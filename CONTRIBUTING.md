# Contributing to pan — load-bearing conventions

These conventions apply to **every** phase and every contributor (human or
agent). They are derived from the implementation plan's §0 and are inherited by
all later work. The `specifications/` corpus is the single source of truth; code
conforms to it.

## 1. Self-contained in-code documentation (plan §0.2)

**Code comments and doc-comments MUST NOT reference the `specifications/*.md`
files.** No "see catalog §7.2", no `[mem §6.1]`, no filenames or section numbers
in `src/`. Instead, **restate the law, invariant, rationale, ordering, or
formula inline**, in plain prose, so the source is understandable without the
spec open.

- Paraphrase the motivating content (e.g. "A feedback cycle is legal only if it
  contains at least one unit delay, because the loop's fixpoint is only
  well-defined when this period's output depends solely on previous periods'
  looped values").
- You may name a law *in words* ("the delay-free-loop rule") but never a markdown
  section number or filename.
- The spec citations live in this plan, in the handoff docs, and in **test
  names** (§3 below) — not in `src/`.

## 2. The correctness-tier markers (plan §0.3, Rule 12 vocabulary)

Every correctness-bearing claim carries exactly one marker; never mislabel:

- **⊢ proven-by-construction / decidable-static** — guaranteed before any code
  runs (Zig's type system, a `@compileError`, or a decidable comptime/commit-time
  check).
- **≈ tested (empirical)** — rests on running code against an oracle or a
  differential check; shows the *presence* of bugs, never their *absence*.
- **▷ conventional (authoring obligation)** — rests on an author obeying a rule
  the system cannot enforce.

**The phrase "the test is the proof" is banned.** Say "proven ⊢ at
comptime/commit", "the primary correctness check ≈ is the B≡C differential test",
"a conventional obligation ▷ tested by …". A test is evidence, not a proof.

## 3. Testing & comparison modes (plan §0.4–§0.5)

- Tests assert intent against an **independent** oracle (SciPy/NumPy) — never
  against pan's own output (Rule 9). A test must encode *why* behavior matters.
- **pan-vs-external-oracle** (gold vectors): `numpy.allclose` for float lanes,
  **bit-exact** for integer/fixed-point lanes (`atol`/`rtol` per block in the
  manifest).
- **pan-vs-pan** (B≡C, dual-mux, aliasing, state-granularity, parallel≡sequential,
  offline differential, codec round-trip): **always bit-exact**, regardless of
  lane type. Tolerance forgives the oracle's different arithmetic; it never
  forgives pan disagreeing with itself.
- **Test names encode the gate + the catalog citation** (this is the *only* place
  catalog sections appear alongside code), e.g.
  `test "B≡C: colored pool ≡ per-edge buffers, bit-exact (catalog §7.5)"`.
- A `@compileError` negative case cannot run as a live test (it aborts
  compilation). Pin it as a **disabled commented stub** stating the exact
  diagnostic un-commenting must produce.

## 4. Build / CI matrix (plan §0.6)

Every harness runs across the build modes; the matrix is the discharge surface
for the ≈ ledger:

| Mode | Asserts | NaN guards | Role |
|---|---|---|---|
| Debug | on | on | primary correctness; UAF/leak detection |
| ReleaseSafe | on | on | release-shaped codegen with safety; default CI gate |
| ReleaseFast | off | off | hot-path build; tests pass with safety stripped |
| ReleaseSmall (freestanding) | off | off | the comptime-commit smoke gate |

- `guards_compiled_out: bool` telemetry must match the build mode; never silently
  drop a safety net (Rule 12).
- Run the suite in **Debug and ReleaseSafe minimum**.
- CI gates: `zig build fmt-check` (formatting), `zig build test` (Debug +
  ReleaseSafe), `zig build smoke` (freestanding ReleaseSmall comptime commit).

## 5. Zig toolchain discipline (Rules 13 / 14)

- **Rule 13:** load the `zig-0-16` skill before writing/reviewing/debugging *any*
  Zig; verify by compiling against `zig 0.16.0`; consult the std source rather
  than recalling stale APIs. **Any dispatched subagent that touches Zig must be
  told to load the `zig-0-16` skill too — state it explicitly in the prompt.**
- **Rule 14:** at each implementation gate, dispatch Yoneda test-writers (told to
  load `zig-0-16`); give them the **code section + the invariant/oracle**, never
  the specific tests to write — the agents decide cases autonomously.

## 6. Layout & naming (plan §0.7)

- Library root `src/root.zig`; CLI `src/main.zig`. Submodules `snake_case.zig`; a
  file whose top level *is* a type is `PascalCase.zig`.
- Types / `type`-returning fns: `PascalCase`; functions: `camelCase`;
  values/fields: `snake_case`; acronyms as words (`Io`, not `IO`).
- `usingnamespace` is gone — re-export explicitly with
  `pub const x = @import(...).x;`.
- Project tree: `src/`, `include/`, `vendor/`, `tests/`, `examples/`, `scripts/`,
  `tools/`.

## 7. Working discipline (Rules 3 / 7 / 10 / 11)

- Surgical changes; match the codebase's conventions even where you disagree
  (surface the disagreement, don't fork silently).
- Surface conflicts, don't average them: pick the more recent / more tested side
  and flag the other.
- Checkpoint after every significant step — summarize done / verified / left.
- The spec is the source of truth; code conforms to it (not the reverse) — except
  explicitly-flagged beyond-spec phases, which amend the spec first.
