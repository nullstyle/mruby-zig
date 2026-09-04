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
//! Out-of-process isolates (worker processes with IPC, OS-level memory
//! separation) are a planned follow-up tier; the in-process API here is
//! designed to front it unchanged.

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

pub const Vm = vm_mod.Vm;
pub const Value = value_mod.Value;
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
    CompileFailed,
    InvalidSource,
    InvalidSourceName,
};

pub const RunRiteError = artifact_mod.RiteValidationError || error{
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
    /// instance_variable_* / methods / method / singleton_methods.
    /// Denied by default.
    introspection: bool = false,
    /// The ObjectSpace module. Denied by default.
    object_space: bool = false,
    /// Freeze core classes: later `def`/`include` on them raises
    /// FrozenError. Apply after registering host methods.
    freeze_object_model: bool = false,
    /// Seed the RNG for reproducible `rand` sequences (mruby-random).
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

pub const Isolate = struct {
    /// Trusted-bootstrap escape hatch: direct access to the underlying `Vm`
    /// bypasses admission, gas, deadlines, and capability state. Intended for
    /// the bootstrap window — defining host classes and methods — which ends
    /// at `seal()` (explicitly or at the first execution).
    vm: *Vm,
    /// Spawn-time resolution of `Policy`. The Isolate never consults a
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

    /// Spawn an isolate with a policy. The policy is resolved completely at
    /// spawn (gas scope, memory caps, wall budget, call-depth ceiling,
    /// capability snapshot, artifact acceptance); the Isolate retains no
    /// mutable policy. Capabilities apply lazily on the first
    /// `run`/`call`, or eagerly via `seal` — register host methods on
    /// `iso.vm` before then when freezing.
    pub fn spawn(policy: Policy) !*Isolate {
        const resolved_gas = try resolveGas(policy.limits);
        const initial_meter = gas_mod.Meter.init(resolved_gas);

        // Allocate the stable owner cell before mruby. Allocation headers keep
        // this address so frees/reallocs remain attributable after bootstrap.
        const iso = try alloc_mod.gpa.create(Isolate);
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

    pub fn deinit(iso: *Isolate) void {
        iso.clearArtifactDiagnostic();
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
    pub fn run(iso: *Isolate, src: []const u8) !Value {
        return iso.enterExecution(struct {
            fn body(iso_: *Isolate, src_: []const u8) !Value {
                return iso_.vm.loadString(src_);
            }
        }.body, src);
    }

    /// Deprecated compatibility operation: run an unframed snapshot produced
    /// by `compile` (no compatibility or application checks). Use `runRite`.
    pub fn runImage(iso: *Isolate, image: []const u8) !Value {
        return iso.enterExecution(struct {
            fn body(iso_: *Isolate, image_: []const u8) !Value {
                // loadIrep's C trampoline runs under mrb_protect_error and
                // checks mrb->exc, so a raising image surfaces as
                // error.RubyException (mapped to a termination error when a
                // limit fired) instead of returning the exception as a success
                // value and poisoning the next run.
                return iso_.vm.loadIrep(image_);
            }
        }.body, image);
    }

    /// Validate and execute a typed RITE image. Framing and compatibility
    /// failures occur before the execution lifecycle mutates Isolate state.
    pub fn runRite(
        iso: *Isolate,
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
            fn load(iso_: *Isolate, bytes: []const u8) !Value {
                return iso_.vm.loadIrep(bytes);
            }
        };
        if (admission == .nested) {
            return Body.load(iso, payload.bytes) catch |err| return @errorCast(err);
        }
        return iso.enterOuterExecution(Body.load, payload.bytes) catch |err|
            return @errorCast(err);
    }

    /// Call a Ruby method under the policy (same error mapping as `run`).
    pub fn call(iso: *Isolate, recv: Value, name: []const u8, args: anytype) !Value {
        return iso.enterExecution(struct {
            fn body(iso_: *Isolate, ctx: anytype) !Value {
                return iso_.vm.call(ctx.recv, ctx.name, ctx.args);
            }
        }.body, .{ .recv = recv, .name = name, .args = args });
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
    pub fn seal(iso: *Isolate) !void {
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
        iso: *Isolate,
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
    /// this Isolate. Process scratch is freed before return; a successful heap
    /// result retains exactly one mruby arena root.
    pub fn importValue(
        iso: *Isolate,
        capsule: artifact_mod.StateCapsuleView,
        options: ImportValueOptions,
    ) ImportValueError!Value {
        try iso.beginArtifactOperation();
        defer iso.endArtifactOperation();

        const limits = iso.artifact_acceptance.limits.capsule.tightened(options.limits);
        var failure: artifact_value.Failure = .{};
        var graph = artifact_value.parse(alloc_mod.gpa, capsule, .{
            .limits = limits,
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
    pub fn terminate(iso: *Isolate) void {
        noteTerm(iso, .script);
    }

    /// True while any termination cause is recorded. Sticky causes remain true
    /// after observation; renewable per-execution gas clears only after the
    /// outer unwind completes. Host callbacks can poll this to cooperatively
    /// unwind for an external or already-recorded cause.
    pub fn pendingTermination(iso: *Isolate) bool {
        return iso.termination_bits.load(.acquire) != 0 or iso.cell.anyOom();
    }

    /// Details for the most recent admitted StateCapsule export/import
    /// failure. Borrowed slices remain valid until the next admitted value
    /// artifact operation or Isolate destruction.
    pub fn lastArtifactError(iso: *const Isolate) ?ArtifactDiagnostic {
        return iso.artifact_diagnostic;
    }

    pub fn stats(iso: *Isolate) Stats {
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

    fn clearArtifactDiagnostic(iso: *Isolate) void {
        if (iso.artifact_path) |path| alloc_mod.gpa.free(path);
        iso.artifact_path = null;
        iso.artifact_diagnostic = null;
    }

    fn setArtifactDiagnostic(
        iso: *Isolate,
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
        iso: *Isolate,
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
            error.SchemaMismatch => .schema_mismatch,
            error.ArtifactConstructionFailed => .construction_failed,
            else => null,
        };
    }

    fn beginArtifactOperation(iso: *Isolate) !void {
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
        iso.clearArtifactDiagnostic();
    }

    fn endArtifactOperation(iso: *Isolate) void {
        std.debug.assert(iso.phase == .preparing);
        iso.phase = .idle;
        iso.operation_lock.unlock();
    }

    fn admitExecution(iso: *Isolate) !ExecutionAdmission {
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

    fn enterExecution(iso: *Isolate, comptime body: anytype, ctx: anytype) !Value {
        const admission = try iso.admitExecution();
        if (admission == .nested) return body(iso, ctx);
        defer iso.operation_lock.unlock();
        return iso.enterOuterExecution(body, ctx);
    }

    fn enterOuterExecution(iso: *Isolate, comptime body: anytype, ctx: anytype) !Value {
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

    fn startTiming(iso: *Isolate) void {
        if (iso.start_ns != 0) return;
        iso.start_ns = monotonicNs();
        if (iso.wall_budget_ns) |budget| {
            iso.deadline_ns = iso.start_ns + @as(i128, @intCast(budget));
        }
    }

    fn updateElapsed(iso: *Isolate) void {
        iso.elapsed_ns = @intCast(@max(0, monotonicNs() - iso.start_ns));
    }

    fn pollDeadline(iso: *Isolate) void {
        if (iso.deadline_ns) |deadline| {
            if (monotonicNs() > deadline) noteTerm(iso, .deadline);
        }
    }

    fn rejectPending(iso: *Isolate, ignore_gas: bool) !void {
        syncOomCause(iso);
        iso.pollDeadline();
        var bits = iso.termination_bits.load(.acquire);
        if (ignore_gas) bits &= ~term_gas;
        if (selectedTermination(bits)) |kind| return terminationError(kind);
    }

    fn prepareCapabilities(iso: *Isolate) !void {
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

    fn finishExecution(iso: *Isolate) void {
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
    fn renewExecutionGas(iso: *Isolate) !void {
        const candidate = iso.gas_meter.?.nextGeneration();
        _ = iso.termination_bits.fetchAnd(~term_gas, .acq_rel);
        try iso.rejectPending(true);
        iso.gas_meter = candidate;
        iso.gas_remaining = candidate.remaining;
        iso.clearGasDelivery();
    }

    fn clearGasDelivery(iso: *Isolate) void {
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
    pub fn lastError(iso: *Isolate) ?RubyError {
        if (c.mrz_nil_p(iso.last_exc)) return null;
        return RubyError.fromInert(
            iso.vm.mrb,
            iso.last_exc,
            iso.error_message,
            iso.error_class,
        );
    }

    fn clearErrorView(iso: *Isolate) void {
        _ = c.mrz_error_release(iso.vm.mrb, iso.error_root);
        iso.last_exc = c.mrz_nil_value();
        iso.error_message = c.mrz_nil_value();
        iso.error_class = c.mrz_nil_value();
    }

    fn captureErrorView(iso: *Isolate) void {
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
    fn mapError(iso: *Isolate, err: anyerror) anyerror {
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
        const iso: *Isolate = @ptrCast(@alignCast(ctx orelse return));
        noteTerm(iso, .memory);
    }

    fn applyCapabilities(iso: *Isolate) !void {
        const caps = iso.resolved_caps;
        const m = iso.vm.mrb;

        if (!caps.eval) {
            const kernel = try iso.vm.getClass("Kernel");
            const basic = try iso.vm.getClass("BasicObject");
            const module = try iso.vm.getClass("Module");
            try maskMethod(kernel, "eval");
            try maskMethod(kernel, "binding");
            // instance_eval/instance_exec are defined on BasicObject, not
            // Kernel; a BasicObject-receiver call (whose ancestry excludes
            // Kernel) would bypass a Kernel-only strip. Mask on both.
            try maskMethod(kernel, "instance_eval");
            try maskMethod(kernel, "instance_exec");
            try maskMethod(basic, "instance_eval");
            try maskMethod(basic, "instance_exec");
            // Module#class_eval / #module_eval accept a source string and are
            // a full string-eval escape; they live on the module class,
            // untouched by the Kernel/BasicObject strips above.
            try maskMethod(module, "class_eval");
            try maskMethod(module, "module_eval");
        }
        if (!caps.send) {
            const kernel = try iso.vm.getClass("Kernel");
            const basic = try iso.vm.getClass("BasicObject");
            try maskMethod(kernel, "send");
            try maskMethod(kernel, "public_send");
            try maskMethod(basic, "__send__");
        }
        if (!caps.introspection) {
            const kernel = try iso.vm.getClass("Kernel");
            for ([_][]const u8{
                "instance_variable_get", "instance_variable_set",
                "instance_variables",    "instance_variable_defined?",
                "methods",               "method",
                "singleton_methods",
            }) |name| try maskMethod(kernel, name);
        }
        if (!caps.object_space) {
            const present = blk: {
                _ = iso.vm.getClass("ObjectSpace") catch break :blk false;
                break :blk true;
            };
            if (present) {
                const object = try iso.vm.getClass("Object");
                if (!c.mrz_protected_remove_const(
                    m,
                    object.class,
                    "ObjectSpace",
                    "ObjectSpace".len,
                )) return error.RubyException;
            }
        }
        if (caps.random_seed) |seed| {
            var buf: [64]u8 = undefined;
            const src = std.fmt.bufPrint(&buf, "srand({d})", .{seed}) catch unreachable;
            // Fail loudly (prepare maps this to CapabilityApplicationFailed) if
            // mruby-random is absent: silently skipping srand would leave the
            // isolate non-deterministic while the host believes the pin applied.
            _ = try iso.vm.loadString(src);
        }
        if (caps.clock_epoch_s) |epoch| {
            try iso.installFrozenClock(epoch);
        }
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
    pub fn sealModel(iso: *Isolate) !void {
        const m = iso.vm.mrb;
        const frozen_classes = [_][]const u8{
            "BasicObject",       "Object",              "Module",
            "Class",             "Kernel",              "Comparable",
            "Enumerable",        "NilClass",            "TrueClass",
            "FalseClass",        "Numeric",             "Integer",
            "Float",             "String",              "Symbol",
            "Array",             "Hash",                "Range",
            "Proc",              "Struct",              "Exception",
            "StandardError",     "RuntimeError",        "ArgumentError",
            "TypeError",         "NameError",           "NoMethodError",
            "IndexError",        "KeyError",            "RangeError",
            "ZeroDivisionError", "FrozenError",         "StopIteration",
            "ScriptError",       "NotImplementedError", "LocalJumpError",
        };
        for (frozen_classes) |name| {
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

    fn maskMethod(cls: anytype, name: []const u8) !void {
        if (!c.mrz_protected_mask_method(
            cls.mrb,
            cls.class,
            name.ptr,
            name.len,
            c.MRZ_MASK_INSTANCE,
        )) return error.RubyException;
    }

    fn installFrozenClock(iso: *Isolate, epoch: i64) !void {
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
                const active: *Isolate =
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
        const iso: *Isolate =
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

    fn noteTerm(iso: *Isolate, kind: TerminationKind) void {
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

    fn syncOomCause(iso: *Isolate) void {
        if (iso.cell.anyOom()) noteTerm(iso, .memory);
    }

    fn currentTermination(iso: *Isolate) ?TerminationKind {
        syncOomCause(iso);
        return selectedTermination(iso.termination_bits.load(.acquire));
    }

    fn terminationException(iso: *Isolate, kind: TerminationKind) c.mrb_value {
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
    try std.testing.expectEqual(maximum, Isolate.defaultHardCap(maximum).?);
}

const SandboxBootstrap = struct {
    hidden: *c.RClass,
    error_root: c.mrb_value,
    policy_exceptions: c.mrb_value,
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
pub fn compile(src: []const u8) ![]u8 {
    var raw = try compileRaw(src, null, 0);
    defer raw.deinit();
    return alloc_mod.gpa.dupe(u8, raw.bytes());
}

/// Compile source into a typed, caller-owned RITE artifact.
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
