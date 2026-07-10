# P3.M2.T2.S2 — Coordinate → Selection (pin) conversion: design notes (the build spec)

> Source of truth for implementing the TUI→ghostty selection bridge. Authored from PRIMARY-SOURCE
> reads of `src/render.zig` (the SHIPPED `buildSelection` recipe), `src/ghostty_format.zig` (the
> vendored formatter's wide-cell handling), ghostty `Selection.zig` / `PageList.zig` / `point.zig`
> (v1.3.1, in `zig-pkg/`), the S1 PRP + `research/design_notes.md` (the `select.Sel` contract),
> and `src/tui/view.zig` (the `view.Selection`/`gridLastRow` pattern). Read end-to-end before coding.

## 0. Scope & layering (what S2 owns vs its neighbours)

```
select.Sel.extent(cols) ──► view.Selection ──► view.render/highlight   (S1's overlay output; DONE)
        │
        ▼
 S2 (THIS):  sel ──extent──► view.Selection ──clamp──► cli.SelectionCoords ──buildSelection──► ghostty Selection
        │                                                                                  │
        │                                                             REUSE P1.M4.T1.S1 ──┘  (point.Point → pages.pin → Selection.init)
        ▼
 P3.M3.T1.S2 (confirm):  toGhosttySelection(sel, screen, cols) ──► renderGrid / ScreenFormatter ──► HTML
```

- **S2 (THIS) owns**: `toGhosttySelection(sel, screen, cols) Selection` — a PUBLIC function in
  `src/render.zig` that (1) reads `select.Sel.extent(cols)` (the linewise/block geometry, already
  min/max-normalized), (2) CLAMPS x→[0,cols-1] / y→[0,gridLastRow] (instead of erroring like the
  CLI path), (3) REUSES `render.buildSelection` (the P1.M4.T1.S1 recipe: point.Point →
  screen.pages.pin → Selection.init) to build the native ghostty Selection. Plus a PURE
  `clampExtent(ext, cols, last_row) cli.SelectionCoords` helper (unit-testable w/o a Terminal).
  Plus a tiny private `gridLastRow(screen) u32` + `wholeGridSelection(screen) Selection` helper.
- **S1 (PREDECESSOR, being implemented in parallel) owns**: `select.Sel` + `extent(cols)` + the
  PURE model. S2 CONSUMES `Sel.extent` as a CONTRACT — assume it ships EXACTLY as specified
  (`extent(cols) ?view.Selection`; linewise `{0,min,cols-1,max,false}`; block `{min,min,max,max,true}`).
- **P3.M3.T1.S2 (SUCCESSOR) owns**: the confirm loop — calls `toGhosttySelection` (or the
  coords path) and feeds the Selection to a renderer (renderGrid may gain a `?Selection`-taking
  path, or region.zig formats via ScreenFormatter on its loaded screen). NOT S2's concern.

> DO NOT: re-implement `extent`/`applyAction` (S1 owns them), hand-roll wide-cell rounding (the
> FORMATTER does it — §2), modify `buildSelection` (REUSE it), or touch select.zig/view.zig.

## 1. The public API (the contract surface)

```zig
// In src/render.zig (ADDS these; render.zig gains `const select = @import("tui/select.zig");`
// and `const view = @import("tui/view.zig");` — both one-way, no cycle, see §4).

/// Convert a TUI selection model into a native ghostty `Selection` against the LOADED screen,
/// clamping to the grid and DELEGATING wide-cell atomicity to the formatter (PRD §13).
///
/// REUSES the P1.M4.T1.S1 recipe via `buildSelection` (point.Point → screen.pages.pin →
/// Selection.init). `cols` is the TUI viewport width (passed to `sel.extent` for the linewise
/// full-row bound x2 = cols-1); x is then clamped to the ACTUAL grid width `screen.pages.cols`.
///
/// PRD §7.4 mapping (produced by `sel.extent`, consumed here):
///   linewise → Selection{ (0,r1)..(cols-1,r2), rectangle=false }
///   block    → Selection{ (c1,r1)..(c2,r2), rectangle=true }
///
/// Infallible (returns `Selection`, NOT an error union): clamping guarantees every coord is a
/// valid grid cell, so `buildSelection` (which can only fail on out-of-range) cannot error here.
/// An INACTIVE `sel` (`extent` ⇒ null) yields a WHOLE-GRID selection (top-left..bottom-right),
/// matching the formatter's own null-selection = whole-grid semantics — but the confirm call site
/// (P3.M3.T1.S2) only calls this when `sel.active()`.
///
/// OWNERSHIP: the returned Selection is UNTRACKED (`Selection.init` creates untracked bounds — no
/// heap, no tracking handles). `Selection.deinit` is a NO-OP for untracked bounds AND requires a
/// MUTABLE `*Screen` the caller lacks (`t.screens.active` is `*const`), so the caller does NOT
/// call deinit — identical to the existing `buildSelection` invariant (render.zig GOTCHA, verified
/// against ghostty v1.3.1 Selection.zig:55/69). The caller owns the value's lifetime; for the
/// untracked value that means "drop it when done" (no free needed).
pub fn toGhosttySelection(sel: select.Sel, screen: *const Screen, cols: u16) Selection {
    const ext = sel.extent(cols) orelse return wholeGridSelection(screen);
    const last_row = gridLastRow(screen); // u32; 0 if the screen has no rows (guarded)
    const coords = clampExtent(ext, screen.pages.cols, last_row);
    // Clamped ⇒ every coord is a valid grid cell ⇒ buildSelection cannot error. The `catch` is a
    // defensive fallback (no UB in ReleaseFast): on the structurally-unreachable error it renders
    // the whole grid rather than trap.
    return buildSelection(screen, coords) catch wholeGridSelection(screen);
}

/// PURE: clamp a (normalized) `view.Selection` extent to grid bounds → `cli.SelectionCoords`
/// safe to hand to `buildSelection`. x→[0,cols-1]; y→[0,last_row]. Re-normalizes order via
/// min/max (defensive — `select.extent` already min/max's). `cols==0` ⇒ x collapses to 0.
/// NO Terminal, NO ghostty import ⇒ unit-testable as a SEPARATE `test` fn (mirrors
/// render.zig's determineCols/lineCount). `view.Selection` and `cli.SelectionCoords` are
/// STRUCTURALLY IDENTICAL ({x1,y1,x2,y2:u32, rect:bool=false}); this is the 1:1 bridge.
pub fn clampExtent(ext: view.Selection, cols: u16, last_row: u32) cli.SelectionCoords {
    const last_col: u32 = if (cols == 0) 0 else @as(u32, cols) - 1;
    const nx1 = @min(ext.x1, ext.x2); // normalize order (defensive)
    const nx2 = @max(ext.x1, ext.x2);
    const ny1 = @min(ext.y1, ext.y2);
    const ny2 = @max(ext.y1, ext.y2);
    return .{
        .x1 = @min(nx1, last_col), // u32 >= 0 always; only clamp the high side
        .y1 = @min(ny1, last_row),
        .x2 = @min(nx2, last_col),
        .y2 = @min(ny2, last_row),
        .rect = ext.rect,
    };
}
// (gridLastRow + wholeGridSelection are PRIVATE helpers — see §1b.)
```

### 1b. Private helpers

```zig
/// The last row index of the loaded screen (0-based). Mirrors `view.zig`'s `total_rows`
/// computation: getBottomRight(.screen) + pointFromPin ⇒ coord.y. Returns 0 if the screen has
/// no addressable bottom-right (guarded — never happens for an initialized Terminal, which
/// always has ≥1 page). Used to clamp y so `pages.pin` never returns null.
fn gridLastRow(screen: *const Screen) u32 {
    const br = screen.pages.getBottomRight(.screen) orelse return 0;
    const br_pt = screen.pages.pointFromPin(.screen, br) orelse return 0;
    return br_pt.coord().y; // last row index (total_rows = y+1)
}

/// A whole-grid (untracked) Selection: top-left..bottom-right, rectangle=false. The fallback for
/// an INACTIVE sel and the (structurally unreachable) buildSelection error. getBottomRight(.screen)
/// does `self.pages.last.?` — safe for any initialized Terminal (Terminal.init creates ≥1 page).
fn wholeGridSelection(screen: *const Screen) Selection {
    const tl = screen.pages.getTopLeft(.screen);
    const br = screen.pages.getBottomRight(.screen) orelse tl;
    return Selection.init(tl, br, false); // untracked; no deinit (§1 ownership)
}
```

## 2. WIDE-CELL ROUNDING IS DELEGATED TO THE FORMATTER (the load-bearing finding)

**PRD §13: "Wide characters ... selection rounds to cell boundaries (wide cells selected atomic)."**
**VERIFIED from primary source (`src/ghostty_format.zig`, the vendored formatter): ghostty's
`PageFormatter` ALREADY implements wide-cell atomicity. tmux-2html (S2) must NOT re-implement it.**

Two mechanisms in the formatter (read `src/ghostty_format.zig` `PageFormatter.formatWithState`):

1. **START boundary rounds back from a wide cell's spacer_tail** (ghostty_format.zig ~lines
   808-823, inside the per-row `cells_subset` extraction):
   ```zig
   const row_start_x = if (start_x > 0 and (rectangle or y == start_y)) start_x: {
       break :start_x switch (cells[start_x].wide) {
           .spacer_tail => start_x - 1, // Include the prior cell to get the FULL wide char
           .spacer_head  => continue,   // spacer_head on the first row ⇒ skip the whole row
           .narrow, .wide => start_x,
       };
   } else 0;
   ```
   So if a selection STARTS on the trailing cell (`.spacer_tail`) of a 2-col wide glyph, the
   formatter DECREMENTS start_x to include the leading cell ⇒ the whole glyph is selected ATOMICALLY.
   The `PageFormatter` doc comment states this explicitly: *"If start X falls on the second column
   of a wide character, then the entire character will be included (as if you specified the
   previous column)."* (ghostty_format.zig ~line 685.)

