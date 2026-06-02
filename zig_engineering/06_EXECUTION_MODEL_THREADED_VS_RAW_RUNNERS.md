# 06: Execution Model — ThreadedBlockRunner vs RawBlockRunner

The execution model is how the abstract dataflow graph becomes **concurrent, real-time running code**. This document analyzes `src/core/runner.zig` in full, with context from flowgraph and block.

## 1. Two Execution Strategies

ZigRadio deliberately offers two ways a block can run:

1. **Standard (Threaded)**: The framework owns the loop. Block implements `process(self, input_slices..., output_slices...) !ProcessResult`. Framework spawns a thread that repeatedly calls process via SampleMux.
2. **Raw**: The block owns the loop. Block implements `start(self, sample_mux: SampleMux) !void` (and optionally `stop`). It is responsible for its own while-loop, calling the vtable methods on the mux to get/put data. Useful when the block has unusual timing, needs to interleave I/O in a specific way, or wants to avoid the per-iteration overhead of the standard mux.

This is exposed at Block construction time:

```zig
// In block.zig
pub fn init(comptime BlockType: type) Block { ... .process_fn = wrap... }
pub fn initRaw(comptime BlockType: type, ...) Block {
    ...
    .raw = true,
    .start_fn = comptime wrapStartFunction(...),
    .process_fn = null,
}
```

FlowgraphRunState decides at init time:

```zig
if (block.*.raw) {
    try block_runners.put(block.*, .{ .raw = try RawBlockRunner.init(...) });
} else {
    try block_runners.put(block.*, .{ .threaded = try ThreadedBlockRunner.init(...) });
}
```

## 2. ThreadedBlockRunner — The Default Real-Time Engine (Verbatim)

```zig
pub const ThreadedBlockRunner = struct {
    block: *Block,
    sample_mux: SampleMux,

    running: bool = false,
    process_error: ?anyerror = null,

    thread: std.Thread = undefined,
    mutex: std.Thread.Mutex = .{},
    call_event: std.Thread.ResetEvent = .{},
    stop_event: std.Thread.ResetEvent = .{},

    pub fn init(_: std.mem.Allocator, block: *Block, sample_mux: SampleMux) !ThreadedBlockRunner {
        return .{
            .block = block,
            .sample_mux = sample_mux,
        };
    }

    pub fn deinit(self: *ThreadedBlockRunner) void {
        if (self.running) {
            self.stop();
            self.join();
        }
    }

    pub fn spawn(self: *ThreadedBlockRunner) !void {
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

        self.thread = try std.Thread.spawn(.{}, Runner.run, .{self});
        self.running = true;
    }

    pub fn call(self: *ThreadedBlockRunner, comptime function: anytype, args: anytype) @typeInfo(@TypeOf(function)).@"fn".return_type.? {
        self.call_event.set();
        self.mutex.lock();
        defer self.mutex.unlock();
        defer self.call_event.reset();

        const block = @as(@typeInfo(@TypeOf(function)).@"fn".params[0].type.?, @alignCast(@fieldParentPtr("block", self.block)));
        return @call(.auto, function, .{block} ++ args);
    }

    pub fn stop(self: *ThreadedBlockRunner) void {
        self.stop_event.set();
    }

    pub fn join(self: *ThreadedBlockRunner) void {
        self.thread.join();
        self.running = false;
    }

    pub fn getError(self: *const ThreadedBlockRunner) ?anyerror {
        return self.process_error;
    }
};
```

**Critical design details for realtime:**

