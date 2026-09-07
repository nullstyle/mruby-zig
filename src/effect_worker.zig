//! OS-contained fresh turns. The broker retains host authority, independently
//! validates every RPC, and admits a result only after a second fresh replay.
//! No Ruby VM is created in this process. The executable and native adapters
//! remain trusted host code; callbacks must stage writes for Turn.Transaction.
const std = @import("std");
const strict = @import("strict.zig");
const Turn = @import("strict_turn.zig");
const inert = @import("strict_turn_data.zig");
const effect = @import("effect.zig");
const artifact = @import("artifact.zig");
const features = @import("features.zig");
pub const Process = @import("effect_worker_process.zig");
pub const Runtime = @import("effect_worker_runtime.zig");
pub const Protocol = @import("effect_worker_protocol.zig");
const protocol = Protocol;
pub const DiagnosticCodec = @import("effect_worker_diagnostic.zig");
const diagnostic_wire = DiagnosticCodec;

pub const ProcessLimits = struct {
    /// One deadline covers recording and the mandatory verification process.
    wall_time_ns: u64 = 30 * std.time.ns_per_s,
    /// Per-child OS CPU limit, including initialization and native execution.
    cpu_seconds: u32 = 30,
    /// OS address space, not just Ruby allocations. Unsupported on macOS.
    address_space_bytes: ?usize = null,
    /// Total bytes sent and received in each child session.
    max_transfer_bytes: u64 = protocol.max_session_bytes,
};
pub const Observation = struct {
    execution_pid: ?i32 = null,
    verification_pid: ?i32 = null,
};
pub const Options = struct {
    turn: Turn.Options = .{},
    process: ProcessLimits = .{},
    /// Host diagnostics only. Process identities never become Ruby inputs.
    observation: ?*Observation = null,
};

pub fn prepare(
    allocator: std.mem.Allocator,
    worker_executable: []const u8,
    comptime manifest: type,
    entry: []const u8,
    comptime operations: anytype,
    request: Turn.Request,
    host: Turn.Host,
    options: Options,
) !Turn.Prepared {
    if (comptime !features.effects_worker_supported) return error.UnsupportedPlatform;
    if (options.observation) |observation| observation.* = .{};
    if (options.turn.diagnostic) |diagnostic| diagnostic.* = .{};
    var phase: @FieldType(Turn.Diagnostic, "phase") = .setup;
    return prepareImpl(allocator, worker_executable, manifest, entry, operations, request, host, options, &phase) catch |err| {
        finishDiagnostic(options.turn.diagnostic, err, phase);
        return err;
    };
}

fn prepareImpl(allocator: std.mem.Allocator, worker_executable: []const u8, comptime manifest: type, entry: []const u8, comptime operations: anytype, request: Turn.Request, host: Turn.Host, options: Options, phase: *@FieldType(Turn.Diagnostic, "phase")) !Turn.Prepared {
    const started = try Process.nowNs();
    const deadline = std.math.add(u64, started, options.process.wall_time_ns) catch return error.InvalidProcessLimits;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const owned = arena.allocator();
    // Snapshot every caller-owned byte/function table before host begin.
    var setup = try Setup.init(owned, manifest, entry, operations, request, host.bindings, options);
    const executable = try owned.dupe(u8, worker_executable);
    var journal = effect.Trace.init(allocator, setup.identity, options.turn.effect_limits);
    defer journal.deinit();
    var begun = false;
    errdefer if (begun) if (host.transaction) |transaction| transaction.discard(transaction.context);
    phase.* = .record;
    const receipt = try runSession(allocator, executable, &setup, .record, &.{}, &journal, host.transaction, &begun, deadline, if (options.observation) |o| &o.execution_pid else null);
    defer allocator.free(receipt);
    // Replay has no callback table or transaction access. A successful exit
    // proves the supplied terminal graph matches another fresh execution.
    phase.* = .verification;
    const replay_receipt = try runSession(allocator, executable, &setup, .replay, receipt, null, null, null, deadline, if (options.observation) |o| &o.verification_pid else null);
    defer allocator.free(replay_receipt);
    var verified = try ownedVerified(allocator, receipt, setup.options);
    errdefer verified.deinit();
    try checkDeadline(deadline);
    return .{ .verified = verified, .transaction = host.transaction };
}

