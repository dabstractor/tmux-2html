# PRP — P1.M2.T1.S2: Pure `applyMouse()` state machine + `clampCursorIntoViewport()` + unit tests

## Goal

**Feature Goal**: Add the second pure building block of the mouse-wiring fix (Issue 1 / PRD §7.6): a
module-private, allocation-free, I/O-free **`applyMouse()`** state machine and a **`clampCursorIntoViewport()`**
helper in `src/region.zig` that translate an already-decoded `app.MouseEvent` into cursor / selection /
scroll mutations with tmux copy-mode-mouse parity (click moves cursor; drag selects linewise, block with
Alt; wheel scrolls half-page). They take explicit pointers (NOT a `RegionCtx`), so they are fully unit-
testable with stack-allocated value structs and NO `Terminal`/`Screen`. This is the pure state-machine
primitive the `regionHandle` `.mouse` arm (P1.M2.T2.S1) will consume.

**Deliverable**: ONE file changed (`/home/dustin/projects/tmux-2html/src/region.zig`) — purely additive:
- 2 new module-private fns (`fn applyMouse(...)` + `fn clampCursorIntoViewport(...)`) + Mode-A doc-comments.
- 8 new `test` fns (press/clear+anchor; linewise drag; Alt⇒block; mid-drag Alt toggle; release-after-drag
  keeps; plain-click clears; wheel up/down half-page+clamp; hover motion).
- No new files; NO changes to `regionHandle`, `RegionCtx`, `view.zig`, `app.zig`, `input.zig`,
  `motion.zig`, `select.zig`, `build.zig` (those are P1.M2.T2.S1 / out of scope).

**Success Definition** (the bodies + all 8 tests are reasoned from APIs **verified line-by-line** in
`research/findings.md`; same verified patterns S1 used):
- `zig build test --release=fast` → exit 0; the 8 new tests pass alongside S1's 6 mouseCell tests and
  the ~20 pre-existing region pure-helper tests.
- press ⇒ cursor moves to the cell + `sel.clear()` + `mouse_anchor = cell`; a linewise drag begins at
  the press cell and extends to the cursor; an Alt-drag is block; toggling Alt mid-drag switches mode;
  release after a drag keeps the selection; a plain click (press+release same cell, no drag) leaves NO
  selection; wheel up/down move `viewport.scroll` by half a page and clamp the cursor into view; a
  hover (motion with no prior press) just moves the cursor.

## User Persona

**Target User**: The implementer of **P1.M2.T2.S1 (the `regionHandle` `.mouse` arm + `RegionCtx.mouse_anchor`)**
— it will `switch (ev) { .mouse => |m| applyMouse(&ctx.cursor, &ctx.sel, &ctx.mouse_anchor, m,
ctx.grid_rows, ctx.total_rows, ctx.tty_cols); repaint(ctx) catch {}; return .none; }`. (End users never
call this directly; they get working §7.6 mouse once P1.M2.T2.S1 wires it in.)

**Use Case**: In the region overlay a left-press at SGR (x,y) → `applyMouse` moves the cursor there and
remembers the cell; a drag (motion events, button held) → it begins a selection at the press cell and
extends it to the cursor (linewise, or block while Alt is held); release → finalizes it; the wheel →
scrolls half a page and keeps the cursor visible. All of this is computed by these two pure fns.

**Pain Points Addressed**: Isolates the tmux-copy-mode-parity mouse state machine in ONE pure, unit-tested
place so the wiring task (P1.M2.T2.S1) is a 4-line `switch` arm and the click/drag/wheel semantics are
provably correct independent of any `Terminal`/pty.

## Why

- **Foundation of the Issue 1 fix (PRD §7.6).** Mouse is decoded but discarded today (`regionHandle` has
  no `.mouse` arm). The fix is layered: S1 = pure coordinate conversion (DONE), **S2 = pure state machine
  (this task)**, P1.M2.T2.S1 = the `.mouse` wiring + `RegionCtx.mouse_anchor` field. Splitting the state
  machine out makes it independently verifiable — the trickiest part (press/drag/release/wheel timing,
  Alt⇒block, click-vs-drag, mid-drag mode switch) is locked down by 8 deterministic tests with no I/O.
- **Pure ⇒ CI-testable without a pty.** Issue 1 was missed precisely because "no integration test sends a
  mouse event." S2's pure fns give deterministic unit coverage of the whole §7.6 state machine; P1.M2.T3.S1
  adds the pty integration harness on top.
- **Zero risk to existing behavior.** Purely additive (2 fns + 8 tests); no existing code path calls
  `applyMouse` yet, so nothing can regress until P1.M2.T2.S1 wires it in. Consumes only verified pub APIs.

## What

