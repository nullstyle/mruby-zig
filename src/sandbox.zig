//! Sandboxing: v8-isolate parity, then better.
//!
//! An `Isolate` owns a private `Vm` (separate heap, symbols, globals —
//! nothing is shared between isolates) plus an enforced `Policy`:
//!
//!   - `gas`: deterministic instruction gas, either one sticky Isolate
//!     allowance or a fresh allowance per admitted outermost execution (v8
//!     has no equivalent),
//!   - `wall_time_ns`: deadline checked between instructions,
//!   - `memory_bytes` / `hard_memory_bytes`: per-isolate allocation caps
//!     with soft (rescuable NoMemoryError) → hard (un-rescuable
//!     termination) escalation,
//!   - `call_depth`: tighter than mruby's fixed 512,
//!   - `Capabilities`: deny-by-default grants of `eval`/`send`/
//!     introspection/ObjectSpace (see `Policy.trusted` / `Policy.restricted`),
//!     freeze the core object model (`def` → FrozenError), pin the RNG
//!     seed and the clock for reproducible runs.
//!
//! `terminate()` is safe to call from any thread and is observed at the next
//! bytecode fetch. Delivery may wait for a catchable VM position and then uses
//! bounded handler grace: scripts cannot `rescue` their way out, but `ensure`
//! blocks still run — unlike mruby's task-stop mechanism, which skips them.
//!
//! Same class of caveat as v8 native code: the hook fires on bytecode only.
//! Long pure-C operations and host Zig callbacks are not instruction-
//! interruptible; memory caps constrain attributable allocations, not CPU
//! time. Keep callbacks bounded; they may poll `Isolate.pendingTermination`
//! for an external or already-recorded cause.
//!
//! For a fresh-process boundary, `mruby.worker.runRite` exposes a smaller
//! one-shot interface around this machinery: typed RITE and StateCapsules in,
//! a typed capsule or failure out, with OS-level supervision on Linux/macOS.

const std = @import("std");
const c = @import("c.zig");
const vm_mod = @import("vm.zig");
const value_mod = @import("value.zig");
const error_mod = @import("error.zig");
const alloc_mod = @import("alloc.zig");
const gas_mod = @import("gas.zig");
const artifact_mod = @import("artifact.zig");
const artifact_value = @import("artifact_value.zig");
const artifact_config = @import("artifact_config");
const codedb_mod = @import("codedb.zig");
const arena_mod = @import("arena.zig");
const authority = @import("authority_manifest");
const features = @import("features.zig");
const effect_mod = @import("effect.zig");
const convert_mod = @import("convert.zig");

pub const Vm = vm_mod.Vm;
pub const Value = value_mod.Value;
pub const Array = value_mod.Array;
pub const Hash = value_mod.Hash;
pub const HashEntry = value_mod.HashEntry;
pub const RootedValue = arena_mod.RootedValue;
pub const RubyError = error_mod.RubyError;

pub const GasPolicy = gas_mod.Policy;
pub const GasScope = gas_mod.Scope;
pub const GasStats = gas_mod.Stats;

pub const CompileRiteOptions = struct {
    include_debug: bool = false,
    source_name: []const u8 = "(mruby-zig)",
    application: ?artifact_mod.ApplicationFingerprint = null,
};

pub const CompileRiteError = std.mem.Allocator.Error || error{
    CompilerUnavailable,
    CompileFailed,
    InvalidSource,
    InvalidSourceName,
};

pub const HostOperationError = error{
    IsolatePreparing,
    IsolateThreadBusy,
    MemoryLimitExceeded,
};

pub const RootError = HostOperationError || arena_mod.RootError;

pub const RunRiteError = artifact_mod.RiteValidationError || effect_mod.ExecutionError || error{
    NativeEffectViolation,
    StrictAttemptActive,
    StrictProfileRequired,
    IsolatePreparing,
    IsolateThreadBusy,
    RubyException,
    ScriptTerminated,
    DeadlineExceeded,
    GasExhausted,
    MemoryLimitExceeded,
    CallDepthExceeded,
    CapabilityApplicationFailed,
};

pub const ExportValueOptions = struct {
    limits: ?artifact_mod.CapsuleLimits = null,
    schema: ?artifact_mod.Schema = null,
};

pub const ImportValueOptions = struct {
    limits: ?artifact_mod.CapsuleLimits = null,
    accepted_schema: ?artifact_mod.Schema = null,
};

pub const ValueCodecError = artifact_mod.FramingError || error{
    ForeignValue,
    UnsupportedValue,
    UnsupportedContainerState,
    UnsupportedHashKey,
    NumericOutOfRange,
    NumericPolicyViolation,
    CapsuleLimitExceeded,
    SchemaMismatch,
    IsolatePreparing,
    IsolateThreadBusy,
    MemoryLimitExceeded,
    ArtifactConstructionFailed,
};

pub const ExportValueError = std.mem.Allocator.Error || ValueCodecError;
pub const ImportValueError = std.mem.Allocator.Error || ValueCodecError;

pub const ArtifactDiagnostic = struct {
    kind: Kind,
    encoded_offset: ?usize = null,
    graph_path: ?[]const u8 = null,
    value_type: ?value_mod.Type = null,

    pub const Kind = enum {
        invalid_envelope,
        checksum_mismatch,
        unsupported_version,
        limit_exceeded,
        foreign_value,
        unsupported_value,
        unsupported_container_state,
        unsupported_hash_key,
        numeric_out_of_range,
        schema_mismatch,
        dangling_reference,
        duplicate_object_id,
        duplicate_hash_key,
        construction_failed,
    };
};

/// Enforced resource limits. All optional; unset fields are unbounded.
pub const Limits = struct {
    /// Deprecated compatibility spelling for `.gas = .{ .per_isolate = N }`.
    instructions: ?u64 = null,
    /// Instruction-gas policy. Null derives from `instructions` during the
    /// compatibility window; setting both fields is an error.
    gas: ?GasPolicy = null,
    /// Lifetime deadline in nanoseconds. It starts when the first outer entry
    /// begins preflight (not at spawn), spans idle time, and is never renewed.
    wall_time_ns: ?u64 = null,
    /// Soft per-isolate memory cap in bytes: crossing it fails the next
    /// allocation (mruby runs a full GC, retries once, then raises the
    /// rescuable NoMemoryError); the instruction hook then escalates.
    memory_bytes: ?usize = null,
    /// Hard cap: crossing it fails allocations permanently and terminates.
    /// Defaults to `memory_bytes + max(1 MiB, memory_bytes/2)` when only
    /// the soft cap is given.
    hard_memory_bytes: ?usize = null,
    /// Interpreter call-depth ceiling (mruby's own fixed limit is 512).
    call_depth: ?u32 = null,
};

/// What Ruby-level authority the script gets. The default gem set is
/// already compute-only (no io/socket/dir/process); these strip
/// language-level escape hatches and ambient introspection.
///
/// Capability grants are **deny-by-default**: the zero value strips every
/// language capability, so a `Policy` constructed without a preset is the
/// fail-closed floor. Grant ambient language authority explicitly through
/// `Policy.trusted` (or individual fields), never by relying on defaults —
/// a capability added in a future release defaults to denied.
pub const Capabilities = struct {
    /// String-eval and metaprogramming-eval entry points:
    /// Kernel#eval / #binding, BasicObject#instance_eval / #instance_exec,
    /// and Module#class_eval / #module_eval. Denied by default.
    eval: bool = false,
    /// send / __send__ / public_send. Denied by default.
    send: bool = false,
    /// The exact audited set of reflective variable, method, binding, symbol,
    /// class, and module operations in authority_manifest. This is not an
    /// information-hiding mode: basic queries such as `class`, `respond_to?`,
    /// `ancestors`, `method_defined?`, and `const_get` remain. Denied by default.
    introspection: bool = false,
    /// The ObjectSpace module. Denied by default.
    object_space: bool = false,
    /// Freeze core classes: later `def`/`include` on them raises
    /// FrozenError. Apply after registering host methods.
    freeze_object_model: bool = false,
    /// Seed the RNG for reproducible `rand` sequences (mruby-random). mruby's
    /// generator consumes the low 32 bits.
    random_seed: ?u64 = null,
    /// Make `Time.now` return a fixed time (epoch seconds).
    clock_epoch_s: ?i64 = null,
};

pub const Policy = struct {
    limits: Limits = .{},
    capabilities: Capabilities = .{},
    artifacts: artifact_mod.Acceptance = .{},

    /// Trusted-embedding preset: grants the ambient language capabilities
    /// (`eval`, `send`, `introspection`, `object_space`) on top of `base`.
    /// Use for Ruby the host authored or fully controls; combine with
    /// `limits` for resource ceilings.
    pub fn trusted(base: Policy) Policy {
        var p = base;
        p.capabilities.eval = true;
        p.capabilities.send = true;
        p.capabilities.introspection = true;
        p.capabilities.object_space = true;
        return p;
    }

    /// Semi-trusted preset: the deny-by-default capability floor plus
    /// `freeze_object_model`, so scripts neither eval nor reopen core
    /// classes. `base` contributes limits, artifact acceptance, seeding,
    /// and clock pinning; its language-capability grants are discarded.
    pub fn restricted(base: Policy) Policy {
        var p = base;
        p.capabilities.eval = false;
        p.capabilities.send = false;
        p.capabilities.introspection = false;
        p.capabilities.object_space = false;
        p.capabilities.freeze_object_model = true;
        return p;
    }
};

pub const Stats = struct {
    /// Saturating lifetime count of every observed bytecode fetch, including
    /// bounded termination-delivery work.
    instructions: u64,
    /// Null only when gas is unlimited.
    gas: ?GasStats = null,
    peak_memory_bytes: usize,
    live_memory_bytes: usize,
    peak_call_depth: u32,
    live_objects: usize,
    wall_time_ns: u64,
    soft_memory_limit_hit: bool,
    hard_memory_limit_hit: bool,
};

/// Why a sandboxed run ended by policy (surfaced as distinct Zig errors).
pub const TerminationKind = enum {
    script, // Isolate.terminate()
    deadline,
    gas,
    memory,
    call_depth,
};

const term_script: u8 = 1 << 0;
const term_deadline: u8 = 1 << 1;
const term_gas: u8 = 1 << 2;
const term_memory: u8 = 1 << 3;
const term_call_depth: u8 = 1 << 4;

const Phase = enum { idle, preparing, running };
const CapabilityState = enum { pending, ready, failed };

const clock_batch: u16 = 1024; // deadline sampled every N instructions
const handler_grace_instructions = 1024;
const uncovered_wait_limit = 4096;

