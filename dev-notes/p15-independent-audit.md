# P15 (Tier B / RealtimeStreaming multicore) — independent audit

An independent auditor (a fresh agent given the brief, the implementation plan, the
specifications, and the code, instructed to reach its own verdict and hunt for bugs —
*not* told the implementer's conclusions) reviewed Phase 15. This note records its
findings, the follow-up actions taken, and a full cross-reference of the files relevant
to understanding and questioning the phase.

**Environment:** `zig 0.16.0`, `zig-0-16` skill loaded. Every judgement was confirmed by
reading the code and by compiling/running, not by recall.

---

## 1. Verdict

> **P15 is substantially and correctly implemented.** Coverage ≈ **92%** fully
> implemented, ≈5% partial/documented-simplification, ≈3% legitimately device-deferred.
> **Confidence: HIGH** for what is present (read every relevant line; compiled; ran;
> TSan-clean; meaningful bit-exact + promotion-asserting tests). **Medium** that no
> concurrency bug survives that manifests *only* under real OS co-scheduling contention —
> which is exactly the ▷/≈ honesty boundary the spec itself draws, with auto-demote +
> Tier-A fallback bounding the worst case to "runs as Tier A."

The auditor found **no data races, deadlocks, lost-wakeups, or torn-pool bugs**, and
verified the green is genuine (the 8 `error:` lines in the Debug log are all intentional
must-fail fixtures: the aliasing-message contract tests + the three `expectExitCode(1)`
negative-compile gates).

## 2. Test-run results observed by the auditor (exit codes — the source of truth)

| Command | Exit |
|---|---|
| `zig build test` (Debug) | 0 |
| `zig build test -Doptimize=ReleaseSafe` | 0 |
| `zig build test -Doptimize=ReleaseFast` | 0 |
| `zig build fmt-check` | 0 |
| `zig build cross-linux` | 0 |
| TSan `parallel_concurrent_yoneda_test` (20/20) | 0 |
| TSan `parallel_tier_b_test` (12/12) | 0 |
| TSan `parallel_ratparam_yoneda_test` (8/8) | 0 |
| `parallel_bench` built + run | 0 (≈3.9× at P=4; spin telemetry present) |

It confirmed the differentials are **not vacuous**: each asserts `tierBActive()` and
`tierBWorkers() ≥ 2` *before* a **byte-exact** `expectEqualSlices(u8, …)` comparison over
8–16 blocks, both executors, P=2..ncores, across wide / diamond / 16-voice / feedback-comb
/ Resampler / wired-param-edge graphs.

## 3. The one genuine gap it found — and the fix applied

**GAP — paranoid NaN-poison was not wired into the *runtime* Tier-B path.** §2.8 / §5.7c /
B9 name a paranoid net (NaN-poison released buffers, extended to catch a cross-worker
buffer reused before its last reader across the concurrency-aware interference graph). It
existed only in the *comptime* `ExecutorModeParanoid` (`src/engine.zig:250`, the fill at
`:308`, gated on `buffer_last_use` at `:322`); the runtime engine render path
(`runOneOp`/`replayBound`) did not poison, and `concurrencyColor` even set color buffers'
`buffer_last_use = op_count` (never poisoned mid-render). Impact: a real coverage shortfall
vs. the committed spec text — correctness was guaranteed only by the (strong, byte-exact,
TSan-clean) differential, not by the named extra net.

**FIX (applied after the audit):** wired the poison into the runtime Tier-B path with a
**per-buffer reader-completion counter** — correct for a *parallel* schedule where
concurrent readers have no finish-order (so the comptime "poison after the schedule-last
reader" would race). The producer stores the value's reader count
(`parallel.computePoison`, `src/parallel.zig:993`), each reader atomically decrements after
reading, and the reader that brings the count to zero (the last to *finish*, race-free for
any interleaving) NaN-fills the scratch buffer (`engine.paranoidPostOp` `:854`,
`poisonReads` `:872`); persistent z⁻¹ buffers are never poisoned. It runs after each op on
both executors before the publish/barrier (`replayWorker` `src/parallel.zig:1360`), gated
by guards (`renderTierB` `:1744`). The Debug differentials now *exercise* it and stay
bit-exact (poison touches only dead buffers); `tierBPoisonFills() > 0` (`engine:2180`) is
asserted so it is provably active, not a no-op (`tests/parallel_tier_b_test.zig`, the
"paranoid poison" test).

## 4. The minor/documented items it noted (no action required)

- **Engine promotes on a deadline-free *structural* gate, not the full `costGate`.**
  `buildFor` (`src/engine.zig:1052`) decides on `parallelism ≥ θ_speedup ∧ workgroup` and
  sizes P from `round(parallelism)`, omitting the `W > deadline·θ_busy` busy test and the
  load-based P sizing — *by design*, since a static commit has no live deadline; the full
  `costGate` (`src/parallel.zig:222`) exists and is unit-tested and is the on-device path.
- **`Σ_worker scratch` footprint term is structurally 0** — no current block declares
  op-internal transient scratch, so the additive term (§8.11 / catalog §7.8) is vacuously
  zero; the mechanism is stated but not exercised. Not a bug.
- **`rebind` lifetime after edit/reconfigure** rests on `active.store(false)` before the
  swap + the synchronous `dispatch` (the caller blocks until all workers finish), not on a
  grace wait for the per-edge plan — sound as written (the L7 recommit/reconfigure-under-
  active-Tier-B tests pass under TSan), noted only because the argument is subtle.

## 5. Device-bound deferrals (legitimate, not unimplemented)

The live `os_workgroup_join` syscall with a real device handle, the 10-minute zero-xrun
run, and an induced-overload auto-demote run all require audio hardware absent from the
build host. The extern bindings compile/link; `force_workgroup=true` drives Tier B for
dev/bench/test with the honest weaker (demote-policy-only) bound.

---

## Context reference

Everything needed to understand — and question the specification design of — Phase 15.
Line numbers are at the time of writing (`zig 0.16.0`).

### Project intent
- `notes/brief.md:5` maximize throughput · `:6` minimize latency · `:9` HAL (Apple
  Silicon M3 / Linux / embedded) · `:10` streaming LPCM I/O · `:11` configuration-driven.

### Implementation plan
- `pan_implementation_plan.md:979` **Phase 15 header** — RealtimeStreaming multicore (Tier B).
  - `:981` Goal (roadmap steps 10–12) · `:985` "Read first" (the spec map) ·
    `:1002` Work items (`src/parallel.zig`, `src/realtime.zig`) · `:1016` Success criteria
    (the gate) · `:1022` Yoneda dispatch · `:1025` Benchmark.
- `pan_implementation_plan.md:1031` Phase 16 (the next phase, for boundary context).

### Specifications (the design source of truth — question these)
- `specifications/pan_parallel_and_offline_execution.md`
  - `:90` §2 Tier B (overview) · `:100` §2.1 foundation (worker pool, gen-wake, token×P,
    workgroup) · `:119` §2.2 work/span/HEFT · `:141` §2.3 cost-model gate + choosing P ·
    `:161` §2.4 point-to-point ready-flag orderings · `:186` §2.5 concurrency-aware
    coloring + 4th in-place condition · `:213` §2.6 honest wait-freedom bound ·
    `:234` §2.7 auto-demote · `:244` §2.8 bit-exactness + the parallel≡sequential test ·
    `:257` §2.9 feedback/Rate/param invariance · `:271` §2.10 level-barrier fallback ·
    `:401` §4 the render-workgroup HAL · `:423` §5 the A14–A20 / B9–B13 / C10–C13 ledger ·
    `:453` §6 roadmap & success criteria · `:472` §7 what the spec pins down.
- `specifications/pan_concurrency_and_memory_ordering.md:397` §4a — the Tier-B ready-flag
  RF-W/RF-R orderings (and `:277` §4 RCU swap the idiom mirrors, `:437` §5 H1 wait-freedom).
- `specifications/pan_memory_model.md:221` §8a — concurrency-aware coloring under Tier B;
  `:245` the paranoid-poison extension across the interference graph; `:297` the footprint
  addendum (peak-concurrent `M_class` + `Σ_worker scratch`).
- `specifications/catalog.md:691` §7.4 in-place coalescing (the 3 conditions Tier B adds a
  4th to) · `:729` §7.8 the footprint formula + Tier-B addendum · `:875` §8.10 execution
  modes & the Executor triple (C6/C7) · `:903` §8.11 concurrency-aware coloring (⊢, A15/A16)
  · `:1146` §12 the correctness ledger (A14–A20 / B9–B13 / C10–C13).
- `specifications/pan_io_realtime_and_pipeline.md:226` §10 telemetry (spin_time, headroom,
  guards_compiled_out) · `:251` §11 the three HALs · `:265` the Render-Workgroup HAL table.
- `specifications/pan_testing_and_vector_contract.md:313` §5.7c parallel≡sequential (bit-exact
  + paranoid) · `:405`/`:477`/`:480` the harness ledger rows for Tier B + the workgroup HAL.

### Code — the Tier-B core (`src/parallel.zig`)
- `:88` `Workgroup` HAL (`:131` macOS `os_workgroup_join` seam, `:160` extern decls,
  `:166` `setLinuxRtScheduling` SCHED_FIFO+affinity) — §4.
- `:222` `costGate` (decidable gate) — §2.3. · `:265` `Dag`, `:287` `topoOrder` (Kahn),
  `:326` `buildDag` / `:339` `buildDagOrdered` (RAW+WAR+WAW; schedule-order rebuild) — §2.5.
- `:405` `CostModel` (cost + `cost_e` P/E + EWMA `refine`) · `:479` `span` — §2.2.
- `:510` `Schedule` · `:589` `levelSchedule` (+ `Barrier`) · `:668` `heftSchedule` — §2.2/§2.10.
- `:816` `concurrencyColor` (schedule-time interval coloring) — §2.5/§8.11/§8a.
- `:984` `PoisonPlan` / `:993` `computePoison` — §2.8 paranoid net.
- `:1047` `ReadyFlags` (RF-W/RF-R) — §2.4/§4a. · `:1089` `ParkWord` (futex cold-park) ·
  `:1128` `WorkerPool` (gen-wake, token×P) · `:1288` `Barrier`.
- `:1360` `replayWorker` (both executors + poison hook) / `:1406` `replayParallel`.
- `:1445` `DemotePolicy` (hysteresis) — §2.7.

### Code — the engine integration (`src/engine.zig`)
- `:125` `RealtimeToken` / `:140` `enterRealtimeThread` (FTZ ×P) — §2.1.
- `:833` `RunCtx` · `:854` `paranoidPostOp` / `:872` `poisonReads` (the new poison fill) ·
  `:893` `runOneOp` (per-op runner).
- `:915` `TierB` overlay struct · `:972` `create` · `:1012` `rebind` (edit/reconfigure) ·
  `:1052` `buildFor` (two-pass: gate → prelim schedule → recolor → rebuilt DAG → final) ·
  `:1103` `ensureSpawned`.
- `:1148` `EngineOptions` (cores / tier_b_executor / force_workgroup / gate).
- `:1561` `buildBoundPlanMode` (`.colored` Tier-A vs `.per_edge` Tier-B plan).
- `:1720` `renderCurrent` (routes Tier B vs Tier A) · `:1744` `renderTierB` (the parallel
  render + poison wiring).
- `:1943` `installPlan` (edit→commit RCU swap; `:2010` `tb.rebind`) · `:2021` `reconfigure`
  (`:2065` `tb.rebind`).
- Accessors: `:2141` `tierBActive` · `:2148` `tierBWorkers` · `:2154` `tierBParallelism` ·
  `:2160` `currentPlan` · `:2167` `tierBScratchBytes` · `:2180` `tierBPoisonFills`.
- The COMPTIME paranoid executor the gap was measured against: `:250` `ExecutorModeParanoid`
  (`:308` the fill, `:322` the `buffer_last_use` gate).

### Code — surface + build
- `src/builder.zig:346` `commitWith(opts)` (the Tier-B commit entry).
- `src/root.zig:148` `pub const parallel` · `:149` `Workgroup` · `:152` `costGate` ·
  `:153` `TierBExecutor`.
- `build.zig:130–133` the four parallel test harnesses · `:259` `bench/parallel_bench.zig`.

### Tests & benchmark
- `tests/parallel_tier_b_test.zig` — the self-authored gate (differential, wide FEEDBACK
  comb bank z⁻¹, concurrency-coloring footprint, the paranoid-poison test).
- `tests/parallel_pure_yoneda_test.zig` — HAL/gate/DAG/schedules/demote unit laws.
- `tests/parallel_concurrent_yoneda_test.zig` — pool/barrier/ready-flags/`replayParallel`/
  engine differential/edit-reconfigure (TSan; caught the `installPlan` UAF).
- `tests/parallel_ratparam_yoneda_test.zig` — Rate-block + wired-param-edge under Tier B
  (both promoting, bit-exact) + the futex cold-park.
- `bench/parallel_bench.zig` — throughput scaling vs P (see `dev-notes/p15-streaming-bench-report.md`).

### Companion dev-notes
- `dev-notes/p15-streaming-bench-report.md` — the bench results + critical analysis
  (cost-model P-undersizing, no-workgroup E-core regression, library comparison).