/// Replay grants no host callback surface, and never starts a host transaction.
pub fn replay(
    allocator: std.mem.Allocator,
    worker_executable: []const u8,
    comptime manifest: type,
    entry: []const u8,
    comptime operations: anytype,
    request: Turn.Request,
    receipt_bytes: []const u8,
    options: Options,
) !Turn.Verified {
    if (comptime !features.effects_worker_supported) return error.UnsupportedPlatform;
    if (options.observation) |observation| observation.* = .{};
    if (options.turn.diagnostic) |diagnostic| diagnostic.* = .{};
    var phase: @FieldType(Turn.Diagnostic, "phase") = .setup;
    return replayImpl(allocator, worker_executable, manifest, entry, operations, request, receipt_bytes, options, &phase) catch |err| {
        finishDiagnostic(options.turn.diagnostic, err, phase);
        return err;
    };
}

fn replayImpl(allocator: std.mem.Allocator, worker_executable: []const u8, comptime manifest: type, entry: []const u8, comptime operations: anytype, request: Turn.Request, receipt_bytes: []const u8, options: Options, phase: *@FieldType(Turn.Diagnostic, "phase")) !Turn.Verified {
    const deadline = std.math.add(u64, try Process.nowNs(), options.process.wall_time_ns) catch return error.InvalidProcessLimits;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const owned = arena.allocator();
    var setup = try Setup.init(owned, manifest, entry, operations, request, &.{}, options);
    // Bounds and complete graph validation precede copying/spawning.
    _ = try setup.validateReceipt(allocator, receipt_bytes, null);
    const snapshot = try owned.dupe(u8, receipt_bytes);
    phase.* = .replay;
    const receipt = try runSession(allocator, worker_executable, &setup, .replay, snapshot, null, null, null, deadline, if (options.observation) |o| &o.verification_pid else null);
    defer allocator.free(receipt);
    var verified = try ownedVerified(allocator, receipt, setup.options);
    errdefer verified.deinit();
    try checkDeadline(deadline);
    return verified;
}

