//! pan_dsp — the node-library module root.
//!
//! Re-exports every node-library member's namespace so the io / umbrella modules
//! can reach them, and so `addTest` on this module collects each member file's
//! in-file `test {}` blocks (each member is reachable by relative-path import
//! from this root). The core symbols these libraries build on are reached through
//! the named `pan_core` module so that `core.Sample` and `dsp`-side `Sample` are
//! the SAME type (a file relative-imported from two module roots would otherwise
//! compile into two distinct types).

const core = @import("pan_core");

pub const gen = @import("generation/gen.zig");
pub const env = @import("generation/env.zig");
pub const synth = @import("synth/synth.zig");
pub const filters = @import("filter/filters.zig");
pub const filterbank = @import("filter/filterbank.zig");
pub const fx = @import("effect/fx.zig");
pub const spatial = @import("spatial/spatial.zig");
pub const dsp_mix = @import("spatial/dsp_mix.zig");
pub const spectral = @import("spectral/spectral.zig");
pub const feat = @import("analysis/feat.zig");
pub const time = @import("time/time.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
