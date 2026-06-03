# pan — Testing Methodology & Gold-Vector Contract (the ≈ tier, pinned to implementation precision)

> **Status: LOCKED** (2026-06-03; includes the parameter-port amendment, catalog §15 — the §5.7b
> parameter-edge harness; **then §5.7c parallel≡sequential + §5.7d offline-differential harnesses**
> for the COMMITTED Tiers B/C — see [`pan_parallel_and_offline_execution.md`](pan_parallel_and_offline_execution.md),
> catalog §8.10/§2.5/§15). Change-control: conforms to [`catalog.md`](catalog.md); an edit
> that changes a definition or law must update catalog.md and every citing section in the same commit.
> Support document for [`pan_architecture_formalisation.md`](pan_architecture_formalisation.md)
> (the hub). Siblings: [`pan_execution_model.md`](pan_execution_model.md) ·
> [`pan_memory_model.md`](pan_memory_model.md) ·
> [`pan_type_and_numeric_model.md`](pan_type_and_numeric_model.md) ·
> [`pan_io_realtime_and_pipeline.md`](pan_io_realtime_and_pipeline.md) ·
> [`pan_concurrency_and_memory_ordering.md`](pan_concurrency_and_memory_ordering.md) ·
> [`pan_categorical_bridge_and_roadmap.md`](pan_categorical_bridge_and_roadmap.md).
> Defined terms resolve to [`catalog.md`](catalog.md) — the single source of truth (read first).
>
> Scope: the **testing methodology** and the **gold-vector contract** — how every ≈ claim in the
> correctness ledger ([`catalog.md` §12.2](catalog.md)) is discharged in code. This document pins the
> float-comparison policy, the vector-storage policy, the JSON manifest schema, each test harness (its
> mux, its comparison mode, its tier), the build/CI matrix, and the Yoneda test-writer plug-in contract
> (Rule 14). It governs the methodology promised in [`pan_categorical_bridge_and_roadmap.md` §3](pan_categorical_bridge_and_roadmap.md)
> and the prototype success criteria of [`pan_categorical_bridge_and_roadmap.md` §5](pan_categorical_bridge_and_roadmap.md).

---

## 0. What this document is, and the one direction-of-truth reminder

This document specifies *how pan is tested*; it specifies **no new semantics**. Every block's *meaning*
is defined in [`catalog.md`](catalog.md), and the SciPy/NumPy oracle is an **external, independent
truth for DSP numerics** ([`catalog.md` §0.1 oracle-as-external-truth](catalog.md)) — it *tests* an
implementation, it never *defines* a block. This independence is what makes the oracle a Rule 9 check
(it can fail when the business logic is wrong); a self-referential oracle that re-used pan's own kernel
would be worthless. Everything here is the **≈ tested tier** ([`catalog.md` §0.2 the correctness-tier
convention](catalog.md)): empirical evidence that shows the *presence* of bugs, never their *absence*
(Dijkstra). The phrase "the test *is* the proof" is banned corpus-wide ([`catalog.md` §0.2 honesty
rule](catalog.md)); the proven ⊢ obligations live in the type system and the comptime-commit gate, not
here.

> **One genuine ⊢ embedded in this document:** the comptime-commit smoke gate (§7) — *compiling*
> discharges the obligation **for the smoke graph only** ([`catalog.md` §8.5 comptime-commit smoke
> gate](catalog.md)). Everything else is ≈.

---

## 1. The float-comparison policy (LOCKED) — `numpy.allclose` for float, bit-exact for integer

### 1.1 The policy

When pan output is compared to the **external SciPy/NumPy oracle**:

| Output element lane | Comparison | Rule |
|---|---|---|
| **float** (`f32`, `f64`) | **`numpy.allclose`** | `|pan − ref| ≤ atol + rtol·|ref|`, elementwise |
| **integer / fixed-point** (`i8`, `i16`/`q15`, `i32`/`q31`, `i64`, …) | **bit-exact** | every output byte identical |

`atol`/`rtol` are carried **per block** in the vector manifest (§4), so a numerically delicate block
(an IIR near its stability edge, an FFT path) can be granted a looser bound than a gain stage without
loosening the whole suite. Sane defaults (used when a manifest omits them):

| Precision | `atol` | `rtol` |
|---|---|---|
| `f32` | `1e-6` | `1e-5` |
| `f64` | `1e-12` | `1e-9` |

These defaults match the spirit of `numpy.allclose`'s own (`atol=1e-8`, `rtol=1e-5`) loosened for `f32`
accumulation; a block that cannot meet them declares a wider bound in its manifest and *documents why*
(▷ authoring note), so a loose tolerance is never silent.

### 1.2 Why float is *not* compared bit-exact against the oracle (the WHY — Rule 9)

SciPy/NumPy computes references in **`f64`** with its own **summation order** (pairwise/Kahan in places)
and its own **transcendental implementations** (`libm` `sin`/`exp`/`log`, FFT twiddle factors). pan
computes in the **declared precision** (`f32` by default, [`catalog.md` §9.3 locked defaults](catalog.md))
with **SIMD-width-`W` partial sums** ([`catalog.md` §1.4 the Numeric trait](catalog.md)) and its own
kernel math. Two correct programs computing the same real-valued function in floating point **will not
agree bit-for-bit** when they differ in width, summation order, or transcendental rounding — this is
ordinary IEEE-754 reality, not a bug. Demanding `f32` bit-exactness against an `f64` oracle would either
be unsatisfiable or force pan to *re-implement NumPy's exact arithmetic*, which would collapse the
oracle's **independence** (it would no longer be an external truth — Rule 9 violated). Hence `allclose`:
it asserts pan computes *the right function to within floating-point tolerance*, while the oracle stays
genuinely independent. **This is the ≈ tier** ([`catalog.md` §12.2 B1 gold-vector oracle](catalog.md)).

