//! Small, bounded SQLite interface for the durable example. All SQL is trusted
//! application code; values use bindings. Borrowed columns expire on step/finalize.
//! WAL + FULL is verified on every open. Tests exercise process termination,
//! not power loss, filesystem failures, or dishonest storage flush completion.
const std = @import("std");
const builtin = @import("builtin");

pub const max_sql_bytes: usize = 64 * 1024;
pub const max_value_bytes: usize = 64 * 1024 * 1024;
pub const max_path_bytes: usize = 4096;
pub const Error = error{
    InvalidDatabasePath,
    InvalidSQL,
    DatabaseOpenFailed,
    DatabaseBusy,
    DatabaseConstraint,
    DatabaseIO,
    DatabaseFull,
    DatabaseCorrupt,
    DatabaseReadOnly,
    DatabaseFailure,
    DatabaseConfiguration,
    DatabaseValueTooLarge,
    DatabaseTypeMismatch,
    DatabaseColumnOutOfBounds,
    DatabaseBindOutOfBounds,
    DatabaseStatementState,
    DatabaseExpectedRow,
    DatabaseUnexpectedRow,
    DatabaseFileIdentityFailed,
    OutOfMemory,
};

pub const Db = struct {
    handle: *sqlite3,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Db {
        // Never silently turn a durable database into a temporary/in-memory DB
        // or interpret URI query parameters supplied as a pathname.
        if (path.len == 0 or path.len > max_path_bytes or std.mem.indexOfScalar(u8, path, 0) != null or
            std.mem.eql(u8, path, ":memory:") or std.mem.startsWith(u8, path, "file:")) return error.InvalidDatabasePath;
        const terminated = try allocator.dupeSentinel(u8, path, 0);
        defer allocator.free(terminated);
        var handle: ?*sqlite3 = null;
        const result = sqlite3_open_v2(terminated, &handle, 0x2 | 0x4 | 0x8000 | 0x40000, null); // READWRITE|CREATE|NOMUTEX|PRIVATECACHE
        if (result != 0) {
            if (handle) |value| _ = sqlite3_close_v2(value);
            try check(result);
            return error.DatabaseOpenFailed;
        }
        var db: Db = .{ .handle = handle orelse return error.DatabaseOpenFailed };
        errdefer db.close();
        try check(sqlite3_extended_result_codes(db.handle, 1));
        try check(sqlite3_busy_timeout(db.handle, 100));
        _ = sqlite3_limit(db.handle, 0, max_value_bytes); // SQLITE_LIMIT_LENGTH
        _ = sqlite3_limit(db.handle, 1, max_sql_bytes); // SQLITE_LIMIT_SQL_LENGTH
        _ = sqlite3_limit(db.handle, 2, 128); // SQLITE_LIMIT_COLUMN
        _ = sqlite3_limit(db.handle, 7, 0); // SQLITE_LIMIT_ATTACHED
        _ = sqlite3_limit(db.handle, 9, 64); // SQLITE_LIMIT_VARIABLE_NUMBER
        try db.exec("PRAGMA foreign_keys=ON");
        if (try db.scalar("PRAGMA foreign_keys") != 1) return error.DatabaseConfiguration;
        {
            var statement = try db.prepare("PRAGMA journal_mode=WAL");
            defer statement.deinit();
            if (try statement.step() != .row or !std.mem.eql(u8, try statement.text(0), "wal")) return error.DatabaseConfiguration;
            if (try statement.step() != .done) return error.DatabaseConfiguration;
        }
        try db.exec("PRAGMA synchronous=FULL");
        if (try db.scalar("PRAGMA synchronous") != 2) return error.DatabaseConfiguration;
        if (comptime builtin.os.tag == .macos) {
            try db.exec("PRAGMA fullfsync=ON");
            if (try db.scalar("PRAGMA fullfsync") != 1) return error.DatabaseConfiguration;
        }
        return db;
    }

    /// Statements must be finalized before closing their owner.
    pub fn close(self: *Db) void {
        const result = sqlite3_close_v2(self.handle);
        std.debug.assert(result == 0);
        self.* = undefined;
    }

    pub fn exec(self: *Db, query: [:0]const u8) Error!void {
        if (query.len == 0 or query.len > max_sql_bytes or std.mem.indexOfScalar(u8, query, 0) != null) return error.InvalidSQL;
        try check(sqlite3_exec(self.handle, query.ptr, null, null, null));
    }

    pub fn prepare(self: *Db, query: []const u8) Error!Statement {
        if (query.len == 0 or query.len > max_sql_bytes or std.mem.indexOfScalar(u8, query, 0) != null) return error.InvalidSQL;
        var native: ?*sqlite3_stmt = null;
        var tail: ?[*]const u8 = null;
        const result = sqlite3_prepare_v2(self.handle, query.ptr, @intCast(query.len), &native, &tail);
        errdefer {
            if (native) |value| _ = sqlite3_finalize(value);
        }
        try check(result);
        const statement = native orelse return error.InvalidSQL;
        const end = tail orelse return error.InvalidSQL;
        const consumed = @intFromPtr(end) - @intFromPtr(query.ptr);
        if (consumed > query.len or std.mem.trim(u8, query[consumed..], " \t\r\n;").len != 0) return error.InvalidSQL;
        return .{ .handle = statement };
    }

    pub fn scalar(self: *Db, query: [:0]const u8) Error!i64 {
        var statement = try self.prepare(query);
        defer statement.deinit();
        if (try statement.step() != .row) return error.DatabaseExpectedRow;
        const value = try statement.int(0);
        if (try statement.step() != .done) return error.DatabaseUnexpectedRow;
        return value;
    }
    pub fn changes(self: *const Db) i64 {
        return sqlite3_changes64(self.handle);
    }
    pub fn autocommit(self: *const Db) bool {
        return sqlite3_get_autocommit(self.handle) != 0;
    }
    /// Path strings alone miss hard-link aliases. Do not rename/replace an
    /// open database; this utility compares the current main-file inodes.
    pub fn sameFile(self: *const Db, other: *const Db) Error!bool {
        const first = sqlite3_db_filename(self.handle, "main") orelse return error.DatabaseFileIdentityFailed;
        const second = sqlite3_db_filename(other.handle, "main") orelse return error.DatabaseFileIdentityFailed;
        var same: c_int = 0;
        if (mrz_durable_same_file(first, second, 0, &same) != 0) return error.DatabaseFileIdentityFailed;
        return same != 0;
    }
    /// Reject an existing pathname alias before opening a second SQLite handle
    /// (and before that alias can acquire its own ambiguous WAL sidecars).
    pub fn samePath(self: *const Db, allocator: std.mem.Allocator, path: []const u8) !bool {
        if (path.len == 0 or path.len > max_path_bytes or std.mem.indexOfScalar(u8, path, 0) != null or
            std.mem.eql(u8, path, ":memory:") or std.mem.startsWith(u8, path, "file:")) return error.InvalidDatabasePath;
        const terminated = try allocator.dupeSentinel(u8, path, 0);
        defer allocator.free(terminated);
        const current = sqlite3_db_filename(self.handle, "main") orelse return error.DatabaseFileIdentityFailed;
        var same: c_int = 0;
        if (mrz_durable_same_file(current, terminated, 1, &same) != 0) return error.DatabaseFileIdentityFailed;
        return same != 0;
    }
};

