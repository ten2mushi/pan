# pan — Concurrency & Memory Ordering (the lock-free control plane, pinned to exact orderings)

> **Status: LOCKED** (2026-06-03; includes the parameter-port amendment, catalog §15 — §3.3 clarifies
> a wired parameter edge is in-graph dataflow, not a control-plane atomic; **then §4a adds the
> intra-render cross-worker ready-flag orderings** for the COMMITTED Tier-B parallel executor — see
> [`pan_parallel_and_offline_execution.md`](pan_parallel_and_offline_execution.md), catalog §8.10/§15). Change-control: conforms to [`catalog.md`](catalog.md); an edit
> that changes a definition or law must update catalog.md and every citing section in the same commit.
> Support document for [`pan_architecture_formalisation.md`](pan_architecture_formalisation.md)
> (the hub). Siblings: [`pan_execution_model.md`](pan_execution_model.md) ·
> [`pan_memory_model.md`](pan_memory_model.md) ·
> [`pan_type_and_numeric_model.md`](pan_type_and_numeric_model.md) ·
> [`pan_io_realtime_and_pipeline.md`](pan_io_realtime_and_pipeline.md) ·
> [`pan_categorical_bridge_and_roadmap.md`](pan_categorical_bridge_and_roadmap.md).
> Defined terms resolve to [`catalog.md`](catalog.md) — the single source of truth (read first).
>
> Scope: the **memory-ordering contract** of the three control verbs `set` / `schedule` / `edit`→`commit`
> ([`catalog.md` §10](catalog.md)). This document pins the *exact* Zig 0.16.0 atomic operations and
> their `std.builtin.AtomicOrder` arguments for each mechanism, and gives the wait-freedom argument for
> the RT thread (H1, [`catalog.md` §11](catalog.md)). It is the precise, implementation-ready form of
> the conceptual control plane sketched in
> [`pan_io_realtime_and_pipeline.md` §7](pan_io_realtime_and_pipeline.md) — that section is the *why*;
> this is the *how, to the ordering*.

---

## 0. The two threads and the single rule

There are exactly two thread roles in scope, and the whole document is about the handoff between them:

- **RT thread (the consumer).** The thread that owns the `AudioDeviceCallback` `PullRoot`
  ([`catalog.md` §8.3](catalog.md)). It replays the render op-list under a hard `N/Fs` deadline. It
  holds the realtime token ([`catalog.md` §10](catalog.md),
  [`pan_io_realtime_and_pipeline.md` §3](pan_io_realtime_and_pipeline.md)). **It must never block, lock,
  allocate, or syscall** (H1).
- **Control thread (the producer / writer).** A single non-RT thread that originates all control-plane
  mutations: knob moves (`set`), scheduled events (`schedule`), and topology edits (`edit`→`commit`).
  It may block, allocate, and spin freely — it never holds the RT thread up.

> **A third role under the COMMITTED Tier-B executor (§4a):** the **render workers**. When
> RealtimeStreaming runs on multiple cores ([`catalog.md` §8.10](catalog.md)), the RT *render* is
> performed by a small pool of pre-spawned workers co-scheduled in the OS audio workgroup, with the
> callback thread as worker 0. This adds **intra-render** cross-worker handoff (a single-writer
> release/acquire **ready-flag**, §4a) — distinct from, and not interacting with, the control-plane
> handoff above. The §1–§5 control-plane contract is unchanged; §4a adds the render-side ordering.

> **The single rule.** All cross-thread cost is paid on the control thread. The RT thread only ever
> *reads what has already been published* and *acknowledges* (bumps an epoch). Every ordering choice
> below is the minimum that makes a control-thread *publish* visible to the RT thread's *consume*
> without a lock.

---

## 1. Producer model — SPSC, single designated control thread (LOCKED)

**Decision (LOCKED by user): the core control plane is Single-Producer / Single-Consumer (SPSC).**
Exactly **one** designated control thread feeds the command ring and performs plan commits; the RT
thread is the lone consumer. SPSC is the entire reason the control plane is **fully wait-free with no
CAS**: with one producer and one consumer, each index has a single writer, so a plain
load/store pair with the right acquire/release ordering is sufficient — there is no contended
read-modify-write, hence no retry loop, hence no unbounded work.

> **MPSC was considered and rejected for the core.** A multi-producer ring would require a CAS-based
> tail reservation (a `@cmpxchgWeak` retry loop) on the producers. That CAS loop is fine *off* the RT
> thread, but it is needless mechanism for pan: the cleaner answer is to keep the core SPSC and push
> multi-source fan-in up to the application as an explicit **funnel**.

