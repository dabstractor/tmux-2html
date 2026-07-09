name: "P1.M4.T2.S2 — Palette parse/serialize round-trip + selection sub-rectangle golden tests"
description: |

---

## Goal

**Feature Goal**: Complete the P1.M4.T2 golden/unit-test contract with two additions: (a) a
palette cache round-trip unit test proving a **non-default** `Colors` survives
`writeCacheDir → loadCacheDir` byte-for-byte (the existing P1.M2.T1.S2 test only round-trips
`defaultColors()`); and (b) two **golden** selection fixtures (`sel_linewise`, `sel_block`)
rendered with a fixed `--selection` and pinned byte-equal to committed `.html`, extending the
P1.M4.T2.S1 golden harness from whole-grid (`sel = null`) to sub-rectangle selection (linewise
+ block).

**Deliverable**:
- `testdata/sel_linewise.{ansi,html}` + `testdata/sel_block.{ansi,html}` — 4 new fixture files
  (authored `.ansi`, blessed `.html`).
- `testdata/embed.zig` — extended with a `SelFixture` struct + `sel_fixtures` array (additive;
  S1's `Fixture`/`fixtures` untouched).
- `src/golden_test.zig` — a SECOND `test` fn that `inline for (td.sel_fixtures)` renders each
  `.ansi` with its embedded geometry + coords and asserts `expectEqualStrings(html, got)`.
- `src/palette.zig` — one NEW `test` fn: `writeCacheDir → loadCacheDir` round-trip with a
  non-default `Colors` (mutated fg/bg + 3 palette entries), asserting field-equal.

**Success Definition**: `zig build test -Doptimize=ReleaseFast` exits 0 with BOTH new test fns
present and passing (the selection golden + the non-default palette round-trip), on top of the
S1 baseline that stays green. As with S1, a Debug-mode `R_X86_64_PC64` link failure is EXPECTED
(known toolchain bug, PRD §15) — ReleaseFast is the mandatory gate.

## User Persona (if applicable)

**Target User**: The project maintainer / future contributor (and CI).

**Use Case**: Regression protection for the two pieces of state not yet pinned by golden tests:
(1) the palette cache serializer/parser contract (any change to `serialize`/`parse`/the PRD §6
plain-text format is caught), and (2) the `--selection` sub-rectangle geometry (any change to
`buildSelection`, `Selection.init`, or the formatter's selection-region emission is caught).

**User Journey**: A contributor bumps `ghostty-vt` or tweaks `serialize` → runs
`zig build test -Doptimize=ReleaseFast` → the selection golden or palette round-trip fails
naming the culprit fixture/field → they re-bless or fix, re-run, green.

**Pain Points Addressed**: PRD §15 explicitly lists "selection sub-rectangles (linewise +
block)" and "palette parse/serialize" as required unit/golden cases. S1 covered the whole-grid
color/attr/OSC8 golden cases but deliberately deferred these two (S1 PRP anti-patterns: "Don't
add selection/palette goldens here — that's P1.M4.T2.S2's scope"). This PRP closes that gap.

## Why

- **PRD §15 compliance.** The testing strategy section names both cases verbatim: golden
  "selection sub-rectangles (linewise + block)" and unit "palette parse/serialize". S1 landed
  the harness + the color/attr/OSC8 cases; this item lands the remaining two named cases so the
  P1.M4.T2 milestone is genuinely "green + complete", not "green with coverage gaps".
- **Pin selection geometry, not just presence.** render.zig's existing inline selection unit
  tests (P1.M4.T1.S1) assert `indexOf != null` / `== null` — substring presence, NOT exact
  bytes. They would pass even if the formatter emitted extra blank rows, wrong column slicing,
  or mis-ordered cells. A byte-equal golden pins the EXACT sub-rectangle, catching regressions
  the substring tests can't.
- **Strengthen the palette round-trip beyond defaults.** The existing round-trip uses
  `defaultColors()` — a coincidental bug (e.g. `serialize` dropping the `fg`/`bg` lines, or
  `parse` ignoring indices > 127) could still pass if defaults happen to round-trip. A
  non-default `Colors` with distinctive values in fg/bg and scattered palette indices makes any
  serialization drift fail loudly.
- **Foundation for P2/P3.** Every P2 (`pane`) / P3 (`region`) subcommand reduces to
  `renderGrid(…, sel, …)`. A green selection golden proves the selection primitive is byte-
  stable, so downstream work can rely on it.

## What

Two test fns + four fixture files, all gated by `zig build test -Doptimize=ReleaseFast`:

1. **Palette round-trip unit test** (`src/palette.zig`): build a `Colors` mutated away from
   `defaultColors()` (distinct fg, distinct bg, distinct values at palette indices 0/100/255),
   `writeCacheDir(tmp.dir, "palette", …)`, then `loadCacheDir(tmp.dir, "palette", …)`, and
   assert the loaded `Colors` is field-equal to the written one (`palette` array slice, fg, bg,
   `palette_received_count`). Uses `std.testing.tmpDir` (no real `$HOME`/`$XDG_CACHE_HOME`).

2. **Selection golden test** (`src/golden_test.zig`, NEW second `test` fn): for each entry in
   `testdata/embed.zig`'s new `sel_fixtures` array, feed the embedded `.ansi` into `renderGrid`
   at the fixture's `.{cols, rows}` with `palette.defaultColors()`, the fixture's embedded
   `SelectionCoords`, `font = null`, into an `std.Io.Writer.Allocating`, and assert
   `expectEqualStrings(embedded_html, rendered)`. The `.html` is **blessed from this binary**
   (`render --cols N --rows M --palette default --selection X1,Y1,X2,Y2[,rect]`), byte-equal to
   the test path by the same argument S1 used.

### Success Criteria

- [ ] `testdata/sel_linewise.{ansi,html}` + `testdata/sel_block.{ansi,html}` exist (4 files).
- [ ] `testdata/embed.zig` adds `SelFixture` + a 2-entry `sel_fixtures` array; S1's `fixtures`
      array is UNCHANGED.
- [ ] `src/golden_test.zig` has a second `test` fn iterating `td.sel_fixtures` with byte-equal
      assertions + fixture-name/byte-count mismatch diagnostics.
- [ ] `src/palette.zig` has a new `test` fn: non-default `Colors` round-trips through
      `writeCacheDir`/`loadCacheDir` field-equal.
- [ ] `zig build test -Doptimize=ReleaseFast` exits 0 with both new test fns present.
- [ ] Coverage confirmed: linewise (full-row, styling preserved, excluded rows absent) + block
      (column sub-rectangle across rows) both pinned byte-equal.

## All Needed Context

### Context Completeness Check

_"If someone knew nothing about this codebase, would they have everything needed to implement
this successfully?"_ **Yes** — this PRP includes the exact `renderGrid` signature, the exact
selection coords + geometry for both fixtures, the verified bless commands (with the exact
bytes they produce), the embed-structure extension, the exact insertion points, the verified
anonymous-literal-to-`?SelectionCoords` coercion, and the explicit reason the PUBLIC
`writeCache`/`loadCache` are not directly unit-tested (so the implementer doesn't waste time on
the XDG/setenv dead end).

### Documentation & References

```yaml
# MUST READ — the sibling PRP that BUILT the harness you are extending
- docfile: plan/001_0c8587f91cb2/P1M4T2S1/PRP.md
  why: "S1 landed the golden harness THIS item extends. Its embed-module solution (@embedFile
        confined to a package root => testdata/embed.zig roots testdata/), its bless-from-binary
        discipline, its font-null==monospace equivalence, and its ReleaseFast-only gate are ALL
        inherited unchanged."
  section: "Implementation Tasks (Task 3 embed.zig, Task 4 build.zig, Task 5 golden_test.zig) +
            Known Gotchas"
  critical: "S1 already wired build.zig (testdata module) + main.zig (golden_test import). S2
             does NOT touch build.zig / main.zig / build.zig.zon — only EXTENDS embed.zig and
             golden_test.zig, and adds a test fn to palette.zig."

# MUST READ — the empirical ground truth for THIS task (every claim rendered/built in-tree)
- docfile: plan/001_0c8587f91cb2/P1M4T2S2/research/findings.md
  why: "Verified facts: §0 (S1 baseline green), §1 (multiple renderGrid test fns safe in
        ReleaseFast), §2 (anon literal -> ?SelectionCoords), §3 (bless workflow byte-stable),
        §4 (palette round-trip state + why public writeCache/loadCache untestable), §5 (embed
        extension), §6 (recommended fixtures)."
  section: "§3 (the two blessed outputs to sanity-check against) + §4 (palette test design)"

# THE PRIMITIVE UNDER TEST — selection path
- file: src/render.zig
  why: "renderGrid is what both golden tests call. buildSelection (sel=coords branch) is the
        selection construction path being pinned. Its existing inline selection tests (LINEWISE,
        BLOCK, OUT-OF-RANGE) show the assertion SHAPE — but those are substring checks; the
        golden is the byte-equal upgrade."
  pattern: "try renderGrid(alloc, ansi, .{ .cols, .rows }, palette.defaultColors(),
            .{ .x1=.., .y1=.., .x2=.., .y2=.., .rect=.. }, null, &aw.writer);  // anon literal
            coerces to ?cli.SelectionCoords (render.zig out-of-range test does exactly this)"
  gotcha: "pass font: null (NOT \"monospace\") to mirror the no---font bless command — the two
           are byte-identical (formatter: opts.font orelse \"monospace\") but null is the exact
           mirror of the binary path. defaultColors() only — NEVER palette.resolve() in a test."

# THE PRIMITIVE UNDER TEST — palette cache path
- file: src/palette.zig
  why: "writeCacheDir / loadCacheDir / serialize / parse / defaultColors are the round-trip
        surface. The EXISTING 'writeCacheDir + loadCacheDir disk round-trip' test (defaultColors
        only) is the pattern to mirror — but mutate the Colors to a non-default for rigor."
  pattern: "var orig = defaultColors(); orig.background = .{.r=1,.g=2,.b=3}; orig.palette[0]=…;
            try writeCacheDir(tmp.dir, \"palette\", alloc, orig);
            const got = try loadCacheDir(tmp.dir, \"palette\", alloc);
            try expectEqualSlices(color.RGB, &orig.palette, &got.palette); …"
  gotcha: "Do NOT call the PUBLIC writeCache/loadCache in a test — they read $XDG_CACHE_HOME/$HOME
           via cachePath() and Zig has no setenv (palette.zig GOTCHA 5). They'd either error in a
           stripped CI env or write the REAL ~/.cache/tmux-2html/palette. The dir-scoped pair they
           delegate to is the canonical round-trip. palette.zig tests never touch Terminal.init =>
           not subject to the cross-test GOTCHA."

# THE HARNESS FILE TO EXTEND — copy its idiom verbatim, add a second test fn
- file: src/golden_test.zig
  why: "S1's golden test is the EXACT template for the selection golden test (same Allocating-
        writer pattern, same mismatch diagnostic, same td import). Add the selection test as a
        SECOND `test` fn in the same file (verified safe in ReleaseFast, findings §1)."
  pattern: "inline for (td.sel_fixtures) |fx| { var aw = …; defer aw.deinit();
            try render.renderGrid(…, .{.cols=fx.cols,.rows=fx.rows}, palette.defaultColors(),
            .{.x1=fx.x1,.y1=fx.y1,.x2=fx.x2,.y2=fx.y2,.rect=fx.rect}, null, &aw.writer);
            expectEqualStrings(fx.html, aw.writer.buffered()) catch {name+counts}; }"

# THE EMBED MANIFEST TO EXTEND — additive, S1's fixtures untouched
- file: testdata/embed.zig
  why: "S1's Fixture/fixtures live here. Add a SelFixture struct (needs per-fixture geometry +
        coords) and a sel_fixtures array. @embedFile reaches the sibling .ansi/.html because this
        file roots the testdata/ package (S1's @embedFile solution)."
  pattern: "pub const SelFixture = struct { name, ansi, html, cols:u16, rows:u16,
            x1:u32, y1:u32, x2:u32, y2:u32, rect:bool };
            pub const sel_fixtures = [_]SelFixture{ .{…@embedFile(\"sel_linewise.ansi\")…}, … };"

# THE CLI TYPES the selection golden builds (anon literal resolves to this)
- file: src/cli.zig
  why: "SelectionCoords = struct { x1,y1,x2,y2: u32, rect: bool = false } (lines ~50-58). The
        embed's u32 fields map 1:1. renderGrid takes ?cli.SelectionCoords; the anon literal
        coerces (findings §2, proven by render.zig's out-of-range test)."

# THE BINARY used to bless goldens — confirms the --selection flag spelling
- file: src/cli.zig
  why: "parseSelection (X1,Y1,X2,Y2[,rect]; rect=1 → block) + parseRender wire --selection.
        Confirms the exact bless-command flag spelling and that rect=1 ⇒ block."
  pattern: "render --cols N --rows M --palette default --selection X1,Y1,X2,Y2[,rect] < in.ansi > out.html"
```

### Current Codebase tree (relevant subset — S1's output is already landed)

```bash
src/
  main.zig            # top-level `test {}` block (lines ~253-262) — UNCHANGED (S1 wired golden_test)
  render.zig          # renderGrid() + buildSelection() + inline selection unit tests — UNCHANGED
  palette.zig         # serialize/parse/writeCacheDir/loadCacheDir + round-trip tests — ADD 1 test fn
  cli.zig             # SelectionCoords + parseSelection + parseRender — UNCHANGED
  golden_test.zig     # S1's whole-grid golden test — ADD a 2nd test fn (selection goldens)
  ghostty_format.zig  # vendored formatter — UNCHANGED
build.zig             # testdata module ALREADY wired (S1) — UNCHANGED
build.zig.zon         # .paths lists "testdata" — UNCHANGED
testdata/
  embed.zig           # S1's Fixture + fixtures — ADD SelFixture + sel_fixtures
  {8 S1 fixtures}.{ansi,html}   # UNCHANGED
  sel_linewise.ansi   # NEW — authored
  sel_linewise.html   # NEW — blessed
  sel_block.ansi      # NEW — authored
  sel_block.html      # NEW — blessed
```

### Desired Codebase tree with files to be added/modified

```bash
testdata/
  embed.zig           # MODIFIED — +SelFixture struct +sel_fixtures array (2 entries)
  sel_linewise.ansi   # NEW — colored rows R0..R4
  sel_linewise.html   # NEW — blessed (rows 1..3 selected)
  sel_block.ansi      # NEW — distinct-content 3×10 grid
  sel_block.html      # NEW — blessed (cols 2..5, rows 0..2, rect)
src/
  golden_test.zig     # MODIFIED — +1 test fn (selection golden: inline for sel_fixtures)
  palette.zig         # MODIFIED — +1 test fn (non-default Colors round-trip)
# build.zig, build.zig.zon, src/main.zig: NO CHANGES (S1 already wired the harness)
```

### Known Gotchas of our codebase & Library Quirks

```zig
// CRITICAL: `zig build test` (Debug) FAILS to LINK — Zig 0.15.2 emits R_X86_64_PC64 relocations
// for the bundled C++ SIMD libs (PRD §15). ReleaseFast is the ONLY gate:
//   zig build test -Doptimize=ReleaseFast   (verified EXIT 0 on the S1 baseline)
// A Debug link failure is NOT a defect in your work.

// CRITICAL: a SECOND renderGrid-calling test fn is SAFE in ReleaseFast. The render.zig
// "cross-test GOTCHA" comment (Terminal.init corrupts process-global state across separate test
// fns) is Debug-only. Empirically the current suite already runs TWO renderGrid test fns
// (render.zig mega-test + golden_test.zig) green under ReleaseFast (findings §0/§1). Adding the
// selection golden as a 3rd test fn in golden_test.zig is therefore safe. (Fallback if it ever
// crashed: merge the selection loop into S1's single golden test fn — same scope. Not needed.)

// CRITICAL: do NOT call the PUBLIC palette.writeCache / palette.loadCache in a test. They resolve
// the cache path via cachePath() → getenv("XDG_CACHE_HOME")/getenv("HOME"); Zig std has NO setenv
// (palette.zig GOTCHA 5), so you cannot redirect them to a tmpDir. Testing them either errors in a
// stripped CI env (no $HOME) or writes the REAL ~/.cache/tmux-2html/palette — a forbidden side
// effect. They are 4-line wrappers (cachePath + openDirAbsolute + delegate to writeCacheDir/
// loadCacheDir). The dir-scoped pair IS the round-trip; test THAT via std.testing.tmpDir.

// CRITICAL: pass font: null to renderGrid in the selection golden (NOT the literal "monospace").
// The bless command omits --font => binary uses opts.font="monospace"; the formatter does
// `opts.font orelse "monospace"` => both emit `font-family: monospace` (byte-identical). null is
// the exact mirror of the binary's effective path. Confirmed in the blessed outputs (findings §3).

// GOTCHA: the anonymous struct literal .{ .x1=.., .y1=.., .x2=.., .y2=.., .rect=.. } coerces
// directly to renderGrid's ?cli.SelectionCoords param — render.zig's out-of-range test already
// passes exactly such a literal (findings §2). No `cli.SelectionCoords{}` qualifier needed.

// GOTCHA: only call palette.defaultColors() in the tests (NEVER palette.resolve()). resolve() may
// read the cache or probe /dev/tty = non-deterministic. Bless with --palette default to force
// defaultColors() deterministically (no tty/cache). defaultColors() is pure.

// GOTCHA: linewise selection (rect omitted/false) selects FULL rows y1..y2 (x1..x2 may span the
// full grid width — pass x1=0, x2=cols-1). Block selection (rect=true/1) selects the RECTANGLE
// x1..x2 × y1..y2: each selected row emits ONLY the column slice [x1..x2]. (findings §3.)

// GOTCHA: renderGrid's sel coords are CELL INDICES, origin top-left, x=column y=row. For a fresh
// terminal sized to the input there is no scrollback, so row 0 == the first input line. Selecting
// past the last WRITTEN row (or x >= cols) returns error.OutOfRange from renderGrid (buildSelection
// → pages.pin returns null). Keep selection within the fixture's written grid.

// GOTCHA: the embed's u32 fields (x1..y2) map onto cli.SelectionCoords (also u32) — no cast needed.
// buildSelection itself guards x > maxInt(u16) before its internal @intCast; the recommended
// fixtures use small cols (10/20) so this never triggers.
```

## Implementation Blueprint

### Data models and structure

No new RUNTIME data models. The only new types are compile-time embed entries + test fixtures:

```zig
// testdata/embed.zig — ADD (S1's Fixture/fixtures stay verbatim above this)
pub const SelFixture = struct {
    name: []const u8,
    ansi: []const u8,
    html: []const u8,
    cols: u16,
    rows: u16,
    x1: u32,
    y1: u32,
    x2: u32,
    y2: u32,
    rect: bool,
};

pub const sel_fixtures = [_]SelFixture{
    .{ .name = "sel_linewise", .ansi = @embedFile("sel_linewise.ansi"), .html = @embedFile("sel_linewise.html"),
        .cols = 20, .rows = 5, .x1 = 0, .y1 = 1, .x2 = 19, .y2 = 3, .rect = false },
    .{ .name = "sel_block", .ansi = @embedFile("sel_block.ansi"), .html = @embedFile("sel_block.html"),
        .cols = 10, .rows = 3, .x1 = 2, .y1 = 0, .x2 = 5, .y2 = 2, .rect = true },
};
```

The selection golden test consumes `td.sel_fixtures`; the palette round-trip test builds its own
non-default `Colors` inline. All `.ansi`/`.html` bytes are baked in at compile time via
`@embedFile` (zero runtime I/O, zero CWD sensitivity) — exactly S1's mechanism.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: AUTHOR the 2 testdata/*.ansi selection fixtures (EXACT bytes)
  - Run these printf commands from the repo root (each ends with a trailing newline for
    deterministic row structure; bytes verified to render correctly — findings §3):
      printf '\033[31mR0\033[0m\n\033[32mR1\033[0m\n\033[33mR2\033[0m\n\033[34mR3\033[0m\n\033[35mR4\033[0m\n' > testdata/sel_linewise.ansi
      printf '0123456789\nABCDEFGHIJ\nabcdefghij\n' > testdata/sel_block.ansi
  - sel_linewise: 5 colored rows (SGR 31..35 = red/green/yellow/blue/magenta) R0..R4. The selection
    (rows 1..3) will pin that full-row selection preserves per-row styling AND excludes R0/R4.
  - sel_block: 3 distinct-content rows; selecting cols 2..5 yields 2345 / CDEF / cdef, pinning the
    column sub-rectangle across all selected rows unambiguously.
  - VERIFY the OSC/SGR bytes survived (especially that \033 is a real ESC, not literal backslash):
      cat -v testdata/sel_linewise.ansi   # expect ^[[31mR0^[[0m ... (^[ == ESC)
  - GOTCHA: a literal "\033" in the file (two chars: backslash, zero, three, three) would render
    as visible text, not color. printf interprets \033 as ESC (byte 0x1b); cat -v shows ^[.

Task 2: BUILD the binary, then BLESS the 2 testdata/*.html expected outputs
  - BUILD first (ReleaseFast — the mode tests run in):
      zig build -Doptimize=ReleaseFast
  - BLESS each .html from the binary WITH the selection coords + geometry, forcing default palette:
      ./zig-out/bin/tmux-2html render --cols 20 --rows 5  --palette default --selection 0,1,19,3   < testdata/sel_linewise.ansi > testdata/sel_linewise.html
      ./zig-out/bin/tmux-2html render --cols 10 --rows 3  --palette default --selection 2,0,5,2,1  < testdata/sel_block.ansi    > testdata/sel_block.html
  - WHY THIS IS BYTE-EQUAL TO THE TEST: the binary's --selection branch calls exactly
    renderGrid(alloc, ansi, .{cols,rows}, resolve(.default)=defaultColors(), coords, opts.font,
    &aw.writer) — identical args to the test (testing.allocator vs gpa is output-irrelevant;
    "monospace" vs null is byte-identical per the formatter). VERIFIED (findings §3): linewise
    yields R1/R2/R3 colored spans (R0/R4 absent); block yields "2345\nCDEF\ncdef".
  - SANITY-CHECK the blessed outputs (must match findings §3 byte-for-byte):
      cat testdata/sel_linewise.html   # <pre ...max-width: 20ch...>...R1..R2..R3...</pre> (no R0/R4)
      cat testdata/sel_block.html      # <pre ...max-width: 10ch...>2345\nCDEF\ncdef</pre>
  - GOTCHA: --rows must match the test's rows (the embed carries rows=5/3). The binary computes
    rows = opts.rows orelse lineCount(ansi); passing --rows explicitly pins it. --palette default
    forces defaultColors() (no tty/cache nondeterminism). Omit --font (null-equivalent).

Task 3: MODIFY testdata/embed.zig — add the SelFixture manifest (additive)
  - APPEND the SelFixture struct + sel_fixtures array (see "Data models" above — copy verbatim).
  - S1's existing `Fixture` struct + `fixtures` array MUST stay unchanged above the new code.
  - FILE LIVES IN testdata/ (its root IS the package; @embedFile("sel_block.ansi") resolves to the
    sibling — S1's verified @embedFile solution).
  - DEPENDENCIES: the .ansi/.html files from Tasks 1-2 MUST exist (else @embedFile is a COMPILE
    error naming the path — a missing fixture fails at compile time, not runtime).

Task 4: MODIFY src/golden_test.zig — add the selection golden test (2nd test fn)
  - APPEND a SECOND `test` fn (see "Implementation Patterns" below — copy verbatim). It
    `inline for (td.sel_fixtures)` renders each fixture with its embedded geometry + coords and
    asserts expectEqualStrings(fx.html, aw.writer.buffered()).
  - ON MISMATCH: print the fixture name + expected/got byte counts BEFORE returning the error
    (mirrors S1's diagnostic — a raw expectEqualStrings dumps the whole HTML).
  - IMPORTS: reuse the file's existing `const std / render / palette / td` (S1 already imports
    them). No new imports.
  - DEPENDENCIES: Task 3 (sel_fixtures) must be in place first.
  - WHY a separate test fn is safe: findings §1 — the current suite runs 2 renderGrid test fns
    green in ReleaseFast; a 3rd is fine.

Task 5: MODIFY src/palette.zig — add the non-default round-trip test
  - APPEND a new `test` fn (see "Implementation Patterns" below — copy verbatim): build a
    non-default Colors (mutated fg/bg + palette[0]/[100]/[255]), writeCacheDir → loadCacheDir via
    std.testing.tmpDir, assert field-equal (palette slice, fg, bg, palette_received_count) +
    spot-check the mutated entries.
  - PLACE among the existing cache-I/O tests (after the "writeCacheDir + loadCacheDir disk
    round-trip" test, which it strengthens).
  - WHY this satisfies contract (a): the public writeCache/loadCache are XDG wrappers untestable
    without setenv (GOTCHA above); the dir-scoped core they delegate to IS the round-trip. This
    test proves ARBITRARY values survive (not just defaults), which is the contract's intent.
  - palette.zig tests never touch Terminal.init => NOT subject to the cross-test GOTCHA.

Task 6: RUN the gate and confirm both new test fns ran + passed
  - zig build test -Doptimize=ReleaseFast    # MUST exit 0
  - Confirm BOTH new tests ran (see Validation Loop Level 2 for the exact check).
```

### Implementation Patterns & Key Details

```zig
// ===== src/golden_test.zig — APPEND this as a SECOND test fn (after S1's golden test) =====
//! Selection golden: testdata/sel_*.ansi rendered WITH a fixed --selection (linewise + block)
//! must be byte-equal to the committed sel_*.html (P1.M4.T2.S2). Extends the S1 whole-grid
//! golden (sel=null) to sub-rectangle selection. The .html is blessed from this binary
//! (`render --cols N --rows M --palette default --selection X1,Y1,X2,Y2[,rect]`); the embedded
//! cols/rows/coords in sel_fixtures EXACTLY match the bless command, so test == binary bytes.
//!
//! Separate test fn is safe in ReleaseFast: the documented cross-test GOTCHA is Debug-only
//! (findings §1; the suite already runs 2 renderGrid test fns green). font=null mirrors the
//! no---font bless (formatter: opts.font orelse "monospace" => byte-identical).
test "golden: --selection fixtures render byte-equal (linewise + block)" {
    inline for (td.sel_fixtures) |fx| {
        var aw = try std.Io.Writer.Allocating.initCapacity(std.testing.allocator, 1 << 16);
        defer aw.deinit();
        try render.renderGrid(
            std.testing.allocator,
            fx.ansi,
            .{ .cols = fx.cols, .rows = fx.rows },
            palette.defaultColors(),
            .{ .x1 = fx.x1, .y1 = fx.y1, .x2 = fx.x2, .y2 = fx.y2, .rect = fx.rect }, // -> ?cli.SelectionCoords
            null, // font: null => formatter defaults "monospace" (matches the no---font bless cmd)
            &aw.writer,
        );
        const got = aw.writer.buffered();
        std.testing.expectEqualStrings(fx.html, got) catch |err| {
            std.debug.print(
                "\n[golden] sel fixture '{s}' mismatch ({s}): expected {d} bytes, got {d} bytes\n",
                .{ fx.name, @errorName(err), fx.html.len, got.len },
            );
            return err;
        };
    }
}
```

```zig
// ===== src/palette.zig — APPEND among the cache-I/O tests =====
// Rigorous round-trip: a Colors with ARBITRARY mutated values (not just the bundled defaults)
// must survive serialize -> write -> read -> parse field-for-field. Strengthens the existing
// default-only "writeCacheDir + loadCacheDir disk round-trip" test (P1.M2.T1.S2). The PUBLIC
// writeCache/loadCache are XDG-path wrappers (cachePath -> getenv) that can't be unit-tested
// without env mutation (no setenv in std — palette.zig GOTCHA 5); they delegate to this dir-
// scoped core, so this IS the canonical round-trip. palette.zig tests never touch Terminal.init
// => not subject to the cross-test GOTCHA.
test "writeCacheDir -> loadCacheDir round-trip preserves a NON-DEFAULT Colors" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A Colors deliberately unlike defaultColors() so a serialization bug (dropped fg/bg,
    // ignored high indices, off-by-one) can't pass by coincidental default equality.
    var orig = defaultColors();
    orig.foreground = .{ .r = 200, .g = 100, .b = 50 };
    orig.background = .{ .r = 1, .g = 2, .b = 3 };
    orig.palette[0] = .{ .r = 9, .g = 9, .b = 9 };
    orig.palette[100] = .{ .r = 250, .g = 240, .b = 230 };
    orig.palette[255] = .{ .r = 11, .g = 22, .b = 33 };
    orig.palette_received_count = 256; // serialize writes all 256 index lines regardless

    try writeCacheDir(tmp.dir, "palette", alloc, orig);
    const got = try loadCacheDir(tmp.dir, "palette", alloc);

    // Full field-equal round-trip.
    try std.testing.expectEqualSlices(color.RGB, &orig.palette, &got.palette);
    try std.testing.expectEqual(orig.foreground, got.foreground);
    try std.testing.expectEqual(orig.background, got.background);
    try std.testing.expectEqual(@as(u16, 256), got.palette_received_count);

    // Spot-check the mutated entries survived (not coincidentally equal to defaults).
    try std.testing.expectEqual(color.RGB{ .r = 9, .g = 9, .b = 9 }, got.palette[0]);
    try std.testing.expectEqual(color.RGB{ .r = 250, .g = 240, .b = 230 }, got.palette[100]);
    try std.testing.expectEqual(color.RGB{ .r = 11, .g = 22, .b = 33 }, got.palette[255]);
    try std.testing.expectEqual(color.RGB{ .r = 200, .g = 100, .b = 50 }, got.foreground.?);
    try std.testing.expectEqual(color.RGB{ .r = 1, .g = 2, .b = 3 }, got.background.?);
}
```

**Blessed-output reference (sanity-check your Task-2 output against these EXACT bytes):**
```
# testdata/sel_linewise.html  (rows 1..3 of the 5 colored rows; R0/R4 excluded):
<pre class="term2html-output" style="max-width: 20ch; background-color: #292c33;color: #c5c8c6;font-family: monospace;"><span style="color: #b5bd68;">R1</span>
<span style="color: #f0c674;">R2</span>
<span style="color: #81a2be;">R3</span></pre>

# testdata/sel_block.html  (cols 2..5 = chars at index 2,3,4,5; rows 0..2):
<pre class="term2html-output" style="max-width: 10ch; background-color: #292c33;color: #c5c8c6;font-family: monospace;">2345
CDEF
cdef</pre>
```
(Row colors derive from the Ghostty bundled palette: SGR 32→#b5bd68, 33→#f0c674, 34→#81a2be.
Rows are separated by a literal `\n`; the `<pre>` uses whitespace:pre. These are deterministic
under defaultColors() and are what your blessed files MUST contain.)

### Integration Points

```yaml
EMBED MANIFEST (testdata/embed.zig):
  - add: "a SelFixture struct + a 2-entry sel_fixtures array (sel_linewise, sel_block)"
  - pattern: "pub const sel_fixtures = [_]SelFixture{ .{…@embedFile(\"sel_linewise.ansi\")…}, … };"
  - preserve: "S1's Fixture struct + fixtures array MUST stay verbatim above the new code"

GOLDEN HARNESS (src/golden_test.zig):
  - add: "a SECOND `test` fn iterating td.sel_fixtures (byte-equal expectEqualStrings + diagnostics)"
  - pattern: "mirror S1's test fn EXACTLY (same Allocating-writer, same mismatch catch), but pass
              the embedded coords + geometry instead of sel=null + fixed 120×150"
  - imports: "reuse the file's existing const std/render/palette/td (S1 already imports them)"

PALETTE TESTS (src/palette.zig):
  - add: "a new `test` fn: non-default Colors writeCacheDir->loadCacheDir round-trip (field-equal)"
  - placement: "among the existing cache-I/O tests (after the default-only round-trip test)"
  - preserve: "all existing palette tests + the serialize/parse/writeCacheDir/loadCacheDir logic"

BUILD (build.zig) / PACKAGE (build.zig.zon) / TEST ROOT (src/main.zig):
  - NO CHANGE — S1 already wired the testdata module + the golden_test.zig import. The new test
    fns are pulled in automatically (palette.zig + golden_test.zig are already imported).
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# After authoring the .ansi, blessing the .html, and editing embed.zig/golden_test.zig/palette.zig:
zig build -Doptimize=ReleaseFast            # prod build must still succeed
zig build test -Doptimize=ReleaseFast       # the GATE — see Level 2
# Expected: both succeed, exit 0. A Debug-mode R_X86_64_PC64 link error is EXPECTED (PRD §15),
# NOT a defect. If ReleaseFast fails to COMPILE, the most likely cause is a missing testdata/
# sel_*.ansi or .html referenced by embed.zig (@embedFile of a nonexistent file is a COMPILE
# error naming the path) — author/bless it (Tasks 1-2). A type mismatch in the anon-literal
# coords would also be a compile error (verify field names match cli.SelectionCoords).
```

### Level 2: Unit Tests (Component Validation)

```bash
# The gate. MUST exit 0.
zig build test -Doptimize=ReleaseFast

# Confirm BOTH new test fns actually RAN (not silently skipped). Run the compiled test binary
# directly and grep for both names:
.find .zig-cache -name 'test' -type f -newermt '-5 minutes' 2>/dev/null | head -1 \
  | xargs -r ./ 2>/dev/null | grep -iE 'golden.*selection|palette.*round-trip|non-default' || \
  ( echo "build the test runner list:"; \
    zig build test -Doptimize=ReleaseFast --summary all 2>&1 | grep -iE 'golden|round-trip|palette' | head )

# Expected: lines naming the selection golden test + the palette round-trip test, and
# "All N tests passed" with no failures. If a selection golden FAILS, the [golden] sel fixture
# '<name>' mismatch line names the culprit — re-bless THAT fixture (Task 2) and re-run.
```

### Level 3: Integration Testing (System Validation)

```bash
# Prove binary --selection output == renderGrid output (the byte-equality underpinning the goldens):
# bless a fixture, then re-render it — bytes must be stable across runs.
./zig-out/bin/tmux-2html render --cols 20 --rows 5 --palette default --selection 0,1,19,3 \
  < testdata/sel_linewise.ansi | diff - testdata/sel_linewise.html && echo "STABLE: linewise golden"
./zig-out/bin/tmux-2html render --cols 10 --rows 3 --palette default --selection 2,0,5,2,1 \
  < testdata/sel_block.ansi | diff - testdata/sel_block.html && echo "STABLE: block golden"

# Prove the selection GEOMETRY is correct (linewise excludes unselected rows; block is a column slice):
grep -c 'R0' testdata/sel_linewise.html   # expect 0 (R0 excluded from rows 1..3)
grep -qo '>R1</span>' testdata/sel_linewise.html && echo "linewise kept R1 (styled)"
grep -q '2345' testdata/sel_block.html && grep -q 'CDEF' testdata/sel_block.html \
  && grep -q 'cdef' testdata/sel_block.html && echo "block kept the column slice across rows"
grep -vq 'ABCDEFGHIJ' testdata/sel_block.html; echo "block has no full row (exit $?)"

# Prove S1's whole-grid golden is UNAFFECTED (no regression from extending the harness):
zig build test -Doptimize=ReleaseFast 2>&1 | grep -qi 'fail' && echo "REGRESSION" || echo "S1 green too"
# Expected: STABLE both, geometry checks pass, no regression.
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Coverage audit — confirm BOTH selection modes are pinned byte-equal (PRD §15: linewise + block):
for n in sel_linewise sel_block; do
  test -f testdata/$n.ansi && test -f testdata/$n.html && echo "OK  $n" || echo "MISSING $n"
done

# Spot-check the blessed outputs contain the expected signals (sanity, not assertion):
grep -q 'max-width: 20ch'        testdata/sel_linewise.html && echo "linewise size OK"
grep -q 'max-width: 10ch'        testdata/sel_block.html    && echo "block size OK"
grep -q 'font-family: monospace' testdata/sel_linewise.html && echo "font (null==monospace) OK"
grep -q 'color: #b5bd68'         testdata/sel_linewise.html && echo "linewise kept palette styling OK"
grep -q '2345'                   testdata/sel_block.html    && echo "block column slice OK"

# Refresh workflow (whenever renderGrid/buildSelection/ghostty_format/Selection changes and the
# selection goldens must move):
#   zig build -Doptimize=ReleaseFast
#   ./zig-out/bin/tmux-2html render --cols 20 --rows 5  --palette default --selection 0,1,19,3   < testdata/sel_linewise.ansi > testdata/sel_linewise.html
#   ./zig-out/bin/tmux-2html render --cols 10 --rows 3  --palette default --selection 2,0,5,2,1  < testdata/sel_block.ansi    > testdata/sel_block.html
#   zig build test -Doptimize=ReleaseFast   # green again
# Commit BOTH the .ansi and the regenerated .html together.

# Palette round-trip rigor (the non-default test): mutate the test's distinct values and re-run —
# the round-trip must still pass (proves it's not matching hardcoded constants). Then introduce a
# deliberate bug (e.g. comment out the fg line in serialize) and confirm the test FAILS loudly.
```

## Final Validation Checklist

### Technical Validation

- [ ] `zig build -Doptimize=ReleaseFast` succeeds (prod unaffected).
- [ ] `zig build test -Doptimize=ReleaseFast` exits 0.
- [ ] The selection golden test fn appears in the test output and passes.
- [ ] The palette non-default round-trip test fn appears and passes.
- [ ] S1's whole-grid golden test still passes (no regression from extending the harness).
- [ ] A Debug-mode link failure (`R_X86_64_PC64`) is NOT treated as a defect.

### Feature Validation

- [ ] `testdata/sel_linewise.{ansi,html}` + `testdata/sel_block.{ansi,html}` all 4 present.
- [ ] Linewise golden pins rows 1..3 WITH styling; R0/R4 absent (Level 3 grep).
- [ ] Block golden pins the column slice (2345/CDEF/cdef) across rows 0..2; no full row present.
- [ ] Blessed outputs match the reference bytes in "Implementation Patterns" (max-width, colors).
- [ ] Binary `--selection` output is byte-stable vs committed goldens (Level 3 diff).
- [ ] Palette round-trip passes with a non-default Colors (fg/bg/palette[0,100,255] mutated).

### Code Quality Validation

- [ ] `golden_test.zig`'s selection test mirrors S1's Allocating-writer + diagnostic pattern.
- [ ] `embed.zig` extension is additive (S1's `Fixture`/`fixtures` untouched).
- [ ] `palette.zig` test placed among existing cache-I/O tests; no logic changed.
- [ ] No `build.zig` / `main.zig` / `build.zig.zon` changes (S1 already wired the harness).
- [ ] No scope creep: this item adds ONLY the 2 selection goldens + 1 palette round-trip test.
- [ ] The PUBLIC `writeCache`/`loadCache` are NOT called from any test (XDG/setenv dead end).

### Documentation & Deployment

- [ ] No new env vars. No user-facing docs (contract DOCS §5: "none — tests").
- [ ] The bless/refresh workflow is documented above for future maintainers.
- [ ] No new licensing — the 2 authored fixtures are original (no vendored inputs).

---

## Anti-Patterns to Avoid

- ❌ Don't call the PUBLIC `palette.writeCache`/`palette.loadCache` in a test — they read
  `$XDG_CACHE_HOME`/`$HOME` and Zig has no `setenv`; they'd error in stripped CI or write the
  REAL `~/.cache/tmux-2html/palette`. Test the dir-scoped `writeCacheDir`/`loadCacheDir` they
  delegate to (the canonical round-trip), via `std.testing.tmpDir`.
- ❌ Don't run tests in Debug — the `R_X86_64_PC64` link failure is a toolchain bug (PRD §15),
  not your code. The gate is `zig build test -Doptimize=ReleaseFast`.
- ❌ Don't pass `font: "monospace"` to renderGrid in the golden when the bless omits `--font`.
  It happens to be byte-equal, but `font: null` is the exact mirror of the binary's effective
  path and what S1's golden uses — keep them consistent.
- ❌ Don't call `palette.resolve()` in any test (tty/cache probing = non-deterministic). Use
  `palette.defaultColors()` directly, and bless with `--palette default`.
- ❌ Don't bless without `--cols N --rows M --palette default` matching the embed's geometry —
  the test pins exactly those (max-width comes from cols; row count from the selection range).
- ❌ Don't merge the selection golden into S1's single whole-grid test fn "for safety" — a
  separate test fn is verified safe in ReleaseFast (findings §1) and keeps the two concerns
  (whole-grid vs sub-rectangle) cleanly separated. Only merge if a crash is actually observed.
- ❌ Don't touch `build.zig` / `main.zig` / `build.zig.zon` — S1 already wired the `testdata`
  module and the `golden_test.zig` import. New test fns in already-imported files are pulled in
  automatically.
- ❌ Don't reuse `defaultColors()` for the palette round-trip and call it "the non-default test"
  — the WHOLE POINT of the new palette test is that arbitrary (non-default) values survive.
  Mutate fg/bg and at least 2-3 scattered palette indices with distinctive values.
- ❌ Don't change selection coords/geometry without re-blessing — the embed's coords MUST exactly
  match the bless command's `--selection`/`--cols`/`--rows`, or the golden is byte-wrong.
