# 10: Real-Time Pipeline Analysis — Rate Propagation, EOS, Buffering, Latency, and Underrun Behavior

This document synthesizes the mechanisms across flowgraph, ring, sample_mux, and runners into an end-to-end picture of **how ZigRadio achieves (soft) real-time behavior** for SDR/DSP workloads.

## 1. The Pipeline is Source-Driven + Rate-Propagated

Sources define the fundamental rate. Everything downstream derives from it, with transformations at rate-changing blocks.

**setRate contract (block + flowgraph):**

In Block:

```zig
pub fn setRate(self: *Block, rate: f64) !void {
    self.rate = if (self.set_rate_fn) |set_rate_fn| try set_rate_fn(self, rate) else rate;
}
```

In Flowgraph._propagateRates (verbatim):

```zig
pub fn _propagateRates(self: *Flowgraph, evaluation_order: *const std.AutoArrayHashMap(*Block, void)) !void {
    for (evaluation_order.keys()) |block| {
        const upstream_rate = if (block.inputs.len > 0) self.flattened_connections.get(BlockInputPort{ .block = block, .index = 0 }).?.block.getRate(f64) else 0;
        try block.setRate(upstream_rate);

        // All other inputs must match exactly (after their own transforms? No — the check is after setRate on the first)
        var i: usize = 1;
        while (i < block.inputs.len) : (i += 1) {
            const rate = self.flattened_connections.get(BlockInputPort{ .block = block, .index = i }).?.block.getRate(f64);
            if (rate != upstream_rate) return FlowgraphError.RateMismatch;
        }
    }
}
```

Note: the check uses the *already propagated* rate from the upstream block's perspective. For a block with multiple inputs (e.g. Add), all upstreams must have produced the same rate after their setRate calls (which for passthrough blocks is identity).

**Example rate transform** — verbatim from `DownsamplerBlock(comptime T: type)` in `src/blocks/signal/downsampler.zig:37` (`Self` is the generated struct):

```zig
pub fn setRate(self: *Self, upstream_rate: f64) !f64 {
    return upstream_rate / @as(f64, @floatFromInt(self.factor));
}
```

LowpassFilter etc. are usually passthrough (return upstream_rate unchanged) unless they internally resample.

This happens once, at `start()` time, in evaluation order (topological). After that, rates are immutable on the Block structs and used for debug printing and some block initialize logic (e.g. filter design uses `self.block.getRate(f32)` to compute nyquist).

## 2. SampleMux.wait — The "How Much Work Can I Do Right Now?" Gate

The key to keeping the pipeline full without busy-wait or massive overproduction is in SampleMux.wait (verbatim from sample_mux.zig):

```zig
pub fn wait(self: SampleMux, comptime type_signature: ComptimeTypeSignature, timeout_ns: ?u64) error{ Timeout, EndOfStream, BrokenStream }!usize {
    const input_element_sizes = comptime util.dataTypeSizes(type_signature.inputs);
    ...
    while (min_samples_available == 0) {
        // Query all ports (bytes -> samples)
        inline for (...) |input_type, i| {
            input_samples_available[i] = try self.vtable.getInputAvailable(...) / @sizeOf(...);
        }
        ... same for outputs

        const min_input_samples = ... indexOfMin ...
        const min_output_samples = ...

        if (inputs and min_input == 0) {
            try self.vtable.waitInputAvailable(..., min_input_samples_index, input_element_sizes[...], timeout_ns);
        } else if (outputs and min_output == 0) {
            try self.vtable.waitOutputAvailable(...);
        } else {
            min_samples_available = if (no inputs) min_output else if (no outputs) min_input else @min(min_input, min_output);
        }
    }
    return min_samples_available;
}
```

Then `get` uses that min to slice the buffers:

```zig
const min_samples_available = self.wait(...) catch |err| switch... ;
...
inline for inputs ... {
    ... bytesAsSlice( input_type, buffer[0 .. min_samples_available * @sizeOf ] )
}
```

**Why this is brilliant for realtime:**
- A block with 2 inputs and 1 output will only be given the *minimum* across (input1 available, input2 available, output space available).
- This prevents a fast input from causing the block to produce more than the downstream can accept (backpressure via output space).
- It also prevents processing a partial set when one input is starved (important for multi-input blocks like adders, PLLs with reference, stereo, etc.).
- The wait is blocking with timeout option (used in some tests).

In the threaded runner, this wait is what parks the thread when the pipeline has a bottleneck.

## 3. EOS and BrokenStream as First-Class Pipeline Control Signals

There are two "normal" termination signals that travel through the exact same SampleMux / ring machinery as data:

- `EndOfStream` (returned by a `Reader` when `read_eos` is set on the ring and no more data is available). Note the flag is named `read_eos` even though it signals *the writer is done*; it is set via `Writer.setEOS()` → `setReadEOS()`.
- `BrokenStream` (returned by a `Writer` when `write_eos` is set on the ring). This flag is set via `Reader.setEOS()` → `setWriteEOS()`.

