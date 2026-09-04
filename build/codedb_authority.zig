//! Conservative admission for build-managed Ruby. Declarations can add
//! authority; they cannot hide authority linked into the VM or host catalogue.
const std = @import("std");
const authority = @import("authority.zig");

pub const AuthoritySet = authority.Set;
pub const AuthorityKind = authority.Kind;
pub const HostBinding = authority.Source;
const Set = AuthoritySet;

pub const known = Set.init(std.enums.values(AuthorityKind));

pub const Tier = union(enum) {
    worker,
    trusted,
    custom: Set,
};

pub fn allowed(tier: Tier) Set {
    return switch (tier) {
        .worker => authority.worker_allowed,
        .trusted => known,
        .custom => |set| set,
    };
}

pub const Artifact = struct {
    name: []const u8,
    dependencies: []const []const u8 = &.{},
    required_authority: Set = .empty,
    host_bindings: []const []const u8 = &.{},
};

pub const GateError = error{
    EmptyCodeDB,
    InvalidEffectiveAuthorityBuffer,
    InvalidAuthorityName,
    DuplicateAuthorityName,
    UnknownAuthority,
    ForbiddenAuthority,
    MissingHostBinding,
    DuplicateHostBindingReference,
    MissingArtifactDependency,
    UnorderedArtifactDependency,
    DuplicateArtifactDependency,
};

pub const Origin = enum { profile, host, artifact, tier };

pub const Reason = enum {
    none,
    empty,
    invalid_buffer,
    invalid_name,
    duplicate_name,
    unknown_authority,
    forbidden_authority,
    missing_host,
    duplicate_host_reference,
    missing_dependency,
    unordered_dependency,
    duplicate_dependency,
};

/// Strings borrow the declarations passed to `validate`.
pub const Failure = struct {
    reason: Reason = .none,
    artifact: ?[]const u8 = null,
    origin: Origin = .tier,
    source: []const u8 = "",
    bits: Set = .empty,

    pub fn report(self: Failure) void {
        if (self.reason == .none) return;
        std.debug.print("CodeDB: ", .{});
        if (self.artifact) |name| std.debug.print("{s}: ", .{name});
        switch (self.reason) {
            .none => unreachable,
            .empty => std.debug.print("at least one module is required", .{}),
            .invalid_buffer => std.debug.print("effective authority buffer does not match module count", .{}),
            .invalid_name => std.debug.print("invalid {s} name: {s}", .{ @tagName(self.origin), self.source }),
            .duplicate_name => std.debug.print("duplicate {s} name: {s}", .{ @tagName(self.origin), self.source }),
            .unknown_authority, .forbidden_authority => {
                std.debug.print("{s} {s} has {s} authority:", .{
                    @tagName(self.origin),                                             self.source,
                    if (self.reason == .unknown_authority) "unknown" else "forbidden",
                });
                inline for (std.enums.values(AuthorityKind)) |kind| {
                    if (self.bits.has(kind)) std.debug.print(" {s}", .{@tagName(kind)});
                }
                const unknown = self.bits.toBits() & ~known.toBits();
                if (unknown != 0) std.debug.print(" unknown bits 0x{x}", .{unknown});
            },
            .missing_host => std.debug.print("unknown host binding: {s}", .{self.source}),
            .duplicate_host_reference => std.debug.print("duplicate host binding reference: {s}", .{self.source}),
            .missing_dependency => std.debug.print("unknown dependency: {s}", .{self.source}),
            .unordered_dependency => std.debug.print("dependency must precede module: {s}", .{self.source}),
            .duplicate_dependency => std.debug.print("duplicate dependency: {s}", .{self.source}),
        }
        std.debug.print("\n", .{});
    }
};

