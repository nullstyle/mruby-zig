//! HTTP delivery tests for the durable example: a real recipient-double
//! child process, byte-identical intent transport with an explicit
//! idempotency key, the crash window between recipient commit and source
//! acknowledgement, and fail-closed behavior when the recipient is
//! unreachable — all through public interfaces. The double is spawned as a
//! real child process and killed between scenarios; no crash supervisor is
//! needed because the crash window is driven through delivery checkpoints.
const std = @import("std");
const mruby = @import("mruby");
const host_module = @import("durable_host");
const contract = @import("durable_contract");
const http = @import("durable_http");
const config = @import("durable_test_config");
const Host = host_module.Host;
const sql = host_module.sql;
const data = mruby.effect.data;
const allocator = std.testing.allocator;

const Paths = struct {
    tmp: std.testing.TmpDir,
    directory: [:0]u8,
    database: []u8,
    recipient: []u8,

    fn init() !Paths {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const directory = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
        errdefer allocator.free(directory);
        const database = try std.fs.path.join(allocator, &.{ directory, "source.sqlite" });
        errdefer allocator.free(database);
        const recipient = try std.fs.path.join(allocator, &.{ directory, "recipient.sqlite" });
        errdefer allocator.free(recipient);
        return .{ .tmp = tmp, .directory = directory, .database = database, .recipient = recipient };
    }
    fn deinit(self: *Paths) void {
        allocator.free(self.directory);
        allocator.free(self.database);
        allocator.free(self.recipient);
        self.tmp.cleanup();
    }
};

const workers = [_][]const u8{ config.worker_executable, config.worker_v2_executable };

fn input(quantity: i64) !mruby.artifact.StateCapsule {
    return data.encode(allocator, .{ .hash = &.{
        .{ .key = .{ .string = "sku" }, .value = .{ .string = "widget" } },
        .{ .key = .{ .string = "quantity" }, .value = .{ .integer = quantity } },
        .{ .key = .{ .string = "fail" }, .value = .{ .boolean = false } },
    } }, contract.max_bytes);
}

fn openHost(paths: *const Paths) !Host {
    return Host.open(allocator, paths.database, &workers, .{ .io = std.testing.io });
}

/// Commit one v1 reservation turn staging exactly one pending intent.
fn stageIntent(paths: *const Paths, turn_id: []const u8, expected_revision: i64, quantity: i64) !void {
    var host = try openHost(paths);
    defer host.close();
    var request = try input(quantity);
    defer request.deinit(allocator);
    var turn = try host.execute(.{ .turn_id = turn_id, .expected_revision = expected_revision, .input = request.view() });
    defer turn.deinit();
    try std.testing.expectEqual(expected_revision + 1, turn.revision);
}

/// Real recipient-double process. Readiness is its "LISTENING <port>" line.
const Double = struct {
    child: std.process.Child,
    port: u16,

    fn start(paths: *const Paths) !Double {
        var child = try std.process.spawn(std.testing.io, .{
            .argv = &.{ config.http_recipient_executable, paths.recipient },
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .inherit,
        });
        errdefer child.kill(std.testing.io);
        var line_buffer: [128]u8 = undefined;
        var stdout = child.stdout.?.reader(std.testing.io, &line_buffer);
        const line = stdout.interface.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.StreamTooLong => return error.BadRecipientAnnouncement,
            else => |e| return e,
        };
        if (!std.mem.startsWith(u8, line, "LISTENING ")) return error.BadRecipientAnnouncement;
        const port = std.fmt.parseInt(u16, line["LISTENING ".len..], 10) catch return error.BadRecipientAnnouncement;
        return .{ .child = child, .port = port };
    }
    fn stop(self: *Double) void {
        self.child.kill(std.testing.io);
    }
};

fn pendingIntent(source: *sql.Db) !struct { id: []u8, payload: []u8 } {
    var query = try source.prepare("SELECT intent_id,payload FROM outbox WHERE delivered=0");
    defer query.deinit();
    if (try query.step() == .done) return error.MissingPendingIntent;
    const id = try query.copyText(allocator, 0, http.delivery.max_intent_id_bytes);
    errdefer allocator.free(id);
    const payload = try query.copyBlob(allocator, 1, http.delivery.max_payload_bytes);
    if (try query.step() != .done) return error.DatabaseUnexpectedRow;
    return .{ .id = id, .payload = payload };
}

