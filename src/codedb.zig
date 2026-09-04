//! CodeDB runtime surface: lookup over an embedded manifest of
//! build-compiled artifacts, executed through the normal policy path.
//!
//! The manifest module is generated at build time (tools/rite_envelope.zig
//! over host-mrbc output); import the generated module and pass it here.
//! See docs/artifacts.md for the build helper and metadata contract.

const std = @import("std");
const artifact_mod = @import("artifact.zig");
const sandbox_mod = @import("sandbox.zig");
const features = @import("features.zig");
const authority = @import("authority_manifest");
const gate = authority.CodeDB;

/// Sidecar schema version; independent of the typed artifact envelope format.
pub const manifest_format_major: u16 = 1;
pub const manifest_format_minor: u16 = 2;

pub const RunError = sandbox_mod.RunRiteError || error{UnknownArtifact};
pub const LoadError = RunError || std.mem.Allocator.Error || error{
    NotEntrypoint,
    CodeDBManifestMismatch,
    CodeDBPoisoned,
};

/// Resolve a logical name while retaining all of its manifest metadata.
/// Returned slices borrow the embedded manifest's storage. Generated manifests
/// must use a supported sidecar schema and match this build's RITE identity.
/// Hand-authored manifests containing only `entries` remain supported; their
/// bytes receive the same runtime admission checks as every other artifact.
pub fn lookup(manifest: anytype, name: []const u8) ?std.meta.Elem(@TypeOf(manifest.entries)) {
    comptime validateManifest(if (@TypeOf(manifest) == type) manifest else @TypeOf(manifest));
    for (manifest.entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

/// Resolve `name` in a generated manifest module (any type whose
/// `entries` is a comptime array of `{ name, bytes }` records).
pub fn find(manifest: anytype, name: []const u8) ?artifact_mod.RiteImageView {
    const entry = lookup(manifest, name) orelse return null;
    return .{ .bytes = entry.bytes };
}

/// Execute a manifest entry under the isolate's policy. Unknown names are
/// `error.UnknownArtifact`; admission failures follow `runRite`.
pub fn run(iso: sandbox_mod.Isolate, manifest: anytype, name: []const u8) RunError!sandbox_mod.Value {
    const view = find(manifest, name) orelse return error.UnknownArtifact;
    return iso.runRite(view);
}

/// Initialize a declared entrypoint and its dependencies once per isolate.
/// Returns true on first initialization, false when already loaded. Results
/// of Ruby initializers are discarded; retain definitions in Ruby globals or
/// constants. Every initializer in this call shares one execution budget.
/// The first load binds the isolate to this manifest. Initialization failure
/// poisons its loader permanently; recovery needs a fresh isolate.
pub fn load(iso: sandbox_mod.Isolate, comptime manifest: type, name: []const u8) LoadError!bool {
    comptime validateManifest(manifest);
    const Compiled = struct {
        // Distinct storage identifies this manifest instantiation even when
        // the optimizer merges otherwise identical constant descriptors.
        var identity: u8 = 0;
        const entries = compileGraph(manifest);
    };
    return iso.internal.loadCodeDB(&Compiled.identity, &Compiled.entries, name);
}

const GraphEntry = struct {
    name: []const u8,
    bytes: []const u8,
    entrypoint: bool,
    dependencies: []const usize,
};

/// Resolve the generated graph once at compile time. Topological order lets
/// the runtime walk a closure iteratively, without recursive Ruby/Zig calls.
/// Version 1.0 and bare manifests are independent entrypoints.
fn compileGraph(comptime manifest: type) [manifest.entries.len]GraphEntry {
    @setEvalBranchQuota(200_000);
    var result: [manifest.entries.len]GraphEntry = undefined;
    for (manifest.entries, 0..) |entry, index| {
        if (entry.name.len == 0 or std.mem.indexOfScalar(u8, entry.name, 0) != null)
            @compileError("CodeDB graph contains an invalid logical name");
        for (manifest.entries[0..index]) |previous| {
            if (std.mem.eql(u8, previous.name, entry.name))
                @compileError("CodeDB graph contains duplicate module: " ++ entry.name);
        }
        const has_dependencies = @hasField(@TypeOf(entry), "dependencies");
        const has_entrypoint = @hasField(@TypeOf(entry), "entrypoint");
        if (has_dependencies != has_entrypoint or
            (@hasDecl(manifest, "format_minor") and manifest.format_minor >= 1 and !has_dependencies))
            @compileError("CodeDB graph requires dependencies and entrypoint metadata");
        const names: []const []const u8 = if (has_dependencies) entry.dependencies else &.{};
        var indices: [names.len]usize = undefined;
        for (names, 0..) |dependency, di| {
            for (names[0..di]) |earlier| {
                if (std.mem.eql(u8, earlier, dependency))
                    @compileError("CodeDB graph repeats dependency " ++ dependency ++ " in " ++ entry.name);
            }
            indices[di] = for (manifest.entries[0..index], 0..) |candidate, ci| {
                if (std.mem.eql(u8, candidate.name, dependency)) break ci;
            } else @compileError("CodeDB dependency " ++ dependency ++ " must precede " ++ entry.name);
        }
        const resolved_indices = indices;
        result[index] = .{
            .name = entry.name,
            .bytes = entry.bytes,
            .entrypoint = if (has_entrypoint) entry.entrypoint else true,
            .dependencies = &resolved_indices,
        };
    }
    return result;
}

fn validateManifest(comptime Manifest: type) void {
    const generated = @hasDecl(Manifest, "format_major") or
        @hasDecl(Manifest, "format_minor") or @hasDecl(Manifest, "compatibility");
    if (!generated) return;
    if (!@hasDecl(Manifest, "format_major") or !@hasDecl(Manifest, "format_minor") or
        !@hasDecl(Manifest, "compatibility") or !@hasDecl(Manifest, "gem_set"))
    {
        @compileError("incomplete CodeDB manifest: schema version, compatibility, and gem_set are required");
    }
    if (Manifest.format_major != manifest_format_major or
        Manifest.format_minor > manifest_format_minor)
    {
        @compileError("unsupported CodeDB manifest schema version");
    }
    if (!std.mem.eql(u8, &Manifest.compatibility, &features.rite_compatibility_fingerprint)) {
        @compileError("CodeDB manifest compiled for " ++ Manifest.gem_set ++ "@" ++
            std.fmt.bytesToHex(Manifest.compatibility, .lower) ++ ", consuming " ++
            features.gem_set ++ "@" ++ features.rite_compatibility_fingerprint_hex);
    }
    if (Manifest.format_minor >= 2) validateAuthority(Manifest);
}

/// Recompute the build gate against the consuming profile. Authority table
/// changes need not alter bytecode compatibility, so the fingerprint alone
/// cannot detect stale classifications. Legacy sidecars predate this contract.
fn validateAuthority(comptime Manifest: type) void {
    @setEvalBranchQuota(200_000);
    for (.{ "authority_tier", "authority_allowed", "authority_profile", "host_bindings" }) |field| {
        if (!@hasDecl(Manifest, field))
            @compileError("incomplete CodeDB authority metadata: " ++ field);
    }
    if (Manifest.authority_profile.len != features.authority.sources.len)
        @compileError("CodeDB authority profile does not match consuming build");
    for (Manifest.authority_profile, features.authority.sources) |recorded, actual| {
        if (!std.mem.eql(u8, recorded.name, actual.name) or recorded.bits != actual.authority.toBits())
            @compileError("CodeDB authority profile does not match consuming build: " ++ actual.name);
    }
    const tier: gate.Tier = if (std.mem.eql(u8, Manifest.authority_tier, "worker"))
        .worker
    else if (std.mem.eql(u8, Manifest.authority_tier, "trusted"))
        .trusted
    else if (std.mem.eql(u8, Manifest.authority_tier, "custom"))
        .{ .custom = authority.Set.fromBits(Manifest.authority_allowed) }
    else
        @compileError("unknown CodeDB authority tier: " ++ Manifest.authority_tier);
    if (gate.allowed(tier).toBits() != Manifest.authority_allowed)
        @compileError("CodeDB authority tier mask does not match its named tier");

    var hosts: [Manifest.host_bindings.len]gate.HostBinding = undefined;
    for (Manifest.host_bindings, &hosts) |recorded, *host|
        host.* = .{ .name = recorded.name, .authority = authority.Set.fromBits(recorded.bits) };
    var artifacts: [Manifest.entries.len]gate.Artifact = undefined;
    for (Manifest.entries, &artifacts) |entry, *item| {
        for (.{ "dependencies", "entrypoint", "required_authority", "host_bindings", "effective_authority" }) |field| {
            if (!@hasField(@TypeOf(entry), field))
                @compileError("incomplete CodeDB authority entry: " ++ field);
        }
        item.* = .{
            .name = entry.name,
            .dependencies = entry.dependencies,
            .required_authority = authority.Set.fromBits(entry.required_authority),
            .host_bindings = entry.host_bindings,
        };
    }
    var effective: [Manifest.entries.len]authority.Set = undefined;
    var failure: gate.Failure = .{};
    gate.validate(tier, features.authority.sources, &hosts, &artifacts, &effective, &failure) catch |err| {
        @compileError(std.fmt.comptimePrint(
            "CodeDB authority gate rejected manifest: {s}: {s}: {s} {s}, bits 0x{x}",
            .{ @errorName(err), failure.artifact orelse "", @tagName(failure.origin), failure.source, failure.bits.toBits() },
        ));
    };
    for (Manifest.entries, effective) |entry, expected| {
        if (entry.effective_authority != expected.toBits())
            @compileError("CodeDB effective authority does not match declaration: " ++ entry.name);
    }
}
