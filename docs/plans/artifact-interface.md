# RITE images and value capsules: public interface design

Status: approved interface
Scope: follow-up to [mruby state serialization feasibility](mruby-state-serialization.md)
Design date: 2026-08-28

## Decision

Expose two sibling artifact types behind four semantically honest operations:

```zig
sandbox.compileRite(...)
Isolate.runRite(...)
Isolate.exportValue(...)
Isolate.importValue(...)
```

- `RiteImage` is executable code for a matching generated compatibility
  fingerprint.
- `StateCapsule` is bounded, non-executable value data.

Do not put both behind a generic `load` operation: `runRite` executes Ruby and
consumes sandbox resources, while `importValue` decodes inert data without
guest dispatch. Do not call either artifact a VM checkpoint. Neither operation
suspends or resumes an `mrb_state`, Fiber, Proc, or Binding.

Do not add a code-plus-state `Bundle` in version 1. A bundle would currently
copy two byte slices and sequence two existing calls without connecting their
results or providing transactional behavior. Under the deletion test, callers
regain only a small transport struct. That is not enough leverage to justify a
manifest, validation, ordering, failure, and evolution interface in this
module.

The external seam remains `sandbox.Isolate`. It already owns the destination
VM, policy, phase admission, allocator attribution, error mapping, and value
lifetime. Byte ownership and wire types live in a new `mruby.artifact` module;
operations that inspect or construct Ruby values remain methods on `Isolate`.

## Alternatives considered

### One tagged load operation

The smallest-looking design is:

```zig
const result = try iso.load(.{ .rite = image });
const root = try iso.load(.{ .state = capsule });
```

It has a small method count but a misleading interface. Callers must remember
that one union tag executes attacker-controlled code and starts an execution
budget while another performs a bounded host control operation. The generic
verb hides the module's most important invariant, so this is shallow despite
its compact syntax.

### Typed RITE and state artifacts

Distinct types and verbs keep the common paths short while making trust and
execution visible at each call site. This is the recommended design. The
implementation hides RITE compatibility, graph identity, quotas, GC rooting,
allocator attribution, and lifecycle admission behind the `Isolate` seam.

### Generic multi-payload artifacts

A flexible design could add named payloads, manifests, selection, dependency
graphs, signatures, codec registries, retained ireps, and staged execution. It
would support sophisticated deployment formats, but ordinary users would need
to learn nearly as much machinery as the implementation contains.

Defer that design until at least two real payload kinds beyond RITE and state,
or repeated downstream transport implementations, establish what varies. The
wire formats should reserve versioned extension points without publishing
hypothetical adapters now.

## Recommended interface

### Artifact types

```zig
const std = @import("std");

/// Domain-separated digest of the embedding application's bootstrap
/// contract. It is not interchangeable with the generated RITE build digest.
pub const ApplicationFingerprint = struct {
    bytes: [32]u8,
};

pub const Schema = struct {
    id: [16]u8,
    major: u16,
    minor: u16 = 0,
};

pub const CapsuleLimits = struct {
    max_encoded_bytes: usize = 16 * 1024 * 1024,
    max_nodes: usize = 100_000,
    max_total_edges: usize = 500_000,
    max_depth: usize = 256,
    max_string_bytes: usize = 8 * 1024 * 1024,
    max_symbol_bytes: usize = 1024 * 1024,
};

pub const Limits = struct {
    max_rite_bytes: usize = 16 * 1024 * 1024,
    capsule: CapsuleLimits = .{},
};

/// What typed artifacts an Isolate admits. The implementation copies and
/// resolves this at spawn; later mutation of the public Policy value cannot
/// relax an existing Isolate.
pub const Acceptance = struct {
    limits: Limits = .{},

    /// Exact optional equality for RITE images: an image and destination must
    /// either both omit this or carry the same value.
    application: ?ApplicationFingerprint = null,
};

/// Borrowed, untrusted bytes. This is not a validation proof; every consumer
/// validates framing, checksum, compatibility, and policy limits again.
pub const RiteImageView = struct {
    bytes: []const u8,
};

/// Owned mruby-zig envelope around raw RITE bytes.
pub const RiteImage = struct {
    encoded: []u8,

    pub fn view(self: *const RiteImage) RiteImageView {
        return .{ .bytes = self.encoded };
    }

    pub fn deinit(
        self: *RiteImage,
        allocator: std.mem.Allocator,
    ) void;
};

/// Borrowed, untrusted bytes. Isolate.importValue performs complete validation.
pub const StateCapsuleView = struct {
    bytes: []const u8,
};

pub const StateCapsule = struct {
    encoded: []u8,

    pub fn view(self: *const StateCapsule) StateCapsuleView {
        return .{ .bytes = self.encoded };
    }

    pub fn deinit(
        self: *StateCapsule,
        allocator: std.mem.Allocator,
    ) void;
};
```