When any block runner's thread exits (the `Runner.run` loop in `ThreadedBlockRunner.spawn`), it calls `sample_mux.setEOS()` exactly once. `ThreadSafeRingBufferSampleMux.setEOS` (sample_mux.zig:217) does both directions at once:
- For every **output** ring (its writers), it calls `Writer.setEOS()`, setting `read_eos` so downstream readers see `EndOfStream`.
- For every **input** ring (its readers), it calls `Reader.setEOS()`, setting `write_eos` so the upstream writer sees `BrokenStream`.

In practice:
- A source returning `ProcessResult.EOS` or exhausting (the `process_result.eos` branch in `Runner.run`) breaks the loop, then `setEOS()` marks its output ring's `read_eos`, so all downstream readers eventually see `EndOfStream` on their get/wait.
- A sink (or any block) erroring breaks the loop with `process_error` set, then `setEOS()` marks its input ring's `write_eos`, so the upstream writer sees `BrokenStream` on its next getAvailable / wait.

The runner treats `error.EndOfStream` from `block.process` as a clean exit for that thread (`runner.zig:98`, `error.EndOfStream => break`); any other error is recorded in `process_error` and also breaks. `BrokenStream` surfaces to an upstream block as a process error, which is why an erroring sink causes the whole chain to collapse with `error.BrokenStream` (see the "Flowgraph collapses on error" test: source and inverter both report `error.BrokenStream`, sink reports `error.Unexpected`).

This is how `top.stop()` (which only calls `stop()` on source blocks — those with `inputs.len == 0`) cleanly shuts down the entire DAG without races or leaked threads: a stopped source sets EOS, which propagates downstream as `EndOfStream`, draining each block in turn.

## 4. Buffering and Latency Math

**Per-link buffer:** `RING_BUFFER_SIZE = 8 * 1048576` = 8 MiB *capacity* (flowgraph.zig:117). The ring's backing memory is double-mapped (`MappedMemoryImpl` maps `2 * capacity` of address space so wrapped reads/writes see a contiguous slice), so the *virtual address space* per ring is 16 MiB, but the usable capacity is 8 MiB. `getWriteAvailable` reports `capacity - 1` when empty (the `-1` is the classic full/empty distinction).

For a 2 MS/s complex float link (IQ from RTL at 2.4MS/s downconverted):
- 8 bytes/sample → ~ 1,048,576 samples of capacity (8 MiB / 8 bytes).
- At 2 MS/s that's ~524 ms of buffering per link.

For an audio-rate link after downsampling (48 kHz f32, 4 bytes):
- ~ 2 million samples (8 MiB / 4 bytes) → ~44 seconds of buffer.

**Pipeline latency components:**
1. **Ring buffering latency** — samples sit in the ring until the consumer thread wakes and drains some. Worst case roughly the time to fill the "give me work" threshold of the downstream block.
2. **Per-block processing latency** — e.g. 128-tap FIR has group delay of ~64 samples + the block's own buffering if it does block processing.
3. **Thread scheduling / wakeup latency** — condvar + OS scheduler. On a loaded system this can be 100us–few ms.
4. **USB / hardware transfer latency** (for sources like rtlsdr) — the source block does sync reads of MIN_BLOCK_SIZE (8k in rtlsdr) or whatever the device delivers.

Because rings are large, a temporary slowdown in one block (GC pause? No, but a priority inversion, or a burst of USB traffic) can be absorbed without immediate underrun downstream, as long as the average rates match and the slow block catches up before its upstream ring fills.

**Underrun behavior:**
- If a consumer asks for more than is available in its input ring when the producer has not kept up, `getAvailable` / wait will block (or timeout if specified).
- In the standard model, the consumer thread simply parks until data arrives. The "audio sink" or "pulse" will see its input starve if the whole upstream chain can't keep the ring non-empty.
- There is no "drop samples" or "insert zeros" policy in the core; individual sinks (PulseAudioSink) may have their own strategies when they can't get data in time for the next callback.

The design assumes that with ReleaseFast, reasonable CPU, and properly sized rings, the pipeline stays "full enough".

## 5. Multi-Rate and Rational Resampling Considerations

Downsamplers / upsamplers change the *logical* rate, but the ring still moves bytes. The SampleMux works in *samples* (after dividing by element size), so the produced/consumed counts in ProcessResult must be consistent with the rate change.

Example for a 4x downsampler:
- It might consume 4*N input samples to produce N output samples in one process call.
- Its setRate returns rate/4.
- Downstream blocks see the lower rate for their own calculations (e.g. filter cutoff design).

The framework does **not** automatically insert resamplers; the user wires the rate-changing blocks explicitly. The validation only checks that at any multi-input block, the *rates after setRate* match on all inputs.

This keeps the core simple.

## 6. Threading Model Impact on Realtime

