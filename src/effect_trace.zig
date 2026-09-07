//! Owned transcripts for host-handled effects. Payloads are opaque, inert
//! encodings: this module never retains VM values or invokes live handlers.
//!
//! Reserve a complete record before performing an effect, then commit its
//! result without allocating. Any failed mutation makes the trace permanently
//! incomplete, so a rescued runtime error cannot produce a replayable prefix.
const std = @import("std");

pub const Identity = struct {
    code: [32]u8,
    catalogue: [32]u8,
    input: [32]u8,

    pub fn eql(self: Identity, other: Identity) bool {
        return std.mem.eql(u8, &self.code, &other.code) and
            std.mem.eql(u8, &self.catalogue, &other.catalogue) and
            std.mem.eql(u8, &self.input, &other.input);
    }
};

pub const Limits = struct {
    max_records: usize = 1024,
    /// Includes framing, names, arguments, and reserved result capacity.
    max_bytes: usize = 16 * 1024 * 1024,
    /// Bounds each argument encoding and each operation name independently.
    max_request_bytes: usize = 1024 * 1024,
    max_result_bytes: usize = 1024 * 1024,
};

pub const Error = std.mem.Allocator.Error || error{
    InvalidTrace,
    IncompleteTrace,
    TraceLimitExceeded,
    ChecksumMismatch,
    UnsupportedTraceVersion,
};

/// Borrowed from its owning trace, valid until that trace is deinitialized.
pub const Outcome = enum(u8) { returned = 0, rejected = 1 };

pub const Record = struct {
    name: []const u8,
    version: u32,
    arguments: []const u8,
    result: []const u8,
    outcome: Outcome = .returned,
};

pub const format_major: u16 = 1;
pub const format_minor: u16 = 1;
pub const header_len: usize = 160;
pub const record_header_len: usize = 32;
const legacy_record_header_len: usize = 24;
pub const magic = "MRZEFCT\x00";
const checksum_offset = 128;
const checksum_domain = "mruby-zig/effect-trace/v1\x00";

const OwnedRecord = struct {
    name: []u8,
    version: u32,
    arguments: []u8,
    result_storage: []u8,
    result_len: usize = 0,
    outcome: Outcome = .returned,

    fn view(self: OwnedRecord) Record {
        return .{
            .name = self.name,
            .version = self.version,
            .arguments = self.arguments,
            .result = self.result_storage[0..self.result_len],
            .outcome = self.outcome,
        };
    }

    fn deinit(self: OwnedRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.arguments);
        allocator.free(self.result_storage);
    }
};