- The inner `while(true)` loop **never yields except on EOS or error**. It relies on the blocking behavior of `block.process` → `SampleMux.get` → `wait` on condvars inside the ring readers/writers. When no data, the thread parks in the kernel. When data arrives, broadcast wakes it.
- The tiny sleep when `call_event` is set is a polite yield to let the external caller acquire the mutex for `flowgraph.call(...)` (runtime introspection / control of a running block's state).
- `mutex` serializes the process loop with any external `call`. Inside the user's `process` the block's own state is safe; calls from outside (e.g. changing a filter cutoff) are serialized.
- On any error other than EndOfStream, it records it and breaks, then **always** does `sample_mux.setEOS()` so downstream blocks see BrokenStream and collapse the pipeline cleanly (see flowgraph "collapses on error" test).
- For sources: when the source returns EOS from its process (or a raw source calls setEOS on stop), the whole graph drains and terminates.

## 3. RawBlockRunner — Escape Hatch for Special Cases

```zig
pub const RawBlockRunner = struct {
    block: *Block,
    sample_mux: SampleMux,

    running: bool = false,

    pub fn init(_: std.mem.Allocator, block: *Block, sample_mux: SampleMux) !RawBlockRunner {
        return .{
            .block = block,
            .sample_mux = sample_mux,
        };
    }

    pub fn deinit(self: *RawBlockRunner) void {
        if (self.running) {
            self.stop();
            self.join();
        }
    }

    pub fn spawn(self: *RawBlockRunner) !void {
        try self.block.start(self.sample_mux);
        self.running = true;
    }

    pub fn call(self: *RawBlockRunner, comptime function: anytype, args: anytype) @typeInfo(@TypeOf(function)).@"fn".return_type.? {
        const block = @as(@typeInfo(@TypeOf(function)).@"fn".params[0].type.?, @alignCast(@fieldParentPtr("block", self.block)));
        return @call(.auto, function, .{block} ++ args);
    }

    pub fn stop(self: *RawBlockRunner) void {
        self.block.stop();
    }

    pub fn join(self: *RawBlockRunner) void {
        self.running = false;
    }

    pub fn getError(_: *const RawBlockRunner) ?anyerror {
        return null;  // Raw blocks report errors via their own mechanism, not the runner
    }
};
```

Raw blocks have full control. They receive the `SampleMux` (which has the vtable for wait/get/update/setEOS on the rings) and can do whatever they want inside `start()` — including their own threads, select-like polling, etc.

Example from flowgraph tests (TestRawSource):

```zig
pub fn start(self: *TestRawSource, sample_mux: SampleMux) !void {
    self.sample_mux = sample_mux;
}

pub fn stop(self: *TestRawSource) void {
    self.sample_mux.setEOS();
}

pub fn feed(self: *TestRawSource) void {
    var output_buf = self.sample_mux.vtable.getOutputBuffer(self.sample_mux.ptr, 0);
    @memset(output_buf[0..4], 0xab);
    self.sample_mux.vtable.updateOutputBuffer(self.sample_mux.ptr, 0, 4);
}
```

The test manually "feeds" the raw source from the main thread while the graph is running. This demonstrates the power: the raw block can be driven from an external event loop if desired.

## 4. Lifecycle in Flowgraph (start / stop / wait / run)

From flowgraph.zig (verbatim orchestration):

```zig
pub fn start(self: *Flowgraph) !void {
    if (self.run_state != null) return FlowgraphError.AlreadyRunning;
    try self._initialize();  // validate, rates, platform, block.initialize()
    self.run_state = try FlowgraphRunState.init(...);
    for (self.run_state.?.block_runners.values()) |*block_runner| switch (block_runner.*) {
        inline else => |*r| try r.spawn(),
    };
}

pub fn stop(self: *Flowgraph) !bool {
    ...
    for (...) |*block_runner| {
        if (r.block.inputs.len == 0) {  // only sources
            r.stop();
        }
    }
    return try self.wait();
}

pub fn wait(self: *Flowgraph) !bool {
    ...
    for (...) {
        r.join();
        success = success and r.getError() == null;
        try self.block_errors.put(...);
    }
    self.run_state.?.deinit();
    ...
    self._deinitialize();
    return success;
}
```

**Important realtime note:** `stop()` only signals *sources*. The EOS then propagates downstream naturally through the rings. This is elegant — you don't have to chase every thread; the dataflow termination does it.

For non-blocking "start then do other work then stop", the pattern in examples is:

```zig
try top.start();
radio.platform.waitForInterrupt();  // or sleep, or other work
_ = try top.stop();
```

`platform.waitForInterrupt` uses sigwait on SIGINT.

## 5. Error Propagation and "Pipeline Collapse"

When any block's process returns a non-EOS error (or a downstream ring reports BrokenStream because a sink errored), the runner records it and sets EOS on its mux. This causes upstream and downstream to see the stream error on their next wait/get and unwind.

Test "Flowgraph collapses on error" (verbatim):

```zig
var sink_block = TestErrorSink.init();  // returns Unexpected on second process
...
try std.testing.expectEqual(false, try top.run());
try std.testing.expectEqual(error.BrokenStream, top.block_errors.get(&source_block.block).?.?);
try std.testing.expectEqual(error.BrokenStream, top.block_errors.get(&inverter_block.block).?.?);
try std.testing.expectEqual(error.Unexpected, top.block_errors.get(&sink_block.block).?.?);
```

This "fail fast and poison the streams" is excellent for realtime systems: a hardware read error or math domain error doesn't leave dangling threads or half-processed audio.

## 6. The `flowgraph.call` Escape Hatch (Live Control)

Even while the threaded loop is running (and holding its internal mutex most of the time), you can safely call methods on the concrete block:

```zig
pub fn call(self: *Flowgraph, block: anytype, comptime function: anytype, args: anytype) ... {
    ...
    const block_runner = ...;
    switch (...) {
        inline else => |*r| return r.call(function, args),
    }
}
```

For threaded, the call() sets the event, takes the runner mutex (waiting for the process iteration to yield or finish), invokes the method, releases, resets event.

For composites, it bypasses and calls directly (passing the flowgraph so the composite can in turn call its children).

This enables runtime reconfiguration (e.g. changing a filter cutoff, AGC target, tuner frequency) from the main thread or a UI thread without stopping the graph. The mutex ensures the user's method sees a consistent view (no process() in the middle of the mutation).

See tests for `TestCallableBlock` and `TestCallableCompositeBlock`.

## 7. Realtime Characteristics of This Model

**Latency / Wakeup:**
- Producer writes N samples → `update` → `broadcast`.
- Consumer is parked in `cond_read_available.wait`.
- Kernel wakes the consumer thread.
- It acquires mutex, gets buffer, releases, does DSP work (potentially long), then loops back to wait if needed.
- Context switch + condvar overhead is the price of the simple "one thread per block" model.

**Throughput:**
- Once awake, a block can process *many* samples in one iteration (SampleMux.wait returns the *min* available across all its ports, which can be thousands).
- This amortizes the per-iteration cost.
- Large rings (8MB) mean a fast producer can get far ahead, giving the consumer long runs of work.

**CPU / Scheduling:**
- Threads are normal pthread / OS threads. No CPU affinity, no real-time priorities set by the framework (user can do it).
- On a multicore machine, independent branches can truly run in parallel.
- A slow block will cause its upstream rings to fill; writers will block in `waitAvailable` when space < needed. This provides natural backpressure.

**Fairness / Starvation:**
- Because of the mutex per runner, a long-running process() can delay a `call()` from outside. The tiny sleep when call_event is seen is a mitigation.
- No priority inheritance or anything; plain mutex.

**Determinism:**
- Not hard realtime (no guarantees). But the design (large buffers, blocking only on data availability, explicit EOS) makes it suitable for soft realtime SDR applications where occasional 10-100ms glitches are tolerable (or can be concealed).

## 8. Why Not a Single Scheduler Thread (like classic GNU Radio)?

Classic GNU Radio uses a scheduler that decides which block to run next in a single (or few) threads, with more sophisticated buffer management and possible "in-tree" execution.

ZigRadio's choice of N threads + rings:
- **Much simpler core.** No central scheduler logic, no need to model "how much work can this block do", no complex topoblock execution planning beyond the initial evaluation order for init/rates.
- Natural parallelism on multicore.
- Each block author writes a simple synchronous `process` that looks like normal DSP code; the framework handles the "when to call me".
- Raw mode gives an escape for when you *do* need custom scheduling.

Downsides (acknowledged by the architecture): more threads, more context switches, mutex per block, higher memory (rings).

For the target use case (rapid prototyping of SDR receivers on a modern laptop/phone SoC), this is an excellent tradeoff.

## 9. Raw Mode Use Cases (Inferred + from Code)

- Blocks that produce/consume in fixed hardware-sized chunks and want to drive the timing themselves (e.g. the TestRawSource in tests).
- Integration with external event loops (you could have the raw block's start() do a blocking read from a socket or device in its own way).
- Blocks that need to spawn *their own* worker threads or use io_uring / kqueue directly on the rings.
- Very low-latency paths where you want to avoid the SampleMux wait/get/update dance per chunk.

Most blocks (all the signal processing ones, most sources/sinks) use the standard model because it is vastly more convenient and the overhead is negligible at audio-to-low-MHz rates.

## Summary

The execution model is deliberately **simple and uniform** for the 95% case (thread per block, blocking on data via condvars inside large aliased rings, clean EOS termination), with a **powerful escape hatch** (raw mode + direct vtable access + live `call`).

Combined with the ring buffer's contiguous views and the SampleMux's multi-port min-available logic, this delivers the "it just flows in real time" experience while staying true to Zig's explicit, low-magic philosophy.

See doc 10 for quantitative thoughts on latency and buffering.
