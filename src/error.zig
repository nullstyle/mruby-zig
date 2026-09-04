//! Exception details for `error.RubyException`.

const std = @import("std");
const c = @import("c.zig");

pub const DetailError = std.mem.Allocator.Error || error{
    DiagnosticUnavailable,
};

pub const DetailOptions = struct {
    /// Bound allocation and guest-controlled backtrace size.
    max_backtrace_frames: usize = 128,
};

pub const Details = struct {
    allocator: std.mem.Allocator,
    class_name: []u8,
    message: []u8,
    backtrace: [][]u8,
    backtrace_truncated: bool,

    pub fn deinit(details: *Details) void {
        for (details.backtrace) |frame| details.allocator.free(frame);
        details.allocator.free(details.backtrace);
        details.allocator.free(details.message);
        details.allocator.free(details.class_name);
        details.* = undefined;
    }
};

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
    /// errors duplicate inert stored metadata without guest execution. The
    /// returned bytes are owned by the caller and use `allocator`.
    pub fn message(self: RubyError, allocator: std.mem.Allocator) DetailError![]u8 {
        if (self.inert) |metadata| {
            if (!c.mrz_nil_p(metadata.message)) {
                return self.dupeInertValue(allocator, metadata.message, "");
            }
            return self.dupeInertValue(allocator, metadata.class_name, "<anonymous exception>");
        }
        const message_value = try self.protectedFuncall(self.exc, "to_s");
        return self.dupeString(allocator, message_value);
    }

    /// Class name of the exception, e.g. "ZeroDivisionError". Sandbox errors
    /// use the cached real class path and `"<anonymous exception>"` fallback,
    /// without guest dispatch. The returned bytes are owned by the caller and
    /// use `allocator`.
    pub fn className(self: RubyError, allocator: std.mem.Allocator) DetailError![]u8 {
        if (self.inert) |metadata| {
            return self.dupeInertValue(allocator, metadata.class_name, "<anonymous exception>");
        }
        const cls = try self.protectedFuncall(self.exc, "class");
        const name_v = try self.protectedFuncall(cls, "to_s");
        return self.dupeString(allocator, name_v);
    }

    /// Capture allocator-owned exception data before another VM operation
    /// supersedes `lastError()`. Sandbox errors retain their inert message and
    /// class metadata and intentionally omit guest-dispatched backtraces.
    pub fn details(
        self: RubyError,
        allocator: std.mem.Allocator,
        options: DetailOptions,
    ) DetailError!Details {
        const class_name = try self.className(allocator);
        errdefer allocator.free(class_name);
        const message_text = try self.message(allocator);
        errdefer allocator.free(message_text);

        const backtrace_result = try self.dupeBacktrace(allocator, options);
        errdefer {
            for (backtrace_result.frames) |frame| allocator.free(frame);
            allocator.free(backtrace_result.frames);
        }
        return .{
            .allocator = allocator,
            .class_name = class_name,
            .message = message_text,
            .backtrace = backtrace_result.frames,
            .backtrace_truncated = backtrace_result.truncated,
        };
    }

    fn protectedFuncall(
        self: RubyError,
        receiver: c.mrb_value,
        method: []const u8,
    ) DetailError!c.mrb_value {
        var result: c.mrb_value = undefined;
        if (!c.mrz_protected_funcall_preserve_error(
            self.mrb,
            receiver,
            method.ptr,
            method.len,
            &result,
        )) return error.DiagnosticUnavailable;
        return result;
    }

    fn dupeString(
        self: RubyError,
        allocator: std.mem.Allocator,
        v: c.mrb_value,
    ) DetailError![]u8 {
        _ = self;
        if (!c.mrz_string_p(v)) return error.DiagnosticUnavailable;
        const p = c.mrz_string_ptr(v) orelse return error.DiagnosticUnavailable;
        const len: usize = @intCast(c.mrz_string_len(v));
        return allocator.dupe(u8, p[0..len]);
    }

    fn dupeInertValue(
        self: RubyError,
        allocator: std.mem.Allocator,
        value: c.mrb_value,
        fallback: []const u8,
    ) DetailError![]u8 {
        if (c.mrz_string_p(value)) return self.dupeString(allocator, value);
        if (c.mrz_symbol_p(value)) {
            var len: c.mrb_int = 0;
            const ptr = c.mrb_sym_name_len(self.mrb, c.mrz_symbol(value), &len) orelse {
                return allocator.dupe(u8, fallback);
            };
            return allocator.dupe(u8, ptr[0..@intCast(len)]);
        }
        return allocator.dupe(u8, fallback);
    }

    fn dupeBacktrace(
        self: RubyError,
        allocator: std.mem.Allocator,
        options: DetailOptions,
    ) DetailError!struct { frames: [][]u8, truncated: bool } {
        if (self.inert != null) {
            return .{
                .frames = try allocator.alloc([]u8, 0),
                .truncated = false,
            };
        }

        const value = try self.protectedFuncall(self.exc, "backtrace");
        if (c.mrz_nil_p(value)) {
            return .{
                .frames = try allocator.alloc([]u8, 0),
                .truncated = false,
            };
        }
        if (!c.mrz_array_p(value)) return error.DiagnosticUnavailable;

        const available = c.mrz_array_len(value);
        const count = @min(available, options.max_backtrace_frames);
        const frames = try allocator.alloc([]u8, count);
        var initialized: usize = 0;
        errdefer {
            for (frames[0..initialized]) |frame| allocator.free(frame);
            allocator.free(frames);
        }
        while (initialized < count) : (initialized += 1) {
            const frame = c.mrb_ary_entry(value, @intCast(initialized));
            frames[initialized] = try self.dupeString(allocator, frame);
        }
        return .{
            .frames = frames,
            .truncated = available > count,
        };
    }
};

test {
    @import("std").testing.refAllDecls(@This());
}
