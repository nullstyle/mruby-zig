//! One-shot process-isolated RITE executor.
//!
//! stdin and stdout are a single private worker-protocol exchange. The
//! fixed-size request header is decoded and the process limits are installed
//! before any artifact body bytes are allocated.

const std = @import("std");
const builtin = @import("builtin");
const mruby = @import("mruby");
const protocol = @import("worker_protocol");

// The mruby C sources call this exported allocator entrypoint directly. Keep
// it reachable in test builds too, where `main` itself is not the root.
comptime {
    _ = mruby.alloc.mrb_basic_alloc_func_pub;
}

const empty_body: protocol.ResponseBody = .{
    .value = "",
    .exception_class = "",
    .exception_message = "",
    .diagnostic_path = "",
};

pub fn main(init: std.process.Init) !u8 {
    return mainObserved(init, NoObserver);
}

// The standalone process regression fixture instantiates this same worker
// with boundary synchronization. The installed helper uses NoObserver, so
// there are no inherited fixture descriptors or runtime observation hooks.
pub const Observation = enum { request_body, execution, response };
const NoObserver = struct {
    pub fn reached(comptime _: Observation) !void {}
};

pub fn mainObserved(init: std.process.Init, comptime Observer: type) !u8 {
    return run(init, Observer) catch 1;
}

fn run(init: std.process.Init, comptime Observer: type) !u8 {
    var stdin_buffer: [4096]u8 = undefined;
    var stdin_file = std.Io.File.stdin().reader(init.io, &stdin_buffer);
    const reader = &stdin_file.interface;

    // Keep the protocol on a private duplicate, then point process stdout at
    // /dev/null before mruby starts. Core `print`/`p` and optional I/O gems
    // can therefore never inject bytes into the framed response.
    const protocol_file = try isolateProtocolOutput(init.io);
    // Deliberately leave this descriptor open until kernel process teardown.
    // Protocol EOF then proves the direct helper has exited, so the controller
    // can kill remaining group members without racing this process's cleanup.
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file = protocol_file.writer(init.io, &stdout_buffer);
    const writer = &stdout_file.interface;

    var request_header_bytes: [protocol.request_header_len]u8 = undefined;
    reader.readSliceAll(&request_header_bytes) catch {
        return sendSimple(writer, .worker_error, .none, .invalid_request, null);
    };
    const request = protocol.decodeRequest(&request_header_bytes) catch {
        return sendSimple(writer, .worker_error, .none, .invalid_request, null);
    };

    if (!validProcessLimits(request.process)) {
        return sendSimple(writer, .worker_error, .bootstrap, .invalid_request, null);
    }
    if (applyProcessLimits(request.process)) |failure| {
        return sendSimple(writer, .worker_error, .bootstrap, failure, null);
    }
    const address_space_limited = effectiveAddressSpaceLimited() orelse {
        return sendSimple(
            writer,
            .worker_error,
            .bootstrap,
            .process_limit_setup_failed,
            null,
        );
    };
    const allocation_failures_before = mruby.alloc.backingAllocationFailures();

    const body_len = request.bodyLen() catch {
        return sendSimple(writer, .worker_error, .none, .invalid_request, null);
    };
    const encoded_body = init.gpa.alloc(u8, body_len) catch {
        return sendSimple(
            writer,
            if (address_space_limited) .limit else .worker_error,
            .bootstrap,
            if (address_space_limited) .address_space_exceeded else .out_of_memory,
            null,
        );
    };
    defer init.gpa.free(encoded_body);

    try Observer.reached(.request_body);
    reader.readSliceAll(encoded_body) catch {
        return sendSimple(writer, .worker_error, .none, .invalid_request, null);
    };
    _ = reader.takeByte() catch |err| switch (err) {
        error.EndOfStream => return execute(
            init.gpa,
            writer,
            request,
            encoded_body,
            address_space_limited,
            allocation_failures_before,
            Observer,
        ),
        error.ReadFailed => return sendSimple(writer, .worker_error, .none, .internal_error, null),
    };
    return sendSimple(writer, .worker_error, .none, .invalid_request, null);
}

