//! Bounded, versioned frames for one strict application worker session.
//! Only inert bytes cross this seam; the broker separately validates authority,
//! operation order, capsule graphs, and the final receipt against its own log.
const std = @import("std");
const schema = @import("effect_schema.zig");
const turn_contract = @import("turn_contract.zig");

pub const magic = "MRZEWKR\x00";
pub const version_major: u16 = 1;
// Private protocol 1.3 adds turn-contract mismatch diagnostics.
// Both endpoints must use the same version; older frames are rejected.
pub const version_minor: u16 = 3;
pub const header_len: usize = 512;
pub const max_body_len: usize = 64 * 1024 * 1024;
pub const max_session_bytes: u64 = 256 * 1024 * 1024;
pub const max_process_wall_ns: u64 = 10 * 60 * std.time.ns_per_s;
pub const max_name_len: usize = 256;
pub const max_error_name_len: usize = 128;
pub const max_diagnostic_len: usize = 4096;
pub const max_operations: usize = 256;

pub const Error = error{
    InvalidFrame,
    UnsupportedVersion,
    UnknownMessageKind,
    NonZeroReserved,
    InvalidField,
    InconsistentLengths,
    BodyTooLarge,
    LengthOverflow,
};

pub const Kind = enum(u8) { start = 1, ready = 2, ready_ack = 3, effect_request = 4, effect_response = 5, finish = 6, failure = 7 };
pub const Mode = enum(u8) { record = 1, replay = 2 };
pub const Outcome = enum(u8) { returned = 0, rejected = 1 };
pub const GasMode = enum(u8) { per_isolate = 1, per_execution = 2 };
pub const Gas = union(GasMode) { per_isolate: u64, per_execution: u64 };
pub const CapsuleLimits = struct {
    max_encoded_bytes: usize = 16 * 1024 * 1024,
    max_nodes: usize = 100_000,
    max_total_edges: usize = 500_000,
    max_depth: usize = 256,
    max_string_bytes: usize = 8 * 1024 * 1024,
    max_symbol_bytes: usize = 1024 * 1024,
};
pub const ProcessLimits = struct {
    wall_time_ns: u64 = 30 * std.time.ns_per_s,
    cpu_seconds: u32 = 30,
    address_space: union(enum) { unbounded, bytes: usize } = .unbounded,
};
pub const ArtifactSettings = struct {
    max_rite_bytes: usize = 16 * 1024 * 1024,
    capsule: CapsuleLimits = .{},
    application: ?[32]u8 = null,
};

/// The strict capability floor is fixed, so no ambient-language switches are
/// transmitted. Deprecated instruction limits are normalized before encoding.
pub const Policy = struct {
    gas: Gas = .{ .per_execution = 100_000 },
    wall_time_ns: ?u64 = null,
    memory_bytes: ?usize = null,
    hard_memory_bytes: ?usize = null,
    call_depth: ?u32 = null,
    artifacts: ArtifactSettings = .{},
};
pub const EffectLimits = struct {
    max_records: usize = 1024,
    max_bytes: usize = 16 * 1024 * 1024,
    max_request_bytes: usize = 1024 * 1024,
    max_result_bytes: usize = 1024 * 1024,
};
pub const ReceiptLimits = struct {
    max_encoded_bytes: usize = 32 * 1024 * 1024,
    max_trace_bytes: usize = 16 * 1024 * 1024,
    max_terminal_bytes: usize = 16 * 1024 * 1024,
};

pub const Start = struct {
    mode: Mode = .record,
    application_identity: [32]u8,
    bootstrap_identity: [32]u8 = @splat(0),
    adapter_state_identity: [32]u8 = @splat(0),
    grants: [32]u8 = @splat(0),
    operation_count: u16,
    grant_order_len: usize = 0,
    policy: Policy = .{},
    effect_limits: EffectLimits = .{},
    capsule_limits: CapsuleLimits = .{},
    receipt_limits: ReceiptLimits = .{},
    process: ProcessLimits = .{},
    max_transfer_bytes: u64 = max_session_bytes,
    entry_len: usize,
    receiver_len: usize,
    method_len: usize,
    state_len: usize,
    input_len: usize,
    receipt_len: usize = 0,

    pub fn granted(self: Start, index: usize) bool {
        return index < max_operations and self.grants[index / 8] & (@as(u8, 1) << @intCast(index % 8)) != 0;
    }
    pub fn setGrant(self: *Start, index: usize) Error!void {
        if (index >= self.operation_count or index >= max_operations) return error.InvalidField;
        self.grants[index / 8] |= @as(u8, 1) << @intCast(index % 8);
    }
};
pub const Ready = struct { application_identity: [32]u8 };
pub const EffectRequest = struct { sequence: u64, operation_index: u32, version: u32, name_len: usize, arguments_len: usize };
pub const EffectResponse = struct { sequence: u64, outcome: Outcome, result_len: usize };
pub const Finish = struct { sequence: u64, receipt_len: usize };
/// Body order is error-name bytes followed by diagnostic bytes. An absent
/// diagnostic never changes the failure itself or grants execution authority.
pub const Failure = struct { sequence: u64, error_name_len: usize, diagnostic_len: usize = 0 };
pub const Header = union(Kind) {
    start: Start,
    ready: Ready,
    ready_ack: Ready,
    effect_request: EffectRequest,
    effect_response: EffectResponse,
    finish: Finish,
    failure: Failure,

    pub fn bodyLen(self: Header) Error!usize {
        return switch (self) {
            .start => |s| checkedLength(&.{ s.entry_len, s.receiver_len, s.method_len, s.grant_order_len, s.state_len, s.input_len, s.receipt_len }),
            .ready, .ready_ack => 0,
            .effect_request => |e| checkedLength(&.{ e.name_len, e.arguments_len }),
            .effect_response => |e| checkedLength(&.{e.result_len}),
            .finish => |f| checkedLength(&.{f.receipt_len}),
            .failure => |f| checkedLength(&.{ f.error_name_len, f.diagnostic_len }),
        };
    }
};

