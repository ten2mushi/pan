const std = @import("std");
const pan = @import("pan");

const Num = pan.numericFor(.f32, .{});
const Mono = pan.Sample(f32);
const Stereo = pan.Frame(f32, .stereo);

const BLOCK_SIZE = 1024;
const SampleRate = 48000;

// Minor Pentatonic (Downtrend)
const ScaleMin = [_]f32{ 0, 3, 5, 7, 10, 12, 15, 17, 19, 22, 24, 27, 29, 31, 34, 36 };
// Major Pentatonic (Uptrend)
const ScaleMaj = [_]f32{ 0, 2, 4, 7, 9, 12, 14, 16, 19, 21, 24, 26, 28, 31, 33, 36 };

fn midiToHz(note: f32) f32 {
    return 440.0 * std.math.pow(f32, 2.0, (note - 69.0) / 12.0);
}

const PluckVoice = struct {
    phase: f32 = 0,
    env: f32 = 0,
    freq: f32 = 0,
    pan_l: f32 = 0.5,
    pan_r: f32 = 0.5,
};

const MarketSynth = struct {
    const Self = @This();

    pub const in_elem = void;
    pub const out_elem = Stereo;
    pub const out_per_in = .{ 1, 0 };
    pub const algorithmic_latency = 0;

    data: []const f32 = &.{}, // [price, volume, volatility, is_up, ...]
    current_tick: usize = 0,
    blocks_since_tick: usize = 0,
    blocks_per_tick: usize = 4,

    bass: pan.gen.PolyBlepSaw = .{},
    filter: pan.fx.Ladder(Num) = .{},

    chorus_l: pan.fx.Flanger(Num, SampleRate) = .{ .base_delay = 100, .depth = 30, .rate = 0.5, .mix = 0.5, .feedback = 0.2 },
    chorus_r: pan.fx.Flanger(Num, SampleRate) = .{ .base_delay = 140, .depth = 40, .rate = 0.4, .mix = 0.5, .feedback = 0.2 },

    voices: [8]PluckVoice = [_]PluckVoice{.{}} ** 8,

    bass_pan_phase: f32 = 0,
    duck_env: f32 = 1.0,

    prng: std.Random.DefaultPrng = undefined,

    pub fn initialize(self: *Self, alloc: std.mem.Allocator) !void {
        _ = alloc;
        self.bass.sample_rate = SampleRate;
        self.prng = std.Random.DefaultPrng.init(42);
    }

    pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
        _ = self;
        _ = alloc;
    }

    pub fn pull(self: *Self, want: usize, out: pan.Planar(f32, .stereo)) void {
        _ = want;
        const frames = out.frames;

        var target_price: f32 = 0;
        var target_vol: f32 = 0;
        var target_volat: f32 = 0;
        var is_up: bool = true;

        const tick_idx = self.current_tick * 4;
        if (tick_idx + 3 < self.data.len) {
            target_price = self.data[tick_idx];
            target_vol = self.data[tick_idx + 1];
            target_volat = self.data[tick_idx + 2];
            is_up = self.data[tick_idx + 3] > 0.5;
        }

        const scale = if (is_up) ScaleMaj else ScaleMin;
        const scale_idx: usize = @intFromFloat(target_price * @as(f32, @floatFromInt(scale.len - 1)));
        const note = 36.0 + scale[scale_idx];

        if (self.blocks_since_tick == 0) {
            self.bass.setFrequency(midiToHz(note));

            const cutoff_norm = 0.05 + (target_volat * 0.4);
            self.filter.cutoff = cutoff_norm;
            self.filter.resonance = target_volat * 0.85; // Growl!

            if (target_vol > 0.6) {
                // Trigger Fake Sidechain (Ducking)
                self.duck_env = 0.05; // Duck harder

                // Trigger Low-Frequency Polyphonic Synth Stab
                const scale_offset: usize = @intFromFloat(target_volat * (@as(f32, @floatFromInt(scale.len)) - 1.0));
                const pluck_note = note - 12.0 + scale[scale_offset % scale.len]; // Sub-octave for deep low-end

                var min_env: f32 = 1.0;
                var v_idx: usize = 0;
                for (&self.voices, 0..) |v, i| {
                    if (v.env < min_env) {
                        min_env = v.env;
                        v_idx = i;
                    }
                }

                const pan_val = self.prng.random().float(f32);
                self.voices[v_idx].freq = midiToHz(pluck_note);
                self.voices[v_idx].env = target_vol;
                self.voices[v_idx].pan_l = std.math.cos(pan_val * std.math.pi / 2.0);
                self.voices[v_idx].pan_r = std.math.sin(pan_val * std.math.pi / 2.0);
            }
        }

        self.blocks_since_tick += 1;
        if (self.blocks_since_tick >= self.blocks_per_tick) {
            self.blocks_since_tick = 0;
            self.current_tick += 1;
        }

        var bass_buf: [4096]Mono = undefined;
        const bass_out = bass_buf[0..frames];

        self.bass.process(bass_out);
        self.filter.process(bass_out, bass_out);

        var pluck_l_buf: [4096]Mono = undefined;
        var pluck_r_buf: [4096]Mono = undefined;
        const pl_out = pluck_l_buf[0..frames];
        const pr_out = pluck_r_buf[0..frames];

        const tau = 2.0 * std.math.pi;
        const sr_f = @as(f32, SampleRate);
        const lfo_inc = 0.2 / sr_f; // Auto-pan speed

        for (pl_out, pr_out, bass_out) |*pl, *pr, b| {
            var mix_l: f32 = 0;
            var mix_r: f32 = 0;

            for (&self.voices) |*v| {
                if (v.env < 0.001) continue;

                // Distant, Deep Polyphonic Synth Stab

                // Very subtle, dark FM modulation
                const fm_mod = @sin(tau * v.phase * 0.5) * v.env * 0.15;
                // Layer with a slightly detuned oscillator for a thick, washed-out pad feel
                const detune = @sin(tau * v.phase * 1.01) * v.env * 0.5;

                const p = (@sin(tau * v.phase + fm_mod) + detune) * v.env * 0.12; // Low presence

                v.phase += v.freq / sr_f;
                if (v.phase > 1.0) v.phase -= 1.0;

                // Long, smooth release to wash out into the reverb
                v.env *= 0.9992;

                mix_l += p * v.pan_l;
                mix_r += p * v.pan_r;
            }

            pl.ch[0] = mix_l;
            pr.ch[0] = mix_r;

            // Sidechain envelope recovery (slower for a heavier musical pump)
            self.duck_env += (1.0 - self.duck_env) * 0.0001;

            const bass_amp = b.ch[0] * 0.7 * self.duck_env;
            const b_pan_l = std.math.cos(self.bass_pan_phase * tau);
            const b_pan_r = std.math.sin(self.bass_pan_phase * tau);

            self.bass_pan_phase += lfo_inc;
            if (self.bass_pan_phase > 1.0) self.bass_pan_phase -= 1.0;

            pl.ch[0] += bass_amp * b_pan_l;
            pr.ch[0] += bass_amp * b_pan_r;
        }

        self.chorus_l.process(pl_out, pl_out);
        self.chorus_r.process(pr_out, pr_out);

        const out_l = out.plane(0);
        const out_r = out.plane(1);
        for (out_l, out_r, pl_out, pr_out) |*ol, *o_r, pl, pr| {
            // Soft clipping before reverb
            ol.* = @as(f32, @floatCast(std.math.tanh(pl.ch[0])));
            o_r.* = @as(f32, @floatCast(std.math.tanh(pr.ch[0])));
        }
    }
};

