//! Private, allocation-free framing for the one-shot mruby worker process.
//!
//! The wire format is deliberately independent of Zig struct layout. Every
//! integer is big-endian, every optional field has an explicit presence bit,
//! and both peers validate a complete fixed-size header before allocating the
//! bounded body.

const std = @import("std");

pub const magic = [_]u8{ 'M', 'R', 'Z', 'W', 'I', 'P', 'C', 0 };
pub const version_major: u16 = 1;
pub const version_minor: u16 = 0;
pub const common_prefix_len: usize = 24;
pub const request_header_len: usize = 256;
pub const response_header_len: usize = 192;
pub const max_body_len: usize = 64 * 1024 * 1024;
pub const max_exception_class_len: usize = 256;
pub const max_exception_message_len: usize = 4096;
pub const max_diagnostic_path_len: usize = 256;

pub const Error = error{
    TruncatedHeader,
    InvalidHeaderLength,
    InvalidMagic,
    UnsupportedVersion,
    UnexpectedMessageKind,
    UnknownFlags,
    UnknownEnumValue,
    NonZeroReserved,
    InconsistentLengths,
    BodyTooLarge,
    LengthOverflow,
    InvalidField,
    InvalidStats,
};

pub const MessageKind = enum(u8) {
    request = 1,
    response = 2,
};

/// The common prefix can be decoded after reading only 24 bytes. `body_len`
/// has already been checked against `max_body_len` and converted to `usize`.
pub const Prefix = struct {
    kind: MessageKind,
    header_len: u16,
    body_len: usize,
};

pub const Schema = struct {
    id: [16]u8,
    major: u16,
    minor: u16 = 0,
};

pub const CapsuleLimits = struct {
    max_encoded_bytes: usize = 16 * 1024 * 1024,
    max_nodes: usize = 100_000,
    max_total_edges: usize = 500_000,
    max_depth: usize = 256,
    max_string_bytes: usize = 8 * 1024 * 1024,
    max_symbol_bytes: usize = 1024 * 1024,
};

pub const ArtifactSettings = struct {
    max_rite_bytes: usize = 16 * 1024 * 1024,
    capsule: CapsuleLimits = .{},
    application: ?[32]u8 = null,
};

pub const GasMode = enum(u8) {
    unlimited = 0,
    per_isolate = 1,
    per_execution = 2,
};

pub const GasLimit = union(GasMode) {
    unlimited,
    per_isolate: u64,
    per_execution: u64,
};

pub const SandboxLimits = struct {
    gas: GasLimit = .unlimited,
    wall_time_ns: ?u64 = null,
    memory_bytes: ?usize = null,
    hard_memory_bytes: ?usize = null,
    call_depth: ?u32 = null,
};

pub const Capabilities = struct {
    eval: bool = false,
    send: bool = false,
    introspection: bool = false,
    object_space: bool = false,
    freeze_object_model: bool = false,
    random_seed: ?u64 = null,
    clock_epoch_s: ?i64 = null,
};

pub const SandboxPolicy = struct {
    limits: SandboxLimits = .{},
    capabilities: Capabilities = .{},
    artifacts: ArtifactSettings = .{},
};

pub const AddressSpaceMode = enum(u8) {
    unbounded = 0,
    bytes = 1,
};

pub const AddressSpaceLimit = union(AddressSpaceMode) {
    unbounded,
    bytes: usize,
};

pub const ProcessLimits = struct {
    wall_time_ns: u64 = 30 * std.time.ns_per_s,
    cpu_seconds: u32 = 30,
    address_space: AddressSpaceLimit = .unbounded,
};

pub const RequestHeader = struct {
    image_len: usize,
    input_len: ?usize = null,
    policy: SandboxPolicy = .{},
    input_schema: ?Schema = null,
    output_schema: ?Schema = null,
    process: ProcessLimits = .{},

    pub fn bodyLen(header: RequestHeader) Error!usize {
        return checkedBodyLength(&.{ header.image_len, header.input_len orelse 0 });
    }
};

pub const RequestBody = struct {
    image: []const u8,
    input: ?[]const u8,
};

pub const Outcome = enum(u8) {
    value = 0,
    ruby_exception = 1,
    limit = 2,
    artifact_rejected = 3,
    worker_error = 4,
};

pub const Phase = enum(u8) {
    none = 0,
    bootstrap = 1,
    input = 2,
    execute = 3,
    output = 4,
};

/// Stable semantic detail codes. `outcome` supplies the broad category and
/// `phase` identifies where the failure occurred.
pub const Detail = enum(u16) {
    none = 0,
    invalid_request = 1,
    out_of_memory = 2,
    conflicting_gas_policy = 3,
    capability_application_failed = 4,
    invalid_artifact = 10,
    checksum_mismatch = 11,
    unsupported_artifact_version = 12,
    artifact_limit_exceeded = 13,
    incompatible_rite_image = 14,
    schema_mismatch = 15,
    capsule_limit_exceeded = 16,
    ruby_exception = 20,
    script_terminated = 21,
    deadline_exceeded = 22,
    gas_exhausted = 23,
    memory_limit_exceeded = 24,
    call_depth_exceeded = 25,
    foreign_value = 30,
    unsupported_value = 31,
    unsupported_container_state = 32,
    unsupported_hash_key = 33,
    numeric_out_of_range = 34,
    artifact_construction_failed = 35,
    hard_memory_limit_unavailable = 40,
    process_limit_setup_failed = 41,
    address_space_exceeded = 42,
    internal_error = 255,
};

pub const GasScope = enum(u8) {
    isolate = 1,
    execution = 2,
};

pub const GasStats = struct {
    scope: GasScope,
    generation: u64,
    limit: u64,
    used: u64,
    remaining: u64,
    exhausted: bool,
    observed_instructions: u128,
};

pub const SandboxStats = struct {
    instructions: u64,
    gas: ?GasStats = null,
    peak_memory_bytes: usize,
    live_memory_bytes: usize,
    peak_call_depth: u32,
    live_objects: usize,
    wall_time_ns: u64,
    soft_memory_limit_hit: bool,
    hard_memory_limit_hit: bool,
};

pub const ResponseHeader = struct {
    outcome: Outcome,
    phase: Phase = .none,
    detail: Detail = .none,
    value_len: usize = 0,
    exception_class_len: usize = 0,
    exception_message_len: usize = 0,
    diagnostic_path_len: usize = 0,
    exception_truncated: bool = false,
    diagnostic_path_truncated: bool = false,
    stats: ?SandboxStats = null,

    pub fn bodyLen(header: ResponseHeader) Error!usize {
        return checkedBodyLength(&.{
            header.value_len,
            header.exception_class_len,
            header.exception_message_len,
            header.diagnostic_path_len,
        });
    }
};

