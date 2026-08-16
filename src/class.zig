//! Classes, modules, and method definition.
//!
//! `defineMethod` registers a Zig function as a Ruby method. The Ruby-facing
//! argument format string follows `mrb_get_args` conventions, and the Zig
//! callback receives fully typed arguments:
//!
//!     const math = try vm.defineClass("ZigMath", null);
//!     math.defineMethod("add", "ii", struct {
//!         fn call(vm: *mruby.Vm, self: mruby.Value, a: i64, b: i64) anyerror!mruby.Value {
//!             _ = self;
//!             return vm.intValue(a + b);
//!         }
//!     }.call);
//!
//! Format specifiers: `i` -> i64, `f` -> f64, `b` -> bool, `n` -> u32
//! (symbol id), `o` -> Value, `z` -> [:0]const u8, `S` -> []const u8,
//! `&` -> Value (block; nil if none), `*` -> Rest (view of remaining args),
//! `|` -> separator after which specs are optional.
//!
//! Error handling: any Zig error surfaced from the callback becomes a Ruby
//! RuntimeError carrying the error name; a callback that raised its own Ruby
//! exception (see `vm.raise`) keeps that exception. mruby's setjmp/longjmp
//! never crosses a live Zig frame: callbacks run inside `mrb_protect_error`
//! and pending exceptions are re-raised from a clean frame.

const std = @import("std");
const c = @import("c.zig");
const value_mod = @import("value.zig");
const vm_mod = @import("vm.zig");

pub const Value = value_mod.Value;
pub const Vm = vm_mod.Vm;

/// Rest arguments (`*`): a view into the VM argument stack, valid only for
/// the duration of the method call.
pub const Rest = struct {
    base: [*]const c.mrb_value,
    mrb: *c.mrb_state,
    len: usize,

    pub fn get(self: Rest, i: usize) Value {
        std.debug.assert(i < self.len);
        return .{ .mrb = self.mrb, .v = self.base[i] };
    }
};

pub const Class = struct {
    mrb: *c.mrb_state,
    class: *c.RClass,

    pub fn defineMethod(self: Class, name: [:0]const u8, comptime fmt: []const u8, comptime func: anytype) void {
        const wrap = Wrap(fmt, func);
        _ = c.mrb_define_method(self.mrb, self.class, name.ptr, wrap.cCall, aspec(fmt));
    }

    pub fn defineClassMethod(self: Class, name: [:0]const u8, comptime fmt: []const u8, comptime func: anytype) void {
        const wrap = Wrap(fmt, func);
        _ = c.mrb_define_class_method(self.mrb, self.class, name.ptr, wrap.cCall, aspec(fmt));
    }

    pub fn defineModuleFunction(self: Class, name: [:0]const u8, comptime fmt: []const u8, comptime func: anytype) void {
        const wrap = Wrap(fmt, func);
        _ = c.mrb_define_module_function(self.mrb, self.class, name.ptr, wrap.cCall, aspec(fmt));
    }

    pub fn defineConst(self: Class, name: [:0]const u8, val: Value) void {
        c.mrb_define_const(self.mrb, self.class, name.ptr, val.v);
    }
};

fn aspec(comptime fmt: []const u8) c.mrb_aspec {
    var req: u32 = 0;
    var opt: u32 = 0;
    var rest = false;
    var block = false;
    var optional = false;
    inline for (fmt) |ch| switch (ch) {
        '|' => optional = true,
        '*' => rest = true,
        '&' => block = true,
        else => {
            if (optional) opt += 1 else req += 1;
        },
    };
    var a: c.mrb_aspec = c.MRB_ARGS_NONE;
    if (req > 0) a |= req << 18; // MRB_ARGS_REQ
    if (opt > 0) a |= opt << 13; // MRB_ARGS_OPT
    if (rest) a |= c.MRB_ARGS_REST;
    if (block) a |= c.MRB_ARGS_BLOCK;
    return a;
}

const Spec = enum { int_, float, boolean, nsymbol, object, zstring, stringval, rstring, block, rest };

fn parseSpecs(comptime fmt: []const u8) []const Spec {
    comptime var specs: []const Spec = &.{};
    inline for (fmt) |ch| switch (ch) {
        'i' => specs = specs ++ .{.int_},
        'f' => specs = specs ++ .{.float},
        'b' => specs = specs ++ .{.boolean},
        'n' => specs = specs ++ .{.nsymbol},
        'o' => specs = specs ++ .{.object},
        'z' => specs = specs ++ .{.zstring},
        'S' => specs = specs ++ .{.stringval},
        's' => specs = specs ++ .{.rstring},
        '&' => specs = specs ++ .{.block},
        '*' => specs = specs ++ .{.rest},
        '|' => {},
        else => @compileError("unsupported mrb_get_args format char '" ++ [1]u8{ch} ++ "'"),
    };
    return specs;
}

