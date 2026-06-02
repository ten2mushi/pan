# pan Specification Corpus — Mathematical Rigor Audit

> **Hub specification:** [`../specifications/pan_architecture_formalisation.md`](../specifications/pan_architecture_formalisation.md)
>
> **Audit thesis:** E.W. Dijkstra's "prove-before-run" position — that programming is closer to
> mathematics than carpentry, that proofs of correctness must precede execution, and that testing
> can show only the *presence* of bugs, never their *absence* — together with the Curry-Howard
> lineage (types as propositions, well-typed programs as proofs, illegal states unrepresentable).
>
> **Zig version grounding:** This audit reasons about Zig 0.16.0's comptime/type system as a
> proof system. Key facts established before writing: (1) `std.debug.assert` is a **no-op in
> ReleaseFast** — any safety claim resting on it evaporates in production builds; (2) Zig 0.16.0
> has no dependent types and no refinement types — only structural/nominal type equality is
> checkable at compile time; (3) `@compileError` can enforce structural constraints but cannot
> encode semantic/relational properties; (4) comptime evaluation is powerful but operates only
> on values and types known at compile time, not on runtime invariants.
>
> **Scope:** All six architecture specifications plus the brief. Adversarial, not laudatory.
> Every claim is classified on the spectrum proven / tested / asserted. The central tension
> (gold-vector testing vs mathematical correctness) is named and adjudicated.

---

## 0. The Brief's Own Aspiration — and the standard it sets

The brief (`notes/brief.md`) is unambiguous:

> "Specification files must use category theory (and its subfields, such as yoneda lemma and
> others), mathematical formulation. a specifications/catalog.md documenting all the semantic
> and definitions which are used in the specification documents."

The intended workflow: category-theory specs are the **single source of truth**, from which code
is generated. This is precisely Dijkstra's programme applied to software architecture: establish
the mathematical object first, then realize it in code, with the formalization itself constituting
the proof.

The audit must therefore apply a double standard: the Dijkstra/Curry-Howard lens from outside,
and pan's own categorical aspirations from inside. If the specs fail to meet their own stated
goal, that is at least as damning as failing Dijkstra's.

---

## 1. The Correctness Spectrum — Full Classification

Every correctness-bearing claim in the corpus is classified below. The three tiers are:

- **(a) Proven-by-construction / decidable-static** — guaranteed before any code runs, by Zig's
  type system or a decidable comptime/commit-time check.
- **(b) Asserted-and-empirically-tested** — correctness rests on running code against an oracle
  or differential check.
- **(c) Conventional / documented obligation** — correctness rests on the author obeying a rule
  that the system cannot enforce.

### 1.1 Tier (a): Proven-by-construction / Decidable-static

**A1. Port element-type and direction matching** (`pan_type_and_numeric_model.md §1`,
`pan_architecture_formalisation.md §2`). The `PortId` is minted at comptime from the
`process`/`pull` function signature by reading `.pointer.child` and `.pointer.is_const`. A
`connect` call between incompatible element types emits a `@compileError` naming the port. This
is a genuine structural proof: the type lattice makes the wrong wiring syntactically impossible.
What is proven: element-type identity and port direction match at every wired edge. What is NOT
proven: that the DSP computation on those typed bytes is mathematically correct; that the author's
chosen element type matches the physical signal's semantics; or that the rate relationship between
connected nodes is realizable.

**A2. 8-port-per-direction ceiling** (`pan_architecture_formalisation.md §2`,
`pan_execution_model.md §8`). The port index type `u3` (range 0..7) causes any `process`/`pull`
signature with more than 8 ports per direction to be rejected at comptime with a readable
`@compileError`. This is a decidable ceiling check: the number of parameters in a function
signature is knowable at comptime. What is proven: no block exceeds 8 ports. What is NOT proven:
that 8 is the right ceiling for any graph or that port count correlates with correctness.

**A3. Map vs Rate contract discrimination** (`pan_execution_model.md §2`). A block is classified
`Map` or `Rate` at comptime by the presence or absence of `out_per_in`/`pull` declarations. A
`Rate` block missing either `out_per_in` or `algorithmic_latency` is a build error (Rule 12,
`pan_execution_model.md §2.2`). This is decidable: field presence is structurally checkable.
What is proven: every `Rate` block has both declarations at the type level. What is NOT proven:
that the declared `out_per_in` and `algorithmic_latency` are numerically correct for the
algorithm the author implemented; a lying `Decimator` that declares `algorithmic_latency = 0`
when its polyphase FIR introduces genuine latency is undetectable by the type system.

