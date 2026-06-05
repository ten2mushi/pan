# examples/spectrogram — power spectrogram + MFCC view

Renders, per track, a **power spectrogram** and an **MFCC** heatmap — both computed
by the **pan library** (`Stft → PowerSpectrum` and `feat.Mfcc`), then drawn in Python.

```
audio ─(scripts/decode_audio.py)─► mono f32 LPCM ─(example-spectrogram, pan)─► <base>.f32
                                                       │  (per hop: BINS spectrum + K MFCCs)
                                                       ▼
                                            render_spectrogram.py  ─►  two PNGs
```

## Files
| file | role |
|---|---|
| `spectrogram.zig` | pan Analyzer graph collecting, per hop, the full power spectrum (`PowerSpectrum`, `BINS=1025`) AND the MFCCs (`feat.Mfcc`, `K=20`) into one matrix (`spectrum` columns then `mfcc` columns). Built by `zig build examples` → `zig-out/bin/example-spectrogram`. FFT 2048 / hop 1024. |
| `render_spectrogram.py` | reads the matrix + sidecar and draws `<source>.spectrogram.png` (power in dB, frequency × time, magma) and `<source>.mfcc.png` (coefficient × time, diverging). |

## Run (from the repo root)
```
# 1. decode to mono LPCM
.venv/bin/python scripts/decode_audio.py \
    "data/input/<source>/<source>_lpcm.wav" data/work/<source>
# 2. pan analysis -> matrix
./zig-out/bin/example-spectrogram data/work/<source>.mono.f32 44100 data/work/<source>.spec
# 3. render the PNGs
.venv/bin/python examples/spectrogram/render_spectrogram.py \
    data/work/<source>.spec --title "pan · <Source>"
```

## Output
**`data/output/spectrogram_<source>/<source>.{spectrogram,mfcc}.png`** (auto-created).
`--out-dir DIR` overrides; `--fmax HZ` caps the spectrogram's frequency axis (default 12 kHz).

## Notes
The MFCC mel filterbank uses a fixed internal sample rate (a documented approximation
in `feat.Mfcc`): a valid cepstral view, but the absolute mel mapping is nominal rather
than exact at 44.1 kHz.

## Dependencies
`scripts/decode_audio.py` (numpy/scipy, ffmpeg for compressed inputs) · the venv
(`numpy scipy matplotlib`) · `zig build examples` for the analyzer.