The allocator is not artifact state. It is used only to allocate and free the
host-owned encoded bytes, so the owned types do not retain it. The caller must
pass the same allocator to creation and `deinit`, and that allocator must remain
valid until destruction. `deinit` poisons the struct after freeing its bytes.
Allocator identity is never encoded. Borrowed views received over IPC need no
allocator, and destination Ruby allocations during `importValue` use the
destination Isolate's existing allocation and memory-policy machinery.

Owned artifacts remain move-only by convention: Zig structs are copyable, so
callers must not copy an owned artifact and deinitialize both copies.

Views have no `open` method in version 1. Constructing one is infallible and
does not suggest that partial parsing has established trust:

```zig
const incoming: artifact.StateCapsuleView = .{ .bytes = received_bytes };
const restored = try iso.importValue(incoming, .{});
```

### Compilation and isolate operations

```zig
pub const CompileRiteOptions = struct {
    include_debug: bool = false,
    source_name: []const u8 = "(mruby-zig)",
    application: ?artifact.ApplicationFingerprint = null,
};

pub fn compileRite(
    allocator: std.mem.Allocator,
    source: []const u8,
    options: CompileRiteOptions,
) CompileRiteError!artifact.RiteImage;

pub const ExportValueOptions = struct {
    /// Optional per-operation ceilings, minimized against cached policy.
    limits: ?artifact.CapsuleLimits = null,
    schema: ?artifact.Schema = null,
};

pub const ImportValueOptions = struct {
    /// Optional per-operation ceilings. The implementation takes the
    /// component-wise minimum with the Isolate's resolved acceptance limits.
    limits: ?artifact.CapsuleLimits = null,

    /// Null accepts only a schema-less capsule. Otherwise IDs and major
    /// versions must match and the producer minor must not be newer.
    accepted_schema: ?artifact.Schema = null,
};

pub const Policy = struct {
    limits: Limits = .{},
    capabilities: Capabilities = .{},
    artifacts: artifact.Acceptance = .{},
};

pub const Isolate = struct {
    /// Execute a typed RITE image under the normal sandbox execution policy.
    pub fn runRite(
        iso: *Isolate,
        image: artifact.RiteImageView,
    ) RunRiteError!Value;

    /// Encode one deliberate root and its supported reachable graph.
    pub fn exportValue(
        iso: *Isolate,
        allocator: std.mem.Allocator,
        root: Value,
        options: ExportValueOptions,
    ) ExportValueError!artifact.StateCapsule;

    /// Decode bounded data into this Isolate without guest method dispatch.
    pub fn importValue(
        iso: *Isolate,
        capsule: artifact.StateCapsuleView,
        options: ImportValueOptions,
    ) ImportValueError!Value;

    /// Detail for the last failed value export/import. It does not replace
    /// lastError(), which remains Ruby-exception metadata.
    pub fn lastArtifactError(iso: *const Isolate) ?ArtifactDiagnostic;
};
```

The common caller learns four operations. `ApplicationFingerprint`, schemas,
and per-call limit tightening are optional; ordinary calls use empty options.

`compileRite` takes an explicit allocator and returns an owned type, unlike the
legacy `compile` function's process-global allocation convention. Debug data is
off by default to match the current raw RITE behavior; enabling it maps to
mruby's dump flag and does not change execution semantics. `source_name`
controls `__FILE__` whether or not debug data is included. Embedded NUL is
rejected as `InvalidSourceName`; legacy `compile` keeps its existing `"(null)"`
source-name behavior.

### Errors and diagnostics

