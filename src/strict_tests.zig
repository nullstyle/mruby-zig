const std = @import("std");
const mruby = @import("mruby");
const manifest = @import("strict_manifest");
const testing = std.testing;
const operations = .{
    .{ .name = "clock.now", .namespace = "Clock", .method = "now", .arity = 0, .authority_bits = 1 << 4, .max_result_bytes = 256 },
    .{ .name = "sink.write", .namespace = "Sink", .method = "write", .arity = 1, .authority_bits = 1 << 13, .max_result_bytes = 2048 },
};
const state_identity: [32]u8 = @splat(7);
const Host = struct {
    calls: usize = 0,
    fn now(context: ?*anyopaque, vm: *mruby.Vm, _: mruby.Value) !mruby.Value {
        const host: *Host = @ptrCast(@alignCast(context.?));
        host.calls += 1;
        return vm.intValue(42);
    }
    fn write(context: ?*anyopaque, _: *mruby.Vm, arguments: mruby.Value) !mruby.Value {
        const host: *Host = @ptrCast(@alignCast(context.?));
        host.calls += 1;
        return (try arguments.asArray()).get(0);
    }
};
fn load(host: *Host, entry: []const u8, mode: mruby.effect.Mode) !mruby.strict.Program {
    const bindings = [_]mruby.effect.Binding{
        .{ .name = "clock.now", .handler = Host.now, .context = host },
        .{ .name = "sink.write", .handler = Host.write, .context = host },
    };
    return mruby.strict.Program.load(manifest, entry, operations, .{
        .effects = .{ .allowed = &.{ "clock.now", "sink.write" }, .bindings = &bindings, .mode = mode },
    });
}

test "strict profile has no compiler or unaudited gems and keeps local mutation" {
    try testing.expect(mruby.features.effects_strict);
    try testing.expect(!mruby.features.has_compiler);
    try testing.expectEqual(@as(usize, 0), mruby.features.gems.len);
    var host: Host = .{};
    const program = try load(&host, "app", .record);
    defer program.deinit();
    try testing.expectEqual(@as(i64, 2), try (try program.call("StrictApp", "local_mutation", .{}, state_identity)).asInt());
    try testing.expectEqual(@as(i64, 3), try (try program.call("StrictApp", "accessors", .{}, state_identity)).asInt());
    const values = try (try program.call("StrictApp", "unavailable", .{}, state_identity)).asArray();
    for (0..values.len()) |index| try testing.expect(!(try values.get(index)).isTruthy());
    try testing.expectEqual(@as(usize, 0), host.calls);
}

test "strict CodeDB program records and replays explicit effects in a fresh VM" {
    const encoded = blk: {
        var host: Host = .{};
        const program = try load(&host, "app", .record);
        defer program.deinit();
        const value = try (try program.call("StrictApp", "run", .{"hello"}, state_identity)).asArray();
        try testing.expectEqual(@as(i64, 42), try (try value.get(0)).asInt());
        try testing.expectEqualStrings("hello", try (try value.get(1)).asString());
        try testing.expectEqual(@as(usize, 2), host.calls);
        const gas = program.stats().gas.?;
        try testing.expectError(error.InvalidEffectInvocation, program.call("NoSuchClass", "", .{}, state_identity));
        try testing.expectError(error.InvalidEffectInvocation, program.call("StrictApp\x00extra", "run", .{}, state_identity));
        try testing.expectEqualDeep(gas, program.stats().gas.?);
        var trace = try program.takeEffectTrace();
        defer trace.deinit();
        try testing.expect(trace.isComplete());
        try testing.expectEqual(@as(usize, 2), trace.len());
        break :blk try trace.encode(testing.allocator);
    };
    defer testing.allocator.free(encoded);
    var replay_host: Host = .{};
    const replay = try load(&replay_host, "app", .{ .replay = encoded });
    defer replay.deinit();
    const value = try (try replay.call("StrictApp", "run", .{"hello"}, state_identity)).asArray();
    try testing.expectEqual(@as(i64, 42), try (try value.get(0)).asInt());
    try testing.expectEqualStrings("hello", try (try value.get(1)).asString());
    try testing.expectEqual(@as(usize, 0), replay_host.calls);
    const gas = replay.stats().gas.?;
    try testing.expectError(error.EffectTraceIdentityMismatch, replay.call("StrictApp", "run", .{"different"}, state_identity));
    try testing.expectEqualDeep(gas, replay.stats().gas.?);
}

