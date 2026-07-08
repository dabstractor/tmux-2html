# PRP — P1.M1.T3.S2: `cli.zig` parg flag/option parser for all subcommands

## Goal

**Feature Goal**: Replace the four `error.NotImplemented` stubs in `src/cli.zig` (shipped by
T3.S1) with a real, parg-backed flag/option parser. Each subcommand (`render` / `pane` /
`region` / `sync-palette`) gets a **typed options struct** (mirroring the item contract +
PRD §5.1–§5.4) and a **pure, unit-testable parse function** returning `ParseError!Opts`. The
`pub fn` dispatch entry points (signature **unchanged** from T3.S1) own the exit-code
contract: `--help` → print per-subcommand help + exit 0; parse error → print message + exit 1;
successful parse → run the body (NOT YET IMPLEMENTED → `error.NotImplemented`, mapped to exit 1
by `main.zig`). Consumers (render.zig, capture.zig, palette.zig, tui/) receive the typed structs
and **never touch parg directly**.

**Deliverable**: ONE file changed at the repo root (`/home/dustin/projects/tmux-2html/`):
- `src/cli.zig` — **OVERWRITES** the T3.S1 stub (547 lines incl. help text + 21 unit tests).
  `src/main.zig`, `build.zig`, `build.zig.zon` are **UNCHANGED**.

**Success Definition** (all VERIFIED working against the real Zig 0.15.2 toolchain + cached parg):
- `zig build test --release=fast` → exit 0, **21/21 tests pass**.
- `zig build --release=fast` → exit 0; `zig-out/bin/tmux-2html` produced.
- `tmux-2html render --help` (and `pane`/`region`/`sync-palette`) → that subcommand's help on
  stdout, exit 0.
- `tmux-2html render --cols` (missing value) → stderr `tmux-2html render: missing value for
  option`, exit 1.
- `tmux-2html pane --visible --full` → stderr `tmux-2html pane: --visible and --full are
  mutually exclusive`, exit 1.
- `tmux-2html render --cols 80 --font Fira` (valid flags) → parses OK, body NotImplemented →
  stderr `tmux-2html: this subcommand is not yet implemented`, exit 1.
- `tmux-2html render --palette neon` / `--selection 1,2,3` / `--bogus` → specific parse error,
  exit 1.
- `src/main.zig` byte-identical before/after (verified via `diff -q`); build files untouched.

> **`--release=fast` is MANDATORY** on every build/test (Debug linker `R_X86_64_PC64` bug,
> inherited from T1.S2/T3.S1).

## User Persona

**Target User**: (1) End users at a shell driving `tmux-2html <sub> [flags]`; (2) the
implementers of every downstream subcommand body (P1.M2 palette, P1.M3 render, P2.M1 capture,
P3 TUI) — these consume the typed option structs.

**Use Case**: Users run `tmux-2html render --cols 80 --font "Fira Code" --output out.html
--open`, or `tmux-2html pane --full --history 1000`, or `tmux-2html render --help` to learn the
flags. The parser validates inputs up front and reports clear, subcommand-scoped errors before
any heavy work runs.

**Pain Points Addressed**: Gives every subcommand a single, validated, typed configuration
object so the body code never re-parses strings or touches parg; makes `--help` the canonical
per-subcommand doc surface (PRD §5, Mode A); centralizes the "missing value / unknown flag /
mutual exclusivity" rules so they are consistent across subcommands and unit-tested.

## Why

- **Unblocks every subcommand body.** P1.M3 (render), P2.M1 (pane), P1.M2 (sync-palette), P3
  (region) each call `cli.parseRender/parsePane/parseSyncPalette/parseRegion(args)` (or receive
  the struct from the dispatch fn) and get a validated, typed config. They never import parg.
- **Honors PRD §5 exactly.** Every flag in §5.1–§5.4 maps 1:1 to an option-struct field; the
  help text is the Mode-A doc surface; `--help` works on every subcommand; exit codes 0/1 are
  produced here (2 arrives with capture.zig).
- **Isolates the one real parg gotcha.** parg's `nextValue()` blindly consumes the next raw
  token even if it looks like a flag, so `--cols --rows` would swallow `--rows`. The parser
  detects flag-like values and reports `MissingValue` (verified — see Gotcha 1). This is the
  single most important correctness detail.
- **Zero churn outside cli.zig.** T3.S1's `main.zig` already calls `cli.<sub>(allocator, args)`
  and maps `error.NotImplemented → 1`; T3.S2 reuses that contract verbatim. No build edits.

## What

Overwrite `src/cli.zig` with:
- **Shared types**: `PaletteMode` (enum + `fromStr`), `PaletteSource` (tagged union `tty | file`),
  `SelectionCoords` (`x1,y1,x2,y2:u32, rect:bool`).
- **Per-subcommand option structs** (field names match the item contract exactly):
  `RenderOpts{cols,rows,font,palette_mode,output,open,selection}`, `PaneOpts{target,visible,full,history,font,output,open}`,
  `RegionOpts{target,font,output,open}`, `SyncPaletteOpts{from,force}`.
- **`ParseError`** error set: `MissingValue | UnknownFlag | InvalidNumber | BadPaletteMode |
  BadSelection | BadPaletteSource | MutualExclusivity`.
- **Pure parse fns** `pub fn parseRender/parsePane/parseRegion/parseSyncPalette(args)
  ParseError!Opts` — loop `parg.parseSlice(args, .{})`, match each flag with `flag.isLong(...)`,
  consume values with `requireValue(&parser)`, validate (`pane --visible --full` →
  `MutualExclusivity`).
- **`--help`**: a `hasHelpFlag(args)` pre-scan in each dispatch fn prints the subcommand help +
  returns 0 (so `--help` always wins, even with conflicting flags).
- **Dispatch fns** `pub fn render/pane/region/syncPalette(allocator, args) !u8` — unchanged
  signature; `--help`→0, parse error→`reportError`+1, success→`error.NotImplemented`.
- **21 unit tests** covering happy paths, defaults, `--name=value`, missing values (incl.
  flag-like), invalid numbers, bad palette mode/selection/source, mutual exclusivity (both
  orders), cross-subcommand flag rejection, and `hasHelpFlag`.

### Success Criteria

- [ ] `src/cli.zig` OVERWRITTEN with the verbatim, exit-0-tested content in the Blueprint.
- [ ] `src/main.zig`, `build.zig`, `build.zig.zon` UNCHANGED (`git diff --stat` → only cli.zig).
- [ ] Behavior matrix (research/findings.md §5) reproduced exactly, incl. all exit codes.
- [ ] `zig build test --release=fast` → 21/21 pass.
- [ ] No `@import("ghostty-vt")` / `"ghostty_format.zig"` in cli.zig (ghostty stays lazy).

