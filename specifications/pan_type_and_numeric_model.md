# pan — Type & Numeric Model

> **Status: LOCKED** (2026-06-02). Change-control: conforms to [`catalog.md`](catalog.md); an edit
> that changes a definition or law must update catalog.md and every citing section in the same commit.
> Support document for [`pan_architecture_formalisation.md`](pan_architecture_formalisation.md)
> (the hub). Siblings: [`pan_execution_model.md`](pan_execution_model.md) ·
> [`pan_memory_model.md`](pan_memory_model.md) ·
> [`pan_io_realtime_and_pipeline.md`](pan_io_realtime_and_pipeline.md) ·
> [`pan_categorical_bridge_and_roadmap.md`](pan_categorical_bridge_and_roadmap.md).
>
> Defined terms resolve to [`catalog.md`](catalog.md) — the single source of truth (read first).
>
> Scope: the **typed-port catalog**, the comptime **port extraction** (verified against ZigRadio),
> the **Numeric trait**, the **precision/N/W asymmetry**, and **format negotiation**. Realises
> commitment **C4** and resolves audit **S1, S9** of the hub.

---

## 1. Typed ports — generalize "audio frame of T" to "typed port element"

Verified against the real source ([hub §2](pan_architecture_formalisation.md)): `ComptimeTypeSignature`
reads each `process` parameter's `.pointer.child` as the **element type** — it is *not* restricted to
scalars; `Complex(f32)` and user structs with a `typeName()` getter already work
(`types.zig:52-72`). This unblocks the feature corpus, which puts spectra, fixed-K vectors, scalars,
and structured records on edges. Bless a small canonical set in `specifications/catalog.md` (canonical
element set & pool keys: [`catalog.md` §1.3](catalog.md)):

| Port element | Zig form | Used by | Pool class key |
|---|---|---|---|
| `Sample(T)` | `T` (e.g. `f32`, `i16`) — the `C=1` case of `Frame` | audio frames | `(T, N)` |
| `Frame(Lane, C)` | **named struct** `struct { ch: [C]Lane }` (`C` comptime) | channel-carrying audio (panner, balance, upmix); `Sample(T) == Frame(Lane,1)` | `(Frame(Lane,C), N)` |
| `Complex(T)` | `std.math.Complex(T)` | STFT spectra | `(Complex(T), N/2+1)` |
| `FeatureFrame(K)` | **named struct** `struct { v: [K]f32 }` | mel/chroma/MFCC/DCT vectors | `(FeatureFrame(K), 1)` |
| `Scalar(T)` | named struct wrapping `T` | centroid, flux, RMS, dominant band | `(Scalar(T), 1)` |
| `Bounded(T, Kmax)` | `struct { items: [Kmax]T, len: u16 }` | ragged: formant tracks (birth/death), sparse peak lists, beat hypotheses | `(Bounded(T,Kmax), 1)` |

> **The `[40]f32` caveat (verified):** a *bare* array element has no `typeName()` and the runtime
> type-name map rejects it (`types.zig` `else` branch `@compileError`). So feature vectors are
> wrapped in a **named struct** `FeatureFrame(K)` carrying a `typeName()`. This is a one-line
> convention, *not* a barrier — and it makes the pool class key explicit.
>
> **`Bounded(T, Kmax)` resolves audit S9:** storage is fixed-capacity (static, colorable); only the
> `len` varies per frame. Liveness is over the *storage*, so coloring is unaffected; correctness is
> the consumer respecting `len`. Spec blesses the pattern; no new transport primitive.

**`Frame(Lane, C)` (channel-carrying element).** `Frame(Lane, C)` is a named `struct { ch: [C]Lane }`
with `C` comptime in the type, so a channel-changing block is simply a port whose in/out `Frame`
differ in `C` (channel-count mismatch between wired ports becomes a comptime/commit type error via
the typed `PortId` below). `Sample(T) == Frame(Lane, 1)` — a mono kernel and a `Frame(Lane,1)` kernel
are the same thing. The internal canonical form is **planar** (LOCKED PLANAR —
[`catalog.md` §9.3](catalog.md)); planar/interleaved conversion happens
**only at the I/O boundary** ([`pan_io_realtime_and_pipeline.md` §5](pan_io_realtime_and_pipeline.md)).

**Typed `PortId` (the connect-checking handle).** A `PortId` is minted per node at comptime from the
`process`/`pull` signature (and any `Concat` spec); it **carries node identity + direction + element
type**. Because the element type rides in the handle, `connect` type-checks both ends and emits a
`@compileError` naming the offending port on a mismatch — this is the same handle the named-port
`Concat` (below) and the homogeneous `node.in(i)` accessors expose, and the channel count in
`Frame(Lane, C)` is just one of the things it checks. The 8-port-per-direction ceiling is enforced as
a comptime `@compileError` via the port-index type `u3` ([hub §2](pan_architecture_formalisation.md),
[`pan_execution_model.md` §8](pan_execution_model.md)).

