//! Durable reference host for strict.Worker. One SQLite transaction owns the
//! inventory mutation, next Ruby state, receipt, committed turn and outbox rows.
//! An earlier durable admission binds the request ID even if execution fails.
//! The ledger names its active application version; historical turns replay on
//! their original bundle, and only an explicit upgrade changes the active one.
//! This application adapter is intentionally separate from the VM library.
const std = @import("std");
const mruby = @import("mruby");
pub const applications = @import("durable_applications");
pub const contract = applications.versions[0].contract;
pub const sql = @import("sql.zig");
pub const delivery = @import("delivery.zig");
const data = mruby.effect.data;
const Turn = mruby.strict.Turn;
const Worker = mruby.strict.Worker;
const View = mruby.artifact.StateCapsuleView;

/// Trusted reference-example instrumentation. Never controlled by Ruby input.
pub const Fault = enum { none, invalid_reservation_result, undeclared_rejection, invalid_notification_result };

pub const Request = struct {
    turn_id: []const u8,
    expected_revision: i64,
    input: View,
};
/// Explicitly identified state upgrade. The caller names the target
/// application version and the state revision the upgrade expects.
pub const UpgradeRequest = struct {
    upgrade_id: []const u8,
    expected_revision: i64,
    target: []const u8,
};
pub const UpgradeResult = struct {
    /// Revision published by the upgrade (the original one when reused).
    revision: i64,
    /// True when a committed upgrade record answered this retry.
    reused: bool,
    application: []const u8,
};
/// Explicit retention request. Committed turns with `revision` strictly below
/// `before_revision` are archived and removed together with their version,
/// reservation, and outbox rows. Their immutable admissions stay bound, so
/// retrying a pruned ID fails closed with `StaleState` instead of executing
/// again. Requires `Options.io`; a zero-turn prune leaves the archive path
/// untouched.
pub const PruneRequest = struct {
    before_revision: i64,
    archive_path: []const u8,
};
pub const PruneResult = struct {
    /// Number of committed turns archived and removed by this call.
    pruned: usize,
};
pub const Options = struct {
    /// Stable logical database namespace; reuse across copies means they are
    /// the same logical source. Independent sources need different namespaces.
    namespace: []const u8 = "demo",
    checkpoint: contract.Checkpoint = .{},
    process: Worker.ProcessLimits = .{},
    diagnostic: ?*Turn.Diagnostic = null,
    fault: Fault = .none,
    /// Threaded host I/O used only by retention archiving. Pruning requires
    /// it; every other operation works without it.
    io: ?std.Io = null,
};
pub const Status = struct {
    application: []const u8,
    revision: i64,
    attempts: i64,
    stock: i64,
    turn_count: i64,
    reservation_count: i64,
    outbox_count: i64,
    delivered_count: i64,
};
pub const Result = struct {
    verified: Turn.Verified,
    revision: i64,
    reused: bool,
    effect_calls: usize,

    pub fn deinit(self: *Result) void {
        self.verified.deinit();
        self.* = undefined;
    }
    pub fn receipt(self: *const Result) []const u8 {
        return self.verified.receipt();
    }
    pub fn terminal(self: *const Result) View {
        return self.verified.terminal();
    }
    pub fn state(self: *const Result, allocator: std.mem.Allocator) !mruby.artifact.StateCapsule {
        return self.verified.state(allocator);
    }
    pub fn result(self: *const Result, allocator: std.mem.Allocator) !mruby.artifact.StateCapsule {
        return self.verified.result(allocator);
    }
};

/// Per-application identities used by request fingerprints, worker options,
/// and the ledger's pinned application identity.
pub const ApplicationIdentity = struct {
    code: [32]u8,
    catalogue: [32]u8,
    turn_digest: [32]u8,
    bootstrap: [32]u8,
    application: [32]u8,
};

