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
zig fetch --save=mruby https://github.com/nullstyle/mruby-zig/archive/refs/tags/v0.3.0.tar.gz
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
| `worker_process_supported` | The target can run the bundled one-shot worker tier (currently 64-bit Linux and macOS) |

`mruby.alloc.backingAllocationFailures()` exposes a saturating, monotonic
process-wide diagnostic count of backing-allocator rejections. The worker
samples it to preserve finite address-space failures as typed limit outcomes,
even if Ruby rescues the immediate `NoMemoryError`.

## Development commands

```sh
mise x -- zig build check             # compile tests, tools, and examples
mise x -- zig build test              # unit + Ruby integration suites
mise x -- zig build test-state-capsule-process
mise x -- zig build fuzz-state-capsule --fuzz=100K
mise x -- zig build run-host-functions
mise x -- zig build run-repl -- -e 'RUBY_VERSION'
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

See [safe-api.md](safe-api.md) for the embedding API,
[sandboxing.md](sandboxing.md) for policy and threat model, and
[artifacts.md](artifacts.md) for compiled images and state transfer. The
[worker guide](workers.md) covers fresh-process execution and deployment.
