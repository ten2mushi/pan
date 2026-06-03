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

On-disk layout: raw native-endian samples, no header, frame-major
(interleaved: frame 0 all channels, frame 1 all channels, ...). The manifest
carries shape/precision so the reader needs no in-band metadata. pan stores
planar internally; the interleave↔planar conversion is an I/O-boundary concern,
not part of the vector format.

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


_REFERENCES = {
    "Gain": _ref_gain,
    "Biquad": _ref_biquad,
    "ConstantPowerPan": _ref_pan,
    # Add a reference per block as it lands (framer, resampler, ...).
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
    p = float(params.get("pan", 0.0))
    p = max(-1.0, min(1.0, p))
    theta = (p + 1.0) * (np.pi / 4.0)
    lq = _round_coeff(float(np.cos(theta)), frac, dt)
    rq = _round_coeff(float(np.sin(theta)), frac, dt)
    mono = x_codes[:, :1]
    left = _q_mul_store(mono, lq, frac, dt)
    right = _q_mul_store(mono, rq, frac, dt)
    return np.concatenate([left, right], axis=1)


_FIXED_REFERENCES = {
    "Gain": _fix_gain,
    # ConstantPowerPan fixed-point gold is deferred: the kernel derives the
    # channel gains from `cos/sin(pan)` internally (f32), so an independent f64
    # NumPy oracle cannot be guaranteed bit-identical (a 1-ULP trig difference
    # shifts the quantized coefficient and every output sample). A robust pan
    # fixed-point gold needs either pre-quantized coefficients on the kernel API
    # or the embedded-phase pinned coefficient computation. (`_fix_pan` is kept
    # below for when that lands.) Biquad fixed-point is likewise deferred (its
    # q-format kernel is a compile error until the embedded-precision phase).
    # The f32 gold covers Gain/Biquad/Pan; q15 bit-exact is proven on Gain.
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


def _compute_blobs(manifest: dict, manifest_path: pathlib.Path) -> tuple[bytes, bytes]:
    """Deterministically compute (input_bytes, expected_bytes) from a manifest.
    Pure function of (manifest, seed) — the determinism contract lives here, so
    `--check` can call it twice and assert byte-equality."""
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
        return x_codes.tobytes(), y_codes.tobytes()

    # Float lanes: allclose. Real-valued reference, then cast to the lane.
    if block not in _REFERENCES:
        sys.exit(f"no reference compute for block {block!r} — add one to _REFERENCES")
    y = _REFERENCES[block](x, manifest.get("params", {}))
    # Frame-major (interleaved) native-endian bytes; .tobytes() flattens C-order.
    return _quantize(x, precision).tobytes(), _quantize(y, precision).tobytes()


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
