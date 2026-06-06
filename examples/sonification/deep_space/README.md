# Deep Space Sonification Example

This directory contains an end-to-end sonification pipeline that translates a Hubble Space Telescope image into sound using the `pan` DSP engine. 

## The Concept

As described in the sonification rules:
- **Time flows left to right**: The X-axis of the image drives the progress of the audio over time.
- **Frequency from bottom to top**: The Y-axis represents frequency (approx. 30 Hz to 1,000 Hz).
- **Intensity maps to Amplitude**: The brightness of pixels (stars and galaxies) translates to the volume of the sound at that specific frequency bin.
- **Synthesis Engine**: Instead of an oscillator bank, this example leverages `pan.spectral.iStft` (Inverse Short-Time Fourier Transform). We feed columns of image pixel intensities directly as magnitudes into an FFT spectrum, applying a randomized phase per-bin to create the lush, diffuse texture characteristic of deep space.

## Pipeline Architecture

1. **Preprocessing (`preprocess.py`)**: 
   - Reads an input image (e.g., `data/input/hubble_pictures/5475_1.jpg`).
   - Converts it to grayscale and resizes it to a grid of `1000 x 83` (1000 time steps by 83 frequency bins, mapping perfectly to STFT bins spanning 30-1000 Hz).
   - Normalizes intensities and applies a non-linear scale so faint stars are audible.
   - Outputs a flat, column-major float32 array stored in a temporary working directory: `data/work/spectrogram_<image_name>.f32`.

2. **Sonification Engine (`deep_space.zig`)**:
   - A custom `pan` Rate block (`ImageSpectrumSource`) streams the preprocessed columns.
   - For every column, it populates a `pan.Spectrum(f32, 4096)` with the column's intensities mapped to magnitude, generating randomized phases for a diffuse sound.
   - The spectrum flows into `pan.spectral.iStft`, which reconstructs it back into raw LPCM samples.
   - The audio is collected via an offline `MemSink` and flushed to `data/work/out_<image_name>.raw`.

3. **Postprocessing (`to_wav.py`)**:
   - A simple python script converts the raw float32 payload into a playable `data/output/sonification/deep_space/<image_name>/<image_name>.wav` audio file.

4. **Animation Rendering (`animate.py`)**:
   - Combines the original image, the generated `.wav` file, and `ffmpeg` to create a sweeping scanline visualization `.mp4`.
   - Renders a continuous vertical waveform that accurately illustrates which frequency bins are being activated in the `pan` graph at any given millisecond.
   - The final video is saved to `data/output/sonification/deep_space/<image_name>/<image_name>.mp4`.

## Running the Example

Instead of running each step manually, we provide a unified batch script that processes all images in `data/input/hubble_pictures/` iteratively. It neatly stores intermediate arrays and audio in `data/work/` to avoid polluting the input directories.

1. **Execute the Batch Pipeline:**
   ```bash
   chmod +x examples/sonification/deep_space/run_all.sh
   ./examples/sonification/deep_space/run_all.sh
   ```

2. **View the Results:**
   Check the `data/output/sonification/deep_space/<image_name>/` directories for the resulting `.wav` and `.mp4` files.

The result is a dynamically evolving drone where bright clusters of galaxies create mid-range swells, and dense bottom-image stars create lower rumbles. You can watch the full timeline sweep in the output videos!
