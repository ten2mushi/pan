# examples/utils — shared helpers for the examples

Small, dependency-light utilities any example can call. Everything is explicit —
no stream parameter (sample rate, channel count, layout, dtype) is hardcoded; the
caller that produced/consumes the data passes them.

| file | direction | role |
|---|---|---|
| `to_lpcm.py` | input | Transcode any audio file (wav/flac/mp3/m4a/webm/…) → raw **mono f32 LPCM** (`<base>.mono.f32` + `.decode.json`) for the analyzer examples. Thin CLI over the canonical, oracle-tested decoder in `scripts/decode_audio.py` (reuses it — does not re-implement decode). |
| `to_wav.py` | output | Wrap a raw, header-less LPCM blob (what the synthesis examples write) in a **WAV** container. Handles mono, interleaved stereo/N-channel (pan frame-sink default), and planar layouts. |

## Why both exist
The pan core is codec-free and speaks only raw LPCM at its I/O boundary (the
disk-minimal, header-less convention). `to_lpcm.py` gets compressed/containered
audio *into* that form; `to_wav.py` gets a synthesized raw blob *out of* it into a
playable/muxable WAV. The raw blob has no header, so `to_wav.py` cannot infer the
stream parameters — they are required/explicit arguments.

## Usage
```bash
# input: m4a -> mono f32 LPCM at the analyzer's rate (44100 → 60 analysis frames/sec)
.venv/bin/python examples/utils/to_lpcm.py --rate 44100 \
    "data/input/incea/AUD-20260607-WA0000.m4a" data/work/incea

# output: raw mono f32 @ 48 kHz -> WAV
.venv/bin/python examples/utils/to_wav.py --rate 48000 out.raw out.wav
# output: raw INTERLEAVED stereo (pan Frame(f32,.stereo) sink) -> WAV
.venv/bin/python examples/utils/to_wav.py --rate 48000 --stereo out.raw out.wav
# output: raw PLANAR multichannel -> WAV
.venv/bin/python examples/utils/to_wav.py --rate 44100 --channels 6 --layout planar out.raw out.wav
```

## Options (both fully configurable)
- `to_lpcm.py`: `--rate` (required). Output is mono by contract (the pan analyzers read one `Sample(f32)`); the sidecar records rate/channels/dtype/frames.
- `to_wav.py`: `--rate` (required), `--channels N` (default 1), `--stereo` (= `--channels 2`), `--layout interleaved|planar` (default interleaved), `--dtype` (default float32).

Dependencies: the repo `.venv` (numpy, scipy); `ffmpeg` on PATH for compressed inputs to `to_lpcm.py`.
