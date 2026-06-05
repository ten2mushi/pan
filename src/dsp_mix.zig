//! Mix / routing blocks — the structural-numeric `Map` morphisms that combine,
//! fan out, and re-weight audio edges.
//!
//! Every block here is rate-1:1 (`out.len == in.len`) and therefore a `Map`,
//! monomorphized over a Numeric trait so the precision (lane, accumulator width,
//! saturation) is bound at comptime, exactly as `Gain`/`Biquad` are. A precision
//! change re-selects a monomorph and requires a recommit — there is no runtime
//! precision switch.
//!
//!   - `SummingMixer(num, n_in)` adds `n_in` homogeneous inputs into one output.
//!     Additive mixing is the default: the output is the plain sum. The integer
//!     path accumulates in the wide `num.Acc` (twice the lane width) so a sum of
//!     lane values does not overflow before the final saturating store.
//!   - `MatrixRouter(num, n_in, n_out)` is an `n_in → n_out` routing/mix matrix:
//!     each output is the weighted sum of all inputs, weights in an
//!     `[n_out][n_in]` coefficient field. It accumulates in `num.Acc`.
//!   - `DryWet(num)` blends two inputs (`dry`, `wet`) by a `mix` parameter in
//!     `[0,1]`: `out = (1−mix)·dry + mix·wet`. A LINEAR (not equal-power)
//!     crossfade — at `mix = 0.5` the output is the arithmetic average.
//!   - `Splitter(num, n_out)` copies one input to `n_out` identical outputs.
//!
//! Multi-input ports are declared the way `port.zig`/`combinators.zig` derive
//! them: each `[]const Sample(T)` parameter of `process` (after `self`) is one
//! input port, each `[]Sample(T)` parameter is one output port — the same
//! constness-classifies-direction rule the port scanner (`mapPortCounts`,
//! `MapInPortAt`) reads. A parameter list cannot be synthesized from a comptime
//! count, so — exactly as `combinators.Concat` does for its arities — each arity
//! gets an explicit `process` whose port slices appear in index order, selected
//! by a `switch` over the count.

const std = @import("std");
const types = @import("types.zig");
const numeric = @import("numeric.zig");

/// Is this lane a floating-point type? Selects the float vs fixed-point kernel.
fn isFloat(comptime T: type) bool {
    return @typeInfo(T) == .float;
}

/// Clamp a wide accumulator value to the lane's representable range and narrow
/// it to the lane. For a float lane this is a plain cast (floats have their own
/// overflow semantics and do not saturate); for an integer lane the value is
/// clamped to `[minInt(T), maxInt(T)]` before narrowing, so a sum that exceeds
/// the lane bound pins at the bound rather than wrapping — the saturating store
/// the Numeric trait's `saturate` flag mandates for integer lanes.
fn storeAcc(comptime num: numeric.Numeric, acc: num.Acc) num.Lane {
    const T = num.Lane;
    if (comptime isFloat(T)) return @floatCast(acc);
    const lo: num.Acc = std.math.minInt(T);
    const hi: num.Acc = std.math.maxInt(T);
    const clamped = std.math.clamp(acc, lo, hi);
    return @intCast(clamped);
}

// ===========================================================================
// SummingMixer — additive fan-in of n_in homogeneous inputs
// ===========================================================================

/// `SummingMixer(num, n_in)` — sum `n_in` homogeneous `Sample(T)` inputs into one
/// `Sample(T)` output, sample-aligned: `out[i] = Σ_k in_k[i]`. Additive mixing is
/// the default (unity per input, no per-input gain). The integer path sums into
/// the wide `num.Acc` and stores once with saturation, so the intermediate sum
/// keeps full headroom and only the final store clamps to the lane bound.
///
/// `n_in` is bounded by the 8-port-per-direction ceiling the port machinery
/// enforces; this block declares one explicit `process` per arity (a parameter
/// list cannot be built from a comptime count) and selects it by `n_in`.
pub fn SummingMixer(comptime num: numeric.Numeric, comptime n_in: usize) type {
    if (n_in == 0) @compileError("pan: SummingMixer needs n_in >= 1");
    if (n_in > 8)
        @compileError(std.fmt.comptimePrint(
            "pan: SummingMixer has {d} inputs, exceeding the 8-port fan-in ceiling",
            .{n_in},
        ));
    const T = num.Lane;
    const S = types.Sample(T);
    return switch (n_in) {
        1 => struct {
            const Self = @This();
            pub fn process(self: *Self, in0: []const S, out: []S) void {
                _ = self;
                for (out, in0) |*o, a| o.ch[0] = a.ch[0];
            }
        },
        2 => struct {
            const Self = @This();
            pub fn process(self: *Self, in0: []const S, in1: []const S, out: []S) void {
                _ = self;
                for (out, in0, in1) |*o, a, b| {
                    const acc: num.Acc = @as(num.Acc, a.ch[0]) + b.ch[0];
                    o.ch[0] = storeAcc(num, acc);
                }
            }
        },
        3 => struct {
            const Self = @This();
            pub fn process(self: *Self, in0: []const S, in1: []const S, in2: []const S, out: []S) void {
                _ = self;
                for (out, in0, in1, in2) |*o, a, b, c| {
                    const acc: num.Acc = @as(num.Acc, a.ch[0]) + b.ch[0] + c.ch[0];
                    o.ch[0] = storeAcc(num, acc);
                }
            }
        },
        4 => struct {
            const Self = @This();
            pub fn process(self: *Self, in0: []const S, in1: []const S, in2: []const S, in3: []const S, out: []S) void {
                _ = self;
                for (out, in0, in1, in2, in3) |*o, a, b, c, d| {
                    const acc: num.Acc = @as(num.Acc, a.ch[0]) + b.ch[0] + c.ch[0] + d.ch[0];
                    o.ch[0] = storeAcc(num, acc);
                }
            }
        },
        5 => struct {
            const Self = @This();
            pub fn process(self: *Self, in0: []const S, in1: []const S, in2: []const S, in3: []const S, in4: []const S, out: []S) void {
                _ = self;
                for (out, 0..) |*o, r| {
                    const acc: num.Acc = @as(num.Acc, in0[r].ch[0]) + in1[r].ch[0] + in2[r].ch[0] + in3[r].ch[0] + in4[r].ch[0];
                    o.ch[0] = storeAcc(num, acc);
                }
            }
        },
        6 => struct {
            const Self = @This();
            pub fn process(self: *Self, in0: []const S, in1: []const S, in2: []const S, in3: []const S, in4: []const S, in5: []const S, out: []S) void {
                _ = self;
                for (out, 0..) |*o, r| {
                    const acc: num.Acc = @as(num.Acc, in0[r].ch[0]) + in1[r].ch[0] + in2[r].ch[0] + in3[r].ch[0] + in4[r].ch[0] + in5[r].ch[0];
                    o.ch[0] = storeAcc(num, acc);
                }
            }
        },
        7 => struct {
            const Self = @This();
            pub fn process(self: *Self, in0: []const S, in1: []const S, in2: []const S, in3: []const S, in4: []const S, in5: []const S, in6: []const S, out: []S) void {
                _ = self;
                for (out, 0..) |*o, r| {
                    const acc: num.Acc = @as(num.Acc, in0[r].ch[0]) + in1[r].ch[0] + in2[r].ch[0] + in3[r].ch[0] + in4[r].ch[0] + in5[r].ch[0] + in6[r].ch[0];
                    o.ch[0] = storeAcc(num, acc);
                }
            }
        },
        8 => struct {
            const Self = @This();
            pub fn process(self: *Self, in0: []const S, in1: []const S, in2: []const S, in3: []const S, in4: []const S, in5: []const S, in6: []const S, in7: []const S, out: []S) void {
                _ = self;
                for (out, 0..) |*o, r| {
                    const acc: num.Acc = @as(num.Acc, in0[r].ch[0]) + in1[r].ch[0] + in2[r].ch[0] + in3[r].ch[0] + in4[r].ch[0] + in5[r].ch[0] + in6[r].ch[0] + in7[r].ch[0];
                    o.ch[0] = storeAcc(num, acc);
                }
            }
        },
        else => unreachable,
    };
}

