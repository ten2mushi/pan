#!/usr/bin/env python3
"""pan audio-format -> raw LPCM decoder (Phase 17, scripts/ — an app concern).

The pan core is codec-free: it speaks only LPCM (linear PCM) at its I/O boundary.
Turning common container/compression formats (WAV/FLAC/MP3/M4A/WebM) into the raw
LPCM the library ingests is therefore a *scripts/* job, kept out of the core. This
module is that decoder.

Two layers:

  1. `read_wav_pcm(path)` — a PURE-PYTHON WAV (RIFF) reader. It walks the chunk
     list (so it correctly skips a `LIST`/`INFO`/`fact` chunk that sits between
     `fmt ` and `data`, as ffmpeg-written files have) and returns the PCM samples
     as a NumPy array shaped exactly like `scipy.io.wavfile.read` returns them —
     `(frames,)` for mono, `(frames, channels)` for multi-channel — with the
     matching integer/float dtype. This is the unit the oracle test
     (`scripts/test_decode_oracle.py`) checks bit-for-bit against SciPy: pan never
     trusts its own decoder as its own oracle (Rule 9).

  2. `decode_to_analysis_lpcm(in_path, out_base, rate)` — the application transform
     that prepares a file for the Analyzer example: load (via the pure WAV reader,
     or via ffmpeg for compressed inputs), downmix to mono, resample to the
     analysis rate, normalise to f32 in [-1, 1], and write:
        <out_base>.mono.f32     raw NATIVE-ENDIAN float32 mono samples, NO header
        <out_base>.decode.json  a sidecar: { sample_rate, channels:1, dtype, frames }

The on-disk LPCM contract (what `examples/analyze.zig` reads):
  * raw native-endian samples, NO header (the disk-minimal convention the gold
    vectors also use — shape/precision live in the sidecar, not in-band);
  * one mono channel of `float32` (pan's `Sample(f32)` is one f32);
  * at the analysis sample rate (default 44100 Hz, the rate the Analyzer's STFT hop
    of 735 samples gives exactly 60 frames/second — the visualization cadence).

Deterministic given (input, rate): the same input bytes and target rate reproduce
byte-identical output (resampling is `scipy.signal.resample_poly`, deterministic;
the int->float scale is fixed). Compressed-format decode delegates to ffmpeg, whose
PCM output for a given input is deterministic.
"""

from __future__ import annotations

import argparse
import json
import os
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np

# --- the pure-Python WAV (RIFF) reader -------------------------------------

# WAVE format tag codes (the `wFormatTag` field of the `fmt ` chunk).
WAVE_FORMAT_PCM = 0x0001
WAVE_FORMAT_IEEE_FLOAT = 0x0003
WAVE_FORMAT_EXTENSIBLE = 0xFFFE


def _pcm_dtype(fmt_code: int, bits: int) -> np.dtype:
    """The NumPy dtype SciPy uses for a (format, bit-depth) pair.

    SciPy maps: 8-bit PCM -> uint8 (unsigned, biased), 16/32/64-bit PCM ->
    signed little-endian int of that width, IEEE float -> float32/float64.
    24-bit PCM has no native NumPy width; SciPy widens it to int32 (handled
    specially in `read_wav_pcm`), so it is not produced here.
    """
    if fmt_code == WAVE_FORMAT_IEEE_FLOAT:
        if bits == 32:
            return np.dtype("<f4")
        if bits == 64:
            return np.dtype("<f8")
        raise ValueError(f"unsupported IEEE-float bit depth: {bits}")
    # PCM integer.
    if bits == 8:
        return np.dtype("u1")  # 8-bit WAV PCM is unsigned
    if bits == 16:
        return np.dtype("<i2")
    if bits == 32:
        return np.dtype("<i4")
    if bits == 64:
        return np.dtype("<i8")
    raise ValueError(f"unsupported PCM bit depth: {bits}")


