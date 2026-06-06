//! pan — the public API surface.
//!
//! This root module pins and re-exports the public identifiers. The load-
//! bearing type machinery (the Numeric trait, the channel-layout descriptor,
//! the canonical port elements, the typed `PortId`, the block classifier) is
//! real and exercised throughout; the builder/engine surface is pinned and its
//! authoring arc type-checks, while the executor, control plane, and the
//! layered DSP libraries are completed by later phases.

const std = @import("std");

// --- configuration --------------------------------------------------------

/// The Numeric trait & comptime precision switch. `precision` is comptime-known:
/// `numericFor(p, opts)` is a comptime switch and a precision change requires a
/// recommit.
pub const numeric = @import("numeric.zig");
pub const Numeric = numeric.Numeric;
pub const Precision = numeric.Precision;
pub const NumericOptions = numeric.NumericOptions;
pub const numericFor = numeric.numericFor;

pub const config = @import("config.zig");
pub const Config = config.Config;

// --- canonical port elements ----------------------------------------------

pub const types = @import("types.zig");
pub const ChannelLayout = types.ChannelLayout;
pub const Frame = types.Frame;
pub const Sample = types.Sample;
pub const Planar = types.Planar;
pub const PlanarConst = types.PlanarConst;
pub const isPlanarView = types.isPlanarView;
pub const Complex = types.Complex;
pub const FeatureFrame = types.FeatureFrame;
pub const Scalar = types.Scalar;
pub const Bounded = types.Bounded;

// --- comptime port machinery ----------------------------------------------

pub const port = @import("port.zig");
pub const PortId = port.PortId;
pub const ParamPortId = port.ParamPortId;
pub const ParamPort = port.ParamPort;
pub const NamedInPort = port.NamedInPort;
pub const ConcatOut = port.ConcatOut;
pub const Direction = port.Direction;
pub const BlockClass = port.BlockClass;
pub const classify = port.classify;
pub const isSource = port.isSource;

// --- the SampleMux seam (the only block ↔ transport coupling) --------------

pub const mux = @import("mux.zig");
pub const SampleMux = mux.SampleMux;
pub const TestSampleMux = mux.TestSampleMux;
pub const PullTestSampleMux = mux.PullTestSampleMux;
pub const PullSampleMux = mux.PullSampleMux;
pub const RingSampleMux = mux.RingSampleMux;
/// `Ring` — the bounded SPSC block channel that backs `RingSampleMux` (the
/// offline push transport's substance; the inter-stage carrier in pipeline
/// parallelism).
pub const Ring = mux.Ring;

// --- OfflineBatch (Tier C): the push / throughput execution mode -----------

/// The OfflineBatch executor and its timeline I/O endpoints. `OfflineBatch(g,
/// node_blocks)` renders a committed comptime graph off the audio deadline:
/// sequentially (the K=1 ground truth), data-parallel chunked across cores (with
/// the `warmup_samples` lead-in + ordered merge → O3), or pipelined stage-per-
/// thread over `Ring`s. `offline.Source`/`offline.Sink` inject and capture the
/// timeline.
pub const offline = @import("offline.zig");
pub const OfflineBatch = offline.OfflineBatch;
/// `OfflineBatch` with automatic comptime loop-fusion applied: a drop-in that runs
/// the same Tier-C machinery on the fused graph, recovering the single-pass /
/// byte-displacement win for offline renders. Bit-exact to the unfused render.
pub const OfflineBatchFused = offline.OfflineBatchFused;

/// The thin unified entry façade: one `pan.render(...)` that routes by intent
/// (`.realtime` → the comptime Tier-A executor block-by-block; `.offline` → the
/// Tier-C `OfflineBatch`) over an offline-style endpoint graph, plus `renderJobs`
/// for file-level offline parallelism. It delegates to the existing executors —
/// it unifies only the entry seam, not the tier internals.
pub const facade = @import("facade.zig");
pub const render = facade.render;
pub const renderJobs = facade.renderJobs;
pub const RenderOptions = facade.RenderOptions;

// --- graph, commit, engine ------------------------------------------------

