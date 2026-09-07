# Mruby with Effects: first sprint proposal

Status: first and second sprints plus strict-native, explicit-turn, contained-worker,
durable-host, diagnostic, operation-contract, whole-turn-contract, integer64,
and typed-durable milestones
implemented, 2026-09-05.
The interface is experimental.
See [the effects guide](../effects.md) for the implemented contract and
`mise x -- zig build run-effects-demo` for the executable CodeDB example.
The design below records the agreed direction; the implementation notes here
identify the first slice's limits.

Implemented `src/effect.zig`, owned transcript storage in
`src/effect_trace.zig`, isolate lifecycle integration, focused tests, and a
shared-catalogue CodeDB example. Requests snapshot inert arguments; grants
are independent of handler registration. Live, fixed-test, recording, and
fresh-VM replay runs use identical application Ruby. Replay invokes zero
live handlers and creates no outgoing intents.

Recording binds actual outer source/RITE bytes, operation descriptors/runtime
compatibility, and a host-supplied input/bootstrap identity. Sprint two adds
identified outer method calls through `callWithEffects`; ordinary `call` and
load-once CodeDB initialization still support live handlers only. Traces are
bounded and owned, with sticky fatal failure and no automatic delivery/retry.

## Second sprint implementation

`effect.Invocation` binds the complete code bundle, bootstrap contract,
starting state, and logical receiver supplied by the host. The runtime binds
the actual dispatched method and a snapshot of the actual argument graph.
Rejected admission leaves the previous trace and gas generation untouched.
The host still attests code and state identities; the runtime does not inspect
arbitrary receiver methods or heap state to discover those identities.

Outcome handlers now distinguish returned values from expected application
rejections. `Effect::Rejected` carries a string code and message. Ruby rescue
can complete the turn, and format 1.1 transcripts reproduce that rejection
without invoking the live handler. Raw native errors, policy failures, invalid
payloads, and indeterminate outcomes still invalidate the turn. Format 1.0
traces remain readable. Results are detached snapshots in every mode.

`effectDiagnostic` returns an owned first-mismatch report with identity or
record reason, operation/version details, and optional encoded argument byte
offset and hashes. Reports do not borrow the VM or transcript's memory.

The opt-in SQLite inventory example implements conditional stock reservation,
an expected rejection fallback, inspection with only read grants, and inert
outbox intents. Host transactions discard both DB writes and prepared intents
on a failed turn. Replay uses a fresh VM with no database handle and produces
the same Ruby results with zero native callbacks or newly prepared intents.
It does not reconstruct a database snapshot or deliver messages. The example
works with CodeDB and a runtime that has no source compiler.

Run it with `mise x -- zig build run-effects-inventory -Dsqlite-effects=true`.
The verification-only target is `test-effects-inventory`; add `-Dno-compiler`
to test the deployment profile. SQLite is a lazy, pinned example dependency.
The demonstration reports 100 local timing samples after 10 warmups for each
mode, including transaction execution, result copying, and record encoding;
fixture setup and VM bootstrap/destruction are excluded. No performance
threshold is imposed.

One local ReleaseSafe run on 2026-09-05 with the pinned Zig toolchain produced:

| Mode | Median per invocation | p95 | Encoded trace |
| --- | --- | --- | --- |
| Live | 18,084 ns | 37,500 ns | 0 bytes |
| Record | 19,667 ns | 29,542 ns | 2,040 bytes |

The expected-rejection trace was 1,251 bytes. These small samples fluctuated
across runs and overlapped with other development activity; they establish a
reproducible measurement path, not a reliable percentage overhead or throughput
claim. The large VM/setup costs excluded above must be measured separately for
a real activation workload.

This completes the proposed invocation/rejection/diagnostics/SQLite slice.
The next integration decision is how the consensus host supplies accepted
state identities and attaches prepared intents to its durable operation
ledger. The separate consensus task keeps its tested runtime pin until an
explicit integration sprint.

## Strict-native milestone

The approved follow-up addresses the [bypass audit](../effects-audit.md).
`-Deffects-strict=true` now selects a source-pinned core-only runtime with checks
on all native dispatch forms and sensitive internal primitives. Unknown native
callbacks, output/warnings, allocation-identity observations, debug operations,
and unapproved lifecycle/finalizer callbacks fail closed. Ruby rescue cannot
produce a successful trace after a native violation.

