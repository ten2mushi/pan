//! Spatial blocks — `ConstantPowerPan`.
//!
//! `ConstantPowerPan` is the canonical layout-changing `Map`: its input is a
//! mono `Sample(T)` and its output is a stereo `Frame(T,.stereo)`, so the
//! channel layout `L` differs between the input and output ports — a layout
//! change is exactly a morphism whose `Frame`s differ in `L`, type-checked at
//! `connect`. Rate-1:1, stateless ⇒ a `Map`.
//!
//! The stereo output is written through a PLANAR view: the buffer is two
//! contiguous channel planes (an L-plane of N samples followed by an R-plane of
//! N samples), plane-major, not interleaved L,R,L,R frames. The kernel writes
//! the whole L-plane and the whole R-plane directly — each plane is a contiguous
//! `[]T` a per-channel vector loop walks straight through. (Mono input is one
//! plane, so it keeps a plain `[]const Sample(T)` slice port.)
//!
//! The pan law is **constant power**: for a pan position `p ∈ [-1, 1]`
//! (−1 hard-left, 0 center, +1 hard-right), the per-channel gains are
//! `L = cos θ`, `R = sin θ` with `θ = (p + 1)·π/4`, so `L² + R² = 1` for every
//! `p` — the perceived loudness is constant as the source pans (unlike a linear
//! law, which dips ~3 dB at center). Center (`p = 0`) gives `L = R = cos(π/4) =
//! √½ ≈ 0.7071`.

const std = @import("std");
const core = @import("pan_core");
const types = core.types;
const numeric = core.numeric;
const simd = core.simd;
const layout = core.layout;

fn isFloat(comptime T: type) bool {
    return @typeInfo(T) == .float;
}
fn fracBits(comptime T: type) comptime_int {
    return @typeInfo(T).int.bits - 1;
}

/// View a mono `Sample(T)` slice as its underlying scalar `[]T`.
fn scalarsConst(comptime T: type, frames: []const types.Sample(T)) []const T {
    return @alignCast(std.mem.bytesAsSlice(T, std.mem.sliceAsBytes(frames)));
}

/// `ConstantPowerPan(num)` — mono → stereo constant-power panner. `pan` is the
/// position in `[-1, 1]`; it is recomputed into the two channel gains each
/// render call (held across the buffer, the parameter/control-rate convention),
/// so a future wired `param.pan` or `set(.pan, …)` ramps without a kernel change.
pub fn ConstantPowerPan(comptime num: numeric.Numeric) type {
    const T = num.Lane;
    return struct {
        const Self = @This();
        /// Pan position in [-1, 1]; held across the render buffer. Used to derive
        /// the channel gains unless `gains_q` overrides them.
        pan: f32 = 0,
        /// Optional PRE-QUANTIZED channel gains `[L, R]` in the lane's q-format,
        /// used by the integer path INSTEAD of computing `cos/sin(pan)` at render
        /// time. This is the embedded path (an MCU precomputes the pan gains — no
        /// runtime trig) and the bit-exact-testable path: the kernel applies the
        /// exact integer coefficients given, so an oracle holding the same integers
        /// matches to the bit (a runtime `cos` would differ by ~1 ULP between f32
        /// and an f64 oracle and shift every output sample). Ignored on the float
        /// path, which derives the gains from `pan` directly.
        gains_q: ?[2]T = null,

        pub const params = .{ .pan = types.Scalar(f32) };

        pub fn process(self: *Self, in: []const types.Sample(T), out: types.Planar(T, .stereo)) void {
            std.debug.assert(in.len == out.frames);
            const xs = scalarsConst(T, in);
            // The two output channel planes — each a contiguous []T over the
            // whole buffer (L-plane then R-plane in the plane-major buffer).
            const left = out.plane(0);
            const right = out.plane(1);
            if (comptime isFloat(T)) {
                // Constant-power gains: θ = (p+1)·π/4, L = cos θ, R = sin θ.
                const p = std.math.clamp(self.pan, -1.0, 1.0);
                const theta = (p + 1.0) * (std.math.pi / 4.0);
                const lcoef: T = @floatCast(@cos(theta));
                const rcoef: T = @floatCast(@sin(theta));
                for (xs, left, right) |x, *l, *r| {
                    l.* = x * lcoef;
                    r.* = x * rcoef;
                }
            } else {
                const frac = comptime fracBits(T);
                // Use the supplied q-format gains, else quantize cos/sin(pan).
                const lq: T, const rq: T = if (self.gains_q) |g| .{ g[0], g[1] } else blk: {
                    const p = std.math.clamp(self.pan, -1.0, 1.0);
                    const theta = (p + 1.0) * (std.math.pi / 4.0);
                    const scale: f32 = @floatFromInt(@as(i64, 1) << frac);
                    break :blk .{ @intFromFloat(@round(@cos(theta) * scale)), @intFromFloat(@round(@sin(theta) * scale)) };
                };
                for (xs, left, right) |x, *l, *r| {
                    l.* = simd.qMulStore(T, num.Acc, x, lq, frac);
                    r.* = simd.qMulStore(T, num.Acc, x, rq, frac);
                }
            }
        }
    };
}

fn requireFloat(comptime T: type) void {
    if (!isFloat(T))
        @compileError("pan: the up/down-mix matrix and balance/width spatial blocks" ++
            " are float-only for now — the canonical mix matrices are defined in" ++
            " real coefficients and the gold-vector oracle is float. A fixed-point" ++
            " spatial matrix (quantized coefficients + wide-accumulator mix) mirrors" ++
            " the fixed-point Biquad treatment and has not been ported yet. Use f32/f64.");
}

const inv_sqrt2: comptime_float = 0.7071067811865476; // 1/√2 ≈ −3 dB

/// View a multi-channel planar input as the lane scalar of one plane `c`.
fn inPlane(comptime Lane: type, comptime L: types.ChannelLayout, v: types.PlanarConst(Lane, L), c: usize) []const Lane {
    return v.plane(c);
}

// ===========================================================================
// Canonical up/down-mix matrix registry — geometry as block data, not in the type
// ===========================================================================

