# CodeDB: build-managed Ruby artifacts for mruby-zig

Status: phase 1 (tracer bullet) in progress. This plan adapts the
Rubinius CodeDB idea — compiled code plus rich metadata as a queryable
database rather than opaque files — to this project's primitives.

## Concept

A **content-addressed, build-managed store of compiled Ruby artifacts
plus a queryable manifest**, versioned by the compatibility fingerprint
we already compute. Each entry carries:

- the typed RITE image (envelope, SHA-256, exact build fingerprint,
  optional application fingerprint) — unchanged from today;
- source identity: original `.rb` content hash and `source_name`;
- a module-graph record: what the script defines and what it expects
  (new format; see *Open design problems*);
- an authority classification derived from the authority manifest;
- the feature identity (gem set + fingerprint) it was compiled against.

The database lives in two places: at build time as `zig build`-managed
steps with cache invalidation, and at runtime as a generated, embedded
manifest module. Compilation becomes a build-time concern — the same
contract `zig cc` gives C.

## Developer experience

- Ruby files are first-class build inputs beside `.zig` files; `zig
  build` compiles, fingerprints, validates, and embeds them.
- Precise compatibility failures at build time ("compiled for
  standard@a1b2, deploying minimal@c3d4"), not runtime mysteries.
- Policy as a build gate: a script whose authority exceeds its target
  tier never ships (fail-closed, like the generic worker gate).
- Backtraces resolve to original sources through the manifest.
- Warm workers: one-shot workers boot from pre-validated artifacts with
  zero parse cost; generations are new workers with new artifact sets.
- Deterministic testing: pinned gas/RNG/clock make recorded runs
  reproducible; spec-to-artifact association enables targeted re-runs.
- End state: a **runtime-only embedding profile** — no parser/codegen
  linked, smaller TCB, execution limited to build-validated code.

## Phases

1. **Tracer bullet (now)**: the host `mrbc` from the bootstrap pipeline
   compiles application `.rb` files at build time; a host tool wraps the
   raw RITE into typed envelopes (reusing pure-Zig `artifact.zig` and
   the generated fingerprint) and emits a manifest module; a small
   `mruby.codedb` runtime surface executes manifest entries through the
   normal policy path. Includes a byte-determinism gate (each source
   compiled twice, artifacts compared) — the property the whole caching
   story depends on.
2. **Loader + example parity**: `Isolate.runArtifact`-level ergonomics;
   a realistic example; cross-version fixture coverage for manifest
   entries (epoch discipline applies — envelope additions bump the
   minor, breaks bump the epoch).
3. **Module graph**: define the source-unit convention (entrypoints,
   defines/expects edges, app-level require). This is the gating design
   decision; everything queryable is built on it.
4. **Authority classification**: extend build-time gem authority tables
   down to per-artifact classes; build gate refuses over-authority
   artifacts for their target tier.
5. **Runtime-only profile**: `-Dno-compiler` build flag flipping
   `features.has_compiler` false, a worker built from that profile, and
   the size/TCB win measured against `docs/benchmarks.md` baselines.

## Open design problems

- **Module graph format** (phase 3): mruby has no core file-`require`;
   apps need a convention for units, edges, and entrypoints that stays
   inert (no guest execution to extract it — derive from RITE constant
   references and presym tables, or declare it alongside sources).
- **`source_name` provenance through mrbc**: the host `mrbc` records
   the input filename; a `__FILE__`-override needs either a mrbc
   wrapper convention or envelope metadata. Phase 1 accepts mrbc's
   filename; revisit when diagnostics land.
- **Manifest vs envelope**: per-entry metadata may ride in a sidecar
   manifest (phase 1 choice) or extend the envelope; envelope growth is
   fingerprint-relevant, so prefer sidecar + strict envelope.

## Requirements already satisfied by existing primitives

Typed envelopes, SHA-256, compatibility fingerprints + epoch,
application fingerprints, authority manifest tables, feature manifest,
host-mrbc pipeline, pure-Zig artifact framing, cross-version fixture
machinery, deterministic-gas testing.
