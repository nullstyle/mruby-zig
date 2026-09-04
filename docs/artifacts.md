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

var worker_boot = try mruby.sandbox.BootstrapIsolate.spawn(
    mruby.sandbox.Policy.trusted(.{
        .artifacts = .{ .application = app },
    }),
);
defer worker_boot.deinit();
const worker = try worker_boot.seal();
defer worker.deinit();

const result = try worker.runRite(image.view());
```

`source_name` controls `__FILE__` even when debug information is omitted.
`RiteImage` owns only `encoded`; pass the same allocator used by
`compileRite` to `deinit`. Across a process boundary, send
`image.view().bytes` and construct `.{ .bytes = received_bytes }` at the
destination. Every `runRite` revalidates the envelope, checksum, generated
compatibility fingerprint, application fingerprint, and byte ceiling.

### Compatibility policy

The generated compatibility fingerprint covers the mruby version, the
hash-pinned package identity, RITE binary/VM versions, a package-owned
compatibility epoch, target traits (pointer width, endianness, Integer and
Float widths, boxing mode, inline-float flag), semantic build defines, the
ordered gem selection, the canonical presym table digest, and the
generated-configuration identity. An image executes only on a build whose
fingerprint matches exactly, so gem-set or target changes correctly reject
previously produced images rather than executing them against a different
object model. Applications add their own fingerprint on top to pin their
bootstrap contract (host classes and methods the compiled code expects).

The compatibility epoch is bumped when this package changes an artifact
format in a way that should reject all previously produced artifacts.

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
