//! Stable byte artifacts shared by sandbox compilation and value transfer.
//!
//! This module deliberately has no dependency on `Vm`, `Value`, or mruby's C
//! interface. It owns byte framing, compatibility metadata, limits, and the
//! primitive StateCapsule grammar. Operations which inspect or construct Ruby
//! objects remain on `sandbox.Isolate`.

const std = @import("std");

pub const envelope_magic = [_]u8{ 'M', 'R', 'Z', 'A', 'R', 'T', 'F', 0 };
pub const envelope_header_len: usize = 128;
pub const format_major: u16 = 1;
pub const format_minor: u16 = 0;
pub const checksum_len: usize = 32;
pub const metadata_len: usize = 64;
pub const checksum_domain = "mruby-zig/artifact-checksum/v1\x00";

pub const offsets = struct {
    pub const magic = 0;
    pub const major = 8;
    pub const minor = 10;
    pub const kind = 12;
    pub const flags = 13;
    pub const header_len = 14;
    pub const payload_len = 16;
    pub const metadata = 24;
    pub const checksum = 88;
    pub const reserved = 120;
};

pub const Kind = enum(u8) {
    rite = 1,
    state_capsule = 2,
};

pub const FramingError = error{
    InvalidArtifact,
    ChecksumMismatch,
    UnsupportedArtifactVersion,
    ArtifactLimitExceeded,
};

pub const RiteValidationError = FramingError || error{IncompatibleRiteImage};
pub const StateValidationError = FramingError || error{SchemaMismatch};

/// Domain-separated digest of the embedding application's bootstrap contract.
pub const ApplicationFingerprint = struct {
    bytes: [32]u8,

    pub fn eql(a: ApplicationFingerprint, b: ApplicationFingerprint) bool {
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }
};

pub const Schema = struct {
    id: [16]u8,
    major: u16,
    minor: u16 = 0,

    /// Whether this accepted schema can decode a capsule produced by `other`.
    pub fn accepts(self: Schema, other: Schema) bool {
        return std.mem.eql(u8, &self.id, &other.id) and
            self.major == other.major and other.minor <= self.minor;
    }
};

pub const CapsuleLimits = struct {
    max_encoded_bytes: usize = 16 * 1024 * 1024,
    max_nodes: usize = 100_000,
    max_total_edges: usize = 500_000,
    max_depth: usize = 256,
    max_string_bytes: usize = 8 * 1024 * 1024,
    max_symbol_bytes: usize = 1024 * 1024,

    /// Component-wise minimum. Per-operation limits may tighten policy but can
    /// never use this operation to relax it.
    pub fn tightened(self: CapsuleLimits, requested: ?CapsuleLimits) CapsuleLimits {
        const other = requested orelse return self;
        return .{
            .max_encoded_bytes = @min(self.max_encoded_bytes, other.max_encoded_bytes),
            .max_nodes = @min(self.max_nodes, other.max_nodes),
            .max_total_edges = @min(self.max_total_edges, other.max_total_edges),
            .max_depth = @min(self.max_depth, other.max_depth),
            .max_string_bytes = @min(self.max_string_bytes, other.max_string_bytes),
            .max_symbol_bytes = @min(self.max_symbol_bytes, other.max_symbol_bytes),
        };
    }
};

pub const Limits = struct {
    max_rite_bytes: usize = 16 * 1024 * 1024,
    capsule: CapsuleLimits = .{},
};

pub const Acceptance = struct {
    limits: Limits = .{},
    application: ?ApplicationFingerprint = null,
};

/// Borrowed, untrusted bytes. Validation occurs on every consumption.
pub const RiteImageView = struct {
    bytes: []const u8,
};

pub const RiteImage = struct {
    encoded: []u8,

    pub fn view(self: *const RiteImage) RiteImageView {
        return .{ .bytes = self.encoded };
    }

    pub fn deinit(self: *RiteImage, allocator: std.mem.Allocator) void {
        allocator.free(self.encoded);
        self.* = undefined;
    }
};

/// Borrowed, untrusted bytes. Validation occurs on every consumption.
pub const StateCapsuleView = struct {
    bytes: []const u8,
};

pub const StateCapsule = struct {
    encoded: []u8,

    pub fn view(self: *const StateCapsule) StateCapsuleView {
        return .{ .bytes = self.encoded };
    }

    pub fn deinit(self: *StateCapsule, allocator: std.mem.Allocator) void {
        allocator.free(self.encoded);
        self.* = undefined;
    }
};