// ===========================================================================
// Splitter — fan-out one input to n_out identical outputs
// ===========================================================================

/// `Splitter(num, n_out)` — copy one `Sample(T)` input to `n_out` identical
/// `Sample(T)` outputs. The explicit multi-output form of fan-out (pure graph
/// fan-out is also handled by the engine's edge coloring; this block makes the
/// duplication a first-class node).
///
/// The port machinery declares one output port per `[]Sample(T)` parameter, so a
/// `process(self, in, o0, o1, …)` declares `n_out` outputs — the count scanner
/// (`mapOutputCount`) reads them all. ONE LIMITATION: the convenience port-minting
/// helper `MapOutPort` returns only the FIRST output port's type (it scans for the
/// first mutable slice), so there is no `MapOutPortAt` analogue to the input-side
/// `MapInPortAt`. Wiring the i-th output therefore relies on the engine's indexed
/// output handling, not on a typed `node.out(i)` helper; the block itself is
/// correct (it writes all `n_out` outputs) and the count is reported correctly.
pub fn Splitter(comptime num: numeric.Numeric, comptime n_out: usize) type {
    if (n_out == 0) @compileError("pan: Splitter needs n_out >= 1");
    if (n_out > 8)
        @compileError(std.fmt.comptimePrint(
            "pan: Splitter has {d} outputs, exceeding the 8-port fan-out ceiling",
            .{n_out},
        ));
    const T = num.Lane;
    const S = types.Sample(T);
    return switch (n_out) {
        1 => struct {
            const Self = @This();
            pub fn process(self: *Self, in: []const S, o0: []S) void {
                _ = self;
                @memcpy(o0, in);
            }
        },
        2 => struct {
            const Self = @This();
            pub fn process(self: *Self, in: []const S, o0: []S, o1: []S) void {
                _ = self;
                @memcpy(o0, in);
                @memcpy(o1, in);
            }
        },
        3 => struct {
            const Self = @This();
            pub fn process(self: *Self, in: []const S, o0: []S, o1: []S, o2: []S) void {
                _ = self;
                @memcpy(o0, in);
                @memcpy(o1, in);
                @memcpy(o2, in);
            }
        },
        4 => struct {
            const Self = @This();
            pub fn process(self: *Self, in: []const S, o0: []S, o1: []S, o2: []S, o3: []S) void {
                _ = self;
                @memcpy(o0, in);
                @memcpy(o1, in);
                @memcpy(o2, in);
                @memcpy(o3, in);
            }
        },
        5 => struct {
            const Self = @This();
            pub fn process(self: *Self, in: []const S, o0: []S, o1: []S, o2: []S, o3: []S, o4: []S) void {
                _ = self;
                inline for (.{ o0, o1, o2, o3, o4 }) |o| @memcpy(o, in);
            }
        },
        6 => struct {
            const Self = @This();
            pub fn process(self: *Self, in: []const S, o0: []S, o1: []S, o2: []S, o3: []S, o4: []S, o5: []S) void {
                _ = self;
                inline for (.{ o0, o1, o2, o3, o4, o5 }) |o| @memcpy(o, in);
            }
        },
        7 => struct {
            const Self = @This();
            pub fn process(self: *Self, in: []const S, o0: []S, o1: []S, o2: []S, o3: []S, o4: []S, o5: []S, o6: []S) void {
                _ = self;
                inline for (.{ o0, o1, o2, o3, o4, o5, o6 }) |o| @memcpy(o, in);
            }
        },
        8 => struct {
            const Self = @This();
            pub fn process(self: *Self, in: []const S, o0: []S, o1: []S, o2: []S, o3: []S, o4: []S, o5: []S, o6: []S, o7: []S) void {
                _ = self;
                inline for (.{ o0, o1, o2, o3, o4, o5, o6, o7 }) |o| @memcpy(o, in);
            }
        },
        else => unreachable,
    };
}

// ===========================================================================
// MatrixRouter — n_in → n_out weighted routing matrix
// ===========================================================================

