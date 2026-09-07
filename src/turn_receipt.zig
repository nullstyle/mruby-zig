//! Owned turn-receipt encoding and borrowed, bounded framing admission.
//! This module does not execute Ruby or authenticate host outcomes. The turn
//! runner validates the embedded trace and complete terminal value graph.
const std = @import("std");
const artifact = @import("artifact.zig");

pub const Limits = struct {
    max_encoded_bytes: usize = 32 * 1024 * 1024,
    max_trace_bytes: usize = 16 * 1024 * 1024,
    max_terminal_bytes: usize = 16 * 1024 * 1024,
};

/// Borrows the encoded receipt. The terminal capsule holds the joint
/// [result, next_state] graph; preserving that single graph retains aliases.
pub const View = struct {
    trace: []const u8,
    terminal: artifact.StateCapsuleView,
};

pub const Error = std.mem.Allocator.Error || artifact.StateValidationError || error{
    InvalidTurnReceipt,
    UnsupportedTurnReceiptVersion,
    TurnReceiptLimitExceeded,
};

pub const magic = "MRZTURN\x00";
pub const format_major: u16 = 1;
pub const format_minor: u16 = 0;
pub const header_len: usize = 80;
const checksum_offset: usize = 48;
const checksum_domain = "mruby-zig/turn-receipt/v1\x00";

/// Makes one independent receipt allocation after all framing admission.
/// Trace bytes are opaque here. Terminal envelope admission requires an
/// unschematized StateCapsule; graph shape is checked by the turn runner.
pub fn encode(
    allocator: std.mem.Allocator,
    trace: []const u8,
    terminal: artifact.StateCapsuleView,
    limits: Limits,
) Error![]u8 {
    const total = try encodedLength(trace.len, terminal.bytes.len, limits);
    _ = try artifact.validateState(terminal, .{ .max_encoded_bytes = limits.max_terminal_bytes });

    const bytes = try allocator.alloc(u8, total);
    @memset(bytes[0..header_len], 0);
    @memcpy(bytes[0..magic.len], magic);
    writeInt(u16, bytes[8..10], format_major);
    writeInt(u16, bytes[10..12], format_minor);
    writeInt(u64, bytes[16..24], @intCast(total));
    writeInt(u64, bytes[24..32], @intCast(trace.len));
    writeInt(u64, bytes[32..40], @intCast(terminal.bytes.len));
    const trace_end = header_len + trace.len;
    @memcpy(bytes[header_len..trace_end], trace);
    @memcpy(bytes[trace_end..], terminal.bytes);
    const digest = checksum(bytes);
    @memcpy(bytes[checksum_offset..header_len], &digest);
    return bytes;
}

/// Pure, allocation-free admission. Rejects nonexact framing, unknown versions,
/// reserved fields and corrupt checksums before returning borrowed slices.
pub fn decode(bytes: []const u8, limits: Limits) Error!View {
    if (bytes.len > limits.max_encoded_bytes) return error.TurnReceiptLimitExceeded;
    if (bytes.len < header_len or !std.mem.eql(u8, bytes[0..magic.len], magic))
        return error.InvalidTurnReceipt;
    if (readInt(u16, bytes[8..10]) != format_major or readInt(u16, bytes[10..12]) != format_minor)
        return error.UnsupportedTurnReceiptVersion;
    if (!allZero(bytes[12..16]) or !allZero(bytes[40..48])) return error.InvalidTurnReceipt;

    const declared_total = std.math.cast(usize, readInt(u64, bytes[16..24])) orelse
        return error.TurnReceiptLimitExceeded;
    const trace_len = std.math.cast(usize, readInt(u64, bytes[24..32])) orelse
        return error.TurnReceiptLimitExceeded;
    const terminal_len = std.math.cast(usize, readInt(u64, bytes[32..40])) orelse
        return error.TurnReceiptLimitExceeded;
    const total = try encodedLength(trace_len, terminal_len, limits);
    if (declared_total != total or total != bytes.len) return error.InvalidTurnReceipt;

    const digest = checksum(bytes);
    if (!std.mem.eql(u8, bytes[checksum_offset..header_len], &digest)) return error.ChecksumMismatch;
    const terminal: artifact.StateCapsuleView = .{ .bytes = bytes[header_len + trace_len ..] };
    _ = try artifact.validateState(terminal, .{ .max_encoded_bytes = limits.max_terminal_bytes });
    return .{ .trace = bytes[header_len..][0..trace_len], .terminal = terminal };
}