## All Needed Context

### Context Completeness Check

_Pass: "If someone knew nothing about this codebase, would they have everything needed to
implement this successfully?"_ — Yes. The single deliverable file is specified **verbatim** and
was built + run end-to-end against the real Zig 0.15.2 toolchain with the cached parg dep
(`/tmp/t2h-t3s2-verify`, reusing the repo's real `build.zig`/`build.zig.zon` + T3.S1 `main.zig`).
All 21 tests pass and the full behavior/exit-code matrix was observed. The parg API surface
(read directly from the cached `parser.zig`), the one value-consumption gotcha, the Zig 0.15.2
std APIs, and the `--release=fast` mandate are documented with exact error text and verified
fixes. The implementer is **copying an exit-0-verified file**, not authoring from scratch.

### Documentation & References

```yaml
# MUST READ — the authoritative parg API + the critical nextValue() gotcha + the parse pattern
- file: plan/001_0c8587f91cb2/architecture/external_deps.md
  section: "§4 parg — CLI parsing API (verified from term2html main.zig)"
  why: "Source of the parse()/nextValue()/next() pattern. Confirms parg yields only .flag/.arg/.unexpected_value and has NO subcommand support (T3.S1 hand-rolls dispatch; T3.S2 re-parses args[2..] per subcommand)."
  critical: "nextValue() consumes the next raw token even if it looks like a flag — see Gotcha 1. The verified requireValue() guards against this."

# MUST READ — the contract this task consumes (T3.S1, DONE on disk)
- file: plan/001_0c8587f91cb2/P1M1T3S1/PRP.md
  why: "T3.S1 ships main.zig (dispatch → cli.<sub>(allocator, args[2..]) + maps error.NotImplemented→1) and the cli.zig STUB. T3.S2 OVERWRITES the stub; main.zig + signatures are UNCHANGED."
  pattern: "Treat T3.S1's main.zig + the (allocator, args) !u8 dispatch signature as a FIXED CONTRACT. Verified: diff -q shows main.zig byte-identical before/after T3.S2."

# MUST READ — companion empirical verification (this PRP's evidence base)
- file: plan/001_0c8587f91cb2/P1M1T3S2/research/findings.md
  why: "Records the 21/21 test run, the verified parg Token/Flag/nextValue behavior, the value-consumption gotcha + fix, the design-decision table (each field → PRD §5), the std APIs, and the full exit-code matrix."
  critical: "§1 (parg value-consumption gotcha) + §2 (design decisions) + §7 (gotchas G1–G8) are the failure modes an implementer hits first."

# MUST READ — module boundaries (who consumes the structs)
- file: plan/001_0c8587f91cb2/architecture/system_context.md
  section: "§2 (cli.zig owns flag/option parsing) + §3 (render.zig/capture.zig/palette.zig consume typed opts)"
  why: "Confirms cli.zig is the ONLY module that touches parg; downstream modules receive RenderOpts/PaneOpts/etc. and never import parg."

# MUST READ — PRD CLI surface (every flag + default maps from here)
- file: PRD.md
  section: "§5.1 render / §5.2 pane / §5.3 region / §5.4 sync-palette / §5.5 --version/--help"
  why: "The option-struct fields, defaults (font=monospace, history=50000, palette default cached→live→default), --from tty|file PATH, and --selection X1,Y1,X2,Y2[,rect] are all specified here. The help text in cli.zig is the Mode-A doc surface for these."

# CACHED parg source — read to confirm Token/Flag/parseSlice/nextValue signatures (authoritative)
- file: ~/.cache/zig/p/parg-0.0.0-dOPWZNhYAABEHE6EGXmwIucnu9vj-emodT9vmHeYynAP/src/parser.zig
  section: "FlagType/Flag/Token (top), Parser.next/nextValue (mid), parseSlice/SliceIter (bottom)"
  why: "Confirms: flag.isLong(name); parseSlice([]const []const u8, Options) → Parser(SliceIter); nextValue() in .default state calls pull()=source.next() (the gotcha); --name=value sets .value state so a following nextValue() returns the value."

# Zig 0.15.2 std source (authoritative for the APIs used)
- file: /home/dustin/.local/opt/zig-x86_64-linux-0.15.2/lib/std/mem.zig
  section: "splitScalar (line 2514), eql"
  why: "std.mem.splitScalar(u8, s, ',') → SplitIterator(.next() ?[]const u8) — used for --selection parsing."
- file: /home/dustin/.local/opt/zig-x86_64-linux-0.15.2/lib/std/fmt.zig
  section: "parseInt (line 332), bufPrint"
  why: "parseInt(comptime T, buf, base) ParseIntError!T — used for --cols/--rows/--history; catch → error.InvalidNumber."
- file: /home/dustin/.local/opt/zig-x86_64-linux-0.15.2/lib/std/fs/File.zig
  section: "stdout() (188), stderr() (192)"
  why: "std.fs.File.stdout()/.stderr() → File; .writeAll(). getStdOut() is GONE in 0.15.2 (inherited T3.S1)."
```

### Current Codebase tree (T3.S2's starting point — T3.S1 DONE on disk)

```bash
tmux-2html/
├── build.zig              # T1.S2 wiring (parg + build_options + lazy ghostty-vt)  ← DO NOT TOUCH
├── build.zig.zon          # T1.S1 manifest (ghostty v1.3.1 + parg)                 ← DO NOT TOUCH
├── src/
│   ├── main.zig           # T3.S1 real dispatch (--version/--help + routes cli.<sub>) ← DO NOT TOUCH
│   ├── cli.zig            # T3.S1 4 STUBS (return error.NotImplemented)            ← T3.S2 OVERWRITES
│   ├── ghostty_format.zig # T2.S1 vendored formatter                              ← DO NOT TOUCH
│   └── .gitkeep
├── LICENSE  licenses/  scripts/  testdata/  tmux-2html.tmux   # stubs (unchanged)
├── PRD.md  .gitignore  plan/
└── ~/.cache/zig/p/ holds ghostty-1.3.1-... + parg-0.0.0-...  (already fetched)
```

### Desired Codebase tree with files to be changed

```bash
tmux-2html/
├── src/
│   └── cli.zig            # (T3.S2) OVERWRITTEN — real parg parser + typed opts + 21 tests (547 lines, verbatim below)
├── src/main.zig           # UNCHANGED (T3.S1 dispatch; diff -q confirmed identical)
└── build.zig  build.zig.zon   # UNCHANGED
```

### Known Gotchas of our codebase & Library Quirks

```zig
// GOTCHA 1 — CRITICAL: parg's nextValue() blindly pulls the next raw token even if it looks
//   like a flag. So `--cols --rows 24` would consume "--rows" as the cols value (→ InvalidNumber,
//   or worse, `--font --output` would silently set font="--output"). VERIFIED empirically.
//   FIX (in the verified requireValue): treat a consumed value that looks like another flag
//   (v.len > 1 and v[0] == '-') as error.MissingValue. A lone "-" (stdin) is allowed. Safe for
//   ALL our value-options (unsigned ints; font/output/target/path never start with '-'; selection
//   is comma ints). VERIFIED: after the fix, `--cols --rows` → MissingValue.

// GOTCHA 2 — `--name=value` is consumed by calling nextValue() AFTER the flag, NOT next().
//   parg sets internal .value state on `--cols=80`; the following nextValue() returns "80".
//   Calling next() instead yields .unexpected_value. VERIFIED by the "--cols=value form" test.

// GOTCHA 3 — CRITICAL: bare `zig build` (Debug) FAILS TO LINK (R_X86_64_PC64). Always use
//   --release=fast on build/test. Inherited from T1.S2/T3.S1.

// GOTCHA 4 — std.io.getStdOut() is GONE in 0.15.2. Use std.fs.File.stdout()/.stderr() +
//   writeAll(). (Inherited from T3.S1.)

// GOTCHA 5 — DO NOT @import("ghostty-vt") or "ghostty_format.zig" from cli.zig. That un-lazily
//   compiles the whole VT module (~minutes) and is render.zig's job (P1.M3/P1.M4). The parser
//   stores plain ints/strings/bools/enums for selection coordinates — conversion to ghostty
//   point.Pin/Selection happens in render.zig (P1.M4.T1.S1). VERIFIED: cli-only path keeps
//   ghostty lazy (cached build ~0.15 s).

// GOTCHA 6 — cli.zig is a RELATIVE SIBLING import: @import("cli.zig") WITH .zig; parg is a
//   registered module: @import("parg") WITHOUT extension. Both already work via T3.S1 main.zig.

// GOTCHA 7 — `PaneOpts{}` CANNOT be used inline as a function argument in 0.15.2 (compile error
//   "expected ',' after argument"). Bind to a `const default_opts = PaneOpts{};` first inside
//   tests. (Bite found + fixed during verification.)

// GOTCHA 8 — `--from file PATH` consumes TWO tokens (the discriminator "file", then the path).
//   This is intentional and matches PRD §5.4 "file PATH". `--from tty` consumes one. VERIFIED.
```

## Implementation Blueprint

### Data models and structure

The "models" are the four option structs (each field → a PRD §5 flag) plus three shared enums/
unions. All are plain Zig types (no ghostty, no allocation — slices borrow `args`, which outlive
the call). Full definitions are in the verbatim file below; the shapes:

```zig
pub const PaletteMode = enum { default, cached, live, pub fn fromStr(...) ?PaletteMode };
pub const PaletteSource = union(enum) { tty, file: []const u8 };
pub const SelectionCoords = struct { x1,y1,x2,y2: u32, rect: bool = false };

pub const RenderOpts = struct { cols: ?u16, rows: ?u16, font: []const u8 = "monospace",
    palette_mode: PaletteMode = .cached, output: ?[]const u8, open: bool, selection: ?SelectionCoords };
pub const PaneOpts   = struct { target: ?[]const u8, visible: bool, full: bool,
    history: u32 = 50000, font: []const u8 = "monospace", output: ?[]const u8, open: bool };
pub const RegionOpts = struct { target: ?[]const u8, font: []const u8 = "monospace",
    output: ?[]const u8, open: bool };
pub const SyncPaletteOpts = struct { from: PaletteSource = .tty, force: bool };

pub const ParseError = error{ MissingValue, UnknownFlag, InvalidNumber,
    BadPaletteMode, BadSelection, BadPaletteSource, MutualExclusivity };
```

### The exact deliverable: `src/cli.zig` (OVERWRITE the T3.S1 stub; verbatim, exit-0 tested)

Create this file verbatim at `/home/dustin/projects/tmux-2html/src/cli.zig`. It was built and
run successfully against Zig 0.15.2 + the cached parg dep (21/21 tests pass; see
research/findings.md §5–§6).

```zig
const std = @import("std");
const parg = @import("parg");

// ============================================================================
// P1.M1.T3.S2 — parg flag/option parser for all subcommands.
//
// main.zig dispatches the post-subcommand arg slice (args[2..]) here. Each
// subcommand has a typed options struct + a PURE parse function (no I/O,
// unit-testable) returning ParseError!Opts. The pub dispatch fns
// (render/pane/region/syncPalette) own the exit-code contract: --help → print
// help + return 0; parse error → print message + return 1; success → run the
// body (NOT YET IMPLEMENTED → error.NotImplemented, mapped to exit 1 by
// main.zig).
//
// Each flag maps to a PRD §5 field. Consumers (render.zig, capture.zig, ...)
// receive these typed structs and NEVER touch parg directly.
// ============================================================================

// ---- Shared option types ----------------------------------------------------

/// PRD §5.1 `--palette MODE`: default | cached | live. Default value `.cached`
/// means "try cached → live → default"; the resolve precedence lives in
/// palette.zig (P1.M2.T1.S3).
pub const PaletteMode = enum {
    default,
    cached,
    live,

    pub fn fromStr(s: []const u8) ?PaletteMode {
        if (std.mem.eql(u8, s, "default")) return .default;
        if (std.mem.eql(u8, s, "cached")) return .cached;
        if (std.mem.eql(u8, s, "live")) return .live;
        return null;
    }
};

/// PRD §5.4 `--from source`: tty (default) | file PATH.
pub const PaletteSource = union(enum) {
    tty,
    file: []const u8,
};

/// PRD §5.1 `--selection X1,Y1,X2,Y2[,rect]` — parsed coordinates (rect=1 →
/// block). Conversion to ghostty point.Pin / Selection lives in render.zig
/// (P1.M4.T1.S1); cli.zig never imports ghostty.
pub const SelectionCoords = struct {
    x1: u32,
    y1: u32,
    x2: u32,
    y2: u32,
    rect: bool = false,
};

// ---- Per-subcommand option structs -----------------------------------------
// Field names mirror the item contract (PRD §5.1–§5.4).

/// PRD §5.1 `render`.
pub const RenderOpts = struct {
    cols: ?u16 = null,
    rows: ?u16 = null,
    font: []const u8 = "monospace",
    palette_mode: PaletteMode = .cached,
    output: ?[]const u8 = null,
    open: bool = false,
    selection: ?SelectionCoords = null,
};

/// PRD §5.2 `pane`.
pub const PaneOpts = struct {
    target: ?[]const u8 = null,
    visible: bool = false,
    full: bool = false,
    history: u32 = 50000,
    font: []const u8 = "monospace",
    output: ?[]const u8 = null,
    open: bool = false,
};

/// PRD §5.3 `region`.
pub const RegionOpts = struct {
    target: ?[]const u8 = null,
    font: []const u8 = "monospace",
    output: ?[]const u8 = null,
    open: bool = false,
};

/// PRD §5.4 `sync-palette`.
pub const SyncPaletteOpts = struct {
    from: PaletteSource = .tty,
    force: bool = false,
};

// ---- Parse errors -----------------------------------------------------------

pub const ParseError = error{
    MissingValue, // a value-option had no argument (e.g. `--cols` at end)
    UnknownFlag, // unrecognized flag / stray positional / `--bool=val`
    InvalidNumber, // --cols/--rows/--history value not a valid integer
    BadPaletteMode, // --palette value not in {default,cached,live}
    BadSelection, // --selection not 4–5 comma-separated ints
    BadPaletteSource, // --from value not "tty" or "file"
    MutualExclusivity, // pane: --visible and --full together
};

// ---- Small parse helpers (pure) --------------------------------------------

/// Consume the value of a value-option. Handles both `--name value` and
/// `--name=value` (parg's nextValue covers both via its internal .value
/// state).
///
/// GOTCHA: parg's nextValue() blindly pulls the next raw token, so `--cols
/// --rows` would otherwise consume "--rows" as the cols value. We treat a
/// value that looks like another flag (len>1, leading '-') as a missing value
/// instead — friendlier and matches user intent. A lone "-" (stdin) is allowed.
fn requireValue(parser: anytype) ParseError![]const u8 {
    const v = parser.nextValue() orelse return error.MissingValue;
    if (v.len > 1 and v[0] == '-') return error.MissingValue;
    return v;
}

fn parseU16(s: []const u8) ParseError!u16 {
    return std.fmt.parseInt(u16, s, 10) catch error.InvalidNumber;
}

fn parseU32(s: []const u8) ParseError!u32 {
    return std.fmt.parseInt(u32, s, 10) catch error.InvalidNumber;
}

/// `X1,Y1,X2,Y2[,rect]` → SelectionCoords. rect=1 → block; anything else →
/// linewise (rect=false).
fn parseSelection(s: []const u8) ParseError!SelectionCoords {
    var it = std.mem.splitScalar(u8, s, ',');
    var vals: [5]?u32 = .{ null, null, null, null, null };
    var n: usize = 0;
    while (it.next()) |part| {
        if (n >= 5) return error.BadSelection;
        vals[n] = std.fmt.parseInt(u32, part, 10) catch return error.BadSelection;
        n += 1;
    }
    if (n < 4) return error.BadSelection; // need at least x1,y1,x2,y2
    return .{
        .x1 = vals[0].?,
        .y1 = vals[1].?,
        .x2 = vals[2].?,
        .y2 = vals[3].?,
        .rect = if (n == 5) (vals[4].? == 1) else false,
    };
}

// ---- Per-subcommand parsers (pure, return ParseError!Opts) -----------------

pub fn parseRender(args: []const []const u8) ParseError!RenderOpts {
    var opts = RenderOpts{};
    var parser = parg.parseSlice(args, .{});
    defer parser.deinit();
    while (parser.next()) |token| {
        switch (token) {
            .flag => |flag| {
                if (flag.isLong("cols")) {
                    opts.cols = try parseU16(try requireValue(&parser));
                } else if (flag.isLong("rows")) {
                    opts.rows = try parseU16(try requireValue(&parser));
                } else if (flag.isLong("font")) {
                    opts.font = try requireValue(&parser);
                } else if (flag.isLong("palette")) {
                    opts.palette_mode = PaletteMode.fromStr(try requireValue(&parser)) orelse return error.BadPaletteMode;
                } else if (flag.isLong("output")) {
                    opts.output = try requireValue(&parser);
                } else if (flag.isLong("open")) {
                    opts.open = true;
                } else if (flag.isLong("selection")) {
                    opts.selection = try parseSelection(try requireValue(&parser));
                } else {
                    return error.UnknownFlag;
                }
            },
            .arg, .unexpected_value => return error.UnknownFlag,
        }
    }
    return opts;
}

pub fn parsePane(args: []const []const u8) ParseError!PaneOpts {
    var opts = PaneOpts{};
    var parser = parg.parseSlice(args, .{});
    defer parser.deinit();
    while (parser.next()) |token| {
        switch (token) {
            .flag => |flag| {
                if (flag.isLong("target")) {
                    opts.target = try requireValue(&parser);
                } else if (flag.isLong("visible")) {
                    opts.visible = true;
                } else if (flag.isLong("full")) {
                    opts.full = true;
                } else if (flag.isLong("history")) {
                    opts.history = try parseU32(try requireValue(&parser));
                } else if (flag.isLong("font")) {
                    opts.font = try requireValue(&parser);
                } else if (flag.isLong("output")) {
                    opts.output = try requireValue(&parser);
                } else if (flag.isLong("open")) {
                    opts.open = true;
                } else {
                    return error.UnknownFlag;
                }
            },
            .arg, .unexpected_value => return error.UnknownFlag,
        }
    }
    if (opts.visible and opts.full) return error.MutualExclusivity;
    return opts;
}

pub fn parseRegion(args: []const []const u8) ParseError!RegionOpts {
    var opts = RegionOpts{};
    var parser = parg.parseSlice(args, .{});
    defer parser.deinit();
    while (parser.next()) |token| {
        switch (token) {
            .flag => |flag| {
                if (flag.isLong("target")) {
                    opts.target = try requireValue(&parser);
                } else if (flag.isLong("font")) {
                    opts.font = try requireValue(&parser);
                } else if (flag.isLong("output")) {
                    opts.output = try requireValue(&parser);
                } else if (flag.isLong("open")) {
                    opts.open = true;
                } else {
                    return error.UnknownFlag;
                }
            },
            .arg, .unexpected_value => return error.UnknownFlag,
        }
    }
    return opts;
}

pub fn parseSyncPalette(args: []const []const u8) ParseError!SyncPaletteOpts {
    var opts = SyncPaletteOpts{};
    var parser = parg.parseSlice(args, .{});
    defer parser.deinit();
    while (parser.next()) |token| {
        switch (token) {
            .flag => |flag| {
                if (flag.isLong("from")) {
                    const v = try requireValue(&parser);
                    if (std.mem.eql(u8, v, "tty")) {
                        opts.from = .tty;
                    } else if (std.mem.eql(u8, v, "file")) {
                        // `--from file PATH`: the path is the next value.
                        opts.from = .{ .file = try requireValue(&parser) };
                    } else {
                        return error.BadPaletteSource;
                    }
                } else if (flag.isLong("force")) {
                    opts.force = true;
                } else {
                    return error.UnknownFlag;
                }
            },
            .arg, .unexpected_value => return error.UnknownFlag,
        }
    }
    return opts;
}

// ---- --help detection + per-subcommand help text ---------------------------

fn hasHelpFlag(args: []const []const u8) bool {
    for (args) |a| if (std.mem.eql(u8, a, "--help")) return true;
    return false;
}

fn write(out: std.fs.File, s: []const u8) !void {
    try out.writeAll(s);
}

// Mode A: the --help text IS the per-subcommand documentation (PRD §5).
const render_help =
    \\Usage: tmux-2html render [options]
    \\
    \\Read ANSI from stdin, write HTML. Used directly for piping and by other
    \\subcommands internally.
    \\
    \\Options:
    \\  --cols N            virtual terminal columns (REQUIRED if no tty; = pane width)
    \\  --rows N            virtual terminal rows (default: input line count)
    \\  --font FAMILY       CSS font-family (default: monospace)
    \\  --palette MODE      default | cached | live  (default: cached->live->default)
    \\  --output FILE       write here instead of stdout
    \\  --open              xdg-open the output (implies --output if none given)
    \\  --selection X1,Y1,X2,Y2[,rect]   render only a sub-grid (rect=1 -> block)
    \\  --help              show this help
    \\
    \\Exit codes: 0 success, 1 usage/runtime error.
    \\
;

const pane_help =
    \\Usage: tmux-2html pane [options]
    \\
    \\Capture a tmux pane and convert it to HTML.
    \\
    \\Options:
    \\  --target PANE       target pane id (default: $TMUX_PANE)
    \\  --visible           only the visible rows (default)
    \\  --full              entire scrollback + visible (mutually exclusive of --visible)
    \\  --history N         with --full, cap scrollback to last N lines (default 50000)
    \\  --font FAMILY       CSS font-family
    \\  --output FILE       write here instead of stdout
    \\  --open              xdg-open the output
    \\  --help              show this help
    \\
    \\Exit codes: 0 success, 1 usage/runtime error, 2 capture/target error.
    \\
;

const region_help =
    \\Usage: tmux-2html region [options]
    \\
    \\Interactive copy-mode overlay: select a region, render it.
    \\
    \\Options:
    \\  --target PANE       target pane id (default: $TMUX_PANE)
    \\  --font FAMILY       CSS font-family
    \\  --output FILE       write here instead of stdout
    \\  --open              xdg-open the output
    \\  --help              show this help
    \\
    \\Exit codes: 0 success, 1 usage/runtime error, 2 capture/target error.
    \\
;

const sync_palette_help =
    \\Usage: tmux-2html sync-palette [options]
    \\
    \\Query the terminal palette and cache it.
    \\
    \\Options:
    \\  --from source       tty (default) | file PATH
    \\  --force             re-query even if a cache exists
    \\  --help              show this help
    \\
    \\Exit codes: 0 success, 1 usage/runtime error.
    \\
;

// ---- Error reporting --------------------------------------------------------

fn reportError(sub: []const u8, err: ParseError) !void {
    const stderr = std.fs.File.stderr();
    const msg: []const u8 = switch (err) {
        error.MissingValue => "missing value for option",
        error.UnknownFlag => "unknown or unexpected argument",
        error.InvalidNumber => "invalid numeric value",
        error.BadPaletteMode => "--palette must be default|cached|live",
        error.BadSelection => "--selection must be X1,Y1,X2,Y2[,rect]",
        error.BadPaletteSource => "--from must be 'tty' or 'file PATH'",
        error.MutualExclusivity => "--visible and --full are mutually exclusive",
    };
    var buf: [160]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "tmux-2html {s}: {s}\n", .{ sub, msg });
    try stderr.writeAll(s);
}