/// Monotonic nanoseconds since an arbitrary epoch (libc
/// clock_gettime(CLOCK_MONOTONIC); QueryPerformanceCounter on Windows).
pub fn monotonicNs() i128 {
    if (@import("builtin").os.tag == .windows) {
        var counter: std.os.windows.LARGE_INTEGER = undefined;
        if (std.os.windows.QueryPerformanceCounter(&counter) != 0) {
            var freq: std.os.windows.LARGE_INTEGER = undefined;
            if (std.os.windows.QueryPerformanceFrequency(&freq) != 0 and freq != 0) {
                return @divFloor(
                    @as(i128, counter) * std.time.ns_per_s,
                    @as(i128, freq),
                );
            }
        }
        return 0;
    }
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

/// Host-side sleep (libc nanosleep); utility for orchestrating tests and
/// supervisors around `Isolate.terminate`.
pub fn sleepNs(ns: u64) void {
    if (@import("builtin").os.tag == .windows) {
        std.os.windows.Sleep(@intCast(@divTrunc(ns, std.time.ns_per_ms)));
        return;
    }
    var empty: std.c.timespec = undefined;
    var req: std.c.timespec = .{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    _ = std.c.nanosleep(&req, &empty);
}

const IsolateState = struct {
    /// Trusted-bootstrap escape hatch: direct access to the underlying `Vm`
    /// bypasses admission, gas, deadlines, and capability state. Intended for
    /// the bootstrap window — defining host classes and methods — which ends
    /// at `seal()`.
    vm: *Vm,
    /// Spawn-time resolution of `Policy`. The isolate never consults a
    /// mutable policy after spawn: everything below was resolved once and
    /// later mutation of a host-held `Policy` value has no effect.
    resolved_caps: Capabilities,
    wall_budget_ns: ?u64,
    call_depth_limit: ?u32,
    artifact_acceptance: artifact_mod.Acceptance,
    resolved_gas: GasPolicy,
    gas_meter: ?gas_mod.Meter,
    last_gas: ?GasStats,
    cell: alloc_mod.IsolateCell = .{},
    /// Serializes the public operations that can enter or inspect the mruby
    /// state. It is deliberately non-blocking: accidental same-Isolate
    /// concurrency is reported to the caller instead of stalling.
    operation_lock: std.atomic.Mutex = .unlocked,
    /// CodeDB's generation belongs to the isolate, so copying a public handle
    /// cannot reset load-once state or replace a poisoned artifact set.
    codedb_identity: ?*const anyopaque = null,
    codedb_loaded: []bool = &.{},
    codedb_poisoned: bool = false,

    // hook/runtime state (owned by the isolate's thread while running)
    termination_bits: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    instr_count: u64 = 0,
    clock_countdown: u16 = clock_batch,
    gas_remaining: u64 = 0,
    /// Instruction budget granted to handler bodies (and any immediate
    /// post-handler continuation) after a termination was raised: mruby
    /// clears mrb->exc while a handler runs, so unwinding is otherwise
    /// undetectable there, and a rescue that catches the termination can
    /// briefly keep executing. When the budget hits zero, termination
    /// re-raises unconditionally — execution past a termination is
    /// bounded, and the error always surfaces to the host.
    handler_grace: u64 = 0,
    /// Grace is granted once per termination (a re-raise inside a handler
    /// must not re-arm it, or a rescue/catch loop could run forever in
    /// grace-sized bursts).
    grace_armed: bool = false,
    /// Termination is armed for delivery beginning with the fetch AFTER the
    /// one that detected the violation: the hook runs before instruction
    /// execution, and catch-handler coverage requires pc to have advanced
    /// past the region start (a raise at a region's first instruction would
    /// find no handler and skip ensure blocks).
    /// Termination is armed but waiting for a fetch where the raise would
    /// actually be catchable (hook-time pc hasn't advanced past the
    /// current instruction, and backward jumps can land exactly on a
    /// region start, which catch coverage excludes).
    raise_pending: bool = false,
    uncovered_waits: u32 = 0,
    deadline_ns: ?i128 = null,
    start_ns: i128 = 0,
    elapsed_ns: u64 = 0,
    peak_call_depth: u32 = 0,
    phase: Phase = .idle,
    capabilities: CapabilityState = .pending,

    // hidden exception classes (rooted as constants of this module)
    hidden: *c.RClass,
    sandbox_context: c.mrz_sandbox_context,
    /// Cached Time value returned by the non-dispatching `Time.now` callback.
    /// The hidden module's FROZEN_TIME constant keeps it rooted.
    frozen_time: c.mrb_value,
    /// Original native reseeder captured before the trusted bootstrap window.
    random_srand: ?c.mrb_func_t,
    /// Exception (as a raw value) behind the last failed run; funcalling
    /// with mrb->exc pending can clobber it, so it is stashed and the
    /// pending state cleared before classification.
    last_exc: c.mrb_value = undefined,
    /// Preallocated one-element array registered as a GC root. Its element is
    /// replaced allocation-free when an ordinary exception is captured.
    error_root: c.mrb_value,
    policy_exceptions: c.mrb_value,
    error_message: c.mrb_value,
    error_class: c.mrb_value,
    artifact_diagnostic: ?ArtifactDiagnostic = null,
    artifact_path: ?[]u8 = null,

    /// Allocate and initialize the underlying state. Public entry points
    /// are `BootstrapIsolate.spawn` (bootstrap window) and its `seal`.
    fn create(policy: Policy) !*IsolateState {
        const resolved_gas = try resolveGas(policy.limits);
        const initial_meter = gas_mod.Meter.init(resolved_gas);

        // Allocate the stable owner cell before mruby. Allocation headers keep
        // this address so frees/reallocs remain attributable after bootstrap.
        const iso = try alloc_mod.gpa.create(IsolateState);
        errdefer alloc_mod.gpa.destroy(iso);
        iso.cell = .{};
        try iso.cell.initOwnership();
        errdefer iso.cell.retireOwnership();
        const attribution = alloc_mod.pushIsolate(&iso.cell);
        defer alloc_mod.restoreIsolate(attribution);

        const vm = try Vm.init();
        errdefer vm.deinit();

        const bootstrap = try bootstrapSandbox(vm);
        const hidden = bootstrap.hidden;

        const bootstrap_live_bytes = iso.cell.live_bytes;
        const bootstrap_live_allocs = iso.cell.live_allocs;
        const bootstrap_owner = iso.cell.owner_token;

        iso.* = .{
            .vm = vm,
            .resolved_caps = policy.capabilities,
            .wall_budget_ns = policy.limits.wall_time_ns,
            .call_depth_limit = policy.limits.call_depth,
            .artifact_acceptance = policy.artifacts,
            .resolved_gas = resolved_gas,
            .gas_meter = initial_meter,
            .last_gas = if (initial_meter) |meter| meter.snapshot() else null,
            .hidden = hidden,
            .sandbox_context = .{
                .userdata = iso,
                .observer = fetchHook,
            },
            .frozen_time = c.mrz_nil_value(),
            .random_srand = bootstrap.random_srand,
            .last_exc = c.mrz_nil_value(),
            .error_root = bootstrap.error_root,
            .policy_exceptions = bootstrap.policy_exceptions,
            .error_message = c.mrz_nil_value(),
            .error_class = c.mrz_nil_value(),
            .cell = .{
                // Bootstrap allocations (state, symbols, core classes,
                // termination classes) are permanent; count them toward
                // the caps so budgets reflect true isolate footprint.
                .live_bytes = bootstrap_live_bytes,
                .live_allocs = bootstrap_live_allocs,
                .peak_bytes = bootstrap_live_bytes,
                .soft_cap = policy.limits.memory_bytes,
                .hard_cap = policy.limits.hard_memory_bytes orelse defaultHardCap(policy.limits.memory_bytes),
                .on_limit = allocatorLimit,
                .on_limit_ctx = iso,
                .owner_token = bootstrap_owner,
            },
        };
        iso.gas_remaining = switch (resolved_gas) {
            .unlimited => 0,
            .per_isolate, .per_execution => |limit| limit,
        };
        c.mrz_set_sandbox_context(vm.mrb, &iso.sandbox_context);
        return iso;
    }

    pub fn deinit(iso: *IsolateState) void {
        iso.clearArtifactDiagnostic();
        if (iso.codedb_loaded.len != 0) alloc_mod.gpa.free(iso.codedb_loaded);
        const attribution = alloc_mod.pushIsolate(&iso.cell);
        c.mrz_set_sandbox_context(iso.vm.mrb, null);
        iso.vm.deinit();
        alloc_mod.restoreIsolate(attribution);
        iso.cell.retireOwnership();
        alloc_mod.gpa.destroy(iso);
    }

    /// Run `src` under the policy. Policy terminations surface as distinct
    /// errors (`ScriptTerminated`, `DeadlineExceeded`, `GasExhausted`,
    /// `MemoryLimitExceeded`, `CallDepthExceeded`); ordinary script errors
    /// as `error.RubyException` (see `iso.lastError()`).
    /// Runtime-only builds return `CompilerUnavailable` before admission.
    pub fn run(iso: *IsolateState, src: []const u8) !Value {
        if (comptime !features.has_compiler) return error.CompilerUnavailable;
        return iso.enterExecution(struct {
            fn body(iso_: *IsolateState, src_: []const u8) !Value {
                return iso_.vm.loadString(src_);
            }
        }.body, src, iso.effectCodeIdentity("source", src));
    }

    /// Deprecated compatibility operation: run an unframed snapshot produced
    /// by `compile` (no compatibility or application checks). Use `runRite`.
    pub fn runImage(iso: *IsolateState, image: []const u8) !Value {
        return iso.enterExecution(struct {
            fn body(iso_: *IsolateState, image_: []const u8) !Value {
                // loadIrep's C trampoline runs under mrb_protect_error and
                // checks mrb->exc, so a raising image surfaces as
                // error.RubyException (mapped to a termination error when a
                // limit fired) instead of returning the exception as a success
                // value and poisoning the next run.
                return iso_.vm.loadIrep(image_);
            }
        }.body, image, iso.effectCodeIdentity("irep", image));
    }

    /// Validate and execute a typed RITE image. Framing and compatibility
    /// failures occur before the execution lifecycle mutates isolate state.
    pub fn runRite(
        iso: *IsolateState,
        image: artifact_mod.RiteImageView,
    ) RunRiteError!Value {
        const admission = try iso.admitExecution();
        const owns_lock = admission == .outer;
        defer if (owns_lock) iso.operation_lock.unlock();

        const payload = try artifact_mod.validateRite(image, .{
            .compatibility = artifact_config.rite_compatibility_fingerprint,
            .application = iso.artifact_acceptance.application,
            .max_encoded_bytes = iso.artifact_acceptance.limits.max_rite_bytes,
        });

        const Body = struct {
            fn load(iso_: *IsolateState, bytes: []const u8) !Value {
                return iso_.vm.loadIrep(bytes);
            }
        };
        if (admission == .nested) {
            return Body.load(iso, payload.bytes) catch |err| return @errorCast(err);
        }
        return iso.enterOuterExecution(Body.load, payload.bytes, iso.effectCodeIdentity("rite", image.bytes), null) catch |err|
            return @errorCast(err);
    }

    /// Internal half of codedb.load. One lock and one outer execution cover
    /// the entire dependency closure. Metadata/byte admission precedes all
    /// guest execution and leaves an existing generation untouched on error.
    pub fn loadCodeDB(
        iso: *IsolateState,
        identity: *const anyopaque,
        entries: anytype,
        name: []const u8,
    ) codedb_mod.LoadError!bool {
        return iso.loadCodeDBMode(identity, entries, name, false);
    }

    /// The same dependency loader under a no-effects initialization phase.
    /// Used by strict.Program after native restrictions are already active.
    pub fn initializeCodeDB(
        iso: *IsolateState,
        identity: *const anyopaque,
        entries: anytype,
        name: []const u8,
    ) codedb_mod.LoadError!bool {
        if (comptime !features.effects_strict) return error.StrictProfileRequired;
        return iso.loadCodeDBMode(identity, entries, name, true);
    }

    fn loadCodeDBMode(
        iso: *IsolateState,
        identity: *const anyopaque,
        entries: anytype,
        name: []const u8,
        comptime initializing: bool,
    ) codedb_mod.LoadError!bool {
        const requested = for (entries, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.name, name)) break index;
        } else return error.UnknownArtifact;
        if (!entries[requested].entrypoint) return error.NotEntrypoint;
        const admission = try iso.admitExecution();
        if (admission == .nested) return error.IsolateThreadBusy;
        defer iso.operation_lock.unlock();
        if (iso.codedb_identity) |bound| {
            if (bound != identity) return error.CodeDBManifestMismatch;
            if (iso.codedb_poisoned) return error.CodeDBPoisoned;
            if (iso.codedb_loaded[requested]) return false;
        }

        // Scratch remains host-owned, like artifact parser scratch. Only the
        // loaded flags persist; no Ruby result is retained by the loader.
        const needed = try alloc_mod.gpa.alloc(bool, entries.len);
        defer alloc_mod.gpa.free(needed);
        @memset(needed, false);
        needed[requested] = true;
        var reverse = requested + 1;
        while (reverse != 0) {
            reverse -= 1;
            if (needed[reverse]) {
                for (entries[reverse].dependencies) |dependency| needed[dependency] = true;
            }
        }
        const payloads = try alloc_mod.gpa.alloc(?[]const u8, entries.len);
        defer alloc_mod.gpa.free(payloads);
        @memset(payloads, null);
        for (entries, needed, 0..) |entry, required, index| {
            if (!required or (iso.codedb_identity != null and iso.codedb_loaded[index])) continue;
            const payload = try artifact_mod.validateRite(.{ .bytes = entry.bytes }, .{
                .compatibility = artifact_config.rite_compatibility_fingerprint,
                .application = iso.artifact_acceptance.application,
                .max_encoded_bytes = iso.artifact_acceptance.limits.max_rite_bytes,
            });
            payloads[index] = payload.bytes;
        }
        if (iso.codedb_identity == null) {
            const loaded = try alloc_mod.gpa.alloc(bool, entries.len);
            @memset(loaded, false);
            iso.codedb_loaded = loaded;
            iso.codedb_identity = identity;
        }
        _ = iso.enterOuterPhase(struct {
            fn body(state: *IsolateState, images: []const ?[]const u8) !Value {
                for (images, 0..) |maybe_image, index| {
                    const image = maybe_image orelse continue;
                    const scope = state.vm.arenaScope();
                    defer scope.restore();
                    _ = try state.vm.loadIrep(image);
                    state.codedb_loaded[index] = true;
                }
                return state.vm.nilValue();
            }
        }.body, @as([]const ?[]const u8, payloads), null, null, initializing) catch |err| {
            // Include policy failures arbitrated AFTER the final initializer,
            // not just exceptions reported by loadIrep itself. This existing
            // contract also includes trace admission rejection before Ruby.
            iso.codedb_poisoned = true;
            return @errorCast(err);
        };
        return true;
    }

    /// Call a Ruby method under the policy (same error mapping as `run`).
    pub fn call(iso: *IsolateState, recv: Value, name: []const u8, args: anytype) !Value {
        return iso.enterExecution(struct {
            fn body(iso_: *IsolateState, ctx: anytype) !Value {
                return iso_.vm.call(ctx.recv, ctx.name, ctx.args);
            }
        }.body, .{ .recv = recv, .name = name, .args = args }, null);
    }

    /// Admit an identified outer method call. Snapshot conversion is inert and
    /// attributed, and completes before trace admission or gas renewal.
    pub fn callWithEffects(
        iso: *IsolateState,
        recv: Value,
        name: []const u8,
        args: anytype,
        invocation: effect_mod.Invocation,
    ) !Value {
        const admission = try iso.admitExecution();
        if (admission == .nested) return error.IsolateThreadBusy;
        defer iso.operation_lock.unlock();

        const effects = iso.vm.effects orelse return error.EffectNotInstalled;
        const max_bytes = @min(effects.limits.max_request_bytes, effects.limits.max_bytes);
        try invocation.validate(name, max_bytes);
        try recv.ensureOwnedBy(iso.vm.mrb);

        // On rejection discard every temporary arena root. On success the
        // returned value and its input snapshot follow Vm.call's arena lifetime;
        // the caller can bound repeated calls with an outer arena scope.
        const scope = iso.vm.arenaScope();
        errdefer scope.restore();
        var snapshot = blk: {
            iso.phase = .preparing;
            defer iso.phase = .idle;
            const attribution = alloc_mod.pushIsolate(&iso.cell);
            defer alloc_mod.restoreIsolate(attribution);
            try iso.rejectHostMemoryLimit();
            var prepared = iso.snapshotInvocationArguments(args, max_bytes) catch |err| {
                iso.rejectHostMemoryLimit() catch |limit_err| return limit_err;
                // Protected value construction can set a pending exception.
                // It belongs to this rejected host operation, not a later run.
                iso.vm.clearError();
                return err;
            };
            errdefer prepared.capsule.deinit(alloc_mod.gpa);
            try iso.rejectHostMemoryLimit();
            break :blk prepared;
        };
        defer snapshot.capsule.deinit(alloc_mod.gpa);
        const code_identity = invocation.codeIdentity(name);
        const input_identity = invocation.inputIdentity(effects.input_identity, snapshot.capsule.encoded);

        return iso.enterOuterExecution(struct {
            fn body(state: *IsolateState, ctx: anytype) !Value {
                var result: c.mrb_value = undefined;
                // An empty tuple's array can be comptime-known. Keep a runtime
                // address for the C call even when argc is zero.
                var argv = ctx.argv;
                if (!c.mrz_protected_funcall_with_block(
                    state.vm.mrb,
                    ctx.recv.v,
                    ctx.name.ptr,
                    ctx.name.len,
                    @intCast(ctx.argv.len),
                    &argv,
                    c.mrz_nil_value(),
                    &result,
                )) return error.RubyException;
                return .{ .mrb = state.vm.mrb, .v = result };
            }
        }.body, .{ .recv = recv, .name = name, .argv = snapshot.argv }, code_identity, input_identity);
    }

    fn SnapshotArguments(comptime count: usize) type {
        return struct {
            argv: [count]c.mrb_value,
            capsule: artifact_mod.StateCapsule,
        };
    }

    fn snapshotInvocationArguments(
        iso: *IsolateState,
        args: anytype,
        max_bytes: usize,
    ) !SnapshotArguments(@typeInfo(@TypeOf(args)).@"struct".field_types.len) {
        const count = comptime @typeInfo(@TypeOf(args)).@"struct".field_types.len;
        _ = std.math.cast(c.mrb_int, count) orelse return error.TooManyArguments;
        if (count > max_bytes) return error.EffectLimitExceeded;
        const limits: artifact_mod.CapsuleLimits = .{
            .max_encoded_bytes = max_bytes,
            .max_nodes = @min(max_bytes, 16_384),
            .max_total_edges = @min(max_bytes, 65_536),
            .max_depth = 64,
            .max_string_bytes = max_bytes,
            .max_symbol_bytes = max_bytes,
        };
        var values: [count]Value = undefined;
        inline for (0..count) |index| {
            values[index] = try invocationArgument(iso.vm.mrb, args[index], max_bytes);
        }
        const original = try iso.vm.array(&values);
        var capsule = artifact_value.exportValue(alloc_mod.gpa, iso.vm.mrb, original.asValue().v, .{
            .limits = limits,
        }, null) catch |err| switch (err) {
            error.ArtifactLimitExceeded, error.CapsuleLimitExceeded => return error.EffectLimitExceeded,
            else => return err,
        };
        errdefer capsule.deinit(alloc_mod.gpa);
        var graph = try artifact_value.parse(alloc_mod.gpa, capsule.view(), .{ .limits = limits, .allow_float = !features.effects_integer64 }, null);
        defer graph.deinit(alloc_mod.gpa);
        const materialized = switch (artifact_value.materialize(iso.vm.mrb, &graph)) {
            .ok => |result| result.value,
            .out_of_memory => return error.OutOfMemory,
            .invalid, .unexpected => return error.ArtifactConstructionFailed,
        };
        const snapshot = try (Value{ .mrb = iso.vm.mrb, .v = materialized }).asArray();
        var result: SnapshotArguments(count) = .{ .argv = undefined, .capsule = capsule };
        inline for (0..count) |index| result.argv[index] = (try snapshot.get(index)).v;
        return result;
    }

    fn invocationArgument(mrb: *c.mrb_state, value: anytype, max_bytes: usize) !Value {
        const T = @TypeOf(value);
        // The ordinary low-level converter accepts raw C values. Identified
        // entry cannot: those values carry no VM ownership evidence.
        if (T == c.mrb_value) return error.UnsupportedValue;
        if (T == Value or T == Array or T == Hash) return convert_mod.toValue(mrb, value);
        switch (@typeInfo(T)) {
            .optional => return if (value) |inner|
                invocationArgument(mrb, inner, max_bytes)
            else
                Value.nil(mrb),
            .pointer => |pointer| switch (pointer.size) {
                .slice => if (pointer.child == u8 and value.len > max_bytes)
                    return error.EffectLimitExceeded,
                .one => switch (@typeInfo(pointer.child)) {
                    .array => |array| if (array.child == u8 and array.len > max_bytes)
                        return error.EffectLimitExceeded,
                    else => {},
                },
                else => {},
            },
            else => {},
        }
        return convert_mod.toValue(mrb, value);
    }

    /// End the bootstrap window explicitly: apply the policy's capabilities
    /// now instead of lazily at the first `run`/`call`. This is the
    /// recommended boundary for raw-`vm` work — define host classes and
    /// methods first, then `seal`, then execute. The preflight bracket
    /// matches an outer execution (admission, deadline start, pending
    /// termination), so capability setup is accounted exactly as it would
    /// be inside a first run: its gas is charged to the current
    /// `.per_execution` generation, which the next run still renews.
    /// Idempotent: sealing an already-sealed isolate does nothing. Cannot
    /// be called from inside a host callback.
    pub fn seal(iso: *IsolateState) !void {
        const admission = try iso.admitExecution();
        // A nested admission means guest frames are live; applying
        // capability masks mid-execution is out of contract.
        if (admission == .nested) return error.IsolateThreadBusy;
        defer iso.operation_lock.unlock();

        iso.clearErrorView();
        iso.startTiming();
        defer iso.updateElapsed();

        const renewable = switch (iso.resolved_gas) {
            .per_execution => true,
            .unlimited, .per_isolate => false,
        };
        try iso.rejectPending(renewable);
        try iso.prepareCapabilities();
        try iso.rejectPending(renewable);

        iso.pollDeadline();
        if (currentTermination(iso)) |kind| return terminationError(kind);
    }

    /// Export a bounded, inert Ruby value graph. The returned bytes are owned
    /// by `allocator`; release them with `capsule.deinit(allocator)`.
    pub fn exportValue(
        iso: *IsolateState,
        allocator: std.mem.Allocator,
        root: Value,
        options: ExportValueOptions,
    ) ExportValueError!artifact_mod.StateCapsule {
        try iso.beginArtifactOperation();
        defer iso.endArtifactOperation();

        if (root.mrb != iso.vm.mrb) {
            iso.setArtifactDiagnostic(.{
                .kind = .foreign_value,
                .value_type = root.typeOf(),
            }, "$");
            return error.ForeignValue;
        }

        var failure: artifact_value.Failure = .{};
        return artifact_value.exportValue(
            allocator,
            iso.vm.mrb,
            root.v,
            .{
                .limits = iso.artifact_acceptance.limits.capsule.tightened(options.limits),
                .schema = options.schema,
            },
            &failure,
        ) catch |err| {
            iso.recordArtifactFailure(err, &failure);
            return err;
        };
    }

    /// Validate a complete StateCapsule before constructing its value graph in
    /// this isolate. Process scratch is freed before return; a successful heap
    /// result retains exactly one mruby arena root.
    pub fn importValue(
        iso: *IsolateState,
        capsule: artifact_mod.StateCapsuleView,
        options: ImportValueOptions,
    ) ImportValueError!Value {
        try iso.beginArtifactOperation();
        defer iso.endArtifactOperation();

        const limits = iso.artifact_acceptance.limits.capsule.tightened(options.limits);
        var failure: artifact_value.Failure = .{};
        var graph = artifact_value.parse(alloc_mod.gpa, capsule, .{
            .limits = limits,
            .allow_float = !features.effects_integer64,
            .accepted_schema = options.accepted_schema,
        }, &failure) catch |err| {
            iso.recordArtifactFailure(err, &failure);
            return err;
        };
        defer graph.deinit(alloc_mod.gpa);

        // A sticky destination cap cannot be relaxed by importing. Parsing is
        // intentionally complete before this check and performs no mruby work.
        if (iso.cell.anyOom()) {
            iso.setArtifactDiagnostic(.{ .kind = .limit_exceeded }, "$");
            return error.MemoryLimitExceeded;
        }

        const attribution = alloc_mod.pushIsolate(&iso.cell);
        const outcome = artifact_value.materialize(iso.vm.mrb, &graph);
        alloc_mod.restoreIsolate(attribution);

        return switch (outcome) {
            .ok => |result| Value{ .mrb = iso.vm.mrb, .v = result.value },
            .out_of_memory => {
                if (iso.cell.anyOom()) {
                    iso.setArtifactDiagnostic(.{ .kind = .limit_exceeded }, "$");
                    return error.MemoryLimitExceeded;
                }
                return error.OutOfMemory;
            },
            .invalid, .unexpected => {
                iso.setArtifactDiagnostic(.{ .kind = .construction_failed }, "$");
                return error.ArtifactConstructionFailed;
            },
        };
    }

    /// Request termination from any thread. The next bytecode fetch observes
    /// it; delivery and guest unwind then complete within bounded wait/grace
    /// budgets (`ensure` runs, while `rescue` cannot suppress it). The pending
    /// outer execution returns `error.ScriptTerminated`.
    pub fn terminate(iso: *IsolateState) void {
        noteTerm(iso, .script);
    }

    /// True while any termination cause is recorded. Sticky causes remain true
    /// after observation; renewable per-execution gas clears only after the
    /// outer unwind completes. Host callbacks can poll this to cooperatively
    /// unwind for an external or already-recorded cause.
    pub fn pendingTermination(iso: *IsolateState) bool {
        return iso.termination_bits.load(.acquire) != 0 or iso.cell.anyOom();
    }

    /// Details for the most recent admitted StateCapsule export/import
    /// failure. Borrowed slices remain valid until the next admitted value
    /// artifact operation or isolate destruction.
    pub fn lastArtifactError(iso: *const IsolateState) ?ArtifactDiagnostic {
        return iso.artifact_diagnostic;
    }

    pub fn stats(iso: *IsolateState) Stats {
        const depth: u32 = @intCast(@max(0, c.mrz_ci_depth(iso.vm.mrb)));
        const gas_stats: ?GasStats = switch (iso.resolved_gas) {
            .unlimited => null,
            .per_isolate => iso.gas_meter.?.snapshot(),
            .per_execution => if (iso.phase == .running)
                iso.gas_meter.?.snapshot()
            else
                iso.last_gas,
        };
        return .{
            .instructions = iso.instr_count,
            .gas = gas_stats,
            .peak_memory_bytes = iso.cell.peak_bytes,
            .live_memory_bytes = iso.cell.live_bytes,
            .peak_call_depth = @max(iso.peak_call_depth, depth),
            .live_objects = c.mrz_gc_live(iso.vm.mrb),
            .wall_time_ns = iso.elapsed_ns,
            .soft_memory_limit_hit = iso.cell.softOom(),
            .hard_memory_limit_hit = iso.cell.hardOom(),
        };
    }

    // ---- internals --------------------------------------------------------

    fn defaultHardCap(soft: ?usize) ?usize {
        const s = soft orelse return null;
        return s +| @max(1024 * 1024, s / 2);
    }

    fn resolveGas(limits: Limits) !GasPolicy {
        if (limits.gas != null and limits.instructions != null) {
            return error.ConflictingGasPolicy;
        }
        if (limits.gas) |gas| return gas;
        if (limits.instructions) |limit| return .{ .per_isolate = limit };
        return .unlimited;
    }

    const ExecutionAdmission = enum { nested, outer };

    fn clearArtifactDiagnostic(iso: *IsolateState) void {
        if (iso.artifact_path) |path| alloc_mod.gpa.free(path);
        iso.artifact_path = null;
        iso.artifact_diagnostic = null;
    }

    fn setArtifactDiagnostic(
        iso: *IsolateState,
        diagnostic: ArtifactDiagnostic,
        path: ?[]const u8,
    ) void {
        iso.clearArtifactDiagnostic();
        var stored = diagnostic;
        stored.graph_path = null;
        if (path) |bytes| {
            if (alloc_mod.gpa.dupe(u8, bytes)) |owned| {
                iso.artifact_path = owned;
                stored.graph_path = owned;
            } else |_| {}
        }
        iso.artifact_diagnostic = stored;
    }

    fn recordArtifactFailure(
        iso: *IsolateState,
        err: anyerror,
        failure: *const artifact_value.Failure,
    ) void {
        const failure_kind: ?ArtifactDiagnostic.Kind = switch (failure.kind) {
            .none => null,
            .invalid_artifact => .invalid_envelope,
            .artifact_limit_exceeded, .capsule_limit_exceeded => .limit_exceeded,
            .unsupported_value => .unsupported_value,
            .unsupported_hash_key => .unsupported_hash_key,
            .unsupported_container_state => .unsupported_container_state,
            .duplicate_hash_key => .duplicate_hash_key,
            .numeric_policy_violation => .unsupported_value,
        };
        const error_kind = diagnosticKindForArtifactError(err);
        // A codec refinement (notably duplicate_hash_key) is more actionable
        // than the broad InvalidArtifact error. Conversely, envelope errors
        // retain their precise checksum/version/schema classification instead
        // of being flattened by the codec's generic invalid failure marker.
        const kind = switch (failure.kind) {
            .duplicate_hash_key,
            .unsupported_value,
            .unsupported_hash_key,
            .unsupported_container_state,
            => failure_kind.?,
            else => error_kind orelse failure_kind orelse return,
        };
        iso.setArtifactDiagnostic(.{
            .kind = kind,
            .encoded_offset = failure.encoded_offset,
            .value_type = if (failure.value_type) |raw|
                @fromBackingInt(@intCast(raw))
            else
                null,
        }, if (failure.path().len == 0) null else failure.path());
    }

    fn diagnosticKindForArtifactError(err: anyerror) ?ArtifactDiagnostic.Kind {
        return switch (err) {
            error.InvalidArtifact => .invalid_envelope,
            error.ChecksumMismatch => .checksum_mismatch,
            error.UnsupportedArtifactVersion => .unsupported_version,
            error.ArtifactLimitExceeded, error.CapsuleLimitExceeded, error.MemoryLimitExceeded => .limit_exceeded,
            error.ForeignValue => .foreign_value,
            error.UnsupportedValue => .unsupported_value,
            error.UnsupportedContainerState => .unsupported_container_state,
            error.UnsupportedHashKey => .unsupported_hash_key,
            error.NumericOutOfRange => .numeric_out_of_range,
            error.NumericPolicyViolation => .unsupported_value,
            error.SchemaMismatch => .schema_mismatch,
            error.ArtifactConstructionFailed => .construction_failed,
            else => null,
        };
    }

    fn beginArtifactOperation(iso: *IsolateState) !void {
        try iso.lockIdlePhase();
        iso.clearArtifactDiagnostic();
    }

    fn endArtifactOperation(iso: *IsolateState) void {
        iso.unlockIdlePhase();
    }

    const HostOperationMode = enum { lock_only, attributed };

    /// Run a host-side (non-guest, non-artifact) operation against isolate
    /// state. One bracket owns mutual exclusion and, for potentially
    /// allocating operations, mruby allocator attribution plus memory-limit
    /// translation. Host-owned Zig scratch remains outside the mruby quota.
    /// Unlike artifact admission this preserves a pending artifact diagnostic
    /// the host may not have observed yet.
    fn hostOperation(
        iso: *IsolateState,
        comptime mode: HostOperationMode,
        comptime Result: type,
        comptime body: anytype,
        ctx: anytype,
    ) anyerror!Result {
        try iso.lockIdlePhase();
        defer iso.unlockIdlePhase();

        if (mode == .lock_only) return body(iso, ctx);

        const attribution = alloc_mod.pushIsolate(&iso.cell);
        defer alloc_mod.restoreIsolate(attribution);

        try iso.rejectHostMemoryLimit();
        const result: Result = body(iso, ctx) catch |err| {
            iso.rejectHostMemoryLimit() catch |limit_err| return limit_err;
            return err;
        };
        try iso.rejectHostMemoryLimit();
        return result;
    }

    fn rejectHostMemoryLimit(iso: *IsolateState) error{MemoryLimitExceeded}!void {
        if (!iso.cell.anyOom()) return;
        noteTerm(iso, .memory);
        c.mrz_exc_clear(iso.vm.mrb);
        return error.MemoryLimitExceeded;
    }

    fn lockIdlePhase(iso: *IsolateState) !void {
        if (alloc_mod.currentIsolateCell()) |cell| {
            if (cell != &iso.cell) return error.IsolateThreadBusy;
            return switch (iso.phase) {
                .preparing => error.IsolatePreparing,
                .running, .idle => error.IsolateThreadBusy,
            };
        }
        if (!iso.operation_lock.tryLock()) return error.IsolateThreadBusy;
        switch (iso.phase) {
            .idle => {},
            .preparing => {
                iso.operation_lock.unlock();
                return error.IsolatePreparing;
            },
            .running => {
                iso.operation_lock.unlock();
                return error.IsolateThreadBusy;
            },
        }
        iso.phase = .preparing;
    }

    fn unlockIdlePhase(iso: *IsolateState) void {
        std.debug.assert(iso.phase == .preparing);
        iso.phase = .idle;
        iso.operation_lock.unlock();
    }

    fn admitExecution(iso: *IsolateState) !ExecutionAdmission {
        // Allocator TLS identifies legitimate same-thread re-entry without
        // reading the non-atomic phase from an unrelated thread.
        if (alloc_mod.currentIsolateCell()) |cell| {
            if (cell != &iso.cell) return error.IsolateThreadBusy;
            return switch (iso.phase) {
                .running => .nested,
                .preparing => error.IsolatePreparing,
                // An idle attribution is a trusted host bracket, not nested
                // execution. Entering would overwrite its attribution.
                .idle => error.IsolateThreadBusy,
            };
        }

        if (!iso.operation_lock.tryLock()) return error.IsolateThreadBusy;
        return switch (iso.phase) {
            .idle => .outer,
            .preparing => {
                iso.operation_lock.unlock();
                return error.IsolatePreparing;
            },
            .running => {
                iso.operation_lock.unlock();
                return error.IsolateThreadBusy;
            },
        };
    }

    fn enterExecution(
        iso: *IsolateState,
        comptime body: anytype,
        ctx: anytype,
        code_identity: ?[32]u8,
    ) !Value {
        const admission = try iso.admitExecution();
        if (admission == .nested) return body(iso, ctx);
        defer iso.operation_lock.unlock();
        return iso.enterOuterExecution(body, ctx, code_identity, null);
    }

    fn enterOuterExecution(
        iso: *IsolateState,
        comptime body: anytype,
        ctx: anytype,
        code_identity: ?[32]u8,
        input_identity: ?[32]u8,
    ) !Value {
        return iso.enterOuterPhase(body, ctx, code_identity, input_identity, false);
    }

    fn enterOuterPhase(
        iso: *IsolateState,
        comptime body: anytype,
        ctx: anytype,
        code_identity: ?[32]u8,
        input_identity: ?[32]u8,
        comptime initializing: bool,
    ) !Value {
        // Trace admission is inert. A rejected identity must preserve both a
        // retained trace and the prior gas generation without entering Ruby.
        if (!initializing) if (iso.vm.effects) |state| try state.validateExecution(code_identity, input_identity);
        if (initializing and iso.vm.effects == null) return error.EffectNotInstalled;
        iso.clearErrorView();
        iso.startTiming();
        defer iso.updateElapsed();

        const renewable = switch (iso.resolved_gas) {
            .per_execution => true,
            .unlimited, .per_isolate => false,
        };
        try iso.rejectPending(renewable);
        try iso.prepareCapabilities();
        try iso.rejectPending(renewable);

        if (renewable) try iso.renewExecutionGas();

        iso.phase = .running;
        defer iso.finishExecution();

        // A non-gas termination racing after the final preflight belongs to
        // this now-committed generation, but still executes no guest body.
        try iso.rejectPending(false);

        const attribution = alloc_mod.pushIsolate(&iso.cell);
        defer alloc_mod.restoreIsolate(attribution);

        if (comptime features.effects_strict) {
            if (!c.mrz_strict_begin_attempt(iso.vm.mrb)) return error.StrictAttemptActive;
        }
        defer if (comptime features.effects_strict) c.mrz_strict_end_attempt(iso.vm.mrb);

        const effects = iso.vm.effects;
        if (effects) |state| {
            if (initializing) try state.beginInitialization() else try state.beginExecution(code_identity, input_identity);
            state.guard_context = iso;
            state.guard = effectGuard;
        }
        defer if (effects) |state| {
            state.guard = null;
            state.guard_context = null;
        };

        const result = iso.runGuestBody(body, ctx) catch |err| {
            if (effects) |state| finishEffectPhase(state, initializing, false) catch |effect_err| {
                // Termination remains authoritative even when Ruby rescued
                // an effect failure while unwinding the same execution.
                if (currentTermination(iso)) |kind| return terminationError(kind);
                if (iso.nativeViolation() != null) return error.NativeEffectViolation;
                return effect_err;
            };
            if (currentTermination(iso)) |kind| return terminationError(kind);
            if (iso.nativeViolation() != null) return error.NativeEffectViolation;
            return err;
        };
        if (iso.nativeViolation() != null) {
            if (effects) |state| finishEffectPhase(state, initializing, false) catch {};
            return error.NativeEffectViolation;
        }
        if (effects) |state| try finishEffectPhase(state, initializing, true);
        return result;
    }

    fn finishEffectPhase(state: *effect_mod.State, comptime initializing: bool, success: bool) !void {
        if (initializing) try state.finishInitialization(success) else try state.finishExecution(success);
    }

    fn nativeViolation(iso: *IsolateState) ?c.StrictDiagnostic {
        if (comptime !features.effects_strict) return null;
        var detail: c.StrictDiagnostic = undefined;
        return if (c.mrz_strict_violation(iso.vm.mrb, &detail)) detail else null;
    }

    fn runGuestBody(iso: *IsolateState, comptime body: anytype, ctx: anytype) !Value {
        const result = body(iso, ctx) catch |err| {
            if (err == error.RubyException) return iso.mapError(err);
            // The final operation may be native code with no later fetch to
            // trigger the batched hook poll. Arbitrate the deadline at every
            // outer return boundary as well.
            iso.pollDeadline();
            if (currentTermination(iso)) |kind| return terminationError(kind);
            return err;
        };
        iso.pollDeadline();
        if (currentTermination(iso)) |kind| return terminationError(kind);
        return result;
    }

    fn effectGuard(context: ?*anyopaque) anyerror!void {
        const iso: *IsolateState = @ptrCast(@alignCast(context.?));
        try iso.rejectPending(false);
    }

    fn effectCodeIdentity(iso: *const IsolateState, comptime format: []const u8, bytes: []const u8) ?[32]u8 {
        const effects = iso.vm.effects orelse return null;
        if (effects.mode == .live) return null;
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("mruby-zig.effect.code.v1\x00" ++ format ++ "\x00");
        hash.update(bytes);
        return hash.finalResult();
    }

    fn startTiming(iso: *IsolateState) void {
        if (iso.start_ns != 0) return;
        iso.start_ns = monotonicNs();
        if (iso.wall_budget_ns) |budget| {
            iso.deadline_ns = iso.start_ns + @as(i128, @intCast(budget));
        }
    }

    fn updateElapsed(iso: *IsolateState) void {
        iso.elapsed_ns = @intCast(@max(0, monotonicNs() - iso.start_ns));
    }

    fn pollDeadline(iso: *IsolateState) void {
        if (iso.deadline_ns) |deadline| {
            if (monotonicNs() > deadline) noteTerm(iso, .deadline);
        }
    }

    fn rejectPending(iso: *IsolateState, ignore_gas: bool) !void {
        syncOomCause(iso);
        iso.pollDeadline();
        var bits = iso.termination_bits.load(.acquire);
        if (ignore_gas) bits &= ~term_gas;
        if (selectedTermination(bits)) |kind| return terminationError(kind);
    }

    fn prepareCapabilities(iso: *IsolateState) !void {
        switch (iso.capabilities) {
            .ready => return,
            .failed => return error.CapabilityApplicationFailed,
            .pending => {},
        }

        iso.phase = .preparing;
        var complete = false;
        defer {
            iso.phase = .idle;
            if (!complete) iso.capabilities = .failed;
        }

        const attribution = alloc_mod.pushIsolate(&iso.cell);
        defer alloc_mod.restoreIsolate(attribution);
        iso.applyCapabilities() catch {
            iso.vm.clearError();
            if (currentTermination(iso)) |kind| return terminationError(kind);
            return error.CapabilityApplicationFailed;
        };
        if (currentTermination(iso)) |kind| return terminationError(kind);
        iso.capabilities = .ready;
        complete = true;
    }

    fn finishExecution(iso: *IsolateState) void {
        if (iso.gas_meter) |*meter| {
            iso.last_gas = meter.snapshot();
            if (meter.scope == .execution) {
                meter.finishGeneration();
                _ = iso.termination_bits.fetchAnd(~term_gas, .acq_rel);
                iso.clearGasDelivery();
            }
        }
        iso.phase = .idle;
    }

    /// Commit the next `.per_execution` allowance: forgive a sticky
    /// exhaustion from the finished generation, then install the fresh
    /// meter state.
    fn renewExecutionGas(iso: *IsolateState) !void {
        const candidate = iso.gas_meter.?.nextGeneration();
        _ = iso.termination_bits.fetchAnd(~term_gas, .acq_rel);
        try iso.rejectPending(true);
        iso.gas_meter = candidate;
        iso.gas_remaining = candidate.remaining;
        iso.clearGasDelivery();
    }

    fn clearGasDelivery(iso: *IsolateState) void {
        iso.handler_grace = 0;
        iso.grace_armed = false;
        iso.raise_pending = false;
        iso.uncovered_waits = 0;
    }

    /// The inert exception metadata behind the last failed outer
    /// `run`/`runImage`/`call` (ordinary script errors only; policy
    /// terminations are distinct Zig errors). Reading it executes no guest
    /// methods or bytecodes. Valid only until the next outer entry, including
    /// one rejected during preflight.
    pub fn lastError(iso: *IsolateState) ?RubyError {
        if (c.mrz_nil_p(iso.last_exc)) return null;
        return RubyError.fromInert(
            iso.vm.mrb,
            iso.last_exc,
            iso.error_message,
            iso.error_class,
        );
    }

    /// Read a global variable between executions (`name` excludes the `$`),
    /// under the same operation lock as guest execution. The returned
    /// `Value` follows ordinary rooting rules: consume it inside an arena
    /// `Scope` or `Vm.root` it if it must outlive further execution.
    pub fn getGlobal(iso: *IsolateState, name: []const u8) !Value {
        return iso.hostOperation(.attributed, Value, struct {
            fn body(iso_: *IsolateState, name_: []const u8) !Value {
                return iso_.vm.getGlobal(name_);
            }
        }.body, name);
    }

    /// Set a global variable between executions; values from another
    /// interpreter are rejected as `error.ForeignValue`.
    pub fn setGlobal(iso: *IsolateState, name: []const u8, val: Value) !void {
        return iso.hostOperation(.attributed, void, struct {
            fn body(iso_: *IsolateState, ctx: anytype) !void {
                return iso_.vm.setGlobal(ctx.name, ctx.val);
            }
        }.body, .{ .name = name, .val = val });
    }

    /// Discard the pending Ruby exception and the retained `lastError`
    /// view. Ordinary flows do not need this — the next outer entry resets
    /// both — but it lets a host drop a diagnostic it has already read.
    pub fn clearError(iso: *IsolateState) !void {
        return iso.hostOperation(.lock_only, void, struct {
            fn body(iso_: *IsolateState, _: void) !void {
                iso_.clearErrorView();
                iso_.vm.clearError();
            }
        }.body, {});
    }

    fn clearErrorView(iso: *IsolateState) void {
        _ = c.mrz_error_release(iso.vm.mrb, iso.error_root);
        iso.last_exc = c.mrz_nil_value();
        iso.error_message = c.mrz_nil_value();
        iso.error_class = c.mrz_nil_value();
    }

    fn captureErrorView(iso: *IsolateState) void {
        const exc = c.mrz_exc_value(iso.vm.mrb);
        var metadata: c.mrz_exception_metadata = undefined;
        if (c.mrz_error_capture(iso.vm.mrb, iso.error_root, exc, &metadata)) {
            iso.last_exc = exc;
            iso.error_class = metadata.class_name;
            iso.error_message = metadata.message;
        } else {
            iso.last_exc = c.mrz_nil_value();
        }
        c.mrz_exc_clear(iso.vm.mrb);
    }

    /// Map a failed run to a distinct Zig error. Policy terminations are
    /// classified **only** by the authoritative termination-cause bitset the
    /// hook sets (and the memory-cap flags), never by the raised
    /// exception's class name: the `MRubyZigSandbox::*` classes are
    /// script-visible and a script can `raise` them (or spoof their `to_s`),
    /// so trusting the name would let a script forge a termination the host
    /// then acts on. `raiseTerm` always calls `noteTerm` before raising, so a
    /// genuine termination is fully covered by the flag check below.
    fn mapError(iso: *IsolateState, err: anyerror) anyerror {
        if (err != error.RubyException) return err;
        iso.pollDeadline();
        if (currentTermination(iso)) |kind| {
            c.mrz_exc_clear(iso.vm.mrb);
            return terminationError(kind);
        }
        iso.captureErrorView();
        iso.pollDeadline();
        if (currentTermination(iso)) |kind| {
            iso.clearErrorView();
            return terminationError(kind);
        }
        return err;
    }

    fn terminationError(kind: TerminationKind) anyerror {
        return switch (kind) {
            .script => error.ScriptTerminated,
            .deadline => error.DeadlineExceeded,
            .gas => error.GasExhausted,
            .memory => error.MemoryLimitExceeded,
            .call_depth => error.CallDepthExceeded,
        };
    }

    fn allocatorLimit(ctx: ?*anyopaque, kind: alloc_mod.IsolateCell.LimitKind, attempted: usize) void {
        _ = kind;
        _ = attempted;
        const iso: *IsolateState = @ptrCast(@alignCast(ctx orelse return));
        noteTerm(iso, .memory);
    }

    fn applyCapabilities(iso: *IsolateState) !void {
        const caps = iso.resolved_caps;
        const m = iso.vm.mrb;

        for (authority.restricted_methods) |restriction| {
            if (capabilityGranted(caps, restriction.gate)) continue;
            const owner = iso.vm.getClass(restriction.owner) catch |err| switch (err) {
                error.UnknownClass => continue,
                else => return err,
            };
            try maskMethod(owner, restriction.name, restriction.kind);
        }
        for (authority.restricted_constants) |restriction| {
            if (capabilityGranted(caps, restriction.gate)) continue;
            const owner = try iso.vm.getClass(restriction.owner);
            var found = false;
            var ignored: c.mrb_value = undefined;
            if (!c.mrz_protected_const_get(
                m,
                owner.class,
                restriction.name.ptr,
                restriction.name.len,
                &found,
                &ignored,
            )) return error.RubyException;
            if (!found) continue;
            if (!c.mrz_protected_remove_const(
                m,
                owner.class,
                restriction.name.ptr,
                restriction.name.len,
            )) return error.RubyException;
        }
        if (caps.random_seed) |seed| {
            const upstream_seed: u32 = @truncate(seed);
            // Fail loudly (prepare maps this to CapabilityApplicationFailed) if
            // mruby-random is absent: silently skipping srand would leave the
            // isolate non-deterministic while the host believes the pin applied.
            const reseed = iso.random_srand orelse return error.RubyException;
            if (!c.mrz_protected_random_seed(m, reseed, upstream_seed))
                return error.RubyException;
            try maskMethods(iso, &authority.random_reseed_methods);
        }
        if (caps.clock_epoch_s) |epoch| {
            try iso.installFrozenClock(epoch);
            try maskMethods(iso, &authority.clock_read_methods);
        }
        // Policy pinning must not restore an ambient entry point that the
        // effect installation masks. Reapply its masks before model sealing.
        if (iso.vm.effects) |effects| try effects.hardenAmbient();
        if (caps.freeze_object_model) try iso.sealModel();

        // The sandbox's own module is a script-visible constant (scripts may
        // read MRubyZigSandbox::FROZEN_TIME). Freeze it so a script cannot
        // reassign or remove its constants (e.g. repoint FROZEN_TIME to defeat
        // the clock pin) or reopen it to add methods: mrb_check_frozen guards
        // const-set, const-remove, and method definition on a frozen module.
        if (!c.mrz_protected_freeze(
            m,
            c.mrz_obj_value(@ptrCast(iso.hidden)),
        )) return error.RubyException;
    }

    /// Freeze the core object model so `def`/`include`/const changes on
    /// these raise FrozenError. The immediate-value singletons
    /// (NilClass/TrueClass/FalseClass), Numeric, and the core Exception
    /// hierarchy are included: omitting them left a script able to reopen
    /// e.g. `class NilClass` under a supposedly frozen model. Classes
    /// absent from a trimmed gem set are skipped (catch continue).
    ///
    /// This is the same list and operation the `freeze_object_model`
    /// capability applies at the first run; exposed as a public method so
    /// hosts can seal at a time of their choosing -- the two-phase form.
    /// The canonical consumer loads a script image on the unfrozen model
    /// (so its top-level `class` definitions land) and calls this right
    /// after, giving every later run a frozen model with load-time
    /// definitions intact. Idempotent: `mrb_obj_freeze` on an
    /// already-frozen class is a no-op, so a host may also combine both
    /// phases defensively.
    pub fn sealModel(iso: *IsolateState) !void {
        const m = iso.vm.mrb;
        for (authority.frozen_classes) |name| {
            const cls = iso.vm.getClass(name) catch |err| switch (err) {
                error.UnknownClass => continue,
                else => return err,
            };
            if (!c.mrz_protected_freeze(
                m,
                cls.asValue().v,
            )) return error.RubyException;
        }
    }

    fn maskMethod(
        cls: anytype,
        name: []const u8,
        kind: authority.MethodKind,
    ) !void {
        if (!c.mrz_protected_mask_method(
            cls.mrb,
            cls.class,
            name.ptr,
            name.len,
            switch (kind) {
                .instance => c.MRZ_MASK_INSTANCE,
                .class => c.MRZ_MASK_CLASS,
            },
        )) return error.RubyException;
    }

    fn maskMethods(
        iso: *IsolateState,
        restrictions: []const authority.DeterminismMethod,
    ) !void {
        for (restrictions) |restriction| {
            const owner = iso.vm.getClass(restriction.owner) catch |err| switch (err) {
                error.UnknownClass => continue,
                else => return err,
            };
            try maskMethod(owner, restriction.name, restriction.kind);
        }
    }

    fn capabilityGranted(caps: Capabilities, gate: authority.PolicyGate) bool {
        return switch (gate) {
            .eval => caps.eval,
            .send => caps.send,
            .introspection => caps.introspection,
            .object_space => caps.object_space,
        };
    }

    fn installFrozenClock(iso: *IsolateState, epoch: i64) !void {
        const m = iso.vm.mrb;
        const time = try iso.vm.getClass("Time");
        // Build Time.at(epoch) via funcall and root it as a constant on the
        // hidden module (mruby has no Ruby-level scoped const assignment).
        const frozen = try iso.vm.call(time.asValue(), "at", .{epoch});
        if (!c.mrz_protected_define_const(
            m,
            iso.hidden,
            "FROZEN_TIME",
            "FROZEN_TIME".len,
            frozen.v,
        )) return error.RubyException;
        iso.frozen_time = frozen.v;
        // Replace Time.now with a Zig class method returning the cached
        // constant (built once, so all calls return the same object).
        const Clock = struct {
            fn now(mrb: ?*c.mrb_state, self: c.mrb_value) callconv(.c) c.mrb_value {
                _ = self;
                const mm = mrb orelse return c.mrz_nil_value();
                const active: *IsolateState =
                    @ptrCast(@alignCast(c.mrz_get_ud(mm) orelse return c.mrz_nil_value()));
                return active.frozen_time;
            }
        };
        if (!c.mrz_protected_mask_method(
            m,
            time.class,
            "now",
            "now".len,
            c.MRZ_MASK_CLASS,
        )) return error.RubyException;
        if (!c.mrz_protected_define_method(
            m,
            time.class,
            "now",
            "now".len,
            Clock.now,
            c.MRB_ARGS_NONE,
            c.MRZ_METHOD_CLASS,
        )) return error.RubyException;
    }

    // ---- the instruction hook ----------------------------------------------

    fn fetchHook(
        mrb: ?*c.mrb_state,
        irep: ?*const anyopaque,
        pc: ?*const anyopaque,
        regs: ?*anyopaque,
    ) callconv(.c) c.mrb_value {
        _ = regs;
        const m = mrb orelse return c.mrz_nil_value();
        const iso: *IsolateState =
            @ptrCast(@alignCast(c.mrz_get_ud(m) orelse return c.mrz_nil_value()));

        iso.instr_count +|= 1;

        // Record limit conditions (idempotent flags).
        syncOomCause(iso);
        if (iso.gas_meter) |*meter| {
            if (meter.observeFetch()) noteTerm(iso, .gas);
        }
        if (iso.call_depth_limit) |maxd| {
            const depth = c.mrz_ci_depth(m);
            if (depth > 0) {
                const d: u32 = @intCast(depth);
                if (d > iso.peak_call_depth) iso.peak_call_depth = d;
                if (d > maxd) noteTerm(iso, .call_depth);
            }
        }

        // Deliver an armed termination raise only where it can be caught
        // (so ensure/rescue machinery runs); pc coverage excludes a
        // region's first instruction, and hook-time pc precedes execution.
        // A bounded wait covers loops that never reach a covered offset
        // (e.g. an empty `while true; end` is a jump-to-self at the region
        // start) — after it expires, termination is forced uncatchably.
        if (iso.raise_pending and c.mrz_nil_p(c.mrz_exc_value(m)) and iso.handler_grace == 0) {
            if (c.mrz_pc_catchable(irep, pc) != 0 or iso.uncovered_waits >= uncovered_wait_limit) {
                iso.raise_pending = false;
                iso.uncovered_waits = 0;
                if (currentTermination(iso)) |kind|
                    return terminationException(iso, kind);
                iso.raise_pending = false;
            } else {
                iso.uncovered_waits += 1;
            }
        }

        // Enforce any pending termination. While the VM is unwinding
        // (mrb->exc set) propagation continues naturally. Handler bodies
        // (rescue/ensure) run with exc cleared by OP_EXCEPT, so they draw
        // from a bounded grace budget; once exhausted — or when normal
        // code resumes after a rescue — termination re-raises. Scripts
        // cannot rescue their way out; ensure blocks complete.
        //
        if (currentTermination(iso) != null) {
            const unwinding = !c.mrz_nil_p(c.mrz_exc_value(m));
            if (!unwinding) {
                if (iso.handler_grace > 0) {
                    iso.handler_grace -= 1;
                } else {
                    iso.raise_pending = true;
                }
            }
            if (iso.cell.hardOom())
                return c.mrz_nil_value(); // no gas/step accounting needed
        }

        // Step the counters.
        if (iso.gas_meter) |*meter| {
            meter.chargeFetch();
            iso.gas_remaining = meter.remaining;
        }

        // Deadline, batched independently of the saturating public lifetime
        // counter so polling cannot stop at maxInt(u64).
        if (iso.clock_countdown > 1) {
            iso.clock_countdown -= 1;
        } else {
            iso.clock_countdown = clock_batch;
            iso.pollDeadline();
        }
        return c.mrz_nil_value();
    }

    fn noteTerm(iso: *IsolateState, kind: TerminationKind) void {
        _ = iso.termination_bits.fetchOr(terminationBit(kind), .release);
    }

    fn terminationBit(kind: TerminationKind) u8 {
        return switch (kind) {
            .script => term_script,
            .deadline => term_deadline,
            .gas => term_gas,
            .memory => term_memory,
            .call_depth => term_call_depth,
        };
    }

    fn selectedTermination(bits: u8) ?TerminationKind {
        if (bits & term_memory != 0) return .memory;
        if (bits & term_script != 0) return .script;
        if (bits & term_deadline != 0) return .deadline;
        if (bits & term_call_depth != 0) return .call_depth;
        if (bits & term_gas != 0) return .gas;
        return null;
    }

    fn syncOomCause(iso: *IsolateState) void {
        if (iso.cell.anyOom()) noteTerm(iso, .memory);
    }

    fn currentTermination(iso: *IsolateState) ?TerminationKind {
        syncOomCause(iso);
        return selectedTermination(iso.termination_bits.load(.acquire));
    }

    fn terminationException(iso: *IsolateState, kind: TerminationKind) c.mrb_value {
        noteTerm(iso, kind);
        if (!iso.grace_armed) {
            iso.handler_grace = handler_grace_instructions;
            iso.grace_armed = true;
        }
        return c.mrb_ary_entry(iso.policy_exceptions, @backingInt(kind));
    }
};

