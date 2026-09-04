//! One-shot process-isolated execution of typed RITE images.
//!
//! `runRite` is deliberately synchronous and returns only after the helper
//! process has exited and been reaped. The executable path is explicit so the
//! controller never searches PATH or guesses an installation layout. Process
//! handles, framing, deadlines, and cleanup remain private to this module.

const std = @import("std");
const builtin = @import("builtin");
const artifact = @import("artifact.zig");
const artifact_config = @import("artifact_config");
const artifact_value = @import("artifact_value.zig");
const build_features = @import("build_features");
const sandbox = @import("sandbox.zig");
const protocol = @import("worker_protocol");

pub const supported: bool = build_features.worker_process_supported;

pub const AddressSpaceLimit = union(enum) {
    unbounded,
    bytes: usize,
};

/// Limits enforced outside mruby. The wall deadline is mandatory and spans
/// the complete request/response/reap lifecycle. The CPU ceiling is also
/// mandatory; address-space enforcement is available on Linux.
pub const ProcessLimits = struct {
    wall_time_ns: u64 = 30 * std.time.ns_per_s,
    cpu_seconds: u32 = 30,
    address_space: AddressSpaceLimit = .unbounded,
};

pub const Input = struct {
    capsule: artifact.StateCapsuleView,
    accepted_schema: ?artifact.Schema = null,
};

pub const Request = struct {
    image: artifact.RiteImageView,
    input: ?Input = null,
    output_schema: ?artifact.Schema = null,
    policy: sandbox.Policy = .{},
    process: ProcessLimits = .{},
};

pub const LimitKind = enum {
    script_terminated,
    sandbox_deadline,
    sandbox_gas,
    sandbox_memory,
    sandbox_call_depth,
    process_wall,
    process_cpu,
    process_address_space,
};

pub const Phase = enum {
    bootstrap,
    input,
    execute,
    output,
};

pub const OwnedException = struct {
    class_name: []u8,
    message: []u8,
    truncated: bool,
};

pub const ArtifactRejection = struct {
    phase: Phase,
    reason: Reason,
    graph_path: ?[]u8 = null,
    graph_path_truncated: bool = false,

    pub const Reason = enum {
        invalid_artifact,
        checksum_mismatch,
        unsupported_version,
        limit_exceeded,
        incompatible_rite_image,
        schema_mismatch,
        foreign_value,
        unsupported_value,
        unsupported_container_state,
        unsupported_hash_key,
        numeric_out_of_range,
        construction_failed,
    };
};

pub const Outcome = union(enum) {
    value: artifact.StateCapsule,
    ruby_exception: OwnedException,
    limit: LimitKind,
    artifact_rejected: ArtifactRejection,
};

/// Fully owned result. No field refers to helper memory or to the request.
pub const Report = struct {
    outcome: Outcome,
    sandbox_stats: ?sandbox.Stats,
    process_peak_rss_bytes: ?usize,

    pub fn deinit(report: *Report, allocator: std.mem.Allocator) void {
        switch (report.outcome) {
            .value => |*capsule| capsule.deinit(allocator),
            .ruby_exception => |exception| {
                allocator.free(exception.message);
                allocator.free(exception.class_name);
            },
            .artifact_rejected => |rejection| {
                if (rejection.graph_path) |path| allocator.free(path);
            },
            .limit => {},
        }
        report.* = undefined;
    }
};

pub const RunError = std.mem.Allocator.Error || error{
    UnsupportedPlatform,
    InvalidOptions,
    UnsupportedApplicationBootstrap,
    HardMemoryLimitUnavailable,
    SpawnFailed,
    TransportFailure,
    ProtocolMismatch,
    RequestTooLarge,
    ResponseTooLarge,
    ProcessControlFailed,
    ChildReapingUnavailable,
    BrokenPipeProtectionUnavailable,
    ProcessLimitSetupFailed,
    WorkerFailed,
    ConcurrencyUnavailable,
    Canceled,
};

const ExchangeError = std.mem.Allocator.Error || error{
    TransportFailure,
    ProtocolMismatch,
    ResponseTooLarge,
    Timeout,
    Canceled,
};

const TimedIoError = error{
    TransportFailure,
    Timeout,
    Canceled,
};

