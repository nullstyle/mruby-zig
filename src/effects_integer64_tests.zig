const std = @import("std");
const mruby = @import("mruby");
const example = @import("integer64_example");
const config = @import("integer64_test_config");
const Turn = mruby.strict.Turn;
const Worker = mruby.strict.Worker;
const data = mruby.effect.data;
const artifact = mruby.artifact;
const a = std.testing.allocator;
const testing = std.testing;

test "integer64 profile exposes exact numeric and strict build features" {
    try testing.expect(mruby.features.effects_integer64);
    try testing.expect(mruby.features.effects_strict);
    try testing.expect(!mruby.features.has_float);
    try testing.expectEqual(@as(u8, 64), mruby.features.integer_bits);
    try testing.expectEqual(@as(u8, 0), mruby.features.float_bits);
    try testing.expect(!mruby.features.has_compiler);
}

test "integer64 canonical corpus checks native and bytecode boundaries without Float intermediates" {
    try example.runCorpus(a, false);
}

const FloatSite = enum { root, array, key, value, default };
fn floatCapsule(site: FloatSite) !artifact.StateCapsule {
    return switch (site) {
        .root => data.encode(a, .{ .float = 1.25 }, 4096),
        .array => data.encode(a, .{ .array = &.{ .{ .integer = 1 }, .{ .array = &.{.{ .float = 1.25 }} } } }, 4096),
        .key => data.encode(a, .{ .hash = &.{.{ .key = .{ .float = 1.25 }, .value = .nil }} }, 4096),
        .value => data.encode(a, .{ .hash = &.{.{ .key = .{ .string = "hidden" }, .value = .{ .float = 1.25 } }} }, 4096),
        .default => blk: {
            var bytes: [64]u8 = undefined;
            var writer = artifact.Writer.init(&bytes);
            try artifact.writeStatePrelude(&writer, .{ .node_count = 1, .edge_count = 1, .root = .{ .node_ref = 0 } });
            try artifact.writeNodeRecordHeader(&writer, .{ .id = 0, .kind = .hash, .flags = artifact.flags.hash_has_default, .body_len = 13 });
            try writer.writeU32(0);
            try artifact.writeValueRef(&writer, .{ .float = @bitCast(@as(f64, 1.25)) });
            break :blk try artifact.wrapState(a, bytes[0..writer.offset], .{});
        },
    };
}
const sites = [_]FloatSite{ .root, .array, .key, .value, .default };

test "integer64 execution rejects Float at every graph site while structural inspection preserves the format" {
    var boot = try mruby.sandbox.BootstrapIsolate.spawn(mruby.sandbox.Policy.restricted(.{}));
    defer boot.deinit();
    const iso = try boot.seal();
    defer iso.deinit();
    for (sites) |site| {
        var capsule = try floatCapsule(site);
        defer capsule.deinit(a);
        var doc = try data.Document.decode(a, capsule.view(), 4096);
        defer doc.deinit();
        try testing.expectEqualSlices(u8, capsule.encoded, doc.view().bytes);
        try testing.expectError(error.NumericPolicyViolation, data.Document.decodeWithOptions(a, capsule.view(), .{ .limits = data.limits(4096), .allow_float = false }));
        try testing.expectError(error.NumericPolicyViolation, iso.importValue(capsule.view(), .{}));
    }
    const vm = try mruby.Vm.init();
    defer vm.deinit();
    try testing.expectError(error.NumericPolicyViolation, vm.floatValue(1.25));
}

