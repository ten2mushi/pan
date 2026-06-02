# 04: Ring Buffer and "Lock-Free" Communication — The Real-Time Heart

This is the single most important piece of engineering for **real-time performance** in ZigRadio. The ring buffer enables lock-free (in the data path) contiguous sample transfer between independently scheduled block threads, with special virtual memory tricks on Linux to eliminate wrap-around copies entirely.

**Primary source:** `src/core/ring_buffer.zig` (1072 lines).

## 1. The Fundamental Problem in Real-Time DSP Pipelines

In a threaded dataflow graph:
- Block A (upstream) produces samples at some rate into a buffer.
- Block B (downstream) consumes them.
- They run on separate OS threads (see runners doc 06).
- Producer must never block forever (or underrun downstream), consumer must get contiguous views for efficient SIMD/DSP loops.
- Wrap-around in a classic ring is painful: you either memcpy to linearize, or handle two segments in every consumer (complex, error-prone, kills vectorization).

ZigRadio solves it with **double-mapped virtual memory** (or double-sized copy fallback) + careful index math + thread-safe coordination.

## 2. Two Memory Implementations (Platform-Adaptive Zero-Copy)

From the top of ring_buffer.zig (whitespace condensed; multi-line struct returns collapsed to one line — otherwise faithful to source):

```zig
const CopiedMemoryImpl = struct {
    allocator: std.mem.Allocator,
    buf: []u8,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !CopiedMemoryImpl {
        const buf = try allocator.alloc(u8, capacity * 2);
        // Zero initialize buffer
        for (buf) |*e| e.* = 0;
        return .{ .allocator = allocator, .buf = buf };
    }

    pub fn deinit(self: *CopiedMemoryImpl) void {
        self.allocator.free(self.buf);
    }

    pub fn alias(self: *CopiedMemoryImpl, dest: usize, src: usize, count: usize) void {
        @memcpy(self.buf[dest .. dest + count], self.buf[src .. src + count]);
    }
};

const MappedMemoryImpl = struct {
    fd: std.posix.fd_t,
    buf: []align(std.heap.page_size_min) u8,

    const MappingError = error{ MappingNotAdjacent };

    pub fn init(_: std.mem.Allocator, capacity: usize) !MappedMemoryImpl {
        // Create memfd
        const fd = try std.posix.memfd_create("ring_buffer_mem", 0);
        errdefer std.posix.close(fd);

        // Size memory
        try std.posix.ftruncate(fd, capacity);

        // Map the file with two regions of capacity
        const mapping1 = try std.posix.mmap(null, 2 * capacity, std.posix.PROT.READ | std.posix.PROT.WRITE, .{ .TYPE = .SHARED }, fd, 0);
        errdefer std.posix.munmap(mapping1);

        // Remap second region to first
        const mapping2 = try std.posix.mmap(@alignCast(mapping1.ptr + capacity), capacity, std.posix.PROT.READ | std.posix.PROT.WRITE, .{ .TYPE = .SHARED, .FIXED = true }, fd, 0);
        errdefer std.posix.munmap(mapping2);

        // Validate mapping is adjacent
        if (@intFromPtr(mapping2.ptr) < @intFromPtr(mapping1.ptr) or @intFromPtr(mapping2.ptr) - @intFromPtr(mapping1.ptr) != capacity) {
            return MappingError.MappingNotAdjacent;
        }

        return .{ .fd = fd, .buf = mapping1.ptr[0 .. capacity * 2] };
    }

    pub fn deinit(self: *MappedMemoryImpl) void {
        std.posix.munmap(self.buf);
        std.posix.close(self.fd);
    }

    pub fn alias(_: *MappedMemoryImpl, _: usize, _: usize, _: usize) void {
        // No-op
    }
};

const DefaultMemoryImpl = if (builtin.os.tag == .linux) MappedMemoryImpl else CopiedMemoryImpl;
```

