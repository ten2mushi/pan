# ZigRadio — Engineering Design Audit

**Subject:** zigradio v0.10.0 (Zig 0.15), ~7.1k LOC core + blocks. A streaming flowgraph DSP/SDR framework, philosophically a "LuaRadio in Zig."
**Audit basis:** direct source reading of `core/{block,flowgraph,ring_buffer,sample_mux,runner,types,composite,platform,util}.zig`, blocks, build, and test infrastructure.

## Scorecard

| Dimension | Score | One-line verdict |
|---|---|---|
| Architecture & modularity | 9/10 | Clean layering; small, sharp, well-separated |
| Comptime type system & API | 9/10 | Best-in-class; zero-boilerplate type-safe wiring |
| Testing & verification | 9/10 | NumPy/SciPy gold-vector methodology is exemplary |
| Memory discipline (RT) | 8/10 | Alloc-at-init, explicit allocator; predictable |
| Concurrency correctness | 8/10 | Correct backpressure; sound but coarse locking |
| Performance & efficiency | 7/10 | Great data plane; locked control plane; TPB ceiling |
| Portability / platform | 6/10 | Headline zero-copy is **Linux-only**; others memcpy |
| Error handling & resilience | 5/10 | Post-mortem only; any error collapses the graph |
| Scalability (large graphs) | 5/10 | Thread-per-block + fixed 8 MiB/port don't scale |
| Feature completeness | 5/10 | Streaming-only; no message ports, no runtime reconfig |
| **Overall (scope-weighted)** | **≈7.8/10** | Excellent *for its intended niche*; real architectural ceilings |

---

## What is genuinely well-engineered

**1. Comptime type signature extraction (the standout).** `ComptimeTypeSignature.init` introspects a block's `process` function: `[]const T` parameters become inputs, `[]T` become outputs (`types.zig:20–25`). The framework derives the entire port type contract from one idiomatic function signature — no macros, no registration tables, no manual port declarations. Wrapper generation (`wrapProcessFunction` et al.) erases the generic-to-`*Block` boundary at compile time with `@fieldParentPtr`/`@call`, so the vtable indirection carries zero per-sample cost. This is the cleanest expression of "the type system *is* the API" I'd expect to see in Zig, and it's the project's strongest engineering idea.

**2. Verification methodology.** DSP correctness is anchored to NumPy/SciPy reference output: `generate.py` emits seeded gold vectors (`random.seed(1)`, fixed precision) and `BlockTester` checks block output against them within epsilon. This is the *right* way to test signal processing — it tests against an independent mathematical oracle, not against the implementation's own assumptions. Most hobby DSP frameworks never reach this bar.

**3. The Linux ring buffer.** `MappedMemoryImpl` uses `memfd_create` + double `mmap` (the second `MAP_FIXED` at `ptr+capacity`) to create a virtual mirror, with an explicit adjacency assertion (`ring_buffer.zig:49–61`). A reader/writer can take a *contiguous* slice across the wrap boundary with no memcpy and no branchy split handling. That's a sophisticated, correct implementation of a well-known trick.

**4. RT memory discipline.** Allocator is threaded explicitly everywhere; allocation happens in `initialize`, never in `process`. `RefCounted(T)` with comptime specialization means the reference-counting path is emitted *only* for ports whose element type is actually a RefCounted wrapper — the common Copy-type pipeline pays nothing.

**5. Graceful degradation.** Optional VOLK/liquid/FFTW acceleration is discovered at runtime via `std.DynLib` with `catch null` and a pure-Zig fallback. No hard runtime dependencies, env-var overrides for disabling — a mature posture for an optional-accel design.

---

## Where the design has real ceilings

**1. Concurrency model: thread-per-block.** `ThreadedBlockRunner.spawn` creates one OS thread per block running a `while(true)` process loop (`runner.zig:83–113`). For a 5-block receiver this is fine. For a large graph (composites flatten to many blocks) you get oversubscription, context-switch overhead, and zero scheduling control — no thread pool, no work-stealing, no core affinity, no RT priority. This is the same model early GNU Radio used and later moved away from for exactly these reasons. It's *correct*, but it's a scalability ceiling baked into the architecture.

