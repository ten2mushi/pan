# pan — Implementation Readiness & Pre-Flight Checklist

> **Status:** advisory / kickoff planning (NOT a locked spec — defers to `specifications/`).
> **Date:** 2026-06-03. **Context:** written after the spec corpus reached "dual-purpose engine"
> (commit `d44cc5d`); the `specifications/` corpus is the single source of truth, this file only
> sequences the work of realising it.
> **Verdict:** **ready to start**, after settling the small set of decisions below.

---

## 0. Grounded current state (what's actually true today)

- **Toolchain:** `zig 0.16.0` installed ✓ — matches `build.zig.zon` `minimum_zig_version` and the
  entire corpus (which targets 0.16.0 exactly). Re-verify with `zig version` before each session;
  the language drifts hard between releases (Rule 13 / the `zig-0-16` skill).
- **Skeleton exists and builds:** `src/{types,numeric,port,mux,graph,commit,engine,pan}.zig`
  (`zig build` is silent-success). One gold vector exists (`tests/vectors/gain_f32`), unused.
- **The skeleton predates the 2026-06-03 amendments.** A grep-level scan (not yet a line-by-line
  read) shows **0** occurrences of `ChannelLayout`, `VariRate`, `EventLane`/`NoteEvent`, `PolyVoice`
  in `src/`, and the channel element is still **count-based**, not `Frame(Lane, L)`. Code and spec
  have diverged.
- **The commit pass is the load-bearing gap.** `commit.zig` has the SCC-has-delay check
  (`error.DelayFreeLoop`) but **lacks** topological sort, liveness, per-element-class interval
  coloring (left-edge), PDC longest-path, and op-list emission. `engine.zig`'s `renderInto` is a
  no-op (fn-ptrs null). No real DSP blocks (Gain/I2S are identity stubs). No I/O HAL.
  → Implementation is at roadmap **step 1 scaffolding**, not yet at the step-1 vertical slice
  ([bridge §5](../specifications/pan_categorical_bridge_and_roadmap.md)).

> ⚠️ My view of `src/` internals is a grep-level scan. **First artifact should be a line-by-line
> `src/` audit** (see §6) before committing to a reconciliation diff.

---

## 1. Must-decide before block code (3)

### 1.1 Skeleton ⇆ spec reconciliation strategy
The amendments aren't in `src/` yet. **Don't retrofit everything now.** Make the one *foundational*
thing layout-ready and fold the rest in at their own feature steps:
- [ ] **Now:** make `Frame(Lane, L)` / `ChannelLayout` the channel element (every edge keys off the
  element type, so this is load-bearing) — `catalog.md` §1.3 (L1/L2/L3).
- [ ] **At their steps:** `VariRate` (§2.6, with step 5 / sampler), `EventLane(Event)` + `NoteEvent`
  (§8.6, with step 6d), `PolyVoice` (§8.12, step 6d). The step-1 trio (Gain/Biquad/Pan) only needs
  `.mono`/`.stereo`, so it is **not** blocked by the others.
- [ ] Decide: evolve `src/` in place, or branch a `v2-core` reconciliation. (Recommend: in place,
  small PRs.)

### 1.2 Pin the public API surface
The DX doc repeatedly flags the builder/engine identifiers as *"plausible surface, not pinned."*
Commit to concrete names in a thin `root.zig` **before** the vertical slice, then promote the DX doc
from *illustrative* to *matches code*. Concretely, pin:
- [ ] `Config { precision, sample_rate, block_size, channels(→ChannelLayout) }` + `numericFor(precision, …)` (comptime).
- [ ] `Graph.init / add / connect / commit` → `Engine`. Multi-port `node.in(i)` / `node.in.<name>` typed `PortId`s.
- [ ] `Engine.start / stop / renderInto(token, mem, out) / renderOffline / telemetry()`.
- [ ] Control verbs: `set` (atomic+ramp, **no** `at_sample`), `schedule` (SPSC, sample-accurate), `edit`→`commit` (RCU).
- [ ] Mux family names: `TestSampleMux / PullTestSampleMux / PullSampleMux / RingSampleMux`.
- [ ] `enterRealtimeThread()` token type; `telemetry` struct (`xrun_count`, `deadline_headroom`, `guards_compiled_out`, …).