```zig
pub const FramingError = error{
    InvalidArtifact,
    ChecksumMismatch,
    UnsupportedArtifactVersion,
    ArtifactLimitExceeded,
};

pub const CompileRiteError = std.mem.Allocator.Error || error{
    CompileFailed,
    InvalidSourceName,
};

pub const RunRiteError = FramingError || error{
    IncompatibleRiteImage,
    IsolatePreparing,
    IsolateThreadBusy,
    RubyException,
    ScriptTerminated,
    DeadlineExceeded,
    GasExhausted,
    MemoryLimitExceeded,
    CallDepthExceeded,
    CapabilityApplicationFailed,
};

pub const ValueCodecError = FramingError || error{
    ForeignValue,
    UnsupportedValue,
    UnsupportedContainerState,
    UnsupportedHashKey,
    NumericOutOfRange,
    CapsuleLimitExceeded,
    SchemaMismatch,
    IsolatePreparing,
    IsolateThreadBusy,
    MemoryLimitExceeded,
    ArtifactConstructionFailed,
};

pub const ExportValueError = std.mem.Allocator.Error || ValueCodecError;
pub const ImportValueError = std.mem.Allocator.Error || ValueCodecError;

pub const ArtifactDiagnostic = struct {
    kind: Kind,
    encoded_offset: ?usize = null,
    graph_path: ?[]const u8 = null,
    value_type: ?Value.Type = null,

    pub const Kind = enum {
        invalid_envelope,
        checksum_mismatch,
        unsupported_version,
        limit_exceeded,
        foreign_value,
        unsupported_value,
        unsupported_container_state,
        unsupported_hash_key,
        numeric_out_of_range,
        schema_mismatch,
        dangling_reference,
        duplicate_object_id,
        duplicate_hash_key,
        construction_failed,
    };
};
```

Typed errors serve ordinary control flow. `lastArtifactError` makes an
unsupported nested value actionable by reporting a graph path and type. Its
slices are borrowed until the next value artifact operation or isolate
destruction. RITE framing/compatibility failures need no graph diagnostic and
do not populate it.

`ArtifactLimitExceeded` is reserved for the outer encoded-byte ceiling;
`CapsuleLimitExceeded` covers graph quotas such as nodes, edges, depth, and
aggregate string/symbol bytes. `OutOfMemory` identifies caller/process scratch
allocation failure. `MemoryLimitExceeded` means destination Ruby construction
was refused by the Isolate's memory policy. An unexpected protected mruby
failure during construction is `ArtifactConstructionFailed` rather than a
guest `RubyException`.

## Stable wire format

Both types use this 128-byte, big-endian envelope followed by the payload:

| Offset | Size | Meaning |
| ---: | ---: | --- |
| 0 | 8 | `MRZARTF\0` |
| 8 | 2 | format major `1` |
| 10 | 2 | format minor `0` |
| 12 | 1 | kind: RITE `1`, StateCapsule `2` |
| 13 | 1 | kind-specific flags |
| 14 | 2 | header length `128` |
| 16 | 8 | payload length |
| 24 | 64 | kind-specific metadata |
| 88 | 32 | SHA-256 checksum |
| 120 | 8 | zero-reserved |
| 128 | N | payload |

The checksum covers the domain `mruby-zig/artifact-checksum/v1\0`, the header
with its checksum bytes zeroed, and the payload. Unknown flags, nonzero
reserved bytes, trailing data, and inconsistent lengths are invalid.

For RITE, metadata bytes 24–55 contain the generated compatibility
fingerprint. Bytes 56–87 contain the optional application fingerprint and flag
bit 0 records its presence; the bytes must be zero when absent. The generated
fingerprint covers the pinned mruby source, RITE/VM versions, shim
compatibility epoch, widths/endianness/numeric boxing, semantic defines,
ordered gems, and presym digest. It excludes OS, libc, optimization mode,
sanitizers, and CPU name so semantically identical targets can match.

For StateCapsule, metadata bytes 24–39 contain the optional schema ID, bytes
40–41 its major, and bytes 42–43 its minor; flag bit 0 records presence and all
remaining metadata must be zero. State payloads begin with `node_count:u32`,
`edge_count:u32`, and one root reference. Reference tags encode nil, false,
true, signed 64-bit integer, binary64 bits, symbol bytes, or a node ID. Node
records contain `id:u32`, kind, flags, zero-reserved bytes, body length, and
body; kinds are String, Array, and Hash. Flag bit 0 preserves frozen state and
Hash flag bit 1 records a non-proc default edge.