/// The canonical up/down-mix coefficient matrix registry lives in `layout.zig`
/// (the channel-layout coercion algebra). Re-exported here so existing callers
/// of `spatial.canonicalMixMatrix` continue to resolve.
pub const canonicalMixMatrix = layout.canonicalMixMatrix;

/// `MixMatrix(num, L_in, L_out)` — a layout-changing `Map` that mixes the `C_in`
/// input planes into the `C_out` output planes through a coefficient matrix
/// `m[o][i]` (`out[o] = Σ_i m[o][i]·in[i]`). The matrix is block data (L3:
/// geometry lives in the block, not the stream type); it defaults to the canonical
/// up/down-mix for a registered `(L_in, L_out)` pair and can be overridden per
/// instance for a custom layout. Wiring two layouts with no registered matrix is a
/// comptime error here (the explicit-block path), the dual of the negotiation pass
/// rejecting an unregistered pair as a hard mismatch.
pub fn MixMatrix(comptime num: numeric.Numeric, comptime L_in: types.ChannelLayout, comptime L_out: types.ChannelLayout) type {
    const T = num.Lane;
    requireFloat(T);
    const Ci = L_in.count();
    const Co = L_out.count();
    const default_matrix: [Co][Ci]T = blk: {
        const canon = layout.canonicalMixMatrix(L_in, L_out) orelse
            @compileError("pan: no registered up/down-mix matrix for this layout pair" ++
                " — supply an explicit `matrix` field, or use a dedicated spatial block" ++
                " (VBAP/ambisonic). Negotiation rejects the same pair as a hard mismatch.");
        var out: [Co][Ci]T = undefined;
        for (0..Co) |o| for (0..Ci) |i| {
            out[o][i] = @floatCast(canon[o][i]);
        };
        break :blk out;
    };
    return struct {
        const Self = @This();
        /// Per-output-per-input gain; `out[o] = Σ_i matrix[o][i]·in[i]`.
        matrix: [Co][Ci]T = default_matrix,

        pub fn process(self: *Self, in: types.PlanarConst(T, L_in), out: types.Planar(T, L_out)) void {
            std.debug.assert(in.frames == out.frames);
            const n = out.frames;
            // Plane-major mix: accumulate each output plane over the input planes.
            for (0..Co) |o| {
                const dst = out.plane(o);
                @memset(dst, 0);
                for (0..Ci) |i| {
                    const g = self.matrix[o][i];
                    if (g == 0) continue; // skip the (common) zero coefficient
                    const src = inPlane(T, L_in, in, i);
                    var k: usize = 0;
                    while (k < n) : (k += 1) dst[k] += g * src[k];
                }
            }
        }
    };
}

/// `Upmix(num, L_in, L_out)` — a `MixMatrix` asserting the layout WIDENS
/// (`C_out > C_in`); the canonical registered up-mix matrix.
pub fn Upmix(comptime num: numeric.Numeric, comptime L_in: types.ChannelLayout, comptime L_out: types.ChannelLayout) type {
    comptime std.debug.assert(L_out.count() > L_in.count());
    return MixMatrix(num, L_in, L_out);
}

/// `Downmix(num, L_in, L_out)` — a `MixMatrix` asserting the layout NARROWS
/// (`C_out < C_in`); the canonical registered down-mix matrix.
pub fn Downmix(comptime num: numeric.Numeric, comptime L_in: types.ChannelLayout, comptime L_out: types.ChannelLayout) type {
    comptime std.debug.assert(L_out.count() < L_in.count());
    return MixMatrix(num, L_in, L_out);
}

// ===========================================================================
// Stereo field blocks — balance & width (stereo → stereo, layout-preserving)
// ===========================================================================

/// `Balance(num)` — stereo balance: shift the level between the two channels
/// without the constant-power re-pan law. `balance ∈ [-1, 1]`: `0` is unity on
/// both; `< 0` attenuates the RIGHT channel linearly to silence at `-1`; `> 0`
/// attenuates the LEFT. Each channel is only ever attenuated (never boosted),
/// which is the classic mixing-console balance control (distinct from a panner,
/// which re-pans a mono source). Stateless, rate-1:1 ⇒ a `Map`; layout-preserving
/// (stereo → stereo).
pub fn Balance(comptime num: numeric.Numeric) type {
    const T = num.Lane;
    requireFloat(T);
    return struct {
        const Self = @This();
        balance: f32 = 0,

        pub const params = .{ .balance = types.Scalar(f32) };

        pub fn process(self: *Self, in: types.PlanarConst(T, .stereo), out: types.Planar(T, .stereo)) void {
            std.debug.assert(in.frames == out.frames);
            const b = std.math.clamp(self.balance, -1.0, 1.0);
            const lg: T = @floatCast(if (b > 0) 1.0 - b else 1.0);
            const rg: T = @floatCast(if (b < 0) 1.0 + b else 1.0);
            const li = in.plane(0);
            const ri = in.plane(1);
            const lo = out.plane(0);
            const ro = out.plane(1);
            for (li, ri, lo, ro) |l, r, *ol, *orr| {
                ol.* = l * lg;
                orr.* = r * rg;
            }
        }
    };
}

/// `Width(num)` — stereo width via the mid/side decomposition. With
/// `mid = (L+R)/2`, `side = (L−R)/2`: `out_L = mid + width·side`,
/// `out_R = mid − width·side`. `width = 1` is identity; `width = 0` collapses to
/// dual-mono (the mid only); `width > 1` widens (and `≈ 2` keeps the side fully,
/// dropping the mid at the limit). Stateless, rate-1:1 ⇒ a `Map`; layout-preserving.
pub fn Width(comptime num: numeric.Numeric) type {
    const T = num.Lane;
    requireFloat(T);
    return struct {
        const Self = @This();
        width: f32 = 1.0,

        pub const params = .{ .width = types.Scalar(f32) };

        pub fn process(self: *Self, in: types.PlanarConst(T, .stereo), out: types.Planar(T, .stereo)) void {
            std.debug.assert(in.frames == out.frames);
            const w: T = @floatCast(self.width);
            const li = in.plane(0);
            const ri = in.plane(1);
            const lo = out.plane(0);
            const ro = out.plane(1);
            for (li, ri, lo, ro) |l, r, *ol, *orr| {
                const mid = (l + r) * 0.5;
                const side = (l - r) * 0.5;
                ol.* = mid + w * side;
                orr.* = mid - w * side;
            }
        }
    };
}

