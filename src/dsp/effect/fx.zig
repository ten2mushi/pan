//! Fused tight-feedback kernels and the applied modulation / dynamics family.
//!
//! This file is a thin re-export aggregator: the block implementations live in the
//! per-family sibling files (`fx_delay.zig`, `fx_resonant.zig`, `fx_dynamics.zig`,
//! `fx_saturation.zig`), and the shared `requireFloat`/`scalars` helpers live in
//! `fx_common.zig`. The public surface (`dsp.fx.*`) is exactly the union of those
//! files' public block factories, unchanged.
//!
//! The fused-kernel idiom these families realise: where a graph-level
//! `DelayLine`-in-a-cycle (one-block feedback latency) is too coarse — ladder
//! filters, Karplus-Strong strings, feedback combs — the tight loop is authored as
//! a **single rate-1:1 `Map` block whose `process` runs the per-sample feedback
//! loop internally** over fixed persistent state. The `z⁻¹` lives *inside* the
//! kernel, per sample, so the feedback is **sample-accurate** (not quantized to the
//! colorer's block granularity).
//!
//! The trade is explicit: you **forfeit scheduler visibility** — the loop is opaque
//! to the colorer, which cannot fuse or split across it — **in exchange for
//! sample-accuracy**. Two consequences follow: each kernel declares `delay_len`
//! (its internal ring length) so it registers as a **delay element** (a feedback
//! cycle built from it passes the SCC-has-delay check, and a self-loop is causal
//! because the per-sample state supplies the `z⁻¹`); and they are **NOT
//! `aliasing_safe`** (the state-dependent read-before-write ordering means an
//! in-place output would corrupt the recurrence).
//!
//! Persistent state (the ring + cursors + coefficients) lives in the block
//! instance, allocated once at construction — the pool-excluded category, counted
//! by the footprint but never colored. **Denormal guard:** a decaying feedback
//! tail drives the state toward subnormal magnitudes; the realtime token's
//! flush-to-zero (set on the audio thread by `enterRealtimeThread`) collapses
//! those to zero so the tail does not provoke the ~100× per-op denormal CPU
//! stall — these kernels are exactly the paths that rule protects.
//!
//! Fixed-point feedback (limit cycles, coefficient scaling, accumulator headroom)
//! needs the same care a fixed-point `Biquad` does — which is now applied THERE
//! (the DF1 wider-coefficient-format + wide-accumulator + saturate technique in
//! `filters.zig`). These feedback kernels each have their own coefficient structure
//! and have not yet had that technique applied, so the integer path still fails
//! loud (a compile error, never silently-wrong audio); they ship float-only for now
//! and are not part of the embedded fixed-point chain (gain → biquad → sink).

const fx_delay = @import("fx_delay.zig");
const fx_resonant = @import("fx_resonant.zig");
const fx_dynamics = @import("fx_dynamics.zig");
const fx_saturation = @import("fx_saturation.zig");

// Delay-line fused kernels.
pub const Comb = fx_delay.Comb;
pub const Allpass = fx_delay.Allpass;
pub const Chorus = fx_delay.Chorus;
pub const Flanger = fx_delay.Flanger;
pub const KarplusStrong = fx_delay.KarplusStrong;

// Resonant fused kernels.
pub const Ladder = fx_resonant.Ladder;
pub const FdnMatrix = fx_resonant.FdnMatrix;

// Modulation appliers & adaptive dynamics.
pub const Vca = fx_dynamics.Vca;
pub const Agc = fx_dynamics.Agc;
pub const AgcController = fx_dynamics.AgcController;
pub const PowerGate = fx_dynamics.PowerGate;
pub const Compressor = fx_dynamics.Compressor;
pub const CompressorController = fx_dynamics.CompressorController;
pub const Limiter = fx_dynamics.Limiter;
pub const Expander = fx_dynamics.Expander;

// Adaptive-filter cancellers and waveshaping / trim.
pub const Aec = fx_saturation.Aec;
pub const HowlSuppressor = fx_saturation.HowlSuppressor;
pub const SoftClip = fx_saturation.SoftClip;
pub const Trim = fx_saturation.Trim;

test {
    // Pull the family files' tests into this aggregator's test scope so they stay
    // counted when reached via `dsp.zig`'s `@import("effect/fx.zig")`.
    @import("std").testing.refAllDecls(@This());
    _ = fx_delay;
    _ = fx_resonant;
    _ = fx_dynamics;
    _ = fx_saturation;
}
