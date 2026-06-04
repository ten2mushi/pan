# Handoff — end of Session 10 (P11 "Modulation / control blocks") → into P12

> **Status:** P0–P10 + **P11 implemented, full-surface, and green.** Advisory handoff, not a spec:
> `specifications/` + `pan_implementation_plan.md` remain the source of truth.
> **Date:** 2026-06-04. **Toolchain:** `zig 0.16.0` (re-run `zig version` at P12 start — Rule 13).
> P11 = roadmap step 6c: the **library modulation blocks** that DRIVE parameter ports — LFO, ADSR,
> feature→param map, adaptive processors (fused + decoupled), and data-gating — wired into the P5
> parameter-port substrate with **no core change**.

---

## 1. Ownership statement (honest, Rule 12)

The P11 gate (plan §11 success criteria) is **met and green across the four-mode matrix** plus
smoke / cross-linux / fmt-check / neg-compile (all exit 0). Verify the EXIT CODE, never pattern-match a
printed test count (the carried reject-path noise — comparator/gold "allclose fail" lines,
aliasing_message "error:" lines, the neg-compile `@compileError`s — prints by design and fails NO step):

- **An LFO→param sweep is zipper-free and bit-identical to the same sweep via `set`** — proved
  pan-vs-pan, byte-for-byte (`expectEqualSlices(u8, ...)`) in `tests/modulation_test.zig`. The wired
  parameter edge and the external `set` verb both arrive through the consumer's `setParam` and drive the
  SAME `control.Param`/`control.Ramp`, so the rendered audio is identical; the wire is just an alternate
  source of the same per-block-ramped target.
- **A feature→param chain modulates correctly** — a control source → `FeatureMap` (affine rescale) →
  `Vca.param.gain` settles the gain to `scale·feat + bias` and scales the audio.
- **Data-gating leaves the op-list static** — a `PowerGate` keyed off a sidechain mutes a constant tone
  through a `Vca`; `op_count` is unchanged whether the key is loud or silent. Gating is DATA (a `Scalar`
  the consumer multiplies), never a skipped op — the static, unconditional op-list is preserved.

**Yoneda dispatch (Rule 14):** two autonomous `yoneda-test-writer` agents (each loaded `zig-0-16`,
verified by compiling). **57 tests, all green, ZERO bugs:** `tests/modulation_yoneda_test.zig` (34 —
Lfo per-waveform value oracles + the `out.len·increment` phase law + broadcast-storage contract; Adsr
full independent state-machine oracle + mid-block crossover + gate boundary; FeatureMap affine/clamp +
aliasing-safe in-place≡out-of-place), `tests/dynamics_yoneda_test.zig` (23 — Vca multi-block wired≡set
bit-exact linear-glide; Agc fused one-pole + max_gain silence clamp; AgcController decoupled convergence
+ broadcast; PowerGate hysteresis hold / strict-`>` open boundary / `{0,1}`-only).

Test totals: **111/111 steps, 1052/1052 tests, exit 0** (Debug & ReleaseSafe; ReleaseFast identical),
up **+108** from P10's 944 (new inline tests + the gate suite + 85 Yoneda across 3 files + 2 NumPy-gold
tests). (The gold tests skip gracefully when the git-ignored blobs are absent — `1051/1052, 1 skipped`
per missing blob — and run+pass once `python3 scripts/generate.py tests/vectors/{lfo,adsr}_f32.json`
materializes them.)

**Independent audit (post-completion).** A fresh general-purpose agent — given only the requirement
sources (brief, plan §11, the P11 specs), NOT this handoff or any summary of what was built — read the
spec, derived the checklist itself, explored the code, ran the four-mode matrix (all exit 0, trusting
exit codes), confirmed the NumPy-gold tests actually RUN and are byte-reproducible, and independently
decided ChannelMap §4.4 is Phase-9 scope (not P11). Its verdict: **"P11 FULLY COVERED"** — every Work
item, gate criterion, and Yoneda/§5.7b obligation genuinely implemented and tested, with the only
un-shipped surface (decoupled AEC/howl) being the inline-justified Rule-2 deferral below. It also flagged
one pre-existing §0.2 cosmetic deviation (a "P10" phase label in fx.zig's feedback-kernel header, from an
earlier phase) — since **fixed**; a full `src/` re-scan is now clean of spec/section/phase refs.

---

## 2. What was built (the deltas)

