const std = @import("std");
const mruby = @import("mruby");
const effect = mruby.effect;
const testing = std.testing;

const operations = [_]effect.Operation{
    .{ .name = "store.reserve", .namespace = "Store", .method = "reserve", .arity = 1, .authority_bits = 1 << 13, .max_result_bytes = 2048 },
};
const invocation: effect.Invocation = .{
    .code = @splat(1),
    .bootstrap = @splat(2),
    .state = @splat(3),
    .receiver = "inventory/one",
};
const application =
    \\class Workflow
    \\  def self.reserve(amount)
    \\    begin
    \\      ["reserved", Effect.perform(Store.reserve(amount))]
    \\    rescue Effect::Rejected => failure
    \\      ["unavailable", failure.code, failure.message]
    \\    end
    \\  end
    \\  def self.reraise_rejection(amount)
    \\    original = nil
    \\    cleaned = false
    \\    begin
    \\      begin
    \\        Effect.perform(Store.reserve(amount))
    \\      rescue Effect::Rejected => original
    \\        raise original
    \\      ensure
    \\        cleaned = true
    \\      end
    \\    rescue Exception => caught
    \\      [caught.equal?(original), caught.code, caught.message, cleaned]
    \\    end
    \\  end
    \\  def self.unhandled(amount)
    \\    Effect.perform(Store.reserve(amount))
    \\  end
    \\  def self.rescue_all(amount)
    \\    begin
    \\      Effect.perform(Store.reserve(amount))
    \\    rescue
    \\      "rescued"
    \\    end
    \\  end
    \\  def self.mutate(left, right)
    \\    left[0].replace("changed")
    \\    right[0]
    \\  end
    \\  def self.identity(value)
    \\    $entered = true
    \\    value
    \\  end
    \\end
;
const Context = struct {
    units: i64 = 3,
    calls: usize = 0,
    fail: bool = false,
    malformed: bool = false,
    shared_outcome: ?enum { returned, rejected } = null,
    fn reserve(raw: ?*anyopaque, vm: *mruby.Vm, arguments: mruby.Value) anyerror!effect.Outcome {
        const self: *Context = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        if (self.shared_outcome) |kind| {
            const shared = try vm.getGlobal("shared");
            return switch (kind) {
                .returned => .{ .returned = shared },
                .rejected => .{ .rejected = (try vm.array(&.{ shared, try vm.stringValue("shared rejection") })).asValue() },
            };
        }
        if (self.fail) return error.IndeterminateCommit;
        if (self.malformed) return .{ .rejected = try vm.intValue(12) };
        const amount = try (try (try arguments.asArray()).get(0)).asInt();
        if (amount > self.units) return effect.reject(vm, "OutOfStock", "Not enough stock");
        self.units -= amount;
        return .{ .returned = try vm.intValue(self.units) };
    }
};
const Fixture = struct {
    iso: mruby.sandbox.Isolate,
    receiver: mruby.Value,
    unsupported: mruby.Value,
    fn deinit(self: Fixture) void {
        self.iso.deinit();
    }
};
const Options = struct {
    mode: effect.Mode = .live,
    input: [32]u8 = @splat(0),
    limits: effect.Limits = .{},
    allowed: bool = true,
    bind: bool = true,
};
fn fixture(context: *Context, options: Options) !Fixture {
    var boot = try mruby.sandbox.BootstrapIsolate.spawn(mruby.sandbox.Policy.restricted(.{
        .limits = .{ .gas = .{ .per_execution = 20_000 } },
    }));
    defer boot.deinit();
    _ = try boot.vm().loadString(application);
    const unsupported = try boot.vm().loadString("$unsupported = Object.new");
    const receiver = (try boot.vm().getClass("Workflow")).asValue();
    const bindings = [_]effect.Binding{.{ .name = "store.reserve", .outcome_handler = Context.reserve, .context = context }};
    try effect.install(boot.vm(), operations, .{
        .allowed = if (options.allowed) &.{"store.reserve"} else &.{},
        .bindings = if (options.bind) &bindings else &.{},
        .mode = options.mode,
        .input_identity = options.input,
        .limits = options.limits,
    });
    return .{ .iso = try boot.seal(), .receiver = receiver, .unsupported = unsupported };
}