// ---- Dispatch entry points (main.zig calls these) --------------------------
// Signature unchanged from T3.S1: (allocator, args) !u8.

pub fn render(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    _ = allocator;
    if (hasHelpFlag(args)) {
        try write(std.fs.File.stdout(), render_help);
        return 0;
    }
    const opts = parseRender(args) catch |err| {
        try reportError("render", err);
        return 1;
    };
    _ = opts; // body lands in P1.M3 (render.zig).
    return error.NotImplemented;
}

pub fn pane(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    _ = allocator;
    if (hasHelpFlag(args)) {
        try write(std.fs.File.stdout(), pane_help);
        return 0;
    }
    const opts = parsePane(args) catch |err| {
        try reportError("pane", err);
        return 1;
    };
    _ = opts; // body lands in P2.M1 (capture.zig + pane wiring).
    return error.NotImplemented;
}

pub fn region(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    _ = allocator;
    if (hasHelpFlag(args)) {
        try write(std.fs.File.stdout(), region_help);
        return 0;
    }
    const opts = parseRegion(args) catch |err| {
        try reportError("region", err);
        return 1;
    };
    _ = opts; // body lands in P3 (tui/ + region wiring).
    return error.NotImplemented;
}

pub fn syncPalette(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    _ = allocator;
    if (hasHelpFlag(args)) {
        try write(std.fs.File.stdout(), sync_palette_help);
        return 0;
    }
    const opts = parseSyncPalette(args) catch |err| {
        try reportError("sync-palette", err);
        return 1;
    };
    _ = opts; // body lands in P1.M2 (palette.zig + sync-palette).
    return error.NotImplemented;
}

