//! Test root: `zig build test`.

const std = @import("std");
const builtin = @import("builtin");
const mruby = @import("mruby");
const authority_manifest = @import("authority_manifest");
const test_config = @import("test_config");

test {
    _ = mruby;
}

/// Spawn and immediately seal: the no-bootstrap form used by most tests.
/// Sites that define host classes use `BootstrapIsolate` directly.
fn spawnSealed(policy: sandbox.Policy) !sandbox.Isolate {
    var boot = try sandbox.BootstrapIsolate.spawn(policy);
    defer boot.deinit();
    return boot.seal();
}

test "features: generated manifest matches the build" {
    const features = mruby.features;

    // The selection lists its gems, in order, without duplicates, and
    // hasGem agrees with list membership.
    try std.testing.expect(features.gems.len > 0);
    for (features.gems, 0..) |name, i| {
        try std.testing.expect(name.len > 0);
        try std.testing.expect(features.hasGem(name));
        for (features.gems[0..i]) |earlier| {
            try std.testing.expect(!std.mem.eql(u8, earlier, name));
        }
    }
    try std.testing.expect(!features.hasGem("mruby-not-a-gem"));

    // Gem-derived test_config flags must agree with the manifest across
    // every gem profile this suite runs under.
    try std.testing.expectEqual(test_config.has_object_space, features.hasGem("mruby-objectspace"));
    try std.testing.expectEqual(test_config.has_random, features.hasGem("mruby-random"));
    try std.testing.expectEqual(test_config.has_time, features.hasGem("mruby-time"));
    try std.testing.expectEqual(test_config.has_string_ext, features.hasGem("mruby-string-ext"));
    try std.testing.expectEqual(test_config.has_math, features.hasGem("mruby-math"));

    // Both shipped presets include mruby-eval; the minimal preset is its
    // dependency closure (mruby-binding + mruby-eval) and nothing else.
    try std.testing.expect(features.hasGem("mruby-eval"));
    try std.testing.expect(features.hasGem("mruby-binding"));
    if (std.mem.eql(u8, features.gem_set, "minimal") and !features.custom_selection) {
        try std.testing.expectEqual(@as(usize, 2), features.gems.len);
        try std.testing.expect(!features.hasGem("mruby-objectspace"));
    }

    // The compiler and debug hook are always linked; the sandbox is usable.
    try std.testing.expect(features.has_compiler);
    try std.testing.expect(features.has_debug_hook);
    try std.testing.expect(features.sandbox_supported);
    try std.testing.expectEqual(mruby.worker.supported, features.worker_process_supported);
    try std.testing.expectEqual(@as(u16, 64), features.pointer_bits);

    // Authority attribution is complete and its generated aggregate agrees
    // with recomputing the union from every source.
    try std.testing.expectEqual(features.gems.len + 2, features.authority.sources.len);
    const core_authority = features.authority.find("mruby-core") orelse
        return error.TestUnexpectedResult;
    const compiler_authority = features.authority.find("mruby-compiler") orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(core_authority.authority.has(.dynamic_dispatch));
    try std.testing.expect(core_authority.authority.has(.host_output));
    try std.testing.expectEqual(@as(u16, 0), compiler_authority.authority.toBits());
    try std.testing.expect(features.authority.has(.host_output));
    var authority_union: features.AuthoritySet = .empty;
    for (features.authority.sources) |source| {
        authority_union = authority_union.unionWith(source.authority);
    }
    try std.testing.expectEqual(
        features.authority.aggregate.toBits(),
        authority_union.toBits(),
    );
    for (features.gems) |name| {
        const attributed = features.authorityForGem(name) orelse
            return error.TestUnexpectedResult;
        try std.testing.expectEqual(
            features.authority.find(name).?.authority.toBits(),
            attributed.toBits(),
        );
    }
    try std.testing.expect(features.authorityForGem("mruby-not-a-gem") == null);
    try std.testing.expectEqual(
        features.hasGem("mruby-time"),
        features.authority.has(.clock),
    );
    try std.testing.expectEqual(
        features.hasGem("mruby-random"),
        features.authority.has(.entropy),
    );
    try std.testing.expectEqual(
        features.authority.workerEligible(),
        features.worker_profile_eligible,
    );
    try std.testing.expectEqual(
        features.worker_target_supported and
            (features.worker_profile_eligible or
                features.worker_ambient_authority_opt_in),
        features.worker_process_supported,
    );
    if (features.worker_ambient_authority_opt_in) {
        try std.testing.expect(!features.worker_profile_eligible);
    }

    // Identity surfaces are consistent with the artifact config.
    try std.testing.expectEqual(
        @as(usize, features.rite_compatibility_fingerprint_hex.len / 2),
        features.rite_compatibility_fingerprint.len,
    );
    try std.testing.expect(features.rite_compatibility_epoch > 0);
    try std.testing.expect(features.mruby_version.len > 0);
    try std.testing.expect(features.rite_binary_version.len > 0);
    try std.testing.expect(features.rite_vm_version.len > 0);
}

test "features: manifest is usable in comptime branches" {
    const present = comptime mruby.features.hasGem("mruby-eval");
    const absent = comptime !mruby.features.hasGem("mruby-not-a-gem");
    try std.testing.expect(present and absent);
    comptime std.debug.assert(mruby.features.sandbox_supported);
}

// ---- ruby integration suite ----------------------------------------------

const ruby_suites = .{
    .{ .name = "core_language", .src = @embedFile("tests_ruby/core_language.rb"), .enabled = test_config.has_core_language_suite },
    .{ .name = "numerics", .src = @embedFile("tests_ruby/numerics.rb"), .enabled = test_config.has_numerics_suite },
};

fn countLines(s: []const u8) usize {
    var n: usize = 0;
    for (s) |ch| {
        if (ch == '\n') n += 1;
    }
    return n + @intFromBool(s.len > 0 and s[s.len - 1] != '\n');
}

test "ruby integration suite" {
    // Each broad Ruby fixture declares its gem requirements in build.zig.
    // Trimmed configurations run every compatible fixture and Zig test while
    // skipping only fixtures that require gems they deliberately omit.
    if (!test_config.has_core_language_suite and !test_config.has_numerics_suite) return error.SkipZigTest;

    inline for (ruby_suites) |suite| {
        if (!suite.enabled) continue;
        const vm = try mruby.Vm.init();
        defer vm.deinit();
        _ = vm.loadString(suite.src) catch {
            const exc = vm.lastError().?;
            const cls = try exc.className(std.testing.allocator);
            defer std.testing.allocator.free(cls);
            const msg = try exc.message(std.testing.allocator);
            defer std.testing.allocator.free(msg);
            std.debug.print("ruby suite '{s}' failed: {s}: {s}\n", .{ suite.name, cls, msg });
            // Bisect: accumulate lines until they parse standalone (so a
            // multi-line def/class is consumed as a unit), then report the
            // first window that still fails.
            var it = std.mem.splitScalar(u8, suite.src, '\n');
            var acc: std.ArrayList(u8) = .empty;
            defer acc.deinit(std.testing.allocator);
            var acc_start: usize = 0;
            var line_no: usize = 0;
            while (it.next()) |line| : (line_no += 1) {
                if (line.len == 0 and acc.items.len == 0) continue;
                if (acc.items.len == 0) acc_start = line_no;
                acc.appendSlice(std.testing.allocator, line) catch break;
                acc.append(std.testing.allocator, '\n') catch break;
                if (acc.items.len > 4096) break;
                const line_vm = mruby.Vm.init() catch break;
                defer line_vm.deinit();
                if (line_vm.loadString(acc.items)) |_| {
                    acc.clearRetainingCapacity();
                } else |_| {
                    line_vm.clearError();
                    // Might be an incomplete multi-line construct; keep
                    // accumulating unless this was already a single line.
                    if (countLines(acc.items) == 1) {
                        std.debug.print("  first failing line {d}: {s}\n", .{ acc_start + 1, line });
                        break;
                    }
                }
            }
            return error.RubySuiteFailed;
        };
    }
}

// ---- evaluation ----------------------------------------------------------

test "evaluates arithmetic" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();
    const result = try vm.loadString("1 + 1");
    try std.testing.expectEqual(@as(i64, 2), try result.asInt());
}

test "nested isolate lifecycle restores outer allocator attribution" {
    var outer_boot = try sandbox.BootstrapIsolate.spawn(.{});
    defer outer_boot.deinit();
    const cls = try outer_boot.vm().defineClass("NestedLifecycle", null);
    try cls.defineClassMethod("check", struct {
        fn call(m: *mruby.Vm, self: mruby.Value) !mruby.Value {
            _ = self;
            const expected = mruby.alloc.currentIsolateCell() orelse return error.MissingOuterAttribution;

            var child = try sandbox.BootstrapIsolate.spawn(.{});
            const after_spawn = mruby.alloc.currentIsolateCell() == expected;
            child.deinit();
            const after_deinit = mruby.alloc.currentIsolateCell() == expected;

            return m.intValue(@as(i64, @intFromBool(after_spawn)) |
                (@as(i64, @intFromBool(after_deinit)) << 1));
        }
    }.call);
    const outer = try outer_boot.seal();
    defer outer.deinit();

    const flags = try (try outer.run("NestedLifecycle.check")).asInt();
    try std.testing.expectEqual(@as(i64, 3), flags);
}

test "plain Vm retained from callback outlives its allocator Isolate" {
    const Retained = struct {
        var vm: ?*mruby.Vm = null;

        fn create(m: *mruby.Vm, self: mruby.Value) !mruby.Value {
            _ = self;
            vm = try mruby.Vm.init();
            return m.nilValue();
        }
    };
    Retained.vm = null;

    var boot = try sandbox.BootstrapIsolate.spawn(.{});
    defer boot.deinit();
    const cls = try boot.vm().defineClass("RetainPlainVm", null);
    try cls.defineClassMethod("create", Retained.create);
    const iso = try boot.seal();
    var iso_live = true;
    defer if (iso_live) iso.deinit();
    _ = try iso.run("RetainPlainVm.create");

    iso.deinit();
    iso_live = false;

    const retained = Retained.vm orelse return error.MissingRetainedVm;
    Retained.vm = null;
    defer retained.deinit();
    try std.testing.expectEqual(@as(i64, 42), try (try retained.loadString("40 + 2")).asInt());
}

test "floats and strings roundtrip through eval" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();
    try std.testing.expectEqual(@as(f64, 0.5), try (try vm.loadString("1.0 / 2")).asFloat());
    try std.testing.expectEqualStrings("ok", try (try vm.loadString(":ok.to_s")).asString());
    try std.testing.expect((try vm.loadString("nil")).isNil());
    try std.testing.expect(!(try vm.loadString("false")).isTruthy());
    try std.testing.expect((try vm.loadString("0")).isTruthy()); // Ruby truthiness
}

test "captures ruby exceptions" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();
    try std.testing.expectError(error.RubyException, vm.loadString("raise 'boom'"));
    const exc = vm.lastError().?;
    const class_name = try exc.className(std.testing.allocator);
    defer std.testing.allocator.free(class_name);
    const message = try exc.message(std.testing.allocator);
    defer std.testing.allocator.free(message);
    try std.testing.expectEqualStrings("RuntimeError", class_name);
    try std.testing.expectEqualStrings("boom", message);
}

test "error diagnostics preserve the pending exception until the next operation" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();

    try std.testing.expectError(error.RubyException, vm.loadString("raise 'original'"));
    const exc = vm.lastError() orelse return error.MissingRubyException;
    const class_name = try exc.className(std.testing.allocator);
    defer std.testing.allocator.free(class_name);
    const message = try exc.message(std.testing.allocator);
    defer std.testing.allocator.free(message);
    try std.testing.expectEqualStrings("RuntimeError", class_name);
    try std.testing.expectEqualStrings("original", message);
    try std.testing.expect(vm.lastError() != null);

    // Starting another safe-layer operation deliberately supersedes the old
    // diagnostic instead of making a non-raising allocation fail spuriously.
    const recovered = try vm.stringValue("recovered");
    try std.testing.expectEqualStrings("recovered", try recovered.asString());
    try std.testing.expect(vm.lastError() == null);
}

test "syntax errors are ruby exceptions" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();
    try std.testing.expectError(error.RubyException, vm.loadString("def oops("));
}

test "source with an interior NUL is rejected" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();
    try std.testing.expectError(error.InvalidSource, vm.loadString("1\x00 + 1"));
}

test "source metadata drives __FILE__ and structured backtraces" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();

    const file = try vm.loadStringWithOptions("__FILE__", .{
        .source_name = "jobs/worker.rb",
    });
    try std.testing.expectEqualStrings("jobs/worker.rb", try file.asString());

    try std.testing.expectError(
        error.RubyException,
        vm.loadStringWithOptions("raise 'named failure'", .{
            .source_name = "jobs/worker.rb",
        }),
    );
    var details = try vm.lastError().?.details(std.testing.allocator, .{});
    defer details.deinit();
    try std.testing.expectEqualStrings("RuntimeError", details.class_name);
    try std.testing.expectEqualStrings("named failure", details.message);
    try std.testing.expect(details.backtrace.len > 0);
    try std.testing.expect(std.mem.indexOf(
        u8,
        details.backtrace[0],
        "jobs/worker.rb:1",
    ) != null);

    try std.testing.expectError(
        error.InvalidSourceName,
        vm.loadStringWithOptions("1", .{ .source_name = "" }),
    );
    try std.testing.expectError(
        error.InvalidSourceName,
        vm.loadStringWithOptions("1", .{ .source_name = "bad\x00name.rb" }),
    );
}

test "structured exception details are owned and backtraces are bounded" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();

    try std.testing.expectError(
        error.RubyException,
        vm.loadStringWithOptions(
            \\def detail_inner
            \\  raise "bounded failure"
            \\end
            \\def detail_outer
            \\  detail_inner
            \\end
            \\detail_outer
        , .{ .source_name = "details.rb" }),
    );
    const exception = vm.lastError().?;
    try std.testing.expectError(
        error.OutOfMemory,
        exception.details(std.testing.failing_allocator, .{}),
    );

    var details = try exception.details(std.testing.allocator, .{
        .max_backtrace_frames = 1,
    });
    defer details.deinit();
    try std.testing.expectEqualStrings("RuntimeError", details.class_name);
    try std.testing.expectEqualStrings("bounded failure", details.message);
    try std.testing.expectEqual(@as(usize, 1), details.backtrace.len);
    try std.testing.expect(details.backtrace_truncated);
    try std.testing.expect(std.mem.indexOf(
        u8,
        details.backtrace[0],
        "details.rb:",
    ) != null);

    _ = try vm.loadString("nil");
    try std.testing.expectEqualStrings("RuntimeError", details.class_name);
    try std.testing.expectEqualStrings("bounded failure", details.message);
}

test "stdlib gems are loaded" {
    if (!test_config.has_string_ext) return error.SkipZigTest;

    const vm = try mruby.Vm.init();
    defer vm.deinit();
    const v = try vm.loadString("'mruby-zig'.start_with?('mruby')");
    try std.testing.expect(v.isTruthy());
}

test "eval builtin works (mruby-eval)" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();
    const v = try vm.loadString("eval('40 + 2')");
    try std.testing.expectEqual(@as(i64, 42), try v.asInt());
}

// ---- method definition ---------------------------------------------------

test "define and call zig methods" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();

    const math = try vm.defineClass("ZigMath", null);
    try math.defineMethod("add", struct {
        fn call(m: *mruby.Vm, self: mruby.Value, a: i64, b: i64) anyerror!mruby.Value {
            _ = self;
            return m.intValue(a + b);
        }
    }.call);
    try math.defineMethodRaw("greet", "S", struct {
        fn call(m: *mruby.Vm, self: mruby.Value, name: []const u8) anyerror!mruby.Value {
            _ = self;
            return m.stringValue(name);
        }
    }.call);
    try math.defineMethodRaw("opt", "i|f", struct {
        fn call(m: *mruby.Vm, self: mruby.Value, a: i64, b: f64) anyerror!mruby.Value {
            _ = self;
            return m.floatValue(@as(f64, @floatFromInt(a)) + b);
        }
    }.call);
    try math.defineMethod("sum", struct {
        fn call(m: *mruby.Vm, self: mruby.Value, rest: mruby.Rest) anyerror!mruby.Value {
            _ = self;
            var total: i64 = 0;
            for (0..rest.len) |i| total += try rest.get(i).asInt();
            return m.intValue(total);
        }
    }.call);
    try math.defineClassMethod("version", struct {
        fn call(m: *mruby.Vm, self: mruby.Value) anyerror!mruby.Value {
            _ = self;
            return m.stringValue("1.0");
        }
    }.call);

    try std.testing.expectEqual(@as(i64, 7), try (try vm.loadString("ZigMath.new.add(3, 4)")).asInt());
    try std.testing.expectEqualStrings("ada", try (try vm.loadString("ZigMath.new.greet('ada')")).asString());
    try std.testing.expectEqual(@as(f64, 5.5), try (try vm.loadString("ZigMath.new.opt(5, 0.5)")).asFloat());
    try std.testing.expectEqual(@as(f64, 5.0), try (try vm.loadString("ZigMath.new.opt(5)")).asFloat());
    try std.testing.expectEqual(@as(i64, 6), try (try vm.loadString("ZigMath.new.sum(1, 2, 3)")).asInt());
    try std.testing.expectEqual(@as(i64, 0), try (try vm.loadString("ZigMath.new.sum")).asInt());
    try std.testing.expectEqual(@as(i64, 10), try (try vm.loadString("ZigMath.new.sum(*[1, 2, 3, 4])")).asInt());
    try std.testing.expectEqualStrings("1.0", try (try vm.loadString("ZigMath.version")).asString());

    // wrong arity/type from Ruby raises ArgumentError / TypeError
    try std.testing.expectError(error.RubyException, vm.loadString("ZigMath.new.add(1)"));
    try std.testing.expectError(error.RubyException, vm.loadString("ZigMath.new.add('a', 'b')"));
}

test "blocks reach zig methods" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();

    const runner = try vm.defineClass("Runner", null);
    try runner.defineMethod("twice", struct {
        fn call(m: *mruby.Vm, self: mruby.Value, blk: mruby.Block) anyerror!mruby.Value {
            _ = self;
            if (!blk.isPresent()) return m.raise("ArgumentError", "no block given");
            const r1 = try m.call(blk.value, "call", .{});
            const r2 = try m.call(blk.value, "call", .{});
            return m.intValue(try r1.asInt() + try r2.asInt());
        }
    }.call);

    try std.testing.expectEqual(@as(i64, 30), try (try vm.loadString("Runner.new.twice { 15 }")).asInt());
    try std.testing.expectError(error.RubyException, vm.loadString("Runner.new.twice"));
}

test "derived signatures marshal every supported parameter type" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();
    const cls = try vm.defineClass("DerivedScalars", null);

    try cls.defineMethod("scalars", struct {
        fn call(
            m: *mruby.Vm,
            self: mruby.Value,
            a: i64,
            b: f64,
            c: bool,
            d: u32,
            e: mruby.Value,
            f: []const u8,
            g: [:0]const u8,
        ) anyerror!mruby.Value {
            _ = self;
            _ = d;
            if (!e.isNil()) return m.raise("RuntimeError", "expected nil object");
            if (!std.mem.eql(u8, f, "str")) return m.raise("RuntimeError", "bad string slice");
            if (!std.mem.eql(u8, g, "zstr")) return m.raise("RuntimeError", "bad zstring");
            if (c) return m.floatValue(@as(f64, @floatFromInt(a)) + b);
            return m.intValue(a);
        }
    }.call);

    const truthy = try vm.loadString(
        "DerivedScalars.new.scalars(2, 2.5, true, :sym, nil, 'str', 'zstr')",
    );
    try std.testing.expectEqual(@as(f64, 4.5), try truthy.asFloat());
    const falsy = try vm.loadString(
        "DerivedScalars.new.scalars(7, 0.5, false, :x, nil, 'str', 'zstr')",
    );
    try std.testing.expectEqual(@as(i64, 7), try falsy.asInt());
}

test "derived optional parameters are null when omitted" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();
    const cls = try vm.defineClass("DerivedOpt", null);

    try cls.defineMethod("combine", struct {
        fn call(m: *mruby.Vm, self: mruby.Value, base: i64, extra: ?i64, tag: ?[]const u8) anyerror!mruby.Value {
            _ = self;
            var out = base;
            if (extra) |e| out += e;
            if (tag) |t| {
                if (!std.mem.eql(u8, t, "tagged")) return m.raise("RuntimeError", "bad tag");
                out += 100;
            }
            return m.intValue(out);
        }
    }.call);

    try std.testing.expectEqual(
        @as(i64, 5),
        try (try vm.loadString("DerivedOpt.new.combine(5)")).asInt(),
    );
    try std.testing.expectEqual(
        @as(i64, 15),
        try (try vm.loadString("DerivedOpt.new.combine(5, 10)")).asInt(),
    );
    try std.testing.expectEqual(
        @as(i64, 115),
        try (try vm.loadString("DerivedOpt.new.combine(5, 10, 'tagged')")).asInt(),
    );
    // Missing required and excess (no rest) arguments are ArgumentError.
    try std.testing.expectError(error.RubyException, vm.loadString("DerivedOpt.new.combine"));
    vm.clearError();
    try std.testing.expectError(
        error.RubyException,
        vm.loadString("DerivedOpt.new.combine(1, 2, 'tagged', 3)"),
    );
}

