//! Ruby output redirection.
//!
//! Fidelity note: `print`/`puts`/`p` here cover the common semantics
//! (including `puts` printing array elements one per line); they are not a
//! complete reimplementations of CRuby's IO (no `$stdout` object, no
//! `$SCRIPT_LINES__`, buffering is per-call flush).
//!
//! `vm.setOutputWriter(&writer.interface)` installs `print`, `puts`, and `p`
//! on Kernel so Ruby-side output flows into any Zig `std.Io.Writer`
//! (a buffered file writer, a socket, an in-memory buffer, ...).
//!
//!     var buf: [4096]u8 = undefined;
//!     var fw = std.fs.File.stdout().writer(&buf);   // 0.16+ std.Io
//!     try vm.setOutputWriter(&fw.interface);
//!     _ = try vm.loadString("puts 'hello from ruby'");
//!     try fw.interface.flush();

const std = @import("std");
const c = @import("c.zig");
const value_mod = @import("value.zig");
const vm_mod = @import("vm.zig");
const class_mod = @import("class.zig");
const alloc_mod = @import("alloc.zig");

pub const Value = value_mod.Value;
pub const Vm = vm_mod.Vm;

/// Set the destination for Ruby-level print/puts/p and install those
/// methods on Kernel (idempotent; later calls only retarget the writer).
pub fn setOutputWriter(vm: *Vm, writer: *std.Io.Writer) !void {
    const previous_writer = vm.writer;
    vm.writer = writer;
    errdefer vm.writer = previous_writer;
    if (vm.output_installed) return;

    const kernel = try vm.getClass("Kernel");
    try kernel.defineMethod("print", "*", printFn);
    try kernel.defineMethod("puts", "*", putsFn);
    try kernel.defineMethod("p", "*", inspectFn);
    vm.output_installed = true;
}

fn toS(vm: *Vm, v: Value) ![]const u8 {
    const s = try vm.call(v, "to_s", .{});
    return s.asString();
}

fn writeVal(vm: *Vm, v: Value) !void {
    const writer = vm.writer orelse return;
    try writer.writeAll(try toS(vm, v));
}

fn copyRest(rest: class_mod.Rest) ![]c.mrb_value {
    if (rest.len == 0) return alloc_mod.gpa.alloc(c.mrb_value, 0);
    return alloc_mod.gpa.dupe(c.mrb_value, rest.base[0..rest.len]);
}

fn printFn(vm: *Vm, self: Value, rest: class_mod.Rest) anyerror!Value {
    _ = self;
    const writer = vm.writer orelse return Value.nil(vm.mrb);
    const args = try copyRest(rest);
    defer alloc_mod.gpa.free(args);
    for (args) |arg| try writeVal(vm, .{ .mrb = vm.mrb, .v = arg });
    try writer.flush();
    return Value.nil(vm.mrb);
}

fn putsFn(vm: *Vm, self: Value, rest: class_mod.Rest) anyerror!Value {
    _ = self;
    const writer = vm.writer orelse return Value.nil(vm.mrb);
    var context = PutsContext{};
    const args = try copyRest(rest);
    defer alloc_mod.gpa.free(args);
    if (args.len == 0) try writer.writeAll("\n");
    for (args) |arg| {
        try putsElem(vm, .{ .mrb = vm.mrb, .v = arg }, &context);
    }
    try writer.flush();
    return Value.nil(vm.mrb);
}

const PutsContext = struct {
    ancestry: [128]?*anyopaque = @splat(null),
    depth: usize = 0,
};

/// CRuby `puts` semantics: arrays print one element per line (recursively);
/// scalars print `to_s` plus a newline unless already newline-terminated.
fn putsElem(vm: *Vm, v: Value, context: *PutsContext) !void {
    const writer = vm.writer orelse return;
    if (c.mrz_array_p(v.v)) {
        const identity = c.mrz_ptr(v.v) orelse return error.InvalidArray;
        for (context.ancestry[0..context.depth]) |ancestor| {
            if (ancestor == identity) {
                try writer.writeAll("[...]\n");
                return;
            }
        }
        if (context.depth == context.ancestry.len)
            return error.OutputNestingTooDeep;

        context.ancestry[context.depth] = identity;
        context.depth += 1;
        defer context.depth -= 1;

        const len = c.mrz_array_len(v.v);
        for (0..len) |i| {
            try putsElem(
                vm,
                .{ .mrb = vm.mrb, .v = c.mrb_ary_entry(v.v, @intCast(i)) },
                context,
            );
        }
        return;
    }
    const s = try toS(vm, v);
    try writer.writeAll(s);
    if (s.len == 0 or s[s.len - 1] != '\n') try writer.writeAll("\n");
}

fn inspectFn(vm: *Vm, self: Value, rest: class_mod.Rest) anyerror!Value {
    _ = self;
    const writer = vm.writer orelse return Value.nil(vm.mrb);
    const args = try copyRest(rest);
    defer alloc_mod.gpa.free(args);
    for (args) |arg| {
        const s = try vm.call(.{ .mrb = vm.mrb, .v = arg }, "inspect", .{});
        const str = try s.asString();
        try writer.writeAll(str);
        try writer.writeAll("\n");
    }
    try writer.flush();
    return Value.nil(vm.mrb);
}
