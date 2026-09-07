const std = @import("std");
const mruby = @import("mruby");
const effect = mruby.effect;
const testing = std.testing;

test {
    _ = @import("effect_invocation_tests.zig");
    _ = @import("effect_allocation_tests.zig");
    _ = @import("effect_contract_tests.zig");
}

const operations = [_]effect.Operation{
    .{ .name = "clock.now", .namespace = "Clock", .method = "now", .arity = 0, .authority_bits = 1 << 4, .max_result_bytes = 256 },
    .{ .name = "sink.write", .namespace = "Sink", .method = "write", .arity = 1, .authority_bits = 1 << 13, .max_result_bytes = 1024 },
};
const all = &.{ "clock.now", "sink.write" };
const Context = struct {
    reads: usize = 0,
    writes: usize = 0,
    fail_write: bool = false,
    nested: bool = false,
    terminate: bool = false,
    invalid_result: bool = false,
    iso: ?mruby.sandbox.Isolate = null,
    fn clock(context: ?*anyopaque, vm: *mruby.Vm, _: mruby.Value) anyerror!mruby.Value {
        const self: *Context = @ptrCast(@alignCast(context.?));
        self.reads += 1;
        return vm.intValue(42);
    }
    fn write(context: ?*anyopaque, vm: *mruby.Vm, args: mruby.Value) anyerror!mruby.Value {
        const self: *Context = @ptrCast(@alignCast(context.?));
        self.writes += 1;
        if (self.fail_write) return error.DeliveryIndeterminate;
        if (self.invalid_result) return vm.loadString("Object.new");
        if (self.terminate) self.iso.?.terminate();
        if (self.nested) {
            _ = vm.loadString("begin; Effect.perform(Clock.now); rescue; 1; end") catch {};
        }
        return (try args.asArray()).get(0);
    }
};
const Options = struct {
    mode: effect.Mode = .live,
    allowed: []const []const u8 = all,
    limits: effect.Limits = .{},
    input: [32]u8 = @splat(0),
    bind: bool = true,
    gas: mruby.sandbox.GasPolicy = .unlimited,
};
fn spawn(context: *Context, options: Options) !mruby.sandbox.Isolate {
    var boot = try mruby.sandbox.BootstrapIsolate.spawn(mruby.sandbox.Policy.restricted(.{
        .limits = .{ .gas = options.gas },
    }));
    defer boot.deinit();
    const bindings = [_]effect.Binding{
        .{ .name = "clock.now", .handler = Context.clock, .context = context },
        .{ .name = "sink.write", .handler = Context.write, .context = context },
    };
    try effect.install(boot.vm(), operations, .{
        .allowed = options.allowed,
        .bindings = if (options.bind) &bindings else &.{},
        .mode = options.mode,
        .limits = options.limits,
        .input_identity = options.input,
    });
    const iso = try boot.seal();
    context.iso = iso;
    return iso;
}

test "requests are inert immutable snapshots with inspectable identity" {
    var context: Context = .{};
    const iso = try spawn(&context, .{});
    defer iso.deinit();
    const result = try iso.run(
        \\payload = ["before"]
        \\request = Sink.write(payload)
        \\payload[0] = "after"
        \\request.arguments[0][0] = "tampered"
        \\$request = request
        \\[request.name, request.version, request.arguments[0][0]]
    );
    const fields = try result.asArray();
    try testing.expectEqualStrings("sink.write", try (try fields.get(0)).asString());
    try testing.expectEqual(@as(i64, 1), try (try fields.get(1)).asInt());
    try testing.expectEqualStrings("before", try (try fields.get(2)).asString());
    try testing.expectEqual(@as(usize, 0), context.writes);
    const performed = try iso.run("Effect.perform($request)[0]");
    try testing.expectEqualStrings("before", try performed.asString());
    try testing.expectEqual(@as(usize, 1), context.writes);
    _ = try iso.run("Effect.perform($request)");
    try testing.expectEqual(@as(usize, 2), context.writes);
}

