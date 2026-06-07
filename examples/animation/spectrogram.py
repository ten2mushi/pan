#!/usr/bin/env python3
"""examples/animation/spectrogram.py — wide, high-res spectrogram from the pan
feature matrix (the SAME `full_spectrum` the 3-D viewer uses).

    python examples/animation/spectrogram.py incea
    python examples/animation/spectrogram.py incea --px-per-sec 160 --height 2200

Reads `data/work/<input>.f<frame>.features.{f32,json}` (analyses it first via
render.py's path if missing), takes the per-frame power spectrum, remaps the
linear-Hz bins onto a log-frequency grid, converts to dB, and rasterises a very
wide image (so each second — even each 1/60 s hop — is resolvable when you zoom).

Output: data/output/animation/ideation/<input>_spectrogram/<input>_spectrogram.png
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FixedLocator, FixedFormatter

REPO = Path(__file__).resolve().parents[2]
WORK = REPO / "data" / "work"
OUT_ROOT = REPO / "data" / "output" / "animation" / "ideation"
sys.path.insert(0, str(Path(__file__).resolve().parent))
import experiments as EXP  # noqa: E402


def ensure_features(inp: str, frame: int) -> Path:
    """Return the cached features base, analysing via render.py if absent."""
    base = WORK / f"{inp}.f{frame}.features"
    if (Path(str(base) + ".f32").exists() and Path(str(base) + ".json").exists()):
        return base
    import render as R  # noqa: E402  (reuse the exact decode+analyze path)
    mono = R.decode(inp)
    return R.analyze(inp, mono, frame)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Wide high-res spectrogram from the pan feature matrix.")
    ap.add_argument("input", help="input key (see experiments.py INPUTS)")
    ap.add_argument("--frame", type=int, default=4096, help="FFT window of the cached features")
    ap.add_argument("--px-per-sec", type=float, default=140.0, help="horizontal resolution (≈2.3 px / 60-fps hop)")
    ap.add_argument("--height", type=int, default=2000, help="frequency-axis pixels (log-spaced rows)")
    ap.add_argument("--fmin", type=float, default=30.0, help="lowest frequency shown (Hz)")
    ap.add_argument("--fmax", type=float, default=16000.0, help="highest frequency shown (Hz)")
    ap.add_argument("--db-range", type=float, default=80.0, help="dynamic range below peak (dB)")
    ap.add_argument("--cmap", default="magma", help="matplotlib colormap (perceptual sequential)")
    args = ap.parse_args(argv)

    if args.input not in EXP.INPUTS:
        sys.exit(f"unknown input '{args.input}' (try: {', '.join(EXP.INPUTS)})")

    base = ensure_features(args.input, args.frame)
    meta = json.loads(Path(str(base) + ".json").read_text())
    ncols, bins, fps, hzpb = meta["n_cols"], meta["bins"], meta["fps"], meta["hz_per_bin"]
    specname = "full_spectrum" if "full_spectrum" in [c["name"] for c in meta["columns"]] else "full_spectrum_l"
    so = next(c["offset"] for c in meta["columns"] if c["name"] == specname)

    m = np.fromfile(Path(str(base) + ".f32"), dtype="<f4")
    nfr = m.size // ncols
    P = m[: nfr * ncols].reshape(nfr, ncols)[:, so:so + bins].T.astype(np.float64)  # (bins, frames)
    dur = nfr / fps
    print(f"spectrogram: {args.input}  {nfr} frames ({dur:.1f}s @ {fps}fps), {bins} bins @ {hzpb:.3f} Hz, frame={args.frame}")

    # --- linear-Hz bins → log-frequency grid (musical y-axis) -----------------
    target = np.logspace(np.log10(args.fmin), np.log10(args.fmax), args.height)
    fbin = np.clip(target / hzpb, 0, bins - 1)
    i0 = np.floor(fbin).astype(int)
    i1 = np.minimum(i0 + 1, bins - 1)
    w = (fbin - i0)[:, None]
    img = P[i0] * (1 - w) + P[i1] * w                # (height, frames), log-freq rows

    # --- power → dB, clipped to a fixed dynamic range -------------------------
    ref = img.max() if img.max() > 0 else 1.0
    db = 10.0 * np.log10(img / ref + 1e-12)
    vmax, vmin = 0.0, -args.db_range

    # --- figure: wide enough to zoom into individual seconds/hops -------------
    width_px = int(round(dur * args.px_per_sec))
    dpi = 100
    fig_w, fig_h = width_px / dpi, (args.height + 220) / dpi
    fig, ax = plt.subplots(figsize=(fig_w, fig_h), dpi=dpi)
    im = ax.imshow(db, origin="lower", aspect="auto", cmap=args.cmap, vmin=vmin, vmax=vmax,
                   extent=[0.0, dur, 0.0, args.height], interpolation="nearest")

    # y ticks at musical frequencies (rows are log-spaced)
    fticks = [f for f in (50, 100, 200, 500, 1000, 2000, 5000, 10000, 16000) if args.fmin <= f <= args.fmax]
    yrows = [int(np.argmin(np.abs(target - f))) for f in fticks]
    ax.yaxis.set_major_locator(FixedLocator(yrows))
    ax.yaxis.set_major_formatter(FixedFormatter([f"{f/1000:g}k" if f >= 1000 else f"{f}" for f in fticks]))
    ax.set_ylabel("frequency (Hz, log)", fontsize=14)

    # x ticks every 5 s (label), minor every 1 s; faint second grid
    ax.xaxis.set_major_locator(FixedLocator(np.arange(0, dur + 1, 5)))
    ax.xaxis.set_minor_locator(FixedLocator(np.arange(0, dur + 1, 1)))
    ax.set_xlabel("time (s)", fontsize=14)
    ax.grid(which="major", axis="x", color="white", alpha=0.18, linewidth=0.6)
    ax.grid(which="minor", axis="x", color="white", alpha=0.06, linewidth=0.4)
    ax.tick_params(labelsize=11)
    ax.set_title(
        f"{EXP.INPUT_TITLE.get(args.input, args.input)} — STFT spectrogram  "
        f"(frame={args.frame}, {hzpb:.2f} Hz/bin, hop={meta['hop_size']} → {fps} fps, dB)",
        fontsize=15, pad=10)
    cb = fig.colorbar(im, ax=ax, pad=0.005, fraction=0.012)
    cb.set_label("power (dB ↓ from peak)", fontsize=12)
    fig.subplots_adjust(left=0.03, right=0.985, top=0.94, bottom=0.06)

    out_dir = OUT_ROOT / f"{args.input}_spectrogram"
    out_dir.mkdir(parents=True, exist_ok=True)
    out = out_dir / f"{args.input}_spectrogram.png"
    fig.savefig(out, dpi=dpi)
    plt.close(fig)
    print(f"✓ {out.relative_to(REPO)}  ({width_px}×{args.height + 220}px, {dur:.1f}s, {args.px_per_sec:g}px/s = {args.px_per_sec/fps:.2f}px/hop)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
