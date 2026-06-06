#!/usr/bin/env bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PAN_ROOT="$( cd "$DIR/../.." && pwd )"

# Check if an input file was provided
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <path_to_input_audio>"
    echo "Example: $0 \"data/input/Andesana  Anna-Maria Hefele  polyphonic overtone singing/Andesana_lpcm.wav\""
    exit 1
fi

INPUT_AUDIO="$1"

# We must ensure the input is exactly 44.1kHz mono f32 LPCM, which it should be if it's already decoded.
# If not, the python script from other examples uses librosa to do it. Here we assume the user provides
# a `_lpcm.wav` file or similar raw file. But actually, `pan` expects raw `f32` samples if we use `LpcmSource(Num)`.
# Wait, `pan.io.LpcmSource(Num)` reads raw native-endian `f32` samples, NOT a WAV header!
# So we need to strip the WAV header if it's a WAV, or decode it properly.
# The analyzer script normally expects `<input.f32>`.
# Let's decode it using ffmpeg to a temporary .f32 file.

BASENAME=$(basename "$INPUT_AUDIO" | sed 's/\.[^.]*$//')
OUT_DIR="$PAN_ROOT/data/output/sonification/extract_and_generate"
mkdir -p "$OUT_DIR"
mkdir -p "$PAN_ROOT/data/work"

TEMP_RAW="$PAN_ROOT/data/work/${BASENAME}.f32"
OUT_RAW="$PAN_ROOT/data/work/${BASENAME}_ghost.raw"
OUT_WAV="$OUT_DIR/${BASENAME}_ghost.wav"

echo "1. Decoding input to raw f32..."
ffmpeg -y -i "$INPUT_AUDIO" -f f32le -acodec pcm_f32le -ar 44100 -ac 1 "$TEMP_RAW" -loglevel warning

echo "2. Building pan example..."
cd "$PAN_ROOT"
zig build examples

echo "3. Running Ghost Autoencoder DSP pipeline..."
./zig-out/bin/example-ghost_autoencoder "$TEMP_RAW" "$OUT_RAW"

echo "4. Muxing to WAV..."
ffmpeg -y -f f32le -ar 44100 -ac 1 -i "$OUT_RAW" "$OUT_WAV" -loglevel warning

echo "Done! The ghost audio is ready at:"
echo "$OUT_WAV"
