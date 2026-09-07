//! Brokered strict effects: application Ruby runs in an OS-confined child;
//! only this parent process owns adapters and the transaction.
//!   zig build run-effects-worker -Deffects-strict=true
//! Installed usage: effects-worker /absolute/path/to/effects-worker-child
const std = @import("std");
const mruby = @import("mruby");
const manifest = @import("worker_manifest");
pub const contract = @import("worker_contract");
const Worker = mruby.strict.Worker;
const Turn = mruby.strict.Turn;
const data = mruby.effect.data;
const View = mruby.artifact.StateCapsuleView;
const testing = std.testing;
const turn_contract = Worker.Runtime.contractFromModule(contract) catch unreachable;
const changed_turn_contract = Turn.Contract.from(.{
    .state = contract.turn_contract.state,
    .input = contract.turn_contract.input,
    .result = .{ .integer = .{ .min = 0 } },
}) catch unreachable;
extern "c" fn getpid() i32;
extern "c" fn usleep(microseconds: u32) c_int;

const Intent = struct { count: i64, observed_at: i64 };
const Host = struct {
    allocator: std.mem.Allocator,
    callbacks: usize = 0,
    callback_pids: [8]i32 = @splat(0),
    begins: usize = 0,
    commits: usize = 0,
    discards: usize = 0,
    active: bool = false,
    committed_count: i64 = 7,
    pending: ?Intent = null,
    committed_intent: ?Intent = null,
    delay_begin_us: u32 = 0,
    delay_intent_us: u32 = 0,
    fail_after_intent: ?*testing.FailingAllocator = null,
    fail_intent: bool = false,
    wrong_clock_result: bool = false,
    reject_clock: bool = false,
    malformed_clock_rejection: bool = false,

    fn from(context: ?*anyopaque) *Host {
        return @ptrCast(@alignCast(context.?));
    }
    fn observed(host: *Host) !void {
        if (!host.active) return error.NoHostTransaction;
        if (host.callbacks >= host.callback_pids.len) return error.TooManyCallbacks;
        host.callback_pids[host.callbacks] = getpid();
        host.callbacks += 1;
    }
    fn clockNow(context: ?*anyopaque, allocator: std.mem.Allocator, _: View) !mruby.effect.DataOutcome {
        const host = from(context);
        try host.observed();
        if (host.malformed_clock_rejection) return .{ .rejected = try data.encode(allocator, .{ .array = &.{ .{ .integer = 1 }, .{ .integer = 2 } } }, 256) };
        if (host.reject_clock) return .{ .rejected = try data.encode(allocator, .{ .array = &.{ .{ .string = "Unavailable" }, .{ .string = "clock unavailable" } } }, 256) };
        if (host.wrong_clock_result) return .{ .returned = try data.encode(allocator, .{ .string = "not an integer" }, 256) };
        return .{ .returned = try data.encode(allocator, .{ .integer = 1_700_000_000 }, 256) };
    }
    fn prepareIntent(context: ?*anyopaque, allocator: std.mem.Allocator, arguments: View) !mruby.effect.DataOutcome {
        const host = from(context);
        try host.observed();
        if (host.fail_intent) return error.IntentStorageUnavailable;
        var document = try data.Document.decode(allocator, arguments, contract.max_bytes);
        defer document.deinit();
        const payload = try document.root().at(0);
        const count = try (try payload.at(0)).asInteger();
        const observed_at = try (try payload.at(1)).asInteger();
        if (host.pending != null) return error.DuplicateIntent;
        host.pending = .{ .count = count, .observed_at = observed_at };
        const response = try data.encode(allocator, .nil, 256);
        if (host.delay_intent_us != 0) _ = usleep(host.delay_intent_us);
        if (host.fail_after_intent) |failing| failing.fail_index = failing.alloc_index;
        return .{ .returned = response };
    }
    fn begin(context: ?*anyopaque) !void {
        const host = from(context);
        if (host.active) return error.HostTransactionAlreadyActive;
        host.active = true;
        host.begins += 1;
        if (host.delay_begin_us != 0) _ = usleep(host.delay_begin_us);
    }
    fn commit(context: ?*anyopaque, terminal: View, _: []const u8) !Turn.CommitOutcome {
        const host = from(context);
        if (!host.active) return error.NoHostTransaction;
        var document = try data.Document.decode(host.allocator, terminal, contract.max_bytes);
        defer document.deinit();
        const next_state = try document.root().at(1);
        const count = try ((try next_state.get("count")) orelse return error.MissingCount).asInteger();
        // The tiny example adopts its complete single-counter state and intent
        // together in memory. No network delivery or durable commit occurs.
        host.committed_count = count;
        host.committed_intent = host.pending;
        host.pending = null;
        host.active = false;
        host.commits += 1;
        return .committed;
    }
    fn discard(context: ?*anyopaque) void {
        const host = from(context);
        std.debug.assert(host.active);
        host.pending = null;
        host.active = false;
        host.discards += 1;
    }
    fn bindings(host: *Host) [2]mruby.effect.DataBinding {
        return .{
            .{ .name = "clock.now", .handler = clockNow, .context = host },
            .{ .name = "outbox.prepare", .handler = prepareIntent, .context = host },
        };
    }
    fn transaction(host: *Host) Turn.Transaction {
        return .{ .context = host, .begin = begin, .commit = commit, .discard = discard };
    }
};

