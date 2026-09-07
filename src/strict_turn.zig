//! One fresh strict VM per turn, with explicit state and data-only adapters.
//! Preparation owns provisional host work; replay has no host callback surface.
const std = @import("std");
const strict = @import("strict.zig");
const effect = @import("effect.zig");
const artifact = @import("artifact.zig");
const sandbox = @import("sandbox.zig");
const c = @import("c.zig");
pub const Receipt = @import("turn_receipt.zig");
const contracts = @import("turn_contract.zig");
pub const Contract = contracts.Contract;

pub const Request = struct {
    receiver: []const u8,
    method: []const u8 = "apply",
    /// Independent input graphs, even when the two views share backing bytes.
    state: artifact.StateCapsuleView,
    input: artifact.StateCapsuleView,
};

pub const Diagnostic = struct {
    pub const Source = c.DiagnosticSource;
    pub const Phase = enum { none, setup, record, verification, replay };
    kind: enum { none, effect, native, terminal, ruby, failure, contract } = .none,
    origin: enum { none, turn, broker, worker } = .none,
    phase: Phase = .none,
    effect_detail: ?effect.Diagnostic = null,
    contract_detail: ?contracts.Mismatch = null,
    native_detail: ?c.StrictDiagnostic = null,
    expected_hash: ?[32]u8 = null,
    actual_hash: ?[32]u8 = null,
    byte_offset: ?usize = null,
    error_name: [128]u8 = @splat(0),
    error_name_len: u16 = 0,
    message: [512]u8 = @splat(0),
    message_len: u16 = 0,
    class_name: [128]u8 = @splat(0),
    class_name_len: u16 = 0,
    truncated: bool = false,
    /// Only native IREP/debug metadata supplies locations. Guest exception
    /// backtrace strings are never parsed or dispatched. Null is unavailable;
    /// a present source with line zero has a filename but no known line.
    source: ?Source = null,

    pub fn errorName(self: *const Diagnostic) []const u8 {
        return self.error_name[0..self.error_name_len];
    }
    pub fn messageText(self: *const Diagnostic) []const u8 {
        return self.message[0..self.message_len];
    }
    pub fn className(self: *const Diagnostic) []const u8 {
        return self.class_name[0..self.class_name_len];
    }
    pub fn writeJson(self: *const Diagnostic, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return @import("turn_diagnostic_json.zig").write(self, writer);
    }
};

pub const Options = struct {
    /// Shared data shapes. Admission takes an owned, validated snapshot before
    /// starting a VM or host transaction. The caller's pointer is then unused.
    contract: ?*const Contract = null,
    policy: sandbox.Policy = (strict.Options{}).policy,
    allowed: []const []const u8 = &.{},
    effect_limits: effect.Limits = .{},
    capsule_limits: artifact.CapsuleLimits = .{},
    receipt_limits: Receipt.Limits = .{},
    /// Contract for native adapters and any relevant host setup.
    bootstrap_identity: [32]u8 = @splat(0),
    /// Relevant external adapter starting state remains a host attestation.
    /// Ruby's explicit starting state and input are hashed from owned bytes.
    adapter_state_identity: [32]u8 = @splat(0),
    diagnostic: ?*Diagnostic = null,
};

pub const CommitOutcome = enum { committed, rejected, indeterminate };
pub const Transaction = struct {
    context: ?*anyopaque = null,
    /// A failed begin cleans up its own partial setup. A successful begin gets
    /// at most one commit attempt; abandonment, preparation failure, or a
    /// definitely rejected commit invokes discard once.
    begin: *const fn (?*anyopaque) anyerror!void,
    /// Persist terminal state and staged effects together. Rejected means no
    /// publication and leaves provisional work for the runner's discard hook.
    /// A thrown error is indeterminate: the host may already have committed.
    commit: *const fn (?*anyopaque, artifact.StateCapsuleView, []const u8) anyerror!CommitOutcome,
    /// Abort provisional work; must not fail. Never called after an uncertain
    /// commit. Host resources then require explicit host reconciliation.
    discard: *const fn (?*anyopaque) void,
};
pub const Host = struct {
    bindings: []const effect.DataBinding = &.{},
    transaction: ?Transaction = null,
};

