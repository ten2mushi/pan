# pan — Implementation Plan (phase-by-phase, sequential)

> **Status:** implementation plan, derived 2026-06-03 from the LOCKED `specifications/` corpus.
> **Direction of truth:** the `specifications/` corpus is the single source of truth; this plan only
> *sequences the work of realising it*. Where this plan and a spec disagree, the spec wins and this
> plan is in error (`catalog.md` is authoritative; the hub conforms to it; every sibling conforms to
> the hub).
>
> **Toolchain:** `zig 0.16.0` exactly. Re-run `zig version` at the start of every session — the
> language drifts hard between releases (project Rule 13 / the `zig-0-16` skill). Any agent dispatched
> for a task that touches Zig **must** be told to load the `zig-0-16` skill (Rule 13).
>
> **Skeleton disposition (decided 2026-06-03):** the existing `src/{types,numeric,port,mux,graph,
> commit,engine,pan}.zig` is treated as **throwaway** — it compiles but uses a count-based
> `Frame(Lane, C)` instead of the spec's layout-based `Frame(Lane, L)`, has a Mode-B-only commit pass
> (no negotiation / topo / liveness / coloring / PDC), and stub kernels. Phase 0 pins the full public
> API surface in `root.zig`; subsequent phases rebuild `src/` against it, reusing skeleton code only
> where it already matches the spec. The green smoke gate (`commitComptime` at comptime in
> `ReleaseSmall`) is preserved/restored as early as Phase 3 and kept green thereafter.

---

## 0. How to use this plan

### 0.1 Reading discipline (no delegation of understanding)

Each phase below names, by **`file §section`** (or `file:line-range`), the exact spec passages to read
*before* writing that phase's code. The implementer reads them directly — understanding is **not**
delegated. The only delegation is **test authoring** (Rule 14, §0.4): autonomous Yoneda test-writers
are dispatched at each gate, given the *code section to test*, never the tests to write.

The reading order of the corpus itself is LOCKED (`SPEC_INDEX.md`): `catalog.md` first (single source
of truth), then the hub `pan_architecture_formalisation.md`, then its siblings. This plan assumes that
corpus has been read once end-to-end; the per-phase citations are the *re-reads* for each task.

### 0.2 Code-documentation rule (LOAD-BEARING — applies to every phase)

> **In-code documentation must be self-contained. Code comments and doc-comments MUST NOT reference
> the `specifications/*.md` files (no "see catalog §7.2", no `[mem §6.1]`).** Instead, *restate inline*
> the law, invariant, rationale, ordering, or formula that the code realises, in plain prose, so the
> source is understandable without the spec open.

