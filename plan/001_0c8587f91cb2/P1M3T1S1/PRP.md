# PRP — P1.M3.T1.S1: renderGrid() core pipeline (default colors) + render subcommand (stdin→stdout)

## Goal

**Feature Goal**: Implement `renderGrid()` — the single, reusable primitive that turns ANSI bytes into
self-contained HTML via the vendored ghostty `ScreenFormatter` — and wire the `tmux-2html render` subcommand
to read ANSI from stdin, render with `palette.defaultColors()`, and write HTML to stdout. This is the
foundation primitive every P2/P3 subcommand (`pane`, `region`) will reuse.

**Deliverable**:
1. `src/render.zig` exporting `pub const Size`, `pub fn renderGrid(...)`, and `pub fn run(...)` (the subcommand body).
2. `src/cli.zig` wired so `cli.render` delegates to `render.run` after parsing (replacing the current `error.NotImplemented`).
3. `src/main.zig` dispatch test updated (the `render` subcommand no longer returns `NotImplemented`).
4. Unit tests proving `renderGrid` emits correct inline-styled HTML (red span, bold span, plain text, OSC empty-input edge).

**Success Definition**: `printf '\033[31mred\033[0m' | zig build run -- render --cols 40` emits valid HTML
containing `<span style="…color:#…">red</span>`, `zig build test` is green, and `renderGrid` is callable with
`sel: null` / `font` / a `*std.Io.Writer` so P2/P3/S4 can extend it without rewriting it.

## Why

- The rendering engine (PRD §8) is the heart of tmux-2html; `renderGrid` is its ONE primitive.
- Every capture mode (`pane`, `region`) reduces to "get ANSI → call `renderGrid` → write file/stdout".
- S1 establishes the verified term2html/ghostty pipeline (Terminal → vtStream → ScreenFormatter) with default
  colors so S2 (sizing/font/output), S3 (`--palette` resolve), and S4 (`--selection` Pin) can layer on cleanly.

## What

### User-visible behavior
- `tmux-2html render [--cols N] [--rows N] [--font FAMILY] …` reads ANSI from **stdin**, writes an HTML
  `<pre class="term2html-output">…</pre>` fragment to **stdout**, exits 0.
- Colors/attributes/OSC-8 hyperlinks in the input are reproduced as inline CSS (`color:#rrggbb`,
  `font-weight:bold`, `<a href=…>`) — fidelity is handled entirely by ghostty-vt; **no bespoke ANSI parser**.

### Success Criteria
- [ ] `renderGrid(alloc, ansi, size, colors, null, font, out)` writes valid HTML to a `*std.Io.Writer`.
- [ ] `printf '\033[31mred\033[0m' | zig build run -- render --cols 40` output contains `<span style="` and `>red</span>` and a `#` hex color.
- [ ] `printf '\033[1mbold\033[0m' | … render --cols 40` contains `font-weight:bold`.
- [ ] Empty stdin produces a `<pre …></pre>` (no crash).
- [ ] `zig build test` green; `zig build` compiles ghostty-vt into the binary.
- [ ] `renderGrid` signature matches the contract so S2/S3/S4 extend (not replace) it.

## All Needed Context

### Context Completeness Check

_Passed._ A developer who has never seen this repo can implement this from: the verified pipeline below
(read from ghostty v1.3.1 source), the **compile-validated** Zig 0.15 new-IO writer pattern, the existing
`palette.zig`/`cli.zig`/`ghostty_format.zig`, and the explicit scope boundaries vs S2/S3/S4.

### Documentation & References

