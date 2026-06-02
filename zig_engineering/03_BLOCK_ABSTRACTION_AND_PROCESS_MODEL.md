# 03: Block Abstraction and the Process Model (Verbatim from block.zig)

This document focuses exclusively on `src/core/block.zig` (532 lines) — the thin but critical adapter that turns a user struct with a `process` method into something the Flowgraph and Runners can schedule uniformly.

## 1. ProcessResult — The Only "Return Value" from DSP Work

```zig
pub const ProcessResult = struct {
    samples_consumed: [8]usize = [_]usize{0} ** 8,
    samples_produced: [8]usize = [_]usize{0} ** 8,
    eos: bool = false,

    pub fn init(consumed: []const usize, produced: []const usize) ProcessResult {
        var self = ProcessResult{};
        @memcpy(self.samples_consumed[0..consumed.len], consumed);
        @memcpy(self.samples_produced[0..produced.len], produced);
        return self;
    }

    pub const EOS: ProcessResult = .{ .eos = true };
};
```

Both arrays are fixed at length 8 (the source has no comment explaining the number; it is simply a fixed upper bound on ports per side). This is a pragmatic, stack-only, cache-friendly design. The mux later uses exactly these counts (scaled by sizeof(T)) to advance the corresponding ring readers/writers.

## 2. The Wrapper Generators — Compile-Time Glue

These are the heart of the "write normal Zig, get framework integration" magic.

### wrapProcessFunction (the hot path)

```zig
fn wrapProcessFunction(comptime BlockType: type, comptime type_signature: ComptimeTypeSignature, comptime processFn: anytype) fn (self: *Block, sample_mux: SampleMux) anyerror!ProcessResult {
    const gen = struct {
        fn process(block: *Block, sample_mux: SampleMux) anyerror!ProcessResult {
            const self: *BlockType = @alignCast(@fieldParentPtr("block", block));
            const buffers = try sample_mux.get(type_signature);
            const process_result = try @call(.auto, processFn, .{self} ++ buffers.inputs ++ buffers.outputs);
            sample_mux.update(type_signature, buffers, process_result);
            return process_result;
        }
    };
    return gen.process;
}
```

`@call(.auto, ...)` + comptime tuple concatenation means the generated function has the exact same calling convention and inlining opportunities as if the user had written the SampleMux.get/update boilerplate themselves.

### Similar wrappers for lifecycle and raw

- `wrapInitializeFunction`, `wrapDeinitializeFunction`, `wrapSetRateFunction`
- `wrapStartFunction`, `wrapStopFunction` (for raw)

All follow the same `@fieldParentPtr` + `@call` pattern.

## 3. Block.init — The Comptime Entry Point

Already quoted extensively in other docs. It:
1. Compile-errors if no `process`.
2. Requires `setRate` for sources (0 inputs).
3. Auto-generates port names `in1,in2...` / `out1,out2...`.
4. Builds both Comptime and Runtime type signatures.
5. Installs the wrapped function pointers (or null for raw).

`initRaw` is symmetric but takes explicit input/output type lists (via `ComptimeTypeSignature.fromTypes` rather than introspecting `process`) and requires a `start` instead of `process`. It still compile-errors if a source (0 inputs) has no `setRate`, sets `.raw = true`, leaves `process_fn = null`, and wires `stop_fn` only if a `stop` method exists.

## 4. The Public Block API Surface

```zig
pub fn setRate(self: *Block, rate: f64) !void { ... }
pub fn initialize(self: *Block, allocator: std.mem.Allocator) !void { ... }
pub fn deinitialize(self: *Block, allocator: std.mem.Allocator) void { ... }
pub fn process(self: *Block, sample_mux: SampleMux) !ProcessResult { return try self.process_fn.?(self, sample_mux); }
pub fn getRate(self: *const Block, comptime T: type) T { ... }

pub fn start(self: *Block, sample_mux: SampleMux) !void { ... }
pub fn stop(self: *Block) void { ... }
```

These are what the runners and flowgraph call. User code almost never touches a `*Block` directly after construction (except for `&myblock.block` when connecting).

## 5. Name Extraction for Debug / Pretty Printing

```zig
pub fn extractBlockName(comptime BlockType: type) []const u8 {
    comptime var it = std.mem.splitScalar(u8, @typeName(BlockType), '(');
    const first = comptime it.first();
    const suffix = comptime it.rest();
    comptime var it_back = std.mem.splitBackwardsScalar(u8, first, '.');
    const prefix = comptime it_back.first();
    return prefix ++ (if (suffix.len > 0) "(" else "") ++ suffix;
}
```

This turns `blocks.signal.LowpassFilterBlock(f32,128)` or `TunerBlock` into clean names for the debug dump.

## 6. Test Blocks in the Same File — Self-Hosting Validation

The file defines several Test* blocks (TestBlock with 2in1out, TestAddBlock, TestSource that produces 2 samples then EOS, TestRawBlock) and runs them through both TestSampleMux and full ThreadSafeRingBufferSampleMux scenarios, including EOS cases on read and write sides.

This is "eating your own dogfood" at the lowest layer.

## Summary

`Block` is a **type-erased, function-pointer-based adapter** generated entirely at comptime for each concrete user block type. It erases the user's specific `process` signature into the uniform `(self: *Block, mux: SampleMux) !ProcessResult` that the rest of the system understands, while preserving zero-overhead dispatch and full type safety at the user's process level.

The fixed-size [8] in ProcessResult and the assumption of "reasonable" port counts are pragmatic systems-language choices that keep everything stack-allocated and simple.
