# Part 2 — Compiling Ruby at build time with CodeDB

**Prerequisites**: [Part 1](01-embedding.md). No example flags required.

CodeDB answers a question the sandbox cannot: *where does the Ruby that runs
in production come from?* If guests can arrive as source strings, then parsing
and compiling happen inside your trust boundary at runtime. CodeDB moves that
work to **build time**: application Ruby is compiled by a host `mrbc` during
`zig build`, and the runtime executes identified bytecode artifacts only.

This matters most for the strict profile you will meet in [Part 5](05-turns.md):
strict workers are built with `-Deffects-strict=true`, which selects a minimal
mruby **without any runtime compiler**. CodeDB is not an optimization on that
path — it is the only way code gets in.

## The demo

```sh
mise x -- zig build run-codedb-demo
```

[examples/codedb_demo.zig](../../examples/codedb_demo.zig) executes two
workloads from a CodeDB bundle. The manifest arrives as a Zig module import —
that is the build-time handshake:

```zig
const codedb_manifest = @import("codedb_manifest");
```

Inside a sealed trusted isolate, it runs a top-level entry:

```zig
var boot = try mruby.sandbox.BootstrapIsolate.spawn(
    mruby.sandbox.Policy.trusted(.{}),
);
defer boot.deinit();
const iso = try boot.seal();
defer iso.deinit();

_ = try iso.runArtifact(codedb_manifest, "accumulate");
const total = try iso.getGlobal("codedb_total");
```

`runArtifact(manifest, "accumulate")` executes the bytecode registered under
that entry name. The Ruby sources themselves live in
[examples/codedb/](../../examples/codedb/) — `accumulate.rb`, `dispatch.rb`,
`billing.rb`, `invoice.rb`, `discounts.rb` — and were compiled into the
manifest when you built the demo. Nothing here parses a source string at
runtime.

The second workload (`invoiceJob`) is the pattern to internalize, because it
is how real applications will load:

```zig
var boot = try mruby.sandbox.BootstrapIsolate.spawn(mruby.sandbox.Policy.restricted(.{
    .limits = .{ .gas = .{ .per_execution = 10_000 }, .call_depth = 32 },
}));
// ...
try std.testing.expect(try iso.loadArtifact(codedb_manifest, "billing"));
try std.testing.expect(!try iso.loadArtifact(codedb_manifest, "billing"));
```

- **Policy data and startup code load once**: `loadArtifact` returns `true`
  the first time and `false` on repeats; both initializers shared one gas
  budget, and reloading did not reset the bundle's job counter.
- **Inputs are ordinary host values** pushed in through `setGlobal` — all
  application *code* comes from CodeDB.
- **Results can cross the inert state-transfer interface**: the example
  exports the result with `iso.exportValue` into a `StateCapsule` — the same
  capsule type the effect system will use for state, input, and receipts in
  every later part. Meet it here as "owned bytes with a typed encoding".
- The manifest is queryable: `mruby.codedb.lookup(codedb_manifest, "invoice")`
  returns the entry with its `source_name`, which the demo round-trips through
  Ruby to show provenance survives execution.

## What the build actually does

From [build.zig](../../build.zig)'s own header and the root
[README](../../README.md):

1. A presym scan preprocesses mruby core, the compiler, and the `mrbc` tool.
2. A host `mrbc` is compiled with `zig cc` and generates core bytecode
   (`mrblib.c`, gem init).
3. Your bundle's `.rb` sources are compiled by that host `mrbc` into a
   manifest module your executable imports.

The result carries identity: the manifest pins which bytecode runs, and — as
you will see from [Part 7](07-durable.md) onward — digests of artifact code
participate in request fingerprints and application identity. Switching a
bundle is a build event, not a runtime decision.

The design history and rationale are recorded in
[docs/plans/codedb.md](../plans/codedb.md); typed RITE images and capsules are
specified in [artifacts.md](../artifacts.md).

## Related steps you can run

```sh
mise x -- zig build test-codedb          # generation, metadata, policy admission
mise x -- zig build run-codedb-demo      # the demo above
```

Downstream packages use the public `addCodeDB` build helper (you will see it
used in [Part 6](06-workers.md) to give a worker its application).

## What you can now build

Applications whose entire Ruby codebase is compiled, identified, and admitted
at build time, running in sealed isolates with code and inputs strictly
separated.

## Limits at this layer

- CodeDB governs *application code*, not data: a manifest entry can still be
  handed hostile input values, so entry-point validation stays your job
  (typed contracts arrive in [Part 5](05-turns.md)).
- The trusted tier (`Policy.trusted`) used for the first workload is exactly
  that — trusted; the restricted tier is the one for less-trusted logic.
- Nothing here mediates *what the code asks the host to do*. A bundle can call
  any registered host function however it likes. Making those crossings
  explicit, granted, and observable is [Part 3](03-effects.md).

Continue with [Part 3 — The effect system](03-effects.md).