test "derived hard cap saturates at usize maximum" {
    const maximum = std.math.maxInt(usize);
    try std.testing.expectEqual(maximum, IsolateState.defaultHardCap(maximum).?);
}

const SandboxBootstrap = struct {
    hidden: *c.RClass,
    error_root: c.mrb_value,
    policy_exceptions: c.mrb_value,
    random_srand: ?c.mrb_func_t,
};

/// All sandbox-specific class/root construction can allocate and raise. The C
/// shim owns the protection frame so no mruby longjmp can cross Zig frames.
fn bootstrapSandbox(vm: *Vm) !SandboxBootstrap {
    var context: c.mrz_sandbox_bootstrap = undefined;
    if (!c.mrz_protected_sandbox_bootstrap(vm.mrb, &context))
        return error.OutOfMemory;
    return .{
        .hidden = context.hidden orelse return error.OutOfMemory,
        .error_root = context.error_root,
        .policy_exceptions = context.policy_exceptions,
        .random_srand = context.random_srand,
    };
}

test "every sandbox bootstrap allocation failure returns OutOfMemory" {
    const previous = alloc_mod.gpa;

    // First measure raw allocations made by the protected sandbox-specific
    // bootstrap. The wrapper delegates to the same backing allocator, so VM
    // teardown remains valid after restoring the direct allocator handle.
    const measure_vm = try Vm.init();
    var measure = std.testing.FailingAllocator.init(previous, .{});
    alloc_mod.gpa = measure.allocator();
    const measured = bootstrapSandbox(measure_vm);
    alloc_mod.gpa = previous;
    _ = try measured;
    const allocation_count = measure.alloc_index;
    measure_vm.deinit();

    for (0..allocation_count) |fail_index| {
        const vm = try Vm.init();
        var failing = std.testing.FailingAllocator.init(previous, .{ .fail_index = fail_index });
        alloc_mod.gpa = failing.allocator();
        const result = bootstrapSandbox(vm);
        alloc_mod.gpa = previous;
        try std.testing.expectError(error.OutOfMemory, result);
        try std.testing.expect(failing.has_induced_failure);
        vm.deinit();
    }
}