/// One caller at a time per Host (this SQLite connection uses NOMUTEX).
/// Multiple hosts/processes serialize new turns using BEGIN IMMEDIATE. The
/// bounded busy error is returned to the caller; there is no automatic retry.
pub const Host = struct {
    allocator: std.mem.Allocator,
    db: sql.Db,
    executables: [applications.count][]u8,
    namespace: []u8,
    checkpoint: contract.Checkpoint,
    process: Worker.ProcessLimits,
    apps: [applications.count]ApplicationIdentity,
    diagnostic: ?*Turn.Diagnostic,
    fault: Fault,
    io: ?std.Io = null,
    in_use: bool = false,
    poisoned: bool = false,

    /// `worker_executables` holds one worker per application version, ordered
    /// like `applications.versions`. Every entry may be needed to execute new
    /// turns or replay historical receipts after an upgrade.
    pub fn open(allocator: std.mem.Allocator, db_path: []const u8, worker_executables: []const []const u8, options: Options) !Host {
        if (worker_executables.len != applications.count) return error.InvalidWorkerPath;
        try validName(options.namespace);
        const namespace = try allocator.dupe(u8, options.namespace);
        errdefer allocator.free(namespace);
        var executables: [applications.count][]u8 = undefined;
        var filled: usize = 0;
        errdefer for (executables[0..filled]) |path| allocator.free(path);
        for (worker_executables) |path| {
            if (path.len == 0 or path.len > sql.max_path_bytes or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidWorkerPath;
            executables[filled] = try allocator.dupe(u8, path);
            filled += 1;
        }
        var db = try sql.Db.open(allocator, db_path);
        errdefer db.close();
        var apps: [applications.count]ApplicationIdentity = undefined;
        inline for (applications.versions, 0..) |app, index| {
            apps[index] = try identifyApplication(app, namespace);
        }
        var host: Host = .{ .allocator = allocator, .db = db, .executables = executables, .namespace = namespace, .checkpoint = options.checkpoint, .process = options.process, .apps = apps, .diagnostic = options.diagnostic, .fault = options.fault, .io = options.io };
        try host.initialize();
        return host;
    }
    pub fn close(self: *Host) void {
        self.db.close(); // SQLite rolls back any unresolved native transaction.
        for (&self.executables) |path| self.allocator.free(path);
        self.allocator.free(self.namespace);
        self.* = undefined;
    }

    pub fn execute(self: *Host, request: Request) !Result {
        if (self.diagnostic) |diagnostic| diagnostic.* = .{};
        return self.executeInner(request) catch |err| {
            hostError(self.diagnostic, err);
            return err;
        };
    }
    fn executeInner(self: *Host, request: Request) !Result {
        try self.enter();
        defer self.in_use = false;
        try validName(request.turn_id);
        if (request.expected_revision < 0) return error.InvalidRevision;
        // The fingerprint is computed under the currently active application.
        // An upgrade publishing between this read and admission changes the
        // state revision, so the stale check below fail-closes that race.
        const admitted_ordinal = try self.storedApplication();
        // Caller storage cannot change the meaning of an admitted turn from a
        // checkpoint or adapter callback. All request bytes have owned lifetime.
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const owned = arena.allocator();
        const turn_id = try owned.dupe(u8, request.turn_id);
        var input = try decodeData(owned, request.input);
        try validateValue(shapeAt(admitted_ordinal), input.root(), .input, self.diagnostic);
        const snapshot: Request = .{ .turn_id = turn_id, .expected_revision = request.expected_revision, .input = input.view() };
        const fingerprint = self.requestIdentity(&self.apps[admitted_ordinal], snapshot);
        // Committed records are immutable. A retry can be answered even while
        // a different writer has uncommitted work and without starting a worker.
        if (try self.cached(snapshot.turn_id, fingerprint, admitted_ordinal)) |result| return result;
        if (try self.admit(snapshot, fingerprint)) |result| return result;
        self.checkpoint.reach(.after_admission);
        try self.db.exec("BEGIN IMMEDIATE");
        var execution: Execution = .{
            .host = self,
            .request = snapshot,
            .request_hash = fingerprint,
            .requested_sku = try (try field(input.root(), "sku")).asString(),
            .requested_quantity = try (try field(input.root(), "quantity")).asInteger(),
        };
        defer execution.abort();
        // Another process may have committed this ID while BEGIN waited.
        if (try self.cached(snapshot.turn_id, fingerprint, admitted_ordinal)) |result| return result;
        const ordinal = try self.storedApplication();
        // Every upgrade publishes a new revision, so an application that moved
        // on always leaves this request's expected revision stale.
        if (ordinal != admitted_ordinal) return error.StaleState;
        const state = try self.readState(owned, ordinal);
        if (state.revision != snapshot.expected_revision) return error.StaleState;
        execution.ordinal = ordinal;
        execution.next_revision = std.math.add(i64, state.revision, 1) catch return error.RevisionExhausted;
        execution.start_state = state.capsule;
        execution.start_attempts = state.attempts;
        execution.start_rejections = state.rejections;
        execution.adapter_identity = try self.adapterIdentity(state.revision, snapshot.turn_id);
        self.checkpoint.reach(.after_begin);
        const bindings = execution.bindings();
        var prepared = try self.prepareWorker(ordinal, &execution, state.capsule, &bindings);
        defer prepared.deinit();
        // Own all reply bytes before publication; returning after COMMIT has no
        // fallible allocations. Persisted replies remain recoverable after death.
        var result: Result = .{ .verified = try verifiedCopy(self.allocator, prepared.receipt(), shapeAt(ordinal), self.diagnostic), .revision = execution.next_revision, .reused = false, .effect_calls = execution.sequence };
        errdefer result.deinit();
        self.checkpoint.reach(.after_prepare);
        prepared.commit() catch |err| return execution.commit_error orelse err;
        return result;
    }

    /// Explicitly identified application upgrade. One transaction resolves a
    /// committed upgrade record for this ID (recovering a lost reply), then
    /// transforms the accepted state under the declared upgrade path and
    /// publishes the new state, revision, active application, and provenance
    /// atomically. No worker runs and no adapters or deliveries are involved.
    pub fn upgrade(self: *Host, request: UpgradeRequest) !UpgradeResult {
        if (self.diagnostic) |diagnostic| diagnostic.* = .{};
        return self.upgradeInner(request) catch |err| {
            hostError(self.diagnostic, err);
            return err;
        };
    }
    fn upgradeInner(self: *Host, request: UpgradeRequest) !UpgradeResult {
        try self.enter();
        defer self.in_use = false;
        try validName(request.upgrade_id);
        if (request.expected_revision < 0) return error.InvalidRevision;
        try validName(request.target);
        const target = applications.ordinalForLabel(request.target) orelse return error.UnknownApplication;
        if (target != applications.upgrade.to) return error.UnsupportedApplicationUpgrade;
        const fingerprint = self.upgradeIdentity(request);
        try self.db.exec("BEGIN IMMEDIATE");
        defer if (!self.poisoned) self.rollback();
        // A committed record answers the retry with its original decision even
        // though the active application has already moved on.
        {
            var query = try self.db.prepare("SELECT request_hash,revision FROM upgrades WHERE upgrade_id=?");
            defer query.deinit();
            try query.bindText(1, request.upgrade_id);
            // A matching committed record is the only row this key can have.
            if (try query.step() == .row) {
                if (!std.mem.eql(u8, try query.blob(0), &fingerprint)) return error.UpgradeIdConflict;
                const revision = try query.int(1);
                if (revision <= 0) return error.InvalidDurableState;
                return .{ .revision = revision, .reused = true, .application = applications.labelAt(target) };
            }
        }
        const ordinal = try self.storedApplication();
        if (ordinal != applications.upgrade.from) return error.UnsupportedApplicationUpgrade;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const state = try self.readState(arena.allocator(), ordinal);
        if (state.revision != request.expected_revision) return error.StaleState;
        const next_revision = std.math.add(i64, state.revision, 1) catch return error.RevisionExhausted;
        var next = try applications.upgrade.transformState(arena.allocator(), state.capsule);
        defer next.deinit(arena.allocator());
        var document = try decodeData(arena.allocator(), next.view());
        defer document.deinit();
        try validateValue(shapeAt(target), document.root(), .state, self.diagnostic);
        // The upgrade preserves the accepted attempt count; only the ledger
        // revision advances. Other transformed values are application policy
        // checked by the target state contract above.
        const attempts = try (try field(document.root(), "attempts")).asInteger();
        if (attempts != state.attempts) return error.InvalidTurnState;
        self.checkpoint.reach(.before_upgrade_commit);
        {
            var update = try self.db.prepare("UPDATE current_state SET revision=?,state=? WHERE id=1 AND revision=?");
            defer update.deinit();
            try update.bindInt(1, next_revision);
            try update.bindBlob(2, next.encoded);
            try update.bindInt(3, request.expected_revision);
            try done(&update);
            if (self.db.changes() != 1) return error.StaleState;
        }
        {
            var insert = try self.db.prepare("INSERT INTO upgrades(upgrade_id,request_hash,from_application,to_application,starting_revision,revision) VALUES(?,?,?,?,?,?)");
            defer insert.deinit();
            try insert.bindText(1, request.upgrade_id);
            try insert.bindBlob(2, &fingerprint);
            try insert.bindBlob(3, &self.apps[applications.upgrade.from].application);
            try insert.bindBlob(4, &self.apps[applications.upgrade.to].application);
            try insert.bindInt(5, request.expected_revision);
            try insert.bindInt(6, next_revision);
            try done(&insert);
        }
        {
            const identity_text = std.fmt.bytesToHex(self.apps[applications.upgrade.to].application, .lower);
            var update = try self.db.prepare("UPDATE durable_metadata SET value=? WHERE key='application'");
            defer update.deinit();
            try update.bindText(1, &identity_text);
            try done(&update);
            if (self.db.changes() != 1) return error.InvalidDurableState;
        }
        self.db.exec("COMMIT") catch {
            // The publication outcome is uncertain: close and reopen, then
            // retry this exact upgrade to resolve the durable decision.
            self.poisoned = true;
            return error.CommitIndeterminate;
        };
        self.checkpoint.reach(.after_upgrade_commit);
        return .{ .revision = next_revision, .reused = false, .application = applications.labelAt(target) };
    }

    /// Archive and remove acknowledged history below an explicit revision.
    /// One transaction deletes version, reservation, outbox, and turn rows
    /// after a write-ahead archive replaces the target file atomically. The
    /// immutable admissions stay bound, so a pruned ID can only ever fail
    /// closed (`StaleState` or `TurnIdConflict`), never re-execute. A
    /// zero-turn prune touches nothing, including the archive path.
    pub fn prune(self: *Host, request: PruneRequest) !PruneResult {
        if (self.diagnostic) |diagnostic| diagnostic.* = .{};
        return self.pruneInner(request) catch |err| {
            hostError(self.diagnostic, err);
            return err;
        };
    }
    fn pruneInner(self: *Host, request: PruneRequest) !PruneResult {
        try self.enter();
        defer self.in_use = false;
        if (request.before_revision <= 0) return error.InvalidRevision;
        if (request.archive_path.len == 0 or request.archive_path.len > sql.max_path_bytes or
            std.mem.indexOfScalar(u8, request.archive_path, 0) != null) return error.InvalidName;
        const io = self.io orelse return error.IoUnavailable;
        try self.db.exec("BEGIN IMMEDIATE");
        defer if (!self.poisoned) self.rollback();
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const owned = arena.allocator();
        // Count first: an empty prune must not rewrite a previous archive,
        // and one call carries a bounded batch of receipts.
        const total: usize = blk: {
            var query = try self.db.prepare("SELECT count(*) FROM turns WHERE revision<?");
            defer query.deinit();
            try query.bindInt(1, request.before_revision);
            if (try query.step() != .row) return error.InvalidDurableState;
            const count = try query.int(0);
            if (count < 0 or try query.step() != .done) return error.InvalidDurableState;
            break :blk @intCast(count);
        };
        if (total == 0) return .{ .pruned = 0 };
        if (total > max_prune_batch) return error.PruneBatchLimit;
        // Pending intents must be delivered and acknowledged before their
        // turn's receipt leaves the ledger.
        {
            var query = try self.db.prepare("SELECT count(*) FROM outbox WHERE delivered=0 AND turn_id IN (SELECT turn_id FROM turns WHERE revision<?)");
            defer query.deinit();
            try query.bindInt(1, request.before_revision);
            if (try query.step() != .row) return error.InvalidDurableState;
            const pending = try query.int(0);
            if (pending != 0 or try query.step() != .done) return error.UndeliveredIntents;
        }
        // Write-ahead archive: one self-describing JSON line per pruned turn
        // with its receipt bytes and pinned application identity.
        var buffer: std.Io.Writer.Allocating = .init(owned);
        defer buffer.deinit();
        const encoder = std.base64.standard.Encoder;
        {
            var query = try self.db.prepare("SELECT t.turn_id,t.revision,v.application,t.receipt FROM turns t JOIN turn_versions v ON v.turn_id=t.turn_id WHERE t.revision<? ORDER BY t.revision");
            defer query.deinit();
            try query.bindInt(1, request.before_revision);
            var written: usize = 0;
            while (try query.step() == .row) {
                const turn_id = try query.copyText(owned, 0, 128);
                const revision = try query.int(1);
                const application = try query.copyBlob(owned, 2, 32);
                const receipt = try query.copyBlob(owned, 3, contract.max_receipt_bytes);
                const encoded = try owned.alloc(u8, encoder.calcSize(receipt.len));
                _ = encoder.encode(encoded, receipt);
                try buffer.writer.writeAll("{\"turn_id\":");
                try jsonText(&buffer.writer, turn_id);
                try buffer.writer.print(",\"revision\":{d},\"application\":", .{revision});
                try jsonText(&buffer.writer, &std.fmt.bytesToHex(application[0..32].*, .lower));
                try buffer.writer.print(",\"receipt\":\"", .{});
                try buffer.writer.writeAll(encoded);
                try buffer.writer.writeAll("\"}\n");
                written += 1;
            }
            if (written != total) return error.InvalidDurableState;
        }
        const archive = buffer.writer.buffer[0..buffer.writer.end];
        if (archive.len > max_archive_bytes) return error.ArchiveLimit;
        {
            var file = try std.Io.Dir.cwd().createFileAtomic(io, request.archive_path, .{ .replace = true });
            errdefer file.deinit(io);
            try file.file.writeStreamingAll(io, archive);
            try file.replace(io);
            file.deinit(io);
        }
        // Children first; deferred foreign keys tolerate either order, but the
        // turn row is the anchor every other row references.
        try self.execPrune("DELETE FROM turn_versions WHERE turn_id IN (SELECT turn_id FROM turns WHERE revision<?)", request.before_revision);
        try self.execPrune("DELETE FROM reservations WHERE turn_id IN (SELECT turn_id FROM turns WHERE revision<?)", request.before_revision);
        try self.execPrune("DELETE FROM outbox WHERE turn_id IN (SELECT turn_id FROM turns WHERE revision<?)", request.before_revision);
        try self.execPrune("DELETE FROM turns WHERE revision<?", request.before_revision);
        self.db.exec("COMMIT") catch {
            // The archive is deliberately write-ahead: reopening and retrying
            // rewrites it for the same still-present set.
            self.poisoned = true;
            return error.CommitIndeterminate;
        };
        return .{ .pruned = total };
    }
    fn execPrune(self: *Host, comptime query_text: []const u8, before_revision: i64) !void {
        var query = try self.db.prepare(query_text);
        defer query.deinit();
        try query.bindInt(1, before_revision);
        try done(&query);
    }

    pub fn status(self: *Host) !Status {
        try self.enter();
        defer self.in_use = false;
        try self.db.exec("BEGIN");
        defer self.rollback();
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const ordinal = try self.storedApplication();
        const state = try self.readState(arena.allocator(), ordinal);
        return .{
            .application = applications.labelAt(ordinal),
            .revision = state.revision,
            .attempts = state.attempts,
            .stock = try self.db.scalar("SELECT quantity FROM stock WHERE sku='widget'"),
            .turn_count = try self.db.scalar("SELECT count(*) FROM turns"),
            .reservation_count = try self.db.scalar("SELECT count(*) FROM reservations"),
            .outbox_count = try self.db.scalar("SELECT count(*) FROM outbox"),
            .delivered_count = try self.db.scalar("SELECT count(*) FROM outbox WHERE delivered=1"),
        };
    }

    /// Re-execute a historical receipt with its original state/input and no
    /// effect bindings or transaction hooks, on the application version that
    /// committed it. This does not redeliver intents.
    pub fn replay(self: *Host, turn_id: []const u8) !Turn.Verified {
        try self.enter();
        defer self.in_use = false;
        try validName(turn_id);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const owned = arena.allocator();
        const row = blk: {
            var query = try self.db.prepare("SELECT t.start_state,t.input,t.adapter_identity,t.receipt,v.application FROM turns t JOIN turn_versions v ON v.turn_id=t.turn_id WHERE t.turn_id=?");
            defer query.deinit();
            try query.bindText(1, turn_id);
            if (try query.step() != .row) return error.UnknownTurn;
            const state = try query.copyBlob(owned, 0, contract.max_bytes);
            const input = try query.copyBlob(owned, 1, contract.max_bytes);
            const identity = try query.blob(2);
            if (identity.len != 32) return error.InvalidDurableState;
            const adapter = identity[0..32].*;
            const receipt = try query.copyBlob(owned, 3, contract.max_receipt_bytes);
            const application = try query.blob(4);
            if (application.len != 32) return error.InvalidDurableState;
            const ordinal = self.resolve(application[0..32]) catch |err| return if (err == error.ApplicationIdentityMismatch) error.UnknownApplication else err;
            if (try query.step() != .done) return error.InvalidDurableState;
            break :blk .{ .state = state, .input = input, .adapter = adapter, .receipt = receipt, .ordinal = ordinal };
        };
        return self.replayWorker(row.ordinal, row);
    }

    /// Bounded local delivery batch. Only committed outbox rows are visible to
    /// the recipient, whose own transaction deduplicates stable intent IDs.
    pub fn dispatch(self: *Host, recipient_path: []const u8) !usize {
        try self.enter();
        defer self.in_use = false;
        if (try self.db.samePath(self.allocator, recipient_path)) return error.DatabaseRoleMismatch;
        var recipient = try sql.Db.open(self.allocator, recipient_path);
        defer recipient.close();
        if (try self.db.sameFile(&recipient)) return error.DatabaseRoleMismatch;
        try delivery.initRecipient(&recipient);
        var delivered: usize = 0;
        while (delivered < 64) : (delivered += 1) {
            const sent = delivery.deliverOne(self.allocator, &self.db, &recipient, self.checkpoint) catch |err| {
                if (err == error.DatabaseNeedsRecovery) self.poisoned = true;
                return err;
            };
            if (!sent) break;
        }
        return delivered;
    }

    fn enter(self: *Host) !void {
        if (self.poisoned) return error.HostNeedsRecovery;
        if (self.in_use or !self.db.autocommit()) return error.HostBusy;
        self.in_use = true;
    }
    pub fn rollback(self: *Host) void {
        if (!self.db.autocommit()) self.db.exec("ROLLBACK") catch {
            self.poisoned = true;
        };
    }
    fn requestIdentity(self: *const Host, identity: *const ApplicationIdentity, request: Request) [32]u8 {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("mruby-zig.durable.request.v2\x00");
        hash.update(&identity.code);
        hash.update(&identity.catalogue);
        hash.update(&identity.turn_digest);
        hashBytes(&hash, self.namespace);
        hashBytes(&hash, request.turn_id);
        hashInteger(&hash, request.expected_revision);
        hashBytes(&hash, request.input.bytes);
        return hash.finalResult();
    }
    fn upgradeIdentity(self: *const Host, request: UpgradeRequest) [32]u8 {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("mruby-zig.durable.upgrade.v1\x00");
        hash.update(&self.apps[applications.upgrade.from].application);
        hash.update(&self.apps[applications.upgrade.to].application);
        hashBytes(&hash, self.namespace);
        hashBytes(&hash, request.upgrade_id);
        hashInteger(&hash, request.expected_revision);
        return hash.finalResult();
    }
    /// Ordinal of the ledger's pinned active application, resolving it against
    /// the versions compiled into this host.
    fn storedApplication(self: *Host) !usize {
        var query = try self.db.prepare("SELECT value FROM durable_metadata WHERE key='application'");
        defer query.deinit();
        if (try query.step() != .row) return error.UnknownApplication;
        const value = try query.text(0);
        if (value.len != 64) return error.UnknownApplication;
        var identity: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&identity, value) catch return error.UnknownApplication;
        if (try query.step() != .done) return error.InvalidDurableState;
        return self.resolve(&identity);
    }
    fn resolve(self: *const Host, identity: *const [32]u8) !usize {
        inline for (self.apps, 0..) |app, index| {
            if (std.mem.eql(u8, &app.application, identity)) return index;
        }
        return error.ApplicationIdentityMismatch;
    }
    fn workerOptions(self: *const Host, comptime index: usize, adapter: [32]u8) Worker.Options {
        return .{ .process = self.process, .turn = .{
            .allowed = applications.versions[index].contract.grants,
            .contract = applications.versions[index].turn_shape,
            .diagnostic = self.diagnostic,
            .bootstrap_identity = self.apps[index].bootstrap,
            .adapter_state_identity = adapter,
            .capsule_limits = .{ .max_encoded_bytes = contract.max_bytes },
            .effect_limits = .{ .max_records = 32, .max_bytes = 128 * 1024, .max_request_bytes = contract.max_bytes, .max_result_bytes = contract.max_bytes },
            .receipt_limits = receiptLimits(),
        } };
    }
    fn prepareWorker(self: *Host, ordinal: usize, execution: *Execution, state: View, bindings: []const mruby.effect.DataBinding) !Turn.Prepared {
        inline for (applications.versions, 0..) |app, index| {
            if (index == ordinal) return Worker.prepare(self.allocator, self.executables[index], app.manifest, app.entry, app.contract.operations, .{
                .receiver = "Inventory",
                .state = state,
                .input = execution.request.input,
            }, .{ .bindings = bindings, .transaction = execution.transaction() }, self.workerOptions(index, execution.adapter_identity));
        }
        return error.UnknownApplication;
    }
    fn replayWorker(self: *Host, ordinal: usize, row: anytype) !Turn.Verified {
        inline for (applications.versions, 0..) |app, index| {
            if (index == ordinal) return Worker.replay(self.allocator, self.executables[index], app.manifest, app.entry, app.contract.operations, .{
                .receiver = "Inventory",
                .state = .{ .bytes = row.state },
                .input = .{ .bytes = row.input },
            }, row.receipt, self.workerOptions(index, row.adapter));
        }
        return error.UnknownApplication;
    }
    fn cached(self: *Host, turn_id: []const u8, fingerprint: [32]u8, ordinal: usize) !?Result {
        var query = try self.db.prepare("SELECT request_hash,revision,receipt FROM turns WHERE turn_id=?");
        defer query.deinit();
        try query.bindText(1, turn_id);
        if (try query.step() == .done) return null;
        // A stored fingerprint that differs from the caller's means this is not
        // the request that committed; the contract that produced it must not be
        // reinterpreted. Matching fingerprints imply the same application data.
        if (!std.mem.eql(u8, try query.blob(0), &fingerprint)) return error.TurnIdConflict;
        const revision = try query.int(1);
        if (revision <= 0) return error.InvalidDurableState;
        var verified = try verifiedCopy(self.allocator, try query.blob(2), shapeAt(ordinal), self.diagnostic);
        errdefer verified.deinit();
        if (try query.step() != .done) return error.InvalidDurableState;
        return .{ .verified = verified, .revision = revision, .reused = true, .effect_calls = 0 };
    }
    // ID admission is durable before business execution. Failed preparation
    // can release provisional SQL work without releasing an ID for new inputs.
    fn admit(self: *Host, request: Request, fingerprint: [32]u8) !?Result {
        try self.db.exec("BEGIN IMMEDIATE");
        defer if (!self.poisoned) self.rollback();
        if (try self.cached(request.turn_id, fingerprint, try self.storedApplication())) |result| return result;
        const registered = blk: {
            var query = try self.db.prepare("SELECT request_hash FROM admissions WHERE turn_id=?");
            defer query.deinit();
            try query.bindText(1, request.turn_id);
            if (try query.step() == .done) break :blk false;
            if (!std.mem.eql(u8, try query.blob(0), &fingerprint)) return error.TurnIdConflict;
            if (try query.step() != .done) return error.InvalidDurableState;
            break :blk true;
        };
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const state = try self.readState(arena.allocator(), try self.storedApplication());
        if (state.revision != request.expected_revision) return error.StaleState;
        if (!registered) {
            var insert = try self.db.prepare("INSERT INTO admissions(turn_id,request_hash) VALUES(?,?)");
            defer insert.deinit();
            try insert.bindText(1, request.turn_id);
            try insert.bindBlob(2, &fingerprint);
            try done(&insert);
        }
        self.db.exec("COMMIT") catch {
            self.poisoned = true;
            return error.CommitIndeterminate;
        };
        return null;
    }

    fn readState(self: *Host, allocator: std.mem.Allocator, ordinal: usize) !struct { revision: i64, attempts: i64, rejections: i64, capsule: View } {
        var query = try self.db.prepare("SELECT revision,state FROM current_state WHERE id=1");
        defer query.deinit();
        if (try query.step() != .row) return error.InvalidDurableState;
        const revision = try query.int(0);
        const bytes = try query.copyBlob(allocator, 1, contract.max_bytes);
        errdefer allocator.free(bytes);
        var state = try decodeData(allocator, .{ .bytes = bytes });
        defer state.deinit();
        try validateValue(shapeAt(ordinal), state.root(), .state, self.diagnostic);
        const attempts = try (try field(state.root(), "attempts")).asInteger();
        // v1 requires one attempt per revision. v2 revisions may additionally
        // cover published upgrades, and every rejection is also an attempt.
        const rejections: i64 = if ((try state.root().get("rejections"))) |value| try value.asInteger() else 0;
        const consistent = if (ordinal == 0)
            attempts == revision
        else
            attempts <= revision and rejections <= attempts;
        if (revision < 0 or attempts < 0 or rejections < 0 or !consistent or try query.step() != .done) return error.InvalidDurableState;
        return .{ .revision = revision, .attempts = attempts, .rejections = rejections, .capsule = .{ .bytes = bytes } };
    }
    fn adapterIdentity(self: *Host, revision: i64, turn_id: []const u8) ![32]u8 {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("mruby-zig.durable.inventory-snapshot.v1\x00");
        hashBytes(&hash, self.namespace);
        hashInteger(&hash, revision);
        // The current turn ID changes host-returned intent IDs, independently
        // of Ruby's explicit state/input, and must be in the replay identity.
        hashBytes(&hash, turn_id);
        var rows: usize = 0;
        {
            var query = try self.db.prepare("SELECT sku,quantity FROM stock ORDER BY sku COLLATE BINARY");
            defer query.deinit();
            while (try query.step() == .row) {
                if (rows >= contract.max_snapshot_rows) return error.AdapterStateLimit;
                rows += 1;
                hash.update("S");
                hashBytes(&hash, try query.text(0));
                hashInteger(&hash, try query.int(1));
            }
        }
        {
            var query = try self.db.prepare("SELECT turn_id,sequence,sku,quantity FROM reservations ORDER BY turn_id COLLATE BINARY,sequence");
            defer query.deinit();
            while (try query.step() == .row) {
                if (rows >= contract.max_snapshot_rows) return error.AdapterStateLimit;
                rows += 1;
                hash.update("R");
                hashBytes(&hash, try query.text(0));
                hashInteger(&hash, try query.int(1));
                hashBytes(&hash, try query.text(2));
                hashInteger(&hash, try query.int(3));
            }
        }
        return hash.finalResult();
    }
    fn initialize(self: *Host) !void {
        // Reject an old ledger before issuing any schema or business writes.
        // This example deliberately has no implicit migration path.
        const fresh = try self.db.scalar("SELECT count(*) FROM sqlite_schema WHERE type='table' AND name='durable_metadata'") == 0;
        if (!fresh) {
            try delivery.requireRole(&self.db, "inventory");
            var query = try self.db.prepare("SELECT value FROM durable_metadata WHERE key='schema'");
            defer query.deinit();
            if (try query.step() != .row or !std.mem.eql(u8, try query.text(0), "3")) return error.UnsupportedDurableSchema;
            if (try query.step() != .done) return error.UnsupportedDurableSchema;
        } else if (try self.db.scalar("SELECT count(*) FROM sqlite_schema WHERE type='table' AND name IN ('admissions','current_state','stock','turns','turn_versions','upgrades','reservations','outbox')") != 0) {
            return error.UnsupportedDurableSchema;
        }
        try self.db.exec("BEGIN IMMEDIATE");
        errdefer self.rollback();
        try self.db.exec("CREATE TABLE IF NOT EXISTS durable_metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL) STRICT");
        try self.db.exec("INSERT INTO durable_metadata(key,value) VALUES('role','inventory') ON CONFLICT(key) DO NOTHING");
        try delivery.requireRole(&self.db, "inventory");
        {
            var insert = try self.db.prepare("INSERT INTO durable_metadata(key,value) VALUES('namespace',?) ON CONFLICT(key) DO NOTHING");
            defer insert.deinit();
            try insert.bindText(1, self.namespace);
            try done(&insert);
        }
        {
            var query = try self.db.prepare("SELECT value FROM durable_metadata WHERE key='namespace'");
            defer query.deinit();
            if (try query.step() != .row or !std.mem.eql(u8, try query.text(0), self.namespace)) return error.DatabaseNamespaceMismatch;
        }
        try self.db.exec("INSERT INTO durable_metadata(key,value) VALUES('schema','3') ON CONFLICT(key) DO NOTHING");
        {
            var query = try self.db.prepare("SELECT value FROM durable_metadata WHERE key='schema'");
            defer query.deinit();
            if (try query.step() != .row or !std.mem.eql(u8, try query.text(0), "3")) return error.UnsupportedDurableSchema;
        }
        // A new ledger pins the first application version. An existing ledger
        // must already name a known application; missing provenance is never
        // invented, and this host must know the pinned identity or open fails.
        if (fresh) {
            const identity_text = std.fmt.bytesToHex(self.apps[0].application, .lower);
            var insert = try self.db.prepare("INSERT INTO durable_metadata(key,value) VALUES('application',?)");
            defer insert.deinit();
            try insert.bindText(1, &identity_text);
            try done(&insert);
        }
        _ = try self.storedApplication();
        try self.db.exec(schema);
        if (try self.db.scalar("SELECT count(*) FROM current_state") == 0) {
            var state = try data.encode(self.allocator, .{ .hash = &.{.{ .key = .{ .string = "attempts" }, .value = .{ .integer = 0 } }} }, contract.max_bytes);
            defer state.deinit(self.allocator);
            var insert = try self.db.prepare("INSERT INTO current_state(id,revision,state) VALUES(1,0,?)");
            defer insert.deinit();
            try insert.bindBlob(1, state.encoded);
            try done(&insert);
            try self.db.exec("INSERT INTO stock(sku,quantity) VALUES('widget',5)");
        }
        try self.db.exec("COMMIT");
    }
};