### 1.3 Why integer / fixed-point *is* bit-exact against the oracle

Integer and fixed-point arithmetic is **exact and deterministic**: `q15` saturating multiply-accumulate
with a declared `Acc` width ([`catalog.md` §1.4 the Numeric trait](catalog.md)) has *one* correct
answer, and the generator computes the oracle in the *same* fixed-point semantics (§5.3). There is no
rounding-order freedom to forgive, so any deviation is a real defect. Bit-exactness here is the
strongest available ≈ check — and it is the *common* path on FPU-less MCUs ([`catalog.md` §9.3 q15
embedded default](catalog.md)), not a footnote.

### 1.4 The reference comparator (Zig 0.16, verified compiling)

```zig
const std = @import("std");

/// The comparison mode carried by a manifest (§4). `approx` = numpy.allclose
/// against the external oracle (float); `bit_exact` = exact (integer/fixed-point,
/// and ALL pan-vs-pan checks regardless of lane type — see §2).
pub const Tolerance = union(enum) {
    approx: struct { atol: f64, rtol: f64 },
    bit_exact,
};

/// numpy.allclose: |got - ref| <= atol + rtol*|ref|, elementwise (§1.1).
/// Used ONLY for the external float oracle. ≈ tier.
pub fn allcloseF32(got: []const f32, ref: []const f32, tol: Tolerance) !void {
    const a = tol.approx; // a bit_exact tolerance on a float oracle is a manifest error
    if (got.len != ref.len) return error.LengthMismatch;
    for (got, ref, 0..) |g, r, i| {
        const diff = @abs(@as(f64, g) - @as(f64, r));
        const bound = a.atol + a.rtol * @abs(@as(f64, r));
        if (diff > bound) {
            std.log.err("oracle allclose fail @ {d}: |{d}-{d}| = {d} > {d}", .{ i, g, r, diff, bound });
            return error.OracleMismatch;
        }
    }
}

/// Bit-exact: integer/fixed-point oracle AND every pan-vs-pan check (§2).
pub fn bitExact(comptime T: type, got: []const T, ref: []const T) !void {
    try std.testing.expectEqualSlices(T, got, ref);
}
```

---

## 2. The crucial distinction (LOCKED) — pan-vs-pan checks are ALWAYS bit-exact

The `allclose` tolerance of §1 applies to **exactly one** comparison: pan output against the **external
SciPy oracle**. Every other harness compares **pan against pan** — the *same machine code* run under a
*different buffer or mux strategy* — and is therefore **bit-exact regardless of element lane**, including
`f32`/`f64`:

| Check | What is compared | Why bit-exact (not `allclose`) |
|---|---|---|
| **B≡C differential** ([`catalog.md` §7.5](catalog.md)) | pool mode B (per-edge double buffers) vs mode C (colored pool) | identical kernels, identical inputs; only the *buffer addresses* differ. The colorer is a pure storage remapping — it must change **nothing** observable. Any float drift is the colorer corrupting data. |
| **Aliasing** ([`catalog.md` §7.4](catalog.md)) | aliased mux (in==out buffer) vs non-aliased mux | same kernel; in-place coalescing must be a no-op on values for an `aliasing_safe` block. |
| **Dual-mux push↔pull** ([`catalog.md` §4.2](catalog.md)) | `TestSampleMux` (push) vs `PullTestSampleMux` (pull), aligned by `algorithmic_latency` | the *same* `process`/`pull` over the *same* state; the only legal difference is the declared latency offset, which we align away (§5.4). |
| **State-granularity** ([`catalog.md` §2.1 M2](catalog.md)) | one full-block render vs two sub-block renders | the Mealy homomorphism (M2) is *exact*: splitting a call must reproduce the identical sample stream and identical end-state. |

> **The rule, stated once:** *tolerance forgives the oracle's different arithmetic; it never forgives pan
> disagreeing with itself.* A `f32` B≡C test that "almost matches" is a **failure** — the colorer either
> preserves the bytes or it has a bug. This keeps the differential checks maximally sharp and is why they
> are the *primary* correctness checks for their respective ⊢ theorems' implementations
> ([`catalog.md` §7.5](catalog.md)).

---

## 3. Vector storage (LOCKED) — generate-on-demand (disk-minimal, per the brief)

The brief demands **minimize disk usage** ([`notes/brief.md`](../notes/brief.md), core requirement). The
locked policy:

| Artifact | State | Rationale |
|---|---|---|
| [`scripts/generate.py`](../scripts/generate.py) | **COMMITTED** | the gold-vector generator; the SciPy/NumPy reference compute. |
| `tests/vectors/<name>.json` (per-block manifests) | **COMMITTED** | tiny JSON (≪1 KB each); the reproducible contract. |
| `tests/vectors/<name>/input.bin`, `expected.bin` | **GENERATED & GIT-IGNORED** | raw native-endian LPCM/sample bytes; reproduced at test time from `manifest + seed`. |