fn options(observation: ?*Worker.Observation) Worker.Options {
    var identity: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(contract.bootstrap_contract, &identity, .{});
    return .{ .turn = .{ .allowed = contract.grants, .bootstrap_identity = identity, .contract = turn_contract }, .observation = observation };
}

fn startingState(allocator: std.mem.Allocator) !mruby.artifact.StateCapsule {
    return data.encode(allocator, .{ .hash = &.{
        .{ .key = .{ .string = "count" }, .value = .{ .integer = 7 } },
    } }, contract.max_bytes);
}
fn inputCapsule(allocator: std.mem.Allocator, mode: []const u8) !mruby.artifact.StateCapsule {
    return data.encode(allocator, .{ .hash = &.{
        .{ .key = .{ .string = "delta" }, .value = .{ .integer = 3 } },
        .{ .key = .{ .string = "mode" }, .value = .{ .string = mode } },
    } }, contract.max_bytes);
}
fn request(state: View, input: View) Turn.Request {
    return .{ .receiver = "WorkerCounter", .state = state, .input = input };
}

pub fn verifyRecordReplay(allocator: std.mem.Allocator, executable: []const u8) !void {
    var state = try startingState(allocator);
    defer state.deinit(allocator);
    var input = try inputCapsule(allocator, "ok");
    defer input.deinit(allocator);
    var host: Host = .{ .allocator = allocator };
    const bindings = host.bindings();
    var observation: Worker.Observation = .{};
    var prepared = try Worker.prepare(allocator, executable, manifest, "app", contract.operations, request(state.view(), input.view()), .{
        .bindings = &bindings,
        .transaction = host.transaction(),
    }, options(&observation));
    defer prepared.deinit();
    try testing.expectEqual(@as(usize, 2), host.callbacks);
    try testing.expectEqual(@as(usize, 1), host.begins);
    try testing.expectEqual(@as(i64, 7), host.committed_count);
    try testing.expect(host.active and host.pending != null);
    const parent_pid = getpid();
    try testing.expect(observation.execution_pid != null and observation.verification_pid != null);
    try testing.expect(observation.execution_pid.? != parent_pid);
    try testing.expect(observation.verification_pid.? != parent_pid);
    for (host.callback_pids[0..host.callbacks]) |pid| try testing.expectEqual(parent_pid, pid);
    try prepared.commit();
    try testing.expectEqual(@as(i64, 10), host.committed_count);
    try testing.expectEqualDeep(Intent{ .count = 10, .observed_at = 1_700_000_000 }, host.committed_intent.?);
    var replay_observation: Worker.Observation = .{};
    var replay = try Worker.replay(allocator, executable, manifest, "app", contract.operations, request(state.view(), input.view()), prepared.receipt(), options(&replay_observation));
    defer replay.deinit();
    try testing.expectEqualSlices(u8, prepared.terminal().bytes, replay.terminal().bytes);
    try testing.expectEqual(@as(usize, 2), host.callbacks);
    try testing.expectEqual(@as(usize, 1), host.commits);
    try testing.expectEqual(@as(usize, 0), host.discards);
}

