//! Auditable authority vocabulary shared by build selection and sandbox policy.
//!
//! The build-time manifest answers which kinds of authority linked code can
//! expose. The policy inventories below answer which Ruby entry points the
//! restricted in-process profile removes or freezes. Keeping both declarations
//! here makes changes reviewable without reconstructing them from build logic
//! and scattered string literals.

const std = @import("std");

/// Authority a linked source can expose to Ruby code. These are conservative
/// labels, not claims that the corresponding capability is automatically
/// granted by every policy.
pub const Kind = enum(u4) {
    filesystem = 0,
    network = 1,
    process = 2,
    environment = 3,
    clock = 4,
    entropy = 5,
    dynamic_code = 6,
    dynamic_dispatch = 7,
    introspection = 8,
    heap_enumeration = 9,
    model_mutation = 10,
    continuations = 11,
    native_host = 12,
    host_output = 13,
};

/// Compact set of `Kind` values. The integer representation is deliberately
/// stable so the build can serialize it through generated options.
pub const Set = struct {
    bits: u16 = 0,

    pub const empty: Set = .{};

    pub fn init(kinds: []const Kind) Set {
        var result: Set = .{};
        for (kinds) |kind| result.bits |= bit(kind);
        return result;
    }

    pub fn fromBits(bits: u16) Set {
        return .{ .bits = bits };
    }

    pub fn toBits(set: Set) u16 {
        return set.bits;
    }

    pub fn has(set: Set, kind: Kind) bool {
        return set.bits & bit(kind) != 0;
    }

    pub fn unionWith(set: Set, other: Set) Set {
        return .{ .bits = set.bits | other.bits };
    }

    pub fn intersects(set: Set, other: Set) bool {
        return set.bits & other.bits != 0;
    }

    /// Whether this authority set is eligible for the bundled generic worker.
    /// Clock and entropy remain visible sources of nondeterminism, but do not
    /// themselves expose host assets or process control and can be policy-pinned.
    /// Unknown/future bits are ineligible until explicitly reviewed here.
    pub fn workerEligible(set: Set) bool {
        return set.bits & ~worker_allowed.bits == 0;
    }

    fn bit(kind: Kind) u16 {
        return @as(u16, 1) << @intCast(@backingInt(kind));
    }
};

/// Authorities that make the generic worker ineligible unless the build owner
/// explicitly opts in. `native_host` means an API that can escape to arbitrary
/// host-native behavior, not merely an implementation written in C.
pub const worker_forbidden = Set.init(&.{
    .filesystem,
    .network,
    .process,
    .environment,
    .native_host,
});

/// Authorities admitted by the bundled generic worker. This allow-list makes
/// the decision fail closed when the vocabulary gains a new kind.
pub const worker_allowed = Set.init(&.{
    .clock,
    .entropy,
    .dynamic_code,
    .dynamic_dispatch,
    .introspection,
    .heap_enumeration,
    .model_mutation,
    .continuations,
    // The generic helper redirects stdout before VM startup, so core print/p
    // cannot corrupt its private protocol or write to the parent's stdout.
    .host_output,
});

pub const WorkerDecision = struct {
    profile_eligible: bool,
    ambient_authority_opt_in: bool,
    enabled: bool,
};

/// Resolve the complete worker gate in one auditable place. The opt-in bit is
/// only recorded when it changes the profile decision; it is never enough to
/// enable a worker on an unsupported target.
pub fn workerDecision(
    available: Set,
    target_supported: bool,
    allow_ambient_authority: bool,
) WorkerDecision {
    const profile_eligible = available.workerEligible();
    const ambient_authority_opt_in = allow_ambient_authority and
        !profile_eligible;
    return .{
        .profile_eligible = profile_eligible,
        .ambient_authority_opt_in = ambient_authority_opt_in,
        .enabled = target_supported and
            (profile_eligible or ambient_authority_opt_in),
    };
}

pub const Source = struct {
    name: []const u8,
    authority: Set,
};

