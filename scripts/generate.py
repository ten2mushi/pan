#!/usr/bin/env python3
"""pan gold-vector generator (SKELETON).

This is the COMMITTED half of the generate-on-demand vector-storage policy
(see specifications/pan_testing_and_vector_contract.md §3): the script + the
per-block JSON manifests are committed; the raw input.bin / expected.bin blobs
are GENERATED here and git-ignored (disk-minimal, per notes/brief.md).

It reads a manifest (schema = §4 of the contract), generates a deterministic
input signal from the manifest seed, computes the SciPy/NumPy *reference*
(the independent external oracle — catalog.md §0.1, Rule 9), and writes both
as native-endian raw sample bytes next to the manifest.

On-disk layout: raw native-endian samples, no header. pan's internal canonical
buffer form is PLANAR (plane-major: all of channel 0, then all of channel 1, …),
and the gold blobs match THAT form so a test can read them straight into pan's
planar buffer with no transpose. A mono (C = 1) blob is therefore identical
whether viewed as frame-major or plane-major (one channel). For C > 1 (e.g.
stereo pan output), `expected.bin` is `[ch0_0…ch0_{n-1}][ch1_0…ch1_{n-1}]…`
(plane-major), NOT `[ch0_0,ch1_0,ch0_1,ch1_1,…]` (interleaved). The interleaved
device LPCM form lives only at the I/O boundary (the codec transposes there),
not in the internal vector format. The manifest carries shape/precision so the
reader needs no in-band metadata.

The float oracle is compared by the test harness with numpy.allclose
(|pan - ref| <= atol + rtol*|ref|); integer/fixed-point is compared bit-exact
(contract §1). This script MUST be DETERMINISTIC given (manifest, seed): the
same NumPy RNG seed, dtype, and byte order must reproduce byte-identical blobs
across machines, or the float tolerance goalposts would silently move. Run
`generate.py <manifest> --check` to assert that determinism in-process.

Quantization convention (fixed-point, bit-exact target): round-half-to-even
(np.rint) then saturate to the lane range. The Zig fixed-point kernels must
match this exactly when they land.

STATUS: starting point (Rule 2 — minimum that solves the problem). Only the
`Gain` reference is stubbed; add a reference per block as blocks land (a biquad
reference will need SciPy's lfilter). Do not add speculative machinery here.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys

import numpy as np


# Manifest "precision" string -> NumPy dtype. Native byte order ('=') so the
# raw blobs match the Zig side's native-endian read (contract §3).
_DTYPE = {
    "f32": np.dtype("=f4"),
    "f64": np.dtype("=f8"),
    "i8": np.dtype("=i1"),
    "i16": np.dtype("=i2"),
    "q15": np.dtype("=i2"),  # q15 rides in i16 storage (catalog §1.4)
    "i32": np.dtype("=i4"),
    "q31": np.dtype("=i4"),  # q31 rides in i32 storage
    "i64": np.dtype("=i8"),
}

_IS_FLOAT = {"f32", "f64"}


def _input_signal(n_frames: int, channels: int, precision: str, seed: int) -> np.ndarray:
    """Deterministic test signal in float64 working precision, shape (n_frames, channels)."""
    rng = np.random.default_rng(seed)
    # White noise in [-1, 1); a starting-point signal. Swap for sweeps/impulses
    # per harness need (e.g. latency-contract uses an impulse — contract §5.5).
    return rng.uniform(-1.0, 1.0, size=(n_frames, channels))


# --- Block reference compute (the oracle). One function per block. ----------

def _ref_gain(x: np.ndarray, params: dict) -> np.ndarray:
    """Gain reference: y = x * 10**(gain_db/20). Computed in f64 (catalog §1.2)."""
    g = 10.0 ** (float(params["gain_db"]) / 20.0)
    return x * g


def _ref_biquad(x: np.ndarray, params: dict) -> np.ndarray:
    """Biquad reference over the normalized transfer function
    H(z) = (b0 + b1 z⁻¹ + b2 z⁻²) / (1 + a1 z⁻¹ + a2 z⁻²).

    Prefers SciPy's `lfilter` (the named oracle); when SciPy is unavailable it
    falls back to the identical transposed-direct-form-II recurrence in pure
    NumPy — `lfilter` IS this recurrence for a normalized `a0 = 1`, so the
    fallback is byte-identical to the SciPy path and still an *independent*
    reference to pan's Zig kernel. Filters each channel column independently."""
    b = [float(params["b0"]), float(params.get("b1", 0.0)), float(params.get("b2", 0.0))]
    a = [1.0, float(params.get("a1", 0.0)), float(params.get("a2", 0.0))]
    try:
        from scipy.signal import lfilter
        return lfilter(b, a, x, axis=0)
    except ModuleNotFoundError:
        y = np.empty_like(x)
        z1 = np.zeros(x.shape[1], dtype=x.dtype)
        z2 = np.zeros(x.shape[1], dtype=x.dtype)
        for n in range(x.shape[0]):
            xn = x[n]
            yn = b[0] * xn + z1
            z1 = b[1] * xn + z2 - a[1] * yn
            z2 = b[2] * xn - a[2] * yn
            y[n] = yn
        return y


