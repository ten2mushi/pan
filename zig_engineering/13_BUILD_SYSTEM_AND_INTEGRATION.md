# 13: Build System, Packaging, Testing, and Integration

## build.zig (88 lines)

The build function is `pub fn build(b: *std.Build) !void` (it can error because example
discovery does filesystem I/O). Verbatim key parts:

```zig
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create radio module
    const radio_module = b.addModule("radio", .{ .root_source_file = b.path("src/radio.zig") });

    // Discover examples
    const examples = try discoverExamples(b.allocator, b.path("examples").getPath(b));

    // Build examples
    const examples_step = b.step("examples", "Build examples");
    for (examples.items) |example| {
        const example_exe = b.addExecutable(.{
            .name = example.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(example.path),
                .target = target,
                .optimize = .ReleaseFast,
            }),
        });
        example_exe.root_module.addImport("radio", radio_module);
        example_exe.linkLibC();
        const install_example = b.addInstallArtifact(example_exe, .{});

        examples_step.dependOn(&install_example.step);
    }

    // Run unit tests
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/radio.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.linkLibC();
    const run_tests = b.addRunArtifact(tests);
    run_tests.has_side_effects = true;
    const test_step = b.step("test", "Run framework tests");
    test_step.dependOn(&run_tests.step);

    // Run benchmark suite
    const benchmark_suite = b.addExecutable(.{
        .name = "benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/benchmark.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    benchmark_suite.root_module.addImport("radio", radio_module);
    benchmark_suite.linkLibC();
    const run_benchmark_suite = b.addRunArtifact(benchmark_suite);
    if (b.args) |args| run_benchmark_suite.addArgs(args);
    const benchmark_step = b.step("benchmark", "Run benchmark suite");
    benchmark_step.dependOn(&run_benchmark_suite.step);

    // Generate test vectors
    const generate_cmd = b.addSystemCommand(&[_][]const u8{ "python3", "generate.py" });
    const generate_step = b.step("generate", "Generate test vectors");
    generate_step.dependOn(&generate_cmd.step);
}
```

Note the Zig 0.15-era module API: executables/tests are built from an explicit
`root_module` created with `b.createModule(.{ ... })` carrying `target` and `optimize`,
and imports are wired with `module.addImport(...)`. The `radio` module itself
(`b.addModule("radio", ...)`) is created with only a `root_source_file` — it inherits
target/optimize from each consumer.

**Notable choices:**
- The `radio` module's root source file is `src/radio.zig`.
- Examples are always built with `.ReleaseFast` (realistic perf for users trying them
  with real hardware) and installed as artifacts under the `examples` step.
- Tests use the user's chosen `optimize` (so you can debug test failures in Debug),
  and `run_tests.has_side_effects = true` forces the test runner to execute every
  build rather than being cached.
- The benchmark exe is built from `benchmarks/benchmark.zig`, always `.ReleaseFast`,
  imports the `radio` module, and forwards `b.args` to the benchmark binary (so
  `zig build benchmark -- <filter>` filters the suite).
- `linkLibC()` is applied to examples, tests, and the benchmark exe because dynamic
  library loading (`std.DynLib`) and the POSIX signal/sigwait path in `platform.zig`
  need libc.
- Example discovery is a small Zig helper, `discoverExamples`, that opens the
  `examples/` dir with `.{ .iterate = true }`, and for every `*.zig` file produces an
  `Example{ .name = "example-" ++ stem, .path = "examples/" ++ filename }`. It returns
  a `std.array_list.Managed(Example)`.

## Zig Package Usage (from README)

```zig
zig fetch --save git+https://github.com/vsergeev/zigradio#master
# in build.zig
const radio = b.dependency("radio", .{});
exe.root_module.addImport("radio", radio.module("radio"));
exe.linkLibC();
```

Then `const radio = @import("radio");`.

## build.zig.zon (the package manifest)

```zig
.{
    .name = .radio,
    .fingerprint = 0xe0461b0f84327ae8,
    .version = "0.10.0",
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
        "examples",
        "benchmarks",
        "LICENSE",
        "CHANGELOG.md",
        "README.md",
    },
}
```

Fields, as written:
- `.name = .radio` — an *enum literal*, not a string (the Zig 0.15 package-name form),
  which is why dependents refer to it as `b.dependency("radio", .{})`.
- `.fingerprint = 0xe0461b0f84327ae8` — the package fingerprint the package manager
  uses to detect identity/renames.
- `.version = "0.10.0"` — matches `radio.version` in `src/radio.zig`
  (`SemanticVersion{ .major = 0, .minor = 10, .patch = 0 }`).
- `.paths` — the files/directories included when the package is fetched: the two build
  files, `src`, `examples`, `benchmarks`, and the license/changelog/readme.

There is no `.dependencies` field: ZigRadio has zero Zig package dependencies (its
optional C libraries are loaded at runtime via `std.DynLib`, not declared here).

## Testing Story

- `zig build test` runs the `test` decl in radio.zig which does `std.testing.refAllDecls(@This())` + all the embedded tests in every core and block file.
- Many blocks have 10-30 individual test cases covering different types (f32 vs Complex), different parameterizations (N=64 vs 128), edge cases (single sample, EOS, wrap), and numerical vector matches.
- `zig build generate` must be run after changing DSP algorithm or adding new blocks that need vectors.

This setup makes the project very pleasant to hack on: change a filter, run generate + test, and you have immediate confidence (or a failing vector diff to debug).

## Recommended Optimization

The README is explicit: "Optimization `ReleaseFast` is recommended for real-time applications."

The framework itself has no "debug vs release" behavior differences in the data path (the debug flag on Flowgraph only affects the dump print), so users get the same semantics, just slower in Debug due to safety checks and less optimization.
