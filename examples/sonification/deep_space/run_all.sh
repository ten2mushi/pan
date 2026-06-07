#!/bin/bash
set -e

# Directories
INPUT_DIR="data/input/hubble_pictures"
WORK_DIR="data/work"
OUT_BASE_DIR="data/output/sonification/deep_space"
RATE=48000  # must match SampleRate in deep_space.zig

# Create necessary directories
mkdir -p "$WORK_DIR"
mkdir -p "$OUT_BASE_DIR"

# Ensure zig graph is built
zig build examples

# Iterate over all images in the input directory
for IMG_PATH in "$INPUT_DIR"/*; do
    # Skip non-images
    if [[ "$IMG_PATH" == *.f32 ]] || [[ ! -f "$IMG_PATH" ]]; then
        continue
    fi
    
    BASENAME=$(basename "$IMG_PATH")
    NAME="${BASENAME%.*}"
    
    echo "Processing $BASENAME..."
    
    EXP_DIR="$OUT_BASE_DIR/$NAME"
    mkdir -p "$EXP_DIR"
    
    SPEC_FILE="$WORK_DIR/spectrogram_$NAME.f32"
    RAW_FILE="$WORK_DIR/out_$NAME.raw"
    WAV_FILE="$EXP_DIR/$NAME.wav"
    MP4_FILE="$EXP_DIR/$NAME.mp4"
    
    # 1. Preprocess
    python examples/sonification/deep_space/preprocess.py "$IMG_PATH" "$SPEC_FILE"
    
    # 2. Synthesize audio
    ./zig-out/bin/example-deep_space "$SPEC_FILE" "$RAW_FILE"
    
    # 3. Convert to WAV
    python examples/utils/to_wav.py --rate "$RATE" "$RAW_FILE" "$WAV_FILE"
    
    # 4. Generate Animation
    python examples/sonification/deep_space/animate.py "$IMG_PATH" "$WAV_FILE" "$MP4_FILE"
    
    echo "Done processing $BASENAME! Output saved to $MP4_FILE"
    echo "--------------------------------------------------------"
done
