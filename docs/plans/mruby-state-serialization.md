# mruby state serialization feasibility

Status: research conclusion; typed artifact design approved
Scope: mruby-zig with mruby 4.0.0 (research began at v0.2.0)
Research date: 2026-08-28

## Conclusion

mruby does not currently provide a supported serializer for a complete
mrb_state, an active call stack, or an exact Binding that can be restored in a
different OS process. Upstream's mruby 4.0.0 TODO still lists “suspend/resume VM
state (serialize/deserialize for power cycling)” as future work
([TODO.md](https://github.com/mruby/mruby/blob/4.0.0/TODO.md#L1-L13)).

The existing RITE/irep dump is a compiled-program image. It contains bytecode,
literal-pool entries, symbol names, child ireps, and optional debug/local-name
metadata. It does not contain the live heap, receiver, closure environments,
class mutations, globals, VM stacks, GC state, native data, or host resources.
mruby-zig v0.2 exposed this facility through raw `compile` and `runImage`;
calling those files “snapshots” implies substantially more than they preserve.
The approved typed interface names them `RiteImage` and wraps them with
compatibility metadata through `compileRite` and `runRite`.

Raw memory imaging is not a viable cross-process format. A live mruby state is
a graph containing process addresses, allocator and GC metadata, native
function pointers, host-owned pointers, and configuration-dependent
representations. Exact restoration would require a relocation-aware heap and
VM checkpoint subsystem plus serialization contracts for every native type.
That is a substantial mruby-core/runtime project, not a thin Zig wrapper.

The approved first-class feature is a portable, explicit **StateCapsule**: a
stable, versioned, bounded graph encoding for selected Ruby values. It restores
data into a freshly bootstrapped isolate, never claims to resume execution, and
rejects Binding, Proc, Fiber, native data, behavioral container subclasses,
and raw pointers. Application schemas label the meaning of that data without
adding guest hooks. Logical native adapters and a later “binding-like” capsule
remain separate future facilities with explicitly reduced semantics. Exact
arbitrary Binding restoration remains experimental or out of scope.

## What RITE captures

An mrb_irep is compiled code metadata: register/local counts, instruction
sequence, literal pool, symbol table, nested ireps, local-variable names, debug
information, and lengths/refcount
([include/mruby/irep.h](https://github.com/mruby/mruby/blob/4.0.0/include/mruby/irep.h#L18-L80)).
The RITE container identifies format version 0400 and defines IREP, debug, and
local-variable sections
([include/mruby/dump.h](https://github.com/mruby/mruby/blob/4.0.0/include/mruby/dump.h#L19-L67)).

The writer serializes:

- local/register/child counts, bytecode, and catch handlers
  ([src/dump.c](https://github.com/mruby/mruby/blob/4.0.0/src/dump.c#L46-L95));
- integer, float, and string pool entries
  ([src/dump.c](https://github.com/mruby/mruby/blob/4.0.0/src/dump.c#L139-L276));
- symbols as names and child ireps recursively
  ([src/dump.c](https://github.com/mruby/mruby/blob/4.0.0/src/dump.c#L289-L399)); and
- optional debug and local-variable-name sections
  ([src/dump.c](https://github.com/mruby/mruby/blob/4.0.0/src/dump.c#L637-L762),
  [src/dump.c](https://github.com/mruby/mruby/blob/4.0.0/src/dump.c#L801-L895)).

The loader allocates a new irep in the destination state, copies code and
pools, and interns serialized symbol names into the destination symbol table
([src/load.c](https://github.com/mruby/mruby/blob/4.0.0/src/load.c#L152-L348)).
It checks the magic, size, and RITE major/minor compatibility and locates
supported sections
([src/load.c](https://github.com/mruby/mruby/blob/4.0.0/src/load.c#L648-L729)).
mrb_load_irep then creates a fresh procedure and executes it with the
destination state's top-level receiver; it does not resume a suspended VM
([src/load.c](https://github.com/mruby/mruby/blob/4.0.0/src/load.c#L761-L797)).

This matches mruby's architecture description: the compiler produces an irep
that can execute immediately or be serialized
([architecture.md](https://github.com/mruby/mruby/blob/4.0.0/doc/internal/architecture.md#L91-L105)).
It is a **compiled image**, not a heap or VM snapshot.

RITE is not a durable, runtime-independent archive. mruby 3.1, for example,
deliberately made binaries non-backward-compatible and required recompilation
([mruby3.1.md](https://github.com/mruby/mruby/blob/4.0.0/doc/mruby3.1.md#L82-L99)).
The format version alone cannot establish that gem sets, opcode semantics,
build flags, native methods, or bootstrap state match. Treat RITE as
transportable executable bytecode only within an explicitly compatible build.

mruby-zig's legacy `compile` creates a temporary VM, generates a procedure, and
passes only its irep to `mrb_dump_irep`
([src/sandbox.zig](https://github.com/nullstyle/mruby-zig/blob/v0.2.0/src/sandbox.zig#L973-L998)).
`runImage` loads and executes those bytes in the target isolate
([src/sandbox.zig](https://github.com/nullstyle/mruby-zig/blob/v0.2.0/src/sandbox.zig#L309-L319)).
Current “snapshot” terminology
([README.md](https://github.com/nullstyle/mruby-zig/blob/v0.2.0/README.md#L334-L336))
has therefore become “RITE image” or “compiled image” in the typed interface.
`compileRite` additionally records a stable source name, generated
compatibility fingerprint, and optional application fingerprint; `runRite`
validates them before execution. Reserve “state capsule” for data and
“checkpoint” for an exact execution-state facility.

## Why Binding is different

mruby's Binding is a live lexical context, not a dictionary of copied local
values. A Binding object stores a bytecode program-counter offset, a wrapped
Ruby procedure, the receiver, and an environment
([mruby-binding binding.c](https://github.com/mruby/mruby/blob/4.0.0/mrbgems/mruby-binding/src/binding.c#L439-L490)).
Local lookup walks the procedure's upper chain and reads named slots from
matching environment stacks
([binding.c](https://github.com/mruby/mruby/blob/4.0.0/mrbgems/mruby-binding/src/binding.c#L218-L239)).
Local assignment can mutate an existing environment slot and extend local
metadata
([binding.c](https://github.com/mruby/mruby/blob/4.0.0/mrbgems/mruby-binding/src/binding.c#L335-L353)).

The referenced structures contain live addresses. REnv has a value-stack
pointer and, while shared with an active frame, an mrb_context pointer. RProc
holds either an irep pointer, native C function pointer, or method ID, plus an
upper-procedure pointer and an environment/target-class pointer
([include/mruby/proc.h](https://github.com/mruby/mruby/blob/4.0.0/include/mruby/proc.h#L19-L65)).

Binding eval depends on that structure. It obtains the stored procedure and
environment, compiles new source with the stored procedure as its upper lexical
scope, and installs the captured environment, upper procedure, and target
class
([mruby-eval eval.c](https://github.com/mruby/mruby/blob/4.0.0/mrbgems/mruby-eval/src/eval.c#L21-L45),
[mruby-eval eval.c](https://github.com/mruby/mruby/blob/4.0.0/mrbgems/mruby-eval/src/eval.c#L62-L138)).

An exact Binding archive would therefore need to reconstruct:

1. the receiver's reachable graph;
2. environments and aliasing between captured slots;
3. the Ruby-procedure upper chain and each procedure's code;
4. program-counter and local-name metadata;
5. target classes and enough class/method state for lexical lookup; and
6. native procedure identities, or a rule that rejects them.

A map such as x = 42 can recreate a useful evaluation context, but not closure
identity, lexical scope, live slot mutation, or method lookup. It must not be
presented as an exact restored Binding.

## Why a complete mrb_state cannot be copied

### Active execution and process addresses

An mruby context contains VM stack pointers, callinfo pointers, program
counters, procedures, blocks, environments, target classes, and fiber links
([include/mruby.h](https://github.com/mruby/mruby/blob/4.0.0/include/mruby.h#L165-L207)).
mrb_state contains current/root contexts, globals, top self, class pointers,
exception and symbol state, method cache, GC state, allocation/debug hooks,
void-pointer user data, and exit callbacks
([include/mruby.h](https://github.com/mruby/mruby/blob/4.0.0/include/mruby.h#L263-L342)).

Those addresses cannot be assumed to mean the same thing in another process.
Relocation is not a single base adjustment: pointers occur in tagged values,
unions, buffers, tables, extensions, and host objects. Resuming a frame also
requires coherent PCs, stack/register layouts, exception state, and external
call boundaries.

### Heap and GC invariants

Every heap object header contains a class pointer; classes contain instance
variable tables, method tables, and superclass pointers
([object.h](https://github.com/mruby/mruby/blob/4.0.0/include/mruby/object.h#L10-L45),
[class.h](https://github.com/mruby/mruby/blob/4.0.0/include/mruby/class.h#L17-L22)).
Methods may point to either Ruby procedures or native C functions
([class.h](https://github.com/mruby/mruby/blob/4.0.0/include/mruby/class.h#L103-L121)).

The collector holds linked heap pages, gray lists/stacks, an arena of object
pointers, and incremental collection colors/state
([gc.h](https://github.com/mruby/mruby/blob/4.0.0/include/mruby/gc.h#L35-L70)).
GC traversal shows the actual graph: contexts and call stacks reach procedures,
upper procedures, environments and stacks, while objects reach arrays, hashes,
strings, classes, fibers, and exceptions
([src/gc.c](https://github.com/mruby/mruby/blob/4.0.0/src/gc.c#L633-L817)).
This traversal can inform a semantic graph encoder, but copying heap pages also
copies stale addresses and transient collector state.

A checkpoint system must stop at a safe point, choose roots, assign stable
object IDs, serialize type-specific logical fields, rebuild all references,
restore GC invariants, and only then publish the graph.

### Native and mruby-zig state

RData stores raw data and type-descriptor pointers plus a destructor function
pointer
([data.h](https://github.com/mruby/mruby/blob/4.0.0/include/mruby/data.h#L19-L35)).
The payload may be a file/socket handle, Zig object, library context, mutex, or
arbitrary extension state. Each native type needs a stable codec and restore
operation; some resources cannot be restored.

This coupling is concrete in mruby-zig:

- Value pairs an mrb_value with its owning mrb_state pointer, and borrowed
  strings point into that heap
  ([value.zig](https://github.com/nullstyle/mruby-zig/blob/v0.2.0/src/value.zig#L40-L84));
- Vm instances are registered by process-local mrb_state address
  ([vm.zig](https://github.com/nullstyle/mruby-zig/blob/v0.2.0/src/vm.zig#L17-L50));
- DataType stores a Zig pointer in RData and supplies a native destructor
  ([data.zig](https://github.com/nullstyle/mruby-zig/blob/v0.2.0/src/data.zig#L21-L54)); and
- allocation headers contain owner pointers, whose owner contains allocator and
  ownership-cell pointers
  ([alloc.zig](https://github.com/nullstyle/mruby-zig/blob/v0.2.0/src/alloc.zig#L8-L29),
  [alloc.zig](https://github.com/nullstyle/mruby-zig/blob/v0.2.0/src/alloc.zig#L118-L127)).

### ABI and versioning

mrb_value has multiple boxing representations, several embedding pointers, and
the choice changes the ABI
([boxing.md](https://github.com/mruby/mruby/blob/4.0.0/doc/internal/boxing.md#L5-L16),
[boxing.md](https://github.com/mruby/mruby/blob/4.0.0/doc/internal/boxing.md#L54-L96)).
Upstream warns that configuration macros change internal layouts and that
mismatches can silently corrupt memory
([getting-started.md](https://github.com/mruby/mruby/blob/4.0.0/doc/guides/getting-started.md#L128-L131)).
mruby-zig deliberately binds one fixed build and keeps mrb_state opaque
([src/c.zig](https://github.com/nullstyle/mruby-zig/blob/v0.2.0/src/c.zig#L1-L18)).

Any private checkpoint would therefore be tied to an exact mruby/mruby-zig
version, architecture, endian and pointer width, integer/float and boxing
configuration, compiler flags, gem set, extension versions, and application
bootstrap. A portable format must encode logical values, not C layouts.

## Feasibility matrix

| Approach | Fidelity | Feasibility | Recommendation |
|---|---|---:|---|
| RITE image | Code and literals; no live data | High within compatible build | Keep and rename precisely |
| Explicit application capsule | Selected logical state | High | Primary production design |
| Restricted Ruby value graph | Supported values, cycles, aliases | Medium | Implement as foundation |
| Binding-like capsule | Receiver plus named locals | Medium after graph codec | Optional later feature |
| Exact quiescent Binding | Proc/env/code/class graph | Medium-low, exact build only | Experimental at most |
| Quiescent whole heap | All roots, objects, classes, native adapters | Low, very high cost | Do not pursue in Zig alone |
| Active continuation | Heap, stacks, PCs, contexts, fibers | Very low | Out of scope pending upstream |
| POSIX fork warm worker | Exact inherited address space | High on suitable POSIX hosts | Deployment option, not serialization |

fork can preserve virtual addresses through copy-on-write, but it produces no
portable artifact, cannot restore in an unrelated process or on Windows, and
requires careful handling of threads, locks, sockets, and random state.
Whole-process checkpoint/restore is likewise outside this library's portable
API.

## First-class StateCapsule design

### Contract and format

The API should export one or more deliberate root values at an outer,
quiescent execution boundary and import them into a freshly bootstrapped
isolate. It does not save a guest frame, exception unwind, fiber, gas counter,
or deadline.

RITE and StateCapsule use one canonical, endian-independent 128-byte envelope:
`MRZARTF\0`, format `1.0`, a kind byte, kind-specific flags, header/payload
lengths, 64 metadata bytes, a 32-byte SHA-256 checksum, and zero-reserved
bytes. The checksum is domain-separated with
`mruby-zig/artifact-checksum/v1\0`; it detects corruption, not attackers, so
cross-trust use needs a signature or MAC.

The two kinds deliberately use metadata differently. A RITE image carries the
generated compatibility fingerprint and an optional exact application
fingerprint. A StateCapsule carries only an optional 16-byte application schema
ID plus major/minor versions: its logical scalars and containers do not depend
on the producer's mruby build. Null schema admission accepts only schema-less
capsules; otherwise ID and major must match and the producer minor must not be
newer. No implicit migration or best-effort interpretation occurs.

State payloads contain node/edge counts, one root reference, and an object
table with stable IDs and typed logical fields. Object records appear in
canonical breadth-first first-encounter order. Arrays scan by index; Hashes
scan insertion-ordered key then value pairs followed by an optional default
edge. All multibyte fields are big-endian.

Encode symbols by bytes/name and re-intern them, not by numeric ID. That follows
RITE's existing cross-state approach
([dump.c](https://github.com/mruby/mruby/blob/4.0.0/src/dump.c#L289-L339),
[load.c](https://github.com/mruby/mruby/blob/4.0.0/src/load.c#L316-L339)).

### Supported value graph

Version 1 supports nil, booleans, signed 64-bit integers, raw binary64 float
bits, symbols, and exact-core Strings, Arrays, and Hashes. Hash keys are
restricted to Integer, Float, Symbol, and frozen exact-core String. Nil and
boolean keys are excluded because mruby may dispatch `eql?` during insertion.
Assign an object ID on first visit and encode later references by ID. Decode in
two passes—allocate shells, then fill edges—to preserve cycles, shared
references, distinct equal objects, and aliasing.

Preserve String/Array/Hash frozen state, Hash insertion order, non-proc Hash
defaults, NaN payloads, and signed zero. Reject mutable String keys, semantic
duplicate Hash keys, subclasses, singleton-class variants, extra instance
variables, and Hash default procs rather than flattening observable behavior.

Root unfinished objects against GC during decode. Validate and construct
privately, publish the root only after the complete graph succeeds, and release
temporary roots on error. A successful heap root occupies one ordinary arena
slot; an immediate nil/boolean/integer/float/symbol result needs no arena root.

Reject CPTR, RData, Proc, Binding, Method, Fiber, classes/modules/singleton
classes, environments, backtraces, and live exceptions in version 1. Avoid
guest calls such as to_s, dump hooks, hash/eql, initialize, or method_missing
during traversal and decode. A protected C materializer constructs supported
types directly so mruby allocation failure cannot longjmp across a live Zig
frame. Destination allocations remain subject to the Isolate memory policy;
the control operation itself starts no guest gas generation or lifetime
deadline.

Before construction, model the pinned mruby Hash insertion algorithm exactly
for the restricted key set (AR linear work through 16 entries, then native
hash mixing and triangular HT probes). Apply non-relaxable ceilings of 250,000
total Hash pairs, 4,000,000 total probes, 128 MiB of conservative equal-length
String comparisons, and `max(136, 12*n)` probes per Hash. Apply the identical
preflight to exported bytes. Full-width Integer hashing uses low numeric bits,
and Symbol hashing uses FNV-1 of name bytes, via an audited generated patch to
the pinned mruby source rather than a dependency-tree mutation.

Marshal-style value serializers do not change this boundary: encoding a
supported value graph demonstrates a data-codec approach, not reconstruction of
RProc/REnv execution context, native resources, or a complete VM. Any such
codec also needs its own exact-version compatibility and untrusted-input audit.

There are community Marshal mrbgems, but none is part of mruby core or this
library's pinned gem catalog. The current `mruby-marshal-c` v2.2 release claims
mruby 3.5 compatibility, not mruby 4.0 compatibility
([v2.2 release](https://github.com/LanzaSchneider/mruby-marshal-c/releases/tag/v2.2)).
Its dumper supports common value/object cases but has no Proc case and rejects
unsupported types; it can also dispatch guest `_dump`/`marshal_dump` hooks
([dump.c](https://github.com/LanzaSchneider/mruby-marshal-c/blob/v2.2/src/dump.c#L407-L553)).
The loader correspondingly invokes `_load` and `marshal_load`
([load.c](https://github.com/LanzaSchneider/mruby-marshal-c/blob/v2.2/src/load.c#L416-L497)).
That makes it useful prior art for trusted application values, not a drop-in
Binding/VM checkpoint or an appropriate untrusted sandbox decoder without a
port, limits, and a security audit.

### Future application adapters

Adapters are not part of StateCapsule version 1. If added later, use an explicit
registry keyed by stable codec ID, not a C pointer or Ruby class address. Each
adapter must declare a schema/version, eligibility, bounded logical encoder,
destination constructor, compatibility policy, and whether it is allowed for
untrusted input.

Restoring a file/socket/database wrapper means reopening an approved logical
resource, never copying its handle. Non-restorable values return a typed error
with a path to the offending graph node. Adapter code is privileged host code
and remains disabled unless explicitly registered.

### Approved API and cross-process usage

The foundational interface is about deliberate value roots, not the whole VM.
The follow-up [artifact interface design](artifact-interface.md) specifies two
sibling owned/view types and four operations:

```zig
sandbox.compileRite(allocator, source, options)
Isolate.runRite(image.view())
Isolate.exportValue(allocator, root, options)
Isolate.importValue(capsule_view, options)
```

`RiteImage` and `StateCapsule` each contain only an owned `encoded: []u8`.
Their `deinit(allocator)` methods require the same allocator used to create the
artifact; allocator identity is neither retained nor serialized. Borrowed
views are plain untrusted byte slices and require no allocator. Ruby objects
created by import use the destination Isolate's allocator and memory policy.

RITE deployment remains separate from state transfer:

```zig
var image = try mruby.sandbox.compileRite(allocator, source, .{
    .source_name = "worker.rb",
    .application = application_fingerprint,
});
defer image.deinit(allocator);

const worker = try mruby.sandbox.Isolate.spawn(.{
    .artifacts = .{ .application = application_fingerprint },
});
defer worker.deinit();

_ = try worker.runRite(image.view());
```

Producer process:

```zig
const root = try source.run(
    \\{"count" => 41, "metadata" => {"worker" => "alpha"}}
);

var capsule = try source.exportValue(allocator, root, .{
    .schema = .{ .id = job_schema_id, .major = 1, .minor = 0 },
});
defer capsule.deinit(allocator);

// Send encoded bytes over a pipe, socket, queue, or durable store.
try channel.writeAll(capsule.view().bytes);
```

Consumer process:

```zig
const worker = try mruby.sandbox.Isolate.spawn(policy);
defer worker.deinit();

const restored = try worker.importValue(
    .{ .bytes = received_bytes },
    .{ .accepted_schema = .{
        .id = job_schema_id,
        .major = 1,
        .minor = 2,
    } },
);
const count = try worker.call(restored, "fetch", .{"count"});
try std.testing.expectEqual(@as(i64, 41), try count.asInt());
```

`exportValue` must reject a root owned by another VM. Both operations should be
methods on Isolate, not Value: the isolate owns its thread/phase guard,
allocator attribution, memory policy, and destination bootstrap. Import is a
bounded host control operation rather than guest bytecode, so CPU work is
bounded by capsule limits while all mruby allocations are still charged to the
destination isolate. A shared non-blocking operation lock rejects concurrent
same-Isolate access deterministically. Same-thread nested guest execution from
a callback remains supported, but callbacks cannot start value artifact
operations.

## Binding options

A reasonable binding-like capsule can contain receiver, visible local names and
graph values, and optional source/application metadata. Restore should create a
new evaluation context or pass locals as arguments, not manufacture a Binding
while claiming equivalence. Documentation must state that closure identity,
upper-procedure chains, live slot mutation, PC position, and some lexical
lookup are lost.

Conceptually, that later layer could look like this:

```zig
const binding = try source.run(
    \\count = 41
    \\metadata = {"worker" => "alpha"}
    \\binding
);

var capsule = try source.exportContext(
    binding,
    allocator,
    .{ .binding_site = "JobContext:v1" },
);
defer capsule.deinit(allocator);

// In another process, whose application bootstrap registers JobContext:v1:
var context = try worker.importContext(capsule.bytes, .{});
defer context.deinit();
const answer = try worker.evalContext(&context, "count += 1; count");
```

The binding-site ID lets the destination re-enter known application code to
create a fresh context at a compatible lexical site before injecting decoded
locals. That preserves more behavior than flattening everything into a
top-level binding, but `context` is still deliberately not advertised as the
original Binding or a resumed continuation.

An exact experiment would need a version-pinned C shim to walk and rebuild
private RProc/REnv structures, dump every Ruby irep in the upper chain, encode
environment graph nodes, and reconnect receiver and target classes. It must
reject native procs, active/shared-stack environments, unstable class
identities, unsupported data, and fingerprint mismatches. Even then it is an
exact-build checkpoint, not portable state, and mruby upgrades may invalidate
it.

## Security requirements

Treat RITE as executable input and capsules as hostile data unless proven
otherwise:

- validate tags, canonical encodings, lengths/counts, object IDs, references,
  and integer arithmetic before allocation;
- cap bytes, nodes, depth, container entries, and aggregate string/symbol
  bytes, charging destination memory during construction;
- never accept serialized addresses or native callback addresses;
- avoid guest dispatch and accept only exact built-in container classes;
- publish no partial root on failure and restore the entry GC arena (symbol
  interning or GC may still have occurred);
- fuzz truncation, cycles, extreme counts, duplicate/dangling references, and
  allocation failures;
- authenticate executable images and capsule data across trust boundaries; and
- establish sandbox policy before import, never allowing an artifact to weaken
  gas, memory, deadline, call-depth, or host-capability limits.

There is a specific capability interaction to resolve before exposing any
Binding-returning API. Today `Capabilities.eval = false` removes Kernel#eval,
Kernel#binding, instance_eval/instance_exec, and class/module eval, but it does
not remove Binding#eval
([sandbox.zig](https://github.com/nullstyle/mruby-zig/blob/v0.2.0/src/sandbox.zig#L631-L649),
[eval.c](https://github.com/mruby/mruby/blob/4.0.0/mrbgems/mruby-eval/src/eval.c#L391-L430)).
Guests normally cannot obtain a Binding after those factories are removed, but
a host restoration API could inject one and reopen string evaluation. Such an
API must either reject eval-disabled isolates or also undefine Binding#eval.

The RITE loader's compatibility checks are not a security proof. High-risk
untrusted artifacts should additionally be decoded and run in a disposable OS
worker.

## Implementation phases

1. **Foundation and lifecycle:** add the pure artifact frame/grammar, generated
   RITE identity, bounded readers/writers, and shared non-blocking Isolate
   operation admission.
2. **Typed RITE:** implement caller-owned `compileRite`/`runRite`, stable source
   names, optional debug data, compatibility/application checks, and legacy raw
   wrappers.
3. **State export:** traverse supported graphs iteratively, assign canonical
   IDs, enforce policy/per-call minima, inspect exact containers through inert
   C shims, and publish actionable paths on failure.
4. **State import:** fully validate into bounded scratch, construct all shells
   and edges in one protected C materializer, preserve frozen/default state,
   and prove arena rollback and memory-limit mapping.
5. **Hardening:** commit golden vectors, corruption/quota/allocation sweeps,
   zero-guest-dispatch tests, concurrency/TSan coverage, parser fuzzing, and a
   cross-process producer/consumer fixture.

Logical adapters and binding-like contexts are later, separate designs. An
exact Binding experiment, if ever demanded, remains behind an unstable
exact-build gate with strict rejection rules.

Do not begin whole-heap or active-continuation work in mruby-zig unless upstream
first supplies stable checkpoint hooks or completes its stated suspend/resume
work. That project needs upstream ownership of object layout, GC, context, and
extension protocols to remain maintainable.

## Recommendation

Implement the typed RITE and StateCapsule seam as the first-class facility. It
provides the useful cross-process capability—moving compiled code and
deliberate Ruby data—without pretending process-local VM internals are
portable. Keep RITE as a separate executable-code primitive. Reconstruct a
worker by:

1. creating a fresh sandbox with the required policy;
2. installing the exact application/gem/native bootstrap;
3. loading an authenticated, fingerprint-compatible RITE image if precompiled
   code is needed;
4. importing the bounded state capsule; and
5. entering guest execution under normal resource accounting.

Offer a binding-like layer only when the caller accepts reduced semantics. Do
not make exact Binding or complete mrb_state serialization part of mruby-zig's
stable contract today. The upstream TODO, internal structures, and current RITE
loader all establish the same boundary: compiled code is serializable now;
live execution state is not.
