# Dev-note: solving filters in fixed-point (q15/qN)

A primer for pan contributors. How to take a filter that works in `f32` and make it
compute **correct, bit-exact** audio in fixed-point integers (q15 and friends), the
way `Gain`, `ConstantPowerPan`, and `Biquad` do today. Grounded in the code as of P10.

---

## 0. Why fixed-point is its own discipline

On an FPU-less MCU the lane is an integer (`i16` = q15 by default; `i32` = q31).
Everything you got for free with floats now needs a decision:

- **Range.** A q15 number is `raw / 2^15`, raw ∈ [−32768, 32767] → values in **[−1, 1)**.
  A coefficient bigger than 1 (a resonant `a1 ≈ −1.9`) **cannot be stored in q15 at all**.
- **Rounding.** Every multiply produces more fractional bits than the lane holds; you
  must shift them off, and *how* you round (toward zero / nearest / −∞) is part of the
  contract — get it wrong and the output drifts a bit on every sample.
- **Overflow.** A sum of products overflows a same-width integer; you need a wider
  accumulator with guard bits.
- **Saturation.** When a result exceeds the lane bound it must **clamp**, never wrap
  (a wrap turns a loud transient into a sign flip — an audible click). pan's Numeric
  carries `saturate = true` for integer lanes for exactly this.
- **Limit cycles.** Quantization *inside a feedback loop* can sustain a tiny
  non-decaying oscillation a float filter never shows. This is the genuinely hard part.

The project rule (Rule 12): a kernel that can't do fixed-point correctly **fails loud
with `@compileError`** rather than shipping silently-wrong audio. So the path is:
fail loud → apply the recipe below → bit-exact gold + limit-cycle tests → enable.

---

## 1. Q-format 101 (the two formats you juggle)

- **The lane format = q(`lane_frac`)**, `lane_frac = bits − 1`: q15 for i16, q31 for
  i32, q7 for i8. Full-scale is one bit below the sign; range [−1, 1). Samples and
  filter *state* live here.
- **The coefficient format = Q(2.`cf`)**, `cf = bits − 3` (so q15 → Q2.13). Two integer
  bits above the sign give the range **[−4, 4)** — enough for any stable second-order
  section's feedback coefficient (|a1| < 2, |a2| < 1) and reasonable forward gains, with
  headroom. This is `biquadCoeffFrac` in `src/filters.zig`; the lane-aware `Coeffs(T)`
  stores integer coefficients in this format (its identity default is `b0 = 1 << cf`).

Key arithmetic identity: a q(lane) value × a Q(cf) coefficient is a **q(lane + cf)**
product. To land back in q(lane) you **shift right by `cf`** (with rounding), then
saturate to the lane.

---

## 2. The four-step recipe

This is the whole technique; everything below is application.

1. **Coefficients → Q(2.cf).** Store them in the wider format so |coeff| > 1 is
   representable. Quantize a real coefficient round-half-away-from-zero and saturate
   (`scripts/generate.py:_round_coeff` is the reference; or precompute the integers).
2. **Accumulate in a wide integer.** Form every product and the running sum in
   `Wide = std.meta.Int(.signed, 2*bits + 4)` (i36 → lowered to i64 for q15). The `+4`
   guard bits cover summing several products without overflow. Do **not** shift after
   each multiply — that discards the inter-term headroom.
3. **Round + saturate only on store.** Once, at the end:
   `y = clamp((acc + bias) >> cf, laneMin, laneMax)` with `bias = 1 << (cf − 1)` for
   round-to-nearest. Zig's signed `>>` is an arithmetic shift (floor toward −∞); the
   bias makes it round half up. `std.math.clamp` then saturates so `@intCast` to the
   lane never traps.