const Setup = struct {
    start: protocol.Start,
    body: protocol.StartBody,
    options: Turn.Options,
    catalogue: []const effect.Operation,
    bindings: []const ?effect.DataBinding,
    identity: effect.Identity,

    fn init(allocator: std.mem.Allocator, comptime manifest: type, entry: []const u8, comptime operations: anytype, request: Turn.Request, bindings: []const effect.DataBinding, options: Options) !Setup {
        const catalogue = try allocator.dupe(effect.Operation, &(try effect.describeCatalogue(operations)));
        const table = try allocator.alloc(?effect.DataBinding, catalogue.len);
        @memset(table, null);
        const ordered_grants = try allocator.alloc(u8, options.turn.allowed.len);
        const allowed = try allocator.alloc([]const u8, ordered_grants.len);
        var start: protocol.Start = .{
            .application_identity = @splat(0),
            .bootstrap_identity = options.turn.bootstrap_identity,
            .adapter_state_identity = options.turn.adapter_state_identity,
            .operation_count = @intCast(catalogue.len),
            .grant_order_len = ordered_grants.len,
            .entry_len = entry.len,
            .receiver_len = request.receiver.len,
            .method_len = request.method.len,
            .state_len = request.state.bytes.len,
            .input_len = request.input.bytes.len,
            .policy = try wirePolicy(options.turn),
            .capsule_limits = wireCapsule(options.turn.capsule_limits),
            .effect_limits = .{
                .max_records = options.turn.effect_limits.max_records,
                .max_bytes = options.turn.effect_limits.max_bytes,
                .max_request_bytes = options.turn.effect_limits.max_request_bytes,
                .max_result_bytes = options.turn.effect_limits.max_result_bytes,
            },
            .receipt_limits = .{
                .max_encoded_bytes = options.turn.receipt_limits.max_encoded_bytes,
                .max_trace_bytes = options.turn.receipt_limits.max_trace_bytes,
                .max_terminal_bytes = options.turn.receipt_limits.max_terminal_bytes,
            },
            .process = .{
                .wall_time_ns = options.process.wall_time_ns,
                .cpu_seconds = options.process.cpu_seconds,
                .address_space = if (options.process.address_space_bytes) |n| .{ .bytes = n } else .unbounded,
            },
            .max_transfer_bytes = options.process.max_transfer_bytes,
        };
        if (ordered_grants.len > catalogue.len) return error.DuplicateEffectGrant;
        for (options.turn.allowed, ordered_grants, allowed) |name, *index, *stable_name| {
            const found = findOperation(catalogue, name) orelse return error.UnknownEffect;
            if (start.granted(found)) return error.DuplicateEffectGrant;
            try start.setGrant(found);
            index.* = @intCast(found);
            stable_name.* = catalogue[found].name;
        }
        for (bindings) |binding| {
            const index = findOperation(catalogue, binding.name) orelse return error.UnknownEffect;
            if (table[index] != null) return error.DuplicateEffectBinding;
            table[index] = .{ .name = catalogue[index].name, .handler = binding.handler, .context = binding.context };
        }
        var turn_options = options.turn;
        turn_options.allowed = allowed;
        const snapshot = try inert.Snapshot.init(allocator, request, turn_options);
        turn_options.contract = snapshot.contract;
        start.application_identity = protocol.applicationIdentityWithContract(manifest, operations, features.rite_compatibility_fingerprint, snapshot.contract);
        _ = try protocol.encode(.{ .start = start });
        const entry_copy = try allocator.dupe(u8, entry);
        const identity = try strict.identify(manifest, entry_copy, .{ .bootstrap_identity = turn_options.bootstrap_identity, .effects = .{ .allowed = allowed } });
        const invocation: effect.Invocation = .{ .code = identity.code, .bootstrap = identity.bootstrap, .state = snapshot.identity, .receiver = snapshot.request.receiver };
        var state_document = try decodeData(allocator, snapshot.request.state, options.turn.capsule_limits.max_encoded_bytes);
        defer state_document.deinit();
        var input_document = try decodeData(allocator, snapshot.request.input, options.turn.capsule_limits.max_encoded_bytes);
        defer input_document.deinit();
        var arguments = try effect.data.encodeRefs(allocator, &.{ state_document.root(), input_document.root() }, @min(options.turn.effect_limits.max_request_bytes, options.turn.effect_limits.max_bytes));
        defer arguments.deinit(allocator);
        return .{
            .start = start,
            .body = .{ .entry = entry_copy, .receiver = snapshot.request.receiver, .method = snapshot.request.method, .grant_order = ordered_grants, .state = snapshot.request.state.bytes, .input = snapshot.request.input.bytes, .receipt = &.{} },
            .options = turn_options,
            .catalogue = catalogue,
            .bindings = table,
            .identity = .{ .code = invocation.codeIdentity(snapshot.request.method), .catalogue = try effect.catalogueIdentity(operations), .input = invocation.inputIdentity(@splat(0), arguments.encoded) },
        };
    }

    fn validateRequest(self: *const Setup, allocator: std.mem.Allocator, request: protocol.EffectRequest, body: []const u8, sequence: usize) !protocol.EffectRequestBody {
        if (request.sequence != sequence or request.operation_index >= self.catalogue.len) return error.InvalidWorkerRequest;
        const operation = self.catalogue[request.operation_index];
        const split = try protocol.splitEffectRequestBody(request, body);
        if (request.version != operation.version or !std.mem.eql(u8, split.name, operation.name)) return error.InvalidWorkerRequest;
        if (!self.start.granted(request.operation_index)) return error.EffectDenied;
        var arguments = try decodeData(allocator, .{ .bytes = split.arguments }, self.options.effect_limits.max_request_bytes);
        defer arguments.deinit();
        if (arguments.root().kind() != .array or try arguments.root().len() != operation.arity) return error.InvalidWorkerRequest;
        try self.validateContract(operation, .arguments, arguments.root(), sequence);
        return split;
    }

    fn validateContract(self: *const Setup, operation: effect.Operation, side: effect.schema.Side, value: effect.data.Ref, index: usize) !void {
        const contract = operation.contract orelse return;
        if (effect.schema.validate(contract, side, value)) |mismatch| {
            noteContractFailure(self.options.diagnostic, index, operation, mismatch);
            return error.EffectContractViolation;
        }
    }

    fn validateOutcome(self: *const Setup, allocator: std.mem.Allocator, operation: effect.Operation, view: artifact.StateCapsuleView, rejected: bool, index: usize) !void {
        var document = try decodeData(allocator, view, @min(operation.max_result_bytes, self.options.effect_limits.max_result_bytes));
        defer document.deinit();
        try self.validateContract(operation, if (rejected) .rejection else .result, document.root(), index);
        if (rejected) {
            const root = document.root();
            if (root.kind() != .array or try root.len() != 2) return error.InvalidEffectRejection;
            _ = (try root.at(0)).asString() catch return error.InvalidEffectRejection;
            _ = (try root.at(1)).asString() catch return error.InvalidEffectRejection;
        }
    }

    fn validateReceipt(self: *const Setup, allocator: std.mem.Allocator, bytes: []const u8, journal: ?*const effect.Trace) !usize {
        const receipt = try Turn.Receipt.decode(bytes, self.options.receipt_limits);
        try inert.validateTerminalContract(allocator, receipt.terminal, inert.terminalLimits(self.options), self.options.contract, self.options.diagnostic, .setup);
        var trace = try effect.Trace.decode(allocator, receipt.trace, self.options.effect_limits);
        defer trace.deinit();
        if (!trace.identity.eql(self.identity)) {
            if (self.options.diagnostic) |detail| {
                const reason: effect.Diagnostic.Reason = if (!std.mem.eql(u8, &trace.identity.code, &self.identity.code)) .identity_code else if (!std.mem.eql(u8, &trace.identity.catalogue, &self.identity.catalogue)) .identity_catalogue else .identity_input;
                detail.* = .{ .kind = .effect, .origin = .broker, .effect_detail = .{
                    .reason = reason,
                    .expected_hash = switch (reason) {
                        .identity_code => self.identity.code,
                        .identity_catalogue => self.identity.catalogue,
                        else => self.identity.input,
                    },
                    .actual_hash = switch (reason) {
                        .identity_code => trace.identity.code,
                        .identity_catalogue => trace.identity.catalogue,
                        else => trace.identity.input,
                    },
                } };
            }
            return error.EffectTraceIdentityMismatch;
        }
        if (journal) |log| if (trace.len() != log.len()) return error.WorkerReceiptMismatch;
        for (0..trace.len()) |index| {
            const record = trace.get(index).?;
            const operation_index = findOperation(self.catalogue, record.name) orelse return error.InvalidWorkerRequest;
            const operation = self.catalogue[operation_index];
            if (!self.start.granted(operation_index)) return error.EffectDenied;
            if (record.version != operation.version) return error.InvalidWorkerRequest;
            var arguments = try decodeData(allocator, .{ .bytes = record.arguments }, self.options.effect_limits.max_request_bytes);
            defer arguments.deinit();
            if (arguments.root().kind() != .array or try arguments.root().len() != operation.arity) return error.InvalidWorkerRequest;
            try self.validateContract(operation, .arguments, arguments.root(), index);
            try self.validateOutcome(allocator, operation, .{ .bytes = record.result }, record.outcome == .rejected, index);
            if (journal) |log| {
                const expected = log.get(index).?;
                if (record.version != expected.version or record.outcome != expected.outcome or
                    !std.mem.eql(u8, record.name, expected.name) or !std.mem.eql(u8, record.arguments, expected.arguments) or !std.mem.eql(u8, record.result, expected.result))
                {
                    noteJournalMismatch(self.options.diagnostic, index, expected, record);
                    return error.WorkerReceiptMismatch;
                }
            }
        }
        return trace.len();
    }
};