pub const Trace = struct {
    allocator: std.mem.Allocator,
    identity: Identity,
    limits: Limits,
    /// Decoded 1.0 traces retain their return-only framing on re-encoding.
    wire_minor: u16 = format_minor,
    entries: std.ArrayList(OwnedRecord) = .empty,
    reserved_bytes: usize = header_len,
    pending: bool = false,
    invalidated: bool = false,
    complete: bool = false,

    pub fn init(allocator: std.mem.Allocator, identity: Identity, limits: Limits) Trace {
        return .{ .allocator = allocator, .identity = identity, .limits = limits };
    }

    pub fn deinit(self: *Trace) void {
        for (self.entries.items) |entry| entry.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn len(self: *const Trace) usize {
        return self.entries.items.len - @intFromBool(self.pending);
    }

    pub fn get(self: *const Trace, index: usize) ?Record {
        if (index >= self.len()) return null;
        return self.entries.items[index].view();
    }

    pub fn isComplete(self: *const Trace) bool {
        return self.complete and !self.invalidated and !self.pending;
    }

    /// All memory required to commit this record is allocated here, before the
    /// caller performs the effect. Result capacity remains charged after commit.
    pub fn reserve(
        self: *Trace,
        name: []const u8,
        version: u32,
        arguments: []const u8,
        max_result_bytes: usize,
    ) Error!void {
        errdefer self.invalidate();
        if (self.invalidated) return error.IncompleteTrace;
        if (self.pending or self.complete or name.len == 0) return error.InvalidTrace;
        if (self.entries.items.len >= self.limits.max_records or
            name.len > std.math.maxInt(u32) or
            name.len > self.limits.max_request_bytes or
            arguments.len > self.limits.max_request_bytes or
            max_result_bytes > self.limits.max_result_bytes)
        {
            return error.TraceLimitExceeded;
        }
        var added = try addLength(frameLength(self.wire_minor), name.len);
        added = try addLength(added, arguments.len);
        added = try addLength(added, max_result_bytes);
        const reserved = try addLength(self.reserved_bytes, added);
        if (reserved > self.limits.max_bytes) return error.TraceLimitExceeded;

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_arguments = try self.allocator.dupe(u8, arguments);
        errdefer self.allocator.free(owned_arguments);
        const result_storage = try self.allocator.alloc(u8, max_result_bytes);
        errdefer self.allocator.free(result_storage);
        try self.entries.ensureUnusedCapacity(self.allocator, 1);
        self.entries.appendAssumeCapacity(.{
            .name = owned_name,
            .version = version,
            .arguments = owned_arguments,
            .result_storage = result_storage,
        });
        self.reserved_bytes = reserved;
        self.pending = true;
    }

    /// Copies a bounded result into the reserved slot, without allocation.
    pub fn commit(self: *Trace, result: []const u8) Error!void {
        return self.commitOutcome(.returned, result);
    }

    pub fn commitOutcome(self: *Trace, outcome: Outcome, result: []const u8) Error!void {
        errdefer self.invalidate();
        if (self.invalidated) return error.IncompleteTrace;
        if (!self.pending or self.complete or (self.wire_minor == 0 and outcome != .returned)) return error.InvalidTrace;
        const entry = &self.entries.items[self.entries.items.len - 1];
        if (result.len > entry.result_storage.len) return error.TraceLimitExceeded;
        @memcpy(entry.result_storage[0..result.len], result);
        entry.result_len = result.len;
        entry.outcome = outcome;
        self.pending = false;
    }

    pub fn invalidate(self: *Trace) void {
        self.invalidated = true;
        self.complete = false;
    }

    /// Call only after the entire guest activation succeeds.
    pub fn finish(self: *Trace) Error!void {
        errdefer self.invalidate();
        if (self.invalidated or self.pending) return error.IncompleteTrace;
        if (self.reserved_bytes > self.limits.max_bytes) return error.TraceLimitExceeded;
        self.complete = true;
    }

    /// Returns an independent, exact-sized wire encoding. Completion and all
    /// identities are covered by a domain-separated SHA-256 checksum.
    pub fn encode(self: *const Trace, allocator: std.mem.Allocator) Error![]u8 {
        if (!self.isComplete()) return error.IncompleteTrace;
        var total: usize = header_len;
        for (self.entries.items) |entry| {
            total = try addLength(total, frameLength(self.wire_minor));
            total = try addLength(total, entry.name.len);
            total = try addLength(total, entry.arguments.len);
            total = try addLength(total, entry.result_len);
        }
        if (total > self.limits.max_bytes) return error.TraceLimitExceeded;
        const bytes = try allocator.alloc(u8, total);
        @memset(bytes[0..header_len], 0);
        @memcpy(bytes[0..8], magic);
        writeInt(u16, bytes[8..10], format_major);
        writeInt(u16, bytes[10..12], self.wire_minor);
        bytes[12] = 1; // A complete trace; all other flag bits are reserved.
        writeInt(u64, bytes[16..24], @intCast(total));
        writeInt(u64, bytes[24..32], @intCast(self.entries.items.len));
        @memcpy(bytes[32..64], &self.identity.code);
        @memcpy(bytes[64..96], &self.identity.catalogue);
        @memcpy(bytes[96..128], &self.identity.input);
        var cursor: usize = header_len;
        for (self.entries.items) |entry| {
            const frame = bytes[cursor..][0..frameLength(self.wire_minor)];
            writeInt(u32, frame[0..4], @intCast(entry.name.len));
            writeInt(u32, frame[4..8], entry.version);
            writeInt(u64, frame[8..16], @intCast(entry.arguments.len));
            writeInt(u64, frame[16..24], @intCast(entry.result_len));
            if (self.wire_minor != 0) {
                frame[24] = @backingInt(entry.outcome);
                @memset(frame[25..32], 0);
            }
            cursor += frame.len;
            for ([_][]const u8{ entry.name, entry.arguments, entry.result_storage[0..entry.result_len] }) |part| {
                @memcpy(bytes[cursor..][0..part.len], part);
                cursor += part.len;
            }
        }
        std.debug.assert(cursor == total);
        const digest = checksum(bytes);
        @memcpy(bytes[checksum_offset..header_len], &digest);
        return bytes;
    }

    /// Validates the complete wire structure and resource bounds before any
    /// allocation, then makes an owned copy independent of the input buffer.
    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8, limits: Limits) Error!Trace {
        if (bytes.len > limits.max_bytes) return error.TraceLimitExceeded;
        if (bytes.len < header_len or !std.mem.eql(u8, bytes[0..8], magic)) return error.InvalidTrace;
        const minor = readInt(u16, bytes[10..12]);
        if (readInt(u16, bytes[8..10]) != format_major or minor > format_minor)
            return error.UnsupportedTraceVersion;
        if (bytes[12] == 0) return error.IncompleteTrace;
        if (bytes[12] != 1 or bytes[13] != 0 or bytes[14] != 0 or bytes[15] != 0 or
            readInt(u64, bytes[16..24]) != bytes.len) return error.InvalidTrace;
        const count_u64 = readInt(u64, bytes[24..32]);
        if (count_u64 > limits.max_records) return error.TraceLimitExceeded;
        if (count_u64 > (bytes.len - header_len) / frameLength(minor)) return error.InvalidTrace;
        const count: usize = @intCast(count_u64);
        const digest = checksum(bytes);
        if (!std.mem.eql(u8, &digest, bytes[checksum_offset..header_len])) return error.ChecksumMismatch;

        var reader: Reader = .{ .bytes = bytes, .offset = header_len, .minor = minor };
        for (0..count) |_| _ = try reader.record(limits);
        if (reader.offset != bytes.len) return error.InvalidTrace;

        var trace = Trace.init(allocator, .{
            .code = bytes[32..64].*,
            .catalogue = bytes[64..96].*,
            .input = bytes[96..128].*,
        }, limits);
        errdefer trace.deinit();
        trace.wire_minor = minor;
        reader.offset = header_len;
        for (0..count) |_| {
            const entry = try reader.record(limits);
            try trace.reserve(entry.name, entry.version, entry.arguments, entry.result.len);
            try trace.commitOutcome(entry.outcome, entry.result);
        }
        try trace.finish();
        return trace;
    }
};

