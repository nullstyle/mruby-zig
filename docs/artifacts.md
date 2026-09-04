# Artifacts: typed RITE images and state capsules

Two artifact types cross process and trust boundaries deliberately:
**RiteImage** (compiled, executable input) and **StateCapsule** (bounded,
inert value graphs). Both carry a stable outer envelope with framing,
length checks, and a SHA-256 checksum.

## Typed RITE images

Use typed RITE images to compile once and execute only in a compatible
sandbox. The wrapper records mruby-zig's generated compatibility fingerprint;
an optional application fingerprint also binds the image to your bootstrap
contract:

```zig
const app: mruby.artifact.ApplicationFingerprint = .{ .bytes = app_digest };

var image = try mruby.sandbox.compileRite(allocator, worker_source, .{
    .source_name = "worker.rb",
    .application = app,
});
defer image.deinit(allocator);

var iso_boot = try mruby.sandbox.BootstrapIsolate.spawn(
    mruby.sandbox.Policy.trusted(.{
        .artifacts = .{ .application = app },
    }),
);
defer iso_boot.deinit();
const iso = try iso_boot.seal();
defer iso.deinit();

const result = try iso.runRite(image.view());
```

The source-compilation example requires `features.has_compiler`. With
`-Dno-compiler`, generate artifacts through CodeDB during the build and keep
using the same typed execution interface.

`source_name` controls `__FILE__` even when debug information is omitted.
`RiteImage` owns only `encoded`; pass the same allocator used by
`compileRite` to `deinit`. Across a process boundary, send
`image.view().bytes` and construct `.{ .bytes = received_bytes }` at the
destination. Every `runRite` revalidates the envelope, checksum, generated
compatibility fingerprint, application fingerprint, and byte ceiling. For
application-independent images executed in a disposable OS process, see the
one-shot [worker guide](workers.md).

### Compatibility policy

The generated compatibility fingerprint covers the mruby version, the
hash-pinned package identity, RITE binary/VM versions, a package-owned
compatibility epoch, target traits (pointer width, endianness, Integer and
Float widths, boxing mode, inline-float flag), semantic build defines, the
ordered gem selection, the canonical presym table digest, and the
generated-configuration identity. An image executes only on a build whose
fingerprint matches exactly, so compiler-profile, gem-set, or target changes correctly reject
previously produced images rather than executing them against a different
object model. Applications add their own fingerprint on top to pin their
bootstrap contract (host classes and methods the compiled code expects).

The compatibility epoch is bumped when this package changes an artifact
format in a way that should reject all previously produced artifacts.

## CodeDB: compile application Ruby during the build

CodeDB makes Ruby source a tracked Zig build input. The host `mrbc` compiles
each source twice and rejects different outputs. A pure-Zig tool wraps the
RITE for the configured target, writes each envelope as `<sha256>.rite`, and
generates an embedded manifest. No application source is parsed at runtime.

With the dependency named `mruby` in your `build.zig.zon`:

```zig
// build.zig; dep is the same configured dependency used by the executable.
const dep = b.dependency("mruby", .{ .target = target, .optimize = optimize });
const code = try @import("mruby").addCodeDB(b, dep, .{ .sources = &.{.{
    .name = "invoice",
    .source = b.path("ruby/invoice.rb"),
    .source_name = "billing/invoice.rb",
    // .application = app_digest, // optional [32]u8 bootstrap identity
}} });
exe.root_module.addImport("mruby", dep.module("mruby"));
exe.root_module.addImport("app_code", code.manifest);
```

```zig
const app_code = @import("app_code");
const result = try iso.runArtifact(app_code, "invoice");
const entry = mruby.codedb.lookup(app_code, "invoice").?;
std.debug.print("executed {s}\n", .{entry.source_name});
```

`addCodeDB` accepts a nonempty array of sources and returns `manifest` (a
build module) and `directory` (the cache-owned manifest and artifact files).
It orders dependencies before their dependents, choosing the smallest logical
name when several modules are ready. Duplicate or empty names are errors.
`source_name` defaults to `<name>.rb`. It must be a relative slash-separated
path without traversal, control characters, or nonportable filename
punctuation, and cannot start with `-`. The helper stages the original bytes
under that name before compilation, so `__FILE__` and Ruby backtrace frames
agree with the manifest even when the checkout or cache moves. Choose
`source_name` explicitly when logical names contain punctuation or when
diagnostics should use a path different from the input location.

The generated module exposes `format_major`, `format_minor`, `compatibility`,
`gem_set`, `gems` (the resolved selection), and `entries`. Each entry contains
`name`, `source_name`, `source_hash`, `artifact_hash`, `application`, `bytes`,
`entrypoint`, and `dependencies`, plus the authority metadata below. Both hashes are SHA-256: the first covers
the original Ruby bytes, the second covers the complete typed envelope.
`application` is an optional
32-byte digest. Manifest schema versions are independent of the existing
RITE envelope version and compatibility epoch.

