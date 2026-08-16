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
//! scope at the outermost point that holds Ruby objects.

const c = @import("c.zig");

pub const Scope = struct {
    mrb: *c.mrb_state,
    idx: c_int,

    pub fn restore(self: Scope) void {
        c.mrz_gc_arena_restore(self.mrb, self.idx);
    }
};
