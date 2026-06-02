# 15: Verbatim Core Reference Compendium (Selected Core Excerpts)

This file is a "one stop shop" for a few of the most architecturally significant code
fragments, copied **verbatim** from the source at the time of analysis so future readers of
this engineering doc set do not have to cross-reference the original checkout for the exact
text. Each fragment is small and load-bearing; the larger surrounding context lives in the
topical documents (03 for block.zig, 04 for ring_buffer.zig, 05 for sample_mux.zig).

Source paths are relative to `/Users/komorebi/Documents/projects/tools/rf/zigradio/`.
ZigRadio version 0.10.0; targets Zig 0.15.

## A. From `src/core/block.zig` — `ProcessResult`

`ProcessResult` is the only "return value" of DSP work: how many samples each input port
consumed and each output port produced (fixed arrays of 8, matching `MAX_NUM_READERS`), plus
an end-of-stream flag. `ProcessResult.init` copies the caller's slices into the fixed arrays.

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

The two constructors on `Block` itself are `pub fn init(comptime BlockType: type) Block`
(the normal, type-inferring path that reads the user's `process` signature at comptime) and
`pub fn initRaw(comptime BlockType: type, input_data_types: []const type, output_data_types: []const type) Block`
(the escape hatch where the author declares port types explicitly). See doc 03 for their full
bodies and the `wrap*Function` generators.

## B. From `src/core/ring_buffer.zig` — The `RingBuffer` Core Struct

The ring is generic over a `MemoryImpl` (the Linux `MappedMemoryImpl` with virtual aliasing,
or the portable `CopiedMemoryImpl`). `ThreadSafeRingBuffer` wraps `RingBuffer(DefaultMemoryImpl)`.
A single writer advances `write_index`; up to `MAX_NUM_READERS = 8` readers each have their own
`read_index`. This is the single-writer / multi-reader (per output port) invariant.

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
```

The thread-safe wrapper adds a mutex and two condition variables (verbatim from the same file):

```zig
        // Lock and Condition Variables
        mutex: std.Thread.Mutex = .{},
        cond_read_available: std.Thread.Condition = .{},
        cond_write_available: std.Thread.Condition = .{},
```

This is the basis for the "lock-free on the data path, coordinated by mutex/condvar" claim in
doc 04 and doc 14: the mutex guards index updates and the condvars signal availability, but the
actual sample math runs against contiguous slices with no lock held. The default runtime ring is
`RING_BUFFER_SIZE = 8 * 1048576` (8 MiB) per output port, set in `flowgraph.zig`.

## C. From `src/core/sample_mux.zig` — The `SampleMux` VTable

`SampleMux` is the type-safe, multi-port boundary between the raw ring mechanics and the typed
`process(self, []const T, []U) !ProcessResult` that block authors write. It is a fat-pointer
vtable so the same block code can run against `TestSampleMux` (unit tests) or
`ThreadSafeRingBufferSampleMux` (real execution).

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

Note the asymmetric error sets: input waits/queries can return `EndOfStream` (upstream finished),
output waits/queries can return `BrokenStream` (a downstream reader is gone). `SampleMux.wait`
computes the minimum samples available across all ports (dividing byte counts by `@sizeOf` of
each port's element type) before blocking on the limiting port; see doc 05 for that loop verbatim.

---

*This is a snapshot from the investigation. For the absolute latest, go back to the upstream repo.*
