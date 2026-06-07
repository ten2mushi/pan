//! Feature-extraction blocks — the analysis side of the library.
//!
//! This file is a thin re-export aggregator: the block implementations live in the
//! per-family sibling files (`feat_spectral.zig`, `feat_tonal.zig`,
//! `feat_temporal.zig`). The public surface (`dsp.feat.*`) is exactly the union of
//! those files' public block factories, unchanged.
//!
//! Every block is a rate-1:1 **`Map`**. The spectral/tonal blocks read a per-hop
//! **power spectrum** (`FeatureFrame(bins)`, whose `v[k]` is the magnitude² of bin
//! `k`, as emitted by `spectral.PowerSpectrum`); the temporal blocks read a windowed
//! `TimeFrame`. A `Map` consumes one frame and emits one feature per hop — one
//! feature row per analysis frame, the natural cadence for a per-frame downstream
//! consumer. Holding per-call history (the flux block keeps the previous spectrum)
//! does **not** make a block a `Rate`: a `Rate` changes the output:input element
//! *count*; a stateful `Map` still emits one-for-one.
//!
//! These are *not* proven correct — they are tested against an external
//! NumPy/librosa-equivalent oracle. To make that oracle trivial to write, each
//! block's doc-comment states its exact formula and conventions in plain prose.
//!
//! All features are computed in `f32`/`f64` regardless of the audio `Numeric`,
//! because the power spectrum is already `f32` (a `FeatureFrame`). The `num`
//! parameter is carried for surface consistency with the rest of the library
//! (`feat.Block(Num, …)`); the lane it names is the audio precision upstream, not
//! the feature precision.

const feat_spectral = @import("feat_spectral.zig");
const feat_tonal = @import("feat_tonal.zig");
const feat_temporal = @import("feat_temporal.zig");

// Spectral-shape / moment / energy descriptors.
pub const Rms = feat_spectral.Rms;
pub const DominantBand = feat_spectral.DominantBand;
pub const SpectralCentroid = feat_spectral.SpectralCentroid;
pub const SpectralFlux = feat_spectral.SpectralFlux;
pub const SpectralRolloff = feat_spectral.SpectralRolloff;
pub const SpectralFlatness = feat_spectral.SpectralFlatness;
pub const SpectralEntropy = feat_spectral.SpectralEntropy;
pub const SpectralSpread = feat_spectral.SpectralSpread;
pub const SpectralSkewness = feat_spectral.SpectralSkewness;
pub const SpectralKurtosis = feat_spectral.SpectralKurtosis;
pub const SpectralCrest = feat_spectral.SpectralCrest;
pub const Hfc = feat_spectral.Hfc;

// Pitch / timbre descriptors.
pub const Mfcc = feat_tonal.Mfcc;
pub const Chroma = feat_tonal.Chroma;
pub const SpectralContrast = feat_tonal.SpectralContrast;
pub const DominantBandHysteresis = feat_tonal.DominantBandHysteresis;

// Time-domain descriptors.
pub const Zcr = feat_temporal.Zcr;
pub const TeoMean = feat_temporal.TeoMean;
pub const BallisticEnvelope = feat_temporal.BallisticEnvelope;

test {
    // Pull the family files' tests into this aggregator's test scope so they stay
    // counted when reached via `dsp.zig`'s `@import("analysis/feat.zig")`.
    @import("std").testing.refAllDecls(@This());
    _ = feat_spectral;
    _ = feat_tonal;
    _ = feat_temporal;
}