def read_wav_pcm(path: str | os.PathLike) -> tuple[int, np.ndarray]:
    """Read a PCM/float WAV file, returning (sample_rate, samples).

    The returned array matches `scipy.io.wavfile.read`: dtype is the natural PCM
    dtype, shape is `(frames,)` for mono and `(frames, channels)` otherwise.

    Pure Python + NumPy: no audio library. Walks the RIFF chunk list so chunks
    between `fmt ` and `data` (LIST/INFO/fact, as ffmpeg writes) are skipped.
    """
    raw = Path(path).read_bytes()
    if len(raw) < 12 or raw[0:4] != b"RIFF" or raw[8:12] != b"WAVE":
        raise ValueError(f"not a RIFF/WAVE file: {path}")

    fmt = None  # (fmt_code, channels, sample_rate, bits)
    data_bytes = None
    pos = 12  # past "RIFF"<size>"WAVE"
    n = len(raw)
    while pos + 8 <= n:
        chunk_id = raw[pos : pos + 4]
        (chunk_size,) = struct.unpack_from("<I", raw, pos + 4)
        body = pos + 8
        if chunk_id == b"fmt ":
            # fmt : wFormatTag, nChannels, nSamplesPerSec, nAvgBytesPerSec,
            #       nBlockAlign, wBitsPerSample [, cbSize, ...extensible...]
            fmt_code, channels, sample_rate, _avg, _align, bits = struct.unpack_from(
                "<HHIIHH", raw, body
            )
            if fmt_code == WAVE_FORMAT_EXTENSIBLE and chunk_size >= 40:
                # The real format tag lives in the SubFormat GUID's first 2 bytes.
                (sub_code,) = struct.unpack_from("<H", raw, body + 24)
                fmt_code = sub_code
            fmt = (fmt_code, channels, sample_rate, bits)
        elif chunk_id == b"data":
            data_bytes = raw[body : body + chunk_size]
        # chunks are word-aligned: an odd size is padded with one byte.
        pos = body + chunk_size + (chunk_size & 1)

    if fmt is None:
        raise ValueError(f"WAV missing 'fmt ' chunk: {path}")
    if data_bytes is None:
        raise ValueError(f"WAV missing 'data' chunk: {path}")

    fmt_code, channels, sample_rate, bits = fmt

    if fmt_code == WAVE_FORMAT_PCM and bits == 24:
        # 24-bit packed little-endian, widened to int32 like SciPy: sign-extend
        # each 3-byte sample into the low 24 bits of an int32.
        a = np.frombuffer(data_bytes, dtype="u1")
        nsamp = a.size // 3
        a = a[: nsamp * 3].reshape(-1, 3).astype(np.int32)
        vals = a[:, 0] | (a[:, 1] << 8) | (a[:, 2] << 16)
        vals = np.where(vals >= (1 << 23), vals - (1 << 24), vals).astype(np.int32)
        data = vals
    else:
        dtype = _pcm_dtype(fmt_code, bits)
        data = np.frombuffer(data_bytes, dtype=dtype)

    if channels > 1:
        frames = data.size // channels
        data = data[: frames * channels].reshape(frames, channels)
    return sample_rate, data


# --- compressed-format fallback via ffmpeg ---------------------------------


def _have_ffmpeg() -> bool:
    from shutil import which

    return which("ffmpeg") is not None


def load_audio(path: str | os.PathLike) -> tuple[int, np.ndarray]:
    """Load any supported audio file as (sample_rate, samples).

    `.wav` goes through the pure-Python reader. Everything else (FLAC/MP3/M4A/
    WebM/...) is transcoded to a temporary 16-bit PCM WAV by ffmpeg and then read
    by the same pure reader — so the decode path is uniform and the LPCM contract
    is identical regardless of source container.
    """
    p = Path(path)
    if p.suffix.lower() == ".wav":
        return read_wav_pcm(p)
    if not _have_ffmpeg():
        raise RuntimeError(
            f"{p.suffix} input needs ffmpeg to decode to LPCM, but ffmpeg was not found"
        )
    with tempfile.TemporaryDirectory() as td:
        tmp_wav = Path(td) / "decoded.wav"
        subprocess.run(
            ["ffmpeg", "-v", "error", "-y", "-i", str(p), "-c:a", "pcm_s16le", str(tmp_wav)],
            check=True,
        )
        return read_wav_pcm(tmp_wav)


