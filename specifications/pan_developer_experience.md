# pan — Developer Experience (what it is *like* to build with it)

> **Status:** developer-experience / UX-from-the-builder's-seat companion. This document
> imagines pan **implemented faithfully** to the six architecture documents and asks the one
> question those documents never ask directly: *what does it feel like to write code against
> this thing?* It is concrete, code-first, and deliberately opinionated about friction.
>
> **Source of truth (do not contradict — this doc defers to them):**
> [`catalog.md`](catalog.md) (the single source of truth) ·
> hub — [`pan_architecture_formalisation.md`](pan_architecture_formalisation.md) ·
> [`pan_execution_model.md`](pan_execution_model.md) ·
> [`pan_memory_model.md`](pan_memory_model.md) ·
> [`pan_type_and_numeric_model.md`](pan_type_and_numeric_model.md) ·
> [`pan_io_realtime_and_pipeline.md`](pan_io_realtime_and_pipeline.md) ·
> [`pan_categorical_bridge_and_roadmap.md`](pan_categorical_bridge_and_roadmap.md).
>
> **⚠️ All Zig below is illustrative.** pan does not exist yet; none of this has been compiled.
> The snippets are written to be plausibly-idiomatic **Zig 0.16.0** (unmanaged containers built
> with `.empty`, allocator-per-call, `@Vector`, `callconv(.c)`, lowercase `.@"struct"` typeInfo
> tags, the `@Int`/`@Struct` constructors, `std.Io` for I/O). Where the architecture leaves an
> API surface unspecified I say **"the spec hasn't pinned this down — a plausible surface is…"**
> and label the guess. Treat the *shapes* as real and the *exact identifiers* as proposals.

---

## 0. First contact / the mental model

Here is the whole of pan in one paragraph, and you should re-read it until it is boring:

> You **author blocks as plain structs.** A block's *type signature is its API*: a `Map` block
> declares `pub fn process(self, in: []const In, out: []Out) void`, a `Rate` block declares
> `pull` plus `out_per_in` and `algorithmic_latency`. You **wire blocks into a graph** at
> startup. You **commit** the graph — a one-time, off-the-hot-path pass that type-checks every
> edge, schedules the DAG, colors a buffer pool, verifies feedback loops contain a delay, and
> emits a flat *render op-list*. Then a **pull root** (the audio device callback is one; a 60fps
> analysis timer is another) drives the committed graph: each callback the op-list is replayed
> wait-free, filling exactly the buffer the device asked for. You never allocate, lock, or walk
> the graph on the hot path — the commit step already did all of that.

Four things you must internalise before you write a line:

1. **Map vs Rate is a real fork, not a flag.** A `Map` is rate-1:1 and pure over its input slice
   (`out.len == in.len`). A `Rate` block owns internal clocked state, can emit 0-or-many samples
   per call, and **must** declare both `out_per_in` and `algorithmic_latency`. If you reach for a
   ring buffer or an "I'll emit when I have enough" pattern inside a `Map`, you have the wrong
   contract. ([exec §2](pan_execution_model.md))
2. **Commit is a phase, not a function call you forget about.** Authoring is loose and dynamic;
   running is frozen and static. The boundary between them is `graph.commit()`. Most of pan's
   guarantees (and most of its error messages) live at that boundary. ([hub §5](pan_architecture_formalisation.md))
3. **Pull semantics mean "demand flows backward."** The root asks for N frames; the scheduler
   renders upstream first so that by the time your block runs, its inputs are already present.
   You don't poll "is data available" — it always is. ([exec §3](pan_execution_model.md))
4. **Precision is comptime, block size is runtime.** You pick `f32`/`i16` once, at config time
   (it changes the machine code). The device picks N, and it can change under you. Don't try to
   make N comptime for stream ports. ([type §3](pan_type_and_numeric_model.md))

If you've used ZigRadio, two of these are familiar (type-signature-is-the-API, the `SampleMux`
seam) and two are new (the Map/Rate split, the synchronous pull executor). If you've used JUCE's
`AudioProcessorGraph`, the commit→op-list→replay loop will feel like home.

---

## 1. Authoring a `Map` block — gain, then a constant-power panner

The smallest useful block. *Illustrative.*

```zig
const pan = @import("pan");

/// A trim/gain block. Mono-or-multichannel agnostic; rate-1:1; type-stable.
pub fn Gain(comptime Num: pan.Numeric) type {
    return struct {
        const Self = @This();
        const Lane = Num.Lane;

        gain: Lane = 1.0,

        // initialize() runs at commit. Allocation, table precompute, coefficient
        // baking — all here, never in process(). Mirrors ZigRadio's discipline.
        pub fn initialize(self: *Self, _: std.mem.Allocator) !void {
            _ = self; // nothing to allocate for a gain
        }

        // The type signature IS the API. pan reads @typeInfo(process) at comptime:
        //   param[1] = []const Lane  -> one input port, element type Lane
        //   param[2] = []Lane        -> one output port, element type Lane
        // out.len == in.len is the Map contract; pan enforces it.
        pub fn process(self: *Self, in: []const Lane, out: []Lane) void {
            const W = Num.W;
            const Vec = @Vector(W, Lane);
            const g: Vec = @splat(self.gain);

            // comptime-W body + scalar tail vectorizes fully even though N is runtime.
            var i: usize = 0;
            while (i + W <= in.len) : (i += W) {
                const v: Vec = in[i..][0..W].*;
                out[i..][0..W].* = v * g;
            }
            while (i < in.len) : (i += 1) out[i] = in[i] * self.gain; // tail
        }

        // I assert this kernel is free of intra-call read-after-write aliasing hazards
        // (reading in[k] / writing out[k] never crosses lanes), so the colorer MAY alias
        // my input and output buffers (it still proves single-consumer + last-use).
        pub const aliasing_safe = true;
    };
}
```

What a newcomer needs to internalise here:

- **`process` is the contract.** There is no separate "declare your ports" step — pan derives
  port count, direction (`is_const` → input), and element type (`.pointer.child`) by reflecting
  on the function signature at comptime. This is genuinely lovely: the thing you'd document is
  the thing the compiler reads. ([hub §2](pan_architecture_formalisation.md), [type §1](pan_type_and_numeric_model.md))