The raw blobs are **native-endian raw bytes** (no header, no framing — disk-minimal; the manifest
carries shape/precision so the reader needs no in-band metadata). `.gitignore` already excludes
`tests/vectors/**/*.bin` (and `*.raw`/`*.pcm`/`*.npy`); the committed surface is *generator + manifests*,
so a checkout is a few kilobytes and `python scripts/generate.py <manifest>` (or a `zig build`
pre-step) reconstitutes the binaries deterministically from the manifest's `seed`.

> **Reproducibility contract (▷+≈):** the generator MUST be deterministic given `(manifest, seed)` — same
> NumPy RNG seed, same dtype, same byte order — so a regenerated `expected.bin` is byte-identical across
> machines. A floating oracle whose values drifted between regenerations would silently move the
> tolerance goalposts. The generator pins `numpy.random.default_rng(seed)` and the explicit dtype.

---

## 4. The manifest schema (LOCKED) — JSON

A manifest is the **committed contract** for one gold vector. Schema:

| Field | Type | Meaning |
|---|---|---|
| `name` | string | vector id; names the `tests/vectors/<name>/` blob directory. |
| `block` | string | the pan block under test (e.g. `"Gain"`). |
| `params` | object | block construction params (e.g. `{ "gain_db": -6.0 }`). |
| `format` | object | `{ sample_rate, precision, channels, block_size }` — the `Format` sub-tuple ([`catalog.md` §1.2 Format product object](catalog.md)). `precision` is the lane `T` ([`catalog.md` §9.1 precision-as-comptime](catalog.md)). |
| `in_ports` | array | `[{ "name", "element_type" }]` — the canonical port elements ([`catalog.md` §1.3 canonical port elements](catalog.md)). |
| `out_ports` | array | same shape as `in_ports`. |
| `out_per_in` | string | `"1:1"` for a `Map`; rational `"p:q"` for a `Rate` ([`catalog.md` §2.2](catalog.md)). |
| `algorithmic_latency` | integer | declared samples of group delay (0 for a pure `Map`) ([`catalog.md` §2.2 R1/R2](catalog.md)). |
| `tolerance` | object | **either** `{ "atol", "rtol" }` (float oracle, §1.1) **or** `{ "bit_exact": true }` (integer/fixed-point, §1.3). |
| `seed` | integer | NumPy RNG seed; makes the blobs reproducible (§3). |
| `n_frames` | integer | total frames of test signal (≥ several blocks, to exercise state across calls). |

### 4.1 Concrete example — `tests/vectors/gain_f32.json`

```json
{
  "name": "gain_f32",
  "block": "Gain",
  "params": { "gain_db": -6.0 },
  "format": { "sample_rate": 48000, "precision": "f32", "channels": 1, "block_size": 256 },
  "in_ports":  [{ "name": "in",  "element_type": "Sample(f32)" }],
  "out_ports": [{ "name": "out", "element_type": "Sample(f32)" }],
  "out_per_in": "1:1",
  "algorithmic_latency": 0,
  "tolerance": { "atol": 1e-6, "rtol": 1e-5 },
  "seed": 1,
  "n_frames": 1024
}
```

A fixed-point sibling would set `"precision": "q15"`, `"element_type": "Sample(q15)"`, and
`"tolerance": { "bit_exact": true }` (§1.3).

---

## 5. The harnesses — one per ≈ obligation

Each harness names its **mux** ([`catalog.md` §4.1 the mux family](catalog.md)), its **comparison mode**
(tolerance vs bit-exact, §1–§2), and its **tier**. The mux is the only seam between a block and its
transport ([`catalog.md` §4.2 the Yoneda probe](catalog.md)); the test family *is* the dual-mux probe,
not arbitrary coverage.

### 5.1 GoldVectorTester — the SciPy oracle harness · ≈

- **Mux:** `TestSampleMux` (push) — feeds exact oracle bytes from `input.bin`, exposes the output buffer.
- **Flow:** read `manifest.json` → load (regenerated) `input.bin` and `expected.bin` → construct the
  block with `params` → render `n_frames` in `block_size` chunks through the mux → compare output to
  `expected.bin` under the **manifest tolerance** (`allclose` for float, `bitExact` for integer, §1).
- **Tier:** ≈ ([`catalog.md` §12.2 B1](catalog.md)). This is the "test intent against an independent
  mathematical truth" check (Rule 9; [`pan_categorical_bridge_and_roadmap.md` §3](pan_categorical_bridge_and_roadmap.md)).

### 5.2 Dual-mux — push vs pull · ≈ (Yoneda-justified) · **bit-exact**

- **Muxes:** `TestSampleMux` (push) vs `PullTestSampleMux` (pull) — the dual-mux partner.
- **Comparison:** **bit-exact** (pan-vs-pan, §2), **aligned by `algorithmic_latency`** (§5.4).
- **Why it suffices:** the representability argument — a block is determined by its action under the mux
  family — makes push/pull agreement the *structural* check that behaviour is mux-independent, catching
  surface leaks at the `Map`/`Rate` seam ([`catalog.md` §4.2 the representable / Yoneda argument](catalog.md)).
  It is the formal basis of "tests as definition" (Rule 14), and an **honest ≈ test strategy, not a
  constructed natural-isomorphism proof** ([`catalog.md` §4.2 honest bound](catalog.md)).
