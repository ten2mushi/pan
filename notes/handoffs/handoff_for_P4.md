# Handoff — end of Session 3 (P3 "commit pass + Mode-B/coloring + footprint") → into P4

> **Status:** P0 + P1 + P2 + **P3 implemented and green**. P3 gate met. This is an
> advisory handoff, not a spec: the `specifications/` corpus and
> `pan_implementation_plan.md` remain the source of truth.
> **Date:** 2026-06-03. **Toolchain:** `zig 0.16.0` (re-run `zig version` at the start
> of P4 — Rule 13). No commit was made (the user had not asked).

---

## 1. Ownership statement (honest, Rule 12)

Every Phase-3 work item in the plan (§3 "The commit pass (offline, comptime-evaluable)")
is implemented and **verified green** across the full CI matrix: **31/31 build steps,
315/315 tests** in Debug, plus ReleaseSafe / ReleaseFast / freestanding-ReleaseSmall smoke /
fmt-check. The two worked examples the gate names reproduce exactly.

**P3 gate (`pan_implementation_plan.md` §3): MET.**
1. **Worked example B** (feedback comb, `pan_commit_pass_algorithms.md` §11) reproduces
   exactly: correct topo, SCC **accept** (the cycle contains a `DelayLine`), and
   `footprint = 3968 bytes` (pools M=2·256·4 = 2048 + persistent ring 480·4 = 1920) at N=256.
   Op-count 5 (one op per node). Pinned in `src/commit.zig` and `tests/commit_plan_test.zig`.
2. **Worked example C** (delay-free loop, §12) reproduces exactly: topo succeeds (feedback
   removed), SCC on the full graph finds the `{Sum,Gain}` cycle with no delay → rejected with
   `error.DelayFreeLoop`.
3. The **smoke gate** compiles in `ReleaseSmall` freestanding (`zig build smoke`);
   `commitComptime` runs at `comptime` (its `footprint_bytes` is used as an array length in
   several tests — legal only for a comptime constant).
4. The **three commit errors fire on the right graphs**: `error.UndeclaredCycle` (plain
   non-feedback back-edge), `error.UnrootedPath` (non-source path head, SR3), `error.DelayFreeLoop`
   (declared feedback, no delay) — plus `MalformedGraph` / `PortCeilingExceeded`.

**Yoneda dispatch (Rule 14):** two autonomous `yoneda-test-writer` agents were dispatched
(each told to load `zig-0-16`), given the code section + invariant but not the tests:
- validation stages → `tests/commit_validation_test.zig` (31 tests);
- buffer/footprint/emit stages → `tests/commit_plan_test.zig` (23 tests).

---

## 2. Full literal scope closed + independently audited

After an initial pass that deferred several §3 sub-items, the **complete literal P3 surface
scope was closed** on user request and **independently audited** (a fresh agent read the
brief + plan §3 + specs, explored the code, and re-ran the build): verdict **"FULL P3 literal
scope met"**, 315/315 tests in Debug/ReleaseSafe/ReleaseFast, all 7 work items MET. What the
closure added beyond the first pass:
- **Item 1:** `CommittedGraph` + `FeedbackEdge` named types (the z⁻¹ write/read split now lives
  in a separate `graph.feedback` list, not an `Edge.feedback` flag).
- **Item 2 (negotiate):** a real stage — the `coercionFor` decision over the catalog §6 table
  (none / cast / up-down-mix / resample / ramp-hold / hard_mismatch), L2 `error.LayoutMismatch`
  reject, and the parameter one-source **P2** check (`error.ParameterMultiplyDriven`) backed by
  `graph.markSetParam`. **L1 (element identity) is the compile-time `connect` guarantee** (spec
  §6: a mismatch is a `@compileError`), so it is *not* re-checked at commit — that was the bug
  in the first pass (a commit-time L1 string check spuriously failed on hand-built test edges).
- **Item 4:** real **iterative Tarjan** SCC (was a transitive-closure substitute).
- **Item 5:** general `needed_input` — Map (1:1), Rate (`ceil(want·q/p)`, no H∤N assumption),
  VariRate (`rate_bounds.min` worst-case), Source out-len from demand N. Both Rate and VariRate
  now have commit-level tests.
- **Item 6:** **Mode-B baseline IS present** — `commitComptimeMode(g, .per_edge)` vs `.colored`;
  `commitComptime` defaults `.colored`. P7's B≡C diff has its baseline.

**The coloring-vs-"Mode-B-only" plan conflict (Rule 7):** the plan §3 wording says "Mode-B" but
its own gate needs worked example B's *colored* 3968 B (M=2); the spec (source of truth) puts
coloring in the commit pass, so `commitComptime` colors by default and Mode-B is the sibling
baseline. See memory `p3-coloring-deviation`.

**Still genuinely P7:** in-place coalescing (3-condition + `aliasing_safe` gate), wiring Mode-C
behind a runtime `getBuffer(edge)` pool, the B≡C differential *executor* test, the quote-back
message. **Still P8:** PDC. **Still P4:** binding real kernel `fn_ptr`/`self_ptr` (null now).

