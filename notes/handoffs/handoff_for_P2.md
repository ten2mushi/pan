# Handoff — end of Session 1 (P0 + P1 "Foundations") → into P2

> **Status:** P0 + P1 implemented and **green**. Session-1 gate met. This is an
> advisory handoff, not a spec: the `specifications/` corpus and
> `pan_implementation_plan.md` remain the source of truth.
> **Date:** 2026-06-03. **Toolchain:** `zig 0.16.0` (re-run `zig version` at the
> start of P2 — Rule 13). **Base commit at handoff:** `51100c4` (working tree had
> these changes uncommitted; no commit was made — the user had not asked).

---

## 1. Ownership statement (honest, Rule 12)

**Update (full P0+P1 pass):** every Phase-0 and Phase-1 *work item* in the plan
is now implemented. The deferrals previously listed in §5 have all been closed
(see §5 for the resolution map). The code is correct, self-contained (no
`specifications/*.md` citations in `src/` per §0.2), and **verified green** across
the full CI matrix: **9/9 build steps, 145/145 tests**, Debug/ReleaseSafe/
ReleaseFast + freestanding ReleaseSmall smoke + fmt-check.

**Session-1 gate (`notes/session_bundling.md`): MET.** Plus the full Phase-0
success criterion — **the DX `add → connect → commit → start` arc type-checks
against the stubs** (`builder.zig` test "DX arc: …").

**Independently audited (Explore agent, read-only).** Verdict: P0 ✅ complete,
P1 ✅ complete, both gates PASSED, nothing missing/mislabeled. It surfaced two
findings, both now resolved:
1. **§0.2 violations (real, fixed).** Spec-section citations in `src/`
   doc-comments — including some I introduced in the `mux.zig` additions and
   `port.zig`, plus pre-existing ones in the throwaway `commit.zig`/`graph.zig`.
   §0.2 applies to every phase, so **all of `src/` was cleaned**: doc-comments and
   inline comments reworded to restate the law in prose, and the spec citation
   stripped from the `connect` `@compileError` message. **Test-name citations are
   preserved** (allowed under §0.4). Final scan: **zero non-test-name citations in
   `src/`**.
2. **Missing `tests/.gitignore` (false alarm).** The root `.gitignore` already
   covers `tests/vectors/**/*.{bin,raw,pcm,npy}` (lines 7–10).

---

## 2. Verification — how to reproduce green

From the project root `/Users/komorebi/Documents/projects/tools/audio/pan`:

```sh
zig build                          # library + CLI install (prints monomorph count) → PASS
zig build test                     # 9/9 steps, 145/145 tests             → PASS
zig build test -Doptimize=ReleaseSafe   # release-shaped + safety         → PASS
zig build test -Doptimize=ReleaseFast   # safety stripped, tests pass     → PASS
zig build smoke                    # freestanding ReleaseSmall comptime-commit object → PASS
zig build fmt-check                # src + build.zig + tests formatting    → PASS
zig build run                      # prints: pan: committed 2 ops, pool footprint 8 bytes
```

Test breakdown: lib `root.zig` + re-exported submodules (incl. the DX-arc and
Concat tests in `builder.zig`/`root.zig`) · exe tests · **60**
(`tests/type_machinery_test.zig`, Yoneda) · **33**
(`tests/port_machinery_test.zig`, Yoneda).

---

## 3. What was built

### P0 — build system, public API surface, conventions
- **`build.zig.zon`** — `.paths` extended (`src`, `tests`, `scripts`, `examples`,
  `include`). `.name = .pan`, `.fingerprint`, `.minimum_zig_version = "0.16.0"`
  unchanged.
- **`build.zig`** — module-centric (skill ch.06): library `src/root.zig`; CLI
  `src/main.zig` (imports the `pan` module); a `test` step running lib + CLI +
  the two `tests/` harnesses; a **freestanding `ReleaseSmall` smoke object**
  (`resolveTargetQuery(.{ .os_tag = .freestanding })` over
  `src/smoke_freestanding.zig`); `docs` (getEmittedDocs); `fmt-check`
  (`addFmt .check`); `run` / `bench` (placeholder) top-level steps.
