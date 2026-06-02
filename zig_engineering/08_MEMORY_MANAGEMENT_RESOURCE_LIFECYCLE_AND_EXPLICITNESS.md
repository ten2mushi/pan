# 08: Memory Management, Resource Lifecycle, and Explicitness

ZigRadio's memory story is a textbook example of **Zig engineering culture** applied to a real-time DSP framework: everything is explicit, allocations are front-loaded, steady-state is allocation-free, and the framework gives you the tools (but not the magic) to manage lifetime correctly.

## 1. The Allocator is King — Passed Everywhere

No hidden allocators, no global `std.heap.page_allocator` in hot paths, no `ArrayList` growing in `process()`.

**User entry point (verbatim README / examples):**

```zig
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
...
var top = radio.Flowgraph.init(gpa.allocator(), .{ .debug = true });
defer top.deinit();
```

**Framework contract (block.zig, flowgraph.zig):**

```zig
pub fn initialize(self: *Block, allocator: std.mem.Allocator) !void {
    if (self.initialize_fn) |initialize_fn| try initialize_fn(self, allocator);
}
...
// In Flowgraph._initialize
for (evaluation_order.keys()) |block| try block.initialize(self.allocator);
```

Every block that needs memory does so in its `initialize`, using the allocator it was given at graph init time.

Example from LowpassFilterBlock (verbatim):

```zig
pub fn initialize(self: *Self, allocator: std.mem.Allocator) !void {
    const nyquist = self.options.nyquist orelse (self.block.getRate(f32) / 2);
    const taps = firwinLowpass(N, self.cutoff / nyquist, self.options.window);
    return self.filter.initialize(allocator, taps[0..]);
}

pub fn deinitialize(self: *Self, allocator: std.mem.Allocator) void {
    self.filter.deinitialize(allocator);
}
```

The FIRFilter (presumably) does `allocator.alloc` for its delay line / taps copy inside its own initialize.

## 2. Ring Buffers — The Big Fixed Allocations

Per-output-port ring is allocated once at `FlowgraphRunState.init`, before any threads are spawned:

```zig
const RING_BUFFER_SIZE = 8 * 1048576;

...
try ring_buffers.put(output, try ThreadSafeRingBuffer.init(allocator, RING_BUFFER_SIZE));
```

`RING_BUFFER_SIZE` is `8 * 1048576` = **8 MiB** (8,388,608 bytes), and it is the *capacity* passed to `ThreadSafeRingBuffer.init`. The ring is double-mapped/double-buffered: the actual backing region is `capacity * 2` = **16 MiB** per output. On Linux the `MappedMemoryImpl` does a `memfd_create` + `ftruncate(fd, capacity)` and two `mmap`s of `capacity` each (the second `FIXED`-mapped immediately after the first), so the *physical* memory is one 8 MiB memfd but the virtual span is 16 MiB. On other platforms `CopiedMemoryImpl` does `allocator.alloc(u8, capacity * 2)`, i.e. a real 16 MiB heap allocation that is zero-initialized.

These are **never freed until deinit of the run state** (after all threads joined). Predictable, large, long-lived.

Inside the ring, the `alias()` calls on wrap (for CopiedMemoryImpl) do bounded memcpys of the wrapped region — still O(wrap size) but only at update time, and the size is at most the chunk the block just produced.

## 3. RefCounted(T) — Optional Shared Ownership Without Copy

For cases where you want fanout of "heavy" sample types without duplicating the payload on every downstream connection, there is `RefCounted`.

Verbatim from types.zig:

```zig
pub fn RefCounted(T: type) type {
    return struct {
        const Self = @This();
        value: T,
        rc: std.atomic.Value(usize),

        pub fn init(args: anytype) Self {
            return .{ .value = @call(.auto, T.init, args), .rc = std.atomic.Value(usize).init(1) };
        }

        pub fn ref(self: *Self, count: usize) void {
            _ = self.rc.fetchAdd(count, .monotonic);
        }

        pub fn unref(self: *Self) void {
            if (self.rc.fetchSub(1, .acq_rel) == 1) {
                self.value.deinit();
            }
        }

        pub fn typeName() []const u8 {
            return "RefCounted(" ++ comptime RuntimeTypeSignature.map(T) ++ ")";
        }

        pub fn typeTag() TypeTag { return .RefCounted; }
    };
}
```

