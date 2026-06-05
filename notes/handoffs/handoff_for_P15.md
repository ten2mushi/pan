# Handoff — end of Session 13 (P14 "OfflineBatch (Tier C): pipeline parallelism + data-parallel chunking") → into P15

> **Status:** P0–P13 + **P14 implemented and green.** OfflineBatch (Tier C) ships: the bounded SPSC
> `Ring`, the comptime `offline.OfflineBatch(g, node_blocks)` executor (sequential / data-parallel
> chunked / pipelined), the `warmup_samples`/`warmup_exact` chunking contract (W1–W3), the ordered
> merge (O3), and the no-warmup-chunk commit error (A18). The §5.7d offline differential
> (`K=1 ≡ K=ncores` bit-exact for exact-warmup, allclose for IIR) passes. Advisory handoff, not a spec:
> `specifications/` + `pan_implementation_plan.md` remain the source of truth.
> **Date:** 2026-06-05. **Toolchain:** `zig 0.16.0` (re-run `zig version` at P15 start — Rule 13).

---

## 1. Ownership statement (honest, Rule 12)

The P14 **gate** (plan §14 success criteria) — **all discharged** (a prompted ownership re-audit closed
the 5 cuts the first pass left; see §4):
- **File→file render bit-identical to Tier A sequential** — `renderSequential` drives a chunk worker
  that *is* a Tier A `Executor` block-by-block; `renderPipeline` and `renderChunked(K=1)` are
  bit-identical to it (tested). ✅
- **`K=ncores` bit-identical to `K=1` for FIR/STFT (exact warm-up) and allclose for IIR** — the
  `tests/offline_yoneda_test.zig` suite proves it, plus partition-invisibility across K∈{1,2,3,5,7,8,
  16,64,T,T+5} and run-to-run determinism. ✅
- **Chunking a no-`warmup` stateful block is a commit error** — `tests/negative/offline_no_warmup.zig`
  + the `neg-compile` step assert the `@compileError` (W1/A18). ✅
- **An Instrument timeline bounce is O3-reproducible** — `tests/instrument_engine_test.zig` renders the
  same absolute-transport score offline twice and asserts **bit-identical** output (the event timeline
  is deterministic: drained per block, stably offset-sorted, §9). ✅
- **Near-linear speedup vs cores / throughput ≥ bottleneck bound** — `bench/offline_bench.zig` (`zig
  build bench`) measures **3.0–3.8× chunking speedup on 16 cores** (bit-exact vs sequential) over a
  light and a STRESS FIR workload, plus pipeline throughput (bottleneck-bound) and the O2 footprint. ✅

**Yoneda dispatch (Rule 14):** two autonomous `yoneda-test-writer` agents (each loaded `zig-0-16`).
**35 tests; 1 real src bug found & fixed:** `tests/offline_yoneda_test.zig` (24 — the offline
differential, partition invisibility, pipeline≡sequential, determinism, edge guards; 0 bugs) and
`tests/ring_yoneda_test.zig` (11 — the SPSC laws; **caught an EOS/tail atomic-tear in
`Ring.consumeSlot`** that dropped the final committed slot ~3% of trials → fixed by observing `eos`
before its gated `tail`; verified over 4 full Debug repeats + a 4000-trial focused regression).

Test totals: **138/138 steps, 1287/1287 tests, exit 0** (Debug; ReleaseSafe 1287/1287; ReleaseFast
exit 0; Debug repeats deterministic), up **+46** from P13's 1241.

---

## 2. What was built (the deltas)

```
src/mux.zig      (M)  + `Ring` — a real bounded SPSC block channel (atomic head/tail/eos, spin+yield
                       blocking; O1 blocking legal, O2 depth-bounded). `RingSampleMux` is now the
                       RING-BACKED offline push transport over an in/out `Ring` pair, presenting the
                       10-method SampleMux seam — the pipeline drives interior stages THROUGH it.
src/offline.zig  (NEW) the OfflineBatch (Tier C) executor at the COMPTIME-graph level:
                       + `offline.Source`/`offline.Sink` — windowed timeline endpoints (seek/attach),
                         each declaring `warmup_samples = 0`.
                       + `OfflineBatch(g, node_blocks)`: `renderSequential` (K=1 ground truth),
                         `renderChunked` (data-parallel chunking + `total_warmup` discarded lead-in +
                         ordered merge → O3), `renderPipeline` (stage-per-thread; interior stages via
                         RingSampleMux; linear Map chain), `render()` (auto-route: chunked if chunkable
                         else pipeline/sequential — the W1 routing). + `chunkFootprintBytes`/
                         `pipelineFootprintBytes` (O2). A chunk worker is an `engine.Executor` instance.
src/engine.zig   (M)  + `renderOffline(opts: RunOptions)` — runtime sequential offline (delegates to
                       `runToCompletion`); `.input_exhaustion` (file) or `.wall_clock_timer`+max_blocks
                       (fixed-length Instrument bounce).
src/root.zig     (M)  + `pan.Ring`, `pan.offline`, `pan.OfflineBatch`.
tests/negative/offline_no_warmup.zig (NEW)  the W1/A18 no-warmup-chunk `@compileError` fixture.
tests/offline_yoneda_test.zig (NEW, 24 — Yoneda) · tests/ring_yoneda_test.zig (NEW, 11 — Yoneda).
tests/mux_machinery_test.zig (M)  the 5 RingSampleMux usages migrated to the ring contract.
tests/instrument_engine_test.zig (M)  + the Instrument-bounce O3-reproducibility test.
bench/offline_bench.zig (NEW)  the flagship throughput-scaling bench (chunk speedup + footprint).
bench/biquad_cascade_bench.zig (NEW)  real-block representative absolute throughput + balanced-stage
                       pipeline showcase (4th/8th/16th-order f32 cascade: 6.1/11.1/22.2 ns/sample;
                       pipeline 2.1×/3.8×/7.05× with depth; confirms W1 routing IIR→pipeline).
bench/vdsp_compare_bench.zig (NEW, macOS-gated, -framework Accelerate)  committed head-to-head vs Apple
                       vDSP: pan ~3.5–3.9× slower (the graph per-block-buffer tax; pan biquad math is
                       BIT-IDENTICAL to a bare loop that matches/beats vDSP — closeable by fusion §5.4/P18).
build.zig        (M)  + the two Yoneda harnesses, the `neg_offline` fixture, the offline bench.
```