test "native identity observations stay failed even when rescued and the next turn works" {
    var host: Host = .{};
    const program = try load(&host, "app", .record);
    defer program.deinit();
    try testing.expectError(error.NativeEffectViolation, program.call("StrictApp", "identity", .{}, state_identity));
    try testing.expect((try program.nativeDiagnostic()) != null);
    var failed = try program.takeEffectTrace();
    defer failed.deinit();
    try testing.expect(!failed.isComplete());
    try testing.expectError(error.IncompleteTrace, failed.encode(testing.allocator));
    try testing.expectError(error.NativeEffectViolation, program.call("StrictApp", "proc_hash", .{}, state_identity));
    try testing.expectError(error.NativeEffectViolation, program.call("StrictApp", "inspect_object", .{}, state_identity));
    try testing.expectEqual(@as(i64, 2), try (try program.call("StrictApp", "local_mutation", .{}, state_identity)).asInt());
    try testing.expect((try program.nativeDiagnostic()) == null);
}

test "initializers cannot perform effects even when rescued" {
    var host: Host = .{};
    try testing.expectError(error.EffectDuringInitialization, load(&host, "bad_init", .record));
    try testing.expectEqual(@as(usize, 0), host.calls);
    try testing.expectError(error.NativeEffectViolation, load(&host, "identity_init", .record));
    try testing.expectEqual(@as(usize, 0), host.calls);
}

test "failed initialization copies sticky effect and native details before destroying the Program" {
    var diagnostic: mruby.strict.Turn.Diagnostic = .{};
    try testing.expectError(error.EffectDuringInitialization, mruby.strict.Program.load(manifest, "bad_init", operations, .{
        .effects = .{ .mode = .record },
        .diagnostic = &diagnostic,
    }));
    try testing.expectEqual(.effect, diagnostic.kind);
    try testing.expectEqual(.setup, diagnostic.phase);
    try testing.expectEqualStrings("EffectDuringInitialization", diagnostic.errorName());
    const detail = diagnostic.effect_detail orelse return error.ExpectedEffectDiagnostic;
    try testing.expectEqual(.initialization, detail.reason);
    try testing.expectEqualStrings("clock.now", detail.actualOperation());
    try testing.expectEqualStrings("strict/bad_init.rb", diagnostic.source.?.fileName());
    try testing.expectError(error.NativeEffectViolation, mruby.strict.Program.load(manifest, "identity_init", operations, .{
        .diagnostic = &diagnostic,
    }));
    try testing.expectEqual(.native, diagnostic.kind);
    try testing.expectEqual(.setup, diagnostic.phase);
    try testing.expect(diagnostic.effect_detail == null);
    try testing.expectEqualStrings("strict/identity_init.rb", diagnostic.source.?.fileName());
    const program = try mruby.strict.Program.load(manifest, "app", operations, .{ .diagnostic = &diagnostic });
    defer program.deinit();
    try testing.expectEqualDeep(mruby.strict.Turn.Diagnostic{}, diagnostic);
}

test "initialization has a finite budget and failed CodeDB loaders remain poisoned" {
    var host: Host = .{};
    try testing.expectError(error.GasExhausted, load(&host, "loop_init", .record));
    try testing.expectError(error.GasExhausted, mruby.strict.Program.load(manifest, "loop_init", operations, .{ .policy = .{} }));
    try testing.expectError(error.InvalidStrictPolicy, mruby.strict.Program.load(manifest, "loop_init", operations, .{ .policy = .{ .limits = .{ .gas = .unlimited } } }));
    var policy = mruby.sandbox.Policy.restricted(.{ .limits = .{ .gas = .{ .per_execution = 2000 } } });
    policy.capabilities.freeze_object_model = false;
    var boot = try mruby.sandbox.BootstrapIsolate.spawn(policy);
    defer boot.deinit();
    try mruby.effect.install(boot.vm(), operations, .{ .mode = .record });
    const iso = try boot.seal();
    defer iso.deinit();
    try testing.expectError(error.EffectDuringInitialization, mruby.codedb.initializeStrict(iso, manifest, "bad_init"));
    try testing.expectError(error.CodeDBPoisoned, mruby.codedb.initializeStrict(iso, manifest, "app"));
    try testing.expectError(error.EffectTraceUnavailable, iso.takeEffectTrace());
}

