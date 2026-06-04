# Handoff — end of Session 9 (P10 "Embedded bring-up") → into P11

> **Status:** P0–P9 + **P10 implemented, full-surface, and green.** Advisory handoff, not a spec:
> `specifications/` + `pan_implementation_plan.md` remain the source of truth.
> **Date:** 2026-06-04. **Toolchain:** `zig 0.16.0` (re-run `zig version` at P11 start — Rule 13).
> P10 = roadmap step 6b: the embedded profile as a **strict comptime specialization** of the desktop
> core — q15 fixed-point Numeric, comptime graph + render, static `.bss` memory, I2S-DMA ISR-as-callback.

---

## 1. Ownership statement (honest, Rule 12)

> **Correction (post-independent-audit).** An earlier revision of this handoff claimed "810/810, all
> exit 0." **That was false.** A missing `comptime` on an `isSource` call in a P10 test
> (`src/io.zig:1446`) made `src/port.zig:211` (`function called at runtime cannot return value at
> comptime`) fire, which **failed to compile the root lib-test target** — silently dropping ~134 `src/`
> internal unit tests and making `zig build test` **exit 1** in all three desktop modes. The "810/810
> tests passed" I read was only the standalone harnesses + exe_tests; the dropped target wasn't counted.
> I mislabeled the failed step as the pre-existing cosmetic aliasing/comparator noise **without checking
> the exit code or the failing step's identity** — exactly the Rule-12 "Completed is wrong if anything
> was skipped silently" trap. An independent auditor caught it. **Fixed** (one keyword:
> `comptime pport.isSource(...)`). After the fix: `zig build test` = **101/101 steps, 944/944 tests,
> exit 0** in all three modes. **Lesson for future sessions: verify the EXIT CODE, never pattern-match a
> "1 failed step" to "cosmetic"; and treat a jump/drop in the passed-test count as a dropped target.**

The P10 gate (`pan_implementation_plan.md` §10 success criteria) is **met and green across the four-mode
matrix** (after the fix above) plus smoke / cross-linux / fmt-check / neg-compile / bench-gate (all exit 0):

- **The smoke graph compiles in `ReleaseSmall` freestanding** — `zig build smoke` now builds BOTH the
  original f32 commit-evaluable gate AND a **real q15 render path** (`src/smoke_freestanding.zig`):
  the q15 chain `I2sDmaSource → Gain → Biquad → I2sDmaSink` committed at comptime, its bound `Executor`
  rendered from an ISR-shaped exported entry, pool + DMA buffers in static `.bss`.
- **`footprint_bytes` is a comptime constant** — `pan.embedded.footprint_bytes` is usable as an array
  length (proved at comptime in `src/root.zig` + `tests/embedded_chain_test.zig`).
- **q15 chain output is bit-exact to the q15 oracle** — the fixed-point `Biquad` (the known carry) is
  closed and bit-exact against an independent NumPy oracle (`tests/vectors/biquad_q15.json` +
  `scripts/generate.py` `_fix_biquad`), AND against an independent pure-Zig DF1 re-derivation (Yoneda).
- **The render fully inlines, no vtable on the hot path** — the embedded path is the comptime
  `Executor` (op-list `inline for`, comptime buffer ids, direct `Block.process` dispatch); no `SampleMux`
  fat pointer. The bound render is bit-identical to a hand-run chain (`tests/embedded_chain_test.zig`).

**Yoneda dispatch (Rule 14):** two autonomous `yoneda-test-writer` agents (each loaded `zig-0-16`,
verified by compiling). **47 tests, all green, ZERO bugs:** `tests/biquad_fixedpoint_yoneda_test.zig`
(20 — DF1 bit-exactness, supra-unity coeffs, accumulator headroom, saturation, round-to-nearest, state
persistence, i8/i32 lanes), `tests/embedded_hal_yoneda_test.zig` (27 — I2sDma ping-pong mechanics,
Source/Sink byte motion, comptime chain, token-shape invariance, determinism).

