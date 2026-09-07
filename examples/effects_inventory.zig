//! SQLite-backed identified method calls, recoverable effects and replay.
//!   zig build run-effects-inventory -Deffects-strict=true -Dsqlite-effects=true
//!   zig build test-effects-inventory -Dsqlite-effects=true -Dno-compiler
//! SQLite is a lazy, hash-pinned amalgamation; no system SQLite is required.
const std = @import("std");
const mruby = @import("mruby");
const manifest = @import("inventory_manifest");
const contract = @import("inventory/contract.zig");
const sqlite = @import("inventory/sqlite.zig");

const Intent = struct { destination: []u8, payload: []u8 };
const Host = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    db: ?*sqlite.sqlite3 = null,
    read_callbacks: usize = 0,
    write_callbacks: usize = 0,
    enqueue_callbacks: usize = 0,
    intents: std.ArrayList(Intent) = .empty,
    used: bool = false,

    fn init(allocator: std.mem.Allocator, io: std.Io) !Host {
        var host: Host = .{ .allocator = allocator, .io = io };
        errdefer host.deinit();
        if (sqlite.sqlite3_open(":memory:", &host.db) != sqlite.SQLITE_OK) return error.SQLiteOpenFailed;
        try host.execHost(contract.fixture);
        return host;
    }

    fn discardIntents(host: *Host) void {
        for (host.intents.items) |intent| {
            host.allocator.free(intent.destination);
            host.allocator.free(intent.payload);
        }
        host.intents.clearRetainingCapacity();
    }

    fn deinit(host: *Host) void {
        host.discardIntents();
        host.intents.deinit(host.allocator);
        if (host.db) |db| std.debug.assert(sqlite.sqlite3_close(db) == sqlite.SQLITE_OK);
    }

    fn execHost(host: *Host, sql: [:0]const u8) !void {
        if (sqlite.sqlite3_exec(host.db orelse return error.ReplayTouchedDatabase, sql.ptr, null, null, null) != sqlite.SQLITE_OK)
            return error.SQLiteExecutionFailed;
    }

    fn scalar(host: *Host, sql: [:0]const u8) !i64 {
        var statement: ?*sqlite.sqlite3_stmt = null;
        if (sqlite.sqlite3_prepare_v2(host.db.?, sql.ptr, -1, &statement, null) != sqlite.SQLITE_OK) return error.SQLitePrepareFailed;
        defer _ = sqlite.sqlite3_finalize(statement);
        if (sqlite.sqlite3_step(statement) != sqlite.SQLITE_ROW) return error.SQLiteStepFailed;
        return sqlite.sqlite3_column_int64(statement, 0);
    }

    // The example deliberately exposes three exact statements, not a general
    // SQL capability. This excludes PRAGMA/ATTACH, transaction control, DDL,
    // arbitrary functions and multi-statement strings before preparing SQL.
    fn prepare(host: *Host, sql: []const u8, parameters: mruby.Array, read_only: bool) !*sqlite.sqlite3_stmt {
        const is_read = std.mem.eql(u8, sql, contract.read_stock);
        const is_write = std.mem.eql(u8, sql, contract.reserve_stock) or std.mem.eql(u8, sql, contract.insert_reservation);
        if ((read_only and !is_read) or (!read_only and !is_write)) return error.StatementNotAllowed;
        const db = host.db orelse return error.ReplayTouchedDatabase;
        var statement: ?*sqlite.sqlite3_stmt = null;
        var tail: [*c]const u8 = null;
        if (sqlite.sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len), &statement, &tail) != sqlite.SQLITE_OK) return error.SQLitePrepareFailed;
        const stmt = statement orelse return error.EmptyStatement;
        errdefer _ = sqlite.sqlite3_finalize(stmt);
        if (tail != sql.ptr + sql.len) return error.MultipleStatements;
        if ((sqlite.sqlite3_stmt_readonly(stmt) != 0) != read_only) return error.StatementAuthorityMismatch;
        if (parameters.len() > 3 or parameters.len() != sqlite.sqlite3_bind_parameter_count(stmt)) return error.InvalidParameters;
        for (0..parameters.len()) |i| {
            const value = try parameters.get(i);
            const index: c_int = @intCast(i + 1);
            const quantity_parameter = if (std.mem.eql(u8, sql, contract.reserve_stock)) i != 1 else std.mem.eql(u8, sql, contract.insert_reservation) and i == 1;
            const status = if (quantity_parameter) blk: {
                const number = try value.asInt();
                if (number <= 0 or number > 1000) return error.InvalidQuantity;
                break :blk sqlite.sqlite3_bind_int64(stmt, index, number);
            } else blk: {
                const string = try value.asString();
                if (string.len == 0 or string.len > 128) return error.InvalidSku;
                const transient: sqlite.sqlite3_destructor_type = @ptrFromInt(std.math.maxInt(usize));
                break :blk sqlite.sqlite3_bind_text(stmt, index, string.ptr, @intCast(string.len), transient);
            };
            if (status != sqlite.SQLITE_OK) return error.SQLiteBindFailed;
        }
        return stmt;
    }

    fn rows(context: ?*anyopaque, vm: *mruby.Vm, args: mruby.Value) !mruby.Value {
        const host: *Host = @ptrCast(@alignCast(context.?));
        host.read_callbacks += 1;
        const values = try args.asArray();
        const sql = try host.allocator.dupe(u8, try (try values.get(0)).asString());
        defer host.allocator.free(sql);
        const stmt = try host.prepare(sql, try (try values.get(1)).asArray(), true);
        defer _ = sqlite.sqlite3_finalize(stmt);
        var rows_value = try vm.array(&.{});
        while (true) {
            switch (sqlite.sqlite3_step(stmt)) {
                sqlite.SQLITE_DONE => break,
                sqlite.SQLITE_ROW => {
                    if (rows_value.len() >= 8) return error.TooManyRows;
                    const row = try vm.array(&.{try vm.intValue(sqlite.sqlite3_column_int64(stmt, 0))});
                    try rows_value.append(row.asValue());
                },
                else => return error.SQLiteStepFailed,
            }
        }
        return rows_value.asValue();
    }

    fn executeWrite(context: ?*anyopaque, vm: *mruby.Vm, args: mruby.Value) !mruby.effect.Outcome {
        const host: *Host = @ptrCast(@alignCast(context.?));
        host.write_callbacks += 1;
        const values = try args.asArray();
        const sql = try host.allocator.dupe(u8, try (try values.get(0)).asString());
        defer host.allocator.free(sql);
        const parameters = try (try values.get(1)).asArray();
        const stmt = try host.prepare(sql, parameters, false);
        defer _ = sqlite.sqlite3_finalize(stmt);
        if (std.mem.eql(u8, sql, contract.reserve_stock) and
            try (try parameters.get(0)).asInt() != try (try parameters.get(2)).asInt()) return error.InvalidParameters;
        if (sqlite.sqlite3_step(stmt) != sqlite.SQLITE_DONE) return error.SQLiteStepFailed;
        const changed = sqlite.sqlite3_changes(host.db.?);
        if (std.mem.eql(u8, sql, contract.reserve_stock) and changed == 0)
            return mruby.effect.reject(vm, "OutOfStock", "insufficient available inventory");
        return .{ .returned = try vm.intValue(changed) };
    }

    fn enqueue(context: ?*anyopaque, vm: *mruby.Vm, args: mruby.Value) !mruby.Value {
        const host: *Host = @ptrCast(@alignCast(context.?));
        host.enqueue_callbacks += 1;
        if (host.intents.items.len >= 8) return error.OutboxFull;
        const values = try args.asArray();
        const destination_bytes = try (try values.get(0)).asString();
        if (destination_bytes.len > 128) return error.InvalidDestination;
        const destination = try host.allocator.dupe(u8, destination_bytes);
        errdefer host.allocator.free(destination);
        const payload_bytes = try (try values.get(1)).asString();
        if (payload_bytes.len > 1024) return error.InvalidPayload;
        const payload = try host.allocator.dupe(u8, payload_bytes);
        errdefer host.allocator.free(payload);
        const receipt = try vm.intValue(host.intents.items.len + 1);
        try host.intents.append(host.allocator, .{ .destination = destination, .payload = payload });
        return receipt;
    }
};