/// The low-level comptime graph IR (the substrate the commit pass consumes).
pub const graph = @import("graph.zig");

pub const commit = @import("commit.zig");
pub const RenderOp = commit.RenderOp;
pub const Plan = commit.Plan;
pub const CommitError = commit.CommitError;
pub const BufferMode = commit.BufferMode;
pub const Coercion = commit.Coercion;
pub const EdgeFormat = commit.EdgeFormat;
pub const coercionFor = commit.coercionFor;
pub const commitComptime = commit.commitComptime;
pub const commitComptimeMode = commit.commitComptimeMode;
pub const commitRuntime = commit.commitRuntime;
pub const commitGraph = commit.commitGraph;
pub const insertCoercions = commit.insertCoercions;
/// The plugin-delay-compensation pass: per-rate-domain longest-path DP that inserts
/// compensating `DelayLine`s on the shorter inputs of a latency-mismatched fan-in
/// (and routes a bypassed latent block's delay), so parallel branches re-align
/// sample-accurately. Run by `commitRuntime`; usable directly for a comptime commit.
pub const insertPdc = commit.insertPdc;

/// The developer-facing graph builder — `pan.Graph.init / add / connect /
/// commit`. Wraps the IR and the commit pass.
pub const builder = @import("builder.zig");
pub const Graph = builder.Graph;
pub const NodeHandle = builder.NodeHandle;
pub const Endpoint = builder.Endpoint;

/// The lock-free control plane: the SPSC `CommandRing` (`schedule`), the atomic
/// `Param` + `Ramp` (`set`), and the `Rcu` plan-swap cell (`edit → commit`) — each
/// at its exact memory ordering, wait-free on the audio thread.
pub const control = @import("control.zig");
pub const CommandRing = control.CommandRing;
pub const Command = control.Command;
pub const Param = control.Param;
pub const Ramp = control.Ramp;
pub const Rcu = control.Rcu;
/// The cross-root tap primitive: a lock-free SPSC data ring that fans a shared
/// upstream (rendered once on its owning root) to a second pull root. The graph
/// blocks that ride it are `io.Tap` (publish, on the upstream root) and
/// `io.TapSource` (consume, on the tapping root).
pub const SpscRing = control.SpscRing;

pub const engine = @import("engine.zig");
pub const Engine = engine.Engine;
pub const RuntimePlan = engine.RuntimePlan;
pub const BoundNode = engine.BoundNode;
pub const ExecutionMode = engine.ExecutionMode;
pub const EngineOptions = engine.EngineOptions;
pub const Threads = engine.Threads;
pub const Edit = engine.Edit;
pub const Telemetry = engine.Telemetry;
pub const RealtimeToken = engine.RealtimeToken;
pub const enterRealtimeThread = engine.enterRealtimeThread;
pub const renderInto = engine.renderInto;

/// Automatic comptime loop fusion — the pure `graph + block-tuple` rewrite
/// (`fusion.fuse`) that folds adjacent rate-1:1 type-stable single-consumer `Map`
/// chains into one block-size-1 `combinators.Subgraph` pass, plus the
/// `engine.FusedExecutor` that applies it transparently. Never an author API: an
/// author writes plain separate blocks; `FusedExecutor` just opts in to the win.
pub const fusion = @import("fusion.zig");
pub const FusedExecutor = engine.FusedExecutor;
pub const FusedExecutorMode = engine.FusedExecutorModeOnly;
pub const ParanoidFusedExecutor = engine.ParanoidFusedExecutor;

/// The Tier-A bound executor — monomorphize over a committed comptime graph and
/// its node-id → block-type tuple to get a runnable, wait-free pull renderer.
pub const Executor = engine.Executor;
pub const ExecutorMode = engine.ExecutorMode;
/// The Tier-A executor with active paranoid NaN-poison (Debug/ReleaseSafe): a
/// retired pool buffer is filled with NaN so a colorer/aliasing bug reaches the
/// sink as a loud NaN rather than as silently-stale audio.
pub const ParanoidExecutor = engine.ParanoidExecutor;

