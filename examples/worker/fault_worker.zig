//! Deliberately dishonest peer used only by broker process tests.
const std = @import("std");
const mruby = @import("mruby");
const protocol = mruby.strict.Worker.Protocol;
const process = mruby.strict.Worker.Process;
const mode = @import("worker_fault_config").mode;
const manifest = @import("worker_manifest");
const contract = @import("worker_contract");
const Turn = mruby.strict.Turn;
const data = mruby.effect.data;
const turn_contract = mruby.strict.Worker.Runtime.contractFromModule(contract) catch unreachable;

pub fn main(init: std.process.Init) !u8 {
    var channel = try process.Channel.child(5 * std.time.ns_per_s, 1024 * 1024);
    var header_bytes: [protocol.header_len]u8 = undefined;
    try channel.readExact(&header_bytes);
    const first = try protocol.decode(&header_bytes);
    if (first != .start) return error.ExpectedStart;
    const start = first.start;
    try process.confine(start.process.cpu_seconds, switch (start.process.address_space) {
        .unbounded => 0,
        .bytes => |n| n,
    });
    const body = try init.gpa.alloc(u8, try first.bodyLen());
    defer init.gpa.free(body);
    try channel.readExact(body);
    try channel.writeAll(&try protocol.encode(.{ .ready = .{ .application_identity = start.application_identity } }));
    try channel.readExact(&header_bytes);
    if ((try protocol.decode(&header_bytes)) != .ready_ack) return error.ExpectedReadyAck;

    if (std.mem.eql(u8, mode, "malformed_diagnostic")) {
        try channel.writeAll(&try protocol.encode(.{ .failure = .{ .sequence = 0, .error_name_len = "RubyException".len, .diagnostic_len = 3 } }));
        try channel.writeAll("RubyException");
        try channel.writeAll("bad");
        return 0;
    }
    if (std.mem.eql(u8, mode, "spoofed_diagnostic")) {
        const payload = try mruby.strict.Worker.DiagnosticCodec.encode(.{ .kind = .failure, .origin = .broker, .phase = .verification });
        try channel.writeAll(&try protocol.encode(.{ .failure = .{ .sequence = 0, .error_name_len = "RubyException".len, .diagnostic_len = payload.len } }));
        try channel.writeAll("RubyException");
        try channel.writeAll(payload.view());
        return 0;
    }

    if (isReceiptFault()) {
        var controller: Remote = .{ .channel = &channel };
        return receiptFault(init.gpa, start, try protocol.splitStartBody(start, body), &controller) catch |err| {
            const name = @errorName(err);
            try channel.writeAll(&try protocol.encode(.{ .failure = .{ .sequence = controller.sequence, .error_name_len = name.len } }));
            try channel.writeAll(name);
            return 0;
        };
    }
    if (std.mem.eql(u8, mode, "wrong_arity")) {
        var wrong = try data.encode(init.gpa, .{ .array = &.{.{ .integer = 42 }} }, 4096);
        defer wrong.deinit(init.gpa);
        try channel.writeAll(&try protocol.encode(.{ .effect_request = .{ .sequence = 0, .operation_index = 0, .version = 1, .name_len = "clock.now".len, .arguments_len = wrong.encoded.len } }));
        try channel.writeAll("clock.now");
        try channel.writeAll(wrong.encoded);
        try channel.readExact(&header_bytes);
        return error.BrokerAcceptedInvalidArity;
    }
    if (std.mem.eql(u8, mode, "schema_arguments")) {
        // Known operation, correct grant/version/sequence/outer arity, and a
        // valid capsule. Only the nested argument contract is violated.
        var wrong = try data.encode(init.gpa, .{ .array = &.{.{ .array = &.{ .{ .integer = 10 }, .{ .string = "not a clock observation" } } }} }, 4096);
        defer wrong.deinit(init.gpa);
        try channel.writeAll(&try protocol.encode(.{ .effect_request = .{ .sequence = 0, .operation_index = 1, .version = 1, .name_len = "outbox.prepare".len, .arguments_len = wrong.encoded.len } }));
        try channel.writeAll("outbox.prepare");
        try channel.writeAll(wrong.encoded);
        try channel.readExact(&header_bytes);
        return error.BrokerAcceptedInvalidContract;
    }

    const outbox = std.mem.eql(u8, mode, "denied") or std.mem.eql(u8, mode, "exit_after_effect");
    var arguments = try mruby.effect.data.encode(init.gpa, if (outbox) .{ .array = &.{.{ .array = &.{ .{ .integer = 10 }, .{ .integer = 1_700_000_000 } } }} } else .{ .array = &.{} }, 4096);
    defer arguments.deinit(init.gpa);
    const name = if (std.mem.eql(u8, mode, "unknown")) "unknown.operation" else if (outbox) "outbox.prepare" else "clock.now";
    const sequence: u64 = if (std.mem.eql(u8, mode, "reordered")) 1 else 0;
    const effect_header = try protocol.encode(.{ .effect_request = .{
        .sequence = sequence,
        .operation_index = if (outbox) 1 else 0,
        .version = 1,
        .name_len = name.len,
        .arguments_len = arguments.encoded.len,
    } });
    try channel.writeAll(&effect_header);
    try channel.writeAll(name);
    try channel.writeAll(arguments.encoded);
    if (std.mem.eql(u8, mode, "exit_after_effect") or std.mem.eql(u8, mode, "duplicate")) {
        try channel.readExact(&header_bytes);
        const response = try protocol.decode(&header_bytes);
        if (response != .effect_response) return error.ExpectedEffectResponse;
        const result = try init.gpa.alloc(u8, try response.bodyLen());
        defer init.gpa.free(result);
        try channel.readExact(result);
        if (std.mem.eql(u8, mode, "exit_after_effect")) return 71;
        // The first effect succeeded, but sequence zero cannot be reused.
        try channel.writeAll(&effect_header);
        try channel.writeAll(name);
        try channel.writeAll(arguments.encoded);
    }
    // A rejecting broker must terminate us, not dispatch another adapter.
    try channel.readExact(&header_bytes);
    return error.BrokerAcceptedInvalidFrame;
}