### 1.1 The funnel pattern (apps with multiple UI / automation sources)

An app with several mutation sources — a GUI thread, a MIDI-input thread, an OSC/automation thread —
**must funnel them through the one designated control thread** before they touch the engine. Two
sanctioned funnel shapes, in order of preference:

1. **Own the control thread.** Spawn one control thread; every source posts its intent to a
   per-source MPSC mailbox (or one app-level `std.Io.Mutex`-guarded queue — this is a *non-RT* lock,
   which is allowed), and the control thread is the only caller of `engine.set` / `engine.schedule` /
   `engine.commit`. The lock contention is entirely off the RT path.
2. **Serialize onto an existing UI thread.** If the app already has a single UI/event thread, designate
   *it* as the control thread and marshal the MIDI/automation sources onto it with the framework's
   normal cross-thread post mechanism.

The contract the engine enforces by construction is narrow and exact: **the engine assumes exactly one
thread calls its mutating control API.** Calling the mutating API from two threads concurrently is a
data race on the producer-owned `tail` (and on the writer side of the RCU swap) — **unchecked Illegal
Behavior** in Zig ([`03-safety.md` §11], no build mode panics on it). The funnel is therefore a **▷
conventional obligation** of the application; pan does not (and with SPSC cannot cheaply) police it on
the hot path. Document it loudly; test it with a ThreadSanitizer build of the app
(`-fsanitize-thread`).

---

## 2. The SPSC command ring — the `schedule` verb

`schedule` ([`catalog.md` §10](catalog.md)) enqueues a time-stamped, sample-accurate event
(`{ at_sample, node, param, value }`, the VST3/CLAP `(sample_offset, event)` shape,
[`catalog.md` §8.6](catalog.md)) into a bounded ring. The RT thread drains the ring at each callback /
sub-block boundary and applies each event at its sample offset.

### 2.1 Structure — power-of-two, masked indices, cache-line padded

```zig
const std = @import("std");

/// SPSC command ring. capacity MUST be a power of two so index→slot is a mask, not a modulo.
/// head is owned by the consumer (RT thread); tail is owned by the producer (control thread).
pub fn CommandRing(comptime Cmd: type, comptime capacity: usize) type {
    comptime std.debug.assert(std.math.isPowerOfTwo(capacity));
    return struct {
        const Self = @This();
        const mask = capacity - 1;

        // Pad head and tail onto SEPARATE cache lines to avoid false sharing: the consumer
        // writes `head` every drain and the producer writes `tail` every enqueue; if they shared
        // a line each write would ping-pong the other core's cache. (std.atomic.cache_line is the
        // target's cache-line size, verified present in std 0.16.0.)
        head: std.atomic.Value(usize) align(std.atomic.cache_line) = .init(0), // consumer-owned
        tail: std.atomic.Value(usize) align(std.atomic.cache_line) = .init(0), // producer-owned
        slots: [capacity]Cmd = undefined,

        pub const empty: Self = .{};
    };
}
```

Indices are **free-running** `usize` counters; the slot is `index & mask`. The number of live entries
is `tail - head` (wrapping subtraction is fine on `usize` because both grow monotonically and never
differ by more than `capacity`). The ring is **full** when `tail - head == capacity`, **empty** when
`tail == head`.

### 2.2 Producer enqueue (control thread, NON-RT) — may spin, never blocks the RT thread

```zig
/// Returns false if the ring is full. NON-RT: the caller may spin/backoff/retry.
pub fn enqueue(self: *Self, cmd: Cmd) bool {
    const tail = self.tail.load(.monotonic);   // (P1) own index: relaxed, we are its only writer
    const head = self.head.load(.acquire);     // (P2) observe space the consumer has freed
    if (tail - head == capacity) return false; // ring full
    self.slots[tail & mask] = cmd;             // (P3) write payload into the slot
    self.tail.store(tail + 1, .release);       // (P4) PUBLISH: release so the consumer's acquire
                                               //      load of tail sees the slot write (P3)
    return true;
}
```

Exact orderings and *why*:

- **(P1) `self.tail` load `.monotonic` (relaxed).** The producer is the *only* writer of `tail`; it is
  reading back its own last value. No cross-thread ordering is needed for it — relaxed is correct and
  cheapest.
- **(P2) `self.head` load `.acquire`.** This observes how far the consumer has advanced `head`, i.e.
  which slots are free. The `.acquire` pairs with the consumer's `.release` store of `head` (C4): once
  we see the new `head`, we are guaranteed the consumer has *finished reading* the slots it freed, so
  reusing those slots cannot race the consumer's read.