/// Owned data, independent of the already-destroyed VM. Treat owned values as
/// move-only. The joint terminal graph is the authoritative replay commitment.
pub const Verified = struct {
    allocator: std.mem.Allocator,
    terminal_capsule: artifact.StateCapsule,
    receipt_bytes: []u8,
    max_terminal_bytes: usize,

    pub fn deinit(self: *Verified) void {
        self.terminal_capsule.deinit(self.allocator);
        self.allocator.free(self.receipt_bytes);
        self.* = undefined;
    }
    pub fn terminal(self: *const Verified) artifact.StateCapsuleView {
        return self.terminal_capsule.view();
    }
    pub fn receipt(self: *const Verified) []const u8 {
        return self.receipt_bytes;
    }
    /// Export one root for use as an independent value/input on a later turn.
    /// Aliases within that root survive; cross-root aliases belong to terminal().
    pub fn result(self: *const Verified, allocator: std.mem.Allocator) !artifact.StateCapsule {
        return self.extract(allocator, 0);
    }
    pub fn state(self: *const Verified, allocator: std.mem.Allocator) !artifact.StateCapsule {
        return self.extract(allocator, 1);
    }
    fn extract(self: *const Verified, allocator: std.mem.Allocator, index: usize) !artifact.StateCapsule {
        var document = try effect.data.Document.decode(allocator, self.terminal(), self.max_terminal_bytes);
        defer document.deinit();
        return effect.data.encodeRef(allocator, try document.root().at(index), self.max_terminal_bytes);
    }
};

pub const Prepared = struct {
    verified: Verified,
    transaction: ?Transaction,
    status: enum { pending, committing, committed, discarded, indeterminate } = .pending,

    pub fn terminal(self: *const Prepared) artifact.StateCapsuleView {
        return self.verified.terminal();
    }
    pub fn receipt(self: *const Prepared) []const u8 {
        return self.verified.receipt();
    }
    pub fn result(self: *const Prepared, allocator: std.mem.Allocator) !artifact.StateCapsule {
        return self.verified.result(allocator);
    }
    pub fn state(self: *const Prepared, allocator: std.mem.Allocator) !artifact.StateCapsule {
        return self.verified.state(allocator);
    }
    pub fn commit(self: *Prepared) !void {
        if (self.status != .pending) return error.TurnAlreadyResolved;
        self.status = .committing;
        const decision: CommitOutcome = if (self.transaction) |transaction|
            transaction.commit(transaction.context, self.terminal(), self.receipt()) catch {
                self.status = .indeterminate;
                return error.CommitIndeterminate;
            }
        else
            .committed;
        switch (decision) {
            .committed => self.status = .committed,
            .rejected => {
                self.status = .discarded;
                if (self.transaction) |transaction| transaction.discard(transaction.context);
                return error.CommitRejected;
            },
            .indeterminate => {
                self.status = .indeterminate;
                return error.CommitIndeterminate;
            },
        }
    }
    pub fn discard(self: *Prepared) void {
        if (self.status != .pending) return;
        self.status = .discarded;
        if (self.transaction) |transaction| transaction.discard(transaction.context);
    }
    pub fn deinit(self: *Prepared) void {
        self.discard();
        self.verified.deinit();
        self.* = undefined;
    }
};

/// Initialize a fresh VM, restore the explicit input graphs, run apply(state,
/// input), and prepare an owned receipt. Nothing commits automatically. Native
/// adapters must stage their writes/intents for Transaction to control them.
pub fn prepare(
    allocator: std.mem.Allocator,
    comptime manifest: type,
    entry: []const u8,
    comptime operations: anytype,
    request: Request,
    host: Host,
    options: Options,
) !Prepared {
    if (options.diagnostic) |diagnostic| diagnostic.* = .{};
    var phase: Diagnostic.Phase = .setup;
    return prepareImpl(allocator, manifest, entry, operations, request, host, options, &phase) catch |err| {
        recordFailure(options.diagnostic, err, phase);
        return err;
    };
}

