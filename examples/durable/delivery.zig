//! Durable local recipient simulation. The recipient transaction records an
//! intent once; source acknowledgement is a later independent transaction.
//! A crash between those commits causes retry, never another notification.
const std = @import("std");
const sql = @import("sql.zig");
const contract = @import("durable_contract");

pub const max_intent_id_bytes: usize = 128;
pub const max_turn_id_bytes: usize = 256;
pub const max_destination_bytes: usize = 256;
pub const max_payload_bytes: usize = 1024 * 1024;

pub const Intent = struct {
    id: []const u8,
    destination: []const u8,
    payload: []const u8,
};

pub fn initRecipient(db: *sql.Db) !void {
    if (!db.autocommit()) return error.DatabaseTransactionActive;
    try db.exec("BEGIN IMMEDIATE");
    initializeRecipientTransaction(db) catch |err| return rollbackError(db, err);
}

fn initializeRecipientTransaction(db: *sql.Db) !void {
    try db.exec("CREATE TABLE IF NOT EXISTS durable_metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL)");
    try db.exec("INSERT INTO durable_metadata(key,value) VALUES('role','recipient') ON CONFLICT(key) DO NOTHING");
    try requireRole(db, "recipient");
    try db.exec("CREATE TABLE IF NOT EXISTS receipts(intent_id TEXT PRIMARY KEY,destination TEXT NOT NULL,payload BLOB NOT NULL) STRICT");
    try db.exec("CREATE TABLE IF NOT EXISTS notification_counter(singleton INTEGER PRIMARY KEY CHECK(singleton=1),count INTEGER NOT NULL CHECK(count>=0)) STRICT");
    try db.exec("INSERT INTO notification_counter(singleton,count) VALUES(1,0) ON CONFLICT(singleton) DO NOTHING");
    try db.exec("COMMIT");
}

/// Public recipient seam for testing idempotency and conflicting ID reuse.
/// The receipt row and simulated observable notification count commit together.
pub fn accept(recipient: *sql.Db, intent: Intent) !void {
    try validateIntent(intent);
    if (!recipient.autocommit()) return error.DatabaseTransactionActive;
    try requireRole(recipient, "recipient");
    try recipient.exec("BEGIN IMMEDIATE");
    acceptTransaction(recipient, intent) catch |err| return rollbackError(recipient, err);
}

fn acceptTransaction(recipient: *sql.Db, intent: Intent) !void {
    const exists = blk: {
        var lookup = try recipient.prepare("SELECT destination,payload FROM receipts WHERE intent_id=?");
        defer lookup.deinit();
        try lookup.bindText(1, intent.id);
        if (try lookup.step() == .done) break :blk false;
        if (!std.mem.eql(u8, try lookup.text(0), intent.destination) or
            !std.mem.eql(u8, try lookup.blob(1), intent.payload)) return error.IntentConflict;
        if (try lookup.step() != .done) return error.DatabaseUnexpectedRow;
        break :blk true;
    };
    if (!exists) {
        {
            var insert = try recipient.prepare("INSERT INTO receipts(intent_id,destination,payload) VALUES(?,?,?)");
            defer insert.deinit();
            try insert.bindText(1, intent.id);
            try insert.bindText(2, intent.destination);
            try insert.bindBlob(3, intent.payload);
            if (try insert.step() != .done) return error.DatabaseUnexpectedRow;
        }
        try recipient.exec("UPDATE notification_counter SET count=count+1 WHERE singleton=1");
        if (recipient.changes() != 1) return error.InvalidRecipientState;
    }
    try recipient.exec("COMMIT");
}

