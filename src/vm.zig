//! `Vm` — an mruby interpreter instance.

const std = @import("std");
const c = @import("c.zig");
const value_mod = @import("value.zig");
const error_mod = @import("error.zig");
const class_mod = @import("class.zig");
const arena_mod = @import("arena.zig");
const convert = @import("convert.zig");
const alloc_mod = @import("alloc.zig");
const features = @import("features.zig");

pub const Value = value_mod.Value;
pub const Array = value_mod.Array;
pub const Hash = value_mod.Hash;
pub const HashEntry = value_mod.HashEntry;
pub const RubyError = error_mod.RubyError;
pub const Class = class_mod.Class;
pub const Rest = class_mod.Rest;
pub const RootedValue = arena_mod.RootedValue;

pub const LoadOptions = struct {
    /// Ruby source identity used by `__FILE__`, syntax diagnostics, and
    /// backtraces. Null retains mruby's default `"(eval)"` identity.
    source_name: ?[]const u8 = null,
};

pub const CallOptions = struct {
    /// Proc passed as the Ruby block. mruby applies `to_proc` to other values.
    block: ?Value = null,
};

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
    roots: arena_mod.RootRegistry,
    /// Destination for Ruby-level `print`/`puts`/`p` output (see
    /// `setOutputWriter`). When null, those methods write to the process
    /// stdout via mruby's default `print` (cstdio).
    writer: ?*std.Io.Writer = null,
    output_installed: bool = false,
    /// Bootstrap-installed effect dispatcher and host-owned execution state.
    effects: ?*@import("effect.zig").State = null,

    /// Look up the Vm for a C state (used internally by method callbacks).
    pub fn fromMrb(mrb: *c.mrb_state) *Vm {
        registryLock();
        defer registryUnlock();
        return registry.get(mrb) orelse @panic("mruby-zig: mrb_state has no registered Vm");
    }

    /// Diagnostics for the most recent `error.InitFailed`, best-effort and
    /// thread-unsafe (only meaningful immediately after a failed `init`).
    var init_failure_buf: [256]u8 = undefined;
    var init_failure_len: usize = 0;

    /// Create a new interpreter. Fails on out-of-memory or if initialization
    /// raises (e.g. a misconfigured gem set — see `lastInitFailure` for the
    /// Ruby-level reason; see `mruby.alloc.setAllocator` for the allocator).
    pub fn init() !*Vm {
        const mrb = c.mrb_open() orelse return error.OutOfMemory;
        errdefer c.mrb_close(mrb);
        if (comptime features.effects_strict) {
            var detail: c.StrictDiagnostic = undefined;
            if (c.mrz_strict_violation(mrb, &detail)) return error.StrictInitializationFailed;
        }
        if (!c.mrz_nil_p(c.mrz_exc_value(mrb))) {
            captureInitFailure(mrb);
            return error.InitFailed;
        }
        const vm = try alloc_mod.gpa.create(Vm);
        errdefer alloc_mod.gpa.destroy(vm);
        vm.* = .{
            .mrb = mrb,
            .roots = arena_mod.RootRegistry.init(alloc_mod.gpa, mrb),
        };
        registryLock();
        defer registryUnlock();
        try registry.put(alloc_mod.gpa, mrb, vm);
        return vm;
    }

    /// The Ruby-level "class: message" behind the last `error.InitFailed`
    /// (empty if the failure was not exception-related).
    pub fn lastInitFailure() []const u8 {
        return init_failure_buf[0..init_failure_len];
    }

    fn captureInitFailure(mrb: *c.mrb_state) void {
        const exc = RubyError.fromValue(mrb, c.mrz_exc_value(mrb));
        const cls = exc.className(alloc_mod.gpa) catch {
            init_failure_len = 0;
            return;
        };
        defer alloc_mod.gpa.free(cls);
        const msg = exc.message(alloc_mod.gpa) catch {
            init_failure_len = 0;
            return;
        };
        defer alloc_mod.gpa.free(msg);
        if (std.fmt.bufPrint(&init_failure_buf, "{s}: {s}", .{ cls, msg })) |written| {
            init_failure_len = written.len;
        } else |_| {
            init_failure_len = 0;
        }
    }

    pub fn deinit(vm: *Vm) void {
        if (vm.effects) |effects| effects.deinit();
        vm.roots.deinit();
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
    ///
    /// Source containing an interior NUL is rejected rather than silently
    /// evaluating only the prefix visible to mruby's lexer.
    /// Returns `error.CompilerUnavailable` in a `-Dno-compiler` build.
    /// Runtime-only builds return `error.CompilerUnavailable`.
    pub fn loadString(vm: *Vm, src: []const u8) !Value {
        return vm.loadStringWithOptions(src, .{});
    }

    /// Parse, compile, and execute source with explicit source metadata.
    pub fn loadStringWithOptions(
        vm: *Vm,
        src: []const u8,
        options: LoadOptions,
    ) !Value {
        if (comptime !features.has_compiler) return error.CompilerUnavailable;
        if (std.mem.indexOfScalar(u8, src, 0) != null) return error.InvalidSource;
        if (options.source_name) |source_name| {
            if (source_name.len == 0 or
                std.mem.indexOfScalar(u8, source_name, 0) != null)
            {
                return error.InvalidSourceName;
            }
        }

        // mruby's lexer reads to a NUL sentinel (mrb_load_nstring's length is
        // not a hard bound in 4.0), so the source is always copied into a
        // NUL-terminated buffer first.
        var stack_buf: [4096]u8 = undefined;
        const taken = src.len < stack_buf.len;
        const buffer_length = std.math.add(usize, src.len, 1) catch
            return error.OutOfMemory;
        const buf = if (taken)
            stack_buf[0..]
        else
            try alloc_mod.gpa.alloc(u8, buffer_length);
        defer if (!taken) alloc_mod.gpa.free(buf);
        @memcpy(buf[0..src.len], src);
        buf[src.len] = 0;

        // mrb_protect_error already restores the arena to its own entry index
        // and re-roots `v` via mrb_gc_protect, so the result is left rooted at
        // exactly one arena slot. An outer save+restore here would pop that
        // slot, un-rooting the returned Value (a use-after-free once a later
        // allocation triggers GC). Callers that loop should bound growth with
        // `vm.arenaScope()`.
        var v: c.mrb_value = undefined;
        if (!c.mrz_protected_load_string(
            vm.mrb,
            @ptrCast(buf.ptr),
            src.len,
            if (options.source_name) |name| name.ptr else null,
            if (options.source_name) |name| name.len else 0,
            &v,
        ))
            return error.RubyException;
        return .{ .mrb = vm.mrb, .v = v };
    }

    /// Load and execute a compiled irep image (see `sandbox.compile`). Same
    /// error and GC-rooting semantics as `loadString`: an uncaught exception
    /// is reported as `error.RubyException` (never returned as a value), and
    /// the pending exception is left set for `lastError()` rather than
    /// leaking into the next call.
    pub fn loadIrep(vm: *Vm, image: []const u8) !Value {
        var v: c.mrb_value = undefined;
        if (!c.mrz_protected_load_irep(vm.mrb, image.ptr, image.len, &v))
            return error.RubyException;
        return .{ .mrb = vm.mrb, .v = v };
    }

    // ---- calling Ruby from Zig -------------------------------------------

    /// Call `name` on `recv` with positional arguments (any type accepted by
    /// `convert.toValue`). Exceptions are reported as `error.RubyException`
    /// (never longjmp into Zig frames).
    pub fn call(vm: *Vm, recv: Value, name: []const u8, args: anytype) !Value {
        return vm.callWithOptions(recv, name, args, .{});
    }

    /// Call a Ruby method with positional arguments and an optional block.
    pub fn callWithOptions(
        vm: *Vm,
        recv: Value,
        name: []const u8,
        args: anytype,
        options: CallOptions,
    ) !Value {
        try recv.ensureOwnedBy(vm.mrb);
        if (options.block) |block| try block.ensureOwnedBy(vm.mrb);

        if (name.len >= 256) return error.NameTooLong;
        const n = comptime @typeInfo(@TypeOf(args)).@"struct".field_types.len;
        const argc = std.math.cast(c.mrb_int, n) orelse
            return error.TooManyArguments;

        var argv: [n]c.mrb_value = undefined;
        inline for (0..n) |i| {
            argv[i] = (try convert.toValue(vm.mrb, args[i])).v;
        }

        // mrb_protect_error re-roots its result in the arena; an outer
        // save+restore would pop that slot and un-root the returned Value.
        // See loadString for the full rationale.
        var v: c.mrb_value = undefined;
        if (!c.mrz_protected_funcall_with_block(
            vm.mrb,
            recv.v,
            name.ptr,
            name.len,
            argc,
            &argv,
            if (options.block) |block| block.v else c.mrz_nil_value(),
            &v,
        )) {
            return error.RubyException;
        }
        return .{ .mrb = vm.mrb, .v = v };
    }

    // ---- classes ---------------------------------------------------------

    /// Define a new class (super defaults to Object). If the name already
    /// names a class it is returned unchanged; if it names a non-class
    /// constant, `error.RubyException` (TypeError) is returned — never a
    /// longjmp through Zig frames.
    pub fn defineClass(vm: *Vm, name: []const u8, super: ?Class) !Class {
        if (super) |s| try s.ensureOwnedBy(vm.mrb);
        const existing = try vm.lookupClass(name);
        if (existing) |e| return e;
        const super_ptr: ?*c.RClass = if (super) |s| s.class else null;
        const v = try vm.protectedDefine(
            name,
            super_ptr,
            c.MRZ_DEFINE_CLASS,
        );
        return .{ .mrb = vm.mrb, .class = @ptrCast(@alignCast(c.mrz_ptr(v) orelse return error.InitFailed)) };
    }

    /// Define a new module. Same conflict semantics as `defineClass`.
    pub fn defineModule(vm: *Vm, name: []const u8) !Class {
        const existing = try vm.lookupClass(name);
        if (existing) |e| return e;
        const v = try vm.protectedDefine(name, null, c.MRZ_DEFINE_MODULE);
        return .{ .mrb = vm.mrb, .class = @ptrCast(@alignCast(c.mrz_ptr(v) orelse return error.InitFailed)) };
    }

    fn protectedDefine(
        vm: *Vm,
        name: []const u8,
        super: ?*c.RClass,
        kind: u8,
    ) !c.mrb_value {
        var value: c.mrb_value = undefined;
        if (!c.mrz_protected_define(
            vm.mrb,
            name.ptr,
            name.len,
            super,
            kind,
            &value,
        )) {
            return error.RubyException;
        }
        if (c.mrz_nil_p(value)) return error.InitFailed;
        return value;
    }

    /// Fetch a class/module by fully-qualified name ("Object", "Math",
    /// "Enumerator::Lazy"). `error.UnknownClass` if no such constant exists.
    pub fn getClass(vm: *Vm, name: []const u8) !Class {
        return (try vm.lookupClass(name)) orelse error.UnknownClass;
    }

    fn lookupClass(vm: *Vm, name: []const u8) !?Class {
        var value: c.mrb_value = undefined;
        if (!c.mrz_protected_lookup(vm.mrb, name.ptr, name.len, &value))
            return error.RubyException;
        if (c.mrz_nil_p(value)) return null;
        const ptr = c.mrz_ptr(value) orelse return null;
        return .{ .mrb = vm.mrb, .class = @ptrCast(@alignCast(ptr)) };
    }

    // ---- globals / instance variables ------------------------------------

    /// Read a global variable. `name` excludes the `$` ("version", not
    /// "$version").
    pub fn getGlobal(vm: *Vm, name: []const u8) !Value {
        var buf: [256]u8 = undefined;
        if (name.len > buf.len - 1) return error.NameTooLong;
        buf[0] = '$';
        @memcpy(buf[1 .. name.len + 1], name);
        var value: c.mrb_value = undefined;
        if (!c.mrz_protected_global_get(
            vm.mrb,
            &buf,
            name.len + 1,
            &value,
        )) return error.RubyException;
        return .{ .mrb = vm.mrb, .v = value };
    }

    /// Set a global variable. A value from another interpreter is rejected as
    /// `error.ForeignValue`; allocation failures and Ruby exceptions are
    /// reported rather than silently ignored.
    pub fn setGlobal(vm: *Vm, name: []const u8, val: Value) !void {
        try val.ensureOwnedBy(vm.mrb);

        var buf: [256]u8 = undefined;
        if (name.len > buf.len - 1) return error.NameTooLong;
        buf[0] = '$';
        @memcpy(buf[1 .. name.len + 1], name);
        if (!c.mrz_protected_global_set(
            vm.mrb,
            &buf,
            name.len + 1,
            val.v,
        )) return error.RubyException;
    }

    /// Read an instance variable (`name` includes the `@`); nil if unset.
    pub fn getIvar(vm: *Vm, obj: Value, name: []const u8) !Value {
        try obj.ensureOwnedBy(vm.mrb);
        var value: c.mrb_value = undefined;
        if (!c.mrz_protected_ivar_get(
            vm.mrb,
            obj.v,
            name.ptr,
            name.len,
            &value,
        )) return error.RubyException;
        return .{ .mrb = vm.mrb, .v = value };
    }

    /// Set an instance variable (`name` includes the `@`). The object and
    /// value must both belong to this interpreter.
    pub fn setIvar(vm: *Vm, obj: Value, name: []const u8, val: Value) !void {
        try obj.ensureOwnedBy(vm.mrb);
        try val.ensureOwnedBy(vm.mrb);

        if (!c.mrz_protected_ivar_set(
            vm.mrb,
            obj.v,
            name.ptr,
            name.len,
            val.v,
        )) return error.RubyException;
    }

    // ---- symbols ----------------------------------------------------------

    /// Intern a symbol, returning its id.
    pub fn internSymbol(vm: *Vm, name: []const u8) !u32 {
        var symbol: c.mrb_sym = undefined;
        if (!c.mrz_protected_intern(vm.mrb, name.ptr, name.len, &symbol))
            return error.RubyException;
        return symbol;
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
    /// mruby observes the pending exception after the Zig callback returns.
    pub fn raise(vm: *Vm, class_name: []const u8, msg: []const u8) error{RubyException} {
        _ = c.mrz_protected_set_exception(
            vm.mrb,
            class_name.ptr,
            class_name.len,
            if (msg.len == 0) null else msg.ptr,
            msg.len,
        );
        return error.RubyException;
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
        c.mrz_protected_print_error(vm.mrb);
    }

    // ---- GC ---------------------------------------------------------------

    pub fn arenaScope(vm: *Vm) arena_mod.Scope {
        return .{ .mrb = vm.mrb, .idx = c.mrz_gc_arena_save(vm.mrb) };
    }

    /// Keep `value` alive independently of the GC arena until the returned
    /// root is destroyed. Roots must be destroyed before this VM.
    pub fn root(vm: *Vm, value: Value) arena_mod.RootError!RootedValue {
        return vm.roots.add(value);
    }

    // ---- value construction ------------------------------------------------

    /// Integer value. Inputs outside mruby's signed 64-bit Integer range return
    /// `error.Overflow`; heap-boxing allocation failure is a Ruby exception.
    pub fn intValue(vm: *Vm, x: anytype) !Value {
        requireInteger(@TypeOf(x));
        return convert.toValue(vm.mrb, x);
    }

    /// Integer value with explicit saturation to mruby's signed 64-bit range.
    pub fn saturatingIntValue(vm: *Vm, x: anytype) !Value {
        requireInteger(@TypeOf(x));
        const n: i64 = std.math.cast(i64, x) orelse if (x < 0)
            std.math.minInt(i64)
        else
            std.math.maxInt(i64);
        return convert.toValue(vm.mrb, n);
    }

    pub fn floatValue(vm: *Vm, x: f64) !Value {
        return convert.toValue(vm.mrb, x);
    }

    pub fn boolValue(vm: *Vm, x: bool) Value {
        return .{ .mrb = vm.mrb, .v = c.mrz_bool_value(x) };
    }

    /// String values are copied onto the Ruby heap. Allocation failure is
    /// contained in C and reported as `error.RubyException`.
    pub fn stringValue(vm: *Vm, s: []const u8) !Value {
        return convert.toValue(vm.mrb, s);
    }

    pub fn nilValue(vm: *Vm) Value {
        return Value.nil(vm.mrb);
    }

    /// Construct a Ruby Array from values owned by this VM.
    pub fn array(vm: *Vm, values: []const Value) !Array {
        _ = std.math.cast(c.mrb_int, values.len) orelse
            return error.Overflow;
        const raw = try alloc_mod.gpa.alloc(c.mrb_value, values.len);
        defer alloc_mod.gpa.free(raw);
        for (values, raw) |value, *slot| {
            try value.ensureOwnedBy(vm.mrb);
            slot.* = value.v;
        }

        var result: c.mrb_value = undefined;
        if (!c.mrz_protected_array_new(
            vm.mrb,
            if (raw.len == 0) null else raw.ptr,
            raw.len,
            &result,
        )) return error.RubyException;
        return (Value{ .mrb = vm.mrb, .v = result }).asArray();
    }

    /// Construct a Ruby Hash from key/value entries owned by this VM.
    pub fn hash(vm: *Vm, entries: []const HashEntry) !Hash {
        _ = std.math.cast(c.mrb_int, entries.len) orelse
            return error.Overflow;
        const raw = try alloc_mod.gpa.alloc(c.mrz_hash_entry, entries.len);
        defer alloc_mod.gpa.free(raw);
        for (entries, raw) |entry, *slot| {
            try entry.key.ensureOwnedBy(vm.mrb);
            try entry.value.ensureOwnedBy(vm.mrb);
            slot.* = .{ .key = entry.key.v, .value = entry.value.v };
        }

        var result: c.mrb_value = undefined;
        if (!c.mrz_protected_hash_new(
            vm.mrb,
            if (raw.len == 0) null else raw.ptr,
            raw.len,
            &result,
        )) return error.RubyException;
        return (Value{ .mrb = vm.mrb, .v = result }).asHash();
    }
};

fn requireInteger(comptime T: type) void {
    switch (@typeInfo(T)) {
        .int, .comptime_int => {},
        else => @compileError("expected an integer, found " ++ @typeName(T)),
    }
}

test {
    @import("std").testing.refAllDecls(@This());
}