const RawRite = struct {
    ptr: [*]u8,
    len: usize,

    fn bytes(raw: RawRite) []const u8 {
        return raw.ptr[0..raw.len];
    }

    fn deinit(raw: *RawRite) void {
        mrb_free_via_allocator(raw.ptr, raw.len);
        raw.* = undefined;
    }
};

fn compileRaw(
    src: []const u8,
    source_name: ?[]const u8,
    dump_flags: u8,
) CompileRiteError!RawRite {
    if (comptime !features.has_compiler) return error.CompilerUnavailable;
    const vm = Vm.init() catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.CompileFailed,
    };
    defer vm.deinit();

    // NUL-terminate for the lexer (same discipline as Vm.loadString).
    if (std.mem.indexOfScalar(u8, src, 0) != null) return error.InvalidSource;
    const buffer_length = std.math.add(usize, src.len, 1) catch
        return error.OutOfMemory;
    const buf = try alloc_mod.gpa.alloc(u8, buffer_length);
    defer alloc_mod.gpa.free(buf);
    @memcpy(buf[0..src.len], src);
    buf[src.len] = 0;

    const name_z: ?[:0]u8 = if (source_name) |name| blk: {
        if (std.mem.indexOfScalar(u8, name, 0) != null) return error.InvalidSourceName;
        const terminated = try alloc_mod.gpa.allocSentinel(u8, name.len, 0);
        @memcpy(terminated[0..name.len], name);
        break :blk terminated;
    } else null;
    defer if (name_z) |allocated| alloc_mod.gpa.free(allocated);

    var bin: ?[*]u8 = null;
    var bin_size: usize = 0;
    const status = c.mrz_protected_compile(
        vm.mrb,
        buf.ptr,
        src.len,
        if (name_z) |name| name.ptr else null,
        dump_flags,
        &bin,
        &bin_size,
    );
    switch (status) {
        c.MRZ_COMPILE_OK => {},
        c.MRZ_COMPILE_OUT_OF_MEMORY => return error.OutOfMemory,
        else => return error.CompileFailed,
    }
    return .{ .ptr = bin orelse return error.CompileFailed, .len = bin_size };
}