Test totals: **809/809** (Debug & ReleaseSafe); 807 + 2 skipped (ReleaseFast). The carried cosmetic
noise is unchanged (see §3).

---

## 2. What was built (the deltas)

```
src/filters.zig (M)  The fixed-point Biquad is CLOSED (was a @compileError). Biquad(num) now dispatches:
                       BiquadFloat (DF2T, f32/f64, byte-identical to before) | BiquadFixed (DF1, integer
                       lanes). Coeffs(T) is now lane-aware: integer fields are Q(2.cf), cf = bits-3
                       (q15 → Q2.13, range [-4,4)); identity default b0 = 1<<cf; exposes `coeff_frac`.
                       BiquadFixed: 5-term MAC in a wide acc (std.meta.Int(.signed, 2*bits+4); i36→i64
                       for q15), round-to-nearest >>cf then saturate on store, DF1 state x1,x2,y1,y2 at
                       the lane q-format. + q15 identity & impulse-decay/limit-cycle unit tests.
src/io.zig      (M)  The embedded I2S-DMA HAL (target-generic freestanding stub): I2sDma(num,N) (a 2N-
                       frame circular ping-pong buffer, .bss, active-half toggled by onHalfTransfer/
                       onTransferComplete), I2sDmaSource(num,N) (Source: active RX half → graph),
                       I2sDmaSink(num,N) (Sink: graph → active TX half). + ping-pong / round-trip tests.
src/root.zig    (M)  The `embedded` namespace: N=64, num=q15(W=1), Source/Gain/Biquad/Sink, node_blocks,
                       chainGraph()/graph_ir, Exec (the bound comptime Executor), footprint_bytes. + the
                       comptime-footprint-constant test. `io` doc updated to mention the I2S transport.
src/smoke_freestanding.zig (M)  Extended: keeps pan_smoke_footprint (f32 commit gate); adds the q15
                       render path — .bss Exec + RX/TX I2sDma, pan_i2s_bind, pan_i2s_render_isr(which),
                       pan_smoke_footprint_q15. The freestanding object compiling = the discharge.
scripts/generate.py (M)  _fix_biquad added to _FIXED_REFERENCES (DF1, pre-quantized Q2.cf integer coeffs
                       b0_q…a2_q, bit-exact int arithmetic mirroring BiquadFixed).
tests/vectors/biquad_q15.json (NEW)  q15 biquad gold manifest (stable resonant LP, a1_q=-14000 > 1.0).
tests/gold_fixedpoint_test.zig (M)  + the bit-exact q15 Biquad gold test.
tests/embedded_chain_test.zig (NEW, gate)  bound-executor ≡ hand-run (bit-exact) + token-shape +
                       footprint + the FixedBufferAllocator zero-heap runtime-engine test.
tests/biquad_fixedpoint_yoneda_test.zig, tests/embedded_hal_yoneda_test.zig (NEW, autonomous).
bench/embedded_q15.zig (NEW)  the P10 Benchmark deliverable: q15 .bss footprint (comptime) + q15-vs-f32
                       Gain/Biquad throughput. (Measures, never asserts — §0.9.)
build.zig (M)  + the three new test harnesses + the q15 bench registered.
dev-notes/fixed-point-biquad.md (M)  Status flipped to RESOLVED; the how-it-was-closed section added.
```