pub const Manifest = struct {
    aggregate: Set,
    sources: []const Source,

    pub fn find(manifest: Manifest, name: []const u8) ?Source {
        for (manifest.sources) |source| {
            if (std.mem.eql(u8, source.name, name)) return source;
        }
        return null;
    }

    pub fn has(manifest: Manifest, kind: Kind) bool {
        return manifest.aggregate.has(kind);
    }

    pub fn workerEligible(manifest: Manifest) bool {
        return manifest.aggregate.workerEligible();
    }
};

pub fn aggregate(sources: []const Source) Set {
    var result: Set = .{};
    for (sources) |source| result = result.unionWith(source.authority);
    return result;
}

/// Language-level policy gate associated with an audited restriction.
pub const PolicyGate = enum {
    eval,
    send,
    introspection,
    object_space,
};

pub const MethodKind = enum { instance, class };

pub const MethodRestriction = struct {
    gate: PolicyGate,
    owner: []const u8,
    name: []const u8,
    kind: MethodKind = .instance,
};

/// Every method masked by the deny-by-default capability floor. Entries are
/// target-specific because masking only an ancestor can leave another lookup
/// path live (notably BasicObject's eval and dispatch methods).
pub const restricted_methods = [_]MethodRestriction{
    .{ .gate = .eval, .owner = "Kernel", .name = "eval" },
    .{ .gate = .eval, .owner = "Kernel", .name = "binding" },
    .{ .gate = .eval, .owner = "Kernel", .name = "instance_eval" },
    .{ .gate = .eval, .owner = "Kernel", .name = "instance_exec" },
    .{ .gate = .eval, .owner = "BasicObject", .name = "instance_eval" },
    .{ .gate = .eval, .owner = "BasicObject", .name = "instance_exec" },
    .{ .gate = .eval, .owner = "Module", .name = "class_eval" },
    .{ .gate = .eval, .owner = "Module", .name = "module_eval" },
    .{ .gate = .eval, .owner = "Module", .name = "class_exec" },
    .{ .gate = .eval, .owner = "Module", .name = "module_exec" },
    .{ .gate = .eval, .owner = "Binding", .name = "eval" },

    .{ .gate = .send, .owner = "Kernel", .name = "send" },
    .{ .gate = .send, .owner = "Kernel", .name = "public_send" },
    .{ .gate = .send, .owner = "BasicObject", .name = "__send__" },

    .{ .gate = .introspection, .owner = "Kernel", .name = "global_variables" },
    .{ .gate = .introspection, .owner = "Kernel", .name = "local_variables" },
    .{ .gate = .introspection, .owner = "Kernel", .name = "singleton_class" },
    .{ .gate = .introspection, .owner = "Kernel", .name = "instance_variable_get" },
    .{ .gate = .introspection, .owner = "Kernel", .name = "instance_variable_set" },
    .{ .gate = .introspection, .owner = "Kernel", .name = "instance_variables" },
    .{ .gate = .introspection, .owner = "Kernel", .name = "instance_variable_defined?" },
    .{ .gate = .introspection, .owner = "Kernel", .name = "remove_instance_variable" },
    .{ .gate = .introspection, .owner = "Kernel", .name = "methods" },
    .{ .gate = .introspection, .owner = "Kernel", .name = "private_methods" },
    .{ .gate = .introspection, .owner = "Kernel", .name = "protected_methods" },
    .{ .gate = .introspection, .owner = "Kernel", .name = "public_methods" },
    .{ .gate = .introspection, .owner = "Kernel", .name = "singleton_methods" },
    .{ .gate = .introspection, .owner = "Kernel", .name = "method" },
    .{ .gate = .introspection, .owner = "Kernel", .name = "singleton_method" },
    .{ .gate = .introspection, .owner = "Kernel", .name = "caller" },
    .{ .gate = .introspection, .owner = "Kernel", .name = "__method__" },
    .{ .gate = .introspection, .owner = "Kernel", .name = "__callee__" },

    .{ .gate = .introspection, .owner = "Module", .name = "class_variables" },
    .{ .gate = .introspection, .owner = "Module", .name = "remove_class_variable" },
    .{ .gate = .introspection, .owner = "Module", .name = "class_variable_defined?" },
    .{ .gate = .introspection, .owner = "Module", .name = "class_variable_get" },
    .{ .gate = .introspection, .owner = "Module", .name = "class_variable_set" },
    .{ .gate = .introspection, .owner = "Module", .name = "included_modules" },
    .{ .gate = .introspection, .owner = "Module", .name = "instance_methods" },
    .{ .gate = .introspection, .owner = "Module", .name = "public_instance_methods" },
    .{ .gate = .introspection, .owner = "Module", .name = "private_instance_methods" },
    .{ .gate = .introspection, .owner = "Module", .name = "protected_instance_methods" },
    .{ .gate = .introspection, .owner = "Module", .name = "undefined_instance_methods" },
    .{ .gate = .introspection, .owner = "Module", .name = "constants" },
    .{ .gate = .introspection, .owner = "Module", .name = "instance_method" },
    .{ .gate = .introspection, .owner = "Module", .name = "name" },
    .{ .gate = .introspection, .owner = "Module", .name = "singleton_class?" },
    .{ .gate = .introspection, .owner = "Module", .name = "constants", .kind = .class },
    .{ .gate = .introspection, .owner = "Module", .name = "nesting", .kind = .class },

    .{ .gate = .introspection, .owner = "Class", .name = "superclass" },
    .{ .gate = .introspection, .owner = "Class", .name = "attached_object" },
    .{ .gate = .object_space, .owner = "Class", .name = "subclasses" },
    .{ .gate = .object_space, .owner = "ObjectSpace", .name = "count_objects", .kind = .class },
    .{ .gate = .object_space, .owner = "ObjectSpace", .name = "each_object", .kind = .class },
    .{ .gate = .introspection, .owner = "Symbol", .name = "all_symbols", .kind = .class },
    .{ .gate = .introspection, .owner = "Proc", .name = "parameters" },
    .{ .gate = .introspection, .owner = "Proc", .name = "source_location" },

    .{ .gate = .introspection, .owner = "Binding", .name = "local_variable_defined?" },
    .{ .gate = .introspection, .owner = "Binding", .name = "local_variable_get" },
    .{ .gate = .introspection, .owner = "Binding", .name = "local_variable_set" },
    .{ .gate = .introspection, .owner = "Binding", .name = "local_variables" },
    .{ .gate = .introspection, .owner = "Binding", .name = "receiver" },
    .{ .gate = .introspection, .owner = "Binding", .name = "source_location" },
};

