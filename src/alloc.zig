//! Zig-side replacement for mruby's `src/allocf.c`.
//!
//! mruby 4.0 routes every allocation through the single `mrb_basic_alloc_func`
//! symbol (realloc-style protocol: `p == null` allocates, `size == 0` frees).
//! The build excludes `allocf.c` from libmruby and this file exports the
//! symbol instead, so the Ruby heap lives in a Zig allocator.
//!
//! Because Zig's Allocator interface needs the old size on free/resize — and
//! the realloc protocol does not provide it — each allocation is prefixed
//! with a small header recording its size. Overhead: 16 bytes per allocation
//! (kept aligned to `max_align_t` so C code sees properly aligned memory).
//!
//! The allocator is process-global (an upstream 4.0 constraint: the function
//! has no user-data parameter). Call `setAllocator` before creating the first
//! `Vm`; afterwards it must not change. The default is `std.heap.c_allocator`
//! (thread-safe). If you supply another allocator, it must be safe to call
//! from whatever threads host `Vm` instances.

const std = @import("std");

const header_bytes = 16; // one max_align_t unit on the platforms we support
const header_align = 16;

pub var gpa: std.mem.Allocator = std.heap.c_allocator;
var any_allocation = std.atomic.Value(bool).init(false);
var live_bytes = std.atomic.Value(usize).init(0);
var live_allocs = std.atomic.Value(usize).init(0);

/// Replace the allocator backing all mruby heaps. Must be called before the
/// first `Vm` is initialized (i.e. before any mruby allocation happens).
pub fn setAllocator(a: std.mem.Allocator) void {
    if (any_allocation.load(.acquire)) {
        @panic("mruby.alloc.setAllocator called after the first allocation; choose the allocator up front");
    }
    gpa = a;
}

/// Approximate number of bytes currently held by mruby (excluding headers).
pub fn liveBytes() usize {
    return live_bytes.load(.monotonic);
}

/// Approximate number of live mruby allocations.
pub fn liveAllocs() usize {
    return live_allocs.load(.monotonic);
}

/// Per-isolate accounting for the sandboxing layer. The allocator
/// attributes every allocation to the cell installed on the executing
/// thread (`enter`/`exit`); sound because a Vm/isolate runs on one thread
/// at a time (the package's standing threading constraint).
///
/// Caps are enforced on the post-realloc net usage. Hitting the soft cap
/// makes the next allocation fail (mruby full-GCs, retries once, then
/// raises the rescuable NoMemoryError) and sets the sticky `soft_oom` so
/// the instruction hook can escalate. The hard cap fails permanently.
pub const IsolateCell = struct {
    live_bytes: usize = 0,
    live_allocs: usize = 0,
    soft_cap: ?usize = null,
    hard_cap: ?usize = null,
    soft_oom: bool = false,
    hard_oom: bool = false,
    peak_bytes: usize = 0,
    on_limit: ?*const fn (ctx: ?*anyopaque, kind: LimitKind, attempted: usize) void = null,
    on_limit_ctx: ?*anyopaque = null,

    pub const LimitKind = enum { soft, hard };
};

threadlocal var current_cell: ?*IsolateCell = null;

/// Attribute subsequent allocations on this thread to `cell` (nesting is
/// not supported: one isolate per thread at a time).
pub fn enterIsolate(cell: *IsolateCell) void {
    current_cell = cell;
}

/// Drop attribution on this thread (restores process-global accounting
/// only).
pub fn exitIsolate() void {
    current_cell = null;
}

/// The isolate currently attributed on this thread, if any.
pub fn currentIsolateCell() ?*IsolateCell {
    return current_cell;
}

/// Internal-use alias so the sandbox (same module family) can route
/// frees of mruby-allocated buffers through the header-prefixed path.
pub const mrb_basic_alloc_func_pub = mrb_basic_alloc_func;