Concretely: where a spec section motivates code, the doc-comment paraphrases the motivating content
(e.g. "A feedback cycle is legal only if it contains at least one unit delay, because the fixpoint of
the loop is only well-defined when this period's output depends solely on previous periods' looped
values"), and may cite a *named law in words* ("the delay-free-loop rule") but **not** a markdown
section number or filename. This keeps `src/` decoupled from the spec's section numbering and readable
on its own. The spec citations live in this plan and in the **test names** (§0.4), not in `src/`.

### 0.3 The correctness-tier discipline (Rule 12 vocabulary — every phase)

Every correctness-bearing claim carries exactly one marker, and the code/tests must not mislabel:

- **⊢ proven-by-construction / decidable-static** — guaranteed before any code runs (Zig's type system,
  a `@compileError`, or a decidable comptime/commit-time check).
- **≈ tested (empirical)** — rests on running code against an oracle or a differential check; shows
  *presence* of bugs, never *absence*.
- **▷ conventional (authoring obligation)** — rests on an author obeying a rule the system can't enforce.

The phrase "the test is the proof" is **banned**. Say "proven ⊢ at comptime/commit", "the primary
correctness check ≈ is the B≡C differential test", "a conventional obligation ▷ tested by …". A test
is evidence, not a proof.

### 0.4 Testing gates (Rule 9 + Rule 14 — every implementation gate)

At the end of every phase that lands a feature, **dispatch Yoneda test-writers** (`Task` →
`yoneda-test-writer`). Each dispatch message must:
1. Instruct the agent to **load the `zig-0-16` skill** (Rule 13) and verify by compiling against
   `zig 0.16.0`.
2. Give the agent the **code section(s) under test and the invariant/oracle**, plus where to place the
   test file (for coherence: `tests/<harness>_test.zig`, naming convention in §0.6) — **not** the
   specific tests to implement. The agent decides cases, signals, and edge conditions autonomously.
3. State the comparison mode it must use (tolerance vs bit-exact, §0.5).
4. Forbid the agent from editing `src/` block code or the gold-vector manifests' contract.

Tests assert intent against the **independent** SciPy/NumPy oracle (Rule 9) — never against pan's own
output. Test names encode the gate and the catalog citation, e.g.
`test "B≡C: colored pool ≡ per-edge buffers, bit-exact (catalog §7.5)"`.

### 0.5 The two comparison modes (LOCKED — `pan_testing_and_vector_contract.md` §1–§2)

- **pan-vs-external-oracle** (gold vectors only): `numpy.allclose` for float lanes, **bit-exact** for
  integer/fixed-point lanes. `atol`/`rtol` carried per block in the manifest.
- **pan-vs-pan** (every other harness — B≡C, dual-mux, aliasing, state-granularity, parallel≡sequential,
  offline differential, codec round-trip): **always bit-exact**, regardless of lane type. Tolerance
  forgives the oracle's different arithmetic; it never forgives pan disagreeing with itself.

### 0.6 Build / CI matrix (LOCKED — `pan_testing_and_vector_contract.md` §6)

Every harness runs across all four build modes; the matrix is the discharge surface for the ≈ ledger:

| Mode | Asserts | NaN guards | Paranoid pool mode | Role |
|---|---|---|---|---|
| Debug | on | on | on | primary correctness; UAF/leak detection |
| ReleaseSafe | on | on | on | release-shaped codegen with safety; default CI gate |
| ReleaseFast | off | off | off | hot-path build; perf + tests pass with safety stripped |
| ReleaseSmall (freestanding) | off | off | off | the comptime-commit smoke gate |

`guards_compiled_out: bool` telemetry must match the build mode; the suite asserts it (Rule 12: never
silently drop a safety net). Run the suite in Debug *and* ReleaseSafe minimum; the paranoid run is
Debug/ReleaseSafe only.

### 0.7 Layout & naming conventions (project + skill)

- Library root = `src/root.zig`; CLI = `src/main.zig` (Zig build convention). Submodules
  `snake_case.zig`; a file whose top level *is* a type is `PascalCase.zig`.
- Types/`type`-returning fns: `PascalCase`; functions: `camelCase`; values/fields: `snake_case`;
  acronyms as words (`Io`, not `IO`). `usingnamespace` is gone — explicit `pub const x = @import(...).x;`.
- `zig fmt --check .` is a required CI gate.
- Project tree per `pan_io_realtime_and_pipeline.md` §5 + skill ch.06:
  `src/`, `include/`, `vendor/`, `tests/`, `examples/`, `scripts/`, `tools/`.

### 0.8 Conflicts surfaced (Rule 7 — read before Phases 17–19)

Per the 2026-06-03 scoping decision, this plan includes **full implementation phases for items the
spec corpus itself LOCKS as deferred / out-of-scope.** These phases (17–19) therefore go **beyond the
spec**, and the spec is otherwise the single source of truth. Each such phase opens with a
**spec-conflict banner** stating which LOCKED decision it overrides and that the override requires a
**spec amendment first** (code conforms to the spec, not the reverse — so the amendment lands in the
same change as the feature). The conflicting LOCKED decisions are: property-based harness + TLA+/Lean +
Flocq (`catalog.md` §13), automatic loop-fusion (`catalog.md` T2 / `pan_memory_model.md` §5), the
block-size-1 subgraph combinator (`catalog.md` §5.4), and the concrete-MCU target
(`catalog.md` §9.3 locks "target-generic / freestanding stub").

### 0.9 The benchmark surface (measurement, not correctness — stood up from Phase 4)

Alongside the `tests/` correctness backbone, a **`bench/`** surface quantifies the brief's four core
requirements — **maximize throughput, minimize latency, minimize memory, minimize disk** — against real
committed plans. A benchmark **measures**; it never asserts an oracle match (correctness stays in
`tests/` under the ⊢/≈/▷ tiers; the zero-hot-path-allocation and footprint-is-comptime-constant
*assertions* live there, Yoneda-dispatched — a bench only reports numbers, never asserts inside timed
code where `assert` is a ReleaseFast no-op). It **stands up at Phase 4** — the first runnable DSP path,
the way the test backbone stood up at Phase 2: deferred until there is something to measure, then never
retrofitted. `bench/harness.zig` is the measurement kit (the bench analogue of `tests/harness.zig`; no
`test {}` blocks; self-contained docs per §0.2): the `std.Io.Clock` timer (`std.time.Timer` is removed
in 0.16.0), a result-consuming sink (defeat dead-code elimination), an instrumented counting allocator,
and a byte-traffic counter.

**Metrics.** *Throughput* — frames/s, samples/s/core, MB/s, × realtime (per-block and per-`renderInto`),
measured across varied contexts **including a stress / heavy-usage mode** (large graphs, max channel
counts, deep chains, high fan-out/fan-in, sustained load, worst-case topologies) so the library is
thoroughly stress-tested, not just measured on a happy-path slice. *Latency* — algorithmic (from the
commit pass) and wall-clock per-callback render time / deadline headroom (the sub-5 ms / zero-xrun
targets become tracked numbers). *Memory / byte displacement* — **both** quantities, reported
distinctly: (i) the static H2 **`Plan.footprint_bytes`** (catalog §7.8 formula; comptime constant for a
comptime graph), and (ii) **byte-displacement-per-render** (Σ over the op-list of bytes read + written)
— the dynamic cache-traffic that Mode-C coloring and loop-fusion reduce. (i) bounds the `.bss`/pool
budget; (ii) is what the optimizations move.

**Discipline (skill ch.04 §12).** Benchmark only in the shipped release modes (ReleaseFast primary;
ReleaseSafe to *price* the safety checks — both via LLVM, never Debug/self-hosted); warm up, many
iterations, report ns/iter + variance, consume every result; sweep the config axes pan is driven by —
precision × block size × channels. Each bench reads `engine.telemetry()` and reports `xrun_count`,
`deadline_headroom`, `per_block_cpu`, `spin_time`, `guards_compiled_out` next to its own wall-clock so
bench and engine self-telemetry cross-validate.

**Disk-minimal (requirement #4).** Results are printed/streamed, never committed; inputs are generated
deterministically (no committed blobs); only tiny scalar `bench/baselines/*.json` are committed.

**Cadence & gating.** `bench` is a top-level step building each `bench/*.zig` as a ReleaseFast executable
importing `pan` (`.paths += "bench"`). It runs **on-demand / nightly, not as the per-commit gate**
(timing on shared runners is noisy — the §0.6 four-mode correctness matrix stays the commit gate). An
opt-in `-Dbench-gate` compares against the committed baselines: **footprint regressions fail hard**
(deterministic), **throughput regressions fail outside a noise band**.

---

## Phase 0 — Build system, public API surface, conventions

**Goal.** A compiling project with the **full public API surface pinned in `src/root.zig`** (stub
bodies), the build graph (library + CLI + multi-target + test step), the freestanding `ReleaseSmall`
smoke target wired, and the code-doc/test conventions established. Nothing runs yet; the point is that
the pinned identifiers and the four-verb authoring arc compile and read correctly in Zig 0.16.0.

**Read first.**
- `pan_architecture_formalisation.md` §3 (C1–C8 the eight commitments), §4 (the shape), §5 (frozen core
  vs layered libraries).
- `pan_developer_experience.md` §0 (mental model), §3 (build/run a graph — the `Config`/`Graph`/
  `Engine` arc), §7 (mode selection at instantiation).
- `notes/implementation_readiness.md` §1.2 (pin the public API surface), §2.2 (align project layout),
  §3 (the "step 0" slice).
- `catalog.md` §1.2 (`Format` product object), §10 (the three control verbs), §11.2 (commitments).
- skill ch.06 (build.zig/build.zig.zon module-centric artifacts, `link_libc` field, `addLibrary`
  `.linkage`, `.name` enum literal, required `.fingerprint`).

**Work.**
1. `build.zig.zon`: keep `.name = .pan`, `.fingerprint`, `.minimum_zig_version = "0.16.0"`; `.paths`
   include `src`, `include`, `tests`, `scripts`, `examples`.
2. `build.zig`: library module `src/root.zig`; CLI `src/main.zig`; `b.standardTargetOptions`/
   `standardOptimizeOption`; a `test` step (one `addTest` per root module: lib + CLI); a `docs` step
   (`getEmittedDocs`); a **freestanding `ReleaseSmall`** target (`resolveTargetQuery` with
   `os_tag = .freestanding`) that builds the smoke-gate object; a `fmt-check` gate. Expose `run`/`test`/
   `docs`/`bench` top-level steps.
3. `src/root.zig` — pin the surface as stub decls (compile only):
   - `Config { precision: Precision, sample_rate: u32, block_size: usize, channels: ChannelLayout }`
     and `numericFor(comptime precision, opts) Numeric` (comptime switch — call site uses the
     `comptime` keyword; a desktop precision change requires recommit).
   - `Graph.init(alloc, cfg) / add(Block, params) → handle / connect(out, in) / connect(out, node.in(i))
     / connect(out, node.in.<name>) / connect(out, node.param.<name>) / connectFeedback(...) /
     commit() → Engine`. Multi-port `node.in(i)` / `node.in.<name>` typed `PortId`s; `node.param.<name>`.
     *(Note: `connectFeedback`'s z⁻¹ write/read-split contract — the back-edge's read side is satisfied
     from persistent state produced last block — is only finalized in Phase 6; the Phase-0 signature is
     provisional until the trace/SCC-has-delay law is read there.)*
   - `Engine.init(alloc, g, .{ .mode, .cores|.threads }) / start / stop / renderInto(token, mem, out) /
     renderOffline / runToCompletion / schedule / beginEdit→commit / sendEvent / telemetry()`.
   - Control verbs: `set` (atomic + ramp; **no `at_sample`** — sample-accuracy is a type-level omission),
     `schedule` (SPSC, sample-accurate), `edit→commit` (RCU).
   - Mux family names: `SampleMux`, `TestSampleMux`, `PullTestSampleMux`, `PullSampleMux`,
     `RingSampleMux`.
   - `enterRealtimeThread() RealtimeToken` (+ `token.leave()`); `Telemetry { xrun_count,
     deadline_headroom, guards_compiled_out, per_block_cpu, spin_time, … }`.
   - Namespaced library roots as empty stubs to be filled later: `io`, `filters`, `gen`, `env`, `fx`,
     `spectral`, `feat`, `mix`, `time`, `spatial`, `synth`, `combinators`, `realtime`.
4. `src/main.zig`: minimal CLI that builds a trivial graph and prints the commit log line (ops / pool
   bytes / max-live).
5. Establish `tests/` skeleton dirs and `.gitignore` for `tests/vectors/**/*.bin` (and `*.raw`/`*.pcm`/
   `*.npy`).
6. Write `CONTRIBUTING`-style notes capturing §0.2 (self-contained code docs), §0.3 (tier markers),
   §0.6 (CI matrix) so every later phase inherits them.

**Success criteria (gate).** `zig build`, `zig build test`, `zig build -Doptimize=ReleaseSmall`
(freestanding object) all succeed; `zig fmt --check .` clean; the pinned API compiles with stub bodies;
the DX `add/connect/commit/start` arc type-checks against the stubs.

**Yoneda dispatch.** None yet (no behaviour). Land a single sanity `test {}` (refAllDecls).

---

## Phase 1 — Core type system: Numeric, ChannelLayout, port elements, PortId, classifier

**Goal.** The load-bearing type machinery: the `Numeric` trait, the `ChannelLayout` identity descriptor,
the canonical port-element set keyed on `Frame(Lane, L)`, the typed `PortId`, and the comptime
classifier that discriminates `Map` / `Rate` / `VariRate` / `Source` by field presence. This is the
foundation every edge keys off (H3 is realised here).

**Read first.**
- `catalog.md` §1.2 (`Format`), §1.3 (canonical port elements + `ChannelLayout` L1/L2/L3 + the
  `Sample(T) ≡ Frame(Lane,.mono)` identity + `Bounded` liveness), §1.4 (Numeric trait), §2.1 (M1–M4 +
  Source SR1), §2.2 (R1–R5), §2.6 (`VariRate` V1–V5), §2.7 (Source SR1–SR3), §9 (precision/N/W
  asymmetry; locked defaults).
- `pan_type_and_numeric_model.md` §1 (typed ports, `ChannelLayout`, typed `PortId`, named `Concat`),
  §1.1 (parameter ports), §3 (precision/N/W), §4 (Numeric trait).
- `pan_execution_model.md` §2 (the two contracts + the Source refinement + `VariRate` §2.2.1), §8
  (what the spec pins: typed `PortId` derivation, 8-port ceiling via `u3`, parameter-port
  classification, Source classifier, `VariRate` field-presence discrimination).
- skill ch.02 (comptime, `@typeInfo` lowercase tags, `@Struct`/`@Int` constructors, `union(enum)`,
  packed/extern, `@hasDecl`/`@hasField`), ch.01 §8 (naming).

**Work (rebuild `src/types.zig`, `src/numeric.zig`, `src/port.zig`).**
1. `numeric.zig`: `Numeric { Lane: type, Acc: type, saturate: bool, W: comptime_int }`; `Precision`
   enum over the **full** locked set (`f32, f64, i8, i16/q15, i32/q31, i64`, extensible); `numericFor`
   comptime switch resolving `Acc`/`saturate` per precision (`i16→i32 sat`, `i32→i64`, `f*→same`) and
   `W` via `std.simd.suggestVectorLength(Lane) orelse 1`. Active-precision list as an explicit comptime
   array; log generated-monomorph count at build (Rule 12).
2. `types.zig`:
   - `ChannelLayout = union(enum) { mono, stereo, surround_5_1, surround_7_1, ambisonic: {order,
     ordering, norm}, discrete: u16, custom: {count, id} }` with `pub fn count()` ((order+1)² for
     ambisonic, etc.) and the **canonical channel-order** + positional-tag data needed by L1.
   - `Frame(comptime Lane, comptime L: ChannelLayout) → struct { ch: [L.count()]Lane }` (planar; named
     → has `typeName()`). `Sample(T) = Frame(T, .mono)` (⊢ identity).
   - `Complex(T)` (wraps `std.math.Complex(T)`, adds `typeName()`), `FeatureFrame(K)`, `Scalar(T)`,
     `Bounded(T, Kmax) { items: [Kmax]T, len: u16 }`. All non-primitive elements expose `typeName()`;
     a bare array element is rejected at comptime.
   - Pool-class key derivation `(element_type, element_count)` exposed as comptime decls.
3. `port.zig`:
   - `Direction { in, out }`; `PortIndex = u3` with `max_ports_per_direction = 8` and
     `checkPortCeiling` → readable `@compileError` past 8.
   - `PortId(NodeT, dir, ElemT)` carrying node identity + direction + element type; `isPortId`.
   - `classify(Block)` → `{ Map, Rate, VariRate }` by field presence: `out_per_in`+`pull`+
     `algorithmic_latency` ⇒ Rate (R1 build error if incomplete); `rate_bounds`+`max_latency` xor
     `out_per_in` ⇒ VariRate (V1); else `process` ⇒ Map. **Source** = zero sample-input ports (SR1/SR2)
     detected by the signature reader (empty `in` side ⇒ `out.len` from pull `N`).
   - Signature readers: `MapInElem`/`MapOutElem`/`MapInPort`/`MapOutPort`, plus the `pull` readers.
   - Named-spec minting: `node.in.<name>` (homogeneous `node.in(i)`), `node.param.<name>` from a
     `pub const params = .{ ... }` struct-of-(name→control-element), and the `Concat` spec minting.
     Wrong element type / wrong name / out-of-range index = ⊢ `@compileError` naming the port.

**Success criteria (gate).** Comptime tests: `Sample(f32) == Frame(f32,.mono)`; layout-identity
mismatch (count, position, or order) on a `connect` is a compile error; classifier returns the right
class for `Map`/`Rate`/`VariRate`/`Source` stubs and rejects a `Rate` missing `algorithmic_latency`
(R1) or a `VariRate` missing `max_latency` (V1); 9th port per direction is a compile error;
`node.param.<name>` mints a typed `PortId`. All evaluable at comptime.

**Yoneda dispatch.** Dispatch to author comptime tests for: the classifier truth table (incl. R1/V1
rejection), the `PortId` element-type/direction/8-port-ceiling checks, the `Sample≡Frame(.mono)`
identity, and the `ChannelLayout.count()` arithmetic. Invariant = the ⊢ laws A1/A2/A3/A6/A21/A23/A25.

---

## Phase 2 — SampleMux seam + test backbone + scripts/generate.py + manifests

**Goal.** The Yoneda/`SampleMux` probe (the only block↔transport seam) and the *entire test backbone*
stood up before any DSP exists, so it is never retrofitted (readiness §2.1). This phase makes the
gold-vector contract, the dual-mux probe, the B≡C differential harness (mode B baseline + paranoid
NaN), and the deterministic Python oracle generator real.

**Read first.**
- `catalog.md` §4 (the seam; the mux family table; the representable/Yoneda argument and its honest
  bound), §7.5 (B≡C honest split), §0.1 (oracle as external truth).
- `pan_execution_model.md` §3 (the `PullSampleMux` 10-method semantics table).
- `pan_testing_and_vector_contract.md` — all of it: §1 (tolerance policy), §2 (pan-vs-pan always
  bit-exact), §3 (generate-on-demand vector storage), §4 (manifest schema), §5 (every harness), §5.9
  (reference skeletons), §6 (CI matrix), §7 (Yoneda test-writer contract + tests/ layout).
- skill ch.05 (allocators; `std.testing.allocator` leak detection; `FailingAllocator`).

**Work.**
1. `src/mux.zig`: `SampleMux` 10-method vtable (`wait/get{Input,Output}Available`,
   `get{Input,Output}Buffer`, `update{Input,Output}Buffer`, `getNumReadersForOutput`, `setEOS`);
   `TestSampleMux` (push: exact bytes in/out), `PullTestSampleMux` (pull partner),
   `PullSampleMux` (synchronous-pull executor seam: `waitInput*` return immediately, `update*` no-op),
   `RingSampleMux` (offline push — interface present, body filled in Phase 14). Type-erased `ptr +
   *const VTable` (skill ch.02 §12 idiom; `@ptrCast(@alignCast(...))`).
2. `tests/` harness drivers (Zig 0.16, verified compiling), each per the testing spec §5:
   `gold_vector_test.zig` (§5.1), `dual_mux_test.zig` (§5.2, latency-aligned bit-exact),
   `bc_differential_test.zig` (§5.3, mode B vs mode C + paranoid NaN poison + the `aliasing_safe`
   quote-back failure message), `aliasing_test.zig` (§5.4), `latency_contract_test.zig` (§5.5),
   `state_granularity_test.zig` (§5.6). Include the comparator (`allcloseF32`, `bitExact`,
   `alignByLatency`, `measuredGroupDelay`) and the `Tolerance` union.
3. `tests/vectors/*.json` manifest schema + the `gain_f32.json` example (already present — validate
   against schema). `.gitignore` blobs.
4. `scripts/generate.py`: deterministic SciPy/NumPy oracle generator — `numpy.random.default_rng(seed)`,
   explicit dtype, native-endian raw blobs, manifest-driven; reproduces `input.bin`/`expected.bin` from
   `(manifest, seed)`. Add the fixed-point (q15) generation path with identical fixed-point semantics
   (bit-exact contract). Optionally a `zig build` pre-step that invokes it.

**Success criteria (gate).** `TestSampleMux`/`PullTestSampleMux` round-trip bytes through the vtable;
`generate.py` reproduces byte-identical blobs across two runs; the harness drivers compile and run
green on the (currently trivial / identity) blocks; mode-B baseline established.

**Yoneda dispatch.** Dispatch to harden each harness driver against the identity/passthrough block
(the only block that exists), and to verify the generator's determinism contract (▷+≈). Invariant =
the §5 harness contracts; comparison modes per §0.5.

---

## Phase 3 — The commit pass (offline, comptime-evaluable) with Mode-B buffers

**Goal.** The graph→op-list compiler to pseudocode precision, **comptime-evaluable**, with **Mode-B
per-edge buffer assignment** (the obviously-correct baseline; coloring/Mode-C lands in Phase 7) so a
runnable `Plan` exists. Stages that don't need liveness/coloring land here: format-negotiate (layout
identity), topo + source-rooted check, SCC-has-delay, rate-scheduling, op-list emit, footprint. The
embedded comptime-commit smoke gate is restored and kept green.

**Read first.**
- `pan_commit_pass_algorithms.md` — all of it: §0 (stage order), §1 (`CommittedGraph`/`Node`/`Edge`/
  `FeedbackEdge`), §1 pre-stage (format-negotiate + parameter one-source check), §2 (Kahn + NodeId
  tie-break + source-rooted SR3 → `error.UnrootedPath`/`error.UndeclaredCycle`), §5 (Tarjan SCC-has-
  delay → `error.DelayFreeLoop` naming cycle), §7 (rate scheduling: `needed_input`→`n_or_pull_spec`,
  Source `out.len` from N, `VariRate` min-ratio, H∤N ring), §8 (emit + N-independent buffer-id), §9
  (footprint formula), §10–§12 (worked examples A/B/C), §13 (comptime-evaluability constraints + smoke
  gate; the `isize` sentinel free-color-table detail).
- `catalog.md` §5.2 (trace/SCC-has-delay law), §6 (negotiation as unification; coercion table; L1/L2),
  §7.8 (footprint), §8.2 (commit-pass order), §8.5 (comptime-commit obligation + honest bound).
- `pan_memory_model.md` §6.1 (z⁻¹ split), §7 (PDC — *read for shape*; insertion lands in Phase 8).
- skill ch.02 (comptime loops/`@Struct`), ch.04 (bounds-check elimination, comptime tables), ch.01
  (error sets, `error.X`).

**Work (rebuild `src/commit.zig` + supporting).**
1. `CommittedGraph`/`Node`/`Edge`/`FeedbackEdge` data shapes; `RenderOp { fn_ptr, self_ptr,
   input_buffer_ids[], output_buffer_ids[], n_or_pull_spec }`; `Plan(n_ops) { ops, op_count,
   footprint_bytes }`; `CommitError`.
2. **Format-negotiate pre-stage**: unify `Format` along edges on **layout identity `L`** (count +
   position + order, L1); insert coercion morphisms where compatible-but-coercible (resampler / **
   registered** up/down-mix matrix / cast / framer / **parameter ramp-hold**); reject **unregistered**
   layout pairs as hard mismatch (L2) and the parameter **one-source** violation (P2). (Matrix numerics
   and resampler insertion-on-runtime land in Phases 5/8/16; here the *insertion decision* + the ⊢
   identity check.)
3. **Topo** (Kahn on DAG-minus-feedback, min-`NodeId` priority tie-break → bit-reproducible op-list) +
   **source-rooted SR3** scan (`error.UnrootedPath`) + `error.UndeclaredCycle`.
4. **SCC-has-delay** (Tarjan on the *full* graph incl. feedback; delay-membership scan →
   `error.DelayFreeLoop` naming the cycle, with the inline-restated rationale per §0.2).
5. **Rate-scheduling**: demand propagation (reverse topo) compiling `needed_input(want)` into each op's
   `n_or_pull_spec`; Source generator `out.len` from pull `N` (SR1); `VariRate` sizes on `min` ratio
   (V2); H∤N absorbed by the block ring; sub-block parameterised by length.
6. **Emit** (forward-topo) + Mode-B buffer-id assignment (one buffer per edge; persistent buffers in
   the pool-excluded region) + **footprint** (the H2 formula; comptime constant for a comptime graph).
7. **Comptime-evaluability**: fixed-size scratch sized by comptime graph dims; `isize` sentinel
   free-color table; no allocator escaping comptime; `comptime_commit_safe` pan-level error for a
   non-comptime-evaluable block. Restore the **smoke gate** in `root.zig` (I2S source→gain→I2S sink at
   comptime; `footprint_bytes` usable as an array length).

**Success criteria (gate).** Worked examples B (feedback comb) and C (rejected delay-free loop) from
`pan_commit_pass_algorithms.md` §11–§12 reproduce exactly (correct topo, SCC accept/reject, footprint
number); the smoke gate compiles in `ReleaseSmall` freestanding; `commitComptime` runs at comptime;
`error.DelayFreeLoop`/`error.UnrootedPath`/`error.UndeclaredCycle` fire on the right graphs.

**Yoneda dispatch.** Dispatch for: the SCC-has-delay validator (assert the error on worked example C),
the Kahn determinism + source-rooted check, the footprint comptime-constant property, and the
comptime-commit smoke gate (compiling = discharge ⊢ for the smoke graph). Tell them to compile at
`comptime` against 0.16.0 per the §13 constraints.

---

## Phase 4 — Tier A executor, RT token, first DSP blocks, the CoreAudio vertical slice

**Goal.** **Roadmap step 1** (`pan_categorical_bridge_and_roadmap.md` §5): the synchronous pull
executor + the callback render path, end-to-end on M3 — CoreAudio sink + LPCM source + a 3-block pure
`Map` chain (gain → biquad → pan) on Tier A + pool Mode-B. Sub-5 ms, zero xruns, oracle-matching output.

**Read first.**
- `pan_execution_model.md` §1 (callback contract + latency theorems), §3 (`PullSampleMux`), §4 (op-list
  replay; sub-block), §5 (Tier A frozen core), §6 (clock-driven pull roots), §7 (error isolation).
- `pan_io_realtime_and_pipeline.md` §3 (denormals/NaN; the **required realtime token** + ARM64 FPCR
  per-thread footgun), §4 (dither & gain staging), §5 (LPCM codecs + channel-order reconciliation;
  off-thread prefetch), §10 (telemetry: xrun counters, headroom, `guards_compiled_out`), §11 (Compute
  HAL `@Vector(W,T)`; I/O HAL CoreAudio).
- `catalog.md` §8.1–§8.3 (callback contract, op-list, pull roots), §10 (FTZ token; control plane
  terms), §11.1 (H1–H3).
- `pan_developer_experience.md` §1 (Gain/Pan authoring), §3 (build/run), §4 (verdicts).
- skill ch.04 (SIMD `@Vector`/`@reduce`/`@select`, `@splat`, scalar tail, `@setRuntimeSafety` hot
  loops), ch.03 (FTZ-adjacent safety; `@setRuntimeSafety`), ch.06 (C interop `extern`/`callconv(.c)`
  for CoreAudio).

**Work.**
1. `src/engine.zig`: `renderInto(token, mem, out)` replaying `plan.ops` wait-free; `RealtimeToken` +
   `enterRealtimeThread()` setting **FPCR FZ/AH on ARM64** (and MXCSR on x86), `token.leave()`;
   `renderInto` won't compile without the token (⊢). `Engine.init(mode=.realtime_streaming, .cores=1)`
   = Tier A; `start`/`stop`; `Telemetry` struct + xrun/headroom/`guards_compiled_out` (NaN guards in
   Debug/ReleaseSafe, compiled out in release with the telemetry bool). Error isolation: a faulting
   block emits silence + raises a flag (exec §7).
2. DSP blocks (`src/filters.zig`, `src/spatial.zig`): `Gain(Num)` (`aliasing_safe`, `@Vector` kernel +
   scalar tail), `Biquad(Num, kind)` (Map, per-sample `z⁻¹` Mealy state — *not* `aliasing_safe`),
   `ConstantPowerPan(Num)` (`.mono → .stereo`, layout-changing).
3. I/O HAL (`src/io.zig`): `LpcmSource` + LPCM boundary codecs (interleaved↔planar, 14 PCM formats +
   `i24` packed + float PCM, endianness, **channel-order reconciliation** to `L`'s canonical order —
   ⊢ bijective permutation, ≈ bytes, + dither/noise-shaping on down-bit conversion); `CoreAudioSink`/
   `CoreAudioSource` via `extern`/`callconv(.c)` (the device callback mints the token and is the RT
   `PullRoot`).
4. **Linux I/O HAL behind the same seam (architecture-accounted, testing-deferred per the brief).**
   The brief mandates the I/O HAL run on M3 **and Linux** and embedded, with Linux/embedded *testing*
   deferred but the platforms *architecturally accounted for*. Stand up an ALSA-baseline backend
   (PipeWire/JACK hooks) implementing the *same* I/O-HAL interface as `CoreAudioSink`, and make it
   **cross-compile** (`zig build -Dtarget=x86_64-linux-gnu`). Validating the seam with **≥2 desktop
   backends** before assuming portability is the whole point — the architecture exists to contain that
   risk; a single CoreAudio implementation would leave the abstraction unexercised. On-device Linux
   testing is deferred (dev is M3); the compile-and-cross-compile gate stands in for it.
5. Compute HAL: `@Vector(W,T)` kernels with `W` from the Numeric trait; document the optional
   runtime-discovered accel slot (vDSP/FFTW) as a later hook.
6. Gold vectors for Gain/Biquad/Pan via `generate.py` (SciPy `lfilter`/`firwin`/constant-power oracle).

**Success criteria (gate — roadmap step 1).** Sub-5 ms measured round-trip on M3; **zero xruns over 10
min**; gain→biquad→pan output matches the SciPy oracle within declared tolerance (bit-exact for
fixed-point); B≡C bit-identical (Mode B vs the still-trivial Mode-C path); FTZ confirmed set on the
audio thread; footprint reported at commit; **the Linux ALSA backend cross-compiles behind the same
I/O-HAL seam** (`-Dtarget=x86_64-linux-gnu`), proving the abstraction holds for ≥2 desktop backends.

**Yoneda dispatch.** Gold-vector + dual-mux + state-granularity for Gain/Biquad/Pan; the realtime-token
requirement (won't compile without it, ⊢); the LPCM codec channel-order round-trip (bit-exact
permutation). Oracle = SciPy.

**Benchmark (surface stand-up — §0.9).** Replace the placeholder `bench` step and add `bench/` +
`bench/harness.zig` (ReleaseFast default, `.paths += "bench"`, opt-in `-Dbench-gate`). First numbers:
per-block ns/iter → frames/s + MB/s for gain/biquad/pan; the 3-block chain per-`renderInto` time vs the
N/Fs deadline (sub-5 ms headroom on M3); the static `footprint_bytes` baseline (covering the P3 commit
output) **and** byte-displacement-per-render; a **stress-mode** throughput run (deep chains / max
channels / sustained load). Sweep precision × block size × channels; cross-check
`telemetry().deadline_headroom`.

---

## Phase 4.5 — Planar (SoA) conformance (core throughput requirement; do BEFORE more blocks land)

**Why now (not later).** The internal channel form is **LOCKED PLANAR and now STRICTLY ENFORCED**
(`catalog.md` §9.3 P-1/P-2, `pan_type_and_numeric_model.md` §2.1): a multi-channel stream buffer is
`C` contiguous `N`-sample **planes** (plane-major), not `[]Frame` interleaved. P1 implemented the
element as `Frame = struct { ch: [C]Lane }`, so a `[]Frame` buffer is **AoS/interleaved for `C > 1`** —
**non-conformant**. This is a **core throughput requirement** (per-channel `@Vector` kernels want a
contiguous plane); converting it **now** (a handful of blocks) is far cheaper than after the spatial
library lands dozens of multi-channel blocks. Mono (`C = 1`) is already conformant (one plane), so the
real work is concentrated at `C > 1`.

**What is and isn't affected (the load-bearing scoping insight).**
- **UNAFFECTED — the commit pass, footprint, coloring, H2.** Commit deals in buffer ids + byte lengths
  and is **layout-agnostic**: a planar stereo buffer and an interleaved one are both `C·N·sizeof(Lane)`
  bytes, so `footprint_bytes` and the buffer-id map are unchanged. The class key already encodes `L`
  (`elem_name`). Expect ~0 change in `src/commit.zig`.
- **UNAFFECTED — mono.** `Sample(T) = Frame(T,.mono)` is one plane; all the mono blocks/sources/sinks
  and the mono test surface are already planar-conformant.
- **AFFECTED — the element/port view + the `C > 1` surfaces.** This is the work.

**Work.**
1. **A planar buffer/port view** (`src/types.zig` + `src/port.zig`): introduce the planar view a block
   sees — `C` contiguous `[]Lane` planes over a buffer (e.g. `Planar(Lane, L)` exposing `plane(c) []Lane`;
   mono degenerates to a single `[]Lane`). `Frame(Lane, L)` stays the **layout-identity** element for
   `connect`/`PortId`; the **port machinery** (`portOfParam`, `MapIn/OutElem`, the classifier) learns to
   read a `Planar` view param and recover `(Lane, L)` from it instead of `.pointer.child` of a `[]Frame`
   slice. *(Hardest piece — re-touches the P1-frozen type/port core; the conceptual centre of the
   rework.)*
2. **Convert the blocks + harness** (`filters.zig`, `spatial.zig`, `tests/harness.zig` Identity/Scale/
   Accumulator) to plane-wise access. Gain/Biquad are per-channel loops (mono unchanged); `ConstantPowerPan`
   gets *cleaner* (write the L-plane and R-plane directly).
3. **The executor** (`engine.zig`): build the `Planar` view from a pool buffer's planes (plane `c` at
   offset `c·N·sizeof(Lane)`) in the `runOp` gather/scatter; the rest of the op-list replay is unchanged.