pub const FailureCase = struct {
    verification_started: ?bool = null,
    mode: []const u8 = "ok",
    expected: anyerror,
    callbacks: usize = 0,
    deadline: bool = false,
    wall_time_ns: ?u64 = null,
    delay_begin_us: u32 = 0,
    delay_intent_us: u32 = 0,
    max_records: ?usize = null,
    allowed: []const []const u8 = contract.grants,
    diagnostic: ?*Turn.Diagnostic = null,
    fail_intent: bool = false,
    omit_intent_binding: bool = false,
    wrong_clock_result: bool = false,
    reject_clock: bool = false,
    malformed_clock_rejection: bool = false,
};

pub fn verifyFailure(allocator: std.mem.Allocator, executable: []const u8, case: FailureCase) !void {
    var state = try startingState(allocator);
    defer state.deinit(allocator);
    var input = try inputCapsule(allocator, case.mode);
    defer input.deinit(allocator);
    var host: Host = .{
        .allocator = allocator,
        .delay_begin_us = case.delay_begin_us,
        .delay_intent_us = case.delay_intent_us,
        .fail_intent = case.fail_intent,
        .wrong_clock_result = case.wrong_clock_result,
        .reject_clock = case.reject_clock,
        .malformed_clock_rejection = case.malformed_clock_rejection,
    };
    const bindings = host.bindings();
    var observation: Worker.Observation = .{};
    var config = options(&observation);
    config.turn.allowed = case.allowed;
    config.turn.diagnostic = case.diagnostic;
    if (case.deadline) {
        config.process.wall_time_ns = 500 * std.time.ns_per_ms;
        config.turn.policy.limits.gas = .{ .per_execution = 1_000_000_000_000 };
    }
    if (case.wall_time_ns) |n| config.process.wall_time_ns = n;
    if (case.max_records) |n| config.turn.effect_limits.max_records = n;
    try testing.expectError(case.expected, Worker.prepare(allocator, executable, manifest, "app", contract.operations, request(state.view(), input.view()), .{
        .bindings = if (case.omit_intent_binding) bindings[0..1] else &bindings,
        .transaction = host.transaction(),
    }, config));
    try testing.expectEqual(case.callbacks, host.callbacks);
    try testing.expectEqual(@as(usize, 1), host.begins);
    try testing.expectEqual(@as(usize, 1), host.discards);
    try testing.expectEqual(@as(usize, 0), host.commits);
    try testing.expectEqual(@as(i64, 7), host.committed_count);
    try testing.expect(!host.active and host.pending == null and host.committed_intent == null);
    if (case.verification_started) |expected| try testing.expectEqual(expected, observation.verification_pid != null);
    try expectReaped(observation.execution_pid.?);
}

fn expectReaped(pid: i32) !void {
    var status: c_int = 0;
    const rc = std.posix.system.waitpid(pid, &status, std.posix.W.NOHANG);
    try testing.expectEqual(@as(i32, -1), rc);
    try testing.expectEqual(std.posix.E.CHILD, std.posix.errno(rc));
}

pub fn verifyAllocationFailure(allocator: std.mem.Allocator, executable: []const u8) !void {
    var state = try startingState(allocator);
    defer state.deinit(allocator);
    var input = try inputCapsule(allocator, "ok");
    defer input.deinit(allocator);
    var failing = testing.FailingAllocator.init(allocator, .{});
    var host: Host = .{ .allocator = allocator, .fail_after_intent = &failing };
    const bindings = host.bindings();
    var observation: Worker.Observation = .{};
    try testing.expectError(error.OutOfMemory, Worker.prepare(failing.allocator(), executable, manifest, "app", contract.operations, request(state.view(), input.view()), .{
        .bindings = &bindings,
        .transaction = host.transaction(),
    }, options(&observation)));
    try testing.expect(failing.has_induced_failure);
    try testing.expectEqual(@as(usize, 2), host.callbacks);
    try testing.expectEqual(@as(usize, 1), host.discards);
    try testing.expectEqual(@as(usize, 0), host.commits);
    try testing.expect(!host.active and host.pending == null);
    try expectReaped(observation.execution_pid.?);
}

