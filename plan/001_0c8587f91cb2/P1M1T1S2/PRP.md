# PRP — P1.M1.T1.S2: `build.zig` wiring (ghostty-vt module, version, -Dsimd, test step)

## Goal

**Feature Goal**: Replace S1's minimal `build.zig` stub with the full Zig 0.15.2
build graph that wires the lazy `ghostty` dependency's `ghostty-vt` module, bakes
the version string into a `build_options` module, exposes a `-Dsimd` option, and
defines `run` + `test` steps — so `zig build` produces the `tmux-2html` binary.

**Deliverable**: Two files at the repo root (`/home/dustin/projects/tmux-2html/`):
1. `build.zig` — the full wiring (overwrites S1's stub). **Does NOT touch
   `build.zig.zon`** (the manifest is complete after S1).
2. `src/main.zig` — a minimal build-graph-validation stub (S1 left `src/` empty;
   `build.zig` references `src/main.zig` as the root source file, so a compiling
   entry point must exist). The stub imports `parg` + `build_options` +
   `ghostty-vt`, handles `--version`, and is explicitly a placeholder for the
   real CLI (P1.M1.T3.S1).

**Success Definition** (all VERIFIED working with the real toolchain):
- `zig build --fetch` exits 0.
- `zig build --release=fast` exits 0 and produces `zig-out/bin/tmux-2html`.
- `zig build run --release=fast -- --version` prints `tmux-2html 0.1.0`.
- `zig build --release=fast -Dsimd=false` exits 0 (SIMD disabled path links).
- `zig build test --release=fast` exits 0.

> NOTE on `--release=fast`: see Gotcha 1 — bare `zig build` (Debug) hits a fatal
> linker bug in this environment, so EVERY build/run/test invocation must append
> `--release=fast`. This is mandatory, verified, and documented below.

## User Persona

**Target User**: Build/release engineer and downstream Zig developers (the
implementers of P1.M1.T3+ through P4).

**Use Case**: `zig build --release=fast` compiles the binary; `zig build test
--release=fast` runs unit tests; CI passes `-Doptimize=ReleaseFast -Dtarget=...`
plus `-Dsimd=false` on cross targets.

**Pain Points Addressed**: Establishes the module graph (`parg`, `build_options`,
`ghostty-vt`) that every downstream `src/*.zig` imports against, and the `test`
step the golden harness (P1.M4.T2) will extend.

## Why

- **Unblocks the entire src/ tree.** Until the module imports (`@import("parg")`,
  `@import("build_options")`, `@import("ghostty-vt")`) resolve at build time, no
  renderer/CLI/TUI code can compile. This task makes those imports real.
- **Locks the verified Zig 0.15.2 build shape.** The `root_module`/`createModule`
  API + `lazyDependency` + `addImport("ghostty-vt", ...)` pattern is taken
  verbatim from `aarol/term2html` (external_deps.md §2) and was built end-to-end
  here to confirm it links the C++ SIMD deps.
- **Bakes the version.** `addOptions()` + `createModule()` surfaces
  `build_options.version` to source, satisfying the PRD §11 "version baked in via
  build_options and surfaced by --version" requirement.
- **Defines the test step** that P1.M4.T2 (golden/unit harness) and CI will grow.

## What

A Zig 0.15.2 `build.zig` at the repo root that:
1. Reads `version_string` from `@import("build.zig.zon").version`.
2. Exposes standard target/optimize options and a `-Dsimd` bool option (default `true`).
3. Declares `parg` (eager) and a `build_options` module (version baked in) and
   imports both into the executable root module.
4. Lazily wires `ghostty` (passing `.target`, `.optimize`, `.@"version-string"`,
   `.simd`) and imports its `ghostty-vt` module under the name `ghostty-vt` (HYPHEN).
5. `addExecutable(.{ .name = "tmux-2html", .root_module = ... })` with
   `.root_source_file = b.path("src/main.zig")`, `.link_libc = false`.
6. `b.installArtifact(exe)`, a `run` step, and a `test` step.

Plus a minimal `src/main.zig` stub that imports all three modules (forcing the
graph to resolve), prints the version on `--version`, and contains one `test`
block so the test step is non-vacuous.

### Success Criteria

- [ ] `build.zig` exists at repo root with the exact verified content below.
- [ ] `src/main.zig` exists (minimal stub) with the exact verified content below.
- [ ] `build.zig.zon` UNCHANGED from S1 (not modified by this task).
- [ ] `zig build --fetch` exits 0.
- [ ] `zig build --release=fast` exits 0; `zig-out/bin/tmux-2html` produced.
- [ ] `zig build run --release=fast -- --version` prints `tmux-2html 0.1.0`.
- [ ] `zig build --release=fast -Dsimd=false` exits 0.
- [ ] `zig build test --release=fast` exits 0.

## All Needed Context

### Context Completeness Check

_Pass: "If someone knew nothing about this codebase, would they have everything
needed to implement this successfully?"_ — Yes. Both deliverable files are
specified verbatim (and were built/linked against the real toolchain to confirm
they exit 0). Every gotcha — the Debug linker bug, the removed stdout API, the
ghostty option types/module name, the `link_libc` semantics — is documented with
the exact error text and verified fix. No guessing required.

### Documentation & References

```yaml
# MUST READ — the authoritative verified build.zig shape (from term2html)
- file: plan/001_0c8587f91cb2/architecture/external_deps.md
  section: "§2 build.zig — exact wiring"
  why: "Source of the root_module/createModule/lazyDependency pattern copied below."
  critical: "Use options.createModule() inside the .imports array (NOT root_module.addOptions)."

# MUST READ — the ghostty-vt hyphen + Zig 0.15.2 facts
- file: plan/001_0c8587f91cb2/architecture/findings_and_corrections.md
  section: "§0.1 (import name) and §4 (Debug linker bug, ReleaseFast requirement)"
  why: "Confirms @import(\"ghostty-vt\") HYPHEN; confirms Debug R_X86_64_PC64 bug → --release=fast."

# MUST READ — companion empirical verification (this PRP's evidence base)
- file: plan/001_0c8587f91cb2/P1M1T1S2/research/findings.md
  why: "Records the end-to-end build (exit 0), ghostty option types read from source, the two 0.15.2 gotchas, and verified validation commands."
  critical: "§4 (ReleaseFast mandatory) and §5 (stdout API change) are the failure modes an implementer will hit first."

# INPUT CONTRACT — what S1 produces and S2 consumes (do NOT duplicate)
- file: plan/001_0c8587f91cb2/P1M1T1S1/PRP.md
  why: "S1 ships build.zig.zon (manifest, complete) + a minimal build.zig stub + empty src/ scaffolding. S2 OVERWRITES the build.zig stub and ADDS src/main.zig."
  pattern: "S2 treats build.zig.zon as READ-ONLY (manifest finalized in S1)."

# Zig 0.15.2 std source (authoritative for API signatures)
- file: /home/dustin/.local/opt/zig-x86_64-linux-0.15.2/lib/std/Build.zig
  why: "Confirm: addTest(.{.root_module}) (:879), createModule (:916), lazyDependency (:1986), standardOptimizeOption (:1319)."
- file: /home/dustin/.local/opt/zig-x86_64-linux-0.15.2/lib/std/fs/File.zig
  why: "Confirm: stdout() (:188), writeAll() (:975) — the 0.15.2 stdout API (getStdOut is GONE)."
```

### Current Codebase tree (post-S1, S2's starting point)

```bash
# Verified on disk: S1 is complete.
tmux-2html/
├── build.zig              # S1's MINIMAL STUB (pub fn build(b){ _ = b; })  ← S2 OVERWRITES THIS
├── build.zig.zon          # S1's manifest (FINAL — S2 does NOT touch)
├── src/                   # EMPTY dir (S1 stub)  ← S2 ADDS src/main.zig
├── scripts/  licenses/  testdata/   # empty dir stubs (S1)
├── tmux-2html.tmux  LICENSE         # empty file stubs (S1)
├── PRD.md  .gitignore  plan/
└── ~/.cache/zig/p/ holds ghostty-1.3.1-... + parg-0.0.0-...  (already fetched by S1)
```

### Desired Codebase tree with files to be added/changed

```bash
tmux-2html/
├── build.zig              # (S2) OVERWRITTEN — full wiring (verbatim content below)
├── src/
│   └── main.zig           # (S2) ADDED — minimal build-graph-validation stub (verbatim below)
├── build.zig.zon          # UNCHANGED (S1)
└── ... (all other stubs unchanged)
```

### Known Gotchas of our codebase & Library Quirks

```zig
// GOTCHA 1 — CRITICAL: bare `zig build` (Debug) FAILS TO LINK. Always use --release=fast.
//   Error at link: "fatal linker error: unhandled relocation type R_X86_64_PC64
//   at offset 0x1c / note: in .../crt1.o:.sframe".
//   Cause: ghostty-vt's bundled C++ SIMD static libs (simdutf/highway/utfcpp) +
//   system crt1.o produce .sframe relocations Zig's Debug linker can't handle
//   (gcc 16.1.1 / recent glibc). Documented in findings_and_corrections.md §4 + PRD §15.
//   FIX (verified): append `--release=fast` (or -Doptimize=ReleaseFast) to EVERY
//   build/run/test command. Do NOT try to "fix" the linker error in build.zig;
//   standardOptimizeOption(.{}) is intentionally kept (default Debug) to match
//   term2html and honor CI's -Doptimize. The release flag is supplied on the CLI.
//   CONSEQUENCE: the contract's literal "zig build produces zig-out/bin/tmux-2html"
//   is satisfied by `zig build --release=fast`.

// GOTCHA 2 — CRITICAL: std.io.getStdOut() is GONE in Zig 0.15.2.
//   Error: "root source file struct 'Io' has no member named 'getStdOut'".
//   0.15 rewrote IO: std.io is now std.Io (no getStdOut/getStdErr/getStdIn).
//   CORRECT stdout API (verified): std.fs.File.stdout() -> *File (fs/File.zig:188),
//   then file.writeAll(bytes) (:975). For FORMATTED output use
//   std.fmt.bufPrint(&buf, "...{s}...", args) then stdout.writeAll(out).
//   Affects S2's main.zig stub AND every downstream src/*.zig that prints (T3.S1+).

// GOTCHA 3 — ghostty is a LAZY dependency. Use b.lazyDependency("ghostty", .{...}),
//   NOT b.dependency. The .{...} MUST include exactly:
//     .target = target, .optimize = optimize,
//     .@"version-string" = version_string,   // []const u8, quoted because of the hyphen
//     .simd = use_simd,                      // bool
//   These option names are CONFIRMED in ghostty's src/build/Config.zig
//   ("simd" :174, "version-string" :210). Then consume the module via
//   dep.module("ghostty-vt") and addImport("ghostty-vt", ...) — HYPHEN, not underscore.

// GOTCHA 4 — build_options goes via options.createModule() in the .imports array,
//   NOT via root_module.addOptions("name", opts). The verified shape:
//     const options = b.addOptions();
//     options.addOption([]const u8, "version", version_string);
//     ... .imports = &.{ .{ .name = "build_options", .module = options.createModule() } } ...
//   Source then reads it as @import("build_options").version.

// GOTCHA 5 — .link_libc = false does NOT prevent libc linking, and that's FINE.
//   The verified link line shows -lc++ -lc and a dynamically-linked binary.
//   Reason: link_libc on OUR root module is a hint about our own needs; ghostty-vt's
//   C++ SIMD artifacts declare a libc/libcpp requirement that propagates up and is
//   honored regardless. Keep .link_libc = false as the contract specifies (matches
//   term2html). Do NOT "fix" the appearance of -lc.

// GOTCHA 6 — the test step needs --release=fast too (same Debug linker bug).
//   b.addTest(.{.root_module}) creates the test exe; b.addRunArtifact(tests) runs it.
//   Testing exe.root_module (rooted at src/main.zig) picks up test blocks in main.zig
//   now; P1.M4.T2 will add more addTest artifacts for dedicated test files.
```

## Implementation Blueprint

### Data models and structure

Not applicable — this task produces build-system declarations and a stub
entrypoint, no domain data models.

### The exact deliverable 1: `build.zig` (OVERWRITE S1's stub; verbatim, exit-0 tested)

Create this file verbatim at the repo root (`/home/dustin/projects/tmux-2html/build.zig`).
It was built and linked successfully against Zig 0.15.2 + cached ghostty/parg.

```zig
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
```

### The exact deliverable 2: `src/main.zig` (ADD; minimal build-graph stub)

Create this file verbatim at `/home/dustin/projects/tmux-2html/src/main.zig`. It
imports all three modules (forcing the graph to resolve), prints the version on
`--version` using the 0.15.2 stdout API, and has one `test` block.

```zig
const std = @import("std");
const build_options = @import("build_options");
const parg = @import("parg");
const ghostty_vt = @import("ghostty-vt");

// S2 build-graph validation stub. Real CLI dispatch (--help, subcommands,
// flag parsing) is P1.M1.T3.S1, which will REPLACE/expand this file.
pub fn main() !void {
    // Force every imported module to be analyzed — proves the build wiring resolves.
    _ = parg;
    _ = ghostty_vt.Terminal;

    const gpa = std.heap.page_allocator;
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    const stdout = std.fs.File.stdout();
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--version")) {
            var buf: [64]u8 = undefined;
            const out = try std.fmt.bufPrint(&buf, "tmux-2html {s}\n", .{build_options.version});
            try stdout.writeAll(out);
            return;
        }
    }
    try stdout.writeAll("tmux-2html (build-graph stub; full CLI is P1.M1.T3.S1)\n");
}

test "smoke: build_options version is non-empty" {
    try std.testing.expect(build_options.version.len > 0);
}
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: OVERWRITE build.zig  (THE primary deliverable)
  - FILE: build.zig  (overwrite S1's stub with the verbatim content above)
  - KEEP EXACT: the lazyDependency("ghostty", .{...}) block with all four options;
                options.createModule() in the .imports array; addImport("ghostty-vt", ...);
                .link_libc = false; the run + test steps.
  - DO NOT modify build.zig.zon (manifest is final from S1).
  - WHY FIRST: nothing else validates until the build graph parses + links.

Task 2: CREATE src/main.zig  (required so build.zig's root_source_file resolves)
  - FILE: src/main.zig  (verbatim content above)
  - NAMING/PLACEMENT: src/main.zig exactly (matches b.path("src/main.zig")).
  - SCOPE NOTE: This is a STUB. Do NOT implement subcommand dispatch / --help /
    parg flag-parsing here — that is P1.M1.T3.S1. Only --version + the import
    force-references + one smoke test, so the graph validates.

Task 3: VALIDATE  (see Validation Loop — all commands verified working)
  - RUN: zig build --fetch                         # expect exit 0
  - RUN: zig build --release=fast                  # expect exit 0 + zig-out/bin/tmux-2html
  - RUN: zig build run --release=fast -- --version # expect: tmux-2html 0.1.0
  - RUN: zig build --release=fast -Dsimd=false     # expect exit 0
  - RUN: zig build test --release=fast             # expect exit 0
```

### Implementation Patterns & Key Details

```zig
// PATTERN: lazy ghostty dep + addImport (the only correct way to consume ghostty-vt).
//   Eager b.dependency("ghostty", .{...}) would force-compile the full VT module
//   even for --fetch/library builds. lazyDependency returns null unless the module
//   is actually needed by a built artifact.
if (b.lazyDependency("ghostty", .{ .target = target, .optimize = optimize,
        .@"version-string" = version_string, .simd = use_simd })) |dep| {
    exe.root_module.addImport("ghostty-vt", dep.module("ghostty-vt"));  // HYPHEN
}

// PATTERN: version baking via addOptions + createModule (in the imports array).
const options = b.addOptions();
options.addOption([]const u8, "version", version_string);
// ... inside b.createModule(.{ .imports = &.{
//       .{ .name = "build_options", .module = options.createModule() } } })

// PATTERN: test step (addTest returns a *Step.Compile that must be RUN via addRunArtifact).
const tests = b.addTest(.{ .root_module = exe.root_module });
const run_tests = b.addRunArtifact(tests);
test_step.dependOn(&run_tests.step);

// PATTERN: 0.15.2 stdout (getStdOut is GONE).
const stdout = std.fs.File.stdout();
var buf: [64]u8 = undefined;
const out = try std.fmt.bufPrint(&buf, "tmux-2html {s}\n", .{build_options.version});
try stdout.writeAll(out);
```

### Integration Points

```yaml
BUILD GRAPH:
  - consumes (from S1): build.zig.zon (manifest, FINAL) + cached ghostty/parg deps + empty src/
  - produces (this task): full build.zig + src/main.zig stub
  - next (T3.S1): replaces src/main.zig stub with real subcommand dispatch + --help,
                   reusing @import("build_options").version and the 0.15.2 stdout API.
  - next (P1.M4.T2): extends the test step with more addTest artifacts for golden/unit tests.
  - next (P4.M1 CI): calls `zig build -Doptimize=ReleaseFast -Dtarget=... [-Dsimd=false]`.

CONFIG:
  - version source: @import("build.zig.zon").version = "0.1.0" (baked, not hardcoded in build.zig).
  - no env vars, no settings files.

ROUTES / DATABASE:
  - none.
```

## Validation Loop

> **ALL commands below were executed successfully** against the real Zig 0.15.2
> toolchain with the cached ghostty/parg deps. Re-run them verbatim. Every
> build/run/test command MUST include `--release=fast` (Gotcha 1 — bare Debug
> builds hit the `R_X86_64_PC64` linker bug).

### Level 1: Syntax & Style (Immediate Feedback)

```bash
zig version            # MUST print: 0.15.2

# Zig 0.15.2 has no separate lint/format step for build.zig; the build runner is the checker.
# A typo in build.zig (e.g. wrong option name) surfaces here as a compile error.
zig build --fetch      # expect: exit 0 (deps already cached from S1; instant)
```

### Level 2: Build the binary (Component Validation — PRIMARY gate)

```bash
zig build --release=fast          # expect: exit 0
ls -la zig-out/bin/tmux-2html     # expect: the ELF binary exists (~2.4 MB)
file zig-out/bin/tmux-2html       # expect: "ELF 64-bit LSB executable, x86-64, ... dynamically linked"

# Expected: zero errors. If you see "fatal linker error: unhandled relocation type
# R_X86_64_PC64", you forgot --release=fast (Gotcha 1). If you see "has no member
# named 'getStdOut'", main.zig used the old IO API (Gotcha 2).
```

### Level 3: Run + version + simd + test (System Validation)

```bash
# Version (contract output #2)
zig build run --release=fast -- --version
# Expected stdout EXACTLY:  tmux-2html 0.1.0

# SIMD-disabled path links (contract output #3)
zig build --release=fast -Dsimd=false
# Expected: exit 0 (rebuilds ghostty-vt without the SIMD code paths)

# Test step (contract output #4)
zig build test --release=fast
# Expected: exit 0 (runs the smoke test in src/main.zig; no failures)
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Confirm -Dsimd actually flips the ghostty option (sanity that the wiring is live,
# not a no-op). Compare build invocations' resolved optimize/simd via the build summary:
zig build --release=fast -Dsimd=false --summary all 2>&1 | grep -i simd || true
zig build --release=fast          -Dsimd=true  --summary all 2>&1 | grep -i simd || true
# (Both exit 0; the dep is re-resolved per flag value. A hard error on -Dsimd=false
#  would indicate the option isn't reaching ghostty — but it is, per the verified build.)

# Confirm build.zig.zon was NOT modified by this task:
git diff --stat build.zig.zon    # Expected: no output (unchanged) if S1 committed it
git diff --stat build.zig src/   # Expected: build.zig modified, src/main.zig added
```

## Final Validation Checklist

### Technical Validation

- [ ] `zig version` prints `0.15.2`.
- [ ] `zig build --fetch` exits 0.
- [ ] `zig build --release=fast` exits 0; `zig-out/bin/tmux-2html` produced.
- [ ] `zig build run --release=fast -- --version` prints `tmux-2html 0.1.0`.
- [ ] `zig build --release=fast -Dsimd=false` exits 0.
- [ ] `zig build test --release=fast` exits 0.

### Feature Validation

- [ ] `build.zig` matches the verbatim Blueprint (lazy ghostty dep with all 4
      options, `addImport("ghostty-vt", ...)`, `build_options` via
      `options.createModule()`, `.link_libc = false`, `run` + `test` steps).
- [ ] `src/main.zig` stub present; imports `parg`/`build_options`/`ghostty-vt`;
      prints version on `--version`; has one `test` block.
- [ ] `build.zig.zon` unchanged from S1 (this task does not modify the manifest).
- [ ] All success criteria from "What" section met.

### Code Quality Validation

- [ ] No out-of-scope work (no subcommand dispatch, no `--help`, no real flag
      parsing — those are P1.M1.T3.S1; the stub is clearly marked as such).
- [ ] `main.zig` uses the 0.15.2 stdout API (`std.fs.File.stdout()`), not the
      removed `std.io.getStdOut()`.
- [ ] The `-Dsimd` option default is `true` and threads into `lazyDependency`.

### Documentation & Deployment

- [ ] No new env vars or config.
- [ ] `build.zig` is self-documenting (comments mark the lazy dep + import names).

---

## Anti-Patterns to Avoid

- ❌ Don't run `zig build` / `zig build run` / `zig build test` WITHOUT
  `--release=fast` — Debug linking hits the `R_X86_64_PC64` fatal error (Gotcha 1,
  verified). The contract's bare "`zig build`" is satisfied by `zig build --release=fast`.
- ❌ Don't use `std.io.getStdOut()` — it's removed in 0.15.2 (Gotcha 2). Use
  `std.fs.File.stdout()` + `writeAll` / `std.fmt.bufPrint`.
- ❌ Don't use eager `b.dependency("ghostty", .{...})` — use `b.lazyDependency`.
- ❌ Don't typo the import/module name as `ghostty_vt` (underscore) — it is
  `ghostty-vt` (HYPHEN) in both `addImport` and `dep.module`.
- ❌ Don't omit any of the four ghostty options (`.target`, `.optimize`,
  `.@"version-string"`, `.simd`) — they are all real options in ghostty's
  `Config.zig`; missing one errors or silently mis-resolves.