2. **Spacers emit NOTHING** (ghostty_format.zig ~line 1019, the per-cell emit loop):
   ```zig
   switch (cell.wide) {
       .narrow, .wide => {},
       .spacer_head, .spacer_tail => continue, // SKIP — spacers contribute no bytes
   }
   ```
   So an END boundary landing on a wide cell's leading cell emits the glyph; landing on its spacer
   emits nothing. The glyph is never SPLIT — it is always emitted whole or not at all.

**CONSEQUENCE for S2:** `toGhosttySelection` does NOT inspect `cell.wide` and does NOT round
coordinates. It produces pins for the (clamped) coords via `buildSelection`; the formatter then
rounds start back from `spacer_tail` and skips spacers during emission. PRD §13's "round to cell
boundaries" is SATISFIED by delegation. **Anti-pattern: do NOT add wide-cell rounding in S2 — it
would double-round against the formatter and risk off-by-one splits.** (This is WHY S2 is a small,
1-point task: the hard part is already done in the formatter.)

Edge cases already covered by the formatter (no S2 action): block mode applies start_x/end_x per
row with the SAME spacer_tail rounding (rectangle branch, ghostty_format.zig ~line 636); an end_x
on a `spacer_head` under `unwrap` moves to the next row (~line 800). These are formatter concerns.

