//! Test root: `zig build test`.

const std = @import("std");
const mruby = @import("mruby");

test {
    _ = mruby;
}

// ---- ruby integration suite ----------------------------------------------

const ruby_suites = .{
    .{ .name = "core_language", .src = @embedFile("tests_ruby/core_language.rb") },
    .{ .name = "numerics", .src = @embedFile("tests_ruby/numerics.rb") },
};

fn countLines(s: []const u8) usize {
    var n: usize = 0;
    for (s) |ch| {
        if (ch == '\n') n += 1;
    }
    return n + @intFromBool(s.len > 0 and s[s.len - 1] != '\n');
}

test "ruby integration suite" {
    inline for (ruby_suites) |suite| {
        const vm = try mruby.Vm.init();
        defer vm.deinit();
        _ = vm.loadString(suite.src) catch {
            const exc = vm.lastError().?;
            const cls = exc.className();
            defer mruby.alloc.gpa.free(cls);
            const msg = exc.message();
            defer mruby.alloc.gpa.free(msg);
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
    const class_name = exc.className();
    defer mruby.alloc.gpa.free(class_name);
    const message = exc.message();
    defer mruby.alloc.gpa.free(message);
    try std.testing.expectEqualStrings("RuntimeError", class_name);
    try std.testing.expectEqualStrings("boom", message);
}

test "syntax errors are ruby exceptions" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();
    try std.testing.expectError(error.RubyException, vm.loadString("def oops("));
}

test "stdlib gems are loaded" {
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
    math.defineMethod("add", "ii", struct {
        fn call(m: *mruby.Vm, self: mruby.Value, a: i64, b: i64) anyerror!mruby.Value {
            _ = self;
            return m.intValue(a + b);
        }
    }.call);
    math.defineMethod("greet", "S", struct {
        fn call(m: *mruby.Vm, self: mruby.Value, name: []const u8) anyerror!mruby.Value {
            _ = self;
            return m.stringValue(name);
        }
    }.call);
    math.defineMethod("opt", "i|f", struct {
        fn call(m: *mruby.Vm, self: mruby.Value, a: i64, b: f64) anyerror!mruby.Value {
            _ = self;
            return m.floatValue(@as(f64, @floatFromInt(a)) + b);
        }
    }.call);
    math.defineMethod("sum", "*", struct {
        fn call(m: *mruby.Vm, self: mruby.Value, rest: mruby.Rest) anyerror!mruby.Value {
            _ = self;
            var total: i64 = 0;
            for (0..rest.len) |i| total += try rest.get(i).asInt();
            return m.intValue(total);
        }
    }.call);
    math.defineClassMethod("version", "", struct {
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
    runner.defineMethod("twice", "&", struct {
        fn call(m: *mruby.Vm, self: mruby.Value, blk: mruby.Value) anyerror!mruby.Value {
            _ = self;
            if (blk.isNil()) return m.raise("ArgumentError", "no block given");
            const r1 = try m.call(blk, "call", .{});
            const r2 = try m.call(blk, "call", .{});
            return m.intValue(try r1.asInt() + try r2.asInt());
        }
    }.call);

    try std.testing.expectEqual(@as(i64, 30), try (try vm.loadString("Runner.new.twice { 15 }")).asInt());
    try std.testing.expectError(error.RubyException, vm.loadString("Runner.new.twice"));
}

test "zig errors surface as runtime errors" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();

    const bomb = try vm.defineClass("Bomb", null);
    bomb.defineMethod("explode", "", struct {
        fn call(m: *mruby.Vm, self: mruby.Value) anyerror!mruby.Value {
            _ = self;
            _ = m;
            return error.Kaboom;
        }
    }.call);

    try std.testing.expectError(error.RubyException, vm.loadString("Bomb.new.explode"));
    const exc = vm.lastError().?;
    const class_name = exc.className();
    defer mruby.alloc.gpa.free(class_name);
    const message = exc.message();
    defer mruby.alloc.gpa.free(message);
    try std.testing.expectEqualStrings("RuntimeError", class_name);
    try std.testing.expectEqualStrings("zig error: Kaboom", message);
}

test "zig raise surfaces custom exceptions" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();

    const guard = try vm.defineClass("Guard", null);
    guard.defineMethod("check", "i", struct {
        fn call(m: *mruby.Vm, self: mruby.Value, n: i64) anyerror!mruby.Value {
            _ = self;
            if (n < 0) return m.raise("ArgumentError", "negative");
            return m.intValue(n);
        }
    }.call);

    try std.testing.expectEqual(@as(i64, 3), try (try vm.loadString("Guard.new.check(3)")).asInt());
    try std.testing.expectError(error.RubyException, vm.loadString("Guard.new.check(-1)"));
    const exc = vm.lastError().?;
    const class_name = exc.className();
    defer mruby.alloc.gpa.free(class_name);
    try std.testing.expectEqualStrings("ArgumentError", class_name);
}

// ---- calling Ruby from Zig -------------------------------------------------

test "vm.call invokes ruby methods" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();

    const str = vm.stringValue("hello");
    const up = try vm.call(str, "upcase", .{});
    try std.testing.expectEqualStrings("HELLO", try up.asString());

    const sqrt = try vm.call(try vm.loadString("Math"), "sqrt", .{@as(f64, 144.0)});
    try std.testing.expectEqual(@as(f64, 12.0), try sqrt.asFloat());

    try std.testing.expectError(error.RubyException, vm.call(str, "nope", .{}));
}