const Reader = struct {
    bytes: []const u8,
    offset: usize,
    minor: u16,

    fn take(self: *Reader, length: u64) Error![]const u8 {
        if (length > self.bytes.len - self.offset) return error.InvalidTrace;
        const count: usize = @intCast(length);
        const result = self.bytes[self.offset..][0..count];
        self.offset += count;
        return result;
    }

    fn record(self: *Reader, limits: Limits) Error!Record {
        const frame = try self.take(frameLength(self.minor));
        const outcome: Outcome = if (self.minor == 0) .returned else switch (frame[24]) {
            0 => .returned,
            1 => .rejected,
            else => return error.InvalidTrace,
        };
        if (self.minor != 0 and !std.mem.allEqual(u8, frame[25..32], 0)) return error.InvalidTrace;
        const name_len = readInt(u32, frame[0..4]);
        const arguments_len = readInt(u64, frame[8..16]);
        const result_len = readInt(u64, frame[16..24]);
        if (name_len == 0) return error.InvalidTrace;
        if (name_len > limits.max_request_bytes or arguments_len > limits.max_request_bytes or
            result_len > limits.max_result_bytes) return error.TraceLimitExceeded;
        return .{
            .name = try self.take(name_len),
            .version = readInt(u32, frame[4..8]),
            .arguments = try self.take(arguments_len),
            .result = try self.take(result_len),
            .outcome = outcome,
        };
    }
};

fn frameLength(minor: u16) usize {
    return if (minor == 0) legacy_record_header_len else record_header_len;
}

fn addLength(a: usize, b: usize) Error!usize {
    if (b > std.math.maxInt(usize) - a) return error.TraceLimitExceeded;
    return a + b;
}

fn checksum(bytes: []const u8) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(checksum_domain);
    hash.update(bytes[0..checksum_offset]);
    hash.update(bytes[header_len..]);
    return hash.finalResult();
}