`strict.Program` installs Effects before bounded CodeDB initialization and
rejects any performed effect during that phase. Failed initialization poisons
the loader and disposes the VM. Code identity includes actual artifacts and
dependency metadata; the existing invocation machinery binds the actual method
and arguments. The SQLite example uses this path when strict mode is selected.
Strict tests and CI cover Debug/ReleaseSafe, with compatibility profiles retained.

See [the strict guide](../effects-strict.md) for the implemented interface and
limits. The lower-level Program interface still trusts Value/Vm handlers and host
starting-state attestations. The turn interface below adds explicit state and
terminal verification. Worker/broker containment is implemented below; broader
gem support still requires review.

## Explicit-turn milestone

`strict.Turn.prepare` creates a fresh VM, restores owned explicit state/input
capsules, and accepts only data-only effect bindings. Ruby returns
`[result,next_state]`; the runner records the joint graph and complete effect
trace in a bounded receipt before disposing the VM. Replay has no binding or
transaction surface and verifies the complete terminal graph, including
cross-root aliases. Inputs are identified from actual bytes.

Prepared work requires host commit or discard. Failed preparation/abandonment
discards staged work. A definitely rejected commit discards once; uncertainty
never triggers automatic rollback or retry. The counter example demonstrates
state continuation, staged intents/output, rejection, replay, and terminal
tampering detection without another dependency.

See [the turn guide](../effects-turns.md). Native adapters/transaction semantics,
external state attestations, durable delivery, and cross-platform numeric
reproducibility remain outside the guarantee.

## Contained-worker milestone

`strict.Worker.prepare` records in an OS-contained child while data adapters stay
in the host. The broker checks authority and complete inert payloads, reserves
journal storage before callbacks, and validates the child receipt against that
independent journal. A second fresh child replays without host callbacks and
verifies the terminal graph before preparation succeeds. Both processes must
exit cleanly and be reaped; failures discard staged host work.

The public build helper embeds a CodeDB bundle and shared operation catalogue
in each application worker. Private socket framing, empty environment, descriptor
closure, Linux seccomp/macOS Seatbelt, mandatory wall/CPU bounds, and malformed
worker regressions add process containment. The same Turn.Prepared interface
keeps explicit commit/discard and uncertainty semantics. See the
[worker guide](../effects-workers.md) for platform limits and remaining trust.

## Durable-host milestone

The new disk-backed inventory host uses `strict.Worker` with a fixed SQL
allowlist. It durably binds a turn ID to the owned request before preparation,
then atomically commits inventory changes, next state, verified receipt, and
outbox. Committed retries return the original result without workers or
callbacks; conflicting reuse and stale revisions fail. Uncertain commits
require reopening and reconciling the original ID.

A separate local SQLite recipient records a stable intent ID and notification
count atomically. Delivery acknowledges the source afterward, so a crash in
between is recovered through recipient deduplication. Real SIGKILL tests cover
admission, staged effects, preparation, business commit, and both delivery
commits. These tests establish process-crash behavior for this reference host;
power-loss behavior, production transports, migrations/retention, replicated
acceptance, and cross-platform numeric identity remain separate work.

See [the durable guide](../effects-durable.md) and run
`mise x -- zig build run-effects-durable -Deffects-strict=true -Dsqlite-effects=true`.
The consensus prototype is unchanged.

## Diagnostic milestone

The existing optional Turn diagnostic now survives worker execution with owned
bounded exception text, native debug locations, operation context, and replay
differences. Inert capture does not call Ruby formatting/backtrace methods;
JSON output escapes arbitrary bytes. The broker supplies origin and phase so
child reports cannot impersonate parent validation. Private protocol 1.3 carries
the payload; receipt formats and effect authority remain unchanged.

The VM-free receipt inspector validates all nested graphs and emits bounded
operation/outcome and terminal summaries. It deliberately does not replay,
authenticate, authorize, commit, or deliver anything. See
[the diagnostic guide](../effects-diagnostics.md).

## Typed-contract milestone