pub const StartBody = struct { entry: []const u8, receiver: []const u8, method: []const u8, grant_order: []const u8, state: []const u8, input: []const u8, receipt: []const u8 };
pub const EffectRequestBody = struct { name: []const u8, arguments: []const u8 };

pub fn encode(header: Header) Error![header_len]u8 {
    try validate(header);
    var bytes: [header_len]u8 = @splat(0);
    @memcpy(bytes[0..8], magic);
    std.mem.writeInt(u16, bytes[8..10], version_major, .big);
    std.mem.writeInt(u16, bytes[10..12], version_minor, .big);
    bytes[12] = @backingInt(std.meta.activeTag(header));
    std.mem.writeInt(u16, bytes[14..16], header_len, .big);
    std.mem.writeInt(u64, bytes[16..24], @intCast(try header.bodyLen()), .big);
    const sequence: u64 = switch (header) {
        .start, .ready, .ready_ack => 0,
        inline else => |h| h.sequence,
    };
    std.mem.writeInt(u64, bytes[24..32], sequence, .big);
    var writer: Writer = .{ .bytes = &bytes };
    switch (header) {
        .start => |s| {
            writer.copy(&s.application_identity);
            writer.copy(&s.bootstrap_identity);
            writer.copy(&s.adapter_state_identity);
            writer.copy(&s.grants);
            writer.int(u8, @backingInt(s.mode));
            writer.int(u8, @backingInt(std.meta.activeTag(s.policy.gas)));
            const flags: u16 = @as(u16, @intFromBool(s.policy.wall_time_ns != null)) |
                (@as(u16, @intFromBool(s.policy.memory_bytes != null)) << 1) |
                (@as(u16, @intFromBool(s.policy.hard_memory_bytes != null)) << 2) |
                (@as(u16, @intFromBool(s.policy.call_depth != null)) << 3) |
                (@as(u16, @intFromBool(s.policy.artifacts.application != null)) << 4);
            writer.int(u16, flags);
            writer.int(u32, s.process.cpu_seconds);
            writer.int(u64, switch (s.policy.gas) {
                .per_isolate, .per_execution => |n| n,
            });
            writer.int(u64, s.policy.wall_time_ns orelse 0);
            writer.int(u64, @intCast(s.policy.memory_bytes orelse 0));
            writer.int(u64, @intCast(s.policy.hard_memory_bytes orelse 0));
            writer.int(u64, s.policy.call_depth orelse 0);
            writer.int(u64, @intCast(s.policy.artifacts.max_rite_bytes));
            writer.capsule(s.policy.artifacts.capsule);
            writer.capsule(s.capsule_limits);
            writer.int(u64, @intCast(s.effect_limits.max_records));
            writer.int(u64, @intCast(s.effect_limits.max_bytes));
            writer.int(u64, @intCast(s.effect_limits.max_request_bytes));
            writer.int(u64, @intCast(s.effect_limits.max_result_bytes));
            writer.int(u64, @intCast(s.receipt_limits.max_encoded_bytes));
            writer.int(u64, @intCast(s.receipt_limits.max_trace_bytes));
            writer.int(u64, @intCast(s.receipt_limits.max_terminal_bytes));
            writer.int(u64, s.process.wall_time_ns);
            writer.int(u64, switch (s.process.address_space) {
                .unbounded => 0,
                .bytes => |n| @intCast(n),
            });
            writer.int(u64, s.max_transfer_bytes);
            for ([_]usize{ s.entry_len, s.receiver_len, s.method_len, s.state_len, s.input_len, s.receipt_len }) |n| writer.int(u64, @intCast(n));
            const application: [32]u8 = s.policy.artifacts.application orelse @splat(0);
            writer.copy(&application);
            writer.int(u16, s.operation_count);
            writer.int(u16, @intCast(s.grant_order_len));
        },
        .ready, .ready_ack => |r| writer.copy(&r.application_identity),
        .effect_request => |e| {
            writer.int(u32, e.operation_index);
            writer.int(u32, e.version);
            writer.int(u64, @intCast(e.name_len));
            writer.int(u64, @intCast(e.arguments_len));
        },
        .effect_response => |e| {
            writer.int(u64, @backingInt(e.outcome));
            writer.int(u64, @intCast(e.result_len));
        },
        .finish => |f| writer.int(u64, @intCast(f.receipt_len)),
        .failure => |f| {
            writer.int(u64, @intCast(f.error_name_len));
            writer.int(u64, @intCast(f.diagnostic_len));
        },
    }
    return bytes;
}