4. **Keep persistent state at the lane format** (when there's feedback). The feedback
   path should see the clean, already-rounded q(lane) signal, not a wide intermediate —
   this is the single biggest limit-cycle mitigation. (For integrator-heavy loops, see
   §5 — sometimes you keep state at *extended* precision instead.)

---

## 3. Worked case A — a single multiply (`Gain`, `ConstantPowerPan`)

No accumulation, `|coeff| ≤ 1` (fits the lane format directly). The whole op is
`src/simd.zig:qMulStore`:

```zig
pub fn qMulStore(comptime T: type, comptime Acc: type, x: T, coeff: T, comptime frac: comptime_int) T {
    const prod: Acc = @as(Acc, x) * @as(Acc, coeff);     // q(frac+frac) in the wider Acc
    const bias: Acc = if (frac > 0) (@as(Acc, 1) << (frac - 1)) else 0;
    const shifted: Acc = (prod + bias) >> frac;          // round to nearest, back to q(frac)
    const clamped = @min(@max(shifted, minInt(T)), maxInt(T)); // saturate
    return @intCast(clamped);
}
```

Here `Acc` is the Numeric's default accumulator (`i32` for q15) — fine, because there's
exactly **one** product, no sum. `Gain(q15)` is just this per element; `ConstantPowerPan(q15)`
is two of them (L and R gains). Both are bit-exact-gold-tested (`tests/gold_fixedpoint_test.zig`,
`tests/vectors/{gain,pan}_q15.json`).

---

## 4. Worked case B — the IIR MAC (`Biquad`)

This is the template for any feedback filter. `src/filters.zig:BiquadFixed`, **direct
form I** (DF1):

```zig
const cf   = biquadCoeffFrac(T);                          // 13 for q15
const Wide = std.meta.Int(.signed, 2*@bitSizeOf(T) + 4);  // i36 -> i64 for q15
const bias: Wide = 1 << (cf - 1);
// state x1,x2,y1,y2 are q15 (lane format); coeffs are Q2.13
for (xs, ys) |x, *y| {
    const acc: Wide =                                      // q(15+13) = q28
        @as(Wide, c.b0)*@as(Wide, x)  + @as(Wide, c.b1)*@as(Wide, x1) + @as(Wide, c.b2)*@as(Wide, x2)
      - @as(Wide, c.a1)*@as(Wide, y1) - @as(Wide, c.a2)*@as(Wide, y2);
    const yv: T = @intCast(std.math.clamp((acc + bias) >> cf, lo, hi)); // round>>cf, saturate -> q15
    x2 = x1; x1 = x;  y2 = y1; y1 = yv;                    // DF1: keep input & output history at q15
    y.* = yv;
}
```

Two design choices worth dwelling on:

- **Why a 5-term wide MAC, not `num.Acc`.** Five products of (q15 × supra-unity Q2.13)
  can reach ~2^33 — `i32` (`num.Acc` for q15) **overflows**. `num.Acc` is correct for
  `Gain`'s single product; an IIR section needs the locally-widened `Wide`. (The plan's
  "MAC in i32 Acc" wording is an imprecision corrected here — see
  `dev-notes/fixed-point-biquad.md`.)
- **Why DF1, not the float path's DF2T.** DF2T's two state words are *accumulator-scale*
  intermediates; quantizing them to q15 would feed rounding back into the loop and
  worsen limit cycles. DF1 keeps the state as the clean q15 input/output history, so the
  feedback sees the proper quantized signal.

---

## 5. Limit cycles (the hard part) and how to tame them

A **limit cycle** is a small, non-decaying oscillation a fixed-point feedback filter
can fall into when quantization error feeds itself. The float version never shows it;
the fixed-point one can buzz at a low level forever after the input stops.

Mitigations, in rough order of "reach for first":

1. **DF1 + round-to-nearest** (what the biquad uses) — keeping state at the clean lane
   format and rounding (not truncating) is often enough for second-order sections.
2. **Extended-precision state.** For integrator-heavy loops (a Moog **ladder**:
   `s += g·(in − s)` over four cascaded stages), store the stage states at *more*
   fractional bits than the lane (e.g. q24 in an `i32`) and only quantize to q15 at the
   output. This keeps the rounding *out of* the feedback path — the integrator analog of
   "accumulator headroom."
3. **Error feedback** (a.k.a. noise shaping in the loop) — carry the quantization
   residual `(acc − (yv << cf))` forward and add it into the next sample's accumulator,
   pushing the error energy out of band.
4. **Dithered quantization in the loop** — add a tiny dither before the shift so the
   error decorrelates instead of locking into a cycle.

Whatever you pick, **prove it**: a limit-cycle test drives an impulse/pluck, stops the
input, and asserts the tail magnitude decays below the early response (no sustained
oscillation). `src/filters.zig` has exactly such an impulse-decay test for `BiquadFixed`.

---

## 6. The bit-exact gold contract (how correctness is judged)

Fixed-point lanes are compared **bit-exact** (never tolerance — tolerance forgives a
different arithmetic; the whole point is that the integer arithmetic is *defined*). So
the oracle must be an **independent re-derivation of the same integer ops**, not a copy
of the Zig kernel. The reference lives in `scripts/generate.py`:

- `_q_mul_store` — the bit-exact mirror of `simd.qMulStore` (`(x*coeff + bias) >> frac`,
  clip). `numpy`'s `>>` on `int64` is arithmetic, matching Zig's signed `>>`.
- `_round_coeff` — round-half-away-from-zero coefficient quantization.
- `_fix_biquad` — DF1 over **pre-quantized integer coefficients** carried in the
  manifest (`b0_q…a2_q`). Using pre-quantized integers (like `gain_q`, `pan_lq`) keeps
  any transcendental (filter design, `10^(db/20)`, `cos/sin`) **out of the bit-exact
  comparison** — a 1-ULP f64-vs-f32 difference there would shift every output sample.

To add a fixed-point gold for a new kernel:
1. Add `_fix_<block>` to `_FIXED_REFERENCES` in `scripts/generate.py` — pure-integer,
   independent of the Zig code.
2. Add `tests/vectors/<block>_q15.json` with pre-quantized integer coefficients and
   `"tolerance": { "bit_exact": true }`. Make the coefficients genuinely exercise the
   hard case (e.g. a feedback coefficient with |a1| > 1 — below `−(1 << cf)` in Q2.cf).
