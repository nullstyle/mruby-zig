//! Allocation-free wire encoding of bounded diagnostics. These are untrusted
//! observations, never authorization or proof of a successful worker execution.
//! Native padding, pointers, and unused fixed-buffer tails never cross the wire.
const std = @import("std");
const Turn = @import("strict_turn.zig");
const effect = @import("effect.zig");
const c = @import("c.zig");
const contracts = @import("turn_contract.zig");

pub const max_encoded_len: usize = @import("effect_worker_protocol.zig").max_diagnostic_len;
const magic = "MRZDIAG\x00";
pub const Error = error{ InvalidDiagnostic, UnsupportedDiagnosticVersion, InvalidDiagnosticField, DiagnosticTooLarge };
pub const Encoded = struct {
    bytes: [max_encoded_len]u8 = @splat(0),
    len: usize = 0,
    pub fn view(self: *const Encoded) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub fn encode(value: Turn.Diagnostic) Error!Encoded {
    var result: Encoded = .{};
    var writer: Writer = .{ .bytes = &result.bytes };
    try writer.copy(magic);
    try writer.int(u16, 3);
    try writer.int(u16, 0); // reserved
    try writer.int(u32, 0); // final encoded length
    try writer.int(u8, switch (value.kind) {
        .none => 0,
        .effect => 1,
        .native => 2,
        .terminal => 3,
        .ruby => 4,
        .failure => 5,
        .contract => 6,
    });
    try writer.int(u8, switch (value.origin) {
        .none => 0,
        .turn => 1,
        .broker => 2,
        .worker => 3,
    });
    try writer.int(u8, switch (value.phase) {
        .none => 0,
        .setup => 1,
        .record => 2,
        .verification => 3,
        .replay => 4,
    });
    const flags: u8 = bit(value.truncated, 0) | bit(value.source != null, 1) | bit(value.effect_detail != null, 2) |
        bit(value.native_detail != null, 3) | bit(value.expected_hash != null, 4) | bit(value.actual_hash != null, 5) | bit(value.byte_offset != null, 6) | bit(value.contract_detail != null, 7);
    try writer.int(u8, flags);
    try writer.text(&value.error_name, value.error_name_len);
    try writer.text(&value.message, value.message_len);
    try writer.text(&value.class_name, value.class_name_len);
    if (value.source) |source| try writer.source(source);
    if (value.effect_detail) |detail| try writer.effectDetail(detail);
    if (value.native_detail) |detail| {
        if (detail.reason > 4) return error.InvalidDiagnosticField;
        try writer.int(u32, detail.reason);
        try writer.text(&detail.name, detail.name_len);
        try writer.source(detail.source);
    }
    if (value.expected_hash) |hash| try writer.copy(&hash);
    if (value.actual_hash) |hash| try writer.copy(&hash);
    if (value.byte_offset) |offset| try writer.int(u64, @intCast(offset));
    if (value.contract_detail) |detail| {
        try writer.int(u8, @backingInt(detail.side));
        try writer.valueMismatch(detail.detail);
    }
    result.len = writer.at;
    std.mem.writeInt(u32, result.bytes[12..16], @intCast(result.len), .big);
    return result;
}

pub fn decode(bytes: []const u8) Error!Turn.Diagnostic {
    if (bytes.len > max_encoded_len) return error.DiagnosticTooLarge;
    if (bytes.len < 20 or !std.mem.eql(u8, bytes[0..8], magic)) return error.InvalidDiagnostic;
    var reader: Reader = .{ .bytes = bytes, .at = 8 };
    if (try reader.int(u16) != 3) return error.UnsupportedDiagnosticVersion;
    if (try reader.int(u16) != 0) return error.InvalidDiagnosticField;
    if (try reader.int(u32) != bytes.len) return error.InvalidDiagnostic;
    var result: Turn.Diagnostic = .{};
    result.kind = switch (try reader.int(u8)) {
        0 => .none,
        1 => .effect,
        2 => .native,
        3 => .terminal,
        4 => .ruby,
        5 => .failure,
        6 => .contract,
        else => return error.InvalidDiagnosticField,
    };
    result.origin = switch (try reader.int(u8)) {
        0 => .none,
        1 => .turn,
        2 => .broker,
        3 => .worker,
        else => return error.InvalidDiagnosticField,
    };
    result.phase = switch (try reader.int(u8)) {
        0 => .none,
        1 => .setup,
        2 => .record,
        3 => .verification,
        4 => .replay,
        else => return error.InvalidDiagnosticField,
    };
    const flags = try reader.int(u8);
    result.truncated = flags & 1 != 0;
    result.error_name_len = try reader.text(&result.error_name);
    result.message_len = try reader.text(&result.message);
    result.class_name_len = try reader.text(&result.class_name);
    if (flags & 2 != 0) result.source = try reader.source();
    if (flags & 4 != 0) result.effect_detail = try reader.effectDetail();
    if (flags & 8 != 0) {
        var native: c.StrictDiagnostic = std.mem.zeroes(c.StrictDiagnostic);
        native.reason = try reader.int(u32);
        if (native.reason > 4) return error.InvalidDiagnosticField;
        native.name_len = try reader.text(&native.name);
        native.source = try reader.source();
        result.native_detail = native;
    }
    if (flags & 16 != 0) result.expected_hash = (try reader.take(32))[0..32].*;
    if (flags & 32 != 0) result.actual_hash = (try reader.take(32))[0..32].*;
    if (flags & 64 != 0) result.byte_offset = try reader.size();
    if (flags & 128 != 0) result.contract_detail = .{ .side = try reader.enumValue(contracts.Side), .detail = try reader.valueMismatch() };
    if (reader.at != bytes.len) return error.InvalidDiagnostic;
    return result;
}

fn bit(present: bool, comptime index: u3) u8 {
    return @as(u8, @intFromBool(present)) << index;
}

const Writer = struct {
    bytes: *[max_encoded_len]u8,
    at: usize = 0,
    fn copy(self: *Writer, bytes: []const u8) Error!void {
        if (bytes.len > self.bytes.len - self.at) return error.DiagnosticTooLarge;
        @memcpy(self.bytes[self.at..][0..bytes.len], bytes);
        self.at += bytes.len;
    }
    fn int(self: *Writer, comptime T: type, value: T) Error!void {
        var bytes: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &bytes, value, .big);
        try self.copy(&bytes);
    }
    fn text(self: *Writer, buffer: []const u8, length: usize) Error!void {
        if (length > buffer.len or length > std.math.maxInt(u16)) return error.InvalidDiagnosticField;
        try self.int(u16, @intCast(length));
        try self.copy(buffer[0..length]);
    }
    fn source(self: *Writer, value: Turn.Diagnostic.Source) Error!void {
        if (value.truncated > 1) return error.InvalidDiagnosticField;
        try self.int(u32, value.line);
        try self.int(u8, @intCast(value.truncated));
        try self.int(u8, 0); // reserved
        try self.text(&value.file, value.file_len);
        try self.text(&value.method, value.method_len);
    }
    fn valueMismatch(self: *Writer, detail: anytype) Error!void {
        try self.int(u8, @backingInt(detail.reason));
        try self.int(u8, @backingInt(detail.expected));
        try self.int(u8, if (detail.actual) |kind| @backingInt(kind) else 255);
        try self.int(u8, @intFromBool(detail.path_truncated));
        try self.text(&detail.path, detail.path_len);
    }
    fn effectDetail(self: *Writer, value: effect.Diagnostic) Error!void {
        try self.int(u8, reasonTag(value.reason));
        const flags = bit(value.expected_version != null, 0) | bit(value.actual_version != null, 1) |
            bit(value.argument_byte_offset != null, 2) | bit(value.expected_hash != null, 3) | bit(value.actual_hash != null, 4) | bit(value.source != null, 5) | bit(value.contract_detail != null, 6);
        try self.int(u8, flags);
        try self.int(u16, 0); // reserved
        try self.int(u64, @intCast(value.record_index));
        try self.text(&value.expected_operation, value.expected_operation_len);
        try self.text(&value.actual_operation, value.actual_operation_len);
        if (value.expected_version) |version| try self.int(u32, version);
        if (value.actual_version) |version| try self.int(u32, version);
        if (value.argument_byte_offset) |offset| try self.int(u64, @intCast(offset));
        if (value.expected_hash) |hash| try self.copy(&hash);
        if (value.actual_hash) |hash| try self.copy(&hash);
        if (value.source) |where| try self.source(where);
        if (value.contract_detail) |detail| {
            // These enums have explicit u8 representations in effect_schema.
            try self.int(u8, @backingInt(detail.side));
            try self.valueMismatch(detail);
        }
    }
};