**A4. Delay-free loop rejection — SCC-has-delay** (`pan_memory_model.md §6.1`). The commit pass
performs a strongly-connected-component analysis on the graph (with feedback edges marked) and
rejects any SCC containing no delay element with `error.DelayFreeLoop`. This is a decidable
graph property: cycle detection plus membership check. The `pan_categorical_bridge_and_roadmap.md
§1` table correctly identifies the categorical analog as a well-formedness condition for a trace
in a traced monoidal category. What is proven: every cycle in the wired graph contains at least
one declared delay at commit time. What is NOT proven: that the declared delay is the correct
length for the application's causality requirements, nor that the delay's implementation is
sample-accurate (fused single-`Map` tight-feedback kernels trade scheduler-visibility for
sample-accuracy in an opaque way the commit pass cannot inspect).

**A5. Comptime-commit smoke gate for embedded** (`pan_architecture_formalisation.md §7`,
`pan_categorical_bridge_and_roadmap.md §5`). Calling `commitComptime()` inside a `comptime`
block in a `ReleaseSmall` embedded build makes the Zig compiler itself serve as a proof checker:
if the commit pass uses any operation non-evaluable at comptime, the build fails. The formulation
"compiling = proof" is accurate for this specific claim. What is proven: the commit/coloring
pass is comptime-evaluable for the smoke graph. What is NOT proven: that the full commit pass
(including format negotiation, PDC longest-path DP, and all block-specific initializers) is
comptime-evaluable for arbitrary graphs — only for the specific smoke graph built in the CI gate.

**A6. Channel-count mismatch as type error** (`pan_type_and_numeric_model.md §1`). Because
channel count rides in the `Frame(Lane, C)` type parameter `C`, wiring a mono output to a stereo
input is structurally a type mismatch (different `C` values → different types → `@compileError`
from `connect`). What is proven: channel count compatibility at wired edges. What is NOT proven:
that the channel semantics (left vs right, front vs surround) are correct — only that the counts
match.

**A7. `set` rejecting sample-accuracy at the type level** (`pan_io_realtime_and_pipeline.md §7`).
The `set` API has no `at_sample` parameter. The impossibility of passing a sample offset to
`set` is encoded in the function signature itself. What is proven: you cannot ask `set` for
sample-accuracy through the type system. What is NOT proven: that `schedule` delivers accurate
sample timing in practice (that depends on the SPSC ring implementation and drain timing, which
are runtime behaviors).

**A8. `FeatureCollectorSink` on RT root as commit error** (`pan_execution_model.md §6`,
`pan_categorical_bridge_and_roadmap.md §2`). Wiring a `FeatureCollectorSink` (which uses
growable allocation) onto an RT pull root is rejected at commit time. What is proven: the
rule is enforced at commit. What is NOT proven: that the commit-time check correctly identifies
every block that might allocate at runtime (arbitrary third-party blocks could allocate silently
and only trigger commit errors if pan can inspect them, which requires blocks to declare their
allocation behavior honestly — a conventional obligation, tier (c)).

**A9. Precision as comptime — no runtime switching** (`pan_type_and_numeric_model.md §3`). The
`numericFor` switch requires the `comptime` keyword; precision is bound to a monomorphized
function pointer once. What is proven: no runtime precision switch through this path. What is
NOT proven: that the selected monomorph is numerically appropriate for the target hardware or
application.

**Summary of Tier (a):** Nine decidable-static properties. They are all structural: type
identity, port counts, field presence, graph topology, function-signature shape. None of them
proves anything about the numerical correctness of the DSP math, the validity of declared
constants, or semantic consistency between wired blocks.

---

### 1.2 Tier (b): Asserted-and-Empirically-Tested

**B1. DSP algorithmic correctness — gold-vector oracle** (`pan_architecture_formalisation.md §2`,
`pan_categorical_bridge_and_roadmap.md §3`). The inherited ZigRadio methodology: generate test
vectors via SciPy/NumPy and assert bit-identical output from pan. This is pure empirical testing.
It demonstrates correct output on a chosen finite set of inputs; it is explicitly what Dijkstra
means by "can show presence but not absence." The specs acknowledge this without apology
("extend, not replace"). The oracle is external and independent (SciPy, not pan itself), which
makes this *good* empirical testing — but it remains empirical.

**B2. Colorer correctness — B≡C differential test** (`pan_memory_model.md §9`). The spec calls
this the "proof obligation" and the "proof that the colorer is correct." This language is
problematic. The differential test runs mode B (per-edge double buffers, clearly correct) and mode
C (colored pool) on the same input and asserts bit-identical output. This is a well-designed test
— it has semantic content (it encodes *why* correctness matters, not just that it runs) — but it
is not a proof. It demonstrates equivalence on tested inputs; any input not in the test corpus
is not covered. The term "proof obligation" is used in the sense of Hoare-logic proof obligations
(a condition that must hold), but the *discharge method* is empirical, not deductive. Calling it a
proof in the spec creates a dangerous false equivalence with actual proofs.