pub const ResponseBody = struct {
    value: []const u8,
    exception_class: []const u8,
    exception_message: []const u8,
    diagnostic_path: []const u8,
};

const request_optional = struct {
    const input: u16 = 1 << 0;
    const sandbox_wall_time: u16 = 1 << 1;
    const memory: u16 = 1 << 2;
    const hard_memory: u16 = 1 << 3;
    const call_depth: u16 = 1 << 4;
    const random_seed: u16 = 1 << 5;
    const clock_epoch: u16 = 1 << 6;
    const application: u16 = 1 << 7;
    const input_schema: u16 = 1 << 8;
    const output_schema: u16 = 1 << 9;
    const known: u16 = (1 << 10) - 1;
};

const capability_flag = struct {
    const eval: u8 = 1 << 0;
    const send: u8 = 1 << 1;
    const introspection: u8 = 1 << 2;
    const object_space: u8 = 1 << 3;
    const freeze_object_model: u8 = 1 << 4;
    const known: u8 = (1 << 5) - 1;
};

const stats_flag = struct {
    const present: u8 = 1 << 0;
    const gas_present: u8 = 1 << 1;
    const gas_exhausted: u8 = 1 << 2;
    const soft_memory_limit_hit: u8 = 1 << 3;
    const hard_memory_limit_hit: u8 = 1 << 4;
    const exception_truncated: u8 = 1 << 5;
    const diagnostic_path_truncated: u8 = 1 << 6;
    const stats_known: u8 = (1 << 5) - 1;
    const known: u8 = (1 << 7) - 1;
};

const request_offset = struct {
    const image_len = 24;
    const input_len = 32;
    const max_rite_bytes = 40;
    const capsule_max_encoded_bytes = 48;
    const capsule_max_nodes = 56;
    const capsule_max_total_edges = 64;
    const capsule_max_depth = 72;
    const capsule_max_string_bytes = 80;
    const capsule_max_symbol_bytes = 88;
    const gas_limit = 96;
    const sandbox_wall_time_ns = 104;
    const memory_bytes = 112;
    const hard_memory_bytes = 120;
    const random_seed = 128;
    const clock_epoch_s = 136;
    const process_wall_time_ns = 144;
    const process_address_space_bytes = 152;
    const application = 160;
    const input_schema_id = 192;
    const output_schema_id = 208;
    const optional_flags = 224;
    const call_depth = 226;
    const cpu_seconds = 230;
    const input_schema_major = 234;
    const input_schema_minor = 236;
    const output_schema_major = 238;
    const output_schema_minor = 240;
    const gas_mode = 242;
    const capability_flags = 243;
    const address_space_mode = 244;
    const reserved = 245;
};

const response_offset = struct {
    const value_len = 24;
    const exception_class_len = 32;
    const exception_message_len = 40;
    const diagnostic_path_len = 48;
    const instructions = 56;
    const gas_generation = 64;
    const gas_limit = 72;
    const gas_used = 80;
    const gas_remaining = 88;
    const gas_observed_hi = 96;
    const gas_observed_lo = 104;
    const peak_memory_bytes = 112;
    const live_memory_bytes = 120;
    const live_objects = 128;
    const wall_time_ns = 136;
    const outcome = 144;
    const phase = 145;
    const detail = 146;
    const stats_flags = 148;
    const gas_scope = 149;
    const reserved_a = 150;
    const peak_call_depth = 152;
    const reserved_b = 156;
};

pub fn decodePrefix(bytes: []const u8) Error!Prefix {
    if (bytes.len < common_prefix_len) return error.TruncatedHeader;
    if (!std.mem.eql(u8, bytes[0..magic.len], &magic)) return error.InvalidMagic;
    if (getU16(bytes[8..10]) != version_major or getU16(bytes[10..12]) != version_minor) {
        return error.UnsupportedVersion;
    }
    const kind: MessageKind = switch (bytes[12]) {
        @backingInt(MessageKind.request) => .request,
        @backingInt(MessageKind.response) => .response,
        else => return error.UnknownEnumValue,
    };
    if (bytes[13] != 0) return error.UnknownFlags;
    const body_len = try wireToUsize(getU64(bytes[16..24]));
    if (body_len > max_body_len) return error.BodyTooLarge;
    return .{
        .kind = kind,
        .header_len = getU16(bytes[14..16]),
        .body_len = body_len,
    };
}

