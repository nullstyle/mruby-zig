const std = @import("std");
const example = @import("turn_example");

test "strict turn preparation, explicit commit, state continuation, and replay without a Host" {
    try example.verifyRecordReplay(std.testing.allocator);
}
test "data-only expected rejection replays with unchanged state" {
    try example.verifyRejection(std.testing.allocator);
}
test "explicit and abandoned prepared turns discard provisional work once" {
    try example.verifyDiscard(std.testing.allocator);
}
test "an exception after staging output and intent discards both" {
    try example.verifyFailureDiscard(std.testing.allocator);
}
test "fresh strict turns cannot inherit unexported Ruby globals" {
    try example.verifyFreshVm(std.testing.allocator);
}
test "replay compares terminal result and next state beyond envelope checksums" {
    try example.verifyTerminalTampering(std.testing.allocator);
}
test "replay binds the actual starting state and input bytes" {
    try example.verifyRequestIdentity(std.testing.allocator);
}

const mruby = @import("mruby");
const manifest = @import("turn_manifest");
const data = mruby.effect.data;
const Turn = mruby.strict.Turn;
const View = mruby.artifact.StateCapsuleView;
const Probe = struct {
    mode: enum { normal, malformed, oversized } = .normal,
    callbacks: usize = 0,
    begins: usize = 0,
    commits: usize = 0,
    discards: usize = 0,
    stop_allocations: ?*std.testing.FailingAllocator = null,

    fn from(context: ?*anyopaque) *Probe {
        return @ptrCast(@alignCast(context.?));
    }
    fn handle(context: ?*anyopaque, allocator: std.mem.Allocator, _: View) !mruby.effect.DataOutcome {
        const probe = from(context);
        probe.callbacks += 1;
        return .{ .returned = switch (probe.mode) {
            .normal => try data.encode(allocator, .nil, 256),
            .malformed => .{ .encoded = try allocator.dupe(u8, "malformed capsule") },
            .oversized => try data.encode(allocator, .{ .string = &@as([1024]u8, @splat('x')) }, 4096),
        } };
    }
    fn begin(context: ?*anyopaque) !void {
        const probe = from(context);
        probe.begins += 1;
        if (probe.stop_allocations) |failing| {
            failing.fail_index = failing.alloc_index;
            failing.resize_fail_index = failing.resize_index;
        }
    }
    fn commit(context: ?*anyopaque, _: View, _: []const u8) !Turn.CommitOutcome {
        from(context).commits += 1;
        return .committed;
    }
    fn discard(context: ?*anyopaque) void {
        from(context).discards += 1;
    }
    fn transaction(probe: *Probe) Turn.Transaction {
        return .{ .context = probe, .begin = begin, .commit = commit, .discard = discard };
    }
    fn verifyDiscarded(probe: Probe, callbacks: usize) !void {
        try std.testing.expectEqual(callbacks, probe.callbacks);
        try std.testing.expectEqual(@as(usize, 1), probe.begins);
        try std.testing.expectEqual(@as(usize, 0), probe.commits);
        try std.testing.expectEqual(@as(usize, 1), probe.discards);
    }
};

fn callProbe(probe: *Probe, method: []const u8, diagnostic: ?*Turn.Diagnostic) !Turn.Prepared {
    return callProbeAllocator(std.testing.allocator, probe, method, diagnostic);
}

fn callProbeAllocator(allocator: std.mem.Allocator, probe: *Probe, method: []const u8, diagnostic: ?*Turn.Diagnostic) !Turn.Prepared {
    var nil = try data.encode(allocator, .nil, 256);
    defer nil.deinit(allocator);
    const bindings = [_]mruby.effect.DataBinding{
        .{ .name = "clock.now", .handler = Probe.handle, .context = probe },
        .{ .name = "output.write", .handler = Probe.handle, .context = probe },
    };
    return Turn.prepare(allocator, manifest, "fresh_probe", example.contract.operations, .{
        .receiver = "FreshProbe",
        .method = method,
        .state = nil.view(),
        .input = nil.view(),
    }, .{ .bindings = &bindings, .transaction = probe.transaction() }, .{
        .allowed = example.contract.grants,
        .diagnostic = diagnostic,
    });
}

