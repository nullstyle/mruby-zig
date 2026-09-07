//! Explicit, host-handled operations. Request construction is inert;
//! only Effect.perform crosses the host-operation seam. Install during
//! bootstrap and execute through a sandbox Isolate. Native handlers remain
//! trusted code; grants do not inspect arbitrary behavior inside them.
const std = @import("std");
const c = @import("c.zig");
const alloc = @import("alloc.zig");
const Vm = @import("vm.zig").Vm;
const Value = @import("value.zig").Value;
const Class = @import("class.zig").Class;
const Rest = @import("class.zig").Rest;
const artifact = @import("artifact.zig");
const codec = @import("artifact_value.zig");
const storage = @import("effect_trace.zig");
const features = @import("features.zig");

pub const Trace = storage.Trace;
pub const Inspection = @import("effect_inspect.zig");
pub const Invocation = @import("effect_invocation.zig").Invocation;
pub const Identity = storage.Identity;
pub const Limits = storage.Limits;
pub const data = @import("effect_data.zig");
pub const schema = @import("effect_schema.zig");
pub const ExecutionError = error{
    EffectNotInstalled,
    EffectNotActive,
    EffectDenied,
    EffectUnhandled,
    InvalidEffectRequest,
    InvalidEffectInvocation,
    EffectReentry,
    EffectLimitExceeded,
    EffectHandlerFailed,
    EffectContractViolation,
    NumericPolicyViolation,
    EffectReplayMismatch,
    EffectTraceIncomplete,
    EffectTraceRequiresCodeIdentity,
    EffectTraceIdentityMismatch,
    EffectTraceUnavailable,
    EffectInitializationFailed,
    EffectDuringInitialization,
    OutOfMemory,
};

/// Pure descriptors can be shared with build.zig's CodeDB host catalogue.
/// Names/versions describe the operation contract, not a handler address.
pub const Operation = struct {
    name: []const u8,
    namespace: []const u8,
    method: []const u8,
    version: u32 = 1,
    arity: usize,
    authority_bits: u16,
    max_result_bytes: usize = 4096,
    /// Static compiled contract. Plain descriptors may instead supply a
    /// `.contract` literal; describeCatalogue owns its static normalization.
    contract: ?*const schema.Contract = null,
};
pub const Handler = *const fn (?*anyopaque, *Vm, Value) anyerror!Value;
/// Expected rejection payloads are exact inert [code String, message String]
/// arrays. Return a Zig error for failures that invalidate the whole execution.
pub const Outcome = union(enum) { returned: Value, rejected: Value };
pub const OutcomeHandler = *const fn (?*anyopaque, *Vm, Value) anyerror!Outcome;
pub const DataOutcome = data.Outcome;
/// Arguments borrow the request capsule for this call only. Return a capsule
/// allocated with the supplied allocator; the dispatcher releases it on every
/// path. No VM access is provided. Context and external transactions remain
/// the embedding application's responsibility.
pub const DataHandler = *const fn (?*anyopaque, std.mem.Allocator, artifact.StateCapsuleView) anyerror!DataOutcome;
/// Used by fresh strict turns to exclude legacy VM-capable callbacks by type.
pub const DataBinding = struct {
    name: []const u8,
    handler: DataHandler,
    context: ?*anyopaque = null,
};

/// Construct an expected application rejection, preserving VM arena ownership.
pub fn reject(vm: *Vm, code: []const u8, message: []const u8) !Outcome {
    const code_value = try vm.stringValue(code);
    const message_value = try vm.stringValue(message);
    return .{ .rejected = (try vm.array(&.{ code_value, message_value })).asValue() };
}

/// An owned, bounded snapshot; safe to retain after the VM or trace is freed.
/// Record indices and byte offsets are zero-based. Hashes are SHA-256.
pub const Diagnostic = struct {
    pub const Reason = enum {
        identity_code,
        identity_catalogue,
        identity_input,
        operation,
        version,
        arguments,
        missing_record,
        extra_record,
        invalid_result,
        denied,
        unhandled,
        handler_failed,
        invalid_request,
        limit,
        initialization,
        reentry,
        contract,
    };
    reason: Reason,
    record_index: usize = 0,
    expected_operation: [256]u8 = @splat(0),
    expected_operation_len: u16 = 0,
    actual_operation: [256]u8 = @splat(0),
    actual_operation_len: u16 = 0,
    expected_version: ?u32 = null,
    actual_version: ?u32 = null,
    argument_byte_offset: ?usize = null,
    expected_hash: ?[32]u8 = null,
    actual_hash: ?[32]u8 = null,
    source: ?c.DiagnosticSource = null,
    contract_detail: ?schema.Mismatch = null,

    pub fn expectedOperation(self: *const Diagnostic) []const u8 {
        return self.expected_operation[0..self.expected_operation_len];
    }
    pub fn actualOperation(self: *const Diagnostic) []const u8 {
        return self.actual_operation[0..self.actual_operation_len];
    }
};
pub const Binding = struct {
    name: []const u8,
    /// Exactly one handler form is required for each binding.
    handler: ?Handler = null,
    outcome_handler: ?OutcomeHandler = null,
    data_handler: ?DataHandler = null,
    /// Must outlive the VM. No process-global handler context is installed.
    context: ?*anyopaque = null,
};
pub const Mode = union(enum) { live, record, replay: []const u8 };
pub const Config = struct {
    allowed: []const []const u8 = &.{},
    bindings: []const Binding = &.{},
    mode: Mode = .live,
    /// Identity of all host-supplied inputs/bootstrap state relevant to replay.
    /// The runtime separately binds actual entry code and operation catalogue.
    input_identity: [32]u8 = @splat(0),
    limits: Limits = .{},
    /// Closes standard clock, random, and output entry points. Outside the
    /// strict profile this is an audited subset, not automatic mediation of
    /// custom native gems. Disabling it is invalid in a strict build.
    harden_ambient: bool = true,
};

