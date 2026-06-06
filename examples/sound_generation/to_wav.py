import sys
import numpy as np
import argparse
from scipy.io import wavfile

parser = argparse.ArgumentParser()
parser.add_argument("--stereo", action="store_true")
parser.add_argument("in_path")
parser.add_argument("out_path")
args = parser.parse_args()

sample_rate = 48000

# Read raw f32 data
data = np.fromfile(args.in_path, dtype=np.float32)

if args.stereo:
    data = data.reshape(-1, 2)

# Save as WAV
wavfile.write(args.out_path, sample_rate, data)
print(f"Saved {args.out_path}")
