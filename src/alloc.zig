//! Zig-side replacement for mruby's `src/allocf.c`.
//!
//! mruby 4.0 routes every allocation through the single `mrb_basic_alloc_func`
//! symbol (realloc-style protocol: `p == null` allocates, `size == 0` frees).
//! The build excludes `allocf.c` from libmruby and this file exports the
//! symbol instead, so the Ruby heap lives in a Zig allocator.
//!
//! Because Zig's Allocator interface needs the old size on free/resize — and
//! the realloc protocol does not provide it — each allocation is prefixed
//! with a small header recording its size and accounting owner. Overhead: 16
//! bytes per allocation on 64-bit targets (kept aligned to `max_align_t` so C
//! code sees properly aligned memory).
//!
//! The allocator is process-global (an upstream 4.0 constraint: the function
//! has no user-data parameter). Call `setAllocator` before creating the first
//! `Vm`; afterwards it must not change. The build defaults to
//! `std.heap.c_allocator` and can select a process-lifetime arena instead. If
//! you supply another allocator, it must be safe to call from whatever threads
//! host `Vm` instances.

const std = @import("std");
const allocator_config = @import("allocator_config");

const header_align = 16;
const AllocationHeader = extern struct {
    size: usize,
    /// Independently-lived token for the cell that charged this block. Current
    /// TLS only chooses an owner for a new or previously-unowned block.
    owner: ?*OwnerToken,
};
const header_bytes = std.mem.alignForward(usize, @sizeOf(AllocationHeader), header_align);

pub const DefaultAllocator = enum {
    libc,
    arena,
};

/// Allocator selected by the package build. `setAllocator` may replace it
/// before the first mruby allocation.
pub const configured_default: DefaultAllocator =
    if (allocator_config.use_arena) .arena else .libc;

// The arena profile deliberately shares the process lifetime of mruby's global
// allocator hook. Its child is thread-safe, as required for separate VMs on
// separate threads; individual frees may be retained until process exit.
var process_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);

fn configuredAllocator() std.mem.Allocator {
    return switch (configured_default) {
        .libc => std.heap.c_allocator,
        .arena => process_arena.allocator(),
    };
}

pub var gpa: std.mem.Allocator = configuredAllocator();
var any_allocation = std.atomic.Value(bool).init(false);
var live_bytes = std.atomic.Value(usize).init(0);
var live_allocs = std.atomic.Value(usize).init(0);

/// Replace the configured allocator backing all mruby heaps. Must be called
/// before the first `Vm` is initialized (i.e. before any mruby allocation).
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
/// raises the rescuable NoMemoryError) and atomically publishes sticky soft
/// OOM state so the instruction hook can escalate. The hard cap fails
/// permanently.
pub const IsolateCell = struct {
    const oom_soft: u8 = 1 << 0;
    const oom_hard: u8 = 1 << 1;

    live_bytes: usize = 0,
    live_allocs: usize = 0,
    soft_cap: ?usize = null,
    hard_cap: ?usize = null,
    oom_bits: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    peak_bytes: usize = 0,
    on_limit: ?*const fn (ctx: ?*anyopaque, kind: LimitKind, attempted: usize) void = null,
    on_limit_ctx: ?*anyopaque = null,
    owner_token: ?*OwnerToken = null,

    pub const LimitKind = enum { soft, hard };

    pub fn softOom(cell: *const IsolateCell) bool {
        return cell.oom_bits.load(.acquire) & oom_soft != 0;
    }

    pub fn hardOom(cell: *const IsolateCell) bool {
        return cell.oom_bits.load(.acquire) & oom_hard != 0;
    }

    pub fn anyOom(cell: *const IsolateCell) bool {
        return cell.oom_bits.load(.acquire) != 0;
    }

    fn noteOom(cell: *IsolateCell, kind: LimitKind) void {
        const bit: u8 = switch (kind) {
            .soft => oom_soft,
            .hard => oom_hard,
        };
        _ = cell.oom_bits.fetchOr(bit, .release);
    }

    /// Create the independently-lived token stored in allocation headers.
    /// Call `retireOwnership` after all directly-owned VM allocations are
    /// released and before the cell itself is destroyed.
    pub fn initOwnership(cell: *IsolateCell) !void {
        std.debug.assert(cell.owner_token == null);
        const token = try gpa.create(OwnerToken);
        token.* = .{ .cell = cell, .allocator = gpa };
        cell.owner_token = token;
    }

    pub fn retireOwnership(cell: *IsolateCell) void {
        const token = cell.owner_token orelse return;
        cell.owner_token = null;
        token.retire();
    }
};