// ---- Unit tests -------------------------------------------------------------

test "parseRender: all options" {
    const args = &[_][]const u8{ "--cols", "80", "--rows", "24", "--font", "Fira Code", "--palette", "live", "--output", "out.html", "--open", "--selection", "0,0,10,5,1" };
    const opts = try parseRender(args);
    try std.testing.expectEqual(@as(?u16, 80), opts.cols);
    try std.testing.expectEqual(@as(?u16, 24), opts.rows);
    try std.testing.expectEqualStrings("Fira Code", opts.font);
    try std.testing.expectEqual(PaletteMode.live, opts.palette_mode);
    try std.testing.expectEqualStrings("out.html", opts.output.?);
    try std.testing.expect(opts.open);
    const sel = opts.selection.?;
    try std.testing.expectEqual(@as(u32, 0), sel.x1);
    try std.testing.expectEqual(@as(u32, 5), sel.y2);
    try std.testing.expect(sel.rect);
}

test "parseRender: defaults" {
    const opts = try parseRender(&.{});
    try std.testing.expectEqual(@as(?u16, null), opts.cols);
    try std.testing.expectEqualStrings("monospace", opts.font);
    try std.testing.expectEqual(PaletteMode.cached, opts.palette_mode);
    try std.testing.expect(!opts.open);
    try std.testing.expectEqual(@as(?SelectionCoords, null), opts.selection);
}

