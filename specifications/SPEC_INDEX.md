# pan Specification Index

**Status: corpus LOCKED 2026-06-02**

pan is a real-time audio DSP library. These specifications are the single source
of truth for its design; implementation conforms to them, not the reverse.

**Change control:** `catalog.md` is authoritative. Any edit to a definition or law
propagates to every citing section across the corpus in the same commit. Do not
fork a definition locally; update the catalog and the citing sections together.

## Reading order (LOCKED)

0. [catalog.md](catalog.md) — single source of truth: objects, morphisms, laws,
   correctness tiers, and glossary that every other doc cites.
1. [pan_architecture_formalisation.md](pan_architecture_formalisation.md) — the hub:
   invariants H1–H3, commitments C1–C5, and tensions T1–T5 that bind the corpus.
2. [pan_execution_model.md](pan_execution_model.md) — Map/Rate contracts, the pull
   scheduler, render op-list, and clock-driven roots.
3. [pan_memory_model.md](pan_memory_model.md) — per-element-class colored pool,
   feedback / z⁻¹ handling, and plugin delay compensation (PDC).
4. [pan_type_and_numeric_model.md](pan_type_and_numeric_model.md) — typed ports, the
   Numeric trait, precision / N / W parameters, and format negotiation.
5. [pan_io_realtime_and_pipeline.md](pan_io_realtime_and_pipeline.md) — I/O HAL,
   drift / ASRC, the control plane, RT hygiene, and transport.
6. [pan_categorical_bridge_and_roadmap.md](pan_categorical_bridge_and_roadmap.md) —
   the categorical bridge (load-bearing vs framing), block taxonomy & combinators,
   resolved open questions, and the de-risking prototype plan.

## Companion (NON-LOCKED)

- [pan_developer_experience.md](pan_developer_experience.md) — DX narrative and
  ergonomics. Defers to the locked specs above; never overrides them.

## Deferred future work

The property-based test harness and the TLA+ / Lean machine-checked proofs are
deferred future work (see `catalog.md` §13).