test "derived signatures compose required, optional, rest, and block" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();
    const cls = try vm.defineClass("DerivedTail", null);

    try cls.defineMethod("gather", struct {
        fn call(m: *mruby.Vm, self: mruby.Value, first: i64, scale: ?i64, rest: mruby.Rest, blk: mruby.Block) anyerror!mruby.Value {
            _ = self;
            var total = first * (scale orelse 1);
            for (0..rest.len) |i| total += try rest.get(i).asInt();
            if (blk.isPresent()) {
                const yielded = try m.call(blk.value, "call", .{});
                total += try yielded.asInt();
            }
            return m.intValue(total);
        }
    }.call);

    try std.testing.expectEqual(
        @as(i64, 2),
        try (try vm.loadString("DerivedTail.new.gather(2)")).asInt(),
    );
    try std.testing.expectEqual(
        @as(i64, 20),
        try (try vm.loadString("DerivedTail.new.gather(2, 10)")).asInt(),
    );
    // Rest absorbs everything beyond the optional; presence still works.
    try std.testing.expectEqual(
        @as(i64, 26),
        try (try vm.loadString("DerivedTail.new.gather(2, 10, 1, 2, 3)")).asInt(),
    );
    try std.testing.expectEqual(
        @as(i64, 126),
        try (try vm.loadString("DerivedTail.new.gather(2, 10, 1, 2, 3) { 100 }")).asInt(),
    );
}

test "derived class methods and module functions" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();

    const cls = try vm.defineClass("DerivedKlass", null);
    try cls.defineClassMethod("twice", struct {
        fn call(m: *mruby.Vm, self: mruby.Value, v: i64) anyerror!mruby.Value {
            _ = self;
            return m.intValue(v * 2);
        }
    }.call);
    try std.testing.expectEqual(
        @as(i64, 42),
        try (try vm.loadString("DerivedKlass.twice(21)")).asInt(),
    );

    const mod = try vm.defineModule("DerivedMod");
    try mod.defineModuleFunction("triple", struct {
        fn call(m: *mruby.Vm, self: mruby.Value, v: i64) anyerror!mruby.Value {
            _ = self;
            return m.intValue(v * 3);
        }
    }.call);
    try std.testing.expectEqual(
        @as(i64, 42),
        try (try vm.loadString("DerivedMod.triple(14)")).asInt(),
    );
}

test "Class.fromValue resolves class objects without global storage" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();

    const cls = try vm.defineClass("FromValue", null);
    const resolved = try mruby.Class.fromValue(cls.asValue());
    try std.testing.expectEqual(cls.class, resolved.class);

    // A class method's self is the defining class; fromValue reaches it
    // without a process-global slot.
    try cls.defineClassMethod("identity", struct {
        fn call(m: *mruby.Vm, self: mruby.Value) anyerror!mruby.Value {
            _ = m;
            const me = try mruby.Class.fromValue(self);
            return me.asValue();
        }
    }.call);
    const same = try vm.loadString("FromValue.identity == FromValue");
    try std.testing.expect(same.isTruthy());

    // Non-class values are rejected.
    try std.testing.expectError(
        error.UnknownClass,
        mruby.Class.fromValue(try vm.intValue(1)),
    );
}

test "zig errors surface as runtime errors" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();

    const bomb = try vm.defineClass("Bomb", null);
    try bomb.defineMethod("explode", struct {
        fn call(m: *mruby.Vm, self: mruby.Value) anyerror!mruby.Value {
            _ = self;
            _ = m;
            return error.Kaboom;
        }
    }.call);

    try std.testing.expectError(error.RubyException, vm.loadString("Bomb.new.explode"));
    const exc = vm.lastError().?;
    const class_name = try exc.className(std.testing.allocator);
    defer std.testing.allocator.free(class_name);
    const message = try exc.message(std.testing.allocator);
    defer std.testing.allocator.free(message);
    try std.testing.expectEqualStrings("RuntimeError", class_name);
    try std.testing.expectEqualStrings("zig error: Kaboom", message);
}

test "zig raise surfaces custom exceptions" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();

    const guard = try vm.defineClass("Guard", null);
    try guard.defineMethod("check", struct {
        fn call(m: *mruby.Vm, self: mruby.Value, n: i64) anyerror!mruby.Value {
            _ = self;
            if (n < 0) return m.raise("ArgumentError", "negative");
            return m.intValue(n);
        }
    }.call);

    try std.testing.expectEqual(@as(i64, 3), try (try vm.loadString("Guard.new.check(3)")).asInt());
    try std.testing.expectError(error.RubyException, vm.loadString("Guard.new.check(-1)"));
    const exc = vm.lastError().?;
    const class_name = try exc.className(std.testing.allocator);
    defer std.testing.allocator.free(class_name);
    try std.testing.expectEqualStrings("ArgumentError", class_name);
}

test "zig callbacks reject values owned by another Vm" {
    const ForeignReturn = struct {
        var value: ?mruby.Value = null;

        fn call(_: *mruby.Vm, _: mruby.Value) !mruby.Value {
            return value orelse error.MissingForeignValue;
        }
    };

    const owner = try mruby.Vm.init();
    defer owner.deinit();
    const other = try mruby.Vm.init();
    defer other.deinit();
    ForeignReturn.value = try owner.stringValue("foreign");
    defer ForeignReturn.value = null;

    const cls = try other.defineClass("ForeignReturn", null);
    try cls.defineClassMethod("value", ForeignReturn.call);
    try std.testing.expectError(error.RubyException, other.loadString("ForeignReturn.value"));
    const exc = other.lastError().?;
    const message = try exc.message(std.testing.allocator);
    defer std.testing.allocator.free(message);
    try std.testing.expectEqualStrings("zig error: ForeignValue", message);
}

// ---- calling Ruby from Zig -------------------------------------------------

test "vm.call invokes ruby methods" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();

    const str = try vm.stringValue("hello");
    const up = try vm.call(str, "upcase", .{});
    try std.testing.expectEqualStrings("HELLO", try up.asString());

    if (test_config.has_math) {
        const sqrt = try vm.call(try vm.loadString("Math"), "sqrt", .{@as(f64, 144.0)});
        try std.testing.expectEqual(@as(f64, 12.0), try sqrt.asFloat());
    }

    try std.testing.expectError(error.RubyException, vm.call(str, "nope", .{}));
}

test "vm.call accepts more than eight positional arguments" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();

    const sum = try vm.loadString(
        "->(a, b, c, d, e, f, g, h, i) { a + b + c + d + e + f + g + h + i }",
    );
    const result = try vm.call(sum, "call", .{ 1, 2, 3, 4, 5, 6, 7, 8, 9 });
    try std.testing.expectEqual(@as(i64, 45), try result.asInt());
}

test "vm.call rejects a receiver owned by another Vm" {
    const owner = try mruby.Vm.init();
    defer owner.deinit();
    const other = try mruby.Vm.init();
    defer other.deinit();

    const foreign = try owner.stringValue("hello");
    try std.testing.expectError(error.ForeignValue, other.call(foreign, "upcase", .{}));
}

test "vm.call rejects arguments owned by another Vm" {
    const owner = try mruby.Vm.init();
    defer owner.deinit();
    const other = try mruby.Vm.init();
    defer other.deinit();

    const receiver = try other.stringValue("hello");
    const foreign = try owner.stringValue("!");
    try std.testing.expectError(error.ForeignValue, other.call(receiver, "+", .{foreign}));
}

test "vm.callWithOptions passes a Ruby block" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();

    const target = try vm.loadString(
        "class BlockTarget; def self.apply(x); yield(x) * 2; end; end; BlockTarget",
    );
    const block = try vm.loadString("->(x) { x + 3 }");
    const result = try vm.callWithOptions(
        target,
        "apply",
        .{4},
        .{ .block = block },
    );
    try std.testing.expectEqual(@as(i64, 14), try result.asInt());
}

test "vm.callWithOptions rejects a block owned by another Vm" {
    const owner = try mruby.Vm.init();
    defer owner.deinit();
    const other = try mruby.Vm.init();
    defer other.deinit();

    const receiver = try other.loadString("Object.new");
    const foreign_block = try owner.loadString("-> { 1 }");
    try std.testing.expectError(
        error.ForeignValue,
        other.callWithOptions(
            receiver,
            "tap",
            .{},
            .{ .block = foreign_block },
        ),
    );
}

test "globals and ivars" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();

    _ = try vm.loadString("$answer = 42");
    try std.testing.expectEqual(@as(i64, 42), try (try vm.getGlobal("answer")).asInt());
    try vm.setGlobal("name", try vm.stringValue("zig"));
    try std.testing.expectEqualStrings("zig", try (try vm.loadString("$name")).asString());

    const obj = try vm.loadString("Object.new");
    try vm.setIvar(obj, "@v", try vm.intValue(7));
    try std.testing.expectEqual(@as(i64, 7), try (try vm.getIvar(obj, "@v")).asInt());
}

test "global assignment rejects a value owned by another Vm" {
    const owner = try mruby.Vm.init();
    defer owner.deinit();
    const other = try mruby.Vm.init();
    defer other.deinit();

    try std.testing.expectError(
        error.ForeignValue,
        other.setGlobal("foreign", try owner.stringValue("value")),
    );
}

test "instance variable assignment rejects values owned by another Vm" {
    const owner = try mruby.Vm.init();
    defer owner.deinit();
    const other = try mruby.Vm.init();
    defer other.deinit();

    const local = try other.loadString("Object.new");
    const foreign = try owner.loadString("Object.new");
    try std.testing.expectError(
        error.ForeignValue,
        other.setIvar(foreign, "@value", try other.intValue(1)),
    );
    try std.testing.expectError(
        error.ForeignValue,
        other.setIvar(local, "@value", foreign),
    );
}

test "instance variable lookup rejects an object owned by another Vm" {
    const owner = try mruby.Vm.init();
    defer owner.deinit();
    const other = try mruby.Vm.init();
    defer other.deinit();

    const foreign = try owner.loadString("Object.new");
    try std.testing.expectError(error.ForeignValue, other.getIvar(foreign, "@value"));
}

// ---- classes ---------------------------------------------------------------

test "class lookup and constants" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();

    _ = try vm.loadString("module LookupOuter; class Inner; end; end");
    const inner = try vm.getClass("LookupOuter::Inner");
    try inner.defineConst("MRB_ZIG", try vm.intValue(1));
    try std.testing.expectEqual(@as(i64, 1), try (try vm.loadString("LookupOuter::Inner::MRB_ZIG")).asInt());

    try std.testing.expectError(error.UnknownClass, vm.getClass("NoSuchThing"));
    try std.testing.expectError(error.UnknownClass, vm.getClass("Enumerator::Nope"));
    try std.testing.expectError(error.UnknownClass, vm.getClass(""));
    try std.testing.expectError(error.UnknownClass, vm.getClass("LookupOuter::"));

    _ = try vm.loadString("LookupOuter::VALUE = 1");
    try std.testing.expectError(
        error.UnknownClass,
        vm.getClass("LookupOuter::VALUE::Nested"),
    );
}

test "class definition rejects a superclass owned by another Vm" {
    const owner = try mruby.Vm.init();
    defer owner.deinit();
    const other = try mruby.Vm.init();
    defer other.deinit();

    const foreign_super = try owner.getClass("Object");
    try std.testing.expectError(
        error.ForeignValue,
        other.defineClass("ForeignSuperclass", foreign_super),
    );
}

test "classes define and inspect scoped namespaces and constants" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();

    const outer = try vm.defineModule("ScopedOuter");
    const inner = try outer.defineClass("Inner", null);
    const base = try outer.defineClass("Base", null);
    const child = try outer.defineClass("Child", base);
    _ = try outer.defineModule("Helpers");
    try inner.defineConst("ANSWER", try vm.intValue(42));
    try base.defineConst("INHERITED", try vm.intValue(7));
    try outer.defineConst("NOTHING", vm.nilValue());
    try outer.defineConst("SCALAR", try vm.intValue(1));

    const looked_up = try outer.getClass("Inner");
    try std.testing.expectEqual(
        @as(i64, 42),
        try (try looked_up.getConst("ANSWER")).asInt(),
    );
    try std.testing.expect((try outer.getConst("NOTHING")).isNil());
    _ = try outer.getClass("Helpers");
    try std.testing.expectError(error.UnknownConstant, outer.getConst("MISSING"));
    try std.testing.expectError(error.UnknownConstant, child.getConst("INHERITED"));
    try std.testing.expectError(error.UnknownClass, outer.getClass("MISSING"));
    try std.testing.expectError(error.UnknownClass, outer.getClass("NOTHING"));
    try std.testing.expectError(error.RubyException, outer.defineClass("SCALAR", null));
    try std.testing.expectEqual(
        @as(i64, 42),
        try (try vm.loadString("ScopedOuter::Inner::ANSWER")).asInt(),
    );
}

test "constant definition rejects a value owned by another Vm" {
    const owner = try mruby.Vm.init();
    defer owner.deinit();
    const other = try mruby.Vm.init();
    defer other.deinit();

    const namespace = try other.defineModule("ForeignConstantNamespace");
    try std.testing.expectError(
        error.ForeignValue,
        namespace.defineConst("VALUE", try owner.stringValue("foreign")),
    );
}

// ---- data wrapping ---------------------------------------------------------

var destroyed_total: i32 = 0;

test "wrap zig state in ruby objects" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();

    const Counter = mruby.data.DataType(i32, "Counter", struct {
        fn destroy(p: *i32) void {
            destroyed_total += p.*;
            mruby.alloc.gpa.destroy(p);
        }
    }.destroy);

    const CounterImpl = struct {
        var class: ?mruby.Class = null;

        fn bump(m: *mruby.Vm, self: mruby.Value) anyerror!mruby.Value {
            const p = Counter.unwrap(self) orelse return m.raise("TypeError", "not a Counter");
            p.* += 1;
            return m.intValue(p.*);
        }

        fn newCount(m: *mruby.Vm, self: mruby.Value, start: i64) anyerror!mruby.Value {
            _ = self;
            const p = try mruby.alloc.gpa.create(i32);
            errdefer mruby.alloc.gpa.destroy(p);
            p.* = @intCast(start);
            const cls = class orelse return error.MissingClass;
            try cls.ensureOwnedBy(m.mrb);
            return Counter.wrap(cls, p);
        }
    };

    const counter_class = try vm.defineClass("Counter", null);
    CounterImpl.class = counter_class;
    try counter_class.defineMethod("bump", CounterImpl.bump);
    try counter_class.defineClassMethod("new_count", CounterImpl.newCount);

    try std.testing.expectEqual(@as(i64, 6), try (try vm.loadString("Counter.new_count(5).bump")).asInt());

    // Drop all references and force a full GC: the wrapper is collected and
    // the Zig destructor must run (the counter was bumped to 6).
    _ = try vm.loadString("GC.start");
    try std.testing.expectEqual(@as(i32, 6), destroyed_total);
}

test "data wrappers derive interpreter ownership from their handles" {
    const Data = mruby.data.DataType(i32, "OwnedData", null);
    const owner = try mruby.Vm.init();
    defer owner.deinit();
    const other = try mruby.Vm.init();
    defer other.deinit();

    const cls = try owner.defineClass("OwnedData", null);
    var payload: i32 = 42;
    const wrapped = try Data.wrap(cls, &payload);
    try std.testing.expect(Data.unwrap(wrapped).? == &payload);
    try std.testing.expect(Data.unwrap(try other.loadString("Object.new")) == null);
}

// ---- arrays and hashes ------------------------------------------------------

test "typed arrays construct, access, extend, and append" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();

    const one = try vm.intValue(1);
    const two = try vm.intValue(2);
    const text = try vm.stringValue("three");
    const values = [_]mruby.Value{ one, two };
    const array = try vm.array(&values);
    const converted = try mruby.convert.fromValue(mruby.Array, array.asValue());

    try std.testing.expectEqual(@as(usize, 2), array.len());
    try std.testing.expectEqual(array.len(), converted.len());
    try std.testing.expectEqual(@as(i64, 1), try (try array.get(0)).asInt());
    try std.testing.expectError(error.TypeMismatch, one.asArray());
    try std.testing.expectError(error.IndexOutOfBounds, array.get(2));

    try array.set(3, text);
    try std.testing.expectEqual(@as(usize, 4), array.len());
    try std.testing.expect((try array.get(2)).isNil());
    try std.testing.expectEqualStrings("three", try (try array.get(3)).asString());
    try array.append(try vm.intValue(4));
    try std.testing.expectEqual(@as(i64, 4), try (try array.get(4)).asInt());
    try std.testing.expectEqual(
        @as(i64, 5),
        try (try vm.call(array.asValue(), "length", .{})).asInt(),
    );
    try std.testing.expect(
        (try vm.call(array.asValue(), "equal?", .{array})).isTruthy(),
    );
}

test "typed hashes distinguish missing keys from present nil" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();

    const answer = try vm.stringValue("answer");
    const empty = try vm.stringValue("empty");
    const missing = try vm.stringValue("missing");
    const entries = [_]mruby.HashEntry{
        .{ .key = answer, .value = try vm.intValue(42) },
        .{ .key = empty, .value = vm.nilValue() },
    };
    const hash = try vm.hash(&entries);
    const converted = try mruby.convert.fromValue(mruby.Hash, hash.asValue());

    try std.testing.expectEqual(@as(usize, 2), hash.len());
    try std.testing.expectEqual(hash.len(), converted.len());
    try std.testing.expectEqual(
        @as(i64, 42),
        try (try hash.get(answer)).?.asInt(),
    );
    try std.testing.expect((try hash.get(empty)).?.isNil());
    try std.testing.expect((try hash.get(missing)) == null);

    try hash.set(missing, vm.boolValue(true));
    try std.testing.expect((try hash.get(missing)).?.isTruthy());
    try std.testing.expectEqual(@as(usize, 3), (try hash.keys()).len());
}

test "typed collection mutation contains Ruby exceptions" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();

    const value = try vm.intValue(2);
    const key = try vm.stringValue("key");
    const frozen_array = try (try vm.loadString("[1].freeze")).asArray();
    const frozen_hash = try (try vm.loadString("{}.freeze")).asHash();

    try std.testing.expectError(error.RubyException, frozen_array.append(value));
    try std.testing.expectError(error.RubyException, frozen_hash.set(key, value));
    try std.testing.expect(vm.lastError() != null);
}

test "typed collections enforce VM ownership" {
    const owner = try mruby.Vm.init();
    defer owner.deinit();
    const other = try mruby.Vm.init();
    defer other.deinit();

    const local = try owner.stringValue("local");
    const foreign = try other.stringValue("foreign");
    try std.testing.expectError(
        error.ForeignValue,
        owner.array(&.{ local, foreign }),
    );

    const array = try owner.array(&.{local});
    try std.testing.expectError(error.ForeignValue, array.append(foreign));
    const hash = try owner.hash(&.{});
    try std.testing.expectError(error.ForeignValue, hash.set(local, foreign));
    try std.testing.expectError(error.ForeignValue, hash.get(foreign));

    const receiver = try other.loadString("Object.new");
    try std.testing.expectError(
        error.ForeignValue,
        other.call(receiver, "equal?", .{array}),
    );
}

// ---- output redirection ----------------------------------------------------

test "ruby print output reaches zig writer" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();

    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();

    try mruby.output.setOutputWriter(vm, &buffer.writer);
    _ = try vm.loadString("print 'a'; puts 'b'; p 42");

    const out = buffer.writer.buffer[0..buffer.writer.end];
    try std.testing.expectEqualStrings("ab\n42\n", out);
}

test "ruby puts renders recursive arrays without native recursion" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();

    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();
    try mruby.output.setOutputWriter(vm, &buffer.writer);

    _ = try vm.loadString("array = []; array << array; puts array");
    const out = buffer.writer.buffer[0..buffer.writer.end];
    try std.testing.expectEqualStrings("[...]\n", out);
}

test "output callbacks retain arguments across nested interpreter calls" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();

    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();
    try mruby.output.setOutputWriter(vm, &buffer.writer);

    _ = try vm.loadString(
        \\class OutputArgument
        \\  def initialize(text)
        \\    @text = text
        \\  end
        \\  def churn(depth)
        \\    depth == 0 ? nil : churn(depth - 1)
        \\  end
        \\  def to_s
        \\    churn(100)
        \\    @text
        \\  end
        \\end
        \\print OutputArgument.new("first"), OutputArgument.new("second")
    );
    const out = buffer.writer.buffer[0..buffer.writer.end];
    try std.testing.expectEqualStrings("firstsecond", out);
}

test "puts tolerates an element mutating its containing array" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();

    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();
    try mruby.output.setOutputWriter(vm, &buffer.writer);

    _ = try vm.loadString(
        \\class ArrayMutator
        \\  def initialize(parent)
        \\    @parent = parent
        \\  end
        \\  def to_s
        \\    100.times { @parent << "late" }
        \\    "first"
        \\  end
        \\end
        \\values = []
        \\values << ArrayMutator.new(values) << "second"
        \\puts values
    );
    const out = buffer.writer.buffer[0..buffer.writer.end];
    try std.testing.expectEqualStrings("first\nsecond\n", out);
}

// ---- arena -----------------------------------------------------------------

