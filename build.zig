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
        "tests/dsp_spatial_test.zig",
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
    };
    for (harnesses) |path| {
        const h_mod = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "pan", .module = pan_mod }},
        });
        linkPlatformAudio(target, h_mod);
        const h_test = b.addTest(.{ .root_module = h_mod });
        test_step.dependOn(&b.addRunArtifact(h_test).step);
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
    const neg_step = b.step("neg-compile", "Assert the missing-Rate-declaration build error fires (P8 gate)");
    neg_step.dependOn(&neg.step);
    test_step.dependOn(&neg.step);

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
    const fmt = b.addFmt(.{ .paths = &.{ "src", "build.zig", "tests", "bench" }, .check = true });
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