/// Requires dependencies before dependents. Writes one effective set per
/// artifact without allocating. Output is valid only after successful return.
/// Every artifact includes the entire linked profile and host catalogue, even
/// when neither its Ruby source nor its declared host references use them.
pub fn validate(
    tier: Tier,
    profile: []const authority.Source,
    hosts: []const HostBinding,
    artifacts: []const Artifact,
    effective: []Set,
    failure: *Failure,
) GateError!void {
    failure.* = .{};
    if (artifacts.len == 0) return fail(failure, .{ .reason = .empty });
    if (effective.len != artifacts.len) return fail(failure, .{ .reason = .invalid_buffer });
    const first = artifacts[0].name;
    try checkKnown(allowed(tier), .{ .origin = .tier, .source = @tagName(tier) }, failure);
    try validateSources(profile, .profile, first, failure);
    try validateSources(hosts, .host, first, failure);
    for (artifacts, 0..) |artifact, i| {
        const context: Failure = .{ .artifact = artifact.name, .origin = .artifact, .source = artifact.name };
        if (!validName(artifact.name)) return failReason(failure, context, .invalid_name);
        for (artifacts[0..i]) |previous| {
            if (std.mem.eql(u8, artifact.name, previous.name))
                return failReason(failure, context, .duplicate_name);
        }
        try checkKnown(artifact.required_authority, context, failure);
        for (artifact.host_bindings, 0..) |name, j| {
            const host_context: Failure = .{ .artifact = artifact.name, .origin = .host, .source = name };
            for (artifact.host_bindings[0..j]) |previous| {
                if (std.mem.eql(u8, name, previous))
                    return failReason(failure, host_context, .duplicate_host_reference);
            }
            if (findSource(hosts, name) == null)
                return failReason(failure, host_context, .missing_host);
        }
        for (artifact.dependencies, 0..) |name, j| {
            const dependency_context: Failure = .{ .artifact = artifact.name, .origin = .artifact, .source = name };
            for (artifact.dependencies[0..j]) |previous| {
                if (std.mem.eql(u8, name, previous))
                    return failReason(failure, dependency_context, .duplicate_dependency);
            }
            const dependency = findArtifact(artifacts, name) orelse
                return failReason(failure, dependency_context, .missing_dependency);
            if (dependency >= i)
                return failReason(failure, dependency_context, .unordered_dependency);
        }
    }

    const permitted = allowed(tier);
    var ambient: Set = .empty;
    for (profile) |source| {
        try checkAllowed(source.authority, permitted, .{ .artifact = first, .origin = .profile, .source = source.name }, failure);
        ambient = ambient.unionWith(source.authority);
    }
    for (hosts) |host| {
        try checkAllowed(host.authority, permitted, .{ .artifact = first, .origin = .host, .source = host.name }, failure);
        ambient = ambient.unionWith(host.authority);
    }
    for (artifacts, effective) |artifact, *result| {
        try checkAllowed(artifact.required_authority, permitted, .{
            .artifact = artifact.name,
            .origin = .artifact,
            .source = artifact.name,
        }, failure);
        result.* = ambient.unionWith(artifact.required_authority);
        for (artifact.dependencies) |name|
            result.* = result.unionWith(effective[findArtifact(artifacts, name).?]);
    }
}

fn validateSources(sources: []const authority.Source, origin: Origin, artifact: []const u8, failure: *Failure) GateError!void {
    for (sources, 0..) |source, i| {
        const context: Failure = .{ .artifact = artifact, .origin = origin, .source = source.name };
        if (!validName(source.name)) return failReason(failure, context, .invalid_name);
        for (sources[0..i]) |previous| {
            if (std.mem.eql(u8, source.name, previous.name))
                return failReason(failure, context, .duplicate_name);
        }
        try checkKnown(source.authority, context, failure);
    }
}

fn validName(name: []const u8) bool {
    return name.len != 0 and std.mem.indexOfScalar(u8, name, 0) == null;
}

fn findSource(sources: []const authority.Source, name: []const u8) ?usize {
    for (sources, 0..) |source, i| {
        if (std.mem.eql(u8, source.name, name)) return i;
    }
    return null;
}

fn findArtifact(artifacts: []const Artifact, name: []const u8) ?usize {
    for (artifacts, 0..) |artifact, i| {
        if (std.mem.eql(u8, artifact.name, name)) return i;
    }
    return null;
}

fn checkKnown(set: Set, context: Failure, failure: *Failure) GateError!void {
    const unknown = set.toBits() & ~known.toBits();
    if (unknown != 0) {
        var result = context;
        result.reason = .unknown_authority;
        result.bits = Set.fromBits(unknown);
        return fail(failure, result);
    }
}

fn checkAllowed(set: Set, permitted: Set, context: Failure, failure: *Failure) GateError!void {
    const forbidden = set.toBits() & ~permitted.toBits();
    if (forbidden != 0) {
        var result = context;
        result.reason = .forbidden_authority;
        result.bits = Set.fromBits(forbidden);
        return fail(failure, result);
    }
}

fn failReason(destination: *Failure, context: Failure, reason: Reason) GateError {
    var failure = context;
    failure.reason = reason;
    return fail(destination, failure);
}

fn fail(destination: *Failure, failure: Failure) GateError {
    destination.* = failure;
    return switch (failure.reason) {
        .none => unreachable,
        .empty => error.EmptyCodeDB,
        .invalid_buffer => error.InvalidEffectiveAuthorityBuffer,
        .invalid_name => error.InvalidAuthorityName,
        .duplicate_name => error.DuplicateAuthorityName,
        .unknown_authority => error.UnknownAuthority,
        .forbidden_authority => error.ForbiddenAuthority,
        .missing_host => error.MissingHostBinding,
        .duplicate_host_reference => error.DuplicateHostBindingReference,
        .missing_dependency => error.MissingArtifactDependency,
        .unordered_dependency => error.UnorderedArtifactDependency,
        .duplicate_dependency => error.DuplicateArtifactDependency,
    };
}