/// A fully checked common envelope. Kind-specific metadata has not necessarily
/// been interpreted; prefer `validateRite` or `validateState` at trust seams.
pub const Envelope = struct {
    kind: Kind,
    flags: u8,
    metadata: [metadata_len]u8,
    payload: []const u8,
};

pub const ParseEnvelopeOptions = struct {
    max_encoded_bytes: usize = std.math.maxInt(usize),
};

pub fn encodedLength(payload_len: usize) FramingError!usize {
    if (payload_len > std.math.maxInt(usize) - envelope_header_len) {
        return error.ArtifactLimitExceeded;
    }
    return envelope_header_len + payload_len;
}

/// Encode a complete envelope into an exactly-sized caller-owned buffer.
pub fn encodeEnvelopeInto(
    output: []u8,
    kind: Kind,
    envelope_flags: u8,
    metadata: [metadata_len]u8,
    payload: []const u8,
) FramingError!void {
    const total = try encodedLength(payload.len);
    if (output.len != total) return error.InvalidArtifact;

    @memset(output, 0);
    @memcpy(output[offsets.magic .. offsets.magic + envelope_magic.len], &envelope_magic);
    putU16(output[offsets.major..][0..2], format_major);
    putU16(output[offsets.minor..][0..2], format_minor);
    output[offsets.kind] = @backingInt(kind);
    output[offsets.flags] = envelope_flags;
    putU16(output[offsets.header_len..][0..2], @intCast(envelope_header_len));
    putU64(output[offsets.payload_len..][0..8], @intCast(payload.len));
    @memcpy(output[offsets.metadata .. offsets.metadata + metadata_len], &metadata);
    @memcpy(output[envelope_header_len..], payload);

    const digest = calculateChecksum(output[0..envelope_header_len], payload);
    @memcpy(output[offsets.checksum .. offsets.checksum + checksum_len], &digest);
}

/// Parse and checksum a common envelope using overflow-safe length checks.
pub fn parseEnvelope(
    encoded: []const u8,
    options: ParseEnvelopeOptions,
) FramingError!Envelope {
    if (encoded.len > options.max_encoded_bytes) return error.ArtifactLimitExceeded;
    if (encoded.len < envelope_header_len) return error.InvalidArtifact;
    if (!std.mem.eql(u8, encoded[offsets.magic .. offsets.magic + envelope_magic.len], &envelope_magic)) {
        return error.InvalidArtifact;
    }

    const major = getU16(encoded[offsets.major..][0..2]);
    const minor = getU16(encoded[offsets.minor..][0..2]);
    if (major != format_major or minor != format_minor) {
        return error.UnsupportedArtifactVersion;
    }
    if (getU16(encoded[offsets.header_len..][0..2]) != envelope_header_len) {
        return error.InvalidArtifact;
    }

    const kind: Kind = switch (encoded[offsets.kind]) {
        @backingInt(Kind.rite) => .rite,
        @backingInt(Kind.state_capsule) => .state_capsule,
        else => return error.InvalidArtifact,
    };

    const payload_len_u64 = getU64(encoded[offsets.payload_len..][0..8]);
    if (payload_len_u64 > std.math.maxInt(usize)) return error.InvalidArtifact;
    const payload_len: usize = @intCast(payload_len_u64);
    const total = encodedLength(payload_len) catch return error.InvalidArtifact;
    if (encoded.len != total) return error.InvalidArtifact;
    if (!allZero(encoded[offsets.reserved..envelope_header_len])) return error.InvalidArtifact;

    const expected = calculateChecksum(encoded[0..envelope_header_len], encoded[envelope_header_len..]);
    if (!std.mem.eql(u8, encoded[offsets.checksum .. offsets.checksum + checksum_len], &expected)) {
        return error.ChecksumMismatch;
    }

    var metadata: [metadata_len]u8 = undefined;
    @memcpy(&metadata, encoded[offsets.metadata .. offsets.metadata + metadata_len]);
    return .{
        .kind = kind,
        .flags = encoded[offsets.flags],
        .metadata = metadata,
        .payload = encoded[envelope_header_len..],
    };
}

pub const RiteWrapOptions = struct {
    compatibility: [32]u8,
    application: ?ApplicationFingerprint = null,
    max_encoded_bytes: usize = 16 * 1024 * 1024,
};

pub const RiteValidationOptions = struct {
    compatibility: [32]u8,
    application: ?ApplicationFingerprint = null,
    max_encoded_bytes: usize = 16 * 1024 * 1024,
};

