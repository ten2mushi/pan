# Handoff — end of Session 14 (P15 "RealtimeStreaming multicore (Tier B): workgroup HAL, HEFT, point-to-point, auto-demote") → into P16

> **Status:** P0–P14 + **P15 implemented and green.** The static-parallel Tier-B overlay ships:
> the Render-Workgroup HAL, the cost-model gate, the op-DAG (RAW + WAR + WAW anti-deps), the
> level-barrier and HEFT executors with point-to-point ready-flags, the worker pool (generation-wake,
> realtime-token ×P, workgroup membership), per-worker spin telemetry, and telemetry-gated auto-demote.
> The **parallel≡sequential differential is bit-exact** (both executors, P=2..ncores), the cost-gate
> refuses a near-linear chain, HEFT's makespan ≤ the level-barrier's, and `bench/parallel_bench.zig`
> measures **3.85× speedup at P=4** on a wide 16-heavy-chain stress graph. Advisory handoff, not a spec:
> `specifications/` + `pan_implementation_plan.md` remain the source of truth.
> **Date:** 2026-06-05. **Toolchain:** `zig 0.16.0` (re-run `zig version` at P16 start — Rule 13).

---

## 1. Ownership statement (honest, Rule 12)

The P15 **gate** (plan §15 success criteria):
- **2-worker spin handshake, bounded wait, spin-time telemetry present** — `WorkerPool` + `ReadyFlags`
  + `SpinTelemetry`; tested (`parallel_*_test.zig`) incl. 500-dispatch handshake, TSan-clean. ✅
- **A wide graph shows measured speedup** — `bench/parallel_bench.zig`: 3.85× at P=4 (level-barrier and
  HEFT), bounded spin. ✅
- **Tier B output bit-identical to Tier A (parallel≡sequential, P=2..ncores)** — the differential is
  `expectEqualSlices(u8, …)` over many blocks and shapes; per-edge plan ⇒ no cross-worker buffer reuse
  by construction. ✅
- **Cost-gate refuses a near-linear chain (W/S≈1)** — `costGate` tested; the engine refuses a chain
  (`!tierBActive()`, parallelism < θ). ✅
- **HEFT beats the level-barrier on a wide→narrow→wide graph** — `heft.makespan ≤ level.makespan`
  asserted. ✅
- **Auto-demote triggers under induced overload** — `DemotePolicy` hysteresis tested; wired to engine
  deadline-headroom telemetry. ✅
- **Zero xruns over 10 min** — on-device (no audio HW in the sandbox), deferred like prior device gates.
  ⚠️

**Yoneda dispatch (Rule 14):** two autonomous `yoneda-test-writer` agents (each loaded `zig-0-16`).
**73 tests; 1 real src bug found & fixed:** a **use-after-free in `Engine.installPlan`** (the `recommit`
path) — `new_bound` aliases `self.bound`, `free(old_bound)` released it, then `tb.rebind(…,new_bound,…)`
read freed render thunks → misaligned `fn_ptr` panic. Fixed by rebinding Tier B from the freshly-duped
live `self.bound`. The regression guard is armed and green (+ TSan).

Full suite green: **Debug / ReleaseSafe / ReleaseFast / fmt-check / smoke / neg-compile / cross-linux all
exit 0**, plus `tests/parallel_concurrent_yoneda_test.zig` clean under `-fsanitize-thread`.

---

## 2. What was built (the deltas)

```
src/parallel.zig   (NEW)  the whole Tier-B core: Workgroup HAL {detect,withHandle,join(token),leave};
                          costGate (decidable busy∧parallel∧workgroup, sizes P); buildDag (RAW+WAR+WAW
                          anti-deps); CostModel/totalWork/span; levelSchedule + heftSchedule (+ Barrier,
                          ReadyFlags); WorkerPool (gen-wake, token×P, workgroup, `live`-gated join);
                          replayParallel/replayWorker (type-erased RunOp); SpinTelemetry; DemotePolicy.
src/engine.zig     (M)   `TierB` overlay (heap; owns its OWN .per_edge plan + pool + worker pool),
                          `renderTierB` routes Tier B vs Tier A under the gate+demote; `RunCtx`/`runOneOp`;
                          `buildBoundPlanMode(mode)` (colored | per_edge); `tierBActive/tierBWorkers/
                          tierBParallelism/currentPlan` accessors; spin_time telemetry; rebind on
                          edit→commit/reconfigure (demote across the swap). EngineOptions += cores,
                          tier_b_executor, force_workgroup, gate.
src/builder.zig    (M)   `commitWith(opts: EngineOptions)` — the Tier-B commit entry.
src/root.zig       (M)   exports `pan.parallel`, `Workgroup`, `GateConfig/Decision`, `costGate`,
                          `TierBExecutor`.
tests/parallel_tier_b_test.zig            (NEW, 12 — the self-authored gate: differential + wide FEEDBACK
                          comb bank (z⁻¹ persistent tail) + concurrency-coloring footprint)
tests/parallel_pure_yoneda_test.zig       (NEW, 53 — Yoneda: HAL/gate/DAG/schedules/demote; 0 bugs)
tests/parallel_concurrent_yoneda_test.zig (NEW, 20 — Yoneda: pool/barrier/ready-flags/replay/engine
                          differential/edit-reconfigure; TSan; caught the installPlan UAF)
tests/parallel_ratparam_yoneda_test.zig   (NEW, 8 — Yoneda: Rate-block round-trip + wired param-edge
                          under Tier B, both PROMOTING bit-exact; the deterministic futex cold-park; TSan)
bench/parallel_bench.zig (NEW)  Tier-B throughput scaling vs P (3.93× at P=4), spin time, footprint.
build.zig          (M)   the four test harnesses + the bench.

The ownership re-audit additions to src/parallel.zig + src/engine.zig (beyond the first pass):
  · the REAL Render-Workgroup platform bindings (macOS os_workgroup extern; Linux SCHED_FIFO+affinity);
  · the futex cold-worker park (raw linux futex / macOS __ulock; std futex moved into std.Io in 0.16);
  · `concurrencyColor` (schedule-time interval coloring) + `buildDagOrdered` + Kahn `topoOrder` (the
    schedulers became order-agnostic), and the engine's TWO-PASS `buildFor` (gate on the per-edge DAG,
    recolor on the preliminary schedule, rebuild the DAG in schedule order, final schedule);
  · `CostModel.cost_e` (P/E asymmetry) + `refineE`/`refineAll` EWMA hooks.
```

