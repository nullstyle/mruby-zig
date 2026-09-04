//! Coverage-guided fuzz target for the C materialization boundary.
//!
//! Where `state_capsule_fuzz.zig` stops at the pure (inert) parser, this
//! target pushes every input through `Isolate.importValue` — envelope
//! validation, graph admission, and the C-side construction of live mruby
//! objects — inside a real isolate under a memory ceiling. No guest code
//! executes: capsule import is inert by design, and the fuzzer's job is to
//! disprove that through exploration (security review 2026-09, finding 1).

const std = @import("std");
const mruby = @import("mruby");
const artifact = mruby.artifact;
const corpus = @import("state_capsule_fuzz_corpus.zig");

const max_input_bytes = 64 * 1024;
const limits: artifact.CapsuleLimits = .{
    .max_encoded_bytes = max_input_bytes + artifact.envelope_header_len,
    .max_nodes = 1024,
    .max_total_edges = 4096,
    .max_depth = 64,
    .max_string_bytes = max_input_bytes,
    .max_symbol_bytes = max_input_bytes,
};

/// One owner follows the current isolate through every recovery. Destruction
/// clears the slot first, so failed replacement and repeated teardown are safe.
const Harness = struct {
    current: ?mruby.sandbox.Isolate = null,
    policy: mruby.sandbox.Policy = .{ .limits = .{ .memory_bytes = 16 * 1024 * 1024 } },
    capsule_limits: artifact.CapsuleLimits = limits,
    generations: usize = 0,

    const Outcome = union(enum) {
        imported,
        rejected: mruby.sandbox.ImportValueError,
        replaced,
    };

    fn deinit(self: *Harness) void {
        const previous = self.current;
        self.current = null;
        if (previous) |live| live.deinit();
    }

    fn replace(self: *Harness) !void {
        self.deinit();
        var boot = try mruby.sandbox.BootstrapIsolate.spawn(self.policy);
        defer boot.deinit();
        self.current = try boot.seal();
        self.generations += 1;
    }

    fn exercise(self: *Harness, bytes: []const u8, accepted_schema: ?artifact.Schema) !Outcome {
        if (self.current == null) try self.replace();
        const live = self.current.?;
        if (live.stats().instructions != 0) return error.UnexpectedGuestExecution;
        const imported = blk: {
            // Import intentionally leaves a root for its caller. This harness
            // discards results; restore before any recovery destroys the VM.
            const scope = live.arenaScope();
            defer scope.restore();
            const result = live.importValue(.{ .bytes = bytes }, .{
                .limits = self.capsule_limits,
                .accepted_schema = accepted_schema,
            });
            if (live.stats().instructions != 0) return error.UnexpectedGuestExecution;
            break :blk result;
        };
        _ = imported catch |err| switch (err) {
            error.InvalidArtifact,
            error.ChecksumMismatch,
            error.UnsupportedArtifactVersion,
            error.ArtifactLimitExceeded,
            error.SchemaMismatch,
            error.CapsuleLimitExceeded,
            => return .{ .rejected = err },
            error.MemoryLimitExceeded => {
                try self.replace();
                return .replaced;
            },
            // Construction divergence, lifecycle misuse, and host OOM are
            // findings, not normal malformed-input rejections.
            else => return err,
        };
        if (live.pendingTermination()) return error.UnexpectedPolicyTermination;
        return .imported;
    }
};

test "fuzz StateCapsule materialization through a live isolate" {
    var harness: Harness = .{};
    defer harness.deinit();
    try std.testing.fuzz(&harness, fuzzOne, .{ .corpus = corpus.seeds });
}

