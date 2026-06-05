# scripts — audio decoders + test-vector generator

App-side tooling that keeps the pan core codec-free. The library speaks only LPCM at
its I/O boundary; getting common formats into that LPCM (and generating gold vectors)
lives here.

| file | role |
|---|---|
| `decode_audio.py` | audio (WAV/FLAC/MP3/M4A/WebM/…) → mono `float32` raw LPCM @ 44.1 kHz, for the `examples/` analyzers. A **pure-Python** RIFF/WAVE reader (chunk-walking, so an interposed `LIST/INFO` chunk is handled) with an ffmpeg fallback for compressed inputs. Writes `<base>.mono.f32` + `<base>.decode.json`. |
| `test_decode_oracle.py` | independent-oracle test (Rule 9): asserts `decode_audio.read_wav_pcm` is **bit-exact** to `scipy.io.wavfile.read` across synthesized PCM widths/channel-counts, the adversarial interposed-chunk case, and every WAV in `data/input/**`. |
| `generate.py` | the committed gold-vector generator (SciPy/NumPy oracle) for the test-vector contract — separate from the viz pipeline. |
| `xcheck_rfft.{py,zig}` | a real-FFT cross-check. |

## Run (from the repo root)
```
# decode one source to mono LPCM
.venv/bin/python scripts/decode_audio.py "data/input/<source>/<source>_lpcm.wav" data/work/<source>

# verify the WAV reader against scipy (exit 0 == bit-exact)
.venv/bin/python scripts/test_decode_oracle.py
```

## LPCM contract (what the pan analyzers read)
Raw **native-endian** samples, **no header** (shape/precision live in the JSON
sidecar — the disk-minimal convention); one mono channel of `float32`; 44.1 kHz (the
rate the STFT hop of 735 gives exactly 60 analysis frames/second).

Dependencies: `numpy`, `scipy` (in `.venv/`); `ffmpeg` on PATH for compressed inputs.