Object IDs are assigned by canonical breadth-first first encounter. Arrays are
scanned in element order; Hashes scan each insertion-ordered key then value,
followed by the default. Records appear in ID order, all nodes are reachable,
and the first reference to an unseen node introduces the next ID.

## Usage

### Compile and run RITE

```zig
var image = try mruby.sandbox.compileRite(
    allocator,
    "[1, 2, 3].map { |x| x * x }",
    .{ .source_name = "squares.rb" },
);
defer image.deinit(allocator);

const worker = try mruby.sandbox.Isolate.spawn(.{});
defer worker.deinit();

const squares = try worker.runRite(image.view());
```

Across a process boundary, transmit `image.view().bytes` and construct a
borrowed view at the destination:

```zig
const result = try worker.runRite(.{ .bytes = received_image_bytes });
```

### Export and import a value

```zig
const root = try producer.run(
    \\{"count" => 41, "worker" => "alpha"}
);

var capsule = try producer.exportValue(allocator, root, .{
    .schema = .{
        .id = job_schema_id,
        .major = 1,
        .minor = 0,
    },
});
defer capsule.deinit(allocator);

try channel.writeAll(capsule.view().bytes);
```

In the destination process:

```zig
const restored = try worker.importValue(
    .{ .bytes = received_capsule_bytes },
    .{
        .accepted_schema = .{
            .id = job_schema_id,
            .major = 1,
            .minor = 2,
        },
    },
);
```

The returned `Value` belongs to `worker`. The capsule bytes can be released
after `importValue` returns.

### Carry code and state together

Transport framing remains caller-owned. A protocol, file, or queue message can
carry the two slices without changing either artifact's semantics:

```zig
const WorkerMessage = struct {
    program: []const u8,
    state: []const u8,
};

const message: WorkerMessage = .{
    .program = program.view().bytes,
    .state = capsule.view().bytes,
};

try channel.send(message);
```

The destination chooses ordering and application wiring explicitly. Version 1
state contains no class-dependent custom objects, so importing before running
untrusted initialization avoids code side effects when state is malformed:

```zig
const state = try worker.importValue(.{ .bytes = message.state }, .{});
const entry = try worker.runRite(.{ .bytes = message.program });

// Returning a Proc is this application's convention, not an artifact rule.
const answer = try worker.call(entry, "call", .{state});
```

With `.per_execution` gas, `runRite` and the later `call` are separate outer
executions and therefore receive separate generations. Applications that need
one budget spanning initialization and invocation should make that an explicit
execution feature rather than hide it in serialization.

## Behavioral contract

### RITE images

- `compileRite` compiles but does not execute source.
- `RiteImage` is an mruby-zig envelope around raw RITE. It includes a format
  version, payload length, checksum, generated build fingerprint, and optional
  application fingerprint.
- The build fingerprint is domain-separated from application identity and
  covers mruby/RITE/opcode versions, numeric and boxing configuration, target
  details relevant to RITE, enabled gems, presym configuration, and the
  mruby-zig shim ABI. It contains no addresses or randomized data.
- `runRite` validates all framing and exact compatibility before guest-visible
  mutation or advancement of a per-execution gas generation.
- Optional application identity uses exact optional equality. An image cannot
  omit it to bypass a destination that expects one.
- RITE is executable input. A checksum detects corruption, not malicious
  replacement. Authentication, encryption, replay rules, persistence, and
  transport remain caller-owned.
- Once admitted, `runRite` has the same exception, gas, deadline, memory,
  call-depth, termination, GC-rooting, and `lastError` behavior as today's
  `runImage`.

### State capsules

Version 1 supports one root containing:

- nil and booleans;
- canonical signed 64-bit integers;
- IEEE-754 binary64 float bit patterns;
- length-delimited string and symbol bytes;
- arrays; and
- exact-core hashes whose keys are Integer, Float, Symbol, or frozen exact-core
  String.

All multibyte framing is endian-independent. Symbols are re-interned by bytes,
never copied by numeric ID. Import returns `NumericOutOfRange` when the
destination mruby configuration cannot preserve an encoded integer or float.
Object IDs and a two-pass decoder preserve cycles, aliases, and shared
references. Canonical first-encounter order makes equivalent traversal produce
stable bytes. Float bits, including NaN payloads and signed zero, are preserved.
The frozen bit of Strings, Arrays, and Hashes is preserved, as are Hash
insertion order and a non-proc default value. String keys must already be
frozen. Hash default procs, mutable String keys, and semantically duplicate
encoded keys are invalid or unsupported.