// ===========================================================================
// VBAP — 2-D Vector Base Amplitude Panning (mono → planar L_out)
// ===========================================================================

/// The default ring of speaker azimuths (DEGREES, counter-clockwise from front,
/// 0° = dead ahead, +90° = listener's left) for a registered positional output
/// layout, in pan's canonical SMPTE channel order. These are BLOCK DATA — the
/// geometry that VBAP needs but the stream type does not carry — exposed as an
/// overridable field on the block. An LFE channel has no place on the panning
/// ring; it is marked with a sentinel NaN azimuth and always receives zero gain.
///
/// Stereo is the ITU ±30° pair; 5.1 places the fronts at ±30°, centre at 0°, and
/// the surrounds at ±110° (the ITU-R BS.775 reference arrangement); 7.1 adds the
/// back pair at ±150° and keeps the side pair at ±90°. Front-left is a POSITIVE
/// azimuth because positive is the listener's left under this CCW convention.
fn defaultAzimuthsDeg(comptime L: types.ChannelLayout) [L.count()]f32 {
    const nan = std.math.nan(f32);
    return switch (L) {
        .stereo => .{ 30, -30 },
        // [FL, FR, FC, LFE, Ls, Rs]
        .surround_5_1 => .{ 30, -30, 0, nan, 110, -110 },
        // [FL, FR, FC, LFE, Lb, Rb, Ls, Rs]
        .surround_7_1 => .{ 30, -30, 0, nan, 150, -150, 90, -90 },
        else => @compileError("pan: Vbap default speaker azimuths are defined only for the" ++
            " positional output layouts (stereo / 5.1 / 7.1); supply an explicit" ++
            " `speaker_az_deg` field for a custom speaker ring."),
    };
}

/// `Vbap(num, L_out)` — 2-D Vector Base Amplitude Panning: a mono `Sample(T)`
/// source is positioned on the horizontal speaker ring of layout `L_out` by an
/// `azimuth` parameter (DEGREES, CCW from front), producing a `Planar(T, L_out)`
/// output. Stateless, rate-1:1, layout-changing ⇒ a `Map`.
///
/// VBAP gain law (Pulkki): each speaker `s` is a unit base vector
/// `l_s = (cos az_s, sin az_s)` on the plane. The virtual source direction is the
/// unit vector `p = (cos az_src, sin az_src)`. The source is rendered by the
/// adjacent speaker PAIR `(a, b)` whose arc brackets it; their gains solve the
/// 2×2 base-vector system `p = g_a·l_a + g_b·l_b`, i.e. `g = L⁻¹·p` where
/// `L = [l_a | l_b]` has the two base vectors as columns. The correct bracketing
/// pair is exactly the one for which BOTH gains come out non-negative (the source
/// lies inside the cone the two speakers span); all other speakers get zero gain.
/// The raw pair-gains are then NORMALIZED to constant power, `g ← g/‖g‖₂`, so the
/// summed power `g_a² + g_b² = 1` is held for every source position — a source
/// panned across the arc keeps constant perceived loudness, and a source sitting
/// exactly on a speaker collapses to that single speaker at unit gain.
///
/// Limit (surfaced): this is the HORIZONTAL (2-D) VBAP only — elevation is not a
/// parameter and the speaker ring is planar. An LFE channel (NaN default azimuth)
/// is never part of the ring and always receives zero gain.
pub fn Vbap(comptime num: numeric.Numeric, comptime L_out: types.ChannelLayout) type {
    const T = num.Lane;
    requireFloat(T);
    const C = L_out.count();
    return struct {
        const Self = @This();
        /// Source position on the ring, DEGREES CCW from front; held across the
        /// render buffer (the parameter/control-rate convention).
        azimuth: f32 = 0,
        /// Speaker azimuths in DEGREES (block data, canonical SMPTE order); a NaN
        /// entry (e.g. LFE) is excluded from the panning ring and gets zero gain.
        speaker_az_deg: [C]f32 = defaultAzimuthsDeg(L_out),

        pub const params = .{ .azimuth = types.Scalar(f32) };

        /// Solve the per-speaker constant-power VBAP gains for the current source
        /// azimuth. Returns one gain per output channel (zero off the active pair).
        fn gains(self: *const Self) [C]T {
            const deg2rad = std.math.pi / 180.0;
            // Compute the source direction in f64 to match the f64 speaker base
            // vectors below. Doing the source trig in f32 (the parameter's type) while
            // the speakers' are in f64 leaves a ~1e-7 rounding mismatch that, for a
            // source sitting exactly on a speaker, drives the partner gain to a small
            // NEGATIVE value (~−9e-9) — just past the non-negativity acceptance
            // threshold — so the only bracketing pair is wrongly rejected and the
            // panner outputs silence. Matching precision keeps the on-speaker residual
            // at ~1e-16, well inside the threshold, so the on-speaker gain stays 1.
            const src: f64 = @as(f64, self.azimuth) * deg2rad;
            const px = @cos(src);
            const py = @sin(src);

            var g = [_]T{0} ** C;
            // Search every speaker pair for one whose 2×2 base-vector system yields
            // two non-negative gains: that is a bracketing pair (the source lies in
            // the wedge the two speakers span). On a full ring several obtuse pairs
            // can enclose the source, so among the candidates keep the one with the
            // NARROWEST arc (smallest angle between the two base vectors) — the
            // physically adjacent pair VBAP intends. A source sitting exactly on a
            // speaker resolves to a single speaker at unit power: the partner gain
            // comes out ≈0 and constant-power normalization leaves the on-speaker
            // gain at 1.
            var best_a: usize = 0;
            var best_b: usize = 0;
            var best_ga: f64 = 0;
            var best_gb: f64 = 0;
            var best_dot: f64 = -2; // cos(arc): larger ⇒ narrower wedge
            var found = false;
            for (0..C) |a| {
                if (std.math.isNan(self.speaker_az_deg[a])) continue; // LFE etc.
                const ax = @cos(@as(f64, self.speaker_az_deg[a]) * deg2rad);
                const ay = @sin(@as(f64, self.speaker_az_deg[a]) * deg2rad);
                for (a + 1..C) |b| {
                    if (std.math.isNan(self.speaker_az_deg[b])) continue;
                    const bx = @cos(@as(f64, self.speaker_az_deg[b]) * deg2rad);
                    const by = @sin(@as(f64, self.speaker_az_deg[b]) * deg2rad);
                    // L = [[ax bx];[ay by]]; g = L⁻¹·p, det = ax·by − ay·bx.
                    const det = ax * by - ay * bx;
                    if (@abs(det) < 1e-9) continue; // colinear / antipodal pair
                    const ga = (@as(f64, px) * by - @as(f64, py) * bx) / det;
                    const gb = (-@as(f64, px) * ay + @as(f64, py) * ax) / det;
                    if (ga >= -1e-9 and gb >= -1e-9) {
                        const dot = ax * bx + ay * by; // cos of the arc between l_a,l_b
                        if (!found or dot > best_dot) {
                            found = true;
                            best_dot = dot;
                            best_a = a;
                            best_b = b;
                            best_ga = ga;
                            best_gb = gb;
                        }
                    }
                }
            }
            if (!found) return g; // no bracketing pair (source outside any arc)
            // Constant-power normalization: g ← g/‖g‖₂ so g_a²+g_b² = 1.
            const norm = @sqrt(best_ga * best_ga + best_gb * best_gb);
            if (norm > 0) {
                g[best_a] = @floatCast(best_ga / norm);
                g[best_b] = @floatCast(best_gb / norm);
            }
            return g;
        }

        pub fn process(self: *Self, in: []const types.Sample(T), out: types.Planar(T, L_out)) void {
            std.debug.assert(in.len == out.frames);
            const xs = scalarsConst(T, in);
            const g = self.gains();
            for (0..C) |c| {
                const dst = out.plane(c);
                const gc = g[c];
                if (gc == 0) {
                    @memset(dst, 0);
                    continue;
                }
                for (xs, dst) |x, *d| d.* = x * gc;
            }
        }
    };
}

