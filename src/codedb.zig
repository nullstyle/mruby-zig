//! CodeDB runtime surface (phase 1): lookup over an embedded manifest of
//! build-compiled artifacts, executed through the normal policy path.
//!
//! The manifest module is generated at build time (tools/rite_envelope.zig
//! over host-mrbc output); import it anonymously and pass it here. See
//! docs/plans/codedb.md.

const std = @import("std");
const artifact_mod = @import("artifact.zig");
const sandbox_mod = @import("sandbox.zig");

/// Resolve `name` in a generated manifest module (any type whose
/// `entries` is a comptime array of `{ name, bytes }` records).
pub fn find(manifest: anytype, name: []const u8) ?artifact_mod.RiteImageView {
    inline for (manifest.entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return .{ .bytes = entry.bytes };
    }
    return null;
}

/// Execute a manifest entry under the isolate's policy. Unknown names are
/// `error.UnknownArtifact`; admission failures follow `runRite`.
pub fn run(iso: sandbox_mod.Isolate, manifest: anytype, name: []const u8) !sandbox_mod.Value {
    const view = find(manifest, name) orelse return error.UnknownArtifact;
    return iso.runRite(view);
}
