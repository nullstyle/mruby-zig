//! Offline schema-2 to schema-3 ledger migration for the durable example.
//! The source ledger is only read and validated; a fresh schema-3 ledger is
//! built beside it. Every historical turn is pinned to one application the
//! operator names explicitly — version provenance is never inferred, because
//! schema-2 ledgers predate per-turn version records.
const std = @import("std");
const mruby = @import("mruby");
const host_module = @import("durable_host");
const contract = @import("durable_contract");
const data = mruby.effect.data;
const Turn = mruby.strict.Turn;
const Host = host_module.Host;
const sql = host_module.sql;
const done = sqlDone;
fn sqlDone(statement: *sql.Statement) !void {
    if (try statement.step() != .done) return error.DatabaseUnexpectedRow;
}

pub const Summary = struct {
    application: []const u8,
    /// Owned by the caller's allocator; free it when finished.
    namespace: []const u8,
    revision: i64,
    turns: usize,
    admissions: usize,
    reservations: usize,
    outbox: usize,
    stock: usize,
};

const Copied = struct {
    admissions: usize = 0,
    turns: usize = 0,
    reservations: usize = 0,
    outbox: usize = 0,
    stock: usize = 0,
};

/// `source` must be a schema-2 ledger; `target` is initialized as a fresh
/// schema-3 ledger. The application label must be one this build knows; the
/// source's namespace and role carry over unchanged. The source is never
/// written.
pub fn migrate(allocator: std.mem.Allocator, source_path: []const u8, target_path: []const u8, application_label: []const u8) !Summary {
    const ordinal = host_module.applications.ordinalForLabel(application_label) orelse return error.UnknownApplication;
    const identity = try pinnedIdentity(ordinal);
    var source = try sql.Db.open(allocator, source_path);
    defer source.close();
    try validateSource(&source);
    // Ownership transfers to the returned Summary on success.
    const namespace = try readNamespace(allocator, &source);
    errdefer allocator.free(namespace);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const owned = arena.allocator();

    // Validate the accepted state and every historical receipt under the
    // named application's contracts before the target ledger is created.
    const state = try readState(owned, &source, ordinal);
    try validateTurns(owned, &source, ordinal);

    // Placeholder worker paths satisfy Host.open's per-version table; the
    // migrator never starts a worker.
    const placeholders = [_][]const u8{ "migrate-unused-worker", "migrate-unused-worker" };
    var target = try Host.open(allocator, target_path, &placeholders, .{ .namespace = namespace });
    defer target.close();
    try target.db.exec("BEGIN IMMEDIATE");
    errdefer target.rollback();
    {
        var update = try target.db.prepare("UPDATE current_state SET revision=?,state=? WHERE id=1 AND revision=0");
        defer update.deinit();
        try update.bindInt(1, state.revision);
        try update.bindBlob(2, state.bytes);
        try done(&update);
        if (target.db.changes() != 1) return error.InvalidDurableState;
    }
    var copied = Copied{};
    try copyStock(owned, &source, &target, &copied);
    try copyAdmissions(owned, &source, &target, &copied);
    // Turns first: every other copied row references them.
    try copyTurns(owned, &source, &target, &copied);
    {
        var query = try source.prepare("SELECT turn_id FROM turns");
        defer query.deinit();
        var insert = try target.db.prepare("INSERT INTO turn_versions(turn_id,application) VALUES(?,?)");
        defer insert.deinit();
        while (try query.step() == .row) {
            try insert.bindText(1, try query.copyText(owned, 0, 128));
            try insert.bindBlob(2, &identity);
            try done(&insert);
            insert.reset();
        }
    }
    try copyReservations(owned, &source, &target, &copied);
    try copyOutbox(owned, &source, &target, &copied);
    {
        const identity_text = std.fmt.bytesToHex(identity, .lower);
        var update = try target.db.prepare("UPDATE durable_metadata SET value=? WHERE key='application'");
        defer update.deinit();
        try update.bindText(1, &identity_text);
        try done(&update);
        if (target.db.changes() != 1) return error.InvalidDurableState;
    }
    target.db.exec("COMMIT") catch {
        target.poisoned = true;
        return error.CommitIndeterminate;
    };
    return .{
        .application = host_module.applications.labelAt(ordinal),
        .namespace = namespace,
        .revision = state.revision,
        .turns = copied.turns,
        .admissions = copied.admissions,
        .reservations = copied.reservations,
        .outbox = copied.outbox,
        .stock = copied.stock,
    };
}

