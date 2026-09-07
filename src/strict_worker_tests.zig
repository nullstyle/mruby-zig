const std = @import("std");
const mruby = @import("mruby");
const example = @import("worker_example");
const config = @import("worker_test_config");
const process = mruby.strict.Worker.Process;

test "dedicated worker and verification child run Ruby while adapters remain in parent" {
    try std.testing.expect(mruby.features.effects_worker_supported);
    try std.testing.expect(!mruby.features.worker_process_supported);
    try example.verifyRecordReplay(std.testing.allocator, config.worker_executable);
}

test "broker admits turn state and input before starting a worker or transaction" {
    try example.verifyTurnInputAdmission(std.testing.allocator);
}

test "child independently rejects invalid turn inputs before ready" {
    try example.verifyChildTurnAdmission(std.testing.allocator, config.worker_executable);
}

test "worker terminal contracts reject staged results and next states before preparation" {
    for ([_]bool{ false, true }) |wrong_state| {
        var diagnostic: mruby.strict.Turn.Diagnostic = .{};
        try example.verifyFailure(std.testing.allocator, config.worker_executable, .{
            .mode = if (wrong_state) "invalid_state" else "invalid_result",
            .verification_started = false,
            .expected = error.TurnContractViolation,
            .callbacks = 2,
            .diagnostic = &diagnostic,
        });
        try std.testing.expectEqual(.worker, diagnostic.origin);
        try std.testing.expectEqual(.record, diagnostic.phase);
        try std.testing.expectEqual(.contract, diagnostic.kind);
        const mismatch = diagnostic.contract_detail.?;
        try std.testing.expectEqual(@as(@TypeOf(mismatch.side), if (wrong_state) .next_state else .result), mismatch.side);
        try std.testing.expectEqualStrings(if (wrong_state) "$[\"count\"]" else "$", mismatch.detail.pathText());
    }
}

test "broker rejects dishonest terminal contracts before verification" {
    for ([_]bool{ false, true }) |wrong_state| {
        var diagnostic: mruby.strict.Turn.Diagnostic = .{};
        try example.verifyFailure(std.testing.allocator, if (wrong_state) config.turn_state_executable else config.turn_result_executable, .{
            .verification_started = false,
            .expected = error.TurnContractViolation,
            .callbacks = 2,
            .diagnostic = &diagnostic,
        });
        try std.testing.expectEqual(.broker, diagnostic.origin);
        try std.testing.expectEqual(.record, diagnostic.phase);
        try std.testing.expectEqual(@as(@TypeOf(diagnostic.contract_detail.?.side), if (wrong_state) .next_state else .result), diagnostic.contract_detail.?.side);
    }
}

test "worker validates turn receipt schemas and binds compiled contract identity" {
    try example.verifyTurnReceiptAdmission(std.testing.allocator, config.worker_executable);
}

test "worker shared turn declaration supports absence null and normalized pointers" {
    const Missing = struct {};
    const ExplicitNull = struct {
        pub const turn_contract = null;
    };
    const Declared = struct {
        pub const turn_contract = .{ .state = .integer, .input = .nil, .result = .boolean };
    };
    const Pointer = struct {
        pub const turn_contract: ?*const mruby.strict.Turn.Contract = mruby.strict.Turn.Contract.from(Declared.turn_contract) catch unreachable;
    };
    const NullPointer = struct {
        pub const turn_contract: ?*const mruby.strict.Turn.Contract = null;
    };
    try std.testing.expectEqual(null, try mruby.strict.Worker.Runtime.contractFromModule(Missing));
    try std.testing.expectEqual(null, try mruby.strict.Worker.Runtime.contractFromModule(ExplicitNull));
    try std.testing.expectEqual(null, try mruby.strict.Worker.Runtime.contractFromModule(NullPointer));
    const declared = try mruby.strict.Worker.Runtime.contractFromModule(Declared);
    const normalized = try mruby.strict.Worker.Runtime.contractFromModule(Pointer);
    try std.testing.expectEqualSlices(u8, &declared.?.digest(), &normalized.?.digest());
}

