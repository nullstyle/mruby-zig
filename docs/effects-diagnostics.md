# Effect diagnostics and receipt inspection

Strict turns and workers return the same execution errors as before, with an
optional owned diagnostic that explains the failure. Workers now preserve
Ruby exception text, native-denial details, effect context, and replay mismatch
details across the private process channel. Inspection reads a stored receipt
without running Ruby or invoking adapters.

## Capture a failed turn

Pass a `strict.Turn.Diagnostic` through the existing options:

```zig
var diagnostic: mruby.strict.Turn.Diagnostic = .{};
var prepared = mruby.strict.Worker.prepare(
    allocator, worker_executable, manifest, "app", operations,
    request, host,
    .{ .turn = .{ .allowed = grants, .diagnostic = &diagnostic } },
) catch |err| {
    // Write to a caller-supplied std.Io.Writer. No Ruby formatting hooks run.
    diagnostic.writeJson(log_writer) catch {};
    return err;
};
defer prepared.deinit();
try prepared.commit();
```

Use `.diagnostic = &diagnostic` directly with `strict.Turn` or
`strict.Program.load`. Each entry resets the output. The diagnostic contains
fixed buffers and values; it needs no `deinit()` and remains valid after the
worker exits or the VM is destroyed. Reading or formatting it never runs Ruby
methods, loads code, or invokes an effect.

| Field | Meaning |
| --- | --- |
| `origin` | `turn` for in-process capture, `broker` for parent-side failures, or `worker` for a report received from a child. |
| `phase` | `setup`, `record`, `verification`, or explicitly requested `replay`. |
| `kind` | `effect`, `contract`, `native`, `terminal`, `ruby`, or a general `failure`; `none` after a successful entry. |
| `errorName()` | The execution error returned to the caller. |
| `messageText()`, `className()` | Bounded explanation or inert Ruby exception metadata, when available. |
| `source` | Optional native debug location: `fileName()`, `methodName()`, and a one-based line. Line zero means unknown. |
| `effect_detail` | Reason, zero-based record index, operation names/versions, mismatch hashes/offset, and optional `contract_detail` with schema side/path/kinds. |
| `contract_detail` | Whole-turn value side (`state`, `input`, `result`, `next_state`) and an owned schema mismatch in `detail`; JSON key `turn_contract`. |
| `native_detail` | Denied native name and reason: denied builtin, unknown native, forbidden primitive, or unapproved finalizer. |
| `expected_hash`, `actual_hash`, `byte_offset` | Terminal replay mismatch details. |
| `truncated` | A bounded text field did not fit; source metadata has its own truncation flag. |

For example, an ungranted `Outbox.prepare` reports `EffectDenied`, the operation
name `outbox.prepare`, and its effect index. A host adapter returning
`error.IntentStorageUnavailable` still fails execution as `EffectHandlerFailed`,
while its diagnostic retains the underlying name. A replay argument mismatch
includes the expected and actual argument hashes and first differing encoded
byte. These offsets refer to capsule bytes, not Ruby source columns.

Source locations come from native IREP/debug metadata. Missing or stripped
debug information produces no invented location. Guest-supplied backtrace
strings are not treated as source metadata. Ruby overrides of `message`,
`to_s`, or `backtrace` are not invoked to build diagnostics. Application
initializer failures are captured before the isolate is destroyed. Earlier
bootstrap failures may have only a general error or no additional detail.

An unknown Ruby constructor is ordinarily a Ruby `NameError`/`NoMethodError`.
A malformed worker operation is a broker request failure. These remain
different errors; reporting does not reinterpret either as a performed effect.

## Format safely

`diagnostic.writeJson(writer)` emits one ASCII JSON object with an explicit
`byte_text_encoding` field. It escapes control bytes and each non-ASCII byte as
`\u00xx`, preserving Ruby's byte strings without terminal control sequences or
an assumption of valid UTF-8. The output includes structured source, effect,
native, and terminal details. The caller controls the writer and log destination.

Raw accessor strings are length-delimited bytes. A custom renderer must escape
them for its destination too. Exception text is guest data even when captured
without calling guest methods. Formatting is optional and writer failure does
not change the already returned execution error.

The private worker protocol is now version 1.3, with an optional diagnostic
payload capped at 4 KiB. Its codec validates tags, lengths, reserved fields,
and exact framing before assigning an owned snapshot. Old private protocol
versions are rejected; deploy matching host and worker builds. Stored receipt
formats are unchanged.

The broker assigns the report's origin and execution phase itself. A worker
cannot claim that the broker observed its failure. Diagnostics do not authorize
an operation, validate a receipt, permit commit, or relax cleanup. Host adapters
are still trusted. A killed process or exhausted transport budget may leave
only a broker error, without a child source location or exception message.
Commit failures after `Prepared` is returned use the transaction's recovery
contract and are outside this execution diagnostic's scope.

## Inspect a stored receipt

The installed tool takes a binary `Turn.Prepared.receipt()` or
`Turn.Verified.receipt()` file:

```sh
mise x -- zig build
./zig-out/bin/mruby-effects-inspect ./turn.receipt

# Or build and run directly:
mise x -- zig build run-effects-inspect -- ./turn.receipt

# Inspect a constructed example receipt without running Ruby:
mise x -- zig build run-effects-inspect-demo
```

It works in ordinary, minimal, and strict builds. The executable links only
inert codecs: no mruby VM, application catalogue, worker, or SQLite connection.
The JSON report contains receipt and trace hashes, code/catalogue/input
identities, each recorded operation's name/version/outcome, capsule sizes and
graph counts, bounded rejection previews, and shallow result/state previews.
Node IDs describe the capsule graph, including aliases and cycles, without
recursively expanding it.

The library interface returns the same owned report:

```zig
var report = try mruby.effect.Inspection.inspect(
    allocator, receipt_bytes, .{},
);
defer report.deinit();
try log_writer.writeAll(report.json());
```

Inspection validates receipt/trace framing and checksums, the terminal pair,
every argument and outcome capsule, and rejection shape before returning any
report. It accepts at most 8 MiB of receipt bytes, 256 operations, 1 MiB per
capsule, 65,536 aggregate nodes, 262,144 aggregate edges, and 256 KiB of output
by default. String previews are at most 64 bytes and collection previews at
most four items. The library exposes these limits; the CLI uses the defaults.

An inspector report proves structural validity and checksums only. It does not
authenticate the observations, check application-specific grants or contracts,
replay the computation, prove commit, or deliver an intent. Use `Worker.replay`
for computation verification and the durable host's ledger for commit recovery.

```sh
mise x -- zig build test-effects-inspect
mise x -- zig build test-effects-worker test-effects-turn -Deffects-strict=true
```

Tests cover real child failures, broker/worker provenance, malformed diagnostics,
replay mismatches, source capture, hostile exception methods, bounded text,
inspection of cycles, malformed nested values, escaped output, and the
installed inspector's execution path.