fn runSession(allocator: std.mem.Allocator, executable: []const u8, setup: *const Setup, mode: protocol.Mode, replay_receipt: []const u8, journal: ?*effect.Trace, transaction: ?Turn.Transaction, begun: ?*bool, deadline: u64, observed_pid: ?*?i32) ![]u8 {
    var start = setup.start;
    start.mode = mode;
    start.receipt_len = replay_receipt.len;
    const now = try Process.nowNs();
    if (now >= deadline) return error.ProcessWallExceeded;
    start.process.wall_time_ns = @min(start.process.wall_time_ns, deadline - now);
    const encoded = try protocol.encode(.{ .start = start });
    var child = try Process.Process.spawn(allocator, executable, .{ .wall_time_ns = start.process.wall_time_ns, .max_transfer_bytes = start.max_transfer_bytes, .deadline_ns = deadline });
    defer child.deinit();
    if (observed_pid) |out| out.* = child.pid;
    try child.channel.writeAll(&encoded);
    for ([_][]const u8{ setup.body.entry, setup.body.receiver, setup.body.method, setup.body.grant_order, setup.body.state, setup.body.input, replay_receipt }) |part| try child.channel.writeAll(part);
    var ready = false;
    while (true) {
        var header_bytes: [protocol.header_len]u8 = undefined;
        try child.channel.readExact(&header_bytes);
        const header = try protocol.decode(&header_bytes);
        // Validate kind/order and per-message authority bounds before allocation.
        switch (header) {
            .ready => |r| {
                if (ready or !std.mem.eql(u8, &r.application_identity, &start.application_identity)) return error.InvalidWorkerRequest;
                if (transaction) |tx| {
                    _ = try child.remainingWall();
                    try tx.begin(tx.context);
                    begun.?.* = true;
                    _ = try child.remainingWall();
                }
                ready = true;
                try child.channel.writeAll(&(try protocol.encode(.{ .ready_ack = r })));
            },
            .effect_request => |request| {
                if (!ready or mode != .record) return error.InvalidWorkerRequest;
                const log = journal orelse return error.InvalidWorkerRequest;
                dispatchRequest(allocator, &child, setup, start, request, log) catch |err| {
                    const known: ?effect.Operation = if (request.operation_index < setup.catalogue.len) setup.catalogue[request.operation_index] else null;
                    noteOperationFailure(setup.options.diagnostic, log.len(), known, err);
                    return err;
                };
            },
            .finish => |finish| {
                if (!ready or finish.receipt_len > setup.options.receipt_limits.max_encoded_bytes) return error.InvalidWorkerRequest;
                if (journal) |log| if (finish.sequence != log.len()) return error.InvalidWorkerRequest;
                const bytes = try allocator.alloc(u8, finish.receipt_len);
                errdefer allocator.free(bytes);
                try child.channel.readExact(bytes);
                const count = try setup.validateReceipt(allocator, bytes, journal);
                if (finish.sequence != count) return error.InvalidWorkerRequest;
                if (mode == .replay and !std.mem.eql(u8, bytes, replay_receipt)) return error.WorkerReceiptMismatch;
                // EOF alone is insufficient: a result followed by a crash fails.
                try child.wait();
                if (journal) |log| try log.finish();
                return bytes;
            },
            .failure => |failure| {
                const sequence: usize = if (journal) |log| log.len() else 0;
                if (failure.sequence != sequence) return error.InvalidWorkerRequest;
                var body: [protocol.max_error_name_len + protocol.max_diagnostic_len]u8 = undefined;
                const length = try header.bodyLen();
                try child.channel.readExact(body[0..length]);
                const name = body[0..failure.error_name_len];
                // Decode even if the caller did not request diagnostics: malformed
                // observations cannot weaken private-protocol admission.
                var detail: Turn.Diagnostic = if (failure.diagnostic_len != 0)
                    try diagnostic_wire.decode(body[failure.error_name_len..length])
                else
                    .{};
                detail.origin = .worker;
                const failure_error = remoteError(name);
                if (failure_error == error.WorkerFailed and detail.message_len == 0) {
                    const count = @min(name.len, detail.message.len);
                    @memcpy(detail.message[0..count], name[0..count]);
                    detail.message_len = @intCast(count);
                    detail.truncated = detail.truncated or count < name.len;
                }
                if (setup.options.diagnostic) |destination| destination.* = detail;
                return failure_error;
            },
            else => return error.InvalidWorkerRequest,
        }
    }
}