test "worker exception after staging discards host transaction" {
    try example.verifyFailure(std.testing.allocator, config.worker_executable, .{
        .mode = "raise",
        .expected = error.RubyException,
        .callbacks = 2,
    });
}

test "external deadline terminates child and discards already staged intent" {
    try example.verifyFailure(std.testing.allocator, config.worker_executable, .{
        .mode = "loop",
        .expected = error.ProcessWallExceeded,
        .callbacks = 2,
        .deadline = true,
    });
}

test "broker rejects unknown operation before any adapter callback" {
    try example.verifyFailure(std.testing.allocator, config.unknown_executable, .{ .expected = error.InvalidWorkerRequest });
}

test "broker independently rejects known but ungranted operation" {
    try example.verifyFailure(std.testing.allocator, config.denied_executable, .{
        .expected = error.EffectDenied,
        .allowed = &.{"clock.now"},
    });
}

test "broker rejects skipped and duplicate request sequence numbers" {
    try example.verifyFailure(std.testing.allocator, config.reordered_executable, .{ .expected = error.InvalidWorkerRequest });
    try example.verifyFailure(std.testing.allocator, config.duplicate_executable, .{ .expected = error.InvalidWorkerRequest, .callbacks = 1 });
}

test "child process exits after staging without authorizing host commit" {
    try example.verifyFailure(std.testing.allocator, config.exit_after_effect_executable, .{ .expected = error.TransportFailure, .callbacks = 1 });
}

test "native confinement denies filesystem reads and network connect or bind" {
    var child = try process.Process.spawn(std.testing.allocator, config.confinement_executable, .{
        .wall_time_ns = 5 * std.time.ns_per_s,
        .max_transfer_bytes = 4096,
    });
    defer child.deinit();
    var result: [1]u8 = undefined;
    try child.channel.readExact(&result);
    try std.testing.expectEqual(@as(u8, 7), result[0]);
    try child.wait();
}

test "deadline expiring in begin is checked before dispatching any adapter" {
    try example.verifyFailure(std.testing.allocator, config.worker_executable, .{
        .expected = error.ProcessWallExceeded,
        .wall_time_ns = std.time.ns_per_s,
        .delay_begin_us = 1_200_000,
    });
}

test "deadline expiring inside an adapter discards its staged intent before another callback" {
    try example.verifyFailure(std.testing.allocator, config.worker_executable, .{
        .mode = "intent_first",
        .expected = error.ProcessWallExceeded,
        .callbacks = 1,
        .wall_time_ns = std.time.ns_per_s,
        .delay_intent_us = 1_200_000,
    });
}

test "broker reserves trace record capacity before invoking a dishonest peer's adapter" {
    try example.verifyFailure(std.testing.allocator, config.exit_after_effect_executable, .{
        .expected = error.TraceLimitExceeded,
        .max_records = 0,
    });
}

test "allocation failure after staging discards once and reaps the child" {
    try example.verifyAllocationFailure(std.testing.allocator, config.worker_executable);
}

test "worker receipts replay in-process and in-process receipts replay in workers with reversed grants" {
    try example.verifyCrossReplay(std.testing.allocator, config.worker_executable);
}

test "broker rejects callback arity before invoking an adapter" {
    try example.verifyFailure(std.testing.allocator, config.wrong_arity_executable, .{ .expected = error.InvalidWorkerRequest });
}

