# Part 0 — Orientation: what this project is and how to walk it

This tutorial series is the guided path through mruby-zig. It follows the
repository's own ladder of examples, from evaluating your first Ruby string in
Zig up to a durable, upgradable, auditable application host with controlled
external delivery. Each part reads the real example code with you, runs it with
the real build commands, and states plainly what each layer does and does not
guarantee. The reference documents under `docs/` remain the specification; when
a tutorial and a reference doc ever seem to disagree, the reference doc wins
and the tutorial is a bug.

## What mruby-zig is

mruby-zig embeds [mruby](https://mruby.org) 4.0 in Zig applications:

- One `zig build` fetches the hash-pinned mruby 4.0.0 source, generates its
  presym tables and core bytecode, compiles everything with `zig cc`, and hands
  you a `mruby` module. There is no Ruby toolchain, no rake, no submodules, and
  no system dependency at build time.
- A safe Zig layer sits over the C API with explicit failure and interpreter
  lifetime rules ([safe-api.md](../safe-api.md)), plus a sandbox tier with
  policies and resource ceilings ([sandboxing.md](../sandboxing.md)).
- On top of that sits the reason this repository exists: a **first-class effect
  system**. Ruby code performs host operations through one explicit seam —
  `Effect.perform(Stock.reserve(sku, quantity))` — and the host decides what
  actually happens: nothing, a typed adapter call, a recording, or a replay of
  recorded observations.

The effect system is deliberately not an annotation on Ruby methods. Ordinary
Ruby mutation stays ordinary Ruby. What the system captures is the crossing
from guest computation to host authority: every such crossing is a request the
host owns, admits or refuses, and can prove happened the same way twice.

## The ladder you will climb

| Part | Layer | Example you will read |
| --- | --- | --- |
| 1 | Embedding, host functions, sandboxing, exceptions | `examples/quickstart.zig` and friends |
| 2 | Ruby compiled at build time (CodeDB) | `examples/codedb_demo.zig` |
| 3 | The effect system: requests, handlers, grants | `examples/effects_demo.zig` |
| 4 | Recording and replay | same demo, record/replay modes |
| 5 | Strict turns and typed contracts | `examples/effects_turn.zig` |
| 6 | OS-confined effect workers | `examples/effects_worker.zig` |
| 7 | The durable host: SQLite ledger, recovery | `examples/durable/` |
| 8 | Application upgrades | the two-version durable demo |
| 9 | Retention, migration, history chain | prune, migrate, `verifyChain` |
| 10 | Delivery and idempotency | local and HTTP delivery |

Parts 1–2 need no flags. Parts 5–10 require the strict profile
(`-Deffects-strict=true`), which selects a minimal mruby without a runtime
compiler; part 7 onward also requires `-Dsqlite-effects=true`, which compiles a
hash-pinned official SQLite amalgamation. No system SQLite installation is
needed — ordinary builds never acquire the dependency.

## Set up

The repository pins its toolchain with [mise](https://mise.jdx.dev)
(`.mise.toml`): Zig `0.17.0-dev.1978+c961124d9`. All commands in this series
run through it:

```sh
git clone <this repository> && cd mruby-zig
mise install                  # installs the pinned Zig snapshot
mise x -- zig build test      # unit + Ruby integration suites
mise x -- zig build run-quickstart
```

If `mise x -- zig build test` and `run-quickstart` pass, you are ready for
part 1. Supported platforms are listed in [platforms.md](../platforms.md); the
plain embedding works everywhere the toolchain does, while the confined workers
of part 6 support Linux and macOS on x86_64 and aarch64.

## How the build is verified

A convention you will see throughout this series: interesting suites are run in
a **matrix of cells**, not just once. The durable suites, for example, run in
Debug and ReleaseSafe, under the ordinary numeric profile and the
integer-only profile (`-Deffects-integer64=true`). CI runs them on
ubuntu-latest (x86_64) and macos-latest (aarch64). When a tutorial claims
something is verified, this matrix is usually what is meant. Numeric-profile
equivalence is bounded evidence, not a universal determinism proof — that
honesty is intentional and recurring.

## A map of the repository

- `src/` — the library: the C shim and safe layer (`shim.c`, `vm.zig`,
  `value.zig`, `sandbox.zig`), artifacts (`artifact.zig`), the effect runtime
  (`effect.zig`, `effect_invocation.zig`), strict turns and workers
  (`strict_turn.zig`, `effect_worker.zig`, `effect_worker_process.c`), and the
  strict-native policy (`strict.zig`, `strict_native.c`).
- `tools/` — build-time executables: the CodeDB compiler pipeline, the mruby
  patcher (`patch_mruby_strict.zig`), the reusable worker entry point
  (`effects_worker.zig`).
- `examples/` — the ladder this series walks; each example is compiled by
  `build.zig` into run and test steps.
- `docs/` — reference documentation (the specification this series defers to)
  and `docs/plans/` — design history and milestone records.

## Reading rules used by this series

- Every code excerpt is quoted from a file that exists in the repository, with
  a path telling you where to find it.
- Every command is a real `zig build` step; flags are stated when required.
- Every part ends with the limits of what that layer establishes. The trust
  model is cumulative and explicit: which parts are trusted (the database, the
  native adapters, the allocator, the OS and storage), which are verified, and
  which are simply out of scope.

Start with [Part 1 — Embedding mruby from Zig](01-embedding.md).
