//! Zig <-> Ruby conversions.
//!
//! `toValue` / `fromValue` dispatch on the Zig type. Supported: integers,
//! floats, bools, slices of u8 (copied into Ruby strings on the way in),
//! `Value` itself (passthrough), and `?T` optionals of any supported type.

const std = @import("std");
const c = @import("c.zig");
const value_mod = @import("value.zig");

pub const Value = value_mod.Value;

/// Convert a Zig value to a Ruby value. Integers that do not fit an i64
/// (e.g. a large u64, since this build has no bigint) return
/// `error.Overflow`. Strings are copied into Ruby heap strings.
pub fn toValue(mrb: *c.mrb_state, x: anytype) !Value {
    const T = @TypeOf(x);
    if (T == Value) {
        try x.ensureOwnedBy(mrb);
        return x;
    }
    if (T == c.mrb_value) return .{ .mrb = mrb, .v = x };
    return switch (@typeInfo(T)) {
        .int => blk: {
            const n: i64 = std.math.cast(i64, x) orelse return error.Overflow;
            var value: c.mrb_value = undefined;
            if (!c.mrz_protected_integer(mrb, n, &value))
                return error.RubyException;
            break :blk .{ .mrb = mrb, .v = value };
        },
        .float => blk: {
            var value: c.mrb_value = undefined;
            if (!c.mrz_protected_float(mrb, x, &value))
                return error.RubyException;
            break :blk .{ .mrb = mrb, .v = value };
        },
        .bool => .{ .mrb = mrb, .v = c.mrz_bool_value(x) },
        .optional => if (x) |inner| toValue(mrb, inner) else Value.nil(mrb),
        .pointer => |info| switch (info.size) {
            .slice => blk: {
                const Elem = @typeInfo(T).pointer.child;
                if (Elem == u8) {
                    _ = std.math.cast(c.mrb_int, x.len) orelse
                        return error.Overflow;
                    var value: c.mrb_value = undefined;
                    if (!c.mrz_protected_string(
                        mrb,
                        if (x.len == 0) null else x.ptr,
                        x.len,
                        &value,
                    )) return error.RubyException;
                    break :blk .{ .mrb = mrb, .v = value };
                }
                @compileError("unsupported slice element type for toValue: " ++ @typeName(Elem));
            },
            else => @compileError("unsupported pointer type for toValue: " ++ @typeName(T)),
        },
        .null => Value.nil(mrb),
        else => @compileError("unsupported type for toValue: " ++ @typeName(T)),
    };
}

pub fn fromValue(comptime T: type, v: Value) !T {
    if (T == Value) return v;
    if (T == c.mrb_value) return v.v;
    return switch (@typeInfo(T)) {
        .int => blk: {
            if (!c.mrz_integer_p(v.v)) return error.TypeMismatch;
            const n = c.mrz_integer(v.v);
            break :blk std.math.cast(T, n) orelse return error.Overflow;
        },
        .float => blk: {
            if (c.mrz_integer_p(v.v)) {
                break :blk @floatFromInt(c.mrz_integer(v.v));
            }
            if (!c.mrz_float_p(v.v)) return error.TypeMismatch;
            break :blk @as(T, c.mrz_float_v(v.v));
        },
        .bool => c.mrz_test(v.v),
        .optional => |opt| if (v.isNil()) null else try fromValue(opt.child, v),
        .pointer => |info| switch (info.size) {
            .slice => blk: {
                const Elem = info.child;
                if (Elem == u8 and info.attrs.@"const") {
                    if (!c.mrz_string_p(v.v)) return error.TypeMismatch;
                    const p = c.mrz_string_ptr(v.v) orelse return error.TypeMismatch;
                    break :blk p[0..@intCast(c.mrz_string_len(v.v))];
                }
                @compileError("unsupported slice type for fromValue: " ++ @typeName(T));
            },
            else => @compileError("unsupported pointer type for fromValue: " ++ @typeName(T)),
        },
        else => @compileError("unsupported type for fromValue: " ++ @typeName(T)),
    };
}

test "int roundtrip" {
    const mruby = @import("mruby.zig");
    const vm = try mruby.Vm.init();
    defer vm.deinit();
    const v = try toValue(vm.mrb, @as(i32, -42));
    try std.testing.expectEqual(@as(i32, -42), try fromValue(i32, v));
    try std.testing.expectEqual(@as(i64, -42), try fromValue(i64, v));
}

test "float and bool roundtrip" {
    const mruby = @import("mruby.zig");
    const vm = try mruby.Vm.init();
    defer vm.deinit();
    const f = try toValue(vm.mrb, @as(f64, 3.25));
    try std.testing.expectEqual(@as(f64, 3.25), try fromValue(f64, f));

    const t = try toValue(vm.mrb, true);
    const nul = try toValue(vm.mrb, null);
    try std.testing.expectEqual(true, try fromValue(bool, t));
    try std.testing.expectEqual(false, try fromValue(bool, nul));
    try std.testing.expectEqual(@as(?i64, null), try fromValue(?i64, nul));
}

test "string roundtrip" {
    const mruby = @import("mruby.zig");
    const vm = try mruby.Vm.init();
    defer vm.deinit();
    const s = try toValue(vm.mrb, @as([]const u8, "hello"));
    try std.testing.expectEqualStrings("hello", try fromValue([]const u8, s));
    const empty = try toValue(vm.mrb, @as([]const u8, ""));
    try std.testing.expectEqualStrings("", try fromValue([]const u8, empty));
}

test "big integers survive heap boxing" {
    const mruby = @import("mruby.zig");
    const vm = try mruby.Vm.init();
    defer vm.deinit();
    // 2^62 does not fit an inline word-boxed fixnum; exercises the heap
    // RInteger path through the shim.
    const big: i64 = std.math.maxInt(i64);
    const v = try toValue(vm.mrb, big);
    try std.testing.expectEqual(big, try fromValue(i64, v));
}