pub const Step = enum { row, done };
pub const Statement = struct {
    handle: *sqlite3_stmt,
    state: enum { ready, row, done, failed } = .ready,

    pub fn deinit(self: *Statement) void {
        // Finalize also returns the previous step error. That error already
        // crossed step(); finalization must still release the native resource.
        _ = sqlite3_finalize(self.handle);
        self.* = undefined;
    }
    fn bindIndex(self: *const Statement, index: usize) Error!c_int {
        if (self.state != .ready) return error.DatabaseStatementState;
        if (index == 0 or index > @as(usize, @intCast(sqlite3_bind_parameter_count(self.handle)))) return error.DatabaseBindOutOfBounds;
        return @intCast(index);
    }
    pub fn bindInt(self: *Statement, index: usize, value: i64) Error!void {
        try check(sqlite3_bind_int64(self.handle, try self.bindIndex(index), value));
    }
    pub fn bindText(self: *Statement, index: usize, value: []const u8) Error!void {
        if (value.len > max_value_bytes) return error.DatabaseValueTooLarge;
        try check(sqlite3_bind_text(self.handle, try self.bindIndex(index), if (value.len == 0) "" else value.ptr, @intCast(value.len), transient));
    }
    pub fn bindBlob(self: *Statement, index: usize, value: []const u8) Error!void {
        if (value.len > max_value_bytes) return error.DatabaseValueTooLarge;
        try check(sqlite3_bind_blob(self.handle, try self.bindIndex(index), if (value.len == 0) "" else value.ptr, @intCast(value.len), transient));
    }
    /// Rebind a statement that reached `.done` for another row. Only valid
    /// after a completed step; binds from the previous row are cleared.
    pub fn reset(self: *Statement) void {
        _ = sqlite3_reset(self.handle);
        self.state = .ready;
    }
    pub fn step(self: *Statement) Error!Step {
        if (self.state == .done or self.state == .failed) return error.DatabaseStatementState;
        switch (sqlite3_step(self.handle)) {
            100 => {
                self.state = .row;
                return .row;
            },
            101 => {
                self.state = .done;
                return .done;
            },
            else => |result| {
                self.state = .failed;
                try check(result);
                return error.DatabaseFailure;
            },
        }
    }
    fn column(self: *const Statement, index: usize, kind: c_int) Error!c_int {
        if (self.state != .row) return error.DatabaseStatementState;
        if (index >= @as(usize, @intCast(sqlite3_column_count(self.handle)))) return error.DatabaseColumnOutOfBounds;
        const native: c_int = @intCast(index);
        if (sqlite3_column_type(self.handle, native) != kind) return error.DatabaseTypeMismatch;
        return native;
    }
    pub fn int(self: *const Statement, index: usize) Error!i64 {
        return sqlite3_column_int64(self.handle, try self.column(index, 1)); // SQLITE_INTEGER
    }
    pub fn text(self: *const Statement, index: usize) Error![]const u8 {
        const native = try self.column(index, 3); // SQLITE_TEXT
        const pointer = sqlite3_column_text(self.handle, native);
        const length = sqlite3_column_bytes(self.handle, native);
        if (length < 0 or length > max_value_bytes) return error.DatabaseValueTooLarge;
        if (length == 0) {
            if (pointer == null and sqlite3_errcode(sqlite3_db_handle(self.handle)) == 7) return error.OutOfMemory;
            return &.{};
        }
        return (pointer orelse return error.OutOfMemory)[0..@intCast(length)];
    }
    pub fn blob(self: *const Statement, index: usize) Error![]const u8 {
        const native = try self.column(index, 4); // SQLITE_BLOB
        const pointer = sqlite3_column_blob(self.handle, native);
        const length = sqlite3_column_bytes(self.handle, native);
        if (length < 0 or length > max_value_bytes) return error.DatabaseValueTooLarge;
        if (length == 0) {
            if (pointer == null and sqlite3_errcode(sqlite3_db_handle(self.handle)) == 7) return error.OutOfMemory;
            return &.{};
        }
        return @as([*]const u8, @ptrCast(pointer orelse return error.OutOfMemory))[0..@intCast(length)];
    }
    pub fn copyText(self: *const Statement, allocator: std.mem.Allocator, index: usize, max_bytes: usize) ![]u8 {
        const value = try self.text(index);
        if (value.len > max_bytes) return error.DatabaseValueTooLarge;
        return allocator.dupe(u8, value);
    }
    pub fn copyBlob(self: *const Statement, allocator: std.mem.Allocator, index: usize, max_bytes: usize) ![]u8 {
        const value = try self.blob(index);
        if (value.len > max_bytes) return error.DatabaseValueTooLarge;
        return allocator.dupe(u8, value);
    }
};

