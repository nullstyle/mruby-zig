//! Pure validation and deterministic ordering for declared CodeDB modules.
const std = @import("std");

pub const Node = struct {
    name: []const u8,
    dependencies: []const []const u8 = &.{},
};

pub const GraphError = error{
    EmptyCodeDB,
    InvalidArtifactName,
    DuplicateArtifactName,
    DuplicateArtifactDependency,
    MissingArtifactDependency,
    ArtifactDependencyCycle,
};

pub const Edge = struct {
    module: []const u8,
    dependency: []const u8,
};

/// Names borrow the caller's nodes. Allocation failures leave `.none`.
pub const Diagnostic = union(enum) {
    none,
    empty,
    invalid_name: []const u8,
    duplicate_name: []const u8,
    duplicate_dependency: Edge,
    missing_dependency: Edge,
    cycle: Edge,

    pub fn report(self: Diagnostic) void {
        switch (self) {
            .none => {},
            .empty => std.debug.print("CodeDB: at least one module is required\n", .{}),
            .invalid_name => |name| std.debug.print("CodeDB: invalid artifact name: {s}\n", .{name}),
            .duplicate_name => |name| std.debug.print("CodeDB: duplicate artifact name: {s}\n", .{name}),
            .duplicate_dependency => |edge| std.debug.print("CodeDB: {s}: duplicate dependency: {s}\n", .{ edge.module, edge.dependency }),
            .missing_dependency => |edge| std.debug.print("CodeDB: {s}: unknown dependency: {s}\n", .{ edge.module, edge.dependency }),
            .cycle => |edge| std.debug.print("CodeDB: dependency cycle includes {s} -> {s}\n", .{ edge.module, edge.dependency }),
        }
    }
};

/// Returns owned indices into `nodes`, with dependencies before dependents.
/// At every step the lexicographically smallest ready module is selected, so
/// source and dependency declaration order cannot affect the resulting names.
/// Entrypoint status does not constrain the graph: a library-only bundle is
/// valid, and any module may declare dependencies on other modules.
pub fn order(allocator: std.mem.Allocator, nodes: []const Node, diagnostic: ?*Diagnostic) (std.mem.Allocator.Error || GraphError)![]usize {
    setDiagnostic(diagnostic, .none);
    if (nodes.len == 0) {
        setDiagnostic(diagnostic, .empty);
        return error.EmptyCodeDB;
    }
    for (nodes, 0..) |node, i| {
        if (node.name.len == 0 or std.mem.indexOfScalar(u8, node.name, 0) != null) {
            setDiagnostic(diagnostic, .{ .invalid_name = node.name });
            return error.InvalidArtifactName;
        }
        for (nodes[0..i]) |previous| {
            if (std.mem.eql(u8, node.name, previous.name)) {
                setDiagnostic(diagnostic, .{ .duplicate_name = node.name });
                return error.DuplicateArtifactName;
            }
        }
    }
    for (nodes) |node| {
        for (node.dependencies, 0..) |dependency, i| {
            const edge: Edge = .{ .module = node.name, .dependency = dependency };
            for (node.dependencies[0..i]) |previous| {
                if (std.mem.eql(u8, dependency, previous)) {
                    setDiagnostic(diagnostic, .{ .duplicate_dependency = edge });
                    return error.DuplicateArtifactDependency;
                }
            }
            if (find(nodes, dependency) == null) {
                setDiagnostic(diagnostic, .{ .missing_dependency = edge });
                return error.MissingArtifactDependency;
            }
        }
    }

    const result = try allocator.alloc(usize, nodes.len);
    errdefer allocator.free(result);
    const pending = try allocator.alloc(usize, nodes.len);
    defer allocator.free(pending);
    for (nodes, pending) |node, *count| count.* = node.dependencies.len;

    for (result) |*slot| {
        var ready: ?usize = null;
        for (nodes, pending, 0..) |node, count, i| {
            if (count == 0 and (ready == null or std.mem.lessThan(u8, node.name, nodes[ready.?].name)))
                ready = i;
        }
        const index = ready orelse {
            setDiagnostic(diagnostic, .{ .cycle = cycleEdge(nodes, pending) });
            return error.ArtifactDependencyCycle;
        };
        slot.* = index;
        pending[index] = emitted;
        for (nodes, pending) |node, *count| {
            if (count.* == emitted) continue;
            for (node.dependencies) |dependency| {
                if (std.mem.eql(u8, dependency, nodes[index].name)) {
                    count.* -= 1;
                    break;
                }
            }
        }
    }
    return result;
}

const emitted = std.math.maxInt(usize);

fn setDiagnostic(destination: ?*Diagnostic, diagnostic: Diagnostic) void {
    if (destination) |pointer| pointer.* = diagnostic;
}

fn find(nodes: []const Node, name: []const u8) ?usize {
    for (nodes, 0..) |node, i| {
        if (std.mem.eql(u8, node.name, name)) return i;
    }
    return null;
}

/// A blocked module may merely depend on a cycle. Follow a deterministic
/// remaining dependency for `nodes.len` steps to enter the cycle itself.
fn cycleEdge(nodes: []const Node, pending: []const usize) Edge {
    var first: ?usize = null;
    for (nodes, pending, 0..) |node, count, i| {
        if (count != emitted and (first == null or std.mem.lessThan(u8, node.name, nodes[first.?].name)))
            first = i;
    }
    var index = first.?;
    for (0..nodes.len) |_| index = pendingDependency(nodes, pending, index);
    return .{
        .module = nodes[index].name,
        .dependency = nodes[pendingDependency(nodes, pending, index)].name,
    };
}

