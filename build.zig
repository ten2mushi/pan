const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The public pan module (root: src/pan.zig).
    const pan_mod = b.addModule("pan", .{
        .root_source_file = b.path("src/pan.zig"),
        .target = target,
        .optimize = optimize,
    });

    // A library artifact so `zig build` has something to compile/install.
    const lib = b.addLibrary(.{
        .name = "pan",
        .root_module = pan_mod,
        .linkage = .static,
    });
    b.installArtifact(lib);

    // Unit tests over the pan root module (pulls in every module via
    // refAllDeclsRecursive in src/pan.zig, including the §8.5 smoke gate).
    const tests = b.addTest(.{ .root_module = pan_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests + the comptime-commit smoke gate");
    test_step.dependOn(&run_tests.step);
}
