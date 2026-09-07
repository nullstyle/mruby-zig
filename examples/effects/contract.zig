//! One operation catalogue shared by CodeDB authority metadata and the runtime.
//! This file intentionally has no dependency on the VM or the build interface.

pub const operations = .{
    .{
        .name = "clock.now",
        .namespace = "Clock",
        .method = "now",
        .version = @as(u32, 1),
        .arity = @as(usize, 0),
        .authority_bits = @as(u16, 1 << 4), // clock
        .max_result_bytes = @as(usize, 256),
    },
    .{
        .name = "outbox.enqueue",
        .namespace = "Outbox",
        .method = "enqueue",
        .version = @as(u32, 1),
        .arity = @as(usize, 2),
        .authority_bits = @as(u16, 1 << 13), // host_output: an owned host intent
        .max_result_bytes = @as(usize, 256),
    },
};

pub const message = "hello from effects";
