# Design Notes — `src/tui/motion.zig` (P3.M2.T1.S2)

The cursor/motion/search engine. Consumes `input.Key` (P3.M2.T1.S1, being implemented NOW —
treated as a CONTRACT) + `view`'s scroll math + types (SHIPPED, P3.M1.T2) + a `Grid` line-provider
seam (decoded per-row cell text). Produces a `Cursor` model + PURE motion/search functions.

## 0. Where this module sits in the pipeline

```
app.readEvent → app.Event → input.feed/decode → input.Key ──┐
                                                              ├─→ motion.applyMotion(cursor, key, grid) → Cursor
view.scrollForCursor/pageDown/... (SHIPPED) ←─────────────────┤    (motion.zig reuses view's PURE scroll math;
view.findMatches → []view.Match ──────────────────────────────┤     NO duplication; NO Terminal in motion.zig)
                                                              └─→ motion.SearchState{matches,current,dir}
                                                                    + motion.nextMatch/prevMatch → ?Pos
region.zig (P3.M3) owns the Cursor + SearchState in its EventHandler ctx; per input.Key:
  .motion ⇒ cursor = applyMotion(cursor, m, count, grid); repaint
  .search ⇒ (start_*) enter pattern-typing sub-mode; on Enter matches=findMatches(...); reset SearchState
            (next/prev) pos = nextMatch/prevMatch(state, cursor, dir); cursor.pos=pos; scrollForCursor; repaint
  .action ⇒ select.zig (P3.M2.T2) / confirm-cancel (P3.M3)
```

**What already exists (do NOT re-implement):**
- `view.Pos{ x:u32, y:u32 }`, `view.Viewport{ cols:u16, rows:u16, scroll:u32 }`, `view.Match{ y,x1,x2 }`
  (SHIPPED, src/tui/view.zig:40-76). REUSE — single source of truth (no duplicate types).
- `view` scroll math (all PURE, unit-tested, src/tui/view.zig:459-534): `clampScroll`,
  `scrollForCursor`, `centerOnCursor`, `topOnCursor`, `bottomOnCursor`, `pageDown`, `pageUp`,
  `halfPageDown`, `halfPageUp`, `scrollToBottom`. REUSE — motion.zig composes these (no new math).
- `view.findMatches(alloc, *const Screen, needle, .fixed, total) []Match` (SHIPPED) = the search
  SCAN. motion.zig does NOT re-scan; it CONSUMES the `[]const Match` and adds next/prev navigation.
- `input.Key{ count:u32=1, kind: input.KeyKind }`, `input.Motion` (21 variants), `input.Action`,
  `input.Search` (P3.M2.T1.S1 CONTRACT — see its PRP + research/design_notes.md). CONSUME as-is.

## 1. The public API (the contract surface)

