//! mruby-zig: embed mruby 4.0 in Zig applications.
//!
//! One `zig build` fetches mruby, generates its presym tables and core
//! bytecode, compiles everything with `zig cc`, and links it into this
//! module. No Ruby toolchain is needed at build time.
//!
//! ```
//! const mruby = @import("mruby");
//!
//! var vm = try mruby.Vm.init();
//! defer vm.deinit();
//! const result = try vm.loadString("2 + 2");
//! try std.testing.expectEqual(@as(i64, 4), try result.asInt());
//! ```

pub const Vm = @import("vm.zig").Vm;
pub const Value = @import("value.zig").Value;
pub const RubyError = @import("error.zig").RubyError;
pub const Class = @import("class.zig").Class;
pub const Rest = @import("class.zig").Rest;
pub const Scope = @import("arena.zig").Scope;
pub const data = @import("data.zig");
pub const output = @import("output.zig");
pub const convert = @import("convert.zig");
pub const alloc = @import("alloc.zig");

/// Raw C bindings + shim; public for power users, but the safe layer above
/// is the supported surface.
pub const c = @import("c.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("vm.zig");
    _ = @import("value.zig");
    _ = @import("error.zig");
    _ = @import("class.zig");
    _ = @import("convert.zig");
    _ = @import("alloc.zig");
}
