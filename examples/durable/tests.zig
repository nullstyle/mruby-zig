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
    missing_worker: []u8,
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
        const missing_worker = try std.fs.path.join(allocator, &.{ directory, "absent-worker" });
        errdefer allocator.free(missing_worker);
        const missing_worker_second = try std.fs.path.join(allocator, &.{ directory, "absent-worker-2" });
        errdefer allocator.free(missing_worker_second);
        return .{ .tmp = tmp, .directory = directory, .database = database, .recipient = recipient, .missing_worker = missing_worker, .missing_worker_second = missing_worker_second };
    }
    fn deinit(self: *Paths) void {
        allocator.free(self.directory);
        allocator.free(self.database);
        allocator.free(self.recipient);
        allocator.free(self.missing_worker);
        allocator.free(self.missing_worker_second);
        self.tmp.cleanup();
    }
    fn crash(self: *const Paths, phase: contract.Phase, ordinal: u32) !harness.Process {
        return harness.Process.start(allocator, config.crash_fixture_executable, self.database, config.worker_executable, config.worker_v2_executable, @tagName(phase), ordinal, self.recipient);
    }
};

/// Worker executables for both application versions, ordered like the host's
/// application table.
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

const observed_reserved: Expected = .{ .revision = 1, .attempts = 1, .stock = 3, .turn_count = 1, .reservation_count = 1, .outbox_count = 1 };
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

test "durable commit binds state receipt intents and retry identity" {
    var paths = try Paths.init();
    defer paths.deinit();
    var observer: Observer = .{};
    var host = try Host.open(allocator, paths.database, &workers, .{ .checkpoint = observer.checkpoint() });
    defer host.close();
    var request = try input(2, false);
    defer request.deinit(allocator);
    var first = try host.execute(.{ .turn_id = "turn-one", .expected_revision = 0, .input = request.view() });
    defer first.deinit();
    try std.testing.expectEqual(@as(i64, 1), first.revision);
    try std.testing.expect(!first.reused);
    try std.testing.expectEqual(@as(usize, 2), first.effect_calls);
    try expectStatus(&host, observed_reserved);
    var terminal = try data.Document.decode(allocator, first.terminal(), contract.max_bytes);
    defer terminal.deinit();
    try std.testing.expectEqualStrings("reserved", try (try (try terminal.root().at(0)).get("status")).?.asString());
    try std.testing.expectEqual(@as(i64, 1), try (try (try terminal.root().at(1)).get("attempts")).?.asInteger());
    const reservation = (try (try terminal.root().at(0)).get("reservation")).?;
    try expectHexId(try (try reservation.get("id")).?.asString());
    try std.testing.expectEqualStrings("widget", try (try reservation.get("sku")).?.asString());
    try std.testing.expectEqual(@as(i64, 2), try (try reservation.get("quantity")).?.asInteger());
    try std.testing.expectEqual(@as(i64, 3), try (try reservation.get("remaining")).?.asInteger());
    const intent = try (try (try terminal.root().at(0)).get("intent")).?.asString();
    try expectHexId(intent);
    const receipt = try mruby.strict.Turn.Receipt.decode(first.receipt(), .{});
    var trace = try mruby.effect.Trace.decode(allocator, receipt.trace, .{});
    defer trace.deinit();
    try std.testing.expectEqual(@as(usize, 2), trace.len());
    try std.testing.expectEqualStrings("stock.reserve", trace.get(0).?.name);
    try std.testing.expectEqualStrings("notifications.reservation_created", trace.get(1).?.name);
    var stock_result = try data.Document.decode(allocator, .{ .bytes = trace.get(0).?.result }, contract.max_bytes);
    defer stock_result.deinit();
    try std.testing.expectEqualStrings(try (try reservation.get("id")).?.asString(), try (try stock_result.root().get("id")).?.asString());
    var notified = try data.Document.decode(allocator, .{ .bytes = trace.get(1).?.arguments }, contract.max_bytes);
    defer notified.deinit();
    var notification_reservation = try data.encodeRef(allocator, try notified.root().at(0), contract.max_bytes);
    defer notification_reservation.deinit(allocator);
    try std.testing.expectEqualSlices(u8, trace.get(0).?.result, notification_reservation.encoded);
    var notification_result = try data.Document.decode(allocator, .{ .bytes = trace.get(1).?.result }, contract.max_bytes);
    defer notification_result.deinit();
    try std.testing.expectEqualStrings(intent, try notification_result.root().asString());
    observer = .{};
    var replay = try host.replay("turn-one");
    defer replay.deinit();
    try std.testing.expectEqualSlices(u8, first.receipt(), replay.receipt());
    try std.testing.expectEqualSlices(u8, first.terminal().bytes, replay.terminal().bytes);
    try std.testing.expectEqual(@as(usize, 0), observer.begins);
    try std.testing.expectEqual(@as(usize, 0), observer.effects);
    try expectStatus(&host, observed_reserved);

    var changed = try input(1, false);
    defer changed.deinit(allocator);
    try std.testing.expectError(error.TurnIdConflict, host.execute(.{ .turn_id = "turn-one", .expected_revision = 0, .input = changed.view() }));
    try std.testing.expectError(error.TurnIdConflict, host.execute(.{ .turn_id = "turn-one", .expected_revision = 1, .input = request.view() }));
    try std.testing.expectError(error.StaleState, host.execute(.{ .turn_id = "stale", .expected_revision = 0, .input = changed.view() }));
    var later = try host.execute(.{ .turn_id = "turn-two", .expected_revision = 1, .input = changed.view() });
    defer later.deinit();
    try expectStatus(&host, .{ .revision = 2, .attempts = 2, .stock = 2, .turn_count = 2, .reservation_count = 2, .outbox_count = 2 });
    observer = .{};
    var historical = try host.replay("turn-one");
    defer historical.deinit();
    try std.testing.expectEqualSlices(u8, first.receipt(), historical.receipt());
    try std.testing.expectEqual(@as(usize, 0), observer.begins);
    try std.testing.expectEqual(@as(usize, 0), observer.effects);

    // An unavailable executable proves a committed retry does not launch even
    // a replay-only worker. The original revision remains valid for that ID.
    var reopened = try Host.open(allocator, paths.database, &.{ paths.missing_worker, paths.missing_worker_second }, .{});
    defer reopened.close();
    var retried = try reopened.execute(.{ .turn_id = "turn-one", .expected_revision = 0, .input = request.view() });
    defer retried.deinit();
    try std.testing.expect(retried.reused);
    try std.testing.expectEqual(@as(i64, 1), retried.revision);
    try std.testing.expectEqual(@as(usize, 0), retried.effect_calls);
    try std.testing.expectEqualSlices(u8, first.receipt(), retried.receipt());
    try std.testing.expectEqualSlices(u8, first.terminal().bytes, retried.terminal().bytes);
    try expectStatus(&reopened, .{ .revision = 2, .attempts = 2, .stock = 2, .turn_count = 2, .reservation_count = 2, .outbox_count = 2 });
}

