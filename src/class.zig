//! Classes, modules, and method definition.
//!
//! `defineMethod` derives the Ruby-facing argument protocol from the Zig
//! callback's parameter types, so the marshalling and the mruby arity can
//! never disagree:
//!
//!     const math = try vm.defineClass("ZigMath", null);
//!     try math.defineMethod("add", struct {
//!         fn call(vm: *mruby.Vm, self: mruby.Value, a: i64, b: i64) anyerror!mruby.Value {
//!             _ = self;
//!             return vm.intValue(a + b);
//!         }
//!     }.call);
//!
//! The callback starts with `vm: *Vm, self: mruby.Value`; every further
//! parameter maps to one Ruby argument:
//!
//!   i64 -> Integer, f64 -> Float, bool -> Boolean, u32 -> Symbol id,
//!   Value -> any Object, []const u8 -> String bytes (borrowed),
//!   [:0]const u8 -> NUL-terminated String (borrowed),
//!   Rest -> splat arguments (`*`), Block -> the block (`&`).
//!
//! Optional arguments are declared as Zig optionals (`?i64`, `?[]const u8`,
//! ...): they map to the mrb_get_args `|` section and are `null` when the
//! caller omitted them — absence is distinguishable from a passed default.
//! Optional parameters must follow the required ones; `Rest` and `Block`
//! come last.
//!
//! Keyword arguments are declared as a `KwArgs(T)` parameter, where `T` is
//! a plain struct: each field is a keyword named after it, non-optional
//! fields are required keywords, and `?T` fields are optional (`null` when
//! the keyword was omitted). Required fields must precede optional ones, so
//! the field order is the mrb_get_args keyword-table order. Keyword values
//! use the safe-layer conversion semantics (checked integers, strict
//! booleans, borrowed strings). A missing required keyword or an unknown
//! keyword raises Ruby `ArgumentError`; `**rest` capture is not modeled yet.
//! `KwArgs` follows the positional parameters and may be followed by
//! `Block` (not `Rest`).
//!
//! String parameters are **borrowed**: the backing memory lives on the Ruby
//! heap and is valid only until the callback's next call into the
//! interpreter; copy anything you keep.
//!
//! `defineMethodRaw` (and the `*Raw` class/module variants) take an
//! explicit `mrb_get_args` format string for protocols the derived form
//! does not model, such as the `S` (String value) spec. Optional specs in
//! a raw format default to zero values when absent.
//!
//! Error handling: any Zig error surfaced from the callback becomes a Ruby
//! RuntimeError carrying the error name; a callback that raised its own Ruby
//! exception (see `vm.raise`) keeps that exception. Potentially raising mruby
//! calls run in C protection trampolines; the VM observes a pending exception
//! only after the Zig callback has returned.

const std = @import("std");
const c = @import("c.zig");
const convert = @import("convert.zig");
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

/// Block parameter (`&`): the caller's block as a `Value`, or `nil` when
/// none was supplied (`isPresent` distinguishes the two).
pub const Block = struct {
    value: Value,

    pub fn isPresent(self: Block) bool {
        return !self.value.isNil();
    }
};

/// Keyword arguments (`:`): the caller's keywords unmarshalled into the
/// fields of `T` (see the module docs for the field rules).
pub fn KwArgs(comptime T: type) type {
    return struct {
        pub const mrz_kwargs_marker = true;

        values: T,
    };
}

fn isKwArgs(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "mrz_kwargs_marker")) return false;
    return T.mrz_kwargs_marker;
}

/// The keyword struct carried by a `KwArgs(T)` parameter.
fn kwArgsStruct(comptime T: type) type {
    return @FieldType(T, "values");
}

/// Comptime validation of a keyword struct: every field maps to a supported
/// spec, and required fields precede optional ones (mruby's keyword table
/// requires the required keywords first).
fn validateKwStruct(comptime T: type) void {
    const info = @typeInfo(T);
    if (info != .@"struct") {
        @compileError("KwArgs parameter must be KwArgs(<plain struct>), got " ++ @typeName(T));
    }
    comptime var seen_optional = false;
    inline for (info.@"struct".field_names, info.@"struct".field_types) |name, ft| {
        switch (@typeInfo(ft)) {
            .optional => |opt| {
                seen_optional = true;
                _ = specChar(opt.child);
            },
            else => {
                if (seen_optional) {
                    @compileError("KwArgs field '" ++ name ++ "': required keyword fields must precede optional (?T) fields");
                }
                _ = specChar(ft);
            },
        }
    }
}

