# Tutorials

A guided, walk-through path through mruby-zig, from evaluating your first
Ruby string in Zig to a durable, upgradable, auditable application host with
controlled delivery. Each part reads the repository's real example code with
you, runs it with real commands, and states what that layer does and does not
establish. The reference documents in [../](../) remain the specification.

Start at the top and read in order — each part assumes the previous ones:

| Part | Topic | Example | Flags |
| --- | --- | --- | --- |
| [0 — Orientation](00-orientation.md) | What this project is; setup; repo map | — | — |
| [1 — Embedding mruby from Zig](01-embedding.md) | VMs, host functions, sandboxing, exceptions | `examples/quickstart.zig` | — |
| [2 — Compiling Ruby at build time](02-codedb.md) | CodeDB, manifests, no runtime compiler | `examples/codedb_demo.zig` | — |
| [3 — The effect system](03-effects.md) | `Effect.perform`, requests, handlers, grants, rejections | `examples/effects_demo.zig` | — |
| [4 — Recording and replay](04-record-replay.md) | Traces, replay identity, determinism bounds | `examples/effects_demo.zig` | — |
| [5 — Strict turns and typed contracts](05-turns.md) | Fresh VMs, data-only adapters, commit/discard | `examples/effects_turn.zig` | strict |
| [6 — Confined effect workers](06-workers.md) | OS-contained children, brokered effects | `examples/effects_worker.zig` | strict |
| [7 — The durable host](07-durable.md) | SQLite ledger, admission, crash recovery | `examples/durable/` | strict + sqlite |
| [8 — Application upgrades](08-upgrades.md) | Pinned identities, one upgrade path | two-version demo | strict + sqlite |
| [9 — Retention, migration, chain](09-retention-chain.md) | Prune, archives, schema migration, `verifyChain` | durable suites | strict + sqlite |
| [10 — Delivery and idempotency](10-delivery.md) | Outbox, recipient dedup, HTTP adapter | durable delivery | strict + sqlite |

"strict" means `-Deffects-strict=true`; "strict + sqlite" adds
`-Dsqlite-effects=true`. All commands run through the pinned toolchain:
`mise x -- zig build <step> …`.

## Conventions

- Code excerpts are quoted from files that exist in the repository.
- Commands are real `zig build` steps.
- Every part ends with the limits of its layer; the trust model is cumulative
  and explicit throughout.

For the specification of any layer, see the reference docs:
[effects.md](../effects.md), [effects-turns.md](../effects-turns.md),
[effects-workers.md](../effects-workers.md),
[effects-contracts.md](../effects-contracts.md),
[effects-diagnostics.md](../effects-diagnostics.md),
[effects-strict.md](../effects-strict.md),
[effects-integer64.md](../effects-integer64.md),
[effects-durable.md](../effects-durable.md), plus [safe-api.md](../safe-api.md),
[sandboxing.md](../sandboxing.md), [artifacts.md](../artifacts.md),
[workers.md](../workers.md), and [platforms.md](../platforms.md).
Design history lives in [plans/](../plans/).
