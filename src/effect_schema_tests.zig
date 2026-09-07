const std = @import("std");
const mruby = @import("mruby");
const schema = mruby.effect.schema;
const data = mruby.effect.data;
const artifact = mruby.artifact;
const allocator = std.testing.allocator;

fn check(contract: *const schema.Contract, side: schema.Side, value: data.Value) !?schema.Mismatch {
    var capsule = try data.encode(allocator, value, 16 * 1024);
    defer capsule.deinit(allocator);
    var document = try data.Document.decode(allocator, capsule.view(), 16 * 1024);
    defer document.deinit();
    return schema.validate(contract, side, document.root());
}
fn failure(contract: *const schema.Contract, side: schema.Side, value: data.Value, reason: schema.Reason, path: []const u8) !void {
    const detail = (try check(contract, side, value)) orelse return error.ExpectedMismatch;
    try std.testing.expectEqual(side, detail.side);
    try std.testing.expectEqual(reason, detail.reason);
    try std.testing.expectEqualStrings(path, detail.pathText());
}

test "operation schemas check exact scalar types bounds and argument paths" {
    const contract = comptime try schema.compile(.{
        .arguments = .{ .tuple = .{ .{ .string = .{ .min_bytes = 1, .max_bytes = 4 } }, .{ .integer = .{ .min = 1, .max = 10 } } } },
        .result = .float,
    });
    const good: data.Value = .{ .array = &.{ .{ .string = "sku" }, .{ .integer = 10 } } };
    try std.testing.expectEqual(@as(?schema.Mismatch, null), try check(&contract, .arguments, good));
    try failure(&contract, .arguments, .{ .array = &.{ .{ .string = "sku" }, .{ .float = 2.0 } } }, .type_mismatch, "$[1]");
    try failure(&contract, .arguments, .{ .array = &.{ .{ .symbol = "sku" }, .{ .integer = 2 } } }, .type_mismatch, "$[0]");
    try failure(&contract, .arguments, .{ .array = &.{ .{ .string = "" }, .{ .integer = 2 } } }, .string_length, "$[0]");
    try failure(&contract, .arguments, .{ .array = &.{ .{ .string = "sku" }, .{ .integer = 0 } } }, .integer_range, "$[1]");
    try failure(&contract, .arguments, .{ .array = &.{.{ .string = "sku" }} }, .array_length, "$");
    try failure(&contract, .result, .{ .float = std.math.inf(f64) }, .non_finite, "$");
    try failure(&contract, .result, .{ .float = std.math.nan(f64) }, .non_finite, "$");
    try std.testing.expectEqual(@as(?schema.Mismatch, null), try check(&contract, .result, .{ .float = -0.0 }));
}

test "operation schema objects require exact String keys and explicit optional fields" {
    const contract = comptime try schema.compile(.{
        .arguments = .{ .tuple = .{} },
        .result = .{ .object = .{
            .{ .name = "id", .schema = .integer },
            .{ .name = "label", .schema = .{ .nullable = .{ .string = .{ .max_bytes = 8 } } }, .optional = true },
        } },
    });
    const id: data.Pair = .{ .key = .{ .string = "id" }, .value = .{ .integer = 1 } };
    try std.testing.expectEqual(@as(?schema.Mismatch, null), try check(&contract, .result, .{ .hash = &.{id} }));
    try std.testing.expectEqual(@as(?schema.Mismatch, null), try check(&contract, .result, .{ .hash = &.{ id, .{ .key = .{ .string = "label" }, .value = .nil } } }));
    try failure(&contract, .result, .{ .hash = &.{} }, .missing_field, "$[\"id\"]");
    try failure(&contract, .result, .{ .hash = &.{ id, .{ .key = .{ .string = "surprise" }, .value = .nil } } }, .extra_field, "$[\"surprise\"]");
    try failure(&contract, .result, .{ .hash = &.{.{ .key = .{ .symbol = "id" }, .value = .{ .integer = 1 } }} }, .extra_field, "$[0]");
    try failure(&contract, .result, .{ .hash = &.{.{ .key = .{ .string = "id" }, .value = .nil }} }, .type_mismatch, "$[\"id\"]");
}

test "operation schemas admit only declared rejection codes and bounded messages" {
    const contract = comptime try schema.compile(.{
        .arguments = .{ .tuple = .{} },
        .result = .nil,
        .rejection = .{ .codes = .{ "OutOfStock", "Busy" }, .max_message_bytes = 4 },
    });
    try std.testing.expectEqual(@as(?schema.Mismatch, null), try check(&contract, .rejection, .{ .array = &.{ .{ .string = "Busy" }, .{ .string = "wait" } } }));
    try failure(&contract, .rejection, .{ .array = &.{ .{ .string = "Other" }, .{ .string = "wait" } } }, .enum_value, "$[0]");
    try failure(&contract, .rejection, .{ .array = &.{ .{ .string = "Busy" }, .{ .string = "longer" } } }, .string_length, "$[1]");
    const none = comptime try schema.compile(.{ .arguments = .{ .tuple = .{} }, .result = .nil });
    try failure(&none, .rejection, .{ .array = &.{ .{ .string = "Busy" }, .{ .string = "wait" } } }, .rejection_forbidden, "$");
}