/// A header may escape its original Isolate through a foreign Vm created by a
/// host callback. The token therefore outlives the embedded cell: retiring the
/// cell makes later foreign frees/reallocs unaccounted, while header references
/// keep the token itself alive until the last escaped allocation is released.
const OwnerToken = struct {
    mutex: std.atomic.Mutex = .unlocked,
    cell: ?*IsolateCell,
    refs: usize = 1, // the live cell owns one reference
    allocator: std.mem.Allocator,

    const Notification = struct {
        callback: *const fn (ctx: ?*anyopaque, kind: IsolateCell.LimitKind, attempted: usize) void,
        context: ?*anyopaque,
        kind: IsolateCell.LimitKind,
    };

    fn lock(token: *OwnerToken) void {
        while (!token.mutex.tryLock()) std.atomic.spinLoopHint();
    }

    /// Check caps and optionally acquire the reference that a new/adopted
    /// allocation header will own. Notifications run outside the token lock.
    fn prepare(token: *OwnerToken, old: ?AllocationHeader, size: usize, acquire_header_ref: bool) bool {
        var notification: ?Notification = null;
        var accepted = true;

        token.lock();
        if (token.cell) |cell| {
            if (cell.hardOom()) {
                accepted = false;
            } else {
                const projected = projectedLive(cell, token, old, size);
                if (cell.hard_cap) |cap| {
                    if (projected > cap) {
                        cell.noteOom(.hard);
                        if (cell.on_limit) |callback| notification = .{
                            .callback = callback,
                            .context = cell.on_limit_ctx,
                            .kind = .hard,
                        };
                        accepted = false;
                    }
                }
                if (accepted) {
                    if (cell.soft_cap) |cap| {
                        if (projected > cap) {
                            cell.noteOom(.soft);
                            if (cell.on_limit) |callback| notification = .{
                                .callback = callback,
                                .context = cell.on_limit_ctx,
                                .kind = .soft,
                            };
                            accepted = false;
                        }
                    }
                }
            }
        }
        if (accepted and acquire_header_ref) token.refs += 1;
        token.mutex.unlock();

        if (notification) |notice| notice.callback(notice.context, notice.kind, size);
        return accepted;
    }

    fn accountNew(token: *OwnerToken, size: usize) void {
        token.lock();
        defer token.mutex.unlock();
        const cell = token.cell orelse return;
        cell.live_bytes +|= size;
        cell.live_allocs +|= 1;
        if (cell.live_bytes > cell.peak_bytes) cell.peak_bytes = cell.live_bytes;
    }

    fn accountResize(token: *OwnerToken, old: AllocationHeader, size: usize) void {
        token.lock();
        defer token.mutex.unlock();
        const cell = token.cell orelse return;
        if (old.owner == token) {
            cell.live_bytes = cell.live_bytes -| old.size +| size;
        } else {
            cell.live_bytes +|= size;
            cell.live_allocs +|= 1;
        }
        if (cell.live_bytes > cell.peak_bytes) cell.peak_bytes = cell.live_bytes;
    }

    fn releaseUncommitted(token: *OwnerToken) void {
        token.release(false, 0);
    }

    fn releaseAllocation(token: *OwnerToken, size: usize) void {
        token.release(true, size);
    }

    fn release(token: *OwnerToken, account_free: bool, size: usize) void {
        var destroy = false;
        token.lock();
        if (account_free) {
            if (token.cell) |cell| {
                cell.live_bytes -|= size;
                cell.live_allocs -|= 1;
            }
        }
        std.debug.assert(token.refs > 0);
        token.refs -= 1;
        destroy = token.refs == 0;
        token.mutex.unlock();
        if (destroy) token.allocator.destroy(token);
    }

    fn retire(token: *OwnerToken) void {
        var destroy = false;
        token.lock();
        token.cell = null;
        std.debug.assert(token.refs > 0);
        token.refs -= 1;
        destroy = token.refs == 0;
        token.mutex.unlock();
        if (destroy) token.allocator.destroy(token);
    }
};

