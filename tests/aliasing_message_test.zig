//! Tests-as-definition for the `aliasing_safe` failure-message contract.
//!
//! Characterized here: the `expectPanVsPan` comparator (and its helpers
//! `firstBitDivergence` and `declaresAliasingSafe`) from `tests/harness.zig`.
//! `expectPanVsPan` is a pan-vs-pan **bit-exact** comparison: a single differing
//! bit pattern is a divergence (so a NaN paranoid-poison counts as divergence and
//! +0.0/-0.0 are distinct). On agreement it returns void; on a divergence it
//! routes to one of two error values according to whether `Block` declared
//! `pub const aliasing_safe = true`:
//!   - declared  -> the safety claim is FALSE: `error.AliasingSafeViolated`;
//!   - undeclared -> a generic storage/colorer bug: `error.PanDivergence`.
//! A length mismatch is `error.LengthMismatch`.
//!
//! COMPARISON MODE (testing contract §0.5): this characterizes a pan-vs-pan
//! bit-exact comparator and its error/agreement boundary. We assert the exact
//! returned error value (or void) — never the printed diagnostic text. The
//! falsified-contract / divergence diagnostics print to stderr on the failure
//! paths; that printing is expected and must NOT be treated as a test failure
//! (the runner still exits 0 as long as no test fails).
//!
//! The blocks below are constructed to make the operational meaning of
//! `aliasing_safe` concrete: a block is in-place-safe iff `process()` never reads
//! an input element AFTER the corresponding output element was overwritten.
//!   - Reading a FUTURE index (`out[i] = in[i] + in[i+1]`) is forward-safe:
//!     aliased and disjoint AGREE, so declaring it `aliasing_safe` is honest.
//!   - Reading a PAST index (`out[i] = in[i] + in[i-1]`) is NOT in-place-safe:
//!     when aliased (out==in), `in[i-1]` was already overwritten by the previous
//!     iteration's write, so aliased DIVERGES from disjoint. A past-index reader
//!     that nonetheless declares `aliasing_safe = true` is LYING — and the
//!     comparator must catch it.

const std = @import("std");
const h = @import("harness.zig");
const pan = @import("pan");

const Sample = pan.Sample;

// --- blocks constructed to exercise the contract ---------------------------

/// HONEST aliasing_safe: a future-index reader. `out[i] = in[i] + in[i+1]`
/// (last lane reads only itself). Reads precede the corresponding write in the
/// aliasing sense — at iteration i the future element in[i+1] has not yet been
/// overwritten — so aliased and disjoint renders agree. Declaring `aliasing_safe`
/// is therefore truthful, and `expectPanVsPan` must PASS.
const HonestFutureReader = struct {
    const Self = @This();
    pub const aliasing_safe = true;
    pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
        _ = self;
        const n = in.len;
        for (0..n) |i| {
            const nxt = if (i + 1 < n) in[i + 1].ch[0] else 0.0;
            out[i].ch[0] = in[i].ch[0] + nxt;
        }
    }
};

/// LYING aliasing_safe: a past-index reader. `out[i] = in[i] + in[i-1]`.
/// When aliased (out==in), the previous iteration already wrote out[i-1] (==
/// in[i-1]), so the read of in[i-1] sees the OUTPUT, not the original input —
/// aliased diverges from disjoint starting at i=1. The block nevertheless claims
/// `aliasing_safe = true`; that claim is FALSE and the comparator must report
/// `error.AliasingSafeViolated`.
const LyingPastReader = struct {
    const Self = @This();
    pub const aliasing_safe = true;
    pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
        _ = self;
        const n = in.len;
        for (0..n) |i| {
            const prev = if (i >= 1) in[i - 1].ch[0] else 0.0;
            out[i].ch[0] = in[i].ch[0] + prev;
        }
    }
};

/// A past-index reader that does NOT declare any aliasing_safe marker. Same
/// kernel as LyingPastReader, but without the false safety claim. Used to show
/// that an aliased-vs-disjoint divergence on an unmarked block is reported as the
/// generic `error.PanDivergence` (a storage/colorer-class bug message), NOT as a
/// falsified-contract violation.
const UnmarkedPastReader = struct {
    const Self = @This();
    pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
        _ = self;
        const n = in.len;
        for (0..n) |i| {
            const prev = if (i >= 1) in[i - 1].ch[0] else 0.0;
            out[i].ch[0] = in[i].ch[0] + prev;
        }
    }
};