pub fn decode(bytes: []const u8) Error!Header {
    if (bytes.len != header_len or !std.mem.eql(u8, bytes[0..8], magic)) return error.InvalidFrame;
    if (std.mem.readInt(u16, bytes[8..10], .big) != version_major or std.mem.readInt(u16, bytes[10..12], .big) != version_minor)
        return error.UnsupportedVersion;
    if (bytes[13] != 0) return error.NonZeroReserved;
    if (std.mem.readInt(u16, bytes[14..16], .big) != header_len) return error.InvalidFrame;
    const body_len = try size(std.mem.readInt(u64, bytes[16..24], .big));
    if (body_len > max_body_len) return error.BodyTooLarge;
    const sequence = std.mem.readInt(u64, bytes[24..32], .big);
    var reader: Reader = .{ .bytes = bytes };
    const header: Header = switch (bytes[12]) {
        1 => .{ .start = blk: {
            if (sequence != 0) return error.InvalidField;
            var s: Start = undefined;
            s.application_identity = reader.array(32);
            s.bootstrap_identity = reader.array(32);
            s.adapter_state_identity = reader.array(32);
            s.grants = reader.array(32);
            s.mode = switch (reader.int(u8)) {
                1 => .record,
                2 => .replay,
                else => return error.InvalidField,
            };
            const gas_mode = reader.int(u8);
            const flags = reader.int(u16);
            if (flags & ~@as(u16, 31) != 0) return error.InvalidField;
            s.process.cpu_seconds = reader.int(u32);
            const gas = reader.int(u64);
            s.policy.gas = switch (gas_mode) {
                1 => .{ .per_isolate = gas },
                2 => .{ .per_execution = gas },
                else => return error.InvalidField,
            };
            s.policy.wall_time_ns = try optional(u64, flags & 1 != 0, reader.int(u64));
            s.policy.memory_bytes = try optional(usize, flags & 2 != 0, reader.int(u64));
            s.policy.hard_memory_bytes = try optional(usize, flags & 4 != 0, reader.int(u64));
            s.policy.call_depth = try optional(u32, flags & 8 != 0, reader.int(u64));
            s.policy.artifacts.max_rite_bytes = try size(reader.int(u64));
            s.policy.artifacts.capsule = try reader.capsule();
            s.capsule_limits = try reader.capsule();
            s.effect_limits = .{ .max_records = try size(reader.int(u64)), .max_bytes = try size(reader.int(u64)), .max_request_bytes = try size(reader.int(u64)), .max_result_bytes = try size(reader.int(u64)) };
            s.receipt_limits = .{ .max_encoded_bytes = try size(reader.int(u64)), .max_trace_bytes = try size(reader.int(u64)), .max_terminal_bytes = try size(reader.int(u64)) };
            s.process.wall_time_ns = reader.int(u64);
            const address_space = try size(reader.int(u64));
            s.process.address_space = if (address_space == 0) .unbounded else .{ .bytes = address_space };
            s.max_transfer_bytes = reader.int(u64);
            s.entry_len = try size(reader.int(u64));
            s.receiver_len = try size(reader.int(u64));
            s.method_len = try size(reader.int(u64));
            s.state_len = try size(reader.int(u64));
            s.input_len = try size(reader.int(u64));
            s.receipt_len = try size(reader.int(u64));
            const application = reader.array(32);
            if (flags & 16 != 0) s.policy.artifacts.application = application else {
                if (!allZero(&application)) return error.InvalidField;
                s.policy.artifacts.application = null;
            }
            s.operation_count = reader.int(u16);
            s.grant_order_len = reader.int(u16);
            break :blk s;
        } },
        2, 3 => blk: {
            if (sequence != 0) return error.InvalidField;
            const ready: Ready = .{ .application_identity = reader.array(32) };
            break :blk if (bytes[12] == 2) .{ .ready = ready } else .{ .ready_ack = ready };
        },
        4 => .{ .effect_request = .{ .sequence = sequence, .operation_index = reader.int(u32), .version = reader.int(u32), .name_len = try size(reader.int(u64)), .arguments_len = try size(reader.int(u64)) } },
        5 => .{ .effect_response = .{ .sequence = sequence, .outcome = switch (reader.int(u64)) {
            0 => .returned,
            1 => .rejected,
            else => return error.InvalidField,
        }, .result_len = try size(reader.int(u64)) } },
        6 => .{ .finish = .{ .sequence = sequence, .receipt_len = try size(reader.int(u64)) } },
        7 => .{ .failure = .{ .sequence = sequence, .error_name_len = try size(reader.int(u64)), .diagnostic_len = try size(reader.int(u64)) } },
        else => return error.UnknownMessageKind,
    };
    if (!allZero(bytes[reader.at..])) return error.NonZeroReserved;
    try validate(header);
    if (try header.bodyLen() != body_len) return error.InconsistentLengths;
    return header;
}