test "strict data handlers validate malformed and oversized result capsules before finishing a turn" {
    var malformed = Probe{ .mode = .malformed };
    try std.testing.expectError(error.InvalidEffectRequest, callProbe(&malformed, "observe_clock", null));
    try malformed.verifyDiscarded(1);
    var oversized = Probe{ .mode = .oversized };
    try std.testing.expectError(error.EffectLimitExceeded, callProbe(&oversized, "observe_clock", null));
    try oversized.verifyDiscarded(1);
}

test "native violation remains fatal after rescue and discards already staged output" {
    var probe = Probe{};
    var diagnostic = Turn.Diagnostic{};
    try std.testing.expectError(error.NativeEffectViolation, callProbe(&probe, "native_violation", &diagnostic));
    try probe.verifyDiscarded(1);
    try std.testing.expectEqual(.native, diagnostic.kind);
    try std.testing.expect(diagnostic.native_detail != null);
    const source = diagnostic.source orelse return error.ExpectedDiagnosticSource;
    try std.testing.expectEqualStrings("turn/fresh_probe.rb", source.fileName());
    try std.testing.expectEqual(@as(u32, 14), source.line);
    try std.testing.expectEqualStrings("NativeEffectViolation", diagnostic.errorName());
}

test "terminal must be an inert result and next-state pair before host commit" {
    var probe = Probe{};
    var diagnostic: Turn.Diagnostic = .{};
    try std.testing.expectError(error.InvalidTurnResult, callProbe(&probe, "not_a_pair", &diagnostic));
    try probe.verifyDiscarded(0);
    try std.testing.expectEqual(.terminal, diagnostic.kind);
    try std.testing.expectEqualStrings("InvalidTurnResult", diagnostic.errorName());
    try std.testing.expectEqual(.record, diagnostic.phase);
}

test "turn copies inert Ruby failure text and native source without guest diagnostic callbacks" {
    var probe: Probe = .{};
    var diagnostic: Turn.Diagnostic = .{};
    try std.testing.expectError(error.RubyException, callProbe(&probe, "ruby_failure", &diagnostic));
    try probe.verifyDiscarded(0);
    // The VM has already been freed by prepare. Every field is an owned copy.
    try std.testing.expectEqual(.ruby, diagnostic.kind);
    try std.testing.expectEqual(.turn, diagnostic.origin);
    try std.testing.expectEqual(.record, diagnostic.phase);
    try std.testing.expectEqualStrings("RubyException", diagnostic.errorName());
    try std.testing.expectEqualStrings("stored failure", diagnostic.messageText());
    try std.testing.expect(std.mem.endsWith(u8, diagnostic.className(), "DiagnosticError"));
    const source = diagnostic.source orelse return error.ExpectedDiagnosticSource;
    try std.testing.expectEqualStrings("turn/fresh_probe.rb", source.fileName());
    try std.testing.expect(source.line > 0);
    try std.testing.expect(!diagnostic.truncated);
}

test "turn bounds Ruby messages and ignores guest supplied backtrace strings" {
    var probe: Probe = .{};
    var diagnostic: Turn.Diagnostic = .{};
    try std.testing.expectError(error.RubyException, callProbe(&probe, "long_failure", &diagnostic));
    try std.testing.expectEqual(@as(usize, 512), diagnostic.messageText().len);
    try std.testing.expectEqualSlices(u8, &@as([512]u8, @splat('x')), diagnostic.messageText());
    try std.testing.expect(diagnostic.truncated);
    try std.testing.expect(diagnostic.source != null);
    try std.testing.expectError(error.RubyException, callProbe(&probe, "forged_backtrace", &diagnostic));
    try std.testing.expectEqualStrings("stored failure", diagnostic.messageText());
    try std.testing.expect(diagnostic.source == null);
    try std.testing.expect(!diagnostic.truncated);
    try std.testing.expectEqual(@as(usize, 0), probe.callbacks);
}