/// Tier B — the static-parallel RealtimeStreaming overlay (worker pool, render-
/// workgroup HAL, cost-model gate, op-DAG, level-barrier + HEFT schedules,
/// point-to-point ready flags, auto-demote). An opt-in, measured layer over the
/// frozen Tier-A ground truth: bit-identical output, auto-demoting under load.
pub const parallel = @import("parallel.zig");
pub const Workgroup = parallel.Workgroup;
pub const GateConfig = parallel.GateConfig;
pub const GateDecision = parallel.GateDecision;
pub const costGate = parallel.costGate;
pub const TierBExecutor = parallel.Executor;

// --- the Compute HAL (portable @Vector kernels) ---------------------------

pub const simd = @import("simd.zig");

// --- namespaced layered-library roots -------------------------------------

/// The I/O boundary: LPCM codecs (14 PCM formats + i24 packed + float PCM,
/// endianness, channel-order reconciliation, dither), the in-memory `LpcmSource`,
/// the desktop device backends (CoreAudio on macOS, ALSA on Linux) behind one
/// seam, and the embedded I2S-DMA ping-pong transport (`pan.io.I2sDma` +
/// `pan.io.I2sDmaSource`/`I2sDmaSink`) whose half-/transfer-complete IRQ is the
/// render callback on an MCU.
pub const io = @import("io.zig");
/// First DSP filters — `Gain` (aliasing-safe), `Biquad` (per-sample Mealy), and
/// `OnePole` (a low-pass whose cutoff is a parameter port — the canonical filter an
/// LFO/envelope sweeps).
pub const filters = @import("filters.zig");
pub const OnePole = filters.OnePole;
/// `StateVariable` (TPT/zero-delay-feedback SVF — lowpass/bandpass/highpass from one
/// pass; cutoff/Q are parameter ports) and `Fir` (windowed-sinc / arbitrary-tap FIR,
/// vectorized dot product; `firwinLowpass` builds the canonical lowpass table).
pub const StateVariable = filters.StateVariable;
pub const Fir = filters.Fir;
/// Windowed-sinc FIR coefficient designers: `firwinLowpass`, `firwinHighpass`
/// (spectral inversion), `firwinBandpass` (lowpass difference), `firwinBandstop` —
/// comptime tables for the `Fir` block's `coeffs`.
pub const firwinLowpass = filters.firwinLowpass;
pub const firwinHighpass = filters.firwinHighpass;
pub const firwinBandpass = filters.firwinBandpass;
pub const firwinBandstop = filters.firwinBandstop;
/// Spatial blocks — the layout-aware "pan" core. `ConstantPowerPan` (mono → stereo);
/// `Balance`/`Width` (stereo field, layout-preserving); `Upmix`/`Downmix`/`MixMatrix`
/// (the registered canonical up/down-mix matrices — geometry is block data, not the
/// stream type; an unregistered layout pair has no canonical matrix and is rejected).
pub const spatial = @import("spatial.zig");
pub const ConstantPowerPan = spatial.ConstantPowerPan;
pub const Balance = spatial.Balance;
pub const Width = spatial.Width;
pub const Upmix = spatial.Upmix;
pub const Downmix = spatial.Downmix;
pub const MixMatrix = spatial.MixMatrix;
pub const canonicalMixMatrix = spatial.canonicalMixMatrix;
/// `Vbap` (2-D vector base amplitude panning, mono → speaker layout) and ambisonic
/// `AmbisonicEncode` (mono+direction → B-format, ACN/SN3D, orders 0–2) /
/// `AmbisonicDecode` (B-format → speaker layout) — geometry as block data (L3).
pub const Vbap = spatial.Vbap;
pub const AmbisonicEncode = spatial.AmbisonicEncode;
pub const AmbisonicDecode = spatial.AmbisonicDecode;
/// Mix / routing `Map` blocks — `SummingMixer` (additive N→1, wide-accumulator on the
/// integer path), `Splitter` (1→N fan-out), `MatrixRouter` (N→M weighted routing
/// matrix), `DryWet` (a `mix`-parameter crossfade of a dry and a wet input).
pub const dsp_mix = @import("dsp_mix.zig");
pub const SummingMixer = dsp_mix.SummingMixer;
pub const Splitter = dsp_mix.Splitter;
pub const MatrixRouter = dsp_mix.MatrixRouter;
pub const DryWet = dsp_mix.DryWet;
/// The realtime-thread entry: `pan.realtime.enterRealtimeThread()` sets FTZ/DAZ.
pub const realtime = struct {
    pub const enterRealtimeThread = engine.enterRealtimeThread;
    pub const RealtimeToken = engine.RealtimeToken;
};

