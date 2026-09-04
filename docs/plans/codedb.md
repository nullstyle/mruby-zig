# CodeDB: build-managed Ruby artifacts for mruby-zig

Status: phases 1–5 complete. Ruby-level require remains deferred.
CodeDB adapts the Rubinius idea of compiled code with queryable metadata
to this project's typed artifacts and build pipeline.

## Contract

CodeDB is a build-managed store of typed RITE envelopes with an embedded
manifest. Each artifact is addressed by the SHA-256 of its **complete
envelope**, so compatibility or application-identity changes produce a
new address even when the raw bytecode is unchanged. The manifest records
the exact target compatibility fingerprint and resolved gem selection once.
Each entry records:

- a logical name and stable source name;
- the original source SHA-256 and final artifact SHA-256;
- an optional application fingerprint;
- declared direct dependencies and an entrypoint flag (manifest schema 1.1);
- declared and effective authority plus host-binding references (schema 1.2);
- the embedded envelope bytes.

The manifest is a separately versioned sidecar. Adding manifest metadata
does not change the envelope format or its compatibility epoch. Envelope
changes follow the existing artifact versioning contract. Schema rejection
is tested separately from admission of existing old-producer RITE fixtures.

The source name is a declared, relative path staged for the host `mrbc`.
That path is recorded in the compiled RITE and manifest. This keeps
`__FILE__` and diagnostics independent of the checkout and Zig cache
location; the source hash preserves the identity of the original input.

Metadata describes a trusted build output. It does not grant authority,
authenticate an untrusted artifact, or bypass runtime admission. Execution
uses `Isolate.runRite` and its compatibility, application, resource, and
capability policy checks.

## Phases 1–2: build pipeline and loader

The reusable build helper accepts logical names, Ruby `LazyPath` inputs,
stable source names, and optional application identity. It uses the host
`mrbc` from bootstrap while wrapping output against the **target's**
generated compatibility identity. It returns the generated manifest for
embedding in the consumer.

Each source is compiled twice from the same stable path in independent
compile steps, and the build rejects unequal bytecode. The pure-Zig
envelope tool wraps the bytecode, hashes source and envelope, and emits
the addressed artifacts plus manifest. Input dependencies participate in
Zig's build cache. Repeated compilation checks determinism for the current
compiler and inputs; it is not a promise that different compiler versions
produce identical artifacts.

At runtime, `mruby.codedb` supports lookup and metadata inspection, and
`Isolate.runArtifact` provides named execution. Unknown names fail before
guest execution; known entries enter the normal RITE admission path. Each
`runArtifact` call executes the artifact again. Phase 3 adds separate load-once
initialization without changing that behavior.

Completion includes a realistic host/Ruby example, metadata and artifact
hash checks, stable `__FILE__` coverage, invalid-name/source-path rejection,
schema rejection, admission and resource-policy tests, and execution rejection
of an existing v0.3.0 RITE fixture through a manifest entry. The example
executes build-compiled Ruby without parsing that application source at
runtime. The default target library links the compiler; phase 5 adds an optional
runtime-only profile.

Validated with the standard and minimal gem sets in Debug and ReleaseSafe,
plus an aarch64-linux-gnu cross-compilation check. The downstream fixture
under `tools/codedb_consumer` exercises the public build helper, escaped
logical names, and compile-time schema/profile rejection. Separate caches
produce byte-identical manifest and artifact files.

## Phase 3: declared module graph and isolate-owned loading

Sources declare `dependencies` by logical name and `entrypoint` (true by
default). Dependency-only modules set `entrypoint = false`. We do not infer
security-relevant dependencies or definitions from constant
references: dynamic dispatch and metaprogramming make that incomplete.
Optional `defines`/`expects` diagnostics remain future work; they would be
claims by the application author rather than proofs extracted from RITE.

