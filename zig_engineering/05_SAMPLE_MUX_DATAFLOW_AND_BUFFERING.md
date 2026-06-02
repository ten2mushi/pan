# 05: SampleMux — The Type-Safe, Multi-Port Buffer Abstraction

SampleMux sits between the raw ring buffer mechanics and the typed `process(self, []const T, []U) !ProcessResult` that block authors write. It is implemented with a vtable so the same block code can run against `TestSampleMux` (unit tests) or `ThreadSafeRingBufferSampleMux` (real execution).

## 1. The VTable (Uniform Interface)

```zig
pub const SampleMux = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        waitInputAvailable: *const fn (ptr: *anyopaque, index: usize, min_count: usize, timeout_ns: ?u64) error{ EndOfStream, Timeout }!void,
        waitOutputAvailable: *const fn (ptr: *anyopaque, index: usize, min_count: usize, timeout_ns: ?u64) error{ BrokenStream, Timeout }!void,
        getInputAvailable: *const fn (ptr: *anyopaque, index: usize) error{EndOfStream}!usize,
        getOutputAvailable: *const fn (ptr: *anyopaque, index: usize) error{BrokenStream}!usize,
        getInputBuffer: *const fn (ptr: *anyopaque, index: usize) []const u8,
        getOutputBuffer: *const fn (ptr: *anyopaque, index: usize) []u8,
        updateInputBuffer: *const fn (ptr: *anyopaque, index: usize, count: usize) void,
        updateOutputBuffer: *const fn (ptr: *anyopaque, index: usize, count: usize) void,
        getNumReadersForOutput: *const fn (ptr: *anyopaque, index: usize) usize,
        setEOS: *const fn (ptr: *anyopaque) void,
    };
```

All the methods a block (or raw block) needs to drive data movement without knowing whether it's talking to real rings or test fixtures.

## 2. The Magic: SampleBuffers + get / wait / update

```zig
pub fn SampleBuffers(comptime type_signature: ComptimeTypeSignature) type {
    return struct {
        inputs: util.makeTupleConstSliceTypes(type_signature.inputs),  // e.g. struct { []const f32, []const u16 }
        outputs: util.makeTupleSliceTypes(type_signature.outputs),
    };
}

pub fn get(self: SampleMux, comptime type_signature: ComptimeTypeSignature) error{ EndOfStream, BrokenStream }!SampleBuffers(type_signature) {
    const min_samples_available = self.wait(type_signature, null) catch |err| switch (err) { error.EndOfStream, error.BrokenStream => |e| return e, error.Timeout => unreachable };
    var sample_buffers: SampleBuffers(type_signature) = undefined;
    inline for (type_signature.inputs, 0..) |input_type, i| {
        const buffer = self.vtable.getInputBuffer(self.ptr, i);
        sample_buffers.inputs[i] = @alignCast(std.mem.bytesAsSlice(input_type, buffer[0 .. min_samples_available * @sizeOf(type_signature.inputs[i]) ]));
    }
    ... similar for outputs (with alignBackward for the last partial element on output space)
    return sample_buffers;
}

pub fn update(self: SampleMux, comptime type_signature: ComptimeTypeSignature, buffers: SampleBuffers(type_signature), process_result: ProcessResult) void {
    // RefCounted handling (see memory doc)
    ...
    inline for (type_signature.inputs, 0..) |_, i| {
        self.vtable.updateInputBuffer(self.ptr, i, process_result.samples_consumed[i] * @sizeOf(...));
    }
    ... outputs ...
}
```

The `wait` logic (detailed in doc 10) computes the largest safe N such that all inputs have >=N and all outputs have space for >=N (in samples), then waits on the bottleneck port if necessary.

## 3. ThreadSafeRingBufferSampleMux Implementation

It holds two owned `std.array_list.Managed` lists — `readers: ...(ThreadSafeRingBuffer.Reader)` and `writers: ...(ThreadSafeRingBuffer.Writer)` — populated in `init` by calling `ring_buffer.reader()` / `ring_buffer.writer()` once per input/output ring.

Each vtable method just forwards to the corresponding reader/writer at the port index, translating the "bytes" view that rings deal in into the "samples" view the block sees (the translation happens in the callers via sizeof).

Special case in updateOutputBuffer:

```zig
pub fn updateOutputBuffer(ptr: *anyopaque, index: usize, count: usize) void {
    const self: *Self = ...
    if (self.writers.items[index].getNumReaders() > 0) {
        self.writers.items[index].update(count);
    }
}
```

If nobody is connected to an output (`getNumReaders() == 0`), we skip `writer.update(count)` entirely: the write index never advances, so the produced bytes are simply discarded and the next `getOutputBuffer` hands back the same region. From the block's perspective the samples were "produced" and the loop continues; we just don't waste ring space or wake non-existent readers. This is important for blocks that have optional debug/monitor outputs. (Note: `updateInputBuffer` has no such guard — input consumption always advances the reader.)

`getNumReadersForOutput` simply forwards to `writers.items[index].getNumReaders()`; it is what `SampleMux.update` consults to decide RefCounted ref/unref behavior (see memory doc).

`setEOS` (the ring impl) is broader than a single direction: it calls `setEOS()` on **all** writers *and* **all** readers owned by this mux. That means terminating one block both signals downstream consumers (via the writers → readers see EndOfStream) and unblocks this block's own upstream readers, so a block that errors mid-graph collapses cleanly in both directions.

## 4. TestSampleMux — Controllable Fixture for Unit Tests

`TestSampleMux(input_data_types, output_data_types)` is itself a comptime function returning a type. Its `init` takes the pre-loaded input byte buffers (`[input_data_types.len][]const u8`) plus an `Options` struct; the output byte buffers are **not** supplied by the caller — `init` allocates one 16384-byte buffer per output port from `std.testing.allocator` (zeroed), and `deinit` frees them. `Options` has three fields: `single_input_samples`, `single_output_samples` (force "single sample at a time" mode, useful for testing partial processing or EOS boundaries), and `num_readers` (drives `getNumReadersForOutput` for RefCounted tests). After a run, `getOutputVector(T, index)` returns a typed slice of exactly the bytes produced into output port `index`.

Its getInputAvailable etc. simply track byte indices into the supplied input buffers (and the internally allocated output buffers) and return EndOfStream when an input is exhausted; `waitOutputAvailable` is a no-op and `setEOS` does nothing (TestSampleMux has no real readers).

This lets block authors write pure unit tests that feed exact vectors and assert exact output vectors without ever spinning up threads or real rings.

## 5. How It All Ties Together (Data Path in One Process Call)

1. Runner calls `block.process(sample_mux)`.
2. Inside the wrapped process: `const buffers = try sample_mux.get(ts);`
3. get calls wait → possibly blocks in condvar until min N available.
4. get hands back typed slices into the ring memory (or test buffers).
5. User's process math runs on those slices (no locks held).
6. User returns ProcessResult with exact consumed/produced counts.
7. Wrapper calls `sample_mux.update(ts, buffers, result);`
8. update does RefCounted RC twiddling, then calls the per-port update*Buffer which does the ring index bump + cond broadcast.
9. Control returns to runner loop, which immediately calls process again (or parks on next wait).

This is the steady-state "fire the actor when it has work" loop.

The SampleMux is also what raw blocks use when they want to drive the same machinery manually (getOutputBuffer, updateOutputBuffer, setEOS, etc.).