`lookup(manifest, name)` returns metadata, while `find(manifest, name)` returns
a borrowed `RiteImageView` suitable for `worker.runRite`. Both return null for
unknown names. `iso.runArtifact(manifest, name)` (also available as
`mruby.codedb.run`) reports `UnknownArtifact` for a missing name. Generated
manifests with an unsupported schema or a different target/gem fingerprint
fail at compile time when used through CodeDB. Every execution still follows
`runRite` admission, including checksums, application identity, artifact size,
and sandbox limits. A matching application fingerprint must be configured in
the isolate's policy when the entry supplies one.

Metadata is trusted build output; checksums do not authenticate substitutions.
Each `runArtifact` call executes only the selected entry again, regardless of
its dependencies or entrypoint flag. Use the loader below for initialization.

### Declare dependencies and initialize once

Declare direct dependencies by logical name beside each source:

```zig
const code = try @import("mruby").addCodeDB(b, dep, .{ .sources = &.{
    .{
        .name = "billing",
        .source = b.path("ruby/billing.rb"),
        .dependencies = &.{"discounts"},
    },
    .{
        .name = "discounts",
        .source = b.path("ruby/discounts.rb"),
        .entrypoint = false,
    },
} });
```

`dependencies` defaults to an empty list; `entrypoint` defaults to true.
Setting it false marks a module which can only be reached through another
module when using the loader. The build rejects missing dependencies, repeated
edges, and cycles, naming the offending modules. Declaration order does not
affect the generated bundle. Dependencies are declarations by the application
author, not inferred from Ruby constants or method calls.

```zig
const first_load = try iso.loadArtifact(app_code, "billing"); // true
const loaded_again = try iso.loadArtifact(app_code, "billing"); // false
```

`loadArtifact` (also `mruby.codedb.load`) initializes the requested entrypoint
and only its transitive dependencies. Each module executes at most once in
that isolate, including shared dependencies in a diamond. Initializer return
values are discarded; keep definitions in Ruby globals or constants, then
call Ruby methods or use `runArtifact` for repeated application work. Neither
raw execution nor `runArtifact` updates the loader's initialization record.
The example uses globals so initialization also works with the restricted
policy's frozen object model. For class/module definitions under that policy,
reserve application namespaces during bootstrap before sealing; initializers
still obey the normal object-model restrictions.

The isolate owns the loader state and binds permanently to the first admitted
manifest. The entire load holds the isolate lock, prevalidates every unloaded
image before any initializer runs, and shares one per-execution gas allowance.
Concurrent or callback-reentrant loading returns `IsolateThreadBusy`. Cached
loads return false without starting a new execution or renewing gas.

Loader-specific failures are:

- `UnknownArtifact`: no such logical name.
- `NotEntrypoint`: direct loading of a dependency-only module.
- `CodeDBManifestMismatch`: this isolate already belongs to another manifest.
- `CodeDBPoisoned`: a previous initialization or execution-policy failure
  poisoned its loader. Side effects cannot be rolled back, so recovery and
  artifact-set replacement require a fresh isolate. Already-loaded entrypoints
  also reject further load requests after poisoning.

Name, graph-selection, busy, and envelope-admission failures execute no Ruby
and do not poison the loader. Runtime exceptions and policy failures retain
the ordinary isolate diagnostics. Schema 1.1 adds graph metadata without
changing RITE envelopes or their compatibility epoch. Schema 1.0 and bare
manifests remain usable as independent entrypoints without dependencies.

### Declare available authority

CodeDB checks the complete linked core/compiler/gem profile, every declared
host binding, and each artifact's own and transitive `required_authority`.
Unused bindings still count. The default worker tier uses the existing worker
allow-list. A trusted tier admits all known authority kinds; a custom tier
supplies an explicit `AuthoritySet`. Unknown bits always fail.

```zig
const CodeDB = @import("mruby").CodeDB;
const code = try @import("mruby").addCodeDB(b, dep, .{
    .tier = .worker,
    .host_bindings = &.{.{
        .name = "Clock.now",
        .authority = CodeDB.AuthoritySet.init(&.{.clock}),
    }},
    .sources = &.{.{
        .name = "billing",
        .source = b.path("ruby/billing.rb"),
        .required_authority = CodeDB.AuthoritySet.init(&.{.entropy}),
        .host_bindings = &.{"Clock.now"},
    }},
});
```

The catalogue's `authority` field is required; a binding with no authority
uses `.empty` explicitly. Source requirements and host references default to
empty. A binding that reads files requires `.filesystem` even if no artifact
references it, so the worker tier rejects that entire bundle. Use `.tier =
.trusted` or an audited `.tier = .{ .custom = CodeDB.AuthoritySet.init(...) }`
when those capabilities are intended. A custom mask must include the full
linked profile, not only the operations visible in the source. Restricted
runtime policies do not subtract from this conservative build classification.

