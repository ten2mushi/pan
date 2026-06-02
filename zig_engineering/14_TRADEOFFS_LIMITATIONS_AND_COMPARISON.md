# 14: Trade-offs, Limitations, and GNU Radio Comparison

## Core Trade-offs (Expanded from DESIGN_PHILOSOPHY)

1. **Simplicity of core vs. power of scheduler**
   - Chose N independent threads + blocking rings over a sophisticated central scheduler that could do zero-copy in-tree execution, tag propagation, history, etc.
   - Result: much easier to understand and debug ("there is one thread per block, here is its ring"), but higher context-switch cost and less opportunity for automatic fusion of adjacent blocks.

2. **Large fixed buffers vs. minimal latency**
   - One fixed 8 MiB ring per block *output port* (`RING_BUFFER_SIZE = 8 * 1048576` in flowgraph.zig, shared by up to `MAX_NUM_READERS = 8` consumers) gives excellent jitter absorption and long contiguous work units for DSP efficiency.
   - Cost: higher memory footprint and higher pipeline latency (hundreds of ms at high rates before samples reach the sink).
   - For many SDR receiver use cases this is irrelevant (the "audio" or "decoded bits" latency is dominated by the algorithms themselves, not the plumbing).

3. **Comptime generics everywhere (N in FIR, T in almost everything) vs. runtime polymorphism**
   - Every different filter length or sample type is a completely separate monomorphized type.
   - Pros: zero overhead, full specialization, excellent codegen.
   - Cons: binary size (if you instantiate 50 different filters), longer compile times for huge graphs, no "I want a runtime-variable number of taps" without codegen or a different block.

4. **Mutex + condvar per ring/runner vs. fully lock-free SPSC queues + atomics**
   - The data path (the actual sample copies and math) is effectively lock-free (mutex released before user process runs).
   - The coordination (wait, update, EOS, call) uses mutex/cond.
   - For the target rates this is perfectly fine; a fully lock-free design would have been more complex and error-prone for marginal gain.

5. **Explicit everything vs. "it just works"**
   - User must remember `defer top.deinit()`, must implement initialize if they alloc, must return correct consume/produce counts, etc.
   - This matches Zig culture and gives predictability and debuggability. The price is a slightly steeper initial learning curve than a Python GNU Radio flowgraph.

## Known Limitations (from Code + Design)

- Max 8 readers per output (hardcoded array in RingBuffer).
- No built-in support for "history" / "tags" / "stream tags" (GNU Radio concepts for metadata that travels with samples). You can build it on top using a custom sample type that carries side info + RefCounted if needed.
- No GPU blocks yet (the architecture would support a block whose process submits work to a GPU and waits, or a raw block that manages its own CUDA streams).
- Composites have no first-class initialize/deinitialize (workaround: put a dedicated leaf block inside that does the composite-level resource mgmt).
- No automatic rate conversion or "fractional resampler" primitive in the core (user must wire one if needed).
- Thread priorities / CPU affinity / NUMA are completely up to the user.
- On non-Linux the wrap memcpy in the ring still exists (small, bounded, only on wrap).

## GNU Radio Comparison (Detailed)

**Language & Build**
- ZigRadio: Zig. One language for everything. Fast clean builds. Single static binary possible.
- GNU Radio: C++ core + Python (or C++) for graphs + XML or GR modtool for blocks. Heavy Boost, SWIG or pybind11, cmake, etc. Long build times, many runtime .so's.

**Block Authoring**
- ZigRadio: One .zig file. Write struct + process. `zig build test` immediately exercises it against vectors.
- GNU Radio: .cc + .h + .py (for Python blocks) or full OOT module with cmake, QA, GRC bindings, etc. Much more ceremony.

**Runtime Model**
- ZigRadio: Simple thread-per-block + large aliased rings + blocking. Easy to reason about.
- GNU Radio: Highly configurable scheduler (TPB, STS, etc.), buffer readers with history, message passing, stream tags, hierarchical blocks with more runtime cost. More powerful for very complex flowgraphs, but the core is significantly larger and harder to debug when things go wrong.

**Performance**
- Both can achieve high throughput on the same hardware when using VOLK / liquid / NEON etc.
- ZigRadio's fixed large buffers + contiguous views are great for "set it and forget it" high-rate chains.
- GNU Radio can be tuned for lower latency (smaller buffers, single-threaded scheduler) at the cost of more configuration and potential underruns.

**Use Case Fit**
- ZigRadio shines for: quick prototypes in Zig, embedded-ish deployments where you want a single binary + minimal deps, people who prefer systems languages and explicit control, projects that want to ship a Zig library with radio capability.
- GNU Radio shines for: the enormous existing ecosystem of blocks and hardware support, research/experimentation in Python, GRC visual programming, when you need the advanced scheduler features or message passing.

ZigRadio is explicitly "LuaRadio in Zig" — same minimalist dataflow spirit, same MIT license, same "small core, rich block library" philosophy, but compiled and with stronger type safety.

## When You Might Outgrow ZigRadio

- You need sub-10ms end-to-end latency across many hops on a single core.
- You need rich metadata (tags) that survives rate changes and fanout.
- You want to visually wire graphs in a GUI and have automatic codegen.
- You need the hundreds of existing GNU Radio OOT modules for esoteric modems, FEC, etc.
- You are doing heavy multi-user or networked SDR (the message passing and control plane in GR is more mature).

For the vast majority of "I want to receive FM, decode POCSAG, do some custom PHY experiment, or build a Zig SDR toolkit", the current design is an excellent, coherent fit.