/// Projected cell live-bytes after a realloc from `old` to `size`.
///
/// `old` can exceed `ic.live_bytes` when the block was allocated while no
/// cell was entered (e.g. via `iso.vm` before the first `run`, or during
/// capability application) and is later resized inside a cell. Subtracting
/// `old` directly would underflow `usize` — panicking in safe builds, and in
/// release wrapping huge to trip the cap and permanently poison the isolate.
/// Only subtract what we plausibly counted: for an attributed block
/// (`old <= live_bytes`) this is exact; otherwise we start counting the block
/// at its new size (its eventual free saturates via `-|=`, so it balances).
fn projectedLive(ic: *IsolateCell, old: usize, size: usize) usize {
    return if (old <= ic.live_bytes) ic.live_bytes - old + size else ic.live_bytes + size;
}

export fn mrb_basic_alloc_func(p: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    any_allocation.store(true, .release);

    // Per-isolate accounting/caps (no-ops without an entered cell). Frees
    // (size == 0) always proceed — caps only gate allocation/growth.
    const cell = current_cell;
    if (cell) |ic| {
        if (size != 0) {
            const old: usize = if (p != null) blk: {
                const raw: [*]u8 = @ptrCast(p.?);
                break :blk readHeader(raw - header_bytes);
            } else 0;
            if (ic.hard_oom) return null;
            const new_live = projectedLive(ic, old, size);
            if (ic.hard_cap) |cap| {
                if (new_live > cap) {
                    ic.hard_oom = true;
                    if (ic.on_limit) |cb| cb(ic.on_limit_ctx, .hard, size);
                    return null;
                }
            }
            if (ic.soft_cap) |cap| {
                if (new_live > cap) {
                    ic.soft_oom = true;
                    if (ic.on_limit) |cb| cb(ic.on_limit_ctx, .soft, size);
                    return null;
                }
            }
        }
    }

    if (size == 0) {
        if (p) |user_ptr| {
            const raw: [*]align(header_align) u8 = @alignCast(@as([*]u8, @ptrCast(user_ptr)) - header_bytes);
            const old = readHeader(raw);
            gpa.rawFree(raw[0 .. old + header_bytes], .fromByteUnits(header_align), @returnAddress());
            _ = live_bytes.fetchSub(old, .monotonic);
            _ = live_allocs.fetchSub(1, .monotonic);
            if (cell) |ic| {
                ic.live_bytes -|= old;
                ic.live_allocs -|= 1;
            }
        }
        return null;
    }

    if (p) |user_ptr| {
        const old_raw: [*]align(header_align) u8 = @alignCast(@as([*]u8, @ptrCast(user_ptr)) - header_bytes);
        const old = readHeader(old_raw);

        // Try in-place growth first; shrink in place when it is a big win.
        if (gpa.rawRemap(old_raw[0 .. old + header_bytes], .fromByteUnits(header_align), size + header_bytes, @returnAddress())) |new_raw| {
            writeHeader(new_raw, size);
            _ = live_bytes.fetchSub(old, .monotonic);
            _ = live_bytes.fetchAdd(size, .monotonic);
            if (cell) |ic| {
                // Must be projectedLive, not `live_bytes - old + size`: a
                // buffer allocated before this cell was entered is not in
                // ic.live_bytes, so `old` can exceed it and the subtraction
                // underflows. The copy path below already used the helper;
                // this in-place path did not, and only Linux noticed --
                // rawRemap succeeds far more often there, so macOS almost
                // always took the copy path and hid it.
                ic.live_bytes = projectedLive(ic, old, size);
                if (ic.live_bytes > ic.peak_bytes) ic.peak_bytes = ic.live_bytes;
            }
            return @ptrCast(new_raw + header_bytes);
        }

        const new_raw = gpa.rawAlloc(size + header_bytes, .fromByteUnits(header_align), @returnAddress()) orelse return null;
        // Copy only what fits the new buffer: on a shrink (size < old) both
        // slices must be `size` long — @memcpy requires equal lengths, so the
        // source must be clamped too, not just the destination.
        const copy_len = @min(old, size);
        @memcpy(new_raw[header_bytes..][0..copy_len], old_raw[header_bytes..][0..copy_len]);
        gpa.rawFree(old_raw[0 .. old + header_bytes], .fromByteUnits(header_align), @returnAddress());
        writeHeader(new_raw, size);
        _ = live_bytes.fetchSub(old, .monotonic);
        _ = live_bytes.fetchAdd(size, .monotonic);
        if (cell) |ic| {
            ic.live_bytes = projectedLive(ic, old, size);
            if (ic.live_bytes > ic.peak_bytes) ic.peak_bytes = ic.live_bytes;
        }
        return @ptrCast(new_raw + header_bytes);
    }

    const raw = gpa.rawAlloc(size + header_bytes, .fromByteUnits(header_align), @returnAddress()) orelse return null;
    writeHeader(raw, size);
    _ = live_bytes.fetchAdd(size, .monotonic);
    _ = live_allocs.fetchAdd(1, .monotonic);
    if (cell) |ic| {
        ic.live_bytes += size;
        ic.live_allocs += 1;
        if (ic.live_bytes > ic.peak_bytes) ic.peak_bytes = ic.live_bytes;
    }
    return @ptrCast(raw + header_bytes);
}