/// Deliver at most one pending committed intent. The caller can cap a batch by
/// invoking this at most 64 times. No source statement/transaction stays open
/// during recipient work or the delivery checkpoints.
pub fn deliverOne(allocator: std.mem.Allocator, source: *sql.Db, recipient: *sql.Db, checkpoint: contract.Checkpoint) !bool {
    if (try source.sameFile(recipient)) return error.DatabaseRoleMismatch;
    if (!source.autocommit() or !recipient.autocommit()) return error.DatabaseTransactionActive;
    try requireRole(source, "inventory");
    try requireRole(recipient, "recipient");
    var pending = (try loadOne(allocator, source)) orelse return false;
    defer pending.deinit(allocator);
    checkpoint.reach(.before_delivery);
    try accept(recipient, pending.intent());
    checkpoint.reach(.after_recipient_commit);
    try acknowledge(source, pending);
    checkpoint.reach(.after_delivery_ack);
    return true;
}

/// Acknowledge one delivered intent in its own source transaction, matching
/// the complete immutable row. A concurrent matching acknowledgement is fine;
/// changed bytes receive nothing. Shared by both dispatcher transports.
pub fn acknowledge(source: *sql.Db, pending: Pending) !void {
    try source.exec("BEGIN IMMEDIATE");
    acknowledgeTransaction(source, pending) catch |err| return rollbackError(source, err);
}

fn acknowledgeTransaction(source: *sql.Db, pending: Pending) !void {
    {
        // Match the complete immutable intent; a changed row must not receive
        // acknowledgement for different bytes. A concurrent matching ack is OK.
        var ack = try source.prepare("UPDATE outbox SET delivered=1 WHERE intent_id=? AND turn_id=? AND sequence=? AND destination=? AND payload=? AND EXISTS(SELECT 1 FROM turns WHERE turns.turn_id=outbox.turn_id)");
        defer ack.deinit();
        try ack.bindText(1, pending.id);
        try ack.bindText(2, pending.turn_id);
        try ack.bindInt(3, pending.sequence);
        try ack.bindText(4, pending.destination);
        try ack.bindBlob(5, pending.payload);
        if (try ack.step() != .done) return error.DatabaseUnexpectedRow;
        if (source.changes() != 1) return error.IntentChanged;
    }
    try source.exec("COMMIT");
}

pub fn requireRole(db: *sql.Db, expected: []const u8) !void {
    var statement = try db.prepare("SELECT value FROM durable_metadata WHERE key='role'");
    defer statement.deinit();
    if (try statement.step() != .row or !std.mem.eql(u8, try statement.text(0), expected)) return error.DatabaseRoleMismatch;
    if (try statement.step() != .done) return error.DatabaseRoleMismatch;
}

/// One pending committed intent loaded from the source outbox, owned by the
/// caller's allocator. Shared by the local and HTTP dispatchers so both
/// transports acknowledge the exact same immutable row.
pub const Pending = struct {
    id: []u8,
    turn_id: []u8,
    sequence: i64,
    destination: []u8,
    payload: []u8,

    pub fn intent(self: Pending) Intent {
        return .{ .id = self.id, .destination = self.destination, .payload = self.payload };
    }
    pub fn deinit(self: *Pending, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.turn_id);
        allocator.free(self.destination);
        allocator.free(self.payload);
        self.* = undefined;
    }
};

/// Load the oldest undelivered committed intent, if any. One definition of
/// pending intent order and bounds serves every dispatcher transport.
pub fn loadOne(allocator: std.mem.Allocator, db: *sql.Db) !?Pending {
    var query = try db.prepare("SELECT o.intent_id,o.turn_id,o.sequence,o.destination,o.payload FROM outbox AS o JOIN turns AS t ON t.turn_id=o.turn_id WHERE o.delivered=0 ORDER BY o.turn_id,o.sequence,o.intent_id LIMIT 1");
    defer query.deinit();
    if (try query.step() == .done) return null;
    const id = try query.copyText(allocator, 0, max_intent_id_bytes);
    errdefer allocator.free(id);
    const turn_id = try query.copyText(allocator, 1, max_turn_id_bytes);
    errdefer allocator.free(turn_id);
    const sequence = try query.int(2);
    if (sequence < 0 or turn_id.len == 0 or std.mem.indexOfScalar(u8, turn_id, 0) != null) return error.InvalidIntent;
    const destination = try query.copyText(allocator, 3, max_destination_bytes);
    errdefer allocator.free(destination);
    const payload = try query.copyBlob(allocator, 4, max_payload_bytes);
    errdefer allocator.free(payload);
    try validateIntent(.{ .id = id, .destination = destination, .payload = payload });
    if (try query.step() != .done) return error.DatabaseUnexpectedRow;
    return .{ .id = id, .turn_id = turn_id, .sequence = sequence, .destination = destination, .payload = payload };
}