pub fn verifyCrossReplay(allocator: std.mem.Allocator, executable: []const u8) !void {
    var state = try startingState(allocator);
    defer state.deinit(allocator);
    var input = try inputCapsule(allocator, "ok");
    defer input.deinit(allocator);
    var config = options(null);
    config.turn.allowed = &.{ "outbox.prepare", "clock.now" };
    var remote_host: Host = .{ .allocator = allocator };
    const remote_bindings = remote_host.bindings();
    var remote = try Worker.prepare(allocator, executable, manifest, "app", contract.operations, request(state.view(), input.view()), .{
        .bindings = &remote_bindings,
        .transaction = remote_host.transaction(),
    }, config);
    defer remote.deinit();
    var local_replay = try Turn.replay(allocator, manifest, "app", contract.operations, request(state.view(), input.view()), remote.receipt(), config.turn);
    defer local_replay.deinit();
    try testing.expectEqualSlices(u8, remote.terminal().bytes, local_replay.terminal().bytes);
    var local_host: Host = .{ .allocator = allocator };
    const local_bindings = local_host.bindings();
    var local = try Turn.prepare(allocator, manifest, "app", contract.operations, request(state.view(), input.view()), .{
        .bindings = &local_bindings,
        .transaction = local_host.transaction(),
    }, config.turn);
    defer local.deinit();
    var remote_replay = try Worker.replay(allocator, executable, manifest, "app", contract.operations, request(state.view(), input.view()), local.receipt(), config);
    defer remote_replay.deinit();
    try testing.expectEqualSlices(u8, local.terminal().bytes, remote_replay.terminal().bytes);
    try testing.expectEqual(@as(usize, 2), remote_host.callbacks);
    try testing.expectEqual(@as(usize, 2), local_host.callbacks);
}

