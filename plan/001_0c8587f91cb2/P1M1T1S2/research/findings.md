# Research Findings — P1.M1.T1.S2 (build.zig wiring)

> All findings below were VERIFIED by building a faithful throwaway repo with the
> REAL Zig 0.15.2 toolchain (`/home/dustin/.local/opt/zig-x86_64-linux-0.15.2/zig`,
> `zig version` → `0.15.2`) against the cached ghostty v1.3.1 + parg deps from
> P1.M1.T1.S1. The full build graph (ghostty-vt module, C++ SIMD libs, linking)
> was exercised end-to-end. Throwaway repo: `/tmp/t2h-s2-verify`. None of this is
> from training-knowledge guessing.

## 1. The build.zig wiring is VERIFIED end-to-end (exit 0)

The candidate `build.zig` in the PRP was built and linked successfully. The exact
Zig 0.15.2 `root_module`/`createModule` API shape from
`architecture/external_deps.md §2` compiles and produces a working binary:

```
zig build --release=fast          # → exit 0, produces zig-out/bin/tmux-2html (2.4 MB ELF)
zig build run --release=fast -- --version   # → prints "tmux-2html 0.1.0"
zig build --release=fast -Dsimd=false       # → exit 0
zig build test --release=fast               # → exit 0
```

The build graph pulls in ghostty-vt's transitive artifacts (verified in the
linker command line):
`libsimdutf.a`, `libhighway.a`, `libutfcpp.a` (built from the C++ sources under
ghostty's `src/simd/`), plus `-lc++ -lc`, plus the transitive `uucode` Zig dep.

## 2. ghostty build options & module name — CONFIRMED by reading ghostty source

Read directly from the cached ghostty v1.3.1 sources (`~/.cache/zig/p/ghostty-...`):

- **`simd`** is `b.option(bool, "simd", ...)`, default `true`
  (`src/build/Config.zig:172`). → pass `.simd = use_simd` (a `bool`).
- **`version-string`** is `b.option([]const u8, "version-string", ...)`
  (`src/build/Config.zig:209`). → pass `.@"version-string" = version_string`.
- The module is registered under the name **`"ghostty-vt"`** (HYPHEN) in
  `src/build/GhosttyZig.zig:29` (`initVt("ghostty-vt", ...)`). → consume via
  `dep.module("ghostty-vt")` and `addImport("ghostty-vt", ...)`.

These match `external_deps.md §2` and `findings_and_corrections.md §0.1` exactly.
The `lazyDependency` + `addImport` pattern (not eager `b.dependency`) is required
so that `--fetch`/library builds don't unconditionally compile the giant ghostty
VT module.

## 3. Zig 0.15.2 std.Build API signatures — CONFIRMED by reading lib/std

- `b.addTest(.{ .root_module = <module> })` → `*Step.Compile`
  (`Build.zig:879`, `TestOptions` at `:856`). Per the doc comment, this does NOT
  run tests; pass its result to `b.addRunArtifact(tests)` to actually execute.
- `b.createModule(.{...})` → `*Module` (`Build.zig:916`) — for the executable's
  private root module (takes `.root_source_file`, `.target`, `.optimize`,
  `.link_libc`, `.imports`).
- `options.addOption([]const u8, "version", value)` (`Step/Options.zig:38`) +
  `options.createModule()` (`Step/Options.zig:426`) → put the returned module in
  `createModule`'s `.imports` array. This is the verified shape (NOT
  `root_module.addOptions("name", opts)` — that older form is superseded).
- `Module.CreateOptions.link_libc: ?bool` (`Build/Module.zig:234`) → set
  `.link_libc = false` inside the root module's `createModule` call.
- `b.lazyDependency("ghostty", .{...})` → `?*Dependency` (`Build.zig:1986`).

## 4. CRITICAL GOTCHA — Debug-mode linker bug REQUIRES `--release=fast`

**This is the single most important finding for the implementer.** A plain
`zig build` (default Debug) FAILS at link time:

```
error: fatal linker error: unhandled relocation type R_X86_64_PC64 at offset 0x1c
    note: in /usr/lib/gcc/x86_64-pc-linux-gnu/16.1.1/../../../../lib/crt1.o:.sframe
error: fatal linker error: unhandled relocation type R_X86_64_PC64 at offset 0x2c
    note: in /usr/lib/gcc/x86_64-pc-linux-gnu/16.1.1/../../../../lib/crt1.o:.sframe
```