pub const RitePayload = struct {
    bytes: []const u8,
    compatibility: [32]u8,
    application: ?ApplicationFingerprint,
};

pub fn wrapRite(
    allocator: std.mem.Allocator,
    raw_rite: []const u8,
    options: RiteWrapOptions,
) (std.mem.Allocator.Error || FramingError)!RiteImage {
    try validateRawRite(raw_rite);
    const total = try encodedLength(raw_rite.len);
    if (total > options.max_encoded_bytes) return error.ArtifactLimitExceeded;

    var metadata: [metadata_len]u8 = @splat(0);
    @memcpy(metadata[0..32], &options.compatibility);
    const envelope_flags: u8 = if (options.application) |application| blk: {
        @memcpy(metadata[32..64], &application.bytes);
        break :blk flags.application;
    } else 0;

    const encoded = try allocator.alloc(u8, total);
    errdefer allocator.free(encoded);
    try encodeEnvelopeInto(encoded, .rite, envelope_flags, metadata, raw_rite);
    return .{ .encoded = encoded };
}

/// Validate common framing, exact RITE compatibility, and the basic inner RITE
/// header. The returned payload borrows the view's backing bytes.
pub fn validateRite(
    image: RiteImageView,
    options: RiteValidationOptions,
) RiteValidationError!RitePayload {
    const envelope = try parseEnvelope(image.bytes, .{
        .max_encoded_bytes = options.max_encoded_bytes,
    });
    if (envelope.kind != .rite) return error.InvalidArtifact;
    if (envelope.flags & ~flags.application != 0) return error.InvalidArtifact;

    var compatibility: [32]u8 = undefined;
    @memcpy(&compatibility, envelope.metadata[0..32]);
    if (!std.mem.eql(u8, &compatibility, &options.compatibility)) {
        return error.IncompatibleRiteImage;
    }

    const application: ?ApplicationFingerprint = if (envelope.flags & flags.application != 0) blk: {
        var result: ApplicationFingerprint = undefined;
        @memcpy(&result.bytes, envelope.metadata[32..64]);
        break :blk result;
    } else blk: {
        if (!allZero(envelope.metadata[32..64])) return error.InvalidArtifact;
        break :blk null;
    };

    if (!optionalApplicationEql(application, options.application)) {
        return error.IncompatibleRiteImage;
    }
    try validateRawRite(envelope.payload);
    return .{
        .bytes = envelope.payload,
        .compatibility = compatibility,
        .application = application,
    };
}

pub const raw_rite_header_len: usize = 20;
pub const raw_rite_ident = "RITE";
pub const raw_rite_version = "0400";

/// Perform structural checks which are safe before passing a payload to mruby.
pub fn validateRawRite(raw_rite: []const u8) FramingError!void {
    if (raw_rite.len < raw_rite_header_len) return error.InvalidArtifact;
    if (!std.mem.eql(u8, raw_rite[0..4], raw_rite_ident)) return error.InvalidArtifact;
    if (!std.mem.eql(u8, raw_rite[4..8], raw_rite_version)) return error.InvalidArtifact;
    const declared_len = getU32(raw_rite[8..12]);
    if (declared_len != raw_rite.len) return error.InvalidArtifact;
}

pub const StateWrapOptions = struct {
    schema: ?Schema = null,
    max_encoded_bytes: usize = 16 * 1024 * 1024,
};

pub const StateValidationOptions = struct {
    accepted_schema: ?Schema = null,
    max_encoded_bytes: usize = 16 * 1024 * 1024,
};

pub const StatePayload = struct {
    bytes: []const u8,
    schema: ?Schema,
};

pub fn wrapState(
    allocator: std.mem.Allocator,
    payload: []const u8,
    options: StateWrapOptions,
) (std.mem.Allocator.Error || FramingError)!StateCapsule {
    const total = try encodedLength(payload.len);
    if (total > options.max_encoded_bytes) return error.ArtifactLimitExceeded;

    var metadata: [metadata_len]u8 = @splat(0);
    const envelope_flags: u8 = if (options.schema) |schema| blk: {
        @memcpy(metadata[0..16], &schema.id);
        putU16(metadata[16..18], schema.major);
        putU16(metadata[18..20], schema.minor);
        break :blk flags.schema;
    } else 0;

    const encoded = try allocator.alloc(u8, total);
    errdefer allocator.free(encoded);
    try encodeEnvelopeInto(encoded, .state_capsule, envelope_flags, metadata, payload);
    return .{ .encoded = encoded };
}

