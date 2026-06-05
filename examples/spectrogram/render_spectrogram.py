#!/usr/bin/env python3
"""Render the pan spectrogram + MFCC matrix (from examples/spectrogram) as PNGs.

Reads the headerless `f32` matrix + JSON sidecar emitted by
`examples/spectrogram.zig` — first `bins` columns are the per-hop power spectrum
(the spectrogram), the last `n_mfcc` columns are the mel-cepstral coefficients —
and renders each as a clean heatmap PNG:

  <base>.spectrogram.png   power in dB, frequency (Hz) vs time (s)
  <base>.mfcc.png          coefficient index vs time (s)

All feature extraction was the pan library's; this only draws. Usage:
  render_spectrogram.py <features_base> [--out-dir DIR] [--title STR] [--fmax HZ]
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402

BG = "#0b0d16"
FG = "#c9d6f2"


def _style(ax):
    ax.set_facecolor(BG)
    for s in ax.spines.values():
        s.set_color("#2a3550")
    ax.tick_params(colors=FG, labelsize=8)
    ax.xaxis.label.set_color(FG)
    ax.yaxis.label.set_color(FG)
    ax.title.set_color("#e6eeff")


def render(base: str, out_dir: Path, title: str, fmax: float | None):
    meta = json.loads(Path(str(base) + ".json").read_text())
    cols = meta["n_cols"]
    bins = meta["bins"]
    n_mfcc = meta["n_mfcc"]
    sr = meta["sample_rate"]
    hz_per_bin = meta["hz_per_bin"]
    sec_per_hop = meta["sec_per_hop"]
    m = np.fromfile(str(base) + ".f32", dtype="<f4").reshape(-1, cols)

    spectrum = m[:, meta["spectrum_offset"] : meta["spectrum_offset"] + bins]  # [T, bins]
    mfcc = m[:, meta["mfcc_offset"] : meta["mfcc_offset"] + n_mfcc]            # [T, K]
    n_frames = spectrum.shape[0]
    duration = n_frames * sec_per_hop

    # power -> dB, normalised so 0 dB is the loudest bin in the piece
    eps = 1e-12
    db = 10.0 * np.log10(spectrum.T + eps)  # [bins, T]
    db -= db.max()
    db = np.clip(db, -90.0, 0.0)

    nyq = sr / 2.0
    fmax = nyq if (fmax is None or fmax <= 0) else min(fmax, nyq)
    top_bin = int(round(fmax / hz_per_bin)) + 1
    db = db[:top_bin]

    # ---- spectrogram ----
    fig, ax = plt.subplots(figsize=(13, 5.5), facecolor=BG)
    _style(ax)
    im = ax.imshow(
        db, origin="lower", aspect="auto", cmap="magma",
        extent=[0.0, duration, 0.0, top_bin * hz_per_bin], vmin=-90, vmax=0,
    )
    ax.set_xlabel("time (s)")
    ax.set_ylabel("frequency (Hz)")
    ax.set_title(f"{title}  ·  power spectrogram   (FFT {meta['frame_size']}, hop {meta['hop_size']})")
    cb = fig.colorbar(im, ax=ax, pad=0.01)
    cb.set_label("power (dB)", color=FG)
    cb.ax.tick_params(colors=FG, labelsize=8)
    cb.outline.set_edgecolor("#2a3550")
    fig.tight_layout()
    stem = Path(base).name.removesuffix(".spec")
    spec_png = out_dir / (stem + ".spectrogram.png")
    fig.savefig(spec_png, dpi=130, facecolor=BG)
    plt.close(fig)
    print(f"wrote {spec_png}")

    # ---- MFCC ----
    fig, ax = plt.subplots(figsize=(13, 4.0), facecolor=BG)
    _style(ax)
    # drop the 0th cepstral coefficient (overall energy) from the colour scaling so
    # the timbral coefficients are visible, then show all of them.
    mt = mfcc.T  # [K, T]
    vlim = np.percentile(np.abs(mt[1:]), 99) if n_mfcc > 1 else np.abs(mt).max()
    vlim = max(vlim, 1e-6)
    im = ax.imshow(
        mt, origin="lower", aspect="auto", cmap="coolwarm",
        extent=[0.0, duration, 0.0, n_mfcc], vmin=-vlim, vmax=vlim,
    )
    ax.set_xlabel("time (s)")
    ax.set_ylabel("MFCC coefficient")
    ax.set_title(f"{title}  ·  mel-frequency cepstral coefficients   ({n_mfcc} coeffs)")
    cb = fig.colorbar(im, ax=ax, pad=0.01)
    cb.set_label("coefficient value", color=FG)
    cb.ax.tick_params(colors=FG, labelsize=8)
    cb.outline.set_edgecolor("#2a3550")
    fig.tight_layout()
    mfcc_png = out_dir / (stem + ".mfcc.png")
    fig.savefig(mfcc_png, dpi=130, facecolor=BG)
    plt.close(fig)
    print(f"wrote {mfcc_png}")


# examples/spectrogram/ -> repo root; output goes to data/output/spectrogram_<source>/
REPO = Path(__file__).resolve().parents[2]
EXPERIMENT = "spectrogram"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Render pan spectrogram + MFCC PNGs.")
    ap.add_argument("features_base", help="base path (<base>.f32 + <base>.json)")
    ap.add_argument("--out-dir", default=None,
                    help="output dir (default: data/output/spectrogram_<source>/)")
    ap.add_argument("--title", default="pan analysis")
    ap.add_argument("--fmax", type=float, default=12000.0, help="top frequency shown (Hz); <=0 = Nyquist")
    args = ap.parse_args(argv)
    if args.out_dir:
        out_dir = Path(args.out_dir)
    else:
        # one output subfolder per experiment+input: data/output/spectrogram_<source>/
        source = Path(args.features_base).name.removesuffix(".spec")
        out_dir = REPO / "data" / "output" / f"{EXPERIMENT}_{source}"
    out_dir.mkdir(parents=True, exist_ok=True)
    render(args.features_base, out_dir, args.title, args.fmax)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
