//! Confinement proof for the worker syscall filter (Linux).
//!
//! Installs the same filter the confined helper uses, then attempts one
//! denied syscall (chdir) and returns:
//!   0 — chdir failed with EPERM: the filter bites
//!   1 — chdir succeeded: the process was NOT confined
//!   2 — unexpected failure (wrong errno, or install unsupported)

const std = @import("std");
const seccomp = @import("seccomp");

pub fn main(init: std.process.Init) !u8 {
    _ = init;
    seccomp.install() catch return 2;
    const rc = std.os.linux.syscall1(.chdir, @intFromPtr("/"));
    const errno: isize = @bitCast(rc);
    if (errno == -1) return 0; // EPERM
    if (errno < 0) return 2; // some other failure
    return 1; // the syscall succeeded: not confined
}
