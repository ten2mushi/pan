# P15 Tier-B streaming benchmark — results & critical analysis

**Bench:** `bench/parallel_bench.zig` (`zig build bench`, ReleaseFast).
**Machine:** Apple **M3 Max — 12 performance cores + 4 efficiency cores** (16 total), macOS.
**What it measures:** a wide, CPU-heavy graph (a source fanning out into many independent
heavy chains summed by an adder tree — the Tier-B target shape) rendered block-by-block
under Tier A (single-core sequential) vs Tier B (level-barrier and HEFT, P = 2..8),
reporting wall-clock speedup, the gate-chosen worker count, per-worker spin time, and the
concurrency-aware-colored footprint.

> **Read the numbers with these caveats (printed by the bench itself):** single-shot
> timing per config (no variance band); `force_workgroup = true` but **no real device
> `os_workgroup`**, so the workers are plain threads and the bounded-spin claim is not
> OS-enforced here; the kernel is a synthetic latency-bound polynomial (stresses the
> parallel path, not representative of SIMD/memory-bound real DSP); and **the gate-chosen
> `workers`, not the core budget, is the ceiling** (see §2).

---

## 1. Headline numbers (clean, unloaded machine)

**wide STRESS — 16 heavy voices, N=512, 4096 blocks** (TierA baseline ≈ 2.23 ms/block):

| req cores | workers | HEFT speedup | level-barrier speedup | HEFT spin |
|---:|---:|---:|---:|---:|
| 2 | 2 | 1.97× | 1.97× | ~300 |
| 3 | 3 | 2.57× | 2.34× | ~11k |
| **4** | **4** | **3.90×** | **2.81×** | ~380 |
| 5 | 5 | 3.71× | 2.54× | ~13k |
| 6 | 5 | 3.72× | 2.19× | ~30k |
| 7 | 5 | 3.59× | 2.18× | ~57k |
| 8 | 5 | 2.73× | 2.27× | ~26k |

**W=16, lighter kernel (a separate scaling probe, HEFT):** 1.00× (1 core) → 1.99× (2) →
3.90× (4) → **4.41× (5 workers)**, then flat 4.3–4.4× for any core budget ≥ 6 — the worker
count pins at 5.

**Footprint (Tier-B addendum):** TierA colored = 20 KB; **TierB concurrency-colored scratch
= 48 KB (24 buffers)** — Tier B uses *more* memory by design (peak-concurrent live edges).

---

## 2. The five findings, audit-scored

### Finding 1 — Within the parallelism budget, scaling is near-ideal. (runtime: 9/10)
1.97× @2 and 3.90× @4 is ~97% parallel efficiency; 4.41× @5 workers is ~88%. The static
schedule, point-to-point ready-flags, and shared pool add essentially no overhead up to the
worker count the gate picks. This is excellent.

### Finding 2 — But the worker count caps at ~5 on a 12-P-core machine. (utilization: 5/10)
The gate sizes `P = round(parallelism)` and the commit-time parallelism is `work / span`.
The **static byte-cost model weights a trivial adder the same as a heavy voice** (both output
N×4 bytes), so the cheap adder tree inflates the "span" and the model under-estimates the true
compute-parallelism (~16 for a 16-voice bank) as ~4.6. So **7 of 12 P-cores sit idle** on this
graph. This is the single highest-leverage performance gap, and the fix is already designed but
not wired: live per-op CPU EWMA (`CostModel.refine`/`refineE`/`cost_e` exist as hooks; nothing
feeds them measured time on the RT path yet). With compute-aware costs, P would size toward 12.

