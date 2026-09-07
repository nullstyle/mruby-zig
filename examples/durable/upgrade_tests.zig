//! Application-upgrade and historical-replay tests for the durable example.
//! These exercise the explicit upgrade operation, its failure and crash
//! recovery, retry identity across the upgrade, and per-turn replay routing
//! through the public host interface.
const std = @import("std");
const mruby = @import("mruby");
const host_module = @import("durable_host");
const contract = @import("durable_contract");
const config = @import("durable_test_config");
const harness = @import("crash_harness.zig");
const Host = host_module.Host;
const data = mruby.effect.data;
const allocator = std.testing.allocator;

const Paths = struct {
    tmp: std.testing.TmpDir,
    directory: [:0]u8,
    database: []u8,
    recipient: []u8,
    missing_worker_second: []u8,

    fn init() !Paths {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const directory = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
        errdefer allocator.free(directory);
        const database = try std.fs.path.join(allocator, &.{ directory, "source.sqlite" });
        errdefer allocator.free(database);
        const recipient = try std.fs.path.join(allocator, &.{ directory, "recipient.sqlite" });
        errdefer allocator.free(recipient);
        const missing_worker_second = try std.fs.path.join(allocator, &.{ directory, "absent-worker-2" });
        errdefer allocator.free(missing_worker_second);
        return .{ .tmp = tmp, .directory = directory, .database = database, .recipient = recipient, .missing_worker_second = missing_worker_second };
    }
    fn deinit(self: *Paths) void {
        allocator.free(self.directory);
        allocator.free(self.database);
        allocator.free(self.recipient);
        allocator.free(self.missing_worker_second);
        self.tmp.cleanup();
    }
    fn upgradeCrash(self: *const Paths, phase: contract.Phase) !harness.Process {
        return harness.Process.start(allocator, config.upgrade_crash_fixture_executable, self.database, config.worker_executable, config.worker_v2_executable, @tagName(phase), 1, self.recipient);
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

const Expected = struct {
    application: []const u8 = "inventory/v1",
    revision: i64 = 0,
    attempts: i64 = 0,
    stock: i64 = 5,
    turn_count: i64 = 0,
    reservation_count: i64 = 0,
    outbox_count: i64 = 0,
    delivered_count: i64 = 0,
};

fn expectStatus(host: *Host, expected: Expected) !void {
    const actual = try host.status();
    try std.testing.expectEqualStrings(expected.application, actual.application);
    inline for (.{ "revision", "attempts", "stock", "turn_count", "reservation_count", "outbox_count", "delivered_count" }) |field|
        try std.testing.expectEqual(@field(expected, field), @field(actual, field));
}

const v1_reserved: Expected = .{ .revision = 1, .attempts = 1, .stock = 3, .turn_count = 1, .reservation_count = 1, .outbox_count = 1 };
const upgraded: Expected = .{ .application = "inventory/v2", .revision = 2, .attempts = 1, .stock = 3, .turn_count = 1, .reservation_count = 1, .outbox_count = 1 };

const Observer = struct {
    begins: usize = 0,
    effects: usize = 0,
    admissions: usize = 0,
    fn hit(raw: ?*anyopaque, phase: contract.Phase) void {
        const self: *Observer = @ptrCast(@alignCast(raw.?));
        if (phase == .after_admission) self.admissions += 1;
        if (phase == .after_begin) self.begins += 1;
        if (phase == .after_effect) self.effects += 1;
    }
    fn checkpoint(self: *Observer) contract.Checkpoint {
        return .{ .context = self, .hit = hit };
    }
};

fn commitFirstTurn(host: *Host) !void {
    var request = try input(2, false);
    defer request.deinit(allocator);
    var result = try host.execute(.{ .turn_id = "turn-one", .expected_revision = 0, .input = request.view() });
    defer result.deinit();
    try std.testing.expectEqual(@as(i64, 1), result.revision);
}

test "explicit upgrade publishes state identity and provenance atomically" {
    var paths = try Paths.init();
    defer paths.deinit();
    {
        var host = try Host.open(allocator, paths.database, &workers, .{});
        defer host.close();
        try commitFirstTurn(&host);
        try expectStatus(&host, v1_reserved);

        const upgrade = try host.upgrade(.{ .upgrade_id = "upgrade-one", .expected_revision = 1, .target = "inventory/v2" });
        try std.testing.expect(!upgrade.reused);
        try std.testing.expectEqual(@as(i64, 2), upgrade.revision);
        try std.testing.expectEqualStrings("inventory/v2", upgrade.application);
        try expectStatus(&host, upgraded);

        // The transformed state is exactly the v1 attempt count plus the declared
        // initial rejection counter; provenance binds both application identities
        // and the active pin names the upgrade target.
        try std.testing.expectEqual(@as(i64, 1), try host.db.scalar("SELECT count(*) FROM upgrades"));
        try std.testing.expectEqual(@as(i64, 1), try host.db.scalar("SELECT starting_revision FROM upgrades WHERE upgrade_id='upgrade-one'"));
        try std.testing.expectEqual(@as(i64, 2), try host.db.scalar("SELECT revision FROM upgrades WHERE upgrade_id='upgrade-one'"));
        try std.testing.expectEqual(@as(i64, 1), try host.db.scalar("SELECT count(*) FROM upgrades u JOIN durable_metadata m ON m.key='application' AND m.value=lower(hex(u.to_application))"));
        {
            var current = try host.db.prepare("SELECT state FROM current_state WHERE id=1");
            defer current.deinit();
            try std.testing.expectEqual(host_module.sql.Step.row, try current.step());
            const state_bytes = try current.copyBlob(allocator, 0, contract.max_bytes);
            defer allocator.free(state_bytes);
            var state = try data.Document.decode(allocator, .{ .bytes = state_bytes }, contract.max_bytes);
            defer state.deinit();
            try std.testing.expectEqual(@as(i64, 1), try (try state.root().get("attempts")).?.asInteger());
            try std.testing.expectEqual(@as(i64, 0), try (try state.root().get("rejections")).?.asInteger());
        }

        // Retrying the committed upgrade resolves the original decision; a changed
        // expectation under the same ID is a different request and conflicts.
        const retry = try host.upgrade(.{ .upgrade_id = "upgrade-one", .expected_revision = 1, .target = "inventory/v2" });
        try std.testing.expect(retry.reused);
        try std.testing.expectEqual(@as(i64, 2), retry.revision);
        try std.testing.expectError(error.UpgradeIdConflict, host.upgrade(.{ .upgrade_id = "upgrade-one", .expected_revision = 2, .target = "inventory/v2" }));
        try expectStatus(&host, upgraded);
    }
    // Reopening keeps the upgraded version and state.
    var reopened = try Host.open(allocator, paths.database, &workers, .{});
    defer reopened.close();
    try expectStatus(&reopened, upgraded);

    // New turns run as v2: a declared rejection advances the new counter while
    // the attempt count keeps tracking every turn.
    var failing = try input(9, false);
    defer failing.deinit(allocator);
    var rejected = try reopened.execute(.{ .turn_id = "v2-rejected", .expected_revision = 2, .input = failing.view() });
    defer rejected.deinit();
    try std.testing.expect(!rejected.reused);
    try std.testing.expectEqual(@as(usize, 1), rejected.effect_calls);
    var terminal = try data.Document.decode(allocator, rejected.terminal(), contract.max_bytes);
    defer terminal.deinit();
    try std.testing.expectEqualStrings("rejected", try (try (try terminal.root().at(0)).get("status")).?.asString());
    try std.testing.expectEqualStrings("OutOfStock", try (try (try terminal.root().at(0)).get("code")).?.asString());
    try std.testing.expectEqual(@as(i64, 2), try (try (try terminal.root().at(1)).get("attempts")).?.asInteger());
    try std.testing.expectEqual(@as(i64, 1), try (try (try terminal.root().at(1)).get("rejections")).?.asInteger());
    try expectStatus(&reopened, .{ .application = "inventory/v2", .revision = 3, .attempts = 2, .stock = 3, .turn_count = 2, .reservation_count = 1, .outbox_count = 1 });

    var reserved = try input(1, false);
    defer reserved.deinit(allocator);
    var second = try reopened.execute(.{ .turn_id = "v2-reserved", .expected_revision = 3, .input = reserved.view() });
    defer second.deinit();
    try std.testing.expect(!second.reused);
    try expectStatus(&reopened, .{ .application = "inventory/v2", .revision = 4, .attempts = 3, .stock = 2, .turn_count = 3, .reservation_count = 2, .outbox_count = 2 });
}

test "upgrade attempts fail closed on unknown targets, wrong direction, and stale revisions" {
    var paths = try Paths.init();
    defer paths.deinit();
    var host = try Host.open(allocator, paths.database, &workers, .{});
    defer host.close();
    try commitFirstTurn(&host);

    try std.testing.expectError(error.UnknownApplication, host.upgrade(.{ .upgrade_id = "bad-target", .expected_revision = 1, .target = "inventory/v3" }));
    try std.testing.expectError(error.UnsupportedApplicationUpgrade, host.upgrade(.{ .upgrade_id = "bad-target", .expected_revision = 1, .target = "inventory/v1" }));
    try std.testing.expectError(error.StaleState, host.upgrade(.{ .upgrade_id = "bad-target", .expected_revision = 0, .target = "inventory/v2" }));
    try std.testing.expectError(error.InvalidName, host.upgrade(.{ .upgrade_id = "", .expected_revision = 1, .target = "inventory/v2" }));
    try expectStatus(&host, v1_reserved);
    try std.testing.expectEqual(@as(i64, 0), try host.db.scalar("SELECT count(*) FROM upgrades"));

    // An admitted v1 request that failed execution stays bound to v1 identity.
    var failing = try input(2, true);
    defer failing.deinit(allocator);
    try std.testing.expectError(error.RubyException, host.execute(.{ .turn_id = "failed-v1", .expected_revision = 1, .input = failing.view() }));
    try std.testing.expectEqual(@as(i64, 2), try host.db.scalar("SELECT count(*) FROM admissions"));

    const upgrade = try host.upgrade(.{ .upgrade_id = "upgrade-one", .expected_revision = 1, .target = "inventory/v2" });
    try std.testing.expectEqual(@as(i64, 2), upgrade.revision);

    // Already upgraded: further or reversed upgrades are unsupported.
    try std.testing.expectError(error.UnsupportedApplicationUpgrade, host.upgrade(.{ .upgrade_id = "upgrade-two", .expected_revision = 2, .target = "inventory/v2" }));
    try std.testing.expectError(error.UnsupportedApplicationUpgrade, host.upgrade(.{ .upgrade_id = "downgrade", .expected_revision = 2, .target = "inventory/v1" }));

    // Old requests cannot become new requests merely because the active
    // application changed: both committed and admitted v1 IDs now conflict
    // instead of being reinterpreted or re-executed under v2.
    var request = try input(2, false);
    defer request.deinit(allocator);
    try std.testing.expectError(error.TurnIdConflict, host.execute(.{ .turn_id = "turn-one", .expected_revision = 0, .input = request.view() }));
    try std.testing.expectError(error.TurnIdConflict, host.execute(.{ .turn_id = "failed-v1", .expected_revision = 1, .input = failing.view() }));
    try expectStatus(&host, upgraded);
}

test "unresolvable pinned applications fail closed at open without changing storage" {
    const variants = [_]struct { value: ?[]const u8, err: anyerror }{
        // Missing provenance is never invented.
        .{ .value = null, .err = error.UnknownApplication },
        // An unknown pinned identity is not this build's application.
        .{ .value = "0000000000000000000000000000000000000000000000000000000000000000", .err = error.ApplicationIdentityMismatch },
        .{ .value = "zz", .err = error.UnknownApplication },
    };
    for (variants) |variant| {
        var paths = try Paths.init();
        defer paths.deinit();
        {
            var host = try Host.open(allocator, paths.database, &workers, .{});
            defer host.close();
            try expectStatus(&host, .{});
        }
        {
            var db = try host_module.sql.Db.open(allocator, paths.database);
            defer db.close();
            if (variant.value) |value| {
                var update = try db.prepare("UPDATE durable_metadata SET value=?1 WHERE key='application'");
                defer update.deinit();
                try update.bindText(1, value);
                try std.testing.expectEqual(host_module.sql.Step.done, try update.step());
                try std.testing.expectEqual(@as(i64, 1), db.changes());
            } else {
                try db.exec("DELETE FROM durable_metadata WHERE key='application'");
            }
        }
        try std.testing.expectError(variant.err, Host.open(allocator, paths.database, &workers, .{}));
        var db = try host_module.sql.Db.open(allocator, paths.database);
        defer db.close();
        try std.testing.expectEqual(@as(i64, 0), try db.scalar("SELECT count(*) FROM upgrades"));
        try std.testing.expectEqual(@as(i64, 0), try db.scalar("SELECT count(*) FROM turns"));
    }
}

test "SIGKILL around upgrade publication recovers the original decision" {
    for ([_]contract.Phase{ .before_upgrade_commit, .after_upgrade_commit }) |phase| {
        var paths = try Paths.init();
        defer paths.deinit();
        {
            var host = try Host.open(allocator, paths.database, &workers, .{});
            defer host.close();
            try commitFirstTurn(&host);
        }
        var child = try paths.upgradeCrash(phase);
        defer child.deinit();
        try child.kill();
        var reopened = try Host.open(allocator, paths.database, &workers, .{});
        defer reopened.close();
        // Death before publication left the prior version; death after it left
        // the upgraded one. Retrying the same upgrade resolves either way.
        const published = phase == .after_upgrade_commit;
        try expectStatus(&reopened, if (published) upgraded else v1_reserved);
        const retry = try reopened.upgrade(.{ .upgrade_id = "crash-upgrade", .expected_revision = 1, .target = "inventory/v2" });
        try std.testing.expectEqual(published, retry.reused);
        try std.testing.expectEqual(@as(i64, 2), retry.revision);
        try std.testing.expectEqual(@as(i64, 1), try reopened.db.scalar("SELECT count(*) FROM upgrades"));
        try expectStatus(&reopened, upgraded);
    }
}

test "an indeterminate upgrade COMMIT requires close and reopen before retry" {
    const Fault = struct {
        deny_commit: usize,
        commits: usize = 0,
        rollbacks: usize = 0,
        const Callback = ?*const fn (?*anyopaque, c_int, ?[*:0]const u8, ?[*:0]const u8, ?[*:0]const u8, ?[*:0]const u8) callconv(.c) c_int;
        extern "c" fn sqlite3_set_authorizer(*anyopaque, Callback, ?*anyopaque) c_int;
        fn authorize(raw: ?*anyopaque, operation: c_int, first: ?[*:0]const u8, _: ?[*:0]const u8, _: ?[*:0]const u8, _: ?[*:0]const u8) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (operation != 22) return 0; // SQLITE_TRANSACTION
            const name = std.mem.span(first orelse return 0);
            if (std.mem.eql(u8, name, "ROLLBACK")) self.rollbacks += 1;
            if (std.mem.eql(u8, name, "COMMIT")) {
                self.commits += 1;
                if (self.commits == self.deny_commit) return 1; // SQLITE_DENY
            }
            return 0;
        }
    };
    var paths = try Paths.init();
    defer paths.deinit();
    var fault: Fault = .{ .deny_commit = 1 };
    {
        var host = try Host.open(allocator, paths.database, &workers, .{});
        defer host.close();
        try commitFirstTurn(&host);
        try std.testing.expectEqual(@as(c_int, 0), Fault.sqlite3_set_authorizer(host.db.handle, Fault.authorize, &fault));
        defer _ = Fault.sqlite3_set_authorizer(host.db.handle, null, null);
        // The upgrade's single transaction COMMIT is denied and must not roll back.
        try std.testing.expectError(error.CommitIndeterminate, host.upgrade(.{ .upgrade_id = "uncertain-upgrade", .expected_revision = 1, .target = "inventory/v2" }));
        try std.testing.expectEqual(@as(usize, 1), fault.commits);
        try std.testing.expectEqual(@as(usize, 0), fault.rollbacks);
        try std.testing.expect(!host.db.autocommit());
        try std.testing.expectError(error.HostNeedsRecovery, host.status());
    }
    // The authorizer prevented publication; a fresh connection retries cleanly.
    var reopened = try Host.open(allocator, paths.database, &workers, .{});
    defer reopened.close();
    try expectStatus(&reopened, v1_reserved);
    const retry = try reopened.upgrade(.{ .upgrade_id = "uncertain-upgrade", .expected_revision = 1, .target = "inventory/v2" });
    try std.testing.expect(!retry.reused);
    try std.testing.expectEqual(@as(i64, 2), retry.revision);
    try expectStatus(&reopened, upgraded);
}

test "an upgrade serializes against an executing turn and adopts cleanly after it" {
    var paths = try Paths.init();
    defer paths.deinit();
    var host = try Host.open(allocator, paths.database, &workers, .{});
    defer host.close();
    // One real v1 host is paused inside its business transaction, holding the
    // SQLite writer reservation at revision 0 with an admitted turn.
    var child = try harness.Process.start(allocator, config.crash_fixture_executable, paths.database, config.worker_executable, config.worker_v2_executable, @tagName(contract.Phase.after_begin), 1, paths.recipient);
    defer child.deinit();
    try std.testing.expectError(error.DatabaseBusy, host.upgrade(.{ .upgrade_id = "concurrent-upgrade", .expected_revision = 0, .target = "inventory/v2" }));
    try expectStatus(&host, .{});
    // Killing the paused host rolls its business transaction back; the turn's
    // admission stays bound to v1 identity.
    try child.kill();
    const upgrade = try host.upgrade(.{ .upgrade_id = "concurrent-upgrade", .expected_revision = 0, .target = "inventory/v2" });
    try std.testing.expect(!upgrade.reused);
    try std.testing.expectEqual(@as(i64, 1), upgrade.revision);
    try expectStatus(&host, .{ .application = "inventory/v2", .revision = 1, .attempts = 0, .stock = 5, .turn_count = 0, .reservation_count = 0, .outbox_count = 0 });

    // The killed turn's admitted v1 request cannot be reissued under v2, but a
    // fresh v2 turn runs normally at the upgraded revision.
    var request = try input(2, false);
    defer request.deinit(allocator);
    try std.testing.expectError(error.TurnIdConflict, host.execute(.{ .turn_id = "crash-turn", .expected_revision = 0, .input = request.view() }));
    var failing = try input(9, false);
    defer failing.deinit(allocator);
    var rejected = try host.execute(.{ .turn_id = "v2-after-upgrade", .expected_revision = 1, .input = failing.view() });
    defer rejected.deinit();
    try std.testing.expect(!rejected.reused);
    try expectStatus(&host, .{ .application = "inventory/v2", .revision = 2, .attempts = 1, .stock = 5, .turn_count = 1 });
}

test "historical receipts replay on their original application after the upgrade" {
    var paths = try Paths.init();
    defer paths.deinit();
    var observer: Observer = .{};
    var host = try Host.open(allocator, paths.database, &workers, .{ .checkpoint = observer.checkpoint() });
    var request = try input(2, false);
    defer request.deinit(allocator);
    var first = try host.execute(.{ .turn_id = "turn-one", .expected_revision = 0, .input = request.view() });
    defer first.deinit();
    const first_bytes = try allocator.dupe(u8, first.receipt());
    defer allocator.free(first_bytes);
    _ = try host.upgrade(.{ .upgrade_id = "upgrade-one", .expected_revision = 1, .target = "inventory/v2" });
    var failing = try input(9, false);
    defer failing.deinit(allocator);
    var second = try host.execute(.{ .turn_id = "v2-rejected", .expected_revision = 2, .input = failing.view() });
    defer second.deinit();
    const second_bytes = try allocator.dupe(u8, second.receipt());
    defer allocator.free(second_bytes);

    // Both replays reproduce their stored receipts with no host callbacks.
    observer = .{};
    var replay_one = try host.replay("turn-one");
    defer replay_one.deinit();
    try std.testing.expectEqualSlices(u8, first_bytes, replay_one.receipt());
    try std.testing.expectEqualSlices(u8, first.terminal().bytes, replay_one.terminal().bytes);
    var replay_two = try host.replay("v2-rejected");
    defer replay_two.deinit();
    try std.testing.expectEqualSlices(u8, second_bytes, replay_two.receipt());
    try std.testing.expectEqualSlices(u8, second.terminal().bytes, replay_two.terminal().bytes);
    try std.testing.expectEqual(@as(usize, 0), observer.begins + observer.effects + observer.admissions);
    try expectStatus(&host, .{ .application = "inventory/v2", .revision = 3, .attempts = 2, .stock = 3, .turn_count = 2, .reservation_count = 1, .outbox_count = 1 });
    try std.testing.expectEqual(@as(i64, 2), try host.db.scalar("SELECT count(*) FROM turn_versions"));
    host.close();

    // Routing proof: the v1 replay needs only the v1 worker, while the v2
    // turn cannot replay without its own application's executable.
    var reopened = try Host.open(allocator, paths.database, &.{ workers[0], paths.missing_worker_second }, .{});
    defer reopened.close();
    var routed = try reopened.replay("turn-one");
    defer routed.deinit();
    try std.testing.expectEqualSlices(u8, first_bytes, routed.receipt());
    var v2_failed = false;
    if (reopened.replay("v2-rejected")) |verified| {
        var mutable = verified;
        mutable.deinit();
    } else |_| {
        v2_failed = true;
    }
    try std.testing.expect(v2_failed);
}

fn recipientCounts(path: []const u8) !struct { receipts: i64, notifications: i64 } {
    var recipient = try host_module.sql.Db.open(allocator, path);
    defer recipient.close();
    return .{ .receipts = try recipient.scalar("SELECT count(*) FROM receipts"), .notifications = try recipient.scalar("SELECT count FROM notification_counter WHERE singleton=1") };
}

test "pending v1 intents retain identity and delivery after the upgrade" {
    var paths = try Paths.init();
    defer paths.deinit();
    var host = try Host.open(allocator, paths.database, &workers, .{});
    defer host.close();
    var request = try input(2, false);
    defer request.deinit(allocator);
    var first = try host.execute(.{ .turn_id = "turn-one", .expected_revision = 0, .input = request.view() });
    defer first.deinit();
    var terminal = try data.Document.decode(allocator, first.terminal(), contract.max_bytes);
    defer terminal.deinit();
    const intent_id = try allocator.dupe(u8, try (try (try terminal.root().at(0)).get("intent")).?.asString());
    defer allocator.free(intent_id);

    _ = try host.upgrade(.{ .upgrade_id = "upgrade-one", .expected_revision = 1, .target = "inventory/v2" });
    var failing = try input(9, false);
    defer failing.deinit(allocator);
    var rejected = try host.execute(.{ .turn_id = "v2-rejected", .expected_revision = 2, .input = failing.view() });
    defer rejected.deinit();
    try expectStatus(&host, .{ .application = "inventory/v2", .revision = 3, .attempts = 2, .stock = 3, .turn_count = 2, .reservation_count = 1, .outbox_count = 1 });

    // The v1-staged intent is still deliverable with its original identity;
    // the upgrade did not touch outbox rows or notification identities.
    try std.testing.expectEqual(@as(usize, 1), try host.dispatch(paths.recipient));
    try std.testing.expectEqual(@as(usize, 0), try host.dispatch(paths.recipient));
    try expectStatus(&host, .{ .application = "inventory/v2", .revision = 3, .attempts = 2, .stock = 3, .turn_count = 2, .reservation_count = 1, .outbox_count = 1, .delivered_count = 1 });
    {
        var query = try host.db.prepare("SELECT intent_id FROM outbox");
        defer query.deinit();
        try std.testing.expectEqual(host_module.sql.Step.row, try query.step());
        try std.testing.expectEqualStrings(intent_id, try query.text(0));
    }
    const counts = try recipientCounts(paths.recipient);
    try std.testing.expectEqual(@as(i64, 1), counts.receipts);
    try std.testing.expectEqual(@as(i64, 1), counts.notifications);
}