fn dispatchRequest(allocator: std.mem.Allocator, child: *Process.Process, setup: *const Setup, start: protocol.Start, request: protocol.EffectRequest, log: *effect.Trace) !void {
    if (request.sequence != log.len() or request.operation_index >= setup.catalogue.len) return error.InvalidWorkerRequest;
    if (!start.granted(request.operation_index)) return error.EffectDenied;
    const operation = setup.catalogue[request.operation_index];
    if (request.name_len != operation.name.len or request.version != operation.version) return error.InvalidWorkerRequest;
    if (request.arguments_len > setup.options.effect_limits.max_request_bytes) return error.EffectLimitExceeded;
    const body = try allocator.alloc(u8, try (protocol.Header{ .effect_request = request }).bodyLen());
    defer allocator.free(body);
    try child.channel.readExact(body);
    const split = try setup.validateRequest(allocator, request, body, log.len());
    const binding = setup.bindings[request.operation_index] orelse return error.EffectUnhandled;
    const max_result = @min(operation.max_result_bytes, setup.options.effect_limits.max_result_bytes);
    // Reserve before touching a host adapter: no unrecordable work.
    try log.reserve(operation.name, operation.version, split.arguments, max_result);
    _ = try child.remainingWall();
    const outcome = binding.handler(binding.context, allocator, .{ .bytes = split.arguments }) catch |err| {
        noteOperationFailure(setup.options.diagnostic, log.len(), operation, error.EffectHandlerFailed);
        if (setup.options.diagnostic) |detail| {
            const cause = @errorName(err);
            const length = @min(cause.len, detail.message.len);
            @memcpy(detail.message[0..length], cause[0..length]);
            detail.message_len = @intCast(length);
            detail.truncated = cause.len > length;
        }
        return error.EffectHandlerFailed;
    };
    var result = switch (outcome) {
        .returned, .rejected => |capsule| capsule,
    };
    defer result.deinit(allocator);
    _ = try child.remainingWall();
    try setup.validateOutcome(allocator, operation, result.view(), outcome == .rejected, log.len());
    try log.commitOutcome(if (outcome == .rejected) .rejected else .returned, result.encoded);
    try child.channel.writeAll(&(try protocol.encode(.{ .effect_response = .{ .sequence = request.sequence, .outcome = if (outcome == .rejected) .rejected else .returned, .result_len = result.encoded.len } })));
    try child.channel.writeAll(result.encoded);
}

