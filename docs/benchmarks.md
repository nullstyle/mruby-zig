# Benchmarks and size baselines

`zig build run-bench` runs the runtime benchmark suite; `zig build run-bench
-Doptimize=ReleaseSafe` produces the reference numbers. Each metric warms
up and then repeats a fixed workload, reporting wall-clock per-op cost and
throughput. Numbers are machine- and build-dependent — treat them as
relative baselines for detecting regressions on the same machine, not as
portable absolute figures.

Timing uses the sandbox's own `monotonicNs` clock. The suite covers the
assessment's target list: VM lifecycle, evaluation throughput, method-call
and host-callback overhead, gas-hook cost, artifact throughput, and the
one-shot worker roundtrip.

## Metrics

| Metric | Workload |
| --- | --- |
| `vm-cycle` | `Vm.init` + `deinit` (raw embedding lifecycle) |
| `isolate-cycle` | `BootstrapIsolate.spawn` + `seal` + `deinit` (sandboxed lifecycle incl. capability setup) |
| `eval-cold` | parse + codegen + run of a fixed 500-iteration compute script |
| `rite-cached` | full `runRite` (envelope validation + load + run) of the pre-compiled script |
| `call-loop` | `Isolate.call` into a Ruby method |
| `host-callback` | Ruby loop calling a derived-signature Zig method (1,000 calls/op) |
| `gas-hook off/on` | the compute script under unlimited gas vs a per-isolate meter; the printed ratio is the instruction-hook's cost |
| `capsule-export` / `capsule-import` | StateCapsule roundtrip of a 200-entry frozen-String-keyed Hash of Integers (14,447 encoded bytes) |
| `worker-rite` | `worker.runRite` one-shot process roundtrip (spawn + IPC + restricted execution + reap); skipped when the platform or deployment lacks the helper |

## Reference observations

Recorded on aarch64-macos, Zig `0.17.0-dev.1978+c961124d9`,
`-Doptimize=ReleaseSafe`, standard gem set. Re-measure on the same machine
when comparing.

| Metric | Per op | Throughput |
| --- | ---: | ---: |
| vm-cycle | 128.6 µs | 7,777 ops/s |
| isolate-cycle | 104.0 µs | 9,617 ops/s |
| eval-cold | 53.2 µs | 18,811 ops/s |
| rite-cached | 48.4 µs | 20,684 ops/s |
| call-loop | 0.09 µs | 10.8 M ops/s |
| host-callback | 0.10 µs/call | 10.1 M calls/s |
| gas-hook overhead | — | 1.03x |
| capsule-export (200-entry) | 72.5 µs | 13,801 ops/s |
| capsule-import (200-entry) | 41.6 µs | 24,027 ops/s |
| worker-rite | 1,721 µs | 581 ops/s |

Observations worth keeping in mind:

- **The instruction hook is cheap.** Metered execution costs ~3% over
  unmetered — the assessment's concern that the fetch hook runs even for
  effectively-unlimited configurations is measurable but small.
- **Cached RITE ≈ cold eval.** `runRite` (validation + load + execute) is
  only ~9% cheaper than parsing and compiling source each time; the win of
  RITE is determinism and compatibility control, not throughput. A
  load-once/run-many path would need a different API shape.
- **Export costs ~1.7x import.** The export path encodes and then
  reparses/normalizes its own output for safety symmetry; import runs the
  parser once. That symmetry is the most promising optimization target if
  capsule throughput ever matters (confirmed by the assessment).
- **The worker roundtrip is process-spawn bound.** ~1.7 ms is dominated by
  fork/exec + IPC of the 14 KB request, not Ruby execution; batching or a
  persistent worker pool would change its economics.

## Binary size

Procedure (run per configuration of interest):

```sh
mise x -- zig build -Doptimize=ReleaseSafe
stat -f%z zig-out/bin/quickstart   # macOS; use stat -c%s on Linux
```

Reference points, aarch64-macos, `ReleaseSafe`:

| Configuration | quickstart | mruby-worker |
| --- | ---: | ---: |
| standard gems | 1,793,736 B | 1,959,648 B |
| minimal gems | 1,290,344 B | 1,489,440 B |