const Registered = struct {
    operation: Operation,
    allowed: bool,
    handler: ?Handler = null,
    outcome_handler: ?OutcomeHandler = null,
    data_handler: ?DataHandler = null,
    context: ?*anyopaque = null,
};

// Requests may be finalized after State is destroyed by Vm.deinit. Their
// quota cell therefore has independent lifetime; finalizers never touch Vm.
const RequestBudget = struct {
    refs: usize = 1,
    bytes: usize = 0,
    count: usize = 0,
    max_bytes: usize,
    max_count: usize,
    fn release(b: *RequestBudget) void {
        b.refs -= 1;
        if (b.refs == 0) alloc.gpa.destroy(b);
    }
};
const Request = struct {
    index: usize,
    arguments: []u8,
    budget: *RequestBudget,
    fn destroy(r: *Request) void {
        const budget = r.budget;
        budget.bytes -= @sizeOf(Request) + r.arguments.len;
        budget.count -= 1;
        alloc.gpa.free(r.arguments);
        alloc.gpa.destroy(r);
        budget.release();
    }
};
const RequestData = @import("data.zig").DataType(Request, "mruby.Effect", Request.destroy);

pub const State = struct {
    vm: *Vm,
    operations: []Registered,
    request_class: Class,
    rejected_class: Class,
    rejected_root: ?@import("vm.zig").RootedValue = null,
    request_budget: *RequestBudget,
    limits: Limits,
    catalogue: [32]u8,
    input_identity: [32]u8,
    mode: enum { live, record, replay },
    replay: ?Trace = null,
    trace: ?Trace = null,
    active: bool = false,
    initializing: bool = false,
    initialization_failure: ?ExecutionError = null,
    in_handler: bool = false,
    cursor: usize = 0,
    failure: ?ExecutionError = null,
    last_operation: ?[]const u8 = null,
    last_diagnostic: ?Diagnostic = null,
    harden_ambient: bool,
    initialized: bool = false,
    // Set only by the isolate's admitted execution bracket.
    guard_context: ?*anyopaque = null,
    guard: ?*const fn (?*anyopaque) anyerror!void = null,

    pub fn deinit(state: *State) void {
        if (state.rejected_root) |*root| root.deinit();
        if (state.trace) |*trace| trace.deinit();
        if (state.replay) |*trace| trace.deinit();
        alloc.gpa.free(state.operations);
        state.request_budget.release();
        alloc.gpa.destroy(state);
    }

    /// Application initialization may construct requests, but cannot perform
    /// them. This separate bracket neither starts nor consumes an effect trace.
    pub fn beginInitialization(state: *State) ExecutionError!void {
        if (state.active or state.initializing) return error.EffectReentry;
        if (!state.initialized) return error.EffectInitializationFailed;
        if (state.initialization_failure) |err| return err;
        state.initializing = true;
    }

    /// A prohibited operation poisons initialization even when Ruby rescues
    /// its exception. Failed initialization is terminal for this effect state.
    pub fn finishInitialization(state: *State, success: bool) ExecutionError!void {
        if (!state.initializing) return error.EffectNotActive;
        defer state.initializing = false;
        if (!success and state.initialization_failure == null)
            state.initialization_failure = error.EffectInitializationFailed;
        if (state.initialization_failure) |err| return err;
    }

    fn rejectInitialization(state: *State) ExecutionError {
        state.mismatch(.initialization, null, state.lastRegistered(), null);
        if (state.initialization_failure == null)
            state.initialization_failure = error.EffectDuringInitialization;
        return error.EffectDuringInitialization;
    }

    /// Validate a proposed execution before admission; retained trace, cursor,
    /// and failure remain unchanged. An inactive attempt resets diagnostics.
    pub fn validateExecution(state: *State, code_identity: ?[32]u8, input_override: ?[32]u8) ExecutionError!void {
        if (state.active or state.initializing) return error.EffectReentry;
        state.last_diagnostic = null;
        if (!state.initialized) return error.EffectInitializationFailed;
        if (state.initialization_failure) |err| return err;
        if (state.mode != .live and code_identity == null)
            return error.EffectTraceRequiresCodeIdentity;
        const identity: Identity = .{
            .code = code_identity orelse @splat(0),
            .catalogue = state.catalogue,
            .input = input_override orelse state.input_identity,
        };
        if (state.mode == .replay) {
            const expected = state.replay.?.identity;
            const reason: ?Diagnostic.Reason = if (!std.mem.eql(u8, &expected.code, &identity.code))
                .identity_code
            else if (!std.mem.eql(u8, &expected.catalogue, &identity.catalogue))
                .identity_catalogue
            else if (!std.mem.eql(u8, &expected.input, &identity.input))
                .identity_input
            else
                null;
            if (reason) |why| {
                state.last_diagnostic = .{
                    .reason = why,
                    .expected_hash = switch (why) {
                        .identity_code => expected.code,
                        .identity_catalogue => expected.catalogue,
                        else => expected.input,
                    },
                    .actual_hash = switch (why) {
                        .identity_code => identity.code,
                        .identity_catalogue => identity.catalogue,
                        else => identity.input,
                    },
                };
                return error.EffectTraceIdentityMismatch;
            }
        }
    }

    pub fn beginExecution(state: *State, code_identity: ?[32]u8, input_override: ?[32]u8) ExecutionError!void {
        try state.validateExecution(code_identity, input_override);
        const identity: Identity = .{
            .code = code_identity orelse @splat(0),
            .catalogue = state.catalogue,
            .input = input_override orelse state.input_identity,
        };
        if (state.trace) |*trace| trace.deinit();
        state.trace = if (state.mode == .record)
            Trace.init(alloc.gpa, identity, state.limits)
        else
            null;
        state.failure = null;
        state.last_operation = null;
        state.cursor = 0;
        state.in_handler = false;
        state.active = true;
    }

    pub fn diagnostic(state: *const State) ?Diagnostic {
        return state.last_diagnostic;
    }

    fn mismatch(state: *State, reason: Diagnostic.Reason, expected: ?storage.Record, actual: ?Registered, arguments: ?[]const u8) void {
        if (state.last_diagnostic != null) return;
        var detail: Diagnostic = .{ .reason = reason, .record_index = state.cursor };
        var source: c.DiagnosticSource = .{};
        if (c.mrz_diagnostic_source_current(state.vm.mrb, &source)) detail.source = source;
        if (expected) |record| {
            const size = @min(record.name.len, detail.expected_operation.len);
            @memcpy(detail.expected_operation[0..size], record.name[0..size]);
            detail.expected_operation_len = @intCast(size);
            detail.expected_version = record.version;
            if (arguments != null) detail.expected_hash = digest(record.arguments);
        }
        if (actual) |op| {
            const size = @min(op.operation.name.len, detail.actual_operation.len);
            @memcpy(detail.actual_operation[0..size], op.operation.name[0..size]);
            detail.actual_operation_len = @intCast(size);
            detail.actual_version = op.operation.version;
        }
        if (arguments) |bytes| {
            detail.actual_hash = digest(bytes);
            if (expected) |record| {
                const common = @min(record.arguments.len, bytes.len);
                var offset: usize = 0;
                while (offset < common and record.arguments[offset] == bytes[offset]) : (offset += 1) {}
                if (offset < common or record.arguments.len != bytes.len) detail.argument_byte_offset = offset;
            }
        }
        state.last_diagnostic = detail;
    }

    pub fn finishExecution(state: *State, success: bool) ExecutionError!void {
        if (!state.active) return error.EffectNotActive;
        defer {
            state.active = false;
            state.in_handler = false;
            state.guard = null;
            state.guard_context = null;
        }
        if (!success) if (state.trace) |*trace| trace.invalidate();
        if (state.failure) |err| return err;
        if (!success) return;
        if (state.mode == .replay and state.cursor != state.replay.?.len()) {
            state.mismatch(.missing_record, state.replay.?.get(state.cursor), null, null);
            return state.fail(error.EffectReplayMismatch);
        }
        if (state.trace) |*trace| trace.finish() catch
            return state.fail(error.EffectTraceIncomplete);
    }

    pub fn takeTrace(state: *State) ExecutionError!Trace {
        if (state.active or state.initializing) return error.EffectReentry;
        const trace = state.trace orelse return error.EffectTraceUnavailable;
        state.trace = null;
        return trace;
    }

    fn fail(state: *State, err: ExecutionError) ExecutionError {
        if (state.last_diagnostic == null) {
            const reason: Diagnostic.Reason = switch (err) {
                error.EffectDenied => .denied,
                error.EffectUnhandled => .unhandled,
                error.EffectHandlerFailed => .handler_failed,
                error.EffectContractViolation => .contract,
                error.EffectReentry => .reentry,
                error.EffectLimitExceeded, error.OutOfMemory => .limit,
                else => .invalid_request,
            };
            state.mismatch(reason, null, state.lastRegistered(), null);
        }
        if (state.failure == null) state.failure = err;
        if (state.trace) |*trace| trace.invalidate();
        return err;
    }

    fn lastRegistered(state: *State) ?Registered {
        const name = state.last_operation orelse return null;
        for (state.operations) |op| {
            if (std.mem.eql(u8, name, op.operation.name)) return op;
        }
        return null;
    }

    fn validateContract(state: *State, op: Registered, side: schema.Side, bytes: []const u8, max_bytes: usize) ExecutionError!void {
        const contract = op.operation.contract orelse return;
        var document = data.Document.decodeWithOptions(alloc.gpa, .{ .bytes = bytes }, .{ .limits = capsuleLimits(max_bytes), .allow_float = !features.effects_integer64 }) catch |err| {
            state.mismatch(if (side == .arguments) .invalid_request else .invalid_result, null, op, null);
            return state.fail(mapStorageError(err));
        };
        defer document.deinit();
        if (schema.validate(contract, side, document.root())) |detail| {
            state.mismatch(.contract, null, op, null);
            if (state.last_diagnostic) |*snapshot| snapshot.contract_detail = detail;
            return state.fail(error.EffectContractViolation);
        }
    }

    fn perform(state: *State, value: Value) anyerror!Value {
        if (state.initializing) {
            // Read only the owned inert request, without executing Ruby or a
            // handler, so initialization denials name the attempted operation.
            if (value.mrb == state.vm.mrb) if (RequestData.unwrap(value)) |request| {
                if (request.budget == state.request_budget and request.index < state.operations.len)
                    state.last_operation = state.operations[request.index].operation.name;
            };
            return state.rejectInitialization();
        }
        if (!state.active) return error.EffectNotActive;
        if (state.failure) |err| return err;
        // In particular, ensure/rescue may run after termination was observed.
        // They must not invoke a fresh host operation during bounded unwind.
        if (state.guard) |guard| try guard(state.guard_context);
        if (state.in_handler) return state.fail(error.EffectReentry);
        state.last_operation = null;
        try value.ensureOwnedBy(state.vm.mrb);
        const request = RequestData.unwrap(value) orelse
            return state.fail(error.InvalidEffectRequest);
        if (request.budget != state.request_budget or request.index >= state.operations.len)
            return state.fail(error.InvalidEffectRequest);
        const op = state.operations[request.index];
        state.last_operation = op.operation.name;
        if (!op.allowed) return state.fail(error.EffectDenied);
        if (state.cursor >= state.limits.max_records)
            return state.fail(error.EffectLimitExceeded);
        try state.validateContract(op, .arguments, request.arguments, state.limits.max_request_bytes);
        if (state.mode == .replay) {
            const record = state.replay.?.get(state.cursor) orelse {
                state.mismatch(.extra_record, null, op, request.arguments);
                return state.fail(error.EffectReplayMismatch);
            };
            const reason: ?Diagnostic.Reason = if (!std.mem.eql(u8, record.name, op.operation.name))
                .operation
            else if (record.version != op.operation.version)
                .version
            else if (!std.mem.eql(u8, record.arguments, request.arguments))
                .arguments
            else
                null;
            if (reason) |why| {
                state.mismatch(why, record, op, request.arguments);
                return state.fail(error.EffectReplayMismatch);
            }
            if (record.result.len > op.operation.max_result_bytes) {
                state.mismatch(.invalid_result, record, op, null);
                return state.fail(error.EffectLimitExceeded);
            }
            try state.validateContract(op, if (record.outcome == .rejected) .rejection else .result, record.result, state.limits.max_result_bytes);
            const result = decode(state.vm, record.result, state.limits.max_result_bytes) catch |err| {
                state.mismatch(.invalid_result, record, op, null);
                return state.fail(mapStorageError(err));
            };
            if (record.outcome == .rejected) validateRejection(result) catch {
                state.mismatch(.invalid_result, record, op, null);
                return state.fail(error.InvalidEffectRequest);
            };
            state.cursor += 1;
            return if (record.outcome == .rejected) state.raiseRejection(result) else result;
        }
        if (op.handler == null and op.outcome_handler == null and op.data_handler == null) return state.fail(error.EffectUnhandled);
        const max_result = @min(op.operation.max_result_bytes, state.limits.max_result_bytes);
        if (state.trace) |*trace|
            trace.reserve(op.operation.name, op.operation.version, request.arguments, max_result) catch |err|
                return state.fail(mapStorageError(err));
        // Data adapters consume the already-snapshotted capsule directly.
        // Legacy adapters still receive a detached Ruby arguments graph.
        const args: ?Value = if (op.data_handler != null) null else decode(state.vm, request.arguments, state.limits.max_request_bytes) catch |err|
            return state.fail(mapStorageError(err));
        if (state.guard) |guard| try guard(state.guard_context);
        state.in_handler = true;
        defer state.in_handler = false;
        var rejected = false;
        const encoded = if (op.data_handler) |handler| blk: {
            const outcome = handler(op.context, alloc.gpa, .{ .bytes = request.arguments }) catch |err| {
                state.failure = state.fail(error.EffectHandlerFailed);
                return err;
            };
            rejected = outcome == .rejected;
            const capsule = switch (outcome) {
                .returned, .rejected => |result| result,
            };
            // Transfer ownership to the common validation/cleanup bracket.
            break :blk capsule.encoded;
        } else blk: {
            const handled: anyerror!Outcome = if (op.outcome_handler) |handler|
                handler(op.context, state.vm, args.?)
            else if (op.handler.?(op.context, state.vm, args.?)) |result| .{ .returned = result } else |err| err;
            const outcome = handled catch |err| {
                state.failure = state.fail(error.EffectHandlerFailed);
                return err;
            };
            if (state.failure) |err| return err;
            const result = switch (outcome) {
                .returned, .rejected => |value_result| value_result,
            };
            result.ensureOwnedBy(state.vm.mrb) catch {
                state.mismatch(.invalid_result, null, op, null);
                return state.fail(error.InvalidEffectRequest);
            };
            rejected = outcome == .rejected;
            // Typed rejections use the common inert contract validator first,
            // including the pair's shape, so every adapter gets the same detail.
            if (rejected and op.operation.contract == null) validateRejection(result) catch {
                state.mismatch(.invalid_result, null, op, null);
                return state.fail(error.InvalidEffectRequest);
            };
            break :blk encode(state.vm, result, max_result) catch |err| {
                state.mismatch(.invalid_result, null, op, null);
                return state.fail(mapStorageError(err));
            };
        };
        defer alloc.gpa.free(encoded);
        if (state.failure) |err| return err;
        try state.validateContract(op, if (rejected) .rejection else .result, encoded, max_result);
        // Give every mode the same detached value graph. Returning the host's
        // original object here would preserve aliases that replay cannot know.
        const detached = decode(state.vm, encoded, max_result) catch |err| {
            state.mismatch(.invalid_result, null, op, null);
            return state.fail(mapStorageError(err));
        };
        if (rejected) validateRejection(detached) catch {
            state.mismatch(.invalid_result, null, op, null);
            return state.fail(error.InvalidEffectRequest);
        };
        if (state.trace) |*trace| trace.commitOutcome(if (rejected) .rejected else .returned, encoded) catch |err|
            return state.fail(mapStorageError(err));
        state.cursor += 1;
        return if (rejected) state.raiseRejection(detached) else detached;
    }

    fn raiseRejection(state: *State, payload: Value) anyerror!Value {
        // The C trampoline reads the validated array and constructs the native
        // exception without calling guest `.exception` or `initialize` code.
        if (!c.mrz_protected_effect_rejection(state.vm.mrb, state.rejected_class.class, payload.v)) {
            state.failure = state.fail(error.EffectHandlerFailed);
        }
        return error.RubyException;
    }

    /// Called again by sandbox preparation after clock/seed pinning and before
    /// core model freezing, so a policy cannot reopen a direct clock path.
    pub fn hardenAmbient(state: *State) !void {
        if (!features.effects_strict and !state.harden_ambient) return;
        for ([_][]const u8{"Kernel"}) |owner| {
            for ([_][]const u8{ "print", "puts", "p", "printf", "rand", "srand" }) |name| {
                try mask(state.vm, owner, name, c.MRZ_MASK_INSTANCE);
                try mask(state.vm, owner, name, c.MRZ_MASK_CLASS);
            }
        }
        for ([_][]const u8{ "now", "new", "allocate" }) |name|
            try mask(state.vm, "Time", name, c.MRZ_MASK_CLASS);
        try mask(state.vm, "Time", "initialize", c.MRZ_MASK_INSTANCE);
        for ([_][]const u8{ "rand", "srand", "bytes", "new", "allocate" }) |name| {
            try mask(state.vm, "Random", name, c.MRZ_MASK_CLASS);
            try mask(state.vm, "Random", name, c.MRZ_MASK_INSTANCE);
        }
        try mask(state.vm, "Random", "initialize", c.MRZ_MASK_INSTANCE);
        for ([_][]const u8{ "shuffle", "shuffle!", "sample" }) |name|
            try mask(state.vm, "Array", name, c.MRZ_MASK_INSTANCE);
    }
};

