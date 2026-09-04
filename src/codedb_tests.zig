//! Integration coverage over real host-mrbc output and generated sidecars.

const std = @import("std");
const mruby = @import("mruby");
const manifest = @import("codedb_manifest");
const app_manifest = @import("codedb_app_manifest");
const graph_manifest = @import("codedb_graph_manifest");
const other_graph_manifest = @import("codedb_graph_other_manifest");
const sandbox = mruby.sandbox;
const codedb = mruby.codedb;
const artifact = mruby.artifact;
const application: artifact.ApplicationFingerprint = .{ .bytes = @splat(0x42) };

const BareEntry = struct { name: []const u8, bytes: []const u8 };

fn spawnSealed(policy: sandbox.Policy) !sandbox.Isolate {
    var boot = try sandbox.BootstrapIsolate.spawn(policy);
    defer boot.deinit();
    return boot.seal();
}

fn expectNoExecution(before: sandbox.Stats, after: sandbox.Stats) !void {
    try std.testing.expectEqual(before.instructions, after.instructions);
    try std.testing.expectEqual(before.wall_time_ns, after.wall_time_ns);
    try std.testing.expectEqual(before.gas.?.generation, after.gas.?.generation);
    try std.testing.expectEqual(before.gas.?.used, after.gas.?.used);
}

test "CodeDB: generated entries retain source, content, and build identity" {
    try std.testing.expectEqual(codedb.manifest_format_major, manifest.format_major);
    try std.testing.expectEqual(codedb.manifest_format_minor, manifest.format_minor);
    try std.testing.expectEqualSlices(u8, &mruby.features.rite_compatibility_fingerprint, &manifest.compatibility);
    try std.testing.expectEqualStrings(mruby.features.gem_set, manifest.gem_set);
    try std.testing.expectEqual(mruby.features.gems.len, manifest.gems.len);
    for (mruby.features.gems, manifest.gems) |expected, actual| {
        try std.testing.expectEqualStrings(expected, actual);
    }
    inline for (manifest.entries) |entry| {
        const source = @embedFile("tests_codedb/" ++ entry.name ++ ".rb");
        var source_hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(source, &source_hash, .{});
        try std.testing.expectEqualSlices(u8, &source_hash, &entry.source_hash);
        var artifact_hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(entry.bytes, &artifact_hash, .{});
        try std.testing.expectEqualSlices(u8, &artifact_hash, &entry.artifact_hash);
        try std.testing.expect(entry.application == null);
        const decoded = try artifact.validateRite(.{ .bytes = entry.bytes }, .{
            .compatibility = manifest.compatibility,
        });
        try std.testing.expect(decoded.application == null);
        const found = codedb.lookup(manifest, entry.name).?;
        try std.testing.expectEqualStrings(entry.source_name, found.source_name);
        try std.testing.expectEqualSlices(u8, entry.bytes, codedb.find(manifest, entry.name).?.bytes);
    }
    const app_entry = codedb.lookup(app_manifest, "answer").?;
    try std.testing.expectEqualSlices(u8, &application.bytes, &app_entry.application.?);
}

test "CodeDB: loader and compatibility wrapper execute generated artifacts" {
    const iso = try spawnSealed(sandbox.Policy.restricted(.{
        .limits = .{ .gas = .{ .per_execution = 10_000 } },
    }));
    defer iso.deinit();
    try std.testing.expectEqual(@as(i64, 42), try (try iso.runArtifact(manifest, "answer")).asInt());
    try std.testing.expectEqual(@as(i64, 42), try (try codedb.run(iso, manifest, "answer")).asInt());
    try std.testing.expectEqual(@as(u64, 2), iso.stats().gas.?.generation);
}

