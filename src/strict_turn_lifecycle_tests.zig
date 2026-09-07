const std = @import("std");
const mruby = @import("mruby");
const manifest = @import("turn_manifest");
const testing = std.testing;
const Turn = mruby.strict.Turn;
const data = mruby.effect.data;
const Capsule = mruby.artifact.StateCapsule;
const View = mruby.artifact.StateCapsuleView;

const operations = .{
    .{ .name = "clock.now", .namespace = "Clock", .method = "now", .arity = 0, .authority_bits = 1 << 4, .max_result_bytes = 256 },
    .{ .name = "intent.prepare", .namespace = "Intent", .method = "prepare", .arity = 1, .authority_bits = 1 << 13, .max_result_bytes = 1024 },
    .{ .name = "output.write", .namespace = "Output", .method = "write", .arity = 1, .authority_bits = 1 << 13, .max_result_bytes = 256 },
};
const options: Turn.Options = .{ .allowed = &.{ "clock.now", "intent.prepare", "output.write" } };
const max_bytes: usize = 64 * 1024;

const Host = struct {
    begins: usize = 0,
    commits: usize = 0,
    discards: usize = 0,
    handlers: usize = 0,
    provisional: usize = 0,
    decision: enum { committed, rejected, indeterminate, throws } = .committed,
    fail_after_begin: ?*testing.FailingAllocator = null,
    mutate_at_begin: []const []u8 = &.{},

    fn cast(context: ?*anyopaque) *Host {
        return @ptrCast(@alignCast(context.?));
    }
    fn begin(context: ?*anyopaque) !void {
        const host = cast(context);
        host.begins += 1;
        if (host.fail_after_begin) |failing| failing.fail_index = failing.alloc_index;
        for (host.mutate_at_begin) |bytes| @memset(bytes, 'x');
    }
    fn commit(context: ?*anyopaque, terminal: View, receipt: []const u8) !Turn.CommitOutcome {
        const host = cast(context);
        host.commits += 1;
        // These views are already complete and do not borrow a Ruby VM.
        _ = try mruby.artifact.validateState(terminal, .{});
        const framed = try Turn.Receipt.decode(receipt, .{});
        try testing.expectEqualSlices(u8, terminal.bytes, framed.terminal.bytes);
        return switch (host.decision) {
            .committed => blk: {
                host.provisional = 0;
                break :blk .committed;
            },
            .rejected => .rejected,
            .indeterminate => .indeterminate,
            .throws => error.CommitTransportLost,
        };
    }
    fn discard(context: ?*anyopaque) void {
        const host = cast(context);
        host.discards += 1;
        host.provisional = 0;
    }
    fn clock(context: ?*anyopaque, allocator: std.mem.Allocator, _: View) !mruby.effect.DataOutcome {
        cast(context).handlers += 1;
        return .{ .returned = try data.encode(allocator, .{ .integer = 42 }, 256) };
    }
    fn intent(context: ?*anyopaque, allocator: std.mem.Allocator, _: View) !mruby.effect.DataOutcome {
        const host = cast(context);
        host.handlers += 1;
        host.provisional += 1;
        return .{ .returned = try data.encode(allocator, .{ .integer = 1 }, 256) };
    }
    fn output(context: ?*anyopaque, allocator: std.mem.Allocator, _: View) !mruby.effect.DataOutcome {
        const host = cast(context);
        host.handlers += 1;
        host.provisional += 1;
        return .{ .returned = try data.encode(allocator, .nil, 256) };
    }
    fn transaction(host: *Host) Turn.Transaction {
        return .{ .context = host, .begin = begin, .commit = commit, .discard = discard };
    }
    fn bindings(host: *Host) [3]mruby.effect.DataBinding {
        return .{
            .{ .name = "clock.now", .handler = clock, .context = host },
            .{ .name = "intent.prepare", .handler = intent, .context = host },
            .{ .name = "output.write", .handler = output, .context = host },
        };
    }
};