Add to `src/region.zig`, extending the existing `// ---- Mouse wiring (PRD §7.6) ----` section (right
after S1's `mouseCell`, before the `regionHandle` separator):

- `fn applyMouse(cursor: *motion.Cursor, sel: *select.Sel, mouse_anchor: *?view.Pos, m: app.MouseEvent,
  grid_rows: u16, total_rows: u32, tty_cols: u16) void` — the §7.6 state machine (press / motion / release
  / wheel_up / wheel_down). Pure (mutates only through the explicit pointers).
- `fn clampCursorIntoViewport(cursor: *motion.Cursor, sel: *select.Sel, total_rows: u32, grid_rows: u16) void`
  — clamp `cursor.pos.y` into `[scroll, min(total-1, scroll+grid_rows-1)]` and sync `sel.cursor`.

And append 8 `test` fns at the bottom of the file (after S1's 6 mouseCell tests), exactly as below.

### Success Criteria

- [ ] `applyMouse` + `clampCursorIntoViewport` added as module-private fns in `src/region.zig` (exact
      bodies below, with their Mode-A doc-comments), placed right after `mouseCell`.
- [ ] 8 new `test` fns pass (press/clear+anchor, linewise drag, Alt⇒block, mid-drag Alt toggle,
      release-after-drag, plain-click-clears, wheel up/down, hover motion).
- [ ] `zig build test --release=fast` → exit 0 (8 new + S1's 6 mouseCell + ~20 existing region tests).
- [ ] ONLY `src/region.zig` changed; `regionHandle`/`RegionCtx`/`view.zig`/`app.zig` UNCHANGED.
- [ ] No `.mouse` arm / `RegionCtx.mouse_anchor` added (that is P1.M2.T2.S1).

## All Needed Context

### Context Completeness Check

_Pass: "If someone knew nothing about this codebase, would they have everything needed to implement this
successfully?"_ — Yes. The verbatim `applyMouse` + `clampCursorIntoViewport` bodies + doc-comments + 8 test
fns are specified below, reasoned from APIs **verified line-by-line against the on-disk source** (citations
in `research/findings.md`): `motion.Cursor{pos,viewport}`, `select.Sel`/`Mode`/`begin`/`clear`/`active`/
`extent`, `view.scrollForCursor`/`halfPageUp`/`halfPageDown`/`clampScroll`/`Viewport`/`Pos`, and
`app.MouseEvent`/`MouseButton`/`MouseAction`. The consumed `mouseCell` (S1) is already on disk at line 127.
The placement (after `mouseCell`), the exact `MouseEvent` struct shape (incl. the required `button` field),
and the scope boundary (S2 = ONLY these 2 fns + 8 tests; no wiring) are all documented. The implementer is
copying two reasoned fns + 8 reasoned tests into one file.

### Documentation & References

```yaml
# MUST READ — the verified APIs + the verbatim implementation + the 8-test verification table
- file: plan/004_92f7aeb62a3a/bugfix/002_b76ad57f9c71/P1M2T1S2/research/findings.md
  why: "§1 every consumed type/fn verified line-by-line (motion.Cursor; select.Sel/Mode/begin/clear/active;
        view.scrollForCursor/halfPageUp/halfPageDown/clampScroll + Viewport/Pos/Selection;
        app.MouseEvent/MouseButton/MouseAction). §2 the verbatim applyMouse + clampCursorIntoViewport
        bodies + why each line is correct. §3 the 8 tests with the mouseCell conversion + wheel-clamp
        math. §4 placement + scope. §5 build gate."
  critical: "app.MouseEvent has a REQUIRED `button: MouseButton` field — every test value must set it
             (.left for press/motion/release; .none for wheel/hover) AND all 7 fields, or the struct
             literal won't compile. applyMouse signature param order is (cursor, sel, mouse_anchor, m,
             grid_rows:u16, total_rows:u32, tty_cols:u16); clampCursorIntoViewport is (cursor, sel,
             total_rows:u32, grid_rows:u16) — NOTE the grid_rows/total_rows ORDER DIFFERS between the two."

# MUST READ — the design this task implements (Issue 1 / §7.6)
- file: plan/004_92f7aeb62a3a/bugfix/002_b76ad57f9c71/architecture/mouse_wiring_design.md
  section: "'State machine — applyMouse' + 'clampCursorIntoViewport' + 'Unit tests for applyMouse' + 'Non-goals'"
  why: "The authoritative design. applyMouse/clampCursorIntoViewport are specified there; the .mouse arm +
        RegionCtx.mouse_anchor are explicitly NOT this task (P1.M2.T2.S1). Mid-drag Alt toggle is supported;
        shift-click extend is NOT (§7.6 only names Alt); wheel = half-page (documented)."

# MUST READ — the previous PRP (S1 = mouseCell; this task consumes its output)
- file: plan/004_92f7aeb62a3a/bugfix/002_b76ad57f9c71/P1M2T1S1/PRP.md
  why: "S1 is MERGED: mouseCell lives at src/region.zig:127. This task calls mouseCell(m.x, m.y,
        cursor.viewport.scroll, grid_rows, total_rows, tty_cols) to get the grid cell. Do NOT re-add or
        touch mouseCell."

# MUST READ — the file being edited + the consumed types/consumers
- file: src/region.zig
  section: "imports (app:42, view:43, motion:45, select:46, std:36); mouseCell (127) — insert AFTER it;
            regionHandle (157) — DO NOT TOUCH; RegionCtx (88: tty_cols:92, grid_rows:94, total_rows:95);
            mouseCell tests (1167-1205) — append new tests AFTER line 1205."
  why: "Confirms region.zig already imports all needed modules (no new imports), where mouseCell sits
        (so applyMouse goes right after it), and that separate pure-helper test fns are the established
        pattern (~20 pre-existing + S1's 6)."
- file: src/tui/motion.zig
  section: "Cursor (62: {pos, viewport}); applyMotion clamp pattern (half_page_up/down: lo=scroll,
            hi=@min(last, scroll+rows-1)) — clampCursorIntoViewport mirrors it."
- file: src/tui/select.zig
  section: "Mode (27); Sel (36: anchor/cursor/mode); begin(78)/clear(48)/active(42)/toggle(55)/extent(92)."
- file: src/tui/view.zig
  section: "Pos(50)/Viewport(40)/Selection(55); scrollForCursor(485)/halfPageUp(536)/halfPageDown(531)/
            clampScroll(~478)."
- file: src/tui/app.zig
  section: "MouseButton(251); MouseAction(253); MouseEvent(259: button/action/x/y/shift/alt/ctrl); Event(291)."

# PRD context (this is the §7.6 mouse fix, layered; S2 = the pure state machine)
- file: PRD.md
  section: "Major Issue 1 (Mouse §7.6 non-functional) + §7.6 ('Click to move cursor; drag to select
            [linewise default, block with Alt]; wheel to scroll')"
  why: "Confirms mouse is SUPPORTED (not §16 out-of-scope) and the exact semantics (click/drag/Alt-block/
        wheel) this state machine implements. tmux copy-mode-mouse parity: fresh click discards prior sel;
        drag begins at press cell + extends; plain click leaves no selection."
```

### Current Codebase tree (this task's starting point — S1 is MERGED)

```bash
tmux-2html/
├── src/
│   ├── region.zig         # 1205 lines; mouseCell(127)+6 tests(1167-1205); regionHandle(157)  ← ADD applyMouse+clamp+8 tests
│   ├── tui/motion.zig     # Cursor{pos,viewport}(62); applyMotion clamp pattern              ← DO NOT TOUCH
│   ├── tui/select.zig     # Sel/Mode/begin/clear/active/extent                               ← DO NOT TOUCH
│   ├── tui/view.zig       # Pos/Viewport/Selection; scrollForCursor/halfPage*/clampScroll    ← DO NOT TOUCH
│   ├── tui/app.zig        # MouseEvent/MouseButton/MouseAction/Event                         ← DO NOT TOUCH
│   └── …
├── build.zig  build.zig.zon                                                               ← DO NOT TOUCH
```

### Desired Codebase tree with files to be changed

```bash
tmux-2html/
└── src/
    └── region.zig        # +applyMouse() +clampCursorIntoViewport() (after mouseCell) +8 test fns +doc-comments
```

### Known Gotchas of our codebase & Library Quirks

```zig
// GOTCHA 1 — CRITICAL: app.MouseEvent has a REQUIRED `button: MouseButton` field (src/tui/app.zig:259).
//   Every test struct literal MUST set ALL 7 fields (button, action, x, y, shift, alt, ctrl) — Zig has no
//   partial init. Use .button = .left for press/motion/release, .button = .none for wheel/hover. A literal
//   missing `button` will not compile ("missing struct field").

// GOTCHA 2 — PARAM ORDER DIFFERS between the two fns (pinned by the item contract):
//     applyMouse(cursor, sel, mouse_anchor, m, grid_rows:u16, total_rows:u32, tty_cols:u16)
//     clampCursorIntoViewport(cursor, sel, total_rows:u32, grid_rows:u16)
//   applyMouse is (grid_rows, total_rows, tty_cols); clamp is (total_rows, grid_rows). Do NOT reorder.

// GOTCHA 3 — applyMouse sets cursor.pos / cursor.viewport.scroll DIRECTLY (it does NOT call
//   motion.applyMotion or build a motion.Grid). That is deliberate: it makes the fn PURE and testable with
//   stack structs (no SliceGrid/Terminal). view.scrollForCursor(cell.y, cursor.viewport, total_rows) is the
//   ONLY scroll math it needs (same call shape motion.zig's .down/.up/$/G use). Do NOT "improve" it by
//   routing through motion.applyMotion.

// GOTCHA 4 — USE SATURATING arithmetic in clampCursorIntoViewport: (@as(u32, grid_rows) -| 1),
//   cursor.viewport.scroll +| (…). grid_rows can be 0 (degenerate); guard total_rows >= 1 before the -1
//   for `last`. Plain `-`/`+` would underflow on the 0-dim cases (same discipline as S1's mouseCell).
//   Widen grid_rows (u16) to u32 BEFORE the `-| 1`.

// GOTCHA 5 — `sel.cursor = cursor.pos` is a direct field write (select.Sel.cursor is PUBLIC). Do NOT call
//   sel.begin() every event — begin RESETS anchor=cursor=pos (that would lose the drag anchor). begin is
//   called ONCE (when the drag starts, with the press anchor); subsequent motion only updates sel.cursor.

// GOTCHA 6 — Mid-drag Alt toggle: set `sel.mode = want_mode` directly when the drag is already active and
//   the mode differs (do NOT call sel.toggle() — toggle on .none is a no-op and on an active sel it
//   blindly flips, but here want_mode is computed from m.alt so a direct assignment is exact). This lets
//   the user press/release Alt during a drag and have the rectangle switch live (PRD §7.6).

// GOTCHA 7 — Click-vs-drag on release: clear the selection ONLY if it collapsed to one cell
//   (`sel.active() and std.meta.eql(sel.anchor, cursor.pos)`). A pure click (press then release, no motion)
//   never calls sel.begin, so sel is already inactive at release — the guard handles the "dragged out and
//   back to the start cell" case (clears a useless single-cell sel). std.meta.eql compares the two view.Pos
//   {x:u32,y:u32} field-wise. Do NOT compare mouse_anchor here (it was just nulled); compare sel.anchor.

// GOTCHA 8 — SAFE as standalone test fns: applyMouse/clampCursorIntoViewport construct NO Terminal/Screen,
//   so they do NOT trigger the cross-test GOTCHA (render.zig:838, Terminal.init process-global state).
//   region.zig already has ~20 standalone pure-helper test fns + S1's 6 mouseCell tests — these 8 follow
//   the same pattern. Separate fns (not one bundled test); std.testing.expectEqual.

// GOTCHA 9 — build/test MUST use --release=fast: Debug linking hits the ghostty R_X86_64_PC64 linker bug.
//   `zig build test` (no release flag) FAILS. Always `zig build test --release=fast`.

// GOTCHA 10 — SCOPE: S2 adds ONLY applyMouse + clampCursorIntoViewport + doc-comments + 8 tests. Do NOT add
//   the `.mouse` arm in regionHandle, RegionCtx.mouse_anchor, or rewrite regionHandle's "Mouse is a NO-OP"
//   doc-comment — those are P1.M2.T2.S1. Do NOT touch mouseCell (S1, merged) or any other src file.
```

## Implementation Blueprint

### Data models and structure

No new types. This task reuses `motion.Cursor` / `select.Sel`+`Mode` / `view.Pos`+`Viewport` /
`app.MouseEvent` (all verified in `research/findings.md §1`) and the S1 `mouseCell` primitive. Both fns are
pure (no allocation, no I/O, no `Terminal`); they mutate state only through their explicit pointer params.

### The exact deliverable: `src/region.zig` (ADD — 2 fns + doc-comments + 8 tests)

**Edit 1 — the 2 fns + their doc-comments.** Insert immediately AFTER S1's `mouseCell` closing `}` (line
~133) and BEFORE the `// ====...regionHandle` separator (line 135) — i.e. extend the same `// ---- Mouse
wiring (PRD §7.6) ----` section. (region.zig already imports `std`(36)/`app`(42)/`view`(43)/`motion`(45)/
`select`(46) — no new imports.)

```zig
// ---- applyMouse (S2) + clampCursorIntoViewport (S2) — PURE mouse state machine (PRD §7.6) ----------
// Consumed by the .mouse arm in regionHandle (P1.M2.T2.S1). Pure: explicit pointers, NO I/O,
// NO Terminal/Screen => unit-testable with stack cursor/sel/anchor. tmux copy-mode-mouse parity.

/// PURE: after a viewport scroll (wheel), clamp cursor.pos.y into the visible window
/// [scroll, min(total-1, scroll+grid_rows-1)] (saturating) and sync sel.cursor. Mirrors
/// motion.zig's page_up/page_down/half_page_* cursor clamping. grid_rows = visible grid rows
/// (= tty_rows-1 in the real wiring). No I/O, no Terminal.
fn clampCursorIntoViewport(cursor: *motion.Cursor, sel: *select.Sel, total_rows: u32, grid_rows: u16) void {
    const lo: u32 = cursor.viewport.scroll;
    const last: u32 = if (total_rows >= 1) total_rows - 1 else 0;
    const hi: u32 = @min(last, cursor.viewport.scroll +| (@as(u32, grid_rows) -| 1));
    if (cursor.pos.y < lo) cursor.pos.y = lo;
    if (cursor.pos.y > hi) cursor.pos.y = hi;
    sel.cursor = cursor.pos;
}

/// PURE mouse state machine — PRD §7.6 / tmux copy-mode-mouse parity. Mutates cursor / sel /
/// mouse_anchor via explicit pointers (testable WITHOUT a RegionCtx/Screen/Terminal). `cell` is the
/// 0-based grid cell from mouseCell (S1). grid_rows/total_rows/tty_cols come from RegionCtx in the
/// real wiring (P1.M2.T2.S1).
///
///   press    — move cursor to cell + scrollForCursor; sel.clear() (a fresh click discards any prior
///               selection); sel.cursor = cursor.pos; mouse_anchor = cell (remember press start).
///   motion   — drag if mouse_anchor is set: want_mode = m.alt ? .block : .linewise (§7.6 "block with
///               Alt"); begin(at the press anchor) if the sel is inactive, else switch the mode live if
///               it differs (mid-drag Alt toggle); move cursor + extend sel.cursor. else (a hover with
///               no prior press): just move cursor + scrollForCursor.
///   release  — if mouse_anchor is set: move cursor + sync sel.cursor; clear mouse_anchor; if the
///               selection collapsed to one cell (anchor == cursor => a click, no drag) sel.clear(),
///               so a plain click leaves NO selection (Enter after a click => "no selection").
///   wheel_*  — halfPageUp / halfPageDown; then clampCursorIntoViewport (keep the cursor visible).
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

**Edit 2 — the 8 unit tests.** Append at the bottom of `src/region.zig` (after S1's last mouseCell test,
line 1205), alongside the other pure-helper tests. Test grid is constant: `tty_cols=80, grid_rows=10,
total_rows=50, viewport{.cols=80,.rows=10,.scroll=0}` (unless noted). mouseCell(scroll=0): SGR `(sx,sy)` →
cell `(sx-1, sy-1)`.

```zig
// ---- applyMouse / clampCursorIntoViewport tests (stack cursor/sel/anchor; NO Terminal ⇒ safe) ----

test "applyMouse: press moves cursor, clears any prior selection, sets mouse_anchor" {
    var cursor = motion.Cursor{ .pos = .{ .x = 0, .y = 9 }, .viewport = .{ .cols = 80, .rows = 10, .scroll = 0 } };
    var sel = select.Sel{ .anchor = .{ .x = 1, .y = 1 }, .cursor = .{ .x = 2, .y = 2 }, .mode = .linewise };
    var anchor: ?view.Pos = null;
    applyMouse(&cursor, &sel, &anchor, .{ .button = .left, .action = .press, .x = 5, .y = 3, .shift = false, .alt = false, .ctrl = false }, 10, 50, 80);
    try std.testing.expectEqual(view.Pos{ .x = 4, .y = 2 }, cursor.pos); // mouseCell(5,3,0)
    try std.testing.expect(!sel.active()); // prior selection cleared
    try std.testing.expectEqual(view.Pos{ .x = 4, .y = 2 }, sel.cursor);
    try std.testing.expectEqual(@as(?view.Pos, .{ .x = 4, .y = 2 }), anchor); // anchor = press cell
}

test "applyMouse: drag (motion after press) begins linewise at anchor; extent anchor..cursor" {
    var cursor = motion.Cursor{ .pos = .{ .x = 0, .y = 0 }, .viewport = .{ .cols = 80, .rows = 10, .scroll = 0 } };
    var sel = select.Sel{};
    var anchor: ?view.Pos = null;
    applyMouse(&cursor, &sel, &anchor, .{ .button = .left, .action = .press, .x = 3, .y = 2, .shift = false, .alt = false, .ctrl = false }, 10, 50, 80);
    applyMouse(&cursor, &sel, &anchor, .{ .button = .left, .action = .motion, .x = 8, .y = 6, .shift = false, .alt = false, .ctrl = false }, 10, 50, 80);
    try std.testing.expectEqual(select.Mode.linewise, sel.mode);
    try std.testing.expect(sel.active());
    try std.testing.expectEqual(view.Pos{ .x = 2, .y = 1 }, sel.anchor); // press cell mouseCell(3,2,0)
    try std.testing.expectEqual(view.Pos{ .x = 7, .y = 5 }, sel.cursor); // drag cell mouseCell(8,6,0)
    const ext = sel.extent(80).?;
    try std.testing.expectEqual(@as(u32, 1), ext.y1); // min(1,5)
    try std.testing.expectEqual(@as(u32, 5), ext.y2); // max(1,5)
    try std.testing.expectEqual(false, ext.rect);
}

test "applyMouse: drag with alt => block selection (rect)" {
    var cursor = motion.Cursor{ .pos = .{ .x = 0, .y = 0 }, .viewport = .{ .cols = 80, .rows = 10, .scroll = 0 } };
    var sel = select.Sel{};
    var anchor: ?view.Pos = null;
    applyMouse(&cursor, &sel, &anchor, .{ .button = .left, .action = .press, .x = 3, .y = 2, .shift = false, .alt = false, .ctrl = false }, 10, 50, 80);
    applyMouse(&cursor, &sel, &anchor, .{ .button = .left, .action = .motion, .x = 8, .y = 6, .shift = false, .alt = true, .ctrl = false }, 10, 50, 80);
    try std.testing.expectEqual(select.Mode.block, sel.mode);
    const ext = sel.extent(80).?;
    try std.testing.expectEqual(true, ext.rect);
    try std.testing.expectEqual(@as(u32, 2), ext.x1); // min(2,7)
    try std.testing.expectEqual(@as(u32, 7), ext.x2); // max(2,7)
}

test "applyMouse: toggling alt mid-drag switches linewise<->block (anchor preserved)" {
    var cursor = motion.Cursor{ .pos = .{ .x = 0, .y = 0 }, .viewport = .{ .cols = 80, .rows = 10, .scroll = 0 } };
    var sel = select.Sel{};
    var anchor: ?view.Pos = null;
    applyMouse(&cursor, &sel, &anchor, .{ .button = .left, .action = .press, .x = 3, .y = 2, .shift = false, .alt = false, .ctrl = false }, 10, 50, 80);
    applyMouse(&cursor, &sel, &anchor, .{ .button = .left, .action = .motion, .x = 8, .y = 6, .shift = false, .alt = false, .ctrl = false }, 10, 50, 80);
    try std.testing.expectEqual(select.Mode.linewise, sel.mode);
    // continue the drag WITH alt => switches to block
    applyMouse(&cursor, &sel, &anchor, .{ .button = .left, .action = .motion, .x = 9, .y = 7, .shift = false, .alt = true, .ctrl = false }, 10, 50, 80);
    try std.testing.expectEqual(select.Mode.block, sel.mode);
    try std.testing.expectEqual(view.Pos{ .x = 2, .y = 1 }, sel.anchor); // anchor still the press cell
}

test "applyMouse: release after a drag keeps the selection (anchor..release-cell)" {
    var cursor = motion.Cursor{ .pos = .{ .x = 0, .y = 0 }, .viewport = .{ .cols = 80, .rows = 10, .scroll = 0 } };
    var sel = select.Sel{};
    var anchor: ?view.Pos = null;
    applyMouse(&cursor, &sel, &anchor, .{ .button = .left, .action = .press, .x = 3, .y = 2, .shift = false, .alt = false, .ctrl = false }, 10, 50, 80);
    applyMouse(&cursor, &sel, &anchor, .{ .button = .left, .action = .motion, .x = 8, .y = 6, .shift = false, .alt = false, .ctrl = false }, 10, 50, 80);
    applyMouse(&cursor, &sel, &anchor, .{ .button = .left, .action = .release, .x = 9, .y = 7, .shift = false, .alt = false, .ctrl = false }, 10, 50, 80);
    try std.testing.expect(sel.active()); // selection kept
    try std.testing.expectEqual(view.Pos{ .x = 2, .y = 1 }, sel.anchor); // press cell
    try std.testing.expectEqual(view.Pos{ .x = 8, .y = 6 }, sel.cursor); // release cell mouseCell(9,7,0)
    try std.testing.expectEqual(@as(?view.Pos, null), anchor); // anchor cleared on release
}

test "applyMouse: a plain click (press then release, no drag) leaves NO selection" {
    var cursor = motion.Cursor{ .pos = .{ .x = 0, .y = 0 }, .viewport = .{ .cols = 80, .rows = 10, .scroll = 0 } };
    var sel = select.Sel{};
    var anchor: ?view.Pos = null;
    applyMouse(&cursor, &sel, &anchor, .{ .button = .left, .action = .press, .x = 5, .y = 3, .shift = false, .alt = false, .ctrl = false }, 10, 50, 80);
    // release at the SAME cell (no motion in between) => a click, not a drag
    applyMouse(&cursor, &sel, &anchor, .{ .button = .left, .action = .release, .x = 5, .y = 3, .shift = false, .alt = false, .ctrl = false }, 10, 50, 80);
    try std.testing.expect(!sel.active()); // no selection after a click
    try std.testing.expectEqual(@as(?view.Pos, null), anchor);
    try std.testing.expectEqual(view.Pos{ .x = 4, .y = 2 }, cursor.pos); // cursor did move to the cell
}

test "applyMouse: wheel_up/wheel_down scroll by half a page and clamp the cursor into view" {
    // 50-row grid, 10-row viewport, scroll=20 (max scroll = 40), cursor at grid row 25 (in view).
    var cursor = motion.Cursor{ .pos = .{ .x = 0, .y = 25 }, .viewport = .{ .cols = 80, .rows = 10, .scroll = 20 } };
    var sel = select.Sel{};
    var anchor: ?view.Pos = null;
    // wheel_up: half=5; scroll=max(0,20-5)=15; clamp window [15, min(49,15+9)=24] => cursor 25->24.
    applyMouse(&cursor, &sel, &anchor, .{ .button = .none, .action = .wheel_up, .x = 1, .y = 1, .shift = false, .alt = false, .ctrl = false }, 10, 50, 80);
    try std.testing.expectEqual(@as(u32, 15), cursor.viewport.scroll);
    try std.testing.expectEqual(@as(u32, 24), cursor.pos.y); // clamped into view
    try std.testing.expectEqual(cursor.pos, sel.cursor); // clamp synced sel.cursor
    // wheel_down: half=5; scroll=15+5=20; clamp window [20, min(49,20+9)=29] => cursor 24 stays.
    applyMouse(&cursor, &sel, &anchor, .{ .button = .none, .action = .wheel_down, .x = 1, .y = 1, .shift = false, .alt = false, .ctrl = false }, 10, 50, 80);
    try std.testing.expectEqual(@as(u32, 20), cursor.viewport.scroll);
    try std.testing.expectEqual(@as(u32, 24), cursor.pos.y);
}

test "applyMouse: motion with no prior press (hover) just moves the cursor" {
    var cursor = motion.Cursor{ .pos = .{ .x = 0, .y = 0 }, .viewport = .{ .cols = 80, .rows = 10, .scroll = 0 } };
    var sel = select.Sel{};
    var anchor: ?view.Pos = null; // no press => drag not active
    applyMouse(&cursor, &sel, &anchor, .{ .button = .none, .action = .motion, .x = 6, .y = 4, .shift = false, .alt = false, .ctrl = false }, 10, 50, 80);
    try std.testing.expectEqual(view.Pos{ .x = 5, .y = 3 }, cursor.pos); // mouseCell(6,4,0)
    try std.testing.expect(!sel.active()); // a hover never begins a selection
    try std.testing.expectEqual(@as(?view.Pos, null), anchor);
}
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: ADD fn clampCursorIntoViewport + fn applyMouse + doc-comments (src/region.zig, after mouseCell)
  - ADD the labeled section comment + the two doc-comments + the two fn bodies verbatim (Edit 1 above).
  - SIGNATURES (module-private `fn`, NOT `pub fn`):
      fn clampCursorIntoViewport(cursor: *motion.Cursor, sel: *select.Sel, total_rows: u32, grid_rows: u16) void
      fn applyMouse(cursor: *motion.Cursor, sel: *select.Sel, mouse_anchor: *?view.Pos, m: app.MouseEvent,
                    grid_rows: u16, total_rows: u32, tty_cols: u16) void
  - CALLS: mouseCell (S1, in scope); view.scrollForCursor/halfPageUp/halfPageDown (in scope via the `view`
           import); sel.clear/begin/active (in scope via `select`); std.meta.eql (std imported).
  - GOTCHA 2: keep the param order EXACTLY as above (the two fns differ in grid_rows/total_rows order).
  - GOTCHA 3: set cursor.pos/viewport.scroll directly (do NOT route through motion.applyMotion).
  - GOTCHA 4: saturating -|/+| + total_rows>=1 guard in clampCursorIntoViewport.
  - ANCHOR: insert immediately AFTER mouseCell's closing `}` (line ~133), BEFORE the regionHandle
            separator (line 135). Additive; no existing code touched.

Task 2: ADD 8 unit tests (src/region.zig, after the last mouseCell test at line 1205)
  - ADD the 8 test fns verbatim (Edit 2 above). Separate fns (Gotcha 8); std.testing.expectEqual.
  - GOTCHA 1: every app.MouseEvent literal sets ALL 7 fields incl. `button` (.left for press/motion/release;
              .none for wheel/hover).
  - COVERAGE: press/clear+anchor; linewise drag extent; Alt⇒block; mid-drag Alt toggle; release-after-drag
              keeps; plain-click clears; wheel up/down half-page+clamp; hover motion.
  - NO Terminal constructed => safe as standalone test fns (matches S1's mouseCell tests + the ~20 helpers).

Task 3: VALIDATE  (see Validation Loop)
  - RUN: zig build test --release=fast      # 8 new + S1's 6 mouseCell + ~20 existing region tests pass
```

### Implementation Patterns & Key Details

```zig
// PATTERN: pure pointer-mutating state machine (testable with stack value structs).
//   applyMouse takes *motion.Cursor / *select.Sel / *?view.Pos so a test passes &cursor/&sel/&anchor.
//   It computes the grid cell ONCE (mouseCell, S1), then switches on m.action. The drag branch keys off
//   mouse_anchor.* (set on press, cleared on release) — NOT m.button — so it is robust to SGR button bits.
fn applyMouse(cursor: *motion.Cursor, sel: *select.Sel, mouse_anchor: *?view.Pos, m: app.MouseEvent,
    grid_rows: u16, total_rows: u32, tty_cols: u16) void {
    const cell = mouseCell(m.x, m.y, cursor.viewport.scroll, grid_rows, total_rows, tty_cols);
    switch (m.action) {
        .press => { cursor.pos = cell; cursor.viewport.scroll = view.scrollForCursor(...); sel.clear();
                    sel.cursor = cursor.pos; mouse_anchor.* = cell; },
        .motion => if (mouse_anchor.*) |anchor| {
                       const want: select.Mode = if (m.alt) .block else .linewise;
                       if (!sel.active()) sel.begin(anchor, want) else if (sel.mode != want) sel.mode = want;
                       cursor.pos = cell; cursor.viewport.scroll = view.scrollForCursor(...); sel.cursor = cursor.pos;
                   } else { cursor.pos = cell; cursor.viewport.scroll = view.scrollForCursor(...); },
        .release => if (mouse_anchor.*) |_| {
                        cursor.pos = cell; cursor.viewport.scroll = view.scrollForCursor(...);
                        sel.cursor = cursor.pos; mouse_anchor.* = null;
                        if (sel.active() and std.meta.eql(sel.anchor, cursor.pos)) sel.clear();
                    },
        .wheel_up => { cursor.viewport.scroll = view.halfPageUp(...); clampCursorIntoViewport(...); },
        .wheel_down => { cursor.viewport.scroll = view.halfPageDown(...); clampCursorIntoViewport(...); },
    }
}

// PATTERN: clamp into the visible window after a scroll (mirrors motion.zig page/half-page clamps).
fn clampCursorIntoViewport(cursor, sel, total_rows, grid_rows) void {
    const lo = cursor.viewport.scroll;
    const last = if (total_rows >= 1) total_rows - 1 else 0;
    const hi = @min(last, cursor.viewport.scroll +| (@as(u32, grid_rows) -| 1));
    if (cursor.pos.y < lo) cursor.pos.y = lo;
    if (cursor.pos.y > hi) cursor.pos.y = hi;
    sel.cursor = cursor.pos;
}

// PATTERN: a test MouseEvent literal — ALL 7 fields, incl. `button`.
const m = app.MouseEvent{ .button = .left, .action = .press, .x = 5, .y = 3,
                          .shift = false, .alt = false, .ctrl = false };
```

### Integration Points

```yaml
BUILD GRAPH:
  - consumes (unchanged): build.zig, build.zig.zon, all src/*.zig. region.zig already imports std/app/
    view/motion/select. mouseCell (S1) is already on disk at line 127.
  - produces: src/region.zig with +applyMouse() +clampCursorIntoViewport() + 8 tests.
  - next (P1.M2.T2.S1): adds RegionCtx.mouse_anchor: ?view.Pos + the .mouse arm in regionHandle:
        .mouse => |m| { applyMouse(&ctx.cursor, &ctx.sel, &ctx.mouse_anchor, m,
                                   ctx.grid_rows, ctx.total_rows, ctx.tty_cols);
                        repaint(ctx) catch {}; return .none; }
    + rewrites regionHandle's "Mouse is a NO-OP" doc-comment. NOT this task.
  - next (P1.M2.T3.S1): tests/region_mouse.sh — the pty integration harness asserting SGR click/drag/wheel.
    NOT this task (pure unit coverage lives here; the pty harness is layered on top).

TUI/RENDER CONTRACT (DO NOT CHANGE):
  - mouseCell (S1) is the exact inverse of view.render's screen->grid mapping (gy=scroll+vy; CUP vy+1/col1).
    applyMouse feeds it m.x/m.y; it never re-derives coordinates.
  - grid_rows passed to applyMouse/clampCursorIntoViewport == RegionCtx.grid_rows (== tty_rows-1) ==
    viewport.rows. In tests grid_rows == viewport.rows (both 10) so they stay consistent.
```

## Validation Loop

> Re-run verbatim. EVERY build/test command MUST include `--release=fast` (Gotcha 9).

### Level 1: Syntax & Style (Immediate Feedback)

```bash
zig version            # MUST print: 0.15.2
zig build --fetch      # exit 0 (deps cached)
```

### Level 2: Unit tests (PRIMARY gate — the 8 new tests + S1's 6 + the ~20 existing)

```bash
# All region tests (8 new applyMouse/clamp + S1's 6 mouseCell + ~20 existing pure-helper) + whole suite.
zig build test --release=fast          # expect: all passed, exit 0

# Diagnostics:
#   "unhandled relocation type R_X86_64_PC64" -> forgot --release=fast (Gotcha 9).
#   "missing struct field" / "expected 7 fields" on a MouseEvent literal -> forgot `button` (Gotcha 1).
#   "expected ... found ..." type error -> a param order mismatch (Gotcha 2) or passing grid_rows where
#     total_rows is expected. Re-check: applyMouse=(grid_rows,total_rows,tty_cols); clamp=(total_rows,grid_rows).
#   integer overflow/panic in a wheel test -> a non-saturating `-`/`+` in clampCursorIntoViewport (Gotcha 4).
#   wrong selection kept/cleared -> re-check release's `std.meta.eql(sel.anchor, cursor.pos)` (Gotcha 7).
```

### Level 3: Behavior (the contract — the 8 cases ARE the gate)

```bash
# The 8 unit tests assert exactly (reasoned from the verified APIs in research/findings.md §3):
#   press SGR(5,3)              -> cursor=(4,2); sel inactive; anchor=(4,2)
#   press(3,2)->motion(8,6)     -> linewise; anchor=(2,1) cursor=(7,5); extent y1=1 y2=5 rect=false
#   press(3,2)->motion alt(8,6) -> block; extent rect=true x1=2 x2=7
#   press->motion->motion alt   -> linewise then block; anchor preserved
#   press->motion->release(9,7) -> active kept; anchor=(2,1) cursor=(8,6); anchor==null
#   press(5,3)->release(5,3)    -> NOT active; anchor==null; cursor=(4,2)
#   wheel_up (scroll20->15)     -> scroll=15 cursor.y=24; sel.cursor synced
#   wheel_down(scroll15->20)    -> scroll=20 cursor.y=24
#   motion(6,4) no press        -> cursor=(5,3); not active; anchor==null
zig build test --release=fast -- 2>&1 | grep applyMouse   # confirm the 8 test names appear + pass
```

### Level 4: Scope boundary

```bash
# ONLY src/region.zig changed; nothing else touched.
git diff --stat | grep -v 'src/region.zig' && echo "UNEXPECTED other changes" || echo "scope OK"
# Both fns are module-private (NOT pub) and take explicit pointers:
grep -n 'fn applyMouse\|fn clampCursorIntoViewport' src/region.zig   # expect: no 'pub' prefix
# No .mouse arm / RegionCtx.mouse_anchor / regionHandle rewrite added (those are P1.M2.T2.S1):
grep -cE 'mouse_anchor:|\.mouse =>' src/region.zig    # expect: 0
# regionHandle's "Mouse is a NO-OP" doc-comment is UNCHANGED (still present — P1.M2.T2.S1 rewrites it):
grep -n 'Mouse is a NO-OP' src/region.zig            # expect: 1 hit (the untouched comment)
```

## Final Validation Checklist

### Technical Validation

- [ ] `zig version` prints `0.15.2`; `zig build --fetch` exits 0.
- [ ] `zig build test --release=fast` exits 0 (8 new + S1's 6 mouseCell + ~20 existing region tests + whole suite).

### Feature Validation

- [ ] press ⇒ cursor moves to the cell + `sel.clear()` + `mouse_anchor = cell` (a fresh click discards prior).
- [ ] linewise drag ⇒ `sel.begin(anchor)` at the press cell, extends to the cursor; `extent()` rows anchor..cursor, rect=false.
- [ ] Alt-drag ⇒ block (`extent()` rect=true); toggling Alt mid-drag switches mode live (anchor preserved).
- [ ] release after a drag keeps the selection (anchor=press cell, cursor=release cell); plain click clears (no drag ⇒ no selection).
- [ ] wheel up/down ⇒ `viewport.scroll = halfPageUp/Down`; cursor clamped into `[scroll, min(total-1, scroll+grid_rows-1)]`; `sel.cursor` synced.
- [ ] hover motion (no prior press) ⇒ just moves the cursor (no selection begun).

### Code Quality Validation

- [ ] `applyMouse`/`clampCursorIntoViewport` are module-private (`fn`, not `pub fn`); take explicit pointers.
- [ ] Param order matches the contract (Gotcha 2); clampCursorIntoViewport uses saturating `-|`/`+|` + `total_rows>=1` (Gotcha 4).
- [ ] applyMouse sets `cursor.pos`/`viewport.scroll` directly (NOT via motion.applyMotion) (Gotcha 3); `sel.cursor` written directly (Gotcha 5).
- [ ] 8 separate `test` fns (Gotcha 8); every MouseEvent literal sets all 7 fields incl. `button` (Gotcha 1).
- [ ] ONLY `src/region.zig` changed; `regionHandle`/`RegionCtx`/`view.zig`/`app.zig`/`mouseCell` UNCHANGED.

### Documentation & Deployment

- [ ] Mode-A doc-comments on `applyMouse` (the §7.6 click/drag/Alt-block/wheel state machine) + `clampCursorIntoViewport`.
- [ ] No user-facing / config / CLI surface change (internal primitives; mouse becomes user-visible only in P1.M2.T2.S1).

---

## Anti-Patterns to Avoid

- ❌ Don't omit the `button` field in a test `MouseEvent` literal — Zig has no partial init; all 7 fields are
  required (Gotcha 1). Use `.left` for press/motion/release, `.none` for wheel/hover.
- ❌ Don't swap the param order. `applyMouse` ends `(grid_rows, total_rows, tty_cols)`; `clampCursorIntoViewport`
  is `(total_rows, grid_rows)` — they DIFFER (Gotcha 2). The signatures are pinned by the item contract.
- ❌ Don't route applyMouse through `motion.applyMotion` or build a `motion.Grid` — that would require a
  SliceGrid/Terminal and break pure testability. Set `cursor.pos`/`cursor.viewport.scroll` directly and call
  `view.scrollForCursor` (Gotcha 3), exactly like motion.zig's `.down`/`.up`/`$`/`G` do internally.
- ❌ Don't call `sel.begin()` on every motion event — begin RESETS anchor=cursor=pos and would lose the drag
  anchor. Call it ONCE when the drag starts (inactive sel); thereafter write `sel.cursor` directly (Gotcha 5).
- ❌ Don't use `sel.toggle()` for the mid-drag Alt switch — set `sel.mode = want_mode` directly. `want_mode` is
  computed from `m.alt`, so a direct assignment is exact; `toggle` would flip blindly (Gotcha 6).
- ❌ Don't clear the selection unconditionally on release, and don't compare `mouse_anchor` (it's just been
  nulled). Clear only if `sel.active() and std.meta.eql(sel.anchor, cursor.pos)` — a collapsed single-cell sel
  (Gotcha 7). A pure click is already inactive (never begun), so it leaves no selection either way.
- ❌ Don't use plain `-`/`+` in `clampCursorIntoViewport` — `grid_rows` is u16 and can be 0; `total_rows` can be
  0. Use `(@as(u32, grid_rows) -| 1)`, `scroll +| …`, and guard `total_rows >= 1` (Gotcha 4).
- ❌ Don't bundle the 8 tests into one `test` fn, and don't fear the cross-test GOTCHA — `applyMouse` constructs
  no Terminal, so separate fns are safe (Gotcha 8), matching the ~26 existing region pure-helper tests.
- ❌ Don't add the `.mouse` arm / `RegionCtx.mouse_anchor` / rewrite `regionHandle` — that is P1.M2.T2.S1. S2 is
  purely additive: 2 fns + 8 tests (Gotcha 10). Don't touch `mouseCell` (S1, merged) or any other src file.
- ❌ Don't build/test WITHOUT `--release=fast` — Debug linking hits `R_X86_64_PC64` (Gotcha 9).

---

**Confidence Score: 9/10** for one-pass implementation success.

Every consumed API (`motion.Cursor{pos,viewport}`; `select.Sel`/`Mode`/`begin`/`clear`/`active`/`extent`;
`view.scrollForCursor`/`halfPageUp`/`halfPageDown`/`clampScroll` + `Viewport`/`Pos`/`Selection`;
`app.MouseEvent`/`MouseButton`/`MouseAction`) is verified line-by-line against the on-disk source, and S1's
`mouseCell` is already merged at `src/region.zig:127`. The two fn bodies follow motion.zig's verified
`scrollForCursor` + page/half-page clamp patterns and S1's saturating-arithmetic discipline; the 8 test
assertions are derived from the verified `clampScroll`/`halfPage*` math and the mouseCell conversion. The
task is purely additive (no existing code path calls `applyMouse` yet → nothing can regress until
P1.M2.T2.S1 wires it in), module-private, and takes explicit pointers so it needs no `Terminal`/`RegionCtx`
to test. The residual 1/10 risk is that the bodies are reasoned (not run-verified — I cannot modify src as a
research agent); the main things to get right on first pass are the `button` field in test literals (Gotcha 1)
and the differing param order (Gotcha 2), both called out explicitly with diagnostics.