# Handoff — end of Session 6 (P6 "feedback/persistent" + P7 "coloring/in-place") → into P8

> **Status:** P0–P5 + **P6 + P7 implemented, full-surface, and green.** Advisory handoff, not a spec:
> the `specifications/` corpus and `pan_implementation_plan.md` remain the source of truth.
> **Date:** 2026-06-03. **Toolchain:** `zig 0.16.0` (re-run `zig version` at P8 start — Rule 13).
> Session was the bundled **P6+P7** (`notes/session_bundling.md` session 6): the memory model finished
> — P6 adds the persistent/feedback category, P7 the non-persistent edge coloring + in-place coalescing.
> They share `commit.zig` liveness/footprint and the B≡C differential, landing one "memory model done +
> B≡C green" gate (roadmap steps 3+4). **Committed** on branch `p6-p7-feedback-coloring` (off `main`,
> commit `7e47ccf`): the full P6+P7 core delta + the gap-closure pass (G1–G10) are in that one commit.

---

## 1. Ownership statement (honest, Rule 12)

> **Correction (honest, Rule 12).** An EARLIER draft of this section claimed full P6/P7 surface coverage
> while several explicitly-listed work items were still missing or partial — that claim was premature. A
> dedicated **gap-closure pass (2026-06-03)** then closed all ten gaps (G1–G10 of
> `handoff_p6p7_gap_closure.md`); the statement below is now backed by that pass and is accurate. The
> two-pass history: the bundled session landed the core machinery green; the follow-up closed the surface.

Every P6 work item (`pan_implementation_plan.md` §6, items 1–5) and every P7 work item (§7, items 1–5)
is implemented and **verified green** across the four-mode matrix (Debug / ReleaseSafe / ReleaseFast
test suites exit 0 — **658 tests**, ReleaseFast skips the 2 guard-gated ones), the freestanding
**ReleaseSmall smoke** object, the Linux **cross seam** (`zig build cross-linux`), `fmt-check`, and
`zig build bench -Dbench-gate` (**footprint baseline 8192 B held** — coalescing leaves the gain→biquad→
pan chain at 8192 because Biquad is not `aliasing_safe` and Pan changes layout). The SPSC ring + RCU
swap stay **ThreadSanitizer-clean** (unchanged by this session).

**What the gap-closure pass added (G1–G10):** the multi-channel planar delay (`PlanarDelayLine`/
`PlanarUnitDelay`, `src/time.zig` — G1) so `UnitDelay`/`DelayLine` cover all four element families incl.
real `Frame(C>1)`/`Frame(.discrete(N))`; the **FDN reverb** core (`FdnMatrix`, `src/fx.zig` — G2,
matrix-mix over a `discrete(N)` bus closed by feedback edges, asserted to commit + render a decaying
tail + reject the delay-free dual); the **Ladder** fused kernel (`src/fx.zig` — G3); an assembled
**Schroeder reverb** rendered through the Executor (`tests/schroeder_reverb_test.zig` — G4); P6 benches
(`bench/feedback_bench.zig` — G5: feedback footprint term, fused-vs-graph throughput, FTZ denormal);
the **uniform-count guard** proving the FFD fallback unreachable under elem-name keying (`src/commit.zig`
— G6); **`noalias`** as a documented ▷ authoring convention applied to the fused kernels (`src/fx.zig`
— G7); the **active paranoid NaN-poison** executor (`ParanoidExecutor` + `Plan.buffer_last_use`,
`src/engine.zig`/`src/commit.zig` — G8, poisons retired POOL buffers, never the persistent feedback
tail); the comptime **worked-example-A coloring** reproduction `M_Sample=3`/`M_Complex=2`
(`tests/example_a_coloring_test.zig` — G9; footprint-figure 14352 deferred to the rate-domain phase,
only the coloring reproduced here); and the **Mode-B vs Mode-C** memory bench (`bench/coloring_bench.zig`
— G10). New Yoneda suites: `tests/planar_delay_test.zig` (23) + `tests/ladder_test.zig` (23), both
autonomous and green; my own gate tests cover FDN/Schroeder/paranoid/example-A.

**What is the user's to run (sandbox can't):** the live device gate (sub-5 ms / 10-min, zero xruns) —
unchanged from P5. No new device dependency this session.