Shared plain descriptors now declare bounded argument/result/rejection shapes.
Runtime and broker validate independently before adapters and result acceptance;
receipt replay checks the same contracts. Contract digests bind both catalogue
and application identity. Fatal mismatches carry owned side/path/kind details.

The contained reservation example uses `Stock.reserve` and
`Notifications.reservation_created`, staging stock, state, receipt, and intents
under one in-memory host transaction. It tests expected rejection, malformed
Ruby arguments, invalid adapter outcomes, discard, zero-adapter replay, and
schema-only identity changes. See [typed contracts](../effects-contracts.md).
The later integer64 and typed-durable milestones below extend this work.

## Whole-turn-contract milestone

An optional shared `turn_contract` declares state, input, and result shapes;
next state reuses the state shape. Both in-process turns and contained workers
validate starting values before application initialization and host begin, then
validate returned values before preparation can succeed. Invalid output discards
staged work. Contracts are copied into bounded owned storage before callbacks,
and their digests participate in invocation and worker application identities.
The reservation example exercises the complete contract with independently
checked broker/child admission and receipt replay.

The separately reported bare re-raise issue is a documented mruby limitation.
Our examples now explicitly re-raise their caught exception; regression tests
preserve rejection identity, code, message, and ensure behavior. This milestone
does not change upstream exception semantics.

## Typed durable milestone

The durable reference host now combines typed `Stock.reserve` and
`Notifications.reservation_created` effects with whole-turn contracts, numeric
admission, atomic persistence, and existing crash recovery. SQL and notification
payloads are host implementation details. The host binds reservation arguments
to the admitted request, permits one matching notification, and checks that the
terminal result agrees with staged work before committing.

Invalid input cannot reserve a durable turn ID. Whole-turn contract digests now
participate in durable retry fingerprints, including the cached path. A separate
schema-only fixture verifies that old committed and admitted requests cannot
reuse their IDs under changed contracts. Contract validation also checks cached
terminal graphs. Process-crash tests retain checkpoints between the stock
update and reservation insertion inside the new domain operation.

This application uses source schema 2 and explicitly rejects earlier ledgers;
no automatic migration or consensus integration is added. See
[the durable guide](../effects-durable.md).

## Direction agreed with the project owner

- Effects should be explicit at the operations that perform them. Do not add
  method-level effect annotations to this design.
- The desired payoffs are all three: enforce what code may do, replace
  handlers for testing or another host, and record/replay execution.
- This work belongs to mruby-zig. The parallel `bugnest-1` task owns the
  consensus prototype; coordinate interfaces without changing its files.

The approved first sprint covers host interactions and nondeterministic
observations, including clock/random reads. Array mutation, instance variables,
and ordinary exception handling remain normal Ruby. An
absence of performed effects would therefore not prove mathematical purity.

## What the existing implementation gives us

The safe host callback layer already centralizes native entry and error
mapping in `src/class.zig` (`CallbackShell`). The bootstrap/seal lifecycle in
`src/sandbox.zig` provides a place to install host operations before exposing
guest execution. Its outer execution bracket provides a place to own effect
context and cleanup; nested host-to-Ruby calls must share that context.

`build/authority.zig` and CodeDB already describe available authority. Those
labels classify what linked code and declared host bindings can expose; they
do not track performed operations. In particular, arbitrary native callbacks
cannot be verified from their declarations. Keep authority classification and
runtime effect permission distinct, while deriving both from one registration
catalogue where practical.

CodeDB can compile ordinary Ruby at build time for a runtime without a parser.
State capsules carry bounded inert values, not VM stacks or native handles.
These are useful foundations for code identity and owned effect records.

Verified baseline: `mise x -- zig build run-codedb-demo -Dno-compiler` passes
on this checkout, producing the expected invoice result and state capsule.
This validates the existing deployment path, not the proposed Effect behavior.

## Proposed Ruby experience

```ruby
def announce(message)
  now = Effect.perform(Clock.now)
  receipt = Effect.perform(Outbox.enqueue("announcements", [now, message]))
  [now, receipt]
end
```