threadlocal var current_cell: ?*IsolateCell = null;

/// A save/restore token for internal lifecycle operations that may be nested
/// inside a callback running under another Isolate's allocator attribution.
pub const AttributionGuard = struct {
    installed: *IsolateCell,
    previous: ?*IsolateCell,
};

/// Attribute subsequent allocations on this thread to an ownership-initialized
/// `cell` (nesting is not supported; use push/restore internally).
pub fn enterIsolate(cell: *IsolateCell) void {
    std.debug.assert(cell.owner_token != null);
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

pub fn pushIsolate(cell: *IsolateCell) AttributionGuard {
    std.debug.assert(cell.owner_token != null);
    const guard = AttributionGuard{ .installed = cell, .previous = current_cell };
    current_cell = cell;
    return guard;
}

pub fn restoreIsolate(guard: AttributionGuard) void {
    std.debug.assert(current_cell == guard.installed);
    current_cell = guard.previous;
}

/// Internal-use alias so the sandbox (same module family) can route
/// frees of mruby-allocated buffers through the header-prefixed path.
pub const mrb_basic_alloc_func_pub = mrb_basic_alloc_func;

/// Projected owner live-bytes after allocating or resizing to `size`. Only an
/// exact owner match permits subtraction; size alone says nothing about which
/// cell paid for a block.
fn projectedLive(ic: *IsolateCell, owner: *OwnerToken, old: ?AllocationHeader, size: usize) usize {
    var base = ic.live_bytes;
    if (old) |header| {
        if (header.owner == owner) base -|= header.size;
    }
    return base +| size;
}

test "build-selected allocator initializes the runtime default" {
    const expected = configuredAllocator();
    // `c_allocator`'s context pointer is `undefined` by contract and must
    // not be read; the vtable identifies the allocator. The arena profile's
    // context is the live arena pointer and must match exactly.
    try std.testing.expect(gpa.vtable == expected.vtable);
    if (configured_default == .arena) {
        try std.testing.expect(gpa.ptr == expected.ptr);
    }
}

test "an unowned realloc cannot subtract another cell's charged bytes" {
    const previous = gpa;
    gpa = std.testing.allocator;
    defer gpa = previous;

    var cell = IsolateCell{};
    try cell.initOwnership();
    defer cell.retireOwnership();
    enterIsolate(&cell);
    const charged = mrb_basic_alloc_func(null, 100) orelse return error.TestUnexpectedResult;
    exitIsolate();

    const unowned = mrb_basic_alloc_func(null, 40) orelse return error.TestUnexpectedResult;
    enterIsolate(&cell);
    defer exitIsolate();

    const adopted = mrb_basic_alloc_func(unowned, 50) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 150), cell.live_bytes);

    _ = mrb_basic_alloc_func(adopted, 0);
    try std.testing.expectEqual(@as(usize, 100), cell.live_bytes);
    _ = mrb_basic_alloc_func(charged, 0);
    try std.testing.expectEqual(@as(usize, 0), cell.live_bytes);
}