test "CodeDB: authority sidecars preserve the complete configured profile" {
    try std.testing.expectEqualStrings("trusted", manifest.authority_tier);
    try std.testing.expectEqual(mruby.features.authority.sources.len, manifest.authority_profile.len);
    for (mruby.features.authority.sources, manifest.authority_profile) |expected, actual| {
        try std.testing.expectEqualStrings(expected.name, actual.name);
        try std.testing.expectEqual(expected.authority.toBits(), actual.bits);
    }
    try std.testing.expectEqual(@as(usize, 0), manifest.host_bindings.len);
    for (manifest.entries) |entry| {
        try std.testing.expectEqual(@as(u16, 0), entry.required_authority);
        try std.testing.expectEqual(@as(usize, 0), entry.host_bindings.len);
        try std.testing.expectEqual(mruby.features.authority.aggregate.toBits(), entry.effective_authority);
        try std.testing.expectEqual(@as(u16, 0), entry.effective_authority & ~manifest.authority_allowed);
    }
    try std.testing.expectEqual(@as(usize, 1), graph_manifest.host_bindings.len);
    try std.testing.expectEqualStrings("CodeDBGate.call", graph_manifest.host_bindings[0].name);
    const entry = codedb.lookup(graph_manifest, "gate").?;
    try std.testing.expectEqualStrings("CodeDBGate.call", entry.host_bindings[0]);
}

test "CodeDB: source identity agrees with __FILE__ and exception locations" {
    const iso = try spawnSealed(sandbox.Policy.trusted(.{}));
    defer iso.deinit();
    const file = try iso.runArtifact(manifest, "source");
    try std.testing.expectEqualStrings(codedb.lookup(manifest, "source").?.source_name, try file.asString());
    const trace = try iso.runArtifact(manifest, "trace");
    const expected = try std.fmt.allocPrint(std.testing.allocator, "{s}:2", .{
        codedb.lookup(manifest, "trace").?.source_name,
    });
    defer std.testing.allocator.free(expected);
    try std.testing.expect(std.mem.indexOf(u8, try trace.asString(), expected) != null);
}

test "CodeDB: missing names preserve execution state and prior errors" {
    const iso = try spawnSealed(.{ .limits = .{ .gas = .{ .per_execution = 10_000 } } });
    defer iso.deinit();
    try std.testing.expectError(error.RubyException, iso.run("raise 'CodeDB sentinel'"));
    const before = iso.stats();
    try std.testing.expect(codedb.lookup(manifest, "missing") == null);
    try std.testing.expect(codedb.find(manifest, "missing") == null);
    try std.testing.expectError(error.UnknownArtifact, iso.runArtifact(manifest, "missing"));
    try expectNoExecution(before, iso.stats());
    const message = try iso.lastError().?.message(std.testing.allocator);
    defer std.testing.allocator.free(message);
    try std.testing.expectEqualStrings("CodeDB sentinel", message);
}

test "CodeDB: modified envelope is rejected without beginning execution" {
    const original = codedb.find(manifest, "answer").?;
    const bytes = try std.testing.allocator.dupe(u8, original.bytes);
    defer std.testing.allocator.free(bytes);
    bytes[bytes.len - 1] ^= 1;
    const corrupted = .{ .entries = [_]BareEntry{.{ .name = "answer", .bytes = bytes }} };
    const iso = try spawnSealed(.{ .limits = .{ .gas = .{ .per_execution = 10_000 } } });
    defer iso.deinit();
    const before = iso.stats();
    try std.testing.expectError(error.ChecksumMismatch, codedb.run(iso, corrupted, "answer"));
    try expectNoExecution(before, iso.stats());
    try std.testing.expect(iso.lastError() == null);
    bytes[bytes.len - 1] ^= 1;
    try std.testing.expectEqual(@as(i64, 42), try (try codedb.run(iso, corrupted, "answer")).asInt());
}

test "CodeDB: manual manifests cannot bypass compatibility admission" {
    const payload = try artifact.validateRite(codedb.find(manifest, "answer").?, .{
        .compatibility = manifest.compatibility,
    });
    var image = try artifact.wrapRite(std.testing.allocator, payload.bytes, .{
        .compatibility = @splat(0x99),
    });
    defer image.deinit(std.testing.allocator);
    const incompatible = .{ .entries = [_]BareEntry{.{ .name = "answer", .bytes = image.encoded }} };
    const iso = try spawnSealed(.{ .limits = .{ .gas = .{ .per_execution = 10_000 } } });
    defer iso.deinit();
    const before = iso.stats();
    try std.testing.expectError(error.IncompatibleRiteImage, codedb.run(iso, incompatible, "answer"));
    try expectNoExecution(before, iso.stats());
}