test "globals and ivars" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();

    _ = try vm.loadString("$answer = 42");
    try std.testing.expectEqual(@as(i64, 42), try (try vm.getGlobal("answer")).asInt());
    try vm.setGlobal("name", vm.stringValue("zig"));
    try std.testing.expectEqualStrings("zig", try (try vm.loadString("$name")).asString());

    const obj = try vm.loadString("Object.new.tap { |o| o.instance_variable_set(:@v, 7) }");
    try std.testing.expectEqual(@as(i64, 7), try vm.getIvar(obj, "@v").asInt());
}

// ---- classes ---------------------------------------------------------------

test "class lookup and constants" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();

    const math = try vm.getClass("Math");
    math.defineConst("MRB_ZIG", vm.intValue(1));
    try std.testing.expectEqual(@as(i64, 1), try (try vm.loadString("Math::MRB_ZIG")).asInt());

    // nested lookup through ::
    const lazy = try vm.getClass("Enumerator::Lazy");
    _ = lazy;

    try std.testing.expectError(error.UnknownClass, vm.getClass("NoSuchThing"));
    try std.testing.expectError(error.UnknownClass, vm.getClass("Enumerator::Nope"));
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
        var class_ptr: ?*mruby.c.RClass = null;

        fn bump(m: *mruby.Vm, self: mruby.Value) anyerror!mruby.Value {
            const p = Counter.unwrap(m.mrb, self) orelse return m.raise("TypeError", "not a Counter");
            p.* += 1;
            return m.intValue(p.*);
        }

        fn newCount(m: *mruby.Vm, self: mruby.Value, start: i64) anyerror!mruby.Value {
            _ = self;
            const p = try mruby.alloc.gpa.create(i32);
            p.* = @intCast(start);
            return Counter.wrap(m.mrb, class_ptr.?, p);
        }
    };

    const counter_class = try vm.defineClass("Counter", null);
    CounterImpl.class_ptr = counter_class.class;
    counter_class.defineMethod("bump", "", CounterImpl.bump);
    counter_class.defineClassMethod("new_count", "i", CounterImpl.newCount);

    try std.testing.expectEqual(@as(i64, 6), try (try vm.loadString("Counter.new_count(5).bump")).asInt());

    // Drop all references and force a full GC: the wrapper is collected and
    // the Zig destructor must run (the counter was bumped to 6).
    _ = try vm.loadString("GC.start");
    try std.testing.expectEqual(@as(i32, 6), destroyed_total);
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

// ---- arena -----------------------------------------------------------------

test "values rooted in globals survive gc churn" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();

    // Values returned by loadString are not GC-rooted after the call
    // returns; to hold them across further Ruby execution, root them (a
    // global here; ivars or the GC register API work too).
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
    // Saturation for the infallible callback helper.
    const v = vm.intValue(@as(u64, std.math.maxInt(u64)));
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), try v.asInt());
}

