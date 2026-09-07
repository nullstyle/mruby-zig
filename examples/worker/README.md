# Effects with a host broker

This example runs a small counter application in a confined child process. Ruby
receives `state` and `input`, performs explicit clock and outbox operations, and
returns `[result, next_state]`. The clock adapter and transaction live in the
parent. The child contains the compiled application and remote effect stubs.

```sh
mise x -- zig build run-effects-worker -Deffects-strict=true
mise x -- zig build test-effects-worker -Deffects-strict=true
```

These commands need no SQLite installation or optional SQLite dependency. The
strict profile selects minimal mruby without a runtime compiler. Workers are
available on Linux and macOS, on x86_64 and aarch64.

To run the installed pair, pass the child executable explicitly:

```sh
mise x -- zig build install -Deffects-strict=true
./zig-out/bin/effects-worker ./zig-out/bin/effects-worker-child
```

The host starts with count 7. Input adds 3, `Clock.now` returns the fixture time,
and `Outbox.prepare` stages an in-memory intent. Before returning prepared work,
the broker compares the child's receipt with its own callback transcript and
replays it in a second fresh child. Only an explicit `prepared.commit()` changes
the host's committed count to 10 and adopts the intent. The demo then replays the
receipt again without invoking adapters or transaction hooks.

The PID checks show that both Ruby executions occur outside the host while
every adapter executes in the parent. PIDs are host observations and do not
enter Ruby state or replay identity. The example's clock is fixed to make its
fixture repeatable; a real clock adapter would record its returned time.

## Files and build integration

- [`app.rb`](app.rb) defines `WorkerCounter.apply(state, input)`.
- [`contract.zig`](contract.zig) is the operation catalogue shared by the host,
  CodeDB manifest, and worker.
- [`../effects_worker.zig`](../effects_worker.zig) implements data-only adapters,
  the in-memory transaction, and the executable demonstration.
- [`../../tools/effects_worker.zig`](../../tools/effects_worker.zig) is the small
  reusable child entry point.

Downstream applications can use the public `addCodeDB` and `addEffectWorker`
helpers from this package's build module. Create the dependency with
`.@"effects-strict" = true`, compile a CodeDB bundle, and pass its `manifest`
module plus a module exporting `operations` to `addEffectWorker`. Install the
returned executable and give its trusted path to `strict.Worker.prepare`.
See the complete [host and build interfaces](../../docs/effects-workers.md).

The tests also compile adversarial worker fixtures. They check independent
grant, arity, sequence, receipt, terminal-state and clean-exit validation; failure
cleanup; deadline and allocation failures after host staging; replay across both
turn runners; raw native filesystem/network denial; and Linux worker termination
when its broker exits before confinement. The malicious fixtures
and confinement probe are test artifacts and are not installed.

## Transaction scope

The outbox is a private in-memory intent. This example does not send messages,
write durable storage, or restore external state during replay. Replay verifies
the result and next state under the recorded observations. Durable commit,
delivery, and crash reconciliation need an application persistence protocol.

Host adapters remain trusted and synchronous. A worker deadline cannot interrupt
an adapter blocked inside the host; expiry is checked when the adapter returns.
The host adapter must validate the meaning of its inert arguments and keep its
own external work bounded. See the [containment limits](../../docs/effects-workers.md#platform-containment-and-resources)
for platform requirements and resource controls.