// ===========================================================================
// Ambisonic encode / decode — real SH, ACN ordering, SN3D normalization
// ===========================================================================

/// Evaluate the ACN-indexed, SN3D-normalized real spherical harmonic `Y_k` for a
/// direction given by azimuth `az` and elevation `el` (RADIANS; azimuth CCW from
/// front, elevation up). ACN maps a flat index `k` to degree/order via
/// `l = ⌊√k⌋`, `m = k − l² − l`; the channel layout is W, Y, Z, X, V, T, R, S, U
/// for k = 0..8. SN3D ("Schmidt semi-normalized") fixes `Y_0 = 1`.
///
/// Implemented for orders 0–2 (k = 0..8). The SN3D real-SH values are:
///   k0  W = 1
///   k1  Y = sin(az)·cos(el)
///   k2  Z = sin(el)
///   k3  X = cos(az)·cos(el)
///   k4  V = √(3)/2 · sin(2az)·cos²(el)
///   k5  T = √(3)/2 · sin(az)·sin(2el)
///   k6  R = (3·sin²(el) − 1)/2
///   k7  S = √(3)/2 · cos(az)·sin(2el)
///   k8  U = √(3)/2 · cos(2az)·cos²(el)
fn sh(comptime k: usize, az: f64, el: f64) f64 {
    const sqrt3_2 = 0.8660254037844386; // √3 / 2
    const ce = @cos(el);
    const se = @sin(el);
    return switch (k) {
        0 => 1.0,
        1 => @sin(az) * ce,
        2 => se,
        3 => @cos(az) * ce,
        4 => sqrt3_2 * @sin(2.0 * az) * ce * ce,
        5 => sqrt3_2 * @sin(az) * @sin(2.0 * el),
        6 => 0.5 * (3.0 * se * se - 1.0),
        7 => sqrt3_2 * @cos(az) * @sin(2.0 * el),
        8 => sqrt3_2 * @cos(2.0 * az) * ce * ce,
        else => @compileError("pan: AmbisonicEncode/Decode implement orders 0–2 only" ++
            " (ACN channels 0..8); higher orders need the corresponding real-SH terms."),
    };
}

/// `AmbisonicEncode(num, order)` — encode a mono `Sample(T)` point source into an
/// order-`order` ambisonic soundfield in ACN channel order with SN3D
/// normalization (`Planar(T, .ambisonic{order,.acn,.sn3d})`, count `(order+1)²`).
/// An `azimuth` and `elevation` parameter (DEGREES; az CCW from front, el up)
/// place the source; output channel `k` is the input scaled by the SN3D real
/// spherical harmonic `Y_k(az, el)`. Stateless, rate-1:1, layout-changing ⇒ a `Map`.
///
/// Limit (surfaced): orders 0–2 only (ACN channels 0..8). The omnidirectional W
/// channel (k=0, `Y_0 = 1`) is direction-independent: it always equals the input.
pub fn AmbisonicEncode(comptime num: numeric.Numeric, comptime order: u8) type {
    const T = num.Lane;
    requireFloat(T);
    if (order > 2) @compileError("pan: AmbisonicEncode implements orders 0–2 only.");
    const L_out: types.ChannelLayout = .{ .ambisonic = .{ .order = order, .ordering = .acn, .norm = .sn3d } };
    const C = L_out.count();
    return struct {
        const Self = @This();
        /// Source azimuth in DEGREES (CCW from front); held across the buffer.
        azimuth: f32 = 0,
        /// Source elevation in DEGREES (up positive); held across the buffer.
        elevation: f32 = 0,

        pub const params = .{ .azimuth = types.Scalar(f32), .elevation = types.Scalar(f32) };

        pub fn process(self: *Self, in: []const types.Sample(T), out: types.Planar(T, L_out)) void {
            std.debug.assert(in.len == out.frames);
            const xs = scalarsConst(T, in);
            const deg2rad = std.math.pi / 180.0;
            const az = @as(f64, self.azimuth) * deg2rad;
            const el = @as(f64, self.elevation) * deg2rad;
            inline for (0..C) |k| {
                const yk: T = @floatCast(sh(k, az, el));
                const dst = out.plane(k);
                for (xs, dst) |x, *d| d.* = x * yk;
            }
        }
    };
}

