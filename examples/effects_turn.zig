//! Fresh strict turns with data-only effects and explicit host commit/discard.
//!   zig build run-effects-turn -Deffects-strict=true
//! No SQLite, system service, or runtime compiler is required.
const std = @import("std");
const mruby = @import("mruby");
const manifest = @import("turn_manifest");
pub const contract = @import("turn/contract.zig");
const data = mruby.effect.data;
const Turn = mruby.strict.Turn;
const Capsule = mruby.artifact.StateCapsule;
const View = mruby.artifact.StateCapsuleView;
const testing = std.testing;

const Intent = struct { count: i64, at: i64 };
const Calls = struct { clock: usize = 0, intent: usize = 0, output: usize = 0 };

// Every adapter receives inert capsule bytes and an allocator. None receives
// a VM or Ruby Value. The context owns any memory retained beyond the callback.
const Host = struct {
    allocator: std.mem.Allocator,
    state: Capsule,
    receipt: ?[]u8 = null,
    pending_intents: std.ArrayList(Intent) = .empty,
    intents: std.ArrayList(Intent) = .empty,
    pending_output: std.ArrayList([]u8) = .empty,
    output: std.ArrayList([]u8) = .empty,
    calls: Calls = .{},
    begins: usize = 0,
    commits: usize = 0,
    discards: usize = 0,
    active: bool = false,

    fn init(allocator: std.mem.Allocator) !Host {
        return .{ .allocator = allocator, .state = try stateCapsule(allocator, 7, null) };
    }

    fn deinit(host: *Host) void {
        if (host.active) host.discardPending();
        host.state.deinit(host.allocator);
        if (host.receipt) |receipt| host.allocator.free(receipt);
        for (host.output.items) |line| host.allocator.free(line);
        host.output.deinit(host.allocator);
        host.pending_output.deinit(host.allocator);
        host.intents.deinit(host.allocator);
        host.pending_intents.deinit(host.allocator);
    }

    fn bindings(host: *Host) [3]mruby.effect.DataBinding {
        return .{
            .{ .name = "clock.now", .handler = clockNow, .context = host },
            .{ .name = "intent.prepare", .handler = prepareIntent, .context = host },
            .{ .name = "output.write", .handler = writeOutput, .context = host },
        };
    }

    fn transaction(host: *Host) Turn.Transaction {
        return .{ .context = host, .begin = begin, .commit = commit, .discard = discard };
    }

    fn from(context: ?*anyopaque) *Host {
        return @ptrCast(@alignCast(context.?));
    }

    fn begin(context: ?*anyopaque) !void {
        const host = from(context);
        if (host.active) return error.TransactionAlreadyActive;
        std.debug.assert(host.pending_intents.items.len == 0 and host.pending_output.items.len == 0);
        host.active = true;
        host.begins += 1;
    }

    fn commit(context: ?*anyopaque, terminal: View, receipt: []const u8) !Turn.CommitOutcome {
        const host = from(context);
        if (!host.active) return error.TransactionNotActive;
        var document = try data.Document.decode(host.allocator, terminal, contract.max_bytes);
        defer document.deinit();
        var next_state = try data.encodeRef(host.allocator, try document.root().at(1), contract.max_bytes);
        errdefer next_state.deinit(host.allocator);
        const saved_receipt = try host.allocator.dupe(u8, receipt);
        errdefer host.allocator.free(saved_receipt);
        // Complete every fallible allocation before adopting any state or
        // intents. This tiny in-memory commit never delivers external work.
        try host.intents.ensureUnusedCapacity(host.allocator, host.pending_intents.items.len);
        try host.output.ensureUnusedCapacity(host.allocator, host.pending_output.items.len);
        host.state.deinit(host.allocator);
        host.state = next_state;
        if (host.receipt) |old| host.allocator.free(old);
        host.receipt = saved_receipt;
        host.intents.appendSliceAssumeCapacity(host.pending_intents.items);
        host.pending_intents.clearRetainingCapacity();
        host.output.appendSliceAssumeCapacity(host.pending_output.items);
        host.pending_output.clearRetainingCapacity();
        host.active = false;
        host.commits += 1;
        return .committed;
    }

    fn discard(context: ?*anyopaque) void {
        from(context).discardPending();
    }

    fn discardPending(host: *Host) void {
        if (!host.active) return;
        for (host.pending_output.items) |line| host.allocator.free(line);
        host.pending_output.clearRetainingCapacity();
        host.pending_intents.clearRetainingCapacity();
        host.active = false;
        host.discards += 1;
    }

    fn clockNow(context: ?*anyopaque, allocator: std.mem.Allocator, _: View) !mruby.effect.DataOutcome {
        const host = from(context);
        if (!host.active) return error.TransactionNotActive;
        host.calls.clock += 1;
        return .{ .returned = try data.encode(allocator, .{ .integer = 1_700_000_000 }, 256) };
    }

    fn prepareIntent(context: ?*anyopaque, allocator: std.mem.Allocator, arguments: View) !mruby.effect.DataOutcome {
        const host = from(context);
        if (!host.active) return error.TransactionNotActive;
        host.calls.intent += 1;
        var document = try data.Document.decode(allocator, arguments, contract.max_bytes);
        defer document.deinit();
        const payload = try document.root().at(0);
        if (!std.mem.eql(u8, try (try field(payload, "topic")).asString(), "counter.updated")) return error.InvalidIntent;
        const count = try (try field(payload, "count")).asInteger();
        const at = try (try field(payload, "at")).asInteger();
        if (count > 100) return data.reject(allocator, "CounterLimit", "counter cannot exceed 100", 1024);
        try host.pending_intents.append(host.allocator, .{ .count = count, .at = at });
        return .{ .returned = try data.encode(allocator, .{ .integer = @intCast(host.pending_intents.items.len) }, 256) };
    }

    fn writeOutput(context: ?*anyopaque, allocator: std.mem.Allocator, arguments: View) !mruby.effect.DataOutcome {
        const host = from(context);
        if (!host.active) return error.TransactionNotActive;
        host.calls.output += 1;
        var document = try data.Document.decode(allocator, arguments, contract.max_bytes);
        defer document.deinit();
        const line = try (try document.root().at(0)).asString();
        if (line.len > 256) return error.OutputTooLong;
        const saved = try host.allocator.dupe(u8, line);
        host.pending_output.append(host.allocator, saved) catch |err| {
            host.allocator.free(saved);
            return err;
        };
        return .{ .returned = try data.encode(allocator, .nil, 256) };
    }
};

