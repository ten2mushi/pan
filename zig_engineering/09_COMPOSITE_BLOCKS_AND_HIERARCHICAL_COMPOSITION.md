# 09: Composite Blocks and Hierarchical Composition

Composites are the mechanism for **abstraction and reuse** inside the dataflow graph. A composite looks like a single block from the outside (has named ports, participates in connect/alias) but expands to an internal sub-graph when the flowgraph is built.

## 1. CompositeBlock — The Facade (composite.zig verbatim)

```zig
pub const CompositeBlock = struct {
    name: []const u8,
    inputs: []const []const u8,
    outputs: []const []const u8,
    connect_fn: *const fn (self: *CompositeBlock, flowgraph: *Flowgraph) anyerror!void,

    pub fn init(comptime CompositeType: type, inputs: []const []const u8, outputs: []const []const u8) CompositeBlock {
        // Composite needs to have a connect method
        if (!@hasDecl(CompositeType, "connect")) {
            @compileError("Composite " ++ @typeName(CompositeType) ++ " is missing the connect() method.");
        }
        return .{
            .name = comptime extractBlockName(CompositeType),
            .inputs = inputs,
            .outputs = outputs,
            .connect_fn = comptime wrapConnectFunction(CompositeType, CompositeType.connect),
        };
    }

    pub fn connect(self: *CompositeBlock, flowgraph: *Flowgraph) !void {
        try self.connect_fn(self, flowgraph);
    }
};
```

The wrapper is the usual `@fieldParentPtr` + `@call`.

The user struct looks like the TunerBlock example (already verbatim in doc 12): it holds the `block: CompositeBlock` + the concrete sub-blocks as fields, implements `connect(self, flowgraph)` which does internal `flowgraph.connect` calls + `flowgraph.alias` calls.

## 2. Alias Resolution in _connect (the Crawl)

Already shown in doc 02. The key insight is that alias crawling happens at connect time and populates the `flattened_connections` map (`BlockInputPort → BlockOutputPort`) directly from real leaf `Block` ports to real leaf `Block` ports.

`alias()` records aliases into two different maps with different shapes (this asymmetry matters):
- **Output aliases** are stored in `output_aliases`, an `AutoHashMap(OutputPort, OutputPort)` written with `putNoClobber` — exactly one underlying source port per composite output.
- **Input aliases** are stored in `input_aliases`, an `AutoHashMap(InputPort, ArrayList(InputPort))` — a composite input may fan out to *several* underlying input ports (e.g. `TestNestedCompositeBlock` aliases `in1` to both `b1.in1` and `b3.in1`).

`_connect` then resolves both ends:
- The **source** crawl is a simple `while (underlying_src_port.block != .block)` loop that follows `output_aliases.get(...)` until it lands on a real `Block`, returning `UnderlyingPortNotFound` if a hop is missing.
- The **destination** crawl is a worklist: it seeds an `ArrayList(InputPort)` with `dst_port`, then pops entries; a real-`Block` entry produces one `flattened_connections.put(...)` from the resolved source, while a composite entry is expanded via `input_aliases.get(...)` whose items are appended back onto the list. This loop, not recursion, is what handles fan-out and nesting.

After connect, the composite objects are only kept around for:
- The user's convenience (they can still hold references to `&tuner.block` and call methods on the composite via `flowgraph.call`).
- Debug printing (the high-level view before flattening).

## 3. Nested Composites

The test "Flowgraph connect nested composite" proves that the crawl resolves arbitrarily deep nesting (it is iterative via the worklist, not literal recursion):

A top-level composite aliases one of its inputs to *another composite's* input. The `input_aliases` map ends up with a chain (`b2.in1 → {b2.b1.in1, b2.b3.in1}` and `b2.b3.in1 → {b2.b3.b1.in1}`), and the final flattened entries point at the deepest leaf blocks (`b2.b1` and `b2.b3.b1` both fed from the source).

The code handles this with the while loop that keeps popping from the `underlying_dst_ports` list and expanding aliases until only real Blocks remain.

A composite's internal `connect()` is run lazily and exactly once: the first time a composite appears as the source or destination of a `_connect` (or as the aliased block of an `alias()` call), it is inserted into `composite_set` and its `connect(self)` is invoked. The `composite_set` guard prevents re-running `connect()` if the same composite is wired multiple times. This is why a nested composite (`b3` inside `TestNestedCompositeBlock`) gets its own entry in `composite_set` and its internal connections appear in `flattened_connections` — the outer composite's `alias(... &self.b3.block ...)` call expands `b3` before the crawl reaches it.

## 4. Why Composites (Engineering Rationale)

- **Encapsulation**: A "Tuner" or "WBFM Stereo Demodulator" is a reusable subsystem with a clean interface. Users don't have to wire 5-10 blocks every time.
- **Abstraction in the graph dump**: With debug=true you see the high-level structure first.
- **Live control**: You can expose methods on the composite (see TestCallableCompositeBlock) that internally do flowgraph.call on children. The composite acts as a "namespace" for control.
- **No runtime cost**: Because flattening happens before any rings or threads are created, a composite adds zero overhead in the steady-state pipeline. The rings are between the same leaf blocks whether the user wired them directly or through 3 levels of composites.

## 5. Limitations (Observed)

- Composites are "static" — the internal wiring is fixed at the struct's connect() method. You can't dynamically add/remove internal blocks at runtime (you can achieve similar by having conditional blocks that are always present but pass-through or zero when disabled).
- Alias errors (missing in/out alias) are only discovered when you actually connect the composite into a graph (UnderlyingPortNotFound), not at composite construction time. This is a minor ergonomics point.
- A composite's own initialize/deinitialize hooks are not directly supported in the current CompositeBlock (only the leaf blocks get initialize called). If a composite needs its own state/resources, it must manage them manually or push them down into a dedicated leaf "controller" block.

Despite these, the mechanism is powerful enough that all the high-level demodulators (AM, NBFM, WBFM mono/stereo) are implemented as composites.

This completes the picture of how you go from a flat list of blocks in user code to a clean, hierarchical, reusable signal flow graph while keeping the runtime execution model simple (one thread + ring per leaf block).