const Result = struct {
    value: []u8,
    trace: ?[]u8 = null,
    elapsed_ns: u64,

    fn deinit(result: Result, allocator: std.mem.Allocator) void {
        allocator.free(result.value);
        if (result.trace) |trace| allocator.free(trace);
    }
};

fn digest(bytes: []const u8) [32]u8 {
    var result: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}

// Existing embedding API retained for the compatibility profile. The strict
// profile below selects strict.Program and never loads application code via a
// raw bootstrap VM.
const CompatibilityProgram = struct {
    iso: mruby.sandbox.Isolate,
    receiver: mruby.Value,
    code: [32]u8,
    bootstrap: [32]u8,

    fn load(comptime bundle: type, entry_name: []const u8, comptime operations: anytype, options: anytype) !CompatibilityProgram {
        var boot = try mruby.sandbox.BootstrapIsolate.spawn(options.policy);
        defer boot.deinit();
        const entry = mruby.codedb.lookup(bundle, entry_name) orelse return error.UnknownArtifact;
        const payload = try mruby.artifact.validateRite(.{ .bytes = entry.bytes }, .{
            .compatibility = mruby.features.rite_compatibility_fingerprint,
        });
        _ = try boot.vm().loadIrep(payload.bytes);
        const receiver = (try boot.vm().getClass("Inventory")).asValue();
        try mruby.effect.install(boot.vm(), operations, options.effects);
        return .{
            .iso = try boot.seal(),
            .receiver = receiver,
            .code = digest(entry.bytes),
            .bootstrap = options.bootstrap_identity,
        };
    }

    fn deinit(program: *CompatibilityProgram) void {
        program.iso.deinit();
    }

    fn call(program: *CompatibilityProgram, receiver: []const u8, method: []const u8, arguments: anytype, state: [32]u8) !mruby.Value {
        if (!std.mem.eql(u8, receiver, "Inventory")) return error.UnknownInventoryReceiver;
        return program.iso.callWithEffects(program.receiver, method, arguments, .{
            .code = program.code,
            .bootstrap = program.bootstrap,
            .state = state,
            .receiver = receiver,
        });
    }

    fn takeEffectTrace(program: *CompatibilityProgram) !mruby.effect.Trace {
        return program.iso.takeEffectTrace();
    }
};

