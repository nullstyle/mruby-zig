//! Build-time-known application versions for the durable example, plus the
//! single supported upgrade path between them. The host resolves the ledger's
//! active application against this table; nothing about an application is
//! discovered at runtime. Each version pairs one CodeDB bundle with its own
//! contracts, worker executable, and whole-turn shape.
const std = @import("std");
const mruby = @import("mruby");
const View = mruby.artifact.StateCapsuleView;

pub const Descriptor = struct {
    label: []const u8,
    manifest: type,
    entry: []const u8,
    contract: type,
    turn_shape: *const mruby.strict.Turn.Contract,
};

fn shapeOf(comptime contract: type) *const mruby.strict.Turn.Contract {
    return mruby.strict.Turn.Contract.from(contract.turn_contract) catch unreachable;
}

/// The `versions` tuple is comptime-only (it carries module types); runtime
/// lookups go through the helpers below.
pub const versions = .{
    Descriptor{
        .label = "inventory/v1",
        .manifest = @import("durable_manifest_v1"),
        .entry = "inventory",
        .contract = @import("durable_contract_v1"),
        .turn_shape = shapeOf(@import("durable_contract_v1")),
    },
    Descriptor{
        .label = "inventory/v2",
        .manifest = @import("durable_manifest_v2"),
        .entry = "inventory-v2",
        .contract = @import("durable_contract_v2"),
        .turn_shape = shapeOf(@import("durable_contract_v2")),
    },
};

pub const count = versions.len;

pub fn labelAt(ordinal: usize) []const u8 {
    var label: []const u8 = "";
    inline for (versions, 0..) |app, index| {
        if (index == ordinal) label = app.label;
    }
    return label;
}

pub fn ordinalForLabel(label: []const u8) ?usize {
    var found: ?usize = null;
    inline for (versions, 0..) |app, index| {
        if (std.mem.eql(u8, app.label, label)) found = index;
    }
    return found;
}

/// The one supported upgrade. v2 state gains an explicit rejection counter;
/// v1 never recorded rejections, so the upgrade starts it at zero rather than
/// inventing history. The transform is trusted host policy, and its output is
/// still validated against the v2 state contract before publication.
pub const upgrade = struct {
    pub const from: usize = 0;
    pub const to: usize = 1;

    pub fn transformState(allocator: std.mem.Allocator, state: View) !mruby.artifact.StateCapsule {
        const contract = versions[from].contract;
        var document = try mruby.effect.data.Document.decodeWithOptions(allocator, state, .{
            .limits = mruby.effect.data.limits(contract.max_bytes),
            .allow_float = !mruby.features.effects_integer64,
        });
        defer document.deinit();
        const root = document.root();
        if (root.kind() != .hash or try root.len() != 1) return error.InvalidTurnState;
        const attempts = try (try root.get("attempts") orelse return error.InvalidTurnState).asInteger();
        if (attempts < 0) return error.InvalidTurnState;
        return mruby.effect.data.encode(allocator, .{ .hash = &.{
            .{ .key = .{ .string = "attempts" }, .value = .{ .integer = attempts } },
            .{ .key = .{ .string = "rejections" }, .value = .{ .integer = 0 } },
        } }, contract.max_bytes);
    }
};