Here `Clock.now` and `Outbox.enqueue(...)` construct inert request values.
Only `Effect.perform` invokes the registered host handler. Building or passing
the request does not read the clock or enqueue anything. `perform` returns an
ordinary Ruby value, so conditions, loops, helpers, and exceptions keep their
usual shape. The spelling `perform Clock.now` can be evaluated as a readability
alternative; ship one canonical spelling after trying real examples.

An Effect is first-class because a request has an identity and arguments and
can be passed, inspected, and performed separately. Start with an opaque
request tied to a registered operation, with bounded immutable payload data.
Constructing a request does not grant permission to perform it. Performing
the same request twice means two occurrences unless that operation explicitly
defines deduplication; merely reusing an object must not imply exactly-once
execution.

The host installs operation definitions and handlers during bootstrap. Each
operation has a stable name/version, payload/result contract, and available
authority classification. The isolate receives an immutable allow-list from
the host. Guest code can choose a request, but cannot install a privileged
handler or widen its grants.

This places the annotation at each primitive host operation. A helper can
contain a `perform` call and its callers remain ordinary method calls. That
matches the requested authoring model; it does not expose a helper's complete
effect set at its call sites.

## First sprint: one workflow, three execution modes

1. **Implement the request and dispatch seam.** Add a small `mruby.effect`
   module with operation registration, inert Ruby requests, and synchronous
   `Effect.perform`. Check request identity, arguments, and permission before
   invoking a handler. Unknown, malformed, ungranted, and unhandled operations
   should have useful diagnostics. Keep C exception unwinding inside the
   existing protected calls; do not create another VM registry or reuse the
   sandbox's `mrb->ud` slot.

2. **Use two adapters for the same Ruby.** The live adapter reads a host clock
   and appends an outgoing intent to an owned in-memory buffer. The test
   adapter supplies a fixed timestamp and captures intents for assertions.
   `Outbox.enqueue` acknowledges creation of an intent; it does not report
   delivery to a recipient. No external network service is needed for the
   demo.

3. **Add a bounded record/replay adapter.** Record each occurrence's sequence,
   operation name/version, inert arguments, and returned value. Tie the trace
   to the code/artifact identity, operation catalogue identity, and explicit
   input. Replay in a fresh isolate with the same setup, require an exact
   operation/argument/order match, and return recorded values without calling
   live handlers. Reject extra, missing, mismatched, truncated, or incompatible
   records. Latch replay mismatches so rescuing an exception cannot make a
   mismatched execution valid. For this sprint, complete successful traces
   are replayable; any dispatch failure, handler error, or failure to capture
   a result permanently marks the trace incomplete, even if Ruby rescues
   and the outer execution returns successfully.

4. **Integrate the existing execution lifecycle.** Scope the trace and handler
   context to an outer execution and preserve them through nested Ruby calls.
   Reject `Effect.perform` while a host effect handler is already active:
   replay skips that live handler and could not reproduce its nested effect
   calls. Pure Ruby reentry can remain supported. Clear context on ordinary
   failure and policy termination. Bound request size,
   result size, occurrence count, and total trace bytes; retain no borrowed
   Ruby memory in host records. Preflight buffer capacity for bounded demo
   results before invoking a handler. A failure after a live operation may
   leave an incomplete trace and must never trigger an automatic retry.
   Reuse existing gas, deadline, memory, and VM ownership rules.

5. **Ship a CodeDB example and a focused effects profile.** Run the workflow
   from build-compiled Ruby with `-Dno-compiler`, using the same registration
   catalogue to declare host authority. In the demo profile, close alternate
   ambient paths for the effects under test: direct clock reads and output
   must not silently bypass `perform`. Expose only audited host operations.
   Cover the request builders and dispatcher against guest replacement.
   This proves enforcement for that configured surface; a dispatcher alone
   cannot constrain arbitrary legacy callbacks or native gems.

Suggested deliverables are `src/effect.zig`, a focused integration suite,
`examples/effects_demo.zig` plus a CodeDB Ruby source, and a short user guide.
Supporting changes should concentrate in callback registration, sandbox
execution ownership, the C shim where required, and build registration.
Avoid a new RITE format or a parser fork for the initial experiment.

### Acceptance criteria

- Constructing an Effect never calls its handler; performing it returns the
  expected ordinary Ruby result.
- Denial occurs before any clock read, sink write, or native handler call.
  Registering a handler alone does not grant it to guest code.
