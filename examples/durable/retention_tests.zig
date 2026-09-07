//! Retention tests for the durable example: write-ahead receipt archives,
//! fail-closed retry identity for pruned turns, delivery preconditions, and
//! indeterminate-commit recovery, all through the public host interface.
const std = @import("std");
const mruby = @import("mruby");
const host_module = @import("durable_host");
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
        const archive = try std.fs.path.join(allocator, &.{ directory, "prune-archive.jsonl" });
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

/// Two delivered turns below the boundary, one above it: revision 1 (v1
/// reserved), revision 2 (upgrade), revision 3 (v2 rejected), revision 4
/// (v2 reserved). Pruning below 4 removes two turn rows and keeps one.
fn seedHistory(host: *Host) !void {
    var request = try input(2, false);
    defer request.deinit(allocator);
    var first = try host.execute(.{ .turn_id = "turn-one", .expected_revision = 0, .input = request.view() });
    defer first.deinit();
    _ = try host.upgrade(.{ .upgrade_id = "upgrade-one", .expected_revision = 1, .target = "inventory/v2" });
    var failing = try input(9, false);
    defer failing.deinit(allocator);
    var rejected = try host.execute(.{ .turn_id = "v2-rejected", .expected_revision = 2, .input = failing.view() });
    defer rejected.deinit();
    var reserved = try input(1, false);
    defer reserved.deinit(allocator);
    var second = try host.execute(.{ .turn_id = "v2-reserved", .expected_revision = 3, .input = reserved.view() });
    defer second.deinit();
}

fn readArchive(path: []const u8) ![]u8 {
    const limit: std.Io.Limit = .limited(contract.max_receipt_bytes * 2);
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, limit);
}

const ArchiveEntry = struct { turn_id: []const u8, receipt: []u8 };

fn archiveEntry(line: []const u8) !ArchiveEntry {
    const id_marker = "\"turn_id\":\"";
    const receipt_marker = "\",\"receipt\":\"";
    const id_start = std.mem.indexOf(u8, line, id_marker) orelse return error.BadArchiveLine;
    const id_span = line[id_start + id_marker.len ..];
    const id_end = std.mem.indexOfScalar(u8, id_span, '"') orelse return error.BadArchiveLine;
    const turn_id = id_span[0..id_end];
    const receipt_start = std.mem.indexOf(u8, line, receipt_marker) orelse return error.BadArchiveLine;
    const b64_start = receipt_start + receipt_marker.len;
    const b64_end = line.len - 2; // closing quote and newline
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(line[b64_start..b64_end]) catch return error.BadArchiveLine;
    const receipt = try allocator.alloc(u8, size);
    errdefer allocator.free(receipt);
    decoder.decode(receipt, line[b64_start..b64_end]) catch return error.BadArchiveLine;
    return .{ .turn_id = turn_id, .receipt = receipt };
}