fn kwFieldCount(comptime T: type) usize {
    return @typeInfo(T).@"struct".field_names.len;
}

fn kwRequiredCount(comptime T: type) usize {
    comptime var n: usize = 0;
    inline for (@typeInfo(T).@"struct".field_types) |ft| {
        if (@typeInfo(ft) != .optional) n += 1;
    }
    return n;
}

pub const Class = struct {
    mrb: *c.mrb_state,
    class: *c.RClass,

    /// View this class/module object as a `Value` owned by the same VM.
    pub fn asValue(self: Class) Value {
        return .{ .mrb = self.mrb, .v = c.mrz_obj_value(@ptrCast(self.class)) };
    }

    /// View a class/module object `Value` as a `Class`. In a
    /// `defineClassMethod` callback, `self` is the class, so this is the
    /// supported way to reach the defining class without process-global
    /// storage.
    pub fn fromValue(value: Value) !Class {
        return classFromRaw(value.mrb, value.v);
    }

    pub fn ensureOwnedBy(self: Class, mrb: *c.mrb_state) error{ForeignValue}!void {
        if (self.mrb != mrb) return error.ForeignValue;
    }

    /// Define an instance method whose Ruby arity and marshalling are
    /// derived from the callback's parameter types (see the module docs).
    pub fn defineMethod(self: Class, name: []const u8, comptime func: anytype) !void {
        const sig = comptime deriveSignature(func);
        const wrap = WrapDerived(func);
        if (!c.mrz_protected_define_method(
            self.mrb,
            self.class,
            name.ptr,
            name.len,
            wrap.cCall,
            aspec(sig.fmt, sig.kw),
            c.MRZ_METHOD_INSTANCE,
        )) return error.RubyException;
    }

    /// Define an instance method with an explicit `mrb_get_args` format
    /// string. The escape hatch for protocols the derived form does not
    /// model (e.g. the `S` String-value spec); optional specs default to
    /// zero values when absent.
    pub fn defineMethodRaw(self: Class, name: []const u8, comptime fmt: []const u8, comptime func: anytype) !void {
        const wrap = Wrap(fmt, func);
        if (!c.mrz_protected_define_method(
            self.mrb,
            self.class,
            name.ptr,
            name.len,
            wrap.cCall,
            aspec(fmt, null),
            c.MRZ_METHOD_INSTANCE,
        )) return error.RubyException;
    }

    /// Define a class (singleton) method with a derived signature.
    pub fn defineClassMethod(self: Class, name: []const u8, comptime func: anytype) !void {
        const sig = comptime deriveSignature(func);
        const wrap = WrapDerived(func);
        if (!c.mrz_protected_define_method(
            self.mrb,
            self.class,
            name.ptr,
            name.len,
            wrap.cCall,
            aspec(sig.fmt, sig.kw),
            c.MRZ_METHOD_CLASS,
        )) return error.RubyException;
    }

    /// Define a class (singleton) method with an explicit format string.
    pub fn defineClassMethodRaw(self: Class, name: []const u8, comptime fmt: []const u8, comptime func: anytype) !void {
        const wrap = Wrap(fmt, func);
        if (!c.mrz_protected_define_method(
            self.mrb,
            self.class,
            name.ptr,
            name.len,
            wrap.cCall,
            aspec(fmt, null),
            c.MRZ_METHOD_CLASS,
        )) return error.RubyException;
    }

    /// Define a module function with a derived signature.
    pub fn defineModuleFunction(self: Class, name: []const u8, comptime func: anytype) !void {
        const sig = comptime deriveSignature(func);
        const wrap = WrapDerived(func);
        if (!c.mrz_protected_define_method(
            self.mrb,
            self.class,
            name.ptr,
            name.len,
            wrap.cCall,
            aspec(sig.fmt, sig.kw),
            c.MRZ_METHOD_MODULE_FUNCTION,
        )) return error.RubyException;
    }

    /// Define a module function with an explicit format string.
    pub fn defineModuleFunctionRaw(self: Class, name: []const u8, comptime fmt: []const u8, comptime func: anytype) !void {
        const wrap = Wrap(fmt, func);
        if (!c.mrz_protected_define_method(
            self.mrb,
            self.class,
            name.ptr,
            name.len,
            wrap.cCall,
            aspec(fmt, null),
            c.MRZ_METHOD_MODULE_FUNCTION,
        )) return error.RubyException;
    }

    pub fn defineConst(self: Class, name: []const u8, val: Value) !void {
        try val.ensureOwnedBy(self.mrb);
        if (!c.mrz_protected_define_const(
            self.mrb,
            self.class,
            name.ptr,
            name.len,
            val.v,
        )) return error.RubyException;
    }

    /// Define a class directly beneath this class/module.
    pub fn defineClass(self: Class, name: []const u8, super: ?Class) !Class {
        if (super) |parent| try parent.ensureOwnedBy(self.mrb);
        var result: c.mrb_value = undefined;
        if (!c.mrz_protected_define_under(
            self.mrb,
            self.class,
            name.ptr,
            name.len,
            if (super) |parent| parent.class else null,
            c.MRZ_DEFINE_CLASS,
            &result,
        )) return error.RubyException;
        return classFromRaw(self.mrb, result);
    }

    /// Define a module directly beneath this class/module.
    pub fn defineModule(self: Class, name: []const u8) !Class {
        var result: c.mrb_value = undefined;
        if (!c.mrz_protected_define_under(
            self.mrb,
            self.class,
            name.ptr,
            name.len,
            null,
            c.MRZ_DEFINE_MODULE,
            &result,
        )) return error.RubyException;
        return classFromRaw(self.mrb, result);
    }

    /// Fetch a constant defined directly beneath this class/module.
    pub fn getConst(self: Class, name: []const u8) !Value {
        var found = false;
        var result: c.mrb_value = undefined;
        if (!c.mrz_protected_const_get(
            self.mrb,
            self.class,
            name.ptr,
            name.len,
            &found,
            &result,
        )) return error.RubyException;
        if (!found) return error.UnknownConstant;
        return .{ .mrb = self.mrb, .v = result };
    }

    /// Fetch a class/module defined directly beneath this class/module.
    pub fn getClass(self: Class, name: []const u8) !Class {
        const value = self.getConst(name) catch |err| switch (err) {
            error.UnknownConstant => return error.UnknownClass,
            else => return err,
        };
        return classFromRaw(self.mrb, value.v);
    }
};

