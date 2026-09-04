//! Artifact execution contract, exercised with and without the target compiler.
const std = @import("std");
const mruby = @import("mruby");
const manifest = @import("codedb_runtime_manifest");
const config = @import("runtime_only_config");
const sandbox = mruby.sandbox;

fn spawn(policy: sandbox.Policy) !sandbox.Isolate {
    var boot = try sandbox.BootstrapIsolate.spawn(policy);
    defer boot.deinit();
    return boot.seal();
}

fn image(name: []const u8) mruby.artifact.RiteImageView {
    return mruby.codedb.find(manifest, name).?;
}

fn integers(value: mruby.Value) ![3]i64 {
    const array = try value.asArray();
    try std.testing.expectEqual(@as(usize, 3), array.len());
    var result: [3]i64 = undefined;
    for (&result, 0..) |*item, i| item.* = try (try array.get(i)).asInt();
    return result;
}

test "artifact runtime: feature profile and configured authority agree" {
    try std.testing.expectEqual(!config.expected_no_compiler, mruby.features.has_compiler);
    try std.testing.expect(mruby.features.has_debug_hook);
    try std.testing.expect(mruby.features.sandbox_supported);
    try std.testing.expectEqual(mruby.features.has_compiler, mruby.features.authority.find("mruby-compiler") != null);
    if (!mruby.features.has_compiler) try std.testing.expect(!mruby.features.hasGem("mruby-eval"));
    try std.testing.expectEqualSlices(u8, &mruby.features.rite_compatibility_fingerprint, &manifest.compatibility);
    try std.testing.expectEqual(mruby.features.authority.sources.len, manifest.authority_profile.len);
    try std.testing.expectEqual(mruby.features.worker_profile_eligible, mruby.features.authority.workerEligible());
}

test "artifact runtime: unavailable source APIs reject before guest execution" {
    if (mruby.features.has_compiler) return error.SkipZigTest;
    const vm = try mruby.Vm.init();
    defer vm.deinit();
    try std.testing.expectError(error.CompilerUnavailable, vm.loadString("42"));
    try std.testing.expectError(error.CompilerUnavailable, vm.loadStringWithOptions("42", .{ .source_name = "source.rb" }));
    try std.testing.expect(vm.lastError() == null);
    try std.testing.expectError(error.CompilerUnavailable, sandbox.compile("42"));
    try std.testing.expectError(error.CompilerUnavailable, sandbox.compileRite(std.testing.allocator, "42", .{}));
    const iso = try spawn(.{ .limits = .{ .gas = .{ .per_execution = 1000 } } });
    defer iso.deinit();
    const before = iso.stats();
    try std.testing.expectError(error.CompilerUnavailable, iso.run("$must_not_run = true"));
    const after = iso.stats();
    try std.testing.expectEqual(before.instructions, after.instructions);
    try std.testing.expectEqual(before.gas.?.generation, after.gas.?.generation);
    try std.testing.expect((try iso.getGlobal("must_not_run")).isNil());
    try std.testing.expectEqual(@as(i64, 42), try (try iso.runRite(image("answer"))).asInt());
}

test "artifact runtime: declared initialization and stable filenames survive compiler removal" {
    const iso = try spawn(sandbox.Policy.restricted(.{ .limits = .{ .gas = .{ .per_execution = 10_000 } } }));
    defer iso.deinit();
    try std.testing.expect(try iso.loadArtifact(manifest, "job"));
    try std.testing.expect(!try iso.loadArtifact(manifest, "job"));
    const result = try (try iso.runArtifact(manifest, "job")).asArray();
    try std.testing.expectEqual(@as(i64, 2), try (try result.get(0)).asInt());
    try std.testing.expectEqualStrings(mruby.codedb.lookup(manifest, "job").?.source_name, try (try result.get(1)).asString());
    try std.testing.expect(iso.stats().instructions > 0);
}