/// Validate common framing and schema admission. Complete graph validation is
/// deliberately performed by the StateCapsule codec before VM construction.
pub fn validateState(
    capsule: StateCapsuleView,
    options: StateValidationOptions,
) StateValidationError!StatePayload {
    const envelope = try parseEnvelope(capsule.bytes, .{
        .max_encoded_bytes = options.max_encoded_bytes,
    });
    if (envelope.kind != .state_capsule) return error.InvalidArtifact;
    if (envelope.flags & ~flags.schema != 0) return error.InvalidArtifact;

    const schema: ?Schema = if (envelope.flags & flags.schema != 0) blk: {
        if (!allZero(envelope.metadata[20..])) return error.InvalidArtifact;
        var result: Schema = undefined;
        @memcpy(&result.id, envelope.metadata[0..16]);
        result.major = getU16(envelope.metadata[16..18]);
        result.minor = getU16(envelope.metadata[18..20]);
        break :blk result;
    } else blk: {
        if (!allZero(&envelope.metadata)) return error.InvalidArtifact;
        break :blk null;
    };

    if (!optionalSchemaAccepts(options.accepted_schema, schema)) {
        return error.SchemaMismatch;
    }
    return .{ .bytes = envelope.payload, .schema = schema };
}

pub const flags = struct {
    pub const application: u8 = 1 << 0;
    pub const schema: u8 = 1 << 0;
    pub const frozen: u8 = 1 << 0;
    pub const hash_has_default: u8 = 1 << 1;
};

pub const state_prelude_fixed_len: usize = 8;
pub const node_record_header_len: usize = 12;

pub const ValueTag = enum(u8) {
    nil = 0,
    boolean_false = 1,
    boolean_true = 2,
    integer = 3,
    float = 4,
    symbol = 5,
    node_ref = 6,
};

pub const NodeKind = enum(u8) {
    string = 1,
    array = 2,
    hash = 3,
};

/// A parsed StateCapsule reference. Symbol bytes borrow the payload.
pub const ValueRef = union(ValueTag) {
    nil: void,
    boolean_false: void,
    boolean_true: void,
    integer: i64,
    float: u64,
    symbol: []const u8,
    node_ref: u32,

    pub fn encodedLen(self: ValueRef) FramingError!usize {
        return switch (self) {
            .nil, .boolean_false, .boolean_true => 1,
            .integer, .float => 9,
            .node_ref => 5,
            .symbol => |bytes| blk: {
                if (bytes.len > std.math.maxInt(u32)) return error.ArtifactLimitExceeded;
                if (bytes.len > std.math.maxInt(usize) - 5) return error.ArtifactLimitExceeded;
                break :blk 5 + bytes.len;
            },
        };
    }
};

pub const StatePrelude = struct {
    node_count: u32,
    edge_count: u32,
    root: ValueRef,
};

pub const NodeRecordHeader = struct {
    id: u32,
    kind: NodeKind,
    flags: u8,
    body_len: u32,
};

/// Bounds-checked big-endian reader used by the StateCapsule validator.
pub const Reader = struct {
    bytes: []const u8,
    offset: usize = 0,

    pub fn init(bytes: []const u8) Reader {
        return .{ .bytes = bytes };
    }

    pub fn remaining(self: Reader) usize {
        if (self.offset > self.bytes.len) return 0;
        return self.bytes.len - self.offset;
    }

    pub fn finish(self: Reader) FramingError!void {
        if (self.offset != self.bytes.len) return error.InvalidArtifact;
    }

    pub fn readByte(self: *Reader) FramingError!u8 {
        const result = try self.readBytes(1);
        return result[0];
    }

    pub fn readU16(self: *Reader) FramingError!u16 {
        return getU16(try self.readBytes(2));
    }

    pub fn readU32(self: *Reader) FramingError!u32 {
        return getU32(try self.readBytes(4));
    }

    pub fn readU64(self: *Reader) FramingError!u64 {
        return getU64(try self.readBytes(8));
    }

    pub fn readI64(self: *Reader) FramingError!i64 {
        return @bitCast(try self.readU64());
    }

    pub fn readBytes(self: *Reader, len: usize) FramingError![]const u8 {
        if (self.offset > self.bytes.len or len > self.bytes.len - self.offset) {
            return error.InvalidArtifact;
        }
        const start = self.offset;
        self.offset += len;
        return self.bytes[start..self.offset];
    }
};

