const mruby = @import("mruby");

/// Deliberately fixed: the subprocess fixture is also a compatibility canary
/// for schema negotiation and deterministic StateCapsule bytes.
pub const schema: mruby.artifact.Schema = .{
    .id = .{
        'p', 'r', 'o', 'c', 'e', 's', 's', '-',
        'f', 'i', 'x', 't', 'u', 'r', 'e', '1',
    },
    .major = 1,
    .minor = 0,
};

/// Golden producer output. Both the standard and minimal gem builds must emit
/// these exact stable bytes on every supported host.
pub const encoded_len: usize = 337;
pub const encoded_sha256 = [_]u8{
    0x90, 0x9d, 0x6d, 0x21, 0x5e, 0xa9, 0x9f, 0xfd,
    0x22, 0xd7, 0xf3, 0x3c, 0xc6, 0x13, 0x3d, 0x32,
    0xab, 0x11, 0x9c, 0x5a, 0xfc, 0x3f, 0xd4, 0x54,
    0xa7, 0x72, 0x25, 0x97, 0x1b, 0xa9, 0x75, 0x9a,
};

pub const producer_source =
    \\shared = "a\x00b".freeze
    \\equal_but_distinct = "a\x00b".freeze
    \\cycle = []
    \\cycle << cycle
    \\mapping = {}
    \\mapping[:first] = shared
    \\mapping[:second] = shared
    \\mapping[:equal] = equal_but_distinct
    \\mapping[:cycle] = cycle
    \\mapping.default = "fallback".freeze
    \\mapping.freeze
    \\[mapping, shared, equal_but_distinct].freeze
;

pub const consumer_assertion =
    \\mapping = $restored_graph[0]
    \\$restored_graph.frozen? &&
    \\  mapping.frozen? &&
    \\  mapping.keys == [:first, :second, :equal, :cycle] &&
    \\  mapping[:first].equal?(mapping[:second]) &&
    \\  !mapping[:first].equal?(mapping[:equal]) &&
    \\  mapping[:first] == "a\x00b" &&
    \\  mapping[:first].frozen? &&
    \\  mapping[:cycle].equal?(mapping[:cycle][0]) &&
    \\  mapping[:missing] == "fallback" &&
    \\  mapping.default.frozen?
;
