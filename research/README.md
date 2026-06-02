# Audio Signal Processing Research Notes

**Goal.** Produce PhD-level, first-principles research notes on audio DSP primitives and algorithms optimized for **real-time execution on embedded devices**, with an uncompromising focus on **minimizing bytes moved through the memory hierarchy** (loads/stores, cache-line traffic, DRAM bandwidth, TLB pressure). 

Notes are language-agnostic in formulation (pseudocode + math first) but include concrete references and intrinsics examples for optimized implementations in C (NEON/Helium intrinsics, CMSIS-DSP, fixed-point paths) and portable SIMD patterns applicable to Rust (std::simd / packed_simd) or Zig (@Vector); full Rust/Zig ports are natural follow-on work given the pseudocode.

## Core Constraints & Philosophy

- **Real-time embedded**: bounded per-sample or per-block latency; no dynamic allocation in the hot path; pre-allocated ring buffers, lookup tables, and state; deterministic execution (no data-dependent branches in inner loops when possible); fixed-point or low-precision floating-point where beneficial for power/area.
- **Memory traffic first**: every algorithm is analyzed for (a) working set size (L1/L2 resident?), (b) bytes read/written per input sample or per frame, (c) stride patterns and cache-line utilization, (d) in-place vs. out-of-place trade-offs, (e) opportunities for streaming / single-pass / fused kernels that never materialize full intermediate arrays (e.g., on-the-fly mel energies from current STFT frame without storing the spectrogram).
- **First principles**: start from the mathematical definition (sum, inner product, convolution, perfect-reconstruction conditions), derive the efficient form (lifting, polyphase, Cooley–Tukey butterflies, Goertzel IIR), then hardware mapping (SIMD butterflies, NEON VMLA, cache blocking, bit-reversed addressing vs. in-order).
- **Elegant & curious techniques**: prefer algorithms that achieve surprising economy (Goertzel’s two state variables for a DFT bin; lifting’s in-place integer wavelets; ribbon-like or sparse methods if they appear in audio; reassignment via phase derivatives; single-bin or pruned transforms).
- **Cross-referenced corpus**: notes hyperlink to each other (e.g. [`discrete-fourier-transform.md`](./transforms/discrete-fourier-transform.md)). Shared concerns live in `general/`.

## How These Notes Differ from Typical DSP Tutorials

- Heavy on **arithmetic intensity and traffic accounting** (e.g., “N-point radix-2 FFT performs ≈ 5N log N loads/stores in naïve implementation; cache-oblivious six-step variant reduces DRAM traffic to Θ(N log N / L) cache lines”).
- Explicit **state-machine and dataflow diagrams** (mermaid) for streaming pipelines.
- Concrete **memory budgets** at typical audio rates (16 kHz, 48 kHz, 10–100 ms blocks) and embedded RAM sizes (64 KiB–8 MiB SRAM, external DDR).
- Hardware-specific sections: ARM NEON / SVE, RISC-V RVV, x86 SSE/AVX (for dev workstations), TI C6x-style DSPs, and the limits of Cortex-M4/M7/M33 without vector units.
- Numerical considerations: fixed-point Q formats, coefficient quantization, limit cycles in IIR, phase preservation in STFT.

## Directory Layout (Current)

