//! Latency-contract — the declared algorithmic_latency is real (catalog §2.2 R1;
//! testing spec §5.5).
//!
//! A block declaring `algorithmic_latency = L` claims its output is delayed by L
//! samples of group delay. That claim is NOT proven by the type system: a lying
//! Decimator declaring `algorithmic_latency = 0` type-checks. This harness is its
//! discharge — feed a unit impulse, measure the index of the first significant
//! response (the measured group delay), and assert it equals the declared L.
//!
//! COMPARISON MODE: measured group delay == declared latency. Verified against
//! zig 0.16.0; the zig-0-16 skill was loaded before authoring (Rule 13/14).

const std = @import("std");
const h = @import("harness.zig");
const pan = @import("pan");

const eps: f32 = 1e-6;

test "latency: a pure Map (identity) has measured group delay 0 == declared (catalog §2.2)" {
    const n = 256;
    var impulse: [n]pan.Sample(f32) = undefined;
    var out: [n]pan.Sample(f32) = undefined;
    h.fillImpulse(&impulse);

    var blk = h.Identity{};
    h.renderPush(h.Identity, &blk, &impulse, &out, 64);

    const delay = h.measuredGroupDelay(h.sampleValues(&out), eps) orelse
        return error.NoResponse;
    try std.testing.expectEqual(@as(usize, 0), delay);
}

test "latency: the measurer finds the delay of a synthetic delayed response (spec §5.5)" {
    // Validate measuredGroupDelay against a known-delay response: an impulse
    // shifted by D samples must read back as group delay D. (A real Rate block's
    // declared latency is checked the same way once such blocks land.)
    inline for (.{ 0, 1, 7, 63, 128 }) |D| {
        const n = 256;
        var resp: [n]f32 = [_]f32{0.0} ** n;
        resp[D] = 1.0;
        const measured = h.measuredGroupDelay(&resp, eps) orelse return error.NoResponse;
        try std.testing.expectEqual(@as(usize, D), measured);
    }
}

test "latency: an all-quiet response yields null, not a false zero (spec §5.5)" {
    const silent = [_]f32{0.0} ** 64;
    try std.testing.expect(h.measuredGroupDelay(&silent, eps) == null);
}

test "latency: sub-eps ringing before the main response is not counted as the delay" {
    // Only a response EXCEEDING eps marks the group delay; tiny pre-ring (numeric
    // noise below the threshold) must not be mistaken for the onset.
    var resp = [_]f32{0.0} ** 64;
    resp[3] = eps / 2.0; // below threshold
    resp[10] = 1.0; // the real onset
    const measured = h.measuredGroupDelay(&resp, eps) orelse return error.NoResponse;
    try std.testing.expectEqual(@as(usize, 10), measured);
}
