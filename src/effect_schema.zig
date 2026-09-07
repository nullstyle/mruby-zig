//! Pure operation contracts. Shared descriptors contain anonymous literals;
//! this module owns their bounded normalized graph and never imports a VM.
//! Validation reads an inert data.Ref interface, allows aliases, rejects cycles,
//! and charges repeated visits so shared DAGs cannot create unbounded work.
const std = @import("std");

pub const max_nodes = 128;
pub const max_edges = 256;
pub const max_text_bytes = 4096;
pub const max_schema_depth = 32;
pub const max_validation_depth = 64;
pub const max_validation_work = 65_536;
/// Includes recursively expanded schema children and framing. Normalized
/// shared DAGs must not turn bounded storage into unbounded identity hashing.
pub const max_schema_hash_bytes = 65_536;
pub const CompileError = error{InvalidEffectContract};
// These tags are also diagnostic wire ABI: append only until that codec's
// version changes. Kind tags additionally participate in contract identity.
pub const Side = enum(u8) { arguments = 0, result = 1, rejection = 2 };
pub const Kind = enum(u8) { nil = 0, boolean = 1, integer = 2, float = 3, string = 4, tuple = 5, array = 6, object = 7, nullable = 8, enum_string = 9, never = 10 };
pub const ValueKind = enum(u8) { nil = 0, boolean = 1, integer = 2, float = 3, symbol = 4, string = 5, array = 6, hash = 7 };
pub const Reason = enum(u8) { type_mismatch = 0, integer_range = 1, string_length = 2, array_length = 3, missing_field = 4, extra_field = 5, enum_value = 6, non_finite = 7, cycle = 8, work_limit = 9, depth_limit = 10, hash_default = 11, rejection_forbidden = 12 };
/// The value-only detail reused by turn contracts. Its path and text own all
/// their storage; it contains no effect operation or operation-side metadata.
pub const ValueMismatch = struct {
    reason: Reason,
    path: [256]u8 = @splat(0),
    path_len: u16 = 0,
    path_truncated: bool = false,
    expected: Kind,
    actual: ?ValueKind = null,
    pub fn pathText(self: *const ValueMismatch) []const u8 {
        return self.path[0..self.path_len];
    }
};
pub const Mismatch = struct {
    side: Side,
    reason: Reason,
    path: [256]u8 = @splat(0),
    path_len: u16 = 0,
    path_truncated: bool = false,
    expected: Kind,
    actual: ?ValueKind = null,
    pub fn pathText(self: *const Mismatch) []const u8 {
        return self.path[0..self.path_len];
    }
    fn valueDetail(self: *const Mismatch) ValueMismatch {
        return .{ .reason = self.reason, .path = self.path, .path_len = self.path_len, .path_truncated = self.path_truncated, .expected = self.expected, .actual = self.actual };
    }
};

const Node = struct {
    kind: Kind = .never,
    minimum: i64 = std.math.minInt(i64),
    maximum: i64 = std.math.maxInt(i64),
    min_len: u32 = 0,
    max_len: u32 = 0,
    first: u16 = 0,
    count: u16 = 0,
    child: u16 = 0,
};
const Edge = struct { child: u16 = 0, text_start: u16 = 0, text_len: u16 = 0, optional: bool = false };

/// Owns every node and name. Store the comptime result once and pass a pointer.
/// Graph layout is private; only digest() defines identity, using explicit
/// endian framing and sorted object fields/enum alternatives.
pub const Contract = struct {
    nodes: [max_nodes]Node = @splat(.{}),
    edges: [max_edges]Edge = @splat(.{}),
    text: [max_text_bytes]u8 = @splat(0),
    node_count: u16 = 0,
    edge_count: u16 = 0,
    text_len: u16 = 0,
    roots: [3]u16 = @splat(0),

    pub fn arity(self: *const Contract) usize {
        return self.nodes[self.roots[0]].count;
    }
    pub fn digest(self: *const Contract) [32]u8 {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("mruby-zig/effect-contract/v1\x00");
        for (self.roots) |root| self.hashNode(&hash, root);
        return hash.finalResult();
    }
    fn name(self: *const Contract, edge: Edge) []const u8 {
        return self.text[edge.text_start..][0..edge.text_len];
    }
    fn hashInt(hash: *std.crypto.hash.sha2.Sha256, comptime T: type, value: T) void {
        var bytes: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &bytes, value, .big);
        hash.update(&bytes);
    }
    fn hashNode(self: *const Contract, hash: *std.crypto.hash.sha2.Sha256, id: u16) void {
        const node = self.nodes[id];
        hashInt(hash, u8, @backingInt(node.kind));
        switch (node.kind) {
            .integer => {
                hashInt(hash, i64, node.minimum);
                hashInt(hash, i64, node.maximum);
            },
            .string, .array => {
                hashInt(hash, u32, node.min_len);
                hashInt(hash, u32, node.max_len);
                if (node.kind == .array) self.hashNode(hash, node.child);
            },
            .nullable => self.hashNode(hash, node.child),
            .tuple, .object, .enum_string => {
                hashInt(hash, u16, node.count);
                for (self.edges[node.first..][0..node.count]) |edge| {
                    if (node.kind != .tuple) {
                        hashInt(hash, u16, edge.text_len);
                        hash.update(self.name(edge));
                    }
                    if (node.kind == .object) hashInt(hash, u8, @intFromBool(edge.optional));
                    if (node.kind != .enum_string) self.hashNode(hash, edge.child);
                }
            },
            else => {},
        }
    }
};