fn isolateProtocolOutput(io: std.Io) !std.Io.File {
    const protocol_fd = std.c.dup(std.posix.STDOUT_FILENO);
    if (protocol_fd < 0) return error.ProtocolOutputSetupFailed;
    const protocol_file: std.Io.File = .{
        .handle = protocol_fd,
        .flags = .{ .nonblocking = false },
    };
    errdefer protocol_file.close(io);
    if (!setCloseOnExec(protocol_fd)) return error.ProtocolOutputSetupFailed;

    const null_file = try std.Io.Dir.openFileAbsolute(io, "/dev/null", .{
        .mode = .write_only,
    });
    defer null_file.close(io);
    if (std.c.dup2(null_file.handle, std.posix.STDOUT_FILENO) < 0) {
        return error.ProtocolOutputSetupFailed;
    }
    return protocol_file;
}

fn setCloseOnExec(fd: std.posix.fd_t) bool {
    while (true) switch (std.posix.errno(std.posix.system.fcntl(
        fd,
        std.posix.F.SETFD,
        @as(usize, std.posix.FD_CLOEXEC),
    ))) {
        .SUCCESS => return true,
        .INTR => continue,
        else => return false,
    };
}

fn execute(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    request: protocol.RequestHeader,
    encoded_body: []const u8,
    address_space_limited: bool,
    allocation_failures_before: usize,
    comptime Observer: type,
) !u8 {
    const body = protocol.splitRequestBody(request, encoded_body) catch {
        return sendSimple(writer, .worker_error, .none, .invalid_request, null);
    };
    const policy = policyFromWire(request.policy);

    var boot = mruby.sandbox.BootstrapIsolate.spawn(policy) catch |err| {
        return sendSetupError(
            writer,
            .bootstrap,
            err,
            isAddressSpaceFailure(address_space_limited, allocation_failures_before, err),
        );
    };
    defer boot.deinit();
    if (addressSpaceExceeded(address_space_limited, allocation_failures_before)) {
        return sendSimple(writer, .limit, .bootstrap, .address_space_exceeded, null);
    }

    const isolate = boot.seal() catch |err| {
        return sendSetupError(
            writer,
            .bootstrap,
            err,
            isAddressSpaceFailure(address_space_limited, allocation_failures_before, err),
        );
    };
    defer isolate.deinit();
    if (addressSpaceExceeded(address_space_limited, allocation_failures_before)) {
        return sendSimple(
            writer,
            .limit,
            .bootstrap,
            .address_space_exceeded,
            statsToWire(isolate.stats()),
        );
    }

    if (body.input) |input_bytes| {
        const input = isolate.importValue(.{ .bytes = input_bytes }, .{
            .accepted_schema = optionalSchemaFromWire(request.input_schema),
        }) catch |err| {
            return sendIsolateError(
                writer,
                isolate,
                .input,
                err,
                isAddressSpaceFailure(address_space_limited, allocation_failures_before, err),
            );
        };
        if (addressSpaceExceeded(address_space_limited, allocation_failures_before)) {
            return sendSimple(
                writer,
                .limit,
                .input,
                .address_space_exceeded,
                statsToWire(isolate.stats()),
            );
        }
        isolate.setGlobal("input", input) catch |err| {
            return sendIsolateError(
                writer,
                isolate,
                .input,
                err,
                isAddressSpaceFailure(address_space_limited, allocation_failures_before, err),
            );
        };
        if (addressSpaceExceeded(address_space_limited, allocation_failures_before)) {
            return sendSimple(
                writer,
                .limit,
                .input,
                .address_space_exceeded,
                statsToWire(isolate.stats()),
            );
        }
    }

    try Observer.reached(.execution);
    const value = isolate.runRite(.{ .bytes = body.image }) catch |err| {
        return sendIsolateError(
            writer,
            isolate,
            .execute,
            err,
            isAddressSpaceFailure(address_space_limited, allocation_failures_before, err),
        );
    };
    if (addressSpaceExceeded(address_space_limited, allocation_failures_before)) {
        return sendSimple(
            writer,
            .limit,
            .execute,
            .address_space_exceeded,
            statsToWire(isolate.stats()),
        );
    }

    var capsule = isolate.exportValue(allocator, value, .{
        .schema = optionalSchemaFromWire(request.output_schema),
    }) catch |err| {
        return sendIsolateError(
            writer,
            isolate,
            .output,
            err,
            isAddressSpaceFailure(address_space_limited, allocation_failures_before, err),
        );
    };
    defer capsule.deinit(allocator);
    if (addressSpaceExceeded(address_space_limited, allocation_failures_before)) {
        return sendSimple(
            writer,
            .limit,
            .output,
            .address_space_exceeded,
            statsToWire(isolate.stats()),
        );
    }

    if (capsule.encoded.len > protocol.max_body_len) {
        return sendSimple(
            writer,
            .artifact_rejected,
            .output,
            .artifact_limit_exceeded,
            statsToWire(isolate.stats()),
        );
    }
    try Observer.reached(.response);
    return sendResponse(writer, .{
        .outcome = .value,
        .phase = .none,
        .detail = .none,
        .stats = statsToWire(isolate.stats()),
    }, .{
        .value = capsule.encoded,
        .exception_class = "",
        .exception_message = "",
        .diagnostic_path = "",
    });
}

