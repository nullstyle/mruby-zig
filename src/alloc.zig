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

export fn mrb_basic_alloc_func(p: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    any_allocation.store(true, .release);

    if (size == 0) {
        if (p) |user_ptr| {
            const raw: [*]align(header_align) u8 = @alignCast(@as([*]u8, @ptrCast(user_ptr)) - header_bytes);
            const old = readHeader(raw);
            gpa.rawFree(raw[0 .. old + header_bytes], .fromByteUnits(header_align), @returnAddress());
            _ = live_bytes.fetchSub(old, .monotonic);
            _ = live_allocs.fetchSub(1, .monotonic);
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
            return @ptrCast(new_raw + header_bytes);
        }

        const new_raw = gpa.rawAlloc(size + header_bytes, .fromByteUnits(header_align), @returnAddress()) orelse return null;
        @memcpy(new_raw[header_bytes..][0..@min(old, size)], old_raw[header_bytes..][0..old]);
        gpa.rawFree(old_raw[0 .. old + header_bytes], .fromByteUnits(header_align), @returnAddress());
        writeHeader(new_raw, size);
        _ = live_bytes.fetchSub(old, .monotonic);
        _ = live_bytes.fetchAdd(size, .monotonic);
        return @ptrCast(new_raw + header_bytes);
    }

    const raw = gpa.rawAlloc(size + header_bytes, .fromByteUnits(header_align), @returnAddress()) orelse return null;
    writeHeader(raw, size);
    _ = live_bytes.fetchAdd(size, .monotonic);
    _ = live_allocs.fetchAdd(1, .monotonic);
    return @ptrCast(raw + header_bytes);
}

fn writeHeader(raw: [*]u8, size: usize) void {
    const h: *usize = @alignCast(@ptrCast(raw));
    h.* = size;
}

fn readHeader(raw: [*]u8) usize {
    const h: *const usize = @alignCast(@ptrCast(raw));
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
