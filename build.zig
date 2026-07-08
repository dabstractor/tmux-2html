const std = @import("std");
const version_string = @import("build.zig.zon").version;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const use_simd = b.option(bool, "simd", "Use SIMD-accelerated code paths (default: true)") orelse true;

    // parg — eager dependency (small pure-Zig parser).
    const parg = b.dependency("parg", .{});
    const parg_module = parg.module("parg");

    // build_options — bakes the version string into a module imported as @import("build_options").
    const options = b.addOptions();
    options.addOption([]const u8, "version", version_string);

    // Executable root module.
    const exe = b.addExecutable(.{
        .name = "tmux-2html",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = false,
            .imports = &.{
                .{ .name = "parg", .module = parg_module },
                .{ .name = "build_options", .module = options.createModule() },
            },
        }),
    });

    // ghostty — LAZY dependency; exposes the "ghostty-vt" module (HYPHEN).
    if (b.lazyDependency("ghostty", .{
        .target = target,
        .optimize = optimize,
        .@"version-string" = version_string,
        .simd = use_simd,
    })) |dep| {
        exe.root_module.addImport("ghostty-vt", dep.module("ghostty-vt"));
    }

    b.installArtifact(exe);

    // `zig build run`  (remember: --release=fast on the CLI; see Gotcha 1)
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    // `zig build test`
    const test_step = b.step("test", "Run unit tests");
    const tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);
}