**2. "Lock-free" is overstated.** The data plane is genuinely lock-free (operate on contiguous slices), but every `get`/`update`/`waitAvailable` takes a per-ring `mutex` and signals a condvar (`ring_buffer.zig:301–307, 367–373`). The control plane is mutex-coordinated. Backpressure itself is implemented *correctly* — a writer blocks on `cond_write_available.wait` in a proper `while` guard until space frees — but the design's own philosophy doc claiming "lock-free … atomic index updates" is aspirational, not what the code does. At very high rates with tiny block sizes, that mutex is the contention point.

**3. Portability regression — the headline feature is Linux-only.** `DefaultMemoryImpl = if (os == .linux) MappedMemoryImpl else CopiedMemoryImpl`. On macOS/BSD/Windows, `CopiedMemoryImpl` allocates `capacity*2` and **memcpies the wrapped tail on every wrap**. So the marquee "zero-copy contiguous ring" advantage simply does not exist off Linux — and macOS *could* support it via `vm_remap`/Mach, but that path isn't implemented. For a framework whose differentiator is the ring buffer, single-platform coverage of that differentiator is a notable gap.

**4. Fixed 8 MiB per output port — non-tunable.** `RING_BUFFER_SIZE = 8 * 1048576` is a hardcoded constant (16 MiB backing each). Consequences: (a) memory scales with port count — a 40-port flattened graph is ~640 MiB of backing RAM, regardless of actual rate; (b) it's a one-size latency/throughput tradeoff — great for jitter absorption at MS/s, but an unnecessarily deep buffer (and latency floor) for a 48 kHz audio tail, and there is no per-edge override. A production framework would expose this as a policy.

**5. Error handling is post-mortem and all-or-nothing.** Block errors aren't handled where they occur; they propagate as `EndOfStream`/`BrokenStream` that cascade through `setEOS` (which signals *both* directions), collapsing the entire flowgraph, and are only collected later in `wait()`. There is no per-block recovery, restart, or supervision — fine for batch/offline runs, weak for a long-running receiver you want to stay up. Compounding this: `RawBlockRunner.getError` always returns `null` (`runner.zig:48`), so raw blocks structurally cannot report process errors to the framework.

**6. Feature scope is narrow by design.** Pure synchronous streaming only — no message/async ports (GNU Radio's PMT message passing), no runtime graph reconfiguration (topology is static after `connect`), no tags/metadata travelling with samples, single-writer rings (many-to-one needs an explicit combiner block). These are legitimate scope choices for a lightweight library, but they're the difference between "SDR teaching/hobby framework" and "production SDR runtime."

**7. Minor:** the `CyclicDependency` detection path exists but is never exercised by any test; a couple of `@constCast` unref sites are flagged "ugly but safe" by the author (they are safe, but they signal the const-correctness model leaking at the RefCounted boundary).

---

## Verdict

ZigRadio is a **high-quality, tightly-scoped piece of engineering** that punches well above its ~7k LOC. Its comptime type machinery and gold-vector test methodology are genuinely excellent and would hold up in a much larger project. The architecture is clean, the RT memory discipline is disciplined, and the data-plane design is sound.

Its ceilings are architectural, not sloppy: thread-per-block scheduling, mutex-coordinated control plane, a Linux-only zero-copy path, a non-tunable fixed buffer, and collapse-on-error semantics. None of these are bugs — they are deliberate simplicity-over-generality tradeoffs that are *correct for an SDR teaching/prototyping framework and a single-machine receiver*, but that would each need rework before this could serve as a general-purpose, many-block, multi-platform, resilient production DSP runtime.

**Scope-appropriate grade: A− (≈7.8/10).** As "LuaRadio reimagined with Zig's compile-time safety," it succeeds cleanly. As a candidate to scale to large graphs, run resiliently for days, or deliver its signature zero-copy benefit cross-platform, it has clear, namable next-step work.

### Suggested next-step engineering backlog (high-impact)

- **Thread-pool / cooperative scheduler** to replace one-OS-thread-per-block (removes the large-graph scaling ceiling).
- **Configurable per-edge buffer sizing** (policy instead of the hardcoded 8 MiB constant) to control memory and latency.
- **macOS `vm_remap` mapped-ring implementation** so the zero-copy advantage is not Linux-only.
- **Block supervision / error reporting for raw runners** (`RawBlockRunner.getError`) and optional per-block restart for long-running receivers.
