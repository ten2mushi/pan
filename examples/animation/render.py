#!/usr/bin/env python3
"""examples/animation/render.py — one command to render an audio-reactive animation.

    python examples/animation/render.py andesana_helix
    python examples/animation/render.py --list
    python examples/animation/render.py incea_constellation --seconds 20   # quick preview

It resolves an experiment (examples/animation/experiments.py), then runs the whole
pipeline end-to-end and writes a self-describing output folder:

  decode  source audio ──► data/work/<input>.mono.f32         (cached; via examples/utils/to_lpcm.py)
  scan    mono LPCM    ──► [f_lo, f_hi]                        (numpy; track-adaptive pitch axis)
  analyze mono LPCM    ──► data/work/<input>.f<FRAME>.features (cached; via zig-out/bin/example-analyze)
  render  features     ──► <out>/<experiment>.mp4             (via capture_webgl.mjs + the WebGL viewer)
  stamp   resolved cfg ──► <out>/config.json + <experiment>_description.md

Output folder (the ideation convention):
  data/output/animation/ideation/<EXPERIMENT_NAME>/

Everything that determines the look — the experiment name, mode, FFT window, detected
frequency band, fps, every forwarded viewer param, and the exact command to recreate
it — is written into config.json and the description, so an output is never orphaned
from the code/config that made it.

Anything in the experiment dict beyond the known keys (input/mode/frame/title/blurb)
is forwarded to capture_webgl.mjs as --<key-with-underscores-as-dashes> <value>, so
new viewer knobs need no change here.
"""
from __future__ import annotations

import argparse
import json
import math
import shutil
import subprocess
import sys
import time
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parents[2]
WORK = REPO / "data" / "work"
OUT_ROOT = REPO / "data" / "output" / "animation" / "ideation"
ANALYZE_BIN = REPO / "zig-out" / "bin" / "example-analyze"
ANALYSIS_RATE = 44_100

sys.path.insert(0, str(Path(__file__).resolve().parent))
import experiments as EXP  # noqa: E402
import probe as PROBE  # noqa: E402

# keys consumed by the pipeline itself (everything else is forwarded to the capturer)
_PIPELINE_KEYS = {"input", "mode", "frame", "title", "blurb", "channels"}


def sh(cmd: list[str], **kw) -> None:
    print("  $", " ".join(str(c) for c in cmd))
    subprocess.run(cmd, check=True, cwd=str(REPO), **kw)


def newer(a: Path, b: Path) -> bool:
    """True if a exists and is at least as new as b (so b need not be regenerated)."""
    return a.exists() and b.exists() and a.stat().st_mtime >= b.stat().st_mtime


def decode(input_key: str) -> Path:
    """source audio -> data/work/<input>.mono.f32 (cached)."""
    src = REPO / EXP.INPUTS[input_key]
    if not src.exists():
        sys.exit(f"input source not found: {src}")
    mono = WORK / f"{input_key}.mono.f32"
    if newer(mono, src):
        print(f"decode: cached {mono.name}")
        return mono
    print(f"decode: {src.name} -> {mono.name}")
    sh([str(REPO / ".venv/bin/python"), "examples/utils/to_lpcm.py",
        "--rate", str(ANALYSIS_RATE), str(src), str(WORK / input_key)])
    return mono


