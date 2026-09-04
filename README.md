# mruby-zig

Embed [mruby](https://mruby.org) 4.0 in Zig applications — first-class,
production-grade, and built entirely with `zig`. One `zig build` fetches the
mruby 4.0.0 source (hash-pinned), generates its presym tables and core
bytecode, compiles everything with `zig cc`, and hands you a `mruby` module.
**No Ruby, no rake, no submodules, no system dependencies.**

```
 ┌──────────┐   presym scan (zig cc -E)     ┌─────────────────────┐
 │ mruby    │ ────────────────────────────► │ id.h / table.h      │
 │ 4.0.0    │                               └─────────────────────┘
 │ (zon dep)│   host mrbc (zig cc)          ┌─────────────────────┐
 │          │ ────────────────────────────► │ mrblib.c, gem_init  │
 └──────────┘                               └─────────┬───────────┘
                                                      ▼
                                      mruby module (C + Zig + shim)
```

## Status

Pre-release, pinned to **Zig 0.17.0-dev.1978+c961124d9** via
[mise](https://mise.jdx.dev) (`.mise.toml`; `mise install`,
`mise x -- zig build test`). Developed and tested on aarch64-macos; linux
targets should work out of the box.

## Quickstart

```sh
mise install                 # install the repository's pinned Zig snapshot
mise x -- zig build test     # unit + Ruby integration suites
mise x -- zig build run-quickstart
```

## Running CI locally

With a running [Docker Engine](https://docs.docker.com/get-docker/), run the
Linux GitHub Actions jobs from the repository root:

```sh
mise run ci
```

The mise task installs a task-local, pinned version of
[`act`](https://nektosact.com/installation/index.html), and the checked-in
`.actrc` selects an `ubuntu-latest` runner image. It follows Docker's native
architecture; on Apple Silicon, forcing `linux/amd64` can make Zig fail under
emulation. `act` skips the macOS matrix entry because Docker cannot emulate a
GitHub-hosted macOS runner, so GitHub Actions remains authoritative for that
leg. To iterate on one job or matrix entry:

```sh
mise run ci -- --job gem-sets --matrix gem_set:minimal --pull=false
```

In your application:

```zig
const mruby = @import("mruby");

const vm = try mruby.Vm.init();
defer vm.deinit();

const result = try vm.loadString("[1, 2, 3].map { |x| x * x }.sum");
std.debug.print("{d}\n", .{try result.asInt()});
```

Depending on this package (once published):

```
zig fetch --save=mruby https://github.com/nullstyle/mruby-zig/archive/refs/tags/v0.3.0.tar.gz
```

```zig
// build.zig
const dep = b.dependency("mruby", .{});
exe.root_module.addImport("mruby", dep.module("mruby"));
```

The entire C library is compiled into the module — consumers link nothing
else and need no Ruby toolchain at build time.

## API tour

The supported Zig layer is explicit about failure and interpreter ownership:

- Any operation that can allocate or raise returns an error union. A Ruby
  exception is always `error.RubyException`; inspect `vm.lastError()` before
  starting the next VM operation, which supersedes the pending diagnostic.
- `Value` and `Class` handles belong to the `Vm` that created them. APIs that
  combine handles reject cross-VM use with `error.ForeignValue` instead of
  passing a foreign heap pointer into mruby.
- The exported `mruby.c` module is an intentionally unsafe escape hatch.
  Supported safe-layer calls keep mruby's `setjmp`/`longjmp` entirely inside
  the C shim, so Ruby exceptions never unwind across live Zig frames.

### Evaluating Ruby

```zig
const v = try vm.loadString("'hello'.upcase");
try std.testing.expectEqualStrings("HELLO", try v.asString());

const named = try vm.loadStringWithOptions("__FILE__", .{
    .source_name = "jobs/worker.rb",
});
```

Ruby exceptions (compile-time or runtime) surface as `error.RubyException`
and never longjmp through Zig frames — the C shim runs each operation under
`mrb_protect_error`:

```zig
if (vm.loadString("raise 'boom'")) |_| {
    unreachable;
} else |err| {
    std.debug.assert(err == error.RubyException);
    var details = try vm.lastError().?.details(allocator, .{
        .max_backtrace_frames = 32,
    });
    defer details.deinit();
    // details.class_name == "RuntimeError"
    // details.message == "boom"
}
```

`RubyError.details` owns its class name, message, and bounded backtrace.
`RubyError.className` and `message` are also available when only one field is
needed; each takes the allocator that will own its returned bytes. Sandbox
errors use metadata captured before guest execution ends, so reading their
details never dispatches guest methods.

### Calling Zig from Ruby

`defineMethod` bridges a Zig function into a Ruby method with typed
arguments. The format string follows mruby's `mrb_get_args`:

| spec | Zig type      | spec | Zig type       |
|------|---------------|------|----------------|
| `i`  | `i64`         | `o`  | `Value`        |
| `f`  | `f64`         | `z`  | `[:0]const u8` |
| `b`  | `bool`        | `S`/`s` | `[]const u8` |
| `n`  | `u32` (sym)   | `&`  | `Value` (block) |
| `*`  | `Rest`        | `\|` | optional separator |

```zig
const math = try vm.defineClass("ZigMath", null);
try math.defineMethod("add", "ii", struct {
    fn call(vm: *mruby.Vm, self: mruby.Value, a: i64, b: i64) anyerror!mruby.Value {
        _ = self;
        return vm.intValue(a + b);
    }
}.call);

_ = try vm.loadString("ZigMath.new.add(20, 22)");  // => 42
```

A Zig `error` returned from a callback becomes a Ruby `RuntimeError`
(`"zig error: Kaboom"`); `vm.raise("ArgumentError", "msg")` raises a specific
class from within a callback.

Classes and modules can define and inspect direct child namespaces and
constants without constructing qualified names:

```zig
const api = try vm.defineModule("API");
const widget = try api.defineClass("Widget", null);
try widget.defineConst("VERSION", try vm.stringValue("1"));
const version = try (try api.getClass("Widget")).getConst("VERSION");
```

### Wrapping Zig state in Ruby objects

```zig
const Conn = mruby.data.DataType(ConnState, "Conn", ConnState.destroy);
const cls = try vm.defineClass("Conn", null);
const obj = try Conn.wrap(cls, state_ptr); // Ruby value
const p   = Conn.unwrap(some_value).?;     // *ConnState
```

If `destroy` is non-null it runs when the GC collects the wrapper. `wrap`
transfers ownership of the pointer only when it succeeds.

### Calling Ruby from Zig

```zig
const s = try vm.stringValue("hello");
const up = try vm.call(s, "upcase", .{});
const sqrt = try vm.call(try vm.loadString("Math"), "sqrt", .{@as(f64, 144.0)});

const items = try vm.loadString("[1, 2, 3]");
const double = try vm.loadString("->(x) { x * 2 }");
_ = try vm.callWithOptions(items, "each", .{}, .{ .block = double });
```

The positional argument tuple has no fixed eight-argument cap.
`callWithOptions` additionally accepts an optional Ruby block and enforces the
same VM ownership rule for that block.

### Typed collections and conversions

```zig
const one = try vm.intValue(1);
const array = try vm.array(&.{one});
try array.append(try vm.intValue(2));

const key = try vm.stringValue("answer");
const hash = try vm.hash(&.{
    .{ .key = key, .value = try vm.intValue(42) },
});
const answer: ?mruby.Value = try hash.get(key);
```

`Array` supports checked indexing, extension by assignment, and append.
`Hash.get` bypasses Hash defaults: it returns `null` for a missing key and a
non-null nil `Value` for a present Ruby `nil`. Hashes also support assignment
and typed `keys`. Both handles convert through `mruby.convert` and retain their
underlying `Value`'s arena lifetime and VM ownership.

Integer conversion is exact: values outside mruby's signed 64-bit range return
`error.Overflow`; use `Vm.saturatingIntValue` only when clamping is intended.
Finite Float conversions that exceed the destination format also return
`error.Overflow`.
Converting Ruby to Zig `bool` accepts only the actual Ruby `true` and `false`
values rather than applying Ruby truthiness.

### Output redirection

```zig
try mruby.output.setOutputWriter(vm, &some_writer.interface);
_ = try vm.loadString("puts 'hello from ruby'");     // -> some_writer
```

`print`, `puts`, and `p` are installed on `Kernel` and write (flushed) to
any `std.Io.Writer`.

### Memory

All mruby allocations flow through `mruby.alloc`, a Zig-side
`mrb_basic_alloc_func` override: `mruby.alloc.setAllocator(gpa)` (before
the first `Vm`), `mruby.alloc.liveBytes()` / `liveAllocs()` for
observability. It is process-global — an upstream 4.0 constraint — and
defaults to the thread-safe `std.heap.c_allocator`.

`-Dallocator=libc|arena` selects the initial process allocator. The arena
profile is thread-safe with the pinned Zig toolchain, but retains backing
allocations for the process lifetime; it is intended for bounded workloads and
allocator-compatibility testing. `setAllocator` can replace either build
default before the first mruby allocation. The selected build default is
available as `mruby.alloc.configured_default`.

Two lifetime rules keep you safe:

- Values returned by `loadString`/`call` stay GC-rooted in the arena, so
  they are safe to hold across further Ruby execution. Each returned value
  occupies one arena slot, so bracket a tight loop of calls with
  `vm.arenaScope()` to keep the arena from growing. To keep selected values
  after restoring a scope, promote them to explicit long-lived roots:

  ```zig
  const scope = vm.arenaScope();
  const temporary = try vm.loadString("Object.new");
  var held = try vm.root(temporary);
  scope.restore();
  defer held.deinit(); // every RootedValue must be released before its Vm

  _ = try vm.call(held.get(), "inspect", .{});
  ```

  Multiple roots for the same Ruby object have independent lifetimes.
- String slices are **borrowed**: `Value.asString`, the `S`/`s`/`z` method
  parameters, and `Rest.get` point into the Ruby heap and are valid only
  until the next interpreter call — use `Value.dupeString(allocator)` to
  keep them. `vm.loadString` rejects source containing an interior NUL byte
  rather than silently evaluating only the prefix visible to the lexer.

## Gem configuration

The default **standard** gem set (28 gems) covers metaprogramming
(`mruby-metaprog`, `mruby-method`, `mruby-eval`, `mruby-binding`), the
stdlib extension gems (`string/array/hash/enum/range/numeric/class/object/
symbol/proc/kernel/toplevel/compar`), `struct`, `set`, `fiber`,
`enumerator` + `lazy`, `sprintf`, `pack`, `random`, `time`, `data`,
`objectspace`, and `math`.

```sh
mise x -- zig build -Dgem-set=minimal          # core + compiler + eval (+ deps)
mise x -- zig build -Dgem-set=minimal -Dwith-gems=mruby-string-ext
mise x -- zig build -Dwithout-gems=mruby-pack  # remove gems
```

`-Dwith-gems` accepts gems from the catalog in `build/gems.zig`. Gem
dependencies are honored like Rake's `add_dependency`: additions pull in
their dependencies, and `-Dwithout-gems` cascade-removes dependents.
Unknown names are rejected during configuration, and the final set is
topologically ordered before generating its initialization table.
The deprecated `-Dstdlib-gems=false` spelling remains an alias for
`-Dgem-set=minimal` (`true` maps to `standard`); conflicting spellings are
rejected.

Excluded from defaults for portability: `io`, `socket`, `dir`, `errno`,
`print`, and the math-extras (`bigint`, `complex`, `rational`, `cmath`).
Note that without `mruby-bigint`, integer *literals* beyond the int32 pool
range raise `RangeError` at load time (upstream 4.0 behavior); computed
values up to ±2^63 work fine.

## Feature manifest

`mruby.features` is generated per build from the resolved gem selection
and target, so applications branch at compile time instead of duplicating
build knowledge or probing at runtime:

```zig
const mruby = @import("mruby");

comptime {
    if (!mruby.features.sandbox_supported)
        @compileError("this application requires the sandbox tier");
}

// Works in comptime branches and ordinary runtime code alike.
if (mruby.features.hasGem("mruby-time")) {
    _ = try vm.loadString("t = Time.now.to_i");
} else {
    _ = try vm.loadString("t = 0");
}
```

| Member | Meaning |
| --- | --- |
| `gems`, `hasGem(name)` | The dependency-ordered gem selection; core mruby and the compiler are always present and not listed as gems |
| `gem_set`, `custom_selection` | Requested preset (`"standard"`/`"minimal"`) and whether `-Dwith-gems`/`-Dwithout-gems` customized it |
| `mruby_version` | Version of the vendored mruby |
| `rite_compatibility_fingerprint` (`_hex`, `epoch`, `rite_binary_version`, `rite_vm_version`) | The artifact compatibility identity this build admits |
| `pointer_bits`, `endian` | Target constraints (the package requires 64-bit targets) |
| `has_compiler`, `has_debug_hook` | Always true today: codegen and the sandbox's instruction hook are linked into every build; a future runtime-only profile would flip them |
| `sandbox_supported` | Debug hook compiled in and the target satisfies the ABI constraint |

## Sandboxing

`mruby.sandbox.Isolate` wraps a private `Vm` (its own heap, symbols, and
globals — nothing is shared between isolates) with an enforced policy.

Capability grants are **deny-by-default**: a `Policy` built without a preset
strips `eval`, `send`, introspection, and `ObjectSpace`, so plain compute
scripts run while ambient language authority must be granted explicitly —
including anything a future release might add. The presets compose with your
limits and artifact acceptance:

```zig
// Semi-trusted scripts: deny-by-default capabilities plus a frozen object
// model and resource ceilings. Host classes/methods go on iso.vm first,
// then seal, then run.
const iso = try mruby.sandbox.Isolate.spawn(mruby.sandbox.Policy.restricted(.{
    .limits = .{
        .gas = .{ .per_isolate = 10_000_000 }, // cumulative gas budget
        .wall_time_ns = 250 * std.time.ns_per_ms,
        .memory_bytes = 8 * 1024 * 1024,      // soft cap -> hard cap
        .call_depth = 64,
    },
    .capabilities = .{
        .random_seed = 42,             // reproducible rand sequences
        .clock_epoch_s = 1_700_000_000, // frozen Time.now
    },
}));
defer iso.deinit();

// Trusted embedding (scripts the host authored or fully controls) grants
// the ambient language capabilities instead:
//   mruby.sandbox.Policy.trusted(.{ .limits = ... })

const result = iso.run(script) catch |err| switch (err) {
    error.ScriptTerminated,   // iso.terminate() from any thread
    error.DeadlineExceeded,
    error.GasExhausted,
    error.MemoryLimitExceeded,
    error.CallDepthExceeded => ...,
    error.RubyException => ..., // ordinary script error: iso.lastError()
};
```

### Typed RITE and state artifacts

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

const worker = try mruby.sandbox.Isolate.spawn(.{
    .artifacts = .{ .application = app },
});
defer worker.deinit();

const result = try worker.runRite(image.view());
```

`source_name` controls `__FILE__` even when debug information is omitted.
`RiteImage` owns only `encoded`; pass the same allocator used by
`compileRite` to `deinit`. Across a process boundary, send
`image.view().bytes` and construct `.{ .bytes = received_bytes }` at the
destination. Every `runRite` revalidates the envelope, checksum, generated
compatibility fingerprint, application fingerprint, and byte ceiling.

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

RITE is executable input; StateCapsule is bounded inert data. Their SHA-256
checksums detect corruption, not substitution, so authenticate either artifact
when it crosses a trust boundary (especially RITE). Neither type is a VM,
Binding, Fiber, or continuation snapshot.

### Gas scopes

`Limits.gas` controls how instruction gas is granted:

| Policy | Behavior |
| --- | --- |
| `.unlimited` | No gas meter; `stats().gas` is `null`. |
| `.{ .per_isolate = N }` | One cumulative allowance for the Isolate. Lazy capability setup and all executions share it, and exhaustion is sticky. |
| `.{ .per_execution = N }` | Each admitted outermost `run`, `runImage`, `runRite`, or `call` gets a fresh allowance. Rejected preflight calls do not advance the generation; nested callback re-entry shares the active allowance. |

Use `.per_execution` for a stateful worker that should accept another request
after gas exhaustion:

```zig
const std = @import("std");
const mruby = @import("mruby");

const iso = try mruby.sandbox.Isolate.spawn(.{
    .limits = .{
        .gas = .{ .per_execution = 20_000 },
    },
});
defer iso.deinit();

if (iso.run(
    \\$value = 40
    \\$cleaned = false
    \\begin
    \\  $value += 1
    \\  while true; end
    \\ensure
    \\  $cleaned = true
    \\end
)) |_| {
    return error.ExpectedGasExhausted;
} else |err| switch (err) {
    error.GasExhausted => {},
    else => return err,
}

const exhausted = iso.stats().gas.?;
std.debug.assert(exhausted.exhausted);
std.debug.assert(exhausted.used == exhausted.limit);

// A new outer execution gets fresh gas on the same Ruby heap.
const preserved = try iso.run("$value == 41 && $cleaned");
std.debug.assert(preserved.isTruthy());

const renewed = iso.stats().gas.?;
std.debug.assert(renewed.generation == exhausted.generation +| 1);
std.debug.assert(!renewed.exhausted);
```

This preserves state; it is not a transaction or continuation. Mutations and
completed `ensure` effects survive, but the interrupted stack is unwound and
never resumed.

`Stats.instructions` is the saturating lifetime count of observed bytecode
fetches. `Stats.gas` describes the live or most recently completed finite
generation. `used + remaining == limit`, and `used <= limit`.
`exhausted` means a later fetch actually observed an empty allowance;
`observed_instructions` also includes bounded detection and unwind work, so it
can exceed `limit`. Before the first `.per_execution` request, gas statistics
report prospective generation 0; actual requests start at generation 1.

`Limits.instructions` is deprecated but remains source-compatible. It maps
exactly to `.gas = .{ .per_isolate = N }`, preserving cumulative sticky
behavior. Setting both fields returns `error.ConflictingGasPolicy`. The whole
policy — gas scope and limit, memory caps, wall budget, call-depth ceiling,
capability snapshot, and artifact acceptance — is resolved once at `spawn`;
the Isolate retains no mutable policy, so later edits to a host-held `Policy`
value have no effect. Dynamic per-request amounts are not currently
supported.

- **Termination** (`iso.terminate()`) is thread-safe and is observed at the
  next bytecode fetch. Delivery may wait for a catchable VM position, after
  which `ensure` blocks run during unwind; a `rescue` can catch the termination
  only briefly (a bounded instruction grace), never suppress it. The distinct
  error always surfaces to the host, and completion after observation is
  bounded by the uncovered-wait and grace budgets.
- **Memory**: the soft cap fails the next allocation (mruby raises the
  rescuable `NoMemoryError`, then the hook escalates); the hard cap
  (default soft + max(1 MiB, soft/2)) fails allocations permanently and
  terminates immediately. `iso.stats()` reports
  instructions/peak-memory/peak-depth/live-objects/wall-time; the isolate
  cell exposes an `on_limit` callback for quota accounting.
- **Recovery**: only gas exhaustion under `.per_execution` is renewable.
  `.per_isolate` exhaustion, deadline, memory, call depth, and external
  termination remain sticky. `Isolate.lastError()` is reserved for ordinary
  `RubyException` and is cleared at the next outer entry. Its `message()` and
  `className()` use rooted inert metadata, execute no guest code, and consume
  no gas; returned slices are caller-owned and must be freed with
  `mruby.alloc.gpa.free`.
- **Compiled images**: prefer typed `compileRite`/`runRite`, which add framing,
  corruption checks, generated build compatibility, and optional application
  identity. Legacy `sandbox.compile`/`runImage` remain temporarily available
  for raw RITE but are deprecated because they provide none of those outer
  compatibility checks.
- **CPU/loops**: the instruction hook fires only on bytecode. Long pure-C
  operations and host Zig callbacks are not instruction-interruptible; memory
  caps constrain only allocations attributed to the Isolate, not CPU time.
  Keep callbacks bounded. They may poll `iso.pendingTermination()` for an
  external or already-recorded cause; a lifetime deadline is also arbitrated
  when the native call returns.
- **Boundaries**: the final charged opcode may finish with `remaining == 0`
  and `exhausted == false`; exhaustion is observed on the next fetch. A zero
  limit admits no charged opcode, but bounded uncharged delivery work may run
  so `ensure` can unwind. Gas does not charge parsing/code generation or work
  inside one C-native opcode.
- **Lifecycle**: lazy capability setup joins `.per_isolate` gas, but completes
  before generation 1 for `.per_execution`. `Isolate.seal()` ends the
  bootstrap window explicitly: it applies the policy's capabilities through
  the same preflight bracket as an execution (so setup gas and deadlines are
  accounted identically) and is idempotent; the first `run`/`call` seals
  lazily otherwise. Route untrusted work through `Isolate.run`, `runImage`,
  `runRite`, or `call`; executing directly through `iso.vm` bypasses the
  generation lifecycle and is for trusted bootstrap before `seal()` only.
  One non-blocking operation lock covers guest execution and value artifact
  operations; simultaneous same-Isolate access returns `IsolateThreadBusy`.
  Nested guest execution from a callback retains its existing behavior, but a
  callback cannot start export/import. Invalid typed RITE is rejected before
  `lastError`, timing, gas, capabilities, or termination state changes.
  `terminate()` and `pendingTermination()` remain the cross-thread-safe
  lock-free controls; serialize stats, diagnostics, direct VM access, and
  destruction. `wall_time_ns` starts when the first outer entry begins
  preflight (`seal()` counts if it comes first), continues across idle time,
  and is never renewed by a new gas generation.

**Not covered by the in-process tier** (by design, same as v8 isolates):
no address-space separation from the host. The planned out-of-process
tier (worker processes with IPC: run/call/terminate/stats plus structured
value transfer, OS-level memory separation and optional seccomp/pledge)
fronts this same API; typed RITE images give those workers cheap warm-starts,
and StateCapsules provide deliberate structured value transfer.

## Layout

```
build.zig            # the entire mruby build, in zig
build/{sources,gems,gen}.zig
tools/presym_gen.zig       # presym tables + canonical table digest
tools/artifact_config_gen.zig # build-dependent RITE identity module
tools/file_join.zig        # generated-C assembler helper
src/c.zig            # hand-written extern bindings (public for power users)
src/shim.c           # C-side accessors for macro-only inline APIs
src/vm.zig           # Vm: eval, call, classes, globals, raise, arena
src/{value,class,data,convert,error,output,arena,alloc}.zig
src/tests_ruby/*.rb  # Ruby-level integration suite (embedded, asserted in zig)
examples/            # quickstart, host_functions, exceptions
tools/repl.zig       # `zig build run-repl -- -e 'expr'` eval tool
```

## How it works

mruby's build normally requires Ruby (rake) to generate four things. This
package generates all of them in `build.zig`, mirroring the rake tasks:

1. **presym tables** — preprocess every C source with
   `-DMRB_PRESYM_SCANNING` (which turns `MRB_SYM(x)` into `<@! "x" !@>`
   markers), collect and sort symbols by (length, bytes), emit
   `mruby/presym/{id.h,table.h}`, and hash the final canonical symbol-to-ID
   table. That generated digest feeds the typed RITE compatibility fingerprint;
   input path names are never used as a substitute for the emitted table.
2. **host `mrbc`** — mruby's own bootstrap trick: the `mrbc` tool ships
   empty `mrb_init_mrblib`/`mrb_init_mrbgems` stubs, so it links without
   any generated files. We build it for the host with `zig cc` (with its
   own presym tables, like rake's nested build).
3. **bytecode** — run that `mrbc` over `mrblib/*.rb` and each gem's
   `mrblib/*.rb` (`-B<sym> -S -s`, cdump format), assembling `mrblib.c`
   and per-gem `gem_init.c` from the exact rake templates.
4. **gem registry** — a generated `gem_init.c` table driving
   `mrb_init_mrbgems`.

Ruby-level symbols reach the presym tables because the final scan covers
the *generated* files (the cdump output references symbols through
`MRB_SYM(...)` macros, exactly like the rake build).

The Zig side never hand-decodes mruby struct layouts: `src/shim.c` compiles
inside libmruby and re-exposes the macro-only inline API (GC arena,
`mrb->exc`, integer/string accessors, value constructors) as plain
functions, keeping every layout decision on the C side.

## Development

```sh
mise x -- zig build check             # compile tests, tools, and examples
mise x -- zig build test              # unit + Ruby integration suites
mise x -- zig build test-state-capsule-process
mise x -- zig build fuzz-state-capsule --fuzz=100K
mise x -- zig build run-host-functions
mise x -- zig build run-repl -- -e 'RUBY_VERSION'
```

## License

MIT — see [LICENSE](LICENSE). mruby is MIT and fetched at build time as a
pinned, hash-verified dependency.