# --- the analysis-LPCM transform -------------------------------------------


def to_mono_float(samples: np.ndarray) -> np.ndarray:
    """Downmix to mono and normalise to float32 in [-1, 1].

    Integer PCM is scaled by its full-scale magnitude; 8-bit unsigned is first
    re-centred to signed. Float PCM is passed through (already in [-1, 1]).
    Multi-channel input is averaged across channels (a stable, phase-neutral
    downmix for analysis).
    """
    x = samples
    if x.dtype == np.uint8:
        x = x.astype(np.float32)
        x = (x - 128.0) / 128.0
    elif np.issubdtype(x.dtype, np.integer):
        full_scale = float(np.iinfo(x.dtype).max + 1)  # 32768 for int16, etc.
        x = x.astype(np.float64) / full_scale
    else:
        x = x.astype(np.float64)
    if x.ndim == 2:
        x = x.mean(axis=1)
    return x.astype(np.float32)


def resample_to(x: np.ndarray, sr_in: int, sr_out: int) -> np.ndarray:
    """Deterministic rational resample mono float `x` from `sr_in` to `sr_out`."""
    if sr_in == sr_out:
        return x.astype(np.float32)
    from math import gcd

    from scipy.signal import resample_poly

    g = gcd(sr_in, sr_out)
    up, down = sr_out // g, sr_in // g
    return resample_poly(x, up, down).astype(np.float32)


def decode_to_analysis_lpcm(
    in_path: str | os.PathLike, out_base: str | os.PathLike, rate: int = 44_100
) -> dict:
    """Decode `in_path` to mono f32 LPCM at `rate` for the Analyzer example.

    Writes `<out_base>.mono.f32` (raw native-endian float32) and
    `<out_base>.decode.json` (the sidecar). Returns the sidecar dict.
    """
    sr, samples = load_audio(in_path)
    mono = to_mono_float(samples)
    mono = resample_to(mono, sr, rate)
    # Guard against pathological inputs producing NaN/inf.
    mono = np.nan_to_num(mono, nan=0.0, posinf=0.0, neginf=0.0).astype("<f4")

    out_base = Path(out_base)
    out_base.parent.mkdir(parents=True, exist_ok=True)
    raw_path = out_base.with_suffix(".mono.f32")
    # Write NATIVE-endian f32 (the pan-side contract); on little-endian hosts this
    # equals the '<f4' we hold, which is the overwhelmingly common case.
    mono.astype(np.float32).tofile(raw_path)

    meta = {
        "schema": "pan.lpcm.v1",
        "source": str(in_path),
        "source_sample_rate": int(sr),
        "sample_rate": int(rate),
        "channels": 1,
        "dtype": "float32",
        "frames": int(mono.size),
        "duration_sec": float(mono.size) / float(rate),
    }
    meta_path = out_base.with_suffix(".decode.json")
    meta_path.write_text(json.dumps(meta, indent=2))
    return meta


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Decode an audio file to mono f32 LPCM for pan.")
    ap.add_argument("input", help="input audio file (wav/flac/mp3/m4a/webm/...)")
    ap.add_argument("out_base", help="output base path (writes <base>.mono.f32 + <base>.decode.json)")
    ap.add_argument("--rate", type=int, default=44_100, help="analysis sample rate (default 44100)")
    args = ap.parse_args(argv)

    meta = decode_to_analysis_lpcm(args.input, args.out_base, args.rate)
    print(
        f"decoded {args.input!r}: {meta['source_sample_rate']} Hz -> {meta['sample_rate']} Hz mono, "
        f"{meta['frames']} frames ({meta['duration_sec']:.1f} s) -> {args.out_base}.mono.f32",
        file=sys.stderr,
    )
    print(json.dumps(meta))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