test "values rooted in globals survive gc churn" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();

    // A Ruby global remains a root independently of temporary arena scopes.
    _ = try vm.loadString("$held = 'i am a string'");
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        var buf: [64]u8 = undefined;
        const src = try std.fmt.bufPrint(&buf, "\"garbage {d}\"; GC.start", .{i});
        _ = try vm.loadString(src);
    }
    const held = try vm.getGlobal("held");
    try std.testing.expectEqualStrings("i am a string", try held.asString());
}

test "RootedValue survives arena restoration and GC churn" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();

    const scope = vm.arenaScope();
    const temporary = try vm.loadString("'long-' + 'lived'");
    var rooted = try vm.root(temporary);
    defer rooted.deinit();
    scope.restore();

    for (0..32) |_| {
        _ = try vm.loadString("100.times { Object.new }; GC.start");
    }
    try std.testing.expectEqualStrings("long-lived", try rooted.get().asString());
}

test "duplicate RootedValues have independent lifetimes" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();

    const scope = vm.arenaScope();
    const temporary = try vm.loadString("'shared root'");
    var first = try vm.root(temporary);
    var second = try vm.root(temporary);
    scope.restore();

    first.deinit();
    mruby.c.mrb_full_gc(vm.mrb);
    try std.testing.expectEqualStrings("shared root", try second.get().asString());
    second.deinit();
}

test "root rejects a value from another VM" {
    const first = try mruby.Vm.init();
    defer first.deinit();
    const second = try mruby.Vm.init();
    defer second.deinit();

    const foreign = try first.loadString("Object.new");
    try std.testing.expectError(error.ForeignValue, second.root(foreign));
}

test "void safe-layer operations do not grow the GC arena" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();

    const namespace = try vm.defineModule("ArenaStable");
    const object = try vm.loadString("Object.new");
    const value = try vm.stringValue("rooted by assignment");
    const before = vm.arenaScope().idx;

    for (0..64) |_| {
        try vm.setGlobal("arena_value", value);
        try vm.setIvar(object, "@arena_value", value);
        try namespace.defineConst("VALUE", value);
        try namespace.defineMethod("value", struct {
            fn call(m: *mruby.Vm, _: mruby.Value) !mruby.Value {
                return m.nilValue();
            }
        }.call);
    }

    const after = vm.arenaScope().idx;
    try std.testing.expectEqual(before, after);
}

// ---- robustness (regression tests for review findings) ---------------------

test "defineClass over non-class constant errors instead of crashing" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();
    _ = try vm.loadString("Runner = 5");
    // Before the fix this raised a TypeError with no protect point (longjmp
    // across a Zig frame, i.e. undefined behavior).
    try std.testing.expectError(error.RubyException, vm.defineClass("Runner", null));
    try std.testing.expectError(error.RubyException, vm.defineModule("Runner"));
}

test "defineModule returns existing module" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();
    const m = try vm.defineModule("Enumerable");
    _ = m;
    const again = try vm.defineModule("Enumerable");
    _ = again;
}

test "large sources exercise the heap eval path" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();
    // > the 4 KiB stack fast path in loadString.
    var script: std.ArrayList(u8) = .empty;
    defer script.deinit(std.testing.allocator);
    var pad: std.ArrayList(u8) = .empty;
    defer pad.deinit(std.testing.allocator);
    var pi: usize = 0;
    while (pi < 900) : (pi += 1) try pad.appendSlice(std.testing.allocator, "# padding\n");
    try script.appendSlice(std.testing.allocator, pad.items);
    try script.appendSlice(std.testing.allocator, "([1, 2, 3].map { |x| x * 3 }).reduce(:+)");
    const v = try vm.loadString(script.items);
    try std.testing.expectEqual(@as(i64, 18), try v.asInt());
}

test "dupeString outlives interpreter churn" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();
    const v = try vm.loadString("'keep me'");
    const owned = try v.dupeString(std.testing.allocator);
    defer std.testing.allocator.free(owned);
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        var buf: [64]u8 = undefined;
        const src = try std.fmt.bufPrint(&buf, "\"garbage {d}\"; GC.start", .{i});
        _ = try vm.loadString(src);
    }
    try std.testing.expectEqualStrings("keep me", owned);
}

test "unsigned overflow in toValue errors rather than panics" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();
    try std.testing.expectError(error.Overflow, mruby.convert.toValue(vm.mrb, @as(u64, std.math.maxInt(u64))));
    try std.testing.expectError(error.Overflow, vm.intValue(@as(u64, std.math.maxInt(u64))));
    const v = try vm.saturatingIntValue(@as(u64, std.math.maxInt(u64)));
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), try v.asInt());
}

test "concurrent VMs on separate threads" {
    const Worker = struct {
        fn run(result: *?anyerror) void {
            runFallible() catch |err| {
                result.* = err;
            };
        }

        fn runFallible() !void {
            const vm = try mruby.Vm.init();
            defer vm.deinit();
            var i: usize = 0;
            while (i < 25) : (i += 1) {
                const v = try vm.loadString("(1..50).reduce(:+)");
                if (try v.asInt() != 1275) return error.TestUnexpectedResult;
            }
        }
    };
    var threads: [4]std.Thread = undefined;
    var results: [threads.len]?anyerror = @splat(null);
    for (&threads, &results) |*t, *result| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{result});
    }
    for (threads) |t| t.join();
    for (results) |result| if (result) |err| return err;
}

test "init failure diagnostics are queryable" {
    // Simulated by checking the API shape; a real InitFailure needs a
    // misconfigured gem set, which the build now rejects at configure time.
    _ = mruby.Vm.lastInitFailure();
}

// ---- sandboxing ---------------------------------------------------------------

const sandbox = mruby.sandbox;

test "sandbox: external terminate stops an infinite loop" {
    const iso = try spawnSealed(.{});
    defer iso.deinit();

    const Stopper = struct {
        fn run(target: sandbox.Isolate) void {
            mruby.sandbox.sleepNs(80 * std.time.ns_per_ms);
            target.terminate();
        }
    };
    var t = try std.Thread.spawn(.{}, Stopper.run, .{iso});
    defer t.join();

    try std.testing.expectError(error.ScriptTerminated, iso.run("while true; end"));
}

test "sandbox: gas cleanup cannot erase an in-flight terminate" {
    var boot = try sandbox.BootstrapIsolate.spawn(.{ .limits = .{
        .gas = .{ .per_execution = 2_000 },
    } });
    defer boot.deinit();

    const Race = struct {
        var entered = std.atomic.Value(bool).init(false);
        var released = std.atomic.Value(bool).init(false);

        fn pause(m: *mruby.Vm, self: mruby.Value) anyerror!mruby.Value {
            _ = self;
            entered.store(true, .release);
            while (!released.load(.acquire)) std.atomic.spinLoopHint();
            return m.nilValue();
        }

        fn terminate(target: sandbox.Isolate) void {
            while (!entered.load(.acquire)) std.atomic.spinLoopHint();
            target.terminate();
            released.store(true, .release);
        }
    };
    Race.entered.store(false, .release);
    Race.released.store(false, .release);

    const cls = try boot.vm().defineClass("GasCleanupRace", null);
    try cls.defineMethod("pause", Race.pause);
    const iso = try boot.seal();
    defer iso.deinit();

    var stopper = try std.Thread.spawn(.{}, Race.terminate, .{iso});
    const outcome = iso.run(
        \\i = 0
        \\begin
        \\  while i < 1_000_000_000
        \\    i += 1
        \\  end
        \\rescue Exception
        \\  GasCleanupRace.new.pause
        \\end
    );
    stopper.join();

    // Script termination has higher priority when it arrives while gas is
    // unwinding. Finalization may clear only gas, so script remains sticky.
    try std.testing.expectError(error.ScriptTerminated, outcome);
    const terminated = iso.stats();
    try std.testing.expectEqual(@as(u64, 1), terminated.gas.?.generation);
    try std.testing.expect(iso.pendingTermination());
    try std.testing.expectError(error.ScriptTerminated, iso.run("$race_must_not_run = true"));
    const repeated = iso.stats();
    try std.testing.expectEqual(terminated.instructions, repeated.instructions);
    try std.testing.expectEqual(terminated.gas.?.generation, repeated.gas.?.generation);
}

test "sandbox: wall-clock deadline" {
    const iso = try spawnSealed(.{ .limits = .{
        .gas = .{ .per_execution = std.math.maxInt(u64) },
        .wall_time_ns = 60 * std.time.ns_per_ms,
    } });
    defer iso.deinit();
    try std.testing.expectError(error.DeadlineExceeded, iso.run("while true; end"));
    const terminated = iso.stats();
    try std.testing.expectEqual(@as(u64, 1), terminated.gas.?.generation);
    try std.testing.expect(iso.pendingTermination());
    try std.testing.expectError(error.DeadlineExceeded, iso.run("$deadline_must_not_run = true"));
    const repeated = iso.stats();
    try std.testing.expectEqual(terminated.instructions, repeated.instructions);
    try std.testing.expectEqual(terminated.gas.?.generation, repeated.gas.?.generation);
}

test "sandbox: deadline is arbitrated after final native work" {
    var boot = try sandbox.BootstrapIsolate.spawn(.{ .limits = .{
        .gas = .{ .per_execution = 10_000 },
        .wall_time_ns = 1 * std.time.ns_per_ms,
    } });
    defer boot.deinit();
    const cls = try boot.vm().defineClass("DeadlineNative", null);
    try cls.defineMethod("wait", struct {
        fn call(m: *mruby.Vm, self: mruby.Value) anyerror!mruby.Value {
            _ = self;
            sandbox.sleepNs(5 * std.time.ns_per_ms);
            return m.intValue(1);
        }
    }.call);
    const iso = try boot.seal();
    defer iso.deinit();
    // Trusted bootstrap outside an execution generation gives call() a
    // receiver without starting the isolate lifetime deadline first.
    const receiver = try sandbox.internalVm(iso).loadString("DeadlineNative.new");

    try std.testing.expectError(error.DeadlineExceeded, iso.call(receiver, "wait", .{}));
}

test "sandbox: instruction gas exhausts and is deterministic" {
    const script = "x = 0\nwhile x < 500\n  x += 1\nend\nx";
    const iso1 = try spawnSealed(.{ .limits = .{ .instructions = 100_000 } });
    defer iso1.deinit();
    const r = try iso1.run(script);
    try std.testing.expectEqual(@as(i64, 500), try r.asInt());

    const iso2 = try spawnSealed(.{ .limits = .{ .instructions = 100_000 } });
    defer iso2.deinit();
    _ = try iso2.run(script);
    try std.testing.expectEqual(iso1.internal.instr_count, iso2.internal.instr_count);

    const iso3 = try spawnSealed(.{ .limits = .{ .instructions = 200 } });
    defer iso3.deinit();
    try std.testing.expectError(error.GasExhausted, iso3.run(script));
}

test "sandbox: typed RITE compiles and runs through the artifact interface" {
    var image = try mruby.sandbox.compileRite(
        std.testing.allocator,
        "6 * 7",
        .{},
    );
    defer image.deinit(std.testing.allocator);

    const iso = try spawnSealed(.{});
    defer iso.deinit();

    const result = try iso.runRite(image.view());
    try std.testing.expectEqual(@as(i64, 42), try result.asInt());
}

test "sandbox: typed RITE source name is stable across debug modes" {
    inline for (.{ false, true }) |include_debug| {
        var image = try mruby.sandbox.compileRite(
            std.testing.allocator,
            "__FILE__",
            .{
                .include_debug = include_debug,
                .source_name = "worker.rb",
            },
        );
        defer image.deinit(std.testing.allocator);

        const has_debug = std.mem.indexOf(u8, image.encoded, "DBG\x00") != null;
        try std.testing.expectEqual(include_debug, has_debug);

        const iso = try spawnSealed(.{});
        defer iso.deinit();
        const result = try iso.runRite(image.view());
        try std.testing.expectEqualStrings("worker.rb", try result.asString());
    }
}

test "sandbox: typed RITE rejects embedded NUL in source name" {
    try std.testing.expectError(
        error.InvalidSourceName,
        mruby.sandbox.compileRite(
            std.testing.allocator,
            "1",
            .{ .source_name = "bad\x00name" },
        ),
    );
}

test "sandbox: RITE compilers reject embedded NUL in source" {
    try std.testing.expectError(
        error.InvalidSource,
        mruby.sandbox.compileRite(
            std.testing.allocator,
            "1\x00 + 1",
            .{},
        ),
    );
    try std.testing.expectError(
        error.InvalidSource,
        mruby.sandbox.compile("1\x00 + 1"),
    );
}

test "sandbox: legacy raw RITE retains its null source-name semantics" {
    const image = try mruby.sandbox.compile("__FILE__");
    defer mruby.alloc.gpa.free(image);
    const iso = try spawnSealed(.{});
    defer iso.deinit();
    try std.testing.expectEqualStrings("(null)", try (try iso.runImage(image)).asString());
}

// ---- cross-version artifact fixtures --------------------------------------
// Byte fixtures produced by the v0.3.0 tag (see
// src/tests_artifacts/MANIFEST.md). These pin the current build's
// admission and restoration behavior against real older-producer bytes.

test "cross-version: v0.3.0 RITE image is rejected without execution" {
    const bytes = @embedFile("tests_artifacts/rite_image_v0_3_0.bin");
    const iso = try spawnSealed(.{ .limits = .{
        .gas = .{ .per_execution = 10_000 },
    } });
    defer iso.deinit();

    // The compatibility fingerprint changed after 0.3.0 (presym digest,
    // semantic defines, gem identity), so the old image must be rejected
    // by classification, never parsed or executed.
    try std.testing.expectError(
        error.IncompatibleRiteImage,
        iso.runRite(.{ .bytes = bytes }),
    );
    // The rejected execution leaves lifecycle state untouched.
    const stats = iso.stats();
    try std.testing.expectEqual(@as(u64, 0), stats.gas.?.generation);
    try std.testing.expect(iso.lastError() == null);
    // The same build's own image still executes.
    var image = try mruby.sandbox.compileRite(std.testing.allocator, "41 + 1", .{});
    defer image.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 42), try (try iso.runRite(image.view())).asInt());
}

test "cross-version: v0.3.0 state capsule restores into the current build" {
    const bytes = @embedFile("tests_artifacts/state_capsule_v0_3_0.bin");
    const iso = try spawnSealed(.{});
    defer iso.deinit();

    // Capsule envelopes carry schema identity, not a build fingerprint:
    // format v1 stays forward-compatible across releases.
    const restored = try iso.importValue(.{ .bytes = bytes }, .{});
    try iso.setGlobal("restored_fixture", restored);
    const check = try iso.run(
        \\$restored_fixture.size == 20 &&
        \\  $restored_fixture["0"] == [0, 0] &&
        \\  $restored_fixture["7"] == [7, 14] &&
        \\  $restored_fixture["19"] == [19, 38]
    );
    try std.testing.expect(check.isTruthy());
}

test "sandbox: invalid typed RITE leaves execution lifecycle untouched" {
    var image = try mruby.sandbox.compileRite(
        std.testing.allocator,
        "42",
        .{},
    );
    defer image.deinit(std.testing.allocator);
    const iso = try spawnSealed(.{ .limits = .{
        .gas = .{ .per_execution = 10_000 },
    } });
    defer iso.deinit();

    const before_rejection = iso.stats();
    image.encoded[image.encoded.len - 1] ^= 1;
    try std.testing.expectError(error.ChecksumMismatch, iso.runRite(image.view()));
    const rejected = iso.stats();
    try std.testing.expectEqual(before_rejection.instructions, rejected.instructions);
    try std.testing.expectEqual(before_rejection.wall_time_ns, rejected.wall_time_ns);
    try std.testing.expectEqual(before_rejection.gas.?.generation, rejected.gas.?.generation);
    try std.testing.expect(iso.lastError() == null);

    image.encoded[image.encoded.len - 1] ^= 1;
    try std.testing.expectEqual(@as(i64, 42), try (try iso.runRite(image.view())).asInt());
    try std.testing.expectEqual(@as(u64, 1), iso.stats().gas.?.generation);
}

test "sandbox: invalid typed RITE preserves a prior Ruby error" {
    var image = try mruby.sandbox.compileRite(std.testing.allocator, "42", .{});
    defer image.deinit(std.testing.allocator);
    const iso = try spawnSealed(.{ .limits = .{
        .gas = .{ .per_execution = 10_000 },
    } });
    defer iso.deinit();

    try std.testing.expectError(error.RubyException, iso.run("raise 'RITE sentinel'"));
    const before = iso.stats();
    image.encoded[image.encoded.len - 1] ^= 1;
    try std.testing.expectError(error.ChecksumMismatch, iso.runRite(image.view()));
    const after = iso.stats();
    try std.testing.expectEqual(before.instructions, after.instructions);
    try std.testing.expectEqual(before.wall_time_ns, after.wall_time_ns);
    try std.testing.expectEqual(before.gas.?.generation, after.gas.?.generation);
    try std.testing.expectEqual(before.gas.?.used, after.gas.?.used);
    const message = try iso.lastError().?.message(std.testing.allocator);
    defer std.testing.allocator.free(message);
    try std.testing.expectEqualStrings("RITE sentinel", message);
}

test "sandbox: concurrent operations on one isolate fail instead of racing" {
    const Gate = struct {
        var entered = std.atomic.Value(bool).init(false);
        var release = std.atomic.Value(bool).init(false);

        fn block(m: *mruby.Vm, self: mruby.Value) !mruby.Value {
            _ = self;
            entered.store(true, .release);
            while (!release.load(.acquire)) std.atomic.spinLoopHint();
            return m.nilValue();
        }
    };
    const Runner = struct {
        iso: mruby.sandbox.Isolate,
        failure: ?anyerror = null,

        fn run(runner: *@This()) void {
            _ = runner.iso.run("ConcurrentGate.block") catch |err| {
                runner.failure = err;
                return;
            };
        }
    };

    Gate.entered.store(false, .release);
    Gate.release.store(false, .release);
    var boot = try sandbox.BootstrapIsolate.spawn(.{});
    defer boot.deinit();
    const class = try boot.vm().defineClass("ConcurrentGate", null);
    try class.defineClassMethod("block", Gate.block);
    const iso = try boot.seal();
    defer iso.deinit();

    var runner = Runner{ .iso = iso };
    const thread = try std.Thread.spawn(.{}, Runner.run, .{&runner});
    var joined = false;
    defer if (!joined) {
        Gate.release.store(true, .release);
        thread.join();
    };

    while (!Gate.entered.load(.acquire)) std.atomic.spinLoopHint();
    try std.testing.expectError(error.IsolateThreadBusy, iso.run("1"));

    Gate.release.store(true, .release);
    thread.join();
    joined = true;
    try std.testing.expect(runner.failure == null);
}

test "sandbox: StateCapsule transfers supported scalar values between isolates" {
    const producer = try spawnSealed(.{});
    defer producer.deinit();
    const root = try producer.run(
        "[nil, false, true, -9, 1.5, :ready, \"a\\x00b\"]",
    );

    var capsule = try producer.exportValue(
        std.testing.allocator,
        root,
        .{},
    );
    defer capsule.deinit(std.testing.allocator);

    const consumer = try spawnSealed(.{});
    defer consumer.deinit();
    const restored = try consumer.importValue(capsule.view(), .{});
    try consumer.setGlobal("restored", restored);
    const matches = try consumer.run(
        "$restored == [nil, false, true, -9, 1.5, :ready, \"a\\x00b\"]",
    );
    try std.testing.expect(matches.isTruthy());
}

test "sandbox: StateCapsule export cleans up every caller allocation failure" {
    const producer = try spawnSealed(.{});
    defer producer.deinit();
    const root = try producer.run(
        \\key = "key".freeze
        \\shared = [1, 2, 3]
        \\{key => shared, :alias => shared}
    );

    const Harness = struct {
        fn run(
            allocator: std.mem.Allocator,
            iso: mruby.sandbox.Isolate,
            value: mruby.Value,
        ) !void {
            var capsule = try iso.exportValue(allocator, value, .{});
            defer capsule.deinit(allocator);
        }
    };
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        Harness.run,
        .{ producer, root },
    );
}

test "sandbox: StateCapsule copies distinct inline symbol names during export" {
    const producer = try spawnSealed(.{});
    defer producer.deinit();
    // Names of four bytes or fewer use mruby's shared mutable symbol scratch
    // buffer. Retaining the borrowed pointers would turn every entry into the
    // final name before the payload is encoded.
    const root = try producer.run("[:a, :b, :c, :zzzz]");
    var capsule = try producer.exportValue(std.testing.allocator, root, .{});
    defer capsule.deinit(std.testing.allocator);

    const consumer = try spawnSealed(.{});
    defer consumer.deinit();
    const restored = try consumer.importValue(capsule.view(), .{});
    try consumer.setGlobal("inline_symbols", restored);
    try std.testing.expect((try consumer.run("$inline_symbols == [:a, :b, :c, :zzzz]")).isTruthy());
}