```yaml
# MUST READ — the verified pipeline + every API signature (read directly from ghostty 1.3.1 + Zig 0.15.2 stdlib)
- docfile: plan/001_0c8587f91cb2/architecture/render_pipeline.md
  why: "VERIFIED term2html formatAnsi shape — the exact pipeline this task implements (§1), Colors struct (§2), Selection (§4), golden harness (§5)."
  section: "§1 (pipeline), §2 (Colors), §6 (file provenance table)"
  critical: "§1 is the literal sequence: Terminal.init -> vtStream -> per-byte next() with \\n->\\r\\n -> ScreenFormatter.init -> content.selection -> extra.styles -> print \"{f}\"."

- docfile: plan/001_0c8587f91cb2/architecture/findings_and_corrections.md
  why: "Source-of-truth corrections to the PRD. §2 verified ghostty-vt API surface; §0.3 ScreenFormatter.Content; §0.4 vendored ghostty_format.zig already has font."
  section: "§0 (corrections), §2 (verified API), §2.1-§2.4 (Terminal/ScreenFormatter/Options/Selection signatures)"

- docfile: plan/001_0c8587f91cb2/P1M3T1S1/research/findings.md
  why: "THIS task's research: all signatures pinned to source line numbers + the COMPILE-VALIDATED new-IO writer bridge + scope boundaries."
  section: "§3 (writer gotcha — read FIRST), §1 (pipeline), §2 (Colors->Options mapping), §6 (scope), §7 (wiring), §8 (test to update)"

# Existing source files to FOLLOW / CONSUME
- file: src/ghostty_format.zig
  why: "The vendored formatter. ScreenFormatter.init(screen, opts); .content = .{.selection=sel}; .extra = .styles; format(writer: *std.Io.Writer). Has Options.font. DO NOT modify (P1.M1.T2.S1 vendored it)."
  pattern: "ScreenFormatter struct — init/content/extra fields; format() driven by writer.print(\"{f}\", .{formatter})."
  gotcha: "format() takes a *std.Io.Writer (the NEW Zig 0.15 IO type), NOT fs.File and NOT fs.File.Writer."

- file: src/palette.zig
  why: "CONSUME: palette.Colors {palette:[256]color.RGB, foreground:?color.RGB, background:?color.RGB, palette_received_count:u16} and defaultColors(). Already implemented (P1.M2.T1.S1)."
  pattern: "defaultColors() returns Ghostty bundled palette, fg=palette[7], bg={41,44,51}. colors.palette is [256]color.RGB == color.Palette."
  gotcha: "render.zig must NOT re-implement colors. S1 uses defaultColors() only; S3 will wire palette.resolve()."

- file: src/cli.zig
  why: "CONSUME: pub const RenderOpts {cols,rows,font,palette_mode,output,open,selection} and pub fn parseRender (pure, done in P1.M1.T3.S2). pub fn render() currently returns NotImplemented — WIRE it."
  pattern: "render() does: hasHelpFlag -> print render_help + 0; parseRender(args) catch reportError+1; THEN (currently) _=opts; return NotImplemented. Replace the NotImplemented with render.run(allocator, opts)."
  gotcha: "parseRender is PURE and ghostty-free — keep it that way. Adding `const render = @import(\"render.zig\");` at the top of cli.zig is fine (parse fns stay pure)."

- file: src/main.zig
  why: "dispatch() routes subcommands to cli.* . The test block imports palette.zig (keeps ghostty-vt compiled in test mode). Update the dispatch test (§8 of findings)."
  pattern: "test block: `_ = @import(\"palette.zig\");`. Add `_ = @import(\"render.zig\");` so renderGrid tests are reachable from the test root."
```

### Current Codebase tree

```bash
src/
├── main.zig            # dispatch + --version/--help; test root imports palette.zig
├── cli.zig             # parg parser: RenderOpts/parseRender + render() returns NotImplemented
├── palette.zig         # Colors + defaultColors() + queryColors/cache/resolve (DONE in P1.M2)
├── ghostty_format.zig  # VENDORED formatter (ScreenFormatter, Options, font) — DO NOT EDIT
└── .gitkeep
licenses/{TERM2HTML.txt,GHOSTTY-VT.txt}
build.zig / build.zig.zon   # ghostty (LAZY) + parg; min_zig 0.15.2; ghostty pinned v1.3.1
testdata/.gitkeep
```

### Desired Codebase tree (this task)

```bash
src/
├── render.zig          # NEW. pub Size, pub renderGrid(), pub run(). Unit tests.
├── cli.zig             # MODIFIED: render() delegates to render.run() (was NotImplemented)
├── main.zig            # MODIFIED: test root imports render.zig; dispatch test updated
├── palette.zig         # unchanged (consumed)
└── ghostty_format.zig  # unchanged (consumed)
```

### Known Gotchas of our codebase & Library Quirks

```zig
// CRITICAL — the new Zig 0.15 IO writer bridge (COMPILE-VALIDATED; see research/findings.md §3).
// ghostty_format.ScreenFormatter.format takes *std.Io.Writer. fs.File.stdout().writer(&buf) returns
// fs.File.Writer (File.zig:1552), a WRAPPER whose .interface field IS the std.Io.Writer. Pass &fw.interface.
var out_file = std.fs.File.stdout();
var buf: [4096]u8 = undefined;
var fw = out_file.writer(&buf);          // fs.File.Writer  (NOT std.Io.Writer)
defer fw.interface.flush() catch {};     // flush the inner std.Io.Writer
try renderGrid(alloc, ansi, size, colors, null, font, &fw.interface);   // &fw.interface is *std.Io.Writer

// CRITICAL — feed bytes ONE at a time to translate \n -> \r\n (matches tmux capture output + term2html).
// stream.nextSlice() exists but can't do the per-newline translation; use stream.next(c).
for (ansi) |c| { if (c == '\n') try stream.next('\r'); try stream.next(c); }

// color.Palette == [256]color.RGB (ghostty color.zig:48). So &colors.palette is *const color.Palette,
// which coerces to Options.palette (?*const color.Palette). No copy/conversion needed.

// size.CellCountInt == u16 (ghostty size.zig:22). render.Size{cols,rows: u16} matches Terminal.Options.

// Because Options.palette is set, palette colors emit as INLINE RGB (#rrggbb) — output is self-contained.
// The :root{--vt-palette-N} CSS block is only from TerminalFormatter (we do NOT use it; we use ScreenFormatter).

// Output is a <pre class="term2html-output"> FRAGMENT (term2html goldens compare this fragment), NOT a full
// <html><body> doc. Trailing blank rows trimmed (Options.trim defaults true).

// LAZY ghostty dep: once render.zig is wired into the exe path, `zig build` compiles ghostty-vt into the
// binary (expected — P1.M3's purpose). Tests already pull ghostty via palette.zig's import in main.zig's test block.
```

## Implementation Blueprint

### Data models and structure

```zig
// src/render.zig — types are tiny and ghostty-shaped; no bespoke ANSI state.
const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const Terminal = ghostty_vt.Terminal;
const Screen = ghostty_vt.Screen;
const Selection = ghostty_vt.Selection;
const fmt = @import("ghostty_format.zig");   // vendored: ScreenFormatter, Options, Format
const palette = @import("palette.zig");       // Colors, defaultColors()
const cli = @import("cli.zig");               // RenderOpts

/// Geometry for the virtual terminal. cols/rows are u16 to match ghostty size.CellCountInt exactly.
/// (cli.RenderOpts.cols/rows are ?u16; render.run maps opts -> Size.)
pub const Size = struct {
    cols: u16,
    rows: u16,
};
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: CREATE src/render.zig — the renderGrid primitive (THE deliverable; everything else consumes it)
  - IMPLEMENT: pub const Size{cols,rows: u16}
  - IMPLEMENT: pub fn renderGrid(alloc: std.mem.Allocator, ansi: []const u8, size: Size,
                 colors: palette.Colors, sel: ?Selection, font: ?[]const u8, out: *std.Io.Writer) !void
      1. var t = try Terminal.init(alloc, .{ .cols = size.cols, .rows = size.rows }); defer t.deinit(alloc);
      2. var stream = t.vtStream(); defer stream.deinit();
      3. for (ansi) |c| { if (c == '\n') try stream.next('\r'); try stream.next(c); }   // \n -> \r\n
      4. var f = fmt.ScreenFormatter.init(t.screens.active, .{
             .emit = .html,
             .background = colors.background,   // ?color.RGB
             .foreground = colors.foreground,   // ?color.RGB
             .palette = &colors.palette,        // *const [256]RGB -> ?*const color.Palette
             .font = font, });                  // ?[]const u8
      5. f.content = .{ .selection = sel };     // null = WHOLE grid (S1 always null)
      6. f.extra = .styles;                      // per-cell <span> styles + <a> hyperlinks
      7. try out.print("{f}", .{f});             // emit <pre class="term2html-output">…</pre>
  - FOLLOW: research/findings.md §1 pipeline + src/ghostty_format.zig ScreenFormatter.
  - GOTCHA: out is *std.Io.Writer (NOT fs.File). Callers create it (see Task 2 / tests).
  - GOTCHA: colors.palette MUST outlive the formatter use — it does (colors is a value param for renderGrid's body).
  - NAMING: renderGrid (camelCase, matches item contract). PLACEMENT: src/render.zig.

Task 2: IMPLEMENT pub fn run(alloc, opts: cli.RenderOpts) !u8 — the render subcommand body (stdin -> stdout)
  - 1. const stdin = std.fs.File.stdin();
        const ansi = try stdin.readToEndAlloc(alloc, MAX_STDIN);  // palette.zig already uses readToEndAlloc
        defer alloc.free(ansi);
    2. const colors = palette.defaultColors();   // S3 will wire palette.resolve(alloc, mode, hasControllingTty)
    3. const size = Size{ .cols = opts.cols orelse 80, .rows = opts.rows orelse 24 };  // S2 refines sizing
    4. var out_file = std.fs.File.stdout();
        var buf: [4096]u8 = undefined;
        var fw = out_file.writer(&buf);
        defer fw.interface.flush() catch {};
        try renderGrid(alloc, ansi, size, colors, null, opts.font, &fw.interface);
    5. return 0;
  - CONST: define MAX_STDIN (e.g. `1 << 28` ~256MiB, or reuse a shared constant) — generous, caller frees.
  - NOTE: deliberately ignores opts.palette_mode (S3), opts.output/--open (S2), opts.selection (S4).
    Passing opts.font through is fine (renderGrid already takes font). Document this explicitly in a comment.
  - FOLLOW: research/findings.md §3 (writer bridge) + §4 (stdin). NAMING: run. DEPENDENCIES: Task 1 + palette.zig + cli.zig.

Task 3: MODIFY src/cli.zig — wire render() to render.run (replace NotImplemented)
  - ADD: at top, `const render_mod = @import("render.zig");`  (name it to avoid clashing with the fn `render`)
  - MODIFY: in pub fn render(allocator, args), replace the `_ = opts; return error.NotImplemented;` block with:
        return render_mod.run(allocator, opts);
    KEEP the --help check and the parseRender/reportError block EXACTLY as-is.
  - GOTCHA: circular import cli.zig <-> render.zig is legal in Zig (lazy module resolution). parseRender stays
    pure/ghostty-free (the import is only to call run). This is the documented P1.M2 contract boundary.
  - PRESERVE: parseRender, all option structs, help text, other subcommand stubs (pane/region/syncPalette).

Task 4: MODIFY src/main.zig — make renderGrid tests reachable + fix the dispatch test
  - ADD inside the `test {}` block: `_ = @import("render.zig");` (alongside the existing `_ = @import("palette.zig");`).
  - MODIFY: the test "dispatch routes knownsubcommand to cli stub" — REMOVE the line asserting dispatch("render")
    returns NotImplemented (render is now implemented; calling it would read real stdin, which is wrong in a unit test).
    Keep assertions only for sibling subcommands that are STILL NotImplemented at impl time (pane, region; check
    sync-palette's status — P1.M2.T2.S1 runs in parallel and may have implemented it). If unsure, leave the test
    asserting NotImplemented only for `pane` and `region`.
  - PRESERVE: dispatch routing, printVersion/printHelp/usage_text, the DebugAllocator, version_string test.

Task 5: CREATE unit tests in src/render.zig (renderGrid via Allocating writer — NO /dev/tty, NO stdin)
  - PATTERN (VALIDATED — research/findings.md §3):
        var aw = try std.Io.Writer.Allocating.initCapacity(std.testing.allocator, 4096);
        defer aw.deinit();
        try renderGrid(std.testing.allocator, ansi, .{ .cols = 40, .rows = 5 }, palette.defaultColors(), null, "monospace", &aw.writer);
        const html = aw.writer.buffered();
  - TEST: red SGR -> html contains "<span style=" and ">red</span>" and a '#' hex color (do NOT hardcode the hex;
    defaultColors palette[1] is whatever Ghostty bundles). Input: "\x1b[31mred\x1b[0m".
  - TEST: bold SGR -> html contains "font-weight:bold". Input: "\x1b[1mbold\x1b[0m".
  - TEST: plain text -> html contains "<pre class=\"term2html-output\"" and the text, no <span>.
  - TEST: empty input -> html contains "<pre" and "</pre>" (no crash; trailing blanks trimmed).
  - TEST: truecolor -> html contains a "#rrggbb" span. Input: "\x1b[38;2;255;0;0mX\x1b[0m".
  - NAMING: test "renderGrid: red foreground emits styled span" etc. COVERAGE: color, attribute, plain, empty, truecolor.
  - GOTCHA: feed bytes as Zig string literals with \x1b (ESC). The \n->\r\n translation must not corrupt \x1b sequences.
  - GOTCHA: std.testing.allocator — renderGrid/Terminal must free everything (deinit t, stream). Verify no leaks.
```

### Implementation Patterns & Key Details

```zig
// renderGrid — the ONE primitive. Every future subcommand calls this (P2 pane, P3 region pass sel != null).
pub fn renderGrid(
    alloc: std.mem.Allocator,
    ansi: []const u8,
    size: Size,
    colors: palette.Colors,
    sel: ?Selection,            // S1 always null. S4 passes a Selection built from Pins.
    font: ?[]const u8,
    out: *std.Io.Writer,
) !void {
    var t = try Terminal.init(alloc, .{ .cols = size.cols, .rows = size.rows });
    defer t.deinit(alloc);

    var stream = t.vtStream();
    defer stream.deinit();
    for (ansi) |c| {
        if (c == '\n') try stream.next('\r');   // translate \n -> \r\n (term2html verified pattern)
        try stream.next(c);
    }

    var f = fmt.ScreenFormatter.init(t.screens.active, .{
        .emit = .html,
        .background = colors.background,
        .foreground = colors.foreground,
        .palette = &colors.palette,   // color.Palette == [256]RGB; &colors.palette is *const color.Palette
        .font = font,
    });
    f.content = .{ .selection = sel }; // null = whole grid
    f.extra = .styles;                  // per-cell spans + OSC-8 <a> links
    try out.print("{f}", .{f});         // {f} invokes f.format(*std.Io.Writer)
}

// run — stdin -> stdout, default colors. S2/S3/S4 extend the opts they honor here.
pub fn run(alloc: std.mem.Allocator, opts: cli.RenderOpts) !u8 {
    const stdin = std.fs.File.stdin();
    const ansi = try stdin.readToEndAlloc(alloc, MAX_STDIN); // File.zig:809
    defer alloc.free(ansi);

    const colors = palette.defaultColors(); // S3: palette.resolve(alloc, mode, palette.hasControllingTty())
    const size = Size{ .cols = opts.cols orelse 80, .rows = opts.rows orelse 24 }; // S2 refines

    var out_file = std.fs.File.stdout();
    var buf: [4096]u8 = undefined;
    var fw = out_file.writer(&buf);          // fs.File.Writer — .interface is the std.Io.Writer
    defer fw.interface.flush() catch {};
    try renderGrid(alloc, ansi, size, colors, null, opts.font, &fw.interface);
    return 0;
}
```

### Integration Points

```yaml
BUILD:
  - none. build.zig already exposes "ghostty-vt" (LAZY) + parg; min_zig 0.15.2. Wiring render into the exe path
    makes `zig build` compile ghostty-vt into the binary (expected).

CLI (src/cli.zig):
  - pub fn render: after parseRender succeeds, `return render_mod.run(allocator, opts);` (was NotImplemented).
  - import: `const render_mod = @import("render.zig");` at module top.

TEST ROOT (src/main.zig):
  - test {} block: add `_ = @import("render.zig");` next to `_ = @import("palette.zig");`.
  - update the dispatch test (drop the render->NotImplemented assertion).

PALETTE (src/palette.zig): consumed, not modified. defaultColors() + Colors struct.

FORMATTER (src/ghostty_format.zig): consumed, not modified. ScreenFormatter + Options (already has font).
```

## Validation Loop

### Level 1: Syntax & Style (immediate)

```bash
zig build                       # compiles exe; ghostty-vt now linked (P1.M3 purpose)
# Expected: success. Read any error (usually a type-coercion mismatch on the writer/palette) and fix.
```
(Zig has no separate lint step; `zig build` IS the type+compile gate. Common failure: passing `fw` instead of
`&fw.interface`, or `colors.palette` instead of `&colors.palette`.)

### Level 2: Unit Tests (renderGrid, via Allocating writer — no tty, no stdin)

```bash
zig build test
# Expected: all green, including the new renderGrid tests AND existing palette/cli/main tests. No leaks under
# std.testing.allocator (Terminal.deinit + stream.deinit must run — they're in `defer`).
```

### Level 3: Integration (the actual subcommand, stdin -> stdout)

```bash
# red span
printf '\033[31mred\033[0m' | zig build run -- render --cols 40
# Expected: <pre class="term2html-output" style="max-width: 40ch; background-color:#…; color:#…; font-family: monospace;">
#           <span style="color:#………;">red</span></pre>

# bold attribute
printf '\033[1mbold\033[0m' | zig build run -- render --cols 40 | grep -o 'font-weight:bold'

# truecolor
printf '\033[38;2;255;0;0mX\033[0m' | zig build run -- render --cols 40 | grep -o 'color:#ff0000;'

# OSC 8 hyperlink (optional, nice-to-have)
printf '\033]8;;https://example.com\033\\link\033]8;;\033\\' | zig build run -- render --cols 40 | grep -o 'href="https://example.com"'

# empty input (no crash)
printf '' | zig build run -- render --cols 40

# --rows honored (S2 owns defaults; S1 just passes opts.rows through if given)
printf 'hello\nworld\n' | zig build run -- render --cols 40 --rows 2 | grep -c 'hello'
```

### Level 4: Regression (don't break P1.M1/P1.M2)

```bash
zig build test                                                  # palette + cli tests still pass
zig build run -- --version | grep -q 'tmux-2html'               # version surface intact
zig build run -- render --help | grep -q -- '--cols N'          # help surface intact
zig build run -- sync-palette --help                            # sibling subcommand help intact
# Expected: all pass. If the main.zig dispatch test was updated correctly, no NotImplemented mismatch.
```

## Final Validation Checklist

### Technical Validation
- [ ] `zig build` succeeds (ghostty-vt compiled into the binary).
- [ ] `zig build test` green (new renderGrid tests + existing palette/cli/main tests; no allocator leaks).
- [ ] `renderGrid` signature is EXACTLY the contract: `(alloc, ansi, size, colors, sel, font, out: *std.Io.Writer) !void`.

### Feature Validation
- [ ] `printf '\033[31mred\033[0m' | zig build run -- render --cols 40` → HTML with a colored `<span>red</span>`.
- [ ] bold → `font-weight:bold`; truecolor → exact `#rrggbb`; empty input → no crash.
- [ ] `renderGrid` is reusable: takes `sel`/`font`/a `*std.Io.Writer` (S2/S3/S4 extend, don't rewrite).

### Scope Discipline (RESPECT sibling tasks)
- [ ] Did NOT implement `--palette` resolve (S3) — used `defaultColors()` only.
- [ ] Did NOT implement `--output`/`--open`/smart sizing defaults (S2) — minimal cols/rows fallback only.
- [ ] Did NOT implement `--selection` coordinate→Pin (S4) — `sel: null` only.
- [ ] Did NOT modify `src/ghostty_format.zig`, `src/palette.zig`, `build.zig`, or `build.zig.zon`.

### Code Quality
- [ ] Follows existing conventions: `std.fs.File.stdout()`/`stderr()` (as in main.zig), `@import("ghostty-vt")`,
      `_ = @import(...)` in main.zig test block, DEBUG-style comments documenting gotchas (as in palette.zig).
- [ ] `cli.parseRender` remains pure/ghostty-free; only the `render()` body now calls `render_mod.run`.
- [ ] Comments cite the research doc / source line numbers for non-obvious API choices (writer bridge, \n→\r\n).

---

## Anti-Patterns to Avoid

- ❌ Don't pass `fw` (fs.File.Writer) to the formatter — it wants `*std.Io.Writer` → use `&fw.interface`.
- ❌ Don't use `stream.nextSlice()` for the whole ansi blob — you MUST translate `\n`→`\r\n` per byte.
- ❌ Don't implement a bespoke ANSI/SGR parser — ghostty-vt owns all of it; `renderGrid` is glue.
- ❌ Don't construct `TerminalFormatter` (emits `:root` CSS) — `ScreenFormatter` + `opts.palette` gives self-contained inline RGB.
- ❌ Don't hardcode palette hex values in tests — `defaultColors()` palette is the Ghostty bundle; assert shape, not exact color.
- ❌ Don't read stdin inside a unit test or via `main.dispatch("render")` — test `renderGrid` through the Allocating writer.
- ❌ Don't expand scope into S2/S3/S4 (palette resolve, --output/--open, --selection). Minimal fallback only.
- ❌ Don't `@import("ghostty_format.zig")` expecting a `font` field to be missing — it's already there (vendored in P1.M1.T2.S1).

---

## Confidence Score: 9/10

All API signatures were read directly from ghostty v1.3.1 source and the Zig 0.15.2 stdlib, and the single
highest-risk piece (the new-IO `*std.Io.Writer` bridge: `fs.File.Writer.interface` + `Writer.Allocating`) was
**compile-validated** (`zig run` + `zig test`, 1/1 passed). The remaining 1/10 is ordinary implementation
friction (exact error-set inference, allocator cleanup in tests) — not architectural uncertainty.
