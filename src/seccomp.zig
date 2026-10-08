//! Linux syscall confinement for the worker tier (roadmap B1).
//!
//! A classic-BPF `SECCOMP_SET_MODE_FILTER` program, installed by the worker
//! helper after exec and before any guest byte runs (the same position as
//! the RLIMIT ceilings). The default action is `SECCOMP_RET_ERRNO(EPERM)`:
//! denials are observable and testable rather than fatal. The allowlist is
//! the runtime surface a confined worker legitimately needs — memory
//! management, fd I/O on already-open descriptors, clocks, signals, and
//! exit, plus seed entropy — and nothing else: no file creation or path
//! access, no sockets, no process creation, no privilege changes.
//! `prlimit64` (own-limit reads) and `ioctl(TCGETS)` are allowed only in
//! argument-gated shapes. The authority manifest
//! already refuses to link filesystem/network/process gems into
//! worker-eligible builds; the filter enforces that decision at the kernel
//! boundary instead of trusting the linked set to be exhaustive.
//!
//! The filter is built from `std.os.linux.SYS`, so syscall numbers are
//! correct for the compiling architecture; `AUDIT_ARCH_*` and the
//! `seccomp_data` offsets are fixed by the kernel ABI. Installation
//! requires `PR_SET_NO_NEW_PRIVS` (itself a one-way process property) and
//! is one-way: filters can stack but never relax.

const std = @import("std");
const builtin = @import("builtin");

pub const available: bool = builtin.os.tag == .linux;

pub const Error = error{
    UnsupportedPlatform,
    FilterInstallationFailed,
};

/// seccomp_data field offsets (include/uapi/linux/seccomp.h).
const data_offset = struct {
    const nr = 0;
    const arch = 4;
};

/// Classic-BPF instruction encodings (include/uapi/linux/filter.h).
const bpf = struct {
    const ld_w_abs: u16 = 0x00 | 0x00 | 0x20; // BPF_LD | BPF_W | BPF_ABS
    const jmp_jeq_k: u16 = 0x05 | 0x10 | 0x00; // BPF_JMP | BPF_JEQ | BPF_K
    const ret_k: u16 = 0x06 | 0x00; // BPF_RET | BPF_K
};

const sock_filter = extern struct {
    code: u16,
    jt: u8,
    jf: u8,
    k: u32,
};

const sock_fprog = extern struct {
    len: u16,
    filter: [*]const sock_filter,
};

const seccomp_ret_allow: u32 = 0x7fff_0000;
const seccomp_ret_errno_eperm: u32 = 0x0005_0000 | 1; // SECCOMP_RET_ERRNO | EPERM
const seccomp_set_mode_filter: usize = 1;
const pr_set_no_new_privs: usize = 38;

fn auditArch() u32 {
    return switch (builtin.cpu.arch) {
        .x86_64 => 0xC000_003E, // AUDIT_ARCH_X86_64
        .aarch64 => 0xC000_00B7, // AUDIT_ARCH_AARCH64
        else => 0,
    };
}

fn sys(comptime name: @TypeOf(std.os.linux.SYS.exit)) usize {
    return @backingInt(name);
}

/// Argument-gated entries: allowed only when the syscall's argument at
/// `arg_index` equals `value`. Used for syscalls the runtime needs in a
/// read-only shape that a guest must not widen.
const ArgCheck = struct {
    nr: usize,
    arg_index: usize,
    value: u64,
};

/// The confined-worker allowlist. Everything else returns EPERM.
const allowed = switch (builtin.os.tag) {
    .linux => [_]usize{
        // Process lifecycle.
        sys(.exit),
        sys(.exit_group),
        // Memory management (allocator, GC).
        sys(.mmap),
        sys(.munmap),
        sys(.mprotect),
        sys(.brk),
        sys(.madvise),
        // I/O on already-open descriptors only.
        sys(.read),
        sys(.readv),
        sys(.write),
        sys(.writev),
        sys(.pwritev),
        // Entropy for mruby's seed initialization (the authority manifest's
        // `entropy` kind is already worker-eligible; policies pin seeds).
        sys(.getrandom),
        sys(.close),
        sys(.fstat),
        // Clocks: deadlines, mruby Time, and sleeps.
        sys(.clock_gettime),
        sys(.clock_nanosleep),
        sys(.gettimeofday),
        // Signals (libc hygiene; SIGXCPU delivery).
        sys(.rt_sigaction),
        sys(.rt_sigprocmask),
        sys(.rt_sigreturn),
        sys(.restart_syscall),
        sys(.tgkill),
        // Thread/primitive runtime hygiene.
        sys(.futex),
        sys(.getpid),
        sys(.gettid),
        sys(.sched_yield),
    },
    else => [_]usize{},
};