const RawResponse = struct {
    header: protocol.ResponseHeader,
    body: ?[]u8,

    fn deinit(response: *RawResponse, allocator: std.mem.Allocator) void {
        if (response.body) |body| allocator.free(body);
        response.* = undefined;
    }

    fn takeBody(response: *RawResponse) []u8 {
        const body = response.body orelse unreachable;
        response.body = null;
        return body;
    }

    fn bodyBytes(response: *const RawResponse) []const u8 {
        return response.body orelse &.{};
    }
};

/// Execute one typed image in a fresh helper process. Inputs are borrowed for
/// this call; the returned report owns its capsule or diagnostic strings.
/// Every successful spawn is killed if necessary and reaped before return.
pub fn runRite(
    io: std.Io,
    allocator: std.mem.Allocator,
    worker_executable: []const u8,
    request: Request,
) RunError!Report {
    if (comptime !supported) return error.UnsupportedPlatform;
    // A relative path containing '/' is still an explicit executable path;
    // `spawn` only consults PATH when argv[0] contains no path separator.
    if ((!std.fs.path.isAbsolute(worker_executable) and
        std.mem.indexOfScalar(u8, worker_executable, '/') == null) or
        std.mem.indexOfScalar(u8, worker_executable, 0) != null or
        request.image.bytes.len == 0 or
        request.process.wall_time_ns == 0 or
        request.process.cpu_seconds == 0 or
        request.policy.artifacts.limits.capsule.max_encoded_bytes > protocol.max_body_len)
    {
        return error.InvalidOptions;
    }
    if (request.input) |input| {
        if (input.capsule.bytes.len == 0) return error.InvalidOptions;
    }
    if (request.policy.limits.gas != null and request.policy.limits.instructions != null) {
        return error.InvalidOptions;
    }
    if (request.policy.artifacts.application != null) {
        return error.UnsupportedApplicationBootstrap;
    }
    switch (request.process.address_space) {
        .unbounded => {},
        .bytes => |bytes| {
            if (bytes == 0) return error.InvalidOptions;
            if (builtin.os.tag == .macos) return error.HardMemoryLimitUnavailable;
        },
    }
    if (!childWaitOwnershipAvailable()) return error.ChildReapingUnavailable;
    if (!brokenPipeProtected()) return error.BrokenPipeProtectionUnavailable;

    const request_header = protocol.encodeRequest(.{
        .image_len = request.image.bytes.len,
        .input_len = if (request.input) |input| input.capsule.bytes.len else null,
        .policy = try encodePolicy(request.policy),
        .input_schema = if (request.input) |input| encodeSchema(input.accepted_schema) else null,
        .output_schema = encodeSchema(request.output_schema),
        .process = .{
            .wall_time_ns = request.process.wall_time_ns,
            .cpu_seconds = request.process.cpu_seconds,
            .address_space = switch (request.process.address_space) {
                .unbounded => .unbounded,
                .bytes => |bytes| .{ .bytes = bytes },
            },
        },
    }) catch |err| return switch (err) {
        error.BodyTooLarge, error.LengthOverflow => error.RequestTooLarge,
        else => error.InvalidOptions,
    };

    const deadline = std.Io.Clock.Timestamp.fromNow(io, .{
        .raw = std.Io.Duration.fromNanoseconds(@intCast(request.process.wall_time_ns)),
        .clock = .boot,
    });

    var child = try spawnWorker(allocator, worker_executable);
    const child_pid = child.id.?;
    // Once spawn succeeds, block caller cancellation until the direct child
    // has been reaped. The mandatory process deadline still bounds this scope.
    const old_cancel_protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(old_cancel_protection);

    const input_file = child.stdin.?;
    child.stdin = null;
    const output_file = child.stdout.?;
    child.stdout = null;
    var output_open = true;
    defer if (output_open) output_file.close(io);
    defer if (child.id != null) terminateAndReap(io, &child, child_pid);

    var write_future = std.Io.concurrent(io, writeRequest, .{
        io,
        input_file,
        deadline,
        &request_header,
        request.image.bytes,
        if (request.input) |input| input.capsule.bytes else null,
    }) catch {
        input_file.close(io);
        return error.ConcurrencyUnavailable;
    };
    var write_finished = false;
    defer if (!write_finished) {
        write_future.cancel(io) catch {};
    };

    var response_failure: ?ExchangeError = null;
    var raw_response: ?RawResponse = readResponse(
        io,
        allocator,
        output_file,
        deadline,
        request.policy.artifacts.limits.capsule.max_encoded_bytes,
    ) catch |err| failed: {
        response_failure = err;
        break :failed null;
    };
    defer if (raw_response) |*response| response.deinit(allocator);
    var termination_sent = false;
    if (response_failure != null) {
        if (!(try terminateOwnedProcessGroup(child_pid))) {
            child.id = null;
            return error.ChildReapingUnavailable;
        }
        termination_sent = true;
    }

    var write_failure: ?TimedIoError = null;
    write_future.await(io) catch |err| {
        write_failure = err;
    };
    write_finished = true;

    output_file.close(io);
    output_open = false;

    const write_failure_allowed = if (write_failure) |err|
        err == error.TransportFailure and raw_response != null and
            responseMayPrecedeRequestBody(raw_response.?.header)
    else
        true;

    if (!termination_sent) {
        if (!(try terminateOwnedProcessGroup(child_pid))) {
            child.id = null;
            return error.ChildReapingUnavailable;
        }
    }
    const term = child.wait(io) catch return error.ProcessControlFailed;
    const peak_rss = child.resource_usage_statistics.getMaxRss();

    const timed_out = (if (response_failure) |err| err == error.Timeout else false) or
        (if (write_failure) |err| err == error.Timeout else false);
    if (isCpuLimitSignal(term)) return processLimitReport(.process_cpu, peak_rss);
    if (timed_out) return processLimitReport(.process_wall, peak_rss);
    if (response_failure) |err| {
        return switch (err) {
            error.Timeout => unreachable,
            error.OutOfMemory => error.OutOfMemory,
            error.Canceled => error.Canceled,
            error.TransportFailure => error.TransportFailure,
            error.ProtocolMismatch => error.ProtocolMismatch,
            error.ResponseTooLarge => error.ResponseTooLarge,
        };
    }
    if (!write_failure_allowed) return error.TransportFailure;
    if (!isSuccessfulExit(term)) return error.WorkerFailed;

    return decodeReport(
        allocator,
        &raw_response.?,
        request.output_schema,
        request.policy.artifacts.limits.capsule,
        peak_rss,
    );
}

