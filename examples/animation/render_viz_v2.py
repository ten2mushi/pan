#!/usr/bin/env python3
"""pan feature-matrix -> 3D constellation animation (Phase 17 renderer, v2).

A second visual treatment of the same pan feature matrix, in the spirit of Lucio
Arese's "Visualizing Bird Songs": a pure-black void filled with thousands of tiny
crystalline points connected by hair-thin lines into a growing neural-network /
constellation web, with the camera drifting slowly through the 3-D structure.

Same data as v1 (`render_viz.py`, which is left untouched): each point is one
analysis frame; its position is feature-placed (dominant frequency = vertical
altitude, loudness = radius, golden-angle fan = breadth) so the structure mirrors
the spectrogram; points accumulate over time into the web, the current point leads,
and the bottom-left readout tracks it. The differences from v1 are purely aesthetic:

  * COLOUR  — a narrow icy blue->white band keyed to dominant frequency (deep blue =
              low, near-white = high): crystalline, not rainbow.
  * MESH    — a precomputed k-nearest-neighbour graph drawn as hair-thin icy lines;
              an edge appears once BOTH its points have been emitted, so the web
              grows as the piece plays (a constellation assembling itself).
  * CAMERA  — a slow drift: gentle continuous orbit + slow vertical bob + a slow
              dolly in/out, to read the structure in depth without rushing.

The pan library did all the feature extraction; this only draws. `run_pipeline.py
--style constellation` muxes the matching audio excerpt into the mp4.

Usage:
  render_viz_v2.py <features_base> --out <out.mp4> [--seconds N] [--start S]
                   [--fps F] [--lifetime S] [--neighbors K] [--max-points M]
                   [--title STR]
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
from matplotlib.animation import FFMpegWriter, PillowWriter  # noqa: E402
from matplotlib.colors import LinearSegmentedColormap  # noqa: E402
from mpl_toolkits.mplot3d.art3d import Line3DCollection  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parent))
from render_viz import build_particles, load_features  # noqa: E402

# A narrow icy ramp: deep glacial blue (low frequency) -> pale ice -> near white
# (high frequency). Crystalline and cold, close to the monochrome reference but
# carrying a faint trace of the frequency mapping.
ICE = LinearSegmentedColormap.from_list(
    "pan_ice", ["#2b4a78", "#5b8fc9", "#a9d2f2", "#e8f4ff", "#ffffff"]
)
FREQ_EDGE_RGB = (0.62, 0.78, 0.98)  # icy blue-grey: frequency/feature neighbours
BG = "#000000"  # pure black void
HUD_FG = "#9fb6d8"


def _knn_edges(pts: np.ndarray, k: int) -> tuple[np.ndarray, np.ndarray]:
    """Undirected k-nearest-neighbour edge list over `pts` [M,3] (precomputed once).

    Returns (src, dst) index arrays with src < dst (deduped). Uses a KD-tree so it
    scales to a whole track's worth of points (tens of thousands) — a dense MxM
    distance matrix would be gigabytes there."""
    from scipy.spatial import cKDTree

    m = pts.shape[0]
    if m < 2:
        return np.empty(0, int), np.empty(0, int)
    kk = min(k + 1, m)  # +1: the first neighbour returned is the point itself
    tree = cKDTree(pts)
    _, nn = tree.query(pts, k=kk)
    nn = np.atleast_2d(nn)
    src = np.repeat(np.arange(m), kk - 1)
    dst = nn[:, 1:].reshape(-1)
    lo = np.minimum(src, dst)
    hi = np.maximum(src, dst)
    key = lo.astype(np.int64) * m + hi
    _, uniq = np.unique(key, return_index=True)
    return lo[uniq], hi[uniq]


def render(base, out_path, seconds, fps, lifetime, title, start=0.0,
           neighbors=4, max_points=1500):
    m, meta, by_name = load_features(base)
    P = build_particles(m, meta, by_name, lifetime)

    total = P["emit_t"][-1] if P["n"] else 0.0
    start = max(0.0, min(start, max(0.0, total - 1.0)))
    window = (total - start) if seconds <= 0 else min(seconds, total - start)
    duration = max(1.0 / fps, window)
    n_video = max(1, int(round(duration * fps)))
    R = P["bound"]
    fps_meta = P["fps"]
    start_i = int(round(start * fps_meta))
    trail = max_points

    # window of point indices that can ever be on screen, and the static mesh over
    # them (computed once; edges are revealed as their endpoints get emitted).
    win_lo = start_i
    win_hi = min(P["n"], start_i + int(np.ceil(window * fps_meta)) + 2)
    gi = np.arange(win_lo, win_hi)
    gpts = np.column_stack([P["bx"][gi], P["by"][gi], P["bz"][gi]])
    e_src, e_dst = _knn_edges(gpts, neighbors)          # FREQUENCY/feature neighbours
    e_src_abs = (e_src + win_lo)
    e_dst_abs = (e_dst + win_lo)
    e_late = np.maximum(e_src_abs, e_dst_abs)           # edge appears when both exist
    tau = max(0.3, lifetime)

    fig = plt.figure(figsize=(10, 8), facecolor=BG)
    ax = fig.add_subplot(111, projection="3d")
    txt = dict(transform=fig.transFigure, color=HUD_FG, family="monospace")

    def draw(frame):
        ax.clear()
        ax.set_facecolor(BG)
        ax.set_position([0.0, 0.0, 1.0, 0.92])
        t = start + frame / fps
        # SLOW camera: gentle continuous orbit + slow vertical bob + slow dolly.
        try:
            ax.set_box_aspect((1, 1, 1), zoom=1.75 + 0.12 * np.sin(t * 0.035))
        except TypeError:
            ax.set_box_aspect((1, 1, 1))
        ax.set_xlim(-R, R); ax.set_ylim(-R, R); ax.set_zlim(-R, R)
        ax.set_axis_off()
        ax.view_init(elev=16 + 7 * np.sin(t * 0.045), azim=(t * 5.0) % 360)

        end_i = min(P["n"], int(np.floor(t * fps_meta)) + 1)
        lo = max(start_i, end_i - trail)
        idx = np.arange(lo, end_i)
        cur_freq = cur_amp = cur_emit = 0.0
        if idx.size:
            a = np.maximum(t - P["emit_t"][idx], 0.0)
            recency = 0.10 + 0.90 * np.exp(-a / tau)
            x = P["bx"][idx]; y = P["by"][idx]; z = P["bz"][idx]

            # frequency/feature mesh (icy blue): edges whose endpoints are both
            # emitted and still in the trail.
            ev = (e_late <= (end_i - 1)) & (e_src_abs >= lo) & (e_dst_abs >= lo)
            if np.any(ev):
                s = e_src_abs[ev]; d = e_dst_abs[ev]
                segs = np.stack([
                    np.column_stack([P["bx"][s], P["by"][s], P["bz"][s]]),
                    np.column_stack([P["bx"][d], P["by"][d], P["bz"][d]]),
                ], axis=1)
                age_e = np.maximum(t - P["emit_t"][np.maximum(s, d)], 0.0)
                ea = np.clip(0.05 + 0.45 * np.exp(-age_e / (tau * 1.6)), 0.02, 0.55)
                ecols = np.zeros((segs.shape[0], 4))
                ecols[:, 0], ecols[:, 1], ecols[:, 2] = FREQ_EDGE_RGB
                ecols[:, 3] = ea
                ax.add_collection3d(Line3DCollection(list(segs), colors=ecols, linewidths=0.4))

            # Every node is drawn the same way; what marks the CURRENT timestep is a
            # quick birth PULSE — a node appears, swells to a peak ~70 ms after
            # emission, then shrinks back to its small resting size — so emission
            # reads as a smooth grow-and-shrink rather than a hard-popping marker.
            # `g` is a grow-then-shrink bump: 0 at emission, peak 1 at age `tp`,
            # decaying after, so the freshest nodes are mid-swell.
            amp_i = P["amp"][idx]
            tp = 0.05
            # a tighter, sharper grow-then-shrink bump (peak 1 at age `tp`); the
            # 1.6 power steepens both the rise and the fall.
            g = np.where(a > 0, (a / tp) * np.exp(1.0 - a / tp), 0.0)
            g = np.clip(g, 0.0, 1.0) ** 1.6
            s_rest = 3.0 + 9.0 * amp_i
            size = s_rest + (26.0 + 118.0 * amp_i) * g
            rgba = ICE(P["cval"][idx])
            # the pulse also brightens the node as it swells, then it fades with recency
            rgba[:, 3] = np.clip(recency * (0.40 + 0.55 * amp_i) + 0.55 * g, 0.05, 1.0)
            ax.scatter(x, y, z, s=size, c=rgba, marker="o", depthshade=False,
                       edgecolors="none", zorder=5)

            cur = idx[-1]
            cur_freq = float(P["freq_hz"][cur])
            cur_amp = float(P["amp_raw"][cur])  # pan's 0..1 signal amplitude
            cur_emit = float(P["emit_t"][cur])  # this point's emission timestamp

        fig.text(0.5, 0.965, title, ha="center", color="#dfe8fb", fontsize=12.5,
                 weight="bold", family="monospace")
        # Data for the current point (notes/1.md schema). FREQUENCY = its most-active
        # band; AMPLITUDE = its 0..1 signal level; EMISSION TIME = when it was emitted
        # (= the running clock, since the current point is the newest); LIFETIME = the
        # span a point stays in the field before it fades (a point's lifetime animates
        # 0 -> this, so for the just-emitted current point it is the full span ahead).
        fig.text(0.025, 0.140, "current point", fontsize=9, color="#54688f",
                 family="monospace", transform=fig.transFigure)
        fig.text(0.025, 0.110, f"COLOR / FREQUENCY   {cur_freq:8.1f} Hz", fontsize=10.5, **txt)
        fig.text(0.025, 0.083, f"SIGNAL AMPLITUDE    {cur_amp:8.4f}", fontsize=10.5, **txt)
        fig.text(0.025, 0.056, f"LIFETIME            {lifetime:8.2f} s", fontsize=10.5, **txt)
        fig.text(0.025, 0.029, f"EMISSION TIME       {cur_emit:8.4f} s", fontsize=10.5, **txt)
        fig.text(0.975, 0.040, "— frequency neighbours", ha="right", fontsize=9,
                 color=tuple(FREQ_EDGE_RGB), family="monospace", transform=fig.transFigure)
        return []

    # icy frequency colorbar
    import matplotlib as mpl
    sm = plt.cm.ScalarMappable(cmap=ICE, norm=P["norm"])
    cax = fig.add_axes([0.30, 0.915, 0.40, 0.018])
    cb = fig.colorbar(sm, cax=cax, orientation="horizontal")
    lo, hi = P["flo"], P["fhi"]
    ticks = np.geomspace(lo, hi, 5)
    cb.set_ticks([np.log2(h) for h in ticks])
    cb.set_ticklabels([f"{h/1000:.1f}k" if h >= 1000 else f"{int(round(h))}" for h in ticks])
    cb.ax.tick_params(colors="#cfe8ff", labelsize=8)
    cb.outline.set_edgecolor("#223")
    _ = mpl

    out_p = Path(out_path)
    if out_p.suffix.lower() == ".gif":
        writer = PillowWriter(fps=int(fps))
    else:
        writer = FFMpegWriter(fps=int(fps), bitrate=6000, codec="libx264")
    print(f"rendering {n_video} frames @ {fps} fps ({duration:.1f}s, start {start:.1f}s), "
          f"{gi.size} pts, {e_src.size} mesh edges -> {out_path}")
    with writer.saving(fig, str(out_p), dpi=100):
        for f in range(n_video):
            draw(f)
            writer.grab_frame()
            if f % 60 == 0:
                print(f"  frame {f}/{n_video}", flush=True)
    plt.close(fig)
    print(f"wrote {out_path}")


def main(argv=None):
    ap = argparse.ArgumentParser(description="Render the pan 3D constellation animation (v2).")
    ap.add_argument("features_base")
    ap.add_argument("--out", required=True)
    ap.add_argument("--seconds", type=float, default=30.0)
    ap.add_argument("--start", type=float, default=0.0)
    ap.add_argument("--fps", type=float, default=30.0)
    ap.add_argument("--lifetime", type=float, default=3.0)
    ap.add_argument("--neighbors", type=int, default=4)
    ap.add_argument("--max-points", type=int, default=1500)
    ap.add_argument("--title", default="pan — constellation")
    args = ap.parse_args(argv)
    render(args.features_base, args.out, args.seconds, args.fps, args.lifetime,
           args.title, args.start, args.neighbors, args.max_points)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
