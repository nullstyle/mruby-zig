const std = @import("std");
const mruby = @import("mruby");
const example = @import("turn_example");
const manifest = @import("turn_manifest");
const Turn = mruby.strict.Turn;
const data = mruby.effect.data;
const a = std.testing.allocator;
const View = mruby.artifact.StateCapsuleView;
const shape = Turn.Contract.from(.{
    .state = .{ .integer = .{ .min = 0, .max = 100 } },
    .input = .{ .string = .{ .max_bytes = 32 } },
    .result = .integer,
}) catch unreachable;
const Probe = struct {
    calls: usize = 0,
    begins: usize = 0,
    discards: usize = 0,
    commits: usize = 0,
    mutate_contract: ?*Turn.Contract = null,
    fn from(raw: ?*anyopaque) *Probe {
        return @ptrCast(@alignCast(raw.?));
    }
    fn handle(raw: ?*anyopaque, allocator: std.mem.Allocator, _: View) !mruby.effect.DataOutcome {
        from(raw).calls += 1;
        return .{ .returned = try data.encode(allocator, .nil, 256) };
    }
    fn begin(raw: ?*anyopaque) !void {
        const self = from(raw);
        self.begins += 1;
        if (self.mutate_contract) |contract| contract.* = (comptime try Turn.Contract.from(.{ .state = .nil, .input = .nil, .result = .nil })).*;
    }
    fn commit(raw: ?*anyopaque, _: View, _: []const u8) !Turn.CommitOutcome {
        from(raw).commits += 1;
        return .committed;
    }
    fn discard(raw: ?*anyopaque) void {
        from(raw).discards += 1;
    }
    fn transaction(self: *Probe) Turn.Transaction {
        return .{ .context = self, .begin = begin, .commit = commit, .discard = discard };
    }
};

fn prepare(allocator: std.mem.Allocator, probe: *Probe, state: View, input: View, contract: ?*const Turn.Contract, diagnostic: ?*Turn.Diagnostic, entry: []const u8) !Turn.Prepared {
    return Turn.prepare(allocator, manifest, entry, example.contract.operations, .{
        .receiver = "FreshProbe",
        .method = "contract_probe",
        .state = state,
        .input = input,
    }, .{
        .bindings = &.{.{ .name = "output.write", .handler = Probe.handle, .context = probe }},
        .transaction = probe.transaction(),
    }, .{ .allowed = example.contract.grants, .contract = contract, .diagnostic = diagnostic });
}

test "turn state and input contracts reject before program lookup and host begin" {
    var state = try data.encode(a, .{ .integer = 1 }, 256);
    defer state.deinit(a);
    var input = try data.encode(a, .{ .string = "ok" }, 256);
    defer input.deinit(a);
    var invalid = try data.encode(a, .nil, 256);
    defer invalid.deinit(a);
    for (0..2) |side| {
        var probe: Probe = .{};
        var diagnostic: Turn.Diagnostic = .{};
        try std.testing.expectError(error.TurnContractViolation, prepare(a, &probe, if (side == 0) invalid.view() else state.view(), if (side == 1) invalid.view() else input.view(), shape, &diagnostic, "entry_that_does_not_exist"));
        try std.testing.expectEqual(@as(usize, 0), probe.begins + probe.calls + probe.discards + probe.commits);
        try std.testing.expectEqual(.contract, diagnostic.kind);
        try std.testing.expectEqual(.turn, diagnostic.origin);
        try std.testing.expectEqual(.setup, diagnostic.phase);
        try std.testing.expectEqualStrings("TurnContractViolation", diagnostic.errorName());
        try std.testing.expectEqualStrings(if (side == 0) "state" else "input", @tagName(diagnostic.contract_detail.?.side));
        try std.testing.expectEqualStrings("$", diagnostic.contract_detail.?.detail.pathText());
    }
}

test "turn result and next state contract failures discard staged work before preparation" {
    var state = try data.encode(a, .{ .integer = 1 }, 256);
    defer state.deinit(a);
    for ([_][]const u8{ "bad_result", "bad_state" }, 0..) |mode, side| {
        var input = try data.encode(a, .{ .string = mode }, 256);
        defer input.deinit(a);
        var probe: Probe = .{};
        var diagnostic: Turn.Diagnostic = .{};
        try std.testing.expectError(error.TurnContractViolation, prepare(a, &probe, state.view(), input.view(), shape, &diagnostic, "fresh_probe"));
        try std.testing.expectEqual(@as(usize, 1), probe.begins);
        try std.testing.expectEqual(@as(usize, 1), probe.calls);
        try std.testing.expectEqual(@as(usize, 1), probe.discards);
        try std.testing.expectEqual(@as(usize, 0), probe.commits);
        try std.testing.expectEqual(.contract, diagnostic.kind);
        try std.testing.expectEqual(.record, diagnostic.phase);
        try std.testing.expectEqualStrings(if (side == 0) "result" else "next_state", @tagName(diagnostic.contract_detail.?.side));
    }
}