## 3. The recipe being reused (P1.M4.T1.S1 — `render.buildSelection`, SHIPPED & unchanged)

`src/render.zig:191` (verbatim):
```zig
pub fn buildSelection(screen: *const Screen, coords: cli.SelectionCoords) error{OutOfRange}!Selection {
    if (coords.x1 > std.math.maxInt(u16) or coords.x2 > std.math.maxInt(u16))
        return error.OutOfRange;
    const start_pt = point.Point{ .screen = .{ .x = @intCast(coords.x1), .y = coords.y1 } };
    const end_pt   = point.Point{ .screen = .{ .x = @intCast(coords.x2), .y = coords.y2 } };
    const sp = screen.pages.pin(start_pt) orelse return error.OutOfRange;
    const ep = screen.pages.pin(end_pt)   orelse return error.OutOfRange;
    return Selection.init(sp, ep, coords.rect); // untracked; NO deinit (findings §1)
}
```
- `point.Point` is `union(Tag){ .screen: Coordinate }`; `Coordinate{ x: size.CellCountInt=u16,
  y: u32 }` (point.zig:66-80). The `.screen` tag's top-left is scrollback-root; for a fresh
  terminal sized to the input's line count, screen row 0 == grid row 0.
- `PageList.pin(pt)` (PageList.zig:3875) returns null iff `x >= self.cols` OR `down(y)` fails
  (row past the page list). After S2's clamp, NEITHER can happen ⇒ `buildSelection` succeeds.
- `Selection.init(sp, ep, rect)` (Selection.zig:55) creates UNTRACKED bounds (`.untracked` arm),
  no heap. `Selection.deinit(self, s: *Screen)` (Selection.zig:69) is a NO-OP for untracked and
  needs a MUTABLE `*Screen` ⇒ caller does NOT deinit (matches the existing render.zig GOTCHA).
- Start/end may be in ANY order — the formatter normalizes via `Selection.order`/`topLeft`
  (Selection.zig:151/200). S2 still pre-normalizes (clampExtent min/max) so the value is correct
  for any consumer.

## 4. Layering & imports (verified cycle-free)

