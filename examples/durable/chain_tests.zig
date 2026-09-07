//! Tamper-evident history-chain tests for the durable example: append
//! coverage across turns and upgrades, survival across pruning and
//! migration, and detection of rewritten or reordered history.
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
    database: []u8,
    recipient: []u8,
    archive: []u8,

    fn init() !Paths {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const directory = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
        errdefer allocator.free(directory);
        const database = try std.fs.path.join(allocator, &.{ directory, "source.sqlite" });
        errdefer allocator.free(database);
        const recipient = try std.fs.path.join(allocator, &.{ directory, "recipient.sqlite" });
        errdefer allocator.free(recipient);
        const archive = try std.fs.path.join(allocator, &.{ directory, "chain-archive.jsonl" });
        errdefer allocator.free(archive);
        return .{ .tmp = tmp, .directory = directory, .database = database, .recipient = recipient, .archive = archive };
    }
    fn deinit(self: *Paths) void {
        allocator.free(self.directory);
        allocator.free(self.database);
        allocator.free(self.recipient);
        allocator.free(self.archive);
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

fn openHost(paths: *const Paths) !Host {
    return Host.open(allocator, paths.database, &workers, .{ .io = std.testing.io });
}

test "turns and upgrades append to one contiguous verifiable chain" {
    var paths = try Paths.init();
    defer paths.deinit();
    var host = try openHost(&paths);
    defer host.close();

    var empty = try host.verifyChain();
    try std.testing.expectEqual(@as(usize, 0), empty.entries);
    try std.testing.expectEqual(@as(i64, 0), empty.head_revision);
    try std.testing.expectEqualSlices(u8, &(@as([32]u8, @splat(0))), &empty.head_digest);

    var request = try input(2, false);
    defer request.deinit(allocator);
    var turn_one = try host.execute(.{ .turn_id = "turn-one", .expected_revision = 0, .input = request.view() });
    defer turn_one.deinit();
    _ = try host.upgrade(.{ .upgrade_id = "upgrade-one", .expected_revision = 1, .target = "inventory/v2" });
    var failing = try input(9, false);
    defer failing.deinit(allocator);
    var rejected = try host.execute(.{ .turn_id = "v2-rejected", .expected_revision = 2, .input = failing.view() });
    defer rejected.deinit();

    var first = try host.verifyChain();
    try std.testing.expectEqual(@as(usize, 3), first.entries);
    try std.testing.expectEqual(@as(i64, 3), first.head_revision);
    var again = try host.verifyChain();
    try std.testing.expectEqualSlices(u8, &first.head_digest, &again.head_digest);
    try std.testing.expectEqual(@as(i64, 3), try host.db.scalar("SELECT count(*) FROM history_chain"));

    // Chain rows survive pruning: the archived turn's link stays verifiable
    // even though its live row and receipt are gone.
    try std.testing.expectEqual(@as(usize, 1), try host.dispatch(paths.recipient));
    _ = try host.prune(.{ .before_revision = 3, .archive_path = paths.archive });
    var after = try host.verifyChain();
    try std.testing.expectEqual(@as(usize, 3), after.entries);
    try std.testing.expectEqual(@as(i64, 3), after.head_revision);
    try std.testing.expectEqualSlices(u8, &first.head_digest, &after.head_digest);
    try std.testing.expectEqual(@as(i64, 1), try host.db.scalar("SELECT count(*) FROM history_chain WHERE kind=0 AND record_id='turn-one'"));
}

test "rewritten or reordered history fails chain verification" {
    // A receipt rewritten in place no longer matches its chained subject.
    {
        var paths = try Paths.init();
        defer paths.deinit();
        var host = try openHost(&paths);
        defer host.close();
        var request = try input(2, false);
        defer request.deinit(allocator);
        var turn_one = try host.execute(.{ .turn_id = "turn-one", .expected_revision = 0, .input = request.view() });
        defer turn_one.deinit();
        _ = try host.verifyChain();
        {
            var db = try host_module.sql.Db.open(allocator, paths.database);
            defer db.close();
            var tampered_bytes: []u8 = undefined;
            {
                var query = try db.prepare("SELECT receipt FROM turns WHERE turn_id='turn-one'");
                defer query.deinit();
                try std.testing.expectEqual(host_module.sql.Step.row, try query.step());
                const original = try query.blob(0);
                tampered_bytes = try allocator.alloc(u8, original.len + 1);
                defer allocator.free(tampered_bytes);
                @memcpy(tampered_bytes[0..original.len], original);
                tampered_bytes[original.len] = 0;
                var update = try db.prepare("UPDATE turns SET receipt=?1 WHERE turn_id='turn-one'");
                defer update.deinit();
                try update.bindBlob(1, tampered_bytes);
                try std.testing.expectEqual(host_module.sql.Step.done, try update.step());
                try std.testing.expect(db.changes() > 0);
            }
        }
        try std.testing.expectError(error.ChainRewritten, host.verifyChain());
    }
    // Removing a middle link breaks the chain's own linkage and numbering.
    {
        var paths = try Paths.init();
        defer paths.deinit();
        var host = try openHost(&paths);
        defer host.close();
        var request = try input(2, false);
        defer request.deinit(allocator);
        var turn_one = try host.execute(.{ .turn_id = "turn-one", .expected_revision = 0, .input = request.view() });
        defer turn_one.deinit();
        var smaller = try input(1, false);
        defer smaller.deinit(allocator);
        var turn_two = try host.execute(.{ .turn_id = "turn-two", .expected_revision = 1, .input = smaller.view() });
        defer turn_two.deinit();
        _ = try host.verifyChain();
        {
            var db = try host_module.sql.Db.open(allocator, paths.database);
            defer db.close();
            try db.exec("DELETE FROM history_chain WHERE revision=1");
        }
        try std.testing.expectError(error.ChainBroken, host.verifyChain());
    }
}

test "migrated ledgers carry a complete chain from genesis" {
    var paths = try Paths.init();
    defer paths.deinit();
    var receipt: []u8 = &.{};
    defer if (receipt.len != 0) allocator.free(receipt);
    {
        var host = try openHost(&paths);
        defer host.close();
        var request = try input(2, false);
        defer request.deinit(allocator);
        var committed = try host.execute(.{ .turn_id = "turn-one", .expected_revision = 0, .input = request.view() });
        defer committed.deinit();
        receipt = try allocator.dupe(u8, committed.receipt());
        var failing = try input(9, false);
        defer failing.deinit(allocator);
        var rejected = try host.execute(.{ .turn_id = "turn-rejected", .expected_revision = 1, .input = failing.view() });
        defer rejected.deinit();
    }
    {
        var db = try host_module.sql.Db.open(allocator, paths.database);
        defer db.close();
        try db.exec("DROP TABLE history_chain");
        try db.exec("DROP TABLE turn_versions");
        try db.exec("DROP TABLE upgrades");
        try db.exec("UPDATE durable_metadata SET value='2' WHERE key='schema'");
    }
    const migrated_path = try std.fs.path.join(allocator, &.{ paths.directory, "migrated.sqlite" });
    defer allocator.free(migrated_path);
    const summary = try migrate.migrate(allocator, paths.database, migrated_path, "inventory/v1");
    defer allocator.free(summary.namespace);
    try std.testing.expectEqual(@as(usize, 2), summary.turns);

    var host = try Host.open(allocator, migrated_path, &workers, .{});
    defer host.close();
    const chain = try host.verifyChain();
    try std.testing.expectEqual(@as(usize, 2), chain.entries);
    try std.testing.expectEqual(@as(i64, 2), chain.head_revision);
    // The chained subject of the first turn is exactly its original receipt.
    var subject: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(receipt, &subject, .{});
    {
        var query = try host.db.prepare("SELECT subject FROM history_chain WHERE revision=1");
        defer query.deinit();
        try std.testing.expectEqual(host_module.sql.Step.row, try query.step());
        try std.testing.expectEqualSlices(u8, &subject, try query.blob(0));
    }
    // New work extends the migrated chain instead of starting a new one.
    var fresh = try input(1, false);
    defer fresh.deinit(allocator);
    var post = try host.execute(.{ .turn_id = "post-migration", .expected_revision = 2, .input = fresh.view() });
    defer post.deinit();
    const extended = try host.verifyChain();
    try std.testing.expectEqual(@as(usize, 3), extended.entries);
    try std.testing.expectEqual(@as(i64, 3), extended.head_revision);
}
