//! `Vm` — an mruby interpreter instance.

const std = @import("std");
const c = @import("c.zig");
const value_mod = @import("value.zig");
const error_mod = @import("error.zig");
const class_mod = @import("class.zig");
const arena_mod = @import("arena.zig");
const convert = @import("convert.zig");
const alloc_mod = @import("alloc.zig");

pub const Value = value_mod.Value;
pub const RubyError = error_mod.RubyError;
pub const Class = class_mod.Class;
pub const Rest = class_mod.Rest;

/// mrb_state -> Vm registry, so method callbacks (which receive only the
/// C state) can hand Zig code a `*Vm`. Guarded by a spinlock; critical
/// sections are a hash get, so contention is negligible even with many
/// concurrent VMs on separate threads.
var registry_lock = std.atomic.Value(bool).init(false);
var registry: std.AutoHashMapUnmanaged(*c.mrb_state, *Vm) = .empty;

fn registryLock() void {
    while (registry_lock_cmpxchg()) std.atomic.spinLoopHint();
}

fn registry_lock_cmpxchg() bool {
    return registry_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null;
}

fn registryUnlock() void {
    registry_lock.store(false, .release);
}

/// An mruby virtual machine. One per Ruby isolate; a single Vm must not be
/// used from multiple threads simultaneously (like MRI).
pub const Vm = struct {
    mrb: *c.mrb_state,
    /// Destination for Ruby-level `print`/`puts`/`p` output (see
    /// `setOutputWriter`). When null, those methods write to the process
    /// stdout via mruby's default `print` (cstdio).
    writer: ?*std.Io.Writer = null,
    output_installed: bool = false,

    /// Look up the Vm for a C state (used internally by method callbacks).
    pub fn fromMrb(mrb: *c.mrb_state) *Vm {
        registryLock();
        defer registryUnlock();
        return registry.get(mrb) orelse @panic("mruby-zig: mrb_state has no registered Vm");
    }

    /// Create a new interpreter. Fails only on out-of-memory or if core
    /// initialization raises (see `mruby.alloc.setAllocator`).
    pub fn init() !*Vm {
        const mrb = c.mrb_open() orelse return error.OutOfMemory;
        if (!c.mrz_nil_p(c.mrz_exc_value(mrb))) return error.InitFailed;
        const vm = try alloc_mod.gpa.create(Vm);
        vm.* = .{ .mrb = mrb };
        registryLock();
        defer registryUnlock();
        try registry.put(alloc_mod.gpa, mrb, vm);
        return vm;
    }

    pub fn deinit(vm: *Vm) void {
        {
            registryLock();
            defer registryUnlock();
            _ = registry.remove(vm.mrb);
        }
        c.mrb_close(vm.mrb);
        alloc_mod.gpa.destroy(vm);
    }

    // ---- evaluation ------------------------------------------------------

    /// Parse, compile, and execute `src`; returns the value of the last
    /// expression. All Ruby exceptions (compile or runtime) are reported as
    /// `error.RubyException`; call `vm.lastError()` for details.
    pub fn loadString(vm: *Vm, src: []const u8) !Value {
        var ctx = ProtectedLoad{ .src = src };
        const ai = c.mrz_gc_arena_save(vm.mrb);
        defer c.mrz_gc_arena_restore(vm.mrb, ai);

        var err = false;
        const v = c.mrb_protect_error(vm.mrb, protectedLoad, &ctx, &err);
        if (err) {
            // protect returns the exception object as its result and clears
            // mrb->exc; restore it so lastError() can describe it.
            c.mrz_exc_set(vm.mrb, v);
            return error.RubyException;
        }
        if (!c.mrz_nil_p(c.mrz_exc_value(vm.mrb))) {
            return error.RubyException;
        }
        return .{ .mrb = vm.mrb, .v = v };
    }

    const ProtectedLoad = struct { src: []const u8 };

    fn protectedLoad(mrb: ?*c.mrb_state, ud: ?*anyopaque) callconv(.c) c.mrb_value {
        const m = mrb orelse return c.mrz_nil_value();
        const ctx: *ProtectedLoad = @ptrCast(@alignCast(ud orelse return c.mrz_nil_value()));
        return c.mrb_load_nstring(m, ctx.src.ptr, ctx.src.len);
    }

    // ---- calling Ruby from Zig -------------------------------------------

    /// Call `name` on `recv` with up to 8 positional arguments (any type
    /// accepted by `convert.toValue`). Exceptions are reported as
    /// `error.RubyException` (never longjmp into Zig frames).
    pub fn call(vm: *Vm, recv: Value, name: []const u8, args: anytype) !Value {
        var name_buf: [256]u8 = undefined;
        if (name.len >= name_buf.len) return error.NameTooLong;
        @memcpy(name_buf[0..name.len], name);
        name_buf[name.len] = 0;
        const namez: [*:0]const u8 = @ptrCast(&name_buf);

        const sym = c.mrb_intern_cstr(vm.mrb, namez);
        const n = comptime @typeInfo(@TypeOf(args)).@"struct".field_types.len;
        if (n > 8) @compileError("vm.call supports at most 8 arguments");

        var argv: [8]c.mrb_value = undefined;
        inline for (0..n) |i| {
            argv[i] = convert.toValue(vm.mrb, args[i]).v;
        }

        const ctx = ProtectedCall{ .recv = recv.v, .sym = sym, .argc = n, .argv = argv };
        const ai = c.mrz_gc_arena_save(vm.mrb);
        defer c.mrz_gc_arena_restore(vm.mrb, ai);

        var err = false;
        const v = c.mrb_protect_error(vm.mrb, protectedCall, @constCast(@ptrCast(&ctx)), &err);
        if (err) {
            c.mrz_exc_set(vm.mrb, v);
            return error.RubyException;
        }
        if (!c.mrz_nil_p(c.mrz_exc_value(vm.mrb))) {
            return error.RubyException;
        }
        return .{ .mrb = vm.mrb, .v = v };
    }

    const ProtectedCall = struct {
        recv: c.mrb_value,
        sym: c.mrb_sym,
        argc: usize,
        argv: [8]c.mrb_value,
    };

    fn protectedCall(mrb: ?*c.mrb_state, ud: ?*anyopaque) callconv(.c) c.mrb_value {
        const m = mrb orelse return c.mrz_nil_value();
        const ctx: *ProtectedCall = @ptrCast(@alignCast(ud orelse return c.mrz_nil_value()));
        return c.mrb_funcall_argv(m, ctx.recv, ctx.sym, @intCast(ctx.argc), &ctx.argv);
    }

    // ---- classes ---------------------------------------------------------

    /// Define a new class (super defaults to Object). Fails if the name
    /// already names something else.
    pub fn defineClass(vm: *Vm, name: []const u8, super: ?Class) !Class {
        var buf: [256]u8 = undefined;
        if (name.len >= buf.len) return error.NameTooLong;
        @memcpy(buf[0..name.len], name);
        buf[name.len] = 0;
        const super_ptr: ?*c.RClass = if (super) |s| s.class else null;
        // mrb_define_class with NULL super gives Object; an existing class
        // with the name is returned unchanged (mruby semantics).
        const existing = vm.getClassOrNull(name);
        if (existing) |e| return e;
        const cla = c.mrb_define_class(vm.mrb, @ptrCast(&buf), super_ptr orelse objectClass(vm));
        return .{ .mrb = vm.mrb, .class = cla };
    }

    /// Define a new module.
    pub fn defineModule(vm: *Vm, name: []const u8) !Class {
        var buf: [256]u8 = undefined;
        if (name.len >= buf.len) return error.NameTooLong;
        @memcpy(buf[0..name.len], name);
        buf[name.len] = 0;
        const existing = vm.getClassOrNull(name);
        if (existing) |e| return e;
        const cla = c.mrb_define_module(vm.mrb, @ptrCast(&buf));
        return .{ .mrb = vm.mrb, .class = cla };
    }

    /// Fetch a class/module by fully-qualified name ("Object", "Math",
    /// "Enumerator::Lazy"). `error.UnknownClass` if no such constant exists.
    pub fn getClass(vm: *Vm, name: []const u8) !Class {
        return vm.getClassOrNull(name) orelse error.UnknownClass;
    }

    fn getClassOrNull(vm: *Vm, name: []const u8) ?Class {
        // mrb_class_get raises NameError on missing constants, so the walk
        // runs under protect; any raise -> null.
        if (name.len >= 256) return null;
        var ctx = ProtectedLookup{ .name = name };
        var err = false;
        const v = c.mrb_protect_error(vm.mrb, protectedLookup, @ptrCast(&ctx), &err);
        if (err) {
            c.mrz_exc_clear(vm.mrb);
            return null;
        }
        if (!c.mrz_nil_p(c.mrz_exc_value(vm.mrb))) {
            c.mrz_exc_clear(vm.mrb);
            return null;
        }
        if (c.mrz_nil_p(v)) return null;
        const ptr = c.mrz_ptr(v) orelse return null;
        return .{ .mrb = vm.mrb, .class = @ptrCast(@alignCast(ptr)) };
    }

    const ProtectedLookup = struct { name: []const u8 };

    /// Resolve "A::B::C" through const_get and accept Class, Module, or
    /// SClass (mrb_class_get / mrb_module_get are each type-strict).
    fn protectedLookup(mrb: ?*c.mrb_state, ud: ?*anyopaque) callconv(.c) c.mrb_value {
        const m = mrb orelse return c.mrz_nil_value();
        const ctx: *ProtectedLookup = @ptrCast(@alignCast(ud orelse return c.mrz_nil_value()));

        var buf: [256]u8 = undefined;
        var cur = c.mrz_obj_value(@ptrCast(c.mrb_class_get(m, "Object")));
        var it = std.mem.splitSequence(u8, ctx.name, "::");
        while (it.next()) |seg| {
            if (seg.len == 0) continue;
            if (seg.len >= buf.len) return c.mrz_nil_value();
            @memcpy(buf[0..seg.len], seg);
            buf[seg.len] = 0;
            const sym = c.mrb_intern_cstr(m, @ptrCast(&buf));
            cur = c.mrb_const_get(m, cur, sym);
        }
        switch (c.mrz_type(cur)) {
            c.MRB_TT_CLASS, c.MRB_TT_MODULE, c.MRB_TT_SCLASS => return cur,
            else => return c.mrz_nil_value(),
        }
    }

    fn objectClass(vm: *Vm) *c.RClass {
        return c.mrb_class_get(vm.mrb, "Object");
    }

    // ---- globals / instance variables ------------------------------------

    /// Read a global variable. `name` excludes the `$` ("version", not
    /// "$version").
    pub fn getGlobal(vm: *Vm, name: []const u8) !Value {
        var buf: [256]u8 = undefined;
        if (name.len + 1 >= buf.len) return error.NameTooLong;
        buf[0] = '$';
        @memcpy(buf[1 .. name.len + 1], name);
        const sym = try vm.intern(buf[0 .. name.len + 1]);
        return .{ .mrb = vm.mrb, .v = c.mrb_gv_get(vm.mrb, sym) };
    }

    pub fn setGlobal(vm: *Vm, name: []const u8, val: Value) void {
        var buf: [256]u8 = undefined;
        if (name.len + 1 >= buf.len) return;
        buf[0] = '$';
        @memcpy(buf[1 .. name.len + 1], name);
        const sym = vm.intern(buf[0 .. name.len + 1]) catch return;
        c.mrb_gv_set(vm.mrb, sym, val.v);
    }

    pub fn getIvar(vm: *Vm, obj: Value, name: []const u8) Value {
        const sym = vm.intern(name) catch return Value.nil(vm.mrb);
        return .{ .mrb = vm.mrb, .v = c.mrb_iv_get(vm.mrb, obj.v, sym) };
    }

    pub fn setIvar(vm: *Vm, obj: Value, name: []const u8, val: Value) void {
        const sym = vm.intern(name) catch return;
        c.mrb_iv_set(vm.mrb, obj.v, sym, val.v);
    }

    fn intern(vm: *Vm, name: []const u8) !c.mrb_sym {
        return c.mrb_intern(vm.mrb, name.ptr, name.len);
    }

    // ---- symbols ----------------------------------------------------------

    /// Intern a symbol, returning its id.
    pub fn internSymbol(vm: *Vm, name: []const u8) !u32 {
        return c.mrb_intern(vm.mrb, name.ptr, name.len);
    }

    /// Symbol name (borrowed; lives in the symbol table for the lifetime of
    /// the interpreter).
    pub fn symbolName(vm: *Vm, sym: u32) []const u8 {
        var len: c.mrb_int = 0;
        const p = c.mrb_sym_name_len(vm.mrb, sym, &len) orelse return "";
        return p[0..@intCast(len)];
    }

    // ---- raising from Zig callbacks ---------------------------------------

    /// Set a pending exception and return `error.RubyException` from your
    /// method callback. Intended for use inside Zig method callbacks, where
    /// the exception is re-raised from a clean frame by the dispatcher.
    pub fn raise(vm: *Vm, class_name: []const u8, msg: []const u8) error{RubyException} {
        const ctx = ProtectedRaise{ .class_name = class_name, .msg = msg };
        var err = false;
        _ = c.mrb_protect_error(vm.mrb, protectedRaise, @ptrCast(@constCast(&ctx)), &err);
        return error.RubyException;
    }

    const ProtectedRaise = struct { class_name: []const u8, msg: []const u8 };

    fn protectedRaise(mrb: ?*c.mrb_state, ud: ?*anyopaque) callconv(.c) c.mrb_value {
        const m = mrb orelse return c.mrz_nil_value();
        const ctx: *ProtectedRaise = @ptrCast(@alignCast(ud orelse return c.mrz_nil_value()));

        var cn: [128]u8 = undefined;
        if (ctx.class_name.len >= cn.len) {
            c.mrz_exc_set(m, simpleError(m, "RuntimeError", ctx.msg));
            return c.mrz_nil_value();
        }
        @memcpy(cn[0..ctx.class_name.len], ctx.class_name);
        cn[ctx.class_name.len] = 0;

        const msg_str = c.mrb_str_new(m, if (ctx.msg.len == 0) null else ctx.msg.ptr, @intCast(ctx.msg.len));
        const cls = c.mrb_class_get(m, @ptrCast(&cn));
        const exc = c.mrb_funcall(m, c.mrz_obj_value(@ptrCast(cls)), "exception", 1, msg_str);
        if (!c.mrz_nil_p(c.mrz_exc_value(m))) return c.mrz_nil_value(); // keep earlier exception
        c.mrz_exc_set(m, exc);
        return c.mrz_nil_value();
    }

    fn simpleError(m: *c.mrb_state, class_name: [*:0]const u8, msg: []const u8) c.mrb_value {
        const cls = c.mrb_class_get(m, class_name);
        const msg_str = c.mrb_str_new(m, if (msg.len == 0) null else msg.ptr, @intCast(msg.len));
        return c.mrb_funcall(m, c.mrz_obj_value(@ptrCast(cls)), "exception", 1, msg_str);
    }

    // ---- exceptions -------------------------------------------------------

    /// The pending exception, if `error.RubyException` was just returned.
    pub fn lastError(vm: *Vm) ?RubyError {
        const exc = c.mrz_exc_value(vm.mrb);
        if (c.mrz_nil_p(exc)) return null;
        return RubyError.fromValue(vm.mrb, exc);
    }

    pub fn clearError(vm: *Vm) void {
        c.mrz_exc_clear(vm.mrb);
    }

    /// Print the pending exception + backtrace to the process stderr
    /// (mruby's own formatter).
    pub fn printError(vm: *Vm) void {
        c.mrb_print_error(vm.mrb);
    }

    // ---- GC ---------------------------------------------------------------

    pub fn arenaScope(vm: *Vm) arena_mod.Scope {
        return .{ .mrb = vm.mrb, .idx = c.mrz_gc_arena_save(vm.mrb) };
    }

    // ---- value construction ------------------------------------------------

    pub fn intValue(vm: *Vm, x: anytype) Value {
        return convert.toValue(vm.mrb, @as(i64, @intCast(x)));
    }

    pub fn floatValue(vm: *Vm, x: f64) Value {
        return convert.toValue(vm.mrb, x);
    }

    pub fn boolValue(vm: *Vm, x: bool) Value {
        return convert.toValue(vm.mrb, x);
    }

    pub fn stringValue(vm: *Vm, s: []const u8) Value {
        return convert.toValue(vm.mrb, s);
    }

    pub fn nilValue(vm: *Vm) Value {
        return Value.nil(vm.mrb);
    }
};

test {
    @import("std").testing.refAllDecls(@This());
}