/// Time-domain delay primitives — element-generic `UnitDelay` / `DelayLine`. The
/// persistent (pool-excluded) delay state a feedback cycle is built on.
pub const time = @import("time.zig");
pub const UnitDelay = time.UnitDelay;
pub const DelayLine = time.DelayLine;
/// Multi-channel (planar) delays — the `Frame(C>1)` / `Frame(.discrete(N))` form a
/// stereo/surround delay or an FDN vector feedback edge rides.
pub const PlanarUnitDelay = time.PlanarUnitDelay;
pub const PlanarDelayLine = time.PlanarDelayLine;
/// Fused tight-feedback kernels — `Comb`, `Allpass`, `KarplusStrong`, `Ladder`:
/// single-`Map` blocks running a sample-accurate per-sample feedback loop over
/// internal state. `FdnMatrix` is the mixing core of a graph-level FDN reverb (the
/// matrix-mix `Map` over a `Frame(.discrete(N))` bus closed by feedback edges).
pub const fx = @import("fx.zig");
pub const Comb = fx.Comb;
pub const Allpass = fx.Allpass;
pub const KarplusStrong = fx.KarplusStrong;
pub const Ladder = fx.Ladder;
pub const FdnMatrix = fx.FdnMatrix;
/// Modulated-delay effects: `Chorus` (LFO-swept fractional delay blended with the
/// dry signal — thickening) and `Flanger` (a short swept delay WITH feedback — the
/// resonant comb sweep). Both are rate-1:1 `Map`s over an internal delay ring.
pub const Chorus = fx.Chorus;
pub const Flanger = fx.Flanger;
/// Modulation appliers & adaptive dynamics — the parameter-port *consumers* and
/// audio→control producers: `Vca` (gain via `param.gain`, the bit-exact-to-`set`
/// modulation target), `Agc` (fused adaptive gain), `AgcController` (its decoupled
/// controller emitting a gain `Scalar`), and `PowerGate` (a data-gating VAD/noise
/// gate whose `Scalar` gate the consumer multiplies — the schedule stays static).
pub const Vca = fx.Vca;
pub const Agc = fx.Agc;
pub const AgcController = fx.AgcController;
pub const PowerGate = fx.PowerGate;
/// Adaptive dynamics & adaptive-filter processors: `Compressor` (fused dynamics) and
/// `CompressorController` (its decoupled gain → a `Vca`), plus the NLMS adaptive
/// filters `Aec` (echo canceller, mic + reference → error) and `HowlSuppressor`
/// (leaky-NLMS acoustic-feedback canceller).
pub const Compressor = fx.Compressor;
pub const CompressorController = fx.CompressorController;
pub const Aec = fx.Aec;
pub const HowlSuppressor = fx.HowlSuppressor;
/// Static dynamics-shaping `Map`s: `Limiter` (brick-wall peak limiter — the
/// infinite-ratio limit of the compressor), `Expander` (downward expander, the soft
/// continuous-ratio form of the gate), `SoftClip` (memoryless cubic waveshaper with a
/// `drive`, aliasing-safe), and `Trim` (a static dB-gain, the dB face of `Gain`).
pub const Limiter = fx.Limiter;
pub const Expander = fx.Expander;
pub const SoftClip = fx.SoftClip;
pub const Trim = fx.Trim;