test "concurrent VMs on separate threads" {
    const Worker = struct {
        fn run() !void {
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
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{});
    for (threads) |t| t.join();
}

test "init failure diagnostics are queryable" {
    // Simulated by checking the API shape; a real InitFailure needs a
    // misconfigured gem set, which the build now rejects at configure time.
    _ = mruby.Vm.lastInitFailure();
}

// ---- sandboxing ---------------------------------------------------------------

const sandbox = mruby.sandbox;

test "sandbox: external terminate stops an infinite loop" {
    const iso = try sandbox.Isolate.spawn(.{});
    defer iso.deinit();

    const Stopper = struct {
        fn run(target: *sandbox.Isolate) void {
            mruby.sandbox.sleepNs(80 * std.time.ns_per_ms);
            target.terminate();
        }
    };
    var t = try std.Thread.spawn(.{}, Stopper.run, .{iso});
    defer t.join();

    try std.testing.expectError(error.ScriptTerminated, iso.run("while true; end"));
}

test "sandbox: wall-clock deadline" {
    const iso = try sandbox.Isolate.spawn(.{ .limits = .{ .wall_time_ns = 60 * std.time.ns_per_ms } });
    defer iso.deinit();
    try std.testing.expectError(error.DeadlineExceeded, iso.run("while true; end"));
}

test "sandbox: instruction gas exhausts and is deterministic" {
    const script = "x = 0\nwhile x < 500\n  x += 1\nend\nx";
    const iso1 = try sandbox.Isolate.spawn(.{ .limits = .{ .instructions = 100_000 } });
    defer iso1.deinit();
    const r = try iso1.run(script);
    try std.testing.expectEqual(@as(i64, 500), try r.asInt());

    const iso2 = try sandbox.Isolate.spawn(.{ .limits = .{ .instructions = 100_000 } });
    defer iso2.deinit();
    _ = try iso2.run(script);
    try std.testing.expectEqual(iso1.instr_count, iso2.instr_count);

    const iso3 = try sandbox.Isolate.spawn(.{ .limits = .{ .instructions = 200 } });
    defer iso3.deinit();
    try std.testing.expectError(error.GasExhausted, iso3.run(script));
}

test "sandbox: un-rescuable termination still runs ensure" {
    const iso = try sandbox.Isolate.spawn(.{ .limits = .{ .instructions = 5_000 } });
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
    const ensured = try iso.vm.getGlobal("ensured");
    try std.testing.expect(ensured.isTruthy());
}

test "sandbox: termination cannot be suppressed by rescue" {
    const iso = try sandbox.Isolate.spawn(.{ .limits = .{ .instructions = 3_000 } });
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
    try std.testing.expect(iso.instr_count <= 3_000 + 2_048);

    // And a long post-rescue continuation is cut off by the grace budget.
    const iso2 = try sandbox.Isolate.spawn(.{ .limits = .{ .instructions = 3_000 } });
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
    try std.testing.expect(iso2.instr_count <= 3_000 + 1_024 + 4_096 + 64);
}

test "sandbox: memory cap escalates to MemoryLimitExceeded" {
    const iso = try sandbox.Isolate.spawn(.{ .limits = .{ .memory_bytes = 2 * 1024 * 1024 } });
    defer iso.deinit();
    // Grow a string well past the cap; the host survives.
    try std.testing.expectError(error.MemoryLimitExceeded, iso.run(
        \\s = ""
        \\2000.times { s += "0123456789abcdef0123456789abcdef" }
        \\s.size
    ));
    try std.testing.expect(iso.cell.soft_oom or iso.cell.hard_oom);
}

test "sandbox: call-depth limit" {
    const iso = try sandbox.Isolate.spawn(.{ .limits = .{ .call_depth = 8 } });
    defer iso.deinit();
    try std.testing.expectError(error.CallDepthExceeded, iso.run(
        \\def r(n)
        \\  r(n + 1)
        \\end
        \\r(0)
    ));
}

test "sandbox: capabilities strip eval, send, introspection, ObjectSpace" {
    const iso = try sandbox.Isolate.spawn(.{ .capabilities = .{
        .eval = false,
        .send = false,
        .introspection = false,
        .object_space = false,
    } });
    defer iso.deinit();

    try std.testing.expectError(error.RubyException, iso.run("eval('1 + 1')"));
    iso.vm.clearError();
    try std.testing.expectError(error.RubyException, iso.run("[1, 2].send(:size)"));
    iso.vm.clearError();
    try std.testing.expectError(error.RubyException, iso.run("@x = 1; instance_variable_get(:@x)"));
    iso.vm.clearError();
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

test "sandbox: frozen object model blocks def on core classes" {
    const iso = try sandbox.Isolate.spawn(.{ .capabilities = .{ .freeze_object_model = true } });
    defer iso.deinit();
    try std.testing.expectError(error.RubyException, iso.run("class String; def boom; end; end"));
    const exc = iso.lastError().?;
    const cls = exc.className();
    defer mruby.alloc.gpa.free(cls);
    try std.testing.expectEqualStrings("FrozenError", cls);
}

test "sandbox: deterministic RNG and frozen clock" {
    const run_pair = struct {
        fn sample(seed: u64) !i64 {
            const iso = try sandbox.Isolate.spawn(.{ .capabilities = .{ .random_seed = seed } });
            defer iso.deinit();
            const v = try iso.run("rand(1 << 40)");
            return v.asInt();
        }
    }.sample;
    try std.testing.expectEqual(try run_pair(42), try run_pair(42));

    const iso = try sandbox.Isolate.spawn(.{ .capabilities = .{ .clock_epoch_s = 1_700_000_000 } });
    defer iso.deinit();
    const t = try iso.run("Time.now.to_i");
    try std.testing.expectEqual(@as(i64, 1_700_000_000), try t.asInt());
    const same = try iso.run("Time.now.equal?(MRubyZigSandbox::FROZEN_TIME)");
    try std.testing.expect(same.isTruthy());
}

test "sandbox: nested run from a method callback" {
    const iso = try sandbox.Isolate.spawn(.{});
    defer iso.deinit();

    const Outer = struct {
        var inner: ?*sandbox.Isolate = null;
        fn call(m: *mruby.Vm, self: mruby.Value, n: i64) anyerror!mruby.Value {
            _ = self;
            const r = inner.?.run("'nested'") catch return error.NestedFailed;
            const s = r.asString() catch return error.NestedFailed;
            _ = m.stringValue(s);
            return m.intValue(n * 2);
        }
    };
    Outer.inner = iso;
    const cls = try iso.vm.defineClass("Nested", null);
    cls.defineMethod("scale", "i", Outer.call);

    const r = try iso.run("Nested.new.scale(21)");
    try std.testing.expectEqual(@as(i64, 42), try r.asInt());
}

test "sandbox: concurrent isolates with independent policies" {
    const Worker = struct {
        fn gasLimited() !void {
            const iso = try sandbox.Isolate.spawn(.{ .limits = .{ .instructions = 500 } });
            defer iso.deinit();
            try std.testing.expectError(error.GasExhausted, iso.run("while true; end"));
        }
        fn unlimited() !void {
            const iso = try sandbox.Isolate.spawn(.{});
            defer iso.deinit();
            const v = try iso.run("(1..20).reduce(:+)");
            if (try v.asInt() != 210) return error.TestUnexpectedResult;
        }
    };
    var t1 = try std.Thread.spawn(.{}, Worker.gasLimited, .{});
    var t2 = try std.Thread.spawn(.{}, Worker.unlimited, .{});
    t1.join();
    t2.join();
}

test "sandbox: irep snapshots compile and run" {
    const image = try sandbox.compile("[1, 2, 3].map { |x| x * x }");
    defer mruby.alloc.gpa.free(image);

    const iso = try sandbox.Isolate.spawn(.{});
    defer iso.deinit();
    const r = try iso.runImage(image);
    const arr = try iso.call(r, "join", .{iso.vm.stringValue(",")});
    const str = try arr.asString();
    try std.testing.expectEqualStrings("1,4,9", str);

    // gas limits apply to image runs too
    const iso2 = try sandbox.Isolate.spawn(.{ .limits = .{ .instructions = 10 } });
    defer iso2.deinit();
    try std.testing.expectError(error.GasExhausted, iso2.runImage(image));

    try std.testing.expectError(error.CompileFailed, sandbox.compile("def oops("));
}

test "sandbox: stats reflect execution" {
    const iso = try sandbox.Isolate.spawn(.{ .limits = .{ .memory_bytes = 64 * 1024 * 1024 } });
    defer iso.deinit();
    _ = try iso.run("a = []\n1000.times { a << 'x' }\na.size");
    const s = iso.stats();
    try std.testing.expect(s.instructions > 1000);
    try std.testing.expect(s.peak_memory_bytes > 0);
    try std.testing.expect(s.live_objects > 0);
    try std.testing.expect(!s.soft_memory_limit_hit);
}

test "sandbox: eval strip closes class_eval and BasicObject#instance_eval" {
    const iso = try sandbox.Isolate.spawn(.{ .capabilities = .{ .eval = false } });
    defer iso.deinit();
    // Module#class_eval / #module_eval take a source string and were a full
    // eval escape the old Kernel-only strip missed.
    try std.testing.expectError(error.RubyException, iso.run("Integer.class_eval(\"1 + 1\")"));
    iso.vm.clearError();
    try std.testing.expectError(error.RubyException, iso.run("Integer.module_eval(\"1 + 1\")"));
    iso.vm.clearError();
    // instance_eval is defined on BasicObject; a BasicObject receiver bypassed
    // a Kernel-only strip.
    try std.testing.expectError(error.RubyException, iso.run("BasicObject.new.instance_eval(\"1\")"));
}

test "sandbox: frozen clock pin cannot be reassigned by a script" {
    const iso = try sandbox.Isolate.spawn(.{ .capabilities = .{ .clock_epoch_s = 1_700_000_000 } });
    defer iso.deinit();
    // The hidden module is frozen: repointing FROZEN_TIME must raise, not
    // silently defeat the determinism pin.
    try std.testing.expectError(error.RubyException, iso.run("MRubyZigSandbox::FROZEN_TIME = Time.at(0)"));
    iso.vm.clearError();
    const t = try iso.run("Time.now.to_i");
    try std.testing.expectEqual(@as(i64, 1_700_000_000), try t.asInt());
}

test "sandbox: script cannot forge a policy termination" {
    const iso = try sandbox.Isolate.spawn(.{});
    defer iso.deinit();
    // Raising the sandbox's own termination class from script must surface as
    // an ordinary RubyException, never the host-trusted error.GasExhausted
    // (no real limit was hit, so terminate_flag stays clear).
    try std.testing.expectError(error.RubyException, iso.run("raise MRubyZigSandbox::GasExhausted, 'fake'"));
}

test "sandbox: frozen object model also freezes the immediate-value singletons" {
    const iso = try sandbox.Isolate.spawn(.{ .capabilities = .{ .freeze_object_model = true } });
    defer iso.deinit();
    try std.testing.expectError(error.RubyException, iso.run("class NilClass; def boom; end; end"));
    iso.vm.clearError();
    try std.testing.expectError(error.RubyException, iso.run("class FalseClass; def boom; end; end"));
}

test "sandbox: a terminated isolate refuses further runs" {
    const iso = try sandbox.Isolate.spawn(.{ .limits = .{ .instructions = 2_000 } });
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
    cls.defineMethod("greet", "|S", struct {
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
    const iso = try sandbox.Isolate.spawn(.{ .limits = .{ .memory_bytes = 64 * 1024 * 1024 } });
    defer iso.deinit();
    // Allocate a large buffer via iso.vm before the first run: no cell is
    // entered yet, so it is not attributed to iso.cell.
    _ = try iso.vm.loadString("$buf = 'x' * 5_000_000");
    // Growing it inside a run reallocs a block whose `old` exceeds the cell's
    // tracked bytes; the pre-fix `live_bytes - old` underflowed (Debug panic;
    // release wrapped huge and poisoned the isolate).
    _ = try iso.run("$buf << ('y' * 100); $buf.size");
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