const Reader = struct {
    bytes: []const u8,
    at: usize = 0,
    fn take(self: *Reader, count: usize) Error![]const u8 {
        if (count > self.bytes.len - self.at) return error.InvalidDiagnostic;
        const bytes = self.bytes[self.at..][0..count];
        self.at += count;
        return bytes;
    }
    fn int(self: *Reader, comptime T: type) Error!T {
        return std.mem.readInt(T, (try self.take(@sizeOf(T)))[0..@sizeOf(T)], .big);
    }
    fn size(self: *Reader) Error!usize {
        return std.math.cast(usize, try self.int(u64)) orelse error.InvalidDiagnosticField;
    }
    fn enumValue(self: *Reader, comptime T: type) Error!T {
        return enumTag(T, try self.int(u8));
    }
    fn text(self: *Reader, buffer: []u8) Error!u16 {
        const length = try self.int(u16);
        if (length > buffer.len) return error.InvalidDiagnosticField;
        @memcpy(buffer[0..length], try self.take(length));
        return length;
    }
    fn source(self: *Reader) Error!Turn.Diagnostic.Source {
        var value: Turn.Diagnostic.Source = std.mem.zeroes(Turn.Diagnostic.Source);
        value.line = try self.int(u32);
        value.truncated = try self.int(u8);
        if (value.truncated > 1 or try self.int(u8) != 0) return error.InvalidDiagnosticField;
        value.file_len = try self.text(&value.file);
        value.method_len = try self.text(&value.method);
        return value;
    }
    fn valueMismatch(self: *Reader) Error!effect.schema.ValueMismatch {
        var detail: effect.schema.ValueMismatch = .{
            .reason = try self.enumValue(effect.schema.Reason),
            .expected = try self.enumValue(effect.schema.Kind),
        };
        const actual = try self.int(u8);
        detail.actual = if (actual == 255) null else try enumTag(effect.schema.ValueKind, actual);
        const truncated = try self.int(u8);
        if (truncated > 1) return error.InvalidDiagnosticField;
        detail.path_truncated = truncated != 0;
        detail.path_len = try self.text(&detail.path);
        return detail;
    }
    fn effectDetail(self: *Reader) Error!effect.Diagnostic {
        var value: effect.Diagnostic = .{ .reason = try decodeReason(try self.int(u8)) };
        const flags = try self.int(u8);
        if (flags & 0x80 != 0 or try self.int(u16) != 0) return error.InvalidDiagnosticField;
        value.record_index = try self.size();
        value.expected_operation_len = try self.text(&value.expected_operation);
        value.actual_operation_len = try self.text(&value.actual_operation);
        if (flags & 1 != 0) value.expected_version = try self.int(u32);
        if (flags & 2 != 0) value.actual_version = try self.int(u32);
        if (flags & 4 != 0) value.argument_byte_offset = try self.size();
        if (flags & 8 != 0) value.expected_hash = (try self.take(32))[0..32].*;
        if (flags & 16 != 0) value.actual_hash = (try self.take(32))[0..32].*;
        if (flags & 32 != 0) value.source = try self.source();
        if (flags & 64 != 0) {
            const side = try self.enumValue(effect.schema.Side);
            const detail = try self.valueMismatch();
            value.contract_detail = .{ .side = side, .reason = detail.reason, .expected = detail.expected, .actual = detail.actual, .path = detail.path, .path_len = detail.path_len, .path_truncated = detail.path_truncated };
        }
        return value;
    }
};