fn writeRequest(
    io: std.Io,
    file: std.Io.File,
    deadline: std.Io.Clock.Timestamp,
    header: *const [protocol.request_header_len]u8,
    image: []const u8,
    input: ?[]const u8,
) TimedIoError!void {
    defer file.close(io);
    try writeAllUntil(io, file, header, deadline);
    try writeAllUntil(io, file, image, deadline);
    if (input) |bytes| try writeAllUntil(io, file, bytes, deadline);
}

fn writeAllUntil(
    io: std.Io,
    file: std.Io.File,
    bytes: []const u8,
    deadline: std.Io.Clock.Timestamp,
) TimedIoError!void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const completion = io.operateTimeout(.{
            .file_write_streaming = .{ .file = file, .data = &.{bytes[offset..]} },
        }, .{ .deadline = deadline }) catch |err| return mapTimedOuterError(err);
        const written = completion.file_write_streaming catch return error.TransportFailure;
        if (written == 0) return error.TransportFailure;
        offset += written;
    }
}

fn readResponse(
    io: std.Io,
    allocator: std.mem.Allocator,
    file: std.Io.File,
    deadline: std.Io.Clock.Timestamp,
    max_value_len: usize,
) ExchangeError!RawResponse {
    var response_bytes: [protocol.response_header_len]u8 = undefined;
    try readAllUntil(io, file, &response_bytes, deadline);
    const response_header = protocol.decodeResponse(&response_bytes) catch |err| return switch (err) {
        error.BodyTooLarge, error.LengthOverflow => error.ResponseTooLarge,
        else => error.ProtocolMismatch,
    };
    const body_len = responseBodyLengthForAllocation(response_header, max_value_len) catch |err| return switch (err) {
        error.BodyTooLarge, error.LengthOverflow => error.ResponseTooLarge,
        else => error.ProtocolMismatch,
    };
    const body: ?[]u8 = if (body_len == 0) null else try allocator.alloc(u8, body_len);
    errdefer if (body) |bytes| allocator.free(bytes);
    if (body) |bytes| try readAllUntil(io, file, bytes, deadline);
    if (try readByteUntil(io, file, deadline) != null) return error.ProtocolMismatch;
    return .{ .header = response_header, .body = body };
}

