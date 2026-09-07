//! Child half of a strict turn session. The application and operation catalogue
//! are compiled into this executable; all adapters are private-channel stubs.
const std = @import("std");
const Turn = @import("strict_turn.zig");
const effect = @import("effect.zig");
const artifact = @import("artifact.zig");
const features = @import("features.zig");
const alloc = @import("alloc.zig");
const protocol = @import("effect_worker_protocol.zig");
const process = @import("effect_worker_process.zig");
const diagnostic_codec = @import("effect_worker_diagnostic.zig");

/// Resolve the optional pure declaration shared by a worker and its broker.
pub fn contractFromModule(comptime module: type) error{InvalidTurnContract}!?*const Turn.Contract {
    if (!@hasDecl(module, "turn_contract")) return null;
    const value = module.turn_contract;
    if (@TypeOf(value) == @TypeOf(null)) return null;
    return switch (@typeInfo(@TypeOf(value))) {
        .optional => if (value) |present| try Turn.Contract.from(present) else null,
        else => try Turn.Contract.from(value),
    };
}

/// Serve exactly one process-local turn on the inherited private descriptor.
/// The caller exits with the returned status; no application bytes or VM are
/// created until the fixed startup header has been bounded and confinement set.
pub fn serve(init: std.process.Init, comptime manifest: type, comptime operations: anytype) !u8 {
    return serveWithContract(init, manifest, operations, null);
}

pub fn serveWithContract(init: std.process.Init, comptime manifest: type, comptime operations: anytype, comptime contract: ?*const Turn.Contract) !u8 {
    const stable_contract = comptime if (contract) |value|
        Turn.Contract.from(value) catch @compileError("invalid application turn contract")
    else
        null;
    comptime {
        _ = alloc.mrb_basic_alloc_func_pub;
    }
    if (comptime !features.effects_strict) return error.StrictProfileRequired;
    var channel = try process.Channel.child(protocol.max_process_wall_ns, protocol.max_session_bytes);
    var session: Session = .{ .channel = &channel };
    run(init.gpa, manifest, operations, stable_contract, &session) catch |err| {
        const name = @errorName(err);
        if (name.len > protocol.max_error_name_len) return 1;
        if (session.diagnostic.kind == .none) session.diagnostic.kind = .failure;
        session.diagnostic.origin = .worker;
        if (session.diagnostic.phase == .none) session.diagnostic.phase = session.phase;
        @memcpy(session.diagnostic.error_name[0..name.len], name);
        session.diagnostic.error_name_len = @intCast(name.len);
        const encoded = diagnostic_codec.encode(session.diagnostic) catch return 1;
        session.send(.{ .failure = .{ .sequence = session.sequence, .error_name_len = name.len, .diagnostic_len = encoded.len } }, &.{ name, encoded.view() }) catch return 1;
    };
    return 0;
}