fn ownedVerified(allocator: std.mem.Allocator, bytes: []const u8, options: Turn.Options) !Turn.Verified {
    const receipt = try Turn.Receipt.decode(bytes, options.receipt_limits);
    const terminal = try allocator.dupe(u8, receipt.terminal.bytes);
    errdefer allocator.free(terminal);
    return .{ .allocator = allocator, .terminal_capsule = .{ .encoded = terminal }, .receipt_bytes = try allocator.dupe(u8, bytes), .max_terminal_bytes = inert.terminalLimits(options).max_encoded_bytes };
}

fn findOperation(operations: []const effect.Operation, name: []const u8) ?usize {
    for (operations, 0..) |operation, index| if (std.mem.eql(u8, operation.name, name)) return index;
    return null;
}

fn wireCapsule(limits: artifact.CapsuleLimits) protocol.CapsuleLimits {
    return .{ .max_encoded_bytes = limits.max_encoded_bytes, .max_nodes = limits.max_nodes, .max_total_edges = limits.max_total_edges, .max_depth = limits.max_depth, .max_string_bytes = limits.max_string_bytes, .max_symbol_bytes = limits.max_symbol_bytes };
}

fn wirePolicy(options: Turn.Options) !protocol.Policy {
    const policy = options.policy;
    if (policy.capabilities.random_seed != null or policy.capabilities.clock_epoch_s != null or (policy.limits.instructions != null and policy.limits.gas != null)) return error.InvalidStrictPolicy;
    const gas: protocol.Gas = if (policy.limits.gas) |value| switch (value) {
        .unlimited => return error.InvalidStrictPolicy,
        .per_isolate => |n| .{ .per_isolate = n },
        .per_execution => |n| .{ .per_execution = n },
    } else if (policy.limits.instructions) |n| .{ .per_isolate = n } else .{ .per_execution = 100_000 };
    return .{ .gas = gas, .wall_time_ns = policy.limits.wall_time_ns, .memory_bytes = policy.limits.memory_bytes, .hard_memory_bytes = policy.limits.hard_memory_bytes, .call_depth = policy.limits.call_depth, .artifacts = .{ .max_rite_bytes = policy.artifacts.limits.max_rite_bytes, .capsule = wireCapsule(policy.artifacts.limits.capsule), .application = if (policy.artifacts.application) |app| app.bytes else null } };
}

