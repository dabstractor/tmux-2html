name: "P3.M1.T2.S1 — Render grid in color via SGR + palette + cursor-addressed (src/tui/view.zig)"
description: |

---

## Goal

**Feature Goal**: Create a NEW module `src/tui/view.zig` exporting one pure rendering
function `pub fn render(out, grid, pal, viewport, cursor, selection, matches) !void` that
paints the captured pane's cell grid to the copy-mode TUI's alternate screen — in FULL
COLOR matching the cached palette — using raw SGR escape sequences + per-row cursor
addressing, capped to the viewport, scrolled by the cursor, with the active selection and
search matches shown in reverse video. v1 = full viewport repaint per call (diff-rendering
explicitly deferred — contract: "v1 may full-repaint per keystroke (optimize later)").

**Deliverable** (ONE new file `src/tui/view.zig` + ONE one-line addition to `src/main.zig`'s
test block):
- **`view.render(...)`** — the public entry point (the contract's exact signature). Pure: no
  terminal state of its own, no event loop, no capture — takes a loaded `*const Screen` +
  viewport + palette + overlays, writes bytes. Stateful callers (region.zig P3.M3) call it
  per keystroke; view.zig does NOT loop or own a previous-frame buffer.
- **`Viewport`/`Pos`/`Selection`/`Match`** public types — the forward-contract `select.zig`
  (P3.M2.T2) and the search layer (P3.M2.T1.S2) will PRODUCE; view.zig CONSUMES.
- **PURE helpers** (`clampScroll`, `normSel`, `inSelection`, `inAnyMatch`, `highlight`,
  `cellStyle`, `withPalette`) — unit-tested in their own `test` fns (no Terminal ⇒ no
  cross-test GOTCHA).
- **ONE integration `test`** exercising `render(...)` against several Terminal-built screens
  (color, selection, match, viewport capping, wide char, below-grid) — all assertions in a
  SINGLE test fn (the ghostty-vt cross-test GOTCHA; see Known Gotchas).
- **`src/main.zig` test block**: add `_ = @import("tui/view.zig");` next to the existing
  `_ = @import("tui/app.zig");` (main.zig:489) so view.zig's tests are reachable. (region.zig,
  view.zig's only caller, does NOT exist yet — without this import the tests never run.)

**Nothing else changes**: NO edits to `app.zig` (S1/S2, in-flight), `render.zig`,
`palette.zig`, `cli.zig`, `build.zig`/`build.zig.zon`, `capture.zig`, `PRD.md`, `tasks.json`.
Sibling tasks do NOT exist yet (`input.zig`/`select.zig` P3.M2, `region.zig` P3.M3) — view.zig's
`render(...)` + its overlay types are designed so those layers PLUG IN later without rewriting
render.

**Success Definition**:
- `zig build test -Doptimize=ReleaseFast` passes; view.zig's PURE tests + its single
  integration test are GREEN and reachable from main.zig's test block; ZERO regressions in the
  rest of the suite. (ReleaseFast is MANDATORY — PRD §15 / main.zig Gotcha: Debug-mode
  `zig build test` hits the Zig linker bug `R_X86_64_PC64` with the bundled C++ SIMD libs.)
- The module **compiles cleanly** in `--release=fast` — automated proof that the
  `Screen`/`PageList.pin`/`Page.getRow`/`Page.getCells`/`Cell`/`Style.formatterVt` APIs and the
  `*std.Io.Writer` seam are used correctly.
- The rendered bytes are CORRECT (unit-asserted): SGR colors resolved through the cached
  palette (`38;2;r;g;b`/`48;2;...` for palette-indexed cells), CUP per row, selection/match
  cells carry `\x1b[7m` (reverse), only the visible viewport rows are emitted.

## User Persona (if applicable)

**Target User**: `tmux-2html region` (P3.M3.T1 — currently an `error.NotImplemented` stub in
`cli.zig:region`). view.zig's `render(...)` is an INTERNAL library called by region's loop.
No end user calls it directly.

**Use Case**: PRD §7.1 / §5.3 — the user triggers `prefix C-o`, tmux opens a 100%×100%
`display-popup` (real pty) running `tmux-2html region`. region captures the full scrollback
into a grid (P3.M3), calls `tui.enter()` (alt screen + raw + mouse, P3.M1.T1), then on every
state change calls `view.render(out, screen, colors, viewport, cursor, selection?, matches)`
between `app.runEvents(...)` calls. The pane content appears in color matching the cached
palette; selection + search hits invert.

**User Journey**: `prefix C-o` → display-popup → `enter()` → loop { `view.render(...)` ;
`runEvents(handler)` } → user moves/searches/selects → each event → re-render → `Enter`/`y`
→ render HTML (renderGrid), exit.

**Pain Points Addressed**: The user sees the EXACT pane content (colors pinned to the captured
palette, not the popup terminal's live palette) and can visually pick a selection/match before
exporting to HTML.

## Why

- **PRD §7.1 mandates full-color grid rendering** ("Render the captured grid in **full color**
  using SGR + cursor addressing against the cached palette … cap rendered rows to viewport,
  scroll with the cursor"). This subtask is that renderer.
- **arch `tui_region.md` §5 is the verified contract**: re-emit SGR per cell run; cursor
  addressing `\x1b[<row>;<col>H`; cap to viewport; scroll with cursor; v1 full-repaint OK;
  invert selection range + search matches. view.zig implements exactly this.
- **`render_pipeline.md` §2** defines the cached `palette.Colors` struct view.zig consumes to
  pin palette-indexed cell colors to RGB (so colors match the source pane even if the popup
  terminal's palette differs).
- **The SGR emission already exists** in the ghostty-vt dep (`Style.formatterVt()` with a
  `palette` field — style.zig). view.zig REUSES it; it does NOT hand-roll SGR (avoiding the
  classic "forgot to turn off attribute 27/24" bug class). This is the key de-risking finding.
- **Forward-compatible seams.** `render(...)` is stateless; P3.M3 only supplies updated
  `viewport`/`selection`/`matches` per keystroke. The overlay types (`Selection`/`Match`) are
  simple value structs select.zig/search produce — no coupling to ghostty-vt's Pin-based
  `Selection` (that's renderGrid's HTML path, P1.M4).

## What

### Behavior (`src/tui/view.zig` — NEW module; std + ghostty-vt + palette)

1. **`render(...)`** paints the grid's VISIBLE rows to `out` (a `*std.Io.Writer`). For each
   visible viewport row `vy` (0..`viewport.rows`-1), grid row `gy = viewport.scroll + vy`:
   cursor-address to screen row `vy+1`, col 1 (`\x1b[<vy+1>;1H`); pin the row; iterate its
   cells left-to-right; emit run-length-deduped SGR (resolving palette indices → RGB via
   `pal.palette`) + the glyph (or a space for blanks). Cells in the selection or a match get
   the reverse bit XOR-ed onto their composited style. Wide-char spacer cells are skipped.
   Below-grid rows are erased with EL (`\x1b[K`). One `\x1b[0m` reset at top and bottom. NO
   per-frame `\x1b[2J` (flicker; full overwrite suffices).
2. **`cellStyle`** mirrors `src/ghostty_format.zig`'s proven Cell→Style mapping (verbatim).
3. **PURE helpers** (viewport row math, selection/match containment, style-inverse XOR) are
   unit-tested independently.

### Success Criteria

- [ ] `view.render(...)` has the contract's exact signature: `pub fn render(out: *std.Io.Writer, grid: *const ghostty_vt.Screen, pal: palette.Colors, viewport: Viewport, cursor: Pos, selection: ?Selection, matches: []const Match) !void`.
- [ ] Output is correct (unit-asserted): plain text emitted with CUP; a palette-colored cell emits `\x1b[38;2;…m` (RGB-resolved, NOT `\x1b[38;5;N`); a selection/match cell's SGR contains `\x1b[7m`; only `viewport.rows` rows emitted; wide-char glyph emitted once (spacer skipped); below-grid rows erased.
- [ ] PURE helpers GREEN in their own test fns; the render integration assertions all share ONE test fn.
- [ ] `zig build -Doptimize=ReleaseFast` compiles; `zig build test -Doptimize=ReleaseFast` GREEN (no regressions).
- [ ] main.zig test block imports view.zig (tests reachable).

## All Needed Context

### Context Completeness Check

_Passed._ An agent who knows nothing about this codebase can implement this from: the
VERIFIED ghostty-vt Cell/Screen/PageList/Style API (file:line cited) in
`research/ghostty_cell_api.md`; the view.zig design + sibling boundaries + the exact render
algorithm in `research/design_notes.md`; the terminal-rendering best-practices (XOR-inverse,
no per-frame 2J, single-write, spacer-skip) in `research/external_rendering_notes.md`; the
PROVEN Cell→Style→SGR pattern in `src/ghostty_format.zig` (read it — view.zig mirrors its
cellStyle + inner cell loop); the `palette.Colors` struct in `src/palette.zig`; and the writer
bridge in `src/render.zig` (`&fw.interface` / `&aw.writer`). Every API fact is pinned to the
shipped source; every SGR byte shape is pinned to style.zig's unit tests.

### Documentation & References

```yaml
# MUST READ — the VERIFIED ghostty-vt API (PRIMARY; do not guess the cell/SGR API)
- file: plan/001_0c8587f91cb2/P3M1T2S1/research/ghostty_cell_api.md
  why: Exact signatures read from shipped source: point.Point{.screen=.{.x,.y}} + PageList.pin()
       (PageList.zig:3875) → Pin{.node,.x,.y}; page.getRow(y) (page.zig:989) + page.getCells(row)
       (page.zig:995); Cell fields content_tag/content/style_id/wide + hasText()/codepoint()
       (page.zig:1962); Style.formatterVt() + the VTFormatter.palette field that RESOLVES palette
       indices to RGB (style.zig); total grid rows via getBottomRight(.screen)+pointFromPin;
       grid cols via PageList.cols. The writer is *std.Io.Writer (the new IO type). The
       cross-test GOTCHA + main.zig test-import wiring.
  critical: Style.formatterVt() ALREADY emits correct SGR (resets with \x1b[0m, then attrs, then
            38;2/48;2/58;2 RGB). Set vt.palette = &pal.palette to pin palette-index colors to the
            cached RGB. view.zig REUSES this — do NOT hand-roll SGR. flags.inverse is a public
            bool field → XOR it for highlight.

# MUST READ — the view.zig design + the exact render algorithm + sibling boundaries
- file: plan/001_0c8587f91cb2/P3M1T2S1/research/design_notes.md
  why: The render() algorithm step-by-step (CUP per row, run-length SGR dedup, XOR-inverse
       highlight, spacer-skip, EL for below-grid rows, no per-frame 2J); the Viewport/Pos/
       Selection/Match type definitions + WHY (forward-contract for select.zig/search); the PURE
       helper signatures; the single-integration-test rule; the main.zig one-line wiring; the
       imports (incl. the "../palette.zig" path from src/tui/); the anti-scope reminders.
  critical: view.zig is STATELESS — no event loop, no previous-frame buffer, no diff-rendering.
            Selection/match highlight is XOR on the composited style.inverse (conventional
            vim/less: an already-reverse cell under selection returns to normal), NOT plain OR-set.

# MUST READ — terminal-rendering best-practices (why each SGR/erase choice is correct)
- file: plan/001_0c8587f91cb2/P3M1T2S1/research/external_rendering_notes.md
  why: Authoritative basis for: selection/match = reverse attribute (SGR 7) per vim/less/tmux;
       CUP each ROW-START then write sequentially (not per-cell); wide char advances cursor +2 so
       the spacer cell MUST be skipped (never space-written); coalesce SGR (re-emit only on style
       change); full-viewport repaint/keystroke is fine for ≤50k total rows (only viewport
       painted); single write() of a whole frame (let the caller's buffered writer coalesce);
       ED (\x1b[2J) does NOT move the cursor and causes flicker so do NOT clear per frame —
       overwrite every cell + EL (\x1b[K) row tails instead.
  critical: do NOT emit \x1b[2J in render() (flicker + cursor-not-moved). Use \x1b[K only for
            below-grid rows (the one case a full overwrite doesn't cover).

# MUST READ — the PROVEN Cell→Style→SGR pattern to mirror (read it; view.zig copies cellStyle)
- file: src/ghostty_format.zig
  why: PageFormatter.formatWithState's inner cell loop (skip spacers; run-length style compare
       via cellStyle.eql; emit style; emit glyph or ' '; handle bg-only cells) is the template for
       view.zig's row loop. cellStyle() (ghostty_format.zig:~1240) is copied VERBATIM into
       view.zig. writeCell (writeCodepoint + lookupGrapheme) shows how to emit a cell's glyph(s).
  pattern: `switch (cell.wide){ .narrow,.wide => {}, .spacer_head,.spacer_tail => continue }`;
           `const cell_style = cellStyle(cell); if (!cell_style.eql(style)) { emit; style =
           cell_style; }`; blank/bg-only cell → writeByte(' ').
  gotcha: ghostty_format writes the WHOLE grid (no viewport, no CUP, \r\n between rows, no
          selection-inverse). view.zig adapts the CELL loop but adds viewport capping + per-row
          CUP + XOR-inverse + EL — do NOT copy its row/newline/selection handling.

# MUST READ — the Style struct + formatterVt (the SGR emitter view.zig reuses)
- file: zig-pkg/ghostty-1.3.1-5UdBCwYm-gQeBa4bu1-sMooCQS4KVriv5wWSIJ_sI-Cb/src/terminal/style.zig
  why: Style = {fg_color, bg_color, underline_color, flags}; Color = union{none,palette:u8,rgb};
       flags.inverse is a public bool (XOR it); Style.eql() for run-length dedup; formatterVt()
       returns VTFormatter{.style,.palette=?*const color.Palette}; print with "{f}". Verified SGR
       byte literals in its unit tests (empty ⇒ "\x1b[0m"; bold ⇒ "\x1b[0m\x1b[1m"; fg rgb ⇒
       "\x1b[38;2;255;128;64m"; palette idx + palette set ⇒ "\x1b[38;2;204;102;102m" RESOLVED).
  critical: set vt.palette = &pal.palette so palette-index cell colors become explicit RGB
            (the "colors match the cached palette" requirement). .none colors emit no SGR (terminal
            default == cached fg/bg, same terminal).

# MUST READ — the Colors struct view.zig consumes + the palette field
- file: src/palette.zig
  why: `palette.Colors = struct { palette: [256]color.RGB, foreground: ?color.RGB, background:
        ?color.RGB, palette_received_count: u16 }` (palette.zig:18); `&colors.palette` is
        `*const [256]RGB` → coerce to `?*const color.Palette` for VTFormatter.palette. resolve()
        is infallible (returns Colors, not !Colors).
  pattern: pass `colors` BY VALUE into render() (it's 256*3 + a few bytes — cheap, and avoids
           lifetime questions); set vt.palette = &pal.palette inside render.

# MUST READ — the *std.Io.Writer bridge (prod + test)
- file: src/render.zig
  why: render.zig run() bridges stdout to *std.Io.Writer via `var fw = out_file.writer(&sbuf);
        … &fw.interface` (the new-IO bridge view.zig's caller region.zig will use). render.zig's
        TEST bridge: `var aw = try std.Io.Writer.Allocating.initCapacity(alloc, 4096); defer
        aw.deinit(); … &aw.writer; const html = aw.writer.buffered();` — copy this for view.zig's
        integration test.
  gotcha: ghostty-vt's Terminal.init corrupts process-global state across SEPARATE test fns
          (render.zig's GOTCHA) → ALL render(...)-with-a-Terminal assertions share ONE test fn.

# READ — the contract spec + the testing/safety rules
- file: PRD.md
  why: §7.1 (full-color SGR + cursor addressing + viewport cap + scroll; selection/search
       highlight), §6 (palette.Colors + cached→live→default precedence), §7.4 (linewise vs block
       selection — view.zig's Selection.rect), §0 + §15 (NEVER touch the user's running tmux;
       ReleaseFast mandatory for tests).

# READ — the architecture doc for the TUI (§5 is this subtask's contract)
- file: plan/001_0c8587f91cb2/architecture/tui_region.md
  why: §5 = the verified view-rendering contract (re-emit SGR per cell run; cursor addressing;
       cap to viewport; scroll; v1 full-repaint OK; invert selection + matches; status line).
  gotcha: §5 mentions "diff-rendering for performance" — DEFERRED for v1 (contract allows
          full-repaint). view.zig stays stateless (no prev-frame buffer).

# READ — the render_pipeline palette model
- file: plan/001_0c8587f91cb2/architecture/render_pipeline.md
  why: §2 = palette.Colors + the cached→live→default precedence; confirms &colors.palette is the
       [256]RGB the renderer maps palette indices through.

# READ — the previous PRP (P3.M1.T1.S2) defines app.zig's Event/runEvents surface view.zig's
# caller (region.zig) will sit between. Treat it as a CONTRACT; do NOT duplicate its work.
- file: plan/001_0c8587f91cb2/P3M1T1S2/PRP.md
  why: app.zig ships enter()/restoreRaw()/runEvents()/Event. region.zig (P3.M3) will do:
        tui.enter(); loop { view.render(&fw.interface, …); _ = try tui.runEvents(handler); }
        defer tui.exit(state);. view.zig does NOT call app.zig — it only writes to `out`.

# EXTERNAL (best-practice references; anchors re-verify on load — see the brief's Gaps)
- url: https://invisible-island.net/xterm/ctlseqs/ctlseqs.html
  why: xterm ctlseqs — PRIMARY for CUP (CSI Ps ; Ps H), ED (CSI Ps J, does NOT move cursor),
       SGR (CSI Pm m; 7=reverse, 0=reset, 38;2/48;2=truecolor).
- url: https://github.com/rockorager/libvaxis
  why: Zig-native cell-grid renderer — reference for spacer-skip + single-write + style-cache.
```

### Current Codebase tree (relevant slice)

```bash
src/
├── main.zig            # test block (main.zig:476) — ADD `_ = @import("tui/view.zig");` here
├── render.zig          # ← the *std.Io.Writer bridge (prod + test) + the cross-test GOTCHA doc
├── palette.zig         # ← Colors struct + resolve(); view.zig imports this
├── ghostty_format.zig  # ← the PROVEN cellStyle + cell loop to mirror (read it)
└── tui/
    └── app.zig         # ← SHIPPED (S1) + S2 in-flight; view.zig does NOT touch it
zig-pkg/ghostty-…/src/terminal/
├── style.zig           # ← Style + formatterVt() + VTFormatter.palette (the SGR emitter)
├── page.zig            # ← Cell, Page.getRow/getCells/lookupGrapheme, Row
├── PageList.zig        # ← pin(), Pin, getBottomRight(.screen), pointFromPin, cols
├── point.zig           # ← Point{.screen=.{.x,.y}}, Coordinate, Tag
└── color.zig           # ← RGB, Palette=[256]RGB
plan/001_0c8587f91cb2/architecture/{tui_region.md,render_pipeline.md}   # §5 / §2 contracts
plan/001_0c8587f91cb2/P3M1T2S1/research/{ghostty_cell_api,design_notes,external_rendering_notes}.md
```

### Desired Codebase tree with files to be added/modified

```bash
src/
├── tui/
│   └── view.zig        # NEW — render() + Viewport/Pos/Selection/Match + PURE helpers + tests
└── main.zig            # MODIFIED — ONE line in the test block (import tui/view.zig)
```

### Known Gotchas of our codebase & Library Quirks

```zig
// CRITICAL: `zig build test` (Debug) HITS a Zig linker bug (R_X86_64_PC64) with the bundled
//   C++ SIMD libs. Tests MUST run as `zig build test -Doptimize=ReleaseFast` (PRD §15).
//   Every Validation command below uses ReleaseFast.

// CRITICAL: ghostty-vt's Terminal.init leaves process-global state corrupted such that a
//   Terminal.init in a SEPARATE test function CRASHES (core dump) (src/render.zig GOTCHA,
//   verified). view.zig imports ghostty-vt and builds a Terminal in its integration test, so
//   ALL render(...)-with-a-Terminal assertions MUST share ONE `test` fn. PURE helpers (no
//   Terminal) get their own test fns — exactly like render.zig (determineCols/lineCount are
//   separate; the renderGrid assertions are one test).

// CRITICAL: reuse Style.formatterVt() for SGR — do NOT hand-roll SGR. It always emits \x1b[0m
//   first (self-contained styles) then attrs then 38;2/48;2/58;2 RGB. Set vt.palette =
//   &pal.palette so palette-INDEX cell colors become explicit RGB pinned to the cache (the
//   "colors match the cached palette" requirement). Verified byte literals in style.zig tests.
//   flags.inverse is a PUBLIC bool → XOR it for highlight: composited.inverse = base.inverse ^ hi.

// CRITICAL: do NOT emit \x1b[2J per frame (external_rendering_notes §5): ED does NOT move the
//   cursor AND causes a visible flicker. render() fully overwrites every viewport cell each call
//   (grid cells incl. blanks-as-spaces; below-grid rows erased with \x1b[K), so no clear is
//   needed. The alt-screen is blank on enter (\x1b[?1049h in app.zig). Emit ONE \x1b[0m at the
//   top so erased cells take the default bg, not a stale run's bg.

// CRITICAL: wide-char handling. A .wide cell holds a 2-col glyph — emit it (terminal advances
//   cursor +2). .spacer_tail/.spacer_head are the consumed 2nd cell — `continue` past them
//   (writing ANYTHING there misaligns / splits the glyph). Mirror ghostty_format.zig's inner
//   loop: `switch (cell.wide){ .narrow,.wide => {}, .spacer_head,.spacer_tail => continue }`.
//   Because render() CUPs each ROW START then writes sequentially, the auto-advance + skip keeps
//   columns aligned (same as ghostty_format's row-sequential write).

// CRITICAL: highlight is XOR, not OR (external_rendering_notes §1 — the vim/less/tmux model):
//   `var s = cellStyle(...); s.flags.inverse = s.flags.inverse ^ highlight(gx,gy,...);`.
//   An ALREADY-reverse cell under selection returns to NORMAL (the two inverses cancel) — the
//   conventional standout-over-standout behavior. Do NOT do `if (hi) s.flags.inverse = true;`.

// CRITICAL: a grid row NEVER spans pages — one PageList.pin(.{.screen=.{.x=0,.y=gy}}) per visible
//   row + page.getRow(pin.y) + page.getCells(row) gives the ENTIRE row. Do NOT call pin() per
//   cell (expensive + unnecessary). pin() returns null when gy is past the grid end (down() fails)
//   → that row is "below the grid" → erase with \x1b[K.

// CRITICAL: PageList.rows is the ACTIVE-area row count (the terminal's `rows`), NOT the total
//   grid rows. Total grid rows (screen tag) = pointFromPin(.screen, getBottomRight(.screen).?).y
//   + 1 (O(pages), called ONCE per render). PageList.totalRows() exists (PageList.zig:4970) but
//   is `fn` not `pub fn` — DO NOT call it. Grid cols = PageList.cols (public field).

// GOTCHA: the writer is *std.Io.Writer (the NEW Zig 0.15 IO type) — NOT fs.File and NOT
//   fs.File.Writer. ghostty-vt's formatterVt().format takes *std.Io.Writer. region.zig bridges
//   via `var fw = stdout.writer(&buf); view.render(&fw.interface, …)` (render.zig's proven
//   bridge); tests use `std.Io.Writer.Allocating` + `&aw.writer` + `aw.writer.buffered()`.
//   Do NOT flush mid-render — the caller's buffer coalesces into one write on flush (single-
//   write frame; external_rendering_notes §4).

// GOTCHA: view.zig imports "../palette.zig" (it lives one dir deeper than src/render.zig which
//   uses "@import("palette.zig")"). ghostty-vt via "@import("ghostty-vt")". Confirm the palette
//   import path compiles; if the build adds src/ to the import root, a bare "palette.zig" also
//   works — but "../palette.zig" is always correct from src/tui/.

// GOTCHA: view.zig is NOT std-only (it imports ghostty-vt) — so its PURE-helper tests are fine
//   in separate fns, but its Terminal-building integration test MUST be a single fn (the
//   cross-test GOTCHA above). app.zig (std-only) is the contrast: ALL its tests can be separate.

// GOTCHA: select.zig (P3.M2.T2) / search (P3.M2.T1.S2) / region.zig (P3.M3) do NOT exist yet.
//   view.zig's Selection/Match types are the FORWARD CONTRACT they produce. Keep them simple
//   value structs (no ghostty-vt Pin/Selection coupling — that's renderGrid's HTML path).
```

## Implementation Blueprint

### Data models and structure

```zig
// src/tui/view.zig — NEW. Imports: std, ghostty-vt, ../palette.zig.
const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const Screen = ghostty_vt.Screen;
const Cell = ghostty_vt.page.Cell;
const Style = ghostty_vt.Style;
const point = ghostty_vt.point;
const color = ghostty_vt.color;
const palette = @import("../palette.zig");

/// The visible window into the grid. `scroll` = top grid row (screen-tag y) shown
/// (0 = top of scrollback). `cols`/`rows` = popup grid cells for the GRID area (S2 reserves
/// the last tty row for the status line and passes rows = tty_rows - 1).
pub const Viewport = struct { cols: u16, rows: u16, scroll: u32 };

/// A grid position (screen-tag coords; x=col, y=row, origin top-left). The TUI cursor.
pub const Pos = struct { x: u32, y: u32 };

/// A visual selection in grid coords. Either endpoint may be the geometric top-left;
/// render() normalizes. rect=false ⇒ LINEWISE (full row width per row in [y1..y2]);
/// rect=true ⇒ BLOCK (cols [min(x)..max(x)] per row in the y range). PRD §7.4.
pub const Selection = struct { x1: u32, y1: u32, x2: u32, y2: u32, rect: bool = false };

/// A search-match highlight: a contiguous run within ONE row [x1..x2] on row y. Multi-row
/// matches = multiple Match entries. The search layer (P3.M2.T1.S2) produces these.
pub const Match = struct { y: u32, x1: u32, x2: u32 };
```

### The render entry point (the contract signature)

```zig
/// Paint the grid's VISIBLE rows to `out` in color (SGR resolved through `pal`), cursor-
/// addressed, capped to `viewport`, with `selection` + `matches` shown in reverse video.
/// Pure + stateless: no terminal state, no previous-frame buffer. v1 = full viewport
/// repaint per call (diff-rendering deferred — contract allows it).
///
/// out       — *std.Io.Writer (new IO); caller (region.zig) bridges stdout via a buffered
///             File writer; tests use std.Io.Writer.Allocating. Do NOT flush mid-render.
/// grid      — the loaded screen (t.screens.active from the captured scrollback).
/// pal       — the cached palette (palette.Colors). Palette-INDEX cell colors are emitted as
///             explicit RGB pinned to pal.palette (colors match the source pane).
/// viewport  — { cols, rows, scroll }: the visible window.
/// cursor    — the TUI cursor (grid coords). Rendered positionally only if you choose to
///             move the terminal cursor at the end (OPTIONAL v1 — app.zig hides it via
///             \x1b[?25l on enter). Param exists so render's signature matches the contract.
/// selection — ?Selection: the active visual selection (null = none). Reversed.
/// matches   — []const Match: search hits to reverse-highlight (empty = none).
pub fn render(
    out: *std.Io.Writer,
    grid: *const Screen,
    pal: palette.Colors,
    viewport: Viewport,
    cursor: Pos,
    selection: ?Selection,
    matches: []const Match,
) !void {
    try out.writeAll("\x1b[0m"); // reset attrs once (erased/blank cells take default bg)

    // Grid dimensions (computed ONCE; O(pages) for the row count).
    const total_rows: u32 = blk: { // pointFromPin(.screen, getBottomRight(.screen)) + 1
        const br = grid.pages.getBottomRight(.screen) orelse break :blk 0;
        const br_pt = grid.pages.pointFromPin(.screen, br) orelse break :blk 0;
        break :blk br_pt.coord().y + 1;
    };
    const grid_cols: u16 = grid.pages.cols;
    const cols: u16 = @min(viewport.cols, grid_cols);
    const rows: u16 = viewport.rows;

    var vy: u32 = 0;
    while (vy < rows) : (vy += 1) {
        const gy: u32 = viewport.scroll + vy;
        try out.print("\x1b[{d};1H", .{vy + 1}); // CUP to screen row vy+1, col 1
        if (gy >= total_rows) { try out.writeAll("\x1b[K"); continue; } // below grid: EL

        const rp = grid.pages.pin(.{ .screen = .{ .x = 0, .y = gy } }) orelse {
            try out.writeAll("\x1b[K"); continue; // defensive: row unpinnable
        };
        const page = rp.node.data;
        const cells = page.getCells(page.getRow(rp.y)); // full row; index by col == gx

        var last: ?Style = null; // run-length SGR dedup
        var gx: u32 = 0;
        while (gx < cols) : (gx += 1) {
            const cell = cells[gx];
            switch (cell.wide) { // mirror ghostty_format.zig
                .spacer_head, .spacer_tail => continue, // consumed by the adjacent wide cell
                .narrow, .wide => {},
            }
            const hi = highlight(gx, gy, selection, matches);
            var s = cellStyle(page, &cell);
            s.flags.inverse = s.flags.inverse ^ hi; // XOR reverse (vim/less convention)
            if (last == null or !s.eql(last.?)) {
                var vt = s.formatterVt();
                vt.palette = &pal.palette; // pin palette-index colors → RGB (cached palette)
                try out.print("{f}", .{vt});
                last = s;
            }
            try writeGlyph(out, page, &cell); // codepoint (+grapheme trail) or ' '
        }
    }

    try out.writeAll("\x1b[0m"); // leave the terminal's SGR state clean
    _ = cursor; // v1: cursor is hidden (app.zig enter()); positional use deferred.
}

/// Emit a cell's glyph: the codepoint (+ any grapheme-cluster trail) or a space for blanks
/// (so bg colors / bg-only cells paint). Mirrors ghostty_format.zig writeCell.
fn writeGlyph(out: *std.Io.Writer, page: *const ghostty_vt.page.Page, cell: *const Cell) !void {
    if (!cell.hasText()) { try out.writeByte(' '); return; }
    try out.print("{u}", .{cell.codepoint()});
    if (cell.content_tag == .codepoint_grapheme) {
        if (page.lookupGrapheme(cell)) |trail| for (trail) |cp| try out.print("{u}", .{cp});
    }
}
```

### PURE helpers (separate test fns — no Terminal)

```zig
/// cellStyle — VERBATIM from src/ghostty_format.zig (the proven Cell→Style mapping).
fn cellStyle(page: *const ghostty_vt.page.Page, cell: *const Cell) Style {
    return switch (cell.content_tag) {
        inline .codepoint, .codepoint_grapheme => if (!cell.hasStyling()) .{} else
            page.styles.get(page.memory, cell.style_id).*,
        .bg_color_palette => .{ .bg_color = .{ .palette = cell.content.color_palette } },
        .bg_color_rgb => .{ .bg_color = .{ .rgb = .{
            .r = cell.content.color_rgb.r, .g = cell.content.color_rgb.g, .b = cell.content.color_rgb.b } } },
    };
}

/// Normalize a Selection to (x1<=x2, y1<=y2). select.zig may pass either order.
fn normSel(s: Selection) struct { x1: u32, y1: u32, x2: u32, y2: u32, rect: bool } {
    return .{ .x1 = @min(s.x1,s.x2), .y1 = @min(s.y1,s.y2),
              .x2 = @max(s.x1,s.x2), .y2 = @max(s.y1,s.y2), .rect = s.rect };
}

/// Is grid cell (gx,gy) inside the selection? LINEWISE: row in [y1..y2]. BLOCK: + col in [x1..x2].
fn inSelection(gx: u32, gy: u32, s: Selection) bool {
    const n = normSel(s);
    if (gy < n.y1 or gy > n.y2) return false;
    if (n.rect) return gx >= n.x1 and gx <= n.x2;
    return true; // linewise: full row width
}

/// Is grid cell (gx,gy) inside any match? (Match is a single-row range.)
fn inAnyMatch(gx: u32, gy: u32, matches: []const Match) bool {
    for (matches) |m| if (m.y == gy and gx >= m.x1 and gx <= m.x2) return true;
    return false;
}

/// Combined highlight for a cell (selection OR match). Both render as inverse (XOR in render).
pub fn highlight(gx: u32, gy: u32, sel: ?Selection, matches: []const Match) bool {
    if (sel) |s| if (inSelection(gx, gy, s)) return true;
    return inAnyMatch(gx, gy, matches);
}

/// Clamp scroll so the viewport can't scroll past the grid end. (S2 passes the clamped scroll.)
pub fn clampScroll(scroll: u32, total_rows: u32, viewport_rows: u16) u32 {
    if (total_rows <= viewport_rows) return 0;
    const max = total_rows - @as(u32, viewport_rows);
    return @min(scroll, max);
}
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: CREATE src/tui/view.zig with the module header + imports + the 4 public types
  (Viewport, Pos, Selection, Match) — see Data models.
  - IMPORTS: std, ghostty-vt (Screen, Cell, Style, point, color), "../palette.zig".
  - NAMING: CamelCase types; fields snake_case; Match is a per-row range (document why).
  - GOTCHA: "../palette.zig" (view.zig is one dir deeper than src/render.zig). Confirm compiles.

Task 2: ADD the PURE helpers (cellStyle, normSel, inSelection, inAnyMatch, highlight,
        clampScroll) — see PURE helpers. cellStyle is VERBATIM from ghostty_format.zig.
  - FOLLOW pattern: src/ghostty_format.zig cellStyle (~line 1240) — copy it exactly.
  - GOTCHA: cellStyle derefs page.styles.get(page.memory, cell.style_id) with .* (a *const Style).
  - GOTCHA: inSelection must normalize (either endpoint may be top-left); rect ⇒ col range too.

Task 3: ADD writeGlyph + render (the contract entry point) — see "The render entry point".
  - IMPLEMENT: the full viewport-paint loop (reset; per-row CUP; pin row; run-length SGR dedup
    with vt.palette=&pal.palette; XOR-inverse highlight; spacer-skip; glyph-or-space; EL for
    below-grid rows; final reset).
  - DEPENDENCIES: Task 1 (types) + Task 2 (helpers). Reuse Style.formatterVt() (do NOT hand-roll SGR).
  - GOTCHA: total_rows via getBottomRight(.screen)+pointFromPin (NOT PageList.rows / totalRows()).
    One pin() per row; a row never spans pages. NO per-frame \x1b[2J (flicker) — overwrite + \x1b[K.
  - GOTCHA: highlight is XOR (`s.flags.inverse ^ hi`), not OR. cursor param unused in v1 (hidden).

Task 4: ADD the PURE-helper unit tests — separate `test` fns (no Terminal ⇒ safe).
  - COVERAGE: normSel (either-order normalization); inSelection (linewise row range; block col
    range; out-of-range false); inAnyMatch (hit/miss across rows); highlight (sel OR match);
    clampScroll (scroll past end clamps; total<=rows ⇒ 0; in-range passthrough).
  - PLACE: in view.zig's test section. assert with std.testing.expectEqual/expect.

Task 5: ADD the ONE render integration test — ALL Terminal-building assertions in ONE `test` fn
  (the cross-test GOTCHA). Sequential render() calls in one scope are fine.
  - IMPLEMENT: a helper that builds a Screen from ANSI (Terminal.init(cols,rows); feed bytes
    \n→\r\n; render into an Allocating writer; return owned buffered() copy), then assert:
    (a) plain text "AB" → output contains "AB" + a CUP "\x1b[" ";1H"; (b) a red-fg ANSI cell
    ("\x1b[31mX\x1b[0m" under defaultColors) → output contains "\x1b[38;2;" (palette-resolved RGB;
    do NOT hardcode the exact RGB — assert the SHAPE) and "X"; (c) a Selection over a range →
    those cells' bytes include "\x1b[7m"; (d) a Match over a range → "\x1b[7m"; (e) viewport
    capping: 6-row grid ("R0\n…\R5"), viewport.rows=3 scroll=2 ⇒ only "R2","R3","R4" present,
    "R0"/"R1"/"R5" absent; (f) a wide char (e.g. a CJK codepoint) ⇒ glyph appears once, no extra
    trailing space for the spacer; (g) below-grid: viewport.rows > total_rows ⇒ below-grid rows
    get "\x1b[K" and no spurious grid content.
  - FOLLOW pattern: src/render.zig's renderToOwned (Allocating writer + dupe to avoid use-after-
    free on deinit) + its single-test-scope rule.
  - GOTCHA: Terminal.init corrupts cross-test state → ONE test fn for all render assertions.
    Use std.testing.allocator (verify no leaks). Do NOT hardcode palette hex (Ghostty's bundle).

Task 6: MODIFY src/main.zig test block — ADD ONE line.
  - FIND: the `test {}` block at main.zig:476; the line `_ = @import("tui/app.zig");` (~489).
  - ADD: `_ = @import("tui/view.zig");` immediately after it.
  - PRESERVE: every other import + the existing tests. No other main.zig change.
  - GOTCHA: without this, view.zig's tests are UNREACHABLE (region.zig, its only caller, doesn't
    exist yet). No build.zig change (view.zig under src/ is reachable once imported).
```

### Implementation Patterns & Key Details

```zig
// Reuse Style.formatterVt() for SGR — the single de-risking choice. Verified output (style.zig):
//   empty  ⇒ "\x1b[0m"
//   bold   ⇒ "\x1b[0m\x1b[1m"   inverse ⇒ "\x1b[0m\x1b[7m"   underline single ⇒ "\x1b[0m\x1b[4m"
//   fg rgb ⇒ "\x1b[0m\x1b[38;2;255;128;64m"   bg rgb ⇒ "\x1b[0m\x1b[48;2;32;64;96m"
//   palette idx + palette SET ⇒ "\x1b[0m\x1b[38;2;204;102;102m"  (RESOLVED to RGB — pin to cache)
//   palette idx, NO palette   ⇒ "\x1b[0m\x1b[38;5;42m"           (raw index — AVOID; set .palette)
var vt = style.formatterVt();
vt.palette = &pal.palette;          // MANDATORY: palette-index → cached RGB
try out.print("{f}", .{vt});

// Run-length SGR dedup (ghostty_format.zig's pattern): only re-emit when the style changes.
var last: ?Style = null;
// … per cell …
if (last == null or !s.eql(last.?)) { try out.print("{f}", .{vt}); last = s; }

// XOR highlight (external_rendering_notes §1): an already-reverse cell under selection → normal.
var s = cellStyle(page, &cell);
s.flags.inverse = s.flags.inverse ^ highlight(gx, gy, selection, matches);

// Per-row CUP + sequential write (NOT per-cell CUP) — robust + small. Wide chars auto-advance.
try out.print("\x1b[{d};1H", .{vy + 1});   // CUP to row vy+1, col 1
// … then write the row's cells left-to-right, skipping spacers …
```

### Integration Points

```yaml
BUILD:
  - change: NONE. view.zig is under src/ (root module); reachable from BOTH the prod exe and the
    test binary once main.zig imports it (Task 6). No build.zig / build.zig.zon edit. No new deps
    (ghostty-vt + std already imported; palette.zig is a sibling).
  - verify: `zig build -Doptimize=ReleaseFast` succeeds; `zig build test -Doptimize=ReleaseFast` GREEN.

MAIN.ZIG:
  - change: ONE line in the `test {}` block (Task 6): `_ = @import("tui/view.zig");`. view.zig is
    NOT imported on the exe path yet (region.zig will `@import("tui/view.zig")` in P3.M3 — not
    this subtask); this test-block import is what makes its tests reachable NOW.

FUTURE CONSUMERS (do NOT implement now — boundary docs only):
  - P3.M1.T2.S2 (status line + scroll + match population): draws the PRD §7.1 copy-mode status
    bar in the last tty row (calls render with rows = tty_rows - 1); maintains viewport.scroll as
    the cursor moves / wheel scrolls (clampScroll); runs search and passes the Match slice. view's
    render() already HIGHLIGHTS the matches it's given + paints viewport.rows rows.
  - P3.M2.T2.S1 (select.zig): builds a view.Selection {x1,y1,x2,y2,rect} from its anchor/cursor
    model (v=linewise, Ctrl-v/Alt-drag=block; PRD §7.4) and passes it to render(). No coupling to
    ghostty-vt's Pin-based Selection.
  - P3.M2.T1.S2 (search): produces []const view.Match (per-row ranges) and passes them to render().
  - P3.M3.T1 (region.zig): captures full scrollback → Terminal/Screen → tui.enter() → loop {
    var fw = stdout.writer(&buf); view.render(&fw.interface, screen, colors, viewport, cursor,
    selection, matches); fw.interface.flush(); _ = try tui.runEvents(handler); } defer tui.exit(state).
```

## Validation Loop

> **MANDATORY:** every `zig build` / `zig build test` below uses `-Doptimize=ReleaseFast`
> (PRD §15 / main.zig Gotcha: Debug-mode `zig build test` hits the Zig linker bug
> `R_X86_64_PC64` with the bundled C++ SIMD libs; ReleaseFast is unaffected).

### Level 1: Syntax & Style (Immediate Feedback)

```bash
cd /home/dustin/projects/tmux-2html
# Compile the whole binary in ReleaseFast — primary proof the ghostty-vt Screen/PageList.pin/
# Page.getRow/getCells/Cell/Style.formatterVt APIs + the *std.Io.Writer seam are used correctly.
zig build -Doptimize=ReleaseFast
# Expected: zero errors. If a PageList/Cell/Style field name, the pin() call, the formatterVt
# palette field, the point.Point{.screen=...} construction, or the "../palette.zig" import is
# wrong, it fails HERE — read the error, fix against research/ghostty_cell_api.md.
```

### Level 2: Unit Tests (the PURE helpers + the single render integration test)

```bash
cd /home/dustin/projects/tmux-2html
zig build test -Doptimize=ReleaseFast
# Expected: all GREEN — view.zig's PURE tests + its ONE integration test + ZERO regressions in
# the rest of the suite (app.zig, render.zig, palette.zig, capture.zig, golden_test.zig).
#
# The tests to ADD (in src/tui/view.zig):
#   PURE (separate test fns — no Terminal):
#     - normSel: {x1=5,y1=1,x2=0,y2=3} ⇒ {x1=0,y1=1,x2=5,y2=3}; identity for already-ordered.
#     - inSelection: linewise sel(y1=1,y2=3) ⇒ (0,1)=T,(0,3)=T,(0,2)=T,(0,0)=F,(0,4)=F;
#       block sel(x1=1,x2=3,y1=0,y2=2,rect) ⇒ (1,0)=T,(3,2)=T,(0,0)=F,(4,1)=F,(2,3)=F.
#     - inAnyMatch: matches=[{y=2,x1=1,x2=3}] ⇒ (1,2)=T,(3,2)=T,(0,2)=F,(4,2)=F,(1,1)=F.
#     - highlight: sel-only / match-only / both ⇒ true; neither ⇒ false.
#     - clampScroll: total=10,rows=4 ⇒ scroll 0→0, 6→6, 7→6 (max), 100→6; total=3,rows=4 ⇒ any⇒0.
#   INTEGRATION (ONE test fn — the cross-test GOTCHA):
#     - plain "AB" (cols=10,rows=2) ⇒ output contains "AB" + a CUP "\x1b[1;1H".
#     - red-fg "\x1b[31mX\x1b[0m" under palette.defaultColors() ⇒ output contains "\x1b[38;2;"
#       (palette[1] resolved to RGB) and "X" (do NOT hardcode the RGB — Ghostty's bundle value).
#     - a Selection over the 'X' cell ⇒ those bytes include "\x1b[7m".
#     - a Match over the 'X' cell ⇒ "\x1b[7m".
#     - viewport capping: grid "R0\nR1\nR2\nR3\nR4\nR5" (rows=6), viewport.rows=3 scroll=2 ⇒
#       "R2","R3","R4" present; "R0","R1","R5" absent.
#     - wide char (a CJK codepoint) ⇒ the glyph appears once (count the utf-8), no extra trailing
#       space for the spacer cell.
#     - below-grid: viewport.rows=10 with a 2-row grid ⇒ the extra rows get "\x1b[K" and contain
#       no grid glyphs.
```

### Level 3: Integration / manual check (real tty — deferred to P3.M3)

> render() itself is PURE (writes to a `*std.Io.Writer`); it is FULLY unit-tested via the
> Allocating writer (Level 2). The LIVE terminal paint is proven when region.zig (P3.M3) wires
> enter()→render()→runEvents() in a real display-popup pty (isolated tmux server per PRD §0/§15).
> **Do NOT wire region here.** This Level 3 only asserts the wiring + structure invariants.

```bash
cd /home/dustin/projects/tmux-2html
# (a) Confirm view.zig is reachable from the test root (its tests actually ran):
grep -n '@import("tui/view.zig")' src/main.zig   # the Task 6 line is present
# (b) Confirm render() has the contract's exact signature:
grep -n 'pub fn render(' src/tui/view.zig        # 7 params: out, grid, pal, viewport, cursor, selection, matches
grep -n 'pub const Viewport = struct' src/tui/view.zig
grep -n 'pub const Selection = struct' src/tui/view.zig
grep -n 'pub const Match = struct' src/tui/view.zig
# (c) Confirm SGR is REUSED (not hand-rolled) + palette is pinned + highlight is XOR:
grep -n 'formatterVt()' src/tui/view.zig          # the SGR emitter
grep -n 'vt.palette = &pal.palette' src/tui/view.zig   # palette-index → cached RGB
grep -n 'inverse = s.flags.inverse \^ hi\|inverse % hi\|inverse %\| \^ hi' src/tui/view.zig  # XOR highlight
# (d) Confirm NO per-frame clear (flicker) + EL for below-grid rows + spacer-skip (mirror ghostty_format):
! grep -n '\\x1b\[2J' src/tui/view.zig            # no per-frame ED (grep exits 1)
grep -n '\\x1b\[K' src/tui/view.zig               # EL for below-grid rows
grep -n 'spacer_head, .spacer_tail => continue' src/tui/view.zig   # wide-char spacer skip
# (e) Confirm view.zig did NOT touch its siblings:
git status --short src/tui/app.zig src/render.zig src/palette.zig src/cli.zig build.zig   # all clean
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Confirm the renderer is structurally correct against the contract (the four pillars):
#   1. cursor-addressed         2. palette-pinned RGB   3. viewport-capped + scrolled   4. selection/match inverse
grep -n '\\x1b\[{d};1H' src/tui/view.zig          # per-row CUP (pillar 1)
grep -n '38;2\|formatterVt' src/tui/view.zig       # RGB SGR via formatterVt (pillar 2)
grep -n 'viewport.scroll + vy\|gy >= total_rows' src/tui/view.zig   # viewport cap + scroll (pillar 3)
grep -n 'highlight(' src/tui/view.zig              # selection/match inverse (pillar 4)
# Confirm the one-pin-per-row access (a row never spans pages):
grep -n 'pages.pin(.*screen' src/tui/view.zig      # one pin per visible row
# Confirm total-rows derivation is the PUBLIC path (NOT the private totalRows()):
grep -n 'getBottomRight(.screen)' src/tui/view.zig
! grep -n 'totalRows()' src/tui/view.zig           # private fn — never called (grep exits 1)
```

## Final Validation Checklist

### Technical Validation

- [ ] `zig build -Doptimize=ReleaseFast` succeeds (ghostty-vt Screen/PageList/Page/Cell/Style APIs + the `*std.Io.Writer` seam correct).
- [ ] `zig build test -Doptimize=ReleaseFast` is GREEN — view.zig's PURE tests + its ONE integration test pass + ZERO regressions (app.zig/render.zig/palette.zig/capture.zig/golden_test.zig).
- [ ] main.zig test block imports view.zig (tests reachable).

### Feature Validation

- [ ] `render(...)` has the contract's exact 7-param signature; emits CUP per row, SGR resolved through the cached palette (`38;2;…`/`48;2;…` for palette-indexed cells), only `viewport.rows` rows, scrolled by `viewport.scroll`.
- [ ] Selection + matches shown via XOR reverse (`\x1b[7m`); an already-reverse cell under selection returns to normal (unit-asserted shape).
- [ ] Wide chars render once (spacer skipped); below-grid rows erased with `\x1b[K`; NO per-frame `\x1b[2J`.

### Code Quality Validation

- [ ] SGR is REUSED from `Style.formatterVt()` (not hand-rolled); palette pinned via `vt.palette = &pal.palette`.
- [ ] `cellStyle` mirrors `src/ghostty_format.zig` verbatim; the cell loop mirrors its spacer-skip + run-length dedup.
- [ ] The ONE integration test shares a single Terminal.init scope (the cross-test GOTCHA); PURE helpers are separate test fns.
- [ ] No new deps; `../palette.zig` import path correct; no edits to siblings (app.zig/render.zig/palette.zig/cli.zig/build.zig).

### Documentation & Deployment

- [ ] Code is self-documenting (the render algorithm + each gotcha is commented at the call site).
- [ ] The `Viewport`/`Selection`/`Match` types document their forward-contract role (select.zig/search produce them).

---

## Anti-Patterns to Avoid

- ❌ Don't hand-roll SGR — REUSE `Style.formatterVt()` (it resets + emits attrs + RGB correctly; style.zig-tested).
- ❌ Don't emit `\x1b[2J` per frame — flicker + cursor-not-moved. Overwrite every cell + `\x1b[K` below-grid rows.
- ❌ Don't CUP every cell — CUP each ROW START, write sequentially (small + robust; matches ghostty_format).
- ❌ Don't write the wide-char spacer cell — `continue` past `.spacer_head`/`.spacer_tail` (it splits the glyph).
- ❌ Don't OR-set inverse for highlight — XOR it (`base.inverse ^ hi`); conventional vim/less behavior.
- ❌ Don't call pin() per cell — one pin() per visible row (a row never spans pages).
- ❌ Don't use `PageList.rows`/`totalRows()` for grid row count — use `getBottomRight(.screen)`+`pointFromPin` (public); `totalRows()` is private.
- ❌ Don't put render()-with-a-Terminal assertions in separate test fns — ghostty-vt's Terminal.init corrupts cross-test state (ONE integration test fn; PURE helpers separate).
- ❌ Don't flush mid-render — let the caller's buffered writer coalesce into one write (single-write frame).
- ❌ Don't implement the status line / scroll maintenance / search / selection model / region wiring — those are S2 / P3.M2 / P3.M3 (scope boundary).
- ❌ Don't hardcode palette hex values in tests — assert SGR SHAPE (`38;2;`), not Ghostty's bundled RGB.
