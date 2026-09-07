//! Synthetic inert fixture for the inspector CLI; never creates a Ruby VM.
const std = @import("std");
const mruby = @import("mruby");

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const path = args.next() orelse return error.ExpectedOutputPath;
    if (args.next() != null) return error.ExpectedOneOutputPath;
    const data = mruby.effect.data;
    var arguments = try data.encode(init.gpa, .{ .array = &.{.{ .string = "widget" }} }, 4096);
    defer arguments.deinit(init.gpa);
    var rejection = try data.reject(init.gpa, "OutOfStock", "no remaining stock", 4096);
    defer rejection.rejected.deinit(init.gpa);
    var terminal = try data.encode(init.gpa, .{ .array = &.{ .{ .string = "rejected" }, .{ .integer = 1 } } }, 4096);
    defer terminal.deinit(init.gpa);
    var trace = mruby.effect.Trace.init(init.gpa, .{ .code = @splat(1), .catalogue = @splat(2), .input = @splat(3) }, .{});
    defer trace.deinit();
    try trace.reserve("stock.reserve", 1, arguments.encoded, rejection.rejected.encoded.len);
    try trace.commitOutcome(.rejected, rejection.rejected.encoded);
    try trace.finish();
    const encoded = try trace.encode(init.gpa);
    defer init.gpa.free(encoded);
    const receipt = try mruby.strict.Turn.Receipt.encode(init.gpa, encoded, terminal.view(), .{});
    defer init.gpa.free(receipt);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = receipt });
}