/// `MatrixRouter(num, n_in, n_out)` — an `n_in → n_out` routing/mix matrix. Each
/// output is the weighted sum of all inputs:
///
///     out_j[i] = Σ_k coeff[j][k] · in_k[i]
///
/// The `[n_out][n_in]` `coeff` field is runtime-settable (a plain field, set
/// directly between renders — the same "coefficients are block data, not the
/// stream type" convention `Gain`/`Biquad` follow). It defaults to the identity-
/// like passthrough on the shared diagonal (`coeff[j][k] = 1` when `j == k`, else
/// `0`), so an unset router routes input `k` to output `k`.
///
/// Weights and accumulation are in the lane domain: a float lane uses linear
/// multipliers and accumulates in `num.Acc` (= the lane); an integer lane treats
/// each weight as a `q(frac)` fixed-point coefficient, multiplies into `num.Acc`
/// (twice the lane width), right-shifts back by `frac`, and saturates on store.
///
/// Both arities are bounded by the 8-port ceiling. Like `combinators.Concat`,
/// each `(n_in, n_out)` shape needs an explicit `process` parameter list; this
/// block keeps the input/output ports as fixed-arity slices and loops the matrix
/// internally, so a single comptime-built body serves every shape via index
/// access into a tuple of the slices.
/// `MatrixRouter(num, n_in, n_out)` — an `n_in → n_out` routing/mix matrix. Each
/// output is the weighted sum of all inputs:
///
///     out_j[i] = Σ_k coeff[j][k] · in_k[i]
///
/// The `[n_out][n_in]` `coeff` field is runtime-settable (a plain field, set
/// directly between renders — the same "coefficients are block data, not the
/// stream type" convention `Gain`/`Biquad` follow). It defaults to the identity-
/// like passthrough on the shared diagonal (`coeff[j][k] = 1` when `j == k`, else
/// `0`), so an unset router routes input `k` to output `k`.
///
/// Weights and accumulation are in the lane domain: a float lane uses linear
/// multipliers and accumulates in `num.Acc` (= the lane); an integer lane treats
/// each weight as a `q(frac)` fixed-point coefficient, multiplies into `num.Acc`
/// (twice the lane width), right-shifts back by `frac`, and saturates on store.
///
/// Both arities are bounded by the 8-port ceiling. Like `combinators.Concat`,
/// each `(n_in, n_out)` shape needs an explicit `process` parameter list (a list
/// cannot be synthesized from a comptime count, and a void-padded fixed-arity
/// signature would make the port scanner reject a `void` param), so the shape is
/// selected by a `switch` over `(n_in, n_out)`; each prong's body is uniform —
/// every output row is the weighted sum over the inputs.
pub fn MatrixRouter(comptime num: numeric.Numeric, comptime n_in: usize, comptime n_out: usize) type {
    if (n_in == 0 or n_out == 0) @compileError("pan: MatrixRouter needs n_in >= 1 and n_out >= 1");
    if (n_in > 8)
        @compileError(std.fmt.comptimePrint("pan: MatrixRouter n_in={d} exceeds the 8-port ceiling", .{n_in}));
    if (n_out > 8)
        @compileError(std.fmt.comptimePrint("pan: MatrixRouter n_out={d} exceeds the 8-port ceiling", .{n_out}));
    const T = num.Lane;
    const S = types.Sample(T);

    // Fractional-bit count for an integer-lane weight. A routing/mix matrix needs
    // to represent unity gain (and modest >1 mixing gains) exactly, so the weights
    // use a Q2 fixed-point format — TWO integer bits above the sign — giving a
    // coefficient range of about [-2, +2). This is deliberately one bit shy of the
    // lane's own q(bits-1) sample format: in q(bits-1) the value +1.0 is NOT
    // representable (the maximum positive value is just under +1, and `1 << (bits-1)`
    // is the sign bit, i.e. the most-negative value), so a "unity" diagonal weight
    // would silently become -1.0 and invert the signal. With `frac = bits-2`, unity
    // is `1 << (bits-2)`, a representable positive value, and `(unity·x) >> frac == x`
    // exactly — the default diagonal is a true bit-exact passthrough. Unused for float.
    const frac: comptime_int = if (isFloat(T)) 0 else @typeInfo(T).int.bits - 2;

    // The default diagonal passthrough: input k → output k at unity.
    const default_coeff = blk: {
        var m: [n_out][n_in]T = undefined;
        for (0..n_out) |j| {
            for (0..n_in) |k| {
                const unity: T = if (isFloat(T)) 1 else (@as(T, 1) << frac);
                m[j][k] = if (j == k) unity else 0;
            }
        }
        break :blk m;
    };

    return switch (n_in * 8 + n_out) {
        9 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, o0: []S) void {
                const ins = .{in0};
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                }
            }
        },
        10 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, o0: []S, o1: []S) void {
                const ins = .{in0};
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                }
            }
        },
        11 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, o0: []S, o1: []S, o2: []S) void {
                const ins = .{in0};
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                    o2[r].ch[0] = self.mixOne(2, ins, r);
                }
            }
        },
        12 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, o0: []S, o1: []S, o2: []S, o3: []S) void {
                const ins = .{in0};
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                    o2[r].ch[0] = self.mixOne(2, ins, r);
                    o3[r].ch[0] = self.mixOne(3, ins, r);
                }
            }
        },
        13 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, o0: []S, o1: []S, o2: []S, o3: []S, o4: []S) void {
                const ins = .{in0};
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                    o2[r].ch[0] = self.mixOne(2, ins, r);
                    o3[r].ch[0] = self.mixOne(3, ins, r);
                    o4[r].ch[0] = self.mixOne(4, ins, r);
                }
            }
        },
        14 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, o0: []S, o1: []S, o2: []S, o3: []S, o4: []S, o5: []S) void {
                const ins = .{in0};
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                    o2[r].ch[0] = self.mixOne(2, ins, r);
                    o3[r].ch[0] = self.mixOne(3, ins, r);
                    o4[r].ch[0] = self.mixOne(4, ins, r);
                    o5[r].ch[0] = self.mixOne(5, ins, r);
                }
            }
        },
        15 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, o0: []S, o1: []S, o2: []S, o3: []S, o4: []S, o5: []S, o6: []S) void {
                const ins = .{in0};
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                    o2[r].ch[0] = self.mixOne(2, ins, r);
                    o3[r].ch[0] = self.mixOne(3, ins, r);
                    o4[r].ch[0] = self.mixOne(4, ins, r);
                    o5[r].ch[0] = self.mixOne(5, ins, r);
                    o6[r].ch[0] = self.mixOne(6, ins, r);
                }
            }
        },
        16 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, o0: []S, o1: []S, o2: []S, o3: []S, o4: []S, o5: []S, o6: []S, o7: []S) void {
                const ins = .{in0};
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                    o2[r].ch[0] = self.mixOne(2, ins, r);
                    o3[r].ch[0] = self.mixOne(3, ins, r);
                    o4[r].ch[0] = self.mixOne(4, ins, r);
                    o5[r].ch[0] = self.mixOne(5, ins, r);
                    o6[r].ch[0] = self.mixOne(6, ins, r);
                    o7[r].ch[0] = self.mixOne(7, ins, r);
                }
            }
        },
        17 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, o0: []S) void {
                const ins = .{ in0, in1 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                }
            }
        },
        18 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, o0: []S, o1: []S) void {
                const ins = .{ in0, in1 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                }
            }
        },
        19 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, o0: []S, o1: []S, o2: []S) void {
                const ins = .{ in0, in1 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                    o2[r].ch[0] = self.mixOne(2, ins, r);
                }
            }
        },
        20 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, o0: []S, o1: []S, o2: []S, o3: []S) void {
                const ins = .{ in0, in1 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                    o2[r].ch[0] = self.mixOne(2, ins, r);
                    o3[r].ch[0] = self.mixOne(3, ins, r);
                }
            }
        },
        21 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, o0: []S, o1: []S, o2: []S, o3: []S, o4: []S) void {
                const ins = .{ in0, in1 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                    o2[r].ch[0] = self.mixOne(2, ins, r);
                    o3[r].ch[0] = self.mixOne(3, ins, r);
                    o4[r].ch[0] = self.mixOne(4, ins, r);
                }
            }
        },
        22 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, o0: []S, o1: []S, o2: []S, o3: []S, o4: []S, o5: []S) void {
                const ins = .{ in0, in1 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                    o2[r].ch[0] = self.mixOne(2, ins, r);
                    o3[r].ch[0] = self.mixOne(3, ins, r);
                    o4[r].ch[0] = self.mixOne(4, ins, r);
                    o5[r].ch[0] = self.mixOne(5, ins, r);
                }
            }
        },
        23 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, o0: []S, o1: []S, o2: []S, o3: []S, o4: []S, o5: []S, o6: []S) void {
                const ins = .{ in0, in1 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                    o2[r].ch[0] = self.mixOne(2, ins, r);
                    o3[r].ch[0] = self.mixOne(3, ins, r);
                    o4[r].ch[0] = self.mixOne(4, ins, r);
                    o5[r].ch[0] = self.mixOne(5, ins, r);
                    o6[r].ch[0] = self.mixOne(6, ins, r);
                }
            }
        },
        24 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, o0: []S, o1: []S, o2: []S, o3: []S, o4: []S, o5: []S, o6: []S, o7: []S) void {
                const ins = .{ in0, in1 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                    o2[r].ch[0] = self.mixOne(2, ins, r);
                    o3[r].ch[0] = self.mixOne(3, ins, r);
                    o4[r].ch[0] = self.mixOne(4, ins, r);
                    o5[r].ch[0] = self.mixOne(5, ins, r);
                    o6[r].ch[0] = self.mixOne(6, ins, r);
                    o7[r].ch[0] = self.mixOne(7, ins, r);
                }
            }
        },
        25 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, in2: []const S, o0: []S) void {
                const ins = .{ in0, in1, in2 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                }
            }
        },
        26 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, in2: []const S, o0: []S, o1: []S) void {
                const ins = .{ in0, in1, in2 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                }
            }
        },
        27 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, in2: []const S, o0: []S, o1: []S, o2: []S) void {
                const ins = .{ in0, in1, in2 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                    o2[r].ch[0] = self.mixOne(2, ins, r);
                }
            }
        },
        28 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, in2: []const S, o0: []S, o1: []S, o2: []S, o3: []S) void {
                const ins = .{ in0, in1, in2 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                    o2[r].ch[0] = self.mixOne(2, ins, r);
                    o3[r].ch[0] = self.mixOne(3, ins, r);
                }
            }
        },
        29 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, in2: []const S, o0: []S, o1: []S, o2: []S, o3: []S, o4: []S) void {
                const ins = .{ in0, in1, in2 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                    o2[r].ch[0] = self.mixOne(2, ins, r);
                    o3[r].ch[0] = self.mixOne(3, ins, r);
                    o4[r].ch[0] = self.mixOne(4, ins, r);
                }
            }
        },
        30 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, in2: []const S, o0: []S, o1: []S, o2: []S, o3: []S, o4: []S, o5: []S) void {
                const ins = .{ in0, in1, in2 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                    o2[r].ch[0] = self.mixOne(2, ins, r);
                    o3[r].ch[0] = self.mixOne(3, ins, r);
                    o4[r].ch[0] = self.mixOne(4, ins, r);
                    o5[r].ch[0] = self.mixOne(5, ins, r);
                }
            }
        },
        31 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, in2: []const S, o0: []S, o1: []S, o2: []S, o3: []S, o4: []S, o5: []S, o6: []S) void {
                const ins = .{ in0, in1, in2 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                    o2[r].ch[0] = self.mixOne(2, ins, r);
                    o3[r].ch[0] = self.mixOne(3, ins, r);
                    o4[r].ch[0] = self.mixOne(4, ins, r);
                    o5[r].ch[0] = self.mixOne(5, ins, r);
                    o6[r].ch[0] = self.mixOne(6, ins, r);
                }
            }
        },
        32 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, in2: []const S, o0: []S, o1: []S, o2: []S, o3: []S, o4: []S, o5: []S, o6: []S, o7: []S) void {
                const ins = .{ in0, in1, in2 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                    o2[r].ch[0] = self.mixOne(2, ins, r);
                    o3[r].ch[0] = self.mixOne(3, ins, r);
                    o4[r].ch[0] = self.mixOne(4, ins, r);
                    o5[r].ch[0] = self.mixOne(5, ins, r);
                    o6[r].ch[0] = self.mixOne(6, ins, r);
                    o7[r].ch[0] = self.mixOne(7, ins, r);
                }
            }
        },
        33 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, in2: []const S, in3: []const S, o0: []S) void {
                const ins = .{ in0, in1, in2, in3 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                }
            }
        },
        34 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, in2: []const S, in3: []const S, o0: []S, o1: []S) void {
                const ins = .{ in0, in1, in2, in3 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                }
            }
        },
        35 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, in2: []const S, in3: []const S, o0: []S, o1: []S, o2: []S) void {
                const ins = .{ in0, in1, in2, in3 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                    o2[r].ch[0] = self.mixOne(2, ins, r);
                }
            }
        },
        36 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, in2: []const S, in3: []const S, o0: []S, o1: []S, o2: []S, o3: []S) void {
                const ins = .{ in0, in1, in2, in3 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                    o2[r].ch[0] = self.mixOne(2, ins, r);
                    o3[r].ch[0] = self.mixOne(3, ins, r);
                }
            }
        },
        37 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, in2: []const S, in3: []const S, o0: []S, o1: []S, o2: []S, o3: []S, o4: []S) void {
                const ins = .{ in0, in1, in2, in3 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                    o2[r].ch[0] = self.mixOne(2, ins, r);
                    o3[r].ch[0] = self.mixOne(3, ins, r);
                    o4[r].ch[0] = self.mixOne(4, ins, r);
                }
            }
        },
        38 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, in2: []const S, in3: []const S, o0: []S, o1: []S, o2: []S, o3: []S, o4: []S, o5: []S) void {
                const ins = .{ in0, in1, in2, in3 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                    o2[r].ch[0] = self.mixOne(2, ins, r);
                    o3[r].ch[0] = self.mixOne(3, ins, r);
                    o4[r].ch[0] = self.mixOne(4, ins, r);
                    o5[r].ch[0] = self.mixOne(5, ins, r);
                }
            }
        },
        39 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, in2: []const S, in3: []const S, o0: []S, o1: []S, o2: []S, o3: []S, o4: []S, o5: []S, o6: []S) void {
                const ins = .{ in0, in1, in2, in3 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                    o2[r].ch[0] = self.mixOne(2, ins, r);
                    o3[r].ch[0] = self.mixOne(3, ins, r);
                    o4[r].ch[0] = self.mixOne(4, ins, r);
                    o5[r].ch[0] = self.mixOne(5, ins, r);
                    o6[r].ch[0] = self.mixOne(6, ins, r);
                }
            }
        },
        40 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, in2: []const S, in3: []const S, o0: []S, o1: []S, o2: []S, o3: []S, o4: []S, o5: []S, o6: []S, o7: []S) void {
                const ins = .{ in0, in1, in2, in3 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                    o2[r].ch[0] = self.mixOne(2, ins, r);
                    o3[r].ch[0] = self.mixOne(3, ins, r);
                    o4[r].ch[0] = self.mixOne(4, ins, r);
                    o5[r].ch[0] = self.mixOne(5, ins, r);
                    o6[r].ch[0] = self.mixOne(6, ins, r);
                    o7[r].ch[0] = self.mixOne(7, ins, r);
                }
            }
        },
        41 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, in2: []const S, in3: []const S, in4: []const S, o0: []S) void {
                const ins = .{ in0, in1, in2, in3, in4 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                }
            }
        },
        42 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, in2: []const S, in3: []const S, in4: []const S, o0: []S, o1: []S) void {
                const ins = .{ in0, in1, in2, in3, in4 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                }
            }
        },
        43 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, in2: []const S, in3: []const S, in4: []const S, o0: []S, o1: []S, o2: []S) void {
                const ins = .{ in0, in1, in2, in3, in4 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                    o2[r].ch[0] = self.mixOne(2, ins, r);
                }
            }
        },
        44 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, in2: []const S, in3: []const S, in4: []const S, o0: []S, o1: []S, o2: []S, o3: []S) void {
                const ins = .{ in0, in1, in2, in3, in4 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                    o2[r].ch[0] = self.mixOne(2, ins, r);
                    o3[r].ch[0] = self.mixOne(3, ins, r);
                }
            }
        },
        45 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, in2: []const S, in3: []const S, in4: []const S, o0: []S, o1: []S, o2: []S, o3: []S, o4: []S) void {
                const ins = .{ in0, in1, in2, in3, in4 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                    o2[r].ch[0] = self.mixOne(2, ins, r);
                    o3[r].ch[0] = self.mixOne(3, ins, r);
                    o4[r].ch[0] = self.mixOne(4, ins, r);
                }
            }
        },
        46 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, in2: []const S, in3: []const S, in4: []const S, o0: []S, o1: []S, o2: []S, o3: []S, o4: []S, o5: []S) void {
                const ins = .{ in0, in1, in2, in3, in4 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                    o2[r].ch[0] = self.mixOne(2, ins, r);
                    o3[r].ch[0] = self.mixOne(3, ins, r);
                    o4[r].ch[0] = self.mixOne(4, ins, r);
                    o5[r].ch[0] = self.mixOne(5, ins, r);
                }
            }
        },
        47 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, in2: []const S, in3: []const S, in4: []const S, o0: []S, o1: []S, o2: []S, o3: []S, o4: []S, o5: []S, o6: []S) void {
                const ins = .{ in0, in1, in2, in3, in4 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                    o2[r].ch[0] = self.mixOne(2, ins, r);
                    o3[r].ch[0] = self.mixOne(3, ins, r);
                    o4[r].ch[0] = self.mixOne(4, ins, r);
                    o5[r].ch[0] = self.mixOne(5, ins, r);
                    o6[r].ch[0] = self.mixOne(6, ins, r);
                }
            }
        },
        48 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, in2: []const S, in3: []const S, in4: []const S, o0: []S, o1: []S, o2: []S, o3: []S, o4: []S, o5: []S, o6: []S, o7: []S) void {
                const ins = .{ in0, in1, in2, in3, in4 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                    o2[r].ch[0] = self.mixOne(2, ins, r);
                    o3[r].ch[0] = self.mixOne(3, ins, r);
                    o4[r].ch[0] = self.mixOne(4, ins, r);
                    o5[r].ch[0] = self.mixOne(5, ins, r);
                    o6[r].ch[0] = self.mixOne(6, ins, r);
                    o7[r].ch[0] = self.mixOne(7, ins, r);
                }
            }
        },
        49 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, in2: []const S, in3: []const S, in4: []const S, in5: []const S, o0: []S) void {
                const ins = .{ in0, in1, in2, in3, in4, in5 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                }
            }
        },
        50 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, in2: []const S, in3: []const S, in4: []const S, in5: []const S, o0: []S, o1: []S) void {
                const ins = .{ in0, in1, in2, in3, in4, in5 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                }
            }
        },
        51 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, in2: []const S, in3: []const S, in4: []const S, in5: []const S, o0: []S, o1: []S, o2: []S) void {
                const ins = .{ in0, in1, in2, in3, in4, in5 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                    o2[r].ch[0] = self.mixOne(2, ins, r);
                }
            }
        },
        52 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, in2: []const S, in3: []const S, in4: []const S, in5: []const S, o0: []S, o1: []S, o2: []S, o3: []S) void {
                const ins = .{ in0, in1, in2, in3, in4, in5 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                    o2[r].ch[0] = self.mixOne(2, ins, r);
                    o3[r].ch[0] = self.mixOne(3, ins, r);
                }
            }
        },
        53 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, in2: []const S, in3: []const S, in4: []const S, in5: []const S, o0: []S, o1: []S, o2: []S, o3: []S, o4: []S) void {
                const ins = .{ in0, in1, in2, in3, in4, in5 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                    o2[r].ch[0] = self.mixOne(2, ins, r);
                    o3[r].ch[0] = self.mixOne(3, ins, r);
                    o4[r].ch[0] = self.mixOne(4, ins, r);
                }
            }
        },
        54 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, in2: []const S, in3: []const S, in4: []const S, in5: []const S, o0: []S, o1: []S, o2: []S, o3: []S, o4: []S, o5: []S) void {
                const ins = .{ in0, in1, in2, in3, in4, in5 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                    o2[r].ch[0] = self.mixOne(2, ins, r);
                    o3[r].ch[0] = self.mixOne(3, ins, r);
                    o4[r].ch[0] = self.mixOne(4, ins, r);
                    o5[r].ch[0] = self.mixOne(5, ins, r);
                }
            }
        },
        55 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, in2: []const S, in3: []const S, in4: []const S, in5: []const S, o0: []S, o1: []S, o2: []S, o3: []S, o4: []S, o5: []S, o6: []S) void {
                const ins = .{ in0, in1, in2, in3, in4, in5 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                    o2[r].ch[0] = self.mixOne(2, ins, r);
                    o3[r].ch[0] = self.mixOne(3, ins, r);
                    o4[r].ch[0] = self.mixOne(4, ins, r);
                    o5[r].ch[0] = self.mixOne(5, ins, r);
                    o6[r].ch[0] = self.mixOne(6, ins, r);
                }
            }
        },
        56 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, in2: []const S, in3: []const S, in4: []const S, in5: []const S, o0: []S, o1: []S, o2: []S, o3: []S, o4: []S, o5: []S, o6: []S, o7: []S) void {
                const ins = .{ in0, in1, in2, in3, in4, in5 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                    o2[r].ch[0] = self.mixOne(2, ins, r);
                    o3[r].ch[0] = self.mixOne(3, ins, r);
                    o4[r].ch[0] = self.mixOne(4, ins, r);
                    o5[r].ch[0] = self.mixOne(5, ins, r);
                    o6[r].ch[0] = self.mixOne(6, ins, r);
                    o7[r].ch[0] = self.mixOne(7, ins, r);
                }
            }
        },
        57 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, in2: []const S, in3: []const S, in4: []const S, in5: []const S, in6: []const S, o0: []S) void {
                const ins = .{ in0, in1, in2, in3, in4, in5, in6 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                }
            }
        },
        58 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, in2: []const S, in3: []const S, in4: []const S, in5: []const S, in6: []const S, o0: []S, o1: []S) void {
                const ins = .{ in0, in1, in2, in3, in4, in5, in6 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                }
            }
        },
        59 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, in2: []const S, in3: []const S, in4: []const S, in5: []const S, in6: []const S, o0: []S, o1: []S, o2: []S) void {
                const ins = .{ in0, in1, in2, in3, in4, in5, in6 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                    o2[r].ch[0] = self.mixOne(2, ins, r);
                }
            }
        },
        60 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, in2: []const S, in3: []const S, in4: []const S, in5: []const S, in6: []const S, o0: []S, o1: []S, o2: []S, o3: []S) void {
                const ins = .{ in0, in1, in2, in3, in4, in5, in6 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                    o2[r].ch[0] = self.mixOne(2, ins, r);
                    o3[r].ch[0] = self.mixOne(3, ins, r);
                }
            }
        },
        61 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, in2: []const S, in3: []const S, in4: []const S, in5: []const S, in6: []const S, o0: []S, o1: []S, o2: []S, o3: []S, o4: []S) void {
                const ins = .{ in0, in1, in2, in3, in4, in5, in6 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                    o2[r].ch[0] = self.mixOne(2, ins, r);
                    o3[r].ch[0] = self.mixOne(3, ins, r);
                    o4[r].ch[0] = self.mixOne(4, ins, r);
                }
            }
        },
        62 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, in2: []const S, in3: []const S, in4: []const S, in5: []const S, in6: []const S, o0: []S, o1: []S, o2: []S, o3: []S, o4: []S, o5: []S) void {
                const ins = .{ in0, in1, in2, in3, in4, in5, in6 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                    o2[r].ch[0] = self.mixOne(2, ins, r);
                    o3[r].ch[0] = self.mixOne(3, ins, r);
                    o4[r].ch[0] = self.mixOne(4, ins, r);
                    o5[r].ch[0] = self.mixOne(5, ins, r);
                }
            }
        },
        63 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, in2: []const S, in3: []const S, in4: []const S, in5: []const S, in6: []const S, o0: []S, o1: []S, o2: []S, o3: []S, o4: []S, o5: []S, o6: []S) void {
                const ins = .{ in0, in1, in2, in3, in4, in5, in6 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                    o2[r].ch[0] = self.mixOne(2, ins, r);
                    o3[r].ch[0] = self.mixOne(3, ins, r);
                    o4[r].ch[0] = self.mixOne(4, ins, r);
                    o5[r].ch[0] = self.mixOne(5, ins, r);
                    o6[r].ch[0] = self.mixOne(6, ins, r);
                }
            }
        },
        64 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, in2: []const S, in3: []const S, in4: []const S, in5: []const S, in6: []const S, o0: []S, o1: []S, o2: []S, o3: []S, o4: []S, o5: []S, o6: []S, o7: []S) void {
                const ins = .{ in0, in1, in2, in3, in4, in5, in6 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                    o2[r].ch[0] = self.mixOne(2, ins, r);
                    o3[r].ch[0] = self.mixOne(3, ins, r);
                    o4[r].ch[0] = self.mixOne(4, ins, r);
                    o5[r].ch[0] = self.mixOne(5, ins, r);
                    o6[r].ch[0] = self.mixOne(6, ins, r);
                    o7[r].ch[0] = self.mixOne(7, ins, r);
                }
            }
        },
        65 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, in2: []const S, in3: []const S, in4: []const S, in5: []const S, in6: []const S, in7: []const S, o0: []S) void {
                const ins = .{ in0, in1, in2, in3, in4, in5, in6, in7 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                }
            }
        },
        66 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, in2: []const S, in3: []const S, in4: []const S, in5: []const S, in6: []const S, in7: []const S, o0: []S, o1: []S) void {
                const ins = .{ in0, in1, in2, in3, in4, in5, in6, in7 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                }
            }
        },
        67 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, in2: []const S, in3: []const S, in4: []const S, in5: []const S, in6: []const S, in7: []const S, o0: []S, o1: []S, o2: []S) void {
                const ins = .{ in0, in1, in2, in3, in4, in5, in6, in7 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                    o2[r].ch[0] = self.mixOne(2, ins, r);
                }
            }
        },
        68 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, in2: []const S, in3: []const S, in4: []const S, in5: []const S, in6: []const S, in7: []const S, o0: []S, o1: []S, o2: []S, o3: []S) void {
                const ins = .{ in0, in1, in2, in3, in4, in5, in6, in7 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                    o2[r].ch[0] = self.mixOne(2, ins, r);
                    o3[r].ch[0] = self.mixOne(3, ins, r);
                }
            }
        },
        69 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, in2: []const S, in3: []const S, in4: []const S, in5: []const S, in6: []const S, in7: []const S, o0: []S, o1: []S, o2: []S, o3: []S, o4: []S) void {
                const ins = .{ in0, in1, in2, in3, in4, in5, in6, in7 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                    o2[r].ch[0] = self.mixOne(2, ins, r);
                    o3[r].ch[0] = self.mixOne(3, ins, r);
                    o4[r].ch[0] = self.mixOne(4, ins, r);
                }
            }
        },
        70 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, in2: []const S, in3: []const S, in4: []const S, in5: []const S, in6: []const S, in7: []const S, o0: []S, o1: []S, o2: []S, o3: []S, o4: []S, o5: []S) void {
                const ins = .{ in0, in1, in2, in3, in4, in5, in6, in7 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                    o2[r].ch[0] = self.mixOne(2, ins, r);
                    o3[r].ch[0] = self.mixOne(3, ins, r);
                    o4[r].ch[0] = self.mixOne(4, ins, r);
                    o5[r].ch[0] = self.mixOne(5, ins, r);
                }
            }
        },
        71 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, in2: []const S, in3: []const S, in4: []const S, in5: []const S, in6: []const S, in7: []const S, o0: []S, o1: []S, o2: []S, o3: []S, o4: []S, o5: []S, o6: []S) void {
                const ins = .{ in0, in1, in2, in3, in4, in5, in6, in7 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                    o2[r].ch[0] = self.mixOne(2, ins, r);
                    o3[r].ch[0] = self.mixOne(3, ins, r);
                    o4[r].ch[0] = self.mixOne(4, ins, r);
                    o5[r].ch[0] = self.mixOne(5, ins, r);
                    o6[r].ch[0] = self.mixOne(6, ins, r);
                }
            }
        },
        72 => struct {
            const Self = @This();
            coeff: [n_out][n_in]T = default_coeff,
            inline fn mixOne(self: *const Self, comptime j: usize, ins: anytype, r: usize) T {
                var acc: num.Acc = 0;
                inline for (0..n_in) |k| {
                    const x: num.Acc = ins[k][r].ch[0];
                    acc += @as(num.Acc, self.coeff[j][k]) * x;
                }
                if (comptime isFloat(T)) return storeAcc(num, acc);
                return storeAcc(num, acc >> frac);
            }
            pub fn process(self: *Self, in0: []const S, in1: []const S, in2: []const S, in3: []const S, in4: []const S, in5: []const S, in6: []const S, in7: []const S, o0: []S, o1: []S, o2: []S, o3: []S, o4: []S, o5: []S, o6: []S, o7: []S) void {
                const ins = .{ in0, in1, in2, in3, in4, in5, in6, in7 };
                const n = o0.len;
                var r: usize = 0;
                while (r < n) : (r += 1) {
                    o0[r].ch[0] = self.mixOne(0, ins, r);
                    o1[r].ch[0] = self.mixOne(1, ins, r);
                    o2[r].ch[0] = self.mixOne(2, ins, r);
                    o3[r].ch[0] = self.mixOne(3, ins, r);
                    o4[r].ch[0] = self.mixOne(4, ins, r);
                    o5[r].ch[0] = self.mixOne(5, ins, r);
                    o6[r].ch[0] = self.mixOne(6, ins, r);
                    o7[r].ch[0] = self.mixOne(7, ins, r);
                }
            }
        },
        else => unreachable,
    };
}

