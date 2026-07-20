# Mouse Wiring Design (Issue 1, PRD §7.6)

## Goal
Make mouse input functional in the region overlay (PRD §7.6): **click moves cursor; drag
selects (linewise default, block with Alt); wheel scrolls.** Today the decoded `MouseEvent`
is dropped by `regionHandle`. The fix is pure glue over existing, unit-tested primitives.

## Where the code goes
ALL in `src/region.zig` (the EventHandler owner). `app.zig` already decodes SGR mouse into
`app.MouseEvent`; `input.zig`, `motion.zig`, `select.zig`, `view.zig` are UNCHANGED (consume
their existing pub API). The fix:
1. A new `mouse_anchor: ?view.Pos` field on `RegionCtx` (drag tracking).
2. A PURE coordinate-conversion fn `mouseCell(...)`.
3. A PURE state-machine fn `applyMouse(...)` (mutates cursor + sel + mouse_anchor; NO I/O).
4. A `.mouse` arm in `regionHandle` (before `input.feed`) that calls `applyMouse` + `repaint`.

## Coordinate conversion — `mouseCell` (PURE, unit-tested)
SGR `MouseEvent.x/y` are **1-based** character cells on the popup screen. Convert to a 0-based
GRID cell (origin top-left), honoring the viewport scroll + excluding the status-line row:

```zig
/// PURE: convert a 1-based SGR (sx,sy) to a 0-based grid cell.
/// vy is clamped to the grid area [0, grid_rows-1] (excludes the status line at row grid_rows);
/// gy adds the viewport scroll; both clamped with SATURATING subtract (no u32 underflow).
fn mouseCell(sx: u32, sy: u32, scroll: u32, grid_rows: u16, total_rows: u32, tty_cols: u16) view.Pos {
    const gx: u32 = @min(if (sx >= 1) sx - 1 else 0, (@as(u32, tty_cols) -| 1));
    const vy: u32 = @min(if (sy >= 1) sy - 1 else 0, (@as(u32, grid_rows) -| 1));
    const gy: u32 = @min(scroll +| vy, (if (total_rows >= 1) total_rows - 1 else 0));
    return .{ .x = gx, .y = gy };
}
```
Validated against `view.render`'s mapping (`gy = scroll + vy`; CUP to `vy+1`; col 1 = gx 0).
Unit-test cases: plain click; click on status line clamps to last grid row; scroll offset
applied; clamping at cols/rows edges; degenerate grid_rows==0 / tty_cols==0 (no underflow).

## State machine — `applyMouse` (PURE, unit-tested with stack cursor/sel — NO Terminal)
Operates on explicit pointers (so it is testable WITHOUT constructing a RegionCtx/Screen):

```zig
fn applyMouse(
    cursor: *motion.Cursor,
    sel: *select.Sel,
    mouse_anchor: *?view.Pos,
    m: app.MouseEvent,
    grid_rows: u16,
    total_rows: u32,
    tty_cols: u16,
) void
```
Behavior (tmux copy-mode-mouse parity; PRD §7.6):

- **press** (button down at cell):
  - `cursor.pos = cell`; `cursor.viewport.scroll = view.scrollForCursor(cell.y, cursor.viewport, total_rows)`.
  - `sel.clear()` (a fresh click discards any prior selection, like tmux copy-mode-mouse).
  - `sel.cursor = cursor.pos`; `mouse_anchor.* = cell` (remember press start for drag).
- **motion** (drag — mode 1002 guarantees a button is held):
  - if `mouse_anchor.*` != null (a drag is active):
    - `want_mode = if (m.alt) .block else .linewise` (§7.6: "block with modifier, e.g. Alt").
    - if `!sel.active()` ⇒ `sel.begin(anchor, want_mode)` (begin selection at the press cell);
      else if `sel.mode != want_mode` ⇒ `sel.mode = want_mode` (live mode switch mid-drag).
    - `cursor.pos = cell`; `scrollForCursor`; `sel.cursor = cursor.pos` (extends anchor→cursor).
  - else (motion with no press — only in mode 1003 hover): just move `cursor.pos` + scrollForCursor.