test "isolate cells cap attribution without touching global accounting" {
    const a = std.testing.allocator;
    const prev = gpa;
    gpa = a;
    defer gpa = prev;

    var counts = [2]usize{ 0, 0 };
    var cell = IsolateCell{
        .soft_cap = 100,
        .hard_cap = 200,
        .on_limit = struct {
            fn cb(ctx: ?*anyopaque, kind: IsolateCell.LimitKind, attempted: usize) void {
                const seen: *[2]usize = @ptrCast(@alignCast(ctx.?));
                seen[@backingInt(kind)] += attempted;
            }
        }.cb,
        .on_limit_ctx = &counts,
    };
    enterIsolate(&cell);
    defer exitIsolate();

    const p1 = mrb_basic_alloc_func(null, 60) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 60), cell.live_bytes);
    // net 60+60 > soft(100): soft refusal, sticky flag, no allocation
    try std.testing.expect(mrb_basic_alloc_func(null, 60) == null);
    try std.testing.expect(cell.soft_oom);
    try std.testing.expect(!cell.hard_oom);
    try std.testing.expectEqual(@as(usize, 60), counts[0]);
    // free path always works, even under sticky soft oom
    _ = mrb_basic_alloc_func(p1, 0);
    try std.testing.expectEqual(@as(usize, 0), cell.live_bytes);
    cell.soft_oom = false; // reset stickiness for the hard-cap check
    // 250 > hard(200): permanent refusal
    try std.testing.expect(mrb_basic_alloc_func(null, 250) == null);
    try std.testing.expect(cell.hard_oom);
    try std.testing.expect(mrb_basic_alloc_func(null, 1) == null); // sticky
    try std.testing.expectEqual(@as(usize, 250), counts[1]);
    try std.testing.expectEqual(@as(usize, 60), cell.peak_bytes);
}

fn writeHeader(raw: [*]u8, size: usize) void {
    const h: *usize = @ptrCast(@alignCast(raw));
    h.* = size;
}

fn readHeader(raw: [*]u8) usize {
    const h: *const usize = @ptrCast(@alignCast(raw));
    return h.*;
}

test "roundtrip alloc/realloc/free" {
    const a = std.testing.allocator;
    const prev = gpa;
    gpa = a;
    defer gpa = prev;

    const p1 = mrb_basic_alloc_func(null, 10) orelse return error.TestUnexpectedResult;
    const bytes: [*]u8 = @ptrCast(p1);
    @memset(bytes[0..10], 0xAA);
    const p2 = mrb_basic_alloc_func(p1, 100) orelse return error.TestUnexpectedResult;
    const b2: [*]u8 = @ptrCast(p2);
    try std.testing.expect(b2[0] == 0xAA); // contents preserved
    _ = mrb_basic_alloc_func(p2, 0);
    try std.testing.expectEqual(@as(usize, 0), liveBytes());
    try std.testing.expectEqual(@as(usize, 0), liveAllocs());
}