def _ref_pan(x: np.ndarray, params: dict) -> np.ndarray:
    """Constant-power pan reference: mono input (n,1) → stereo (n,2). For pan
    position p ∈ [-1,1], θ = (p+1)·π/4, L = cos θ, R = sin θ (so L²+R²=1)."""
    p = float(params.get("pan", 0.0))
    theta = (p + 1.0) * (np.pi / 4.0)
    mono = x[:, :1]  # take channel 0 as the mono source
    return np.concatenate([mono * np.cos(theta), mono * np.sin(theta)], axis=1)


def _ref_resampler(x: np.ndarray, params: dict) -> np.ndarray:
    """Rational resampler reference: L:M via SciPy's polyphase `resample_poly`
    (the named oracle for the rate-elastic seam — catalog Rule 9). When SciPy is
    unavailable, falls back to NumPy `interp` linear resampling (a coarser but
    still INDEPENDENT reference; the float tolerance must be widened accordingly).
    Resamples each channel column independently. `up = L`, `down = M`."""
    up = int(params["L"])
    down = int(params["M"])
    try:
        from scipy.signal import resample_poly
        return resample_poly(x, up, down, axis=0)
    except ModuleNotFoundError:
        n_out = x.shape[0] * up // down
        idx = np.arange(n_out) * down / up
        return np.stack([np.interp(idx, np.arange(x.shape[0]), x[:, c]) for c in range(x.shape[1])], axis=1)


# NOTE on the STFT reference: an STFT's output is COMPLEX spectral frames, which
# do not fit the real-sample blob format above. pan validates the STFT numerics
# HERMETICALLY in-test against an independent naive O(N²) DFT of the Hann-windowed
# frame (tests/spectral_gold_test.zig) — a different algorithm from pan's radix-2
# real-FFT, so a genuine Rule-9 independent oracle with no external dependency.
# `xcheck_rfft.py` additionally cross-validates pan's `rfftForward` against
# `scipy.fft.rfft` directly (run on demand; not part of the hermetic `zig build test`).


_REFERENCES = {
    "Gain": _ref_gain,
    "Biquad": _ref_biquad,
    "ConstantPowerPan": _ref_pan,
    "Resampler": _ref_resampler,
    # STFT is complex-output → validated hermetically (see note above), not here.
}


# --- Fixed-point references (bit-exact target). -----------------------------
#
# Float lanes compare under numpy.allclose (the oracle's f64 arithmetic differs
# from pan's f32); INTEGER/FIXED-POINT lanes compare BIT-EXACT, so the oracle must
# implement the SAME integer arithmetic the Zig kernel runs — operating on the
# QUANTIZED INPUT CODES (the bytes in input.bin), not the real-valued signal. The
# defining op is `qMulStore`: round-half (via a +2^(frac-1) bias) of the product
# in a wider accumulator, arithmetic right shift by `frac`, saturate to the lane
# range. numpy's `>>` on int64 is an arithmetic shift, matching Zig's signed `>>`.
# This is an INDEPENDENT implementation (NumPy, not Zig) of the same spec-defined
# fixed-point arithmetic — the legitimate bit-exact contract.

_FRAC = {"q15": 15, "q31": 31, "i8": 7, "i16": 15, "i32": 31, "i64": 63}


def _q_mul_store(x_codes: np.ndarray, coeff: int, frac: int, dt: np.dtype) -> np.ndarray:
    """clamp(round((x*coeff)/2^frac)) — the bit-exact mirror of simd.qMulStore."""
    bias = 1 << (frac - 1) if frac > 0 else 0
    prod = x_codes.astype(np.int64) * np.int64(coeff)
    shifted = (prod + bias) >> frac  # arithmetic shift, matches Zig signed >>
    info = np.iinfo(dt)
    return np.clip(shifted, info.min, info.max).astype(dt)


