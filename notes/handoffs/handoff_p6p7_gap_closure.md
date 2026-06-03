# In-between handoff — CLOSE the P6 + P7 surface gaps (fresh-context agent)

> **Why this exists.** Session 6 (P6+P7) landed the CORE machinery green, but an honest surface audit
> found several explicitly-listed work items missing or partial. The prior `handoff_for_P8.md` §1
> OVERCLAIMED ("every P6/P7 work item is implemented") — **that line is wrong and must be corrected**
> once these gaps close. Your job: finish ALL the gaps below, re-verify every gate, re-run Yoneda
> dispatch, and fix the overclaim. **Date:** 2026-06-03. **Toolchain:** `zig 0.16.0` (re-run
> `zig version`). This is NOT P8 — do not start PDC / Rate blocks; finish P6+P7 first.

---

## 0. Orient first (do these before writing code)

1. **Load the `zig-0-16` skill AND read ALL its reference files** (ch.00–06) — project Rule 13. Any
   subagent you dispatch must be told to load it too.
2. **Read these memory files** (they hold the design decisions — do NOT re-derive them):
   `~/.claude/projects/-Users-komorebi-Documents-projects-tools-audio-pan/memory/`:
   `pan-p6-p7-status.md`, `p6-p7-design.md`, `pan-p5-status.md`, and `MEMORY.md`.
3. **Read** `pan_implementation_plan.md` Phase 6 (lines ~589–629) and Phase 7 (~633–671) — the work
   items + success criteria are the contract. **Read** `CLAUDE.md` (Rules 12 fail-loud, 13 zig skill,
   14 Yoneda dispatch).
4. **Re-read the spec sections** cited per gap below (the `specifications/` corpus is the source of
   truth; in-code docs must NOT cite spec filenames — restate inline, §0.2).
5. **Current state is GREEN**: `zig build test` = 595 tests across the four-mode matrix; smoke,
   cross-linux, fmt-check, bench-gate (8192 B), TSan all pass. Don't regress them.

---

## 1. Design context you MUST reuse (decided last session — do not re-litigate)

- **Footprint vs pool (the load-bearing split).** `plan.footprint_bytes` = the H2 REPORTING figure
  (locked formula: `Σ pools + Σ delay-ring + Σ block-state + Σ PDC`). Delay rings + per-block state
  live INSIDE block instances (allocated at construction, like P5 ramp state) — counted by footprint,
  NOT in the executor pool. The executor's flat pool = `pool_bytes` (colored scratch) + `persistent_bytes`
  (feedback z⁻¹ tail). Feedback z⁻¹ buffers are real memory but, per the locked worked example B (3968),
  are NOT in the reported footprint. **Keep this — don't "fix" footprint to include feedback buffers.**
- **Feedback z⁻¹ = the producer's output made persistent** (pool-excluded, shared by all consumers,
  one persistent buffer per distinct feedback source). `commit.zig` already does this (`is_persistent`
  value flag + emit write-side dedup).
- **Planar enforcement (Phase 4.5, HARD).** A multi-channel `Frame(Lane,L)` with `C>1` MUST ride a
  `Planar(Lane,L)` / `PlanarConst(Lane,L)` VIEW — a `[]Frame(Lane,L)` port for `C>1` is a
  `@compileError` (see `src/port.zig portOfParam`). Mono `Sample(T)=Frame(.mono)` stays a plain
  `[]Sample(T)` slice. **This is why the current `DelayLine` only does single-plane elements** — see G1.
- **Block authoring conventions** (`src/filters.zig`, `src/fx.zig` are the templates): `fn Block(num:
  numeric.Numeric) type` (or `(Elem)` / `(num, max_delay)`); `process(self, in, out)`; declare
  `pub const delay_len` → marks `is_delay` (so SCC-has-delay accepts a cycle containing it); declare
  `pub const aliasing_safe = true` to opt into in-place; `pub const state_size`; float-only kernels
  `@compileError` on integer lanes (copy the `requireFloat` pattern from `fx.zig`).
- **Useful facts learned:** `@splat(std.mem.zeroes(Elem))` zero-inits a `[len]Elem` ring field.
  `types.Complex(f32) = struct { z: std.math.Complex(f32) }` (build `.{ .z = .{ .re=.., .im=.. } }`).
  `graph.max_buffers = max_edges*2` already exists. Expected-reject diagnostics use `std.debug.print`,
  NEVER `std.log.err` (the 0.16 runner counts logged errors → non-zero exit). The in-place coalescing
  now collapses single-consumer `aliasing_safe` Gain chains to ONE buffer (bench stress shows it).

