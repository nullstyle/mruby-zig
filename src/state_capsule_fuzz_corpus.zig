//! Stable structured seeds for the pure StateCapsule parser fuzzer.
//!
//! Seeds include both payloads (which the harness places in a fresh valid
//! envelope so checksum gating cannot hide graph-parser coverage) and complete
//! envelopes (which exercise framing, checksums, flags, and schema admission).

const artifact = @import("mruby").artifact;

pub const schema: artifact.Schema = .{
    .id = .{
        'p', 'r', 'o', 'c', 'e', 's', 's', '-',
        'f', 'i', 'x', 't', 'u', 'r', 'e', '1',
    },
    .major = 1,
    .minor = 0,
};

pub const scalar_payload = makeScalarPayload();
pub const cycle_alias_payload = makeCycleAliasPayload();
pub const hash_payload = makeHashPayload();
pub const duplicate_zero_key_payload = makeDuplicateZeroKeyPayload();
pub const excessive_counts_payload = makeExcessiveCountsPayload();

pub const scalar_capsule = frame(&scalar_payload, null);
pub const cycle_alias_capsule = frame(&cycle_alias_payload, null);
pub const hash_schema_capsule = frame(&hash_payload, schema);
pub const duplicate_zero_key_capsule = frame(&duplicate_zero_key_payload, null);
pub const excessive_counts_capsule = frame(&excessive_counts_payload, null);

// Exact subprocess fixture bytes, committed independently of the framing
// helper above. This is the macOS/Linux and standard/minimal stability canary.
const process_fixture_hex =
    "4d525a4152544600000100000201008000000000000000d170726f636573732d6669787475726531000100000000000000000000000000000000000000000000" ++
    "000000000000000000000000000000000000000000000000f0a6fbc6755dfe03863597d1105e2fa4d2e977afd4e80cd10a410ec4f12f3ab50000000000000000" ++
    "000000060000000d0600000000000000000201000000000013000000030600000001060000000206000000030000000103030000000000460000000405000000" ++
    "056669727374060000000205000000067365636f6e6406000000020500000005657175616c060000000305000000056379636c65060000000406000000050000" ++
    "00020101000000000007000000036100620000000301010000000000070000000361006200000004020000000000000900000001060000000400000005010100" ++
    "000000000c0000000866616c6c6261636b";
pub const process_fixture_capsule = decodeHex(process_fixture_hex);

const empty_seed = smithSeed(&.{});
const scalar_payload_seed = smithSeed(&scalar_payload);
const cycle_alias_payload_seed = smithSeed(&cycle_alias_payload);
const hash_payload_seed = smithSeed(&hash_payload);
const duplicate_payload_seed = smithSeed(&duplicate_zero_key_payload);
const excessive_counts_payload_seed = smithSeed(&excessive_counts_payload);
const scalar_capsule_seed = smithSeed(&scalar_capsule);
const cycle_alias_capsule_seed = smithSeed(&cycle_alias_capsule);
const hash_schema_capsule_seed = smithSeed(&hash_schema_capsule);
const duplicate_capsule_seed = smithSeed(&duplicate_zero_key_capsule);
const excessive_counts_capsule_seed = smithSeed(&excessive_counts_capsule);
const process_fixture_capsule_seed = smithSeed(&process_fixture_capsule);

/// `std.testing.Smith.slice` consumes a little-endian u32 length before the
/// slice bytes, so each logical corpus entry is wrapped in that stable form.
pub const seeds: []const []const u8 = &.{
    &empty_seed,
    &scalar_payload_seed,
    &cycle_alias_payload_seed,
    &hash_payload_seed,
    &duplicate_payload_seed,
    &excessive_counts_payload_seed,
    &scalar_capsule_seed,
    &cycle_alias_capsule_seed,
    &hash_schema_capsule_seed,
    &duplicate_capsule_seed,
    &excessive_counts_capsule_seed,
    &process_fixture_capsule_seed,
};

fn makeScalarPayload() [17]u8 {
    var bytes: [17]u8 = undefined;
    var writer = artifact.Writer.init(&bytes);
    artifact.writeStatePrelude(&writer, .{
        .node_count = 0,
        .edge_count = 0,
        .root = .{ .integer = -42 },
    }) catch unreachable;
    writer.finish() catch unreachable;
    return bytes;
}

fn makeCycleAliasPayload() [60]u8 {
    var bytes: [60]u8 = undefined;
    var writer = artifact.Writer.init(&bytes);
    artifact.writeStatePrelude(&writer, .{
        .node_count = 2,
        .edge_count = 3,
        .root = .{ .node_ref = 0 },
    }) catch unreachable;
    artifact.writeNodeRecordHeader(&writer, .{
        .id = 0,
        .kind = .array,
        .flags = artifact.flags.frozen,
        .body_len = 14,
    }) catch unreachable;
    writer.writeU32(2) catch unreachable;
    artifact.writeValueRef(&writer, .{ .node_ref = 1 }) catch unreachable;
    artifact.writeValueRef(&writer, .{ .node_ref = 1 }) catch unreachable;
    artifact.writeNodeRecordHeader(&writer, .{
        .id = 1,
        .kind = .array,
        .flags = 0,
        .body_len = 9,
    }) catch unreachable;
    writer.writeU32(1) catch unreachable;
    artifact.writeValueRef(&writer, .{ .node_ref = 1 }) catch unreachable;
    writer.finish() catch unreachable;
    return bytes;
}

