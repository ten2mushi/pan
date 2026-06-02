# 07: Comptime Type System, Runtime Signatures, and RefCounted

Deep dive on `src/core/types.zig`.

## 1. ComptimeTypeSignature — Introspecting the User's process()

```zig
pub const ComptimeTypeSignature = struct {
    inputs: []const type,
    outputs: []const type,

    pub fn init(comptime process_fn: anytype) ComptimeTypeSignature {
        const process_args = @typeInfo(@TypeOf(process_fn)).@"fn".params[1..];  // skip self
        var _comptime_inputs: [process_args.len]type = undefined;
        ...
        inline for (process_args) |arg| {
            const arg_is_input = @typeInfo(arg.type orelse unreachable).pointer.is_const;
            if (arg_is_input) {
                _comptime_inputs[num_inputs] = @typeInfo(...).pointer.child;
                num_inputs += 1;
            } else {
                _comptime_outputs[...] = ...;
            }
        }
        ...
    }
};
```

The rule is beautifully simple: `[]const T` → input of type T; `[]T` → output of type T.

This is used both at Block construction (to decide how many ports, what the runtime names are, and to generate the wrapper that calls the user's fn with the right slices) and inside SampleMux.get to produce the correct tuple of slice types for the user's process.

## 2. RuntimeTypeSignature — For the Heterogeneous Graph

Because a Flowgraph contains many different block types (some f32, some Complex(f32), some u1 bits, some user types), the graph data structures need a uniform way to talk about "what type is on this port?"

```zig
pub const RuntimeTypeSignature = struct {
    inputs: []const []const u8,
    outputs: []const []const u8,

    pub fn map(comptime data_type: type) []const u8 {
        return switch (data_type) {
            std.math.Complex(f32) => "ComplexFloat32",
            f32 => "Float32",
            u8 => "Unsigned8",
            ...
            else => {
                if (@hasDecl(data_type, "typeName")) return data_type.typeName();
                @compileError("User-defined type " ++ @typeName(data_type) ++ " is missing a typeName() getter.");
            },
        };
    }
};
```

At Block.init time we do `comptime RuntimeTypeSignature.init(type_signature)` which monomorphizes the string table for that block's ports.

Later, in flowgraph._validate:

```zig
if (!std.mem.eql(u8, k.*.type_signature.inputs[i], upstream... .outputs[...])) {
    return FlowgraphError.DataTypeMismatch;
}
```

And in the debug dump, the strings are printed: `[Float32] <- ...`

User types just need:

```zig
pub fn typeName() []const u8 { return "MyPacket"; }
```

This is the minimal "runtime type info" ZigRadio needs — no full RTTI, no vtables on the samples themselves.

## 3. RefCounted + Type Tags

See the memory doc for the full struct and the update logic that bumps RC on fanout.

The `hasTypeTag` + `typeTag()` mechanism lets the generic SampleMux code (which is comptime over the type_signature) conditionally emit the RC code only for ports whose element type is a RefCounted wrapper.

This is a nice example of "comptime specialization" for a rarely-used feature (most pipelines use plain Copy types) without paying any cost in the common case.

## 4. Comptime Tuple-Type Generation (core/util.zig)

The buffer tuples that a block's `process` receives are not hand-written types — they are generated at comptime from the block's data-type lists by three helpers in `src/core/util.zig`. These are the bridge between the `ComptimeTypeSignature` (a `[]const type` of input/output element types) and the concrete slice tuples passed through `SampleMux`/`SampleBuffers`.

```zig
pub fn dataTypeSizes(comptime data_types: []const type) []const usize {
    var _data_type_sizes: [data_types.len]usize = undefined;
    inline for (data_types, 0..) |data_type, i| {
        _data_type_sizes[i] = @sizeOf(data_type);
    }
    const data_type_sizes = _data_type_sizes;
    return data_type_sizes[0..];
}

pub fn makeTupleConstSliceTypes(comptime data_types: []const type) type {
    var slice_data_types: [data_types.len]type = undefined;
    inline for (data_types, 0..) |data_type, i| {
        slice_data_types[i] = []const data_type;
    }
    return std.meta.Tuple(&slice_data_types);
}

pub fn makeTupleSliceTypes(comptime data_types: []const type) type {
    var slice_data_types: [data_types.len]type = undefined;
    inline for (data_types, 0..) |data_type, i| {
        slice_data_types[i] = []data_type;
    }
    return std.meta.Tuple(&slice_data_types);
}
```

- `makeTupleConstSliceTypes([u8, f32, bool])` → `std.meta.Tuple(&.{ []const u8, []const f32, []const bool })` — the **read-only** input tuple type.
- `makeTupleSliceTypes([...])` → the same but with mutable `[]T` — the **writable** output tuple type.
- `dataTypeSizes` maps element types to their `@sizeOf` (e.g. `[u8, u128, u64, bool]` → `[1, 16, 8, 1]`), used to convert sample counts to byte offsets when slicing the ring's byte buffers.

These are exactly the type constructors used by `SampleBuffers` and by the `BlockTester`/`BlockFixture` test harness (testing.zig), so the *const-vs-mutable* distinction the `ComptimeTypeSignature` extracts in §1 is preserved end-to-end: inputs stay `[]const T`, outputs stay `[]T`, with no runtime tagging. `indexOfString` (a small linear `[]const u8` lookup) is also defined here and is used for port-name resolution.

## 5. Tests in the File

The file thoroughly tests:
- All the mapping cases (f32, Complex, integers, u1 Bit, user types with typeName).
- Round-tripping Comptime → Runtime.
- RefCounted init/ref/unref/deinit behavior (the last unref calls T.deinit).

Together with the tests inside block.zig and sample_mux.zig that exercise the full get/update path with RefCounted, this gives strong coverage of the type layer.