fn field(value: data.Ref, name: []const u8) !data.Ref {
    return (try value.get(name)) orelse error.MissingField;
}

fn stateCapsule(allocator: std.mem.Allocator, count: i64, last_at: ?i64) !Capsule {
    return data.encode(allocator, .{ .hash = &.{
        .{ .key = .{ .string = "count" }, .value = .{ .integer = count } },
        .{ .key = .{ .string = "last_at" }, .value = if (last_at) |n| .{ .integer = n } else .nil },
    } }, contract.max_bytes);
}

fn inputCapsule(allocator: std.mem.Allocator, delta: i64, abort_after_prepare: bool) !Capsule {
    return data.encode(allocator, .{ .hash = &.{
        .{ .key = .{ .string = "delta" }, .value = .{ .integer = delta } },
        .{ .key = .{ .string = "abort_after_prepare" }, .value = .{ .boolean = abort_after_prepare } },
    } }, contract.max_bytes);
}

fn options() Turn.Options {
    var identity: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(contract.bootstrap_contract, &identity, .{});
    return .{
        .allowed = contract.grants,
        .bootstrap_identity = identity,
    };
}

fn request(state: View, input: View) Turn.Request {
    return .{ .receiver = "Counter", .state = state, .input = input };
}

fn prepare(allocator: std.mem.Allocator, host: *Host, input: View) !Turn.Prepared {
    const bindings = host.bindings();
    return Turn.prepare(allocator, manifest, "counter", contract.operations, request(host.state.view(), input), .{
        .bindings = &bindings,
        .transaction = host.transaction(),
    }, options());
}

fn countOf(allocator: std.mem.Allocator, state: View) !i64 {
    var document = try data.Document.decode(allocator, state, contract.max_bytes);
    defer document.deinit();
    return (try field(document.root(), "count")).asInteger();
}

