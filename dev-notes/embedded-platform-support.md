# Dev-note: adding support for a new embedded (or desktop) platform

A primer for pan contributors. How the platform-portability layer is shaped, and the
concrete steps to bring pan up on (A) a new desktop-class audio OS backend, or
(B) a new bare-metal MCU. Grounded in the code as of P10.

---

## 0. The one idea to internalize first

> **The embedded build is a *comptime specialization* of the desktop core, not a
> fork.** Every desktop "runtime degree of freedom" collapses to comptime or
> vanishes on an MCU. You author a block (`Gain`, `Biquad`) once; it runs in a
> CoreAudio callback, an ALSA thread, or an STM32 DMA ISR unchanged.

What collapses on embedded (`pan_architecture_formalisation.md §7`):

| Desktop | Embedded |
|---|---|
| runtime block size `N` | **comptime** `N` (half the DMA buffer) — no scalar tail, full unrolling |
| runtime commit + RCU plan swap | **comptime** `commitComptime`; topology is fixed; no epochs |
| `SampleMux` fat pointer (vtable) | a concrete comptime type — the render monomorphizes/inlines, **no vtable** |
| `Numeric{f32,…}` | `Numeric{i16, i32, saturate=true, W}` (q15, no FPU) |
| heap allocator | static `.bss`; no heap |
| FTZ realtime token (real) | no-op token (no FPU) — **same API shape** |
| Tiers B/C (multicore/offline) | do not exist (single core) |

So adding a platform is mostly: implement the **two HALs** for it, and (for an MCU)
wire the comptime render path to the device's interrupt.

---

## 1. The two HALs (don't conflate them)

`pan_io_realtime_and_pipeline.md §11`:

- **Compute HAL** — portable vectorized kernels. `src/simd.zig` writes everything as
  `@Vector(W, T)` with a scalar tail; the Zig compiler lowers it to NEON (M3),
  AVX2/AVX-512 (x86), Helium (Cortex-M55), or scalarizes (correct, just not faster)
  when the target has no vector unit (then `W == 1`). **You usually do nothing here**
  — a new target gets vectorization for free. `W` comes from the Numeric trait
  (`numeric.widthFor`, which is `std.simd.suggestVectorLength(Lane) orelse 1`). An
  optional runtime-discovered accel slot (vDSP/FFTW/CMSIS-DSP, chiefly FFT) layers
  *above* this and is never a dependency of the core.
- **I/O HAL** — device transport. This is the part you implement per platform. Two
  shapes: a desktop **`io.AudioBackend`** vtable (callback-driven), or the embedded
  **I2S-DMA ISR** (the interrupt *is* the callback).

---

## 2. Scenario A — a new desktop-class OS backend (JACK, PipeWire, WASAPI, …)

The seam is `io.AudioBackend` in `src/io.zig`:

```zig
pub const RenderFn = *const fn (user: ?*anyopaque, token: engine.RealtimeToken, out: []f32, frames: usize) void;

pub const AudioBackend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    pub const Config = struct { sample_rate: u32 = 48_000, channels: u16 = 2, block_size: usize = 512 };
    pub const VTable = struct {
        start: *const fn (ptr: *anyopaque, cfg: Config, render: RenderFn, user: ?*anyopaque) anyerror!void,
        stop:  *const fn (ptr: *anyopaque) void,
    };
    pub fn start(self: AudioBackend, cfg: Config, render: RenderFn, user: ?*anyopaque) !void { ... }
    pub fn stop(self: AudioBackend) void { ... }
};
```

Steps:

1. **Write a backend struct** (model on `darwin.CoreAudioSink` / `linux.AlsaSink` in
   `src/io.zig`). Expose `pub fn backend(self: *Self) AudioBackend` returning
   `.{ .ptr = self, .vtable = &vtable }`. Implement `start`/`stop`.
2. **The device callback mints the realtime token** and calls the user `RenderFn`:
   ```zig
   fn deviceCallback(...) {
       const token = engine.enterRealtimeThread(); // FTZ on THIS audio thread (see §4)
       render(user, token, out_slice, frames);
   }
   ```
   This closes the FTZ footgun structurally — `render`'s signature requires the token,
   so it cannot run on a thread that hasn't entered realtime mode.
3. **C interop** (`extern`/`callconv(.c)`) for the OS API lives inside your backend
   struct (see the `darwin`/`linux` namespaces). Tighten C pointers (`[*c]`) to Zig
   kinds (`[*:0]const u8`, `[]const u8`, `?*T`) immediately at the boundary.
4. **Select it at comptime** by target OS — extend `DefaultSink`/`CoreAudioSink`/
   `AlsaSink` in `src/io.zig` (an unsupported target falls back to `Unsupported`,
   whose `start` returns `error.UnsupportedAudioBackend` — loud, not silent).
5. **Link the platform library** in `build.zig` `linkPlatformAudio` (e.g. macOS →
   AudioToolbox/CoreAudio frameworks; Linux → `asound`). Add your OS branch.