The bootstrap owner must catalogue all host bindings available to guests.
CodeDB checks declared references against this catalogue; it cannot discover
arbitrary host callbacks registered later or verify that their declared masks
are accurate. Host-binding names are catalogue keys, not registration calls.
Changing the tier never grants capabilities or selects an isolate policy.

The generator rejects forbidden authority before publishing its output, with
artifact and profile/binding attribution. It uses the profile built into the
configured dependency's host tool. Schema 1.2 records:

- `authority_tier` and `authority_allowed` (a `u16` mask);
- `authority_profile` and `host_bindings`, each containing `{ name, bits }`;
- each entry's `required_authority` and `effective_authority` (`u16` masks),
  plus its `host_bindings` names.

Use `mruby.features.AuthoritySet.fromBits(entry.effective_authority)` to inspect
kinds at runtime. Importing a schema 1.2 manifest through lookup, execution, or
loading checks the profile against the consuming build, recomputes effective
authority, and rejects inconsistent tiers or masks at compile time. The sidecar
change leaves the typed envelope and compatibility epoch unchanged. Older
1.0/1.1 and bare manifests remain supported without this metadata gate; direct
`runRite` also retains its existing contract. Metadata remains trusted build
output and does not authenticate artifacts.

To remove runtime source compilation, configure the dependency with
`.@"no-compiler" = true` and pass that same dependency to `addCodeDB`. The
host compiler still generates the artifacts against the runtime-only target's
identity. `run-codedb-demo -Dno-compiler` exercises the complete pipeline,
including its restricted invoice job and state capsule output. Runtime
`compileRite` is unavailable in that profile. See the
[profile options](getting-started.md#runtime-only-profile) and
[measured binary sizes](benchmarks.md#binary-size).

Ruby-level `require` remains deferred; declared loading is the current interface.

Run `mise x -- zig build run-codedb-demo` for dependency initialization and
repeated invoice jobs under a restricted policy, with host-created inputs and
a capsule result. The focused suite is `mise x -- zig build test-codedb`, also
included in `zig build test`.

## State capsules

State capsules move supported value graphs without executing guest methods:

```zig
const schema: mruby.artifact.Schema = .{
    .id = job_schema_id,
    .major = 1,
    .minor = 0,
};

const root = try producer.run(
    "count = \"count\".freeze; {count => 41, :jobs => [1, 2, 3]}",
);
var capsule = try producer.exportValue(allocator, root, .{ .schema = schema });
defer capsule.deinit(allocator);

// Send capsule.view().bytes to another process.
const restored = try worker.importValue(
    .{ .bytes = received_capsule_bytes },
    .{ .accepted_schema = .{
        .id = job_schema_id,
        .major = 1,
        .minor = 2,
    } },
);
```

A destination accepts the same schema ID and major version when the producer's
minor version is no newer. Null accepts only schema-less capsules. Version 1
preserves cycles, aliases, binary64 bits, frozen String/Array/Hash state, and
non-proc Hash defaults. Hash keys are limited to Integer, Float, Symbol, and
frozen exact-core String; subclasses, instance variables, default procs,
Binding, Proc, Fiber, and native data are rejected. This strict subset keeps
import/export inert: no `_dump`, `_load`, `hash`, `eql?`, constructors, or
other guest hooks run.

`StateCapsule`, like `RiteImage`, owns only its encoded bytes and is freed with
the allocator passed to `exportValue`. Imported Ruby allocations use the
destination isolate's allocator and memory policy. Per-call capsule limits can
tighten, never relax, the ceilings copied from `Policy.artifacts` at spawn.
Independent non-relaxable safety ceilings also bound total Hash pairs, exact
simulated insertion probes, and conservative String-key comparison work.
Export and import run the same preflight and report `CapsuleLimitExceeded` at
the offending key for pathological collision sets.

## Wire-format stance

RITE is executable input; StateCapsule is bounded inert data. Their SHA-256
checksums detect corruption, not substitution, so authenticate either artifact
when it crosses a trust boundary (especially RITE). Neither type is a VM,
Binding, Fiber, or continuation snapshot. A StateCapsule describes values
only: the destination's policy, classes, and host environment are supplied by
the importing isolate.

A coverage-guided fuzz target (`zig build fuzz-state-capsule`) exercises the
pure parser, and a golden producer/consumer subprocess fixture verifies byte
stability and restoration into a separate OS process.

Cross-version fixtures in `src/tests_artifacts/` pin admission behavior
against bytes produced by the **v0.3.0** tag (see its `MANIFEST.md` for
provenance): the old RITE image is rejected with `IncompatibleRiteImage`
(its compatibility fingerprint predates later presym/semantic-identity
changes) while the old state capsule restores fully — capsule envelopes
carry schema identity, not a build fingerprint, so format v1 is
forward-compatible across releases.
