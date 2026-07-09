# view.zig design notes (P3.M1.T2.S1) + sibling boundaries

## 0. What this subtask IS and is NOT

**IS** (this PRP): `src/tui/view.zig` — a NEW module exporting ONE public entry point:
```zig
pub fn render(
    out: *std.Io.Writer,
    grid: *const ghostty_vt.Screen,
    pal: palette.Colors,
    viewport: Viewport,
    cursor: Pos,
    selection: ?Selection,
    matches: []const Match,
) !void
```
that paints the grid's VISIBLE rows to the alternate-screen terminal in color (SGR resolved
through the cached palette), cursor-addressed, capped to the viewport, with selection + search
matches inverted. v1 = full viewport repaint per call (diff-rendering deferred — arch §5 +
contract: "v1 may full-repaint per keystroke (optimize later)").

**IS NOT** (sibling subtasks — do NOT implement):
- **P3.M1.T1.S2** (parallel, in-flight): `src/tui/app.zig` mouse/event loop. ALREADY SHIPPES
  `enter()`/`restoreRaw()`/`runEvents()`/`Event`. view.zig does NOT call app.zig; region.zig
  (P3.M3) wires enter()→render()→runEvents(). Treat app.zig's S2 PRP as a CONTRACT.
- **P3.M1.T2.S2** (next sibling): the STATUS LINE (PRD §7.1 copy-mode bar) + viewport SCROLL
  bookkeeping (maintaining `viewport.scroll` as the cursor moves / wheel scrolls) + populating
  the `matches` slice from the search layer. view.zig's `render()` already HIGHLIGHTS matches
  passed in (the `matches` param) and paints the grid for `viewport.rows` rows; S2 draws the
  status line in the last row and drives scroll/search to call render() with updated params.
- **P3.M2.T1/T2**: input decode (vim/search) + selection MODEL. view.zig CONSUMES a simple
  `?Selection`/`[]const Match` that those layers produce; it does NOT build them.
- **P3.M3.T1**: `region.zig` — captures scrollback → builds the Terminal/Screen → tui.enter() →
  loop { view.render(...); app.runEvents(handler) } → on confirm renders HTML. view.zig's caller.

So view.zig is a PURE rendering function (no terminal state of its own, no event loop, no
capture). It takes a loaded `*const Screen` + viewport + palette + overlays and writes bytes.
This is the cleanest scope boundary and makes it unit-testable (feed a Terminal-built Screen,
capture output, assert SGR/text).

## 1. Types (defined IN view.zig — the forward-contract select.zig/search will produce)