/// One value shape using exactly the operation compiler and validator. Each
/// shape independently has the published node, edge, text, depth and work caps.
pub const Shape = struct {
    graph: Contract,

    pub fn digest(self: *const Shape) [32]u8 {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("mruby-zig/value-shape/v1\x00");
        self.graph.hashNode(&hash, self.graph.roots[0]);
        return hash.finalResult();
    }
    pub fn validate(self: *const Shape, root: anytype) ?ValueMismatch {
        var validation: Validation = .{ .contract = &self.graph, .side = .result };
        validation.path.add("$");
        const mismatch = validation.visit(self.graph.roots[0], root, 0) orelse return null;
        return mismatch.valueDetail();
    }
    /// Copy before checking indexes. Runtime admission uses the owned result,
    /// so callbacks cannot subsequently change a captured contract's meaning.
    pub fn checkedCopy(self: *const Shape) CompileError!Shape {
        const copied = self.*;
        if (!validNormalized(&copied.graph, false)) return error.InvalidEffectContract;
        return copied;
    }
    pub fn snapshot(comptime pointer: *const Shape) CompileError!*const Shape {
        @setEvalBranchQuota(200_000);
        const checked = comptime pointer.checkedCopy();
        if (checked) |copied| {
            return &struct {
                const stored = copied;
            }.stored;
        } else |err| return err;
    }
};

pub fn compileShape(comptime literal: anytype) CompileError!Shape {
    @setEvalBranchQuota(200_000);
    var compiler: Compiler = .{};
    const root = try compiler.shape(literal, 0);
    compiler.contract.roots = @splat(root);
    return .{ .graph = compiler.contract };
}

/// Compile trusted anonymous descriptor literals. Malformed shapes, unknown
/// fields, duplicate names, inverted bounds, and schema budget excess all fail.
pub fn compile(comptime literal: anytype) CompileError!Contract {
    @setEvalBranchQuota(200_000);
    if (comptime !fields(literal, .{ "arguments", "result" }, .{"rejection"})) return error.InvalidEffectContract;
    var compiler: Compiler = .{};
    compiler.contract.roots[0] = try compiler.shape(literal.arguments, 0);
    if (compiler.contract.nodes[compiler.contract.roots[0]].kind != .tuple) return error.InvalidEffectContract;
    compiler.contract.roots[1] = try compiler.shape(literal.result, 0);
    compiler.contract.roots[2] = if (@hasField(@TypeOf(literal), "rejection"))
        try compiler.rejection(literal.rejection)
    else
        try compiler.add(.{ .kind = .never });
    return compiler.contract;
}

/// Normalize either a raw shared literal or an already normalized operation.
/// The returned pointer refers to static owned storage, never the caller stack.
pub fn operationContract(comptime descriptor: anytype) CompileError!?*const Contract {
    @setEvalBranchQuota(200_000);
    if (!@hasField(@TypeOf(descriptor), "contract")) return null;
    const value = descriptor.contract;
    if (@TypeOf(value) == @TypeOf(null)) return null;
    if (@TypeOf(value) == ?*const Contract or @TypeOf(value) == ?*Contract) {
        if (value) |pointer| return @as(?*const Contract, try snapshot(pointer));
        return null;
    }
    if (@TypeOf(value) == *const Contract or @TypeOf(value) == *Contract) return @as(?*const Contract, try snapshot(value));
    const compiled = comptime compile(value);
    if (compiled) |normalized| {
        return &struct {
            const stored = normalized;
        }.stored;
    } else |err| return err;
}

