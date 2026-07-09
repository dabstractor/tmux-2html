name: "P3.M1.T2.S2 — Status line (copy-mode style) + viewport scroll + match highlight (src/tui/view.zig additions)"
description: |

---

## Goal

**Feature Goal**: ADD three things to `src/tui/view.zig` (created by the parallel sibling
P3.M1.T2.S1) so the copy-mode TUI can show a live status bar, keep the cursor on-screen through
every scroll motion, and highlight real search matches:

1. **`renderStatus(...)`** — paints the LAST tty row with the PRD §7.1 copy-mode status line:
   `[LINE|BLOCK]  row:N col:M  /pattern  N match(es)  <S-sel>Enter=render q=quit` in reverse-video
   (vim `StatusLine` default = reverse; confirmed convention).
2. **Viewport scroll arithmetic** — a set of PURE functions the input layer (P3.M2.T1.S2 vim
   motions) composes: `scrollForCursor` (keep-cursor-visible), `centerOnCursor`/`topOnCursor`/
   `bottomOnCursor` (zz/zt/zb recenter), `pageUp`/`pageDown`/`halfPageUp`/`halfPageDown`,
   `scrollToBottom`. All clamp via S1's existing `clampScroll`.
3. **Match finding** — `findMatches` (+ `rowText`) scan the captured grid's decoded cell text for
   a needle and produce `[]Match` (per-row cell-column ranges) that S1's `render()` already
   inverts. This makes the status line's `N match(es)` and the grid highlight REAL (not stubs).

v1 is **fixed-string** search — Zig 0.15.2 has **NO `std.regex`** (verified, see Known Gotchas);
regex is deferred to a dependency decision (out of scope). S2 provides the building blocks;
P3.M3 (region.zig) wires them per keystroke, P3.M2 supplies the key/selection state.

**Deliverable** (ALL changes inside the ONE existing file `src/tui/view.zig`; NO new files, NO
main.zig edit, NO build changes — S1 already added `_ = @import("tui/view.zig");` to main.zig's
test block):
- **3 new public types**: `SelMode`, `Status`, `SearchMode`.
- **1 new public paint fn**: `renderStatus(out, tty_rows, cols, status) !void`.
- **9 new public PURE scroll fns** (listed above) — all `u32 → u32`, no I/O, no Terminal.
- **3 new public match fns**: `rowText`, `findMatches`, + PURE internal `findInRow`/`decodeRow`.
- **Tests**: PURE scroll-math table-driven edge cases (separate `test` fns); PURE `renderStatus`
  format assertions (separate `test` fn — no Terminal); PURE `findInRow` assertions (separate
  `test` fn); the Terminal-building `rowText`/`findMatches`/`decodeRow` assertions **appended to
  S1's single render-integration `test` fn** (the ghostty-vt cross-test GOTCHA — separate
  Terminal.init test fns crash). Everything GREEN under `zig build test -Doptimize=ReleaseFast`.

**Nothing else changes**: NO edits to S1's `render()` signature/body, `app.zig`, `render.zig`,
`palette.zig`, `cli.zig`, `capture.zig`, `main.zig`, `build.zig`/`build.zig.zon`, `PRD.md`,
`tasks.json`. Sibling layers (P3.M2 input/select, P3.M3 region) do NOT exist yet — S2's fns are
designed so they PLUG IN later without rewriting view.zig.

**Success Definition**:
- `zig build test -Doptimize=ReleaseFast` passes; S2's new tests + S1's tests + ZERO regressions
  in the rest of the suite. (ReleaseFast MANDATORY — PRD §15 / Debug-mode `zig build test` hits
  the Zig linker bug `R_X86_64_PC64` with the bundled C++ SIMD libs.)
- `zig build -Doptimize=ReleaseFast` compiles — proof the verified Cell/Screen/Style API + the
  `*std.Io.Writer` seam + S1's public types are consumed correctly.
- The status-line BYTES are correct (unit-asserted): CUP to `tty_rows`, reverse SGR `\x1b[7m`,
  the exact field order, trailing EL `\x1b[K`, terminal `\x1b[0m`.
- The scroll math is correct (unit-asserted): keep-visible scrolls minimally; recenter/page/half
  formulas match vim (validated against `:help scroll.txt`); clamps at `[0, max(0,total-rows)]`.
- `findMatches` returns the right per-row cell-column ranges (unit-asserted), including wide-char
  column alignment and multiple hits per row.

## User Persona (if applicable)

**Target User**: `tmux-2html region` (P3.M3 — currently an `error.NotImplemented` stub in
`cli.zig:region`). S2's fns are INTERNAL libraries called by region's per-keystroke loop. No end
user calls them directly.

**Use Case**: PRD §7.1/§7.2/§7.3 — the user triggers `prefix C-o`; region captures the full
scrollback, enters the alt-screen TUI, then per keystroke: updates cursor/selection/pattern
(P3.M2) → if pattern changed, `matches = view.findMatches(grid, pat, .fixed)` →
`viewport.scroll = view.scrollForCursor(cursor, viewport, total)` →
`view.render(&fw.interface, grid, pal, .{cols, tty_rows-1, scroll}, cursor, selection, matches)` →
`view.renderStatus(&fw.interface, tty_rows, cols, .{mode, cursor, pattern, matches, has_sel})` →
`app.runEvents(handler)`. The user sees a vim/tmux-style status bar, the cursor always on-screen,
and live search hits inverted.

**Pain Points Addressed**: The user gets a faithful copy-mode experience — the status bar reports
exactly where the cursor is and how many search hits exist; scroll motions never strand the cursor
off-screen; search is reflected immediately in both the grid and the bar.

## Why

- **PRD §7.1 mandates the status line** (last row, copy-mode style, exact format) AND "cap rendered
  rows to viewport, scroll with the cursor". S1 paints the grid viewport; S2 paints the status row
  + provides the scroll math that "scroll with the cursor" requires.
- **PRD §7.2/§7.3** name the scroll motions (H/M/L, Ctrl-d/u/f/b, PgUp/Dn, gg/G) + search. S2
  provides their SCROLL ARITHMETIC (the input layer P3.M2 composes them) and the MATCH FINDER.
- **arch `tui_region.md` §5/§6** is the verified contract: status line in the last row; highlight
  search matches (reverse video); "Find matches by scanning decoded cell text per row (strip SGR)".
  S2 implements exactly this scan.
- **S1 already inverts `[]Match` in `render()`** — S2 is what PRODUCES that slice (and the count for
  the status line). This is the clean boundary: S1 renders, S2 computes.
- **Forward-compatible seams.** All S2 fns are stateless/pure; P3.M3 only threads updated state per
  keystroke. `SearchMode` reserves `.regex` for a future dependency (the stdlib has none).

## What

### Behavior (`src/tui/view.zig` — ADD to the existing S1 module; std + ghostty-vt + palette)