pub fn verifyRecordReplay(allocator: std.mem.Allocator) !void {
    var host = try Host.init(allocator);
    defer host.deinit();
    var starting_state = try data.clone(allocator, host.state.view(), contract.max_bytes);
    defer starting_state.deinit(allocator);
    var input = try inputCapsule(allocator, 3, false);
    defer input.deinit(allocator);
    const input_before = try allocator.dupe(u8, input.encoded);
    defer allocator.free(input_before);
    var prepared = try prepare(allocator, &host, input.view());
    defer prepared.deinit();
    try testing.expectEqual(@as(i64, 7), try countOf(allocator, host.state.view()));
    try testing.expectEqual(@as(usize, 1), host.pending_intents.items.len);
    try testing.expectEqual(@as(usize, 1), host.pending_output.items.len);
    try testing.expectEqual(@as(usize, 0), host.intents.items.len);
    try testing.expectEqualSlices(u8, input_before, input.encoded);
    try prepared.commit();
    try testing.expectEqual(@as(i64, 10), try countOf(allocator, host.state.view()));
    try testing.expectEqual(@as(usize, 1), host.intents.items.len);
    try testing.expectEqualStrings("counter=10 at=1700000000", host.output.items[0]);
    const calls_before = host.calls;
    var replay = try Turn.replay(allocator, manifest, "counter", contract.operations, request(starting_state.view(), input.view()), prepared.receipt(), options());
    defer replay.deinit();
    try testing.expectEqualSlices(u8, prepared.terminal().bytes, replay.terminal().bytes);
    try testing.expectEqualDeep(calls_before, host.calls);
    // Replay verifies observations and the terminal pair. It does not commit
    // state, re-create host intents, or print the queued output.
    try testing.expectEqual(@as(usize, 1), host.commits);
    try testing.expectEqual(@as(usize, 1), host.intents.items.len);
    try testing.expectEqual(@as(usize, 1), host.output.items.len);
    var next = try prepare(allocator, &host, input.view());
    defer next.deinit();
    try next.commit();
    try testing.expectEqual(@as(i64, 13), try countOf(allocator, host.state.view()));
    try testing.expectEqual(@as(usize, 2), host.intents.items.len);
}

pub fn verifyRejection(allocator: std.mem.Allocator) !void {
    var host = try Host.init(allocator);
    defer host.deinit();
    var input = try inputCapsule(allocator, 200, false);
    defer input.deinit(allocator);
    var prepared = try prepare(allocator, &host, input.view());
    defer prepared.deinit();
    var document = try data.Document.decode(allocator, prepared.terminal(), contract.max_bytes);
    defer document.deinit();
    const result = try document.root().at(0);
    try testing.expectEqualStrings("rejected", try (try field(result, "status")).asString());
    try testing.expectEqualStrings("CounterLimit", try (try field(result, "code")).asString());
    try testing.expectEqualDeep(Calls{ .clock = 1, .intent = 1 }, host.calls);
    var replay = try Turn.replay(allocator, manifest, "counter", contract.operations, request(host.state.view(), input.view()), prepared.receipt(), options());
    defer replay.deinit();
    try testing.expectEqualSlices(u8, prepared.terminal().bytes, replay.terminal().bytes);
    try prepared.commit();
    try testing.expectEqual(@as(i64, 7), try countOf(allocator, host.state.view()));
    try testing.expectEqual(@as(usize, 0), host.intents.items.len);
    try testing.expectEqual(@as(usize, 0), host.output.items.len);
}

pub fn verifyDiscard(allocator: std.mem.Allocator) !void {
    var host = try Host.init(allocator);
    defer host.deinit();
    var input = try inputCapsule(allocator, 3, false);
    defer input.deinit(allocator);
    {
        var prepared = try prepare(allocator, &host, input.view());
        defer prepared.deinit();
        prepared.discard();
        prepared.discard();
        try testing.expectEqual(@as(usize, 1), host.discards);
    }
    {
        var abandoned = try prepare(allocator, &host, input.view());
        abandoned.deinit();
        try testing.expectEqual(@as(usize, 2), host.discards);
    }
    try testing.expectEqual(@as(i64, 7), try countOf(allocator, host.state.view()));
    try testing.expectEqual(@as(usize, 0), host.pending_intents.items.len);
    try testing.expectEqual(@as(usize, 0), host.pending_output.items.len);
    try testing.expectEqual(@as(usize, 0), host.commits);
}

pub fn verifyFailureDiscard(allocator: std.mem.Allocator) !void {
    var host = try Host.init(allocator);
    defer host.deinit();
    var input = try inputCapsule(allocator, 3, true);
    defer input.deinit(allocator);
    try testing.expectError(error.RubyException, prepare(allocator, &host, input.view()));
    try testing.expectEqualDeep(Calls{ .clock = 1, .intent = 1, .output = 1 }, host.calls);
    try testing.expectEqual(@as(i64, 7), try countOf(allocator, host.state.view()));
    try testing.expectEqual(@as(usize, 1), host.discards);
    try testing.expectEqual(@as(usize, 0), host.pending_intents.items.len);
    try testing.expectEqual(@as(usize, 0), host.pending_output.items.len);
    try testing.expectEqual(@as(usize, 0), host.commits);
}