fn enumTag(comptime T: type, tag: u8) Error!T {
    inline for (@typeInfo(T).@"enum".field_names) |name| {
        if (tag == @backingInt(@field(T, name))) return @field(T, name);
    }
    return error.InvalidDiagnosticField;
}

fn reasonTag(reason: effect.Diagnostic.Reason) u8 {
    return switch (reason) {
        .identity_code => 0,
        .identity_catalogue => 1,
        .identity_input => 2,
        .operation => 3,
        .version => 4,
        .arguments => 5,
        .missing_record => 6,
        .extra_record => 7,
        .invalid_result => 8,
        .denied => 9,
        .unhandled => 10,
        .handler_failed => 11,
        .invalid_request => 12,
        .limit => 13,
        .initialization => 14,
        .reentry => 15,
        .contract => 16,
    };
}
fn decodeReason(tag: u8) Error!effect.Diagnostic.Reason {
    return switch (tag) {
        0 => .identity_code,
        1 => .identity_catalogue,
        2 => .identity_input,
        3 => .operation,
        4 => .version,
        5 => .arguments,
        6 => .missing_record,
        7 => .extra_record,
        8 => .invalid_result,
        9 => .denied,
        10 => .unhandled,
        11 => .handler_failed,
        12 => .invalid_request,
        13 => .limit,
        14 => .initialization,
        15 => .reentry,
        16 => .contract,
        else => error.InvalidDiagnosticField,
    };
}