The **fan-in `Concat`/`Vectorize` block** (audit §3.2) takes a **comptime struct-of-(name →
element-type)** spec and emits one output struct whose fields are those named element types. Inputs
are wired **by name** via the typed `PortId`s minted from the spec — `node.in.<name>` — so order
cannot drift and a wrong element type is a compile error naming the port. The **output struct's field
order *is* the canonical feature-matrix column order**, pinned by the same declaration that pins the
wiring (no second list to keep in sync; a transposed feature matrix becomes impossible because the
column identity is the field name, not an int). *Illustrative — Zig 0.16:*

```zig
const collect = try g.add(pan.combinators.Concat(.{
    .mfcc     = pan.FeatureFrame(13),
    .centroid = pan.Scalar(f32),
    .flux     = pan.Scalar(f32),
    .dominant = pan.Scalar(u16),
    .rms      = pan.Scalar(f32),
}), .{});

try g.connect(mfcc,     collect.in.mfcc);     // compile error if Mfcc's Out != FeatureFrame(13)
try g.connect(centroid, collect.in.centroid);
// collect.Out is the comptime-built struct { mfcc: FeatureFrame(13), centroid: Scalar(f32), ... };
// its field order is the canonical column order of the emitted feature matrix.
```

`Concat(spec)` reflects over `spec` with `@typeInfo(@TypeOf(spec)).@"struct".fields`, synthesising a
typed `PortId` per field (exposed as `collect.in.<name>`) and the matching output-struct field. It is
a **library block**, not a core primitive ([`pan_categorical_bridge_and_roadmap.md` §2](pan_categorical_bridge_and_roadmap.md)).

---

## 2. Format negotiation — a unification pass over a product object

Generalize ZigRadio's `setRate` topological propagation into a full negotiation over the **product**:

```
Format = (sample_rate × precision T × channel_layout × block_size N × port_element_type × out_per_in)
```

At graph-commit the pass propagates formats along edges, validates compatibility with **loud
mismatches** (Rule 12), and **inserts coercion morphisms** where the user wired incompatible formats:
resamplers (rate), channel matrices (layout), precision casts (T), framers (rate-ratio). Categorical
reading: format negotiation is a constraint/unification problem over the product object; converter
insertion makes the diagram commute ([`pan_categorical_bridge_and_roadmap.md` §1](pan_categorical_bridge_and_roadmap.md)).

### 2.1 Channel model — *this is "pan"*
Channel layout rides in the format. Internal canonical form is **planar** (LOCKED PLANAR —
[`catalog.md` §9.3](catalog.md); friendlier to `@Vector`
kernels; interleaved is converted at the I/O boundary —
[`pan_io_realtime_and_pipeline.md` §4](pan_io_realtime_and_pipeline.md)). The channel-carrying
element type is the pinned **`Frame(Lane, C)`** of §1 — a named `struct { ch: [C]Lane }` with `C`
comptime, pool-class key `(Frame(Lane, C), N)`:

```zig
pub fn Frame(comptime Lane: type, comptime C: usize) type {
    return struct { ch: [C]Lane }; // named struct => has typeName(); pool-class key = (Frame(Lane,C), N)
}
```

A channel-agnostic block (gain, biquad) applies per channel trivially; a **panner** changes channel
count by differing in `C` only — `process(self, in: []const Frame(Lane,1), out: []Frame(Lane,2))`.
The spatial core — constant-power panner,
balance, width, upmix/downmix matrix, VBAP, ambisonic encode/decode — are ordinary blocks whose port
format carries `C`. For *replicating a whole analysis subgraph per channel*, the channel-rides-in-format
model is **not** enough (audit S4); the `ChannelMap(Sub, C)` **library combinator** fills that gap
([`pan_categorical_bridge_and_roadmap.md` §2](pan_categorical_bridge_and_roadmap.md)).

---

## 3. The precision / block-size / width asymmetry (C4)

The three configurable axes are **not symmetric**, and recognizing this kills the feared comptime
explosion:

| Axis | Binding | Why |
|---|---|---|
| **Precision `T`** | **comptime** kernel parameter | changes machine code: SIMD lane type, instruction selection, accumulator width, saturation. Bound once at config time by selecting a concrete monomorph's **function pointer** (one indirect call per *buffer* — free). |
| **Block size `N`** | **runtime** (a slice length) | the device dictates N and can change it on a route switch. Zig's vectorization keys off comptime `W`, **not** comptime `N`, so a runtime-N loop with a comptime-W body + scalar tail vectorizes fully. |
| **SIMD width `W`** | **comptime per target** via the HAL | `std.simd.suggestVectorLength(T)` → NEON 4×f32 (M3), Helium/MVE (Cortex-M55), AVX2 8×f32 (x86). Runtime fat-dispatch only for x86 desktop (AVX2/AVX-512/SSE); elsewhere build per target. |

