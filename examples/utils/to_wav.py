#!/usr/bin/env python3
"""Wrap a raw, header-less LPCM blob in a WAV container.

The pan examples write synthesized audio as a raw LPCM blob (the disk-minimal
I/O-boundary convention): native-endian samples, NO in-band header. This utility
adds a WAV header so the blob can be played or muxed.

Because the blob has no header, NOTHING about the stream can be inferred from the
file — the caller that produced it knows the parameters and passes them all
explicitly. There are no hardcoded stream values here: the sample rate is a
REQUIRED argument, and channel count / multichannel layout / sample dtype are
explicit options (their defaults describe the single most common case — one
channel of float32 — and every one is overridable).

Multichannel layout note: pan's frame sinks (e.g. a `Frame(f32, .stereo)` sink)
write INTERLEAVED on disk — `[f0c0, f0c1, f1c0, f1c1, ...]` — which is the
default here. Pass `--layout planar` for a plane-major blob `[c0...][c1...]`
(pan's internal canonical buffer form).

Usage:
    python examples/utils/to_wav.py --rate 48000 in.raw out.wav            # mono
    python examples/utils/to_wav.py --rate 48000 --stereo in.raw out.wav   # interleaved stereo
    python examples/utils/to_wav.py --rate 44100 --channels 6 --layout planar in.raw out.wav
"""
from __future__ import annotations

import argparse

import numpy as np
from scipy.io import wavfile


def to_wav(
    in_path: str,
    out_path: str,
    rate: int,
    channels: int,
    layout: str,
    dtype: str,
) -> int:
    """Read a raw LPCM blob and write it as a WAV; returns the frame count."""
    if rate <= 0:
        raise SystemExit(f"to_wav: --rate must be positive, got {rate}")
    if channels < 1:
        raise SystemExit(f"to_wav: --channels must be >= 1, got {channels}")

    data = np.fromfile(in_path, dtype=np.dtype(dtype))
    if data.size == 0:
        raise SystemExit(f"to_wav: {in_path} is empty (no samples read)")

    if channels == 1:
        arr = data
    else:
        if data.size % channels != 0:
            raise SystemExit(
                f"to_wav: sample count {data.size} not divisible by {channels} channels"
            )
        if layout == "interleaved":
            # [f0c0, f0c1, f1c0, f1c1, ...] -> rows are frames, columns are channels
            arr = data.reshape(-1, channels)
        else:  # planar / plane-major: [c0_0..c0_n][c1_0..c1_n] -> transpose to (frames, channels)
            arr = data.reshape(channels, -1).T

    wavfile.write(out_path, rate, arr)
    frames = arr.shape[0]
    print(
        f"to_wav: wrote {out_path}  rate={rate} channels={channels} "
        f"layout={layout} dtype={dtype} frames={frames}"
    )
    return frames


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description="Wrap a raw header-less LPCM blob in a WAV container (all stream "
        "parameters are explicit; the blob carries no header)."
    )
    ap.add_argument("in_path", help="raw LPCM input (header-less native-endian samples)")
    ap.add_argument("out_path", help="output .wav path")
    ap.add_argument(
        "--rate",
        type=int,
        required=True,
        help="sample rate in Hz (REQUIRED — the raw blob has no header to infer it from)",
    )
    ap.add_argument(
        "--channels", type=int, default=1, help="channel count (default 1 = mono)"
    )
    ap.add_argument(
        "--stereo", action="store_true", help="convenience alias for --channels 2"
    )
    ap.add_argument(
        "--layout",
        choices=["interleaved", "planar"],
        default="interleaved",
        help="multichannel sample layout (default interleaved; matches pan frame sinks)",
    )
    ap.add_argument(
        "--dtype",
        default="float32",
        help="numpy dtype of the raw samples (default float32 = pan's Sample(f32))",
    )
    args = ap.parse_args(argv)
    channels = 2 if args.stereo else args.channels
    to_wav(args.in_path, args.out_path, args.rate, channels, args.layout, args.dtype)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