```
src/gen.zig  (NEW)  `Lfo` — a control-rate LFO: a zero-sample-input `Map` SOURCE emitting `Scalar(f32)`.
                     Fields phase (cycles [0,1)), increment (cycles/sample), amplitude, offset, waveform
                     (enum sine/triangle/saw/square). Emits one control value per call (the wave at the
                     block-start phase) broadcast across all out lanes, then advances phase by out.len.
src/env.zig  (NEW)  `Adsr` — gate→amplitude control SOURCE (`params = .{ .gate = Scalar(f32) }`); a
                     per-sample-internal ADSR state machine advanced out.len samples/call, emitting the
                     block-start level (broadcast). `FeatureMap` — affine `Scalar→Scalar` rescale
                     (out = clamp(scale·in + bias, lo, hi)), rate-1:1, aliasing_safe.
src/fx.zig   (M)    + `Vca(num)` (gain via `param.gain`, control.Param+Ramp — the bit-exact-to-`set`
                     consumer; the multiply target for data-gating), `Agc(num)` (FUSED adaptive: block
                     RMS → one-pole gain toward target/level, applied per-sample-ramped), `AgcController(num)`
                     (DECOUPLED: same estimate, emits the gain as `Scalar(f32)` to drive a separate `Vca`),
                     `PowerGate(num)` (data-gating: block power → `{0,1}` gate with hysteresis), and the
                     adaptive processors `Compressor(num)`/`CompressorController(num)` (fused+decoupled
                     dynamics), `Aec(num,taps)` (NLMS echo canceller, 2 sample inputs), `HowlSuppressor(num,taps)`
                     (leaky-NLMS feedback canceller). All float-only (`requireFloat`) + `blockPower`/
                     `compressorGain`/`followEnvelope` helpers. + the `control` import.
src/filters.zig (M) + `OnePole(num)` — a one-pole low-pass whose **cutoff is a parameter port**
                     (`onepole.param.cutoff`, the ramped coefficient): the canonical filter an LFO sweeps.
                     control.Param + control.Ramp on the coefficient; float-only for now. + the `control`
                     import. The literal "LFO→cutoff" gate target.
src/root.zig (M)    + `pan.gen`/`pan.Lfo`, `pan.env`/`pan.Adsr`/`pan.FeatureMap`, `pan.OnePole`, and
                     `pan.Vca`/`pan.Agc`/`pan.AgcController`/`pan.PowerGate` (the `gen`/`env` stubs are
                     now real imports).
scripts/generate.py (M)  + `_ref_lfo`/`_ref_adsr` (NumPy control-rate oracles) in `_REFERENCES`.
tests/vectors/{lfo,adsr}_f32.json (NEW)  committed gold manifests (blobs git-ignored, generate-on-demand).
tests/modulation_test.zig (NEW, gate)  the four-property gate over the REAL runtime builder→engine path
                     (LFO→OnePole.cutoff bit-exact-to-set; a real feat.Rms feature→param chain; data-gating).
tests/modulation_gold_test.zig (NEW)  the external-NumPy-oracle ≈ gold for Lfo/Adsr (allclose).
tests/modulation_yoneda_test.zig, tests/dynamics_yoneda_test.zig (NEW, autonomous).
build.zig    (M)    + the four new test harnesses registered.
```

## 3. Verify — reproduce green (from repo root)
```sh
zig build test                          # Debug — 107/107 steps, 1015/1015 tests, EXIT 0 (check the exit code!)
zig build test -Doptimize=ReleaseSafe   # exit 0
zig build test -Doptimize=ReleaseFast   # exit 0
zig build fmt-check                     # exit 0
zig build smoke                         # exit 0
zig build neg-compile                   # exit 0
zig build cross-linux                   # exit 0
```

## 3b. Surface re-audit (post-challenge) — gaps found and closed