test "sandbox: StateCapsule full-i64 Hash keys survive hash-table materialization" {
    const producer = try spawnSealed(.{});
    defer producer.deinit();
    try producer.setGlobal("maximum_key", try producer.intValue(std.math.maxInt(i64)));
    try producer.setGlobal("minimum_key", try producer.intValue(std.math.minInt(i64)));
    const root = try producer.run(
        \\mapping = {}
        \\index = 0
        \\while index < 20
        \\  mapping[index] = index
        \\  index += 1
        \\end
        \\mapping[$maximum_key] = :maximum
        \\mapping[$minimum_key] = :minimum
        \\mapping
    );
    var capsule = try producer.exportValue(std.testing.allocator, root, .{});
    defer capsule.deinit(std.testing.allocator);

    const consumer = try spawnSealed(.{});
    defer consumer.deinit();
    const restored = try consumer.importValue(capsule.view(), .{});
    try consumer.setGlobal("wide_integer_keys", restored);
    try consumer.setGlobal("maximum_key", try consumer.intValue(std.math.maxInt(i64)));
    try consumer.setGlobal("minimum_key", try consumer.intValue(std.math.minInt(i64)));
    const matches = try consumer.run(
        \\$wide_integer_keys.size == 22 &&
        \\  $wide_integer_keys[$maximum_key] == :maximum &&
        \\  $wide_integer_keys[$minimum_key] == :minimum &&
        \\  (($wide_integer_keys[$maximum_key] = :updated) == :updated) &&
        \\  $wide_integer_keys.size == 22 &&
        \\  $wide_integer_keys[$maximum_key] == :updated
    );
    try std.testing.expect(matches.isTruthy());
}

test "sandbox: StateCapsule export enforces Hash insertion work admission" {
    const iso = try spawnSealed(.{});
    defer iso.deinit();
    // Seed through the C ABI because this pinned parser rejects some decimal
    // literals outside its immediate-integer range even though mrb_int is i64.
    try iso.setGlobal("hash_collision_stride", try iso.intValue(0x1_0000_0000));
    const collision_hash = try iso.run(
        \\mapping = {}
        \\index = 0
        \\while index < 24
        \\  mapping[index * $hash_collision_stride] = nil
        \\  index += 1
        \\end
        \\mapping
    );
    try std.testing.expectError(error.CapsuleLimitExceeded, iso.exportValue(
        std.testing.allocator,
        collision_hash,
        .{},
    ));
    const diagnostic = iso.lastArtifactError().?;
    try std.testing.expectEqual(
        mruby.sandbox.ArtifactDiagnostic.Kind.limit_exceeded,
        diagnostic.kind,
    );
    try std.testing.expectEqualStrings("$#0.key[23]", diagnostic.graph_path.?);
    try std.testing.expect(diagnostic.encoded_offset == null);
}

test "sandbox: StateCapsule Symbol-heavy Hash uses inert name hashing" {
    if (!test_config.has_core_language_suite) return error.SkipZigTest;
    const producer = try spawnSealed(.{});
    defer producer.deinit();
    const mapping = try producer.run(
        \\mapping = {}
        \\index = 0
        \\while index < 64
        \\  mapping[("symbol" + index.to_s).to_sym] = index
        \\  index += 1
        \\end
        \\mapping
    );
    var capsule = try producer.exportValue(std.testing.allocator, mapping, .{});
    defer capsule.deinit(std.testing.allocator);

    const consumer = try spawnSealed(.{});
    defer consumer.deinit();
    const restored = try consumer.importValue(capsule.view(), .{});
    try consumer.setGlobal("symbol_hash", restored);
    try std.testing.expect((try consumer.run(
        "$symbol_hash.size == 64 && $symbol_hash[:symbol0] == 0 && $symbol_hash[:symbol63] == 63",
    )).isTruthy());
}

test "sandbox: StateCapsule catches OOM while protecting a materialized result" {
    const test_c = struct {
        extern fn mrz_artifact_test_fill_arena(mrb: *mruby.c.mrb_state) c_int;
    };

    const producer = try spawnSealed(.{});
    defer producer.deinit();
    var capsule = try producer.exportValue(
        std.testing.allocator,
        try producer.run("'arena-result'"),
        .{},
    );
    defer capsule.deinit(std.testing.allocator);

    // The consumer never runs guest code; trusted avoids capability-mask
    // allocations at seal so the first attributed arena growth is
    // deterministically refused by this cap.
    const consumer = try spawnSealed(sandbox.Policy.trusted(.{ .limits = .{
        .hard_memory_bytes = 1,
    } }));
    defer consumer.deinit();
    const entry_arena = test_c.mrz_artifact_test_fill_arena(sandbox.internalVm(consumer).mrb);
    defer mruby.c.mrz_gc_arena_restore(sandbox.internalVm(consumer).mrb, entry_arena);

    try std.testing.expectError(error.MemoryLimitExceeded, consumer.importValue(
        capsule.view(),
        .{},
    ));
    try std.testing.expect(consumer.internal.cell.hardOom());
    try std.testing.expect(mruby.c.mrz_nil_p(mruby.c.mrz_exc_value(sandbox.internalVm(consumer).mrb)));
}

test "sandbox: StateCapsule import distinguishes soft policy refusal" {
    const producer = try spawnSealed(.{});
    defer producer.deinit();
    const source_bytes = try std.testing.allocator.alloc(u8, 256 * 1024);
    defer std.testing.allocator.free(source_bytes);
    @memset(source_bytes, 's');
    var capsule = try producer.exportValue(
        std.testing.allocator,
        try producer.stringValue(source_bytes),
        .{},
    );
    defer capsule.deinit(std.testing.allocator);

    // The consumer never runs guest code; trusted avoids capability-mask
    // allocations at seal, so a one-byte soft ceiling makes the first
    // graph-construction allocation deterministically fail without setting
    // the separate hard-limit bit.
    const consumer = try spawnSealed(sandbox.Policy.trusted(.{ .limits = .{
        .memory_bytes = 1,
    } }));
    defer consumer.deinit();
    try std.testing.expectError(error.MemoryLimitExceeded, consumer.importValue(
        capsule.view(),
        .{},
    ));
    try std.testing.expect(consumer.internal.cell.softOom());
    try std.testing.expect(!consumer.internal.cell.hardOom());
    try std.testing.expect(mruby.c.mrz_nil_p(mruby.c.mrz_exc_value(sandbox.internalVm(consumer).mrb)));
}

test "sandbox: StateCapsule process allocation failures stay contained" {
    const producer = try spawnSealed(.{});
    defer producer.deinit();
    const root = try producer.run(
        \\key = "key".freeze
        \\cycle = []
        \\mapping = {key => cycle, :alias => cycle}
        \\cycle << mapping
        \\mapping
    );
    var capsule = try producer.exportValue(std.testing.allocator, root, .{});
    defer capsule.deinit(std.testing.allocator);

    const previous_allocator = mruby.alloc.gpa;
    var measurement = std.testing.FailingAllocator.init(previous_allocator, .{});
    {
        const consumer = try spawnSealed(.{});
        defer consumer.deinit();
        const result = blk: {
            mruby.alloc.gpa = measurement.allocator();
            defer mruby.alloc.gpa = previous_allocator;
            break :blk consumer.importValue(capsule.view(), .{});
        };
        _ = try result;
    }
    const allocation_count = measurement.alloc_index;
    try std.testing.expect(allocation_count > 0);

    for (0..allocation_count) |fail_index| {
        const consumer = try spawnSealed(.{});
        defer consumer.deinit();
        var failing = std.testing.FailingAllocator.init(previous_allocator, .{
            .fail_index = fail_index,
        });
        const result = blk: {
            mruby.alloc.gpa = failing.allocator();
            defer mruby.alloc.gpa = previous_allocator;
            break :blk consumer.importValue(capsule.view(), .{});
        };
        try std.testing.expectError(error.OutOfMemory, result);
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expect(mruby.c.mrz_nil_p(mruby.c.mrz_exc_value(sandbox.internalVm(consumer).mrb)));
    }
}

fn duplicateZeroHashKeyCapsule(
    allocator: std.mem.Allocator,
) !mruby.artifact.StateCapsule {
    // A canonical one-node Hash whose two keys are +0.0 and -0.0. The frame
    // and checksum are valid; only the mruby-compatible key semantics make it
    // invalid.
    var payload: [49]u8 = undefined;
    var writer = mruby.artifact.Writer.init(&payload);
    try mruby.artifact.writeStatePrelude(&writer, .{
        .node_count = 1,
        .edge_count = 4,
        .root = .{ .node_ref = 0 },
    });
    try mruby.artifact.writeNodeRecordHeader(&writer, .{
        .id = 0,
        .kind = .hash,
        .flags = 0,
        .body_len = 24,
    });
    try writer.writeU32(2);
    try mruby.artifact.writeValueRef(&writer, .{ .float = 0x0000_0000_0000_0000 });
    try mruby.artifact.writeValueRef(&writer, .{ .nil = {} });
    try mruby.artifact.writeValueRef(&writer, .{ .float = 0x8000_0000_0000_0000 });
    try mruby.artifact.writeValueRef(&writer, .{ .nil = {} });
    try writer.finish();
    return mruby.artifact.wrapState(allocator, &payload, .{});
}

fn immediateFloatCapsule(
    allocator: std.mem.Allocator,
    bits: u64,
) !mruby.artifact.StateCapsule {
    var payload: [17]u8 = undefined;
    var writer = mruby.artifact.Writer.init(&payload);
    try mruby.artifact.writeStatePrelude(&writer, .{
        .node_count = 0,
        .edge_count = 0,
        .root = .{ .float = bits },
    });
    try writer.finish();
    return mruby.artifact.wrapState(allocator, &payload, .{});
}

test "sandbox: StateCapsule preserves cycles aliases defaults order and frozen state" {
    const producer = try spawnSealed(.{});
    defer producer.deinit();
    const root = try producer.run(
        \\shared = "a\\x00b".freeze
        \\equal_but_distinct = "a\\x00b".freeze
        \\cycle = []
        \\cycle << cycle
        \\mapping = {}
        \\mapping[:first] = shared
        \\mapping[:second] = shared
        \\mapping[:equal] = equal_but_distinct
        \\mapping[:cycle] = cycle
        \\mapping.default = "fallback".freeze
        \\mapping.freeze
        \\[mapping, shared, equal_but_distinct].freeze
    );

    var capsule = try producer.exportValue(std.testing.allocator, root, .{});
    defer capsule.deinit(std.testing.allocator);

    const consumer = try spawnSealed(.{});
    defer consumer.deinit();
    const restored = try consumer.importValue(capsule.view(), .{});
    // A successful heap import deliberately leaves one ordinary arena root.
    // Prove the graph survives a full collection before the host publishes it
    // into a longer-lived Ruby root such as a global.
    mruby.alloc.enterIsolate(&consumer.internal.cell);
    mruby.c.mrb_full_gc(sandbox.internalVm(consumer).mrb);
    mruby.alloc.exitIsolate();
    try consumer.setGlobal("restored_graph", restored);
    const matches = try consumer.run(
        \\mapping = $restored_graph[0]
        \\$restored_graph.frozen? &&
        \\  mapping.frozen? &&
        \\  mapping.keys == [:first, :second, :equal, :cycle] &&
        \\  mapping[:first].equal?(mapping[:second]) &&
        \\  !mapping[:first].equal?(mapping[:equal]) &&
        \\  mapping[:first] == "a\\x00b" &&
        \\  mapping[:first].frozen? &&
        \\  mapping[:cycle].equal?(mapping[:cycle][0]) &&
        \\  mapping[:missing] == "fallback" &&
        \\  mapping.default.frozen?
    );
    try std.testing.expect(matches.isTruthy());
}

test "sandbox: StateCapsule preserves binary64 NaN payloads and signed zero" {
    const producer = try spawnSealed(.{});
    defer producer.deinit();
    const consumer = try spawnSealed(.{});
    defer consumer.deinit();

    const cases = [_]u64{
        0x7ff8_1234_5678_9abc,
        0xfff8_dead_beef_0042,
        0x0000_0000_0000_0000,
        0x8000_0000_0000_0000,
    };
    for (cases) |expected_bits| {
        // Seed through the stable wire so host floating-point construction
        // cannot canonicalize a NaN before it reaches the artifact seam.
        var seed = try immediateFloatCapsule(std.testing.allocator, expected_bits);
        defer seed.deinit(std.testing.allocator);
        const original = try producer.importValue(seed.view(), .{});
        try std.testing.expectEqual(expected_bits, @as(u64, @bitCast(try original.asFloat())));

        var exported = try producer.exportValue(std.testing.allocator, original, .{});
        defer exported.deinit(std.testing.allocator);
        const restored = try consumer.importValue(exported.view(), .{});
        try std.testing.expectEqual(expected_bits, @as(u64, @bitCast(try restored.asFloat())));
    }
}

test "sandbox: StateCapsule schema admission is explicit and minor-compatible" {
    const id = [_]u8{ 0x10, 0x21, 0x32, 0x43, 0x54, 0x65, 0x76, 0x87, 0x98, 0xa9, 0xba, 0xcb, 0xdc, 0xed, 0xfe, 0x0f };
    const produced: mruby.artifact.Schema = .{ .id = id, .major = 3, .minor = 2 };

    const producer = try spawnSealed(.{});
    defer producer.deinit();
    var capsule = try producer.exportValue(
        std.testing.allocator,
        try producer.run("[:schema, 42]"),
        .{ .schema = produced },
    );
    defer capsule.deinit(std.testing.allocator);

    const consumer = try spawnSealed(.{});
    defer consumer.deinit();
    try std.testing.expectError(error.SchemaMismatch, consumer.importValue(capsule.view(), .{}));
    try std.testing.expectEqual(
        mruby.sandbox.ArtifactDiagnostic.Kind.schema_mismatch,
        consumer.lastArtifactError().?.kind,
    );
    try std.testing.expectError(error.SchemaMismatch, consumer.importValue(capsule.view(), .{
        .accepted_schema = .{ .id = id, .major = 3, .minor = 1 },
    }));

    const restored = try consumer.importValue(capsule.view(), .{
        .accepted_schema = .{ .id = id, .major = 3, .minor = 7 },
    });
    try std.testing.expect(consumer.lastArtifactError() == null);
    try consumer.setGlobal("schema_value", restored);
    try std.testing.expect((try consumer.run("$schema_value == [:schema, 42]")).isTruthy());
}

test "sandbox: StateCapsule policy and per-call limits can only tighten" {
    const producer = try spawnSealed(.{});
    defer producer.deinit();
    const root = try producer.run("[1, 2]");

    // The graph has exactly one node and two edges.
    var boundary = try producer.exportValue(std.testing.allocator, root, .{
        .limits = .{ .max_nodes = 1, .max_total_edges = 2 },
    });
    defer boundary.deinit(std.testing.allocator);
    try std.testing.expectError(error.CapsuleLimitExceeded, producer.exportValue(
        std.testing.allocator,
        root,
        .{ .limits = .{ .max_total_edges = 1 } },
    ));
    try std.testing.expectEqual(
        mruby.sandbox.ArtifactDiagnostic.Kind.limit_exceeded,
        producer.lastArtifactError().?.kind,
    );

    const constrained = try spawnSealed(.{ .artifacts = .{
        .limits = .{ .capsule = .{ .max_total_edges = 1 } },
    } });
    defer constrained.deinit();
    try std.testing.expectError(error.CapsuleLimitExceeded, constrained.importValue(
        boundary.view(),
        .{ .limits = .{ .max_total_edges = 100 } },
    ));

    const per_call = try spawnSealed(.{});
    defer per_call.deinit();
    try std.testing.expectError(error.CapsuleLimitExceeded, per_call.importValue(
        boundary.view(),
        .{ .limits = .{ .max_total_edges = 1 } },
    ));
    try std.testing.expectError(error.ArtifactLimitExceeded, per_call.importValue(
        boundary.view(),
        .{ .limits = .{ .max_encoded_bytes = boundary.encoded.len - 1 } },
    ));
}

test "sandbox: StateCapsule rejects unsupported values and container state with paths" {
    // The ivar branch of the suite exercises instance_variable_set.
    const iso = try spawnSealed(mruby.sandbox.Policy.trusted(.{}));
    defer iso.deinit();

    const subclass = try iso.run("class ArtifactArray < Array; end; ArtifactArray.new");
    try std.testing.expectError(error.UnsupportedContainerState, iso.exportValue(
        std.testing.allocator,
        subclass,
        .{},
    ));
    try std.testing.expectEqual(
        mruby.sandbox.ArtifactDiagnostic.Kind.unsupported_container_state,
        iso.lastArtifactError().?.kind,
    );
    try std.testing.expectEqualStrings("$", iso.lastArtifactError().?.graph_path.?);

    if (test_config.has_core_language_suite) {
        // instance_variable_set is provided by mruby-object-ext, so exercise
        // this branch whenever that standard integration surface is present.
        const with_ivar = try iso.run(
            "mapping = {}; mapping.instance_variable_set(:@artifact_note, 1); mapping",
        );
        try std.testing.expectError(error.UnsupportedContainerState, iso.exportValue(
            std.testing.allocator,
            with_ivar,
            .{},
        ));
        try std.testing.expect(std.mem.startsWith(
            u8,
            iso.lastArtifactError().?.graph_path.?,
            "$#0",
        ));

        const direct_ifnone = try iso.run(
            "mapping = {}; mapping.instance_variable_set(:@ifnone, :hidden); mapping",
        );
        try std.testing.expectError(error.UnsupportedContainerState, iso.exportValue(
            std.testing.allocator,
            direct_ifnone,
            .{},
        ));

        const singleton_container = try iso.run(
            "value = []; def value.artifact_marker; :marker; end; value",
        );
        try std.testing.expectError(error.UnsupportedContainerState, iso.exportValue(
            std.testing.allocator,
            singleton_container,
            .{},
        ));
    }

    // mruby keeps an observable @ifnone ivar after assigning nil while its
    // semantic default flag is clear. Reject that state instead of silently
    // dropping the ivar from the capsule.
    const nil_default = try iso.run("mapping = {}; mapping.default = nil; mapping");
    try std.testing.expectError(error.UnsupportedContainerState, iso.exportValue(
        std.testing.allocator,
        nil_default,
        .{},
    ));

    const default_proc = try iso.run("Hash.new { |hash, key| key }");
    try std.testing.expectError(error.UnsupportedContainerState, iso.exportValue(
        std.testing.allocator,
        default_proc,
        .{},
    ));

    const unsafe_key = try iso.run("{true => 1}");
    try std.testing.expectError(error.UnsupportedHashKey, iso.exportValue(
        std.testing.allocator,
        unsafe_key,
        .{},
    ));
    try std.testing.expectEqual(
        mruby.sandbox.ArtifactDiagnostic.Kind.unsupported_hash_key,
        iso.lastArtifactError().?.kind,
    );
    try std.testing.expect(std.mem.endsWith(
        u8,
        iso.lastArtifactError().?.graph_path.?,
        ".key[0]",
    ));

    const unsupported = try iso.run("-> { 1 }");
    try std.testing.expectError(error.UnsupportedValue, iso.exportValue(
        std.testing.allocator,
        unsupported,
        .{},
    ));
}

test "sandbox: StateCapsule rejects foreign values without inspecting their graph" {
    const owner = try spawnSealed(.{});
    defer owner.deinit();
    const other = try spawnSealed(.{});
    defer other.deinit();

    try std.testing.expectError(error.ForeignValue, other.exportValue(
        std.testing.allocator,
        try owner.run("[1, 2, 3]"),
        .{},
    ));
    const diagnostic = other.lastArtifactError().?;
    try std.testing.expectEqual(mruby.sandbox.ArtifactDiagnostic.Kind.foreign_value, diagnostic.kind);
    try std.testing.expectEqualStrings("$", diagnostic.graph_path.?);
}

test "sandbox: StateCapsule reports semantic duplicate encoded Hash keys" {
    var capsule = try duplicateZeroHashKeyCapsule(std.testing.allocator);
    defer capsule.deinit(std.testing.allocator);
    const iso = try spawnSealed(.{});
    defer iso.deinit();

    try std.testing.expectError(error.InvalidArtifact, iso.importValue(capsule.view(), .{}));
    const diagnostic = iso.lastArtifactError().?;
    try std.testing.expectEqual(
        mruby.sandbox.ArtifactDiagnostic.Kind.duplicate_hash_key,
        diagnostic.kind,
    );
    try std.testing.expectEqualStrings("$#0.key[1]", diagnostic.graph_path.?);
    try std.testing.expect(diagnostic.encoded_offset != null);
}

test "sandbox: StateCapsule distinguishes framing and checksum failures" {
    const producer = try spawnSealed(.{});
    defer producer.deinit();
    var capsule = try producer.exportValue(
        std.testing.allocator,
        try producer.run("[1, 2, 3]"),
        .{},
    );
    defer capsule.deinit(std.testing.allocator);

    const consumer = try spawnSealed(.{});
    defer consumer.deinit();
    for (0..capsule.encoded.len) |cut| {
        try std.testing.expectError(error.InvalidArtifact, consumer.importValue(.{
            .bytes = capsule.encoded[0..cut],
        }, .{}));
        try std.testing.expectEqual(
            mruby.sandbox.ArtifactDiagnostic.Kind.invalid_envelope,
            consumer.lastArtifactError().?.kind,
        );
    }

    const corrupted = try std.testing.allocator.dupe(u8, capsule.encoded);
    defer std.testing.allocator.free(corrupted);
    corrupted[corrupted.len - 1] ^= 0x80;
    try std.testing.expectError(error.ChecksumMismatch, consumer.importValue(.{
        .bytes = corrupted,
    }, .{}));
    try std.testing.expectEqual(
        mruby.sandbox.ArtifactDiagnostic.Kind.checksum_mismatch,
        consumer.lastArtifactError().?.kind,
    );
}

