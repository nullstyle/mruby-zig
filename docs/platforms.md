# Platform support matrix

| Target | Build | Tests | Worker tier | Notes |
| --- | --- | --- | --- | --- |
| aarch64-macos | supported | unit + integration + ReleaseSafe (CI) | target-supported and authority-gated; no finite address-space cap | primary development platform |
| x86_64-macos | supported | unit + integration + ReleaseSafe (CI) | target-supported and authority-gated; no finite address-space cap | |
| x86_64-linux (ubuntu) | supported | unit + integration + ReleaseSafe + TSan + gem profiles (CI) | target-supported and authority-gated, including finite `RLIMIT_AS` | |
| aarch64-linux-gnu | cross-compiles (CI) | compile-only (`-Doptimize=ReleaseSafe`) | target-supported and authority-gated; compile-only in CI | runtime not exercised in CI |
| x86_64-linux-musl | cross-compiles (CI) | compile-only | target-supported and authority-gated; compile-only in CI | static-friendly libc |
| x86_64-windows-gnu | best effort | compile-only, `continue-on-error` in CI | unavailable | no runtime CI; not supported until it has one |

## Constraints

- **64-bit targets only.** The hand-written `mrb_value`/`mrb_int` ABI in
  `src/c.zig` targets the package's supported 64-bit word-boxing
  configuration and rejects other pointer widths at compile time.
  `mruby.features.pointer_bits` and `mruby.features.endian` expose the
  resolved target traits; `mruby.features.sandbox_supported` summarizes
  whether the in-process sandbox tier is usable.
- **Worker execution is Linux/macOS only and authority-gated.**
  `worker_target_supported` reports the target check;
  `worker_profile_eligible` reports whether linked authority avoids
  filesystem, network, process, environment, and arbitrary native-host
  access; `worker_ambient_authority_opt_in` records when the explicit build
  override is actively admitting an ineligible profile.
  `worker_process_supported` is exactly target support and either profile
  eligibility or that opt-in. Both systems get parent wall
  supervision, `RLIMIT_CPU`, disabled core dumps, and guaranteed direct-child
  reaping. Finite address-space ceilings use Linux `RLIMIT_AS`; macOS returns
  `error.HardMemoryLimitUnavailable` for that option.
- **Authority features describe linked APIs, not platform enforcement.**
  `mruby.features.authority` is the conservative union for core, compiler,
  and selected gems. It is independent of the target support flags and does
  not claim that an in-process policy or operating system has removed the
  reported authority.
- **Zig is pinned** to `0.17.0-dev.1978+c961124d9` via mise (`.mise.toml`).
  A tagged mruby-zig release can stop building under a moving Zig snapshot,
  so upgrades are deliberate: bump the pin together with any required
  build/API compatibility fixes, in their own change.
- **libc is linked**; the default process allocator is the thread-safe
  `std.heap.c_allocator` (see [getting-started.md](getting-started.md)).

## CI coverage

- `zig fmt --check`
- `zig build test` in Debug **and** `-Doptimize=ReleaseSafe` on macOS and
  Linux
- example binaries execute on every CI run (quickstart, host_functions,
  exceptions, sandbox, and the REPL)
- normal Linux/macOS integration runs execute the real `mruby-worker`
  exchange, including typed transfer, failure classification, and hard
  timeout/reap coverage
- cross-compiles for the targets above
- ThreadSanitizer build and test on Linux
- gem profiles: `-Dgem-set=minimal`, `-Dwithout-gems=…` subsets

Windows runtime behavior is explicitly **not** claimed: compilation is
best-effort only. Promoting a target means adding its runtime tests to CI
and updating this matrix in the same change.
