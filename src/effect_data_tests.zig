const std = @import("std");
const mruby = @import("mruby");
const data = mruby.effect.data;
const artifact = mruby.artifact;

test "combining independent documents matches Ruby argument export with cycles and Hash defaults" {
    if (comptime !mruby.features.has_compiler) return;
    const allocator = std.testing.allocator;
    var bootstrap = try mruby.sandbox.BootstrapIsolate.spawn(mruby.sandbox.Policy.restricted(.{}));
    defer bootstrap.deinit();
    const iso = try bootstrap.seal();
    defer iso.deinit();
    const original = try (try iso.run(
        \\shared = "shared".freeze
        \\cycle = []
        \\cycle << cycle << shared << shared
        \\h = Hash.new(cycle)
        \\h["key"] = cycle
        \\h.freeze
        \\[[h, cycle, shared].freeze, [h, cycle, shared].freeze]
    )).asArray();
    var state = try iso.exportValue(allocator, try original.get(0), .{});
    defer state.deinit(allocator);
    var input = try iso.exportValue(allocator, try original.get(1), .{});
    defer input.deinit(allocator);
    var state_doc = try data.Document.decode(allocator, state.view(), 4096);
    defer state_doc.deinit();
    var input_doc = try data.Document.decode(allocator, input.view(), 4096);
    defer input_doc.deinit();
    const state_value = try iso.importValue(state.view(), .{});
    const input_value = try iso.importValue(input.view(), .{});
    const array_class = try iso.run("Array");
    const joined_value = try iso.call(array_class, "[]", .{ state_value, input_value });
    var expected = try iso.exportValue(allocator, joined_value, .{});
    defer expected.deinit(allocator);
    var actual = try data.encodeRefs(allocator, &.{ state_doc.root(), input_doc.root() }, 4096);
    defer actual.deinit(allocator);
    try std.testing.expectEqualSlices(u8, expected.encoded, actual.encoded);

    const shared_value = try iso.call(array_class, "[]", .{ state_value, state_value });
    var shared_expected = try iso.exportValue(allocator, shared_value, .{});
    defer shared_expected.deinit(allocator);
    var shared_actual = try data.encodeRefs(allocator, &.{ state_doc.root(), state_doc.root() }, 4096);
    defer shared_actual.deinit(allocator);
    try std.testing.expectEqualSlices(u8, shared_expected.encoded, shared_actual.encoded);
    try std.testing.expect(!std.mem.eql(u8, actual.encoded, shared_actual.encoded));
}

test "combining no roots and immediate roots has canonical Array framing" {
    const allocator = std.testing.allocator;
    var nil_capsule = try data.encode(allocator, .nil, 4096);
    defer nil_capsule.deinit(allocator);
    var doc = try data.Document.decode(allocator, nil_capsule.view(), 4096);
    defer doc.deinit();
    var empty = try data.encodeRefs(allocator, &.{}, 4096);
    defer empty.deinit(allocator);
    var empty_expected = try data.encode(allocator, .{ .array = &.{} }, 4096);
    defer empty_expected.deinit(allocator);
    try std.testing.expectEqualSlices(u8, empty_expected.encoded, empty.encoded);
    var pair = try data.encodeRefs(allocator, &.{ doc.root(), doc.root() }, 4096);
    defer pair.deinit(allocator);
    var pair_expected = try data.encode(allocator, .{ .array = &.{ .nil, .nil } }, 4096);
    defer pair_expected.deinit(allocator);
    try std.testing.expectEqualSlices(u8, pair_expected.encoded, pair.encoded);
    try std.testing.expectError(error.ArtifactLimitExceeded, data.encodeRefs(allocator, &.{doc.root()}, 24));
}