fn classFromRaw(mrb: *c.mrb_state, value: c.mrb_value) !Class {
    if (!c.mrz_class_p(value) and !c.mrz_module_p(value))
        return error.UnknownClass;
    const ptr = c.mrz_ptr(value) orelse return error.UnknownClass;
    return .{ .mrb = mrb, .class = @ptrCast(@alignCast(ptr)) };
}

fn aspec(comptime fmt: []const u8, comptime kw: ?type) c.mrb_aspec {
    var req: u32 = 0;
    var opt: u32 = 0;
    var rest = false;
    var block = false;
    var optional = false;
    inline for (fmt) |ch| switch (ch) {
        '|' => optional = true,
        '*' => rest = true,
        '&' => block = true,
        // The keyword spec contributes MRB_ARGS_KEY below, not a
        // positional slot: cfunc argument-count checks run against this
        // aspec (check_argument_count), where a bogus required slot both
        // rejects keyword-only calls with no keywords and mis-accepts
        // keyword calls as satisfying a positional requirement.
        ':' => {},
        else => {
            if (optional) opt += 1 else req += 1;
        },
    };
    var a: c.mrb_aspec = c.MRB_ARGS_NONE;
    if (req > 0) a |= req << 18; // MRB_ARGS_REQ
    if (opt > 0) a |= opt << 13; // MRB_ARGS_OPT
    if (rest) a |= c.MRB_ARGS_REST;
    if (block) a |= c.MRB_ARGS_BLOCK;
    if (kw) |T| {
        // MRB_ARGS_KEY(required, dict): the KDICT bit marks the method as
        // keyword-accepting even when every keyword is optional, so the
        // caller's keyword hash is never counted as a positional argument.
        // Unknown-keyword strictness lives in mrb_get_args (rest == null).
        const required = comptime kwRequiredCount(T);
        a |= (required & 0x1f) << 2; // MRB_ARGS_KEY count
        a |= 1 << 1; // MRB_ARGS_KDICT
    }
    return a;
}

