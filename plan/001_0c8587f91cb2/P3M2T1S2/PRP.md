name: "P3.M2.T1.S2 — Vim motions + search navigation engine (src/tui/motion.zig)"
description: |
  The PURE cursor/motion/search NAVIGATION engine for the copy-mode TUI. Consumes the decoded
  `input.Key` (P3.M2.T1.S1, SHIPPED) + `view`'s types + scroll math + `findMatches` scan
  (P3.M1.T2, SHIPPED) and produces a `Cursor` model + PURE motion primitives + `applyMotion`
  dispatcher + `SearchState`/`nextMatch` navigation. NEW file `src/tui/motion.zig` + ONE import
  line in `src/main.zig`. No deps, no build.zig change, no edits to view/input/app.

---

## Goal

**Feature Goal**: Implement the cursor-motion + search-navigation ENGINE behind PRD §7.2 (vim
movements: `h j k l`, `w b e`, `0 ^ $`, `gg`/`G`, `Ctrl-d/u` half-page, `Ctrl-f/b` full-page,
`H M L`, `{ }`, `%`, all with count prefixes) and §7.3 (`/` `?` `n` `N` navigation over a
match list). Every motion is applied to a cursor model with viewport side-effects; search
navigation moves the cursor through an externally-produced match list with wraparound.

**Deliverable**:
1. **NEW FILE** `src/tui/motion.zig` — a PURE, ghostty-vt-free engine containing:
   `Cursor`, `Row`, `Grid` (seam), `SliceGrid` (test), `Direction`, `SearchState`, Row helpers,
   motion primitives (`wordForward`/`wordBackward`/`wordEnd`/`matchBracket`/`paragraphBack`/
   `paragraphFwd`), the `applyMotion` dispatcher (all 21 `input.Motion` variants), and
   `nextMatch`/`prevMatch` search navigation — all PURE and fully unit-tested.
2. **ONE-LINE EDIT** to `src/main.zig` test block: add `_ = @import("tui/motion.zig");` so the
   engine's tests are reachable from the test root.

**Success Definition**: `zig build test -Doptimize=ReleaseFast` passes (all existing tests +
ALL new motion.zig tests). Every motion variant moves the cursor to the exact documented cell,
every page/half-page/G/gg motion recomputes `viewport.scroll` via the SHIPPED `view` scroll math,
and search `n`/`N` with wraparound lands on the correct match. No new dependencies; no edits to
`view.zig`/`input.zig`/`app.zig`/`build.zig`/`build.zig.zon`.

## User Persona (if applicable)

**Target User**: tmux user invoking the interactive `region` copy-mode overlay (PRD §7) to
navigate captured scrollback with vim-style keys, then confirm a selection to render to HTML.

**Use Case**: User presses `5j` to move down 5 rows, `w` to jump to the next word, `/error` to
search, `n`/`N` to hop between matches, `Ctrl-d` to half-page-scroll — all while the viewport
follows the cursor.

**User Journey**: (wired by P3.M3 region.zig, which OWNS a `Cursor` + `SearchState` in its event
handler) — `app.readEvent → input.decode → input.Key → motion.applyMotion(cursor, key, grid) →
repaint` / `motion.nextMatch(state, cursor, dir) → cursor.pos → scrollForCursor → repaint`.

**Pain Points Addressed**: Full-vim copy-mode navigation fidelity in a custom Zig TUI without the
complexity of a full vim; predictable, testable, deterministic motion semantics.

## Why

- **Completes the TUI input pipeline**: P3.M2.T1.S1 SHIPPED the key DECODER (`input.Key`); this
  subtask ships the ENGINE that consumes it. Without it, the decoded keys do nothing.
- **Reuses, never duplicates**: consumes the SHIPPED `view` scroll math + `findMatches` scan —
  `motion.zig` is a thin, PURE composition layer (no Terminal, no re-derivation of scroll formulas).
- **Unblocks siblings**: P3.M2.T2 (`select.zig`) reads `cursor.pos`; P3.M3 (`region.zig`) owns the
  `Cursor` + `SearchState` and wires `input.Key → applyMotion/nextMatch`. This engine is their
  foundation.

## What

A new `src/tui/motion.zig` that:
- Defines `Cursor{ pos: view.Pos, viewport: view.Viewport }` (the navigable cursor state).
- Defines a line-provider `Grid` seam (`ctx:*anyopaque` + `getRowFn` + `total_rows` + `cols`) +
  `Row{ text: []const u8, col: []const u16 }` (per-byte → cell-column map, wide-char-correct).
- Implements PURE Row helpers + motion primitives over borrowed `Row`s (no allocation).
- Implements `applyMotion(cursor, motion, count, grid) Cursor` — exhaustive `switch` over all 21
  `input.Motion` variants, updating `pos` and recomputing `viewport.scroll` via `view`'s fns.
- Implements `SearchState{ matches, current, direction }` + `nextMatch(state, cursor, dir) ?Pos`
  (strictly-after + wraparound; `prevMatch` = `nextMatch` with the opposite direction).
- Is PURE (no I/O, no allocation, no `ghostty-vt` import) ⇒ its tests run as SEPARATE `test` fns
  (NO Terminal is ever constructed ⇒ the ghostty-vt cross-test GOTCHA does NOT apply).

### Success Criteria