- `render.zig` currently imports: std, builtin, ghostty-vt, ghostty_format.zig, palette.zig, cli.zig.
- S2 ADDS to render.zig: `const select = @import("tui/select.zig");` + `const view = @import("tui/view.zig");`.
- Import graph (verified by grepping `@import`):
  - `select.zig` → std, view.zig, input.zig.  `input.zig` → std, app.zig.  `app.zig` → std ONLY.
  - `view.zig` → std, ghostty-vt, palette.zig.
  - ⇒ `render.zig → select.zig → {view.zig, input.zig → app.zig}` and `render.zig → view.zig`.
    NONE of these point back to render.zig ⇒ NO cycle. (cli.zig → render.zig is a SEPARATE,
    already-legal lazy cycle, documented at cli.zig:3.)
- Coupling note: render.zig is CORE; it gains a one-way dep on the TUI model (select.zig). This is
  an INTENTIONAL, documented trade-off for DRY reuse of `buildSelection` (co-located in render.zig)
  and faithfulness to the contract signature `toGhosttySelection(sel, screen, cols)`. Import is
  LAZY (render/pane paths never reference `select`) ⇒ zero runtime cost. select.zig is small, pure,
  stable. Acceptable.

## 5. Gotchas (Zig 0.15.2 + this codebase)

- **`zig build test` MUST use `-Doptimize=ReleaseFast`** (PRD §15; the R_X86_64_PC64 linker bug
  with the bundled ghostty C++ SIMD libs in Debug). EVERY validation command uses it.