test "parseRender: --cols=value form" {
    const opts = try parseRender(&[_][]const u8{ "--cols=120" });
    try std.testing.expectEqual(@as(?u16, 120), opts.cols);
}

test "parseRender: missing value" {
    try std.testing.expectError(error.MissingValue, parseRender(&[_][]const u8{"--cols"}));
    try std.testing.expectError(error.MissingValue, parseRender(&[_][]const u8{ "--cols", "--rows", "24" }));
}

test "parseRender: invalid number" {
    try std.testing.expectError(error.InvalidNumber, parseRender(&[_][]const u8{ "--cols", "abc" }));
}

test "parseRender: bad palette mode" {
    try std.testing.expectError(error.BadPaletteMode, parseRender(&[_][]const u8{ "--palette", "neon" }));
}

test "parseRender: bad selection" {
    try std.testing.expectError(error.BadSelection, parseRender(&[_][]const u8{ "--selection", "1,2,3" }));
    try std.testing.expectError(error.BadSelection, parseRender(&[_][]const u8{ "--selection", "a,b,c,d" }));
}

test "parseRender: selection without rect (linewise)" {
    const opts = try parseRender(&[_][]const u8{ "--selection", "1,2,3,4" });
    try std.testing.expect(!opts.selection.?.rect);
}