test "operation schemas allow real capsule aliases but reject cycles" {
    const contract = comptime try schema.compile(.{ .arguments = .{ .tuple = .{} }, .result = .{ .array = .{ .element = .{ .array = .{ .element = .integer, .max_items = 2 } }, .max_items = 2 } } });
    var inner = try data.encode(allocator, .{ .array = &.{.{ .integer = 1 }} }, 4096);
    defer inner.deinit(allocator);
    var inner_doc = try data.Document.decode(allocator, inner.view(), 4096);
    defer inner_doc.deinit();
    var shared = try data.encodeRefs(allocator, &.{ inner_doc.root(), inner_doc.root() }, 4096);
    defer shared.deinit(allocator);
    var shared_doc = try data.Document.decode(allocator, shared.view(), 4096);
    defer shared_doc.deinit();
    try std.testing.expectEqual((try shared_doc.root().at(0)).nodeId(), (try shared_doc.root().at(1)).nodeId());
    try std.testing.expectEqual(@as(?schema.Mismatch, null), schema.validate(&contract, .result, shared_doc.root()));

    var payload: [34]u8 = undefined;
    var writer = artifact.Writer.init(&payload);
    try artifact.writeStatePrelude(&writer, .{ .node_count = 1, .edge_count = 1, .root = .{ .node_ref = 0 } });
    try artifact.writeNodeRecordHeader(&writer, .{ .id = 0, .kind = .array, .flags = 0, .body_len = 9 });
    try writer.writeU32(1);
    try artifact.writeValueRef(&writer, .{ .node_ref = 0 });
    try writer.finish();
    var cyclic = try artifact.wrapState(allocator, &payload, .{});
    defer cyclic.deinit(allocator);
    var cyclic_doc = try data.Document.decode(allocator, cyclic.view(), 4096);
    defer cyclic_doc.deinit();
    const detail = schema.validate(&contract, .result, cyclic_doc.root()).?;
    try std.testing.expectEqual(schema.Reason.cycle, detail.reason);
    try std.testing.expectEqualStrings("$[0]", detail.pathText());
}

test "operation schema validation bounds repeated traversal of shared capsule DAGs" {
    const contract = comptime try schema.compile(.{ .arguments = .{ .tuple = .{} }, .result = .{ .array = .{ .max_items = 512, .element = .{ .array = .{ .max_items = 512, .element = .nil } } } } });
    const values: [512]data.Value = @splat(.nil);
    var inner = try data.encode(allocator, .{ .array = &values }, 16 * 1024);
    defer inner.deinit(allocator);
    var document = try data.Document.decode(allocator, inner.view(), 16 * 1024);
    defer document.deinit();
    const refs: [512]data.Ref = @splat(document.root());
    var shared = try data.encodeRefs(allocator, &refs, 16 * 1024);
    defer shared.deinit(allocator);
    var shared_doc = try data.Document.decode(allocator, shared.view(), 16 * 1024);
    defer shared_doc.deinit();
    try std.testing.expectEqual(schema.Reason.work_limit, schema.validate(&contract, .result, shared_doc.root()).?.reason);
}

test "operation schema objects reject nonnil Hash defaults without following them" {
    const contract = comptime try schema.compile(.{ .arguments = .{ .tuple = .{} }, .result = .{ .object = .{} } });
    for ([_]artifact.ValueRef{ .nil, .{ .integer = 3 } }) |default| {
        var payload: [64]u8 = undefined;
        var writer = artifact.Writer.init(&payload);
        try artifact.writeStatePrelude(&writer, .{ .node_count = 1, .edge_count = 1, .root = .{ .node_ref = 0 } });
        try artifact.writeNodeRecordHeader(&writer, .{ .id = 0, .kind = .hash, .flags = artifact.flags.hash_has_default, .body_len = @intCast(4 + try default.encodedLen()) });
        try writer.writeU32(0);
        try artifact.writeValueRef(&writer, default);
        var capsule = try artifact.wrapState(allocator, payload[0..writer.offset], .{});
        defer capsule.deinit(allocator);
        var document = try data.Document.decode(allocator, capsule.view(), 4096);
        defer document.deinit();
        const result = schema.validate(&contract, .result, document.root());
        if (default == .nil) try std.testing.expectEqual(@as(?schema.Mismatch, null), result) else try std.testing.expectEqual(schema.Reason.hash_default, result.?.reason);
    }
}