fn readInt(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .big);
}

fn writeInt(comptime T: type, bytes: []u8, value: T) void {
    std.mem.writeInt(T, bytes[0..@sizeOf(T)], value, .big);
}

const test_identity: Identity = .{
    .code = @splat(0x11),
    .catalogue = @splat(0x22),
    .input = @splat(0x33),
};

test "trace owns requests and commits without allocating" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var trace = Trace.init(failing.allocator(), test_identity, .{});
    defer trace.deinit();
    var name = "Clock.now".*;
    var arguments = "argument bytes".*;
    try trace.reserve(&name, 3, &arguments, 32);
    @memset(&name, 'x');
    @memset(&arguments, 'x');
    try std.testing.expectEqual(0, trace.len());
    try std.testing.expect(trace.get(0) == null);
    failing.fail_index = failing.alloc_index;
    try trace.commit("timestamp bytes");
    try trace.finish();
    try std.testing.expect(trace.isComplete());
    const entry = trace.get(0).?;
    try std.testing.expectEqualStrings("Clock.now", entry.name);
    try std.testing.expectEqual(@as(u32, 3), entry.version);
    try std.testing.expectEqualStrings("argument bytes", entry.arguments);
    try std.testing.expectEqualStrings("timestamp bytes", entry.result);
}

test "complete trace round trips into independent storage" {
    const allocator = std.testing.allocator;
    var trace = Trace.init(allocator, test_identity, .{});
    defer trace.deinit();
    try trace.reserve("Clock.now", 1, "[]", 64);
    try trace.commit("1725545400");
    try trace.reserve("Outbox.enqueue", 2, "[hello]", 64);
    try trace.commit("receipt-42");
    try trace.finish();
    const encoded = try trace.encode(allocator);
    defer allocator.free(encoded);
    var decoded = try Trace.decode(allocator, encoded, .{});
    defer decoded.deinit();
    @memset(encoded, 0);
    try std.testing.expect(decoded.isComplete());
    try std.testing.expect(decoded.identity.eql(test_identity));
    try std.testing.expectEqual(@as(usize, 2), decoded.len());
    for (0..trace.len()) |index| {
        const expected = trace.get(index).?;
        const actual = decoded.get(index).?;
        try std.testing.expectEqualStrings(expected.name, actual.name);
        try std.testing.expectEqual(expected.version, actual.version);
        try std.testing.expectEqualStrings(expected.arguments, actual.arguments);
        try std.testing.expectEqualStrings(expected.result, actual.result);
    }
}

test "pending and failed records remain permanently incomplete" {
    const allocator = std.testing.allocator;
    var pending_trace = Trace.init(allocator, test_identity, .{});
    defer pending_trace.deinit();
    try pending_trace.reserve("op", 1, "args", 2);
    try std.testing.expectError(error.IncompleteTrace, pending_trace.encode(allocator));
    try std.testing.expectError(error.IncompleteTrace, pending_trace.finish());
    try std.testing.expectError(error.IncompleteTrace, pending_trace.commit("ok"));

    var oversized_result = Trace.init(allocator, test_identity, .{});
    defer oversized_result.deinit();
    try oversized_result.reserve("op", 1, "args", 1);
    try std.testing.expectError(error.TraceLimitExceeded, oversized_result.commit("too large"));
    try std.testing.expectError(error.IncompleteTrace, oversized_result.finish());
    try std.testing.expectError(error.IncompleteTrace, oversized_result.reserve("op", 1, "args", 1));

    var explicitly_invalid = Trace.init(allocator, test_identity, .{});
    defer explicitly_invalid.deinit();
    try explicitly_invalid.finish();
    explicitly_invalid.invalidate();
    try std.testing.expectError(error.IncompleteTrace, explicitly_invalid.encode(allocator));
}

