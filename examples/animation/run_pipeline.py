#!/usr/bin/env python3
"""End-to-end Phase-17 pipeline driver: audio file -> 3D particle animation.

Chains the three Phase-17 stages for one or more input audio files:

  1. DECODE   scripts/decode_audio.py : <input> -> <work>/<name>.mono.f32 (+ sidecar)
  2. ANALYZE  examples/analyze (the pan-library Zig binary) : mono LPCM ->
              <work>/<name>.features.f32 (+ .json) — ALL feature extraction is the
              pan library's job;
  3. RENDER   examples/render_viz.py : feature matrix -> <out>/<name>.mp4

Between (2) and (3) it runs a NUMERIC SHAPE CHECK on the feature matrix (the
plan's non-gold validation for the analysis output): the row count matches the
decoded duration × fps to within a block, the column count matches the sidecar,
the values are finite, and the per-column ranges are sane. The animation itself is
validated by eye (the brief: viz is validated visually + a shape check).

The pan analyzer binary is `zig-out/bin/example-analyze`; this driver builds it
(`zig build examples -Doptimize=ReleaseFast`) if it is missing.

Usage:
  run_pipeline.py INPUT [INPUT ...] [--out DIR] [--work DIR] [--rate HZ]
                  [--seconds N] [--start S] [--fps F] [--check-only]
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parents[2]  # examples/animation/ -> repo root
SCRIPTS = REPO / "scripts"
EXAMPLES = Path(__file__).resolve().parent  # the animation experiment dir (renderers live here)
ANALYZER = REPO / "zig-out" / "bin" / "example-analyze"
EXPERIMENT = "animation"  # output goes to data/output/<EXPERIMENT>_<source>/


def _slug(p: Path) -> str:
    import re

    stem = p.stem
    if stem.endswith("_lpcm"):
        stem = stem[: -len("_lpcm")]
    stem = re.sub(r"\([^)]*\)", " ", stem)  # drop "(HDR - 4K - 5.1)"-style tags
    stem = re.sub(r"[^A-Za-z0-9]+", "_", stem.lower())  # non-alnum runs -> "_"
    return stem.strip("_")


def ensure_analyzer() -> Path:
    if ANALYZER.exists():
        return ANALYZER
    print("building examples/analyze (zig build examples -Doptimize=ReleaseFast)...", file=sys.stderr)
    subprocess.run(
        ["zig", "build", "examples", "-Doptimize=ReleaseFast"], cwd=REPO, check=True
    )
    if not ANALYZER.exists():
        raise RuntimeError(f"analyzer not found after build: {ANALYZER}")
    return ANALYZER


def shape_check(features_base: Path, decode_meta: dict) -> None:
    """Assert the feature matrix is the right shape and sane (the analysis check)."""
    meta = json.loads((features_base.with_name(features_base.name + ".json")).read_text())
    cols = meta["n_cols"]
    m = np.fromfile(str(features_base) + ".f32", dtype="<f4")
    assert m.size % cols == 0, f"matrix size {m.size} not a multiple of n_cols {cols}"
    rows = m.size // cols
    assert rows == meta["n_frames"], f"row count {rows} != sidecar n_frames {meta['n_frames']}"
    assert np.isfinite(m).all(), "feature matrix contains non-finite values"

    # Expected rows ≈ duration × fps (the analyzer rounds up to a block at the tail).
    fps = meta["fps"]
    expect = decode_meta["frames"] / decode_meta["sample_rate"] * fps
    assert rows >= expect - 1, f"too few frames: {rows} < ~{expect:.0f}"
    assert rows <= expect + 256, f"far too many frames: {rows} >> ~{expect:.0f}"

    mm = m.reshape(rows, cols)
    dominant = mm[:, 0]
    amplitude = mm[:, 1]
    assert dominant.min() >= 0 and dominant.max() < meta["bins"], "dominant band out of [0,bins)"
    assert amplitude.min() >= 0 and amplitude.max() <= 1.001, "amplitude out of [0,1]"
    print(
        f"  shape-check OK: {rows} frames × {cols} cols (~{expect:.0f} expected); "
        f"dominant∈[0,{int(dominant.max())}] amp∈[{amplitude.min():.3f},{amplitude.max():.3f}]"
    )


def process(
    input_path: Path,
    out_dir: Path,
    work_dir: Path,
    rate: int,
    seconds: float,
    start: float,
    fps: float,
    check_only: bool,
    lifetime: float = 2.2,
    style: str = "classic",
) -> Path | None:
    name = _slug(input_path)
    work_dir.mkdir(parents=True, exist_ok=True)
    out_dir.mkdir(parents=True, exist_ok=True)
    base = work_dir / name

    print(f"\n=== {input_path.name}  ->  {name} ===")
    # 1. decode
    sys.path.insert(0, str(SCRIPTS))
    from decode_audio import decode_to_analysis_lpcm  # noqa: E402

    decode_meta = decode_to_analysis_lpcm(input_path, base, rate)
    mono = base.with_suffix(".mono.f32")
    print(f"  decoded -> {mono.name} ({decode_meta['frames']} frames, {decode_meta['duration_sec']:.1f}s)")

    # 2. analyze (pan library)
    analyzer = ensure_analyzer()
    features_base = work_dir / f"{name}.features"
    subprocess.run([str(analyzer), str(mono), str(rate), str(features_base)], check=True)

    # numeric shape check on the analysis output
    shape_check(features_base, decode_meta)
    if check_only:
        return None

    # 3. render (to a silent file first, then mux the audio excerpt). Two styles:
    #    classic       -> render_viz.py    (the soft rainbow particle field)
    #    constellation -> render_viz_v2.py (the icy crystalline neural-web)
    script = "render_viz_v2.py" if style == "constellation" else "render_viz.py"
    suffix = ".constellation" if style == "constellation" else ""
    # one output subfolder per experiment+input: data/output/animation_<source>/
    exp_dir = out_dir / f"{EXPERIMENT}_{name}"
    exp_dir.mkdir(parents=True, exist_ok=True)
    out_path = exp_dir / f"{name}{suffix}.mp4"
    silent = work_dir / f"{name}{suffix}.silent.mp4"
    title = input_path.stem.replace("_lpcm", "").replace("_", " ")
    lt = lifetime if style == "classic" else max(lifetime, 3.0)
    subprocess.run(
        [
            sys.executable,
            str(EXAMPLES / script),
            str(features_base),
            "--out", str(silent),
            "--seconds", str(seconds),
            "--start", str(start),
            "--fps", str(fps),
            "--lifetime", str(lt),
            "--title", f"pan · {title}",
        ],
        check=True,
    )
    mux_audio(silent, input_path, start, out_path)
    return out_path


def mux_audio(silent_video: Path, audio_src: Path, start: float, out_path: Path) -> None:
    """Mux the matching audio excerpt (from `start`) onto the silent animation.

    The animation's emission time is the audio timeline (the analysis is at the
    decode rate, no time-warp), so the excerpt starting at `start` plays in sync.
    `-shortest` trims the audio to the video length. Falls back to copying the
    silent file if ffmpeg has no usable audio stream.
    """
    from shutil import which

    if which("ffmpeg") is None:
        out_path.write_bytes(silent_video.read_bytes())
        return
    cmd = [
        "ffmpeg", "-v", "error", "-y",
        "-i", str(silent_video),
        "-ss", f"{start:.3f}", "-i", str(audio_src),
        "-map", "0:v:0", "-map", "1:a:0",
        "-c:v", "copy", "-c:a", "aac", "-b:a", "192k",
        "-shortest", str(out_path),
    ]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print(f"  [warn] audio mux failed ({r.stderr.strip().splitlines()[-1:]}); "
              f"writing silent video", flush=True)
        out_path.write_bytes(silent_video.read_bytes())
    else:
        print(f"  muxed audio from {audio_src.name} (start {start:.1f}s)")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="pan Phase-17 end-to-end pipeline.")
    ap.add_argument("inputs", nargs="+", help="input audio file(s)")
    ap.add_argument("--out", default=str(REPO / "data" / "output"), help="animation output dir")
    ap.add_argument("--work", default=str(REPO / "data" / "work"), help="intermediate dir")
    ap.add_argument("--rate", type=int, default=44_100, help="analysis sample rate")
    ap.add_argument("--seconds", type=float, default=30.0, help="excerpt length (0 = full)")
    ap.add_argument("--start", type=float, default=0.0, help="excerpt start (s)")
    ap.add_argument("--fps", type=float, default=30.0, help="video fps")
    ap.add_argument("--lifetime", type=float, default=2.2, help="particle recency time-constant (s)")
    ap.add_argument("--style", choices=["classic", "constellation"], default="classic",
                    help="classic = soft rainbow particle field; constellation = icy crystalline web")
    ap.add_argument("--check-only", action="store_true", help="decode+analyze+shape-check; no render")
    args = ap.parse_args(argv)

    outs = []
    for inp in args.inputs:
        out = process(
            Path(inp), Path(args.out), Path(args.work), args.rate,
            args.seconds, args.start, args.fps, args.check_only, args.lifetime, args.style,
        )
        if out:
            outs.append(out)
    if outs:
        print("\nwrote animations:")
        for o in outs:
            print(f"  {o}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
