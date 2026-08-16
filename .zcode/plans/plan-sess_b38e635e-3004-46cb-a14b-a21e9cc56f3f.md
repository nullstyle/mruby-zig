# Sandboxing for mruby-zig — v8-isolate parity, then better

Add a `mruby.sandbox` module delivering what V8 isolates give (separate heaps, per-isolate memory limits, async termination from any thread, no ambient authority) **plus** things V8 doesn't have: deterministic instruction-gas budgets, a real capability model with object-model freezing, un-rescuable termination semantics, and precompiled-irep snapshots for mass spawn. The out-of-process tier (worker processes with IPC — OS-level separation beyond v8) is explicitly out of scope for v1 and will be documented as the follow-up architecture.

## Verified mechanisms (from mruby 4.0 source research)

- `mrb->code_fetch_hook` (`MRB_USE_DEBUG_HOOK`): NULL-guarded function pointer invoked **once per VM instruction** in both dispatch modes (`src/vm.c:1519-1556`). Raising from the hook is valid — it longjmps to the interpreter's internal `MRB_TRY`, so `rescue`/`ensure` semantics work normally.
- `mrb_basic_alloc_func` (already ours): every non-object allocation flows through it → per-isolate caps enforced there. On NULL, mruby does full-GC + one retry, then raises pre-allocated `NoMemoryError` (rescuable — so we escalate via sticky flags).
- `mrb_undef_method` (C-string variant doesn't raise if absent), `mrb_const_remove`, and `mrb_obj_freeze` on core classes (frozen classes raise `FrozenError` from `def`/`include`) → capability stripping.
- `mrb_dump_irep` / `mrb_load_irep_buf` (buffer APIs, no stdio) → snapshot images. Caveat handled: each irep load leaks one RProc unless arena-rooted.
- mruby's fixed limits (call depth 512, value stack ~256K) exist; `gc.live` and `ci` depth are readable for per-isolate tighter enforcement.

## Public API (new `src/sandbox.zig`)

```zig
const iso = try mruby.sandbox.Isolate.spawn(.{
    .limits = .{
        .instructions  = 10_000_000,            // deterministic gas (v8 has no analog)
        .wall_time_ns  = 250 * std.time.ns_per_ms,
        .memory_bytes  = 8 * 1024 * 1024,       // hard per-isolate cap
        .call_depth    = 64,                    // tighter than mruby's 512
    },
    .capabilities = .{
        .eval = false,                          // Kernel#eval, instance_eval, binding
        .send = false,                          // send/__send__/public_send
        .introspection = false,                 // instance_variable_* etc.
        .object_space = false,                  // ObjectSpace removed
        .freeze_object_model = true,            // core classes frozen (def → FrozenError)
        .random_seed = 42,                      // deterministic Random (optional)
        .clock_epoch_s = 1_700_000_000,         // frozen Time.now (optional)
    },
});
defer iso.deinit();

const result = iso.run(script) catch |err| switch (err) {
    error.ScriptTerminated,                     // iso.terminate() from any thread
    error.DeadlineExceeded,
    error.GasExhausted,
    error.MemoryLimitExceeded => ...,           // mapped from hidden exception classes
    error.RubyException => ...,                 // ordinary script error: iso.vm.lastError()
};

iso.terminate();                    // thread-safe, takes effect next instruction
_ = iso.stats();                    // .instructions .peak_memory_bytes .peak_call_depth .wall_time_ns

const image = try mruby.sandbox.compile(script);   // []u8 irep binary (snapshot)
const iso2 = try mruby.sandbox.Isolate.spawn(policy);
_ = try iso2.runImage(image);                      // no re-parse/compile
```

## Enforcement design

**Instruction hook (Zig, `callconv(.c)`)** — installed per isolate:
- `terminate` atomic checked every instruction (relaxed load, ~free); wall-clock every 1024 instructions; gas decremented per instruction; per-isolate `call_depth` via shim-read ci depth; `gc.live` observed for peak stats.
- Violations raise dedicated exception classes under a hidden `MRubyZigSandbox::` namespace. Termination is **un-rescuable**: sticky flags make the hook re-raise on the next instruction if a script catches it, while `ensure` blocks still run (better than mruby 4.0's task-stop, which skips them). Our `run()` maps those classes to the distinct Zig errors above.

**Memory caps (in `src/alloc.zig`)** — thread-local "current isolate" cell bracketed at `Isolate` entry points (spawn/run/runImage/call/deinit; sound because a Vm is single-thread-at-a-time, our existing documented constraint). Soft cap → allocation fails once (mruby raises rescuable `NoMemoryError`); sticky soft-OOM seen by the hook escalates to `MemoryLimitExceeded` termination; hard cap → allocator fails permanently + immediate termination. Host gets an `on_limit` callback. Raw `Vm` usage keeps today's global accounting untouched (back-compat).

**Capabilities** — applied after gem init at spawn: `mrb_undef_method` on Kernel/BasicObject per policy, `mrb_const_remove(Object, :ObjectSpace)`, freezing of the core class list when `freeze_object_model`, `srand(seed)` for determinism, and a Zig-defined `Time.now` returning a cached `Time.at(epoch)` when `clock_epoch_s` is set.

**Documented caveat (same class as v8):** the hook fires only on bytecode — long-running pure-C operations and host Zig callbacks aren't instruction-interruptible; memory caps still bound them, and hosts should keep callbacks bounded.

## Implementation steps

1. Build/shim/binds: `-DMRB_USE_DEBUG_HOOK` in `build.zig` lib+scan flags; `mrz_set_code_fetch_hook` / `mrz_ci_depth` / `mrz_gc_live` in `src/shim.c`; bind `mrb_undef_method`, `mrb_undef_class_method`, `mrb_const_remove`, `mrb_dump_irep`, `mrb_load_irep_buf` in `src/c.zig`.
2. `alloc.zig`: per-isolate attribution cells + soft/hard caps + callback (unit-tested independently of mruby).
3. `sandbox.zig` core: Policy/Isolate/hook/termination classes/error mapping; `Vm` gains an opaque `sandbox_ctx` field for hook→isolate lookup via the existing registry.
4. Tests: external `terminate()` killing `while true; end`; deadline; exact gas determinism; memory cap with escalation; capability strips (`eval`/`send` → NoMethodError, `ObjectSpace` gone, `def` on frozen core → FrozenError); determinism (seeded Random sequence); nested `run` from a method callback; two isolates on separate threads with different policies; snapshot compile→runImage roundtrip; stats sanity.
5. Docs: README "Sandboxing" section rewritten around the real API (incl. the process-tier follow-up architecture sketch and the cfunc caveat); CHANGELOG; `zig fmt`; full test + example runs on standard, minimal, and `-Dwithout-gems` configs.

## Out of scope (documented follow-up)

Out-of-process isolates (re-exec worker mode, pipe IPC with run/call/terminate/stats, structured value transfer, crash recovery) — designed to layer on `Isolate` without API changes; irep snapshotting already gives it cheap worker warm-starts.