1. **`renderStatus(out, tty_rows, cols, status)`** paints row `tty_rows` (1-based, the LAST screen
   row — S1's `render()` paints rows `1..tty_rows-1`, so the caller passes `viewport.rows =
   tty_rows-1`). Emits: `\x1b[{tty_rows};1H` (CUP), `\x1b[7m\x1b[1m` (reverse+bold — vim
   `StatusLine` default), the formatted fields, `\x1b[K` (EL — clear stale tail), `\x1b[0m` (reset).
   Field order (PRD §7.1): `[LINE]`/`[BLOCK]` (only when `status.mode != .none`), `row:{y+1}
   col:{x+1}` (1-based, vim/tmux convention), `/{pattern}  {N} match(es)` (only when pattern
   non-null+non-empty; N = `status.matches.len`), `<S-sel>` (only when `status.has_selection`),
   `Enter=render q=quit` (static). A long pattern is truncated so the whole line fits `cols`.
2. **Scroll math (PURE)** — every fn returns a clamped `scroll` (via S1's `clampScroll`); they
   NEVER touch global state. Formulas validated against `:help scroll.txt` (see
   `research/external_scroll_statusline.md`):
   - `scrollForCursor(cursor_y, viewport, total)`: keep-visible. If `cursor_y < scroll` →
     `cursor_y`; if `cursor_y > scroll+rows-1` → `cursor_y-(rows-1)`; else unchanged. Clamp.
   - `centerOnCursor` (zz): `cursor_y - rows/2` (saturating), clamp.
   - `topOnCursor` (zt): `cursor_y`, clamp. `bottomOnCursor` (zb): `cursor_y-(rows-1)` (saturating),
     clamp.
   - `pageDown`/`pageUp`: `±rows`; `halfPageDown`/`halfPageUp`: `±rows/2` (floor); saturating
     subtract, clamp.
   - `scrollToBottom`: `clampScroll(maxInt, total, rows)` = `max(0, total-rows)`.
3. **Match finding** — `findMatches(alloc, grid, needle, mode)` walks every grid row: per row,
   `decodeRow(alloc, grid, y)` returns `{ text: []u8, col: []u16 }` (decoded UTF-8 + a per-byte →
   cell-column map so byte-range hits map to inclusive CELL columns — wide chars keep one col);
   then PURE `findInRow(text, col, needle, y, &list, alloc)` scans with `std.mem.indexOf` (all
   hits) and appends `Match{y, col[bs], col[be-1]}`. `mode` is `.fixed` only in v1 (`.regex`
   reserved). `needle.len==0` ⇒ empty result. Returns an owned `[]Match`.

### Success Criteria

- [ ] `renderStatus` emits the EXACT PRD §7.1 field order with reverse SGR + trailing EL; 1-based
      row:col; `[LINE]`/`[BLOCK]`/omit by mode; `/{pat} {N} match(es)`/omit by pattern; `<S-sel>`/
      omit by has_selection; static hints. Asserted byte-for-byte.
- [ ] All 9 scroll fns match the validated formulas incl. edge cases (cursor above/below viewport,
      `total<=rows` ⇒ 0, clamps at 0 / maxscroll, saturating subtracts).
- [ ] `findMatches` returns correct per-row `[x1..x2]` CELL ranges (ASCII + a wide-char row +
      multiple hits/row + empty needle ⇒ none), all GREEN under `std.testing.allocator` (no leaks).
- [ ] Terminal-building assertions (`decodeRow`/`rowText`/`findMatches`) live in ONE `test` fn
      (appended to S1's render-integration test); PURE fns get separate test fns.
- [ ] `zig build -Doptimize=ReleaseFast` compiles; `zig build test -Doptimize=ReleaseFast` GREEN
      (no regressions). NO new files, NO main.zig/build edits, NO new deps.

## All Needed Context

### Context Completeness Check

_Passed._ An agent who knows nothing about this codebase can implement this from: the S1 CONTRACT
(view.zig's exact public surface — file:line cited in `research/design_notes.md` §0); the VERIFIED
ghostty-vt Cell/Screen/Style API in `../P3M1T2S1/research/ghostty_cell_api.md`; the exact scroll
formulas (vim `:help`-validated) + status-line reverse convention in
`research/external_scroll_statusline.md`; the S2 design (API table + scope boundaries + col_map
decision + std.regex absence + testing strategy) in `research/design_notes.md`; the `*std.Io.Writer`
bridge + cross-test GOTCHA + Allocating-writer test pattern in `src/render.zig`; S1's
`render()`/`cellStyle`/`clampScroll` (reused — read view.zig). Every API fact is pinned to shipped
source; every formula is pinned to vim `:help`.

### Documentation & References

```yaml
# MUST READ — the S1 CONTRACT this PRP builds on (view.zig's exact public surface + the reused fns)
- file: plan/001_0c8587f91cb2/P3M1T2S1/PRP.md
  why: view.zig (created by S1) exports Viewport{cols,rows,scroll}, Pos{x,y}, Selection, Match{y,x1,x2},
       render(out,grid,pal,viewport,cursor,selection,matches), + PURE helpers cellStyle/normSel/
       inSelection/inAnyMatch/highlight/clampScroll(scroll,total_rows,viewport_rows). S2 REUSES
       clampScroll + the cellStyle/cell-walk pattern + the Pos/Match/Viewport types. DO NOT redefine
       them; ADD to the file. render() paints rows 1..viewport.rows; renderStatus paints row tty_rows.
  critical: S2 MUST NOT change render()'s signature/body. render() already inverts []Match — S2
            PRODUCES that slice. clampScroll(scroll:u32, total_rows:u32, viewport_rows:u16)u32 is the
            single clamp every S2 scroll fn funnels through (keeps behavior consistent with S1).

# MUST READ — the S2 design: API table, scope boundaries, col_map decision, std.regex absence, testing
- file: plan/001_0c8587f91cb2/P3M1T2S2/research/design_notes.md
  why: The exact public API S2 exports (SelMode/Status/SearchMode + renderStatus + 9 scroll fns +
       rowText/findMatches); the per-row decodeRow → {text, col:[]u16} design (byte-range → cell-col
       mapping for correct wide-char column alignment); the findInRow PURE split (string in → Match
       out, separately testable); WHY fixed-string v1 (no stdlib regex); the region.zig per-keystroke
       wiring (P3.M3); what S2 does NOT do (key mapping, selection model, capture, loop).
  critical: build col:[]u16 per-byte while walking cells (a wide char's bytes all share one cell col;
            spacer contributes nothing) so a match's x1=col[bs], x2=col[be-1] are inclusive CELL cols.
            Terminal-building tests APPEND to S1's single render test fn (cross-test GOTCHA).

# MUST READ — the validated scroll formulas + status-line reverse-video convention
- file: plan/001_0c8587f91cb2/P3M1T2S2/research/external_scroll_statusline.md
  why: Every S2 scroll fn's formula confirmed against vim :help scroll.txt (keep-visible, H/M/L,
       Ctrl-D/U cursor-moves-with-content, Ctrl-F/B ±rows, zz/zt/zb, gg/G) + the EOF no-empty model
       MAXSCROLL=max(0,total-rows) (matches S1 clampScroll). Status-line: vim StatusLine default =
       term=reverse,bold; tmux message/status/mode-style = distinct non-default bg; reverse-video is
       the acceptable convention for BOTH the status row AND search matches.
  critical: Ctrl-D/U move the CURSOR with the content (same delta, clamped to [0,total-1]); S2 returns
            the new SCROLL (the input layer P3.M2 computes the cursor). Use the NO-EMPTY model
            (MAXSCROLL=total-rows) — consistent with S1 clampScroll; do NOT use vim's total-1 + '~' model.

# MUST READ — the VERIFIED ghostty-vt cell/grid API (decodeRow/findMatches walk cells exactly this way)
- file: plan/001_0c8587f91cb2/P3M1T2S1/research/ghostty_cell_api.md
  why: total_rows = getBottomRight(.screen)→pointFromPin→y+1 (computed ONCE); grid_cols = pages.cols;
       one pages.pin(.{.screen=.{.x=0,.y}}) per row → page.getRow(pin.y) → page.getCells(row) gives the
       full row; Cell.hasText()/codepoint()/content_tag/.wide/lookupGrapheme; switch(.wide){
       .spacer_head,.spacer_tail=>continue, .narrow,.wide=>{} } (mirror S1 render's cell loop);
       cellStyle is S1's VERBATIM ghostty_format copy — reuse it (do not re-copy unless it is file-private
       in S1; if private, expose or re-copy into the decodeRow helper).
  critical: decodeRow's cell walk is S1 render's inner loop MINUS the SGR/CUP — it only collects
            codepoint bytes + records the cell column. lookupGrapheme gives a codepoint_grapheme cell's
            trailing codepoints (append each + record same cell col). A row never spans pages.

# MUST READ — the writer bridge (prod + test) + the cross-test GOTCHA (the single-test-fn rule)
- file: src/render.zig
  why: renderStatus writes to *std.Io.Writer (new IO). PROD bridge: `var fw = stdout.writer(&buf);
       view.renderStatus(&fw.interface, …)`. TEST bridge: `var aw = try std.Io.Writer.Allocating.
       initCapacity(alloc, 4096); defer aw.deinit(); renderStatus(&aw.writer, …); const got =
       aw.writer.buffered();` (render.zig's renderToOwned pattern; dupe to avoid use-after-free on
       deinit if you return the slice). render.zig's GOTCHA (Terminal.init corrupts cross-test state)
       is why ALL Terminal-building assertions share ONE test fn — S2 APPENDS to S1's single view.zig
       render-integration test, it does NOT add a second Terminal.init test fn.
  gotcha: Allocating.deinit frees the buffer that buffered() points into — dupe before deinit if the
          owned bytes must outlive the writer (findMatches returns an owned []Match, not writer bytes,
          so this only applies to renderStatus/decodeRow text-returning test helpers).

# READ — the Cell/Style structs + formatterVt (decodeRow only needs Cell; renderStatus needs no Style)
- file: zig-pkg/ghostty-1.3.1-5UdBCwYm-gQeBa4bu1-sMooCQS4KVriv5wWSIJ_sI-Cb/src/terminal/page.zig
  why: Cell fields (content_tag/content/.wide/style_id) + hasText()/codepoint()/lookupGrapheme — the
       exact accessors decodeRow uses. Verified in ghostty_cell_api.md §4.
- file: src/tui/view.zig  # (S1, EXISTS when S2 starts) — READ it: reuse clampScroll, cellStyle, the
       # cell-walk loop, Pos/Match/Viewport. Confirm cellStyle's visibility (pub vs file-private) to
       # decide reuse-vs-re-copy for decodeRow.

# READ — the contract spec + testing/safety rules
- file: PRD.md
  why: §7.1 (status line format + viewport scroll + match highlight), §7.2 (the scroll motions S2's
       arithmetic serves), §7.3 (search — fixed OR regex; v1 fixed because no stdlib regex), §0 + §15
       (NEVER touch the user's running tmux; ReleaseFast mandatory for tests).

# READ — the architecture doc for the TUI (§5 view + status line; §6 search)
- file: plan/001_0c8587f91cb2/architecture/tui_region.md
  why: §5 = status line (last row) + "highlight search matches (reverse video)"; §6 = "Find matches by
       scanning decoded cell text per row (strip SGR)". S2 implements §5's status line + §6's scan.
  gotcha: §5 mentions diff-rendering — DEFERRED (S1 is full-repaint; S2 adds no diff state).

# EXTERNAL (authoritative; anchors re-verify on load)
- url: https://vimhelp.org/scroll.txt.html
  why: scroll-cursor (keep-visible), H/M/L, CTRL-D/U/F/B, zz/zt/zb — the formula source for S2's math.
- url: https://vimhelp.org/syntax.txt.html#hl-StatusLine
  why: confirms StatusLine default = term=reverse,bold → reverse-video status row is conventional.
- url: https://man.openbsd.org/tmux#COPY_MODE
  why: tmux copy-mode scroll/search semantics + copy-mode-match-style (distinct bg for matches).
```

### Current Codebase tree (relevant slice)

```bash
src/
├── main.zig            # test block (main.zig:483) — ALREADY has `_ = @import("tui/view.zig");` (S1). S2 needs NO edit.
├── render.zig          # ← the *std.Io.Writer bridge (prod+test) + the cross-test GOTCHA doc
└── tui/
    └── view.zig        # ← S1 CREATED it (render + Viewport/Pos/Selection/Match + PURE helpers). S2 ADDS to it.
plan/001_0c8587f91cb2/P3M1T2S2/research/{design_notes,external_scroll_statusline}.md   # THIS PRP's research
plan/001_0c8587f91cb2/P3M1T2S1/research/{ghostty_cell_api,design_notes}.md            # the verified cell API + S1 design
plan/001_0c8587f91cb2/architecture/tui_region.md   # §5/§6 contracts
```

### Desired Codebase tree with files to be added/modified

```bash
src/
└── tui/
    └── view.zig        # MODIFIED — ADD: SelMode/Status/SearchMode + renderStatus + 9 scroll fns +
                        #                  rowText/decodeRow/findInRow/findMatches + tests.
                        #          (S1's render + types + helpers UNCHANGED.)
# NO other files change.
```

### Known Gotchas of our codebase & Library Quirks

```zig
// CRITICAL: `zig build test` (Debug) HITS a Zig linker bug (R_X86_64_PC64) with the bundled C++
//   SIMD libs. Tests MUST run as `zig build test -Doptimize=ReleaseFast` (PRD §15). Every Validation
//   command below uses ReleaseFast.

// CRITICAL: Zig 0.15.2 has NO `std.regex` — VERIFIED (`error: 'std' has no member named 'regex'`;
//   find .../lib/std -iname '*regex*' → only gcc's libphobos). PRD §7.3 says "regex (or fixed-string)"
//   but adding a regex DEPENDENCY needs a build.zig.zon change (FORBIDDEN here) and writing an engine
//   is out of scope. So SearchMode = enum { fixed } (with .regex documented RESERVED). findMatches
//   uses std.mem.indexOf(u8, haystack, needle) per row. Regex is a documented follow-up.

// CRITICAL: ghostty-vt's Terminal.init leaves process-global state corrupted such that a
//   Terminal.init in a SEPARATE test function CRASHES (core dump) (src/render.zig GOTCHA, verified).
//   decodeRow/rowText/findMatches build a Terminal to get a Screen → their assertions MUST share ONE
//   `test` fn — APPEND to S1's single render-integration test in view.zig (do NOT add a 2nd Terminal
//   test fn). PURE fns (scroll math, renderStatus via Status struct, findInRow via string+col_map) get
//   their OWN separate test fns (no Terminal ⇒ safe) — exactly like render.zig's separate
//   determineCols/lineCount/selectionBodyEmpty tests.

// CRITICAL: decodeRow must produce a per-BYTE → cell-column map (col:[]u16, len == text.len) so a
//   match's byte range [bs..be-1] maps to inclusive CELL columns x1=col[bs], x2=col[be-1]. While
//   walking cells left-to-right: for a .narrow/.wide cell, append each emitted UTF-8 byte of its
//   codepoint(s) to `text` AND append the CURRENT cell index to `col` for each such byte. SKIP
//   spacer cells entirely (a wide char's spacer contributes nothing — its column is consumed by the
//   .wide cell; this is what keeps columns aligned, mirroring S1 render's spacer-skip). A wide char's
//   2 columns map: the .wide cell's bytes get col = the wide cell's index; the spacer is skipped, so
//   the NEXT cell's index is wide_idx+2. Correct.

// CRITICAL: scroll subtraction underflow. cursor_y/scroll are u32. `cursor_y - rows/2` and
//   `cursor_y-(rows-1)` and `scroll - rows` can underflow when the operand is small. Use SATURATING
//   subtract: `const half = viewport_rows/2; const c = if (cursor_y >= half) cursor_y - half else 0;`
//   then clampScroll. Never let unsigned subtraction wrap (ReleaseFast = UB on overflow in some
//   cases; Debug traps). Grids are ≤ ~50k rows so `scroll + rows` won't overflow u32 — but still
//   clamp the result.

// CRITICAL: the NO-EMPTY EOF model. MAXSCROLL = max(0, total_rows - viewport_rows) — which is EXACTLY
//   S1's clampScroll(scroll, total_rows, viewport_rows). Use it as the single clamp for every scroll
//   fn. Do NOT use vim's total-1 + '~' empty-line model (no empty markers in this TUI — below-grid
//   rows are erased with EL by S1 render). This keeps S2 consistent with S1's clampScroll.

// GOTCHA: the writer is *std.Io.Writer (the NEW Zig 0.15 IO type). renderStatus(out: *std.Io.Writer,
//   tty_rows: u16, cols: u16, status: Status). region.zig bridges via `var fw = stdout.writer(&buf);
//   view.renderStatus(&fw.interface, …)` (render.zig's proven bridge); tests use
//   std.Io.Writer.Allocating + &aw.writer + aw.writer.buffered(). Do NOT flush mid-render — the
//   caller's buffer coalesces.

// GOTCHA: view.zig imports "../palette.zig" (already, per S1) + ghostty-vt + std. S2 adds NO new
//   imports (findMatches/decodeRow reuse ghostty_vt.Screen/page.Cell already imported by S1; std.mem
//   + std.ArrayList are in std). Confirm cellStyle's visibility: if S1 made it file-private (fn, not
//   pub fn), decodeRow can still call it (same file). If you need it from a test, it's same-file ⇒ OK.

// GOTCHA: std.ArrayList in Zig 0.15.2 is the UNMANAGED variant (allocator-per-method) — see
//   palette.zig GOTCHA 1. `var list: std.ArrayList(Match) = .{};` then `list.append(alloc, m)` /
//   `list.deinit(alloc)` / `list.toOwnedSlice(alloc)`. findMatches owns + returns the slice; the
//   caller (region.zig) frees it with the SAME allocator.

// GOTCHA: S2 does NOT wire region.zig, does NOT implement the key→scroll/selection mapping (P3.M2),
//   and does NOT capture panes (P3.M3). It provides fns; the loop calls them. Do NOT add a status-
//   line field that requires state S2 doesn't own (e.g. don't track the pattern inside view.zig —
//   status.pattern is an INPUT the caller supplies).
```

## Implementation Blueprint

### Data models and structure (ADDITIONAL to S1's Viewport/Pos/Selection/Match)

```zig
// src/tui/view.zig — ADD these (S1's types above stay unchanged).

/// What the status line shows for the selection mode. PRD §7.4: v=linewise, Ctrl-v/R=block.
/// select.zig (P3.M2.T2) owns the model; renderStatus only DISPLAYS the mode it's given.
pub const SelMode = enum { none, line, block };

/// Everything renderStatus needs to paint the PRD §7.1 copy-mode status line. Pure value struct.
/// `matches` is the SAME slice render() inverts (so the "N match(es)" count == the highlighted
/// hits — guaranteed consistent, single source of truth). `pattern` null/empty ⇒ omit the search
/// token. `cursor` is grid coords; renderStatus prints 1-based row:col.
pub const Status = struct {
    mode: SelMode,
    cursor: Pos,              // S1's Pos {x,y}
    pattern: ?[]const u8,
    matches: []const Match,   // count = .len → "N match(es)" (shown only when pattern active)
    has_selection: bool,
};

/// Search mode for findMatches. v1 ships FIXED only: Zig 0.15.2 has no stdlib regex and adding a
/// regex dependency is out of scope (build.zig.zon change). `.regex` is RESERVED for a future task.
pub const SearchMode = enum { fixed };
```

### The status line entry point

```zig
/// Paint the LAST tty row (`tty_rows`, 1-based) with the PRD §7.1 copy-mode status line:
///   [LINE|BLOCK]  row:N col:M  /pattern  N match(es)  <S-sel>Enter=render q=quit
/// Reverse+bold (vim StatusLine default = reverse; convention confirmed). `cols` is the tty width
/// (truncates a long pattern so the line fits; trailing EL clears stale tail). Pure given `status`.
/// Caller (region.zig) calls this AFTER render() (which paints rows 1..tty_rows-1) with the SAME
/// matches slice render() inverted. Writes to `out` (*std.Io.Writer).
pub fn renderStatus(out: *std.Io.Writer, tty_rows: u16, cols: u16, status: Status) !void {
    try out.print("\x1b[{d};1H\x1b[7m\x1b[1m", .{tty_rows}); // CUP to last row + reverse + bold
    var b: [256]u8 = undefined; // the status line is short; 256 is generous
    var fbs = std.Io.Writer.fixed(&b); // build into a fixed buffer
    const w = &fbs.interface;
    // [LINE]/[BLOCK] (omit when none)
    if (status.mode != .none) {
        const tag: []const u8 = if (status.mode == .line) "LINE" else "BLOCK";
        try w.print("[{s}]  ", .{tag});
    }
    // row:N col:M (1-based)
    try w.print("row:{d} col:{d}", .{ status.cursor.y + 1, status.cursor.x + 1 });
    // /pattern  N match(es) (only when a pattern is active)
    if (status.pattern) |p| if (p.len > 0) {
        try w.print("  /{s}  {d} match(es)", .{ p, status.matches.len });
    };
    if (status.has_selection) try w.writeAll("  <S-sel>");
    try w.writeAll("  Enter=render q=quit");
    var line = fbs.getWritten();
    if (line.len > cols) line = line[0..cols]; // truncate to viewport width (no wrap)
    try out.writeAll(line);
    try out.writeAll("\x1b[K\x1b[0m"); // EL (clear stale tail) + reset
}
```
> NOTE: the exact `std.Io.Writer.fixed` / `getWritten` helper names should be confirmed against the
> Zig 0.15.2 std at impl time (the S1 tests use `std.Io.Writer.Allocating` + `buffered()`; an
> Allocating writer is the SAFE fallback if a fixed-buffer writer isn't available — allocate, write,
> `buffered()`, truncate, write to `out`, free). The BYTE OUTPUT (CUP + `\x1b[7m\x1b[1m` + fields +
> `\x1b[K\x1b[0m`) is what the tests assert, not the buffer-building mechanism.

### PURE scroll arithmetic (separate test fns — no Terminal)

```zig
// Every fn returns a scroll clamped to [0, max(0,total-rows)] via S1's clampScroll.
// Formulas validated against vim :help scroll.txt (research/external_scroll_statusline.md).

/// Keep the cursor visible with MINIMAL scroll (the workhorse — call after every cursor move).
/// scroll-cursor semantics (scrolloff=0).
pub fn scrollForCursor(cursor_y: u32, viewport: Viewport, total_rows: u32) u32 {
    const rows = viewport.rows;
    if (total_rows <= rows) return 0;
    const new: u32 = if (cursor_y < viewport.scroll) cursor_y
        else if (cursor_y > viewport.scroll + @as(u32, rows) - 1) cursor_y - (@as(u32, rows) - 1)
        else viewport.scroll;
    return clampScroll(new, total_rows, rows);
}
/// zz: center the viewport on the cursor. cursor UNCHANGED (the input layer keeps it).
pub fn centerOnCursor(cursor_y: u32, viewport_rows: u16, total_rows: u32) u32 {
    const half = @as(u32, viewport_rows) / 2;
    const c = if (cursor_y >= half) cursor_y - half else 0;
    return clampScroll(c, total_rows, viewport_rows);
}
/// zt: cursor at the top of the viewport.
pub fn topOnCursor(cursor_y: u32, viewport_rows: u16, total_rows: u32) u32 {
    return clampScroll(cursor_y, total_rows, viewport_rows);
}
/// zb: cursor at the bottom of the viewport.
pub fn bottomOnCursor(cursor_y: u32, viewport_rows: u16, total_rows: u32) u32 {
    const up = if (@as(u32, viewport_rows) >= 1 and cursor_y >= (@as(u32, viewport_rows) - 1))
        cursor_y - (@as(u32, viewport_rows) - 1) else 0;
    return clampScroll(up, total_rows, viewport_rows);
}
/// Ctrl-f / PgDn: +rows, clamp.
pub fn pageDown(scroll: u32, total_rows: u32, viewport_rows: u16) u32 {
    return clampScroll(scroll + @as(u32, viewport_rows), total_rows, viewport_rows);
}
/// Ctrl-b / PgUp: -rows, saturating, clamp.
pub fn pageUp(scroll: u32, total_rows: u32, viewport_rows: u16) u32 {
    const r = @as(u32, viewport_rows);
    const s = if (scroll >= r) scroll - r else 0;
    return clampScroll(s, total_rows, viewport_rows);
}
/// Ctrl-d: +rows/2, clamp.
pub fn halfPageDown(scroll: u32, total_rows: u32, viewport_rows: u16) u32 {
    return clampScroll(scroll + @as(u32, viewport_rows) / 2, total_rows, viewport_rows);
}
/// Ctrl-u: -rows/2, saturating, clamp.
pub fn halfPageUp(scroll: u32, total_rows: u32, viewport_rows: u16) u32 {
    const half = @as(u32, viewport_rows) / 2;
    const s = if (scroll >= half) scroll - half else 0;
    return clampScroll(s, total_rows, viewport_rows);
}
/// G: max scroll (last line at viewport bottom).
pub fn scrollToBottom(total_rows: u32, viewport_rows: u16) u32 {
    return clampScroll(std.math.maxInt(u32), total_rows, viewport_rows);
}
```

### Match finding (PURE findInRow + Terminal-needing decodeRow/rowText/findMatches)

```zig
/// One grid row decoded to plain UTF-8 + a per-BYTE → cell-column map (len == text.len). A match's
/// byte range [bs..be-1] maps to inclusive CELL columns col[bs]..col[be-1]. Wide-char safe: a .wide
/// cell's bytes share its cell index; its spacer is skipped (so the next cell's index is wide+2).
const DecodedRow = struct { text: []u8, col: []u16 };

/// Walk ONE grid row's cells (the verified S1 path: pin → getRow → getCells) into UTF-8 + col map.
/// Returns empty text/col for rows past the grid (gy >= total_rows). Terminal-needed (Screen walk).
fn decodeRow(alloc: std.mem.Allocator, grid: *const Screen, total_rows: u32, gy: u32) !DecodedRow {
    var text: std.ArrayList(u8) = .{};
    errdefer text.deinit(alloc);
    var col: std.ArrayList(u16) = .{};
    errdefer col.deinit(alloc);
    if (gy >= total_rows) return .{ .text = try text.toOwnedSlice(alloc), .col = try col.toOwnedSlice(alloc) };
    const rp = grid.pages.pin(.{ .screen = .{ .x = 0, .y = gy } }) orelse
        return .{ .text = try text.toOwnedSlice(alloc), .col = try col.toOwnedSlice(alloc) };
    const page = rp.node.data;
    const cells = page.getCells(page.getRow(rp.y));
    const grid_cols = grid.pages.cols;
    var gx: u32 = 0;
    while (gx < grid_cols) : (gx += 1) {
        const cell = cells[gx];
        switch (cell.wide) { .spacer_head, .spacer_tail => continue, .narrow, .wide => {} }
        const cellx: u16 = @intCast(gx);
        // append the primary codepoint's UTF-8 bytes (+grapheme trail), each byte tagged cellx
        var cp_buf: [4]u8 = undefined;
        if (cell.hasText()) {
            const n = std.unicode.utf8Encode(cell.codepoint(), &cp_buf) catch 0;
            for (cp_buf[0..n]) |by| { try text.append(alloc, by); try col.append(alloc, cellx); }
            if (cell.content_tag == .codepoint_grapheme) {
                if (page.lookupGrapheme(&cell)) |trail| for (trail) |cp| {
                    const m = std.unicode.utf8Encode(cp, &cp_buf) catch continue;
                    for (cp_buf[0..m]) |by| { try text.append(alloc, by); try col.append(alloc, cellx); }
                };
        } else { try text.append(alloc, ' '); try col.append(alloc, cellx); } // blank cell → 1 space
        }
    }
    return .{ .text = try text.toOwnedSlice(alloc), .col = try col.toOwnedSlice(alloc) };
}

/// PUBLIC convenience: decode a row to plain text (caller frees). Used by region.zig if it needs
/// the text (e.g. yanking); findMatches calls decodeRow internally.
pub fn rowText(alloc: std.mem.Allocator, grid: *const Screen, total_rows: u32, y: u32) ![]u8 {
    const d = try decodeRow(alloc, grid, total_rows, y);
    alloc.free(d.col);
    return d.text;
}

/// PURE: scan decoded `text` for ALL occurrences of `needle` (std.mem.indexOf loop), map each hit's
/// byte range to inclusive CELL columns via `col`, append Match{y, col[bs], col[be-1]} to `list`.
/// needle.len==0 ⇒ nothing. Multiple hits per row ⇒ multiple Matches.
fn findInRow(text: []const u8, col: []const u16, needle: []const u8, y: u32,
    list: *std.ArrayList(Match), alloc: std.mem.Allocator) !void {
    if (needle.len == 0 or needle.len > text.len) return;
    var start: usize = 0;
    while (start <= text.len - needle.len) {
        const hit = std.mem.indexOfPos(u8, text, start, needle) orelse break;
        const be = hit + needle.len; // exclusive end; last matched byte = be-1
        try list.append(alloc, .{ .y = y, .x1 = col[hit], .x2 = col[be - 1] });
        start = be; // next search starts after this hit (non-overlapping)
    }
}

/// Scan EVERY grid row for `needle`, producing per-row Match ranges (cell columns). v1: fixed-string
/// (SearchMode.fixed only — no stdlib regex). needle.len==0 ⇒ empty result. Caller owns the slice.
pub fn findMatches(alloc: std.mem.Allocator, grid: *const Screen, needle: []const u8,
    mode: SearchMode, total_rows: u32) ![]Match {
    var list: std.ArrayList(Match) = .{};
    errdefer list.deinit(alloc);
    if (mode == .fixed and needle.len > 0) {
        var y: u32 = 0;
        while (y < total_rows) : (y += 1) {
            const d = try decodeRow(alloc, grid, total_rows, y); defer alloc.free(d.text); defer alloc.free(d.col);
            try findInRow(d.text, d.col, needle, y, &list, alloc);
        }
    }
    return list.toOwnedSlice(alloc);
}
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: ADD the 3 public types (SelMode, Status, SearchMode) to src/tui/view.zig — see Data models.
  - PLACE: right after S1's Match type. NAMING: CamelCase types; snake_case fields.
  - GOTCHA: Status.matches is []const Match (the SAME slice render() inverts) so the count is always
    consistent with the highlights. SearchMode is {.fixed} ONLY with a doc comment that .regex is
    RESERVED (no stdlib regex in Zig 0.15.2 — Known Gotcha).

Task 2: ADD the 9 PURE scroll fns (scrollForCursor, centerOnCursor, topOnCursor, bottomOnCursor,
        pageDown, pageUp, halfPageDown, halfPageUp, scrollToBottom) — see PURE scroll arithmetic.
  - DEPENDENCIES: reuse S1's clampScroll (same file). Every fn funnels through clampScroll (NO-EMPTY
    EOF model = S1's model; consistent).
  - GOTCHA: SATURATING subtract (cursor_y - rows/2, scroll - rows) — guard `if (a >= b) a-b else 0`
    BEFORE the subtract (u32 underflow traps in Debug / is UB-adjacent in ReleaseFast). pageDown's
    `scroll + rows` is safe (grids ≤ ~50k rows) but clamp the result.
  - GOTCHA: rows is u16; promote to u32 in arithmetic (@as(u32, viewport_rows)) to avoid u16 overflow
    in `rows - 1` / `rows * ...`. Never compute `rows - 1` in u16 when rows could be 0 (guard).

Task 3: ADD renderStatus + the byte-building helper — see "The status line entry point".
  - IMPLEMENT: CUP to tty_rows; \x1b[7m\x1b[1m; the field-order format; truncate to cols; \x1b[K\x1b[0m.
  - GOTCHA: build the field string in a small fixed/allocated buffer, truncate to cols, THEN write to
    out (so a long pattern doesn't wrap). Field order EXACT: [LINE]/[BLOCK], row:N col:M, /pat N match(es),
    <S-sel>, Enter=render q=quit. 1-based row:col (cursor.y+1, cursor.x+1).
  - GOTCHA: confirm the fixed-buffer-writer helper at impl time; if std.Io.Writer.fixed isn't available,
    use std.Io.Writer.Allocating (alloc, write, buffered(), truncate, free) — the test asserts the BYTES.

Task 4: ADD decodeRow + rowText + findInRow + findMatches — see Match finding.
  - IMPLEMENT: decodeRow walks cells (pin/getRow/getCells — S1's path), appends UTF-8 bytes + per-byte
    cell col (spacer-skip, grapheme trail). findInRow is PURE (indexOf loop → Match{y,col[bs],col[be-1]}).
    findMatches loops rows calling decodeRow+findInRow; returns owned []Match.
  - FOLLOW pattern: S1 render's cell loop (switch .wide; hasText/codepoint/lookupGrapheme). Reuse S1's
    cellStyle if it helps; decodeRow needs no Style (text only).
  - GOTCHA: col[] length MUST == text[] length (per-byte). Wide char: .wide cell's bytes get its col;
    spacer skipped. utf8Encode may error on bad codepoints — `catch 0`/`catch continue` (defensive).
  - GOTCHA: findInRow uses `start <= text.len - needle.len` (needle.len>0 guaranteed by the guard);
    indexOfPos(text, start, needle); non-overlapping (start = be).

Task 5: ADD the PURE unit tests — separate `test` fns (NO Terminal ⇒ safe).
  - scroll math (Task 2): table-driven. scrollForCursor (cursor above/below/in-view; total<=rows⇒0;
    minimal scroll both directions); centerOnCursor/topOnCursor/bottomOnCursor (incl. saturating +
    EOF clamp); pageUp/Down + halfPageUp/Down (clamp at 0/maxscroll; saturating up); scrollToBottom
    (=max(0,total-rows)). Edge: total<=rows ⇒ all return 0; rows=1.
  - renderStatus (Task 3): build a Status, render into Allocating writer, assert exact bytes: CUP
    `\x1b[{tty_rows};1H`, `\x1b[7m\x1b[1m`, `[LINE]`/`[BLOCK]`/omit, `row:N col:M` (1-based),
    `/pat  N match(es)` (N=matches.len)/omit-when-no-pattern, `<S-sel>`/omit, `Enter=render q=quit`,
    trailing `\x1b[K\x1b[0m`. Truncation: a long pattern + small cols ⇒ line truncated to cols.
  - findInRow (Task 4 PURE): feed ("hello world", identity col_map 0..10, "world", y=3) ⇒ one Match
    {y=3, x1=6, x2=10}; ("aaa", cols, "a", 0) ⇒ three Matches {0,0,0}{0,1,1}{0,2,2}; empty needle ⇒ none;
    needle longer than text ⇒ none; a col_map that maps a byte-range to wide-aligned cols ⇒ correct x1/x2.

Task 6: APPEND the Terminal-building assertions (decodeRow/rowText/findMatches) to S1's SINGLE render-
        integration `test` fn in view.zig (the cross-test GOTCHA — do NOT add a 2nd Terminal test fn).
  - IMPLEMENT: build a Screen from ANSI (Terminal.init(cols,rows); feed bytes \n→\r\n; the S1 test
    helper), then: (a) rowText of "hello" row ⇒ "hello"; (b) findMatches(grid, "ll", .fixed, total)
    ⇒ one Match on that row at x1=2,x2=3; (c) a row with a match repeated twice ⇒ two Matches;
    (d) a wide-char row: findMatches for the wide glyph's text ⇒ the Match's x1/x2 are the inclusive
    CELL cols (wide char spans 2 cols; spacer not double-counted); (e) empty needle ⇒ empty slice;
    (f) no leaks under std.testing.allocator (findMatches returns owned []Match → free it).
  - FOLLOW pattern: src/render.zig's renderToOwned (Allocating writer + dupe) + its single-test rule.
  - GOTCHA: Terminal.init corrupts cross-test state ⇒ ONE test fn for all Terminal assertions. Free
    every owned slice (decodeRow text+col; findMatches []Match; rowText text) before the fn ends.
```

### Implementation Patterns & Key Details

```zig
// Reuse S1's clampScroll as the SINGLE clamp (NO-EMPTY model, consistent with S1):
//   clampScroll(scroll, total_rows, viewport_rows) => if (total<=rows) 0 else min(scroll, total-rows)
pub fn scrollForCursor(cursor_y: u32, viewport: Viewport, total_rows: u32) u32 {
    if (total_rows <= viewport.rows) return 0;
    const last = viewport.scroll + @as(u32, viewport.rows) - 1; // last visible grid row
    const new = if (cursor_y < viewport.scroll) cursor_y
        else if (cursor_y > last) cursor_y - (@as(u32, viewport.rows) - 1)
        else viewport.scroll;
    return clampScroll(new, total_rows, viewport.rows);
}

// Saturating subtract (avoid u32 underflow):
const half = @as(u32, viewport_rows) / 2;
const centered = if (cursor_y >= half) cursor_y - half else 0;

// Status line: reverse+bold, then EL+reset (vim StatusLine default = reverse; EL clears stale tail):
try out.print("\x1b[{d};1H\x1b[7m\x1b[1m", .{tty_rows});
// …fields… (truncate to cols)
try out.writeAll("\x1b[K\x1b[0m");

// Match's inclusive CELL columns from a byte range (col is per-byte → cell index):
try list.append(alloc, .{ .y = y, .x1 = col[hit], .x2 = col[hit + needle.len - 1] });
```

### Integration Points

```yaml
BUILD:
  - change: NONE. S2 adds functions/types to the EXISTING src/tui/view.zig (S1 created it). view.zig
    is already reachable from the test binary (S1's main.zig test-block import) + the exe (via the
    root module). No build.zig / build.zig.zon edit. No new deps (std.mem/std.ArrayList/std.unicode +
    ghostty-vt are already imported by S1).
  - verify: `zig build -Doptimize=ReleaseFast` succeeds; `zig build test -Doptimize=ReleaseFast` GREEN.

MAIN.ZIG:
  - change: NONE. S1 already added `_ = @import("tui/view.zig");` to the test block. S2's new tests
    live in view.zig ⇒ reachable via that existing import.

FUTURE CONSUMERS (do NOT implement now — boundary docs only):
  - P3.M2.T1 (input.zig + vim motions): calls the scroll fns. e.g. on Ctrl-d: new_scroll =
    halfPageDown(viewport.scroll, total, rows); cursor moves +rows/2 clamped to [0,total-1] (Ctrl-d
    moves the cursor WITH the content); viewport.scroll = scrollForCursor(cursor, .{cols,rows,new_scroll},
    total). On H/M/L: NO scroll fn — set cursor = scroll / scroll+rows/2 / scroll+rows-1 (scroll
    unchanged). On gg/G: scroll = 0 / scrollToBottom(total,rows). On /pat: pattern set; matches =
    findMatches(grid, pat, .fixed, total).
  - P3.M2.T2 (select.zig): reports SelMode (.none/.line/.block) + has_selection to renderStatus.
  - P3.M3.T1 (region.zig): per keystroke — update state → if pattern changed matches=findMatches →
    viewport.scroll=scrollForCursor → render(rows=tty_rows-1) → renderStatus(tty_rows) → runEvents.
```

## Validation Loop

> **MANDATORY:** every `zig build` / `zig build test` below uses `-Doptimize=ReleaseFast`
> (PRD §15 / main.zig Gotcha: Debug-mode `zig build test` hits the Zig linker bug
> `R_X86_64_PC64` with the bundled C++ SIMD libs; ReleaseFast is unaffected).

### Level 1: Syntax & Style (Immediate Feedback)

```bash
cd /home/dustin/projects/tmux-2html
# Compile the whole binary in ReleaseFast — proof the new types/fns + S1's reused surface +
# the *std.Io.Writer seam + the verified Cell/Screen API are used correctly.
zig build -Doptimize=ReleaseFast
# Expected: zero errors. If a type name, clampScroll/Pos/Match/Viewport reuse, the Status struct,
# the scroll fn arithmetic, the decodeRow cell walk, or the renderStatus byte-build is wrong, it
# fails HERE — read the error, fix against research/design_notes.md + ghostty_cell_api.md.
```

### Level 2: Unit Tests (PURE helpers + the single Terminal integration test)

```bash
cd /home/dustin/projects/tmux-2html
zig build test -Doptimize=ReleaseFast
# Expected: all GREEN — S2's PURE tests (scroll math, renderStatus, findInRow) + S2's appended
# Terminal assertions (decodeRow/rowText/findMatches) + S1's tests + ZERO regressions in the rest
# of the suite (app.zig, render.zig, palette.zig, capture.zig, golden_test.zig).
#
# The tests to ADD (in src/tui/view.zig):
#   PURE SCROLL MATH (separate test fns — no Terminal):
#     - scrollForCursor: total=20,rows=5,scroll=10 ⇒ cursor 8→scroll8 (above); cursor 16→scroll12
#       (below, minimal); cursor 12→scroll10 (in view, unchanged); total=3,rows=5 ⇒ any cursor⇒0.
#     - centerOnCursor: rows=10,total=20 ⇒ cursor 15⇒scroll10 (15-5); cursor 2⇒scroll0 (saturate).
#     - topOnCursor: cursor 17,rows=5,total=20 ⇒ scroll 15 (clamped: maxscroll=15, 17>15 ⇒ 15).
#     - bottomOnCursor: cursor 17,rows=5,total=20 ⇒ scroll 13 (17-4).
#     - pageDown/pageUp: scroll 10,rows=5,total=20 ⇒ down 15, up 5; scroll 2 pageUp ⇒ 0 (saturate).
#     - halfPageDown/halfPageUp: scroll 10,rows=10,total=20 ⇒ down 15 (+5), up 5 (-5); scroll 2
#       halfPageUp ⇒ 0 (saturate).
#     - scrollToBottom: total=20,rows=5 ⇒ 15 (=max(0,20-5)); total=3,rows=5 ⇒ 0.
#   renderStatus (separate test fn — no Terminal, Status struct only):
#     - mode=.line, cursor{2,3}, pattern="foo", matches=[_,_,_] (len 3), has_sel=true ⇒ output
#       contains "\x1b[{tty};1H\x1b[7m\x1b[1m", "[LINE]", "row:3 col:4", "/foo  3 match(es)",
#       "<S-sel>", "Enter=render q=quit", and ends with "\x1b[K\x1b[0m".
#     - mode=.block ⇒ "[BLOCK]"; mode=.none + no pattern + no sel ⇒ no bracket, no /pat, no <S-sel>.
#     - 1-based: cursor.y=0,x=0 ⇒ "row:1 col:1".
#     - truncation: pattern long + cols=10 ⇒ the emitted line ≤ 10 bytes before the EL.
#   findInRow (separate test fn — PURE, string+col_map):
#     - ("hello world", [0..10 identity], "world", 3) ⇒ [{3,6,10}]; ("aaa",identity,"a",0) ⇒
#       [{0,0,0},{0,1,1},{0,2,2}]; ("",identity,"x",0) ⇒ []; ("ab",identity,"abcd",0) ⇒ [];
#       a col_map mapping bytes 0..3 → cols [5,5,6,6] (a wide-ish 2-col scenario) with needle covering
#       bytes 1..2 ⇒ x1=col[1]=5, x2=col[2]=6.
#   TERMINAL (ONE test fn — APPENDED to S1's render integration test; the cross-test GOTCHA):
#     - feed "hello\nworld"; rowText(y=0) == "hello"; findMatches(grid,"ll",.fixed,total) ⇒
#       [{y=0,x1=2,x2=3}]; findMatches(grid,"o",.fixed,total) ⇒ two Matches (y0 x4..4, y1 x1..1);
#       findMatches(grid,"",.fixed,total) ⇒ empty slice; a CJK row findMatches ⇒ x1/x2 inclusive
#       cell cols (wide spans 2, spacer not counted); no leaks (free every owned slice).
```

### Level 3: Integration / manual check (real tty — deferred to P3.M3)

> S2's fns are PURE/render-helpers (write to a `*std.Io.Writer` or return values); they are FULLY
> unit-tested (Level 2). The LIVE status-bar paint + live scroll + live search are proven when
> region.zig (P3.M3) wires enter()→render()→renderStatus()→runEvents() in a real display-popup pty
> (isolated tmux server per PRD §0/§15). **Do NOT wire region here.** This Level 3 asserts wiring +
> structure invariants only.

```bash
cd /home/dustin/projects/tmux-2html
# (a) Confirm S2 added NO new files + NO main.zig/build edits (view.zig is the only change):
git status --short src/ build.zig build.zig.zon            # ONLY src/tui/view.zig modified
# (b) Confirm the new public surface exists:
grep -n 'pub const SelMode = struct\|pub const Status = struct\|pub const SearchMode = enum' src/tui/view.zig
grep -n 'pub fn renderStatus(' src/tui/view.zig
grep -n 'pub fn scrollForCursor\|pub fn centerOnCursor\|pub fn topOnCursor\|pub fn bottomOnCursor' src/tui/view.zig
grep -n 'pub fn pageDown\|pub fn pageUp\|pub fn halfPageDown\|pub fn halfPageUp\|pub fn scrollToBottom' src/tui/view.zig
grep -n 'pub fn findMatches(\|pub fn rowText(' src/tui/view.zig
# (c) Confirm S2 reuses S1's clampScroll (single clamp) + reverse-video status + EL tail:
grep -n 'clampScroll(' src/tui/view.zig                      # the scroll fns funnel through it
grep -n '\\x1b\[7m' src/tui/view.zig                         # reverse-video status line
grep -n '\\x1b\[K\\x1b\[0m' src/tui/view.zig                 # EL + reset tail
# (d) Confirm S2 did NOT touch siblings + did NOT add a regex dep / new file:
! grep -n '@import("regex")\|std.regex' src/tui/view.zig     # no stdlib regex (grep exits 1)
git status --short src/tui/app.zig src/render.zig src/palette.zig src/cli.zig src/main.zig   # all clean
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Confirm the three pillars are structurally present + the scope boundaries hold:
#   1. status line (reverse, last row, PRD field order)   2. scroll math (clamp via S1)   3. match finder
grep -n 'tty_rows;1H' src/tui/view.zig                       # CUP to last row (pillar 1)
grep -n 'row:{d} col:{d}' src/tui/view.zig                   # PRD field order
grep -n 'match(es)' src/tui/view.zig                         # N match(es)
grep -n 'pub fn scrollForCursor\|pub fn pageDown\|pub fn halfPageUp' src/tui/view.zig  # pillar 2
grep -n 'pub fn findMatches(' src/tui/view.zig               # pillar 3
grep -n 'indexOfPos' src/tui/view.zig                        # fixed-string scan (no regex)
# Confirm the col_map invariant (per-byte → cell col) for wide-char correctness:
grep -n 'col.append' src/tui/view.zig                        # every text byte gets a col entry
# Confirm S1's render() is UNCHANGED (S2 only ADDED):
git diff src/tui/view.zig | grep -E '^-.*pub fn render\(' | head   # empty ⇒ render() not deleted/rewritten
```

## Final Validation Checklist

### Technical Validation

- [ ] `zig build -Doptimize=ReleaseFast` succeeds (S2 types/fns + reused S1 surface + `*std.Io.Writer` seam + verified Cell/Screen API correct).
- [ ] `zig build test -Doptimize=ReleaseFast` is GREEN — S2's PURE tests (scroll/renderStatus/findInRow) + S2's appended Terminal assertions + S1's tests + ZERO regressions (app.zig/render.zig/palette.zig/capture.zig/golden_test.zig).
- [ ] NO new files; ONLY `src/tui/view.zig` modified; NO main.zig/build.zig/build.zig.zon edits; NO new deps.

### Feature Validation

- [ ] `renderStatus` emits the EXACT PRD §7.1 field order (byte-asserted): `[LINE]`/`[BLOCK]`/omit, `row:N col:M` (1-based), `/pat  N match(es)`/omit, `<S-sel>`/omit, `Enter=render q=quit`, reverse SGR, trailing EL+reset; truncates to `cols`.
- [ ] All 9 scroll fns match the validated formulas incl. edge cases (keep-visible minimal; recenter/page/half; saturating subtracts; clamps at `[0, max(0,total-rows)]`; `total<=rows ⇒ 0`).
- [ ] `findMatches` returns correct per-row inclusive CELL-column ranges (ASCII, multi-hit/row, wide-char alignment, empty-needle⇒none), no leaks.
- [ ] S1's `render()` signature/body UNCHANGED; S2 only ADDS to view.zig.

### Code Quality Validation

- [ ] Scroll fns funnel through S1's `clampScroll` (single clamp; NO-EMPTY model consistent with S1).
- [ ] `decodeRow` builds a per-byte `col:[]u16` (len == text.len); spacer-skip mirrors S1 render.
- [ ] Terminal-building assertions share ONE `test` fn (appended to S1's render test); PURE fns are separate test fns.
- [ ] No new deps; `std.regex` NOT used (fixed-string v1); `../palette.zig`/ghostty-vt imports unchanged.
- [ ] No edits to siblings (app.zig/render.zig/palette.zig/cli.zig/capture.zig/main.zig/build).

### Documentation & Deployment

- [ ] Code is self-documenting (each scroll fn cites the vim motion; renderStatus cites PRD §7.1; findMatches documents the fixed-string v1 + reserved `.regex`).
- [ ] The `SelMode`/`Status`/`SearchMode` types + the scroll/match fns document their forward-contract role (P3.M2 supplies state; P3.M3 wires the loop).

---

## Anti-Patterns to Avoid

- ❌ Don't change S1's `render()` signature or body — S2 ADDS to view.zig; render() already inverts `[]Match`.
- ❌ Don't use `std.regex` — it does NOT exist in Zig 0.15.2 (verified). v1 is fixed-string via `std.mem.indexOf`; `.regex` is RESERVED (a dependency decision, not this subtask).
- ❌ Don't add a second `Terminal.init` test fn — ghostty-vt corrupts cross-test state. APPEND Terminal assertions to S1's single render-integration test; PURE fns get separate test fns.
- ❌ Don't compute `rows - 1` / `cursor_y - rows/2` / `scroll - rows` in raw u32 — SATURATE (`if (a>=b) a-b else 0`) to avoid underflow (Debug traps / ReleaseFast UB-adjacent).
- ❌ Don't hand-roll the clamp — funnel every scroll fn through S1's `clampScroll` (single source; NO-EMPTY model consistent with S1).
- ❌ Don't map match byte-ranges to columns by assuming ASCII — build the per-byte `col:[]u16` while walking cells (wide chars + multi-byte UTF-8 + grapheme trails need it). `col.len == text.len`.
- ❌ Don't forget the status-line trailing `\x1b[K` (EL) — a shorter current frame would leave stale chars from a longer previous status line (same rationale as S1's below-grid EL).
- ❌ Don't implement the key→scroll/selection mapping (P3.M2), the selection model (P3.M2.T2), capture (P3.M3), or the TUI loop (P3.M3) — S2 provides fns; the loop calls them.
- ❌ Don't track the pattern/matches inside view.zig — `status.pattern`/`matches` are INPUTS the caller (region.zig/P3.M2) supplies; view.zig is stateless.
- ❌ Don't hardcode the status line in region.zig or a new file — it lives in view.zig (the one view module) per the S1/S2 split.
- ❌ Don't add new files / main.zig edits / build changes — S1 already imported view.zig; S2 only modifies view.zig.