- [ ] All 21 `input.Motion` variants move the cursor to the exact documented cell (per the table
      in `plan/.../research/design_notes.md §3` + `vim_motion_semantics.md`).
- [ ] Counts apply correctly: `5j`, `2$` (end of next row), `5G`→row4, `5gg`→row4, plain `G`→last
      row, plain `gg`→row0, `5w`, `3{`, etc.
- [ ] Page/half-page/G/gg motions update `viewport.scroll` via the SHIPPED `view` scroll fns.
- [ ] After any motion, `viewport.scroll` keeps the cursor visible (via `view.scrollForCursor`).
- [ ] `%` matches `()[]{}` across rows with nesting depth; not-on-bracket ⇒ line-forward-search;
      unbalanced ⇒ no move (return null ⇒ cursor unchanged).
- [ ] `{`/`}` jump to the nearest all-blank row strictly above/below; count repeats.
- [ ] `nextMatch` returns the first match strictly after (forward) / before (backward) the cursor,
      with wraparound; empty matches ⇒ null.
- [ ] `zig build test -Doptimize=ReleaseFast` passes; no leaks (test allocator where applicable).

## All Needed Context

### Context Completeness Check

_If someone knew nothing about this codebase, would they have everything needed to implement this
successfully?_ **YES.** This PRP embeds the exact API to consume (S1 `input.Key`/`Motion`), the
exact SHIPPED `view` symbols to reuse (with file:line), the authoritative motion semantics table,
the `%` bracket-matching algorithm, the full per-variant `applyMotion` rules, the search
navigation contract, the testing seam (`SliceGrid`), and the precise build/test commands.

### Documentation & References

```yaml
# MUST READ — the authoritative spec for THIS module (already in the research/ dir)
- docfile: plan/001_0c8587f91cb2/P3M2T1S2/research/design_notes.md
  why: The COMPLETE API + per-variant motion table + matchBracket algorithm + scope boundaries +
       testing strategy + Zig/ghostty-vt gotchas. This IS the build spec — read it end-to-end.
  section: "§1 The public API (the contract surface)" + "§3 applyMotion per-variant table"

- docfile: plan/001_0c8587f91cb2/P3M2T1S2/research/vim_motion_semantics.md
  why: Authoritative vim semantics for EVERY motion, with the TUI-SIMPLIFICATIONS explicitly
       adopted (two-class WORD model for w/b/e; nearest-blank-row for {/}; bracket-match-only for
       %). The "Count-semantics summary" table is the source of truth for count handling.
  section: "Count-semantics summary (this TUI's adopted behavior)"

- file: src/tui/input.zig
  why: The DECODER CONTRACT — CONSUME its `Key{count:u32=1, kind}`, `KeyKind`, `Motion` (21
       variants), `Action`, `Search`. Do NOT re-implement decoding. `applyMotion` switches on
       `input.Motion`; `SearchState` mirrors the `Direction` of the last `/`/`?`.
  pattern: enum `Motion` has exactly: left,right,up,down,word_fwd,word_back,word_end,line_start,
       first_nonblank,line_end,doc_top,doc_bottom,half_page_down,half_page_up,page_down,page_up,
       viewport_top,viewport_mid,viewport_bottom,paragraph_back,paragraph_fwd,match_bracket.
  gotcha: "`input.Key.count` defaults to 1 with NO `has_count` field — plain `G` is INDISTINGUISHABLE
       from `1G`. applyMotion resolves `.doc_bottom` with count<=1 ⇒ LAST row (documented v1 limit).
       Do NOT try to 'fix' this; it is a deliberate decoder property."

- file: src/tui/view.zig
  why: REUSE its types + scroll math + search scan — single source of truth (NO duplication).
       Types (src/tui/view.zig:40-76): `Pos{x:u32,y:u32}`, `Viewport{cols:u16,rows:u16,scroll:u32}`,
       `Match{y:u32,x1:u32,x2:u32}`. Scroll fns (src/tui/view.zig:459-534): clampScroll,
       scrollForCursor, centerOnCursor, topOnCursor, bottomOnCursor, pageDown, pageUp,
       halfPageDown, halfPageUp, scrollToBottom. Scan fn: findMatches(alloc, *const Screen, needle,
       .fixed, total_rows) []Match (SHIPPED — motion.zig NAVIGATES only, never re-scans).
  pattern: motion.zig calls e.g. `view.scrollForCursor(cursor.pos.y, cursor.viewport, total_rows)`
       with the SAME arg shapes view.zig's own tests use (src/tui/view.zig test fns).
  gotcha: "SearchMode is `{fixed}` only (Zig 0.15.2 has NO stdlib regex). `.regex` is RESERVED
       for a future task. findMatches is view's job; motion.zig consumes the []Match it returns."

- file: src/tui/app.zig
  why: Pipeline context only — `Event` union (key:u8 / mouse / seq:EscSeq / eof), `Input`,
       `readEvent`, `EventHandler`, `runEvents`. motion.zig does NOT import app.zig (it consumes
       `input.Key`, which is downstream of app.Event). Read to understand WHERE motion.zig plugs
       in: region.zig (P3.M3) owns a Cursor + SearchState in its EventHandler ctx.
  pattern: The EventHandler ctx-pointer + fn-pointer seam (app.zig:461) is the PATTERN motion.zig's
       `Grid` seam mirrors (`ctx:*anyopaque` + one fn pointer + `@ptrCast(@alignCast(ctx))`).

- docfile: plan/001_0c8587f91cb2/architecture/tui_region.md
  why: The TUI layering overview — §3 (key decode), §4 (selection model, P3.M2.T2), §6 (search).
       Confirms `/pattern` typing is collected by region.zig (decoder idle) then findMatches runs.
  section: "§3 Key decoding" + "§6 Search"

- url: https://vimhelp.org/motion.txt.html
  why: Authoritative vim motion reference. Cited as `:help <tag>` in vim_motion_semantics.md.
       Consult ONLY to resolve ambiguity; the adopted TUI simplifications OVERRIDE full-vim.
  critical: "Do NOT implement full three-class `w/b/e` — this TUI uses the two-class WORD model
       (a word = a maximal run of NON-WHITESPACE), == vim's uppercase W/B/E. Documented divergence."
```

