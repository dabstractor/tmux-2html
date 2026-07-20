# Research findings — P1.M2.T1.S2: pure `applyMouse()` + `clampCursorIntoViewport()` + tests

All facts read **directly from the on-disk source** (`src/region.zig`, `src/tui/*.zig`).
The design is `architecture/mouse_wiring_design.md`; this file verifies its `applyMouse` /
`clampCursorIntoViewport` spec against the REAL APIs so the PRP can quote them verbatim.

## 0. Consumed contract (P1.M2.T1.S1 — ALREADY MERGED on disk)

S1 is **implemented**: `fn mouseCell(sx, sy, scroll, grid_rows, total_rows, tty_cols) view.Pos`
lives at **`src/region.zig:127`** in a `// ---- Mouse wiring (PRD §7.6) ----` section (line 115),
with its 6 tests at lines 1167–1205. **This task (S2) APPENDS `applyMouse` + `clampCursorIntoViewport`
right after `mouseCell` (between its closing `}` at line ~133 and the `// ====` separator at
line 135), and appends new test fns at the bottom of the file (after line 1205).** mouseCell is
module-private and takes raw u32 coords — `applyMouse` calls `mouseCell(m.x, m.y, cursor.viewport.scroll,
grid_rows, total_rows, tty_cols)`.

## 1. The input/state types — ALL VERIFIED against source