---

## 2. THE GAPS — close every one (P6: G1–G5, P7: G6–G10)

### G1 — Multi-channel `Frame(C>1)` delay (incl. `.discrete(N)`)  ·  src/time.zig  ·  MED-HIGH risk
The current `DelayLine(Elem,len)` / `UnitDelay(Elem)` work on plain `[]Elem` slices → only single-plane
elements (Sample, Complex, FeatureFrame, Scalar). A `C>1` `Frame` port is a planar VIEW, so a planar
delay needs `process(self, in: PlanarConst(Lane,L), out: Planar(Lane,L))` with a per-plane ring
(`[C][len]Lane` or `[C*len]Lane` + cursor), delaying each plane independently.
- **Implement** a `PlanarDelayLine(Lane, comptime L, len)` (and a `PlanarUnitDelay`) in `src/time.zig`,
  OR make `DelayLine` detect a planar element and dispatch. Keep `delay_len`/`state_size` declared.
- **Reference:** `src/types.zig` `Planar`/`PlanarConst` (`.plane(c) → []Lane`, `.frames`, `.is_const_view`,
  `.Elem`); `src/spatial.zig` `ConstantPowerPan` (a planar-output block writing planes); `src/engine.zig`
  `runOp` `planarConstView`/`planarMutView` (how the executor builds planar views from a pool buffer —
  it keys on `types.isPlanarView(ParamT)`). Confirm the executor + commit handle a planar delay element
  (its forward/feedback buffers are sized `C·N·sizeof(Lane)` — already layout-agnostic in commit).
- **Spec:** `catalog.md` §5.5 (element-generic `UnitDelay`/FDN over `Frame(.discrete(N))`),
  `pan_memory_model.md` §6.2.
- **Done when:** UnitDelay/DelayLine cover `Frame(C>1)` incl. `.discrete(N)`; the success criterion
  "works across all four element types" (Sample/Frame/Complex/FeatureFrame) is TRUE for real `Frame`.

### G2 — FDN reverb  ·  src/fx.zig  ·  depends on G1
A Feedback Delay Network = `N` `(Planar)DelayLine` nodes + a **matrix-mix `Map`** over
`Frame(Lane,.discrete(N))` (an `N×N` feedback matrix — a Hadamard/Householder is standard) + feedback
edges closing the loop. The SCC contains the delay lines ⇒ legal.
- **Implement** the matrix-mix block (`FdnMatrix(num, N)` or similar: `process` over a `Frame(.discrete(N))`
  planar view, applying the mixing matrix per sample) in `src/fx.zig`. Assemble the FDN as a graph (N
  delays + matrix mix + `connectFeedback` edges) in a test/example.
- **Spec:** `catalog.md` §5.5, `pan_memory_model.md` §6.
- **Done when:** an FDN commits (SCC-has-delay passes) and renders a stable decaying tail; Yoneda-tested.

### G3 — Ladder fused kernel  ·  src/fx.zig
A Moog-style ladder filter: 4 cascaded one-pole stages with a global feedback path (resonance), authored
as a SINGLE rate-1:1 `Map` with internal per-sample state. Declares `delay_len` (so SCC sees its internal
z⁻¹), NOT `aliasing_safe`, float-only. Sits next to `Comb`/`Allpass`/`KarplusStrong`.
- **Spec:** `pan_memory_model.md` §6.1 (fused tight-feedback kernel), `catalog.md` §5.4.
- **Done when:** classifies `.Map` + delay element + not aliasing_safe; stable resonant-lowpass behaviour;
  Yoneda-tested. Export from `root.zig` (`pan.Ladder`).

### G4 — Assembled graph-level comb/all-pass reverb  ·  test (+ optional examples/)
The fused `Comb`/`Allpass` exist; the plan wants an actual **Schroeder reverb assembled as a graph**
(parallel `Comb` bank summed → series `Allpass` chain) rendered end-to-end through the `Executor` with a
stable decaying tail. Build it as a test (and optionally an `examples/` program). Note: fused kernels have
NO graph feedback edge (loop is internal) — the assembly is just a feed-forward graph of them + a mixer.
- **Spec:** `catalog.md` §5.4; plan P6 item 5 ("a comb reverb runs").
- **Done when:** the assembled reverb renders finite, decaying output through the engine; tested.