fn invoke(host: *Host, mode: mruby.effect.Mode, read_only: bool, method: []const u8, arguments: anytype) !Result {
    // One disposable host fixture and VM per turn. This keeps the declared
    // starting-state identity accurate; reusing mutated hosts is an error.
    if (host.used) return error.HostAlreadyUsed;
    host.used = true;
    const bindings = [_]mruby.effect.Binding{
        .{ .name = "db.rows", .handler = Host.rows, .context = host },
        .{ .name = "db.execute", .outcome_handler = Host.executeWrite, .context = host },
        .{ .name = "outbox.enqueue", .handler = Host.enqueue, .context = host },
    };
    const Program = if (mruby.features.effects_strict) mruby.strict.Program else CompatibilityProgram;
    var program = try Program.load(manifest, "inventory", contract.operations, .{
        .policy = mruby.sandbox.Policy.restricted(.{
            .limits = .{ .gas = .{ .per_execution = 100_000 }, .call_depth = 32 },
        }),
        .effects = mruby.effect.Config{
            .allowed = if (read_only) &.{"db.rows"} else &.{ "db.rows", "db.execute", "outbox.enqueue" },
            .bindings = &bindings,
            .mode = mode,
        },
        .bootstrap_identity = digest(contract.bootstrap_contract),
    });
    defer program.deinit();
    const start = std.Io.Clock.awake.now(host.io);
    const live_database = mode != .replay;
    if (live_database) try host.execHost("BEGIN");
    errdefer {
        if (live_database) host.execHost("ROLLBACK") catch {};
        host.discardIntents();
    }
    const value = try program.call("Inventory", method, arguments, digest(contract.fixture));
    const copied = try host.allocator.dupe(u8, try value.asString());
    errdefer host.allocator.free(copied);
    var encoded: ?[]u8 = null;
    errdefer if (encoded) |bytes| host.allocator.free(bytes);
    if (mode == .record) {
        var trace = try program.takeEffectTrace();
        defer trace.deinit();
        encoded = try trace.encode(host.allocator);
    }
    if (live_database) try host.execHost("COMMIT");
    return .{
        .value = copied,
        .trace = encoded,
        .elapsed_ns = @intCast(start.durationTo(std.Io.Clock.awake.now(host.io)).toNanoseconds()),
    };
}