4. **The codec** (`io.zig`): `deinterleave` device-interleaved → planar planes (a real transpose now);
   `interleave`/`interleaveShaped` planar → interleaved. This is the one place the transpose cost lands
   (I/O boundary only — by design).
5. **Conformance gate (P-2):** a comptime/`test` assertion that a multi-channel stream buffer is
   plane-major and that channel access is per-plane `[]Lane`, so an AoS regression fails loud.
6. **Tests, gold blobs, bench:** update the `C > 1` test constructions; regenerate the **pan** gold
   blobs (stereo `expected.bin` becomes `[L-plane][R-plane]`, not `[L,R,L,R]`); `generate.py` `_ref_pan`/
   `_fix_pan` emit plane-major for `C > 1`; bench pan→sink handling. Mono gold (gain/biquad) unaffected.

**Rework estimate (so it is scheduled, not drifted).** ~**1,000–1,500 LOC** across ~**12–18 files**,
**1 focused session**, **MEDIUM-HIGH risk** (it re-opens the frozen P1 type/port core; the port-view
change in item 1 is the only genuinely-hard part — the rest is mechanical). Test churn is the bulk but
concentrated at `C > 1`; the heavily-affected Yoneda suites (dual-mux, comparator, gold-vector, spatial,
io) likely warrant **Yoneda re-dispatch** rather than hand-editing. Re-verify the full four-mode matrix
+ smoke + cross-linux + bench. **Cost grows with every later phase that adds a multi-channel block — so
this phase runs before Phase 5 proceeds.**