const Spec = enum { int_, float, boolean, nsymbol, object, zstring, stringval, rstring, block, rest, kwargs };

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
        ':' => specs = specs ++ .{.kwargs},
        '|' => {},
        else => @compileError("unsupported mrb_get_args format char '" ++ [1]u8{ch} ++ "'"),
    };
    return specs;
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

        fn fillPtrs(self: *Self, ptrs: *[total_slots]?*anyopaque, kw: ?*anyopaque) void {
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
                .kwargs => {
                    ptrs[pi] = kw;
                    pi += 1;
                },
            };
        }
    };
}

/// The Zig-side value a spec unmarshals to.
fn SpecValue(comptime spec: Spec) type {
    return switch (spec) {
        .int_ => i64,
        .float => f64,
        .boolean => bool,
        .nsymbol => u32,
        .object => Value,
        .stringval => []const u8,
        .zstring => [:0]const u8,
        .rstring => []const u8,
        .block => Value,
        .rest => Rest,
        .kwargs => @compileError("kwargs values are built by kwParam, not extractSpec"),
    };
}

/// Read the `i`-th parsed argument out of the slots as its Zig-side type.
/// Optional specs left absent hold their zero-value initializers here;
/// presence is decided separately by the derived builder.
fn extractSpec(
    comptime specs: []const Spec,
    comptime i: usize,
    vm: *Vm,
    slots: *ArgSlots(specs),
) SpecValue(specs[i]) {
    const S = ArgSlots(specs);
    return switch (specs[i]) {
        .int_ => @as(i64, slots.ints[S.ordinal(.int_, i)]),
        .float => @as(f64, slots.floats[S.ordinal(.float, i)]),
        .boolean => slots.bools[S.ordinal(.boolean, i)],
        .nsymbol => @as(u32, slots.syms[S.ordinal(.nsymbol, i)]),
        .object => @as(Value, .{ .mrb = vm.mrb, .v = slots.objs[S.ordinal(.object, i)] }),
        .stringval => blk: {
            const sv = slots.strs[S.ordinal(.stringval, i)];
            // An omitted optional 'S' leaves the slot at nil (its
            // init value); mrz_string_ptr applies RSTRING_PTR to the
            // value and would deref a non-string, so gate on the type
            // first and yield the empty-string default.
            if (!c.mrz_string_p(sv)) break :blk @as([]const u8, "");
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
        // The derived builder constructs KwArgs parameters from the keyword
        // value array before extractSpec runs; this arm exists only for
        // switch exhaustiveness.
        .kwargs => unreachable,
    };
}

/// Shared C-callable shell: error mapping and Zig-error promotion are
/// identical for raw and derived signatures.
fn CallbackShell(comptime invoke: anytype) type {
    return struct {
        pub fn cCall(mrb: ?*c.mrb_state, self_v: c.mrb_value) callconv(.c) c.mrb_value {
            const m = mrb orelse return c.mrz_nil_value();
            return invoke(m, self_v) catch |err| {
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
            _ = c.mrz_protected_set_exception(
                m,
                "RuntimeError",
                "RuntimeError".len,
                if (msg.len == 0) null else msg.ptr,
                msg.len,
            );
        }
    };
}

/// Derived signature: the mrb_get_args format and required/optional counts
/// implied by the callback's parameter types.
const DerivedSignature = struct {
    fmt: []const u8,
    /// Number of specs before the `|` separator.
    required: usize,
    /// Total number of optional specs (after the `|`).
    optional: usize,
    /// The keyword struct of a `KwArgs(T)` parameter, if any.
    kw: ?type,
};

fn specChar(comptime T: type) []const u8 {
    return switch (T) {
        i64 => "i",
        f64 => "f",
        bool => "b",
        u32 => "n",
        Value => "o",
        []const u8 => "s",
        [:0]const u8 => "z",
        else => @compileError("unsupported callback parameter type: " ++ @typeName(T)),
    };
}

fn deriveSignature(comptime func: anytype) DerivedSignature {
    const F = @typeInfo(@TypeOf(func)).@"fn";
    if (F.param_types.len < 2) {
        @compileError("callback must start with (vm: *Vm, self: Value, ...)");
    }
    for (F.param_types) |p| {
        if (p == null) @compileError("callback parameters must be concrete types");
    }
    if (F.param_types[0].? != *Vm) {
        @compileError("callback's first parameter must be *Vm");
    }
    if (F.param_types[1].? != Value) {
        @compileError("callback's second parameter must be Value (self)");
    }
    const rt = @typeInfo(F.return_type.?);
    if (rt != .error_union or rt.error_union.payload != Value) {
        @compileError("callback must return anyerror!Value");
    }

    comptime var fmt: []const u8 = "";
    comptime var required: usize = 0;
    comptime var optional: usize = 0;
    comptime var seen_optional = false;
    comptime var seen_rest = false;
    comptime var seen_block = false;
    comptime var seen_kw = false;
    comptime var kw: ?type = null;
    inline for (F.param_types[2..]) |p| {
        const T = p.?;
        if (T == Rest) {
            if (seen_rest) @compileError("at most one Rest parameter is allowed");
            if (seen_block) @compileError("Rest must precede Block");
            if (seen_kw) @compileError("Rest cannot yet be combined with KwArgs");
            fmt = fmt ++ "*";
            seen_rest = true;
            continue;
        }
        if (T == Block) {
            if (seen_block) @compileError("at most one Block parameter is allowed");
            fmt = fmt ++ "&";
            seen_block = true;
            continue;
        }
        if (comptime isKwArgs(T)) {
            if (seen_kw) @compileError("at most one KwArgs parameter is allowed");
            if (seen_rest or seen_block) @compileError("KwArgs must precede Rest and Block");
            kw = kwArgsStruct(T);
            validateKwStruct(kw.?);
            fmt = fmt ++ ":";
            seen_kw = true;
            continue;
        }
        switch (@typeInfo(T)) {
            .optional => |opt| {
                if (seen_rest or seen_block) {
                    @compileError("optional parameters must precede Rest and Block");
                }
                if (seen_kw) @compileError("positional parameters must precede KwArgs");
                if (!seen_optional) {
                    fmt = fmt ++ "|";
                    seen_optional = true;
                }
                fmt = fmt ++ specChar(opt.child);
                optional += 1;
            },
            else => {
                if (seen_optional) @compileError("required parameters must precede optional parameters");
                if (seen_rest or seen_block) @compileError("required parameters must precede Rest and Block");
                if (seen_kw) @compileError("positional parameters must precede KwArgs");
                fmt = fmt ++ specChar(T);
                required += 1;
            },
        }
    }
    return .{ .fmt = fmt, .required = required, .optional = optional, .kw = kw };
}

fn Wrap(comptime fmt: []const u8, comptime func: anytype) type {
    comptime if (std.mem.indexOfScalar(u8, fmt, ':') != null) {
        @compileError("raw format strings do not model the ':' keyword spec; use a KwArgs(T) parameter with the derived form");
    };
    return CallbackShell(struct {
        fn invoke(m: *c.mrb_state, self_v: c.mrb_value) !c.mrb_value {
            const vm = Vm.fromMrb(m);
            const self_val = Value{ .mrb = m, .v = self_v };
            const specs = comptime parseSpecs(fmt);
            const fmtz = comptime fmt ++ "\x00";

            var slots: ArgSlots(specs) = ArgSlots(specs).init();
            var ptrs: [ArgSlots(specs).total_slots]?*anyopaque = @splat(null);
            slots.fillPtrs(&ptrs, null);
            var parsed: c.mrb_int = 0;
            if (!c.mrz_protected_get_args(
                m,
                @ptrCast(fmtz.ptr),
                ptrs[0..].ptr,
                &parsed,
            )) return error.RubyException;

            const result: Value = try callN(specs, 0, vm, self_val, &slots, .{ vm, self_val });
            try result.ensureOwnedBy(m);
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
            return callN(
                specs,
                i + 1,
                vm,
                self_val,
                slots,
                built ++ .{extractSpec(specs, i, vm, slots)},
            );
        }
    }.invoke);
}

/// Marshalling for derived signatures: each parameter receives its declared
/// type, with `?T` optionals receiving `null` when the caller omitted them
/// (presence follows from the parsed argument count: optional k is present
/// iff `argc > required + k`, with Rest absorbing any excess). A `KwArgs(T)`
/// parameter receives `T` built from the keyword values.
fn WrapDerived(comptime func: anytype) type {
    const sig = deriveSignature(func);
    const specs = comptime parseSpecs(sig.fmt);
    const fmtz = comptime sig.fmt ++ "\x00";

    // Keyword plumbing for a `KwArgs(T)` parameter: field names as C
    // strings (field order is the keyword-table order; required first is
    // enforced at derivation), the interned symbol table, and the mrb_kwargs
    // descriptor pointing at both.
    const kw_names: ?[if (sig.kw) |T| kwFieldCount(T) else 0][*:0]const u8 = blk: {
        const T = sig.kw orelse break :blk null;
        var names: [kwFieldCount(T)][*:0]const u8 = undefined;
        for (@typeInfo(T).@"struct".field_names, 0..) |name, i| {
            names[i] = name;
        }
        break :blk names;
    };

    return CallbackShell(struct {
        fn invoke(m: *c.mrb_state, self_v: c.mrb_value) !c.mrb_value {
            const vm = Vm.fromMrb(m);
            const self_val = Value{ .mrb = m, .v = self_v };

            var slots: ArgSlots(specs) = ArgSlots(specs).init();
            var kw_syms: [if (sig.kw) |T| kwFieldCount(T) else 0]c.mrb_sym = @splat(0);
            var kw_values: [if (sig.kw) |T| kwFieldCount(T) else 0]c.mrb_value = @splat(c.mrz_nil_value());
            var kw_desc: c.mrb_kwargs = .{
                .num = 0,
                .required = 0,
                .table = null,
                .values = null,
                .rest = null,
            };
            if (sig.kw != null) {
                kw_desc = .{
                    .num = @intCast(kw_syms.len),
                    .required = @intCast(comptime kwRequiredCount(sig.kw.?)),
                    .table = &kw_syms,
                    .values = &kw_values,
                    // No **rest capture: unknown keywords raise ArgumentError.
                    .rest = null,
                };
            }
            var ptrs: [ArgSlots(specs).total_slots]?*anyopaque = @splat(null);
            slots.fillPtrs(&ptrs, if (sig.kw != null) @ptrCast(&kw_desc) else null);
            var parsed: c.mrb_int = 0;
            const ok = if (sig.kw != null) c.mrz_protected_get_args_kw(
                m,
                @ptrCast(fmtz.ptr),
                ptrs[0..].ptr,
                &kw_names.?,
                kw_names.?.len,
                &kw_syms,
                &parsed,
            ) else c.mrz_protected_get_args(
                m,
                @ptrCast(fmtz.ptr),
                ptrs[0..].ptr,
                &parsed,
            );
            if (!ok) return error.RubyException;

            const result: Value = try build(0, vm, &slots, &kw_values, parsed, .{ vm, self_val });
            try result.ensureOwnedBy(m);
            return result.v;
        }

        fn build(
            comptime i: usize,
            vm: *Vm,
            slots: *ArgSlots(specs),
            kw_values: []const c.mrb_value,
            parsed: c.mrb_int,
            built: anytype,
        ) anyerror!Value {
            if (i == specs.len) return @call(.auto, func, built);
            const F = @typeInfo(@TypeOf(func)).@"fn";
            const P = F.param_types[i + 2].?;
            const wrapped: P = if (comptime isKwArgs(P)) blk: {
                break :blk try kwParam(P, vm, kw_values);
            } else blk: {
                const value = extractSpec(specs, i, vm, slots);
                if (@typeInfo(P) == .optional) {
                    const optional_ordinal = i - sig.required;
                    if (parsed > @as(c.mrb_int, @intCast(sig.required)) + @as(c.mrb_int, @intCast(optional_ordinal))) {
                        break :blk value;
                    }
                    break :blk null;
                }
                if (P == Block) break :blk Block{ .value = value };
                break :blk value;
            };
            return build(i + 1, vm, slots, kw_values, parsed, built ++ .{wrapped});
        }
    }.invoke);
}

/// Build the `KwArgs(T)` argument from the raw keyword values mruby filled
/// (field order == table order; undef marks an omitted optional keyword).
fn kwParam(comptime P: type, vm: *Vm, kw_values: []const c.mrb_value) !P {
    const T = kwArgsStruct(P);
    var out: T = undefined;
    inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types, 0..) |name, ft, fi| {
        // mruby raises for missing required keywords before the callback
        // runs, so an undef slot here is an omitted optional keyword.
        if (@typeInfo(ft) == .optional) {
            @field(out, name) = if (c.mrz_undef_p(kw_values[fi]))
                null
            else
                try convert.fromValue(ft, .{ .mrb = vm.mrb, .v = kw_values[fi] });
        } else {
            @field(out, name) = try convert.fromValue(ft, .{ .mrb = vm.mrb, .v = kw_values[fi] });
        }
    }
    return .{ .values = out };
}
