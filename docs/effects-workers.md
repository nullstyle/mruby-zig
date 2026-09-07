# Contained effect workers

`mruby.strict.Worker` executes the [explicit turn contract](effects-turns.md)
in a separate, OS-contained process. Native effect adapters stay in the host.
The host validates and records every requested operation, then starts another
fresh worker to replay the complete receipt before returning prepared work.
The broker never creates a Ruby VM.

```sh
mise x -- zig build run-effects-worker -Deffects-strict=true
mise x -- zig build test-effects-worker -Deffects-strict=true
```

The Ruby experience remains `Effect.perform(Clock.now)`. Methods still receive
`(state, input)` and return `[result, next_state]`. Hosts keep the same data-only
handlers and commit/discard contract as `strict.Turn`.

## Host interface

```zig
var prepared = try mruby.strict.Worker.prepare(
    allocator, worker_executable, manifest, "app", operations,
    .{ .receiver = "Counter", .state = state.view(), .input = input.view() },
    .{ .bindings = &bindings, .transaction = transaction },
    .{
        .turn = .{
            .allowed = &.{ "clock.now", "outbox.prepare" },
            .bootstrap_identity = adapter_contract_digest,
            .adapter_state_identity = external_starting_state_digest,
        },
        .process = .{ .wall_time_ns = 30 * std.time.ns_per_s },
    },
);
defer prepared.deinit();
try prepared.commit();
```

`worker_executable` names the trusted worker built for this application. Use an
absolute path, or an explicit relative path containing `/`; there is no PATH
search. The worker embeds the same CodeDB manifest and operation catalogue as
the host. Do not select executables from guest input.