- **(P3) slot write — plain (non-atomic) store.** Ordinary write into `slots[tail & mask]`. It is made
  visible to the consumer by the release in (P4); no per-field atomic is needed.
- **(P4) `self.tail` store `.release`.** The **publish**. Release ordering guarantees every prior write
  in program order — crucially the slot payload (P3) — is visible to any thread that performs an
  `.acquire` load of `tail` and sees this new value. This is the half of the release/acquire pair that
  makes the payload safe to read on the other side (C2).

**Ring-full policy.** When `enqueue` returns `false`, the producer is on the **non-RT control thread**,
so it may **spin / back off / retry** at its leisure (or drop / coalesce, an app policy). It **never**
blocks, signals, or otherwise stalls the RT thread — the RT thread is not even aware the producer is
waiting. This is the asymmetry that keeps H1 intact: backpressure is absorbed entirely on the
non-RT side.

### 2.3 Consumer drain (RT thread) — bounded, wait-free

Called once per callback and again at each sub-block boundary ([`catalog.md` §8.6](catalog.md)):

```zig
/// RT thread. Drains every command currently present, in order. WAIT-FREE.
pub fn drain(self: *Self, ctx: anytype) void {
    var head = self.head.load(.monotonic);  // (C1) own index: relaxed, we are its only writer
    const tail = self.tail.load(.acquire);  // (C2) observe PUBLISHED payloads (pairs with P4)
    while (head != tail) {                  //      bound: at most `capacity` iterations, ever
        const cmd = self.slots[head & mask]; // (C3) read payload made visible by C2's acquire
        ctx.apply(cmd);
        head += 1;
    }
    self.head.store(head, .release);        // (C4) FREE the slots (pairs with P2)
}
```

Exact orderings and *why*:

- **(C1) `self.head` load `.monotonic`.** The consumer is the only writer of `head`; reading its own
  value needs no cross-thread ordering. Relaxed.
- **(C2) `self.tail` load `.acquire`.** Pairs with the producer's `.release` store (P4). Seeing the new
  `tail` value guarantees the matching slot payloads (P3) are visible — so the slot reads in (C3) are
  not a race.
- **(C3) slot read — plain (non-atomic) load.** Safe because (C2)'s acquire ordered it after the
  producer's payload write.
- **(C4) `self.head` store `.release`.** Pairs with the producer's `.acquire` load (P2). Publishing the
  advanced `head` *after* the slot reads guarantees the producer will not reuse a slot until we are done
  reading it.

**Wait-freedom (the load-bearing property).** `drain` reads `tail` **once** and loops over exactly the
entries present at that instant — **at most `capacity` iterations** (a compile-time constant). It does
**not** re-load `tail` to chase newly-arrived commands, and it does **not** wait for anything. Commands
that arrive *during* the drain are simply picked up at the next boundary. There is **no CAS, no retry
loop, no spin** on the consumer side. This is ⊢ wait-free *by the shape of the code* (a fixed-bound
counted loop with no backward dependence on a contended write); see §5.

### 2.4 Sample-accuracy and the boundary

`schedule` is **sample-accurate** ([`catalog.md` §10](catalog.md)): each command carries `at_sample`,
and the RT thread renders sub-blocks bounded by those offsets ([`catalog.md` §8.6](catalog.md)),
applying the command exactly at its offset. The *ring* delivers the command before its boundary;
the *sub-block scheduler* places it at the exact sample. (Contrast `set`, §3, which is explicitly
**not** sample-accurate.)

---

## 3. Atomic scalar parameters — the `set` verb

`set` ([`catalog.md` §10](catalog.md)) moves a continuous knob (gain, cutoff). Mechanism: a lone atomic
scalar holding the **target**, plus a per-block ramp on the RT side toward that target.

```zig
// Control thread — publish a new target. One word, monotonic is sufficient (see below).
pub fn set(p: *std.atomic.Value(f32), target: f32) void {
    p.store(target, .monotonic);
}

// RT thread, once per block — read the target, then ramp the live value toward it across N frames.
fn rampTowardTarget(live: *f32, p: *const std.atomic.Value(f32), n: usize) void {
    const target = p.load(.monotonic);
    // ... per-block linear/one-pole ramp of `live` toward `target` over `n` frames (anti-zipper) ...
    _ = .{ live, target, n };
}
```

Equivalently with the raw builtins the verbs ultimately lower to:
`@atomicStore(f32, &p, target, .monotonic)` / `@atomicLoad(f32, &p, .monotonic)`.