test "broker validates nested operation arguments even when the child bypasses Ruby constructors" {
    var diagnostic: mruby.strict.Turn.Diagnostic = .{};
    try example.verifyFailure(std.testing.allocator, config.schema_arguments_executable, .{
        .expected = error.EffectContractViolation,
        .diagnostic = &diagnostic,
    });
    try std.testing.expectEqual(.broker, diagnostic.origin);
    try std.testing.expectEqual(.record, diagnostic.phase);
    try std.testing.expectEqualStrings("EffectContractViolation", diagnostic.errorName());
    const detail = diagnostic.effect_detail.?;
    try std.testing.expectEqual(.contract, detail.reason);
    try std.testing.expectEqualStrings("outbox.prepare", detail.actualOperation());
    try std.testing.expectEqual(@as(usize, 0), detail.record_index);
    const mismatch = detail.contract_detail.?;
    try std.testing.expectEqual(.arguments, mismatch.side);
    try std.testing.expectEqualStrings("$[0][1]", mismatch.pathText());
    try std.testing.expectEqual(.integer, mismatch.expected);
    try std.testing.expectEqual(.string, mismatch.actual.?);
}

test "broker rejects host result and rejection contract violations before journal commit" {
    for ([_]bool{ false, true }) |rejected| {
        var diagnostic: mruby.strict.Turn.Diagnostic = .{};
        try example.verifyFailure(std.testing.allocator, config.worker_executable, .{
            .expected = error.EffectContractViolation,
            .callbacks = 1,
            .wrong_clock_result = !rejected,
            .reject_clock = rejected,
            .diagnostic = &diagnostic,
        });
        try std.testing.expectEqual(.broker, diagnostic.origin);
        const detail = diagnostic.effect_detail.?;
        try std.testing.expectEqual(.contract, detail.reason);
        try std.testing.expectEqualStrings("clock.now", detail.actualOperation());
        try std.testing.expectEqual(@as(usize, 0), detail.record_index);
        try std.testing.expectEqual(@as(mruby.effect.schema.Side, if (rejected) .rejection else .result), detail.contract_detail.?.side);
    }
}

test "worker replay validates every typed receipt capsule before child startup" {
    try example.verifyContractReceiptAdmission(std.testing.allocator);
}

test "broker gives malformed typed rejection pairs the same contract diagnostic as the runtime" {
    var diagnostic: mruby.strict.Turn.Diagnostic = .{};
    try example.verifyFailure(std.testing.allocator, config.worker_executable, .{
        .expected = error.EffectContractViolation,
        .callbacks = 1,
        .malformed_clock_rejection = true,
        .diagnostic = &diagnostic,
    });
    try std.testing.expectEqual(.broker, diagnostic.origin);
    try std.testing.expectEqual(.record, diagnostic.phase);
    const detail = diagnostic.effect_detail.?;
    try std.testing.expectEqual(.contract, detail.reason);
    try std.testing.expectEqualStrings("clock.now", detail.actualOperation());
    try std.testing.expectEqual(@as(usize, 0), detail.record_index);
    const mismatch = detail.contract_detail.?;
    try std.testing.expectEqual(.rejection, mismatch.side);
    try std.testing.expectEqual(.rejection_forbidden, mismatch.reason);
    try std.testing.expectEqualStrings("$", mismatch.pathText());
}

test "worker transports a rescued Ruby contract failure and discards earlier staged effects" {
    var diagnostic: mruby.strict.Turn.Diagnostic = .{};
    try example.verifyFailure(std.testing.allocator, config.worker_executable, .{
        .mode = "contract_failure",
        .expected = error.EffectContractViolation,
        .callbacks = 2,
        .diagnostic = &diagnostic,
    });
    try std.testing.expectEqual(.worker, diagnostic.origin);
    try std.testing.expectEqual(.record, diagnostic.phase);
    try std.testing.expectEqualStrings("EffectContractViolation", diagnostic.errorName());
    try std.testing.expectEqualStrings("worker/app.rb", diagnostic.source.?.fileName());
    const detail = diagnostic.effect_detail.?;
    try std.testing.expectEqual(.contract, detail.reason);
    try std.testing.expectEqual(@as(usize, 2), detail.record_index);
    try std.testing.expectEqualStrings("outbox.prepare", detail.actualOperation());
    const mismatch = detail.contract_detail.?;
    try std.testing.expectEqual(.arguments, mismatch.side);
    try std.testing.expectEqualStrings("$[0][1]", mismatch.pathText());
    try std.testing.expectEqual(.integer, mismatch.expected);
    try std.testing.expectEqual(.string, mismatch.actual.?);
}

