//! Complete turn contracts are plain shared literals compiled into owned data.
//! Each state/input/result shape reuses the operation schema implementation;
//! next_state deliberately validates against the same state shape.
const std = @import("std");
const schema = @import("effect_schema.zig");

pub const CompileError = error{InvalidTurnContract};
// Diagnostic wire ABI: append only until that codec's version changes.
pub const Side = enum(u8) { state = 0, input = 1, result = 2, next_state = 3 };
pub const Mismatch = struct { side: Side, detail: schema.ValueMismatch };

pub const Contract = struct {
    state: schema.Shape,
    input: schema.Shape,
    result: schema.Shape,

    pub fn from(comptime literal: anytype) CompileError!*const Contract {
        return fromStatic(literal);
    }

    pub fn digest(self: *const Contract) [32]u8 {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("mruby-zig/turn-contract/v1\x00");
        hash.update(&self.state.digest());
        hash.update(&self.input.digest());
        hash.update(&self.result.digest());
        return hash.finalResult();
    }
    pub fn validate(self: *const Contract, side: Side, ref: anytype) ?Mismatch {
        const shape = switch (side) {
            .state, .next_state => &self.state,
            .input => &self.input,
            .result => &self.result,
        };
        const detail = shape.validate(ref) orelse return null;
        return .{ .side = side, .detail = detail };
    }
    /// Runtime admission takes this checked owned copy before hashing or any
    /// callbacks. The returned value borrows nothing from the original.
    pub fn checkedCopy(self: *const Contract) CompileError!Contract {
        var copied = self.*;
        copied.state = copied.state.checkedCopy() catch return error.InvalidTurnContract;
        copied.input = copied.input.checkedCopy() catch return error.InvalidTurnContract;
        copied.result = copied.result.checkedCopy() catch return error.InvalidTurnContract;
        return copied;
    }
    /// Readable only at comptime; the returned pointer refers to owned static
    /// storage. Runtime-only pointer inputs cannot escape as a shared contract.
    pub fn snapshot(comptime pointer: *const Contract) CompileError!*const Contract {
        @setEvalBranchQuota(600_000);
        const checked = comptime pointer.checkedCopy();
        if (checked) |copied| {
            return &struct {
                const stored = copied;
            }.stored;
        } else |err| return err;
    }
};

pub fn compile(comptime literal: anytype) CompileError!Contract {
    @setEvalBranchQuota(600_000);
    const info = @typeInfo(@TypeOf(literal));
    if (info != .@"struct") return error.InvalidTurnContract;
    if (info.@"struct".field_names.len != 3 or !@hasField(@TypeOf(literal), "state") or !@hasField(@TypeOf(literal), "input") or !@hasField(@TypeOf(literal), "result")) return error.InvalidTurnContract;
    return .{
        .state = schema.compileShape(literal.state) catch return error.InvalidTurnContract,
        .input = schema.compileShape(literal.input) catch return error.InvalidTurnContract,
        .result = schema.compileShape(literal.result) catch return error.InvalidTurnContract,
    };
}

/// Compile a plain shared literal, or snapshot an already compiled static
/// pointer. Optional/absent declarations are handled by the caller.
pub fn from(comptime literal: anytype) CompileError!*const Contract {
    return fromStatic(literal);
}

fn fromStatic(comptime literal: anytype) CompileError!*const Contract {
    @setEvalBranchQuota(600_000);
    if (@TypeOf(literal) == *const Contract or @TypeOf(literal) == *Contract) return Contract.snapshot(literal);
    const compiled = comptime compile(literal);
    if (compiled) |value| {
        return &struct {
            const stored = value;
        }.stored;
    } else |err| return err;
}

test "turn contracts normalize shared literals and keep identity bound to all three shapes" {
    const nils = comptime try compile(.{ .state = .nil, .input = .nil, .result = .nil });
    try std.testing.expectEqualStrings("c1f344dfa883eb6f80d5f3e5221483c1f6affd59e1c6f212cd4d83cb09c70600", &std.fmt.bytesToHex(nils.state.digest(), .lower));
    try std.testing.expectEqualStrings("24710efa7cfdb9d47933c5610f68528ba2b39e48447f1cf6cefd1c3ac4a6b9e5", &std.fmt.bytesToHex(nils.digest(), .lower));
    const count = .{ .integer = .{ .min = 0, .max = 100 } };
    const literal = .{ .state = count, .input = .boolean, .result = .nil };
    const first = comptime try compile(literal);
    const stable = comptime try from(literal);
    const normalized = comptime try from(stable);
    try std.testing.expectEqualSlices(u8, &first.digest(), &normalized.digest());
    inline for (.{
        .{ .state = .integer, .input = .boolean, .result = .nil },
        .{ .state = count, .input = .nil, .result = .nil },
        .{ .state = count, .input = .boolean, .result = .boolean },
    }) |changed| {
        const value = comptime try compile(changed);
        try std.testing.expect(!std.mem.eql(u8, &first.digest(), &value.digest()));
    }
    const reordered = comptime try compile(.{ .result = .nil, .input = .boolean, .state = count });
    try std.testing.expectEqualSlices(u8, &first.digest(), &reordered.digest());
}

test "turn contracts reject malformed declarations and malformed normalized graphs" {
    inline for (.{
        .{},
        .{ .state = .nil, .input = .nil },
        .{ .state = .nil, .input = .nil, .result = .nil, .next_state = .integer },
        .{ .state = .wat, .input = .nil, .result = .nil },
        .{ .state = .nil, .input = .{ .array = .{ .element = .integer } }, .result = .nil },
        .{ .state = .nil, .input = .nil, .result = .{ .integer = .{ .min = 2, .max = 1 } } },
    }) |literal| {
        try std.testing.expectError(error.InvalidTurnContract, compile(literal));
        try std.testing.expectError(error.InvalidTurnContract, from(literal));
    }
    var mutable = try compile(.{ .state = .nil, .input = .nil, .result = .nil });
    mutable.result.graph.roots[0] = 1000;
    try std.testing.expectError(error.InvalidTurnContract, mutable.checkedCopy());
    const malformed = comptime blk: {
        var value = try compile(.{ .state = .nil, .input = .nil, .result = .nil });
        value.input.graph.roots[0] = 1000;
        break :blk value;
    };
    try std.testing.expectError(error.InvalidTurnContract, Contract.from(&malformed));
}

test "turn contract admission copies are independent of later mutable host storage" {
    var mutable = try compile(.{ .state = .integer, .input = .boolean, .result = .nil });
    const copied = try mutable.checkedCopy();
    const original_digest = copied.digest();
    mutable = try compile(.{ .state = .nil, .input = .nil, .result = .nil });
    try std.testing.expect(!std.mem.eql(u8, &original_digest, &mutable.digest()));
    try std.testing.expectEqualSlices(u8, &original_digest, &copied.digest());
    const static_copy = comptime blk: {
        var original = try compile(.{ .state = .integer, .input = .boolean, .result = .nil });
        const stored = try from(&original);
        original.state.graph.roots[0] = 1000;
        break :blk stored;
    };
    try std.testing.expectEqualSlices(u8, &original_digest, &static_copy.digest());
}