**Platform selection (verbatim, line 74):** `const DefaultMemoryImpl = if (builtin.os.tag == .linux) MappedMemoryImpl else CopiedMemoryImpl;`. So **Linux is the only platform with the zero-copy mapping**; everything else (macOS, BSD, Windows) uses `CopiedMemoryImpl`. Note the Linux mechanism is specifically **memfd_create + ftruncate + two mmaps** (a placeholder `mmap` of `2*capacity` to reserve a contiguous region, then a `FIXED` mmap of the second `capacity` window onto the same fd). There is no `vm_remap`/`shm`/`MAP_ALIASED` path for macOS/BSD in this source — non-Linux always copies.

**Why this works for realtime:**
- On Linux: the two halves are the **same physical memory**. A write to [capacity .. 2*capacity) is instantly visible at [0 .. capacity). No cache issues for the alias because it's the same pages.
- Producer can always get a **single contiguous []u8** of up to (capacity-1) bytes even when wrapping.
- Consumer same.
- The `alias()` call (which does the copy on non-Linux or when needed for the "lagging reader" case) only happens at `updateWriteIndex` time, and only for the wrapped portion.

Test for mapped (verbatim):

```zig
test "MappedMemoryImpl" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    ...
    // Fill upper region
    @memcpy(memory1.buf[capacity..], &buf1);
    ...
    // Validate lower (the alias)
    try std.testing.expectEqualSlices(u8, memory1.buf[0..capacity], &buf1);
    ...
}
```

## 3. Ring Buffer State Machine and Math (The "Contiguous Illusion")

Excellent diagram + states in the source comments (verbatim):

```zig
// RingBuffer is a ring buffer implemented with an adjacent, aliased memory
// region to allow for contiguous reads and writes at all times.
//
//     R points to unread data
//     W points to unwritten data
//     E points to end of virtual buffer
//    2E points to end of real buffer
//
// It exists in two basic states:
//
// R <= W
//
//   |-----------|xxxxxxxxxxx|-------| |-------------------------------|
//   0           R           W       E E                               2E
//
//      Write Available = E - W + R - 1
//       Read Available = W - R
//
// R > W
//
//   |xxx|----------------|xxxxxxxxxx| |xxx|----------------|xxxxxxxxxx|
//   0   W                R          E E                               2E
//
//      Write Available = R - W - 1
//       Read Available = E - R + W
//
// Empty and Full States:
//
// Empty (R == W, case R <= W)
//
//   |-----------------------|-------| |-------------------------------|
//   0                       R       E E                               2E
//                           W
//
//      Write Available = E - W + R - 1 = E - 1
//       Read Available = W - R = 0
//
// Full (W = R - 1, case R > W)
//
//   |xxxxxxxxxxxxxxxxxxxxxx||xxxxxxx| |xxxxxxxxxxxxxxxxxxxxxxxxxxxxx|-|
//   0                      WR       E E                               2E
//
//
//      Write Available = R - W - 1 = R - R + 1 - 1 = 0
//       Read Available = E - R + W = E - R + R - 1 = E - 1
```

**Core struct (verbatim):**

```zig
fn RingBuffer(comptime MemoryImpl: type) type {
    return struct {
        const Self = @This();

        // Max number of readers supported
        pub const MAX_NUM_READERS = 8;

        // Memory and Configuration
        memory: MemoryImpl,
        capacity: usize,
        num_readers: usize = 0,

        // Accounting State
        read_index: [MAX_NUM_READERS]usize = [_]usize{0} ** MAX_NUM_READERS,
        write_index: usize = 0,
        read_eos: bool = false,
        write_eos: bool = false,
        // ... (constructor/destructor, helpers, write/read API below)
```

**Min read index (for multiple readers / backpressure):**

```zig
pub fn _minReadIndex(self: *Self) usize {
    // Optimize for single reader and no reader
    if (self.num_readers == 1) {
        return self.read_index[0];
    } else if (self.num_readers == 0) {
        return 0;
    }

    // Find lagging reader index
    var min_weight: usize = std.math.maxInt(usize);
    var min_index: usize = 0;
    for (self.read_index[0..self.num_readers], 0..) |read_index, i| {
        const weight = if (read_index <= self.write_index) read_index + self.capacity else read_index;
        if (weight < min_weight) {
            min_weight = weight;
            min_index = i;
        }
    }

    return self.read_index[min_index];
}
```

