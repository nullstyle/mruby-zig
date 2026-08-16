//! `Vm` — an mruby interpreter instance.

const std = @import("std");
const c = @import("c.zig");
const value_mod = @import("value.zig");
const error_mod = @import("error.zig");

pub const Value = value_mod.Value;
pub const RubyError = error_mod.RubyError;

/// An mruby virtual machine. One per Ruby isolate; not thread-safe (a Vm
/// must be confined to one thread at a time, like MRI).
pub const Vm = struct {
    mrb: *c.mrb_state,

    /// Create a new interpreter. Fails only if the process is out of memory
    /// or core initialization raises (see `mruby.alloc` for the allocator).
    pub fn init() !*Vm {
        const mrb = c.mrb_open() orelse return error.OutOfMemory;
        const vm = @import("alloc.zig").gpa.create(Vm) catch {
            c.mrb_close(mrb);
            return error.OutOfMemory;
        };
        vm.* = .{ .mrb = mrb };
        if (!c.mrz_nil_p(c.mrz_exc_value(mrb))) {
            vm.deinit();
            return error.InitFailed;
        }
        return vm;
    }

    pub fn deinit(vm: *Vm) void {
        c.mrb_close(vm.mrb);
        @import("alloc.zig").gpa.destroy(vm);
    }

    /// Parse, compile, and execute `src`; returns the value of the last
    /// expression. All Ruby exceptions (compile or runtime) are caught and
    /// reported as `error.RubyException`; call `vm.lastError()` for details.
    pub fn loadString(vm: *Vm, src: []const u8) !Value {
        var ctx = ProtectedLoad{ .src = src };
        const ai = c.mrz_gc_arena_save(vm.mrb);
        defer c.mrz_gc_arena_restore(vm.mrb, ai);

        var err = false;
        const v = c.mrb_protect_error(vm.mrb, protectedLoad, &ctx, &err);
        if (err or !c.mrz_nil_p(c.mrz_exc_value(vm.mrb))) {
            return error.RubyException;
        }
        return .{ .mrb = vm.mrb, .v = v };
    }

    /// The pending exception, if `error.RubyException` was just returned.
    /// The returned value is only valid until the next mruby call that
    /// touches the interpreter.
    pub fn lastError(vm: *Vm) ?RubyError {
        const exc = c.mrz_exc_value(vm.mrb);
        if (c.mrz_nil_p(exc)) return null;
        return RubyError.fromValue(vm.mrb, exc);
    }

    pub fn clearError(vm: *Vm) void {
        c.mrz_exc_clear(vm.mrb);
    }

    const ProtectedLoad = struct {
        src: []const u8,
    };

    fn protectedLoad(mrb: ?*c.mrb_state, ud: ?*anyopaque) callconv(.c) c.mrb_value {
        const m = mrb orelse return c.mrz_nil_value();
        const ctx: *ProtectedLoad = @ptrCast(@alignCast(ud orelse return c.mrz_nil_value()));
        return c.mrb_load_nstring(m, ctx.src.ptr, ctx.src.len);
    }
};

test {
    @import("std").testing.refAllDecls(@This());
}