**Consequence:** you never need the precision×block-size **cross-product** — the explosion is driven
almost entirely by the *precision* axis, and the device-facing N dimension can't be comptime anyway.
The active precision set is an explicit comptime list; embedded compiles **only** its one precision
and width (`ReleaseSmall`), keeping the binary tiny; desktop carries the configured
runtime-reconfigurable set. Log the generated-monomorph count at build (Rule 12) to catch creep.

> **⚠️ `cfg.precision` is comptime-known, not a runtime knob.** Precision lives inside the single
> `Config` struct (one config flows through the whole pipeline), **but it is bound at comptime**:
> `numericFor(cfg.precision, …)` is a **comptime switch over the explicit active-precision list**, and
> the call site **requires the `comptime` keyword** to make the comptime nature loud —
> `const Num = comptime pan.numericFor(cfg.precision, .{});`. The consequence the spec states up
> front: a **desktop precision change therefore requires a recommit** (it re-selects a monomorph; it
> is not a live runtime switch). pan deliberately offers no runtime precision switching. (We keep
> precision in `Config` rather than adopting a `Graph(precision)` type parameter, so the
> configuration-driven "one struct flows everywhere" model is preserved; the comptime seam is paid
> once by this callout + the `comptime` keyword, not by every `Graph`-typed signature.)

### 3.1 Two N-regimes (the corollary the spec must state)
- **Runtime N for stream ports** (`Sample(T)`, `Complex(T)`) — device-driven, scalar tail accepted.
- **Comptime N (= K) for fixed-K feature ports** (`FeatureFrame(K)`) — kills the scalar tail, enables
  full `inline for` unrolling of short kernels (skill ch.04). This is the **same** port-kind
  distinction the buffer pool already makes ([`pan_memory_model.md` §2](pan_memory_model.md)) — free
  coherence, not a new axis.
- **Intra-kernel algorithmic sizes** (filter order, FFT size) stay **comptime** where the block author
  fixes them (one instantiation per block type — no explosion).

---

## 4. The Numeric trait — more than a lane type

The comptime kernel parameter is **not** just `T`; integer/fixed-point precision changes overflow,
accumulation, and rounding semantics, and fixed-point is the *common* path on FPU-less MCUs:

```zig
pub const Numeric = struct {
    Lane: type,            // element type: f32, f64, i16(q15), i32(q31), ...
    Acc: type,             // accumulator: f32→f32, i16→i32, i32→i64  (mul-accumulate width)
    saturate: bool,        // integer ops saturate (+|, -|, *|) vs wrap
    W: comptime_int,       // SIMD width for this Lane on this target (from the HAL)
};
```

A biquad over `i16` accumulates `i16×i16` in `i32` and saturates on store; over `f32` it accumulates
in `f32`. **`Acc` and `saturate` must be in the core trait** because they are load-bearing on the
primary embedded path, not an edge case (skill ch.03 for saturating ops `+| -| *|` and overflow
builtins). Precision policy default: **f32 internal everywhere with int only at I/O seams** (covers
~95 % of audio; simplest), with genuinely per-block precision available (an `i16` decode → `f32` core
→ `i24/i32` output, monomorphized conversion blocks at the seams). The default is the simpler one;
per-block precision is opt-in. (LOCKED — [`catalog.md` §9.3](catalog.md))

---

## 5. What the spec must pin down here

- The canonical port-element catalog (`Sample`, `Frame(Lane,C)`, `Complex`, `FeatureFrame(K)`,
  `Scalar`, `Bounded(T,Kmax)`), the `Sample(T) == Frame(Lane,1)` identity, and the `typeName()`
  convention for non-primitive elements.
- The typed `PortId` (node identity + direction + element type, minted at comptime) and the
  named-spec `Concat` whose output-struct field order is the canonical column order.
- The `Format` product object and the negotiation/coercion-insertion algorithm (with
  [`pan_memory_model.md`](pan_memory_model.md) for pool-class derivation).
- The `Numeric` trait fields and the per-target HAL resolution of `W`.
- The two N-regimes rule and the explicit active-precision comptime list — and that `cfg.precision`
  is **comptime-known** (`numericFor` is a comptime switch; the call site uses the `comptime`
  keyword; a desktop precision change requires a recommit; no `Graph(precision)` type parameter).
- Planar as the internal canonical channel form (LOCKED PLANAR — [`catalog.md` §9.3](catalog.md)).