### `motion.Cursor` (`src/tui/motion.zig:62`)
```zig
pub const Cursor = struct { pos: view.Pos, viewport: view.Viewport };
```
EXACTLY two fields. Tests construct `motion.Cursor{ .pos = .{ .x = …, .y = … }, .viewport =
.{ .cols = …, .rows = …, .scroll = … } }` (same shape motion.zig's own tests use).

### `view` types (`src/tui/view.zig`)
- `Pos = struct { x: u32, y: u32 }` (line 50) — 0-based grid cell.
- `Viewport = struct { cols: u16, rows: u16, scroll: u32 }` (line 40).
- `Selection = struct { x1, y1, x2, y2: u32, rect: bool = false }` (line 55).
- `SelMode = enum { none, line, block }` (line 79).
- `scrollForCursor(cursor_y: u32, viewport: Viewport, total_rows: u32) u32` (line 485) — reads
  `viewport.scroll` AND `viewport.rows`; returns 0 when `total_rows <= rows`; else minimal
  keep-visible scroll (`cursor_y` if above, `cursor_y-(rows-1)` if below, else unchanged), clamped.
- `halfPageUp(scroll, total_rows, viewport_rows: u16) u32` (line 536) — `half=rows/2`;
  `s = scroll>=half ? scroll-half : 0`; `clampScroll(s, total_rows, viewport_rows)`.
- `halfPageDown(scroll, total_rows, viewport_rows: u16) u32` (line 531) — `clampScroll(scroll +
  rows/2, total_rows, viewport_rows)`.
- `clampScroll(scroll, total_rows, viewport_rows) u32` (line ~478) — `if (total_rows <=
  viewport_rows) return 0; const max = total_rows - viewport_rows; return @min(scroll, max);`

### `select.Sel` + `select.Mode` (`src/tui/select.zig`)
```zig
pub const Mode = enum { none, linewise, block };                       // line 27
pub const Sel = struct {
    anchor: view.Pos = .{ .x = 0, .y = 0 },                              // line 36
    cursor: view.Pos = .{ .x = 0, .y = 0 },
    mode: Mode = .none,
    pub fn active(self: Sel) bool { return self.mode != .none; }        // line 42
    pub fn clear(self: *Sel) void { self.mode = .none; }                // line 48
    pub fn toggle(self: *Sel) void { ... }                              // line 55 (linewise<->block, none stays none)
    pub fn begin(self: *Sel, pos: view.Pos, mode: Mode) void { ... }    // line 78 (anchor=cursor=pos, mode=mode)
    pub fn extent(self: Sel, cols: u16) ?view.Selection { ... }         // line 92 (null if .none)
    pub fn viewMode(self: Sel) view.SelMode { ... }
};
```
`sel.cursor` is a PUBLIC settable field — applyMouse writes it directly. `begin(pos, mode)` sets
anchor=cursor=pos. `clear()` only flips mode→none (endpoints left stale). `active()` == mode≠none.

### `app.MouseEvent` (`src/tui/app.zig:259`)
```zig
pub const MouseButton = enum { left, middle, right, none };             // line 251
pub const MouseAction = enum { press, release, motion, wheel_up, wheel_down };  // line 253
pub const MouseEvent = struct {
    button: MouseButton,   // REQUIRED field — tests must set it
    action: MouseAction,
    x: u32,  // 1-based SGR column
    y: u32,  // 1-based SGR row
    shift: bool,   // (b & 4)
    alt: bool,     // (b & 8) — drives block-drag (PRD §7.6)
    ctrl: bool,    // (b & 16)
};
```
**GOTCHA:** `MouseEvent` has a `button` field — every test value must set it (`.button = .left`
for press/motion/release, `.button = .none` for wheel/hover). The struct literal must be COMPLETE
(all 7 fields) — Zig has no partial init. The `app.Event` union arm is `.mouse => |m|` (line 296).

## 2. The verbatim implementation (verified against the APIs above)

```zig
// ---- applyMouse (S2) + clampCursorIntoViewport (S2) — PURE mouse state machine ----
// Consumed by the .mouse arm in regionHandle (P1.M2.T2.S1). Pure: explicit pointers, NO I/O,
// NO Terminal/Screen => unit-testable with stack cursor/sel/anchor. tmux copy-mode-mouse parity.

/// PURE: after a viewport scroll (wheel), clamp cursor.pos.y into the visible window
/// [scroll, min(total-1, scroll+grid_rows-1)] (saturating) and sync sel.cursor. Mirrors
/// motion.zig's page_up/page_down/half_page_* cursor clamping. grid_rows = visible grid rows.
fn clampCursorIntoViewport(cursor: *motion.Cursor, sel: *select.Sel, total_rows: u32, grid_rows: u16) void {
    const lo: u32 = cursor.viewport.scroll;
    const last: u32 = if (total_rows >= 1) total_rows - 1 else 0;
    const hi: u32 = @min(last, cursor.viewport.scroll +| (@as(u32, grid_rows) -| 1));
    if (cursor.pos.y < lo) cursor.pos.y = lo;
    if (cursor.pos.y > hi) cursor.pos.y = hi;
    sel.cursor = cursor.pos;
}

/// PURE mouse state machine (PRD §7.6 / tmux copy-mode-mouse parity). Mutates cursor/sel/
/// mouse_anchor via explicit pointers (testable without a RegionCtx/Screen). `cell` is the
/// 0-based grid cell from mouseCell (S1).
///
///   press    — move cursor to cell + scrollForCursor; sel.clear() (fresh click discards prior);
///               sel.cursor = cursor.pos; mouse_anchor = cell (remember press start for drag).
///   motion   — drag if mouse_anchor set: want_mode = m.alt ? .block : .linewise; begin(at anchor)
///               if inactive else switch mode live; move cursor + extend sel.cursor. else (hover):
///               just move cursor + scrollForCursor.
///   release  — if mouse_anchor set: move cursor + sync sel.cursor; mouse_anchor = null; if the
///               selection collapsed to one cell (anchor == cursor => a click, no drag) sel.clear().
///   wheel_*  — halfPageUp/halfPageDown; then clampCursorIntoViewport (keep cursor visible).
fn applyMouse(
    cursor: *motion.Cursor,
    sel: *select.Sel,
    mouse_anchor: *?view.Pos,
    m: app.MouseEvent,
    grid_rows: u16,
    total_rows: u32,
    tty_cols: u16,
) void {
    const cell: view.Pos = mouseCell(m.x, m.y, cursor.viewport.scroll, grid_rows, total_rows, tty_cols);
    switch (m.action) {
        .press => {
            cursor.pos = cell;
            cursor.viewport.scroll = view.scrollForCursor(cell.y, cursor.viewport, total_rows);
            sel.clear();
            sel.cursor = cursor.pos;
            mouse_anchor.* = cell;
        },
        .motion => {
            if (mouse_anchor.*) |anchor| {
                const want_mode: select.Mode = if (m.alt) .block else .linewise;
                if (!sel.active()) {
                    sel.begin(anchor, want_mode);
                } else if (sel.mode != want_mode) {
                    sel.mode = want_mode;
                }
                cursor.pos = cell;
                cursor.viewport.scroll = view.scrollForCursor(cell.y, cursor.viewport, total_rows);
                sel.cursor = cursor.pos;
            } else {
                cursor.pos = cell;
                cursor.viewport.scroll = view.scrollForCursor(cell.y, cursor.viewport, total_rows);
            }
        },
        .release => {
            if (mouse_anchor.*) |_| {
                cursor.pos = cell;
                cursor.viewport.scroll = view.scrollForCursor(cell.y, cursor.viewport, total_rows);
                sel.cursor = cursor.pos;
                mouse_anchor.* = null;
                // A click with no drag (selection collapsed to one cell) leaves no selection.
                if (sel.active() and std.meta.eql(sel.anchor, cursor.pos)) sel.clear();
            }
        },
        .wheel_up => {
            cursor.viewport.scroll = view.halfPageUp(cursor.viewport.scroll, total_rows, grid_rows);
            clampCursorIntoViewport(cursor, sel, total_rows, grid_rows);
        },
        .wheel_down => {
            cursor.viewport.scroll = view.halfPageDown(cursor.viewport.scroll, total_rows, grid_rows);
            clampCursorIntoViewport(cursor, sel, total_rows, grid_rows);
        },
    }
}
```

### Why this is correct (cross-checked against the verified APIs)
- `mouseCell` returns `view.Pos`; `cursor.pos = cell` type-checks (`pos: view.Pos`).
- `view.scrollForCursor(cell.y, cursor.viewport, total_rows)` matches the verified signature
  `(cursor_y: u32, viewport: Viewport, total_rows: u32) u32` — same call shape motion.zig's
  `.down`/`.up`/`$`/`G` use. It reads `cursor.viewport.scroll`+`.rows`.
- `sel.begin(anchor, want_mode)` matches `(pos: view.Pos, mode: Mode) void`; `sel.active()`,
  `sel.clear()`, `sel.mode`, `sel.anchor`, `sel.cursor` are all verified public members.
- `view.halfPageUp/Down(scroll, total_rows, viewport_rows: u16)` — `grid_rows` is `u16` ✓
  (matches the `viewport_rows: u16` param; in the real wiring grid_rows = tty_rows-1 = viewport.rows).
- `std.meta.eql(sel.anchor, cursor.pos)` compares two `view.Pos` (`{x:u32,y:u32}`) field-wise. `std`
  is already imported in region.zig (line 36).
- `clampCursorIntoViewport` uses saturating `-|`/`+|` + the `total_rows >= 1` guard (same safety
  discipline as S1's mouseCell). `lo`/`hi`/`last` are u32; `@as(u32, grid_rows)` widens before `-| 1`.
- The pointer params (`*motion.Cursor`, `*select.Sel`, `*?view.Pos`) mean callers in tests pass
  `&cursor`/`&sel`/`&anchor` — exactly the stack-alloc pattern the contract requires.

## 3. Test design (8 fns — all stack-allocated; NO Terminal ⇒ safe as separate `test` fns)

Test grid is constant: `tty_cols=80, grid_rows=10, total_rows=50, viewport{cols=80,rows=10,scroll=0}`
(unless the test needs scroll). mouseCell conversion (scroll=0): SGR `(sx,sy)` → cell `(sx-1, sy-1)`.

| # | test | sequence | key assertions |
|---|------|----------|----------------|
| 1 | press moves cursor + clears prior sel + sets anchor | prior linewise sel; press SGR(5,3) | cursor=(4,2); `!sel.active()`; sel.cursor=(4,2); anchor==(4,2) |
| 2 | drag begins linewise at anchor; extent anchor..cursor | press(3,2)→motion(8,6) | sel.linewise+active; anchor=(2,1); cursor=(7,5); extent y1=1,y2=5,rect=false |
| 3 | drag with alt ⇒ block | press(3,2)→motion alt(8,6) | sel.block; extent rect=true, x1=2,x2=7 |
| 4 | toggling alt mid-drag switches mode | press→motion no-alt→motion alt | linewise then block; anchor preserved |
| 5 | release after a drag keeps selection | press→motion→release(9,7) | active; anchor=(2,1); cursor=(8,6); anchor==null |
| 6 | a plain click (no drag) leaves NO selection | press(5,3)→release(5,3) | `!sel.active()`; anchor==null |
| 7 | wheel_up/wheel_down half-page scroll + clamp cursor | scroll=20,cursor.y=25; wheel_up; wheel_down | after up: scroll=15,cursor.y=24; after down: scroll=20,cursor.y=24 |
| 8 | motion with no prior press just moves cursor | motion(6,4), no press | cursor=(5,3); `!sel.active()`; anchor==null |

### Test 7 math (verified via clampScroll/halfPage* above)
- Start: scroll=20, cursor.y=25, grid_rows=10, total=50 (max scroll=40).
- `wheel_up`: halfPageUp(20,50,10)=15. clamp: lo=15, hi=min(49,15+9)=24 → cursor.y 25→24. ✓
- `wheel_down`: halfPageDown(15,50,10)=20. clamp: lo=20, hi=min(49,20+9)=29 → cursor.y 24 ∈[20,29] → 24. ✓

## 4. Placement + scope (DO NOT over-reach)
- **Placement:** insert `applyMouse` + `clampCursorIntoViewport` immediately AFTER `mouseCell`'s
  closing `}` (line ~133) and BEFORE the `// ====...regionHandle` separator (line 135) — i.e.
  extend the SAME `// ---- Mouse wiring (PRD §7.6) ----` section. The 8 test fns go at the BOTTOM
  of the file after the last S1 mouseCell test (line 1205).
- **SCOPE (S2 ONLY):** add the 2 fns + doc-comments + 8 tests. Do NOT touch `regionHandle`
  (line 157; still has the "Mouse is a NO-OP … follow-up" comment — that rewrite + the `.mouse` arm
  + `RegionCtx.mouse_anchor` are **P1.M2.T2.S1**). Do NOT modify `motion.zig`/`select.zig`/
  `view.zig`/`app.zig`/`input.zig`/`build.zig`. region.zig already imports `app`(42)/`view`(43)/
  `motion`(45)/`select`(46)/`std`(36) — no new imports.

## 5. Build/test gate (unchanged from S1)
`zig build test --release=fast` — `--release=fast` MANDATORY (Debug linker hits ghostty
`R_X86_64_PC64`). Tests are reachable via region.zig's existing test discovery (region.zig is
`@import`ed by main.zig, the test root). applyMouse/clampCursorIntoViewport construct NO Terminal/
Screen ⇒ safe as separate `test` fns (same as S1's mouseCell tests + the 20 pre-existing helpers).

## 6. Confidence
Every consumed API (`motion.Cursor`, `select.Sel`/`Mode`/methods, `view` scroll fns +
`Viewport`/`Pos`/`Selection`, `app.MouseEvent`/`MouseButton`/`MouseAction`) is verified line-by-line.
The implementation follows motion.zig's verified `scrollForCursor`/clamp patterns and S1's
saturating-arithmetic discipline. The test values (mouseCell conversions, wheel clamp math) are
derived from the verified `clampScroll`/`halfPage*`. Residual risk: low — the bodies are reasoned,
not run-verified (can't modify src as a research agent), but mirror compile-verified patterns.