test "CodeDB: application-bound entries require matching isolate acceptance" {
    const plain = try spawnSealed(.{ .limits = .{ .gas = .{ .per_execution = 10_000 } } });
    defer plain.deinit();
    const plain_before = plain.stats();
    try std.testing.expectError(error.IncompatibleRiteImage, plain.runArtifact(app_manifest, "answer"));
    try expectNoExecution(plain_before, plain.stats());

    const bound = try spawnSealed(.{
        .limits = .{ .gas = .{ .per_execution = 10_000 } },
        .artifacts = .{ .application = application },
    });
    defer bound.deinit();
    const bound_before = bound.stats();
    try std.testing.expectError(error.IncompatibleRiteImage, bound.runArtifact(manifest, "answer"));
    try expectNoExecution(bound_before, bound.stats());
    try std.testing.expectEqual(@as(i64, 42), try (try bound.runArtifact(app_manifest, "answer")).asInt());

    const other = try spawnSealed(.{
        .limits = .{ .gas = .{ .per_execution = 10_000 } },
        .artifacts = .{ .application = .{ .bytes = @splat(0x43) } },
    });
    defer other.deinit();
    const other_before = other.stats();
    try std.testing.expectError(error.IncompatibleRiteImage, other.runArtifact(app_manifest, "answer"));
    try expectNoExecution(other_before, other.stats());
}

test "CodeDB: artifact size limits apply before execution" {
    const iso = try spawnSealed(.{
        .limits = .{ .gas = .{ .per_execution = 10_000 } },
        .artifacts = .{ .limits = .{
            .max_rite_bytes = codedb.find(manifest, "answer").?.bytes.len - 1,
        } },
    });
    defer iso.deinit();
    const before = iso.stats();
    try std.testing.expectError(error.ArtifactLimitExceeded, iso.runArtifact(manifest, "answer"));
    try expectNoExecution(before, iso.stats());
}

test "CodeDB: instruction limits terminate bytecode and renew per execution" {
    const iso = try spawnSealed(sandbox.Policy.restricted(.{
        .limits = .{ .gas = .{ .per_execution = 200 } },
    }));
    defer iso.deinit();
    try std.testing.expectError(error.GasExhausted, iso.runArtifact(manifest, "loop"));
    try std.testing.expectEqual(@as(u64, 1), iso.stats().gas.?.generation);
    try std.testing.expectEqual(@as(i64, 42), try (try iso.runArtifact(manifest, "answer")).asInt());
    try std.testing.expectEqual(@as(u64, 2), iso.stats().gas.?.generation);
}

test "CodeDB: v0.3.0 manifest entry is rejected without execution" {
    const OldManifest = struct {
        pub const entries = [_]BareEntry{.{
            .name = "old",
            .bytes = @embedFile("tests_artifacts/rite_image_v0_3_0.bin"),
        }};
    };
    const iso = try spawnSealed(.{ .limits = .{ .gas = .{ .per_execution = 10_000 } } });
    defer iso.deinit();
    const before = iso.stats();
    try std.testing.expect(codedb.lookup(OldManifest, "old") != null);
    try std.testing.expectError(error.IncompatibleRiteImage, iso.runArtifact(OldManifest, "old"));
    try std.testing.expectError(error.IncompatibleRiteImage, iso.loadArtifact(OldManifest, "old"));
    try expectNoExecution(before, iso.stats());
    try std.testing.expect(iso.lastError() == null);
    try std.testing.expectEqual(@as(i64, 42), try (try iso.runArtifact(manifest, "answer")).asInt());
}

fn expectGraphLog(iso: sandbox.Isolate, expected: []const []const u8) !void {
    const log = try (try iso.getGlobal("codedb_graph_log")).asArray();
    try std.testing.expectEqual(expected.len, log.len());
    for (expected, 0..) |item, i| {
        try std.testing.expectEqualStrings(item, try (try log.get(i)).asString());
    }
}

test "CodeDB: version 1.0 and bare manifests load independent entries once" {
    const LegacyManifest = struct {
        pub const format_major: u16 = 1;
        pub const format_minor: u16 = 0;
        pub const compatibility = manifest.compatibility;
        pub const gem_set = manifest.gem_set;
        pub const entries = [_]BareEntry{.{
            .name = "answer",
            .bytes = codedb.lookup(manifest, "answer").?.bytes,
        }};
    };
    const BareManifest = struct {
        pub const entries = LegacyManifest.entries;
    };
    inline for (.{ LegacyManifest, BareManifest }) |legacy| {
        const iso = try spawnSealed(.{ .limits = .{ .gas = .{ .per_execution = 10_000 } } });
        defer iso.deinit();
        try std.testing.expect(try iso.loadArtifact(legacy, "answer"));
        const before = iso.stats();
        try std.testing.expect(!try iso.loadArtifact(legacy, "answer"));
        try expectNoExecution(before, iso.stats());
        try std.testing.expectEqual(@as(i64, 42), try (try iso.runArtifact(legacy, "answer")).asInt());
    }
}