fn encodedLength(trace_len: usize, terminal_len: usize, limits: Limits) Error!usize {
    if (trace_len > limits.max_trace_bytes or terminal_len > limits.max_terminal_bytes)
        return error.TurnReceiptLimitExceeded;
    const prefix = std.math.add(usize, header_len, trace_len) catch return error.TurnReceiptLimitExceeded;
    const total = std.math.add(usize, prefix, terminal_len) catch return error.TurnReceiptLimitExceeded;
    if (total > limits.max_encoded_bytes) return error.TurnReceiptLimitExceeded;
    return total;
}

fn checksum(bytes: []const u8) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(checksum_domain);
    hash.update(bytes[0..checksum_offset]);
    hash.update(bytes[header_len..]);
    return hash.finalResult();
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn readInt(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .big);
}

fn writeInt(comptime T: type, bytes: []u8, value: T) void {
    std.mem.writeInt(T, bytes[0..@sizeOf(T)], value, .big);
}

fn fixture() !artifact.StateCapsule {
    // The framing layer deliberately leaves full graph admission to its caller.
    return artifact.wrapState(std.testing.allocator, "terminal graph", .{});
}

test "receipt owns bytes and exposes exact borrowed payloads" {
    const a = std.testing.allocator;
    var terminal = try fixture();
    defer terminal.deinit(a);
    var trace = "effect trace".*;
    const bytes = try encode(a, &trace, terminal.view(), .{});
    defer a.free(bytes);
    @memset(&trace, 'x');
    @memset(terminal.encoded, 0);
    const decoded = try decode(bytes, .{});
    try std.testing.expectEqualStrings("effect trace", decoded.trace);
    try std.testing.expectEqual(@intFromPtr(bytes.ptr) + header_len, @intFromPtr(decoded.trace.ptr));
    try std.testing.expectEqual(@intFromPtr(bytes.ptr) + header_len + trace.len, @intFromPtr(decoded.terminal.bytes.ptr));
    try std.testing.expectEqualStrings("terminal graph", (try artifact.validateState(decoded.terminal, .{})).bytes);
    const roundtrip = try encode(a, decoded.trace, decoded.terminal, .{});
    defer a.free(roundtrip);
    try std.testing.expectEqualSlices(u8, bytes, roundtrip);
}

test "receipt rejects every truncation and extra trailing bytes" {
    const a = std.testing.allocator;
    var terminal = try fixture();
    defer terminal.deinit(a);
    const bytes = try encode(a, "trace", terminal.view(), .{});
    defer a.free(bytes);
    for (0..bytes.len) |length|
        try std.testing.expectError(error.InvalidTurnReceipt, decode(bytes[0..length], .{}));
    const trailing = try a.alloc(u8, bytes.len + 1);
    defer a.free(trailing);
    @memcpy(trailing[0..bytes.len], bytes);
    trailing[bytes.len] = 0;
    try std.testing.expectError(error.InvalidTurnReceipt, decode(trailing, .{}));
}

test "receipt rejects version and reserved fields even with fresh checksum" {
    const a = std.testing.allocator;
    var terminal = try fixture();
    defer terminal.deinit(a);
    const bytes = try encode(a, "trace", terminal.view(), .{});
    defer a.free(bytes);
    const Case = struct { offset: usize, expected: anyerror };
    for ([_]Case{
        .{ .offset = 0, .expected = error.InvalidTurnReceipt },
        .{ .offset = 9, .expected = error.UnsupportedTurnReceiptVersion },
        .{ .offset = 11, .expected = error.UnsupportedTurnReceiptVersion },
        .{ .offset = 12, .expected = error.InvalidTurnReceipt },
        .{ .offset = 15, .expected = error.InvalidTurnReceipt },
        .{ .offset = 40, .expected = error.InvalidTurnReceipt },
        .{ .offset = 47, .expected = error.InvalidTurnReceipt },
    }) |case| {
        const changed = try a.dupe(u8, bytes);
        defer a.free(changed);
        changed[case.offset] ^= 1;
        const digest = checksum(changed);
        @memcpy(changed[checksum_offset..header_len], &digest);
        try std.testing.expectError(case.expected, decode(changed, .{}));
    }
}