/// The rate-elastic seam — `Rate` blocks where output-per-input ≠ the algorithmic
/// latency: the `Framer`/`Stft`/`iStft` analysis-synthesis pair (radix-2 FFT, Hann
/// COLA reconstruction), the type-changing `PowerSpectrum` `Map`, and a windowed-
/// sinc rational `Resampler`. The blocks the per-rate-domain PDC pass compensates.
pub const spectral = @import("spectral.zig");
pub const Spectrum = spectral.Spectrum;
pub const TimeFrame = spectral.TimeFrame;
pub const Framer = spectral.Framer;
pub const Stft = spectral.Stft;
pub const iStft = spectral.iStft;
pub const PowerSpectrum = spectral.PowerSpectrum;
pub const Resampler = spectral.Resampler;
/// `Varispeed` — the arbitrary-runtime-ratio resampler `VariRate` (varispeed /
/// scrub / sample-playback pitch): a bounded `rate_bounds` interval + `max_latency`,
/// the operating ratio a held-per-call parameter (`connect(ctrl, vs.param.ratio)`).
pub const Varispeed = spectral.Varispeed;
/// `TimeStretch` — runtime tempo change without pitch change: a `VariRate` source
/// (overlap-add; the variable analysis hop is the rate seam, output = `stretch` ×
/// input length at the same pitch). `PitchShift` — constant-duration pitch shift =
/// time-stretch ∘ resample (a rate-1:1 `Map` source composing two VariRate stages).
pub const TimeStretch = spectral.TimeStretch;
pub const PitchShift = spectral.PitchShift;
/// Spectral-domain library blocks: `PartitionedConvolution` (uniform-partitioned
/// overlap-add FFT convolution reverb, a `Rate` over a frequency-domain delay line),
/// `SpectralGate` (per-bin magnitude noise gate) and `SpectralEq` (per-bin real-gain
/// EQ) — both `Map`s over the `Spectrum` stream. FFT-HAL consumers.
pub const PartitionedConvolution = spectral.PartitionedConvolution;
pub const SpectralGate = spectral.SpectralGate;
pub const SpectralEq = spectral.SpectralEq;

/// Multi-rate filterbanks — a CASCADE/bank of uniform-rate `Rate` stages (NOT one
/// block): `WaveletAnalysis`/`WaveletSynthesis` (Haar 2-band, perfect-reconstruction),
/// `DwtOctaveTree` (octave-band cascade) and `Cqt` (constant-Q bandpass bank).
pub const filterbank = @import("filterbank.zig");
pub const WaveletAnalysis = filterbank.WaveletAnalysis;
pub const WaveletSynthesis = filterbank.WaveletSynthesis;
pub const DwtOctaveTree = filterbank.DwtOctaveTree;
pub const Cqt = filterbank.Cqt;

/// Control-side generators — the modulation *producers* that drive parameter ports.
/// `Lfo` is a control-rate low-frequency oscillator: a zero-sample-input `Map`
/// source emitting `Scalar(f32)` (`connect(lfo, x.param.cutoff)`).
pub const gen = @import("gen.zig");
pub const Lfo = gen.Lfo;
/// Envelope generators & feature→parameter maps. `Adsr` is a gate→amplitude control
/// source (gate via a parameter port); `FeatureMap` is the affine `Scalar → Scalar`
/// rescale at the body of a feature→param modulation chain.
pub const env = @import("env.zig");
pub const Adsr = env.Adsr;
pub const FeatureMap = env.FeatureMap;
// Layered-library roots filled by later phases.
pub const mix = struct {};

