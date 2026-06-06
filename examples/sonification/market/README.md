# Financial Market Data Sonification (Synthwave Techno)

This directory contains a complete, end-to-end sonification pipeline that translates financial market data (tick data) into a "Synthwave/Dark Techno" musical composition using the `pan` DSP engine. 

## The Concept

We map historical financial market data to audio synthesis parameters to create a dynamic, evolving piece of music. The "music of capitalism" uses the following mappings:

- **Time flows left to right**: Each tick (e.g. 1 day of BTC-USD data) drives the progress of the audio over time.
- **Price -> Pitch**: The normalized price is mapped to a musical scale (Minor Pentatonic) to drive the fundamental frequency of a dark bass drone (`PolyBlepSaw`).
- **Volatility -> Timbre (Cutoff)**: The volatility (High - Low price) modulates the cutoff frequency of a `StateVariable` lowpass filter. High volatility opens the filter, making the synth harsher and brighter.
- **Volume -> Rhythmic Plucks**: High trading volume spikes trigger an FM-synthesized polyphonic pluck. The volume magnitude determines the envelope intensity, creating percussive techno accents during intense trading periods.
- **Atmosphere**: The entire mix is routed through a massive `Comb` filter reverb network (`SpaceReverb`), giving the composition a cavernous, echoing aesthetic.

## Pipeline Architecture

1. **Preprocessing (`preprocess.py`)**: 
   - Uses the `yfinance` library to download historical market data.
   - Extracts Close Price, Volume, and Volatility.
   - Normalizes and interleaves the features into a single flat `.f32` array for the `pan` engine.
   - Saves a `.csv` file with the dates and prices for the animation step.

2. **Sonification Engine (`market.zig`)**:
   - A custom `pan` Source block (`MarketSynth`) streams the preprocessed `.f32` data.
   - Each tick is expanded over 4 audio blocks (at 1024 samples per block), meaning each tick lasts ~85ms (about 11.7 ticks per second).
   - Generates the FM plucks, the bass drone, and the reverb.
   - The raw audio is output to `data/work/out_market_<ticker>.raw`.

3. **Postprocessing (`to_wav.py`)**:
   - Converts the raw float32 payload into a playable `.wav` file.

4. **Animation Rendering (`animate.py`)**:
   - Uses `matplotlib` to render a synthwave-style neon financial chart with a scrolling playhead.
   - Pipes the rendered frames directly to `ffmpeg` and multiplexes them with the generated `.wav` audio.
   - Outputs the final video to `data/output/sonification/market/<ticker>/<ticker>.mp4`.

## Running the Example

We provide a unified batch script that sets up the environment, fetches the data, and runs the entire pipeline automatically. By default, it fetches the last 2 years of daily data for `BTC-USD`.

```bash
# From the project root:
chmod +x examples/sonification/market/run_all.sh
./examples/sonification/market/run_all.sh
```

**Customizing:**
You can modify `TICKER`, `PERIOD`, and `INTERVAL` directly inside `run_all.sh` to sonify different assets (e.g., `^GSPC` for the S&P 500, `NVDA` for NVIDIA stock).

### Requirements
The pipeline uses a self-contained Python virtual environment (`.venv`) initialized by the run script. It relies on `ffmpeg` being installed on your system to generate the final `.mp4` video.