test "sandbox: StateCapsule control operations preserve execution state and last error" {
    const iso = try spawnSealed(.{ .limits = .{
        .gas = .{ .per_execution = 100_000 },
    } });
    defer iso.deinit();
    const root = try iso.run("[1, 2, 3]");
    var capsule = try iso.exportValue(std.testing.allocator, root, .{});
    defer capsule.deinit(std.testing.allocator);

    try std.testing.expectError(error.RubyException, iso.run("raise 'artifact sentinel'"));
    const before = iso.stats();
    const before_message = try iso.lastError().?.message(std.testing.allocator);
    defer std.testing.allocator.free(before_message);
    try std.testing.expectEqualStrings("artifact sentinel", before_message);

    var second = try iso.exportValue(std.testing.allocator, root, .{});
    defer second.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidArtifact, iso.importValue(.{
        .bytes = capsule.encoded[0 .. capsule.encoded.len - 1],
    }, .{}));

    const after = iso.stats();
    try std.testing.expectEqual(before.instructions, after.instructions);
    try std.testing.expectEqual(before.wall_time_ns, after.wall_time_ns);
    try std.testing.expectEqual(before.gas.?.generation, after.gas.?.generation);
    try std.testing.expectEqual(before.gas.?.used, after.gas.?.used);
    try std.testing.expect(!iso.pendingTermination());
    const after_message = try iso.lastError().?.message(std.testing.allocator);
    defer std.testing.allocator.free(after_message);
    try std.testing.expectEqualStrings("artifact sentinel", after_message);
}

test "sandbox: StateCapsule construction does not dispatch guest overrides" {
    const producer = try spawnSealed(.{});
    defer producer.deinit();
    const root = try producer.run(
        \\key = "safe".freeze
        \\{key => [1, 2, 3]}
    );
    _ = try producer.run(
        \\class String
        \\  def hash; raise "String#hash dispatched"; end
        \\  def eql?(other); raise "String#eql? dispatched"; end
        \\end
    );
    var capsule = try producer.exportValue(std.testing.allocator, root, .{});
    defer capsule.deinit(std.testing.allocator);

    const consumer = try spawnSealed(.{});
    defer consumer.deinit();
    _ = try consumer.run(
        \\class String
        \\  def hash; raise "String#hash dispatched"; end
        \\  def eql?(other); raise "String#eql? dispatched"; end
        \\end
        \\class Array
        \\  def self.new(*args); raise "Array.new dispatched"; end
        \\end
        \\class Hash
        \\  def self.new(*args); raise "Hash.new dispatched"; end
        \\end
        \\class Object
        \\  def _dump(*args); raise "_dump dispatched"; end
        \\  def method_missing(*args); raise "method_missing dispatched"; end
        \\  def self._load(*args); raise "_load dispatched"; end
        \\end
    );
    _ = try consumer.importValue(capsule.view(), .{});
}

test "sandbox: StateCapsule operations reject a concurrently running Isolate" {
    const Gate = struct {
        var entered: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
        var release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

        fn block(m: *mruby.Vm, self: mruby.Value) !mruby.Value {
            _ = self;
            entered.store(true, .release);
            while (!release.load(.acquire)) std.atomic.spinLoopHint();
            return m.nilValue();
        }
    };
    const Runner = struct {
        iso: mruby.sandbox.Isolate,
        failure: ?anyerror = null,

        fn run(runner: *@This()) void {
            _ = runner.iso.run("ArtifactConcurrentGate.block") catch |err| {
                runner.failure = err;
                return;
            };
        }
    };

    Gate.entered.store(false, .release);
    Gate.release.store(false, .release);
    var boot = try sandbox.BootstrapIsolate.spawn(.{});
    defer boot.deinit();
    const class = try boot.vm().defineClass("ArtifactConcurrentGate", null);
    try class.defineClassMethod("block", Gate.block);
    const iso = try boot.seal();
    defer iso.deinit();
    const root = try iso.run("[1, 2]");
    var capsule = try iso.exportValue(std.testing.allocator, root, .{});
    defer capsule.deinit(std.testing.allocator);

    var runner = Runner{ .iso = iso };
    const thread = try std.Thread.spawn(.{}, Runner.run, .{&runner});
    var joined = false;
    defer if (!joined) {
        Gate.release.store(true, .release);
        thread.join();
    };
    while (!Gate.entered.load(.acquire)) std.atomic.spinLoopHint();

    try std.testing.expectError(error.IsolateThreadBusy, iso.exportValue(
        std.testing.allocator,
        root,
        .{},
    ));
    try std.testing.expectError(error.IsolateThreadBusy, iso.importValue(capsule.view(), .{}));
    try std.testing.expect(iso.lastArtifactError() == null);

    Gate.release.store(true, .release);
    thread.join();
    joined = true;
    try std.testing.expect(runner.failure == null);
}

test "sandbox: StateCapsule operations from same-Isolate callbacks are busy" {
    const Callback = struct {
        var isolate: ?mruby.sandbox.Isolate = null;
        var root: ?mruby.Value = null;
        var capsule_view: ?mruby.artifact.StateCapsuleView = null;

        fn exportBusy(m: *mruby.Vm, self: mruby.Value) anyerror!mruby.Value {
            _ = self;
            var capsule = isolate.?.exportValue(
                std.testing.allocator,
                root.?,
                .{},
            ) catch |err| {
                if (err == error.IsolateThreadBusy) return m.boolValue(true);
                return err;
            };
            defer capsule.deinit(std.testing.allocator);
            return m.boolValue(false);
        }

        fn importBusy(m: *mruby.Vm, self: mruby.Value) anyerror!mruby.Value {
            _ = self;
            _ = isolate.?.importValue(capsule_view.?, .{}) catch |err| {
                if (err == error.IsolateThreadBusy) return m.boolValue(true);
                return err;
            };
            return m.boolValue(false);
        }
    };

    var boot = try sandbox.BootstrapIsolate.spawn(.{});
    defer boot.deinit();
    const class = try boot.vm().defineClass("ArtifactCallback", null);
    try class.defineClassMethod("export_busy", Callback.exportBusy);
    try class.defineClassMethod("import_busy", Callback.importBusy);
    const iso = try boot.seal();
    defer iso.deinit();

    const root = try iso.run("[1, 2]");
    var capsule = try iso.exportValue(std.testing.allocator, root, .{});
    defer capsule.deinit(std.testing.allocator);
    Callback.isolate = iso;
    Callback.root = root;
    Callback.capsule_view = capsule.view();
    defer {
        Callback.isolate = null;
        Callback.root = null;
        Callback.capsule_view = null;
    }

    try std.testing.expect((try iso.run("ArtifactCallback.export_busy")).isTruthy());
    try std.testing.expect((try iso.run("ArtifactCallback.import_busy")).isTruthy());
}

test "sandbox: explicit per-isolate gas preserves sticky legacy behavior" {
    const iso = try spawnSealed(.{ .limits = .{
        .gas = .{ .per_isolate = 2_000 },
    } });
    defer iso.deinit();

    try std.testing.expectError(error.GasExhausted, iso.run("while true; end"));
    const before = iso.stats().instructions;
    try std.testing.expectError(error.GasExhausted, iso.run("$must_not_run = true"));
    try std.testing.expectEqual(before, iso.stats().instructions);
}

test "sandbox: per-execution gas publishes generation zero before first run" {
    const iso = try spawnSealed(.{ .limits = .{
        .gas = .{ .per_execution = 7 },
    } });
    defer iso.deinit();

    const stats = iso.stats();
    try std.testing.expectEqual(@as(u64, 0), stats.instructions);
    const gas = stats.gas.?;
    try std.testing.expectEqual(sandbox.GasScope.execution, gas.scope);
    try std.testing.expectEqual(@as(u64, 0), gas.generation);
    try std.testing.expectEqual(@as(u64, 7), gas.limit);
    try std.testing.expectEqual(@as(u64, 0), gas.used);
    try std.testing.expectEqual(@as(u64, 7), gas.remaining);
    try std.testing.expect(!gas.exhausted);
    try std.testing.expectEqual(@as(u128, 0), gas.observed_instructions);
}

test "sandbox: explicit unlimited policy publishes no gas stats" {
    const iso = try spawnSealed(.{ .limits = .{ .gas = .unlimited } });
    defer iso.deinit();
    try std.testing.expect(iso.stats().gas == null);
    _ = try iso.run("1 + 1");
    try std.testing.expect(iso.stats().gas == null);
}

test "sandbox: termination latched before entry starts no gas generation" {
    const iso = try spawnSealed(.{ .limits = .{
        .gas = .{ .per_execution = 1_000 },
    } });
    defer iso.deinit();

    iso.terminate();
    try std.testing.expect(iso.pendingTermination());
    try std.testing.expectError(error.ScriptTerminated, iso.run("$must_not_run = true"));
    const rejected = iso.stats();
    try std.testing.expectEqual(@as(u64, 0), rejected.instructions);
    try std.testing.expectEqual(@as(u64, 0), rejected.gas.?.generation);
    try std.testing.expect((try iso.getGlobal("must_not_run")).isNil());

    try std.testing.expectError(error.ScriptTerminated, iso.run("1"));
    try std.testing.expectEqual(@as(u64, 0), iso.stats().gas.?.generation);
}

test "sandbox: idle entry preserves an existing allocator attribution" {
    const iso = try spawnSealed(.{ .limits = .{
        .gas = .{ .per_execution = 1_000 },
    } });
    defer iso.deinit();

    {
        mruby.alloc.enterIsolate(&iso.internal.cell);
        defer mruby.alloc.exitIsolate();
        try std.testing.expectError(error.IsolateThreadBusy, iso.run("$must_not_run = true"));
        try std.testing.expect(mruby.alloc.currentIsolateCell() == &iso.internal.cell);
    }

    try std.testing.expectEqual(@as(u64, 0), iso.stats().gas.?.generation);
    const ok = try iso.run("42");
    try std.testing.expectEqual(@as(i64, 42), try ok.asInt());
}

test "sandbox: gas configuration is validated and cached at spawn" {
    const allocations_before = mruby.alloc.liveAllocs();
    try std.testing.expectError(error.ConflictingGasPolicy, spawnSealed(.{ .limits = .{
        .instructions = 10,
        .gas = .{ .per_execution = 10 },
    } }));
    // Conflict validation happens before the mruby heap is allocated.
    try std.testing.expectEqual(allocations_before, mruby.alloc.liveAllocs());

    const iso = try spawnSealed(.{ .limits = .{
        .gas = .{ .per_execution = 100 },
    } });
    defer iso.deinit();

    // The Isolate retains no mutable policy: gas scope and allowance were
    // resolved once at spawn and cannot be reconfigured afterwards.
    try std.testing.expectError(error.GasExhausted, iso.run("while true; end"));
    const gas = iso.stats().gas.?;
    try std.testing.expectEqual(sandbox.GasScope.execution, gas.scope);
    try std.testing.expectEqual(@as(u64, 100), gas.limit);
}

test "sandbox: exact and zero gas boundaries are observable" {
    // Calibrate the deterministic opcode count on the same public entry path.
    const calibration = try spawnSealed(.{ .limits = .{
        .gas = .{ .per_isolate = 10_000 },
    } });
    defer calibration.deinit();
    _ = try calibration.run("1");
    const exact_limit = calibration.stats().gas.?.used;
    try std.testing.expect(exact_limit > 0);

    const exact = try spawnSealed(.{ .limits = .{
        .gas = .{ .per_isolate = exact_limit },
    } });
    defer exact.deinit();
    const one = try exact.run("1");
    try std.testing.expectEqual(@as(i64, 1), try one.asInt());
    const empty = exact.stats().gas.?;
    try std.testing.expectEqual(@as(u64, 0), empty.remaining);
    try std.testing.expect(!empty.exhausted);

    // Exhaustion is observed only when a later fetch sees the empty meter.
    try std.testing.expectError(error.GasExhausted, exact.run("1"));
    try std.testing.expect(exact.stats().gas.?.exhausted);

    const zero = try spawnSealed(.{ .limits = .{
        .gas = .{ .per_execution = 0 },
    } });
    defer zero.deinit();
    try std.testing.expectError(error.GasExhausted, zero.run("1 + 1"));
    const zero_stats = zero.stats().gas.?;
    try std.testing.expectEqual(@as(u64, 0), zero_stats.used);
    try std.testing.expectEqual(@as(u64, 0), zero_stats.remaining);
    try std.testing.expect(zero_stats.exhausted);
    try std.testing.expect(zero_stats.observed_instructions >= 1);
}

test "sandbox: per-execution gas renews at each outer run" {
    const iso = try spawnSealed(.{ .limits = .{
        .gas = .{ .per_execution = 1_000 },
    } });
    defer iso.deinit();

    const first = try iso.run("$request_count ||= 0; $request_count += 1");
    try std.testing.expectEqual(@as(i64, 1), try first.asInt());
    const first_stats = iso.stats();
    const first_gas = first_stats.gas.?;
    try std.testing.expectEqual(@as(u64, 1), first_gas.generation);
    try std.testing.expect(first_gas.used > 0);
    try std.testing.expect(!first_gas.exhausted);

    const second = try iso.run("$request_count += 1");
    try std.testing.expectEqual(@as(i64, 2), try second.asInt());
    const second_stats = iso.stats();
    const second_gas = second_stats.gas.?;
    try std.testing.expectEqual(@as(u64, 2), second_gas.generation);
    try std.testing.expect(second_gas.used > 0);
    try std.testing.expect(second_stats.instructions > first_stats.instructions);
}

test "sandbox: sequential executions each receive the full fixed allowance" {
    const script = "i = 0; while i < 50; i += 1; end; i";
    const calibration = try spawnSealed(.{ .limits = .{
        .gas = .{ .per_execution = 100_000 },
    } });
    defer calibration.deinit();
    _ = try calibration.run(script);
    const allowance = calibration.stats().gas.?.used;

    const iso = try spawnSealed(.{ .limits = .{
        .gas = .{ .per_execution = allowance },
    } });
    defer iso.deinit();

    const first = try iso.run(script);
    try std.testing.expectEqual(@as(i64, 50), try first.asInt());
    const first_gas = iso.stats().gas.?;
    try std.testing.expectEqual(@as(u64, 1), first_gas.generation);
    try std.testing.expectEqual(@as(u64, 0), first_gas.remaining);
    try std.testing.expect(!first_gas.exhausted);

    const second = try iso.run(script);
    try std.testing.expectEqual(@as(i64, 50), try second.asInt());
    const second_stats = iso.stats();
    const second_gas = second_stats.gas.?;
    try std.testing.expectEqual(@as(u64, 2), second_gas.generation);
    try std.testing.expectEqual(@as(u64, 0), second_gas.remaining);
    try std.testing.expect(!second_gas.exhausted);
    try std.testing.expect(second_stats.instructions >= allowance * 2);
}

test "sandbox: per-execution gas recovers after exhaustion on the same heap" {
    const iso = try spawnSealed(.{ .limits = .{
        .gas = .{ .per_execution = 2_000 },
    } });
    defer iso.deinit();

    try std.testing.expectError(error.GasExhausted, iso.run(
        \\$gas_value = 0
        \\$gas_ensured = false
        \\begin
        \\  while $gas_value < 1_000_000_000
        \\    $gas_value += 1
        \\  end
        \\ensure
        \\  $gas_ensured = true
        \\end
    ));
    try std.testing.expect(!iso.pendingTermination());
    try std.testing.expect(iso.lastError() == null);
    const exhausted = iso.stats().gas.?;
    try std.testing.expectEqual(@as(u64, 1), exhausted.generation);
    try std.testing.expect(exhausted.exhausted);
    try std.testing.expectEqual(exhausted.limit, exhausted.used);
    try std.testing.expect(exhausted.observed_instructions >= @as(u128, exhausted.limit) + 1);

    const preserved = try iso.run("$gas_value > 0 && $gas_ensured");
    try std.testing.expect(preserved.isTruthy());
    const renewed = iso.stats().gas.?;
    try std.testing.expectEqual(@as(u64, 2), renewed.generation);
    try std.testing.expect(!renewed.exhausted);
    try std.testing.expectEqual(@as(u128, renewed.used), renewed.observed_instructions);
}

test "sandbox: run runImage and call each start a fresh gas generation" {
    const image = try sandbox.compile("6 * 7");
    defer mruby.alloc.gpa.free(image);

    const iso = try spawnSealed(.{ .limits = .{
        .gas = .{ .per_execution = 2_000 },
    } });
    defer iso.deinit();

    try std.testing.expectError(error.GasExhausted, iso.run("while true; end"));
    try std.testing.expectEqual(@as(u64, 1), iso.stats().gas.?.generation);

    const receiver = try iso.run(
        \\class GasEntryPoint
        \\  def answer
        \\    42
        \\  end
        \\end
        \\GasEntryPoint.new
    );
    try std.testing.expectEqual(@as(u64, 2), iso.stats().gas.?.generation);

    const from_image = try iso.runImage(image);
    try std.testing.expectEqual(@as(i64, 42), try from_image.asInt());
    try std.testing.expectEqual(@as(u64, 3), iso.stats().gas.?.generation);

    const from_call = try iso.call(receiver, "answer", .{});
    try std.testing.expectEqual(@as(i64, 42), try from_call.asInt());
    try std.testing.expectEqual(@as(u64, 4), iso.stats().gas.?.generation);
}

test "sandbox: per-isolate gas reports charged and observed instructions" {
    const iso = try spawnSealed(.{ .limits = .{
        .gas = .{ .per_isolate = 300 },
    } });
    defer iso.deinit();

    try std.testing.expectError(error.GasExhausted, iso.run("while true; end"));
    const stats = iso.stats();
    const gas = stats.gas.?;
    try std.testing.expectEqual(sandbox.GasScope.isolate, gas.scope);
    try std.testing.expectEqual(@as(u64, 1), gas.generation);
    try std.testing.expectEqual(@as(u64, 300), gas.used);
    try std.testing.expectEqual(@as(u64, 0), gas.remaining);
    try std.testing.expect(gas.exhausted);
    try std.testing.expect(gas.observed_instructions >= 301);
    try std.testing.expectEqual(@as(u128, stats.instructions), gas.observed_instructions);
}

test "sandbox: un-rescuable termination still runs ensure" {
    const iso = try spawnSealed(.{ .limits = .{ .instructions = 5_000 } });
    defer iso.deinit();
    // An unfinishable counted loop (an empty `while true; end` compiles to
    // a jump-to-self at the catch region start, where no raise can be
    // delivered catchably — see sandbox.zig).
    try std.testing.expectError(error.GasExhausted, iso.run(
        \\$ensured = false
        \\y = 0
        \\begin
        \\  while y < 1000000000
        \\    y += 1
        \\  end
        \\ensure
        \\  $ensured = true
        \\end
    ));
    const ensured = try iso.getGlobal("ensured");
    try std.testing.expect(ensured.isTruthy());
}

test "sandbox: termination cannot be suppressed by rescue" {
    const iso = try spawnSealed(.{ .limits = .{ .instructions = 3_000 } });
    defer iso.deinit();
    // A rescue that catches the termination grants only a bounded grace
    // budget of further execution (handler + immediate continuation);
    // the termination always surfaces to the host.
    try std.testing.expectError(error.GasExhausted, iso.run(
        \\$after = false
        \\y = 0
        \\begin
        \\  while y < 1000000000
        \\    y += 1
        \\  end
        \\rescue Exception
        \\  $after = :rescued
        \\end
        \\$after = :continued
    ));
    // Bounded execution: the run cannot have looped or continued freely.
    try std.testing.expect(iso.internal.instr_count <= 3_000 + 2_048);

    // And a long post-rescue continuation is cut off by the grace budget.
    const iso2 = try spawnSealed(.{ .limits = .{ .instructions = 3_000 } });
    defer iso2.deinit();
    try std.testing.expectError(error.GasExhausted, iso2.run(
        \\y = 0
        \\begin
        \\  while y < 1000000000
        \\    y += 1
        \\  end
        \\rescue Exception
        \\  z = 0
        \\  while z < 1000000000
        \\    z += 1
        \\  end
        \\end
    ));
    try std.testing.expect(iso2.internal.instr_count <= 3_000 + 1_024 + 4_096 + 64);
}

test "sandbox: memory cap escalates to MemoryLimitExceeded" {
    const iso = try spawnSealed(.{ .limits = .{
        .gas = .{ .per_execution = 10_000_000 },
        .memory_bytes = 2 * 1024 * 1024,
    } });
    defer iso.deinit();
    // Grow a string well past the cap; the host survives.
    try std.testing.expectError(error.MemoryLimitExceeded, iso.run(
        \\s = ""
        \\2000.times { s += "0123456789abcdef0123456789abcdef" }
        \\s.size
    ));
    try std.testing.expect(iso.internal.cell.anyOom());
    const terminated = iso.stats();
    try std.testing.expectError(error.MemoryLimitExceeded, iso.run("$memory_must_not_run = true"));
    const repeated = iso.stats();
    try std.testing.expectEqual(terminated.instructions, repeated.instructions);
    try std.testing.expectEqual(terminated.gas.?.generation, repeated.gas.?.generation);
}

test "sandbox: call-depth limit" {
    const iso = try spawnSealed(.{ .limits = .{
        .gas = .{ .per_execution = 100_000 },
        .call_depth = 8,
    } });
    defer iso.deinit();
    try std.testing.expectError(error.CallDepthExceeded, iso.run(
        \\def r(n)
        \\  r(n + 1)
        \\end
        \\r(0)
    ));
    const terminated = iso.stats();
    try std.testing.expectError(error.CallDepthExceeded, iso.run("$depth_must_not_run = true"));
    const repeated = iso.stats();
    try std.testing.expectEqual(terminated.instructions, repeated.instructions);
    try std.testing.expectEqual(terminated.gas.?.generation, repeated.gas.?.generation);
}