test "prune archives acknowledged history and keeps pruned IDs fail closed" {
    var paths = try Paths.init();
    defer paths.deinit();
    var first_receipt: []u8 = &.{};
    defer if (first_receipt.len != 0) allocator.free(first_receipt);
    {
        var host = try openHost(&paths);
        defer host.close();
        try seedHistory(&host);
        try std.testing.expectEqual(@as(usize, 2), try host.dispatch(paths.recipient));
        var historical = try host.replay("turn-one");
        defer historical.deinit();
        first_receipt = try allocator.dupe(u8, historical.receipt());

        const pruned = try host.prune(.{ .before_revision = 4, .archive_path = paths.archive });
        try std.testing.expectEqual(@as(usize, 2), pruned.pruned);
        // Admissions stay bound for every request the ledger ever admitted.
        try std.testing.expectEqual(@as(i64, 3), try host.db.scalar("SELECT count(*) FROM admissions"));
        try std.testing.expectEqual(@as(i64, 1), try host.db.scalar("SELECT count(*) FROM turns"));
        try std.testing.expectEqual(@as(i64, 1), try host.db.scalar("SELECT count(*) FROM turn_versions"));
        try std.testing.expectEqual(@as(i64, 1), try host.db.scalar("SELECT count(*) FROM reservations"));
        try std.testing.expectEqual(@as(i64, 1), try host.db.scalar("SELECT count(*) FROM outbox"));
        const status = try host.status();
        try std.testing.expectEqualStrings("inventory/v2", status.application);
        try std.testing.expectEqual(@as(i64, 4), status.revision);
        try std.testing.expectEqual(@as(i64, 1), status.turn_count);
        try std.testing.expectEqual(@as(i64, 2), status.stock);
        try std.testing.expectEqual(@as(i64, 1), status.delivered_count);

        // A pruned request fails closed: under the upgraded application its
        // kept admission no longer matches any computable fingerprint, and
        // same-version pruned IDs stale out instead. Either way the turn can
        // never execute again; its receipt is gone from replay.
        var original = try input(2, false);
        defer original.deinit(allocator);
        try std.testing.expectError(error.TurnIdConflict, host.execute(.{ .turn_id = "turn-one", .expected_revision = 0, .input = original.view() }));
        try std.testing.expectError(error.UnknownTurn, host.replay("turn-one"));
        var survivor = try host.replay("v2-reserved");
        defer survivor.deinit();
        // Fresh work continues on the same ledger.
        var fresh = try input(1, false);
        defer fresh.deinit(allocator);
        var next = try host.execute(.{ .turn_id = "post-prune", .expected_revision = 4, .input = fresh.view() });
        defer next.deinit();
        try std.testing.expectEqual(@as(i64, 5), next.revision);
    }
    // The write-ahead archive holds one self-describing line per pruned turn,
    // oldest first, with the original receipt bytes recoverable.
    const archive = try readArchive(paths.archive);
    defer allocator.free(archive);
    var lines = std.mem.splitScalar(u8, archive, '\n');
    const first_line = lines.next() orelse return error.MissingArchiveLine;
    const second_line = lines.next() orelse return error.MissingArchiveLine;
    try std.testing.expectEqualStrings("", lines.next() orelse return error.TrailingArchiveData);
    const entry_one = try archiveEntry(first_line);
    defer allocator.free(entry_one.receipt);
    const entry_two = try archiveEntry(second_line);
    defer allocator.free(entry_two.receipt);
    try std.testing.expectEqualStrings("turn-one", entry_one.turn_id);
    try std.testing.expectEqualStrings("v2-rejected", entry_two.turn_id);
    try std.testing.expect(std.mem.indexOf(u8, first_line, "\"revision\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_line, "\"application\":\"") != null);
    _ = try mruby.strict.Turn.Receipt.decode(entry_one.receipt, .{});
    try std.testing.expectEqualSlices(u8, first_receipt, entry_one.receipt);
}

test "prune refuses pending intents and invalid requests without changing storage" {
    var paths = try Paths.init();
    defer paths.deinit();
    var host = try openHost(&paths);
    defer host.close();
    var request = try input(2, false);
    defer request.deinit(allocator);
    var first = try host.execute(.{ .turn_id = "turn-one", .expected_revision = 0, .input = request.view() });
    defer first.deinit();

    // The staged intent is still pending delivery.
    try std.testing.expectError(error.UndeliveredIntents, host.prune(.{ .before_revision = 2, .archive_path = paths.archive }));
    try std.testing.expectEqual(@as(i64, 1), try host.db.scalar("SELECT count(*) FROM turns"));
    try std.testing.expectError(error.InvalidRevision, host.prune(.{ .before_revision = 0, .archive_path = paths.archive }));
    try std.testing.expectError(error.InvalidName, host.prune(.{ .before_revision = 2, .archive_path = "" }));

    try std.testing.expectEqual(@as(usize, 1), try host.dispatch(paths.recipient));
    const pruned = try host.prune(.{ .before_revision = 2, .archive_path = paths.archive });
    try std.testing.expectEqual(@as(usize, 1), pruned.pruned);
    try std.testing.expectEqual(@as(i64, 0), try host.db.scalar("SELECT count(*) FROM turns"));
    try std.testing.expectEqual(@as(i64, 1), try host.db.scalar("SELECT count(*) FROM admissions"));

    // A host opened without threaded I/O cannot archive, so it cannot prune.
    var no_io = try Host.open(allocator, paths.database, &workers, .{});
    defer no_io.close();
    var fresh = try input(1, false);
    defer fresh.deinit(allocator);
    var io_less = try no_io.execute(.{ .turn_id = "io-less", .expected_revision = 1, .input = fresh.view() });
    defer io_less.deinit();
    try std.testing.expectEqual(@as(usize, 1), try no_io.dispatch(paths.recipient));
    // Same-version retries of pruned IDs stale out on their kept admission.
    var retry = try input(2, false);
    defer retry.deinit(allocator);
    try std.testing.expectError(error.StaleState, no_io.execute(.{ .turn_id = "turn-one", .expected_revision = 0, .input = retry.view() }));
    try std.testing.expectError(error.IoUnavailable, no_io.prune(.{ .before_revision = 3, .archive_path = paths.archive }));
    try std.testing.expectEqual(@as(i64, 1), try no_io.db.scalar("SELECT count(*) FROM turns"));
}