One thread per block (standard mode):
- Pros: trivial parallelism, simple block code (just implement process), natural backpressure per edge.
- Cons: N context switches per "wave" of data through the graph, mutex per block for call() serialization, condvar wakeups.

For a typical WBFM receiver graph (source → translator → filter → downsample → demod → af filter → deemph → downsample → sink) that's ~9 threads.

On modern hardware this is fine; the DSP work per block usually dominates the scheduling cost.

Raw mode blocks can collapse several logical operations into one thread if the author wants (by doing the sub-processing inside the raw `start` loop, manually driving multiple sample_mux ports). Note that a `RawBlockRunner` does **not** spawn a framework thread — `spawn()` simply calls the block's own `start(sample_mux)`, and the block is responsible for its own threading/looping. Consequently `RawBlockRunner.getError()` always returns `null` (runner.zig:48), so raw blocks cannot report process errors back to the flowgraph the way threaded blocks do via `process_error`. A raw block signals completion by calling `sample_mux.setEOS()` itself (e.g. in its `stop()`).

## 7. Observed Patterns in Real Examples (rtlsdr_wbfm_mono etc.)

From the actual `examples/rtlsdr_wbfm_mono.zig` top-level wiring:
- `RtlSdrSource.init(frequency - 250e3, 960000, ...)` — 960 kS/s complex (`Complex(f32)`, 8 bytes/sample).
- `TunerBlock.init(-250e3, 200e3, 4)` — a **composite** that internally chains a frequency translator + lowpass filter + `Downsampler(4)`, so it divides the rate by 4 (960k → 240k). It flattens to its constituent blocks at connect time.
- `FrequencyDiscriminatorBlock.init(75e3)` — FM discriminator at 240 kS/s.
- `LowpassFilterBlock(f32, 128).init(15e3, .{})` — the AF lowpass with `N=128` taps.
- `FMDeemphasisFilterBlock.init(75e-6)`.
- `DownsamplerBlock(f32).init(5)` — 240k / 5 = 48 kS/s audio.
- `PulseAudioSink(1)`.

(The top-level program issues 6 `connect` calls, but because `TunerBlock` is a composite the flattened graph — and thus the thread count — is larger than 7.)

Each ring between high-rate blocks is still the full 8 MiB capacity, which at 960k complex (8 bytes/sample → ~1.05M samples) is ~1.1 seconds — plenty of slop for USB scheduling jitter on the source side.

The final audio rings are huge in time (seconds), which is good because PulseAudio will pull at its own cadence.

## 8. Failure Modes and Mitigations

- **CPU starvation:** A block's process takes longer on average than the sample arrival interval → rings fill upstream, eventual writer blocks or (if source is hardware) device buffer overflow (underrun on the radio side).
- **Priority inversion:** UI thread or logging thread starves a DSP thread → glitch. User responsibility (set realtime scheduling, CPU affinity, nice values).
- **Memory pressure:** 8MB * number of output ports can be 100+ MB for a big graph. Acceptable on desktops, tight on embedded.
- **EOS races:** Handled by the setEOS + error returns + runner unwind. Tests cover partial data + EOS, write-EOS while reader waiting, etc.

## 9. Comparison to "Classic" GNU Radio Scheduler (Brief)

GNU Radio has:
- A single (or hierarchical) scheduler thread that decides runnable blocks.
- More sophisticated "buffer readers/writers" with history, tags, etc.
- Options for "single threaded" or "thread per block" (tpb) scheduler.
- Explicit "noutput_items" forecasting.

ZigRadio is closer to the "tpb" idea but simpler: every block always has its own thread, and "how many items" is purely determined at runtime by min(available in, available out space) rather than block forecasting.

The ZigRadio approach wins on implementation simplicity and "the block code looks like normal DSP". The GNU Radio approach can achieve lower latency and better single-core efficiency in some cases, at the cost of much more complex core scheduler code.

## 10. Summary: Why It Feels "Real Time"

- Large fixed per-edge buffers give statistical headroom.
- Blocking condvar waits mean zero CPU when idle (no polling).
- Contiguous aliased views mean efficient work once awake.
- Source-driven + explicit rate transforms + validation prevent rate mismatch disasters.
- EOS as a dataflow signal gives clean, decentralized shutdown.
- Explicit initialize + no hot-path allocs → predictable memory and no jitter from malloc.
- The whole thing is "pull from the back, push from the front" with backpressure, which is the natural way rings + blocking readers/writers work.

For the class of applications (RTL-SDR receivers, tone generators, file-based offline processing turned realtime, audio chains), this has proven sufficient, as evidenced by the working examples and the benchmark infrastructure that runs full graphs for seconds and reports sustained MS/s.

If you need hard realtime or sub-millisecond latency across many hops, you would probably use raw mode for critical sections + external scheduling + CPU pinning + possibly a different buffer strategy. The architecture gives you the hooks.