The build and generator validate unique module names, existing dependencies,
no repeated edges, and an acyclic graph. They emit a deterministic ordering
with dependencies first and the lexicographically smallest ready name next.
Dependency declarations are serialized in lexical order. Library-only bundles
are valid, although loading requires a declared entrypoint.

`Isolate.loadArtifact(manifest, entrypoint)` returns true on first load and
false when already initialized. It checks every unloaded image in the required
closure before running any Ruby, then executes the closure under one isolate
lock and one execution budget. It discards initializer results and restores
the GC arena after each module. Definitions survive through Ruby globals or
constants. Callback reentry and concurrent loads are rejected.

The isolate owns loaded flags, manifest identity, and poison state. Failed
initialization does not mark the failing module loaded; because Ruby side
effects cannot be rolled back, any outer execution failure poisons the loader,
including policy failure detected after the last initializer. Unknown names,
non-entrypoints, manifest mismatch, busy admission, and invalid envelopes leave
the generation unchanged. Recovery and replacement use a fresh isolate.

Graph metadata is a sidecar minor-version addition (1.1). The RITE format and
compatibility epoch are unchanged. Version 1.0 and bare manifests retain
independent-entrypoint behavior; `runArtifact` remains explicit repeated
execution and neither resolves dependencies nor records initialization.

App-level require remains deferred. If exposed, it resolves only declared
names within this graph and does not search the filesystem or compile source.
Acceptance tests cover missing/repeated edges, cycles, diamonds, repeat loads, initialization
failure, generation isolation, aggregate gas, GC roots, and concurrent access.

Phase 3 passes the full standard/minimal Debug and ReleaseSafe suites and the
aarch64-linux-gnu cross-compilation check. The downstream fixture and CI verify
invalid-graph diagnostics and byte-identical output with reversed declarations
in a separate cache.

## Phase 4: conservative authority gate

The gate uses the union of authority available from the complete linked
core/compiler/gem profile and **every** declared host binding, including unused
bindings. Each artifact adds its own `required_authority` and its transitive
dependencies' requirements. Declarations never subtract linked authority based
on bytecode references: Ruby can reach methods dynamically.

`addCodeDB` defaults to `.tier = .worker`, using the existing worker allow-list.
`.trusted` admits all currently known kinds; `.custom = AuthoritySet.init(...)`
supplies an explicit allow-list. Unknown bits fail in every tier, including
trusted. The helper rejects invalid declarations before adding compile steps;
the generator performs the full gate against its immutable configured profile
before reading artifacts or publishing output. An application cannot substitute
a smaller profile through build-helper arguments. Package test/example bundles
explicitly use trusted so they remain buildable with every selectable gem set;
that declaration does not change their runtime policies.

Host bindings use a named catalogue with a required authority set, and artifacts
list the catalogue names they expect. Missing references, duplicate catalogue
names/references, forbidden requirements, and unknown bits fail with source
attribution. The bootstrap owner must catalogue **all** bindings it exposes to
guest code. Arbitrary host registration is not introspected: catalogue
completeness is a trusted host contract, and an absent reference is the specific
undeclared-binding error the gate can detect.

Schema 1.2 records the tier and its concrete allow-list, profile and host
catalogues with individual masks, and declared/effective authority for each
artifact. Consumer compilation compares the profile to the current linked
classification, recomputes the full gate, and checks effective masks. This
catches stale classifications even when bytecode compatibility is unchanged.
Host catalogue and reference declaration order do not affect generated bytes.
The typed envelope format and compatibility epoch are unchanged.

The gate supplements runtime policy and the existing worker gate; it does not
grant capabilities or force an isolate to use a particular policy. Versions
1.0/1.1 and bare manifests remain supported outside this metadata contract, as
does direct `runRite`. Narrower classifications require audited runtime
restrictions or a smaller linked profile, with tests showing the authority is
unavailable.

Coverage includes unused host/profile authority, transitive declarations,
missing/duplicate names, unknown bits, custom and trusted tiers, deterministic
catalogue ordering, and consumer rejection of stale profile, modified effective
masks, and inconsistent named tiers.