const long_name = "a-long-field-name-that-is-deliberately-repeated-in-several-levels-of-a-bounded-owned-diagnostic-path";
fn Nested(comptime depth: usize) type {
    return struct {
        const shape = .{ .object = .{.{ .name = long_name, .schema = if (depth == 0) .integer else Nested(depth - 1).shape }} };
        const value: data.Value = .{ .hash = &.{.{ .key = .{ .string = long_name }, .value = if (depth == 0) .nil else Nested(depth - 1).value }} };
    };
}
test "operation schema mismatch owns a bounded truncated field path" {
    const contract = comptime try schema.compile(.{ .arguments = .{ .tuple = .{} }, .result = Nested(3).shape });
    const detail = (try check(&contract, .result, Nested(3).value)).?;
    try std.testing.expectEqual(schema.Reason.type_mismatch, detail.reason);
    try std.testing.expect(detail.path_truncated);
    try std.testing.expectEqual(@as(usize, 256), detail.pathText().len);
    try std.testing.expect(std.mem.startsWith(u8, detail.pathText(), "$[\"a-long-field"));
}

test "turn contracts validate all four sides using the same inert schema rules" {
    const contract = comptime try mruby.strict.Turn.Contract.from(.{
        .state = .{ .integer = .{ .min = 0, .max = 10 } },
        .input = .{ .string = .{ .max_bytes = 4 } },
        .result = .{ .tuple = .{ .integer, .boolean } },
    });
    inline for (.{
        .{ .side = .state, .good = @as(data.Value, .{ .integer = 1 }), .bad = @as(data.Value, .{ .integer = -1 }), .reason = .integer_range, .path = "$" },
        .{ .side = .input, .good = @as(data.Value, .{ .string = "okay" }), .bad = @as(data.Value, .{ .string = "longer" }), .reason = .string_length, .path = "$" },
        .{ .side = .result, .good = @as(data.Value, .{ .array = &.{ .{ .integer = 1 }, .{ .boolean = true } } }), .bad = @as(data.Value, .{ .array = &.{ .{ .integer = 1 }, .{ .integer = 2 } } }), .reason = .type_mismatch, .path = "$[1]" },
        .{ .side = .next_state, .good = @as(data.Value, .{ .integer = 10 }), .bad = @as(data.Value, .{ .integer = -1 }), .reason = .integer_range, .path = "$" },
    }) |case| {
        for ([_]data.Value{ case.good, case.bad }, 0..) |value, i| {
            var capsule = try data.encode(allocator, value, 4096);
            defer capsule.deinit(allocator);
            var document = try data.Document.decode(allocator, capsule.view(), 4096);
            const mismatch = contract.validate(case.side, document.root());
            document.deinit();
            if (i == 0) {
                try std.testing.expect(mismatch == null);
            } else {
                try std.testing.expectEqual(case.side, mismatch.?.side);
                try std.testing.expectEqual(case.reason, mismatch.?.detail.reason);
                try std.testing.expectEqualStrings(case.path, mismatch.?.detail.pathText());
            }
        }
    }
}

test "standalone shape uses operation alias-cycle rules and checked owned copies" {
    const literal = .{ .array = .{ .element = .{ .array = .{ .element = .integer, .max_items = 2 } }, .max_items = 2 } };
    var original = try schema.compileShape(literal);
    const copied = try original.checkedCopy();
    const digest = copied.digest();
    original.graph.roots[0] = 1000;
    try std.testing.expectError(error.InvalidEffectContract, original.checkedCopy());
    try std.testing.expectEqualSlices(u8, &digest, &copied.digest());

    var payload: [34]u8 = undefined;
    var writer = artifact.Writer.init(&payload);
    try artifact.writeStatePrelude(&writer, .{ .node_count = 1, .edge_count = 1, .root = .{ .node_ref = 0 } });
    try artifact.writeNodeRecordHeader(&writer, .{ .id = 0, .kind = .array, .flags = 0, .body_len = 9 });
    try writer.writeU32(1);
    try artifact.writeValueRef(&writer, .{ .node_ref = 0 });
    try writer.finish();
    var cyclic = try artifact.wrapState(allocator, &payload, .{});
    defer cyclic.deinit(allocator);
    var document = try data.Document.decode(allocator, cyclic.view(), 4096);
    defer document.deinit();
    const detail = copied.validate(document.root()).?;
    try std.testing.expectEqual(schema.Reason.cycle, detail.reason);
    try std.testing.expectEqualStrings("$[0]", detail.pathText());
}
