const std = @import("std");
const mruby = @import("mruby");
pub fn main(init: std.process.Init) !void {
    var image = try mruby.sandbox.compileRite(init.gpa, "[3, 4].sum * 2", .{ .source_name = "determinism.rb" });
    defer image.deinit(init.gpa);
    const f = try std.Io.Dir.createFileAbsolute(init.io, "/tmp/mrz-verify/determinism_rite.bin", .{});
    var buf: [4096]u8 = undefined;
    var w = f.writer(init.io, &buf);
    try w.interface.writeAll(image.view().bytes);
    try w.interface.flush();
    f.close(init.io);
}
