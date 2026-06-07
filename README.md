# pan

A graph DSP engine for audio — **extraction + generation** — built in Zig for
**real-time processing down to bare metal**. One comptime-committed signal graph
runs unchanged across desktop (CoreAudio / ALSA), offline batch, static-parallel
realtime, and a freestanding fixed-point MCU target. Developed and tested on Apple
M3 (macOS, aarch64); cross-checked for x86_64-linux.

- **Comptime graph, static plan.** You build a graph of typed nodes; a commit pass
  colors buffers, sizes a single pool, inserts latency compensation, and emits a
  flat op-list — all at comptime where possible. No allocation, no vtables, no locks
  on the audio thread.
- **Typed ports.** Edges carry `Sample`, `Frame(C)`, `Complex`, `FeatureFrame`,
  `Scalar`, … . Type mismatch is a build error; layout coercions (up/down-mix,
  format) are auto-inserted from registered canonical matrices.
- **One numeric trait, many precisions.** Every node is monomorphized over a
  `Numeric` (f32/f64 float or q7/q15/q31/q63 saturating fixed-point, with a comptime
  SIMD width). The MCU build is the *same* nodes at q15, not a fork.
- **Correctness by differential test.** Float lanes are checked against independent
  NumPy/SciPy oracles; every pan-vs-pan equivalence (parallel ≡ sequential, colored
  pool ≡ per-edge, offline ≡ realtime, codec round-trip) is **bit-exact**.

> Run `zig build test` to verify locally.

## Demo

pan does both halves of the audio loop — one worked example of each. Click to play.

### Extraction — audio → features → animation (`examples/animation`)

pan extracts per-frame features; WebGL draws the feature point cloud (source audio muxed in).

<table>
<tr>
<td width="50%" align="center">

**Integraation — *constellation***