pub fn splitStartBody(start: Start, body: []const u8) Error!StartBody {
    if (body.len != try (Header{ .start = start }).bodyLen()) return error.InconsistentLengths;
    var cursor: usize = 0;
    const entry = take(body, &cursor, start.entry_len);
    const receiver = take(body, &cursor, start.receiver_len);
    const method = take(body, &cursor, start.method_len);
    for ([_][]const u8{ entry, receiver, method }) |name| if (std.mem.indexOfScalar(u8, name, 0) != null) return error.InvalidField;
    const grant_order = take(body, &cursor, start.grant_order_len);
    var seen: [32]u8 = @splat(0);
    for (grant_order) |index| {
        if (index >= start.operation_count) return error.InvalidField;
        const bit = @as(u8, 1) << @intCast(index % 8);
        if (seen[index / 8] & bit != 0) return error.InvalidField;
        seen[index / 8] |= bit;
    }
    if (!std.mem.eql(u8, &seen, &start.grants)) return error.InvalidField;
    return .{ .entry = entry, .receiver = receiver, .method = method, .grant_order = grant_order, .state = take(body, &cursor, start.state_len), .input = take(body, &cursor, start.input_len), .receipt = take(body, &cursor, start.receipt_len) };
}

pub fn splitEffectRequestBody(request: EffectRequest, body: []const u8) Error!EffectRequestBody {
    if (body.len != try (Header{ .effect_request = request }).bodyLen()) return error.InconsistentLengths;
    if (std.mem.indexOfScalar(u8, body[0..request.name_len], 0) != null) return error.InvalidField;
    return .{ .name = body[0..request.name_len], .arguments = body[request.name_len..] };
}

fn validate(header: Header) Error!void {
    _ = try header.bodyLen();
    switch (header) {
        .start => |s| {
            if (s.operation_count > max_operations or s.grant_order_len > s.operation_count or s.entry_len == 0 or s.entry_len > max_name_len or
                s.receiver_len == 0 or s.receiver_len > max_name_len or s.method_len == 0 or s.method_len > 255 or
                s.state_len == 0 or s.input_len == 0 or (s.mode == .record and s.receipt_len != 0) or (s.mode == .replay and s.receipt_len == 0)) return error.InvalidField;
            for (s.operation_count..max_operations) |index| if (s.granted(index)) return error.InvalidField;
            var grant_count: usize = 0;
            for (s.grants) |byte| grant_count += @popCount(byte);
            if (s.grant_order_len != grant_count) return error.InvalidField;
            if (s.process.wall_time_ns == 0 or s.process.wall_time_ns > max_process_wall_ns or s.process.cpu_seconds == 0 or
                s.max_transfer_bytes < header_len or s.max_transfer_bytes > max_session_bytes) return error.InvalidField;
            if (s.process.address_space == .bytes and s.process.address_space.bytes == 0) return error.InvalidField;
            if (s.policy.artifacts.max_rite_bytes > max_body_len or s.policy.artifacts.capsule.max_encoded_bytes > max_body_len or
                s.capsule_limits.max_encoded_bytes > max_body_len or s.effect_limits.max_bytes > max_body_len or
                s.effect_limits.max_request_bytes > max_body_len or s.effect_limits.max_result_bytes > max_body_len or
                s.receipt_limits.max_encoded_bytes > max_body_len or s.receipt_limits.max_trace_bytes > max_body_len or
                s.receipt_limits.max_terminal_bytes > max_body_len) return error.BodyTooLarge;
            if (s.state_len > s.capsule_limits.max_encoded_bytes or s.input_len > s.capsule_limits.max_encoded_bytes or
                s.state_len > s.policy.artifacts.capsule.max_encoded_bytes or s.input_len > s.policy.artifacts.capsule.max_encoded_bytes or
                s.receipt_len > s.receipt_limits.max_encoded_bytes) return error.BodyTooLarge;
        },
        .ready, .ready_ack => {},
        .effect_request => |e| if (e.operation_index >= max_operations or e.version == 0 or e.name_len == 0 or e.name_len > max_name_len or e.arguments_len == 0) return error.InvalidField,
        .effect_response => |e| if (e.result_len == 0) return error.InvalidField,
        .finish => |f| if (f.receipt_len == 0) return error.InvalidField,
        .failure => |f| if (f.error_name_len == 0 or f.error_name_len > max_error_name_len or f.diagnostic_len > max_diagnostic_len) return error.InvalidField,
    }
}

