
These rules apply to every task in this project unless explicitly overridden.
Bias: caution over speed on non-trivial work.

## Rule 1 — Think Before Coding
State assumptions explicitly. Ask rather than guess.
Push back when a simpler approach exists. Stop when confused.

## Rule 2 — Simplicity First
Minimum code that solves the problem. Nothing speculative.
No abstractions for single-use code.

## Rule 3 — Surgical Changes
Touch only what you must. Don't improve adjacent code.
Match existing style. Don't refactor what isn't broken.

## Rule 4 — Goal-Driven Execution
Define success criteria. Loop until verified.
Strong success criteria let Claude loop independently.

## Rule 5 — Use the model only for judgment calls
Use for: classification, drafting, summarization, extraction.
Do NOT use for: routing, retries, deterministic transforms.
If code can answer, code answers.

## Rule 6 — Token budgets are not advisory
Per-task: 40,000 tokens. Per-session: 120,000 tokens.
If approaching budget, summarize and start fresh.
Surface the breach. Do not silently overrun.

## Rule 7 — Surface conflicts, don't average them
If two patterns contradict, pick one (more recent / more tested).
Explain why. Flag the other for cleanup.

## Rule 8 — Read before you write
Before adding code, read exports, immediate callers, shared utilities.
If unsure why existing code is structured a certain way, ask.

## Rule 9 — Tests verify intent, not just behavior
Tests must encode WHY behavior matters, not just WHAT it does.
A test that can't fail when business logic changes is wrong.

## Rule 10 — Checkpoint after every significant step
Summarize what was done, what's verified, what's left.
Don't continue from a state you can't describe back.

## Rule 11 — Match the codebase's conventions, even if you disagree
Conformance > taste inside the codebase.
If you think a convention is harmful, surface it. Don't fork silently.

## Rule 12 — Fail loud
"Completed" is wrong if anything was skipped silently.
"Tests pass" is wrong if any were skipped.
Default to surfacing uncertainty, not hiding it.

## Rule 13 — Always load the `zig-0-16` skill for Zig work
Before writing, reviewing, or debugging any Zig code in this project, load the
`zig-0-16` skill. Zig syntax changes heavily across versions; do not rely on
training-data recall — consult the skill (and the std source) and verify by
compiling against `zig 0.16.0`.
Any subagent dispatched for a task that touches Zig MUST be instructed to load
the `zig-0-16` skill too — state this explicitly in the subagent's prompt.

## Rule 14 - Dispatch yoneda test writers at each implementation gate
Whenever you finished implementing a feature, dispatch yoneda test wirters (they should load the zig 0.16 skill) and provide them with instructions on where to create the test (for coherence accross the codebase), buit don't provide them with the specific tests to implement: instead provide them with the code sections / files to test : the agents are autonomous in deciding which tests to create.

## Rule 15 - In-code documentation
In-code documentation must be self-contained. Code comments and doc-comments MUST NOT reference the `specifications/*.md` nor the `pan_implementation_plan.md` (no "see catalog §7.2", no `[mem §6.1]`, no "Phase X.Y"). Instead, restate inline the law, invariant, rationale, ordering, or formula that the code realises, in plain prose, so the source is understandable without the spec open.

## Learnings:
- Saved a feedback memory verify-exit-codes-not-test-counts: trust the exit code; a compile-failed target silently drops its tests while "X/X passed" still prints; never assume a "failed step" is cosmetic.