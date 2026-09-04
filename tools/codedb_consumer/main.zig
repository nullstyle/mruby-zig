//! Exercises the public dependency build helper from an actual consumer.
const std = @import("std");
const mruby = @import("mruby");
const generated = @import("codedb_manifest");
const options = @import("consumer_options");

// Preserve a generated manifest's identity except for one deliberate change.
// Each invalid choice must fail compilation in CodeDB's manifest admission.
const manifest = if (options.mismatch == .none) generated else struct {
    pub const format_major = generated.format_major + @intFromBool(options.mismatch == .schema);
    pub const format_minor = generated.format_minor;
    pub const compatibility = blk: {
        var digest = generated.compatibility;
        if (options.mismatch == .compatibility) digest[0] ^= 1;
        break :blk digest;
    };
    pub const gem_set = generated.gem_set;
    pub const authority_tier = generated.authority_tier;
    pub const authority_allowed = generated.authority_allowed ^ @as(u16, @intFromBool(options.mismatch == .authority_tier));
    pub const authority_profile = blk: {
        var sources: [generated.authority_profile.len]generated.AuthoritySource = undefined;
        @memcpy(&sources, generated.authority_profile);
        if (options.mismatch == .authority_profile) sources[0].bits ^= 1;
        const result = sources;
        break :blk &result;
    };
    pub const host_bindings = generated.host_bindings;
    pub const entries = blk: {
        var result = generated.entries;
        if (options.mismatch == .authority_effective) result[0].effective_authority ^= 1;
        break :blk result;
    };
};

pub fn main() !void {
    try std.testing.expectEqual(!options.no_compiler, mruby.features.has_compiler);
    try std.testing.expectEqual(!options.no_compiler, mruby.features.authority.find("mruby-compiler") != null);
    if (options.no_compiler) {
        try std.testing.expect(!mruby.features.hasGem("mruby-eval"));
        try std.testing.expect(mruby.features.has_debug_hook);
    }
    var boot = try mruby.sandbox.BootstrapIsolate.spawn(mruby.sandbox.Policy.restricted(.{
        .limits = .{ .gas = .{ .per_execution = 1_000 } },
    }));
    defer boot.deinit();
    // Restricted policy freezes Object. Reserve the application's namespace
    // before sealing; its methods are still initialized by the Ruby library.
    _ = try boot.vm().defineModule("Billing");
    const isolate = try boot.seal();
    defer isolate.deinit();

    const name = "billing/\"weekly\"";
    const library_name = "libraries/\"shared\"";
    try std.testing.expectError(error.NotEntrypoint, isolate.loadArtifact(manifest, library_name));
    const loaded = isolate.loadArtifact(manifest, name) catch |err| {
        if (isolate.lastError()) |ruby_error| {
            const message = try ruby_error.message(std.heap.page_allocator);
            defer std.heap.page_allocator.free(message);
            std.debug.print("CodeDB consumer initialization: {s}\n", .{message});
        }
        return err;
    };
    try std.testing.expect(loaded);
    try std.testing.expect(!try isolate.loadArtifact(manifest, name));

    // Loading retains shared Ruby declarations and initializes each module
    // once. Direct execution keeps its return value and runs on every call.
    try expectBillingResult(isolate, name, 1, 2);
    try expectBillingResult(isolate, name, 1, 3);
    // Direct execution is independent of both entrypoint status and the
    // loader's remembered state, even for a previously loaded library.
    _ = try isolate.runArtifact(manifest, library_name);
    try std.testing.expect(!try isolate.loadArtifact(manifest, name));
    try expectBillingResult(isolate, name, 2, 4);

    const entry = mruby.codedb.lookup(manifest, name).?;
    const library = mruby.codedb.lookup(manifest, library_name).?;
    try std.testing.expectEqualStrings(name, entry.name);
    try std.testing.expectEqualStrings("jobs/billing job.rb", entry.source_name);
    try std.testing.expect(entry.entrypoint);
    try std.testing.expectEqual(@as(usize, 1), entry.dependencies.len);
    try std.testing.expectEqualStrings(library_name, entry.dependencies[0]);
    try std.testing.expect(!library.entrypoint);
    try std.testing.expectEqualStrings("support/shared library.rb", library.source_name);
    try std.testing.expectEqual(@as(usize, 0), library.dependencies.len);
    try std.testing.expectEqual(@as(usize, 2), manifest.entries.len);
    try std.testing.expectEqualStrings(library_name, manifest.entries[0].name);
    try std.testing.expectEqualStrings(name, manifest.entries[1].name);
    try std.testing.expect(mruby.codedb.lookup(manifest, "missing") == null);
    try std.testing.expectEqualStrings(mruby.features.gem_set, generated.gem_set);
    try std.testing.expectEqualSlices(u8, &mruby.features.rite_compatibility_fingerprint, &generated.compatibility);
    try expectAuthority(entry, library);

    var source_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(@embedFile("billing.rb"), &source_hash, .{});
    try std.testing.expectEqualSlices(u8, &source_hash, &entry.source_hash);
    var artifact_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(entry.bytes, &artifact_hash, .{});
    try std.testing.expectEqualSlices(u8, &artifact_hash, &entry.artifact_hash);
    std.crypto.hash.sha2.Sha256.hash(@embedFile("lib.rb"), &source_hash, .{});
    try std.testing.expectEqualSlices(u8, &source_hash, &library.source_hash);
    std.crypto.hash.sha2.Sha256.hash(library.bytes, &artifact_hash, .{});
    try std.testing.expectEqualSlices(u8, &artifact_hash, &library.artifact_hash);
}