fn checkedLength(parts: []const usize) Error!usize {
    var total: usize = 0;
    for (parts) |part| total = std.math.add(usize, total, part) catch return error.LengthOverflow;
    if (total > max_body_len) return error.BodyTooLarge;
    return total;
}
fn size(n: u64) Error!usize {
    return std.math.cast(usize, n) orelse error.LengthOverflow;
}
fn optional(comptime T: type, present: bool, n: u64) Error!?T {
    if (!present) {
        if (n != 0) return error.InvalidField;
        return null;
    }
    return std.math.cast(T, n) orelse error.InvalidField;
}
fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}
fn take(bytes: []const u8, cursor: *usize, length: usize) []const u8 {
    const start = cursor.*;
    cursor.* += length;
    return bytes[start..cursor.*];
}
const Writer = struct {
    bytes: *[header_len]u8,
    at: usize = 32,
    fn int(self: *Writer, comptime T: type, n: T) void {
        std.mem.writeInt(T, self.bytes[self.at..][0..@sizeOf(T)], n, .big);
        self.at += @sizeOf(T);
    }
    fn copy(self: *Writer, bytes: []const u8) void {
        @memcpy(self.bytes[self.at..][0..bytes.len], bytes);
        self.at += bytes.len;
    }
    fn capsule(self: *Writer, limits: CapsuleLimits) void {
        inline for (capsule_fields) |name| self.int(u64, @intCast(@field(limits, name)));
    }
};
const Reader = struct {
    bytes: []const u8,
    at: usize = 32,
    fn int(self: *Reader, comptime T: type) T {
        const n = std.mem.readInt(T, self.bytes[self.at..][0..@sizeOf(T)], .big);
        self.at += @sizeOf(T);
        return n;
    }
    fn array(self: *Reader, comptime n: usize) [n]u8 {
        const out: [n]u8 = self.bytes[self.at..][0..n].*;
        self.at += n;
        return out;
    }
    fn capsule(self: *Reader) Error!CapsuleLimits {
        var out: CapsuleLimits = undefined;
        inline for (capsule_fields) |name| @field(out, name) = try size(self.int(u64));
        return out;
    }
};
const capsule_fields = .{ "max_encoded_bytes", "max_nodes", "max_total_edges", "max_depth", "max_string_bytes", "max_symbol_bytes" };

/// Binds the executable's compiled application, dependency graph, operation
/// contracts, and strict runtime profile. No executable path is trusted as ID.
pub fn applicationIdentity(comptime manifest: type, comptime operations: anytype, runtime_identity: [32]u8) [32]u8 {
    return applicationIdentityWithContract(manifest, operations, runtime_identity, null);
}