test "handler results and rejection codes are detached consistently in live record and replay" {
    const cases = .{
        .{
            .kind = .returned,
            .source = "$shared = ['original']; result = Effect.perform(Store.reserve(1)); result[0].replace('changed'); $shared[0]",
        },
        .{
            .kind = .rejected,
            .source = "$shared = 'original'; begin; Effect.perform(Store.reserve(1)); rescue Effect::Rejected => failure; failure.code.replace('changed'); end; $shared",
        },
    };
    inline for (cases) |case| {
        const bytes = blk: {
            var context: Context = .{ .shared_outcome = case.kind };
            const f = try fixture(&context, .{ .mode = .record });
            defer f.deinit();
            try testing.expectEqualStrings("original", try (try f.iso.run(case.source)).asString());
            var trace = try f.iso.takeEffectTrace();
            defer trace.deinit();
            break :blk try trace.encode(testing.allocator);
        };
        defer testing.allocator.free(bytes);
        var live_context: Context = .{ .shared_outcome = case.kind };
        const live = try fixture(&live_context, .{});
        defer live.deinit();
        try testing.expectEqualStrings("original", try (try live.iso.run(case.source)).asString());
        var replay_context: Context = .{ .fail = true };
        const replay = try fixture(&replay_context, .{ .mode = .{ .replay = bytes } });
        defer replay.deinit();
        try testing.expectEqualStrings("original", try (try replay.iso.run(case.source)).asString());
        try testing.expectEqual(@as(usize, 0), replay_context.calls);
    }
}

test "identified calls record returned and rescued rejected outcomes across fresh VMs" {
    for ([_]i64{ 2, 8 }) |amount| {
        const bytes = blk: {
            var context: Context = .{};
            const f = try fixture(&context, .{ .mode = .record });
            defer f.deinit();
            const result = try (try f.iso.callWithEffects(f.receiver, "reserve", .{amount}, invocation)).asArray();
            try testing.expectEqualStrings(if (amount == 2) "reserved" else "unavailable", try (try result.get(0)).asString());
            if (amount == 8) {
                try testing.expectEqualStrings("OutOfStock", try (try result.get(1)).asString());
                try testing.expectEqualStrings("Not enough stock", try (try result.get(2)).asString());
            }
            try testing.expectEqual(@as(usize, 1), context.calls);
            var trace = try f.iso.takeEffectTrace();
            defer trace.deinit();
            try testing.expect(trace.isComplete());
            try testing.expectEqual(@as(usize, 1), trace.len());
            if (amount == 2) {
                try testing.expect(trace.get(0).?.outcome == .returned);
            } else {
                try testing.expect(trace.get(0).?.outcome == .rejected);
            }
            break :blk try trace.encode(testing.allocator);
        };
        defer testing.allocator.free(bytes);
        var unused: Context = .{ .units = 999, .fail = true };
        const replay = try fixture(&unused, .{ .mode = .{ .replay = bytes }, .bind = false });
        defer replay.deinit();
        const result = try (try replay.iso.callWithEffects(replay.receiver, "reserve", .{amount}, invocation)).asArray();
        try testing.expectEqualStrings(if (amount == 2) "reserved" else "unavailable", try (try result.get(0)).asString());
        if (amount == 2) {
            try testing.expectEqual(@as(i64, 1), try (try result.get(1)).asInt());
        } else {
            try testing.expectEqualStrings("OutOfStock", try (try result.get(1)).asString());
            try testing.expectEqualStrings("Not enough stock", try (try result.get(2)).asString());
        }
        try testing.expectEqual(@as(usize, 0), unused.calls);
    }
}

test "unrescued rejection invalidates the outer trace and a later invocation works" {
    var context: Context = .{};
    const f = try fixture(&context, .{ .mode = .record });
    defer f.deinit();
    try testing.expectError(error.RubyException, f.iso.callWithEffects(f.receiver, "unhandled", .{8}, invocation));
    var failed = try f.iso.takeEffectTrace();
    defer failed.deinit();
    try testing.expect(!failed.isComplete());
    try testing.expect(failed.get(0).?.outcome == .rejected);
    try testing.expectError(error.IncompleteTrace, failed.encode(testing.allocator));
    _ = try f.iso.callWithEffects(f.receiver, "reserve", .{8}, invocation);
    var recovered = try f.iso.takeEffectTrace();
    defer recovered.deinit();
    try testing.expect(recovered.isComplete());
}