/// Bounds-checked big-endian writer used by the StateCapsule encoder.
pub const Writer = struct {
    bytes: []u8,
    offset: usize = 0,

    pub const Error = error{NoSpaceLeft};

    pub fn init(bytes: []u8) Writer {
        return .{ .bytes = bytes };
    }

    pub fn remaining(self: Writer) usize {
        if (self.offset > self.bytes.len) return 0;
        return self.bytes.len - self.offset;
    }

    pub fn finish(self: Writer) Error!void {
        if (self.offset != self.bytes.len) return error.NoSpaceLeft;
    }

    pub fn writeByte(self: *Writer, value: u8) Error!void {
        const target = try self.reserve(1);
        target[0] = value;
    }

    pub fn writeU16(self: *Writer, value: u16) Error!void {
        putU16(try self.reserve(2), value);
    }

    pub fn writeU32(self: *Writer, value: u32) Error!void {
        putU32(try self.reserve(4), value);
    }

    pub fn writeU64(self: *Writer, value: u64) Error!void {
        putU64(try self.reserve(8), value);
    }

    pub fn writeI64(self: *Writer, value: i64) Error!void {
        try self.writeU64(@bitCast(value));
    }

    pub fn writeBytes(self: *Writer, value: []const u8) Error!void {
        @memcpy(try self.reserve(value.len), value);
    }

    fn reserve(self: *Writer, len: usize) Error![]u8 {
        if (self.offset > self.bytes.len or len > self.bytes.len - self.offset) {
            return error.NoSpaceLeft;
        }
        const start = self.offset;
        self.offset += len;
        return self.bytes[start..self.offset];
    }
};

pub fn readValueRef(reader: *Reader) FramingError!ValueRef {
    return switch (try reader.readByte()) {
        @backingInt(ValueTag.nil) => .{ .nil = {} },
        @backingInt(ValueTag.boolean_false) => .{ .boolean_false = {} },
        @backingInt(ValueTag.boolean_true) => .{ .boolean_true = {} },
        @backingInt(ValueTag.integer) => .{ .integer = try reader.readI64() },
        @backingInt(ValueTag.float) => .{ .float = try reader.readU64() },
        @backingInt(ValueTag.symbol) => blk: {
            const len = try reader.readU32();
            break :blk .{ .symbol = try reader.readBytes(len) };
        },
        @backingInt(ValueTag.node_ref) => .{ .node_ref = try reader.readU32() },
        else => error.InvalidArtifact,
    };
}

pub fn writeValueRef(writer: *Writer, value: ValueRef) (Writer.Error || FramingError)!void {
    try writer.writeByte(@backingInt(std.meta.activeTag(value)));
    switch (value) {
        .nil, .boolean_false, .boolean_true => {},
        .integer => |integer| try writer.writeI64(integer),
        .float => |bits| try writer.writeU64(bits),
        .node_ref => |id| try writer.writeU32(id),
        .symbol => |bytes| {
            if (bytes.len > std.math.maxInt(u32)) return error.ArtifactLimitExceeded;
            try writer.writeU32(@intCast(bytes.len));
            try writer.writeBytes(bytes);
        },
    }
}

pub fn readStatePrelude(reader: *Reader) FramingError!StatePrelude {
    return .{
        .node_count = try reader.readU32(),
        .edge_count = try reader.readU32(),
        .root = try readValueRef(reader),
    };
}

pub fn writeStatePrelude(
    writer: *Writer,
    prelude: StatePrelude,
) (Writer.Error || FramingError)!void {
    try writer.writeU32(prelude.node_count);
    try writer.writeU32(prelude.edge_count);
    try writeValueRef(writer, prelude.root);
}

pub fn readNodeRecordHeader(reader: *Reader) FramingError!NodeRecordHeader {
    const id = try reader.readU32();
    const kind: NodeKind = switch (try reader.readByte()) {
        @backingInt(NodeKind.string) => .string,
        @backingInt(NodeKind.array) => .array,
        @backingInt(NodeKind.hash) => .hash,
        else => return error.InvalidArtifact,
    };
    const node_flags = try reader.readByte();
    if (try reader.readU16() != 0) return error.InvalidArtifact;
    try validateNodeFlags(kind, node_flags);
    return .{
        .id = id,
        .kind = kind,
        .flags = node_flags,
        .body_len = try reader.readU32(),
    };
}

pub fn writeNodeRecordHeader(
    writer: *Writer,
    header: NodeRecordHeader,
) (Writer.Error || FramingError)!void {
    try validateNodeFlags(header.kind, header.flags);
    try writer.writeU32(header.id);
    try writer.writeByte(@backingInt(header.kind));
    try writer.writeByte(header.flags);
    try writer.writeU16(0);
    try writer.writeU32(header.body_len);
}

