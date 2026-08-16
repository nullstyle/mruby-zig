//! Sandboxing: v8-isolate parity, then better.
//!
//! An `Isolate` owns a private `Vm` (separate heap, symbols, globals —
//! nothing is shared between isolates) plus an enforced `Policy`:
//!
//!   - `instructions`: deterministic gas budget (interpreter instructions;
//!     v8 has no equivalent),
//!   - `wall_time_ns`: deadline checked between instructions,
//!   - `memory_bytes` / `hard_memory_bytes`: per-isolate allocation caps
//!     with soft (rescuable NoMemoryError) → hard (un-rescuable
//!     termination) escalation,
//!   - `call_depth`: tighter than mruby's fixed 512,
//!   - `Capabilities`: strip `eval`/`send`/introspection/ObjectSpace,
//!     freeze the core object model (`def` → FrozenError), pin the RNG
//!     seed and the clock for reproducible runs.
//!
//! `terminate()` is safe to call from any thread and takes effect at the
//! next interpreter instruction. Termination is **un-rescuable**: the
//! instruction hook re-raises on every instruction while a termination is
//! pending (scripts cannot `rescue` their way out), but `ensure` blocks
//! still run — unlike mruby's task-stop mechanism, which skips them.
//!
//! Same class of caveat as v8 native code: the hook fires on bytecode
//! only. Long pure-C operations and host Zig callbacks are not
//! instruction-interruptible (memory caps still bound them); keep host
//! callbacks bounded or poll `Isolate.pendingTermination` from them.
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

pub const Vm = vm_mod.Vm;
pub const Value = value_mod.Value;
pub const RubyError = error_mod.RubyError;