fn fuzzOne(harness: *Harness, smith: *std.testing.Smith) !void {
    var input_buffer: [max_input_bytes]u8 = undefined;
    const input_len: usize = @intCast(smith.slice(&input_buffer));
    const input = input_buffer[0..input_len];

    _ = try harness.exercise(input, null);
    _ = try harness.exercise(input, corpus.schema);

    // Reframe as a checksummed payload so mutations reach graph admission
    // and C materialization instead of stopping at SHA-256.
    var framed = try artifact.wrapState(std.testing.allocator, input, .{
        .max_encoded_bytes = limits.max_encoded_bytes,
    });
    defer framed.deinit(std.testing.allocator);
    _ = try harness.exercise(framed.encoded, null);
}

test "materialization harness: failed replacement clears the owned isolate" {
    const before = mruby.alloc.liveAllocs();
    var harness: Harness = .{};
    defer harness.deinit();
    try harness.replace();
    const previous = mruby.alloc.gpa;
    var failing = std.testing.FailingAllocator.init(previous, .{ .fail_index = 0 });
    const result = blk: {
        mruby.alloc.gpa = failing.allocator();
        defer mruby.alloc.gpa = previous;
        break :blk harness.replace();
    };
    try std.testing.expectError(error.OutOfMemory, result);
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expect(harness.current == null);
    try std.testing.expectEqual(before, mruby.alloc.liveAllocs());
    try std.testing.expectEqual(Harness.Outcome.imported, try harness.exercise(&corpus.scalar_capsule, null));
    harness.deinit();
    try std.testing.expectEqual(before, mruby.alloc.liveAllocs());
}

test "materialization harness: declared edge limit reaches import" {
    var harness: Harness = .{};
    defer harness.deinit();
    for ([_]usize{ limits.max_total_edges, limits.max_total_edges + 1 }) |edges| {
        var capsule = try arrayCapsule(edges);
        defer capsule.deinit(std.testing.allocator);
        const result = try harness.exercise(capsule.encoded, null);
        if (edges == limits.max_total_edges) {
            try std.testing.expectEqual(Harness.Outcome.imported, result);
        } else {
            try std.testing.expectEqual(error.CapsuleLimitExceeded, result.rejected);
            try std.testing.expectEqual(.limit_exceeded, harness.current.?.lastArtifactError().?.kind);
        }
    }
}

test "materialization harness: every configured capsule ceiling is enforced" {
    var harness: Harness = .{};
    defer harness.deinit();
    const golden = &corpus.process_fixture_capsule;
    try std.testing.expectEqual(Harness.Outcome.imported, try harness.exercise(golden, corpus.schema));
    inline for (.{ "max_encoded_bytes", "max_nodes", "max_total_edges", "max_depth", "max_string_bytes", "max_symbol_bytes" }) |field| {
        harness.capsule_limits = limits;
        @field(harness.capsule_limits, field) = 0;
        const result = try harness.exercise(golden, corpus.schema);
        const expected = if (std.mem.eql(u8, field, "max_encoded_bytes"))
            error.ArtifactLimitExceeded
        else
            error.CapsuleLimitExceeded;
        try std.testing.expectEqual(expected, result.rejected);
    }
    harness.capsule_limits = limits;
    try std.testing.expectEqual(Harness.Outcome.imported, try harness.exercise(golden, corpus.schema));
}

test "materialization harness: valid schema and schema-free seeds reach C" {
    var harness: Harness = .{};
    defer harness.deinit();
    try std.testing.expectEqual(Harness.Outcome.imported, try harness.exercise(&corpus.scalar_capsule, null));
    try std.testing.expectEqual(Harness.Outcome.imported, try harness.exercise(&corpus.cycle_alias_capsule, null));
    try std.testing.expectEqual(Harness.Outcome.imported, try harness.exercise(&corpus.hash_schema_capsule, corpus.schema));
    try std.testing.expectEqual(Harness.Outcome.imported, try harness.exercise(&corpus.process_fixture_capsule, corpus.schema));
    try std.testing.expectEqual(error.SchemaMismatch, (try harness.exercise(&corpus.process_fixture_capsule, null)).rejected);
    try std.testing.expectEqual(error.InvalidArtifact, (try harness.exercise(&.{}, null)).rejected);
    try std.testing.expectEqual(@as(u64, 0), harness.current.?.stats().instructions);
}