The ~500 KB standard-vs-minimal delta is the stdlib extension gems plus
their mrblib bytecode. The following runtime-only measurements use the same
native aarch64-macos target, pinned Zig version, `ReleaseSafe`, default
allocator, and unstripped executables. They were recorded on 2026-09-04.
`codedb-demo` provides an identical artifact-only workload in both profiles;
`quickstart` requires runtime source compilation and is not a runtime-only
executable.

### Runtime-only preset comparison

Both builds request the same preset. `-Dno-compiler` removes parser/codegen and
compiler-dependent eval; in minimal it also avoids adding eval's binding
dependency. The instruction hook remains enabled.

| Preset | Executable | Compiler enabled | Runtime-only | Reduction |
| --- | --- | ---: | ---: | ---: |
| standard | codedb-demo | 1,902,040 B | 1,558,776 B | 343,264 B (18.05%) |
| standard | mruby-worker | 1,959,376 B | 1,616,128 B | 343,248 B (17.52%) |
| minimal | codedb-demo | 1,431,976 B | 1,068,056 B | 363,920 B (25.41%) |
| minimal | mruby-worker | 1,489,280 B | 1,125,360 B | 363,920 B (24.44%) |

Reproduce the four builds and measure the actual installed executables:

```sh
for gem_preset in standard minimal; do
  mise x -- zig build -Dgem-set="$gem_preset" -Doptimize=ReleaseSafe \
    -Dno-compiler=false --prefix "/tmp/mruby-phase5-$gem_preset-full" -j4
  mise x -- zig build -Dgem-set="$gem_preset" -Doptimize=ReleaseSafe \
    -Dno-compiler=true --prefix "/tmp/mruby-phase5-$gem_preset-runtime" -j4
  wc -c /tmp/mruby-phase5-$gem_preset-{full,runtime}/bin/{codedb-demo,mruby-worker}
done
```

The `wc` command uses bash/zsh brace expansion. Both runtime-only executables
pass `sh tools/check_runtime_only_symbols.sh executable...`: their symbol tables
retain the VM and sandbox interface but contain no parser, codegen,
compiler-context, source-loading, or compiler-backed eval definitions or
references. The compiler-enabled default worker fails that audit as expected.

### Identical resolved gem selections

To separate explicit compiler removal from gem removal, the compiler-enabled
standard baseline excludes `mruby-eval`; the compiler-enabled minimal baseline
excludes both `mruby-eval` and `mruby-binding`. Generated manifest gem arrays
then match the corresponding runtime-only builds exactly: 28 gems for standard,
zero for minimal.

| Matching selection | Executable | Compiler enabled | Runtime-only | Reduction |
| --- | --- | ---: | ---: | ---: |
| standard without eval | codedb-demo | 1,559,608 B | 1,558,776 B | 832 B |
| standard without eval | mruby-worker | 1,616,944 B | 1,616,128 B | 816 B |
| minimal without eval/binding | codedb-demo | 1,068,872 B | 1,068,056 B | 816 B |
| minimal without eval/binding | mruby-worker | 1,126,176 B | 1,125,360 B | 816 B |

```sh
mise x -- zig build -Dgem-set=standard -Doptimize=ReleaseSafe \
  -Dwithout-gems=mruby-eval -Dno-compiler=false \
  --prefix /tmp/mruby-phase5-standard-matched-full -j4
mise x -- zig build -Dgem-set=minimal -Doptimize=ReleaseSafe \
  -Dwithout-gems=mruby-eval,mruby-binding -Dno-compiler=false \
  --prefix /tmp/mruby-phase5-minimal-matched-full -j4
wc -c /tmp/mruby-phase5-*-matched-full/bin/{codedb-demo,mruby-worker}
```

Once eval is excluded, the linker already removes unused compiler functions
from these artifact-only executables, even in a compiler-enabled build. Most
of the preset savings therefore come from removing eval and its compiler
dependency. Explicit compiler removal adds little binary-size benefit for this
workload, but prevents source APIs from linking the compiler back in and makes
compiler absence a declared feature and compatibility constraint. These are
binary-size measurements, not runtime-throughput claims.

## CI

The Linux test job runs `mruby-bench` informationally on every push: the
output is recorded in logs for eyeballing trends, but shared runners are
too noisy for hard regression gates. Promote a metric to a gate only with
dedicated hardware and an agreed threshold.