**Yoneda dispatch (Rule 14):** SIX autonomous `yoneda-test-writer` agents total (each loaded `zig-0-16` +
verified by compiling), no bugs found in the under-test code. Bundled pass (four): `tests/delay_test.zig`
(19), `tests/fused_feedback_test.zig` (24), `tests/persistent_feedback_test.zig` (14),
`tests/inplace_coalescing_test.zig` (12). Gap-closure pass (two): `tests/planar_delay_test.zig` (23),
`tests/ladder_test.zig` (23). The B≡C differential (mode B per-edge ≡ mode C colored, **bit-exact**, with
coalescing on) is the primary colorer correctness check and is green across single Gain, deep Gain
chains, Gain→Biquad, fan-out, and the layout-changing Pan.

---

## 2. What was built (the deltas)

Two passes: the **bundled session** (core machinery) and the **gap-closure pass** (G1–G10, marked `[Gn]`).

```
src/time.zig    (NEW)  Element-generic UnitDelay(Elem) / DelayLine(Elem,len): rate-1:1 Map, internal
                       zero-init ring [len]Elem + circular cursor, out[n]=in[n-len]. Declares
                       `delay_len` (⇒ is_delay, SCC-has-delay sees it) + `state_size`. Generic over
                       Sample/Complex/FeatureFrame/Scalar.
                       [G1] + PlanarDelayLine(Lane,L,len) / PlanarUnitDelay(Lane,L): the multi-channel
                       variant — per-plane ring [C*len]Lane over a Planar/PlanarConst VIEW, so a real
                       Frame(C>1) / Frame(.discrete(N)) bus (the AoS port is a compile error) is delayed
                       plane-by-plane. Closes "UnitDelay works across ALL four element families".
src/fx.zig      (NEW)  Fused tight-feedback kernels — Comb / Allpass / KarplusStrong: single Map, the
                       per-sample feedback loop runs INTERNALLY over instance state (sample-accurate
                       z⁻¹). Declare `delay_len`, deliberately NOT `aliasing_safe`, float-only (int =
                       compile error, like Biquad). The executable-reverb path (no graph feedback edge).
                       [G3] + Ladder(num): Moog 4-pole resonant low-pass (4 cascaded one-poles + global
                       resonance feedback), a fused kernel (delay_len=1, not aliasing_safe, float-only).
                       [G2] + FdnMatrix(num,N): the FDN mixing core — out = input + A·feedback over a
                       Frame(.discrete(N)) planar bus, A = normalized Sylvester Hadamard × decay (N a
                       power of two). The graph-level FDN = N (Planar)DelayLine nodes + FdnMatrix +
                       feedback edges (SCC has the delays ⇒ legal).
                       [G7] `noalias` on the fused kernels' slice ports — a documented ▷ authoring
                       convention (the opposite of aliasing_safe; these kernels never alias in/out).
src/commit.zig  (M)    Plan += `persistent_bytes`. **Feedback-source values are now pool-EXCLUDED
                       persistent**: a value whose output port feeds a feedback read-side gets one
                       persistent buffer in the pool tail (shared by ALL its consumers — producer writes
                       once, this block's forward readers + next block's feedback read the same buffer;
                       never colored, never zeroed mid-stream). One persistent buffer per DISTINCT
                       feedback source (deduped). Buffer-offset tables now cover the persistent tail.
                       **P7 in-place coalescing** (stage "5b" + `alias_root` union-find): a single-
                       consumer `aliasing_safe` unary rate-1:1 Map writes its output IN PLACE into its
                       input buffer — colored mode only; per_edge never coalesces (the B baseline).
                       [G6] uniform-count guard in the class-gather loop: element_count rides in the
                       elem_name key, so a class is uniform-size by construction → the spec's FFD
                       heterogeneous-count fallback is UNREACHABLE; closed with an assert + doc, not dead
                       bin-packing code.
                       [G8] Plan += `buffer_last_use[id]` (per POOL buffer, the op index of its last
                       read; -1 = unused OR persistent ⇒ never poison). Threaded through the
                       commitComptimeMode repack like persistent_bytes.
src/graph.zig   (M)    +`max_buffers = max_edges*2` (persistent ids `pool_count+fi` can exceed max_edges).
src/engine.zig  (M)    **Removed the `footprint_bytes != pool_bytes` @compileError gate.** Executor pool
                       is now `pool_bytes + persistent_bytes`, zero-init (`@splat(0)`), tail survives
                       callbacks. Runtime Engine pool cap / reconfigure / installPlan include
                       persistent_bytes; allocPool zeroes. +inline graph-level-feedback execution test.
                       [G8] ExecutorMode now delegates to ExecutorModeParanoid(.., comptime paranoid);
                       ParanoidExecutor poisons each POOL buffer to a NaN bit pattern (@memset 0xFF) the
                       op its live range ends (gated on runtime_safety), NEVER the persistent feedback
                       tail. A colorer/coalescing bug surfaces as a NaN at the sink.
src/root.zig    (M)    re-export time / fx + UnitDelay / DelayLine / Comb / Allpass / KarplusStrong.
                       [G1/G2/G3/G8] + PlanarUnitDelay / PlanarDelayLine / Ladder / FdnMatrix /
                       ExecutorMode / ParanoidExecutor.
build.zig       (M)    +4 Yoneda harnesses (bundled). [gap-closure] +6 harnesses (planar_delay,
                       fdn_reverb, ladder, schroeder_reverb, paranoid_poison, example_a_coloring) and
                       +2 benches (feedback_bench, coloring_bench).
tests/{delay,fused_feedback,persistent_feedback,inplace_coalescing}_test.zig  (NEW, Yoneda, bundled).
tests/planar_delay_test.zig (23, Yoneda) · tests/ladder_test.zig (23, Yoneda)               [G1/G3]
tests/fdn_reverb_test.zig (3) · tests/schroeder_reverb_test.zig (2)                          [G2/G4]
tests/paranoid_poison_test.zig (2) · tests/example_a_coloring_test.zig (2, M_Sample=3/M_Complex=2) [G8/G9]
bench/feedback_bench.zig (footprint, fused-vs-graph throughput, FTZ denormal)                [G5]
bench/coloring_bench.zig (Mode-B vs Mode-C footprint reduction %)                            [G10]
```