fn roundTrip(allocator: std.mem.Allocator) !void {
    var capsule = try data.encode(allocator, .{ .hash = &.{
        .{ .key = .{ .string = "value" }, .value = .{ .array = &.{ .{ .integer = -42 }, .{ .string = "hello" }, .{ .boolean = true }, .nil, .{ .float = 1.25 } } } },
        .{ .key = .{ .symbol = "value" }, .value = .{ .symbol = "distinct" } },
    } }, 4096);
    defer capsule.deinit(allocator);
    var doc = try data.Document.decode(allocator, capsule.view(), 4096);
    defer doc.deinit();
    try std.testing.expectEqual(data.Kind.hash, doc.root().kind());
    try std.testing.expectEqual(2, try doc.root().len());
    const values = (try doc.root().get("value")).?;
    try std.testing.expectEqual(-42, try (try values.at(0)).asInteger());
    try std.testing.expectEqualStrings("hello", try (try values.at(1)).asString());
    try std.testing.expect(try (try values.at(2)).asBoolean());
    try std.testing.expectEqual(data.Kind.nil, (try values.at(3)).kind());
    try std.testing.expectEqual(1.25, try (try values.at(4)).asFloat());
    try std.testing.expectEqualStrings("distinct", try (try doc.root().getSymbol("value")).?.asSymbol());
    try std.testing.expect((try doc.root().pair(0)).key.isFrozen());
    try std.testing.expect(try doc.root().get("absent") == null);
    try std.testing.expectError(error.TypeMismatch, doc.root().asInteger());
    try std.testing.expectError(error.IndexOutOfBounds, values.at(5));
    var extracted = try data.encodeRef(allocator, values, 4096);
    defer extracted.deinit(allocator);
    var extracted_doc = try data.Document.decode(allocator, extracted.view(), 4096);
    defer extracted_doc.deinit();
    try std.testing.expectEqual(5, try extracted_doc.root().len());
    var independent_doc = try data.Document.decode(allocator, doc.view(), 4096);
    defer independent_doc.deinit();
    var combined = try data.encodeRefs(allocator, &.{ doc.root(), doc.root(), independent_doc.root() }, 8192);
    defer combined.deinit(allocator);
    var combined_doc = try data.Document.decode(allocator, combined.view(), 8192);
    defer combined_doc.deinit();
    try std.testing.expectEqual((try combined_doc.root().at(0)).nodeId(), (try combined_doc.root().at(1)).nodeId());
    try std.testing.expect((try combined_doc.root().at(0)).nodeId() != (try combined_doc.root().at(2)).nodeId());
    try std.testing.expect(!(combined_doc.root().isFrozen()));
}

test "data trees round trip through the existing capsule validator" {
    try roundTrip(std.testing.allocator);
}

test "data encoding and graph extraction release every partial allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, roundTrip, .{});
}

test "documents own input bytes and rejection uses two exact strings" {
    const allocator = std.testing.allocator;
    var outcome = try data.reject(allocator, "insufficient", "too few", 4096);
    var doc = try data.Document.decode(allocator, outcome.rejected.view(), 4096);
    defer doc.deinit();
    outcome.rejected.deinit(allocator);
    try std.testing.expectEqualStrings("insufficient", try (try doc.root().at(0)).asString());
    try std.testing.expectEqualStrings("too few", try (try doc.root().at(1)).asString());
}

test "malformed duplicate and oversized data are rejected" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.ArtifactLimitExceeded, data.encode(allocator, .{ .string = "large" }, 10));
    try std.testing.expectError(error.InvalidArtifact, data.encode(allocator, .{ .hash = &.{
        .{ .key = .{ .string = "duplicate" }, .value = .nil },
        .{ .key = .{ .string = "duplicate" }, .value = .nil },
    } }, 4096));
    try std.testing.expectError(error.InvalidArtifact, data.Document.decode(allocator, .{ .bytes = "malformed" }, 4096));
}

test "extracting a graph reroots canonical IDs and preserves aliases and cycles" {
    const allocator = std.testing.allocator;
    // [42, cycle] where cycle == [cycle, shared_string, shared_string].
    var payload: [91]u8 = undefined;
    var writer = artifact.Writer.init(&payload);
    try artifact.writeStatePrelude(&writer, .{ .node_count = 3, .edge_count = 5, .root = .{ .node_ref = 0 } });
    try artifact.writeNodeRecordHeader(&writer, .{ .id = 0, .kind = .array, .flags = 0, .body_len = 18 });
    try writer.writeU32(2);
    try artifact.writeValueRef(&writer, .{ .integer = 42 });
    try artifact.writeValueRef(&writer, .{ .node_ref = 1 });
    try artifact.writeNodeRecordHeader(&writer, .{ .id = 1, .kind = .array, .flags = artifact.flags.frozen, .body_len = 19 });
    try writer.writeU32(3);
    try artifact.writeValueRef(&writer, .{ .node_ref = 1 });
    try artifact.writeValueRef(&writer, .{ .node_ref = 2 });
    try artifact.writeValueRef(&writer, .{ .node_ref = 2 });
    try artifact.writeNodeRecordHeader(&writer, .{ .id = 2, .kind = .string, .flags = 0, .body_len = 5 });
    try writer.writeU32(1);
    try writer.writeBytes("x");
    try writer.finish();
    var capsule = try artifact.wrapState(allocator, &payload, .{});
    defer capsule.deinit(allocator);
    var document = try data.Document.decode(allocator, capsule.view(), 4096);
    defer document.deinit();
    var next_state = try data.encodeRef(allocator, try document.root().at(1), 4096);
    defer next_state.deinit(allocator);
    var next = try data.Document.decode(allocator, next_state.view(), 4096);
    defer next.deinit();
    try std.testing.expectEqual(0, next.root().nodeId().?);
    try std.testing.expectEqual(next.root().nodeId(), (try next.root().at(0)).nodeId());
    try std.testing.expectEqual((try next.root().at(1)).nodeId(), (try next.root().at(2)).nodeId());
    try std.testing.expect(next.root().isFrozen());
    try std.testing.expectEqualStrings("x", try (try next.root().at(2)).asString());
    var combined = try data.encodeRefs(allocator, &.{ next.root(), next.root(), document.root() }, 4096);
    defer combined.deinit(allocator);
    var copied = try data.Document.decode(allocator, combined.view(), 4096);
    defer copied.deinit();
    const cycle = try copied.root().at(0);
    const independent_cycle = try (try copied.root().at(2)).at(1);
    try std.testing.expectEqual(cycle.nodeId(), (try copied.root().at(1)).nodeId());
    try std.testing.expectEqual(cycle.nodeId(), (try cycle.at(0)).nodeId());
    try std.testing.expect(cycle.nodeId() != independent_cycle.nodeId());
    try std.testing.expectEqual(independent_cycle.nodeId(), (try independent_cycle.at(0)).nodeId());
    try std.testing.expectEqual((try cycle.at(1)).nodeId(), (try cycle.at(2)).nodeId());
    try std.testing.expect(cycle.isFrozen());
}