test "CodeDB: version 1.1 graphs remain usable without authority metadata" {
    const LegacyGraph = struct {
        pub const format_major: u16 = 1;
        pub const format_minor: u16 = 1;
        pub const compatibility = graph_manifest.compatibility;
        pub const gem_set = graph_manifest.gem_set;
        const Entry = struct {
            name: []const u8,
            bytes: []const u8,
            dependencies: []const []const u8,
            entrypoint: bool,
        };
        pub const entries = blk: {
            var result: [graph_manifest.entries.len]Entry = undefined;
            for (graph_manifest.entries, &result) |entry, *record|
                record.* = .{
                    .name = entry.name,
                    .bytes = entry.bytes,
                    .dependencies = entry.dependencies,
                    .entrypoint = entry.entrypoint,
                };
            break :blk result;
        };
    };
    const iso = try spawnSealed(sandbox.Policy.trusted(.{}));
    defer iso.deinit();
    try std.testing.expect(try iso.loadArtifact(LegacyGraph, "main"));
    try std.testing.expect(!try iso.loadArtifact(LegacyGraph, "main"));
    try expectGraphLog(iso, &.{ "base", "left", "right", "main" });
}

test "CodeDB: graph metadata records dependencies before their users" {
    for (graph_manifest.entries, 0..) |entry, i| {
        for (entry.dependencies) |dependency| {
            var found = false;
            for (graph_manifest.entries[0..i]) |earlier| {
                if (std.mem.eql(u8, earlier.name, dependency)) found = true;
            }
            try std.testing.expect(found);
        }
    }
    try std.testing.expect(!codedb.lookup(graph_manifest, "base").?.entrypoint);
    try std.testing.expect(codedb.lookup(graph_manifest, "main").?.entrypoint);
    try std.testing.expectEqual(@as(usize, 2), codedb.lookup(graph_manifest, "main").?.dependencies.len);
}

test "CodeDB: diamond initialization runs once in dependency order" {
    const iso = try spawnSealed(.{ .limits = .{ .gas = .{ .per_execution = 10_000 } } });
    defer iso.deinit();
    try std.testing.expect(try iso.loadArtifact(graph_manifest, "main"));
    try expectGraphLog(iso, &.{ "base", "left", "right", "main" });
    try std.testing.expectEqual(@as(i64, 1), try (try iso.getGlobal("codedb_graph_base_runs")).asInt());
    try std.testing.expect((try iso.getGlobal("codedb_graph_unused")).isNil());
    try std.testing.expectEqual(@as(u64, 1), iso.stats().gas.?.generation);

    const before_repeat = iso.stats();
    try std.testing.expect(!try iso.loadArtifact(graph_manifest, "main"));
    try expectNoExecution(before_repeat, iso.stats());
    try expectGraphLog(iso, &.{ "base", "left", "right", "main" });

    try std.testing.expect(try iso.loadArtifact(graph_manifest, "secondary"));
    try expectGraphLog(iso, &.{ "base", "left", "right", "main", "secondary" });
    try std.testing.expectEqual(@as(i64, 1), try (try iso.getGlobal("codedb_graph_base_runs")).asInt());
    try std.testing.expectEqual(@as(u64, 2), iso.stats().gas.?.generation);
    try std.testing.expect(!try iso.loadArtifact(graph_manifest, "secondary"));

    // Explicit execution remains available and does not change loader state.
    _ = try iso.runArtifact(graph_manifest, "main");
    try expectGraphLog(iso, &.{ "base", "left", "right", "main", "secondary", "main" });
    try std.testing.expect(!try iso.loadArtifact(graph_manifest, "main"));
}

test "CodeDB: loading an entrypoint initializes only its dependency closure" {
    const iso = try spawnSealed(.{});
    defer iso.deinit();
    try std.testing.expect(try iso.loadArtifact(graph_manifest, "secondary"));
    try expectGraphLog(iso, &.{ "base", "secondary" });
    try std.testing.expect((try iso.getGlobal("codedb_graph_unused")).isNil());
    try std.testing.expect((try iso.getGlobal("codedb_graph_failure_runs")).isNil());
    try std.testing.expect((try iso.getGlobal("codedb_graph_gas_base")).isNil());
}