test "unused profile and host authority cannot be subtracted by declarations" {
    const artifacts = &[_]Artifact{.{ .name = "entry" }};
    const filesystem = Set.init(&.{.filesystem});
    const dangerous = &[_]HostBinding{.{ .name = "unused-files", .authority = filesystem }};
    var effective: [1]Set = undefined;
    var failure: Failure = .{};
    try std.testing.expectError(error.ForbiddenAuthority, validate(.worker, dangerous, &.{}, artifacts, &effective, &failure));
    try std.testing.expectEqual(Origin.profile, failure.origin);
    try std.testing.expectEqualStrings("entry", failure.artifact.?);
    try std.testing.expectEqualStrings("unused-files", failure.source);
    try std.testing.expectEqual(filesystem, failure.bits);
    try std.testing.expectError(error.ForbiddenAuthority, validate(.worker, &.{}, dangerous, artifacts, &effective, &failure));
    try std.testing.expectEqual(Origin.host, failure.origin);
    try validate(.trusted, dangerous, dangerous, artifacts, &effective, &failure);
    try std.testing.expectEqual(filesystem, effective[0]);
    try std.testing.expectEqual(Reason.none, failure.reason);
    try validate(.{ .custom = filesystem }, dangerous, dangerous, artifacts, &effective, &failure);
    try std.testing.expectError(error.ForbiddenAuthority, validate(.{ .custom = .empty }, dangerous, &.{}, artifacts, &effective, &failure));
}

test "trusted still rejects unknown authority in every declaration" {
    const unknown = Set.fromBits(@as(u16, 1) << 15);
    const bad = &[_]HostBinding{.{ .name = "future", .authority = unknown }};
    const artifacts = &[_]Artifact{.{ .name = "entry" }};
    var effective: [1]Set = undefined;
    var failure: Failure = .{};
    try std.testing.expectError(error.UnknownAuthority, validate(.trusted, bad, &.{}, artifacts, &effective, &failure));
    try std.testing.expectEqual(Origin.profile, failure.origin);
    try std.testing.expectError(error.UnknownAuthority, validate(.trusted, &.{}, bad, artifacts, &effective, &failure));
    try std.testing.expectEqual(Origin.host, failure.origin);
    try std.testing.expectError(error.UnknownAuthority, validate(.trusted, &.{}, &.{}, &.{.{ .name = "future", .required_authority = unknown }}, &effective, &failure));
    try std.testing.expectEqual(Origin.artifact, failure.origin);
    try std.testing.expectError(error.UnknownAuthority, validate(.{ .custom = unknown }, &.{}, &.{}, artifacts, &effective, &failure));
    try std.testing.expectEqual(Origin.tier, failure.origin);
    try std.testing.expectEqual(unknown, failure.bits);
}

test "effective authority includes diamond dependencies without unrelated requirements" {
    const profile = &[_]authority.Source{.{ .name = "core", .authority = Set.init(&.{.dynamic_dispatch}) }};
    const hosts = &[_]HostBinding{.{ .name = "unused-clock", .authority = Set.init(&.{.clock}) }};
    const artifacts = &[_]Artifact{
        .{ .name = "base", .required_authority = Set.init(&.{.entropy}) },
        .{ .name = "left", .dependencies = &.{"base"}, .required_authority = Set.init(&.{.dynamic_code}) },
        .{ .name = "right", .dependencies = &.{"base"}, .required_authority = Set.init(&.{.introspection}) },
        .{ .name = "entry", .dependencies = &.{ "left", "right" }, .host_bindings = &.{"unused-clock"} },
        .{ .name = "other", .required_authority = Set.init(&.{.host_output}) },
    };
    var effective: [5]Set = undefined;
    var failure: Failure = .{};
    try validate(.worker, profile, hosts, artifacts, &effective, &failure);
    try std.testing.expectEqual(Set.init(&.{ .dynamic_dispatch, .clock, .entropy }), effective[0]);
    try std.testing.expectEqual(Set.init(&.{ .dynamic_dispatch, .clock, .entropy, .dynamic_code, .introspection }), effective[3]);
    try std.testing.expectEqual(Set.init(&.{ .dynamic_dispatch, .clock, .host_output }), effective[4]);
}