test "Ruby failure rolls back business changes while retaining the request identity" {
    var paths = try Paths.init();
    defer paths.deinit();
    var observer: Observer = .{};
    var host = try Host.open(allocator, paths.database, &workers, .{ .checkpoint = observer.checkpoint() });
    defer host.close();
    var failing = try input(2, true);
    defer failing.deinit(allocator);
    try std.testing.expectError(error.RubyException, host.execute(.{ .turn_id = "failed", .expected_revision = 0, .input = failing.view() }));
    try std.testing.expectEqual(@as(usize, 2), observer.effects);
    try expectStatus(&host, .{});
    var success = try input(2, false);
    defer success.deinit(allocator);
    try std.testing.expectError(error.TurnIdConflict, host.execute(.{ .turn_id = "failed", .expected_revision = 0, .input = success.view() }));
    var retry = try host.execute(.{ .turn_id = "success-after-failure", .expected_revision = 0, .input = success.view() });
    defer retry.deinit();
    try std.testing.expect(!retry.reused);
    try expectStatus(&host, observed_reserved);
}

test "checkpoint mutation cannot change the admitted turn ID input or persisted retry fingerprint" {
    const Mutator = struct {
        turn_id: []u8,
        input_bytes: []u8,
        replacement: []const u8,
        mutated: bool = false,
        fn hit(raw: ?*anyopaque, phase: contract.Phase) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (phase != .after_begin or self.mutated) return;
            self.mutated = true;
            @memset(self.turn_id, 'X');
            @memcpy(self.input_bytes, self.replacement);
        }
    };
    var paths = try Paths.init();
    defer paths.deinit();
    var request = try input(2, false);
    defer request.deinit(allocator);
    const original = try allocator.dupe(u8, request.encoded);
    defer allocator.free(original);
    var replacement = try input(1, false);
    defer replacement.deinit(allocator);
    try std.testing.expectEqual(request.encoded.len, replacement.encoded.len);
    var turn_id = "original".*;
    var mutator: Mutator = .{ .turn_id = &turn_id, .input_bytes = request.encoded, .replacement = replacement.encoded };
    var host = try Host.open(allocator, paths.database, &workers, .{ .checkpoint = .{ .context = &mutator, .hit = Mutator.hit } });
    defer host.close();
    var result = try host.execute(.{ .turn_id = &turn_id, .expected_revision = 0, .input = request.view() });
    defer result.deinit();
    try std.testing.expect(mutator.mutated);
    try std.testing.expectEqualStrings("XXXXXXXX", &turn_id);
    try std.testing.expectEqualSlices(u8, replacement.encoded, request.encoded);
    try expectStatus(&host, observed_reserved);
    var retried = try host.execute(.{ .turn_id = "original", .expected_revision = 0, .input = .{ .bytes = original } });
    defer retried.deinit();
    try std.testing.expect(retried.reused);
    try std.testing.expectEqual(@as(usize, 0), retried.effect_calls);
    try std.testing.expectEqualSlices(u8, result.receipt(), retried.receipt());
    var replay = try host.replay("original");
    defer replay.deinit();
    try std.testing.expectEqualSlices(u8, result.receipt(), replay.receipt());
}

test "host turn ID participates in the effect input identity of otherwise equal fresh databases" {
    var left_paths = try Paths.init();
    defer left_paths.deinit();
    var right_paths = try Paths.init();
    defer right_paths.deinit();
    var left = try Host.open(allocator, left_paths.database, &workers, .{});
    defer left.close();
    var right = try Host.open(allocator, right_paths.database, &workers, .{});
    defer right.close();
    var request = try input(2, false);
    defer request.deinit(allocator);
    var first = try left.execute(.{ .turn_id = "left-turn", .expected_revision = 0, .input = request.view() });
    defer first.deinit();
    var second = try right.execute(.{ .turn_id = "right-turn", .expected_revision = 0, .input = request.view() });
    defer second.deinit();
    const first_receipt = try mruby.strict.Turn.Receipt.decode(first.receipt(), .{});
    const second_receipt = try mruby.strict.Turn.Receipt.decode(second.receipt(), .{});
    var first_trace = try mruby.effect.Trace.decode(allocator, first_receipt.trace, .{});
    defer first_trace.deinit();
    var second_trace = try mruby.effect.Trace.decode(allocator, second_receipt.trace, .{});
    defer second_trace.deinit();
    try std.testing.expectEqualSlices(u8, &first_trace.identity.code, &second_trace.identity.code);
    try std.testing.expectEqualSlices(u8, &first_trace.identity.catalogue, &second_trace.identity.catalogue);
    try std.testing.expect(!std.mem.eql(u8, &first_trace.identity.input, &second_trace.identity.input));
    var first_terminal = try data.Document.decode(allocator, first.terminal(), contract.max_bytes);
    defer first_terminal.deinit();
    var second_terminal = try data.Document.decode(allocator, second.terminal(), contract.max_bytes);
    defer second_terminal.deinit();
    const first_id = try (try (try first_terminal.root().at(0)).get("intent")).?.asString();
    const second_id = try (try (try second_terminal.root().at(0)).get("intent")).?.asString();
    try std.testing.expect(!std.mem.eql(u8, first_id, second_id));
}