/// `prlimit64` with a NULL new-limit is the runtime's own-limit read (the
/// helper's address-space introspection); a non-NULL new-limit would let
/// guest code adjust its ceilings and is denied. `ioctl(TCGETS)` is the
/// stdio is-a-tty probe; every other request is denied.
const allowed_with_arg = switch (builtin.os.tag) {
    .linux => [_]ArgCheck{
        .{ .nr = sys(.prlimit64), .arg_index = 2, .value = 0 },
        .{ .nr = sys(.ioctl), .arg_index = 1, .value = 0x5401 }, // TCGETS
    },
    else => [_]ArgCheck{},
};

/// Instructions: arch gate, load nr, one compare/allow pair per plain
/// entry, then per argument-gated entry a five-instruction block
/// (compare, load arg, compare arg, allow, reload nr), ending in the
/// EPERM default. Jump offsets stay local (+1) so the shape is obviously
/// correct; the accumulator is reloaded after each gated block because
/// classic BPF has a single A register.
pub fn programLength() usize {
    if (!available) return 0;
    return 4 + 2 * allowed.len + 5 * allowed_with_arg.len + 1;
}

/// Render the filter program into `out`; returns the instruction count.
pub fn renderProgram(out: []sock_filter) usize {
    if (!available) return 0;
    const arch = auditArch();
    var i: usize = 0;
    out[i] = .{ .code = bpf.ld_w_abs, .jt = 0, .jf = 0, .k = data_offset.arch };
    i += 1;
    out[i] = .{ .code = bpf.jmp_jeq_k, .jt = 1, .jf = 0, .k = arch };
    i += 1;
    out[i] = .{ .code = bpf.ret_k, .jt = 0, .jf = 0, .k = seccomp_ret_errno_eperm };
    i += 1;
    out[i] = .{ .code = bpf.ld_w_abs, .jt = 0, .jf = 0, .k = data_offset.nr };
    i += 1;
    for (allowed) |nr| {
        // Match falls through to the ALLOW return; mismatch skips it and
        // continues down the chain (jf = 1).
        out[i] = .{ .code = bpf.jmp_jeq_k, .jt = 0, .jf = 1, .k = @intCast(nr) };
        i += 1;
        out[i] = .{ .code = bpf.ret_k, .jt = 0, .jf = 0, .k = seccomp_ret_allow };
        i += 1;
    }
    for (allowed_with_arg) |entry| {
        out[i] = .{ .code = bpf.jmp_jeq_k, .jt = 0, .jf = 1, .k = @intCast(entry.nr) };
        i += 1;
        out[i] = .{
            .code = bpf.ld_w_abs,
            .jt = 0,
            .jf = 0,
            .k = @intCast(16 + 8 * entry.arg_index),
        };
        i += 1;
        out[i] = .{ .code = bpf.jmp_jeq_k, .jt = 0, .jf = 1, .k = @intCast(entry.value) };
        i += 1;
        out[i] = .{ .code = bpf.ret_k, .jt = 0, .jf = 0, .k = seccomp_ret_allow };
        i += 1;
        out[i] = .{ .code = bpf.ld_w_abs, .jt = 0, .jf = 0, .k = data_offset.nr };
        i += 1;
    }
    out[i] = .{ .code = bpf.ret_k, .jt = 0, .jf = 0, .k = seccomp_ret_errno_eperm };
    i += 1;
    return i;
}

var program: [programLength()]sock_filter = undefined;
var installed: bool = false;