fn snapshot(comptime pointer: *const Contract) CompileError!*const Contract {
    // A host cannot mutate a normalized operation's schema after its identity
    // is captured. Reading a runtime-only pointer here is a comptime error.
    const copied = comptime pointer.*;
    if (comptime !validNormalized(&copied, true)) return error.InvalidEffectContract;
    return &struct {
        const stored = copied;
    }.stored;
}

fn validNormalized(contract: *const Contract, operation: bool) bool {
    if (contract.node_count == 0 or contract.node_count > max_nodes or contract.edge_count > max_edges or contract.text_len > max_text_bytes) return false;
    for (contract.roots) |root| if (root >= contract.node_count) return false;
    if (operation and contract.nodes[contract.roots[0]].kind != .tuple) return false;
    if (!operation and (contract.roots[0] != contract.roots[1] or contract.roots[0] != contract.roots[2])) return false;
    var heights: [max_nodes]usize = @splat(1);
    var hash_bytes: [max_nodes]usize = @splat(1); // kind tag
    for (contract.nodes[0..contract.node_count], 0..) |node, id| {
        if (node.minimum > node.maximum or node.min_len > node.max_len) return false;
        switch (node.kind) {
            .integer => hash_bytes[id] += 16,
            .string => hash_bytes[id] += 8,
            .nullable, .array => {
                if (node.child >= id) return false;
                heights[id] += heights[node.child];
                hash_bytes[id] += hash_bytes[node.child];
                if (node.kind == .array) hash_bytes[id] += 8;
            },
            .tuple, .object, .enum_string => {
                if (node.first > contract.edge_count or node.count > contract.edge_count - node.first) return false;
                if (node.kind == .enum_string and node.count == 0) return false;
                const members = contract.edges[node.first..][0..node.count];
                hash_bytes[id] += 2; // child/field/enum count
                for (members, 0..) |edge, i| {
                    if (node.kind != .enum_string) {
                        if (edge.child >= id) return false;
                        heights[id] = @max(heights[id], 1 + heights[edge.child]);
                        hash_bytes[id] += hash_bytes[edge.child];
                    }
                    if (node.kind != .tuple) {
                        if (edge.text_len == 0 or edge.text_len > 128 or edge.text_start > contract.text_len or edge.text_len > contract.text_len - edge.text_start) return false;
                        if (i > 0 and std.mem.order(u8, contract.name(members[i - 1]), contract.name(edge)) != .lt) return false;
                        hash_bytes[id] += 2 + @as(usize, edge.text_len);
                        if (node.kind == .object) hash_bytes[id] += 1; // optional flag
                    }
                    if (hash_bytes[id] > max_schema_hash_bytes) return false;
                }
            },
            .never => if (!operation or id != contract.roots[2]) return false,
            else => {},
        }
        if (heights[id] > max_schema_depth) return false;
        if (hash_bytes[id] > max_schema_hash_bytes) return false;
    }
    var expanded_bytes: usize = if (operation) "mruby-zig/effect-contract/v1\x00".len else "mruby-zig/value-shape/v1\x00".len;
    for (contract.roots[0..if (operation) @as(usize, 3) else 1]) |root| {
        if (hash_bytes[root] > max_schema_hash_bytes - expanded_bytes) return false;
        expanded_bytes += hash_bytes[root];
    }
    if (!operation) return true;
    const rejection = contract.nodes[contract.roots[2]];
    if (rejection.kind == .never) return true;
    if (rejection.kind != .tuple or rejection.count != 2) return false;
    return contract.nodes[contract.edges[rejection.first].child].kind == .enum_string and contract.nodes[contract.edges[rejection.first + 1].child].kind == .string;
}