const SpaceReverb = struct {
    const Self = @This();
    pub const in_elem = Stereo;
    pub const out_elem = Stereo;
    pub const algorithmic_latency = 0;

    delay1_l: pan.fx.Comb(Num, 48000) = .{ .delay = 18000, .feedback = 0.6 },
    delay2_l: pan.fx.Comb(Num, 48000) = .{ .delay = 24000, .feedback = 0.5 },
    delay1_r: pan.fx.Comb(Num, 48000) = .{ .delay = 18500, .feedback = 0.6 },
    delay2_r: pan.fx.Comb(Num, 48000) = .{ .delay = 24500, .feedback = 0.5 },

    pub fn initialize(self: *Self, alloc: std.mem.Allocator) !void {
        _ = self;
        _ = alloc;
    }
    pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
        _ = self;
        _ = alloc;
    }
    pub fn process(self: *Self, in: pan.PlanarConst(f32, .stereo), out: pan.Planar(f32, .stereo)) void {
        const frames = in.frames;
        var in_l: [4096]Mono = undefined;
        var in_r: [4096]Mono = undefined;
        var d1l: [4096]Mono = undefined;
        var d2l: [4096]Mono = undefined;
        var d1r: [4096]Mono = undefined;
        var d2r: [4096]Mono = undefined;

        const in_plane_l = in.plane(0);
        const in_plane_r = in.plane(1);
        for (0..frames) |i| {
            in_l[i].ch[0] = in_plane_l[i];
            in_r[i].ch[0] = in_plane_r[i];
        }

        self.delay1_l.process(in_l[0..frames], d1l[0..frames]);
        self.delay2_l.process(in_l[0..frames], d2l[0..frames]);
        self.delay1_r.process(in_r[0..frames], d1r[0..frames]);
        self.delay2_r.process(in_r[0..frames], d2r[0..frames]);

        const out_plane_l = out.plane(0);
        const out_plane_r = out.plane(1);
        for (0..frames) |i| {
            // Final master mix: soft clipping for analog tape saturation feel
            const mix_l = in_l[i].ch[0] * 0.8 + (d1l[i].ch[0] + d2l[i].ch[0]) * 0.20;
            const mix_r = in_r[i].ch[0] * 0.8 + (d1r[i].ch[0] + d2r[i].ch[0]) * 0.20;
            out_plane_l[i] = @as(f32, @floatCast(std.math.tanh(mix_l)));
            out_plane_r[i] = @as(f32, @floatCast(std.math.tanh(mix_r)));
        }
    }
};