**Success criteria (gate).** Multi-channel buffers are plane-major (conformance gate ⊢/≈, green);
`ConstantPowerPan` output is two planes, not interleaved frames; the codec transposes interleaved↔planar
only at the boundary; the four-mode matrix + smoke + cross-linux stay green; gold/B≡C/dual-mux re-pass
under the planar layout; `footprint_bytes` is unchanged (proving the commit pass was layout-agnostic).

**Yoneda dispatch.** Re-dispatch the planar-touched harnesses (dual-mux push≡pull, gold-vector, spatial,
io codec round-trip) against the planar view; a new conformance harness asserting plane-major layout.

---

## Phase 5 — Format negotiation (runtime) + lock-free control plane + ramped parameter

**Goal.** **Roadmap step 2** + the parameter-port machinery: the three control verbs at exact atomic
orderings, runtime format negotiation (auto-resampler on rate mismatch), and one ramped parameter,
zipper-free, with no audio-thread lock.

**Read first.**
- `pan_concurrency_and_memory_ordering.md` — all of it: §0–§1 (two threads, SPSC, the funnel), §2 (the
  SPSC `schedule` ring with exact P1–P4 / C1–C4 orderings), §3 (`set` atomic scalar + `.monotonic`
  justification; not sample-accurate by contract), §4 (RCU plan swap; epoch reclamation; single-writer
  ⇒ no ABA), §5 (the H1 wait-freedom argument), §6 (Zig 0.16.0 atomics reference — `@atomicRmw` op
  capitalization, `AtomicOrder` lowercase, `std.atomic.Value`, `std.atomic.cache_line`).
- `pan_io_realtime_and_pipeline.md` §7 (control plane: three verbs ↔ three mechanisms; `set` rejects
  `at_sample`; `set`/`schedule` xor wired edge; bypass-preserves-latency), §1–§2 (SRC as a boundary
  citizen — the resampler primitive; full design lands in Phases 8/12).
- `catalog.md` §2.4 (parameter ports P1–P4), §6 (negotiation; ramp/hold coercion), §10 (control verbs).
- `pan_type_and_numeric_model.md` §1.1 (parameter ports), §2 (negotiation pass).
- skill ch.03 §11 (atomics, `std.atomic.Value`, memory orders), ch.05 (allocator for off-thread plan
  build).

**Work.**
1. `src/control.zig`: SPSC `CommandRing(Cmd, capacity)` (power-of-two, cache-line-padded head/tail,
   P1–P4/C1–C4 orderings) → the `schedule` verb (sample-accurate, drained at sub-block boundaries);
   atomic scalar `set` (`.monotonic` store/load + per-block ramp); RCU `commitPlan` (release store) +
   quiescent-state epoch reclamation (`+2` bound) → the `edit→commit` verb. The funnel contract
   (single designated control thread; ▷ obligation, ThreadSanitizer-tested).
2. **Parameter ports**: ramp/hold coercion node insertion at negotiate; one-source enforcement (P2,
   commit error); parameter edge as ordinary edge for color/schedule/SCC (P4); ramp/hold *state*
   persistent (Phase 6 owns persistent category, but reserve it here).
3. Runtime format negotiation: auto-insert a resampler on a wired sample-rate mismatch; precision casts;
   the parameter ramp/hold coercion. (Polyphase sinc resampler block itself = Phase 8.)
4. Per-block ramp policy (pipeline-wide "ramp, never step": bypass/mute/solo/start-stop).
   Bypass-preserves-latency law (commit warning where detectable; full PDC routing in Phase 8).
5. Device-reconfiguration protocol (re-negotiate, re-size pool backing bytes to max-N, rebuild +
   atomic-swap) — desktop (io §8); the assignment map is N-independent.