fn responseBodyLengthForAllocation(
    header: protocol.ResponseHeader,
    max_value_len: usize,
) protocol.Error!usize {
    if (header.outcome == .value and header.value_len > max_value_len) {
        return error.BodyTooLarge;
    }
    return header.bodyLen();
}

fn responseMayPrecedeRequestBody(header: protocol.ResponseHeader) bool {
    if (header.outcome == .worker_error) return true;
    return header.outcome == .limit and
        header.phase == .bootstrap and
        header.detail == .address_space_exceeded;
}

fn readAllUntil(
    io: std.Io,
    file: std.Io.File,
    bytes: []u8,
    deadline: std.Io.Clock.Timestamp,
) TimedIoError!void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const completion = io.operateTimeout(.{
            .file_read_streaming = .{ .file = file, .data = &.{bytes[offset..]} },
        }, .{ .deadline = deadline }) catch |err| return mapTimedOuterError(err);
        const count = completion.file_read_streaming catch return error.TransportFailure;
        if (count == 0) return error.TransportFailure;
        offset += count;
    }
}

fn readByteUntil(
    io: std.Io,
    file: std.Io.File,
    deadline: std.Io.Clock.Timestamp,
) TimedIoError!?u8 {
    var byte: [1]u8 = undefined;
    while (true) {
        const completion = io.operateTimeout(.{
            .file_read_streaming = .{ .file = file, .data = &.{&byte} },
        }, .{ .deadline = deadline }) catch |err| return mapTimedOuterError(err);
        const count = completion.file_read_streaming catch |err| return switch (err) {
            error.EndOfStream => null,
            else => error.TransportFailure,
        };
        if (count == 0) return null;
        return byte[0];
    }
}

fn mapTimedOuterError(err: anyerror) TimedIoError {
    return switch (err) {
        error.Timeout => error.Timeout,
        error.Canceled => error.Canceled,
        else => error.TransportFailure,
    };
}

fn childWaitOwnershipAvailable() bool {
    var action: std.posix.Sigaction = undefined;
    std.posix.sigaction(.CHLD, null, &action);
    const no_child_wait = @as(@TypeOf(action.flags), std.posix.SA.NOCLDWAIT);
    return action.handler.handler == std.posix.SIG.DFL and
        action.flags & no_child_wait == 0;
}

fn brokenPipeProtected() bool {
    var action: std.posix.Sigaction = undefined;
    std.posix.sigaction(.PIPE, null, &action);
    return action.handler.handler != std.posix.SIG.DFL;
}

extern fn mrz_worker_spawn(
    path: [*:0]const u8,
    pid_out: *std.posix.pid_t,
    stdin_fd_out: *std.posix.fd_t,
    stdout_fd_out: *std.posix.fd_t,
) c_int;

fn spawnWorker(
    allocator: std.mem.Allocator,
    worker_executable: []const u8,
) RunError!std.process.Child {
    const path = try allocator.dupeSentinel(u8, worker_executable, 0);
    defer allocator.free(path);

    var pid: std.posix.pid_t = undefined;
    var stdin_fd: std.posix.fd_t = undefined;
    var stdout_fd: std.posix.fd_t = undefined;
    if (mrz_worker_spawn(path, &pid, &stdin_fd, &stdout_fd) != 0) {
        return error.SpawnFailed;
    }
    return .{
        .id = pid,
        .thread_handle = {},
        .stdin = .{ .handle = stdin_fd, .flags = .{ .nonblocking = false } },
        .stdout = .{ .handle = stdout_fd, .flags = .{ .nonblocking = false } },
        .stderr = null,
        .request_resource_usage_statistics = true,
    };
}

