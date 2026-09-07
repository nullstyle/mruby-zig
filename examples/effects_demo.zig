//! Explicit Ruby effects with live, test, record, and replay adapters.
//! Application Ruby is compiled by CodeDB, including with -Dno-compiler.
//!
//!     zig build run-effects-demo

const std = @import("std");
const mruby = @import("mruby");
const manifest = @import("effects_manifest");
const contract = @import("effects/contract.zig");

const Intent = struct {
    destination: []u8,
    payload: []u8,
};

const Host = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    fixed_now: ?i64 = null,
    intents: std.ArrayList(Intent) = .empty,
    clock_calls: usize = 0,
    enqueue_calls: usize = 0,

    fn deinit(host: *Host) void {
        for (host.intents.items) |intent| {
            host.allocator.free(intent.destination);
            host.allocator.free(intent.payload);
        }
        host.intents.deinit(host.allocator);
    }

    fn now(context: ?*anyopaque, vm: *mruby.Vm, args: mruby.Value) !mruby.Value {
        _ = args;
        const host: *Host = @ptrCast(@alignCast(context.?));
        host.clock_calls += 1;
        return vm.intValue(host.fixed_now orelse std.Io.Clock.real.now(host.io).toSeconds());
    }

    fn enqueue(context: ?*anyopaque, vm: *mruby.Vm, args: mruby.Value) !mruby.Value {
        const host: *Host = @ptrCast(@alignCast(context.?));
        host.enqueue_calls += 1;
        if (host.intents.items.len >= 16) return error.OutboxFull;
        const values = try args.asArray();
        const destination_value = try values.get(0);
        const destination_bytes = try destination_value.asString();
        if (destination_bytes.len > 256) return error.DestinationTooLong;
        // Copy borrowed Ruby bytes before making another interpreter call.
        const destination = try host.allocator.dupe(u8, destination_bytes);
        errdefer host.allocator.free(destination);
        const payload_value = try values.get(1);
        const payload_bytes = try payload_value.asString();
        if (payload_bytes.len > 4096) return error.PayloadTooLong;
        const payload = try host.allocator.dupe(u8, payload_bytes);
        errdefer host.allocator.free(payload);
        const receipt = try vm.intValue(@as(i64, @intCast(host.intents.items.len + 1)));
        try host.intents.append(host.allocator, .{
            .destination = destination,
            .payload = payload,
        });
        // A receipt acknowledges ownership of an in-memory intent. No network
        // delivery or durable commit occurs in this adapter.
        return receipt;
    }
};

const Outcome = struct {
    timestamp: i64,
    receipt: i64,
    encoded_trace: ?[]u8 = null,
};

fn execute(host: *Host, mode: mruby.effect.Mode) !Outcome {
    var boot = try mruby.sandbox.BootstrapIsolate.spawn(mruby.sandbox.Policy.restricted(.{
        .limits = .{ .gas = .{ .per_execution = 100_000 }, .call_depth = 32 },
    }));
    defer boot.deinit();
    const bindings = [_]mruby.effect.Binding{
        .{ .name = "clock.now", .handler = Host.now, .context = host },
        .{ .name = "outbox.enqueue", .handler = Host.enqueue, .context = host },
    };
    var input_identity: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(contract.message, &input_identity, .{});
    try mruby.effect.install(boot.vm(), contract.operations, .{
        .allowed = &.{ "clock.now", "outbox.enqueue" },
        .bindings = &bindings,
        .mode = mode,
        .input_identity = input_identity,
    });
    const iso = try boot.seal();
    defer iso.deinit();
    const result = try iso.runArtifact(manifest, "announce");
    const values = try result.asArray();
    var outcome: Outcome = .{
        .timestamp = try (try values.get(0)).asInt(),
        .receipt = try (try values.get(1)).asInt(),
    };
    if (mode == .record) {
        var trace = try iso.takeEffectTrace();
        defer trace.deinit();
        outcome.encoded_trace = try trace.encode(host.allocator);
    }
    return outcome;
}

fn expectIntent(host: *const Host, outcome: Outcome) !void {
    try std.testing.expectEqual(@as(usize, 1), host.clock_calls);
    try std.testing.expectEqual(@as(usize, 1), host.enqueue_calls);
    try std.testing.expectEqual(@as(usize, 1), host.intents.items.len);
    try std.testing.expectEqual(@as(i64, 1), outcome.receipt);
    const intent = host.intents.items[0];
    try std.testing.expectEqualStrings("announcements", intent.destination);
    const expected = try std.fmt.allocPrint(host.allocator, "{d}: {s}", .{
        outcome.timestamp, contract.message,
    });
    defer host.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, intent.payload);
}

pub fn main(init: std.process.Init) !void {
    var live: Host = .{ .allocator = init.gpa, .io = init.io };
    defer live.deinit();
    const live_result = try execute(&live, .live);
    try expectIntent(&live, live_result);

    var fixed: Host = .{ .allocator = init.gpa, .io = init.io, .fixed_now = 1_700_000_000 };
    defer fixed.deinit();
    const fixed_result = try execute(&fixed, .live);
    try std.testing.expectEqual(@as(i64, 1_700_000_000), fixed_result.timestamp);
    try expectIntent(&fixed, fixed_result);

    var recorder: Host = .{ .allocator = init.gpa, .io = init.io };
    defer recorder.deinit();
    const recorded = try execute(&recorder, .record);
    const encoded = recorded.encoded_trace.?;
    defer init.gpa.free(encoded);
    try expectIntent(&recorder, recorded);

    // execute has destroyed the recording VM. Only owned host values and the
    // encoded transcript survive into this fresh isolate.
    var replayer: Host = .{ .allocator = init.gpa, .io = init.io, .fixed_now = -1 };
    defer replayer.deinit();
    const replayed = try execute(&replayer, .{ .replay = encoded });
    try std.testing.expectEqual(recorded.timestamp, replayed.timestamp);
    try std.testing.expectEqual(recorded.receipt, replayed.receipt);
    try std.testing.expectEqual(@as(usize, 0), replayer.clock_calls);
    try std.testing.expectEqual(@as(usize, 0), replayer.enqueue_calls);
    try std.testing.expectEqual(@as(usize, 0), replayer.intents.items.len);

    std.debug.print("effects: live -> [{d}, {d}], fixed -> [{d}, {d}]\n", .{
        live_result.timestamp, live_result.receipt, fixed_result.timestamp, fixed_result.receipt,
    });
    std.debug.print("effects: {d}-byte trace -> replay [{d}, {d}], zero handler calls and no new intents\n", .{
        encoded.len, replayed.timestamp, replayed.receipt,
    });
}