fn validateIntent(intent: Intent) !void {
    if (intent.id.len == 0 or intent.id.len > max_intent_id_bytes or
        intent.destination.len == 0 or intent.destination.len > max_destination_bytes or
        intent.payload.len > max_payload_bytes or std.mem.indexOfScalar(u8, intent.id, 0) != null or
        std.mem.indexOfScalar(u8, intent.destination, 0) != null) return error.InvalidIntent;
}

fn rollbackError(db: *sql.Db, original: anyerror) anyerror {
    if (!db.autocommit()) {
        db.exec("ROLLBACK") catch return error.DatabaseNeedsRecovery;
        if (!db.autocommit()) return error.DatabaseNeedsRecovery;
    }
    return original;
}

test "recipient accepts exact duplicates once and rejects changed bytes under the same ID" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory, "recipient.db" });
    defer std.testing.allocator.free(path);
    var recipient = try sql.Db.open(std.testing.allocator, path);
    defer recipient.close();
    try initRecipient(&recipient);
    const intent: Intent = .{ .id = "stable-intent", .destination = "notifications", .payload = "bytes\x00preserved" };
    try accept(&recipient, intent);
    try accept(&recipient, intent);
    try std.testing.expectEqual(@as(i64, 1), try recipient.scalar("SELECT count(*) FROM receipts"));
    try std.testing.expectEqual(@as(i64, 1), try recipient.scalar("SELECT count FROM notification_counter WHERE singleton=1"));
    try std.testing.expectError(error.IntentConflict, accept(&recipient, .{ .id = intent.id, .destination = intent.destination, .payload = "different" }));
    try std.testing.expectError(error.IntentConflict, accept(&recipient, .{ .id = intent.id, .destination = "different", .payload = intent.payload }));
    try std.testing.expect(recipient.autocommit());
    try std.testing.expectEqual(@as(i64, 1), try recipient.scalar("SELECT count FROM notification_counter WHERE singleton=1"));
}

