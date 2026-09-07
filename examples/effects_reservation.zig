//! Typed domain operations in a confined worker, with staged host effects.
//!   zig build run-effects-reservation -Deffects-strict=true
//! Installed: effects-reservation /absolute/path/to/effects-reservation-child
const std = @import("std");
const mruby = @import("mruby");
pub const manifest = @import("reservation_manifest");
pub const contract = @import("reservation_contract");
pub const storage = @import("reservation/host.zig");
pub const Host = storage.Host;
const Worker = mruby.strict.Worker;
const Turn = mruby.strict.Turn;
const data = mruby.effect.data;
const Capsule = mruby.artifact.StateCapsule;
const View = mruby.artifact.StateCapsuleView;
const testing = std.testing;

pub fn inputCapsule(allocator: std.mem.Allocator, quantity: i64, mode: []const u8) !Capsule {
    return data.encode(allocator, .{ .hash = &.{
        .{ .key = .{ .string = "sku" }, .value = .{ .string = "widget" } },
        .{ .key = .{ .string = "quantity" }, .value = .{ .integer = quantity } },
        .{ .key = .{ .string = "mode" }, .value = .{ .string = mode } },
    } }, contract.max_bytes);
}

pub fn options(host: *const Host) Worker.Options {
    var bootstrap: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(contract.bootstrap_contract, &bootstrap, .{});
    return .{ .turn = .{
        .contract = comptime Turn.Contract.from(contract.turn_contract) catch unreachable,
        .allowed = contract.grants,
        .bootstrap_identity = bootstrap,
        .adapter_state_identity = host.identity(),
    } };
}

pub fn request(state: View, input: View) Turn.Request {
    return .{ .receiver = "ReservationFlow", .state = state, .input = input };
}

pub fn prepare(allocator: std.mem.Allocator, executable: []const u8, host: *Host, input: View, diagnostic: ?*Turn.Diagnostic) !Turn.Prepared {
    const bindings = host.bindings();
    var configuration = options(host);
    configuration.turn.diagnostic = diagnostic;
    return Worker.prepare(allocator, executable, manifest, "app", contract.operations, request(host.state.view(), input), .{
        .bindings = &bindings,
        .transaction = host.transaction(),
    }, configuration);
}

pub fn stateCounter(allocator: std.mem.Allocator, state: View, name: []const u8) !i64 {
    var doc = try data.Document.decode(allocator, state, contract.max_bytes);
    defer doc.deinit();
    return (try storage.field(doc.root(), name)).asInteger();
}

pub fn expectStatus(allocator: std.mem.Allocator, terminal: View, expected: []const u8) !void {
    var doc = try data.Document.decode(allocator, terminal, contract.max_bytes);
    defer doc.deinit();
    try testing.expectEqualStrings(expected, try (try storage.field(try doc.root().at(0), "status")).asString());
}

pub fn verifyReservation(allocator: std.mem.Allocator, executable: []const u8) !void {
    var host = try Host.init(allocator);
    defer host.deinit();
    var starting_state = try data.clone(allocator, host.state.view(), contract.max_bytes);
    defer starting_state.deinit(allocator);
    var input = try inputCapsule(allocator, 2, "ok");
    defer input.deinit(allocator);
    const replay_options = options(&host);
    var prepared = try prepare(allocator, executable, &host, input.view(), null);
    defer prepared.deinit();
    try expectStatus(allocator, prepared.terminal(), "reserved");
    try testing.expectEqual(@as(i64, 5), host.stock);
    try testing.expectEqual(@as(usize, 0), host.notification_count);
    try testing.expectEqual(@as(i64, 3), host.pending_stock.?);
    try testing.expect(host.pending_notification != null);
    try prepared.commit();
    try testing.expectEqual(@as(i64, 3), host.stock);
    try testing.expectEqual(@as(i64, 1), host.reservation_count);
    try testing.expectEqual(@as(usize, 1), host.notification_count);
    try testing.expectEqual(@as(i64, 1), try stateCounter(allocator, host.state.view(), "attempts"));
    try testing.expectEqual(@as(i64, 1), try stateCounter(allocator, host.state.view(), "reservations"));
    var replay = try Worker.replay(allocator, executable, manifest, "app", contract.operations, request(starting_state.view(), input.view()), prepared.receipt(), replay_options);
    defer replay.deinit();
    try testing.expectEqualSlices(u8, prepared.terminal().bytes, replay.terminal().bytes);
    try testing.expectEqual(@as(usize, 1), host.reserve_calls);
    try testing.expectEqual(@as(usize, 1), host.notification_calls);
    try testing.expectEqual(@as(usize, 1), host.commits);
    try testing.expectEqual(@as(usize, 0), host.discards);
}