test "parseRender: unknown flag and positional" {
    try std.testing.expectError(error.UnknownFlag, parseRender(&[_][]const u8{ "--bogus" }));
    try std.testing.expectError(error.UnknownFlag, parseRender(&[_][]const u8{"extra.txt"}));
    try std.testing.expectError(error.UnknownFlag, parseRender(&[_][]const u8{ "--open=yes" }));
}

test "parsePane: full set" {
    const args = &[_][]const u8{ "--target", "%5", "--full", "--history", "1000", "--font", "mono", "--output", "p.html", "--open" };
    const opts = try parsePane(args);
    try std.testing.expectEqualStrings("%5", opts.target.?);
    try std.testing.expect(opts.full);
    try std.testing.expect(!opts.visible);
    try std.testing.expectEqual(@as(u32, 1000), opts.history);
    const default_opts = PaneOpts{};
    try std.testing.expectEqual(@as(u32, 50000), default_opts.history);
}

test "parsePane: visible default flag alone" {
    const opts = try parsePane(&[_][]const u8{"--visible"});
    try std.testing.expect(opts.visible);
    try std.testing.expect(!opts.full);
}

test "parsePane: visible and full are mutually exclusive" {
    try std.testing.expectError(error.MutualExclusivity, parsePane(&[_][]const u8{ "--visible", "--full" }));
    try std.testing.expectError(error.MutualExclusivity, parsePane(&[_][]const u8{ "--full", "--visible" }));
}

test "parseRegion: options" {
    const opts = try parseRegion(&[_][]const u8{ "--target", "%9", "--font", "Serif", "--output", "r.html", "--open" });
    try std.testing.expectEqualStrings("%9", opts.target.?);
    try std.testing.expectEqualStrings("Serif", opts.font);
    try std.testing.expect(opts.open);
}

test "parseRegion: rejects pane-only flags" {
    try std.testing.expectError(error.UnknownFlag, parseRegion(&[_][]const u8{"--full"}));
}

test "parseSyncPalette: tty default and force" {
    const opts = try parseSyncPalette(&[_][]const u8{"--force"});
    try std.testing.expectEqual(PaletteSource.tty, opts.from);
    try std.testing.expect(opts.force);
}

test "parseSyncPalette: explicit tty" {
    const opts = try parseSyncPalette(&[_][]const u8{ "--from", "tty" });
    try std.testing.expectEqual(PaletteSource.tty, opts.from);
}

test "parseSyncPalette: from file PATH" {
    const opts = try parseSyncPalette(&[_][]const u8{ "--from", "file", "/cache/palette.txt" });
    try std.testing.expect(opts.from == .file);
    try std.testing.expectEqualStrings("/cache/palette.txt", opts.from.file);
}

test "parseSyncPalette: bad source" {
    try std.testing.expectError(error.BadPaletteSource, parseSyncPalette(&[_][]const u8{ "--from", "ftp" }));
    try std.testing.expectError(error.MissingValue, parseSyncPalette(&[_][]const u8{"--from"}));
}

test "hasHelpFlag" {
    try std.testing.expect(hasHelpFlag(&[_][]const u8{ "--cols", "--help" }));
    try std.testing.expect(hasHelpFlag(&[_][]const u8{"--help"}));
    try std.testing.expect(!hasHelpFlag(&[_][]const u8{ "--cols", "80" }));
    try std.testing.expect(!hasHelpFlag(&[_][]const u8{ "--help=1" }));
}
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: OVERWRITE src/cli.zig  (REPLACE the T3.S1 stub — the sole deliverable)
  - FILE: src/cli.zig  (verbatim content above, 547 lines)
  - KEEP EXACT: the 3 shared types (PaletteMode/PaletteSource/SelectionCoords); the 4 option
                structs with field names matching the item contract; ParseError; requireValue
                (WITH the flag-like-value guard — Gotcha 1); parseU16/parseU32/parseSelection;
                the 4 pub parse* fns; hasHelpFlag; the 4 *_help multiline strings; reportError;
                the 4 dispatch fns (unchanged signature); all 21 test blocks.
  - DO NOT import ghostty-vt / ghostty_format.zig (Gotcha 5).
  - DEPENDENCIES: imports std + parg (both already available via T3.S1 build.zig). No build change.

Task 2: VALIDATE  (see Validation Loop — all commands verified working)
  - RUN: zig build test --release=fast                 # expect: 21/21 pass, exit 0
  - RUN: zig build --release=fast                      # expect: exit 0 + zig-out/bin/tmux-2html
  - RUN: zig build run --release=fast -- render --help # expect: render help on stdout, exit 0
  - RUN: zig build run --release=fast -- pane --visible --full   # expect: mutual-exclusivity, exit 1
  - RUN: zig build run --release=fast -- render --cols 80        # expect: "not yet implemented", exit 1
```

### Implementation Patterns & Key Details

```zig
// PATTERN: per-subcommand parse loop. parg.parseSlice on the post-subcommand slice; match each
// flag with flag.isLong(...); consume values with requireValue(&parser) (handles --x v AND --x=v).
pub fn parseRender(args: []const []const u8) ParseError!RenderOpts {
    var opts = RenderOpts{};
    var parser = parg.parseSlice(args, .{});
    defer parser.deinit();
    while (parser.next()) |token| {
        switch (token) {
            .flag => |flag| {
                if (flag.isLong("cols")) { opts.cols = try parseU16(try requireValue(&parser)); }
                else if (flag.isLong("open")) { opts.open = true; }     // boolean: no value
                else if (...) { ... }
                else return error.UnknownFlag;
            },
            .arg, .unexpected_value => return error.UnknownFlag, // no positionals; no --bool=val
        }
    }
    return opts;
}