- **release** (button up at cell):
  - if `mouse_anchor.*` != null: `cursor.pos = cell`; scrollForCursor; `sel.cursor = cursor.pos`;
    `mouse_anchor.* = null`. If the selection collapsed to a single cell (anchor==cursor ⇒ a click
    with no drag), `sel.clear()` so a plain click leaves NO selection (Enter after a click ⇒ "no
    selection" exit 1, matching "click to move cursor").
- **wheel_up**: `cursor.viewport.scroll = view.halfPageUp(scroll, total_rows, grid_rows)`; then
  `clampCursorIntoViewport(cursor, sel, total_rows, grid_rows)` (keep cursor visible).
- **wheel_down**: `view.halfPageDown(...)`; then clamp. (Half-page matches Ctrl-d/u; documented
  choice — tmux's default 5-line wheel scroll is a possible future refinement.)

```zig
/// PURE: after a viewport scroll, clamp cursor.pos.y into [scroll, min(total-1, scroll+rows-1)]
/// and sync sel.cursor. Mirrors motion.zig's page_down/page_up cursor clamping.
fn clampCursorIntoViewport(cursor: *motion.Cursor, sel: *select.Sel, total_rows: u32, grid_rows: u16) void {
    const lo = cursor.viewport.scroll;
    const last = if (total_rows >= 1) total_rows - 1 else 0;
    const hi = @min(last, cursor.viewport.scroll +| (@as(u32, grid_rows) -| 1));
    if (cursor.pos.y < lo) cursor.pos.y = lo;
    if (cursor.pos.y > hi) cursor.pos.y = hi;
    sel.cursor = cursor.pos;
}
```

### Unit tests for applyMouse (stack-allocated; no Screen/Terminal ⇒ safe separate `test` fns)
- press moves cursor + clears sel + sets anchor.
- drag (motion after press) begins linewise at anchor; cursor extends; extent = anchor..cursor.
- drag with `m.alt` ⇒ block mode (extent rect=true); toggling alt mid-drag switches mode.
- release after a drag keeps the selection (anchor..release-cell); release of a click (no motion)
  leaves NO selection (cleared).
- wheel_up/wheel_down move viewport.scroll by half-page and clamp the cursor into view.
- motion with no prior press just moves the cursor.

## regionHandle wiring (the `.mouse` arm)
Add a branch BEFORE the `input.feed` call (feed returns null for mouse, so it must be consumed
first). Search-mode already ignores non-key events (`handleSearchByte` returns `.none` for
`else`), so mouse is naturally ignored while typing a search pattern:

```zig
fn regionHandle(opaque_ctx: ?*anyopaque, ev: app.Event) app.Action {
    const ctx: *RegionCtx = @ptrCast(@alignCast(opaque_ctx.?));
    if (ctx.searching) return handleSearchByte(ctx, ev);   // mouse ignored while typing

    // ---- MOUSE (PRD §7.6): consume the decoded MouseEvent BEFORE the keyboard decoder ----
    switch (ev) {
        .mouse => |m| {
            applyMouse(&ctx.cursor, &ctx.sel, &ctx.mouse_anchor, m,
                       ctx.grid_rows, ctx.total_rows, ctx.tty_cols);
            repaint(ctx) catch {};   // resilient write (matches existing stance)
            return .none;
        },
        else => {},
    }

    // ---- KEYBOARD: feed the decoder (unchanged) ----
    if (input.feed(&ctx.decoder, ev)) |key| { /* unchanged motion/action/search dispatch */ }
    return .none;
}
```
Update the `regionHandle` doc-comment: REMOVE the "Mouse is a NO-OP / follow-up" note; state
that mouse is now wired (§7.6). Remove the stale "input.feed returns null … on .mouse" framing
in favor of the explicit `.mouse` arm.

## Non-goals / explicit decisions
- No new config option / env var / CLI flag (mouse is always-on, matching §7.6 "supported").
- `input.zig`/`motion.zig`/`select.zig`/`view.zig`/`app.zig` are NOT modified.
- Mid-drag Alt toggle is supported (mode set per-event); shift-click extend is NOT (§7.6 only
  names Alt for block). Wheel = half-page (documented; tmux's 5-line default deferred).
- applyMouse does NOT call `motion.applyMotion` or `motion.Grid` — it sets `cursor.pos`/`sel`
  directly, so it is fully unit-testable with stack structs (no SliceGrid/Terminal needed).