test "sandbox: capabilities strip eval, send, introspection, ObjectSpace" {
    const iso = try spawnSealed(.{ .capabilities = .{
        .eval = false,
        .send = false,
        .introspection = false,
        .object_space = false,
    } });
    defer iso.deinit();

    try std.testing.expectError(error.RubyException, iso.run("eval('1 + 1')"));
    try iso.clearError();
    try std.testing.expectError(error.RubyException, iso.run("[1, 2].send(:size)"));
    try iso.clearError();
    try std.testing.expectError(error.RubyException, iso.run("@x = 1; instance_variable_get(:@x)"));
    try iso.clearError();
    // mruby's `defined?` on a removed constant raises NameError (not nil);
    // either way, the constant is unreachable from scripts.
    const gone = try iso.run(
        \\begin
        \\  ObjectSpace
        \\  :reachable
        \\rescue NameError
        \\  :gone
        \\end
    );
    const gone_sym = try iso.call(gone, "to_s", .{});
    try std.testing.expectEqualStrings("gone", try gone_sym.asString());
}

test "sandbox: audited restriction inventory is enforced" {
    if (!test_config.has_core_language_suite) return error.SkipZigTest;

    var boot = try sandbox.BootstrapIsolate.spawn(.{});
    defer boot.deinit();
    if (test_config.has_object_space) {
        _ = try boot.vm().loadString("$audit_object_space = ObjectSpace");
    }
    const iso = try boot.seal();
    defer iso.deinit();

    for (authority_manifest.restricted_methods) |restriction| {
        var source_buf: [256]u8 = undefined;
        const owner = if (std.mem.eql(u8, restriction.owner, "ObjectSpace"))
            "$audit_object_space"
        else
            restriction.owner;
        const source = switch (restriction.kind) {
            .instance => try std.fmt.bufPrint(
                &source_buf,
                "{s}.method_defined?(:\"{s}\")",
                .{ owner, restriction.name },
            ),
            .class => try std.fmt.bufPrint(
                &source_buf,
                "(class << {s}; self; end).method_defined?(:\"{s}\")",
                .{ owner, restriction.name },
            ),
        };
        const visible = try iso.run(source);
        try std.testing.expect(!visible.isTruthy());
    }

    try std.testing.expectError(error.RubyException, iso.run("$audit_object_space.count_objects"));
    try iso.clearError();
    try std.testing.expectError(
        error.RubyException,
        iso.run("$audit_object_space.each_object { |_| }"),
    );
    try iso.clearError();

    for (authority_manifest.restricted_constants) |restriction| {
        var source_buf: [256]u8 = undefined;
        const source = try std.fmt.bufPrint(
            &source_buf,
            "begin; {s}::{s}; 0; rescue NameError; 1; end",
            .{ restriction.owner, restriction.name },
        );
        try std.testing.expectEqual(@as(i64, 1), try (try iso.run(source)).asInt());
    }
}

test "sandbox: introspection gate is not an information-hiding mode" {
    if (!test_config.has_core_language_suite) return error.SkipZigTest;

    const iso = try spawnSealed(.{});
    defer iso.deinit();

    try std.testing.expect((try iso.run("String.class == Class")).isTruthy());
    try std.testing.expect((try iso.run("String.ancestors.include?(Object)")).isTruthy());
    try std.testing.expect((try iso.run("String.method_defined?(:upcase)")).isTruthy());
    try std.testing.expect((try iso.run("Object.const_get(:Object) == Object")).isTruthy());
}

test "sandbox: audited frozen-class inventory is enforced" {
    if (!test_config.has_core_language_suite) return error.SkipZigTest;

    const iso = try spawnSealed(sandbox.Policy.restricted(.{}));
    defer iso.deinit();

    for (authority_manifest.frozen_classes) |name| {
        var source_buf: [192]u8 = undefined;
        const source = try std.fmt.bufPrint(
            &source_buf,
            "begin; {s}.frozen? ? 2 : 1; rescue NameError; 0; end",
            .{name},
        );
        try std.testing.expectEqual(@as(i64, 2), try (try iso.run(source)).asInt());
    }
}

test "sandbox: zero-value policy is the deny-by-default floor" {
    // A Policy constructed without a preset strips every language
    // capability, so plain compute scripts run but ambient authority does
    // not silently accrue.
    const iso = try spawnSealed(.{});
    defer iso.deinit();

    const plain = try iso.run("6 * 7");
    try std.testing.expectEqual(@as(i64, 42), try plain.asInt());
    try std.testing.expectError(error.RubyException, iso.run("eval('1 + 1')"));
    try iso.clearError();
    try std.testing.expectError(error.RubyException, iso.run("[1, 2].send(:size)"));
    try iso.clearError();
    // mruby's symbol form of reduce dispatches through `__send__`, so it is
    // intentionally unavailable with the send capability stripped. The block
    // form remains capability-independent plain computation.
    try std.testing.expectError(error.RubyException, iso.run("[1, 2, 3].reduce(:+)"));
    try iso.clearError();
    const reduced = try iso.run("[1, 2, 3].reduce { |sum, n| sum + n }");
    try std.testing.expectEqual(@as(i64, 6), try reduced.asInt());
    try std.testing.expectError(error.RubyException, iso.run("@x = 1; instance_variable_get(:@x)"));
    try iso.clearError();
    const gone = try iso.run(
        \\begin
        \\  ObjectSpace
        \\  :reachable
        \\rescue NameError
        \\  :gone
        \\end
    );
    const gone_sym = try iso.call(gone, "to_s", .{});
    try std.testing.expectEqualStrings("gone", try gone_sym.asString());
}

test "sandbox: trusted preset grants ambient language capabilities" {
    if (!test_config.has_core_language_suite) return error.SkipZigTest;

    const iso = try spawnSealed(sandbox.Policy.trusted(.{ .limits = .{
        .gas = .{ .per_isolate = 1_000_000 },
    } }));
    defer iso.deinit();

    const ev = try iso.run("eval('40 + 2')");
    try std.testing.expectEqual(@as(i64, 42), try ev.asInt());
    const sd = try iso.run("[1, 2].send(:size)");
    try std.testing.expectEqual(@as(i64, 2), try sd.asInt());
    const reduced = try iso.run("[1, 2, 3].reduce(:+)");
    try std.testing.expectEqual(@as(i64, 6), try reduced.asInt());
    const iv = try iso.run("@x = 5; instance_variable_get(:@x)");
    try std.testing.expectEqual(@as(i64, 5), try iv.asInt());
    const reachable = try iso.run(
        \\begin
        \\  ObjectSpace
        \\  :reachable
        \\rescue NameError
        \\  :gone
        \\end
    );
    const reachable_sym = try iso.call(reachable, "to_s", .{});
    try std.testing.expectEqualStrings(
        if (test_config.has_object_space) "reachable" else "gone",
        try reachable_sym.asString(),
    );
}

test "sandbox: restricted preset strips language grants and freezes the model" {
    const iso = try spawnSealed(sandbox.Policy.restricted(.{}));
    defer iso.deinit();

    try std.testing.expectError(error.RubyException, iso.run("eval('1')"));
    try iso.clearError();
    try std.testing.expectError(error.RubyException, iso.run("class String; def boom; end; end"));
    const exc = iso.lastError().?;
    const cls = try exc.className(std.testing.allocator);
    defer std.testing.allocator.free(cls);
    try std.testing.expectEqualStrings("FrozenError", cls);

    // Restricted discards language grants from the base policy rather than
    // merging them, so composition cannot re-open a stripped surface.
    const composed = try spawnSealed(
        sandbox.Policy.restricted(sandbox.Policy.trusted(.{})),
    );
    defer composed.deinit();
    try std.testing.expectError(error.RubyException, composed.run("eval('1')"));
    try composed.clearError();
    try std.testing.expectError(error.RubyException, composed.run("class String; def boom; end; end"));
}

test "sandbox: policy is resolved at spawn; host-side edits afterwards are ignored" {
    if (!test_config.has_core_language_suite) return error.SkipZigTest;

    var policy = sandbox.Policy{};
    policy.capabilities.eval = true;
    const iso = try spawnSealed(policy);
    defer iso.deinit();
    const ev = try iso.run("eval('41 + 1')");
    try std.testing.expectEqual(@as(i64, 42), try ev.asInt());

    // The isolate resolved its capability snapshot at spawn; editing the
    // host-held policy value afterwards cannot reconfigure it.
    policy.capabilities.eval = false;
    policy.limits.call_depth = 1;
    const still = try iso.run("eval('40 + 2')");
    try std.testing.expectEqual(@as(i64, 42), try still.asInt());
}

test "sandbox: seal applies capabilities at an explicit bootstrap boundary" {
    var boot = try sandbox.BootstrapIsolate.spawn(.{});
    defer boot.deinit();

    // Bootstrap window: raw-vm evaluation has not been masked yet, so the
    // host can define helpers that themselves rely on ambient methods.
    if (test_config.has_core_language_suite) {
        const pre = try boot.vm().loadString("eval('40 + 2')");
        try std.testing.expectEqual(@as(i64, 42), try pre.asInt());
    }

    const iso = try boot.seal();
    defer iso.deinit();

    // The masks are installed even though no run has happened.
    if (test_config.has_core_language_suite) {
        try std.testing.expectError(error.RubyException, iso.run("eval('1')"));
        try iso.clearError();
    }
    // A sealed isolate keeps executing compute-only scripts.
    const plain = try iso.run("21 * 2");
    try std.testing.expectEqual(@as(i64, 42), try plain.asInt());
}

test "sandbox: seal under per-execution gas keeps generation accounting" {
    var boot = try sandbox.BootstrapIsolate.spawn(.{ .limits = .{
        .gas = .{ .per_execution = 20_000 },
    } });
    defer boot.deinit();
    const iso = try boot.seal();
    defer iso.deinit();

    const r = try iso.run("40 + 1");
    try std.testing.expectEqual(@as(i64, 41), try r.asInt());
    const stats = iso.stats();
    try std.testing.expectEqual(@as(u64, 1), stats.gas.?.generation);
    try std.testing.expect(!stats.gas.?.exhausted);
}

test "sandbox: seal rejects re-entrant use from inside a host callback" {
    var boot = try sandbox.BootstrapIsolate.spawn(.{});
    defer boot.deinit();
    const cls = try boot.vm().defineClass("SealReenter", null);

    const Reenter = struct {
        var target: ?*sandbox.BootstrapIsolate = null;

        fn call(m: *mruby.Vm, self: mruby.Value) anyerror!mruby.Value {
            _ = self;
            _ = try target.?.seal();
            return m.intValue(1);
        }
    };
    Reenter.target = &boot;
    try cls.defineMethod("attempt", Reenter.call);
    const iso = try boot.seal();
    defer iso.deinit();
    try std.testing.expectError(error.RubyException, iso.run("SealReenter.new.attempt"));
    const message = try iso.lastError().?.message(std.testing.allocator);
    defer std.testing.allocator.free(message);
    // The consumed bootstrap handle was rejected inside the callback and
    // surfaced as an ordinary callback error, not a policy termination.
    try std.testing.expectEqualStrings("zig error: BootstrapHandleConsumed", message);
    // Capabilities were not applied by the rejected seal.
    const plain = try iso.run("21 * 2");
    try std.testing.expectEqual(@as(i64, 42), try plain.asInt());
    // The successful seal applied them; eval stays masked.
    try std.testing.expectError(error.RubyException, iso.run("eval('1')"));
}

test "sandbox: host globals read and write between executions" {
    const iso = try spawnSealed(.{});
    defer iso.deinit();

    _ = try iso.run("$host_value = 11");
    try std.testing.expectEqual(@as(i64, 11), try (try iso.getGlobal("host_value")).asInt());

    // Host-authored values move through the same surface.
    const read = try iso.getGlobal("host_value");
    try iso.setGlobal("host_value", read);
    _ = try iso.run("$host_value += 1");
    try std.testing.expectEqual(@as(i64, 12), try (try iso.getGlobal("host_value")).asInt());

    // Values from another interpreter are rejected.
    const other = try spawnSealed(.{});
    defer other.deinit();
    const foreign = try other.getGlobal("host_value");
    try std.testing.expectError(error.ForeignValue, iso.setGlobal("host_value", foreign));
}

test "sandbox: clearError drops the retained diagnostic" {
    const iso = try spawnSealed(.{});
    defer iso.deinit();

    try std.testing.expectError(error.RubyException, iso.run("raise 'boom'"));
    try std.testing.expect(iso.lastError() != null);
    try iso.clearError();
    try std.testing.expect(iso.lastError() == null);
    // The isolate keeps executing afterwards.
    try std.testing.expectEqual(@as(i64, 42), try (try iso.run("6 * 7")).asInt());
}

test "sandbox: host operations reject re-entrant use from callbacks" {
    var boot = try sandbox.BootstrapIsolate.spawn(.{});
    defer boot.deinit();

    const Probe = struct {
        var target: ?sandbox.Isolate = null;
        var rejected = false;

        fn call(m: *mruby.Vm, self: mruby.Value) anyerror!mruby.Value {
            _ = self;
            _ = target.?.getGlobal("x") catch |err| {
                if (err == error.IsolateThreadBusy) {
                    rejected = true;
                    return m.intValue(1);
                }
                return err;
            };
            return m.intValue(0);
        }
    };

    const cls = try boot.vm().defineClass("HostProbe", null);
    try cls.defineMethod("attempt", Probe.call);
    const iso = try boot.seal();
    defer iso.deinit();
    Probe.target = iso;
    _ = try iso.run("HostProbe.new.attempt");
    try std.testing.expect(Probe.rejected);
    // Between executions the same operation succeeds.
    try std.testing.expect((try iso.getGlobal("x")).isNil());
}

test "sandbox: frozen object model blocks def on core classes" {
    const iso = try spawnSealed(.{ .capabilities = .{ .freeze_object_model = true } });
    defer iso.deinit();
    try std.testing.expectError(error.RubyException, iso.run("class String; def boom; end; end"));
    const exc = iso.lastError().?;
    const cls = try exc.className(std.testing.allocator);
    defer std.testing.allocator.free(cls);
    try std.testing.expectEqualStrings("FrozenError", cls);
}

test "sandbox: deterministic RNG and frozen clock" {
    if (!test_config.has_random and !test_config.has_time) return error.SkipZigTest;

    if (test_config.has_random) {
        const run_pair = struct {
            fn sample(seed: u64) !i64 {
                const iso = try spawnSealed(.{ .capabilities = .{ .random_seed = seed } });
                defer iso.deinit();
                // A seeded policy owns the RNG seed; no-argument srand would
                // otherwise restore time/address-derived nondeterminism.
                try std.testing.expectError(error.RubyException, iso.run("srand()"));
                try iso.clearError();
                try std.testing.expectError(error.RubyException, iso.run("Random.new.rand"));
                try iso.clearError();
                for (authority_manifest.random_reseed_methods) |restriction| {
                    var source_buf: [256]u8 = undefined;
                    const source = switch (restriction.kind) {
                        .instance => try std.fmt.bufPrint(
                            &source_buf,
                            "{s}.method_defined?(:\"{s}\")",
                            .{ restriction.owner, restriction.name },
                        ),
                        .class => try std.fmt.bufPrint(
                            &source_buf,
                            "(class << {s}; self; end).method_defined?(:\"{s}\")",
                            .{ restriction.owner, restriction.name },
                        ),
                    };
                    const visible = try iso.run(source);
                    try std.testing.expect(!visible.isTruthy());
                }
                const v = try iso.run("rand(1 << 40)");
                return v.asInt();
            }
        }.sample;
        try std.testing.expectEqual(try run_pair(42), try run_pair(42));
        try std.testing.expectEqual(
            try run_pair(42),
            try run_pair(0xffff_ffff_0000_002a),
        );
    }

    if (test_config.has_time) {
        const iso = try spawnSealed(.{ .capabilities = .{ .clock_epoch_s = 1_700_000_000 } });
        defer iso.deinit();
        try std.testing.expectError(error.RubyException, iso.run("Time.new"));
        try iso.clearError();
        for (authority_manifest.clock_read_methods) |restriction| {
            var source_buf: [256]u8 = undefined;
            const source = switch (restriction.kind) {
                .instance => try std.fmt.bufPrint(
                    &source_buf,
                    "{s}.method_defined?(:\"{s}\")",
                    .{ restriction.owner, restriction.name },
                ),
                .class => try std.fmt.bufPrint(
                    &source_buf,
                    "(class << {s}; self; end).method_defined?(:\"{s}\")",
                    .{ restriction.owner, restriction.name },
                ),
            };
            const visible = try iso.run(source);
            try std.testing.expect(!visible.isTruthy());
        }
        const t = try iso.run("Time.now.to_i");
        try std.testing.expectEqual(@as(i64, 1_700_000_000), try t.asInt());
        const same = try iso.run("Time.now.equal?(MRubyZigSandbox::FROZEN_TIME)");
        try std.testing.expect(same.isTruthy());
        const explicit = try iso.run("Time.at(123).to_i");
        try std.testing.expectEqual(@as(i64, 123), try explicit.asInt());
    }
}

test "sandbox: capability bytecode follows the selected gas scope" {
    if (!test_config.has_random) return error.SkipZigTest;

    const renewable = try spawnSealed(.{
        .limits = .{ .gas = .{ .per_execution = 10_000 } },
        .capabilities = .{ .random_seed = 42 },
    });
    defer renewable.deinit();
    _ = try renewable.run("1");
    const renewable_stats = renewable.stats();
    // The trusted one-time srand setup executes before generation 1.
    try std.testing.expect(renewable_stats.instructions > renewable_stats.gas.?.observed_instructions);
    try std.testing.expectEqual(@as(u64, 1), renewable_stats.gas.?.generation);

    const lifetime = try spawnSealed(.{
        .limits = .{ .gas = .{ .per_isolate = 10_000 } },
        .capabilities = .{ .random_seed = 42 },
    });
    defer lifetime.deinit();
    _ = try lifetime.run("1");
    const lifetime_stats = lifetime.stats();
    // A lifetime meter is active at spawn, so the same setup is charged.
    try std.testing.expectEqual(
        @as(u128, lifetime_stats.instructions),
        lifetime_stats.gas.?.observed_instructions,
    );
}

test "sandbox: failed capability preparation is terminal before generation one" {
    if (test_config.has_random) return error.SkipZigTest;

    var boot = try sandbox.BootstrapIsolate.spawn(.{
        .limits = .{ .gas = .{ .per_execution = 10_000 } },
        // A trimmed build without mruby-random must fail loudly instead of
        // claiming a deterministic seed was installed.
        .capabilities = .{ .random_seed = 42 },
    });
    defer boot.deinit();

    // Capability preparation fails at the seal boundary, and the failure is
    // terminal for every later execution. Reach the failed state explicitly:
    // sealing cannot succeed anymore.
    try std.testing.expectError(error.CapabilityApplicationFailed, boot.seal());
    const iso = sandbox.Isolate{ .internal = boot.state.? };
    boot.state = null;
    defer iso.deinit();
    try std.testing.expectError(error.CapabilityApplicationFailed, iso.run("$must_not_run = true"));
    const failed = iso.stats();
    try std.testing.expectEqual(@as(u64, 0), failed.gas.?.generation);

    try std.testing.expectError(error.CapabilityApplicationFailed, iso.run("$must_not_run = true"));
    const repeated = iso.stats();
    try std.testing.expectEqual(failed.instructions, repeated.instructions);
    try std.testing.expectEqual(@as(u64, 0), repeated.gas.?.generation);
    try std.testing.expect((try iso.getGlobal("must_not_run")).isNil());
}

test "sandbox: nested run from a method callback" {
    var boot = try sandbox.BootstrapIsolate.spawn(.{});
    defer boot.deinit();
    const cls = try boot.vm().defineClass("Nested", null);

    const Outer = struct {
        var inner: ?sandbox.Isolate = null;
        fn call(m: *mruby.Vm, self: mruby.Value, n: i64) anyerror!mruby.Value {
            _ = self;
            const r = inner.?.run("'nested'") catch return error.NestedFailed;
            const s = r.asString() catch return error.NestedFailed;
            _ = try m.stringValue(s);
            return m.intValue(n * 2);
        }
    };
    try cls.defineMethod("scale", Outer.call);
    const iso = try boot.seal();
    defer iso.deinit();
    Outer.inner = iso;

    const r = try iso.run("Nested.new.scale(21)");
    try std.testing.expectEqual(@as(i64, 42), try r.asInt());
}