fn check(result: c_int) Error!void {
    return switch (result & 0xff) {
        0 => {},
        5, 6 => error.DatabaseBusy,
        7 => error.OutOfMemory,
        8 => error.DatabaseReadOnly,
        10 => error.DatabaseIO,
        11, 26 => error.DatabaseCorrupt,
        13 => error.DatabaseFull,
        18 => error.DatabaseValueTooLarge,
        19 => error.DatabaseConstraint,
        else => error.DatabaseFailure,
    };
}

// Exact C declarations for the pinned amalgamation; no generated cImport.
const sqlite3 = opaque {};
const sqlite3_stmt = opaque {};
const Destructor = ?*align(1) const fn (?*anyopaque) callconv(.c) void;
const transient: Destructor = @ptrFromInt(std.math.maxInt(usize));
const ExecCallback = ?*const fn (?*anyopaque, c_int, [*c][*c]u8, [*c][*c]u8) callconv(.c) c_int;
extern "c" fn sqlite3_open_v2([*:0]const u8, *?*sqlite3, c_int, ?[*:0]const u8) c_int;
extern "c" fn sqlite3_close_v2(*sqlite3) c_int;
extern "c" fn sqlite3_extended_result_codes(*sqlite3, c_int) c_int;
extern "c" fn sqlite3_busy_timeout(*sqlite3, c_int) c_int;
extern "c" fn sqlite3_limit(*sqlite3, c_int, c_int) c_int;
extern "c" fn sqlite3_exec(*sqlite3, [*:0]const u8, ExecCallback, ?*anyopaque, ?*?[*:0]u8) c_int;
extern "c" fn sqlite3_prepare_v2(*sqlite3, [*]const u8, c_int, *?*sqlite3_stmt, *?[*]const u8) c_int;
extern "c" fn sqlite3_finalize(*sqlite3_stmt) c_int;
extern "c" fn sqlite3_reset(*sqlite3_stmt) c_int;
extern "c" fn sqlite3_step(*sqlite3_stmt) c_int;
extern "c" fn sqlite3_bind_parameter_count(*sqlite3_stmt) c_int;
extern "c" fn sqlite3_bind_int64(*sqlite3_stmt, c_int, i64) c_int;
extern "c" fn sqlite3_bind_text(*sqlite3_stmt, c_int, [*]const u8, c_int, Destructor) c_int;
extern "c" fn sqlite3_bind_blob(*sqlite3_stmt, c_int, *const anyopaque, c_int, Destructor) c_int;
extern "c" fn sqlite3_column_count(*sqlite3_stmt) c_int;
extern "c" fn sqlite3_column_type(*sqlite3_stmt, c_int) c_int;
extern "c" fn sqlite3_column_int64(*sqlite3_stmt, c_int) i64;
extern "c" fn sqlite3_column_text(*sqlite3_stmt, c_int) ?[*]const u8;
extern "c" fn sqlite3_column_blob(*sqlite3_stmt, c_int) ?*const anyopaque;
extern "c" fn sqlite3_column_bytes(*sqlite3_stmt, c_int) c_int;
extern "c" fn sqlite3_db_handle(*sqlite3_stmt) *sqlite3;
extern "c" fn sqlite3_errcode(*sqlite3) c_int;
extern "c" fn sqlite3_changes64(*sqlite3) i64;
extern "c" fn sqlite3_get_autocommit(*sqlite3) c_int;
extern "c" fn sqlite3_db_filename(*sqlite3, [*:0]const u8) ?[*:0]const u8;
extern "c" fn mrz_durable_same_file([*:0]const u8, [*:0]const u8, c_int, *c_int) c_int;