const operation = .{.{ .name = "echo.call", .namespace = "Echo", .method = "call", .arity = 1, .authority_bits = 1 << 13, .max_result_bytes = 512 }};
const Host = struct {
    calls: usize = 0,
    behavior: enum { echo, reject, malformed, oversized, invalid_rejection, failure } = .echo,
    fn handle(context: ?*anyopaque, allocator: std.mem.Allocator, arguments: artifact.StateCapsuleView) !mruby.effect.DataOutcome {
        const self: *Host = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        switch (self.behavior) {
            .reject => return data.reject(allocator, "expected", "application rejected", 512),
            .malformed => return .{ .returned = .{ .encoded = try allocator.dupe(u8, "malformed") } },
            .oversized => return .{ .returned = try data.encode(allocator, .{ .string = &@as([768]u8, @splat('x')) }, 4096) },
            .invalid_rejection => return .{ .rejected = try data.encode(allocator, .{ .integer = 42 }, 512) },
            .failure => return error.AdapterFailed,
            .echo => {},
        }
        var doc = try data.Document.decode(allocator, arguments, 4096);
        defer doc.deinit();
        return .{ .returned = try data.encodeRef(allocator, try doc.root().at(0), 512) };
    }
};

fn spawn(host: *Host, mode: mruby.effect.Mode, allowed: bool, bounds: mruby.effect.Limits) !mruby.sandbox.Isolate {
    var boot = try mruby.sandbox.BootstrapIsolate.spawn(mruby.sandbox.Policy.restricted(.{}));
    defer boot.deinit();
    try mruby.effect.install(boot.vm(), operation, .{
        .mode = mode,
        .allowed = if (allowed) &.{"echo.call"} else &.{},
        .bindings = &.{.{ .name = "echo.call", .data_handler = Host.handle, .context = host }},
        .limits = bounds,
    });
    return boot.seal();
}

test "data handlers preserve graph results and replay invokes zero callbacks" {
    if (!mruby.features.has_compiler) return error.SkipZigTest;
    const source = "a = ['payload']; a << a; result = Effect.perform(Echo.call(a)); [result[0], result[1].equal?(result)]";
    const encoded = blk: {
        var host: Host = .{};
        const iso = try spawn(&host, .record, true, .{});
        defer iso.deinit();
        const result = try (try iso.run(source)).asArray();
        try std.testing.expectEqualStrings("payload", try (try result.get(0)).asString());
        try std.testing.expect((try result.get(1)).isTruthy());
        try std.testing.expectEqual(1, host.calls);
        var trace = try iso.takeEffectTrace();
        defer trace.deinit();
        try std.testing.expect(trace.isComplete());
        break :blk try trace.encode(std.testing.allocator);
    };
    defer std.testing.allocator.free(encoded);
    var host: Host = .{ .behavior = .failure };
    const replay = try spawn(&host, .{ .replay = encoded }, true, .{});
    defer replay.deinit();
    const result = try (try replay.run(source)).asArray();
    try std.testing.expectEqualStrings("payload", try (try result.get(0)).asString());
    try std.testing.expect((try result.get(1)).isTruthy());
    try std.testing.expectEqual(0, host.calls);
}

