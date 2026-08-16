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

pub const Value = value_mod.Value;
pub const Vm = vm_mod.Vm;

/// Set the destination for Ruby-level print/puts/p and install those
/// methods on Kernel (idempotent; later calls only retarget the writer).
pub fn setOutputWriter(vm: *Vm, writer: *std.Io.Writer) !void {
    vm.writer = writer;
    if (vm.output_installed) return;
    vm.output_installed = true;

    const kernel = try vm.getClass("Kernel");
    kernel.defineMethod("print", "*", printFn);
    kernel.defineMethod("puts", "*", putsFn);
    kernel.defineMethod("p", "*", inspectFn);
}

fn toS(vm: *Vm, v: Value) ![]const u8 {
    const s = try vm.call(v, "to_s", .{});
    return s.asString();
}

fn writeVal(vm: *Vm, v: Value) !void {
    const writer = vm.writer orelse return;
    try writer.writeAll(try toS(vm, v));
}

fn printFn(vm: *Vm, self: Value, rest: class_mod.Rest) anyerror!Value {
    _ = self;
    const writer = vm.writer orelse return Value.nil(vm.mrb);
    for (0..rest.len) |i| try writeVal(vm, rest.get(i));
    try writer.flush();
    return Value.nil(vm.mrb);
}

fn putsFn(vm: *Vm, self: Value, rest: class_mod.Rest) anyerror!Value {
    _ = self;
    const writer = vm.writer orelse return Value.nil(vm.mrb);
    if (rest.len == 0) try writer.writeAll("\n");
    for (0..rest.len) |i| try putsElem(vm, rest.get(i));
    try writer.flush();
    return Value.nil(vm.mrb);
}

/// CRuby `puts` semantics: arrays print one element per line (recursively);
/// scalars print `to_s` plus a newline unless already newline-terminated.
fn putsElem(vm: *Vm, v: Value) !void {
    const writer = vm.writer orelse return;
    if (c.mrz_array_p(v.v)) {
        const n = try (try vm.call(v, "size", .{})).asInt();
        for (0..@intCast(n)) |i| {
            try putsElem(vm, try vm.call(v, "[]", .{vm.intValue(i)}));
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
    for (0..rest.len) |i| {
        const s = try vm.call(rest.get(i), "inspect", .{});
        const str = try s.asString();
        try writer.writeAll(str);
        try writer.writeAll("\n");
    }
    try writer.flush();
    return Value.nil(vm.mrb);
}
