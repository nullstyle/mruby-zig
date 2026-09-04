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

    /// Reject using a Ruby value with a different interpreter. Heap-backed
    /// `mrb_value`s are meaningful only to the state that created them.
    pub fn ensureOwnedBy(self: Value, mrb: *c.mrb_state) error{ForeignValue}!void {
        if (self.mrb != mrb) return error.ForeignValue;
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
        var bits: u64 = undefined;
        if (!c.mrz_artifact_float_bits(self.v, &bits)) return error.TypeMismatch;
        return @bitCast(bits);
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

    pub fn asArray(self: Value) error{TypeMismatch}!Array {
        if (!c.mrz_array_p(self.v)) return error.TypeMismatch;
        return .{ .inner = self };
    }

    pub fn asHash(self: Value) error{TypeMismatch}!Hash {
        if (!c.mrz_hash_p(self.v)) return error.TypeMismatch;
        return .{ .inner = self };
    }
};

/// A typed view over a Ruby Array. It has the same arena lifetime as its
/// underlying `Value`; use `Vm.root(array.asValue())` for long-lived storage.
pub const Array = struct {
    inner: Value,

    pub fn asValue(array: Array) Value {
        return array.inner;
    }

    pub fn len(array: Array) usize {
        return c.mrz_array_len(array.inner.v);
    }

    pub fn get(array: Array, index: usize) !Value {
        if (index >= array.len()) return error.IndexOutOfBounds;
        const raw_index = std.math.cast(c.mrb_int, index) orelse
            return error.Overflow;
        var result: c.mrb_value = undefined;
        if (!c.mrz_protected_array_get(
            array.inner.mrb,
            array.inner.v,
            raw_index,
            &result,
        )) return error.RubyException;
        return .{ .mrb = array.inner.mrb, .v = result };
    }

    /// Set `index`, extending the Ruby Array with nil values when needed.
    pub fn set(array: Array, index: usize, value: Value) !void {
        try value.ensureOwnedBy(array.inner.mrb);
        const raw_index = std.math.cast(c.mrb_int, index) orelse
            return error.Overflow;
        if (!c.mrz_protected_array_set(
            array.inner.mrb,
            array.inner.v,
            raw_index,
            value.v,
        )) return error.RubyException;
    }

    pub fn append(array: Array, value: Value) !void {
        try value.ensureOwnedBy(array.inner.mrb);
        if (!c.mrz_protected_array_push(
            array.inner.mrb,
            array.inner.v,
            value.v,
        )) return error.RubyException;
    }
};

pub const HashEntry = struct {
    key: Value,
    value: Value,
};

/// A typed view over a Ruby Hash. Lookup bypasses Hash defaults and
/// distinguishes a missing key (`null`) from a present key whose value is
/// Ruby `nil`.
pub const Hash = struct {
    inner: Value,

    pub fn asValue(hash: Hash) Value {
        return hash.inner;
    }

    pub fn len(hash: Hash) usize {
        return @intCast(c.mrb_hash_size(hash.inner.mrb, hash.inner.v));
    }

    pub fn get(hash: Hash, key: Value) !?Value {
        try key.ensureOwnedBy(hash.inner.mrb);
        var found = false;
        var result: c.mrb_value = undefined;
        if (!c.mrz_protected_hash_get(
            hash.inner.mrb,
            hash.inner.v,
            key.v,
            &found,
            &result,
        )) return error.RubyException;
        if (!found) return null;
        return .{ .mrb = hash.inner.mrb, .v = result };
    }

    pub fn set(hash: Hash, key: Value, value: Value) !void {
        try key.ensureOwnedBy(hash.inner.mrb);
        try value.ensureOwnedBy(hash.inner.mrb);
        if (!c.mrz_protected_hash_set(
            hash.inner.mrb,
            hash.inner.v,
            key.v,
            value.v,
        )) return error.RubyException;
    }

    pub fn keys(hash: Hash) !Array {
        var result: c.mrb_value = undefined;
        if (!c.mrz_protected_hash_keys(
            hash.inner.mrb,
            hash.inner.v,
            &result,
        )) return error.RubyException;
        return (Value{ .mrb = hash.inner.mrb, .v = result }).asArray();
    }
};

test {
    @import("std").testing.refAllDecls(@This());
}