const Execution = struct {
    host: *Host,
    request: Request,
    request_hash: [32]u8,
    requested_sku: []const u8,
    requested_quantity: i64,
    ordinal: usize = 0,
    reserve_called: bool = false,
    rejected: bool = false,
    pending_reservation: ?Reservation = null,
    pending_intent: ?[64]u8 = null,
    active: bool = true,
    ready: bool = false,
    start_state: View = undefined,
    start_attempts: i64 = 0,
    start_rejections: i64 = 0,
    adapter_identity: [32]u8 = @splat(0),
    next_revision: i64 = 0,
    sequence: usize = 0,
    commit_error: ?anyerror = null,

    fn from(raw: ?*anyopaque) *Execution {
        return @ptrCast(@alignCast(raw.?));
    }
    fn bindings(self: *Execution) [2]mruby.effect.DataBinding {
        return .{
            .{ .name = "stock.reserve", .handler = reserve, .context = self },
            .{ .name = "notifications.reservation_created", .handler = notify, .context = self },
        };
    }
    fn transaction(self: *Execution) Turn.Transaction {
        return .{ .context = self, .begin = begin, .commit = commit, .discard = discard };
    }
    fn begin(raw: ?*anyopaque) !void {
        const self = from(raw);
        if (!self.active or self.ready or self.host.db.autocommit()) return error.InvalidTransactionState;
        self.ready = true;
    }
    fn abort(self: *Execution) void {
        if (!self.active) return;
        self.active = false;
        self.host.rollback();
    }
    fn discard(raw: ?*anyopaque) void {
        from(raw).abort();
    }
    fn commit(raw: ?*anyopaque, terminal: View, receipt: []const u8) !Turn.CommitOutcome {
        const self = from(raw);
        return self.persist(terminal, receipt) catch |err| {
            // This bracket ends before issuing COMMIT. Known preparation errors
            // leave a provisional transaction for Prepared's discard hook.
            self.commit_error = err;
            return .rejected;
        };
    }
    fn persist(self: *Execution, terminal: View, receipt: []const u8) !Turn.CommitOutcome {
        if (!self.active or !self.ready) return error.InvalidTransactionState;
        const shape = shapeAt(self.ordinal);
        var document = try decodeData(self.host.allocator, terminal);
        defer document.deinit();
        const result = try document.root().at(0);
        const next_state = try document.root().at(1);
        try validateValue(shape, result, .result, self.host.diagnostic);
        try validateValue(shape, next_state, .next_state, self.host.diagnostic);
        try self.validateResult(result);
        var state = try data.encodeRef(self.host.allocator, next_state, contract.max_bytes);
        defer state.deinit(self.host.allocator);
        {
            // Every turn advances the attempt count exactly once; a v2 turn
            // additionally advances its rejection counter only when the domain
            // operation reported the declared OutOfStock rejection.
            const attempts = try (try field(next_state, "attempts")).asInteger();
            if (attempts != self.start_attempts + 1) return error.InvalidTurnState;
            if (self.ordinal != 0) {
                const rejections = try (try field(next_state, "rejections")).asInteger();
                if (rejections != self.start_rejections + @as(i64, if (self.rejected) 1 else 0)) return error.InvalidTurnState;
            }
        }
        {
            var update = try self.host.db.prepare("UPDATE current_state SET revision=?,state=? WHERE id=1 AND revision=?");
            defer update.deinit();
            try update.bindInt(1, self.next_revision);
            try update.bindBlob(2, state.encoded);
            try update.bindInt(3, self.request.expected_revision);
            try done(&update);
            if (self.host.db.changes() != 1) return error.StaleState;
        }
        {
            var insert = try self.host.db.prepare("INSERT INTO turns(turn_id,request_hash,starting_revision,start_state,input,adapter_identity,receipt,revision) VALUES(?,?,?,?,?,?,?,?)");
            defer insert.deinit();
            try insert.bindText(1, self.request.turn_id);
            try insert.bindBlob(2, &self.request_hash);
            try insert.bindInt(3, self.request.expected_revision);
            try insert.bindBlob(4, self.start_state.bytes);
            try insert.bindBlob(5, self.request.input.bytes);
            try insert.bindBlob(6, &self.adapter_identity);
            try insert.bindBlob(7, receipt);
            try insert.bindInt(8, self.next_revision);
            try done(&insert);
        }
        // Historical replay routes to the bundle and contracts that committed
        // this turn, even after the active application moves on.
        {
            var insert = try self.host.db.prepare("INSERT INTO turn_versions(turn_id,application) VALUES(?,?)");
            defer insert.deinit();
            try insert.bindText(1, self.request.turn_id);
            try insert.bindBlob(2, &self.host.apps[self.ordinal].application);
            try done(&insert);
        }
        self.host.checkpoint.reach(.before_commit);
        self.host.db.exec("COMMIT") catch {
            // Conservatively classify every COMMIT error as uncertain. Suppress
            // generic rollback/retry; close and reopen, then look up this ID.
            self.active = false;
            self.host.poisoned = true;
            return .indeterminate;
        };
        self.active = false;
        self.host.checkpoint.reach(.after_commit);
        return .committed;
    }
    fn requireActive(self: *Execution) !void {
        if (!self.active or !self.ready or self.host.db.autocommit()) return error.NoHostTransaction;
    }
    fn completed(self: *Execution) void {
        self.sequence += 1;
        self.host.checkpoint.reach(.after_effect);
    }
    fn reservationId(self: *const Execution) [64]u8 {
        return self.domainId("mruby-zig.durable.reservation.v2\x00", 0);
    }
    fn domainId(self: *const Execution, domain: []const u8, ordinal: i64) [64]u8 {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update(domain);
        hashBytes(&hash, self.host.namespace);
        hashBytes(&hash, self.request.turn_id);
        hashInteger(&hash, ordinal);
        return std.fmt.bytesToHex(hash.finalResult(), .lower);
    }
    fn reserve(raw: ?*anyopaque, allocator: std.mem.Allocator, arguments: View) !mruby.effect.DataOutcome {
        const self = from(raw);
        try self.requireActive();
        var document = try decodeData(allocator, arguments);
        defer document.deinit();
        const sku = try (try document.root().at(0)).asString();
        const quantity = try (try document.root().at(1)).asInteger();
        if (!std.mem.eql(u8, sku, self.requested_sku) or quantity != self.requested_quantity) return error.ReservationRequestMismatch;
        if (self.reserve_called) return error.ReservationAlreadyAttempted;
        self.reserve_called = true;
        {
            var update = try self.host.db.prepare("UPDATE stock SET quantity=quantity-? WHERE sku=? AND quantity>=?");
            defer update.deinit();
            try update.bindInt(1, quantity);
            try update.bindText(2, sku);
            try update.bindInt(3, quantity);
            try done(&update);
        }
        if (self.host.db.changes() == 0) {
            self.rejected = true;
            var rejection = try data.reject(allocator, "OutOfStock", "insufficient available inventory", 2048);
            errdefer rejection.rejected.deinit(allocator);
            self.completed();
            return rejection;
        }
        if (self.host.db.changes() != 1) return error.InvalidDurableState;
        self.host.checkpoint.reach(.after_stock_update);
        const remaining = blk: {
            var query = try self.host.db.prepare("SELECT quantity FROM stock WHERE sku=?");
            defer query.deinit();
            try query.bindText(1, sku);
            if (try query.step() != .row) return error.InvalidDurableState;
            const value = try query.int(0);
            if (value < 0 or try query.step() != .done) return error.InvalidDurableState;
            break :blk value;
        };
        {
            var insert = try self.host.db.prepare("INSERT INTO reservations(turn_id,sequence,sku,quantity) VALUES(?,0,?,?)");
            defer insert.deinit();
            try insert.bindText(1, self.request.turn_id);
            try insert.bindText(2, self.requested_sku);
            try insert.bindInt(3, quantity);
            try done(&insert);
        }
        self.host.checkpoint.reach(.after_reservation_insert);
        const reservation: Reservation = .{ .id = self.reservationId(), .sku = self.requested_sku, .quantity = quantity, .remaining = remaining };
        self.pending_reservation = reservation;
        var observation = reservation;
        if (self.host.fault == .invalid_reservation_result) observation.quantity = 0;
        var outcome = if (self.host.fault == .undeclared_rejection)
            try data.reject(allocator, "DatabaseUnavailable", "not a declared business rejection", 2048)
        else
            mruby.effect.DataOutcome{ .returned = try encodeReservation(allocator, observation) };
        errdefer switch (outcome) {
            .returned, .rejected => |*capsule| capsule.deinit(allocator),
        };
        self.completed();
        return outcome;
    }
    fn notify(raw: ?*anyopaque, allocator: std.mem.Allocator, arguments: View) !mruby.effect.DataOutcome {
        const self = from(raw);
        try self.requireActive();
        var document = try decodeData(allocator, arguments);
        defer document.deinit();
        const reservation = self.pending_reservation orelse return error.ReservationNotPending;
        if (self.pending_intent != null) return error.NotificationAlreadyPending;
        if (!try reservation.matches(try document.root().at(0))) return error.ReservationDoesNotMatch;
        // The host supplies destination, canonical payload and intent identity.
        // A typed guest object alone never authorizes a different reservation.
        var payload = try encodeReservation(allocator, reservation);
        defer payload.deinit(allocator);
        const id = self.domainId("mruby-zig.durable.intent.v2\x00", 1);
        {
            var insert = try self.host.db.prepare("INSERT INTO outbox(intent_id,turn_id,sequence,destination,payload,delivered) VALUES(?,?,1,'reservations',?,0)");
            defer insert.deinit();
            try insert.bindText(1, &id);
            try insert.bindText(2, self.request.turn_id);
            try insert.bindBlob(3, payload.encoded);
            try done(&insert);
        }
        self.pending_intent = id;
        var result = try data.encode(allocator, if (self.host.fault == .invalid_notification_result) .nil else .{ .string = &id }, 256);
        errdefer result.deinit(allocator);
        self.completed();
        return .{ .returned = result };
    }
    fn validateResult(self: *const Execution, result: data.Ref) !void {
        const status = try (try field(result, "status")).asString();
        if (std.mem.eql(u8, status, "reserved")) {
            const reservation = self.pending_reservation orelse return error.InvalidTurnResult;
            const intent = self.pending_intent orelse return error.InvalidTurnResult;
            if (!self.reserve_called or self.rejected or try result.get("code") != null or
                !try reservation.matches((try result.get("reservation")) orelse return error.InvalidTurnResult) or
                !std.mem.eql(u8, try (try field(result, "intent")).asString(), &intent)) return error.InvalidTurnResult;
        } else if (std.mem.eql(u8, status, "rejected")) {
            if (!self.reserve_called or !self.rejected or self.pending_reservation != null or self.pending_intent != null or
                try result.get("reservation") != null or try result.get("intent") != null or
                !std.mem.eql(u8, try (try field(result, "code")).asString(), "OutOfStock")) return error.InvalidTurnResult;
        } else return error.InvalidTurnResult;
    }
};

