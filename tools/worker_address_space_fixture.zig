//! Test launcher that preserves a finite inherited RLIMIT_AS across exec.

const std = @import("std");
const config = @import("worker_address_space_fixture_config");

pub fn main(init: std.process.Init) !u8 {
    const inherited = try std.posix.getrlimit(.AS);
    const fixture_ceiling: std.posix.rlim_t = 128 * 1024 * 1024;
    const effective = @min(fixture_ceiling, inherited.cur);
    try std.posix.setrlimit(.AS, .{ .cur = effective, .max = effective });

    return std.process.replace(init.io, .{
        .argv = &.{config.worker_executable},
    });
}
