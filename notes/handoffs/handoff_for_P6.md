# Handoff — end of Session 5 (P5 "Format negotiation + lock-free control plane + runtime Engine") → into P6

> **Status:** P0–P4 + **P5 implemented, full-surface, and green**. This is an advisory handoff, not a
> spec: the `specifications/` corpus and `pan_implementation_plan.md` remain the source of truth.
> **Date:** 2026-06-03. **Toolchain:** `zig 0.16.0` (re-run `zig version` at P6 start — Rule 13).
> Session was scoped P5+P11 in the bundling note; **only P5 landed** (P11 = the modulation *blocks*
> that consume P5's param ports; it is **unblocked, not a blocker** — see §7). P5's full surface was
> closed in two passes and **independently audited** (a fresh subagent read brief/plan/specs, explored
> the code, ran the four-mode matrix + smoke + cross + fmt + bench-gate + two ThreadSanitizer runs, and
> confirmed coverage; the one hole it found — work-item 4c — was then closed and re-verified green).
> **Not yet committed at the time of writing** (HEAD = `d6a1802`); this session's delta is committed
> alongside this handoff.

---

## 1. Ownership statement (honest, Rule 12)

Every P5 work item (`pan_implementation_plan.md` §5, items 1–6) and **all six success-criteria gate
clauses** are implemented and **verified green** across the four-mode matrix (Debug / ReleaseSafe /
ReleaseFast test suites exit 0), the freestanding **ReleaseSmall smoke** object, the Linux **cross
seam** (`zig build cross-linux`), `fmt-check`, and `zig build bench -Dbench-gate` (**footprint baseline
8192 B held** — the commit refactor + the frozen-executor param-apply call are byte-neutral). The SPSC
ring and the RCU swap (control-plane AND a concurrent RT-render) are **ThreadSanitizer-clean**.

**What is the user's to run (cannot be done from a sandbox):** the live device gate — sub-5 ms
round-trip on M3, zero xruns over 10 min. `Engine.start(backend)` installs the CoreAudio render
callback (compiles + links AudioToolbox) but is not opened here; binding the device `out: []f32` to a
sink instance is the on-device integration step.

**Yoneda dispatch (Rule 14):** two autonomous `yoneda-test-writer` agents (each loaded `zig-0-16` +
verified by compiling) authored `tests/control_plane_test.zig` (39 tests, also TSan-clean) and
`tests/runtime_engine_test.zig` (16 tests incl. the runtime≡comptime differential). No bugs found in
the under-test code. Additional P5-closure tests live inline in `engine.zig`/`commit.zig`/`builder.zig`.

---

## 2. What was built (the P5 session's deltas)

```
src/control.zig  (NEW)  The lock-free control plane at EXACT orderings (concurrency spec §2–§4):
                        CommandRing(Cmd,cap) SPSC (P1–P4 producer / C1–C4 consumer; power-of-two,
                        cache-line-padded head/tail; drain + drainUntil wait-free); Param (atomic
                        .monotonic set/read) + Ramp (per-block anti-zipper, snap-no-drift); Rcu(Ptr)
                        (publish .release / enter .acq_rel+.acquire / waitGrace +2; single-writer ⇒ no
                        CAS/ABA). Re-exported as pan.control / CommandRing / Command / Param / Ramp / Rcu.
src/commit.zig   (M)    Refactored the ~400-line commit body into the SHARED `computePlan(g, mode)
                        Plan(max_nodes)` — runtime-callable, no comptime wrapper (scratch was already
                        max-sized; only `var ops` + the return were size-specialized). `commitComptimeMode`
                        repacks it to Plan(g.node_count) BYTE-IDENTICALLY (bench-gate proves it). Added
                        `commitGraph` (no insertion), `commitRuntime` (= computePlan(insertCoercions(g))),
                        and `insertCoercions` (auto-inserts a resampler coercion node on a rate-mismatched
                        edge). RenderOp += param_input_buffer_ids/slots/count (param edges split out of
                        sample inputs). CommitError += ParameterMultiplyDriven (already), BypassLatencyUncompensated.
                        Negotiate stage 1b = bypass-preserves-latency check.
src/engine.zig   (M)    The runtime Engine is now REAL (was a façade). renderThunk/destroyThunk/setThunkFor
                        + BoundNode{self_ptr,render,destroy,set}; RuntimePlan = Plan(max_nodes).
                        buildBoundPlan = insertCoercions + commitGraph + bind each op's fn_ptr/self_ptr
                        (author node → its thunk+instance; coercion node → coercionPassthroughThunk).
                        renderInto = epoch-bump + one acquire-load + ring drain + replayBound (wait-free,
                        indirect call/op). applyParamInputs applies wired param edges via setParam BEFORE
                        process (in BOTH the runtime thunk AND the comptime Executor.runOp) — so a wired
                        edge ≡ set. Verbs: set (atomic), schedule (ring), beginEdit/commit + recommit/
                        installPlan (RCU swap, grace-gated on a `running` flag), reconfigure (live swap
                        if pool pre-sized to max-N, else stopped realloc). Transition policy: mute/unmute/
                        solo/fadeIn/fadeOut = ramped set ("ramp, never step"). start(backend)/stop wire io.
src/builder.zig  (M)    add() heap-allocates each instance + captures thunks (ownership → engine on commit;
                        builder.deinit frees on failure). commit() → Engine.bind (real). markSet (P2).
                        max_block_size threaded from Config.
src/graph.zig    (M)    Node += is_coercion, bypassed; markBypassed.
src/config.zig   (M)    Config += max_block_size (pool pre-size for live reconfigure).
src/root.zig     (M)    re-export control + commitRuntime/commitGraph/insertCoercions + RuntimePlan/BoundNode.
tests/control_plane_test.zig, tests/runtime_engine_test.zig  (NEW, Yoneda).
build.zig        (M)    +2 harnesses.
```

---

## 3. Verification — how to reproduce green

From `/Users/komorebi/Documents/projects/tools/audio/pan`:
```sh
zig build test                              # Debug                    → EXIT 0
zig build test -Doptimize=ReleaseSafe       #                          → EXIT 0
zig build test -Doptimize=ReleaseFast       #                          → EXIT 0
zig build smoke                             # freestanding ReleaseSmall → PASS
zig build cross-linux                       # x86_64-linux-gnu seam     → PASS
zig build fmt-check                         #                          → PASS
zig build bench -Dbench-gate                # footprint baseline 8192B  → OK
# ThreadSanitizer (the RCU swap + SPSC ring under concurrent load):
zig test src/engine.zig  -framework AudioToolbox -framework CoreAudio -framework CoreFoundation -lc -fsanitize-thread --test-filter concurrent
zig test src/control.zig -fsanitize-thread --test-filter concurrent
```
> Carried cosmetic noise (from P2, still live): `aliasing_message_test`/`comparator_test` drive reject
> paths with `std.debug.print` ("aliasing hazard…", "oracle allclose fail…"); the 0.16 runner echoes
> "failed command" for those but the suite exits 0. Use `std.debug.print`, never `std.log.err`, for
> expected-reject diagnostics.

---

## 4. The central new architecture for P6 to read

- **The runtime Engine is the comptime Executor's RCU-swappable sibling.** Both share
  `commit.RenderOp` / `commit.Plan` / the pool-by-buffer-id layout and the gather/scatter logic; the
  only difference is dispatch (comptime-inlined `inline for` vs a bound `fn_ptr` indirect call). The
  shared `computePlan` is the single commit algorithm. **Do not fork a second IR.**
- **Param edges are an ordinary edge + a consumer-side ramp.** A wired control-rate output is colored/
  scheduled/SCC'd like any edge (P4); the executor reads its latest value and calls the consumer's
  `setParam(slot,value)` BEFORE `process`, and the consumer holds+ramps it — identical to `set`.
- **Ramp/transition state lives in the BLOCK INSTANCE** (e.g. `ParamGain.ramp`), NOT in the pool. This
  is why P5 could ship the ramp policy without the pool-excluded persistent category — that category is
  exactly P6's job (see §5).

---

## 5. What P6 needs (from `pan_implementation_plan.md` Phase 6) — and the P5 hooks

P6 = **roadmap step 3**: the `z⁻¹`/feedback machinery — element-generic `UnitDelay`/`DelayLine`, the
**pool-excluded persistent category**, the graph-level `DelayLine`-in-a-cycle idiom, FDN matrix
feedback, and the fused single-`Map` tight-feedback kernels (ladder / Karplus-Strong / comb). **Read
first** (plan §6): `pan_memory_model.md` §6 (the z⁻¹ rule; the two feedback idioms; persistent buffers
as state; S6 state-update granularity), §6.1 (fused tight-feedback kernel), §6.2 (persistent category);
`catalog.md` §5 (traced-monoidal feedback; §5.2 SCC-has-delay; §5.3 persistent pool-excluded; §5.5
element-generic `UnitDelay`/FDN); `pan_io_realtime_and_pipeline.md` §3 (denormals/FTZ in decaying
feedback paths); skill ch.04 + ch.05.

**The hooks P5 (and P3/P4) leave:**
- **`commit.zig` already handles feedback for the topology**: `FeedbackEdge` list, Tarjan SCC-has-delay
  (`error.DelayFreeLoop`), the z⁻¹ write/read split in emit (feedback read-sides = persistent inputs,
  write-sides = persistent outputs), and the footprint formula already adds `Σ delay_len·elem_size +
  Σ state_size` (the **persistent/feedback term**). `builder.connectFeedback` is wired. P5 even tests a
  **delay-free PARAMETER loop** rejection (param edges are subject to SCC-has-delay).
- **THE BLOCKER TO LIFT (P6's central task):** the executor currently **`@compileError`s if
  `plan.footprint_bytes != plan.pool_bytes`** (`engine.zig` `ExecutorMode`), i.e. it handles POOL
  buffers only — persistent delay/feedback state is rejected. P6 must give the executor (both the
  comptime `Executor` and the runtime `buildBoundPlan`/`replayBound`) a **persistent region** past
  `pool_bytes` (the pool-excluded category), allocate/own it across the whole callback (never colored),
  and route feedback read/write buffer ids into it. The runtime `Engine` already owns a heap pool slice
  sized `pool_cap`; extend it to `pool_bytes + persistent_bytes` and map persistent ids into the tail.
- **State-update granularity S6**: history/delay updates once per hop regardless of sub-block count.
- **`UnitDelay(Elem)`/`DelayLine(Elem,len)`** element-generic over `Sample`/`Frame`/`Complex`/
  `FeatureFrame`; allocated at `initialize`, pool-excluded. **FDN** = N `DelayLine` nodes + a matrix-mix
  `Map` over `Frame(Lane,.discrete(N))` + feedback edges. **Fused tight-feedback kernels** (ladder/KS/
  comb): per-sample feedback inside one rate-1:1 `process` over fixed persistent state; **not**
  `aliasing_safe`; declare the internal `z⁻¹` so SCC-has-delay sees it.
- **FTZ** is already token-gated (`enterRealtimeThread`); P6 confirms it prevents denormal CPU spikes on
  a decaying reverb tail.
- **Persistent-state handoff across an RCU swap** (concurrency §4.6): P5's `installPlan` reclaims the
  old plan after grace; P6 must **carry persistent buffers into the new plan** (reuse the same buffer,
  or ramp) so a topology edit doesn't reset a delay line / click. `installPlan` already frees only
  dropped author instances after grace — extend the same discipline to persistent buffers.

**Bundling:** Session 6 = **P6 + P7** (per `notes/session_bundling.md`): P6 adds the persistent
category; P7 colors the non-persistent edges (Mode-C left-edge interval coloring) and adds in-place
coalescing. They share `commit.zig` liveness + footprint + the **B≡C differential harness**, so they
land one "memory model done + B≡C green" gate (roadmap steps 3+4). P7's coloring is partly present
already (the commit pass colors per-class today); P7 finishes liveness intervals + the in-place gate +
the `aliasing_safe` quote-back message + the B≡C differential as the *primary* colorer check.

---

## 6. Honest gaps carried into P6+ (Rule 12)

**Closed this session (no longer gaps):** the lock-free control plane (all three verbs at exact
orderings); the runtime Engine render path (runtime≡comptime bit-identical differential); param-edge
rendering + set≡wired-edge (P3) + delay-free-param-loop (P4); one-source P2; resampler auto-insertion;
bypass-preserves-latency commit check; device-reconfiguration with a max-N pre-sized live swap; the
mute/solo/start-stop "ramp, never step" transition policy; set-rejects-`at_sample` ⊢; RCU+ring TSan.

**Still genuinely deferred (cited):**
- **Polyphase sinc resampler NUMERICAL body** + registered up/down-mix matrices → Phase 8/16 (plan
  line 551). P5 inserts the resampler *node* (`coercionPassthroughThunk` = same-rate passthrough STUB);
  ≈ numerical correctness is a Phase-8 gold vector. **Also:** a rate mismatch is currently only
  constructible by hand-setting per-node `sample_rate` on the raw `graph.Graph` (the test does this) —
  the public `builder.Graph` has no per-node rate setter, so auto-insertion isn't reachable through the
  documented `add→connect→commit` arc until a real `Rate` block / device domain introduces a second
  rate (Phase 8). A P5/P8 **seam gap**, not a bug (flagged by the independent audit).
- **Full PDC compensating-delay routing** → Phase 8 (plan line 553). P5 does only the "where detectable"
  bypass-preserves-latency commit reject (a bypassed latent block with no compensation).
- **Pool-excluded persistent category** (delay/feedback buffers in the pool tail) → **P6** (the
  executor `@compileError` above is the explicit gate).
- **Live device gate** (sub-5 ms / 10-min) → on-device (user). `Engine.start` links but isn't opened.
- **`renderOffline`/`renderToCompletion`** → `error.OfflineNotImplemented` (Tier C, Phase 14).
- **Param-edge value extraction** assumes a `Scalar(f32)`-lane control element (the LFO→cutoff case);
  wider control elements (`FeatureFrame`, `f64` lane) are a later refinement.
- **P11** (LFO/ADSR/feature→param/data-gating modulation BLOCKS) — see §7.

---

## 7. P11 status (the unbundled half) — NOT a blocker

Session 5 was mapped as P5+P11 (`session_bundling.md` line 35, the one deliberate reorder). **Only P5
landed.** P11 is the modulation *blocks* that DRIVE parameter ports (the consumers of P5's machinery),
so it **cannot precede P5** and **does not block** P6/P7/P8. Its only downstream consumer is **P13**
(Instrument/polyphony — ADSR feeds voices), ~5 sessions out. P5's closure already proved the wired-
param-edge seam **end-to-end and bit-identically to `set`** (`ConstScalar`→`param.gain` ≡ `set`), so
P11's blocks have a tested socket; a real `LFO` is a fancier `ConstScalar`. **Recommendation:** proceed
to Session 6 (P6+P7); slot P11 in later as a light standalone (S–M) any time before P13.

---

## 8. Conventions carried forward

Unchanged: §0.2 self-contained code docs (no spec-section refs in `src/` — verified clean); §0.3
⊢/≈/▷ markers; §0.5 oracle-allclose vs pan-vs-pan bit-exact; §0.6 four-mode CI matrix; Rule 13 load
`zig-0-16` + tell every subagent; Rule 14 dispatch Yoneda writers; Rule 10 checkpoint; any new runnable
module links the platform audio transport via `build.zig`'s `linkPlatformAudio`.
