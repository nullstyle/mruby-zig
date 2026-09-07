//! Durable strict turns with a disk-backed SQLite transaction and local outbox,
//! plus one explicit application upgrade from inventory/v1 to inventory/v2.
//!   zig build run-effects-durable -Deffects-strict=true -Dsqlite-effects=true
//! Installed usage: effects-durable /path/effects-durable-child /path/effects-durable-child-v2 [directory]
const std = @import("std");
const mruby = @import("mruby");
const durable = @import("durable_host");
const contract = @import("durable_contract");
const data = mruby.effect.data;
const testing = std.testing;

extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;

fn inputCapsule(allocator: std.mem.Allocator, quantity: i64) !mruby.artifact.StateCapsule {
    return data.encode(allocator, .{ .hash = &.{
        .{ .key = .{ .string = "sku" }, .value = .{ .string = "widget" } },
        .{ .key = .{ .string = "quantity" }, .value = .{ .integer = quantity } },
        .{ .key = .{ .string = "fail" }, .value = .{ .boolean = false } },
    } }, contract.max_bytes);
}

/// Final ledger state once this demo has run against a directory, whether it
/// committed fresh or reused an earlier run's decisions.
const final_status = durable.Status{
    .application = "inventory/v2",
    .revision = 3,
    .attempts = 2,
    .stock = 3,
    .turn_count = 2,
    .reservation_count = 1,
    .outbox_count = 1,
    .delivered_count = 1,
};

fn expectStatus(status: durable.Status) !void {
    const info = @typeInfo(durable.Status).@"struct";
    inline for (info.field_names, info.field_types) |name, FieldType| {
        if (FieldType == i64) {
            try testing.expectEqual(@field(final_status, name), @field(status, name));
        } else {
            try testing.expectEqualStrings(@field(final_status, name), @field(status, name));
        }
    }
}

/// Run repeatedly against a dedicated directory. A completed prior run reuses
/// its turn, upgrade, and delivery decisions without repeating any effect.
pub fn verify(allocator: std.mem.Allocator, database_path: []const u8, recipient_path: []const u8, worker_executable: []const u8, worker_v2_executable: []const u8) !void {
    const workers = [_][]const u8{ worker_executable, worker_v2_executable };
    var input = try inputCapsule(allocator, 2);
    defer input.deinit(allocator);
    const request: durable.Request = .{ .turn_id = "demo-reservation", .expected_revision = 0, .input = input.view() };
    var first_receipt: []u8 = &.{};
    defer if (first_receipt.len != 0) allocator.free(first_receipt);
    {
        var host = try durable.Host.open(allocator, database_path, &workers, .{});
        defer host.close();
        const initial = try host.status();
        if (std.mem.eql(u8, initial.application, "inventory/v1")) {
            // First run: commit the v1 reservation turn, then verify its retry,
            // conflicts, and replay against the ledger that produced it.
            var first = try host.execute(request);
            defer first.deinit();
            try testing.expect(!first.reused);
            try testing.expectEqual(@as(usize, 2), first.effect_calls);
            first_receipt = try allocator.dupe(u8, first.receipt());
            try testing.expectEqual(@as(i64, 1), first.revision);
            var terminal = try data.Document.decode(allocator, first.terminal(), contract.max_bytes);
            defer terminal.deinit();
            const reservation = (try (try terminal.root().at(0)).get("reservation")).?;
            try testing.expectEqualStrings("widget", try (try reservation.get("sku")).?.asString());
            try testing.expectEqual(@as(i64, 3), try (try reservation.get("remaining")).?.asInteger());
            var retry = try host.execute(request);
            defer retry.deinit();
            try testing.expect(retry.reused);
            try testing.expectEqual(@as(usize, 0), retry.effect_calls);
            var replayed = try host.replay(request.turn_id);
            defer replayed.deinit();
            try testing.expectEqualSlices(u8, first.receipt(), replayed.receipt());
            const delivered = try host.dispatch(recipient_path);
            try testing.expectEqual(@as(usize, 1), delivered);
        } else {
            // Later runs: the committed v1 request can no longer be reissued
            // as a new turn, because the active application moved on.
            try testing.expectEqualStrings("inventory/v2", initial.application);
            try testing.expectError(error.TurnIdConflict, host.execute(request));
            const delivered = try host.dispatch(recipient_path);
            try testing.expectEqual(@as(usize, 0), delivered);
        }
    }

    // The explicit upgrade is idempotent: a committed record answers retries.
    var rejection: mruby.artifact.StateCapsule = undefined;
    {
        var host = try durable.Host.open(allocator, database_path, &workers, .{});
        defer host.close();
        const upgrade = try host.upgrade(.{ .upgrade_id = "demo-upgrade", .expected_revision = 1, .target = "inventory/v2" });
        try testing.expectEqual(@as(i64, 2), upgrade.revision);
        try testing.expectEqualStrings("inventory/v2", upgrade.application);
        const retry = try host.upgrade(.{ .upgrade_id = "demo-upgrade", .expected_revision = 1, .target = "inventory/v2" });
        try testing.expect(retry.reused);
        try testing.expectEqual(@as(i64, 2), retry.revision);
        try testing.expectError(error.UpgradeIdConflict, host.upgrade(.{ .upgrade_id = "demo-upgrade", .expected_revision = 2, .target = "inventory/v2" }));

        // New turns run as v2. Requesting more than the remaining stock is a
        // declared business rejection; v2 state records it explicitly.
        rejection = try inputCapsule(allocator, 9);
        var second = try host.execute(.{ .turn_id = "demo-v2-rejection", .expected_revision = 2, .input = rejection.view() });
        defer second.deinit();
        try testing.expectEqual(@as(i64, 3), second.revision);
        try testing.expectEqual(@as(usize, if (second.reused) 0 else 1), second.effect_calls);
        var terminal = try data.Document.decode(allocator, second.terminal(), contract.max_bytes);
        defer terminal.deinit();
        try testing.expectEqualStrings("rejected", try (try (try terminal.root().at(0)).get("status")).?.asString());
        try testing.expectEqualStrings("OutOfStock", try (try (try terminal.root().at(0)).get("code")).?.asString());
        try testing.expectEqual(@as(i64, 2), try (try (try terminal.root().at(1)).get("attempts")).?.asInteger());
        try testing.expectEqual(@as(i64, 1), try (try (try terminal.root().at(1)).get("rejections")).?.asInteger());

        // Historical replay still routes to the v1 bundle that committed it.
        var historical = try host.replay("demo-reservation");
        defer historical.deinit();
        if (first_receipt.len != 0) try testing.expectEqualSlices(u8, first_receipt, historical.receipt());
        try expectStatus(try host.status());
    }
    rejection.deinit(allocator);
    var recipient = try durable.sql.Db.open(allocator, recipient_path);
    defer recipient.close();
    try testing.expectEqual(@as(i64, 1), try recipient.scalar("SELECT count FROM notification_counter WHERE singleton=1"));
    try testing.expectEqual(@as(i64, 1), try recipient.scalar("SELECT COUNT(*) FROM receipts"));
}