6. **Close the runtime `Engine` render path (carried from P4 — do this cleanly, not as a shim).**
   P4 left the runtime `Engine.{renderInto, start, stop}` as a *documented control-plane façade*: the
   runnable Tier-A renderer is the **comptime** `Executor`/`ExecutorMode` (it monomorphizes over a
   comptime graph + a node-id→block-type tuple, owns the pool, binds real `fn_ptr`/`self_ptr`, and
   replays the op-list wait-free). P5 makes the **runtime** `Engine` an equally-real engine by adding
   the **runtime commit pass** the RCU verb already needs: commit a *runtime-built* graph to a
   **heap-allocated `Plan`** whose ops carry **bound, type-erased `fn_ptr`/`self_ptr`** (the same
   op-list/pool-by-buffer-id shape the comptime `Executor` uses — reuse `RenderOp`/`Plan`, do not fork
   a second IR). Then `Engine.start` drives an `io.AudioBackend` whose render callback mints the token
   and replays the current plan; `Engine.renderInto(token, …)` is that replay over the engine-owned
   pool; `edit→commit` (item 1's RCU swap) atomically swaps the heap `Plan` pointer at a block
   boundary. **Elegance constraint (Rule 2/Rule 11):** the comptime and runtime paths must share the
   `RenderOp`/`Plan`/pool model and the gather/scatter logic — the only difference is comptime-inlined
   dispatch vs a bound `fn_ptr` indirect call; a faulting block still emits silence + raises the flag
   (exec §7), and FTZ is still token-gated. The comptime `Executor` remains the frozen Tier-A ground
   truth and the embedded path; the runtime `Engine` is its RCU-swappable desktop sibling. **Honest
   note (Rule 12):** this is the piece that lets the device gate (sub-5 ms / 10-min, P4's deferred
   on-device run) be driven through the public `Engine` API rather than a hand-wired `Executor`.

**Success criteria (gate — roadmap step 2 + 6c).** A wired rate-mismatch auto-inserts a resampler; a
parameter sweep is zipper-free and **bit-identical via `set` vs a wired parameter edge** (P3); no
audio-thread lock (ThreadSanitizer clean); declaring both `set` and a wired edge for one slot is a
commit error (P2); the SPSC ring + RCU swap pass under concurrent producer/consumer load (TSan);
**the runtime `Engine` render path is live** — a runtime-committed plan replays bit-identically to the
comptime `Executor` over the same graph (the runtime-commit ≡ comptime-commit differential), and an
`edit→commit` RCU swap rewires it with no glitch and no audio-thread allocation/lock.

**Yoneda dispatch.** Parameter-edge ramp/hold + one-source + delay-free-param-loop (§5.7b); the SPSC
ring and RCU swap under `-fsanitize-thread`; the `set`-rejects-`at_sample` ⊢ omission. Verify atomic
forms compile against 0.16.0.

---

## Phase 6 — Feedback primitives, persistent state, tight-feedback kernels

**Goal.** **Roadmap step 3**: the `z⁻¹`/feedback machinery end-to-end — element-generic
`UnitDelay`/`DelayLine`, the pool-excluded persistent category, the graph-level `DelayLine`-in-a-cycle
idiom, FDN matrix feedback, and the fused single-`Map` tight-feedback kernels (ladder / Karplus-Strong
/ comb). A comb reverb runs; a delay-free loop is rejected; denormals don't spike CPU.

**Read first.**
- `pan_memory_model.md` §5.5 *(via catalog)*, §6 (the z⁻¹ rule; the two feedback idioms; persistent
  buffers as state; state-update granularity S6), §6.1 (fused tight-feedback kernel), §6.2 (persistent
  category: delay lines, overlap rings, history, voice pools, assets, ramp/hold state).
- `catalog.md` §5 (trace/traced-monoidal feedback; §5.2 SCC-has-delay; §5.3 persistent pool-excluded;
  §5.4 two idioms; §5.5 element-generic `UnitDelay`/FDN over `Frame(.discrete(N))`).
- `pan_io_realtime_and_pipeline.md` §3 (denormals/FTZ in decaying feedback paths).
- skill ch.04 (cache layout for delay buffers; `@memcpy`/`@memset`), ch.05 (persistent allocation at
  `initialize`).

**Work (`src/time.zig`, `src/fx.zig`).**
1. Element-generic `UnitDelay(Elem)` / `DelayLine(Elem, len)` over `Sample`/`Frame`/`Complex`/
   `FeatureFrame`; allocated once at `initialize`, pool-excluded; frame-/spectrum-granular feedback
   (`UnitDelay(Complex)` for phase-vocoder accumulation, spectral flux as a graph edge).
2. The persistent-state category boundary in the commit pass (live range = whole callback; never
   colored; contributes the persistent/feedback term to the footprint). State-update granularity:
   history updates once per hop regardless of sub-block count (S6).
3. FDN reverb = N `DelayLine` nodes + a matrix-mix `Map` over `Frame(Lane,.discrete(N))` + feedback
   edges (SCC contains the delay lines ⇒ legal).
4. Fused tight-feedback `Map` kernels: ladder, Karplus-Strong, comb (per-sample feedback loop inside
   one rate-1:1 `process` over fixed persistent state; sample-accurate; **not** `aliasing_safe`;
   internal `z⁻¹` declared so SCC-has-delay sees it).
5. A comb/all-pass reverb assembled graph-level; FTZ confirmed preventing denormal spikes.

**Success criteria (gate — roadmap step 3).** A delay-free loop is rejected at commit
(`error.DelayFreeLoop`); the reverb tail is stable; denormals don't spike CPU (FTZ set); the
fused-kernel `z⁻¹` is sample-accurate; `UnitDelay` works across all four element types.

**Yoneda dispatch.** Feedback-SCC validator (assert the error), state-update-granularity (history once
per hop), reverb-tail stability, FTZ/denormal behaviour (≈). Oracle = SciPy for the LTI tails.

**Benchmark.** Persistent/feedback footprint term (delay-line bytes); fused tight-feedback kernel
throughput vs the graph-level idiom; the FTZ denormal CPU-spike avoidance measured on a decaying tail
(with/without FTZ).

---

## Phase 7 — Liveness + per-class left-edge coloring (Mode C) + in-place coalescing + B≡C

**Goal.** **Roadmap step 4**: turn on the colored pool (Mode C) behind the *same* `getBuffer(edge)`
interface, validated bit-identical to Mode B. This is the per-element-class interval coloring (C3) and
the gated in-place coalescing.

**Read first.**
- `pan_commit_pass_algorithms.md` §3 (liveness intervals; the end-inclusive convention; persistent set),
  §4 (per-class left-edge coloring; optimality import ⊢ vs B≡C ≈; FFD for heterogeneous counts; the
  3-condition + `aliasing_safe` in-place gate), §10 (worked example A coloring tables).
- `pan_memory_model.md` §1 (register-allocation framing), §2 (one pool per element-type-class), §3
  (in-place coalescing; the 3 conditions; `noalias` placement), §4 (fan-out/fan-in), §7.5 *(via
  catalog)*, §9 (the B≡C differential-test obligation + the `aliasing_safe` quote-back message), §10
  (footprint formula).
- `catalog.md` §7 (coloring as interference-graph coloring; §7.2 one pool per class + optimality; §7.3
  fan-out/in; §7.4 in-place gate; §7.5 honest split; §7.6 failure message; §7.8 footprint).
- skill ch.04 (bounds-check elimination, `noalias`, `@memcpy`), ch.02 (comptime arrays for the colorer).

**Work.**
1. Liveness pass: per-edge `[start, end]` intervals over op indices (fan-out → last reader; end-inclusive
   free-test `prev_end < this_start`); persistent set excluded.
2. Per-class left-edge colorer (group by `(element_type, element_count)`; across-class disjoint ⊢;
   linear-scan; FFD fallback for heterogeneous counts at M≤8). `M_class` = colors used.
3. In-place coalescing gate: (i) single consumer, (ii) identical element type & count in==out, (iii)
   consumer reads before any other producer overwrites — **and** the block declares `aliasing_safe`;
   `noalias` only on the proven-non-aliased path.
4. Wire Mode C behind `getBuffer(edge)`; keep Mode B as the differential baseline + paranoid NaN-poison.
5. The `aliasing_safe` quote-back failure message (names the assertion, first divergent sample, the fix).

**Success criteria (gate — roadmap step 4).** Mode C output **bit-identical** to Mode B across the
corpus; pool size = max-live-edges per class; paranoid mode finds no aliasing; worked example A's
`M_Sample=3`, `M_Complex=2` reproduced at comptime; a falsely-declared `aliasing_safe` block trips the
quote-back message.

**Yoneda dispatch.** B≡C differential (the *primary* colorer correctness check, ≈) + paranoid mode;
aliasing (in-place vs non-aliased) with the quote-back contract. Bit-exact (pan-vs-pan).

**Benchmark.** Flagship memory bench: Mode-B per-edge vs Mode-C pool **footprint** reduction % and the
**byte-displacement-per-render** reduction, behind the same `getBuffer(edge)` interface.

---

## Phase 8 — A `Rate` block + latency accounting + per-rate-domain PDC

**Goal.** **Roadmap step 5**: the dual contract proven at the rate-elastic seam — a `Framer`+STFT (or a
polyphase resampler) with declared `out_per_in` ≠ `algorithmic_latency`, dual-mux + latency-contract
passing, and PDC re-aligning a dry/wet FFT diamond sample-accurately.

> **PDC-deferral precondition (Rule 4).** PDC routing is built *here* and not earlier because **no graph
> in Phases 1–7 has a latency-mismatched fan-in**: the vertical slice (P4) and the feedback/coloring
> graphs (P6–P7) are linear or single-latency, so PDC is genuinely not needed before this phase. The
> first fan-in of unequal-latency branches is this phase's dry/wet diamond — which is exactly what makes
> deferring the longest-path DP to here safe rather than a missed dependency.

**Read first.**
- `pan_execution_model.md` §2.2 (`Rate` contract R1–R5), §2.3 (why Rate ≠ Map; multi-input pull rule),
  §4 (sub-block).
- `pan_commit_pass_algorithms.md` §6 (PDC longest-path DP; per-rate-domain conversion before `max`;
  comp-delay insertion from the persistent category; static-latency mandate; bypass-preserves-latency),
  §7 (rate scheduling), §10 (worked example A: the dry/wet FFT diamond, per-rate-domain PDC + coloring +
  footprint = 14352 B + Σ state).
- `pan_memory_model.md` §7 (PDC folded into the buffer-assignment pass; per-rate-domain).
- `catalog.md` §2.2 (R1–R5), §7.7 (PDC), §8.8 (multi-input pull rule).
- `pan_io_realtime_and_pipeline.md` §2 (SRC as boundary citizen; polyphase sinc resampler).
- `pan_testing_and_vector_contract.md` §5.5 (latency-contract), §5.2 (dual-mux).
- skill ch.04 (FFT-adjacent kernels; the optional vDSP/FFTW accel slot), ch.05 (overlap-ring state).

**Work (`src/spectral.zig`, extend `src/io.zig`).**
1. `Framer(Lane, FRAME, HOP)` (Rate; overlap ring; `out_per_in = 1:HOP`; `algorithmic_latency =
   FRAME-HOP`; `needed_input`/`pull`); `Stft`/`iStft` (Rate → `Complex` spectra; COLA pair latency);
   `PowerSpectrum` (Map `[]Complex → []f32`). A polyphase sinc resampler (Rate; declares latency).
2. PDC longest-path DP in the commit pass, **per rate-domain** (convert latency into the fan-in node's
   rate domain before `max`); insert compensating `DelayLine`s from the persistent category; static
   worst-case latency for `Rate` (and `max_latency` for `VariRate` in Phase 12). Bypass routes through
   the comp-delay.
3. Multi-input pull rule: independent per-edge `needed_input`; same-rate multi-input aligned by PDC;
   mixed-rate *sample* inputs require an explicit adapter (negotiation error otherwise) — only parameter
   ports auto-coerce.

**Success criteria (gate — roadmap step 5).** A dry/wet diamond around the FFT path re-aligns
sample-accurately (worked example A); the `Rate` block passes both muxes (dual-mux bit-exact modulo
latency) and the latency-contract (impulse group-delay == declared); a `Rate` missing a declaration is
a build error; `error.UndeclaredCycle` vs `error.DelayFreeLoop` distinguished.

**Yoneda dispatch.** Latency-contract (impulse group delay), dual-mux push↔pull for the `Framer`/STFT,
PDC arithmetic across the dry/wet diamond (≈ B6), `needed_input` monotonicity. Oracle = SciPy STFT/
resampler.

**Benchmark.** STFT/Framer throughput; the PDC comp-delay footprint term; measured impulse group-delay
as the latency number.

---

## Phase 9 — Analysis pull root, typed feature ports, Concat, FeatureCollectorSink, feature chains

**Goal.** **Roadmap step 6**: the Analyzer graph shape — a non-RT analysis pull root driving
file→features→collector, feeding the `notes/1.md` visualization, with **zero risk** of stealing an
audio deadline. Proves clock-driven roots (C5), typed feature ports, named `Concat`, and off-RT
collection.

**Read first.**
- `pan_execution_model.md` §6 (clock-driven pull roots; `PullRoot`/`ClockSource`; analysis sink on a
  non-RT thread; SPSC-ring taps; `FeatureCollectorSink` on RT root = commit error A8).
- `pan_type_and_numeric_model.md` §1 (typed feature ports; the named `Concat` whose output-struct field
  order is the canonical column order), §3.1 (two N-regimes: comptime-K for `FeatureFrame`).
- `catalog.md` §1.3 (`FeatureFrame`/`Scalar`/`Bounded`), §4.3 (`Concat` named limit), §8.3 (pull roots),
  §8.13 (Analyzer shape).
- `pan_categorical_bridge_and_roadmap.md` §2 (`FeatureCollectorSink` growth policy — `capacity_hint`
  pre-reserve + geometric ×2, legal only on non-RT root; analysis feature chains taxonomy).
- `notes/1.md` (the visualization data schema), `notes/brief.md` line 30 (examples/ goal).
- skill ch.05 (the unmanaged `std.ArrayList` growth; `ensureTotalCapacity`).

**Work (`src/feat.zig`, `src/combinators.zig`, extend `src/io.zig`).**
1. `PullRoot`/`ClockSource` (AudioDeviceCallback / WallClockTimer / InputExhaustion); a non-RT analysis
   root; cross-root SPSC-ring taps; shared upstream rendered once and fanned.
2. `Concat(spec)` named-product fan-in (struct-of-(name→element-type); `node.in.<name>`; output-struct
   field order = canonical column order). `ChannelMap(Sub, C)` combinator (replicate subgraph over C
   channels; pool scales by C).
3. `FeatureCollectorSink(Row)` (non-RT; `capacity_hint` pre-reserve + geometric ×2 growth; RT-root
   wiring = commit error A8). Feature chains: `Mfcc`, `SpectralCentroid`, `SpectralFlux` (history),
   `DominantBand`, `Rms`, plus the perceptual-sparse/onset chains from `research/`.
4. `writeFeatureMatrix` → the matrix `examples/` consumes; the `examples/` Python 60 fps viz reads it
   (full examples/ buildout in Phase 18).

**Success criteria (gate — roadmap step 6).** A per-hop feature matrix is collected with **no effect on
a concurrent audio root's deadline**; `Concat` field order is the column order (wrong element type =
compile error); `FeatureCollectorSink` on an RT root is a commit error; the matrix drives the
`notes/1.md` viz schema (color/amplitude/time).

**Yoneda dispatch.** Gold-vector for each feature block vs SciPy/librosa-equivalent oracle; `Concat`
named-wiring type-checks; `FeatureCollectorSink`-on-RT-root commit rejection (⊢ A8). Oracle = SciPy/
NumPy.

**Benchmark.** Isolation bench: feature collection on the analysis root has **zero effect** on a
concurrent audio root's `deadline_headroom` (a throughput-isolation measurement, not raw speed).

---

## Phase 10 — Embedded bring-up: full comptime graph, q15 fixed-point, I2S-DMA

**Goal.** **Roadmap step 6b**: the embedded profile as a *strict comptime specialization* of the
desktop core — comptime-fixed graph, q15 fixed-point Numeric, static `.bss` memory, the I2S DMA
ping-pong ISR as the callback. The freestanding `ReleaseSmall` smoke gate (already green since Phase 3)
is extended to a real fixed-point chain.