test "data expected rejections remain rescuable and replayable" {
    if (!mruby.features.has_compiler) return error.SkipZigTest;
    const source = "begin; Effect.perform(Echo.call(1)); rescue Effect::Rejected => e; [e.code, e.message]; end";
    const encoded = blk: {
        var host: Host = .{ .behavior = .reject };
        const iso = try spawn(&host, .record, true, .{});
        defer iso.deinit();
        const result = try (try iso.run(source)).asArray();
        try std.testing.expectEqualStrings("expected", try (try result.get(0)).asString());
        try std.testing.expectEqualStrings("application rejected", try (try result.get(1)).asString());
        var trace = try iso.takeEffectTrace();
        defer trace.deinit();
        try std.testing.expect(trace.isComplete());
        break :blk try trace.encode(std.testing.allocator);
    };
    defer std.testing.allocator.free(encoded);
    var host: Host = .{};
    const replay = try spawn(&host, .{ .replay = encoded }, true, .{});
    defer replay.deinit();
    const result = try (try replay.run(source)).asArray();
    try std.testing.expectEqualStrings("expected", try (try result.get(0)).asString());
    try std.testing.expectEqual(0, host.calls);
}

test "data invalid outputs and raw adapter failures poison rescued executions" {
    if (!mruby.features.has_compiler) return error.SkipZigTest;
    for ([_]@FieldType(Host, "behavior"){ .malformed, .oversized, .invalid_rejection, .failure }) |behavior| {
        var host: Host = .{ .behavior = behavior };
        const iso = try spawn(&host, .record, true, .{});
        defer iso.deinit();
        const expected = switch (behavior) {
            .oversized => error.EffectLimitExceeded,
            .failure => error.EffectHandlerFailed,
            else => error.InvalidEffectRequest,
        };
        try std.testing.expectError(expected, iso.run("begin; Effect.perform(Echo.call(1)); rescue; 42; end"));
        try std.testing.expectEqual(1, host.calls);
        var trace = try iso.takeEffectTrace();
        defer trace.deinit();
        try std.testing.expect(!trace.isComplete());
        try std.testing.expectEqual(0, trace.len());
        if (behavior != .failure) try std.testing.expectEqual(mruby.effect.Diagnostic.Reason.invalid_result, (try iso.effectDiagnostic()).?.reason);
    }
}

test "data dispatch rejects permission and trace capacity before callbacks" {
    if (!mruby.features.has_compiler) return error.SkipZigTest;
    var host: Host = .{};
    const denied = try spawn(&host, .record, false, .{});
    defer denied.deinit();
    try std.testing.expectError(error.EffectDenied, denied.run("Effect.perform(Echo.call(1))"));
    const limited = try spawn(&host, .record, true, .{ .max_bytes = 500 });
    defer limited.deinit();
    try std.testing.expectError(error.EffectLimitExceeded, limited.run("Effect.perform(Echo.call(1))"));
    try std.testing.expectEqual(0, host.calls);
}

test "data bindings require exactly one handler and pure catalogues may be empty" {
    const Legacy = struct {
        fn handle(_: ?*anyopaque, _: *mruby.Vm, value: mruby.Value) !mruby.Value {
            return value;
        }
    };
    var boot = try mruby.sandbox.BootstrapIsolate.spawn(mruby.sandbox.Policy.restricted(.{}));
    defer boot.deinit();
    try std.testing.expectError(error.InvalidEffectBinding, mruby.effect.install(boot.vm(), operation, .{
        .bindings = &.{.{ .name = "echo.call" }},
    }));
    try std.testing.expectError(error.InvalidEffectBinding, mruby.effect.install(boot.vm(), operation, .{
        .bindings = &.{.{ .name = "echo.call", .handler = Legacy.handle, .data_handler = Host.handle }},
    }));
    try std.testing.expectError(error.DuplicateEffectBinding, mruby.effect.install(boot.vm(), operation, .{
        .bindings = &.{
            .{ .name = "echo.call", .data_handler = Host.handle },
            .{ .name = "echo.call", .data_handler = Host.handle },
        },
    }));
    try mruby.effect.install(boot.vm(), .{}, .{ .mode = .record });
    const isolate = try boot.seal();
    defer isolate.deinit();
    if (mruby.features.has_compiler) {
        try std.testing.expectEqual(42, try (try isolate.run("40 + 2")).asInt());
        var trace = try isolate.takeEffectTrace();
        defer trace.deinit();
        try std.testing.expect(trace.isComplete());
        try std.testing.expectEqual(0, trace.len());
        try std.testing.expectError(error.InvalidEffectRequest, isolate.run("Effect.perform(nil)"));
    }
}
