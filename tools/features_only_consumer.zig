//! Downstream-link regression fixture.
//!
//! This executable deliberately reads only build metadata from `mruby`. The
//! module must still contribute its C dependencies and required Zig exports.

const mruby = @import("mruby");

comptime {
    if (!mruby.features.authority.has(.host_output))
        @compileError("mruby core authority is missing");
}

pub fn main() void {}