/// The application identity this build would pin for `ordinal`. The digest
/// binds label, code, contracts, and profile — never the namespace — so it
/// matches what a host opened with the source's namespace would compute.
fn pinnedIdentity(ordinal: usize) ![32]u8 {
    var identity: ?[32]u8 = null;
    inline for (host_module.applications.versions, 0..) |app, index| {
        if (index == ordinal) identity = try identifyFor(app);
    }
    return identity orelse error.UnknownApplication;
}

/// Mirrors the host's application identity computation without a namespace.
fn identifyFor(comptime app: host_module.applications.Descriptor) ![32]u8 {
    const program = try mruby.strict.identify(app.manifest, app.entry, .{ .effects = .{ .allowed = app.contract.grants } });
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("mruby-zig.durable.application.v1\x00");
    hashBytes(&hash, app.label);
    hash.update(&program.code);
    hash.update(&try mruby.effect.catalogueIdentity(app.contract.operations));
    hash.update(&app.turn_shape.digest());
    hashBytes(&hash, app.contract.bootstrap_contract);
    hashBytes(&hash, mruby.features.rite_compatibility_fingerprint_hex);
    return hash.finalResult();
}

fn hashBytes(hash: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, @intCast(bytes.len), .big);
    hash.update(&length);
    hash.update(bytes);
}

fn validateSource(source: *sql.Db) !void {
    try host_module.delivery.requireRole(source, "inventory");
    {
        var query = try source.prepare("SELECT value FROM durable_metadata WHERE key='schema'");
        defer query.deinit();
        if (try query.step() != .row or !std.mem.eql(u8, try query.text(0), "2")) return error.UnsupportedDurableSchema;
        if (try query.step() != .done) return error.InvalidDurableState;
    }
    // A ledger claiming schema 2 must not already carry versioned tables.
    if (try source.scalar("SELECT count(*) FROM sqlite_schema WHERE type='table' AND name IN ('turn_versions','upgrades')") != 0) return error.UnsupportedDurableSchema;
    for ([_][]const u8{ "admissions", "current_state", "stock", "turns", "reservations", "outbox" }) |table| {
        var query = try source.prepare("SELECT count(*) FROM sqlite_schema WHERE type='table' AND name=?");
        defer query.deinit();
        try query.bindText(1, table);
        if (try query.step() != .row or try query.int(0) != 1) return error.UnsupportedDurableSchema;
        if (try query.step() != .done) return error.InvalidDurableState;
    }
}

fn readNamespace(allocator: std.mem.Allocator, source: *sql.Db) ![]u8 {
    var query = try source.prepare("SELECT value FROM durable_metadata WHERE key='namespace'");
    defer query.deinit();
    if (try query.step() != .row) return error.InvalidDurableState;
    const value = try query.copyText(allocator, 0, 128);
    if (try query.step() != .done) return error.InvalidDurableState;
    return value;
}

