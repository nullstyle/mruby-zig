//! Wrapping Zig values in Ruby objects.
//!
//! `DataType` produces a Ruby-visible wrapper (an `RData` object) around a
//! Zig pointer, so Ruby scripts can hold and pass around Zig-owned state:
//!
//!     const Conn = mruby.data.DataType(ConnState, "Conn", ConnState.destroy);
//!     const cls = try vm.defineClass("Conn", null);
//!     const obj = Conn.wrap(vm.mrb, cls.class, state_ptr); // Ruby Value
//!     const back = Conn.unwrap(vm.mrb, obj).?;             // *ConnState
//!
//! If `destroy` is non-null it runs when the Ruby object is garbage
//! collected. Pointers passed to `wrap` must stay valid until then; the
//! lifetime is Ruby's, so prefer heap-allocated state.

const std = @import("std");
const c = @import("c.zig");
const value_mod = @import("value.zig");

pub const Value = value_mod.Value;

pub fn DataType(
    comptime T: type,
    comptime type_name: [:0]const u8,
    comptime destroy: ?fn (*T) void,
) type {
    return struct {
        var data_type = c.mrb_data_type{
            .name = type_name.ptr,
            .dfree = if (destroy != null) dfreeC else null,
        };

        fn dfreeC(mrb: ?*c.mrb_state, p: ?*anyopaque) callconv(.c) void {
            _ = mrb;
            if (p) |ptr| {
                destroy.?(@ptrCast(@alignCast(ptr)));
            }
        }

        /// Wrap `ptr` as an instance of `klass`. The value is GC-rooted
        /// until the arena it was created in is restored.
        pub fn wrap(mrb: *c.mrb_state, klass: *c.RClass, ptr: *T) Value {
            // The class must accept CDATA instances (mrb_obj_alloc checks
            // the instance type; idempotent).
            c.mrz_set_instance_tt(klass, c.MRB_TT_CDATA);
            const rd = c.mrb_data_object_alloc(mrb, klass, ptr, &data_type);
            return .{ .mrb = mrb, .v = c.mrz_obj_value(@ptrCast(rd)) };
        }

        /// Recover the Zig pointer, or null if `v` is not a T. Never raises.
        pub fn unwrap(mrb: *c.mrb_state, v: Value) ?*T {
            if (!c.mrz_data_p(v.v)) return null;
            const p = c.mrb_data_check_get_ptr(mrb, v.v, &data_type) orelse return null;
            return @ptrCast(@alignCast(p));
        }
    };
}