[![Integraation — constellation](https://img.youtube.com/vi/WyNFXqvc3O4/hqdefault.jpg)](https://youtu.be/WyNFXqvc3O4)

▶ [click to play on YouTube](https://youtu.be/WyNFXqvc3O4)

</td>
<td width="50%" align="center">

**Pachelbel — *feature-space***

[![Pachelbel — feature-space](https://img.youtube.com/vi/xArB1-nS6wM/hqdefault.jpg)](https://youtu.be/xArB1-nS6wM)

▶ [click to play on YouTube](https://youtu.be/xArB1-nS6wM)

</td>
</tr>
</table>

### Generation — data → audio → animation (`examples/sonification`)

pan *synthesises* audio from non-audio data (`iStft` resynthesis / event-driven
synthesis), then animates the result.

<table>
<tr>
<td width="50%" align="center">

**Deep space — telescope image → sound**

[![Deep space sonification](https://img.youtube.com/vi/etNRvP-XFyo/hqdefault.jpg)](https://youtu.be/etNRvP-XFyo)

▶ [click to play on YouTube](https://youtu.be/etNRvP-XFyo)

image pixels → STFT magnitudes → `iStft` (randomized phase)

</td>
<td width="50%" align="center">

**Market — COVID-era VIX → sound**

[![Market sonification](https://img.youtube.com/vi/2udI5hZl050/hqdefault.jpg)](https://youtu.be/2udI5hZl050)

▶ [click to play on YouTube](https://youtu.be/2udI5hZl050)

financial time series → events → synthesis

</td>
</tr>
</table>

---

## Requirements

- **Zig 0.16.0** (exact — the language moves; this is pinned in `build.zig.zon`).
- macOS or Linux for the desktop device backends. The library core and offline
  paths are platform-agnostic; the embedded profile is freestanding.
- Python 3 + NumPy (`.venv` provided) for the oracle-backed gold-vector tests and
  the examples.
- `ffmpeg` and a headless Chrome/Chromium on `PATH` for the animation example's
  video capture.

## Install / build

```sh
git clone https://github.com/ten2mushi/pan](https://github.com/ten2mushi/pan.git && cd pan
zig build                 # build the library + CLI
zig build run             # build and run the pan CLI
```

There are no external Zig dependencies (`.dependencies = .{}`); the FFT, resamplers,
filters, and codecs are all from-scratch in-tree.

## Test

```sh
zig build test            # unit + integration tests (Debug + ReleaseSafe) + smoke gate
zig build fmt-check       # formatting CI gate
zig build smoke           # freestanding ReleaseSmall comptime-commit gate
zig build neg-compile     # assert the expected @compileError negatives actually fire
zig build cross-linux     # cross-compile to x86_64-linux-gnu (ALSA seam gate)
zig build bench           # benchmarks (ReleaseFast)
zig build bench-vdsp      # pan-vs-Apple-vDSP yardstick (macOS)
zig build docs            # API documentation
```

The build matrix (Debug / ReleaseSafe / ReleaseFast / ReleaseSmall-freestanding) is
the discharge surface for correctness: asserts + NaN guards on in Debug/ReleaseSafe,
stripped in ReleaseFast (hot-path codegen), comptime-commit smoke in ReleaseSmall.
**Trust the exit code, not the printed test count** — a target that fails to compile
silently drops its tests.

## Run the animation example

The flagship example turns a recording into an audio-reactive 3-D point-cloud video,
using pan for all feature extraction and WebGL for rendering:

```sh
python examples/animation/render.py --list                 # all experiments
python examples/animation/render.py andesana_helix          # render one (decode→analyze→capture→stamp)
python examples/animation/render.py incea_constellation --seconds 20   # quick preview
```

It writes a self-describing folder under `data/output/animation/ideation/<EXPERIMENT>/`
(mp4 with audio muxed, a `_description.md`, and the fully-resolved `config.json`).
Add an input by dropping a file in `data/input/` and one line in `experiments.py`.
See `examples/animation/README.md` for modes and the pipeline.

## Run the sonification (generation) example

The generation counterpart synthesises audio from non-audio data and animates it:

```sh
bash examples/sonification/deep_space/run_all.sh   # telescope image → STFT magnitudes → iStft → sound
bash examples/sonification/market/run_all.sh       # financial time series → events → synthesis
```

Each writes its render under `data/output/sonification/<example>/<item>/` (`.wav` +
muxed `.mp4`). See the per-example `README.md` for the pipeline. The remaining example,
`examples/spectrogram`, renders a high-res STFT spectrogram PNG.

---

## Architecture

### Module layers

Three strictly-layered Zig modules, plus an umbrella. **Type identity** is shared by
wiring one `pan_core` object into all three, so `pan.Sample` and a dsp-side `Sample`
are the *same* type.

```
pan_core  ←  pan_dsp  ←  pan_io          (← = "depends on / imports")
   └────────── pan (umbrella: src/root.zig — re-exports the public surface) ───────┘
```

| module | root | contents |
|---|---|---|
| **`pan_core`** (`src/core/`) | `core.zig` | DSP-agnostic engine: numeric trait, typed ports, graph IR + builder, commit/coloring/PDC, the Tier-A/B/C executors, fusion, combinators, control plane (RCU, lock-free rings), layout/resample/backend primitives. Imports nothing downstream. |
| **`pan_dsp`** (`src/dsp/`) | `dsp.zig` | The node libraries, in per-pipeline subdirs: `generation/`, `synth/`, `filter/`, `effect/`, `spatial/`, `spectral/`, `analysis/`, `time/`. Reaches core *by symbol* via `@import("pan_core")`. |
| **`pan_io`** (`src/io/`) | `io.zig` | Platform boundary: LPCM codecs, device backends (CoreAudio/ALSA), the I2S-DMA embedded transport, file/sample/prefetch sources, the feature-matrix sink. |

`src/root.zig` (umbrella), `src/main.zig` (CLI), and `src/smoke_freestanding.zig`
stay at `src/` top. Each module has its **own** test step, so a module root must
transitively reference every member file or that file's `test {}` blocks orphan.

### Execution tiers

The same committed graph runs under several executors, each proven bit-exact to the
ground truth:

- **Tier A** — the wait-free pull executor: monomorphized over the committed graph +
  node-block tuple. The realtime ground truth; no allocation, no locks.
- **Tier B** (`parallel.zig`) — static-parallel realtime overlay: worker pool +
  render-workgroup HAL, op-DAG with HEFT scheduling, cost-gated and **auto-demoting**
  to Tier A under load. Bit-identical output. (Currently gated on for macOS; off on
  Linux pending on-device soak.)
- **Tier C** (`offline.zig`) — `OfflineBatch`: off-deadline render, sequential /
  data-parallel chunked (warmup lead-in + ordered merge) / pipelined stage-per-thread
  over `Ring`s. For throughput, not latency.
- **Embedded** (`root.embedded`) — the whole graph commits at comptime to a q15
  chain; `footprint_bytes` is a comptime constant usable as a `.bss` array length;
  the render entry is the I2S DMA half-/transfer-complete ISR. No `SampleMux` fat
  pointer, no vtable.

`pan.render(...)` is the unified façade that routes by intent (`.realtime` → Tier A,
`.offline` → Tier C).

### Control plane

Parameters change on the audio thread wait-free: an atomic `Param` + per-block `Ramp`
(anti-zipper "ramp, never step"), an SPSC `CommandRing` for scheduled edits, and an
`Rcu` cell for whole-plan hot-swap. Events (e.g. `NoteEvent`) reach a node **out of
band** through the engine's per-node store — the static op-list stays pure.

---

## Block (node) model

A node is a plain struct monomorphized over a `Numeric`. Its **class** is inferred
*structurally* from what it declares — there is no base class to inherit:

| class | declares | meaning |
|---|---|---|
| **Map** | `process(self, in…, out…)` | rate-1:1; `out.len == in.len`. The default. |
| **Rate** | `out_per_in` + `pull` + `algorithmic_latency` | fixed non-1:1 rate (STFT framing, decimation, resampling). |
| **VariRate** | `rate_bounds` + `max_latency` + `pull` | runtime-variable ratio (varispeed, drift-ASRC, time-stretch). |

- **Ports** are read from the `process` signature: each `[]const Sample(T)` param is
  an input port, each `[]Sample(T)` an output. A block with **zero** input ports is a
  **Source** (oscillator, file reader) — not a separate class, just an empty input
  side.
- **Parameter ports** (`node.param.cutoff`, …) are control inputs an LFO/envelope/
  feature drives; `param.*` writes are bit-exact to a direct `set`.
- `pub const aliasing_safe = true;` lets the colorer run the block **in place**
  (output edge aliased onto the input buffer) — declare it only when each output
  element is written solely from the corresponding input element.
- **Named fan-in** uses `combinators.Concat(.{ .a = T1, .b = T2 })`, minting one typed
  port per field (`node.in.a`); **channel replication** uses `ChannelMap`.

### Quick start

```zig
const pan = @import("pan");
const Num = pan.numericFor(.f32, .{});

var g = pan.Graph.init(allocator, .{ .precision = .f32, .channels = .mono, .block_size = 512 });
defer g.deinit();

const src  = try g.add(pan.io.LpcmSource(Num), .{ .data = samples, .loop = false });
const filt = try g.add(pan.filters.Biquad(Num), .{ /* coeffs */ });
const lfo  = try g.add(pan.Lfo(Num), .{ .hz = 2.0 });
const sink = try g.add(pan.io.FeatureCollectorSink(Row), .{});

try g.connect(src, filt);            // sample edge
try g.connect(lfo, filt.param.cutoff); // control edge into a parameter port
try g.connect(filt, sink);

var eng = try g.commit();            // colors buffers, sizes the pool, builds the op-list
defer eng.deinit();
// drive eng from a device callback (realtime) or eng.runToCompletion (offline/analysis)
```

---

## Adding a new node

1. **Pick the family file** under `src/dsp/<pipeline>/`. Effects go in
   `effect/fx_*.zig`, spectral blocks in `spectral/spectral_*.zig`, analysis blocks
   in `analysis/feat_*.zig`, etc. (The aggregators `fx.zig` / `spectral.zig` /
   `feat.zig` are thin re-export hubs over their `*_<family>.zig` files.)

2. **Write the block** as a `fn Name(comptime num: Numeric) type { return struct { … }; }`.
   Give it a `process` (Map) or `out_per_in`/`pull`/`algorithmic_latency` (Rate) or
   `rate_bounds`/`max_latency`/`pull` (VariRate). The required signatures:

   ```zig
   // Map (rate-1:1)
   pub fn process(self: *Self, in: []const Sample(T), out: []Sample(T)) void
   // Source (zero input ports)
   pub fn process(self: *Self, out: []Sample(T)) void
   // Parameter port: expose `param: struct { cutoff: ... }` and a setParam, or use
   // the control.Param helpers — wired via `connect(ctrl, node.param.cutoff)`.
   ```

   Declare `pub const aliasing_safe = true;` only if it is truly element-local.

3. **Re-export** the new type from the family aggregator and, if it belongs on the
   public surface, add a `pub const Name = family.Name;` line to `src/root.zig`.

4. **Reference it from the module root** (transitively) or its `test {}` blocks
   orphan — `refAllDecls` in `dsp.zig` covers re-exported decls.

5. **Test against an independent oracle**, never against pan's own output. Float
   lanes: `numpy.allclose` to a NumPy/SciPy reference. Integer/fixed lanes and any
   pan-vs-pan equivalence (parallel ≡ sequential, colored pool ≡ per-edge, codec
   round-trip): **bit-exact**. Test names encode the gate they discharge.

### Conventions

- **Run `zig build test` + `zig build fmt-check` before pushing.** Trust the exit
  code, not the printed test count.

---

## Repository map

```
src/            the library — core/ (engine), dsp/ (nodes), io/ (boundary)
build.zig       all build steps (test, fmt-check, smoke, neg-compile, cross-linux, bench, examples, docs)
tests/          oracle-backed + differential test suites; tests/vectors (gold), tests/negative (@compileError stubs)
examples/       animation (WebGL audio-reactive video), sonification, spectrogram
bench/          benchmarks + baselines (incl. the vDSP yardstick)
scripts/        audio→LPCM decoders and helpers
data/           input/ work/ output/ (gitignored audio + renders)
```