- **Tier:** ≈ (push↔pull agreement, [`catalog.md` §12.2 R4](catalog.md)).

### 5.3 B≡C differential — colorer correctness · ≈ · **bit-exact** · paranoid mode

- **Mux:** the same block run twice through the engine — **pool mode B** (per-edge double buffers,
  obviously correct) vs **pool mode C** (colored pool, [`catalog.md` §7.2 one pool per
  element-type-class](catalog.md)).
- **Comparison:** **bit-identical** output (pan-vs-pan, §2). The colorer is a pure storage remapping; the
  optimality is the imported ⊢ theorem ([`catalog.md` §7.2](catalog.md)), the *implementation's
  faithfulness* is what this test checks — the **primary correctness check** for the colorer, **empirical
  evidence, NOT a proof** ([`catalog.md` §7.5 the honest split](catalog.md)).
- **Paranoid mode:** in **Debug / ReleaseSafe**, released pool buffers are **poisoned to NaN** so any
  read-after-free or premature reuse surfaces as a divergence rather than a stale-but-plausible value.
- **Failure message contract:** on a divergence where the block declared `aliasing_safe = true`, the
  message **names the assertion and quotes it back**, identifies the first divergent sample, and states
  the fix — a false safety claim reads as a *falsified contract*, not an opaque mismatch
  ([`catalog.md` §7.6 the aliasing_safe failure-message contract](catalog.md)).
- **Tier:** ≈ ([`catalog.md` §12.2 B2](catalog.md)).

### 5.4 Aliasing — in-place vs non-aliased · ≈ · **bit-exact**

- **Muxes:** an **aliased** mux (output buffer == input buffer) vs a **non-aliased** mux, for a block
  declaring `aliasing_safe = true` ([`catalog.md` §2.1 M4](catalog.md)).
- **Comparison:** **bit-identical** (pan-vs-pan, §2). For an `aliasing_safe` block the two must agree
  exactly; a divergence is a false `aliasing_safe` claim (the §5.3 failure-message contract applies).
- **Tier:** ≈ ([`catalog.md` §12.2 B3](catalog.md)).

### 5.5 Latency-contract — declared `algorithmic_latency` is real · ≈

- **Mux:** `TestSampleMux` feeding a **unit impulse**; the block under test is a `Rate` block (or any
  block declaring `algorithmic_latency > 0`).
- **Comparison:** measure the **output group delay** (index of first significant response) and assert it
  equals the **declared `algorithmic_latency`**. A lying `Decimator` declaring `algorithmic_latency = 0`
  is **not** caught by ⊢ — this test is its discharge ([`catalog.md` §2.2 R1](catalog.md), audit C7).
- **Tier:** ≈ ([`catalog.md` §12.2 B4](catalog.md)). **Upgrade candidate:** this is the prime target for
  the deferred property-based harness (§8), which would sweep `algorithmic_latency` against
  `needed_input` over a range of `want` ([`catalog.md` §13 deferred formal work](catalog.md)).

### 5.6 State-granularity — full-block vs sub-block render · ≈ · **bit-exact**

- **Mux:** `TestSampleMux` driving **(a)** one render of `N` frames vs **(b)** two renders of `k` and
  `N−k` frames through the *same* block instance/state.
- **Comparison:** **bit-identical** output stream **and** identical post-render history (pan-vs-pan, §2).
  This is the sub-block homomorphism M2 ([`catalog.md` §2.1 M2](catalog.md)) — "sub-block splitting is
  free" — exactly the property the event-lane sub-block rendering relies on ([`catalog.md` §8.6 events &
  sub-block rendering](catalog.md)).
- **Tier:** ≈ ([`catalog.md` §12.2 state-update granularity](catalog.md)).

### 5.7 Embedded comptime-commit smoke gate — **⊢ for the smoke graph** (the lone ⊢ here)

- **Not a mux test.** `commitComptime()` is evaluated inside a `comptime` block in a **ReleaseSmall**
  embedded build, on the minimal graph **I2S source → gain → I2S sink**
  ([`catalog.md` §8.5 the comptime-commit obligation](catalog.md); the gate already lives in
  [`src/pan.zig`](../src/pan.zig)).
- **Discharge:** **the build compiling IS the discharge** of the comptime-commit obligation **for the
  smoke graph** — and `footprint_bytes` being usable as a comptime array length proves it is a comptime
  constant (H2, [`catalog.md` §7.8 the footprint formula](catalog.md)). Failing to compile is the loud
  failure (Rule 12).
- **Honest bound:** this is ⊢ **for the smoke graph only** — *not* a proof for arbitrary graphs
  ([`catalog.md` §8.5 honest bound](catalog.md), audit A5).

### 5.7b Parameter-edge — ramp/hold & one-source (catalog §2.4) · ≈ + ⊢

- **Muxes:** `TestSampleMux` feeding both the consumer's sample port and a control-rate **parameter
  edge** (`node.param.<name>`), driven by a step/sweep modulator.