test "integer64 Float state and input fail before worker spawn or host transaction without schemas" {
    var nil = try data.encode(a, .nil, 4096);
    defer nil.deinit(a);
    for (sites) |site| {
        var bad = try floatCapsule(site);
        defer bad.deinit(a);
        for ([_]bool{ false, true }) |as_state| {
            var host: example.Host = .{};
            const bindings = host.bindings();
            var observed: Worker.Observation = .{};
            try testing.expectError(error.NumericPolicyViolation, Worker.prepare(a, "/nonexistent/integer64-worker-must-not-start", example.manifest, "app", example.contract.operations, example.request(if (as_state) bad.view() else nil.view(), if (as_state) nil.view() else bad.view()), .{ .bindings = &bindings, .transaction = host.transaction() }, .{ .turn = .{ .allowed = example.contract.grants }, .observation = &observed }));
            try testing.expect(observed.execution_pid == null and observed.verification_pid == null);
            try testing.expectEqual(@as(usize, 0), host.begins + host.stages + host.reads + host.commits + host.discards + host.pending + host.durable);
        }
    }
}

test "integer64 malformed Float adapter outcomes discard earlier staged work despite Ruby rescue" {
    var nil = try data.encode(a, .nil, 4096);
    defer nil.deinit(a);
    var input = try example.input(a, "adapter_float", 0, 0);
    defer input.deinit(a);
    for (sites) |site| {
        var bad = try floatCapsule(site);
        defer bad.deinit(a);
        var host: example.Host = .{ .response = bad.view() };
        const bindings = host.bindings();
        var diagnostic: Turn.Diagnostic = .{};
        try testing.expectError(error.NumericPolicyViolation, Worker.prepare(a, config.worker_executable, example.manifest, "app", example.contract.operations, example.request(nil.view(), input.view()), .{ .bindings = &bindings, .transaction = host.transaction() }, .{ .turn = .{ .allowed = example.contract.grants, .diagnostic = &diagnostic } }));
        try testing.expectEqual(@as(usize, 1), host.begins);
        try testing.expectEqual(@as(usize, 1), host.stages);
        try testing.expectEqual(@as(usize, 1), host.reads);
        try testing.expectEqual(@as(usize, 1), host.discards);
        try testing.expectEqual(@as(usize, 0), host.commits + host.pending + host.durable);
        try testing.expectEqual(.broker, diagnostic.origin);
        try testing.expectEqualStrings("NumericPolicyViolation", diagnostic.errorName());
    }
}

test "integer64 worker verifies exact integer boundaries and safe rescued errors without replay adapters" {
    var nil = try data.encode(a, .nil, 4096);
    defer nil.deinit(a);
    const modes = [_][]const u8{ "power", "rescue_overflow" };
    for (modes, 0..) |mode, i| {
        var input = try example.input(a, mode, if (i == 0) -2 else std.math.maxInt(i64), if (i == 0) 63 else 1);
        defer input.deinit(a);
        var host: example.Host = .{};
        const bindings = host.bindings();
        var observed: Worker.Observation = .{};
        const options: Worker.Options = .{ .turn = .{ .allowed = example.contract.grants }, .observation = &observed };
        const request = example.request(nil.view(), input.view());
        var prepared = try Worker.prepare(a, config.worker_executable, example.manifest, "app", example.contract.operations, request, .{ .bindings = &bindings, .transaction = host.transaction() }, options);
        defer prepared.deinit();
        try testing.expect(observed.execution_pid != null and observed.verification_pid != null);
        try testing.expectEqual(@as(usize, 1), host.stages);
        try prepared.commit();
        var replay = try Worker.replay(a, config.worker_executable, example.manifest, "app", example.contract.operations, request, prepared.receipt(), options);
        defer replay.deinit();
        try testing.expectEqualSlices(u8, prepared.terminal().bytes, replay.terminal().bytes);
        try testing.expectEqual(@as(usize, 1), host.begins);
        try testing.expectEqual(@as(usize, 1), host.stages);
        try testing.expectEqual(@as(usize, 1), host.commits);
        try testing.expectEqual(@as(usize, 0), host.discards + host.reads);
        try testing.expectEqual(@as(usize, 1), host.durable);
    }
}