Version 1 rejects Proc, Binding, Fiber, class/module/singleton objects,
environments, exceptions/backtraces, CPTR, CData/RData, and native handles. It
also rejects String/Array/Hash subclasses, singleton-class variants, extra
instance variables, and default procs rather than flattening observable
behavior. It invokes no guest `_dump`, `_load`, `hash`, `eql?`, `to_s`,
constructor, or `method_missing` hook. Nil and boolean Hash keys are excluded
because mruby may dispatch `eql?` while inserting them; the strict key set
keeps import non-executing.

Hash construction also has non-relaxable implementation safety ceilings,
separate from public `CapsuleLimits`: at most 250,000 Hash pairs across a
capsule, 4,000,000 simulated bucket probes, 128 MiB of conservative
equal-length String-key comparison work, and per-Hash probes bounded by
`max(136, 12 * pair_count)`. The pure parser models the pinned mruby AR/HT
capacity, hash mixing, and triangular probing before C materialization;
rejection is `CapsuleLimitExceeded` at the offending key. Export runs the same
preflight over its finished bytes, so it cannot publish a capsule that an
equally configured import rejects solely for Hash work. The generated mruby
core patch hashes full-width Integers by numeric value and Symbols by FNV-1 of
their inert name bytes; both semantic markers are part of the RITE
compatibility fingerprint.

Schemas are application data contracts, not build compatibility. A null
accepted schema admits only schema-less capsules. Otherwise the ID and major
version must match and the producer minor must be no newer than the accepted
minor. The module performs no implicit migration.

### Isolate lifecycle

- One non-blocking operation lock covers `run`, `runImage`, `runRite`, `call`,
  `exportValue`, and `importValue`. Cross-thread same-Isolate races return
  `IsolateThreadBusy` without reading non-atomic lifecycle state.
- Existing same-thread nested guest execution from a host callback is
  preserved. Artifact operations require an idle, quiescent isolate; attempts
  from callbacks return `IsolateThreadBusy` before traversal or construction.
- Value artifact operations use a private artifact-preparation phase so guest
  execution cannot nest into them. `exportValue` also rejects a root owned by a
  different VM.
- These host control operations do not create a gas generation, start the
  guest lifetime deadline, apply lazy guest capabilities, or clear
  `lastError`. The decoder itself executes no guest bytecode.
- Imported allocations are attributed to the destination and enforced against
  the artifact limits cached at `Isolate.spawn` plus the ordinary isolate
  memory cap. A per-call limit can tighten, never relax, the cached ceiling.
- Import validates and constructs privately, publishing the root only after
  the graph succeeds. A returned heap object leaves one ordinary arena root;
  an immediate nil/boolean/integer/float/symbol needs and leaves no root.
  Failure restores the entry arena index. Symbol interning or GC may have
  occurred, but no partial root becomes visible.
- Graph traversal is iterative and bounded by encoded bytes, nodes, total
  edges, depth, string bytes, and symbol bytes. This prevents the product of
  per-container limits from becoming unbounded host work.

Views are convenience wrappers, not capabilities or proof tokens. They contain
public slices and can be forged or backed by mutable memory. Every consuming
operation performs overflow-safe length checks, checksum verification,
canonical validation, and destination-policy checks during that call. Callers
must not mutate backing bytes concurrently with an operation.

Typed RITE validation is admitted under the operation lock but happens before
execution admission. Invalid, corrupt, oversized, or incompatible input leaves
`lastError`, lifetime timing, gas generation, lazy capabilities, and
termination state unchanged. `terminate()` remains lock-free. Statistics,
diagnostics, direct VM access, and destruction retain their caller-serialized
precondition.

## Why no built-in bundle yet

A stable bundle becomes worthwhile when the module can hide behavior that
would otherwise be duplicated across callers, such as:

- an authenticated, canonical multi-payload manifest;
- complete preflight before any guest execution;
- selection and compatibility of multiple target RITE images;
- named roots or migrations;
- rollback-aware logical resource adapters; or
- a repeated downstream message format the library intentionally standardizes.