test "CodeDB: invalid entrypoint requests preserve execution state and do not bind a manifest" {
    const iso = try spawnSealed(.{ .limits = .{ .gas = .{ .per_execution = 10_000 } } });
    defer iso.deinit();
    try std.testing.expectError(error.RubyException, iso.run("raise 'graph sentinel'"));
    const before = iso.stats();
    try std.testing.expectError(error.UnknownArtifact, iso.loadArtifact(graph_manifest, "missing"));
    try std.testing.expectError(error.NotEntrypoint, iso.loadArtifact(graph_manifest, "base"));
    try expectNoExecution(before, iso.stats());
    const message = try iso.lastError().?.message(std.testing.allocator);
    defer std.testing.allocator.free(message);
    try std.testing.expectEqualStrings("graph sentinel", message);
    try std.testing.expect(try iso.loadArtifact(other_graph_manifest, "main"));
}

test "CodeDB: the complete unloaded closure is admitted before initialization" {
    const IncompatibleGraph = struct {
        pub const entries = blk: {
            var copied = graph_manifest.entries;
            for (&copied) |*entry| {
                // Only the final diamond unit requires an application identity.
                if (std.mem.eql(u8, entry.name, "main")) entry.bytes = app_manifest.entries[0].bytes;
            }
            break :blk copied;
        };
    };
    const iso = try spawnSealed(.{ .limits = .{ .gas = .{ .per_execution = 10_000 } } });
    defer iso.deinit();
    const before = iso.stats();
    try std.testing.expectError(error.IncompatibleRiteImage, iso.loadArtifact(IncompatibleGraph, "main"));
    try expectNoExecution(before, iso.stats());
    try std.testing.expect((try iso.getGlobal("codedb_graph_log")).isNil());
    try std.testing.expect(try iso.loadArtifact(graph_manifest, "main"));
    try expectGraphLog(iso, &.{ "base", "left", "right", "main" });
}

test "CodeDB: a loaded manifest cannot be replaced within an isolate" {
    const IdenticalEntries = struct {
        pub const entries = graph_manifest.entries;
    };
    const iso = try spawnSealed(.{ .limits = .{ .gas = .{ .per_execution = 10_000 } } });
    defer iso.deinit();
    try std.testing.expect(try iso.loadArtifact(graph_manifest, "main"));
    const before = iso.stats();
    try std.testing.expectError(error.CodeDBManifestMismatch, iso.loadArtifact(other_graph_manifest, "main"));
    try std.testing.expectError(error.CodeDBManifestMismatch, iso.loadArtifact(IdenticalEntries, "main"));
    try expectNoExecution(before, iso.stats());
    try std.testing.expect(!try iso.loadArtifact(graph_manifest, "main"));
    try std.testing.expect(try iso.loadArtifact(graph_manifest, "secondary"));

    const fresh = try spawnSealed(.{});
    defer fresh.deinit();
    try std.testing.expect(try fresh.loadArtifact(other_graph_manifest, "main"));
}

test "CodeDB: admission failure leaves a bound manifest and its loaded units usable" {
    const PartiallyIncompatibleGraph = struct {
        pub const entries = blk: {
            var copied = graph_manifest.entries;
            for (&copied) |*entry| {
                if (std.mem.eql(u8, entry.name, "main")) entry.bytes = app_manifest.entries[0].bytes;
            }
            break :blk copied;
        };
    };
    const iso = try spawnSealed(.{ .limits = .{ .gas = .{ .per_execution = 10_000 } } });
    defer iso.deinit();
    try std.testing.expect(try iso.loadArtifact(PartiallyIncompatibleGraph, "secondary"));
    try expectGraphLog(iso, &.{ "base", "secondary" });

    const before = iso.stats();
    try std.testing.expectError(error.IncompatibleRiteImage, iso.loadArtifact(PartiallyIncompatibleGraph, "main"));
    try expectNoExecution(before, iso.stats());
    try std.testing.expect(!try iso.loadArtifact(PartiallyIncompatibleGraph, "secondary"));
    try expectGraphLog(iso, &.{ "base", "secondary" });
    try std.testing.expectEqual(@as(i64, 1), try (try iso.getGlobal("codedb_graph_base_runs")).asInt());

    try std.testing.expect(try iso.loadArtifact(PartiallyIncompatibleGraph, "gas_main"));
    try std.testing.expectEqual(@as(i64, 4950), try (try iso.getGlobal("codedb_graph_gas_main")).asInt());
    try std.testing.expectEqual(@as(u64, 2), iso.stats().gas.?.generation);
}

