//! Emit one complete StateCapsule to stdout. The build fixture captures these
//! bytes and feeds them to a separately linked consumer process.

const std = @import("std");
const mruby = @import("mruby");
const fixture = @import("state_capsule_process_common.zig");

pub fn main(init: std.process.Init) !void {
    var boot = try mruby.sandbox.BootstrapIsolate.spawn(.{});
    defer boot.deinit();
    const isolate = try boot.seal();
    defer isolate.deinit();

    const root = try isolate.run(fixture.producer_source);
    var capsule = try isolate.exportValue(init.gpa, root, .{
        .schema = fixture.schema,
    });
    defer capsule.deinit(init.gpa);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    try stdout_file.interface.writeAll(capsule.encoded);
    try stdout_file.interface.flush();
}