test "reserve enforces count, payload, total capacity and integer overflow limits" {
    const Case = struct { limits: Limits, result_capacity: usize = 1 };
    const cases = [_]Case{
        .{ .limits = .{ .max_records = 0 } },
        .{ .limits = .{ .max_request_bytes = 1 } },
        .{ .limits = .{ .max_result_bytes = 0 } },
        .{ .limits = .{ .max_bytes = header_len + record_header_len + 6 } },
        .{ .limits = .{ .max_bytes = std.math.maxInt(usize), .max_result_bytes = std.math.maxInt(usize) }, .result_capacity = std.math.maxInt(usize) },
    };
    for (cases) |case| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        var trace = Trace.init(failing.allocator(), test_identity, case.limits);
        defer trace.deinit();
        try std.testing.expectError(error.TraceLimitExceeded, trace.reserve("op", 1, "args", case.result_capacity));
        try std.testing.expectEqual(@as(usize, 0), failing.alloc_index);
        try std.testing.expectError(error.IncompleteTrace, trace.finish());
    }

    var trace = Trace.init(std.testing.allocator, test_identity, .{ .max_bytes = header_len + 2 * (record_header_len + 2 + 4 + 8) - 1 });
    defer trace.deinit();
    try trace.reserve("op", 1, "args", 8);
    try trace.commit("a");
    try std.testing.expectError(error.TraceLimitExceeded, trace.reserve("op", 1, "args", 8));
}

test "wire validation rejects truncation tampering unsupported versions and excess data" {
    const allocator = std.testing.allocator;
    var trace = Trace.init(allocator, test_identity, .{});
    defer trace.deinit();
    try trace.reserve("op", 1, "args", 8);
    try trace.commit("result");
    try trace.finish();
    const encoded = try trace.encode(allocator);
    defer allocator.free(encoded);
    for (0..encoded.len) |length| {
        try std.testing.expectError(error.InvalidTrace, Trace.decode(allocator, encoded[0..length], .{}));
    }
    encoded[32] ^= 1;
    try std.testing.expectError(error.ChecksumMismatch, Trace.decode(allocator, encoded, .{}));
    encoded[32] ^= 1;
    encoded[encoded.len - 1] ^= 1;
    try std.testing.expectError(error.ChecksumMismatch, Trace.decode(allocator, encoded, .{}));
    encoded[encoded.len - 1] ^= 1;
    encoded[9] = 2;
    try std.testing.expectError(error.UnsupportedTraceVersion, Trace.decode(allocator, encoded, .{}));
    encoded[9] = 1;
    encoded[12] = 0;
    try std.testing.expectError(error.IncompleteTrace, Trace.decode(allocator, encoded, .{}));
    encoded[12] = 1;
    encoded[13] = 1;
    try std.testing.expectError(error.InvalidTrace, Trace.decode(allocator, encoded, .{}));
    encoded[13] = 0;
    try std.testing.expectError(error.TraceLimitExceeded, Trace.decode(allocator, encoded, .{ .max_records = 0 }));
    try std.testing.expectError(error.TraceLimitExceeded, Trace.decode(allocator, encoded, .{ .max_bytes = encoded.len - 1 }));
    try std.testing.expectError(error.TraceLimitExceeded, Trace.decode(allocator, encoded, .{ .max_request_bytes = 3 }));
    try std.testing.expectError(error.TraceLimitExceeded, Trace.decode(allocator, encoded, .{ .max_result_bytes = 5 }));

    // A valid checksum cannot conceal malformed record lengths or trailing data.
    writeInt(u64, encoded[header_len + 8 ..][0..8], std.math.maxInt(u64));
    var digest = checksum(encoded);
    @memcpy(encoded[checksum_offset..header_len], &digest);
    try std.testing.expectError(error.TraceLimitExceeded, Trace.decode(allocator, encoded, .{}));
    writeInt(u64, encoded[header_len + 8 ..][0..8], 0);
    digest = checksum(encoded);
    @memcpy(encoded[checksum_offset..header_len], &digest);
    try std.testing.expectError(error.InvalidTrace, Trace.decode(allocator, encoded, .{}));
}

test "trace allocation failures clean up every partial reservation and decode" {
    const Harness = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var trace = Trace.init(allocator, test_identity, .{});
            defer trace.deinit();
            try trace.reserve("Clock.now", 1, "[]", 32);
            try trace.commit("now");
            try trace.reserve("Outbox.enqueue", 1, "[hello]", 32);
            try trace.commit("receipt");
            try trace.finish();
            const encoded = try trace.encode(allocator);
            defer allocator.free(encoded);
            var decoded = try Trace.decode(allocator, encoded, .{});
            defer decoded.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Harness.run, .{});
}