fn stateCapsule() !Capsule {
    return data.encode(testing.allocator, .{ .hash = &.{
        .{ .key = .{ .string = "count" }, .value = .{ .integer = 7 } },
        .{ .key = .{ .string = "last_at" }, .value = .nil },
    } }, max_bytes);
}

fn inputCapsule() !Capsule {
    return data.encode(testing.allocator, .{ .hash = &.{
        .{ .key = .{ .string = "delta" }, .value = .{ .integer = 3 } },
        .{ .key = .{ .string = "abort_after_prepare" }, .value = .{ .boolean = false } },
    } }, max_bytes);
}

fn prepare(allocator: std.mem.Allocator, host: *Host, state: View, input: View) !Turn.Prepared {
    const bindings = host.bindings();
    return Turn.prepare(allocator, manifest, "counter", operations, .{
        .receiver = "Counter",
        .state = state,
        .input = input,
    }, .{ .bindings = &bindings, .transaction = host.transaction() }, options);
}

test "turn output allocation failure discards effects staged after begin" {
    var state = try stateCapsule();
    defer state.deinit(testing.allocator);
    var input = try inputCapsule();
    defer input.deinit(testing.allocator);
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var host: Host = .{ .fail_after_begin = &failing };
    try testing.expectError(error.OutOfMemory, prepare(failing.allocator(), &host, state.view(), input.view()));
    try testing.expectEqual(@as(usize, 1), host.begins);
    try testing.expectEqual(@as(usize, 3), host.handlers);
    try testing.expectEqual(@as(usize, 1), host.discards);
    try testing.expectEqual(@as(usize, 0), host.commits);
    try testing.expectEqual(@as(usize, 0), host.provisional);
}

test "rejected commit discards once and cannot be attempted again" {
    var state = try stateCapsule();
    defer state.deinit(testing.allocator);
    var input = try inputCapsule();
    defer input.deinit(testing.allocator);
    var host: Host = .{ .decision = .rejected };
    {
        var prepared = try prepare(testing.allocator, &host, state.view(), input.view());
        defer prepared.deinit();
        try testing.expectEqual(@as(usize, 2), host.provisional);
        try testing.expectError(error.CommitRejected, prepared.commit());
        try testing.expectError(error.TurnAlreadyResolved, prepared.commit());
        prepared.discard();
        try testing.expectEqual(@as(usize, 1), host.commits);
        try testing.expectEqual(@as(usize, 1), host.discards);
        try testing.expectEqual(@as(usize, 0), host.provisional);
        _ = try Turn.Receipt.decode(prepared.receipt(), .{});
    }
    try testing.expectEqual(@as(usize, 1), host.discards);
}

test "uncertain and thrown commits never auto-discard or retry" {
    var state = try stateCapsule();
    defer state.deinit(testing.allocator);
    var input = try inputCapsule();
    defer input.deinit(testing.allocator);
    for ([_]@FieldType(Host, "decision"){ .indeterminate, .throws }) |decision| {
        var host: Host = .{ .decision = decision };
        {
            var prepared = try prepare(testing.allocator, &host, state.view(), input.view());
            defer prepared.deinit();
            try testing.expectError(error.CommitIndeterminate, prepared.commit());
            try testing.expectError(error.TurnAlreadyResolved, prepared.commit());
            prepared.discard();
            try testing.expectEqual(@as(usize, 1), host.commits);
            try testing.expectEqual(@as(usize, 0), host.discards);
            // Provisional resources remain host-owned pending reconciliation.
            try testing.expectEqual(@as(usize, 2), host.provisional);
            _ = try Turn.Receipt.decode(prepared.receipt(), .{});
        }
        try testing.expectEqual(@as(usize, 0), host.discards);
        try testing.expectEqual(@as(usize, 1), host.commits);
    }
}

test "malformed input is rejected before transaction begin" {
    var state = try stateCapsule();
    defer state.deinit(testing.allocator);
    var input = try inputCapsule();
    defer input.deinit(testing.allocator);
    input.encoded[input.encoded.len - 1] ^= 1;
    var host: Host = .{};
    try testing.expectError(error.ChecksumMismatch, prepare(testing.allocator, &host, state.view(), input.view()));
    try testing.expectEqual(@as(usize, 0), host.begins);
    try testing.expectEqual(@as(usize, 0), host.handlers);
    try testing.expectEqual(@as(usize, 0), host.discards);
    try testing.expectEqual(@as(usize, 0), host.commits);
}

