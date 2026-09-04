# Security review — v0.4.0 (2026-09-04)

Scope: the security-critical surfaces of mruby-zig at tag `v0.4.0` — the
worker-process boundary, the artifact attack surface, the sandbox
enforcement machinery, and capability enforcement against the authority
manifest. Method: targeted manual code review of each boundary with
attention to the classic embedding-parsing failure classes (untrusted
length fields, partial I/O, signal/fd hygiene, kill/reap races, counter
overflow, and trust-boundary confusion). This is a code review by the
project's usual reviewer, not an external audit.

## Verdict

No critical or high findings. The boundaries reviewed are built to an
unusually deliberate standard: every untrusted length is checked before
allocation, every byte path is deadline-bounded, process teardown is
kill-then-reap with caller cancellation blocked, and the in-process tier's
limits are honestly scoped in the documented threat model. One medium
follow-up (fuzzing through the C materialization boundary) and a few
accepted, documented risks remain.

## Verified-strong (with evidence)

### Worker process boundary

- **Spawn hygiene** (`src/worker_spawn.c`): empty environment (no env
  leakage); the child receives exactly stdin/stdout pipes with stderr
  redirected to `/dev/null`; every other pipe end is closed in the child;
  parent-held fds carry `FD_CLOEXEC` (with a dup-above-stdio path when the
  kernel hands out low fds); the child starts in its own process group so
  group-kill can never reach the parent; `posix_spawn` with an explicit
  path never consults `PATH`.
- **Parent-side I/O discipline** (`src/worker.zig`): request and response
  transfers are deadline-bounded in both directions; the response is only
  allocated after the fixed-size header passes `max_encoded_bytes` and
  protocol ceilings, and any trailing byte after the declared body is a
  `ProtocolMismatch` (no smuggling); a failed exchange kills the child's
  process group **before** reaping; caller cancellation is blocked
  (`swapCancelProtection`) for the whole spawn-to-reap scope, so the host
  cannot abandon a live child.
- **Environment preconditions** (`childWaitOwnershipAvailable`,
  `brokenPipeProtected`): the run refuses to start unless `SIGCHLD`
  disposition allows reaping and `SIGPIPE` is not at its default — the
  latter would otherwise let a dead child's closed pipe kill the host
  process. Refusing to run beats silently misbehaving.
- **Protocol arithmetic** (`src/worker_protocol.zig`): all body lengths go
  through `checkedBodyLength` with a hard 64 MiB ceiling; header sizes are
  fixed; encode-side overflow is rejected (`LengthOverflow`).
- **Child self-limiting** (`tools/mruby_worker.zig`): `RLIMIT_CPU`,
  `RLIMIT_CORE = 0`, and (on Linux) `RLIMIT_AS` are installed before any
  guest byte executes; macOS address-space ceilings are reported as
  unavailable rather than pretended (`HardMemoryLimitUnavailable`, mirrored
  by a parent-side rejection).
- **Fail-closed generic worker**: generic worker builds refuse to link when
  the authority manifest shows filesystem/network/process/environment or
  arbitrary native-host authority, unless explicitly overridden at build
  time.

### Artifact attack surface

- `parseEnvelope` (`src/artifact.zig`) validates size ceiling, magic, and
  exact format version before any length-driven work; RITE admission
  requires an exact 32-byte compatibility-fingerprint match, and the
  cross-version fixtures pin the rejection of older-producer images.
- The StateCapsule graph parser (`src/artifact_value.zig`) is
  coverage-fuzzed with stable corpora, computes exact hash-work admission
  before materialization, and enforces non-relaxable pair/probe/compare
  ceilings with diagnostics at the offending key — pathological collision
  sets are bounded work, not unbounded hashing.
- Capsule import runs no guest code (`_dump`/`_load`/`hash`/`eql?`/
  constructors excluded by the value whitelist), so hostile capsule bytes
  cannot invoke Ruby-level hooks during parsing.

### Sandbox enforcement machinery

- The instruction fetch hook (`src/sandbox.zig` `fetchHook`) uses
  saturating counters (`+|=`), atomic termination bits, and idempotent
  limit notation; gas accounting lives in the meter, not ad-hoc
  arithmetic.
- Capability stripping consumes centralized authority tables with
  inventory-driven tests (from the auditable-authority work); pinned
  ObjectSpace references cannot bypass the object-space gate, and pinned
  RNG/clock policies mask re-seeding and fresh construction after setup.