---

## 3. Verification — reproduce green

From `/Users/komorebi/Documents/projects/tools/audio/pan`:
```sh
zig build test                              # Debug                     → 658/658
zig build test -Doptimize=ReleaseSafe       #                           → 658/658
zig build test -Doptimize=ReleaseFast       #                           → 656/658 (2 guard-skipped)
zig build smoke                             # freestanding ReleaseSmall  → PASS
zig build cross-linux                       # x86_64-linux-gnu seam      → PASS
zig build fmt-check                         #                           → PASS
zig build bench -Dbench-gate                # footprint baseline 8192 B  → OK
zig test src/engine.zig  -framework AudioToolbox -framework CoreAudio -framework CoreFoundation -lc -fsanitize-thread --test-filter concurrent
zig test src/control.zig -fsanitize-thread --test-filter concurrent
```
> Carried cosmetic noise (P2): `aliasing_message_test` / `comparator_test` drive reject paths with
> `std.debug.print`; the 0.16 runner echoes "failed command" but the suite exits 0. Use
> `std.debug.print`, never `std.log.err`, for expected-reject diagnostics.

---

## 4. The central architecture P8 must read (the memory model, finished)

- **Two distinct quantities, never conflated** (the load-bearing insight of P6):
  - `plan.footprint_bytes` = the **H2 reporting figure**, the locked formula `Σ pools + Σ delay-ring +
    Σ block-state (+ Σ PDC)`. Delay rings and per-block state live INSIDE block instances (allocated at
    construction, like P5 ramp state) — counted here but NOT in the executor pool.
  - The executor's flat pool = `pool_bytes` (colored scratch) **+ `persistent_bytes`** (the feedback
    z⁻¹ tail). The feedback z⁻¹ buffers are real memory but, per the locked spec (worked example B =
    3968, "the feedback edge contributes no pool buffer"), are NOT in the reported footprint.
- **The feedback z⁻¹ is the producer's output, made persistent.** A feedback-source value is shared by
  all consumers and lives in the pool tail; the producer writes it once. This solved the
  "one output port, two destinations (forward + feedback)" problem cleanly: the emit dedups the
  feedback write-side against the forward output (same persistent id).
- **In-place coalescing is value-merging before coloring** (`alias_root` union-find), gated on the
  three structural conditions + `aliasing_safe`. A falsely-declared `aliasing_safe` is CAUGHT by B≡C
  (the colored aliased run diverges from the per-edge baseline) with the quote-back message.

## 5. What P8 needs (from plan Phase 8) — and the hooks this session leaves

