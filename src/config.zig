//! The whole-pipeline configuration object.
//!
//! One `Config` flows through the entire graph (configuration-driven). The
//! precision is bound at COMPTIME (resolve it with `comptime numericFor(...)`) —
//! a precision change re-selects a monomorph and requires a recommit, not a
//! runtime switch. The block size N is a RUNTIME quantity the device dictates
//! and may change on a route switch, so it is an ordinary field, not comptime.

const numeric = @import("numeric.zig");
const types = @import("types.zig");

pub const Config = struct {
    /// Comptime-bound numeric precision for the pipeline's monomorph.
    precision: numeric.Precision = .f32,
    sample_rate: u32 = 48_000,
    /// Device block size N (a hint; the device may override it at commit).
    block_size: usize = 512,
    /// The pipeline's channel layout identity.
    channels: types.ChannelLayout = .stereo,
};