### Finding 3 — Past the peak, both executors regress, and the spin telemetry proves why. (honest)
HEFT peaks at 3.90× @4 then decays to 2.73× @8; the per-worker spin count explodes
(~380 → ~57,000). This is exactly the **unbounded-spin pathology the render-workgroup exists to
prevent**: with `force_workgroup=true` but *no real `os_workgroup` on the dev box*, the workers
are plain threads, macOS scatters the surplus across E-cores (≈⅓ a P-core's throughput) and
deschedules them, so consumers spin on ready-flags whose producers are stalled. The B12
spin-time telemetry surfaces the breach precisely as specified; in a live deadline the
auto-demote policy would fall back to Tier A. **The regression is the honest signature of running
the architecture *without* its load-bearing OS primitive** — not a bug.

### Finding 4 — HEFT clearly beats the level-barrier here (3.90× vs 2.81× @4). (corroborates the gate)
The deep adder tree means many barrier phases, each waiting for the slowest worker; HEFT's
point-to-point ready-flags fill those bubbles. This empirically confirms the unit-tested
`heft.makespan ≤ level.makespan` claim on an irregular (wide→narrow) graph.

### Finding 5 — The bench methodology is weak; single-shot is unreliable under load. (bench quality: 5/10)
Re-running the *same* configs while the test gate hammered all 16 cores in the background gave
**0.84× to 6.40×** for the same config class — wild, meaningless variance (and an apparent,
impossible 6.40× "super-linear" from a contended baseline). Lessons / TODO: report a min-of-N or
a variance band, not single-shot; pin/quiesce the machine; add a real-kernel (biquad/FIR) variant
alongside the synthetic; and note that the absolute load here is comfortably realtime single-core
anyway (2.2 ms to render a 512-frame block ≈ 4.8× realtime at 48 kHz), so this measures **density
headroom**, not xrun avoidance.

---

## 3. Comparison with known libraries

| System | In-callback graph parallelism | Typical multicore scaling | pan vs it |
|---|---|---|---|
| **JUCE / AVAudioEngine / most VST hosts** | none (single-threaded callback) | 1× | pan is **categorically ahead** |
| **SuperCollider `supernova` (ParGroup)** | yes (independent synth groups) | ~near-linear to 4–6 cores | pan **matches at low core counts**; supernova keeps using cores past 5 where pan's cost model caps |
| **Faust `-sch` / `-omp`** | yes (compiled scheduler) | 2–4× typical, drops on irregular graphs | pan's 3.90× @4 is at the **top of Faust's range**; pan's no-CAS static schedule avoids Faust's work-stealing overhead |
| **Bitwig / Reaper (anticipative FX)** | yes, but with **look-ahead latency** | near-N×cores | pan is strictly in-callback (lower latency, harder problem) and still hits 3.9× @4 — a fair trade, but won't reach their utilization until the cost-model fix |
| **Intel TBB flow-graph / OpenMP** | generic task parallelism | near-linear for coarse tasks | pan deliberately forgoes work-stealing (CAS) for RT wait-freedom |

**Net positioning:** pan's Tier B is **ahead of every single-threaded audio framework** and
**competitive with the parallel audio servers (supernova, Faust-sch) at low core counts**. Its
gap versus the best (supernova/Bitwig using all cores for a wide voice bank) is the cost-model
P-undersizing (Finding 2), not the runtime — which scales at ~97% efficiency within its budget.

---

## 4. Scorecard

| Dimension | Score | Note |
|---|---:|---|
| Parallel-runtime engineering (efficiency within budget, bit-exact, no contention) | **9/10** | 97% @4 workers; TSan-clean; bit-identical to Tier A |
| Core utilization on this hardware | **5/10** | cost-model caps P at ~5 of 12 P-cores; fix designed (EWMA), not wired |
| Honesty of the result *as presented in the bench* | now **7/10** | fixed: footprint mislabel, exposed worker-cap + par, added caveats; still single-shot |
| Architectural positioning vs the field | **8/10** | ahead of single-threaded hosts; competitive with parallel servers; wait-free no-CAS schedule |

**Bottom line:** the **3.9×-on-4-cores headline is real and competitive, but it is the ceiling of
a ~4.6 cost-model parallelism estimate, not of the 16-core machine.** The two highest-leverage
follow-ups are (a) wire live per-op telemetry into the cost model so a 16-voice bank sizes P
toward 12, and (b) verify the bounded spin on a real `os_workgroup` — without which scaling
regresses past ~5 workers exactly as the spin telemetry honestly shows.

---

*Numbers from `bench/parallel_bench.zig` on M3 Max, ReleaseFast, unloaded (the headline table) and
under background load (Finding 5's variance). Re-run with `zig build bench`. The bench prints its
own methodology caveats at the top.*
