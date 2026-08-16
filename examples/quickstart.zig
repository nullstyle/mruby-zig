//! Quickstart: evaluate Ruby from Zig and print the result.
//!
//!     zig build

const std = @import("std");
const mruby = @import("mruby");

pub fn main() !void {
    const mrb = mruby.c.mrb_open();
    if (mrb == null) return error.NullVm;
    if (!mruby.c.mrz_nil_p(mruby.c.mrz_exc_value(mrb.?))) {
        std.debug.print("open failed with exception:\n", .{});
        mruby.c.mrb_print_error(mrb.?);
        return error.InitFailed;
    }
    const vm = try mruby.Vm.init();
    defer vm.deinit();

    const result = try vm.loadString("[1, 2, 3, 4].map { |x| x * x }.reduce(:+)");
    std.debug.print("result: {d}\n", .{try result.asInt()});
}
