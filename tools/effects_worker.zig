//! Dedicated application worker: embed code and descriptors, never host adapters.
const std = @import("std");
const mruby = @import("mruby");
const manifest = @import("worker_manifest");
const contract = @import("worker_contract");

comptime {
    if (!mruby.features.effects_worker_supported)
        @compileError("application effect workers require a supported -Deffects-strict=true build");
}

pub fn main(init: std.process.Init) !u8 {
    const turn_contract = comptime mruby.strict.Worker.Runtime.contractFromModule(contract) catch @compileError("invalid application turn contract");
    return mruby.strict.Worker.Runtime.serveWithContract(init, manifest, contract.operations, turn_contract);
}