test "captured native alias cannot evade the native gate" {
    const Native = struct {
        var calls: usize = 0;
        fn bump(vm: *mruby.Vm, _: mruby.Value) !mruby.Value {
            calls += 1;
            return vm.intValue(calls);
        }
    };
    Native.calls = 0;
    var boot = try mruby.sandbox.BootstrapIsolate.spawn(mruby.sandbox.Policy.trusted(.{}));
    defer boot.deinit();
    try (try boot.vm().defineModule("Legacy")).defineClassMethod("bump", Native.bump);
    const view = mruby.codedb.find(manifest, "native_alias").?;
    const payload = try mruby.artifact.validateRite(view, .{ .compatibility = mruby.features.rite_compatibility_fingerprint });
    // Deliberate low-level host access reproduces a preexisting captured alias.
    // Strict Program itself never exposes this bootstrap escape.
    _ = try boot.vm().loadIrep(payload.bytes);
    try mruby.effect.install(boot.vm(), operations, .{ .mode = .record });
    const iso = try boot.seal();
    defer iso.deinit();
    const receiver = try iso.classValue("NativeAudit");
    try testing.expectError(error.NativeEffectViolation, iso.callWithEffects(receiver, "run", .{}, .{
        .code = @splat(1),
        .bootstrap = @splat(2),
        .state = state_identity,
        .receiver = "NativeAudit",
    }));
    try testing.expectEqual(@as(usize, 0), Native.calls);
    try testing.expectError(error.NativeEffectViolation, iso.callWithEffects(receiver, "send_run", .{}, .{
        .code = @splat(1),
        .bootstrap = @splat(2),
        .state = state_identity,
        .receiver = "NativeAudit",
    }));
    try testing.expectEqual(@as(usize, 0), Native.calls);
    var failed = try iso.takeEffectTrace();
    defer failed.deinit();
    try testing.expect(!failed.isComplete());
}

test "strict runtime rejects unapproved native finalizers before ownership transfer" {
    const Native = struct {
        var freed: usize = 0;
        fn destroy(_: *u8) void {
            freed += 1;
        }
    };
    const Wrapper = mruby.data.DataType(u8, "Unaudited", Native.destroy);
    Native.freed = 0;
    const vm = try mruby.Vm.init();
    defer vm.deinit();
    const cls = try vm.defineClass("Unaudited", null);
    var owned: u8 = 1;
    try testing.expectError(error.RubyException, Wrapper.wrap(cls, &owned));
    try testing.expectEqual(@as(usize, 0), Native.freed);
    var detail: mruby.c.StrictDiagnostic = undefined;
    try testing.expect(mruby.c.mrz_strict_violation(vm.mrb, &detail));
}

test "strict installation cannot opt out of ambient restrictions" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();
    try testing.expectError(error.InvalidEffectConfiguration, mruby.effect.install(vm, operations, .{ .harden_ambient = false }));
    try testing.expect(vm.effects == null);
}

fn graphManifest(comptime with_dependency: bool) type {
    return struct {
        const Entry = struct { name: []const u8, bytes: []const u8, entrypoint: bool, dependencies: []const []const u8 };
        pub const entries = [_]Entry{
            .{ .name = "base", .bytes = mruby.codedb.find(manifest, "app").?.bytes, .entrypoint = false, .dependencies = &.{} },
            .{ .name = "app", .bytes = mruby.codedb.find(manifest, "app").?.bytes, .entrypoint = true, .dependencies = if (with_dependency) &.{"base"} else &.{} },
        };
    };
}

test "changed initialization graph cannot replay identical artifact bytes" {
    const program = try mruby.strict.Program.load(graphManifest(false), "app", operations, .{ .effects = .{ .mode = .record } });
    defer program.deinit();
    try testing.expectEqual(@as(i64, 1), try (try program.call("StrictApp", "load_count", .{}, state_identity)).asInt());
    var trace = try program.takeEffectTrace();
    defer trace.deinit();
    const encoded = try trace.encode(testing.allocator);
    defer testing.allocator.free(encoded);

    const changed = try mruby.strict.Program.load(graphManifest(true), "app", operations, .{ .effects = .{ .mode = .record } });
    defer changed.deinit();
    try testing.expectEqual(@as(i64, 2), try (try changed.call("StrictApp", "load_count", .{}, state_identity)).asInt());
    const replay = try mruby.strict.Program.load(graphManifest(true), "app", operations, .{ .effects = .{ .mode = .{ .replay = encoded } } });
    defer replay.deinit();
    const gas = replay.stats().gas.?;
    try testing.expectError(error.EffectTraceIdentityMismatch, replay.call("StrictApp", "load_count", .{}, state_identity));
    try testing.expectEqualDeep(gas, replay.stats().gas.?);
}