/// The synthesis library — the Instrument graph shape. The typed event lane
/// (`EventLane(Event)`) and the blessed `NoteEvent` union; a worked `SawVoice`
/// (PolyBLEP osc → ADSR → VCA); and fixed-capacity intra-block polyphony as one
/// static op: `PolyVoice(Voice, Vmax)` (fused, internal-skip) / `VoiceMap` (replicated).
pub const synth = @import("synth.zig");
/// The blessed instrument event union (pitch in Hz; note_on/off, pressure, MPE
/// expression, control, bend, program). The event lane is event-generic; this is
/// the library type instruments consume.
pub const NoteEvent = synth.NoteEvent;
/// The event-type-generic lane a block consumes (a time-sorted `(sample_offset,
/// event)` view), delivered to its node out-of-band by the engine.
pub const EventLane = synth.EventLane;
/// One time-stamped event (`{ sample_offset, event }`).
pub const Timed = synth.Timed;
/// An MPE per-note expression axis (timbre / bend / slide).
pub const ExprAxis = synth.ExprAxis;
/// A worked single voice: PolyBLEP saw → per-sample ADSR → velocity VCA.
pub const SawVoice = synth.SawVoice;
/// Fixed-capacity intra-block polyphony as one static op (fused internal-skip).
pub const PolyVoice = synth.PolyVoice;
/// The replicated polyphony realisation (all `Vmax` voices run every callback).
pub const VoiceMap = synth.VoiceMap;
/// The musical transport (sample-accurate position, tempo, loop).
pub const Transport = io.Transport;
/// The MIDI-ingestion adapter feeding `NoteEvent`s into the engine's event ring.
pub const MidiEventSource = io.MidiEventSource;

/// Feature-extraction blocks — the analysis side. Each is a rate-1:1 `Map` over a
/// per-hop power spectrum (`FeatureFrame(bins)`): `Mfcc` (→ `FeatureFrame(K)`),
/// `SpectralCentroid`/`SpectralFlux`/`Rms` (→ `Scalar(f32)`), and `DominantBand`
/// (→ `Scalar(u16)`, a dominant-band (color/frequency-index) descriptor). Tested against an external
/// NumPy/librosa-equivalent oracle, not proven.
pub const feat = @import("feat.zig");

/// Graph combinators. `Concat` is the named fan-in: a comptime
/// struct-of-(name → element-type) spec mints one typed input port per name
/// (`node.in.<name>`) and a one-for-one output struct whose field order is the
/// canonical column order. `ChannelMap` replicates a mono block across C channels.
/// (Accessed as `pan.combinators.Concat` / `pan.feat.Mfcc` — not aliased at the
/// root to avoid shadowing the short block names a DSP author uses locally.)
pub const combinators = @import("combinators.zig");

/// The analysis pull root + feature collection surface. `FeatureCollectorSink` is
/// the growable, non-RT-only time-series sink (law A8 — rejected on a realtime
/// root); `runToCompletion`/`ClockSource` drive an analysis root by input
/// exhaustion; `writeFeatureMatrix`/`encodeFeatureMatrix` flatten the collected
/// rows to the column-major `f32` matrix a downstream consumer reads.
pub const FeatureCollectorSink = io.FeatureCollectorSink;
/// `Asrc` — the device-boundary drift-correcting asynchronous resampler: a
/// `VariRate` source over a bridging SPSC FIFO whose out:in ratio is nudged by an
/// internal PI controller to keep the FIFO centred (the controller-driven, ≈-only
/// determinism class). Bypass on a single full-duplex clock.
pub const Asrc = io.Asrc;
/// `SamplePlayer` — varispeed / scrub sample playback at an arbitrary live pitch: a
/// `VariRate` SOURCE over an owned sample asset, `param.pitch` the held-per-call read
/// step (parameter-driven, reproducible).
pub const SamplePlayer = io.SamplePlayer;
/// `PrefetchSource` — the off-thread-prefetch streaming file/network source: a
/// `Sample(T)` Map Source over a lock-free SPSC FIFO filled by a background prefetch
/// thread, so the audio thread pops wait-free with no disk I/O on the render path.
pub const PrefetchSource = io.PrefetchSource;
pub const writeFeatureMatrix = io.writeFeatureMatrix;
pub const encodeFeatureMatrix = io.encodeFeatureMatrix;
pub const featureMatrixColumns = io.featureMatrixColumns;
pub const ClockSource = engine.ClockSource;
pub const RunOptions = engine.RunOptions;