pub fn encodeRequest(header: RequestHeader) Error![request_header_len]u8 {
    const body_len = try validateRequest(header);
    var bytes: [request_header_len]u8 = @splat(0);
    try encodePrefix(&bytes, .request, request_header_len, body_len);

    putU64(bytes[request_offset.image_len..][0..8], try usizeToWire(header.image_len));
    putU64(bytes[request_offset.input_len..][0..8], try usizeToWire(header.input_len orelse 0));
    putU64(bytes[request_offset.max_rite_bytes..][0..8], try usizeToWire(header.policy.artifacts.max_rite_bytes));
    putU64(bytes[request_offset.capsule_max_encoded_bytes..][0..8], try usizeToWire(header.policy.artifacts.capsule.max_encoded_bytes));
    putU64(bytes[request_offset.capsule_max_nodes..][0..8], try usizeToWire(header.policy.artifacts.capsule.max_nodes));
    putU64(bytes[request_offset.capsule_max_total_edges..][0..8], try usizeToWire(header.policy.artifacts.capsule.max_total_edges));
    putU64(bytes[request_offset.capsule_max_depth..][0..8], try usizeToWire(header.policy.artifacts.capsule.max_depth));
    putU64(bytes[request_offset.capsule_max_string_bytes..][0..8], try usizeToWire(header.policy.artifacts.capsule.max_string_bytes));
    putU64(bytes[request_offset.capsule_max_symbol_bytes..][0..8], try usizeToWire(header.policy.artifacts.capsule.max_symbol_bytes));

    const gas_mode: GasMode, const gas_limit: u64 = switch (header.policy.limits.gas) {
        .unlimited => .{ .unlimited, 0 },
        .per_isolate => |limit| .{ .per_isolate, limit },
        .per_execution => |limit| .{ .per_execution, limit },
    };
    bytes[request_offset.gas_mode] = @backingInt(gas_mode);
    putU64(bytes[request_offset.gas_limit..][0..8], gas_limit);

    var optional_flags: u16 = 0;
    if (header.input_len) |_| optional_flags |= request_optional.input;
    if (header.policy.limits.wall_time_ns) |value| {
        optional_flags |= request_optional.sandbox_wall_time;
        putU64(bytes[request_offset.sandbox_wall_time_ns..][0..8], value);
    }
    if (header.policy.limits.memory_bytes) |value| {
        optional_flags |= request_optional.memory;
        putU64(bytes[request_offset.memory_bytes..][0..8], try usizeToWire(value));
    }
    if (header.policy.limits.hard_memory_bytes) |value| {
        optional_flags |= request_optional.hard_memory;
        putU64(bytes[request_offset.hard_memory_bytes..][0..8], try usizeToWire(value));
    }
    if (header.policy.limits.call_depth) |value| {
        optional_flags |= request_optional.call_depth;
        putU32(bytes[request_offset.call_depth..][0..4], value);
    }
    if (header.policy.capabilities.random_seed) |value| {
        optional_flags |= request_optional.random_seed;
        putU64(bytes[request_offset.random_seed..][0..8], value);
    }
    if (header.policy.capabilities.clock_epoch_s) |value| {
        optional_flags |= request_optional.clock_epoch;
        putU64(bytes[request_offset.clock_epoch_s..][0..8], @bitCast(value));
    }
    if (header.policy.artifacts.application) |fingerprint| {
        optional_flags |= request_optional.application;
        @memcpy(bytes[request_offset.application..][0..32], &fingerprint);
    }
    if (header.input_schema) |schema| {
        optional_flags |= request_optional.input_schema;
        encodeSchema(&bytes, request_offset.input_schema_id, request_offset.input_schema_major, schema);
    }
    if (header.output_schema) |schema| {
        optional_flags |= request_optional.output_schema;
        encodeSchema(&bytes, request_offset.output_schema_id, request_offset.output_schema_major, schema);
    }
    putU16(bytes[request_offset.optional_flags..][0..2], optional_flags);

    var capabilities: u8 = 0;
    if (header.policy.capabilities.eval) capabilities |= capability_flag.eval;
    if (header.policy.capabilities.send) capabilities |= capability_flag.send;
    if (header.policy.capabilities.introspection) capabilities |= capability_flag.introspection;
    if (header.policy.capabilities.object_space) capabilities |= capability_flag.object_space;
    if (header.policy.capabilities.freeze_object_model) capabilities |= capability_flag.freeze_object_model;
    bytes[request_offset.capability_flags] = capabilities;

    putU64(bytes[request_offset.process_wall_time_ns..][0..8], header.process.wall_time_ns);
    putU32(bytes[request_offset.cpu_seconds..][0..4], header.process.cpu_seconds);
    switch (header.process.address_space) {
        .unbounded => bytes[request_offset.address_space_mode] = @backingInt(AddressSpaceMode.unbounded),
        .bytes => |value| {
            bytes[request_offset.address_space_mode] = @backingInt(AddressSpaceMode.bytes);
            putU64(bytes[request_offset.process_address_space_bytes..][0..8], try usizeToWire(value));
        },
    }
    return bytes;
}

pub fn decodeRequest(bytes: []const u8) Error!RequestHeader {
    if (bytes.len < request_header_len) return error.TruncatedHeader;
    if (bytes.len != request_header_len) return error.InvalidHeaderLength;
    const prefix = try decodePrefix(bytes);
    if (prefix.kind != .request) return error.UnexpectedMessageKind;
    if (prefix.header_len != request_header_len) return error.InvalidHeaderLength;
    if (!allZero(bytes[request_offset.reserved..request_header_len])) return error.NonZeroReserved;

    const optional_flags = getU16(bytes[request_offset.optional_flags..][0..2]);
    if (optional_flags & ~request_optional.known != 0) return error.UnknownFlags;
    const capability_flags = bytes[request_offset.capability_flags];
    if (capability_flags & ~capability_flag.known != 0) return error.UnknownFlags;

    const image_len = try wireToUsize(getU64(bytes[request_offset.image_len..][0..8]));
    if (image_len == 0) return error.InvalidField;
    const input_len_raw = try wireToUsize(getU64(bytes[request_offset.input_len..][0..8]));
    const input_len: ?usize = if (has(optional_flags, request_optional.input)) blk: {
        if (input_len_raw == 0) return error.InconsistentLengths;
        break :blk input_len_raw;
    } else blk: {
        if (input_len_raw != 0) return error.InconsistentLengths;
        break :blk null;
    };

    const gas_limit = getU64(bytes[request_offset.gas_limit..][0..8]);
    const gas: GasLimit = switch (bytes[request_offset.gas_mode]) {
        @backingInt(GasMode.unlimited) => blk: {
            if (gas_limit != 0) return error.InvalidField;
            break :blk .unlimited;
        },
        @backingInt(GasMode.per_isolate) => .{ .per_isolate = gas_limit },
        @backingInt(GasMode.per_execution) => .{ .per_execution = gas_limit },
        else => return error.UnknownEnumValue,
    };

    const input_schema = try decodeOptionalSchema(
        bytes,
        optional_flags,
        request_optional.input_schema,
        request_offset.input_schema_id,
        request_offset.input_schema_major,
    );
    if (input_schema != null and input_len == null) return error.InvalidField;
    const output_schema = try decodeOptionalSchema(
        bytes,
        optional_flags,
        request_optional.output_schema,
        request_offset.output_schema_id,
        request_offset.output_schema_major,
    );

    const application: ?[32]u8 = if (has(optional_flags, request_optional.application)) blk: {
        var result: [32]u8 = undefined;
        @memcpy(&result, bytes[request_offset.application..][0..32]);
        break :blk result;
    } else blk: {
        if (!allZero(bytes[request_offset.application..][0..32])) return error.InvalidField;
        break :blk null;
    };

    const address_space_raw = try wireToUsize(getU64(bytes[request_offset.process_address_space_bytes..][0..8]));
    const address_space: AddressSpaceLimit = switch (bytes[request_offset.address_space_mode]) {
        @backingInt(AddressSpaceMode.unbounded) => blk: {
            if (address_space_raw != 0) return error.InvalidField;
            break :blk .unbounded;
        },
        @backingInt(AddressSpaceMode.bytes) => .{ .bytes = address_space_raw },
        else => return error.UnknownEnumValue,
    };

    const header: RequestHeader = .{
        .image_len = image_len,
        .input_len = input_len,
        .policy = .{
            .limits = .{
                .gas = gas,
                .wall_time_ns = try optionalU64(bytes, optional_flags, request_optional.sandbox_wall_time, request_offset.sandbox_wall_time_ns),
                .memory_bytes = try optionalUsize(bytes, optional_flags, request_optional.memory, request_offset.memory_bytes),
                .hard_memory_bytes = try optionalUsize(bytes, optional_flags, request_optional.hard_memory, request_offset.hard_memory_bytes),
                .call_depth = try optionalU32(bytes, optional_flags, request_optional.call_depth, request_offset.call_depth),
            },
            .capabilities = .{
                .eval = capability_flags & capability_flag.eval != 0,
                .send = capability_flags & capability_flag.send != 0,
                .introspection = capability_flags & capability_flag.introspection != 0,
                .object_space = capability_flags & capability_flag.object_space != 0,
                .freeze_object_model = capability_flags & capability_flag.freeze_object_model != 0,
                .random_seed = try optionalU64(bytes, optional_flags, request_optional.random_seed, request_offset.random_seed),
                .clock_epoch_s = try optionalI64(bytes, optional_flags, request_optional.clock_epoch, request_offset.clock_epoch_s),
            },
            .artifacts = .{
                .max_rite_bytes = try wireToUsize(getU64(bytes[request_offset.max_rite_bytes..][0..8])),
                .capsule = .{
                    .max_encoded_bytes = try wireToUsize(getU64(bytes[request_offset.capsule_max_encoded_bytes..][0..8])),
                    .max_nodes = try wireToUsize(getU64(bytes[request_offset.capsule_max_nodes..][0..8])),
                    .max_total_edges = try wireToUsize(getU64(bytes[request_offset.capsule_max_total_edges..][0..8])),
                    .max_depth = try wireToUsize(getU64(bytes[request_offset.capsule_max_depth..][0..8])),
                    .max_string_bytes = try wireToUsize(getU64(bytes[request_offset.capsule_max_string_bytes..][0..8])),
                    .max_symbol_bytes = try wireToUsize(getU64(bytes[request_offset.capsule_max_symbol_bytes..][0..8])),
                },
                .application = application,
            },
        },
        .input_schema = input_schema,
        .output_schema = output_schema,
        .process = .{
            .wall_time_ns = getU64(bytes[request_offset.process_wall_time_ns..][0..8]),
            .cpu_seconds = getU32(bytes[request_offset.cpu_seconds..][0..4]),
            .address_space = address_space,
        },
    };
    const body_len = try validateRequest(header);
    if (body_len != prefix.body_len) return error.InconsistentLengths;
    return header;
}