fn fields(comptime value: anytype, comptime required: anytype, comptime optional: anytype) bool {
    const info = @typeInfo(@TypeOf(value));
    if (info != .@"struct") return false;
    inline for (required) |name| if (!@hasField(@TypeOf(value), name)) return false;
    inline for (info.@"struct".field_names) |name| {
        var found = false;
        inline for (required) |allowed| if (std.mem.eql(u8, name, allowed)) {
            found = true;
        };
        inline for (optional) |allowed| if (std.mem.eql(u8, name, allowed)) {
            found = true;
        };
        if (!found) return false;
    }
    return true;
}
fn list(comptime value: anytype) bool {
    const info = @typeInfo(@TypeOf(value));
    return info == .@"struct" and (info.@"struct".is_tuple or info.@"struct".field_names.len == 0);
}
fn literalBytes(comptime value: anytype) ?[]const u8 {
    const info = @typeInfo(@TypeOf(value));
    if (info != .pointer) return null;
    if (info.pointer.size == .slice and info.pointer.child == u8) return value;
    if (info.pointer.size == .one) {
        const child = @typeInfo(info.pointer.child);
        if (child == .array and child.array.child == u8) return value;
    }
    return null;
}
fn integer(comptime value: anytype) ?i64 {
    return switch (@typeInfo(@TypeOf(value))) {
        .int, .comptime_int => std.math.cast(i64, value),
        else => null,
    };
}
fn length(comptime value: anytype) ?u32 {
    const n = integer(value) orelse return null;
    return std.math.cast(u32, n);
}

