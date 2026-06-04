//! The freestanding ReleaseSmall smoke object — the embedded "same code,
//! specialized" obligation, discharged by compilation.
//!
//! This compiles the comptime commit pass (and now a real fixed-point render
//! path) against a freestanding target with no std runtime, no allocator, and no
//! test harness. Two obligations are discharged here, and the object compiling at
//! all IS the discharge for these graphs (not a proof for arbitrary graphs;
//! failing to compile is the loud failure):
//!
//!   1. `pan_smoke_footprint` — the original commit-evaluable-at-comptime gate: a
//!      tiny f32 graph committed at comptime, its `footprint_bytes` returned (an
//!      exported function whose value forces the commit at compile time).
//!   2. The q15 embedded chain — `I2sDmaSource → Gain → Biquad → I2sDmaSink` over
//!      the fixed-point Numeric, committed at comptime and rendered by the bound
//!      `Executor`. The render is fully monomorphized (the op-list `inline for`s
//!      with comptime-known buffer ids and calls each block's `process` directly):
//!      there is NO `SampleMux` fat pointer and NO vtable on the hot path. The
//!      pool and the two `2N` DMA ping-pong buffers all live in static `.bss`; the
//!      render entry is shaped like the I2S DMA interrupt that drives it on an MCU.

const root = @import("root.zig");

// --- Obligation 1: comptime-evaluable commit (f32 smoke graph) --------------

export fn pan_smoke_footprint() usize {
    const g = comptime root.smokeGraph();
    const plan = comptime root.commitComptime(g) catch unreachable;
    return plan.footprint_bytes;
}

// --- Obligation 2: the q15 embedded render path -----------------------------
//
// All three buffers are static `.bss`: the executor's colored pool (the render
// memory the H2 footprint formula sizes) and the RX/TX `2N` DMA ping-pong
// buffers. There is no heap on this target. The executor's pool IS the static
// render memory; a `FixedBufferAllocator` over a `.bss` array would back any
// block that allocated at `initialize`, but the embedded comptime blocks
// (Gain/Biquad/I2sDma) allocate nothing — their state lives inline in the
// instances, counted by the footprint, not in a heap.

const num = root.embedded.num;
const N = root.embedded.N;

/// The RX I2S DMA transport (codec → graph): a `2N`-frame circular buffer in `.bss`.
var rx: @import("io.zig").I2sDma(num, N) = .{};
/// The TX I2S DMA transport (graph → codec).
var tx: @import("io.zig").I2sDma(num, N) = .{};

/// The fully-monomorphized q15 executor. Its colored pool (`exec.pool`) is the
/// static render memory in `.bss`; the four instances are seeded here — a q15 gain
/// of ~0.8 and the stable resonant low-pass whose feedback coefficient `a1`
/// (−14000 in Q2.13 ≈ −1.71) exceeds the q15 lane's ±1 range, the case the fixed-
/// point biquad's wider coefficient format exists for.
var exec: root.embedded.Exec = .{
    .instances = .{
        .{}, // I2sDmaSource — dma pointer bound at init
        .{ .gain = 26214 }, // Gain(q15): round(0.8 · 2^15)
        .{ .coeffs = .{ .b0 = 50, .b1 = 100, .b2 = 50, .a1 = -14000, .a2 = 6500 } }, // Biquad(q15)
        .{}, // I2sDmaSink — dma pointer bound at init
    },
};

/// Bind the boundary blocks to their DMA transports. Pointers into mutable `.bss`
/// are not comptime-known, so they are seeded once at startup rather than at
/// commit. Call before the first render.
export fn pan_i2s_bind() void {
    exec.instances[0].dma = &rx;
    exec.instances[3].dma = &tx;
}

/// The render entry, shaped like the I2S DMA half-/transfer-complete ISR that
/// drives it on an MCU. On a concrete target this symbol is aliased to the
/// device's DMA IRQ vector (the freestanding stub here does not name a concrete
/// MCU — that, with its register map and the known STM32-HAL TC-suppression
/// caveat, is a later phase). `enterRealtimeThread` is the SAME API as desktop; on
/// a fixed-point / FPU-less target it is a no-op token (nothing to flush), but the
/// token-gated render entry shape is identical. `which_half` selects the DMA half
/// the processing side now owns (0 = the half-transfer IRQ, 1 = transfer-complete).
export fn pan_i2s_render_isr(which_half: u8) void {
    if (which_half == 0) {
        rx.onHalfTransfer();
        tx.onHalfTransfer();
    } else {
        rx.onTransferComplete();
        tx.onTransferComplete();
    }
    const tok = root.enterRealtimeThread();
    exec.render(tok);
}

/// The q15 chain's pool footprint — a comptime constant, returned so the commit
/// is forced at compile time during the object build (the same discharge shape as
/// `pan_smoke_footprint`).
export fn pan_smoke_footprint_q15() usize {
    return root.embedded.footprint_bytes;
}
