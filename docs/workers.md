# One-shot worker processes

`mruby.worker.runRite` executes a typed RITE image in a fresh helper process
and returns only after that process has exited cleanly and been reaped. It is the
process-isolated counterpart to `sandbox.Isolate.runRite`, with a deliberately
smaller boundary: one optional `StateCapsule` enters as `$input`, one RITE
image runs, and one `StateCapsule` or typed failure comes back.

When `mruby.features.worker_process_supported` is true, the helper is built
from `tools/mruby_worker.zig` and installed as `mruby-worker`. Always deploy
the helper artifact produced by the same mruby-zig dependency configuration as
the `mruby` module. In a consuming `build.zig`, forward the application's
target and optimization settings, retrieve the helper with
`dep.artifact("mruby-worker")`, and install it beside the application:

```zig
const target = b.standardTargetOptions(.{});
const optimize = b.standardOptimizeOption(.{});
const dep = b.dependency("mruby", .{
    .target = target,
    .optimize = optimize,
});
const worker = dep.artifact("mruby-worker");
b.installArtifact(worker);
```

At runtime, resolve the installed sibling from the application's own absolute
path, or accept an absolute path from trusted deployment configuration:

```zig
const application_path = try std.process.executablePathAlloc(io, allocator);
defer allocator.free(application_path);
const application_dir = std.fs.path.dirname(application_path) orelse
    return error.InvalidApplicationPath;
const worker_executable = try std.fs.path.join(
    allocator,
    &.{ application_dir, "mruby-worker" },
);
defer allocator.free(worker_executable);
```

With `.@"no-compiler" = true`, the worker omits the parser/code generator and
compiler-backed eval while preserving gas, deadlines, termination, and seeded
RNG policies. Produce its images through `addCodeDB` using that same configured
dependency, then pass `mruby.codedb.find(manifest, name).?` as the request image.
The compiler profile participates in the compatibility fingerprint. The
runtime source-compilation example below applies to compiler-enabled builds.

`worker.getEmittedBin()` is useful for build-time run steps and tests, but it
names a build-cache artifact and must not be baked into a deployed program.
The runtime API requires an explicit absolute path, or an explicit relative
path containing a path separator. It never searches `PATH`. The IPC format is
private to the package; matching protocol versions are checked, but wire
compatibility between mruby-zig releases is not promised.

```zig
const std = @import("std");
const mruby = @import("mruby");

fn runJob(
    io: std.Io,
    allocator: std.mem.Allocator,
    worker_executable: []const u8,
    input_capsule: mruby.artifact.StateCapsuleView,
    input_schema: mruby.artifact.Schema,
    output_schema: mruby.artifact.Schema,
) !void {
    var image = try mruby.sandbox.compileRite(
        allocator,
        "$input.fetch(:count) + 1",
        .{},
    );
    defer image.deinit(allocator);

    // `input_capsule` was exported by another Isolate and is borrowed for
    // this call. A schema can be required independently in each direction.
    var report = try mruby.worker.runRite(io, allocator, worker_executable, .{
        .image = image.view(),
        .input = .{
            .capsule = input_capsule,
            .accepted_schema = input_schema,
        },
        .output_schema = output_schema,
        .policy = mruby.sandbox.Policy.restricted(.{
            .limits = .{ .gas = .{ .per_execution = 1_000_000 } },
        }),
        .process = .{
            .wall_time_ns = 2 * std.time.ns_per_s,
            .cpu_seconds = 1,
        },
    });
    defer report.deinit(allocator);

    switch (report.outcome) {
        .value => |capsule| {
            // Import `capsule.view()` into a destination Isolate to inspect
            // the Ruby value. The report owns these bytes until deinit.
            _ = capsule;
        },
        .ruby_exception => |exception| {
            std.debug.print("{s}: {s}\n", .{
                exception.class_name,
                exception.message,
            });
        },
        .limit => |limit| std.debug.print("limit: {s}\n", .{@tagName(limit)}),
        .artifact_rejected => |failure| {
            std.debug.print("artifact rejected during {s}: {s}\n", .{
                @tagName(failure.phase),
                @tagName(failure.reason),
            });
        },
    }
}
```

`Report` owns successful capsule bytes, exception strings, and any diagnostic
path. Call `report.deinit(allocator)` on every successful `runRite` result.
Ruby exceptions, sandbox limits, process wall/CPU/address-space limits, and
artifact rejections are typed `Outcome` values; launch, transport, protocol,
and helper setup failures are `RunError`s. Unknown crashes and non-CPU signals
may surface as `error.WorkerFailed` rather than a typed limit. Returned
capsules are parsed again by the controller before they are exposed. Sandbox
and process ceilings are independent; set the sandbox deadline below the
process deadline when a cooperative failure with sandbox statistics is
preferable to a hard kill.

## Enforcement and platform contract

Worker availability is fail-closed and visible through separate feature
flags:

- `worker_target_supported` is true for supported process targets (currently
  64-bit Linux and macOS).