test "receipt detects payload corruption and validates the nested state envelope" {
    const a = std.testing.allocator;
    var terminal = try fixture();
    defer terminal.deinit(a);
    const bytes = try encode(a, "trace", terminal.view(), .{});
    defer a.free(bytes);
    bytes[header_len] ^= 1;
    try std.testing.expectError(error.ChecksumMismatch, decode(bytes, .{}));
    bytes[header_len] ^= 1;
    bytes[bytes.len - 1] ^= 1;
    try std.testing.expectError(error.ChecksumMismatch, decode(bytes, .{}));
    const digest = checksum(bytes);
    @memcpy(bytes[checksum_offset..header_len], &digest);
    try std.testing.expectError(error.ChecksumMismatch, decode(bytes, .{}));

    terminal.encoded[0] ^= 1;
    try std.testing.expectError(error.InvalidArtifact, encode(a, "trace", terminal.view(), .{}));
}

test "receipt limits and overflow reject before allocation" {
    const a = std.testing.allocator;
    var terminal = try fixture();
    defer terminal.deinit(a);
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    const total = header_len + 5 + terminal.encoded.len;
    for ([_]Limits{
        .{ .max_encoded_bytes = total - 1 },
        .{ .max_trace_bytes = 4 },
        .{ .max_terminal_bytes = terminal.encoded.len - 1 },
    }) |limits|
        try std.testing.expectError(error.TurnReceiptLimitExceeded, encode(failing.allocator(), "trace", terminal.view(), limits));
    try std.testing.expectEqual(@as(usize, 0), failing.alloc_index);

    const bytes = try encode(a, "trace", terminal.view(), .{});
    defer a.free(bytes);
    try std.testing.expectError(error.TurnReceiptLimitExceeded, decode(bytes, .{ .max_encoded_bytes = total - 1 }));
    try std.testing.expectError(error.TurnReceiptLimitExceeded, decode(bytes, .{ .max_trace_bytes = 4 }));
    try std.testing.expectError(error.TurnReceiptLimitExceeded, decode(bytes, .{ .max_terminal_bytes = terminal.encoded.len - 1 }));
    writeInt(u64, bytes[24..32], std.math.maxInt(u64));
    try std.testing.expectError(error.TurnReceiptLimitExceeded, decode(bytes, .{
        .max_encoded_bytes = std.math.maxInt(usize),
        .max_trace_bytes = std.math.maxInt(usize),
        .max_terminal_bytes = std.math.maxInt(usize),
    }));
}

test "receipt re-encoding can bind replacement opaque trace and terminal payloads" {
    const a = std.testing.allocator;
    var terminal = try fixture();
    defer terminal.deinit(a);
    var changed_terminal = try artifact.wrapState(a, "different terminal graph", .{});
    defer changed_terminal.deinit(a);
    const original = try encode(a, "trace A", terminal.view(), .{});
    defer a.free(original);
    const changed = try encode(a, "trace B", changed_terminal.view(), .{});
    defer a.free(changed);
    try std.testing.expect(!std.mem.eql(u8, original, changed));
    const decoded = try decode(changed, .{});
    try std.testing.expectEqualStrings("trace B", decoded.trace);
    try std.testing.expectEqualStrings("different terminal graph", (try artifact.validateState(decoded.terminal, .{})).bytes);
    // These well-framed substitutions still need trace/graph/terminal replay
    // validation by the runner. A checksum is not an authenticity proof.
}