const Reservation = struct {
    id: [64]u8,
    // Borrowed only from execute's owned immutable input snapshot.
    sku: []const u8,
    quantity: i64,
    remaining: i64,

    fn matches(self: Reservation, value: data.Ref) !bool {
        return std.mem.eql(u8, &self.id, try (try field(value, "id")).asString()) and
            std.mem.eql(u8, self.sku, try (try field(value, "sku")).asString()) and
            self.quantity == try (try field(value, "quantity")).asInteger() and
            self.remaining == try (try field(value, "remaining")).asInteger();
    }
};
fn encodeReservation(allocator: std.mem.Allocator, value: Reservation) !mruby.artifact.StateCapsule {
    return data.encode(allocator, .{ .hash = &.{
        .{ .key = .{ .string = "id" }, .value = .{ .string = &value.id } },
        .{ .key = .{ .string = "sku" }, .value = .{ .string = value.sku } },
        .{ .key = .{ .string = "quantity" }, .value = .{ .integer = value.quantity } },
        .{ .key = .{ .string = "remaining" }, .value = .{ .integer = value.remaining } },
    } }, 2048);
}
fn decodeData(allocator: std.mem.Allocator, view: View) !data.Document {
    return data.Document.decodeWithOptions(allocator, view, .{
        .limits = data.limits(contract.max_bytes),
        .allow_float = !mruby.features.effects_integer64,
    });
}
fn field(value: data.Ref, name: []const u8) !data.Ref {
    return (try value.get(name)) orelse error.InvalidTurnResult;
}
/// Whole-turn shape of an application ordinal from this build's table.
pub fn shapeAt(ordinal: usize) *const Turn.Contract {
    var shape: ?*const Turn.Contract = null;
    inline for (applications.versions, 0..) |app, index| {
        if (index == ordinal) shape = app.turn_shape;
    }
    return shape orelse unreachable;
}
/// Ledger application identity: label, artifact code, operation catalogue,
/// whole-turn contract, bootstrap contract, and the RITE compatibility profile
/// this build produced. Changing any of them changes the pinned identity, so
/// ledgers from other applications or profiles fail closed at open.
fn identifyApplication(comptime app: applications.Descriptor, namespace: []const u8) !ApplicationIdentity {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("mruby-zig.durable.bootstrap.v1\x00");
    hashBytes(&hash, app.contract.bootstrap_contract);
    hashBytes(&hash, namespace);
    const bootstrap = hash.finalResult();
    const program = try mruby.strict.identify(app.manifest, app.entry, .{ .bootstrap_identity = bootstrap, .effects = .{ .allowed = app.contract.grants } });
    const invocation: mruby.effect.Invocation = .{ .code = program.code, .bootstrap = program.bootstrap, .state = @splat(0), .receiver = "Inventory" };
    const catalogue = try mruby.effect.catalogueIdentity(app.contract.operations);
    const turn_digest = app.turn_shape.digest();
    var application = std.crypto.hash.sha2.Sha256.init(.{});
    application.update("mruby-zig.durable.application.v1\x00");
    hashBytes(&application, app.label);
    application.update(&program.code);
    application.update(&catalogue);
    application.update(&turn_digest);
    hashBytes(&application, app.contract.bootstrap_contract);
    hashBytes(&application, mruby.features.rite_compatibility_fingerprint_hex);
    return .{
        .code = invocation.codeIdentity("apply"),
        .catalogue = catalogue,
        .turn_digest = turn_digest,
        .bootstrap = bootstrap,
        .application = application.finalResult(),
    };
}
pub fn validateValue(shape: *const Turn.Contract, value: data.Ref, comptime side: anytype, diagnostic: ?*Turn.Diagnostic) !void {
    if (shape.validate(side, value)) |mismatch| {
        if (diagnostic) |output| output.* = .{ .kind = .contract, .origin = .broker, .phase = switch (side) {
            .input, .state => .setup,
            .result, .next_state => .verification,
            else => unreachable,
        }, .contract_detail = mismatch };
        return error.TurnContractViolation;
    }
}
fn hostError(diagnostic: ?*Turn.Diagnostic, err: anyerror) void {
    const output = diagnostic orelse return;
    if (output.kind == .none) output.* = .{ .kind = .failure, .origin = .broker };
    if (output.error_name_len == 0) {
        const name = @errorName(err);
        const len = @min(name.len, output.error_name.len);
        @memcpy(output.error_name[0..len], name[0..len]);
        output.error_name_len = @intCast(len);
    }
}

