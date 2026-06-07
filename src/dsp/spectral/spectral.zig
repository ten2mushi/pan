//! The rate-elastic seam — `Rate` blocks where output-elements-per-input differ
//! from the algorithmic latency, and the element type changes across the seam.
//!
//! This file is a thin re-export aggregator: the block implementations live in the
//! per-family sibling files (`spectral_core.zig`, `spectral_timepitch.zig`,
//! `spectral_fx.zig`), and the shared FFT kernel + Hann window + float/pow2 guards
//! live in `spectral_common.zig`. The public surface (`dsp.spectral.*`) is exactly
//! the union of those files' public block factories plus the re-exported FFT
//! primitives, unchanged.
//!
//! A `Map` is rate-1:1 (`out.len == in.len`); these blocks are NOT. A `Framer`
//! emits one windowed frame every `HOP` input samples (`out_per_in = 1:HOP`); an
//! `Stft` emits one spectral frame per hop and an `iStft` reconstructs `HOP`
//! samples per spectral frame; a `Resampler` emits `L` samples per `M` input
//! samples. Each owns an internal clocked ring (the overlap/history buffer), so
//! it is not a pure function of its current input slice — that ring is the
//! defining `Rate` smell. Each declares the two orthogonal rate facts the commit
//! pass needs and the type system cannot infer: the **rate ratio** `out_per_in`
//! and the **group delay** `algorithmic_latency` (measured in the block's own
//! OUTPUT elements). Declaring either without the other is a build error.
//!
//! The pull contract is `pull(self, in, want, out) -> produced`: given `want`
//! output elements demanded and the upstream-produced `in` slice, the block emits
//! up to `want` outputs into `out` and returns the count produced (the executor
//! zero-fills any unproduced tail during latency priming). A `needed_input(want)`
//! companion reports how many input elements `want` outputs require, which the
//! rate scheduler compiles into the upstream demand. The internal ring absorbs
//! any hop-vs-buffer (`HOP ∤ N`) misalignment across calls, so the scheduler never
//! assumes the hop divides the device block.
//!
//! COLA reconstruction: `Stft` applies a Hann analysis window; at 50% overlap
//! (`HOP = FRAME/2`) the Hann window satisfies the constant-overlap-add condition
//! `Σ_k w[n − kH] = 1`, so `iStft` reconstructs by plain overlap-add (no synthesis
//! window, no normalization) and `iStft ∘ Stft` is the input delayed by `FRAME −
//! HOP` samples, exact up to FFT round-off. That whole round-trip group delay is
//! the analysis framing's (`Stft.algorithmic_latency`); synthesis adds none.
//!
//! Float-only: the FFT and windowed overlap-add need real arithmetic; the
//! fixed-point spectral path (block-floating-point scaling, accumulator headroom)
//! is the embedded-precision phase, so the integer lane fails loud here.
//!
//! Denormal hygiene: a decaying STFT tail / resampler ringing slips toward
//! subnormal magnitudes; the realtime token's flush-to-zero (set on the audio
//! thread by `enterRealtimeThread`) collapses those so the seam does not provoke
//! the denormal CPU stall — the same protection the feedback kernels rely on.

const spectral_common = @import("spectral_common.zig");
const spectral_core = @import("spectral_core.zig");
const spectral_timepitch = @import("spectral_timepitch.zig");
const spectral_fx = @import("spectral_fx.zig");

// FFT primitives (public in the spectral namespace, re-exported unchanged).
pub const fftInPlace = spectral_common.fftInPlace;
pub const rfftForward = spectral_common.rfftForward;

// Spectral / time-frame port elements + the STFT analysis/synthesis Rate pair.
pub const Spectrum = spectral_core.Spectrum;
pub const TimeFrame = spectral_core.TimeFrame;
pub const Framer = spectral_core.Framer;
pub const Stft = spectral_core.Stft;
pub const iStft = spectral_core.iStft;
pub const PowerSpectrum = spectral_core.PowerSpectrum;

// Time- and pitch-domain resamplers.
pub const Resampler = spectral_timepitch.Resampler;
pub const Varispeed = spectral_timepitch.Varispeed;
pub const TimeStretch = spectral_timepitch.TimeStretch;
pub const PitchShift = spectral_timepitch.PitchShift;

// Frequency-domain processors.
pub const PartitionedConvolution = spectral_fx.PartitionedConvolution;
pub const SpectralGate = spectral_fx.SpectralGate;
pub const SpectralEq = spectral_fx.SpectralEq;

test {
    // Pull the family files' tests into this aggregator's test scope so they stay
    // counted when reached via `dsp.zig`'s `@import("spectral/spectral.zig")`.
    @import("std").testing.refAllDecls(@This());
    _ = spectral_common;
    _ = spectral_core;
    _ = spectral_timepitch;
    _ = spectral_fx;
}