/// Schema-invalid observations retain valid framing and the original identity.
/// A missing executable proves preflight rejects them before starting Ruby.
pub fn verifyContractReceiptAdmission(allocator: std.mem.Allocator) !void {
    var state = try startingState(allocator);
    defer state.deinit(allocator);
    var input = try inputCapsule(allocator, "ok");
    defer input.deinit(allocator);
    var host: Host = .{ .allocator = allocator };
    const bindings = host.bindings();
    var original = try Turn.prepare(allocator, manifest, "app", contract.operations, request(state.view(), input.view()), .{ .bindings = &bindings, .transaction = host.transaction() }, options(null).turn);
    defer original.deinit();
    const receipt = try Turn.Receipt.decode(original.receipt(), .{});
    var trace = try mruby.effect.Trace.decode(allocator, receipt.trace, .{});
    defer trace.deinit();
    for ([_]mruby.effect.schema.Side{ .arguments, .result, .rejection, .rejection }, 0..) |side, case_index| {
        const malformed_rejection = case_index == 3;
        var replacement = try data.encode(allocator, switch (side) {
            .arguments => .{ .array = &.{.{ .array = &.{ .{ .integer = 10 }, .{ .string = "invalid observation" } } }} },
            .result => .{ .string = "invalid clock result" },
            .rejection => if (malformed_rejection)
                .{ .array = &.{ .{ .integer = 1 }, .{ .integer = 2 } } }
            else
                .{ .array = &.{ .{ .string = "Unavailable" }, .{ .string = "unexpected clock rejection" } } },
        }, 4096);
        defer replacement.deinit(allocator);
        var altered = mruby.effect.Trace.init(allocator, trace.identity, .{});
        defer altered.deinit();
        const changed_index: usize = if (side == .arguments) 1 else 0;
        for (0..trace.len()) |index| {
            const record = trace.get(index).?;
            const arguments = if (index == changed_index and side == .arguments) replacement.encoded else record.arguments;
            const result = if (index == changed_index and side != .arguments) replacement.encoded else record.result;
            const outcome = if (index == changed_index and side == .rejection) .rejected else record.outcome;
            try altered.reserve(record.name, record.version, arguments, result.len);
            try altered.commitOutcome(outcome, result);
        }
        try altered.finish();
        const trace_bytes = try altered.encode(allocator);
        defer allocator.free(trace_bytes);
        const altered_receipt = try Turn.Receipt.encode(allocator, trace_bytes, receipt.terminal, .{});
        defer allocator.free(altered_receipt);
        var diagnostic: Turn.Diagnostic = .{};
        var observation: Worker.Observation = .{};
        var config = options(&observation);
        config.turn.diagnostic = &diagnostic;
        try testing.expectError(error.EffectContractViolation, Worker.replay(allocator, "/missing/contract-preflight-worker", manifest, "app", contract.operations, request(state.view(), input.view()), altered_receipt, config));
        try testing.expectEqualDeep(Worker.Observation{}, observation);
        try testing.expectEqual(.broker, diagnostic.origin);
        try testing.expectEqual(.setup, diagnostic.phase);
        try testing.expectEqual(.contract, diagnostic.effect_detail.?.reason);
        try testing.expectEqual(changed_index, diagnostic.effect_detail.?.record_index);
        try testing.expectEqual(side, diagnostic.effect_detail.?.contract_detail.?.side);
        if (malformed_rejection) {
            const mismatch = diagnostic.effect_detail.?.contract_detail.?;
            try testing.expectEqual(.rejection_forbidden, mismatch.reason);
            try testing.expectEqualStrings("$", mismatch.pathText());
        }
    }
    try testing.expectEqual(@as(usize, 2), host.callbacks);
    try testing.expectEqual(@as(usize, 1), host.begins);
    try testing.expectEqual(@as(usize, 0), host.commits);
}

/// Both inputs must be admitted before a process or host transaction exists.
pub fn verifyTurnInputAdmission(allocator: std.mem.Allocator) !void {
    var state = try startingState(allocator);
    defer state.deinit(allocator);
    var input = try inputCapsule(allocator, "ok");
    defer input.deinit(allocator);
    for ([_]bool{ false, true }) |wrong_input| {
        var wrong = try data.encode(allocator, if (wrong_input) .{ .hash = &.{
            .{ .key = .{ .string = "delta" }, .value = .{ .string = "three" } },
            .{ .key = .{ .string = "mode" }, .value = .{ .string = "ok" } },
        } } else .{ .hash = &.{.{ .key = .{ .string = "count" }, .value = .{ .string = "seven" } }} }, 4096);
        defer wrong.deinit(allocator);
        var host: Host = .{ .allocator = allocator };
        const bindings = host.bindings();
        var observation: Worker.Observation = .{};
        var diagnostic: Turn.Diagnostic = .{};
        var config = options(&observation);
        config.turn.diagnostic = &diagnostic;
        try testing.expectError(error.TurnContractViolation, Worker.prepare(allocator, "/missing/turn-admission-worker", manifest, "app", contract.operations, request(if (wrong_input) state.view() else wrong.view(), if (wrong_input) wrong.view() else input.view()), .{
            .bindings = &bindings,
            .transaction = host.transaction(),
        }, config));
        try testing.expectEqualDeep(Worker.Observation{}, observation);
        try testing.expectEqual(@as(usize, 0), host.begins);
        try testing.expectEqual(@as(usize, 0), host.callbacks);
        try testing.expectEqual(@as(usize, 0), host.discards);
        try testing.expectEqual(.broker, diagnostic.origin);
        try testing.expectEqual(.setup, diagnostic.phase);
        try testing.expectEqual(.contract, diagnostic.kind);
        const mismatch = diagnostic.contract_detail.?;
        try testing.expectEqual(@as(@TypeOf(mismatch.side), if (wrong_input) .input else .state), mismatch.side);
        try testing.expectEqualStrings(if (wrong_input) "$[\"delta\"]" else "$[\"count\"]", mismatch.detail.pathText());
        try testing.expectEqual(.integer, mismatch.detail.expected);
        try testing.expectEqual(.string, mismatch.detail.actual.?);
    }
}