export fn mrb_basic_alloc_func(p: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    any_allocation.store(true, .release);

    const old_header: ?AllocationHeader = if (p) |user_ptr| blk: {
        const raw: [*]u8 = @ptrCast(user_ptr);
        break :blk readHeader(raw - header_bytes);
    } else null;
    const current_owner = if (current_cell) |cell| cell.owner_token else null;
    const owner: ?*OwnerToken = if (old_header) |header| header.owner orelse current_owner else current_owner;

    if (size == 0) {
        if (p) |user_ptr| {
            const raw: [*]align(header_align) u8 = @alignCast(@as([*]u8, @ptrCast(user_ptr)) - header_bytes);
            const header = old_header.?;
            gpa.rawFree(raw[0 .. header.size + header_bytes], .fromByteUnits(header_align), @returnAddress());
            _ = live_bytes.fetchSub(header.size, .monotonic);
            _ = live_allocs.fetchSub(1, .monotonic);
            if (header.owner) |token| token.releaseAllocation(header.size);
        }
        return null;
    }

    const total = std.math.add(usize, size, header_bytes) catch return null;
    const acquire_header_ref = owner != null and (old_header == null or old_header.?.owner == null);
    if (owner) |token| {
        if (!token.prepare(old_header, size, acquire_header_ref)) return null;
    }
    var header_ref_committed = !acquire_header_ref;
    defer if (!header_ref_committed) owner.?.releaseUncommitted();

    if (p) |user_ptr| {
        const old_raw: [*]align(header_align) u8 = @alignCast(@as([*]u8, @ptrCast(user_ptr)) - header_bytes);
        const old = old_header.?;

        // Try in-place growth first; shrink in place when it is a big win.
        if (gpa.rawRemap(old_raw[0 .. old.size + header_bytes], .fromByteUnits(header_align), total, @returnAddress())) |new_raw| {
            writeHeader(new_raw, .{ .size = size, .owner = owner });
            _ = live_bytes.fetchSub(old.size, .monotonic);
            _ = live_bytes.fetchAdd(size, .monotonic);
            if (owner) |token| token.accountResize(old, size);
            header_ref_committed = true;
            return @ptrCast(new_raw + header_bytes);
        }

        const new_raw = gpa.rawAlloc(total, .fromByteUnits(header_align), @returnAddress()) orelse return null;
        // Copy only what fits the new buffer: on a shrink (size < old) both
        // slices must be `size` long — @memcpy requires equal lengths, so the
        // source must be clamped too, not just the destination.
        const copy_len = @min(old.size, size);
        @memcpy(new_raw[header_bytes..][0..copy_len], old_raw[header_bytes..][0..copy_len]);
        gpa.rawFree(old_raw[0 .. old.size + header_bytes], .fromByteUnits(header_align), @returnAddress());
        writeHeader(new_raw, .{ .size = size, .owner = owner });
        _ = live_bytes.fetchSub(old.size, .monotonic);
        _ = live_bytes.fetchAdd(size, .monotonic);
        if (owner) |token| token.accountResize(old, size);
        header_ref_committed = true;
        return @ptrCast(new_raw + header_bytes);
    }

    const raw = gpa.rawAlloc(total, .fromByteUnits(header_align), @returnAddress()) orelse return null;
    writeHeader(raw, .{ .size = size, .owner = owner });
    _ = live_bytes.fetchAdd(size, .monotonic);
    _ = live_allocs.fetchAdd(1, .monotonic);
    if (owner) |token| token.accountNew(size);
    header_ref_committed = true;
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
    try cell.initOwnership();
    defer cell.retireOwnership();
    enterIsolate(&cell);
    defer exitIsolate();

    const p1 = mrb_basic_alloc_func(null, 60) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 60), cell.live_bytes);
    // net 60+60 > soft(100): soft refusal, sticky flag, no allocation
    try std.testing.expect(mrb_basic_alloc_func(null, 60) == null);
    try std.testing.expect(cell.softOom());
    try std.testing.expect(!cell.hardOom());
    try std.testing.expectEqual(@as(usize, 60), counts[0]);
    // free path always works, even under sticky soft oom
    _ = mrb_basic_alloc_func(p1, 0);
    try std.testing.expectEqual(@as(usize, 0), cell.live_bytes);
    exitIsolate();
    var hard_cell = IsolateCell{
        .soft_cap = 300,
        .hard_cap = 200,
        .on_limit = cell.on_limit,
        .on_limit_ctx = &counts,
    };
    try hard_cell.initOwnership();
    defer hard_cell.retireOwnership();
    enterIsolate(&hard_cell);
    // 250 > hard(200): permanent refusal
    try std.testing.expect(mrb_basic_alloc_func(null, 250) == null);
    try std.testing.expect(hard_cell.hardOom());
    try std.testing.expect(mrb_basic_alloc_func(null, 1) == null); // sticky
    try std.testing.expectEqual(@as(usize, 250), counts[1]);
    try std.testing.expectEqual(@as(usize, 60), cell.peak_bytes);
}

fn writeHeader(raw: [*]u8, header: AllocationHeader) void {
    const h: *AllocationHeader = @ptrCast(@alignCast(raw));
    h.* = header;
}

fn readHeader(raw: [*]u8) AllocationHeader {
    const h: *const AllocationHeader = @ptrCast(@alignCast(raw));
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