Until then, `Bundle.pack` and `runBundle` would be transport framing plus two
calls. Deferring them keeps the module deep and leaves applications free to use
their existing protocol. Adding a future container is source-compatible with
the two typed primitive artifacts.

## Future logical adapters

Do not publish an adapter registry in version 1. Reserve these wire concepts
before freezing golden StateCapsule vectors:

- a capsule-level table listing only adapters actually used;
- a stable adapter ID and schema major/minor;
- a compatibility mode of portable schema or exact adapter fingerprint;
- a length-delimited custom node body with canonical references so aliases and
  cycles remain possible; and
- mandatory destination registration plus policy allowlisting before any
  custom node is constructed.

A registry becomes a real seam after multiple logical value adapters and an
in-memory test adapter establish the varying behavior. Adapter decoding must
not dispatch guest Ruby. Resource-opening adapters also need an explicit
preflight/materialize/rollback contract before they can share the version 1
no-partial-publication guarantee.

## Future reconstructed contexts

A binding-like feature should be a separately named experimental
`ContextCapsule`, never a `StateCapsule` option:

```zig
var encoded = try source.exportContext(allocator, .{
    .binding = binding,
    .site = job_context_site,
});
defer encoded.deinit(allocator);

const values = try destination.decodeContext(encoded.view(), .{});
const context = try destination.activateContext(values, job_context_site);
```

The two phases preserve the interface's execution distinction:

- `decodeContext` reconstructs receiver and visible-local data without guest
  execution; and
- `activateContext` enters normal sandbox execution through a registered
  application-site adapter.

Its metadata should include the semantic mode
`receiver_and_visible_locals_v1`, site ID/version, and application fingerprint,
but no RITE build fingerprint. Its stable promise explicitly excludes original
Proc identity, upper environments, closure-slot aliasing, PC,
Fiber/continuation state, and exact Binding behavior.

The stable interface should never return or promise a real `Binding`. If an
experimental site does produce one, an eval-disabled isolate must reject it or
the capability implementation must also remove `Binding#eval`; removing only
the usual Binding factories is insufficient.

## Migration from v0.2

Version 0.2 exposes raw bytes through the process-global allocator:

```zig
const raw = try sandbox.compile(source);
defer mruby.alloc.gpa.free(raw);
const result = try iso.runImage(raw);
```

Add the typed interface without breaking existing callers:

```zig
var image = try sandbox.compileRite(allocator, source, .{});
defer image.deinit(allocator);
const result = try iso.runRite(image.view());
```

For one compatibility cycle:

- keep `sandbox.compile` and `Isolate.runImage` as deprecated raw-RITE
  operations;
- implement both old and new paths through the same private compiler and
  protected executor;
- document that raw RITE lacks mruby-zig's complete build/application
  fingerprint; and
- move raw operations to an explicitly unsafe namespace only at a major
  release.

Do not make `runImage` accept raw slices and typed images through `anytype`.
That would put inconsistent compatibility guarantees under one method name.

## Implementation sequence

1. Add `artifact.zig`, owned/view types, the RITE wrapper, generated build
   fingerprint, and `compileRite`/`runRite`; preserve raw compatibility
   wrappers.
2. Add the versioned scalar StateCapsule frame, canonical signed integers,
   binary64 floats, strings, symbols, exact limits, corruption tests, and
   endian-independent golden vectors.
3. Add graph arrays/restricted hashes, object IDs, two-pass construction,
   cycles, aliasing, arena rollback, diagnostics, allocation-failure tests,
   cross-process fixtures, and fuzzing.
4. Add optional application schemas and RITE application fingerprints in the
   initial stable envelope and freeze them in the golden-vector contract.
5. Add logical adapters only when real implementations justify the seam.
6. Keep `ContextCapsule` experimental until its reduced semantics and
   capability behavior have production evidence.

## Recommendation

Implement the typed direct paths first. They form a deep module because callers
learn four truthful operations while the implementation hides compatibility,
canonical encoding, graph identity, GC safety, quotas, allocator attribution,
and isolate admission.

The deletion test supports this seam: without it, every downstream worker must
recreate RITE fingerprints, value graph encoding, corruption checks, resource
limits, and import cleanup. A bundle or exact Binding layer does not yet pass
that test. Both can be added later without weakening or replacing the stable
code and data artifacts.