**Two minor audit notes (non-blocking):** two in-`src/` *test names* cite catalog sections
(sanctioned by plan §0.4 "test names encode the catalog citation"; the §0.2 no-spec-refs rule
is about code/doc-comments, which are clean). No `src/` code or doc-comment references a spec
file/section.

---

## 3. Verification — how to reproduce green

From `/Users/komorebi/Documents/projects/tools/audio/pan`:

```sh
zig build                               # lib + CLI install (prints monomorph count)  → PASS
zig build test                          # 31/31 steps, 315/315 tests                  → PASS
zig build test -Doptimize=ReleaseSafe   # release-shaped + safety                     → PASS
zig build test -Doptimize=ReleaseFast   # safety stripped                             → PASS
zig build smoke                         # freestanding ReleaseSmall comptime-commit obj → PASS
zig build fmt-check                     # src + build.zig + tests formatting           → PASS
zig build run                           # prints: pan: committed 3 ops, pool footprint 4096 bytes
```

Per-target Debug test counts: lib `root.zig` 53 · exe · `type_machinery` 60 · `port_machinery`
33 · `mux_machinery` 24 · `gold_vector` 5 · `dual_mux` 3 · `comparator` 56 · `bc_differential`
3 · `aliasing` 2 · `aliasing_message` 16 · `latency_contract` 4 · `state_granularity` 2 ·
**`commit_plan` 23** · **`commit_validation` 31**.

> **Cosmetic noise (carried from P2, §6 gotcha):** `aliasing_message_test` and
> `comparator_test` deliberately drive comparators down their reject path and emit
> `std.debug.print` diagnostics ("aliasing hazard…", "oracle allclose fail…"); the Zig 0.16
> build runner echoes "failed command" for those binaries, but the authoritative line is
> "315/315 tests passed" and the process exits 0 on every repeat run (verified 20+ runs).
> A single first-recompile run once showed a transient slice-diff exit-1 that never
> reproduced — watch, but it is in P2 harness territory, not the commit pass.

---

## 4. What was built (this session's deltas)

```
src/graph.zig   (REBUILT) Node enriched: is_source, is_delay, delay_len,
                          algorithmic_latency, out_per_in_{p,q} (VariRate reads rate_bounds.min),
                          aliasing_safe, state_size, rate_domain, sample_rate, set_param_slots.
                          add() handles SINK blocks (no output → out_elem "(sink)"). Graph gains
                          block_size (device N) + sample_rate. NEW: FeedbackEdge type + separate
                          `feedback` list (z⁻¹ write/read split) populated by connectFeedback;
                          `CommittedGraph = Graph` alias; edges carry is_param + channels;
                          markSetParam(node, slot) for the P2 one-source check.
src/commit.zig  (REBUILT) the full pipeline to pseudocode precision (see file header):
                          negotiate (coercionFor decision over catalog §6 table + L2
                          LayoutMismatch reject + P2 ParameterMultiplyDriven; L1 = compile-time
                          connect) · Kahn topo + min-node-id tie-break (UndeclaredCycle) ·
                          source-rooted SR3 (UnrootedPath) · SCC-has-delay via ITERATIVE TARJAN
                          on the FULL graph forward∪feedback (DelayFreeLoop) · liveness
                          (produced-value intervals, end-inclusive, fan-out → last reader,
                          persistent excluded) · buffer assignment with BufferMode {per_edge |
                          colored} (left-edge, isize -1 sentinel) · general rate-scheduling
                          (Map/Rate ceil(want·q/p)/VariRate min-ratio, Source out-from-N, H∤N) ·
                          per-NODE emit (forward + feedback read/write sides) · footprint = Σ
                          pools + Σ delay rings + Σ state (PDC term = 0, P8). commitComptime =
                          commitComptimeMode(.colored). CommitError = {UndeclaredCycle,
                          UnrootedPath, DelayFreeLoop, LayoutMismatch, ParameterMultiplyDriven,
                          MalformedGraph, PortCeilingExceeded}. ~22 in-file characterization tests.
src/root.zig    (M)  SmokeSource → a real Source (zero input); SmokeSink → true sink; smoke-gate
                     test updated (op_count 3, footprint 2·512·4); export CommitError, BufferMode,
                     Coercion, EdgeFormat, coercionFor, commitComptimeMode.
src/engine.zig  (M)  renderInto test graph re-rooted at a Source; passes g.node_count.
src/main.zig    (—)  unchanged signature; prints "3 ops, 4096 bytes".
build.zig       (M)  registered tests/commit_plan_test.zig + tests/commit_validation_test.zig.
tests/commit_plan_test.zig       (NEW, Yoneda) buffer/footprint/emit laws (23 tests).
tests/commit_validation_test.zig (NEW, Yoneda) topo/SR3/SCC/taxonomy laws (31 tests).
```