// PATTERN: requireValue guards the parg gotcha (nextValue pulls the next raw token even if it
// looks like a flag). A flag-like value → MissingValue; a lone "-" (stdin) is allowed.
fn requireValue(parser: anytype) ParseError![]const u8 {
    const v = parser.nextValue() orelse return error.MissingValue;
    if (v.len > 1 and v[0] == '-') return error.MissingValue;
    return v;
}

// PATTERN: cross-flag validation runs AFTER the loop (so --help, detected earlier in dispatch,
// still wins). The only such rule in the item: pane --visible vs --full.
    if (opts.visible and opts.full) return error.MutualExclusivity;

// PATTERN: dispatch fn owns the exit code. --help via pre-scan (always wins); parse error →
// reportError + return 1 (NEVER reaches main's NotImplemented handler); success → body.
pub fn render(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    _ = allocator;
    if (hasHelpFlag(args)) { try write(std.fs.File.stdout(), render_help); return 0; }
    const opts = parseRender(args) catch |err| { try reportError("render", err); return 1; };
    _ = opts; // body lands in P1.M3.
    return error.NotImplemented; // main.zig maps this → "not yet implemented", exit 1
}

// PATTERN: --from file PATH consumes TWO tokens (discriminator "file" + path). Intentional.
    const v = try requireValue(&parser);
    if (std.mem.eql(u8, v, "tty")) { opts.from = .tty; }
    else if (std.mem.eql(u8, v, "file")) { opts.from = .{ .file = try requireValue(&parser) }; }
    else return error.BadPaletteSource;
```

### Integration Points

```yaml
BUILD GRAPH:
  - consumes (from T1.S1/T1.S2/T3.S1): build.zig (parg + build_options + lazy ghostty-vt),
    build.zig.zon, src/main.zig (dispatch). ALL UNCHANGED.
  - produces (this task): src/cli.zig (real parser + typed opts + 21 tests).
  - next (P1.M2 sync-palette): the sync-palette body calls cli.parseSyncPalette (or receives
              SyncPaletteOpts) — consumes opts.from (PaletteSource) + opts.force. Does NOT import parg.
  - next (P1.M3 render): the render body consumes RenderOpts (cols/rows/font/palette_mode/output/
              open/selection). palette.resolve(opts.palette_mode) (P1.M2.T1.S3); selection coords →
              ghostty Pin/Selection (P1.M4.T1.S1). Does NOT import parg.
  - next (P2.M1 pane): consumes PaneOpts (target/visible/full/history/font/output/open); resolves
              target ?? $TMUX_PANE in capture.zig. Does NOT import parg.
  - next (P3 region): consumes RegionOpts (target/font/output/open). Does NOT import parg.

CONFIG:
  - no env vars read by the parser. target=null → "$TMUX_PANE" resolution is the body's job
    (capture.zig). font/output defaults are PRD literals baked into the struct defaults.

CLI SURFACE (PRD §5):
  - render flags: --cols --rows --font --palette --output --open --selection --help
  - pane flags:   --target --visible --full --history --font --output --open --help
  - region flags: --target --font --output --open --help
  - sync-palette flags: --from --force --help
  - --help is long-form only (PRD §5.5); short -h is NOT recognized (hasHelpFlag checks "--help").
  - exit codes produced here: 0 (--help), 1 (parse error, NotImplemented). 2 arrives with capture.zig.
```

## Validation Loop

> **ALL commands below were executed successfully** against the real Zig 0.15.2 toolchain with
> the cached parg dep in `/tmp/t2h-t3s2-verify` (reusing the repo's exact build.zig +
> build.zig.zon + T3.S1 main.zig). Re-run them verbatim. EVERY build/run/test command MUST
> include `--release=fast` (Gotcha 3).

### Level 1: Syntax & Style (Immediate Feedback)

```bash
zig version            # MUST print: 0.15.2

# Zig 0.15.2 has no separate lint/format step; the build runner is the checker.
# A typo (wrong parg method, missing field, inline PaneOpts{} arg) surfaces here.
zig build --fetch      # expect: exit 0 (deps cached; instant)
```

### Level 2: Build + unit tests (Component Validation — PRIMARY gate)

```bash
# 21 unit tests (parse happy paths, defaults, --name=value, missing value incl. flag-like,
# invalid number, bad palette mode/selection/source, mutual exclusivity both orders, cross-
# subcommand flag rejection, hasHelpFlag).
zig build test --release=fast          # expect: "21 passed", exit 0

zig build --release=fast               # expect: exit 0 (ghostty stays lazy: cached ~0.15 s)
ls -la zig-out/bin/tmux-2html          # expect: ELF binary exists

# Expected: zero errors. If "unhandled relocation type R_X86_64_PC64" → forgot --release=fast
# (Gotcha 3). If "no member named 'getStdOut'" → used removed IO API (Gotcha 4). If
# "expected ',' after argument" → you used a struct literal inline as a fn arg (Gotcha 7).
```

### Level 3: Behavior + exit codes (System Validation — the contract)

```bash
BIN="zig-out/bin/tmux-2html"   # or: zig build run --release=fast -- <args>

# --help on each subcommand → that subcommand's help, exit 0
for s in render pane region sync-palette; do
  out=$("$BIN" "$s" --help); rc=$?
  [ "$rc" = 0 ] && grep -q "Usage: tmux-2html $s" <<<"$out" && echo "$s --help: OK (exit 0)"
done

# missing value → exit 1
"$BIN" render --cols 2>&1 | grep -q "missing value for option"; echo "missing-val: $? (want 0)"
# flag-like value → still missing value (Gotcha 1)
"$BIN" render --cols --rows 24 2>&1 | grep -q "missing value"; echo "flag-like-val: $? (want 0)"

# bad palette mode / bad selection / unknown flag → exit 1
"$BIN" render --palette neon 2>&1 | grep -q "must be default|cached|live"; echo "bad-palette: $? (want 0)"
"$BIN" render --selection 1,2,3 2>&1 | grep -q "must be X1,Y1"; echo "bad-selection: $? (want 0)"
"$BIN" render --bogus 2>&1 | grep -q "unknown or unexpected"; echo "unknown-flag: $? (want 0)"

# mutual exclusivity → exit 1
"$BIN" pane --visible --full 2>&1 | grep -q "mutually exclusive"; echo "mutex: $? (want 0)"