- `general/` — cross-cutting foundations (memory hierarchy modeling for DSP, numerical stability, fixed-point arithmetic, ring-buffer design that minimizes copies). **Completed foundational notes.** + **2026:** `general/end-to-end-pipeline-budgets-and-worked-examples.md` (glue: concrete <2 KiB KWS / 60 fps viz / full-duplex / synth+reverb budgets + fusion recipes + decision framework across all notes).
- `transforms/` — DFT/FFT (incl. Goertzel, cache-oblivious, SIMD), STFT (streaming, zero-copy, on-the-fly), DWT/lifting (in-place integer), CQT, plus IntMDCT lifting and sliding/recursive DFT (new 2026 scaffolds). **4 deep notes completed + 2 scaffolds.**
- `features/` — mel / bark / ERB filterbanks, MFCC (full pipeline, fused on-the-fly, fixed-point, CMSIS); perceptual/sparse/TEO/flux/chroma ultra-low-compute family (**2026 expanded to full deep**); real-time dominant frequency band tracking & mapping (2026); **2026 fills/scaffolds:** LPC/PARCOR/formants/LPCC (with formant tracking; **solid scaffold 2026-06**), GFCC/gammatone/ERB (**solid 2026-06**), spectral contrast (**solid 2026-06**), ITU BS.1770 loudness (**solid 2026-06**), modulation spectrum + RASTA (**solid 2026-06**), PNCC robust (**solid 2026-06**), phase/IF/group-delay condensed, online norm, MPEG-7 (see gaps/INDEX for details). **MFCC + perceptual-sparse full + 2026 expansions complete major feature zoo. All 6 features partials upgraded to full guideline-compliant solid scaffolds in 2026-06 subagent pass (see audit).**
- `detection/` — real-time pitch (YIN/pYIN, HPS, Goertzel hybrids, state/traffic budgets); **2026 full:** onset/beat/transient (OSF + agent + wavelet) and VAD (energy+ZCR+harmonicity+adaptive FSM+hangover + explicit gating to save MFCC/pitch). **Pitch + onset + VAD completed.**
- `optimization/` — SIMD vectorization (NEON/Helium/RVV intrinsics + traffic tables for biquads, butterflies, mel, Goertzel), **fast approximations / LUT / CORDIC / minimax / CLZ (new 2026, harvesting perf-coder tricks from embedded.com, ST AN, ARM whitepapers, music-dsp for log/sqrt/atan2/sin in all features)**, **branchless/bit-twiddling hacks (Stanford bithacks + Lemire + music-dsp harvest: masks for abs/min/clip/ZCR/gating, float-pun log/CTZ, popcount/SWAR, bitrev; zero-traffic deterministic layer)**, **cache-blocking + fused kernels + advanced DMA choreography (table-guided FIFO / scatter from TI dMAX pro-audio + modern MCU DMA; fusion STFT+features single-pass, register blocking, offload for delay-lines; fills planned + new critical-infra surface)**, low-mem streaming (partially subsumed). **SIMD + fast-math + branchless + cache/DMA notes completed.**
- `filters/` — IIR families (DF, lattice, SVF, WDF, two-path allpass), FIR streaming (block FIFO, transposed, CSD multiplierless), comb, allpass phase linearization, LR crossovers (2026: scaffold expanded to full deep + new dedicated note). 
- `resampling/` — polyphase, Farrow, CIC, Lagrange (2026 scaffold).
- `algorithms/` — streaming dynamics, envelope followers, ballistic filters, AGC & [0,1] feature scaling (2026, fulfills ballistics); **2026 scaffolds/full per gaps:** higher-level compositions (HPSS streaming, AEC partitioned NLMS/FDAF, reverb Schroeder/FDN delay-line traffic, WSOLA/PSOLA light, spectral subtraction/NS/gating, feedback/howl adaptive notching, chorus/flanger/phaser modulated frac, Karplus-Strong physical modeling, multiband dynamics/de-esser, simple dereverb, phase-vocoder vs WSOLA; all with explicit traffic/state focus, mermaids, cross data_structures/filters/resampling/dynamics/numerical/opt). Directory now substantially populated.
- `data_structures/` — audio rings, fractional delays, sparse reps (directory prepared 2026; foundational for reverb/AEC/WSOLA; **filled 2026 with power-of-2 rings, frac delay lines, sparse trackers, traffic analysis**).
- `references/` — bibliography / data files (empty, for future use).
- Meta: `gaps-feature-extraction-algorithms-2026.md` (ultrathink on missing high-value features & algorithms for comprehensive coverage; proposals with cross-ref maps and prioritization).

## Provenance & Verification Standard

Every quantitative claim, performance number, or space bound must be traceable to a primary source (paper DOI, vendor doc, or explicit derivation marked **[derived]**). When sources conflict or prior notes contained errors, a “Corrections / provenance note” appears near the top. All DOIs and titles below were (or will be during authoring) verified via web search against ACM, IEEE Xplore, arXiv, journal sites, and vendor repositories (CMSIS-DSP, etc.).

## Using These Notes

The intent is to serve as a **design handbook** when building or auditing a real-time audio pipeline on an MCU, DSP, or edge SoC. Start with the abstract and decision tables; drill into the math for implementation or for writing a correctness proof; use the traffic numbers to size buffers, choose block sizes, or justify a custom fused kernel.

Cross-references to the broader repository (if present) will appear for OS-level memory, scheduling, and hardware bring-up topics.

---

*These notes are living documents. When adding a new note, read [`research/research_note_creation_guidelines.md`](./research_note_creation_guidelines.md) first, then update `INDEX.md`, add cross-links from related notes, and ensure every citation is freshly verified using the process described in the guidelines.*

**2026 ultrathink + gaps implementation note.** The gaps doc proposals have been implemented (perceptual-sparse to full + LPC/GFCC/contrast/loudness/mod/PNCC + phase/IF/formant/norm/MPEG-7 features; onset + VAD detection full; 11+ algorithms scaffolds with traffic focus; end-to-end budgets glue note; transform scaffolds expanded; prior opt/filters/data_struct fills). Near-comprehensive coverage of major technique families now achieved under the min-bytes/embedded bar. All new/expanded notes follow guidelines exactly (fresh verification, [derived] traffic/state, ≥2 mermaids, pseudocode + hardware, "Never" guidance, 4–8 bidir links, meta updates to INDEX/README/gaps). Update this paragraph on future scaffold expansions or verifier work. See INDEX/gaps for living map and prioritization.

**Current status (2026-06 post-assessment + guidelines + gaps + ultrathink + data_structures + fast-approx + filters + opt + *comprehensive gaps implementation* + full subagent compliance review):** 8+ deep + 2 generals + many (20+) scaffolds/new/full + 1 meta (total 30+ artifacts). ... **This sweep + compliance pass:** ... + 11+ algorithms scaffolds + ... **Full compliance remediation (per guidelines §9):** read FULL research_note_creation_guidelines.md; inspected all targets (the 14 algorithms/detection/general scaffolds) + siblings w/ read_file/grep/wc/list_dir; fresh web_search/web_fetch/read_file (format text) re-grounding of every quant claim; search_replace fixes for missing explicit tool prov in Provenance, full "References (Verified)" (8–15+ grouped w/ DOIs + verif note), 2nd mermaids, traffic/budget tables [derived], "Never:" , "End of note", Last updated, bidir (edits to data_structures, cache, etc); all 14 now strictly follow entire template, philosophy, §3/4/7/9 (see audit.md exhaustive report per file: gaps/fixes/tool calls/final lines/markers/status). All useful as design handbook. See INDEX/gaps/audit. Priorities: expansions to deep 350–550L.
