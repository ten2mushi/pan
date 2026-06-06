const std = @import("std");
const numeric = @import("src/numeric.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Rule 12: surface the active-precision monomorph count at build time so
    // precision creep (each active precision is one extra monomorph per kernel)
    // is never silent.
    std.debug.print("pan build: {d} active precision monomorphs per kernel\n", .{numeric.monomorph_count});

    // ---- The public pan library (root: src/root.zig) -------------------
    const pan_mod = b.addModule("pan", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The I/O HAL's device backend is platform C interop: on macOS the CoreAudio
    // sink calls AudioToolbox; on Linux the ALSA sink calls libasound. Link the
    // platform's audio transport so any executable built from this module
    // resolves those `extern` symbols. (On Linux this links libasound, present on
    // a real Linux host; the x86_64-linux-gnu *cross-compile* gate builds the
    // static lib only — which does not link — so it needs no sysroot libasound.)
    linkPlatformAudio(target, pan_mod);

    const lib = b.addLibrary(.{
        .name = "pan",
        .root_module = pan_mod,
        .linkage = .static,
    });
    b.installArtifact(lib);

    // ---- The CLI executable (depends on the pan library) ---------------
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "pan", .module = pan_mod }},
    });
    linkPlatformAudio(target, exe_mod);
    const exe = b.addExecutable(.{ .name = "pan", .root_module = exe_mod });
    b.installArtifact(exe);

    // ---- Run step ------------------------------------------------------
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Build and run the pan CLI");
    run_step.dependOn(&run_cmd.step);

    // ---- Tests (library + CLI root modules; run in parallel) -----------
    const lib_tests = b.addTest(.{ .root_module = pan_mod });
    const exe_tests = b.addTest(.{ .root_module = exe_mod });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run unit tests + the comptime-commit smoke gate");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // Standalone test harnesses under tests/ (each imports the src files it
    // exercises by relative path). Added as they land; each runs in the suite.
    const harnesses = [_][]const u8{
        "tests/type_machinery_test.zig",
        "tests/port_machinery_test.zig",
        "tests/mux_machinery_test.zig",
        "tests/gold_vector_test.zig",
        "tests/dual_mux_test.zig",
        "tests/comparator_test.zig",
        "tests/bc_differential_test.zig",
        "tests/aliasing_test.zig",
        "tests/aliasing_message_test.zig",
        "tests/latency_contract_test.zig",
        "tests/state_granularity_test.zig",
        "tests/commit_plan_test.zig",
        "tests/commit_validation_test.zig",
        "tests/executor_test.zig",
        "tests/dsp_filters_test.zig",
        "tests/dsp_filters2_yoneda_test.zig",
        "tests/onepole_coeffs_yoneda_test.zig",
        "tests/dsp_spatial_test.zig",
        "tests/spatial_negotiation_yoneda_test.zig",
        "tests/mix_routing_yoneda_test.zig",
        "tests/layout_negotiation_test.zig",
        "tests/spatial_geometry_yoneda_test.zig",
        "tests/spectral_library_yoneda_test.zig",
        "tests/filterbank_yoneda_test.zig",
        "tests/io_codec_test.zig",
        "tests/bc_executor_test.zig",
        "tests/gold_fixedpoint_test.zig",
        "tests/planar_conformance_test.zig",
        "tests/control_plane_test.zig",
        "tests/runtime_engine_test.zig",
        "tests/delay_test.zig",
        "tests/fused_feedback_test.zig",
        "tests/persistent_feedback_test.zig",
        "tests/inplace_coalescing_test.zig",
        "tests/planar_delay_test.zig",
        "tests/fdn_reverb_test.zig",
        "tests/ladder_test.zig",
        "tests/schroeder_reverb_test.zig",
        "tests/paranoid_poison_test.zig",
        "tests/example_a_coloring_test.zig",
        "tests/spectral_test.zig",
        "tests/pdc_test.zig",
        "tests/spectral_yoneda_test.zig",
        "tests/pdc_yoneda_test.zig",
        "tests/spectral_gold_test.zig",
        "tests/analysis_root_test.zig",
        "tests/feat_yoneda_test.zig",
        "tests/analysis_yoneda_test.zig",
        "tests/analysis_buildout_test.zig",
        "tests/examples_analysis_smoke_test.zig",
        "tests/feat_spectral_shape_yoneda_test.zig",
        "tests/feat_chroma_contrast_yoneda_test.zig",
        "tests/feat_timedomain_yoneda_test.zig",
        "tests/embedded_chain_test.zig",
        "tests/biquad_fixedpoint_yoneda_test.zig",
        "tests/embedded_hal_yoneda_test.zig",
        "tests/modulation_test.zig",
        "tests/modulation_yoneda_test.zig",
        "tests/dynamics_yoneda_test.zig",
        "tests/fx_dynamics_yoneda_test.zig",
        "tests/modulation_gold_test.zig",
        "tests/adaptive_yoneda_test.zig",
        "tests/varirate_latency_test.zig",
        "tests/varispeed_yoneda_test.zig",
        "tests/asrc_yoneda_test.zig",
        "tests/varirate_gold_test.zig",
        "tests/sampleplayer_yoneda_test.zig",
        "tests/timestretch_yoneda_test.zig",
        "tests/pitchshift_yoneda_test.zig",
        "tests/instrument_engine_test.zig",
        "tests/generator_gold_vector_test.zig",
        "tests/polyvoice_behaviour_test.zig",
        "tests/channelmap_functoriality_test.zig",
        "tests/offline_yoneda_test.zig",
        "tests/ring_yoneda_test.zig",
        "tests/parallel_tier_b_test.zig",
        "tests/parallel_pure_yoneda_test.zig",
        "tests/parallel_concurrent_yoneda_test.zig",
        "tests/parallel_ratparam_yoneda_test.zig",
    };
    // The Tier-B suites (`parallel_*`) each spawn up to `ncores` workers that bounded-spin
    // on cross-worker ready-flags. Running several at once oversubscribes the cores, and
    // without a real render workgroup the descheduled workers thrash (the same pathology
    // the workgroup HAL exists to bound). So the parallel suites are CHAINED to run one at
    // a time — each gets the whole machine — while the single-threaded suites still run
    // concurrently. (The runtime also yields past a spin threshold as a backstop.)
    var prev_parallel: ?*std.Build.Step = null;
    for (harnesses) |path| {
        const h_mod = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "pan", .module = pan_mod }},
        });
        linkPlatformAudio(target, h_mod);
        const h_test = b.addTest(.{ .root_module = h_mod });
        const h_run = b.addRunArtifact(h_test);
        test_step.dependOn(&h_run.step);
        if (std.mem.startsWith(u8, std.fs.path.basename(path), "parallel_")) {
            if (prev_parallel) |pp| h_run.step.dependOn(pp);
            prev_parallel = &h_run.step;
        }
    }

    // ---- Negative-compile gate: the P8 "missing Rate declaration" build error
    // The gate criterion "a Rate missing a declaration is a build error" is enforced
    // by `port.classify`'s `@compileError`; this turns it from a by-inspection
    // disabled stub into an ACTIVE check by compiling a fixture that MUST fail and
    // asserting a non-zero `zig build-obj` exit. If the fixture ever compiles, the
    // gate regressed and this step fails (expected exit 1, got 0).
    const neg = b.addSystemCommand(&.{
        b.graph.zig_exe,      "build-obj", "-fno-emit-bin",
        "--dep",              "pan",       "-Mroot=tests/negative/missing_latency.zig",
        "-Mpan=src/root.zig",
    });
    neg.expectExitCode(1);
    neg.has_side_effects = true; // always re-run (it produces no cacheable output)
    const neg_step = b.step("neg-compile", "Assert the missing-Rate-declaration + Concat-type-mismatch build errors fire");
    neg_step.dependOn(&neg.step);
    test_step.dependOn(&neg.step);

    // The P9 companion: a wrong element type on a named `Concat` column is a
    // `@compileError` (the connect type-check, `src/graph.zig:340`). This fixture
    // wires a `Scalar(f32)` producer into a `FeatureFrame(13)` column and MUST fail
    // to compile — turning the "wrong element type = compile error" guarantee from
    // ⊢-by-inspection into an active must-fail build check.
    const neg_concat = b.addSystemCommand(&.{
        b.graph.zig_exe,      "build-obj", "-fno-emit-bin",
        "--dep",              "pan",       "-Mroot=tests/negative/concat_type_mismatch.zig",
        "-Mpan=src/root.zig",
    });
    neg_concat.expectExitCode(1);
    neg_concat.has_side_effects = true;
    neg_step.dependOn(&neg_concat.step);
    test_step.dependOn(&neg_concat.step);

    // The P14 companion (catalog §2.5 W1 / A18): asking the OfflineBatch chunker to
    // data-parallel partition a graph with a stateful block that declares no
    // `warmup_samples` is a `@compileError` ("presence gates chunkability"). This
    // fixture references `OfflineBatch.renderChunked` on such a graph and MUST fail
    // to compile — the active form of the no-warmup-stateful-chunk commit error.
    const neg_offline = b.addSystemCommand(&.{
        b.graph.zig_exe,      "build-obj", "-fno-emit-bin",
        "--dep",              "pan",       "-Mroot=tests/negative/offline_no_warmup.zig",
        "-Mpan=src/root.zig",
    });
    neg_offline.expectExitCode(1);
    neg_offline.has_side_effects = true;
    neg_step.dependOn(&neg_offline.step);
    test_step.dependOn(&neg_offline.step);

    // ---- Freestanding ReleaseSmall smoke object ------------------------
    // Proves the commit pass evaluates at comptime against a no-std target —
    // the embedded "same code, specialized" obligation in miniature. A
    // concrete MCU target is chosen in a later phase; freestanding native arch
    // exercises the comptime path without a sysroot.
    const free_target = b.resolveTargetQuery(.{ .os_tag = .freestanding });
    const smoke_mod = b.createModule(.{
        .root_source_file = b.path("src/smoke_freestanding.zig"),
        .target = free_target,
        .optimize = .ReleaseSmall,
    });
    const smoke_obj = b.addObject(.{ .name = "pan_smoke", .root_module = smoke_mod });
    const smoke_step = b.step("smoke", "Build the freestanding ReleaseSmall comptime-commit smoke object");
    smoke_step.dependOn(&smoke_obj.step);

    // ---- Documentation (autodoc) ---------------------------------------
    const docs = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Build API documentation");
    docs_step.dependOn(&docs.step);

    // ---- Formatting gate -----------------------------------------------
    const fmt = b.addFmt(.{ .paths = &.{ "src", "build.zig", "tests", "bench", "examples" }, .check = true });
    const fmt_step = b.step("fmt-check", "Verify formatting (CI gate)");
    fmt_step.dependOn(&fmt.step);

    // ---- Linux cross-compile gate (the ≥2-backend proof) ---------------
    // The brief mandates the I/O HAL run on macOS AND Linux (and embedded), with
    // Linux/embedded *testing* deferred but the platforms architecturally
    // accounted for. Building the pan static library for x86_64-linux-gnu proves
    // the ALSA backend compiles behind the same I/O-HAL seam as CoreAudio — a
    // single backend would leave the abstraction unexercised. A static lib does
    // not link, so this needs no sysroot libasound; the compile is the stand-in
    // for on-device Linux testing.
    const linux_target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu });
    const linux_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = linux_target,
        .optimize = optimize,
    });
    const linux_lib = b.addLibrary(.{ .name = "pan-linux", .root_module = linux_mod, .linkage = .static });
    const cross_step = b.step("cross-linux", "Cross-compile the pan lib for x86_64-linux-gnu (ALSA seam gate)");
    cross_step.dependOn(&linux_lib.step);

    // ---- Examples (Phase 17 — the brief's end-to-end demonstrators) ----
    // Each examples/*.zig is an executable importing pan. The Analyzer example
    // takes a decoded LPCM file and emits the feature matrix the Python renderer
    // draws. They are BUILT by the `examples` step (and installed so the Python
    // pipeline driver can invoke the binary); they are not auto-run here because
    // they take a file path argument.
    const examples_step = b.step("examples", "Build the Phase-17 example executables");
    const examples = [_][]const u8{
        "examples/animation/analyze.zig",
        "examples/spectrogram/spectrogram.zig",
        "examples/sonification/deep_space/deep_space.zig",
        "examples/extract_and_generate/ghost_autoencoder.zig",
    };
    for (examples) |path| {
        const ex_mod = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "pan", .module = pan_mod }},
        });
        linkPlatformAudio(target, ex_mod);
        const ex_exe = b.addExecutable(.{
            .name = b.fmt("example-{s}", .{std.fs.path.stem(path)}),
            .root_module = ex_mod,
        });
        const ex_install = b.addInstallArtifact(ex_exe, .{});
        examples_step.dependOn(&ex_install.step);
    }

    // ---- Benchmarks (measurement, not correctness) --------------------
    // Each bench/*.zig is a ReleaseFast executable importing pan. Benches MEASURE
    // (throughput, latency headroom, footprint, byte displacement); they never
    // assert an oracle match. Runs on demand, not as the per-commit gate.
    const bench_gate = b.option(bool, "bench-gate", "Fail hard on a footprint regression vs the committed baselines") orelse false;
    const bench_opts = b.addOptions();
    bench_opts.addOption(bool, "bench_gate", bench_gate);
    const bench_opts_mod = bench_opts.createModule();

    const bench_step = b.step("bench", "Build and run the benchmarks (ReleaseFast)");
    const benches = [_][]const u8{
        "bench/dsp_chain.zig",
        "bench/feedback_bench.zig",
        "bench/coloring_bench.zig",
        "bench/spectral_bench.zig",
        "bench/embedded_q15.zig",
        "bench/offline_bench.zig",
        "bench/biquad_cascade_bench.zig",
        "bench/parallel_bench.zig",
    };
    for (benches) |path| {
        const bench_mod = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "pan", .module = pan_mod },
                .{ .name = "build_options", .module = bench_opts_mod },
            },
        });
        linkPlatformAudio(target, bench_mod);
        const bench_exe = b.addExecutable(.{ .name = b.fmt("bench-{s}", .{std.fs.path.stem(path)}), .root_module = bench_mod });
        bench_step.dependOn(&b.addRunArtifact(bench_exe).step);
    }

    // macOS-only head-to-head against Apple vDSP (Accelerate) — a tracked,
    // regression-visible comparison of pan's biquad-cascade graph path vs a
    // top-tier hand-tuned DSP library on the same hardware. Gated to Darwin
    // because it links `-framework Accelerate` and calls `vDSP_biquad`.
    if (target.result.os.tag.isDarwin()) {
        const vdsp_mod = b.createModule(.{
            .root_source_file = b.path("bench/vdsp_compare_bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "pan", .module = pan_mod },
                .{ .name = "build_options", .module = bench_opts_mod },
            },
        });
        linkPlatformAudio(target, vdsp_mod); // libc + pan's CoreAudio externs
        vdsp_mod.linkFramework("Accelerate", .{});
        const vdsp_exe = b.addExecutable(.{ .name = "bench-vdsp-compare", .root_module = vdsp_mod });
        const vdsp_run = b.addRunArtifact(vdsp_exe);
        bench_step.dependOn(&vdsp_run.step);
        // A dedicated step to run ONLY the vDSP comparison (biquad + real-FFT), so it
        // can be measured without the full bench suite.
        const vdsp_step = b.step("bench-vdsp", "Run only the pan-vs-Apple-vDSP comparison bench (macOS)");
        vdsp_step.dependOn(&vdsp_run.step);
    }
}

/// Link the build target's audio transport so the I/O HAL's `extern` device-
/// backend symbols resolve in any executable built from `mod`. macOS → the
/// AudioToolbox / CoreAudio frameworks (the CoreAudio sink); Linux → libasound
/// (the ALSA sink). Other targets need nothing (the no-op backend has no
/// externs). Called for every module that becomes a runnable artifact.
fn linkPlatformAudio(target: std.Build.ResolvedTarget, mod: *std.Build.Module) void {
    const os = target.result.os.tag;
    if (os.isDarwin()) {
        mod.link_libc = true;
        mod.linkFramework("AudioToolbox", .{});
        mod.linkFramework("CoreAudio", .{});
        mod.linkFramework("CoreFoundation", .{});
    } else if (os == .linux) {
        mod.link_libc = true;
        mod.linkSystemLibrary("asound", .{});
    }
}