This is crucial: the "full" calculation is always relative to the **slowest** downstream reader. A fast reader cannot make the writer think there is space if a slow fanout branch is lagging. This prevents silent data loss in broadcast scenarios.

**Write path (get + update):**

```zig
pub fn getWriteAvailable(self: *Self) usize {
    const min_read_index = self._minReadIndex();
    return if (min_read_index <= self.write_index) self.capacity - self.write_index + min_read_index - 1 else min_read_index - self.write_index - 1;
}

pub fn getWriteBuffer(self: *Self, count: usize) []u8 {
    return self.memory.buf[self.write_index .. self.write_index + count];
}

pub fn updateWriteIndex(self: *Self, count: usize) void {
    // Copy over wrapped bytes to adjacent region if write index is wrapped
    if (self.write_index + count > self.capacity) {
        self.memory.alias(0, self.capacity, self.write_index + count - self.capacity);
    } else if (self.write_index < self._minReadIndex()) {
        self.memory.alias(self.capacity + self.write_index, self.write_index, count);
    }

    self.write_index = (self.write_index + count) % self.capacity;
}
```

Note the two alias cases: normal wrap (write past E), and the case where writer is "behind" min reader in the modular sense (the R > W case).

**One slot is always sacrificed:** the maximum write-available is `capacity - 1` (see the `- 1` in `getWriteAvailable` and the diagrams' `E - 1`). This is the classic ring-buffer trick to disambiguate full (`W = R - 1`) from empty (`W = R`) without a separate count. So a buffer constructed with `capacity = N` holds at most `N - 1` bytes of live data. Indices are taken `% self.capacity` (virtual size `E`), never `% (2 * capacity)`; the second mapped/copied half exists only so the slice `buf[write_index .. write_index + count]` (or read equivalent) is always contiguous even when it crosses `E`.

Read API (per-reader `index`): `getReadAvailable(index)`, `getReadBuffer(index, count)` (returns `[]const u8`), `updateReadIndex(index, count)`, `getReadEOS`, `setWriteEOS`. Read availability is computed against `write_index` directly (not the min-reader), so each reader sees its own backlog: `if (read_index[i] <= write_index) write_index - read_index[i] else capacity - read_index[i] + write_index`. Note `updateReadIndex` performs no `alias()` — only the writer ever copies wrapped bytes.

## 4. Thread-Safe Wrapper (Coordination, Not Data Path)

```zig
fn _ThreadSafeRingBuffer(comptime RingBufferImpl: type) type {
    return struct {
        const Self = @This();

        impl: RingBufferImpl,

        // Lock and Condition Variables
        mutex: std.Thread.Mutex = .{},
        cond_read_available: std.Thread.Condition = .{},
        cond_write_available: std.Thread.Condition = .{},

        // ... (init/deinit, Writer, Reader, writer()/reader() factories)
```

**Writer (verbatim for the methods shown; `getNumReaders` and a test-only `write` helper are elided):**

```zig
pub const Writer = struct {
    ring_buffer: *Self,

    pub fn getAvailable(self: *const @This()) error{BrokenStream}!usize {
        self.ring_buffer.mutex.lock();
        defer self.ring_buffer.mutex.unlock();
        if (self.ring_buffer.impl.getWriteEOS()) return error.BrokenStream;
        return self.ring_buffer.impl.getWriteAvailable();
    }

    pub fn waitAvailable(self: *@This(), min_count: usize, timeout_ns: ?u64) error{ BrokenStream, Timeout }!void {
        self.ring_buffer.mutex.lock();
        defer self.ring_buffer.mutex.unlock();
        while (self.ring_buffer.impl.getWriteAvailable() < min_count) {
            if (self.ring_buffer.impl.getWriteEOS()) return error.BrokenStream;
            if (timeout_ns) |timeout| {
                try self.ring_buffer.cond_write_available.timedWait(&self.ring_buffer.mutex, timeout);
            } else {
                self.ring_buffer.cond_write_available.wait(&self.ring_buffer.mutex);
            }
        }
    }

    pub fn getBuffer(self: *@This()) []u8 {
        self.ring_buffer.mutex.lock();
        defer self.ring_buffer.mutex.unlock();
        return self.ring_buffer.impl.getWriteBuffer(self.ring_buffer.impl.getWriteAvailable());
    }

    pub fn update(self: *@This(), count: usize) void {
        self.ring_buffer.mutex.lock();
        defer self.ring_buffer.mutex.unlock();
        self.ring_buffer.impl.updateWriteIndex(count);
        self.ring_buffer.cond_read_available.broadcast();
    }

    pub fn setEOS(self: *@This()) void { ... broadcast read cond ... }
};
```

**Key realtime property:** `getBuffer()` + the subsequent `memcpy` or DSP write into the slice happens **while the mutex is held** in the current code? Wait — look:

In `getBuffer`:

```zig
pub fn getBuffer(self: *@This()) []u8 {
    self.ring_buffer.mutex.lock();
    defer self.ring_buffer.mutex.unlock();
    return self.ring_buffer.impl.getWriteBuffer(self.ring_buffer.impl.getWriteAvailable());
}
```

**The returned slice is valid only while the lock is conceptually "logically" held for the caller?** But the defer unlocks immediately after the return expression evaluates. In Zig, the slice header is copied out, but the underlying memory is the ring buf which is safe as long as we don't let readers advance past us.

But the actual write by the caller (the block's process fn) happens **after** this function returns, i.e. **with the mutex released**.

See usage in SampleMux (doc 05): the block receives `[]T` views, does its math, then calls `update` which re-acquires the mutex only for the index bump + broadcast.

This is correct and good for realtime: the expensive DSP work (FIR, demod, etc.) happens **without holding the per-ring mutex**. Only the small index update + cond wakeup is serialized.

Note the wakeup asymmetry: `Writer.update` calls `cond_read_available.broadcast()` (wake *all* readers — necessary because one write can satisfy multiple fanout readers), whereas `Reader.update` calls `cond_write_available.signal()` (a single writer waits on write-availability, so one wakeup suffices). `Writer.setEOS` broadcasts `cond_read_available`; `Reader.setEOS` signals `cond_write_available`.

Reader APIs mirror the writer: `getAvailable`/`waitAvailable`/`getBuffer`/`update`/`setEOS`, plus a test-only `read` helper. `Reader.getBuffer` returns `[]const u8` (read-only view) and is created via `ring_buffer.reader()`, which calls `impl.addReader()` to assign the per-reader index.

## 5. EOS and Stream Termination Semantics (Critical for Clean Shutdown)

There are two independent EOS flags (`read_eos`, `write_eos`) and two directions. Note the naming is from the perspective of which side the flag *blocks*:

- **Reader → Writer (BrokenStream):** `Reader.setEOS()` calls `impl.setWriteEOS()` (sets `write_eos`). The writer's `getAvailable()`/`waitAvailable()` check `impl.getWriteEOS()` and return `error.BrokenStream` (downstream died or stop requested).
- **Writer → Reader (EndOfStream):** `Writer.setEOS()` calls `impl.setReadEOS()` (sets `read_eos`). The reader's `getAvailable()`/`waitAvailable()` check `impl.getReadEOS()` and return `error.EndOfStream` (source exhausted).

Note the subtle drain difference between the two reader entry points:
- `Reader.getAvailable()` only returns `EndOfStream` when `available == 0 and getReadEOS()` — so any buffered data is reported (and can be consumed) before EOS surfaces (see the "read wait eos with partial read" test, where 3 bytes are still delivered after the writer set EOS).
- `Reader.waitAvailable(min_count, ...)` returns `EndOfStream` as soon as `getReadEOS()` is true while the loop's `getReadAvailable(index) < min_count` (it doesn't wait to be drained), so a blocked reader wakes immediately on EOS even if it can never reach `min_count`.

In the threaded runner:

```zig
const process_result = runner.block.process(...) catch |err| switch (err) {
    error.EndOfStream => break,
    ...
};
if (process_result.eos) break;
...
runner.sample_mux.setEOS();  // propagates to all connected rings
```

For sources, `stop()` on the runner calls the block's stop (for raw) or for normal the EOS is triggered by the source returning EOS from process.

This gives **clean, race-free termination** of the entire pipeline without leaking threads or deadlocking on cond waits.

## 6. Configuration in Flowgraph (Hardcoded for Predictability)

From flowgraph.zig:

```zig
const FlowgraphRunState = struct {
    ...
    const RING_BUFFER_SIZE = 8 * 1048576;  // 8 MiB per output port !!

    pub fn init(...) !FlowgraphRunState {
        ...
        try ring_buffers.put(output, try ThreadSafeRingBuffer.init(allocator, RING_BUFFER_SIZE));
        ...
    }
```

**Why 8MB?** At 1 MS/s complex float (8 bytes/sample) that's 1M samples ~1 second of buffering. At audio rates (48kHz) it's many seconds. This is deliberately large to:
- Absorb OS thread scheduling latency / priority inversion.
- Allow bursty producers (e.g. file sources, USB transfers in rtlsdr).
- Give downstream blocks large contiguous chunks for efficient processing (SIMD likes 4k+).

Tradeoff: higher memory use and higher pipeline latency (samples may sit in ring for a while before consumer wakes).

## 7. Multi-Reader Fanout Support

`addReader()` just bumps num_readers and returns an index. Each reader has independent read_index.

The writer always respects the *minimum* of them for available space. This implements classic "broadcast" semantics with backpressure from the slowest consumer — exactly what you want in a signal processing fanout (e.g. one branch for demod, one for spectrum, one for recording).

## 8. Testing Rigor (Evidence of Correctness Focus)

Hundreds of lines of tests, including:
- Single/multi reader wrap cases with explicit alias verification (`try std.testing.expectEqualSlices` on the aliased regions).
- Threaded waiter tests using ResetEvent + timedWait to prove blocking/ wakeup.
- EOS propagation in both directions, partial read + EOS, etc.
- MappedMemoryImpl validation on Linux.

This level of testing on the comms primitive is why the higher-level realtime claims are credible.

## 9. Realtime Implications and Gotchas

**Strengths:**
- Contiguous views → blocks can do tight `for` loops or pass slices directly to accel libs without scatter/gather.
- Large fixed buffers → statistical headroom against jitter.
- Broadcast + min-reader backpressure → safe fanout.
- Mutex only around coordination → DSP work parallel and unserialized (except the actual CPU cores).
- EOS is a first-class, observable stream condition, not an ad-hoc flag.

**Limitations (observed from code):**
- Not "lock free" in the academic sense for the control plane (mutex + cond). For very high-rate tiny blocks this could show contention, but for typical SDR (kS/s to low MS/s per block) it's fine.
- All readers see the *same* data (broadcast). No selective dropping.
- MAX 8 readers per buffer (compile-time array).
- On non-Linux, every wrap does a small memcpy (the alias). Still better than per-block linearization.
- Writer/reader get/ update always take the mutex, even for non-blocking fast path. Could be optimized with atomics + seqlocks for pure SPSC, but multi-reader + blocking made the condvar approach simpler and correct.

## 10. Connection to Higher Layers

- `FlowgraphRunState` creates one `ThreadSafeRingBuffer` **per output port** of every block.
- For each block, it collects the relevant input rings + output rings and creates a `ThreadSafeRingBufferSampleMux`.
- The `SampleMux` vtable then delegates to the per-reader/writer objects.
- Blocks never see rings; they see typed slices via the mux + comptime signature.

This completes the "plumbing" that makes the dataflow philosophy (doc 01) and the block abstraction (doc 03) actually execute in real time.

See:
- Doc 05 for how SampleMux uses these buffers to compute "how many samples can I safely give the block right now?"
- Doc 06 for the threads that call into this.
- Doc 10 for end-to-end pipeline latency / underrun analysis.

The ring buffer is the reason ZigRadio can claim "real-time pipeline" with a straightforward threaded model instead of a complex single-threaded scheduler or lock-free queues everywhere.