fn prepareImpl(
    allocator: std.mem.Allocator,
    comptime manifest: type,
    entry: []const u8,
    comptime operations: anytype,
    request: Request,
    host: Host,
    options: Options,
    phase: *Diagnostic.Phase,
) !Prepared {
    var snapshot = try Snapshot.init(allocator, request, options);
    defer snapshot.deinit();
    const bindings = try allocator.alloc(effect.Binding, host.bindings.len);
    defer allocator.free(bindings);
    for (host.bindings, bindings) |binding, *target| target.* = .{
        .name = binding.name,
        .data_handler = binding.handler,
        .context = binding.context,
    };
    const program = try strict.Program.load(manifest, entry, operations, .{
        .policy = options.policy,
        .effects = .{ .allowed = options.allowed, .bindings = bindings, .mode = .record, .limits = options.effect_limits },
        .bootstrap_identity = options.bootstrap_identity,
        .diagnostic = options.diagnostic,
    });
    defer program.deinit();
    const limits = capsuleLimits(options);
    const output_limits = terminalLimits(options);
    const state_value = try program.internal.importValue(snapshot.request.state, .{ .limits = limits });
    const input_value = try program.internal.importValue(snapshot.request.input, .{ .limits = limits });
    // Every fallible output/receipt allocation happens before commit. A failed
    // call or export disposes both the fresh VM and all provisional host work.
    phase.* = .record;
    if (host.transaction) |transaction| try transaction.begin(transaction.context);
    errdefer if (host.transaction) |transaction| transaction.discard(transaction.context);
    const value = program.call(snapshot.request.receiver, snapshot.request.method, .{ state_value, input_value }, snapshot.identity) catch |err| {
        captureDiagnostic(program.internal, options.diagnostic, err, .record);
        return err;
    };
    var terminal = program.internal.exportValue(allocator, value, .{ .limits = output_limits }) catch |err| {
        terminalFailure(options.diagnostic, err, .record);
        return err;
    };
    errdefer terminal.deinit(allocator);
    inert.validateTerminalContract(allocator, terminal.view(), output_limits, snapshot.contract, options.diagnostic, .record) catch |err| {
        terminalFailure(options.diagnostic, err, .record);
        return err;
    };
    var trace = try program.takeEffectTrace();
    defer trace.deinit();
    const trace_bytes = try trace.encode(allocator);
    defer allocator.free(trace_bytes);
    const receipt_bytes = try Receipt.encode(allocator, trace_bytes, terminal.view(), options.receipt_limits);
    return .{
        .verified = .{ .allocator = allocator, .terminal_capsule = terminal, .receipt_bytes = receipt_bytes, .max_terminal_bytes = output_limits.max_encoded_bytes },
        .transaction = host.transaction,
    };
}

/// Replay accepts neither bindings nor transaction hooks. It returns owned
/// data only after both the effect sequence and the entire terminal graph match.
pub fn replay(
    allocator: std.mem.Allocator,
    comptime manifest: type,
    entry: []const u8,
    comptime operations: anytype,
    request: Request,
    receipt_bytes: []const u8,
    options: Options,
) !Verified {
    if (options.diagnostic) |diagnostic| diagnostic.* = .{};
    var phase: Diagnostic.Phase = .setup;
    return replayImpl(allocator, manifest, entry, operations, request, receipt_bytes, options, &phase) catch |err| {
        recordFailure(options.diagnostic, err, phase);
        return err;
    };
}