/// Method target used by deterministic capability hardening after the trusted
/// seed/time value has been installed.
pub const DeterminismMethod = struct {
    owner: []const u8,
    name: []const u8,
    kind: MethodKind = .instance,
};

pub const random_reseed_methods = [_]DeterminismMethod{
    .{ .owner = "Kernel", .name = "srand" },
    .{ .owner = "Random", .name = "srand", .kind = .class },
    .{ .owner = "Random", .name = "new", .kind = .class },
    .{ .owner = "Random", .name = "allocate", .kind = .class },
    .{ .owner = "Random", .name = "initialize" },
    .{ .owner = "Random", .name = "srand" },
};

/// Constructors that can read the current wall clock even after `Time.now`
/// has been replaced. Explicit-value constructors such as `Time.at`,
/// `Time.gm`, and `Time.local` remain available.
pub const clock_read_methods = [_]DeterminismMethod{
    .{ .owner = "Time", .name = "new", .kind = .class },
    .{ .owner = "Time", .name = "allocate", .kind = .class },
    .{ .owner = "Time", .name = "initialize" },
};

pub const ConstantRestriction = struct {
    gate: PolicyGate,
    owner: []const u8,
    name: []const u8,
};

pub const restricted_constants = [_]ConstantRestriction{
    .{ .gate = .object_space, .owner = "Object", .name = "ObjectSpace" },
};