fn digest(bytes: []const u8) [32]u8 {
    var result: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}

fn validateRejection(value: Value) !void {
    const array = try value.asArray();
    if (array.len() != 2) return error.InvalidEffectRequest;
    if (!(try array.get(0)).isString() or !(try array.get(1)).isString())
        return error.InvalidEffectRequest;
}

fn rejectionCode(vm: *Vm, self: Value) anyerror!Value {
    return vm.getIvar(self, "@code");
}

fn mapStorageError(err: anyerror) ExecutionError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.NumericPolicyViolation => error.NumericPolicyViolation,
        error.TraceLimitExceeded, error.ArtifactLimitExceeded, error.CapsuleLimitExceeded => error.EffectLimitExceeded,
        else => error.InvalidEffectRequest,
    };
}

fn capsuleLimits(max_bytes: usize) artifact.CapsuleLimits {
    return data.limits(max_bytes);
}

fn encode(vm: *Vm, value: Value, max_bytes: usize) ![]u8 {
    try value.ensureOwnedBy(vm.mrb);
    const capsule = try codec.exportValue(alloc.gpa, vm.mrb, value.v, .{ .limits = capsuleLimits(max_bytes) }, null);
    return capsule.encoded;
}

fn decode(vm: *Vm, bytes: []const u8, max_bytes: usize) !Value {
    var graph = try codec.parse(alloc.gpa, .{ .bytes = bytes }, .{ .limits = capsuleLimits(max_bytes), .allow_float = !features.effects_integer64 }, null);
    defer graph.deinit(alloc.gpa);
    return switch (codec.materialize(vm.mrb, &graph)) {
        .ok => |result| .{ .mrb = vm.mrb, .v = result.value },
        .out_of_memory => error.OutOfMemory,
        else => error.InvalidEffectRequest,
    };
}

