//! Instruction-gas policy and generation statistics for sandbox isolates.

const std = @import("std");

pub const Policy = union(enum) {
    /// No instruction meter. `Isolate.stats().gas` is null.
    unlimited,
    /// One cumulative generation for the Isolate; exhaustion is sticky.
    per_isolate: u64,
    /// A fresh generation at each admitted outermost run, runImage, or call.
    per_execution: u64,
};

pub const Scope = enum { isolate, execution };

pub const Stats = struct {
    scope: Scope,
    /// Saturating diagnostic ID. Generation 0 is prospective; requests start
    /// at 1. It is not an authorization token.
    generation: u64,
    limit: u64,
    used: u64,
    remaining: u64,
    exhausted: bool,
    /// Every fetch observed in the generation, including bounded delivery
    /// work after the charged allowance reaches zero.
    observed_instructions: u128,
};

/// Owner-thread state for one finite gas policy. Unlimited policies do not
/// allocate a meter. Generation zero is the prospective per-execution state.
pub const Meter = struct {
    scope: Scope,
    generation: u64,
    limit: u64,
    used: u64 = 0,
    remaining: u64,
    exhausted: bool = false,
    observed_instructions: u128 = 0,
    active: bool,

    pub fn init(policy: Policy) ?Meter {
        return switch (policy) {
            .unlimited => null,
            .per_isolate => |limit| .{
                .scope = .isolate,
                .generation = 1,
                .limit = limit,
                .remaining = limit,
                .active = true,
            },
            .per_execution => |limit| .{
                .scope = .execution,
                .generation = 0,
                .limit = limit,
                .remaining = limit,
                .active = false,
            },
        };
    }

    pub fn snapshot(meter: Meter) Stats {
        return .{
            .scope = meter.scope,
            .generation = meter.generation,
            .limit = meter.limit,
            .used = meter.used,
            .remaining = meter.remaining,
            .exhausted = meter.exhausted,
            .observed_instructions = meter.observed_instructions,
        };
    }

    /// Observe a VM fetch before its opcode executes. Returns true when the
    /// finite allowance was already empty, which is when exhaustion becomes
    /// visible. Inactive generation zero observes nothing.
    pub fn observeFetch(meter: *Meter) bool {
        if (!meter.active) return false;
        meter.observed_instructions +|= 1;
        if (meter.remaining != 0) return false;
        meter.exhausted = true;
        return true;
    }

    /// Charge the fetched opcode after termination delivery checks. Keeping
    /// this separate preserves the existing hard-OOM path, which returns
    /// before gas is charged.
    pub fn chargeFetch(meter: *Meter) void {
        if (!meter.active or meter.remaining == 0) return;
        meter.remaining -= 1;
        meter.used += 1;
    }

    pub fn nextGeneration(meter: Meter) Meter {
        var next = meter;
        next.generation +|= 1;
        next.used = 0;
        next.remaining = next.limit;
        next.exhausted = false;
        next.observed_instructions = 0;
        next.active = true;
        return next;
    }

    pub fn finishGeneration(meter: *Meter) void {
        if (meter.scope == .execution) meter.active = false;
    }
};

test "maximum gas limit represents the final admitted and failing fetches" {
    const max_u64 = std.math.maxInt(u64);
    var meter = Meter.init(.{ .per_isolate = max_u64 }).?;

    // Executing maxInt(u64) VM instructions is impractical, so position the
    // private meter immediately before the boundary. The last unit is
    // admitted and charged; the following fetch observes exhaustion without
    // wrapping the wider audit count.
    meter.used = max_u64 - 1;
    meter.remaining = 1;
    meter.observed_instructions = max_u64 - 1;

    try std.testing.expect(!meter.observeFetch());
    meter.chargeFetch();
    try std.testing.expectEqual(max_u64, meter.used);
    try std.testing.expectEqual(@as(u64, 0), meter.remaining);
    try std.testing.expectEqual(@as(u128, max_u64), meter.observed_instructions);

    try std.testing.expect(meter.observeFetch());
    meter.chargeFetch();
    try std.testing.expectEqual(max_u64, meter.used);
    try std.testing.expectEqual(@as(u64, 0), meter.remaining);
    try std.testing.expectEqual(@as(u128, max_u64) + 1, meter.observed_instructions);
    try std.testing.expect(meter.exhausted);
}

test "gas generation and audit counters saturate" {
    var meter = Meter.init(.{ .per_execution = 1 }).?;
    meter.generation = std.math.maxInt(u64);
    meter.observed_instructions = std.math.maxInt(u128);
    meter.active = true;
    meter.remaining = 0;

    try std.testing.expect(meter.observeFetch());
    try std.testing.expectEqual(std.math.maxInt(u128), meter.observed_instructions);

    const next = meter.nextGeneration();
    try std.testing.expectEqual(std.math.maxInt(u64), next.generation);
    try std.testing.expectEqual(@as(u128, 0), next.observed_instructions);
    try std.testing.expect(next.active);
}