test "broker compares child receipt against its own adapter transcript" {
    try example.verifyFailure(std.testing.allocator, config.forged_result_executable, .{ .expected = error.WorkerReceiptMismatch, .callbacks = 2 });
    try example.verifyFailure(std.testing.allocator, config.dropped_record_executable, .{ .expected = error.WorkerReceiptMismatch, .callbacks = 2 });
}

test "broker waits for clean child termination after a complete receipt" {
    try example.verifyFailure(std.testing.allocator, config.trailing_output_executable, .{ .expected = error.UnexpectedWorkerOutput, .callbacks = 2 });
    try example.verifyFailure(std.testing.allocator, config.crash_after_finish_executable, .{ .expected = error.WorkerFailed, .callbacks = 2 });
}

test "automatic second child replay rejects forged terminal state before preparation" {
    try example.verifyFailure(std.testing.allocator, config.forged_terminal_executable, .{ .expected = error.TerminalMismatch, .callbacks = 2 });
}

test "worker diagnostics preserve Ruby failures and native denial after child destruction" {
    var diagnostic: mruby.strict.Turn.Diagnostic = .{};
    try example.verifyFailure(std.testing.allocator, config.worker_executable, .{
        .mode = "raise",
        .expected = error.RubyException,
        .callbacks = 2,
        .diagnostic = &diagnostic,
    });
    try std.testing.expectEqual(.ruby, diagnostic.kind);
    try std.testing.expectEqual(.worker, diagnostic.origin);
    try std.testing.expectEqual(.record, diagnostic.phase);
    try std.testing.expectEqualStrings("RubyException", diagnostic.errorName());
    try std.testing.expectEqualStrings("failure after staging", diagnostic.messageText());
    try std.testing.expectEqualStrings("RuntimeError", diagnostic.className());
    try std.testing.expect(diagnostic.source != null);
    try std.testing.expect(std.mem.endsWith(u8, diagnostic.source.?.fileName(), "worker/app.rb"));
    try std.testing.expectEqual(@as(u32, 13), diagnostic.source.?.line);
    try example.verifyFailure(std.testing.allocator, config.worker_executable, .{
        .mode = "native",
        .expected = error.NativeEffectViolation,
        .diagnostic = &diagnostic,
    });
    try std.testing.expectEqual(.native, diagnostic.kind);
    try std.testing.expectEqual(.worker, diagnostic.origin);
    try std.testing.expect(diagnostic.native_detail != null);
    try std.testing.expect(diagnostic.native_detail.?.name_len > 0);
    try std.testing.expect(diagnostic.source != null);
    try std.testing.expectEqual(@as(u32, 3), diagnostic.source.?.line);
    try std.testing.expectEqual(@as(usize, 0), diagnostic.className().len);
    try std.testing.expect(!std.mem.eql(u8, "failure after staging", diagnostic.messageText()));
    try example.verifyFailure(std.testing.allocator, config.worker_executable, .{
        .mode = "unknown_ruby",
        .expected = error.RubyException,
        .diagnostic = &diagnostic,
    });
    try std.testing.expectEqual(.ruby, diagnostic.kind);
    try std.testing.expectEqualStrings("NameError", diagnostic.className());
}