### 3.1 Why `.monotonic` (relaxed) is sufficient — and correct — for a lone scalar

`.monotonic` gives exactly two guarantees, and a lone scalar parameter needs exactly those two and **no
more**:

1. **Atomicity / no torn read.** The store and the load are indivisible: the RT thread reads either the
   old target or the new one, never a half-written `f32`. (A plain non-atomic store racing a plain load
   would be a data race — unchecked IB.)
2. **Eventual visibility.** A relaxed store becomes visible to the relaxed load in finite time; the RT
   thread will pick up the new target on this block or a subsequent one.

What `.monotonic` does **not** provide — cross-thread ordering of *other* memory relative to this
store — is **not needed here**, because **there is no dependent data to order against.** The scalar is
self-contained: its value carries no pointer to a payload that must be initialized-before-published
(that is the ring's job, §2, and the RCU pointer's job, §4, both of which *do* need release/acquire).
A gain target of `0.5` means `0.5` no matter what else the writer did. With nothing to order against,
acquire/release would be paying for a fence that guards nothing — so relaxed is both correct and the
right choice (the skill's guidance: "pick the weakest order that is correct"; `.monotonic` is fine for
independent counters/flags, [`03-safety.md` §11]).

### 3.2 Not sample-accurate — by contract

`set` is **wait-free and click-free but NOT sample-accurate** ([`catalog.md` §10](catalog.md), law A7).
The new target is reached by the **end of the block** via the ramp, not at a caller-named sample. There
is deliberately **no `at_sample` parameter on `set`** — its omission is a ⊢ compile error of intent
(sample-accurate intent is only expressible on `schedule`, §2). The ordering choice here is consistent
with that contract: a relaxed store has no defined sample-position semantics, and none is promised.

### 3.3 The in-graph alternative — a wired parameter edge (not a control-plane mechanism)

The same parameter slot may instead be driven *from inside the graph* by a **parameter edge**
([`catalog.md` §2.4](catalog.md)) — another node's control-rate output wired into `node.param.<name>`.
This is **out of scope for this document's atomics contract**: a parameter edge is **in-graph
dataflow** rendered within the single RT pass (colored, scheduled, read with ordinary loads — no
cross-thread atomic, SPSC ring, or RCU involved). It applies the *same* per-block ramp as `set` (P3),
sourcing the target from the edge each call. A slot has **one source** — `set`/`schedule` **xor** a
wired edge (catalog §2.4 P2). So the three verbs here remain the **only** cross-thread control
mechanisms; the wired-edge variant adds no new concurrency primitive.

---

## 4. RCU plan swap — the `edit`→`commit` verb

`edit`→`commit` ([`catalog.md` §10](catalog.md)) rewires topology. It publishes a **new immutable Plan**
(the render op-list + pool sizing + buffer-id assignment, [`catalog.md` §8.2](catalog.md)) built
entirely off-thread, then swaps a single atomic pointer. This is classic **RCU** (read-copy-update):
many fast readers (the RT thread, once per callback), one slow writer (the control thread).

### 4.1 The shared state

```zig
const Plan = @import("plan.zig").Plan; // immutable once committed

const Engine = struct {
    /// The currently-active plan. RT thread reads it; control thread swaps it.
    plan: std.atomic.Value(*const Plan),
    /// Quiescent-state epoch: the RT thread bumps it at the start of every callback.
    epoch: std.atomic.Value(u64) align(std.atomic.cache_line) = .init(0),
};
```

### 4.2 Publish (control thread) — build fully, then one release store

```zig
/// Control thread. `new_plan` is FULLY constructed and immutable before this is called.
pub fn commitPlan(eng: *Engine, new_plan: *const Plan) *const Plan {
    const old = eng.plan.load(.monotonic);   // own-side read of current pointer (relaxed)
    eng.plan.store(new_plan, .release);       // (W) PUBLISH the pointer with RELEASE
    return old;                               // caller proceeds to reclaim `old` (§4.4)
}
```

- **(W) `plan.store(new_plan, .release)`.** Release ordering guarantees that every write that built
  `new_plan` (ops array, buffer-id tables, pool sizes, persistent-state handoff) is visible to any
  thread that performs an `.acquire` load of the pointer and sees `new_plan`. The new plan is
  **immutable** after this point; the writer never touches it again.

### 4.3 Consume (RT thread) — one acquire load per callback, used for the whole callback

