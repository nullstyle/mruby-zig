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
const authority_types = @import("authority_manifest");

pub const AuthorityKind = authority_types.Kind;
pub const AuthoritySet = authority_types.Set;
pub const AuthoritySource = authority_types.Source;
pub const AuthorityManifest = authority_types.Manifest;

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

const authority_sources = blk: {
    if (config.authority_source_names.len != config.authority_source_bits.len) {
        @compileError("authority source names and masks disagree");
    }
    var result: [config.authority_source_names.len]AuthoritySource = undefined;
    for (&result, 0..) |*source, i| {
        source.* = .{
            .name = config.authority_source_names[i],
            .authority = AuthoritySet.fromBits(config.authority_source_bits[i]),
        };
    }
    break :blk result;
};

/// Conservative authority exposed by core, compiler, and every selected gem,
/// with per-source attribution. This is linked/available authority; a sandbox
/// policy can remove some language entry points before guest execution.
pub const authority: AuthorityManifest = .{
    .aggregate = AuthoritySet.fromBits(config.authority_bits),
    .sources = &authority_sources,
};

/// Authority attributed to one selected gem, or null when it is not linked.
pub fn authorityForGem(name: []const u8) ?AuthoritySet {
    if (!hasGem(name)) return null;
    const source = authority.find(name) orelse return null;
    return source.authority;
}

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

/// Whether the target can host the bundled one-shot worker before considering
/// the selected authority profile.
pub const worker_target_supported: bool = config.worker_target_supported;

/// Whether the selected core/gem profile contains no authority that can access
/// host assets or process control through the generic worker.
pub const worker_profile_eligible: bool = config.worker_profile_eligible;

/// True only when an ineligible profile was explicitly enabled with
/// `-Dallow-worker-ambient-authority=true`.
pub const worker_ambient_authority_opt_in: bool =
    config.worker_ambient_authority_opt_in;

/// Whether the bundled one-shot worker artifact and controller are enabled.
/// This combines target support with the fail-closed authority decision made
/// by the build graph.
pub const worker_process_supported: bool = config.worker_process_supported;

comptime {
    if (sandbox_supported and @bitSizeOf(usize) != pointer_bits) {
        @compileError("features.sandbox_supported disagrees with the compiled target");
    }
    if (worker_process_supported and !worker_target_supported) {
        @compileError("worker enabled on an unsupported target");
    }
    if (worker_process_supported and !worker_profile_eligible and
        !worker_ambient_authority_opt_in)
    {
        @compileError("worker authority gate was bypassed without explicit opt-in");
    }
}