pub fn main(init: std.process.Init) !void {
    var arguments = init.minimal.args.iterate();
    _ = arguments.next();
    const worker = arguments.next() orelse return error.MissingWorkerExecutable;
    const worker_v2 = arguments.next() orelse return error.MissingSecondWorkerExecutable;
    const requested_directory = arguments.next();
    if (arguments.next() != null) return error.UnexpectedArgument;
    const directory = if (requested_directory) |path| blk: {
        try std.Io.Dir.cwd().createDirPath(init.io, path);
        break :blk try init.gpa.dupeSentinel(u8, path, 0);
    } else blk: {
        const template = try init.gpa.dupeSentinel(u8, "/tmp/mruby-effects-durable-XXXXXX", 0);
        errdefer init.gpa.free(template);
        if (mkdtemp(template.ptr) == null) return error.TemporaryDirectoryFailed;
        break :blk template;
    };
    defer init.gpa.free(directory);
    defer if (requested_directory == null) std.Io.Dir.cwd().deleteTree(init.io, directory) catch {};
    const database_path = try std.fs.path.join(init.gpa, &.{ directory, "inventory.sqlite" });
    defer init.gpa.free(database_path);
    const recipient_path = try std.fs.path.join(init.gpa, &.{ directory, "recipient.sqlite" });
    defer init.gpa.free(recipient_path);
    try verify(init.gpa, database_path, recipient_path, worker, worker_v2);
    std.debug.print("durable turns: the v1 application reserved stock 5 -> 3 and staged one notification atomically\n", .{});
    std.debug.print("durable upgrade: inventory/v2 published {{attempts, rejections}} state and its provenance; retries reuse the decision\n", .{});
    std.debug.print("durable turns: a v2 rejection advanced the new counter; the v1 receipt still replayed on its original bundle\n", .{});
    std.debug.print("durable turns: dispatch delivered the pending v1 intent exactly once across runs\n", .{});
    if (requested_directory != null) std.debug.print("durable turns: databases retained in {s}\n", .{directory});
}
