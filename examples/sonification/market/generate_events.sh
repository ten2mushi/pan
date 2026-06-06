#!/bin/bash
set -e
cd "$(dirname "$0")/../../.."

WORK_DIR="data/work"
OUT_BASE_DIR="data/output/sonification/market"

zig build examples
source examples/sonification/market/.venv/bin/activate

# Function to run the pipeline
run_sonification() {
    TICKER=$1
    START=$2
    END=$3
    NAME=$4

    EXP_DIR="$OUT_BASE_DIR/$NAME"
    mkdir -p "$EXP_DIR"

    SPEC_FILE="$WORK_DIR/market_$NAME.f32"
    CSV_FILE="$WORK_DIR/market_$NAME.f32.csv"
    RAW_FILE="$WORK_DIR/out_market_$NAME.raw"
    WAV_FILE="$EXP_DIR/$NAME.wav"
    MP4_FILE="$EXP_DIR/$NAME.mp4"

    echo "========================================"
    echo "Processing $NAME ($TICKER)"
    echo "========================================"

    python examples/sonification/market/preprocess.py --ticker "$TICKER" --start "$START" --end "$END" --interval "1d" "$SPEC_FILE"
    ./zig-out/bin/example-market "$SPEC_FILE" "$RAW_FILE"
    python examples/sound_generation/to_wav.py --stereo "$RAW_FILE" "$WAV_FILE"
    python examples/sonification/market/animate.py "$CSV_FILE" "$WAV_FILE" "$MP4_FILE" "$NAME" "Historical"
}

# 1. The GME Short Squeeze (Dec 2020 - March 2021)
run_sonification "GME" "2020-12-01" "2021-04-01" "GME-Squeeze"

# 2. The 2008 Financial Crisis (S&P 500: Jan 2008 - Jan 2010)
run_sonification "^GSPC" "2008-01-01" "2010-01-01" "2008-Crash"

# 3. VIX Volatility Index (2020 COVID Crash)
run_sonification "^VIX" "2019-11-01" "2020-07-01" "COVID-VIX"