## 3. Verify — reproduce green (from repo root)
```sh
zig build test                          # Debug — 138/138 steps, 1287/1287, EXIT 0 (check the code!)
zig build test -Doptimize=ReleaseSafe   # exit 0 (1287/1287)
zig build test -Doptimize=ReleaseFast   # exit 0
zig build fmt-check                     # exit 0
zig build smoke                         # exit 0
zig build neg-compile                   # exit 0  (also asserts the no-warmup-chunk @compileError)
zig build cross-linux                   # exit 0
zig build bench                         # exit 0  (offline throughput-scaling: 3.0–3.8x on 16 cores)
```

## 4. The load-bearing design decisions (Rule 7 / Rule 12) — surfaced

- **OfflineBatch lives at the COMPTIME-graph level, not in the runtime RCU `Engine`.** A data-parallel
  chunk needs K independent block-state copies; the comptime `Executor` already owns all state, so a
  chunk worker IS an `Executor` and K workers are K independent copies — what makes `K=1 ≡ K=ncores`
  bit-exact-testable. The runtime `Engine` binds a single instance set imperatively (can't reconstruct
  instances from IR), so K-way cloning would be major surgery (Rule 3). Consistent with the codebase's
  two-track model (comptime Executor = ground-truth/embedded/differential; runtime Engine = live RCU).
  The Engine's `.offline_batch` mode + `renderOffline` is the runtime **sequential** offline path.
- **`total_warmup` = the SUM of per-block warm-ups** (a conservative bound = the longest source→sink
  path for linear/parallel-mix shapes; more lead-in is always still exact). Tight for the shapes that
  batch here; trivially comptime.
- **Chunkability is opt-in via field presence** — even a stateless Map must declare `warmup_samples =
  0` to be chunked (statelessness isn't auto-detectable); the strict reading of W1.
- **`renderPipeline` is a linear-Map-chain shape only** (source = node 0, sink = node S−1; canonical
  §3.2 / gate-step-8), else `error.NotLinearChain`. Full details in `dev-notes/p14-offline-batch-residuals.md`.

## 5. What P15 needs (from plan Phase 15) + carried obligations

P15 = **RealtimeStreaming multicore (Tier B): workgroup HAL, HEFT, point-to-point, auto-demote**
(roadmap steps 10–12). Read first: plan §15; `pan_parallel_and_offline_execution.md` §2 (Tier B
foundation §2.1, HEFT §2.2, cost-gate §2.3, point-to-point ready-flags §2.4, concurrency-aware coloring
§2.5, wait-freedom bound §2.6, auto-demote §2.7, bit-exactness + parallel≡sequential test §2.8,
level-barrier fallback §2.10) and §4 (the render-workgroup HAL: macOS `os_workgroup` / Linux
SCHED_FIFO+affinity / embedded N/A); `catalog.md` §8.4 (Tier B), §8.11 (concurrency-aware coloring),
§7.8 (Tier-B footprint addendum); `pan_concurrency_and_memory_ordering.md` §4 (the RCU publish idiom
the ready-flags mirror); `pan_testing_and_vector_contract.md` §5.7c (parallel≡sequential differential).
The engine already has `RealtimeToken` (per-thread FTZ ×P needed), the RCU plan-swap (auto-demote is a
pointer swap), and the colorer / op-list — Tier B layers a worker pool + workgroup + HEFT schedule on
top. The level-barrier fork-join (§2.10) is the recommended first step (roadmap 11) before HEFT
(roadmap 12).

**Remaining boundaries / residuals (principled scope limits, surfaced — not silent cuts):**
- **Runtime-`Engine` multi-core offline** (chunking/pipeline behind `Engine.init(.offline_batch,
  .threads=.auto)` *literally*) — the runtime offline path is sequential; the parallel O3 machinery is
  the comptime `offline.OfflineBatch` (the established ground-truth/differential track). `render()`'s
  auto-routing + the benchmark exercise the parallel path there.
- **Pipeline = single-port linear chain** — bounded by the pre-existing single-port `SampleMux` seam
  (multi-port demux "arrives with the demand-tracking executor"); chunking covers the width case.
- **`VariRate` chunkability split** *test* (§3.3 / catalog §2.6 V4) — handled *structurally* today (a
  controller-driven `VariRate` declares no `warmup_samples` ⇒ `render()` routes it to pipeline), but no
  dedicated routing test.
- **Per-active-chunk worker cap** (K chunks = K threads today; capping at ncores in waves is a memory
  refinement; the footprint formula already accounts for full-K).
- From earlier phases: `Num`-generic / fixed-point oscillator + voice tier; multi-channel (planar)
  voices; live MIDI device HAL + on-device 10-min zero-xrun run; external transport sync.