- **`Num` carries everything precision-related**: the lane type, the accumulator width, whether
  integer ops saturate, and the SIMD width `W` for this target. You write the kernel once; `Gain(f32_num)`
  and `Gain(q15_num)` are different monomorphised types. ([type §4](pan_type_and_numeric_model.md))
- **`aliasing_safe = true` is a *hint*, not a command.** The name telegraphs the contract (the
  author asserts the kernel is free of intra-call read-after-write aliasing hazards), not a perf
  knob. The colorer honours it only after proving single-consumer + last-use + identical in/out
  element type & count. Get the kernel wrong (read `in[i+1]` while writing `out[i]`) and you've
  created a silent corruption that *only manifests when coloring aliases the buffers* — which is
  exactly what the B≡C differential test ([mem §9](pan_memory_model.md)) exists to catch, with a
  message that **quotes your `aliasing_safe` assertion back at you**. **Residual obligation:** the
  truth of the claim lives in a test, not in the type system — which is why the name makes it a claim
  to scrutinise.

Now a constant-power panner — the block that gives the library its name. It *changes channel
count* (mono → stereo), which rides in the port's element type via the channel layout.

```zig
// The channel-carrying element is the pinned Frame(Lane, C): struct { ch: [C]Lane }, C comptime,
// Sample(T) == Frame(Lane,1), planar internally ([type §1, §2.1]).
pub fn ConstantPowerPan(comptime Num: pan.Numeric) type {
    return struct {
        const Self = @This();
        const Lane = Num.Lane;
        const In = pan.Frame(Lane, 1);   // mono frame element
        const Out = pan.Frame(Lane, 2);  // stereo frame element

        position: Lane = 0.0, // -1 = hard left, +1 = hard right

        pub fn initialize(self: *Self, _: std.mem.Allocator) !void { _ = self; }

        pub fn process(self: *Self, in: []const In, out: []Out) void {
            // equal-power: angle in [0, pi/2]; gains are cos/sin.
            const theta = (self.position * 0.5 + 0.5) * std.math.pi * 0.5;
            const l = @cos(theta);
            const r = @sin(theta);
            for (in, out) |frame, *o| {
                o.ch[0] = frame.ch[0] * l;
                o.ch[1] = frame.ch[0] * r;
            }
        }
        // NOT aliasing_safe: element type and channel count differ in vs out.
    };
}
```

**Ergonomics verdict for Map blocks:** clean. The struct is the block, the method is the API,
precision is a comptime parameter you mostly ignore inside the kernel. The one genuine newcomer
caution is `aliasing_safe`: the name now telegraphs that it is a correctness assertion (not a perf
knob) — a claim a reviewer scrutinises. The internal
**planar** channel form ([type §2.1](pan_type_and_numeric_model.md)) means a channel-agnostic
block (gain) needs no per-channel ceremony, while a channel-*changing* block (the panner) just
changes its port element type — that's a nice consistency once it clicks.

---

## 2. Authoring a `Rate` block — a Framer and a decimator

This is the contract people will get wrong first, so it deserves the most care.

A `Rate` block is rate-elastic: it owns an internal ring, may return **0** outputs (still
accumulating) or **many** (hop smaller than the request), and **must** tell the scheduler two
*distinct* numbers: `out_per_in` (the rate ratio) and `algorithmic_latency` (samples of delay it
introduces). Conflating them is the architecture's named sin (audit S2,
[exec §2](pan_execution_model.md)). *Illustrative.*

```zig
/// Slices a continuous stream into overlapping windows of FRAME samples, hop HOP.
/// Emits one FeatureFrame-sized window each time HOP new samples have arrived.
pub fn Framer(comptime Lane: type, comptime FRAME: usize, comptime HOP: usize) type {
    return struct {
        const Self = @This();
        const Window = pan.FeatureFrame(FRAME); // named struct {v: [FRAME]Lane}, carries typeName()

        ring: [FRAME]Lane = undefined, // persistent overlap state (pool-EXCLUDED, see mem §6.2)
        filled: usize = 0,

        // --- the two declarations pan DEMANDS of every Rate block ---
        pub const out_per_in: pan.Ratio = .{ .num = 1, .den = HOP }; // 1 window per HOP in-samples
        pub const algorithmic_latency: usize = FRAME - HOP;          // group delay, distinct from rate

        pub fn initialize(self: *Self, _: std.mem.Allocator) !void {
            @memset(&self.ring, 0);
            self.filled = 0;
        }

        // "To produce `want` windows, how many input samples must you hand me?"
        pub fn needed_input(self: *Self, want: usize) usize {
            _ = self;
            return want * HOP; // steady-state; the ring absorbs H ∤ N misalignment
        }

        // Returns the number of windows actually produced (may be 0 or many).
        pub fn pull(self: *Self, want: usize, out: []Window) usize {
            var produced: usize = 0;
            // ... shift HOP samples into self.ring, emit a window per hop boundary ...
            // (body elided; the point is the SHAPE of the contract, not the DSP)
            _ = .{ self, want, out };
            return produced;
        }
    };
}
```

The forcing function — and it is genuinely good DX — is the **build error when you forget**:

```text
error: block 'Decimator(f32, 4)' is a Rate block (declares `pull`) but does not declare
       `algorithmic_latency`. A Rate block must declare BOTH `out_per_in` and
       `algorithmic_latency` (they are distinct: latency ≠ decimation). See pan_execution_model.md §2.
   note: declare `pub const algorithmic_latency: usize = ...;` (use 0 only if the transform
         is truly zero-delay, which a decimator is not).
```

That message is doing Rule 12's job (fail loud) and Rule 1's job (push back at authoring time).
Compare a decimator, which is the *other* axis — it changes rate but, for a naive
drop-every-Dth-sample design, has trivial latency; a polyphase one has real latency. The author
is forced to be honest about which:

```zig
pub fn Decimator(comptime Lane: type, comptime D: usize) type {
    return struct {
        // ...
        pub const out_per_in: pan.Ratio = .{ .num = 1, .den = D }; // D:1 decimation
        pub const algorithmic_latency: usize = 0;                  // naive; a sinc-polyphase would report its FIR group delay
        pub fn needed_input(_: *@This(), want: usize) usize { return want * D; }
        pub fn pull(self: *@This(), want: usize, out: []Lane) usize { _ = .{ self, want, out }; return 0; }
    };
}
```

**Why this is a *different* contract and what the author carries:** the scheduler's recursion is
`needed_input(want)` upstream, not "pull N everywhere." The block owns the misalignment when the
hop doesn't divide the device buffer (T4) — pan deliberately refuses to force `N ≡ 0 (mod H)`, so
you, the Framer author, own the ring. That's more responsibility than a `Map`, and the payoff is
that the *device buffer size never leaks into your algorithm's internal hop.*

**Ergonomics verdict for Rate blocks:** the contract is heavier and the failure mode is subtle
(a wrong `needed_input` desyncs the whole graph silently until a latency-contract test catches
it — [roadmap §3](pan_categorical_bridge_and_roadmap.md)). But the *declarations are checked*,
the build error is excellent, and `Framer`/`Decimator`/resampler share one obvious shape. The
biggest newcomer hazard is psychological: people will try to write a Framer as a `Map` with
"state," and pan should — and per the error above, does — refuse.

---

## 3. Building & running a graph

The brief wants: add nodes, fan-out, fan-in, connect; config-driven precision/rate/block-size;
commit; attach a CoreAudio sink + LPCM source; start. Here is the clean round-trip the
prototype-plan vertical slice (gain → biquad → pan) implies. *Illustrative; the builder API is
not pinned down — this is a plausible surface.*

```zig
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer if (gpa.deinit() == .leak) @panic("leak");
    const alloc = gpa.allocator();

    // ---- config drives precision / rate / block-size for the whole pipeline ----
    const cfg = pan.Config{
        .precision = .f32,        // comptime-selected monomorph set
        .sample_rate = 48_000,
        .block_size = 128,        // a HINT; the device may override at commit (runtime N)
        .channels = .stereo,
    };
    const Num = comptime pan.numericFor(cfg.precision, .{}); // comptime switch over the active-precision list; {Lane=f32, Acc=f32, saturate=false, W=4 on M3}

    var g = pan.Graph.init(alloc, cfg);
    defer g.deinit();

    // ---- add nodes (returns handles; storage lives in the graph arena) ----
    const src   = try g.add(pan.io.LpcmSource(Num), .{ .path = "drums.lpcm", .format = .s16le });
    const gain  = try g.add(Gain(Num), .{ .gain = 0.8 });
    const biquad= try g.add(pan.filters.Biquad(Num, .lowpass), .{ .cutoff = 1200, .q = 0.707 });
    const panner= try g.add(ConstantPowerPan(Num), .{ .position = -0.3 });
    const sink  = try g.add(pan.io.CoreAudioSink(Num), .{}); // M3 dev machine HAL

    // ---- connect: src -> gain -> biquad -> pan -> sink ----
    try g.connect(src, gain);
    try g.connect(gain, biquad);
    try g.connect(biquad, panner);
    try g.connect(panner, sink);

    // ---- COMMIT: type-check, schedule, color the pool, verify, emit op-list ----
    // Everything that can go wrong with the topology goes wrong HERE, loudly.
    var engine = try g.commit(); // returns the frozen, runnable engine
    defer engine.deinit();

    std.log.info("committed: {d} render ops, {d} KB static pool, {d} edges live max",
        .{ engine.plan.ops.len, engine.plan.pool_bytes / 1024, engine.plan.max_live });

    // ---- start: the CoreAudioSink is a clock-driven pull root; its callback drives the op-list ----
    try engine.start(); // hands the op-list to the audio callback; returns immediately
    defer engine.stop();

    // round-trip latency expectation: one device block. At 128/48k ≈ 2.67 ms,
    // PLUS any Rate-block algorithmic_latency on the path (here: 0). Target sub-5 ms. (exec §1)
    try pan.waitForSignal(.interrupt);
}
```

Fan-out and fan-in look like what you'd hope:

```zig
// Fan-out: one source, two consumers. The colorer pins the buffer for the branch span;
// no per-reader copy because both readers are non-mutating. (mem §4)
try g.connect(src, gain);
try g.connect(src, meter); // src now feeds both

// Fan-in: a summing mixer. Additive summing into a destination buffer is the default. (mem §4)
// Ports are typed PortId handles: mixer.in(i) is bounds-checked at comptime (in(2) on a Sum(Num,2)
// is a compile error), and connect type-checks the element type. (hub §2, type §1)
const mixer = try g.add(pan.mix.Sum(Num, 2), .{});
try g.connect(dry,  mixer.in(0));
try g.connect(wet,  mixer.in(1));
```

**What feels clean:** the add/connect/commit/start arc is exactly four verbs and they mean what
they say. Config flows from one struct into the whole graph. The commit log line (ops / pool
bytes / max-live-edges) is the kind of observability the I/O doc demands ([io §10](pan_io_realtime_and_pipeline.md))
and it's *immediately* useful — you see your static footprint before you ever hear audio.

**Now pinned (was friction):**
- **Multi-port connect is typed, not positional.** `mixer.in(0)` returns a typed `PortId` (node
  identity + direction + element type) minted at comptime from the signature; an out-of-range index
  (`in(2)` on a `Sum(Num,2)`) or a wrong element type is a **compile error**, and the 8-port ceiling
  is enforced via the index type `u3` ([hub §2](pan_architecture_formalisation.md),
  [type §1](pan_type_and_numeric_model.md)). Heterogeneous `Concat` inputs use the same `PortId`
  mechanism, wired **by name** (§6).
- **`numericFor(cfg.precision, …)` is comptime — and the call site says so.** `cfg.precision` is
  **comptime-known**; `numericFor` is a **comptime switch over the active-precision list** and the
  call site uses the **`comptime` keyword** to make that loud. The consequence, stated up front: a
  desktop precision change requires a **recommit** — there is no runtime precision switching
  ([type §3](pan_type_and_numeric_model.md)).