test "raw handler errors invalid rejection payloads and denied effects remain fatal under rescue" {
    var context: Context = .{ .fail = true };
    const f = try fixture(&context, .{ .mode = .record });
    defer f.deinit();
    try testing.expectError(error.EffectHandlerFailed, f.iso.callWithEffects(f.receiver, "rescue_all", .{1}, invocation));
    var failed = try f.iso.takeEffectTrace();
    defer failed.deinit();
    try testing.expect(!failed.isComplete());
    context.fail = false;
    context.malformed = true;
    try testing.expectError(error.InvalidEffectRequest, f.iso.callWithEffects(f.receiver, "rescue_all", .{1}, invocation));
    try testing.expectEqual(effect.Diagnostic.Reason.invalid_result, (try f.iso.effectDiagnostic()).?.reason);
    var invalid = try f.iso.takeEffectTrace();
    defer invalid.deinit();
    try testing.expect(!invalid.isComplete());
    var denied_context: Context = .{};
    const denied = try fixture(&denied_context, .{ .mode = .record, .allowed = false });
    defer denied.deinit();
    try testing.expectError(error.EffectDenied, denied.iso.callWithEffects(denied.receiver, "rescue_all", .{1}, invocation));
    try testing.expectEqual(@as(usize, 0), denied_context.calls);
}

fn recordedCall() ![]u8 {
    var context: Context = .{};
    const f = try fixture(&context, .{ .mode = .record });
    defer f.deinit();
    _ = try f.iso.callWithEffects(f.receiver, "reserve", .{2}, invocation);
    var trace = try f.iso.takeEffectTrace();
    defer trace.deinit();
    return trace.encode(testing.allocator);
}

test "identified replay rejects changed code bootstrap receiver method state and actual arguments before gas renewal" {
    const bytes = try recordedCall();
    defer testing.allocator.free(bytes);
    var context: Context = .{};
    const f = try fixture(&context, .{ .mode = .{ .replay = bytes } });
    defer f.deinit();
    // First consume successfully, so rejection must preserve real statistics.
    _ = try f.iso.callWithEffects(f.receiver, "reserve", .{2}, invocation);
    const before = f.iso.stats().gas.?;
    for (0..6) |variant| {
        var changed = invocation;
        var method: []const u8 = "reserve";
        switch (variant) {
            0 => changed.code[0] ^= 1,
            1 => changed.bootstrap[0] ^= 1,
            2 => changed.receiver = "inventory/two",
            3 => method = "unhandled",
            4 => changed.state[0] ^= 1,
            else => {},
        }
        const amount: i64 = if (variant == 5) 3 else 2;
        try testing.expectError(error.EffectTraceIdentityMismatch, f.iso.callWithEffects(f.receiver, method, .{amount}, changed));
        const detail = (try f.iso.effectDiagnostic()).?;
        try testing.expectEqual(if (variant < 4) effect.Diagnostic.Reason.identity_code else .identity_input, detail.reason);
        try testing.expect(detail.expected_hash != null and detail.actual_hash != null);
        try testing.expect(!std.mem.eql(u8, &detail.expected_hash.?, &detail.actual_hash.?));
        try testing.expectEqualDeep(before, f.iso.stats().gas.?);
    }
    const saved = (try f.iso.effectDiagnostic()).?;
    _ = try f.iso.callWithEffects(f.receiver, "reserve", .{2}, invocation);
    try testing.expect((try f.iso.effectDiagnostic()) == null);
    try testing.expectEqual(effect.Diagnostic.Reason.identity_input, saved.reason);
    try testing.expectEqual(@as(usize, 0), context.calls);

    var other: Context = .{};
    const different_config = try fixture(&other, .{ .mode = .{ .replay = bytes }, .input = @splat(7) });
    defer different_config.deinit();
    try testing.expectError(error.EffectTraceIdentityMismatch, different_config.iso.callWithEffects(different_config.receiver, "reserve", .{2}, invocation));
    try testing.expectEqual(effect.Diagnostic.Reason.identity_input, (try different_config.iso.effectDiagnostic()).?.reason);
    try testing.expectEqual(@as(u64, 0), different_config.iso.stats().gas.?.generation);
}

