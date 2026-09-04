//! Build-managed application Ruby. The host tools belong to the configured
//! mruby dependency; source files and generated outputs belong to the caller.
const std = @import("std");
const graph = @import("codedb_graph.zig");
const gate = @import("codedb_authority.zig");

pub const Tier = gate.Tier;
pub const AuthoritySet = gate.AuthoritySet;
pub const AuthorityKind = gate.AuthorityKind;
pub const HostBinding = gate.HostBinding;

pub const Source = struct {
    /// Logical lookup key, independent of the on-disk artifact name.
    name: []const u8,
    source: std.Build.LazyPath,
    /// Stable relative filename recorded by mrbc, including in __FILE__ and
    /// backtraces. Defaults to `<name>.rb`; never use an absolute host path.
    source_name: ?[]const u8 = null,
    application: ?[32]u8 = null,
    /// Logical names loaded before this module. Declaration order is ignored.
    dependencies: []const []const u8 = &.{},
    /// Public entrypoint by default; false declares a dependency-only library.
    entrypoint: bool = true,
    /// Additional authority required by this module. An empty declaration
    /// never removes authority linked into the VM or host binding catalogue.
    required_authority: AuthoritySet = .empty,
    /// Names from Options.host_bindings used by this module.
    host_bindings: []const []const u8 = &.{},
};

pub const Options = struct {
    sources: []const Source,
    tier: Tier = .worker,
    /// Complete catalogue of host bindings available to application Ruby.
    /// Every declared binding contributes authority, including unused bindings.
    host_bindings: []const HostBinding = &.{},
};

pub const Bundle = struct {
    /// Import this module into the executable which imports `mruby`.
    manifest: *std.Build.Module,
    /// Cache-owned manifest.zig and SHA-256-addressed .rite files.
    directory: std.Build.LazyPath,
};

pub const Tools = struct {
    mrbc: std.Build.LazyPath,
    envelope: std.Build.LazyPath,
};