/// A block that explicitly declares `aliasing_safe = false`. `declaresAliasingSafe`
/// must treat this as NOT declaring safety (the value, not mere presence, decides).
const ExplicitlyUnsafe = struct {
    const Self = @This();
    pub const aliasing_safe = false;
    pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
        _ = self;
        @memcpy(out, in);
    }
};

const N = 64;
const CHUNK = N; // whole-buffer render; aliasing hazard is intra-call here.

/// Render a block's disjoint (push) stream and its aliased (in-place) stream over
/// the same noise input, returning both as `[]const f32` views for the bit-exact
/// comparator. Buffers are caller-owned arrays passed in by pointer so their
/// storage outlives the returned views.
fn renderBothPaths(
    comptime Block: type,
    disjoint_in: *[N]Sample(f32),
    disjoint_out: *[N]Sample(f32),
    aliased: *[N]Sample(f32),
    seed: u64,
) struct { ref: []const f32, cand: []const f32 } {
    h.fillNoise(disjoint_in, seed);
    // The aliased path shares one buffer seeded with the SAME input.
    aliased.* = disjoint_in.*;

    var ref_blk: Block = .{};
    var cand_blk: Block = .{};
    h.renderPush(Block, &ref_blk, disjoint_in, disjoint_out, CHUNK);
    h.renderAliased(Block, &cand_blk, aliased);

    return .{
        .ref = h.sampleValues(disjoint_out),
        .cand = h.sampleValues(aliased),
    };
}

// --- expectPanVsPan: the aliasing_safe error/agreement boundary ------------

test "a false aliasing_safe claim is a falsified contract, not an opaque mismatch (catalog §7.6)" {
    // A past-index reader that declares aliasing_safe = true LIES: aliased and
    // disjoint diverge, and because the block asserted the safety the comparator
    // names the falsified contract -> error.AliasingSafeViolated. (The
    // falsified-contract diagnostic prints to stderr; that is expected.)
    var din: [N]Sample(f32) = undefined;
    var dout: [N]Sample(f32) = undefined;
    var ali: [N]Sample(f32) = undefined;
    const streams = renderBothPaths(LyingPastReader, &din, &dout, &ali, 0xA11A5);

    // Precondition for the test to be meaningful: the two paths really diverge.
    // (If they did not, the comparator would return void and the test below would
    // be vacuous — so pin the divergence first.)
    try std.testing.expect(h.firstBitDivergence(streams.ref, streams.cand) != null);

    try std.testing.expectError(
        error.AliasingSafeViolated,
        h.expectPanVsPan(LyingPastReader, streams.ref, streams.cand, "double-buffered", "in-place"),
    );
}

test "an honest aliasing_safe block (future-index read) agrees aliased vs disjoint and passes" {
    // Reading a FUTURE index is forward-safe: the aliased in-place render produces
    // the SAME stream as the disjoint render, so the safety claim is truthful and
    // expectPanVsPan returns void (no divergence, no error, no diagnostic).
    var din: [N]Sample(f32) = undefined;
    var dout: [N]Sample(f32) = undefined;
    var ali: [N]Sample(f32) = undefined;
    const streams = renderBothPaths(HonestFutureReader, &din, &dout, &ali, 0xF00D);

    try std.testing.expect(h.firstBitDivergence(streams.ref, streams.cand) == null);
    try h.expectPanVsPan(HonestFutureReader, streams.ref, streams.cand, "double-buffered", "in-place");
}