/// Valid framing and an unchanged effect journal cannot admit invalid terminal
/// values, and changing the turn contract invalidates the old receipt identity.
pub fn verifyTurnReceiptAdmission(allocator: std.mem.Allocator, executable: []const u8) !void {
    var state = try startingState(allocator);
    defer state.deinit(allocator);
    var input = try inputCapsule(allocator, "ok");
    defer input.deinit(allocator);
    var host: Host = .{ .allocator = allocator };
    const bindings = host.bindings();
    var original = try Turn.prepare(allocator, manifest, "app", contract.operations, request(state.view(), input.view()), .{ .bindings = &bindings, .transaction = host.transaction() }, options(null).turn);
    defer original.deinit();
    const receipt = try Turn.Receipt.decode(original.receipt(), .{});
    for ([_]bool{ false, true }) |wrong_state| {
        var wrong = try data.encode(allocator, .{ .array = &.{
            if (wrong_state) .{ .integer = 10 } else .{ .string = "invalid result" },
            .{ .hash = &.{.{ .key = .{ .string = "count" }, .value = if (wrong_state) .{ .string = "invalid count" } else .{ .integer = 10 } }} },
        } }, 4096);
        defer wrong.deinit(allocator);
        const altered = try Turn.Receipt.encode(allocator, receipt.trace, wrong.view(), .{});
        defer allocator.free(altered);
        var observation: Worker.Observation = .{};
        var diagnostic: Turn.Diagnostic = .{};
        var config = options(&observation);
        config.turn.diagnostic = &diagnostic;
        try testing.expectError(error.TurnContractViolation, Worker.replay(allocator, "/missing/turn-receipt-worker", manifest, "app", contract.operations, request(state.view(), input.view()), altered, config));
        try testing.expectEqualDeep(Worker.Observation{}, observation);
        try testing.expectEqual(.broker, diagnostic.origin);
        try testing.expectEqual(.setup, diagnostic.phase);
        try testing.expectEqual(@as(@TypeOf(diagnostic.contract_detail.?.side), if (wrong_state) .next_state else .result), diagnostic.contract_detail.?.side);
        try testing.expectEqualStrings(if (wrong_state) "$[\"count\"]" else "$", diagnostic.contract_detail.?.detail.pathText());
    }
    for ([_]?*const Turn.Contract{ changed_turn_contract, null }) |replacement| {
        var observation: Worker.Observation = .{};
        var diagnostic: Turn.Diagnostic = .{};
        var config = options(&observation);
        config.turn.contract = replacement;
        config.turn.diagnostic = &diagnostic;
        try testing.expectError(error.EffectTraceIdentityMismatch, Worker.replay(allocator, "/missing/turn-identity-worker", manifest, "app", contract.operations, request(state.view(), input.view()), original.receipt(), config));
        try testing.expectEqualDeep(Worker.Observation{}, observation);
        try testing.expectEqual(.identity_input, diagnostic.effect_detail.?.reason);
    }
    var other: Host = .{ .allocator = allocator };
    const other_bindings = other.bindings();
    var config = options(null);
    config.turn.contract = changed_turn_contract;
    try testing.expectError(error.WorkerApplicationMismatch, Worker.prepare(allocator, executable, manifest, "app", contract.operations, request(state.view(), input.view()), .{ .bindings = &other_bindings, .transaction = other.transaction() }, config));
    try testing.expectEqual(@as(usize, 0), other.begins);
    try testing.expectEqual(@as(usize, 0), other.callbacks);
    try testing.expectEqual(@as(usize, 0), other.discards);
    try testing.expectEqual(@as(usize, 2), host.callbacks);
}