pub fn validateNodeFlags(kind: NodeKind, node_flags: u8) FramingError!void {
    const allowed_flags: u8 = switch (kind) {
        .string, .array => flags.frozen,
        .hash => flags.frozen | flags.hash_has_default,
    };
    if (node_flags & ~allowed_flags != 0) return error.InvalidArtifact;
}

fn optionalApplicationEql(
    actual: ?ApplicationFingerprint,
    expected: ?ApplicationFingerprint,
) bool {
    if (actual) |a| {
        if (expected) |b| return ApplicationFingerprint.eql(a, b);
        return false;
    }
    return expected == null;
}

fn optionalSchemaAccepts(accepted: ?Schema, produced: ?Schema) bool {
    if (accepted) |acceptance| {
        if (produced) |schema| return acceptance.accepts(schema);
        return false;
    }
    return produced == null;
}

fn calculateChecksum(header: []const u8, payload: []const u8) [checksum_len]u8 {
    std.debug.assert(header.len == envelope_header_len);
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var hasher = Sha256.init(.{});
    hasher.update(checksum_domain);
    hasher.update(header[0..offsets.checksum]);
    const zeros: [checksum_len]u8 = @splat(0);
    hasher.update(&zeros);
    hasher.update(header[offsets.checksum + checksum_len .. envelope_header_len]);
    hasher.update(payload);
    var result: [checksum_len]u8 = undefined;
    hasher.final(&result);
    return result;
}

fn refreshChecksum(encoded: []u8) void {
    const digest = calculateChecksum(encoded[0..envelope_header_len], encoded[envelope_header_len..]);
    @memcpy(encoded[offsets.checksum .. offsets.checksum + checksum_len], &digest);
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte != 0) return false;
    }
    return true;
}

fn getU16(bytes: []const u8) u16 {
    std.debug.assert(bytes.len == 2);
    return (@as(u16, bytes[0]) << 8) | bytes[1];
}

fn getU32(bytes: []const u8) u32 {
    std.debug.assert(bytes.len == 4);
    return (@as(u32, bytes[0]) << 24) |
        (@as(u32, bytes[1]) << 16) |
        (@as(u32, bytes[2]) << 8) |
        bytes[3];
}

fn getU64(bytes: []const u8) u64 {
    std.debug.assert(bytes.len == 8);
    var result: u64 = 0;
    for (bytes) |byte| result = (result << 8) | byte;
    return result;
}

fn putU16(bytes: []u8, value: u16) void {
    std.debug.assert(bytes.len == 2);
    bytes[0] = @truncate(value >> 8);
    bytes[1] = @truncate(value);
}

fn putU32(bytes: []u8, value: u32) void {
    std.debug.assert(bytes.len == 4);
    bytes[0] = @truncate(value >> 24);
    bytes[1] = @truncate(value >> 16);
    bytes[2] = @truncate(value >> 8);
    bytes[3] = @truncate(value);
}

fn putU64(bytes: []u8, value: u64) void {
    std.debug.assert(bytes.len == 8);
    bytes[0] = @truncate(value >> 56);
    bytes[1] = @truncate(value >> 48);
    bytes[2] = @truncate(value >> 40);
    bytes[3] = @truncate(value >> 32);
    bytes[4] = @truncate(value >> 24);
    bytes[5] = @truncate(value >> 16);
    bytes[6] = @truncate(value >> 8);
    bytes[7] = @truncate(value);
}

fn rawRiteFixture() [raw_rite_header_len]u8 {
    return .{
        'R', 'I', 'T', 'E',                 '0', '4', '0', '0',
        0,   0,   0,   raw_rite_header_len, 'M', 'A', 'T', 'Z',
        '0', '0', '0', '0',
    };
}