test "retry after recipient commit and failed source acknowledgement does not notify twice" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(directory);
    const source_path = try std.fs.path.join(allocator, &.{ directory, "source.db" });
    defer allocator.free(source_path);
    const recipient_path = try std.fs.path.join(allocator, &.{ directory, "recipient.db" });
    defer allocator.free(recipient_path);
    var source = try sql.Db.open(allocator, source_path);
    defer source.close();
    var blocker = try sql.Db.open(allocator, source_path);
    defer blocker.close();
    var recipient = try sql.Db.open(allocator, recipient_path);
    defer recipient.close();
    try source.exec("CREATE TABLE durable_metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL); INSERT INTO durable_metadata VALUES('role','inventory'); CREATE TABLE turns(turn_id TEXT PRIMARY KEY); CREATE TABLE outbox(intent_id TEXT PRIMARY KEY,turn_id TEXT REFERENCES turns(turn_id) DEFERRABLE INITIALLY DEFERRED,sequence INTEGER,destination TEXT,payload BLOB,delivered INTEGER CHECK(delivered IN(0,1)))");
    try source.exec("BEGIN IMMEDIATE; INSERT INTO turns VALUES('turn-1'); INSERT INTO outbox VALUES('intent-1','turn-1',0,'notifications',x'0102',0); COMMIT");
    try initRecipient(&recipient);
    const Hook = struct {
        source: *sql.Db,
        recipient: *sql.Db,
        blocker: *sql.Db,
        reached: bool = false,
        failed: bool = false,
        fn hit(raw: ?*anyopaque, phase: contract.Phase) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (!self.source.autocommit() or !self.recipient.autocommit()) self.failed = true;
            if (phase != .after_recipient_commit) return;
            self.reached = true;
            self.blocker.exec("BEGIN IMMEDIATE") catch {
                self.failed = true;
            };
        }
    };
    var hook: Hook = .{ .source = &source, .recipient = &recipient, .blocker = &blocker };
    try std.testing.expectError(error.DatabaseBusy, deliverOne(allocator, &source, &recipient, .{ .context = &hook, .hit = Hook.hit }));
    try std.testing.expect(hook.reached and !hook.failed);
    try std.testing.expect(source.autocommit() and recipient.autocommit());
    try std.testing.expectEqual(@as(i64, 0), try source.scalar("SELECT delivered FROM outbox"));
    try std.testing.expectEqual(@as(i64, 1), try recipient.scalar("SELECT count FROM notification_counter WHERE singleton=1"));
    try blocker.exec("ROLLBACK");
    try std.testing.expect(try deliverOne(allocator, &source, &recipient, .{}));
    try std.testing.expectEqual(@as(i64, 1), try source.scalar("SELECT delivered FROM outbox"));
    try std.testing.expectEqual(@as(i64, 1), try recipient.scalar("SELECT count(*) FROM receipts"));
    try std.testing.expectEqual(@as(i64, 1), try recipient.scalar("SELECT count FROM notification_counter WHERE singleton=1"));
    try std.testing.expect(!try deliverOne(allocator, &source, &recipient, .{}));
    try std.testing.expectError(error.DatabaseRoleMismatch, deliverOne(allocator, &source, &blocker, .{}));
    try std.testing.expectError(error.DatabaseRoleMismatch, initRecipient(&source));
}

test "failed rollback explicitly requires database recovery" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(directory);
    const path = try std.fs.path.join(allocator, &.{ directory, "recipient.db" });
    defer allocator.free(path);
    var recipient = try sql.Db.open(allocator, path);
    defer recipient.close();
    try initRecipient(&recipient);
    var observer = try sql.Db.open(allocator, path);
    defer observer.close();
    const Denial = struct {
        const Callback = ?*const fn (?*anyopaque, c_int, ?[*:0]const u8, ?[*:0]const u8, ?[*:0]const u8, ?[*:0]const u8) callconv(.c) c_int;
        extern "c" fn sqlite3_set_authorizer(*anyopaque, Callback, ?*anyopaque) c_int;
        fn transactions(_: ?*anyopaque, operation: c_int, first: ?[*:0]const u8, _: ?[*:0]const u8, _: ?[*:0]const u8, _: ?[*:0]const u8) callconv(.c) c_int {
            if (operation == 22) { // SQLITE_TRANSACTION
                const name = std.mem.span(first orelse return 0);
                if (std.mem.eql(u8, name, "COMMIT") or std.mem.eql(u8, name, "ROLLBACK")) return 1; // SQLITE_DENY
            }
            return 0;
        }
    };
    try std.testing.expectEqual(@as(c_int, 0), Denial.sqlite3_set_authorizer(recipient.handle, Denial.transactions, null));
    defer {
        _ = Denial.sqlite3_set_authorizer(recipient.handle, null, null);
        recipient.exec("ROLLBACK") catch {};
    }
    try std.testing.expectError(error.DatabaseNeedsRecovery, accept(&recipient, .{ .id = "uncertain", .destination = "notifications", .payload = "value" }));
    try std.testing.expect(!recipient.autocommit());
    try std.testing.expectEqual(@as(i64, 0), try observer.scalar("SELECT count(*) FROM receipts"));
    try std.testing.expectEqual(@as(i64, 0), try observer.scalar("SELECT count FROM notification_counter WHERE singleton=1"));
}