pub fn verifyFreshVm(allocator: std.mem.Allocator) !void {
    var state = try stateCapsule(allocator, 7, null);
    defer state.deinit(allocator);
    var input = try inputCapsule(allocator, 3, false);
    defer input.deinit(allocator);
    for (0..2) |_| {
        var prepared = try Turn.prepare(allocator, manifest, "fresh_probe", .{}, .{
            .receiver = "FreshProbe",
            .state = state.view(),
            .input = input.view(),
        }, .{}, .{});
        defer prepared.deinit();
        var document = try data.Document.decode(allocator, prepared.terminal(), contract.max_bytes);
        defer document.deinit();
        try testing.expectEqual(@as(i64, 1), try (try document.root().at(0)).asInteger());
    }
}

pub fn verifyTerminalTampering(allocator: std.mem.Allocator) !void {
    var host = try Host.init(allocator);
    defer host.deinit();
    var input = try inputCapsule(allocator, 3, false);
    defer input.deinit(allocator);
    var prepared = try prepare(allocator, &host, input.view());
    defer prepared.deinit();
    const original = try Turn.Receipt.decode(prepared.receipt(), .{});
    // Both alternate receipts have valid framing and checksums. One changes
    // only the result; the other changes only the proposed next state.
    for ([_]?bool{ null, false, true }) |change_state| {
        var terminal = try data.encode(allocator, .{ .array = &.{
            .{ .hash = &.{
                .{ .key = .{ .string = "status" }, .value = .{ .string = "updated" } },
                .{ .key = .{ .string = "count" }, .value = .{ .integer = if (change_state == false) 11 else 10 } },
                .{ .key = .{ .string = "receipt" }, .value = .{ .integer = 1 } },
            } },
            .{ .hash = &.{
                .{ .key = .{ .string = "count" }, .value = .{ .integer = if (change_state == true) 11 else 10 } },
                .{ .key = .{ .string = "last_at" }, .value = .{ .integer = 1_700_000_000 } },
            } },
        } }, contract.max_bytes);
        defer terminal.deinit(allocator);
        if (change_state == null) {
            try testing.expectEqualSlices(u8, original.terminal.bytes, terminal.encoded);
            continue;
        }
        const changed = try Turn.Receipt.encode(allocator, original.trace, terminal.view(), .{});
        defer allocator.free(changed);
        var diagnostic: Turn.Diagnostic = .{};
        var replay_options = options();
        replay_options.diagnostic = &diagnostic;
        try testing.expectError(error.TerminalMismatch, Turn.replay(allocator, manifest, "counter", contract.operations, request(host.state.view(), input.view()), changed, replay_options));
        try testing.expectEqual(.terminal, diagnostic.kind);
        try testing.expect(diagnostic.expected_hash != null and diagnostic.actual_hash != null and diagnostic.byte_offset != null);
    }
    try testing.expectEqualDeep(Calls{ .clock = 1, .intent = 1, .output = 1 }, host.calls);
}

pub fn verifyRequestIdentity(allocator: std.mem.Allocator) !void {
    var host = try Host.init(allocator);
    defer host.deinit();
    var input = try inputCapsule(allocator, 3, false);
    defer input.deinit(allocator);
    var prepared = try prepare(allocator, &host, input.view());
    defer prepared.deinit();
    var changed_input = try inputCapsule(allocator, 4, false);
    defer changed_input.deinit(allocator);
    var changed_state = try stateCapsule(allocator, 8, null);
    defer changed_state.deinit(allocator);
    try testing.expectError(error.EffectTraceIdentityMismatch, Turn.replay(allocator, manifest, "counter", contract.operations, request(host.state.view(), changed_input.view()), prepared.receipt(), options()));
    try testing.expectError(error.EffectTraceIdentityMismatch, Turn.replay(allocator, manifest, "counter", contract.operations, request(changed_state.view(), input.view()), prepared.receipt(), options()));
    try testing.expectEqualDeep(Calls{ .clock = 1, .intent = 1, .output = 1 }, host.calls);
}

pub fn main(init: std.process.Init) !void {
    try verifyRecordReplay(init.gpa);
    try verifyRejection(init.gpa);
    try verifyDiscard(init.gpa);
    try verifyFailureDiscard(init.gpa);
    try verifyFreshVm(init.gpa);
    try verifyTerminalTampering(init.gpa);
    try verifyRequestIdentity(init.gpa);
    std.debug.print("strict turns: counter 7 -> 10 -> 13; explicit commit retained state, intent and queued output\n", .{});
    std.debug.print("strict turns: replay matched result + next state without handlers; rejected/aborted/abandoned turns verified\n", .{});
    std.debug.print("strict turns: changed result/state and request identity rejected; each call owns a fresh VM\n", .{});
}
