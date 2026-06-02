# 02: Flowgraph Orchestration and Graph Management (Deep Source Dive)

The `Flowgraph` is the central nervous system. This document contains extensive verbatim excerpts from `src/core/flowgraph.zig` (the ~1790 line file) plus surrounding analysis.

## 1. Data Structures (Ports, Connections, Flattening)

```zig
const BlockVariant = union(enum) {
    block: *Block,
    composite: *CompositeBlock,
    pub fn wrap(element: anytype) BlockVariant { ... }
};

const InputPort = struct { block: BlockVariant, index: usize };
const OutputPort = struct { block: BlockVariant, index: usize };

const BlockInputPort = struct { block: *Block, index: usize };
const BlockOutputPort = struct { block: *Block, index: usize };
```

User-facing `connections: std.AutoHashMap(InputPort, OutputPort)` keep the original (possibly composite) wiring.

`flattened_connections: std.AutoHashMap(BlockInputPort, BlockOutputPort)` is what actually drives rings and evaluation.

`input_aliases` and `output_aliases` maps handle the composite indirection (a composite input can alias to *multiple* internal inputs for fanout inside the composite; outputs are 1:1).

## 2. Topological Sort for Evaluation Order (buildEvaluationOrder)

Verbatim (critical for init order and rate propagation):

```zig
fn buildEvaluationOrder(allocator: std.mem.Allocator, flattened_connections: *const std.AutoHashMap(BlockInputPort, BlockOutputPort), block_set: *const std.AutoHashMap(*Block, void)) !std.AutoArrayHashMap(*Block, void) {
    var block_set_copy = try block_set.cloneWithAllocator(allocator);
    defer block_set_copy.deinit();
    var evaluation_order = std.AutoArrayHashMap(*Block, void).init(allocator);
    errdefer evaluation_order.deinit();

    const num_blocks = block_set_copy.count();
    while (evaluation_order.count() < num_blocks) {
        var block_it = block_set_copy.keyIterator();
        const next_block: ?*Block = outer: while (block_it.next()) |k| {
            for (0..k.*.inputs.len) |i| {
                const upstream_block = flattened_connections.get(BlockInputPort{ .block = k.*, .index = i }).?.block;
                if (!evaluation_order.contains(upstream_block)) {
                    continue :outer;
                }
            }
            break k.*;
        } else null;

        if (next_block == null) return FlowgraphError.CyclicDependency;
        _ = block_set_copy.remove(next_block.?);
        try evaluation_order.put(next_block.?, {});
    }
    return evaluation_order;
}
```

This is a simple "ready when all predecessors are ready" Kahn's algorithm variant. It also detects cycles (the only way the inner loop can exhaust without finding a ready block).

The resulting order is used for:
- Rate propagation.
- Debug dump.
- Block initialization (so upstream rates are set before downstream blocks ask for fs in their initialize).

## 3. Full _connect and Alias Logic (the Flattening Engine)

The `_connect` method (called by connect / connectPort) does the heavy lifting of populating both the user map and the flattened map, and triggering composite.connect on first sight.

Large verbatim excerpt (key parts):

```zig
pub fn _connect(self: *Flowgraph, src_port: OutputPort, dst_port: InputPort) !void {
    if (self.connections.contains(dst_port)) return FlowgraphError.PortAlreadyConnected;
    try self.connections.put(dst_port, src_port);

    // Ensure composites are "activated"
    switch (src_port.block) { BlockVariant.block => ..., BlockVariant.composite => if (!self.composite_set.contains...) { try self.composite_set.put...; try src... .connect(self); } }
    ... same for dst ...

    // Crawl output aliases until we hit a real Block
    var underlying_src_port = src_port;
    while (underlying_src_port.block != BlockVariant.block) {
        underlying_src_port = self.output_aliases.get(underlying_src_port) orelse return FlowgraphError.UnderlyingPortNotFound;
    }

    // Crawl input aliases (composites can fan-in to multiple)
    var underlying_dst_ports = std.array_list.Managed(InputPort).init(self.allocator);
    defer underlying_dst_ports.deinit();
    try underlying_dst_ports.append(dst_port);

    while (underlying_dst_ports.items.len > 0) {
        const next_dst_port = underlying_dst_ports.pop() orelse break;
        if (next_dst_port.block == BlockVariant.block) {
            try self.flattened_connections.put( BlockInputPort{.block=next...}, BlockOutputPort{.block=underlying_src...} );
        } else {
            const aliased = self.input_aliases.get(next_dst_port) orelse return ...;
            try underlying_dst_ports.appendSlice(aliased.items);
        }
    }
}
```

The input alias side uses a list because one composite "in1" can be wired to several internal blocks' inputs (fanout of the same stream inside the composite).

Output aliases are single (a composite output names exactly one internal output).

## 4. Validation, Rate Propagation, Dump

Already covered in other docs; the `_dump` produces the nice ASCII tree you see when debug=true.

## 5. Run State Construction (the Moment Everything Becomes Real)

In FlowgraphRunState.init (verbatim skeleton):

```zig
pub fn init(...) !FlowgraphRunState {
    // create ring_buffers map: for every block output port, one 8MB ThreadSafeRingBuffer
    ...
    // for every block:
    //   collect its input rings (from flattened_connections)
    //   collect its output rings
    //   create ThreadSafeRingBufferSampleMux for it
    //   create Raw or Threaded runner for it
    ...
}
```

This is where the "virtual wires" become actual ring buffers (each `RING_BUFFER_SIZE = 8 * 1048576` = 8 MiB capacity, double-mapped for contiguous wraparound). The block runners are *constructed* here in `FlowgraphRunState.init`, but threads are only spawned afterwards in `start()` (which loops over `block_runners.values()` and calls `r.spawn()`).

## 6. The Call Mechanism for Live Introspection

`flowgraph.call(&some_block.block, ConcreteBlock.someMethod, .{args})` lets you poke a running block's methods from outside its thread (with proper mutex handoff for threaded runners).

This is used in tests for callable blocks and is intended for user control planes (changing parameters on the fly).

## 7. Full Test Coverage of Graph Edge Cases

The file contains extensive tests for:
- Linear and multi-fanout / multi-input graphs (`buildEvaluationOrder`, `Flowgraph connect`).
- Composite and nested composite aliasing (with `flattened_connections` assertions).
- Missing alias errors (`UnderlyingPortNotFound`), both input-side and output-side.
- Type mismatch (`DataTypeMismatch`), rate mismatch (`RateMismatch`), unconnected input (`InputPortUnconnected`), and port count (`InvalidPortCount`) / `PortNotFound` / `PortAlreadyConnected` errors.
- Run to completion, start/stop, error collapse, raw+threaded mix, live call on running graph (block and composite).

Note: the `CyclicDependency` error path in `buildEvaluationOrder` (flowgraph.zig:96) exists but is **not** exercised by any test in this file — none of the tests construct a cyclic graph.

This level of testing on the orchestrator is what gives confidence that the higher-level SDR examples "just work".

The Flowgraph is intentionally "dumb but correct": it doesn't do clever scheduling or buffer sizing per block; it sets up a uniform, predictable, debuggable concurrent dataflow and gets out of the way.