- **What it checks (≈, bit-exact):** a wired parameter edge produces output **bit-identical** to the
  same target sequence applied via `set` (P3 — one ramp policy, two sources); the ramp is **zipper-
  free** (no discontinuity at block boundaries); a control-rate producer emitting 0 this call → the
  consumer **holds** the previous value.
- **What it checks (⊢, assert the error):** declaring **both** `set`/`schedule` and a wired parameter
  edge for one slot ⇒ a **commit error** (P2 one-source); a delay-free parameter feedback loop ⇒
  `error.DelayFreeLoop` (P4).

### 5.7c Parallel≡sequential — Tier-B executor correctness (catalog §8.10) · ≈ · **bit-exact**

- **Executors:** Tier A (sequential pull) vs Tier B (static-parallel: HEFT schedule + point-to-point
  ready-flags + concurrency-aware coloring), **same graph, same inputs**.
- **What it checks (≈, bit-exact):** Tier B output is **bit-identical** to Tier A — the direct analogue
  of B≡C, justified because op-granular scheduling preserves per-op reduction order (catalog §8.10 A17).
  The concurrency-aware colorer's pool (§8.11) must change nothing observable; **paranoid mode** extends
  to catch a buffer reused before its last reader across the *concurrency-aware* interference graph
  (a cross-worker live-range overlap). Run with `P = 2..ncores`; all must match Tier A and each other.
- **Why bit-exact (Rule 9):** this is a pan-vs-pan check (§2) — the parallel executor is a pure
  scheduling/storage remapping; any float drift is a colorer or sync bug, not numerics.

### 5.7d Offline differential — OfflineBatch reproducibility (catalog §11.1b O3) · ≈

- **Executors:** OfflineBatch with `K=1` (sequential) vs `K=ncores` (data-parallel chunking), and the
  pipeline-parallel path vs sequential.
- **What it checks (≈):** pipeline-parallel and **exact-warmup** (`warmup_exact=true`, FIR/STFT) chunked
  renders are **bit-identical** to sequential; **IIR-chunked** (`warmup_exact=false`) renders are
  **allclose within the block's declared tolerance** (catalog §2.5 W2). The ordered merge makes the
  timeline partition invisible (O3); fan-in reductions use fixed port order.
- **⊢ adjunct:** chunking a stateful block that **omits** `warmup_samples` is a commit/build error
  (W1 / A18) — asserted by attempting it and expecting the error.

### 5.7e Layout negotiation — registered up/down-mix & channel-order codec (catalog §1.3 L2 / §6) · ≈ + ⊢

- **Mux:** `TestSampleMux` on the **composite** (the §5.1 oracle harness applied across the inserted
  matrix), the same way Format negotiation is tested on the composite (§7.1).
- **What it checks (≈, allclose):** a wired **registered** layout mismatch (`.stereo → .surround_5_1`)
  causes negotiation (§6) to **auto-insert the canonical up/down-mix matrix**, and the composite output
  matches the **gold-vector oracle** within the manifest tolerance — the matrix is a float numeric
  ([`catalog.md` §1.3 L2](catalog.md)).
- **What it checks (≈, bit-exact):** the I/O codec's **channel-order reconciliation**
  (device/file order ↔ internal canonical order, [`catalog.md` §10](catalog.md)) **round-trips** — a
  pure permutation, so a decode∘encode is **bit-identical** (pan-vs-pan permutation, §2).
- **What it checks (⊢, assert the error):** a wired **unregistered** pair (`.custom → .ambisonic`) is a
  **hard mismatch** rejected **at commit** (no auto-coercion; requires an explicit spatial block) —
  asserted by attempting the wiring and expecting the negotiation error.
- **Tier:** ≈ ([`catalog.md` §12.2 B14](catalog.md)); the unregistered-pair rejection is ⊢ (A22).

### 5.7f VariRate latency/demand & determinism — the interval contract (catalog §2.6 V1/V2/V4) · ≈

- **Mux:** `TestSampleMux` feeding a **unit impulse** (delay measurement) and a swept `param.ratio`
  driving the `VariRate` block across `rate_bounds` (the §5.5 latency-contract extended to the interval).
- **What it checks (≈, V1/V2):** the declared `rate_bounds`/`max_latency` are **real** — measure the
  actual **out:in** ratio across the interval and assert it lies in `[min, max]`, and the impulse-response
  group delay is **≤ `max_latency`** at every operating point; `needed_input(want)` is **sound &
  monotone** over a `want` range **and across ratios** (the §8 deferred property-harness applied to the
  interval; latency-contract + dual-mux generalised — [`catalog.md` §2.6 V1/V2](catalog.md)).
- **What it checks (≈, V4 — the honest split):** a **parameter-driven** `VariRate` render is
  **O3-reproducible** — offline `K=1` is **bit-identical** to `K=ncores` where chunkable (the §5.7d
  differential applied to the `VariRate` seam); a **controller-driven** `VariRate` (drift PI / ASRC) is
  **exercised but asserted ≈-only**, *not* bit-reproducible — drift compensation cannot be
  ([`catalog.md` §2.6 V4](catalog.md), the §10 ASRC bound).
- **Tier:** ≈ ([`catalog.md` §12.2 B15/B16](catalog.md)).

### 5.7g Source generators — generator gold-vectors & anti-aliasing (catalog §2.7 SR1) · ≈

- **Mux:** `TestSampleMux` exposing only the **output** buffer (a Source has **zero sample-input
  ports**, [`catalog.md` §2.7 SR1](catalog.md)); the generator is driven by its parameter ports.
