//! Tests for the offline schema-2 to schema-3 ledger migration. Schema-2
//! sources are produced by stripping version tables from a real schema-3
//! ledger, so every migrated row is a genuine committed row.
const std = @import("std");
const mruby = @import("mruby");
const host_module = @import("durable_host");
const migrate = @import("durable_migrate");
const contract = @import("durable_contract");
const config = @import("durable_test_config");
const Host = host_module.Host;
const data = mruby.effect.data;
const allocator = std.testing.allocator;

const Paths = struct {
    tmp: std.testing.TmpDir,
    directory: [:0]u8,
    source: []u8,
    target: []u8,
    recipient: []u8,

    fn init() !Paths {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const directory = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
        errdefer allocator.free(directory);
        const source = try std.fs.path.join(allocator, &.{ directory, "schema2.sqlite" });
        errdefer allocator.free(source);
        const target = try std.fs.path.join(allocator, &.{ directory, "migrated.sqlite" });
        errdefer allocator.free(target);
        const recipient = try std.fs.path.join(allocator, &.{ directory, "recipient.sqlite" });
        errdefer allocator.free(recipient);
        return .{ .tmp = tmp, .directory = directory, .source = source, .target = target, .recipient = recipient };
    }
    fn deinit(self: *Paths) void {
        allocator.free(self.directory);
        allocator.free(self.source);
        allocator.free(self.target);
        allocator.free(self.recipient);
        self.tmp.cleanup();
    }
};

const workers = [_][]const u8{ config.worker_executable, config.worker_v2_executable };

fn input(quantity: i64, fail: bool) !mruby.artifact.StateCapsule {
    return data.encode(allocator, .{ .hash = &.{
        .{ .key = .{ .string = "sku" }, .value = .{ .string = "widget" } },
        .{ .key = .{ .string = "quantity" }, .value = .{ .integer = quantity } },
        .{ .key = .{ .string = "fail" }, .value = .{ .boolean = fail } },
    } }, contract.max_bytes);
}

/// Commit one reserved v1 turn (with a pending intent) and one rejected turn,
/// then produce a faithful schema-2 copy: drop the versioned tables and pin
/// the old schema marker. Returns the reserved turn's receipt bytes.
fn buildSchemaTwoSource(paths: *const Paths) ![]u8 {
    var receipt: []u8 = &.{};
    {
        var host = try Host.open(allocator, paths.source, &workers, .{});
        defer host.close();
        var request = try input(2, false);
        defer request.deinit(allocator);
        var reserved = try host.execute(.{ .turn_id = "turn-one", .expected_revision = 0, .input = request.view() });
        defer reserved.deinit();
        receipt = try allocator.dupe(u8, reserved.receipt());
        var failing = try input(9, false);
        defer failing.deinit(allocator);
        var rejected = try host.execute(.{ .turn_id = "turn-rejected", .expected_revision = 1, .input = failing.view() });
        defer rejected.deinit();
    }
    var db = try host_module.sql.Db.open(allocator, paths.source);
    defer db.close();
    try db.exec("DROP TABLE history_chain");
    try db.exec("DROP TABLE turn_versions");
    try db.exec("DROP TABLE upgrades");
    try db.exec("UPDATE durable_metadata SET value='2' WHERE key='schema'");
    return receipt;
}

