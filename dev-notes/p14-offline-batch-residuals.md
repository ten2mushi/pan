# P14 — OfflineBatch (Tier C): what shipped, the load-bearing decisions, and the honest deferrals

> Session 13 (2026-06-05). Status: **P14 implemented & green** across the four-mode matrix +
> fmt-check / smoke / neg-compile / cross-linux + bench (all exit 0; Debug repeated deterministic).
> Totals: **138/138 steps, 1287/1287 tests** (Debug & ReleaseSafe), up +46 from P13's 1241. Trust the
> EXIT CODE, never a printed count.
>
> **Post-completion ownership re-audit (Rule 12 in action).** An adversarial "do you own the WHOLE §14
> surface?" re-read caught **5 genuine cuts/hand-waves** the first pass left — all now **closed**:
> (1) **`RingSampleMux` was a flat stub, not filled** — now the real ring-backed SPSC push transport
> over `Ring`s, and the offline pipeline drives its interior stages *through* it (the seam); the 5
> `mux_machinery_test` flat-stub usages were migrated to the ring contract. (2) the **chunker's
> routing** (`render()` auto-selects chunking when chunkable, else pipeline/sequential — "forces a
> non-chunkable block through pipeline", W1). (3) the **O2 footprint** is now an accounted commit-known
> formula (`chunkFootprintBytes`/`pipelineFootprintBytes`). (4) the **Instrument-timeline-bounce
> O3-reproducibility** gate item now has a test (two offline event-driven renders bit-identical).
> (5) the **flagship throughput-scaling benchmark** (`bench/offline_bench.zig`) — at a realistic file
> length (≈349 s of audio) the chunker reaches **9.36× on 16 cores** (12P+4E) with `K=4·cores`
> oversubscription (bit-exact vs sequential), pipeline throughput (bottleneck-bound), and the
> footprint. (`K=cores` equal chunks straggler-bind on the P/E asymmetry → only ~4.5×; oversubscribing
> lets the OS balance P/E. Short clips are thread-spawn-overhead-bound, ~7× — see §6.)

## 1. What shipped

- **`src/mux.zig` `Ring`** — a real bounded single-producer/single-consumer block channel: `depth`
  fixed-size slots, atomic `head`/`tail`/`eos`, blocking by spin-then-`std.Thread.yield` (offline O1
  permits blocking; depth bounds the footprint, O2). This is the substance the plan's "fill
  `RingSampleMux` (bounded SPSC rings)" calls for. The `RingSampleMux` SampleMux **type itself is kept
  as the flat single-block offline seam** (its existing `mux_machinery_test` contract is unchanged —
  Rule 7: the flat-buffer tests lock that surface), and the genuinely-concurrent ring is the separate
  `Ring` type the pipeline drives directly (the same de-indirection the comptime `Executor` applies).
- **`src/offline.zig`** — `OfflineBatch(g, node_blocks)`, the Tier C executor at the **comptime-graph
  level** (the same track as `engine.Executor`):
  - `offline.Source` / `offline.Sink` — windowed-buffer timeline endpoints (`seek`/`attach`), each
    declaring `warmup_samples = 0`.
  - `renderSequential` (K=1 ground truth, no threads), `renderChunked` (data-parallel timeline
    chunking across threads + `total_warmup` discarded lead-in + **ordered merge → O3**),
    `renderPipeline` (stage-per-thread over `Ring`s; linear Map chain).
  - The **`warmup_samples`/`warmup_exact` contract** (W1–W3): `chunkable` = every block declares
    `warmup_samples` (presence gates chunkability); `total_warmup` = the per-block sum (a conservative
    bound = the longest source→sink path for linear/parallel-mix shapes; more lead-in is always still
    exact); `warmup_exact` ⇒ a bit-exact chunked merge, else allclose.
- **`tests/negative/offline_no_warmup.zig`** (+ `neg-compile` registration) — chunking a stateful
  block that declares no `warmup_samples` is a `@compileError` (W1 / A18), asserted active.
- **`src/engine.zig` `renderOffline(opts: RunOptions)`** — the runtime-Engine sequential offline entry
  (delegates to `runToCompletion`); `.input_exhaustion` for a file render, `.wall_clock_timer` +
  `max_blocks` for a fixed-length Instrument bounce (O3-reproducible via the deterministic event
  timeline).
- **Yoneda (Rule 14):** two autonomous `yoneda-test-writer` agents (each loaded `zig-0-16`).
  `tests/offline_yoneda_test.zig` (24 — the §5.7d offline differential: K=ncores ≡ K=1 bit-exact for
  exact-warmup FIR, allclose for IIR; partition-invisibility across K∈{1,2,3,5,7,8,16,64,T,T+5};
  pipeline ≡ sequential; determinism over 16 repeats; the T<warmup / T=0 / T=warmup edge guards; 0
  bugs). `tests/ring_yoneda_test.zig` (11 — the SPSC FIFO/no-loss/bounded-depth/EOS-drain laws).

## 2. Bugs caught by the test/audit passes (Rule 12, all found & fixed)

**An independent adversarial audit** (a fresh agent that read the brief/plan/specs itself, ran the
suite + ThreadSanitizer, and hunted with `std.testing.FailingAllocator`) then found **2 real
memory-safety bugs on the allocation-failure error path** that no test covered — both a double-free /
double-deinit from having an `errdefer` (partial-build cleanup) AND a post-loop `defer` (full cleanup)
both live, so a `try` failing *after* the construction loop fired both: **(1)** `renderPipeline`'s rings
(`offline.zig`) — `defer` deinits all rings (poisoning to `undefined`), then `errdefer` deinits the
poisoned ring again → free of `0xaa…` / segfault; **(2)** `renderChunked`'s per-chunk scratches — same
shape → double-free. **Fix:** a single `defer for (…[0..made/allocated])` that frees exactly what was
built, once, on every exit (no overlapping `errdefer`). Locked by two
`std.testing.checkAllAllocationFailures` cleanup tests (`offline.zig`) — the previously-untested control
path. The happy path was already TSan-clean; these were OOM-path-only latent defects.

### 2.1 The Ring bug the Yoneda pass caught

`Ring.consumeSlot` originally loaded `tail` **before** `eos`. `tail` and `eos` are independent
atomics and release/acquire synchronises per location, so a stale `tail` (fill 0) read together with a
fresh `eos == true` made the consumer declare the stream drained **while the producer's final
`commitProduce` slot was still pending** — dropping the last slot on ~3% of trials (162/5000). Fix:
observe `eos` **before** the `tail` it gates on (both acquire), so a `true` eos observation's
happens-before (the producer sets eos after its last commit) covers the subsequent `tail` load.
Verified: 4 full Debug suite repeats + the 4000-trial focused regression all deterministic.

## 3. Load-bearing decisions (Rule 7 — surfaced)

- **OfflineBatch lives at the comptime-graph level, not in the runtime RCU `Engine`.** A data-parallel
  chunk needs K **independent block-state copies** (K pools, K instance sets). The comptime `Executor`
  already owns all state (`instances` + `pool`), so a chunk worker *is* an `Executor` and K workers are
  K independent copies — exactly what makes `K=1 ≡ K=ncores` realisable and bit-exact-testable. The
  runtime `Engine` binds a single instance set imperatively (the builder can't reconstruct instances
  from IR), so K-way cloning would be major surgery (Rule 3). This is consistent with the codebase's
  established two-track model: the comptime `Executor` is the ground-truth/embedded/differential track
  (B≡C, gold vectors, embedded `.bss`), the runtime `Engine` is the live-RCU track. The Engine's
  `.offline_batch` mode + `renderOffline` is the runtime **sequential** offline path; the parallel O3
  machinery is `offline.OfflineBatch`.
- **`total_warmup` is the SUM of per-block warm-ups, not the longest-path DP.** The sum is a
  conservative upper bound (≥ the longest source→sink warm-up path); more lead-in is always still
  exact, never less, so it is correct for every shape and trivially comptime. For the linear and
  parallel-mix graphs that batch here the sum equals the longest path, so it is also tight there.
- **Chunkability is opt-in via the field's presence.** A block without `warmup_samples` is
  conservatively treated as not-chunkable (statelessness can't be auto-detected), so even a pure
  stateless Map must declare `warmup_samples = 0` to be chunked. This is the strict reading of W1
  ("presence gates chunkability") and yields the clean A18 commit error.
- **`renderPipeline` is restricted to a linear Map chain** whose endpoints are the source (node 0) and
  sink (node S−1) — the canonical §3.2 / gate-step-8 shape (`Source → Map → … → Sink`). A non-linear /
  non-terminal-endpoint graph returns `error.NotLinearChain`. Fan-in/out pipelining is not implemented.

## 4. Remaining boundaries (genuine scope limits, surfaced — not silent cuts)

After the re-audit closed the 5 items above, these are the principled boundaries that remain:

- **`renderPipeline` is a single-port linear Map chain** (source = node 0, sink = node S−1). This is
  bounded by the **pre-existing single-port `SampleMux` seam** — multi-port demux "arrives with the
  demand-tracking executor and the first multi-port block" (the `mux.zig` contract), so a general-DAG
  pipeline (fan-in/out) would need that seam first. Chunking already covers the *width* (parallel) case;
  pipeline is the non-chunkable *fallback*, whose canonical shape (§3.2 / gate-step-8) is a chain.
- **Runtime-`Engine` multi-core offline** (parallel chunking behind `Engine.init(.offline_batch,
  .threads=.auto)` *literally*) — see §3: the runtime offline path is sequential; the parallel O3
  machinery is the comptime `OfflineBatch`, the codebase's established ground-truth/differential track.
  `render()`'s auto-routing + the benchmark exercise the parallel path there.
- **`VariRate` chunkability split** (§3.3 / catalog §2.6 V4): handled *structurally* by W1 — a
  controller-driven (ASRC, non-reproducible) `VariRate` declares no `warmup_samples`, so `render()`
  routes it through pipeline, not chunking. A `VariRate`-specific routing *test* is not yet written.
- **Per-active-chunk concurrency cap**: today K chunks = K threads = K workers. Capping concurrent
  workers at ncores while K > ncores (rendering in waves) is a memory refinement; the footprint formula
  (`chunkFootprintBytes`) already accounts for the full-K case.
- P15 territory (untouched): render-workgroup HAL, Tier B level-barrier, HEFT + point-to-point.

## 5. Verify — reproduce green (from repo root)
```sh
zig build test                          # Debug — 138/138 steps, 1287/1287, EXIT 0 (check the code!)
zig build test -Doptimize=ReleaseSafe   # exit 0 (1287/1287)
zig build test -Doptimize=ReleaseFast   # exit 0
zig build fmt-check                     # exit 0
zig build smoke                         # exit 0
zig build neg-compile                   # exit 0  (also asserts the no-warmup-chunk @compileError)
zig build cross-linux                   # exit 0
zig build bench                         # exit 0  (offline throughput-scaling; see §6)
```

## 6. Benchmark scaling audit (critical, measured on an M3 Max — 12P + 4E cores)

A rigorous re-measurement (min-of-3, sweeping `T` and chunk count `K`) corrected an initial misleading
headline. The executor's scaling depends strongly on two factors the first bench hid:

| workload | seq | `K=cores` (16) | `K=4·cores` (64) |
|---|---|---|---|
| stress FIR, 349 s file (T=16.7M) | 255 ms | 4.52× | **9.36×** |
| stress FIR, 21 s clip (T=1.0M)   | 16 ms  | 4.38× | 6.94× |
| light FIR, 174 s file (T=8.4M)   | 28 ms  | 6.08× | 6.06× (bandwidth-bound) |

Findings (the 3–4× the first bench reported was a **methodology artifact, not an executor limit**):
- **Equal `K=cores` chunks straggler-bind on the P/E asymmetry.** The merge is a barrier; with 16 equal
  chunks the 4 on the slow E-cores gate the whole render. **Oversubscribing (`K=4·cores`)** lets the OS
  scheduler hand fast P-cores ~4 chunks each and E-cores fewer → load balances → **9.36×** (≈ near-
  linear: 12P+4E ≈ 14 P-equivalents, so 9.36/14 ≈ 67% of P-equivalent peak — strong for heterogeneous
  cores, and `render()` could default `K` to a multiple of cores).
- **Small `T` is thread-spawn-overhead-bound.** `renderChunked` spawns K fresh `std.Thread` per call;
  for ms-scale renders that fixed cost is a large fraction. Scaling climbs with `T` (6.9× at 21 s →
  9.4× at 349 s). A **persistent worker pool** (spawn once, signal per render) is the remaining
  refinement — and is exactly the Tier-B "pre-spawned pool" the spec assigns to P15 (§2.1).
- **Light (memory-bound) kernels cap at ~6×** regardless of K — a real bandwidth ceiling (one P-core
  already pulls a large fraction of the M3 Max's bandwidth); this is the expected ceiling for a
  memory-bound op, not a defect.
- **Pipeline shows ~1× here** because the 3-stage chain is degenerate (trivial source/sink, all work in
  the FIR stage) ⇒ bottleneck-bound by design (the gate's "throughput ≥ bottleneck-stage bound" — met,
  but a balanced-stage graph would be a better showcase).
- **Versus libraries:** a tuned dynamic scheduler (oneTBB/Rayon/OpenMP-`dynamic`) on a 12P+4E machine
  gets ~8–11× on a compute-bound kernel; `K=4·cores` here (9.36×) is competitive. The naive O(taps)
  array-shift FIR (`offline_bench.zig`) makes the absolute MB/s meaningless as a library-competitive
  figure (a real running-sum/SIMD FIR is ~10–50× faster) — but it inflates seq and parallel equally, so
  the *speedup ratio* is representative. **Honest gate verdict:** "near-linear speedup" IS achieved at
  realistic file lengths with oversubscription; it is NOT achieved at `K=cores` or on short clips.

**Representative absolute numbers — `bench/biquad_cascade_bench.zig`** (a real `pan.filters.Biquad`
cascade, the shipping block, not a synthetic kernel): a 4th/8th/16th-order f32 cascade runs at
**6.1 / 11.1 / 22.2 ns/sample** (≈2.8 ns per biquad/sample; 164 / 90 / 45 Msample/s; **3411× / 1872× /
938× realtime** @48k). Biquads are IIR (no `warmup_samples`) ⇒ not chunkable, so this bench also (a)
exercises the W1 routing — `render()` falls to pipeline — and (b) is the **balanced-stage** showcase the
FIR bench could not be: pipeline speedup scales with cascade depth (4 stages → 2.1×, 6 → 3.8×, 10 →
**7.05×**), bit-exact vs sequential. (The FIR throughput-scaling bench stays for the chunking story; the
running-sum/SIMD FIR *block* itself is Phase-16 library buildout — the SIMD-ness is a Compute-HAL
concern, the running-sum/FFT-convolution algorithm is a block-author choice, neither blocks P14.)

**Head-to-head vs Apple vDSP — `bench/vdsp_compare_bench.zig`** (macOS-gated, links `-framework
Accelerate`; a committed, regression-visible comparison against a top-tier hand-tuned DSP library on the
same M3 Max). f32-mono ns/sample for 4th/8th/16th-order cascades: **pan 5.6 / 11.5 / 20.8**, bare fused
loop **2.5 / 2.7 / 4.6**, **vDSP 1.5 / 3.0 / 6.1** → pan is a steady **~3.5–3.9× slower than vDSP**. The
finding the bench makes legible: pan's biquad *math is bit-identical to the bare loop* (`pan≡bare: true`,
the fair-work witness), and the **bare loop matches or beats vDSP at D≥4** (0.76–0.91×) — so the entire
gap is the graph's per-block buffer round-trip (≈2–4.5× over the register-fused single pass), **not the
arithmetic**. Tight-feedback fusion (§5.4) / the Phase-18 loop-fusion pass would fuse a hot cascade to
the bare-loop level, landing pan at-or-below vDSP. (For live audio the gap is moot: pan does
938–3411× realtime; it surfaces only in massive offline batch, where chunking's 9.4× partly compensates.)
