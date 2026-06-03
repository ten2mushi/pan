# Handoff — end of Session 4 (P4 "Tier-A executor + CoreAudio vertical slice") → into P5

> **Status:** P0 + P1 + P2 + P3 + **P4 implemented and green**. This is an advisory
> handoff, not a spec: the `specifications/` corpus and `pan_implementation_plan.md`
> remain the source of truth.
> **Date:** 2026-06-03. **Toolchain:** `zig 0.16.0` (re-run `zig version` at P5 start — Rule 13).
> No commit made (the user had not asked). Session ran "Full P4, accept the overrun" with the
> "cross-compiling extern seam" device-backend realism (the user's explicit choices).

---

## 1. Ownership statement (honest, Rule 12)

Every P4 work item (`pan_implementation_plan.md` §4) is implemented and **verified green** across the
four-mode matrix: **Debug / ReleaseSafe / ReleaseFast** test suites all exit 0, the freestanding
**ReleaseSmall smoke** object compiles, the Linux **ALSA seam cross-compiles**
(`zig build cross-linux`), `fmt-check` passes, and `zig build bench` runs (~4500× realtime, 100%
deadline headroom on the gain→biquad→pan chain at every block size 128–1024).

**What is the user's to run (cannot be done from a sandbox — no audio device / no 10-min loop):**
the *measured* gate — **sub-5 ms round-trip on M3, zero xruns over 10 min, FTZ confirmed live on the
device thread**. The compute headroom is enormous (per-render ≈ 0.6–4.9 µs vs the N/Fs deadline), and
FTZ-on-thread is unit-tested (a subnormal squared underflows to exactly 0 after
`enterRealtimeThread()`), but opening CoreAudio and running the loop is on-device work.

**Yoneda dispatch (Rule 14):** four autonomous `yoneda-test-writer` agents (each told to load
`zig-0-16` + verify by compiling), given the code section + invariant + comparison mode but not the
tests: `tests/executor_test.zig` (15), `tests/dsp_filters_test.zig` (18), `tests/dsp_spatial_test.zig`
(18), `tests/io_codec_test.zig` (39). No bugs found in the under-test code by any writer.

---

## 2. The central new architecture — kernel binding (read before P5)

The P3 commit pass left `RenderOp.fn_ptr`/`self_ptr` null and the IR stores `@typeName`, not `type`.
**P4 binds kernels by monomorphizing the executor over the comptime graph + a parallel node-id →
block-type tuple**, NOT by a runtime commit pass:

- `commit.zig`: `RenderOp` gained **`node_id`** (op-list is topo-ordered, so op index ≠ node id; the
  executor keys off this to recover each node's block type/instance). `Plan` gained the **pool layout**
  the executor needs: `pool_buffer_count`, `pool_bytes`, `buffer_offset[id]`, `buffer_byte_len[id]`
  (each pool buffer id → a `[offset, offset+len)` window; `len = N·element_size` of its class). All
  filled in the footprint stage. The 54 P3 commit tests + smoke gate stayed green.
- `engine.zig`: `Executor(comptime g: graph.Graph, comptime node_blocks: []const type)` →
  owns a `[pool_bytes]u8 align(64)` pool + an `instances` tuple (`std.meta.Tuple(node_blocks)`, one
  block per node in node-id order, caller-seeded). `render(token)` `inline for`s the op-list, and per
  op builds the typed `process` arg tuple (`std.meta.ArgsTuple`) by pulling input slices (each
  `[]const A` param) and output slices (each `[]A` param) from the pool by buffer id, then `@call`s.
  Exposes `Exec.committed` (the comptime Plan) and `telemetry()`.
- **It handles POOL buffers only** — a `@compileError` fires if `footprint_bytes != pool_bytes` (i.e.
  if persistent delay/feedback state is present). That is **P6** territory (feedback primitives).
- It handles **Map** blocks (`process`); a `Rate` block's `pull` is not yet bound (the P4 slice is
  all-Map; the in-memory `LpcmSource` is modeled as a zero-input Map Source per SR1).
- The **runtime commit pass + RCU `edit→commit`** (a *runtime* graph → plan) is deliberately NOT done
  here; it belongs with P5's control plane. The builder (`builder.Graph`) still just `summarize()`s.

This satisfies the spec's `fn_ptr(self_ptr, gather, scatter, n)` op-list model AND "the whole plan
inlines on embedded" — the monomorphized `inline for` IS the binding.

---

## 3. What was built (this session's deltas)

```
src/commit.zig   (M)  RenderOp += node_id; Plan += pool_buffer_count/pool_bytes/
                      buffer_offset[]/buffer_byte_len[]; footprint stage emits the pool layout.
src/engine.zig   (REBUILT) RealtimeToken now sets REAL flush-to-zero: ARM64 FPCR FZ (bits 24+19)
                      via mrs/msr; x86 MXCSR FTZ/DAZ via stmxcsr/ldmxcsr; saved word restored on
                      .leave(); no-op on other arches. enterRealtimeThread() mints it. The
                      monomorphized Executor (above). Telemetry += fault. Error isolation: a NaN/Inf
                      block output is silenced + fault raised (guarded by runtime_safety, i.e.
                      compiled out in release per guards_compiled_out). Free renderInto() kept as the
                      token-gated replay shell. Runtime Engine shell unchanged in shape.
src/simd.zig     (NEW) Compute HAL: scaleFloat (@Vector(W,T) + scalar tail), qMulStore (saturating
                      fixed-point round-and-store). W from the Numeric trait.
src/filters.zig  (NEW) Gain(num) — aliasing_safe, float SIMD + q-format int path.
                      Biquad(num) — Map, per-sample z⁻¹ Mealy DF2T (== scipy.signal.lfilter),
                      NOT aliasing_safe. Coeffs(T).
src/spatial.zig  (NEW) ConstantPowerPan(num) — mono Sample → stereo Frame, L=cosθ R=sinθ, L²+R²=1.
src/io.zig       (NEW) PcmFormat (16 named: s/u 8/16/32 LE+BE, s24 packed LE+BE, f32/f64 LE+BE);
                      decodeSample/encodeSample (normalize↔bytes, round+saturate, dither offset);
                      ChannelPos + canonicalOrder(L) + channelPermutation (⊢ total/bijective);
                      deinterleave/interleave (format + channel reorder); Dither (TPDF, seeded);
                      LpcmSource(num) (Map source over a preloaded buffer, loops); AudioBackend
                      vtable seam; CoreAudioSink/Source (Darwin, extern AudioToolbox, callconv(.c)
                      render callback that mints the token); AlsaSink (Linux, extern asound);
                      Unsupported (no-op, fails loud).
src/root.zig     (M)  re-export simd/filters/spatial/io/Executor; realtime.enterRealtimeThread.
build.zig        (M)  linkPlatformAudio() (macOS→AudioToolbox/CoreAudio/CoreFoundation+libc;
                      Linux→asound+libc) on lib/exe/test/bench modules; cross-linux step (builds the
                      static lib for x86_64-linux-gnu — no link, so no sysroot libasound needed);
                      bench step (ReleaseFast); 4 new harnesses wired.
build.zig.zon    (M)  .paths += "bench".
scripts/generate.py (M) _ref_biquad (scipy.signal.lfilter, with a byte-identical pure-numpy DF2T
                      fallback when scipy is absent — this env has numpy, not scipy) + _ref_pan
                      (constant power). References map extended.
tests/vectors/   (NEW) biquad_f32.json, pan_f32.json manifests (committed). The *.bin blobs are
                      generate-on-demand + git-ignored; the gold tests read them at runtime and skip
                      gracefully when absent.
bench/harness.zig, bench/dsp_chain.zig (NEW) the measurement kit (std.Io.Clock timer, consume sink,
                      counting allocator, byteDisplacement) + the gain→biquad→pan throughput bench.
tests/executor_test.zig, dsp_filters_test.zig, dsp_spatial_test.zig, io_codec_test.zig (NEW, Yoneda).
```

---

## 4. Verification — how to reproduce green

From `/Users/komorebi/Documents/projects/tools/audio/pan`:
```sh
zig build                               # lib + CLI (links AudioToolbox on macOS)  → PASS
zig build test                          # full suite (Debug)                       → EXIT 0
zig build test -Doptimize=ReleaseSafe   #                                          → EXIT 0
zig build test -Doptimize=ReleaseFast   #                                          → EXIT 0
zig build smoke                         # freestanding ReleaseSmall comptime-commit → PASS
zig build cross-linux                   # x86_64-linux-gnu ALSA-seam compile gate   → PASS
zig build fmt-check                     #                                          → PASS
zig build bench                         # gain→biquad→pan throughput (ReleaseFast)  → prints numbers
python3 scripts/generate.py tests/vectors/biquad_f32.json   # regenerate gold blobs (numpy; scipy optional)
```
> **Carried cosmetic noise (P2, still live):** `aliasing_message_test` / `comparator_test` drive
> reject paths and `std.debug.print` diagnostics ("aliasing hazard…", "oracle allclose fail…"); the
> 0.16 build runner echoes "failed command" for those, but the suite exits 0. Use
> `std.debug.print`, never `std.log.err`, for expected-reject diagnostics (the runner counts logged
> errors and exits non-zero otherwise).

---

## 5. Honest gaps carried into P5+ (Rule 12)

- **Live device gate is the user's** (no audio HW / no 10-min loop in the sandbox). The CoreAudio
  render-callback path *compiles + links* (AudioToolbox) but is **not opened/run** here.
- **`CoreAudioSource` (capture)** is shape-pinned and returns `error.CaptureNotYetImplemented` — the
  P4 slice is output-sink + in-memory source; input-unit config lands when live capture is exercised.
- **B≡C through the executor** is **P7** (the commit-level B≡C differential exists from P3; the
  executor currently runs the `.colored` plan only — wiring the `.per_edge` baseline behind a runtime
  `getBuffer` and the B≡C executor differential is P7, as the P4 handoff already noted).
- **Persistent state in the executor** (delay rings / feedback z⁻¹) is **P6** — the executor
  `@compileError`s if `footprint_bytes != pool_bytes` today.
- **`Rate`/`pull` binding** in the executor is unimplemented (P4 slice is all-Map); needed when a
  real `Rate` block (framer/resampler) rides the executor (P8).
- **q15 biquad/pan gold vectors** not added (q15 gain manifest exists; the slice is f32). The
  fixed-point kernel paths in `filters`/`spatial` exist (qMulStore) but lack committed gold vectors.
- **Telemetry**: `fault` + `guards_compiled_out` are live; `xrun_count`/`deadline_headroom`/
  `per_block_cpu`/`spin_time` are populated by the device loop / bench, not the headless executor.

---

## 6. What P5 needs (from `pan_implementation_plan.md` Phase 5)

P5 = **roadmap step 2** + the parameter-port machinery: the three control verbs at exact atomic
orderings (`set`/`schedule`/`edit→commit`), runtime format negotiation (auto-resampler on rate
mismatch), one ramped (zipper-free) parameter, no audio-thread lock. **Read first** (plan §5):
`pan_concurrency_and_memory_ordering.md` (all of it), `pan_io_realtime_and_pipeline.md` §7,
`catalog.md` §2.4/§6/§10, `pan_type_and_numeric_model.md` §1.1/§2; skill ch.03 §11 (atomics), ch.05.
The hooks P4 leaves: the runtime commit + RCU plan swap (the `edit→commit` mechanism) consume the
P4 op-list/pool-layout; `ConstantPowerPan` already declares a `param.pan` slot ready for the wired-edge
/ `set` source; the negotiate stage (`coercionFor`) already decides `resample`/`ramp_hold` (P3) — P5
materializes the coercion node bodies and the SPSC ring / atomic-scalar / RCU mechanisms.

---

## 7. Conventions carried forward

Unchanged: §0.2 self-contained code docs (no spec-section refs in `src/` — verified clean); §0.3
⊢/≈/▷ markers; §0.5 oracle-allclose vs pan-vs-pan-bit-exact; §0.6 four-mode CI matrix +
`guards_compiled_out`; Rule 13 load `zig-0-16` + tell every subagent; Rule 14 dispatch Yoneda
writers; Rule 10 checkpoint. **New convention:** any executable importing `pan` must link the
platform audio transport — `build.zig`'s `linkPlatformAudio(target, mod)` does this; call it for any
new test/bench/exe module (the I/O HAL pulls CoreAudio/ALSA `extern`s).