### 1.3 De-risking entry point — offline-first, not CoreAudio-first
Roadmap step 1 leads with CoreAudio, but the highest-value/highest-uncertainty core is the
**commit pass + render replay**, gated by the SciPy oracle and the B≡C differential test. De-risk
*all* of that on the **file→file offline path** — deterministic, bit-exact, zero device/RT
complexity — then add CoreAudio as a separable, thinner risk.
- [ ] Confirm: build & validate the commit pass offline first (reorders roadmap 1/4/7), CoreAudio after.

---

## 2. Do early, cheaply (2)

### 2.1 Stand up the gold-vector + dual-mux harness now (Rule 9 / Rule 14)
`generate.py` + `gain_f32` exist but are unused. Wire the test backbone from block #1 — it is
painful to retrofit and it is the "tests as definition" contract.
- [ ] `GoldVectorTester` driving `vectors/**` against `TestSampleMux` **and** `PullTestSampleMux`
  (dual-mux), float=allclose / integer=bit-exact ([testing §5](../specifications/pan_testing_and_vector_contract.md)).
- [ ] `B≡C` differential harness (mode B per-edge buffers vs mode C colored pool, bit-identical) +
  paranoid NaN-poison mode — the **primary correctness check** for the colorer ([catalog §7.5](../specifications/catalog.md)).
- [ ] Per Rule 14, dispatch **Yoneda test-writers** (each told to load `zig-0-16`) at each gate as
  features land — give them the *code section to test*, not the tests.

### 2.2 Align project layout
- [ ] Library = `root.zig`, CLI = `main.zig` (build-skill convention); the skeleton uses `pan.zig` —
  reconcile early so imports/exports don't churn later.

---

## 3. Recommended first move — the "step 0" slice

A single slice that front-loads the two expensive-to-change things (API surface, test backbone) and
de-risks the commit pass deterministically before any device code:

1. **Pin the public API** (`root.zig`) with stub bodies (§1.2).
2. **Make `Frame` layout-ready** (`ChannelLayout`, §1.1) + reconcile `types.zig`/`port.zig`.
3. **Stand up the gold-vector + dual-mux + B≡C harness** (§2.1).
4. **Implement the offline commit pass**: topo-sort → liveness → per-element-class interval coloring
   (left-edge) → PDC longest-path → op-list emission → footprint. (`commit.zig` already has
   SCC-has-delay.) Detail & pseudocode: [`pan_commit_pass_algorithms.md`](../specifications/pan_commit_pass_algorithms.md).
5. **Drive a `Gain → Biquad → Pan` Map chain** through `RingSampleMux`/a pull harness, **validated
   bit-exact against the SciPy oracle** and **B≡C bit-identical**.

**Then** step 1' adds the CoreAudio sink (RT pull root, sub-5 ms, zero xruns) on top of the proven core.

---

## 4. The commit pass — the centerpiece (budget for it)

This is the bulk of the load-bearing algorithmic work. Order (from
[`pan_commit_pass_algorithms.md`](../specifications/pan_commit_pass_algorithms.md), [catalog §8.2](../specifications/catalog.md)):

| Stage | Status | Correctness gate |
|---|---|---|
| Format negotiation (incl. **layout identity** L1/L2, source-rooted SR3) | ⬜ TODO | type errors ⊢ + gold-vector ≈ |
| Topological sort (DAG minus feedback) | ⬜ TODO | deterministic tie-break |
| Liveness intervals | ⬜ TODO | B≡C |
| Per-element-class interval coloring (left-edge) | ⬜ TODO | **B≡C bit-identical** ≈ |
| SCC-has-delay | ✅ done | `error.DelayFreeLoop` ⊢ |
| PDC longest-path (incl. `VariRate` `max_latency`) | ⬜ TODO | latency-contract ≈ |
| Op-list emission + footprint | ⬜ TODO | comptime-const footprint ⊢ (embedded smoke gate) |

---

## 5. Test gates the amendments introduced (wire as features land)

