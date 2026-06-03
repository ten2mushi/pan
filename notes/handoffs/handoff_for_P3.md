# Handoff — end of Session 2 (P2 "SampleMux seam + test backbone") → into P3

> **Status:** P0 + P1 + **P2 implemented and green**. P2 gate met. This is an
> advisory handoff, not a spec: the `specifications/` corpus and
> `pan_implementation_plan.md` remain the source of truth.
> **Date:** 2026-06-03. **Toolchain:** `zig 0.16.0` (re-run `zig version` at the
> start of P3 — Rule 13). No commit was made (the user had not asked).

---

## 1. Ownership statement (honest, Rule 12)

Every Phase-2 work item in the plan (§2 "SampleMux seam + test backbone +
scripts/generate.py + manifests") is implemented and **verified green** across
the full CI matrix: **27/27 build steps, 260/260 tests** in Debug, plus
ReleaseSafe / ReleaseFast / freestanding-ReleaseSmall smoke / fmt-check, and the
generator's byte-reproducibility gate.

> **Scope-closure note (honesty, Rule 12):** an initial pass left two items
> open, both closed in a follow-up within the same session after an ownership
> audit: (1) the **`aliasing_safe` quote-back failure-message contract**
> (plan §2 / spec §7.6 / mem §9) — the listed P2 item I had missed — is now
> implemented (`harness.expectPanVsPan`), wired into the aliasing + B≡C harnesses,
> and Yoneda-characterized (16 tests, `tests/aliasing_message_test.zig`); (2) the
> single-port mux boundary, previously a silent trap (port>0 returned port-0's
> buffer), is now **loud** — every method asserts `port == 0`. Multi-port mux
> bodies remain a deliberate P4 deferral (no P2 block is multi-port; the executor
> that demultiplexes port demand is P4), now made explicit rather than latent.

**P2 gate (`pan_implementation_plan.md` §2): MET.**
1. `TestSampleMux`/`PullTestSampleMux` round-trip bytes through the 10-method
   vtable (the `src/mux.zig` in-file tests + the new 24-test
   `tests/mux_machinery_test.zig` exercise all four realizations).
2. `scripts/generate.py` reproduces **byte-identical** blobs across two runs
   (proven by cross-run `cmp` and the new `--check` self-test, for both the
   `f32` and `q15` manifests).
3. The six harness drivers compile and **run green on the identity/passthrough
   block** across every build mode.

The P2 work was **mostly net-new test backbone**; `src/mux.zig` was already
complete from P1 (full vtable + the whole family with working single-port
bodies), so per Rule 3 it was left untouched and only characterized by tests.
The full demand-tracking *multi-port* executor bodies are genuinely a later
concern (the executor lands in P4); single-port muxes suffice for every P2
harness and the gate.

**Yoneda dispatch (Rule 14):** two autonomous `yoneda-test-writer` agents were
dispatched (each instructed to load `zig-0-16`), given the code section +
invariant but not the tests:
- one for the `SampleMux` family → `tests/mux_machinery_test.zig` (24 tests);
- one for the comparison backbone → `tests/comparator_test.zig` (56 tests).

---

## 2. Verification — how to reproduce green

From the project root `/Users/komorebi/Documents/projects/tools/audio/pan`:

```sh
zig build                               # lib + CLI install (prints monomorph count)  → PASS
zig build test                          # 27/27 steps, 260/260 tests                  → PASS
zig build test -Doptimize=ReleaseSafe   # release-shaped + safety (paranoid on)       → PASS
zig build test -Doptimize=ReleaseFast   # safety stripped; paranoid tests early-return → PASS
zig build smoke                         # freestanding ReleaseSmall comptime-commit obj → PASS
zig build fmt-check                     # src + build.zig + tests formatting            → PASS
zig build run                           # prints: pan: committed 2 ops, pool footprint 8 bytes

# Generator (numpy only; scipy not needed until DSP-block references land in P4):
python3 scripts/generate.py tests/vectors/gain_f32.json --check   # byte-reproducible
python3 scripts/generate.py tests/vectors/gain_q15.json --check   # byte-reproducible
```

Per-target test counts (Debug): lib `root.zig` 52 · exe · `type_machinery` 60 ·
`port_machinery` 33 · **`mux_machinery` 24** · `gold_vector` 5 · `dual_mux` 3 ·
**`comparator` 56** · `bc_differential` 3 · `aliasing` 2 ·
**`aliasing_message` 16** · `latency_contract` 4 · `state_granularity` 2.

---

## 3. What was built (this session's deltas)

```
tests/harness.zig            (NEW) shared backbone: Tolerance + allcloseF32/bitExact/
                                   alignByLatency/measuredGroupDelay/poisonNaN/anyNaN,
                                   render-through-mux drivers (push/pull/aliased),
                                   synthetic blocks (Identity/Scale/Accumulator),
                                   Manifest schema + parseManifest/resolveTolerance.
                                   Carries NO test{} blocks by design.
tests/gold_vector_test.zig   (NEW) §5.1 — manifest schema validation (embedFile) +
                                   identity≡synthetic-oracle through the push mux.
tests/dual_mux_test.zig      (NEW) §5.2 — push≡pull bit-exact, latency-aligned.
tests/bc_differential_test.zig (NEW) §5.3 — Mode-B baseline + paranoid NaN mechanism.
tests/aliasing_test.zig      (NEW) §5.4 — aliasing_safe scale in-place≡out-of-place
                                   (now via the quote-back comparator).
tests/aliasing_message_test.zig (NEW, Yoneda) the §7.6/§9 quote-back contract (16):
                                   a lying aliasing_safe block trips
                                   error.AliasingSafeViolated with the falsified-
                                   contract message; honest blocks pass.
tests/latency_contract_test.zig (NEW) §5.5 — impulse group-delay measurement.
tests/state_granularity_test.zig (NEW) §5.6 — full≡sub-block on a stateful accumulator.
tests/mux_machinery_test.zig (NEW, Yoneda) the SampleMux family vtable laws (24).
tests/comparator_test.zig    (NEW, Yoneda) the comparison-policy laws (56).
tests/vectors/gain_q15.json  (NEW) the fixed-point bit-exact manifest sibling.
tests/harness.zig            (M)  + expectPanVsPan / firstBitDivergence /
                                   declaresAliasingSafe — the aliasing_safe quote-back.
scripts/generate.py          (M)  factored _compute_blobs; added `--check` determinism
                                   self-test; documented frame-major/interleaved layout +
                                   round-half-to-even quantization; q15 path already present.
build.zig                    (M)  registered the 9 new tests/ harnesses.
src/mux.zig                  (M)  single-port boundary made loud: every method asserts
                                   `port == 0` (was a silently-ignored `_ = port;`).
                                   Bodies otherwise unchanged from P1.
```

---

## 4. Key decisions surfaced (Rules 7 / 11)

1. **Comparator backbone lives in `tests/harness.zig`, not `src/`.** The shared
   `Tolerance`/comparator/driver/manifest code is test-only infrastructure, so it
   stays out of the shipped library surface — matching the testing spec's
   `tests/`-rooted §7.2 layout. Each `tests/<harness>_test.zig` relative-imports
   `harness.zig` (a sibling within the `tests/` module root, which Zig 0.16
   allows) and imports the library via the `pan` module (never `../src`, per the
   P1 decision). `harness.zig` deliberately has **no `test{}` blocks** (it is
   compiled into several test modules; a test there would run once per importer).
2. **Drivers route through the byte-typed 10-method vtable** (`sliceAsBytes` /
   `@alignCast(bytesAsSlice(...))`), not around it — the P2 gate is literally
   "round-trip bytes through the vtable". `bytesAsSlice` returns an under-aligned
   slice; the bytes originate from aligned `Sample` arrays, so `@alignCast` is the
   correct, safety-checked recovery.
3. **Gold-vector harness is hermetic.** It `@embedFile`s the committed manifest to
   validate the schema and compares against a *synthetic in-test oracle*; it does
   **not** shell out to python or depend on the git-ignored blobs at test time.
   The real gold vectors (with SciPy references and generated blobs) plug into the
   same `renderPush` + comparator path unchanged when DSP blocks land in P4.
4. **B≡C is a Mode-B-vs-Mode-B baseline for now.** The colored pool (Mode C) lands
   in P7; this session stands up the differential *shape* (two independent
   renders, bit-exact) + the paranoid NaN-poison mechanism, so P7 only swaps Mode
   C in behind the same comparison.
5. **Comparator diagnostics use `std.debug.print`, not `std.log.err`** (gotcha, see
   §6). The testing-spec §1.4 reference comparator uses `std.log.err`; that flips
   `zig build test` to exit-1 whenever a test *deliberately* exercises the reject
   path (the comparator characterization does). `std.debug.print` is the idiomatic
   test-comparator diagnostic (std's own comparators use it) and keeps the
   semantics identical (the returned error is the loud signal). This is a faithful
   restatement, not a deviation from the spec's meaning.

---

## 5. What P3 needs (from `pan_implementation_plan.md` Phase 3)

P3 = the **commit pass** (offline, comptime-evaluable) with **Mode-B per-edge
buffers**. **Read first (per plan §3):** `pan_commit_pass_algorithms.md` (all),
`catalog.md` §5.2 / §6 / §7.8 / §8.2 / §8.5, `pan_memory_model.md` §6.1 / §7
(shape only), skill ch.02 / ch.04 / ch.01.

Work (rebuild `src/commit.zig` + supporting; the current `commit.zig`/`graph.zig`
are the **Phase-3 throwaway baseline** — a Mode-B-only commit + comptime IR — and
P3 rebuilds them):
1. `CommittedGraph`/`Node`/`Edge`/`FeedbackEdge`; `RenderOp`; `Plan(n_ops)`;
   `CommitError`.
2. Format-negotiate pre-stage (layout-identity unification L1; coercion-insertion
   decision; reject unregistered pairs L2; parameter one-source P2).
3. Topo (Kahn + min-NodeId tie-break) + source-rooted SR3 scan
   (`error.UnrootedPath`/`error.UndeclaredCycle`).
4. SCC-has-delay (Tarjan on the full graph incl. feedback →
   `error.DelayFreeLoop`).
5. Rate-scheduling (demand propagation → `n_or_pull_spec`; Source `out.len` from
   pull N; VariRate min-ratio; H∤N ring).
6. Emit (forward-topo) + Mode-B buffer-id assignment + the footprint formula.
7. Comptime-evaluability: keep/restore the **smoke gate** green
   (`smokeGraph()` + `footprint_bytes`-as-array-length proof in `root.zig`).

**P3 gate:** worked examples B (feedback comb) and C (rejected delay-free loop)
from `pan_commit_pass_algorithms.md` §11–§12 reproduce exactly; the smoke gate
compiles in `ReleaseSmall` freestanding; `commitComptime` runs at comptime; the
three commit errors fire on the right graphs.

The P2 test backbone is now in place to receive P3's work: the B≡C harness is the
home for the colorer differential (P7), and the comptime-commit smoke gate is
already wired into `zig build test` + `zig build smoke`.

---

## 6. Conventions carried forward + one new gotcha

Conventions are unchanged from the P2 handoff §7 (§0.2 self-contained code docs;
§0.3 ⊢/≈/▷ tier markers; §0.5 oracle-allclose vs pan-vs-pan-bit-exact; §0.6 CI
matrix + `guards_compiled_out`; Rule 13 load `zig-0-16` + tell every subagent;
Rule 14 dispatch Yoneda writers; Rule 10 checkpoint).

**New gotcha (Zig 0.16 test runner):** `std.options`/a custom `logFn` is resolved
from the **test-runner root module, not your `-Mroot` test file**, so a test file
cannot suppress library `std.log` output. The runner also exits **non-zero** when
`log_err_count != 0` even if `fail_count == 0`. Consequence: a comparator/helper
that emits `std.log.err` on a path a test *expects* to hit (e.g. an asserted
rejection via `expectError`) will flip an all-passing `zig build test` to exit-1.
Use `std.debug.print` for test-diagnostic output that may fire on expected paths.