test "h.Scale is honestly aliasing_safe: per-lane read-then-write agrees in place" {
    // The harness's own Scale block (out[i] = in[i]*k) only ever reads its own
    // lane before writing it, so aliased == disjoint. A truthful aliasing_safe
    // claim must pass.
    var din: [N]Sample(f32) = undefined;
    var dout: [N]Sample(f32) = undefined;
    var ali: [N]Sample(f32) = undefined;
    h.fillNoise(&din, 0x5CA1E);
    ali = din;

    var ref_blk: h.Scale = .{ .k = 0.5 };
    var cand_blk: h.Scale = .{ .k = 0.5 };
    h.renderPush(h.Scale, &ref_blk, &din, &dout, CHUNK);
    h.renderAliased(h.Scale, &cand_blk, &ali);

    const ref = h.sampleValues(&dout);
    const cand = h.sampleValues(&ali);
    try std.testing.expect(h.firstBitDivergence(ref, cand) == null);
    try h.expectPanVsPan(h.Scale, ref, cand, "double-buffered", "in-place");
}

test "an UNMARKED block whose two streams diverge is a generic PanDivergence, not a contract violation" {
    // Same past-index kernel, but no aliasing_safe marker. The divergence is real
    // yet there is no safety claim to falsify, so it routes to the generic
    // storage/colorer-bug error.PanDivergence. (Its diagnostic prints to stderr.)
    var din: [N]Sample(f32) = undefined;
    var dout: [N]Sample(f32) = undefined;
    var ali: [N]Sample(f32) = undefined;
    const streams = renderBothPaths(UnmarkedPastReader, &din, &dout, &ali, 0xBADF00D);

    try std.testing.expect(h.firstBitDivergence(streams.ref, streams.cand) != null);

    try std.testing.expectError(
        error.PanDivergence,
        h.expectPanVsPan(UnmarkedPastReader, streams.ref, streams.cand, "double-buffered", "in-place"),
    );
}

test "agreement returns void regardless of the aliasing_safe marker" {
    // Two bit-identical streams: no divergence index, so the comparator returns
    // void on the very first check (the marker is never consulted on this path).
    const a = [_]f32{ 0.0, 1.5, -2.25, 3.0, std.math.pi };
    const b = [_]f32{ 0.0, 1.5, -2.25, 3.0, std.math.pi };

    // Declared-safe block: void (no falsified contract because nothing diverged).
    try h.expectPanVsPan(h.Scale, &a, &b, "ref", "cand");
    // Unmarked block: void as well.
    try h.expectPanVsPan(h.Identity, &a, &b, "ref", "cand");
}

test "a length mismatch is LengthMismatch and is decided before the marker is consulted" {
    // Different lengths short-circuit to error.LengthMismatch — this precedes both
    // the divergence scan and any aliasing_safe routing, so the Block's marker is
    // irrelevant. Verify with both a declared-safe and an unmarked block.
    const short = [_]f32{ 1.0, 2.0, 3.0 };
    const long = [_]f32{ 1.0, 2.0, 3.0, 4.0 };

    try std.testing.expectError(
        error.LengthMismatch,
        h.expectPanVsPan(h.Scale, &short, &long, "ref", "cand"),
    );
    try std.testing.expectError(
        error.LengthMismatch,
        h.expectPanVsPan(h.Identity, &long, &short, "ref", "cand"),
    );
}

test "the violation path keys on the block's marker, not on which stream is 'aliased'" {
    // Cross-check: the SAME divergent streams, compared once under a declared-safe
    // block and once under an unmarked block, yield AliasingSafeViolated vs
    // PanDivergence respectively. The routing is a property of the comptime Block
    // type, nothing else.
    var din: [N]Sample(f32) = undefined;
    var dout: [N]Sample(f32) = undefined;
    var ali: [N]Sample(f32) = undefined;
    const streams = renderBothPaths(LyingPastReader, &din, &dout, &ali, 0xDECAF);
    try std.testing.expect(h.firstBitDivergence(streams.ref, streams.cand) != null);

    try std.testing.expectError(
        error.AliasingSafeViolated,
        h.expectPanVsPan(LyingPastReader, streams.ref, streams.cand, "double-buffered", "in-place"),
    );
    // Identical bytes, only the comptime Block differs -> different error.
    try std.testing.expectError(
        error.PanDivergence,
        h.expectPanVsPan(h.Identity, streams.ref, streams.cand, "double-buffered", "in-place"),
    );
}

// --- firstBitDivergence: bit-exact pinpointing -----------------------------

