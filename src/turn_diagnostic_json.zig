//! Bounded diagnostics as ASCII JSON. Text is byte-oriented, so every byte
//! outside printable ASCII is escaped independently as \u00XX. Never dispatches
//! Ruby, inspects guest objects, or allocates storage beyond the caller's writer.
const std = @import("std");
const Writer = std.Io.Writer;

pub fn write(detail: anytype, writer: *Writer) Writer.Error!void {
    try writer.writeAll("{\"byte_text_encoding\":\"u00xx-per-byte\",\"origin\":");
    try text(writer, @tagName(detail.origin));
    try writer.writeAll(",\"phase\":");
    try text(writer, @tagName(detail.phase));
    try writer.writeAll(",\"kind\":");
    try text(writer, @tagName(detail.kind));
    try writer.writeAll(",\"error\":");
    try text(writer, detail.errorName());
    try writer.writeAll(",\"message\":");
    try text(writer, detail.messageText());
    try writer.writeAll(",\"class\":");
    try text(writer, detail.className());
    try writer.print(",\"truncated\":{s},\"source\":", .{if (detail.truncated) "true" else "false"});
    if (detail.source) |location| {
        try writer.writeAll("{\"file\":");
        try text(writer, location.fileName());
        try writer.writeAll(",\"method\":");
        try text(writer, location.methodName());
        try writer.print(",\"line\":{d},\"truncated\":{s}}}", .{ location.line, if (location.truncated != 0) "true" else "false" });
    } else try writer.writeAll("null");
    try writer.writeAll(",\"turn_contract\":");
    if (detail.contract_detail) |mismatch| {
        try writeMismatch(writer, mismatch.side, mismatch.detail);
    } else try writer.writeAll("null");
    try writer.writeAll(",\"effect\":");
    if (detail.effect_detail) |event| {
        try writer.writeAll("{\"reason\":");
        try text(writer, @tagName(event.reason));
        try writer.print(",\"record_index\":{d},\"expected_operation\":", .{event.record_index});
        try text(writer, event.expectedOperation());
        try writer.writeAll(",\"actual_operation\":");
        try text(writer, event.actualOperation());
        try writer.writeAll(",\"expected_version\":");
        try number(writer, event.expected_version);
        try writer.writeAll(",\"actual_version\":");
        try number(writer, event.actual_version);
        try writer.writeAll(",\"argument_byte_offset\":");
        try number(writer, event.argument_byte_offset);
        try writer.writeAll(",\"expected_hash\":");
        try hash(writer, event.expected_hash);
        try writer.writeAll(",\"actual_hash\":");
        try hash(writer, event.actual_hash);
        try writer.writeAll(",\"contract\":");
        if (event.contract_detail) |mismatch| {
            try writeMismatch(writer, mismatch.side, mismatch);
        } else try writer.writeAll("null");
        try writer.writeByte('}');
    } else try writer.writeAll("null");
    try writer.writeAll(",\"native\":");
    if (detail.native_detail) |native| {
        try writer.print("{{\"reason\":{d},\"name\":", .{native.reason});
        try text(writer, native.name[0..native.name_len]);
        try writer.writeByte('}');
    } else try writer.writeAll("null");
    try writer.writeAll(",\"expected_hash\":");
    try hash(writer, detail.expected_hash);
    try writer.writeAll(",\"actual_hash\":");
    try hash(writer, detail.actual_hash);
    try writer.writeAll(",\"byte_offset\":");
    try number(writer, detail.byte_offset);
    try writer.writeByte('}');
}

fn writeMismatch(writer: *Writer, side: anytype, mismatch: anytype) Writer.Error!void {
    try writer.writeAll("{\"side\":");
    try text(writer, @tagName(side));
    try writer.writeAll(",\"reason\":");
    try text(writer, @tagName(mismatch.reason));
    try writer.writeAll(",\"path\":");
    try text(writer, mismatch.pathText());
    try writer.print(",\"path_truncated\":{s},\"expected\":", .{if (mismatch.path_truncated) "true" else "false"});
    try text(writer, @tagName(mismatch.expected));
    try writer.writeAll(",\"actual\":");
    if (mismatch.actual) |kind| try text(writer, @tagName(kind)) else try writer.writeAll("null");
    try writer.writeByte('}');
}

fn text(writer: *Writer, bytes: []const u8) Writer.Error!void {
    const hex = "0123456789abcdef";
    try writer.writeByte('"');
    for (bytes) |byte| switch (byte) {
        '"', '\\' => {
            try writer.writeByte('\\');
            try writer.writeByte(byte);
        },
        0x20...0x21, 0x23...0x5b, 0x5d...0x7e => try writer.writeByte(byte),
        else => try writer.writeAll(&.{ '\\', 'u', '0', '0', hex[byte >> 4], hex[byte & 15] }),
    };
    try writer.writeByte('"');
}
fn number(writer: *Writer, value: anytype) Writer.Error!void {
    if (value) |n| try writer.print("{d}", .{n}) else try writer.writeAll("null");
}
fn hash(writer: *Writer, value: ?[32]u8) Writer.Error!void {
    if (value) |bytes| {
        const encoded = std.fmt.bytesToHex(bytes, .lower);
        try text(writer, &encoded);
    } else try writer.writeAll("null");
}