test "CodeDB: initializer failure poisons loading even after host repairs its cause" {
    const iso = try spawnSealed(.{ .limits = .{ .gas = .{ .per_execution = 10_000 } } });
    defer iso.deinit();
    try std.testing.expect(try iso.loadArtifact(graph_manifest, "secondary"));
    try std.testing.expectError(error.RubyException, iso.loadArtifact(graph_manifest, "failed_root"));
    try expectGraphLog(iso, &.{ "base", "secondary", "failure" });
    const message = try iso.lastError().?.message(std.testing.allocator);
    defer std.testing.allocator.free(message);
    try std.testing.expectEqualStrings("CodeDB initialization failed", message);

    try iso.setGlobal("codedb_graph_allow_failure", iso.boolValue(true));
    const failed = iso.stats();
    try std.testing.expectError(error.CodeDBPoisoned, iso.loadArtifact(graph_manifest, "failed_root"));
    try std.testing.expectError(error.CodeDBPoisoned, iso.loadArtifact(graph_manifest, "secondary"));
    try std.testing.expectError(error.CodeDBPoisoned, iso.loadArtifact(graph_manifest, "main"));
    try expectNoExecution(failed, iso.stats());
    try std.testing.expectEqual(@as(i64, 1), try (try iso.getGlobal("codedb_graph_failure_runs")).asInt());

    const fresh = try spawnSealed(.{});
    defer fresh.deinit();
    try fresh.setGlobal("codedb_graph_allow_failure", fresh.boolValue(true));
    try std.testing.expect(try fresh.loadArtifact(graph_manifest, "failed_root"));
    try expectGraphLog(fresh, &.{ "base", "failure", "failed_root" });
    try std.testing.expectEqual(@as(i64, 1), try (try fresh.getGlobal("codedb_graph_base_runs")).asInt());
}

test "CodeDB: all initializers in one load share a single execution gas allowance" {
    const probe = try spawnSealed(.{ .limits = .{ .gas = .{ .per_execution = 100_000 } } });
    defer probe.deinit();
    _ = try probe.runArtifact(graph_manifest, "gas_base");
    const base_cost = probe.stats().gas.?.used;
    _ = try probe.runArtifact(graph_manifest, "gas_main");
    const main_cost = probe.stats().gas.?.used;
    const budget = @max(base_cost, main_cost) + 1;
    try std.testing.expect(base_cost + main_cost > budget);

    const iso = try spawnSealed(.{ .limits = .{ .gas = .{ .per_execution = budget } } });
    defer iso.deinit();
    try std.testing.expectError(error.GasExhausted, iso.loadArtifact(graph_manifest, "gas_main"));
    try std.testing.expectEqual(@as(u64, 1), iso.stats().gas.?.generation);
    try std.testing.expectEqual(@as(i64, 4950), try (try iso.getGlobal("codedb_graph_gas_base")).asInt());
    try std.testing.expectError(error.CodeDBPoisoned, iso.loadArtifact(graph_manifest, "gas_main"));
}

test "CodeDB: final outer policy failure poisons an initializer that returned successfully" {
    const Gate = struct {
        var isolate: ?sandbox.Isolate = null;

        fn call(vm: *mruby.Vm, self: mruby.Value) !mruby.Value {
            _ = self;
            isolate.?.terminate();
            return vm.boolValue(true);
        }
    };
    var boot = try sandbox.BootstrapIsolate.spawn(.{ .limits = .{
        .gas = .{ .per_execution = 10_000 },
    } });
    defer boot.deinit();
    const class = try boot.vm().defineClass("CodeDBGate", null);
    try class.defineClassMethod("call", Gate.call);
    const iso = try boot.seal();
    defer iso.deinit();
    Gate.isolate = iso;
    defer Gate.isolate = null;
    const copied_handle = iso;

    // The short initializer tail has no catch region: delayed termination
    // delivery lets it store the callback result and return normally, then
    // the outer policy boundary rejects the execution.
    try std.testing.expectError(error.ScriptTerminated, iso.loadArtifact(graph_manifest, "gate"));
    try std.testing.expect((try iso.getGlobal("codedb_graph_gate_result")).isTruthy());

    const failed = iso.stats();
    try std.testing.expectError(error.CodeDBPoisoned, copied_handle.loadArtifact(graph_manifest, "gate"));
    try std.testing.expectError(error.CodeDBPoisoned, copied_handle.loadArtifact(graph_manifest, "main"));
    try expectNoExecution(failed, iso.stats());
}