```zig
const std = @import("std");
const view = @import("view.zig"); // Pos, Viewport, Match, scroll fns (SHIPPED — reuse)
const input = @import("input.zig"); // Key, Motion, Action, Search (P3.M2.T1.S1 CONTRACT)

/// The navigable cursor state. `pos` is a grid cell (x=col, y=row, origin top-left); `viewport`
/// is the visible window. select.zig (P3.M2.T2) reads `.pos`; region.zig (P3.M3) owns a Cursor
/// in its EventHandler ctx and updates it via applyMotion/nextMatch.
pub const Cursor = struct {
    pos: view.Pos,
    viewport: view.Viewport,
};

/// One decoded grid row: UTF-8 text (trailing blank cells trimmed — vim getline() semantics) +
/// a per-BYTE → cell-column map (len == text.len). A motion landing on byte `b` sets cursor.x =
/// `col[b]` (wide-char-correct: a `.wide` cell's bytes share its index; spacers are skipped —
/// mirrors view's decodeRow). Borrowed slices (valid until the next Grid.getRow call).
pub const Row = struct { text: []const u8, col: []const u16 };

/// The line-provider seam — MIRRORS capture.Runner / app.Input / app.EventHandler (NON-nullable
/// ctx:*anyopaque + one fn pointer + thin method). motion.zig NEVER touches ghostty-vt's Screen
/// directly: all text comes through this seam ⇒ motion.zig's fns are PURE + fully testable via
/// SliceGrid (no Terminal ⇒ safe as separate test fns). region.zig (P3.M3) supplies the prod Grid
/// (built from view.decodeRow — forward contract; see §4).
pub const Grid = struct {
    ctx: *anyopaque,
    getRowFn: *const fn (ctx: *anyopaque, y: u32) Row,
    total_rows: u32,
    cols: u16, // grid cell width (grid.pages.cols); hard ceiling for cursor.x
    pub fn getRow(self: Grid, y: u32) Row {
        return self.getRowFn(self.ctx, y);
    }
};

pub const Direction = enum { forward, backward };

/// Search navigation state. `matches` is the EXTERNALLY-produced list from view.findMatches
/// (region.zig calls it after the pattern is typed). `current` = index of the last-visited match
/// (null before the first n/N). `direction` = the direction of the last `/` or `?`.
pub const SearchState = struct {
    matches: []const view.Match = &.{},
    current: ?usize = null,
    direction: Direction = .forward,
};
```

## 2. The PURE functions (all fully unit-tested via SliceGrid — NO Terminal)

### Row helpers (operate on ONE Row; trivially PURE)
- `lineLastByte(row) ?usize` — index of the last non-blank byte, or null for an all-blank row.
- `lastCellCol(row) u32` — cell col of the last non-blank byte (0 for blank). `$` target.
- `firstNonBlankCol(row) u32` — cell col of the first non-blank byte (0 for blank). `^` target.
- `clampX(row, x, cols) u32` — `min(x, lastCellCol(row))` capped at `cols-1`.
- `isBlankRow(row) bool` — true if no non-blank byte (a `{`/`}` paragraph boundary).

### The motion primitives (operate on Grid; PURE — read-only over borrowed Rows)
- `wordForward(grid, pos, count, cols) view.Pos` — `w`: next word start (non-blank-run model),
  `count` repeats, crosses rows, clamps at EOF to last cell of last row.
- `wordBackward(grid, pos, count, cols) view.Pos` — `b`: previous word start; clamps at BOF.
- `wordEnd(grid, pos, count, cols) view.Pos` — `e`: end of current/next word; clamps at EOF.
- `matchBracket(grid, pos, cols) ?view.Pos` — `%`: bracket match across rows (see §3).
- `paragraphBack(grid, y, count) u32` / `paragraphFwd(grid, y, count) u32` — `{`/`}`: nearest
  blank row strictly above/below; `count` repeats; clamp at BOF/EOF.

### The dispatcher (composes primitives + view scroll math)
- `applyMotion(c: Cursor, m: input.Motion, count: u32, grid: Grid) Cursor` — switch on all 21
  `input.Motion` variants; update `pos` (via the primitives for text motions, simple clamp for
  h/l/j/k/0, viewport-relative for H/M/L, scroll-math for page/half-page/G/gg) and recompute
  `viewport.scroll` via `view.scrollForCursor` (the workhorse — minimal keep-visible). Returns
  the new Cursor. PURE (no I/O). See §3 for the per-variant table.

### Search navigation (operates on []const Match + cursor; PURE)
- `nextMatch(s: SearchState, cursor: view.Pos, dir: Direction) ?view.Pos` — first match whose
  start `(y,x1)` is strictly AFTER (dir=.forward) / BEFORE (dir=.backward) the cursor, with
  WRAPAROUND (if none forward, wrap to match[0]; if none backward, wrap to last). Returns the
  match's start `{ x: m.x1, y: m.y }` or null if `s.matches` is empty.
- `prevMatch` = `nextMatch` with the opposite direction (one fn, dir param — no duplication).

