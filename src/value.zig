//! `Value` — a Ruby value handle.

const std = @import("std");
const c = @import("c.zig");

pub const Type = enum(c.mrb_vtype) {
    false_ = c.MRB_TT_FALSE,
    true_ = c.MRB_TT_TRUE,
    symbol = c.MRB_TT_SYMBOL,
    undef = c.MRB_TT_UNDEF,
    free = c.MRB_TT_FREE,
    float = c.MRB_TT_FLOAT,
    integer = c.MRB_TT_INTEGER,
    cptr = c.MRB_TT_CPTR,
    object = c.MRB_TT_OBJECT,
    class = c.MRB_TT_CLASS,
    module = c.MRB_TT_MODULE,
    sclass = c.MRB_TT_SCLASS,
    hash = c.MRB_TT_HASH,
    cdata = c.MRB_TT_CDATA,
    exception = c.MRB_TT_EXCEPTION,
    iclass = c.MRB_TT_ICLASS,
    proc = c.MRB_TT_PROC,
    array = c.MRB_TT_ARRAY,
    string = c.MRB_TT_STRING,
    range = c.MRB_TT_RANGE,
    env = c.MRB_TT_ENV,
    fiber = c.MRB_TT_FIBER,
    struct_ = c.MRB_TT_STRUCT,
    istruct = c.MRB_TT_ISTRUCT,
    @"break" = c.MRB_TT_BREAK,
    complex = c.MRB_TT_COMPLEX,
    rational = c.MRB_TT_RATIONAL,
    bigint = c.MRB_TT_BIGINT,
    backtrace = c.MRB_TT_BACKTRACE,
    set = c.MRB_TT_SET,
    _,
};

pub const Value = struct {
    mrb: *c.mrb_state,
    v: c.mrb_value,

    pub fn nil(mrb: *c.mrb_state) Value {
        return .{ .mrb = mrb, .v = c.mrz_nil_value() };
    }

    pub fn typeOf(self: Value) Type {
        return @fromBackingInt(@intCast(c.mrz_type(self.v)));
    }

    pub fn isNil(self: Value) bool {
        return c.mrz_nil_p(self.v);
    }

    pub fn isTruthy(self: Value) bool {
        return c.mrz_test(self.v);
    }

    /// Integer value; error if this value is not an Integer.
    pub fn asInt(self: Value) !i64 {
        if (!c.mrz_integer_p(self.v)) return error.TypeMismatch;
        return c.mrz_integer(self.v);
    }

    /// Float value; error if this value is not a Float.
    pub fn asFloat(self: Value) !f64 {
        if (!c.mrz_float_p(self.v)) return error.TypeMismatch;
        return c.mrz_float_v(self.v);
    }

    /// String contents as a **borrowed** slice pointing into the Ruby heap.
    /// The slice is valid only until the next call into the interpreter
    /// that can allocate or run the GC; use `dupeString` to keep it.
    pub fn asString(self: Value) ![]const u8 {
        if (!c.mrz_string_p(self.v)) return error.TypeMismatch;
        const p = c.mrz_string_ptr(self.v) orelse return error.TypeMismatch;
        return p[0..@intCast(c.mrz_string_len(self.v))];
    }

    /// Copy the string contents into caller-owned memory. The safe way to
    /// hold Ruby text beyond the next interpreter call.
    pub fn dupeString(self: Value, allocator: std.mem.Allocator) ![]u8 {
        return allocator.dupe(u8, try self.asString());
    }

    pub fn isString(self: Value) bool {
        return c.mrz_string_p(self.v);
    }

    pub fn isException(self: Value) bool {
        return c.mrz_exception_p(self.v);
    }
};

test {
    @import("std").testing.refAllDecls(@This());
}