---

## 4. Feedback / a small reverb — and the error you *want* to hit

Feedback is where pan's "fail loud at commit" personality is most welcome. The rule
([mem §6.1](pan_memory_model.md)): a cycle is legal **iff** its SCC contains a delay. You build a
comb filter by closing a loop through a `DelayLine`. *Illustrative.*

```zig
const delay = try g.add(pan.time.DelayLine(Num), .{ .length_samples = 1789 }); // persistent state
const fb    = try g.add(Gain(Num), .{ .gain = 0.7 });                          // feedback coefficient
const sum   = try g.add(pan.mix.Sum(Num, 2), .{});

try g.connect(src,   sum.in(0));
try g.connect(sum,   delay);
try g.connect(delay, sink);
try g.connect(delay, fb);            // tap the delay output...
try g.connect(fb,    sum.in(1));     // ...back into the summer  => a cycle
```

If you forget the `DelayLine` and wire `sum -> fb -> sum` directly, commit refuses:

```text
error.DelayFreeLoop: strongly-connected component { sum, fb } contains no delay element.
   A feedback cycle must contain at least one z⁻¹ / DelayLine to be causal.
   nodes in cycle: sum (mix.Sum) -> fb (Gain) -> sum
   fix: insert a pan.time.DelayLine or pan.time.UnitDelay on the back-edge.
   see pan_memory_model.md §6.1
```

This is the experience you want: the category-theory underpinning (a *trace* in a traced monoidal
category is only well-defined with the delay guaranteeing causality —
[roadmap §1](pan_categorical_bridge_and_roadmap.md)) surfaces to the user as a plain, actionable
build-time error naming the exact cycle. **No runtime crash, no silent NaN explosion.**

For tight feedback (ladder filters, Karplus-Strong) the default one-block feedback latency is too
coarse. The blessed idiom (now pinned, [mem §6.1](pan_memory_model.md)) is a **fused single-`Map`
kernel**: you author one rate-1:1 `Map` block whose `process` runs the per-sample feedback loop
internally over fixed persistent state — sample-accurate, trading the colorer's block-granularity
(the loop is opaque to the scheduler) for sample-accuracy. ladder/Karplus-Strong/comb ship as such
fused single-block library kernels; the block-size-1 *subgraph* combinator is deferred. Such fused
kernels are typically **not** `aliasing_safe`.

**Ergonomics verdict:** the `DelayLine`-in-the-loop idiom is standard (Web Audio / Max / Pd all
do it) so it transfers. The delay's state being a *pool-excluded persistent buffer* is invisible
to you — you just set `length_samples` — which is exactly right. The friction is conceptual: a
newcomer must learn that a back-edge is split into a write-side (this block) and a read-side
(previous block), so the reverb tail is "one block behind." That's a footnote in the docs and
should be a tutorial chapter.

---

## 5. Parameters & automation — the control plane from the outside

Inside the callback, nothing blocks. So how do you turn a knob? Three mechanisms, none of which
the audio thread can stall on ([io §7](pan_io_realtime_and_pipeline.md)). From the user's seat:

The public control API is **exactly three verbs**, each bound 1:1 to a mechanism — the verb *is* the
contract ([io §7](pan_io_realtime_and_pipeline.md)):

```zig
// 1. set — "move a knob": lock-free atomic + per-block ramp. RT-safe, click-free.
//    NOT sample-accurate by contract (ramped to target by end of buffer). There is no
//    `at_sample` on set, so you CANNOT ask set for sample-accuracy — it's a type-level omission.
gain.set(.gain, 0.5);

// 2. schedule — "automate at a point": SPSC command ring, applied at a sub-block boundary.
//    Sample-accurate at the given sample offset.
engine.schedule(.{ .at_sample = 64, .node = gain, .param = .gain, .value = 0.0 });

// 3. edit -> commit — "rewire": RCU plan swap built off-thread, published at a block boundary.
var edit = engine.beginEdit();
_ = try edit.add(pan.fx.Chorus(Num), .{});
try edit.commit();                      // RCU pointer swap at a block boundary; no audio glitch
```

The thing that will *delight* a systems programmer: continuous parameters ramp automatically.
You don't hand-write a zipper-noise smoother; setting `.gain = 0.5` is understood as "be at 0.5 by
end of buffer," and the engine interpolates ([io §7](pan_io_realtime_and_pipeline.md)). Bypass,
mute, solo, start/stop all ramp too — the pipeline-wide "ramp, never step" policy means you can't
*accidentally* click.

What keeps it un-confusing: the three verbs are not interchangeable *and the verb names which
mechanism you get*. `set` is atomic-scalar + ramp (and **not** sample-accurate by contract);
`schedule` is the SPSC ring (sample-accurate); `edit`→`commit` is RCU topology. The "I expected
`set()` to be sample-accurate" footgun is closed structurally — there is no `at_sample` on `set`, so
asking for sample-accuracy on the wrong verb is a compile error of omission, steering you to
`schedule` ([io §7](pan_io_realtime_and_pipeline.md)).

A genuinely subtle correctness corner the user inherits — now a **named law**, *bypass preserves
latency*: a bypassed block that has latency must **still delay** its signal by exactly its
`algorithmic_latency` ([io §7](pan_io_realtime_and_pipeline.md), [mem §7](pan_memory_model.md)), or
bypassing shifts timing and breaks PDC on parallel paths. Built-in bypass honours it automatically
(routing through the compensating `DelayLine` PDC already inserts); **if you author a custom bypass
you must route through the compensating delay**, and where detectable at commit a latent
bypass-capable block with no compensating path is a commit warning/error.

---

## 6. The analysis path — driving the notes/1.md visualization

This is the brief's headline `examples/` use case ([1.md](../notes/1.md)): a file of audio → spectral /
perceptual features per hop → a collected matrix → a Python 60fps 3D particle viz. It is also the
cleanest demonstration of **clock-driven pull roots** (C5): the analysis graph is its *own* pull
root on a *non-RT thread*, driven by input exhaustion, never slaved to an audio deadline
([exec §6](pan_execution_model.md)).