fn run(allocator: std.mem.Allocator, comptime manifest: type, comptime descriptors: anytype, comptime contract: ?*const Turn.Contract, session: *Session) !void {
    const start = switch (try session.receive()) {
        .start => |start| start,
        else => return error.UnexpectedWorkerOutput,
    };
    try session.channel.configure(start.process.wall_time_ns, start.max_transfer_bytes);
    const application_identity = protocol.applicationIdentityWithContract(manifest, descriptors, features.rite_compatibility_fingerprint, contract);
    if (!std.mem.eql(u8, &application_identity, &start.application_identity) or start.operation_count != descriptors.len)
        return error.WorkerApplicationMismatch;
    const catalogue = try effect.describeCatalogue(descriptors);
    try process.confine(start.process.cpu_seconds, switch (start.process.address_space) {
        .unbounded => 0,
        .bytes => |bytes| @intCast(bytes),
    });
    const body_bytes = try allocator.alloc(u8, try (protocol.Header{ .start = start }).bodyLen());
    defer allocator.free(body_bytes);
    try session.channel.readExact(body_bytes);
    const body = try protocol.splitStartBody(start, body_bytes);
    const allowed = try allocator.alloc([]const u8, body.grant_order.len);
    defer allocator.free(allowed);
    for (body.grant_order, allowed) |index, *name| name.* = catalogue[index].name;
    session.start = start;
    session.operations = &catalogue;
    session.application_identity = application_identity;
    var options = turnOptions(start, allowed);
    options.contract = contract;
    options.diagnostic = &session.diagnostic;
    session.phase = if (start.mode == .record) .record else .replay;
    const request: Turn.Request = .{
        .receiver = body.receiver,
        .method = body.method,
        .state = .{ .bytes = body.state },
        .input = .{ .bytes = body.input },
    };
    switch (start.mode) {
        .record => {
            var bindings: [descriptors.len]effect.DataBinding = undefined;
            inline for (0..descriptors.len) |index| bindings[index] = .{
                .name = catalogue[index].name,
                .handler = Remote(index).call,
                .context = session,
            };
            var prepared = try Turn.prepare(allocator, manifest, body.entry, descriptors, request, .{
                .bindings = &bindings,
                .transaction = .{ .context = session, .begin = Session.ready, .commit = childCommit, .discard = childDiscard },
            }, options);
            defer prepared.deinit();
            try session.send(.{ .finish = .{ .sequence = session.sequence, .receipt_len = prepared.receipt().len } }, &.{prepared.receipt()});
        },
        .replay => {
            // Replay has no adapter or transaction surface. Its ready exchange
            // only confirms confinement and the compiled application identity.
            try Session.ready(session);
            var verified = try Turn.replay(allocator, manifest, body.entry, descriptors, request, body.receipt, options);
            defer verified.deinit();
            const receipt = try Turn.Receipt.decode(verified.receipt(), options.receipt_limits);
            var trace = try effect.Trace.decode(allocator, receipt.trace, options.effect_limits);
            defer trace.deinit();
            try session.send(.{ .finish = .{ .sequence = @intCast(trace.len()), .receipt_len = verified.receipt().len } }, &.{verified.receipt()});
        },
    }
}

const Session = struct {
    channel: *process.Channel,
    start: protocol.Start = undefined,
    operations: []const effect.Operation = &.{},
    application_identity: [32]u8 = @splat(0),
    sequence: u64 = 0,
    ready_sent: bool = false,
    diagnostic: Turn.Diagnostic = .{},
    phase: @FieldType(Turn.Diagnostic, "phase") = .setup,

    fn send(self: *Session, header: protocol.Header, parts: []const []const u8) !void {
        var length: usize = 0;
        for (parts) |part| length = try std.math.add(usize, length, part.len);
        if (length != try header.bodyLen()) return error.InconsistentLengths;
        const bytes = try protocol.encode(header);
        try self.channel.writeAll(&bytes);
        for (parts) |part| try self.channel.writeAll(part);
    }

    fn receive(self: *Session) !protocol.Header {
        var bytes: [protocol.header_len]u8 = undefined;
        try self.channel.readExact(&bytes);
        return protocol.decode(&bytes);
    }

    fn ready(raw: ?*anyopaque) !void {
        const self: *Session = @ptrCast(@alignCast(raw.?));
        if (self.ready_sent) return error.UnexpectedWorkerOutput;
        try self.send(.{ .ready = .{ .application_identity = self.application_identity } }, &.{});
        const ack = switch (try self.receive()) {
            .ready_ack => |ack| ack,
            .failure => |failure| return self.brokerFailure(failure),
            else => return error.UnexpectedWorkerOutput,
        };
        if (!std.mem.eql(u8, &ack.application_identity, &self.application_identity)) return error.WorkerApplicationMismatch;
        self.ready_sent = true;
    }

    fn brokerFailure(self: *Session, failure: protocol.Failure) !void {
        if (failure.sequence != self.sequence) return error.UnexpectedWorkerOutput;
        var bytes: [protocol.max_error_name_len + protocol.max_diagnostic_len]u8 = undefined;
        const length = failure.error_name_len + failure.diagnostic_len;
        try self.channel.readExact(bytes[0..length]);
        if (failure.diagnostic_len != 0) {
            self.diagnostic = try diagnostic_codec.decode(bytes[failure.error_name_len..length]);
        }
        return error.BrokerRejected;
    }

    fn perform(self: *Session, index: usize, allocator: std.mem.Allocator, arguments: artifact.StateCapsuleView) !effect.DataOutcome {
        if (!self.ready_sent or self.start.mode != .record or index >= self.operations.len)
            return error.UnexpectedWorkerOutput;
        if (!self.start.granted(index)) return error.EffectDenied;
        const operation = self.operations[index];
        if (arguments.bytes.len > self.start.effect_limits.max_request_bytes) return error.EffectLimitExceeded;
        try self.send(.{ .effect_request = .{
            .sequence = self.sequence,
            .operation_index = @intCast(index),
            .version = operation.version,
            .name_len = operation.name.len,
            .arguments_len = arguments.bytes.len,
        } }, &.{ operation.name, arguments.bytes });
        const response = switch (try self.receive()) {
            .effect_response => |response| response,
            .failure => |failure| {
                try self.brokerFailure(failure);
                unreachable;
            },
            else => return error.UnexpectedWorkerOutput,
        };
        if (response.sequence != self.sequence) return error.UnexpectedWorkerOutput;
        if (response.result_len > @min(operation.max_result_bytes, self.start.effect_limits.max_result_bytes))
            return error.EffectLimitExceeded;
        const bytes = try allocator.alloc(u8, response.result_len);
        errdefer allocator.free(bytes);
        try self.channel.readExact(bytes);
        self.sequence = try std.math.add(u64, self.sequence, 1);
        return switch (response.outcome) {
            .returned => .{ .returned = .{ .encoded = bytes } },
            .rejected => .{ .rejected = .{ .encoded = bytes } },
        };
    }
};