def _round_coeff(value_real: float, frac: int, dt: np.dtype) -> int:
    """Quantize a real coefficient to q(frac), round-half-away-from-zero (matching
    Zig @round), saturated to the lane — the coefficient pan's kernel holds."""
    scale = float(1 << frac)
    info = np.iinfo(dt)
    q = np.floor(abs(value_real) * scale + 0.5)
    q = q if value_real >= 0 else -q
    return int(np.clip(q, info.min, info.max))


def _fix_gain(x_codes: np.ndarray, params: dict, frac: int, dt: np.dtype) -> np.ndarray:
    # For a BIT-EXACT fixed-point gold, the coefficient must be identical to the
    # one pan's kernel holds, to the bit. `10**(db/20)` is transcendental and can
    # differ by 1 ULP between NumPy f64 and Zig f32, so the manifest carries the
    # already-quantized integer coefficient `gain_q` directly (no transcendental in
    # the comparison). `gain_db` remains for the float manifests / documentation.
    if "gain_q" in params:
        g_q = int(params["gain_q"])
    else:
        g_q = _round_coeff(10.0 ** (float(params["gain_db"]) / 20.0), frac, dt)
    return _q_mul_store(x_codes, g_q, frac, dt)


def _fix_pan(x_codes: np.ndarray, params: dict, frac: int, dt: np.dtype) -> np.ndarray:
    # Bit-exact: use the PRE-QUANTIZED integer gains from the manifest (`pan_lq`,
    # `pan_rq`) — the same values the kernel holds via `gains_q`. `cos/sin(pan)` is
    # transcendental and would differ by ~1 ULP between f64 here and the kernel's
    # f32, shifting the quantized coefficient and every output sample, so it must
    # NOT enter the bit-exact comparison.
    lq = int(params["pan_lq"])
    rq = int(params["pan_rq"])
    mono = x_codes[:, :1]
    left = _q_mul_store(mono, lq, frac, dt)
    right = _q_mul_store(mono, rq, frac, dt)
    return np.concatenate([left, right], axis=1)


def _fix_biquad(x_codes: np.ndarray, params: dict, frac: int, dt: np.dtype) -> np.ndarray:
    # Bit-exact mirror of filters.zig's BiquadFixed (direct form I). The lane (q15
    # here) is `frac` fractional bits; the COEFFICIENTS ride in a wider Q(2.cf)
    # format, cf = bits-3, so a feedback coefficient |a1|>1 is representable (the
    # very thing a plain q15 lane number cannot hold). The five-term MAC is summed
    # in a wide accumulator (Python ints are unbounded, so no overflow — matching
    # the Zig i64/iN `Wide`), then a round-to-nearest right shift by `cf` lands the
    # result back in the lane q-format and saturates on store.
    #
    # For a bit-exact gold the coefficients must be IDENTICAL to the integers pan's
    # kernel holds, so the manifest carries the PRE-QUANTIZED integers `b0_q`…`a2_q`
    # (no transcendental coefficient design enters the comparison — exactly the
    # gain_q/pan_lq convention).
    info = np.iinfo(dt)
    cf = info.bits - 3  # coefficient fractional bits (Q2.cf), matches biquadCoeffFrac
    b0 = int(params["b0_q"])
    b1 = int(params.get("b1_q", 0))
    b2 = int(params.get("b2_q", 0))
    a1 = int(params.get("a1_q", 0))
    a2 = int(params.get("a2_q", 0))
    bias = 1 << (cf - 1)
    n, C = x_codes.shape
    y = np.empty_like(x_codes)
    for c in range(C):
        x1 = x2 = y1 = y2 = 0
        for nn in range(n):
            xn = int(x_codes[nn, c])
            acc = b0 * xn + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            yq = (acc + bias) >> cf  # Python >> on ints is arithmetic (floor), matches Zig signed >>
            yv = int(np.clip(yq, info.min, info.max))
            x2, x1 = x1, xn
            y2, y1 = y1, yv
            y[nn, c] = yv
    return y


_FIXED_REFERENCES = {
    "Gain": _fix_gain,
    "ConstantPowerPan": _fix_pan,  # uses the manifest's pre-quantized `pan_lq`/`pan_rq`
    "Biquad": _fix_biquad,  # DF1, pre-quantized Q2.cf coeffs (`b0_q`…`a2_q`) — the embedded q15 path
}