fn isReceiptFault() bool {
    inline for (.{ "forged_result", "dropped_record", "trailing_output", "crash_after_finish", "forged_terminal", "turn_result", "turn_state" }) |name| {
        if (std.mem.eql(u8, mode, name)) return true;
    }
    return false;
}

const Remote = struct {
    channel: *process.Channel,
    sequence: u64 = 0,

    fn invoke(self: *Remote, allocator: std.mem.Allocator, index: usize, arguments: mruby.artifact.StateCapsuleView) !mruby.effect.DataOutcome {
        const name = if (index == 0) "clock.now" else "outbox.prepare";
        try self.channel.writeAll(&try protocol.encode(.{ .effect_request = .{ .sequence = self.sequence, .operation_index = @intCast(index), .version = 1, .name_len = name.len, .arguments_len = arguments.bytes.len } }));
        try self.channel.writeAll(name);
        try self.channel.writeAll(arguments.bytes);
        var bytes: [protocol.header_len]u8 = undefined;
        try self.channel.readExact(&bytes);
        const header = try protocol.decode(&bytes);
        if (header != .effect_response) return error.ExpectedResponse;
        const result = try allocator.alloc(u8, header.effect_response.result_len);
        errdefer allocator.free(result);
        try self.channel.readExact(result);
        self.sequence += 1;
        return if (header.effect_response.outcome == .rejected) .{ .rejected = .{ .encoded = result } } else .{ .returned = .{ .encoded = result } };
    }
    fn clock(context: ?*anyopaque, allocator: std.mem.Allocator, arguments: mruby.artifact.StateCapsuleView) !mruby.effect.DataOutcome {
        const self: *Remote = @ptrCast(@alignCast(context.?));
        return self.invoke(allocator, 0, arguments);
    }
    fn outbox(context: ?*anyopaque, allocator: std.mem.Allocator, arguments: mruby.artifact.StateCapsuleView) !mruby.effect.DataOutcome {
        const self: *Remote = @ptrCast(@alignCast(context.?));
        return self.invoke(allocator, 1, arguments);
    }
    fn finish(self: *Remote, receipt: []const u8, sequence: u64) !void {
        try self.channel.writeAll(&try protocol.encode(.{ .finish = .{ .sequence = sequence, .receipt_len = receipt.len } }));
        try self.channel.writeAll(receipt);
    }
};