fn verify(allocator: std.mem.Allocator, io: std.Io) !void {
    var success = try Host.init(allocator, io);
    defer success.deinit();
    const recorded = try invoke(&success, .record, false, "reserve", .{ "widget", @as(i64, 2) });
    defer recorded.deinit(allocator);
    try std.testing.expectEqualStrings("reserved:widget:2:3:1", recorded.value);
    try std.testing.expectEqual(@as(i64, 3), try success.scalar("SELECT quantity FROM stock WHERE sku = 'widget'"));
    try std.testing.expectEqual(@as(i64, 1), try success.scalar("SELECT count(*) FROM reservations"));
    try std.testing.expectEqual(@as(usize, 1), success.read_callbacks);
    try std.testing.expectEqual(@as(usize, 2), success.write_callbacks);
    try std.testing.expectEqual(@as(usize, 1), success.intents.items.len);
    try std.testing.expectEqualStrings("reservations", success.intents.items[0].destination);
    try std.testing.expectEqualStrings("widget:2", success.intents.items[0].payload);

    // There is deliberately no SQLite handle in either replay host. Replay
    // returns recorded observations; it does not reconstruct database state.
    var replay_host: Host = .{ .allocator = allocator, .io = io };
    defer replay_host.deinit();
    const replayed = try invoke(&replay_host, .{ .replay = recorded.trace.? }, false, "reserve", .{ "widget", @as(i64, 2) });
    defer replayed.deinit(allocator);
    try std.testing.expectEqualStrings(recorded.value, replayed.value);
    try expectNoCallbacks(&replay_host);

    var rejection = try Host.init(allocator, io);
    defer rejection.deinit();
    const rejected = try invoke(&rejection, .record, false, "reserve", .{ "widget", @as(i64, 9) });
    defer rejected.deinit(allocator);
    try std.testing.expectEqualStrings("unavailable:widget:5:OutOfStock", rejected.value);
    try std.testing.expectEqual(@as(i64, 5), try rejection.scalar("SELECT quantity FROM stock WHERE sku = 'widget'"));
    try std.testing.expectEqual(@as(i64, 0), try rejection.scalar("SELECT count(*) FROM reservations"));
    try std.testing.expectEqual(@as(usize, 0), rejection.intents.items.len);
    var rejected_replay_host: Host = .{ .allocator = allocator, .io = io };
    defer rejected_replay_host.deinit();
    const rejected_replay = try invoke(&rejected_replay_host, .{ .replay = rejected.trace.? }, false, "reserve", .{ "widget", @as(i64, 9) });
    defer rejected_replay.deinit(allocator);
    try std.testing.expectEqualStrings(rejected.value, rejected_replay.value);
    try expectNoCallbacks(&rejected_replay_host);

    var inspection = try Host.init(allocator, io);
    defer inspection.deinit();
    const inspected = try invoke(&inspection, .live, true, "inspect_stock", .{ "widget", false });
    defer inspected.deinit(allocator);
    try std.testing.expectEqualStrings("stock:widget:5", inspected.value);
    var denial = try Host.init(allocator, io);
    defer denial.deinit();
    try std.testing.expectError(error.EffectDenied, invoke(&denial, .live, true, "inspect_stock", .{ "widget", true }));
    try std.testing.expectEqual(@as(usize, 0), denial.write_callbacks);
    try std.testing.expectEqual(@as(i64, 5), try denial.scalar("SELECT quantity FROM stock WHERE sku = 'widget'"));

    var rollback = try Host.init(allocator, io);
    defer rollback.deinit();
    try std.testing.expectError(error.RubyException, invoke(&rollback, .record, false, "reserve_then_fail", .{ "widget", @as(i64, 2) }));
    try std.testing.expectEqual(@as(i64, 5), try rollback.scalar("SELECT quantity FROM stock WHERE sku = 'widget'"));
    try std.testing.expectEqual(@as(i64, 0), try rollback.scalar("SELECT count(*) FROM reservations"));
    try std.testing.expectEqual(@as(usize, 0), rollback.intents.items.len);
    try std.testing.expectEqual(@as(usize, 1), rollback.enqueue_callbacks);

    // Even granted operations cannot escape this example's SQL protocol.
    const invalid_sql = [_][]const u8{
        "COMMIT",                                                      "ROLLBACK",                      "PRAGMA foreign_keys = OFF", "ATTACH DATABASE ':memory:' AS other",
        "SELECT quantity FROM stock WHERE sku = ?; DELETE FROM stock", "UPDATE stock SET quantity = 0",
    };
    for (invalid_sql) |sql| {
        inline for (.{ "read_sql", "write_sql" }) |method| {
            var invalid = try Host.init(allocator, io);
            defer invalid.deinit();
            try std.testing.expectError(error.EffectHandlerFailed, invoke(&invalid, .live, false, method, .{sql}));
            try std.testing.expectEqual(@as(i64, 5), try invalid.scalar("SELECT quantity FROM stock WHERE sku = 'widget'"));
        }
    }
    for ([_]i64{ 0, -1, 1001 }) |quantity| {
        var invalid = try Host.init(allocator, io);
        defer invalid.deinit();
        try std.testing.expectError(error.EffectHandlerFailed, invoke(&invalid, .live, false, "reserve", .{ "widget", quantity }));
        try std.testing.expectEqual(@as(i64, 5), try invalid.scalar("SELECT quantity FROM stock WHERE sku = 'widget'"));
        try std.testing.expectEqual(@as(usize, 0), invalid.intents.items.len);
    }
    std.debug.print("inventory: success + OutOfStock fallback replayed without a database or new intents ({d}/{d} trace bytes)\n", .{ recorded.trace.?.len, rejected.trace.?.len });
    std.debug.print("inventory: inspection write denied before its SQLite callback; failed turn rolled back DB + intents; SQL protocol escape checks passed\n", .{});
}