test "Ruby diagnostic capture needs no further host allocations after execution begins" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var probe: Probe = .{ .stop_allocations = &failing };
    var diagnostic: Turn.Diagnostic = .{};
    try std.testing.expectError(error.RubyException, callProbeAllocator(failing.allocator(), &probe, "ruby_failure", &diagnostic));
    try probe.verifyDiscarded(0);
    try std.testing.expectEqualStrings("stored failure", diagnostic.messageText());
    try std.testing.expect(diagnostic.source != null);
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    // A reused destination is cleared before a subsequent successful turn.
    probe.stop_allocations = null;
    var prepared = try callProbe(&probe, "apply", &diagnostic);
    defer prepared.deinit();
    try std.testing.expectEqualDeep(Turn.Diagnostic{}, diagnostic);
}

test "turn denied and unhandled effects retain operation context and source" {
    var nil = try data.encode(std.testing.allocator, .nil, 256);
    defer nil.deinit(std.testing.allocator);
    for ([_]bool{ false, true }) |granted| {
        var probe: Probe = .{};
        var diagnostic: Turn.Diagnostic = .{};
        try std.testing.expectError(if (granted) error.EffectUnhandled else error.EffectDenied, Turn.prepare(
            std.testing.allocator,
            manifest,
            "fresh_probe",
            example.contract.operations,
            .{ .receiver = "FreshProbe", .method = "observe_clock", .state = nil.view(), .input = nil.view() },
            .{ .transaction = probe.transaction() },
            .{ .allowed = if (granted) example.contract.grants else &.{}, .diagnostic = &diagnostic },
        ));
        try probe.verifyDiscarded(0);
        try std.testing.expectEqual(.effect, diagnostic.kind);
        const detail = diagnostic.effect_detail orelse return error.ExpectedEffectDiagnostic;
        try std.testing.expectEqual(@as(mruby.effect.Diagnostic.Reason, if (granted) .unhandled else .denied), detail.reason);
        try std.testing.expectEqualStrings("clock.now", detail.actualOperation());
        try std.testing.expectEqual(@as(usize, 0), detail.record_index);
        try std.testing.expectEqual(@as(?u32, 1), detail.actual_version);
        const source = diagnostic.source orelse return error.ExpectedDiagnosticSource;
        try std.testing.expectEqualStrings("turn/fresh_probe.rb", source.fileName());
        try std.testing.expectEqual(@as(u32, 8), source.line);
    }
}

const RejectionProbe = struct {
    calls: usize = 0,
    fn reject(context: ?*anyopaque, allocator: std.mem.Allocator, _: View) !mruby.effect.DataOutcome {
        const self: *RejectionProbe = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        return data.reject(allocator, "OutOfStock", "Not enough stock", 1024);
    }
};

fn checkReraisedRejection(capsule: View) !void {
    var doc = try data.Document.decode(std.testing.allocator, capsule, 4096);
    defer doc.deinit();
    try std.testing.expect(try (try doc.root().at(0)).asBoolean());
    try std.testing.expectEqualStrings("OutOfStock", try (try doc.root().at(1)).asString());
    try std.testing.expectEqualStrings("Not enough stock", try (try doc.root().at(2)).asString());
    try std.testing.expect(try (try doc.root().at(3)).asBoolean());
}

test "CodeDB explicit reraising preserves rejection identity code message and ensure through replay" {
    const allocator = std.testing.allocator;
    var nil = try data.encode(allocator, .nil, 256);
    defer nil.deinit(allocator);
    var probe = RejectionProbe{};
    const bindings = [_]mruby.effect.DataBinding{
        .{ .name = "intent.prepare", .handler = RejectionProbe.reject, .context = &probe },
    };
    const request: Turn.Request = .{
        .receiver = "Counter",
        .method = "reraise_rejection",
        .state = nil.view(),
        .input = nil.view(),
    };
    const options: Turn.Options = .{ .allowed = &.{"intent.prepare"} };
    var prepared = try Turn.prepare(allocator, manifest, "counter", example.contract.operations, request, .{ .bindings = &bindings }, options);
    defer prepared.deinit();
    var result = try prepared.result(allocator);
    defer result.deinit(allocator);
    try checkReraisedRejection(result.view());
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    var replay = try Turn.replay(allocator, manifest, "counter", example.contract.operations, request, prepared.receipt(), options);
    defer replay.deinit();
    var replay_result = try replay.result(allocator);
    defer replay_result.deinit(allocator);
    try checkReraisedRejection(replay_result.view());
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
}
