//! Test launcher that preserves hostile inherited SIGXCPU state across exec.

const std = @import("std");
const config = @import("worker_signal_fixture_config");

pub fn main(init: std.process.Init) !u8 {
    const ignored: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.XCPU, &ignored, null);

    var blocked = std.posix.sigemptyset();
    std.posix.sigaddset(&blocked, .XCPU);
    std.posix.sigprocmask(std.posix.SIG.BLOCK, &blocked, null);

    return std.process.replace(init.io, .{
        .argv = &.{config.worker_executable},
    });
}