- Live, fixed-test, and replay runs use identical Ruby source. Replay returns
  the original result and performs zero live reads or deliveries.
- Reordering an operation, changing its arguments, or consuming a different
  number of records produces a specific replay mismatch.
- Nested calls cannot widen grants; performing an effect from inside an
  active host handler fails before invoking the nested handler. Ruby
  exceptions, `ensure`, handler errors, gas exhaustion, and termination clean
  up effect context while preserving existing sticky termination policies.
  Separate isolates do not share handler or trace state.
- Records survive destruction of their producing VM. Quota failures do not
  retain borrowed pointers or present partial traces as complete.
- Source and CodeDB execution have equivalent semantics in a compiler-enabled
  build; the CodeDB example also passes separately with `-Dno-compiler`.
  Existing relevant sandbox and callback checks pass.

The sprint should end with a runnable demonstration and a review of how its
Ruby feels, followed by a decision about syntax and the next host integration.

## Integer64 milestone

The optional `-Deffects-integer64=true` strict profile fixes Ruby integers at
signed 64-bit width and removes Float from the compiler and runtime. Checked
integer arithmetic raises ordinary rescuable errors; it does not wrap or create
Float intermediates. Pinned patches define shift extremes, decimal rounding,
minimum-integer formatting, and modulo edge cases explicitly.

Runtime data admission rejects Float anywhere in state, input, effect data, or
terminal graphs with `NumericPolicyViolation`, independently of typed schemas.
Invalid adapter results discard staged work. Structural artifact tools retain
Float support for inspection. Numeric-profile identity prevents substitution
of CodeDB/RITE artifacts and receipts from the ordinary strict profile;
integer-only StateCapsules remain transferable.

The corpus compares canonical terminal bytes and exception classes rather than
platform-specific receipt identities. This narrows the numeric reproducibility
problem; it does not prove all Ruby behavior or host computations portable.
See [the integer64 guide](../effects-integer64.md). The consensus project remains
unchanged.

## Application-upgrade milestone

Persisted state, receipts, and pending intents now outlive code and contract
versions, so the durable example pins an explicit application identity in the
ledger and demonstrates one controlled upgrade. Each build-time-known version
pairs a CodeDB bundle, whole-turn contracts, and its own confined worker; the
ledger stores the active version's identity and the committing version of every
turn. Opening a ledger under a different application, label, or numeric profile
fails closed at open instead of silently adopting existing state — this
replaces the earlier admission-time conflict demonstration for schema-only
changes, which can no longer even open the ledger.

`Host.upgrade` publishes the single demonstrated path
(`inventory/v1` → `inventory/v2`, whose state gains an explicit rejection
counter) in one transaction: a committed upgrade record first resolves retries
and lost replies, the accepted state validates under the source contract at the
expected revision, a trusted transform produces the target state, and the new
state, next revision, active identity, and provenance commit atomically. No
worker or adapter participates. Upgrades advance the revision, so admitted
older-version requests fail with `StaleState`, and reissuing committed or
admitted v1 requests under the active v2 fails with `TurnIdConflict`.

Historical replay resolves each turn's recorded version and dispatches to that
version's bundle, contracts, and worker executable; v1 receipts replay on v1
after the upgrade. Receipts, admissions, outbox rows, and notification
identities are never rewritten, and pending v1 intents remain deliverable with
their original IDs.