test "allocation failure after staging or preparation rolls back and keeps the host reusable" {
    const AllocationGate = struct {
        failing: *std.testing.FailingAllocator,
        selected: contract.Phase,
        effects: usize = 0,
        triggered: bool = false,
        fn hit(raw: ?*anyopaque, phase: contract.Phase) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (phase == .after_effect) self.effects += 1;
            if (self.triggered or phase != self.selected or (phase == .after_effect and self.effects != 2)) return;
            self.triggered = true;
            self.failing.fail_index = self.failing.alloc_index;
            self.failing.resize_fail_index = self.failing.resize_index;
        }
    };
    for ([_]contract.Phase{ .after_effect, .after_prepare }) |phase| {
        var paths = try Paths.init();
        defer paths.deinit();
        var request = try input(2, false);
        defer request.deinit(allocator);
        var failing = std.testing.FailingAllocator.init(allocator, .{});
        var gate: AllocationGate = .{ .failing = &failing, .selected = phase };
        {
            var host = try Host.open(failing.allocator(), paths.database, &workers, .{ .checkpoint = .{ .context = &gate, .hit = AllocationGate.hit } });
            defer host.close();
            try std.testing.expectError(error.OutOfMemory, host.execute(.{ .turn_id = "allocation-failure", .expected_revision = 0, .input = request.view() }));
            try std.testing.expect(gate.triggered);
            try std.testing.expect(failing.has_induced_failure);
            try std.testing.expectEqual(@as(usize, 2), gate.effects);
            failing.fail_index = std.math.maxInt(usize);
            failing.resize_fail_index = std.math.maxInt(usize);
            try expectStatus(&host, .{});
            var result = try host.execute(.{ .turn_id = "allocation-failure", .expected_revision = 0, .input = request.view() });
            defer result.deinit();
            try std.testing.expect(!result.reused);
            try expectStatus(&host, observed_reserved);
        }
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "expected OutOfStock rejection commits the attempt without reservations or intents" {
    var paths = try Paths.init();
    defer paths.deinit();
    var observer: Observer = .{};
    var host = try Host.open(allocator, paths.database, &workers, .{ .checkpoint = observer.checkpoint() });
    defer host.close();
    var request = try input(6, false);
    defer request.deinit(allocator);
    var result = try host.execute(.{ .turn_id = "rejected", .expected_revision = 0, .input = request.view() });
    defer result.deinit();
    var terminal = try data.Document.decode(allocator, result.terminal(), contract.max_bytes);
    defer terminal.deinit();
    const returned = try terminal.root().at(0);
    try std.testing.expectEqualStrings("rejected", try (try returned.get("status")).?.asString());
    try std.testing.expectEqualStrings("OutOfStock", try (try returned.get("code")).?.asString());
    try expectStatus(&host, .{ .revision = 1, .attempts = 1, .turn_count = 1 });
    try std.testing.expectEqual(@as(usize, 1), result.effect_calls);
    observer = .{};
    var replay = try host.replay("rejected");
    defer replay.deinit();
    try std.testing.expectEqualSlices(u8, result.receipt(), replay.receipt());
    try std.testing.expectEqual(@as(usize, 0), observer.begins + observer.effects + observer.admissions);
}

test "SIGKILL before commit rolls back each staged effect and prepared application state" {
    const cases = [_]struct { phase: contract.Phase, ordinal: u32 = 1 }{
        .{ .phase = .after_admission },
        .{ .phase = .after_begin },
        .{ .phase = .after_effect, .ordinal = 1 },
        .{ .phase = .after_effect, .ordinal = 2 },
        .{ .phase = .after_stock_update },
        .{ .phase = .after_reservation_insert },
        .{ .phase = .after_prepare },
        .{ .phase = .before_commit },
    };
    for (cases) |case| {
        var paths = try Paths.init();
        defer paths.deinit();
        var child = try paths.crash(case.phase, case.ordinal);
        defer child.deinit();
        try child.kill();
        var reopened = try Host.open(allocator, paths.database, &workers, .{});
        defer reopened.close();
        try expectStatus(&reopened, .{});
        var changed = try input(1, false);
        defer changed.deinit(allocator);
        try std.testing.expectError(error.TurnIdConflict, reopened.execute(.{ .turn_id = "crash-turn", .expected_revision = 0, .input = changed.view() }));
        var request = try input(2, false);
        defer request.deinit(allocator);
        var result = try reopened.execute(.{ .turn_id = "crash-turn", .expected_revision = 0, .input = request.view() });
        defer result.deinit();
        try std.testing.expect(!result.reused);
        try std.testing.expectEqual(@as(usize, 2), result.effect_calls);
        try expectStatus(&reopened, observed_reserved);
    }
}

test "SIGKILL after commit recovers the lost reply without rerunning the worker" {
    var paths = try Paths.init();
    defer paths.deinit();
    var child = try paths.crash(.after_commit, 1);
    defer child.deinit();
    try child.kill();
    var reopened = try Host.open(allocator, paths.database, &.{ paths.missing_worker, paths.missing_worker_second }, .{});
    defer reopened.close();
    try expectStatus(&reopened, observed_reserved);
    var request = try input(2, false);
    defer request.deinit(allocator);
    var result = try reopened.execute(.{ .turn_id = "crash-turn", .expected_revision = 0, .input = request.view() });
    defer result.deinit();
    try std.testing.expect(result.reused);
    try std.testing.expectEqual(@as(usize, 0), result.effect_calls);
    try std.testing.expectEqual(@as(i64, 1), result.revision);
    try expectStatus(&reopened, observed_reserved);
}

fn recipientCounts(path: []const u8) !struct { receipts: i64, notifications: i64 } {
    var recipient = try host_module.sql.Db.open(allocator, path);
    defer recipient.close();
    return .{ .receipts = try recipient.scalar("SELECT count(*) FROM receipts"), .notifications = try recipient.scalar("SELECT count FROM notification_counter WHERE singleton=1") };
}

test "delivery SIGKILL boundaries retry accepted intent IDs without another notification" {
    for ([_]contract.Phase{ .before_delivery, .after_recipient_commit, .after_delivery_ack }) |phase| {
        var paths = try Paths.init();
        defer paths.deinit();
        var child = try paths.crash(phase, 1);
        defer child.deinit();
        try child.kill();
        var reopened = try Host.open(allocator, paths.database, &workers, .{});
        defer reopened.close();
        var expected = observed_reserved;
        expected.delivered_count = if (phase == .after_delivery_ack) 1 else 0;
        try expectStatus(&reopened, expected);
        const before = try recipientCounts(paths.recipient);
        const accepted: i64 = if (phase == .before_delivery) 0 else 1;
        try std.testing.expectEqual(accepted, before.receipts);
        try std.testing.expectEqual(accepted, before.notifications);
        try std.testing.expectEqual(@as(usize, if (phase == .after_delivery_ack) 0 else 1), try reopened.dispatch(paths.recipient));
        try std.testing.expectEqual(@as(usize, 0), try reopened.dispatch(paths.recipient));
        const after = try recipientCounts(paths.recipient);
        try std.testing.expectEqual(@as(i64, 1), after.receipts);
        try std.testing.expectEqual(@as(i64, 1), after.notifications);
        expected.delivered_count = 1;
        try expectStatus(&reopened, expected);
    }
}

test "two host connections cannot overwrite a turn begun against an older revision" {
    var paths = try Paths.init();
    defer paths.deinit();
    var observer: Observer = .{};
    var second = try Host.open(allocator, paths.database, &workers, .{ .checkpoint = observer.checkpoint() });
    defer second.close();
    var child = try paths.crash(.after_begin, 1);
    defer child.deinit();
    var request = try input(2, false);
    defer request.deinit(allocator);
    try std.testing.expectError(error.DatabaseBusy, second.execute(.{ .turn_id = "concurrent", .expected_revision = 0, .input = request.view() }));
    try std.testing.expectEqual(@as(usize, 0), observer.effects);
    try expectStatus(&second, .{});
    try child.proceed();
    try std.testing.expectError(error.StaleState, second.execute(.{ .turn_id = "concurrent", .expected_revision = 0, .input = request.view() }));
    try std.testing.expectEqual(@as(usize, 0), observer.effects);
    try expectStatus(&second, observed_reserved);
}

test "recipient deduplicates exact bytes and rejects a reused ID with changed destination or payload" {
    var paths = try Paths.init();
    defer paths.deinit();
    var recipient = try host_module.sql.Db.open(allocator, paths.recipient);
    defer recipient.close();
    try host_module.delivery.initRecipient(&recipient);
    const intent: host_module.delivery.Intent = .{ .id = "stable-intent", .destination = "reservations", .payload = "widget:2" };
    try host_module.delivery.accept(&recipient, intent);
    try host_module.delivery.accept(&recipient, intent);
    try std.testing.expectError(error.IntentConflict, host_module.delivery.accept(&recipient, .{ .id = intent.id, .destination = intent.destination, .payload = "widget:3" }));
    try std.testing.expectError(error.IntentConflict, host_module.delivery.accept(&recipient, .{ .id = intent.id, .destination = "different", .payload = intent.payload }));
    try std.testing.expect(recipient.autocommit());
    try std.testing.expectEqual(@as(i64, 1), try recipient.scalar("SELECT count(*) FROM receipts"));
    try std.testing.expectEqual(@as(i64, 1), try recipient.scalar("SELECT count FROM notification_counter WHERE singleton=1"));
}

test "a recipient conflict cannot acknowledge the source intent" {
    var paths = try Paths.init();
    defer paths.deinit();
    var host = try Host.open(allocator, paths.database, &workers, .{});
    defer host.close();
    var request = try input(2, false);
    defer request.deinit(allocator);
    var result = try host.execute(.{ .turn_id = "conflicting-delivery", .expected_revision = 0, .input = request.view() });
    defer result.deinit();
    var terminal = try data.Document.decode(allocator, result.terminal(), contract.max_bytes);
    defer terminal.deinit();
    const intent_id = try (try (try terminal.root().at(0)).get("intent")).?.asString();
    var recipient = try host_module.sql.Db.open(allocator, paths.recipient);
    defer recipient.close();
    try host_module.delivery.initRecipient(&recipient);
    try host_module.delivery.accept(&recipient, .{ .id = intent_id, .destination = "reservations", .payload = "different payload" });
    try std.testing.expectError(error.IntentConflict, host.dispatch(paths.recipient));
    try expectStatus(&host, observed_reserved);
    try std.testing.expectEqual(@as(i64, 1), try recipient.scalar("SELECT count(*) FROM receipts"));
    try std.testing.expectEqual(@as(i64, 1), try recipient.scalar("SELECT count FROM notification_counter WHERE singleton=1"));
}

test "source cannot act as its own recipient even through an inode alias" {
    var paths = try Paths.init();
    defer paths.deinit();
    var host = try Host.open(allocator, paths.database, &workers, .{});
    defer host.close();
    var request = try input(2, false);
    defer request.deinit(allocator);
    var result = try host.execute(.{ .turn_id = "same-db", .expected_revision = 0, .input = request.view() });
    defer result.deinit();
    try std.testing.expectError(error.DatabaseRoleMismatch, host.dispatch(paths.database));
    const source = try allocator.dupeSentinel(u8, paths.database, 0);
    defer allocator.free(source);
    const alias = try allocator.dupeSentinel(u8, paths.recipient, 0);
    defer allocator.free(alias);
    if (std.c.link(source, alias) != 0) return error.HardLinkFailed;
    try std.testing.expectError(error.DatabaseRoleMismatch, host.dispatch(paths.recipient));
    try expectStatus(&host, observed_reserved);
}

test "combined adapter snapshot row limit rejects before worker startup and preserves business state" {
    var paths = try Paths.init();
    defer paths.deinit();
    var request = try input(2, false);
    defer request.deinit(allocator);
    {
        var seed = try Host.open(allocator, paths.database, &workers, .{});
        defer seed.close();
        var result = try seed.execute(.{ .turn_id = "snapshot-seed", .expected_revision = 0, .input = request.view() });
        defer result.deinit();
        try expectStatus(&seed, observed_reserved);
    }
    {
        var db = try host_module.sql.Db.open(allocator, paths.database);
        defer db.close();
        // Stock alone reaches the bound; the existing reservation makes the
        // combined stock+reservation snapshot exceed it by exactly one row.
        var fill = try db.prepare("WITH RECURSIVE n(value) AS (SELECT 1 UNION ALL SELECT value+1 FROM n WHERE value<?) INSERT INTO stock(sku,quantity) SELECT 'snapshot-'||value,0 FROM n");
        defer fill.deinit();
        try fill.bindInt(1, @intCast(contract.max_snapshot_rows - 1));
        try std.testing.expectEqual(host_module.sql.Step.done, try fill.step());
        try std.testing.expectEqual(@as(i64, contract.max_snapshot_rows), try db.scalar("SELECT count(*) FROM stock"));
        try std.testing.expectEqual(@as(i64, 1), try db.scalar("SELECT count(*) FROM reservations"));
    }
    var observer: Observer = .{};
    // The nonexistent executable makes any accidental worker startup fail
    // differently from the expected host-side snapshot admission error.
    var host = try Host.open(allocator, paths.database, &.{ paths.missing_worker, paths.missing_worker_second }, .{ .checkpoint = observer.checkpoint() });
    defer host.close();
    try std.testing.expectError(error.AdapterStateLimit, host.execute(.{ .turn_id = "snapshot-too-large", .expected_revision = 1, .input = request.view() }));
    try std.testing.expectEqual(@as(usize, 0), observer.begins);
    try std.testing.expectEqual(@as(usize, 0), observer.effects);
    try std.testing.expect(host.db.autocommit());
    try expectStatus(&host, observed_reserved);
    try std.testing.expectEqual(@as(i64, contract.max_snapshot_rows), try host.db.scalar("SELECT count(*) FROM stock"));
    try std.testing.expectEqual(@as(i64, 1), try host.db.scalar("SELECT count(*) FROM admissions WHERE turn_id='snapshot-too-large'"));
}

test "reopening with a different namespace or recipient database role fails without changing storage" {
    var paths = try Paths.init();
    defer paths.deinit();
    {
        var source = try Host.open(allocator, paths.database, &.{ paths.missing_worker, paths.missing_worker_second }, .{ .namespace = "source-a" });
        defer source.close();
        try expectStatus(&source, .{});
    }
    try std.testing.expectError(error.DatabaseNamespaceMismatch, Host.open(allocator, paths.database, &.{ paths.missing_worker, paths.missing_worker_second }, .{ .namespace = "source-b" }));
    {
        var source = try Host.open(allocator, paths.database, &.{ paths.missing_worker, paths.missing_worker_second }, .{ .namespace = "source-a" });
        defer source.close();
        try expectStatus(&source, .{});
    }
    {
        var recipient = try host_module.sql.Db.open(allocator, paths.recipient);
        defer recipient.close();
        try host_module.delivery.initRecipient(&recipient);
    }
    try std.testing.expectError(error.DatabaseRoleMismatch, Host.open(allocator, paths.recipient, &.{ paths.missing_worker, paths.missing_worker_second }, .{}));
    var recipient = try host_module.sql.Db.open(allocator, paths.recipient);
    defer recipient.close();
    try host_module.delivery.requireRole(&recipient, "recipient");
    try std.testing.expectEqual(@as(i64, 0), try recipient.scalar("SELECT count(*) FROM receipts"));
    try std.testing.expectEqual(@as(i64, 0), try recipient.scalar("SELECT count FROM notification_counter WHERE singleton=1"));
    try std.testing.expectEqual(@as(i64, 0), try recipient.scalar("SELECT count(*) FROM sqlite_schema WHERE name='current_state'"));
}

test "admission and business COMMIT errors require recovery without automatically rolling back" {
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
    // The first transaction binds the ID; the second publishes business work.
    for ([_]usize{ 1, 2 }) |commit_number| {
        var paths = try Paths.init();
        defer paths.deinit();
        var request = try input(2, false);
        defer request.deinit(allocator);
        var fault: Fault = .{ .deny_commit = commit_number };
        {
            var host = try Host.open(allocator, paths.database, &workers, .{});
            defer host.close();
            try std.testing.expectEqual(@as(c_int, 0), Fault.sqlite3_set_authorizer(host.db.handle, Fault.authorize, &fault));
            defer _ = Fault.sqlite3_set_authorizer(host.db.handle, null, null);
            try std.testing.expectError(error.CommitIndeterminate, host.execute(.{ .turn_id = "uncertain-commit", .expected_revision = 0, .input = request.view() }));
            try std.testing.expectEqual(commit_number, fault.commits);
            try std.testing.expectEqual(@as(usize, 0), fault.rollbacks);
            try std.testing.expect(!host.db.autocommit());
            try std.testing.expectError(error.HostNeedsRecovery, host.status());
            try std.testing.expectError(error.HostNeedsRecovery, host.execute(.{ .turn_id = "uncertain-commit", .expected_revision = 0, .input = request.view() }));
            try std.testing.expectEqual(commit_number, fault.commits);
            try std.testing.expectEqual(@as(usize, 0), fault.rollbacks);
        }
        // The authorizer prevented publication. Explicitly closing the poisoned
        // connection releases its provisional transaction; reopening resolves it.
        var reopened = try Host.open(allocator, paths.database, &workers, .{});
        defer reopened.close();
        try expectStatus(&reopened, .{});
        try std.testing.expectEqual(@as(i64, if (commit_number == 1) 0 else 1), try reopened.db.scalar("SELECT count(*) FROM admissions"));
        var retried = try reopened.execute(.{ .turn_id = "uncertain-commit", .expected_revision = 0, .input = request.view() });
        defer retried.deinit();
        try std.testing.expect(!retried.reused);
        try std.testing.expectEqual(@as(usize, 2), retried.effect_calls);
        try expectStatus(&reopened, observed_reserved);
        try std.testing.expectEqual(@as(i64, 1), try reopened.db.scalar("SELECT count(*) FROM admissions"));
    }
}

fn expectHexId(id: []const u8) !void {
    try std.testing.expectEqual(@as(usize, 64), id.len);
    for (id) |byte| try std.testing.expect((byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'));
}

fn inputMode(mode: []const u8) !mruby.artifact.StateCapsule {
    return data.encode(allocator, .{ .hash = &.{
        .{ .key = .{ .string = "sku" }, .value = .{ .string = "widget" } },
        .{ .key = .{ .string = "quantity" }, .value = .{ .integer = 2 } },
        .{ .key = .{ .string = "fail" }, .value = .{ .boolean = false } },
        .{ .key = .{ .string = "mode" }, .value = .{ .string = mode } },
    } }, contract.max_bytes);
}

fn expectUnpublished(host: *Host, observer: Observer, completed_effects: usize) !void {
    try expectStatus(host, .{});
    try std.testing.expect(host.db.autocommit());
    try std.testing.expectEqual(@as(usize, 1), observer.admissions);
    try std.testing.expectEqual(@as(usize, 1), observer.begins);
    try std.testing.expectEqual(completed_effects, observer.effects);
    try std.testing.expectEqual(@as(i64, 1), try host.db.scalar("SELECT count(*) FROM admissions"));
}

test "durable turn input shape and numeric policy reject before ID admission or worker startup" {
    var paths = try Paths.init();
    defer paths.deinit();
    var observer: Observer = .{};
    var host = try Host.open(allocator, paths.database, &.{ paths.missing_worker, paths.missing_worker_second }, .{ .checkpoint = observer.checkpoint() });
    defer host.close();
    const invalid = [_]data.Value{
        .nil,
        .{ .hash = &.{
            .{ .key = .{ .string = "sku" }, .value = .{ .string = "widget" } },
            .{ .key = .{ .string = "quantity" }, .value = .{ .integer = 0 } },
            .{ .key = .{ .string = "fail" }, .value = .{ .boolean = false } },
        } },
        .{ .hash = &.{
            .{ .key = .{ .string = "sku" }, .value = .{ .string = "widget" } },
            .{ .key = .{ .string = "quantity" }, .value = .{ .integer = 2 } },
            .{ .key = .{ .string = "fail" }, .value = .{ .boolean = false } },
            .{ .key = .{ .string = "surprise" }, .value = .nil },
        } },
        .{ .hash = &.{
            .{ .key = .{ .string = "sku" }, .value = .{ .string = "widget" } },
            .{ .key = .{ .string = "quantity" }, .value = .{ .float = 1.25 } },
            .{ .key = .{ .string = "fail" }, .value = .{ .boolean = false } },
        } },
    };
    for (invalid, 0..) |value, index| {
        var bad = try data.encode(allocator, value, contract.max_bytes);
        defer bad.deinit(allocator);
        try std.testing.expectError(if (mruby.features.effects_integer64 and index == invalid.len - 1) error.NumericPolicyViolation else error.TurnContractViolation, host.execute(.{ .turn_id = "invalid-input", .expected_revision = 0, .input = bad.view() }));
        try std.testing.expectEqual(@as(usize, 0), observer.admissions + observer.begins + observer.effects);
        try std.testing.expectEqual(@as(i64, 0), try host.db.scalar("SELECT count(*) FROM admissions"));
        try expectStatus(&host, .{});
    }
}

fn replaceState(db: *host_module.sql.Db, bytes: []const u8) !void {
    var update = try db.prepare("UPDATE current_state SET state=? WHERE id=1");
    defer update.deinit();
    try update.bindBlob(1, bytes);
    try std.testing.expectEqual(host_module.sql.Step.done, try update.step());
}

test "invalid stored turn state fails before worker startup and business changes" {
    const values = [_]data.Value{ .{ .integer = -1 }, .{ .float = 1.25 }, .{ .integer = 1 } };
    for (values, 0..) |attempts, index| {
        var paths = try Paths.init();
        defer paths.deinit();
        var observer: Observer = .{};
        var host = try Host.open(allocator, paths.database, &.{ paths.missing_worker, paths.missing_worker_second }, .{ .checkpoint = observer.checkpoint() });
        defer host.close();
        var invalid = try data.encode(allocator, .{ .hash = &.{.{ .key = .{ .string = "attempts" }, .value = attempts }} }, contract.max_bytes);
        defer invalid.deinit(allocator);
        try replaceState(&host.db, invalid.encoded);
        var request = try input(2, false);
        defer request.deinit(allocator);
        const expected = if (index == 2) error.InvalidDurableState else if (index == 1 and mruby.features.effects_integer64) error.NumericPolicyViolation else error.TurnContractViolation;
        try std.testing.expectError(expected, host.execute(.{ .turn_id = "invalid-state", .expected_revision = 0, .input = request.view() }));
        try std.testing.expectEqual(@as(usize, 0), observer.begins + observer.effects);
        try std.testing.expect(host.db.autocommit());
        try std.testing.expectEqual(@as(i64, 5), try host.db.scalar("SELECT quantity FROM stock WHERE sku='widget'"));
        try std.testing.expectEqual(@as(i64, 0), try host.db.scalar("SELECT count(*) FROM turns"));
        try std.testing.expectEqual(@as(i64, 0), try host.db.scalar("SELECT count(*) FROM reservations"));
        try std.testing.expectEqual(@as(i64, 0), try host.db.scalar("SELECT count(*) FROM outbox"));
        var current = try host.db.prepare("SELECT state FROM current_state WHERE id=1");
        defer current.deinit();
        try std.testing.expectEqual(host_module.sql.Step.row, try current.step());
        try std.testing.expectEqualSlices(u8, invalid.encoded, try current.blob(0));
    }
}

test "durable operation and terminal contracts discard staged domain work" {
    const cases = [_]struct { mode: []const u8, err: anyerror, effects: usize, cause: ?[]const u8 = null }{
        .{ .mode = "invalid_argument", .err = error.EffectContractViolation, .effects = 0 },
        .{ .mode = "mismatched_request", .err = error.EffectHandlerFailed, .effects = 0, .cause = "ReservationRequestMismatch" },
        .{ .mode = "invalid_turn_result", .err = error.TurnContractViolation, .effects = 2 },
        .{ .mode = "invalid_next_state", .err = error.TurnContractViolation, .effects = 2 },
        .{ .mode = "mismatched_next_state", .err = error.InvalidTurnState, .effects = 2 },
        .{ .mode = "invalid_reserved_result", .err = error.InvalidTurnResult, .effects = 2 },
        .{ .mode = "rejected_after_staging", .err = error.InvalidTurnResult, .effects = 2 },
    };
    for (cases) |case| {
        var paths = try Paths.init();
        defer paths.deinit();
        var observer: Observer = .{};
        var diagnostic: mruby.strict.Turn.Diagnostic = .{};
        var host = try Host.open(allocator, paths.database, &workers, .{ .checkpoint = observer.checkpoint(), .diagnostic = &diagnostic });
        defer host.close();
        var request = try inputMode(case.mode);
        defer request.deinit(allocator);
        try std.testing.expectError(case.err, host.execute(.{ .turn_id = "invalid-domain-turn", .expected_revision = 0, .input = request.view() }));
        try expectUnpublished(&host, observer, case.effects);
        if (case.cause) |cause| try expectAdapterDiagnostic(&diagnostic, "stock.reserve", cause);
    }
}

fn expectAdapterDiagnostic(diagnostic: *const mruby.strict.Turn.Diagnostic, operation: []const u8, cause: []const u8) !void {
    try std.testing.expectEqual(.broker, diagnostic.origin);
    try std.testing.expectEqualStrings("EffectHandlerFailed", diagnostic.errorName());
    try std.testing.expectEqualStrings(cause, diagnostic.messageText());
    const detail = diagnostic.effect_detail orelse return error.MissingEffectDiagnostic;
    try std.testing.expectEqual(.handler_failed, detail.reason);
    try std.testing.expectEqualStrings(operation, detail.actualOperation());
}

test "forged changed and duplicate reservation notifications cannot publish stock or intents" {
    const cases = [_]struct { mode: []const u8, cause: []const u8, effects: usize }{
        .{ .mode = "forged_notification", .cause = "ReservationDoesNotMatch", .effects = 1 },
        .{ .mode = "mismatched_reservation", .cause = "ReservationDoesNotMatch", .effects = 1 },
        .{ .mode = "duplicate_notification", .cause = "NotificationAlreadyPending", .effects = 2 },
    };
    for (cases) |case| {
        var paths = try Paths.init();
        defer paths.deinit();
        var observer: Observer = .{};
        var diagnostic: mruby.strict.Turn.Diagnostic = .{};
        var host = try Host.open(allocator, paths.database, &workers, .{ .checkpoint = observer.checkpoint(), .diagnostic = &diagnostic });
        defer host.close();
        var request = try inputMode(case.mode);
        defer request.deinit(allocator);
        try std.testing.expectError(error.EffectHandlerFailed, host.execute(.{ .turn_id = "forged-notification", .expected_revision = 0, .input = request.view() }));
        try expectUnpublished(&host, observer, case.effects);
        try expectAdapterDiagnostic(&diagnostic, "notifications.reservation_created", case.cause);
    }
}

test "invalid typed adapter results and undeclared rejections roll back before exact retry" {
    const Fault = @TypeOf((host_module.Options{}).fault);
    const cases = [_]struct { fault: Fault, effects: usize }{
        .{ .fault = .invalid_reservation_result, .effects = 1 },
        .{ .fault = .undeclared_rejection, .effects = 1 },
        .{ .fault = .invalid_notification_result, .effects = 2 },
    };
    for (cases) |case| {
        var paths = try Paths.init();
        defer paths.deinit();
        var request = try input(2, false);
        defer request.deinit(allocator);
        {
            var observer: Observer = .{};
            var host = try Host.open(allocator, paths.database, &workers, .{ .checkpoint = observer.checkpoint(), .fault = case.fault });
            defer host.close();
            try std.testing.expectError(error.EffectContractViolation, host.execute(.{ .turn_id = "bad-adapter", .expected_revision = 0, .input = request.view() }));
            try expectUnpublished(&host, observer, case.effects);
        }
        var clean = try Host.open(allocator, paths.database, &workers, .{});
        defer clean.close();
        var result = try clean.execute(.{ .turn_id = "bad-adapter", .expected_revision = 0, .input = request.view() });
        defer result.deinit();
        try std.testing.expect(!result.reused);
        try std.testing.expectEqual(@as(usize, 2), result.effect_calls);
        try expectStatus(&clean, observed_reserved);
    }
}

test "schema one and two durable ledgers are rejected unchanged without implicit migration" {
    const legacy_one = "CREATE TABLE durable_metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL) STRICT; INSERT INTO durable_metadata VALUES('role','inventory'),('namespace','demo'),('schema','1'); CREATE TABLE legacy_inventory(sku TEXT PRIMARY KEY,quantity INTEGER NOT NULL) STRICT; INSERT INTO legacy_inventory VALUES('legacy-widget',77)";
    const legacy_two = "CREATE TABLE durable_metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL) STRICT; INSERT INTO durable_metadata VALUES('role','inventory'),('namespace','demo'),('schema','2'); CREATE TABLE legacy_inventory(sku TEXT PRIMARY KEY,quantity INTEGER NOT NULL) STRICT; INSERT INTO legacy_inventory VALUES('legacy-widget',77)";
    const legacy = [_][:0]const u8{ legacy_one, legacy_two };
    for (legacy) |setup| {
        var paths = try Paths.init();
        defer paths.deinit();
        {
            var db = try host_module.sql.Db.open(allocator, paths.database);
            defer db.close();
            try db.exec(setup);
        }
        try std.testing.expectError(error.UnsupportedDurableSchema, Host.open(allocator, paths.database, &.{ paths.missing_worker, paths.missing_worker_second }, .{}));
        var db = try host_module.sql.Db.open(allocator, paths.database);
        defer db.close();
        try std.testing.expectEqual(@as(i64, 77), try db.scalar("SELECT quantity FROM legacy_inventory WHERE sku='legacy-widget'"));
        try std.testing.expectEqual(@as(i64, 1), try db.scalar("SELECT count(*) FROM durable_metadata WHERE key='schema'"));
        try std.testing.expectEqual(@as(i64, 0), try db.scalar("SELECT count(*) FROM sqlite_schema WHERE name IN('current_state','stock','reservations','turns','turn_versions','upgrades','outbox','admissions')"));
    }
}

test "a schema-only contract change is a different application and cannot open the ledger" {
    for ([_]bool{ false, true }) |fail| {
        var paths = try Paths.init();
        defer paths.deinit();
        const turn_id = if (fail) "failed-schema-turn" else "committed-schema-turn";
        var request = try input(2, fail);
        defer request.deinit(allocator);
        var host = try Host.open(allocator, paths.database, &workers, .{});
        defer host.close();
        if (fail) {
            try std.testing.expectError(error.RubyException, host.execute(.{ .turn_id = turn_id, .expected_revision = 0, .input = request.view() }));
        } else {
            var result = try host.execute(.{ .turn_id = turn_id, .expected_revision = 0, .input = request.view() });
            defer result.deinit();
            try std.testing.expectEqual(@as(usize, 2), result.effect_calls);
        }
        // The alternate host keeps code, operations and bootstrap but changes
        // only the whole-turn schema: a different pinned application identity.
        // It fails at open, before any business write, and changes nothing.
        var alternate = try harness.Process.start(allocator, config.changed_contract_fixture_executable, paths.database, paths.missing_worker, paths.missing_worker_second, turn_id, 1, paths.recipient);
        defer alternate.deinit();
        try alternate.proceed();
        try expectStatus(&host, if (fail) .{} else observed_reserved);
        try std.testing.expectEqual(@as(i64, 1), try host.db.scalar("SELECT count(*) FROM admissions"));
        try std.testing.expectEqual(@as(i64, 0), try host.db.scalar("SELECT count(*) FROM upgrades"));
    }
}

test "cached retries validate persisted terminal contracts before starting a worker" {
    var paths = try Paths.init();
    defer paths.deinit();
    var request = try input(2, false);
    defer request.deinit(allocator);
    {
        var host = try Host.open(allocator, paths.database, &workers, .{});
        defer host.close();
        var committed = try host.execute(.{ .turn_id = "invalid-cached-terminal", .expected_revision = 0, .input = request.view() });
        defer committed.deinit();
        const receipt = try mruby.strict.Turn.Receipt.decode(committed.receipt(), .{});
        var invalid_terminal = try data.encode(allocator, .{ .array = &.{
            .{ .hash = &.{.{ .key = .{ .string = "status" }, .value = .{ .string = "invalid" } }} },
            .{ .hash = &.{.{ .key = .{ .string = "attempts" }, .value = .{ .integer = 1 } }} },
        } }, contract.max_bytes);
        defer invalid_terminal.deinit(allocator);
        // The fixture changes trusted storage and recomputes valid framing;
        // rejection must come from the terminal contract, not its checksum.
        const altered = try mruby.strict.Turn.Receipt.encode(allocator, receipt.trace, invalid_terminal.view(), .{});
        defer allocator.free(altered);
        _ = try mruby.strict.Turn.Receipt.decode(altered, .{});
        var update = try host.db.prepare("UPDATE turns SET receipt=?1 WHERE turn_id=?2");
        defer update.deinit();
        try update.bindBlob(1, altered);
        try update.bindText(2, "invalid-cached-terminal");
        try std.testing.expectEqual(host_module.sql.Step.done, try update.step());
        try std.testing.expectEqual(@as(i64, 1), host.db.changes());
    }
    var observer: Observer = .{};
    var diagnostic: mruby.strict.Turn.Diagnostic = .{};
    var cached = try Host.open(allocator, paths.database, &.{ paths.missing_worker, paths.missing_worker_second }, .{ .checkpoint = observer.checkpoint(), .diagnostic = &diagnostic });
    defer cached.close();
    try std.testing.expectError(error.TurnContractViolation, cached.execute(.{ .turn_id = "invalid-cached-terminal", .expected_revision = 0, .input = request.view() }));
    try std.testing.expectEqual(@as(usize, 0), observer.admissions + observer.begins + observer.effects);
    try std.testing.expectEqual(.result, (diagnostic.contract_detail orelse return error.MissingTurnDiagnostic).side);
    try std.testing.expectEqualStrings("TurnContractViolation", diagnostic.errorName());
    try std.testing.expect(cached.db.autocommit());
    try expectStatus(&cached, observed_reserved);
}