fn readState(allocator: std.mem.Allocator, source: *sql.Db, ordinal: usize) !struct { revision: i64, bytes: []u8 } {
    var query = try source.prepare("SELECT revision,state FROM current_state WHERE id=1");
    defer query.deinit();
    if (try query.step() != .row) return error.InvalidDurableState;
    const revision = try query.int(0);
    const bytes = try query.copyBlob(allocator, 1, contract.max_bytes);
    if (revision < 0 or try query.step() != .done) return error.InvalidDurableState;
    var document = try decode(allocator, bytes);
    defer document.deinit();
    try host_module.validateValue(host_module.shapeAt(ordinal), document.root(), .state, null);
    const attempts = try (try fieldOf(document.root(), "attempts")).asInteger();
    // Schema-2 ledgers ran a single application whose attempts tracked the
    // ledger revision exactly.
    if (attempts != revision or attempts < 0) return error.InvalidDurableState;
    return .{ .revision = revision, .bytes = bytes };
}

fn validateTurns(allocator: std.mem.Allocator, source: *sql.Db, ordinal: usize) !void {
    const shape = host_module.shapeAt(ordinal);
    var query = try source.prepare("SELECT turn_id,request_hash,adapter_identity,receipt FROM turns");
    defer query.deinit();
    while (try query.step() == .row) {
        _ = try query.copyText(allocator, 0, 128);
        if ((try query.blob(1)).len != 32 or (try query.blob(2)).len != 32) return error.InvalidDurableState;
        const receipt_bytes = try query.copyBlob(allocator, 3, contract.max_receipt_bytes);
        const receipt = try Turn.Receipt.decode(receipt_bytes, .{ .max_encoded_bytes = contract.max_receipt_bytes, .max_trace_bytes = 128 * 1024, .max_terminal_bytes = contract.max_bytes });
        var trace = try mruby.effect.Trace.decode(allocator, receipt.trace, .{ .max_records = 32, .max_bytes = 128 * 1024, .max_request_bytes = contract.max_bytes, .max_result_bytes = contract.max_bytes });
        defer trace.deinit();
        var terminal = try decode(allocator, receipt.terminal.bytes);
        defer terminal.deinit();
        if (terminal.root().kind() != .array or try terminal.root().len() != 2) return error.InvalidDurableState;
        try host_module.validateValue(shape, try terminal.root().at(0), .result, null);
        try host_module.validateValue(shape, try terminal.root().at(1), .next_state, null);
    }
}

fn copyStock(allocator: std.mem.Allocator, source: *sql.Db, target: *Host, copied: *Copied) !void {
    var query = try source.prepare("SELECT sku,quantity FROM stock");
    defer query.deinit();
    // The target's seeded inventory row is replaced by the source's stock.
    try target.db.exec("DELETE FROM stock");
    var insert = try target.db.prepare("INSERT INTO stock(sku,quantity) VALUES(?,?)");
    defer insert.deinit();
    while (try query.step() == .row) {
        try insert.bindText(1, try query.copyText(allocator, 0, 128));
        try insert.bindInt(2, try query.int(1));
        try done(&insert);
        insert.reset();
        copied.stock += 1;
    }
}

fn copyAdmissions(allocator: std.mem.Allocator, source: *sql.Db, target: *Host, copied: *Copied) !void {
    var query = try source.prepare("SELECT turn_id,request_hash FROM admissions");
    defer query.deinit();
    var insert = try target.db.prepare("INSERT INTO admissions(turn_id,request_hash) VALUES(?,?)");
    defer insert.deinit();
    while (try query.step() == .row) {
        try insert.bindText(1, try query.copyText(allocator, 0, 128));
        try insert.bindBlob(2, try query.copyBlob(allocator, 1, 32));
        try done(&insert);
        insert.reset();
        copied.admissions += 1;
    }
}