### G5 — P6 benchmark entries  ·  bench/
Add (per plan P6 Benchmark + §0.9): (a) the persistent/feedback footprint term (delay-line bytes) for a
feedback graph; (b) fused-tight-feedback-kernel throughput vs the graph-level `DelayLine`-in-a-cycle
idiom; (c) FTZ denormal CPU-spike avoidance on a decaying comb tail (with vs without `enterRealtimeThread`).
Follow `bench/harness.zig` discipline (ReleaseFast, warm up, consume results, ns/iter). Don't add a hard
`-Dbench-gate` baseline for these unless deterministic (footprint is; throughput isn't).

### G6 — FFD fallback for heterogeneous element_count in a class  ·  src/commit.zig
The colorer groups by `elem_name` and computes ONE stride per class (`N · class_elem_size[c]`). **First
ASSESS reachability:** with the current keying, element_count rides inside the element type's `@typeName`
(Frame layout, FeatureFrame K, Complex bin count) → different counts are different `elem_name`s → different
classes → uniform-count within a class. If you confirm it's unreachable, the honest close is a **comptime
guard/assert that each class is uniform-count** (proving the invariant) + a doc note — NOT dead FFD code.
If reachable, implement the brute-force/first-fit-decreasing path at `M ≤ 8` (spec §4). **Decide, do one,
document which and why (Rule 12).**
- **Spec:** `pan_commit_pass_algorithms.md` §4, `catalog.md` §7.2.

### G7 — `noalias` on the proven-non-aliased path  ·  src/engine.zig (+ assess)
Spec wants `noalias` applied only where in/out buffers are PROVEN distinct. **Assess feasibility first:**
a block's `process` signature is author-controlled — pan cannot inject `noalias` into the call site, and
the in-place-coalesced path deliberately aliases. The realistic options: (a) it's an AUTHORING convention
(▷) — a block whose kernel never aliases MAY declare `noalias` params itself; document that and add it to
the relevant library kernels where safe; OR (b) find a mechanically-injectable win in the gather/scatter.
Likely a small/▷ item — **close it honestly** (implement what's feasible, document what isn't and why),
don't silently skip.
- **Spec:** `pan_memory_model.md` §3 (noalias placement), skill ch.04.

### G8 — Active paranoid NaN-poison in the colored executor  ·  src/engine.zig + src/commit.zig  ·  HARDEST
The poison MECHANISM exists (`h.poisonNaN` in `tests/harness.zig`, tested in `tests/bc_differential_test.zig`)
but is NOT wired into `ExecutorMode` to actively poison a pool buffer to NaN when its live range ENDS,
so a buffer-reused-before-last-reader bug surfaces as NaN during a real render (the colored/coalescing/
feedback paths). Implement (Debug/ReleaseSafe only, gated like the existing guards):
- Surface per-buffer-id **last-use op index** from the liveness pass into the `Plan` (e.g.
  `buffer_last_use[id]`), for POOL (non-persistent) buffers only. **Never poison persistent feedback
  buffers** (they survive the callback) and respect coalesced live-ranges (the merged root's end).
- In `ExecutorMode` with a comptime `paranoid` flag, after each op, NaN-fill any pool buffer whose
  `last_use == this op index`. A subsequent erroneous read sees NaN.
- Yoneda: render a coalescing + a feedback graph under paranoid mode; assert NO NaN leaks into the sink
  (correctness) — this is the success criterion "paranoid mode finds no aliasing".
- **Spec:** `pan_memory_model.md` §9, `catalog.md` §7.5.

### G9 — Worked example A: reproduce `M_Sample=3`, `M_Complex=2` at comptime  ·  test
Build the dry/wet FFT-diamond TOPOLOGY with SYNTHETIC stub blocks (the numerics are P8): a Gain dry path;
an `STFT` stub (`Sample → Complex` Map), `SpectralGain` (`Complex → Complex`), `iSTFT` (`Complex → Sample`)
on the wet path; a split (fan-out) and a 2-input `Mix`. **To get `M_Sample=3` you must include the dry
PDC comp-delay as an explicit `DelayLine(1024)` node on the dry branch** (the 3-way fan-in at Mix —
comp-delay out + iSTFT out + fresh edge — is what forces 3 colors). `M_Complex=2` falls out of the two
overlapping spectral edges (STFT→SpectralGain→iSTFT). Assert the M values at `comptime` via
`commitComptime`. **Read `pan_commit_pass_algorithms.md` §10.2 for the exact intervals/colors** before
building so your topology matches. (Full 14352 B + real PDC insertion is P8 — only the coloring here.)
- **Spec:** `pan_commit_pass_algorithms.md` §10 (worked example A).

### G10 — P7 benchmark: Mode-B vs Mode-C head-to-head  ·  bench/
Add a bench comparing `per_edge` (Mode B) vs `colored` (Mode C) **footprint reduction %** and
**byte-displacement-per-render reduction** on the same graph, behind the same `getBuffer` interface (plan
P7 Benchmark). Footprint is deterministic → safe to report a number.

---

## 3. Verify (ALL must pass at the end) + Yoneda + cleanup

```sh
zig build test                            # Debug
zig build test -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseFast
zig build smoke                           # freestanding ReleaseSmall
zig build cross-linux                     # x86_64-linux-gnu seam
zig build fmt-check                       # run `zig fmt` on any new files FIRST
zig build bench -Dbench-gate              # footprint baseline 8192 B must still hold
zig test src/control.zig -fsanitize-thread --test-filter concurrent
zig test src/engine.zig  -framework AudioToolbox -framework CoreAudio -framework CoreFoundation -lc -fsanitize-thread --test-filter concurrent
```
- **bench-gate caution:** the gate only checks the gain→biquad→pan chain f32 N=512 footprint (8192 B);
  your new blocks shouldn't touch it. If a NEW deterministic baseline is added, commit it under
  `bench/baselines/`.
- **Rule 14 (Yoneda):** dispatch autonomous `yoneda-test-writer` agents for each NEW surface (planar
  delay, FDN, Ladder, assembled reverb, paranoid mode, example-A coloring). Each: load `zig-0-16` +
  verify by compiling; give them the code section + invariant + comparison mode (pan-vs-pan ⇒ bit-exact;
  analytic oracle ⇒ allclose) + the `tests/` file path; do NOT hand them the tests; forbid editing `src/`.
  Wire new harness files into `build.zig`'s `harnesses` list. Import convention: `const pan = @import("pan");`
  then `pan.X` (copy from `tests/executor_test.zig`); relative `@import("harness.zig")` for `h.*` helpers.
- **Wire** new `root.zig` exports (`pan.Ladder`, FDN, planar delays).
- **CORRECT THE OVERCLAIM:** edit `notes/handoffs/handoff_for_P8.md` §1 so it honestly states the gaps
  were closed in a follow-up pass (or, if any item lands as ▷/unreachable per G6/G7, say exactly that).
  Update the memory `pan-p6-p7-status.md` "Honest gaps" line to reflect closure.
- **Checkpoint (Rule 10):** after each gap, note what's verified. End on green; commit only if the user
  asks (the repo is git but the prior session left work uncommitted by design).

## 4. Risk / sequencing advice

- **G1 → G2** are coupled (FDN needs the planar/discrete delay) and are the heaviest; do them first while
  context is fresh. G1 re-opens the planar-view machinery (the Phase-4.5 frozen surface) — tread carefully,
  lean on `ConstantPowerPan` + `runOp`'s planar path as the working reference.
- **G8** (paranoid poison) needs a `Plan` change (expose per-buffer last-use) touching the comptime AND
  runtime commit copy + `commitComptimeMode` repack — mirror how `persistent_bytes` was threaded last
  session. Don't poison persistent/feedback buffers.
- **G9** is pure test authoring but requires matching the spec's §10.2 topology precisely (the comp-delay
  node is what makes M_Sample=3).
- **G3, G4, G5, G10** are low-risk and independent — good parallel Yoneda/fan-out candidates.
- **G6, G7** may resolve to "guard + document" rather than new code — that's a legitimate honest close
  (Rule 12), not a skip, as long as you state the reasoning.

You have ~50% context free at compaction; this list is the full remaining P6+P7 surface. Finish it, prove
it green across all gates, and only then is "full ownership of P6+P7" an honest claim.