The graph: file source → `Framer` (Rate) → STFT (Rate) → power → a fan-out into several feature
extractors → `Concat` into one `FeatureFrame` → `FeatureCollectorSink`. *Illustrative.*

```zig
// Non-RT analysis pipeline. No CoreAudio here — the root is driven by input exhaustion.
var g = pan.Graph.init(alloc, .{ .precision = .f32, .sample_rate = 48_000, .channels = .mono });
const Num = pan.numericFor(.f32, .{});

const src   = try g.add(pan.io.LpcmSource(Num), .{ .path = "song.lpcm", .format = .f32le });
const frame = try g.add(Framer(f32, 1024, 256), .{});          // Rate: 1 window / 256 in-samples
const stft  = try g.add(pan.spectral.Stft(Num, 1024), .{ .window = .hann }); // Rate -> Complex spectra
const power = try g.add(pan.spectral.PowerSpectrum(Num), .{}); // Map: []Complex(f32) -> []f32

// fan-out the power spectrum to several reductions (the colorer pins it for the branch span)
const mfcc      = try g.add(pan.feat.Mfcc(Num, 13), .{});           // -> FeatureFrame(13)
const centroid  = try g.add(pan.feat.SpectralCentroid(Num), .{});   // -> Scalar(f32)
const flux      = try g.add(pan.feat.SpectralFlux(Num), .{});       // -> Scalar(f32) (keeps prev-spectrum history)
const dominant  = try g.add(pan.feat.DominantBand(Num), .{});       // -> Scalar(u16) (the viz "color/frequency")
const rms       = try g.add(pan.feat.Rms(Num), .{});                // -> Scalar(f32) (the viz "amplitude 0..1")

// Concat: NAMED heterogeneous typed fan-in. The spec (struct-of name->element-type) IS the column
// order; inputs are wired by name via typed PortIds, so order can't drift and a wrong element type
// is a compile error. collect.Out is the comptime-built struct { mfcc, centroid, flux, dominant, rms }.
const collect = try g.add(pan.combinators.Concat(.{
    .mfcc     = pan.FeatureFrame(13),
    .centroid = pan.Scalar(f32),
    .flux     = pan.Scalar(f32),
    .dominant = pan.Scalar(u16),
    .rms      = pan.Scalar(f32),
}), .{});
const sink = try g.add(pan.io.FeatureCollectorSink(@TypeOf(collect).Out), .{ .capacity_hint = 1 << 16 });

try g.connect(src, frame);
try g.connect(frame, stft);
try g.connect(stft, power);
inline for (.{ mfcc, centroid, flux, dominant, rms }) |node| try g.connect(power, node);
try g.connect(mfcc,     collect.in.mfcc);     // by NAME; compile error if element type mismatches
try g.connect(centroid, collect.in.centroid);
try g.connect(flux,     collect.in.flux);
try g.connect(dominant, collect.in.dominant);
try g.connect(rms,      collect.in.rms);
try g.connect(collect, sink);

var engine = try g.commit();
defer engine.deinit();

// This root is driven by InputExhaustion — pull until the file source signals EOS.
try engine.runToCompletion(.{ .clock = .input_exhaustion });

// Drain the collected time-series and write a matrix for Python.
const matrix = sink.frames(); // []const FeatureFrame, one row per hop
try pan.io.writeFeatureMatrix("features.f32.bin", matrix);
```

And if you want the *same* analysis replicated per channel for a stereo file, you don't rewire —
you wrap the subgraph in the `ChannelMap` combinator, which is a functor `C^(·)` over the subgraph
(pool sizes scale by C, [roadmap §1–§2](pan_categorical_bridge_and_roadmap.md)):

```zig
// Replicate the mono feature subgraph across C channels. (PLAUSIBLE surface for the combinator.)
const Stereo = pan.combinators.ChannelMap(MonoFeatureSub, 2);
const feats = try g.add(Stereo, .{});
```

The Python side reads `features.f32.bin` (one row per 60fps-equivalent hop) and maps columns to
the viz's "Data for every point" schema: `dominant` → color, `rms` → amplitude/size, row index →
emission time, MFCC/centroid → the oscillatory spatial distribution.

**Why this is the satisfying part of pan:** the analysis graph is *the same authoring model* as
the audio graph — same blocks, same connect/commit — but it runs on its own timer-or-exhaustion
root with **zero risk** of stealing an audio deadline. If you later run this analysis *live*
alongside playback, you tap the shared upstream once and fan it to both roots via an SPSC ring;
the expensive feature/viz path **cannot** cause an xrun on the audio path
([exec §6](pan_execution_model.md)). That separation-of-deadlines is the headline design win and
it shows up in the API as "just a different root, same graph."

**Now pinned (was the roughest friction):**
- **`Concat` fan-in is named, not positional.** You pass a **struct-of-(name → element-type)** spec
  and wire inputs **by name** (`collect.in.mfcc`) through typed `PortId`s. The output struct's field
  order **is** the canonical feature-matrix column order — pinned by the same declaration that pins
  the wiring, so a transposed matrix is impossible and a wrong element type is a compile error naming
  the port ([type §1](pan_type_and_numeric_model.md), [roadmap §2](pan_categorical_bridge_and_roadmap.md)).
- **`FeatureCollectorSink` growth is specified.** `capacity_hint` **pre-reserves** rows at
  `initialize` (one up-front allocation); growth past the hint is **geometric (×2)** via the
  unmanaged `ArrayList` per-call allocator — explicitly legal **because this sink lives only on a
  non-RT pull root** (the contained H1 exception). Wiring it onto an RT (audio) root is a **commit
  error** ([roadmap §2](pan_categorical_bridge_and_roadmap.md), [exec §6](pan_execution_model.md)).

---

## 7. Offline render (Tier C) vs real-time (Tier A) — same blocks, different runner

The promise of the architecture is that Tier C is *the same blocks via a different mux*
([exec §5](pan_execution_model.md)). From the user's side it should be a one-line change to the
runner, not a re-author. *Illustrative.*