The ledger schema is now 3 (adding the application pin, per-turn versions, and
the upgrade journal); schema-1 and schema-2 ledgers are rejected and preserved
unchanged. Downgrades, migration of older schemas, upgrade fan-out beyond the
two build-time-known versions, and background upgrade automation remain
explicitly unsupported. See
[the durable guide](../effects-durable.md#application-identity-and-upgrades).

## Retention milestone

Pruning is now an explicit, bounded host operation instead of deferred
forever. `Host.prune` takes a revision bound and an archive path: turns
strictly below the bound are archived as self-describing JSON lines (ID,
revision, pinned application identity, base64 receipt) through an atomic
file replace, then removed with their version, reservation, and outbox rows
in one transaction. The archive is deliberately write-ahead, so an
indeterminate COMMIT resolves on retry by rewriting the same archive for the
still-present rows. Pruning refuses pending intents, bounds a batch to 256
receipts, and never touches a zero-turn archive. Admissions are immutable and
never pruned, which is what keeps pruned IDs fail-closed: same-version
retries stale out, cross-version retries conflict, and no pruned turn can
execute again. Native x86_64 confined workers are now locally validated as
well (QEMU VM, Alpine 6.12 kernel, pinned toolchain); all four supported
platform combinations have passed the confined-worker suite.

## Ledger-migration milestone

Schema-2 ledgers now have one explicit, offline way forward instead of
permanent rejection. The installed `effects-durable-migrate` reads a
schema-2 source ledger, validates the accepted state and every receipt,
terminal graph, and effect trace under an operator-named application's
contracts, and builds a fresh schema-3 ledger beside it: namespace and role
carry over, every historical turn gains a version record pinned to the named
application (provenance is an explicit input, never inferred), and
admissions, reservations, outbox delivery flags, stock, and retry identity
survive bit for bit. A rejected migration creates no target at all, and the
source is never written; cutover is an explicit operator action. Schema-1
ledgers remain read-only-rejected — their SQL-shaped domain predates the
typed contracts and is archived rather than reinterpreted.

## History-chain milestone

Every revision event now appends to an append-only hash chain inside its
committing transaction: turn commits chain a subject digest of their receipt
bytes, upgrades chain a digest of their published state, and each link binds
the previous digest, event kind, record ID, request fingerprint, and
revision. `Host.verifyChain` recomputes every link from a zero genesis,
requires contiguous revisions, and cross-checks live rows, distinguishing
`ChainRewritten` (content changed) from `ChainBroken` (history reordered or
removed). Chain rows are exempt from pruning, migrated schema-2 ledgers are
chained across their full history, and the head digest is returned for
external anchoring. This is deliberately keyless tamper-evidence inside the
trusted-storage model — signatures remain a separate decision for when
receipts must convince a third party.

## How it meets the consensus prototype later

`bugnest-1` reported that a turn runs against a private SQLite snapshot before
consensus. Accepted results and snapshots are replicated; other members do
not need to rerun all Ruby operations. Retries may return a recorded result or
reuse prepared work without executing Ruby again.

Immediate private DB operations and outgoing delivery therefore need different
host treatment. A later DB adapter can distinguish read and write operations,
with inspection granted only reads. An outgoing adapter should attach inert
intent records to the prepared work, persist them with acceptance, and let a
durable dispatcher deliver afterward. Losing proposals must not deliver.

The first sprint's in-memory intent buffer proves the interface, not durable
delivery. Production integration needs stable intent identity, dispatch
ownership, crash reconciliation, and receiver idempotency where applicable.
The effect runtime alone cannot promise exactly-once external delivery.

Recorded DB read values are also insufficient to reconstruct database writes.
Reproducing Ruby's return value, recreating a durable state transition, and
redelivering an external operation are separate policies. Start replay with
the bounded clock/intent example and preserve these distinctions in the
interface before adding databases or QUIC.

## Deliberate limits and later questions

The first experiment offers dynamic enforcement for registered host
operations. It does not infer arbitrary Ruby methods' effects or guarantee
purity for mutable guest objects. Time, randomness, native helpers, or SQL can
still introduce nondeterminism unless the configured host mediates them.
Trace replay is conditional on the same deterministic guest setup and all
relevant environmental observations crossing the effect seam.

Handlers initially return synchronously. mruby's pinned Fiber implementation
rejects suspension across some C call frames, and the embedding supports
native callbacks reentering Ruby. Transparent suspension, resumable handlers,
and durable continuations need a separate feasibility slice. Ruby-level
custom handlers can also follow once privilege and nested handling semantics
are defined.

These are independent choices: Koka tracks effects in function types, while
OCaml's effect handlers expose continuations and do not themselves guarantee
that every effect is statically handled. See the primary references:
[Koka's book](https://koka-lang.github.io/koka/doc/book.html) and
[OCaml's effect handler manual](https://ocaml.org/manual/5.3/effects.html).
The first mruby experiment deliberately starts with the explicit operation
and synchronous handler seam, leaving syntax extensions and continuation
machinery for evidence from actual programs.
