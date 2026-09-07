const std = @import("std");
const mruby = @import("mruby");
const effect = mruby.effect;
const testing = std.testing;

fn Catalogue(comptime maximum: i64) type {
    return struct {
        pub const operations = .{.{
            .name = "stock.reserve",
            .namespace = "Stock",
            .method = "reserve",
            .arity = @as(usize, 1),
            .authority_bits = @as(u16, 1 << 13),
            .contract = .{
                .arguments = .{ .tuple = .{.{ .integer = .{ .min = 1, .max = maximum } }} },
                .result = .integer,
                .rejection = .{ .codes = .{"OutOfStock"}, .max_message_bytes = 32 },
            },
        }};
    };
}
const operations = Catalogue(8).operations;
const Probe = struct {
    calls: usize = 0,
    outcome: enum { valid, wrong_type, rejected, bad_code, bad_pair } = .valid,
    fn handle(context: ?*anyopaque, vm: *mruby.Vm, _: mruby.Value) !effect.Outcome {
        const self: *Probe = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        return switch (self.outcome) {
            .valid => .{ .returned = try vm.intValue(42) },
            .wrong_type => .{ .returned = try vm.stringValue("wrong") },
            .rejected => effect.reject(vm, "OutOfStock", "none available"),
            .bad_code => effect.reject(vm, "SecretFailure", "not declared"),
            .bad_pair => .{ .rejected = (try vm.array(&.{ try vm.intValue(1), try vm.intValue(2) })).asValue() },
        };
    }
};
fn spawn(comptime descriptors: anytype, probe: *Probe, mode: effect.Mode) !mruby.sandbox.Isolate {
    var boot = try mruby.sandbox.BootstrapIsolate.spawn(mruby.sandbox.Policy.restricted(.{}));
    defer boot.deinit();
    try effect.install(boot.vm(), descriptors, .{
        .allowed = &.{"stock.reserve"},
        .mode = mode,
        .bindings = &.{.{ .name = "stock.reserve", .outcome_handler = Probe.handle, .context = probe }},
    });
    return boot.seal();
}
const program = "begin; Effect.perform(Stock.reserve(2)); rescue Effect::Rejected => e; e.code; end";

test "typed requests stay inert and invalid arguments poison performed live and recorded executions" {
    for ([_]effect.Mode{ .live, .record }) |mode| {
        var probe: Probe = .{};
        const iso = try spawn(operations, &probe, mode);
        defer iso.deinit();
        _ = try iso.run("Stock.reserve(0)");
        try testing.expectEqual(@as(usize, 0), probe.calls);
        try testing.expectError(error.EffectContractViolation, iso.run("begin; Effect.perform(Stock.reserve(0)); rescue; 99; end"));
        try testing.expectEqual(@as(usize, 0), probe.calls);
        const detail = (try iso.effectDiagnostic()).?;
        try testing.expectEqual(.contract, detail.reason);
        try testing.expectEqual(.arguments, detail.contract_detail.?.side);
        try testing.expectEqual(.integer_range, detail.contract_detail.?.reason);
        if (mode == .record) {
            var trace = try iso.takeEffectTrace();
            defer trace.deinit();
            try testing.expect(!trace.isComplete());
        }
    }
}

test "typed legacy adapter results and unexpected rejection codes remain fatal after rescue" {
    for ([_]Probe{ .{ .outcome = .wrong_type }, .{ .outcome = .bad_code }, .{ .outcome = .bad_pair } }) |initial| {
        var probe = initial;
        const iso = try spawn(operations, &probe, .record);
        defer iso.deinit();
        try testing.expectError(error.EffectContractViolation, iso.run("begin; Effect.perform(Stock.reserve(2)); rescue; 99; end"));
        try testing.expectEqual(@as(usize, 1), probe.calls);
        const mismatch = (try iso.effectDiagnostic()).?.contract_detail.?;
        try testing.expectEqual(if (probe.outcome == .wrong_type) effect.schema.Side.result else .rejection, mismatch.side);
        if (probe.outcome == .bad_pair) {
            try testing.expectEqualStrings("$[0]", mismatch.pathText());
            try testing.expectEqual(.type_mismatch, mismatch.reason);
        }
        var trace = try iso.takeEffectTrace();
        defer trace.deinit();
        try testing.expect(!trace.isComplete());
    }
}

test "typed expected rejections replay without adapters and schema changes invalidate old traces" {
    var probe: Probe = .{ .outcome = .rejected };
    const recording = try spawn(operations, &probe, .record);
    defer recording.deinit();
    try testing.expectEqualStrings("OutOfStock", try (try recording.run(program)).asString());
    var trace = try recording.takeEffectTrace();
    defer trace.deinit();
    const bytes = try trace.encode(testing.allocator);
    defer testing.allocator.free(bytes);
    var replay_probe: Probe = .{};
    const replay = try spawn(operations, &replay_probe, .{ .replay = bytes });
    defer replay.deinit();
    try testing.expectEqualStrings("OutOfStock", try (try replay.run(program)).asString());
    const changed = try spawn(Catalogue(9).operations, &replay_probe, .{ .replay = bytes });
    defer changed.deinit();
    try testing.expectError(error.EffectTraceIdentityMismatch, changed.run(program));
    try testing.expectEqual(@as(usize, 0), replay_probe.calls);
}

test "typed replay rejects structurally valid tampered outcomes against its contract" {
    var probe: Probe = .{};
    const recording = try spawn(operations, &probe, .record);
    defer recording.deinit();
    _ = try recording.run(program);
    var original = try recording.takeEffectTrace();
    defer original.deinit();
    const record = original.get(0).?;
    var invalid = try effect.data.encode(testing.allocator, .{ .string = "wrong" }, 256);
    defer invalid.deinit(testing.allocator);
    var changed = effect.Trace.init(testing.allocator, original.identity, .{});
    defer changed.deinit();
    try changed.reserve(record.name, record.version, record.arguments, invalid.encoded.len);
    try changed.commit(invalid.encoded);
    try changed.finish();
    const bytes = try changed.encode(testing.allocator);
    defer testing.allocator.free(bytes);
    const replay = try spawn(operations, &probe, .{ .replay = bytes });
    defer replay.deinit();
    try testing.expectError(error.EffectContractViolation, replay.run(program));
    try testing.expectEqual(.result, (try replay.effectDiagnostic()).?.contract_detail.?.side);
    try testing.expectEqual(@as(usize, 1), probe.calls);
}

test "contract catalogue rejects malformed schemas and arity drift before installation" {
    const arity_drift = .{.{ .name = "x", .namespace = "X", .method = "x", .arity = 1, .authority_bits = 0, .contract = .{ .arguments = .{ .tuple = .{} }, .result = .nil } }};
    const malformed = .{.{ .name = "x", .namespace = "X", .method = "x", .arity = 0, .authority_bits = 0, .contract = .{ .arguments = .integer, .result = .nil } }};
    try testing.expectError(error.InvalidEffectContract, effect.describeCatalogue(arity_drift));
    try testing.expectError(error.InvalidEffectContract, effect.describeCatalogue(malformed));
    const normalized = comptime try effect.describeCatalogue(operations);
    try testing.expectEqual(@as(usize, 1), normalized[0].contract.?.arity());
    try testing.expectEqualSlices(u8, &(try effect.catalogueIdentity(operations)), &(try effect.catalogueIdentity(normalized)));
}