fn makeHashPayload() [98]u8 {
    var bytes: [98]u8 = undefined;
    var writer = artifact.Writer.init(&bytes);
    artifact.writeStatePrelude(&writer, .{
        .node_count = 2,
        .edge_count = 9,
        .root = .{ .node_ref = 0 },
    }) catch unreachable;
    artifact.writeNodeRecordHeader(&writer, .{
        .id = 0,
        .kind = .hash,
        .flags = artifact.flags.frozen | artifact.flags.hash_has_default,
        .body_len = 53,
    }) catch unreachable;
    writer.writeU32(4) catch unreachable;
    artifact.writeValueRef(&writer, .{ .integer = -1 }) catch unreachable;
    artifact.writeValueRef(&writer, .{ .nil = {} }) catch unreachable;
    artifact.writeValueRef(&writer, .{ .float = 0x7ff8_1234_5678_9abc }) catch unreachable;
    artifact.writeValueRef(&writer, .{ .boolean_false = {} }) catch unreachable;
    artifact.writeValueRef(&writer, .{ .symbol = &.{ 's', 'y', 'm', 0 } }) catch unreachable;
    artifact.writeValueRef(&writer, .{ .boolean_true = {} }) catch unreachable;
    artifact.writeValueRef(&writer, .{ .node_ref = 1 }) catch unreachable;
    artifact.writeValueRef(&writer, .{ .float = 0x8000_0000_0000_0000 }) catch unreachable;
    artifact.writeValueRef(&writer, .{ .node_ref = 1 }) catch unreachable;
    artifact.writeNodeRecordHeader(&writer, .{
        .id = 1,
        .kind = .string,
        .flags = artifact.flags.frozen,
        .body_len = 8,
    }) catch unreachable;
    writer.writeU32(4) catch unreachable;
    writer.writeBytes(&.{ 'k', 'e', 'y', 0 }) catch unreachable;
    writer.finish() catch unreachable;
    return bytes;
}

fn makeDuplicateZeroKeyPayload() [49]u8 {
    var bytes: [49]u8 = undefined;
    var writer = artifact.Writer.init(&bytes);
    artifact.writeStatePrelude(&writer, .{
        .node_count = 1,
        .edge_count = 4,
        .root = .{ .node_ref = 0 },
    }) catch unreachable;
    artifact.writeNodeRecordHeader(&writer, .{
        .id = 0,
        .kind = .hash,
        .flags = 0,
        .body_len = 24,
    }) catch unreachable;
    writer.writeU32(2) catch unreachable;
    artifact.writeValueRef(&writer, .{ .float = 0x0000_0000_0000_0000 }) catch unreachable;
    artifact.writeValueRef(&writer, .{ .nil = {} }) catch unreachable;
    artifact.writeValueRef(&writer, .{ .float = 0x8000_0000_0000_0000 }) catch unreachable;
    artifact.writeValueRef(&writer, .{ .nil = {} }) catch unreachable;
    writer.finish() catch unreachable;
    return bytes;
}

fn makeExcessiveCountsPayload() [9]u8 {
    var bytes: [9]u8 = undefined;
    var writer = artifact.Writer.init(&bytes);
    artifact.writeStatePrelude(&writer, .{
        .node_count = std.math.maxInt(u32),
        .edge_count = std.math.maxInt(u32),
        .root = .{ .nil = {} },
    }) catch unreachable;
    writer.finish() catch unreachable;
    return bytes;
}

fn frame(
    comptime payload: []const u8,
    comptime producer_schema: ?artifact.Schema,
) [artifact.envelope_header_len + payload.len]u8 {
    @setEvalBranchQuota(100_000);
    var bytes: [artifact.envelope_header_len + payload.len]u8 = undefined;
    var metadata: [artifact.metadata_len]u8 = @splat(0);
    const envelope_flags: u8 = if (producer_schema) |value| flags: {
        @memcpy(metadata[0..16], &value.id);
        putU16(metadata[16..18], value.major);
        putU16(metadata[18..20], value.minor);
        break :flags artifact.flags.schema;
    } else 0;
    artifact.encodeEnvelopeInto(
        &bytes,
        .state_capsule,
        envelope_flags,
        metadata,
        payload,
    ) catch unreachable;
    return bytes;
}

fn smithSeed(comptime bytes: []const u8) [4 + bytes.len]u8 {
    var seed: [4 + bytes.len]u8 = undefined;
    seed[0] = @truncate(bytes.len);
    seed[1] = @truncate(bytes.len >> 8);
    seed[2] = @truncate(bytes.len >> 16);
    seed[3] = @truncate(bytes.len >> 24);
    @memcpy(seed[4..], bytes);
    return seed;
}

fn putU16(bytes: []u8, value: u16) void {
    bytes[0] = @truncate(value >> 8);
    bytes[1] = @truncate(value);
}

fn decodeHex(comptime hex: []const u8) [hex.len / 2]u8 {
    @setEvalBranchQuota(10_000);
    var bytes: [hex.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, hex) catch unreachable;
    return bytes;
}

const std = @import("std");
