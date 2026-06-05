# Handoff — end of P16 (DSP & spatial library buildout + layout negotiation + split-radix FFT)

> **Status:** P0–P15 + **P16 COMPLETE.** The full plan §16 work-list (items 1–4) and all four
> success-criteria gates are implemented and green. Advisory handoff, not a spec; `specifications/` +
> `pan_implementation_plan.md` remain the source of truth. **Date:** 2026-06-05. **Toolchain:**
> `zig 0.16.0` (re-run `zig version` next session — Rule 13).

## Verify (run ONE AT A TIME — see the contention note; redirect to a file, trust the EXIT CODE)
`zig build test` · `-Doptimize=ReleaseSafe` · `-Doptimize=ReleaseFast` · `fmt-check` · `smoke` ·
`neg-compile` · `cross-linux` — all exit 0. `zig build bench-vdsp` for the FFT numbers.
**Do not run multiple `zig build`s concurrently:** they thrash the shared `.zig-cache`/CPU and flake the
host-load-sensitive Tier-B `parallel_concurrent_yoneda_test` (L8c); serialized, it passes 31/31.

## The full P16 surface (all shipped, all tested)
- **Spatial** (`spatial.zig`): ConstantPowerPan, Balance, Width, Upmix/Downmix/MixMatrix +
  `canonicalMixMatrix` registry, Vbap (2-D), AmbisonicEncode/Decode (ACN/SN3D orders 0–2). Float-only.
- **Filters** (`filters.zig`): StateVariable (TPT SVF), Fir, firwinLowpass/Highpass/Bandpass/Bandstop.
- **Dynamics** (`fx.zig`): Limiter, Expander, SoftClip, Trim, Chorus, Flanger (+ earlier Compressor/
  Vca/PowerGate/Comb/Allpass/Ladder/FdnMatrix).
- **Mix/routing** (`dsp_mix.zig`): SummingMixer, Splitter, MatrixRouter (Q2 int format), DryWet.
- **Spectral** (`spectral.zig`): PartitionedConvolution (UPOLA reverb), SpectralGate, SpectralEq.
- **Multi-rate filterbanks** (`filterbank.zig`): WaveletAnalysis/Synthesis (Haar), DwtOctaveTree, Cqt —
  a cascade/bank of uniform-rate Rate stages (R5).
- **FFT** (`spectral.zig`): conjugate-pair split-radix `@Vector` kernel. vDSP gap was rising with N
  (10.7→15.6×, algorithmic) → now flat ~6×. See `dev-notes/fft-split-radix-vdsp.md`.

## Layout-negotiation auto-insertion (the gate's hard criterion) — wired end-to-end
`graph.Edge.to_channels`/`to_elem_*` + `Node.is_channel_matrix`; `graph.connectCoerced` /
`builder.connectCoerced` (typed: same Lane, layout may differ); the negotiate stage uses the consumer's
`to_channels` (registered → coercion, unregistered → `error.LayoutMismatch`); `commit.insertCoercions`
materializes a `(chmatrix)` rate-1:1 Map coercion node + `runtimeMixMatrix` (runtime sibling of
`canonicalMixMatrix` — ONE coefficient source); `engine.channelMatrixThunk` binds the built-in kernel
(mirrors the resampler coercion). `tests/layout_negotiation_test.zig` proves it on the real Engine
commit+renderInto: mono→stereo + 5.1→stereo (independent BS.775 oracle), unregistered rejection, and the
codec channel-order round-trip bit-exact (§5.7e a/b/c MET; d = per-block gold-vector + dual-mux Yoneda).

## Bugs found & fixed (independent Yoneda oracles + audit)
- `MatrixRouter` integer default unity `1<<(bits-1)` overflowed to the sign bit (q15 "unity" = −1.0, a
  phase inverter) → fixed: Q2 weight format (`frac = bits-2`), default diagonal is a bit-exact passthrough.
- `Vbap` returned silence for a source exactly on a stereo speaker (f32 source trig vs f64 base-vectors →
  partner gain tripped the −1e-9 non-negativity gate) → fixed: source direction in f64.
- Rule 15: the 3 pre-existing `§9` doc-comment citations in `engine.zig` were cleaned.

## Genuinely deferred (surfaced, not silent)
- Fixed-point (q-format) path for the float-only spatial blocks + StateVariable + DryWet (documented
  `requireFloat`; mirrors the per-kernel fixed-point Biquad treatment, not yet ported).
- A planar split-complex `Spectrum` layout to shave the FFT's residual ~6× constant factor (would change
  the `Complex`-AoS contract `Spectrum`/`feat.zig` depend on).
- Higher-order / 3-D ambisonic & VBAP; a fully per-band-decimated CQT (the bandpass-bank core ships).

## P17 (next) — examples/ (Python viz) + scripts/ (audio-format → LPCM decoders). Read plan §17.