## 3. Verify — reproduce green (from repo root)
```sh
zig build test                          # Debug — 101/101 steps, 944/944 tests, EXIT 0 (check the exit code!)
zig build test -Doptimize=ReleaseSafe   # exit 0
zig build test -Doptimize=ReleaseFast   # exit 0 (+2 skipped)
zig build smoke                         # freestanding ReleaseSmall: f32 commit gate + q15 render path
zig build cross-linux                   # x86_64-linux-gnu ALSA seam
zig build fmt-check
zig build neg-compile                   # the two must-fail fixtures
zig build bench -Dbench-gate            # footprint baseline 8192 B held (q15 biquad state is in the
                                        #   instance, NOT the pool — the commit footprint is unchanged)
# Regenerate the q15 biquad gold blobs (git-ignored): python3 scripts/generate.py tests/vectors/biquad_q15.json
```
Carried cosmetic noise: aliasing_message_test / comparator_test / the neg-compile fixtures drive reject
paths that print `error: …` via `std.debug.print` (and `@compileError` in the neg fixtures). These lines
appear in the output but **do NOT fail a step** — after the §1 fix the build is **101/101 steps
succeeded, 944/944 tests passed, exit 0**. (The earlier confusion: I assumed a "1 failed step" was this
noise; it was actually the real io.zig compile error. Always trust the exit code, not the printed lines.)

## 4. Design decisions & deviations (Rule 7 / Rule 12)