const Compiler = struct {
    contract: Contract = .{},
    fn add(self: *Compiler, node: Node) CompileError!u16 {
        if (self.contract.node_count == max_nodes) return error.InvalidEffectContract;
        const id = self.contract.node_count;
        self.contract.nodes[id] = node;
        self.contract.node_count += 1;
        return id;
    }
    fn reserve(self: *Compiler, count: usize) CompileError!u16 {
        if (count > max_edges - self.contract.edge_count) return error.InvalidEffectContract;
        const start = self.contract.edge_count;
        self.contract.edge_count += @intCast(count);
        return start;
    }
    fn textEdge(self: *Compiler, text: []const u8) CompileError!Edge {
        if (text.len == 0 or text.len > 128 or text.len > max_text_bytes - self.contract.text_len) return error.InvalidEffectContract;
        const start = self.contract.text_len;
        @memcpy(self.contract.text[start..][0..text.len], text);
        self.contract.text_len += @intCast(text.len);
        return .{ .text_start = start, .text_len = @intCast(text.len) };
    }
    fn sort(self: *Compiler, first: u16, count: usize) CompileError!void {
        const edges = self.contract.edges[first..][0..count];
        // Bounded insertion sort; this also canonicalizes identity independently
        // of declaration order without changing argument tuple order.
        for (1..edges.len) |i| {
            var j = i;
            while (j > 0 and std.mem.order(u8, self.contract.name(edges[j]), self.contract.name(edges[j - 1])) == .lt) : (j -= 1)
                std.mem.swap(Edge, &edges[j], &edges[j - 1]);
        }
        for (1..edges.len) |i| if (std.mem.eql(u8, self.contract.name(edges[i - 1]), self.contract.name(edges[i]))) return error.InvalidEffectContract;
    }
    fn strings(self: *Compiler, comptime values: anytype) CompileError!u16 {
        if (comptime !list(values)) return error.InvalidEffectContract;
        if (values.len == 0) return error.InvalidEffectContract;
        const first = try self.reserve(values.len);
        inline for (values, 0..) |value, i| self.contract.edges[first + i] = try self.textEdge(literalBytes(value) orelse return error.InvalidEffectContract);
        try self.sort(first, values.len);
        return self.add(.{ .kind = .enum_string, .first = first, .count = @intCast(values.len) });
    }
    fn rejection(self: *Compiler, comptime value: anytype) CompileError!u16 {
        if (comptime !fields(value, .{ "codes", "max_message_bytes" }, .{})) return error.InvalidEffectContract;
        const maximum = length(value.max_message_bytes) orelse return error.InvalidEffectContract;
        const first = try self.reserve(2);
        self.contract.edges[first].child = try self.strings(value.codes);
        self.contract.edges[first + 1].child = try self.add(.{ .kind = .string, .max_len = maximum });
        return self.add(.{ .kind = .tuple, .first = first, .count = 2 });
    }
    fn shape(self: *Compiler, comptime value: anytype, depth: usize) CompileError!u16 {
        if (depth >= max_schema_depth) return error.InvalidEffectContract;
        const info = @typeInfo(@TypeOf(value));
        if (info == .enum_literal) {
            inline for (.{ Kind.nil, Kind.boolean, Kind.integer, Kind.float }) |kind| {
                if (comptime std.mem.eql(u8, @tagName(value), @tagName(kind))) return self.add(.{ .kind = kind });
            }
            return error.InvalidEffectContract;
        }
        if (info != .@"struct" or info.@"struct".field_names.len != 1) return error.InvalidEffectContract;
        if (@hasField(@TypeOf(value), "integer")) {
            const bounds = value.integer;
            if (comptime !fields(bounds, .{}, .{ "min", "max" })) return error.InvalidEffectContract;
            const low = if (@hasField(@TypeOf(bounds), "min")) integer(bounds.min) orelse return error.InvalidEffectContract else std.math.minInt(i64);
            const high = if (@hasField(@TypeOf(bounds), "max")) integer(bounds.max) orelse return error.InvalidEffectContract else std.math.maxInt(i64);
            if (low > high) return error.InvalidEffectContract;
            return self.add(.{ .kind = .integer, .minimum = low, .maximum = high });
        }
        if (@hasField(@TypeOf(value), "string")) {
            const bounds = value.string;
            if (comptime !fields(bounds, .{"max_bytes"}, .{"min_bytes"})) return error.InvalidEffectContract;
            const low = if (@hasField(@TypeOf(bounds), "min_bytes")) length(bounds.min_bytes) orelse return error.InvalidEffectContract else 0;
            const high = length(bounds.max_bytes) orelse return error.InvalidEffectContract;
            if (low > high) return error.InvalidEffectContract;
            return self.add(.{ .kind = .string, .min_len = low, .max_len = high });
        }
        if (@hasField(@TypeOf(value), "nullable")) return self.add(.{ .kind = .nullable, .child = try self.shape(value.nullable, depth + 1) });
        if (@hasField(@TypeOf(value), "enum_string")) return self.strings(value.enum_string);
        if (@hasField(@TypeOf(value), "tuple")) {
            if (comptime !list(value.tuple)) return error.InvalidEffectContract;
            const first = try self.reserve(value.tuple.len);
            inline for (value.tuple, 0..) |child, i| self.contract.edges[first + i].child = try self.shape(child, depth + 1);
            return self.add(.{ .kind = .tuple, .first = first, .count = @intCast(value.tuple.len) });
        }
        if (@hasField(@TypeOf(value), "array")) {
            const array = value.array;
            if (comptime !fields(array, .{ "element", "max_items" }, .{"min_items"})) return error.InvalidEffectContract;
            const low = if (@hasField(@TypeOf(array), "min_items")) length(array.min_items) orelse return error.InvalidEffectContract else 0;
            const high = length(array.max_items) orelse return error.InvalidEffectContract;
            if (low > high) return error.InvalidEffectContract;
            return self.add(.{ .kind = .array, .min_len = low, .max_len = high, .child = try self.shape(array.element, depth + 1) });
        }
        if (@hasField(@TypeOf(value), "object")) {
            if (comptime !list(value.object)) return error.InvalidEffectContract;
            const first = try self.reserve(value.object.len);
            inline for (value.object, 0..) |field, i| {
                if (comptime !fields(field, .{ "name", "schema" }, .{"optional"})) return error.InvalidEffectContract;
                var edge = try self.textEdge(literalBytes(field.name) orelse return error.InvalidEffectContract);
                edge.child = try self.shape(field.schema, depth + 1);
                if (@hasField(@TypeOf(field), "optional")) {
                    if (@TypeOf(field.optional) != bool) return error.InvalidEffectContract;
                    edge.optional = field.optional;
                }
                self.contract.edges[first + i] = edge;
            }
            if (value.object.len > 1) try self.sort(first, value.object.len);
            return self.add(.{ .kind = .object, .first = first, .count = @intCast(value.object.len) });
        }
        return error.InvalidEffectContract;
    }
};

/// Input must already be an inert validated Ref. This never coerces values,
/// invokes guest hooks, allocates, or follows a Hash default as an object field.
pub fn validate(contract: *const Contract, side: Side, root: anytype) ?Mismatch {
    var validation: Validation = .{ .contract = contract, .side = side };
    validation.path.add("$");
    return validation.visit(contract.roots[@backingInt(side)], root, 0);
}