> Note: `git status` shows `archive/high-throughput-url-processing.md` deleted — that is
> pre-existing and unrelated to P3; left untouched.

---

## 5. Design decisions carried forward (read before P4)

1. **One RenderOp per NODE**, forward-topo order (spec §8), with `input_buffer_ids` /
   `output_buffer_ids` / counts and `n_or_pull_spec` (= resolved N). `op_count == node_count`
   (the P2 skeleton emitted one op per *edge* — that was wrong and is gone).
2. **`fn_ptr` / `self_ptr` are NULL in P3.** The op-list topology + buffer ids are fixed at
   commit; binding the monomorphized kernel pointers + block state is **P4's executor job**.
   The IR stores `@typeName` not `type`, so P4 will need a mechanism to carry the bound kernel
   (the comptime graph can hold the block type; consider a parallel comptime tuple of kernels
   keyed by node id, resolved at the `commitComptime` call site or in the builder).
3. **N lives on the comptime `Graph` (`block_size`).** Footprint scales with N; the buffer-id
   *map* is N-independent (an N change resizes backing bytes only — spec §8). On embedded N is
   comptime-fixed so footprint is a comptime constant.
4. **`element_count = N` for every pool edge** in P3 (all edges are time-domain `Sample`/`Frame`).
   Spectral `Complex` (N/2+1) and feature (1) counts are computed when rate-elastic / spectral
   blocks ride edges (P8/P9). The class key is `(element_name, element_count)`.
5. **Validation runs BEFORE buffer assignment** (negotiate → topo → SR3 → SCC, then liveness →
   coloring → emit → footprint). The spec §0 list interleaves SCC after coloring, but §12's
   worked example C mandates the rejection short-circuits *before* coloring — §12 wins.
6. **No PDC and no param one-source P2 in P3** (both explicitly later: PDC = P8 "no graph in
   P1–7 has a latency-mismatched fan-in"; control plane / one-source = P5). The footprint keeps
   a (zero) PDC term structurally; `aliasing_safe`/`algorithmic_latency`/`rate_domain` are read
   onto the Node now so P7/P8 have them without re-reflecting.
7. **Error messages name the error value, not a rich string.** At `comptime` a returned error
   carries no payload (and `expectError` must work), so the cycle-naming / quote-back prose
   (spec §5/§12) is deferred to the runtime-commit path; the error *value* is the comptime
   signal. Do not `@compileError` for these — it breaks `expectError`.

---

## 6. What P4 needs (from `pan_implementation_plan.md` Phase 4)

P4 = **roadmap step 1**: the synchronous pull executor + the CoreAudio callback render path,
end-to-end on M3 — CoreAudio sink + LPCM source + a 3-block `Map` chain (gain → biquad → pan)
on Tier A + pool Mode-B. **Read first (per plan §4):** `pan_execution_model.md` §1/§3/§4/§5/§6/§7,
`pan_io_realtime_and_pipeline.md` §3/§4/§5/§10/§11, `catalog.md` §8.1–§8.3/§10/§11.1,
`pan_developer_experience.md` §1/§3/§4, skill ch.04 (SIMD) / ch.03 / ch.06 (C interop).

The hooks P3 leaves for P4:
- `commitComptime` returns `Plan(node_count)` with per-node ops; **bind real `fn_ptr`/`self_ptr`**
  (the biggest new piece — wire the monomorphized `process`/`pull` kernels + block state into
  the op-list).
- `engine.renderInto(n_ops, token, plan, mux)` already replays `plan.ops`; flesh out the body
  (gather inputs / scatter outputs through the pool by buffer id; honor `n_or_pull_spec`).
- `RealtimeToken` must actually set ARM64 FPCR FZ/AH on the audio thread (currently a no-op).
- First real DSP blocks (`Gain` aliasing_safe, `Biquad` Mealy state, `ConstantPowerPan`
  layout-changing) + the LPCM I/O HAL + CoreAudio `extern`/`callconv(.c)` + an ALSA backend
  that cross-compiles (`-Dtarget=x86_64-linux-gnu`).
- **Stand up `bench/`** (plan §0.9) — first runnable DSP path is the cue.

The P3 commit pass + the test backbone are in place to receive P4's executor: the colored
op-list and footprint are correct; P4 makes the ops actually run.

---

## 7. Conventions carried forward

Unchanged from prior handoffs: §0.2 self-contained code docs (no spec-section refs in `src/`);
§0.3 ⊢/≈/▷ tier markers; §0.5 oracle-allclose vs pan-vs-pan-bit-exact; §0.6 four-mode CI matrix
+ `guards_compiled_out`; Rule 13 load `zig-0-16` + tell every subagent; Rule 14 dispatch Yoneda
writers; Rule 10 checkpoint. **Gotcha (still live):** use `std.debug.print`, never `std.log.err`,
for test diagnostics on expected-reject paths — the 0.16 test runner resolves `logFn` from the
runner root and exits non-zero on any `log_err_count != 0`.