pub fn verifyOutOfStock(allocator: std.mem.Allocator, executable: []const u8) !void {
    var host = try Host.init(allocator);
    defer host.deinit();
    var starting_state = try data.clone(allocator, host.state.view(), contract.max_bytes);
    defer starting_state.deinit(allocator);
    var input = try inputCapsule(allocator, 8, "ok");
    defer input.deinit(allocator);
    const replay_options = options(&host);
    var prepared = try prepare(allocator, executable, &host, input.view(), null);
    defer prepared.deinit();
    try expectStatus(allocator, prepared.terminal(), "out_of_stock");
    try testing.expectEqual(@as(usize, 1), host.reserve_calls);
    try testing.expectEqual(@as(usize, 0), host.notification_calls);
    try testing.expect(host.pending_stock == null and host.pending_notification == null);
    try prepared.commit();
    try testing.expectEqual(@as(i64, 5), host.stock);
    try testing.expectEqual(@as(i64, 0), host.reservation_count);
    try testing.expectEqual(@as(usize, 0), host.notification_count);
    try testing.expectEqual(@as(i64, 1), try stateCounter(allocator, host.state.view(), "attempts"));
    try testing.expectEqual(@as(i64, 0), try stateCounter(allocator, host.state.view(), "reservations"));
    var replay = try Worker.replay(allocator, executable, manifest, "app", contract.operations, request(starting_state.view(), input.view()), prepared.receipt(), replay_options);
    defer replay.deinit();
    try testing.expectEqualSlices(u8, prepared.terminal().bytes, replay.terminal().bytes);
    try testing.expectEqual(@as(usize, 1), host.reserve_calls);
}

pub fn verifyFailure(allocator: std.mem.Allocator, executable: []const u8, mode: []const u8, fault: storage.Fault, expected: anyerror, reserve_calls: usize, notification_calls: usize) !Turn.Diagnostic {
    var host = try Host.init(allocator);
    defer host.deinit();
    host.fault = fault;
    var input = try inputCapsule(allocator, 2, mode);
    defer input.deinit(allocator);
    var diagnostic: Turn.Diagnostic = .{};
    try testing.expectError(expected, prepare(allocator, executable, &host, input.view(), &diagnostic));
    try testing.expectEqual(reserve_calls, host.reserve_calls);
    try testing.expectEqual(notification_calls, host.notification_calls);
    try testing.expectEqual(@as(usize, 1), host.begins);
    try testing.expectEqual(@as(usize, 0), host.commits);
    try testing.expectEqual(@as(usize, 1), host.discards);
    try testing.expectEqual(@as(i64, 5), host.stock);
    try testing.expectEqual(@as(i64, 0), host.reservation_count);
    try testing.expectEqual(@as(usize, 0), host.notification_count);
    try testing.expectEqual(@as(i64, 0), try stateCounter(allocator, host.state.view(), "attempts"));
    try testing.expect(!host.active and host.pending_stock == null and host.pending_notification == null and host.receipt == null);
    return diagnostic;
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const executable = args.next() orelse return error.ExpectedReservationWorker;
    if (args.next() != null) return error.UnexpectedArgument;
    try verifyReservation(init.gpa, executable);
    try verifyOutOfStock(init.gpa, executable);
    _ = try verifyFailure(init.gpa, executable, "invalid_argument", .none, error.EffectContractViolation, 0, 0);
    _ = try verifyFailure(init.gpa, executable, "ok", .invalid_result, error.EffectContractViolation, 1, 0);
    _ = try verifyFailure(init.gpa, executable, "ok", .undeclared_rejection, error.EffectContractViolation, 1, 0);
    _ = try verifyFailure(init.gpa, executable, "invalid_turn_result", .none, error.TurnContractViolation, 1, 1);
    _ = try verifyFailure(init.gpa, executable, "invalid_next_state", .none, error.TurnContractViolation, 1, 1);
    std.debug.print("typed reservation: stock 5 -> 3; commit retained one reservation, state and local notification intent\n", .{});
    std.debug.print("typed reservation: OutOfStock is recoverable; malformed requests and handler outcomes discard the turn\n", .{});
    std.debug.print("typed reservation: replay matched success and rejection without adapters or new intents\n", .{});
    std.debug.print("typed reservation: invalid returned values and next state discarded both staged domain effects\n", .{});
}
