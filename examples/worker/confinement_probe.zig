const std = @import("std");
const process = @import("mruby").strict.Worker.Process;
extern "c" fn mrz_effect_worker_probe_authority() u8;

pub fn main(_: std.process.Init) !u8 {
    var channel = try process.Channel.child(5 * std.time.ns_per_s, 4096);
    try process.confine(5, 0);
    const result = mrz_effect_worker_probe_authority();
    try channel.writeAll(&.{result});
    return 0;
}
