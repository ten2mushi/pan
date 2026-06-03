//! The freestanding ReleaseSmall smoke object.
//!
//! This compiles the comptime commit pass for a tiny graph against a
//! freestanding target with no std runtime, no allocator, and no test harness —
//! the embedded profile's "same code, specialized" obligation in miniature. The
//! exported symbol returns the comptime-known pool footprint, forcing the
//! commit pass to be evaluated at compile time during the object build; the
//! object compiling at all is the discharge of that obligation for this graph.

const root = @import("root.zig");

export fn pan_smoke_footprint() usize {
    const g = comptime root.smokeGraph();
    const plan = comptime root.commitComptime(g) catch unreachable;
    return plan.footprint_bytes;
}
