//! pan CLI — builds a trivial graph, commits it, and prints the commit summary.
//! A thin demonstrator over the `pan` library module.

const std = @import("std");
const pan = @import("pan");

pub fn main() void {
    // Build and commit the library's smoke graph (source → gain → sink) at
    // comptime, then report the commit summary the embedded profile relies on.
    const g = comptime pan.smokeGraph();
    const plan = comptime pan.commitComptime(g) catch unreachable;

    std.debug.print(
        "pan: committed {d} ops, pool footprint {d} bytes\n",
        .{ plan.op_count, plan.footprint_bytes },
    );
}
