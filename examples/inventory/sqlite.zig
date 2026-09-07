//! Minimal declarations from the pinned SQLite 3.51.3 sqlite3.h.
//! Zig's pinned toolchain has no @cImport. These declarations cover only the
//! SQLite calls used by this example; they are not a general-purpose binding.
pub const sqlite3 = opaque {};
pub const sqlite3_stmt = opaque {};
// SQLite reserves the unaligned pointer -1 for SQLITE_TRANSIENT. It is a
// sentinel, never invoked; alignment 1 allows spelling that C ABI value.
pub const sqlite3_destructor_type = ?*align(1) const fn (?*anyopaque) callconv(.c) void;
const ExecCallback = ?*const fn (?*anyopaque, c_int, [*c][*c]u8, [*c][*c]u8) callconv(.c) c_int;
pub const SQLITE_OK = 0;
pub const SQLITE_ROW = 100;
pub const SQLITE_DONE = 101;

pub extern "c" fn sqlite3_open(filename: [*:0]const u8, db: *?*sqlite3) c_int;
pub extern "c" fn sqlite3_close(db: *sqlite3) c_int;
pub extern "c" fn sqlite3_exec(db: *sqlite3, sql: [*:0]const u8, callback: ExecCallback, context: ?*anyopaque, message: ?*?[*:0]u8) c_int;
pub extern "c" fn sqlite3_prepare_v2(db: *sqlite3, sql: [*]const u8, bytes: c_int, statement: *?*sqlite3_stmt, tail: ?*[*c]const u8) c_int;
pub extern "c" fn sqlite3_finalize(statement: ?*sqlite3_stmt) c_int;
pub extern "c" fn sqlite3_step(statement: ?*sqlite3_stmt) c_int;
pub extern "c" fn sqlite3_stmt_readonly(statement: *sqlite3_stmt) c_int;
pub extern "c" fn sqlite3_bind_parameter_count(statement: *sqlite3_stmt) c_int;
pub extern "c" fn sqlite3_bind_int64(statement: *sqlite3_stmt, index: c_int, value: i64) c_int;
pub extern "c" fn sqlite3_bind_text(statement: *sqlite3_stmt, index: c_int, bytes: [*]const u8, length: c_int, destructor: sqlite3_destructor_type) c_int;
pub extern "c" fn sqlite3_column_int64(statement: ?*sqlite3_stmt, column: c_int) i64;
pub extern "c" fn sqlite3_changes(db: *sqlite3) c_int;