/// Bypass broker preflight entirely: the child must reject invalid state/input
/// before sending ready, so no parent transaction could have begun.
pub fn verifyChildTurnAdmission(allocator: std.mem.Allocator, executable: []const u8) !void {
    const protocol = Worker.Protocol;
    var valid_state = try startingState(allocator);
    defer valid_state.deinit(allocator);
    var valid_input = try inputCapsule(allocator, "ok");
    defer valid_input.deinit(allocator);
    var wrong = try data.encode(allocator, .nil, 4096);
    defer wrong.deinit(allocator);
    for ([_]bool{ false, true }) |wrong_input| {
        const state = if (wrong_input) valid_state.view() else wrong.view();
        const input = if (wrong_input) wrong.view() else valid_input.view();
        var start: protocol.Start = .{
            .application_identity = protocol.applicationIdentityWithContract(manifest, contract.operations, mruby.features.rite_compatibility_fingerprint, turn_contract),
            .bootstrap_identity = options(null).turn.bootstrap_identity,
            .operation_count = contract.operations.len,
            .grant_order_len = 2,
            .entry_len = "app".len,
            .receiver_len = "WorkerCounter".len,
            .method_len = "apply".len,
            .state_len = state.bytes.len,
            .input_len = input.bytes.len,
        };
        try start.setGrant(0);
        try start.setGrant(1);
        var child = try Worker.Process.Process.spawn(allocator, executable, .{ .wall_time_ns = 5 * std.time.ns_per_s, .max_transfer_bytes = 1024 * 1024 });
        defer child.deinit();
        try child.channel.writeAll(&try protocol.encode(.{ .start = start }));
        for ([_][]const u8{ "app", "WorkerCounter", "apply", &.{ 0, 1 }, state.bytes, input.bytes }) |part| try child.channel.writeAll(part);
        var header_bytes: [protocol.header_len]u8 = undefined;
        try child.channel.readExact(&header_bytes);
        const header = try protocol.decode(&header_bytes);
        try testing.expectEqual(.failure, std.meta.activeTag(header));
        var body: [protocol.max_error_name_len + protocol.max_diagnostic_len]u8 = undefined;
        const length = try header.bodyLen();
        try child.channel.readExact(body[0..length]);
        try testing.expectEqualStrings("TurnContractViolation", body[0..header.failure.error_name_len]);
        const diagnostic = try Worker.DiagnosticCodec.decode(body[header.failure.error_name_len..length]);
        try testing.expectEqual(.worker, diagnostic.origin);
        try testing.expectEqual(.setup, diagnostic.phase);
        try testing.expectEqual(@as(@TypeOf(diagnostic.contract_detail.?.side), if (wrong_input) .input else .state), diagnostic.contract_detail.?.side);
        try testing.expectEqualStrings("$", diagnostic.contract_detail.?.detail.pathText());
        try child.wait();
    }
}

pub fn main(init: std.process.Init) !void {
    var arguments = init.minimal.args.iterate();
    _ = arguments.next();
    const executable = arguments.next() orelse return error.MissingWorkerExecutable;
    try verifyRecordReplay(init.gpa, executable);
    std.debug.print("strict worker: child executed and replayed counter 7 -> 10; both adapters ran in the parent process\n", .{});
    std.debug.print("strict worker: commit retained the state and in-memory intent; replay invoked no adapters\n", .{});
}