### Current Codebase tree (run `tree` in the root of the project)

```bash
$ tree src/ -I 'zig-cache' --dirsfirst
src/
├── tui/
│   ├── app.zig        # P3.M1.T1 — Event/Input/readEvent/runEvents + alt-screen + mouse (SHIPPED)
│   ├── input.zig      # P3.M2.T1.S1 — key DECODER: Key/Motion/Action/Search/Decoder/feed/decode (SHIPPED — CONTRACT)
│   └── view.zig       # P3.M1.T2 — render + scroll math + findMatches scan + Pos/Viewport/Match (SHIPPED — REUSE)
├── capture.zig        # P2.M1 — pane capture (region.zig P3.M3 will reuse its full mode)
├── cli.zig            # parg flag parser
├── ghostty_format.zig # vendored Cell→Style formatter
├── golden_test.zig    # P1.M4 golden harness
├── main.zig           # dispatch + top-level test{} block (ADD ONE @import line HERE)
├── palette.zig        # P1.M2 — queryColors + cache + resolve
└── render.zig         # P1.M3 — renderGrid (HTML)
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
src/
├── tui/
│   ├── app.zig        # UNCHANGED
│   ├── input.zig      # UNCHANGED (consumed as a contract)
│   ├── view.zig       # UNCHANGED (consumed: types + scroll fns + findMatches)
│   └── motion.zig     # NEW — the PURE cursor/motion/search NAVIGATION engine (THIS subtask)
└── main.zig           # ONE new line in the test{} block: `_ = @import("tui/motion.zig");`
```

`src/tui/motion.zig` responsibilities (the ONLY new file):
- `Cursor` (navigable cursor state: pos + viewport).
- `Row` / `Grid` / `SliceGrid` (the line-provider seam + its test impl).
- `Direction` / `SearchState` (search navigation state).
- Row helpers + motion primitives + `applyMotion` (the 21-variant dispatcher).
- `nextMatch` / `prevMatch` (match-list navigation with wraparound).
- Comprehensive `test` fns (separate fns — motion.zig never constructs a Terminal).

### Known Gotchas of our codebase & Library Quirks

```zig
// CRITICAL: zig build test MUST use -Doptimize=ReleaseFast. Debug hits the R_X86_64_PC64 linker
//   bug with the bundled ghostty C++ SIMD libs (PRD §15; confirmed across all sibling PRPs).
//   EVERY validation command in this PRP uses `zig build test -Doptimize=ReleaseFast`.

// CRITICAL: input.Key.count defaults to 1 (NO has_count field). Plain `G` ≡ `1G` to the engine.
//   applyMotion resolves `.doc_bottom` count<=1 ⇒ LAST row (total_rows-1); count>=2 ⇒ row count-1.
//   This is a DELIBERATE decoder property (S1) — do NOT "fix" it; document it as a v1 limitation.

// CRITICAL: motion.zig REUSES view's scroll math (scrollForCursor, pageDown, halfPageDown,
//   scrollToBottom, topOnCursor, etc.). Do NOT re-derive scroll formulas — view's are unit-tested
//   (src/tui/view.zig:459-534); duplicating risks divergence. Call them with the SAME arg shapes.

// CRITICAL: Row.col maps BYTE index → CELL column (wide-char-correct). Motions compute a target
//   BYTE index in row.text, then set pos.x = row.col[byte]. For ASCII col[i]==i (trivial); for
//   wide chars a .wide cell's bytes SHARE its col index and its spacer is SKIPPED (mirrors
//   view.decodeRow). Tests use identity col arrays for the bulk + hand-crafted maps for wide cases.

// CRITICAL: Borrowed Row lifetime. Grid.getRow returns a Row whose slices are valid ONLY until the
//   NEXT getRow call (the seam contract). Motions READ text+col, compute a new pos, and do NOT
//   retain the Row. SliceGrid returns stable static slices; the prod ScreenGrid (P3.M3) reuses a
//   buffer. NEVER store a Row across getRow calls.

// CRITICAL: NO Terminal in motion.zig. The ghostty-vt cross-test GOTCHA (src/render.zig,
//   src/tui/view.zig): a Terminal.init in a SEPARATE test fn CRASHES via process-global state
//   corruption. motion.zig NEVER imports ghostty-vt and NEVER constructs a Terminal ⇒ its PURE
//   tests are SAFE as separate `test` fns (mirrors app.zig + input.zig).

// CRITICAL: `@ptrCast(@alignCast(ctx))` is MANDATORY to recover the typed Grid impl pointer inside
//   getRowFn (Zig 0.15.2; mirrors capture.zig, app.FdInput, input.SliceEventReader). SliceGrid must
//   be a stack `var sg` so `&sg` is `*SliceGrid` (a const yields `*const T` which does NOT coerce).

// CRITICAL: u32 saturating subtract for upward motions (k / Ctrl-u / Ctrl-b / { / wordBackward):
//   `y >= count ? y - count : 0`. Plain `y - count` UNDERFLOWS in Debug (trap) / is UB-adjacent in
//   ReleaseFast. Same pattern view.zig's pageUp/halfPageUp already use.

// CRITICAL: the `switch (m)` on input.Motion MUST be exhaustive (21 variants). Zig errors at
// compile time if one is missed — use this as a checklist while implementing.
```