pub fn splitRequestBody(header: RequestHeader, body: []const u8) Error!RequestBody {
    const expected = try validateRequest(header);
    if (body.len != expected) return error.InconsistentLengths;
    const input_start = header.image_len;
    return .{
        .image = body[0..input_start],
        .input = if (header.input_len) |len| body[input_start..][0..len] else null,
    };
}

pub fn encodeResponse(header: ResponseHeader) Error![response_header_len]u8 {
    const body_len = try validateResponse(header);
    var bytes: [response_header_len]u8 = @splat(0);
    try encodePrefix(&bytes, .response, response_header_len, body_len);

    putU64(bytes[response_offset.value_len..][0..8], try usizeToWire(header.value_len));
    putU64(bytes[response_offset.exception_class_len..][0..8], try usizeToWire(header.exception_class_len));
    putU64(bytes[response_offset.exception_message_len..][0..8], try usizeToWire(header.exception_message_len));
    putU64(bytes[response_offset.diagnostic_path_len..][0..8], try usizeToWire(header.diagnostic_path_len));
    bytes[response_offset.outcome] = @backingInt(header.outcome);
    bytes[response_offset.phase] = @backingInt(header.phase);
    putU16(bytes[response_offset.detail..][0..2], @backingInt(header.detail));

    var flags: u8 = 0;
    if (header.exception_truncated) flags |= stats_flag.exception_truncated;
    if (header.diagnostic_path_truncated) flags |= stats_flag.diagnostic_path_truncated;
    if (header.stats) |stats| {
        flags |= stats_flag.present;
        putU64(bytes[response_offset.instructions..][0..8], stats.instructions);
        putU64(bytes[response_offset.peak_memory_bytes..][0..8], try usizeToWire(stats.peak_memory_bytes));
        putU64(bytes[response_offset.live_memory_bytes..][0..8], try usizeToWire(stats.live_memory_bytes));
        putU64(bytes[response_offset.live_objects..][0..8], try usizeToWire(stats.live_objects));
        putU64(bytes[response_offset.wall_time_ns..][0..8], stats.wall_time_ns);
        putU32(bytes[response_offset.peak_call_depth..][0..4], stats.peak_call_depth);
        if (stats.soft_memory_limit_hit) flags |= stats_flag.soft_memory_limit_hit;
        if (stats.hard_memory_limit_hit) flags |= stats_flag.hard_memory_limit_hit;
        if (stats.gas) |gas| {
            flags |= stats_flag.gas_present;
            if (gas.exhausted) flags |= stats_flag.gas_exhausted;
            bytes[response_offset.gas_scope] = @backingInt(gas.scope);
            putU64(bytes[response_offset.gas_generation..][0..8], gas.generation);
            putU64(bytes[response_offset.gas_limit..][0..8], gas.limit);
            putU64(bytes[response_offset.gas_used..][0..8], gas.used);
            putU64(bytes[response_offset.gas_remaining..][0..8], gas.remaining);
            putU64(bytes[response_offset.gas_observed_hi..][0..8], @intCast(gas.observed_instructions >> 64));
            putU64(bytes[response_offset.gas_observed_lo..][0..8], @truncate(gas.observed_instructions));
        }
    }
    bytes[response_offset.stats_flags] = flags;
    return bytes;
}