const Path = struct {
    bytes: [256]u8 = @splat(0),
    len: u16 = 0,
    truncated: bool = false,
    fn add(self: *Path, text: []const u8) void {
        const count = @min(text.len, self.bytes.len - self.len);
        @memcpy(self.bytes[self.len..][0..count], text[0..count]);
        self.len += @intCast(count);
        self.truncated = self.truncated or count != text.len;
    }
    fn index(self: *Path, i: usize) void {
        var buffer: [32]u8 = undefined;
        self.add(std.fmt.bufPrint(&buffer, "[{d}]", .{i}) catch unreachable);
    }
    fn field(self: *Path, name: []const u8) void {
        const hex = "0123456789abcdef";
        self.add("[\"");
        for (name) |byte| {
            if (self.len == self.bytes.len) {
                self.truncated = true;
                break;
            }
            switch (byte) {
                '"', '\\' => self.add(&.{ '\\', byte }),
                0x20...0x21, 0x23...0x5b, 0x5d...0x7e => self.add(&.{byte}),
                else => self.add(&.{ '\\', 'x', hex[byte >> 4], hex[byte & 15] }),
            }
        }
        self.add("\"]");
    }
};

const Validation = struct {
    contract: *const Contract,
    side: Side,
    work: usize = 0,
    ancestors: [max_validation_depth]u32 = undefined,
    ancestor_count: usize = 0,
    path: Path = .{},

    fn fail(self: *Validation, reason: Reason, expected: Kind, actual: ?ValueKind) Mismatch {
        return .{ .side = self.side, .reason = reason, .path = self.path.bytes, .path_len = self.path.len, .path_truncated = self.path.truncated, .expected = expected, .actual = actual };
    }
    fn charge(self: *Validation, expected: Kind, actual: ValueKind) ?Mismatch {
        if (self.work == max_validation_work) return self.fail(.work_limit, expected, actual);
        self.work += 1;
        return null;
    }
    fn actualKind(ref: anytype) ValueKind {
        return std.meta.stringToEnum(ValueKind, @tagName(ref.kind())).?;
    }
    fn visit(self: *Validation, id: u16, ref: anytype, depth: usize) ?Mismatch {
        const node = self.contract.nodes[id];
        const actual = actualKind(ref);
        if (self.charge(node.kind, actual)) |failure| return failure;
        if (depth >= max_validation_depth) return self.fail(.depth_limit, node.kind, actual);
        if (node.kind == .never) return self.fail(.rejection_forbidden, .never, actual);
        if (node.kind == .nullable) return if (actual == .nil) null else self.visit(node.child, ref, depth + 1);
        const container = actual == .array or actual == .hash;
        if (container) {
            const node_id = ref.nodeId().?;
            for (self.ancestors[0..self.ancestor_count]) |ancestor| if (ancestor == node_id) return self.fail(.cycle, node.kind, actual);
        }
        const matches = switch (node.kind) {
            .nil => actual == .nil,
            .boolean => actual == .boolean,
            .integer => actual == .integer,
            .float => actual == .float,
            .string, .enum_string => actual == .string,
            .tuple, .array => actual == .array,
            .object => actual == .hash,
            .never, .nullable => unreachable,
        };
        if (!matches) return self.fail(.type_mismatch, node.kind, actual);
        if (container) {
            self.ancestors[self.ancestor_count] = ref.nodeId().?;
            self.ancestor_count += 1;
        }
        defer if (container) {
            self.ancestor_count -= 1;
        };
        switch (node.kind) {
            .integer => {
                const value = ref.asInteger() catch unreachable;
                if (value < node.minimum or value > node.maximum) return self.fail(.integer_range, node.kind, actual);
            },
            .float => if (!std.math.isFinite(ref.asFloat() catch unreachable)) return self.fail(.non_finite, node.kind, actual),
            .string => {
                const size = (ref.asString() catch unreachable).len;
                if (size < node.min_len or size > node.max_len) return self.fail(.string_length, node.kind, actual);
            },
            .enum_string => {
                const value = ref.asString() catch unreachable;
                for (self.contract.edges[node.first..][0..node.count]) |edge| {
                    if (self.charge(node.kind, actual)) |failure| return failure;
                    if (std.mem.eql(u8, value, self.contract.name(edge))) return null;
                }
                return self.fail(.enum_value, node.kind, actual);
            },
            .tuple, .array => {
                const size = ref.len() catch unreachable;
                if (if (node.kind == .tuple) size != node.count else size < node.min_len or size > node.max_len)
                    return self.fail(.array_length, node.kind, actual);
                for (0..size) |i| {
                    const saved = self.path;
                    self.path.index(i);
                    const child = if (node.kind == .tuple) self.contract.edges[node.first + i].child else node.child;
                    if (self.visit(child, ref.at(i) catch unreachable, depth + 1)) |failure| return failure;
                    self.path = saved;
                }
            },
            .object => {
                if (ref.default() catch unreachable) |default| if (actualKind(default) != .nil) return self.fail(.hash_default, node.kind, actual);
                const count = ref.len() catch unreachable;
                const members = self.contract.edges[node.first..][0..node.count];
                for (0..count) |i| {
                    const pair = ref.pair(i) catch unreachable;
                    if (self.charge(node.kind, actual)) |failure| return failure;
                    if (actualKind(pair.key) != .string) {
                        self.path.index(i);
                        return self.fail(.extra_field, node.kind, actualKind(pair.key));
                    }
                    const key = pair.key.asString() catch unreachable;
                    var known = false;
                    for (members) |member| {
                        if (self.charge(node.kind, actual)) |failure| return failure;
                        if (std.mem.eql(u8, key, self.contract.name(member))) {
                            known = true;
                            break;
                        }
                    }
                    if (!known) {
                        self.path.field(key);
                        return self.fail(.extra_field, node.kind, actualKind(pair.value));
                    }
                }
                for (members) |member| {
                    const saved = self.path;
                    const name = self.contract.name(member);
                    self.path.field(name);
                    var found = false;
                    for (0..count) |i| {
                        if (self.charge(node.kind, actual)) |failure| return failure;
                        const pair = ref.pair(i) catch unreachable;
                        if (!std.mem.eql(u8, pair.key.asString() catch unreachable, name)) continue;
                        found = true;
                        if (self.visit(member.child, pair.value, depth + 1)) |failure| return failure;
                        break;
                    }
                    if (!found and !member.optional) return self.fail(.missing_field, self.contract.nodes[member.child].kind, null);
                    self.path = saved;
                }
            },
            else => {},
        }
        return null;
    }
};

