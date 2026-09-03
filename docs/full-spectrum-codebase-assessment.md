# Full-Spectrum Codebase Assessment

> Baseline: commit `32e942f` (`v0.3.0`). This records the assessment before
> follow-up hardening work; findings, verification results, and source locations
> describe that revision.

## Verdict

This is a **strong, technically credible pre-release**, but it is **not yet production-ready as a general-purpose embedding and sandboxing library**.

The core architecture should be retained. The best parts—the Zig-native mruby build, C ABI isolation, artifact framing, compatibility validation, allocator accounting, and termination machinery—are substantially stronger than a typical v0.3 project. The gaps are concentrated at the boundaries: VM ownership, exception containment, value lifetimes, policy semantics, build-option correctness, and supported-platform guarantees.

The opening “production-grade” claim conflicts with the project’s own pre-release status and platform caveats in the [README](worktree://b731251f-07d9-4b0d-8b4c-89bca14f4df5/README.md#L3-L24).

Production readiness depends on the use case:

| Use case | Assessment |
|---|---|
| Trusted Ruby embedded in a controlled 64-bit macOS/Linux application | Close enough to justify hardening rather than redesign; likely 2–3 focused releases |
| Cooperative or semi-trusted scripts with resource limits | Promising, but policy and native-boundary gaps remain |
| Hostile, untrusted Ruby | Not suitable in-process; needs the planned worker-process boundary |
| Broad portable library with reproducible builds | Not ready; Zig pinning, Windows runtime behavior, gem-option correctness, and support policy need work |

## What is already strong

### 1. The underlying build approach is excellent

The host-tool/target-library split in [the build pipeline](worktree://b731251f-07d9-4b0d-8b4c-89bca14f4df5/build.zig#L79-L177) correctly handles the difficult part of cross-compiling mruby: building host `mrbc` and presym tools, generating target data, and then compiling the target library. Avoiding Ruby/Rake as host build dependencies is a meaningful usability and reproducibility improvement.

Keeping ABI-sensitive structures and behavior in the narrow [C shim](worktree://b731251f-07d9-4b0d-8b4c-89bca14f4df5/src/shim.c#L1-L12) is also the right design. Zig should orchestrate and type the boundary without attempting to reproduce every C bitfield, anonymous union, or macro convention.

### 2. The artifact subsystem is the most production-mature area

The framing, checksums, limits, compatibility identity, and typed distinction between RITE images and state capsules in [artifact.zig](worktree://b731251f-07d9-4b0d-8b4c-89bca14f4df5/src/artifact.zig#L149-L305) are coherent and defensive.

The state-graph parser goes beyond superficial byte validation: it computes exact hash work and admission requirements in [artifact_value.zig](worktree://b731251f-07d9-4b0d-8b4c-89bca14f4df5/src/artifact_value.zig#L859-L1046), and C materialization is deliberately consolidated under one protection frame in [c.zig](worktree://b731251f-07d9-4b0d-8b4c-89bca14f4df5/src/c.zig#L375-L382). This is a good deep module: substantial complexity is hidden behind a comparatively small, meaningful contract.

### 3. The sandbox implementation addresses real failure modes

Gas, deadlines, memory accounting, explicit termination state, allocator failure, callback errors, artifact admission, and model sealing are much more comprehensive than a superficial “sandbox” wrapper. The code shows awareness that Ruby exceptions, host errors, OOM, and termination are distinct failure classes.

The project is also appropriately honest that in-process hooks cannot interrupt arbitrary native work and that stronger isolation requires another process in the [sandbox limitations and roadmap](worktree://b731251f-07d9-4b0d-8b4c-89bca14f4df5/README.md#L419-L450).

### 4. Functional test coverage is broad

The current suite covers normal embedding, sandbox behavior, allocator failures, artifact corruption, parser fuzz corpora, and multiple gem configurations. CI exercises macOS, Linux, cross-compilation, TSan, and gem profiles in [ci.yml](worktree://b731251f-07d9-4b0d-8b4c-89bca14f4df5/.github/workflows/ci.yml#L9-L98).

That gives the project a strong foundation for hardening; the concern is not a lack of tests generally, but missing tests around several critical invariants.

---

## Production blockers

### 1. The safe API does not enforce VM ownership

[`Value`](worktree://b731251f-07d9-4b0d-8b4c-89bca14f4df5/src/value.zig#L40-L42) records the owning `mrb_state`, but [`Vm.call`](worktree://b731251f-07d9-4b0d-8b4c-89bca14f4df5/src/vm.zig#L189-L218) does not verify that the receiver or `Value` arguments belong to that VM. [`convert.toValue`](worktree://b731251f-07d9-4b0d-8b4c-89bca14f4df5/src/convert.zig#L16-L19) simply passes an existing `Value` through.

The same invariant is missing from global/instance-variable assignment in [vm.zig](worktree://b731251f-07d9-4b0d-8b4c-89bca14f4df5/src/vm.zig#L370-L390), callback return handling in [class.zig](worktree://b731251f-07d9-4b0d-8b4c-89bca14f4df5/src/class.zig#L286-L299), and native-data unwrapping in [data.zig](worktree://b731251f-07d9-4b0d-8b4c-89bca14f4df5/src/data.zig#L49-L53).

Passing an mruby heap object into another state is not merely a friendly API error; it can become invalid memory access or use-after-free. Artifact export already performs an ownership check in [sandbox.zig](worktree://b731251f-07d9-4b0d-8b4c-89bca14f4df5/src/sandbox.zig#L458-L464), so the intended invariant exists but is not centralized.

**Recommendation:** introduce one `Vm.requireOwned(Value) error{ForeignValue}!void` rule and apply it at every safe-layer ingress and callback egress. Do not rely on each API author remembering independently.

### 2. “Protected” operations do not contain the whole potentially raising operation

[`Vm.call`](worktree://b731251f-07d9-4b0d-8b4c-89bca14f4df5/src/vm.zig#L189-L218) protects the eventual method dispatch, but method interning and argument conversion occur first. String conversion invokes `mrb_str_new` in [convert.zig](worktree://b731251f-07d9-4b0d-8b4c-89bca14f4df5/src/convert.zig#L29-L33), which can allocate. [`internSymbol`](worktree://b731251f-07d9-4b0d-8b4c-89bca14f4df5/src/vm.zig#L395-L398) exposes an error union but calls the raw C operation directly. Class definition operations in [class.zig](worktree://b731251f-07d9-4b0d-8b4c-89bca14f4df5/src/class.zig#L59-L76) and parts of [`compileRaw`](worktree://b731251f-07d9-4b0d-8b4c-89bca14f4df5/src/sandbox.zig#L1327-L1369) similarly contain allocation-capable mruby work outside a uniform protection rule.

That makes the README guarantee that Ruby exceptions do not longjmp through Zig in [README.md](worktree://b731251f-07d9-4b0d-8b4c-89bca14f4df5/README.md#L91-L93) broader than the implementation supports.

**Recommendation:** do not scatter additional partial protection calls through Zig. Add narrow C trampolines that encompass the complete operation—interning, conversion, allocation, and dispatch—and return tagged status to Zig. The invariant should be: *no allocation-capable mruby API is called from the safe layer except inside a C protection frame.*

### 3. Gem selection is not a reliable build contract

The README documents `-Dwith-gems=mruby-io` in [the gem configuration section](worktree://b731251f-07d9-4b0d-8b4c-89bca14f4df5/README.md#L191-L203), but the catalog in [build/gems.zig](worktree://b731251f-07d9-4b0d-8b4c-89bca14f4df5/build/gems.zig#L36-L79) does not include it. The documented command panics with “unknown gem.”

More importantly, dependency resolution in [build.zig](worktree://b731251f-07d9-4b0d-8b4c-89bca14f4df5/build.zig#L634-L649) adds missing dependencies but does not topologically reorder already selected gems. `minimal + mruby-binding` therefore builds in an invalid initialization order; the targeted test run produced 99 test failures.

Unknown `-Dwithout-gems` entries are silently ignored in [build.zig](worktree://b731251f-07d9-4b0d-8b4c-89bca14f4df5/build.zig#L555-L560), which compounds configuration mistakes.

**Recommendation:** make the gem catalog the single source of truth, topologically sort the complete selected graph, reject unknown inclusions and exclusions, detect cycles, and test every preset plus dependency-closure properties. If arbitrary external gems are not supported, call the option “catalog gems” rather than implying they are.

### 4. The sandbox is not yet a defensible security boundary

The zero-value [`Policy`](worktree://b731251f-07d9-4b0d-8b4c-89bca14f4df5/src/sandbox.zig#L126-L175) has no resource limits and enables capabilities. That is convenient for compatibility but dangerous for a type named `Policy`: adding a future capability with a default of `true` silently grants new authority.

Capability removal and model freezing are manually enumerated in [sandbox.zig](worktree://b731251f-07d9-4b0d-8b4c-89bca14f4df5/src/sandbox.zig#L961-L1073). This is difficult to prove complete as mruby or the selected gems evolve. Public access to the underlying VM is documented as trusted-only in [README.md](worktree://b731251f-07d9-4b0d-8b4c-89bca14f4df5/README.md#L430-L440), but exposing it as an ordinary field makes bypassing the policy lifecycle easy.

Policy values are also partly resolved and cached at spawn while other capability fields remain mutable in [Isolate](worktree://b731251f-07d9-4b0d-8b4c-89bca14f4df5/src/sandbox.zig#L247-L254), so post-spawn mutation has non-obvious partial effects.

**Recommendation:**

- Require an explicit `Policy.trusted()` or `Policy.restricted()` preset.
- Resolve it once into an immutable internal `ResolvedPolicy`.
- Separate bootstrap from execution, ideally as `BootstrapIsolate.seal() -> Isolate`.
- Replace ordinary `vm` access with an explicitly unsafe bootstrap-only operation.
- Generate/audit a capability manifest from the selected gem profile.
- Treat hostile execution as unsupported until the worker-process tier exists.

### 5. Value lifetime and rooting need a first-class model

The README explains that returned values consume arena roots and that scopes restore them in [README.md](worktree://b731251f-07d9-4b0d-8b4c-89bca14f4df5/README.md#L170-L180), but [`Scope`](worktree://b731251f-07d9-4b0d-8b4c-89bca14f4df5/src/arena.zig#L1-L23) is only a manual save/restore wrapper. A `Value` can escape its scope, outlive its VM, or be reused after restoration without detection.

That forces users to choose between steadily growing arena roots and values whose runtime validity is implicit.

**Recommendation:** define a clear distinction between transient values and explicit long-lived roots. A `RootedValue` or `Root` with RAII release, plus debug owner/generation checks, would make the lifetime contract discoverable and testable.

### 6. There is a real Windows clock defect

[`monotonicNs`](worktree://b731251f-07d9-4b0d-8b4c-89bca14f4df5/src/sandbox.zig#L216-L229) calculates `counter * 1_000_000_000` in `i64` before division. With a common 10 MHz performance counter, this overflows after roughly fifteen minutes. Safe builds can trap; fast builds can wrap and break deadline behavior.

**Recommendation:** widen operands to `i128` before multiplication or use the standard-library monotonic timer implementation. Windows should remain unsupported until this has a runtime CI test, rather than only best-effort compilation.

### 7. Output redirection has failure and recursion hazards

[`setOutputWriter`](worktree://b731251f-07d9-4b0d-8b4c-89bca14f4df5/src/output.zig#L29-L38) marks output as installed before all subsequent setup succeeds, poisoning retries after a partial failure.

[`putsElem`](worktree://b731251f-07d9-4b0d-8b4c-89bca14f4df5/src/output.zig#L67-L81) recursively walks arrays without cycle detection and uses overridable Ruby methods such as `size` and `[]`. A self-referential array can recurse through native Zig code outside the intended Ruby gas/stack controls.

Installation should be transactional, and array rendering should use guarded/raw array traversal with Ruby-compatible recursion handling.

---

## Consistency and API improvements

Several APIs make different choices for the same concept:

- [`Vm.intValue`](worktree://b731251f-07d9-4b0d-8b4c-89bca14f4df5/src/vm.zig#L479-L484) saturates, while generic integer conversion returns `error.Overflow` in [convert.zig](worktree://b731251f-07d9-4b0d-8b4c-89bca14f4df5/src/convert.zig#L13-L23). Checked conversion should be the default; saturation should be explicitly named.
- [`getIvar`](worktree://b731251f-07d9-4b0d-8b4c-89bca14f4df5/src/vm.zig#L379-L383) turns allocation failure into Ruby `nil`, conflating “unset” with “failed.”
- `fromValue(bool)` applies Ruby truthiness in [convert.zig](worktree://b731251f-07d9-4b0d-8b4c-89bca14f4df5/src/convert.zig#L43-L60). Strict bool conversion and an explicitly named `isTruthy` operation should be separate.
- [`RubyError.message` and `className`](worktree://b731251f-07d9-4b0d-8b4c-89bca14f4df5/src/error.zig#L34-L52) allocate through a global allocator and return an empty string on failure. They should accept an allocator and return `![]u8`.
- [`lastInitFailure`](worktree://b731251f-07d9-4b0d-8b4c-89bca14f4df5/src/vm.zig#L53-L80) is process-global and explicitly thread-unsafe. Initialization should return a diagnostic value owned by the failed operation.
- Source strings containing NUL are silently truncated in [vm.zig](worktree://b731251f-07d9-4b0d-8b4c-89bca14f4df5/src/vm.zig#L108-L123). Rejecting interior NUL is safer and avoids validation/execution mismatches.
- Method names, globals, ivars, and class paths have inconsistent sentinel, sigil, and empty-segment conventions.

These should not be fixed individually with exceptions. Establish coherent rules:

1. Checked conversions by default.
2. No silent fallback on allocation failure.
3. All owned results accept an allocator.
4. All safe API inputs validate VM ownership.
5. Invalid names and source data are rejected, not normalized or truncated.
6. Public error sets are named rather than inferred `!`/`anyerror`.

The high-level API is also still too thin for a “first-class” embedding layer. Common arrays/hashes, nested class/module definition, scoped constants, persistent roots, block and keyword argument support, source filename metadata, and structured backtraces currently push users toward the public raw C layer exposed in [mruby.zig](worktree://b731251f-07d9-4b0d-8b4c-89bca14f4df5/src/mruby.zig#L35-L37).

---

## Better uses of Zig

### Comptime-derived callback signatures

[`Class.defineMethod`](worktree://b731251f-07d9-4b0d-8b4c-89bca14f4df5/src/class.zig#L59-L120) asks users to provide both a string signature such as `"ii"` and a Zig function whose parameter types restate that signature. Those can drift.

Zig reflection can derive marshalling and mruby arity from the callback type, with explicit marker types for optional, rest, and block parameters. Keep a `defineMethodRaw` escape hatch, but make the safe path impossible to describe inconsistently.

### Typestate for isolate lifecycle

Distinct `BootstrapIsolate`, `SealedIsolate`, and possibly `RunningIsolate` types would encode allowed operations at compile time instead of relying primarily on phase flags and documentation. This is particularly valuable for preventing raw VM access after policy sealing.

### Generated compile-time feature information

Generate a module exposing:

- Enabled gems
- mruby version
- compatibility fingerprint
- compiler availability
- sandbox/debug-hook availability
- target constraints

Applications could then use ordinary `comptime` branches instead of duplicating build knowledge or discovering features at runtime.

### Explicit allocators and named errors

Zig is strongest when ownership and failure are visible in signatures. Allocating diagnostics and serialization APIs should accept allocators; stable public methods should use named error sets and exhaustive mapping rather than inferred implementation-dependent errors.

### Build-time validation

The gem graph, presym inputs, and semantic build flags should be generated and validated at build time. The final presym scan currently claims to cover all relevant sources in [build.zig](worktree://b731251f-07d9-4b0d-8b4c-89bca14f4df5/build.zig#L163-L165), but the project shim is added later in [build.zig](worktree://b731251f-07d9-4b0d-8b4c-89bca14f4df5/build.zig#L280). It works only while the shim’s symbols happen to occur elsewhere.

---

## Performance

There is no evidence that the implementation is broadly slow, but there is also no benchmark or binary-size baseline. Performance claims should wait until the project measures:

- VM creation/destruction
- Eval and cached method-call throughput
- Host callback overhead
- Gas-hook cost
- Artifact export/import throughput and peak memory
- Binary size per gem/profile combination

Likely targets are already visible:

- The fetch hook executes on every bytecode instruction, even for effectively unlimited configurations, in [sandbox.zig](worktree://b731251f-07d9-4b0d-8b4c-89bca14f4df5/src/sandbox.zig#L1110-L1180).
- State-capsule export constructs a graph, encodes it, copies it into an envelope, and reparses/normalizes it in [artifact_value.zig](worktree://b731251f-07d9-4b0d-8b4c-89bca14f4df5/src/artifact_value.zig#L168-L235). The safety symmetry is good, but the export path can likely prove the same invariant without a complete second parse.
- Method names are repeatedly interned on calls; a cached `Symbol`/`MethodId` path would help callback-heavy users.
- A runtime-only embedding profile could omit compiler/debug-hook facilities and reduce binary size.

Profile first; optimize only confirmed costs.

---

## Documentation, organization, and maintenance

### Documentation

The README is detailed and unusually candid, but it is overloaded. It should become an overview pointing to stable documents:

1. Getting started and build options
2. Safe API ownership, lifetimes, and threading
3. Sandbox threat model and unsupported adversaries
4. Artifact wire format and compatibility policy
5. Platform/support matrix
6. mruby upgrade and patch-maintenance procedure
7. Release/versioning policy

Add runnable sandbox and artifact examples, and compile documentation snippets in CI. The host-function example also uses process-global class storage in [examples/host_functions.zig](worktree://b731251f-07d9-4b0d-8b4c-89bca14f4df5/examples/host_functions.zig#L25-L75), which is unsafe with multiple VMs and demonstrates a workaround for missing nested-class APIs. Examples should model the recommended production style.

### Organization

The large files are not inherently a problem, but [`sandbox.zig`](worktree://b731251f-07d9-4b0d-8b4c-89bca14f4df5/src/sandbox.zig#L1), [`artifact_value.zig`](worktree://b731251f-07d9-4b0d-8b4c-89bca14f4df5/src/artifact_value.zig#L1), and [`tests.zig`](worktree://b731251f-07d9-4b0d-8b4c-89bca14f4df5/src/tests.zig#L1) now mix enough concerns to slow navigation.

Split around meaningful invariants, not small helper categories:

- `ResolvedPolicy`
- `ExecutionGate`
- `TerminationController`
- Artifact graph validation/materialization
- Test suites by public subsystem

Keep the current public modules deep; avoid turning every helper into a new shallow module.

### Reproducibility and maintenance

[`.mise.toml`](worktree://b731251f-07d9-4b0d-8b4c-89bca14f4df5/.mise.toml#L1-L4) tracks Zig `master`, so a tagged mruby-zig release can stop building without any repository change. Pin an exact Zig version or compiler commit.

The build globally disables C warnings in [build.zig](worktree://b731251f-07d9-4b0d-8b4c-89bca14f4df5/build.zig#L103-L110). Suppress specific known upstream warnings, but compile project-owned shim code with warnings enabled.

The 64-bit-only constraint is correctly enforced in [c.zig](worktree://b731251f-07d9-4b0d-8b4c-89bca14f4df5/src/c.zig#L15-L22), but it should be rejected earlier by the build and documented in an explicit support matrix.

---

## Recommended roadmap

### P0: production correctness

1. Enforce VM affinity at every safe API boundary.
2. Put every allocation-capable mruby operation behind complete C protection trampolines.
3. Topologically sort and validate the full gem graph; repair the documented options.
4. Fix the Windows monotonic clock and define the supported platform matrix.
5. Pin Zig.
6. Introduce explicit trusted/restricted policy presets and immutable resolved policy.
7. Add tests for foreign-VM values, OOM at every public boundary, output cycles, and malformed names/source.

### P1: coherent public API

1. Add explicit rooted-value ownership.
2. Normalize conversion, allocator, and error semantics.
3. Add nested classes/modules, arrays/hashes, blocks/keywords, source metadata, and structured errors.
4. Replace partial output installation and recursive Ruby-level array traversal.
5. Add generated feature information and clean build diagnostics.
6. Split the README and test suite by public concern.

### P2: security and scale

1. Implement the worker-process execution tier with OS memory/CPU constraints.
2. Add cross-version artifact fixtures rather than testing only current producer/current consumer.
3. Add sustained fuzzing through both the pure parser and C materialization boundary.
4. Add sanitizer builds where supported and Windows runtime CI.
5. Establish performance and binary-size regression baselines.
6. Conduct a security review after the process boundary and capability manifest are complete.

Only after P0 should the project claim production readiness for trusted embedding. Production readiness for hostile code should wait for P2.

## Verification performed

The repository remained clean; I made no changes.

Passing checks:

- `mise x -- zig fmt --check .`
- `mise x -- zig build test -Doptimize=ReleaseSafe --summary all` — 198/198
- `mise x -- zig build test -Dgem-set=minimal --summary all` — 105/105
- `mise x -- zig build test -Dwithout-gems=mruby-enumerator --summary all` — 188/188

Targeted configuration checks exposed two concrete defects:

- The documented `-Dwith-gems=mruby-io` option panics as an unknown gem.
- `-Dgem-set=minimal -Dwith-gems=mruby-binding` builds but initializes gems in the wrong order and produced 99 test failures.

Overall: **keep the architecture, harden the boundaries, narrow the production claim, and complete the process-isolation story rather than rewriting the core.**