- ❌ Don't wire `build_options` via `root_module.addOptions("name", opts)` — use
  `options.createModule()` inside `createModule`'s `.imports` array (verified shape).
- ❌ Don't modify `build.zig.zon` — the manifest is final from S1.
- ❌ Don't implement real CLI logic in `src/main.zig` — subcommand dispatch /
  `--help` / parg parsing is P1.M1.T3.S1. Ship only the build-graph stub here.
- ❌ Don't try to "fix" the `-lc++ -lc` in the link line by changing `link_libc` —
  ghostty-vt's C++ SIMD libs legitimately require libc/libcpp regardless (Gotcha 5).

---

**Confidence Score: 10/10** for one-pass implementation success.

The entire deliverable — both files, verbatim — was built and linked against the
real Zig 0.15.2 toolchain with the cached ghostty v1.3.1 + parg deps
(`/tmp/t2h-s2-verify`). Every validation command in this PRP was executed and
observed to pass (`zig build --release=fast` → exit 0 + 2.4 MB binary; `run --
--version` → `tmux-2html 0.1.0`; `-Dsimd=false` → exit 0; `test --release=fast`
→ exit 0). The two failure modes an implementer could hit (Debug linker bug,
removed stdout API) are documented with their exact error text and verified fixes,
and the ghostty option types/module name were read directly from ghostty's source.
The implementer is copying exit-0-verified files, not authoring from scratch.