test "artifact runtime: compiler-backed eval is absent even with a trusted policy" {
    const iso = try spawn(sandbox.Policy.trusted(.{}));
    defer iso.deinit();
    if (mruby.features.hasGem("mruby-eval")) {
        try std.testing.expectEqual(@as(i64, 42), try (try iso.runRite(image("eval"))).asInt());
    } else {
        try std.testing.expectError(error.RubyException, iso.runRite(image("eval")));
        const class_name = try iso.lastError().?.className(std.testing.allocator);
        defer std.testing.allocator.free(class_name);
        try std.testing.expectEqualStrings("NoMethodError", class_name);
    }
}

test "artifact runtime: native RNG setup is deterministic, masks reseeding and uses no bytecode" {
    if (!mruby.features.hasGem("mruby-random")) return error.SkipZigTest;
    var expected: ?[3]i64 = null;
    for ([_]u64{ 42, 42, 0xffff_ffff_0000_002a }) |seed| {
        const iso = try spawn(sandbox.Policy.restricted(.{
            .capabilities = .{ .random_seed = seed },
            .limits = .{ .gas = .{ .per_execution = 1000 } },
        }));
        defer iso.deinit();
        try std.testing.expectEqual(@as(u64, 0), iso.stats().instructions);
        const sample = try integers(try iso.runRite(image("random")));
        if (expected) |previous| try std.testing.expectEqual(previous, sample) else expected = sample;
        try std.testing.expectError(error.RubyException, iso.runRite(image("reseed")));
    }
    const other = try spawn(.{ .capabilities = .{ .random_seed = 43 } });
    defer other.deinit();
    try std.testing.expect(!std.mem.eql(i64, &expected.?, &try integers(try other.runRite(image("random")))));
    if (mruby.features.has_compiler) {
        const vm = try mruby.Vm.init();
        defer vm.deinit();
        const upstream = try integers(try vm.loadString("srand(42); [rand(1_000_000), rand(1_000_000), rand(1_000_000)]"));
        try std.testing.expectEqual(upstream, expected.?);
    }
}

test "artifact runtime: bootstrap overrides cannot replace the captured native seed operation" {
    if (!mruby.features.hasGem("mruby-random")) return error.SkipZigTest;
    const Probe = struct {
        var called: bool = false;
        fn replaced(vm: *mruby.Vm, _: mruby.Value, _: i64) anyerror!mruby.Value {
            called = true;
            return vm.intValue(0);
        }
    };
    Probe.called = false;
    const reference = try spawn(.{ .capabilities = .{ .random_seed = 42 } });
    defer reference.deinit();
    const expected = try integers(try reference.runRite(image("random")));
    var boot = try sandbox.BootstrapIsolate.spawn(.{ .capabilities = .{ .random_seed = 42 } });
    defer boot.deinit();
    const kernel = try boot.vm().defineModule("Kernel");
    try kernel.defineModuleFunction("srand", Probe.replaced);
    const iso = try boot.seal();
    defer iso.deinit();
    try std.testing.expect(!Probe.called);
    try std.testing.expectEqual(expected, try integers(try iso.runRite(image("random"))));
}

test "artifact runtime: seeding without the random gem fails terminally at seal" {
    if (mruby.features.hasGem("mruby-random")) return error.SkipZigTest;
    var boot = try sandbox.BootstrapIsolate.spawn(.{ .capabilities = .{ .random_seed = 42 } });
    defer boot.deinit();
    try std.testing.expectError(error.CapabilityApplicationFailed, boot.seal());
    try std.testing.expectError(error.CapabilityApplicationFailed, boot.seal());
}

test "artifact runtime: gas termination runs ensure and the next execution gets fresh gas" {
    const iso = try spawn(.{ .limits = .{ .gas = .{ .per_execution = 1000 } } });
    defer iso.deinit();
    try std.testing.expectError(error.GasExhausted, iso.runRite(image("ensure_loop")));
    try std.testing.expect((try iso.getGlobal("runtime_only_ensured")).isTruthy());
    try std.testing.expectEqual(@as(i64, 42), try (try iso.runRite(image("answer"))).asInt());
    try std.testing.expectEqual(@as(u64, 2), iso.stats().gas.?.generation);
}