/// `AmbisonicDecode(num, order, L_out)` — decode an order-`order` ACN/SN3D
/// soundfield (`PlanarConst(T, .ambisonic{order,.acn,.sn3d})`) to the positional
/// speaker layout `L_out` (`Planar(T, L_out)`). Layout-changing `Map`, rate-1:1.
///
/// Basic ("mode-matching"/projection) decode: each speaker `s` sits in direction
/// `dir_s` (azimuth from `L_out`'s canonical ring; horizontal, el = 0). Its output
/// is the projection of the soundfield onto the SN3D real SH sampled at `dir_s`,
/// scaled by `1/N` with `N = (order+1)²` the channel count:
///   `out[s] = (1/N) · Σ_k Y_k(dir_s) · in[k]`.
/// This is the transpose of the SN3D encoder, so encoding a point source at a
/// speaker's direction and decoding concentrates the energy at that speaker, and a
/// pure-W (omnidirectional) field — `in[0] = c`, all higher channels 0 — decodes to
/// the SAME value `c/N` at every speaker (Y_0 = 1 for all directions).
///
/// Limit (surfaced): orders 0–2 only; speakers are taken on the horizontal plane
/// (el = 0). An LFE channel (NaN default azimuth) is left silent.
pub fn AmbisonicDecode(comptime num: numeric.Numeric, comptime order: u8, comptime L_out: types.ChannelLayout) type {
    const T = num.Lane;
    requireFloat(T);
    if (order > 2) @compileError("pan: AmbisonicDecode implements orders 0–2 only.");
    const L_in: types.ChannelLayout = .{ .ambisonic = .{ .order = order, .ordering = .acn, .norm = .sn3d } };
    const N = L_in.count();
    const C = L_out.count();
    return struct {
        const Self = @This();
        /// Speaker azimuths in DEGREES (block data, canonical SMPTE order); a NaN
        /// entry (LFE) is left silent.
        speaker_az_deg: [C]f32 = defaultAzimuthsDeg(L_out),

        pub fn process(self: *Self, in: types.PlanarConst(T, L_in), out: types.Planar(T, L_out)) void {
            std.debug.assert(in.frames == out.frames);
            const deg2rad = std.math.pi / 180.0;
            const inv_n = 1.0 / @as(f64, @floatFromInt(N));
            for (0..C) |s| {
                const dst = out.plane(s);
                if (std.math.isNan(self.speaker_az_deg[s])) {
                    @memset(dst, 0); // LFE: silent
                    continue;
                }
                const az = @as(f64, self.speaker_az_deg[s]) * deg2rad;
                // Per-speaker decode coefficients = (1/N)·SN3D SH at this direction (el=0).
                var coef: [N]T = undefined;
                inline for (0..N) |k| coef[k] = @floatCast(sh(k, az, 0.0) * inv_n);
                @memset(dst, 0);
                inline for (0..N) |k| {
                    const ck = coef[k];
                    const src = inPlane(T, L_in, in, k);
                    for (src, dst) |x, *d| d.* += ck * x;
                }
            }
        }
    };
}

const testing = std.testing;
const f32num = numeric.numericFor(.f32, .{});

test "ConstantPowerPan centers to equal √½ gains and is layout-changing mono→stereo" {
    const port = core.port;
    const Pan = ConstantPowerPan(f32num);
    try testing.expect(port.classify(Pan) == .Map);
    try testing.expect(port.MapInPort(Pan).Elem == types.Sample(f32));
    // The output port's element identity remains the stereo Frame even though
    // the buffer is written through a planar view.
    try testing.expect(port.MapOutPort(Pan).Elem == types.Frame(f32, .stereo));

    var pan = Pan{ .pan = 0 };
    var in: [3]types.Sample(f32) = .{ .{ .ch = .{1} }, .{ .ch = .{0.5} }, .{ .ch = .{-1} } };
    // Plane-major stereo backing: [L0,L1,L2][R0,R1,R2].
    var out_buf: [6]f32 = undefined;
    const out = types.Planar(f32, .stereo).fromBase(&out_buf, 3);
    pan.process(&in, out);
    const root_half: f32 = @sqrt(0.5);
    for (in, out.plane(0), out.plane(1)) |x, l, r| {
        try testing.expectApproxEqAbs(x.ch[0] * root_half, l, 1e-6);
        try testing.expectApproxEqAbs(x.ch[0] * root_half, r, 1e-6);
    }
}

test "ConstantPowerPan preserves power L²+R² across the pan sweep" {
    const Pan = ConstantPowerPan(f32num);
    var pos: f32 = -1.0;
    while (pos <= 1.0) : (pos += 0.25) {
        var pan = Pan{ .pan = pos };
        var in: [1]types.Sample(f32) = .{.{ .ch = .{1} }};
        var out_buf: [2]f32 = undefined;
        const out = types.Planar(f32, .stereo).fromBase(&out_buf, 1);
        pan.process(&in, out);
        const lv = out.plane(0)[0];
        const rv = out.plane(1)[0];
        const power = lv * lv + rv * rv;
        try testing.expectApproxEqAbs(@as(f32, 1.0), power, 1e-6);
    }
}

test "hard-left puts all signal in L, hard-right all in R" {
    const Pan = ConstantPowerPan(f32num);
    var left = Pan{ .pan = -1 };
    var right = Pan{ .pan = 1 };
    var in: [1]types.Sample(f32) = .{.{ .ch = .{1} }};
    var ol_buf: [2]f32 = undefined;
    var orr_buf: [2]f32 = undefined;
    const ol = types.Planar(f32, .stereo).fromBase(&ol_buf, 1);
    const orr = types.Planar(f32, .stereo).fromBase(&orr_buf, 1);
    left.process(&in, ol);
    right.process(&in, orr);
    try testing.expectApproxEqAbs(@as(f32, 1.0), ol.plane(0)[0], 1e-6); // L = cos(0) = 1
    try testing.expectApproxEqAbs(@as(f32, 0.0), ol.plane(1)[0], 1e-6); // R = sin(0) = 0
    try testing.expectApproxEqAbs(@as(f32, 0.0), orr.plane(0)[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), orr.plane(1)[0], 1e-6);
}