test "turn contracts snapshot mutable host declarations and bind replay identity" {
    var state = try data.encode(a, .{ .integer = 1 }, 256);
    defer state.deinit(a);
    var input = try data.encode(a, .{ .string = "ok" }, 256);
    defer input.deinit(a);
    var mutable = shape.*;
    var probe: Probe = .{ .mutate_contract = &mutable };
    var prepared = try prepare(a, &probe, state.view(), input.view(), &mutable, null, "fresh_probe");
    defer prepared.deinit();
    try prepared.commit();
    const request: Turn.Request = .{ .receiver = "FreshProbe", .method = "contract_probe", .state = state.view(), .input = input.view() };
    var verified = try Turn.replay(a, manifest, "fresh_probe", example.contract.operations, request, prepared.receipt(), .{ .allowed = example.contract.grants, .contract = shape });
    defer verified.deinit();
    try std.testing.expectEqualSlices(u8, prepared.terminal().bytes, verified.terminal().bytes);
    const changed = comptime try Turn.Contract.from(.{ .state = .integer, .input = .{ .string = .{ .max_bytes = 32 } }, .result = .integer });
    for ([_]?*const Turn.Contract{ changed, null }) |contract| {
        try std.testing.expectError(error.EffectTraceIdentityMismatch, Turn.replay(a, manifest, "fresh_probe", example.contract.operations, request, prepared.receipt(), .{ .allowed = example.contract.grants, .contract = contract }));
    }
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(@as(usize, 1), probe.commits);
}

test "turn replay rejects a reframed malformed terminal before program lookup" {
    var state = try data.encode(a, .{ .integer = 1 }, 256);
    defer state.deinit(a);
    var input = try data.encode(a, .{ .string = "ok" }, 256);
    defer input.deinit(a);
    var probe: Probe = .{};
    var prepared = try prepare(a, &probe, state.view(), input.view(), shape, null, "fresh_probe");
    defer prepared.deinit();
    const receipt = try Turn.Receipt.decode(prepared.receipt(), .{});
    var wrong = try data.encode(a, .{ .array = &.{ .{ .integer = 7 }, .{ .integer = -1 } } }, 1024);
    defer wrong.deinit(a);
    const changed = try Turn.Receipt.encode(a, receipt.trace, wrong.view(), .{});
    defer a.free(changed);
    var diagnostic: Turn.Diagnostic = .{};
    try std.testing.expectError(error.TurnContractViolation, Turn.replay(a, manifest, "entry_that_does_not_exist", example.contract.operations, .{
        .receiver = "FreshProbe",
        .method = "contract_probe",
        .state = state.view(),
        .input = input.view(),
    }, changed, .{ .allowed = example.contract.grants, .contract = shape, .diagnostic = &diagnostic }));
    try std.testing.expectEqual(.next_state, diagnostic.contract_detail.?.side);
    try std.testing.expectEqual(.setup, diagnostic.phase);
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
}

test "invalid normalized turn contracts fail before host activity" {
    var state = try data.encode(a, .{ .integer = 1 }, 256);
    defer state.deinit(a);
    var input = try data.encode(a, .{ .string = "ok" }, 256);
    defer input.deinit(a);
    var invalid = shape.*;
    invalid.state.graph.roots[0] = 1000;
    var probe: Probe = .{};
    try std.testing.expectError(error.InvalidTurnContract, prepare(a, &probe, state.view(), input.view(), &invalid, null, "fresh_probe"));
    try std.testing.expectEqual(@as(usize, 0), probe.begins + probe.calls + probe.discards);
}

test "turn contract validation retains tighter capsule policies and cleans up admission allocation failures" {
    var state = try data.encode(a, .{ .integer = 1 }, 256);
    defer state.deinit(a);
    var input = try data.encode(a, .{ .string = "ok" }, 256);
    defer input.deinit(a);
    var probe: Probe = .{};
    try std.testing.expectError(error.CapsuleLimitExceeded, Turn.prepare(a, manifest, "entry_that_does_not_exist", example.contract.operations, .{
        .receiver = "FreshProbe",
        .state = state.view(),
        .input = input.view(),
    }, .{ .transaction = probe.transaction() }, .{
        .contract = shape,
        .capsule_limits = .{ .max_string_bytes = 1 },
    }));
    for (0..3) |failure_index| {
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = failure_index });
        try std.testing.expectError(error.OutOfMemory, prepare(failing.allocator(), &probe, state.view(), input.view(), shape, null, "entry_that_does_not_exist"));
    }
    try std.testing.expectEqual(@as(usize, 0), probe.begins + probe.calls + probe.discards);
}