fn copyTurns(allocator: std.mem.Allocator, source: *sql.Db, target: *Host, copied: *Copied) !void {
    var query = try source.prepare("SELECT turn_id,request_hash,starting_revision,start_state,input,adapter_identity,receipt,revision FROM turns");
    defer query.deinit();
    var insert = try target.db.prepare("INSERT INTO turns(turn_id,request_hash,starting_revision,start_state,input,adapter_identity,receipt,revision) VALUES(?,?,?,?,?,?,?,?)");
    defer insert.deinit();
    while (try query.step() == .row) {
        try insert.bindText(1, try query.copyText(allocator, 0, 128));
        try insert.bindBlob(2, try query.copyBlob(allocator, 1, 32));
        try insert.bindInt(3, try query.int(2));
        try insert.bindBlob(4, try query.copyBlob(allocator, 3, contract.max_bytes));
        try insert.bindBlob(5, try query.copyBlob(allocator, 4, contract.max_bytes));
        try insert.bindBlob(6, try query.copyBlob(allocator, 5, 32));
        try insert.bindBlob(7, try query.copyBlob(allocator, 6, contract.max_receipt_bytes));
        try insert.bindInt(8, try query.int(7));
        try done(&insert);
        insert.reset();
        copied.turns += 1;
    }
}

fn copyReservations(allocator: std.mem.Allocator, source: *sql.Db, target: *Host, copied: *Copied) !void {
    var query = try source.prepare("SELECT turn_id,sequence,sku,quantity FROM reservations");
    defer query.deinit();
    var insert = try target.db.prepare("INSERT INTO reservations(turn_id,sequence,sku,quantity) VALUES(?,?,?,?)");
    defer insert.deinit();
    while (try query.step() == .row) {
        try insert.bindText(1, try query.copyText(allocator, 0, 128));
        try insert.bindInt(2, try query.int(1));
        try insert.bindText(3, try query.copyText(allocator, 2, 128));
        try insert.bindInt(4, try query.int(3));
        try done(&insert);
        insert.reset();
        copied.reservations += 1;
    }
}

fn copyOutbox(allocator: std.mem.Allocator, source: *sql.Db, target: *Host, copied: *Copied) !void {
    var query = try source.prepare("SELECT intent_id,turn_id,sequence,destination,payload,delivered FROM outbox");
    defer query.deinit();
    var insert = try target.db.prepare("INSERT INTO outbox(intent_id,turn_id,sequence,destination,payload,delivered) VALUES(?,?,?,?,?,?)");
    defer insert.deinit();
    while (try query.step() == .row) {
        try insert.bindText(1, try query.copyText(allocator, 0, 128));
        try insert.bindText(2, try query.copyText(allocator, 1, 128));
        try insert.bindInt(3, try query.int(2));
        try insert.bindText(4, try query.copyText(allocator, 3, 128));
        try insert.bindBlob(5, try query.copyBlob(allocator, 4, contract.max_bytes));
        try insert.bindInt(6, try query.int(5));
        try done(&insert);
        insert.reset();
        copied.outbox += 1;
    }
}

fn decode(allocator: std.mem.Allocator, bytes: []const u8) !data.Document {
    return data.Document.decodeWithOptions(allocator, .{ .bytes = bytes }, .{
        .limits = data.limits(contract.max_bytes),
        .allow_float = !mruby.features.effects_integer64,
    });
}

fn fieldOf(value: data.Ref, name: []const u8) !data.Ref {
    return (try value.get(name)) orelse error.InvalidDurableState;
}

pub fn main(init: std.process.Init) !void {
    var arguments = init.minimal.args.iterate();
    _ = arguments.next();
    const source = arguments.next() orelse return error.MissingSource;
    const target = arguments.next() orelse return error.MissingTarget;
    const label = arguments.next() orelse return error.MissingApplication;
    if (arguments.next() != null) return error.UnexpectedArgument;
    const summary = try migrate(init.gpa, source, target, label);
    std.debug.print("migrated {s} (namespace {s}) to application {s}: revision {d}, {d} turns, {d} admissions, {d} reservations, {d} outbox rows, {d} stock rows\n", .{
        source, summary.namespace, summary.application, summary.revision, summary.turns, summary.admissions, summary.reservations, summary.outbox, summary.stock,
    });
}