pub fn decodeResponse(bytes: []const u8) Error!ResponseHeader {
    if (bytes.len < response_header_len) return error.TruncatedHeader;
    if (bytes.len != response_header_len) return error.InvalidHeaderLength;
    const prefix = try decodePrefix(bytes);
    if (prefix.kind != .response) return error.UnexpectedMessageKind;
    if (prefix.header_len != response_header_len) return error.InvalidHeaderLength;
    if (!allZero(bytes[response_offset.reserved_a..response_offset.peak_call_depth])) return error.NonZeroReserved;
    if (!allZero(bytes[response_offset.reserved_b..response_header_len])) return error.NonZeroReserved;

    const outcome: Outcome = switch (bytes[response_offset.outcome]) {
        @backingInt(Outcome.value) => .value,
        @backingInt(Outcome.ruby_exception) => .ruby_exception,
        @backingInt(Outcome.limit) => .limit,
        @backingInt(Outcome.artifact_rejected) => .artifact_rejected,
        @backingInt(Outcome.worker_error) => .worker_error,
        else => return error.UnknownEnumValue,
    };
    const phase: Phase = switch (bytes[response_offset.phase]) {
        @backingInt(Phase.none) => .none,
        @backingInt(Phase.bootstrap) => .bootstrap,
        @backingInt(Phase.input) => .input,
        @backingInt(Phase.execute) => .execute,
        @backingInt(Phase.output) => .output,
        else => return error.UnknownEnumValue,
    };
    const detail: Detail = switch (getU16(bytes[response_offset.detail..][0..2])) {
        @backingInt(Detail.none) => .none,
        @backingInt(Detail.invalid_request) => .invalid_request,
        @backingInt(Detail.out_of_memory) => .out_of_memory,
        @backingInt(Detail.conflicting_gas_policy) => .conflicting_gas_policy,
        @backingInt(Detail.capability_application_failed) => .capability_application_failed,
        @backingInt(Detail.invalid_artifact) => .invalid_artifact,
        @backingInt(Detail.checksum_mismatch) => .checksum_mismatch,
        @backingInt(Detail.unsupported_artifact_version) => .unsupported_artifact_version,
        @backingInt(Detail.artifact_limit_exceeded) => .artifact_limit_exceeded,
        @backingInt(Detail.incompatible_rite_image) => .incompatible_rite_image,
        @backingInt(Detail.schema_mismatch) => .schema_mismatch,
        @backingInt(Detail.capsule_limit_exceeded) => .capsule_limit_exceeded,
        @backingInt(Detail.ruby_exception) => .ruby_exception,
        @backingInt(Detail.script_terminated) => .script_terminated,
        @backingInt(Detail.deadline_exceeded) => .deadline_exceeded,
        @backingInt(Detail.gas_exhausted) => .gas_exhausted,
        @backingInt(Detail.memory_limit_exceeded) => .memory_limit_exceeded,
        @backingInt(Detail.call_depth_exceeded) => .call_depth_exceeded,
        @backingInt(Detail.foreign_value) => .foreign_value,
        @backingInt(Detail.unsupported_value) => .unsupported_value,
        @backingInt(Detail.unsupported_container_state) => .unsupported_container_state,
        @backingInt(Detail.unsupported_hash_key) => .unsupported_hash_key,
        @backingInt(Detail.numeric_out_of_range) => .numeric_out_of_range,
        @backingInt(Detail.artifact_construction_failed) => .artifact_construction_failed,
        @backingInt(Detail.hard_memory_limit_unavailable) => .hard_memory_limit_unavailable,
        @backingInt(Detail.process_limit_setup_failed) => .process_limit_setup_failed,
        @backingInt(Detail.address_space_exceeded) => .address_space_exceeded,
        @backingInt(Detail.internal_error) => .internal_error,
        else => return error.UnknownEnumValue,
    };

    const flags = bytes[response_offset.stats_flags];
    if (flags & ~stats_flag.known != 0) return error.UnknownFlags;
    const stats_present = flags & stats_flag.present != 0;
    if (!stats_present and flags & stats_flag.stats_known != 0) return error.InvalidStats;

    const stats: ?SandboxStats = if (stats_present) blk: {
        const gas_present = flags & stats_flag.gas_present != 0;
        const gas: ?GasStats = if (gas_present) gas_blk: {
            const scope: GasScope = switch (bytes[response_offset.gas_scope]) {
                @backingInt(GasScope.isolate) => .isolate,
                @backingInt(GasScope.execution) => .execution,
                else => return error.UnknownEnumValue,
            };
            const limit = getU64(bytes[response_offset.gas_limit..][0..8]);
            const used = getU64(bytes[response_offset.gas_used..][0..8]);
            const remaining = getU64(bytes[response_offset.gas_remaining..][0..8]);
            const exhausted = flags & stats_flag.gas_exhausted != 0;
            break :gas_blk .{
                .scope = scope,
                .generation = getU64(bytes[response_offset.gas_generation..][0..8]),
                .limit = limit,
                .used = used,
                .remaining = remaining,
                .exhausted = exhausted,
                .observed_instructions = (@as(u128, getU64(bytes[response_offset.gas_observed_hi..][0..8])) << 64) |
                    getU64(bytes[response_offset.gas_observed_lo..][0..8]),
            };
        } else gas_blk: {
            if (flags & stats_flag.gas_exhausted != 0) return error.InvalidStats;
            if (bytes[response_offset.gas_scope] != 0 or
                !allZero(bytes[response_offset.gas_generation..response_offset.peak_memory_bytes]))
            {
                return error.InvalidStats;
            }
            break :gas_blk null;
        };
        break :blk .{
            .instructions = getU64(bytes[response_offset.instructions..][0..8]),
            .gas = gas,
            .peak_memory_bytes = try wireToUsize(getU64(bytes[response_offset.peak_memory_bytes..][0..8])),
            .live_memory_bytes = try wireToUsize(getU64(bytes[response_offset.live_memory_bytes..][0..8])),
            .peak_call_depth = getU32(bytes[response_offset.peak_call_depth..][0..4]),
            .live_objects = try wireToUsize(getU64(bytes[response_offset.live_objects..][0..8])),
            .wall_time_ns = getU64(bytes[response_offset.wall_time_ns..][0..8]),
            .soft_memory_limit_hit = flags & stats_flag.soft_memory_limit_hit != 0,
            .hard_memory_limit_hit = flags & stats_flag.hard_memory_limit_hit != 0,
        };
    } else blk: {
        if (!allZero(bytes[response_offset.instructions..response_offset.outcome]) or
            bytes[response_offset.gas_scope] != 0 or
            getU32(bytes[response_offset.peak_call_depth..][0..4]) != 0)
        {
            return error.InvalidStats;
        }
        break :blk null;
    };

    const header: ResponseHeader = .{
        .outcome = outcome,
        .phase = phase,
        .detail = detail,
        .value_len = try wireToUsize(getU64(bytes[response_offset.value_len..][0..8])),
        .exception_class_len = try wireToUsize(getU64(bytes[response_offset.exception_class_len..][0..8])),
        .exception_message_len = try wireToUsize(getU64(bytes[response_offset.exception_message_len..][0..8])),
        .diagnostic_path_len = try wireToUsize(getU64(bytes[response_offset.diagnostic_path_len..][0..8])),
        .exception_truncated = flags & stats_flag.exception_truncated != 0,
        .diagnostic_path_truncated = flags & stats_flag.diagnostic_path_truncated != 0,
        .stats = stats,
    };
    const body_len = try validateResponse(header);
    if (body_len != prefix.body_len) return error.InconsistentLengths;
    return header;
}