**Integration in SampleMux.update (verbatim):**

```zig
pub fn update(self: SampleMux, comptime type_signature: ComptimeTypeSignature, buffers: SampleBuffers(type_signature), process_result: ProcessResult) void {
    // Handle RefCounted(T) inputs (decrement reference count)
    inline for (type_signature.inputs, 0..) |input_type, i| {
        if (comptime hasTypeTag(input_type, .RefCounted)) {
            // TODO @constCast() here is ugly, but safe
            for (buffers.inputs[i]) |*e| @constCast(e).unref();
        }
    }

    // Handle RefCounted(T) outputs (increment reference count for additional readers)
    inline for (type_signature.outputs, 0..) |output_type, i| {
        if (comptime hasTypeTag(output_type, .RefCounted)) {
            const num_readers = self.vtable.getNumReadersForOutput(self.ptr, i);
            switch (num_readers) {
                0 => for (buffers.outputs[i]) |*e| e.unref(), // No readers
                1 => {}, // Elements already initialized with an rc of 1
                else => for (buffers.outputs[i]) |*e| e.ref(num_readers - 1), // Ref additional readers
            }
        }
    }

    // Then the normal byte-count updates to the rings
    ...
}
```

When a block produces RefCounted samples, the framework bumps the refcount for each additional reader beyond the first (the first consumer gets rc=1 from the producer's init). When consumers are done with their slice, they unref in the input handling.

This is a classic intrusive atomic RC pattern, safe for the lock-free-ish ring world because the actual `value.deinit()` only happens on the last unref (with acq_rel).

Most blocks don't use this (simple f32 / Complex(f32) are Copy and cheap). It exists for future or user-defined heavy sample types (e.g. large FFT bins, packets with metadata, etc.).

## 4. Explicit Lifecycle Hooks on Blocks

Every block can implement (optional):

- `setRate(upstream_rate: f64) !f64` — required for sources; can transform for rate-changing blocks.
- `initialize(allocator) !void`
- `deinitialize(allocator) void`
- `process(...) !ProcessResult` (or `start` for raw)

The framework calls them at well-defined times:
- setRate during `_propagateRates` (after the evaluation order is built, before any threads), in evaluation (topological) order.
- initialize after platform init, before spawn, iterating the evaluation order's keys.
- deinitialize in `_deinitialize`, after all runners joined; it iterates `block_set.keyIterator()` (i.e. hash-map order, **not** reverse and **not** the evaluation order).

User blocks that hold resources (file handles, device handles, allocated arrays, liquid/volk plans, etc.) **must** use initialize/deinitialize. The `defer top.deinit()` in user code + framework's `_deinitialize` ensures cleanup even on error paths.

See RtlSdrSource: it does all the DynLib lookup + rtlsdr_open + configuration in `initialize`, stores `dev`, and in `deinitialize` calls `rtlsdr_close(dev)` (guarded by `if (self.dev) |dev|`). The pattern is mandated and followed here.

## 5. No Allocations in the Steady-State Hot Path

This is non-negotiable for real-time DSP:

- `process()` receives slices that are **views into pre-allocated ring memory** or the block's own pre-allocated state (from initialize).
- `ProcessResult` is a small struct with fixed [8]usize arrays — no lists, no heap.
- SampleMux.get does some comptime unrolling + bytesAsSlice, but zero alloc.
- The only "alloc" in the data path would be if a block author mistakenly did one inside process — the framework gives no encouragement or helpers that would do it.

Contrast with languages that do small-vector optimization or arena-per-iteration implicitly.

## 6. Flowgraph Run State Owns the Transient Execution Memory

When you `start()` or `run()`:

```zig
self.run_state = try FlowgraphRunState.init(self.allocator, &self.flattened_connections, &self.block_set);
```

This allocates:
- The map of rings (N outputs).
- The map of sample_muxes (N blocks).
- The map of runners (N blocks).
- Inside each ring: the memory impl (16 MiB = 8 MiB capacity * 2, either an `alloc` on non-Linux or a memfd-backed double `mmap` on Linux).
- Inside each ThreadSafeRingBufferSampleMux: two ArrayLists of Reader/Writer (the reader() calls do `addReader` which just bumps a counter).

All of this is freed in `run_state.deinit()` which is called from `wait()` after joins.

Between start and stop, the only growing structures are the rings themselves (their indices move, but the backing memory is fixed).

## 7. Error Paths and Partial Initialization

See flowgraph test "Flowgraph initialize and deinitialize blocks":

If a later block's initialize fails, earlier blocks that succeeded have already been initialized — but the test shows that on error from `_initialize`, only the blocks up to the failure point have `initialized=true`. The framework does **not** automatically deinitialize the successful prefix on error (the caller of run() is expected to call deinit on the Flowgraph, which will deinit the run_state if any, but the block-level initialized state is left as-is?).

Looking at code:

```zig
pub fn _initialize(self: *Flowgraph) !void {
    try self._validate();
    ... build order, rates, dump, platform.initialize
    for (evaluation_order.keys()) |block| try block.initialize(self.allocator);
}
```

If one throws, previous ones in the loop have run their initialize. The Flowgraph deinit will **not** call block deinitialize unless run_state existed (which it doesn't on init failure).

In practice, blocks are expected to be written so that a failed initialize leaves no resources (or the block's own state tracks partial init). This is a minor sharp edge, but consistent with "explicit".

In the error block test, the source got initialized, the error block did not, and after the failed _initialize the source's initialized flag was left true — user would need to deinit the whole top or manually clean.

## 8. Platform Global State (the Exception that Proves the Rule)

```zig
pub var libs: struct { liquid: ?std.DynLib, volk: ?std.DynLib, fftw3f: ?std.DynLib } = ...
```

These are process-global and loaded once (with disable env var support) in `platform.initialize`, which is called from Flowgraph._initialize.

They are never unloaded (DynLib has no close in the shown code? std.DynLib on close would be manual).

This is the only real "singleton" state. Acceptable because:
- It's optional acceleration.
- Loading is idempotent (guarded by `if (libs.xxx == null)`).
- Unloading dynamic libs with live symbols is notoriously dangerous; better to leak till process exit.

## 9. Zig Idioms Used Heavily

- `defer top.deinit();` and `defer foo.deinit();` everywhere in tests and examples.
- `errdefer` for cleanup on failure paths inside inits.
- `std.array_list.Managed` (the one that takes allocator in init) for the temporary lists in flowgraph.
- No `try` in hot paths that would allocate (the error handling is for stream conditions, not OOM).
- `std.heap.GeneralPurposeAllocator` recommended in examples (with its leak checking potential).

## 10. Realtime Predictability Benefits

Because of the above:
- You can know the *exact* memory high-water mark after the first successful `start()` (sum of all ring sizes + per-block initialize sizes + a few small maps).
- No malloc in the audio/DSP callback equivalent (the process threads).
- Backpressure via ring full/empty is deterministic (modulo OS scheduling).
- Reference counting is atomic and only on the (rare) RefCounted path; normal samples are just bytes moved by the block's own code.
- Deallocation is batched at graph stop time.

This is why "ReleaseFast + explicit everything" works well for SDR on commodity hardware.

## Summary Table of Allocations

| Phase              | What is Allocated                          | When Freed          | In Hot Path? |
|--------------------|--------------------------------------------|---------------------|--------------|
| Flowgraph.init     | HashMaps for connections, aliases, etc.    | Flowgraph.deinit    | No           |
| _initialize        | platform libs (once), block.initialize() resources | _deinitialize     | No           |
| RunState.init      | 16 MiB ring backing per output (8 MiB capacity * 2), muxes, runners | RunState.deinit (post-wait) | No     |
| Block process      | None (views into rings + block state)      | N/A                 | **No**       |
| Ring update (wrap) | Small memcpy (non-Linux) or no-op (Linux)  | N/A                 | Yes (but bounded) |
| RefCounted         | Atomic inc/dec + possible deinit of T      | Last unref          | Rare         |

This explicit, front-loaded, steady-state-free model is a core part of the engineering philosophy (see doc 01, principle 5).