`prepare` returns `strict.Turn.Prepared`. Its receipt and joint terminal graph
are owned bytes; both child processes have exited and been reaped. Preparation
never commits automatically. A failed recording, malformed RPC, disagreement
with the host journal, failed verification, crash, or timeout discards a
successfully begun host transaction exactly once. A failed `begin` cleans up
its own partial setup. Commit rejection and uncertainty have the same semantics
as [in-process turns](effects-turns.md#prepare-commit-or-discard).

`Worker.replay` takes the same executable, manifest, entry, catalogue, request,
receipt bytes, and options, without any Host argument. It uses one fresh worker,
invokes no native adapters or transaction hooks, and returns `Turn.Verified`.
Receipts are compatible with in-process `Turn.replay` for the same application,
inputs, grants, and adapter identities. Grant order is part of the existing
bootstrap identity and is preserved across the wire.

## Build one worker per application

Use the strict dependency for both CodeDB and the worker:

```zig
const dep = b.dependency("mruby", .{
    .target = target,
    .optimize = optimize,
    .@"effects-strict" = true,
});
const child = mruby.addEffectWorker(b, dep, .{
    .name = "orders-worker",
    .target = target,
    .optimize = optimize,
    .manifest = codedb_manifest_module,
    .contract = operation_contract_module,
});
b.installArtifact(child);
```

The contract module exports `operations`, the pure descriptors shared with
CodeDB and the host. The build helper supplies the worker entry point and links
the strict runtime. Native host handlers are supplied only to the host broker;
they are not registered in the child. See the complete
[worker example](../examples/worker/README.md) and its build registration.

`features.effects_worker_supported` reports strict worker support. The older
`worker.runRite` interface remains disabled in strict builds. Worker availability
does not widen the strict native catalogue or enable extra gems.

## Execution and authority

```mermaid
sequenceDiagram
    participant Host as Host broker
    participant Record as Recording worker
    participant Adapter as Host adapter / transaction
    participant Replay as Verification worker
    Host->>Record: Owned inputs, immutable grants, bounded policy
    Record->>Record: OS confinement, strict initialization, import
    Record->>Host: Ready
    Host->>Adapter: Begin
    Host->>Record: Ready acknowledgement
    Record->>Host: Operation, version, sequence, inert arguments
    Host->>Host: Check grant / arity / bounds, reserve journal
    Host->>Adapter: Stage effect
    Adapter->>Host: Inert return or rejection
    Host->>Record: Recorded outcome
    Record->>Host: Receipt, then clean exit
    Host->>Host: Compare receipt with host journal
    Host->>Replay: Same inputs plus receipt; no adapters
    Replay->>Host: Verified receipt, then clean exit
    Host->>Host: Return Prepared; explicit commit remains available
```

A private bidirectional socket on descriptor 3 is the sole protocol channel.
Standard descriptors refer to `/dev/null`, other inherited descriptors are
closed, and the environment is empty. Containment is installed after validating
the fixed startup header and before allocating the request body or creating a
Ruby VM. The executable's native startup and confinement implementation remain
trusted.

The host independently checks message kind/order, application identity,
code/catalogue/input identities, operation index/name/version, immutable grants,
positional arity, full inert
graphs, result/rejection shape, and all configured byte/record bounds. It reserves
a complete journal slot before invoking a handler. A compromised guest cannot
widen grants by forging an RPC, claim a different outcome than the host recorded,
or turn a successful prefix into an accepted receipt. Unexpected messages,
trailing output, incomplete frames, and nonzero child exits fail preparation.

These are capability checks, not business authorization: a granted operation
may be requested with any inert arguments allowed by its contract. The adapter
must enforce account ownership, paths, SQL policy, and other application rules.

## Platform containment and resources

Supported targets are Linux and macOS on x86_64 and aarch64. Unsupported targets
or unavailable confinement fail closed.

| Platform | Enforced containment |
| --- | --- |
| Linux | `no_new_privs` and seccomp syscall allowlist; stream IO restricted to descriptor 3; filesystem, network and process creation denied. Descriptor closure requires Linux 5.9 or newer. |
| macOS | Deny-default Seatbelt profile denying file access, network connect/bind, process creation/exec and Mach lookup. Unconnected socket creation itself is still possible. Seatbelt is deprecated and may become unavailable on future systems. |

Both platforms use a dedicated child process group, bounded socket transfers,
mandatory process wall and CPU limits, and forced cleanup/reaping on failure.
Reaping can outlast the deadline if the OS leaves a killed process stuck in an
uninterruptible kernel operation.
Linux installs a parent-death signal before exec and checks the original broker
identity, covering broker death during startup. The host must not use competing child
reapers or change its SIGCHLD disposition while a worker is active.

Defaults are 30 seconds for the complete record-plus-verification wall budget,
30 CPU seconds per child, and 256 MiB of combined sent/received bytes per child.
The protocol caps a frame body at 64 MiB and wall budgets at ten minutes.
`address_space_bytes` optionally sets an OS address-space limit on Linux;
macOS rejects it instead of claiming to enforce it. Ruby gas, capsule limits,
and per-VM allocation limits remain independently available through `.turn`.

Native host adapters are synchronous and trusted. Their work is not preempted
by the worker deadline: a blocked adapter can delay the host call's return.
The child's own transport deadline/CPU limit continues to run, and the broker
rejects an expired session when the adapter returns. Keep adapters bounded or
put their external operations behind host-managed timeouts.

`Options.observation` can receive execution and verification PIDs for host
instrumentation. These never enter Ruby state or replay identity. Worker errors
cross the protocol as bounded, recognized error names. `Turn.Options.diagnostic`
also receives owned exception, source, native, effect, and replay details when
available. The broker stamps their origin and execution phase; see
[diagnostics and receipt inspection](effects-diagnostics.md).

[Typed operation contracts](effects-contracts.md) are checked independently by
the child runtime and broker. The broker validates arguments before callbacks,
outcomes before journal commit, and every receipt record before replay. Contract
digests are bound into the application handshake and catalogue identity.

## What this does not establish

The worker binary, OS kernel, broker codec, native adapter implementations, and
transaction semantics remain trusted. OS containment reduces the authority
available after a native VM bug; it is not a proof of native memory safety or
absence of timing/resource side channels. The native runtime needs internal
clocks and allocation behavior that Ruby must still be prevented from observing
through unreviewed APIs. Cross-architecture float/libc determinism remains
unproven.

Receipt checksums detect corruption and do not authenticate observations or
prove a host commit occurred. Fresh replay verifies computation under the
supplied observations. Durable intent delivery, consensus acceptance, receipt
signing, and crash reconciliation belong to the host's persistence protocol.
Handlers that publish immediately cannot be rolled back by either turn runner.

The [durable reference host](effects-durable.md) demonstrates the persistence
protocol with SQLite: immutable turn-ID admission, atomic state/receipt/outbox
commit, committed retry lookup, and a local idempotent recipient. Its real
process-kill tests exercise crash recovery independently of the worker's
computation checks.
