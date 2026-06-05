# Tier B — per-kernel cost model + profile-guided calibration: throughput assessment

Honest before/after assessment of the static-parallel (Tier B) executor after two
schedule-only changes: a **per-kernel cost hint** and **profile-guided calibration**.
Companion to `dev-notes/p15-streaming-bench-report.md` (the original byte-cost-model
state). Numbers from `bench/parallel_bench.zig` (`zig build bench`, ReleaseFast) on an
**Apple M3 Max (12 P + 4 E cores)**, quiesced.

> **What changed (both schedule-only — costs never touch rendered samples; the bit-exact
> Tier-B-vs-Tier-A differentials still hold):**
> 1. A block may declare `pub const cost_hint: f32` (relative compute per output sample,
>    default 1.0). It flows `GraphNode.cost_hint` → `RenderOp.cost_hint` →
>    `CostModel.fromPlan` (`cost[i] = (1 + output_bytes) · cost_hint`). Without it every
>    op writing N samples weighed the same, so a cheap adder inflated the critical path
>    and the gate under-sized the worker count.
> 2. `Engine.calibrate(k)` renders `k` warm-up blocks under a sequential replay (in
>    schedule order — the colored plan's reuse anti-deps require it), times each op via a
>    monotonic tick source, and rebuilds the schedule from the measured per-op cost.

---

## 1. The change, quantified — apples-to-apples on the real biquad bank

Identical graph (16 IIR biquad voices → balanced adder tree → sink), N=512, quiesced
M3 Max. Byte-cost model vs per-kernel + calibration:

| | worker cap | `par` (work/span) | peak speedup |
|---|---:|---:|---|
| **Pre** (byte volume) | **5** of 12 | 4.6 | level-barrier 3.24× @4, HEFT ≈3.5× |
| **Post** (per-kernel + calibration) | **8** | 8.0 | **level-barrier 4.24× @8, HEFT 4.53× @8** |

Post-change worker sweep (HEFT, TierA baseline 105.7 µs/block):

```
workers  2     3     4     5     6     7     8
HEFT    1.87  2.59  3.49  3.59  4.45  4.47  4.53x
level   1.91  2.42  3.63  3.41  3.90  3.80  4.24x
```

**The cost-model fix did exactly what it was designed to: the worker cap moved 5→8 and
realized throughput rose ≈3.2–3.5× → ≈4.3–4.5× — a ~30–40% density gain on the same
hardware**, with `par` now sizing 2.0→8.0 linearly instead of flat-lining at 4.6.

---

## 2. Why it is a real-but-bounded win (the ceiling moved; it did not vanish)

4.53× at 8 workers is **57% parallel efficiency**, not linear. The bottleneck is no
longer the cost model — it is now structural:

- **Reduction-tree serial fraction.** The 16 voices run 16-wide for one phase (cost ≈ a
  biquad), but the log₂(16)=4 levels of *cheap* adders that follow underutilize cores.
  The graph's true average parallelism is `W/S ≈ 8`, and HEFT delivering ~4.5× of that is
  consistent — the tree phase cannot fill 8 cores. Approaching linear needs **flatter
  mixing** (wide fan-in adders), a graph-shape lever, not a scheduler lever.
- **No real `os_workgroup`** on the dev host: past the heavy-op regime the unbounded
  cross-worker spin still bites (see §3).

The diagnosis is reclassified: from *"the scheduler is starved of accurate costs"* (pre)
to *"the reduction tree is serial and the device workgroup is needed past the heavy-op
regime"* (post).

---

## 3. Three honest caveats the new state introduces

- **The cost-model fix makes the workgroup MORE load-bearing, not less.** Because the gate
  now sizes 8 workers instead of 5, the **FIR (light-op) scenario livelocked at 7–8
  workers** without a real workgroup (one process, 34 min CPU-time, no output progress —
  surplus workers descheduled, consumers spinning on stalled producers' ready-flags).
  Heavy biquad ops absorb the spin; light FIR ops do not. So the full benefit is now gated
  on the device workgroup *more tightly* than before. In a real deadline-driven loop the
  auto-demote policy catches this; the bench (direct `renderInto`, no headroom feedback)
  does not, so it hangs — which is the sharpest evidence yet that the Render-Workgroup HAL
  is load-bearing. (Mitigation for the bench: cap the worker sweep on no-workgroup hosts.)
- **Calibration is correctness-confirmed but throughput-unquantified here.** The demo shows
  `calibrated` flips false→true and the re-costed schedule renders bit-exact — but `par`
  stayed 8.0 before *and* after, because the static biquad hint (≈20×) already saturates
  the bench's 8-worker cap. Calibration's distinct value (correcting a *wrong/absent* hint;
  sizing toward 12 on a 12-core sweep) is real but **not visible on a `p_max=8` bench with
  well-hinted blocks.** No number is claimed for it.
- **Single machine.** Even quiesced this measures density headroom (40–100× realtime), not
  xrun avoidance. An earlier source of noise was **6 stray bench processes (load avg 109)**
  that survived `kill`-of-the-build-wrapper (killing `zig build` does not reap the spawned
  exe) — reaped before the clean run. Numbers remain fragile to host load.

---

## 4. Versus known DSP libraries

| System | In-callback parallelism | pan now |
|---|---|---|
| **JUCE / AVAudioEngine / VST hosts** | none (single-threaded callback, 1×) | **categorically ahead** (4.5× in-callback) |
| **SuperCollider `supernova` (ParGroup)** | yes, ~near-linear to 4–6 cores | **competitive**; pan matches to ~8 workers, wait-free (no CAS) where supernova differs |
| **Faust `-sch` / `-omp`** | yes, 2–4× typical, drops on irregular graphs | pan's **4.53× is at/above Faust's range**; static no-CAS schedule avoids work-stealing overhead |
| **Bitwig / Reaper (anticipative FX)** | yes, but with look-ahead **latency** | pan is strictly in-callback (lower latency, harder problem); 4.5× is a fair trade |
| **Apple vDSP (single-core SIMD kernel)** | n/a (1 core, vectorized) | pan's *scalar* biquad is **≈3.4–4.6× slower per-sample than vDSP's NEON** |

The vDSP row is a **yardstick, not a dependency or a plan.** pan is first-principles /
from-scratch: its core links no external DSP library — every kernel is pan's own
`@Vector` Zig (the only vDSP reference is the *comparison* bench, `vdsp_compare_bench.zig`,
which measures headroom). The load-bearing framing: **pan-on-8-cores (4.5×) roughly
*recovers* the single-core SIMD gap vs vDSP** for a biquad — today pan trades a
not-yet-hand-tuned kernel for parallelism + portability. Closing the remaining per-core gap
means writing **pan's own** optimized SIMD kernels (§6), not linking Accelerate — and
because they are portable `@Vector`, the win compounds with parallelism on *every* target.

---

## 5. Audit scorecard (vs pre-change)

| Dimension | Pre | Post | Note |
|---|--:|--:|---|
| Cost-model correctness | 5/10 | **8/10** | per-kernel + measured; remaining: no P/E-split-aware placement, calibration value unquantified |
| Parallel-runtime engineering | 9/10 | **9/10** | bit-exact, TSan-clean, wait-free; correctly unchanged |
| Core utilization (this hardware) | 5/10 | **7/10** | cap 5→8; realized 4.5× bounded by tree serial-fraction + no-workgroup |
| Result honesty as presented | 7/10 | **8/10** | real kernels, min-of-N, ×realtime; FIR livelock surfaced; calibration value not quantified |
| Field positioning | 8/10 | **8/10** | ahead of single-threaded hosts; competitive with parallel servers; SIMD-kernel gap is the known accel deferral |

**Bottom line.** The cost-model fix is solid and lands the structural win: **worker cap
5→8, ≈30–40% more density, bottleneck reclassified.** Calibration is proven-correct
(bit-exact, `calibrated` flips, re-costed schedule promotes and renders) but its throughput
payoff awaits an uncapped sweep / a mis-hinted graph. Top three remaining levers, in order:

1. **A real `os_workgroup`** — now *more* load-bearing; unblocks light-op graphs past ~6 workers.
2. **Raise the bench `p_max` to 12 + the op/node cap** — to show the cost model sizing toward 12 (the op-list is capped at 64 nodes; the bench caps the worker sweep at 8).
3. **Hand-write pan's own optimized `@Vector` kernels** (first-principles, no external lib) — close the ≈4× single-core gap (measured against vDSP as a yardstick) so parallelism compounds on a faster per-core kernel, portably across every target.

---

## 6. Portability, and where platform-specific kernels go (the iOS question)

**Is pan at a state that runs anywhere, with an architecture that enables *and* pushes
platform-specific optimization?** — Confirmed, with one honest qualification.

**The architecture: yes, unambiguously.** The core (graph + blocks) is execution- and
platform-agnostic — a block is authored once and runs under a CoreAudio callback, an ALSA
thread, or an MCU DMA ISR unchanged. Platform specifics live behind two clean HAL seams:

- **Compute HAL** (`src/simd.zig`) — every kernel is `@Vector(W, T)` with a scalar tail,
  `W = std.simd.suggestVectorLength(Lane) orelse 1` (`numeric.zig:75`). The compiler lowers
  it to **NEON on Apple Silicon, AVX2/AVX-512 on x86, Helium on Cortex-M**, and scalarizes
  (`W=1`) where there is no vector unit. So the *baseline* vectorization is free and portable.
- **I/O HAL** — the audio transport: an `io.AudioBackend` vtable on desktop/mobile, the
  I2S-DMA ISR on embedded.
- **No external DSP dependency, by intent.** pan is first-principles / from-scratch: the
  core links no vendor library. `src/simd.zig:9` mentions a *possible* optional vendor slot
  "never a dependency of the core," but the project direction is **not** to take it — the
  per-core gap is closed by writing pan's *own* faster kernels, not by linking Accelerate /
  FFTW / CMSIS. (The only vendor reference anywhere is the comparison bench, a yardstick.)

**Runs anywhere — the honest qualification.** The portable core *compiles* for every target
(the `cross-linux` and freestanding `smoke` gates prove it) and *runs* on macOS today. For
the other targets it is "core compiles + HAL seam present; the platform's I/O transport and
on-device verification are the remaining per-platform work":

| Target | Compute HAL | Workgroup HAL | Audio I/O HAL | State |
|---|---|---|---|---|
| macOS (M3) | NEON (free) | `os_workgroup` branch present | CoreAudio backend | **runs** |
| **iOS** | **NEON — identical to macOS** (aarch64) | `.ios` branch present (`parallel.zig:137`) | **needs a RemoteIO/AVAudioSession backend** | compiles; on-device deferred |
| Linux | AVX (free) | SCHED_FIFO+affinity | ALSA backend seam | compiles (gate); on-device deferred |
| embedded | scalar/Helium | N/A (single core) | I2S-DMA ISR (register layer out-of-tree) | compiles (smoke) |

So "runs anywhere" is true at the **architecture + compile** level and **runs on macOS**;
the per-platform remainder is I/O transport + on-device verification, not core rework.

**Today's kernels are correct but not yet hand-tuned** — the portable `@Vector` core favours
clarity over peak throughput, hence the ≈3.4–4.6× single-core gap vs vDSP (§4). Closing it is
the work, done in pan's own Zig.

### Where do iOS-specific kernels go? — they (mostly) don't

The key correction: **iOS needs no iOS-specific kernel at all.** iOS is aarch64, so the
portable Compute HAL already emits the *same* NEON it does on the M3. There is no "iOS has no
SIMD" gap, and — under the first-principles, no-external-dependency rule — there is **no
vendor (vDSP/Accelerate) kernel to plug in** either.

So the per-core gap is closed by **rewriting pan's own kernels from first principles**, once,
as portable `@Vector` Zig in the Compute HAL — and the compiler then lowers that *one*
implementation to NEON (iOS + macOS), AVX (x86), Helium (Cortex-M55), or scalar. **One
hand-tuned kernel set benefits iOS, macOS, Linux, and embedded simultaneously**; there is no
per-platform kernel fork. The optimization work is algorithmic and layout-level, not
library-call-level:

1. **FFT / spectral** (`spectral.zig` `rfftForward`) — the **one genuine per-core gap**, now
   measured directly against vDSP (`bench/vdsp_compare_bench.zig`, `zig build bench-vdsp`):
   **pan/vDSP = 10.7× at 256-pt rising to 15.6× at 2048-pt** (energy ratio 1.000 — same
   transform). Unlike the biquad (flat ≈3.5×, pure abstraction overhead), the FFT gap
   *grows with N* — the signature of an algorithmic deficit: pan runs a radix-2 FFT vs
   vDSP's split-radix + vectorized butterflies. Closing it is real kernel work — write a
   proper split-radix / real FFT in Zig (algorithm + `@Vector`, both reproducible from
   scratch, no vendor dependency). The biggest single-core win available.
2. **Biquad / IIR** (`filters.zig`/`fx.zig`) — vectorize across voices/channels (state-parallel
   form) or use a transposed/normalized structure that the `@Vector` lowering can fill; closes
   the §4 gap directly.
3. **FIR / convolution** — blocked/vectorized inner product with the right accumulator layout.
4. Bulk ops (gain/mix/dot) — already near-optimal in the `@Vector` core; marginal.

The portable techniques (no external lib): explicit `@Vector(W,T)` with `W` from the target,
the right state/data layout (SoA, cache-aware), `@branchHint`, bounds-check elision in proven
hot loops, comptime selection of a target-tuned variant on `builtin.cpu.features` where a NEON
shuffle or an AVX-512 width genuinely helps — **all pan's own Zig.**

**The genuinely iOS-specific work is *not* a kernel** — it is the **I/O HAL audio backend** (a
RemoteIO `AudioUnit` + `AVAudioSession` transport, the iOS sibling of the macOS CoreAudio
backend) plus on-device verification (the `os_workgroup` join, FTZ per worker, the deadline).
A transport, authored once at the I/O seam — that is what makes pan *run* on an iOS device.

**Summary:** pan runs anywhere at the architecture/compile level (and on macOS today). The
Compute HAL *pushes* platform optimization — but as the compiler's target lowering of **pan's
own** portable, hand-tuned `@Vector` kernels (FFT → biquad → FIR), **not** a vendor slot and
**not** iOS-specific code. The only iOS-*specific* addition is the RemoteIO/AVAudioSession
audio backend in the I/O HAL.

---

## Context reference

Code (line numbers at time of writing, `zig 0.16.0`):
- `src/graph.zig` — `GraphNode.cost_hint` field; `Graph.add` reads `@hasDecl(Block, "cost_hint")`.
- `src/commit.zig` — `RenderOp.cost_hint` field; set at op emission from `g.nodes[v].cost_hint`.
- `src/parallel.zig` — `CostModel.fromPlan` (`cost = (1 + bytes) · cost_hint`); `costGate`; `heftSchedule`; `concurrencyColor`.
- `src/engine.zig` — `Engine.calibrate`; `TierB.measure` (schedule-order replay); `TierB.buildFor` (refine hook on both the gate cost model and the final schedule); `monoTicks`; `Engine.tierBCalibrated`.
- `bench/parallel_bench.zig` — real biquad-cascade / FIR kernels with `cost_hint`, min-of-N reps, ×realtime, and the calibration demo (runs first).

Commits: `8893552` (per-kernel cost model + calibration), `ef666cc` (fail-loud node cap +
realistic-kernel bench), `50ae14c` (Tier B checkpoint).

Companion notes: `dev-notes/p15-streaming-bench-report.md` (pre-change byte-cost state),
`dev-notes/p15-independent-audit.md` (Tier-B correctness audit).

*Bench: `bench/parallel_bench.zig`, M3 Max, ReleaseFast, quiesced (headline) + the FIR
no-workgroup livelock (§3). Re-run with `zig build bench`. The bench prints its own
methodology caveats.*