pub fn splitResponseBody(header: ResponseHeader, body: []const u8) Error!ResponseBody {
    const expected = try validateResponse(header);
    if (body.len != expected) return error.InconsistentLengths;
    var offset: usize = 0;
    const value = take(body, &offset, header.value_len);
    const exception_class = take(body, &offset, header.exception_class_len);
    const exception_message = take(body, &offset, header.exception_message_len);
    const diagnostic_path = take(body, &offset, header.diagnostic_path_len);
    return .{
        .value = value,
        .exception_class = exception_class,
        .exception_message = exception_message,
        .diagnostic_path = diagnostic_path,
    };
}

fn validateRequest(header: RequestHeader) Error!usize {
    const body_len = try header.bodyLen();
    if (header.image_len == 0) return error.InvalidField;
    if (header.process.wall_time_ns == 0 or header.process.cpu_seconds == 0) {
        return error.InvalidField;
    }
    switch (header.process.address_space) {
        .unbounded => {},
        .bytes => |bytes| if (bytes == 0) return error.InvalidField,
    }
    if (header.image_len > header.policy.artifacts.max_rite_bytes) {
        return error.InvalidField;
    }
    if (header.policy.artifacts.capsule.max_encoded_bytes > max_body_len) {
        return error.InvalidField;
    }
    if (header.input_len) |len| {
        if (len == 0) return error.InconsistentLengths;
        if (len > header.policy.artifacts.capsule.max_encoded_bytes) {
            return error.InvalidField;
        }
    } else if (header.input_schema != null) {
        return error.InvalidField;
    }
    return body_len;
}

fn validateResponse(header: ResponseHeader) Error!usize {
    const body_len = try header.bodyLen();
    if (header.stats) |stats| try validateStats(stats);
    switch (header.outcome) {
        .value => {
            if (header.value_len == 0 or header.exception_class_len != 0 or
                header.exception_message_len != 0 or header.diagnostic_path_len != 0)
            {
                return error.InconsistentLengths;
            }
            if (header.phase != .none or header.detail != .none or
                header.exception_truncated or header.diagnostic_path_truncated)
            {
                return error.InvalidField;
            }
        },
        .ruby_exception => {
            if (header.value_len != 0 or header.exception_class_len == 0 or
                header.diagnostic_path_len != 0)
            {
                return error.InconsistentLengths;
            }
            if (header.exception_class_len > max_exception_class_len or
                header.exception_message_len > max_exception_message_len)
            {
                return error.BodyTooLarge;
            }
            if (header.phase != .execute or header.detail != .ruby_exception or
                header.diagnostic_path_truncated)
            {
                return error.InvalidField;
            }
        },
        .limit => {
            if (body_len != 0) return error.InconsistentLengths;
            if (header.phase == .none or !isLimitDetail(header.detail) or
                header.exception_truncated or header.diagnostic_path_truncated)
            {
                return error.InvalidField;
            }
        },
        .artifact_rejected => {
            if (header.value_len != 0 or header.exception_class_len != 0 or
                header.exception_message_len != 0)
            {
                return error.InconsistentLengths;
            }
            if (header.diagnostic_path_len > max_diagnostic_path_len) {
                return error.BodyTooLarge;
            }
            if (header.phase == .none or !isArtifactDetail(header.detail) or
                header.exception_truncated or
                (header.diagnostic_path_truncated and header.diagnostic_path_len == 0))
            {
                return error.InvalidField;
            }
        },
        .worker_error => {
            if (body_len != 0) return error.InconsistentLengths;
            if (!isWorkerErrorDetail(header.detail) or
                header.exception_truncated or header.diagnostic_path_truncated)
            {
                return error.InvalidField;
            }
        },
    }
    return body_len;
}

fn validateStats(stats: SandboxStats) Error!void {
    const gas = stats.gas orelse return;
    const sum = std.math.add(u64, gas.used, gas.remaining) catch
        return error.InvalidStats;
    if (sum != gas.limit) return error.InvalidStats;
    if (gas.exhausted and gas.remaining != 0) return error.InvalidStats;
}

fn isLimitDetail(detail: Detail) bool {
    return switch (detail) {
        .script_terminated,
        .deadline_exceeded,
        .gas_exhausted,
        .memory_limit_exceeded,
        .call_depth_exceeded,
        .address_space_exceeded,
        => true,
        else => false,
    };
}

fn isArtifactDetail(detail: Detail) bool {
    return switch (detail) {
        .invalid_artifact,
        .checksum_mismatch,
        .unsupported_artifact_version,
        .artifact_limit_exceeded,
        .incompatible_rite_image,
        .schema_mismatch,
        .capsule_limit_exceeded,
        .foreign_value,
        .unsupported_value,
        .unsupported_container_state,
        .unsupported_hash_key,
        .numeric_out_of_range,
        .artifact_construction_failed,
        => true,
        else => false,
    };
}

fn isWorkerErrorDetail(detail: Detail) bool {
    return switch (detail) {
        .invalid_request,
        .out_of_memory,
        .conflicting_gas_policy,
        .capability_application_failed,
        .hard_memory_limit_unavailable,
        .process_limit_setup_failed,
        .internal_error,
        => true,
        else => false,
    };
}

fn encodePrefix(
    bytes: []u8,
    kind: MessageKind,
    header_len: usize,
    body_len: usize,
) Error!void {
    if (bytes.len < common_prefix_len) return error.TruncatedHeader;
    if (body_len > max_body_len) return error.BodyTooLarge;
    const header_len_u16 = std.math.cast(u16, header_len) orelse return error.LengthOverflow;
    @memcpy(bytes[0..magic.len], &magic);
    putU16(bytes[8..10], version_major);
    putU16(bytes[10..12], version_minor);
    bytes[12] = @backingInt(kind);
    bytes[13] = 0;
    putU16(bytes[14..16], header_len_u16);
    putU64(bytes[16..24], try usizeToWire(body_len));
}

fn checkedBodyLength(lengths: []const usize) Error!usize {
    var total: usize = 0;
    for (lengths) |len| total = std.math.add(usize, total, len) catch return error.LengthOverflow;
    if (total > max_body_len) return error.BodyTooLarge;
    return total;
}

fn optionalU64(bytes: []const u8, flags: u16, flag: u16, offset: usize) Error!?u64 {
    const value = getU64(bytes[offset..][0..8]);
    if (has(flags, flag)) return value;
    if (value != 0) return error.InvalidField;
    return null;
}

fn optionalI64(bytes: []const u8, flags: u16, flag: u16, offset: usize) Error!?i64 {
    const value = try optionalU64(bytes, flags, flag, offset);
    return if (value) |present| @bitCast(present) else null;
}

fn optionalUsize(bytes: []const u8, flags: u16, flag: u16, offset: usize) Error!?usize {
    const value = try optionalU64(bytes, flags, flag, offset);
    return if (value) |present| try wireToUsize(present) else null;
}