fn validProcessLimits(limits: protocol.ProcessLimits) bool {
    if (limits.wall_time_ns == 0 or limits.cpu_seconds == 0) return false;
    return switch (limits.address_space) {
        .unbounded => true,
        .bytes => |bytes| bytes != 0,
    };
}

fn effectiveAddressSpaceLimited() ?bool {
    return switch (builtin.os.tag) {
        .linux => (std.posix.getrlimit(.AS) catch return null).cur != std.posix.RLIM.INFINITY,
        .macos => false,
        else => unreachable,
    };
}

fn addressSpaceExceeded(enabled: bool, allocation_failures_before: usize) bool {
    return enabled and
        mruby.alloc.backingAllocationFailures() != allocation_failures_before;
}

fn isAddressSpaceFailure(
    enabled: bool,
    allocation_failures_before: usize,
    err: anyerror,
) bool {
    return enabled and (err == error.OutOfMemory or
        addressSpaceExceeded(enabled, allocation_failures_before));
}

/// Returns a wire detail on failure. Keeping this non-allocating lets the
/// caller report setup failures even when the requested address-space ceiling
/// is too small for the artifact body.
fn applyProcessLimits(limits: protocol.ProcessLimits) ?protocol.Detail {
    return switch (builtin.os.tag) {
        .linux => applyLinuxProcessLimits(limits),
        .macos => applyMacProcessLimits(limits),
        else => .process_limit_setup_failed,
    };
}

fn applyLinuxProcessLimits(limits: protocol.ProcessLimits) ?protocol.Detail {
    if (!applyCommonProcessLimits(limits.cpu_seconds)) return .process_limit_setup_failed;
    switch (limits.address_space) {
        .unbounded => {},
        .bytes => |bytes| {
            const value: std.posix.rlim_t = @intCast(bytes);
            if (!installCeiling(.AS, value)) return .process_limit_setup_failed;
        },
    }
    return null;
}

fn applyMacProcessLimits(limits: protocol.ProcessLimits) ?protocol.Detail {
    switch (limits.address_space) {
        .unbounded => {},
        .bytes => return .hard_memory_limit_unavailable,
    }
    if (!applyCommonProcessLimits(limits.cpu_seconds)) return .process_limit_setup_failed;
    return null;
}

fn applyCommonProcessLimits(cpu_seconds: u32) bool {
    if (!installCeiling(.CORE, 0)) return false;
    normalizeCpuSignal();
    const cpu: std.posix.rlim_t = @intCast(cpu_seconds);
    if (!installCpuCeiling(cpu)) return false;
    return true;
}

/// Signal dispositions set to ignored and the calling thread's signal mask
/// survive exec. Restore the CPU-limit signal so an embedding parent cannot
/// accidentally disable the helper's soft ceiling.
fn normalizeCpuSignal() void {
    const default_action: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.XCPU, &default_action, null);

    var unblock = std.posix.sigemptyset();
    std.posix.sigaddset(&unblock, .XCPU);
    std.posix.sigprocmask(std.posix.SIG.UNBLOCK, &unblock, null);
}

/// Leave one second between the catchable soft signal and the hard kill. A
/// worker that catches or ignores SIGXCPU still cannot run indefinitely.
fn installCpuCeiling(requested: std.posix.rlim_t) bool {
    const inherited = std.posix.getrlimit(.CPU) catch return false;
    const ceiling = chooseCpuCeiling(requested, inherited) orelse return false;
    std.posix.setrlimit(.CPU, .{ .cur = ceiling.soft, .max = ceiling.hard }) catch return false;
    return true;
}

const CpuCeiling = struct {
    soft: std.posix.rlim_t,
    hard: std.posix.rlim_t,
};