pub fn add(b: *std.Build, tools: Tools, options: Options) !Bundle {
    // Validate the complete request before adding compilation steps. Logical
    // keys are serialized by the generator and never become output paths.
    const nodes = try b.allocator.alloc(graph.Node, options.sources.len);
    defer b.allocator.free(nodes);
    for (options.sources, nodes) |unit, *node|
        node.* = .{ .name = unit.name, .dependencies = unit.dependencies };
    var diagnostic: graph.Diagnostic = .none;
    const ordered = graph.order(b.allocator, nodes, &diagnostic) catch |err| {
        diagnostic.report();
        return err;
    };
    defer b.allocator.free(ordered);
    for (ordered) |index| {
        const unit = options.sources[index];
        const source_name = unit.source_name orelse b.fmt("{s}.rb", .{unit.name});
        if (!validSourceName(source_name)) {
            std.debug.print("CodeDB: {s}: invalid relative source_name: {s}\n", .{ unit.name, source_name });
            return error.InvalidSourceName;
        }
    }

    const artifacts = try b.allocator.alloc(gate.Artifact, ordered.len);
    defer b.allocator.free(artifacts);
    for (ordered, artifacts) |index, *artifact| {
        const unit = options.sources[index];
        artifact.* = .{
            .name = unit.name,
            .dependencies = unit.dependencies,
            .required_authority = unit.required_authority,
            .host_bindings = unit.host_bindings,
        };
    }
    const effective = try b.allocator.alloc(AuthoritySet, ordered.len);
    defer b.allocator.free(effective);
    var failure: gate.Failure = .{};
    // This preflight validates caller declarations before scheduling compiler
    // steps. It does not establish profile eligibility: the configured envelope
    // tool repeats the full gate with its immutable linked authority profile
    // before publishing outputs.
    gate.validate(options.tier, &.{}, options.host_bindings, artifacts, effective, &failure) catch |err| {
        failure.report();
        return err;
    };

    const envelope = std.Build.Step.Run.create(b, "generate CodeDB manifest");
    envelope.addFileArg(tools.envelope);
    const directory = envelope.addOutputDirectoryArg("codedb");
    envelope.addArg(@tagName(options.tier));
    envelope.addArg(b.fmt("{d}", .{gate.allowed(options.tier).toBits()}));
    envelope.addArg(b.fmt("{d}", .{options.host_bindings.len}));
    const hosts = try b.allocator.dupe(HostBinding, options.host_bindings);
    defer b.allocator.free(hosts);
    std.mem.sort(HostBinding, hosts, {}, struct {
        fn lessThan(_: void, a: HostBinding, c: HostBinding) bool {
            return std.mem.lessThan(u8, a.name, c.name);
        }
    }.lessThan);
    for (hosts) |host| {
        envelope.addArg(host.name);
        envelope.addArg(b.fmt("{d}", .{host.authority.toBits()}));
    }
    for (ordered) |index| {
        const unit = options.sources[index];
        const source_name = unit.source_name orelse b.fmt("{s}.rb", .{unit.name});
        const stage = b.addWriteFiles();
        const staged_source = stage.addCopyFile(unit.source, source_name);
        var passes: [2]std.Build.LazyPath = undefined;
        for (&passes, 0..) |*pass, i| {
            const compile = std.Build.Step.Run.create(b, b.fmt("compile CodeDB {s} pass {d}", .{ unit.name, i }));
            compile.addFileArg(tools.mrbc);
            compile.setCwd(stage.getDirectory());
            compile.addArgs(&.{ "-g", "-o" });
            // Distinct output names force separate cached compilation steps.
            pass.* = compile.addOutputFileArg(b.fmt("pass-{d}.mrb", .{i}));
            compile.addArg(source_name);
            compile.addFileInput(staged_source);
        }
        envelope.addArgs(&.{ unit.name, source_name });
        // Hash the exact snapshot compiled by both passes, even if the
        // checkout source changes while these build steps are running.
        envelope.addFileArg(staged_source);
        envelope.addFileArg(passes[0]);
        envelope.addFileArg(passes[1]);
        envelope.addArg(if (unit.application) |digest|
            b.dupe(&std.fmt.bytesToHex(digest, .lower))
        else
            "-");
        envelope.addArg(if (unit.entrypoint) "true" else "false");
        envelope.addArg(b.fmt("{d}", .{unit.dependencies.len}));
        const dependencies = try b.allocator.dupe([]const u8, unit.dependencies);
        defer b.allocator.free(dependencies);
        std.mem.sort([]const u8, dependencies, {}, struct {
            fn lessThan(_: void, a: []const u8, c: []const u8) bool {
                return std.mem.lessThan(u8, a, c);
            }
        }.lessThan);
        envelope.addArgs(dependencies);
        envelope.addArg(b.fmt("{d}", .{unit.required_authority.toBits()}));
        envelope.addArg(b.fmt("{d}", .{unit.host_bindings.len}));
        const host_references = try b.allocator.dupe([]const u8, unit.host_bindings);
        defer b.allocator.free(host_references);
        std.mem.sort([]const u8, host_references, {}, struct {
            fn lessThan(_: void, a: []const u8, c: []const u8) bool {
                return std.mem.lessThan(u8, a, c);
            }
        }.lessThan);
        envelope.addArgs(host_references);
    }
    return .{
        .manifest = b.createModule(.{ .root_source_file = directory.path(b, "manifest.zig") }),
        .directory = directory,
    };
}

fn validSourceName(name: []const u8) bool {
    if (name.len == 0 or name[0] == '-') return false;
    for (name) |byte| {
        if (byte < 32 or byte == 127 or std.mem.indexOfScalar(u8, "\\:<>\"|?*", byte) != null)
            return false;
    }
    var parts = std.mem.splitScalar(u8, name, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..") or
            part[part.len - 1] == '.' or part[part.len - 1] == ' ') return false;
    }
    return true;
}

test "source names stay relative and portable for mrbc staging" {
    for ([_][]const u8{ "worker.rb", "app/billing job.rb", "app/step-1.rb" }) |name|
        try std.testing.expect(validSourceName(name));
    for ([_][]const u8{ "", "-g.rb", "/job.rb", "../job.rb", "app/../job.rb", "app//job.rb", "./job.rb", "a/", "a\\b.rb", "C:job.rb", "a\x00.rb", "a\n.rb", "a\".rb", "a.", "a " }) |name|
        try std.testing.expect(!validSourceName(name));
}
