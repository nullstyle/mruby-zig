//! GC arena scopes.
//!
//! Any `mrb_value` holding a heap object that you keep across calls into the
//! interpreter must be rooted, or the GC may collect it mid-flight. The
//! standard pattern (used by mruby itself) is to save the arena index,
//! operate, then restore it:
//!
//!     var scope = vm.arenaScope();
//!     defer scope.restore();
//!     ...hold Values here...
//!
//! `restore` shrinks the arena back to the saved index, so allocate the
//! scope at the outermost point that holds Ruby objects. Use `Vm.root` when a
//! value must outlive that scope.

const std = @import("std");
const c = @import("c.zig");
const value_mod = @import("value.zig");

pub const Value = value_mod.Value;

pub const RootError = error{
    ForeignValue,
    OutOfMemory,
    RubyException,
    TooManyRoots,
};

pub const Scope = struct {
    mrb: *c.mrb_state,
    idx: c_int,

    pub fn restore(self: Scope) void {
        c.mrz_gc_arena_restore(self.mrb, self.idx);
    }
};

/// An explicitly long-lived Ruby value. A root keeps its value alive across GC
/// arena restoration and collection until `deinit` is called.
///
/// Like other Zig-owned resources, a `RootedValue` has one logical owner and
/// must not be copied. It must be destroyed before its `Vm`.
pub const RootedValue = struct {
    registry: *RootRegistry,
    inner: Value,
    active: bool = true,

    /// Borrow the rooted value for a safe-layer operation. The returned handle
    /// is valid while this root (or another root/Ruby reference) keeps it alive.
    pub fn get(root: *const RootedValue) Value {
        if (!root.active) @panic("mruby-zig: use of a released RootedValue");
        return root.inner;
    }

    pub fn deinit(root: *RootedValue) void {
        if (!root.active) @panic("mruby-zig: RootedValue.deinit called twice");
        root.registry.release(root.inner);
        root.active = false;
    }
};

/// Per-VM implementation behind `Vm.root`. mruby's `mrb_gc_unregister`
/// removes every registration for the same object, so duplicate roots must be
/// reference-counted here to give each `RootedValue` an independent lifetime.
pub const RootRegistry = struct {
    allocator: std.mem.Allocator,
    mrb: *c.mrb_state,
    references: std.AutoHashMapUnmanaged(*anyopaque, usize) = .empty,
    handle_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, mrb: *c.mrb_state) RootRegistry {
        return .{ .allocator = allocator, .mrb = mrb };
    }

    pub fn deinit(registry: *RootRegistry) void {
        if (registry.handle_count != 0) {
            @panic("mruby-zig: Vm.deinit called with live RootedValues");
        }
        std.debug.assert(registry.references.count() == 0);
        registry.references.deinit(registry.allocator);
    }

    pub fn add(registry: *RootRegistry, value: Value) RootError!RootedValue {
        try value.ensureOwnedBy(registry.mrb);
        if (registry.handle_count == std.math.maxInt(usize))
            return error.TooManyRoots;

        if (c.mrz_ptr(value.v)) |identity| {
            const entry = try registry.references.getOrPut(registry.allocator, identity);
            if (entry.found_existing) {
                if (entry.value_ptr.* == std.math.maxInt(usize))
                    return error.TooManyRoots;
                entry.value_ptr.* += 1;
            } else {
                entry.value_ptr.* = 0;
                errdefer std.debug.assert(registry.references.remove(identity));
                if (!c.mrz_protected_gc_register(registry.mrb, value.v))
                    return error.RubyException;
                entry.value_ptr.* = 1;
            }
        }

        registry.handle_count += 1;
        return .{ .registry = registry, .inner = value };
    }

    fn release(registry: *RootRegistry, value: Value) void {
        if (registry.handle_count == 0)
            @panic("mruby-zig: corrupt RootedValue registry");

        if (c.mrz_ptr(value.v)) |identity| {
            const count = registry.references.getPtr(identity) orelse
                @panic("mruby-zig: released value is not rooted");
            if (count.* == 1) {
                c.mrz_gc_unregister(registry.mrb, value.v);
                std.debug.assert(registry.references.remove(identity));
            } else {
                std.debug.assert(count.* > 1);
                count.* -= 1;
            }
        }

        registry.handle_count -= 1;
    }
};