fn sample() Turn.Diagnostic {
    const source: Turn.Diagnostic.Source = .{
        .line = 0x01020304,
        .file_len = 256,
        .method_len = 96,
        .truncated = 1,
        .file = @splat('f'),
        .method = @splat('m'),
    };
    return .{
        .kind = .effect,
        .origin = .worker,
        .phase = .verification,
        .error_name = @splat('e'),
        .error_name_len = 128,
        .message = @splat('t'),
        .message_len = 512,
        .class_name = @splat('c'),
        .class_name_len = 128,
        .truncated = true,
        .source = source,
        .effect_detail = .{
            .reason = .arguments,
            .record_index = 0x0102030405060708,
            .expected_operation = @splat('a'),
            .expected_operation_len = 256,
            .actual_operation = @splat('b'),
            .actual_operation_len = 256,
            .expected_version = 0x12345678,
            .actual_version = 0x87654321,
            .argument_byte_offset = 0x0807060504030201,
            .expected_hash = @splat(0xf0),
            .actual_hash = @splat(0x0f),
            .source = source,
            .contract_detail = .{
                .side = .result,
                .reason = .missing_field,
                .expected = .integer,
                .actual = null,
                .path = @splat('p'),
                .path_len = 256,
                .path_truncated = true,
            },
        },
        .native_detail = .{ .reason = 4, .name_len = 96, .name = @splat('n'), .source = source },
        .expected_hash = @splat(0x31),
        .actual_hash = @splat(0x32),
        .byte_offset = 0x1234567890,
        .contract_detail = .{ .side = .next_state, .detail = .{
            .reason = .extra_field,
            .expected = .object,
            .actual = .hash,
            .path = @splat('s'),
            .path_len = 256,
            .path_truncated = true,
        } },
    };
}

test "bounded worker diagnostic roundtrip retains all present and absent fields" {
    for ([_]Turn.Diagnostic{ .{}, sample() }) |original| {
        const encoded = try encode(original);
        try std.testing.expect(encoded.len <= max_encoded_len);
        const decoded = try decode(encoded.view());
        try std.testing.expectEqualDeep(original, decoded);
        const again = try encode(decoded);
        try std.testing.expectEqualSlices(u8, encoded.view(), again.view());
    }
    const original = sample();
    const encoded = try encode(original);
    // Explicit byte order, not host-native struct layout.
    try std.testing.expectEqualSlices(u8, &.{ 0, 3, 0, 0 }, encoded.bytes[8..12]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 128 }, encoded.bytes[20..22]);
    const where = 20 + 2 + 128 + 2 + 512 + 2 + 128;
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 1, 0, 1, 0 }, encoded.bytes[where..][0..8]);
}