// =====================================================================
// The embedded q15 profile — a strict comptime specialization of the core.
//
// The embedded build is NOT a fork: it is the desktop core with every runtime
// degree of freedom collapsed to comptime. The block types are the SAME ones the
// desktop uses (`filters.Gain`, `filters.Biquad`) — only the Numeric is fixed-
// point (q15, no FPU, SIMD width pinned to 1) and the boundary blocks are the
// I2S-DMA ping-pong transport instead of CoreAudio/ALSA. The whole graph commits
// AT COMPTIME (coloring, footprint, op-list), and the bound `Executor`
// monomorphizes the render so the op-list `inline for`s with comptime-known buffer
// ids and dispatches each block's `process` DIRECTLY — there is no `SampleMux`
// fat pointer and no vtable on the hot path: the concept stays, the indirection
// vanishes. The `footprint_bytes` is a comptime constant (usable as a `.bss`
// array length), and the render entry is the I2S DMA half-/transfer-complete ISR.
// =====================================================================

/// The embedded q15 chain: `I2sDmaSource → Gain → Biquad → I2sDmaSink`, all over
/// the fixed-point Numeric. Reusable so both the freestanding smoke object (which
/// places its `Exec` pool in `.bss` and renders it from an ISR) and a desktop
/// differential test (which checks the monomorphized render is bit-identical to a
/// hand-run chain) build the SAME thing.
pub const embedded = struct {
    /// The comptime block size — half a DMA ping-pong buffer. On the MCU N is
    /// comptime-known (unlike the desktop's device-driven runtime N), so the
    /// scalar tail vanishes and kernels fully unroll: strictly easier than desktop.
    pub const N: usize = 64;
    /// The embedded Numeric: q15 (i16 lane, i32 default accumulator, saturating),
    /// SIMD width pinned to 1 (an FPU-less MCU has no float vector unit; the q15
    /// kernels are scalar anyway). Same `Numeric` trait as desktop — only the
    /// precision differs.
    pub const num = numeric.numericFor(.i16, .{ .width_override = 1 });

    pub const Source = io.I2sDmaSource(num, N);
    pub const Gain = filters.Gain(num);
    pub const Biquad = filters.Biquad(num);
    pub const Sink = io.I2sDmaSink(num, N);

    /// One block type per graph node, in node-id order (the `Executor` contract).
    pub const node_blocks = [_]type{ Source, Gain, Biquad, Sink };

    /// Build the chain on the low-level IR at comptime, block size pinned to N.
    pub fn chainGraph() graph.Graph {
        var g = graph.Graph.empty;
        g.block_size = N;
        const src = g.add(Source);
        const gain = g.add(Gain);
        const bq = g.add(Biquad);
        const sink = g.add(Sink);
        g.connect(port.MapOutPort(Source), src, 0, port.MapInPort(Gain), gain, 0);
        g.connect(port.MapOutPort(Gain), gain, 0, port.MapInPort(Biquad), bq, 0);
        g.connect(port.MapOutPort(Biquad), bq, 0, port.MapInPort(Sink), sink, 0);
        return g;
    }

    /// The committed comptime graph (a comptime `Graph` value).
    pub const graph_ir: graph.Graph = chainGraph();

    /// The fully-monomorphized Tier-A executor for the q15 chain: owns the colored
    /// `.bss` pool and the four block instances; `Exec.committed.footprint_bytes`
    /// is a comptime constant. The render path has no vtable.
    pub const Exec = engine.Executor(graph_ir, &node_blocks);

    /// The comptime-constant pool footprint for the q15 chain (the `.bss` budget).
    pub const footprint_bytes: usize = Exec.committed.footprint_bytes;
};

// Pull in every re-exported submodule's `test {}` blocks when this root is the
// test target. Referencing each `pub const` submodule forces its analysis.
test {
    std.testing.refAllDecls(@This());
}

test "embedded q15 chain commits at comptime: footprint is a comptime constant" {
    // Legal only because footprint_bytes is comptime-known — the same property the
    // freestanding `.bss` render buffer relies on.
    const proof: [embedded.footprint_bytes]u8 = undefined;
    comptime std.debug.assert(proof.len > 0);
    // One op per node: source → gain → biquad → sink = 4 ops.
    try std.testing.expectEqual(@as(usize, 4), embedded.Exec.committed.op_count);
    // The q15 lane is two bytes; the pool is sized in those, not f32's four.
    try std.testing.expect(embedded.footprint_bytes > 0);
    try std.testing.expectEqual(i16, embedded.num.Lane);
}