## Implementation Blueprint

### Data models and structure

`src/tui/motion.zig` defines ONLY value structs + a function-pointer seam (no ghostty-vt, no
allocation, no I/O). Mirrors the contract in `research/design_notes.md §1`:

```zig
const std = @import("std");
const view = @import("view.zig");   // Pos, Viewport, Match, scroll fns (SHIPPED — reuse)
const input = @import("input.zig"); // Key, Motion, Action, Search (S1 CONTRACT — consume)

/// The navigable cursor state. select.zig (P3.M2.T2) reads .pos; region.zig (P3.M3) OWNS a
/// Cursor in its EventHandler ctx and updates it via applyMotion / nextMatch.
pub const Cursor = struct { pos: view.Pos, viewport: view.Viewport };

/// One decoded grid row: UTF-8 text (trailing blank cells TRIMMED — vim getline() semantics) +
/// a per-BYTE → cell-column map (len == text.len). A motion landing on byte b sets cursor.x =
/// col[b]. Borrowed slices (valid until the next Grid.getRow call). Mirrors view.DecodedRow.
pub const Row = struct { text: []const u8, col: []const u16 };

/// The line-provider seam — MIRRORS capture.Runner / app.Input / input.EventReader (NON-nullable
/// ctx:*anyopaque + one fn pointer). motion.zig NEVER touches ghostty-vt's Screen directly: all
/// text comes through this seam ⇒ motion.zig's fns are PURE + testable via SliceGrid.
pub const Grid = struct {
    ctx: *anyopaque,
    getRowFn: *const fn (ctx: *anyopaque, y: u32) Row,
    total_rows: u32,
    cols: u16, // grid cell width; hard ceiling for cursor.x
    pub fn getRow(self: Grid, y: u32) Row { return self.getRowFn(self.ctx, y); }
};

pub const Direction = enum { forward, backward };

/// Search navigation state. `matches` is the EXTERNALLY-produced list from view.findMatches
/// (region.zig calls it after the pattern is typed). `current` = last-visited match index (null
/// before the first n/N). `direction` = the direction of the last `/` or `?`.
pub const SearchState = struct {
    matches: []const view.Match = &.{},
    current: ?usize = null,
    direction: Direction = .forward,
};

/// TEST Grid — yields Rows from a slice; y >= len ⇒ empty Row (text.len==0). Stable static slices.
pub const SliceGrid = struct {
    rows: []const Row,
    total_rows: u32,
    cols: u16,
    fn getRowFn(ctx: *anyopaque, y: u32) Row {
        const self: *SliceGrid = @ptrCast(@alignCast(ctx));
        if (y >= self.total_rows) return .{ .text = "", .col = &.{} };
        return self.rows[y];
    }
    pub fn grid(self: *SliceGrid) Grid {
        return .{ .ctx = @ptrCast(self), .getRowFn = getRowFn, .total_rows = self.total_rows, .cols = self.cols };
    }
};
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: CREATE src/tui/motion.zig — module header + imports + public types
  - IMPORT: `const std = @import("std"); const view = @import("view.zig"); const input = @import("input.zig");`
  - IMPLEMENT: Cursor, Row, Grid (+ getRow method), Direction, SearchState, SliceGrid (EXACTLY the
    data models above — verbatim from research/design_notes.md §1).
  - GOTCHA: SliceGrid must be a stack `var` in tests so `&sg` is *SliceGrid (NOT *const). getRowFn
    uses @ptrCast(@alignCast(ctx)).
  - NAMING: match view.zig's Pos/Viewport/Match EXACTLY (reuse — do NOT redefine).

Task 2: Row helpers (PURE, operate on ONE Row)
  - IMPLEMENT (all in research/design_notes.md §2):
      lineLastByte(row) ?usize      // last non-blank byte index; null if all-blank
      lastCellCol(row) u32          // cell col of last non-blank byte (0 if blank) — $ target
      firstNonBlankCol(row) u32     // cell col of first non-blank byte (0 if blank) — ^ target
      clampX(row, x, cols) u32      // min(x, lastCellCol(row)) capped at cols-1
      isBlankRow(row) bool          // true if no non-blank byte — a {/} paragraph boundary
  - PATTERN: iterate row.text + use row.col[byte] for cell columns. Blank = byte is ' ' or '\t'.
  - GOTCHA: row.text may be EMPTY (blank row / past-grid) — guard before indexing.

Task 3: Motion primitives (PURE, operate on Grid via borrowed Rows)
  - IMPLEMENT wordForward(grid, pos, count, cols) view.Pos   // w: two-class WORD (non-blank run)
  - IMPLEMENT wordBackward(grid, pos, count, cols) view.Pos  // b: previous word start; clamp BOF
  - IMPLEMENT wordEnd(grid, pos, count, cols) view.Pos       // e: end of current/next word; clamp EOF
  - IMPLEMENT matchBracket(grid, pos, cols) ?view.Pos        // %: see algorithm below (Task 3b)
  - IMPLEMENT paragraphBack(grid, y, count) u32              // {: nearest blank row strictly above
  - IMPLEMENT paragraphFwd(grid, y, count) u32               // }: nearest blank row strictly below
  - SEMANTICS: follow research/vim_motion_semantics.md §1,§7,§8 EXACTLY (TUI-SIMPLIFICATIONS adopted).
  - w/b/e algorithm (two-class WORD): a "word" = a maximal run of NON-WHITESPACE chars (== vim W/B/E).
    Skip current non-blank run + following whitespace; land on next non-blank char; cross rows
    (a blank row is whitespace); clamp at EOF to last cell of last row, at BOF to (0,0). count repeats.
  - GOTCHA: compute target BYTE index in row.text, then pos.x = row.col[byte] (wide-char-correct).
  - GOTCHA: u32 saturating subtract in wordBackward/paragraphBack (y >= step ? y-step : 0).

Task 3b: matchBracket algorithm (% — research/design_notes.md §3)
  - STEP 1: row = grid.getRow(pos.y). Find byte index bi where col[bi]==pos.x AND text[bi] is a
    bracket ()[]{}. If none AT pos.x, scan row.text forward from the first byte with col[bi]>=pos.x
    for the first bracket char; if none on the row ⇒ return null (no move).
  - STEP 2: open = text[bi]. direction = forward if open in ([{, else backward. The matching char
    is the closer/opener of the SAME pair: () → () , [] → [] , {} → {}.
  - STEP 3: walk the grid row-by-row, byte-by-byte in direction, starting just past bi. Maintain a
    depth counter (start 1): each SAME-PAIR opener (forward) / closer (backward) increments; each
    matching closer (forward) / opener (backward) decrements. Land where depth returns to 0 ⇒
    return { x: col[landing_byte], y: that_row }. Unbalanced / grid-end reached ⇒ return null.
  - COUNT: IGNORED (always bracket-match; percent-of-file jumps are out of scope).

Task 4: applyMotion dispatcher (PURE — switches on all 21 input.Motion variants)
  - IMPLEMENT applyMotion(c: Cursor, m: input.Motion, count: u32, grid: Grid) Cursor
  - FOLLOW the per-variant table in research/design_notes.md §3 (reproduced in Implementation
    Patterns below). Update pos via the primitives (Task 3) / simple clamp / viewport-relative /
    scroll-math; then recompute viewport.scroll via view.scrollForCursor (the workhorse) for
    vertical motions, EXCEPT H/M/L which leave scroll unchanged (within-viewport jumps) and the
    page/half-page/G/gg variants which call the matching view scroll fn.
  - half = viewport.rows / 2 (floor). "clamp into viewport" = y clamped to [new_scroll,
    min(total-1, new_scroll+rows-1)] after a page/half-page scroll.
  - GOTCHA: .match_bracket ⇒ pos = matchBracket(...) orelse c.pos (no bracket ⇒ cursor UNCHANGED;
    also leave scroll unchanged when null).
  - GOTCHA: the switch MUST be exhaustive (Zig compile-errors if a variant is missed).

Task 5: Search navigation (PURE — operates on []const Match + cursor)
  - IMPLEMENT nextMatch(s: SearchState, cursor: view.Pos, dir: Direction) ?view.Pos
      // First match whose start (y,x1) is strictly AFTER (dir=.forward) / BEFORE (dir=.backward)
      // the cursor, with WRAPAROUND. Forward: scan matches in order; first with (m.y,m.x1) >
      // (cursor.y,cursor.x) after-cursor ordering; if none, wrap to matches[0]. Backward: mirror;
      // if none, wrap to last. Empty matches ⇒ null. Return { x: m.x1, y: m.y }.
  - IMPLEMENT prevMatch(s, cursor) by calling nextMatch(s, cursor, opposite direction) — ONE fn,
    no duplication. (region.zig P3.M3 sets SearchState.direction from the last / or ?.)
  - GOTCHA: "strictly after" ordering compares (y, then x1) lexicographically. A match whose start
    is AT the cursor is NOT "after" — n on a match-start lands on the NEXT match.

Task 6: Tests (SEPARATE test fns — motion.zig never constructs a Terminal ⇒ SAFE)
  - FOLLOW the test strategy in research/design_notes.md §6. Cover:
      * Row helpers: ASCII, blank, wide-col-map rows.
      * wordForward/Backward/End: single row, multi-row (cross-row), EOF/BOF clamp, count, blank
        rows, the foo.bar-is-one-word (two-class) assertion.
      * matchBracket: cursor on each pair ( [ {, forward nesting ((a)(b)), backward matching,
        cursor-not-on-bracket ⇒ line-forward-search, unbalanced ⇒ null, cross-row match.
      * paragraphBack/Fwd: blank-row jumps, count, BOF/EOF clamp, no-blank ⇒ end.
      * applyMotion: EVERY variant returns expected {pos, viewport.scroll}; count cases (5j, 2$,
        5G→row4, 5gg→row4, plain G→last, plain gg→row0); viewport scroll side-effects.
      * nextMatch: forward (strictly-after + wraparound), backward, empty ⇒ null, cursor on a
        match start ⇒ next is the FOLLOWING match.
      * SliceGrid: rows[y] passthrough; y >= len ⇒ empty Row.
  - PATTERN: mirror src/tui/input.zig test style — `const testing = std.testing;` + `test "name"` +
    `try testing.expectEqual(...)`. Build asciiRow helpers with comptime identity col arrays.
  - NAMING: test "{fn}: {scenario}" — descriptive, one concept per test fn.

Task 7: EDIT src/main.zig — wire motion.zig into the test root
  - FIND: the test{} block at src/main.zig:476 (the `_ = @import("tui/input.zig");` line at ~497).
  - ADD: ONE line after the input.zig import:
        // P3.M2.T1.S2: keep tui/motion.zig tests reachable (region.zig, its caller, does NOT
        // exist yet). motion.zig is PURE (no Terminal) ⇒ separate test fns (no cross-test GOTCHA).
        _ = @import("tui/motion.zig");
  - PRESERVE: every other @import line; NO other main.zig change; NO build.zig / build.zig.zon change.
```