/// Core classes and modules frozen by `freeze_object_model` / `sealModel`.
/// Missing entries are tolerated for trimmed gem configurations.
pub const frozen_classes = [_][]const u8{
    "BasicObject",    "Object",            "Module",
    "Class",          "Kernel",            "Comparable",
    "Enumerable",     "NilClass",          "TrueClass",
    "FalseClass",     "Numeric",           "Integer",
    "Float",          "String",            "Symbol",
    "Array",          "Hash",              "Range",
    "Proc",           "Struct",            "Data",
    "Exception",      "StandardError",     "RuntimeError",
    "ArgumentError",  "TypeError",         "NameError",
    "NoMethodError",  "IndexError",        "KeyError",
    "RangeError",     "ZeroDivisionError", "FrozenError",
    "StopIteration",  "ScriptError",       "NotImplementedError",
    "LocalJumpError",
};

test "authority sets aggregate and gate workers" {
    const sources = [_]Source{
        .{ .name = "core", .authority = Set.init(&.{.dynamic_dispatch}) },
        .{ .name = "clock", .authority = Set.init(&.{ .clock, .entropy }) },
    };
    const safe = aggregate(&sources);
    try std.testing.expect(safe.has(.dynamic_dispatch));
    try std.testing.expect(safe.has(.clock));
    try std.testing.expect(safe.workerEligible());

    const unsafe = safe.unionWith(Set.init(&.{.filesystem}));
    try std.testing.expect(!unsafe.workerEligible());
    try std.testing.expect(!Set.fromBits(@as(u16, 1) << 15).workerEligible());

    inline for (std.enums.values(Kind)) |kind| {
        try std.testing.expect(worker_allowed.has(kind) != worker_forbidden.has(kind));
    }

    const ordinary = workerDecision(safe, true, false);
    try std.testing.expect(ordinary.profile_eligible);
    try std.testing.expect(!ordinary.ambient_authority_opt_in);
    try std.testing.expect(ordinary.enabled);

    const blocked = workerDecision(unsafe, true, false);
    try std.testing.expect(!blocked.profile_eligible);
    try std.testing.expect(!blocked.ambient_authority_opt_in);
    try std.testing.expect(!blocked.enabled);

    const acknowledged = workerDecision(unsafe, true, true);
    try std.testing.expect(!acknowledged.profile_eligible);
    try std.testing.expect(acknowledged.ambient_authority_opt_in);
    try std.testing.expect(acknowledged.enabled);

    const unsupported = workerDecision(unsafe, false, true);
    try std.testing.expect(unsupported.ambient_authority_opt_in);
    try std.testing.expect(!unsupported.enabled);
}

test "audited policy inventories contain no duplicate targets" {
    for (restricted_methods, 0..) |entry, i| {
        for (restricted_methods[0..i]) |earlier| {
            try std.testing.expect(!(entry.gate == earlier.gate and
                std.mem.eql(u8, entry.owner, earlier.owner) and
                std.mem.eql(u8, entry.name, earlier.name) and
                entry.kind == earlier.kind));
        }
    }
    for (frozen_classes, 0..) |name, i| {
        for (frozen_classes[0..i]) |earlier| {
            try std.testing.expect(!std.mem.eql(u8, name, earlier));
        }
    }
    for (random_reseed_methods, 0..) |entry, i| {
        for (random_reseed_methods[0..i]) |earlier| {
            try std.testing.expect(!(std.mem.eql(u8, entry.owner, earlier.owner) and
                std.mem.eql(u8, entry.name, earlier.name) and
                entry.kind == earlier.kind));
        }
    }
    for (clock_read_methods, 0..) |entry, i| {
        for (clock_read_methods[0..i]) |earlier| {
            try std.testing.expect(!(std.mem.eql(u8, entry.owner, earlier.owner) and
                std.mem.eql(u8, entry.name, earlier.name) and
                entry.kind == earlier.kind));
        }
    }
}
