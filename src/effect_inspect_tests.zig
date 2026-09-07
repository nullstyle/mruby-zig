const std = @import("std");
const mruby = @import("mruby");
const inspection = mruby.effect.Inspection;
const data = mruby.effect.data;
const artifact = mruby.artifact;
const Receipt = mruby.strict.Turn.Receipt;
const a = std.testing.allocator;

fn receipt(allocator: std.mem.Allocator, name: []const u8, arguments: []const u8, result: []const u8, outcome: enum { returned, rejected }, terminal: artifact.StateCapsuleView) ![]u8 {
    var trace = mruby.effect.Trace.init(allocator, .{ .code = @splat(1), .catalogue = @splat(2), .input = @splat(3) }, .{});
    defer trace.deinit();
    try trace.reserve(name, 7, arguments, result.len);
    try trace.commitOutcome(if (outcome == .rejected) .rejected else .returned, result);
    try trace.finish();
    const encoded = try trace.encode(allocator);
    defer allocator.free(encoded);
    return Receipt.encode(allocator, encoded, terminal, .{});
}

const Fixture = struct {
    arguments: artifact.StateCapsule,
    result: artifact.StateCapsule,
    terminal: artifact.StateCapsule,
    fn init() !Fixture {
        var arguments = try data.encode(a, .{ .array = &.{.{ .integer = 2 }} }, 4096);
        errdefer arguments.deinit(a);
        var result = try data.encode(a, .{ .array = &.{ .{ .string = "OutOfStock" }, .{ .string = "no stock" } } }, 4096);
        errdefer result.deinit(a);
        return .{ .arguments = arguments, .result = result, .terminal = try data.encode(a, .{ .array = &.{ .{ .string = "fallback" }, .{ .hash = &.{.{ .key = .{ .string = "attempts" }, .value = .{ .integer = 1 } }} } } }, 4096) };
    }
    fn deinit(self: *Fixture) void {
        self.arguments.deinit(a);
        self.result.deinit(a);
        self.terminal.deinit(a);
    }
    fn encode(self: *Fixture) ![]u8 {
        return receipt(a, "stock.reserve", self.arguments.encoded, self.result.encoded, .rejected, self.terminal.view());
    }
};

test "inspection owns deterministic JSON and reports rejection with result and state summaries" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const bytes = try fixture.encode();
    defer a.free(bytes);
    var first = try inspection.inspect(a, bytes, .{});
    defer first.deinit();
    var second = try inspection.inspect(a, bytes, .{});
    defer second.deinit();
    try std.testing.expectEqualSlices(u8, first.json(), second.json());
    try std.testing.expectEqual(@as(usize, 1), first.operation_count);
    try std.testing.expectEqual(@as([32]u8, @splat(1)), first.identity.code);
    @memset(bytes, 0);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, first.json(), .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("structure-and-checksums-only", root.get("verification").?.string);
    const op = root.get("operations").?.array.items[0].object;
    try std.testing.expectEqual(@as(i64, 0), op.get("sequence").?.integer);
    try std.testing.expectEqualStrings("rejected", op.get("outcome").?.string);
    try std.testing.expectEqualStrings("OutOfStock", op.get("rejection_code").?.object.get("preview_bytes").?.string);
    try std.testing.expectEqualStrings("hash", root.get("state").?.object.get("kind").?.string);
}

test "inspection validates nested graphs even under checksum-valid framing" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var invalid = try artifact.wrapState(a, "not a graph", .{});
    defer invalid.deinit(a);
    for (0..3) |part| {
        const bytes = try receipt(a, "stock.reserve", if (part == 0) invalid.encoded else fixture.arguments.encoded, if (part == 1) invalid.encoded else fixture.result.encoded, .rejected, if (part == 2) invalid.view() else fixture.terminal.view());
        defer a.free(bytes);
        if (inspection.inspect(a, bytes, .{})) |valid| {
            var unexpected = valid;
            unexpected.deinit();
            return error.AcceptedMalformedGraph;
        } else |_| {}
    }
    const bytes = try fixture.encode();
    defer a.free(bytes);
    bytes[Receipt.header_len] ^= 1;
    try std.testing.expectError(error.ChecksumMismatch, inspection.inspect(a, bytes, .{}));
}

test "inspection requires argument array rejection pair and terminal pair" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var scalar = try data.encode(a, .nil, 4096);
    defer scalar.deinit(a);
    const args = try receipt(a, "stock.reserve", scalar.encoded, fixture.result.encoded, .rejected, fixture.terminal.view());
    defer a.free(args);
    try std.testing.expectError(error.InvalidEffectArguments, inspection.inspect(a, args, .{}));
    const result = try receipt(a, "stock.reserve", fixture.arguments.encoded, scalar.encoded, .rejected, fixture.terminal.view());
    defer a.free(result);
    try std.testing.expectError(error.InvalidEffectRejection, inspection.inspect(a, result, .{}));
    const terminal = try receipt(a, "stock.reserve", fixture.arguments.encoded, fixture.result.encoded, .rejected, scalar.view());
    defer a.free(terminal);
    try std.testing.expectError(error.InvalidTurnResult, inspection.inspect(a, terminal, .{}));
}

