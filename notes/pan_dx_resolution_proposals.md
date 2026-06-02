# pan — DX Resolution Proposals

> **Purpose.** Concrete, apply-or-decide resolution proposals for the developer-experience friction
> raised against the pan architecture. Each issue gets a proposed API/spec surface, a rationale, the
> exact spec doc + section it changes, an H1/H2/H3 invariant check, a `CLEAR-WIN` vs `DECISION-NEEDED`
> classification, and cross-issue interactions. **No spec files are edited by this document** — the
> architect applies the clear wins and takes the decision points to the user.
>
> **Sources:**
> - DX report (source of the issues): [`../specifications/pan_developer_experience.md`](../specifications/pan_developer_experience.md)
> - Hub / invariants H1–H3, commitments C1–C5: [`../specifications/pan_architecture_formalisation.md`](../specifications/pan_architecture_formalisation.md)
> - Siblings: `pan_execution_model.md`, `pan_memory_model.md`, `pan_type_and_numeric_model.md`,
>   `pan_io_realtime_and_pipeline.md`, `pan_categorical_bridge_and_roadmap.md` (all in `../specifications/`).
>
> **Invariants under test (hub §1):** **H1** wait-free RT path · **H2** bounded static render memory ·
> **H3** port/graph correctness provable at comptime/commit.
>
> **⚠️ All Zig below is illustrative.** pan does not exist yet; nothing here has been compiled. Snippets
> target **Zig 0.16.0** idioms (unmanaged containers via `.empty`, allocator-per-call, `@Vector`,
> `callconv(.c)`, lowercase `.@"struct"` typeInfo tags with `default_value_ptr`, the `@Int`/`@Struct`
> typed constructors, `std.Io`). Treat the *shapes* as proposals, the *identifiers* as negotiable.
>
> **Method note (Rule 7 — surface, don't average).** Where two surfaces genuinely fork I do not blend
> them into a mush; I present mutually-exclusive options with crisp trade-offs and state my pick.

---

## Issue index (classification at a glance)

| # | Issue | Class |
|---|---|---|
| I1 | Positional `Concat`/fan-in is the worst edge of the API | **DECISION-NEEDED** |
| I2 | `in_place` reads as a perf flag but is a safety assertion | **DECISION-NEEDED** |
| I3 | Parameter API fragmented across 3 control-plane mechanisms | **DECISION-NEEDED** |
| I4 | Multi-port `connect` grammar is positional / 8-port ceiling is a magic number | **CLEAR-WIN** (couples to I1) |
| I5 | FTZ + release-mode NaN-guard behavior is implicit | **DECISION-NEEDED** |
| I6 | "Same code, specialized not forked" hinges on commit being comptime-evaluable — untested | **CLEAR-WIN** |
| I7 | Precision-as-comptime vs runtime-looking `cfg.precision` seam | **DECISION-NEEDED** |
| I8 | Map/Rate split has no tutorial-grade onboarding surface | **CLEAR-WIN** |
| I9 | Single-sample inner-loop feedback node surface unpinned | **DECISION-NEEDED** |
| I10 | `FeatureCollectorSink` growth policy unspecified | **CLEAR-WIN** |
| I11 | Channel-typed-frame element surface (`Frame(C)`) unpinned | **CLEAR-WIN** (couples to I1/I4) |
| I12 | Custom-bypass-with-latency author obligation is invisible | **CLEAR-WIN** |

DECISION POINTS are consolidated in the table at the end.

---

## I1 — Positional `Concat`/fan-in is the worst edge of the API

**One-line.** `Concat` takes a tuple of element types, then you wire inputs *positionally*
(`collect.input(3)`), and tuple-order and connect-order can silently diverge.
**Raised in DX report:** §6 ("the roughest edge in the whole library"), §11 recommendation #1
(*highest priority*), §11 scorecard ("Positional `Concat` fan-in… not justified… the worst edge").

### Proposed resolution

Make a fan-in node's inputs **named, typed port handles minted at comptime from a port spec**, so
order cannot drift and a wrong element type is a compile error. Replace the parallel
`(tuple-of-types, positional input(i))` pair with a single declarative port set.

```zig
// ILLUSTRATIVE — Zig 0.16. The Concat spec is a comptime list of (name, element-type) pairs.
// A name is an enum-literal-ish field key; the element type is the port's pool-class element.
const collect = try g.add(pan.combinators.Concat(.{
    .mfcc      = pan.FeatureFrame(13),
    .centroid  = pan.Scalar(f32),
    .flux      = pan.Scalar(f32),
    .dominant  = pan.Scalar(u16),
    .rms       = pan.Scalar(f32),
}), .{});

// Connect by NAME. The handle's element type is checked against the producer at comptime/commit.
try g.connect(mfcc,     collect.in.mfcc);      // compile error if Mfcc's Out != FeatureFrame(13)
try g.connect(centroid, collect.in.centroid);
try g.connect(flux,     collect.in.flux);
try g.connect(dominant, collect.in.dominant);
try g.connect(rms,      collect.in.rms);
// collect.Out is the comptime-built struct { mfcc: FeatureFrame(13), centroid: Scalar(f32), ... }
```

How the comptime machinery works (sketch): `Concat(spec)` reflects over `spec` with
`@typeInfo(@TypeOf(spec)).@"struct".fields`, and for each field synthesises (a) a typed `PortId`
exposed as `collect.in.<name>` and (b) a field in the output struct via the `@Struct` constructor.
Each `PortId` carries its element type as a comptime field, so `connect` can `@compileError` on a
type mismatch and name the offending port. The output struct's field *order* is fixed by the spec —
so the feature matrix layout is pinned by the same declaration that pins the wiring. No second list
to keep in sync.

How a developer uses it: you declare the shape once; the wiring reads like assigning to named fields;
a transposed feature matrix becomes *impossible* (the column identity is the field name, not an int).

### Rationale & spec change

This is pure commit-time/comptime sugar over the existing `Concat`/`Vectorize` library block. It
converts a runtime-order invariant the user must hold in their head into a comptime-checked one
(strengthens H3). Changes:
- **`pan_type_and_numeric_model.md` §1** ("Typed ports", the `Concat`/`Vectorize` paragraph): replace
  "takes heterogeneous typed inputs … emits one … comptime-built tuple/struct" with the **named-port
  spec** form, and state that the output struct's field order is the canonical column order.
- **`pan_categorical_bridge_and_roadmap.md` §2** ("Combinators"): update the `Vectorize`/`Concat`
  signature to the named-spec form.
- **`pan_categorical_bridge_and_roadmap.md` §1** (categorical table): the "product / tupling morphism"
  row gains the note that the product's projections are *named* (a record, not an ordered tuple) — a
  strictly cleaner categorical reading (the product object is a labelled limit).

### Invariant check
- **H1:** untouched — all of this is resolved at comptime/commit; the hot path still replays a flat
  op-list with integer buffer ids.
- **H2:** untouched — the output struct is a fixed comptime type; pool class is unchanged.
- **H3:** **strengthened** — wrong port name and wrong element type both become compile errors.

### Classification: **DECISION-NEEDED**
The *direction* (kill positional) is unanimous, but the *surface* genuinely forks. Options (drop-in
multiple-choice):

- **Option A — Named-field spec (struct-of-types), connect via `node.in.<name>`** (shown above).
  *Pro:* column identity = field name, self-documenting, output struct is the same record, IDE
  completion on `.in.`. *Con:* names are baked into the block instance; reusing the same Concat shape
  with different names means a different type.
- **Option B — Typed `port(name, ElemType)` accessor returning a handle.**
  `try g.connect(mfcc, collect.port("mfcc", pan.FeatureFrame(13)))`. *Pro:* matches DX report rec #1
  verbatim; explicit element type at the call site doubles as documentation. *Con:* you repeat the
  element type at every connect; string-y name unless made an enum literal; easy to typo a name into a
  *new* port unless `Concat` pre-declares the legal name set.
- **Option C — Builder returns an ordered slice of typed handles** (`const p = collect.inputs();` then
  `connect(mfcc, p[0])`). *Pro:* smallest change from today. *Con:* still positional — does **not**
  fix the root friction; rejected on merit, listed only for completeness.

**My recommendation: Option A.** It is the only option where the column order of the feature matrix
*is* the wiring declaration, so the §6 footgun ("transposed feature matrix") cannot occur, and it
needs no element-type repetition at the call site. Option B is a fine fallback if the user prefers the
element type to be visible at each `connect`.

### Interactions
Couples tightly to **I4** (typed `PortId`): the named handles here are the *same* `PortId` mechanism
I4 proposes for all multi-port nodes — adopt one `PortId` design and `Concat` is its richest consumer.
Couples to **I11** (`Frame(C)`): a Concat over channel-typed frames just uses `Frame(C)` as an element
type, no special case.

---

## I2 — `in_place` reads as a perf flag but is a safety assertion

**One-line.** `pub const in_place = true;` looks like a performance knob but asserts "my kernel never
reads ahead while writing" — a correctness claim the type system cannot check, whose violation is a
*silent* corruption only manifesting when coloring aliases the buffers.
**Raised in DX report:** §1 ("the safety of `in_place` lives in your head and in a test"), §11
recommendation #2, §11 scorecard ("Ceremony that's a *trap*… Justified to *have*, badly *named*").

### Proposed resolution

Rename the declaration so it reads as the **promise** it is, and make the validator quote the
author's assertion back when the B≡C differential test or paranoid mode catches a violation. The
mechanism (colorer honours it only after proving single-consumer + last-use + identical element
type/count, per `pan_memory_model.md` §3) is **unchanged**; only the *name and failure ergonomics*
change.

```zig
// ILLUSTRATIVE — Zig 0.16. The declaration now names the contract, not the optimization.
/// I promise process() never reads in[k+m] while/after writing out[k] (no read-ahead/aliasing hazard).
/// The colorer MAY then alias my input and output buffers; it still proves single-consumer + last-use.
pub const aliasing_safe = true;
```

And the paranoid-mode / B≡C failure message names the assertion:

```text
error: aliasing hazard in block 'Gain(f32)' — output differs between pooled (mode C) and
       double-buffered (mode B) execution when in/out buffers are aliased.
   This block declared `pub const aliasing_safe = true`, asserting process() never reads an
   input element after the corresponding output element was written. That assertion is FALSE.
   first divergent sample: index 1024  (mode B = 0.5000, mode C = NaN under paranoid poison)
   fix: remove `aliasing_safe` (forfeits in-place coalescing) OR restructure the kernel so reads
        precede writes per lane.  see pan_memory_model.md §3.
```

How a developer uses it: the name now *is* the documentation; a reviewer reading `aliasing_safe = true`
sees a claim to scrutinise, not a speed dial. Forgetting it costs a memcpy (safe); asserting it
falsely is caught by the existing B≡C test with a message that points at the assertion.

### Rationale & spec change
The fix is a rename plus a message contract — no algorithm change. Changes:
- **`pan_memory_model.md` §3** ("In-place coalescing"): rename `in_place` → `aliasing_safe`
  everywhere; reword the gating sentence to "block author *asserts the kernel is free of intra-call
  read-after-write aliasing hazards*"; add the failure-message contract above as part of §9's
  differential-test obligation.
- **`pan_execution_model.md` §2.1** (`Map`): rename `pub const in_place = true` → `aliasing_safe`.
- **`pan_architecture_formalisation.md` §5 item 1**: the typed-port carry-set
  `{… in_place}` → `{… aliasing_safe}`.
- **`pan_memory_model.md` §11** (pin-down list): "the `in_place` validator's three conditions" →
  "the `aliasing_safe` validator's three conditions".

### Invariant check
- **H1 / H2:** untouched (pure rename; same coloring outcome).
- **H3:** mildly clarified — H3 explicitly does *not* claim to prove this property at comptime; the
  rename makes the residual obligation (proved by test, not type) honest, which is the Rule-12 spirit.

### Classification: **DECISION-NEEDED**
Renaming is unanimous; the *form* of the assertion forks:

- **Option A — `pub const aliasing_safe = true;`** (a const, like today). *Pro:* zero mechanism change,
  one-line rename, matches the existing comptime-reflection path. *Con:* still a bare bool an author
  can flip carelessly.
- **Option B — `pub const aliasing_safe = true;` PLUS a required one-line rationale**
  (`pub const aliasing_safe_because = "reads precede writes per lane";`) that the validator surfaces.
  *Pro:* forces the author to articulate *why*, which is exactly the claim under test. *Con:* mild
  extra ceremony; the rationale string is unverified prose.
- **Option C — A marker method `pub fn assertAliasSafe() void {}`** whose mere presence flips the flag
  (DX report rec #2's alternative). *Pro:* "looks like code, not config." *Con:* odd Zig idiom (empty
  marker fn); no payload; not obviously better than a named const.

**My recommendation: Option A** for the rename, named `aliasing_safe`. It resolves the entire friction
(the name now telegraphs the contract) at one-line cost and keeps the comptime path trivial. Option B
is worth adopting *only if* the user wants the design to push authors to justify the claim in-source.

### Interactions
Independent of the others; touches only the memory-model coloring path. (The B≡C differential test in
`pan_memory_model.md` §9 / `pan_categorical_bridge_and_roadmap.md` §3 is the enforcement mechanism and
already exists — this issue only renames the trigger and improves the message.)

---

## I3 — Parameter API is fragmented across three control-plane mechanisms

**One-line.** Turning a knob uses one of three non-interchangeable mechanisms (atomic scalar / SPSC
command ring / RCU snapshot) and the spec doesn't say which a given call uses, so a user can expect
`set()` to be sample-accurate and be wrong.
**Raised in DX report:** §5 ("the three tiers are not interchangeable, and the docs don't say which one
a given call uses"; "The spec hasn't pinned down a unified parameter API"), §11 recommendation #3.

### Proposed resolution

A single, intention-revealing control surface where **the *kind of change* selects the mechanism**,
and the mechanism is documented in the method name/type, not hidden:

```zig
// ILLUSTRATIVE — Zig 0.16. One handle, three intentions, each routed to the right RT-safe mechanism.

// (1) Continuous parameter, "be at value by end of next buffer" — ATOMIC scalar + per-block ramp.
gain.set(.gain, 0.5);                 // RT-safe, click-free; NOT sample-accurate (ramped over the block)

// (2) Sample-accurate scheduled change — SPSC COMMAND RING, applied at a sub-block boundary.
engine.schedule(.{ .at_sample = 64, .node = gain, .param = .gain, .value = 0.0 });

// (3) Bulk / topology change — RCU plan swap built off-thread, published at a block boundary.
var edit = engine.beginEdit();
_ = try edit.add(pan.fx.Chorus(Num), .{});
try edit.commit();                    // atomic pointer swap; no audio glitch
```

The unifying rule (this is the part the spec must *state*): **`set` is always "ramp to target by end
of buffer" (atomic path); `schedule` is always sample-accurate (ring path); `edit/commit` is always
topology (RCU path).** `set` *rejects* a sample-accurate request at the type level — there is no
`at_sample` parameter on `set`, so the §5 footgun ("I expected `set()` to be sample-accurate") is a
compile error of omission, not a silent wrong behavior. Each method's doc-comment names its mechanism
and its RT-safety class explicitly.

How a developer uses it: pick the verb by *what you mean* — "move the knob" (`set`), "automate at a
point" (`schedule`), "rewire" (`edit`). The mechanism is a documented consequence, never a guess.

### Rationale & spec change
This is surface design over the **existing** three primitives (C1/C5 control plane); it adds no new
RT mechanism. Changes:
- **`pan_io_realtime_and_pipeline.md` §7** ("Lock-free control plane"): add a **mapping table**
  `intention → mechanism → RT-safety` and state that the public API exposes exactly the three verbs
  (`set`/`schedule`/`edit`) bound 1:1 to (atomic / SPSC ring / RCU), with `set` ramped and
  *not* sample-accurate by contract.
- **`pan_io_realtime_and_pipeline.md` §12** (pin-down list): add "the unified parameter surface and the
  intention→mechanism table" to the items the spec must pin down.
- **`pan_execution_model.md` §4.3** (installing a new plan): cross-reference that `edit/commit` is the
  user-facing name for the RCU plan swap.

### Invariant check
- **H1:** preserved — each verb still maps to a wait-free mechanism (atomic store / SPSC enqueue drained
  at the boundary / RCU pointer swap). No verb introduces a blocking call on the RT thread.
- **H2:** preserved — `schedule` enqueues into the pre-sized command ring; `edit` builds the new plan
  off-thread within the pre-allocated max-M ceiling (`pan_memory_model.md` §8).
- **H3:** mildly strengthened — sample-accurate intent is no longer expressible on the wrong verb.

### Classification: **DECISION-NEEDED**
The "document which mechanism each call uses" half is a clear win and should just be applied. The
*surface* forks on how unified to make it:

- **Option A — Three explicit verbs `set` / `schedule` / `edit`** (shown above), each named for its
  intention, mechanism documented. *Pro:* the verb *is* the contract; impossible to ask `set` for
  sample-accuracy; matches the three mechanisms 1:1 so nothing is hidden. *Con:* user must learn three
  verbs (but they map to three genuinely different guarantees, so this is honest, not incidental).
- **Option B — One `set(param, value, opts)`** where `opts` selects ramp vs sample-accurate vs bulk.
  *Pro:* one entry point. *Con:* re-hides the mechanism behind an options bag; the dangerous
  combination (`set` + `at_sample`) becomes expressible again, reintroducing the footgun the issue is
  about. Mild Rule-12 violation (uncertainty hidden in opts).
- **Option C — `handle.set` for continuous only (atomic+ramp), keep `engine.events.push` for
  sample-accurate, keep `engine.beginEdit` for topology** (DX report rec #3 verbatim). *Pro:* closest
  to the report's own suggestion; minimal renaming. *Con:* two of the three names live on different
  objects (`handle` vs `engine`), so discoverability is weaker than A's parallel verb set.

**My recommendation: Option A.** Three parallel verbs make the three guarantees impossible to confuse
and keep each mechanism documented at its own call site, which is precisely the friction §5 names.
Option C is a perfectly acceptable lighter-touch alternative if the user wants to minimise churn from
the names already sketched in the DX report.

### Interactions
Couples to **I12** (bypass-with-latency): bypass/mute/solo are themselves `set`-style ramped
transitions per `pan_io_realtime_and_pipeline.md` §7, so they live on the same surface. Couples weakly
to **I5**: neither `schedule` nor `edit` may run on a self-spawned worker without the realtime token.

---

## I4 — Multi-port `connect` grammar is positional; 8-port ceiling is a magic number

**One-line.** Port selection on a multi-port node is `mixer.input(0)` (a bare int) and the 8-port
ceiling is a magic `[8]` checked at commit, not at compile time.
**Raised in DX report:** §3 friction ("Multi-port connect syntax is underspecified… the spec needs to
pin down how you name a specific port"), §11 recommendation #4, §3/§6 cross-refs. Architecture basis:
8-port ceiling is `block.zig:276-278` / `[8]usize`, kept per **hub §2**.

### Proposed resolution

Introduce a **typed `PortId` per node, derived at comptime from the block's `process`/`pull`
signature and any port spec**, with the 8-port ceiling enforced as a `@compileError` at block
instantiation rather than a commit-time surprise. `connect` takes typed port handles on both ends; an
out-of-range or wrong-type port is a compile error naming the port.

```zig
// ILLUSTRATIVE — Zig 0.16. PortId carries node identity + direction + element type at comptime.
pub fn PortId(comptime Node: type, comptime dir: enum { in, out }, comptime Elem: type) type {
    return struct {
        index: u3, // 0..7 — the 8-port ceiling is the *type* of the index (u3), enforced at comptime
        comptime { /* @compileError if Node declares > 8 ports in `dir` */ }
    };
}

// For a homogeneous N-input node (summing mixer), indices are typed and bounds-checked by u3:
const mixer = try g.add(pan.mix.Sum(Num, 2), .{});
try g.connect(dry, mixer.in(0));   // in(2) would be a comptime error: Sum(Num,2) has 2 inputs
try g.connect(wet, mixer.in(1));

// For a heterogeneous node, ports are the named handles of I1 (same PortId mechanism).
```

The ceiling: today it is a runtime `[8]usize`. Make the port-index type `u3` (range 0..7) so the
ceiling is *the type*, and have the block-instantiation comptime block emit a readable
`@compileError` if a `process`/`pull` signature or a `Concat` spec declares more than 8 ports per
direction — turning "magic `[8]`" into a named comptime invariant with a message.

How a developer uses it: `mixer.in(0)` looks the same but is now type-checked; reaching for a
9th port fails at compile time with "block X declares 9 inputs; the per-direction ceiling is 8 (see
pan_architecture_formalisation.md §2)".

### Rationale & spec change
Pure H3 strengthening; zero runtime cost (the op-list still stores resolved integer buffer ids).
Changes:
- **`pan_architecture_formalisation.md` §2** (multiple-heterogeneous-inputs row / 8-port ceiling): state
  that the ceiling is enforced at comptime via the port-index type, with a named `@compileError`.
- **`pan_execution_model.md` §8** (pin-down list): add "the typed `PortId` derivation from the
  `process`/`pull` signature and the comptime 8-port-ceiling check" as a spec obligation.
- **`pan_type_and_numeric_model.md` §1**: note that `PortId` carries the element type so `connect`
  type-checks (this is the same handle I1's `Concat` exposes).

### Invariant check
- **H1 / H2:** untouched — runtime hot path unchanged; buffer ids are still small integers.
- **H3:** **strengthened** — out-of-range and wrong-type connects move from commit-time to compile-time.

### Classification: **CLEAR-WIN**
There is no genuine fork here: typed `PortId` + comptime ceiling is strictly better than the magic
`[8]` with no DX or invariant downside, and it is the substrate I1 needs anyway. The only sub-choice
(index type `u3` vs a checked `comptime_int`) is an implementation detail, not a user-facing decision;
recommend `u3` so the ceiling is self-documenting in the type. **Apply directly.**

### Interactions
Foundational for **I1** (named `Concat` handles are `PortId`s) and **I11** (`Frame(C)` is just the
element type a `PortId` carries). Adopt the `PortId` design once; I1 and I11 consume it.

---

## I5 — FTZ + release-mode NaN-guard behavior is implicit

**One-line.** Flush-to-zero is set on pan-spawned threads but a *self-spawned* DSP worker silently
won't inherit it (ARM64 FPCR is per-thread), and NaN guards compile out in release with no signal —
two of the scariest footguns are invisible.
**Raised in DX report:** §10 ("the two real footguns… should be screaming warnings"), §11
recommendation #5. Architecture basis: `pan_io_realtime_and_pipeline.md` §3 (M3 FPCR per-thread
footgun, Mixxx bug), §10 (telemetry), §3 (NaN guards compiled out in release).

### Proposed resolution

Two first-class, loud surfaces:

1. **A required realtime-thread token.** Running pan DSP on a thread *requires* holding a token whose
   construction sets FTZ/DAZ on the calling thread. The audio HAL mints it for its own callback; a
   user who spawns a worker must call the entry function, making FTZ impossible to forget.

```zig
// ILLUSTRATIVE — Zig 0.16. The token is proof FTZ/DAZ is set on THIS thread.
// On fixed-point targets this is a no-op token (N/A), but the API shape is identical.
const rt = pan.realtime.enterRealtimeThread(); // sets FPCR FZ/DAZ on the calling thread; returns a token
defer rt.leave();
engine.renderInto(token: rt, &scratch, dma_half); // renderInto requires the token => won't compile without it
```

2. **Telemetry exposing whether guards were compiled out**, so a release build cannot silently drop
   NaN protection:

```zig
const t = engine.telemetry();
// guards_compiled_out == true in ReleaseFast/ReleaseSmall; false in Debug/ReleaseSafe.
std.log.info("xruns={d} nan_guards_active={} headroom={d:.0}%",
    .{ t.xrun_count, !t.guards_compiled_out, t.deadline_headroom * 100 });
```

How a developer uses it: you cannot call `renderInto`/start a custom DSP loop without an
`enterRealtimeThread` token, so FTZ-on-self-spawned-threads is structurally enforced; and a one-line
telemetry read tells you in release whether NaN guards are live.

### Rationale & spec change
The token is a *one-time thread-entry call* (H1-safe), and the telemetry field is read off the existing
observability struct. Changes:
- **`pan_io_realtime_and_pipeline.md` §3** (Denormals/NaN): add the **required realtime token** as the
  blessed entry point that sets FTZ/DAZ; state that `renderInto`/custom-worker entry require it; note
  the fixed-point no-op token keeps the API uniform.
- **`pan_io_realtime_and_pipeline.md` §10** (Observability): add `guards_compiled_out: bool` to the
  telemetry struct, defined as true in ReleaseFast/Small, false in Debug/ReleaseSafe.
- **`pan_io_realtime_and_pipeline.md` §12** (pin-down list): add both surfaces.
- **`pan_architecture_formalisation.md` §5** (deferred libraries: "click-free ramps / NaN guards /
  FTZ-DAZ (block-author conventions + one HAL call at thread entry)"): upgrade the wording from
  "convention" to "the required realtime token" for FTZ, keeping NaN guards as a build-mode behavior
  now surfaced in telemetry.

### Invariant check
- **H1:** preserved — `enterRealtimeThread` runs once at thread entry, not on the hot path; setting
  FPCR is a register write, not a syscall.
- **H2:** untouched — no allocation.
- **H3:** mildly strengthened — `renderInto` requiring the token makes "DSP on a non-FTZ thread" a
  compile error rather than a silent runtime hazard. (Caveat: H3 cannot prove FTZ is *still* set if a
  user mutates FPCR after taking the token; the token is a strong nudge, not a proof — stated below.)

### Classification: **DECISION-NEEDED**
The telemetry `guards_compiled_out` field is a clear win — just add it. The *token requirement* forks
on how mandatory to make it:

- **Option A — Token is mandatory: `renderInto`/custom-worker entry won't compile without it.**
  *Pro:* structurally closes the Mixxx-class footgun; you *cannot* run DSP on a non-FTZ thread by
  accident. *Con:* adds a token parameter to the render entry; on fixed-point it is a no-op token
  (slight conceptual noise for embedded authors who don't have an FPU).
- **Option B — Token optional but recommended; pan-spawned threads always FTZ, self-spawned workers
  *should* call `enterRealtimeThread`.** *Pro:* zero friction on the common path (HAL callback).
  *Con:* the footgun survives — a user who spawns a worker and forgets is exactly the §10 failure;
  this is closer to today and weaker on Rule 12.
- **Option C — Token mandatory on desktop float targets only; elided entirely on fixed-point builds.**
  *Pro:* no conceptual noise on embedded (no FPU, no FTZ). *Con:* the API shape now differs between
  targets, eroding the "same code, specialized not forked" claim (I6) — a token that exists on desktop
  but not embedded means the render call signature forks.

**My recommendation: Option A.** It is the only option that actually closes the footgun the issue is
about, and keeping a uniform (no-op on fixed-point) token preserves the same-code-everywhere property
(I6) better than Option C. Accept the small embedded conceptual cost in exchange for one render-entry
signature across all targets.

### Interactions
Couples to **I6** (same-code claim): keeping the token uniform (Option A) rather than target-forked
(Option C) is what preserves the embedded-is-a-specialization story. Couples weakly to **I3**: custom
workers driving `schedule`/`edit` also need the token if they run DSP.

---

## I6 — "Same code, specialized not forked" hinges on commit being comptime-evaluable — but that is asserted, not tested

**One-line.** The strongest structural claim (embedded build = comptime specialization of the desktop
core) holds *only if* the entire commit/coloring pass is genuinely comptime-evaluable end-to-end; if any
block sneaks in non-comptime work the user gets a 40-frame-deep Zig comptime error.
**Raised in DX report:** §8 ("the spec must ensure the commit pass is cleanly comptime-evaluable… or the
embedded DX degrades sharply"), §11 push-back ("must be *tested*, not asserted — an embedded smoke graph
in CI that fails loudly if commit can't run at comptime"). Architecture basis: **hub §5 item 6**
(commit "*Must be comptime-evaluable*"), **hub §7** (embedded specialization), `pan_memory_model.md` §10.

### Proposed resolution

Promote the comptime-evaluability of commit from a one-line mandate to a **tested proof obligation** with
a dedicated CI gate, and give the spec a concrete authoring contract that makes a violation a *clear*
error rather than a deep comptime trace.

1. **CI gate (the test):** a minimal **embedded smoke graph** that calls `g.commitComptime()` inside a
   `comptime` block in a `ReleaseSmall` build for the embedded target. The test *passing* is the proof;
   the build *failing to compile* is the loud failure. This is added to the prototype plan's success
   criteria.

2. **Authoring contract (so failures are legible):** the spec mandates that every core-path facility the
   commit pass touches — topo sort, liveness, per-class coloring, SCC-has-delay, PDC longest-path DP,
   buffer-id assignment, footprint formula — is written against comptime-safe primitives only (no
   allocator that escapes comptime, no `std.Io`, no runtime-only branch). A block's `initialize` that
   does work incompatible with comptime must be flagged: the spec adds a **`comptime_commit_safe`
   obligation** to the `Map`/`Rate` contract so a non-comptime-evaluable block is rejected with a pan
   message ("block X's initialize is not comptime-evaluable; it cannot appear in a comptime graph — see
   hub §7") instead of a raw Zig trace.

```zig
// ILLUSTRATIVE — Zig 0.16. The CI smoke gate: if this file compiles, commit is comptime-evaluable.
test "embedded commit runs at comptime (smoke gate)" {
    const engine = comptime blk: {
        var g = pan.Graph.initComptime(.{ .precision = .q15, .sample_rate = 48_000, .block_size = 64 });
        const src  = g.add(pan.io.I2sDmaSource(EmbNum, 64), .{});
        const gain = g.add(Gain(EmbNum), .{ .gain = 0.8 });
        const sink = g.add(pan.io.I2sDmaSink(EmbNum, 64), .{});
        g.connect(src, gain);
        g.connect(gain, sink);
        break :blk g.commitComptime(); // must fully evaluate at comptime or this test fails to compile
    };
    try std.testing.expect(engine.footprint_bytes > 0); // footprint is a comptime constant
}
```

### Rationale & spec change
This converts a load-bearing assertion into a Rule-9 test (encodes *why* same-code-everywhere works)
and a Rule-12 loud failure. Changes:
- **`pan_categorical_bridge_and_roadmap.md` §5** (Prototype plan): add a row (or fold into row 1/6) —
  *"Embedded comptime-commit smoke gate: `commitComptime()` evaluates at comptime in a ReleaseSmall
  embedded build; success criterion = the smoke graph compiles, footprint is a comptime constant."*
- **`pan_categorical_bridge_and_roadmap.md` §3** (testing methodology): add the comptime-commit gate to
  the list of highest-value gates.
- **`pan_architecture_formalisation.md` §5 item 6** and **§7**: upgrade "*Must be comptime-evaluable*"
  to "*Must be comptime-evaluable, and this is enforced by a CI smoke gate (roadmap §5); the
  commit pass uses only comptime-safe primitives, and a non-comptime-evaluable block is rejected with a
  pan-level error (`comptime_commit_safe`), not a raw Zig trace.*"
- **`pan_execution_model.md` §4.1** (commit-time compilation, "at `comptime` on embedded"): cross-ref the
  gate.

### Invariant check
- **H1 / H2:** untouched (this is a build/CI obligation).
- **H3:** **strengthened and made honest** — H3 claims comptime correctness; this is the test that proves
  the most ambitious instance of it (whole-graph commit at comptime) actually holds.

### Classification: **CLEAR-WIN**
Adding a CI smoke gate and a legible rejection message has no downside and directly de-risks the
architecture's headline claim. The only open sub-question — *which* embedded target the smoke gate
compiles for — is already an explicit open question (`pan_categorical_bridge_and_roadmap.md` §4 item 6)
and can be stubbed with a generic `freestanding` target until the SRAM-budget target is chosen.
**Apply directly.**

### Interactions
Couples to **I5** (Option A keeps the render-entry signature uniform across targets, which is part of
what the smoke gate transitively protects) and to **I7** (the comptime-graph path is the embedded end of
the precision-binding spectrum).

---

## I7 — Precision-as-comptime vs runtime-looking `cfg.precision` seam

**One-line.** Precision is comptime (it changes machine code) but `cfg.precision` and
`numericFor(cfg.precision, …)` *look* runtime, so a newcomer may expect runtime precision switching that
the architecture deliberately doesn't offer.
**Raised in DX report:** §3 friction ("`numericFor(cfg.precision, …)` straddles the comptime/runtime line
awkwardly… a newcomer… may expect runtime precision switching that doesn't exist desktop-side without a
recommit"), §11 push-back ("Either lean fully into comptime (`Graph(.f32)` as a type parameter) or
document the switch-over-active-list mechanism prominently"). Architecture basis:
`pan_type_and_numeric_model.md` §3 (precision comptime via active-precision list), **C4**.

### Proposed resolution

This is exactly the fork the DX report names, so it is `DECISION-NEEDED`. Both arms are coherent; they
trade comptime honesty against config-struct uniformity.

```zig
// Option A — lean fully comptime: precision is a TYPE parameter, not a config field.
var g = pan.Graph(.f32).init(alloc, .{ .sample_rate = 48_000, .block_size = 128, .channels = .stereo });
const Num = pan.Graph(.f32).Numeric; // precision is in the type; no runtime-looking field

// Option B — keep cfg.precision but document the comptime switch-over-active-list, loudly.
const cfg = pan.Config{ .precision = .f32, .sample_rate = 48_000, .block_size = 128, .channels = .stereo };
// numericFor() is a COMPTIME switch over the explicit active-precision list; .precision is comptime-known.
const Num = comptime pan.numericFor(cfg.precision, .{});
```

### Rationale & spec change
- **`pan_type_and_numeric_model.md` §3** (precision/N/W asymmetry) and **§5** (pin-down list): either
  restate the public surface as `Graph(precision)` (Option A) or add an explicit, prominent callout that
  `cfg.precision` is **comptime-known** and `numericFor` is a comptime switch over the active-precision
  list, with the consequence that desktop precision changes require a recommit, stated up front.
- **`pan_developer_experience.md` §3** is downstream documentation and will follow whichever surface the
  user picks (not edited here; noted for coherence).

### Invariant check
Both options are equivalent on invariants:
- **H1 / H2:** untouched.
- **H3:** Option A is marginally stronger (precision can never be mistaken for a runtime field because it
  is in the type); Option B relies on documentation + a `comptime` keyword to convey the same.

### Classification: **DECISION-NEEDED**

- **Option A — `Graph(precision)` as a comptime type parameter.** *Pro:* the comptime nature is
  inescapable; no runtime-looking field to mislead; strongest H3 framing. *Con:* precision leaves the
  `Config` struct, so config is split between a type parameter and a struct — slightly less "one config
  struct flows everywhere"; every `Graph`-typed signature now carries the precision parameter.
- **Option B — keep `cfg.precision`, document the comptime switch prominently, require `comptime`
  at the `numericFor` call.** *Pro:* one uniform `Config` struct (matches the DX report's §3 example and
  the brief's "configuration-driven… for the entire pipeline"); smallest change. *Con:* the seam
  survives as a *documentation* fix, not a *structural* one; a newcomer can still mis-read it until they
  read the callout.

**My recommendation: Option B**, with the comptime nature made loud (the `comptime` keyword at the call
site + a prominent §3 callout). Rationale: the brief explicitly frames the system as *configuration-driven
for the entire pipeline*, and keeping precision inside the single `Config` struct preserves that mental
model and the "config flows from one struct into the whole graph" ergonomic the DX report praises in §3.
The seam is a comprehension tax payable once by documentation, whereas Option A taxes every `Graph`-typed
signature forever. Choose Option A only if the user weights comptime-honesty above config uniformity.

### Interactions
Couples to **I6**: the embedded path already binds precision at comptime via `initComptime`, so Option A
would make desktop and embedded *identical* in this respect (a point in A's favour for same-code purity),
while Option B keeps desktop's config-struct ergonomics at the cost of a desktop/embedded surface
difference. This is the one place where I6's same-code claim and I7 actively pull in opposite directions —
worth flagging to the user.

---

## I8 — The Map/Rate split has no tutorial-grade onboarding surface

**One-line.** The Map/Rate fork is correct and should not be softened, but newcomers will repeatedly
reach for "a `Map` with state," and the spec underestimates the onboarding cost.
**Raised in DX report:** §2 ("the biggest newcomer hazard is psychological"), §11 push-back ("the docs
underestimate how often a newcomer will reach for 'a `Map` with state'… should ship a *tutorial-grade*
explanation plus the excellent build error").

### Proposed resolution

Keep the contract; add two things the spec can mandate now:
1. **A decision rule in the catalog** ("Do I need a `Map` or a `Rate`?"): *If `out.len` is always
   `in.len` and your output depends only on the current input slice → `Map`. If you accumulate across
   calls, emit a different number of samples than you consume, or buffer until you have enough →
   `Rate`. Per-sample IIR/biquad state is still a `Map` (rate-1:1); a ring/overlap buffer is the
   `Rate` smell."* The biquad-vs-Framer distinction is the load-bearing example.
2. **Sharpen the existing build error** (already specified in `pan_execution_model.md` §2 and shown in
   DX §2) to *also* fire on the inverse mistake — a block that keeps a ring/accumulator but declares no
   `pull`/`out_per_in` cannot be auto-detected, so instead the spec mandates a **tutorial chapter** plus
   the decision rule, since the "Map with hidden state" case is exactly the one the type system *cannot*
   catch (a `Map` is allowed to have per-sample state like a biquad).

### Rationale & spec change
No API change — this is a documentation/spec-coverage obligation (Rule 9: encode *why* the split exists).
Changes:
- **`pan_categorical_bridge_and_roadmap.md` §2** (block taxonomy) or **catalog.md**: add the Map-vs-Rate
  decision rule and the biquad-vs-Framer worked distinction.
- **`pan_execution_model.md` §2.3** ("Why `Rate` cannot be folded into `Map`"): add the newcomer
  decision rule as a sidebar, and explicitly state the trap (per-sample state ≠ Rate; cross-call
  accumulation = Rate).

### Invariant check
H1/H2/H3 untouched — pure documentation/spec-coverage. (The contract itself, which *is* an H3 mechanism,
is unchanged.)

### Classification: **CLEAR-WIN**
Adding a decision rule and a worked example has no downside and directly addresses the named onboarding
cost. **Apply directly** (as a catalog/spec doc addition).

### Interactions
None structural. Reinforces the value of the existing `algorithmic_latency`/`out_per_in` build error
(`pan_execution_model.md` §2).

---

## I9 — Single-sample inner-loop feedback node surface is unpinned

**One-line.** For tight feedback (ladder filters, Karplus-Strong) the default one-block feedback latency
is too coarse; the docs promise a "single-sample inner-loop" node but don't pin its surface.
**Raised in DX report:** §4 ("The spec hasn't pinned its surface down — a plausible one is a composite you
author as one block whose `process` runs a per-sample loop internally"). Architecture basis:
`pan_memory_model.md` §6.1 ("a fused single-sample inner-loop node… is offered for tight feedback").

### Proposed resolution

Bless the surface the DX report already sketches: a **single block whose `process` runs the per-sample
feedback loop internally**, so the tight loop lives *inside* one kernel (sample-accurate) rather than
across the colorer's block granularity. The spec pins it as a *Map authoring pattern*, not a new core
primitive — the block is rate-1:1 (`out.len == in.len`) and simply iterates samples with its own
persistent state.

```zig
// ILLUSTRATIVE — Zig 0.16. A one-pole resonant loop fused into a single Map kernel.
// Persistent state (z^-1) lives in the struct (pool-excluded, mem §6.2); the feedback is
// per-SAMPLE inside process(), not per-BLOCK across the colorer.
pub fn LadderLowpass(comptime Num: pan.Numeric) type {
    return struct {
        const Self = @This();
        const Lane = Num.Lane;
        z: [4]Lane = .{0,0,0,0}, // persistent inner state across calls
        cutoff: Lane = 1000, resonance: Lane = 0.5,
        pub fn initialize(self: *Self, _: std.mem.Allocator) !void { @memset(&self.z, 0); }
        pub fn process(self: *Self, in: []const Lane, out: []Lane) void {
            for (in, out) |x, *y| {
                // per-sample feedback loop runs here, sample-accurate; no cross-block z^-1 needed
                // ... 4-pole ladder update reading/writing self.z ...
                y.* = self.z[3];
            }
        }
        // NOT aliasing_safe by default (state-dependent ordering); author opts in only if proven.
    };
}
```

The spec's job is to **name this the blessed idiom** for sub-block-latency feedback and to state the
trade explicitly: you forfeit the colorer's ability to fuse/split across the loop (it is opaque to the
scheduler) in exchange for sample-accurate feedback. This is distinct from the graph-level
`DelayLine`-in-a-cycle idiom (`pan_memory_model.md` §6.1), which is one-block-latency but composable.

### Rationale & spec change
- **`pan_memory_model.md` §6.1** ("the `z⁻¹` rule"): expand the single-sentence promise into a pinned
  pattern — "tight feedback is authored as a single `Map` block whose `process` runs the per-sample loop
  over internal persistent state; this trades scheduler-visibility for sample-accuracy and is the blessed
  alternative to a graph-level back-edge (which carries one-block latency)."
- **`pan_categorical_bridge_and_roadmap.md` §2** (Time/feedback library blocks): note that ladder/KS/comb
  tight-feedback primitives ship as fused single-block kernels.

### Invariant check
- **H1:** preserved — the per-sample loop is bounded, branch-free DSP inside one wait-free kernel; no
  blocking.
- **H2:** preserved — inner state is fixed-size persistent (pool-excluded), known at commit.
- **H3:** unchanged — it's an ordinary rate-1:1 `Map`; correctness of the inner loop is the author's
  (tested against the SciPy oracle).

### Classification: **DECISION-NEEDED**
The *pattern* (fuse the loop into one kernel) is the only sane H1-respecting option, but there is a real
fork on **how much the library does for you**:

- **Option A — Document the pattern only; ladder/KS/comb ship as ordinary library `Map` blocks** (above).
  *Pro:* zero new machinery; uses the existing `Map` contract; authors of new tight-feedback effects
  follow the same idiom. *Con:* a user inventing a *novel* tight-feedback topology must hand-write the
  per-sample loop (no graph-level help).
- **Option B — Provide a `block-size-1 subgraph` combinator** that takes a small subgraph and emits a
  single fused block running it per-sample (gen~/Cmajor-style). *Pro:* lets users compose tight feedback
  from existing blocks. *Con:* significant new comptime machinery (a mini-scheduler that runs at N=1
  inside a kernel); higher risk; arguably violates Rule 2 (speculative) until a real use case demands it.
- **Option C — Provide both:** ship A now, defer B as a measured library addition.
  *Pro:* unblocks the named cases (ladder/KS) immediately, leaves the door open. *Con:* none beyond
  documenting that B is deferred.

**My recommendation: Option C** — pin Option A now as the blessed idiom and ship the named primitives
that way; explicitly defer Option B's block-size-1 subgraph combinator as a layered library subject to a
real use case (Rule 2). This unblocks the §4 examples without committing to speculative machinery.

### Interactions
Couples to **I2** (`aliasing_safe`): a fused feedback kernel typically is *not* aliasing-safe (state
makes ordering matter), so the renamed flag's docs should call this out.

---

## I10 — `FeatureCollectorSink` growth policy is unspecified

**One-line.** The sink is a non-RT growable time-series; `capacity_hint` is load-bearing for avoiding
reallocs mid-run, but the spec calls it growable without specifying the growth policy.
**Raised in DX report:** §6 friction ("the docs call it growable but don't specify the growth policy").
Architecture basis: `pan_categorical_bridge_and_roadmap.md` §2 (`FeatureCollectorSink`), runs on a non-RT
pull root (`pan_execution_model.md` §6).

### Proposed resolution

Pin a concrete, non-RT growth policy and make `capacity_hint` a true reservation:
- `capacity_hint` **pre-reserves** that many rows at `initialize` (one allocation up front).
- Growth beyond the hint uses **geometric growth (×2)** via the unmanaged `std.ArrayList` per-call
  allocator path — *explicitly allowed because this sink lives only on a non-RT root* (it can never sit
  on the audio deadline; cross-root hand-off is SPSC-tap only, `pan_execution_model.md` §6).
- The spec states the **H1/H2 boundary explicitly**: this is the one blessed place a `realloc` may
  happen, *because it is provably off the RT path* — and a `FeatureCollectorSink` wired onto an audio
  (RT) root is a **commit error**.

```zig
// ILLUSTRATIVE — Zig 0.16. Unmanaged ArrayList, allocator per call; non-RT root only.
rows: std.ArrayList(Row) = .empty,
pub fn initialize(self: *Self, a: std.mem.Allocator) !void {
    try self.rows.ensureTotalCapacity(a, self.capacity_hint); // one up-front reservation
}
pub fn push(self: *Self, a: std.mem.Allocator, row: Row) !void {
    try self.rows.append(a, row); // geometric growth past the hint — legal: non-RT root
}
```

### Rationale & spec change
- **`pan_categorical_bridge_and_roadmap.md` §2** (`FeatureCollectorSink` bullet): specify the
  pre-reserve-then-geometric-growth policy, the `capacity_hint` reservation semantics, and the
  **commit-time rule that this sink is rejected on an RT root** (so the H1 exception is contained).
- **`pan_execution_model.md` §6**: cross-reference that growable sinks are legal *only* on non-RT pull
  roots.

### Invariant check
- **H1:** preserved precisely *because* the growth is fenced to non-RT roots, with a commit-time check
  that the sink never lands on the audio root. (This is the careful part — stated as a hard rule, not a
  convention.)
- **H2:** the *RT* memory bound is unaffected (this sink isn't in the RT pool); its own memory is bounded
  by the run length, which is acceptable off-deadline.
- **H3:** strengthened — wiring a growable sink onto an RT root becomes a commit error.

### Classification: **CLEAR-WIN**
Pre-reserve + geometric growth + a commit-time RT-root rejection is the obvious, low-risk policy with no
real alternative worth a user decision (a fixed-capacity ring would silently drop data — worse for an
analysis time-series). **Apply directly.**

### Interactions
Couples to **I3/I5** only insofar as it reinforces the RT vs non-RT boundary; otherwise independent.

---

## I11 — Channel-typed-frame element surface (`Frame(C)`) is unpinned

**One-line.** The constant-power panner changes channel count via a `Frame(C)` element type carrying its
channel count in the type, but the DX report flags this surface as a plausible guess, not pinned.
**Raised in DX report:** §1 ("The spec hasn't pinned down the exact channel-typed-frame surface — a
plausible one is a `Frame(C)` element type carrying its channel count in the type"). Architecture basis:
`pan_type_and_numeric_model.md` §2.1 (channel rides in the format; planar internal form;
`process(in: []const Frame(C_in), out: []Frame(C_out))`).

### Proposed resolution

Pin `Frame(Lane, C)` into the canonical typed-port catalog as the channel-carrying element type, with the
channel count `C` comptime in the type (so a channel-changing block is just a port whose in/out `Frame`
differ in `C`), consistent with the **planar internal canonical form** the type doc already commits to.

```zig
// ILLUSTRATIVE — Zig 0.16. Frame(Lane, C): C channels, comptime; planar internally.
pub fn Frame(comptime Lane: type, comptime C: usize) type {
    return struct { ch: [C]Lane }; // a named struct => has typeName(); pool-class key = (Frame(Lane,C), N)
}
// A panner's ports differ only in C:
//   process(self, in: []const Frame(Lane,1), out: []Frame(Lane,2)) void
```

Add `Frame(Lane, C)` as a first-class row in the typed-port catalog table alongside `Sample(T)`,
`Complex(T)`, `FeatureFrame(K)`, `Scalar(T)`, `Bounded(T,Kmax)`, with pool class key
`(Frame(Lane,C), N)`. State that `Sample(T)` is the `C=1` case (so a mono kernel and a `Frame(Lane,1)`
kernel are the same thing) and that the planar/interleaved conversion happens only at the I/O boundary
(`pan_io_realtime_and_pipeline.md` §5).

### Rationale & spec change
- **`pan_type_and_numeric_model.md` §1** (typed-port catalog table): add the `Frame(Lane, C)` row and the
  `Sample(T) == Frame(Lane,1)` identity.
- **`pan_type_and_numeric_model.md` §2.1** (channel model): replace the parenthetical
  `process(in: []const Frame(C_in), out: []Frame(C_out))` sketch with the pinned `Frame(Lane, C)`
  definition and the pool-class-key statement.
- **`pan_memory_model.md` §2** (pool classes): add `Frame(Lane, C)` to the example class keys.

### Invariant check
- **H1 / H2:** untouched — `Frame(Lane, C)` is a fixed-size comptime type; pool class is determined at
  commit exactly like the other element types.
- **H3:** strengthened — channel-count mismatch between wired ports becomes a comptime/commit type error
  (the channel count is in the element type, so `connect` checks it via the I4 `PortId`).

### Classification: **CLEAR-WIN**
`Frame(Lane, C)` is the natural completion of the typed-port catalog and the only surface consistent with
the planar-internal commitment and the I4 typed-port machinery. The open question of *planar vs
interleaved internal form* (`pan_categorical_bridge_and_roadmap.md` §4 item 2) is **orthogonal** — it is
about memory layout at the I/O boundary, not about whether `Frame(C)` carries `C` in the type — so this
can be pinned without resolving that open question. **Apply directly.**

### Interactions
Couples to **I4** (the channel count is checked by the typed `PortId`) and **I1** (a `Concat` may carry
`Frame(C)` elements with no special case). Couples to the existing **`ChannelMap` combinator**
(`pan_categorical_bridge_and_roadmap.md` §2), which replicates a subgraph across `C` — `Frame(Lane,C)` is
the element type its stacked outputs use; pinning `Frame` also tightens `ChannelMap`'s plausible-only
surface (DX §6).

---

## I12 — Custom-bypass-with-latency author obligation is invisible

**One-line.** A bypassed block that has latency must still delay its signal, or bypassing it shifts
timing and breaks PDC on parallel paths; pan handles this for built-in bypass, but a user authoring a
*custom* bypass inherits a silent correctness obligation.
**Raised in DX report:** §5 ("if you author a custom bypass you must honour it"). Architecture basis:
`pan_io_realtime_and_pipeline.md` §7 ("a *bypassed* block that has latency must **still delay** its
signal"), `pan_memory_model.md` §7 (PDC).

### Proposed resolution

Two cheap, loud measures:
1. **Spec the obligation as a named contract**: a block that declares `algorithmic_latency > 0` and
   supports bypass must, when bypassed, route through a compensating delay of exactly its
   `algorithmic_latency` (the same `DelayLine` PDC already inserts). The spec states this as the
   **bypass-preserves-latency law** and ties it to the existing PDC pass.
2. **Make built-in bypass the default and custom bypass opt-in with a warning**: the engine's `set`-based
   bypass (I3) already honours latency; the spec mandates that *custom* bypass authors who manipulate
   routing directly are flagged in docs and, where detectable at commit (a block with declared latency
   marked bypass-capable but providing no compensating path), warned.

### Rationale & spec change
No new RT mechanism — it reuses PDC's compensating `DelayLine` (`pan_memory_model.md` §7). Changes:
- **`pan_io_realtime_and_pipeline.md` §7** (click-free correctness corner): elevate the
  bypassed-block-must-delay note from a parenthetical to a **named law** ("bypass preserves latency") and
  state that built-in bypass honours it automatically while custom bypass must route through the
  compensating delay.
- **`pan_memory_model.md` §7** (PDC): note that bypass is a PDC-relevant state change — bypassing a
  latent block must keep its compensating delay active.

### Invariant check
- **H1 / H2:** untouched — the compensating delay is already allocated by PDC at commit (persistent
  category); bypass just keeps routing through it.
- **H3:** mildly strengthened — where detectable, a latent bypass-capable block with no compensating path
  can be a commit warning/error.

### Classification: **CLEAR-WIN**
Naming an existing correctness corner as a law and reusing the existing PDC delay has no downside and
closes a silent footgun. **Apply directly.**

### Interactions
Couples to **I3** (bypass is a `set`-style ramped transition on the unified control surface).

---

## DECISION POINTS

Only the `DECISION-NEEDED` items. Each row is phrased to drop into a user-facing multiple-choice question.

| # | Decision | Options (mutually exclusive) | My recommendation |
|---|---|---|---|
| **I1** | Fan-in / `Concat` connection surface (kill positional) | **A.** Named-field spec `Concat(.{ .mfcc = …, .rms = … })`, connect via `node.in.<name>`; output struct field order = column order. **B.** Typed `port(name, ElemType)` accessor returning a handle (element type repeated at each connect). **C.** Ordered slice of typed handles (still positional — rejected on merit). | **A** — column identity = field name, so a transposed feature matrix is impossible; no element-type repetition. (B acceptable if the user wants element type visible at each `connect`.) |
| **I2** | Form of the renamed `in_place` safety assertion | **A.** `pub const aliasing_safe = true;` (bare named const). **B.** `aliasing_safe` + a required rationale string the validator surfaces. **C.** Marker method `fn assertAliasSafe() void {}`. | **A** — one-line rename fully resolves the "looks like a perf flag" friction; trivial comptime path. (B only if the user wants authors to justify the claim in-source.) |
| **I3** | Unified parameter API shape (mechanism stays documented either way) | **A.** Three parallel verbs `set` (atomic+ramp) / `schedule` (SPSC, sample-accurate) / `edit` (RCU topology). **B.** One `set(param, value, opts)` with an options bag. **C.** `handle.set` (continuous) + `engine.events.push` (sample-accurate) + `engine.beginEdit` (topology) — DX report's own sketch. | **A** — three guarantees, three verbs; impossible to ask `set` for sample-accuracy (closes the §5 footgun). (C is a fine lighter-touch fallback.) Note: B reintroduces the footgun — discouraged. |
| **I5** | How mandatory is the FTZ realtime-thread token? (telemetry `guards_compiled_out` is a clear win regardless) | **A.** Mandatory: `renderInto`/custom-worker entry won't compile without the token; uniform (no-op) token on fixed-point. **B.** Optional but recommended; pan threads always FTZ, self-spawned workers *should* call it. **C.** Mandatory on desktop float only; elided on fixed-point (render signature forks per target). | **A** — only option that structurally closes the Mixxx-class footgun; uniform token preserves same-code-everywhere (I6) better than C. |
| **I7** | Precision binding surface | **A.** `Graph(precision)` as a comptime type parameter (precision leaves `Config`). **B.** Keep `cfg.precision`; make the comptime switch loud (`comptime` keyword at `numericFor` + prominent §3 callout); desktop precision change ⇒ recommit. | **B** — preserves the brief's "configuration-driven for the entire pipeline" single-`Config` mental model; seam is a one-time documentation tax vs A's per-signature tax. **Flag:** A would make desktop/embedded identical (helps I6's same-code purity) — the one place I6 and I7 pull opposite ways; surface to user. |
| **I9** | Tight (sample-accurate) feedback surface | **A.** Document the fused-single-`Map`-kernel pattern; ship ladder/KS/comb as ordinary library blocks. **B.** A block-size-1 subgraph combinator (gen~/Cmajor-style) composing tight feedback from sub-blocks. **C.** Both — ship A now, defer B as a measured library addition. | **C** — pin A as the blessed idiom now (unblocks §4 examples); defer B's speculative machinery until a real use case (Rule 2). |

**Cross-decision flag for the user:** **I7-A vs I7-B interacts with I6 and I5-A.** Choosing I7-A
(precision in the type) makes desktop and embedded bind precision identically, reinforcing the
"same code, specialized not forked" claim that I6 tests and I5-A's uniform token protects. Choosing I7-B
keeps desktop's config-struct ergonomics at the cost of one desktop/embedded surface difference. If
same-code purity is the top priority, prefer I7-A; if config-driven ergonomics win, prefer I7-B (my
default). All other recommendations are independent of this choice.