- **`src/root.zig`** — the library root (renamed from the deleted `src/pan.zig`).
  Re-exports the type machinery; pins `Config`, `Telemetry`, the mux family
  names, `RealtimeToken`/`enterRealtimeThread`, and the namespaced library roots
  (`io`, `filters`, `gen`, `env`, `fx`, `spectral`, `feat`, `mix`, `time`,
  `spatial`, `synth`, `combinators`, `realtime`) as empty `struct {}` stubs.
  Holds the **comptime-commit smoke gate** (`smokeGraph()` + the
  `footprint_bytes`-as-array-length proof).
- **`src/main.zig`** — minimal CLI: commits `smokeGraph()` at comptime, prints
  the ops/footprint summary.
- **`src/smoke_freestanding.zig`** — `export fn pan_smoke_footprint()` forcing the
  comptime commit during a no-std freestanding object build.

### P1 — core type system (rebuilt)
- **`src/numeric.zig`** — `Numeric { Lane, Acc, saturate, W }`; full locked
  `Precision` set `{ f32, f64, i8, i16, i32, i64 }` (i16 = q15, i32 = q31 by
  interpretation); `numericFor` comptime switch (integer → 2×-width **saturating**
  `Acc`; float → same-width, no saturate); `widthFor` via
  `std.simd.suggestVectorLength orelse 1`; explicit `active` precision list.
- **`src/types.zig`** — **`ChannelLayout`** `union(enum)`
  (`mono/stereo/surround_5_1/surround_7_1/ambisonic/discrete/custom`) with
  `count()` (ambisonic `(o+1)²`) and `name()`; **`Frame(Lane, L)`** planar named
  struct (layout rides in the type → layout mismatch is a type error);
  `Sample(T) == Frame(T, .mono)` by construction; `Complex`, `FeatureFrame`,
  `Scalar`, `Bounded`. Pool-class-key decls (`channel_count`, `lane`, `layout`,
  `typeName()`).
- **`src/port.zig`** — `Direction`, `PortIndex = u3` (8-port ceiling,
  `checkPortCeiling`), `PortId`/`ParamPortId`, `isPortId`/`isParamPort`;
  **`classify` → `{ Map, Rate, VariRate }`** by field presence with the R1/V1
  build-error rejections; **`isSource`** (zero sample-input Map); signature
  readers `MapInElem`/`MapOutElem`/`MapInPort`/`MapOutPort`, `RateOutElem`;
  **`ParamPort(Block, name)`** minting `node.param.<name>`.

### Tests (Rule 14, two Yoneda dispatches, each loaded `zig-0-16`)
- `tests/type_machinery_test.zig` (60) — `Sample≡Frame(.mono)` identity,
  `ChannelLayout.count` arithmetic, the element-distinctness matrix (incl.
  same-count-different-identity, e.g. `stereo` vs `discrete(2)`), `typeName`
  uniqueness, planar `@sizeOf`, `numericFor` exhaustiveness + Acc/saturate laws.
- `tests/port_machinery_test.zig` (33 live + 9 disabled `@compileError` stubs) —
  classifier truth table (Map/Rate/VariRate, R1/V1 rejection as disabled stubs),
  Source detection, PortId identity/distinctness, param-port mint, 8-port ceiling.

---

## 4. Key decisions surfaced (Rules 7 / 11)

1. **Skeleton disposition.** `graph.zig`, `commit.zig` are kept as the
   **Phase-3 throwaway** baseline (the comptime IR + commit pass) and `mux.zig` as
   the **P2** seam; only patched enough to stay green: the count-based
   `Frame(_, N)` → layout-based `Frame(_, .stereo)` in their internal tests, and
   one `typeName` string (`"Frame(f32,1)"` → `"Frame(f32,mono)"`). Their *logic*
   is unchanged; their **doc-comments were reworded for §0.2 compliance** (no spec
   citations). **P3 rebuilds `commit.zig`/`graph.zig`; P2 completes `mux.zig`; P4
   the engine executor.** Do not treat their current contents as final.
2. **`typeName` format changed** to `Frame(<lane>,<layoutname>)` (e.g.
   `Frame(f32,mono)`, `Frame(f32,stereo)`, `Frame(i16,discrete4)`) to make layout
   identity visible. The `elem_name` *string literals* in `commit.zig`'s
   hand-built-edge tests are arbitrary labels, not `typeName` comparisons — they
   were left as-is intentionally.