def scan_band(mono: Path, frame: int) -> tuple[float, float]:
    """Pre-scan the mono LPCM for its active frequency band [f_lo, f_hi] (Hz).

    Averages the power spectrum over the file, then takes the cumulative-energy
    2nd/98th-percentile frequencies (clamped to a musical floor). This is what makes
    the pitch axis adapt to each track instead of guessing from percentiles in the
    viewer.
    """
    x = np.fromfile(mono, dtype="<f4")
    if x.size < frame:
        return 40.0, ANALYSIS_RATE / 2
    hop = frame  # non-overlapping is plenty for a long-term average
    win = np.hanning(frame).astype(np.float32)
    nseg = 1 + (x.size - frame) // hop
    nseg = min(nseg, 4000)  # cap work on long files
    step = max(1, (x.size - frame) // (hop * nseg)) if nseg else 1
    acc = np.zeros(frame // 2 + 1, dtype=np.float64)
    cnt = 0
    for s in range(0, x.size - frame, hop * step):
        seg = x[s:s + frame] * win
        acc += np.abs(np.fft.rfft(seg)) ** 2
        cnt += 1
        if cnt >= nseg:
            break
    if cnt == 0:
        return 40.0, ANALYSIS_RATE / 2
    acc /= cnt
    acc[0] = 0.0  # drop DC
    freqs = np.fft.rfftfreq(frame, 1.0 / ANALYSIS_RATE)
    cum = np.cumsum(acc)
    total = cum[-1] if cum[-1] > 0 else 1.0
    lo_i = int(np.searchsorted(cum, 0.02 * total))
    hi_i = int(np.searchsorted(cum, 0.98 * total))
    f_lo = max(40.0, float(freqs[max(lo_i, 1)]))
    f_hi = float(freqs[min(hi_i, len(freqs) - 1)])
    if f_hi <= f_lo * 2:
        f_hi = f_lo * 8
    return round(f_lo, 1), round(f_hi, 1)


def decode_stereo(input_key: str) -> tuple[Path, Path]:
    """source audio -> data/work/<input>.L.f32 + .R.f32 (two aligned mono f32, cached).

    A thin ffmpeg channelsplit wrapper (the canonical decoder is mono-by-contract);
    both channels come from one pass so they are sample-aligned and equal length.
    """
    src = REPO / EXP.INPUTS[input_key]
    lf, rf = WORK / f"{input_key}.L.f32", WORK / f"{input_key}.R.f32"
    if newer(lf, src) and newer(rf, src):
        print(f"decode: cached {lf.name} + {rf.name}")
        return lf, rf
    print(f"decode: {src.name} -> {lf.name} + {rf.name} (stereo)")
    sh(["ffmpeg", "-v", "error", "-y", "-i", str(src),
        "-filter_complex", "channelsplit=channel_layout=stereo[l][r]",
        "-map", "[l]", "-ar", str(ANALYSIS_RATE), "-f", "f32le", str(lf),
        "-map", "[r]", "-ar", str(ANALYSIS_RATE), "-f", "f32le", str(rf)])
    return lf, rf


def analyze_stereo(input_key: str, lf: Path, rf: Path, frame: int) -> Path:
    base = WORK / f"{input_key}.f{frame}.stereo.features"
    f32, js = Path(str(base) + ".f32"), Path(str(base) + ".json")
    if newer(f32, lf) and newer(f32, rf) and js.exists():
        print(f"analyze: cached {f32.name}")
        return base
    ensure_analyzer()
    print(f"analyze(stereo): {lf.name}+{rf.name} -> {f32.name} (frame={frame})")
    sh([str(ANALYZE_BIN), "--stereo", str(lf), str(rf), str(ANALYSIS_RATE), str(base), str(frame)])
    return base


def ensure_analyzer() -> None:
    if ANALYZE_BIN.exists():
        return
    print("analyze: building example-analyze (zig build examples)")
    sh(["zig", "build", "examples"])


def analyze(input_key: str, mono: Path, frame: int) -> Path:
    """mono LPCM -> data/work/<input>.f<FRAME>.features.{f32,json} (cached)."""
    base = WORK / f"{input_key}.f{frame}.features"
    f32, js = base.with_suffix(".f32"), base.with_suffix(".json")
    # `base` already has no extension issues: writeFeatureMatrix appends .f32/.json
    f32 = Path(str(base) + ".f32")
    js = Path(str(base) + ".json")
    if newer(f32, mono) and js.exists():
        print(f"analyze: cached {f32.name}")
        return base
    ensure_analyzer()
    print(f"analyze: {mono.name} -> {f32.name} (frame={frame})")
    sh([str(ANALYZE_BIN), str(mono), str(ANALYSIS_RATE), str(base), str(frame)])
    return base


def _read_matrix(base: Path):
    """Load a feature matrix written by analyze.zig: (sidecar, frames×cols array, offsets)."""
    js = json.loads(Path(str(base) + ".json").read_text())
    ncols = js["n_cols"]
    m = np.fromfile(Path(str(base) + ".f32"), dtype="<f4")
    nfr = m.size // ncols
    m = m[: nfr * ncols].reshape(nfr, ncols)
    off = {c["name"]: (c["offset"], c["width"]) for c in js["columns"]}
    return js, m, off, nfr


def _mel_filterbank(nbins: int, sr: int, frame: int, nmel: int = 26):
    """Triangular mel filterbank over `nbins` power-spectrum bins."""
    def hz2mel(f):
        return 2595.0 * np.log10(1.0 + f / 700.0)

    def mel2hz(mel):
        return 700.0 * (10.0 ** (mel / 2595.0) - 1.0)

    mpts = np.linspace(hz2mel(0.0), hz2mel(sr / 2.0), nmel + 2)
    hz = mel2hz(mpts)
    centre = np.floor(frame * hz / sr).astype(int)
    fb = np.zeros((nmel, nbins))
    for i in range(1, nmel + 1):
        lo, ce, hi = centre[i - 1], centre[i], centre[i + 1]
        ce = max(ce, lo + 1)
        hi = max(hi, ce + 1)
        for b in range(lo, ce):
            if 0 <= b < nbins:
                fb[i - 1, b] = (b - lo) / max(ce - lo, 1)
        for b in range(ce, hi):
            if 0 <= b < nbins:
                fb[i - 1, b] = (hi - b) / max(hi - ce, 1)
    return fb


def compute_pca(base: Path, feats: list[str], whiten: bool, frame: int) -> np.ndarray:
    """Build a per-frame timbre vector from the matrix, z-score, PCA (SVD) → top-3.

    Features (selectable via `feats`): `scalars` (centroid/rolloff/flux/rms), `flatness`
    (geometric/arithmetic-mean tonality), `contrast` (peak−valley in log-spaced
    sub-bands), `mfcc` (mel-log-DCT, 13). The result is the projection of each frame
    onto this track's own three principal timbral axes, robustly scaled to ~[−8,8].
    """
    js, m, off, nfr = _read_matrix(base)
    sr = ANALYSIS_RATE
    specname = "full_spectrum" if "full_spectrum" in off else "full_spectrum_l"
    so, sw = off[specname]
    spec = m[:, so:so + sw].astype(np.float64)            # power per bin
    if "full_spectrum_r" in off:                          # stereo → mono power L+R
        ro, rw = off["full_spectrum_r"]
        spec = spec + m[:, ro:ro + rw].astype(np.float64)

    sel = set(feats)
    blocks: list[np.ndarray] = []
    if "scalars" in sel:
        for nm in ("centroid", "rolloff", "flux", "rms"):
            if nm in off:
                o, _ = off[nm]
                blocks.append(m[:, o:o + 1].astype(np.float64))
    if "flatness" in sel:
        p = spec[:, 1:]
        gm = np.exp(np.mean(np.log(p + 1e-12), axis=1))
        am = np.mean(p, axis=1) + 1e-12
        blocks.append((gm / am).reshape(-1, 1))
    if "contrast" in sel:
        nb = spec.shape[1]
        edges = np.unique(np.floor(np.logspace(np.log10(2), np.log10(nb - 1), 7)).astype(int))
        cont = []
        for k in range(len(edges) - 1):
            sub = spec[:, edges[k]:edges[k + 1]]
            if sub.shape[1] < 2:
                cont.append(np.zeros(nfr))
                continue
            ssub = np.sort(sub, axis=1)
            q = max(1, sub.shape[1] // 5)
            peak = np.mean(ssub[:, -q:], axis=1)
            val = np.mean(ssub[:, :q], axis=1)
            cont.append(np.log(peak + 1e-9) - np.log(val + 1e-9))
        blocks.append(np.stack(cont, axis=1))
    if "mfcc" in sel:
        fb = _mel_filterbank(spec.shape[1], sr, frame, nmel=26)
        mel = np.log(spec @ fb.T + 1e-9)                   # nfr × 26
        K, nmf = mel.shape[1], 13
        dct = np.array([[np.cos(np.pi * (k + 0.5) * j / K) for k in range(K)] for j in range(nmf)])
        blocks.append(mel @ dct.T)
    if not blocks:
        raise SystemExit(f"pca: no features selected from {feats}")

    X = np.nan_to_num(np.concatenate(blocks, axis=1))
    Z = (X - X.mean(0)) / (X.std(0) + 1e-9)               # z-score each dim
    Zc = Z - Z.mean(0)
    _, S, Vt = np.linalg.svd(Zc, full_matrices=False)
    comp = Zc @ Vt[:3].T                                  # nfr × 3
    if whiten:
        comp = comp / (S[:3] / np.sqrt(max(nfr - 1, 1)) + 1e-9)
    out = np.zeros_like(comp)
    for a in range(3):
        lo, hi = np.percentile(comp[:, a], [2, 98])
        rng = max(hi - lo, 1e-9)
        out[:, a] = np.clip((comp[:, a] - (lo + hi) / 2) / (rng / 2) * 8.0, -10.0, 10.0)
    return out.astype("<f4")


def render(name: str, seconds: float, fps: int, start: float, extra_cli: dict) -> Path:
    cfg = dict(EXP.get(name))
    cfg.update(extra_cli)  # CLI overrides win
    input_key = cfg["input"]
    mode = cfg["mode"]
    frame = int(cfg.get("frame", 2048))
    channels = str(cfg.get("channels", "mono")).lower()
    if channels not in ("mono", "stereo"):
        sys.exit(f"channels must be 'mono' or 'stereo' (got '{channels}')")

    out_dir = OUT_ROOT / name
    out_dir.mkdir(parents=True, exist_ok=True)
    out_mp4 = out_dir / f"{name}.mp4"

    print(f"\n=== experiment: {name}  (input={input_key}, mode={mode}, frame={frame}, channels={channels}) ===")
    src = REPO / EXP.INPUTS[input_key]
    mono = decode(input_key)                       # always used for the band pre-scan
    f_lo, f_hi = scan_band(mono, frame)
    print(f"scan: active band {f_lo}..{f_hi} Hz")

    if channels == "stereo":
        # Refuse stereo on effectively-mono input — render it as a misleading stereo
        # image would be wasted work. The probe is the single source of truth.
        info = PROBE.probe(str(src))
        print(f"probe: container={info['container_channels']}ch, side={info['side_frac']*100:.2f}%, "
              f"corr={info['correlation']:+.3f} -> {'stereo' if info['is_stereo'] else 'MONO'}")
        if not info["is_stereo"]:
            sys.exit(
                f"\nERROR: experiment '{name}' requests channels=stereo, but '{input_key}' is "
                f"not usably stereo ({info['reason']}).\n"
                f"       Re-run with channels=mono (or --channels mono)."
            )
        lf, rf = decode_stereo(input_key)
        base = analyze_stereo(input_key, lf, rf, frame)
    else:
        base = analyze(input_key, mono, frame)

    # forward every non-pipeline experiment key to the capturer as --flag value
    fwd: list[str] = []
    for k, v in cfg.items():
        if k in _PIPELINE_KEYS:
            continue
        fwd += [f"--{k.replace('_', '-')}", str(v)]

    # PCA timbral-fingerprint mode: build the per-frame 3-D embedding (numpy) and pass
    # its path to the viewer. Regenerated each run (cheap vs the render); keyed by the
    # feature set + whiten so a different selection writes a distinct file.
    if mode == "pca":
        feats_raw = str(cfg.get("pca_features", "all"))
        feats = (["scalars", "flatness", "contrast", "mfcc"] if feats_raw in ("all", "")
                 else [s.strip() for s in feats_raw.split(",") if s.strip()])
        whiten = str(cfg.get("pca_whiten", "0")).lower() in ("1", "true", "yes")
        sig = "-".join(sorted(feats)) + ("-w" if whiten else "")
        pca_path = Path(str(base) + f".pca.{sig}.f32")
        print(f"pca: features={feats} whiten={whiten} -> {pca_path.name}")
        compute_pca(base, feats, whiten, frame).tofile(pca_path)
        fwd += ["--pca-file", str(pca_path.relative_to(REPO))]

    audio_src = REPO / EXP.INPUTS[input_key]
    # `base` must be REPO-relative: the capturer serves it as an http URL under the
    # repo root, and the viewer treats a leading "/" or absolute path as server-root.
    base_rel = base.relative_to(REPO)
    cmd = [
        "node", "examples/animation/capture_webgl.mjs",
        "--base", str(base_rel),
        "--mode", mode,
        "--audio", str(audio_src),
        "--out", str(out_mp4),
        "--fps", str(fps),
        "--title", str(cfg.get("title", name)),
    ]
    # NB: we deliberately do NOT pass --freq-lo/--freq-hi. The viewer derives the
    # pitch-axis band from the ACTUAL distribution of detected spectral peaks (a
    # long-term average band under-bounds the per-frame peaks and would push them onto
    # the axis extremes). The pre-scan band above is kept only as a diagnostic.
    if seconds > 0:
        cmd += ["--seconds", str(seconds)]
    if start > 0:
        cmd += ["--start", str(start)]
    cmd += fwd

    t0 = time.time()
    sh(cmd)
    dt = time.time() - t0

    # ---- stamp the resolved config + a human description into the output -----
    resolved = {
        "experiment": name,
        "input": input_key,
        "input_source": str(EXP.INPUTS[input_key]),
        "mode": mode,
        "channels": channels,
        "frame": frame,
        "analysis_rate": ANALYSIS_RATE,
        "prescan_band_hz_diagnostic": [f_lo, f_hi],
        "pitch_axis_band": "peak-distribution (1st..99th pctile, computed in viewer)",
        "fps": fps,
        "seconds": seconds,
        "start": start,
        "forwarded": {k: v for k, v in cfg.items() if k not in _PIPELINE_KEYS},
        "features": str(Path(str(base) + ".f32").relative_to(REPO)),
        "output_mp4": str(out_mp4.relative_to(REPO)),
        "render_seconds": round(dt, 1),
        "reproduce": f"python examples/animation/render.py {name}",
    }
    (out_dir / "config.json").write_text(json.dumps(resolved, indent=2, ensure_ascii=False))
    # copy the small feature sidecar so the folder is self-contained (the big .f32
    # stays in data/work and is referenced by path)
    side = Path(str(base) + ".json")
    if side.exists():
        shutil.copy(side, out_dir / "features.json")

    # Colour/look line reflects the actually-resolved palette + effects (not a fixed
    # ICE assumption — ember/aurora/bone/mono and bloom are all selectable).
    palette = str(cfg.get("palette", "ice"))
    color_by = str(cfg.get("color_by", "pitch"))
    extras = []
    if str(cfg.get("sat_by_timbre", "0")) in ("1", "true", "True"):
        extras.append("saturation driven by tonality (tonal→colour, breathy→grey)")
    if str(cfg.get("bloom", "0")) in ("1", "true", "True"):
        extras.append("cinematic bloom (ACES tonemapped)")
    if "edge_life" in cfg:
        extras.append(f"edge trails fade over ~{int(int(cfg['edge_life']) * 0.33)} s")
    extra_txt = (" · " + "; ".join(extras)) if extras else ""

    desc = out_dir / f"{name}_description.md"
    desc.write_text(
        f"# {cfg.get('title', name)}\n\n"
        f"**Experiment:** `{name}`  ·  **mode:** `{mode}`  ·  **input:** `{input_key}`\n\n"
        f"{cfg.get('blurb', '')}\n\n"
        f"## What you are seeing\n"
        f"- Analysis: pan STFT, FFT window **{frame}** ({ANALYSIS_RATE/frame:.1f} Hz/bin), "
        f"60 frames/s, full power spectrum + dominant band / amplitude / centroid / rolloff / flux.\n"
        f"- Track-adaptive pitch axis: spans the actual spectral-peak distribution "
        f"(1st–99th percentile, computed in the viewer); out-of-band peaks are dropped, not clamped. "
        f"Pre-scan diagnostic band for reference: **{f_lo}–{f_hi} Hz**.\n"
        f"- Colour: **{palette}** palette (perceptual OKLCH, no rainbow), driven by {color_by}{extra_txt}. "
        f"Points: round glow with a tight grow-then-shrink birth pulse. Edges: fat kNN web.\n\n"
        f"## Reproduce\n```\npython examples/animation/render.py {name}\n```\n\n"
        f"Resolved parameters are in `config.json`; the feature-matrix layout is in `features.json`.\n"
    )
    print(f"\n✓ {name}: {out_mp4.relative_to(REPO)}  ({dt:.0f}s render)")
    return out_mp4


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Render a pan audio animation experiment.")
    ap.add_argument("experiment", nargs="?", help="experiment name (see --list)")
    ap.add_argument("--list", action="store_true", help="list experiments and exit")
    ap.add_argument("--all", action="store_true", help="render every experiment")
    ap.add_argument("--batch", action="store_true", help="render the curated compound 'hero' set")
    ap.add_argument("--seconds", type=float, default=0.0, help="render only N seconds (0 = full)")
    ap.add_argument("--start", type=float, default=0.0, help="start offset in seconds")
    ap.add_argument("--fps", type=int, default=30, help="output frames per second (default 30)")
    # any extra --key value pairs override the experiment dict / are forwarded
    args, rest = ap.parse_known_args(argv)

    if args.list or (not args.experiment and not args.all and not args.batch):
        print("experiments:")
        for nm in EXP.names():
            c = EXP.get(nm)
            print(f"  {nm:28s}  input={c['input']:9s} mode={c['mode']:14s} frame={c.get('frame',2048)}")
        return 0

    # parse passthrough overrides (--key value)
    extra: dict = {}
    it = iter(rest)
    for tok in it:
        if tok.startswith("--"):
            key = tok[2:].replace("-", "_")
            val = next(it, "")
            extra[key] = val

    if args.batch:
        targets = EXP.COMPOUND_BATCH
    elif args.all:
        targets = EXP.names()
    else:
        targets = [args.experiment]
    for nm in targets:
        if nm not in EXP.EXPERIMENTS:
            sys.exit(f"unknown experiment '{nm}' (try --list)")
        render(nm, args.seconds, args.fps, args.start, extra)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