test "RITE envelope has stable framing and validates application identity" {
    const allocator = std.testing.allocator;
    const raw = rawRiteFixture();
    const compatibility: [32]u8 = @splat(0x11);
    const application: ApplicationFingerprint = .{ .bytes = @splat(0x22) };
    var image = try wrapRite(allocator, &raw, .{
        .compatibility = compatibility,
        .application = application,
    });
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(usize, envelope_header_len + raw.len), image.encoded.len);
    try std.testing.expectEqualSlices(u8, &envelope_magic, image.encoded[0..8]);
    try std.testing.expectEqual(@as(u8, @backingInt(Kind.rite)), image.encoded[offsets.kind]);
    try std.testing.expectEqual(flags.application, image.encoded[offsets.flags]);
    try std.testing.expectEqualSlices(u8, &compatibility, image.encoded[24..56]);
    try std.testing.expectEqualSlices(u8, &application.bytes, image.encoded[56..88]);

    const golden_hex =
        "4d525a415254460000010000010100800000000000000014" ++
        "1111111111111111111111111111111111111111111111111111111111111111" ++
        "2222222222222222222222222222222222222222222222222222222222222222" ++
        "e8f79297e235bf7129480f05133903dbe8587ab7a983ea1bf70e8043402cbcc9" ++
        "00000000000000005249544530343030000000144d41545a30303030";
    var golden: [golden_hex.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&golden, golden_hex);
    try std.testing.expectEqualSlices(u8, &golden, image.encoded);

    const decoded = try validateRite(image.view(), .{
        .compatibility = compatibility,
        .application = application,
    });
    try std.testing.expectEqualSlices(u8, &raw, decoded.bytes);
    try std.testing.expect(decoded.application.?.eql(application));

    try std.testing.expectError(error.IncompatibleRiteImage, validateRite(image.view(), .{
        .compatibility = @splat(0x33),
        .application = application,
    }));
    try std.testing.expectError(error.IncompatibleRiteImage, validateRite(image.view(), .{
        .compatibility = compatibility,
        .application = null,
    }));
}

test "RITE application presence uses exact optional equality" {
    const allocator = std.testing.allocator;
    const raw = rawRiteFixture();
    const compatibility: [32]u8 = @splat(0x44);
    var image = try wrapRite(allocator, &raw, .{ .compatibility = compatibility });
    defer image.deinit(allocator);

    _ = try validateRite(image.view(), .{ .compatibility = compatibility });
    try std.testing.expectError(error.IncompatibleRiteImage, validateRite(image.view(), .{
        .compatibility = compatibility,
        .application = .{ .bytes = @splat(1) },
    }));
}

test "envelope detects corruption, truncation, trailing bytes, and limits" {
    const allocator = std.testing.allocator;
    const raw = rawRiteFixture();
    const compatibility: [32]u8 = @splat(0x55);
    var image = try wrapRite(allocator, &raw, .{ .compatibility = compatibility });
    defer image.deinit(allocator);

    image.encoded[image.encoded.len - 1] ^= 1;
    try std.testing.expectError(error.ChecksumMismatch, validateRite(image.view(), .{
        .compatibility = compatibility,
    }));
    image.encoded[image.encoded.len - 1] ^= 1;

    try std.testing.expectError(error.InvalidArtifact, parseEnvelope(
        image.encoded[0 .. image.encoded.len - 1],
        .{},
    ));
    try std.testing.expectError(error.ArtifactLimitExceeded, parseEnvelope(image.encoded, .{
        .max_encoded_bytes = image.encoded.len - 1,
    }));

    const trailing = try allocator.alloc(u8, image.encoded.len + 1);
    defer allocator.free(trailing);
    @memcpy(trailing[0..image.encoded.len], image.encoded);
    trailing[trailing.len - 1] = 0;
    try std.testing.expectError(error.InvalidArtifact, parseEnvelope(trailing, .{}));
}

test "State schema admission is ID and major exact with forward minor rejection" {
    const allocator = std.testing.allocator;
    const producer: Schema = .{
        .id = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
        .major = 3,
        .minor = 4,
    };
    const payload = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, @backingInt(ValueTag.nil) };
    var capsule = try wrapState(allocator, &payload, .{ .schema = producer });
    defer capsule.deinit(allocator);

    const golden_hex =
        "4d525a415254460000010000020100800000000000000009" ++
        "000102030405060708090a0b0c0d0e0f00030004" ++
        "0000000000000000000000000000000000000000000000000000000000000000" ++
        "000000000000000000000000" ++
        "8ee0aec2fbd6623f3da353ca117f14956b1e78c3a9b6f79f27f3e7d8512bf014" ++
        "0000000000000000000000000000000000";
    var golden: [golden_hex.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&golden, golden_hex);
    try std.testing.expectEqualSlices(u8, &golden, capsule.encoded);

    const decoded = try validateState(capsule.view(), .{ .accepted_schema = .{
        .id = producer.id,
        .major = 3,
        .minor = 5,
    } });
    try std.testing.expectEqualSlices(u8, &payload, decoded.bytes);
    try std.testing.expectEqual(producer, decoded.schema.?);

    try std.testing.expectError(error.SchemaMismatch, validateState(capsule.view(), .{
        .accepted_schema = .{ .id = producer.id, .major = 3, .minor = 3 },
    }));
    try std.testing.expectError(error.SchemaMismatch, validateState(capsule.view(), .{
        .accepted_schema = .{ .id = producer.id, .major = 4, .minor = 4 },
    }));
    try std.testing.expectError(error.SchemaMismatch, validateState(capsule.view(), .{}));
}