const ChildProbe = enum {
    exited,
    running,
    unavailable,
};

fn probeChild(pid: std.posix.pid_t) RunError!ChildProbe {
    return switch (builtin.os.tag) {
        .linux => probeChildLinux(pid),
        .macos => probeChildMac(pid),
        else => unreachable,
    };
}

fn probeChildLinux(pid: std.posix.pid_t) RunError!ChildProbe {
    const linux = std.os.linux;
    var info: linux.siginfo_t = std.mem.zeroes(linux.siginfo_t);
    while (true) switch (linux.errno(linux.waitid(
        .PID,
        pid,
        &info,
        linux.W.EXITED | linux.W.NOWAIT | linux.W.NOHANG,
        null,
    ))) {
        .SUCCESS => return if (info.fields.common.first.piduid.pid == 0)
            .running
        else
            .exited,
        .INTR => continue,
        .CHILD => return .unavailable,
        else => return error.ProcessControlFailed,
    };
}

const mac_wait = struct {
    const IdType = enum(c_uint) {
        all,
        pid,
        pgid,
    };

    const exited = 0x00000004;
    const no_hang = 0x00000001;
    const no_wait = 0x00000020;

    extern "c" fn waitid(
        id_type: IdType,
        id: c_uint,
        info: *std.posix.siginfo_t,
        options: c_int,
    ) c_int;
};

fn probeChildMac(pid: std.posix.pid_t) RunError!ChildProbe {
    var info: std.posix.siginfo_t = std.mem.zeroes(std.posix.siginfo_t);
    while (true) switch (std.posix.errno(mac_wait.waitid(
        .pid,
        @intCast(pid),
        &info,
        mac_wait.exited | mac_wait.no_wait | mac_wait.no_hang,
    ))) {
        .SUCCESS => return if (info.pid == 0) .running else .exited,
        .INTR => continue,
        .CHILD => return .unavailable,
        else => return error.ProcessControlFailed,
    };
}

/// Verify that `pid` is still our child before using its numeric process-group
/// id. An exited child remains waitable because WNOWAIT reserves the zombie;
/// a live child is signaled immediately. Callers must exclude competing child
/// reapers for the duration of `runRite` (documented by the public contract).
fn terminateOwnedProcessGroup(pid: std.posix.pid_t) RunError!bool {
    switch (try probeChild(pid)) {
        .unavailable => return false,
        .exited, .running => hardKillGroupAndChild(pid),
    }
    return true;
}

fn terminateAndReap(io: std.Io, child: *std.process.Child, pid: std.posix.pid_t) void {
    const owned = terminateOwnedProcessGroup(pid) catch {
        // Without verified wait ownership, neither the pid nor its process
        // group is safe to signal numerically.
        child.id = null;
        return;
    };
    if (!owned) {
        // SIGCHLD disposition changed or another component reaped this child.
        // The numeric pid is no longer safe to signal.
        child.id = null;
        return;
    }
    _ = child.wait(io) catch {};
}

fn hardKillGroupAndChild(pid: std.posix.pid_t) void {
    std.posix.kill(-pid, .KILL) catch {};
    std.posix.kill(pid, .KILL) catch {};
}

fn processLimitReport(kind: LimitKind, peak_rss: ?usize) Report {
    return .{
        .outcome = .{ .limit = kind },
        .sandbox_stats = null,
        .process_peak_rss_bytes = peak_rss,
    };
}