> **Note on the target.** `catalog.md` §9.3 LOCKS the embedded target as **target-generic / freestanding
> stub** (no concrete MCU). This phase builds against the freestanding stub. A *concrete* MCU (with
> CMSIS-DSP / Helium) is the subject of Phase 19 (which requires a spec amendment, §0.8).

**Read first.**
- `pan_architecture_formalisation.md` §7 (the embedded reality check / factoring proof).
- `pan_io_realtime_and_pipeline.md` §8 (device-reconfiguration + the embedded ISR-as-callback mapping;
  DMA circular mode HT/TC IRQ; STM32-HAL circular-mode TC suppression caveat), §11 (Compute HAL Helium;
  the no-op realtime token on fixed-point).
- `catalog.md` §8.5 (comptime-commit smoke gate), §9 (precision/N/W; §9.1 precision comptime; §9.2 N
  regimes — comptime N on embedded; §9.3 q15 default, freestanding stub), §1.4 (Acc/saturate
  load-bearing on the fixed-point path).
- `pan_developer_experience.md` §8 (embedded — the same code specialized).
- skill ch.03 (saturating ops `+|`/`-|`/`*|`, overflow builtins, `@setRuntimeSafety`), ch.06
  (cross-compilation, `resolveTargetQuery` freestanding, `callconv(.c)` ISR, no_std/freestanding
  allocators), ch.05 (`FixedBufferAllocator` over a `.bss` array), **ch.02 (typed type constructors
  `@Struct`/`@Int`/… — `@Type` is REMOVED in 0.16.0).** This phase is where it bites: the comptime
  graph build + the "`SampleMux` collapses to a concrete comptime type, the vtable vanishes" elision
  must build **values or typed constructors, never `@Type`** — the commit-pass comptime-evaluability
  constraint that the colorer/DP build only values, and any monomorphized op-type construction uses
  `@Struct`/`@Int`.

**Work.**
1. The fixed-point path: `Gain`/`Biquad` etc. compiled with `Numeric{ i16, i32, saturate=true, W }`;
   q15 saturating MAC in `i32` `Acc`; bit-exact gold vectors (q15 oracle from `generate.py`).
2. Comptime graph build + `commitComptime` end-to-end at comptime; one `.bss` `[footprint_bytes]u8`
   behind a `FixedBufferAllocator`; the `SampleMux` as a concrete comptime type (vtable vanishes,
   render monomorphizes/inlines).
3. I2S-DMA HAL: circular-mode `2N` buffer; HT IRQ / TC IRQ as the render callback; N comptime-known;
   the no-op realtime token (same API shape). Verify the STM32-HAL TC-suppression caveat where a real
   target is later chosen.

**Success criteria (gate — roadmap step 6b).** The smoke graph compiles in `ReleaseSmall` freestanding;
`footprint_bytes` is a comptime constant; q15 chain output is **bit-exact** to the q15 oracle; the
render fully inlines (no vtable on the hot path).

**Yoneda dispatch.** The comptime-commit smoke gate (compiling = ⊢ for the smoke graph); q15 bit-exact
gold vectors; the no-op-token-on-fixed-point API-shape invariance. Compile against a freestanding 0.16.0
target.

**Benchmark.** q15 footprint in `.bss` (ReleaseSmall freestanding, `footprint_bytes` comptime);
q15-vs-f32 throughput; instruction-count (real on-device cycles deferred to Phase 19).

---

## Phase 11 — Modulation / control blocks (parameter-port consumers & producers)

**Goal.** **Roadmap step 6c** completion: the *library* modulation blocks that drive parameter ports —
LFOs, envelope generators (ADSR), feature→param maps, adaptive-coefficient drivers — plus the
data-gating discipline (no conditional execution).

**Read first.**
- `catalog.md` §2.4 (parameter ports — the consumer/producer contract), §8.9 (data-gating only;
  conditional execution out of scope, permanent).
- `pan_type_and_numeric_model.md` §1.1 (parameter ports; modulation blocks are library).
- `pan_categorical_bridge_and_roadmap.md` §2 (modulation/control taxonomy; adaptive processors fuse-or-
  decouple).
- `pan_io_realtime_and_pipeline.md` §7 (per-block ramp; `set`/`schedule` xor wired edge).

**Work (`src/env.zig`, `src/gen.zig` control side, `src/fx.zig`).**
1. LFO (a zero-sample-input `Map` source emitting `Scalar`), ADSR envelope (gate→amplitude `Map`),
   feature→param map. Wire into a filter's `param.cutoff` etc.
2. Adaptive processors (AEC/AGC/dynamics/howl-suppression) in both realisations: fused (controller +
   filter in one block) and decoupled (coefficient as a parameter port driven by a separate controller).
3. Data-gating blocks: a VAD/onset/power gate emits a `Scalar` the consumer multiplies/freezes on
   (static op-list unchanged; no skipped ops).

**Success criteria (gate — roadmap step 6c).** An LFO→cutoff sweep is zipper-free and **bit-identical**
to the same sweep via `set` (P3); a feature→param chain modulates correctly; data-gating leaves the
op-list static.

**Yoneda dispatch.** Parameter-edge behavioural equivalence to `set` (bit-exact, §5.7b extended);
LFO/ADSR gold vectors vs SciPy. Oracle = SciPy.

---

## Phase 12 — `VariRate`: drift-ASRC, varispeed, TSM/phase-vocoder, pitch-shift

**Goal.** The bounded-variable-rate `Rate` family with worst-case static planning and the honest
determinism split (parameter-driven O3-reproducible; controller-driven ≈-only).

**Read first.**
- `catalog.md` §2.6 (`VariRate` V1–V5; `RatioInterval`/`rate_bounds`/`max_latency`/`ratio_source`).
- `pan_execution_model.md` §2.2.1 (`VariRate`; worst-case planning; ratio held per call), §6 (VariRate
  on a path plans on worst-case endpoints).
- `pan_io_realtime_and_pipeline.md` §1 (clock-domain drift; the adaptive drift-ASRC as a `VariRate`
  with `ratio_source = .internal_controller`; PI controller on the FIFO fill; Q4.60 ratio), §2 (SRC).
- `pan_commit_pass_algorithms.md` §6 (PDC uses `max_latency` for VariRate), §7 (sizes on `min` ratio).
- `pan_testing_and_vector_contract.md` §5.7f (VariRate latency/demand + determinism split).
- `pan_developer_experience.md` §2 (`VariRate` authoring — SamplePlayer).

**Work (`src/io.zig`, `src/fx.zig`, `src/spectral.zig`).**
1. The drift-ASRC `VariRate` at the device boundary (PI controller on the bridging FIFO; bypass on a
   single full-duplex clock); varispeed/scrub `SamplePlayer` (`param.pitch`); runtime-stretch
   TSM/phase-vocoder (STFT/iSTFT fixed-rate, the variable synthesis hop is the `VariRate` seam);
   pitch-shift (TSM ∘ resample).
2. Worst-case static planning in commit: size `needed_input`/buffers on the `min` ratio; PDC on
   `max_latency`; ratio sampled once per render call (held across the buffer).
3. Determinism split: parameter-driven ratio → O3-reproducible (chunkable in Phase 14);
   controller-driven (drift-PI) → ≈-only, not bit-reproducible, not chunkable.

**Success criteria (gate).** Measured out:in ratio lies in `[min,max]`; impulse delay ≤ `max_latency` at
every operating point; `needed_input` sound & monotone over `want` and across ratios; parameter-driven
`VariRate` is O3-reproducible; controller-driven ASRC keeps a bridging FIFO centered over a long run
without xrun (≈, not bit-reproducible).

**Yoneda dispatch.** VariRate latency/demand (§5.7f); the determinism split (parameter-driven bit-exact
where chunkable; controller-driven ≈-only). Oracle = SciPy resampler / XMOS-style reference.

---

## Phase 13 — Sources, typed event lane, NoteEvent, PolyVoice, the Instrument vertical slice

**Goal.** **Roadmap step 6d**: the Instrument graph shape end-to-end — Source generators (SR1/SR2), the
typed `EventLane(Event)` + blessed `NoteEvent`, intra-block fixed-capacity `PolyVoice`, the transport,
and a MIDI-driven polyphonic synth through a layout-typed panner to the device.

**Read first.**
- `catalog.md` §2.7 (Source SR1–SR3), §8.6 (typed event lane EV1–EV3 + `NoteEvent` union, pitch in Hz),
  §8.12 (`Voice`/`PolyVoice`/`VoiceMap` Y1–Y6; fused vs replicated), §8.13 (Instrument shape).
- `pan_execution_model.md` §2.1 (Source = zero-sample-input Map), §4.4 (event lane), §6 (Instrument
  root).
- `pan_io_realtime_and_pipeline.md` §6 (sample-accurate events + sub-block; `NoteEvent`; MPE by
  `note_id`), §9 (transport/timeline/position).
- `pan_concurrency_and_memory_ordering.md` §2 (the `schedule`/event ring shape).
- `pan_developer_experience.md` §6b (the Instrument vertical slice — `SawVoice`/`PolyVoice`/MIDI).
- `pan_categorical_bridge_and_roadmap.md` §2 (sources; polyphony; anti-aliasing obligation Y6).
- `pan_testing_and_vector_contract.md` §5.7g (Source generators + anti-aliasing), §5.7h (events +
  PolyVoice).
- skill ch.02 (`union(enum)` for `NoteEvent`/`Event`-generic lane), ch.04 (PolyBLEP/band-limited
  oscillators; the fused voice loop).

**Work (`src/gen.zig`, `src/synth.zig`, extend `src/io.zig`).**
1. Sources: oscillators (PolyBLEP/band-limited — anti-aliasing ▷/≈), noise, wavetable, constant
   (zero-sample-input `Map`, `out.len` from pull `N`); `SamplePlayer`/file source (`Rate`/`VariRate`).
2. `EventLane(Event)` (comptime-`Event`-generic; time-sorted `(sample_offset, event)`; sub-block split
   keys only on `sample_offset`); blessed `NoteEvent` library union (Hz pitch; note_on/off, pressure,
   MPE expression, CC, bend, program). `MidiEventSource(NoteEvent)`; transport (sample-accurate
   position/seek/loop/tempo; offline deterministic timeline).
3. `Voice` (composite block, flattened `osc→env→filter→VCA`); `PolyVoice(Voice, Vmax)` = `VoiceMap`
   functor + note→slot allocator (steal oldest/quietest + release ramp) + summing mixer; both
   realisations (fused internal-skip / replicated). One static op; `Vmax` comptime ⇒ bounded footprint.
4. The Instrument slice: `MidiEventSource → PolyVoice(SawVoice, 16) → ConstantPowerPan(layout) →
   CoreAudioSink`.

**Success criteria (gate — roadmap step 6d).** A held-then-released MIDI chord renders `Vmax`-bounded
polyphony with **zero xruns over 10 min** and no audio-thread malloc/lock; each note onset lands on its
sample-accurate offset (verified vs an offset-tagged oracle); voice-stealing past `Vmax` is click-free;
the panner output carries the declared layout `L` (mismatch = commit error); oscillator numerics match
a band-limited (PolyBLEP) oracle within tolerance; footprint is a `Vmax`-comptime constant.

**Yoneda dispatch.** Source generators + anti-aliasing vs band-limited oracle (§5.7g); typed events +
PolyVoice alloc/stealing/MPE-routing + sample-accurate onset (§5.7h, dual-mux). Oracle = SciPy/PolyBLEP.

**Benchmark.** `Vmax`-bounded polyphony throughput under a **stress** voice load; voice-pool footprint as
a `Vmax`-comptime constant; zero-xrun-over-10-min as a tracked number.

---

## Phase 14 — OfflineBatch (Tier C): pipeline parallelism + data-parallel chunking

**Goal.** **Roadmap steps 8–9**: the OfflineBatch execution mode (push / input-exhaustion, no deadline,
invariants O1–O3) — pipeline parallelism (exact) and data-parallel timeline chunking via
`warmup_samples` (scales with cores), with bit-reproducible ordered merge.