test "begin cannot change caller bytes already snapshotted for execution and identity" {
    const a = testing.allocator;
    var state = try stateCapsule();
    defer state.deinit(a);
    var input = try inputCapsule();
    defer input.deinit(a);
    var saved_state = try data.clone(a, state.view(), max_bytes);
    defer saved_state.deinit(a);
    var saved_input = try data.clone(a, input.view(), max_bytes);
    defer saved_input.deinit(a);
    var receiver = "Counter".*;
    var method = "apply".*;
    var host: Host = .{ .mutate_at_begin = &.{ state.encoded, input.encoded, &receiver, &method } };
    const bindings = host.bindings();
    var prepared = try Turn.prepare(a, manifest, "counter", operations, .{
        .receiver = &receiver,
        .method = &method,
        .state = state.view(),
        .input = input.view(),
    }, .{ .bindings = &bindings, .transaction = host.transaction() }, options);
    defer prepared.deinit();
    try testing.expectEqualStrings("xxxxxxx", &receiver);
    try testing.expectEqualStrings("xxxxx", &method);
    try testing.expectEqual(@as(usize, 3), host.handlers);
    var replay = try Turn.replay(a, manifest, "counter", operations, .{
        .receiver = "Counter",
        .state = saved_state.view(),
        .input = saved_input.view(),
    }, prepared.receipt(), options);
    defer replay.deinit();
    try testing.expectEqualSlices(u8, prepared.terminal().bytes, replay.terminal().bytes);
    try testing.expectEqual(@as(usize, 1), host.begins);
    try testing.expectEqual(@as(usize, 3), host.handlers);
}

test "terminal replay detects changed cross-root aliases with equal independent values" {
    const a = testing.allocator;
    var state = try data.encode(a, .{ .array = &.{.{ .integer = 7 }} }, max_bytes);
    defer state.deinit(a);
    var input = try data.encode(a, .nil, max_bytes);
    defer input.deinit(a);
    const request: Turn.Request = .{ .receiver = "Counter", .method = "aliases", .state = state.view(), .input = input.view() };
    var prepared = try Turn.prepare(a, manifest, "counter", operations, request, .{}, options);
    defer prepared.deinit();
    var original = try data.Document.decode(a, prepared.terminal(), max_bytes);
    defer original.deinit();
    try testing.expectEqual((try original.root().at(0)).nodeId(), (try original.root().at(1)).nodeId());

    var replacement = try data.encode(a, .{ .array = &.{
        .{ .array = &.{.{ .integer = 7 }} },
        .{ .array = &.{.{ .integer = 7 }} },
    } }, max_bytes);
    defer replacement.deinit(a);
    var changed = try data.Document.decode(a, replacement.view(), max_bytes);
    defer changed.deinit();
    try testing.expect((try changed.root().at(0)).nodeId() != (try changed.root().at(1)).nodeId());
    for (0..2) |index| {
        var original_root = try data.encodeRef(a, try original.root().at(index), max_bytes);
        defer original_root.deinit(a);
        var changed_root = try data.encodeRef(a, try changed.root().at(index), max_bytes);
        defer changed_root.deinit(a);
        try testing.expectEqualSlices(u8, original_root.encoded, changed_root.encoded);
    }
    const view = try Turn.Receipt.decode(prepared.receipt(), .{});
    const substituted = try Turn.Receipt.encode(a, view.trace, replacement.view(), .{});
    defer a.free(substituted);
    var diagnostic: Turn.Diagnostic = .{};
    var replay_options = options;
    replay_options.diagnostic = &diagnostic;
    try testing.expectError(error.TerminalMismatch, Turn.replay(a, manifest, "counter", operations, request, substituted, replay_options));
    try testing.expectEqual(.terminal, diagnostic.kind);
    try testing.expect(diagnostic.expected_hash != null and diagnostic.actual_hash != null);
}
