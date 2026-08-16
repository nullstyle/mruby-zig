//! Scratch: run snippets, print results/errors (development only).

const std = @import("std");
const mruby = @import("mruby");

const snippets = [_][]const u8{
    "ZigMath.new.greet('ada')",
    "$answer = 42",
    "Math",
    "Math.sqrt(144.0)",
    "Object.new.instance_variable_set(:@v, 7)",
    "\"garbage #{1}\"",
    "GC.start",
    "[1,2].map { |x| x.to_s }",
};

pub fn main() !void {
    const vm = try mruby.Vm.init();
    defer vm.deinit();

    const math = try vm.defineClass("ZigMath", null);
    math.defineMethod("whereami", "", struct {
        fn call(m: *mruby.Vm, self: mruby.Value) anyerror!mruby.Value {
            _ = self;
            std.debug.print("    [callback mrb ptr = 0x{x}]\n", .{@intFromPtr(m.mrb)});
            return m.nilValue();
        }
    }.call);
    math.defineMethod("greet", "S", struct {
        fn call(m: *mruby.Vm, self: mruby.Value, name: []const u8) anyerror!mruby.Value {
            _ = self;
            std.debug.print("    [greet got '{s}']\n", .{name});
            return m.stringValue(name);
        }
    }.call);

    std.debug.print("host vm.mrb ptr   = 0x{x}\n", .{@intFromPtr(vm.mrb)});
    {
        // Minimal repro on a fresh VM, nothing else done.
        const v2 = try mruby.Vm.init();
        defer v2.deinit();
        const sym = try v2.internSymbol("minimal_gv");
        mruby.c.mrb_gv_set(v2.mrb, sym, mruby.c.mrz_int_value(v2.mrb, 7));
        std.debug.print("MINIMAL: after C set: globals={*} symidx={}\n", .{ mruby.c.mrz_dbg_globals(v2.mrb), mruby.c.mrz_dbg_symidx(v2.mrb) });
        const r = v2.loadString("$minimal_gv") catch return;
        std.debug.print("MINIMAL: after eval:   globals={*} symidx={}\n", .{ mruby.c.mrz_dbg_globals(v2.mrb), mruby.c.mrz_dbg_symidx(v2.mrb) });
        const sym2 = try v2.internSymbol("minimal_gv");
        const sym_dollar = try v2.internSymbol("$minimal_gv");
        std.debug.print("MINIMAL: sym pre: {} now: {} with_dollar: {}\n", .{ sym, sym2, sym_dollar });
        mruby.c.mrb_gv_set(v2.mrb, sym_dollar, mruby.c.mrz_int_value(v2.mrb, 12345));
        const via_sym_read = v2.loadString("$minimal_gv") catch return;
        std.debug.print("MINIMAL: re-eval read (dollar sym written) = {} int {}\n", .{ via_sym_read.typeOf(), via_sym_read.asInt() catch -1 });
        std.debug.print("MINIMAL: eval read = {} (int {})\n", .{ r.typeOf(), r.asInt() catch -1 });
        const r2 = mruby.c.mrb_gv_get(v2.mrb, sym);
        std.debug.print("MINIMAL: c read int = {}\n", .{mruby.c.mrz_integer(r2)});
    }
    _ = vm.loadString("ZigMath.new.whereami") catch {};
    for (snippets) |src| {
        std.debug.print("EVAL {s}\n", .{src});
        const v = vm.loadString(src) catch {
            const exc = vm.lastError().?;
            const cls = exc.className();
            defer mruby.alloc.gpa.free(cls);
            const msg = exc.message();
            defer mruby.alloc.gpa.free(msg);
            std.debug.print("  !! {s}: {s}\n", .{ cls, msg });
            vm.clearError();
            continue;
        };
        std.debug.print("  -> {}\n", .{v.typeOf()});
    }

    {
        const sym = try vm.internSymbol("answer");
        std.debug.print("raw: sym={d} name='{s}'\n", .{ sym, vm.symbolName(sym) });
        const raw = mruby.c.mrb_gv_get(vm.mrb, sym);
        std.debug.print("raw: gv type={} int={}\n", .{ mruby.c.mrz_type(raw), mruby.c.mrz_integer(raw) });
        const sym2 = try vm.internSymbol("Math");
        std.debug.print("raw: sym(Math)={d} name='{s}'\n", .{ sym2, vm.symbolName(sym2) });
        const Protected = struct {
            fn body(mrb: ?*mruby.c.mrb_state, ud: ?*anyopaque) callconv(.c) mruby.c.mrb_value {
                _ = ud;
                const m = mrb.?;
                const cls = mruby.c.mrb_class_get(m, "Math");
                return mruby.c.mrz_obj_value(@ptrCast(cls));
            }
        };
        var perr = false;
        const pv = mruby.c.mrb_protect_error(vm.mrb, Protected.body, null, &perr);
        std.debug.print("raw: class_get err={} val_type={}\n", .{ perr, mruby.c.mrz_type(pv) });
        if (perr) {
            const exc2 = mruby.RubyError.fromValue(vm.mrb, pv);
            const m2 = exc2.message();
            defer mruby.alloc.gpa.free(m2);
            const c2 = exc2.className();
            defer mruby.alloc.gpa.free(c2);
            std.debug.print("raw: class_get exc = {s}: {s}\n", .{ c2, m2 });
            vm.clearError();
        }
        {
            // C-API global write/read roundtrip, bypassing eval entirely.
            const sym_w = try vm.internSymbol("zanswer");
            mruby.c.mrb_gv_set(vm.mrb, sym_w, mruby.c.mrz_int_value(vm.mrb, 99));
            const back = mruby.c.mrb_gv_get(vm.mrb, sym_w);
            std.debug.print("raw: gv roundtrip type={} int={}\n", .{ mruby.c.mrz_type(back), mruby.c.mrz_integer(back) });
            const via_eval = vm.loadString("$zanswer") catch {
                std.debug.print("eval $zanswer FAILED\n", .{});
                return;
            };
            std.debug.print("raw: eval $zanswer -> {}\n", .{via_eval.typeOf()});
            const post = try vm.internSymbol("zanswer");
            std.debug.print("raw: zanswer sym pre={} post={}\n", .{ sym_w, post });
            const via_eval2 = vm.loadString("$zanswer") catch return;
            std.debug.print("raw: eval $zanswer again -> {}\n", .{via_eval2.typeOf()});
            // fresh name: intern via C, then let the parser intern the same
            // name in an eval; compare ids.
            const fa = try vm.internSymbol("fresh_name_probe");
            const fsym = vm.loadString(":fresh_name_probe") catch return;
            const fb = mruby.c.mrz_symbol(fsym.v);
            std.debug.print("raw: fresh probe: C={} parser={} same={}\n", .{ fa, fb, fa == fb });
        }
        const a1 = try vm.internSymbol("answer");
        const a2 = try vm.internSymbol("answer");
        std.debug.print("raw: intern answer twice: {d} {d}\n", .{ a1, a2 });
        const symv = vm.loadString(":answer") catch {
            std.debug.print("eval :answer FAILED\n", .{});
            return;
        };
        std.debug.print("raw: parser :answer id = {}\n", .{mruby.c.mrz_symbol(symv.v)});
        const ans = vm.loadString("$answer") catch {
            std.debug.print("eval $answer FAILED\n", .{});
            return;
        };
        std.debug.print("eval $answer -> type {}\n", .{ans.typeOf()});
    }
    const g = try vm.getGlobal("answer");
    std.debug.print("global answer type {} int? {}\n", .{ g.typeOf(), g.asInt() catch -999 });

    _ = vm.getClass("Math") catch |e| {
        std.debug.print("getClass(Math) failed: {}\n", .{e});
        return;
    };
    std.debug.print("getClass(Math) ok\n", .{});

    {
        // Counter wrap repro
        const Counter = mruby.data.DataType(i32, "Counter", null);
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
        const v = vm.loadString("Counter.new_count(5).bump") catch {
            const exc3 = vm.lastError().?;
            const m3 = exc3.message();
            defer mruby.alloc.gpa.free(m3);
            const c3 = exc3.className();
            defer mruby.alloc.gpa.free(c3);
            std.debug.print("WRAP FAIL {s}: {s}\n", .{ c3, m3 });
            vm.clearError();
            return;
        };
        std.debug.print("WRAP result = {} int {}\n", .{ v.typeOf(), v.asInt() catch -1 });
    }

    var buffer: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer buffer.deinit();
    mruby.output.setOutputWriter(vm, &buffer.writer);
    _ = vm.loadString("print 'a'; puts 'b'; p 42") catch {
        const exc = vm.lastError().?;
        const cls = exc.className();
        defer mruby.alloc.gpa.free(cls);
        const msg = exc.message();
        defer mruby.alloc.gpa.free(msg);
        std.debug.print("print failed !! {s}: {s}\n", .{ cls, msg });
        return;
    };
    std.debug.print("captured: '{s}'\n", .{buffer.writer.buffer[0..buffer.writer.end]});
}
