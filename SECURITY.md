# Security policy

## Reporting a vulnerability

Email the maintainer (see git log for the address); please do not open
public issues for exploitable findings. Include reproduction steps and
the build profile. A signed advisory follows for confirmed issues.

## Scope

In scope:

- The sandbox machinery (`src/sandbox.zig`): limit enforcement,
  capability stripping, termination classification, bootstrap/seal.
- The worker tier (`src/worker.zig`, `src/worker_protocol.zig`,
  `tools/mruby_worker.zig`, `src/worker_spawn.c`, `src/seccomp.zig`):
  protocol framing, spawn hygiene, supervision/reaping, syscall
  confinement.
- Artifact admission (`src/artifact.zig`, `src/artifact_value.zig`,
  `src/codedb.zig`): envelope validation, capsule parsing, CodeDB
  compile-time checks.
- The safe layer's protection trampolines (`src/shim.c`): any path
  where a Ruby exception could longjmp through Zig frames.

Out of scope (documented, accepted):

- mruby's own C implementation (pinned, hash-verified; report upstream),
  and the host application's own scripts, host functions, and worker
  helper deployment (the helper binary is part of the trusted computing
  base — ship and verify it like the application binary).
- In-process execution of genuinely hostile input by design; use the
  worker tier. See `docs/sandboxing.md` for the threat model.

## What the boundaries claim today

`docs/sandboxing.md` and `docs/workers.md` are the authoritative
statements; treat any divergence between those documents and behavior as
a reportable finding even if it is not exploitable. The v0.4.0 security
review (`docs/security-review-2026-09.md`) records the baseline; its
follow-ups are tracked in the changelog.