test "durable SQLite requires an explicit disk pathname" {
    for ([_][]const u8{ "", ":memory:", "file:example?mode=memory", "bad\x00path" }) |path| {
        try std.testing.expectError(error.InvalidDatabasePath, Db.open(std.testing.allocator, path));
    }
}

test "durable SQLite verifies WAL and full synchronization and preserves typed empty values" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory, "values.db" });
    defer std.testing.allocator.free(path);
    var db = try Db.open(std.testing.allocator, path);
    defer db.close();
    try std.testing.expectEqual(@as(i64, 2), try db.scalar("PRAGMA synchronous"));
    try std.testing.expectEqual(@as(i64, 1), try db.scalar("PRAGMA foreign_keys"));
    try db.exec("CREATE TABLE items(number INTEGER, label TEXT, payload BLOB) STRICT");
    {
        var statement = try db.prepare("INSERT INTO items VALUES(?,?,?)");
        defer statement.deinit();
        try std.testing.expectError(error.DatabaseBindOutOfBounds, statement.bindInt(0, 1));
        try statement.bindInt(1, 42);
        try statement.bindText(2, "");
        try statement.bindBlob(3, &.{});
        try std.testing.expectEqual(Step.done, try statement.step());
    }
    {
        var statement = try db.prepare("SELECT number,label,payload,NULL FROM items");
        defer statement.deinit();
        try std.testing.expectError(error.DatabaseStatementState, statement.int(0));
        try std.testing.expectEqual(Step.row, try statement.step());
        try std.testing.expectEqual(@as(i64, 42), try statement.int(0));
        try std.testing.expectEqualStrings("", try statement.text(1));
        try std.testing.expectEqual(@as(usize, 0), (try statement.blob(2)).len);
        try std.testing.expectError(error.DatabaseTypeMismatch, statement.text(0));
        try std.testing.expectError(error.DatabaseTypeMismatch, statement.int(1));
        try std.testing.expectError(error.DatabaseTypeMismatch, statement.blob(3));
        try std.testing.expectError(error.DatabaseColumnOutOfBounds, statement.int(4));
        try std.testing.expectEqual(Step.done, try statement.step());
    }
    try std.testing.expectError(error.InvalidSQL, db.prepare("SELECT 1; SELECT 2"));
    try std.testing.expectError(error.InvalidSQL, db.prepare("SELECT 1\x00; SELECT 2"));
}