fn replayImpl(
    allocator: std.mem.Allocator,
    comptime manifest: type,
    entry: []const u8,
    comptime operations: anytype,
    request: Request,
    receipt_bytes: []const u8,
    options: Options,
    phase: *Diagnostic.Phase,
) !Verified {
    var snapshot = try Snapshot.init(allocator, request, options);
    defer snapshot.deinit();
    // Validate bounded framing before copying, then consume the owned copy.
    _ = try Receipt.decode(receipt_bytes, options.receipt_limits);
    const owned_receipt = try allocator.dupe(u8, receipt_bytes);
    errdefer allocator.free(owned_receipt);
    const expected = try Receipt.decode(owned_receipt, options.receipt_limits);
    const limits = capsuleLimits(options);
    const output_limits = terminalLimits(options);
    try inert.validateTerminalContract(allocator, expected.terminal, output_limits, snapshot.contract, options.diagnostic, .setup);
    var admitted_trace = try effect.Trace.decode(allocator, expected.trace, options.effect_limits);
    admitted_trace.deinit();
    const program = try strict.Program.load(manifest, entry, operations, .{
        .policy = options.policy,
        .effects = .{ .allowed = options.allowed, .mode = .{ .replay = expected.trace }, .limits = options.effect_limits },
        .bootstrap_identity = options.bootstrap_identity,
        .diagnostic = options.diagnostic,
    });
    defer program.deinit();
    const state_value = try program.internal.importValue(snapshot.request.state, .{ .limits = limits });
    const input_value = try program.internal.importValue(snapshot.request.input, .{ .limits = limits });
    phase.* = .replay;
    const value = program.call(snapshot.request.receiver, snapshot.request.method, .{ state_value, input_value }, snapshot.identity) catch |err| {
        captureDiagnostic(program.internal, options.diagnostic, err, .replay);
        return err;
    };
    var terminal = program.internal.exportValue(allocator, value, .{ .limits = output_limits }) catch |err| {
        terminalFailure(options.diagnostic, err, .replay);
        return err;
    };
    errdefer terminal.deinit(allocator);
    inert.validateTerminalContract(allocator, terminal.view(), output_limits, snapshot.contract, options.diagnostic, .replay) catch |err| {
        terminalFailure(options.diagnostic, err, .replay);
        return err;
    };
    if (!std.mem.eql(u8, expected.terminal.bytes, terminal.encoded)) {
        if (options.diagnostic) |diagnostic| {
            var offset: usize = 0;
            const common = @min(expected.terminal.bytes.len, terminal.encoded.len);
            while (offset < common and expected.terminal.bytes[offset] == terminal.encoded[offset]) : (offset += 1) {}
            diagnostic.* = .{
                .kind = .terminal,
                .origin = .turn,
                .phase = .replay,
                .expected_hash = digest(expected.terminal.bytes),
                .actual_hash = digest(terminal.encoded),
                .byte_offset = offset,
            };
            diagnostic.message_len = copyBounded(&diagnostic.message, "replayed result or next state differs from the receipt", &diagnostic.truncated);
        }
        return error.TerminalMismatch;
    }
    return .{ .allocator = allocator, .terminal_capsule = terminal, .receipt_bytes = owned_receipt, .max_terminal_bytes = output_limits.max_encoded_bytes };
}

const inert = @import("strict_turn_data.zig");
const capsuleLimits = inert.capsuleLimits;
const terminalLimits = inert.terminalLimits;
const validateTerminal = inert.validateTerminal;
const Snapshot = inert.Snapshot;