fn optionalU32(bytes: []const u8, flags: u16, flag: u16, offset: usize) Error!?u32 {
    const value = getU32(bytes[offset..][0..4]);
    if (has(flags, flag)) return value;
    if (value != 0) return error.InvalidField;
    return null;
}

fn encodeSchema(bytes: []u8, id_offset: usize, version_offset: usize, schema: Schema) void {
    @memcpy(bytes[id_offset..][0..16], &schema.id);
    putU16(bytes[version_offset..][0..2], schema.major);
    putU16(bytes[version_offset + 2 ..][0..2], schema.minor);
}

fn decodeOptionalSchema(
    bytes: []const u8,
    flags: u16,
    flag: u16,
    id_offset: usize,
    version_offset: usize,
) Error!?Schema {
    if (!has(flags, flag)) {
        if (!allZero(bytes[id_offset..][0..16]) or !allZero(bytes[version_offset..][0..4])) {
            return error.InvalidField;
        }
        return null;
    }
    var id: [16]u8 = undefined;
    @memcpy(&id, bytes[id_offset..][0..16]);
    return .{
        .id = id,
        .major = getU16(bytes[version_offset..][0..2]),
        .minor = getU16(bytes[version_offset + 2 ..][0..2]),
    };
}

fn take(bytes: []const u8, offset: *usize, len: usize) []const u8 {
    const start = offset.*;
    offset.* += len;
    return bytes[start..offset.*];
}