test "operation schema compiler preserves absent and normalized descriptors" {
    const raw = .{ .arguments = .{ .tuple = .{} }, .result = .nil };
    const normalized = comptime try compile(raw);
    try std.testing.expectEqual(@as(usize, 0), normalized.arity());
    try std.testing.expectEqualStrings("093888d5a5a8dcd8ae15d8be9738039d0d026a2d26674bce7574c22907a91234", &std.fmt.bytesToHex(normalized.digest(), .lower));
    try std.testing.expectEqual(@as(?*const Contract, null), try operationContract(.{}));
    try std.testing.expectEqual(@as(?*const Contract, null), try operationContract(.{ .contract = null }));
    try std.testing.expectEqual(@as(?*const Contract, null), try operationContract(.{ .contract = @as(?*const Contract, null) }));
    const from_literal = comptime (try operationContract(.{ .contract = raw })).?;
    const again = (try operationContract(.{ .contract = from_literal })).?;
    try std.testing.expectEqualSlices(u8, &normalized.digest(), &again.digest());
    try std.testing.expectError(error.InvalidEffectContract, operationContract(.{ .contract = .{ .arguments = .nil, .result = .nil } }));
    const saved = comptime blk: {
        var original = try compile(raw);
        const copy = (try operationContract(.{ .contract = &original })).?;
        original.roots[0] = 1000;
        break :blk copy;
    };
    try std.testing.expectEqual(@as(usize, 0), saved.arity());
    try std.testing.expectEqualSlices(u8, &normalized.digest(), &saved.digest());
    const malformed = comptime blk: {
        var original = try compile(raw);
        original.roots[0] = 1000;
        break :blk original;
    };
    try std.testing.expectError(error.InvalidEffectContract, operationContract(.{ .contract = &malformed }));
}

test "operation schema digest normalizes object and enum order but binds semantic changes" {
    const text = .{ .string = .{ .min_bytes = 1, .max_bytes = 64 } };
    const first = comptime try compile(.{
        .arguments = .{ .tuple = .{text} },
        .result = .{ .object = .{ .{ .name = "b", .schema = .integer }, .{ .name = "a", .schema = text, .optional = true } } },
        .rejection = .{ .codes = .{ "Busy", "Missing" }, .max_message_bytes = 128 },
    });
    const reordered = comptime try compile(.{
        .arguments = .{ .tuple = .{text} },
        .result = .{ .object = .{ .{ .name = "a", .schema = text, .optional = true }, .{ .name = "b", .schema = .integer } } },
        .rejection = .{ .codes = .{ "Missing", "Busy" }, .max_message_bytes = 128 },
    });
    try std.testing.expectEqualSlices(u8, &first.digest(), &reordered.digest());
    const shape = .{ .arguments = .{ .tuple = .{.{ .integer = .{ .min = 1, .max = 100 } }} }, .result = .nil };
    const changed = .{ .arguments = .{ .tuple = .{.{ .integer = .{ .min = 1, .max = 101 } }} }, .result = .nil };
    const a = comptime try compile(shape);
    const b = comptime try compile(changed);
    try std.testing.expect(!std.mem.eql(u8, &a.digest(), &b.digest()));
    try std.testing.expectEqual(@as(usize, 1), a.arity());
}