3. **Test-harness import wiring (both Yoneda writers hit this).** Zig 0.16
   forbids a harness module `@import`-ing a `../src/...` path that escapes its
   module root. **Resolution adopted:** each `tests/` harness is given the `pan`
   module as an import in `build.zig` and does `const pan = @import("pan"); const
   port = pan.port;` etc. (One writer's symlink workaround `tests/_src` was
   removed.) **P2 harnesses must follow this same pattern** — import `pan`, not
   `../src`.

---

## 5. Deferred-item RESOLUTION map (all closed this pass)

Every item previously deferred has been implemented. Where bodies are stubs,
that is by design (Phase 0 pins the surface; the executor/control-plane land in
P3/P4/P5). The surface type-checks and is exercised by tests.

**Phase 0:**
- `Graph.init(alloc, cfg)` / `add(Block, params) → handle` / `connect` /
  `connectFeedback` / `commit() → Engine` / `deinit` — **done** in `builder.zig`
  (the DX `Graph`). The builder accumulates into the comptime IR and forwards to
  the commit pass; `summarize()` reports a per-edge baseline footprint (the
  colored-pool footprint lands with the runtime commit in P3).
- `Engine` struct + `init/start/stop/renderInto/renderOffline/renderToCompletion/
  schedule/sendEvent/telemetry/deinit` + `beginEdit→Edit.commit` — **done** in
  `engine.zig` as compiling stubs. `ExecutionMode`/`Threads`/`EngineOptions`/
  `Summary`/`Edit` pinned. (Plan said `runToCompletion`; DX said
  `renderToCompletion` — Rule 7: kept the DX name + `renderOffline`.)
- Control verbs: `set` (on the node handle), `schedule` (engine), `edit→commit`
  (`beginEdit`/`Edit`) — **done** (stubs).
- Mux family: `PullTestSampleMux` (functional dual-mux partner) and
  `RingSampleMux` (offline push stub) — **done** in `mux.zig`. P2 still owns the
  full demand-tracking executor bodies.
- `CONTRIBUTING.md` (§0.2/§0.3/§0.6 + Rules 13/14) — **done** at project root.

