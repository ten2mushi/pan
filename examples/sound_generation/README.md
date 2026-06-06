# Pan Sound Generation Example

This directory contains examples of using the `pan` library for pure sound generation, producing audio entirely within a DSP graph and writing it out to disk.

## Overview

Unlike the feature extraction examples where `pan` generates structural data (matrices and JSON), sound generation focuses on using `pan` as a synthesizer engine. A typical generative graph looks like this:

`Generator(s) -> Effects/Mixers -> Sink`

In the provided example `sine_drone.zig`, we construct a graph with:
- `gen.Sine`: A band-limited sinusoid source.
- `gen.Lfo`: A low-frequency oscillator modulating the sine wave's frequency.
- `filters.Gain`: A simple gain block to scale the amplitude.
- A custom `MemSink` acting as a growable sink to collect the generated samples in memory.

### The Sound Generation Pipeline

To construct an offline audio generation pipeline:

1. **Initialize the Graph**: Create an instance of `pan.Graph` with the desired precision, channel count, block size, and sample rate.
2. **Add Nodes**: Use `g.add(Type, args)` to instantiate blocks like `pan.gen.Sine` and `pan.filters.Gain`. Wait for their `NodeHandle`.
3. **Connect Nodes**: Use `g.connect(producer, consumer)`. You can also connect to parameter ports, such as using an LFO to modulate frequency via `g.connect(lfo, osc.param.freq)`.
4. **Commit Analysis**: Call `g.commitAnalysis()` to freeze the graph. Realtime roots restrict dynamic allocations, so for writing to memory continuously, you must commit an offline batch root.
5. **Run to Completion**: Use `runToCompletion` with a `.wall_clock_timer` clock limit. You can specify `max_blocks` to restrict the generator length.
6. **Save Audio Data**: Extract the accumulated samples from your sink via `sink.instance().frames()` and write them to a raw LPCM file using `std.Io.Dir.cwd().writeFile`.

## Running the Example

1. **Compile the program:**
   Compile the sound generation example via the `zig build` target:
   ```sh
   zig build examples
   ```

2. **Generate the Raw Audio:**
   Run the resulting binary to produce 5 seconds of raw `.f32` (LPCM) audio.
   ```sh
   ./zig-out/bin/example-sine_drone examples/sound_generation/out.raw
   ```

3. **Convert to WAV:**
   Use the provided Python script to convert the raw floating-point data to a playable `.wav` file:
   ```sh
   python examples/sound_generation/to_wav.py examples/sound_generation/out.raw examples/sound_generation/out.wav
   ```

## Advanced Uses

To explore further with `pan`:
- Introduce envelopes like `env.Adsr` to shape dynamic notes.
- Explore polyphony using `synth.PolyVoice`.
- Experiment with `synth.EventLane` to trigger sample-accurate note events along a sequence track.