test "registration does not grant effects and rescued denials stay failed" {
    var context: Context = .{};
    const iso = try spawn(&context, .{ .allowed = &.{"clock.now"}, .mode = .record });
    defer iso.deinit();
    try testing.expectError(error.EffectDenied, iso.run("begin; Effect.perform(Sink.write(1)); rescue; 99; end"));
    try testing.expectEqual(@as(usize, 0), context.writes);
    var trace = try iso.takeEffectTrace();
    defer trace.deinit();
    try testing.expect(!trace.isComplete());
    try testing.expectError(error.IncompleteTrace, trace.encode(testing.allocator));
    try testing.expectError(error.EffectDenied, iso.run("Effect.perform(Sink.write(1))"));
    const diagnostic = try iso.lastError().?.message(testing.allocator);
    defer testing.allocator.free(diagnostic);
    try testing.expect(std.mem.indexOf(u8, diagnostic, "sink.write") != null);
    try testing.expectEqual(@as(i64, 42), try (try iso.run("Effect.perform(Clock.now)")).asInt());
}

test "unknown forged and unhandled requests fail without host activity" {
    var context: Context = .{};
    const iso = try spawn(&context, .{ .bind = false });
    defer iso.deinit();
    try testing.expectError(error.InvalidEffectRequest, iso.run("Effect.perform(:clock_now)"));
    try testing.expectError(error.EffectUnhandled, iso.run("Effect.perform(Clock.now)"));
    try testing.expectError(error.RubyException, iso.run("Effect.new"));
    try testing.expectError(error.RubyException, iso.run("Clock.now.dup"));
    try testing.expectEqual(@as(usize, 0), context.reads);
}

test "ambient operations and request namespace replacement are closed" {
    var context: Context = .{};
    const iso = try spawn(&context, .{});
    defer iso.deinit();
    for ([_][]const u8{
        "puts 'bypass'", "Kernel.print('bypass')", "rand",         "Time.now",              "Time.new",
        "Random.rand",   "Random.bytes(16)",       "[1,2].sample", "def Clock.now; 7; end", "def Effect.perform(x); 7; end",
    }) |source| try testing.expectError(error.RubyException, iso.run(source));
    try testing.expectEqual(@as(i64, 42), try (try iso.run("Effect.perform(Clock.now)")).asInt());
}

const program = "[Effect.perform(Clock.now), Effect.perform(Sink.write($payload))]";
fn recorded() !effect.Trace {
    var context: Context = .{};
    const iso = try spawn(&context, .{ .mode = .record });
    defer iso.deinit();
    try iso.setGlobal("payload", try iso.stringValue("hello"));
    _ = try iso.run(program);
    return iso.takeEffectTrace();
}

test "trace survives VM destruction and replay invokes no live handlers" {
    var trace = try recorded();
    defer trace.deinit();
    try testing.expect(trace.isComplete());
    try testing.expectEqual(@as(usize, 2), trace.len());
    const bytes = try trace.encode(testing.allocator);
    defer testing.allocator.free(bytes);
    var context: Context = .{};
    const iso = try spawn(&context, .{ .mode = .{ .replay = bytes } });
    defer iso.deinit();
    try iso.setGlobal("payload", try iso.stringValue("hello"));
    const result = try (try iso.run(program)).asArray();
    try testing.expectEqual(@as(i64, 42), try (try result.get(0)).asInt());
    try testing.expectEqualStrings("hello", try (try result.get(1)).asString());
    try testing.expectEqual(@as(usize, 0), context.reads + context.writes);
}

test "replay rejects code input and argument mismatches before live operations" {
    var trace = try recorded();
    defer trace.deinit();
    const bytes = try trace.encode(testing.allocator);
    defer testing.allocator.free(bytes);
    var context: Context = .{};
    const iso = try spawn(&context, .{ .mode = .{ .replay = bytes } });
    defer iso.deinit();
    try testing.expectError(error.EffectTraceIdentityMismatch, iso.run("Effect.perform(Clock.now)"));
    try iso.setGlobal("payload", try iso.stringValue("changed"));
    try testing.expectError(error.EffectReplayMismatch, iso.run(program));
    const detail = (try iso.effectDiagnostic()).?;
    try testing.expectEqual(effect.Diagnostic.Reason.arguments, detail.reason);
    try testing.expectEqual(@as(usize, 1), detail.record_index);
    try testing.expectEqualStrings("sink.write", detail.expectedOperation());
    try testing.expectEqualStrings("sink.write", detail.actualOperation());
    try testing.expect(detail.argument_byte_offset != null);
    try testing.expect(!std.mem.eql(u8, &detail.expected_hash.?, &detail.actual_hash.?));
    var other: Context = .{};
    const wrong_input = try spawn(&other, .{ .mode = .{ .replay = bytes }, .input = @splat(7) });
    defer wrong_input.deinit();
    try testing.expectError(error.EffectTraceIdentityMismatch, wrong_input.run(program));
    try testing.expectEqual(@as(usize, 0), context.reads + context.writes + other.reads);
}