- **What it checks (≈, allclose):** oscillator / noise / wavetable output matches the **SciPy oracle**
  within the manifest tolerance, **including** oscillator **anti-aliasing** measured against a
  **bandlimited reference** (e.g. PolyBLEP) — an aliased naive ramp/saw is the failure mode the oracle
  rejects.
- **What it checks (bit-exact length):** the Source classifier sets **`out.len` == the pull demand `N`**
  (length from the pull, not from `in.len`, [`catalog.md` §2.7 SR1](catalog.md)) — a pan-vs-pan length
  invariant.
- **Tier:** ≈ ([`catalog.md` §12.2 B17](catalog.md)).

### 5.7h Typed events + PolyVoice — event lane & voice behaviour (catalog §8.6 / §8.12) · ≈

- **Mux:** the dual-mux pair (§5.2) applied to a block consuming a **typed `EventLane(NoteEvent)`**
  ([`catalog.md` §8.6](catalog.md)) — push vs pull agreement over the *same* event-driven render.
- **What it checks (≈):** `PolyVoice` voice **allocation / stealing is click-free** (no discontinuity
  when a slot is stolen and release-ramped, Y3); a `note_id` / **MPE expression** event **routes to the
  owning voice** (EV2); a **note onset is sample-accurate** via the sub-block split (Y2 / EV3) — the
  onset lands at the declared `sample_offset`, verified by the state-granularity sub-block mechanism
  (§5.6).
- **Comparison:** behavioural / gold-vector (≈) for the voice response; **bit-exact** for the dual-mux
  push↔pull agreement and the sub-block onset split (pan-vs-pan, §2).
- **Tier:** ≈ ([`catalog.md` §12.2 B18](catalog.md)).

### 5.8 Comparison-mode summary

| Harness | Mux(es) / executors | Compare against | Mode | Tier |
|---|---|---|---|---|
| GoldVectorTester (§5.1) | `TestSampleMux` | external SciPy oracle | tolerance (float) / bit-exact (int) | ≈ |
| Dual-mux (§5.2) | `TestSampleMux` vs `PullTestSampleMux` | pan (other mux) | **bit-exact**, latency-aligned | ≈ |
| B≡C (§5.3) | pool mode B vs C | pan (other pool) | **bit-exact** + paranoid NaN | ≈ |
| Aliasing (§5.4) | aliased vs non-aliased | pan (other mux) | **bit-exact** | ≈ |
| Latency-contract (§5.5) | `TestSampleMux` (impulse) | declared `algorithmic_latency` | group-delay == declared | ≈ |
| State-granularity (§5.6) | `TestSampleMux` (full vs split) | pan (other split) | **bit-exact** | ≈ |
| Parameter-edge (§5.7b) | `TestSampleMux` + param edge | pan (`set` vs wired edge) | **bit-exact** ramp; ⊢ one-source/SCC | ≈ + ⊢ |
| **Parallel≡sequential (§5.7c)** | Tier A vs Tier B (`P=2..ncores`) | pan (Tier A) | **bit-exact** + paranoid NaN | ≈ |
| **Offline differential (§5.7d)** | OfflineBatch `K=1` vs `K=ncores` / pipeline | pan (sequential) | **bit-exact** (exact-warmup) / allclose (IIR); ⊢ no-warmup error | ≈ + ⊢ |
| **Layout negotiation (§5.7e)** | `TestSampleMux` on the composite | SciPy oracle (matrix) / pan (codec round-trip) | **allclose** (matrix) / **bit-exact** (codec permutation); ⊢ unregistered-pair error | ≈ + ⊢ |
| **VariRate latency/demand (§5.7f)** | `TestSampleMux` (impulse) + swept `param.ratio` / OfflineBatch `K=1` vs `K=ncores` | declared `rate_bounds`/`max_latency`/`needed_input` / pan (parameter-driven) | out:in ∈ `[min,max]`, delay ≤ `max_latency`, monotone `needed_input`; **bit-exact** (parameter-driven O3) / allclose-only (controller ASRC) | ≈ |
| **Source generators (§5.7g)** | `TestSampleMux` (output only) | SciPy / bandlimited (PolyBLEP) oracle | **allclose**; `out.len`==pull `N` (bit-exact length) | ≈ |
| **Typed events + PolyVoice (§5.7h)** | `TestSampleMux` vs `PullTestSampleMux` + `EventLane(NoteEvent)` | gold-vector (voice response) / pan (push↔pull) | behavioural ≈; **bit-exact** push↔pull + onset split | ≈ |
| Smoke gate (§5.7) | — (comptime) | compiles | compile ⊢ | **⊢** (smoke graph only) |

### 5.9 Reference harness skeletons (Zig 0.16, verified compiling)

```zig
const std = @import("std");

/// Dual-mux / B≡C / state-granularity alignment helper: pan-vs-pan, the pull
/// stream lags the push stream by the declared algorithmic_latency (§2, §5.2).
/// Compares the overlapping region BIT-EXACT — tolerance never applies here.
pub fn alignByLatency(comptime T: type, push: []const T, pull: []const T, latency: usize) !void {
    if (push.len < latency or pull.len < latency) return error.TooShort;
    try std.testing.expectEqualSlices(T, push[latency..], pull[0 .. pull.len - latency]);
}

/// Latency-contract (§5.5): index of the first sample exceeding `eps` is the
/// measured group delay; it must equal the declared algorithmic_latency.
pub fn measuredGroupDelay(impulse_response: []const f32, eps: f32) ?usize {
    for (impulse_response, 0..) |s, i| if (@abs(s) > eps) return i;
    return null;
}
```

