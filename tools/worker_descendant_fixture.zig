//! Test-only worker that returns a complete frame while leaving a descendant.
//!
//! The RITE image bytes are interpreted as a sentinel path. A shell in the
//! worker's inherited process group waits for the direct worker to be reaped,
//! then attempts to create that sentinel, allowing the controller tests to
//! verify whole-group cleanup. Magic images exercise nonzero exit status and a
//! helper that closes the protocol stream after a valid frame but never exits,
//! plus clean exit without a response.

const std = @import("std");
const protocol = @import("worker_protocol");

pub fn main(init: std.process.Init) !u8 {
    return run(init) catch 1;
}

fn run(init: std.process.Init) !u8 {
    var stdin_buffer: [4096]u8 = undefined;
    var stdin_file = std.Io.File.stdin().reader(init.io, &stdin_buffer);
    const reader = &stdin_file.interface;

    var request_header_bytes: [protocol.request_header_len]u8 = undefined;
    try reader.readSliceAll(&request_header_bytes);
    const request = try protocol.decodeRequest(&request_header_bytes);

    const body_len = try request.bodyLen();
    const encoded_body = try init.gpa.alloc(u8, body_len);
    defer init.gpa.free(encoded_body);
    try reader.readSliceAll(encoded_body);
    if (reader.takeByte()) |_| {
        return error.TrailingRequestBytes;
    } else |err| switch (err) {
        error.EndOfStream => {},
        error.ReadFailed => return error.RequestReadFailed,
    }

    const body = try protocol.splitRequestBody(request, encoded_body);
    const exit_nonzero = std.mem.eql(u8, body.image, "fixture:exit-nonzero");
    const frame_and_hang = std.mem.eql(u8, body.image, "fixture:frame-and-hang");
    if (std.mem.eql(u8, body.image, "fixture:exit-without-response")) return 0;
    if (!exit_nonzero and !frame_and_hang) {
        _ = try std.process.spawn(init.io, .{
            .argv = &.{
                "/bin/sh",
                "-c",
                "parent=$PPID; while kill -0 \"$parent\" 2>/dev/null; do sleep 1; done; sleep 1; : > \"$1\"",
                "worker-descendant-fixture",
                body.image,
            },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
    }

    const response = try protocol.encodeResponse(.{
        .outcome = .limit,
        .phase = .execute,
        .detail = .script_terminated,
    });
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    try stdout_file.interface.writeAll(&response);
    try stdout_file.interface.flush();
    if (frame_and_hang) {
        std.Io.File.stdout().close(init.io);
        while (true) {
            try std.Io.sleep(
                init.io,
                std.Io.Duration.fromNanoseconds(std.time.ns_per_s),
                .awake,
            );
        }
    }
    return if (exit_nonzero) 23 else 0;
}
