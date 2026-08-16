//! Calling Zig from Ruby: methods with typed arguments, blocks, and Zig
//! state wrapped in Ruby objects.
//!
//!     zig build run-host-functions

const std = @import("std");
const mruby = @import("mruby");

/// Zig state exposed to Ruby as instances of `Audio::Mixer`.
const Mixer = struct {
    volume: f64 = 1.0,
    slots: [8]i16 = @splat(0),

    fn setSlot(self: *Mixer, i: usize, v: i16) void {
        if (i < self.slots.len) self.slots[i] = v;
    }
};

const MixerData = mruby.data.DataType(Mixer, "Audio::Mixer", struct {
    fn destroy(p: *Mixer) void {
        mruby.alloc.gpa.destroy(p);
    }
}.destroy);

const MixerMethods = struct {
    var class_ptr: ?*mruby.c.RClass = null;

    fn init_(m: *mruby.Vm, self: mruby.Value) anyerror!mruby.Value {
        _ = self;
        const p = try mruby.alloc.gpa.create(Mixer);
        p.* = .{};
        return MixerData.wrap(m.mrb, class_ptr.?, p);
    }

    fn setVolume(m: *mruby.Vm, self: mruby.Value, v: f64) anyerror!mruby.Value {
        const p = MixerData.unwrap(m.mrb, self) orelse return m.raise("TypeError", "expected a Mixer");
        if (v < 0 or v > 1) return m.raise("ArgumentError", "volume must be in 0..1");
        p.volume = v;
        return m.floatValue(v);
    }

    fn mix(m: *mruby.Vm, self: mruby.Value, samples: mruby.Rest) anyerror!mruby.Value {
        const p = MixerData.unwrap(m.mrb, self) orelse return m.raise("TypeError", "expected a Mixer");
        var total: i64 = 0;
        for (0..samples.len) |i| total += try samples.get(i).asInt();
        p.setSlot(0, @intCast(@as(i64, @intFromFloat(p.volume * @as(f64, @floatFromInt(total)))) & 0xffff));
        return m.intValue(total);
    }

    fn eachSlot(m: *mruby.Vm, self: mruby.Value, blk: mruby.Value) anyerror!mruby.Value {
        const p = MixerData.unwrap(m.mrb, self) orelse return m.raise("TypeError", "expected a Mixer");
        if (blk.isNil()) return m.raise("ArgumentError", "no block given");
        for (p.slots) |s| {
            if (s != 0) _ = try m.call(blk, "call", .{m.intValue(s)});
        }
        return m.nilValue();
    }
};

fn registerMixer(cls: mruby.Class) void {
    MixerMethods.class_ptr = cls.class;
    cls.defineClassMethod("new", "", MixerMethods.init_);
    cls.defineMethod("set_volume", "f", MixerMethods.setVolume);
    cls.defineMethod("mix", "*", MixerMethods.mix);
    cls.defineMethod("each_slot", "&", MixerMethods.eachSlot);
}

pub fn main() !void {
    const vm = try mruby.Vm.init();
    defer vm.deinit();

    const audio = try vm.defineModule("Audio");
    const mixer = try vm.defineClass("Mixer", null);
    registerMixer(mixer);
    audio.defineConst("Mixer", .{ .mrb = vm.mrb, .v = mruby.c.mrz_obj_value(@ptrCast(mixer.class)) });

    const script =
        \\mixer = Audio::Mixer.new
        \\mixer.set_volume(0.5)
        \\total = mixer.mix(100, 200, 300)
        \\collected = []
        \\mixer.each_slot { |s| collected << s }
        \\[total, collected.first]
    ;
    const result = try vm.loadString(script);
    const total = try vm.call(result, "[]", .{vm.intValue(0)});
    const first_sample = try vm.call(result, "[]", .{vm.intValue(1)});

    std.debug.print("mix total: {d}, scaled sample: {d}\n", .{ try total.asInt(), try first_sample.asInt() });
}