6. **Add a cross-compile gate** in `build.zig` (model on `cross-linux`): build the pan
   static lib for the new triple via `resolveTargetQuery`. A static lib does not link,
   so it needs no sysroot — the compile is the stand-in for on-device testing. The
   brief mandates ≥2 backends behind the same seam precisely to keep the abstraction
   exercised; a single backend leaves it untested.

The render itself is the runtime `Engine` (`Engine.start(backend)` drives the
callback; `Engine.renderInto(token)` replays the current plan; `edit→commit` RCU-swaps
the plan at a block boundary). You don't touch the engine — only the transport.

---

## 3. Scenario B — a new bare-metal MCU (the embedded profile)

Here the **render callback IS the I2S DMA ping-pong interrupt**. There is no
`AudioBackend` vtable; the boundary blocks ARE the device bridge, and the render is
the comptime `Executor`.

### 3.1 The DMA ping-pong model (`pan_io_realtime_and_pipeline.md §8`)

Configure the DMA in **circular mode** over a `2N`-sample buffer (two halves). While
the DMA streams one half to/from the codec, you process the other:

- **half-transfer (HT) IRQ** → DMA finished the first half → process the first half.
- **transfer-complete (TC) IRQ** → DMA finished the second half → process the second.

"Fill before the deadline" = "finish before the next HT/TC IRQ." `N` (half the buffer)
is **comptime-known**.

`src/io.zig` provides the target-generic model:

```zig
const dma = io.I2sDma(num, N);          // a 2N circular buffer (.bss) + an `active` half
//   dma.onHalfTransfer()  -> active = 0
//   dma.onTransferComplete() -> active = 1
//   dma.activeHalf() -> []Sample(T)    the half the processing side owns this IRQ
io.I2sDmaSource(num, N)                  // Source: active RX half -> graph
io.I2sDmaSink(num, N)                    // Sink:   graph -> active TX half
```

### 3.2 Bring-up steps

1. **Pick the Numeric.** q15 is the first-class embedded default (no FPU):
   ```zig
   const num = pan.numericFor(.i16, .{ .width_override = 1 }); // i16 lane, i32 acc, saturate, W=1
   ```
   Use `.f32` only if the part has an FPU. (See `dev-notes/fixed-point-filters.md` for
   authoring fixed-point kernels.)
2. **Build the graph at comptime** (model on `pan.embedded` in `src/root.zig`):
   ```zig
   const Source = io.I2sDmaSource(num, N);
   const Gain   = filters.Gain(num);
   const Biquad = filters.Biquad(num);
   const Sink   = io.I2sDmaSink(num, N);
   fn chainGraph() graph.Graph {
       var g = graph.Graph.empty;
       g.block_size = N;                            // N is COMPTIME here
       const src  = g.add(Source);
       const gain = g.add(Gain);
       const bq   = g.add(Biquad);
       const sink = g.add(Sink);
       g.connect(port.MapOutPort(Source), src, 0, port.MapInPort(Gain),   gain, 0);
       g.connect(port.MapOutPort(Gain),   gain, 0, port.MapInPort(Biquad), bq,   0);
       g.connect(port.MapOutPort(Biquad), bq,   0, port.MapInPort(Sink),   sink, 0);
       return g;
   }
   const node_blocks = [_]type{ Source, Gain, Biquad, Sink };
   const Exec = engine.Executor(chainGraph(), &node_blocks); // colored pool, comptime
   ```
   `engine.Executor` runs `commitComptime` at compile time; `Exec.committed.footprint_bytes`
   is a **comptime constant**.
3. **Static memory.** Instantiate the executor as a container-scope `var` so its pool
   lands in `.bss`:
   ```zig
   var rx: io.I2sDma(num, N) = .{};
   var tx: io.I2sDma(num, N) = .{};
   var exec: Exec = .{ .instances = .{ .{}, .{ .gain = … }, .{ .coeffs = … }, .{} } };
   ```
   (Heap-free. If a block needs `initialize`-time allocation, back it with a
   `std.heap.FixedBufferAllocator` over a `.bss` array — see the zero-heap test in
   `tests/embedded_chain_test.zig`. The comptime path's blocks allocate nothing, so the
   pool *is* the static memory.)
4. **The ISR is the callback.** Bind the DMA pointers once, then render per IRQ:
   ```zig
   export fn DMA1_Stream0_IRQHandler() callconv(.c) void {
       if (halfTransferFlagSet()) { rx.onHalfTransfer();  tx.onHalfTransfer();  clearHT(); }
       else                       { rx.onTransferComplete(); tx.onTransferComplete(); clearTC(); }
       const token = pan.enterRealtimeThread();   // no-op on a no-FPU part; same API
       exec.render(token);                        // monomorphized, inlined, wait-free
   }
   ```
   See `src/smoke_freestanding.zig` (`pan_i2s_render_isr`) for the portable skeleton.
5. **Multi-channel boundary.** I2S streams are interleaved; pan is planar. For `C > 1`,
   deinterleave RX → planes and interleave planes → TX at the boundary with
   `io.deinterleave`/`io.interleave` (mono `C = 1` is identity — no transpose). Also
   reconcile the codec's channel order to the layout's canonical order
   (`io.channelPermutation`).
