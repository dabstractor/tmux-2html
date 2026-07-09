# P3.M1.T2.S2 design notes — status line + viewport scroll + match highlight (view.zig additions)

> This subtask ADDS to `src/tui/view.zig` (created by the parallel sibling P3.M1.T2.S1).
> Treat the S1 PRP (`plan/001_0c8587f91cb2/P3M1T2S1/PRP.md`) as a CONTRACT — assume view.zig
> exists with the S1 surface (below) when S2 begins.

## 0. What S1 ships (the CONTRACT we build on — do NOT redefine/recreate)

`src/tui/view.zig` (S1) exports:
- `pub const Viewport = struct { cols: u16, rows: u16, scroll: u32 }`
- `pub const Pos = struct { x: u32, y: u32 }`
- `pub const Selection = struct { x1:u32, y1:u32, x2:u32, y2:u32, rect: bool = false }`
- `pub const Match = struct { y: u32, x1: u32, x2: u32 }`  // per-row range
- `pub fn render(out, grid, pal, viewport, cursor, selection, matches) !void`
    — paints `viewport.rows` GRID rows (CUP per row, SGR via formatterVt with
    `vt.palette=&pal.palette`, XOR-inverse highlight for selection/match, spacer-skip, EL for
    below-grid rows). render() does NOT paint a status line and does NOT own viewport.scroll.
- PURE helpers (S1, reusable): `cellStyle`, `normSel`, `inSelection`, `inAnyMatch`,
  `highlight`, `clampScroll(scroll, total_rows, viewport_rows) u32`.

The writer is `*std.Io.Writer` (new IO). The Cell/Style/Screen API is verified in
`../P3M1T2S1/research/ghostty_cell_api.md`. Cross-test GOTCHA (ghostty-vt Terminal.init
corrupts process-global state across SEPARATE test fns) applies to view.zig → any test that
builds a Terminal for findMatches/renderStatus assertions MUST share ONE test fn with the
existing S1 render integration test. PURE helpers (no Terminal) get their own test fns.

## 1. S2 scope (ADD to view.zig — three deliverables)

S2 = the ORCHESTRATION/ARITHMETIC layer that sits ABOVE `render()` and BELOW the region.zig
loop (P3.M3). It does NOT loop, own terminal state, or capture. Three additions:

### 1A. Status line — `renderStatus(...)` + `Status` + `SelMode` (paints the LAST tty row)
PRD §7.1 exact format:
`[LINE|BLOCK]  row:N col:M  /pattern  N match(es)  <S-sel>Enter=render q=quit`
- Drawn on the LAST screen row (`tty_rows`), using CUP + a DISTINCT style (reverse video /
  bold) so it's visually separated from the grid (vim `StatusLine` default = reverse; tmux
  `message-style`/status defaults — see external_scroll_statusline.md). Use SGR `\x1b[7m`
  (reverse) + `\x1b[1m` (bold) for the whole line, reset `\x1b[0m` at the end.
- S1's `render()` paints rows `1..viewport.rows` (= tty_rows - 1). renderStatus paints row
  `tty_rows`. So the caller passes `viewport.rows = tty_rows - 1` to render() and calls
  renderStatus with `tty_rows` for the last row. **No overlap; no double-paint.**