fn mask(vm: *Vm, owner: []const u8, name: []const u8, kind: u8) !void {
    const cls = vm.getClass(owner) catch |err| switch (err) {
        error.UnknownClass => return,
        else => return err,
    };
    if (!c.mrz_protected_mask_method(vm.mrb, cls.class, name.ptr, name.len, kind))
        return error.RubyException;
}

fn freeze(cls: Class) !void {
    if (!c.mrz_protected_freeze(cls.mrb, cls.asValue().v)) return error.RubyException;
}

fn approveImplementation(cls: Class, name: []const u8, kind: u8) !void {
    if (features.effects_strict and
        !c.mrz_strict_approve_method(cls.mrb, cls.class, name.ptr, name.len, kind))
        return error.EffectInitializationFailed;
}

fn builder(comptime index: usize) type {
    return struct {
        fn call(vm: *Vm, _: Value, args: Rest) anyerror!Value {
            const state = vm.effects orelse return error.EffectNotInstalled;
            if (!state.initialized) return error.EffectInitializationFailed;
            const op = state.operations[index].operation;
            if (args.len != op.arity) return error.InvalidEffectRequest;
            const values = try alloc.gpa.alloc(Value, args.len);
            defer alloc.gpa.free(values);
            // Snapshot the VM argument stack before any allocation can reenter.
            for (values, 0..) |*value, i| value.* = args.get(i);
            const array = try vm.array(values);
            const bytes = encode(vm, array.asValue(), state.limits.max_request_bytes) catch |err|
                return mapStorageError(err);
            errdefer alloc.gpa.free(bytes);
            const budget = state.request_budget;
            const size = std.math.add(usize, bytes.len, @sizeOf(Request)) catch return error.EffectLimitExceeded;
            if (budget.count >= budget.max_count or size > budget.max_bytes - budget.bytes)
                return error.EffectLimitExceeded;
            const request = try alloc.gpa.create(Request);
            errdefer alloc.gpa.destroy(request);
            request.* = .{ .index = index, .arguments = bytes, .budget = budget };
            const value = try RequestData.wrap(state.request_class, request);
            // Ownership transferred; any subsequent allocation failure is GC's
            // responsibility, so do not free these objects on this path.
            budget.refs += 1;
            budget.count += 1;
            budget.bytes += size;
            return value;
        }
    };
}

