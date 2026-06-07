//! Channel-layout coercion algebra — the canonical up/down-mix coefficient
//! matrices for the registered POSITIONAL layouts (mono/stereo/5.1/7.1).
//!
//! A layout change is a morphism whose input and output `Frame`s differ only in
//! their channel layout `L`. For a registered positional pair this morphism is a
//! fixed linear map: an output plane is `out[o] = Σ_i m[o][i]·in[i]`, where
//! `m[o][i]` is the gain from input channel `i` to output channel `o`. The
//! coefficients here are the ONE source of truth used by both the explicit
//! up/down-mix block and the auto-inserted coercion the graph compiler emits, so
//! the two paths are bit-identical.
//!
//! Channels are in pan's canonical (SMPTE) order — stereo is `[L, R]`; 5.1 is
//! `[FL, FR, FC, LFE, Ls, Rs]`; 7.1 is `[FL, FR, FC, LFE, Lb, Rb, Ls, Rs]`.
//! Downmix rows fold the centre and surrounds in at the standard −3 dB (`1/√2`)
//! so a centred or surround signal keeps roughly constant power across the fold;
//! the stereo→surround upmix places L/R on the front pair and leaves the new
//! channels silent (the conservative, phase-safe widening, distinct from a
//! decorrelating "fake surround"). Any unregistered pair (ambisonic, discrete
//! bus, custom set) returns `null` — those need an explicit spatial block, never
//! a silent coercion.

const types = @import("types.zig");

const inv_sqrt2: comptime_float = 0.7071067811865476; // 1/√2 ≈ −3 dB

/// The canonical up/down-mix coefficient matrix for a REGISTERED positional
/// layout pair, expressed in pan's canonical (SMPTE) channel order — stereo is
/// `[L, R]`; 5.1 is `[FL, FR, FC, LFE, Ls, Rs]`; 7.1 is
/// `[FL, FR, FC, LFE, Lb, Rb, Ls, Rs]`. The result `m[o][i]` is the gain from
/// input channel `i` to output channel `o`, so an output plane is
/// `out[o] = Σ_i m[o][i]·in[i]`. Returns `null` for any unregistered pair
/// (ambisonic, discrete bus, custom set) — those need an explicit spatial block,
/// never a silent coercion. The downmix rows fold the centre and surrounds in at
/// the standard −3 dB (`1/√2`) so a centred or surround signal keeps roughly
/// constant power across the fold; the stereo→surround upmix places L/R on the
/// front pair and leaves the new channels silent (the conservative, phase-safe
/// widening, distinct from a decorrelating "fake surround").
pub fn canonicalMixMatrix(comptime from: types.ChannelLayout, comptime to: types.ChannelLayout) ?[to.count()][from.count()]f32 {
    const ci = comptime from.count();
    const co = comptime to.count();
    // Only the positional layouts (mono/stereo/5.1/7.1, counts 1/2/6/8) are
    // registered; an order/count outside that set is an unregistered pair.
    if (comptime !isPositional(from) or !isPositional(to)) return null;
    {
        var m: [co][ci]f32 = [_][ci]f32{[_]f32{0} ** ci} ** co;
        switch (comptime ci * 100 + co) {
            // mono → stereo: copy the mono source to both fronts (equal-gain dual mono).
            1 * 100 + 2 => {
                m[0][0] = 1.0;
                m[1][0] = 1.0;
            },
            // stereo → mono: average (−6 dB sum, never clips a coherent pair).
            2 * 100 + 1 => {
                m[0][0] = 0.5;
                m[0][1] = 0.5;
            },
            // stereo → 5.1: front pair carries L/R; centre/LFE/surrounds silent.
            2 * 100 + 6 => {
                m[0][0] = 1.0; // FL ← L
                m[1][1] = 1.0; // FR ← R
            },
            // stereo → 7.1: same — front pair only.
            2 * 100 + 8 => {
                m[0][0] = 1.0;
                m[1][1] = 1.0;
            },
            // 5.1 → stereo (ITU-R BS.775): Lo = FL + .707·FC + .707·Ls; LFE dropped.
            6 * 100 + 2 => {
                m[0][0] = 1.0;
                m[0][2] = inv_sqrt2;
                m[0][4] = inv_sqrt2; // Ls
                m[1][1] = 1.0;
                m[1][2] = inv_sqrt2;
                m[1][5] = inv_sqrt2; // Rs
            },
            // 5.1 → 7.1: FL,FR,FC,LFE pass straight; 5.1 side pair lands on the 7.1
            // side pair (indices 6,7); the back pair is left silent.
            6 * 100 + 8 => {
                m[0][0] = 1.0; // FL
                m[1][1] = 1.0; // FR
                m[2][2] = 1.0; // FC
                m[3][3] = 1.0; // LFE
                m[6][4] = 1.0; // Ls → Ls
                m[7][5] = 1.0; // Rs → Rs
            },
            // 7.1 → 5.1: FL,FR,FC,LFE pass; fold each back channel into its side.
            8 * 100 + 6 => {
                m[0][0] = 1.0; // FL
                m[1][1] = 1.0; // FR
                m[2][2] = 1.0; // FC
                m[3][3] = 1.0; // LFE
                m[4][6] = 1.0; // Ls ← Ls
                m[4][4] = inv_sqrt2; // Ls ← Lb (−3 dB)
                m[5][7] = 1.0; // Rs ← Rs
                m[5][5] = inv_sqrt2; // Rs ← Rb
            },
            else => return null,
        }
        return m;
    }
}

fn isPositional(comptime L: types.ChannelLayout) bool {
    return switch (L) {
        .mono, .stereo, .surround_5_1, .surround_7_1 => true,
        else => false,
    };
}
