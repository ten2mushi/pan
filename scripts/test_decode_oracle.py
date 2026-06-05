#!/usr/bin/env python3
"""Independent-oracle test for the pure-Python WAV reader (Phase 17, Rule 9).

The pan project never validates a decoder against its own output. This test
asserts `decode_audio.read_wav_pcm` reproduces, BIT-FOR-BIT, what an independent
external oracle — `scipy.io.wavfile.read` — returns for the same files: identical
sample rate, identical dtype, identical shape, and `np.array_equal` samples.

It also exercises a synthesized-WAV round-trip across several PCM widths and
channel counts (so the test is meaningful even with no media files present), and a
chunked WAV with a `LIST`/`INFO` chunk wedged between `fmt ` and `data` (the layout
ffmpeg produces — the case naive readers get wrong).

Run:  .venv/bin/python scripts/test_decode_oracle.py
Exit code 0 ⇒ all assertions held; non-zero ⇒ a mismatch (printed).
"""

from __future__ import annotations

import io
import struct
import sys
import tempfile
from pathlib import Path

import numpy as np
from scipy.io import wavfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from decode_audio import read_wav_pcm  # noqa: E402

REPO = Path(__file__).resolve().parents[1]


def _write_wav_with_list_chunk(path: Path, sr: int, data: np.ndarray) -> None:
    """Write a canonical PCM WAV with an INFO LIST chunk between fmt and data."""
    if data.ndim == 1:
        channels = 1
        interleaved = data
    else:
        channels = data.shape[1]
        interleaved = data.reshape(-1)
    bits = data.dtype.itemsize * 8
    block_align = channels * data.dtype.itemsize
    byte_rate = sr * block_align
    data_bytes = interleaved.astype(data.dtype).tobytes()

    fmt_chunk = struct.pack("<HHIIHH", 1, channels, sr, byte_rate, block_align, bits)
    # A small LIST/INFO chunk (the ISFT software tag), like ffmpeg writes.
    info = b"INFO" + b"ISFT" + struct.pack("<I", 8) + b"pantest\x00"
    list_chunk = info
    body = (
        b"fmt " + struct.pack("<I", len(fmt_chunk)) + fmt_chunk
        + b"LIST" + struct.pack("<I", len(list_chunk)) + list_chunk
        + b"data" + struct.pack("<I", len(data_bytes)) + data_bytes
    )
    riff = b"RIFF" + struct.pack("<I", 4 + len(body)) + b"WAVE" + body
    path.write_bytes(riff)


def _assert_matches_scipy(path: Path, label: str) -> None:
    sr_ref, data_ref = wavfile.read(path)
    sr_got, data_got = read_wav_pcm(path)
    assert sr_got == sr_ref, f"{label}: sample rate {sr_got} != scipy {sr_ref}"
    assert data_got.shape == data_ref.shape, (
        f"{label}: shape {data_got.shape} != scipy {data_ref.shape}"
    )
    assert data_got.dtype == data_ref.dtype, (
        f"{label}: dtype {data_got.dtype} != scipy {data_ref.dtype}"
    )
    assert np.array_equal(data_got, data_ref), f"{label}: samples differ from scipy"
    print(f"  ok  {label}: sr={sr_got} shape={data_got.shape} dtype={data_got.dtype}")


def test_synthetic_round_trips() -> None:
    """Synthesized PCM WAVs across widths/channels match scipy exactly."""
    print("synthetic WAV round-trips vs scipy.io.wavfile.read:")
    rng = np.random.default_rng(20260605)
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        cases = [
            ("int16 mono", (np.clip(rng.normal(0, 8000, 5000), -32768, 32767)).astype(np.int16)),
            ("int16 stereo", (np.clip(rng.normal(0, 8000, (4000, 2)), -32768, 32767)).astype(np.int16)),
            ("int32 stereo", (rng.integers(-(2**30), 2**30, (3000, 2))).astype(np.int32)),
            ("uint8 mono", (rng.integers(0, 256, 4000)).astype(np.uint8)),
            ("float32 stereo", (rng.normal(0, 0.3, (3500, 2))).astype(np.float32)),
        ]
        for label, data in cases:
            p = tmp / (label.replace(" ", "_") + ".wav")
            wavfile.write(p, 44100, data)  # scipy WRITES it (canonical layout)
            _assert_matches_scipy(p, label)  # our reader must match scipy READING it

        # The adversarial case: a LIST chunk between fmt and data.
        data = (np.clip(rng.normal(0, 8000, (2000, 2)), -32768, 32767)).astype(np.int16)
        p = tmp / "stereo_with_list_chunk.wav"
        _write_wav_with_list_chunk(p, 48000, data)
        _assert_matches_scipy(p, "int16 stereo + interposed LIST/INFO chunk")


def test_repo_inputs() -> None:
    """If real input WAVs are present, our reader matches scipy on them too."""
    wavs = sorted((REPO / "data" / "input").glob("*.wav"))
    if not wavs:
        print("repo input WAVs: none present (skipping — synthetic suite covers the reader)")
        return
    print("repo data/input/*.wav vs scipy:")
    for w in wavs:
        _assert_matches_scipy(w, w.name)


def main() -> int:
    test_synthetic_round_trips()
    test_repo_inputs()
    print("\nALL OK: read_wav_pcm is bit-exact to scipy.io.wavfile.read")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