A second, adversarial pass over the literal §11 surface (prompted by a "do you take full
ownership?" challenge) found **three genuine gaps** in the first revision, all since **closed and
green** (totals above already include them):

- **LFO→*cutoff* (was LFO→gain).** §11 says "wire into a filter's `param.cutoff`" and the gate says
  "LFO→cutoff sweep". The first revision wired `Lfo → Vca.gain` (parameter-agnostic but not the literal
  filter cutoff). **Closed:** added `filters.OnePole(num)` — a one-pole low-pass whose cutoff is a
  parameter port (the ramped coefficient), and the GATE test now wires `Lfo → OnePole.param.cutoff` and
  proves it byte-identical to the same sweep via `set`.
- **LFO/ADSR gold vectors vs NumPy (was hermetic-only).** The §11 Yoneda dispatch names "LFO/ADSR gold
  vectors vs SciPy. Oracle = SciPy" as a distinct obligation; the first revision shipped only hermetic
  in-test oracles. **Closed:** added `scripts/generate.py` `_ref_lfo`/`_ref_adsr` (NumPy, control-rate
  block structure), committed manifests `tests/vectors/{lfo,adsr}_f32.json`, and
  `tests/modulation_gold_test.zig` (loads the generated blob, `allclose` vs the external oracle, graceful
  skip if absent — verified it skips when the blob is removed and passes when present).
- **feature→param used a real feat block (was a constant-Lfo stand-in).** **Closed:** the feature→param
  test now roots on a `feat.Rms` over a crafted power-spectrum frame → `FeatureMap` → `Vca.gain`.

A supposed fourth gap — the **`ChannelMap`-over-a-composite functoriality** test the P9 handoff flagged
as "Phase-11-gated" — is **NOT a P11 item**: the plan puts `Voice`/`VoiceMap` (and that functoriality
obligation) in **Phase 13** (plan §13 work item 3). The advisory P9 handoff mis-scoped it; the plan is
the source of truth (Rule 7). Left for P13.

**Work item 2 — now FULLY covered (the residual closed in a second pass).** Every named adaptive
processor now has a real, tested block:
- **AGC** — `Agc` (fused) + `AgcController → Vca` (decoupled).
- **dynamics** — `Compressor` (fused feed-forward: per-sample envelope follower → soft static gain curve
  `(env/threshold)^(1/ratio−1)`) + `CompressorController → Vca` (decoupled).
- **AEC** — `Aec(num, taps)` (fused NLMS adaptive FIR: mic + far-end reference → echo-cancelled error;
  taps adapt `w += μ·e·x/(‖x‖²+ε)`). A two-sample-input Map; the runtime engine wires and renders two
  input ports end to end (the AEC integration test — `mu = 0` ⇒ verified mic pass-through).
- **howl-suppression** — `HowlSuppressor(num, taps)` (fused **leaky** NLMS feedback canceller: like AEC
  but `w := (1−leak)·w + step`, the decorrelation that tames the correlated-reference bias of a closed
  feedback loop).
Adaptive-FIR convergence is tested structurally (late residual energy ≪ early; taps stay bounded). The
only deliberate Rule-2 deferral remaining for work item 2: the **decoupled** (vector-coefficient
parameter-port) realisation of the *adaptive-FIR* processors — `Aec`/`HowlSuppressor` ship fused only,
because a whole tap-vector coefficient would need a `FeatureFrame`-valued parameter port and an
FIR-apply consumer; the realisation duality is already proven at scalar-coefficient granularity by
`Agc`/`Compressor` (fused AND decoupled), so the vector-granularity decoupling adds no new contract.

## 4. The load-bearing design decision (the control-producer model) + deviations (Rule 7 / Rule 12)

- **A control producer is a zero-sample-input `Map` source emitting `Scalar(f32)`.** This wires into the
  EXISTING parameter-port machinery with **no core change**: the buffer-sizing pass sizes the producer's
  output buffer at the consumer's per-callback demand (`want == N` for a rate-1:1 consumer), and the
  executor's `applyParamInputs` reads only the **first lane** as the per-call coefficient and hands it to
  the consumer's `setParam`. Two mechanical consequences a producer MUST honour:
  - The executor finite-checks (NaN/Inf "poison" guard) EVERY lane of an output buffer, so a control
    producer **fills its whole `out` slice** (broadcasts its single value) — never leaving lanes
    undefined. One-per-call in *semantics*, broadcast in *storage*. (This means a `Scalar` control buffer
    is over-allocated to `N` elements while only `[0]` is consumed — a tiny, harmless footprint cost that
    is exactly how the P5 param edges + P9 feature-output `Scalar` edges were already sized; NOT a new
    behaviour, but worth knowing for P12+ if a control-rate `want=1` sizing is ever wanted as an
    optimization.)
  - `out.len` IS the block size, so a generator advances phase/state by `out.len` per call (control rate:
    one value per render; the consumer's per-block ramp interpolates → zipper-free).
- **Bit-exact-to-`set` mechanism.** The wired edge and external `set` are bit-identical ONLY because both
  funnel through the same `consumer.setParam` → `control.Param`/`control.Ramp`. A future modulation block
  that ramps differently than `set` would break this — keep new consumers on the shared `Param`/`Ramp`.
- **Genericity split.** `Lfo`/`Adsr`/`FeatureMap` are NON-generic (pure f32 control — the control element
  is always `Scalar(f32)`); `Vca`/`Agc`/`AgcController`/`PowerGate` are `(num)`-generic but **float-only**
  (`requireFloat`), like the fx.zig feedback kernels — a gain ramp / level estimate is f32. The Vca/Agc
  gain ramp is f32 even for an f64 lane (the whole control plane is f32); for f32 lanes the gate test is
  bit-exact.
- **Adaptive realisations, both shipped.** Fused (`Agc`, controller+applier in one block, preferred when
  the coefficient is private) AND decoupled (`AgcController` emits a `Scalar` gain → a separate `Vca`,
  making the coefficient a first-class graph value). The per-block one-pole smoothing lives in the
  controller; the per-sample anti-zipper ramp in the `Vca` — zipper-free end to end.
- **Two independent-oracle tiers for `Lfo`/`Adsr` (both shipped).** The hermetic in-test Yoneda oracles
  (a naive re-derivation of each documented formula, different accumulation order, no disk) AND the
  external NumPy gold (`scripts/generate.py` `_ref_lfo`/`_ref_adsr` + committed manifests + the
  blob-loading `modulation_gold_test.zig`, `allclose`). The plan named the latter ("Oracle = SciPy"); it
  is now present, with the hermetic tier as an additional in-process check.

## 5. Code-documentation compliance (the §0.2 rule — fixed this session)

The plan's §0.2 rule: **in-`src/` comments and doc-comments must be self-contained — NO references to
`specifications/*.md` (no "catalog §2.4"), no plan section numbers, no "Phase N"/"roadmap step" wording.**
The first revision of the P11 code violated this (doc-comments cited "Phase 11", "catalog §2.4 P2/P3",
"§5.7b", "catalog §8.9"). **All fixed:** every law is now restated inline in plain prose, naming the law
in words only ("the one-source rule — a wired edge XOR an external set", "data is gated, never an op"),
with zero filename/section/phase tokens. A full re-scan of `src/` confirms the **pre-existing codebase
was already compliant** (its only section-style refs are in *test names*, which §0.4 explicitly permits)
— the deviation was entirely in the new P11 code. Lesson for future sessions: write `src/` comments as
self-contained formal descriptions derived from the code, never as pointers to the spec.

## 6. Surface coverage audit (Rule 12 — every §11 work item, honest verdict; post-re-audit)
Work item 1 — **DONE, literally.** `Lfo` (zero-input `Map` source → `Scalar`), `Adsr` (gate→amplitude),
`FeatureMap` (feature→param), wired into **a filter's `param.cutoff`** — the gate wires `Lfo →
OnePole.param.cutoff` (the new library one-pole low-pass with a real cutoff parameter port) and a real
`feat.Rms → FeatureMap → Vca.gain` feature chain.
Work item 2 — **DONE (full named roster).** AGC (`Agc` fused + `AgcController` decoupled), dynamics
(`Compressor` fused + `CompressorController` decoupled), AEC (`Aec` fused NLMS), howl-suppression
(`HowlSuppressor` leaky-NLMS). Both realisations proven at scalar-coefficient granularity; the
adaptive-FIR vector-coefficient decoupling is the only Rule-2 deferral (see §3b).
Work item 3 — **DONE.** `PowerGate` data-gate emits a `Scalar` the `Vca` multiplies; the op-list stays
static (the gate test asserts `op_count` constant across a loud-key vs silent-key block).

## 7. What P12 needs (from plan Phase 12) + carried obligations
P12 = `VariRate`: drift-ASRC, varispeed, TSM/phase-vocoder, pitch-shift — the bounded-variable-rate
`Rate` family with worst-case static planning and the determinism split (parameter-driven O3-reproducible;
controller-driven ≈-only). Read first: plan §12; `catalog.md` §2.6 (`VariRate` V1–V5); `pan_execution_model.md`
§2.2.1/§6; `pan_io_realtime_and_pipeline.md` §1/§2; `pan_commit_pass_algorithms.md` §6/§7;
`pan_testing_and_vector_contract.md` §5.7f; `pan_developer_experience.md` §2.

**Carried obligations / residuals (surfaced for whoever schedules them):**
- **`ChannelMap`-over-a-composite functoriality** ≈-test — this belongs to **Phase 13** (plan §13, with
  `Voice`/`VoiceMap`), NOT P11 (the P9 handoff mis-scoped it). `combinators.ChannelMap` exists; the
  functoriality test does not.
- **AEC / howl-suppression / a standalone compressor** (§11 work-item-2 named examples) — not
  individually implemented; the fuse-vs-decouple pattern is owned via AGC (see §3b).
- Optional: a `bench/modulation_bench.zig` (no P11 bench added — the control-rate blocks are cheap; a
  throughput bench is low-value but would complete the benchmark surface).