test "inspection escapes arbitrary bytes and truncates previews without terminal controls" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var result = try data.encode(a, .{ .string = "\x1b[31m\x00\xff\"\\\nabcdefghijklmnop" }, 4096);
    defer result.deinit(a);
    const bytes = try receipt(a, "op\x1b\x00\xff\n\"", fixture.arguments.encoded, result.encoded, .returned, fixture.terminal.view());
    defer a.free(bytes);
    var report = try inspection.inspect(a, bytes, .{ .max_preview_bytes = 10 });
    defer report.deinit();
    for (report.json(), 0..) |byte, i| try std.testing.expect((byte >= 0x20 and byte <= 0x7e) or (i == report.json().len - 1 and byte == '\n'));
    try std.testing.expect(std.mem.indexOf(u8, report.json(), "\\u001b") != null);
    try std.testing.expect(std.mem.indexOf(u8, report.json(), "\\u00ff") != null);
    try std.testing.expect(std.mem.indexOf(u8, report.json(), "\"truncated\":true") != null);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, report.json(), .{});
    defer parsed.deinit();
}

fn cyclicTerminal() !artifact.StateCapsule {
    var buffer: [256]u8 = undefined;
    var writer = artifact.Writer.init(&buffer);
    try artifact.writeStatePrelude(&writer, .{ .node_count = 2, .edge_count = 3, .root = .{ .node_ref = 0 } });
    try artifact.writeNodeRecordHeader(&writer, .{ .id = 0, .kind = .array, .flags = 0, .body_len = 14 });
    try writer.writeU32(2);
    try artifact.writeValueRef(&writer, .{ .node_ref = 1 });
    try artifact.writeValueRef(&writer, .{ .node_ref = 1 });
    try artifact.writeNodeRecordHeader(&writer, .{ .id = 1, .kind = .array, .flags = 0, .body_len = 9 });
    try writer.writeU32(1);
    try artifact.writeValueRef(&writer, .{ .node_ref = 1 });
    return artifact.wrapState(a, buffer[0..writer.offset], .{});
}

test "inspection previews cycles without recursion and preserves cross-root node identity" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var terminal = try cyclicTerminal();
    defer terminal.deinit(a);
    const bytes = try receipt(a, "stock.reserve", fixture.arguments.encoded, fixture.result.encoded, .rejected, terminal.view());
    defer a.free(bytes);
    var report = try inspection.inspect(a, bytes, .{});
    defer report.deinit();
    var parsed = try std.json.parseFromSlice(std.json.Value, a, report.json(), .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 1), root.get("result").?.object.get("node_id").?.integer);
    try std.testing.expectEqual(@as(i64, 1), root.get("state").?.object.get("node_id").?.integer);
    try std.testing.expect(report.json().len < 4096);
}

test "inspection bounds input graph work operation names and complete output" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const bytes = try fixture.encode();
    defer a.free(bytes);
    try std.testing.expectError(error.TurnReceiptLimitExceeded, inspection.inspect(a, bytes, .{ .max_receipt_bytes = bytes.len - 1 }));
    try std.testing.expectError(error.TraceLimitExceeded, inspection.inspect(a, bytes, .{ .max_operations = 0 }));
    try std.testing.expectError(error.InspectionLimitExceeded, inspection.inspect(a, bytes, .{ .max_name_bytes = 1 }));
    try std.testing.expectError(error.InspectionLimitExceeded, inspection.inspect(a, bytes, .{ .max_total_nodes = 0 }));
    try std.testing.expectError(error.InspectionLimitExceeded, inspection.inspect(a, bytes, .{ .max_total_edges = 0 }));
    try std.testing.expectError(error.InspectionOutputLimitExceeded, inspection.inspect(a, bytes, .{ .max_output_bytes = 10 }));
    var report = try inspection.inspect(a, bytes, .{});
    defer report.deinit();
    var exact = try inspection.inspect(a, bytes, .{ .max_output_bytes = report.json().len });
    defer exact.deinit();
    try std.testing.expectError(error.InspectionOutputLimitExceeded, inspection.inspect(a, bytes, .{ .max_output_bytes = report.json().len - 1 }));
}

fn allocationFailures(allocator: std.mem.Allocator, bytes: []const u8) !void {
    var report = try inspection.inspect(allocator, bytes, .{});
    defer report.deinit();
}

test "inspection releases every partial allocation" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const bytes = try fixture.encode();
    defer a.free(bytes);
    try std.testing.checkAllAllocationFailures(a, allocationFailures, .{bytes});
}

test "inspection accepts pure receipts and renders non-finite scalars as exact bits" {
    var terminal = try data.encode(a, .{ .array = &.{
        .{ .float = std.math.nan(f64) },
        .{ .hash = &.{
            .{ .key = .{ .symbol = "infinity" }, .value = .{ .float = std.math.inf(f64) } },
            .{ .key = .{ .string = "ready" }, .value = .{ .boolean = true } },
        } },
    } }, 4096);
    defer terminal.deinit(a);
    var trace = mruby.effect.Trace.init(a, .{ .code = @splat(0), .catalogue = @splat(0), .input = @splat(0) }, .{});
    defer trace.deinit();
    try trace.finish();
    const encoded_trace = try trace.encode(a);
    defer a.free(encoded_trace);
    const bytes = try Receipt.encode(a, encoded_trace, terminal.view(), .{});
    defer a.free(bytes);
    var report = try inspection.inspect(a, bytes, .{});
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 0), report.operation_count);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, report.json(), .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqual(@as(usize, 16), root.get("result").?.object.get("ieee754_bits").?.string.len);
    const entries = root.get("state").?.object.get("entries").?.array.items;
    try std.testing.expectEqualStrings("7ff0000000000000", entries[0].object.get("value").?.object.get("ieee754_bits").?.string);
    try std.testing.expect(entries[1].object.get("value").?.object.get("value").?.bool);
}