fn performFn(vm: *Vm, _: Value, args: Rest) anyerror!Value {
    const state = vm.effects orelse return error.EffectNotInstalled;
    const result: anyerror!Value = if (state.initializing and args.len != 1)
        state.rejectInitialization()
    else if (args.len != 1)
        state.fail(error.InvalidEffectRequest)
    else
        state.perform(args.get(0));
    return result catch |err| {
        // Preserve an exception deliberately supplied by a host handler.
        if (err == error.RubyException and vm.lastError() != null) return err;
        var message: [384]u8 = undefined;
        const text = std.fmt.bufPrint(&message, "effect {s}: {s}", .{
            state.last_operation orelse "(request)", @errorName(err),
        }) catch "effect failed";
        return vm.raise("RuntimeError", text);
    };
}

fn requestName(vm: *Vm, self: Value) anyerror!Value {
    const state = vm.effects orelse return error.EffectNotInstalled;
    const request = RequestData.unwrap(self) orelse return error.InvalidEffectRequest;
    return vm.stringValue(state.operations[request.index].operation.name);
}
fn requestVersion(vm: *Vm, self: Value) anyerror!Value {
    const state = vm.effects orelse return error.EffectNotInstalled;
    const request = RequestData.unwrap(self) orelse return error.InvalidEffectRequest;
    return vm.intValue(state.operations[request.index].operation.version);
}
fn requestArguments(vm: *Vm, self: Value) anyerror!Value {
    const state = vm.effects orelse return error.EffectNotInstalled;
    const request = RequestData.unwrap(self) orelse return error.InvalidEffectRequest;
    return decode(vm, request.arguments, state.limits.max_request_bytes);
}