// =====================================================================
// The comptime-commit smoke gate (on the IR + the comptime commit pass).
//
// Build a tiny graph (source → gain → sink) and run the commit at comptime,
// then use the resulting `footprint_bytes` as an array length. Only a
// comptime-known value is legal as an array length, so the build compiling at
// all IS the discharge of the "the commit pass evaluates at comptime" promise
// for this graph — the same property the embedded profile relies on.
// =====================================================================

const SmokeSource = struct {
    const Self = @This();
    // A Source: zero sample inputs, so it may legally root a path (its output
    // length comes from the pull demand, not an input slice).
    pub fn process(self: *Self, out: []Sample(f32)) void {
        _ = self;
        _ = out;
    }
};

const SmokeGain = struct {
    const Self = @This();
    gain: f32 = 1.0,
    pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
        _ = self;
        @memcpy(out, in);
    }
};

const SmokeSink = struct {
    const Self = @This();
    // A sink: input only, no output port.
    pub fn process(self: *Self, in: []const Sample(f32)) void {
        _ = self;
        _ = in;
    }
};

/// The smoke graph, buildable at comptime on the IR: source → gain → sink.
pub fn smokeGraph() graph.Graph {
    var g = graph.Graph.empty;
    const src = g.add(SmokeSource);
    const gain = g.add(SmokeGain);
    const sink = g.add(SmokeSink);
    g.connect(port.MapOutPort(SmokeSource), src, 0, port.MapInPort(SmokeGain), gain, 0);
    g.connect(port.MapOutPort(SmokeGain), gain, 0, port.MapInPort(SmokeSink), sink, 0);
    return g;
}

test "comptime-commit smoke gate: footprint_bytes is a comptime constant > 0" {
    const g = comptime smokeGraph();
    const plan = comptime try commitComptime(g);

    // Legal only because footprint_bytes is comptime-known.
    const proof: [plan.footprint_bytes]u8 = undefined;
    comptime std.debug.assert(proof.len > 0);

    try std.testing.expect(plan.footprint_bytes > 0);
    // One op per node: source → gain → sink = 3 ops.
    try std.testing.expectEqual(@as(usize, 3), plan.op_count);
    // Two ping-pong pool buffers (M=2) over the default N=512: 2 · 512 · 4.
    try std.testing.expectEqual(@as(usize, 2 * 512 * @sizeOf(Sample(f32))), plan.footprint_bytes);
}

test "smoke gate: classifier + PortId minting on the stub blocks" {
    try std.testing.expect(classify(SmokeGain) == .Map);
    const InPort = port.MapInPort(SmokeGain);
    const OutPort = port.MapOutPort(SmokeGain);
    try std.testing.expect(InPort.Elem == Sample(f32));
    try std.testing.expect(OutPort.Elem == Sample(f32));
    try std.testing.expect(InPort.direction == .in);
    try std.testing.expect(OutPort.direction == .out);
}

test "DX surface: Concat named fan-in wires by name and commits" {
    const Collect = combinators.Concat(.{
        .mfcc = FeatureFrame(13),
        .centroid = Scalar(f32),
    });
    // Feature-producing sources (zero sample input → legal path heads), so the
    // fan-in graph is source-rooted and the real commit accepts it.
    const Mfcc = struct {
        const Self = @This();
        pub fn process(self: *Self, out: []FeatureFrame(13)) void {
            _ = self;
            _ = out;
        }
    };
    const Centroid = struct {
        const Self = @This();
        pub fn process(self: *Self, out: []Scalar(f32)) void {
            _ = self;
            _ = out;
        }
    };
    var g = Graph.init(std.testing.allocator, .{});
    defer g.deinit();
    const mfcc = try g.add(Mfcc, .{});
    const centroid = try g.add(Centroid, .{});
    const collect = try g.add(Collect, .{});
    try g.connect(mfcc, collect.in.mfcc); // wired BY NAME
    try g.connect(centroid, collect.in.centroid);
    var eng = try g.commit();
    defer eng.deinit();
    try std.testing.expectEqual(@as(usize, 3), eng.op_count); // one op per node
}
