//! Regression process for controller signal-disposition preflight checks.

const std = @import("std");
const mruby = @import("mruby");
const config = @import("worker_sigchld_fixture_config");

// The linked mruby C sources reference this export even though this fixture
// rejects the request before starting an mruby helper.
comptime {
    _ = mruby.alloc.mrb_basic_alloc_func_pub;
}

pub fn main(init: std.process.Init) !u8 {
    const descriptors_before = try openDescriptorCount(init.io);
    for (0..32) |_| {
        if (!missingWorkerRejected(init)) return 2;
    }
    if (try openDescriptorCount(init.io) != descriptors_before) return 3;
    if (!try noChildProcesses(init.io)) return 4;

    const default_pipe: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var old_pipe: std.posix.Sigaction = undefined;
    std.posix.sigaction(.PIPE, &default_pipe, &old_pipe);
    if (!rejectedWith(init, error.BrokenPipeProtectionUnavailable)) {
        std.posix.sigaction(.PIPE, &old_pipe, null);
        return 5;
    }
    std.posix.sigaction(.PIPE, &old_pipe, null);

    const ignored: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.NOCLDWAIT,
    };
    std.posix.sigaction(.CHLD, &ignored, null);

    return if (rejectedWith(init, error.ChildReapingUnavailable)) 0 else 6;
}

fn openDescriptorCount(io: std.Io) !usize {
    const directory = try std.Io.Dir.openDirAbsolute(io, "/dev/fd", .{
        .iterate = true,
    });
    defer directory.close(io);
    var iterator = directory.iterateAssumeFirstIteration();
    var count: usize = 0;
    while (try iterator.next(io)) |_| count += 1;
    return count;
}

fn missingWorkerRejected(init: std.process.Init) bool {
    var report = mruby.worker.runRite(
        init.io,
        init.gpa,
        "/mruby-zig-worker-does-not-exist",
        .{ .image = .{ .bytes = "not-a-rite-image" } },
    ) catch |err| return err == error.SpawnFailed or err == error.TransportFailure;
    report.deinit(init.gpa);
    return false;
}

fn noChildProcesses(io: std.Io) !bool {
    // Darwin can briefly report the internal process created by a failed
    // posix_spawn as running after posix_spawn itself has returned an error,
    // then remove it without making it waitable. Allow that kernel teardown
    // window, but fail immediately if we reap a real leaked child.
    for (0..200) |_| {
        var status: c_int = undefined;
        const result = std.posix.system.waitpid(-1, &status, std.posix.W.NOHANG);
        switch (std.posix.errno(result)) {
            .CHILD => return true,
            .INTR => continue,
            .SUCCESS => if (result != 0) return false,
            else => return false,
        }
        try std.Io.sleep(
            io,
            std.Io.Duration.fromNanoseconds(5 * std.time.ns_per_ms),
            .awake,
        );
    }
    return false;
}

fn rejectedWith(init: std.process.Init, expected: anyerror) bool {
    var report = mruby.worker.runRite(
        init.io,
        init.gpa,
        config.worker_executable,
        .{ .image = .{ .bytes = "not-a-rite-image" } },
    ) catch |err| return err == expected;
    report.deinit(init.gpa);
    return false;
}