### Implementation Patterns & Key Details

```zig
// === applyMotion per-variant rules (research/design_notes.md §3 — the source of truth) ===
// All vertical motions then recompute scroll via view.scrollForCursor (the minimal keep-visible
// workhorse) UNLESS noted. half = viewport.rows / 2 (floor). "clamp into viewport" clamps y to
// [new_scroll, min(total-1, new_scroll+rows-1)].
//
// .left      (h): x = clamp(max(0, x-count), row);                       scroll unchanged
// .right     (l): x = clamp(x+count, row);                               scroll unchanged
// .up        (k): y = max(0, y-count);  x = clampX(newRow);              view.scrollForCursor(y)
// .down      (j): y = min(total-1, y+count); x = clampX(newRow);         view.scrollForCursor(y)
// .word_fwd  (w): pos = wordForward(grid, pos, count, cols);             view.scrollForCursor(pos.y)
// .word_back (b): pos = wordBackward(...);                               view.scrollForCursor(pos.y)
// .word_end  (e): pos = wordEnd(...);                                    view.scrollForCursor(pos.y)
// .line_start(0): x = 0;                                                 scroll unchanged
// .first_nonblank(^): x = firstNonBlankCol(row);                         scroll unchanged
// .line_end  ($): y = min(total-1, y+(count-1)); x = lastCellCol(newRow);view.scrollForCursor(y)
// .doc_top   (gg):y = (count>=2 ? count-1 : 0); x = clampX(row);         view.topOnCursor(y,total,rows)
// .doc_bottom(G): y = (count>=2 ? count-1 : total-1); x = clampX(newRow);view.scrollToBottom/scrollForCursor
// .half_page_down(Ctrl-d): repeat count: y=min(total-1,y+half); clamp into viewport; view.halfPageDown/step
// .half_page_up  (Ctrl-u): repeat count: y=max(0,y-half);   clamp into viewport; view.halfPageUp/step
// .page_down (Ctrl-f): repeat count: y=min(total-1,y+rows); clamp into viewport; view.pageDown/step
// .page_up   (Ctrl-b): repeat count: y=max(0,y-rows);       clamp into viewport; view.pageUp/step
// .viewport_top   (H): y = min(total-1, scroll+(count-1));  x = clampX;   scroll unchanged
// .viewport_mid   (M): y = min(total-1, scroll+rows/2) (count IGNORED); x = clampX; scroll unchanged
// .viewport_bottom(L): y = min(total-1, scroll+rows-1)-(count-1); x = clampX; scroll unchanged
// .paragraph_back({): y = paragraphBack(grid,y,count); x = clampX;        view.scrollForCursor(y)
// .paragraph_fwd (}): y = paragraphFwd(grid,y,count);  x = clampX;        view.scrollForCursor(y)
// .match_bracket (%): pos = matchBracket(grid,pos,cols) orelse c.pos;     view.scrollForCursor(pos.y)
//                     (no bracket found ⇒ cursor UNCHANGED + scroll unchanged)

// === applyMotion skeleton (illustrative — fill every variant) ===
pub fn applyMotion(c: Cursor, m: input.Motion, count: u32, grid: Grid) Cursor {
    var out = c;
    const total = grid.total_rows;
    const row = grid.getRow(c.pos.y); // borrow valid ONLY until next getRow
    switch (m) {
        .left  => { out.pos.x = if (c.pos.x >= count) c.pos.x - count else 0;
                    out.pos.x = @min(out.pos.x, view.lastCellColSafe(row, c.viewport.cols)); },
        // ... (all 21 variants per the table above) ...
        .match_bracket => {
            if (matchBracket(grid, c.pos, c.viewport.cols)) |np| {
                out.pos = np;
                out.viewport.scroll = view.scrollForCursor(np.y, out.viewport, total);
            }
            // else: no bracket ⇒ out unchanged (out == c)
        },
    }
    return out;
}

// === nextMatch skeleton (strictly-after + wraparound) ===
pub fn nextMatch(s: SearchState, cursor: view.Pos, dir: Direction) ?view.Pos {
    if (s.matches.len == 0) return null;
    const fwd = (dir == .forward);
    var first: ?usize = null; // wrap candidate (matches[0] fwd / last backward)
    for (s.matches, 0..) |m, i| {
        const after = (m.y > cursor.y) or (m.y == cursor.y and m.x1 > cursor.x);
        const before = (m.y < cursor.y) or (m.y == cursor.y and m.x1 < cursor.x);
        const hit = if (fwd) after else before;
        if (hit) return .{ .x = m.x1, .y = m.y };
        if (first == null) first = i; // remember index 0 (fwd) / 0 (then pick last for back)
    }
    // wraparound: forward ⇒ matches[0]; backward ⇒ matches[len-1]
    const idx: usize = if (fwd) 0 else s.matches.len - 1;
    const m = s.matches[idx];
    return .{ .x = m.x1, .y = m.y };
}
pub fn prevMatch(s: SearchState, cursor: view.Pos) ?view.Pos {
    return nextMatch(s, cursor, if (s.direction == .forward) .backward else .forward);
}
```

