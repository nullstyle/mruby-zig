# First-class gas for `mruby-zig`

Research date: 2026-08-28. This note uses only first-party Shopify and mruby
sources for the external audit. The audited repository state is Shopify's
current default `master` HEAD,
[`db03e6b14b879f821e9691c7e89267080480397c`](https://github.com/Shopify/mruby-engine/commit/db03e6b14b879f821e9691c7e89267080480397c),
whose `ext/mruby_engine/mruby` gitlink is Shopify/mruby commit
[`72c37992a56c004539877ffd56989bc44d0f670b`](https://github.com/Shopify/mruby/commit/72c37992a56c004539877ffd56989bc44d0f670b).

## Conclusion

Shopify calls this an **instruction quota**, not gas. It is a fixed,
engine-owned, lifetime-cumulative counter. The debug hook checks the count
before the next opcode, permits exactly the configured number of opcodes, and
aborts before opcode `quota + 1`. Exhaustion is transported out of band rather
than as an mruby guest exception. It permanently poisons the engine for
`sandbox_eval`, instruction-sequence load, injection, and extraction; only
statistics and destruction remain useful. Shopify exposes no reset, refill, or
quota setter.

That model gives us two useful ideas: put accounting in the interpreter hook,
and keep a lifetime counter distinct from the configured allowance. We should
not copy the all-or-nothing poison flag. In `mruby-zig`, gas is already coupled
to a richer termination protocol that runs `ensure` and bounds hostile
`rescue`. Reusable gas therefore needs a host-authorized **new gas generation**,
not a write to `gas_remaining`: it must clear only gas-specific termination
state after the outermost call has fully unwound, while preserving every
non-gas termination and the Ruby heap.

The recommended Interface makes those generations automatic policy: a
`.per_execution = N` Isolate receives a fresh generation at each admitted
outermost `run`, `runImage`, or `call`, while rejected preflights do not
advance it and nested re-entry shares the active one.
`.per_isolate = N` retains today's lifetime-sticky behavior. An explicit
`resetGas` method and option-bearing execution calls were also designed below;
they are useful alternatives, but they make the common fixed-budget case more
stateful or widen the public Interface.

Renewal also exposes one existing hidden execution Seam that must be closed:
the sandbox's `lastError().message()` and `className()` currently call Ruby
methods after `run` has returned. The extension therefore snapshots inert
exception metadata before an epoch is cleaned up. Reading an ordinary error
afterward must execute zero guest bytecodes and must not alter gas statistics.

## Shopify implementation audit

### Baseline and relevant history

The default `master` build points at Shopify's mruby fork via a submodule
([`.gitmodules` lines 1-4](https://github.com/Shopify/mruby-engine/blob/db03e6b14b879f821e9691c7e89267080480397c/.gitmodules#L1-L4)).
That pinned fork identifies itself as mruby 1.2.0
([`version.h` lines 40-80](https://github.com/Shopify/mruby/blob/72c37992a56c004539877ffd56989bc44d0f670b/include/mruby/version.h#L40-L80)),
and the build enables `MRB_ENABLE_DEBUG_HOOK`
([`flag_helper.rb` lines 19-33](https://github.com/Shopify/mruby-engine/blob/db03e6b14b879f821e9691c7e89267080480397c/ext/mruby_engine/flag_helper.rb#L19-L33)).
An official but unmerged 2026 change attempted to move the submodule to mruby
4.0; its commit did not change the quota implementation
([commit `52f5d67`](https://github.com/Shopify/mruby-engine/commit/52f5d67bfa4c53f13e66d381d4a28f4b936c2118)).
Consequently, Shopify's repository is evidence for the design, but not evidence
that this exact C implementation was exercised against mruby 4.0.

The instruction counter, pre-opcode check, sticky flag, and public preflight
gate were already present in Shopify's opening 2016 source snapshot
([initial hook and initialization, lines 122-184](https://github.com/Shopify/mruby-engine/blob/b048f970e5e7fe66b98f5bb606658fdb5c51a892/ext/mruby_engine/mruby_engine.c#L122-L184),
[initial gate, lines 64-69](https://github.com/Shopify/mruby-engine/blob/b048f970e5e7fe66b98f5bb606658fdb5c51a892/ext/mruby_engine/ext.c#L64-L69)).
A `git log -G`/`-S` audit of the official repository found no later semantic
change to those gas mechanics through the audited `master` HEAD. The relevant
later concurrency history is in the separate wall-time monitor: Shopify fixed
a race where a timed-out thread finished before cancellation
([commit `9ad117a`](https://github.com/Shopify/mruby-engine/commit/9ad117aa0b13513d7bf2ec14facb5bb6f24171ea)).

### Counter ownership and hook installation

`me_mruby_engine` owns `instruction_count`, `instruction_quota`, and the
generic sticky `quota_error_raised` bit
([`mruby_engine_private.h` lines 27-42](https://github.com/Shopify/mruby-engine/blob/db03e6b14b879f821e9691c7e89267080480397c/ext/mruby_engine/mruby_engine_private.h#L27-L42)).
Construction sets the quota, zeros the count and poison bit, and installs the
hook on that engine's `mrb_state`
([`mruby_engine.c` lines 177-204](https://github.com/Shopify/mruby-engine/blob/db03e6b14b879f821e9691c7e89267080480397c/ext/mruby_engine/mruby_engine.c#L177-L204)).
The hook recovers the engine through `mrb->allocf_ud`, which is also the
allocator's userdata
([allocator userdata, lines 64-85](https://github.com/Shopify/mruby-engine/blob/db03e6b14b879f821e9691c7e89267080480397c/ext/mruby_engine/mruby_engine.c#L64-L85),
[hook lookup, lines 139-154](https://github.com/Shopify/mruby-engine/blob/db03e6b14b879f821e9691c7e89267080480397c/ext/mruby_engine/mruby_engine.c#L139-L154)).

This is one counter per engine/mruby heap. It is neither local to one eval nor
reset at an eval boundary. Normal evaluations may reuse the heap while adding
to the same count until the lifetime quota is reached.

### Hook order and the off-by-one answer

Shopify's pinned mruby stores `code_fetch_hook` on `mrb_state`
([`mruby.h` lines 212-215](https://github.com/Shopify/mruby/blob/72c37992a56c004539877ffd56989bc44d0f670b/include/mruby.h#L212-L215)).
Both switch and direct-threaded dispatch invoke it after fetching/decoding the
instruction and before entering the opcode body
([`vm.c` lines 808-840](https://github.com/Shopify/mruby/blob/72c37992a56c004539877ffd56989bc44d0f670b/src/vm.c#L808-L840)).

The engine hook does this in order:

1. If `instruction_count >= instruction_quota`, signal exhaustion.
2. Otherwise increment `instruction_count`.
3. Then perform the Linux stack check for selected send opcodes.
4. Return to the VM, which executes the fetched opcode.

The implementation is visible in
[`mruby_engine.c` lines 139-169](https://github.com/Shopify/mruby-engine/blob/db03e6b14b879f821e9691c7e89267080480397c/ext/mruby_engine/mruby_engine.c#L139-L169).
Starting from zero, fetches `1...quota` increment and execute; fetch
`quota + 1` exits before incrementing and before executing. The final count is
therefore exactly the quota, not quota plus one. Shopify locks this behavior in
a spec that expects `stat[:instructions] == reasonable_instruction_quota`
after exhaustion
([`mruby_engine_spec.rb` lines 97-102](https://github.com/Shopify/mruby-engine/blob/db03e6b14b879f821e9691c7e89267080480397c/spec/mruby_engine_spec.rb#L97-L102)).

The hook counts mruby bytecodes, not work performed inside one C opcode. A
long-running native method can therefore consume wall time without advancing
the instruction quota; Shopify's separate wall-time monitor exists for that
class of work.

### Quota error transport and guest unwind behavior

Instruction exhaustion creates a small C `me_eval_err` tagged
`ME_EVAL_INSTRUCTION_QUOTA_REACHED` and records the configured quota
([`mruby_engine.c` lines 43-51](https://github.com/Shopify/mruby-engine/blob/db03e6b14b879f821e9691c7e89267080480397c/ext/mruby_engine/mruby_engine.c#L43-L51),
[`mruby_engine.h` lines 29-53](https://github.com/Shopify/mruby-engine/blob/db03e6b14b879f821e9691c7e89267080480397c/ext/mruby_engine/mruby_engine.h#L29-L53)).
It does **not** instantiate or raise an exception inside the guest mruby heap.
The host conversion later creates the CRuby
`MRubyEngine::EngineInstructionQuotaError` with the quota in its message
([`mruby_engine.c` lines 442-460](https://github.com/Shopify/mruby-engine/blob/db03e6b14b879f821e9691c7e89267080480397c/ext/mruby_engine/mruby_engine.c#L442-L460),
[`host.c` lines 92-100](https://github.com/Shopify/mruby-engine/blob/db03e6b14b879f821e9691c7e89267080480397c/ext/mruby_engine/host.c#L92-L100)).

Transport is platform-dependent:

- On Linux, guest evaluation runs in a pthread. `eval_leave` writes the C error,
  marks the engine poisoned, and calls `pthread_exit`; a pthread cleanup handler
  signals completion, the host joins the thread, and only then converts the C
  error to a CRuby exception
  ([`eval_monitored.c` lines 37-71](https://github.com/Shopify/mruby-engine/blob/db03e6b14b879f821e9691c7e89267080480397c/ext/mruby_engine/eval_monitored.c#L37-L71),
  [`eval_monitored.c` lines 211-235](https://github.com/Shopify/mruby-engine/blob/db03e6b14b879f821e9691c7e89267080480397c/ext/mruby_engine/eval_monitored.c#L211-L235)).
- On unmonitored platforms, `eval_leave` marks the same poison bit and raises
  the host CRuby error directly
  ([`eval_unmonitored.c` lines 5-17](https://github.com/Shopify/mruby-engine/blob/db03e6b14b879f821e9691c7e89267080480397c/ext/mruby_engine/eval_unmonitored.c#L5-L17)).

**Source-based inference:** because neither path raises through mruby's guest
exception machinery, guest `rescue` cannot catch the quota error. On Linux,
`pthread_exit` leaves from the hook rather than asking the mruby VM to unwind;
the only registered cleanup shown here is the pthread completion notifier.
Guest `ensure` blocks therefore appear to be bypassed as well. Shopify has no
quota/rescue/ensure spec, so the `ensure` statement should be treated as an
inference from control flow, not a tested contract.

Ordinary guest exceptions take a different path: after evaluation, the engine
reads `mrb->exc`, builds a host runtime error and guest backtrace, and clears
the pending guest exception
([`mruby_engine.c` lines 92-123](https://github.com/Shopify/mruby-engine/blob/db03e6b14b879f821e9691c7e89267080480397c/ext/mruby_engine/mruby_engine.c#L92-L123)).
The monitored evaluator only reads that guest exception if no quota/system
error was already produced
([`eval_monitored.c` lines 216-228](https://github.com/Shopify/mruby-engine/blob/db03e6b14b879f821e9691c7e89267080480397c/ext/mruby_engine/eval_monitored.c#L216-L228)).

### State after exhaustion; reset and reuse

Every instruction, memory, or explicit stack-limit exit passes through
`eval_leave`, which sets the single `quota_error_raised` bit
([`eval_monitored.c` lines 231-235](https://github.com/Shopify/mruby-engine/blob/db03e6b14b879f821e9691c7e89267080480397c/ext/mruby_engine/eval_monitored.c#L231-L235)).
The CRuby extension checks that bit before every stateful public operation and
raises `EngineQuotaAlreadyReached`
([`ext.c` lines 94-99](https://github.com/Shopify/mruby-engine/blob/db03e6b14b879f821e9691c7e89267080480397c/ext/mruby_engine/ext.c#L94-L99)).
The mruby heap remains allocated until destruction, but the supported interface
will no longer evaluate, load, inject, or extract values from it.

There is no reset or setter in the public method registration
([`ext.c` lines 402-409](https://github.com/Shopify/mruby-engine/blob/db03e6b14b879f821e9691c7e89267080480397c/ext/mruby_engine/ext.c#L402-L409))
or the C engine interface
([`mruby_engine.h` lines 55-86](https://github.com/Shopify/mruby-engine/blob/db03e6b14b879f821e9691c7e89267080480397c/ext/mruby_engine/mruby_engine.h#L55-L86)).
Calling Ruby `initialize` again destroys the old engine and builds another one
([`ext.c` lines 150-195](https://github.com/Shopify/mruby-engine/blob/db03e6b14b879f821e9691c7e89267080480397c/ext/mruby_engine/ext.c#L150-L195));
that is replacement with a new mruby heap, not a gas reset preserving state.

### Interaction with each operation

| Operation | Instruction accounting | Behavior after sticky quota |
| --- | --- | --- |
| `sandbox_eval(path, source)` | The preflight gate runs first. Parsing/code generation happens in C; `mrb_context_run` executes the resulting bytecode under the hook ([`ext.c` lines 209-228](https://github.com/Shopify/mruby-engine/blob/db03e6b14b879f821e9691c7e89267080480397c/ext/mruby_engine/ext.c#L209-L228), [`eval_monitored.c` lines 53-69](https://github.com/Shopify/mruby-engine/blob/db03e6b14b879f821e9691c7e89267080480397c/ext/mruby_engine/eval_monitored.c#L53-L69)). | `EngineQuotaAlreadyReached` before parsing or execution. |
| `load_instruction_sequence(iseq)` | Reads the irep, builds a proc, and sends it through the same evaluator/hook ([`mruby_engine.c` lines 281-295](https://github.com/Shopify/mruby-engine/blob/db03e6b14b879f821e9691c7e89267080480397c/ext/mruby_engine/mruby_engine.c#L281-L295)). | `EngineQuotaAlreadyReached`; covered by specs ([lines 454-487](https://github.com/Shopify/mruby-engine/blob/db03e6b14b879f821e9691c7e89267080480397c/spec/mruby_engine_spec.rb#L454-L487)). |
| `inject(name, value)` | Converts the supported host scalars/arrays/hashes through direct mruby C value operations, so the intended path executes no guest bytecode ([`value_host.c` lines 47-137](https://github.com/Shopify/mruby-engine/blob/db03e6b14b879f821e9691c7e89267080480397c/ext/mruby_engine/value_host.c#L47-L137), [`mruby_engine.c` lines 297-310](https://github.com/Shopify/mruby-engine/blob/db03e6b14b879f821e9691c7e89267080480397c/ext/mruby_engine/mruby_engine.c#L297-L310)). Allocations still use the bounded engine allocator. | Blocked by the same generic poison gate ([`ext.c` lines 269-279](https://github.com/Shopify/mruby-engine/blob/db03e6b14b879f821e9691c7e89267080480397c/ext/mruby_engine/ext.c#L269-L279)); covered after instruction and memory exhaustion ([spec lines 222-243](https://github.com/Shopify/mruby-engine/blob/db03e6b14b879f821e9691c7e89267080480397c/spec/mruby_engine_spec.rb#L222-L243)). |
| `extract(name)` | Reads the ivar and recursively converts supported mruby values through C operations; there is no evaluator call in this path ([`value_guest.c` lines 12-110](https://github.com/Shopify/mruby-engine/blob/db03e6b14b879f821e9691c7e89267080480397c/ext/mruby_engine/value_guest.c#L12-L110), [`mruby_engine.c` lines 312-330](https://github.com/Shopify/mruby-engine/blob/db03e6b14b879f821e9691c7e89267080480397c/ext/mruby_engine/mruby_engine.c#L312-L330)). | Blocked by the same poison gate ([`ext.c` lines 281-291](https://github.com/Shopify/mruby-engine/blob/db03e6b14b879f821e9691c7e89267080480397c/ext/mruby_engine/ext.c#L281-L291)); covered after instruction and memory exhaustion ([spec lines 317-338](https://github.com/Shopify/mruby-engine/blob/db03e6b14b879f821e9691c7e89267080480397c/spec/mruby_engine_spec.rb#L317-L338)). |
| `stat` | Does not run guest bytecode and does not alter the count. | Deliberately has no poison preflight, so it remains available ([`ext.c` lines 293-325](https://github.com/Shopify/mruby-engine/blob/db03e6b14b879f821e9691c7e89267080480397c/ext/mruby_engine/ext.c#L293-L325)). |

`MRubyEngine::InstructionSequence.new` compiles with
`context->no_exec = TRUE` in a separate temporary engine constructed with
nominal instruction/time quotas
([constants, `mruby_engine.c` lines 21-22](https://github.com/Shopify/mruby-engine/blob/db03e6b14b879f821e9691c7e89267080480397c/ext/mruby_engine/mruby_engine.c#L21-L22),
[construction, lines 340-357](https://github.com/Shopify/mruby-engine/blob/db03e6b14b879f821e9691c7e89267080480397c/ext/mruby_engine/mruby_engine.c#L340-L357)).
Its caller supplies a fixed 4 MiB memory pool
([`ext.c` lines 307-336](https://github.com/Shopify/mruby-engine/blob/db03e6b14b879f821e9691c7e89267080480397c/ext/mruby_engine/ext.c#L307-L336)).
The compiler calls parse/codegen directly rather than entering the evaluator
([`mruby_engine.c` lines 200-258](https://github.com/Shopify/mruby-engine/blob/db03e6b14b879f821e9691c7e89267080480397c/ext/mruby_engine/mruby_engine.c#L200-L258)),
so neither the temporary engine's instruction hook nor its wall-time monitor
constrains compilation; the fixed memory pool is its only configured compiler
resource bound that is actually enforced.

Compilation does not consume the target engine's instruction quota. Execution
is charged when the sequence is loaded.

### Statistics

`stat[:instructions]` is the raw lifetime `instruction_count`
([getter lines 332-350](https://github.com/Shopify/mruby-engine/blob/db03e6b14b879f821e9691c7e89267080480397c/ext/mruby_engine/mruby_engine.c#L332-L350),
[Ruby hash construction lines 293-325](https://github.com/Shopify/mruby-engine/blob/db03e6b14b879f821e9691c7e89267080480397c/ext/mruby_engine/ext.c#L293-L325)).
It starts at zero, becomes nonzero after evaluation, and remains exactly at the
quota after instruction exhaustion
([spec lines 51-102](https://github.com/Shopify/mruby-engine/blob/db03e6b14b879f821e9691c7e89267080480397c/spec/mruby_engine_spec.rb#L51-L102)).
There is no remaining-gas value, current-generation count, exhaustion cause,
or reset count. The same stat hash also exposes allocator information and, on
Linux, CPU time and context-switch data.

### Time, memory, stack, and concurrency

- **Memory:** each engine gets a fixed-capacity mmap-backed `mspace`; allocator
  failure signals a memory quota through the same `eval_leave` poison path
  ([pool creation, lines 18-64](https://github.com/Shopify/mruby-engine/blob/db03e6b14b879f821e9691c7e89267080480397c/ext/mruby_engine/memory_pool.c#L18-L64),
  [pool allocation/destruction, lines 81-98](https://github.com/Shopify/mruby-engine/blob/db03e6b14b879f821e9691c7e89267080480397c/ext/mruby_engine/memory_pool.c#L81-L98),
  [memory error payload, lines 31-40](https://github.com/Shopify/mruby-engine/blob/db03e6b14b879f821e9691c7e89267080480397c/ext/mruby_engine/mruby_engine.c#L31-L40),
  [allocator exit, lines 64-85](https://github.com/Shopify/mruby-engine/blob/db03e6b14b879f821e9691c7e89267080480397c/ext/mruby_engine/mruby_engine.c#L64-L85)).
  Thus memory and instructions are different meters but share one irreversible
  public poison state.
- **Wall time:** on Linux, each eval gets a fresh monotonic deadline and guest
  pthread; timeout asynchronously cancels and joins that thread
  ([`eval_monitored.c` lines 117-215](https://github.com/Shopify/mruby-engine/blob/db03e6b14b879f821e9691c7e89267080480397c/ext/mruby_engine/eval_monitored.c#L117-L215)).
  Unlike `eval_leave`, the timeout branch does not set `quota_error_raised`.
  The public preflight therefore does not deliberately poison an engine after
  `EngineTimeQuotaError`. The repository has no reuse-after-timeout test, so
  safe reuse should not be inferred from the missing bit.
- **Stack:** the instruction hook checks selected send opcodes on monitored
  builds and routes an explicit stack exhaustion through `eval_leave`
  ([`mruby_engine.c` lines 125-169](https://github.com/Shopify/mruby-engine/blob/db03e6b14b879f821e9691c7e89267080480397c/ext/mruby_engine/mruby_engine.c#L125-L169)).
- **Concurrency:** one eval owns one mutable `eval_state`, while the host wait
  releases CRuby's GVL
  ([eval-state initialization, lines 74-107](https://github.com/Shopify/mruby-engine/blob/db03e6b14b879f821e9691c7e89267080480397c/ext/mruby_engine/eval_monitored.c#L74-L107),
  [wait loop, lines 164-171](https://github.com/Shopify/mruby-engine/blob/db03e6b14b879f821e9691c7e89267080480397c/ext/mruby_engine/eval_monitored.c#L164-L171),
  [`host.c` lines 178-184](https://github.com/Shopify/mruby-engine/blob/db03e6b14b879f821e9691c7e89267080480397c/ext/mruby_engine/host.c#L178-L184)).
  **Source-based inference:** there is no same-engine running guard or locking
  around the counter/state initialization, so callers should not treat a
  single engine as concurrently callable. Separate engines can run in
  parallel; the source does not establish safety for overlapping calls on one.

### What Shopify tests, and what it does not

The official specs cover fresh/nonzero/exact-quota instruction stats, the
typed instruction error and message, instruction exhaustion through both eval
and instruction-sequence load, and the sticky gate across later eval/load/
inject/extract calls
([stat specs](https://github.com/Shopify/mruby-engine/blob/db03e6b14b879f821e9691c7e89267080480397c/spec/mruby_engine_spec.rb#L51-L102),
[eval specs](https://github.com/Shopify/mruby-engine/blob/db03e6b14b879f821e9691c7e89267080480397c/spec/mruby_engine_spec.rb#L356-L433),
[load specs](https://github.com/Shopify/mruby-engine/blob/db03e6b14b879f821e9691c7e89267080480397c/spec/mruby_engine_spec.rb#L436-L488)).

There are no official specs for quota reset/refill, guest `rescue` or `ensure`
during quota exhaustion, reuse after wall-time cancellation, concurrent calls
on one engine, or cumulative accounting split across several successful evals.
The absence matches the interface: reset is not a supported capability.

### What base mruby actually supplies

Current upstream mruby exposes an optional `code_fetch_hook` on `mrb_state` and
invokes it from the VM dispatcher
([`mruby.h` lines 392-395](https://github.com/mruby/mruby/blob/41e6b6c7095954b2399dca744375f7993944a802/include/mruby.h#L392-L395),
[`vm.c` lines 1635-1672](https://github.com/mruby/mruby/blob/41e6b6c7095954b2399dca744375f7993944a802/src/vm.c#L1635-L1672)).
It does not own Shopify's `instruction_count`, `instruction_quota`, or poison
bit; those live in Shopify's wrapper. `mruby-zig` likewise owns its meter above
the optional hook.

The similarly named `mrb_task_reset_context` is not a gas reset. Its source
rewinds a Task's call-info pointer and changes its status back to
`MRB_TASK_CREATED`
([`task.c` lines 1739-1756](https://github.com/mruby/mruby/blob/41e6b6c7095954b2399dca744375f7993944a802/mrbgems/mruby-task/src/task.c#L1739-L1756)).
It touches no instruction allowance. This distinction explains the earlier
confusion: base mruby provides the execution hook and, in the optional Task
gem, context reuse; a sandbox library still has to define gas ownership,
renewal, termination, and statistics itself.

## Interface designs considered

All three designs use the existing interpreter hook. They differ at the
host-facing **Seam** where a new gas generation is authorized.

### Design A — explicit `resetGas`

```zig
pub fn resetGas(iso: *Isolate, instructions: u64) !void;
```

`resetGas` replaces the current allowance on an idle Isolate. It may recover
from gas exhaustion but never from external termination, deadline, memory, or
call-depth termination. It supports a different amount for every host turn and
adds only one Interface entry.

Its cost is a two-operation protocol: callers must reset and then invoke, must
remember to do so on every intended turn, and can leave an Isolate rearmed
without starting work. The implementation can make the race with
`terminate()` safe, but the caller-visible ordering remains manual. This is the
best minimal advanced Interface if dynamic budgets become a demonstrated need.

### Design B — policy-scoped generations (recommended)

```zig
pub const GasPolicy = union(enum) {
    unlimited,
    per_isolate: u64,
    per_execution: u64,
};
```

The existing `run`, `runImage`, and `call` Interface does not change.
`.per_execution = N` starts a fresh generation at every admitted outermost entry;
`.per_isolate = N` installs one lifetime generation; nested host-callback
re-entry always joins the active generation. The fixed policy turns renewal
into an invariant of the `Isolate` Module rather than a caller protocol.

This has the greatest **Depth** for the common sandbox-worker use case: one
configuration choice hides renewal ordering, unwind cleanup, nested-entry
rules, and termination races. It also has the best **Locality** because every
execution form crosses the existing private `bracketed` implementation. Its
intentional limitation is that one Isolate cannot choose a different amount
for each outermost call without a later advanced Interface.

### Design C — option-bearing execution grants

```zig
try iso.callWith(receiver, "perform", args, .{
    .gas = .{ .start = .{ .instructions = 25_000 } },
});
```

This atomically couples a dynamic grant to work and can deliberately continue
one grant across several entries. It removes the reset/invoke gap and is the
most flexible design. The cost is three parallel option-bearing methods
(`runWith`, `runImageWith`, and `callWith`), more ordering/error semantics, and
a wider Interface that every caller must navigate. Its full design is retained
later in this note as a future extension candidate.

| Criterion | A: `resetGas` | B: policy scope | C: execution grants |
| --- | --- | --- | --- |
| Common fixed per-request budget | Caller repeats reset | Automatic | Caller supplies options |
| Dynamic budget per request | Yes | No | Yes |
| Share one grant across outer entries | Yes | Only `.per_isolate` | Yes |
| Reset/invoke ordering | Two public calls | One private entry transition | One public call |
| Added execution methods | None | None | Three |
| Compatibility with current lifetime behavior | Explicit reset changes it | `.per_isolate` preserves it | Existing methods preserve it |
| Interface Depth and Locality | Good | Best | Good, but wider |

Recommendation: ship Design B first. It handles the motivating stateful-worker
case with no new lifecycle call, preserves the current security posture by
default, and leaves A additive if variable grants are later needed. Design C
is a standalone alternative as written: revisiting it would require reconciling
its `GasStats` type and explicit grant precedence with automatic policy epochs.

## Recommended design: policy-scoped execution epochs

### Public Interface

Keep gas with the other resource limits. During a compatibility release, add
the optional `gas` field and retain `instructions` as the legacy spelling:

```zig
pub const GasPolicy = union(enum) {
    unlimited,
    /// One cumulative allowance for the Isolate. Exhaustion is sticky.
    per_isolate: u64,
    /// A fresh allowance for each admitted outermost run/runImage/call.
    per_execution: u64,
};

pub const Limits = struct {
    /// Deprecated compatibility field; maps to `.per_isolate = value`.
    instructions: ?u64 = null,
    /// Null means derive from `instructions` during the migration window.
    gas: ?GasPolicy = null,
    wall_time_ns: ?u64 = null,
    memory_bytes: ?usize = null,
    hard_memory_bytes: ?usize = null,
    call_depth: ?u32 = null,
};

pub const GasScope = enum { isolate, execution };

pub const GasStats = struct {
    scope: GasScope,
    generation: u64,
    limit: u64,
    used: u64,
    remaining: u64,
    /// True only if a later fetch observed the empty allowance.
    exhausted: bool,
    /// All hook visits in the generation, including bounded delivery work.
    /// Wider than `limit` so maxInt(u64) + the failing fetch is representable.
    observed_instructions: u128,
};

pub const Stats = struct {
    /// Saturating lifetime raw hook count; existing values stay source-compatible.
    instructions: u64,
    /// Null for `.unlimited`.
    gas: ?GasStats = null,
    // Existing fields unchanged.
};
```

For finite `.per_isolate`, generation 1 exists at spawn with `used = 0` and
`remaining = limit`; capability bytecode and all later entries join it. For
finite `.per_execution`, `stats().gas` before the first request reports the
prospective generation 0 snapshot: `used = 0`, `remaining = limit`,
`exhausted = false`, and `observed_instructions = 0`. Actual request
generations start at 1.

A preflight or bootstrap failure before generation 1 leaves generation 0
observable; a later preflight rejection leaves the last completed generation
snapshot intact. Only `.unlimited` reports `gas = null`.

If both transitional fields are set, `spawn` returns
`error.ConflictingGasPolicy` rather than guessing. If only
`Limits.instructions = N` is set, resolve it to `.per_isolate = N`; existing
callers remain lifetime-limited and sticky. In the next breaking release,
remove `instructions`, make `gas: GasPolicy = .unlimited`, and remove the
nullable migration state.

Resolve and cache that choice in a private immutable `resolved_gas` field at
spawn. Entry and hook code must never reread the publicly reachable
`iso.policy.limits.instructions`/`gas` fields; post-spawn mutation must not
change scope, bypass conflict validation, or alter a running meter.

No `resetGas`, public `GasMeter`, execution token, or Adapter is needed for the
first implementation. There is one in-process implementation and one existing
execution Seam.

### Example usage

```zig
const std = @import("std");
const mruby = @import("mruby");

const iso = try mruby.sandbox.Isolate.spawn(.{
    .limits = .{
        .gas = .{ .per_execution = 20_000 },
    },
});
defer iso.deinit();

_ = try iso.run("$value = 40; $cleaned = false");

if (iso.run(
    \\begin
    \\  $value += 1
    \\  i = 0
    \\  while i < 1_000_000_000
    \\    i += 1
    \\  end
    \\ensure
    \\  $cleaned = true
    \\end
)) |_| {
    return error.ExpectedGasExhausted;
} else |err| switch (err) {
    error.GasExhausted => {},
    else => return err,
}

const exhausted = iso.stats().gas.?;
std.debug.assert(exhausted.exhausted);
const exhausted_generation = exhausted.generation;

// The previous invocation unwound. This outermost entry automatically gets
// a fresh 20,000, while the same Ruby heap and its partial mutations survive.
const value = try iso.run("[$value, $cleaned]");
_ = value;

const renewed = iso.stats().gas.?;
std.debug.assert(renewed.generation == exhausted_generation +| 1);
std.debug.assert(!renewed.exhausted);
std.debug.assert(renewed.used <= renewed.limit);
```

This is state preservation, not rollback: `$value` and the completed `ensure`
mutation survive. The loop itself is not resumed.

### Error diagnostics must be inert

Today `Isolate.lastError()` returns the general-purpose `RubyError` over a raw
exception value
([`sandbox.zig` lines 381-404](https://github.com/nullstyle/mruby-zig/blob/f772fc1d7ff1c68f75b209b67a2e09d5801cede7/src/sandbox.zig#L381-L404)).
Its `message()` calls guest-overridable `exc.to_s`; `className()` calls
`exc.class` and then `to_s`, all through `mrb_funcall`
([`error.zig` lines 7-53](https://github.com/nullstyle/mruby-zig/blob/f772fc1d7ff1c68f75b209b67a2e09d5801cede7/src/error.zig#L7-L53)).
Those calls are protected from a C longjmp, but they are not inside the
sandbox's execution bracket. With renewable gas, invoking either method after
an epoch returns could therefore run hostile Ruby with no active generation,
mutate the heap, latch the completed meter, and corrupt the stats snapshot.

Make sandbox diagnostics an inert, rooted metadata view:

1. Preserve the public `RubyError` type and the current caller-owned return
   values of `message()` and `className()`. Add an internal inert
   representation; unrestricted `Vm.lastError()` may keep its live behavior,
   while `Isolate.lastError()` constructs the same public type from cached
   pointer/length views. Its methods duplicate those bytes through the host
   allocator only and never call mruby.
2. Add a small layout-safe shim accessor for exception metadata. This project
   pins mruby 4.0.0
   ([`build.zig.zon` lines 16-20](https://github.com/nullstyle/mruby-zig/blob/f772fc1d7ff1c68f75b209b67a2e09d5801cede7/build.zig.zon#L16-L20)),
   where `RException` stores the normalized message directly in its `mesg`
   field
   ([`error.h` lines 16-21](https://github.com/mruby/mruby/blob/831da26b9021de0369d17b71b5667e2941a1a32d/include/mruby/error.h#L16-L21));
   the core setter/getter show that this is a string-or-null value
   ([`error.c` lines 18-32](https://github.com/mruby/mruby/blob/831da26b9021de0369d17b71b5667e2941a1a32d/src/error.c#L18-L32)).
   Resolve the exception's real class by walking past singleton/include
   classes, then read its cached `__classname__` symbol/string directly
   ([real-class traversal, `class.c` lines 2905-2927](https://github.com/mruby/mruby/blob/831da26b9021de0369d17b71b5667e2941a1a32d/src/class.c#L2905-L2927),
   [cached path, lines 2869-2903](https://github.com/mruby/mruby/blob/831da26b9021de0369d17b71b5667e2941a1a32d/src/class.c#L2869-L2903)).
   Use a fixed `"<anonymous exception>"` fallback. The shim must perform no
   method dispatch and no mruby allocation; in particular, it must not call
   `mrb_obj_as_string`, `mrb_class_path`, or backtrace conversion.
3. At `spawn`, create a private one-element array, fill it with `nil`, and
   register that array as a GC root while bootstrap allocation is already
   charged to the Isolate. For an ordinary final `RubyException`, first
   arbitrate policy causes, place the exception into the preallocated slot, and
   cache only the shim's pointer/length views while `mrb->exc` still roots it.
   Replace element zero through the verified existing-index `mrb_ary_set` path
   (or an equivalent shim) so the write remains allocation-free **and** runs
   mruby's GC field-write barrier; a raw pointer write is forbidden. Then clear
   `mrb->exc`.
   With no stored message, use the class-name view as the message, matching the
   core `Exception#to_s` fallback
   ([`error.c` lines 94-114](https://github.com/mruby/mruby/blob/831da26b9021de0369d17b71b5667e2941a1a32d/src/error.c#L94-L114)).
   Recheck termination bits afterward; if a policy cause raced in, clear the
   root/views and return that policy error without exposing its private
   exception.
4. Replace the root slot with `nil` and clear the views at the next outermost
   entry; nested entry does not invalidate them. `mrb_close` owns final root
   destruction. This adds constant automatic memory rather than copying an
   unbounded guest-controlled message outside `IsolateCell`. The existing
   `message()`/`className()` host allocation happens only when trusted host code
   explicitly requests a caller-owned copy; its failure retains today's empty
   best-effort result and cannot reclassify the sandbox error or set sandbox
   OOM. The “valid until the next run” lifetime remains unchanged.

This deliberately stops honoring a sandbox exception's overridden `to_s`,
`class`, or class `to_s` during host diagnostics. The stored exception message
and real cached class path are the security-stable contract. The unrestricted
`Vm` Interface can retain its current Ruby-dispatched diagnostics because it
does not claim sandbox gas isolation.

### Contract and invariants

1. An **execution** is the outermost `run`, `runImage`, or `call`. A nested
   entry from a Zig-backed Ruby method shares the active generation and never
   refills gas.
2. `.per_execution = N` authorizes a new N-unit generation only after the
   previous outermost call has completely returned through the protected frame.
   `rescue`, `ensure`, and nested callbacks cannot manufacture generations.
3. `.per_isolate = N` preserves today's behavior: capability bytecode and all
   executions share the remaining allowance, and observed exhaustion
   permanently terminates the Isolate.
4. The last available unit is charged and its opcode may execute. Exhaustion
   becomes observed only on the next fetch. Under today's delivery ordering,
   that detecting opcode also executes uncharged because the hook arms deferred
   delivery after its delivery check has already passed. A program that ends
   exactly at zero may succeed with `remaining == 0` and
   `exhausted == false`.
5. A zero limit admits no charged instruction. Because `mruby-zig` deliberately
   delivers termination through guest unwinding, the first fetched opcode still
   executes as uncharged detection work and may mutate guest state. Additional
   bounded catchability/handler instructions may also execute.
6. `GasStats.used` never exceeds `limit`; `remaining + used == limit`.
   `observed_instructions` and lifetime `Stats.instructions` include bounded
   uncharged detection/delivery work and may exceed charged gas. A surfaced
   gas-only exhaustion has
   `observed_instructions >= @as(u128, limit) + 1`, including when `limit` is
   `maxInt(u64)`. The generation counter is maintained independently as a
   saturating `u64`; it must not be derived by subtracting two possibly
   saturated lifetime counters. The public lifetime counter and diagnostic
   generation ID both saturate instead of wrapping or trapping.
7. `GasExhausted` is recoverable only for `.per_execution`. External
   termination, deadline, memory, call depth, and `.per_isolate` exhaustion
   remain sticky.
8. A fresh generation preserves the heap, globals, loaded code, capabilities,
   allocator accounting, deadline, and lifetime/peak statistics. It never
   resumes the unwound computation and never promises transactionality.
9. A guest-raised `MRubyZigSandbox::GasExhausted` remains an ordinary
   `RubyException`; private meter state remains authoritative.
10. Only `terminate()` and `pendingTermination()` are cross-thread safe.
    Execution methods remain caller-serialized. A racing `terminate()` can
    never be cleared by gas cleanup.
11. `pendingTermination()` is true while gas termination is being delivered.
    After a `.per_execution` call fully returns and gas-only cleanup completes,
    it becomes false unless a non-gas cause is also present. It remains true
    after `.per_isolate` exhaustion or any non-gas termination.
12. Gas still measures bytecode fetches, not time inside long C-native methods
    or uncooperative host callbacks. Deadline, memory, and cooperative polling
    remain necessary companions.
13. `Isolate.lastError()`, including `message()` and `className()`, executes no
    guest code, starts no generation, and leaves lifetime and generation stats
    unchanged. Policy termination never appears as a sandbox `RubyError`.

### Hidden state and termination arbitration

The current `{ terminate_flag, pending_kind }` pair is a last-writer-wins
protocol. It cannot safely be reset: a concurrent `terminate()` can store
`.script` between a gas check and a later `terminate_flag = false`, losing the
host request. Refactor this before making gas renewable.

Use an internal atomic termination bitset, with one bit per cause:

```zig
const term_gas: u8        = 1 << 0;
const term_script: u8     = 1 << 1;
const term_deadline: u8   = 1 << 2;
const term_memory: u8     = 1 << 3;
const term_call_depth: u8 = 1 << 4;

termination_bits: std.atomic.Value(u8);
```

`noteTerm` and `terminate()` use `fetchOr`; reads use acquire ordering. Clearing
the gas bit with `fetchAnd(~term_gas, .acq_rel)` commutes with a concurrent OR
of any other bit, so gas cleanup cannot erase external termination. If several
causes are present, use and document one deterministic priority; the
recommended order is memory, script, deadline, call depth, then gas. Non-gas
causes always outlive an execution epoch.

Group the owner-thread execution fields in a private record:

```zig
const Phase = enum { idle, preparing, running };
const CapabilityState = enum { pending, ready, failed };

const ExecutionState = struct {
    phase: Phase = .idle,
    capabilities: CapabilityState = .pending,
    generation: u64 = 0,
    /// Independent generation hook count; do not derive from lifetime stats.
    observed_instructions: u128 = 0,
    gas_limit: ?u64 = null,
    gas_remaining: u64 = 0,
    gas_used: u64 = 0,
    gas_exhausted: bool = false,
    /// Published generation 0 or last completed epoch;
    /// live state wins while running.
    last_gas: ?GasStats = null,
    handler_grace: u64 = 0,
    grace_armed: bool = false,
    raise_pending: bool = false,
    uncovered_waits: u32 = 0,
};
```

`stats()` reads committed live fields while `.running`; otherwise it reads
`last_gas`. Provisional entry state is never observable and never overwrites
the generation 0/last-completed snapshot.

The hook increments the lifetime `u64` with saturating addition and, when a
finite generation is active, increments its independent `u128` observed count
with saturating addition. This closes the `maxInt(u64)` boundary: the fetch
that first observes an empty maximum-sized allowance is still representable.

`Phase` replaces the ambiguous boolean running guard: nested entry joins only
while `.running`; entry attempted while `.preparing` fails. Capability setup
sets `ready` only after all steps succeed. An ordinary setup failure sets
`failed` permanently, so a partially stripped/frozen Isolate can never proceed;
later entries re-report `CapabilityApplicationFailed`.

The private outer-entry sequence is:

1. Drop the previous inert error root/views. Initialize the non-resettable
   wall-time start/deadline on the first outer entry, before preparation, and
   update elapsed time across the whole lifecycle. Acquire allocator OOM state,
   OR `term_memory` if necessary, poll the deadline, and reject any sticky
   non-gas termination. Thus any new outer-entry attempt makes a stale
   `lastError()` unavailable even when preflight rejects the attempt.
2. For `.per_isolate`, reject a sticky gas bit before capability work. Then
   switch explicitly on capability state: `ready` continues; `failed` returns
   `CapabilityApplicationFailed`; `pending` enters `.preparing` and runs the
   existing one-time setup with its own allocator TLS bracket. Restore phase to
   `.idle` on every preparation exit. `.per_isolate` retains today's
   accounting and charges any setup bytecode to its lifetime generation. For
   `.per_execution`, trusted setup is bootstrap work: count any bytecode in
   lifetime `Stats.instructions` and enforce memory, lifetime deadline,
   call-depth, and external termination, but do not charge it to a request
   generation. Set capability state to `ready` only after complete success;
   every incomplete exit sets `failed`. After a failure, authoritative policy
   causes take precedence; otherwise return `CapabilityApplicationFailed`.
3. Reacquire OOM state and poll/recheck authoritative causes after preparation.
   This includes sticky gas for `.per_isolate`, so a limit reached during setup
   is reported before any guest request code. For `.per_execution`, prepare the
   next generation's ID, limit, counters, and delivery fields provisionally and
   clear only the gas bit. Do not replace the published last-completed snapshot
   or commit the generation yet.
4. Recheck non-gas bits so a racing `terminate()` is observed before guest work.
   If this rejects, discard the provisional meter and preserve generation 0 or
   the last completed snapshot. Otherwise commit the generation and make its
   live stats observable. A termination arriving after that commit belongs to
   the now-started generation and remains sticky through its finalization.
5. Mark the Isolate `.running` and install one outer finalizer that runs for
   success, ordinary Ruby errors, policy errors, and unrelated Zig errors. In
   order, it snapshots the live `GasStats`, clears only per-execution gas and
   delivery residue after the protected body has fully unwound, and finally
   restores phase to `.idle`. Never clear another cause.
6. Perform the requested body under the main allocator/protection bracket. Do
   not nest `enterIsolate`: preparation has already left its own bracket, or
   the allocator API must first be changed to save and restore a previous cell.
7. Map the result using authoritative termination bits before the finalizer
   runs. For an ordinary `RubyException`, capture the inert rooted error view
   described above; recheck termination afterward and never publish an
   internal policy exception through `lastError`.

Make the allocator cell's OOM state atomic (one atomic enum/bitset is enough),
and have the allocator publish soft/hard failure when it occurs. Both outer
preflight and `mapError` must acquire that state and OR `term_memory` before
returning. `pendingTermination()` reads only atomic termination/OOM state, never
the current non-atomic `cell.hard_oom` field. Gas renewal must therefore never
begin after an allocation failure merely because no later bytecode fetch had a
chance to call `noteTerm(.memory)`.

The hook keeps today's ensure-preserving order: charge at most one unit per
admitted fetch, latch gas when a later fetch observes zero, execute that
detecting opcode uncharged, and use the existing bounded catchability and
handler-grace protocol. This differs from Shopify's immediate out-of-band exit
but preserves this library's guest `ensure` contract. No mruby patch is
required; the inert-error rule adds one narrow layout-safe shim accessor.

## Alternative C in detail: option-bearing gas grants on execution

This section retains the strongest rejected alternative for comparison. It is
not an additive API on top of the recommendation as currently written: its
explicit `.start`/`.continue_current` lifecycle and `GasStats` definition would
need one precedence rule and one shared type model before coexistence with
automatic `.per_execution` epochs.

### Current seam and the change we actually need

At `mruby-zig` HEAD
[`f772fc1d7ff1c68f75b209b67a2e09d5801cede7`](https://github.com/nullstyle/mruby-zig/commit/f772fc1d7ff1c68f75b209b67a2e09d5801cede7),
`Isolate` owns `instr_count`, `gas_remaining`, the general termination atomics,
and several fields that make termination un-suppressible
([`src/sandbox.zig` lines 147-185](https://github.com/nullstyle/mruby-zig/blob/f772fc1d7ff1c68f75b209b67a2e09d5801cede7/src/sandbox.zig#L147-L185)).
The fetch hook counts, detects limits, defers a raise until mruby can run its
handlers, grants bounded handler grace, and decrements gas
([lines 572-664](https://github.com/nullstyle/mruby-zig/blob/f772fc1d7ff1c68f75b209b67a2e09d5801cede7/src/sandbox.zig#L572-L664)).
The outer bracket permanently rejects any later operation once the general
termination flag is set
([lines 336-375](https://github.com/nullstyle/mruby-zig/blob/f772fc1d7ff1c68f75b209b67a2e09d5801cede7/src/sandbox.zig#L336-L375)).

Changing only `gas_remaining` would leave `terminate_flag`, `pending_kind`,
`handler_grace`, `grace_armed`, `raise_pending`, and `uncovered_waits` armed.
It could also erase an external `terminate()` racing with a reset. The correct
**Seam** is entry into host-authorized execution. This design makes a new gas
generation an option on `run`, `runImage`, or `call`, so “reset” and “start the
next invocation” are one ordered operation rather than two host calls.

### Module, Interface, and Depth

This alternative's **Module** is `sandbox.Gas`. Its **Interface** adds shared
execution options and option-bearing variants of the three execution methods:

```zig
pub const GasBudget = union(enum) {
    unlimited,
    instructions: u64,
};

pub const GasGrant = union(enum) {
    /// Use the generation already installed on the Isolate.
    continue_current,
    /// Replace it immediately before this outermost invocation.
    start: GasBudget,
};

pub const ExecutionOptions = struct {
    gas: GasGrant = .continue_current,
};

pub const GasStats = struct {
    generation: u64,
    limit: ?u64,
    consumed: u64,
    remaining: ?u64,
    exhausted: bool,
};

pub const Stats = struct {
    // Existing lifetime raw fetch count, including termination overhead.
    instructions: u64,
    gas: GasStats,
    // ...existing fields unchanged...
};

pub fn runWith(
    iso: *Isolate,
    src: []const u8,
    options: ExecutionOptions,
) !Value;

pub fn runImageWith(
    iso: *Isolate,
    image: []const u8,
    options: ExecutionOptions,
) !Value;

pub fn callWith(
    iso: *Isolate,
    recv: Value,
    name: []const u8,
    args: anytype,
    options: ExecutionOptions,
) !Value;
```

Existing `run`, `runImage`, and `call` stay source-compatible and forward with
`.gas = .continue_current`. `Limits.instructions` defines generation zero:
`null` maps to `.unlimited`, a value to `.instructions = value`. `0` is valid;
the first fetch observes an empty allowance, although bounded delivery work may
still execute to preserve the `ensure` contract.

This favors flexibility over the smallest possible surface. One caller can
give every request a fresh grant with `.start`, while another can start once
and use `.continue_current` across a `runImage` plus several `call`s. The
**Depth** comes from one private entry implementation behind all three wrappers:
it hides generation accounting, termination-cause separation, handler-state
cleanup, and the race with `terminate()`. That creates **Leverage** across all
execution forms and **Locality** for security fixes. Deleting the Module would
push ordering and cleanup back into every host call site, so it passes the
deletion test even though the three typed convenience methods mirror existing
entry points.

### Interface invariants, ordering, and errors

1. **A grant is installed only at the outermost entry.** A nested host callback
   may use `.continue_current`, sharing its caller's generation. Nested
   `.start` fails with `error.IsolateRunning`; callback-sized grants cannot turn
   one hostile invocation into unlimited work.
2. **`start` is replace, not top-up.** It increments `generation`, zeros
   `consumed`, installs the requested limit, and clears gas-only exhaustion.
   It discards any remainder from the prior generation.
3. **The grant precedes all invocation work.** At an outermost call the order is:
   reject irreversible termination; install/continue gas; apply lazy
   capabilities if needed; enter the allocator bracket; parse/load/invoke; map
   errors; publish statistics. Capability setup that executes bytecode is
   therefore charged to the selected generation, as it is to generation zero
   today.
4. **A failed invocation does not roll the grant back.** Syntax errors, ordinary
   `RubyException`, and memory failures leave the newly selected generation and
   its counters observable. This avoids transactional behavior the Interface
   cannot actually guarantee.
5. **One generation may span entry points.** `.continue_current` on `run`,
   `runImage`, `call`, and nested execution all uses the same remaining gas.
   There is no implicit reset on success.
6. **Lifetime and generation statistics differ.** `Stats.instructions` remains
   monotonic for the Isolate and counts every fetch, including bounded
   catchability waits and handler/unwind work. `GasStats.consumed` counts only
   instructions admitted by the current generation and never exceeds `limit`.
7. **Empty and exhausted are distinct.** `remaining == 0` becomes
   `exhausted == true` only when guest execution attempts another fetch. This
   distinguishes an exactly consumed grant from an observed `GasExhausted`.
8. **Only gas termination is replaceable.** `.start` is accepted on a healthy
   Isolate or after `GasExhausted` has surfaced and the prior invocation has
   fully unwound. If external termination, deadline, memory, or call-depth
   termination exists, the new call returns that termination error without
   installing the grant.
9. **No continuation is resumed.** A new grant preserves the Ruby heap,
   globals, loaded code, and partial mutations, but starts a new mruby
   invocation. Retrying non-idempotent work is the caller's decision.
10. **External termination cannot be lost.** Gas replacement never writes
    `false` into the atomic non-gas termination state. If `terminate()` races
    after the preflight, the existing before/after-body checks still surface
    `ScriptTerminated` and no later entry can revive it.
11. **Classification remains authoritative.** A guest-raised
    `MRubyZigSandbox::GasExhausted` remains `RubyException`; only the private
    meter authorizes host `error.GasExhausted` and a subsequent `.start`.

### Hidden implementation

Add a private `GasMeter` (preferably `src/gas.zig`, re-exporting only public
types from `sandbox.zig`) with state equivalent to:

```zig
const GasMeter = struct {
    generation: u64 = 0,
    limit: ?u64,
    consumed: u64 = 0,
    remaining: u64 = 0, // meaningful only when limit != null
    exhausted: bool = false,
};
```

It has private `onFetch`, `snapshot`, and `startGeneration` operations.
`onFetch` is allocation-free and either admits/charges one instruction or marks
the generation exhausted. Generation overflow may saturate because it is a
diagnostic identifier, not an authorization token.

Refactor all public execution methods through a private `enterExecution(body,
ctx, options)`. At the outermost level it performs the invariant ordering
above. Nested `.continue_current` takes today's nested path; nested `.start`
fails before changing state. The no-option methods are thin forwards into this
same implementation, not a second code path.

Separate resettable gas exhaustion from irreversible termination:

- Keep the atomic external/non-gas termination state monotonic. Deadline,
  memory, call depth, and `terminate()` set it and a gas grant never clears it.
- Let `GasMeter.exhausted` be the authoritative gas cause. Entry and the hook
  treat `non_gas_termination || gas.exhausted` as pending, with non-gas causes
  taking precedence if both arrive.
- Before `.start`, clear gas-specific `handler_grace`, `grace_armed`,
  `raise_pending`, and `uncovered_waits`, and clear any stale internal
  termination value plus the previous inert error root/views. Do not clear
  allocator or non-gas flags.
- Change `mapError` so a genuine policy termination clears mruby's exception
  without publishing the private termination object through `lastError`;
  ordinary Ruby exceptions are converted to the inert snapshot specified by
  the recommended design before the generation is closed.

Do not change hook delivery merely to copy Shopify. Charge the last available
unit, then observe exhaustion on the next fetch. The catchability wait and
handler grace may execute bounded extra bytecodes after user gas reaches zero;
exclude those from `GasStats.consumed` but retain them in lifetime
`Stats.instructions`. That exposes the cost while preserving `mruby-zig`'s
stronger `ensure` contract.

### Usage

Fresh gas for each stateful request is attached to the request entry itself:

```zig
const std = @import("std");
const mruby = @import("mruby");

const iso = try mruby.sandbox.Isolate.spawn(.{
    .limits = .{
        .instructions = 100_000, // bootstrap generation
        .wall_time_ns = 2 * std.time.ns_per_s, // never reset by gas
    },
});
defer iso.deinit();

const top = try iso.run(
    \\def quote(cents)
    \\  cents * 2
    \\end
    \\self
);

for (jobs) |cents| {
    const result = iso.callWith(
        top,
        "quote",
        .{cents},
        .{ .gas = .{ .start = .{ .instructions = 25_000 } } },
    ) catch |err| switch (err) {
        error.GasExhausted => {
            // The invocation has unwound; do not blindly retry work that
            // may have made partial mutations.
            continue;
        },
        else => return err,
    };
    consume(try result.asInt());
}
```

A caller can deliberately share one grant across setup and calls:

```zig
const receiver = try iso.runImageWith(
    image,
    .{ .gas = .{ .start = .{ .instructions = 100_000 } } },
);
const result = try iso.call(receiver, "perform", .{input}); // continues it
```

After exhaustion, the next `.start` both replaces gas and enters a new call on
the same heap:

```zig
if (iso.runWith(
    "$started = true; while true; end",
    .{ .gas = .{ .start = .{ .instructions = 1_000 } } },
)) |_| {
    return error.ExpectedGasExhausted;
} else |err| switch (err) {
    error.GasExhausted => {},
    else => return err,
}

const started = try iso.runWith(
    "$started",
    .{ .gas = .{ .start = .{ .instructions = 10_000 } } },
); // true: same heap, new invocation
```

### Dependency strategy

Implement this directly in the existing in-process `Isolate` and instruction
hook. Only one implementation exists at this Seam, so an Adapter or abstract
meter Interface would be hypothetical and would make the Module shallower. The
gas meter itself needs only the per-instruction hook already exposed by the C
shim. Independently, the inert-error contract requires the narrow metadata
accessor described above. If a worker-process tier later becomes real, its
protocol can carry `ExecutionOptions`, `GasStats`, and inert error metadata;
that second implementation is the right time to consider a real Adapter.

### Implementation sequence if this alternative is chosen

1. Add characterization tests for current cumulative accounting, shared gas
   across `run`/`runImage`/`call`, post-exhaustion unwind, and permanent non-gas
   termination.
2. Introduce `GasBudget`, `GasGrant`, `GasStats`, and private `GasMeter`; map
   `Limits.instructions` into generation zero without changing existing calls.
3. Consolidate execution in private `enterExecution`, then add the three
   option-bearing wrappers and forward existing methods with default options.
4. Refactor the fetch hook through `GasMeter` while preserving catchability and
   handler grace; keep `Stats.instructions` as the saturating lifetime raw
   count.
5. Separate gas exhaustion from irreversible termination and update entry,
   `pendingTermination`, and `mapError` with one documented precedence.
6. Add `Stats.gas`, README examples, and the state-preservation/non-resumption
   warning.

### Verification matrix if this alternative is chosen

- Generation accounting for grants `0`, `1`, and a larger deterministic loop;
  `consumed <= limit` and `remaining + consumed == limit`.
- `.start` on each of `runWith`, `runImageWith`, and `callWith`; then a mixed
  sequence using `.continue_current` to prove shared consumption.
- A healthy `.start` replaces a nonzero remainder and increments `generation`.
- A post-`GasExhausted` `.start` runs on the same heap with globals/methods
  intact; the interrupted invocation is not resumed.
- Syntax/Ruby errors after `.start` leave the selected generation observable
  rather than rolling it back.
- Nested `.continue_current` shares gas; nested `.start` from a callback returns
  `IsolateRunning` without changing counters or granting a grace window.
- Repeated exhaust/start cycles cannot re-arm more than one bounded handler
  grace per generation; `ensure` completes and hostile `rescue` remains bounded.
- Lifetime `Stats.instructions` includes termination overhead while generation
  consumption stays within its configured limit.
- External `terminate()`, deadline, soft/hard memory, and call-depth termination
  all reject `.start` and retain their existing errors.
- A `.start` racing with `terminate()` never loses `ScriptTerminated` (stress
  under ThreadSanitizer where supported).
- Ordinary `RubyException` and a forged hidden `GasExhausted` class cannot
  authorize reset.
- `.unlimited` works after real gas exhaustion while lifetime instruction stats
  continue increasing.
- Long native C operations remain outside gas and rely on deadline, memory, or
  cooperative host behavior.

### Tradeoffs

- This is wider than a single `resetGas` method: all three execution forms gain
  option-bearing variants. The payoff is atomic ordering—there is no public
  interval in which gas has been reset but no invocation has started—and a
  single type supports both per-request and shared multi-call grants.
- Stateful reuse preserves loaded code and partial mutations. The Interface
  promises neither transactionality nor continuation resumption.
- Starting generations converts a lifetime gas bound into a host-controlled
  bound. Supervisors requiring a true lifetime ceiling must also enforce
  `Stats.instructions` and/or the non-resettable deadline.
- Handler/unwind overhead outside `GasStats.consumed` means gas measures
  admitted work, not all post-termination bytecodes. Lifetime stats retain the
  audit number; this is the cost of keeping `ensure` behavior.
- `.unlimited` is powerful but host-only, equivalent to the existing authority
  to spawn an unlimited Isolate.
- The private termination split is more work than assigning a counter, but it
  concentrates the race and cleanup rules in one Module, increasing Depth and
  Locality instead of exporting them to callers.

## Recommended delivery plan

The implementation should land as a sequence of behavior-preserving steps.
The termination refactor is deliberately first; adding renewal while the cause
and pending flag are separate atomics would create a security-sensitive lost
termination race.

### Phase 1 — characterize and make termination monotonic

1. Add characterization tests for exact gas admission, the empty-versus-
   exhausted edge, shared lifetime gas across all three entry points, bounded
   `rescue`/`ensure`, and permanent non-gas termination.
2. Replace `terminate_flag` plus `pending_kind` with the atomic cause bitset.
   Make `noteTerm`/`terminate` OR causes and centralize deterministic cause
   selection.
3. Make the allocator cell's OOM publication atomic and fold it into the same
   monotonic memory cause. Make preflight, `pendingTermination()`, and error
   mapping read only atomic termination/OOM state.
4. Keep public behavior unchanged: legacy instruction exhaustion remains
   sticky and later entries execute zero bytecode.

Exit criterion: all existing tests plus the new characterization tests pass in
Debug and ReleaseSafe, including the current “terminated isolate refuses
further runs” regression.

### Phase 2 — separate lifetime and generation accounting

1. Introduce the private execution/gas state and route the fetch hook through
   allocation-free charge/observe operations.
2. Preserve `Stats.instructions` as the source-compatible `u64` lifetime raw
   hook count, but make its increment saturating. Maintain the generation's
   `u128 observed_instructions` independently rather than as a delta from the
   lifetime value.
3. Add `GasStats` and verify `used <= limit`, `used + remaining == limit`, and
   that observed hook work exposes termination overhead without charging it.
   Define and test finite `.per_execution` generation 0 before any request or
   after terminal bootstrap failure. Unit-test the meter just below
   `maxInt(u64)` to prove the maximum limit plus its failing fetch neither wraps
   nor traps; executing that many VM instructions is unnecessary.
4. Continue resolving every existing `Limits.instructions` caller to one
   `.per_isolate` generation; no renewal is enabled yet.

Exit criterion: legacy behavior and source usage are unchanged, while stats can
unambiguously answer lifetime count, generation use, remaining gas, and whether
exhaustion was actually observed.

### Phase 3 — add policy-scoped epochs at the outer-entry Seam

1. Add transitional `Limits.gas` and the conflict check.
2. Consolidate `prepare`, `run`, `runImage`, and `call` under one private
   outer-entry lifecycle with explicit idle/preparing/running phases. Keep
   preparation in its own non-nested allocator bracket, make failure terminal,
   and preserve the nested running path as “join current epoch.”
3. Add the preallocated error root plus allocation-free metadata shim, and make
   ordinary Ruby diagnostics inert while gas is still legacy-sticky. Keep
   `Isolate.lastError()` on the existing public `RubyError` type, but make its
   sandbox representation operate on cached byte views only.
4. Only after inert diagnostics are in place, implement `.per_execution`
   initialization and post-unwind gas-only cleanup. Clear no non-gas cause,
   deadline, allocator flag, capability, or lifetime statistic.
5. Snapshot the completed epoch before cleanup so `stats()` after
   `GasExhausted` remains informative.
6. Make generation numbering saturate at `maxInt(u64)`; it is diagnostic and
   must never become an authorization token.

Exit criterion: two sequential outer executions can each use N gas even when
their combined work exceeds N, but nested re-entry cannot acquire a second
grant.

### Phase 4 — adversarial verification

Add Interface-level tests for:

- `.per_execution` success, exact exhaustion, and zero gas;
- `GasExhausted` followed by successful `run`, `runImage`, and `call` on the
  same heap;
- globals, loaded methods, partial mutations, and completed `ensure` effects
  surviving without resuming the interrupted computation;
- nested Zig callback re-entry sharing the outer budget;
- hostile `rescue` remaining bounded once per epoch, with no grace leakage
  between epochs;
- ordinary `RubyException` and a forged guest `GasExhausted` class not
  authorizing host recovery;
- an ordinary exception whose `to_s`, `class`, and class `to_s` loop, mutate
  globals, or raise. Repeated `lastError().message()`/`className()` calls must
  return the stored metadata while executing zero bytecodes, starting no
  generation, changing no gas/lifetime stats, and setting no termination bit;
- inert details preserving embedded NULs and UTF-8, returning cached paths for
  nested classes and the fixed fallback for anonymous classes, surviving
  non-executing observations plus a forced full/incremental GC between capture
  and inspection, and becoming unavailable at the next outer entry;
- policy errors exposing no `lastError`, and failure of an explicit host
  metadata-copy allocation or sandbox soft/hard OOM never changing the
  authoritative host error;
- first-entry lazy capability work consuming the selected generation and
  preserving policy-termination classification for `.per_isolate`;
- `.per_execution` capability bootstrap completing outside the renewable
  request grant, and any bootstrap failure/termination permanently preventing
  guest execution with a partially applied Policy;
- legacy `.instructions` and explicit `.per_isolate` remaining sticky;
- simultaneous legacy/new configuration returning
  `ConflictingGasPolicy`;
- deadline, memory, call-depth, and external termination remaining permanent;
- termination latched before outer-entry preflight executing zero guest
  bytecodes;
- a barrier-controlled in-flight `terminate()`/gas-cleanup race. The only
  allowed outcomes are that `ScriptTerminated` wins the completed call or
  remains latched for the next entry. Post-request execution may include the
  protocol's documented bounded detection/catchability/grace work, but cleanup
  must not grant a new epoch or clear the script bit;
- independent Isolates and deterministic equivalent executions remaining
  independent/equal;
- long native C work remaining outside the gas guarantee and covered only by
  the documented deadline/memory/cooperative limits.

Use the real embedded VM rather than a fake Adapter. Run Debug and ReleaseSafe;
run the race stress under ThreadSanitizer on a supported toolchain.

### Phase 5 — documentation and migration

1. Update README and CHANGELOG with both scopes and the state-preservation/
   non-resumption warning.
2. Mark `Limits.instructions` deprecated and document its exact
   `.per_isolate` mapping. Do not silently make old callers renewable.
3. In the next breaking release, remove `instructions`, make
   `Limits.gas: GasPolicy = .unlimited`, and retain `.per_isolate` for
   a Shopify-like fixed cumulative scope, while retaining mruby-zig's distinct
   bounded guest-unwind and termination semantics.
4. Treat dynamic grants as a separate follow-up decision. If real callers need
   variable per-request budgets, choose between the minimal `resetGas` Seam and
   a reconciled replacement/extension based on the option-bearing design using
   concrete usage evidence. The private epoch model supports either without
   another termination rewrite, but the public grant precedence and stats type
   must be designed once rather than layering both drafts unchanged.

### Non-goals for this extension

- Resuming the interrupted Ruby stack or rolling back its mutations.
- Guest-accessible refills, mid-execution top-ups, refunds, or additive gas.
- Resetting external termination, deadline, memory, or call-depth failure.
- Charging time spent inside one long C-native opcode or host callback.
- Patching mruby or inventing an out-of-process Adapter before that
  implementation exists. One narrow layout-safe shim accessor is in scope so
  sandbox error inspection cannot execute guest code outside an epoch.
