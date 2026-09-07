# Getting started and build options

mruby-zig embeds [mruby](https://mruby.org) 4.0 in Zig applications. One
`zig build` fetches the mruby 4.0.0 source (hash-pinned), generates its
presym tables and core bytecode, compiles everything with `zig cc`, and
hands you a `mruby` module. **No Ruby, no rake, no submodules, no system
dependencies.**

## Requirements

Pre-release, pinned to **Zig 0.17.0-dev.1978+c961124d9** via
[mise](https://mise.jdx.dev) (`.mise.toml`). `mise install` installs the
pinned snapshot; `mise x -- zig build test` runs through it. Supported
platforms are listed in [platforms.md](platforms.md).

## Quickstart

```sh
mise install                 # install the repository's pinned Zig snapshot
mise x -- zig build test     # unit + Ruby integration suites
mise x -- zig build run-quickstart
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
zig fetch --save=mruby https://github.com/nullstyle/mruby-zig/archive/refs/tags/v0.4.0.tar.gz
```

```zig
// build.zig
const target = b.standardTargetOptions(.{});
const optimize = b.standardOptimizeOption(.{});
const dep = b.dependency("mruby", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("mruby", dep.module("mruby"));

// Only needed for mruby.worker.runRite: install the helper built with the
// same target, gem set, and compatibility fingerprint as the module.
const worker = dep.artifact("mruby-worker");
b.installArtifact(worker);
```

The entire C library is compiled into the module — in-process consumers link
nothing else and need no Ruby toolchain at build time. Process-isolated users
must deploy that separate helper and pass its explicit path to
`mruby.worker.runRite`; see [workers.md](workers.md).

## Gem configuration

The default **standard** gem set covers metaprogramming
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

Every catalog entry declares the conservative authority its Ruby-visible
surface can expose. The generic worker is omitted when the selected profile
includes filesystem, network, process, environment, or arbitrary native-host
authority. Both shipped presets are eligible today. A deployment that has
separately reviewed an ineligible local catalog can acknowledge the risk with:

```sh
mise x -- zig build -Dallow-worker-ambient-authority=true
```

When mruby-zig is a dependency, root build options are not forwarded
automatically. Declare the acknowledgement in the consuming build and pass it
through explicitly:

```zig
const allow_worker_ambient_authority = b.option(
    bool,
    "allow-worker-ambient-authority",
    "acknowledge authority exposed by the selected mruby worker profile",
) orelse false;
const dep = b.dependency("mruby", .{
    .target = target,
    .optimize = optimize,
    .@"allow-worker-ambient-authority" = allow_worker_ambient_authority,
});
```

This option only overrides the build gate; it does not remove, restrict, or
OS-sandbox that authority. See [workers.md](workers.md).

## Runtime-only profile

`-Dno-compiler` removes the target parser/code generator and compiler-dependent
`mruby-eval`. The host `mrbc` remains available for core/gem bytecode and
[CodeDB application artifacts](artifacts.md). The standard preset retains its
other gems; minimal becomes core-only because eval's binding dependency is no
longer needed. Explicitly adding a compiler-dependent gem with `-Dwith-gems`
fails during configuration.

```sh
mise x -- zig build -Dno-compiler -Doptimize=ReleaseSafe
mise x -- zig build test check -Dno-compiler
mise x -- zig build run-codedb-demo -Dno-compiler -Dgem-set=minimal
```

For a downstream application, forward the option to the same dependency used
by the application, its CodeDB helper, and its worker:

```zig
const dep = b.dependency("mruby", .{
    .target = target,
    .optimize = optimize,
    .@"no-compiler" = true,
});
```

`Vm.loadString`, `Vm.loadStringWithOptions`, `Isolate.run`, `sandbox.compile`,
and `sandbox.compileRite` return `error.CompilerUnavailable` in this profile.
Use CodeDB or typed `runRite`, with a manifest generated for this exact target
profile. The compiler choice participates in compatibility identity, so images
compiled for a compiler-enabled target cannot be substituted.

`features.has_compiler` is false; `features.has_debug_hook` remains true. Gas,
deadlines, termination, and native deterministic RNG setup remain available.
The runtime-only profile installs the CodeDB demo and, on supported eligible
platforms, `mruby-worker`. The source-driven REPL, ordinary examples, benchmark,
and capsule-process source fixture are omitted; invoking their run steps reports
that a compiler is required. `test` and `check` use the artifact execution
suite plus compiler-independent tests. `test-runtime-only` runs that same
artifact suite under either compiler profile.

## Strict effects profile

`-Deffects-strict=true` selects a core-only minimal runtime without a target
compiler and enables native implementation admission. It rejects incompatible
gem/compiler/worker options. Use `mruby.strict.Program` to install Effects before
bounded application initialization; use CodeDB for all application Ruby.

```sh
mise x -- zig build test check -Deffects-strict=true
mise x -- zig build run-effects-inventory -Deffects-strict=true -Dsqlite-effects=true
mise x -- zig build run-effects-durable -Deffects-strict=true -Dsqlite-effects=true
mise x -- zig build run-effects-reservation -Deffects-strict=true
```

For a contained worker with native adapters retained in the host, run
`mise x -- zig build run-effects-worker -Deffects-strict=true` and see
[effects-workers.md](effects-workers.md).
The [durable host guide](effects-durable.md) covers atomic persistence, stable
request IDs, process-crash recovery, and deferred local delivery.
Use `mise x -- zig build run-effects-inspect-demo` to inspect a constructed
receipt without executing Ruby. [Diagnostics and inspection](effects-diagnostics.md)
covers worker failures, source locations, and safe JSON reports.
The [typed contracts guide](effects-contracts.md) shows shared operation schemas
and a reservation flow with staged stock and notification intents.

See [effects-strict.md](effects-strict.md) for downstream build configuration,
the native trust contract, and links to terminal-state verification and worker
containment. The ordinary runtime-only profile above retains its
existing behavior.

## Allocator profile

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

## Feature manifest

`mruby.features` is generated per build from the resolved gem selection
and target, so applications branch at compile time instead of duplicating
build knowledge or probing at runtime:

```zig
const mruby = @import("mruby");

comptime {
    if (!mruby.features.sandbox_supported)
        @compileError("this application requires the sandbox tier");
    if (mruby.features.authority.has(.filesystem))
        @compileError("this application does not admit filesystem authority");
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
| `gems`, `hasGem(name)` | The dependency-ordered gem selection; core mruby and the optional target compiler are not listed as gems |
| `gem_set`, `custom_selection` | Requested preset (`"standard"`/`"minimal"`) and whether `-Dwith-gems`/`-Dwithout-gems` customized it |
| `AuthorityKind`, `AuthoritySet`, `AuthoritySource`, `AuthorityManifest` | Types for inspecting the build's conservative authority vocabulary and source attribution |
| `authority` | Aggregate linked authority plus entries for `mruby-core`, the compiler when linked, and every selected gem |
| `authorityForGem(name)` | Authority for a selected gem, or `null` when that gem is not linked; use `authority.find` for core/compiler |
| `mruby_version` | Version of the vendored mruby |
| `rite_compatibility_fingerprint` (`_hex`, `epoch`, `rite_binary_version`, `rite_vm_version`) | The artifact compatibility identity this build admits |
| `pointer_bits`, `endian` | Target constraints (the package requires 64-bit targets) |
| `has_compiler`, `has_debug_hook` | The compiler is absent with `-Dno-compiler`; the instruction hook stays enabled in every profile |
| `sandbox_supported` | Debug hook compiled in and the target satisfies the ABI constraint |
| `worker_target_supported` | The target alone can host the worker (currently 64-bit Linux and macOS) |
| `worker_profile_eligible` | The linked authority avoids filesystem, network, process, environment, and arbitrary native-host access |
| `worker_ambient_authority_opt_in` | True when `-Dallow-worker-ambient-authority` is actively admitting an otherwise-ineligible profile; it records an acknowledgement, not confinement |
| `worker_process_supported` | The worker artifact/controller are enabled: target support and either profile eligibility or the explicit opt-in |

`AuthorityKind` contains `filesystem`, `network`, `process`, `environment`,
`clock`, `entropy`, `dynamic_code`, `dynamic_dispatch`, `introspection`,
`heap_enumeration`, `model_mutation`, `continuations`, `native_host`, and
`host_output`. These values describe what linked package code can make
available, not what a particular sandbox policy leaves reachable after
sealing; see [sandboxing.md](sandboxing.md).

`mruby.alloc.backingAllocationFailures()` exposes a saturating, monotonic
process-wide diagnostic count of backing-allocator rejections. The worker
samples it to preserve finite address-space failures as typed limit outcomes,
even if Ruby rescues the immediate `NoMemoryError`.

## Development commands

```sh
mise x -- zig build check             # compile tests, tools, and examples
mise x -- zig build test              # unit + Ruby integration suites
mise x -- zig build test-state-capsule-process
mise x -- zig build test-codedb        # build-time Ruby and artifact admission
mise x -- zig build test-runtime-only -Dno-compiler
mise x -- zig build test-worker-orphan # controller death and bounded worker exit
mise x -- bash tools/test_codedb_package.sh # fetched package + relocated worker
mise x -- zig build run-codedb-demo    # compiled invoice job under policy
mise x -- zig build fuzz-state-capsule --fuzz=100K
mise x -- zig build fuzz-state-materialize --fuzz=100K
mise x -- zig build fuzz-state-materialize -Dno-compiler --fuzz=100K
mise x -- zig build run-host-functions
mise x -- zig build run-repl -- -e 'RUBY_VERSION'
```

The fuzz limits count iterations. Without `--fuzz`, the targets run their
regression tests and seed corpus once. Materialization fuzzing validates input
and constructs live objects inside a bounded isolate; assertions check that
no guest instructions execute. Coverage guidance comes from Zig code: the
pinned fuzzer cannot consume mruby's Clang C coverage counters.

CI runs 25,000 materialization iterations in compiler-enabled and compiler-free
profiles on Linux/macOS. The scheduled job runs 2 million parser iterations and
500,000 materialization iterations per compiler profile. Failed campaigns retain
the generated corpus, coverage state, and fuzzer log as CI artifacts for 14 days.
Locally, preserve `.zig-cache/f`, `.zig-cache/v`, and
`.zig-cache/tmp/libfuzzer.log` before clearing caches; reduce useful failing
inputs into checked-in regression fixtures.

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

See [safe-api.md](safe-api.md) for the embedding API,
[sandboxing.md](sandboxing.md) for policy and threat model, and
[artifacts.md](artifacts.md) for compiled images and state transfer. The
[worker guide](workers.md) covers fresh-process execution and deployment.