```zig
/// RT thread, at callback start.
fn callback(eng: *Engine, frames: usize) void {
    _ = eng.epoch.fetchAdd(1, .acq_rel);          // (E) announce a new quiescent period (§4.4)
    const plan = eng.plan.load(.acquire);          // (R) ONE acquire load; pairs with (W)
    // ... replay `plan.ops` for the ENTIRE callback. Do NOT re-load the pointer mid-callback. ...
    _ = .{ plan, frames };
}
```

- **(R) `plan.load(.acquire)`.** Pairs with (W)'s release. Seeing `new_plan` guarantees the RT thread
  sees the **fully-initialized** plan — release/acquire is precisely the "publish a pointer to data you
  finished writing" idiom. The RT thread loads the pointer **exactly once** at callback start and uses
  that same plan for the whole callback, so a swap that happens mid-callback never tears a render: the
  callback either runs entirely on the old plan or entirely on the new one. This is the **block-boundary
  publish** contract ([`catalog.md` §10](catalog.md): "published at a block boundary").

### 4.4 Reclamation — quiescent-state RCU via the epoch counter

The writer cannot free the old plan immediately: an in-flight callback may still be reading it through
its (R) load. pan uses **quiescent-state RCU**, with the callback boundary as the quiescent state.

- **(E) RT thread** bumps `epoch` with `@atomicRmw(.Add)` (`fetchAdd`, `.acq_rel`) at the **start of
  every callback**. A callback that observes epoch value `e` runs entirely "within generation `e`."
- **Writer** records the epoch around the swap and frees the old plan only after the epoch has
  **advanced past** the swap — i.e. after at least one full callback has begun *and ended* since the
  swap, guaranteeing no callback is still holding the old pointer:

```zig
/// Control thread, AFTER commitPlan returned `old`. NON-RT: it may block/sleep/spin freely.
pub fn reclaimOldPlan(eng: *Engine, old: *const Plan, allocator: std.mem.Allocator) void {
    const at_swap = eng.epoch.load(.acquire);          // epoch as of (just after) the swap
    // Wait until the RT thread has STARTED a callback strictly later than the swap AND that
    // callback has finished. One epoch tick guarantees a boundary was crossed; to be sure the
    // reader that may have grabbed `old` has drained, wait for the epoch to advance, then for the
    // next boundary. Two observed increments bound it conservatively.
    while (eng.epoch.load(.acquire) < at_swap + 2) {
        std.Thread.yield() catch {};                    // NON-RT spin/yield; never on the RT thread
    }
    old.deinit(allocator);                              // safe: no callback can still hold `old`
}
```

Rationale for `+2` (conservative, single-writer): the callback that may have loaded `old` started at
some epoch `≤ at_swap`. Once we observe `epoch ≥ at_swap + 1`, a strictly later callback has *begun*
(so any reader of `old` belongs to a callback that began at `≤ at_swap`); once we observe
`at_swap + 2`, that later callback boundary has also been crossed, so every callback that could have
read `old` has run to completion. Waiting two ticks is the simplest bound that is obviously correct; a
tighter "remember the exact reader generation" scheme is possible but unnecessary at pan's swap rates.

- **`.acq_rel` on (E)** is used because the epoch bump is a read-modify-write that both *acknowledges*
  the prior generation (acquire side) and *announces* the new one (release side) to the writer's
  `.acquire` loads. `.acquire` on the writer's `epoch.load` pairs with it.

### 4.5 Single writer ⇒ no ABA, no hazard pointers

Because there is exactly **one** writer (the SPSC producer / control thread, §1), only one plan swap is
ever in flight at a time and the plan pointer is only ever stored by that one thread. There is therefore
**no ABA problem** (the classic CAS hazard where a pointer cycles A→B→A under a reader) — the RT thread
never does a CAS on the pointer, it only loads it; and the single writer serializes all swaps. **No
hazard pointers and no CAS are needed.** The epoch counter alone is sufficient grace-period detection.
This is the direct payoff of the SPSC decision (§1).

### 4.6 Persistent state across the swap (click-free)

Delay-line / overlap-ring / history buffers are the **pool-excluded persistent category**
([`catalog.md` §5.3](catalog.md)); they outlive any single plan. On a plan swap the new plan must
**hand off or ramp** this state rather than reset it, or the swap clicks:

- **Hand off** — where the topology of a persistent node is unchanged across the edit, the new plan
  reuses the *same* persistent buffer (the pointer is carried into the new plan during off-thread build,
  before publish). No audio discontinuity.
