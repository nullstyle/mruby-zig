//! Coverage-guided fuzz target for the inert StateCapsule parser.
//!
//! Each input is attempted both as an untrusted complete envelope and as an
//! arbitrary graph payload inside a freshly checksummed envelope. The latter
//! prevents SHA-256 validation from becoming a coverage wall in front of the
//! node/reference parser. No mruby state is created and no guest code runs.

const std = @import("std");
const mruby = @import("mruby");
const artifact = mruby.artifact;
const codec = mruby.internal_test.artifact_value;
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

test "fuzz StateCapsule framing and graph parser" {
    // Link the repository's existing C objects because artifact_value.zig's
    // compile-coverage test references its VM-facing half. The fuzz callback
    // itself remains parser-only and never creates or calls an mruby state.
    _ = mruby;
    _ = mruby.alloc;
    try std.testing.fuzz({}, fuzzOne, .{ .corpus = corpus.seeds });
}

test "golden subprocess StateCapsule is canonical parser input" {
    var failure: codec.Failure = .{};
    var graph = try codec.parse(
        std.testing.allocator,
        .{ .bytes = &corpus.process_fixture_capsule },
        .{ .limits = limits, .accepted_schema = corpus.schema },
        &failure,
    );
    defer graph.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 6), graph.nodes.len);
    try std.testing.expectEqual(@as(usize, 13), graph.edges.len);
    try std.testing.expect(corpus.schema.accepts(graph.schema.?));
}

fn fuzzOne(_: void, smith: *std.testing.Smith) !void {
    var input_buffer: [max_input_bytes]u8 = undefined;
    const input_len: usize = @intCast(smith.slice(&input_buffer));
    const input = input_buffer[0..input_len];

    // Raw bytes exercise the common envelope, checksum, reserved fields,
    // kind flags, schema metadata, and complete graph parser when valid.
    try exercise(input, null);
    try exercise(input, corpus.schema);

    // Reframe the same bytes as a payload so every mutation can reach the
    // graph parser instead of almost all mutations stopping at SHA-256.
    var framed = try artifact.wrapState(std.testing.allocator, input, .{
        .max_encoded_bytes = limits.max_encoded_bytes,
    });
    defer framed.deinit(std.testing.allocator);
    try exercise(framed.encoded, null);
}

fn exercise(encoded: []const u8, accepted_schema: ?artifact.Schema) !void {
    try exerciseWithPolicy(encoded, accepted_schema, true);
    try exerciseWithPolicy(encoded, accepted_schema, false);
}

fn exerciseWithPolicy(encoded: []const u8, accepted_schema: ?artifact.Schema, allow_float: bool) !void {
    var failure: codec.Failure = .{};
    var graph = codec.parse(
        std.testing.allocator,
        .{ .bytes = encoded },
        .{ .limits = limits, .accepted_schema = accepted_schema, .allow_float = allow_float },
        &failure,
    ) catch |err| switch (err) {
        error.InvalidArtifact,
        error.ChecksumMismatch,
        error.UnsupportedArtifactVersion,
        error.ArtifactLimitExceeded,
        error.SchemaMismatch,
        error.CapsuleLimitExceeded,
        => return,
        error.NumericPolicyViolation => {
            try std.testing.expect(!allow_float);
            return;
        },
        error.OutOfMemory => return err,
    };
    defer graph.deinit(std.testing.allocator);

    try std.testing.expect(graph.nodes.len <= limits.max_nodes);
    try std.testing.expect(graph.edges.len <= limits.max_total_edges);
    if (!allow_float) {
        try std.testing.expect(graph.root.tag != mruby.c.MRZ_ARTIFACT_REF_F64);
        for (graph.edges) |edge| try std.testing.expect(edge.tag != mruby.c.MRZ_ARTIFACT_REF_F64);
    }
    if (graph.schema) |produced| {
        const accepted = accepted_schema orelse return error.UnexpectedSchemaAdmission;
        try std.testing.expect(accepted.accepts(produced));
    } else {
        try std.testing.expect(accepted_schema == null);
    }
}