fn pendingDependency(nodes: []const Node, pending: []const usize, index: usize) usize {
    var first: ?usize = null;
    for (nodes[index].dependencies) |dependency| {
        const dependency_index = find(nodes, dependency).?;
        if (pending[dependency_index] != emitted and
            (first == null or std.mem.lessThan(u8, dependency, nodes[first.?].name)))
            first = dependency_index;
    }
    return first.?;
}

fn expectOrder(nodes: []const Node, names: []const []const u8) !void {
    const indices = try order(std.testing.allocator, nodes, null);
    defer std.testing.allocator.free(indices);
    try std.testing.expectEqual(names.len, indices.len);
    for (indices, names) |index, name| try std.testing.expectEqualStrings(name, nodes[index].name);
}

test "diamond dependencies execute before dependents" {
    try expectOrder(&.{
        .{ .name = "entry", .dependencies = &.{ "left", "right" } },
        .{ .name = "right", .dependencies = &.{"base"} },
        .{ .name = "base" },
        .{ .name = "left", .dependencies = &.{"base"} },
    }, &.{ "base", "left", "right", "entry" });
}

test "lexically smallest ready module wins over a pre-sorted traversal" {
    try expectOrder(&.{
        .{ .name = "a", .dependencies = &.{"c"} },
        .{ .name = "b" },
        .{ .name = "c" },
    }, &.{ "b", "c", "a" });
    try expectOrder(&.{
        .{ .name = "a", .dependencies = &.{"b"} },
        .{ .name = "b" },
        .{ .name = "c" },
    }, &.{ "b", "a", "c" });
}

test "shuffled source and dependency declarations have the same order" {
    const expected = &.{ "base", "left", "right", "entry", "unused" };
    try expectOrder(&.{
        .{ .name = "entry", .dependencies = &.{ "right", "left" } },
        .{ .name = "unused" },
        .{ .name = "right", .dependencies = &.{"base"} },
        .{ .name = "base" },
        .{ .name = "left", .dependencies = &.{"base"} },
    }, expected);
    try expectOrder(&.{
        .{ .name = "left", .dependencies = &.{"base"} },
        .{ .name = "base" },
        .{ .name = "entry", .dependencies = &.{ "left", "right" } },
        .{ .name = "right", .dependencies = &.{"base"} },
        .{ .name = "unused" },
    }, expected);
}

test "graph needs modules but no entrypoint" {
    try expectOrder(&.{
        .{ .name = "library", .dependencies = &.{"support"} },
        .{ .name = "support" },
    }, &.{ "support", "library" });
    var diagnostic: Diagnostic = .none;
    try std.testing.expectError(error.EmptyCodeDB, order(std.testing.allocator, &.{}, &diagnostic));
    try std.testing.expect(diagnostic == .empty);
}

test "duplicate and invalid names are rejected" {
    var diagnostic: Diagnostic = .none;
    try std.testing.expectError(error.DuplicateArtifactName, order(std.testing.allocator, &.{
        .{ .name = "same" },
        .{ .name = "same" },
    }, &diagnostic));
    try std.testing.expectEqualStrings("same", diagnostic.duplicate_name);
    for ([_][]const u8{ "", "nul\x00name" }) |name| {
        try std.testing.expectError(error.InvalidArtifactName, order(std.testing.allocator, &.{.{ .name = name }}, &diagnostic));
        try std.testing.expectEqualStrings(name, diagnostic.invalid_name);
    }
}

test "missing and repeated dependencies name both ends of the edge" {
    var diagnostic: Diagnostic = .none;
    try std.testing.expectError(error.MissingArtifactDependency, order(std.testing.allocator, &.{
        .{ .name = "entry", .dependencies = &.{"missing"} },
    }, &diagnostic));
    try std.testing.expectEqualStrings("entry", diagnostic.missing_dependency.module);
    try std.testing.expectEqualStrings("missing", diagnostic.missing_dependency.dependency);
    try std.testing.expectError(error.DuplicateArtifactDependency, order(std.testing.allocator, &.{
        .{ .name = "entry", .dependencies = &.{ "base", "base" } },
        .{ .name = "base" },
    }, &diagnostic));
    try std.testing.expectEqualStrings("entry", diagnostic.duplicate_dependency.module);
    try std.testing.expectEqualStrings("base", diagnostic.duplicate_dependency.dependency);
}

test "self dependency is a cycle" {
    var diagnostic: Diagnostic = .none;
    try std.testing.expectError(error.ArtifactDependencyCycle, order(std.testing.allocator, &.{
        .{ .name = "self", .dependencies = &.{"self"} },
    }, &diagnostic));
    try std.testing.expectEqualStrings("self", diagnostic.cycle.module);
    try std.testing.expectEqualStrings("self", diagnostic.cycle.dependency);
}

test "cycle diagnostic names an edge in the cycle rather than a blocked dependent" {
    var diagnostic: Diagnostic = .none;
    try std.testing.expectError(error.ArtifactDependencyCycle, order(std.testing.allocator, &.{
        .{ .name = "a_blocked", .dependencies = &.{"cycle_b"} },
        .{ .name = "cycle_b", .dependencies = &.{"cycle_c"} },
        .{ .name = "cycle_c", .dependencies = &.{"cycle_b"} },
        .{ .name = "unrelated" },
    }, &diagnostic));
    const edge = diagnostic.cycle;
    try std.testing.expect(std.mem.startsWith(u8, edge.module, "cycle_"));
    try std.testing.expect(std.mem.startsWith(u8, edge.dependency, "cycle_"));
    try std.testing.expect(!std.mem.eql(u8, edge.module, edge.dependency));
}