fn decodeReport(
    allocator: std.mem.Allocator,
    response: *RawResponse,
    output_schema: ?artifact.Schema,
    capsule_limits: artifact.CapsuleLimits,
    peak_rss: ?usize,
) RunError!Report {
    const body = protocol.splitResponseBody(response.header, response.bodyBytes()) catch
        return error.ProtocolMismatch;
    const stats = if (response.header.stats) |wire| decodeStats(wire) else null;

    const outcome: Outcome = switch (response.header.outcome) {
        .value => value: {
            if (body.value.len == 0 or body.exception_class.len != 0 or
                body.exception_message.len != 0 or body.diagnostic_path.len != 0 or
                response.header.phase != .none or response.header.detail != .none)
            {
                return error.ProtocolMismatch;
            }
            var failure: artifact_value.Failure = .{};
            var parsed = artifact_value.parse(allocator, .{ .bytes = body.value }, .{
                .limits = capsule_limits,
                .accepted_schema = output_schema,
            }, &failure) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.ProtocolMismatch,
            };
            parsed.deinit(allocator);
            break :value .{ .value = .{ .encoded = response.takeBody() } };
        },
        .ruby_exception => exception: {
            if (body.value.len != 0 or body.diagnostic_path.len != 0 or
                body.exception_class.len == 0 or response.header.phase != .execute or
                response.header.detail != .ruby_exception)
            {
                return error.ProtocolMismatch;
            }
            const class_name = try allocator.dupe(u8, body.exception_class);
            errdefer allocator.free(class_name);
            const message = try allocator.dupe(u8, body.exception_message);
            break :exception .{ .ruby_exception = .{
                .class_name = class_name,
                .message = message,
                .truncated = response.header.exception_truncated,
            } };
        },
        .limit => limit: {
            if (body.value.len != 0 or body.exception_class.len != 0 or
                body.exception_message.len != 0 or body.diagnostic_path.len != 0)
            {
                return error.ProtocolMismatch;
            }
            break :limit .{ .limit = try decodeLimit(response.header.detail) };
        },
        .artifact_rejected => rejected: {
            if (body.value.len != 0 or body.exception_class.len != 0 or
                body.exception_message.len != 0)
            {
                return error.ProtocolMismatch;
            }
            const graph_path = if (body.diagnostic_path.len == 0)
                null
            else
                try allocator.dupe(u8, body.diagnostic_path);
            break :rejected .{ .artifact_rejected = .{
                .phase = try decodePhase(response.header.phase),
                .reason = try decodeArtifactReason(response.header.detail),
                .graph_path = graph_path,
                .graph_path_truncated = response.header.diagnostic_path_truncated,
            } };
        },
        .worker_error => switch (response.header.detail) {
            .out_of_memory => return error.WorkerFailed,
            .hard_memory_limit_unavailable => return error.HardMemoryLimitUnavailable,
            .process_limit_setup_failed => return error.ProcessLimitSetupFailed,
            else => return error.WorkerFailed,
        },
    };
    return .{
        .outcome = outcome,
        .sandbox_stats = stats,
        .process_peak_rss_bytes = peak_rss,
    };
}

test "Ruby exception frames are execution-only" {
    try std.testing.expectError(error.InvalidField, protocol.encodeResponse(.{
        .outcome = .ruby_exception,
        .phase = .input,
        .detail = .ruby_exception,
        .exception_class_len = 1,
    }));
}

fn encodePolicy(policy: sandbox.Policy) RunError!protocol.SandboxPolicy {
    const gas: protocol.GasLimit = if (policy.limits.gas) |configured| switch (configured) {
        .unlimited => .unlimited,
        .per_isolate => |limit| .{ .per_isolate = limit },
        .per_execution => |limit| .{ .per_execution = limit },
    } else if (policy.limits.instructions) |limit|
        .{ .per_isolate = limit }
    else
        .unlimited;
    return .{
        .limits = .{
            .gas = gas,
            .wall_time_ns = policy.limits.wall_time_ns,
            .memory_bytes = policy.limits.memory_bytes,
            .hard_memory_bytes = policy.limits.hard_memory_bytes,
            .call_depth = policy.limits.call_depth,
        },
        .capabilities = .{
            .eval = policy.capabilities.eval,
            .send = policy.capabilities.send,
            .introspection = policy.capabilities.introspection,
            .object_space = policy.capabilities.object_space,
            .freeze_object_model = policy.capabilities.freeze_object_model,
            .random_seed = policy.capabilities.random_seed,
            .clock_epoch_s = policy.capabilities.clock_epoch_s,
        },
        .artifacts = .{
            .max_rite_bytes = policy.artifacts.limits.max_rite_bytes,
            .capsule = .{
                .max_encoded_bytes = policy.artifacts.limits.capsule.max_encoded_bytes,
                .max_nodes = policy.artifacts.limits.capsule.max_nodes,
                .max_total_edges = policy.artifacts.limits.capsule.max_total_edges,
                .max_depth = policy.artifacts.limits.capsule.max_depth,
                .max_string_bytes = policy.artifacts.limits.capsule.max_string_bytes,
                .max_symbol_bytes = policy.artifacts.limits.capsule.max_symbol_bytes,
            },
            .application = null,
        },
    };
}