test "HTTP dispatch delivers a committed intent once, byte for byte, and acknowledges the source" {
    var paths = try Paths.init();
    defer paths.deinit();
    try stageIntent(&paths, "turn-one", 0, 2);
    var double = try Double.start(&paths);
    defer double.stop();
    var source = try sql.Db.open(allocator, paths.database);
    defer source.close();
    const staged = try pendingIntent(&source);
    defer allocator.free(staged.id);
    defer allocator.free(staged.payload);

    try std.testing.expectEqual(@as(usize, 1), try http.dispatch(allocator, std.testing.io, &source, double.port, .{}));
    // The transported bytes at the recipient are exactly the staged outbox
    // payload under the same stable intent ID.
    var recipient = try sql.Db.open(allocator, paths.recipient);
    defer recipient.close();
    try std.testing.expectEqual(@as(i64, 1), try recipient.scalar("SELECT count FROM notification_counter WHERE singleton=1"));
    try std.testing.expectEqual(@as(i64, 1), try recipient.scalar("SELECT count(*) FROM receipts"));
    {
        var query = try recipient.prepare("SELECT intent_id,payload FROM receipts");
        defer query.deinit();
        try std.testing.expect(try query.step() == .row);
        try std.testing.expectEqualStrings(staged.id, try query.text(0));
        try std.testing.expectEqualSlices(u8, staged.payload, try query.blob(1));
        try std.testing.expect(try query.step() == .done);
    }
    try std.testing.expectEqual(@as(i64, 1), try source.scalar("SELECT delivered FROM outbox"));

    // The batch is bounded and empty once nothing is pending.
    try std.testing.expectEqual(@as(usize, 0), try http.dispatch(allocator, std.testing.io, &source, double.port, .{}));
    var host = try openHost(&paths);
    defer host.close();
    const status = try host.status();
    try std.testing.expectEqualStrings("inventory/v1", status.application);
    try std.testing.expectEqual(@as(i64, 1), status.delivered_count);
    try std.testing.expectEqual(@as(i64, 1), status.outbox_count);
}

test "a crash between send and acknowledgement re-sends without a second effect" {
    var paths = try Paths.init();
    defer paths.deinit();
    try stageIntent(&paths, "turn-one", 0, 2);
    var double = try Double.start(&paths);
    defer double.stop();
    var source = try sql.Db.open(allocator, paths.database);
    defer source.close();
    var blocker = try sql.Db.open(allocator, paths.database);
    defer blocker.close();
    // The dispatcher dies after the recipient commits but before the source
    // acknowledgement: a competing writer holds the source write lock, so the
    // acknowledgement fails exactly where the crash window sits.
    const Hook = struct {
        blocker: *sql.Db,
        reached: bool = false,
        fn hit(raw: ?*anyopaque, phase: contract.Phase) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (phase != .after_recipient_commit) return;
            self.reached = true;
            self.blocker.exec("BEGIN IMMEDIATE") catch {};
        }
    };
    var hook: Hook = .{ .blocker = &blocker };
    try std.testing.expectError(error.DatabaseBusy, http.dispatch(allocator, std.testing.io, &source, double.port, .{ .context = &hook, .hit = Hook.hit }));
    try std.testing.expect(hook.reached);
    try std.testing.expect(source.autocommit());
    try std.testing.expectEqual(@as(i64, 0), try source.scalar("SELECT delivered FROM outbox"));
    var recipient = try sql.Db.open(allocator, paths.recipient);
    defer recipient.close();
    try std.testing.expectEqual(@as(i64, 1), try recipient.scalar("SELECT count FROM notification_counter WHERE singleton=1"));

    // Retrying after the lost acknowledgement re-sends the identical bytes;
    // the recipient's stored idempotency key prevents a second notification.
    try blocker.exec("ROLLBACK");
    try std.testing.expectEqual(@as(usize, 1), try http.dispatch(allocator, std.testing.io, &source, double.port, .{}));
    try std.testing.expectEqual(@as(i64, 1), try source.scalar("SELECT delivered FROM outbox"));
    try std.testing.expectEqual(@as(i64, 1), try recipient.scalar("SELECT count FROM notification_counter WHERE singleton=1"));
    try std.testing.expectEqual(@as(i64, 1), try recipient.scalar("SELECT count(*) FROM receipts"));
}