fn hashString(hash: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, @intCast(bytes.len), .little);
    hash.update(&length);
    hash.update(bytes);
}

fn validIdentifier(name: []const u8, uppercase: bool) bool {
    if (name.len == 0 or name.len > 128) return false;
    if (uppercase and !std.ascii.isUpper(name[0])) return false;
    for (name) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    return !std.ascii.isDigit(name[0]);
}

/// Normalize and validate the finite operation catalogue without a VM.
pub fn describeCatalogue(comptime descriptors: anytype) ![descriptors.len]Operation {
    if (descriptors.len > 256) return error.InvalidEffectCatalogue;
    var operations: [descriptors.len]Operation = undefined;
    inline for (descriptors, 0..) |descriptor, index| {
        const op: Operation = .{
            .name = descriptor.name,
            .namespace = descriptor.namespace,
            .method = descriptor.method,
            .version = if (@hasField(@TypeOf(descriptor), "version")) descriptor.version else 1,
            .arity = descriptor.arity,
            .authority_bits = descriptor.authority_bits,
            .max_result_bytes = if (@hasField(@TypeOf(descriptor), "max_result_bytes")) descriptor.max_result_bytes else 4096,
            .contract = try schema.operationContract(descriptor),
        };
        if (op.name.len == 0 or op.name.len > 256 or op.version == 0 or op.arity > 32 or
            op.max_result_bytes == 0 or !validIdentifier(op.namespace, true) or
            !validIdentifier(op.method, false) or std.mem.eql(u8, op.namespace, "Effect") or
            op.authority_bits & ~@as(u16, 0x3fff) != 0)
            return error.InvalidEffectCatalogue;
        if (op.contract) |contract| if (contract.arity() != op.arity) return error.InvalidEffectContract;
        for (operations[0..index]) |prior| {
            if (std.mem.eql(u8, prior.name, op.name) or
                (std.mem.eql(u8, prior.namespace, op.namespace) and
                    std.mem.eql(u8, prior.method, op.method)))
                return error.InvalidEffectCatalogue;
        }
        operations[index] = op;
    }
    return operations;
}