test "operation schema compiler rejects malformed literals and budget excess" {
    inline for (.{
        .{},
        .{ .arguments = .integer, .result = .nil },
        .{ .arguments = .{ .tuple = .{} }, .result = .wat },
        .{ .arguments = .{ .tuple = .{} }, .result = .nil, .unknown = 1 },
        .{ .arguments = .{ .tuple = .{} }, .result = .{ .integer = .{ .min = 3, .max = 2 } } },
        .{ .arguments = .{ .tuple = .{} }, .result = .{ .integer = .{ .min = "bad" } } },
        .{ .arguments = .{ .tuple = .{} }, .result = .{ .string = .{} } },
        .{ .arguments = .{ .tuple = .{} }, .result = .{ .string = .{ .max_bytes = -1 } } },
        .{ .arguments = .{ .tuple = .{} }, .result = .{ .array = .{ .element = .nil, .min_items = 2, .max_items = 1 } } },
        .{ .arguments = .{ .tuple = .{} }, .result = .{ .object = .{ .{ .name = "same", .schema = .integer }, .{ .name = "same", .schema = .nil } } } },
        .{ .arguments = .{ .tuple = .{} }, .result = .{ .object = .{.{ .name = "", .schema = .integer }} } },
        .{ .arguments = .{ .tuple = .{} }, .result = .{ .object = .{.{ .name = "value", .schema = .integer, .optional = 1 }} } },
        .{ .arguments = .{ .tuple = .{} }, .result = .{ .object = .{.{ .name = @as(*const [129]u8, &@as([129]u8, @splat('x'))), .schema = .integer }} } },
        .{ .arguments = .{ .tuple = .{} }, .result = .{ .enum_string = .{} } },
        .{ .arguments = .{ .tuple = .{} }, .result = .nil, .rejection = .{ .codes = .{ "Same", "Same" }, .max_message_bytes = 1 } },
        .{ .arguments = .{ .tuple = .{} }, .result = .nil, .rejection = .{ .codes = .{""}, .max_message_bytes = 1 } },
        .{ .arguments = .{ .tuple = .{} }, .result = .nil, .rejection = .{ .codes = .{"A"} } },
    }) |literal| try std.testing.expectError(error.InvalidEffectContract, compile(literal));
    const many = comptime blk: {
        const types: [max_nodes]type = @splat(@TypeOf(.nil));
        var values: @Tuple(&types) = undefined;
        for (0..max_nodes) |i| values[i] = .nil;
        break :blk values;
    };
    const too_many = .{ .arguments = .{ .tuple = .{} }, .result = .{ .tuple = many } };
    try std.testing.expectError(error.InvalidEffectContract, compile(too_many));
}

test "normalized schema DAGs retain identity while rejecting exponential hash expansion" {
    const pair = .{ .tuple = .{ .integer, .integer } };
    const expanded = try compileShape(.{ .tuple = .{ pair, pair } });
    var shared = expanded;
    const root = shared.graph.nodes[shared.graph.roots[0]];
    shared.graph.edges[root.first + 1].child = shared.graph.edges[root.first].child;
    const accepted = try shared.checkedCopy();
    try std.testing.expectEqualSlices(u8, &expanded.digest(), &accepted.digest());

    var exponential = try compileShape(.integer);
    exponential.graph.node_count = 31;
    exponential.graph.edge_count = 60;
    exponential.graph.roots = @splat(30);
    for (1..31) |id| {
        const first: u16 = @intCast((id - 1) * 2);
        exponential.graph.nodes[id] = .{ .kind = .tuple, .first = first, .count = 2 };
        exponential.graph.edges[first] = .{ .child = @intCast(id - 1) };
        exponential.graph.edges[first + 1] = .{ .child = @intCast(id - 1) };
    }
    // Never call digest on unchecked data. This 31-node DAG would otherwise
    // expand into billions of recursive visits before any guest execution.
    try std.testing.expectError(error.InvalidEffectContract, exponential.checkedCopy());
}