fn chooseCpuCeiling(
    requested: std.posix.rlim_t,
    inherited: std.posix.rlimit,
) ?CpuCeiling {
    const hard = @min(requested +| 1, inherited.max);
    if (hard == 0) return null;
    var soft = @min(requested, inherited.cur, hard);
    // Linux checks the hard threshold first. Preserve a one-second signal
    // window even when a shell supplied equal inherited soft/hard limits.
    if (soft >= hard) soft = hard - 1;
    return .{ .soft = soft, .hard = hard };
}

/// Never relax a stricter limit inherited from the controller. Setting both
/// halves to the effective ceiling also prevents later worker code from
/// raising the soft limit again.
fn installCeiling(resource: std.posix.rlimit_resource, requested: std.posix.rlim_t) bool {
    const inherited = std.posix.getrlimit(resource) catch return false;
    const effective = @min(requested, inherited.cur);
    std.posix.setrlimit(resource, .{ .cur = effective, .max = effective }) catch return false;
    return true;
}

fn policyFromWire(wire: protocol.SandboxPolicy) mruby.sandbox.Policy {
    return .{
        .limits = .{
            .instructions = null,
            .gas = switch (wire.limits.gas) {
                .unlimited => .unlimited,
                .per_isolate => |limit| .{ .per_isolate = limit },
                .per_execution => |limit| .{ .per_execution = limit },
            },
            .wall_time_ns = wire.limits.wall_time_ns,
            .memory_bytes = wire.limits.memory_bytes,
            .hard_memory_bytes = wire.limits.hard_memory_bytes,
            .call_depth = wire.limits.call_depth,
        },
        .capabilities = .{
            .eval = wire.capabilities.eval,
            .send = wire.capabilities.send,
            .introspection = wire.capabilities.introspection,
            .object_space = wire.capabilities.object_space,
            .freeze_object_model = wire.capabilities.freeze_object_model,
            .random_seed = wire.capabilities.random_seed,
            .clock_epoch_s = wire.capabilities.clock_epoch_s,
        },
        .artifacts = .{
            .limits = .{
                .max_rite_bytes = wire.artifacts.max_rite_bytes,
                .capsule = .{
                    .max_encoded_bytes = wire.artifacts.capsule.max_encoded_bytes,
                    .max_nodes = wire.artifacts.capsule.max_nodes,
                    .max_total_edges = wire.artifacts.capsule.max_total_edges,
                    .max_depth = wire.artifacts.capsule.max_depth,
                    .max_string_bytes = wire.artifacts.capsule.max_string_bytes,
                    .max_symbol_bytes = wire.artifacts.capsule.max_symbol_bytes,
                },
            },
            .application = if (wire.artifacts.application) |bytes|
                .{ .bytes = bytes }
            else
                null,
        },
    };
}

fn optionalSchemaFromWire(schema: ?protocol.Schema) ?mruby.artifact.Schema {
    const wire = schema orelse return null;
    return .{
        .id = wire.id,
        .major = wire.major,
        .minor = wire.minor,
    };
}

fn statsToWire(stats: mruby.sandbox.Stats) protocol.SandboxStats {
    return .{
        .instructions = stats.instructions,
        .gas = if (stats.gas) |gas| .{
            .scope = switch (gas.scope) {
                .isolate => .isolate,
                .execution => .execution,
            },
            .generation = gas.generation,
            .limit = gas.limit,
            .used = gas.used,
            .remaining = gas.remaining,
            .exhausted = gas.exhausted,
            .observed_instructions = gas.observed_instructions,
        } else null,
        .peak_memory_bytes = stats.peak_memory_bytes,
        .live_memory_bytes = stats.live_memory_bytes,
        .peak_call_depth = stats.peak_call_depth,
        .live_objects = stats.live_objects,
        .wall_time_ns = stats.wall_time_ns,
        .soft_memory_limit_hit = stats.soft_memory_limit_hit,
        .hard_memory_limit_hit = stats.hard_memory_limit_hit,
    };
}

fn sendSetupError(
    writer: *std.Io.Writer,
    phase: protocol.Phase,
    err: anyerror,
    address_space_exceeded: bool,
) !u8 {
    if (address_space_exceeded) {
        return sendSimple(writer, .limit, phase, .address_space_exceeded, null);
    }
    if (limitDetail(err)) |detail| {
        return sendSimple(writer, .limit, phase, detail, null);
    }
    const detail: protocol.Detail = if (err == error.OutOfMemory)
        .out_of_memory
    else if (err == error.ConflictingGasPolicy)
        .conflicting_gas_policy
    else if (err == error.CapabilityApplicationFailed)
        .capability_application_failed
    else
        .internal_error;
    return sendSimple(writer, .worker_error, phase, detail, null);
}