fn encodeSchema(schema: ?artifact.Schema) ?protocol.Schema {
    const value = schema orelse return null;
    return .{ .id = value.id, .major = value.major, .minor = value.minor };
}

fn decodeStats(stats: protocol.SandboxStats) sandbox.Stats {
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

fn decodeLimit(detail: protocol.Detail) RunError!LimitKind {
    return switch (detail) {
        .script_terminated => .script_terminated,
        .deadline_exceeded => .sandbox_deadline,
        .gas_exhausted => .sandbox_gas,
        .memory_limit_exceeded => .sandbox_memory,
        .call_depth_exceeded => .sandbox_call_depth,
        .address_space_exceeded => .process_address_space,
        else => error.ProtocolMismatch,
    };
}

fn decodePhase(phase: protocol.Phase) RunError!Phase {
    return switch (phase) {
        .bootstrap => .bootstrap,
        .input => .input,
        .execute => .execute,
        .output => .output,
        .none => error.ProtocolMismatch,
    };
}

fn decodeArtifactReason(detail: protocol.Detail) RunError!ArtifactRejection.Reason {
    return switch (detail) {
        .invalid_artifact => .invalid_artifact,
        .checksum_mismatch => .checksum_mismatch,
        .unsupported_artifact_version => .unsupported_version,
        .artifact_limit_exceeded, .capsule_limit_exceeded => .limit_exceeded,
        .incompatible_rite_image => .incompatible_rite_image,
        .schema_mismatch => .schema_mismatch,
        .foreign_value => .foreign_value,
        .unsupported_value => .unsupported_value,
        .unsupported_container_state => .unsupported_container_state,
        .unsupported_hash_key => .unsupported_hash_key,
        .numeric_out_of_range => .numeric_out_of_range,
        .artifact_construction_failed => .construction_failed,
        else => error.ProtocolMismatch,
    };
}

fn isCpuLimitSignal(term: std.process.Child.Term) bool {
    return switch (term) {
        .signal => |signal| signal == .XCPU,
        else => false,
    };
}

fn isSuccessfulExit(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

test "public defaults stay fail-closed and bounded" {
    const request: Request = .{ .image = .{ .bytes = "x" } };
    try std.testing.expect(!request.policy.capabilities.eval);
    try std.testing.expect(request.process.wall_time_ns > 0);
    try std.testing.expect(request.process.cpu_seconds > 0);
    try std.testing.expectEqual(artifact_config.rite_compatibility_fingerprint.len, 32);
}

test "configured address-space exhaustion is a typed process limit" {
    var response: RawResponse = .{
        .header = .{
            .outcome = .limit,
            .phase = .execute,
            .detail = .address_space_exceeded,
        },
        .body = null,
    };
    var report = try decodeReport(
        std.testing.allocator,
        &response,
        null,
        .{},
        null,
    );
    defer report.deinit(std.testing.allocator);
    switch (report.outcome) {
        .limit => |kind| try std.testing.expectEqual(LimitKind.process_address_space, kind),
        else => return error.UnexpectedWorkerOutcome,
    }
}

test "response allocation cannot exceed the caller capsule ceiling" {
    const header: protocol.ResponseHeader = .{
        .outcome = .value,
        .value_len = 11,
    };
    try std.testing.expectError(
        error.BodyTooLarge,
        responseBodyLengthForAllocation(header, 10),
    );
    try std.testing.expectEqual(
        @as(usize, 11),
        try responseBodyLengthForAllocation(header, 11),
    );
}

test "pre-body address-space refusal tolerates a closed request pipe" {
    try std.testing.expect(responseMayPrecedeRequestBody(.{
        .outcome = .limit,
        .phase = .bootstrap,
        .detail = .address_space_exceeded,
    }));
    try std.testing.expect(!responseMayPrecedeRequestBody(.{
        .outcome = .limit,
        .phase = .execute,
        .detail = .address_space_exceeded,
    }));
}