fn ParamType(comptime s: Spec) type {
    return switch (s) {
        .int_ => i64,
        .float => f64,
        .boolean => bool,
        .nsymbol => u32,
        .object, .block => Value,
        .zstring => [:0]const u8,
        .stringval => []const u8,
        .rstring => []const u8,
        .rest => Rest,
    };
}

/// Storage for one call's parsed arguments, plus the machinery that feeds
/// the interleaved pointer array `mrb_get_args_a` consumes.
fn ArgSlots(comptime specs: []const Spec) type {
    return struct {
        const Self = @This();

        ints: [countOf(.int_)]c.mrb_int,
        floats: [countOf(.float)]c.mrb_float,
        bools: [countOf(.boolean)]c.mrb_bool,
        syms: [countOf(.nsymbol)]c.mrb_sym,
        objs: [countOf(.object)]c.mrb_value,
        strs: [countOf(.stringval)]c.mrb_value,
        zstrs: [countOf(.zstring)]?[*:0]const u8,
        rstrs: [countOf(.rstring)]?[*]const u8,
        rstr_lens: [countOf(.rstring)]c.mrb_int,
        blocks: [countOf(.block)]c.mrb_value,
        rests: [countOf(.rest)]?[*]const c.mrb_value,
        rest_lens: [countOf(.rest)]c.mrb_int,

        pub fn init() Self {
            return .{
                .ints = @splat(0),
                .floats = @splat(0),
                .bools = @splat(false),
                .syms = @splat(0),
                .objs = @splat(c.mrz_nil_value()),
                .strs = @splat(c.mrz_nil_value()),
                .zstrs = @splat(null),
                .rstrs = @splat(null),
                .rstr_lens = @splat(0),
                .blocks = @splat(c.mrz_nil_value()),
                .rests = @splat(null),
                .rest_lens = @splat(0),
            };
        }

        pub const total_slots = blk: {
            var n: usize = 0;
            for (specs) |s| {
                n += switch (s) {
                    .rstring, .rest => 2,
                    else => 1,
                };
            }
            break :blk n;
        };

        fn countOf(comptime target: Spec) usize {
            var n: usize = 0;
            for (specs) |s| {
                if (s == target) n += 1;
            }
            return n;
        }

        fn ordinal(comptime target: Spec, comptime spec_index: usize) usize {
            var n: usize = 0;
            for (specs, 0..) |s, j| {
                if (j == spec_index) return n;
                if (s == target) n += 1;
            }
            unreachable;
        }

        fn fillPtrs(self: *Self, ptrs: *[total_slots]?*anyopaque) void {
            var pi: usize = 0;
            inline for (specs, 0..) |s, i| switch (s) {
                .int_ => {
                    ptrs[pi] = @ptrCast(&self.ints[ordinal(.int_, i)]);
                    pi += 1;
                },
                .float => {
                    ptrs[pi] = @ptrCast(&self.floats[ordinal(.float, i)]);
                    pi += 1;
                },
                .boolean => {
                    ptrs[pi] = @ptrCast(&self.bools[ordinal(.boolean, i)]);
                    pi += 1;
                },
                .nsymbol => {
                    ptrs[pi] = @ptrCast(&self.syms[ordinal(.nsymbol, i)]);
                    pi += 1;
                },
                .object => {
                    ptrs[pi] = @ptrCast(&self.objs[ordinal(.object, i)]);
                    pi += 1;
                },
                .stringval => {
                    ptrs[pi] = @ptrCast(&self.strs[ordinal(.stringval, i)]);
                    pi += 1;
                },
                .zstring => {
                    ptrs[pi] = @ptrCast(&self.zstrs[ordinal(.zstring, i)]);
                    pi += 1;
                },
                .rstring => {
                    const o = ordinal(.rstring, i);
                    ptrs[pi] = @ptrCast(&self.rstrs[o]);
                    ptrs[pi + 1] = @ptrCast(&self.rstr_lens[o]);
                    pi += 2;
                },
                .block => {
                    ptrs[pi] = @ptrCast(&self.blocks[ordinal(.block, i)]);
                    pi += 1;
                },
                .rest => {
                    const o = ordinal(.rest, i);
                    ptrs[pi] = @ptrCast(&self.rests[o]);
                    ptrs[pi + 1] = @ptrCast(&self.rest_lens[o]);
                    pi += 2;
                },
            };
        }
    };
}

const CallCtx = struct {
    mrb: *c.mrb_state,
    self_v: c.mrb_value,
};

