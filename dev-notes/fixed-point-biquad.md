# Dev-note: fixed-point `Biquad` is deferred (a deliberate `@compileError`)

**Status:** `src/filters.zig` `Biquad(num)` supports **float lanes only** (f32/f64).
Instantiating it at an integer precision (`i16`=q15, `i32`=q31, …) is a **compile
error** by design, not an omission:

```zig
// src/filters.zig — the integer branch of Biquad.process
@compileError("pan: fixed-point Biquad is not yet supported — a q-format biquad
   needs wider coefficient scaling + accumulator headroom (the embedded-precision
   phase). Use a float precision (f32/f64).");
```

## Why it is NOT a straight q-format port

A biquad's coefficients break the simple "multiply, `>>frac`, saturate" mould the
`Gain`/`ConstantPowerPan` integer paths use:

1. **Coefficients exceed unity.** A resonant section has `a1 ≈ -1.9`, `a2 ≈ 0.95`.
   A plain q15 number only spans `[-1, 1)`, so `a1 = -1.9` **cannot be stored at
   all**. A real implementation needs a wider coefficient Q-format — e.g. CMSIS-DSP's
   `arm_biquad_cascade_df1_q15` uses **Q1.14 coefficients + a `postShift`** so
   `|coeff|` up to ~2 (or ~4) is representable.
2. **Accumulator headroom.** The 5-term MAC `b0·x + b1·x₁ + b2·x₂ − a1·y₁ − a2·y₂`
   must accumulate in a strictly wider type (i64 for a q15 section) with guard bits,
   then a single rounding shift + saturate on store. A per-multiply `>>frac`
   (as `Gain` does) loses the inter-term headroom.
3. **Limit cycles.** Quantization *inside* the feedback loop can drive small-signal
   self-oscillation (a non-decaying "limit cycle") that the float path never
   exhibits. Mitigation (error feedback / dithered quantization in the loop) is part
   of a correct fixed-point IIR, not an afterthought.

A naive q15 biquad would therefore compute **silently wrong audio** for ordinary
filters. Per the project's fail-loud rule, the kernel refuses to compile rather than
ship that.

## What closing it requires (the embedded-precision phase)

- Adopt a fixed-point coefficient scheme (recommended: mirror CMSIS-DSP DF1 q15 /
  DF2T q31 — Q1.14 coeffs + `postShift`, Q15/Q31 state, rounding, saturation).
- Pin a **bit-exact** reference in `scripts/generate.py` that implements the *same*
  integer arithmetic (the legitimate fixed-point gold contract — an independent
  NumPy implementation of the same spec-defined ops), then add `biquad_q15` /
  `biquad_q31` gold vectors.
- Add limit-cycle / stability checks to the test suite.

This is genuine embedded-DSP design + validation work and belongs to the embedded
bring-up phase (the plan's q15/MCU phase), where fixed-point is the actual target.
The desktop vertical slice is f32, so nothing in P1–P5 needs it.

## What already works in fixed-point

`Gain(q15)` and `ConstantPowerPan(q15)` **do** run — they are single multiplies with
`|coeff| ≤ 1`, representable in q15, validated by **live bit-exact gold vectors**
(`tests/gold_fixedpoint_test.zig`, manifests `tests/vectors/gain_q15.json` and
`pan_q15.json`). The panner takes pre-quantized integer gains via `gains_q` so its
fixed-point path carries no runtime trig and is bit-exact-testable. So fixed-point
is not absent — only the one block where it is genuinely hard is gated off.
