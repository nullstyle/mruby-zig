//! Quickstart: evaluate Ruby from Zig and read the result.
//!
//!     zig build run-quickstart

const std = @import("std");
const mruby = @import("mruby");

pub fn main() !void {
    const vm = try mruby.Vm.init();
    defer vm.deinit();

    const result = try vm.loadString("[1, 2, 3, 4].map { |x| x * x }.reduce(:+)");
    std.debug.print("sum of squares: {d}\n", .{try result.asInt()});
}