```zig
/// The visible window into the grid. `scroll` is the top grid row (screen-tag y) currently
/// shown (0 = top of scrollback). `cols`/`rows` are the popup terminal's grid cells available
/// for the GRID area (S2 reserves the last row for the status line — S2 passes rows = tty_rows-1).
pub const Viewport = struct {
    cols: u16,
    rows: u16,
    scroll: u32,
};

/// A grid position (screen-tag coords; x=col, y=row, origin top-left). For the TUI cursor.
pub const Pos = struct { x: u32, y: u32 };

/// A visual selection range in grid coords. select.zig (P3.M2.T2.S1) builds this from its
/// anchor/cursor model. Either endpoint may be the geometric top-left; render() normalizes.
/// `rect=false` ⇒ LINEWISE (full row width selected for each row in [y1..y2]).
/// `rect=true`  ⇒ BLOCK (columns [min(x1,x2)..max(x1,x2)] selected for each row in the y range).
/// Matches PRD §7.4 (v toggles linewise; Ctrl-v/Alt-drag toggles block).
pub const Selection = struct {
    x1: u32, y1: u32, x2: u32, y2: u32,
    rect: bool = false,
};

/// A search-match highlight: a contiguous run within a SINGLE row [x1..x2] on row `y`.
/// Multi-row matches are represented as multiple Match entries (one per row touched). The
/// search layer (P3.M2.T1.S2) produces these; render() highlights them with reverse video.
pub const Match = struct {
    y: u32,
    x1: u32,
    x2: u32,
};
```
RATIONALE for per-row `Match`: copy-mode search highlights are naturally per-row (a match wraps
to the next row as a new range), and containment testing is O(1) per cell. select.zig/search
splitting multi-row matches into per-row ranges is trivial. (If a future iteration wants
spanning matches, swap the slice element type — render()'s `matches` param is the only seam.)

## 2. The render algorithm (v1 full viewport repaint)

```
render(out, grid, pal, viewport, cursor, selection, matches):
  1. total_rows, grid_cols = (once) getBottomRight(.screen) → pointFromPin → y+1;  grid.pages.cols
  2. cols = min(viewport.cols, grid_cols);  rows = viewport.rows
  3. out.writeAll("\x1b[0m")                   # reset attrs once (no per-frame 2J — see note)
  4. for vy in 0..rows-1:
        gy = viewport.scroll + vy
        out.print("\x1b[{d};1H", .{vy+1})       # CUP to screen row vy+1, col 1 (1-based)
        if gy >= total_rows:
            out.writeAll("\x1b[K")              # below the grid — EL (erase line) to blank it
            continue                            # (handles scroll-past-end without a full 2J)
        row_pin = grid.pages.pin(.{.screen=.{.x=0,.y=gy}}) orelse continue
        page = row_pin.node.data
        cells = page.getCells(page.getRow(row_pin.y))
        var last_style: ?Style = null           # run-length SGR dedup
        for gx in 0..cols-1:
            cell = cells[gx]
            # wide-char / spacer handling (mirror ghostty_format)
            switch (cell.wide) {
                .spacer_head, .spacer_tail => continue,   # consumed by the adjacent wide cell
                .narrow, .wide => {},
            }
            hi = highlight(gx, gy, selection, matches)     # in selection OR in a match?
            style = cellStyle(page, &cell)
            if (hi) { style.flags.inverse = true }          # reverse-video the highlight
            if (last_style == null or !style.eql(last_style.?)):
                out.print("{f}", .{ with_palette(style.formatterVt(), pal) })  # re-emit SGR
                last_style = style
            # emit the glyph (or a space for blanks, so bg colors paint)
            if (cell.hasText()):
                out.print("{u}", .{cell.codepoint()})
                if (cell.content_tag == .codepoint_grapheme):
                    for (page.lookupGrapheme(&cell).?) |cp| out.print("{u}", .{cp})
            else:
                out.writeByte(' ')
  5. out.writeAll("\x1b[0m")                      # reset attrs (leave terminal clean)
```

### Why each step
- **3. NO per-frame `\x1b[2J`** (external_rendering_notes §5: ED causes a visible flicker
  between frames and does NOT move the cursor). render() paints EVERY viewport cell fully
  (grid cells incl. blanks-as-spaces; below-grid rows erased with EL `\x1b[K`), so each frame
  completely overwrites the previous one — no clear needed. The alt-screen is blank on entry
  (`\x1b[?1049h` in app.zig enter()), so the first frame is also clean. Emit one `\x1b[0m`
  (reset attrs) at the top so erased/blank cells take the default bg, not a stale run's bg.
  Below-grid rows (gy >= total_rows) get `\x1b[K` (Erase in Line) so scrolling past the grid
  end doesn't leave stale content. Clearing fills erased cells with the terminal's default bg,
  which == cached bg (popup runs in the same terminal the palette was captured from, PRD §6).
- **4. CUP per ROW (`\x1b[<vy+1>;1H`) then write cells sequentially within the row**: matches
  ghostty_format's proven row-sequential write (which writes a row then \r\n). Addressing the
  row start + writing left-to-right means wide chars auto-advance correctly (the terminal moves
  2 cols for a .wide glyph; we SKIP the spacer cell so alignment holds). CUP per row (not per
  cell) keeps output small while being robust. (External research: per-row CUP + sequential is
  the standard; per-cell CUP is overkill.)
- **wide/spacer**: a `.wide` cell holds the 2-col glyph (emit it; terminal advances 2);
  `.spacer_tail`/`.spacer_head` are the consumed 2nd cell (SKIP — emitting anything would
  misalign). This is byte-for-byte the rule in `src/ghostty_format.zig` (its inner loop does
  `switch (cell.wide) { .narrow, .wide => {}, .spacer_head, .spacer_tail => continue }`).
- **run-length SGR dedup**: only re-emit SGR when `style.eql(last)` is false. ghostty_format
  does exactly this (compares cell_style to the running `style`). `Style.eql` is field-wise
  (style.zig) so two cells with the same attrs/colors coalesce → one SGR for the whole run. This
  is the "re-emit SGR per cell run" the contract names.
- **highlight = XOR inverse** (external_rendering_notes §1: the conventional vim/less/tmux
  model): `composited.inverse = base.inverse ^ highlight`. Set on the value-copied Style:
  `style.flags.inverse = style.flags.inverse ^ hi;` (NOT a plain OR-set). An ALREADY-reverse
  cell under selection returns to NORMAL (the two inverses cancel) — exactly vim/less
  standout-over-standout behavior. formatterVt then emits `\x1b[7m` (or omits it) plus the
  cell's own colors; the terminal swaps fg/bg at draw time → reverse video over selected/
  matched cells (PRD §7.1 / arch §5). Selection + match both set `hi=true` (OR is sufficient
  — both render as inverse, one SGR covers both).
- **blank cells → space**: cells with no text but a bg color (`.bg_color_palette`/`.bg_color_rgb`
  or an empty cell with bg styling) must paint their bg → emit a space WITH the cell's style.
  This fills colored bars/backgrounds correctly. (ghostty_format emits ' ' for bg-only cells.)
- **palette resolve**: `with_palette(formatter, pal)` sets `formatter.palette = &pal.palette`
  so palette-index colors become explicit RGB pinned to the cache (the "colors match the cached
  palette" requirement). Default (.none) colors emit no SGR → terminal default (= cached fg/bg,
  same terminal). Verified SGR byte shapes in ghostty_cell_api.md §6.

## 3. PURE helpers (separate test fns — no Terminal)

```zig
/// Normalize a Selection to top-left/bottom-right. (select.zig may pass either order.)
pub fn normSel(s: Selection) struct { x1:u32,y1:u32,x2:u32,y2:u32,rect:bool } { ... min/max ... }

/// Is grid cell (gx,gy) inside the selection? LINEWISE: any row in [y1..y2].
/// BLOCK: row in [y1..y2] AND col in [x1..x2].
pub fn inSelection(gx:u32, gy:u32, s: Selection) bool { ... }

/// Is grid cell (gx,gy) inside any match? (Match is a single-row range.)
pub fn inAnyMatch(gx:u32, gy:u32, matches: []const Match) bool { ... }

/// Combined highlight for a cell (selection OR match). Selection takes precedence visually
/// (both render as inverse, so OR is sufficient).
pub fn highlight(gx:u32, gy:u32, sel: ?Selection, matches: []const Match) bool {
    if (sel) |s| if (inSelection(gx,gy,s)) return true;
    return inAnyMatch(gx,gy,matches);
}

/// viewport row math: clamp scroll so the viewport can't scroll past the grid.
pub fn clampScroll(scroll: u32, total_rows: u32, viewport_rows: u16) u32 {
    if (total_rows <= viewport_rows) return 0;
    const max = total_rows - viewport_rows;
    return @min(scroll, max);
}
```
These are PURE/deterministic → get their own `test` fns (NO Terminal → no cross-test GOTCHA).

## 4. The cellStyle helper — copy ghostty_format's (ghostty_cell_api.md §7)

```zig
fn cellStyle(page: *const ghostty_vt.page.Page, cell: *const Cell) Style {
    return switch (cell.content_tag) {
        inline .codepoint, .codepoint_grapheme => if (!cell.hasStyling()) .{} else
            page.styles.get(page.memory, cell.style_id).*,
        .bg_color_palette => .{ .bg_color = .{ .palette = cell.content.color_palette } },
        .bg_color_rgb => .{ .bg_color = .{ .rgb = .{
            .r = cell.content.color_rgb.r, .g = cell.content.color_rgb.g, .b = cell.content.color_rgb.b } } },
    };
}
```

## 5. The ONE integration test (shares a single Terminal.init scope — the GOTCHA)

ALL render() assertions that build a Terminal live in ONE `test` fn (sequential renderGrid-style
Terminal.init calls in one scope are fine; separate fns crash — render.zig GOTCHA). Build several
screens and assert:
- plain text → CUP + the codepoints + `\x1b[0m` somewhere.
- a red-fg ANSI cell → output contains `\x1b[38;2;` (palette-resolved RGB, since defaultColors
  palette[1] resolves to RGB) — do NOT hardcode the exact RGB (Ghostty's bundled value); assert
  the SHAPE (`38;2;` prefix for fg, `48;2;` for bg).
- a selection over a range → those cells' SGR includes `\x1b[7m`.
- a Match over a range → same.
- viewport capping: a 10-row grid with viewport.rows=3 + scroll=2 ⇒ only grid rows 2,3,4
  appear (assert grid row labels; rows outside absent).
- a wide char (e.g. 真 / a CJK codepoint) renders the glyph once and the spacer is skipped
  (assert the glyph count, not an extra space).
- below-grid rows (gy >= total_rows) are left blank (no spurious content).
Helper to build a Screen from ANSI (mirror render.zig's renderToOwned but return the Terminal
OR capture render output): init Terminal(cols,rows), feed bytes (\n→\r\n), call view.render into
an Allocating writer, return buffered().

## 6. main.zig wiring (ONE line in the test block)

Add `_ = @import("tui/view.zig");` to the `test {}` block in src/main.zig (next to the existing
`_ = @import("tui/app.zig");` at main.zig:489). No other main.zig change. No build.zig change
(view.zig is under src/, reachable from both exe + test binaries once imported; region.zig will
`@import("tui/view.zig")` when P3.M3 wires it — not this subtask).

## 7. Imports for view.zig

```zig
const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const Screen = ghostty_vt.Screen;
const Cell = ghostty_vt.page.Cell;
const Style = ghostty_vt.Style;
const point = ghostty_vt.point;
const color = ghostty_vt.color;
const palette = @import("../palette.zig");   // Colors
```
(`palette.zig` is a sibling under src/; from src/tui/view.zig the path is "../palette.zig".
Confirm at impl time — render.zig uses `@import("palette.zig")` from src/ root; view.zig is one
dir deeper so "../palette.zig". Alternatively put view.zig's palette import as the cli.zig-style
flat name only if build adds src/ to the import path — it does NOT by default, so "../palette.zig"
is correct. The other tui file app.zig imports only `std`, so there's no precedent in src/tui/.)

## 8. Anti-scope reminders (do NOT do these)

- Do NOT add a status line, scroll-offset maintenance, or search — that's S2.
- Do NOT decode keys / maintain a selection model — that's P3.M2.
- Do NOT capture panes or wire `region` — that's P3.M3.
- Do NOT implement diff-rendering (track previous frame, redraw only changed cells) — v1 is full
  repaint; the contract explicitly allows it ("optimize later"). Keep render() stateless.
- Do NOT touch app.zig (S1/S2), render.zig, palette.zig, cli.zig, main.zig (beyond the 1 test
  line), build.zig, PRD.md, tasks.json.
- Do NOT show the terminal cursor (app.zig enter() hides it via `\x1b[?25l`); leave it hidden.
  Positioning the terminal cursor at the TUI `cursor` cell is OPTIONAL and not required for v1
  (the `cursor` param exists for S2/future use + so render's signature matches the contract).