```zig
// Identical graph construction as §3 — gain -> biquad -> pan — but file->file, offline.
var g = pan.Graph.init(alloc, .{ .precision = .f64, .sample_rate = 96_000, .channels = .stereo });
// ... same add/connect ...
const src  = try g.add(pan.io.LpcmSource(Num), .{ .path = "in.f64.lpcm", .format = .f64le });
const sink = try g.add(pan.io.FileRenderSink(Num), .{ .path = "out.f64.lpcm" });
// ... connect ...

var engine = try g.commit();

// THE ONLY DIFFERENCE: a push runner instead of a clock-driven RT root.
// Latency is irrelevant; throughput rules; blocking is fine (it's the RingSampleMux path).
try engine.renderOffline(.{ .runner = .tier_c_push }); // bit-reproducible, deterministic timeline
```

The same `Gain`/`Biquad`/`ConstantPowerPan` structs you wrote in §1 drive both. On the offline
path the `SampleMux` is the ring-based push mux, threads-per-block and large rings are *fine*
because there's no deadline — and this is exactly where ZigRadio's inherited ring machinery earns
its keep ([hub §2](pan_architecture_formalisation.md)). Notice you can also bump precision to
`f64` for an offline master render where you'd never afford it live; precision being a comptime
parameter makes that a config change, not a code change.

**Ergonomics verdict:** if pan delivers this, it's a quiet superpower — author once, render live or
offline. The risk the docs themselves flag: the `Map`/`Rate` *surface* must not leak between push
and pull, which is why **every block is tested under both muxes** ([roadmap §3](pan_categorical_bridge_and_roadmap.md)).
As a user you mostly benefit from that discipline without seeing it.

---

## 8. Embedded (STM32) — the same code, specialized

The strongest structural claim in the architecture: **the embedded build is a comptime
specialization of the desktop core, not a fork** ([hub §7](pan_architecture_formalisation.md)).
What actually changes from the user's perspective:

```zig
// Embedded: the graph is comptime-fixed, Numeric is fixed-point, memory is static .bss,
// and the DMA ISR is the callback. Tiers B/C do not exist here. (hub §7, io §8)
const Num = pan.Numeric{ .Lane = i16, .Acc = i32, .saturate = true, .W = 1 }; // q15, no FPU

// The whole graph is built and committed AT COMPTIME -> a fully-inlined, vtable-free render fn.
const engine = comptime blk: {
    var g = pan.Graph.initComptime(.{ .precision = .q15, .sample_rate = 48_000, .block_size = N }); // N comptime here!
    const src  = g.add(pan.io.I2sDmaSource(Num, N), .{});
    const gain = g.add(Gain(Num), .{ .gain = 0.8 }); // SAME Gain struct as §1
    const sink = g.add(pan.io.I2sDmaSink(Num, N), .{});
    g.connect(src, gain);
    g.connect(gain, sink);
    break :blk g.commitComptime(); // coloring runs at comptime; footprint is a comptime constant
};

// Static memory: one .bss buffer sized by the comptime footprint formula (mem §10).
var render_memory: [engine.footprint_bytes]u8 align(16) = undefined;

// The render callback IS the I2S DMA half-/full-transfer ISR.
export fn DMA1_Stream0_IRQHandler() callconv(.c) void {
    const rt = pan.realtime.enterRealtimeThread();      // no-op token on fixed-point; SAME API as desktop
    engine.renderInto(rt, &render_memory, dmaHalfBuffer()); // renderInto requires the token; monomorphized, inlined, wait-free
}
```

What's the *same*: the `Gain` struct (literally the §1 code), the connect/commit verbs, the
typed-port machinery, the colored-pool footprint formula. What *collapses*:

- **N becomes comptime** (half the DMA buffer) — so the scalar tail vanishes and kernels fully
  unroll. The C4 runtime-N/comptime-N split pays off as *strictly easier* than desktop.
- **The `SampleMux` vtable becomes a concrete comptime type** → the whole render monomorphizes and
  inlines; the *concept* stays, the *fat pointer* vanishes ([hub §7](pan_architecture_formalisation.md)).
- **`Numeric = {i16, i32, saturate=true, W}`** — and now you see why `Acc` and `saturate` are in
  the *core* trait, not an afterthought: fixed-point is the default path here, and your `Gain`
  kernel's `v * g` must mean "saturating q15 multiply accumulating in i32," which the `Num` type
  supplies. ([type §4](pan_type_and_numeric_model.md))
