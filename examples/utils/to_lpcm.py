#!/usr/bin/env python3
"""Transcode any audio file (wav/flac/mp3/m4a/webm/...) -> raw mono f32 LPCM.

This is the INPUT-side companion to `to_wav.py`: it turns a container/compressed
audio file into the header-less LPCM blob the pan analyzer examples ingest, writing

    <out_base>.mono.f32     raw native-endian float32, mono, NO header
    <out_base>.decode.json  sidecar: { sample_rate, channels, dtype, frames, ... }

It is a thin, example-facing CLI over the canonical decoder in
`scripts/decode_audio.py`. That decoder is the single source of truth for the
decode path (it is bit-checked against SciPy by `scripts/test_decode_oracle.py`,
and uses a pure-Python WAV reader with an ffmpeg fallback for compressed inputs),
so this utility deliberately does NOT re-implement decode/downmix/resample — it
reuses it.

Nothing is hardcoded: the analysis sample rate is a REQUIRED argument — choose the
rate your analyzer graph expects (e.g. 44100 makes an STFT hop of 735 land exactly
60 analysis frames per second). The output is mono by contract (the pan analyzers
read one `Sample(f32)` channel); that contract is documented in the sidecar.

Usage:
    python examples/utils/to_lpcm.py --rate 44100 \
        "data/input/incea/AUD-20260607-WA0000.m4a" data/work/incea_AUD-20260607-WA0000
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

# Reuse the canonical, oracle-tested decoder (single source of truth) instead of
# duplicating the WAV/ffmpeg decode + mono downmix + resample logic here.
_REPO_ROOT = Path(__file__).resolve().parents[2]  # examples/utils/ -> repo root
sys.path.insert(0, str(_REPO_ROOT / "scripts"))
from decode_audio import decode_to_analysis_lpcm  # noqa: E402


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description="Transcode an audio file to raw mono f32 LPCM for the pan examples."
    )
    ap.add_argument("input", help="input audio file (wav/flac/mp3/m4a/webm/...)")
    ap.add_argument(
        "out_base",
        help="output base path (writes <base>.mono.f32 + <base>.decode.json)",
    )
    ap.add_argument(
        "--rate",
        type=int,
        required=True,
        help="analysis sample rate in Hz (REQUIRED — set it to what your analyzer expects)",
    )
    args = ap.parse_args(argv)

    meta = decode_to_analysis_lpcm(args.input, args.out_base, args.rate)
    print(
        f"to_lpcm: wrote {args.out_base}.mono.f32  "
        f"({meta['frames']} frames, {meta['duration_sec']:.2f}s, mono f32 @ "
        f"{meta['sample_rate']} Hz; source {meta['source_sample_rate']} Hz) + .decode.json"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