**Read first.**
- `pan_parallel_and_offline_execution.md` §0 (two modes; Executor triple; mux as mode selector), §1
  (O1–O3 invariants), §3 (Tier C: §3.1 driver/transport, §3.2 pipeline parallelism, §3.3 data-parallel
  chunking + warmup, §3.4 the `warmup_samples`/`warmup_exact` contract, §3.5 deterministic merge/O3,
  §3.6 offline footprint O2), §5 (ledger A18–A19, B10, C11/C13), §6 (roadmap 8–9 success criteria).
- `catalog.md` §2.5 (`warmup_samples` W1–W3), §8.10 (execution modes), §11.1b (O1–O3).
- `pan_execution_model.md` §5 (Tier C row), §7 (offline keeps collapse-on-error).
- `pan_testing_and_vector_contract.md` §5.7d (offline differential).
- skill ch.05 (heap allocations legal offline; rings; per-chunk pools), ch.04 (large-N vectorization).

**Work (fill `RingSampleMux`, `src/offline.zig`).**
1. `RingSampleMux` (bounded SPSC rings, the push transport); `Engine.init(mode=.offline_batch,
   .threads=.auto)`; driven by `InputExhaustion`/`WallClockTimer`; transport deterministic timeline.
2. Pipeline parallelism: map the op-list to stages, stage-per-thread + bounded rings; exact &
   bit-reproducible.
3. Data-parallel chunking: partition `[0,T)` into K chunks rendered concurrently; warm-up lead-in of
   `warmup_samples` discarded; the `warmup_samples`/`warmup_exact` block contract (presence gates
   chunkability — chunking a stateful block without it is a commit/build error W1/A18); the chunker
   forces controller-driven `VariRate` and no-warmup blocks through pipeline parallelism.
4. Deterministic ordered merge (timeline order) + fixed reduction order → O3; offline footprint O2
   (rings + per-chunk pools + per-active-chunk state, pre-allocated).

**Success criteria (gate — roadmap steps 8–9).** File→file render **bit-identical** to the Tier A
sequential render; `K=ncores` **bit-identical** to `K=1` for FIR/STFT (exact-warmup) and **allclose
within declared tolerance** for IIR; near-linear speedup vs cores; chunking a no-`warmup` stateful block
is a commit error; throughput ≥ bottleneck-stage bound. An Instrument timeline bounce is O3-reproducible.

**Yoneda dispatch.** Offline differential (`K=1`≡`K=ncores`; exact vs allclose; no-warmup commit error,
§5.7d); pipeline bit-reproducibility. Bit-exact pan-vs-pan + SciPy where numeric.

**Benchmark.** Flagship throughput-scaling bench: file→file MB/s and near-linear speedup vs cores
(chunking + pipeline parallelism), including a **stress** workload; the O2 pre-sized footprint (rings +
per-chunk pools).

---

## Phase 15 — RealtimeStreaming multicore (Tier B): workgroup HAL, HEFT, point-to-point, auto-demote

**Goal.** **Roadmap steps 10–12**: the static-parallel RT executor — Render-Workgroup HAL, the
level-barrier fallback, then the committed HEFT + point-to-point + concurrency-aware coloring +
cost-gate + auto-demote, **bit-identical to Tier A**.

**Read first.**
- `pan_parallel_and_offline_execution.md` §2 (all: §2.1 foundation/worker pool/generation-wake/token×P/
  workgroup, §2.2 HEFT + work/span, §2.3 cost-model gate + choosing P, §2.4 point-to-point ready-flag
  orderings, §2.5 concurrency-aware coloring + the 4th in-place condition, §2.6 honest wait-freedom
  bound, §2.7 auto-demote, §2.8 bit-exactness + parallel≡sequential test, §2.9 feedback/Rate/param
  invariance, §2.10 level-barrier fallback), §4 (Render-Workgroup HAL), §6 (roadmap 10–12).
- `pan_concurrency_and_memory_ordering.md` §4a (intra-render cross-worker ready-flag orderings; bounded
  spin honest bound).
- `pan_memory_model.md` §8a (concurrency-aware coloring; footprint addendum).
- `catalog.md` §8.4 (tier B disposition), §8.10–§8.11 (cost-gate; concurrency-aware coloring), §12
  (A14–A20, B9/B11/B12, C10/C12).
- `pan_io_realtime_and_pipeline.md` §11 (Render-Workgroup HAL table; macOS `os_workgroup` / Linux
  SCHED_FIFO+affinity / embedded N/A), §10 (per-worker spin-time telemetry).
- `pan_testing_and_vector_contract.md` §5.7c (parallel≡sequential).
- skill ch.03 §11 (atomics, `std.atomic.Value`, `spinLoopHint`), ch.06 (`extern` C-interop for
  `os_workgroup`).

**Work (`src/parallel.zig`, `src/realtime.zig`).**
1. Render-Workgroup HAL `{create, join(token), leave}`: macOS `os_workgroup`
   (`kAudioDevicePropertyIOThreadOSWorkgroup`); Linux SCHED_FIFO/SCHED_DEADLINE + affinity; embedded
   N/A. Honest ▷/≈ bound.
2. Tier B foundation: pre-spawned worker pool (callback thread = worker 0); generation-counter wake
   (no RT syscall, futex park when cold); realtime token ×P (FTZ per-thread); workgroup membership.
3. Level-barrier fallback (level schedule + atomic-countdown barrier + level-axis coloring) — the
   simpler first stage on the same foundation.
4. HEFT schedule (upward-rank list-scheduling, P/E-aware WCET from telemetry EWMA) + work/span; the
   cost-model gate (`W > deadline·θ_busy ∧ W/max(S,W/P) ≥ θ_speedup ∧ workgroup_available`; pick P);
   point-to-point release/acquire ready-flags keyed by generation (no CAS); concurrency-aware interval
   coloring on the schedule-time axis (4th in-place condition: not concurrently scheduled; per-worker
   scratch pools); auto-demote to Tier A (telemetry-gated, RCU swap, hysteresis).

**Success criteria (gate — roadmap steps 10–12).** A 2-worker spin handshake shows bounded wait under
load (spin-time telemetry present); a wide graph (16-voice bank → mix) shows measured speedup; **Tier B
output is bit-identical to Tier A** (parallel≡sequential differential, P=2..ncores) incl. paranoid
no-cross-worker-reuse; the cost-gate refuses a near-linear chain (`W/S≈1`); HEFT beats the level-barrier
on a wide→narrow→wide graph; auto-demote triggers under induced overload; zero xruns over 10 min.

**Yoneda dispatch.** Parallel≡sequential (§5.7c, bit-exact + paranoid); cost-model gate decision (⊢
assert); workgroup bounded-spin under load (B12 telemetry). Compile atomics against 0.16.0.

**Benchmark.** Throughput/headroom scaling vs worker count P (incl. a **stress** graph); per-worker
`spin_time`; the Tier-B concurrent footprint addendum (`+Σ_worker scratch`); the
ReleaseSafe-vs-ReleaseFast delta as the priced safety-check cost.

---

## Phase 16 — DSP & spatial library buildout + layout negotiation

**Goal.** Complete the layered block taxonomy (the bulk of the usable library), including the full
spatial core (the namesake "pan") and the registered layout up/down-mix matrices + layout-negotiation
tests. Most blocks here are independent and parallelizable across dispatched implementers.

**Read first.**
- `pan_categorical_bridge_and_roadmap.md` §2 (the full block taxonomy: gain/dynamics, filters, spatial,
  time/feedback, spectral, rate, mix/routing, sources, polyphony, modulation, analysis; combinators).
- `catalog.md` §1.3 (L1/L2/L3 layout identity/registered coercion/geometry-in-block), §6 (negotiation
  coercion table).
- `pan_type_and_numeric_model.md` §2.1 (channel model — layout-aware spatial blocks; geometry as block
  data).
- `pan_io_realtime_and_pipeline.md` §5 (LPCM channel-order reconciliation), §11 (Compute HAL accel slot
  for FFT/convolution).
- `pan_testing_and_vector_contract.md` §5.7e (layout negotiation — registered up/down-mix + codec
  channel-order round-trip; unregistered-pair commit rejection).
- skill ch.04 (SIMD kernels for filters/dynamics/spatial), ch.05 (partitioned-convolution state).

**Work.**
1. Dynamics: compressor/limiter/expander/gate, soft-clip/waveshaper, VCA, trim. Filters: state-variable,
   FIR (`firwin*`), IIR. Spectral: partitioned-convolution reverb, spectral gate/EQ.
   Mix/routing: summing mixer, splitter/fan-out, matrix router, dry/wet (PDC).
   Time: delay, comb/all-pass, FDN reverb, chorus/flanger.
2. Spatial core (layout-aware `Frame(Lane, L)`): constant-power panner (done), balance, width,
   upmix/downmix matrix, VBAP, ambisonic encode/decode — geometry as block config (L3).
3. Registered layout up/down-mix matrices (`.stereo↔.surround_5_1`, etc.) + the registry; negotiation
   auto-inserts the canonical matrix for a registered pair; an unregistered pair is a commit hard
   mismatch (L2).
4. Multi-rate filterbanks (DWT octave trees, CQT) as a **cascade/bank of uniform-rate `Rate` stages**
   (R5 — not one block).

**Success criteria (gate).** A wired registered layout mismatch auto-inserts the canonical up/down-mix
matrix and the composite output matches the gold-vector oracle (allclose); the I/O codec channel-order
reconciliation round-trips bit-exactly; an unregistered pair is a commit-time hard mismatch; each new
block passes gold-vector + dual-mux.

**Yoneda dispatch.** Layout negotiation (§5.7e: registered matrix allclose + codec round-trip bit-exact
+ unregistered-pair ⊢ rejection); per-block gold vectors + dual-mux for the whole taxonomy. Oracle =
SciPy.

**Benchmark.** Per-block throughput across the full taxonomy (the standing regression surface, under
varied / stress inputs); the layout up/down-mix matrix cost.

---

## Phase 17 — examples/ (Python visualization) + scripts/ (audio-format → LPCM decoders)

**Goal.** The brief's end-to-end demonstrators (`notes/brief.md` lines 28–31): the `examples/` pipeline
that uses the pan library to produce the `notes/1.md` visualization data and renders the animation in
Python, and the `scripts/` decoders that parse common audio formats (WAV/FLAC/MP3) into raw LPCM for
testing the library.

**Read first.**
- `notes/brief.md` lines 28–31 (examples/ + scripts/ workflow goals), `notes/1.md` (the visualization
  data schema + animation spec).
- `pan_io_realtime_and_pipeline.md` §5 (LPCM codecs are core; WAV/FLAC/MP3 → raw-LPCM decoders live in
  `scripts/`, an app concern — keeps the core codec-free).
- `pan_categorical_bridge_and_roadmap.md` §2 (`FeatureCollectorSink` → matrix → Python viz).
- Phase 9's `writeFeatureMatrix` output format.

**Work.**
1. `scripts/`: WAV (and FLAC/MP3 via a thin dependency or `zig`-side decode) → native-endian raw LPCM;
   keep deterministic; document the format the pan library consumes. Extend `generate.py` coverage.
2. `examples/`: a Zig example that builds the Analyzer graph (Phase 9) over a decoded LPCM file →
   `FeatureCollectorSink` → `features.f32.bin`; a Python renderer that reads the matrix and produces the
   `notes/1.md` 60 fps 3D particle animation (matplotlib/your choice — viz is Python per the brief).
3. Optionally an Instrument example (Phase 13) bouncing a MIDI timeline to a WAV via OfflineBatch.

**Success criteria (gate).** `scripts/` decode a WAV to LPCM that the pan library ingests; the
`examples/` Analyzer produces a feature matrix that the Python renderer turns into the `notes/1.md`
animation; the Instrument example bounces a deterministic WAV.

