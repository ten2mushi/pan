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


_REFERENCES = {
    "Gain": _ref_gain,
    # Add a reference per block as it lands (biquad, panner, framer, ...).
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
    if block not in _REFERENCES:
        sys.exit(f"no reference compute for block {block!r} — add one to _REFERENCES")

    x = _input_signal(manifest["n_frames"], fmt["channels"], precision, manifest["seed"])
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
