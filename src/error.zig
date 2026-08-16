//! Exception details for `error.RubyException`.

const std = @import("std");
const c = @import("c.zig");
const alloc_mod = @import("alloc.zig");

pub const RubyError = struct {
    mrb: *c.mrb_state,
    exc: c.mrb_value,

    pub fn fromValue(mrb: *c.mrb_state, exc: c.mrb_value) RubyError {
        return .{ .mrb = mrb, .exc = exc };
    }

    /// Exception message (`exc.to_s`). Owned by the caller; free it with
    /// `mruby.alloc.gpa.free`. Valid while the exception is pending (right
    /// after an `error.RubyException`).
    pub fn message(self: RubyError) []const u8 {
        return self.dupeString(self.protectedFuncall("to_s"));
    }

    /// Class name of the exception, e.g. "ZeroDivisionError". Owned by the
    /// caller; free with `mruby.alloc.gpa.free`.
    pub fn className(self: RubyError) []const u8 {
        const cls = self.protectedFuncall("class");
        const Protected = struct {
            fn body(mrb: ?*c.mrb_state, ud: ?*anyopaque) callconv(.c) c.mrb_value {
                const m = mrb orelse return c.mrz_nil_value();
                const v: *c.mrb_value = @ptrCast(@alignCast(ud orelse return c.mrz_nil_value()));
                return c.mrb_funcall(m, v.*, "to_s", 0);
            }
        };
        var err = false;
        const name_v = c.mrb_protect_error(self.mrb, Protected.body, @ptrCast(@constCast(@as(*const c.mrb_value, &cls))), &err);
        return self.dupeString(name_v);
    }

    const ExcCall = struct {
        exc: c.mrb_value,
        method: [*:0]const u8,
    };

    fn protectedFuncall(self: RubyError, method: [*:0]const u8) c.mrb_value {
        const Protected = struct {
            fn body(mrb: ?*c.mrb_state, ud: ?*anyopaque) callconv(.c) c.mrb_value {
                const m = mrb orelse return c.mrz_nil_value();
                const ctx: *ExcCall = @ptrCast(@alignCast(ud orelse return c.mrz_nil_value()));
                return c.mrb_funcall(m, ctx.exc, ctx.method, 0);
            }
        };
        var ctx = ExcCall{ .exc = self.exc, .method = method };
        var err = false;
        return c.mrb_protect_error(self.mrb, Protected.body, &ctx, &err);
    }

    fn dupeString(self: RubyError, v: c.mrb_value) []const u8 {
        _ = self;
        if (!c.mrz_string_p(v)) return "";
        const p = c.mrz_string_ptr(v) orelse return "";
        const len: usize = @intCast(c.mrz_string_len(v));
        return alloc_mod.gpa.dupe(u8, p[0..len]) catch "";
    }
};

test {
    @import("std").testing.refAllDecls(@This());
}