**Yoneda dispatch.** Decoder correctness must assert against an **independent** oracle — decode a WAV
and compare to `scipy.io.wavfile.read` (Rule 9: never use pan's own decoder as its own oracle) — plus
decode∘encode round-trip where applicable; a smoke test that the example graph commits and runs to
completion. The Python *animation* itself is validated by eye + a numeric shape check (not a Zig
gold-vector); the *decoders feeding it* are not exempt from the independent-oracle rule.

---

## Phase 18 — Automatic loop-fusion pass + block-size-1 subgraph combinator  ⚠️ beyond-spec

> **⚠️ Spec-conflict banner (Rule 7 / §0.8).** `catalog.md` T2 / `pan_memory_model.md` §5 LOCK automatic
> loop-fusion as a **deferred, measured optimization (not core)**, and `catalog.md` §5.4 explicitly
> **defers** the block-size-1 subgraph combinator "subject to a real use case." Implementing them here
> **overrides those LOCKED deferral decisions.** Because code conforms to the spec (the single source of
> truth), this phase must **first land a spec amendment** (catalog §15 change-log entry promoting T2 /
> §5.4 from deferred to committed, propagated to the memory model and bridge) in the *same change* as
> the code. Do not ship the code against an unamended spec.

**Goal.** The automatic comptime loop-fusion pass (fuse adjacent rate-1:1 type-stable `Map` blocks that
share an input buffer, provably semantics-preserving, recovering the single-pass min-traffic win) and
the block-size-1 subgraph combinator (compose tight feedback from sub-blocks).

**Read first.**
- `pan_memory_model.md` §5 (the fusion tension T2; the "allowed to fuse adjacent Maps" rule; why it is
  never exposed in the API), §6.1 (the fused tight-feedback kernel and the deferred subgraph
  combinator).
- `catalog.md` T2 (§11.3), §5.4, §7.3–§7.4 (fan-out/in + in-place — fusion must preserve coloring
  semantics).
- skill ch.02 (comptime graph rewriting / `@Struct`), ch.04 (the single-pass cache-traffic win the
  fusion targets).

**Work.**
1. A commit-time fusion pass: identify chains of adjacent rate-1:1 type-stable `Map`s sharing an input
   buffer; fuse into one op (loop-fuse the kernels); prove semantics-preserving (B≡C against the
   unfused graph). Never expose in the API.
2. The block-size-1 subgraph combinator: compose a tight (sample-accurate) feedback loop from
   sub-blocks rendered at N=1 inside one op; bounded; SCC-has-delay still applies.

**Success criteria (gate).** Fused output **bit-identical** to the unfused graph across the corpus
(B≡C); measured cache-traffic / per-call reduction on a perceptual-sparse multi-reduction graph; the
subgraph combinator reproduces a fused-kernel tight feedback bit-identically. **And** the spec amendment
is present (catalog §15 entry).

**Yoneda dispatch.** Fused≡unfused differential (bit-exact); subgraph-combinator≡fused-kernel
equivalence. Bit-exact pan-vs-pan.

**Benchmark.** The **byte-displacement-per-render** reduction from loop-fusion (the single-pass
min-traffic win) — fusion's primary performance evidence alongside the B≡C correctness check.

---

## Phase 19 — Concrete embedded MCU target + machine-checked & property-based verification  ⚠️ beyond-spec

> **⚠️ Spec-conflict banner (Rule 7 / §0.8).** `catalog.md` §9.3 LOCKS the embedded target as
> **target-generic / freestanding stub** (no concrete MCU), and §13 LOCKS the property-based harness,
> the TLA+/Lean proofs, and the Flocq/Gappa numeric proofs as **deferred future work (out of scope).**
> Implementing them here **overrides those LOCKED decisions** and requires a **spec amendment first**
> (catalog §15 entry choosing the concrete MCU and promoting §13 items from deferred to in-scope,
> propagated to §9.3 and the testing spec §8). Pick the MCU explicitly — **recommended: an STM32H7-class
> Cortex-M7/M55 part** (CMSIS-DSP, Helium where available) per `pan_io_realtime_and_pipeline.md` §8's
> references — and confirm the SRAM budget build-constant.

**Goal.** (a) A concrete MCU bring-up beyond the freestanding stub; (b) the deferred verification
adjuncts the spec marks out of scope.

**Read first.**
- `pan_io_realtime_and_pipeline.md` §8 (the embedded ISR mapping; STM32-HAL circular-mode TC caveat),
  §11 (CMSIS-DSP/Helium accel).
- `catalog.md` §9.3 (the locked freestanding-stub decision being overridden), §13 (deferred formal
  work: property-based harness attach points; TLA+/Lean scheduler+colorer; Flocq/Gappa).
- `pan_testing_and_vector_contract.md` §8 (the property-based harness attach points: R3 `needed_input`
  sweep incl. VariRate interval, M4 `aliasing_safe` randomized, B≡C over random topologies).
- skill ch.06 (cross-compilation to the chosen `-mcpu`, CMSIS-DSP C-interop), ch.03/04 (fixed-point
  kernels, SIMD/Helium).

**Work.**
1. Concrete MCU: target triple + `-mcpu`, CMSIS-DSP linkage (FFT, fixed-point primitives), the real I2S
   DMA driver, on-device smoke of the comptime-committed q15 chain, the SRAM-budget build constant.
   (Spec amendment: §9.3 names the target.)
2. Property-based test harness: `needed_input` monotonicity/soundness sweep (incl. the `VariRate`
   `rate_bounds` interval); `aliasing_safe` over randomized inputs; B≡C over randomly generated graph
   topologies. (Moves several ▷ claims toward ≈.)
3. Machine-checked proofs: a TLA+ model of the pull scheduler (upstream-before-downstream, termination,
   wait-freedom over bounded graphs) and the RCU/SPSC orderings; a Lean (or Coq) proof of the left-edge
   interval-coloring correctness (CompCert-style register-allocation literature). Flocq/Gappa numeric
   proofs for a representative biquad (matches its rational transfer function over f32). These turn the
   corresponding ≈ checks into a sanity layer behind a real proof.

**Success criteria (gate).** The chosen MCU runs the q15 chain bit-exactly on-device within the SRAM
budget; the property-based harness runs in CI and finds no counterexamples on the corpus; the TLA+ model
checks, the Lean coloring proof type-checks, the Flocq biquad bound is discharged. **And** the spec
amendments are present.

**Yoneda dispatch.** Property-based harness authoring (the three attach points). The TLA+/Lean/Flocq
artifacts are authored directly (not Zig); pair them with the existing ≈ tests as a cross-check.

**Benchmark.** On-device cycle counts + SRAM-budget footprint — the real-hardware measurement the
freestanding stub couldn't give at Phase 10.

---

## Specification coverage matrix

Demonstrates every LOCKED/COMMITTED commitment, invariant, ledger item, harness, and taxonomy area maps
to a phase (no simplification; spec-deferred items in Phases 18–19 per the 2026-06-03 override).

| Spec item | Where | Phase(s) |
|---|---|---|
| C1 two contracts `Map`/`Rate` + parameter ports | catalog §2, §2.4 | 1, 5, 8 |
| C2 synchronous pull scheduler + render op-list | catalog §8.2 | 3, 4 |
| C3 per-element-class colored pool | catalog §7 | 3 (Mode B), 7 (Mode C), 15 (concurrency-aware) |
| C4 precision-comptime / N-runtime / W-comptime + Numeric trait | catalog §1.4, §9 | 1, 10 |
| C5 clock-driven pull roots | catalog §8.3 | 4, 9 |
| C6 two execution modes (RealtimeStreaming/OfflineBatch) | catalog §8.10 | 4, 14, 15 |
| C7 static-parallel RT executor (Tier B) | catalog §8.10–§8.11 | 15 |
| C8 purpose-agnostic core (Analyzer + Instrument) | catalog §8.13 | 9 (Analyzer), 13 (Instrument) |
| H1 wait-free RT path | catalog §11.1 | 4, 5, 15 |
| H2 bounded static render memory | catalog §7.8 | 3, 7, 10 |
| H3 comptime/commit graph correctness | catalog §11.1 | 1, 3 |
| O1–O3 offline invariants | catalog §11.1b | 14 |
| `ChannelLayout` L1/L2/L3 | catalog §1.3 | 1, 16 |
| `VariRate` V1–V5 | catalog §2.6 | 1 (classify), 12 |
| Source SR1–SR3 | catalog §2.7 | 1 (classify), 3 (rooted check), 13 |
| Event lane EV1–EV3 + `NoteEvent` | catalog §8.6 | 13 |
| `PolyVoice` Y1–Y6 | catalog §8.12 | 13 |
| `warmup_samples` W1–W3 | catalog §2.5 | 14 |
| Feedback/trace + SCC-has-delay | catalog §5 | 3, 6 |
| Format negotiation (unification + coercion) | catalog §6 | 3 (decision), 5 (runtime), 16 (layout matrices) |
| PDC longest-path per rate-domain | catalog §7.7 | 8 |
| Control plane `set`/`schedule`/`edit` + exact orderings | catalog §10; concurrency doc | 5 |
| RT hygiene token / FTZ / NaN / dither / telemetry | io §3,§4,§10 | 4 |
| I/O HAL (CoreAudio / ALSA·JACK·PipeWire / I2S-DMA) | io §11; brief 22–23 | 4 (CoreAudio + Linux ALSA cross-compiled, testing deferred), 10 (I2S-DMA) |
| Compute HAL (`@Vector` + accel slot) | io §11 | 4, 16 |
| Render-Workgroup HAL | io §11; parallel §4 | 15 |
| Transport / timeline | io §9 | 13 |
| Device reconfiguration | io §8 | 5 |
| Ledger ⊢ A1–A28 | catalog §12.1 | distributed (1,3,5,7,8,14,15) |
| Ledger ≈ B1–B18 | catalog §12.2 | the per-phase Yoneda gates |
| Ledger ▷ C1–C18 | catalog §12.3 | authoring obligations surfaced per phase |
| All harnesses §5.1–§5.7h | testing spec | 2 (backbone), then per gate |
| Benchmark surface (throughput incl. stress / latency / footprint + byte-displacement) | §0.9; brief 4–8; catalog §7.8; io §10 | 4 (stand-up + first), 6,7,8,9,10,13,14,15,16,18,19 |
| Block taxonomy (full library + combinators) | bridge §2 | 4,6,8,9,11,12,13,16 |
| Roadmap steps 1–6,6b,6c,6d | bridge §5 | 4,5,6,7,8,9,10,11,13 |
| Roadmap steps 8–12 | parallel §6 | 14, 15 |
| examples/ + scripts/ (brief) | brief 28–31; io §5 | 17 |
| Spec-deferred: loop-fusion, subgraph combinator | catalog T2, §5.4 | 18 (⚠️ beyond-spec) |
| Spec-deferred: property harness, TLA+/Lean, Flocq, concrete MCU | catalog §13, §9.3 | 19 (⚠️ beyond-spec) |

---

## Working discipline (carried through every phase)

- **Rule 13:** load the `zig-0-16` skill before writing/reviewing/debugging *any* Zig; verify by
  compiling against `zig 0.16.0`; consult the std source rather than recalling stale APIs. Every
  dispatched subagent that touches Zig is told the same, explicitly.
- **Rule 14:** at each implementation gate, dispatch Yoneda test-writers (load `zig-0-16`); give them
  the code section + invariant, not the tests.
- **Rule 9/12:** tests assert intent against the independent SciPy/NumPy oracle (pan-vs-oracle) or via
  pan-vs-pan differential; fail loud — "compiles"/"tests pass" must be literally true; `guards_compiled_out`
  asserted against the build mode.
- **Rule 3/11:** surgical changes, match the codebase's conventions; the spec is the source of truth,
  code conforms to it (not the reverse) — except the explicitly-flagged beyond-spec Phases 18–19, which
  amend the spec first.
- **Rule 10:** checkpoint after every significant step — summarize done/verified/left before continuing.
- **§0.2 always:** in-code documentation is self-contained — restate the law/rationale inline; never cite
  a `specifications/*.md` section or filename from `src/`.
