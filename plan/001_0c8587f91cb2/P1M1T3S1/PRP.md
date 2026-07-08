# PRP — P1.M1.T3.S1: `main.zig` subcommand dispatch + `--version` / `--help`

## Goal

**Feature Goal**: Replace the T1.S2 build-graph stub in `src/main.zig` with a real CLI
entrypoint that (a) bakes the version in from `build_options`, (b) handles `--version` /
`--help` / no-subcommand, and (c) dispatches the first positional — `render | pane | region |
sync-palette` — to per-subcommand functions in a new `src/cli.zig`. parg has **no native
subcommand support**, so dispatch is hand-rolled by peeking the first token after the program
name (the term2html `parg.parse(...)` + `nextValue()`-skip-program-name pattern, adapted to a
slice for clean flag hand-off). `cli.zig` ships **stubs** (`error.NotImplemented`); their
bodies land in later milestones (T3.S2 flag parser, P1.M2/P1.M3/P2/P3 subcommand bodies).

**Deliverable**: Two files at the repo root (`/home/dustin/projects/tmux-2html/`):
1. `src/main.zig` — **REPLACES** the T1.S2 stub. Entry point: `DebugAllocator` → `argsAlloc`
   → parg-based subcommand/version/help dispatch → routes to `cli.<sub>`. Returns the process
   exit code (`pub fn main() !u8`).
2. `src/cli.zig` — **ADDED** (new sibling file). Four `pub fn` stubs
   (`render`/`pane`/`region`/`syncPalette`) each `(allocator, args) !u8` returning
   `error.NotImplemented`. This is the contract surface T3.S2 implements.

**Success Definition** (all VERIFIED working against the real Zig 0.15.2 toolchain):
- `zig build --release=fast` exits 0; `zig-out/bin/tmux-2html` produced.
- `tmux-2html --version` → stdout `tmux-2html 0.1.0`, exit 0.
- `tmux-2html --help` → stdout usage listing all 4 subcommands, exit 0.
- `tmux-2html` (no args) → stderr usage, exit 1.
- `tmux-2html render` (and `pane`/`region`/`sync-palette`) → stderr `not yet implemented`, exit 1.
- `tmux-2html bogus` → stderr `unknown subcommand 'bogus'` + usage, exit 1.
- `tmux-2html --unknown` → stderr `unknown option '--unknown'` + usage, exit 1.
- `tmux-2html render --cols 80` → still dispatches to the render stub (sub-args handed off), exit 1.
- `zig build test --release=fast` exits 0.
- `build.zig`, `build.zig.zon` UNCHANGED (this task adds no build wiring).

> **`--release=fast` is MANDATORY** on every build/run/test (Debug linker `R_X86_64_PC64`
> bug, inherited from T1.S2). The contract's literal "zig build" is satisfied by
> `zig build --release=fast`. See Gotcha 2.

## User Persona

**Target User**: End users at a shell (the `tmux-2html` binary) AND the implementers of every
downstream subcommand (T3.S2 cli flag parser, P1.M2 palette, P1.M3 render, P2 capture, P3 TUI).

**Use Case**: `tmux-2html --version` reports the build version; `tmux-2html --help` lists the
subcommands and their roles; `tmux-2html <sub> [flags]` runs a subcommand. For THIS subtask the
subcommands are wiring-only (they error out as not-yet-implemented); the dispatch + help +
version surface is the deliverable.

**Pain Points Addressed**: Establishes the single CLI entrypoint and the `cli.zig` function
contract that every later milestone calls into; makes the binary's `--help` the canonical CLI
doc surface (PRD §5, Mode A) so docs and code never drift.

## Why

- **Unblocks every subcommand.** T3.S2 (cli flag parser) and P1.M2+ (subcommand bodies) need a
  stable dispatch boundary to hang off. This task defines it: `main` owns global flags +
  routing; `cli.<sub>` owns per-subcommand flag parsing and behavior.
- **Honors PRD §5 / §5.5.** The CLI surface (`--version`, `--help`, exit codes 0/1/2,
  `--help` listing subcommands) is specified there and is fully realized here.
- **Uses the verified parg pattern.** `parg` has no subcommand support (verified from the
  cached `parser.zig`); the documented term2html pattern (`parg.parse`, skip program name via
  `nextValue()`, loop `next()` → `.flag`/`.arg`/`.unexpected_value`) is adapted to a slice so
  each subcommand's flags can be handed off cleanly (`args[2..]`).
