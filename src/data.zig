//! Wrapping Zig values in Ruby objects.
//!
//! `DataType` produces a Ruby-visible wrapper (an `RData` object) around a
//! Zig pointer, so Ruby scripts can hold and pass around Zig-owned state:
//!
//!     const Conn = mruby.data.DataType(ConnState, "Conn", ConnState.destroy);
//!     const cls = try vm.defineClass("Conn", null);
//!     const obj = try Conn.wrap(cls, state_ptr); // Ruby Value
//!     const back = Conn.unwrap(obj).?;           // *ConnState
//!
//! If `destroy` is non-null it runs when the Ruby object is garbage
//! collected. Pointers passed to `wrap` must stay valid until then; the
//! lifetime is Ruby's, so prefer heap-allocated state.

const c = @import("c.zig");
const value_mod = @import("value.zig");
const class_mod = @import("class.zig");

pub const Value = value_mod.Value;
pub const Class = class_mod.Class;

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

        /// Wrap `ptr` as an instance of `class`. Taking a `Class` handle keeps
        /// the class and interpreter paired, so a foreign class pointer cannot
        /// be passed to the wrong mruby heap. Ownership of `ptr` transfers to
        /// Ruby only on success. The value is GC-rooted until the arena it was
        /// created in is restored.
        pub fn wrap(class: Class, ptr: *T) !Value {
            var value: c.mrb_value = undefined;
            if (!c.mrz_protected_data(
                class.mrb,
                class.class,
                ptr,
                &data_type,
                &value,
            ))
                return error.RubyException;
            return .{ .mrb = class.mrb, .v = value };
        }

        /// Recover the Zig pointer, or null if `v` is not a T. Never raises.
        pub fn unwrap(v: Value) ?*T {
            if (!c.mrz_data_p(v.v)) return null;
            const p = c.mrb_data_check_get_ptr(v.mrb, v.v, &data_type) orelse return null;
            return @ptrCast(@alignCast(p));
        }
    };
}