// Get an honest receipt through the same data seam, then tamper with only the
// property under test. Checksums remain valid: this exercises journal/replay
// admission, not merely the outer corruption check.
fn receiptFault(allocator: std.mem.Allocator, start: protocol.Start, body: protocol.StartBody, remote: *Remote) !u8 {
    const catalogue = try mruby.effect.describeCatalogue(contract.operations);
    const allowed = try allocator.alloc([]const u8, body.grant_order.len);
    defer allocator.free(allowed);
    for (body.grant_order, allowed) |index, *name| name.* = catalogue[index].name;
    const options: Turn.Options = .{ .allowed = allowed, .bootstrap_identity = start.bootstrap_identity, .adapter_state_identity = start.adapter_state_identity, .contract = turn_contract };
    const request: Turn.Request = .{ .receiver = body.receiver, .method = body.method, .state = .{ .bytes = body.state }, .input = .{ .bytes = body.input } };
    if (start.mode == .replay) {
        var verified = try Turn.replay(allocator, manifest, body.entry, contract.operations, request, body.receipt, options);
        defer verified.deinit();
        const receipt = try Turn.Receipt.decode(verified.receipt(), options.receipt_limits);
        var trace = try mruby.effect.Trace.decode(allocator, receipt.trace, options.effect_limits);
        defer trace.deinit();
        try remote.finish(verified.receipt(), trace.len());
        return 0;
    }
    const bindings = [_]mruby.effect.DataBinding{
        .{ .name = "clock.now", .handler = Remote.clock, .context = remote },
        .{ .name = "outbox.prepare", .handler = Remote.outbox, .context = remote },
    };
    var prepared = try Turn.prepare(allocator, manifest, body.entry, contract.operations, request, .{ .bindings = &bindings }, options);
    defer prepared.deinit();
    const original = try Turn.Receipt.decode(prepared.receipt(), options.receipt_limits);
    var trace = try mruby.effect.Trace.decode(allocator, original.trace, options.effect_limits);
    defer trace.deinit();
    var altered = mruby.effect.Trace.init(allocator, trace.identity, options.effect_limits);
    defer altered.deinit();
    var wrong_result = try data.encode(allocator, .{ .integer = 1_700_000_001 }, 256);
    defer wrong_result.deinit(allocator);
    for (0..trace.len()) |index| {
        if (std.mem.eql(u8, mode, "dropped_record") and index == trace.len() - 1) continue;
        const record = trace.get(index).?;
        const result = if (std.mem.eql(u8, mode, "forged_result") and index == 0) wrong_result.encoded else record.result;
        try altered.reserve(record.name, record.version, record.arguments, result.len);
        try altered.commitOutcome(record.outcome, result);
    }
    try altered.finish();
    const trace_bytes = try altered.encode(allocator);
    defer allocator.free(trace_bytes);
    const forged_terminal = std.mem.eql(u8, mode, "forged_terminal");
    const turn_result = std.mem.eql(u8, mode, "turn_result");
    const turn_state = std.mem.eql(u8, mode, "turn_state");
    var wrong_terminal = try data.encode(allocator, .{ .array = &.{
        if (turn_result) .{ .string = "invalid result" } else .{ .integer = 11 },
        .{ .hash = &.{.{ .key = .{ .string = "count" }, .value = if (turn_state) .{ .string = "invalid count" } else .{ .integer = 10 } }} },
    } }, 4096);
    defer wrong_terminal.deinit(allocator);
    const receipt_bytes = try Turn.Receipt.encode(allocator, trace_bytes, if (forged_terminal or turn_result or turn_state) wrong_terminal.view() else original.terminal, options.receipt_limits);
    defer allocator.free(receipt_bytes);
    try remote.finish(receipt_bytes, trace.len());
    if (std.mem.eql(u8, mode, "trailing_output")) try remote.channel.writeAll("x");
    return if (std.mem.eql(u8, mode, "crash_after_finish")) 71 else 0;
}