fn sendIsolateError(
    writer: *std.Io.Writer,
    isolate: mruby.sandbox.Isolate,
    phase: protocol.Phase,
    err: anyerror,
    address_space_exceeded: bool,
) !u8 {
    const stats = statsToWire(isolate.stats());
    if (address_space_exceeded) {
        return sendSimple(writer, .limit, phase, .address_space_exceeded, stats);
    }
    if (err == error.RubyException) {
        if (phase == .execute) return sendRubyException(writer, isolate, stats);
        return sendSimple(writer, .worker_error, phase, .internal_error, stats);
    }
    if (limitDetail(err)) |detail| {
        return sendSimple(writer, .limit, phase, detail, stats);
    }
    if (artifactDetail(err) != null or isolate.lastArtifactError() != null) {
        return sendArtifactRejection(writer, isolate, phase, err, stats);
    }
    const detail: protocol.Detail = if (err == error.OutOfMemory)
        .out_of_memory
    else if (err == error.ConflictingGasPolicy)
        .conflicting_gas_policy
    else if (err == error.CapabilityApplicationFailed)
        .capability_application_failed
    else
        .internal_error;
    return sendSimple(writer, .worker_error, phase, detail, stats);
}

fn sendRubyException(
    writer: *std.Io.Writer,
    isolate: mruby.sandbox.Isolate,
    stats: protocol.SandboxStats,
) !u8 {
    const ruby_error = isolate.lastError() orelse {
        return sendSimple(writer, .worker_error, .execute, .internal_error, stats);
    };

    var class_storage: [protocol.max_exception_class_len]u8 = undefined;
    var class_fba = std.heap.FixedBufferAllocator.init(&class_storage);
    var exception_truncated = false;
    const class_name = ruby_error.className(class_fba.allocator()) catch blk: {
        exception_truncated = true;
        const fallback = "<exception class unavailable>";
        @memcpy(class_storage[0..fallback.len], fallback);
        break :blk class_storage[0..fallback.len];
    };

    var message_storage: [protocol.max_exception_message_len]u8 = undefined;
    var message_fba = std.heap.FixedBufferAllocator.init(&message_storage);
    const message = ruby_error.message(message_fba.allocator()) catch blk: {
        exception_truncated = true;
        const fallback = "<exception message unavailable>";
        @memcpy(message_storage[0..fallback.len], fallback);
        break :blk message_storage[0..fallback.len];
    };

    return sendResponse(writer, .{
        .outcome = .ruby_exception,
        .phase = .execute,
        .detail = .ruby_exception,
        .stats = stats,
        .exception_truncated = exception_truncated,
    }, .{
        .value = "",
        .exception_class = class_name,
        .exception_message = message,
        .diagnostic_path = "",
    });
}

fn sendArtifactRejection(
    writer: *std.Io.Writer,
    isolate: mruby.sandbox.Isolate,
    phase: protocol.Phase,
    err: anyerror,
    stats: protocol.SandboxStats,
) !u8 {
    const diagnostic = isolate.lastArtifactError();
    const detail = if (diagnostic) |present|
        detailFromDiagnostic(present.kind)
    else
        artifactDetail(err) orelse .internal_error;

    var path_storage: [protocol.max_diagnostic_path_len]u8 = undefined;
    var path: []const u8 = "";
    var path_truncated = false;
    if (diagnostic) |present| {
        if (present.graph_path) |source| {
            const len = @min(source.len, path_storage.len);
            @memcpy(path_storage[0..len], source[0..len]);
            path = path_storage[0..len];
            path_truncated = source.len > len;
        }
    }

    return sendResponse(writer, .{
        .outcome = .artifact_rejected,
        .phase = phase,
        .detail = detail,
        .stats = stats,
        .diagnostic_path_truncated = path_truncated,
    }, .{
        .value = "",
        .exception_class = "",
        .exception_message = "",
        .diagnostic_path = path,
    });
}

fn limitDetail(err: anyerror) ?protocol.Detail {
    if (err == error.ScriptTerminated) return .script_terminated;
    if (err == error.DeadlineExceeded) return .deadline_exceeded;
    if (err == error.GasExhausted) return .gas_exhausted;
    if (err == error.MemoryLimitExceeded) return .memory_limit_exceeded;
    if (err == error.CallDepthExceeded) return .call_depth_exceeded;
    return null;
}