fn expectNoCallbacks(host: *const Host) !void {
    try std.testing.expectEqual(@as(usize, 0), host.read_callbacks);
    try std.testing.expectEqual(@as(usize, 0), host.write_callbacks);
    try std.testing.expectEqual(@as(usize, 0), host.enqueue_callbacks);
    try std.testing.expectEqual(@as(usize, 0), host.intents.items.len);
}

fn measure(allocator: std.mem.Allocator, io: std.Io, mode: mruby.effect.Mode) !void {
    const warmup = 10;
    const samples = 100;
    var elapsed: [samples]u64 = undefined;
    var trace_bytes: usize = 0;
    for (0..warmup + samples) |i| {
        var host = try Host.init(allocator, io);
        defer host.deinit();
        const result = try invoke(&host, mode, false, "reserve", .{ "widget", @as(i64, 2) });
        defer result.deinit(allocator);
        try std.testing.expectEqualStrings("reserved:widget:2:3:1", result.value);
        if (i >= warmup) {
            elapsed[i - warmup] = result.elapsed_ns;
            if (result.trace) |trace| trace_bytes += trace.len;
        }
    }
    std.mem.sort(u64, &elapsed, {}, std.sort.asc(u64));
    std.debug.print("inventory benchmark {s}: median {d} ns/op, p95 {d} ns/op, {d} trace bytes/op ({d} samples after {d} warmups)\n", .{
        @tagName(mode), elapsed[samples / 2], elapsed[samples * 95 / 100 - 1], trace_bytes / samples, samples, warmup,
    });
}

pub fn main(init: std.process.Init) !void {
    std.debug.print("inventory runtime: {s}, {s}\n", .{
        if (mruby.features.effects_strict) "strict" else "compatibility", @tagName(@import("builtin").mode),
    });
    try verify(init.gpa, init.io);
    var arguments = init.minimal.args.iterate();
    _ = arguments.next();
    if (arguments.next()) |argument| {
        if (std.mem.eql(u8, argument, "--test")) return;
        return error.UnknownArgument;
    }
    std.debug.print("inventory measurements include BEGIN/method/COMMIT, result copy and record encoding; exclude fixture creation, VM bootstrap/seal and destruction. Each sample starts with the same private DB.\n", .{});
    try measure(init.gpa, init.io, .live);
    try measure(init.gpa, init.io, .record);
}