test "materialization harness: two memory recoveries retain one owner and resume import" {
    const previous = mruby.alloc.gpa;
    // All allocations created by this test have one tracked backing allocator,
    // including the IsolateState itself as well as the mruby heap.
    mruby.alloc.gpa = std.testing.allocator;
    defer mruby.alloc.gpa = previous;
    const before = mruby.alloc.liveAllocs();
    var harness: Harness = .{ .policy = mruby.sandbox.Policy.trusted(.{ .limits = .{ .memory_bytes = 1 } }) };
    defer harness.deinit();
    // Small arrays can fit mruby's inline storage and reuse preallocated GC
    // slots. An external array buffer must hit the real allocator ceiling.
    var allocating = try arrayCapsule(limits.max_total_edges);
    defer allocating.deinit(std.testing.allocator);
    for (0..2) |_| {
        try std.testing.expectEqual(Harness.Outcome.replaced, try harness.exercise(allocating.encoded, null));
        try std.testing.expectEqual(Harness.Outcome.imported, try harness.exercise(&corpus.scalar_capsule, null));
    }
    try std.testing.expectEqual(@as(usize, 3), harness.generations);
    harness.deinit();
    try std.testing.expect(harness.current == null);
    try std.testing.expectEqual(before, mruby.alloc.liveAllocs());
}

test "materialization harness: discarded graph roots and heap usage stabilize" {
    var harness: Harness = .{};
    defer harness.deinit();
    try harness.replace();
    const arena_before = harness.current.?.arenaScope().idx;
    var warmed_bytes: ?usize = null;
    for (0..4) |_| {
        for (0..256) |_| {
            try std.testing.expectEqual(Harness.Outcome.imported, try harness.exercise(&corpus.process_fixture_capsule, corpus.schema));
            try std.testing.expectEqual(arena_before, harness.current.?.arenaScope().idx);
        }
        collect(harness.current.?);
        const current_bytes = harness.current.?.stats().live_memory_bytes;
        if (warmed_bytes) |expected| try std.testing.expectEqual(expected, current_bytes) else warmed_bytes = current_bytes;
    }
    try std.testing.expectEqual(@as(usize, 1), harness.generations);
}

test "materialization harness: lifecycle failures are not malformed input" {
    var harness: Harness = .{};
    defer harness.deinit();
    try harness.replace();
    const live = harness.current.?;
    try std.testing.expect(live.internal.operation_lock.tryLock());
    defer live.internal.operation_lock.unlock();
    try std.testing.expectError(error.IsolateThreadBusy, harness.exercise(&corpus.scalar_capsule, null));
}

fn collect(live: mruby.sandbox.Isolate) void {
    const attribution = mruby.alloc.pushIsolate(&live.internal.cell);
    defer mruby.alloc.restoreIsolate(attribution);
    mruby.c.mrb_full_gc(mruby.sandbox.internalVm(live).mrb);
}

fn arrayCapsule(edges: usize) !artifact.StateCapsule {
    const payload = try std.testing.allocator.alloc(u8, 29 + edges);
    defer std.testing.allocator.free(payload);
    var writer = artifact.Writer.init(payload);
    try artifact.writeStatePrelude(&writer, .{
        .node_count = 1,
        .edge_count = @intCast(edges),
        .root = .{ .node_ref = 0 },
    });
    try artifact.writeNodeRecordHeader(&writer, .{
        .id = 0,
        .kind = .array,
        .flags = 0,
        .body_len = @intCast(4 + edges),
    });
    try writer.writeU32(@intCast(edges));
    for (0..edges) |_| try artifact.writeValueRef(&writer, .{ .nil = {} });
    try writer.finish();
    return artifact.wrapState(std.testing.allocator, payload, .{});
}