// --- spatial up/down-mix matrix + balance/width ---------------------------

/// Independent oracle: a naive triple-loop plane-major matrix-vector mix, sharing
/// none of `MixMatrix.process`'s plane/skip-zero machinery — only the math.
fn oracleMix(
    comptime Ci: usize,
    comptime Co: usize,
    matrix: [Co][Ci]f32,
    in_planes: [Ci][]const f32,
    out_planes: [Co][]f32,
) void {
    const n = out_planes[0].len;
    for (0..n) |k| {
        for (0..Co) |o| {
            var acc: f32 = 0;
            for (0..Ci) |i| acc += matrix[o][i] * in_planes[i][k];
            out_planes[o][k] = acc;
        }
    }
}

test "MixMatrix mono→stereo / stereo→mono classify as layout-changing Maps" {
    const port = core.port;
    const Up = Upmix(f32num, .mono, .stereo);
    const Dn = Downmix(f32num, .stereo, .mono);
    try testing.expect(port.classify(Up) == .Map);
    try testing.expect(port.classify(Dn) == .Map);
    try testing.expect(port.MapInPort(Up).Elem == types.Frame(f32, .mono));
    try testing.expect(port.MapOutPort(Up).Elem == types.Frame(f32, .stereo));
    try testing.expect(port.MapInPort(Dn).Elem == types.Frame(f32, .stereo));
    try testing.expect(port.MapOutPort(Dn).Elem == types.Frame(f32, .mono));
}

test "canonical 5.1→stereo downmix matches the independent matrix-vector oracle (BS.775)" {
    const Dn = Downmix(f32num, .surround_5_1, .stereo);
    var blk = Dn{};
    // 5.1 planes [FL,FR,FC,LFE,Ls,Rs], 3 frames each, distinct ramps per channel.
    const n = 3;
    var in_buf: [6 * n]f32 = undefined;
    for (0..6) |c| for (0..n) |k| {
        in_buf[c * n + k] = @floatFromInt(10 * (c + 1) + k);
    };
    const in = types.PlanarConst(f32, .surround_5_1).fromBase(&in_buf, n);
    var out_buf: [2 * n]f32 = undefined;
    const out = types.Planar(f32, .stereo).fromBase(&out_buf, n);
    blk.process(in, out);

    // Oracle over the SAME canonical matrix, computed independently.
    const m = layout.canonicalMixMatrix(.surround_5_1, .stereo).?;
    var oin: [6][]const f32 = undefined;
    for (0..6) |c| oin[c] = in_buf[c * n ..][0..n];
    var oout_buf: [2 * n]f32 = undefined;
    const oout: [2][]f32 = .{ oout_buf[0..n], oout_buf[n..][0..n] };
    oracleMix(6, 2, m, oin, oout);
    for (0..2) |o| for (0..n) |k| {
        try testing.expectApproxEqAbs(oout[o][k], out.plane(o)[k], 1e-6);
    };
    // Spot-check the law itself: Lo = FL + .707·FC + .707·Ls at k=0.
    const fl = in_buf[0 * n + 0];
    const fc = in_buf[2 * n + 0];
    const ls = in_buf[4 * n + 0];
    try testing.expectApproxEqAbs(fl + inv_sqrt2 * fc + inv_sqrt2 * ls, out.plane(0)[0], 1e-5);
}

test "canonical 5.1↔7.1 up/down-mix round-trips the front bed and folds the surrounds" {
    // Upmix 5.1→7.1 then downmix back; FL/FR/FC/LFE survive exactly, the side pair
    // survives (7.1 has a free back pair), so the round trip is the identity on 5.1.
    const Up = Upmix(f32num, .surround_5_1, .surround_7_1);
    const Dn = Downmix(f32num, .surround_7_1, .surround_5_1);
    var up = Up{};
    var dn = Dn{};
    const n = 2;
    var a_buf: [6 * n]f32 = undefined;
    for (0..6) |c| for (0..n) |k| {
        a_buf[c * n + k] = @floatFromInt(c + 1 + k);
    };
    const a = types.PlanarConst(f32, .surround_5_1).fromBase(&a_buf, n);
    var b_buf: [8 * n]f32 = undefined;
    const b = types.Planar(f32, .surround_7_1).fromBase(&b_buf, n);
    up.process(a, b);
    const b_c = types.PlanarConst(f32, .surround_7_1).fromBase(&b_buf, n);
    var c_buf: [6 * n]f32 = undefined;
    const c = types.Planar(f32, .surround_5_1).fromBase(&c_buf, n);
    dn.process(b_c, c);
    for (0..6) |ch| for (0..n) |k| {
        try testing.expectApproxEqAbs(a_buf[ch * n + k], c.plane(ch)[k], 1e-6);
    };
}

test "canonicalMixMatrix registers only the positional pairs (the L2 boundary)" {
    // Registered positional pairs return a matrix.
    try testing.expect(layout.canonicalMixMatrix(.mono, .stereo) != null);
    try testing.expect(layout.canonicalMixMatrix(.stereo, .surround_5_1) != null);
    try testing.expect(layout.canonicalMixMatrix(.surround_7_1, .surround_5_1) != null);
    // An unregistered layout (discrete bus / ambisonic) has no canonical matrix —
    // the data behind negotiation rejecting the pair as a hard mismatch.
    const amb: types.ChannelLayout = .{ .ambisonic = .{ .order = 1, .ordering = .acn, .norm = .sn3d } };
    try testing.expect(layout.canonicalMixMatrix(.stereo, amb) == null);
    try testing.expect(layout.canonicalMixMatrix(.{ .discrete = 2 }, .stereo) == null);
}

