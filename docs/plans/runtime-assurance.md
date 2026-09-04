# Runtime assurance after CodeDB

Status: implemented and validated locally on macOS arm64 (Debug and
ReleaseSafe, both compiler profiles); hosted CI validation of this sprint's
commits pending push.
Planning date: 2026-09-04.
Baseline: `786c41a`, with CodeDB phases 1–5 complete and pushed to `main`.

## Objective

Make the existing artifact fuzzing and worker lifecycle evidence dependable
before the next release. Keep the public CodeDB and artifact interfaces stable.
This sprint addresses concrete gaps found while reviewing the completed work.

The local rehearsal passed the compiler-enabled and runtime-only matrices on
macOS arm64 and Linux arm64, plus both packaged deployment presets. Those
results do not exercise every fuzz-harness recovery path or prove behavior
after a worker's controller is killed.

## 1. Establish the hosted CI baseline

Inspect the GitHub run for the pushed implementation commit:
[CI for 786c41a](https://github.com/nullstyle/mruby-zig/actions/runs/33924952090).
It was queued when this plan was written. Record actual hosted runner
architectures and results, including x86_64 Linux, sanitizers, cross builds,
runtime-only profiles, and packaged consumers. Fix regressions attributable
to this work before accepting further changes. Keep best-effort Windows
results separate from supported-platform requirements.

Acceptance: required jobs pass for the implementation being evaluated;
failures have recorded causes and fixes rather than being hidden by retries.

## 2. Repair and verify live-isolate fuzzing

The existing target is [state_materialize_fuzz.zig](../../src/state_materialize_fuzz.zig).
Source review found these gaps; deterministic reproductions are the first
implementation step:

- The test defers destruction of the first isolate, while `freshIsolate`
  destroys and replaces that same isolate after memory exhaustion. After a
  rollover, teardown still targets the original handle. Replacement failure
  also leaves the global pointing at a destroyed isolate.
- The declared capsule limits are only used when framing input. The actual
  `importValue` call receives default options.
- The schema-bearing corpus fixture is never tried with its accepted schema,
  so that path stops before materialization.
- A broad error catch suppresses unexpected failures, and the harness does
  not assert its stated invariant that import executes no guest instructions.

Give the harness one explicit owner for the current isolate. Define teardown
and failed replacement behavior, pass its declared limits into import, and
distinguish expected malformed-input rejection from harness failures. Preserve
raw-envelope and checksummed-payload mutation paths. Exercise schema-free and
schema-bearing inputs deliberately. Bound the retained roots from successful
imports so discarded results do not accumulate as an accidental workload.

Acceptance:

- A deterministic test forces at least two isolate replacements, performs a
  valid import afterward, and tears down without stale access, double free,
  or leaked live allocations. Cover replacement failure as well.
- Boundary fixtures demonstrate that configured limits apply to import.
- Repeated imports of a fixed valid graph stabilize memory after cleanup;
  separate stress fixtures deliberately trigger memory-limit recovery.
- Known-valid seeds reach successful C materialization, including the golden
  schema-bearing capsule; rejected inputs cannot count as that evidence.
- Successful and rejected imports execute zero guest instructions. Unexpected
  lifecycle, execution, or construction failures remain visible to the test.
- Ordinary corpus/regression tests pass in both compiler profiles. Finite
  fuzz campaigns run with recorded toolchain, profile, budget, and outcome;
  any failing inputs are retained as regression fixtures.

The current build disables C coverage instrumentation because the pinned Zig
fuzzer cannot consume the Clang counter map. Document that mutations receive
Zig-side coverage guidance even though valid inputs reach C. Enabling native
C coverage is separate toolchain work and is not required to close this item.

## 3. Test worker behavior after controller death

Close the untested scenario in security review finding 2 using the real worker
and a separate test supervisor. Reuse the existing worker fixture patterns,
but do not rely on the controller under test to clean up after itself.

Synchronize worker readiness before killing the controller. Cover an incomplete
request, a CPU-bound Ruby loop, and response delivery after the reader has
gone away. Distinguish the mechanisms being tested: pipe closure, CPU limits,
and parent wall-time supervision have different behavior.

Acceptance:

- The supervisor observes the intended worker phase before killing only its
  own test controller, then verifies bounded direct-worker exit on Linux and
  macOS.
- Every failure path has an independent watchdog and cleanup for all processes
  created by the fixture; tests must not leave workers running.
- Observe the exact worker lifetime using a dedicated worker-owned pipe or an
  equivalent mechanism; PID existence alone cannot distinguish a running
  orphan from a zombie. Keep cleanup identity-safe, and ensure the supervisor
  retains no request-writer or response-reader duplicates that defeat EOF or
  broken-pipe behavior.
- The CPU-bound case uses explicit short CPU limits and a generous outer
  watchdog rather than timing-sensitive sleeps.
- Test with compiler-free artifact execution as well as the normal profile.
- Document the exact demonstrated guarantee. Parent death removes parent-side
  wall supervision; CPU limits alone do not bound blocked native work. Do not
  claim general orphan wall-time containment from these fixtures. If the
  intended cases fail, fix the demonstrated behavior or record the unresolved
  limitation before closing the finding.

Persistent worker pools, arbitrary descendants from ambient-authority helpers,
and new OS confinement mechanisms are outside this item.

## 4. Publish accurate assurance status

Append a follow-up status section to the dated security review, preserving its
original findings. Link finding 1 to the repaired harness and its evidence,
finding 2 to the new process fixtures, and finding 3 to the existing helper
integrity documentation. Keep accepted platform limitations explicit.

Reconcile [platforms.md](../platforms.md) with actual CI: distinguish configured
jobs, observed runtime results, compile-only targets, and non-blocking Windows.
Update the changelog with the harness correction and new lifecycle coverage.
Preserve the older codebase assessment as historical rather than reopening
recommendations already implemented.

Acceptance: each closed finding has a test or documentation reference, the
final required hosted CI is green, and claims match the tested platforms and
failure modes. Release numbering and publication remain a separate decision.

## Work order and commit boundaries

1. Hosted CI triage and any necessary baseline fixes.
2. Fuzz-harness lifecycle, bounds, schema paths, and deterministic regressions.
3. Orphan-controller fixtures and any directly required worker corrections.
4. Validation records, security follow-up, and platform documentation.

Items 2 and 3 can be developed independently after the baseline is understood;
coordinate shared build and CI edits. Keep the fixes and their tests together
in reviewable commits, then record the completed evidence.

## Deferred work

Ruby-level `require`, persistent workers, prepared executable handles, capsule
export optimization, and Windows support promotion remain outside this sprint.
The export reparse is a measured optimization candidate, but removing it needs
its own proof that import safety ceilings and canonical bytes are preserved.
Revisit it after the validation harness is reliable.

The mruby 4.1/Prism migration also belongs in a separate integration sprint.
Recheck upstream release status before planning that migration; the existing
RC assessment is a dated record, not a statement about the latest release.