- **No runtime epochs, no atomic-swap, no Tier B/C**; FTZ is a **no-op realtime token** (N/A for
  fixed-point) but the `enterRealtimeThread()`-gated render entry is the **same API shape** as
  desktop; no off-thread prefetch (files/network don't exist here).

**Ergonomics verdict:** *if* the comptime-graph-build path works as advertised, this is the most
impressive thing about pan — you genuinely write the kernel once. The honest friction: writing
fixed-point kernels is harder than f32 (you must think about Q-format, headroom, saturation), and
that complexity is real regardless of pan. The `comptime blk: { ... }` graph-build is also a place
where Zig comptime error messages can get *deep and ugly* if a block isn't comptime-evaluable — but
the spec now **tests** this rather than asserting it: a CI embedded smoke gate runs `commitComptime()`
inside a `comptime` block in a `ReleaseSmall` build (the build compiling is the discharge of the
obligation for the smoke graph — not a proof for arbitrary graphs; failing to compile is the loud
failure, see [`catalog.md` §8.5](catalog.md)), and a non-comptime-evaluable
block is rejected with a pan-level `comptime_commit_safe` error, not a 40-frame Zig trace
([hub §5 item 6 / §7](pan_architecture_formalisation.md),
[roadmap §5](pan_categorical_bridge_and_roadmap.md)).

---

## 9. Testing your block — gold vectors + dual mux

pan inherits ZigRadio's best habit: tests assert against an **independent mathematical oracle**
(NumPy/SciPy), not against pan's own output ([roadmap §3](pan_categorical_bridge_and_roadmap.md)).
You generate vectors in Python, then assert pan reproduces them *bit-for-bit*. *Illustrative.*

```python
# generate.py — the oracle. Run once; commit the vectors.
import numpy as np, scipy.signal as sps
x = np.random.default_rng(0).standard_normal(4096).astype(np.float32)
b, a = sps.butter(2, 1200/(48000/2), 'low')
y = sps.lfilter(b, a, x).astype(np.float32)
x.tofile("vectors/biquad_lp_in.f32"); y.tofile("vectors/biquad_lp_out.f32")
```

```zig
// The dual-mux discipline: every block is tested under BOTH push and pull. A block that
// passes TestSampleMux (push) but fails PullTestSampleMux (pull) has a surface leak. (exec §8)
test "biquad lowpass matches scipy under both muxes" {
    const in  = @embedFile("vectors/biquad_lp_in.f32");
    const want = @embedFile("vectors/biquad_lp_out.f32");

    inline for (.{ pan.test.TestSampleMux, pan.test.PullTestSampleMux }) |Mux| {
        var blk = pan.filters.Biquad(f32_num, .lowpass){ .cutoff = 1200, .q = 0.707 };
        var mux = Mux.init(in, want.len);
        try pan.test.run(&blk, &mux);
        try mux.expectBitIdentical(want); // exact bytes, not approx — the oracle is truth
    }
}
```

For the colorer there's the **B≡C differential test** ([mem §9](pan_memory_model.md)): run the
whole graph with per-edge double-buffers (mode B) and with the colored pool (mode C) and assert
**bit-identical** output — that test is the **primary correctness check (empirical evidence)** for the
colorer implementation: the coloring *optimality* is the proven theorem
([`catalog.md` §7.2/§7.5](catalog.md)), and the implementation's faithfulness to it is *tested*, not
proven. And a
paranoid mode poisons released buffers to NaN so an aliasing bug surfaces as a NaN, not as a
plausible-but-wrong number.

**Ergonomics verdict:** this is pan's most *trustworthy* surface. `@embedFile` + bit-exact assert
+ the dual-mux `inline for` is about as ergonomic as DSP testing gets, and "test against SciPy,
not against yourself" is the right discipline (Rule 9). The friction is upstream: you need a
Python step in your loop, and bit-exact float comparison across NumPy↔Zig demands care about
accumulation order (the very thing the `Numeric.Acc` field forces you to make explicit). Per Rule
14 the test-writing itself is dispatched to Yoneda test writers at each gate — as a block author
you mostly *consume* this harness.

---

## 10. Observability & the footguns

You cannot run a real-time pipeline blind ([io §10](pan_io_realtime_and_pipeline.md)). From the
user's seat, the things you actually watch:

```zig
const t = engine.telemetry();
std.log.info("xruns={d} headroom={d:.0}% peak_block_us={d:.1} nan_guards_active={}",
    .{ t.xrun_count, t.deadline_headroom * 100, t.peak_block_us, !t.guards_compiled_out });
```

- **xrun / deadline-miss counters** are first-class. If this number is nonzero, you missed a
  deadline and the user heard a click — it is the single most important signal, and it's also the
  gate that *would* enable a future Tier B ([exec §5](pan_execution_model.md)). Watch it.
- **Per-block CPU / deadline headroom** tells you "30% or 95% of budget?" — the knob you turn is
  block size (bigger = more headroom, more latency).
- **Denormal FTZ (the M3 footgun) — now structurally closed.** On a decaying reverb tail, floats
  slip subnormal and *some CPUs are 10–100× slower there* → a sudden CPU spike → xrun *while the
  signal is inaudibly quiet*. pan sets flush-to-zero via a **required realtime-thread token**:
  `enterRealtimeThread()` sets FTZ/DAZ on the calling thread and returns a token, and `renderInto` /
  any custom-worker render entry **won't compile without it** — so a self-spawned DSP worker that
  forgets FTZ is a compile error, not the silent Mixxx-class bug (which shipped full-volume noise on
  Apple Silicon from exactly the ARM64 per-thread, not-inherited FPCR FZ bit;
  [io §3](pan_io_realtime_and_pipeline.md)). On fixed-point it is a uniform no-op token.
- **NaN isolation — surfaced in telemetry.** One NaN (a bad coefficient, a divide-by-zero)
  propagates through the whole summing graph and *persists in feedback state permanently*. In
  Debug/ReleaseSafe pan guards block outputs and a faulting block emits silence + raises a flag
  rather than killing the engine ([exec §7](pan_execution_model.md)). In release the guards compile
  out — but this is no longer silent: telemetry carries **`guards_compiled_out: bool`** (true in
  ReleaseFast/Small, false in Debug/ReleaseSafe), so a one-line read tells you whether NaN protection
  is live. Keep ReleaseSafe in your test matrix.

**Ergonomics verdict:** the telemetry surface is exactly right and the required-token FTZ design is
the kind of hard-won correctness most libraries get wrong. The two formerly-scariest footguns are now
first-class: (a) self-spawned DSP threads without FTZ are a **compile error** (the required token),
and (b) NaN guards compiling out in release is **visible in telemetry** (`guards_compiled_out`) — no
longer silent.

---

## 11. DX scorecard & recommendations

### Where pan is genuinely pleasant

- **Type-signature-is-the-API.** You author a struct with a `process`/`pull` method and you're
  done declaring ports. Nothing to keep in sync. The best inherited idea.
- **`add / connect / commit / start`.** Four verbs, honest meanings. The commit step gives you a
  footprint number *before* you make a sound.
- **Commit-time errors that name the problem.** `error.DelayFreeLoop` naming the exact SCC, the
  "you forgot `algorithmic_latency`" build error — these turn category-theory invariants into
  plain actionable messages. This is the strongest part of the DX.
- **Same blocks across RT / offline / embedded.** Author `Gain` once; run it in a CoreAudio
  callback, a file→file batch, or an STM32 DMA ISR. If this holds up it's a rare achievement.
- **Click-free by default.** Parameters ramp, bypass ramps, you can't accidentally zipper.
- **Test against an independent oracle, under both muxes.** Trustworthy, and ergonomic via
  `@embedFile` + `inline for`.

### Where it imposes ceremony (and whether it's justified)

- **The commit step.** Real ceremony, fully justified — it's the membrane that makes the hot path
  wait-free (H1) and statically bounded (H2). Keep it; it pays for itself.
- **Declaring `algorithmic_latency` / `out_per_in` on every Rate block.** Ceremony, justified —
  PDC and the scheduler recursion are only correct if these are honest, and the build error makes
  forgetting impossible. Keep it.
- **`aliasing_safe` as a correctness assertion.** Renamed from `in_place` so the name telegraphs the
  contract (the author asserts no intra-call read-after-write aliasing hazard) rather than reading as
  a perf flag; the B≡C test quotes the assertion back on a violation. Justified to *have*, now
  honestly *named* (decided: I2).
- **The `Numeric` trait everywhere.** Mild ceremony on desktop (where it's almost always `f32`),
  essential on embedded. Justified, but desktop users pay a small comprehension tax for the
  embedded path's benefit.
- **`Concat` fan-in (now named).** No longer positional: a struct-of-(name → element-type) spec wired
  by name via typed `PortId`s, with the output struct's field order as the canonical column order —
  the former "worst edge" is closed (decided: I1).

### Five recommendations — all now decided and applied in the spec (none violate H1/H2/H3)

1. **`Concat`/fan-in is named, not positional (decided: Option A).** A struct-of-(name →
   element-type) spec wired by name (`collect.in.mfcc`) via typed `PortId`s; the output struct's
   field order is the canonical column order, so tuple/connect order can't diverge and a wrong
   element type is a compile error. Pure commit-time/comptime sugar; fully inside H3
   ([type §1](pan_type_and_numeric_model.md), [roadmap §2](pan_categorical_bridge_and_roadmap.md), §6).
2. **`in_place` renamed to `aliasing_safe` (decided: I2).** `pub const aliasing_safe = true;` names
   the safety assertion (the kernel is free of intra-call read-after-write aliasing hazards), and the
   B≡C/paranoid-mode failure message quotes the assertion back. Comptime-only; no invariant touched
   (§1, [mem §3 / §9](pan_memory_model.md)).
3. **Unified three-verb parameter API (decided: I3).** Exactly `set` (atomic + per-block ramp; **not**
   sample-accurate by contract) / `schedule` (SPSC ring; sample-accurate at an offset) / `edit`→
   `commit` (RCU topology). `set` rejects sample-accuracy at the type level, closing the "I expected
   `set()` to be sample-accurate" footgun ([io §7](pan_io_realtime_and_pipeline.md), §5).
4. **Typed `PortId` + comptime 8-port ceiling (decided: I4).** Port handles are typed (`node.in(i)`),
   minted at comptime from the signature/`Concat` spec, carrying node identity + direction + element
   type; the ceiling is the index type `u3` with a readable `@compileError` past 8. Out-of-range or
   wrong-type connects are *compile* errors. Strengthens H3, zero runtime cost
   ([hub §2](pan_architecture_formalisation.md), [type §1](pan_type_and_numeric_model.md), §3/§6).
5. **FTZ + NaN-guard behaviour are first-class (decided: I5).** `pan.realtime.enterRealtimeThread()`
   sets FTZ/DAZ and returns a **required** token (`renderInto`/custom-worker entry won't compile
   without it; a uniform no-op token on fixed-point), and the telemetry struct carries
   `guards_compiled_out: bool` so a release build can't silently drop NaN protection. One-time
   thread-entry call, so H1 holds ([io §3 / §10](pan_io_realtime_and_pipeline.md), §10).

### Push-back on the architecture where DX cost is high

- **The `Map`/`Rate` split is correct and not softened** — and the spec now ships a *tutorial-grade*
  Map-vs-Rate **decision rule** plus the biquad-vs-`Framer` worked distinction (per-sample state ⇒
  still `Map`; cross-call accumulation / different out-vs-in count / buffer-until-enough ⇒ `Rate`)
  alongside the excellent build error (decided: I8; [exec §2.3](pan_execution_model.md),
  [roadmap §2](pan_categorical_bridge_and_roadmap.md)). The cost is onboarding time, not API soundness.
- **Comptime graph build on embedded — now a tested obligation (decided: I6).** "It's the same code"
  holds only if commit is comptime-evaluable end-to-end; the spec no longer merely asserts this — a
  CI embedded smoke gate runs `commitComptime()` inside a `comptime` block in a `ReleaseSmall` build
  (the build compiling is the discharge of the obligation for the smoke graph — not a proof for
  arbitrary graphs; failing to compile is the loud failure, [`catalog.md` §8.5](catalog.md)), and a
  non-comptime-evaluable block is
  rejected with a pan-level `comptime_commit_safe` error, not a 40-frame Zig trace
  ([hub §5 item 6 / §7](pan_architecture_formalisation.md), [roadmap §3 / §5](pan_categorical_bridge_and_roadmap.md)).
- **Precision-as-comptime + `cfg.precision` — resolved by a loud comptime seam (decided: I7,
  Option B).** Precision stays inside the single `Config` struct (preserving the configuration-driven
  model), but the comptime nature is made loud: the `comptime` keyword is required at the `numericFor`
  call site and a prominent callout states `cfg.precision` is comptime-known, `numericFor` is a
  comptime switch over the active-precision list, and a desktop precision change requires a recommit.
  No `Graph(precision)` type parameter ([type §3](pan_type_and_numeric_model.md)).

**Bottom line:** pan's developer experience is *commit-centric* — almost everything good (loud
errors, static footprint, wait-free hot path, same-code-everywhere) and almost everything
ceremonial (the commit phase, latency declarations, the Numeric trait) flows from making the
author front-load correctness so the hot path can be brainless. That is the right trade for
hard-real-time audio. The friction that was *not* paying for an invariant — positional `Concat`,
the `in_place` naming, the scattered parameter API — has now been resolved in the spec phase (named
`Concat`, `aliasing_safe`, the three-verb control surface) without touching H1/H2/H3.