test "worker diagnostic encodes every known kind origin phase and effect reason explicitly" {
    inline for (@typeInfo(@FieldType(Turn.Diagnostic, "kind")).@"enum".field_names) |name| {
        const value: Turn.Diagnostic = .{ .kind = @field(@FieldType(Turn.Diagnostic, "kind"), name) };
        const encoded = try encode(value);
        try std.testing.expectEqualDeep(value, try decode(encoded.view()));
    }
    inline for (@typeInfo(@FieldType(Turn.Diagnostic, "origin")).@"enum".field_names) |name| {
        const value: Turn.Diagnostic = .{ .origin = @field(@FieldType(Turn.Diagnostic, "origin"), name) };
        const encoded = try encode(value);
        try std.testing.expectEqualDeep(value, try decode(encoded.view()));
    }
    inline for (@typeInfo(@FieldType(Turn.Diagnostic, "phase")).@"enum".field_names) |name| {
        const value: Turn.Diagnostic = .{ .phase = @field(@FieldType(Turn.Diagnostic, "phase"), name) };
        const encoded = try encode(value);
        try std.testing.expectEqualDeep(value, try decode(encoded.view()));
    }
    inline for (@typeInfo(effect.Diagnostic.Reason).@"enum".field_names) |name| {
        const value: Turn.Diagnostic = .{ .effect_detail = .{ .reason = @field(effect.Diagnostic.Reason, name) } };
        const encoded = try encode(value);
        try std.testing.expectEqualDeep(value, try decode(encoded.view()));
    }
}

test "worker diagnostic rejects every truncated prefix and trailing bytes" {
    const original = try encode(sample());
    for (0..original.len) |length| {
        var prefix = original;
        if (length >= 16) std.mem.writeInt(u32, prefix.bytes[12..16], @intCast(length), .big);
        try std.testing.expectError(error.InvalidDiagnostic, decode(prefix.bytes[0..length]));
    }
    var trailing = original;
    trailing.len += 1;
    std.mem.writeInt(u32, trailing.bytes[12..16], @intCast(trailing.len), .big);
    try std.testing.expectError(error.InvalidDiagnostic, decode(trailing.view()));
    const oversized: [max_encoded_len + 1]u8 = @splat(0);
    try std.testing.expectError(error.DiagnosticTooLarge, decode(&oversized));
}

test "worker diagnostic rejects unknown tags flags reserved bytes and invalid text lengths" {
    const empty = try encode(.{});
    for ([_]usize{ 10, 16, 17, 18 }) |offset| {
        var invalid = empty;
        invalid.bytes[offset] = 0xff;
        try std.testing.expectError(error.InvalidDiagnosticField, decode(invalid.view()));
    }
    var old = empty;
    old.bytes[9] = 0;
    try std.testing.expectError(error.UnsupportedDiagnosticVersion, decode(old.view()));
    var long_name = empty;
    std.mem.writeInt(u16, long_name.bytes[20..22], 129, .big);
    try std.testing.expectError(error.InvalidDiagnosticField, decode(long_name.view()));
    const source = try encode(.{ .source = std.mem.zeroes(Turn.Diagnostic.Source) });
    for ([_]usize{ 30, 31 }) |offset| {
        var invalid = source;
        invalid.bytes[offset] = 2;
        try std.testing.expectError(error.InvalidDiagnosticField, decode(invalid.view()));
    }
    var long_file = source;
    std.mem.writeInt(u16, long_file.bytes[32..34], 257, .big);
    try std.testing.expectError(error.InvalidDiagnosticField, decode(long_file.view()));
    const detail = try encode(.{ .effect_detail = .{ .reason = .operation } });
    for ([_]usize{ 26, 27, 28 }) |offset| {
        var invalid = detail;
        invalid.bytes[offset] = 0xff;
        try std.testing.expectError(error.InvalidDiagnosticField, decode(invalid.view()));
    }
    var native = try encode(.{ .native_detail = std.mem.zeroes(c.StrictDiagnostic) });
    native.bytes[29] = 5;
    try std.testing.expectError(error.InvalidDiagnosticField, decode(native.view()));
    var invalid: Turn.Diagnostic = .{ .message_len = 513 };
    try std.testing.expectError(error.InvalidDiagnosticField, encode(invalid));
    invalid = .{ .native_detail = .{ .reason = 5, .name_len = 0, .name = @splat(0), .source = std.mem.zeroes(Turn.Diagnostic.Source) } };
    try std.testing.expectError(error.InvalidDiagnosticField, encode(invalid));
}