> **Why region.zig owns pattern-typing, not motion.zig:** the decoder emits `search.start_*` only
> (S1 design §3.6); the PATTERN bytes typed after `/`/`?` are collected by region.zig from the raw
> event stream (the decoder is idle during typing). On Enter, region.zig calls `view.findMatches`
> → `[]Match`, resets `SearchState`, then `n`/`N` drive `nextMatch`/`prevMatch`. motion.zig owns
> the NAVIGATION only (current index + direction + wraparound + cursor jump). No scan duplication.

## 3. `applyMotion` per-variant table (ADOPTED semantics — see vim_motion_semantics.md)

| `input.Motion` | pos update | viewport.scroll update |
|---|---|---|
| `.left` (h) | `x = clamp(max(0, x-count), row)` | unchanged |
| `.right` (l) | `x = clamp(x+count, row)` | unchanged |
| `.up` (k) | `y = max(0, y-count)`; `x = clampX(newRow)` | `scrollForCursor(newY)` |
| `.down` (j) | `y = min(total-1, y+count)`; `x = clampX(newRow)` | `scrollForCursor(newY)` |
| `.word_fwd` (w) | `pos = wordForward(...)` | `scrollForCursor(pos.y)` |
| `.word_back` (b) | `pos = wordBackward(...)` | `scrollForCursor(pos.y)` |
| `.word_end` (e) | `pos = wordEnd(...)` | `scrollForCursor(pos.y)` |
| `.line_start` (0) | `x = 0` | unchanged |
| `.first_nonblank` (^) | `x = firstNonBlankCol(row)` | unchanged |
| `.line_end` ($) | `y = min(total-1, y+(count-1))`; `x = lastCellCol(newRow)` | `scrollForCursor(newY)` |
| `.doc_top` (gg) | `y = (count>=2 ? count-1 : 0)`; `x = clampX(row0)` | `topOnCursor(y)` (or scroll=0) |
| `.doc_bottom` (G) | `y = (count>=2 ? count-1 : total-1)`; `x = clampX(newRow)` | `scrollToBottom` / `scrollForCursor` |
| `.half_page_down` (Ctrl-d) | repeat `count`: `y=min(total-1,y+half)`; clamp into new viewport | `halfPageDown` per step |
| `.half_page_up` (Ctrl-u) | repeat `count`: `y=max(0,y-half)`; clamp into viewport | `halfPageUp` per step |
| `.page_down` (Ctrl-f) | repeat `count`: `y=min(total-1,y+rows)`; clamp into viewport | `pageDown` per step |
| `.page_up` (Ctrl-b) | repeat `count`: `y=max(0,y-rows)`; clamp into viewport | `pageUp` per step |
| `.viewport_top` (H) | `y = scroll+(count-1)` (clamp total-1); `x = clampX(newRow)` | unchanged |
| `.viewport_mid` (M) | `y = min(total-1, scroll+rows/2)` (count ignored); `x = clampX(newRow)` | unchanged |
| `.viewport_bottom` (L) | `y = min(total-1, scroll+rows-1)-(count-1)`; `x = clampX(newRow)` | unchanged |
| `.paragraph_back` ({) | `y = paragraphBack(...)`; `x = clampX(newRow)` | `scrollForCursor(newY)` |
| `.paragraph_fwd` (}) | `y = paragraphFwd(...)`; `x = clampX(newRow)` | `scrollForCursor(newY)` |
| `.match_bracket` (%) | `pos = matchBracket(...) orelse c.pos` (no bracket ⇒ no move); count ignored | `scrollForCursor(pos.y)` |

`half = viewport.rows / 2` (floor). "clamp into viewport" = `y = clamp(y, new_scroll, min(total-1,
new_scroll+rows-1))` so the cursor stays inside the freshly-scrolled window (≈ same screen row for
half/full-page). All scroll results flow through `view.clampScroll` implicitly (the view fns clamp).