New ≈ gates (catalog ledger B14–B18) on top of the existing dual-mux / B≡C / latency-contract /
state-granularity / embedded-smoke gates:
- [ ] **Layout negotiation** (registered up/down-mix vs hard mismatch; codec channel-order round-trip) — L2/B14.
- [ ] **VariRate** latency/`needed_input` over the interval; determinism split (param=reproducible, controller=≈) — V1/V2/V4, B15/B16.
- [ ] **Source generators** gold-vector incl. **oscillator anti-aliasing** vs a bandlimited (PolyBLEP) oracle; `out.len == pull N` — SR1, B17.
- [ ] **Typed events + PolyVoice**: dual-mux under `EventLane(NoteEvent)`; voice-stealing click-free; `note_id`/MPE routing; sample-accurate onset — EV1/EV2, Y2/Y3, B18.

---

## 6. Recommended next artifact (before feature code)

A **line-by-line `src/` audit → reconciliation report + sequenced step-0/step-1 plan**:
- What each of the 8 `src/` files currently is, and its precise delta vs the amended spec.
- The concrete `types.zig`/`port.zig` change for `ChannelLayout`; where `VariRate`/`EventLane`/`PolyVoice` slot in later.
- The pinned public API (`root.zig`) as a reviewable surface.
- The Yoneda test-gate list mapped to the step-0/step-1 code sections.

---

## 7. Non-blockers / known deferrals (don't wait on these)

- **Deferred formal work** — property-based harness, TLA+/Lean proofs, Flocq numeric proofs ([catalog §13](../specifications/catalog.md)). Explicitly out of scope.
- **Embedded MCU** — target-generic / deferred; a `freestanding` stub serves the comptime-commit smoke gate ([catalog §8.5/§9.3](../specifications/catalog.md)). Desktop-first is fine.
- **`ChannelLayout` registry** of canonical up/down-mix pairs — author when you need >stereo (mono/stereo need none).
- **Tiers B/C** — COMMITTED but **phased**; Tier A (single-thread sync pull) is the frozen ground truth — build it first, add B/C later ([catalog §8.4](../specifications/catalog.md)).
- **Synthesis blocks** (oscillators, ADSR, PolyVoice, samplers) — land at step 6d, after the core proves out.

---

## 8. Risks to keep visible (from the spec risk register)

| Risk | Mitigation (already designed) |
|---|---|
| `Map`/`Rate` surface leak | two contracts + **dual-mux** every block |
| Aliasing bugs from in-place coloring | `aliasing_safe` assertion + **B≡C / paranoid NaN-poison** (message quotes the assertion back) |
| Monomorph creep (now **layout × precision**) | bounded active-precision + active-layout lists; log generated-monomorph count at build (Rule 12) |
| Denormal CPU spikes / NaN | **required** FTZ realtime token (won't compile without it); NaN guards + telemetry `guards_compiled_out` |
| Clock drift (long sessions) | adaptive **`VariRate` ASRC** at the device boundary (≈ class, V4) |
| `VariRate` controller non-reproducibility | honest ≈ class; parameter-driven is O3-reproducible |
| Tier-B nondeterminism (later) | OS audio workgroup + static HEFT + bit-identical to Tier A + auto-demote |

---

## 9. Working discipline (project rules that bite during coding)

- **Rule 13:** load the `zig-0-16` skill before writing/reviewing/debugging *any* Zig; verify by
  compiling against `zig 0.16.0`; consult the std source rather than recalling stale APIs.
- **Rule 14:** at each implementation gate, dispatch Yoneda test-writers (tell them to load `zig-0-16`);
  give them the code section, not the tests.
- **Rule 9/12:** tests assert intent against the **independent** SciPy/NumPy oracle (not pan's own
  output); fail loud — "compiles" / "tests pass" must be literally true.
- **Rule 3/11:** surgical changes, match the codebase's conventions; the spec is the source of truth,
  code conforms to it (not the reverse).

---

## 10. Definition of done

- **Step 0 done:** public API pinned in `root.zig`; `Frame(Lane, L)` layout-ready; gold-vector +
  dual-mux + B≡C harness runs green; offline commit pass produces a correct op-list for the 3-block
  chain; `Gain → Biquad → Pan` matches the SciPy oracle (allclose f32 / bit-exact fixed-point) **and**
  is B≡C bit-identical.
- **Step 1' done:** the same graph runs live through a CoreAudio sink on M3 — **sub-5 ms** round trip,
  **zero xruns** over 10 min, footprint reported at commit ([bridge §5 step 1](../specifications/pan_categorical_bridge_and_roadmap.md)).