- `worker_profile_eligible` is true only when the aggregate linked authority
  excludes filesystem, network, process, environment, and `native_host`
  access. `native_host` means an arbitrary native-host escape, not merely that
  a gem happens to be implemented in C.
- Core `host_output` authority is deliberately eligible: the helper preserves
  its protocol on a private descriptor and redirects process stdout to
  `/dev/null` before constructing the VM.
- `worker_process_supported` combines the target check with profile
  eligibility. When false, the helper is not built and `runRite` returns
  `error.UnsupportedPlatform`.

Both shipped gem presets are eligible today. A build owner who has separately
audited an ineligible local catalog may pass
`-Dallow-worker-ambient-authority=true`; the generated
`worker_ambient_authority_opt_in` records that choice and re-enables the
worker on supported targets. This override neither strips the reported
authority nor adds syscall confinement.

In a consuming package, `-Dallow-worker-ambient-authority=true` sets a root
option; Zig does not implicitly pass it to dependencies. The application must
declare that option and forward it as
`.@"allow-worker-ambient-authority" = allow_worker_ambient_authority` in the
`b.dependency("mruby", .{ ... })` options, as shown in
[getting-started.md](getting-started.md#gem-configuration).

- The parent applies one absolute boot-clock deadline to request writing,
  response reading, process exit, and reaping. On expiry it sends `SIGKILL` to
  the worker's process group and direct child, then reaps the direct child.
  A complete response is accepted only after a clean direct-child exit; the
  parent then kills any descendants left in that process group. Process
  creation itself has no interruptible timeout in the pinned Zig API.
- The controller must keep `SIGCHLD` at its default disposition and must not
  run a competing wait-any child reaper for the duration of `runRite`. Calls
  made with `SIGCHLD` ignored or `SA_NOCLDWAIT` set fail before spawn with
  `error.ChildReapingUnavailable`; loss of wait ownership during a call fails
  with the same error. This contract lets the controller verify that a
  waitable child still anchors its numeric process-group id before signaling
  descendants.
- `SIGPIPE` must have a non-default disposition for the duration of the call,
  so a helper that closes its request pipe becomes a transport result instead
  of terminating the controller. Zig's standard threaded I/O initialization
  installs such a handler. Other backends must arrange one; otherwise the call
  fails before spawn with `error.BrokenPipeProtectionUnavailable`.
- On macOS, worker launches are serialized internally. Because `pipe()` cannot
  create close-on-exec descriptors atomically, the application must also avoid
  unrelated concurrent `fork`/`spawn` operations while `runRite` is active.
  Otherwise that unrelated child could inherit a transient transport handle,
  exposing request data or delaying protocol EOF. Linux uses atomic
  `pipe2(O_CLOEXEC)` and does not have this additional launch constraint.
- Linux and macOS install `RLIMIT_CPU` and disable core dumps before reading
  the request body. The helper restores and unblocks `SIGXCPU` before applying
  that ceiling, so an ignored or blocked signal inherited from the controller
  cannot disable it. Linux can additionally install a finite `RLIMIT_AS`;
  macOS rejects finite address-space requests with
  `error.HardMemoryLimitUnavailable`. A Linux allocation failure that the
  helper can report becomes `.limit = .process_address_space`, whether the
  effective finite ceiling was requested or inherited. Backing allocator
  rejection is sticky for the request, so rescuing Ruby's immediate
  `NoMemoryError` cannot turn address-space exhaustion into a successful
  result. An abrupt unclassified signal can still surface as
  `error.WorkerFailed`. CPU and address-space ceilings apply to each process,
  not to aggregate usage across a descendant tree; descendants inherit the
  ceilings but receive their own accounting.
- `process_peak_rss_bytes` is the operating system's direct-child `wait4`
  statistic. It is not a guaranteed measurement of an entire descendant
  tree.
- The helper receives an empty environment. It duplicates the protocol handle
  as close-on-exec and redirects process stdout to `/dev/null` before mruby
  starts, while stderr is ignored. Ordinary Ruby output therefore cannot
  contaminate the framing and there is intentionally no output-capture API.
  The spawn API also preserves unrelated controller descriptors that were not
  marked close-on-exec. Custom native or I/O gems with ambient file-descriptor
  access remain inside the trust boundary: they can reach those inherited
  descriptors and can subvert the stdout separation.
- The authority manifest covers linked core/compiler/gem code. The generic
  helper has no application host bootstrap callbacks or classes, so callback
  authority is absent rather than inferred, and application-fingerprinted
  RITE images are intentionally unsupported. Use build-compatible,
  application-independent images.

This is process and resource isolation, not a complete operating-system
sandbox. It does not yet install a syscall filter, filesystem jail, network
namespace, or separate user identity. The default gem set omits filesystem,
socket, directory, and general I/O gems. If the explicit authority override is
used for a profile that can access host assets, that code runs as the same OS
user as the helper. Treat the helper as defense in depth for crash and
resource containment; add an external OS/container sandbox before running
fully hostile code with access-sensitive deployments.