fn has(flags: u16, flag: u16) bool {
    return flags & flag != 0;
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn usizeToWire(value: usize) Error!u64 {
    return std.math.cast(u64, value) orelse error.LengthOverflow;
}

fn wireToUsize(value: u64) Error!usize {
    return std.math.cast(usize, value) orelse error.LengthOverflow;
}

fn putU16(bytes: []u8, value: u16) void {
    bytes[0] = @truncate(value >> 8);
    bytes[1] = @truncate(value);
}

fn putU32(bytes: []u8, value: u32) void {
    bytes[0] = @truncate(value >> 24);
    bytes[1] = @truncate(value >> 16);
    bytes[2] = @truncate(value >> 8);
    bytes[3] = @truncate(value);
}

fn putU64(bytes: []u8, value: u64) void {
    inline for (0..8) |i| bytes[i] = @truncate(value >> @intCast(56 - 8 * i));
}

fn getU16(bytes: []const u8) u16 {
    return (@as(u16, bytes[0]) << 8) | bytes[1];
}

fn getU32(bytes: []const u8) u32 {
    return (@as(u32, bytes[0]) << 24) |
        (@as(u32, bytes[1]) << 16) |
        (@as(u32, bytes[2]) << 8) |
        bytes[3];
}

fn getU64(bytes: []const u8) u64 {
    var result: u64 = 0;
    for (bytes[0..8]) |byte| result = (result << 8) | byte;
    return result;
}

test "request header round trips every field" {
    const header: RequestHeader = .{
        .image_len = 1234,
        .input_len = 567,
        .policy = .{
            .limits = .{
                .gas = .{ .per_execution = 99_999 },
                .wall_time_ns = 4567,
                .memory_bytes = 10_000,
                .hard_memory_bytes = 20_000,
                .call_depth = 42,
            },
            .capabilities = .{
                .eval = true,
                .send = true,
                .introspection = true,
                .object_space = true,
                .freeze_object_model = true,
                .random_seed = 0xfeed_beef,
                .clock_epoch_s = -123,
            },
            .artifacts = .{
                .max_rite_bytes = 2_000_000,
                .capsule = .{
                    .max_encoded_bytes = 1_000_000,
                    .max_nodes = 222,
                    .max_total_edges = 333,
                    .max_depth = 44,
                    .max_string_bytes = 555,
                    .max_symbol_bytes = 66,
                },
                .application = @splat(0xa5),
            },
        },
        .input_schema = .{ .id = @splat(0x11), .major = 2, .minor = 3 },
        .output_schema = .{ .id = @splat(0x22), .major = 4, .minor = 5 },
        .process = .{
            .wall_time_ns = 8_000_000,
            .cpu_seconds = 7,
            .address_space = .{ .bytes = 64 * 1024 * 1024 },
        },
    };
    const encoded = try encodeRequest(header);
    try std.testing.expectEqualSlices(u8, &magic, encoded[0..magic.len]);
    try std.testing.expectEqual(request_header_len, getU16(encoded[14..16]));
    try std.testing.expectEqualDeep(header, try decodeRequest(&encoded));
}

test "response header round trips outcome stats and component lengths" {
    const header: ResponseHeader = .{
        .outcome = .ruby_exception,
        .phase = .execute,
        .detail = .ruby_exception,
        .exception_class_len = 12,
        .exception_message_len = 34,
        .stats = .{
            .instructions = 1000,
            .gas = .{
                .scope = .execution,
                .generation = 3,
                .limit = 500,
                .used = 450,
                .remaining = 50,
                .exhausted = false,
                .observed_instructions = (@as(u128, 9) << 64) | 10,
            },
            .peak_memory_bytes = 2048,
            .live_memory_bytes = 1024,
            .peak_call_depth = 17,
            .live_objects = 88,
            .wall_time_ns = 123_456,
            .soft_memory_limit_hit = true,
            .hard_memory_limit_hit = false,
        },
    };
    const encoded = try encodeResponse(header);
    try std.testing.expectEqualDeep(header, try decodeResponse(&encoded));
}

test "split helpers enforce exact component lengths" {
    const request: RequestHeader = .{ .image_len = 3, .input_len = 2 };
    const request_parts = try splitRequestBody(request, "abcde");
    try std.testing.expectEqualStrings("abc", request_parts.image);
    try std.testing.expectEqualStrings("de", request_parts.input.?);
    try std.testing.expectError(error.InconsistentLengths, splitRequestBody(request, "abcd"));

    const response: ResponseHeader = .{
        .outcome = .ruby_exception,
        .phase = .execute,
        .detail = .ruby_exception,
        .exception_class_len = 1,
        .exception_message_len = 2,
    };
    const response_parts = try splitResponseBody(response, "abc");
    try std.testing.expectEqualStrings("a", response_parts.exception_class);
    try std.testing.expectEqualStrings("bc", response_parts.exception_message);
    try std.testing.expectEqualStrings("", response_parts.diagnostic_path);
    try std.testing.expectError(error.InconsistentLengths, splitResponseBody(response, "ab"));
}

test "request policy bounds are enforced before body allocation" {
    try std.testing.expectError(error.InvalidField, encodeRequest(.{
        .image_len = 11,
        .policy = .{ .artifacts = .{ .max_rite_bytes = 10 } },
    }));
    try std.testing.expectError(error.InvalidField, encodeRequest(.{
        .image_len = 1,
        .input_len = 2,
        .policy = .{ .artifacts = .{
            .capsule = .{ .max_encoded_bytes = 1 },
        } },
    }));
    try std.testing.expectError(error.InvalidField, encodeRequest(.{
        .image_len = 1,
        .policy = .{ .artifacts = .{
            .capsule = .{ .max_encoded_bytes = max_body_len + 1 },
        } },
    }));
    try std.testing.expectError(error.InvalidField, encodeRequest(.{
        .image_len = 1,
        .process = .{ .wall_time_ns = 0 },
    }));
    try std.testing.expectError(error.InvalidField, encodeRequest(.{
        .image_len = 1,
        .process = .{ .cpu_seconds = 0 },
    }));
    try std.testing.expectError(error.InvalidField, encodeRequest(.{
        .image_len = 1,
        .process = .{ .address_space = .{ .bytes = 0 } },
    }));
}

test "decode rejects truncated malformed unknown and reserved headers" {
    const valid = try encodeRequest(.{ .image_len = 10 });
    try std.testing.expectError(error.TruncatedHeader, decodeRequest(valid[0 .. valid.len - 1]));

    var malformed = valid;
    malformed[0] ^= 1;
    try std.testing.expectError(error.InvalidMagic, decodeRequest(&malformed));

    malformed = valid;
    malformed[10] = 1;
    try std.testing.expectError(error.UnsupportedVersion, decodeRequest(&malformed));

    malformed = valid;
    malformed[request_offset.gas_mode] = 99;
    try std.testing.expectError(error.UnknownEnumValue, decodeRequest(&malformed));

    malformed = valid;
    malformed[13] = 0x80;
    try std.testing.expectError(error.UnknownFlags, decodeRequest(&malformed));

    malformed = valid;
    malformed[request_offset.optional_flags] = 0x80;
    try std.testing.expectError(error.UnknownFlags, decodeRequest(&malformed));

    malformed = valid;
    malformed[request_offset.reserved] = 1;
    try std.testing.expectError(error.NonZeroReserved, decodeRequest(&malformed));
}

test "decode rejects inconsistent oversized and overflowing body lengths" {
    const valid = try encodeRequest(.{ .image_len = 10 });
    var malformed = valid;
    putU64(malformed[16..24], 9);
    try std.testing.expectError(error.InconsistentLengths, decodeRequest(&malformed));

    malformed = valid;
    putU64(malformed[request_offset.image_len..][0..8], max_body_len + 1);
    putU64(malformed[16..24], max_body_len + 1);
    try std.testing.expectError(error.BodyTooLarge, decodeRequest(&malformed));

    malformed = valid;
    putU64(malformed[request_offset.image_len..][0..8], std.math.maxInt(u64));
    putU64(malformed[request_offset.input_len..][0..8], 1);
    var flags = getU16(malformed[request_offset.optional_flags..][0..2]);
    flags |= request_optional.input;
    putU16(malformed[request_offset.optional_flags..][0..2], flags);
    putU64(malformed[16..24], 0);
    try std.testing.expectError(error.LengthOverflow, decodeRequest(&malformed));
}

test "response rejects unknown enums flags reserved and inconsistent lengths" {
    const valid = try encodeResponse(.{ .outcome = .worker_error, .detail = .internal_error });
    var malformed = valid;
    malformed[response_offset.outcome] = 99;
    try std.testing.expectError(error.UnknownEnumValue, decodeResponse(&malformed));

    malformed = valid;
    malformed[response_offset.stats_flags] = 0x80;
    try std.testing.expectError(error.UnknownFlags, decodeResponse(&malformed));

    malformed = valid;
    malformed[response_offset.reserved_b] = 1;
    try std.testing.expectError(error.NonZeroReserved, decodeResponse(&malformed));

    malformed = valid;
    putU64(malformed[response_offset.exception_message_len..][0..8], 1);
    try std.testing.expectError(error.InconsistentLengths, decodeResponse(&malformed));
}

test "response rejects outcome-inconsistent metadata" {
    try std.testing.expectError(error.InconsistentLengths, encodeResponse(.{
        .outcome = .value,
    }));
    try std.testing.expectError(error.InvalidField, encodeResponse(.{
        .outcome = .ruby_exception,
        .phase = .none,
        .detail = .ruby_exception,
        .exception_class_len = 1,
    }));
    try std.testing.expectError(error.InvalidField, encodeResponse(.{
        .outcome = .limit,
        .phase = .execute,
        .detail = .schema_mismatch,
    }));
    try std.testing.expectError(error.InvalidField, encodeResponse(.{
        .outcome = .artifact_rejected,
        .phase = .output,
        .detail = .unsupported_value,
        .diagnostic_path_truncated = true,
    }));
    try std.testing.expectError(error.InvalidField, encodeResponse(.{
        .outcome = .worker_error,
        .detail = .none,
    }));
}

test "response bounds diagnostics and validates gas before encoding" {
    try std.testing.expectError(error.BodyTooLarge, encodeResponse(.{
        .outcome = .ruby_exception,
        .phase = .execute,
        .detail = .ruby_exception,
        .exception_class_len = max_exception_class_len + 1,
    }));
    try std.testing.expectError(error.BodyTooLarge, encodeResponse(.{
        .outcome = .artifact_rejected,
        .phase = .output,
        .detail = .unsupported_value,
        .diagnostic_path_len = max_diagnostic_path_len + 1,
    }));
    try std.testing.expectError(error.InvalidStats, encodeResponse(.{
        .outcome = .limit,
        .phase = .execute,
        .detail = .gas_exhausted,
        .stats = .{
            .instructions = 1,
            .gas = .{
                .scope = .execution,
                .generation = 1,
                .limit = 10,
                .used = 9,
                .remaining = 9,
                .exhausted = false,
                .observed_instructions = 9,
            },
            .peak_memory_bytes = 0,
            .live_memory_bytes = 0,
            .peak_call_depth = 0,
            .live_objects = 0,
            .wall_time_ns = 0,
            .soft_memory_limit_hit = false,
            .hard_memory_limit_hit = false,
        },
    }));
}

test "address-space limit response round trips" {
    const header: ResponseHeader = .{
        .outcome = .limit,
        .phase = .execute,
        .detail = .address_space_exceeded,
    };
    const encoded = try encodeResponse(header);
    try std.testing.expectEqualDeep(header, try decodeResponse(&encoded));
}