test "host references must exist and cannot repeat" {
    const hosts = &[_]HostBinding{.{ .name = "clock", .authority = Set.init(&.{.clock}) }};
    var effective: [1]Set = undefined;
    var failure: Failure = .{};
    try std.testing.expectError(error.MissingHostBinding, validate(.trusted, &.{}, hosts, &.{.{ .name = "entry", .host_bindings = &.{"missing"} }}, &effective, &failure));
    try std.testing.expectEqualStrings("entry", failure.artifact.?);
    try std.testing.expectEqualStrings("missing", failure.source);
    try std.testing.expectError(error.DuplicateHostBindingReference, validate(.trusted, &.{}, hosts, &.{.{ .name = "entry", .host_bindings = &.{ "clock", "clock" } }}, &effective, &failure));
}

test "profile host and artifact names must be valid and unique within their catalogue" {
    const artifacts = &[_]Artifact{.{ .name = "entry" }};
    const duplicate = &[_]HostBinding{
        .{ .name = "same", .authority = .empty },
        .{ .name = "same", .authority = .empty },
    };
    var effective: [2]Set = undefined;
    var failure: Failure = .{};
    try std.testing.expectError(error.DuplicateAuthorityName, validate(.trusted, duplicate, &.{}, artifacts, effective[0..1], &failure));
    try std.testing.expectEqual(Origin.profile, failure.origin);
    try std.testing.expectError(error.DuplicateAuthorityName, validate(.trusted, &.{}, duplicate, artifacts, effective[0..1], &failure));
    try std.testing.expectEqual(Origin.host, failure.origin);
    try std.testing.expectError(error.DuplicateAuthorityName, validate(.trusted, &.{}, &.{}, &.{ .{ .name = "entry" }, .{ .name = "entry" } }, &effective, &failure));
    try std.testing.expectEqual(Origin.artifact, failure.origin);
    for ([_][]const u8{ "", "nul\x00name" }) |name| {
        const invalid = &[_]HostBinding{.{ .name = name, .authority = .empty }};
        try std.testing.expectError(error.InvalidAuthorityName, validate(.trusted, invalid, &.{}, artifacts, effective[0..1], &failure));
        try std.testing.expectError(error.InvalidAuthorityName, validate(.trusted, &.{}, invalid, artifacts, effective[0..1], &failure));
        try std.testing.expectError(error.InvalidAuthorityName, validate(.trusted, &.{}, &.{}, &.{.{ .name = name }}, effective[0..1], &failure));
    }
}

test "gate rejects malformed graph metadata and output size" {
    var effective: [2]Set = undefined;
    var failure: Failure = .{};
    try std.testing.expectError(error.EmptyCodeDB, validate(.trusted, &.{}, &.{}, &.{}, &.{}, &failure));
    try std.testing.expectError(error.InvalidEffectiveAuthorityBuffer, validate(.trusted, &.{}, &.{}, &.{.{ .name = "entry" }}, &effective, &failure));
    try std.testing.expectError(error.MissingArtifactDependency, validate(.trusted, &.{}, &.{}, &.{.{ .name = "entry", .dependencies = &.{"missing"} }}, effective[0..1], &failure));
    try std.testing.expectError(error.UnorderedArtifactDependency, validate(.trusted, &.{}, &.{}, &.{
        .{ .name = "entry", .dependencies = &.{"later"} }, .{ .name = "later" },
    }, &effective, &failure));
    try std.testing.expectError(error.UnorderedArtifactDependency, validate(.trusted, &.{}, &.{}, &.{.{ .name = "entry", .dependencies = &.{"entry"} }}, effective[0..1], &failure));
    try std.testing.expectError(error.DuplicateArtifactDependency, validate(.trusted, &.{}, &.{}, &.{
        .{ .name = "base" }, .{ .name = "entry", .dependencies = &.{ "base", "base" } },
    }, &effective, &failure));
}

test "artifact requirements distinguish tiers and identify their origin" {
    const required = Set.init(&.{ .network, .clock });
    const artifacts = &[_]Artifact{.{ .name = "fetch", .required_authority = required }};
    var effective: [1]Set = undefined;
    var failure: Failure = .{};
    try std.testing.expectError(error.ForbiddenAuthority, validate(.worker, &.{}, &.{}, artifacts, &effective, &failure));
    try std.testing.expectEqual(Origin.artifact, failure.origin);
    try std.testing.expectEqualStrings("fetch", failure.artifact.?);
    try std.testing.expectEqual(Set.init(&.{.network}), failure.bits);
    try validate(.trusted, &.{}, &.{}, artifacts, &effective, &failure);
    try std.testing.expectEqual(required, effective[0]);
    try validate(.{ .custom = required }, &.{}, &.{}, artifacts, &effective, &failure);
    try std.testing.expectError(error.ForbiddenAuthority, validate(.{ .custom = Set.init(&.{.network}) }, &.{}, &.{}, artifacts, &effective, &failure));
    try std.testing.expectEqual(Set.init(&.{.clock}), failure.bits);
}