**B3. `aliasing_safe` correctness** (`pan_memory_model.md §3, §9`). The spec explicitly
acknowledges the type system cannot verify `aliasing_safe`: "asserting it falsely is caught by
the B≡C / paranoid-mode differential test, which quotes the assertion back." This is an honest
admission. The correctness of the `aliasing_safe` claim rests entirely on the differential test,
which is empirical. The NaN-poison paranoid mode increases coverage but does not constitute a
proof: a kernel with aliasing hazards that happen not to manifest on tested inputs would pass.

**B4. `Rate` contract numerical correctness** (`pan_execution_model.md §2.2`,
`pan_categorical_bridge_and_roadmap.md §3`). The declared `out_per_in` and `algorithmic_latency`
values are tested via the "latency-contract tests" and "dual-mux testing" (`pan_categorical_bridge_and_roadmap.md §3`). A `Rate` block's declared latency being real (that the scheduler's recursion and PDC produce correct timing) is verified empirically, not proven. A misimplemented `needed_input` that returns a wrong count "desyncs the whole graph silently until a latency-contract test catches it" (`pan_developer_experience.md §2`).

**B5. Causality of feedback / RT hygiene in practice** (`pan_io_realtime_and_pipeline.md §3`).
Whether denormals actually cause CPU spikes, whether FTZ is actually set correctly on all
relevant threads, whether the FPCR FZ bit is honoured on the specific kernel version and
scheduler combination — these are runtime properties. The spec documents the correct approach
(token-gated FTZ) and structurally closes the forgetting path (compile error without the token),
but whether the hardware and OS behave as expected is inherently empirical. The `guards_compiled_out`
telemetry field is observational, not a proof.

**B6. PDC correctness — delay compensation arithmetic** (`pan_memory_model.md §7`). The
longest-path DP correctly computing and inserting compensating delays is tested empirically
(prototype step 5: "a dry/wet diamond around the FFT path re-aligns sample-accurately"). Whether
the algorithm handles all graph topologies (including rate-domain crossings and multi-SCC
feedback structures) is not formally proven.

**B7. Wait-free hot path in practice** (`pan_architecture_formalisation.md §1`, H1). The spec
declares H1 as a theorem but the actual wait-freedom of the render op-list replay depends on
the correctness of the implementations of all blocks and the pool. No lock, malloc, or syscall
appearing in any block's `process`/`pull` would violate H1 silently — the type system has no
mechanism to prevent this. Enforcement is conventional (tier c) and validated empirically
through xrun counters and profiling.

---

### 1.3 Tier (c): Conventional / Documented Obligation

**C1. `Map` contract: no cross-call accumulation** (`pan_execution_model.md §2.3`). The spec
explicitly states: "The type system cannot auto-detect the 'Map with hidden accumulator' mistake
(a Map is *allowed* per-sample state)." An author who writes a `Framer` as a `Map` (accumulating
across calls, maintaining a ring buffer, but naming it `process`) will compile and pass type
checks. The distinction is "a documentation/tutorial obligation, not a build error." This is a
pure convention: the spec ships a rule and a tutorial chapter, and correctness depends on the
author reading and following them.

**C2. `aliasing_safe` authoring accuracy** (`pan_memory_model.md §3`). The author must
correctly determine that their kernel has no intra-call read-after-write aliasing hazard. This
requires understanding the memory access pattern of the DSP algorithm. The type system cannot
help. Only the B≡C differential test provides any retrospective check, and only on the tested
inputs.

**C3. No malloc/lock on the audio thread — block author discipline** (H1,
`pan_architecture_formalisation.md §1`). Block authors must not call `malloc`, lock a mutex, or
issue a syscall in `process`/`pull`. Zig has no linear or affine types that could enforce this.
There is no compile-time check that a function call graph is malloc-free. This is pure authoring
discipline. The spec acknowledges this: Tier A's wait-freedom is an *invariant* the architecture
"exists to guarantee" but the guarantee rests on authors obeying the rule.

**C4. `comptime_commit_safe` as authoring obligation** (`pan_architecture_formalisation.md §5`).
A block that uses runtime-only operations in its commit-phase logic should declare itself not
`comptime_commit_safe`. Whether it does depends on the author correctly understanding what
"comptime-evaluable" means in Zig 0.16.0 and checking their own implementation. The CI smoke
gate tests one specific graph; it does not protect against a third-party block silently violating
the obligation for a different graph.

**C5. State-update granularity** (`pan_memory_model.md §6.3`). "When a block is rendered in
two sub-blocks per hop, history must update once per hop, not once per render call." This is a
documented obligation (`spec obligation + a Yoneda test`). The type system cannot enforce
update granularity. The Yoneda test provides empirical coverage.