/// The optional turn contract is compiled independently into the worker. Its
/// digest participates in the handshake; no untrusted schema crosses the wire.
pub fn applicationIdentityWithContract(comptime manifest: type, comptime operations: anytype, runtime_identity: [32]u8, whole_contract: ?*const turn_contract.Contract) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("mruby-zig/effect-worker-application/v1\x00");
    hash.update(&runtime_identity);
    hashNumber(&hash, manifest.entries.len);
    for (manifest.entries) |entry| {
        hashBytes(&hash, entry.name);
        hashBytes(&hash, entry.bytes);
        hashNumber(&hash, @intFromBool(if (@hasField(@TypeOf(entry), "entrypoint")) entry.entrypoint else true));
        const dependencies: []const []const u8 = if (@hasField(@TypeOf(entry), "dependencies")) entry.dependencies else &.{};
        hashNumber(&hash, dependencies.len);
        for (dependencies) |dependency| hashBytes(&hash, dependency);
    }
    hashNumber(&hash, operations.len);
    inline for (operations) |op| {
        hashBytes(&hash, op.name);
        hashBytes(&hash, op.namespace);
        hashBytes(&hash, op.method);
        hashNumber(&hash, if (@hasField(@TypeOf(op), "version")) op.version else 1);
        hashNumber(&hash, op.arity);
        hashNumber(&hash, op.authority_bits);
        hashNumber(&hash, if (@hasField(@TypeOf(op), "max_result_bytes")) op.max_result_bytes else 4096);
    }
    // Keep schema-less application IDs byte-for-byte compatible. Typed
    // contracts add one separately framed extension using the shared schema
    // compiler/digest, never a second interpretation of the declaration.
    comptime var typed_count: usize = 0;
    inline for (operations) |op| {
        if (comptime (schema.operationContract(op) catch @compileError("invalid effect operation contract")) != null) typed_count += 1;
    }
    if (typed_count != 0) {
        hash.update("mruby-zig/effect-worker-contracts/v1\x00");
        hashNumber(&hash, typed_count);
        inline for (operations, 0..) |op, index| {
            const contract = comptime schema.operationContract(op) catch @compileError("invalid effect operation contract");
            if (contract) |compiled| {
                hashNumber(&hash, index);
                hash.update(&compiled.digest());
            }
        }
    }
    if (whole_contract) |compiled| {
        hash.update("mruby-zig/effect-worker-turn-contract/v1\x00");
        hash.update(&compiled.digest());
    }
    return hash.finalResult();
}
fn hashNumber(hash: *std.crypto.hash.sha2.Sha256, n: usize) void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, @intCast(n), .big);
    hash.update(&encoded);
}
fn hashBytes(hash: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
    hashNumber(hash, bytes.len);
    hash.update(bytes);
}

fn sampleStart() Start {
    return .{ .application_identity = @splat(1), .operation_count = 3, .entry_len = 1, .receiver_len = 2, .method_len = 3, .state_len = 128, .input_len = 128 };
}
test "strict worker frames round trip exactly with all optional limits" {
    var start = sampleStart();
    start.policy = .{ .gas = .{ .per_isolate = 321 }, .wall_time_ns = 0, .memory_bytes = 1234, .hard_memory_bytes = 4567, .call_depth = 64, .artifacts = .{ .application = @splat(9) } };
    try start.setGrant(2);
    start.grant_order_len = 1;
    for ([_]Header{ .{ .start = start }, .{ .ready = .{ .application_identity = @splat(3) } }, .{ .ready_ack = .{ .application_identity = @splat(3) } }, .{ .effect_request = .{ .sequence = 7, .operation_index = 2, .version = 8, .name_len = 3, .arguments_len = 128 } }, .{ .effect_response = .{ .sequence = 7, .outcome = .rejected, .result_len = 128 } }, .{ .finish = .{ .sequence = 8, .receipt_len = 1024 } }, .{ .failure = .{ .sequence = 8, .error_name_len = 12 } } }) |header| {
        const bytes = try encode(header);
        try std.testing.expectEqualDeep(header, try decode(&bytes));
        try std.testing.expectEqualSlices(u8, &bytes, &(try encode(try decode(&bytes))));
    }
}
test "strict worker framing rejects reserved bits lengths versions and unknown kinds" {
    const original = try encode(.{ .start = sampleStart() });
    for ([_]struct { offset: usize, expected: anyerror }{ .{ .offset = 0, .expected = error.InvalidFrame }, .{ .offset = 9, .expected = error.UnsupportedVersion }, .{ .offset = 12, .expected = error.UnknownMessageKind }, .{ .offset = 13, .expected = error.NonZeroReserved }, .{ .offset = 511, .expected = error.NonZeroReserved } }) |case| {
        var bytes = original;
        bytes[case.offset] = 0xff;
        try std.testing.expectError(case.expected, decode(&bytes));
    }
    var bytes = original;
    std.mem.writeInt(u64, bytes[16..24], 1, .big);
    try std.testing.expectError(error.InconsistentLengths, decode(&bytes));
    try std.testing.expectError(error.InvalidFrame, decode(original[0 .. header_len - 1]));
}
test "strict worker start rejects hidden grants absent values and incompatible mode bodies" {
    var start = sampleStart();
    start.grants[31] = 1;
    try std.testing.expectError(error.InvalidField, encode(.{ .start = start }));
    start = sampleStart();
    start.mode = .replay;
    try std.testing.expectError(error.InvalidField, encode(.{ .start = start }));
    start = sampleStart();
    start.receipt_len = 1;
    try std.testing.expectError(error.InvalidField, encode(.{ .start = start }));
    var bytes = try encode(.{ .start = sampleStart() });
    bytes[183] = 1; // absent optional sandbox deadline must encode zero
    try std.testing.expectError(error.InvalidField, decode(&bytes));
}
test "strict worker body slicing bounds every region and rejects embedded nul names" {
    var start = sampleStart();
    start.state_len = 1;
    start.input_len = 1;
    const body = try splitStartBody(start, "eRRmmmSI");
    try std.testing.expectEqualStrings("e", body.entry);
    try std.testing.expectEqualStrings("RR", body.receiver);
    try std.testing.expectEqualStrings("mmm", body.method);
    try std.testing.expectEqualStrings("S", body.state);
    try std.testing.expectEqualStrings("I", body.input);
    try std.testing.expectError(error.InconsistentLengths, splitStartBody(start, "short"));
    try std.testing.expectError(error.InvalidField, splitStartBody(start, "eR\x00mmmSI"));
}