3. Add a gold test (model on the `Biquad(q15)` test in `tests/gold_fixedpoint_test.zig`):
   read the integer coeffs from the manifest, run the real kernel, assert `h.bitExact`.
4. Regenerate the (git-ignored) blobs: `python3 scripts/generate.py tests/vectors/<block>_q15.json`.

Then dispatch a Yoneda test-writer (Rule 14) for the kernel + an independent in-test
re-derivation, and add limit-cycle/stability tests.

---

## 7. Step-by-step: fixed-pointing a new filter

1. **Classify the arithmetic.** Single multiply (`|coeff| ≤ 1`) → §3 (`qMulStore`,
   `num.Acc` is fine). MAC / sum of products, or |coeff| > 1, or feedback → §4 (wide
   `Wide` acc + Q2.cf coeffs). Integrator loop → §4 + §5 extended-precision state.
2. **Split float vs fixed** like `Biquad`: `return if (isFloat(num.Lane)) FloatImpl
   else FixedImpl;`. Keep the float path byte-identical; write the fixed path fresh.
3. **Coefficients → Q(2.cf)** integer fields (lane-aware `Coeffs`-style).
4. **Size the accumulator** to hold the worst-case sum (`2*bits + ⌈log2(#terms)⌉ + slack`).
   For an N-way sum (e.g. an `FdnMatrix` row), add `log2(N)` guard bits.
5. **Pick the canonical form.** DF1 for IIR (state at lane format). For integrators,
   extended-precision state.
6. **Round + saturate on store** (§2 step 3), once.
7. **Write the independent oracle + manifest + gold test** (§6).
8. **Write limit-cycle/stability tests** (§5) — non-optional for feedback kernels.
9. Until 7–8 pass, **keep the integer path `@compileError`** (fail loud).

---

## 8. Applying it to the `fx` feedback kernels (current fail-loud → enabled)

`src/fx.zig`'s `Comb`/`Allpass`/`KarplusStrong`/`Ladder`/`FdnMatrix` are float-only
today (`requireFloat`). Difficulty ranking when porting with the recipe above:

| Kernel | Recurrence (float) | Fixed-point work | Difficulty |
|---|---|---|---|
| `Comb` | `y = x + g·y[n−D]` | one product, `g<1`, state already q15 — a 1-tap MAC | easy |
| `Allpass` | `y = −g·x + v; ring = x + g·y` | two products, `g<1`, intermediate `y` at q15 | easy |
| `FdnMatrix` | `out[i] = x[i] + Σⱼ A[i][j]·w[j]` | N-way wide sum (`log2(N)` guard bits); **stateless** ⇒ no internal limit cycle (loop closes through external `DelayLine`s, already q15) | moderate |
| `KarplusStrong` | `y = x + ½·damping·(tap+tap_prev)` | sum the two taps before `>>1`; damping≤1; needs a decay/stability test | moderate |
| `Ladder` | 4 cascaded `s += g·(in−s)` + resonance `k·s4` (k up to 4) | Q2.cf coeff for `k`; **extended-precision stage states** (§5) to keep rounding out of the resonant loop | hard |

The hard "is it even possible / how" question is answered by the biquad. What remains
per kernel is application + its bit-exact gold + a stability gate.

---

## 9. Pitfalls

- **Don't `>>frac` per multiply** in a MAC — accumulate first, shift once. (Headroom.)
- **Don't store IIR feedback state at accumulator scale** — keep it at the lane format
  (DF1) or extended precision; never the lossy DF2T intermediate.
- **Don't let a transcendental into a bit-exact gold** — carry pre-quantized integer
  coefficients in the manifest.
- **Don't compare fixed-point under tolerance** — bit-exact only (it's defined math).
- **Match the round mode exactly** between Zig and the NumPy oracle (`(acc+bias) >> cf`,
  arithmetic shift) — a single off-by-one rounding diverges every sample.
- **Saturate, never wrap** — clamp on store (`saturate = true` is in the Numeric for a
  reason); a wrap is an audible click.
- **Coefficients > 1 need Q2.cf, not the lane format** — the #1 reason a naive q15
  biquad is wrong.

---

## 10. Where the code lives

| Concern | File |
|---|---|
| Single-multiply q-store (`qMulStore`) | `src/simd.zig` |
| Lane-aware `Coeffs`, `BiquadFixed`, `biquadCoeffFrac`, `Gain` fixed path | `src/filters.zig` |
| `ConstantPowerPan` fixed path (`gains_q`) | `src/spatial.zig` |
| Float-only feedback kernels (the fail-loud `requireFloat`) | `src/fx.zig` |
| The Numeric trait (`Lane`/`Acc`/`saturate`/`W`) | `src/numeric.zig` |
| Independent integer oracle (`_q_mul_store`, `_round_coeff`, `_fix_*`) | `scripts/generate.py` |
| Bit-exact gold tests + manifests | `tests/gold_fixedpoint_test.zig`, `tests/vectors/*_q15.json` |
| The deferred→closed history + rationale | `dev-notes/fixed-point-biquad.md` |
