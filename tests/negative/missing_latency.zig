//! NEGATIVE-COMPILE fixture: a `Rate` block that declares `out_per_in` + `pull`
//! but is MISSING `algorithmic_latency`. The P8 gate criterion "a Rate missing a
//! declaration is a build error" requires `pan.classify` to reject this with a
//! `@compileError`. The `neg-compile` build step asserts THIS FILE FAILS to
//! compile (expects a non-zero `zig build-obj` exit) — turning the gate from a
//! by-inspection disabled stub into an active CI check. If it ever compiles, the
//! gate has regressed and the build step fails.
const pan = @import("pan");

const MissingLatency = struct {
    const Self = @This();
    pub const out_per_in = .{ 1, 2 };
    // pub const algorithmic_latency: usize = ...;  // DELIBERATELY OMITTED — the gate
    pub fn pull(self: *Self, in: []const pan.Sample(f32), want: usize, out: []pan.Sample(f32)) usize {
        _ = self;
        _ = in;
        _ = out;
        return want;
    }
};

comptime {
    _ = pan.classify(MissingLatency); // => @compileError: "is a Rate but declares no algorithmic_latency"
}

pub fn main() void {}