- EL (`\x1b[K`) the remainder of the status row after the text so stale content from a longer
  previous frame is cleared (same rationale as S1's below-grid EL — no per-frame 2J).
- The status line is built into a small stack buffer (the format is short, ≤ ~80 chars) and
  printed with one `out.print`. Truncate the `/pattern` to fit the width if needed (pattern
  may be long); N is always shown.

Fields → Status struct inputs:
  - `mode: SelMode` → `.none | .line | .block` → prints `[LINE]` / `[BLOCK]` / nothing for none.
  - `cursor: Pos` → `row:{cursor.y+1} col:{cursor.x+1}` (1-based, vim/tmux convention).
  - `pattern: ?[]const u8` → `/{pattern}` when non-null+non-empty, else omit the search token.
  - `match_count: usize` → ` {match_count} match(es)` (only when a pattern is active).
  - `has_selection: bool` → `<S-sel>` indicator shown only when a selection is active.
- `Enter=render q=quit` are STATIC key hints (always shown).

### 1B. Viewport scroll math — PURE `scrollForCursor*` primitives (no I/O, no Terminal)
The input layer (P3.M2.T1.S2 vim motions) COMPOSES these. S2 provides the arithmetic, NOT the
key→action mapping. All return a NEW `scroll` value (clamped via S1's `clampScroll`); they
NEVER mutate global state. Coordinates are GRID rows (screen-tag y).

  // Keep cursor visible after an arbitrary move (the workhorse — call after every cursor change).
  // Returns the scroll that brings cursor_y into [scroll, scroll+rows-1], scrolling the MINIMUM
  // amount (vim 'sidescroll'/'scroll-cursor' semantics). If already visible, returns viewport.scroll.
  pub fn scrollForCursor(cursor_y: u32, viewport: Viewport, total_rows: u32) u32

  // Recenter family (vim zz/zt/zb): the viewport follows the cursor.
  pub fn centerOnCursor(cursor_y: u32, viewport_rows: u16, total_rows: u32) u32  // zz: cursor mid
  pub fn topOnCursor(cursor_y: u32, total_rows: u32) u32                          // zt: cursor at top
  pub fn bottomOnCursor(cursor_y: u32, viewport_rows: u16, total_rows: u32) u32   // zb: cursor at bot

  // Page/half-page scrolls (vim Ctrl-f/Ctrl-b, Ctrl-d/Ctrl-u, PgUp/PgDn). cursor repositions to
  // stay visible (see external_scroll_statusline.md for the exact vim model). S2 returns the new
  // scroll; the input layer computes the new cursor (keep-cursor-visible or jump).
  pub fn pageDown(scroll: u32, total_rows: u32, viewport_rows: u16) u32   // +rows, clamp
  pub fn pageUp(scroll: u32, total_rows: u32, viewport_rows: u16) u32     // -rows, clamp ≥0
  pub fn halfPageDown(scroll: u32, total_rows: u32, viewport_rows: u16) u32 // +rows/2
  pub fn halfPageUp(scroll: u32, total_rows: u32, viewport_rows: u16) u32   // -rows/2

  // gg / G helpers (also exposed so the input layer + region.zig init can use them).
  pub fn scrollToTop() u32          // 0
  pub fn scrollToBottom(total_rows: u32, viewport_rows: u16) u32  // clampScroll(maxInt, total, rows) = max(0,total-rows)

Rationale for providing BOTH `scrollForCursor` (keep-visible) and the recenter family: H/M/L in
vim move the CURSOR within the current viewport and do NOT scroll (so they don't call any scroll
fn — the input layer just sets cursor = scroll / scroll+rows/2 / scroll+rows-1). The recenter
family (zz/zt/zb) and page scrolls DO change scroll and need these primitives. `scrollForCursor`
is what keeps the cursor on-screen after hjkl/wbe/0^$/{}/% and after n/N search jumps.

### 1C. Match finding — PURE `findMatches` + `rowText` (enables "N match(es)" + highlight)
The status line shows `N match(es)` and the grid highlights matches (S1 render inverts them).
To make BOTH real, S2 provides the grid-text scan that produces `[]Match`:

  // Decode ONE grid row (screen-tag y) into plain UTF-8 text. Caller owns the returned slice.
  // Walks the row's cells (pin + getRow + getCells — the verified S1 path), appends each cell's
  // codepoint (+ grapheme trail), SKIPS spacer cells (a wide char contributes its glyph but its
  // spacer contributes nothing — keeps column indices aligned). Returns "" for rows past the grid.
  pub fn rowText(alloc, grid, y: u32) ![]u8

  // Scan EVERY grid row's text for `needle`, producing per-row Match ranges [x1..x2] (col indices).
  // mode = .fixed (v1; regex is NOT available — see §2). `needle == ""` ⇒ empty result (no matches;
  // the status line then shows no search token — caller checks emptiness). Case-sensitive (vim
  // default; /i can be a future option). Multi-row matches are naturally per-row entries.
  pub const SearchMode = enum { fixed };  // .regex reserved for a future dependency (§2)
  pub fn findMatches(alloc, grid, needle: []const u8, mode: SearchMode) ![]Match

  // Total match count (== findMatches(...).len, but a O(rows) shortcut if only the count is needed
  // for the status line when highlights aren't being recomputed). v1: just return matches.len —
  // the function exists so the status-line path and the render path share ONE source of truth.
  pub fn matchCount(matches: []const Match) usize

The column index mapping: `rowText` walks cell-by-cell; the byte offset of a match in the decoded
text does NOT equal the cell column (multi-byte UTF-8 + wide chars). So findMatches must track
the CELL column alongside each emitted codepoint while building rowText, OR re-derive the cell
range from the byte range. **Decision: findMatches builds rowText WITH a parallel `col_map:
[]u16` (byte-offset → cell-column) so a byte-range match maps to [x1..x2] cell columns exactly.**
This handles wide chars (a wide glyph is one cell index but the search text is its codepoint(s))
correctly — the match's x1/x2 are the inclusive CELL columns of the first/last matched cell.

## 2. CRITICAL: Zig 0.15.2 has NO stdlib regex — v1 is FIXED-STRING

VERIFIED (compile probe): `@import("std").regex` → `error: 'std' has no member named 'regex'`.
`find /.../lib/std -iname '*regex*'` → nothing Zig (only gcc's libphobos). PRD §7.3 says
"regex (or fixed-string, configurable, default regex)" BUT:
- Adding a regex dependency (e.g. a third-party Zig regex lib) requires a `build.zig.zon` change
  — OUT OF SCOPE for this subtask (FORBIDDEN: never modify build.zig.zon/build.zig; deps are a
  product/architecture decision).
- Implementing a regex engine here is far beyond a 1-point view subtask.

**Therefore S2 ships `SearchMode.fixed` ONLY, using `std.mem.indexOf(u8, haystack, needle)` /
`indexOfPos` per row.** `SearchMode = enum { fixed }` is defined with a doc comment that `.regex`
is RESERVED for a future dependency. findMatches asserts/ignores the mode (only .fixed exists).
The status line + highlight are fully functional with fixed-string search. This is recorded as a
known limitation / follow-up (regex needs a dependency decision — not a view.zig concern).

## 3. What S2 does NOT do (scope boundaries — sibling subtasks)

- Does NOT implement the KEY→action mapping (hjkl/H/M/L/Ctrl-d-u-f-b/PgUp/PgDn/gg/G/n/N) — that is
  P3.M2.T1 (input.zig + vim motions). S2 only provides the scroll ARITHMETIC primitives those
  motions call. (Provide the math; don't consume the keys.)
- Does NOT implement the selection MODEL (v-toggle, o/O, anchor/cursor) — P3.M2.T2 (select.zig).
  S2's `Status.mode` is an INPUT (the caller reports the current selection mode); S2 does not track it.
- Does NOT capture panes / launch the TUI / loop — P3.M3 (region.zig). region.zig will, per keystroke:
  update cursor/selection/pattern → if pattern changed, `matches = findMatches(...)` →
  `viewport.scroll = scrollForCursor(cursor, viewport, total)` → `render(..., viewport.rows=tty_rows-1)`
  → `renderStatus(..., tty_rows)`. S2 provides the functions; region.zig calls them.
- Does NOT modify S1's `render()` signature or its body. S2 ADDS functions + types to view.zig.
- Does NOT add build deps. Does NOT touch app.zig/render.zig/palette.zig/cli.zig/main.zig (beyond
  the one-line test import S1 already added — confirmed present in main.zig:489 area; S2 needs NO
  new main.zig edit because view.zig is already imported by S1).

## 4. Testing strategy (mirrors S1 / render.zig)

- PURE scroll math (§1B): separate `test` fns, no Terminal. Table-driven edge cases (cursor above/
  below viewport; total < viewport; scroll clamps at 0 / total-rows; recenter families; page clamps).
- PURE `rowText` / `findMatches` math WITHOUT a Terminal: build a Match slice from a synthetic
  `rowText`-style input OR test the col_map logic in isolation. BUT rowText/findMatches need a real
  `*const Screen` to walk cells. Those assertions build a Terminal → MUST live in the ONE shared
  Terminal test fn (the cross-test GOTCHA — append to S1's single render-integration test, do NOT
  create a second Terminal.init test fn). Use std.testing.allocator; verify no leaks.
- renderStatus is PURE given a Status struct (no Terminal) → its own test fn (format exact bytes,
  including the `[LINE]`/`[BLOCK]`/none, 1-based row:col, `/pat`, `N match(es)`, `<S-sel>`, hints,
  reverse SGR `\x1b[7m`, trailing EL `\x1b[K`). Build a Status, render into an Allocating writer,
  assert the exact string shape.
- All under `zig build test -Doptimize=ReleaseFast` (MANDATORY — Debug linker bug; PRD §15).

## 5. main.zig wiring — NONE needed

S1 already added `_ = @import("tui/view.zig");` to main.zig's test block. S2 ADDS functions to the
SAME file (view.zig) → they're reachable from the existing import. No new main.zig edit, no build.zig
change. (Confirmed: main.zig test block imports tui/view.zig per S1's Task 6.)

## 6. Public API summary (the contract S2 exports — for region.zig P3.M3 + input/select P3.M2)

```zig
// types (ADDITIONAL — S1's Viewport/Pos/Selection/Match stay)
pub const SelMode = enum { none, line, block };
pub const Status = struct {
    mode: SelMode,
    cursor: Pos,            // S1's Pos {x,y} (grid coords; renderStatus prints 1-based)
    pattern: ?[]const u8,   // null OR empty ⇒ no search token shown
    match_count: usize,
    has_selection: bool,
};
pub const SearchMode = enum { fixed };  // .regex reserved (§2: no stdlib regex in 0.15.2)

// paint the last tty row (status line). `cols` = tty width (for EL + truncation). `tty_rows` =
// the row index to paint (1-based). MUST be called AFTER render() (which paints rows 1..tty_rows-1).
pub fn renderStatus(out: *std.Io.Writer, tty_rows: u16, cols: u16, status: Status) !void

// viewport scroll arithmetic (PURE; all clamp via S1 clampScroll)
pub fn scrollForCursor(cursor_y: u32, viewport: Viewport, total_rows: u32) u32
pub fn centerOnCursor(cursor_y: u32, viewport_rows: u16, total_rows: u32) u32
pub fn topOnCursor(cursor_y: u32) u32
pub fn bottomOnCursor(cursor_y: u32, viewport_rows: u16, total_rows: u32) u32
pub fn pageDown(scroll: u32, total_rows: u32, viewport_rows: u16) u32
pub fn pageUp(scroll: u32, total_rows: u32, viewport_rows: u16) u32
pub fn halfPageDown(scroll: u32, total_rows: u32, viewport_rows: u16) u32
pub fn halfPageUp(scroll: u32, total_rows: u32, viewport_rows: u16) u32
pub fn scrollToBottom(total_rows: u32, viewport_rows: u16) u32

// match finding (PURE; needs a *const Screen to walk cells)
pub fn rowText(alloc: std.mem.Allocator, grid: *const ghostty_vt.Screen, y: u32) ![]u8
pub fn findMatches(alloc: std.mem.Allocator, grid: *const ghostty_vt.Screen, needle: []const u8, mode: SearchMode) ![]Match
pub fn matchCount(matches: []const Match) usize  // == matches.len (single source of truth)
```