fn Remote(comptime index: usize) type {
    return struct {
        fn call(raw: ?*anyopaque, allocator: std.mem.Allocator, arguments: artifact.StateCapsuleView) !effect.DataOutcome {
            const session: *Session = @ptrCast(@alignCast(raw.?));
            return session.perform(index, allocator, arguments);
        }
    };
}

fn childCommit(_: ?*anyopaque, _: artifact.StateCapsuleView, _: []const u8) !Turn.CommitOutcome {
    return error.ChildCommitForbidden;
}
fn childDiscard(_: ?*anyopaque) void {}

fn turnOptions(start: protocol.Start, allowed: []const []const u8) Turn.Options {
    var result: Turn.Options = .{
        .allowed = allowed,
        .bootstrap_identity = start.bootstrap_identity,
        .adapter_state_identity = start.adapter_state_identity,
        .effect_limits = .{
            .max_records = start.effect_limits.max_records,
            .max_bytes = start.effect_limits.max_bytes,
            .max_request_bytes = start.effect_limits.max_request_bytes,
            .max_result_bytes = start.effect_limits.max_result_bytes,
        },
        .capsule_limits = capsuleLimits(start.capsule_limits),
        .receipt_limits = .{
            .max_encoded_bytes = start.receipt_limits.max_encoded_bytes,
            .max_trace_bytes = start.receipt_limits.max_trace_bytes,
            .max_terminal_bytes = start.receipt_limits.max_terminal_bytes,
        },
    };
    result.policy.limits = .{
        .gas = switch (start.policy.gas) {
            .per_isolate => |n| .{ .per_isolate = n },
            .per_execution => |n| .{ .per_execution = n },
        },
        .wall_time_ns = start.policy.wall_time_ns,
        .memory_bytes = start.policy.memory_bytes,
        .hard_memory_bytes = start.policy.hard_memory_bytes,
        .call_depth = start.policy.call_depth,
    };
    result.policy.artifacts = .{
        .limits = .{ .max_rite_bytes = start.policy.artifacts.max_rite_bytes, .capsule = capsuleLimits(start.policy.artifacts.capsule) },
        .application = if (start.policy.artifacts.application) |bytes| .{ .bytes = bytes } else null,
    };
    return result;
}

fn capsuleLimits(limits: protocol.CapsuleLimits) artifact.CapsuleLimits {
    return .{
        .max_encoded_bytes = limits.max_encoded_bytes,
        .max_nodes = limits.max_nodes,
        .max_total_edges = limits.max_total_edges,
        .max_depth = limits.max_depth,
        .max_string_bytes = limits.max_string_bytes,
        .max_symbol_bytes = limits.max_symbol_bytes,
    };
}