test "artifact runtime: deadline and external termination still interrupt bytecode" {
    const timed = try spawn(.{ .limits = .{ .wall_time_ns = 20 * std.time.ns_per_ms } });
    defer timed.deinit();
    try std.testing.expectError(error.DeadlineExceeded, timed.runRite(image("loop")));
    const stopped = try spawn(.{});
    defer stopped.deinit();
    const Stopper = struct {
        fn run(iso: sandbox.Isolate) void {
            sandbox.sleepNs(20 * std.time.ns_per_ms);
            iso.terminate();
        }
    };
    const thread = try std.Thread.spawn(.{}, Stopper.run, .{stopped});
    defer thread.join();
    try std.testing.expectError(error.ScriptTerminated, stopped.runRite(image("loop")));
    try std.testing.expect(stopped.stats().instructions > 0);
}

test "artifact runtime: memory and call-depth limits survive compiler removal" {
    const memory = try spawn(.{ .limits = .{ .memory_bytes = 2 * 1024 * 1024 } });
    defer memory.deinit();
    try std.testing.expectError(error.MemoryLimitExceeded, memory.runRite(image("memory")));
    const depth = try spawn(.{ .limits = .{ .call_depth = 16 } });
    defer depth.deinit();
    try std.testing.expectError(error.CallDepthExceeded, depth.runRite(image("depth")));
}

test "artifact runtime: worker exchanges typed capsules without compiling source" {
    if (!mruby.worker.supported) return error.SkipZigTest;
    const source = try spawn(.{});
    defer source.deinit();
    var input = try source.exportValue(std.testing.allocator, try source.intValue(41), .{});
    defer input.deinit(std.testing.allocator);
    var report = try mruby.worker.runRite(std.testing.io, std.testing.allocator, config.worker_executable, .{
        .image = image("input"),
        .input = .{ .capsule = input.view() },
    });
    defer report.deinit(std.testing.allocator);
    switch (report.outcome) {
        .value => |capsule| try std.testing.expectEqual(@as(i64, 42), try (try source.importValue(capsule.view(), .{})).asInt()),
        else => return error.UnexpectedWorkerOutcome,
    }
    try std.testing.expect(report.sandbox_stats.?.instructions > 0);
}

test "artifact runtime: seeded workers reproduce the in-process sequence" {
    if (!mruby.worker.supported or !mruby.features.hasGem("mruby-random")) return error.SkipZigTest;
    const policy: sandbox.Policy = .{ .capabilities = .{ .random_seed = 42 } };
    const iso = try spawn(policy);
    defer iso.deinit();
    const expected = try integers(try iso.runRite(image("random")));
    for (0..2) |_| {
        var report = try mruby.worker.runRite(std.testing.io, std.testing.allocator, config.worker_executable, .{
            .image = image("random"),
            .policy = policy,
        });
        defer report.deinit(std.testing.allocator);
        switch (report.outcome) {
            .value => |capsule| try std.testing.expectEqual(expected, try integers(try iso.importValue(capsule.view(), .{}))),
            else => return error.UnexpectedWorkerOutcome,
        }
    }
}

test "artifact runtime: worker exceptions and execution limits remain typed outcomes" {
    if (!mruby.worker.supported) return error.SkipZigTest;
    var exception = try mruby.worker.runRite(std.testing.io, std.testing.allocator, config.worker_executable, .{ .image = image("raise") });
    defer exception.deinit(std.testing.allocator);
    switch (exception.outcome) {
        .ruby_exception => |value| try std.testing.expectEqualStrings("runtime-only worker exception", value.message),
        else => return error.UnexpectedWorkerOutcome,
    }
    const cases = .{
        .{ sandbox.Policy{ .limits = .{ .gas = .{ .per_execution = 1000 } } }, mruby.worker.LimitKind.sandbox_gas },
        .{ sandbox.Policy{ .limits = .{ .wall_time_ns = 20 * std.time.ns_per_ms } }, mruby.worker.LimitKind.sandbox_deadline },
    };
    inline for (cases) |case| {
        var report = try mruby.worker.runRite(std.testing.io, std.testing.allocator, config.worker_executable, .{
            .image = image("loop"),
            .policy = case[0],
        });
        defer report.deinit(std.testing.allocator);
        switch (report.outcome) {
            .limit => |kind| try std.testing.expectEqual(case[1], kind),
            else => return error.UnexpectedWorkerOutcome,
        }
    }
}