test "integer64 worker discards an unrescued overflowing intermediate even with an integer final expression" {
    var nil = try data.encode(a, .nil, 4096);
    defer nil.deinit(a);
    var input = try example.input(a, "hidden_add", std.math.maxInt(i64), 1);
    defer input.deinit(a);
    var host: example.Host = .{};
    const bindings = host.bindings();
    var diagnostic: Turn.Diagnostic = .{};
    try testing.expectError(error.RubyException, Worker.prepare(a, config.worker_executable, example.manifest, "app", example.contract.operations, example.request(nil.view(), input.view()), .{ .bindings = &bindings, .transaction = host.transaction() }, .{ .turn = .{ .allowed = example.contract.grants, .diagnostic = &diagnostic } }));
    try testing.expectEqualStrings("RangeError", diagnostic.className());
    try testing.expectEqual(.worker, diagnostic.origin);
    try testing.expectEqual(@as(usize, 1), host.stages);
    try testing.expectEqual(@as(usize, 1), host.discards);
    try testing.expectEqual(@as(usize, 0), host.pending + host.durable + host.commits);
}

test "integer64 in-process effects keep Float adapter failure fatal through Ruby rescue" {
    var nil = try data.encode(a, .nil, 4096);
    defer nil.deinit(a);
    var input = try example.input(a, "adapter_float", 0, 0);
    defer input.deinit(a);
    for (sites) |site| {
        var bad = try floatCapsule(site);
        defer bad.deinit(a);
        var host: example.Host = .{ .response = bad.view() };
        const bindings = host.bindings();
        var diagnostic: Turn.Diagnostic = .{};
        try testing.expectError(error.NumericPolicyViolation, Turn.prepare(a, example.manifest, "app", example.contract.operations, example.request(nil.view(), input.view()), .{ .bindings = &bindings, .transaction = host.transaction() }, .{ .allowed = example.contract.grants, .diagnostic = &diagnostic }));
        try testing.expectEqual(@as(usize, 1), host.begins);
        try testing.expectEqual(@as(usize, 1), host.stages);
        try testing.expectEqual(@as(usize, 1), host.reads);
        try testing.expectEqual(@as(usize, 1), host.discards);
        try testing.expectEqual(@as(usize, 0), host.commits + host.pending + host.durable);
        try testing.expectEqualStrings("NumericPolicyViolation", diagnostic.errorName());
    }
}

test "integer64 replay rejects reframed Float terminals before program lookup and worker spawn" {
    var nil = try data.encode(a, .nil, 4096);
    defer nil.deinit(a);
    var input = try example.input(a, "identity", 7, 0);
    defer input.deinit(a);
    var host: example.Host = .{};
    const bindings = host.bindings();
    const request = example.request(nil.view(), input.view());
    var prepared = try Turn.prepare(a, example.manifest, "app", example.contract.operations, request, .{ .bindings = &bindings, .transaction = host.transaction() }, .{ .allowed = example.contract.grants });
    defer prepared.deinit();
    const receipt = try Turn.Receipt.decode(prepared.receipt(), .{});
    for ([_]bool{ false, true }) |as_state| {
        var bad = try data.encode(a, .{ .array = &.{ if (as_state) .{ .integer = 7 } else .{ .float = 1.25 }, if (as_state) .{ .float = 1.25 } else .nil } }, 4096);
        defer bad.deinit(a);
        const changed = try Turn.Receipt.encode(a, receipt.trace, bad.view(), .{});
        defer a.free(changed);
        try testing.expectError(error.NumericPolicyViolation, Turn.replay(a, example.manifest, "missing_program_must_not_load", example.contract.operations, request, changed, .{ .allowed = example.contract.grants }));
        var observed: Worker.Observation = .{};
        try testing.expectError(error.NumericPolicyViolation, Worker.replay(a, "/nonexistent/integer64-worker-must-not-start", example.manifest, "app", example.contract.operations, request, changed, .{ .turn = .{ .allowed = example.contract.grants }, .observation = &observed }));
        try testing.expect(observed.execution_pid == null and observed.verification_pid == null);
    }
    try testing.expectEqual(@as(usize, 1), host.stages);
    try testing.expectEqual(@as(usize, 0), host.commits + host.reads);
}