- **Zero build-system churn.** T1.S2 already wires `parg` + `build_options` + lazy
  `ghostty-vt` into `src/main.zig`. This task reuses that graph unchanged; `cli.zig` is a
  relative sibling import that needs no `build.zig` registration.

## What

Replace `src/main.zig` with a real dispatcher and add `src/cli.zig` with stubs.

- `main()` sets up `std.heap.DebugAllocator`, `std.process.argsAlloc`, and returns the exit
  code from `run(allocator, args)`.
- `run()` parses args with `parg.parseSlice(args, .{})`, skips the program name via
  `nextValue()`, then switches on the **first token**: `.flag` → `--version`/`--help` (exit 0)
  or unknown-option usage error (exit 1); `.arg` → dispatch to the matching `cli.<sub>` (exit
  code from the stub, `NotImplemented`→1); `.unexpected_value` → usage error (exit 1); `null`
  (no args) → usage to stderr (exit 1).
- `dispatch(allocator, name, args[2..])` routes the four known subcommands; anything else is
  `unknown subcommand` (exit 1).
- `cli.zig`: four `pub fn` stubs each `(allocator: std.mem.Allocator, args: []const []const u8) !u8`
  returning `error.NotImplemented`.
- The `--help`/usage text is the CLI doc surface and lists every subcommand (PRD §5).

### Success Criteria

- [ ] `src/main.zig` REPLACES the stub with the verbatim verified content below (149 lines).
- [ ] `src/cli.zig` ADDED with the verbatim verified content below (30 lines).
- [ ] `build.zig` + `build.zig.zon` UNCHANGED (`git diff --stat build.zig build.zig.zon` → none).
- [ ] Behavior matrix (research/findings.md §4) reproduced exactly, incl. all exit codes.
- [ ] `zig build test --release=fast` exits 0.

## All Needed Context

### Context Completeness Check