fn expectAuthority(entry: generated.Entry, library: generated.Entry) !void {
    const AuthoritySet = mruby.features.AuthoritySet;
    const clock = AuthoritySet.init(&.{.clock}).toBits();
    const entropy = AuthoritySet.init(&.{.entropy}).toBits();
    const filesystem = AuthoritySet.init(&.{.filesystem}).toBits();
    const trusted = options.authority_case == .trusted_host;
    const expected_tier = if (trusted) "trusted" else if (options.authority_case == .custom_worker) "custom" else "worker";
    try std.testing.expectEqualStrings(expected_tier, generated.authority_tier);
    const expected_allowed = if (trusted)
        AuthoritySet.init(std.enums.values(mruby.features.AuthorityKind)).toBits()
    else
        AuthoritySet.init(&.{
            .clock,            .entropy,        .dynamic_code,  .dynamic_dispatch, .introspection,
            .heap_enumeration, .model_mutation, .continuations, .host_output,
        }).toBits();
    try std.testing.expectEqual(expected_allowed, generated.authority_allowed);
    try std.testing.expectEqual(mruby.features.authority.sources.len, generated.authority_profile.len);
    for (generated.authority_profile, mruby.features.authority.sources) |source, actual| {
        try std.testing.expectEqualStrings(actual.name, source.name);
        try std.testing.expectEqual(actual.authority.toBits(), source.bits);
    }
    try std.testing.expectEqual(@as(usize, if (trusted) 3 else 2), generated.host_bindings.len);
    try std.testing.expectEqualStrings("host/\"clock\"", generated.host_bindings[0].name);
    try std.testing.expectEqual(clock, generated.host_bindings[0].bits);
    try std.testing.expectEqualStrings("host/arithmetic", generated.host_bindings[1].name);
    try std.testing.expectEqual(@as(u16, 0), generated.host_bindings[1].bits);
    if (trusted) {
        try std.testing.expectEqualStrings("host/filesystem", generated.host_bindings[2].name);
        try std.testing.expectEqual(filesystem, generated.host_bindings[2].bits);
    }
    try std.testing.expectEqual(@as(u16, 0), entry.required_authority);
    try std.testing.expectEqual(entropy, library.required_authority);
    try std.testing.expectEqual(@as(usize, 2), entry.host_bindings.len);
    try std.testing.expectEqualStrings("host/\"clock\"", entry.host_bindings[0]);
    try std.testing.expectEqualStrings("host/arithmetic", entry.host_bindings[1]);
    try std.testing.expectEqual(@as(usize, 0), library.host_bindings.len);
    const effective = mruby.features.authority.aggregate.toBits() | clock | entropy |
        @as(u16, if (trusted) filesystem else 0);
    try std.testing.expectEqual(effective, library.effective_authority);
    // The library's additional requirement reaches its dependent entrypoint.
    try std.testing.expectEqual(effective, entry.effective_authority);
}

fn expectBillingResult(isolate: mruby.sandbox.Isolate, name: []const u8, library_loads: i64, entry_runs: i64) !void {
    const result = try (try isolate.runArtifact(manifest, name)).asArray();
    try std.testing.expectEqual(@as(i64, 42), try (try result.get(0)).asInt());
    try std.testing.expectEqualStrings("jobs/billing job.rb", try (try result.get(1)).asString());
    try std.testing.expectEqual(library_loads, try (try result.get(2)).asInt());
    try std.testing.expectEqual(entry_runs, try (try result.get(3)).asInt());
    try std.testing.expectEqualStrings("support/shared library.rb", try (try result.get(4)).asString());
}