test "schema-less capsules require schema-less acceptance and zero metadata" {
    const allocator = std.testing.allocator;
    const payload = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, @backingInt(ValueTag.nil) };
    var capsule = try wrapState(allocator, &payload, .{});
    defer capsule.deinit(allocator);

    _ = try validateState(capsule.view(), .{});
    try std.testing.expectError(error.SchemaMismatch, validateState(capsule.view(), .{
        .accepted_schema = .{ .id = @splat(0), .major = 1 },
    }));

    capsule.encoded[offsets.metadata] = 1;
    refreshChecksum(capsule.encoded);
    try std.testing.expectError(error.InvalidArtifact, validateState(capsule.view(), .{}));
}

test "State primitive references round-trip exact integer and float bits" {
    const values = [_]ValueRef{
        .{ .nil = {} },
        .{ .boolean_false = {} },
        .{ .boolean_true = {} },
        .{ .integer = std.math.minInt(i64) },
        .{ .float = 0x7ff8_0000_0000_0042 },
        .{ .symbol = "a\x00b" },
        .{ .node_ref = 0x1020_3040 },
    };
    var encoded: [1 + 1 + 1 + 9 + 9 + 8 + 5]u8 = undefined;
    var writer = Writer.init(&encoded);
    for (values) |value| try writeValueRef(&writer, value);
    try writer.finish();

    var reader = Reader.init(&encoded);
    for (values) |expected| {
        const actual = try readValueRef(&reader);
        switch (expected) {
            .nil => try std.testing.expect(actual == .nil),
            .boolean_false => try std.testing.expect(actual == .boolean_false),
            .boolean_true => try std.testing.expect(actual == .boolean_true),
            .integer => |value| try std.testing.expectEqual(value, actual.integer),
            .float => |value| try std.testing.expectEqual(value, actual.float),
            .symbol => |value| try std.testing.expectEqualSlices(u8, value, actual.symbol),
            .node_ref => |value| try std.testing.expectEqual(value, actual.node_ref),
        }
    }
    try reader.finish();
}

test "node record headers reject reserved bits and kind-specific flags" {
    var encoded: [node_record_header_len]u8 = undefined;
    var writer = Writer.init(&encoded);
    try writeNodeRecordHeader(&writer, .{
        .id = 7,
        .kind = .hash,
        .flags = flags.frozen | flags.hash_has_default,
        .body_len = 99,
    });
    try writer.finish();

    var reader = Reader.init(&encoded);
    const decoded = try readNodeRecordHeader(&reader);
    try std.testing.expectEqual(@as(u32, 7), decoded.id);
    try std.testing.expectEqual(NodeKind.hash, decoded.kind);
    try std.testing.expectEqual(@as(u32, 99), decoded.body_len);

    encoded[5] = flags.hash_has_default;
    encoded[4] = @backingInt(NodeKind.array);
    var invalid = Reader.init(&encoded);
    try std.testing.expectError(error.InvalidArtifact, readNodeRecordHeader(&invalid));
}

test "CapsuleLimits tightening is component-wise" {
    const policy: CapsuleLimits = .{
        .max_encoded_bytes = 10,
        .max_nodes = 20,
        .max_total_edges = 30,
        .max_depth = 40,
        .max_string_bytes = 50,
        .max_symbol_bytes = 60,
    };
    const result = policy.tightened(.{
        .max_encoded_bytes = 11,
        .max_nodes = 19,
        .max_total_edges = 31,
        .max_depth = 39,
        .max_string_bytes = 51,
        .max_symbol_bytes = 59,
    });
    try std.testing.expectEqual(@as(usize, 10), result.max_encoded_bytes);
    try std.testing.expectEqual(@as(usize, 19), result.max_nodes);
    try std.testing.expectEqual(@as(usize, 30), result.max_total_edges);
    try std.testing.expectEqual(@as(usize, 39), result.max_depth);
    try std.testing.expectEqual(@as(usize, 50), result.max_string_bytes);
    try std.testing.expectEqual(@as(usize, 59), result.max_symbol_bytes);
}