fn Wrap(comptime fmt: []const u8, comptime func: anytype) type {
    return struct {
        fn cCall(mrb: ?*c.mrb_state, self_v: c.mrb_value) callconv(.c) c.mrb_value {
            const m = mrb orelse return c.mrz_nil_value();
            var ctx = CallCtx{ .mrb = m, .self_v = self_v };

            var errored = false;
            const r = c.mrb_protect_error(m, protectedBody, &ctx, &errored);
            if (errored) {
                // On error, protect's result IS the exception object and
                // mrb->exc has been cleared; raise it from this clean frame.
                c.mrb_exc_raise(m, r);
            }
            const exc = c.mrz_exc_value(m);
            if (!c.mrz_nil_p(exc)) {
                c.mrb_exc_raise(m, exc);
            }
            return r;
        }

        fn protectedBody(mrb: ?*c.mrb_state, ud: ?*anyopaque) callconv(.c) c.mrb_value {
            const m = mrb orelse return c.mrz_nil_value();
            const ctx: *CallCtx = @ptrCast(@alignCast(ud orelse return c.mrz_nil_value()));
            return invoke(m, ctx.self_v) catch |err| {
                if (err == error.RubyException and !c.mrz_nil_p(c.mrz_exc_value(m))) {
                    return c.mrz_nil_value(); // callback raised its own exception
                }
                setZigError(m, err);
                return c.mrz_nil_value();
            };
        }

        fn setZigError(m: *c.mrb_state, err: anyerror) void {
            var buf: [160]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "zig error: {s}", .{@errorName(err)}) catch "zig error";
            // We are inside protectedBody's protect, so even a failure while
            // building the exception is contained.
            const cls = c.mrb_class_get(m, "RuntimeError");
            const msg_v = c.mrb_str_new(m, if (msg.len == 0) null else msg.ptr, @intCast(msg.len));
            const exc = c.mrb_funcall(m, c.mrz_obj_value(@ptrCast(cls)), "exception", 1, msg_v);
            c.mrz_exc_set(m, exc);
        }

        fn invoke(m: *c.mrb_state, self_v: c.mrb_value) !c.mrb_value {
            const vm = Vm.fromMrb(m);
            const self_val = Value{ .mrb = m, .v = self_v };
            const specs = comptime parseSpecs(fmt);
            const fmtz = comptime fmt ++ "\x00";

            var slots: ArgSlots(specs) = ArgSlots(specs).init();
            var ptrs: [ArgSlots(specs).total_slots]?*anyopaque = @splat(null);
            slots.fillPtrs(&ptrs);
            _ = c.mrb_get_args_a(m, @ptrCast(fmtz.ptr), ptrs[0..].ptr);

            const result: Value = try callN(specs, 0, vm, self_val, &slots, .{ vm, self_val });
            return result.v;
        }

        /// Recursively build the typed argument tuple (concatenation with
        /// runtime values) and dispatch to the user callback when complete.
        fn callN(
            comptime specs: []const Spec,
            comptime i: usize,
            vm: *Vm,
            self_val: Value,
            slots: *ArgSlots(specs),
            built: anytype,
        ) anyerror!Value {
            if (i == specs.len) return @call(.auto, func, built);
            const S = ArgSlots(specs);
            const v = switch (specs[i]) {
                .int_ => @as(i64, slots.ints[S.ordinal(.int_, i)]),
                .float => @as(f64, slots.floats[S.ordinal(.float, i)]),
                .boolean => slots.bools[S.ordinal(.boolean, i)] != 0,
                .nsymbol => @as(u32, slots.syms[S.ordinal(.nsymbol, i)]),
                .object => @as(Value, .{ .mrb = vm.mrb, .v = slots.objs[S.ordinal(.object, i)] }),
                .stringval => blk: {
                    const sv = slots.strs[S.ordinal(.stringval, i)];
                    const p = c.mrz_string_ptr(sv) orelse break :blk @as([]const u8, "");
                    break :blk p[0..@intCast(c.mrz_string_len(sv))];
                },
                .zstring => blk: {
                    const p = slots.zstrs[S.ordinal(.zstring, i)] orelse break :blk @as([:0]const u8, "");
                    break :blk std.mem.span(p);
                },
                .rstring => blk: {
                    const o = S.ordinal(.rstring, i);
                    const p = slots.rstrs[o] orelse break :blk @as([]const u8, "");
                    break :blk p[0..@intCast(slots.rstr_lens[o])];
                },
                .block => @as(Value, .{ .mrb = vm.mrb, .v = slots.blocks[S.ordinal(.block, i)] }),
                .rest => blk: {
                    const o = S.ordinal(.rest, i);
                    const p = slots.rests[o] orelse break :blk Rest{ .base = undefined, .mrb = vm.mrb, .len = 0 };
                    break :blk Rest{ .base = p, .mrb = vm.mrb, .len = @intCast(slots.rest_lens[o]) };
                },
            };
            return callN(specs, i + 1, vm, self_val, slots, built ++ .{v});
        }
    };
}