**C6. `bypass-preserves-latency` for custom bypass authors**
(`pan_io_realtime_and_pipeline.md §7`, `pan_memory_model.md §7`). Built-in bypass is correct by
construction (it routes through the PDC delay). A custom bypass author who routes around the
compensating delay introduces a timing error. The spec names this a "named law" and says it is
"a commit warning/error" where detectable — but the qualifier "where detectable" is significant.
The commit pass can only detect it if the bypass-capable block exposes its bypass routing at
commit time; an opaque custom bypass that manipulates routing directly is undetectable.

**C7. `algorithmic_latency` numerical accuracy** (from `pan_execution_model.md §2.2`). The
declared value must match the algorithm's true group delay. A block that incorrectly reports
`algorithmic_latency = 0` for a filter with genuine group delay passes all structural checks,
passes the latency-contract tests if those tests do not specifically probe that delay, and
produces misaligned signals at PDC fan-in points. The structural check (that the field is
declared) is tier (a); the accuracy of the declared value is tier (c), tested only weakly by
tier (b) tests.

**C8. Correct `needed_input` implementation** (`pan_execution_model.md §2.2`). The `Rate`
block's `needed_input(want)` method must correctly return the number of input samples required
to produce `want` output samples. An incorrect implementation (e.g., returning `want` instead
of `want * HOP` for a `Framer`) desynchronizes the whole graph silently. The type system
enforces the method's existence (tier a); correctness is a conventional obligation.

---

### 1.4 Spectrum Summary

| Tier | Count | Properties | Fraction |
|---|---|---|---|
| (a) Proven-by-construction / decidable-static | 9 | Structural: type/direction match, port counts, field presence, graph topology, signature shape | ~30% of correctness claims |
| (b) Asserted-and-empirically-tested | 7 | DSP numerics, coloring equivalence, aliasing safety, RT timing, PDC, wait-freedom | ~40% |
| (c) Conventional / documented obligation | 8 | Map contract discipline, no-malloc rule, aliasing safety authoring, latency accuracy, needed_input correctness | ~30% |

The type-system proofs cover structure; empirical tests cover behavior; conventions cover
semantic obligations. No tier is empty, and the balance is frankly typical of well-designed
systems-level software. The question is whether the specs misrepresent this balance.

---

## 2. The Central Tension — Surface It Without Softening

The thesis bites hardest here. Dijkstra: "Program testing can be used to show the presence of
bugs, but never to show their absence." The spec corpus repeatedly and proudly claims a
methodology inherited from ZigRadio:

> "Keep verbatim [...] the SciPy gold-vector testing discipline"
> (`pan_architecture_formalisation.md §0`)

And the most celebrated correctness mechanism in the corpus, repeated across three documents, is
the B≡C differential test, which `pan_memory_model.md §9` calls "the proof that the colorer is
correct." `pan_categorical_bridge_and_roadmap.md §1` doubles down: "Correctness = colored ≡
uncolored output (the **B≡C differential test** *is* the proof)."

This language is false to Dijkstra and false to Curry-Howard. A differential test is an
equivalence test on a finite sample of executions. It constitutes evidence of correctness, not
a proof of it. Calling it "the proof" borrows mathematical authority it has not earned. The fact
that the test encodes *why* correctness matters (Rule 9) makes it an exceptionally well-designed
test — but it remains a test.

### 2.1 Where the categorical framing is load-bearing

The following categorical mappings generate real, checkable obligations in the code, not merely
vocabulary:

- **`SampleMux` as Yoneda probe** (`pan_categorical_bridge_and_roadmap.md §1`): the
  representability argument genuinely justifies dual-mux testing as the *definition* of a block's
  behavior. A block is fully determined by its interaction with any mux, so testing under two
  muxes is not arbitrary coverage — it is a structural consequence of representability. This is
  the strongest piece of genuine mathematical content in the corpus. The Yoneda argument is load-
  bearing: it tells you what to test and why testing it is sufficient (modulo the test corpus).

- **Traced-monoidal feedback / SCC-has-delay** (`pan_categorical_bridge_and_roadmap.md §1`,
  `pan_memory_model.md §6.1`): the category-theoretic requirement (a trace is only well-defined
  with a delay guaranteeing causality) maps directly to the `error.DelayFreeLoop` commit check.
  The mathematical concept generates a decidable enforcement rule. This is genuine.

- **Per-element-class coloring as interference-graph coloring** (`pan_memory_model.md §2`): the
  claim that interval graphs are optimally k-colorable in linear time by the left-edge algorithm
  is a mathematical theorem (not a pan claim). Invoking it correctly justifies the correctness
  of the coloring algorithm's optimality — but only for the within-class interval case. The
  across-class non-interference also follows from type disjointness. Both are genuine.

- **Converter insertion makes the diagram commute** (`pan_type_and_numeric_model.md §2`): format
  negotiation as a constraint/unification problem genuinely has categorical content. The commit
  pass inserting coercion morphisms to make the diagram commute is a real structural obligation
  derivable from the categorical framework.