pub fn catalogueIdentity(comptime descriptors: anytype) ![32]u8 {
    const operations = try describeCatalogue(descriptors);
    return hashCatalogue(&operations);
}

fn hashCatalogue(operations: []const Operation) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("mruby-zig/effect-catalogue/v1");
    hash.update(&features.rite_compatibility_fingerprint);
    for (operations) |op| {
        hashString(&hash, op.name);
        hashString(&hash, op.namespace);
        hashString(&hash, op.method);
        var numbers: [24]u8 = @splat(0);
        std.mem.writeInt(u32, numbers[0..4], op.version, .little);
        std.mem.writeInt(u16, numbers[4..6], op.authority_bits, .little);
        std.mem.writeInt(u64, numbers[8..16], @intCast(op.arity), .little);
        std.mem.writeInt(u64, numbers[16..24], @intCast(op.max_result_bytes), .little);
        hash.update(&numbers);
    }
    // Keep the original identity for entirely schema-less catalogues. Once a
    // contract exists, bind its presence and digest at every operation slot.
    const has_contract = for (operations) |op| {
        if (op.contract != null) break true;
    } else false;
    if (has_contract) {
        hash.update("mruby-zig/effect-contracts/v1");
        for (operations) |op| {
            hash.update(&.{@intFromBool(op.contract != null)});
            if (op.contract) |contract| hash.update(&contract.digest());
        }
    }
    return hash.finalResult();
}

