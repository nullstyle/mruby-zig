# Platform support matrix

| Target | Build | Tests | Worker tier | Notes |
| --- | --- | --- | --- | --- |
| aarch64-macos | supported | unit + integration + ReleaseSafe (CI) | target-supported and authority-gated; no finite address-space cap | primary development platform |
| x86_64-macos | supported | not exercised by the current hosted CI | target-supported and authority-gated; no finite address-space cap | current macOS runners are arm64 |
| x86_64-linux (ubuntu) | supported | unit + integration + ReleaseSafe + TSan + gem profiles (CI) | target-supported and authority-gated, including finite `RLIMIT_AS` | |
| aarch64-linux-gnu | cross-compiles (CI) | compile-only in hosted CI; local Docker runtime rehearsal | target-supported and authority-gated | local rehearsal covers both gem presets and compiler profiles in Debug/ReleaseSafe |
| x86_64-linux-musl | cross-compiles (CI) | compile-only | target-supported and authority-gated; compile-only in CI | static-friendly libc |
| x86_64-windows-gnu | best effort | GNU cross-build plus a non-blocking native Windows runtime job | unavailable | runtime job is diagnostic; it is not a support guarantee |

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
- CodeDB graph, authority, compatibility-rejection, and declaration-order
  checks through a downstream consumer
- compiler-free standard/minimal profiles in Debug/ReleaseSafe, including
  artifact execution and runtime/worker symbol audits on Linux/macOS
- hash-pinned archive consumers for both presets, run after deleting build
  inputs and relocating the application and worker on Linux/macOS
- example binaries execute on every CI run (quickstart, host_functions,
  exceptions, sandbox, and the REPL)
- normal Linux/macOS integration runs execute the real `mruby-worker`
  exchange, including typed transfer, failure classification, and hard
  timeout/reap coverage
- cross-compiles for the targets above
- ThreadSanitizer build and test on Linux
- C undefined-behavior detection in a ReleaseFast build
  (`-Dsanitize-c=true`) on Linux
- a best-effort, non-blocking Windows runtime job (unit + integration
  suites, ReleaseSafe, and the example binaries); promoting Windows to
  supported means making that job blocking and updating this matrix in
  the same change
- weekly sustained StateCapsule parser and live materialization fuzzing
  (scheduled and manually dispatchable)
- gem profiles: `-Dgem-set=minimal`, `-Dwithout-gems=…` subsets

The hosted baseline for `786c41a` used Ubuntu 24.04 x86_64 and macOS 26 arm64.
Its native Windows job failed while compiling the host `mrbc` (mruby's
`jmp_buf`/`void **` exception-handler mismatch), before running tests; the
Windows GNU cross-build passed. Windows runtime behavior is therefore still
unverified. Promoting it requires fixing that build, making the runtime job
blocking, and updating this matrix with passing evidence.