test "strict worker grants retain caller order with exact bitmap membership" {
    var start = sampleStart();
    start.state_len = 1;
    start.input_len = 1;
    start.grant_order_len = 2;
    try start.setGrant(0);
    try start.setGrant(2);
    const decoded = (try decode(&(try encode(.{ .start = start })))).start;
    const reverse = try splitStartBody(decoded, "eRRmmm\x02\x00SI");
    try std.testing.expectEqualSlices(u8, &.{ 2, 0 }, reverse.grant_order);
    _ = try splitStartBody(decoded, "eRRmmm\x00\x02SI");
    try std.testing.expectError(error.InvalidField, splitStartBody(decoded, "eRRmmm\x02\x02SI"));
    try std.testing.expectError(error.InvalidField, splitStartBody(decoded, "eRRmmm\x02\x01SI"));
    try std.testing.expectError(error.InvalidField, splitStartBody(decoded, "eRRmmm\x02\x03SI"));
    var pure = sampleStart();
    pure.operation_count = 0;
    _ = try decode(&(try encode(.{ .start = pure })));
}

test "strict worker application identity binds graph profile and normalized operation contracts" {
    const Entry = struct { name: []const u8, bytes: []const u8, dependencies: []const []const u8 = &.{}, entrypoint: bool = true };
    const Manifest = struct {
        pub const entries = [_]Entry{.{ .name = "app", .bytes = "rite", .dependencies = &.{ "one", "two" } }};
    };
    const Reordered = struct {
        pub const entries = [_]Entry{.{ .name = "app", .bytes = "rite", .dependencies = &.{ "two", "one" } }};
    };
    const NotEntry = struct {
        pub const entries = [_]Entry{.{ .name = "app", .bytes = "rite", .dependencies = &.{ "one", "two" }, .entrypoint = false }};
    };
    const ops = .{.{ .name = "clock.now", .namespace = "Clock", .method = "now", .arity = 0, .authority_bits = 4 }};
    const explicit = .{.{ .name = "clock.now", .namespace = "Clock", .method = "now", .version = 1, .arity = 0, .authority_bits = 4, .max_result_bytes = 4096 }};
    const absent = .{.{ .name = "clock.now", .namespace = "Clock", .method = "now", .version = 1, .arity = 0, .authority_bits = 4, .max_result_bytes = 4096, .contract = null }};
    const versioned = .{.{ .name = "clock.now", .namespace = "Clock", .method = "now", .version = 2, .arity = 0, .authority_bits = 4 }};
    const identity = applicationIdentity(Manifest, ops, @splat(0));
    // Independently computed with Python hashlib/struct using the original
    // v1 domain and big-endian u64 framing, before contract extensions.
    const legacy_identity = [_]u8{
        0x57, 0x56, 0xd2, 0x81, 0x79, 0xa4, 0x07, 0xfa,
        0x42, 0xb3, 0x7a, 0xf7, 0xfe, 0xc3, 0xbe, 0x6a,
        0x7f, 0xfd, 0x73, 0x4b, 0xdd, 0x6f, 0x1d, 0xbf,
        0x8b, 0x78, 0xa9, 0x88, 0x1d, 0x45, 0xf2, 0xa0,
    };
    try std.testing.expectEqualSlices(u8, &legacy_identity, &identity);
    try std.testing.expectEqualSlices(u8, &identity, &applicationIdentity(Manifest, explicit, @splat(0)));
    try std.testing.expectEqualSlices(u8, &identity, &applicationIdentity(Manifest, absent, @splat(0)));
    try std.testing.expect(!std.mem.eql(u8, &identity, &applicationIdentity(Manifest, ops, @splat(1))));
    try std.testing.expect(!std.mem.eql(u8, &identity, &applicationIdentity(Manifest, versioned, @splat(0))));
    try std.testing.expect(!std.mem.eql(u8, &identity, &applicationIdentity(Reordered, ops, @splat(0))));
    try std.testing.expect(!std.mem.eql(u8, &identity, &applicationIdentity(NotEntry, ops, @splat(0))));
}

