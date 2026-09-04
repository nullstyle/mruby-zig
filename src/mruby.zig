//! mruby-zig: embed mruby 4.0 in Zig applications.
//!
//! One `zig build` fetches mruby, generates its presym tables and core
//! bytecode, compiles everything with `zig cc`, and links it into this
//! module. No Ruby toolchain is needed at build time.
//!
//! ```
//! const mruby = @import("mruby");
//!
//! const vm = try mruby.Vm.init();
//! defer vm.deinit();
//! const result = try vm.loadString("2 + 2");
//! try std.testing.expectEqual(@as(i64, 4), try result.asInt());
//! ```

pub const Vm = @import("vm.zig").Vm;
pub const Value = @import("value.zig").Value;
pub const Array = @import("value.zig").Array;
pub const Hash = @import("value.zig").Hash;
pub const HashEntry = @import("value.zig").HashEntry;
pub const RubyError = @import("error.zig").RubyError;
pub const ExceptionDetails = @import("error.zig").Details;
pub const ExceptionDetailOptions = @import("error.zig").DetailOptions;
pub const Class = @import("class.zig").Class;
pub const Rest = @import("class.zig").Rest;
pub const Block = @import("class.zig").Block;
pub const Scope = @import("arena.zig").Scope;
pub const RootedValue = @import("arena.zig").RootedValue;
pub const LoadOptions = @import("vm.zig").LoadOptions;
pub const CallOptions = @import("vm.zig").CallOptions;
pub const data = @import("data.zig");
pub const output = @import("output.zig");
pub const convert = @import("convert.zig");
pub const alloc = @import("alloc.zig");
pub const artifact = @import("artifact.zig");
pub const sandbox = @import("sandbox.zig");
pub const worker = @import("worker.zig");
pub const features = @import("features.zig");

/// Test-build-only access to private seams used by standalone fuzz targets.
/// This declaration is empty in library and executable builds.
pub const internal_test = if (@import("builtin").is_test) struct {
    pub const artifact_value = @import("artifact_value.zig");
} else struct {};

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
    _ = @import("artifact.zig");
    _ = @import("artifact_value.zig");
    _ = @import("sandbox.zig");
    _ = @import("worker.zig");
}
