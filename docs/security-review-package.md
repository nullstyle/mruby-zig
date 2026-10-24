# External security review package (roadmap B4)

Prepared 2026-10-24 against **v0.6.0** (`6db7682`). This document is the
hand-off package for commissioning an external review of the worker
boundary, sandbox machinery, and artifact attack surface. It exists so
the review can start from the project's own threat model and evidence
rather than reconstructing it; it makes no claims beyond what the cited
documents and tests support. The internal history (assessments, the
adversarial review lineage) is deliberately not softened here —
divergence between documented claims and behavior is itself reportable
per `SECURITY.md`.

## How to build and test

```sh
git clone https://github.com/nullstyle/mruby-zig && cd mruby-zig
git checkout v0.6.0
mise install                  # installs the pinned Zig 0.17.0 exactly
mise x -- zig build test      # full suite (Zig unit, embedded Ruby,
                              # mruby's own ISO suite, sandbox, workers)
mise x -- zig build test -Doptimize=ReleaseSafe
mise x -- zig build test -Dgem-set=minimal
mise x -- zig build test -Dno-compiler=true
mise x -- zig build fuzz-state-materialize --fuzz=100000 -Doptimize=ReleaseSafe
```

CI (`.github/workflows/ci.yml`) runs the full matrix: 2-OS tests both
optimize profiles, runtime-only 2×2, packaged-consumer relocation,
cross-compiles, TSan, C-UB sanitizer, a blocking native Windows job, and
weekly sustained fuzzing (2M parser / 500K materialize runs per
compiler profile). All green at tag time.

## Scope

**In scope** (from `SECURITY.md`):

| Surface | Primary code | Docs |
| --- | --- | --- |
| Sandbox enforcement | `src/sandbox.zig`, `src/gas.zig` | `docs/sandboxing.md` |
| Worker tier: one-shot + sessions + pool | `src/worker.zig`, `src/worker_protocol.zig`, `tools/mruby_worker.zig`, `src/worker_spawn.c` | `docs/workers.md` |
| Syscall confinement | `src/seccomp.zig` | `docs/workers.md` (hardened tier) |
| cgroupv2 confinement | `src/cgroup.zig` | `docs/workers.md` |
| Artifact admission | `src/artifact.zig`, `src/artifact_value.zig`, `src/codedb.zig`, `build/codedb*.zig`, `tools/rite_envelope.zig` | `docs/artifacts.md` |
| Protection trampolines | `src/shim.c`, `src/c.zig` | `docs/safe-api.md` |
| Audited upstream patches | `tools/patch_mruby_hash.zig`, `tools/patch_mruby_throw.zig` | `docs/maintenance.md` |

**Out of scope** (documented, accepted): mruby's own C implementation
(pinned, hash-verified — report upstream); the host application's
scripts, host functions, and helper deployment (the helper binary is
trusted computing base); in-process execution of genuinely hostile
input by design (use the worker tier).

## Review asks, in priority order

1. **Worker protocol framing under sessions** — new in 0.6.0: a session
   presence bit frames multi-shot requests by exact declared lengths
   instead of end-of-input (`src/worker_protocol.zig` request_optional
   session; helper loop in `tools/mruby_worker.zig`). Ask: can a
   desynchronized or malicious controller/helper pair smuggle bytes
   across the framing change, and does every failure path still
   kill-then-reap?
2. **seccomp allowlist** (`src/seccomp.zig`, B1) — hand-assembled
   classic BPF: arch gate, per-entry compare/allow pairs, two
   argument-gated entries (`prlimit64` NULL-new-limit reads,
   `ioctl(TCGETS)`), EPERM default. Ask: is the allowlist minimal for
   the documented runtime surface; are the argument gates sound; is the
   program shape exploitable? Empirical derivation history is in the
   B1 commit (`ea953ff`).
3. **cgroup lifecycle** (`src/cgroup.zig`, B3) — leaf create/write/
   attach between spawn and first request byte, destroy after reap;
   the library never writes `subtree_control`. Ask: can confinement be
   bypassed by racing spawn/attach, and do failure paths leak leaves or
   run unconfined?
4. **Audit trail fidelity** (`AuditRecord`/`AuditSink` in
   `src/worker.zig`) — one record per exchange on every outcome path.
   Ask: is any outcome path unaudited; can a record misrepresent the
   authority actually in effect?
5. **Safe-layer marshalling additions** — `KwArgs(T)` keyword
   extraction through `mrb_get_args` with in-frame symbol interning
   (`src/class.zig`, `mrz_protected_get_args_kw`), per-object singleton
   methods with the arena re-rooting invariant (`mrz_protected_define_
   singleton_method` returns the receiver), and symbol-cached dispatch.
   Ask: any longjmp escape, arena un-rooting, or arity/aspec confusion
   (the aspec `MRB_ARGS_KEY`/`KDICT` interaction was security-relevant
   once already — see commit `04ebda1`).
6. **Capsule/RITE admission as before** — re-review the
   previously-reviewed parser and materialization boundary against the
   unchanged-since findings, plus the CodeDB compile-time gates.

## Prior review and its disposition

The v0.4.0 self-review (`docs/security-review-2026-09.md`) found no
critical/high issues; all findings are closed or explicitly accepted
with follow-up status recorded in that document. That review predates:
CodeDB, the runtime-only profile, sessions/pooling, seccomp, cgroups,
the audit trail, kwargs/singleton/symbol-dispatch API, and Windows
support — which is why items 1–5 above lead the asks.

Honest context for calibrating trust: the project's review history is
one maintainer with heavy AI assistance; two prior "green" states were
later shown incomplete by subsequent review passes, and the upstream
CI fuzzing failure went unnoticed for weeks (fixed; scheduled runs now
green). Treat self-attested claims accordingly — the externally
checkable anchors are: mruby's own test suite result (697 pass / 0
fail / 1 documented upstream delta, in CI), the committed
cross-toolchain determinism fixture, the cross-version artifact
fixtures, and the fuzz corpora with CI retention.

## Deliverables expected

- Findings with severity, reproduction (build profile + minimal
  reproducer), and the violated document claim where applicable.
- Per-surface verdicts for the six asks above.
- Explicit confirmation or refutation of the documented boundary
  claims in `docs/sandboxing.md` and `docs/workers.md`.

Findings route per `SECURITY.md`: exploitable issues privately to the
maintainer; doc/behavior divergences may be public issues.