/// Alter valid receipt observations/terminal bytes while retaining well-formed
/// framing. The real replay child supplies mismatch details, with no adapters.
pub fn verifyReplayDiagnostics(allocator: std.mem.Allocator, executable: []const u8) !void {
    var state = try startingState(allocator);
    defer state.deinit(allocator);
    var input = try inputCapsule(allocator, "ok");
    defer input.deinit(allocator);
    var host: Host = .{ .allocator = allocator };
    const bindings = host.bindings();
    var original = try Turn.prepare(allocator, manifest, "app", contract.operations, request(state.view(), input.view()), .{ .bindings = &bindings, .transaction = host.transaction() }, options(null).turn);
    defer original.deinit();
    const receipt = try Turn.Receipt.decode(original.receipt(), .{});
    var trace = try mruby.effect.Trace.decode(allocator, receipt.trace, .{});
    defer trace.deinit();
    var changed_arguments = try data.encode(allocator, .{ .array = &.{.{ .array = &.{ .{ .integer = 11 }, .{ .integer = 1_700_000_000 } } }} }, 4096);
    defer changed_arguments.deinit(allocator);
    var changed = mruby.effect.Trace.init(allocator, trace.identity, .{});
    defer changed.deinit();
    for (0..trace.len()) |index| {
        const record = trace.get(index).?;
        try changed.reserve(record.name, record.version, if (index == 1) changed_arguments.encoded else record.arguments, record.result.len);
        try changed.commitOutcome(record.outcome, record.result);
    }
    try changed.finish();
    const changed_trace = try changed.encode(allocator);
    defer allocator.free(changed_trace);
    const bad_arguments = try Turn.Receipt.encode(allocator, changed_trace, receipt.terminal, .{});
    defer allocator.free(bad_arguments);
    var diagnostic: Turn.Diagnostic = .{};
    var config = options(null);
    config.turn.diagnostic = &diagnostic;
    try testing.expectError(error.EffectReplayMismatch, Worker.replay(allocator, executable, manifest, "app", contract.operations, request(state.view(), input.view()), bad_arguments, config));
    try testing.expectEqual(.worker, diagnostic.origin);
    try testing.expectEqual(.replay, diagnostic.phase);
    try testing.expectEqual(.effect, diagnostic.kind);
    try testing.expectEqual(.arguments, diagnostic.effect_detail.?.reason);
    try testing.expectEqual(@as(usize, 1), diagnostic.effect_detail.?.record_index);
    try testing.expectEqualStrings("outbox.prepare", diagnostic.effect_detail.?.actualOperation());
    try testing.expect(diagnostic.effect_detail.?.expected_hash != null and diagnostic.effect_detail.?.actual_hash != null);
    try testing.expect(diagnostic.effect_detail.?.argument_byte_offset != null);

    var changed_terminal = try data.encode(allocator, .{ .array = &.{ .{ .integer = 999 }, .{ .hash = &.{.{ .key = .{ .string = "count" }, .value = .{ .integer = 10 } }} } } }, 4096);
    defer changed_terminal.deinit(allocator);
    const bad_terminal = try Turn.Receipt.encode(allocator, receipt.trace, changed_terminal.view(), .{});
    defer allocator.free(bad_terminal);
    try testing.expectError(error.TerminalMismatch, Worker.replay(allocator, executable, manifest, "app", contract.operations, request(state.view(), input.view()), bad_terminal, config));
    try testing.expectEqual(.worker, diagnostic.origin);
    try testing.expectEqual(.replay, diagnostic.phase);
    try testing.expectEqual(.terminal, diagnostic.kind);
    try testing.expect(diagnostic.expected_hash != null and diagnostic.actual_hash != null and diagnostic.byte_offset != null);
    try testing.expect(diagnostic.effect_detail == null);

    trace.identity.input[0] ^= 1;
    const identity_trace = try trace.encode(allocator);
    defer allocator.free(identity_trace);
    const bad_identity = try Turn.Receipt.encode(allocator, identity_trace, receipt.terminal, .{});
    defer allocator.free(bad_identity);
    try testing.expectError(error.EffectTraceIdentityMismatch, Worker.replay(allocator, executable, manifest, "app", contract.operations, request(state.view(), input.view()), bad_identity, config));
    try testing.expectEqual(.broker, diagnostic.origin);
    try testing.expectEqual(.setup, diagnostic.phase);
    try testing.expectEqual(.identity_input, diagnostic.effect_detail.?.reason);

    var valid = try Worker.replay(allocator, executable, manifest, "app", contract.operations, request(state.view(), input.view()), original.receipt(), config);
    defer valid.deinit();
    try testing.expectEqualDeep(Turn.Diagnostic{}, diagnostic);
    try testing.expectEqual(@as(usize, 2), host.callbacks);
}
