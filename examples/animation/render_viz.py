#!/usr/bin/env python3
"""pan feature-matrix -> 3D audio-reactive particle animation (Phase 17 renderer).

Reads the headerless `f32` feature matrix + JSON sidecar emitted by
`examples/analyze.zig` and renders the `notes/1.md` visualization: a generative,
ever-changing 3-D point cloud where each particle is one analysis frame (sampled at
60 fps), per the reference screenshots in `notes/`.

Data for every point (notes/1.md schema):
  * COLOR / FREQUENCY  = the most-active frequency band at emission, mapped through
                         a rainbow (turbo) colormap over the piece's dominant-band
                         frequency range (the 2k->8k-style colorbar);
  * SIGNAL AMPLITUDE   = the 0..1 ballistic envelope (particle size + brightness);
  * LIFETIME           = seconds the particle lives before it fades out;
  * EMISSION TIME      = its frame's timestamp (Time=0 at the animation start).

Positions are audio-driven oscillatory patterns, not random: the cloud is a
bounded 3-D walk whose heading is *steered by the spectrum* — spectral brightness
(centroid) turns it horizontally, roll-off tilts it vertically, loudness and onsets
(flux) set its speed — so the wandering ribbon "closely mirrors the features,
amplitude, and temporal characteristics found in the spectrogram." Live particles
are stitched into a constellation by a faint web (temporal thread + nearest spatial
neighbours), and each shimmers on a small lifetime oscillation whose rate tracks its
frequency. The central red square + white dot and the four attribute readouts around
it mirror the reference legend.

The pan library did all the feature extraction; this renderer (Python, per the
brief) only draws. `run_pipeline.py` muxes the matching audio excerpt into the mp4.

Usage:
  render_viz.py <features_base> --out <out.mp4> [--seconds N] [--start S]
                [--fps F] [--lifetime S] [--title STR]
  <features_base> resolves <base>.f32 (matrix) + <base>.json (sidecar).
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import matplotlib

matplotlib.use("Agg")  # headless render to a file
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
from matplotlib.animation import FFMpegWriter, PillowWriter  # noqa: E402
from matplotlib.colors import LinearSegmentedColormap, Normalize  # noqa: E402
from mpl_toolkits.mplot3d.art3d import Line3DCollection  # noqa: E402

# A curated low->high frequency gradient: deep indigo → periwinkle → teal → soft
# gold → warm rose. An analogous cool sweep with a warm high-frequency accent —
# distinguishable by hue (so colour reads as frequency) but with controlled
# saturation/luminance, so it stays clean and harmonious rather than neon-rainbow.
CMAP = LinearSegmentedColormap.from_list(
    "pan_freq",
    ["#3b4a8c", "#5e74d6", "#46b4c8", "#5fd6a0", "#e8c66b", "#e87f9c"],
)
BG = "#070912"  # deep navy-black field (a touch of blue reads as depth, not flat black)
HUD_FG = "#9fb0d6"


def load_features(base: str) -> tuple[np.ndarray, dict, dict]:
    """Load the feature matrix and sidecar; return (matrix, meta, columns-by-name)."""
    # NB: append the extension (do NOT use with_suffix — a base like
    # "dune.features" has ".features" as its apparent suffix).
    meta = json.loads(Path(str(base) + ".json").read_text())
    cols = meta["n_cols"]
    m = np.fromfile(str(base) + ".f32", dtype="<f4")
    if m.size % cols != 0:
        raise ValueError(f"matrix size {m.size} not divisible by n_cols {cols}")
    m = m.reshape(-1, cols)
    by_name = {c["name"]: (c["offset"], c["width"]) for c in meta["columns"]}
    return m, meta, by_name


def col(m: np.ndarray, by_name: dict, name: str) -> np.ndarray:
    off, w = by_name[name]
    seg = m[:, off : off + w]
    return seg[:, 0] if w == 1 else seg


def _norm01(x: np.ndarray, pct: float = 98.0) -> np.ndarray:
    hi = np.percentile(x, pct)
    return np.zeros_like(x) if hi <= 0 else np.clip(x / hi, 0.0, 1.0)


def build_particles(m: np.ndarray, meta: dict, by_name: dict, lifetime: float):
    """Precompute per-emission attributes and the feature-steered walk geometry."""
    fps = meta["fps"]
    hz_per_bin = meta["hz_per_bin"]
    n = m.shape[0]

    dominant = col(m, by_name, "dominant")
    amplitude = col(m, by_name, "amplitude")
    rms = col(m, by_name, "rms")
    centroid = col(m, by_name, "centroid")
    rolloff = col(m, by_name, "rolloff")
    flux = col(m, by_name, "flux")

    emit_t = np.arange(n) / float(fps)
    freq_hz = np.maximum(dominant * hz_per_bin, 1.0)

    amp_n = _norm01(amplitude, 98.0)
    if amp_n.max() <= 0:
        amp_n = _norm01(rms, 98.0)
    centroid_n = _norm01(centroid, 98.0)
    rolloff_n = _norm01(rolloff, 98.0)
    flux_n = _norm01(flux, 97.0)

    # COLOR: rainbow over the piece's dominant-frequency span (2nd..98th pct, log),
    # so the palette is fully used and color tracks the melody/spectrum frame to
    # frame; near-constant for a drone (faithfully), varied for a melodic line.
    flo = max(20.0, float(np.percentile(freq_hz, 2)))
    fhi = max(flo * 2.0, float(np.percentile(freq_hz, 98)))
    norm = Normalize(vmin=np.log2(flo), vmax=np.log2(fhi))
    cval = norm(np.log2(np.clip(freq_hz, flo, fhi)))

    # POSITION: each point is placed in 3-D by its own features, mirroring the
    # spectrogram — the dominant frequency is a vertical "altitude" (like a
    # spectrogram's frequency axis), loudness is the radius from that axis (loud =
    # flung wide), and successive emissions are fanned around the axis by the golden
    # angle (so a stream of points spreads into a broad disc/cloud rather than a
    # thin ring) with a slow brightness-driven drift on top. A sustained pitch thus
    # traces a ring at its frequency-height; a melodic line stacks rings; onsets
    # (flux) and amplitude push points outward — the structure is the spectrogram
    # rendered as an accumulating 3-D point field.
    GOLDEN = np.pi * (3.0 - np.sqrt(5.0))  # 2.39996… rad — even azimuthal fan
    lf = (np.log2(np.clip(freq_hz, flo, fhi)) - np.log2(flo)) / (np.log2(fhi) - np.log2(flo))
    az = np.arange(n) * GOLDEN + 0.6 * np.cumsum(centroid_n - 0.5) * (1.0 / fps)
    radius = 1.0 + 4.6 * amp_n + 2.2 * flux_n
    height = (lf - 0.5) * 8.0
    bx = (radius * np.cos(az)).astype(np.float32)
    by = (radius * np.sin(az)).astype(np.float32)
    bz = (height + 0.5 * np.sin(az * 0.5)).astype(np.float32)

    shimmer_rate = 1.0 + 5.0 * cval
    shimmer_amp = 0.10 + 0.7 * amp_n

    span = float(
        1.06 * max(
            np.percentile(np.sqrt(bx * bx + by * by + bz * bz), 97)
            + float(shimmer_amp.max()),
            3.0,
        )
    )
    return {
        "fps": fps,
        "lifetime": lifetime,
        "n": n,
        "emit_t": emit_t,
        "freq_hz": freq_hz,
        "amp": amp_n,
        # the raw ballistic-envelope amplitude (pan's 0..1 signal amplitude), as
        # opposed to `amp` which is renormalised for visual dynamic range.
        "amp_raw": np.clip(amplitude, 0.0, 1.0).astype(np.float32),
        "bx": bx,
        "by": by,
        "bz": bz,
        "cval": cval.astype(np.float32),
        "shimmer_rate": shimmer_rate.astype(np.float32),
        "shimmer_amp": shimmer_amp.astype(np.float32),
        "flo": flo,
        "fhi": fhi,
        "norm": norm,
        "bound": span,
    }


def render(base: str, out_path: str, seconds: float, fps: float, lifetime: float,
           title: str, start: float = 0.0):
    m, meta, by_name = load_features(base)
    P = build_particles(m, meta, by_name, lifetime)

    total_audio = P["emit_t"][-1] if P["n"] else 0.0
    start = max(0.0, min(start, max(0.0, total_audio - 1.0)))
    window = (total_audio - start) if seconds <= 0 else min(seconds, total_audio - start)
    duration = max(1.0 / fps, window)
    n_video = max(1, int(round(duration * fps)))
    R = P["bound"]
    fps_meta = P["fps"]
    start_i = int(round(start * fps_meta))  # first emission index shown
    # `lifetime` is the recency time-constant: a point flares at emission and decays
    # to a faint floor over ~lifetime seconds, then PERSISTS in the historical trail
    # (it is never removed) — the current point leads, the past accumulates.
    tau = max(0.3, lifetime)
    trail_cap = 2400  # cap drawn history so a long excerpt stays interactive

    fig = plt.figure(figsize=(10, 8), facecolor=BG)
    ax = fig.add_subplot(111, projection="3d")

    def visible(t: float):
        """All emissions up to time t (the accumulated trail), newest last."""
        end_i = min(P["n"], int(np.floor(t * fps_meta)) + 1)
        lo = max(start_i, end_i - trail_cap)
        idx = np.arange(lo, end_i)
        if idx.size == 0:
            return idx, None
        a = np.maximum(t - P["emit_t"][idx], 0.0)
        # recency: a soft flare at emission settling to a faint persistent floor
        recency = 0.12 + 0.88 * np.exp(-a / tau)
        osc = P["shimmer_amp"][idx] * np.sin(2 * np.pi * P["shimmer_rate"][idx] * a)
        x = P["bx"][idx] + osc
        y = P["by"][idx] + osc * 0.7
        z = P["bz"][idx] + 0.6 * osc
        alpha = np.clip(recency * (0.40 + 0.60 * P["amp"][idx]), 0.04, 0.96)
        size = 6 + 34 * P["amp"][idx] + 60 * P["amp"][idx] * np.exp(-a / 0.5)
        return idx, (x, y, z, alpha, size)

    txt = dict(transform=fig.transFigure, color=HUD_FG, family="monospace")

    def draw(frame: int):
        ax.clear()
        ax.set_facecolor(BG)
        ax.set_position([0.0, 0.0, 1.0, 0.92])
        try:
            ax.set_box_aspect((1, 1, 1), zoom=1.85)
        except TypeError:
            ax.set_box_aspect((1, 1, 1))
        ax.set_xlim(-R, R); ax.set_ylim(-R, R); ax.set_zlim(-R, R)
        ax.set_axis_off()
        t = start + frame / fps
        # cinematic turntable orbit: a steady azimuth sweep + a slow elevation rise
        # and fall + a gentle dolly-in/out, so the structure is read in full 3-D.
        ax.view_init(elev=22 + 14 * np.sin(t * 0.11), azim=(t * 16.0) % 360)
        try:
            ax.set_box_aspect((1, 1, 1), zoom=1.85 + 0.18 * np.sin(t * 0.07))
        except TypeError:
            pass

        cur_freq = cur_amp = cur_age = 0.0
        idx, vis = visible(t)
        if vis is not None:
            x, y, z, alpha, size = vis
            base = CMAP(P["cval"][idx])

            # a single calm thread through the recent trail (no busy mesh): the
            # continuity of the stream, not a constellation of crossing wires.
            segs, scols = _web_segments(x, y, z, idx, P, base, alpha)
            if segs:
                ax.add_collection3d(Line3DCollection(segs, colors=scols, linewidths=0.6))

            # soft glow: a wide faint halo under a smaller brighter core (round dots,
            # not neon stars) for a clean, luminous look.
            halo = base.copy(); halo[:, 3] = alpha * 0.18
            core = base.copy(); core[:, 3] = alpha
            ax.scatter(x, y, z, s=size * 4.0, c=halo, marker="o", depthshade=False,
                       edgecolors="none", zorder=4)
            ax.scatter(x, y, z, s=size, c=core, marker="o", depthshade=False,
                       edgecolors="none", zorder=5)

            # the current point: a luminous core + soft halo + a thin white ring,
            # so the live timestep reads clearly while leading the trail.
            cur = idx[-1]
            cc = CMAP(P["cval"][cur])
            ax.scatter([x[-1]], [y[-1]], [z[-1]], s=420, c=[(cc[0], cc[1], cc[2], 0.22)],
                       marker="o", depthshade=False, edgecolors="none", zorder=7)
            ax.scatter([x[-1]], [y[-1]], [z[-1]], s=70, c=[cc],
                       marker="o", depthshade=False,
                       edgecolors="white", linewidths=1.1, zorder=8)
            cur_freq = float(P["freq_hz"][cur])
            cur_amp = float(P["amp"][cur])
            cur_age = float(t - P["emit_t"][cur])

        fig.text(0.5, 0.965, title, ha="center", color="#dfe8fb", fontsize=12.5,
                 weight="bold", family="monospace")
        # bottom-left readout of the CURRENT highlighted point, updated every frame
        # (the per-point schema: colour/frequency, amplitude, lifetime, emission time).
        fig.text(0.025, 0.140, "current point", fontsize=9, color="#5f6f96", family="monospace",
                 transform=fig.transFigure)
        fig.text(0.025, 0.110, f"COLOR / FREQUENCY   {cur_freq:8.1f} Hz", fontsize=10.5, **txt)
        fig.text(0.025, 0.083, f"SIGNAL AMPLITUDE    {cur_amp:8.4f}", fontsize=10.5, **txt)
        fig.text(0.025, 0.056, f"LIFETIME            {cur_age:8.4f} s", fontsize=10.5, **txt)
        fig.text(0.025, 0.029, f"EMISSION TIME       {t:8.4f} s", fontsize=10.5, **txt)
        return []

    # frequency colorbar across the top, labelled in the piece's real Hz span
    sm = plt.cm.ScalarMappable(cmap=CMAP, norm=P["norm"])
    cax = fig.add_axes([0.30, 0.915, 0.40, 0.018])
    cb = fig.colorbar(sm, cax=cax, orientation="horizontal")
    lo, hi = P["flo"], P["fhi"]
    ticks = np.geomspace(lo, hi, 5)
    cb.set_ticks([np.log2(h) for h in ticks])
    cb.set_ticklabels([f"{h/1000:.1f}k" if h >= 1000 else f"{int(round(h))}" for h in ticks])
    cb.ax.tick_params(colors="#cfe8ff", labelsize=8)
    cb.outline.set_edgecolor("#2a3550")

    out_p = Path(out_path)
    if out_p.suffix.lower() == ".gif":
        writer = PillowWriter(fps=int(fps))
    else:
        writer = FFMpegWriter(fps=int(fps), bitrate=5000, codec="libx264")
    print(f"rendering {n_video} frames @ {fps} fps ({duration:.1f}s, start {start:.1f}s) -> {out_path}")
    with writer.saving(fig, str(out_p), dpi=100):
        for f in range(n_video):
            draw(f)
            writer.grab_frame()
            if f % 60 == 0:
                print(f"  frame {f}/{n_video}", flush=True)
    plt.close(fig)
    print(f"wrote {out_path}")


def _web_segments(x, y, z, idx, P, base, alpha):
    """Tidy local filaments: link each recent point only to its single nearest
    spatial neighbour (short links), not to temporally-consecutive points (which are
    fanned far apart and would crisscross the whole field). The result is a calm,
    clustered constellation that traces local structure; the older trail is left as
    a soft point field. Links inherit the points' recency, so they fade out behind
    the leading edge."""
    m = min(150, x.shape[0])
    if m < 3:
        return [], []
    pts = np.column_stack([x[-m:], y[-m:], z[-m:]])
    cb = base[-m:]
    ab = alpha[-m:]
    d2 = ((pts[:, None, :] - pts[None, :, :]) ** 2).sum(-1)
    np.fill_diagonal(d2, np.inf)
    nn = np.argmin(d2, axis=1)
    segs = []
    cols = []
    for i in range(m):
        j = int(nn[i])
        if i < j:  # dedupe mutual pairs
            segs.append([pts[i], pts[j]])
            c = cb[i].copy()
            c[3] = float(np.clip(min(ab[i], ab[j]) * 0.45, 0.0, 0.55))
            cols.append(c)
    return segs, cols


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Render the pan 3D audio particle animation.")
    ap.add_argument("features_base", help="feature base path (<base>.f32 + <base>.json)")
    ap.add_argument("--out", required=True, help="output .mp4 or .gif")
    ap.add_argument("--seconds", type=float, default=30.0, help="excerpt length (0 = full)")
    ap.add_argument("--start", type=float, default=0.0, help="excerpt start offset (s)")
    ap.add_argument("--fps", type=float, default=30.0, help="video frame rate")
    ap.add_argument("--lifetime", type=float, default=2.5, help="particle lifetime (s)")
    ap.add_argument("--title", default="pan — audio-reactive particle field")
    args = ap.parse_args(argv)
    render(args.features_base, args.out, args.seconds, args.fps, args.lifetime,
           args.title, args.start)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
