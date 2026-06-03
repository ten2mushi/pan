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
    };
    for (harnesses) |path| {
        const h_mod = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "pan", .module = pan_mod }},
        });
        const h_test = b.addTest(.{ .root_module = h_mod });
        test_step.dependOn(&b.addRunArtifact(h_test).step);
    }

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
    const fmt = b.addFmt(.{ .paths = &.{ "src", "build.zig", "tests" }, .check = true });
    const fmt_step = b.step("fmt-check", "Verify formatting (CI gate)");
    fmt_step.dependOn(&fmt.step);

    // ---- Bench placeholder (wired in a later phase) --------------------
    const bench_step = b.step("bench", "Run benchmarks (placeholder)");
    bench_step.dependOn(b.getInstallStep());
}
