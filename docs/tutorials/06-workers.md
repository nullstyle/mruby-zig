# Part 6 — Confined effect workers

**Prerequisites**: [Part 5](05-turns.md). Strict profile required; workers
support Linux and macOS on x86_64 and aarch64:

```sh
mise x -- zig build run-effects-worker -Deffects-strict=true
mise x -- zig build test-effects-worker -Deffects-strict=true

# Installed host plus its application-specific child:
mise x -- zig build install -Deffects-strict=true
./zig-out/bin/effects-worker ./zig-out/bin/effects-worker-child
```

No SQLite installation or optional dependency is involved.

[Part 5](05-turns.md) ended on the gap: strict turns still share one process.
This part closes it. In the brokered arrangement, **application Ruby runs in
an OS-confined child process; only the parent owns adapters and the
transaction.** The child contains the compiled CodeDB application and remote
effect stubs — when Ruby performs an effect, the stub serializes the request
to the parent over a pipe, the parent's data-only adapter answers, and the
observation returns. The child cannot reach the clock, the database, or the
network except by asking through the seam.

## Reading the demo

[examples/effects_worker.zig](../../examples/effects_worker.zig) is the host;
[examples/worker/app.rb](../../examples/worker/app.rb) is the application
(`WorkerCounter.apply`); the reusable child entry point is
[tools/effects_worker.zig](../../tools/effects_worker.zig), built once per
application via the `addEffectWorker` build helper with that application's
manifest and contract modules.

The core call mirrors `Turn.prepare` from [Part 5](05-turns.md) — with an
executable where the VM used to be:

```zig
var prepared = try Worker.prepare(allocator, executable, manifest, "app",
    contract.operations, request(state.view(), input.view()), .{
        .bindings = &bindings,
        .transaction = host.transaction(),
    }, options(&observation));
defer prepared.deinit();
```

`Worker.Options` carries the turn policy (grants, limits, the whole-turn
contract, bootstrap identity) plus process-level controls such as
`wall_time_ns`. The demo then proves the arrangement with PIDs:

```zig
try testing.expect(observation.execution_pid != null and observation.verification_pid != null);
try testing.expect(observation.execution_pid.? != parent_pid);
try testing.expect(observation.verification_pid.? != parent_pid);
for (host.callback_pids[0..host.callbacks]) |pid| try testing.expectEqual(parent_pid, pid);
```

Two *different* child processes ran — one to execute, a second fresh child to
verify the receipt by replay — while every adapter callback ran in the parent.
PIDs are host observations; they never enter Ruby state or replay identity.

The broker does not take the child's word for anything: it compares the
child's receipt with its own transcript of adapter calls (independent grant,
arity, sequence, and result validation — a malicious child fails closed), and
only an explicit `prepared.commit()` adopts state and the staged intent.
`Worker.replay` later re-verifies the receipt in another fresh child without
invoking adapters or transaction hooks.

## What confinement means

The child is OS-confined: on Linux, `no_new_privs` plus a seccomp syscall
allowlist with stream IO restricted to one descriptor and filesystem, network,
and process creation denied; on macOS, a deny-default Seatbelt profile
denying file access, network connect/bind, process creation/exec, and Mach
lookup (Seatbelt is deprecated and may become unavailable on future systems).
Both platforms add a dedicated child process group, mandatory wall and CPU
limits, and forced cleanup/reaping on failure. The confinement
**hard-checks its architecture**: x86_64 builds refuse to run under an
aarch64 kernel, and Rosetta-style emulation cannot validate them.
The test suite includes a confinement probe and adversarial worker fixtures
(malformed receipts, wrong sequences, wrong results, unclean exits) and
verifies that a worker whose broker dies is reaped — on Linux, that the child
exits when its controller disappears.

Two boundaries the reference doc is emphatic about
([effects-workers.md](../effects-workers.md)):

- **Adapters remain trusted and synchronous.** A worker deadline cannot
  interrupt an adapter blocked inside the host; expiry is checked when the
  adapter returns. The host must keep its own external work bounded.
- **This is not a sandbox escape proof.** The containment narrows what
  *correct-but-untrusted* application code can touch; the platform trust
  assumptions are documented under "What this does not establish" in the same
  doc. The database, native adapters, allocator, OS, and storage remain
  trusted parts of the model.

Cross-platform evidence is taken seriously here: the confined-worker suite
has been validated natively on Linux and macOS, x86_64 and aarch64 — including
a real x86_64 Linux kernel VM (QEMU, Alpine 6.12, pinned toolchain), because
emulated userspace cannot validate seccomp. CI runs the suite on
ubuntu-latest and macos-latest. Emulated x86_64 userspace on an aarch64
kernel is explicitly invalid for this purpose.

## Failure behavior

The demo's `verifyFailure` table is a tour of what fail-closed looks like:
missing grant, omitted binding, deadline expiry, adapter Zig error, malformed
rejection payload, wrong-typed result — each fails `Worker.prepare`, the
transaction records exactly one begin and one discard, zero commits, state
untouched, and the child process is confirmed reaped (`waitpid` returns
`ECHILD`). Adapter failures surface as `EffectHandlerFailed` with the cause
in `Diagnostic.messageText()` ([effects-diagnostics.md](../effects-diagnostics.md)).

## What you can now build

A production-shaped host: build-time-compiled application, per-turn fresh
confined children, effects brokered to trusted parent adapters, receipts
verified by replay in a second child, and an explicit host commit gate — with
no in-process execution of application Ruby at all.

## Where it leads

Everything from here to the end of the series is one application of this
machine: the durable host of [Part 7](07-durable.md) runs these turns inside
a SQLite transaction, persists the receipts, and adds the recovery, upgrade,
audit, and delivery protocols.

Continue with [Part 7 — The durable host](07-durable.md).
