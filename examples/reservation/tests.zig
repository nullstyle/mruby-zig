const std = @import("std");
const mruby = @import("mruby");
const example = @import("reservation_example");
const config = @import("reservation_test_config");
const Worker = mruby.strict.Worker;
const data = mruby.effect.data;
const testing = std.testing;
const a = testing.allocator;

test "typed reservation commits stock state and a local notification then replays without callbacks" {
    try example.verifyReservation(a, config.worker_executable);
}

test "declared OutOfStock rejection becomes a committed Ruby fallback without reserving stock" {
    try example.verifyOutOfStock(a, config.worker_executable);
}

fn verifyRejectedAdmission(comptime invalid_state: bool) !void {
    var host = try example.Host.init(a);
    defer host.deinit();
    var state = if (invalid_state) try data.encode(a, .{ .hash = &.{
        .{ .key = .{ .string = "attempts" }, .value = .{ .integer = -1 } },
        .{ .key = .{ .string = "reservations" }, .value = .{ .integer = 0 } },
    } }, example.contract.max_bytes) else try data.clone(a, host.state.view(), example.contract.max_bytes);
    defer state.deinit(a);
    var input = try example.inputCapsule(a, if (invalid_state) 2 else 0, "ok");
    defer input.deinit(a);
    var options = example.options(&host);
    var diagnostic: mruby.strict.Turn.Diagnostic = .{};
    var observation: Worker.Observation = .{};
    options.turn.diagnostic = &diagnostic;
    options.observation = &observation;
    const bindings = host.bindings();
    try testing.expectError(error.TurnContractViolation, Worker.prepare(a, config.worker_executable, example.manifest, "app", example.contract.operations, example.request(state.view(), input.view()), .{
        .bindings = &bindings,
        .transaction = host.transaction(),
    }, options));
    try testing.expectEqual(.contract, diagnostic.kind);
    try testing.expectEqual(.broker, diagnostic.origin);
    try testing.expectEqual(.setup, diagnostic.phase);
    if (invalid_state) {
        try testing.expectEqual(.state, diagnostic.contract_detail.?.side);
        try testing.expectEqualStrings("$[\"attempts\"]", diagnostic.contract_detail.?.detail.pathText());
    } else {
        try testing.expectEqual(.input, diagnostic.contract_detail.?.side);
        try testing.expectEqualStrings("$[\"quantity\"]", diagnostic.contract_detail.?.detail.pathText());
    }
    try testing.expect(observation.execution_pid == null and observation.verification_pid == null);
    try testing.expectEqual(@as(usize, 0), host.begins);
    try testing.expectEqual(@as(usize, 0), host.reserve_calls);
    try testing.expectEqual(@as(usize, 0), host.notification_calls);
    try testing.expectEqual(@as(usize, 0), host.commits);
    try testing.expectEqual(@as(usize, 0), host.discards);
    try testing.expectEqual(@as(i64, 5), host.stock);
    try testing.expectEqual(@as(i64, 0), try example.stateCounter(a, host.state.view(), "attempts"));
    try testing.expect(!host.active and host.pending_stock == null and host.pending_reservation == null and host.pending_notification == null and host.receipt == null);
}

test "invalid turn input is rejected before worker spawn transaction begin or adapters" {
    try verifyRejectedAdmission(false);
}

test "invalid starting state is rejected before worker spawn transaction begin or adapters" {
    try verifyRejectedAdmission(true);
}

test "wrong Ruby argument type fails its operation contract before the stock adapter" {
    const diagnostic = try example.verifyFailure(a, config.worker_executable, "invalid_argument", .none, error.EffectContractViolation, 0, 0);
    try testing.expectEqual(.arguments, diagnostic.effect_detail.?.contract_detail.?.side);
    try testing.expectEqualStrings("$[1]", diagnostic.effect_detail.?.contract_detail.?.pathText());
}

test "invalid stock handler result discards already staged stock before notification" {
    const diagnostic = try example.verifyFailure(a, config.worker_executable, "ok", .invalid_result, error.EffectContractViolation, 1, 0);
    try testing.expectEqual(.result, diagnostic.effect_detail.?.contract_detail.?.side);
}

test "undeclared business rejection discards staged stock instead of entering Ruby rescue" {
    const diagnostic = try example.verifyFailure(a, config.worker_executable, "ok", .undeclared_rejection, error.EffectContractViolation, 1, 0);
    try testing.expectEqual(.rejection, diagnostic.effect_detail.?.contract_detail.?.side);
}

test "notification result contract failure discards reservation and prepared notification" {
    const diagnostic = try example.verifyFailure(a, config.worker_executable, "ok", .invalid_notification, error.EffectContractViolation, 1, 1);
    try testing.expectEqual(.result, diagnostic.effect_detail.?.contract_detail.?.side);
}

test "Ruby exception after both domain effects discards all staged host changes" {
    _ = try example.verifyFailure(a, config.worker_executable, "raise", .none, error.RubyException, 1, 1);
}

test "invalid returned turn result discards both staged domain effects" {
    const diagnostic = try example.verifyFailure(a, config.worker_executable, "invalid_turn_result", .none, error.TurnContractViolation, 1, 1);
    try testing.expectEqual(.contract, diagnostic.kind);
    try testing.expectEqual(.worker, diagnostic.origin);
    try testing.expectEqual(.result, diagnostic.contract_detail.?.side);
    try testing.expectEqualStrings("$[\"status\"]", diagnostic.contract_detail.?.detail.pathText());
}