### `%` bracket-matching algorithm (matchBracket)
1. `row = grid.getRow(pos.y)`. Find the byte index `bi` of a bracket AT `pos.x` (i.e. `col[bi]==pos.x`
   and `row.text[bi]` ∈ `()[]{}`). If none there, scan `row.text` forward from the first byte with
   `col[bi] >= pos.x` for the first bracket char; if none on the row ⇒ return null (no move).
2. Let `open = row.text[bi]`. Direction = forward if `open` ∈ `([{`, backward if `) ] }`. The
   matching closer/opener is the corresponding char of the SAME pair.
3. Walk the grid (row by row, byte by byte) in `direction`, starting just past `bi`. Maintain a
   depth counter (start 1): each SAME-PAIR opener (forward) or closer (backward) increments; each
   matching closer/opener decrements. Land on the byte where depth returns to 0 ⇒ return
   `{ x: col[landing_byte], y: that_row }`. Clamp at grid ends (unbalanced ⇒ return null).

## 4. The prod Grid (forward contract — region.zig, P3.M3)

motion.zig ships `SliceGrid` (test) + the `Grid` seam. The PROD Grid is region.zig's job (P3.M3):
- region.zig builds each `Row{text, col}` from the captured `*const Screen`. The clean path:
  EXPOSE `view.decodeRow` + `view.DecodedRow` (additive `pub` edit to view.zig — view already has
  the private `DecodedRow{text:[]u8, col:[]u16}` + `decodeRow`; making them pub is zero-behavior-
  change). region.zig's ScreenGrid holds the Screen + a reusable decode buffer; `getRow` decodes
  row y into the buffer and returns a borrowed `Row` (valid until the next getRow — exactly what
  the seam's "borrowed until next call" contract promises). motion.zig itself NEVER imports
  ghostty-vt and needs NO view.zig edit (it consumes only view's already-pub scroll fns + types).

## 5. Scope boundaries (what THIS subtask does NOT do)

- ❌ Key DECODING — P3.M2.T1.S1 (input.zig; CONSUME its Key/Motion/Action/Search).
- ❌ The event loop / pattern-typing collection / repaint — P3.M3 (region.zig). motion.zig is the
  PURE engine; region.zig owns the Cursor + SearchState + wires input.Key → applyMotion/nextMatch.
- ❌ The search SCAN (the []Match list) — view.findMatches (SHIPPED). motion.zig navigates only.
- ❌ Selection model (anchor/mode/v-toggle/o/O) — P3.M2.T2 (select.zig; reads cursor.pos).
- ❌ Coordinate → ghostty Selection conversion — P3.M2.T2.S2.
- ❌ The prod Grid (ScreenGrid) — P3.M3 (region.zig); needs view.decodeRow exposed.

THIS subtask = the motion/search ENGINE: `Cursor` + `Row`/`Grid`/`SliceGrid` + the PURE motion
primitives + `applyMotion` + `SearchState`/`nextMatch` + tests. Reachable from main.zig's test
block via ONE new line `_ = @import("tui/motion.zig");`.

## 6. Testing strategy (motion.zig constructs NO Terminal ⇒ separate test fns are SAFE)

motion.zig imports `view` (which imports ghostty-vt) — but motion.zig's OWN tests NEVER call
`Terminal.init`. The ghostty-vt cross-test GOTCHA (src/render.zig, src/tui/view.zig) is ONLY
triggered by `Terminal.init` in SEPARATE test fns (process-global state corruption). motion.zig
never constructs a Terminal ⇒ its PURE tests are SAFE as separate `test` fns (mirrors app.zig +
input.zig). Cover:

- Row helpers: `lineLastByte`/`lastCellCol`/`firstNonBlankCol`/`clampX`/`isBlankRow` on ASCII +
  blank + wide-col-map rows.
- `wordForward`/`wordBackward`/`wordEnd`: single row, multi-row (cross-row), EOF/BOF clamp,
  count, blank rows, the `foo.bar`-is-one-word (two-class) assertion.
- `matchBracket`: cursor on each pair `( [ {`, forward nesting `((a)(b))`, backward matching,
  cursor-not-on-bracket ⇒ line-forward-search, unbalanced ⇒ null, cross-row match.
- `paragraphBack`/`paragraphFwd`: blank-row jumps, count, BOF/EOF clamp, no-blank ⇒ end.
- `applyMotion`: EVERY variant (h/l/j/k/0/^/$/w/b/e/gg/G/Ctrl-d/u/f/b/H/M/L/{/}/%) returns the
  expected {pos, viewport.scroll}; count cases (`5j`, `2$`, `5G`→row4, `5gg`→row4, plain `G`→last,
  plain `gg`→row0); the G-ambiguity doc case (`1G`→last, documented); viewport scroll side-effects
  (cursor pushed off-screen ⇒ scroll follows via scrollForCursor).
- `nextMatch`: forward (strictly-after + wraparound), backward, empty matches ⇒ null, cursor on a
  match start ⇒ next is the FOLLOWING match, count ignored here (region applies count by repeating).
- SliceGrid: rows[y] passthrough; y ≥ len ⇒ empty Row.

## 7. Gotchas (codebase + Zig 0.15.2 + ghostty-vt + the S1 contract)

- **ReleaseFast MANDATORY** for `zig build test` (Debug hits the `R_X86_64_PC64` linker bug with
  the bundled C++ SIMD libs — PRD §15). Every validation cmd uses `-Doptimize=ReleaseFast`.
- **input.Key.count defaults to 1, NO has_count** (S1 CONTRACT). This makes plain `G`
  indistinguishable from `1G` ⇒ applyMotion resolves `G` with count≤1 ⇒ LAST row (documented v1
  limitation). Do NOT "fix" this in motion.zig by guessing; it is a deliberate decoder property.
- **motion.zig reuses view's scroll math** (`scrollForCursor`, `pageDown`, etc.) — do NOT rederive
  scroll formulas (they are unit-tested in view.zig; duplicating risks divergence). Call them with
  the SAME arg shapes view.zig's tests use (see src/tui/view.zig:459-534).
- **Row.col maps BYTE index → CELL column** (wide-char-correct). Motions compute a target BYTE
  index then set `pos.x = row.col[byte]`. For ASCII (col[i]==i) this is trivial; for wide chars it
  matters. Tests use `asciiRow` (identity col) for the bulk + hand-crafted col maps for wide cases.
- **Borrowed Row lifetime:** Grid.getRow returns a Row whose slices are valid ONLY until the next
  getRow call (the seam contract). Motions read text+col, compute a new pos, and do NOT retain the
  Row. SliceGrid returns stable static slices (fine); ScreenGrid (P3.M3) reuses one buffer.
- **`@ptrCast(@alignCast(ctx))` MANDATORY** to recover the typed Grid impl pointer in getRowFn
  (0.15.2; mirrors capture.zig:356, app.FdInput, input.SliceEventReader). SliceGrid must be a stack
  `var` so `&sg` is `*SliceGrid` (a const yields `*const T` which does NOT coerce).
- **Tagged-union switch on `input.Motion`** — exhaustive (21 variants; Zig errors if one is
  missed). Use `switch (m) { .left => ..., .right => ..., ... }`.
- **u32 saturating subtract** for upward motions (k/Ctrl-u/Ctrl-b/{/wordBackward): `y >= count ?
  y-count : 0` — plain `y - count` underflows in Debug (trap) / is UB-adjacent in ReleaseFast.
- **main.zig test block** needs ONE new line `_ = @import("tui/motion.zig");` (after the
  input.zig import at main.zig ~500). NO other main.zig change; NO build.zig/build.zig.zon change;
  NO new deps; NO view.zig/input.zig/app.zig edit.
- **No allocation in motion.zig.** All fns are stack-only (Rows are borrowed). Tests use no
  allocator (asciiRow builds comptime col arrays; SliceGrid holds static slices). Leak-free.