test "a zero-turn prune leaves the archive untouched" {
    var paths = try Paths.init();
    defer paths.deinit();
    var host = try openHost(&paths);
    defer host.close();
    var request = try input(2, false);
    defer request.deinit(allocator);
    var first = try host.execute(.{ .turn_id = "turn-one", .expected_revision = 0, .input = request.view() });
    defer first.deinit();
    try std.testing.expectEqual(@as(usize, 1), try host.dispatch(paths.recipient));

    // Nothing is older than revision one, and nothing has ever been archived.
    const none = try host.prune(.{ .before_revision = 1, .archive_path = paths.archive });
    try std.testing.expectEqual(@as(usize, 0), none.pruned);
    try std.testing.expectError(error.FileNotFound, readArchive(paths.archive));

    // A sentinel archive from an earlier batch is never rewritten by a no-op.
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = paths.archive, .data = "sentinel\n" });
    _ = try host.prune(.{ .before_revision = 1, .archive_path = paths.archive });
    const archive = try readArchive(paths.archive);
    defer allocator.free(archive);
    try std.testing.expectEqualStrings("sentinel\n", archive);
}

test "an indeterminate prune COMMIT resolves after reopen with the archive intact" {
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
        var host = try openHost(&paths);
        defer host.close();
        var request = try input(2, false);
        defer request.deinit(allocator);
        var first = try host.execute(.{ .turn_id = "turn-one", .expected_revision = 0, .input = request.view() });
        defer first.deinit();
        try std.testing.expectEqual(@as(usize, 1), try host.dispatch(paths.recipient));
        try std.testing.expectEqual(@as(c_int, 0), Fault.sqlite3_set_authorizer(host.db.handle, Fault.authorize, &fault));
        defer _ = Fault.sqlite3_set_authorizer(host.db.handle, null, null);
        try std.testing.expectError(error.CommitIndeterminate, host.prune(.{ .before_revision = 2, .archive_path = paths.archive }));
        try std.testing.expectEqual(@as(usize, 1), fault.commits);
        try std.testing.expectEqual(@as(usize, 0), fault.rollbacks);
        try std.testing.expectError(error.HostNeedsRecovery, host.status());
    }
    // The denied COMMIT left the turns in place while the write-ahead archive
    // already exists; a fresh connection retries and completes the prune.
    var reopened = try openHost(&paths);
    defer reopened.close();
    try std.testing.expectEqual(@as(i64, 1), try reopened.db.scalar("SELECT count(*) FROM turns"));
    const archive_before = try readArchive(paths.archive);
    defer allocator.free(archive_before);
    try std.testing.expect(std.mem.indexOf(u8, archive_before, "turn-one") != null);
    const pruned = try reopened.prune(.{ .before_revision = 2, .archive_path = paths.archive });
    try std.testing.expectEqual(@as(usize, 1), pruned.pruned);
    try std.testing.expectEqual(@as(i64, 0), try reopened.db.scalar("SELECT count(*) FROM turns"));
    try std.testing.expectEqual(@as(i64, 1), try reopened.db.scalar("SELECT count(*) FROM admissions"));
    const archive_after = try readArchive(paths.archive);
    defer allocator.free(archive_after);
    try std.testing.expectEqualStrings(archive_before, archive_after);
}