test "migrating a schema two ledger preserves data receipts and retry identity" {
    var paths = try Paths.init();
    defer paths.deinit();
    const reserved_receipt = try buildSchemaTwoSource(&paths);
    defer allocator.free(reserved_receipt);

    const summary = try migrate.migrate(allocator, paths.source, paths.target, "inventory/v1");
    defer allocator.free(summary.namespace);
    try std.testing.expectEqualStrings("inventory/v1", summary.application);
    try std.testing.expectEqualStrings("demo", summary.namespace);
    try std.testing.expectEqual(@as(i64, 2), summary.revision);
    try std.testing.expectEqual(@as(usize, 2), summary.turns);
    try std.testing.expectEqual(@as(usize, 2), summary.admissions);
    try std.testing.expectEqual(@as(usize, 1), summary.reservations);
    try std.testing.expectEqual(@as(usize, 1), summary.outbox);

    // The source is untouched and still refuses a modern host.
    try std.testing.expectError(error.UnsupportedDurableSchema, Host.open(allocator, paths.source, &workers, .{}));

    var host = try Host.open(allocator, paths.target, &workers, .{});
    defer host.close();
    const status = try host.status();
    try std.testing.expectEqualStrings("inventory/v1", status.application);
    try std.testing.expectEqual(@as(i64, 2), status.revision);
    try std.testing.expectEqual(@as(i64, 2), status.attempts);
    try std.testing.expectEqual(@as(i64, 3), status.stock);
    try std.testing.expectEqual(@as(i64, 2), status.turn_count);
    try std.testing.expectEqual(@as(i64, 1), status.outbox_count);
    try std.testing.expectEqual(@as(i64, 0), status.delivered_count);
    // Every historical turn is pinned to the explicitly named application.
    try std.testing.expectEqual(@as(i64, 2), try host.db.scalar("SELECT count(*) FROM turn_versions v JOIN durable_metadata m ON m.key='application' AND m.value=lower(hex(v.application))"));

    // Retry identity carries over exactly: the committed request reuses its
    // receipt, and its receipt replays bit for bit.
    var request = try input(2, false);
    defer request.deinit(allocator);
    var retry = try host.execute(.{ .turn_id = "turn-one", .expected_revision = 0, .input = request.view() });
    defer retry.deinit();
    try std.testing.expect(retry.reused);
    try std.testing.expectEqual(@as(usize, 0), retry.effect_calls);
    try std.testing.expectEqualSlices(u8, reserved_receipt, retry.receipt());
    var replayed = try host.replay("turn-one");
    defer replayed.deinit();
    try std.testing.expectEqualSlices(u8, reserved_receipt, replayed.receipt());

    // The migrated ledger accepts new work: delivery, a fresh turn, and the
    // documented upgrade path all function normally.
    try std.testing.expectEqual(@as(usize, 1), try host.dispatch(paths.recipient));
    const upgrade = try host.upgrade(.{ .upgrade_id = "migrated-upgrade", .expected_revision = 2, .target = "inventory/v2" });
    try std.testing.expectEqual(@as(i64, 3), upgrade.revision);
    var fresh = try input(1, false);
    defer fresh.deinit(allocator);
    var next = try host.execute(.{ .turn_id = "post-migration", .expected_revision = 3, .input = fresh.view() });
    defer next.deinit();
    try std.testing.expect(!next.reused);
}

test "migration rejects invalid sources and labels before creating a target" {
    var paths = try Paths.init();
    defer paths.deinit();
    const reserved_receipt = try buildSchemaTwoSource(&paths);
    defer allocator.free(reserved_receipt);

    // Unknown application labels never produce provenance.
    try std.testing.expectError(error.UnknownApplication, migrate.migrate(allocator, paths.source, paths.target, "inventory/v9"));

    // A corrupted receipt fails validation and leaves no target ledger.
    {
        var db = try host_module.sql.Db.open(allocator, paths.source);
        defer db.close();
        var update = try db.prepare("UPDATE turns SET receipt=?1 WHERE turn_id='turn-one'");
        defer update.deinit();
        const zeros = std.mem.zeroes([32]u8);
        try update.bindBlob(1, &zeros);
        try std.testing.expectEqual(host_module.sql.Step.done, try update.step());
    }
    var rejected_migration = false;
    if (migrate.migrate(allocator, paths.source, paths.target, "inventory/v1")) |_| {
        return error.ExpectedMigrationFailure;
    } else |_| {
        rejected_migration = true;
    }
    try std.testing.expect(rejected_migration);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().readFileAlloc(std.testing.io, paths.target, allocator, .limited(1)));

    // Schema-3 ledgers are not migration inputs.
    {
        var host = try Host.open(allocator, paths.target, &workers, .{});
        defer host.close();
        var request = try input(2, false);
        defer request.deinit(allocator);
        var modern = try host.execute(.{ .turn_id = "modern", .expected_revision = 0, .input = request.view() });
        defer modern.deinit();
    }
    const rejected = try std.fs.path.join(allocator, &.{ paths.directory, "rejected.sqlite" });
    defer allocator.free(rejected);
    try std.testing.expectError(error.UnsupportedDurableSchema, migrate.migrate(allocator, paths.target, rejected, "inventory/v1"));
}