test "firstBitDivergence returns null for byte-identical streams" {
    const a = [_]f32{ -1.0, 0.0, 1.0, 42.0 };
    const b = [_]f32{ -1.0, 0.0, 1.0, 42.0 };
    try std.testing.expectEqual(@as(?usize, null), h.firstBitDivergence(&a, &b));
}

test "firstBitDivergence pinpoints the FIRST differing index, ignoring later agreements" {
    // Index 0,1 agree; 2 differs; 3 differs too — the FIRST (2) is reported.
    const a = [_]f32{ 1.0, 2.0, 3.0, 9.0 };
    const b = [_]f32{ 1.0, 2.0, 3.5, 8.0 };
    try std.testing.expectEqual(@as(?usize, 2), h.firstBitDivergence(&a, &b));
}

test "firstBitDivergence treats a NaN paranoid-poison vs a finite value as a divergence" {
    // The poison mechanism overwrites a released buffer with NaN; a stale read
    // must surface as a divergence rather than slip past. Bit comparison makes a
    // NaN-vs-finite mismatch a divergence at exactly the poisoned index.
    var poisoned = [_]f32{ 0.25, 0.5, 0.5, 0.75 };
    h.poisonNaN(poisoned[2..3]); // poison only index 2
    const finite = [_]f32{ 0.25, 0.5, 0.5, 0.75 };

    try std.testing.expect(h.anyNaN(&poisoned)); // the poison really took
    try std.testing.expectEqual(@as(?usize, 2), h.firstBitDivergence(&finite, &poisoned));
}

test "firstBitDivergence treats two NaNs with the SAME bit pattern as identical" {
    // Value `!=` would call NaN != NaN true; the comparator uses BIT equality, so
    // two identical NaN bit patterns are NOT a divergence. This is the
    // counterexample that a value-based implementation would get wrong.
    var a = [_]f32{ 0.0, 0.0 };
    var b = [_]f32{ 0.0, 0.0 };
    h.poisonNaN(&a);
    h.poisonNaN(&b);
    try std.testing.expectEqual(@as(?usize, null), h.firstBitDivergence(&a, &b));
}

test "firstBitDivergence distinguishes +0.0 from -0.0 as different bit patterns" {
    // +0.0 == -0.0 by value, but their bit patterns differ (sign bit). The
    // bit-exact comparator MUST flag the difference. A value-based implementation
    // would wrongly return null here.
    const pos = [_]f32{ 1.0, 0.0, 2.0 };
    const neg = [_]f32{ 1.0, -0.0, 2.0 };
    // Guard the premise: these ARE equal by value but differ in bits.
    try std.testing.expect(pos[1] == neg[1]);
    try std.testing.expect(@as(u32, @bitCast(pos[1])) != @as(u32, @bitCast(neg[1])));
    try std.testing.expectEqual(@as(?usize, 1), h.firstBitDivergence(&pos, &neg));
}

test "firstBitDivergence over empty streams is null" {
    const a = [_]f32{};
    const b = [_]f32{};
    try std.testing.expectEqual(@as(?usize, null), h.firstBitDivergence(&a, &b));
}

// --- declaresAliasingSafe: comptime correctness of the marker --------------

test "declaresAliasingSafe is true only for a block with `pub const aliasing_safe = true`" {
    // Declared true.
    try std.testing.expect(h.declaresAliasingSafe(h.Scale));
    try std.testing.expect(h.declaresAliasingSafe(HonestFutureReader));
    try std.testing.expect(h.declaresAliasingSafe(LyingPastReader));
}

test "declaresAliasingSafe is false for a block with no aliasing_safe declaration" {
    try std.testing.expect(!h.declaresAliasingSafe(h.Identity));
    try std.testing.expect(!h.declaresAliasingSafe(h.Accumulator));
    try std.testing.expect(!h.declaresAliasingSafe(UnmarkedPastReader));
}

test "declaresAliasingSafe is false when the marker is present but set to false" {
    // The VALUE decides, not mere presence of the decl: aliasing_safe = false must
    // read as "does not declare safety".
    try std.testing.expect(@hasDecl(ExplicitlyUnsafe, "aliasing_safe"));
    try std.testing.expect(!h.declaresAliasingSafe(ExplicitlyUnsafe));
}