### Integration Points

```yaml
BUILD:
  - NO change. motion.zig is reached via the existing `src/tui/` import graph + the ONE new
    `_ = @import("tui/motion.zig");` line in main.zig's test block. No build.zig / build.zig.zon
    edit; no new dependency (imports ONLY std + view.zig + input.zig).

TEST_ROOT:
  - add to: src/main.zig (the top-level `test {}` block at line 476)
  - pattern: "_ = @import(\"tui/motion.zig\");" placed AFTER the existing
             "_ = @import(\"tui/input.zig\");" line (~line 497)
  - preserve: every other @import line; the file's non-test dispatch logic

DOWNSTREAM_CONSUMERS (NOT this subtask — for awareness):
  - P3.M2.T2 select.zig: reads Cursor.pos (the anchor/cursor for the selection model)
  - P3.M3 region.zig: OWNS a Cursor + SearchState in its EventHandler ctx; per input.Key:
      .motion  ⇒ cursor = motion.applyMotion(cursor, key.kind.motion, key.count, screenGrid)
      .search  ⇒ start_*: collect pattern bytes (decoder idle), on Enter matches =
                     view.findMatches(alloc, screen, pattern, .fixed, total); reset SearchState;
                     (next/prev): pos = motion.nextMatch(state, cursor.pos, dir) orelse cursor.pos;
                     cursor.pos = pos; cursor.viewport.scroll = view.scrollForCursor(pos.y, …)
  - PROD Grid (ScreenGrid) is region.zig's job (P3.M3): builds Row{ text, col } from the captured
    *const Screen via view.decodeRow (view.zig's private decodeRow/DecodedRow — making them pub is
    an ADDITIVE edit for P3.M3, NOT this subtask; motion.zig needs NO view.zig edit).
```