_Pass: "If someone knew nothing about this codebase, would they have everything needed to
implement this successfully?"_ — Yes. Both deliverable files are specified **verbatim** and
were built + run end-to-end against the real Zig 0.15.2 toolchain with the cached parg dep
(`/tmp/t2h-t3s1-verify`, reusing the repo's real `build.zig`/`build.zig.zon`). Every behavior
and exit code was observed. The parg API surface, the Zig 0.15.2 std APIs (DebugAllocator,
argsAlloc, File.stdout), the sibling-import rule, and the `--release=fast` mandate are all
documented with exact error text and verified fixes. The implementer is **copying exit-0-
verified files**, not authoring from scratch.

### Documentation & References

```yaml
# MUST READ — the authoritative parg API + "no native subcommands" finding + the term2html dispatch pattern
- file: plan/001_0c8587f91cb2/architecture/external_deps.md
  section: "§4 parg — CLI parsing API (verified from term2html main.zig)"
  why: "Source of the parse()/nextValue()/next() pattern adapted below. Confirms parg yields only .flag/.arg/.unexpected_value and has NO subcommand dispatch."
  critical: "term2html shows parg.parse(args,.{}) with an ITERATOR; this PRP uses parseSlice(args,.{}) on the argsAlloc slice so sub-flags can be handed off as args[2..]. Both are correct; parseSlice is the right call for a slice."

# MUST READ — where main.zig/cli.zig sit in the module map
- file: plan/001_0c8587f91cb2/architecture/system_context.md
  section: "§1 (two-layer diagram) + §2 (subcommand dispatch owned by cli.zig)"
  why: "Confirms main.zig peeks the first positional then dispatches to cli.<sub>, and the 0/1/2 exit-code policy."

# MUST READ — companion empirical verification (this PRP's evidence base + exact behavior matrix)
- file: plan/001_0c8587f91cb2/P1M1T3S1/research/findings.md
  why: "Records the exit-0 build/run/test, the verified parg Token/Flag API, the DebugAllocator/argsAlloc shapes, the sibling-import rule, and the full exit-code matrix."
  critical: "§1 (parg API) + §2 (std APIs) + §6 (gotchas) are the failure modes an implementer hits first."

# MUST READ — PRD CLI surface (the --help text must reflect this)
- file: PRD.md
  section: "§5 (CLI surface: name, exit codes 0/1/2, --help on every subcommand) + §5.5 (--version/--help)"
  why: "The usage_text below is the Mode-A CLI doc surface and lists the four subcommands verbatim from §5.1–§5.4."

# INPUT CONTRACT — the build graph + the stub this task replaces (do NOT duplicate build wiring)
- file: plan/001_0c8587f91cb2/P1M1T1S2/PRP.md
  why: "T1.S2 ships build.zig (wires parg + build_options + lazy ghostty-vt) + the src/main.zig STUB. T3.S1 OVERWRITES main.zig and ADDS cli.zig; it reuses build.zig UNCHANGED."
  pattern: "Treat T1.S2's build.zig as a CONTRACT. build_options.version is already baked in (via addOptions+createModule). main.zig reads @import(\"build_options\").version."

# CACHED parg source — read to confirm Token/Flag/parseSlice signatures (authoritative)
- file: ~/.cache/zig/p/parg-0.0.0-dOPWZNhYAABEHE6EGXmwIucnu9vj-emodT9vmHeYynAP/src/parser.zig
  section: "Token/Flag/FlagType (top), parseSlice/parse/parseProcess (mid), Parser.next/nextValue (mid)"
  why: "Confirms: Token = union(enum){flag:Flag, arg:[]const u8, unexpected_value:[]const u8}; flag.isLong/isShort; flag.kind.prefix(); parseSlice([]const []const u8, Options)."

# Zig 0.15.2 std source (authoritative for the APIs used)
- file: /home/dustin/.local/opt/zig-x86_64-linux-0.15.2/lib/std/heap/debug_allocator.zig
  why: "DebugAllocator(comptime Config) type; .{} default config; instance via struct literal; .allocator()/deinit()."
- file: /home/dustin/.local/opt/zig-x86_64-linux-0.15.2/lib/std/process.zig
  why: "argsAlloc(alloc) -> ![][:0]u8 (caller argsFree); args[2..] coerces to []const []const u8."
- file: /home/dustin/.local/opt/zig-x86_64-linux-0.15.2/lib/std/fs/File.zig
  why: "stdout()/stderr() -> *File; writeAll() — getStdOut() is GONE in 0.15.2."
```

### Current Codebase tree (T3.S1's starting point — post T1.S1/T1.S2; T2.S1 in flight)

```bash
tmux-2html/
├── build.zig              # T1.S2 wiring (parg + build_options + lazy ghostty-vt)  ← DO NOT TOUCH
├── build.zig.zon          # T1.S1 manifest (ghostty v1.3.1 + parg)                 ← DO NOT TOUCH
├── src/
│   ├── main.zig           # T1.S2 build-graph STUB                                ← T3.S1 OVERWRITES
│   ├── ghostty_format.zig # T2.S1 (parallel, in flight) — vendored formatter      ← DO NOT TOUCH / may not exist yet
│   └── .gitkeep
├── LICENSE  licenses/  scripts/  testdata/  tmux-2html.tmux   # stubs (unchanged)
├── PRD.md  .gitignore  plan/
└── ~/.cache/zig/p/ holds ghostty-1.3.1-... + parg-0.0.0-...  (already fetched)
```

### Desired Codebase tree with files to be added/changed

```bash
tmux-2html/
├── src/
│   ├── main.zig           # (T3.S1) OVERWRITTEN — real dispatch + --version/--help (149 lines, verbatim below)
│   ├── cli.zig            # (T3.S1) ADDED — 4 subcommand stubs (30 lines, verbatim below)
│   ├── ghostty_format.zig # (T2.S1) untouched / added by parallel task
│   └── .gitkeep
├── build.zig  build.zig.zon   # UNCHANGED
└── ... (all other files unchanged)
```

### Known Gotchas of our codebase & Library Quirks

```zig
// GOTCHA 1 — CRITICAL: main() must return !u8 (NOT !void). The returned u8 is the process
//   exit code. Switching to !void silently drops the 0/1/2 exit-code contract. VERIFIED:
//   `pub fn main() !u8` compiles and the returned value is the real exit code.

// GOTCHA 2 — CRITICAL: bare `zig build` (Debug) FAILS TO LINK. Always use --release=fast.
//   Error: "fatal linker error: unhandled relocation type R_X86_64_PC64" from ghostty-vt's
//   bundled C++ SIMD libs + recent glibc crt1.o. Inherited from T1.S2 (findings §4, PRD §15).
//   Apply --release=fast to EVERY build/run/test command. Do NOT try to fix the linker in build.zig.

// GOTCHA 3 — CRITICAL: std.io.getStdOut() is GONE in 0.15.2. Use std.fs.File.stdout() /
//   std.fs.File.stderr() (return *File) + writeAll(). For formatted output use
//   std.fmt.bufPrint(&buf, "...", .{}) then writeAll. (Inherited from T1.S2.)

// GOTCHA 4 — skip the program name with `nextValue()`, NOT `next()`. In parg's `.default`
//   state, nextValue() calls pull() = source.next() and returns/discards args[0]; state stays
//   `.default`. Using next() to skip would mis-classify args[0] if it looked like a flag.
//   This is the documented term2html pattern (external_deps.md §4). VERIFIED.

// GOTCHA 5 — DO NOT @import("ghostty-vt") or "ghostty_format.zig" from main.zig. Rendering is
//   render.zig's job (P1.M3). Importing ghostty-vt here UN-LAZILY compiles the full VT module
//   (~minutes) for no reason. VERIFIED: a main.zig that doesn't import ghostty-vt keeps the
//   build at ~11 s (ghostty never compiled). The build.zig addImport is harmless when unused.

// GOTCHA 6 — cli.zig is a RELATIVE SIBLING import: @import("cli.zig") WITH the .zig extension.
//   It needs NO build.zig registration (unlike the registered modules parg/build_options/
//   ghostty-vt, imported WITHOUT an extension). VERIFIED: adding src/cli.zig as a sibling
//   compiled with build.zig unchanged.

// GOTCHA 7 — args[2..] (type [][:0]u8 from argsAlloc) coerces to []const []const u8 for the
//   cli.<sub>(allocator, sub_args) hand-off AND for parg.parseSlice. VERIFIED to compile.
//   (Zig 0.15.2 accepts the [:0]u8 → []const u8 element coercion inside a slice.)

// GOTCHA 8 — exit code 2 (capture/target) is NOT produced by this subtask. It arrives with
//   capture.zig (P2.M1). T3.S1 only ever yields 0 (version/help) or 1 (usage/runtime/stub).
//   Map error.NotImplemented → 1; map the future capture/target errors → 2 in their owners.
```

## Implementation Blueprint

### Data models and structure

No domain data models. The only "model" is the **cli.zig function contract** that every later
milestone implements against:

```zig
// src/cli.zig — each subcommand is a pub fn with this signature.
//   allocator  : the process allocator (DebugAllocator) from main.
//   args       : the flags AFTER the subcommand (args[2..] of argv), already type-coerced
//                to []const []const u8. T3.S2 will parg.parseSlice these per subcommand.
//   returns    : the process exit code (0 ok, 1 usage/runtime, 2 capture/target).
pub fn <sub>(allocator: std.mem.Allocator, args: []const []const u8) !u8
```

`main()` returns `!u8`; the returned value is the process exit code. Errors that escape `run()`
abort with a stack trace + non-zero exit, so **known** errors are caught and mapped to explicit
codes inside `run()` / `dispatch()`.

### The exact deliverable 1: `src/main.zig` (OVERWRITE the T1.S2 stub; verbatim, exit-0 tested)

Create this file verbatim at `/home/dustin/projects/tmux-2html/src/main.zig`. It was built and
run successfully against Zig 0.15.2 + the cached parg dep (see research/findings.md §4).

```zig
const std = @import("std");
const build_options = @import("build_options");
const parg = @import("parg");
const cli = @import("cli.zig");

const version_string = build_options.version;

pub fn main() !u8 {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    return run(allocator, args);
}

fn run(allocator: std.mem.Allocator, args: [][:0]u8) !u8 {
    const stdout = std.fs.File.stdout();
    const stderr = std.fs.File.stderr();

    // parg has no native subcommand support (verified: parg parser.zig yields only
    // .flag / .arg / .unexpected_value tokens). So we peek the FIRST token after the
    // program name: it is either a global flag (--version / --help) or the subcommand
    // positional. This mirrors the term2html pattern: parse, skip program name via
    // nextValue(), then read tokens with next().
    var parser = parg.parseSlice(args, .{});
    defer parser.deinit();
    _ = parser.nextValue(); // discard args[0] (program name)

    const token = parser.next() orelse {
        // no subcommand given
        try printUsage(stderr);
        return 1;
    };

    switch (token) {
        .flag => |flag| {
            if (flag.isLong("version")) {
                try printVersion(stdout);
                return 0;
            }
            if (flag.isLong("help")) {
                try printHelp(stdout);
                return 0;
            }
            // Any other flag in command position is a usage error.
            var buf: [160]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "tmux-2html: unknown option '{s}{s}'\n", .{
                flag.kind.prefix(),
                flag.name,
            }) catch {
                try printUsage(stderr);
                return 1;
            };
            try stderr.writeAll(msg);
            try printUsage(stderr);
            return 1;
        },
        .arg => |name| {
            // The subcommand is always the first positional (args[1]); everything
            // after it (args[2..]) are that subcommand's flags/options.
            return dispatch(allocator, name, args[2..]) catch |err| switch (err) {
                error.NotImplemented => blk: {
                    try stderr.writeAll("tmux-2html: this subcommand is not yet implemented\n");
                    break :blk 1;
                },
                else => |e| return e,
            };
        },
        .unexpected_value => |u| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "tmux-2html: unexpected value '{s}'\n", .{u}) catch {
                try printUsage(stderr);
                return 1;
            };
            try stderr.writeAll(msg);
            try printUsage(stderr);
            return 1;
        },
    }
}

fn dispatch(allocator: std.mem.Allocator, name: []const u8, sub_args: []const []const u8) !u8 {
    if (std.mem.eql(u8, name, "render")) {
        return cli.render(allocator, sub_args);
    } else if (std.mem.eql(u8, name, "pane")) {
        return cli.pane(allocator, sub_args);
    } else if (std.mem.eql(u8, name, "region")) {
        return cli.region(allocator, sub_args);
    } else if (std.mem.eql(u8, name, "sync-palette")) {
        return cli.syncPalette(allocator, sub_args);
    }

    const stderr = std.fs.File.stderr();
    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "tmux-2html: unknown subcommand '{s}'\n", .{name});
    try stderr.writeAll(msg);
    try printUsage(stderr);
    return 1;
}

fn printVersion(out: std.fs.File) !void {
    var buf: [64]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "tmux-2html {s}\n", .{version_string});
    try out.writeAll(s);
}

// --help / usage text is the CLI doc surface (PRD §5, Mode A). Keep it accurate as
// subcommands gain real flag parsing (T3.S2+).
const usage_text =
    \\Usage: tmux-2html <subcommand> [options]
    \\       tmux-2html --version | --help
    \\
    \\Convert tmux pane output to standalone HTML.
    \\
    \\Subcommands:
    \\  render        Read ANSI from stdin, write HTML (core renderer).
    \\  pane          Capture a tmux pane and convert it to HTML.
    \\  region        Interactive copy-mode overlay: select a region, render it.
    \\  sync-palette  Query the terminal palette and cache it.
    \\
    \\Common options:
    \\  --version     Print the version and exit.
    \\  --help        Show this help.
    \\
    \\Exit codes: 0 success, 1 usage/runtime error, 2 capture/target error.
    \\
;

fn printUsage(out: std.fs.File) !void {
    try out.writeAll(usage_text);
}

fn printHelp(out: std.fs.File) !void {
    try out.writeAll(usage_text);
}

test "dispatch routes known subcommand to cli stub" {
    // Known subcommand reaches the cli stub, which reports NotImplemented.
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.NotImplemented, dispatch(allocator, "render", &.{}));
    try std.testing.expectError(error.NotImplemented, dispatch(allocator, "sync-palette", &.{}));
}

test "version string is non-empty" {
    try std.testing.expect(version_string.len > 0);
}
```

### The exact deliverable 2: `src/cli.zig` (ADD; new sibling file; verbatim, exit-0 tested)

Create this file verbatim at `/home/dustin/projects/tmux-2html/src/cli.zig`.

```zig
const std = @import("std");

// P1.M1.T3.S1 stubs. The real flag parsing + behavior lands in later milestones
// (T3.S2: parg flag parser; P1.M2/P1.M3/P2/P3: subcommand bodies).
// Each returns the process exit code (0 ok, 1 usage/runtime, 2 capture/target).
// For this subtask they all report "not yet implemented" via error.NotImplemented.

pub fn render(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    _ = allocator;
    _ = args;
    return error.NotImplemented;
}

pub fn pane(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    _ = allocator;
    _ = args;
    return error.NotImplemented;
}

pub fn region(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    _ = allocator;
    _ = args;
    return error.NotImplemented;
}

pub fn syncPalette(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    _ = allocator;
    _ = args;
    return error.NotImplemented;
}
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: CREATE src/cli.zig  (ADD — defines the dispatch contract T3.S2 implements)
  - FILE: src/cli.zig  (verbatim content above)
  - NAMING: pub fn render/pane/region/syncPalette; snake_case file, the export name `syncPalette`
            maps to the CLI string "sync-palette" (hyphen) in main.zig's dispatch().
  - SIGNATURE: (allocator: std.mem.Allocator, args: []const []const u8) !u8
  - BODY: return error.NotImplemented; (discard both params with _ = to avoid unused-var errors)
  - WHY FIRST: main.zig imports it; it must exist for main.zig to compile.

Task 2: OVERWRITE src/main.zig  (REPLACE the T1.S2 stub — the primary deliverable)
  - FILE: src/main.zig  (verbatim content above)
  - KEEP EXACT: main() returns !u8; DebugAllocator(.{}){} + deinit + allocator();
                argsAlloc/argsFree; parg.parseSlice(args,.{}) + nextValue() skip + next() switch;
                dispatch() routing the 4 subcommands; the usage_text multiline string;
                both test blocks.
  - DO NOT import ghostty-vt / ghostty_format.zig (Gotcha 5 — keeps the build fast/lazy).
  - DEPENDENCIES: imports cli.zig (Task 1), parg, build_options.

Task 3: VALIDATE  (see Validation Loop — all commands verified working)
  - RUN: zig build --release=fast                       # expect exit 0 + zig-out/bin/tmux-2html
  - RUN: zig build run --release=fast -- --version      # expect stdout: tmux-2html 0.1.0
  - RUN: zig build run --release=fast -- --help         # expect usage listing 4 subcommands
  - RUN: zig build run --release=fast -- render         # expect stderr "not yet implemented", exit 1
  - RUN: zig build run --release=fast -- bogus          # expect stderr "unknown subcommand", exit 1
  - RUN: zig build test --release=fast                  # expect exit 0
```

### Implementation Patterns & Key Details

```zig
// PATTERN: main() returns the exit code via !u8 (the channel for 0/1/2).
pub fn main() !u8 {
    var gpa = std.heap.DebugAllocator(.{}){};   // type-instance w/ default config
    defer _ = gpa.deinit();                      // deinit returns std.heap.Check; discard
    const allocator = gpa.allocator();
    const args = try std.process.argsAlloc(allocator);   // [][:0]u8; caller must argsFree
    defer std.process.argsFree(allocator, args);
    return run(allocator, args);
}

// PATTERN: parg subcommand detection (no native subcommand support — peek the first token).
var parser = parg.parseSlice(args, .{});   // args ([][:0]u8) coerces to []const []const u8
defer parser.deinit();
_ = parser.nextValue();                     // skip program name (args[0])
const token = parser.next() orelse { try printUsage(stderr); return 1; };
switch (token) {
    .flag => |flag| { if (flag.isLong("version")) {...} ... },  // global flags short-circuit
    .arg => |name| { return dispatch(allocator, name, args[2..]); },  // subcommand + its flags
    .unexpected_value => |u| { ... },          // e.g. stray --name=val at top level
}

// PATTERN: hand the subcommand's flags (args[2..]) to cli.<sub>; map known errors to codes.
return dispatch(allocator, name, args[2..]) catch |err| switch (err) {
    error.NotImplemented => blk: { try stderr.writeAll("...not yet implemented\n"); break :blk 1; },
    else => |e| return e,                       // unexpected errors propagate (stack trace + nonzero)
};

// PATTERN: 0.15.2 stdout/stderr + formatted write (getStdOut is GONE).
const stdout = std.fs.File.stdout();
var buf: [64]u8 = undefined;
const s = try std.fmt.bufPrint(&buf, "tmux-2html {s}\n", .{version_string});
try stdout.writeAll(s);
```

### Integration Points

```yaml
BUILD GRAPH:
  - consumes (from T1.S1/T1.S2): build.zig (parg + build_options + lazy ghostty-vt), build.zig.zon.
  - produces (this task): src/main.zig (real dispatch) + src/cli.zig (4 stubs).
  - next (T3.S2): implements each cli.<sub> body — parg.parseSlice(sub_args) + per-subcommand
                   flags incl. --help (PRD §5 "--help on every subcommand"). Signature unchanged.
  - next (P1.M3 render, P2.M1 capture, P3 region): fill the cli.<sub> bodies; raise
                   error.Capture*/Target* → mapped to exit 2 by their owners (NOT in this task).
  - next (P1.M4.T2 golden tests): extend `zig build test` with more addTest artifacts.

CONFIG:
  - version source: @import("build_options").version (= build.zig.zon .version = "0.1.0").
  - no env vars, no settings files.

CLI SURFACE (PRD §5):
  - subcommands: render | pane | region | sync-palette.
  - global flags: --version, --help. (Short -h/-V are intentionally NOT supported — PRD §5.5
    specifies long forms only; do not add short aliases speculatively.)
  - exit codes: 0 success, 1 usage/runtime, 2 capture/target (2 unused at this subtask).
```

## Validation Loop

> **ALL commands below were executed successfully** against the real Zig 0.15.2 toolchain
> with the cached parg dep. Re-run them verbatim. EVERY build/run/test command MUST include
> `--release=fast` (Gotcha 2 — bare Debug hits the `R_X86_64_PC64` linker bug).

### Level 1: Syntax & Style (Immediate Feedback)

```bash
zig version            # MUST print: 0.15.2

# Zig 0.15.2 has no separate lint/format step; the build runner is the checker.
# A typo (e.g. wrong parg method, missing field) surfaces as a compile error here.
zig build --fetch      # expect: exit 0 (deps already cached; instant)
```

### Level 2: Build the binary (Component Validation — PRIMARY gate)

```bash
zig build --release=fast          # expect: exit 0 (ghostty stays lazy: ~11 s build)
ls -la zig-out/bin/tmux-2html     # expect: ELF binary exists (~3.6 MB)
file zig-out/bin/tmux-2html       # expect: "ELF 64-bit LSB executable, x86-64"

# Expected: zero errors. If you see "fatal linker error: unhandled relocation type
# R_X86_64_PC64", you forgot --release=fast (Gotcha 2). If "no member named 'getStdOut'",
# main.zig used the old IO API (Gotcha 3). If "no module named 'cli' available", you
# imported cli as @import("cli") instead of @import("cli.zig") (Gotcha 6).
```

### Level 3: Behavior + exit codes (System Validation — the contract)

```bash
BIN="zig-out/bin/tmux-2html"   # or: zig build run --release=fast -- <args>

# --version → stdout, exit 0
"$BIN" --version;                                       echo "exit=$? (want 0)"
# Expected stdout EXACTLY:  tmux-2html 0.1.0

# --help → stdout usage listing all 4 subcommands, exit 0
"$BIN" --help | head -1;                                echo "exit=${PIPESTATUS[0]} (want 0)"
# Expected first line:  Usage: tmux-2html <subcommand> [options]
"$BIN" --help | grep -c -E 'render|pane|region|sync-palette'   # expect: >= 4

# no subcommand → stderr usage, exit 1
"$BIN" >/dev/null 2>&1;                                 echo "exit=$? (want 1)"

# each subcommand dispatches to its stub → stderr, exit 1
for s in render pane region sync-palette; do
  out=$("$BIN" "$s" 2>&1 >/dev/null); rc=$?
  [ "$rc" = 1 ] && grep -q "not yet implemented" <<<"$out" && echo "$s: OK (exit 1)"
done

# unknown subcommand → stderr, exit 1
"$BIN" bogus 2>&1 | grep -q "unknown subcommand 'bogus'"; echo "bogus: $? (want 0=found)"

# unknown option in command position → stderr, exit 1
"$BIN" --unknown 2>&1 | grep -q "unknown option '--unknown'"; echo "unknown-opt: $? (want 0)"

# sub-flags are handed off to the stub (args[2..])
"$BIN" render --cols 80 2>&1 | grep -q "not yet implemented"; echo "sub-args: $? (want 0)"
```

### Level 4: Test step + scope boundary (Domain Validation)

```bash
# Test step compiles + runs the test blocks in main.zig (dispatch routing + version).
zig build test --release=fast          # expect: exit 0

# Scope boundary: build.zig / build.zig.zon UNCHANGED by this task.
git diff --stat build.zig build.zig.zon   # expect: no output (unchanged)
git diff --stat src/                       # expect: src/main.zig modified, src/cli.zig added

# (Optional) confirm ghostty stayed lazy (fast build = ghostty not compiled):
time zig build --release=fast 2>&1 | tail -1   # expect: well under a minute (~11 s here)
```

## Final Validation Checklist

### Technical Validation

- [ ] `zig version` prints `0.15.2`.
- [ ] `zig build --fetch` exits 0.
- [ ] `zig build --release=fast` exits 0; `zig-out/bin/tmux-2html` produced (~3.6 MB).
- [ ] `zig build test --release=fast` exits 0.

### Feature Validation

- [ ] `tmux-2html --version` → `tmux-2html 0.1.0`, exit 0.
- [ ] `tmux-2html --help` → usage listing all 4 subcommands, exit 0.
- [ ] `tmux-2html` (no args) → stderr usage, exit 1.
- [ ] `render`/`pane`/`region`/`sync-palette` → `not yet implemented`, exit 1.
- [ ] unknown subcommand → `unknown subcommand '<x>'` + usage, exit 1.
- [ ] unknown option → `unknown option '<x>'` + usage, exit 1.
- [ ] `render --cols 80` dispatches (sub-args handed off), exit 1.
- [ ] `src/cli.zig` exposes 4 `pub fn` stubs with the `(allocator, args) !u8` contract.

### Code Quality Validation

- [ ] `src/main.zig` matches the verbatim Blueprint (returns `!u8`; `DebugAllocator`;
      `argsAlloc`/`argsFree`; `parg.parseSlice` + `nextValue()` skip + `next()` switch;
      `dispatch` routing 4 subs; `usage_text`; 2 test blocks).
- [ ] `src/cli.zig` matches the verbatim Blueprint (4 stubs, `error.NotImplemented`).
- [ ] No out-of-scope work (no flag parsing in cli.zig bodies, no ghostty-vt import, no
      build.zig edits — those belong to T3.S2 / P1.M3 / T1.S2 respectively).
- [ ] Uses the 0.15.2 stdout API (`std.fs.File.stdout()`), not removed `std.io.getStdOut()`.
- [ ] `build.zig` + `build.zig.zon` unchanged.

### Documentation & Deployment

- [ ] `--help` text (the CLI doc surface, Mode A) lists every subcommand and the exit codes;
      accurate to PRD §5.1–§5.5. (It will be extended per-subcommand in T3.S2.)
- [ ] No new env vars or config.

---

## Anti-Patterns to Avoid

- ❌ Don't run `zig build` / `zig build run` / `zig build test` WITHOUT `--release=fast` —
  Debug linking hits the `R_X86_64_PC64` fatal error (Gotcha 2, verified).
- ❌ Don't make `main()` return `!void` — the u8 return value IS the exit code (Gotcha 1).
- ❌ Don't use `std.io.getStdOut()`/`getStdErr()` — removed in 0.15.2 (Gotcha 3). Use
  `std.fs.File.stdout()`/`stderr()`.
- ❌ Don't skip the program name with `parser.next()` — use `parser.nextValue()` (Gotcha 4).
- ❌ Don't `@import("ghostty-vt")` or `"ghostty_format.zig"` from main.zig — it un-lazily
  compiles the whole VT module for no reason (Gotcha 5). Rendering is render.zig's job (P1.M3).
- ❌ Don't import cli as `@import("cli")` — it's a sibling FILE: `@import("cli.zig")` with the
  `.zig` extension (Gotcha 6). Registered modules (parg/build_options/ghostty-vt) have no
  extension; sibling files do.
- ❌ Don't modify `build.zig` or `build.zig.zon` — the graph is complete from T1.S2; `cli.zig`
  is a sibling import that needs no registration.
- ❌ Don't implement real flag parsing or subcommand bodies in `cli.zig` — T3.S2 owns the flag
  parser and P1.M2/P1.M3/P2/P3 own the bodies. Ship only the dispatch + stubs here.
- ❌ Don't add `-h`/`-V` short aliases — PRD §5.5 specifies `--version`/`--help` (long) only.
- ❌ Don't swallow unknown errors silently — let them propagate (stack trace + nonzero exit);
  only map KNOWN errors (`error.NotImplemented` → 1) to explicit codes.

---

**Confidence Score: 10/10** for one-pass implementation success.

Both deliverable files — `src/main.zig` (149 lines) and `src/cli.zig` (30 lines) — were
**built and run end-to-end** against the real Zig 0.15.2 toolchain with the cached parg dep in
an isolated throwaway project (`/tmp/t2h-t3s1-verify`) reusing the repo's exact `build.zig` +
`build.zig.zon`. Every validation command in this PRP was executed and observed to pass:
`zig build --release=fast` → exit 0 (~11 s; ghostty stayed lazy); the full behavior matrix
(research/findings.md §4) reproduced with exact stdout/stderr and exit codes (`--version` →
`tmux-2html 0.1.0` exit 0; `--help` exit 0; no-args/unknown-sub/unknown-option exit 1; all four
subcommands → `not yet implemented` exit 1; `render --cols 80` hands off sub-args); and
`zig build test --release=fast` → exit 0. The failure modes an implementer could hit (Debug
linker bug, removed stdout API, nextValue-vs-next skip, sibling-vs-module import, ghostty
laziness) are documented with exact error text and verified fixes. The parg Token/Flag API and
the Zig 0.15.2 DebugAllocator/argsAlloc signatures were read directly from std source. The
implementer is copying exit-0-verified files, not authoring from scratch.