## 3. Verify — reproduce green (from repo root)
```sh
zig build test                          # Debug — exit 0 (check the exit code, never "X/X passed")
zig build test -Doptimize=ReleaseSafe   # exit 0
zig build test -Doptimize=ReleaseFast   # exit 0
zig build fmt-check                     # exit 0
zig build smoke                         # exit 0
zig build neg-compile                   # exit 0
zig build cross-linux                   # exit 0
zig build bench                         # exit 0  (Tier-B scaling: 3.85x @ P=4)
# concurrency paranoia:
zig test -fsanitize-thread --dep pan -Mroot=tests/parallel_concurrent_yoneda_test.zig -Mpan=src/root.zig
```
ALWAYS redirect to a file, never `| tail` — the pipe masks zig's exit code (the P10 false-green lesson).

## 4. The load-bearing design decisions (Rule 7 / Rule 12) — surfaced

- **Tier B runs its OWN per-edge (non-coalesced) plan + pool, NOT the engine's colored plan.** A colored
  pool reuses one buffer id across independent voices; `buildDag`'s correct WAW/WAR anti-deps on those
  shared colors then re-serialize the voices → parallelism = 1. Per-edge gives each value its own buffer
  ⇒ real parallelism, and per-edge ≡ colored bit-exact (the colorer is a memory-reuse optimization), so
  the parallel≡sequential differential is BIT-EXACT. This is the spec's "M_class grows to peak concurrent
  live edges" footprint (per-edge is its conservative upper bound).
- **Auto-demote is a per-callback branch, not an RCU plan swap.** Block-internal state lives in shared
  instances; feedback-free graphs (the Tier-B targets) have no pool-resident z⁻¹, so flipping `tb.active`
  is seamless. Only pool-tail z⁻¹ feedback would click for one block on a demote — absent for voice banks.
- **Engine promotion uses the deadline-FREE structural parallelism (work/span), not the full costGate.**
  The static byte-cost model has no time units, so the busy test + P-from-load need live headroom (the
  on-device path); `costGate` is the full decidable gate, tested as a pure function.
- **Level-barrier is the default executor** (deadlock-free by construction); HEFT is opt-in and relies on
  the standard static-schedule deadlock-freedom argument with the differential test as the net.

## 5. Residuals / boundaries (principled, surfaced — not silent cuts)

A prompted ownership re-audit (this same session) CLOSED the six gaps the first pass left: the Linux
SCHED_FIFO+affinity workgroup path, the macOS `os_workgroup_join`/`leave` extern bindings, the futex
cold-worker park, the concurrency-aware coloring (A15/A16, schedule-time interval coloring — footprint
shrink, bit-exact), the P/E `cost_e` + EWMA telemetry hooks, and the §2.9 feedback/Rate/param-edge
under-Tier-B differentials. What genuinely remains:

- **On-device verification of `os_workgroup_join` + the 10-min-zero-xrun device run** — the extern
  bindings compile/link (libsystem on Darwin) but a real device workgroup handle and the live run need
  audio HW (not in the sandbox). `force_workgroup=true` drives Tier B for dev/bench/test with the honest
  weaker (demote-policy-only) bound; `detect()` returns available on Linux (SCHED_FIFO is present).
- **P/E-split-AWARE HEFT placement** — `CostModel.cost_e` + `refineE` carry the asymmetry, but applying
  it (placing E-core-cheap ops on E cores) needs on-device core-type topology; macOS gives no userland
  core-type control, so the placement is core-type-agnostic for now (≈, on-device refinement).
- **Tier A↔B demote click-free only for feedback-free graphs** (the targets) — a graph with pool-tail z⁻¹
  feedback may click for one block on a demote (Tier A and B keep distinct pools; block-internal state is
  shared, only pool-tail z⁻¹ diverges).
- From earlier phases: live MIDI device HAL + on-device runs; `Num`-generic fixed-point voice tier;
  multi-channel (planar) voices; external transport sync.

## 6. What P16 needs (from plan Phase 16)

P16 = **DSP & spatial library buildout + layout negotiation** (the bulk of the usable block taxonomy,
the namesake spatial "pan" core, registered up/down-mix matrices + negotiation tests). Read first: plan
§16; `pan_categorical_bridge_and_roadmap.md` §2 (block taxonomy); `catalog.md` §1.3 (L1/L2/L3 layout),
§6 (negotiation coercion table); `pan_type_and_numeric_model.md` §2.1 (channel model / geometry as block
data); `pan_testing_and_vector_contract.md` §5.7e (layout negotiation tests). Most blocks here are
independent and parallelizable across dispatched implementers; the SciPy/oracle gold-vector + dual-mux
discipline applies per block.
