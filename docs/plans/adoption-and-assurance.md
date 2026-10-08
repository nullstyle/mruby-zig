# Adoption and assurance roadmap (Option A + B)

Date: 2026-10-08. Baseline: v0.5.0 (83b1734) with green CI, feature/effects
and feature/optional-debug-hook rebased onto it (kept alive, not landed;
effects is load-bearing for the local bugnest prototypes and lands when it
becomes the priority). This plan merges the "Ship 1.0" (A) and "Assurance
frontier" (B) options from the 2026-10 full-spectrum assessment into one
sequenced backlog of sprints. A-items widen the supported embedding
surface; B-items make the worker tier a defensible boundary for untrusted
input. They interleave because B depends on A's validation story
(conformance suite, external anchoring) and A inherits B's hardened-worker
profile as its strongest adoption pitch.

## Track A — ship 1.0

### A1. API completeness (in progress)

- [x] Keyword arguments, Ruby → Zig (`KwArgs(T)`, shipped 2026-10-08).
- [ ] Keyword arguments, Zig → Ruby (`CallOptions.kwargs`). See the
      analysis below; needs its own reviewed change.
- [x] Per-object singleton methods (`Value.defineMethod`, 2026-10-08).
- [x] Calling a stored Proc from Zig — `vm.call(proc, "call", ...)`
      covers it with full lambda/proc semantics; documented and tested
      (2026-10-08). A dedicated `mrb_yield`-based entry point remains
      unnecessary unless a need for yield-with-explicit-self appears.
- [ ] Symbol-cached dispatch (`Vm.callSymbol`) — interning is protected
      but repeated per call today.
- [ ] Named public error sets on `Vm` methods (inferred `!` today).
- [x] Replace the process-global `lastInitFailure` with owned
      diagnostics (`Vm.initWithFailure`, 2026-10-08).
- [x] Move the test seam `mrz_artifact_test_fill_arena` out of the
      shipped shim into a test-only C source (2026-10-08).

### A2. mruby 4.1 / Prism migration

The staged `mruby-4.1-integration` branch and
docs/upstream-4.1-assessment.md hold the findings. Rework surfaces:
source lists, presym port (Prism's `mrc_presym.c`), host-mrbc bootstrap,
shim.c reconciliation, RITE version constants, epoch decision. Add the
planned 4.0.0-produced RITE fixture at the same time. Do this while
pre-1.0 so the fingerprint change costs nothing.

### A3. Windows

Fix the host-mrbc MinGW build (`jmp_buf` / `void **` mismatch diagnosed
upstream; reproduces under both pinned Zig toolchains). A shim-level
containing trampoline is the likely shape — mruby's `mrb_jmpbuf` is
already `void **`. Then promote the windows-runtime CI job per
docs/platforms.md criteria.

### A4. External anchoring

- Run mruby's own `test/t` suite as a conformance harness (biggest
  credibility win per unit effort).
- Re-record benchmarks on the pinned toolchain; commit cross-toolchain
  artifact fixtures (the A/B check exists but is not committed evidence).
- CONTRIBUTING, security policy, issue templates before announcements.

### A5. 1.0

Semver freeze, migration notes, example gallery, announcements.

## Track B — assurance frontier

### B1. Linux syscall confinement for workers (shipped 2026-10-08)

Implemented as designed: `mruby.seccomp` (hand-assembled classic-BPF
allowlist from `std.os.linux.SYS`), a `syscall mode` byte in the worker
protocol, helper installation before any guest byte (fail-closed), and
controller prevalidation (`error.SyscallFilterUnavailable` off Linux).
Denials return EPERM rather than killing the process. Tests: program-shape
and denied-class unit tests (all platforms), the `seccomp-probe` fixture
and a fully confined `runRite` roundtrip (Linux CI; validated locally in
an arm64 Linux container). Landlock path restrictions remain the
follow-up, as do network namespaces and uid separation (B3).

Goal: turn "process and resource isolation" into an OS-enforced boundary.
Constraints: no new system dependencies — the filter is raw BPF
(`seccomp(SECCOMP_SET_MODE_FILTER)` via `prctl`) installed in the worker
after exec, before any guest byte, mirroring where RLIMITs are installed
today.

- Default policy: read/write on already-open fds, exit/exit_group,
  clock_gettime, the memory-allocator syscalls (mmap/munmap/mprotect/
  brk), futex, and tgkill/sigreturn; everything else EPERM (not SIGKILL:
  EPERM keeps failures observable and testable from Ruby).