/// Best-effort inert capture before Program disposes a failed initialization.
/// This is observational: it neither runs Ruby nor allocates diagnostic data.
pub fn captureDiagnostic(iso: sandbox.Isolate, destination: ?*Diagnostic, err: anyerror, phase: Diagnostic.Phase) void {
    const diagnostic = destination orelse return;
    recordFailure(destination, err, phase);
    diagnostic.phase = phase;
    if (iso.nativeDiagnostic() catch null) |detail| {
        diagnostic.kind = .native;
        diagnostic.native_detail = detail;
        if (detail.source.file_len != 0) diagnostic.source = detail.source;
        diagnostic.message_len = copyBounded(&diagnostic.message, "native operation is unavailable in strict execution", &diagnostic.truncated);
    } else if (iso.effectDiagnostic() catch null) |detail| {
        diagnostic.kind = .effect;
        diagnostic.effect_detail = detail;
        diagnostic.source = detail.source;
        const message = switch (detail.reason) {
            .denied => "operation was not granted",
            .unhandled => "operation has no host handler",
            .handler_failed => "host effect handler failed",
            .initialization => "effects cannot be performed during application initialization",
            .reentry => "nested effect execution is unavailable",
            .limit => "effect exceeded a configured resource limit",
            .invalid_request => "effect request is invalid",
            .invalid_result => "effect handler or receipt returned an invalid result",
            .contract => "effect value does not satisfy its operation contract",
            else => "effect replay differs from the recorded operation sequence",
        };
        diagnostic.message_len = copyBounded(&diagnostic.message, message, &diagnostic.truncated);
    } else if (iso.lastError()) |ruby| {
        // Only the sandbox's retained inert view is accepted. General Vm
        // RubyError helpers may call guest methods and are intentionally unused.
        if (ruby.inert) |metadata| {
            diagnostic.kind = .ruby;
            const class_name = inertText(ruby.mrb, metadata.class_name) orelse "<anonymous exception>";
            diagnostic.class_name_len = copyBounded(&diagnostic.class_name, class_name, &diagnostic.truncated);
            diagnostic.message_len = copyBounded(&diagnostic.message, inertText(ruby.mrb, metadata.message) orelse class_name, &diagnostic.truncated);
            var source: c.DiagnosticSource = .{};
            if (c.mrz_diagnostic_source_exception(ruby.mrb, ruby.exc, &source)) diagnostic.source = source;
        }
    }
}

fn terminalFailure(destination: ?*Diagnostic, err: anyerror, phase: Diagnostic.Phase) void {
    const diagnostic = destination orelse return;
    recordFailure(destination, err, phase);
    if (diagnostic.kind == .contract) return;
    diagnostic.kind = .terminal;
    diagnostic.message_len = copyBounded(&diagnostic.message, "turn must return an inert [result, next_state] pair within the configured limits", &diagnostic.truncated);
}

fn recordFailure(destination: ?*Diagnostic, err: anyerror, phase: Diagnostic.Phase) void {
    const diagnostic = destination orelse return;
    if (diagnostic.kind == .none) diagnostic.kind = .failure;
    if (diagnostic.origin == .none) diagnostic.origin = .turn;
    if (diagnostic.phase == .none) diagnostic.phase = phase;
    if (diagnostic.error_name_len == 0)
        diagnostic.error_name_len = copyBounded(&diagnostic.error_name, @errorName(err), &diagnostic.truncated);
}

fn copyBounded(buffer: []u8, bytes: []const u8, truncated: *bool) u16 {
    const size = @min(buffer.len, bytes.len);
    @memcpy(buffer[0..size], bytes[0..size]);
    truncated.* = truncated.* or size < bytes.len;
    return @intCast(size);
}

fn inertText(mrb: *c.mrb_state, value: c.mrb_value) ?[]const u8 {
    if (c.mrz_string_p(value)) {
        const pointer = c.mrz_string_ptr(value) orelse return null;
        const length = c.mrz_string_len(value);
        if (length < 0) return null;
        return pointer[0..@intCast(length)];
    }
    if (c.mrz_symbol_p(value)) {
        var length: c.mrb_int = 0;
        const pointer = c.mrb_sym_name_len(mrb, c.mrz_symbol(value), &length) orelse return null;
        if (length < 0) return null;
        return pointer[0..@intCast(length)];
    }
    return null;
}

fn digest(bytes: []const u8) [32]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return hash;
}