fn artifactDetail(err: anyerror) ?protocol.Detail {
    if (err == error.InvalidArtifact) return .invalid_artifact;
    if (err == error.ChecksumMismatch) return .checksum_mismatch;
    if (err == error.UnsupportedArtifactVersion) return .unsupported_artifact_version;
    if (err == error.ArtifactLimitExceeded) return .artifact_limit_exceeded;
    if (err == error.IncompatibleRiteImage) return .incompatible_rite_image;
    if (err == error.SchemaMismatch) return .schema_mismatch;
    if (err == error.CapsuleLimitExceeded) return .capsule_limit_exceeded;
    if (err == error.ForeignValue) return .foreign_value;
    if (err == error.UnsupportedValue) return .unsupported_value;
    if (err == error.UnsupportedContainerState) return .unsupported_container_state;
    if (err == error.UnsupportedHashKey) return .unsupported_hash_key;
    if (err == error.NumericOutOfRange) return .numeric_out_of_range;
    if (err == error.ArtifactConstructionFailed) return .artifact_construction_failed;
    return null;
}

fn detailFromDiagnostic(kind: mruby.sandbox.ArtifactDiagnostic.Kind) protocol.Detail {
    return switch (kind) {
        .invalid_envelope, .dangling_reference, .duplicate_object_id, .duplicate_hash_key => .invalid_artifact,
        .checksum_mismatch => .checksum_mismatch,
        .unsupported_version => .unsupported_artifact_version,
        .limit_exceeded => .artifact_limit_exceeded,
        .foreign_value => .foreign_value,
        .unsupported_value => .unsupported_value,
        .unsupported_container_state => .unsupported_container_state,
        .unsupported_hash_key => .unsupported_hash_key,
        .numeric_out_of_range => .numeric_out_of_range,
        .schema_mismatch => .schema_mismatch,
        .construction_failed => .artifact_construction_failed,
    };
}

fn sendSimple(
    writer: *std.Io.Writer,
    outcome: protocol.Outcome,
    phase: protocol.Phase,
    detail: protocol.Detail,
    stats: ?protocol.SandboxStats,
) !u8 {
    return sendResponse(writer, .{
        .outcome = outcome,
        .phase = phase,
        .detail = detail,
        .stats = stats,
    }, empty_body);
}

fn sendResponse(
    writer: *std.Io.Writer,
    source_header: protocol.ResponseHeader,
    body: protocol.ResponseBody,
) !u8 {
    var header = source_header;
    header.value_len = body.value.len;
    header.exception_class_len = body.exception_class.len;
    header.exception_message_len = body.exception_message.len;
    header.diagnostic_path_len = body.diagnostic_path.len;
    const encoded_header = try protocol.encodeResponse(header);
    try writer.writeAll(&encoded_header);
    try writer.writeAll(body.value);
    try writer.writeAll(body.exception_class);
    try writer.writeAll(body.exception_message);
    try writer.writeAll(body.diagnostic_path);
    try writer.flush();
    return 0;
}

test "CPU ceiling keeps a soft-signal window under equal inherited limits" {
    const equal = chooseCpuCeiling(30, .{ .cur = 5, .max = 5 }).?;
    try std.testing.expectEqual(@as(std.posix.rlim_t, 4), equal.soft);
    try std.testing.expectEqual(@as(std.posix.rlim_t, 5), equal.hard);

    const requested = chooseCpuCeiling(2, .{ .cur = 20, .max = 20 }).?;
    try std.testing.expectEqual(@as(std.posix.rlim_t, 2), requested.soft);
    try std.testing.expectEqual(@as(std.posix.rlim_t, 3), requested.hard);
    try std.testing.expect(chooseCpuCeiling(1, .{ .cur = 0, .max = 0 }) == null);
}

test "protocol output descriptor is close-on-exec" {
    const duplicate = std.c.dup(std.posix.STDERR_FILENO);
    if (duplicate < 0) return error.UnexpectedDupFailure;
    const duplicate_file: std.Io.File = .{
        .handle = duplicate,
        .flags = .{ .nonblocking = false },
    };
    defer duplicate_file.close(std.testing.io);

    try std.testing.expect(setCloseOnExec(duplicate));
    const flags = std.posix.system.fcntl(duplicate, std.posix.F.GETFD, @as(usize, 0));
    try std.testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(flags));
    try std.testing.expect(@as(usize, @intCast(flags)) & std.posix.FD_CLOEXEC != 0);
}