test "denied and unhandled effects identify the operation and trusted diagnostic origin" {
    var diagnostic: mruby.strict.Turn.Diagnostic = .{};
    try example.verifyFailure(std.testing.allocator, config.worker_executable, .{
        .expected = error.EffectDenied,
        .callbacks = 1,
        .allowed = &.{"clock.now"},
        .diagnostic = &diagnostic,
    });
    try std.testing.expectEqual(.worker, diagnostic.origin);
    try std.testing.expectEqual(.denied, diagnostic.effect_detail.?.reason);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.effect_detail.?.record_index);
    try std.testing.expect(diagnostic.source != null);
    try std.testing.expectEqual(@as(u32, 11), diagnostic.source.?.line);
    try std.testing.expectEqualStrings("outbox.prepare", diagnostic.effect_detail.?.actualOperation());
    try example.verifyFailure(std.testing.allocator, config.denied_executable, .{
        .expected = error.EffectDenied,
        .allowed = &.{"clock.now"},
        .diagnostic = &diagnostic,
    });
    try std.testing.expectEqual(.broker, diagnostic.origin);
    try std.testing.expectEqual(.denied, diagnostic.effect_detail.?.reason);
    try std.testing.expectEqualStrings("outbox.prepare", diagnostic.effect_detail.?.actualOperation());
    try example.verifyFailure(std.testing.allocator, config.worker_executable, .{
        .expected = error.EffectUnhandled,
        .callbacks = 1,
        .omit_intent_binding = true,
        .diagnostic = &diagnostic,
    });
    try std.testing.expectEqual(.broker, diagnostic.origin);
    try std.testing.expectEqual(.unhandled, diagnostic.effect_detail.?.reason);
}

test "host adapter diagnostic retains its underlying error without changing execution failure" {
    var diagnostic: mruby.strict.Turn.Diagnostic = .{};
    try example.verifyFailure(std.testing.allocator, config.worker_executable, .{
        .expected = error.EffectHandlerFailed,
        .callbacks = 2,
        .fail_intent = true,
        .diagnostic = &diagnostic,
    });
    try std.testing.expectEqual(.broker, diagnostic.origin);
    try std.testing.expectEqual(.record, diagnostic.phase);
    try std.testing.expectEqualStrings("EffectHandlerFailed", diagnostic.errorName());
    try std.testing.expectEqualStrings("IntentStorageUnavailable", diagnostic.messageText());
    try std.testing.expectEqual(.handler_failed, diagnostic.effect_detail.?.reason);
    try std.testing.expectEqualStrings("outbox.prepare", diagnostic.effect_detail.?.actualOperation());
}

test "worker replay transports argument and terminal mismatches while setup checks stay in the broker" {
    try example.verifyReplayDiagnostics(std.testing.allocator, config.worker_executable);
}

test "broker validates optional diagnostic payloads and stamps worker provenance itself" {
    // Malformed frames fail even with no diagnostic destination requested.
    try example.verifyFailure(std.testing.allocator, config.malformed_diagnostic_executable, .{ .expected = error.InvalidDiagnostic });
    var diagnostic: mruby.strict.Turn.Diagnostic = .{};
    try example.verifyFailure(std.testing.allocator, config.spoofed_diagnostic_executable, .{ .expected = error.RubyException, .diagnostic = &diagnostic });
    try std.testing.expectEqual(.worker, diagnostic.origin);
    try std.testing.expectEqual(.record, diagnostic.phase);
    try std.testing.expectEqualStrings("RubyException", diagnostic.errorName());
}

test "worker diagnostic payload codecs" {
    std.testing.refAllDecls(mruby.strict.Worker.DiagnosticCodec);
}

test "diagnostic JSON escapes guest bytes and preserves structured replay context" {
    var diagnostic: mruby.strict.Turn.Diagnostic = .{ .kind = .ruby, .origin = .worker, .phase = .record };
    const message = "bad\n\x1b[31m\xff\"\\";
    @memcpy(diagnostic.message[0..message.len], message);
    diagnostic.message_len = message.len;
    var buffer: [32768]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try diagnostic.writeJson(&writer);
    const json = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, json, "\\u000a\\u001b[31m\\u00ff") != null);
    for (json) |byte| try std.testing.expect(byte >= 0x20 and byte <= 0x7e);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("worker", parsed.value.object.get("origin").?.string);
    try std.testing.expectEqualStrings("record", parsed.value.object.get("phase").?.string);
    try std.testing.expect(parsed.value.object.get("source").? == .null);
}
