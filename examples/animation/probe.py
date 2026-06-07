#!/usr/bin/env python3
"""examples/animation/probe.py — thin mono/stereo probe for the animation pipeline.

Answers one question: does this input carry *usable* stereo information? A file can
be a 2-channel container yet hold effectively mono content (a phone voice memo, a
dual-mono bounce). Rendering that "in stereo" would be wasted work and a misleading
picture, so the pipeline refuses it (see render.py --channels stereo).

"Usable stereo" = the container has ≥ 2 channels AND the stereo *difference* (Side =
(L−R)/2) carries a non-trivial share of the energy. The Side/(Mid+Side) energy
fraction is the decisive number; SIDE_THRESHOLD is the cutoff.

    python examples/animation/probe.py <audio-file>          # human report, exit 0
    python examples/animation/probe.py <audio-file> --require-stereo   # exit 1 if mono

Used as a library: `from probe import probe; probe(path) -> dict`.
"""
from __future__ import annotations

import json
import subprocess
import sys

import numpy as np

# Minimum Side/(Mid+Side) energy fraction to call a file "usably stereo".
SIDE_THRESHOLD = 0.03  # 3%


def _ffprobe_channels(path: str) -> int:
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "a:0",
         "-show_entries", "stream=channels", "-of", "csv=p=0", path],
        capture_output=True, text=True,
    ).stdout.strip()
    try:
        return int(out.splitlines()[0])
    except Exception:
        return 0


def probe(path: str) -> dict:
    """Return {container_channels, side_frac, correlation, lr_ratio, is_stereo}."""
    channels = _ffprobe_channels(path)
    if channels < 2:
        return {"container_channels": channels, "side_frac": 0.0, "correlation": 1.0,
                "lr_ratio": 1.0, "is_stereo": False, "reason": "single-channel container"}
    raw = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", path, "-f", "f32le", "-acodec", "pcm_f32le",
         "-ac", "2", "-"], capture_output=True,
    ).stdout
    x = np.frombuffer(raw, dtype="<f4")
    x = x[: len(x) // 2 * 2].reshape(-1, 2)
    L, R = x[:, 0], x[:, 1]
    mid = (L + R) * 0.5
    side = (L - R) * 0.5
    eM, eS = float(np.mean(mid ** 2)), float(np.mean(side ** 2))
    side_frac = eS / (eM + eS + 1e-12)
    denom = np.sqrt(np.mean(L ** 2) * np.mean(R ** 2)) + 1e-12
    corr = float(np.mean(L * R) / denom)
    eL, eR = float(np.mean(L ** 2)), float(np.mean(R ** 2))
    is_stereo = side_frac >= SIDE_THRESHOLD
    return {
        "container_channels": channels,
        "side_frac": round(side_frac, 4),
        "correlation": round(corr, 4),
        "lr_ratio": round(eL / (eR + 1e-12), 3),
        "is_stereo": is_stereo,
        "reason": (f"side energy {side_frac*100:.2f}% "
                   f"{'≥' if is_stereo else '<'} {SIDE_THRESHOLD*100:.0f}% threshold"),
    }


def main(argv=None) -> int:
    argv = argv if argv is not None else sys.argv[1:]
    require = "--require-stereo" in argv
    paths = [a for a in argv if not a.startswith("--")]
    if not paths:
        print("usage: probe.py <audio-file> [--require-stereo]")
        return 2
    p = probe(paths[0])
    print(json.dumps(p, indent=2))
    if require and not p["is_stereo"]:
        print(f"\nERROR: '{paths[0]}' is not usably stereo ({p['reason']}).", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