- The bootstrap/execution typestate makes post-seal raw-VM misuse a
  compile error; the sealed `Isolate`'s host operations are
  lock-serialized, turning cross-thread misuse into `IsolateThreadBusy`.

## Findings

| # | Severity | Finding | Recommendation |
| --- | --- | --- | --- |
| 1 | Medium | The C materialization boundary (`Isolate.importValue` into a live interpreter) is exercised by tests and fixtures but has **no coverage-guided fuzz target**; only the pure parser is fuzzed. A parser/validator divergence would be found by tests of crafted shapes, not by exploration. | Add a second fuzz root that feeds the fuzzer's bytes through `importValue` on an isolate with tight memory/limit ceilings (the assessment's remaining fuzzing item). |
| 2 | Low | Worker wall-time enforcement is parent-side; an orphaned worker (parent `SIGKILL`ed) relies on pipe EOF and its own `RLIMIT_CPU` to exit, which reasoning supports but no fixture demonstrates end-to-end. | Extend the existing descendant/signal fixtures with an orphaned-parent scenario asserting the child exits. |
| 3 | Low | Worker helper integrity is a deployment trust assumption: the helper path is host-controlled, and a swapped helper bypasses every policy. Documented in `docs/workers.md`, but not restated in the threat model. | Add one sentence to the sandboxing threat model: the helper binary is part of the trusted computing base; ship and verify it like the application binary. |
| 4 | Info | `RLIMIT_AS` is unavailable on macOS; macOS workers enforce sandbox-level memory policy but no OS address-space ceiling (surfaced, not hidden). | Accepted; revisit if macOS gains a usable mechanism. |
| 5 | Info | The in-process tier remains unsuitable for hostile input by design (no address-space separation) — documented, and the worker tier now exists for that case. | Accepted risk, documented. |

## Explicitly out of scope

mruby upstream C code itself (pinned, hash-verified, patched via the
audited hash patch), the host application's own Ruby scripts, and Zig
toolchain soundness.

## Follow-up status (2026-09-04)

Recorded after the runtime-assurance sprint
([plans/runtime-assurance.md](plans/runtime-assurance.md)); the findings
above are the original, unmodified review record.

- **Finding 1 (medium) — closed.** `zig build fuzz-state-materialize` now
  drives fuzzer bytes through `Isolate.importValue` — envelope validation,
  graph admission, and C-side construction of live objects — inside a
  memory-capped isolate, with the harness's declared capsule limits actually
  passed to import. Deterministic regressions in
  [state_materialize_fuzz.zig](../src/state_materialize_fuzz.zig) pin single
  isolate ownership across at least two memory-exhaustion replacements
  (including failed replacement), boundary fixtures for every configured
  ceiling, golden schema-bearing and schema-free seeds reaching C
  materialization, zero executed guest instructions for successful and
  rejected imports, and stable memory across repeated valid imports.
  Unexpected lifecycle and construction failures surface instead of being
  swallowed. CI runs bounded campaigns in the compiler-enabled and
  compiler-free profiles and a weekly sustained campaign per profile;
  failing inputs are retained as artifacts and reduced into regression
  fixtures. Zig-side coverage guidance is active — mruby's Clang coverage
  counters are disabled for the pinned fuzzer (see
  [artifacts.md](artifacts.md#state-capsules)).
- **Finding 2 (low) — closed.** `zig build test-worker-orphan` builds a
  supervisor → controller → real worker tree, synchronizes at real worker
  boundaries, SIGKILLs only its own controller, and verifies bounded worker
  exit on Linux and macOS in both compiler profiles, observing the exact
  lifetime through a worker-owned pipe with subreaper/kqueue exit
  confirmation: pipe EOF for an incomplete request, SIGXCPU for a CPU-bound
  loop under its inherited `RLIMIT_CPU`, and exit 1 for response delivery
  after the only reader died. The exact demonstrated guarantee — and its
  limits — are documented in [workers.md](workers.md): parent death removes
  parent-side wall supervision, CPU ceilings do not bound blocked native
  work, and no general orphan wall-time containment is claimed.
- **Finding 3 (low) — closed.** The sandboxing threat model now states that
  the worker helper binary is part of the trusted computing base and must be
  shipped and verified exactly like the application binary
  ([sandboxing.md](sandboxing.md#threat-model)).
- **Findings 4–5 (info) — remain accepted platform limitations.** macOS has
  no usable `RLIMIT_AS` (surfaced as `HardMemoryLimitUnavailable`, never
  pretended), and the in-process tier remains unsuitable for genuinely
  hostile input by design; the worker tier exists for that case.