// Every broker-side graph admission uses the binary's numeric policy before
// operation contracts or adapters. Structural inspection remains independent.
fn decodeData(allocator: std.mem.Allocator, view: artifact.StateCapsuleView, max_bytes: usize) !effect.data.Document {
    return effect.data.Document.decodeWithOptions(allocator, view, .{
        .limits = effect.data.limits(max_bytes),
        .allow_float = !features.effects_integer64,
    });
}

fn remoteError(name: []const u8) anyerror {
    if (std.mem.eql(u8, name, "WorkerApplicationMismatch")) return error.WorkerApplicationMismatch;
    inline for (.{ error.RubyException, error.GasExhausted, error.DeadlineExceeded, error.MemoryLimitExceeded, error.CallDepthExceeded, error.NativeEffectViolation, error.EffectDenied, error.EffectUnhandled, error.EffectHandlerFailed, error.EffectLimitExceeded, error.EffectContractViolation, error.NumericPolicyViolation, error.TurnContractViolation, error.InvalidTurnContract, error.EffectDuringInitialization, error.EffectInitializationFailed, error.EffectReplayMismatch, error.EffectTraceIdentityMismatch, error.EffectTraceIncomplete, error.InvalidTurnResult, error.TerminalMismatch, error.OutOfMemory, error.ConfinementUnavailable, error.InvalidProcessLimits, error.ProcessWallExceeded, error.UnsupportedValue, error.CapsuleLimitExceeded, error.ArtifactLimitExceeded }) |err| {
        if (std.mem.eql(u8, name, @errorName(err))) return err;
    }
    return error.WorkerFailed;
}

fn checkDeadline(deadline: u64) !void {
    if (try Process.nowNs() >= deadline) return error.ProcessWallExceeded;
}