## Validation Loop

> **CRITICAL**: ALL Zig build/test commands MUST use `-Doptimize=ReleaseFast`. Debug hits the
> `R_X86_64_PC64` linker bug with the bundled ghostty C++ SIMD libs (PRD §15). This is the #1
> build gotcha — confirmed across every sibling PRP.

### Level 1: Syntax & Type Check (Immediate Feedback)

```bash
# After creating src/tui/motion.zig + the main.zig import line — compile the test target.
zig build test -Doptimize=ReleaseFast
# Expected: compiles cleanly. A non-exhaustive `switch (m)` on input.Motion ⇒ compile error
# naming the missing variant (a BUILT-IN checklist). @ptrCast/@alignCast + borrow-lifetime
# errors surface here too. Fix BEFORE running tests further.
```

### Level 2: Unit Tests (Component Validation)

```bash
# Run the full test suite (ReleaseFast MANDATORY). motion.zig tests run as SEPARATE fns
# (no Terminal ⇒ no cross-test GOTCHA), so a failure points at exactly one test.
zig build test -Doptimize=ReleaseFast
# Expected: ALL tests pass (existing + new motion.zig tests). If a motion.zig test fails, READ
# the assertion + the expected cell from the test name + vim_motion_semantics.md, then fix.

# To focus debugging, temporarily add `--test-filter "applyMotion"` (or "wordForward", etc.)
# via: zig build test -Doptimize=ReleaseFast --test-filter "wordForward"
# (Zig's test runner supports --test-filter <substring> to run only matching tests.)
```

### Level 3: Integration Testing (System Validation)