fn rewritten(original: *const effect.Trace, indices: []const usize) ![]u8 {
    var trace = effect.Trace.init(testing.allocator, original.identity, .{});
    defer trace.deinit();
    for (indices) |index| {
        const record = original.get(index).?;
        try trace.reserve(record.name, record.version, record.arguments, record.result.len);
        try trace.commit(record.result);
    }
    try trace.finish();
    return trace.encode(testing.allocator);
}

test "replay rejects reordered missing and extra records" {
    var original = try recorded();
    defer original.deinit();
    for ([_][]const usize{ &.{ 1, 0 }, &.{0}, &.{ 0, 1, 0 } }) |indices| {
        const bytes = try rewritten(&original, indices);
        defer testing.allocator.free(bytes);
        var context: Context = .{};
        const iso = try spawn(&context, .{ .mode = .{ .replay = bytes } });
        defer iso.deinit();
        try iso.setGlobal("payload", try iso.stringValue("hello"));
        try testing.expectError(error.EffectReplayMismatch, iso.run(program));
        const detail = (try iso.effectDiagnostic()).?;
        if (indices.len == 2) {
            try testing.expectEqual(effect.Diagnostic.Reason.operation, detail.reason);
            try testing.expectEqual(@as(usize, 0), detail.record_index);
            try testing.expectEqualStrings("sink.write", detail.expectedOperation());
            try testing.expectEqualStrings("clock.now", detail.actualOperation());
        } else if (indices.len == 1) {
            try testing.expectEqual(effect.Diagnostic.Reason.extra_record, detail.reason);
            try testing.expectEqual(@as(usize, 1), detail.record_index);
            try testing.expectEqualStrings("", detail.expectedOperation());
            try testing.expectEqualStrings("sink.write", detail.actualOperation());
        } else {
            try testing.expectEqual(effect.Diagnostic.Reason.missing_record, detail.reason);
            try testing.expectEqual(@as(usize, 2), detail.record_index);
            try testing.expectEqualStrings("clock.now", detail.expectedOperation());
            try testing.expectEqualStrings("", detail.actualOperation());
        }
        try testing.expectEqual(@as(usize, 0), context.reads + context.writes);
    }
}

test "replay diagnostics distinguish operation version invalid result and catalogue identity" {
    var original = try recorded();
    defer original.deinit();
    for (0..3) |variant| {
        var identity = original.identity;
        if (variant == 2) identity.catalogue[0] ^= 1;
        var changed = effect.Trace.init(testing.allocator, identity, .{});
        defer changed.deinit();
        for (0..original.len()) |index| {
            const record = original.get(index).?;
            const version = record.version + @as(u32, if (variant == 0 and index == 0) 1 else 0);
            const result = if (variant == 1 and index == 0) "invalid result" else record.result;
            try changed.reserve(record.name, version, record.arguments, result.len);
            try changed.commit(result);
        }
        try changed.finish();
        const bytes = try changed.encode(testing.allocator);
        defer testing.allocator.free(bytes);
        var context: Context = .{};
        const iso = try spawn(&context, .{ .mode = .{ .replay = bytes } });
        defer iso.deinit();
        try iso.setGlobal("payload", try iso.stringValue("hello"));
        if (variant == 0) {
            try testing.expectError(error.EffectReplayMismatch, iso.run(program));
        } else if (variant == 1) {
            try testing.expectError(error.InvalidEffectRequest, iso.run(program));
        } else {
            try testing.expectError(error.EffectTraceIdentityMismatch, iso.run(program));
        }
        const detail = (try iso.effectDiagnostic()).?;
        try testing.expectEqual(switch (variant) {
            0 => effect.Diagnostic.Reason.version,
            1 => .invalid_result,
            else => .identity_catalogue,
        }, detail.reason);
        if (variant == 0) {
            try testing.expectEqual(@as(?u32, 2), detail.expected_version);
            try testing.expectEqual(@as(?u32, 1), detail.actual_version);
        }
        try testing.expectEqual(@as(usize, 0), context.reads + context.writes);
    }
}

