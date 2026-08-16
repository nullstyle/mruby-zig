//! Test root: `zig build test`.

const std = @import("std");
const mruby = @import("mruby");

test {
    _ = mruby;
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
    vm.setGlobal("name", vm.stringValue("zig"));
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

    mruby.output.setOutputWriter(vm, &buffer.writer);
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