fn receiptLimits() Turn.Receipt.Limits {
    return .{ .max_encoded_bytes = contract.max_receipt_bytes, .max_trace_bytes = 128 * 1024, .max_terminal_bytes = contract.max_bytes };
}
fn verifiedCopy(allocator: std.mem.Allocator, bytes: []const u8, shape: *const Turn.Contract, diagnostic: ?*Turn.Diagnostic) !Turn.Verified {
    const receipt = try Turn.Receipt.decode(bytes, receiptLimits());
    var trace = try mruby.effect.Trace.decode(allocator, receipt.trace, .{ .max_records = 32, .max_bytes = 128 * 1024, .max_request_bytes = contract.max_bytes, .max_result_bytes = contract.max_bytes });
    defer trace.deinit();
    var terminal = try decodeData(allocator, receipt.terminal);
    defer terminal.deinit();
    if (terminal.root().kind() != .array or try terminal.root().len() != 2) return error.InvalidTurnResult;
    try validateValue(shape, try terminal.root().at(0), .result, diagnostic);
    try validateValue(shape, try terminal.root().at(1), .next_state, diagnostic);
    const terminal_bytes = try allocator.dupe(u8, receipt.terminal.bytes);
    errdefer allocator.free(terminal_bytes);
    return .{ .allocator = allocator, .terminal_capsule = .{ .encoded = terminal_bytes }, .receipt_bytes = try allocator.dupe(u8, bytes), .max_terminal_bytes = contract.max_bytes };
}
/// One retention call archives at most this many receipts, bounding memory
/// and the atomic file write. Callers loop for longer histories.
const max_prune_batch: usize = 256;
const max_archive_bytes: usize = 16 * 1024 * 1024;