test "worker diagnostic copies owned bytes and excludes unused tails" {
    var original: Turn.Diagnostic = .{ .kind = .ruby, .message_len = 3 };
    @memcpy(original.message[0..3], "x\x00y");
    const encoded = try encode(original);
    original.message[200] = 0xff;
    const again = try encode(original);
    try std.testing.expectEqualSlices(u8, encoded.view(), again.view());
    var overwritten = encoded;
    const decoded = try decode(overwritten.view());
    @memset(&overwritten.bytes, 0);
    try std.testing.expectEqualSlices(u8, "x\x00y", decoded.messageText());
}

test "worker diagnostic contract details validate tags and survive safe JSON formatting" {
    var value: Turn.Diagnostic = .{ .effect_detail = .{ .reason = .contract, .contract_detail = .{
        .side = .arguments,
        .reason = .integer_range,
        .expected = .integer,
        .actual = .integer,
    } } };
    const path = "$[1][\"quantity\"]";
    @memcpy(value.effect_detail.?.contract_detail.?.path[0..path.len], path);
    value.effect_detail.?.contract_detail.?.path_len = path.len;
    const encoded = try encode(value);
    const decoded = try decode(encoded.view());
    try std.testing.expectEqualDeep(value, decoded);
    // Empty outer strings and operation names precede this fixed wire record.
    const at = 42;
    for ([_]usize{ at, at + 1, at + 2, at + 3, at + 4 }) |offset| {
        var invalid = encoded;
        invalid.bytes[offset] = 254;
        try std.testing.expectError(error.InvalidDiagnosticField, decode(invalid.view()));
    }
    var long_path = encoded;
    std.mem.writeInt(u16, long_path.bytes[at + 5 ..][0..2], 257, .big);
    try std.testing.expectError(error.InvalidDiagnosticField, decode(long_path.view()));
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try decoded.writeJson(&writer);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, writer.buffered(), .{});
    defer parsed.deinit();
    const contract = parsed.value.object.get("effect").?.object.get("contract").?.object;
    try std.testing.expectEqualStrings("arguments", contract.get("side").?.string);
    try std.testing.expectEqualStrings(path, contract.get("path").?.string);
    try std.testing.expectEqualStrings("integer_range", contract.get("reason").?.string);
}

test "worker diagnostic turn contracts bound every field and format all four value sides" {
    inline for (@typeInfo(contracts.Side).@"enum".field_names) |name| {
        var value: Turn.Diagnostic = .{ .kind = .contract, .contract_detail = .{
            .side = @field(contracts.Side, name),
            .detail = .{ .reason = .integer_range, .expected = .integer, .actual = .integer },
        } };
        const path = "$[\"count\"]";
        @memcpy(value.contract_detail.?.detail.path[0..path.len], path);
        value.contract_detail.?.detail.path_len = path.len;
        const encoded = try encode(value);
        const decoded = try decode(encoded.view());
        try std.testing.expectEqualDeep(value, decoded);
        // Three empty outer strings precede the standalone turn mismatch.
        for ([_]usize{ 26, 27, 28, 29, 30 }) |offset| {
            var invalid = encoded;
            invalid.bytes[offset] = 254;
            try std.testing.expectError(error.InvalidDiagnosticField, decode(invalid.view()));
        }
        var long_path = encoded;
        std.mem.writeInt(u16, long_path.bytes[31..33], 257, .big);
        try std.testing.expectError(error.InvalidDiagnosticField, decode(long_path.view()));
        var buffer: [4096]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try decoded.writeJson(&writer);
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, writer.buffered(), .{});
        defer parsed.deinit();
        const detail = parsed.value.object.get("turn_contract").?.object;
        try std.testing.expectEqualStrings(name, detail.get("side").?.string);
        try std.testing.expectEqualStrings(path, detail.get("path").?.string);
    }
    const encoded = try encode(.{});
    for ([_]u8{ 1, 2 }) |version| {
        var old = encoded;
        old.bytes[9] = version;
        try std.testing.expectError(error.UnsupportedDiagnosticVersion, decode(old.view()));
    }
}