test "sandbox: nested callback re-entry shares the active gas generation" {
    var boot = try sandbox.BootstrapIsolate.spawn(.{ .limits = .{
        .gas = .{ .per_execution = 10_000 },
    } });
    defer boot.deinit();

    const Reenter = struct {
        var target: ?sandbox.Isolate = null;
        var generation_before: u64 = 0;
        var generation_after: u64 = 0;
        var used_before: u64 = 0;
        var used_after: u64 = 0;

        fn call(m: *mruby.Vm, self: mruby.Value) anyerror!mruby.Value {
            _ = self;
            const before = target.?.stats().gas.?;
            generation_before = before.generation;
            used_before = before.used;
            const inner = try target.?.run("20 + 1");
            const after = target.?.stats().gas.?;
            generation_after = after.generation;
            used_after = after.used;
            return m.intValue((try inner.asInt()) * 2);
        }
    };
    Reenter.generation_before = 0;
    Reenter.generation_after = 0;
    Reenter.used_before = 0;
    Reenter.used_after = 0;

    const cls = try boot.vm().defineClass("GasReenter", null);
    try cls.defineMethod("call", Reenter.call);
    const iso = try boot.seal();
    defer iso.deinit();
    Reenter.target = iso;

    const result = try iso.run("GasReenter.new.call");
    try std.testing.expectEqual(@as(i64, 42), try result.asInt());
    try std.testing.expectEqual(@as(u64, 1), Reenter.generation_before);
    try std.testing.expectEqual(Reenter.generation_before, Reenter.generation_after);
    try std.testing.expect(Reenter.used_after > Reenter.used_before);
    try std.testing.expectEqual(@as(u64, 1), iso.stats().gas.?.generation);
}

test "sandbox: nested callback cannot mint a replacement gas generation" {
    var boot = try sandbox.BootstrapIsolate.spawn(.{ .limits = .{
        .gas = .{ .per_execution = 1_000 },
    } });
    defer boot.deinit();

    const Reenter = struct {
        var target: ?sandbox.Isolate = null;
        fn call(m: *mruby.Vm, self: mruby.Value) anyerror!mruby.Value {
            _ = m;
            _ = self;
            _ = try target.?.run("while true; end");
            return error.TestUnexpectedResult;
        }
    };
    const cls = try boot.vm().defineClass("GasNestedExhaust", null);
    try cls.defineMethod("call", Reenter.call);
    const iso = try boot.seal();
    defer iso.deinit();
    Reenter.target = iso;

    try std.testing.expectError(error.GasExhausted, iso.run("GasNestedExhaust.new.call"));
    const exhausted = iso.stats().gas.?;
    try std.testing.expectEqual(@as(u64, 1), exhausted.generation);
    try std.testing.expect(exhausted.exhausted);

    const next = try iso.run("42");
    try std.testing.expectEqual(@as(i64, 42), try next.asInt());
    try std.testing.expectEqual(@as(u64, 2), iso.stats().gas.?.generation);
}

test "sandbox: concurrent isolates with independent policies" {
    const Worker = struct {
        fn gasLimited(result: *?anyerror) void {
            gasLimitedFallible() catch |err| {
                result.* = err;
            };
        }
        fn gasLimitedFallible() !void {
            const iso = try spawnSealed(sandbox.Policy.trusted(.{
                .limits = .{ .instructions = 500 },
            }));
            defer iso.deinit();
            try std.testing.expectError(error.GasExhausted, iso.run("while true; end"));
        }
        fn unlimited(result: *?anyerror) void {
            unlimitedFallible() catch |err| {
                result.* = err;
            };
        }
        fn unlimitedFallible() !void {
            const iso = try spawnSealed(sandbox.Policy.trusted(.{}));
            defer iso.deinit();
            const v = try iso.run("(1..20).reduce(:+)");
            if (try v.asInt() != 210) return error.TestUnexpectedResult;
        }
    };
    var result1: ?anyerror = null;
    var result2: ?anyerror = null;
    var t1 = try std.Thread.spawn(.{}, Worker.gasLimited, .{&result1});
    var t2 = try std.Thread.spawn(.{}, Worker.unlimited, .{&result2});
    t1.join();
    t2.join();
    if (result1) |err| return err;
    if (result2) |err| return err;
}

test "sandbox: irep snapshots compile and run" {
    const image = try sandbox.compile("[1, 2, 3].map { |x| x * x }");
    defer mruby.alloc.gpa.free(image);

    const iso = try spawnSealed(.{});
    defer iso.deinit();
    const r = try iso.runImage(image);
    const arr = try iso.call(r, "join", .{try iso.stringValue(",")});
    const str = try arr.asString();
    try std.testing.expectEqualStrings("1,4,9", str);

    // gas limits apply to image runs too
    const iso2 = try spawnSealed(.{ .limits = .{ .instructions = 10 } });
    defer iso2.deinit();
    try std.testing.expectError(error.GasExhausted, iso2.runImage(image));

    try std.testing.expectError(error.CompileFailed, sandbox.compile("def oops("));
}

test "sandbox: stats reflect execution" {
    const iso = try spawnSealed(.{ .limits = .{ .memory_bytes = 64 * 1024 * 1024 } });
    defer iso.deinit();
    _ = try iso.run("a = []\n1000.times { a << 'x' }\na.size");
    const s = iso.stats();
    try std.testing.expect(s.instructions > 1000);
    try std.testing.expect(s.peak_memory_bytes > 0);
    try std.testing.expect(s.live_objects > 0);
    try std.testing.expect(!s.soft_memory_limit_hit);
}

test "sandbox: host construction is charged to isolate memory" {
    const iso = try spawnSealed(sandbox.Policy.trusted(.{ .limits = .{
        .memory_bytes = 64 * 1024 * 1024,
    } }));
    defer iso.deinit();

    const before = iso.stats();
    const bytes = try std.testing.allocator.alloc(u8, 256 * 1024);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 'x');
    const string_value = try iso.stringValue(bytes);
    var rooted = try iso.root(string_value);
    defer rooted.deinit();
    const after_string = iso.stats();
    try std.testing.expect(after_string.live_memory_bytes > before.live_memory_bytes);

    const values = try std.testing.allocator.alloc(mruby.Value, 4096);
    defer std.testing.allocator.free(values);
    @memset(values, iso.nilValue());
    _ = try iso.array(values);
    const after_array = iso.stats();
    try std.testing.expect(after_array.live_memory_bytes > after_string.live_memory_bytes);

    const entries = try std.testing.allocator.alloc(mruby.HashEntry, 256);
    defer std.testing.allocator.free(entries);
    for (entries, 0..) |*entry, i| entry.* = .{
        .key = try iso.intValue(i),
        .value = iso.nilValue(),
    };
    _ = try iso.hash(entries);
    const after_hash = iso.stats();
    try std.testing.expect(after_hash.live_memory_bytes > after_array.live_memory_bytes);

    var symbol_buf: [64]u8 = undefined;
    for (0..4096) |i| {
        const symbol_name = try std.fmt.bufPrint(&symbol_buf, "host_accounted_symbol_{d}", .{i});
        _ = try iso.internSymbol(symbol_name);
    }
    const after_symbol = iso.stats();
    try std.testing.expect(after_symbol.peak_memory_bytes > after_hash.peak_memory_bytes);
    try std.testing.expect(after_symbol.peak_memory_bytes >= after_symbol.live_memory_bytes);
    try std.testing.expect(!after_symbol.soft_memory_limit_hit);

    var global_name: [200]u8 = undefined;
    @memset(&global_name, 'g');
    try iso.setGlobal(&global_name, string_value);
    try std.testing.expectEqualStrings(bytes, try (try iso.getGlobal(&global_name)).asString());
}

test "sandbox: host construction enforces sticky memory caps and restores admission" {
    const policy = sandbox.Policy.trusted(.{ .limits = .{
        .memory_bytes = 1,
        .hard_memory_bytes = std.math.maxInt(usize),
    } });
    const bytes = try std.testing.allocator.alloc(u8, 256 * 1024);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 'x');

    const string_iso = try spawnSealed(policy);
    defer string_iso.deinit();
    try std.testing.expectError(error.MemoryLimitExceeded, string_iso.stringValue(bytes));
    try std.testing.expect(string_iso.stats().soft_memory_limit_hit);
    try std.testing.expect(mruby.c.mrz_nil_p(mruby.c.mrz_exc_value(sandbox.internalVm(string_iso).mrb)));
    try std.testing.expect(mruby.alloc.currentIsolateCell() == null);
    // Clearing diagnostics is lock-only and remains available even though
    // allocating operations and guest execution are now permanently refused.
    try string_iso.clearError();
    try std.testing.expectError(error.MemoryLimitExceeded, string_iso.stringValue("retry"));

    const hard_iso = try spawnSealed(sandbox.Policy.trusted(.{ .limits = .{
        .hard_memory_bytes = 1,
    } }));
    defer hard_iso.deinit();
    try std.testing.expectError(error.MemoryLimitExceeded, hard_iso.stringValue(bytes));
    try std.testing.expect(hard_iso.stats().hard_memory_limit_hit);
    try std.testing.expect(mruby.c.mrz_nil_p(mruby.c.mrz_exc_value(sandbox.internalVm(hard_iso).mrb)));
    try std.testing.expect(mruby.alloc.currentIsolateCell() == null);

    const symbol_iso = try spawnSealed(policy);
    defer symbol_iso.deinit();
    var symbol_limit_hit = false;
    var symbol_buf: [64]u8 = undefined;
    for (0..4096) |i| {
        const symbol_name = try std.fmt.bufPrint(&symbol_buf, "host_capped_symbol_{d}", .{i});
        if (symbol_iso.internSymbol(symbol_name)) |_| {
            continue;
        } else |err| {
            try std.testing.expectEqual(error.MemoryLimitExceeded, err);
            symbol_limit_hit = true;
            break;
        }
    }
    try std.testing.expect(symbol_limit_hit);
    try std.testing.expect(symbol_iso.stats().soft_memory_limit_hit);
    try std.testing.expect(mruby.alloc.currentIsolateCell() == null);

    const array_iso = try spawnSealed(policy);
    defer array_iso.deinit();
    const array_values = try std.testing.allocator.alloc(mruby.Value, 4096);
    defer std.testing.allocator.free(array_values);
    @memset(array_values, array_iso.nilValue());
    try std.testing.expectError(error.MemoryLimitExceeded, array_iso.array(array_values));
    try std.testing.expect(array_iso.stats().soft_memory_limit_hit);
    try std.testing.expect(mruby.alloc.currentIsolateCell() == null);

    const hash_iso = try spawnSealed(policy);
    defer hash_iso.deinit();
    const hash_entries = try std.testing.allocator.alloc(mruby.HashEntry, 256);
    defer std.testing.allocator.free(hash_entries);
    for (hash_entries, 0..) |*entry, i| entry.* = .{
        .key = try hash_iso.intValue(i),
        .value = hash_iso.nilValue(),
    };
    try std.testing.expectError(error.MemoryLimitExceeded, hash_iso.hash(hash_entries));
    try std.testing.expect(hash_iso.stats().soft_memory_limit_hit);
    try std.testing.expect(mruby.alloc.currentIsolateCell() == null);
}

test "sandbox: eval strip closes every audited context-evaluation path" {
    var boot = try sandbox.BootstrapIsolate.spawn(.{ .capabilities = .{ .eval = false } });
    defer boot.deinit();
    _ = try boot.vm().loadString("$audit_binding = binding");
    const iso = try boot.seal();
    defer iso.deinit();
    // Module#class_eval / #module_eval take a source string and were a full
    // eval escape the old Kernel-only strip missed.
    try std.testing.expectError(error.RubyException, iso.run("Integer.class_eval(\"1 + 1\")"));
    try iso.clearError();
    try std.testing.expectError(error.RubyException, iso.run("Integer.module_eval(\"1 + 1\")"));
    try iso.clearError();
    // instance_eval is defined on BasicObject; a BasicObject receiver bypassed
    // a Kernel-only strip.
    try std.testing.expectError(error.RubyException, iso.run("BasicObject.new.instance_eval(\"1\")"));
    try iso.clearError();
    // Binding#eval is its own entry point and must be masked even when the
    // Kernel method used to create the binding is no longer reachable.
    try std.testing.expectError(error.RubyException, iso.run("$audit_binding.eval(\"1\")"));
    try iso.clearError();
    if (mruby.features.hasGem("mruby-class-ext")) {
        try std.testing.expectError(error.RubyException, iso.run("Integer.class_exec { 1 }"));
        try iso.clearError();
        try std.testing.expectError(error.RubyException, iso.run("Integer.module_exec { 1 }"));
    }
}

test "sandbox: ObjectSpace denial closes Class subclasses enumeration" {
    if (!mruby.features.hasGem("mruby-class-ext")) return error.SkipZigTest;

    var policy = sandbox.Policy.trusted(.{});
    policy.capabilities.object_space = false;
    const iso = try spawnSealed(policy);
    defer iso.deinit();

    try std.testing.expectError(error.RubyException, iso.run("String.subclasses"));
}

test "sandbox: frozen clock pin cannot be reassigned by a script" {
    if (!test_config.has_time) return error.SkipZigTest;

    const iso = try spawnSealed(.{ .capabilities = .{ .clock_epoch_s = 1_700_000_000 } });
    defer iso.deinit();
    // The hidden module is frozen: repointing FROZEN_TIME must raise, not
    // silently defeat the determinism pin.
    try std.testing.expectError(error.RubyException, iso.run("MRubyZigSandbox::FROZEN_TIME = Time.at(0)"));
    try iso.clearError();
    const t = try iso.run("Time.now.to_i");
    try std.testing.expectEqual(@as(i64, 1_700_000_000), try t.asInt());
}

test "sandbox: script cannot forge a policy termination" {
    const iso = try spawnSealed(.{ .limits = .{
        .gas = .{ .per_execution = 1_000 },
    } });
    defer iso.deinit();
    // Raising the sandbox's own termination class from script must surface as
    // an ordinary RubyException, never the host-trusted error.GasExhausted
    // (no real limit was hit, so the authoritative gas bit stays clear).
    try std.testing.expectError(error.RubyException, iso.run("raise MRubyZigSandbox::GasExhausted, 'fake'"));
    const class_name = try iso.lastError().?.className(std.testing.allocator);
    defer std.testing.allocator.free(class_name);
    try std.testing.expectEqualStrings("MRubyZigSandbox::GasExhausted", class_name);
    const next = try iso.run("21 * 2");
    try std.testing.expectEqual(@as(i64, 42), try next.asInt());
    try std.testing.expectEqual(@as(u64, 2), iso.stats().gas.?.generation);
}

test "sandbox: policy exception delivery does not dispatch guest factories" {
    const iso = try spawnSealed(.{ .limits = .{
        .gas = .{ .per_execution = 1_000 },
    } });
    defer iso.deinit();

    try std.testing.expectError(error.GasExhausted, iso.run(
        \\$replacement = RuntimeError.new("hijacked")
        \\class << MRubyZigSandbox::GasExhausted
        \\  def exception(*args)
        \\    $policy_factory_ran = true
        \\    $replacement
        \\  end
        \\end
        \\while true; end
    ));
    const untouched = try iso.run("$policy_factory_ran == nil");
    try std.testing.expect(untouched.isTruthy());
}

test "sandbox: lastError uses inert exception metadata" {
    const iso = try spawnSealed(.{ .limits = .{
        .gas = .{ .per_execution = 100_000 },
    } });
    defer iso.deinit();

    try std.testing.expectError(error.RubyException, iso.run(
        \\module DiagnosticOuter
        \\  class HostileError < StandardError
        \\    def to_s
        \\      $hostile_to_s_ran = true
        \\      raise "to_s was dispatched"
        \\    end
        \\    def class
        \\      $hostile_class_ran = true
        \\      String
        \\    end
        \\  end
        \\  class << HostileError
        \\    def to_s
        \\      $hostile_class_to_s_ran = true
        \\      raise "class to_s was dispatched"
        \\    end
        \\  end
        \\end
        \\raise DiagnosticOuter::HostileError, "stored\x00 snowman: ☃"
    ));

    const before = iso.stats();

    // The private root must keep both the exception and its metadata alive
    // through non-executing collection. Symbol lookups then exercise the
    // reusable short-symbol buffer before the cached class path is copied.
    {
        mruby.alloc.enterIsolate(&iso.internal.cell);
        defer mruby.alloc.exitIsolate();
        mruby.c.mrb_full_gc(sandbox.internalVm(iso).mrb);
        mruby.c.mrb_incremental_gc(sandbox.internalVm(iso).mrb);
        const vm = sandbox.internalVm(iso);
        const unrelated = try vm.internSymbol("unrelated_short_symbol");
        _ = vm.symbolName(unrelated);
    }

    const ruby_error = iso.lastError().?;
    const failed_copy = ruby_error.message(std.testing.failing_allocator);
    try std.testing.expectError(error.OutOfMemory, failed_copy);

    const message = try ruby_error.message(std.testing.allocator);
    defer std.testing.allocator.free(message);
    const class_name = try ruby_error.className(std.testing.allocator);
    defer std.testing.allocator.free(class_name);
    const repeated_message = try ruby_error.message(std.testing.allocator);
    defer std.testing.allocator.free(repeated_message);
    const repeated_class = try ruby_error.className(std.testing.allocator);
    defer std.testing.allocator.free(repeated_class);
    var details = try ruby_error.details(std.testing.allocator, .{
        .max_backtrace_frames = 1,
    });
    defer details.deinit();

    try std.testing.expectEqualStrings("stored\x00 snowman: ☃", message);
    try std.testing.expectEqualStrings("DiagnosticOuter::HostileError", class_name);
    try std.testing.expectEqualStrings(message, repeated_message);
    try std.testing.expectEqualStrings(class_name, repeated_class);
    try std.testing.expectEqualStrings(message, details.message);
    try std.testing.expectEqualStrings(class_name, details.class_name);
    try std.testing.expectEqual(@as(usize, 0), details.backtrace.len);
    try std.testing.expect(!details.backtrace_truncated);
    const after = iso.stats();
    try std.testing.expectEqual(before.instructions, after.instructions);
    try std.testing.expectEqual(before.gas.?.observed_instructions, after.gas.?.observed_instructions);
    try std.testing.expectEqual(before.gas.?.generation, after.gas.?.generation);
    try std.testing.expect(!iso.pendingTermination());
    try std.testing.expect((try iso.getGlobal("hostile_to_s_ran")).isNil());
    try std.testing.expect((try iso.getGlobal("hostile_class_ran")).isNil());
    try std.testing.expect((try iso.getGlobal("hostile_class_to_s_ran")).isNil());

    _ = try iso.run("1");
    try std.testing.expect(iso.lastError() == null);
}

test "sandbox: inert diagnostics use a fixed anonymous class fallback" {
    const iso = try spawnSealed(.{ .limits = .{
        .gas = .{ .per_execution = 10_000 },
    } });
    defer iso.deinit();

    try std.testing.expectError(error.RubyException, iso.run(
        \\anonymous = Class.new(StandardError)
        \\raise anonymous, "anonymous message"
    ));
    const ruby_error = iso.lastError().?;
    const message = try ruby_error.message(std.testing.allocator);
    defer std.testing.allocator.free(message);
    const class_name = try ruby_error.className(std.testing.allocator);
    defer std.testing.allocator.free(class_name);
    try std.testing.expectEqualStrings("anonymous message", message);
    try std.testing.expectEqualStrings("<anonymous exception>", class_name);
}

test "sandbox: rejected outer entry invalidates the previous lastError" {
    const iso = try spawnSealed(.{ .limits = .{
        .gas = .{ .per_execution = 10_000 },
    } });
    defer iso.deinit();

    try std.testing.expectError(error.RubyException, iso.run("raise 'old error'"));
    try std.testing.expect(iso.lastError() != null);
    const completed_generation = iso.stats().gas.?.generation;

    iso.terminate();
    try std.testing.expectError(error.ScriptTerminated, iso.run("1"));
    try std.testing.expect(iso.lastError() == null);
    try std.testing.expectEqual(completed_generation, iso.stats().gas.?.generation);
}

test "sandbox: private diagnostic and policy roots are hidden from ObjectSpace" {
    if (!test_config.has_object_space) return error.SkipZigTest;

    const iso = try spawnSealed(sandbox.Policy.trusted(.{ .limits = .{
        .gas = .{ .per_execution = 100_000 },
    } }));
    defer iso.deinit();

    // Freeze every guest-visible Array. The fixed diagnostic and policy root
    // arrays have no class, so ObjectSpace cannot expose or tamper with them.
    try std.testing.expectError(error.RubyException, iso.run(
        \\ObjectSpace.each_object(Array) do |array|
        \\  begin
        \\    array.freeze
        \\  rescue Exception
        \\  end
        \\end
        \\raise "root survives"
    ));
    const message = try iso.lastError().?.message(std.testing.allocator);
    defer std.testing.allocator.free(message);
    try std.testing.expectEqualStrings("root survives", message);

    try std.testing.expectError(error.GasExhausted, iso.run("while true; end"));
    try std.testing.expect(iso.lastError() == null);
}

test "sandbox: frozen object model also freezes the immediate-value singletons" {
    const iso = try spawnSealed(.{ .capabilities = .{ .freeze_object_model = true } });
    defer iso.deinit();
    try std.testing.expectError(error.RubyException, iso.run("class NilClass; def boom; end; end"));
    try iso.clearError();
    try std.testing.expectError(error.RubyException, iso.run("class FalseClass; def boom; end; end"));
}