test "handler failure and nested effects cannot be rescued into a valid trace" {
    var context: Context = .{ .fail_write = true };
    const iso = try spawn(&context, .{ .mode = .record });
    defer iso.deinit();
    const source = "begin; Effect.perform(Sink.write(5)); rescue; 8; ensure; $cleaned = true; end";
    try testing.expectError(error.EffectHandlerFailed, iso.run(source));
    try testing.expect((try iso.getGlobal("cleaned")).isTruthy());
    var trace = try iso.takeEffectTrace();
    defer trace.deinit();
    try testing.expect(!trace.isComplete());
    context.fail_write = false;
    context.nested = true;
    try testing.expectError(error.EffectReentry, iso.run(source));
    try testing.expectEqual(@as(usize, 0), context.reads);
    context.nested = false;
    try testing.expectEqual(@as(i64, 5), try (try iso.run(source)).asInt());
}

test "trace reservation and occurrence limits reject before handler" {
    var context: Context = .{};
    const tiny = try spawn(&context, .{ .mode = .record, .limits = .{ .max_bytes = 300 } });
    defer tiny.deinit();
    try testing.expectError(error.EffectLimitExceeded, tiny.run("Effect.perform(Clock.now)"));
    try testing.expectEqual(@as(usize, 0), context.reads);
    const one = try spawn(&context, .{ .limits = .{ .max_records = 1 } });
    defer one.deinit();
    try testing.expectError(error.EffectLimitExceeded, one.run("request = Clock.now; Effect.perform(request); Effect.perform(request)"));
    try testing.expectEqual(@as(usize, 1), context.reads);
}

test "gas exhaustion cleans trace and the next renewable execution works" {
    var context: Context = .{};
    const iso = try spawn(&context, .{ .mode = .record, .gas = .{ .per_execution = 2000 } });
    defer iso.deinit();
    try testing.expectError(error.GasExhausted, iso.run("Effect.perform(Clock.now); while true; end"));
    var incomplete = try iso.takeEffectTrace();
    defer incomplete.deinit();
    try testing.expect(!incomplete.isComplete());
    try testing.expectEqual(@as(i64, 42), try (try iso.run("Effect.perform(Clock.now)")).asInt());
    var complete = try iso.takeEffectTrace();
    defer complete.deinit();
    try testing.expect(complete.isComplete());
}

test "termination prevents another native operation during ensure" {
    var context: Context = .{ .terminate = true };
    const iso = try spawn(&context, .{ .mode = .record });
    defer iso.deinit();
    try testing.expectError(error.ScriptTerminated, iso.run(
        "begin; Effect.perform(Sink.write(1)); ensure; Effect.perform(Clock.now); end",
    ));
    try testing.expectEqual(@as(usize, 1), context.writes);
    try testing.expectEqual(@as(usize, 0), context.reads);
    var trace = try iso.takeEffectTrace();
    defer trace.deinit();
    try testing.expect(!trace.isComplete());
}

test "source and typed CodeDB-style RITE share operation semantics" {
    var image = try mruby.sandbox.compileRite(testing.allocator, "Effect.perform(Clock.now)", .{});
    defer image.deinit(testing.allocator);
    var a: Context = .{};
    var b: Context = .{};
    const source = try spawn(&a, .{});
    defer source.deinit();
    const compiled = try spawn(&b, .{});
    defer compiled.deinit();
    try testing.expectEqual(try (try source.run("Effect.perform(Clock.now)")).asInt(), try (try compiled.runRite(image.view())).asInt());
}

test "recording an outer method call requires an identified code entry" {
    var context: Context = .{};
    const iso = try spawn(&context, .{ .mode = .record });
    defer iso.deinit();
    const input = try iso.stringValue("hello");
    try testing.expectError(error.EffectTraceRequiresCodeIdentity, iso.call(input, "upcase", .{}));
    try testing.expectEqualStrings("HELLO", try (try iso.run("'hello'.upcase")).asString());
}

test "malformed dispatch and invalid handler results invalidate recording" {
    var context: Context = .{ .invalid_result = true };
    const iso = try spawn(&context, .{ .mode = .record });
    defer iso.deinit();
    try testing.expectError(error.InvalidEffectRequest, iso.run("begin; Effect.perform; rescue; 1; end"));
    var malformed = try iso.takeEffectTrace();
    defer malformed.deinit();
    try testing.expect(!malformed.isComplete());
    try testing.expectError(error.InvalidEffectRequest, iso.run("begin; Effect.perform(Sink.write(1)); rescue; 2; end"));
    var invalid_result = try iso.takeEffectTrace();
    defer invalid_result.deinit();
    try testing.expectEqual(@as(usize, 1), context.writes);
    try testing.expect(!invalid_result.isComplete());
}