test "CodeDB: discarded initializer results do not accumulate arena roots" {
    const iso = try spawnSealed(.{});
    defer iso.deinit();
    const before = iso.arenaScope();
    try std.testing.expect(try iso.loadArtifact(graph_manifest, "main"));
    const after = iso.arenaScope();
    try std.testing.expectEqual(before.idx, after.idx);
    mruby.c.mrb_full_gc(sandbox.internalVm(iso).mrb);
    try expectGraphLog(iso, &.{ "base", "left", "right", "main" });
}

test "CodeDB: callback reentry is rejected without poisoning the outer load" {
    const Gate = struct {
        var isolate: ?sandbox.Isolate = null;

        fn call(vm: *mruby.Vm, self: mruby.Value) anyerror!mruby.Value {
            _ = self;
            _ = isolate.?.loadArtifact(graph_manifest, "main") catch |err| {
                if (err == error.IsolateThreadBusy) return vm.boolValue(true);
                return err;
            };
            return vm.boolValue(false);
        }
    };
    var boot = try sandbox.BootstrapIsolate.spawn(.{});
    defer boot.deinit();
    const class = try boot.vm().defineClass("CodeDBGate", null);
    try class.defineClassMethod("call", Gate.call);
    const iso = try boot.seal();
    defer iso.deinit();
    Gate.isolate = iso;
    defer Gate.isolate = null;
    try std.testing.expect(try iso.loadArtifact(graph_manifest, "gate"));
    try std.testing.expect((try iso.getGlobal("codedb_graph_gate_result")).isTruthy());
    try std.testing.expect((try iso.getGlobal("codedb_graph_log")).isNil());
    try std.testing.expect(try iso.loadArtifact(graph_manifest, "main"));
}

test "CodeDB: concurrent loads and execution are rejected while a closure is initializing" {
    const Gate = struct {
        var entered = std.atomic.Value(bool).init(false);
        var release = std.atomic.Value(bool).init(false);

        fn call(vm: *mruby.Vm, self: mruby.Value) !mruby.Value {
            _ = self;
            entered.store(true, .release);
            while (!release.load(.acquire)) std.atomic.spinLoopHint();
            return vm.nilValue();
        }
    };
    const Runner = struct {
        iso: sandbox.Isolate,
        done: std.atomic.Value(bool) = .init(false),
        failure: ?anyerror = null,

        fn run(runner: *@This()) void {
            defer runner.done.store(true, .release);
            _ = runner.iso.loadArtifact(graph_manifest, "gate") catch |err| {
                runner.failure = err;
                return;
            };
        }
    };
    Gate.entered.store(false, .release);
    Gate.release.store(false, .release);
    var boot = try sandbox.BootstrapIsolate.spawn(.{});
    defer boot.deinit();
    const class = try boot.vm().defineClass("CodeDBGate", null);
    try class.defineClassMethod("call", Gate.call);
    const iso = try boot.seal();
    defer iso.deinit();

    var runner = Runner{ .iso = iso };
    const thread = try std.Thread.spawn(.{}, Runner.run, .{&runner});
    var joined = false;
    defer if (!joined) {
        Gate.release.store(true, .release);
        thread.join();
    };
    while (!Gate.entered.load(.acquire) and !runner.done.load(.acquire)) std.atomic.spinLoopHint();
    try std.testing.expect(Gate.entered.load(.acquire));
    try std.testing.expectError(error.IsolateThreadBusy, iso.loadArtifact(graph_manifest, "main"));
    try std.testing.expectError(error.IsolateThreadBusy, iso.runArtifact(manifest, "answer"));
    Gate.release.store(true, .release);
    thread.join();
    joined = true;
    try std.testing.expect(runner.failure == null);
    try std.testing.expect(!try iso.loadArtifact(graph_manifest, "gate"));
    try std.testing.expect(try iso.loadArtifact(graph_manifest, "main"));
}
