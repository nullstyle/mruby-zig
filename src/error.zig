//! Exception details for `error.RubyException`.

const std = @import("std");
const c = @import("c.zig");
const alloc_mod = @import("alloc.zig");

pub const RubyError = struct {
    mrb: *c.mrb_state,
    exc: c.mrb_value,
    inert: ?Inert = null,

    pub const Inert = struct {
        message: c.mrb_value,
        class_name: c.mrb_value,
    };

    pub fn fromValue(mrb: *c.mrb_state, exc: c.mrb_value) RubyError {
        return .{ .mrb = mrb, .exc = exc };
    }

    pub fn fromInert(
        mrb: *c.mrb_state,
        exc: c.mrb_value,
        message_value: c.mrb_value,
        class_name_value: c.mrb_value,
    ) RubyError {
        return .{
            .mrb = mrb,
            .exc = exc,
            .inert = .{ .message = message_value, .class_name = class_name_value },
        };
    }

    /// Exception message. General `Vm` errors dispatch `exc.to_s`; sandbox
    /// errors duplicate inert stored metadata without guest execution. Owned
    /// by the caller; free it with `mruby.alloc.gpa.free`. An allocation
    /// failure returns the empty slice.
    pub fn message(self: RubyError) []const u8 {
        if (self.inert) |metadata| {
            if (!c.mrz_nil_p(metadata.message)) {
                return self.dupeInertValue(metadata.message, "");
            }
            return self.dupeInertValue(metadata.class_name, "<anonymous exception>");
        }
        return self.dupeString(self.protectedFuncall("to_s"));
    }

    /// Class name of the exception, e.g. "ZeroDivisionError". Sandbox errors
    /// use the cached real class path and `"<anonymous exception>"` fallback,
    /// without guest dispatch. Owned by the caller; free with
    /// `mruby.alloc.gpa.free`.
    pub fn className(self: RubyError) []const u8 {
        if (self.inert) |metadata| {
            return self.dupeInertValue(metadata.class_name, "<anonymous exception>");
        }
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
        return dupeBytes(p[0..len]);
    }

    fn dupeInertValue(self: RubyError, value: c.mrb_value, fallback: []const u8) []const u8 {
        if (c.mrz_string_p(value)) return self.dupeString(value);
        if (c.mrz_symbol_p(value)) {
            var len: c.mrb_int = 0;
            const ptr = c.mrb_sym_name_len(self.mrb, c.mrz_symbol(value), &len) orelse {
                return dupeBytes(fallback);
            };
            return dupeBytes(ptr[0..@intCast(len)]);
        }
        return dupeBytes(fallback);
    }

    fn dupeBytes(bytes: []const u8) []const u8 {
        return alloc_mod.gpa.dupe(u8, bytes) catch "";
    }
};

test {
    @import("std").testing.refAllDecls(@This());
}