- `clock_gettime` stays available: the sandbox deadline machinery and
  mruby's Time use it; the authority manifest already models `clock`.
- No `open/openat` by default: `filesystem` authority gems already make
  builds worker-ineligible; seccomp enforces what the manifest declares.
- Landlock for filesystem path restrictions is a follow-up once the pure
  syscall filter lands (needs the landlock syscall family enabled; gate
  on kernel support at runtime, degrade loudly to the documented
  "no fs confinement" state).
- Architecture: BPF filters must be generated per arch (`seccomp_data`
  syscall numbers differ). The worker binary knows its target arch at
  build time — generate the filter table in the build, embed it as data.
- Testing: extend the worker fixtures with a `worker-syscall-fixture`
  that probes denial (e.g. Ruby-level `File.open` raising EPERM inside
  the worker) and the existing orphan/signal fixtures unchanged. Linux
  CI only; macOS keeps the current documented posture.
- Explicitly out of scope for B1: network namespaces, uid separation,
  cgroups. Those are B3+.

### B2. Worker economics (shipped 2026-10-08)

Persistent sessions + pooling shipped: a session presence bit frames
multi-shot requests by exact length (no protocol version bump needed;
same-tree pairing), the helper loops with a fresh isolate per request
and treats stdin EOF as graceful shutdown, and `Session`/`Pool` carry
lifetime-vs-per-request limit semantics (RLIMITs install once;
per-exchange budgets come from the sandbox policy + controller-side I/O
deadline). Benchmarked 6689 -> 1359 us/op (4.9x) on the reference
machine. Deferred follow-up: a protocol hello with feature negotiation
only becomes necessary if the controller and helper can come from
different builds.

### B3. Platform honesty + hardening depth

Either a macOS hardening story (EndpointSecurity is heavyweight; an
honest "hardened tier is Linux-only" contract matches the existing
`HardMemoryLimitUnavailable` precedent) plus cgroupv2 integration and
audit logging of worker authority use.

### B4. External validation

External security review of the worker boundary + seccomp policy;
adversarial red-team corpus wired into the existing fuzz-retention CI;
protocol property tests.

## Cross-cutting decisions

- **Trace-hook decoupling (B1-adjacent):** the worker tier currently
  requires the per-instruction hook (`worker_target_supported and … and
  debug_hook` on the unmerged branch) because the helper executes inside
  a sandboxed isolate. Add a hook-less hardened worker profile where the
  OS boundary (RLIMITs + seccomp) is the enforcement point and gas/
  deadline enforcement is absent rather than silently missing. The
  effects system remains hook-dependent by design
  (`StrictEffectsRequiresDebugHook`): deterministic replay needs
  deterministic gas.

## Zig → Ruby keyword calls: analysis (deferred A1 item)

`mrb_funcall` does not support keyword arguments (`funcall_args_capture`
hard-sets `ci->nk = 0`; vm.c says so in a comment). The VM convention is
`ci->nk == 15` with the kwargs hash at `mrb_ci_kidx(ci)` (set by OP_SEND
from the `c` operand's high nibble). Options, in increasing invasiveness:

1. **Shim replication of `mrb_funcall_with_block` with kwargs** using
   exported internals (`mrb_stack_extend`, `mrb_vm_find_method`,
   `mrb_ci_nregs/bidx`): ~200 lines mirroring cipush/cipop/
   prepare_missing, including method_missing dispatch and the irep path
   (`mrb_run`). High review burden, no core patch.
2. **Audited vm.c patch** (like the hash.c patch, via the literal-match
   patcher with a fingerprint marker): refactor the funcall core into a
   kwargs-capable `mrb_funcall_with_block_kw` export. Smaller diff, but
   a second literal core patch to carry across upstream releases (4.1
   moves this code).
3. **Wait for upstream**: kwargs funcall has been requested; the Prism
   era may revisit the C call API.

Recommendation: revisit after A2 (the 4.1 migration will touch vm.c
anyway; patch-carrying cost is better known then).

## Sequencing

A1 (finish) → B1 → A2 → A3 → B2 → A4 → B3 → A5/B4, with the flaky-test/
CI-hygiene class of fixes (like the two already landed) taken whenever
they appear. Each item ships independently behind green CI; nothing here
blocks landing feature/effects when that becomes the priority.