**Phase 1:**
- `node.in(i)` indexed input accessor — **done** (`MapInPortAt`, handle `in(i)`).
- `node.in.<name>` named input accessor — **done** (`NamedInPort`, the fan-in
  handle's `in` named accessor).
- `Concat(spec)` minting — **done**: `port.ConcatOut`/`port.NamedInPort` +
  `combinators.Concat(spec)` (stub kernel; full block at P9).
- Build-time monomorph logging — **done**: `build.zig` imports
  `numeric.monomorph_count` and prints `"pan build: N active precision
  monomorphs per kernel"` on every build (Rule 12).
- Bare-array element guard — **done**: `portOfParam` rejects an `.array` element
  with a named diagnostic.
- `numericFor` is now **2-arg** (`numericFor(p, .{})`) with `NumericOptions`
  (`width_override`), matching the DX doc.

**Still genuinely later (correctly out of scope for P0/P1):** the *real* runtime
commit pass + arena (P3), the wait-free executor + CoreAudio/control plane
(P4/P5), the full mux executor bodies (P2). The surface for all of these is
pinned and type-checks now.

---

## 6. What P2 needs (from `pan_implementation_plan.md` Phase 2)

> **Read first (per plan):** `catalog.md` §4 (the seam + mux family),
> `pan_execution_model.md` §3 (the `PullSampleMux` 10-method semantics),
> `pan_testing_and_vector_contract.md` (all — §1 tolerance, §2 pan-vs-pan
> bit-exact, §3 generate-on-demand, §4 manifest schema, §5 harnesses, §6 CI
> matrix, §7 Yoneda contract + `tests/` layout), skill ch.05 (allocators,
> leak detection, `FailingAllocator`).

P2 = the `SampleMux` seam + the entire test backbone, stood up before any DSP:
1. **`src/mux.zig`**: complete the 10-method `SampleMux` vtable and the family —
   `TestSampleMux`, **`PullTestSampleMux`**, `PullSampleMux`, **`RingSampleMux`**
   (interface present; body filled at P14). Build the two missing muxes flagged
   in §5. Type-erased `ptr + *const VTable` (skill ch.02 §12).
2. **`tests/` harness drivers** (compiling, per testing-spec §5): `gold_vector`,
   `dual_mux`, `bc_differential` (mode B baseline + paranoid NaN), `aliasing`,
   `latency_contract`, `state_granularity`, plus the comparator
   (`allcloseF32`/`bitExact`/`alignByLatency`/`measuredGroupDelay`) and the
   `Tolerance` union. **Import the `pan` module (see §4, decision 3), not
   `../src`.**
3. **`tests/vectors/*.json`** manifest schema + validate the existing
   `gain_f32.json`; blobs are gitignored already (`.gitignore` covers
   `tests/vectors/**/*.bin|raw|pcm|npy`).
4. **`scripts/generate.py`** — deterministic SciPy/NumPy oracle generator
   (`numpy.random.default_rng(seed)`, native-endian raw blobs, manifest-driven,
   byte-reproducible across runs) + the q15 fixed-point path.

**P2 gate:** `TestSampleMux`/`PullTestSampleMux` round-trip bytes through the
vtable; `generate.py` reproduces byte-identical blobs across two runs; the
harness drivers compile and run green on the identity/passthrough block.

`scripts/` audio-format→LPCM decoders (part of P17) may ride with P2 — same
decoder muscle as `generate.py`, no late-game dependency.

---

## 7. Conventions carried forward (every phase)

- **§0.2** — in-code docs are self-contained; **no `specifications/*.md`
  references from `src/`**. (Test *names* may cite catalog laws, e.g.
  `test "... (catalog §2.6, ⊢)"` — that is correct, per §0.4.)
- **§0.3** — correctness-tier markers `⊢` (proven/decidable-static) / `≈` (tested)
  / `▷` (conventional). "The test is the proof" is banned.
- **§0.5** — pan-vs-external-oracle: allclose (float) / bit-exact (int). All other
  harnesses (pan-vs-pan): **always bit-exact**.
- **§0.6** — every harness runs Debug + ReleaseSafe minimum;
  `guards_compiled_out` telemetry must match the build mode.
- **Rule 13** — load `zig-0-16` before any Zig; **tell every dispatched subagent
  to load it too**; verify by compiling against 0.16.0.
- **Rule 14** — dispatch Yoneda test-writers at each gate; give them the code
  section + invariant, never the specific tests.
- **Rule 10** — checkpoint after each significant step.

---

## 8. File map (this session's deltas)

```
build.zig              (M)  module-centric; CLI, smoke, docs, fmt-check, steps; monomorph log
build.zig.zon          (M)  .paths += CONTRIBUTING.md/tests/scripts/examples/include
CONTRIBUTING.md        (NEW) §0.2/§0.3/§0.6 conventions + Rules 13/14
src/root.zig           (M)  full pinned surface (Graph=builder, Engine, muxes, Concat) + smoke gate
src/pan.zig            (DEL) → root.zig
src/main.zig           (NEW) CLI
src/smoke_freestanding.zig (NEW) freestanding ReleaseSmall comptime-commit object
src/config.zig         (NEW) Config (precision/sample_rate/block_size/channels)
src/numeric.zig        (M)  full Precision set; numericFor(p, opts); monomorph_count
src/types.zig          (M)  ChannelLayout + Frame(Lane,L); self-contained docs
src/port.zig           (M)  Map/Rate/VariRate + Source; indexed/named/param/Concat minting; array guard
src/builder.zig        (NEW) the DX Graph: init/add→handle/connect/commit→Engine; endpoints, accessors
src/engine.zig         (M)  Engine + ExecutionMode/Threads/Edit/Telemetry + verb stubs; keeps free renderInto
src/mux.zig            (M)  + PullTestSampleMux (functional) + RingSampleMux (stub); §0.2 doc cleanup (P2 completes)
src/graph.zig          (M)  the comptime IR; count→layout test patch; §0.2 doc cleanup (P3 rebuilds)
src/commit.zig         (M)  count→layout test patch; §0.2 doc cleanup (P3 rebuilds)
tests/type_machinery_test.zig (NEW) 60 Yoneda tests (numericFor calls now 2-arg)
tests/port_machinery_test.zig (NEW) 33 Yoneda tests + 9 disabled @compileError stubs
```

> **Note on the two `Graph`s:** `pan.Graph` is the DX builder (`builder.zig`).
> The low-level comptime substrate is `pan.graph.Graph` (`graph.zig`, the IR the
> commit pass + smoke gate consume). P3 rebuilds the commit pass and folds the
> runtime path into the builder; the IR is the frozen ground-truth until then.