/// Install once, during trusted bootstrap. Descriptor names have static
/// lifetime; grants, handler bindings, and replay bytes are copied. Installation
/// failure after Ruby definitions begin is terminal for this VM: discard it.
pub fn install(vm: *Vm, comptime descriptors: anytype, config: Config) !void {
    if (vm.effects != null) return error.EffectsAlreadyInstalled;
    if (features.effects_strict and !config.harden_ambient) return error.InvalidEffectConfiguration;
    const catalogue = try describeCatalogue(descriptors);
    const operations = try alloc.gpa.alloc(Registered, descriptors.len);
    errdefer if (vm.effects == null) alloc.gpa.free(operations);
    for (catalogue, operations) |op, *registered| registered.* = .{ .operation = op, .allowed = false };
    for (config.allowed) |name| {
        const index = findOperation(operations, name) orelse return error.UnknownEffect;
        if (operations[index].allowed) return error.DuplicateEffectGrant;
        operations[index].allowed = true;
    }
    for (config.bindings) |binding| {
        const index = findOperation(operations, binding.name) orelse return error.UnknownEffect;
        if (operations[index].handler != null or operations[index].outcome_handler != null or operations[index].data_handler != null) return error.DuplicateEffectBinding;
        const handler_count = @as(u8, @intFromBool(binding.handler != null)) + @as(u8, @intFromBool(binding.outcome_handler != null)) + @as(u8, @intFromBool(binding.data_handler != null));
        if (handler_count != 1) return error.InvalidEffectBinding;
        operations[index].handler = binding.handler;
        operations[index].outcome_handler = binding.outcome_handler;
        operations[index].data_handler = binding.data_handler;
        operations[index].context = binding.context;
    }
    const budget = try alloc.gpa.create(RequestBudget);
    errdefer if (vm.effects == null) alloc.gpa.destroy(budget);
    budget.* = .{ .max_bytes = config.limits.max_bytes, .max_count = config.limits.max_records };
    const state = try alloc.gpa.create(State);
    errdefer if (vm.effects == null) alloc.gpa.destroy(state);
    state.* = .{
        .vm = vm,
        .operations = operations,
        .request_class = undefined,
        .rejected_class = undefined,
        .request_budget = budget,
        .limits = config.limits,
        .catalogue = hashCatalogue(&catalogue),
        .input_identity = config.input_identity,
        .mode = switch (config.mode) {
            .live => .live,
            .record => .record,
            .replay => .replay,
        },
        .harden_ambient = config.harden_ambient,
    };
    if (config.mode == .replay) state.replay = try Trace.decode(alloc.gpa, config.mode.replay, config.limits);
    errdefer if (vm.effects == null) if (state.replay) |*trace| trace.deinit();
    // Check namespace conflicts before any Ruby-visible definitions change.
    if (vm.getClass("Effect")) |_| return error.EffectNamespaceConflict else |err| if (err != error.UnknownClass) return err;
    inline for (descriptors) |descriptor| {
        if (vm.getClass(descriptor.namespace)) |_| return error.EffectNamespaceConflict else |err| if (err != error.UnknownClass) return err;
    }
    vm.effects = state; // VM now owns cleanup, including partial installation.
    if (features.effects_strict and !c.mrz_strict_approve_data_type(vm.mrb, RequestData.nativeType()))
        return error.EffectInitializationFailed;
    state.request_class = try vm.defineClass("Effect", null);
    state.rejected_class = try state.request_class.defineClass("Rejected", try vm.getClass("StandardError"));
    state.rejected_root = try vm.root(state.rejected_class.asValue());
    try state.rejected_class.defineMethod("code", rejectionCode);
    try approveImplementation(state.rejected_class, "code", c.MRZ_METHOD_INSTANCE);
    try freeze(state.rejected_class);
    try state.request_class.defineClassMethod("perform", performFn);
    try approveImplementation(state.request_class, "perform", c.MRZ_METHOD_CLASS);
    try state.request_class.defineMethod("name", requestName);
    try approveImplementation(state.request_class, "name", c.MRZ_METHOD_INSTANCE);
    try state.request_class.defineMethod("version", requestVersion);
    try approveImplementation(state.request_class, "version", c.MRZ_METHOD_INSTANCE);
    try state.request_class.defineMethod("arguments", requestArguments);
    try approveImplementation(state.request_class, "arguments", c.MRZ_METHOD_INSTANCE);
    for ([_][]const u8{ "new", "allocate" }) |name| try mask(vm, "Effect", name, c.MRZ_MASK_CLASS);
    for ([_][]const u8{ "dup", "clone", "initialize_copy" }) |name| try mask(vm, "Effect", name, c.MRZ_MASK_INSTANCE);
    inline for (descriptors, 0..) |descriptor, index| {
        const namespace = try vm.defineModule(descriptor.namespace);
        try namespace.defineClassMethod(descriptor.method, builder(index).call);
        try approveImplementation(namespace, descriptor.method, c.MRZ_METHOD_CLASS);
    }
    inline for (descriptors) |descriptor| try freeze(try vm.getClass(descriptor.namespace));
    try freeze(state.request_class);
    try state.hardenAmbient();
    state.initialized = true;
}

fn findOperation(operations: []const Registered, name: []const u8) ?usize {
    for (operations, 0..) |operation, index| if (std.mem.eql(u8, operation.operation.name, name)) return index;
    return null;
}

test {
    _ = @import("effect_trace.zig");
}