- **The cross-test GOTCHA (Terminal.init corrupts process-global state across SEPARATE test fns).**
  `toGhosttySelection` + `gridLastRow` + `wholeGridSelection` touch the screen ⇒ their tests MUST
  live in render.zig's SINGLE Terminal test scope (the `"renderGrid: red foreground..."` test, where
  the S1 selection lw/block/out-of-range assertions already live). APPEND to that test; do NOT add
  a new Terminal-building test fn. `clampExtent` is PURE (no Terminal) ⇒ its tests ARE separate fns
  (mirrors render.zig's determineCols/lineCount).
- **`view.Selection` ≡ `cli.SelectionCoords` structurally** ({x1,y1,x2,y2:u32, rect:bool=false}).
  clampExtent is the 1:1 bridge; do NOT redefine either type. `view.Selection.x/y` are u32;
  `cli.SelectionCoords.x/y` are u32; `point.Coordinate.x` is u16, `.y` is u32 (point.zig). buildSelection
  already guards `coords.x > maxInt(u16)` before the `@intCast` — clampExtent's `last_col` is a u32
  derived from a u16 cols, so x ≤ 65535 always; the guard never trips post-clamp.
- **u32 min/max, no underflowing subtracts.** clampExtent uses only `@min`/`@max` + the guarded
  `cols-1` (cols is u16; widen via `@as(u32, cols)` AFTER the `cols==0` guard). No `y - n`.
- **`screen.pages.cols` is u16** (ghostty size.CellCountInt). Pass it straight to clampExtent's
  `cols: u16` param. `gridLastRow` returns u32 (the last row index).
- **`select.Sel.extent(cols)` returns null when INACTIVE.** toGhosttySelection handles null ⇒
  whole-grid (defensive; the confirm call site guarantees active). Do NOT panic on null.
- **`Selection.init` is UNTRACKED; do NOT call `deinit`** (no-op + needs `*Screen`). Document this
  on toGhosttySelection (mirrors buildSelection's GOTCHA). "Deinit by caller" in the contract =
  the caller owns the value's lifetime; for the untracked value that is a no-op.
- **Do NOT hand-roll wide-cell rounding** — the formatter does it (§2). Adding rounding in S2
  double-rounds and risks off-by-one. S2 = clamp + recipe ONLY.
- **Do NOT modify `buildSelection`** — REUSE it (the contract: "REUSE the exact recipe"). S2's
  clamp is what makes buildSelection's `error{OutOfRange}` unreachable here.
- **`screen.pages.getBottomRight(.screen)` does `self.pages.last.?`** — panics if pages.last is
  null. An initialized `Terminal` ALWAYS has ≥1 page, so this is safe for any screen derived from a
  live Terminal (the only kind region.zig / the tests build). wholeGridSelection's `orelse tl` is a
  belt-and-suspenders guard for the pointFromPin step, not the `.?`.

## 6. Testing strategy

### 6a. clampExtent — PURE ⇒ SEPARATE `test` fns (no Terminal)
Mirror render.zig's determineCols/lineCount test style. Cover:
- **linewise passthrough (in-range):** ext `{0,2,79,7,false}`, cols=80, last_row=23 ⇒ identical
  `{0,2,79,7,false}` (no clamp).
- **block passthrough:** ext `{3,1,9,5,true}`, cols=10, last_row=9 ⇒ identical.
- **x clamp high:** ext `{0,0,99,0,false}` (x2 beyond grid), cols=10, last_row=5 ⇒ x2 clamped to 9.
- **y clamp high:** ext `{0,50,0,60,false}`, cols=80, last_row=23 ⇒ y1→23, y2→23.
- **cols==0 guard:** ext `{0,0,0,0,false}`, cols=0, last_row=5 ⇒ x1=x2=0 (no underflow).
- **order normalization (defensive):** ext `{9,7,0,2,false}` (reversed) cols=10 last_row=9 ⇒
  `{0,2,9,7,false}` (min/max re-applied).
- **rect preserved:** a `.rect=true` ext stays `.rect=true` through clamp.
- **last_row==0 (degenerate):** ext `{0,5,0,5,false}`, cols=10, last_row=0 ⇒ y1=y2=0.

### 6b. toGhosttySelection / gridLastRow / wholeGridSelection — APPEND to render.zig's single Terminal test
Build a Terminal in the SHARED scope, feed ANSI (incl. a wide char), set up a `select.Sel` by hand
(setting `.anchor`/`.cursor`/`.mode` directly — no input/motion import needed), call
`toGhosttySelection`, and verify. Cover:
- **linewise:** feed "R0\nR1\nR2\nR3\nR4\nR5" into cols=80 rows=6; sel linewise anchor(0,1)
  cursor(0,5); `toGhosttySelection(sel, screen, 80)`; round-trip start/end pins via
  `screen.pages.pointFromPin(.screen, gs.start()/end())` ⇒ coords {0,1}..{79,5}, rectangle=false.
  THEN format the Selection via ScreenFormatter (`f.content = .{ .selection = gs }`) and assert
  the HTML contains R1..R5 and NOT R0 (reuses the proven S1 assertion shape).
- **block:** feed "ABCDEFGHIJ\nABCDEFGHIJ\nABCDEFGHIJ" cols=10 rows=3; sel block anchor(2,0)
  cursor(5,2); ⇒ coords {2,0}..{5,2}, rectangle=true; format ⇒ HTML contains "CDEF", not full rows.
- **clamp (no error):** sel linewise with cursor.y BEYOND the grid (e.g. set cursor.y=100 on a
  6-row grid); `toGhosttySelection` CLAMPS y to gridLastRow (5) instead of erroring ⇒ renders rows
  up to the last (no `error.OutOfRange`). This is the behavioral delta vs the CLI `--selection` path.
- **inactive ⇒ whole-grid:** sel with mode=.none; `toGhosttySelection` ⇒ a Selection spanning
  top-left..bottom-right (format ⇒ full grid HTML).
- **wide-cell atomicity (delegation proof):** feed a wide glyph (真 U+771F = UTF-8 e7 9c 9f) at
  col 0 (occupies cols 0-1; col 1 is spacer_tail) into cols=4 rows=1; sel linewise covering row 0;
  format the Selection ⇒ the glyph appears EXACTLY ONCE (the formatter rounds/emits atomically;
  S2 did nothing special). This proves PRD §13 is satisfied by delegation.

(All Terminal-building assertions share the ONE render.zig test scope per the cross-test GOTCHA.
clampExtent's separate fns are PURE and safe.)

## 7. File footprint (exactly)

- **EDIT** `src/render.zig`:
  - ADD imports: `const select = @import("tui/select.zig");` + `const view = @import("tui/view.zig");`
    (after the existing `cli` import, ~line 23).
  - ADD `pub fn toGhosttySelection(sel: select.Sel, screen: *const Screen, cols: u16) Selection`
    (near buildSelection, ~line 199).
  - ADD `pub fn clampExtent(ext: view.Selection, cols: u16, last_row: u32) cli.SelectionCoords`
    (PURE helper, near buildSelection).
  - ADD private `fn gridLastRow(screen: *const Screen) u32` + `fn wholeGridSelection(screen:
    *const Screen) Selection` (near buildSelection).
  - APPEND clampExtent `test` fns (separate — PURE) + toGhosttySelection assertions to the SINGLE
    `"renderGrid: red foreground..."` Terminal test (cross-test GOTCHA).
- **NO** new file. **NO** build.zig / build.zig.zon change. **NO** edit to select.zig / view.zig /
  cli.zig / input.zig / app.zig / motion.zig / main.zig. **NO** modification of buildSelection.