test "the recipient double deduplicates identical keys and rejects key reuse for different bytes" {
    var paths = try Paths.init();
    defer paths.deinit();
    var double = try Double.start(&paths);
    defer double.stop();
    var client = std.http.Client{ .allocator = allocator, .io = std.testing.io };
    defer client.deinit();
    const intent: http.delivery.Intent = .{ .id = "stable-intent", .destination = "reservations", .payload = "bytes\x00preserved" };
    try http.send(&client, double.port, intent);
    try http.send(&client, double.port, intent);
    try std.testing.expectError(error.IntentConflict, http.send(&client, double.port, .{ .id = intent.id, .destination = intent.destination, .payload = "different" }));
    try std.testing.expectError(error.IntentConflict, http.send(&client, double.port, .{ .id = intent.id, .destination = "other", .payload = intent.payload }));

    // A request without an idempotency key is refused before any commit.
    var url_buffer: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buffer, "http://127.0.0.1:{d}/reservations", .{double.port});
    const response = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = "anonymous",
        .headers = .{ .content_type = .{ .override = "application/octet-stream" } },
        .redirect_behavior = .not_allowed,
    });
    try std.testing.expectEqual(std.http.Status.bad_request, response.status);

    var recipient = try sql.Db.open(allocator, paths.recipient);
    defer recipient.close();
    try std.testing.expectEqual(@as(i64, 1), try recipient.scalar("SELECT count FROM notification_counter WHERE singleton=1"));
    try std.testing.expectEqual(@as(i64, 1), try recipient.scalar("SELECT count(*) FROM receipts"));
}

test "dispatch fails closed when the recipient is unreachable and resumes after it returns" {
    var paths = try Paths.init();
    defer paths.deinit();
    try stageIntent(&paths, "turn-one", 0, 2);
    {
        var double = try Double.start(&paths);
        defer double.stop();
        var source = try sql.Db.open(allocator, paths.database);
        defer source.close();
        try std.testing.expectEqual(@as(usize, 1), try http.dispatch(allocator, std.testing.io, &source, double.port, .{}));
    }
    // A second intent stays pending while the recipient is down; dispatch
    // changes nothing and reports the transport failure.
    try stageIntent(&paths, "turn-two", 1, 1);
    var port: u16 = 0;
    {
        var double = try Double.start(&paths);
        defer double.stop();
        port = double.port;
        var source = try sql.Db.open(allocator, paths.database);
        defer source.close();
        try std.testing.expectEqual(@as(i64, 1), try source.scalar("SELECT count(*) FROM outbox WHERE delivered=0"));
    }
    var source = try sql.Db.open(allocator, paths.database);
    defer source.close();
    try std.testing.expectError(error.ConnectionRefused, http.dispatch(allocator, std.testing.io, &source, port, .{}));
    try std.testing.expectEqual(@as(i64, 1), try source.scalar("SELECT count(*) FROM outbox WHERE delivered=0"));
    try std.testing.expectEqual(@as(i64, 1), try source.scalar("SELECT count(*) FROM outbox WHERE delivered=1"));

    // Restarting the recipient on its committed database finishes delivery.
    var double = try Double.start(&paths);
    defer double.stop();
    try std.testing.expectEqual(@as(usize, 1), try http.dispatch(allocator, std.testing.io, &source, double.port, .{}));
    try std.testing.expectEqual(@as(i64, 0), try source.scalar("SELECT count(*) FROM outbox WHERE delivered=0"));
    var recipient = try sql.Db.open(allocator, paths.recipient);
    defer recipient.close();
    try std.testing.expectEqual(@as(i64, 2), try recipient.scalar("SELECT count FROM notification_counter WHERE singleton=1"));
}