test "durable SQLite reports write contention and recognizes the same database file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory, "busy.db" });
    defer std.testing.allocator.free(path);
    var first = try Db.open(std.testing.allocator, path);
    defer first.close();
    var second = try Db.open(std.testing.allocator, path);
    defer second.close();
    try std.testing.expect(try first.sameFile(&second));
    const alias = try std.fs.path.join(std.testing.allocator, &.{ directory, "alias.db" });
    defer std.testing.allocator.free(alias);
    const path_z = try std.testing.allocator.dupeSentinel(u8, path, 0);
    defer std.testing.allocator.free(path_z);
    const alias_z = try std.testing.allocator.dupeSentinel(u8, alias, 0);
    defer std.testing.allocator.free(alias_z);
    try std.testing.expect(!try first.samePath(std.testing.allocator, alias));
    try std.testing.expectEqual(@as(c_int, 0), std.c.link(path_z, alias_z));
    try std.testing.expect(try first.samePath(std.testing.allocator, alias));
    try first.exec("BEGIN IMMEDIATE");
    defer first.exec("ROLLBACK") catch {};
    try std.testing.expect(!first.autocommit());
    try std.testing.expectError(error.DatabaseBusy, second.exec("BEGIN IMMEDIATE"));
    try std.testing.expect(second.autocommit());
}