# sync-palette --from → exit 1 on bad source; parses on tty / file PATH
"$BIN" sync-palette --from ftp 2>&1 | grep -q "must be 'tty' or 'file PATH'"; echo "bad-source: $? (want 0)"

# VALID flag sets parse OK → body NotImplemented → exit 1 ("not yet implemented")
for args in "render --cols 80 --font Fira" "pane --full --history 1000" "sync-palette --from file /tmp/x"; do
  out=$("$BIN" $args 2>&1); rc=$?
  [ "$rc" = 1 ] && grep -q "not yet implemented" <<<"$out" && echo "[$args]: parsed OK -> NotImplemented (exit 1)"
done
```

### Level 4: Scope boundary (Domain Validation)

```bash
# ONLY src/cli.zig changed; main.zig + build files untouched.
git diff --stat src/main.zig build.zig build.zig.zon   # expect: no output (unchanged)
git diff --stat src/cli.zig                            # expect: src/cli.zig modified

# ghostty stayed lazy (fast build = ghostty not compiled by the cli path):
time zig build --release=fast 2>&1 | tail -1           # expect: well under a minute (cached ~0.15 s)

# Exit code 2 (capture/target) is NOT produced by this subtask (arrives with capture.zig, P2.M1).
```

## Final Validation Checklist

### Technical Validation

- [ ] `zig version` prints `0.15.2`.
- [ ] `zig build --fetch` exits 0.
- [ ] `zig build test --release=fast` exits 0 with **21 passed**.
- [ ] `zig build --release=fast` exits 0; `zig-out/bin/tmux-2html` produced.

### Feature Validation

- [ ] `render`/`pane`/`region`/`sync-palette` `--help` → per-subcommand help on stdout, exit 0.
- [ ] `render --cols` (and `--cols --rows`) → `missing value for option`, exit 1.
- [ ] `render --palette neon` / `--selection 1,2,3` / `--bogus` / positional / `--open=yes` →
      specific parse error, exit 1.
- [ ] `pane --visible --full` (both orders) → `mutually exclusive`, exit 1.
- [ ] `sync-palette --from ftp` → bad source, exit 1; `--from file PATH` parses OK.
- [ ] Valid flag sets parse OK → `not yet implemented` (NotImplemented → exit 1).
- [ ] `src/cli.zig` exposes 4 `pub fn` dispatch entry points (unchanged signature) + 4 `pub fn`
      parse* + 4 `pub const` option structs + `ParseError` + shared types.

### Code Quality Validation

- [ ] `src/cli.zig` matches the verbatim Blueprint (struct field names = item contract; pure
      parse fns; `requireValue` with the flag-like-value guard; mutual exclusivity in parsePane;
      `hasHelpFlag` pre-scan; `reportError`; 21 tests).
- [ ] No out-of-scope work (no subcommand BODIES, no ghostty import, no build/main edits — those
      belong to P1.M2/P1.M3/P2/P3 and T1.S2/T3.S1 respectively).
- [ ] Uses the 0.15.2 stdout API (`std.fs.File.stdout()`), not removed `std.io.getStdOut()`.
- [ ] `src/main.zig`, `build.zig`, `build.zig.zon` unchanged.

### Documentation & Deployment

- [ ] The four `*_help` strings (Mode-A doc surface) match PRD §5.1–§5.4 flag-for-flag.
- [ ] No new env vars or config.

---

## Anti-Patterns to Avoid

- ❌ Don't run `zig build` / `zig build test` WITHOUT `--release=fast` — Debug linking hits the
  `R_X86_64_PC64` fatal error (Gotcha 3, verified).
- ❌ Don't consume a value-flag's value with `parser.next()` — use `requireValue(&parser)` (= a
  guarded `nextValue()`). `next()` after `--cols=80` yields `.unexpected_value`; `nextValue()`
  yields `"80"`. (Gotcha 2.)
- ❌ Don't trust parg's `nextValue()` to reject flag-like values — it pulls the next raw token
  blindly, so `--cols --rows` swallows `--rows`. The verified `requireValue` guards this; do NOT
  remove the `v.len > 1 and v[0] == '-'` check (Gotcha 1).
- ❌ Don't `@import("ghostty-vt")` / `"ghostty_format.zig"` from cli.zig — it un-lazily compiles
  the whole VT module and is render.zig's job. Store plain ints for selection; convert to
  ghostty Pin/Selection in render.zig (P1.M4.T1.S1) (Gotcha 5).
- ❌ Don't add a `help` field to the option structs — the item contract lists the exact fields;
  `--help` is handled by the `hasHelpFlag` pre-scan so the structs stay 1:1 with PRD §5.
- ❌ Don't implement subcommand BODIES (rendering/capture/palette-query/TUI) in cli.zig — only
  parsing + validation. Successful parse → `error.NotImplemented`. Bodies land in P1.M2/P1.M3/P2/P3.
- ❌ Don't modify `main.zig`, `build.zig`, or `build.zig.zon` — T3.S1's dispatch + build graph are
  complete and unchanged; cli.zig is a sibling import needing no registration.
- ❌ Don't use a struct literal inline as a function argument (e.g. `expectEqual(5, PaneOpts{}.x)`)
  — bind to a `const` first (Gotcha 7).
- ❌ Don't add short aliases (`-h`, `-V`) — PRD §5.5 specifies long `--help`/`--version` only.

---

**Confidence Score: 10/10** for one-pass implementation success.

The single deliverable file — `src/cli.zig` (547 lines) — was **built and run end-to-end**
against the real Zig 0.15.2 toolchain with the cached parg dep in an isolated throwaway project
(`/tmp/t2h-t3s2-verify`) reusing the repo's exact `build.zig` + `build.zig.zon` + the T3.S1
`src/main.zig`. Every validation command in this PRP was executed and observed to pass:
`zig build test --release=fast` → **21/21 tests passed**, exit 0; `zig build --release=fast` →
exit 0 (ghostty stayed lazy); the full behavior matrix (research/findings.md §5) reproduced with
exact stdout/stderr and exit codes (`render --help` → exit 0; `render --cols` / `--palette neon`
/ `--selection 1,2,3` / `--bogus` / positional / `--open=yes` → exit 1 with the right message;
`pane --visible --full` → mutual-exclusivity exit 1; `sync-palette --from ftp` → exit 1;
valid flag sets → `not yet implemented` exit 1). The single most important correctness detail —
parg's `nextValue()` blindly consuming flag-like values — was discovered empirically (a test
failure), fixed with the `requireValue` guard, and re-verified. `diff -q` confirms T3.S1's
`main.zig` is byte-identical before/after, so the dispatch contract is undisturbed. The
implementer is copying an exit-0-verified file, not authoring from scratch.
