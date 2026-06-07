#!/usr/bin/env bash
# Configurable, file-level-parallel verification driver for the pan examples.
#
# Runs each example end-to-end on a SHORT clip and writes the artifacts into
# data/output/verify/<experiment>/ — proving the full pipelines run after the
# library restructure. Independent inputs are processed concurrently (the
# process-level form of the Tier-C renderBatch O3 win: each job is fully isolated,
# so the output is identical regardless of how many run at once); a single input
# simply runs one job.
#
# EVERYTHING is configurable via environment — no values are hardcoded inline:
#   DURATION_SEC  clip length in seconds for the audio examples           (default 30)
#   FPS           animation WebGL capture frame rate                      (default 24)
#   WIDTH HEIGHT  animation capture resolution                           (default 1280x720)
#   ANALYZER_RATE analysis sample rate for animation/spectrogram         (default 44100)
#   DS_RATE       deep_space synthesis rate (must match deep_space.zig)   (default 48000)
#   CORES         max concurrent file-level jobs                         (default: all cores)
#   PY            python interpreter (needs numpy/scipy/matplotlib/PIL)  (default .venv/bin/python)
#   OUT_ROOT      output root                                            (default data/output/verify)
#   WORK          scratch dir                                            (default data/work/verify)
#   AUDIO_INPUTS  newline-separated audio files for animation/spectrogram
#                 (default: the incea m4a)
#   IMAGE_DIR     deep_space source images                              (default data/input/hubble_pictures)
#   EXAMPLES      which to run                          (default "spectrogram animation deep_space")
#
# Usage:  examples/utils/run_verify.sh
#         DURATION_SEC=15 FPS=30 EXAMPLES="spectrogram" examples/utils/run_verify.sh
set -euo pipefail
cd "$(dirname "$0")/../.."   # repo root

: "${DURATION_SEC:=30}"
: "${FPS:=24}"
: "${WIDTH:=1280}"
: "${HEIGHT:=720}"
: "${ANALYZER_RATE:=44100}"
: "${DS_RATE:=48000}"
: "${CORES:=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)}"
: "${PY:=.venv/bin/python}"
: "${OUT_ROOT:=data/output/verify}"
: "${WORK:=data/work/verify}"
: "${IMAGE_DIR:=data/input/hubble_pictures}"
: "${EXAMPLES:=spectrogram animation deep_space}"
: "${AUDIO_INPUTS:=data/input/incea/AUD-20260607-WA0000.m4a}"
export DURATION_SEC FPS WIDTH HEIGHT ANALYZER_RATE DS_RATE PY OUT_ROOT WORK

# ---------------------------------------------------------------------------
# Per-file workers (self-dispatched so `xargs -P` can run them concurrently).
# ---------------------------------------------------------------------------
if [ "${1:-}" = "__audio_one" ]; then
  in_path="$2"; mode="$3"   # mode = spectrogram | animation
  base=$(basename "$in_path"); stem="${base%.*}"
  lpcm="$WORK/${stem}.mono.f32"; clip="$WORK/${stem}.clip.mono.f32"
  # decode -> mono f32 LPCM, then slice the first DURATION_SEC
  "$PY" examples/utils/to_lpcm.py --rate "$ANALYZER_RATE" "$in_path" "$WORK/${stem}" >/dev/null
  head -c $((DURATION_SEC * ANALYZER_RATE * 4)) "$lpcm" > "$clip"
  if [ "$mode" = "spectrogram" ]; then
    ./zig-out/bin/example-spectrogram "$clip" "$ANALYZER_RATE" "$WORK/${stem}.spec" >/dev/null
    "$PY" examples/spectrogram/render_spectrogram.py "$WORK/${stem}.spec" \
      --title "pan verify · ${stem}" --out-dir "$OUT_ROOT/spectrogram" >/dev/null
    echo "  [spectrogram] $stem -> $OUT_ROOT/spectrogram/${stem}.{spectrogram,mfcc}.png"
  else
    ./zig-out/bin/example-analyze "$clip" "$ANALYZER_RATE" "$WORK/${stem}.features" >/dev/null
    ffmpeg -y -i "$in_path" -t "$DURATION_SEC" -ar "$ANALYZER_RATE" -ac 1 "$WORK/${stem}.clip.wav" -loglevel error
    node examples/animation/capture_webgl.mjs --base "$WORK/${stem}.features" \
      --audio "$WORK/${stem}.clip.wav" --out "$OUT_ROOT/animation/${stem}.constellation.mp4" \
      --fps "$FPS" --seconds "$DURATION_SEC" --width "$WIDTH" --height "$HEIGHT" \
      --title "pan verify · ${stem}" >/dev/null
    echo "  [animation] $stem -> $OUT_ROOT/animation/${stem}.constellation.mp4"
  fi
  exit 0
fi

if [ "${1:-}" = "__ds_one" ]; then
  img="$2"; base=$(basename "$img"); name="${base%.*}"
  d="$OUT_ROOT/deep_space/$name"; mkdir -p "$d"
  "$PY" examples/sonification/deep_space/preprocess.py "$img" "$WORK/ds_${name}.f32" >/dev/null
  ./zig-out/bin/example-deep_space "$WORK/ds_${name}.f32" "$WORK/ds_${name}.raw" >/dev/null
  "$PY" examples/utils/to_wav.py --rate "$DS_RATE" "$WORK/ds_${name}.raw" "$d/${name}.wav" >/dev/null
  "$PY" examples/sonification/deep_space/animate.py "$img" "$d/${name}.wav" "$d/${name}.mp4" >/dev/null
  echo "  [deep_space] $name -> $d/${name}.mp4"
  exit 0
fi

# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------
echo "pan example verification — ${DURATION_SEC}s clips, ${CORES}-way file parallelism -> $OUT_ROOT/"
mkdir -p "$WORK" "$OUT_ROOT"/{spectrogram,animation,deep_space}
echo "Building examples..."
zig build examples >/dev/null

self="$0"
for ex in $EXAMPLES; do
  case "$ex" in
    spectrogram|animation)
      echo "[$ex] running (file-level parallel over audio inputs)..."
      mkdir -p "$OUT_ROOT/$ex"
      printf '%s\n' "$AUDIO_INPUTS" | xargs -P "$CORES" -I{} bash "$self" __audio_one "{}" "$ex"
      ;;
    deep_space)
      echo "[deep_space] running (file-level parallel over images, $CORES-way)..."
      find "$IMAGE_DIR" -maxdepth 1 -type f \
        \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) -print0 \
        | xargs -0 -P "$CORES" -I{} bash "$self" __ds_one "{}"
      ;;
    *) echo "  (unknown example '$ex' — skipping)" ;;
  esac
done
echo "Done. Artifacts under $OUT_ROOT/"