/// Install the confined-worker filter in the calling process. One-way: the
/// kernel keeps every installed filter for the process lifetime. Safe to
/// call again (returns without touching the kernel).
pub fn install() Error!void {
    if (!available) return error.UnsupportedPlatform;
    if (installed) return;

    const n = renderProgram(&program);
    std.debug.assert(n == program.len);
    const fprog = sock_fprog{
        .len = @intCast(n),
        .filter = &program,
    };

    // PR_SET_NO_NEW_PRIVS is required for unprivileged filter installation
    // and is itself irreversible: even a compromised guest can never regain
    // privilege through exec or setuid binaries.
    const prctl_rc = std.os.linux.syscall5(
        .prctl,
        pr_set_no_new_privs,
        1,
        0,
        0,
        0,
    );
    if (std.posix.errno(prctl_rc) != .SUCCESS) return error.FilterInstallationFailed;

    const seccomp_rc = std.os.linux.syscall3(
        .seccomp,
        seccomp_set_mode_filter,
        0,
        @intFromPtr(&fprog),
    );
    if (std.posix.errno(seccomp_rc) != .SUCCESS) return error.FilterInstallationFailed;

    installed = true;
}

// ---- tests ------------------------------------------------------------

test "program shape is arch-gated and entry-paired" {
    if (!available) return error.SkipZigTest;
    try std.testing.expect(auditArch() != 0);
    var buf: [programLength() + 4]sock_filter = undefined;
    const n = renderProgram(&buf);
    try std.testing.expectEqual(programLength(), n);
    // arch load + arch compare + arch-mismatch EPERM + nr load.
    try std.testing.expectEqual(bpf.ld_w_abs, buf[0].code);
    try std.testing.expectEqual(data_offset.arch, buf[0].k);
    try std.testing.expectEqual(bpf.jmp_jeq_k, buf[1].code);
    try std.testing.expectEqual(auditArch(), buf[1].k);
    try std.testing.expectEqual(bpf.ret_k, buf[2].code);
    try std.testing.expectEqual(seccomp_ret_errno_eperm, buf[2].k);
    try std.testing.expectEqual(data_offset.nr, buf[3].k);
    // Every allow entry pairs a compare with a local ALLOW return; a
    // mismatch must skip that return (jf = 1) or everything is allowed.
    var i: usize = 4;
    for (allowed) |nr| {
        try std.testing.expectEqual(bpf.jmp_jeq_k, buf[i].code);
        try std.testing.expectEqual(@as(u32, @intCast(nr)), buf[i].k);
        try std.testing.expectEqual(@as(u8, 0), buf[i].jt);
        try std.testing.expectEqual(@as(u8, 1), buf[i].jf);
        try std.testing.expectEqual(seccomp_ret_allow, buf[i + 1].k);
        i += 2;
    }
    // Argument-gated blocks: compare, load arg, compare, allow, reload nr.
    for (allowed_with_arg) |entry| {
        try std.testing.expectEqual(bpf.jmp_jeq_k, buf[i].code);
        try std.testing.expectEqual(@as(u32, @intCast(entry.nr)), buf[i].k);
        try std.testing.expectEqual(bpf.ld_w_abs, buf[i + 1].code);
        try std.testing.expectEqual(@as(u32, @intCast(16 + 8 * entry.arg_index)), buf[i + 1].k);
        try std.testing.expectEqual(bpf.jmp_jeq_k, buf[i + 2].code);
        try std.testing.expectEqual(@as(u32, @intCast(entry.value)), buf[i + 2].k);
        try std.testing.expectEqual(seccomp_ret_allow, buf[i + 3].k);
        try std.testing.expectEqual(bpf.ld_w_abs, buf[i + 4].code);
        try std.testing.expectEqual(data_offset.nr, buf[i + 4].k);
        i += 5;
    }
    // Terminal default. The walking index stops before it.
    try std.testing.expectEqual(seccomp_ret_errno_eperm, buf[n - 1].k);
    try std.testing.expectEqual(n - 1, i);
}

test "allowlist contains no path, socket, process, or privilege syscall" {
    if (!available) return error.SkipZigTest;
    const denied = [_]usize{
        sys(.openat),
        sys(.unlinkat),
        sys(.mkdirat),
        sys(.socket),
        sys(.connect),
        sys(.execve),
        sys(.clone),
        sys(.prctl),
        sys(.seccomp),
        sys(.ptrace),
    };
    for (denied) |nr| {
        for (allowed) |ok| {
            try std.testing.expect(ok != nr);
        }
    }
}