def _quantize(y: np.ndarray, precision: str) -> np.ndarray:
    """Cast the f64 reference to the manifest precision. Fixed-point uses the
    standard qN scaling and saturating round (bit-exact target — contract §1.3)."""
    dt = _DTYPE[precision]
    if precision in _IS_FLOAT:
        return y.astype(dt)
    if precision in ("q15", "q31"):
        scale = (1 << (15 if precision == "q15" else 31))
        info = np.iinfo(dt)
        q = np.rint(y * scale)
        return np.clip(q, info.min, info.max).astype(dt)
    # plain integer lanes: round-to-nearest, saturate to dtype range.
    info = np.iinfo(dt)
    return np.clip(np.rint(y), info.min, info.max).astype(dt)


def _planar_bytes(a: np.ndarray) -> bytes:
    """Serialize a (n_frames, C) sample array as PLANE-MAJOR native-endian bytes:
    all of channel 0, then all of channel 1, … (pan's internal canonical form).
    For C == 1 this equals the frame-major bytes (one channel). For C > 1 it is
    the transpose of the interleaved layout — `a.T` is (C, n), and `.tobytes()`
    flattens it C-order to `[ch0…][ch1…]…`. `ascontiguousarray` makes the
    transposed view contiguous so the byte order is plane-major as intended."""
    return np.ascontiguousarray(a.T).tobytes()


def _compute_blobs(manifest: dict, manifest_path: pathlib.Path) -> tuple[bytes, bytes]:
    """Deterministically compute (input_bytes, expected_bytes) from a manifest.
    Pure function of (manifest, seed) — the determinism contract lives here, so
    `--check` can call it twice and assert byte-equality. Both blobs are
    PLANE-MAJOR (pan's internal planar form): input is mono (C = 1, so plane-major
    == frame-major), expected is plane-major across its output channels."""
    fmt = manifest["format"]
    precision = fmt["precision"]
    if precision not in _DTYPE:
        sys.exit(f"unknown precision {precision!r} (manifest {manifest_path})")
    block = manifest["block"]
    x = _input_signal(manifest["n_frames"], fmt["channels"], precision, manifest["seed"])

    # Fixed-point lanes: bit-exact. Quantize the input to codes, then run the
    # SAME integer arithmetic the Zig kernel runs on those codes.
    if precision in _FRAC:
        if block not in _FIXED_REFERENCES:
            sys.exit(f"no fixed-point reference for block {block!r} at precision {precision!r} "
                     f"— add one to _FIXED_REFERENCES (or use a float precision)")
        dt = _DTYPE[precision]
        x_codes = _quantize(x, precision)
        y_codes = _FIXED_REFERENCES[block](x_codes, manifest.get("params", {}), _FRAC[precision], dt)
        return _planar_bytes(x_codes), _planar_bytes(y_codes)

    # Float lanes: allclose. Real-valued reference, then cast to the lane.
    if block not in _REFERENCES:
        sys.exit(f"no reference compute for block {block!r} — add one to _REFERENCES")
    y = _REFERENCES[block](x, manifest.get("params", {}))
    return _planar_bytes(_quantize(x, precision)), _planar_bytes(_quantize(y, precision))


def generate(manifest_path: pathlib.Path) -> None:
    manifest = json.loads(manifest_path.read_text())
    input_bytes, expected_bytes = _compute_blobs(manifest, manifest_path)

    out_dir = manifest_path.with_suffix("")  # tests/vectors/<name>/
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "input.bin").write_bytes(input_bytes)
    (out_dir / "expected.bin").write_bytes(expected_bytes)
    print(f"wrote {out_dir}/input.bin and expected.bin "
          f"({manifest['n_frames']} frames x {manifest['format']['channels']} ch, "
          f"{manifest['format']['precision']})")


def check(manifest_path: pathlib.Path) -> None:
    """Assert the generator is byte-reproducible: compute the blobs twice and
    fail loud on any drift (Rule 12 — the determinism contract is executable)."""
    manifest = json.loads(manifest_path.read_text())
    a = _compute_blobs(manifest, manifest_path)
    b = _compute_blobs(manifest, manifest_path)
    if a != b:
        sys.exit(f"DETERMINISM VIOLATION: {manifest_path} produced differing blobs across two runs")
    print(f"ok: {manifest_path.name} is byte-reproducible "
          f"(input {len(a[0])} B, expected {len(a[1])} B)")


def main() -> None:
    ap = argparse.ArgumentParser(description="pan gold-vector generator.")
    ap.add_argument("manifest", type=pathlib.Path,
                    help="path to a vector manifest JSON (e.g. tests/vectors/gain_f32.json)")
    ap.add_argument("--check", action="store_true",
                    help="assert byte-reproducibility across two runs instead of writing blobs")
    args = ap.parse_args()
    if args.check:
        check(args.manifest)
    else:
        generate(args.manifest)


if __name__ == "__main__":
    main()