- **Fixed-point Biquad q-format (decided here, not in the spec).** Coefficients ride in Q(2.cf),
  cf = bits-3 (a fixed format, no per-section `postShift`) — simpler than CMSIS's Q1.14+postShift and
  bit-exact-reproducible. The accumulator is `2*bits+4` wide (i36→i64 for q15), NOT `num.Acc` (i32 for
  q15): the plan §10 wording said "MAC in i32 Acc," but a sum of five (lane × supra-unity coeff)
  products overflows i32 — `num.Acc` is right for `Gain`'s single product, the biquad's 5-term MAC
  locally widens. (The dev-note's earlier reasoning was correct; this is what shipped.) DF1 (not DF2T)
  for the fixed path so the feedback state stays at the clean lane q-format (better limit-cycle behaviour).
- **The bit-exact gold carries pre-quantized integer coeffs** (`b0_q…a2_q`), mirroring the gain_q/pan_lq
  convention, so no transcendental filter design enters the comparison.
- **"`.bss` behind a `FixedBufferAllocator`" (spec §10 work-item) — CLOSED two ways.** (i) The shipped
  embedded path is the comptime `Executor` whose colored pool IS a static `.bss` byte array (no allocator
  needed — the blocks allocate nothing). (ii) A real `FixedBufferAllocator` over a static `.bss` buffer
  is ALSO demonstrated, tested: `tests/embedded_chain_test.zig` builds + commits + renders the q15 chain
  through the RUNTIME engine backed by an FBA (no heap fallback), so commit succeeding IS the proof of
  zero-heap operation — "the same code, specialized" to a no-heap target by swapping the allocator.
- **No concrete MCU (catalog §9.3 LOCK).** The I2S-DMA HAL is the **target-generic freestanding stub**:
  the portable circular-buffer + active-half + ISR-shaped entry model is real; the register-level DMA
  poke / IRQ-vector binding (and the STM32-HAL TC-suppression caveat to verify) are left as a documented
  seam. A concrete MCU + CMSIS-DSP/Helium is **Phase 19** (requires a spec amendment, §0.8).
- **No-op token on fixed-point.** `enterRealtimeThread()` selects its FP-env action by ISA: aarch64/x86
  set FTZ (harmless on the integer path), other archs are a structural no-op. The native-arch
  freestanding stub (M3 = aarch64, has an FPU) therefore still sets FTZ; on a real FPU-less MCU the
  arch/soft-float branch is the no-op. The **API shape is identical across precisions** (the token-gated
  render entry won't compile without a token, q15 or f32) — that invariance is what P10 pins; the
  hardware no-op is target-selected at Phase 19.
- **Embedded chain is mono q15.** Multi-channel I2S deinterleaves at the boundary with the same
  `io.deinterleave`/`interleave` codec the desktop sinks use; the smoke/gate chain is mono (`C=1`, plane
  == frame) so no transpose is exercised there.

## 5. Surface coverage audit (Rule 12 — every §10 work item, honest verdict)
Work item 1 — **DONE.** `Gain`/`Biquad` at `Numeric{i16,i32,saturate,W}`; q15 saturating kernels;
**bit-exact q15 gold** (Gain + Biquad + ConstantPowerPan). The fixed-point Biquad carry is closed.
Work item 2 — **DONE.** Comptime graph build + `commitComptime`/`Executor` end-to-end at comptime
(`pan.embedded`); one `.bss` pool (the Executor's, footprint-sized); the `SampleMux` vtable absent on the
comptime path (the boundary blocks ARE the bridge; render monomorphizes/inlines).
Work item 3 — **DONE (target-generic stub).** I2S-DMA HAL: circular `2N` buffer, HT/TC → active half,
ISR-shaped render entry; N comptime-known; the no-op-token API shape. Concrete-MCU register layer +
STM32-HAL caveat are Phase-19-gated (the LOCK), not dropped.

**Re-audit nuances (the "etc." in work-item 1, and evidence for the gate criteria):**
- **Other blocks at q15 — no silent miscomputation (Rule 12).** Beyond Gain/Biquad: `spatial.ConstantPowerPan(q15)`
  works (bit-exact gold); `time.{UnitDelay,DelayLine,PlanarDelayLine}` are element-generic pure copies, so
  correct at any lane incl. q15; the `fx.zig` feedback kernels (Comb/Allpass/KarplusStrong/Ladder/FdnMatrix)
  **fail loud** at integer precision (`requireFloat` `@compileError`) — they are NOT in the P10 gate chain
  (gain→biquad→sink) and the DF1/wide-acc technique that closed the biquad is now their template but not
  yet ported. Nothing computes wrong q15 audio.
- **"render fully inlines, no vtable" — concretely verified, not just claimed.** Emitting asm for the
  freestanding q15 object (`zig build-obj src/smoke_freestanding.zig -target aarch64-freestanding
  -O ReleaseSmall -femit-asm=…`) shows **zero `blr` (indirect calls)** in the whole object; the render ISR
  is one ~104-line straight-line function — the source/gain/biquad/sink chain fully monomorphized/inlined.
- **q15 footprint = 256 B** (2 ping-pong × 64 frames × 2-byte lane) — half the f32 figure, as expected.

## 6. What P11 needs (from plan Phase 11)
P11 = roadmap step 6c completion: **modulation / control blocks** — the library blocks that DRIVE
parameter ports. Read first: plan §11; `catalog.md` §2.4 (parameter-port consumer/producer contract),
§8.9 (data-gating only — conditional execution is permanently out of scope); `pan_type_and_numeric_model.md`
§1.1; `pan_categorical_bridge_and_roadmap.md` §2 (modulation taxonomy; adaptive processors fuse-or-decouple);
`pan_io_realtime_and_pipeline.md` §7 (per-block ramp; `set`/`schedule` xor a wired parameter edge). Build
(`src/env.zig`, `src/gen.zig` control side, `src/fx.zig`): an LFO (zero-input `Map` source → `Scalar`),
an ADSR envelope (gate→amplitude `Map`), a feature→param map (wire into a filter's `param.cutoff`);
adaptive processors in both fused and decoupled realisations; data-gating blocks (a VAD/onset/power gate
emits a `Scalar` the consumer multiplies/freezes on — the static op-list stays unchanged, no skipped ops).
Gate: an LFO→cutoff sweep zipper-free and **bit-identical** to the same sweep via `set` (P3); a
feature→param chain modulates correctly; data-gating leaves the op-list static. The parameter-port
machinery (P5: `node.param.<name>`, ramp/hold, one-source P2, `setParam`/`applyParamInputs`) is the
substrate P11's producers wire into — it already exists and is exercised.

**Note for P11:** Phase 11 is ALSO where the catalog §4.4 `ChannelMap`-over-a-composite functoriality
obligation lands (`Voice` = composite block, flattened — the P9 handoff flagged this as Phase-11-gated).
