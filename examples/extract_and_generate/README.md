# Extract & Generate (Ghost Autoencoder)

This example demonstrates how to combine the extraction and generation pipelines of `pan` into a single, cohesive DSP graph. 

## The Concept

We process an input audio file by passing it through an "autoencoder" bottleneck:
1. **Analysis / Compression**: The graph analyzes the audio into 10 key features (Dominant pitch, amplitude, centroid, rolloff, flux, flatness, and contrast) per time step. The original audio data is discarded; only the 10-dimensional feature "latent space" vector remains.
2. **Synthesis / Decompression**: A custom `GhostResynthesizer` node takes this 10-dimensional vector and synthesizes a new magnitude spectrum from scratch. It builds a synthetic tone at the dominant frequency, layers in broadband noise controlled by the flatness and centroid features, and scales everything by the dynamic amplitude envelope.
3. **iSTFT**: The synthetic spectrum is passed through the Inverse Short-Time Fourier Transform (`iStft`), creating a continuous "ghostly" shadow of the original audio.

## Running the Example

A convenience shell script is provided to handle decoding the audio to raw float32 samples, building the Zig project, running the graph, and muxing the output back to a playable `.wav` file.

```bash
chmod +x examples/extract_and_generate/run_autoencoder.sh
./examples/extract_and_generate/run_autoencoder.sh "data/input/Karenn - On Request/Karenn - On Request_lpcm.wav"
```

The resulting audio file will be placed in `data/output/sonification/extract_and_generate/`. Listen to it—you will hear the ghost!
