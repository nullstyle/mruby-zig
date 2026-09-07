//! Shared inert validation and owned turn inputs; never constructs a VM.
const std = @import("std");
const Turn = @import("strict_turn.zig");
const Request = Turn.Request;
const Options = Turn.Options;
const effect = @import("effect.zig");
const artifact = @import("artifact.zig");
const codec = @import("artifact_value.zig");
const c = @import("c.zig");
const features = @import("features.zig");
const contracts = @import("turn_contract.zig");

pub fn capsuleLimits(options: Options) artifact.CapsuleLimits {
    return options.policy.artifacts.limits.capsule.tightened(options.capsule_limits).tightened(
        effect.data.limits(options.capsule_limits.max_encoded_bytes),
    );
}

pub fn terminalLimits(options: Options) artifact.CapsuleLimits {
    var limits = capsuleLimits(options);
    limits.max_encoded_bytes = @min(limits.max_encoded_bytes, options.receipt_limits.max_terminal_bytes);
    return limits;
}

pub fn validateTerminal(allocator: std.mem.Allocator, view: artifact.StateCapsuleView, limits: artifact.CapsuleLimits) !void {
    var graph = try codec.parse(allocator, view, .{ .limits = limits, .allow_float = !features.effects_integer64 }, null);
    defer graph.deinit(allocator);
    if (graph.root.tag != c.MRZ_ARTIFACT_REF_NODE) return error.InvalidTurnResult;
    const node = graph.nodes[@intCast(graph.root.payload)];
    if (node.kind != c.MRZ_ARTIFACT_NODE_ARRAY or node.edge_count != 2) return error.InvalidTurnResult;
}

/// Both the broker and local runner use the same inert terminal admission.
/// Diagnostics leave provenance to their caller; no VM or formatter is invoked.
pub fn validateTerminalContract(allocator: std.mem.Allocator, view: artifact.StateCapsuleView, limits: artifact.CapsuleLimits, contract: ?*const Turn.Contract, diagnostic: ?*Turn.Diagnostic, phase: Turn.Diagnostic.Phase) !void {
    const shape = contract orelse return validateTerminal(allocator, view, limits);
    var document = try effect.data.Document.decodeWithOptions(allocator, view, .{ .limits = limits, .allow_float = !features.effects_integer64 });
    defer document.deinit();
    const root = document.root();
    if (root.kind() != .array or try root.len() != 2) return error.InvalidTurnResult;
    try validateValue(shape, .result, try root.at(0), diagnostic, phase);
    try validateValue(shape, .next_state, try root.at(1), diagnostic, phase);
}

fn validateValue(contract: *const Turn.Contract, side: contracts.Side, value: effect.data.Ref, destination: ?*Turn.Diagnostic, phase: Turn.Diagnostic.Phase) !void {
    if (contract.validate(side, value)) |mismatch| {
        if (destination) |diagnostic| if (diagnostic.kind == .none) {
            diagnostic.* = .{ .kind = .contract, .phase = phase, .contract_detail = mismatch };
            const message = "turn value does not satisfy its data contract";
            @memcpy(diagnostic.message[0..message.len], message);
            diagnostic.message_len = message.len;
        };
        return error.TurnContractViolation;
    }
}

fn copyInput(allocator: std.mem.Allocator, view: artifact.StateCapsuleView, limits: artifact.CapsuleLimits, contract: ?*const Turn.Contract, side: contracts.Side, diagnostic: ?*Turn.Diagnostic) !artifact.StateCapsule {
    var document = try effect.data.Document.decodeWithOptions(allocator, view, .{ .limits = limits, .allow_float = !features.effects_integer64 });
    errdefer document.deinit();
    if (contract) |shape| try validateValue(shape, side, document.root(), diagnostic, .setup);
    // Transfer the already validated, owned bytes to Snapshot.
    document.graph.deinit(allocator);
    return document.capsule;
}

pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    request: Request,
    identity: [32]u8,
    contract: ?*const Turn.Contract,

    pub fn init(allocator: std.mem.Allocator, request: Request, options: Options) !Snapshot {
        const invocation: effect.Invocation = .{ .code = @splat(0), .bootstrap = @splat(0), .state = @splat(0), .receiver = request.receiver };
        try invocation.validate(request.method, @min(options.effect_limits.max_request_bytes, options.effect_limits.max_bytes));
        const limits = capsuleLimits(options);
        const contract = if (options.contract) |source| blk: {
            const copy = try allocator.create(Turn.Contract);
            errdefer allocator.destroy(copy);
            copy.* = try source.checkedCopy();
            break :blk copy;
        } else null;
        errdefer if (contract) |copy| allocator.destroy(copy);
        var state = try copyInput(allocator, request.state, limits, contract, .state, options.diagnostic);
        errdefer state.deinit(allocator);
        var input = try copyInput(allocator, request.input, limits, contract, .input, options.diagnostic);
        errdefer input.deinit(allocator);
        const receiver = try allocator.dupe(u8, request.receiver);
        errdefer allocator.free(receiver);
        const method = try allocator.dupe(u8, request.method);
        errdefer allocator.free(method);
        const state_bytes = state.encoded;
        const input_bytes = input.encoded;
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("mruby-zig.strict.turn-input.v1\x00");
        hash.update(&options.adapter_state_identity);
        for ([_][]const u8{ state_bytes, input_bytes }) |bytes| {
            var length: [8]u8 = undefined;
            std.mem.writeInt(u64, &length, @intCast(bytes.len), .big);
            hash.update(&length);
            hash.update(bytes);
        }
        if (contract) |shape| {
            hash.update("mruby-zig.strict.turn-contract.v1\x00");
            hash.update(&shape.digest());
        }
        return .{
            .allocator = allocator,
            .request = .{ .receiver = receiver, .method = method, .state = .{ .bytes = state_bytes }, .input = .{ .bytes = input_bytes } },
            .identity = hash.finalResult(),
            .contract = contract,
        };
    }
    pub fn deinit(self: *Snapshot) void {
        self.allocator.free(self.request.receiver);
        self.allocator.free(self.request.method);
        self.allocator.free(self.request.state.bytes);
        self.allocator.free(self.request.input.bytes);
        if (self.contract) |contract| self.allocator.destroy(contract);
    }
};
