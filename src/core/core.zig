//! pan_core — the DSP-agnostic graph engine module root.
//!
//! This module root re-exports every core member's namespace so that
//! `@import("pan_core").types` (etc.) resolves for the dsp / io / umbrella
//! modules, and so that `addTest` on this module collects every member file's
//! in-file `test {}` blocks (each member is reachable by relative-path import
//! from this root).

pub const types = @import("types.zig");
pub const numeric = @import("numeric.zig");
pub const simd = @import("simd.zig");
pub const config = @import("config.zig");
pub const control = @import("control.zig");
pub const mux = @import("mux.zig");
pub const port = @import("port.zig");
pub const graph = @import("graph.zig");
pub const builder = @import("builder.zig");
pub const commit = @import("commit.zig");
pub const engine = @import("engine.zig");
pub const parallel = @import("parallel.zig");
pub const offline = @import("offline.zig");
pub const fusion = @import("fusion.zig");
pub const facade = @import("facade.zig");
pub const combinators = @import("combinators.zig");
pub const layout = @import("layout.zig");
pub const events = @import("events.zig");
pub const resample = @import("resample.zig");
pub const backend = @import("backend.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
