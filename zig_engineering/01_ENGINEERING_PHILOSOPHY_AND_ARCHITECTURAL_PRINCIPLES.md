# 01: Engineering Philosophy and Architectural Principles

This document dives deep into ZigRadio's **engineering philosophy**. The primary source is the project's own `docs/DESIGN_PHILOSOPHY.md`, but it is expanded, validated, and exemplified with **verbatim code** from the implementation (src/core/*, blocks, etc.). The goal is to understand *why* the code is structured this way, especially for enabling reliable real-time DSP pipelines in a systems language (Zig).

## 1. Core Paradigm: Dataflow Programming

From DESIGN_PHILOSOPHY.md (verbatim):

> ZigRadio implements the **dataflow programming model**, where computation is expressed as a directed graph of processing nodes (blocks) connected by edges (sample streams). This paradigm is ideal for signal processing because:
> 1. **Natural representation** - Signal processing chains map directly to graph structures
> 2. **Parallelism** - Independent blocks can execute concurrently
> 3. **Composability** - Complex systems built from simple, reusable components
> 4. **Declarative** - Focus on "what" rather than "how"

The Flow:

```
Samples originate at SOURCE blocks
        ↓
Flow through PROCESSING blocks
        ↓
Terminate at SINK blocks
```

The graph runs until all sources exhaust their data (End-of-Stream propagation).

**Implementation evidence (verbatim from flowgraph.zig and runner.zig):**

In practice, this is realized via:

- `Flowgraph` owns connections (hashmaps of ports), flattened connections, block_set.
- Each `Block` exposes a `process` (or raw `start`) that is invoked by its dedicated runner thread.
- Data moves exclusively through `ThreadSafeRingBuffer` instances (one per output port).

Key verbatim from `src/core/flowgraph.zig`:

```zig
pub const Flowgraph = struct {
    ...
    connections: std.AutoHashMap(InputPort, OutputPort),
    flattened_connections: std.AutoHashMap(BlockInputPort, BlockOutputPort),
    block_set: std.AutoHashMap(*Block, void),
    ...
    pub fn run(self: *Flowgraph) !bool {
        ...
        try self.start();
        return try self.wait();
    }
    ...
};
```

And the runner loop (from runner.zig, ThreadedBlockRunner):

```zig
const Runner = struct {
    fn run(runner: *ThreadedBlockRunner) !void {
        while (true) {
            if (runner.stop_event.isSet()) {
                break;
            } else if (runner.call_event.isSet()) {
                // Give calling thread a chance to lock the mutex
                std.Thread.sleep(std.time.ns_per_us);
            }

            runner.mutex.lock();
            defer runner.mutex.unlock();

            const process_result = runner.block.process(runner.sample_mux) catch |err| switch (err) {
                error.EndOfStream => break,
                else => {
                    runner.process_error = err;
                    break;
                },
            };
            if (process_result.eos) {
                break;
            }
        }

        runner.sample_mux.setEOS();
    }
};
```

This per-block thread + ring buffer edge is the concrete realization of dataflow "actors" firing when data is available (via `SampleMux.wait` which blocks on condvars).

## 2. Architectural Layers (Verbatim Diagram + Code Mapping)

From DESIGN:

```
┌────────────────────────────────────────────────────────────┐
│                     User Application                        │
├────────────────────────────────────────────────────────────┤
│                     Block Library                           │
│  (Sources, Signal Processing, Digital, Sinks, Composites)  │
├────────────────────────────────────────────────────────────┤
│                     Core Framework                          │
│  (Flowgraph, Block, CompositeBlock, SampleMux, RingBuffer) │
├────────────────────────────────────────────────────────────┤
│                     Utilities                               │
│  (Filter Design, Windowing, Math Functions)                │
├────────────────────────────────────────────────────────────┤
│                     Platform Layer                          │
│  (Dynamic Library Loading, Signal Handling)                │
└────────────────────────────────────────────────────────────┘
```

**Mapping to files (verbatim imports and structure):**

- Top: `src/radio.zig` reexports:
```zig
pub const Block = @import("core/block.zig").Block;
pub const CompositeBlock = @import("core/composite.zig").CompositeBlock;
pub const Flowgraph = @import("core/flowgraph.zig").Flowgraph;
pub const platform = @import("core/platform.zig");
pub const blocks = @import("blocks/index.zig");
```

- Core: All under `src/core/`.
- Blocks live in `src/blocks/` (and mirrored test vectors in `src/vectors/blocks/`).

This layering enforces **separation of concerns** (see principle 4 below). User code rarely touches core directly except via `radio.Flowgraph` and `radio.Block.init(@This())`.

## 3. Key Design Principles (with Code Proofs)

### 3.1 Compile-Time Type Safety

From DESIGN (verbatim):

> Block type signatures are derived at compile time through Zig's comptime introspection:
> ```zig
> // The type signature is automatically extracted from the process() method
> pub fn process(self: *MyBlock, input: []const f32, output: []f32) !ProcessResult { ... }
> ```
> The framework:
> - Extracts input/output types from `process()` function signatures
> - Validates port type compatibility when connecting blocks
> - Reports type mismatches at runtime with clear error messages

**Verbatim implementation in `src/core/block.zig`:**

```zig
pub fn init(comptime BlockType: type) Block {
    // Block needs to have a process method
    if (!@hasDecl(BlockType, "process")) {
        @compileError("Block " ++ @typeName(BlockType) ++ " is missing the process() method.");
    }

    // Derive type signature from process method
    const type_signature = ComptimeTypeSignature.init(BlockType.process);
    if (type_signature.inputs.len == 0 and !@hasDecl(BlockType, "setRate")) {
        @compileError("Source block " ++ @typeName(BlockType) ++ " is missing the setRate() method.");
    }

    // Generate input and output names
    comptime var _inputs: [type_signature.inputs.len][]const u8 = undefined;
    comptime var _outputs: [type_signature.outputs.len][]const u8 = undefined;
    inline for (type_signature.inputs, 0..) |_, i| _inputs[i] = comptime std.fmt.comptimePrint("in{d}", .{i + 1});
    inline for (type_signature.outputs, 0..) |_, i| _outputs[i] = comptime std.fmt.comptimePrint("out{d}", .{i + 1});
    const inputs = _inputs;
    const outputs = _outputs;

    return .{
        .name = comptime extractBlockName(BlockType),
        .inputs = &inputs,
        .outputs = &outputs,
        .type_signature = comptime RuntimeTypeSignature.init(type_signature),
        .set_rate_fn = if (@hasDecl(BlockType, "setRate")) comptime wrapSetRateFunction(BlockType, BlockType.setRate) else null,
        ...
        .process_fn = comptime wrapProcessFunction(BlockType, type_signature, BlockType.process),
    };
}
```

The wrapper generator itself (critical for zero-overhead + type erasure):

```zig
fn wrapProcessFunction(comptime BlockType: type, comptime type_signature: ComptimeTypeSignature, comptime processFn: anytype) fn (self: *Block, sample_mux: SampleMux) anyerror!ProcessResult {
    const gen = struct {
        fn process(block: *Block, sample_mux: SampleMux) anyerror!ProcessResult {
            const self: *BlockType = @alignCast(@fieldParentPtr("block", block));

            // Get sample buffers
            const buffers = try sample_mux.get(type_signature);

            // Process sample buffers
            const process_result = try @call(.auto, processFn, .{self} ++ buffers.inputs ++ buffers.outputs);

            // Update sample buffers
            sample_mux.update(type_signature, buffers, process_result);

            // Return process result
            return process_result;
        }
    };
    return gen.process;
}
```

**Runtime validation (flowgraph.zig _validate):**

```zig
if (!std.mem.eql(u8, k.*.type_signature.inputs[i], upstream_connection.?.block.type_signature.outputs[upstream_connection.?.index])) {
    return FlowgraphError.DataTypeMismatch;
}
```

This is **compile-time extraction + runtime checking** hybrid: types are known statically per block, but heterogeneous graph requires string names for mismatch reporting.

See also full `types.zig` in document 07.

### 3.2 Zero-Overhead Abstractions

DESIGN:

> ZigRadio leverages Zig's comptime features to eliminate runtime overhead:
> - **Generic blocks** instantiated at compile time for specific types
> - **Function pointers** generated once during block initialization
> - **Type erasure** only where necessary for heterogeneous collections

Evidence:
- `LowpassFilterBlock(comptime T: type, comptime N: comptime_int)` — full generic, FIR taps sized at CT.
- Wrappers above are generated per-block-type at the `Block.init(@This())` callsite (comptime).
- The `Block` struct holds function pointers (set once), then dispatches with `@fieldParentPtr` cast — classic Zig "vtable by hand" or "fat pointer" but per-type monomorphized.
- No virtual calls in hot path beyond the one indirect fn ptr per block (which the compiler can often devirtualize).

Raw mode exists to escape even the standard process wrapper for absolute minimum overhead/special control:

```zig
pub fn initRaw(...) Block { ... .raw = true, .start_fn = ... }
```

### 3.3 Lock-Free Communication (or "Mostly Lock-Free" in Practice)

DESIGN claims:

> Inter-block communication uses lock-free ring buffers with virtual memory aliasing.

**Reality from ring_buffer.zig (verbatim core struct and alias logic):**

There are two impls:

```zig
const DefaultMemoryImpl = if (builtin.os.tag == .linux) MappedMemoryImpl else CopiedMemoryImpl;
```

Linux uses `memfd_create` + two adjacent `mmap` (second with FIXED at +capacity) so the *same physical pages* appear twice contiguously in virtual address space. This makes wrap-around reads/writes always contiguous — **zero memcpy for aliasing**.

Verbatim `MappedMemoryImpl`:

```zig
pub fn init(_: std.mem.Allocator, capacity: usize) !MappedMemoryImpl {
    const fd = try std.posix.memfd_create("ring_buffer_mem", 0);
    errdefer std.posix.close(fd);
    try std.posix.ftruncate(fd, capacity);
    const mapping1 = try std.posix.mmap(null, 2 * capacity, std.posix.PROT.READ | std.posix.PROT.WRITE, .{ .TYPE = .SHARED }, fd, 0);
    errdefer std.posix.munmap(mapping1);
    const mapping2 = try std.posix.mmap(@alignCast(mapping1.ptr + capacity), capacity, std.posix.PROT.READ | std.posix.PROT.WRITE, .{ .TYPE = .SHARED, .FIXED = true }, fd, 0);
    ...
    return .{ .fd = fd, .buf = mapping1.ptr[0 .. capacity * 2] };
}
```

Alias op is no-op on mapped:

```zig
pub fn alias(_: *MappedMemoryImpl, _: usize, _: usize, _: usize) void {
    // No-op
}
```

Copied fallback (portable):

```zig
pub fn init(allocator: std.mem.Allocator, capacity: usize) !CopiedMemoryImpl {
    const buf = try allocator.alloc(u8, capacity * 2);
    ...
}
pub fn alias(self: *CopiedMemoryImpl, dest: usize, src: usize, count: usize) void {
    @memcpy(self.buf[dest .. dest + count], self.buf[src .. src + count]);
}
```

**The ring logic itself (non-blocking data path) is "lock free" in the sense that once you have the buffer slice via getWriteBuffer/getReadBuffer, you memcpy directly with no lock held during the actual sample copy.** The mutex is only for index updates + availability queries + cond signaling:

```zig
pub fn update(self: *@This(), count: usize) void {
    self.ring_buffer.mutex.lock();
    defer self.ring_buffer.mutex.unlock();
    self.ring_buffer.impl.updateWriteIndex(count);
    self.ring_buffer.cond_read_available.broadcast();
}
```

In hot path (inside block.process after SampleMux.get succeeds), the block does direct slice ops on the returned `[]T` views into the aliased memory — **no locks during DSP math**.

This is the classic "lock-free ring with external synchronization for coordination" pattern. For pure single-producer single-consumer without waits, atomics could replace mutex, but the design chose condvar + mutex for simplicity, blocking semantics, and multi-reader support (the min-read-index logic).

See document 04 for full ring math and _minReadIndex.

### 3.4 Separation of Concerns

Table from DESIGN (verbatim):

| Component | Responsibility |
|-----------|----------------|
| `Block` | Single unit of signal processing |
| `CompositeBlock` | Hierarchical block composition |
| `Flowgraph` | Graph construction, validation, execution orchestration |
| `SampleMux` | Type-safe sample buffer management |
| `RingBuffer` | Lock-free inter-block communication |
| `Runner` | Block thread lifecycle management |

This is strictly followed: no block knows about threads or rings; it only sees `SampleMux`. Flowgraph wires everything at start time.

### 3.5 Explicit Resource Management

DESIGN:

> Following Zig conventions:
> - All allocations go through `std.mem.Allocator`
> - Blocks have explicit `initialize()` and `deinitialize()` lifecycle hooks
> - RAII patterns with `defer` for cleanup

Verbatim in user example (README):

```zig
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
...
var top = radio.Flowgraph.init(gpa.allocator(), .{ .debug = true });
defer top.deinit();
...
_ = try top.run();
```

Framework side (flowgraph):

```zig
pub fn _initialize(self: *Flowgraph) !void {
    ...
    try platform.initialize(self.allocator);
    for (evaluation_order.keys()) |block| try block.initialize(self.allocator);
}
pub fn _deinitialize(self: *Flowgraph) void {
    var block_it = self.block_set.keyIterator();
    while (block_it.next()) |block| {
        block.*.deinitialize(self.allocator);
    }
}
```

Blocks like filters allocate FIR state only in initialize (using rate from `self.block.getRate(f32)`).

### 3.6 Optional Acceleration

DESIGN verbatim:

> Performance-critical operations can use external libraries when available:
> ```zig
> pub var libs: struct {
>     liquid: ?std.DynLib,
>     volk: ?std.DynLib,
>     fftw3f: ?std.DynLib,
> } = ...
> ```
> Blocks check for availability and fall back to pure Zig implementations.

Implementation (platform.zig verbatim):

```zig
pub fn initialize(allocator: std.mem.Allocator) !void {
    debug.enabled = try lookupEnvFlag(allocator, "ZIGRADIO_DEBUG");
    if (libs.liquid == null and !try lookupEnvFlag(allocator, "ZIGRADIO_DISABLE_LIQUID")) {
        libs.liquid = std.DynLib.open("libliquid.so") catch null;
    }
    ... volk, fftw3f similar with ZIGRADIO_DISABLE_* envs
}
```

This embodies "pragmatic performance": pure Zig is always correct and portable; accel is best-effort and discovered at runtime. Matches "simplicity over features".

## 4. Type System Design (Summary; Deep in Doc 07)

Two layers:
- `ComptimeTypeSignature`: introspects the `process` fn signature using `@typeInfo` on params, distinguishes input (`const` pointer slice) vs output.
- `RuntimeTypeSignature`: maps to string names ("ComplexFloat32", "Float32", user `typeName()`) for the heterogeneous graph validation and debug dumps.

Special `RefCounted(T)` wrapper with atomic RC + custom `typeTag` for cases where samples need shared ownership (e.g. across fanout without copy?).

## 5. Block Categories and Execution Model

- **Sources**: 0 inputs, implement `setRate`, drive data.
- **Processing**: N inputs/outputs, transform (or rate change via setRate).
- **Sinks**: inputs only, consume.
- **Composites**: facade + internal wiring via aliases (see doc 09).
- **Raw mode**: opt-out of the standard process+SampleMux loop; block owns its `start` and calls sample_mux vtable methods directly. Useful for "I need to control the exact timing/loop" (e.g. some hardware? or test raw sources).

Standard mode = one OS thread per Block (see runners).

## 6. Error Handling Philosophy

Zig errors everywhere ( `!T` ), no exceptions. Flowgraph collects per-block errors post-run. Specific sentinel errors for stream conditions: `EndOfStream`, `BrokenStream`.

From flowgraph stop logic: sources get stop() signal, which for raw can setEOS etc.

## 7. Memory Model (Preview of Doc 08)

- Fixed 8MB usable ring capacity per output port (`FlowgraphRunState.RING_BUFFER_SIZE = 8 * 1048576`, passed as `capacity` to `ThreadSafeRingBuffer.init`).
- Backing memory is allocated/mapped at `capacity * 2` (16MB) so the second half mirrors the first, giving a contiguous alias window. The usable ring capacity remains the full 8MB (write index wraps at `% capacity`).
- All user blocks use the passed `allocator` in initialize only.
- No per-sample allocations in steady state (critical for realtime jitter).
- RefCounted allows "zero-copy" fanout for expensive sample types by bumping RC instead of memcpy.

## 8. Comparison with GNU Radio (from DESIGN, expanded)

| Aspect | ZigRadio | GNU Radio |
|--------|----------|-----------|
| Language | Zig | C++ with Python bindings |
| Block creation | Single file, pure Zig | Multiple files, XML |
| Dependencies | Minimal (Zig stdlib) | Heavy (Boost, SWIG, etc.) |
| Compilation | Fast, single binary | Slow, complex build |
| Runtime | Thread-per-block + ring + cond | Scheduler-based (more complex) |
| Learning curve | Moderate | Steep |

ZigRadio deliberately simpler and more "systems" — everything explicit, comptime instead of runtime polymorphism, fixed buffering strategy.

## 9. Design Trade-offs (verbatim from DESIGN + analysis)

1. **Simplicity over features** — Core framework is minimal; complexity in block library.
2. **Performance over convenience** — Lock-free designs require careful programming (actually mutex-protected coordination + lock-free data path).
3. **Static over dynamic** — Compile-time polymorphism preferred over runtime (generics on every filter tap count!).
4. **Explicit over implicit** — Resource management is always explicit (`defer top.deinit()`).

Additional observed tradeoff: **Predictable realtime over absolute minimal latency**. 8MB buffers + condvar wakeups + thread scheduling mean higher latency than a single-threaded pull scheduler (GNU Radio has options for this), but much simpler "just works" concurrent pipeline for high sample rates (e.g. 1MS/s+ RTL-SDR chains). The large buffers absorb bursts and OS scheduling jitter.

## 10. Future Directions (from DESIGN)

- Additional hardware source blocks
- GPU acceleration blocks
- Network streaming blocks
- More modulation/demodulation schemes
- Integration with visualization tools

The architecture (pluggable blocks via `Block.init`, optional platform libs, raw mode) supports these without core changes.

## Conclusion: Philosophy in One Sentence

ZigRadio is a **minimalist, comptime-heavy, explicitly-resourced dataflow DSP framework** that uses per-block threads + virtually-aliased large ring buffers + blocking sample mux coordination to deliver simple-to-author, reliable real-time SDR pipelines, preferring compile-time guarantees and Zig idioms over heavy runtime machinery or convenience layers.

This philosophy is not just stated — it is **mechanically enforced** by the code patterns (comptime wrappers, explicit initialize, allocator passing, no global singletons except the accel lib table).

Next: See document 02 for the Flowgraph as the central orchestrator that makes the philosophy executable.
