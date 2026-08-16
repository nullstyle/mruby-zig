//! Ruby output redirection.
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
/// methods on Kernel (idempotent).
pub fn setOutputWriter(vm: *Vm, writer: *std.Io.Writer) void {
    vm.writer = writer;
    if (vm.output_installed) return;
    vm.output_installed = true;

    const kernel = vm.getClass("Kernel") catch return;
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
    for (0..rest.len) |i| {
        const s = try toS(vm, rest.get(i));
        try writer.writeAll(s);
        if (s.len == 0 or s[s.len - 1] != '\n') try writer.writeAll("\n");
    }
    if (rest.len == 0) try writer.writeAll("\n");
    try writer.flush();
    return Value.nil(vm.mrb);
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