---

## 6. Build / CI matrix

Every harness above runs across the build modes; the matrix is the discharge surface for the ≈ ledger.

| Mode | Asserts | NaN guards | Paranoid mode (§5.3) | Role |
|---|---|---|---|---|
| **Debug** | on | on | **on** | primary correctness; UAF/leak detection. |
| **ReleaseSafe** | on | on | **on** | release-shaped codegen with safety; the default CI gate. |
| **ReleaseFast** | **off** | **off** | off | the hot-path build; perf + that tests still pass with safety stripped. |
| **ReleaseSmall** (embedded) | off | off | off | the **comptime-commit smoke gate** (§5.7), `freestanding` stub target ([`catalog.md` §9.3 embedded target](catalog.md)). |

> **`guards_compiled_out` telemetry ([`catalog.md` §10](catalog.md)):** because NaN guards and asserts
> are compiled out in ReleaseFast/ReleaseSmall, the runtime exposes a `guards_compiled_out: bool` so a
> release build cannot *silently* drop its guards — the test suite asserts the flag matches the build
> mode (Rule 12: fail loud, never silently skip a safety net). `std.debug.assert` is a **no-op in
> ReleaseFast** — never rely on it for safety there; the differential harnesses (B≡C, dual-mux) carry
> the correctness weight in release.

---

## 7. The Yoneda test-writer plug-in contract (Rule 14)

Each gate is a pair **(code-section-under-test, invariant/oracle)**. Per Rule 14, the orchestrator
dispatches **autonomous Yoneda test writers** — each loading the `zig-0-16` skill (Rule 13) — and gives
them the *section* and the *invariant*, **not** the tests. The writers author the tests themselves
(deciding cases, signals, edge conditions), which is exactly the dual-mux probe's promise: the tests are
the operational *definition* of the block's behaviour ([`catalog.md` §4.2](catalog.md)).

### 7.1 The gate table (section ↦ invariant)

| Gate | Code section under test | Invariant / oracle | Harness |
|---|---|---|---|
| Gold vector | each block's `process`/`pull` | matches SciPy oracle within manifest tolerance | §5.1 |
| Dual-mux | block under `TestSampleMux` vs `PullTestSampleMux` | bit-exact modulo `algorithmic_latency` | §5.2 |
| Colorer | the liveness/coloring pass ([`src/commit.zig`](../src/commit.zig)) | mode C ≡ mode B, bit-exact | §5.3 |
| `aliasing_safe` | the in-place coalescing path + the M4 declaration | aliased ≡ non-aliased, bit-exact | §5.4 |
| Feedback-SCC | the SCC-has-delay validator | delay-free cycle ⇒ `error.DelayFreeLoop` | (⊢; assert the error) |
| Format negotiation | the negotiation/coercion-insertion pass | rate-mismatch auto-inserts a resampler; commuting diagram | §5.1 on the composite |
| `PullSampleMux` | the synchronous-pull executor seam | upstream-rendered-first; pull == push | §5.2 |
| `Framer` (Rate) | `needed_input`/`pull` + `algorithmic_latency` | latency-contract + monotone `needed_input` | §5.5 |
| Parameter ports | the ramp/hold coercion + one-source check ([`catalog.md` §2.4](catalog.md)) | wired edge ≡ `set`, zipper-free; both-sources ⇒ commit error; delay-free param loop ⇒ `error.DelayFreeLoop` | §5.7b |
| Tier-B executor | the HEFT schedule + point-to-point sync + concurrency-aware colorer ([`catalog.md` §8.10–§8.11](catalog.md)) | Tier B ≡ Tier A bit-exact (`P=2..ncores`); paranoid mode finds no cross-worker reuse-before-last-read | §5.7c |
| Cost-model gate | the commit-time `W`/`S` gate ([`catalog.md` §8.10](catalog.md)) | refuses Tier B on a near-linear chain (`W/S≈1`); enables it when work/span + headroom justify | (⊢; assert the decision) |
| OfflineBatch / chunker | the pipeline + data-parallel chunker + `warmup_samples` merge ([`catalog.md` §2.5/§11.1b](catalog.md)) | `K=1`≡`K=ncores` bit-exact (exact-warmup) / allclose (IIR); no-`warmup` stateful chunk ⇒ commit error | §5.7d |
| Render-workgroup HAL | the `{create,join,leave}` co-scheduling seam ([`pan_parallel_and_offline_execution.md` §4](pan_parallel_and_offline_execution.md)) | bounded cross-worker spin under load; spin-time telemetry present | §5.7c (under load) |
| Layout negotiation | the layout up/down-mix matrix insertion + the I/O-codec channel-order reconciliation ([`catalog.md` §1.3 L2 / §6](catalog.md)) | a **registered** pair (`.stereo → .surround_5_1`) auto-inserts the canonical matrix, output matches the gold-vector oracle (allclose); an **unregistered** pair (`.custom → .ambisonic`) is a commit-time **hard mismatch**; codec channel-order round-trips (bit-exact) (≈ B14) | §5.7e |
| `VariRate` latency/demand | `rate_bounds`/`max_latency`/`needed_input` over the interval ([`catalog.md` §2.6 V1/V2](catalog.md)) | measured out:in lies in `[min,max]` across the interval; impulse delay ≤ `max_latency`; `needed_input(want)` sound & monotone over a `want` range and across ratios (≈ B15) | §5.7f |
| `VariRate` determinism | the parameter-driven vs controller-driven (ASRC) render ([`catalog.md` §2.6 V4](catalog.md)) | parameter-driven render is O3-reproducible (`K=1`≡`K=ncores` bit-exact where chunkable); controller-driven (ASRC) exercised ≈-only, not bit-reproducible (≈ B16) | §5.7f |
| Source generators | the Source classifier + oscillator/noise/wavetable `process` ([`catalog.md` §2.7 SR1](catalog.md)) | generator output matches the oracle (allclose), oscillator anti-aliasing matches a bandlimited (PolyBLEP) reference (allclose); `out.len`==pull `N` (bit-exact length) (≈ B17) | §5.7g |
| Typed events + `PolyVoice` | the `EventLane(NoteEvent)` dispatch + `PolyVoice` allocation/stealing/routing ([`catalog.md` §8.6 EV1/EV2 / §8.12 Y2/Y3](catalog.md)) | a block dual-muxes under a typed `EventLane(NoteEvent)`; voice alloc/stealing is click-free; `note_id`/MPE expression routes to the owning voice; note onset is sample-accurate via the sub-block split (≈ B18) | §5.7h |
| Smoke gate | `commitComptime` in ReleaseSmall | compiles ⊢ (smoke graph) | §5.7 |