- **Ramp** — where a node appears/disappears/changes (bypass, replaced filter), the transition is
  ramped, never stepped ([`catalog.md` §10](catalog.md) transition policy;
  [`pan_io_realtime_and_pipeline.md` §7](pan_io_realtime_and_pipeline.md)). The *bypass-preserves-latency*
  law ([`catalog.md` §10](catalog.md)) applies: a bypassed latent block still routes through its
  compensating `DelayLine`.

This handoff happens during the off-thread build (before (W)), so it costs the RT thread nothing.

---

## 4a. Intra-render cross-worker synchronization — the Tier-B ready-flag (COMMITTED 2026-06-03)

Under the static-parallel executor ([`catalog.md` §8.10](catalog.md);
[`pan_parallel_and_offline_execution.md` §2.4](pan_parallel_and_offline_execution.md)), each render op
runs on exactly one worker per callback (the static HEFT schedule). Same-worker dependencies are
implicit in the worker's op sequence (no sync). A **cross-worker** dependency uses one release/acquire
flag per producing op, keyed by the per-callback **generation** `g` (bumped once by worker 0 at
callback start, after the RCU `plan.load`):

```zig
// Producer worker, on finishing op `p`:  (single writer of ready[p] this callback ⇒ no CAS)
ready[p].store(g, .release);                     // (RF-W) PUBLISH: release orders p's pool-buffer
                                                 //        writes before any acquirer that sees g
// Consumer worker, before starting op `c`, for each cross-worker predecessor `p`:
while (ready[p].load(.acquire) != g) std.atomic.spinLoopHint(); // (RF-R) pairs with RF-W
```

- **(RF-W) `.release` store / (RF-R) `.acquire` load** — the identical "publish a pointer/flag to data
  you finished writing" idiom as the RCU swap (§4, W/R): seeing `g` guarantees the producer's output
  buffer writes are visible, so the consumer's plain reads of that buffer are not a race.
- **No CAS.** Each `ready[p]` has exactly **one writer** (the worker owning op `p` this callback), so a
  plain release store suffices — the same single-writer property that keeps the SPSC ring (§2) and the
  RCU pointer (§4.5) CAS-free, now applied per op. (This is why the work-stealing alternative — which
  *does* require CAS on the steal path — was rejected for the RT executor.)
- **Generation `g`** avoids a per-callback memset of the flag array: a flag still holding `g−1` reads as
  "not ready." `g` is monotone `usize`.
- **Bounded spin (RF-R) — the honest ▷/≈ bound.** The spin terminates within the producer's WCET
  **only while the OS honours workgroup co-scheduling** (the producer is not descheduled while the
  consumer spins). This is **▷/≈**, the same honesty class as FTZ ([`catalog.md` §10](catalog.md)) — a
  strong structural nudge, not a proof — and is **strictly weaker** than Tier A's structural
  wait-freedom (Tier A has no spin). It is backed ≈ by per-worker spin-time / deadline-headroom
  telemetry and the **auto-demote to Tier A** ([`catalog.md` §8.10](catalog.md)). The cost-model gate
  refuses Tier B entirely if no workgroup is available.

> **Why this is not in the §5 ⊢ column the way §2–§4 are.** The control-plane primitives (§2–§4) are
> ⊢ wait-free *by code shape* (single ops or fixed-bound counted loops with no contended backward
> dependence). The Tier-B ready-flag spin (RF-R) is a loop whose bound depends on the *scheduler*
> honouring the workgroup — hence ▷/≈, not ⊢. §5's table is for the always-on control plane; this row
> applies only when Tier B is enabled.

## 5. Wait-freedom of the RT thread (H1) — the argument

H1 ([`catalog.md` §11.1](catalog.md)): *no unbounded blocking on the audio thread; for one callback the
render path is wait-free.* The control-plane primitives above contribute the following to the RT
thread, and **every one is bounded with no RT-side loop on a contended write**:

| RT-thread operation (per callback) | Atomic ops | Bound | Tier |
|---|---|---|---|
| Plan consume (§4.3) | one `plan.load(.acquire)` | O(1) | **⊢** (single load, no loop) |
| Epoch bump (§4.4) | one `epoch.fetchAdd(.acq_rel)` | O(1) | **⊢** (single RMW, hardware-atomic, no software retry) |
| Command drain (§2.3) | `head` load + `tail` load + ≤`capacity` slot reads + `head` store | ≤ `capacity` (compile-time const) | **⊢** (counted loop, fixed bound, no `tail` re-read) |
| Scalar reads (§3) | one `@atomicLoad(.monotonic)` per `set` param | O(#params), bounded by the committed plan | **⊢** (single load each) |
| Op-list replay | — | bounded by `plan.ops.len` (fixed at commit) | **⊢** ([`catalog.md` §8.2](catalog.md)) |

**The decisive structural facts:**

1. **No CAS-retry loop ever runs on the RT thread.** The only place a CAS *could* live is the producer
   side, and SPSC (§1) eliminates it even there. The RT thread does loads, one RMW counter bump (which
   is a single hardware-atomic instruction, not a software retry loop), plain memory reads/writes, and
   one release store of `head`. None of these can spin.
2. **Every loop on the RT thread has a compile-time-fixed bound** — the drain is `≤ capacity`, the
   replay is `plan.ops.len`. No RT-thread loop's iteration count depends on what another thread is
   *currently* doing (the drain reads `tail` once and ignores later arrivals; §2.3).
3. **The asymmetry is the whole design.** All waiting — ring-full backpressure (§2.2), grace-period
   reclamation (§4.4) — is pushed onto the **non-RT control thread**, which is allowed to spin/yield.

Therefore:

> **⊢ (proven-by-construction):** the *memory-ordering protocols* of §2–§4 introduce **no unbounded or
> contended RT-side loop**. Each RT-side primitive is a single atomic op or a fixed-bound counted loop;
> wait-freedom of these primitives follows from the *shape of the code* and does not depend on runtime
> contention. (This is the part H1 can claim structurally.)
>
> **▷ (conventional, authoring obligation):** that **no block body, no `apply`, and no plan-consume
> path introduces a lock, allocation, syscall, or page fault** remains author discipline — *no Zig type
> forbids `malloc` in `process`* ([`catalog.md` §11.1](catalog.md), H1). The protocols here are
> wait-free; whether the code *placed inside* them stays wait-free is the ▷ part.
>
> **≈ (tested):** wait-freedom *in practice* is checked by xrun / deadline-miss counters
> ([`pan_io_realtime_and_pipeline.md` §10](pan_io_realtime_and_pipeline.md)) and by ThreadSanitizer
> runs of the SPSC ring and RCU swap under concurrent producer/consumer load
> ([`catalog.md` §12.2](catalog.md), B7; [`03-safety.md` §12], `-fsanitize-thread`).

The honest split mirrors [`catalog.md` §11.1](catalog.md) exactly: *the architecture exists to
guarantee H1; the ordering protocol is the ⊢ structural half, no-malloc-discipline is the ▷ half,
xrun counters are the ≈ half.*

---

## 6. Zig 0.16.0 atomics reference (verified against the toolchain)

> **Verification.** Every API name and `AtomicOrder` value below was compiled and run under
> `zig version` **0.16.0** (a `zig test` exercising the ring, the RCU pointer publish/consume, the
> epoch RMW, all six order values, `std.atomic.cache_line`, and the raw builtins passed). Where this
> document and older tutorials disagree, **this is the 0.16.0-true form.**

### 6.1 The raw builtins

| Builtin | Signature shape | Use in this doc |
|---|---|---|
| `@atomicLoad(comptime T, ptr, comptime order)` | `T` | scalar read (§3), what `Value.load` lowers to |
| `@atomicStore(comptime T, ptr, value, comptime order)` | `void` | scalar/pointer publish (§3, §4) |
| `@atomicRmw(comptime T, ptr, comptime op, operand, comptime order)` | `T` (old value) | epoch bump (§4.4); `op` is an `AtomicRmwOp` enum, **capitalized** (`.Add`, `.Sub`, `.Xchg`, `.And`, `.Or`, `.Xor`, `.Max`, `.Min`, …) — note the capitalization, a 0.16 gotcha |
| `@cmpxchgWeak(comptime T, ptr, expected, new, comptime success, comptime fail)` | `?T` (null on success) | **not used on the RT thread**; only a *non-RT* MPSC funnel (§1.1) would use it |
| `@cmpxchgStrong(comptime T, ptr, expected, new, comptime success, comptime fail)` | `?T` | same — off-RT only |

`@cmpxchg*` take **two** order arguments: the success order and the (no-weaker-than) failure order.

### 6.2 `std.builtin.AtomicOrder` — the six values

```zig
pub const AtomicOrder = enum { unordered, monotonic, acquire, release, acq_rel, seq_cst };
```

| Value | Meaning | Where pan uses it |
|---|---|---|
| `.unordered` | atomic, no ordering at all (torn-free only) | not used (pan's relaxed reads want `.monotonic`) |
| `.monotonic` | relaxed: atomicity + eventual visibility, no fence | own-index reads (P1, C1), scalar `set`/load (§3) |
| `.acquire` | a consume-side fence: prior-to-publish writes become visible | `head`/`tail`/`plan` consume loads (P2, C2, R), epoch reads |
| `.release` | a publish-side fence: makes prior writes visible to an acquirer | `tail`/`head`/`plan` publish stores (P4, C4, W) |
| `.acq_rel` | both, for a read-modify-write | epoch `fetchAdd` (E) |
| `.seq_cst` | total global order; the safe-but-slow default | not needed here — every pairing is a clean release/acquire handoff |

> **Naming note (0.16):** the values are lowercase/snake (`.acq_rel`, `.seq_cst`), not the older
> `.AcqRel`/`.SeqCst`. Verified.

### 6.3 `std.atomic.Value(T)` — the preferred wrapper

pan prefers `std.atomic.Value(T)` over the bare builtins: it is a typed, harder-to-misuse wrapper
([`03-safety.md` §11]). Methods used here:

```zig
pub fn init(value: T) Value(T);
pub fn load(self: *const Value(T), comptime order: AtomicOrder) T;
pub fn store(self: *Value(T), value: T, comptime order: AtomicOrder) void;
pub fn fetchAdd(self: *Value(T), operand: T, comptime order: AtomicOrder) T; // → @atomicRmw(.Add)
// also: swap, cmpxchgWeak/Strong, fetchSub/And/Or/Xor/Min/Max, bitSet/bitReset/bitToggle
```

Decl-literal init: `var epoch: std.atomic.Value(u64) = .init(0);`.

### 6.4 `std.atomic.cache_line`

`std.atomic.cache_line` is a `comptime_int` — the target's assumed cache-line size — used as the
`align(...)` on the ring's `head`/`tail` and the engine's `epoch` to **prevent false sharing** (§2.1).
Verified present and usable as an alignment in 0.16.0.

---

## 7. What the spec must pin down here

- **The SPSC decision and the funnel (§1).** Core is single-producer/single-consumer → fully wait-free,
  no CAS; multi-source apps funnel through one designated control thread (a ▷ obligation, ThreadSanitizer
  the only enforcement). MPSC rejected for the core.
- **The exact ring orderings (§2).** Producer: `tail` `.monotonic` / `head` `.acquire` / slot write /
  `tail` `.release`. Consumer: `head` `.monotonic` / `tail` `.acquire` / slot reads / `head` `.release`.
  Power-of-two masked indices; `head`/`tail` on separate cache lines via `std.atomic.cache_line`;
  ring-full backpressure absorbed off-RT; drain bounded by `capacity` (⊢ wait-free).
- **The scalar ordering (§3).** `set` uses `.monotonic` store / load — justified because a lone scalar
  has atomicity + eventual-visibility needs and **no dependent data to order against**. Not
  sample-accurate by contract (A7).
- **The RCU protocol (§4).** Build off-thread → `plan.store(.release)`; RT does one
  `plan.load(.acquire)` at callback start for the whole callback; reclamation via a quiescent-state
  **epoch** bumped `.acq_rel` by the RT thread and read `.acquire` by the single writer, freeing the old
  plan only after the epoch advances past the swap. Single writer ⇒ no ABA, no hazard pointers. Persistent
  state handed off or ramped across the swap.
- **The H1 wait-freedom argument (§5).** Every RT-side primitive is a single atomic op or a fixed-bound
  counted loop; no CAS-retry ever runs on the RT thread; ⊢ for the protocol shape, ▷ for no-malloc
  discipline, ≈ for xrun-counter evidence.
- **The Zig 0.16.0 atomics surface (§6).** Builtins, the six `AtomicOrder` values, `std.atomic.Value`,
  `std.atomic.cache_line` — verified by compiling against 0.16.0.

> **Tie-off.** This document is the memory-ordering realization of the three control verbs of
> [`catalog.md` §10](catalog.md): **`set`** = `.monotonic` atomic scalar + ramp (§3); **`schedule`** =
> SPSC release/acquire ring (§2); **`edit`→`commit`** = release/acquire RCU pointer swap with
> epoch-based quiescent reclamation (§4). All three are wait-free on the RT thread by construction (§5),
> discharging the structural half of **H1** ([`catalog.md` §11.1](catalog.md)).

---

*Locked 2026-06-03 as a support document under the specification-locking pass. Author: Claude (Opus 4.8)
via Claude Code; the `zig-0-16` skill was loaded and every Zig atomic form was verified by compiling and
running a `zig test` against `zig version` 0.16.0.*