test "Balance attenuates one channel only; center is unity" {
    const Bal = Balance(f32num);
    var in_buf: [2]f32 = .{ 1.0, 1.0 };
    const in = types.PlanarConst(f32, .stereo).fromBase(&in_buf, 1);
    var out_buf: [2]f32 = undefined;
    const out = types.Planar(f32, .stereo).fromBase(&out_buf, 1);
    // center: unity on both.
    var c = Bal{ .balance = 0 };
    c.process(in, out);
    try testing.expectApproxEqAbs(@as(f32, 1.0), out.plane(0)[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), out.plane(1)[0], 1e-6);
    // full left: right muted, left untouched.
    var l = Bal{ .balance = -1 };
    l.process(in, out);
    try testing.expectApproxEqAbs(@as(f32, 1.0), out.plane(0)[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.0), out.plane(1)[0], 1e-6);
    // half right: left scaled by 0.5, right untouched.
    var r = Bal{ .balance = 0.5 };
    r.process(in, out);
    try testing.expectApproxEqAbs(@as(f32, 0.5), out.plane(0)[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), out.plane(1)[0], 1e-6);
}

test "Width: unity preserves, zero collapses to mid, double drops the mid at the limit" {
    const Wd = Width(f32num);
    var in_buf: [2]f32 = .{ 1.0, -1.0 }; // pure side (mid=0, side=1)
    const in = types.PlanarConst(f32, .stereo).fromBase(&in_buf, 1);
    var out_buf: [2]f32 = undefined;
    const out = types.Planar(f32, .stereo).fromBase(&out_buf, 1);
    // width=1 ⇒ identity.
    var w1 = Wd{ .width = 1 };
    w1.process(in, out);
    try testing.expectApproxEqAbs(@as(f32, 1.0), out.plane(0)[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, -1.0), out.plane(1)[0], 1e-6);
    // width=0 ⇒ both channels = mid = 0.
    var w0 = Wd{ .width = 0 };
    w0.process(in, out);
    try testing.expectApproxEqAbs(@as(f32, 0.0), out.plane(0)[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.0), out.plane(1)[0], 1e-6);
    // A centered (mono) signal is unaffected by width (no side to scale).
    var monoin: [2]f32 = .{ 0.7, 0.7 };
    const min = types.PlanarConst(f32, .stereo).fromBase(&monoin, 1);
    var w2 = Wd{ .width = 2 };
    w2.process(min, out);
    try testing.expectApproxEqAbs(@as(f32, 0.7), out.plane(0)[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.7), out.plane(1)[0], 1e-6);
}

// --- VBAP ------------------------------------------------------------------

test "Vbap classifies as a layout-changing Map mono→5.1" {
    const port = core.port;
    const V = Vbap(f32num, .surround_5_1);
    try testing.expect(port.classify(V) == .Map);
    try testing.expect(port.MapInPort(V).Elem == types.Sample(f32));
    try testing.expect(port.MapOutPort(V).Elem == types.Frame(f32, .surround_5_1));
}

test "Vbap: a source exactly at a speaker azimuth puts all power in that speaker" {
    // Independent oracle: the EXPECTED outcome (one speaker at gain 1, rest 0) is
    // a property of VBAP at a node, not a re-derivation of the block's solver.
    const V = Vbap(f32num, .surround_5_1);
    const az = [_]f32{ 30, -30, 0, 110, -110 }; // FL,FR,FC,Ls,Rs (skip LFE NaN)
    const idx = [_]usize{ 0, 1, 2, 4, 5 };
    for (az, idx) |a, target| {
        var blk = V{ .azimuth = a };
        var in: [1]types.Sample(f32) = .{.{ .ch = .{1} }};
        var out_buf: [6]f32 = undefined;
        const out = types.Planar(f32, .surround_5_1).fromBase(&out_buf, 1);
        blk.process(&in, out);
        for (0..6) |c| {
            const want: f32 = if (c == target) 1.0 else 0.0;
            try testing.expectApproxEqAbs(want, out.plane(c)[0], 1e-5);
        }
    }
}

test "Vbap: a source between two speakers splits power between exactly those two, Σg²≈1" {
    const V = Vbap(f32num, .surround_5_1);
    // Sweep across the front arc (FC at 0° to FL at 30°) and the FR..FC arc.
    var a: f32 = -110;
    while (a <= 110) : (a += 5) {
        var blk = V{ .azimuth = a };
        var in: [1]types.Sample(f32) = .{.{ .ch = .{1} }};
        var out_buf: [6]f32 = undefined;
        const out = types.Planar(f32, .surround_5_1).fromBase(&out_buf, 1);
        blk.process(&in, out);
        // LFE (index 3) must always be silent.
        try testing.expectApproxEqAbs(@as(f32, 0), out.plane(3)[0], 1e-6);
        // Constant power: the summed square of all speaker gains is 1.
        var power: f32 = 0;
        var nonzero: usize = 0;
        for (0..6) |c| {
            const gc = out.plane(c)[0];
            power += gc * gc;
            if (@abs(gc) > 1e-6) nonzero += 1;
        }
        try testing.expectApproxEqAbs(@as(f32, 1.0), power, 1e-5);
        // At most two speakers are ever active (the bracketing pair).
        try testing.expect(nonzero <= 2);
    }
}

test "Vbap stereo: 0° centre splits equally between L and R (constant power)" {
    const V = Vbap(f32num, .stereo);
    var blk = V{ .azimuth = 0 };
    var in: [1]types.Sample(f32) = .{.{ .ch = .{1} }};
    var out_buf: [2]f32 = undefined;
    const out = types.Planar(f32, .stereo).fromBase(&out_buf, 1);
    blk.process(&in, out);
    const root_half: f32 = @sqrt(0.5);
    // By symmetry a centred source is equal on both, at √½ for unit power.
    try testing.expectApproxEqAbs(root_half, out.plane(0)[0], 1e-5);
    try testing.expectApproxEqAbs(root_half, out.plane(1)[0], 1e-5);
}

// --- AmbisonicEncode -------------------------------------------------------

