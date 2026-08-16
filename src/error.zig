//! Exception details for `error.RubyException`.

const std = @import("std");
const c = @import("c.zig");

pub const RubyError = struct {
    mrb: *c.mrb_state,
    exc: c.mrb_value,

    pub fn fromValue(mrb: *c.mrb_state, exc: c.mrb_value) RubyError {
        return .{ .mrb = mrb, .exc = exc };
    }

    /// Exception message (calls Ruby `message` semantics via `to_s`).
    /// The slice is owned by the caller; allocated with the mruby allocator.
    pub fn message(self: RubyError) []const u8 {
        const s = c.mrb_funcall(self.mrb, self.exc, "to_s", 0);
        if (c.mrz_string_p(s)) {
            const p = c.mrz_string_ptr(s) orelse return "";
            const len: usize = @intCast(c.mrz_string_len(s));
            // Copy out: the exception (and any string built from it) may not
            // survive once the interpreter moves on. Leak-free via GC arena
            // is not possible here, so dupe with the process allocator.
            const gpa = @import("alloc.zig").gpa;
            return gpa.dupe(u8, p[0..len]) catch "";
        }
        return "";
    }

    /// Class name of the exception, e.g. "ZeroDivisionError".
    pub fn className(self: RubyError) []const u8 {
        const cls = c.mrb_funcall(self.mrb, self.exc, "class", 0);
        const name = c.mrb_funcall(self.mrb, cls, "to_s", 0);
        if (c.mrz_string_p(name)) {
            const p = c.mrz_string_ptr(name) orelse return "";
            const len: usize = @intCast(c.mrz_string_len(name));
            const gpa = @import("alloc.zig").gpa;
            return gpa.dupe(u8, p[0..len]) catch "";
        }
        return "";
    }
};

test {
    @import("std").testing.refAllDecls(@This());
}