// ===========================================================================
// DryWet — linear crossfade of dry and wet by a mix parameter
// ===========================================================================

/// `DryWet(num)` — blend two `Sample(T)` inputs (`dry`, `wet`) by a `mix`
/// parameter in `[0,1]`:
///
///     out = (1 − mix)·dry + mix·wet
///
/// This is a LINEAR crossfade: at `mix = 0` the output is `dry`, at `mix = 1` it
/// is `wet`, and at `mix = 0.5` it is the arithmetic average `(dry + wet)/2`
/// (NOT equal-power; the two are not gain-compensated at the centre).
///
/// `mix` is a parameter port (`drywet.param.mix`, control element `Scalar(f32)`),
/// driven either by a wired modulation edge or by an external `set`, both arriving
/// through `setParam`. It is held between renders (no per-block ramp here — the
/// blend is a stateless per-sample mix). Float lanes only: a fixed-point `(1−mix)`
/// blend needs the q-format + wide-accumulator treatment not ported here, so the
/// integer path fails loud (a compile error, never silently-wrong audio).
pub fn DryWet(comptime num: numeric.Numeric) type {
    const T = num.Lane;
    if (!isFloat(T))
        @compileError("pan: DryWet is float-only for now — a fixed-point (1−mix)" ++
            " blend needs the q-format + wide-accumulator treatment, not yet ported" ++
            " here. Use f32/f64.");
    const S = types.Sample(T);
    return struct {
        const Self = @This();

        /// The blend parameter port (control element `Scalar(f32)`). Slot 0.
        pub const params = .{ .mix = types.Scalar(f32) };

        /// The blend coefficient in `[0,1]`, held between renders. Set by an external
        /// `set` or a wired parameter edge through `setParam`, or directly.
        mix: f32 = 0,

        pub fn setParam(self: *Self, slot: u8, value: f32) void {
            if (slot == 0) self.mix = std.math.clamp(value, 0, 1);
        }

        pub fn process(self: *Self, dry: []const S, wet: []const S, out: []S) void {
            const m: T = @floatCast(self.mix);
            const one_minus: T = 1 - m;
            for (out, dry, wet) |*o, d, w| {
                o.ch[0] = one_minus * d.ch[0] + m * w.ch[0];
            }
        }
    };
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;
const port = @import("port.zig");

const f32num = numeric.numericFor(.f32, .{});
const i16num = numeric.numericFor(.i16, .{});

fn s32(v: f32) types.Sample(f32) {
    return .{ .ch = .{v} };
}
fn s16(v: i16) types.Sample(i16) {
    return .{ .ch = .{v} };
}

test "SummingMixer classifies as a Map with the right port count and elements" {
    // WHY: a mix/routing block is rate-1:1, so it MUST classify as a Map; and the
    // port scanner must see exactly n_in inputs + 1 output of Sample(T), else the
    // graph would mis-wire it.
    const Mix3 = SummingMixer(f32num, 3);
    try testing.expect(port.classify(Mix3) == .Map);
    try testing.expectEqual(@as(comptime_int, 3), port.mapInputCount(Mix3));
    try testing.expectEqual(@as(comptime_int, 1), port.mapOutputCount(Mix3));
    try testing.expect(port.MapInPortAt(Mix3, 0).Elem == types.Sample(f32));
    try testing.expect(port.MapInPortAt(Mix3, 2).Elem == types.Sample(f32));
    try testing.expect(port.MapOutPort(Mix3).Elem == types.Sample(f32));
    try testing.expect(comptime port.isPortId(port.MapInPort(Mix3)));
}

test "SummingMixer(f32) sums its inputs sample-by-sample" {
    // WHY: additive mixing is the contract — out[i] must equal the plain sum of
    // the aligned input samples, with no per-input gain applied.
    var mix = SummingMixer(f32num, 3){};
    const a = [_]types.Sample(f32){ s32(1.0), s32(-2.0) };
    const b = [_]types.Sample(f32){ s32(0.5), s32(0.25) };
    const c = [_]types.Sample(f32){ s32(0.25), s32(1.75) };
    var out: [2]types.Sample(f32) = undefined;
    mix.process(&a, &b, &c, &out);
    try testing.expectApproxEqAbs(@as(f32, 1.75), out[0].ch[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.0), out[1].ch[0], 1e-6);
}

test "SummingMixer(i16) accumulates in the wide Acc and saturates on store" {
    // WHY: the whole point of the num.Acc integer path is that a sum exceeding the
    // lane bound must NOT wrap (32767 + 32767 wraps to -2 in i16) — it must keep
    // full headroom in i32 and clamp to maxInt(i16) only at the final store.
    var mix = SummingMixer(i16num, 2){};
    const big = std.math.maxInt(i16); // 32767
    const a = [_]types.Sample(i16){ s16(big), s16(10) };
    const b = [_]types.Sample(i16){ s16(big), s16(-30) };
    var out: [2]types.Sample(i16) = undefined;
    mix.process(&a, &b, &out);
    try testing.expectEqual(@as(i16, big), out[0].ch[0]); // saturated, not wrapped
    try testing.expectEqual(@as(i16, -20), out[1].ch[0]); // in-range sum is exact
}

test "MatrixRouter classifies as a Map and defaults to diagonal passthrough" {
    // WHY: an unset router must be a transparent pass-through (input k → output k),
    // and it must classify as a Map with n_in inputs + n_out outputs.
    const R = MatrixRouter(f32num, 2, 2);
    try testing.expect(port.classify(R) == .Map);
    try testing.expectEqual(@as(comptime_int, 2), port.mapInputCount(R));
    try testing.expectEqual(@as(comptime_int, 2), port.mapOutputCount(R));

    var r = R{};
    const in0 = [_]types.Sample(f32){s32(3.0)};
    const in1 = [_]types.Sample(f32){s32(7.0)};
    var o0: [1]types.Sample(f32) = undefined;
    var o1: [1]types.Sample(f32) = undefined;
    r.process(&in0, &in1, &o0, &o1);
    try testing.expectApproxEqAbs(@as(f32, 3.0), o0[0].ch[0], 1e-6); // out0 = in0
    try testing.expectApproxEqAbs(@as(f32, 7.0), o1[0].ch[0], 1e-6); // out1 = in1
}

test "MatrixRouter(2x2) applies the weight matrix exactly (hand-checked)" {
    // WHY: the defining law is out_j = Σ_k coeff[j][k]·in_k. Hand-pick a non-trivial
    // 2x2 matrix and verify both outputs to prove the indexing (row=out, col=in) and
    // the accumulation are correct — a transposed matrix would fail this.
    const R = MatrixRouter(f32num, 2, 2);
    var r = R{};
    // out0 = 0.5*in0 + 2.0*in1 ; out1 = -1.0*in0 + 0.25*in1
    r.coeff = .{ .{ 0.5, 2.0 }, .{ -1.0, 0.25 } };
    const in0 = [_]types.Sample(f32){ s32(4.0), s32(2.0) };
    const in1 = [_]types.Sample(f32){ s32(1.0), s32(8.0) };
    var o0: [2]types.Sample(f32) = undefined;
    var o1: [2]types.Sample(f32) = undefined;
    r.process(&in0, &in1, &o0, &o1);
    // r=0: out0 = 0.5*4 + 2*1 = 4 ; out1 = -1*4 + 0.25*1 = -3.75
    try testing.expectApproxEqAbs(@as(f32, 4.0), o0[0].ch[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, -3.75), o1[0].ch[0], 1e-6);
    // r=1: out0 = 0.5*2 + 2*8 = 17 ; out1 = -1*2 + 0.25*8 = 0
    try testing.expectApproxEqAbs(@as(f32, 17.0), o0[1].ch[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.0), o1[1].ch[0], 1e-6);
}

test "DryWet classifies as a Map with a mix parameter port" {
    // WHY: DryWet has two sample inputs + one output and a control parameter; the
    // param port must expose Scalar(f32) so a modulation edge type-checks against it.
    const D = DryWet(f32num);
    try testing.expect(port.classify(D) == .Map);
    try testing.expectEqual(@as(comptime_int, 2), port.mapInputCount(D));
    try testing.expectEqual(@as(comptime_int, 1), port.mapOutputCount(D));
    const Mix = port.ParamPort(D, "mix");
    try testing.expect(Mix.Elem == types.Scalar(f32));
    try testing.expect(comptime port.isParamPort(Mix));
}

test "DryWet: mix=0 => dry, mix=1 => wet, mix=0.5 => average" {
    // WHY: this is the defining crossfade law at its three anchor points. A linear
    // crossfade MUST hit dry at 0, wet at 1, and the arithmetic mean at 0.5 — any
    // other midpoint would mean a different (e.g. equal-power) law than documented.
    const D = DryWet(f32num);
    const dry = [_]types.Sample(f32){ s32(2.0), s32(-4.0) };
    const wet = [_]types.Sample(f32){ s32(10.0), s32(8.0) };
    var out: [2]types.Sample(f32) = undefined;

    var d0 = D{};
    d0.setParam(0, 0.0);
    d0.process(&dry, &wet, &out);
    try testing.expectApproxEqAbs(@as(f32, 2.0), out[0].ch[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, -4.0), out[1].ch[0], 1e-6);

    var d1 = D{};
    d1.setParam(0, 1.0);
    d1.process(&dry, &wet, &out);
    try testing.expectApproxEqAbs(@as(f32, 10.0), out[0].ch[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 8.0), out[1].ch[0], 1e-6);

    var dh = D{};
    dh.setParam(0, 0.5);
    dh.process(&dry, &wet, &out);
    try testing.expectApproxEqAbs(@as(f32, 6.0), out[0].ch[0], 1e-6); // (2+10)/2
    try testing.expectApproxEqAbs(@as(f32, 2.0), out[1].ch[0], 1e-6); // (-4+8)/2
}

test "DryWet.setParam clamps mix into [0,1]" {
    // WHY: mix is contractually in [0,1]; an out-of-range modulation value must be
    // clamped so the blend can never extrapolate beyond dry/wet.
    const D = DryWet(f32num);
    var d = D{};
    d.setParam(0, 5.0);
    try testing.expectEqual(@as(f32, 1.0), d.mix);
    d.setParam(0, -2.0);
    try testing.expectEqual(@as(f32, 0.0), d.mix);
}

test "Splitter classifies as a Map and copies the input to every output" {
    // WHY: a splitter must be a Map with one input and exactly n_out outputs, and
    // each output must be a byte-identical copy of the input — fan-out duplicates,
    // it does not transform.
    const Sp = Splitter(f32num, 3);
    try testing.expect(port.classify(Sp) == .Map);
    try testing.expectEqual(@as(comptime_int, 1), port.mapInputCount(Sp));
    try testing.expectEqual(@as(comptime_int, 3), port.mapOutputCount(Sp));

    var sp = Sp{};
    const in = [_]types.Sample(f32){ s32(1.5), s32(2.5), s32(-3.5) };
    var o0: [3]types.Sample(f32) = undefined;
    var o1: [3]types.Sample(f32) = undefined;
    var o2: [3]types.Sample(f32) = undefined;
    sp.process(&in, &o0, &o1, &o2);
    for (in, o0, o1, o2) |x, a, b, c| {
        try testing.expectEqual(x.ch[0], a.ch[0]);
        try testing.expectEqual(x.ch[0], b.ch[0]);
        try testing.expectEqual(x.ch[0], c.ch[0]);
    }
}