test "sandbox: sealModel is the two-phase freeze_object_model" {
    // Phase 1: the model is unfrozen while the host loads its script, so
    // top-level definitions -- including reopening a core class -- land.
    var boot = try sandbox.BootstrapIsolate.spawn(sandbox.Policy.trusted(.{}));
    defer boot.deinit();
    _ = try boot.vm().loadString("class LoadTime; end");
    _ = try boot.vm().loadString("class String; def load_time_helper; 7; end; end");

    // Phase 2: freeze at a host-chosen time, then seal; every later run
    // sees the same frozen model the capability produces, and the
    // load-time definitions survive and stay callable.
    try boot.sealModel();
    const iso = try boot.seal();
    defer iso.deinit();
    try std.testing.expectError(error.RubyException, iso.run("class String; def later; end; end"));
    try iso.clearError();
    try std.testing.expectError(error.RubyException, iso.run("class NilClass; def boom; end; end"));
    try iso.clearError();
    const got = try iso.run("'x'.load_time_helper");
    try std.testing.expectEqual(@as(i64, 7), try got.asInt());
    _ = try iso.run("LoadTime.new");

    // Freezing again changes nothing.
    try std.testing.expectError(error.RubyException, iso.run("class String; def later; end; end"));
}

test "sandbox: a terminated isolate refuses further runs" {
    const iso = try spawnSealed(.{ .limits = .{ .instructions = 2_000 } });
    defer iso.deinit();
    try std.testing.expectError(error.GasExhausted, iso.run("while true; end"));
    // The isolate is dead: a second run must execute no script (no fresh grace
    // window) and re-report the termination immediately.
    const before = iso.stats().instructions;
    try std.testing.expectError(error.GasExhausted, iso.run("$x = 1"));
    try std.testing.expectEqual(before, iso.stats().instructions);
}

// ---- allocator ---------------------------------------------------------------

test "live allocations return to zero after teardown" {
    {
        const vm = try mruby.Vm.init();
        defer vm.deinit();
        _ = try vm.loadString("[1,2,3].map { |x| x.to_s }; 'x' * 1000");
        try std.testing.expect(mruby.alloc.liveAllocs() > 0);
    }
    try std.testing.expectEqual(@as(usize, 0), mruby.alloc.liveAllocs());
}

test "vm: value-construction OOM is contained as a Ruby exception" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();

    var bytes: [4096]u8 = undefined;
    @memset(&bytes, 'x');
    const previous = mruby.alloc.gpa;
    var failing = std.testing.FailingAllocator.init(previous, .{ .fail_index = 0 });
    const result = blk: {
        mruby.alloc.gpa = failing.allocator();
        defer mruby.alloc.gpa = previous;
        break :blk vm.stringValue(&bytes);
    };

    try std.testing.expectError(error.RubyException, result);
    try std.testing.expect(failing.has_induced_failure);
    const exception = vm.lastError() orelse return error.MissingRubyException;
    const class_name = try exception.className(std.testing.allocator);
    defer std.testing.allocator.free(class_name);
    try std.testing.expectEqualStrings("NoMemoryError", class_name);

    vm.clearError();
    try std.testing.expectEqualStrings("recovered", try (try vm.stringValue("recovered")).asString());
}

// ---- crash regressions -------------------------------------------------------

test "vm: loadString/call results stay rooted across a later GC" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();
    const s = try vm.loadString("'hello ' + 'world'");
    const up = try vm.call(s, "upcase", .{});
    // Churn the heap and force a full GC. Pre-fix, the outer arena restore
    // popped the slot mrb_protect_error used to root each result, so these
    // heap strings were collectible here — a use-after-free on the next read.
    _ = try vm.loadString("a = []; 3000.times { |i| a << i.to_s }; GC.start");
    try std.testing.expectEqualStrings("hello world", try s.asString());
    try std.testing.expectEqualStrings("HELLO WORLD", try up.asString());
}

test "class: omitted optional |S argument yields empty string, not a NULL deref" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();
    const cls = try vm.defineClass("Greeter", null);
    try cls.defineMethodRaw("greet", "|S", struct {
        fn f(m: *mruby.Vm, self: mruby.Value, name: []const u8) anyerror!mruby.Value {
            _ = self;
            var buf: [64]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "hi:{s}", .{name}) catch "hi";
            return m.stringValue(msg);
        }
    }.f);
    // No argument: the 'S' slot stays nil, which pre-fix dereferenced NULL
    // inside mrz_string_ptr. It must now default to the empty string.
    const r = try vm.loadString("Greeter.new.greet");
    try std.testing.expectEqualStrings("hi:", try r.asString());
    const r2 = try vm.loadString("Greeter.new.greet('bob')");
    try std.testing.expectEqualStrings("hi:bob", try r2.asString());
}

test "sandbox: reallocating a pre-run buffer does not underflow accounting" {
    const test_c = struct {
        extern fn mrb_str_cat(mrb: *mruby.c.mrb_state, str: mruby.c.mrb_value, p: [*]const u8, len: usize) mruby.c.mrb_value;
    };

    var boot = try sandbox.BootstrapIsolate.spawn(.{ .limits = .{ .memory_bytes = 64 * 1024 * 1024 } });
    defer boot.deinit();
    // Allocate a large buffer through the raw bootstrap VM. Post-seal host
    // construction is attributed, so the bootstrap window is the remaining
    // supported way to exercise an unowned allocation in this regression.
    const bytes = try std.testing.allocator.alloc(u8, 5_000_000);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 'x');
    const buf = try boot.vm().stringValue(bytes);
    const iso = try boot.seal();
    defer iso.deinit();
    try iso.setGlobal("buf", buf);

    // Growing it under the isolate cell reallocs a block whose `old` exceeds
    // the cell's tracked bytes; the pre-fix `live_bytes - old` underflowed
    // (Debug panic; release wrapped huge and poisoned the isolate).
    const suffix = "yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy";
    mruby.alloc.enterIsolate(&iso.internal.cell);
    defer mruby.alloc.exitIsolate();
    _ = test_c.mrb_str_cat(sandbox.internalVm(iso).mrb, buf.v, suffix.ptr, suffix.len);
    try std.testing.expect(!iso.stats().hard_memory_limit_hit);
}

test "alloc: shrinking realloc via the copy path preserves bytes" {
    // An allocator whose remap always fails, forcing the alloc+memcpy+free
    // fallback: the path where a shrink previously @memcpy'd mismatched slice
    // lengths (dest @min(old,size), src old) and panicked.
    const NoRemap = struct {
        child: std.mem.Allocator,
        fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.child.rawAlloc(len, a, ra);
        }
        fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
            return false;
        }
        fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
            return null;
        }
        fn free(ctx: *anyopaque, buf: []u8, a: std.mem.Alignment, ra: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.child.rawFree(buf, a, ra);
        }
        const vtable = std.mem.Allocator.VTable{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };
    };
    var nr = NoRemap{ .child = std.testing.allocator };
    const prev = mruby.alloc.gpa;
    mruby.alloc.gpa = .{ .ptr = &nr, .vtable = &NoRemap.vtable };
    defer mruby.alloc.gpa = prev;

    const p1 = mruby.alloc.mrb_basic_alloc_func_pub(null, 200) orelse return error.TestUnexpectedResult;
    const b1: [*]u8 = @ptrCast(p1);
    @memset(b1[0..200], 0xCD);
    // Shrink 200 -> 8: remap returns null, so the copy path runs.
    const p2 = mruby.alloc.mrb_basic_alloc_func_pub(p1, 8) orelse return error.TestUnexpectedResult;
    const b2: [*]u8 = @ptrCast(p2);
    try std.testing.expectEqual(@as(u8, 0xCD), b2[0]);
    try std.testing.expectEqual(@as(u8, 0xCD), b2[7]);
    _ = mruby.alloc.mrb_basic_alloc_func_pub(p2, 0);
}

test "sandbox: runImage surfaces an uncaught exception without poisoning the isolate" {
    const image = try sandbox.compile("raise 'boom'");
    defer mruby.alloc.gpa.free(image);
    const iso = try spawnSealed(.{});
    defer iso.deinit();
    // Pre-fix, runImage returned the RuntimeError as a successful Value and
    // left mrb->exc pending. It must now report the raise as an error.
    try std.testing.expectError(error.RubyException, iso.runImage(image));
    const msg = try iso.lastError().?.message(std.testing.allocator);
    defer std.testing.allocator.free(msg);
    try std.testing.expectEqualStrings("boom", msg);
    // And the stale exception must not leak into the next run.
    const ok = try iso.run("1 + 2");
    try std.testing.expectEqual(@as(i64, 3), try ok.asInt());
}

test "sandbox: wall_time_ns is recorded even when a run is terminated" {
    const iso = try spawnSealed(.{ .limits = .{ .wall_time_ns = 20 * std.time.ns_per_ms } });
    defer iso.deinit();
    try std.testing.expectError(error.DeadlineExceeded, iso.run("while true; end"));
    // Pre-fix, elapsed_ns was assigned only on the success path, so a killed
    // run reported 0. A deadline kill runs for about the budget.
    try std.testing.expect(iso.stats().wall_time_ns >= 10 * std.time.ns_per_ms);
}

test "class: bool 'b' method argument round-trips" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();
    const cls = try vm.defineClass("Flag", null);
    // The documented 'b' spec was a compile error (bool != 0), so any method
    // using it failed to build. Exercise it here.
    try cls.defineMethod("check", struct {
        fn f(m: *mruby.Vm, self: mruby.Value, flag: bool) anyerror!mruby.Value {
            _ = self;
            return m.stringValue(if (flag) "yes" else "no");
        }
    }.f);
    const yes = try vm.loadString("Flag.new.check(true)");
    try std.testing.expectEqualStrings("yes", try yes.asString());
    const no = try vm.loadString("Flag.new.check(false)");
    try std.testing.expectEqualStrings("no", try no.asString());
}

test "worker: typed capsule input and output cross a fresh process" {
    if (!mruby.worker.supported) return error.SkipZigTest;

    const input_schema: mruby.artifact.Schema = .{
        .id = @splat(0x31),
        .major = 1,
    };
    const output_schema: mruby.artifact.Schema = .{
        .id = @splat(0x42),
        .major = 1,
    };

    const source = try spawnSealed(.{});
    defer source.deinit();
    const input_value = try source.run("41");
    var input_capsule = try source.exportValue(std.testing.allocator, input_value, .{
        .schema = input_schema,
    });
    defer input_capsule.deinit(std.testing.allocator);

    // Core print writes to C stdout. The helper must keep that stream away
    // from its framed protocol while still returning the typed result.
    var image = try sandbox.compileRite(
        std.testing.allocator,
        "print 'discarded worker output'; $input + 1",
        .{},
    );
    defer image.deinit(std.testing.allocator);
    var report = try mruby.worker.runRite(
        std.testing.io,
        std.testing.allocator,
        test_config.worker_executable,
        .{
            .image = image.view(),
            .input = .{
                .capsule = input_capsule.view(),
                .accepted_schema = input_schema,
            },
            .output_schema = output_schema,
        },
    );
    defer report.deinit(std.testing.allocator);

    const destination = try spawnSealed(.{});
    defer destination.deinit();
    switch (report.outcome) {
        .value => |capsule| {
            const restored = try destination.importValue(capsule.view(), .{
                .accepted_schema = output_schema,
            });
            try std.testing.expectEqual(@as(i64, 42), try restored.asInt());
        },
        else => return error.UnexpectedWorkerOutcome,
    }
    try std.testing.expect(report.sandbox_stats != null);
}

test "worker: Ruby exceptions are owned after the helper exits" {
    if (!mruby.worker.supported) return error.SkipZigTest;

    var image = try sandbox.compileRite(std.testing.allocator, "raise 'worker boom'", .{});
    defer image.deinit(std.testing.allocator);
    var report = try mruby.worker.runRite(
        std.testing.io,
        std.testing.allocator,
        test_config.worker_executable,
        .{ .image = image.view() },
    );
    defer report.deinit(std.testing.allocator);

    switch (report.outcome) {
        .ruby_exception => |exception| {
            try std.testing.expectEqualStrings("RuntimeError", exception.class_name);
            try std.testing.expectEqualStrings("worker boom", exception.message);
            try std.testing.expect(!exception.truncated);
        },
        else => return error.UnexpectedWorkerOutcome,
    }
}

test "worker: sandbox gas and malformed artifacts are typed outcomes" {
    if (!mruby.worker.supported) return error.SkipZigTest;

    var looping_image = try sandbox.compileRite(std.testing.allocator, "while true; end", .{});
    defer looping_image.deinit(std.testing.allocator);
    var limited = try mruby.worker.runRite(
        std.testing.io,
        std.testing.allocator,
        test_config.worker_executable,
        .{
            .image = looping_image.view(),
            .policy = .{ .limits = .{ .gas = .{ .per_execution = 1000 } } },
        },
    );
    defer limited.deinit(std.testing.allocator);
    switch (limited.outcome) {
        .limit => |kind| try std.testing.expectEqual(mruby.worker.LimitKind.sandbox_gas, kind),
        else => return error.UnexpectedWorkerOutcome,
    }

    var damaged_image = try sandbox.compileRite(std.testing.allocator, "1", .{});
    defer damaged_image.deinit(std.testing.allocator);
    damaged_image.encoded[damaged_image.encoded.len - 1] ^= 1;
    var rejected = try mruby.worker.runRite(
        std.testing.io,
        std.testing.allocator,
        test_config.worker_executable,
        .{ .image = damaged_image.view() },
    );
    defer rejected.deinit(std.testing.allocator);
    switch (rejected.outcome) {
        .artifact_rejected => |failure| {
            try std.testing.expectEqual(mruby.worker.Phase.execute, failure.phase);
            try std.testing.expectEqual(mruby.worker.ArtifactRejection.Reason.checksum_mismatch, failure.reason);
        },
        else => return error.UnexpectedWorkerOutcome,
    }
}

test "worker: supervisor deadline hard-kills and reaps runaway Ruby" {
    if (!mruby.worker.supported) return error.SkipZigTest;

    var image = try sandbox.compileRite(std.testing.allocator, "while true; end", .{});
    defer image.deinit(std.testing.allocator);
    var report = try mruby.worker.runRite(
        std.testing.io,
        std.testing.allocator,
        test_config.worker_executable,
        .{
            .image = image.view(),
            .process = .{
                .wall_time_ns = 100 * std.time.ns_per_ms,
                .cpu_seconds = 30,
            },
        },
    );
    defer report.deinit(std.testing.allocator);
    switch (report.outcome) {
        .limit => |kind| try std.testing.expectEqual(mruby.worker.LimitKind.process_wall, kind),
        else => return error.UnexpectedWorkerOutcome,
    }
}

test "worker: process CPU exhaustion is a typed limit" {
    if (!mruby.worker.supported) return error.SkipZigTest;

    var image = try sandbox.compileRite(std.testing.allocator, "while true; end", .{});
    defer image.deinit(std.testing.allocator);
    var report = try mruby.worker.runRite(
        std.testing.io,
        std.testing.allocator,
        test_config.worker_executable,
        .{
            .image = image.view(),
            .process = .{
                .wall_time_ns = 5 * std.time.ns_per_s,
                .cpu_seconds = 1,
            },
        },
    );
    defer report.deinit(std.testing.allocator);
    switch (report.outcome) {
        .limit => |kind| try std.testing.expectEqual(mruby.worker.LimitKind.process_cpu, kind),
        else => return error.UnexpectedWorkerOutcome,
    }
}

test "worker: inherited SIGXCPU ignore and mask cannot disable CPU exhaustion" {
    if (!mruby.worker.supported) return error.SkipZigTest;

    var image = try sandbox.compileRite(std.testing.allocator, "while true; end", .{});
    defer image.deinit(std.testing.allocator);
    var report = try mruby.worker.runRite(
        std.testing.io,
        std.testing.allocator,
        test_config.worker_signal_fixture,
        .{
            .image = image.view(),
            .process = .{
                .wall_time_ns = 5 * std.time.ns_per_s,
                .cpu_seconds = 1,
            },
        },
    );
    defer report.deinit(std.testing.allocator);
    switch (report.outcome) {
        .limit => |kind| try std.testing.expectEqual(mruby.worker.LimitKind.process_cpu, kind),
        else => return error.UnexpectedWorkerOutcome,
    }
}

test "worker: a complete frame still requires clean helper exit" {
    if (!mruby.worker.supported) return error.SkipZigTest;

    try std.testing.expectError(
        error.WorkerFailed,
        mruby.worker.runRite(
            std.testing.io,
            std.testing.allocator,
            test_config.worker_descendant_fixture,
            .{ .image = .{ .bytes = "fixture:exit-nonzero" } },
        ),
    );
}

test "worker: an empty helper response fails closed at EOF" {
    if (!mruby.worker.supported) return error.SkipZigTest;

    try std.testing.expectError(
        error.TransportFailure,
        mruby.worker.runRite(
            std.testing.io,
            std.testing.allocator,
            test_config.worker_descendant_fixture,
            .{ .image = .{ .bytes = "fixture:exit-without-response" } },
        ),
    );
}

test "worker: a helper cannot hang after closing a complete response" {
    if (!mruby.worker.supported) return error.SkipZigTest;

    try std.testing.expectError(
        error.WorkerFailed,
        mruby.worker.runRite(
            std.testing.io,
            std.testing.allocator,
            test_config.worker_descendant_fixture,
            .{
                .image = .{ .bytes = "fixture:frame-and-hang" },
                .process = .{
                    .wall_time_ns = 100 * std.time.ns_per_ms,
                    .cpu_seconds = 30,
                },
            },
        ),
    );
}

test "worker: successful one-shot execution kills remaining descendants" {
    if (!mruby.worker.supported) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(tmp_path);
    const sentinel_path = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/survived",
        .{tmp_path},
    );
    defer std.testing.allocator.free(sentinel_path);

    var report = try mruby.worker.runRite(
        std.testing.io,
        std.testing.allocator,
        test_config.worker_descendant_fixture,
        .{
            .image = .{ .bytes = sentinel_path },
            .process = .{
                .wall_time_ns = 5 * std.time.ns_per_s,
                .cpu_seconds = 1,
            },
        },
    );
    defer report.deinit(std.testing.allocator);
    switch (report.outcome) {
        .limit => |kind| try std.testing.expectEqual(
            mruby.worker.LimitKind.script_terminated,
            kind,
        ),
        else => return error.UnexpectedWorkerOutcome,
    }

    try std.Io.sleep(
        std.testing.io,
        std.Io.Duration.fromNanoseconds(3 * std.time.ns_per_s),
        .awake,
    );
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.access(std.testing.io, "survived", .{}),
    );
}

test "worker: Linux address-space exhaustion remains a typed limit when Ruby rescues" {
    if (!mruby.worker.supported or builtin.os.tag != .linux or test_config.sanitize_thread) {
        return error.SkipZigTest;
    }

    const source =
        \\begin
        \\  chunks = []
        \\  while true
        \\    chunks << ("x" * 1_048_576)
        \\  end
        \\rescue NoMemoryError
        \\  42
        \\end
    ;
    var image = try sandbox.compileRite(std.testing.allocator, source, .{});
    defer image.deinit(std.testing.allocator);
    var report = try mruby.worker.runRite(
        std.testing.io,
        std.testing.allocator,
        test_config.worker_executable,
        .{
            .image = image.view(),
            .process = .{
                .wall_time_ns = 10 * std.time.ns_per_s,
                .cpu_seconds = 5,
                .address_space = .{ .bytes = 128 * 1024 * 1024 },
            },
        },
    );
    defer report.deinit(std.testing.allocator);
    switch (report.outcome) {
        .limit => |kind| try std.testing.expectEqual(
            mruby.worker.LimitKind.process_address_space,
            kind,
        ),
        else => return error.UnexpectedWorkerOutcome,
    }
    try std.testing.expect(report.sandbox_stats != null);
}

test "worker: inherited Linux address-space ceilings remain typed limits" {
    if (!mruby.worker.supported or builtin.os.tag != .linux or test_config.sanitize_thread) {
        return error.SkipZigTest;
    }

    const source =
        \\chunks = []
        \\while true
        \\  chunks << ("x" * 1_048_576)
        \\end
    ;
    var image = try sandbox.compileRite(std.testing.allocator, source, .{});
    defer image.deinit(std.testing.allocator);
    var report = try mruby.worker.runRite(
        std.testing.io,
        std.testing.allocator,
        test_config.worker_address_space_fixture,
        .{
            .image = image.view(),
            .process = .{
                .wall_time_ns = 10 * std.time.ns_per_s,
                .cpu_seconds = 5,
            },
        },
    );
    defer report.deinit(std.testing.allocator);
    switch (report.outcome) {
        .limit => |kind| try std.testing.expectEqual(
            mruby.worker.LimitKind.process_address_space,
            kind,
        ),
        else => return error.UnexpectedWorkerOutcome,
    }
}

test "worker: Linux pre-body address-space refusal survives a closed request pipe" {
    if (!mruby.worker.supported or builtin.os.tag != .linux or test_config.sanitize_thread) {
        return error.SkipZigTest;
    }

    const image_bytes = try std.testing.allocator.alloc(u8, 2 * 1024 * 1024);
    defer std.testing.allocator.free(image_bytes);
    @memset(image_bytes, 0);

    var report = try mruby.worker.runRite(
        std.testing.io,
        std.testing.allocator,
        test_config.worker_executable,
        .{
            .image = .{ .bytes = image_bytes },
            .policy = .{ .artifacts = .{ .limits = .{
                .max_rite_bytes = image_bytes.len,
            } } },
            .process = .{
                .wall_time_ns = 5 * std.time.ns_per_s,
                .cpu_seconds = 5,
                .address_space = .{ .bytes = 1 },
            },
        },
    );
    defer report.deinit(std.testing.allocator);
    switch (report.outcome) {
        .limit => |kind| try std.testing.expectEqual(
            mruby.worker.LimitKind.process_address_space,
            kind,
        ),
        else => return error.UnexpectedWorkerOutcome,
    }
}