/// JSON string with the same conservative escaping as the diagnostic writer.
fn jsonText(writer: *std.Io.Writer, bytes: []const u8) !void {
    const hex = "0123456789abcdef";
    try writer.writeByte('"');
    for (bytes) |byte| switch (byte) {
        '"', '\\' => {
            try writer.writeByte('\\');
            try writer.writeByte(byte);
        },
        0x20...0x21, 0x23...0x5b, 0x5d...0x7e => try writer.writeByte(byte),
        else => try writer.writeAll(&.{ '\\', 'u', '0', '0', hex[byte >> 4], hex[byte & 15] }),
    };
    try writer.writeByte('"');
}

fn validName(name: []const u8) !void {
    if (name.len == 0 or name.len > 128 or std.mem.indexOfScalar(u8, name, 0) != null) return error.InvalidName;
}
fn done(statement: *sql.Statement) !void {
    if (try statement.step() != .done) return error.DatabaseUnexpectedRow;
}
fn hashBytes(hash: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, @intCast(bytes.len), .big);
    hash.update(&length);
    hash.update(bytes);
}
fn hashInteger(hash: *std.crypto.hash.sha2.Sha256, integer: i64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(i64, &bytes, integer, .big);
    hash.update(&bytes);
}
const schema =
    "CREATE TABLE IF NOT EXISTS admissions(turn_id TEXT PRIMARY KEY,request_hash BLOB NOT NULL CHECK(length(request_hash)=32)) STRICT;" ++
    "CREATE TABLE IF NOT EXISTS current_state(id INTEGER PRIMARY KEY CHECK(id=1),revision INTEGER NOT NULL CHECK(revision>=0),state BLOB NOT NULL) STRICT;" ++
    "CREATE TABLE IF NOT EXISTS stock(sku TEXT PRIMARY KEY,quantity INTEGER NOT NULL CHECK(quantity>=0)) STRICT;" ++
    "CREATE TABLE IF NOT EXISTS turns(turn_id TEXT PRIMARY KEY,request_hash BLOB NOT NULL CHECK(length(request_hash)=32),starting_revision INTEGER NOT NULL,start_state BLOB NOT NULL,input BLOB NOT NULL,adapter_identity BLOB NOT NULL CHECK(length(adapter_identity)=32),receipt BLOB NOT NULL,revision INTEGER NOT NULL UNIQUE CHECK(revision>0)) STRICT;" ++
    "CREATE TABLE IF NOT EXISTS turn_versions(turn_id TEXT PRIMARY KEY,application BLOB NOT NULL CHECK(length(application)=32),FOREIGN KEY(turn_id) REFERENCES turns(turn_id)) STRICT;" ++
    "CREATE TABLE IF NOT EXISTS upgrades(upgrade_id TEXT PRIMARY KEY,request_hash BLOB NOT NULL CHECK(length(request_hash)=32),from_application BLOB NOT NULL CHECK(length(from_application)=32),to_application BLOB NOT NULL CHECK(length(to_application)=32),starting_revision INTEGER NOT NULL CHECK(starting_revision>=0),revision INTEGER NOT NULL CHECK(revision>0)) STRICT;" ++
    "CREATE TABLE IF NOT EXISTS reservations(turn_id TEXT NOT NULL,sequence INTEGER NOT NULL CHECK(sequence>=0),sku TEXT NOT NULL REFERENCES stock(sku),quantity INTEGER NOT NULL CHECK(quantity>0),PRIMARY KEY(turn_id,sequence),FOREIGN KEY(turn_id) REFERENCES turns(turn_id) DEFERRABLE INITIALLY DEFERRED) STRICT;" ++
    "CREATE TABLE IF NOT EXISTS outbox(intent_id TEXT PRIMARY KEY,turn_id TEXT NOT NULL,sequence INTEGER NOT NULL CHECK(sequence>=0),destination TEXT NOT NULL,payload BLOB NOT NULL,delivered INTEGER NOT NULL CHECK(delivered IN(0,1)),UNIQUE(turn_id,sequence),FOREIGN KEY(turn_id) REFERENCES turns(turn_id) DEFERRABLE INITIALLY DEFERRED) STRICT;";