/// Deprecated compatibility operation: compile `src` to unframed RITE bytes.
/// It omits mruby-zig's compatibility/application checks; use `compileRite`.
/// Runtime-only builds return `error.CompilerUnavailable`.
pub fn compile(src: []const u8) ![]u8 {
    var raw = try compileRaw(src, null, 0);
    defer raw.deinit();
    return alloc_mod.gpa.dupe(u8, raw.bytes());
}

/// Compile source into a typed, caller-owned RITE artifact.
/// Returns `CompilerUnavailable` with `-Dno-compiler`; use build-time CodeDB.
/// Runtime-only builds return `error.CompilerUnavailable`.
pub fn compileRite(
    allocator: std.mem.Allocator,
    src: []const u8,
    options: CompileRiteOptions,
) CompileRiteError!artifact_mod.RiteImage {
    var raw = try compileRaw(
        src,
        options.source_name,
        if (options.include_debug) c.MRB_DUMP_DEBUG_INFO else 0,
    );
    defer raw.deinit();

    return artifact_mod.wrapRite(allocator, raw.bytes(), .{
        .compatibility = artifact_config.rite_compatibility_fingerprint,
        .application = options.application,
        .max_encoded_bytes = std.math.maxInt(usize),
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.CompileFailed,
    };
}

fn mrb_free_via_allocator(ptr: [*]u8, size: usize) void {
    // The dump buffer was allocated through mrb_malloc (our allocator with
    // its header prefix), so free it through the same path.
    _ = alloc_mod.mrb_basic_alloc_func_pub(@ptrCast(ptr), 0);
    _ = size;
}

// ---------------------------------------------------------------------------
// public handles: the bootstrap/execution typestate
// ---------------------------------------------------------------------------

/// The execution handle: a sealed isolate. Created by
/// `BootstrapIsolate.seal()`; every operation runs under the resolved
/// policy (admission, gas, deadlines, capabilities). There is no raw `vm`
/// access here — value construction, symbols, rooting, globals, and error
/// inspection are first-class locked operations, and anything else is
/// bootstrap work that belongs before `seal()`.
pub const Isolate = struct {
    /// Internal state pointer. Touching it opts out of every guarantee;
    /// it exists so the handle can be passed and stored by value.
    internal: *IsolateState,

    pub fn deinit(iso: Isolate) void {
        iso.internal.deinit();
    }

    /// Run `src` under the policy. Policy terminations surface as distinct
    /// errors (`ScriptTerminated`, `DeadlineExceeded`, `GasExhausted`,
    /// `MemoryLimitExceeded`, `CallDepthExceeded`); ordinary script errors
    /// as `error.RubyException` (see `lastError`).
    /// Runtime-only builds return `error.CompilerUnavailable` before admission.
    pub fn run(iso: Isolate, src: []const u8) !Value {
        return iso.internal.run(src);
    }

    /// Deprecated compatibility operation: run an unframed snapshot (no
    /// compatibility or application checks). Use `runRite`.
    pub fn runImage(iso: Isolate, image: []const u8) !Value {
        return iso.internal.runImage(image);
    }

    /// Validate and execute a typed RITE image.
    pub fn runRite(iso: Isolate, image: artifact_mod.RiteImageView) RunRiteError!Value {
        return iso.internal.runRite(image);
    }

    /// Look up and execute a build-compiled CodeDB entry. Generated manifest
    /// schema/build identity is checked at compile time; each execution still
    /// validates its envelope, application identity, and policy limits.
    /// An unknown name returns `error.UnknownArtifact` without entering Ruby.
    pub fn runArtifact(
        iso: Isolate,
        comptime manifest: type,
        name: []const u8,
    ) @import("codedb.zig").RunError!Value {
        return @import("codedb.zig").run(iso, manifest, name);
    }

    /// Initialize a CodeDB entrypoint and its dependencies once. All modules
    /// in this call share the policy's execution allowance. Returns false for
    /// an already-loaded entrypoint. Failed initialization poisons this
    /// isolate's loader; it cannot be reset or rebound to another manifest.
    pub fn loadArtifact(
        iso: Isolate,
        comptime manifest: type,
        name: []const u8,
    ) codedb_mod.LoadError!bool {
        return codedb_mod.load(iso, manifest, name);
    }

    /// Call a Ruby method under the policy (same error mapping as `run`).
    pub fn call(iso: Isolate, recv: Value, name: []const u8, args: anytype) !Value {
        return iso.internal.call(recv, name, args);
    }

    /// Call an identified Ruby method in live, recording, or replay mode.
    /// Positional arguments are snapshotted as bounded inert values: Ruby sees
    /// private copies, preserving aliasing within the argument graph. No block
    /// is accepted. The host must identify the complete code, bootstrap, and
    /// starting receiver/handler state; the runtime binds the actual method and
    /// arguments. Nested identified calls are rejected before execution.
    pub fn callWithEffects(
        iso: Isolate,
        recv: Value,
        name: []const u8,
        args: anytype,
        invocation: effect_mod.Invocation,
    ) !Value {
        return iso.internal.callWithEffects(recv, name, args, invocation);
    }

    /// Call a Ruby method with options (block argument), under the policy.
    pub fn callWithOptions(
        iso: Isolate,
        recv: Value,
        name: []const u8,
        args: anytype,
        options: vm_mod.CallOptions,
    ) !Value {
        return iso.internal.enterExecution(struct {
            fn body(iso_: *IsolateState, ctx: anytype) !Value {
                return iso_.vm.callWithOptions(ctx.recv, ctx.name, ctx.args, ctx.options);
            }
        }.body, .{ .recv = recv, .name = name, .args = args, .options = options }, null);
    }

    /// Transfer the most recent effect trace to the host without entering Ruby.
    /// The caller owns the returned trace and must deinitialize it. Recording
    /// and replay require an identified outer entry: `run`, `runImage`,
    /// `runRite`, or `callWithEffects`. Ordinary calls and load-once CodeDB
    /// initialization do not supply the required identities.
    pub fn takeEffectTrace(iso: Isolate) !effect_mod.Trace {
        return iso.internal.hostOperation(.lock_only, effect_mod.Trace, struct {
            fn body(state: *IsolateState, _: void) !effect_mod.Trace {
                const effects = state.vm.effects orelse return error.EffectNotInstalled;
                return effects.takeTrace();
            }
        }.body, {});
    }

    /// Copy the most recent effect diagnostic without entering Ruby. The
    /// returned value owns its operation labels and survives later executions.
    pub fn effectDiagnostic(iso: Isolate) !?effect_mod.Diagnostic {
        return iso.internal.hostOperation(.lock_only, ?effect_mod.Diagnostic, struct {
            fn body(state: *IsolateState, _: void) !?effect_mod.Diagnostic {
                const effects = state.vm.effects orelse return error.EffectNotInstalled;
                return effects.diagnostic();
            }
        }.body, {});
    }

    /// Owned native admission diagnostic; absent in compatibility builds.
    pub fn nativeDiagnostic(iso: Isolate) !?c.StrictDiagnostic {
        return iso.internal.hostOperation(.lock_only, ?c.StrictDiagnostic, struct {
            fn body(state: *IsolateState, _: void) !?c.StrictDiagnostic {
                return state.nativeViolation();
            }
        }.body, {});
    }

    /// Host lookup with allocator attribution and serialized VM access.
    pub fn classValue(iso: Isolate, name: []const u8) !Value {
        return iso.internal.hostOperation(.attributed, Value, struct {
            fn body(state: *IsolateState, class_name: []const u8) !Value {
                return (try state.vm.getClass(class_name)).asValue();
            }
        }.body, name);
    }

    /// Finish the definition phase without exposing the raw VM.
    pub fn sealModel(iso: Isolate) !void {
        return iso.internal.hostOperation(.attributed, void, struct {
            fn body(state: *IsolateState, _: void) !void {
                try state.sealModel();
            }
        }.body, {});
    }

    /// Export a bounded, inert Ruby value graph. The returned bytes are
    /// owned by `allocator`; release them with `capsule.deinit(allocator)`.
    pub fn exportValue(
        iso: Isolate,
        allocator: std.mem.Allocator,
        root_value: Value,
        options: ExportValueOptions,
    ) ExportValueError!artifact_mod.StateCapsule {
        return iso.internal.exportValue(allocator, root_value, options);
    }

    /// Import a state capsule under the isolate's artifact acceptance.
    pub fn importValue(
        iso: Isolate,
        capsule: artifact_mod.StateCapsuleView,
        options: ImportValueOptions,
    ) ImportValueError!Value {
        return iso.internal.importValue(capsule, options);
    }

    /// The typed diagnostic behind the last rejected artifact operation,
    /// if any (see `mruby.artifact`).
    pub fn lastArtifactError(iso: Isolate) ?ArtifactDiagnostic {
        return iso.internal.lastArtifactError();
    }

    /// Request termination from any thread; observed at the next bytecode
    /// fetch with guaranteed `ensure` unwinding.
    pub fn terminate(iso: Isolate) void {
        iso.internal.terminate();
    }

    pub fn pendingTermination(iso: Isolate) bool {
        return iso.internal.pendingTermination();
    }

    pub fn stats(iso: Isolate) Stats {
        return iso.internal.stats();
    }

    /// The inert exception metadata behind the last failed outer
    /// execution (ordinary script errors only). Valid only until the next
    /// outer entry.
    pub fn lastError(iso: Isolate) ?RubyError {
        return iso.internal.lastError();
    }

    /// Read a global variable between executions (`name` excludes `$`).
    pub fn getGlobal(iso: Isolate, name: []const u8) !Value {
        return iso.internal.getGlobal(name);
    }

    /// Set a global variable between executions; foreign values rejected.
    pub fn setGlobal(iso: Isolate, name: []const u8, val: Value) !void {
        return iso.internal.setGlobal(name, val);
    }

    /// Discard the pending Ruby exception and the retained `lastError` view.
    pub fn clearError(iso: Isolate) !void {
        return iso.internal.clearError();
    }

    // ---- value construction (locked delegations) -------------------------

    /// Construct an Integer; out-of-range values return `error.Overflow`.
    pub fn intValue(iso: Isolate, x: anytype) !Value {
        return iso.internal.hostOperation(.attributed, Value, struct {
            fn body(iso_: *IsolateState, x_: anytype) !Value {
                return iso_.vm.intValue(x_);
            }
        }.body, x);
    }

    /// Construct an Integer, clamping out-of-range values.
    pub fn saturatingIntValue(iso: Isolate, x: anytype) !Value {
        return iso.internal.hostOperation(.attributed, Value, struct {
            fn body(iso_: *IsolateState, x_: anytype) !Value {
                return iso_.vm.saturatingIntValue(x_);
            }
        }.body, x);
    }

    /// Construct a Float; non-finite or destination-overflow values return
    /// `error.Overflow`.
    pub fn floatValue(iso: Isolate, x: f64) !Value {
        return iso.internal.hostOperation(.attributed, Value, struct {
            fn body(iso_: *IsolateState, x_: f64) !Value {
                return iso_.vm.floatValue(x_);
            }
        }.body, x);
    }

    /// Construct a String (no allocation failure swallowing).
    pub fn stringValue(iso: Isolate, s: []const u8) !Value {
        return iso.internal.hostOperation(.attributed, Value, struct {
            fn body(iso_: *IsolateState, s_: []const u8) !Value {
                return iso_.vm.stringValue(s_);
            }
        }.body, s);
    }

    /// Construct a Boolean (immediate; cannot fail).
    pub fn boolValue(iso: Isolate, x: bool) Value {
        return iso.internal.vm.boolValue(x);
    }

    /// Construct nil (immediate; cannot fail).
    pub fn nilValue(iso: Isolate) Value {
        return iso.internal.vm.nilValue();
    }

    /// Construct an Array from same-VM values.
    pub fn array(iso: Isolate, values: []const Value) !Array {
        return iso.internal.hostOperation(.attributed, Array, struct {
            fn body(iso_: *IsolateState, values_: []const Value) !Array {
                return iso_.vm.array(values_);
            }
        }.body, values);
    }

    /// Construct a Hash from same-VM entries.
    pub fn hash(iso: Isolate, entries: []const HashEntry) !Hash {
        return iso.internal.hostOperation(.attributed, Hash, struct {
            fn body(iso_: *IsolateState, entries_: []const HashEntry) !Hash {
                return iso_.vm.hash(entries_);
            }
        }.body, entries);
    }

    // ---- symbols and rooting ----------------------------------------------

    /// Intern a symbol name (allocating; serialized with execution).
    pub fn internSymbol(iso: Isolate, name: []const u8) !u32 {
        return iso.internal.hostOperation(.attributed, u32, struct {
            fn body(iso_: *IsolateState, name_: []const u8) !u32 {
                return iso_.vm.internSymbol(name_);
            }
        }.body, name);
    }

    /// Borrowed symbol name (no allocation; same-thread use only).
    pub fn symbolName(iso: Isolate, sym: u32) []const u8 {
        return iso.internal.vm.symbolName(sym);
    }

    /// Keep `value` alive independently of the GC arena until the returned
    /// root is destroyed. Roots must be destroyed before this Isolate.
    pub fn root(iso: Isolate, value: Value) RootError!RootedValue {
        return iso.internal.hostOperation(.attributed, RootedValue, struct {
            fn body(iso_: *IsolateState, value_: Value) arena_mod.RootError!RootedValue {
                return iso_.vm.root(value_);
            }
        }.body, value) catch |err| return @errorCast(err);
    }

    /// Save the GC arena index; same-thread use only, like the raw layer.
    pub fn arenaScope(iso: Isolate) arena_mod.Scope {
        return iso.internal.vm.arenaScope();
    }
};

/// The bootstrap handle: the window between allocation and sealing where
/// the host owns the raw `Vm` — defining classes and methods, loading
/// definition-time code, applying a model freeze. `seal()` consumes it and
/// returns the execution `Isolate`; using a bootstrap handle after a
/// successful seal (other than `deinit`, which becomes a no-op) is out of
/// contract.
pub const BootstrapIsolate = struct {
    state: ?*IsolateState = null,

    /// Spawn an isolate with a policy. The policy is resolved completely at
    /// spawn (gas scope, memory caps, wall budget, call-depth ceiling,
    /// capability snapshot, artifact acceptance) and never changes
    /// afterwards. Register host methods on `vm` before `seal()` when
    /// freezing the object model.
    pub fn spawn(policy: Policy) !BootstrapIsolate {
        return .{ .state = try IsolateState.create(policy) };
    }

    /// The raw `Vm` for the bootstrap window: trusted host access that
    /// bypasses admission, gas, and capabilities. Out of contract after
    /// `seal()`.
    pub fn vm(boot: BootstrapIsolate) *Vm {
        const state = boot.state orelse @panic("bootstrap handle already sealed");
        return state.vm;
    }

    /// End the bootstrap window: apply the policy's capabilities through
    /// the same preflight bracket as an execution (admission, deadline
    /// start, pending termination; setup gas is charged to the current
    /// generation exactly as it would be inside a first run) and return
    /// the execution handle. Consumes this handle; `deinit` becomes a
    /// no-op so `defer boot.deinit()` alongside `defer iso.deinit()` is
    /// always safe. On failure the bootstrap handle remains usable for
    /// `deinit` and the failure is terminal for the state.
    pub fn seal(boot: *BootstrapIsolate) !Isolate {
        const state = boot.state orelse return error.BootstrapHandleConsumed;
        boot.sealState(state) catch |err| {
            return err;
        };
        boot.state = null;
        return .{ .internal = state };
    }

    fn sealState(boot: *BootstrapIsolate, state: *IsolateState) !void {
        _ = boot;
        try state.seal();
    }

    /// Freeze the core object model during bootstrap (the two-phase form
    /// of the `freeze_object_model` capability): load definitions on the
    /// unfrozen model via `vm`, call this, then `seal`. Idempotent.
    pub fn sealModel(boot: BootstrapIsolate) !void {
        const state = boot.state orelse @panic("bootstrap handle already sealed");
        return state.sealModel();
    }

    /// Destroy the isolate if it has not been sealed; a no-op after a
    /// successful `seal()` (the returned `Isolate` owns the state).
    pub fn deinit(boot: *BootstrapIsolate) void {
        const state = boot.state orelse return;
        state.deinit();
        boot.state = null;
    }
};

/// Test-build-only raw VM access for diagnostics (GC forcing, allocator
/// probing). Compiled out of library builds; use the public surface
/// otherwise.
pub fn internalVm(iso: Isolate) *Vm {
    if (!@import("builtin").is_test) @compileError("sandbox.internalVm is test-build only");
    return iso.internal.vm;
}