P8 = **roadmap step 5**: the dual contract at the **rate-elastic seam** — a `Framer`+STFT (or polyphase
resampler) with `out_per_in ≠ algorithmic_latency`, dual-mux + latency-contract passing, and **PDC**
re-aligning the dry/wet FFT diamond (worked example A, footprint `14352 B + Σ state`). **Read first**
(plan §8): `pan_execution_model.md` §2.2/§2.3/§4; `pan_commit_pass_algorithms.md` §6 (PDC longest-path
DP, per-rate-domain), §7 (rate scheduling), §10 (worked example A); `pan_memory_model.md` §7 (PDC folded
into buffer assignment).

**The hooks P6/P7 (and earlier) leave:**
- **The executor handles persistent state now** — the `@compileError` gate is gone. PDC compensating
  delays are "persistent / pool-excluded" too, so they slot into the SAME persistent category P6 built
  (a `DelayLine` on the shorter fan-in branch, instance-resident, counted in footprint). The commit pass
  already has `algorithmic_latency` / `rate_domain` / `out_per_in` on every Node and the
  `BypassLatencyUncompensated` error stub — PDC fills the longest-path DP and inserts the comp-delays.
- **`Rate`/`pull` binding in the executor is still unimplemented** (P4/P5 slices are all-Map). A real
  `Rate` block (framer/STFT) needs the executor to bind its `pull` (not just `process`) — the op-list
  `n_or_pull_spec` already carries the demand, and the rate scheduler already compiles it; the missing
  piece is the executor dispatching `pull(want,out)` for a Rate op.
- **`insertCoercions` auto-inserts a resampler node** on a rate-mismatched edge (P5); its numerical body
  is still the same-rate passthrough stub (Phase 8/16 gold). A second rate domain (the STFT hop grid) is
  what first exercises per-rate-domain PDC conversion.
- **Worked example A** (dry/wet FFT diamond) is the P8 gate graph: M_Sample=3, M_Complex=2, a
  `DelayLine(1024)` PDC comp-delay on the dry branch, footprint 14352 + Σ state. The colorer + footprint
  are ready; PDC insertion + the STFT/iSTFT `Rate` blocks are the work. **Scaffold already exists:**
  G9's `tests/example_a_coloring_test.zig` builds this exact diamond with SYNTHETIC rate-1:1 stub blocks
  (STFT Sample→Complex, SpectralGain, iSTFT, explicit dry `DelayLine(1024)`) and asserts M_Sample=3 /
  M_Complex=2 at comptime — P8 turns the stubs into real `Rate` blocks (257-wide spectral frames on the
  hop-256 domain) and adds PDC insertion to reach the full 14352 B figure. Today those stubs are 1:1 so
  the spectral pool is N-wide, not 257-wide — the coloring is right, the rate-domain sizing is P8's job.

## 6. Honest gaps carried into P8+ (Rule 12)

- **PDC** (per-rate-domain longest-path DP + comp-delay insertion) → **P8** (the `BypassLatencyUncompensated`
  reject is the only latency check today; full routing is P8).
- **`Rate`/`pull` executor binding** → P8 (needed for the first real Rate block).
- **Persistent-state carry across an RCU swap** resets to silence today (a topology edit clicks the
  delay tail). The `installPlan` path frees the old plan after grace but does not memcpy the old
  persistent tail into the new pool — a documented refinement (concurrency §4.6).
- **Polyphase sinc resampler numerical body** + up/down-mix matrices → Phase 8/16 (still a passthrough
  stub). Fixed-point Comb/Allpass/KS + fixed-point Biquad + fixed-point Ladder/FdnMatrix → embedded-
  precision phase (compile-error today). (Multi-channel `Frame(C>1)` delay is now CLOSED — G1's
  `PlanarDelayLine` ships the planar-view ring; only the fixed-point lane stays deferred.)
- **Live device gate** (sub-5 ms / 10-min) → on-device (user), unchanged.
- **P11** (modulation blocks) — still unbundled, not a blocker (see P6 handoff §7); slot before P13.

## 7. Conventions carried forward

Unchanged: §0.2 self-contained code docs (no spec-section refs in `src/` — verified clean); §0.3 ⊢/≈/▷
markers; §0.5 oracle-allclose vs pan-vs-pan bit-exact; §0.6 four-mode CI matrix; Rule 13 load `zig-0-16`
+ tell every subagent; Rule 14 dispatch Yoneda writers; any new runnable module links the platform audio
transport via `build.zig`'s `linkPlatformAudio`. New: a block declares itself a **delay element** by a
`pub const delay_len` decl; **persistent state lives in the block instance** (counted by footprint, not
the pool), and **feedback z⁻¹ buffers live in the executor pool tail** (`plan.persistent_bytes`).