/// Independent oracle for the order-1 SN3D real SH at a direction (degrees).
/// Hand-written `[W, Y, Z, X] = [1, sin az cos el, sin el, cos az cos el]`,
/// sharing none of the block's `sh()` switch.
fn oracleOrder1(az_deg: f32, el_deg: f32) [4]f32 {
    const d = std.math.pi / 180.0;
    const az = @as(f32, az_deg) * d;
    const el = @as(f32, el_deg) * d;
    return .{ 1.0, @sin(az) * @cos(el), @sin(el), @cos(az) * @cos(el) };
}

test "AmbisonicEncode classifies as a layout-changing Map mono→ambisonic1" {
    const port = core.port;
    const E = AmbisonicEncode(f32num, 1);
    const amb1: types.ChannelLayout = .{ .ambisonic = .{ .order = 1, .ordering = .acn, .norm = .sn3d } };
    try testing.expect(port.classify(E) == .Map);
    try testing.expect(port.MapInPort(E).Elem == types.Sample(f32));
    try testing.expect(port.MapOutPort(E).Elem == types.Frame(f32, amb1));
}

test "AmbisonicEncode order-1 W/Y/Z/X match the hand-computed SN3D real SH" {
    const E = AmbisonicEncode(f32num, 1);
    const dirs = [_][2]f32{ .{ 0, 0 }, .{ 30, 0 }, .{ 90, 0 }, .{ 0, 45 }, .{ 45, 30 }, .{ -60, -20 } };
    for (dirs) |dir| {
        var blk = E{ .azimuth = dir[0], .elevation = dir[1] };
        var in: [1]types.Sample(f32) = .{.{ .ch = .{1} }};
        var out_buf: [4]f32 = undefined;
        const out = types.Planar(f32, .{ .ambisonic = .{ .order = 1, .ordering = .acn, .norm = .sn3d } }).fromBase(&out_buf, 1);
        blk.process(&in, out);
        const want = oracleOrder1(dir[0], dir[1]);
        for (0..4) |k| try testing.expectApproxEqAbs(want[k], out.plane(k)[0], 1e-5);
    }
}

test "AmbisonicEncode: the omni W channel is direction-independent (always the input)" {
    const E = AmbisonicEncode(f32num, 2);
    const dirs = [_][2]f32{ .{ 0, 0 }, .{ 137, -22 }, .{ -88, 61 } };
    for (dirs) |dir| {
        var blk = E{ .azimuth = dir[0], .elevation = dir[1] };
        var in: [1]types.Sample(f32) = .{.{ .ch = .{0.42} }};
        var out_buf: [9]f32 = undefined;
        const out = types.Planar(f32, .{ .ambisonic = .{ .order = 2, .ordering = .acn, .norm = .sn3d } }).fromBase(&out_buf, 1);
        blk.process(&in, out);
        try testing.expectApproxEqAbs(@as(f32, 0.42), out.plane(0)[0], 1e-6); // W = input
    }
}

// --- AmbisonicDecode -------------------------------------------------------

test "AmbisonicDecode classifies as a layout-changing Map ambisonic1→stereo" {
    const port = core.port;
    const D = AmbisonicDecode(f32num, 1, .stereo);
    const amb1: types.ChannelLayout = .{ .ambisonic = .{ .order = 1, .ordering = .acn, .norm = .sn3d } };
    try testing.expect(port.classify(D) == .Map);
    try testing.expect(port.MapInPort(D).Elem == types.Frame(f32, amb1));
    try testing.expect(port.MapOutPort(D).Elem == types.Frame(f32, .stereo));
}

test "AmbisonicDecode: a pure-W (omni) field decodes equally to every speaker" {
    // Independent oracle: Y_0 = 1 for all directions, so a W-only field of value c
    // must land as c/N on every (non-LFE) speaker, N = (order+1)² = 9 here.
    const D = AmbisonicDecode(f32num, 2, .surround_5_1);
    var blk = D{};
    var in_buf: [9]f32 = [_]f32{0} ** 9;
    in_buf[0] = 3.0; // pure W
    const in = types.PlanarConst(f32, .{ .ambisonic = .{ .order = 2, .ordering = .acn, .norm = .sn3d } }).fromBase(&in_buf, 1);
    var out_buf: [6]f32 = undefined;
    const out = types.Planar(f32, .surround_5_1).fromBase(&out_buf, 1);
    blk.process(in, out);
    const want: f32 = 3.0 / 9.0;
    for (0..6) |c| {
        if (c == 3) {
            try testing.expectApproxEqAbs(@as(f32, 0), out.plane(c)[0], 1e-6); // LFE silent
        } else {
            try testing.expectApproxEqAbs(want, out.plane(c)[0], 1e-6);
        }
    }
}

test "AmbisonicDecode: encode-then-decode concentrates energy at the speaker's direction" {
    // Encode a point source at a speaker direction, decode to that ring, and check
    // the matching speaker carries the most energy. Independent oracle: the basic
    // SN3D decode is the encoder transpose, so the on-axis speaker is the argmax.
    const order = 2;
    const amb: types.ChannelLayout = .{ .ambisonic = .{ .order = order, .ordering = .acn, .norm = .sn3d } };
    const E = AmbisonicEncode(f32num, order);
    const D = AmbisonicDecode(f32num, order, .surround_5_1);
    const az = [_]f32{ 30, -30, 0, 110, -110 };
    const idx = [_]usize{ 0, 1, 2, 4, 5 };
    for (az, idx) |a, target| {
        var enc = E{ .azimuth = a, .elevation = 0 };
        var dec = D{};
        var in: [1]types.Sample(f32) = .{.{ .ch = .{1} }};
        var b_buf: [9]f32 = undefined;
        const b = types.Planar(f32, amb).fromBase(&b_buf, 1);
        enc.process(&in, b);
        const b_c = types.PlanarConst(f32, amb).fromBase(&b_buf, 1);
        var out_buf: [6]f32 = undefined;
        const out = types.Planar(f32, .surround_5_1).fromBase(&out_buf, 1);
        dec.process(b_c, out);
        // The on-axis speaker is the strictly largest output (and positive).
        const on = out.plane(target)[0];
        try testing.expect(on > 0);
        for (0..6) |c| {
            if (c == target or c == 3) continue;
            try testing.expect(on > out.plane(c)[0]);
        }
    }
}