6. **The smoke gate.** Add a freestanding `ReleaseSmall` build target
   (`b.resolveTargetQuery(.{ .os_tag = .freestanding, … })`) that compiles your chain
   object (model on `build.zig`'s `smoke` step + `src/smoke_freestanding.zig`). **The
   object compiling at all is the discharge** of "the commit pass is comptime-evaluable
   end to end for this graph" (`catalog.md §8.5`). A non-comptime-evaluable block is
   rejected with a pan-level error, not a 40-frame Zig trace.

### 3.3 The register-level seam (what you still supply downstream)

`io.I2sDma` is **target-generic on purpose**. You supply, per chip:
- the DMA controller + I2S peripheral register configuration (clocks, formats,
  circular mode, the `2N` buffer address);
- the IRQ vector binding — an `export fn <Vector>_IRQHandler() callconv(.c) void`
  aliased to the device's actual vector, calling `exec.render`;
- **verify the known STM32-HAL circular-mode TC-callback suppression bug** on the real
  part (the HAL can swallow the TC callback in circular mode).

This chip-specific layer is **out of pan's in-tree scope by spec LOCK**: `catalog.md
§9.3` fixes the embedded target as "target-generic / freestanding stub," and a
*concrete* MCU (with CMSIS-DSP/Helium acceleration) is **Phase 19**, which per
`pan_implementation_plan.md §0.8` requires a **spec amendment first** (code conforms to
the spec, never the reverse). So: contribute the portable parts in-tree; the register
layer ships against a concrete target when one is chosen.

---

## 4. The realtime token / FTZ (read this — it is a real shipping footgun)

`enterRealtimeThread()` (`src/engine.zig`) sets **flush-to-zero / denormals-are-zero**
on the *calling* thread and returns a `RealtimeToken`. Why it matters: denormal floats
(decaying reverb/IIR tails toward silence) are 10–100× slower on some CPUs, so a quiet
signal can spike CPU and cause an xrun. On **ARM64 the FPCR `FZ` bit is per-thread and
NOT inherited by child threads** — a real shipping bug (full-volume noise on Apple
Silicon) came from exactly this. `renderInto`/`Executor.render` **require the token in
their signature**, so forgetting FTZ on a self-spawned audio/worker thread is a compile
error, not a silent bug.

Current behaviour by ISA (`enterFlushToZero`): aarch64 sets FPCR FZ/FZ16; x86 sets
MXCSR FTZ/DAZ; **any other arch is a structural no-op** (`active = false`). So on a
fixed-point / soft-float MCU the token is already a no-op while the API shape stays
identical across targets. If you bring up a concrete FPU-less arch not in that switch,
the no-op branch already covers it; if you bring up a new arch *with* an FPU and a
different control register, extend `enterFlushToZero`/`restoreFpEnv`.

---

## 5. Checklist & gotchas

- [ ] Numeric chosen (`numericFor`); q15 unless the part has an FPU. `W` is 1 without a
      vector unit (correct scalar fallback) — pin it with `.width_override` to match.
- [ ] All blocks in the chain are **comptime-evaluable** (the commit runs at comptime).
- [ ] `N` is comptime-known on embedded (half the DMA buffer).
- [ ] No heap: comptime `Executor` (pool in `.bss`) or `FixedBufferAllocator` over a
      static array for the runtime engine.
- [ ] DMA in circular mode; HT/TC → `onHalfTransfer`/`onTransferComplete` → `render`.
- [ ] The render entry takes (and is gated by) a `RealtimeToken`.
- [ ] Boundary interleave/deinterleave + channel-order reconciliation for `C > 1`.
- [ ] A freestanding `ReleaseSmall` smoke target compiles the chain (the discharge).
- [ ] Any new fixed-point kernel is bit-exact-tested against an independent oracle and
      fails loud until validated (see `dev-notes/fixed-point-filters.md`).
- [ ] Desktop backend: registered in `DefaultSink`, linked in `linkPlatformAudio`,
      cross-compile gate added.
- Gotcha: a plain `struct` has unspecified field order — use `extern struct`/`packed
  struct(uN)` for anything crossing the C/ABI/register boundary.
- Gotcha: `callconv(.c)` is lowercase in 0.16.0 (`.C` is gone).

---

## 6. Where the code lives

| Concern | File |
|---|---|
| Compute HAL (`@Vector` kernels, `qMulStore`) | `src/simd.zig` |
| I/O HAL: PCM codecs, `AudioBackend`, CoreAudio/ALSA, I2S-DMA | `src/io.zig` |
| Realtime token / FTZ, the comptime `Executor`, runtime `Engine` | `src/engine.zig` |
| The Numeric trait / `numericFor` / precision set | `src/numeric.zig` |
| The worked embedded q15 chain (reference) | `src/root.zig` (`pan.embedded`) |
| The freestanding smoke object (ISR skeleton) | `src/smoke_freestanding.zig` |
| Build targets: `smoke`, `cross-linux`, `linkPlatformAudio` | `build.zig` |
| Embedded tests (gate + zero-heap FBA) | `tests/embedded_chain_test.zig` |