test "identified calls snapshot actual argument graphs and preserve aliases without mutating host inputs" {
    var context: Context = .{};
    const f = try fixture(&context, .{ .mode = .record });
    defer f.deinit();
    const original = try f.iso.array(&.{try f.iso.stringValue("original")});
    const result = try f.iso.callWithEffects(f.receiver, "mutate", .{ original, original }, invocation);
    try testing.expectEqualStrings("changed", try result.asString());
    try testing.expectEqualStrings("original", try (try original.get(0)).asString());
    var trace = try f.iso.takeEffectTrace();
    defer trace.deinit();
    try testing.expect(trace.isComplete());
    try testing.expectEqual(@as(usize, 0), trace.len());
}

test "invalid invocation arguments reject before Ruby preserving gas and retained complete trace" {
    var context: Context = .{};
    const f = try fixture(&context, .{ .mode = .record, .limits = .{ .max_request_bytes = 512 } });
    defer f.deinit();
    _ = try f.iso.callWithEffects(f.receiver, "reserve", .{2}, invocation);
    const before = f.iso.stats().gas.?;
    var invalid = invocation;
    invalid.receiver = "";
    try testing.expectError(error.InvalidEffectInvocation, f.iso.callWithEffects(f.receiver, "identity", .{1}, invalid));
    try testing.expectError(error.InvalidEffectInvocation, f.iso.callWithEffects(f.receiver, "bad\x00name", .{1}, invocation));
    try testing.expectError(error.UnsupportedValue, f.iso.callWithEffects(f.receiver, "identity", .{f.unsupported}, invocation));
    try testing.expectError(error.UnsupportedValue, f.iso.callWithEffects(f.receiver, "identity", .{f.receiver.v}, invocation));
    try testing.expectError(error.EffectLimitExceeded, f.iso.callWithEffects(f.receiver, "identity", .{@as([]const u8, &(@as([600]u8, @splat('x'))))}, invocation));
    var other_context: Context = .{};
    const other = try fixture(&other_context, .{});
    defer other.deinit();
    const foreign = try other.iso.stringValue("foreign");
    try testing.expectError(error.ForeignValue, f.iso.callWithEffects(f.receiver, "identity", .{foreign}, invocation));
    try testing.expectError(error.ForeignValue, f.iso.callWithEffects(other.receiver, "identity", .{1}, invocation));
    try testing.expectEqualDeep(before, f.iso.stats().gas.?);
    try testing.expect((try f.iso.getGlobal("entered")).isNil());
    var retained = try f.iso.takeEffectTrace();
    defer retained.deinit();
    try testing.expect(retained.isComplete());
    try testing.expectEqual(@as(usize, 1), retained.len());
}

fn checkReraisedRejection(value: mruby.Value) !void {
    const fields = try value.asArray();
    try testing.expect((try fields.get(0)).isTruthy());
    try testing.expectEqualStrings("OutOfStock", try (try fields.get(1)).asString());
    try testing.expectEqualStrings("Not enough stock", try (try fields.get(2)).asString());
    try testing.expect((try fields.get(3)).isTruthy());
}

test "explicit reraising preserves a rejection object and ensure in live record and replay" {
    var live_context: Context = .{};
    const live = try fixture(&live_context, .{});
    defer live.deinit();
    try checkReraisedRejection(try live.iso.callWithEffects(live.receiver, "reraise_rejection", .{8}, invocation));
    try testing.expectEqual(@as(usize, 1), live_context.calls);
    const bytes = blk: {
        var context: Context = .{};
        const record = try fixture(&context, .{ .mode = .record });
        defer record.deinit();
        try checkReraisedRejection(try record.iso.callWithEffects(record.receiver, "reraise_rejection", .{8}, invocation));
        try testing.expectEqual(@as(usize, 1), context.calls);
        var trace = try record.iso.takeEffectTrace();
        defer trace.deinit();
        try testing.expect(trace.isComplete());
        break :blk try trace.encode(testing.allocator);
    };
    defer testing.allocator.free(bytes);
    var replay_context: Context = .{ .fail = true };
    const replay = try fixture(&replay_context, .{ .mode = .{ .replay = bytes }, .bind = false });
    defer replay.deinit();
    try checkReraisedRejection(try replay.iso.callWithEffects(replay.receiver, "reraise_rejection", .{8}, invocation));
    try testing.expectEqual(@as(usize, 0), replay_context.calls);
}