const MemSink = struct {
    const Self = @This();
    pub const growable_sink: bool = true;

    capacity_hint: usize = 0,
    samples: std.ArrayList(Stereo) = .empty,
    gpa: std.mem.Allocator = undefined,

    pub fn initialize(self: *Self, alloc: std.mem.Allocator) !void {
        self.gpa = alloc;
        try self.samples.ensureTotalCapacity(alloc, self.capacity_hint);
    }
    pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
        self.samples.deinit(alloc);
    }
    pub fn process(self: *Self, in: pan.PlanarConst(f32, .stereo)) void {
        const num_frames = in.frames;
        const l = in.plane(0);
        const r = in.plane(1);
        self.samples.ensureUnusedCapacity(self.gpa, num_frames) catch unreachable;
        for (0..num_frames) |i| {
            self.samples.appendAssumeCapacity(.{ .ch = .{ l[i], r[i] } });
        }
    }
    pub fn frames(self: *const Self) []const Stereo {
        return self.samples.items;
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var args = std.process.Args.iterate(init.minimal.args);
    _ = args.next();

    const in_path = args.next() orelse return error.Usage;
    const out_path = args.next() orelse return error.Usage;

    const data_bytes = try std.Io.Dir.cwd().readFileAllocOptions(init.io, in_path, gpa, .unlimited, comptime .of(f32), null);
    defer gpa.free(data_bytes);
    const data = std.mem.bytesAsSlice(f32, data_bytes);

    const total_ticks = data.len / 4; // Now 4 floats per tick

    var g = pan.Graph.init(gpa, .{ .precision = .f32, .channels = .stereo, .block_size = BLOCK_SIZE, .sample_rate = SampleRate });
    defer g.deinit();

    const src = try g.add(MarketSynth, .{ .data = data });
    const reverb = try g.add(SpaceReverb, .{});
    const sink = try g.add(MemSink, .{ .capacity_hint = total_ticks * BLOCK_SIZE * 4 });

    try g.connect(src, reverb);
    try g.connect(reverb, sink);

    var eng = try g.commitAnalysis();
    defer eng.deinit();

    const blocks_per_tick = 4;
    try eng.runToCompletion(.{ .clock = .{ .wall_clock_timer = 60 }, .max_blocks = total_ticks * blocks_per_tick });

    const output_bytes = std.mem.sliceAsBytes(sink.instance().frames());
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = out_path, .data = output_bytes });
    std.debug.print("Wrote market sonification to {s}\n", .{out_path});
}