Phase 4 passes the full standard Debug and minimal ReleaseSafe suites,
the aarch64-linux-gnu ReleaseSafe cross-compilation check, and the downstream
worker/trusted/custom-tier fixtures. Separate-cache builds with reversed source,
host-catalogue, and host-reference declarations produce byte-identical bundles.

## Phase 5: runtime-only profile

`-Dno-compiler` retains the build-time host compiler and removes target
parser/codegen C sources, compiler presym inputs, and compiler-dependent eval
gems. Preset roots requiring the compiler are filtered before dependency
closure; explicitly adding such a gem fails. Standard retains independent
binding support, while minimal becomes core-only.

`features.has_compiler` records the choice, and source-compilation interfaces
return `CompilerUnavailable` before execution or compiler allocation. CodeDB,
raw irep execution, typed RITE admission, capsules, and worker execution remain
available. Target compiler presence is a semantic compatibility input; its
authority source appears only when linked. The sidecar/envelope formats and
compatibility epoch are unchanged.

RNG setup captures upstream's original native seeding operation during protected
sandbox bootstrap, invokes it inside C protection at seal, restores the GC
arena, and masks reseeding methods. This preserves the low-32-bit seed contract
without parsing or executing setup Ruby. A missing random gem still fails
capability application. Tests compare the native sequence with upstream source
seeding and verify bootstrap method overrides cannot replace the captured call.

`MRB_USE_DEBUG_HOOK` stays enabled. Artifact tests cover gas, ensure cleanup,
deadlines, external termination, memory/call-depth limits, load-once initialization,
and typed worker results, including deterministic RNG and input capsules.
`test-runtime-only` runs the artifact suite under either compiler profile.
The runtime-only `test`/`check` graphs retain compiler-independent checks and
omit source-driven suites; source-only run steps report a clear
unsupported-profile error when requested. The CodeDB demo remains runnable.

`tools/check_runtime_only_symbols.sh` inspects actual unstripped executables,
requires runtime VM/sandbox symbols, and rejects parser, codegen, compiler-context,
source-loading, and compiler-backed eval symbols, including undefined references.
CI checks both presets and optimization modes on Linux/macOS, plus cross builds.
See [binary-size measurements](../benchmarks.md#binary-size) for matching
compiler-enabled/runtime-only commands and results.

Validation passes for compiler-enabled and runtime-only standard/minimal
presets in Debug/ReleaseSafe on macOS arm64 and Linux arm64. Runtime-only
configurations pass `test check install`; downstream consumers, demos, and
workers pass symbol audits. The aarch64-linux-gnu ReleaseSafe cross-compilation
check also passes. CI compares compiler-profile fingerprints with identical
resolved gems, and the compiler-enabled audit baseline is rejected as expected.

## Release validation

The packaged-consumer smoke test fetches a checkout snapshot as a hash-pinned
archive into a fresh external project. It builds a compiler-free application
and matching worker, audits both binaries, removes all temporary source and
cache directories, and runs the relocated installation from an empty working
directory. This covers the `.paths` package allowlist and deployment behavior
that the checkout-relative downstream fixture does not exercise. Both presets
run on Linux and macOS in CI; see [release validation](../maintenance.md#release-and-versioning).

The release rehearsal passes for standard and minimal presets in ReleaseSafe
on macOS arm64 and Linux arm64 (Docker through `act`). On both platforms, all
four runtime-only preset/optimization combinations pass `test check install`
and installed-binary symbol audits. Independent reviews of the runtime and
build pipeline found no actionable issues. The configured GitHub-hosted Linux
jobs also cover x86_64; the local Linux rehearsal exercises arm64.

The Linux main and gem-set workflows pass through `act`, including manifest
mismatch rejection, graph and authority errors, declaration-order
reproducibility, explicit tiers, and removal of Enumerator and Pack gems.