test "invalid next state discards both staged domain effects" {
    const diagnostic = try example.verifyFailure(a, config.worker_executable, "invalid_next_state", .none, error.TurnContractViolation, 1, 1);
    try testing.expectEqual(.next_state, diagnostic.contract_detail.?.side);
    try testing.expectEqualStrings("$[\"reservations\"]", diagnostic.contract_detail.?.detail.pathText());
}

test "abandoned successful reservation preparation discards all staged changes" {
    var host = try example.Host.init(a);
    defer host.deinit();
    var input = try example.inputCapsule(a, 2, "ok");
    defer input.deinit(a);
    {
        var prepared = try example.prepare(a, config.worker_executable, &host, input.view(), null);
        defer prepared.deinit();
        try testing.expect(host.active and host.pending_notification != null);
    }
    try testing.expectEqual(@as(usize, 1), host.discards);
    try testing.expectEqual(@as(usize, 0), host.commits);
    try testing.expectEqual(@as(i64, 5), host.stock);
    try testing.expectEqual(@as(usize, 0), host.notification_count);
    try testing.expectEqual(@as(i64, 0), try example.stateCounter(a, host.state.view(), "attempts"));
    try testing.expect(!host.active and host.pending_stock == null and host.pending_reservation == null and host.pending_notification == null);
}

test "schema change with unchanged operation versions and Ruby code rejects the old receipt" {
    var host = try example.Host.init(a);
    defer host.deinit();
    var state = try data.clone(a, host.state.view(), example.contract.max_bytes);
    defer state.deinit(a);
    var input = try example.inputCapsule(a, 2, "ok");
    defer input.deinit(a);
    var options = example.options(&host);
    var prepared = try example.prepare(a, config.worker_executable, &host, input.view(), null);
    defer prepared.deinit();
    var observation: Worker.Observation = .{};
    options.observation = &observation;
    try testing.expectError(error.EffectTraceIdentityMismatch, Worker.replay(a, config.changed_worker_executable, example.manifest, "app", example.contract.operations_v2, example.request(state.view(), input.view()), prepared.receipt(), options));
    try testing.expect(observation.execution_pid == null and observation.verification_pid == null);
    try testing.expectEqual(@as(usize, 1), host.reserve_calls);
    try testing.expectEqual(@as(usize, 1), host.notification_calls);
    try testing.expectEqual(@as(i64, 5), host.stock);
}

test "turn schema alone changes replay identity and matching changed worker still runs" {
    const changed = comptime try mruby.strict.Turn.Contract.from(example.contract.turn_contract_v2);
    var host = try example.Host.init(a);
    defer host.deinit();
    var state = try data.clone(a, host.state.view(), example.contract.max_bytes);
    defer state.deinit(a);
    var input = try example.inputCapsule(a, 2, "ok");
    defer input.deinit(a);
    var configuration = example.options(&host);
    var observation: Worker.Observation = .{};
    var diagnostic: mruby.strict.Turn.Diagnostic = .{};
    configuration.turn.contract = changed;
    configuration.turn.diagnostic = &diagnostic;
    configuration.observation = &observation;
    {
        var prepared = try example.prepare(a, config.worker_executable, &host, input.view(), null);
        defer prepared.deinit();
        try testing.expectError(error.EffectTraceIdentityMismatch, Worker.replay(a, config.changed_turn_worker_executable, example.manifest, "app", example.contract.operations, example.request(state.view(), input.view()), prepared.receipt(), configuration));
        try testing.expectEqual(.identity_input, diagnostic.effect_detail.?.reason);
        try testing.expect(observation.execution_pid == null and observation.verification_pid == null);
        try testing.expectEqual(@as(usize, 1), host.reserve_calls);
        try testing.expectEqual(@as(usize, 1), host.notification_calls);
    }
    // The same operation catalogue and Ruby program run under the changed
    // whole-turn declaration when both broker and compiled child agree.
    var fresh = try example.Host.init(a);
    defer fresh.deinit();
    const bindings = fresh.bindings();
    var matching = example.options(&fresh);
    matching.turn.contract = changed;
    var prepared = try Worker.prepare(a, config.changed_turn_worker_executable, example.manifest, "app", example.contract.operations, example.request(fresh.state.view(), input.view()), .{
        .bindings = &bindings,
        .transaction = fresh.transaction(),
    }, matching);
    defer prepared.deinit();
    try example.expectStatus(a, prepared.terminal(), "reserved");
    try prepared.commit();
    try testing.expectEqual(@as(i64, 3), fresh.stock);
    try testing.expectEqual(@as(usize, 1), fresh.notification_count);
}

test "allocation failure before in-memory adoption rejects commit and discards staged changes" {
    var host = try example.Host.init(a);
    defer host.deinit();
    var input = try example.inputCapsule(a, 2, "ok");
    defer input.deinit(a);
    var prepared = try example.prepare(a, config.worker_executable, &host, input.view(), null);
    defer prepared.deinit();
    var failing = testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    host.allocator = failing.allocator();
    defer host.allocator = a;
    try testing.expectError(error.CommitRejected, prepared.commit());
    try testing.expect(failing.has_induced_failure);
    try testing.expectEqual(@as(usize, 1), host.discards);
    try testing.expectEqual(@as(usize, 0), host.commits);
    try testing.expectEqual(@as(i64, 5), host.stock);
    try testing.expectEqual(@as(usize, 0), host.notification_count);
    try testing.expectEqual(@as(i64, 0), try example.stateCounter(a, host.state.view(), "attempts"));
    try testing.expect(host.receipt == null and !host.active and host.pending_reservation == null);
}
