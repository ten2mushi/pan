#!/bin/bash
set -e

# Change directory to project root
cd "$(dirname "$0")/../../.."

WORK_DIR="data/work"
OUT_BASE_DIR="data/output/sonification/market"

mkdir -p "$WORK_DIR"
mkdir -p "$OUT_BASE_DIR"

# Ensure zig graph is built
echo "Building zig examples..."
zig build examples

TICKER="BTC-USD"
PERIOD="2y"
INTERVAL="1d"

EXP_DIR="$OUT_BASE_DIR/$TICKER"
mkdir -p "$EXP_DIR"

SPEC_FILE="$WORK_DIR/market_$TICKER.f32"
CSV_FILE="$WORK_DIR/market_$TICKER.f32.csv"
RAW_FILE="$WORK_DIR/out_market_$TICKER.raw"
WAV_FILE="$EXP_DIR/$TICKER.wav"
MP4_FILE="$EXP_DIR/$TICKER.mp4"

# Activate python virtual environment
source examples/sonification/market/.venv/bin/activate

echo "Processing $TICKER..."

# 1. Preprocess
echo "Running Preprocessor..."
python examples/sonification/market/preprocess.py --ticker "$TICKER" --period "$PERIOD" --interval "$INTERVAL" "$SPEC_FILE"

# 2. Synthesize audio
echo "Synthesizing audio..."
./zig-out/bin/example-market "$SPEC_FILE" "$RAW_FILE"

# 3. Convert to WAV
echo "Converting to WAV..."
python examples/sound_generation/to_wav.py --stereo "$RAW_FILE" "$WAV_FILE"

# 4. Generate Animation
echo "Rendering Animation..."
python examples/sonification/market/animate.py "$CSV_FILE" "$WAV_FILE" "$MP4_FILE" "$TICKER" "$PERIOD"

echo "Done processing $TICKER! Output saved to $MP4_FILE"