test "worker failures bound diagnostic bytes and reject old protocol framing" {
    const original = try encode(.{ .failure = .{ .sequence = 3, .error_name_len = 12, .diagnostic_len = max_diagnostic_len } });
    const decoded = try decode(&original);
    try std.testing.expectEqual(@as(usize, 12 + max_diagnostic_len), try decoded.bodyLen());
    try std.testing.expectEqual(@as(usize, max_diagnostic_len), decoded.failure.diagnostic_len);
    try std.testing.expectError(error.InvalidField, encode(.{ .failure = .{ .sequence = 0, .error_name_len = 1, .diagnostic_len = max_diagnostic_len + 1 } }));
    var old = original;
    std.mem.writeInt(u16, old[10..12], 0, .big);
    try std.testing.expectError(error.UnsupportedVersion, decode(&old));
    std.mem.writeInt(u16, old[10..12], 1, .big);
    try std.testing.expectError(error.UnsupportedVersion, decode(&old));
    std.mem.writeInt(u16, old[10..12], 2, .big);
    try std.testing.expectError(error.UnsupportedVersion, decode(&old));
    var inconsistent = original;
    std.mem.writeInt(u64, inconsistent[16..24], 12, .big);
    try std.testing.expectError(error.InconsistentLengths, decode(&inconsistent));
    var oversized = original;
    std.mem.writeInt(u64, oversized[40..48], max_diagnostic_len + 1, .big);
    try std.testing.expectError(error.InvalidField, decode(&oversized));
}

test "worker application identity includes normalized typed contracts and changes with their meaning" {
    const Manifest = struct {
        const Entry = struct { name: []const u8, bytes: []const u8 };
        pub const entries = [_]Entry{.{ .name = "app", .bytes = "rite" }};
    };
    const plain = .{.{ .name = "clock.now", .namespace = "Clock", .method = "now", .arity = 0, .authority_bits = 4 }};
    const typed = .{.{ .name = "clock.now", .namespace = "Clock", .method = "now", .arity = 0, .authority_bits = 4, .contract = .{ .arguments = .{ .tuple = .{} }, .result = .integer } }};
    const explicit = .{.{ .name = "clock.now", .namespace = "Clock", .method = "now", .arity = 0, .authority_bits = 4, .contract = .{ .arguments = .{ .tuple = .{} }, .result = .{ .integer = .{ .min = std.math.minInt(i64), .max = std.math.maxInt(i64) } } } }};
    const positive = .{.{ .name = "clock.now", .namespace = "Clock", .method = "now", .arity = 0, .authority_bits = 4, .contract = .{ .arguments = .{ .tuple = .{} }, .result = .{ .integer = .{ .min = 0 } } } }};
    const compiled = comptime schema.operationContract(typed[0]) catch unreachable;
    const normalized = .{.{ .name = "clock.now", .namespace = "Clock", .method = "now", .arity = 0, .authority_bits = 4, .contract = compiled }};
    const identity = applicationIdentity(Manifest, typed, @splat(0));
    try std.testing.expectEqualSlices(u8, &identity, &applicationIdentity(Manifest, explicit, @splat(0)));
    try std.testing.expectEqualSlices(u8, &identity, &applicationIdentity(Manifest, normalized, @splat(0)));
    try std.testing.expect(!std.mem.eql(u8, &identity, &applicationIdentity(Manifest, plain, @splat(0))));
    try std.testing.expect(!std.mem.eql(u8, &identity, &applicationIdentity(Manifest, positive, @splat(0))));
}

test "worker application identity preserves null turn contracts and binds every declared boundary" {
    const Manifest = struct {
        const Entry = struct { name: []const u8, bytes: []const u8 };
        pub const entries = [_]Entry{.{ .name = "app", .bytes = "rite" }};
    };
    const original = applicationIdentity(Manifest, .{}, @splat(0));
    try std.testing.expectEqualSlices(u8, &original, &applicationIdentityWithContract(Manifest, .{}, @splat(0), null));
    const compiled = comptime try turn_contract.Contract.from(.{ .state = .integer, .input = .boolean, .result = .nil });
    const normalized = comptime try turn_contract.Contract.from(compiled);
    const typed = applicationIdentityWithContract(Manifest, .{}, @splat(0), compiled);
    try std.testing.expect(!std.mem.eql(u8, &original, &typed));
    try std.testing.expectEqualSlices(u8, &typed, &applicationIdentityWithContract(Manifest, .{}, @splat(0), normalized));
    inline for (.{
        .{ .state = .{ .integer = .{ .min = 0 } }, .input = .boolean, .result = .nil },
        .{ .state = .integer, .input = .nil, .result = .nil },
        .{ .state = .integer, .input = .boolean, .result = .boolean },
    }) |literal| {
        const changed = comptime try turn_contract.Contract.from(literal);
        try std.testing.expect(!std.mem.eql(u8, &typed, &applicationIdentityWithContract(Manifest, .{}, @splat(0), changed)));
    }
}