### 7.2 Tests directory layout & naming convention

```
tests/
  vectors/                         # committed manifests + generated (git-ignored) blobs
    gain_f32.json                  # one manifest per gold vector (§4)
    gain_f32/                      # GENERATED, git-ignored: input.bin, expected.bin
  gold_vector_test.zig             # §5.1 GoldVectorTester  — drives every vectors/*.json
  dual_mux_test.zig                # §5.2 push vs pull
  bc_differential_test.zig         # §5.3 B≡C + paranoid mode
  aliasing_test.zig                # §5.4 aliased vs non-aliased
  latency_contract_test.zig        # §5.5 impulse group-delay
  state_granularity_test.zig       # §5.6 full vs sub-block
  layout_negotiation_test.zig      # §5.7e registered up/down-mix + codec channel-order round-trip
  varirate_latency_test.zig        # §5.7f rate_bounds/max_latency/needed_input + determinism class
  generator_gold_vector_test.zig   # §5.7g Source generators + oscillator anti-aliasing
  polyvoice_behaviour_test.zig     # §5.7h EventLane(NoteEvent) + voice alloc/stealing/MPE routing
```

- **One file per harness**, named `<harness>_test.zig`; the `_test.zig` suffix is the discovery
  convention. The comptime-commit smoke gate stays embedded in [`src/pan.zig`](../src/pan.zig) (it must
  compile *with* the library, §5.7), and is wired into `zig build test` already.
- **Test names** encode the gate and the catalog citation, e.g.
  `test "B≡C: colored pool ≡ per-edge buffers, bit-exact (catalog §7.5)"` — a Rule 9 test that names
  *why* (the invariant), not just *what*.
- Yoneda test writers add files here; they do **not** edit `src/` block code or this contract.

---

## 8. Deferred — the property-based harness (NOTED, not implemented)

Per [`catalog.md` §13 deferred formal work](catalog.md), a property-based harness is **deferred** (do
not implement). When built, it attaches at exactly three points, moving several ▷ claims toward ≈ with
adequate coverage:

- **R3 — `needed_input` monotonicity & soundness** ([`catalog.md` §2.2 R3](catalog.md)): sweep `want`
  over a range, assert `needed_input` is monotone non-decreasing, zero only at `want = 0`, and that
  pulling `needed_input(want)` inputs yields `≥ want` outputs. Upgrades the §5.5 latency-contract gate
  from a single impulse to a swept property. **`VariRate` extension (V1/V2, [`catalog.md` §2.6](catalog.md)):**
  the same sweep across the **`rate_bounds` interval** — `needed_input(want)` sound & monotone over both
  `want` *and* the operating ratio, with the measured out:in inside `[min, max]` and the impulse delay
  ≤ `max_latency` at every point — promoting the §5.7f gate from interval endpoints to a swept property.
- **M4 — `aliasing_safe` over random inputs** ([`catalog.md` §2.1 M4](catalog.md)): the §5.4 aliasing
  check over randomized signals rather than one fixed vector.
- **B≡C over random graph topologies** ([`catalog.md` §7.5](catalog.md)): the §5.3 differential over
  randomly generated *graphs*, not just the fixed corpus — the strongest available evidence short of the
  deferred Lean register-allocation proof ([`catalog.md` §13](catalog.md)).

These are **noted, not done.**

---

*Locked 2026-06-03 as a support document of the pan specification corpus. Author: Claude (Opus 4.8) via
Claude Code, with the `zig-0-16` skill consulted and every harness snippet compiled against `zig 0.16.0`.*