Root cause: the bundled C++ SIMD static libs (simdutf/highway/utfcpp) + the
system `crt1.o` produce `.sframe` relocations (`R_X86_64_PC64`) that Zig's
Debug-mode linker cannot handle in this toolchain (gcc 16.1.1 / recent glibc).
This is the EXACT bug documented in `findings_and_corrections.md §4` and PRD §15.

**Fix (verified):** every build/run/test invocation MUST append `--release=fast`
(equivalently `-Doptimize=ReleaseFast`). ReleaseFast links cleanly. `standardOptimizeOption(.{})`
is kept (default Debug) to stay consistent with term2html and to honor CI's
`-Doptimize` flag; the release flag is supplied on the command line, NOT forced
in build.zig. (`preferred_optimize_mode` would not help: it makes `-Drelease`
*select* the preferred mode while leaving bare `zig build` at Debug — the inverse
of what we need.)

CONSEQUENCE for the contract: the literal "`zig build` produces zig-out/bin/tmux-2html"
is satisfied by `zig build --release=fast`. Plain `zig build` is known-broken in
this env and must not be used as a gate.

## 5. CRITICAL GOTCHA — `std.io.getStdOut()` is GONE in Zig 0.15.2

The 0.15 IO rewrite removed `std.io.getStdOut()` (and `getStdErr`/`getStdIn`).
Referencing it errors:
`error: root source file struct 'Io' has no member named 'getStdOut'`
(`std.io` is now an alias for `std.Io`, the new IO struct, which has no
getStdOut).

**Correct 0.15.2 stdout API (verified):**
- `std.fs.File.stdout()` → `*File` (returns a File handle) (`fs/File.zig:188`).
- `file.writeAll(bytes)` (`fs/File.zig:975`) — simplest, no buffering.
- For FORMATTED output: `std.fmt.bufPrint(&buf, "...{s}...", args)` → then
  `stdout.writeAll(out)`. (`fmt.bufPrint` at `fmt.zig:612`.)
- Buffered alternative: `var w = file.writer(&buf);` (`fs/File.zig:2120`, takes a
  caller-supplied buffer) → `w.print(...)` → `w.flush()`. More code; the
  `bufPrint`+`writeAll` path is simpler for a stub.

This affects S2's `main.zig` stub AND downstream tasks (T3.S1 real main.zig, all
`src/*.zig` that print). Capture in the PRP as a cross-cutting gotcha.

## 6. `link_libc = false` does NOT prevent libc linking (expected)

The contract specifies `.link_libc = false` on the executable root module. The
verified link line contains `-lc++ -lc` and the produced binary is dynamically
linked. Reason: `link_libc` on OUR root module is a hint about our own needs; the
ghostty-vt dependency's C++ SIMD artifacts declare a libc/libcpp requirement that
propagates up and is honored by the linker regardless. This is correct and
expected — keep `.link_libc = false` as specified (matches term2html). No action
needed; just don't be surprised that `-lc` still appears.

## 7. S2 must create a minimal `src/main.zig` (S1 only made an empty dir)

S1's deliverable left `src/` as an empty stub. For `zig build` to produce a
binary, `build.zig` points `.root_source_file = b.path("src/main.zig")`, so S2
MUST create a `src/main.zig` that compiles. The stub's job is to VALIDATE the
build graph (prove parg + build_options + ghostty-vt all resolve) and to satisfy
the `--version` contract output. It is NOT the real CLI — subcommand dispatch,
`--help`, and real flag parsing are **P1.M1.T3.S1**, which will REPLACE/expand
this stub.

The verified stub (uses the 0.15.2 stdout API, imports all three modules to force
analysis, handles `--version`, includes one `test` block so the test step is
non-vacuous) is in the PRP verbatim.

## 8. The test step — VERIFIED wiring

`zig build test --release=fast` exits 0. The verified pattern:
```zig
const test_step = b.step("test", "Run unit tests");
const tests = b.addTest(.{ .root_module = exe.root_module });
const run_tests = b.addRunArtifact(tests);
test_step.dependOn(&run_tests.step);
```
Testing `exe.root_module` (rooted at `src/main.zig`) picks up `test` blocks in
main.zig now; future tasks (P1.M4.T2 golden harness) will add more `addTest`
artifacts for dedicated test files and depend them on the same `test_step`.
`--release=fast` is required for the test step too (same Debug linker bug).

## 9. S1 handoff is COMPLETE and reusable as-is

The repo already contains S1's verified `build.zig.zon` + minimal `build.zig`
stub + `.paths` scaffolding. S2 OVERWRITES `build.zig` (replacing the stub) and
ADDS `src/main.zig`. `build.zig.zon` is NOT touched (manifest complete after S1).
The two deps are already in `~/.cache/zig/p/`, so S2's build is fast (no fetch).