test "native arguments and retained request storage are bounded before handlers" {
    var context: Context = .{};
    const iso = try spawn(&context, .{ .limits = .{ .max_records = 2, .max_request_bytes = 512 } });
    defer iso.deinit();
    try testing.expectError(error.RubyException, iso.run("Sink.write(Object.new)"));
    try testing.expectError(error.RubyException, iso.run("Sink.write('x' * 1024)"));
    try testing.expectError(error.RubyException, iso.run("$held = [Clock.now, Clock.now]; Clock.now"));
    try testing.expectEqual(@as(usize, 0), context.reads + context.writes);
}

test "malformed transcript is rejected during installation without guest activity" {
    var context: Context = .{};
    try testing.expectError(error.InvalidTrace, spawn(&context, .{ .mode = .{ .replay = "truncated" } }));
    try testing.expectEqual(@as(usize, 0), context.reads + context.writes);
}

test "rescued replay mismatch remains a host-visible failure" {
    const source = "begin; Effect.perform(Sink.write($payload)); rescue; 1; end";
    var recorder: Context = .{};
    const original = try spawn(&recorder, .{ .mode = .record });
    defer original.deinit();
    try original.setGlobal("payload", try original.intValue(1));
    _ = try original.run(source);
    var trace = try original.takeEffectTrace();
    defer trace.deinit();
    const bytes = try trace.encode(testing.allocator);
    defer testing.allocator.free(bytes);
    var replayer: Context = .{};
    const replay = try spawn(&replayer, .{ .mode = .{ .replay = bytes } });
    defer replay.deinit();
    try replay.setGlobal("payload", try replay.intValue(2));
    try testing.expectError(error.EffectReplayMismatch, replay.run(source));
    try testing.expectEqual(@as(usize, 0), replayer.writes);
}

test "installed grants and handler bindings are snapshots of configuration" {
    var context: Context = .{};
    var boot = try mruby.sandbox.BootstrapIsolate.spawn(mruby.sandbox.Policy.restricted(.{}));
    defer boot.deinit();
    var allowed = [_][]const u8{"clock.now"};
    var bindings = [_]effect.Binding{.{ .name = "clock.now", .handler = Context.clock, .context = &context }};
    try effect.install(boot.vm(), operations, .{ .allowed = &allowed, .bindings = &bindings });
    allowed[0] = "sink.write";
    bindings[0].context = null;
    const iso = try boot.seal();
    defer iso.deinit();
    try testing.expectEqual(@as(i64, 42), try (try iso.run("Effect.perform(Clock.now)")).asInt());
    try testing.expectError(error.EffectDenied, iso.run("Effect.perform(Sink.write(1))"));
    try testing.expectEqual(@as(usize, 1), context.reads);
    try testing.expectEqual(@as(usize, 0), context.writes);
}

test "policy clock pinning cannot reopen ambient effects and descriptor defaults work" {
    if (!mruby.features.hasGem("mruby-time") or !mruby.features.hasGem("mruby-random"))
        return error.SkipZigTest;
    var context: Context = .{};
    var boot = try mruby.sandbox.BootstrapIsolate.spawn(mruby.sandbox.Policy.restricted(.{
        .capabilities = .{ .random_seed = 42, .clock_epoch_s = 1234 },
    }));
    defer boot.deinit();
    const descriptors = .{.{
        .name = "clock.now",
        .namespace = "Clock",
        .method = "now",
        .arity = @as(usize, 0),
        .authority_bits = @as(u16, 1 << 4),
    }};
    try effect.install(boot.vm(), descriptors, .{
        .allowed = &.{"clock.now"},
        .bindings = &.{.{ .name = "clock.now", .handler = Context.clock, .context = &context }},
    });
    const iso = try boot.seal();
    defer iso.deinit();
    try testing.expectError(error.RubyException, iso.run("Time.now"));
    try testing.expectError(error.RubyException, iso.run("rand"));
    try testing.expectEqual(@as(i64, 1), try (try iso.run("Clock.now.version")).asInt());
    try testing.expectEqual(@as(i64, 42), try (try iso.run("Effect.perform(Clock.now)")).asInt());
}