test "empty complete trace is valid and still obeys its framing budget" {
    const allocator = std.testing.allocator;
    var trace = Trace.init(allocator, test_identity, .{ .max_records = 0, .max_bytes = header_len });
    defer trace.deinit();
    try trace.finish();
    const encoded = try trace.encode(allocator);
    defer allocator.free(encoded);
    try std.testing.expectEqual(header_len, encoded.len);
    var decoded = try Trace.decode(allocator, encoded, .{ .max_records = 0, .max_bytes = header_len });
    defer decoded.deinit();
    try std.testing.expect(decoded.isComplete());
    try std.testing.expectEqual(@as(usize, 0), decoded.len());

    var tiny = Trace.init(allocator, test_identity, .{ .max_bytes = header_len - 1 });
    defer tiny.deinit();
    try std.testing.expectError(error.TraceLimitExceeded, tiny.finish());
}

test "expected rejection outcomes round trip without poisoning a complete trace" {
    var trace = Trace.init(std.testing.allocator, test_identity, .{});
    defer trace.deinit();
    try trace.reserve("Inventory.reserve", 1, "[widget,2]", 64);
    try trace.commitOutcome(.rejected, "[unavailable,not enough stock]");
    try trace.reserve("Audit.note", 1, "[fallback]", 16);
    try trace.commit("noted");
    try trace.finish();
    const bytes = try trace.encode(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(@as(u16, 1), readInt(u16, bytes[10..12]));
    var restored = try Trace.decode(std.testing.allocator, bytes, .{});
    defer restored.deinit();
    try std.testing.expectEqual(Outcome.rejected, restored.get(0).?.outcome);
    try std.testing.expectEqualStrings("[unavailable,not enough stock]", restored.get(0).?.result);
    try std.testing.expectEqual(Outcome.returned, restored.get(1).?.outcome);
    try std.testing.expect(restored.isComplete());
}

test "1.0 fixed return-only trace stays readable with its original exact byte budget" {
    const hex = "4d525a4546435400000100000100000000000000000000c400000000000000011111111111111111111111111111111111111111111111111111111111111111222222222222222222222222222222222222222222222222222222222222222233333333333333333333333333333333333333333333333333333333333333338744952380a2ca7296ec2593f769f609f53c03d2b3c041e5d589dfb1601705710000000200000007000000000000000400000000000000066f7061726773726573756c74";
    var fixture: [hex.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&fixture, hex);
    var trace = try Trace.decode(std.testing.allocator, &fixture, .{ .max_bytes = fixture.len });
    defer trace.deinit();
    try std.testing.expect(trace.identity.eql(test_identity));
    const entry = trace.get(0).?;
    try std.testing.expectEqual(Outcome.returned, entry.outcome);
    try std.testing.expectEqual(@as(u32, 7), entry.version);
    try std.testing.expectEqualStrings("op", entry.name);
    try std.testing.expectEqualStrings("args", entry.arguments);
    try std.testing.expectEqualStrings("result", entry.result);
    const encoded = try trace.encode(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualSlices(u8, &fixture, encoded);
}

test "outcome discriminator and reserved bytes are authenticated and validated" {
    var trace = Trace.init(std.testing.allocator, test_identity, .{});
    defer trace.deinit();
    try trace.reserve("op", 1, "[]", 2);
    try trace.commit("ok");
    try trace.finish();
    const bytes = try trace.encode(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    bytes[header_len + 24] = 1;
    try std.testing.expectError(error.ChecksumMismatch, Trace.decode(std.testing.allocator, bytes, .{}));
    bytes[header_len + 24] = 2;
    var hash = checksum(bytes);
    @memcpy(bytes[checksum_offset..header_len], &hash);
    try std.testing.expectError(error.InvalidTrace, Trace.decode(std.testing.allocator, bytes, .{}));
    bytes[header_len + 24] = 0;
    bytes[header_len + 25] = 1;
    hash = checksum(bytes);
    @memcpy(bytes[checksum_offset..header_len], &hash);
    try std.testing.expectError(error.InvalidTrace, Trace.decode(std.testing.allocator, bytes, .{}));
    bytes[10] = 1;
    try std.testing.expectError(error.UnsupportedTraceVersion, Trace.decode(std.testing.allocator, bytes, .{}));
}
