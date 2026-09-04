//! Comptime view of the package's build configuration.
//!
//! Everything here is a compile-time constant derived from the resolved
//! build (gem selection, target, vendored mruby identity), so applications
//! can branch with ordinary `comptime` conditionals instead of duplicating
//! build knowledge or discovering features at runtime:
//!
//!     const mruby = @import("mruby");
//!
//!     comptime {
//!         if (!mruby.features.sandbox_supported)
//!             @compileError("this application requires the sandbox tier");
//!     }
//!
//!     if (mruby.features.hasGem("mruby-time")) {
//!         _ = try vm.loadString("puts Time.now");
//!     } else {
//!         _ = try vm.loadString("puts 'no clock'");
//!     }
//!
//! The manifest is generated per build: `-Dgem-set`, `-Dwith-gems`, and
//! `-Dwithout-gems` change `gems`/`gem_set`/`custom_selection`, and the
//! compatibility identity follows the presym table and target traits.

const std = @import("std");

const config = @import("build_features");
const artifact_config = @import("artifact_config");

/// Gems linked into this build, in dependency-respecting initialization
/// order (dependencies first). Core mruby and the compiler are always
/// present and are not listed as gems.
pub const gems: []const []const u8 = config.gems;

/// Whether `name` is part of this build's gem selection. Callable at
/// comptime and at runtime.
pub fn hasGem(name: []const u8) bool {
    for (gems) |gem| {
        if (std.mem.eql(u8, gem, name)) return true;
    }
    return false;
}

/// Requested preset: "standard" or "minimal".
pub const gem_set: []const u8 = config.gem_set;

/// True when `-Dwith-gems` or `-Dwithout-gems` customized the selection,
/// meaning `gem_set` alone does not describe the linked gems.
pub const custom_selection: bool = config.custom_selection;

/// Version of the vendored mruby this package builds.
pub const mruby_version: []const u8 = config.mruby_version;

/// RITE compatibility identity of this build. Compiled artifacts (RITE
/// images, state capsules) are only admissible across builds whose
/// fingerprint matches exactly.
pub const rite_compatibility_fingerprint: [32]u8 =
    artifact_config.rite_compatibility_fingerprint;
/// Lowercase hex spelling of `rite_compatibility_fingerprint`.
pub const rite_compatibility_fingerprint_hex: []const u8 =
    artifact_config.rite_compatibility_fingerprint_hex;
/// Bumped when this package changes an artifact format in a way that
/// should reject all previously produced artifacts.
pub const rite_compatibility_epoch: u32 = artifact_config.rite_compatibility_epoch;
/// RITE binary format version string (upstream).
pub const rite_binary_version: []const u8 = artifact_config.rite_binary_version;
/// RITE VM instruction-set version string (upstream).
pub const rite_vm_version: []const u8 = artifact_config.rite_vm_version;

/// Target pointer width this library was built for. The package currently
/// requires 64-bit targets (enforced by the C ABI shim).
pub const pointer_bits: u16 = config.pointer_bits;

/// Target byte order, from the compiling target.
pub const endian: std.builtin.Endian = @import("builtin").target.cpu.arch.endian();

/// The instruction-level debug hook (`MRB_USE_DEBUG_HOOK`) is compiled in.
/// The sandbox's gas/deadline/termination machinery is built on it.
pub const has_debug_hook: bool = true;

/// The mruby compiler (parser + codegen) is linked in, so `Vm.loadString`
/// and the RITE compilers are available. Always true today; a future
/// runtime-only profile would set this false.
pub const has_compiler: bool = true;

/// Whether the sandboxing tier is usable in this build: the debug hook
/// must be compiled in and the target must satisfy the ABI constraint.
pub const sandbox_supported: bool = has_debug_hook and pointer_bits == 64;

comptime {
    if (sandbox_supported and @bitSizeOf(usize) != pointer_bits) {
        @compileError("features.sandbox_supported disagrees with the compiled target");
    }
}