// Diagnostics are observational snapshots. These helpers allocate nothing and
// never change the execution error or perform an operation on the caller's behalf.
fn finishDiagnostic(destination: ?*Turn.Diagnostic, err: anyerror, phase: @FieldType(Turn.Diagnostic, "phase")) void {
    const detail = destination orelse return;
    if (detail.kind == .none) detail.kind = .failure;
    if (detail.origin == .none) detail.origin = .broker;
    detail.phase = phase;
    const name = @errorName(err);
    const length = @min(name.len, detail.error_name.len);
    @memset(&detail.error_name, 0);
    @memcpy(detail.error_name[0..length], name[0..length]);
    detail.error_name_len = @intCast(length);
    detail.truncated = detail.truncated or name.len > length;
}

fn noteOperationFailure(destination: ?*Turn.Diagnostic, index: usize, operation: ?effect.Operation, err: anyerror) void {
    const detail = destination orelse return;
    if (detail.kind != .none) return;
    var event: effect.Diagnostic = .{ .record_index = index, .reason = switch (err) {
        error.EffectDenied => .denied,
        error.EffectUnhandled => .unhandled,
        error.EffectHandlerFailed => .handler_failed,
        error.EffectLimitExceeded, error.TraceLimitExceeded => .limit,
        else => .invalid_request,
    } };
    if (operation) |op| {
        const length = @min(op.name.len, event.actual_operation.len);
        @memcpy(event.actual_operation[0..length], op.name[0..length]);
        event.actual_operation_len = @intCast(length);
        event.actual_version = op.version;
    }
    detail.* = .{ .kind = .effect, .origin = .broker, .effect_detail = event };
}

fn noteContractFailure(destination: ?*Turn.Diagnostic, index: usize, operation: effect.Operation, mismatch: effect.schema.Mismatch) void {
    const detail = destination orelse return;
    var event: effect.Diagnostic = .{ .reason = .contract, .record_index = index, .actual_version = operation.version, .contract_detail = mismatch };
    const length = @min(operation.name.len, event.actual_operation.len);
    @memcpy(event.actual_operation[0..length], operation.name[0..length]);
    event.actual_operation_len = @intCast(length);
    detail.* = .{ .kind = .effect, .origin = .broker, .effect_detail = event };
    const message = "effect data does not match its operation contract";
    @memcpy(detail.message[0..message.len], message);
    detail.message_len = message.len;
}

fn noteJournalMismatch(destination: ?*Turn.Diagnostic, index: usize, expected: @import("effect_trace.zig").Record, actual: @import("effect_trace.zig").Record) void {
    const detail = destination orelse return;
    const reason: effect.Diagnostic.Reason = if (!std.mem.eql(u8, expected.name, actual.name)) .operation else if (expected.version != actual.version) .version else if (!std.mem.eql(u8, expected.arguments, actual.arguments)) .arguments else .invalid_result;
    var event: effect.Diagnostic = .{ .reason = reason, .record_index = index, .expected_version = expected.version, .actual_version = actual.version };
    const expected_length = @min(expected.name.len, event.expected_operation.len);
    const actual_length = @min(actual.name.len, event.actual_operation.len);
    @memcpy(event.expected_operation[0..expected_length], expected.name[0..expected_length]);
    @memcpy(event.actual_operation[0..actual_length], actual.name[0..actual_length]);
    event.expected_operation_len = @intCast(expected_length);
    event.actual_operation_len = @intCast(actual_length);
    const left = if (reason == .arguments) expected.arguments else expected.result;
    const right = if (reason == .arguments) actual.arguments else actual.result;
    if (reason == .arguments or reason == .invalid_result) {
        var expected_hash: [32]u8 = undefined;
        var actual_hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(left, &expected_hash, .{});
        std.crypto.hash.sha2.Sha256.hash(right, &actual_hash, .{});
        event.expected_hash = expected_hash;
        event.actual_hash = actual_hash;
    }
    if (reason == .arguments) {
        var offset: usize = 0;
        while (offset < @min(left.len, right.len) and left[offset] == right[offset]) : (offset += 1) {}
        event.argument_byte_offset = offset;
    }
    detail.* = .{ .kind = .effect, .origin = .broker, .effect_detail = event };
}
