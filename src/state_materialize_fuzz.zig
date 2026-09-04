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

/// One shared isolate across invocations for throughput; recreated once its
/// memory ceiling goes sticky (valid capsules genuinely allocate) or any
/// policy termination is noted.
var iso: ?mruby.sandbox.Isolate = null;

fn freshIsolate() !mruby.sandbox.Isolate {
    if (iso) |live| live.deinit();
    var boot = try mruby.sandbox.BootstrapIsolate.spawn(.{ .limits = .{
        .memory_bytes = 16 * 1024 * 1024,
    } });
    defer boot.deinit();
    const sealed = try boot.seal();
    iso = sealed;
    return sealed;
}

test "fuzz StateCapsule materialization through a live isolate" {
    const sealed = try freshIsolate();
    defer sealed.deinit();
    _ = iso; // the callback uses its own isolates; keep the corpus run hermetic
    try std.testing.fuzz({}, fuzzOne, .{ .corpus = corpus.seeds });
}

fn fuzzOne(_: void, smith: *std.testing.Smith) !void {
    var input_buffer: [max_input_bytes]u8 = undefined;
    const input_len: usize = @intCast(smith.slice(&input_buffer));
    const input = input_buffer[0..input_len];

    try exercise(input);

    // Reframe as a checksummed payload so mutations reach the graph
    // admission and C materialization instead of stopping at SHA-256.
    var framed = try artifact.wrapState(std.testing.allocator, input, .{
        .max_encoded_bytes = limits.max_encoded_bytes,
    });
    defer framed.deinit(std.testing.allocator);
    try exercise(framed.encoded);
}

fn exercise(bytes: []const u8) !void {
    if (iso == null) _ = try freshIsolate();
    _ = iso.?.importValue(.{ .bytes = bytes }, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.MemoryLimitExceeded => {
            // The ceiling went sticky; a fresh isolate continues the run.
            _ = try freshIsolate();
        },
        else => {},
    };
}
