//! Strict minimal native runtime and bounded application initialization.
//! Program supplies guarded in-process embedding; Turn adds explicit state
//! and data-only adapters; Worker adds OS containment with a host broker.
//! Native adapter semantics remain trusted. General embedding is in sandbox/Vm.
const std = @import("std");
const sandbox = @import("sandbox.zig");
const codedb = @import("codedb.zig");
const effect = @import("effect.zig");
const features = @import("features.zig");
const c = @import("c.zig");
const Value = @import("value.zig").Value;

/// Fresh-VM execution with explicit state, data-only handlers, and terminal
/// replay verification. Program below retains the lower-level embedding API.
pub const Turn = @import("strict_turn.zig");
/// Fresh OS-contained workers, with host-only data adapters and replay admission.
pub const Worker = @import("effect_worker.zig");

pub const Options = struct {
    /// Unset gas receives a finite default. Explicit unlimited gas is rejected;
    /// initialization and calls both require an instruction budget.
    policy: sandbox.Policy = .{ .limits = .{ .gas = .{ .per_execution = 100_000 }, .call_depth = 64 } },
    effects: effect.Config = .{},
    /// Additional trusted host setup/adapter contract beyond the actual bundle
    /// and strict runtime profile. Never use this to omit a relevant input.
    bootstrap_identity: [32]u8 = @splat(0),
    /// Optional owned failure details, captured before failed setup is freed.
    diagnostic: ?*Turn.Diagnostic = null,
};

pub const ProgramIdentity = struct { code: [32]u8, bootstrap: [32]u8 };

/// Compute the same artifact/bootstrap identities as Program.load, without
/// creating a VM. Brokers use this to validate a child process's receipt.
pub fn identify(comptime manifest: type, entry: []const u8, options: Options) !ProgramIdentity {
    // Validate names/manifest before creating an interpreter. Hash actual
    // artifacts, not caller-supplied claims about which code was loaded.
    _ = codedb.lookup(manifest, entry) orelse return error.UnknownArtifact;
    var code = std.crypto.hash.sha2.Sha256.init(.{});
    code.update("mruby-zig.strict.program.v1\x00");
    hashBytes(&code, entry);
    for (manifest.entries) |artifact| {
        hashBytes(&code, artifact.name);
        hashBytes(&code, artifact.bytes);
        const is_entrypoint = if (@hasField(@TypeOf(artifact), "entrypoint")) artifact.entrypoint else true;
        code.update(&.{if (is_entrypoint) 1 else 0});
        const dependencies: []const []const u8 = if (@hasField(@TypeOf(artifact), "dependencies")) artifact.dependencies else &.{};
        var count: [8]u8 = undefined;
        std.mem.writeInt(u64, &count, @intCast(dependencies.len), .big);
        code.update(&count);
        for (dependencies) |dependency| hashBytes(&code, dependency);
    }
    var bootstrap = std.crypto.hash.sha2.Sha256.init(.{});
    bootstrap.update("mruby-zig.strict.bootstrap.v1\x00");
    bootstrap.update(&features.rite_compatibility_fingerprint);
    bootstrap.update(&options.bootstrap_identity);
    for (options.effects.allowed) |grant| hashBytes(&bootstrap, grant);
    return .{ .code = code.finalResult(), .bootstrap = bootstrap.finalResult() };
}

/// Owns one initialized VM. Returned Values borrow its lifetime. The caller
/// supplies the complete current receiver/adapter state identity for each turn;
/// this module does not infer arbitrary native adapter state or commit it.
pub const Program = struct {
    internal: sandbox.Isolate,
    code_identity: [32]u8,
    bootstrap_identity: [32]u8,
    max_identity_bytes: usize,

    pub fn load(
        comptime manifest: type,
        entry: []const u8,
        comptime operations: anytype,
        options: Options,
    ) !Program {
        if (options.diagnostic) |diagnostic| diagnostic.* = .{};
        if (comptime !features.effects_strict) return error.StrictProfileRequired;
        const identity = try identify(manifest, entry, options);

        var policy = sandbox.Policy.restricted(options.policy);
        if (policy.limits.gas) |gas| {
            if (gas == .unlimited) return error.InvalidStrictPolicy;
        } else if (policy.limits.instructions == null) {
            policy.limits.gas = .{ .per_execution = 100_000 };
        }
        // The native gate is compiled into VM creation. Language capabilities
        // are stripped before initializers, while class definitions still work.
        policy.capabilities.freeze_object_model = false;
        if (policy.capabilities.random_seed != null or policy.capabilities.clock_epoch_s != null)
            return error.InvalidStrictPolicy;
        var boot = try sandbox.BootstrapIsolate.spawn(policy);
        defer boot.deinit();
        try effect.install(boot.vm(), operations, options.effects);
        const iso = try boot.seal();
        errdefer iso.deinit();
        _ = codedb.initializeStrict(iso, manifest, entry) catch |err| {
            Turn.captureDiagnostic(iso, options.diagnostic, err, .setup);
            return err;
        };
        iso.sealModel() catch |err| {
            Turn.captureDiagnostic(iso, options.diagnostic, err, .setup);
            return err;
        };
        return .{
            .internal = iso,
            .code_identity = identity.code,
            .bootstrap_identity = identity.bootstrap,
            .max_identity_bytes = @min(options.effects.limits.max_request_bytes, options.effects.limits.max_bytes),
        };
    }

    pub fn deinit(program: Program) void {
        program.internal.deinit();
    }

    pub fn call(program: Program, receiver_name: []const u8, method: []const u8, arguments: anytype, state_identity: [32]u8) !Value {
        const invocation: effect.Invocation = .{
            .code = program.code_identity,
            .bootstrap = program.bootstrap_identity,
            .state = state_identity,
            .receiver = receiver_name,
        };
        // Reject malformed identity text before class lookup interns symbols
        // or allocates in the VM. The isolate validates again with its contract.
        try invocation.validate(method, program.max_identity_bytes);
        const receiver = try program.internal.classValue(receiver_name);
        return program.internal.callWithEffects(receiver, method, arguments, invocation);
    }

    pub fn takeEffectTrace(program: Program) !effect.Trace {
        return program.internal.takeEffectTrace();
    }
    pub fn effectDiagnostic(program: Program) !?effect.Diagnostic {
        return program.internal.effectDiagnostic();
    }
    pub fn nativeDiagnostic(program: Program) !?c.StrictDiagnostic {
        return program.internal.nativeDiagnostic();
    }
    pub fn stats(program: Program) sandbox.Stats {
        return program.internal.stats();
    }
};

fn hashBytes(hash: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, @intCast(bytes.len), .big);
    hash.update(&length);
    hash.update(bytes);
}