/// Enforced resource limits. All optional; unset fields are unbounded.
pub const Limits = struct {
    /// Interpreter instruction budget (deterministic "gas"). Exact across
    /// runs of the same script on the same build.
    instructions: ?u64 = null,
    /// Wall-clock deadline for the whole isolate lifetime, in nanoseconds.
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
pub const Capabilities = struct {
    /// Kernel#eval / #instance_eval / #instance_exec / #binding.
    eval: bool = true,
    /// send / __send__ / public_send.
    send: bool = true,
    /// instance_variable_* / methods / method / singleton_methods.
    introspection: bool = true,
    /// The ObjectSpace module.
    object_space: bool = true,
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
};

pub const Stats = struct {
    instructions: u64,
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

const clock_batch = 1024; // deadline + stats sampled every N instructions
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
                return @divFloor(counter * 1_000_000_000, freq);
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
    vm: *Vm,
    policy: Policy,
    cell: alloc_mod.IsolateCell = .{},

    // hook/runtime state (owned by the isolate's thread while running)
    terminate_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    pending_kind: std.atomic.Value(u8) = std.atomic.Value(u8).init(@backingInt(TerminationKind.script)),
    instr_count: u64 = 0,
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
    /// Termination is delivered on the fetch AFTER the one that detected
    /// the violation: the hook runs before instruction execution, and
    /// catch-handler coverage requires pc to have advanced past the
    /// region start (a raise at a region's first instruction would find
    /// no handler and skip ensure blocks).
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
    capabilities_applied: bool = false,
    running: bool = false,

    // hidden exception classes (rooted as constants of this module)
    hidden: *c.RClass,
    /// Exception (as a raw value) behind the last failed run; funcalling
    /// with mrb->exc pending can clobber it, so it is stashed and the
    /// pending state cleared before classification.
    last_exc: c.mrb_value = undefined,

    /// Spawn an isolate with a policy. The underlying `Vm` is fully
    /// initialized; capabilities apply lazily on the first `run`/`call`
    /// (register host methods on `iso.vm` before then when freezing).
    pub fn spawn(policy: Policy) !*Isolate {
        // Bracket bootstrap allocations so caps see them.
        var bootstrap_cell = alloc_mod.IsolateCell{};
        alloc_mod.enterIsolate(&bootstrap_cell);
        defer alloc_mod.exitIsolate();

        const vm = try Vm.init();
        errdefer vm.deinit();

        const iso = try alloc_mod.gpa.create(Isolate);
        errdefer alloc_mod.gpa.destroy(iso);

        const hidden = c.mrb_define_module(vm.mrb, "MRubyZigSandbox");
        defineTerminationClasses(vm.mrb, hidden);

        iso.* = .{
            .vm = vm,
            .policy = policy,
            .hidden = hidden,
            .cell = .{
                // Bootstrap allocations (state, symbols, core classes,
                // termination classes) are permanent; count them toward
                // the caps so budgets reflect true isolate footprint.
                .live_bytes = bootstrap_cell.live_bytes,
                .live_allocs = bootstrap_cell.live_allocs,
                .peak_bytes = bootstrap_cell.live_bytes,
                .soft_cap = policy.limits.memory_bytes,
                .hard_cap = policy.limits.hard_memory_bytes orelse defaultHardCap(policy.limits.memory_bytes),
            },
        };
        iso.gas_remaining = policy.limits.instructions orelse 0;
        c.mrz_set_ud(vm.mrb, iso);
        c.mrz_set_code_fetch_hook(vm.mrb, fetchHook);
        return iso;
    }

    pub fn deinit(iso: *Isolate) void {
        alloc_mod.enterIsolate(&iso.cell);
        defer alloc_mod.exitIsolate();
        c.mrz_set_code_fetch_hook(iso.vm.mrb, null);
        c.mrz_set_ud(iso.vm.mrb, null);
        iso.vm.deinit();
        alloc_mod.gpa.destroy(iso);
    }

    /// Run `src` under the policy. Policy terminations surface as distinct
    /// errors (`ScriptTerminated`, `DeadlineExceeded`, `GasExhausted`,
    /// `MemoryLimitExceeded`, `CallDepthExceeded`); ordinary script errors
    /// as `error.RubyException` (see `iso.vm.lastError()`).
    pub fn run(iso: *Isolate, src: []const u8) !Value {
        try iso.prepare();
        return iso.bracketed(struct {
            fn body(iso_: *Isolate, src_: []const u8) !Value {
                return iso_.vm.loadString(src_);
            }
        }.body, src);
    }

    /// Run a snapshot produced by `compile` (no parse/codegen).
    pub fn runImage(iso: *Isolate, image: []const u8) !Value {
        try iso.prepare();
        return iso.bracketed(struct {
            fn body(iso_: *Isolate, image_: []const u8) !Value {
                return Value{ .mrb = iso_.vm.mrb, .v = c.mrb_load_irep_buf(iso_.vm.mrb, image_.ptr, image_.len) };
            }
        }.body, image);
    }

    /// Call a Ruby method under the policy (same error mapping as `run`).
    pub fn call(iso: *Isolate, recv: Value, name: []const u8, args: anytype) !Value {
        try iso.prepare();
        return iso.bracketed(struct {
            fn body(iso_: *Isolate, ctx: anytype) !Value {
                return iso_.vm.call(ctx.recv, ctx.name, ctx.args);
            }
        }.body, .{ .recv = recv, .name = name, .args = args });
    }

    /// Request termination from any thread. The running script stops at
    /// the next interpreter instruction (`ensure` blocks run; `rescue`
    /// cannot suppress it) and the pending `run` returns
    /// `error.ScriptTerminated`.
    pub fn terminate(iso: *Isolate) void {
        iso.pending_kind.store(@backingInt(TerminationKind.script), .release);
        iso.terminate_flag.store(true, .release);
    }

    /// True once termination has been requested (or a limit has fired) and
    /// has not been observed yet. Host callbacks that loop for a long time
    /// can poll this to cooperatively unwind.
    pub fn pendingTermination(iso: *Isolate) bool {
        return iso.terminate_flag.load(.acquire) or iso.cell.hard_oom;
    }

    pub fn stats(iso: *Isolate) Stats {
        const depth: u32 = @intCast(@max(0, c.mrz_ci_depth(iso.vm.mrb)));
        return .{
            .instructions = iso.instr_count,
            .peak_memory_bytes = iso.cell.peak_bytes,
            .live_memory_bytes = iso.cell.live_bytes,
            .peak_call_depth = @max(iso.peak_call_depth, depth),
            .live_objects = c.mrz_gc_live(iso.vm.mrb),
            .wall_time_ns = iso.elapsed_ns,
            .soft_memory_limit_hit = iso.cell.soft_oom,
            .hard_memory_limit_hit = iso.cell.hard_oom,
        };
    }

    // ---- internals --------------------------------------------------------

    fn defaultHardCap(soft: ?usize) ?usize {
        const s = soft orelse return null;
        return s + @max(1024 * 1024, s / 2);
    }

    fn prepare(iso: *Isolate) !void {
        if (iso.capabilities_applied) return;
        iso.capabilities_applied = true;
        const caps_result: anyerror!void = iso.applyCapabilities();
        caps_result catch |err| switch (err) {
            error.RubyException => {
                iso.vm.clearError();
                return error.CapabilityApplicationFailed;
            },
            else => return err,
        };
    }

    fn bracketed(iso: *Isolate, comptime body: anytype, ctx: anytype) !Value {
        if (iso.running) return body(iso, ctx); // nested: already bracketed
        iso.running = true;
        defer iso.running = false;

        if (iso.policy.limits.wall_time_ns) |budget| {
            if (iso.deadline_ns == null) {
                iso.start_ns = monotonicNs();
                iso.deadline_ns = iso.start_ns + @as(i128, @intCast(budget));
            }
        } else if (iso.start_ns == 0) {
            iso.start_ns = monotonicNs();
        }

        alloc_mod.enterIsolate(&iso.cell);
        defer alloc_mod.exitIsolate();

        iso.last_exc = c.mrz_nil_value();
        iso.grace_armed = false;
        const result = body(iso, ctx) catch |err| {
            return iso.mapError(err);
        };
        if (iso.terminate_flag.load(.acquire)) {
            return terminationError(@fromBackingInt(@intCast(iso.pending_kind.load(.monotonic))));
        }
        iso.elapsed_ns = @intCast(@max(0, monotonicNs() - iso.start_ns));
        return result;
    }

    /// The exception behind the last failed `run`/`runImage`/`call`
    /// (ordinary script errors; policy terminations are reported as their
    /// distinct Zig errors instead). Only valid until the next run.
    pub fn lastError(iso: *Isolate) ?RubyError {
        if (c.mrz_nil_p(iso.last_exc)) return null;
        return RubyError.fromValue(iso.vm.mrb, iso.last_exc);
    }

    /// Policy terminations are raised as hidden exception classes; map
    /// them (and memory-limit NoMemoryError) to distinct Zig errors.
    fn mapError(iso: *Isolate, err: anyerror) anyerror {
        if (err != error.RubyException) return err;
        if (iso.cell.soft_oom or iso.cell.hard_oom) {
            return error.MemoryLimitExceeded;
        }
        // Stash the exception value and clear the pending state before
        // funcalling (class/to_s) — mruby funcalls disturb a pending exc.
        iso.last_exc = c.mrz_exc_value(iso.vm.mrb);
        c.mrz_exc_clear(iso.vm.mrb);
        if (iso.terminate_flag.load(.acquire)) {
            return terminationError(@fromBackingInt(@intCast(iso.pending_kind.load(.monotonic))));
        }
        if (c.mrz_nil_p(iso.last_exc)) return err;
        const exc = RubyError.fromValue(iso.vm.mrb, iso.last_exc);
        const cls = exc.className();
        defer alloc_mod.gpa.free(cls);
        if (std.mem.startsWith(u8, cls, "MRubyZigSandbox::")) {
            if (std.mem.endsWith(u8, cls, "::ScriptTerminated")) return error.ScriptTerminated;
            if (std.mem.endsWith(u8, cls, "::DeadlineExceeded")) return error.DeadlineExceeded;
            if (std.mem.endsWith(u8, cls, "::GasExhausted")) return error.GasExhausted;
            if (std.mem.endsWith(u8, cls, "::MemoryLimitExceeded")) return error.MemoryLimitExceeded;
            if (std.mem.endsWith(u8, cls, "::CallDepthExceeded")) return error.CallDepthExceeded;
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

    fn hookNoop(mrb: ?*c.mrb_state, self: c.mrb_value) callconv(.c) c.mrb_value {
        _ = mrb;
        _ = self;
        return c.mrz_nil_value();
    }

    fn applyCapabilities(iso: *Isolate) !void {
        const caps = iso.policy.capabilities;
        const m = iso.vm.mrb;

        // mrb_undef_method fires the method_undefined hook on the class;
        // without a handler that funcall raises NoMethodError. Install a
        // no-op on Kernel (in the ancestry of every class object) first.
        const kernel0 = try iso.vm.getClass("Kernel");
        c.mrb_define_method(m, kernel0.class, "method_undefined", hookNoop, 1 << 18); // MRB_ARGS_REQ(1)

        if (!caps.eval) {
            const kernel = try iso.vm.getClass("Kernel");
            undef(kernel, "eval");
            undef(kernel, "instance_eval");
            undef(kernel, "instance_exec");
            undef(kernel, "binding");
        }
        if (!caps.send) {
            const kernel = try iso.vm.getClass("Kernel");
            const basic = try iso.vm.getClass("BasicObject");
            undef(kernel, "send");
            undef(kernel, "public_send");
            undef(basic, "__send__");
        }
        if (!caps.introspection) {
            const kernel = try iso.vm.getClass("Kernel");
            for ([_][]const u8{
                "instance_variable_get", "instance_variable_set",
                "instance_variables",    "instance_variable_defined?",
                "methods",               "method",
                "singleton_methods",
            }) |name| undef(kernel, name);
        }
        if (!caps.object_space) {
            const present = blk: {
                _ = iso.vm.getClass("ObjectSpace") catch break :blk false;
                break :blk true;
            };
            if (present) {
                const object = try iso.vm.getClass("Object");
                const sym = try iso.vm.internSymbol("ObjectSpace");
                c.mrb_const_remove(m, object.class, sym);
            }
        }
        if (caps.random_seed) |seed| {
            var buf: [64]u8 = undefined;
            const src = std.fmt.bufPrint(&buf, "srand({d})", .{seed}) catch unreachable;
            _ = iso.vm.loadString(src) catch iso.vm.clearError();
        }
        if (caps.clock_epoch_s) |epoch| {
            iso.installFrozenClock(epoch) catch iso.vm.clearError();
        }
        if (caps.freeze_object_model) {
            const frozen_classes = [_][]const u8{
                "Object", "BasicObject", "Kernel",     "Module",
                "Class",  "Comparable",  "Enumerable", "String",
                "Symbol", "Integer",     "Float",      "Array",
                "Hash",   "Range",       "Proc",       "Exception",
            };
            for (frozen_classes) |name| {
                const cls = iso.vm.getClass(name) catch continue;
                _ = c.mrb_obj_freeze(m, .{ .w = @intFromPtr(cls.class) });
            }
        }
    }

    fn undef(cls: anytype, name: []const u8) void {
        var buf: [64]u8 = undefined;
        if (name.len >= buf.len) return;
        @memcpy(buf[0..name.len], name);
        buf[name.len] = 0;
        c.mrb_undef_method(cls.mrb, cls.class, @ptrCast(&buf));
    }

    fn installFrozenClock(iso: *Isolate, epoch: i64) !void {
        const m = iso.vm.mrb;
        const time = try iso.vm.getClass("Time");
        // Build Time.at(epoch) via funcall and root it as a constant on the
        // hidden module (mruby has no Ruby-level scoped const assignment).
        const time_val = c.mrb_value{ .w = @intFromPtr(time.class) };
        const frozen = try iso.vm.call(Value{ .mrb = m, .v = time_val }, "at", .{epoch});
        c.mrb_define_const(m, iso.hidden, "FROZEN_TIME", frozen.v);
        // Replace Time.now with a Zig class method returning the cached
        // constant (built once, so all calls return the same object).
        const Clock = struct {
            fn now(mrb: ?*c.mrb_state, self: c.mrb_value) callconv(.c) c.mrb_value {
                _ = self;
                const mm = mrb orelse return c.mrz_nil_value();
                const sym = c.mrb_intern_cstr(mm, "FROZEN_TIME");
                const hidden_mod = c.mrb_module_get(mm, "MRubyZigSandbox");
                const val = c.mrz_obj_value(@ptrCast(hidden_mod));
                return c.mrb_const_get(mm, val, sym);
            }
        };
        c.mrb_undef_class_method(m, time.class, "now");
        _ = c.mrb_define_class_method(m, time.class, "now", Clock.now, c.MRB_ARGS_NONE);
    }

    // ---- the instruction hook ----------------------------------------------

    fn fetchHook(mrb: ?*c.mrb_state, irep: ?*const anyopaque, pc: ?*const anyopaque, regs: ?*anyopaque) callconv(.c) void {
        _ = regs;
        const m = mrb orelse return;
        const iso: *Isolate = @ptrCast(@alignCast(c.mrz_get_ud(m) orelse return));

        iso.instr_count += 1;

        // Record limit conditions (idempotent flags).
        if (iso.cell.soft_oom) noteTerm(iso, .memory);
        if (iso.policy.limits.instructions != null and iso.gas_remaining == 0) noteTerm(iso, .gas);
        if (iso.policy.limits.call_depth) |maxd| {
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
                raiseTerm(m, iso, if (iso.cell.hard_oom) .memory else @fromBackingInt(@intCast(iso.pending_kind.load(.monotonic))));
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
        if (iso.terminate_flag.load(.acquire) or iso.cell.hard_oom) {
            const unwinding = !c.mrz_nil_p(c.mrz_exc_value(m));
            if (!unwinding) {
                if (iso.handler_grace > 0) {
                    iso.handler_grace -= 1;
                } else {
                    iso.raise_pending = true;
                }
            }
            if (iso.cell.hard_oom) return; // no gas/step accounting needed
        }

        // Step the counters.
        if (iso.policy.limits.instructions != null and iso.gas_remaining > 0) {
            iso.gas_remaining -= 1;
        }

        // Deadline, batched.
        if (iso.instr_count % clock_batch == 0) {
            if (iso.deadline_ns) |dl| {
                if (monotonicNs() > dl) noteTerm(iso, .deadline);
            }
        }
    }

    fn noteTerm(iso: *Isolate, kind: TerminationKind) void {
        iso.pending_kind.store(@backingInt(kind), .release);
        iso.terminate_flag.store(true, .release);
    }

    fn raiseTerm(m: *c.mrb_state, iso: *Isolate, kind: TerminationKind) noreturn {
        noteTerm(iso, kind);
        if (!iso.grace_armed) {
            iso.handler_grace = handler_grace_instructions;
            iso.grace_armed = true;
        }
        const name = switch (kind) {
            .script => "ScriptTerminated",
            .deadline => "DeadlineExceeded",
            .gas => "GasExhausted",
            .memory => "MemoryLimitExceeded",
            .call_depth => "CallDepthExceeded",
        };
        var buf: [96]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "mruby-zig sandbox: {s}", .{name}) catch unreachable; // 96B buf, <= 22B name
        const cls = c.mrb_class_get_under(m, iso.hidden, name);
        const msg_v = c.mrb_str_new(m, if (msg.len == 0) null else msg.ptr, @intCast(msg.len));
        const exc = c.mrb_funcall(m, c.mrz_obj_value(@ptrCast(cls)), "exception", 1, msg_v);
        c.mrb_exc_raise(m, exc);
    }
};

fn defineTerminationClasses(m: *c.mrb_state, hidden: *c.RClass) void {
    const names = [_][]const u8{
        "ScriptTerminated",    "DeadlineExceeded",  "GasExhausted",
        "MemoryLimitExceeded", "CallDepthExceeded",
    };
    for (names) |name| {
        var buf: [64]u8 = undefined;
        if (name.len >= buf.len) continue;
        @memcpy(buf[0..name.len], name);
        buf[name.len] = 0;
        const exc = c.mrb_class_get(m, "Exception");
        _ = c.mrb_define_class_under(m, hidden, @ptrCast(&buf), exc);
    }
}

/// Compile `src` to a snapshot image (Rite irep binary) without executing
/// it. Run later with `Isolate.runImage`; images are per-build (bytecode
/// version) but isolate- and policy-independent.
pub fn compile(src: []const u8) ![]u8 {
    const vm = try Vm.init();
    defer vm.deinit();

    // NUL-terminate for the lexer (same discipline as Vm.loadString).
    const buf = try alloc_mod.gpa.alloc(u8, src.len + 1);
    defer alloc_mod.gpa.free(buf);
    @memcpy(buf[0..src.len], src);
    buf[src.len] = 0;

    const parser = c.mrb_parse_nstring(vm.mrb, buf.ptr, src.len, null) orelse return error.CompileFailed;
    defer c.mrb_parser_free(parser);
    if (c.mrz_parse_nerr(parser) != 0) return error.CompileFailed;
    const proc = c.mrb_generate_code(vm.mrb, parser) orelse return error.CompileFailed;

    var bin: ?[*]u8 = null;
    var bin_size: usize = 0;
    const rc = c.mrb_dump_irep(vm.mrb, c.mrz_proc_irep(proc), 0, &bin, &bin_size);
    if (rc != 0) return error.CompileFailed;
    // mrb_malloc'd buffer: copy to a gpa slice, free through mruby.
    const owned = try alloc_mod.gpa.dupe(u8, bin.?[0..bin_size]);
    _ = mrb_free_via_allocator(bin.?, bin_size);
    return owned;
}

fn mrb_free_via_allocator(ptr: [*]u8, size: usize) void {
    // The dump buffer was allocated through mrb_malloc (our allocator with
    // its header prefix), so free it through the same path.
    _ = alloc_mod.mrb_basic_alloc_func_pub(@ptrCast(ptr), 0);
    _ = size;
}
