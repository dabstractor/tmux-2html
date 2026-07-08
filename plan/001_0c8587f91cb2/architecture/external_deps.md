# External Dependencies & Build Configuration (VERIFIED)

> Verified by reading `aarol/term2html`'s `build.zig`, `build.zig.zon`, and
> `.github/workflows/build-binaries.yml` (fetched 2026-07-08). These are exact, copy-able.

## 1. `build.zig.zon` — exact dependencies

tmux-2html's `build.zig.zon` should mirror term2html's, with `.name = .tmux-2html` (note:
`.name` uses a `.identifier` in 0.15, but hyphens are allowed via `.@"tmux-2html"`? —
**VERIFY:** term2html uses `.name = .term2html` (no hyphen). For tmux-2html, prefer
`.name = .tmux_2html` or `.@"tmux-2html"`; the executable NAME is separately set in
`addExecutable(.{ .name = "tmux-2html" })` which can contain a hyphen. See gap note.)

```zig
.{
    .name = .tmux_2html,                      // VERIFY exact identifier form; safe = no hyphen
    .version = "0.1.0",
    .minimum_zig_version = "0.15.2",
    .fingerprint = <REGENERATE>,              // delete field, run zig build to regenerate
    .dependencies = .{
        .ghostty = .{
            .url = "https://github.com/ghostty-org/ghostty/archive/refs/tags/v1.3.1.tar.gz",
            .hash = "ghostty-1.3.1-5UdBCwYm-gQeBa4bu1-sMooCQS4KVriv5wWSIJ_sI-Cb",
        },
        .parg = .{
            .url = "git+https://github.com/judofhr/parg.git#b9ce29e3dcbf9845dac8ee4b33a31bb1bff29f80",
            .hash = "parg-0.0.0-dOPWZNhYAABEHE6EGXmwIucnu9vj-emodT9vmHeYynAP",
        },
    },
    .paths = .{ "build.zig", "build.zig.zon", "src", "scripts", "tmux-2html.tmux", "LICENSE", "licenses", "testdata" },
}
```

## 2. `build.zig` — exact wiring (verified from term2html)

Key patterns (Zig 0.15.2 API):
```zig
const std = @import("std");
const version_string = @import("build.zig.zon").version;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const use_simd = b.option(bool, "simd", "use simd (default: true)") orelse true;

    // parg
    const parg = b.dependency("parg", .{});
    const parg_module = parg.module("parg");

    // build_options (version, baked in)
    const options = b.addOptions();
    options.addOption([]const u8, "version", version_string);

    const exe = b.addExecutable(.{
        .name = "tmux-2html",                 // <-- binary name (hyphen OK here)
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "parg",        .module = parg_module },
                .{ .name = "build_options", .module = options.createModule() },
            },
            .link_libc = false,
        }),
    });

    // ghostty — LAZY dependency, imports module "ghostty-vt"
    if (b.lazyDependency("ghostty", .{
        .target = target,
        .optimize = optimize,
        .@"version-string" = version_string,
        .simd = use_simd,
    })) |dep| {
        exe.root_module.addImport("ghostty-vt", dep.module("ghostty-vt"));
    }

    b.installArtifact(exe);

    // `zig build run`
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // `zig build test`
    const test_step = b.step("test", "Run unit tests");
    const tests = b.addTest(.{ .root_module = ... }); // per-module test steps
    // ... (see term2html build.zig for the full test wiring)
}
```
**Important:** `addOptions()` + `options.addOption(...)` + `options.createModule()` bakes
`version` into a `build_options` module imported as `@import("build_options")`.

## 3. GitHub Actions release matrix (verified from term2html build-binaries.yml)

```yaml
on:
  push:
    tags: ["v*"]
permissions:
  contents: write
jobs:
  build:
    strategy:
      fail-fast: false
      matrix:
        include:
          - { os: ubuntu-latest, target: x86_64-linux-gnu,  name: tmux-2html-linux-x86_64,  flags: "" }
          - { os: ubuntu-latest, target: aarch64-linux-gnu, name: tmux-2html-linux-aarch64, flags: "-Dsimd=false" }
          - { os: macos-latest,  target: x86_64-macos,      name: tmux-2html-macos-x86_64,  flags: "-Dsimd=false" }
          - { os: macos-latest,  target: aarch64-macos,     name: tmux-2html-macos-arm64,   flags: "" }
    steps:
      - uses: actions/checkout@v4
      - uses: mlugg/setup-zig@v2
        with: { version: 0.15.2 }
      - run: zig build --fetch
      - run: zig build -Doptimize=ReleaseFast -Dtarget=${{ matrix.target }} ${{ matrix.flags }}
        env: { ZIG_HTTP_MAX_CONNS: "1" }
      - run: |   # tmux-2html ADDS sha256sums + tar.xz (term2html used tar.gz only)
          mkdir -p dist && cp zig-out/bin/tmux-2html dist/
          (cd dist && sha256sum tmux-2html > ../SHA256SUMS.txt)
          tar -C dist -cJf ${{ matrix.name }}.tar.xz tmux-2html
      - uses: actions/upload-artifact@v4
  release_draft:
    needs: build
    if: startsWith(github.ref, 'refs/tags/')
    runs-on: ubuntu-latest
    steps:
      - uses: actions/download-artifact@v4
        with: { path: dist }
      - uses: softprops/action-gh-release@v2
        with: { draft: true, files: "dist/**/*.tar.xz\ndist/**/SHA256SUMS.txt" }
```
**Differences from term2html (PRD-driven):** (a) `tar.xz` not `tar.gz`; (b) generate
`SHA256SUMS.txt`; (c) verify checksum in `scripts/download.sh`; (d) platform triples named
`linux-x86_64` etc per PRD §10. Native runners preferred for arm64; cross where unavailable
(term2html cross-compiles aarch64-linux on ubuntu + `-Dsimd=false`).

## 4. parg — CLI parsing API (verified from term2html main.zig)

`parg` (github.com/judofr/parg) exposes:
```zig
const parg = @import("parg");
var arg_parser = parg.parse(args, .{});          // args = std.process.args()
_ = arg_parser.nextValue();                       // skip program name
while (arg_parser.next()) |token| {
    switch (token) {
        .flag => |flag| {
            if (flag.isLong("font")) {
                const val = arg_parser.nextValue() orelse { /* error: missing value */ };
            } else if (flag.isLong("version")) { ... }
        },
        .arg => |a| { ... },                      // positional
        .unexpected_value => |u| { ... },
    }
}
```
- `flag.isLong("name")` / `flag.isShort('x')` (short flags); `flag.name` for unknown.
- `nextValue()` consumes the value of a flag that takes one.
- **No built-in subcommand dispatch** — parg is flag/positional oriented. For subcommands
  (`render | pane | region | sync-palette`), tmux-2html must read the first positional
  (`.arg` token) BEFORE the flag loop, then dispatch. **Action:** wrap parg in `cli.zig`
  that peeks the first positional for the subcommand and parses the rest. See system_context.md.

## 5. Gaps to verify at impl time

1. Exact `build.zig.zon` `.name`/`.fingerprint` for a hyphenated package; regenerate fingerprint.
2. Full `zig build test` wiring (term2html's build.zig was truncated — fetch the test step).
3. `getPin`/coordinate→Pin API on `PageList`/`Screen` (see render_pipeline.md §4).