### 2.2 Where the categorical framing is ornamental

- **"Liveness/coloring correctness = B≡C differential test IS the proof"** (the primary
  example): as argued above, this is ornamental. The interference-graph-coloring optimality
  argument is real mathematics; the B≡C test is empirical verification that the Zig
  *implementation* of that algorithm is correct. Conflating the two obscures which layer is
  mathematical and which is tested.

- **"`SampleMux` vtable = Representable probe / Yoneda embedding"**: the *naming* is
  illuminating as a framing device and the testing consequence is real. But the actual Yoneda
  lemma (Hom(A, -) ≅ the functor it represents) requires a natural isomorphism proof, not just
  the naming of one mux as a representable. The spec does not construct this isomorphism; it
  asserts the analogy. As vocabulary for motivating dual-mux testing, it is valuable. As a proof
  of correctness, it is ornamental.

- **`ChannelMap(Sub, C)` as a functor `C^(·)` on subgraphs**: the naming is correct in spirit
  but the spec provides no functoriality proof (that the combinator preserves composition and
  identity). It is a design vocabulary, not a theorem.

- **Analysis pull roots as "additional terminal objects"**: the categorical identification is
  approximate. Terminal objects in a category are unique up to unique isomorphism; having
  multiple pull roots with different clocks does not fit the categorical terminal-object pattern
  cleanly. This is decorative naming.

### 2.3 The adjudication

pan's correctness story is **primarily craft-plus-testing wearing mathematical language**, with a
genuine mathematical core at the structural level. The mathematical content that is load-bearing:
the interval-coloring optimality argument (imports a theorem), the Yoneda-probe justification
for dual-mux testing (imports a categorical principle), the SCC-has-delay requirement (imports
the traced-monoidal well-formedness condition), and the type-system structural checks (which are
decidable static properties). The mathematical language applied to empirical testing (calling
differential tests "proofs," calling the test methodology a "proof obligation" whose discharge
is running code) is ornamental in the Dijkstra sense.

This is not unique to pan; it is the standard condition of well-engineered systems software.
The honest position, which the specs largely avoid, is: "we use mathematics to design the system
and identify the invariants; we use tests to verify the implementation; we use the type system
to make some invariants unrepresentable." The occasional elision of that middle step — treating
tests as proofs — is the primary mathematical dishonesty in the corpus.

---

## 3. Does pan Meet Its Own Categorical Aspiration?

The brief demands: category-theory specs as the **single source of truth from which code is
generated.** Assess the gap.

### 3.1 What the specs actually are

The categorical bridge document (`pan_categorical_bridge_and_roadmap.md §1`) provides a mapping
table: architecture concept → categorical formalisation → proof/code obligation. This is a
**design vocabulary**, not a formal specification. A formal categorical specification would:

1. Define the category precisely: objects (typed sample streams with Format index), morphisms
   (blocks), composition (graph wiring), identity morphisms.
2. State and prove that the required categorical laws hold (associativity of composition, identity
   laws) for pan's specific constructions.
3. Derive the correctness properties as theorems from the categorical axioms.
4. Show that the Zig implementation is a realization of the categorical model (i.e., prove a
   correspondence between the categorical structure and the code).

None of these four steps are present in the specifications. What is present:

- Categorical names for architecture concepts (morphism, Yoneda probe, trace, limit).
- A table mapping those names to code obligations.
- Claims that the categorical reading "is" something (e.g., "format negotiation is a
  constraint/unification problem over the product object").

The specs are a **categorical vocabulary applied to an architecture that was designed with
categorical intuitions**. This is valuable — it organizes the design and identifies the
right invariants. But it is not the programme the brief describes. "Code generated from the
spec" as the path to prove-before-run requires the spec to have a formal operational semantics
that can be mechanically lowered to code. These specs have English prose, Zig-illustrative
snippets (explicitly marked "illustrative, uncompiled"), and a table of analogies.

### 3.2 The `catalog.md` gap

The brief and `pan_categorical_bridge_and_roadmap.md §1` both call for a `specifications/catalog.md`
defining: "the object category and its Format index; the two morphism classes; the Yoneda/SampleMux
probe; the traced-monoidal feedback law; the coloring proof obligation; and the converter-insertion
rule." This document **does not exist in the corpus**. The mathematical definitions that would
make the categorical claims precise — the ones that would allow one to say "the spec is the source
of truth" — are absent. Their absence means there is no formal foundation from which the code
claims could be derived.

### 3.3 The "single source of truth" claim

The current specs are not the single source of truth in the mathematical sense intended by the
brief. They are a detailed architecture document with categorical vocabulary. The real sources of
truth in the pan design are:

- The ZigRadio source code (explicitly: "[t]he one open feasibility question [...] is answered
  yes" from reading `src/core/block.zig` — the spec is *derived from* code, not the converse).
- The JUCE `AudioProcessorGraph` design (the op-list pattern is inherited, not derived from the
  categorical framework).
- The SciPy oracle (the ground truth for DSP correctness is a Python library, not the spec).

The spec serves as an excellent **architecture decision record** with categorical vocabulary.
It does not serve as the mathematical object from which code is provably generated.

### 3.4 Is "code generated from the spec" achievable here?

Partially, in principle. The structural invariants (H3: port type matching, SCC-has-delay,
format negotiation) are formal enough that they could be machine-checked against an
implementation via a type-checker. The DSP math (biquad transfer functions, MFCC computations,
PDC latency arithmetic) would require a domain-specific formalization (e.g., signal-flow graphs
in Lean/Coq with a formal semantics of linear time-invariant systems) that is not present.

The gap between the aspiration and the current state is large. The current specs are a necessary
precursor, not the thing itself.

---

## 4. What Would It Take to Actually Satisfy the Thesis

Ranked by value (impact on provable correctness) versus feasibility (achievable without
abandoning Zig 0.16.0 as the implementation language).

### 4.1 High value, achievable in Zig

**R1. Encode the no-malloc RT obligation structurally.** Zig has no affine or linear types.
However, the render path's allocator could be a custom `Allocator` implementation that panics
(in debug) or is a compile-time-typed `std.heap.FixedBufferAllocator` with zero remaining
capacity. Passing this allocator to blocks' `process`/`pull` signatures means any malloc attempt
crashes loudly in debug. Combined with `ReleaseSafe` in the test matrix (where `std.debug.assert`
is still active), this approaches making H1 violations detectable empirically. This does not
constitute a proof, but it closes the detection gap substantially without a proof assistant.

**R2. Encode `needed_input` correctness as a property-based test.** The scheduler's correctness
depends on `needed_input(want)` being monotone, non-zero for `want > 0`, and satisfying
`pull(needed_input(want)) >= want` (or a declared ratio). These are properties that can be
tested by a fuzzer/property-based test (e.g., Zig's comptime-generated test matrix over a range
of `want` values). This moves `needed_input` from tier (c) to tier (b), and explicitly states
the property being tested. It is the closest Zig-achievable analog to a type-level proof of
`Rate` contract correctness.

**R3. Formalize and machine-check the `Format` product and unification algorithm.** The format
negotiation pass is described as "constraint/unification over the product object" — but the
unification algorithm itself is prose. Writing the negotiation as a comptime function whose
output type is a `Format` (rather than an error union with runtime checks) would make type
mismatches unrepresentable rather than merely detectable. This is achievable in Zig 0.16.0
using comptime struct reflection and is the cleanest path to extending tier (a) coverage.

**R4. Make `algorithmic_latency` testable by the framework automatically.** Every `Rate` block
must pass a harness test: feed the block a unit impulse and measure the actual output delay.
Compare it to the declared `algorithmic_latency`. This is a standard DSP verification step and
moves latency accuracy from tier (c) to tier (b) in a systematic way. The prototype plan (step 5)
gestures at this but does not specify the harness as a required gate for all `Rate` blocks.

### 4.2 High value, require tools outside Zig

**R5. Machine-check the scheduler and colorer with TLA+ or Lean.** The correctness of the pull
scheduler (that it always renders upstream before downstream, that it terminates, that it is
wait-free) and the coloring algorithm (that assigned buffer IDs never alias live intervals) are
properties of algorithms on graphs. These are naturally expressed as invariants in TLA+ or as
theorems in Lean/Coq. The Zig implementation can be verified against the spec by testing, but
a proof would cover all inputs. Realistic effort: a graduate-student semester for the scheduler;
more for the colorer. The spec's existing register-allocation analogy directly maps to a
classical compiler register-allocation correctness proof literature (the Leroy CompCert approach).

**R6. Formal operational semantics for `Map` and `Rate` in the `catalog.md`.** The missing
`catalog.md` should define a formal denotational semantics: a `Map` block is a function
`Stream(A) → Stream(B)` where `Stream(A)` is `ℕ → A`; the `Rate` contract is a causal
transducer with a bounded look-ahead. These definitions could be written in Lean and the
categorical laws (functoriality of composition, identity) proven. Code correspondence would be
established by the Yoneda argument (if the block passes the dual-mux test for all inputs, it
realizes the categorical morphism). This is the true version of the brief's stated aspiration.

**R7. Refinement types for numeric correctness.** Properties like "the biquad's transfer
function matches a specified rational function in z" or "the MFCC values are within epsilon of
the SciPy oracle for all inputs in the numerical domain" require either a proof assistant with
numeric reasoning (Coq + Flocq) or a model checker (dReal). These are genuinely hard; the
SciPy-oracle testing is a pragmatic substitute that covers the cases tested, not all cases.

**R8. Prove the embedded "same code, specialized" claim formally.** The claim that the embedded
build is a "strict comptime specialization" of the desktop core is the strongest architectural
claim in the corpus. A formal proof would demonstrate a bisimulation: that for all inputs, the
embedded build's output equals the desktop build's output when given the same inputs and the
same comptime parameters. The CI smoke gate tests one graph; a proof would cover all graphs in
the spec. This would require a formal semantics for the comptime specialization mechanism.

### 4.3 Inherently empirical — no proof can reach

**E1. Real-time scheduling guarantees on physical hardware.** Whether the audio callback meets
its deadline on a specific M3 machine with a specific macOS scheduler version, under contention
with other processes, cannot be proven. It is measured. The xrun counter is the right mechanism.
H1 says "the render path must be wait-free" — but wait-freedom in the theoretical sense (the
algorithm makes progress in finite steps without blocking on others) does not guarantee that
the OS schedules the audio thread before the deadline. This is a physical constraint.

**E2. Clock drift and ASRC behavior.** The adaptive PI controller for drift resampling
(`pan_io_realtime_and_pipeline.md §1`) has stability properties that could theoretically be
analyzed (the PI controller's stability criterion is mathematical), but the actual drift of a
real device over 20 minutes on specific hardware depends on crystal quality, temperature, and
OS behavior. Testing is the only verification path.

**E3. Denormal behavior on specific hardware.** Whether FTZ is respected by a particular
BLAS/FFTW library call in an optional accel path is not checkable at compile time. The
`guards_compiled_out` telemetry field and the required-token pattern close the forgetting path,
but the underlying hardware behavior must be empirically verified.

**E4. NaN propagation through the full graph.** The spec describes NaN-guard behavior in
Debug/ReleaseSafe and silence-emission on fault. Whether a specific combination of blocks and
feedback loops contains a NaN sink or propagation path is, in general, undecidable (it depends
on runtime values). The per-block isolation policy is the right engineering response; a proof
is not achievable.

---

## 5. Verdict

### 5.1 Where pan is genuinely "closer to mathematics than carpentry"

The following invariants are proven by construction in Zig 0.16.0's type system or by decidable
commit-time checks, and they constitute real, non-trivial correctness guarantees:

- **H3 (port/graph correctness)** is genuinely achieved for its scope. Type-mismatch, channel-
  count-mismatch, and direction-mismatch wiring is unrepresentable. The 8-port ceiling is
  comptime-enforced. The SCC-has-delay law is decidable at commit. The `Map`/`Rate` field-presence
  check is structural. These are genuine Curry-Howard results: the type checker *is* the proof
  checker for these properties.
- **The Yoneda-probe argument for dual-mux testing** imports a categorical principle that
  genuinely determines what must be tested and why. This is mathematical reasoning informing
  the test design — not a proof, but a proof *strategy* properly applied.
- **The interval-coloring optimality claim** correctly imports a graph-theory theorem to bound
  the coloring algorithm's behavior. The algorithmic argument is sound.
- **The `Format` unification as commuting-diagram constraint** correctly identifies format
  negotiation as a categorical property — and the commit-time enforcement is mechanical.

### 5.2 Where pan is craft-in-mathematical-language

- **H1 (wait-freedom)** is declared as a theorem but enforced by authoring convention. No Zig
  type prevents a block author from calling `malloc` in `process`. The guarantee is the
  discipline of the library authors, not the type system. Testing (xrun counters, CI that runs
  under instrumented allocators) is the actual enforcement.
- **H2 (bounded render memory)** is guaranteed by the footprint formula and the per-element-class
  pool if and only if all blocks correctly pre-allocate in `initialize` and never allocate in
  `process`. Again: convention with empirical testing, not a proof.
- **DSP correctness** — the actual audio math — is entirely in tier (b). The SciPy-oracle
  testing is excellent empirical practice. It is not a proof. Dijkstra's statement bites here
  exactly: the test suite can show that the biquad is wrong on inputs it covers; it cannot show
  that it is right on inputs it does not.
- **The coloring correctness claim** is misrepresented as a proof. The differential test is an
  excellent test, not a proof. The spec should say "the B≡C differential test is the primary
  correctness check for the colorer," not "the test IS the proof."

### 5.3 Are the gaps fixable-in-principle or inherent?

**Fixable in principle (with significant effort):**
- The no-malloc RT obligation could be structurally enforced by type-parameterizing the render
  path allocator.
- The scheduler and colorer correctness could be proven in a proof assistant with realistic
  effort.
- The `catalog.md` with formal operational semantics for `Map`/`Rate` could be written.
- Property-based tests could move several tier (c) properties to tier (b).
- The brief's "code generated from spec" model is achievable in principle if the categorical
  spec becomes formal (the gap is the current informality of the spec, not the architecture).

**Inherent to hard-real-time audio on physical hardware:**
- Real-time scheduling guarantees require empirical measurement, not proofs.
- Device clock drift, denormal behavior on specific hardware, and NaN propagation through
  arbitrary graphs are runtime phenomena that testing and monitoring must address.
- DSP numeric correctness at the level of "the biquad matches its mathematical specification for
  all floating-point inputs" requires a floating-point proof assistant (Flocq/Gappa), which is
  a serious research-grade effort for even one algorithm.

### 5.4 Graded judgment

On the Dijkstra spectrum from "pure craft" to "pure mathematics":

| Dimension | Grade | Justification |
|---|---|---|
| Structural / type-level correctness (H3, port wiring) | B+ | Genuine Curry-Howard results; structural invariants are unrepresentable via types |
| Algorithmic correctness claims (coloring, scheduler) | C+ | Mathematical vocabulary; empirical testing; no formal proofs; "proof" language overstated |
| DSP numeric correctness | C | Good empirical discipline (SciPy oracle); pure craft in the Dijkstra sense |
| Categorical spec as single source of truth | D | Aspiration not realized; `catalog.md` missing; specs are design vocabulary, not formal specifications; code precedes spec in several places |
| Real-time / hardware guarantees | Inherently empirical | No grade applies; this is the correct response to physical constraints |

Overall: pan, as currently specified, is **closer to well-engineered craft with mathematical
vocabulary than to mathematics in Dijkstra's sense**. It is better than most real-time audio
libraries at identifying the right invariants, deploying types where types can help, and
designing tests that have semantic content (the B≡C test, dual-mux testing, the Yoneda-probe
argument). But the core correctness mechanism — the SciPy-oracle differential testing — is the
pure empiricism Dijkstra was critiquing, and the occasional language claiming tests are proofs
represents the kind of category error Dijkstra's thesis was designed to call out.

The architecture is sound and the mathematical vocabulary is often load-bearing. The gap between
aspiration and specification is real and specific: the `catalog.md` does not exist, the
formal operational semantics are absent, and the brief's "code from spec" model is not realized.
These are fixable — they require a significant but bounded additional investment in formal
methods tooling around the existing architecture, not a redesign.

---

## 6. Top Three Recommendations Toward Prove-Before-Run

**Recommendation 1 (highest impact, achievable without leaving Zig): Property-based testing as a
systematic upgrade for tier (c) → tier (b).** Write a property-based test harness that exercises:
(a) `needed_input(want) * out_per_in ≈ want` for all `Rate` blocks over a range of `want` values;
(b) `aliasing_safe` blocks produce identical output whether buffers are aliased or separate, for
randomized inputs; (c) the colorer produces bit-identical output to mode B for randomized graph
topologies, not just fixed test vectors. This does not change the tier classification from
"tested" to "proven" — but it substantially increases the evidence weight and makes the claims
more honest. The B≡C differential test becomes genuinely coverage-adequate, not cherry-picked.

**Recommendation 2 (highest structural impact, medium effort): Write the `catalog.md` as a
formal operational semantics.** Define, in mathematical notation (not prose):
(a) the category of typed sample streams with its `Format` index as objects;
(b) `Map` as a morphism class with stated laws (rate-1:1, causal, no cross-call state about rate);
(c) `Rate` as a morphism class with stated laws (declared `out_per_in`, `algorithmic_latency`,
monotone `needed_input`);
(d) composition (graph wiring) with its associativity and identity laws.
This document, even if informal-mathematical (using standard mathematical notation without
mechanization), would make the categorical vocabulary load-bearing rather than ornamental and
would serve as the missing "single source of truth" the brief demands. It is a prerequisite
for recommendation 3.

**Recommendation 3 (highest long-term value, requires external tools): Machine-check the
scheduler and colorer in TLA+ (short term) or Lean (long term).** The pull scheduler is a
topological-sort-plus-replay algorithm on a DAG with well-defined properties. TLA+ can model-
check its invariants (upstream renders before downstream, wait-freedom, termination) over all
graphs up to a bounded size within days of effort. The coloring algorithm has a direct literature
proof (the left-edge interval-coloring algorithm) that could be mechanized in Lean/Coq, turning
the B≡C differential test from the primary correctness evidence into a sanity check. This is
the move that would genuinely satisfy Dijkstra: the scheduler and colorer — the two algorithms
that underpin all of H1, H2, and the coloring-is-optimization claim — would be *proven correct*
before running, with the differential test as additional confirmation, not as the proof itself.

---

*Audit completed 2026-06-02. Auditor: Claude Sonnet 4.6 via Claude Code, with the zig-0-16 skill
loaded to accurately bound claims about Zig 0.16.0's type system guarantees.*