```bash
# motion.zig has NO I/O (PURE) — there is no service to start or endpoint to hit. Its "integration"
# is reaching it from the test root. The one-line main.zig edit IS the integration. Confirm:
zig build test -Doptimize=ReleaseFast  # passes ⇒ motion.zig tests are reachable + green

# Build the binary itself still compiles (motion.zig is imported by main's test block only; the
# exe path is unaffected, but confirm there's no stray import that breaks the build):
zig build -Doptimize=ReleaseFast
# Expected: builds zig-out/bin/tmux-2html with no errors.
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Exhaustiveness check: confirm the applyMotion switch covers all 21 input.Motion variants.
# The Zig compiler ENFORCES this — if a variant is missing, `zig build test` fails to compile
# with "switch must handle all possible values". So a green build == exhaustive dispatch.

# Semantic spot-check (manual reasoning against vim_motion_semantics.md, encoded as tests):
#   * "foo.bar" + w from col 0 ⇒ lands on EOF/last cell (ONE word, two-class model) — NOT col 4.
#   * "((a)(b))" with cursor on the FIRST '(' + % ⇒ lands on the LAST ')'.
#   * "5G" on a 20-row grid ⇒ cursor.y == 4 (count>=2 ⇒ row count-1); plain G ⇒ cursor.y == 19.
#   * nextMatch forward with cursor past the last match ⇒ wraps to matches[0].
# All of the above MUST be present as named test fns (Task 6) and pass.
```

## Final Validation Checklist

### Technical Validation

- [ ] `zig build test -Doptimize=ReleaseFast` passes (zero test failures).
- [ ] `zig build -Doptimize=ReleaseFast` builds the binary with no errors.
- [ ] No new compiler warnings from motion.zig.
- [ ] No memory leaks (test allocator clean in any allocator-using test).

### Feature Validation

- [ ] All 21 `input.Motion` variants move the cursor to the exact documented cell (Task 4 table).
- [ ] Counts apply: `5j`, `2$`, `5G`→row4, `5gg`→row4, plain `G`→last, `5w`, `3{`.
- [ ] `viewport.scroll` updates correctly: page/half-page/G/gg call the matching `view` scroll fn;
      H/M/L leave scroll unchanged; vertical cursor moves keep the cursor visible via
      `view.scrollForCursor`.
- [ ] `%` matches `()[]{}` across rows with nesting depth; not-on-bracket ⇒ line-forward-search;
      unbalanced ⇒ cursor unchanged.
- [ ] `{`/`}` jump to nearest all-blank row strictly above/below; count repeats; clamp at BOF/EOF.
- [ ] `nextMatch` strictly-after + wraparound works both directions; empty matches ⇒ null.

### Code Quality Validation

- [ ] motion.zig imports ONLY `std` + `view.zig` + `input.zig` (NO `ghostty-vt`).
- [ ] Reuses `view`'s Pos/Viewport/Match + scroll fns (NO duplicate types or scroll math).
- [ ] Consumes `input.Key`/`Motion` as-is (NO re-decoding).
- [ ] `switch (m)` on `input.Motion` is exhaustive (compiler-enforced).
- [ ] Follows the `Grid` seam pattern (`ctx:*anyopaque` + fn pointer + `@ptrCast(@alignCast)`).
- [ ] u32 saturating subtract everywhere upward motions subtract (no underflow).
- [ ] Only ONE new line added to main.zig; NO other source file modified.

### Documentation & Deployment

- [ ] Module-level `//!` doc comment explains the layering (consumes input.Key + view; produces
      Cursor + PURE motion/search fns) — mirror the doc style of input.zig/view.zig.
- [ ] The G-vs-1G ambiguity + the two-class WORD model + {/} nearest-blank + %-always-bracket are
      documented as deliberate TUI simplifications (matching vim_motion_semantics.md).

---

## Anti-Patterns to Avoid

- ❌ Don't re-implement key DECODING — `input.zig` (S1) is the CONTRACT; consume `input.Key`/`Motion`.
- ❌ Don't re-derive scroll formulas — REUSE `view`'s `scrollForCursor`/`pageDown`/`halfPageDown`/
  `scrollToBottom`/`topOnCursor`/etc. (they're unit-tested; duplication risks divergence).
- ❌ Don't re-scan the grid for search matches — `view.findMatches` is SHIPPED; motion.zig only
  NAVIGATES the `[]Match` it returns.
- ❌ Don't import `ghostty-vt` in motion.zig — text comes through the `Grid` seam (keeps it PURE
  and avoids the cross-test Terminal-init GOTCHA).
- ❌ Don't store a borrowed `Row` across `Grid.getRow` calls (slices valid only until next call).
- ❌ Don't use plain `y - count` for upward motions — u32 underflows (use saturating subtract).
- ❌ Don't `switch` on raw bytes — switch on the 21 `input.Motion` variants (already decoded).
- ❌ Don't skip ReleaseFast — `zig build test` WITHOUT `-Doptimize=ReleaseFast` fails to LINK.
- ❌ Don't edit view.zig/input.zig/app.zig/build.zig to "enable" this — it needs NONE of those.
- ❌ Don't implement full-vim three-class `w/b/e` — the two-class WORD model is the adopted
  simplification (== vim W/B/E); `foo.bar` is ONE word.

---

## Confidence Score

**9/10** — This is an exceptionally well-scoped subtask: both upstream contracts (`input.Key` from
S1, `view` types + scroll math + `findMatches` from P3.M1.T2) are SHIPPED and the complete API +
per-variant semantics + matchBracket algorithm + testing strategy are already authored in the
research/ directory (`design_notes.md` + `vim_motion_semantics.md`). The deliverable is ONE new
PURE file (no Terminal ⇒ no cross-test GOTCHA) + ONE import line. The only residual risk is the
hand-implemented word/bracket/paragraph scan edge cases — but these are fully enumerated with
deterministic test cases. `-Doptimize=ReleaseFast` is the single build criticality.
