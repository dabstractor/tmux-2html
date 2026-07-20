# PRP — P1.M2.T1.S1: Pure `mouseCell()` SGR→grid coordinate conversion + unit tests

## Goal

**Feature Goal**: Add the first pure building block of the mouse-wiring fix (Issue 1 / PRD §7.6):
a module-private, allocation-free, I/O-free `mouseCell()` in `src/region.zig` that converts a
1-based SGR mouse position on the popup screen into a 0-based grid cell, honoring the viewport
scroll offset and excluding the status-line row — with saturating arithmetic so the degenerate
0-row / 0-col / 0-total cases never underflow. This is the pure coordinate primitive that
`applyMouse` (P1.M2.T1.S2) consumes; it is fully unit-testable without a `Terminal`.

**Deliverable**: ONE file changed (`/home/dustin/projects/tmux-2html/src/region.zig`) — purely
additive:
- 1 new module-private `fn mouseCell(...)` + its Mode-A doc-comment.
- 6 new `test` fns (plain click, status-line clamp, scroll offset, gx clamp, gy clamp, degenerate no-underflow).
- No new files; NO changes to `regionHandle`, `RegionCtx`, `view.zig`, `app.zig`, `input.zig`,
  `motion.zig`, or `select.zig` (those are S2 / P1.M2.T2.S1).

**Success Definition** (the `mouseCell` body + all 6 tests were **compile- and run-verified**
standalone under Zig 0.15.2 — 6/6 passed):
- `zig build test --release=fast` → exit 0; the 6 new tests pass alongside the existing 20 region tests.
- A plain 1-based click `(sx,sy)` with `scroll=0` ⇒ `.x = sx-1`, `.y = sy-1`; with `scroll=N` ⇒ `.y = N + (sy-1)`.
- A click on the status-line row (`sy-1 ≥ grid_rows`) clamps `.y` to `grid_rows-1`; an
  over-range column clamps `.x` to `tty_cols-1`; an over-scroll `gy` clamps to `total_rows-1`.
- `mouseCell(_, _, _, 0, 0, 0)` and `(_, _, _, 0, _, 0)` return `{0,…}` with NO u32 underflow.

## User Persona

**Target User**: The implementer of **P1.M2.T1.S2 (`applyMouse`)** and **P1.M2.T2.S1 (the
`.mouse` arm + `RegionCtx.mouse_anchor`)** — they call `mouseCell` to turn each decoded
`app.MouseEvent` into a grid cell before mutating the cursor/selection. (End users never call
this directly; they get working §7.6 mouse once the later tasks wire it in.)

**Use Case**: `applyMouse` receives `app.MouseEvent{ .x, .y, … }` (1-based SGR cells), calls
`mouseCell(ev.x, ev.y, ctx.cursor.viewport.scroll, ctx.grid_rows, ctx.total_rows, ctx.tty_cols)`,
and uses the returned 0-based `view.Pos` to move the cursor / extend the selection / etc.

**Pain Points Addressed**: Isolates the tricky 1-based→0-based + scroll-offset + status-line-
exclusion + saturating-clamp math in ONE pure, unit-tested primitive so the state-machine
task (S2) is simpler and the coordinate logic is provably correct independent of any Terminal.

## Why

- **Foundation of the Issue 1 fix (PRD §7.6).** Mouse is decoded but discarded today
  (`regionHandle` has no `.mouse` arm). The fix is layered: S1 = pure coordinate conversion
  (this task), S2 = pure state machine (`applyMouse`), P1.M2.T2.S1 = the wiring + anchor field.
  Splitting the coordinate math out makes it independently verifiable — the most error-prone
  part (off-by-one, scroll, status-line row, underflow) is locked down by 6 deterministic tests.
- **Matches `view.render`'s mapping exactly** (verified at `src/tui/view.zig:149`: `gy = scroll +
  vy`; CUP to `vy+1`; col 1 = gx 0). `mouseCell` is the precise inverse of that paint loop.
- **Zero risk to existing behavior.** Purely additive (one new fn + tests); no existing code
  path calls `mouseCell` yet, so nothing can regress until S2 wires it in.

## What

Add to `src/region.zig`, in a new "Mouse wiring (PRD §7.6)" section immediately before
`regionHandle` (line 138):

```zig
/// PURE: convert a 1-based SGR mouse position (sx, sy) on the popup screen to a 0-based GRID
/// cell (origin top-left), honoring the viewport `scroll` offset and excluding the status-line
/// row. gx = sx-1 (screen col 1 = grid col 0); vy = sy-1 clamped to [0, grid_rows-1] (the grid
/// area — the status line at viewport row `grid_rows` is excluded); gy = scroll + vy clamped to
/// [0, total_rows-1]. All arithmetic is SATURATING (`-|`, `+|`) and the total_rows==0 / 0-row /
/// 0-col degenerate cases are guarded, so there is NO u32 underflow.
/// Validated against view.render's mapping (gy = scroll + vy; CUP to vy+1; col 1 = gx 0).
/// Consumed by applyMouse (P1.M2.T1.S2); no I/O, no Terminal — fully unit-testable.
fn mouseCell(sx: u32, sy: u32, scroll: u32, grid_rows: u16, total_rows: u32, tty_cols: u16) view.Pos {
    const gx: u32 = @min(if (sx >= 1) sx - 1 else 0, (@as(u32, tty_cols) -| 1));
    const vy: u32 = @min(if (sy >= 1) sy - 1 else 0, (@as(u32, grid_rows) -| 1));
    const gy: u32 = @min(scroll +| vy, (if (total_rows >= 1) total_rows - 1 else 0));
    return .{ .x = gx, .y = gy };
}
```

And add 6 `test` fns at the bottom of the file (alongside the other 20 pure-helper tests),
exactly as below (these are the compile/run-verified cases).

### Success Criteria

- [ ] `fn mouseCell(sx: u32, sy: u32, scroll: u32, grid_rows: u16, total_rows: u32, tty_cols: u16) view.Pos`
      added as a module-private fn in `src/region.zig` (the exact body above, with its doc-comment).
- [ ] 6 new `test` fns pass (plain click, status-line clamp, scroll offset, gx clamp, gy clamp, degenerate).
- [ ] `zig build test --release=fast` → exit 0 (6 new + 20 existing region tests; whole suite green).
- [ ] ONLY `src/region.zig` changed; `regionHandle`/`RegionCtx`/`view.zig`/`app.zig` UNCHANGED.
- [ ] No `applyMouse`/`clampCursorIntoViewport`/`.mouse` arm added (those are S2 / P1.M2.T2.S1).

## All Needed Context

### Context Completeness Check

_Pass: "If someone knew nothing about this codebase, would they have everything needed to
implement this successfully?"_ — Yes. The verbatim `mouseCell` body + doc-comment + 6 test fns
are specified (and were compile-/run-verified standalone under Zig 0.15.2, 6/6 passed). The
types (`view.Pos`, the `RegionCtx` field names mouseCell's caller passes), the exact
screen→grid mapping (verified against `view.render:149`), the saturating-arithmetic rationale,
the placement (before `regionHandle`), and the scope boundary (S1 = ONLY mouseCell + tests;
no `applyMouse`/wiring) are all documented with line citations in `research/findings.md`. The
implementer is copying a verified fn + 6 verified tests into one file.

### Documentation & References

```yaml
# MUST READ — the design + the verified implementation + the 6 run-checked test cases
- file: plan/004_92f7aeb62a3a/bugfix/002_b76ad57f9c71/P1M2T1S1/research/findings.md
  why: "§1 the input types (app.MouseEvent 1-based x/y; view.Pos 0-based {x,y}); §2 the render
        mapping PROOF (gy=scroll+vy; CUP vy+1/col1) at view.zig:149; §3 RegionCtx field names
        (tty_cols/grid_rows:u16, total_rows:u32) the caller passes; §4 the safe separate-test
        pattern (20 existing pure-helper tests, no Terminal => no cross-test GOTCHA); §5 the
        verbatim mouseCell + the 6/6 run-verified test table; §6 placement + scope."
  critical: "mouseCell is module-private (`fn`, NOT `pub fn`) and takes raw u32 coords (NOT an
             app.MouseEvent) so it is testable without constructing a MouseEvent. It is PURE
             (no Terminal) => safe as standalone test fns (unlike renderGrid scopes)."

# MUST READ — the design this task implements (Issue 1 / §7.6)
- file: plan/004_92f7aeb62a3a/bugfix/002_b76ad57f9c71/architecture/mouse_wiring_design.md
  section: "'Coordinate conversion — mouseCell' + 'Non-goals / explicit decisions'"
  why: "The authoritative design. mouseCell is quoted verbatim; S2 (applyMouse) and P1.M2.T2.S1
        (the .mouse arm + mouse_anchor) are explicitly NOT this task."

# MUST READ — the file being edited + the types/consumers
- file: src/region.zig
  section: "imports (app:42, view:43, motion:45, select:46); RegionCtx fields (tty_cols:92,
            grid_rows:94, total_rows:95); regionHandle (138); the 20 pure-helper test fns (792-1147)."
  why: "Confirms region.zig already imports view/app, the RegionCtx field names/types mouseCell's
        caller uses, and that pure-helper standalone tests are the established pattern. mouseCell
        is PURE (no Terminal) so it follows that pattern — NOT the renderGrid cross-test GOTCHA."
- file: src/tui/view.zig
  section: "Pos (50: struct{x:u32,y:u32}); render loop (149: gy=scroll+vy; 151: CUP vy+1/col1)"
  why: "PROVES the screen->grid mapping mouseCell inverts. A 1-based click (sx,sy) => gx=sx-1,
        vy=sy-1, gy=scroll+vy; status line = screen row tty_rows = viewport row grid_rows."
- file: src/tui/app.zig
  section: "MouseEvent (259: x:u32, y:u32; doc 255 '1-based CHARACTER cells')"
  why: "The 1-based source coordinates mouseCell converts. mouseCell takes the raw ints (not the
        struct) for testability."

# PRD context (this is the §7.6 mouse fix, layered; S1 = the pure coord primitive)
- file: PRD.md
  section: "Major Issue 1 (Mouse support §7.6 non-functional) + §7.6 ('Click to move cursor;
            drag to select; wheel to scroll')"
  why: "Confirms mouse is a SUPPORTED feature (not §16 out-of-scope) and that the fix is layered:
        S1=coord conversion (here), S2=state machine, P1.M2.T2.S1=wiring."
```

### Current Codebase tree (this task's starting point)

```bash
tmux-2html/
├── src/
│   ├── region.zig        # 1147 lines; regionHandle(138); 20 pure-helper test fns(792-1147) ← ADD mouseCell + 6 tests
│   ├── tui/view.zig      # Pos{ x:u32, y:u32 }(50); render mapping gy=scroll+vy(149)        ← DO NOT TOUCH
│   ├── tui/app.zig       # MouseEvent{ x:u32, y:u32 }(259); 1-based(255)                    ← DO NOT TOUCH
│   ├── tui/{input,motion,select}.zig                                                    ← DO NOT TOUCH
│   └── …
├── build.zig  build.zig.zon                                                             ← DO NOT TOUCH
```

### Desired Codebase tree with files to be changed

```bash
tmux-2html/
└── src/
    └── region.zig        # +mouseCell() (module-private, before regionHandle) +6 test fns +doc-comment
```

### Known Gotchas of our codebase & Library Quirks

```zig
// GOTCHA 1 — CRITICAL: use SATURATING arithmetic. `tty_cols`/`grid_rows` are u16; subtracting 1
//   when they are 0 would underflow. The pattern `(@as(u32, tty_cols) -| 1)` saturates to 0.
//   `scroll +| vy` saturates the add. And `total_rows - 1` is guarded by `if (total_rows >= 1)
//   … else 0` (total_rows==0 must NOT underflow). These were verified to NOT panic in Debug.
//   Do NOT write plain `-`/`+` here.

// GOTCHA 2 — `view.Pos` fields are `x: u32, y: u32` (BOTH u32). `tty_cols`/`grid_rows` are u16;
//   widen them to u32 BEFORE the saturating subtract (`@as(u32, tty_cols) -| 1`), else the `-|`
//   stays in u16 and the @min compares u32 vs u16 (would need a cast anyway). The verified body
//   casts explicitly. `total_rows` and `scroll`/`vy` are already u32.

// GOTCHA 3 — mouseCell is module-PRIVATE (`fn mouseCell`, NOT `pub fn`). It is an internal helper
//   consumed only by applyMouse (S2) within region.zig. Making it pub would leak an impl detail.

// GOTCHA 4 — mouseCell takes raw u32 coords (sx, sy), NOT an `app.MouseEvent`. This keeps it
//   PURE/unit-testable without constructing a MouseEvent, and lets the caller (applyMouse) pass
//   `ev.x`/`ev.y`. Do NOT change the signature to take app.MouseEvent (the design + tests pin it).

// GOTCHA 5 — SAFE as standalone test fns: mouseCell constructs NO Terminal/Screen, so it does NOT
//   trigger the cross-test GOTCHA at render.zig:838 (that only affects Terminal.init scopes).
//   region.zig already has 20 standalone pure-helper test fns — mouseCell's 6 tests follow the
//   same pattern. Do NOT bundle them into one test; separate fns are idiomatic + greppable here.

// GOTCHA 6 — build/test MUST use --release=fast: Debug linking hits the ghostty R_X86_64_PC64
//   linker bug. `zig build test` (no release flag) FAILS. Always `zig build test --release=fast`.

// GOTCHA 7 — SCOPE: S1 adds ONLY mouseCell + its doc-comment + 6 tests. Do NOT add applyMouse /
//   clampCursorIntoViewport (S2), the .mouse arm in regionHandle, or RegionCtx.mouse_anchor
//   (P1.M2.T2.S1). Adding them now collides with those tasks. Purely additive: one new fn.
```

## Implementation Blueprint

### Data models and structure

No data models. `mouseCell` reuses the existing `view.Pos = struct { x: u32, y: u32 }` return
type and takes only primitive ints (`u32`/`u16`). It is a pure function (no allocation, no I/O,
no Terminal).

### The exact deliverable: `src/region.zig` (ADD — 1 fn + doc-comment + 6 tests)

**Edit 1 — the `mouseCell` fn + its doc-comment.** Insert in a new labeled section immediately
BEFORE the `regionHandle` doc-comment (the comment block above `fn regionHandle` at line 138):

```zig
// ---- Mouse wiring (PRD §7.6) -------------------------------------------------------------
// mouseCell (S1) is the pure 1-based-SGR -> 0-based-grid coordinate primitive consumed by
// applyMouse (S2). The .mouse arm in regionHandle + RegionCtx.mouse_anchor land in P1.M2.T2.S1.

/// PURE: convert a 1-based SGR mouse position (sx, sy) on the popup screen to a 0-based GRID
/// cell (origin top-left), honoring the viewport `scroll` offset and excluding the status-line
/// row. gx = sx-1 (screen col 1 = grid col 0); vy = sy-1 clamped to [0, grid_rows-1] (the grid
/// area — the status line at viewport row `grid_rows` is excluded); gy = scroll + vy clamped to
/// [0, total_rows-1]. All arithmetic is SATURATING (`-|`, `+|`) and the total_rows==0 / 0-row /
/// 0-col degenerate cases are guarded, so there is NO u32 underflow.
/// Validated against view.render's mapping (gy = scroll + vy; CUP to vy+1; col 1 = gx 0).
/// Consumed by applyMouse (P1.M2.T1.S2); no I/O, no Terminal — fully unit-testable.
fn mouseCell(sx: u32, sy: u32, scroll: u32, grid_rows: u16, total_rows: u32, tty_cols: u16) view.Pos {
    const gx: u32 = @min(if (sx >= 1) sx - 1 else 0, (@as(u32, tty_cols) -| 1));
    const vy: u32 = @min(if (sy >= 1) sy - 1 else 0, (@as(u32, grid_rows) -| 1));
    const gy: u32 = @min(scroll +| vy, (if (total_rows >= 1) total_rows - 1 else 0));
    return .{ .x = gx, .y = gy };
}
```

**Edit 2 — the 6 unit tests.** Append at the bottom of `src/region.zig` (after the last existing
test, alongside the other 20 pure-helper tests). These are the compile-/run-verified cases:

```zig
test "mouseCell: plain click maps sx-1 / sy-1 (scroll=0)" {
    const p = mouseCell(5, 3, 0, 10, 50, 80);
    try std.testing.expectEqual(@as(u32, 4), p.x); // gx = 5-1
    try std.testing.expectEqual(@as(u32, 2), p.y); // gy = scroll(0) + vy(3-1)
}

test "mouseCell: click on the status-line row clamps to the last grid row" {
    // sy=11 > grid_rows=10 => vy clamps to grid_rows-1=9 (status line at viewport row 10 excluded).
    const p = mouseCell(5, 11, 0, 10, 50, 80);
    try std.testing.expectEqual(@as(u32, 9), p.y);
    try std.testing.expectEqual(@as(u32, 4), p.x);
}

test "mouseCell: viewport scroll offset is applied (gy = scroll + vy)" {
    const p = mouseCell(5, 3, 20, 10, 50, 80); // vy=2, gy=20+2
    try std.testing.expectEqual(@as(u32, 22), p.y);
    try std.testing.expectEqual(@as(u32, 4), p.x);
}

test "mouseCell: gx clamps to tty_cols-1 for an over-range column" {
    const p = mouseCell(200, 1, 0, 10, 50, 80); // sx-1=199 clamps to 80-1
    try std.testing.expectEqual(@as(u32, 79), p.x);
}

test "mouseCell: gy clamps to total_rows-1 for an over-scroll position" {
    // vy at max grid row (9), no scroll => gy = 9 (well within total_rows=50).
    try std.testing.expectEqual(@as(u32, 9), mouseCell(1, 50, 0, 10, 50, 80).y);
    // scroll=100 past total_rows=50 => gy = min(100+0, 49) = 49.
    try std.testing.expectEqual(@as(u32, 49), mouseCell(1, 1, 100, 10, 50, 80).y);
}

test "mouseCell: degenerate grid_rows==0 / tty_cols==0 / total_rows==0 do NOT underflow" {
    const a = mouseCell(5, 3, 0, 0, 50, 0); // grid_rows=0 AND tty_cols=0
    try std.testing.expectEqual(@as(u32, 0), a.x); // min(4, 0-|0=0)
    try std.testing.expectEqual(@as(u32, 0), a.y); // vy=min(2, 0)=0; gy=min(0, 49)=0
    const b = mouseCell(5, 3, 0, 10, 0, 80); // total_rows=0
    try std.testing.expectEqual(@as(u32, 0), b.y); // gy = min(scroll+vy, 0) = 0
}
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: ADD fn mouseCell + doc-comment (src/region.zig, before regionHandle at line 138)
  - ADD the labeled section comment + the doc-comment + the fn body verbatim (Edit 1 above).
  - SIGNATURE: fn mouseCell(sx: u32, sy: u32, scroll: u32, grid_rows: u16, total_rows: u32, tty_cols: u16) view.Pos
  - MODULE-PRIVATE (fn, not pub fn). RETURNS view.Pos{ .x = gx, .y = gy }.
  - USE SATURATING arithmetic: (@as(u32, tty_cols) -| 1), (@as(u32, grid_rows) -| 1), scroll +| vy;
    guard total_rows>=1 before the -1. (Gotcha 1, 2.)
  - ANCHOR: insert immediately before the regionHandle doc-comment (line ~133-137). region.zig
            already imports `view` (line 43) => view.Pos is in scope. Additive; no existing code touched.

Task 2: ADD 6 unit tests (src/region.zig, after the last existing test ~line 1147)
  - ADD the 6 test fns verbatim (Edit 2 above). Separate fns (Gotcha 5), std.testing.expectEqual.
  - COVERAGE: plain click / status-line clamp / scroll offset / gx clamp / gy clamp / degenerate no-underflow.
  - NO Terminal constructed => safe as standalone test fns (matches the 20 existing pure-helper tests).

Task 3: VALIDATE  (see Validation Loop)
  - RUN: zig build test --release=fast      # 6 new + 20 existing region tests pass; whole suite green
```

### Implementation Patterns & Key Details

```zig
// PATTERN: pure coordinate primitive (1-based screen -> 0-based grid), saturating + clamped.
//   gx = sx-1 clamped to [0, tty_cols-1]; vy = sy-1 clamped to [0, grid_rows-1] (excludes the
//   status line); gy = scroll + vy clamped to [0, total_rows-1]. The `-|`/`+|` saturating ops
//   + the total_rows>=1 guard make the 0-dim degenerate cases safe (no u32 underflow).
fn mouseCell(sx: u32, sy: u32, scroll: u32, grid_rows: u16, total_rows: u32, tty_cols: u16) view.Pos {
    const gx: u32 = @min(if (sx >= 1) sx - 1 else 0, (@as(u32, tty_cols) -| 1));
    const vy: u32 = @min(if (sy >= 1) sy - 1 else 0, (@as(u32, grid_rows) -| 1));
    const gy: u32 = @min(scroll +| vy, (if (total_rows >= 1) total_rows - 1 else 0));
    return .{ .x = gx, .y = gy };
}

// PATTERN: standalone pure-helper test fns (region.zig has 20 of these; mouseCell has no Terminal
//   so it does NOT hit the render.zig:838 cross-test GOTCHA). Each test is one focused scenario.
test "mouseCell: plain click maps sx-1 / sy-1 (scroll=0)" {
    const p = mouseCell(5, 3, 0, 10, 50, 80);
    try std.testing.expectEqual(@as(u32, 4), p.x);
    try std.testing.expectEqual(@as(u32, 2), p.y);
}
```

### Integration Points

```yaml
BUILD GRAPH:
  - consumes (unchanged): build.zig, build.zig.zon, all src/*.zig. region.zig already imports view/app.
  - produces: src/region.zig with +mouseCell() + 6 tests.
  - next (P1.M2.T1.S2 applyMouse): calls mouseCell(ev.x, ev.y, cursor.viewport.scroll, grid_rows,
              total_rows, tty_cols) to get the grid cell, then mutates cursor/sel/mouse_anchor.
  - next (P1.M2.T2.S1): adds RegionCtx.mouse_anchor + the .mouse arm in regionHandle that calls applyMouse.
  - PARALLEL WORK (P1.M1.T2.S1): creates tests/region_signal_keys.sh (NEW file) — does NOT touch
              src/region.zig. No collision.

TUI/RENDER CONTRACT (DO NOT CHANGE — mouseCell must match it):
  - view.render (view.zig:149): gy = viewport.scroll + vy; CUP to screen row vy+1 (1-based), col 1.
    mouseCell is the exact inverse: 1-based (sx,sy) -> 0-based grid (gx=sx-1, gy=scroll+(sy-1)).
  - status line = the last tty row (screen row tty_rows = viewport row grid_rows); excluded by the
    vy clamp to grid_rows-1. (grid_rows = tty_rows -| 1, region.zig:358.)
```

## Validation Loop

> Re-run verbatim. EVERY build/test command MUST include `--release=fast` (Gotcha 6).

### Level 1: Syntax & Style (Immediate Feedback)

```bash
zig version            # MUST print: 0.15.2
zig build --fetch      # exit 0 (deps cached)
```

### Level 2: Unit tests (PRIMARY gate — the 6 new tests + the existing 20 region tests)

```bash
# All region tests (6 new mouseCell + 20 existing pure-helper) + the whole suite.
zig build test --release=fast          # expect: all passed, exit 0

# If "unhandled relocation type R_X86_64_PC64" -> forgot --release=fast (Gotcha 6).
# If an integer overflow / panic in a mouseCell test -> a `-`/`+` is non-saturating (Gotcha 1);
#   the verified body uses `-|`/`+|` + the total_rows>=1 guard — copy it verbatim.
# If a test expects the wrong value -> re-check the mapping: gx=sx-1, vy=sy-1, gy=scroll+vy,
#   vy clamped to grid_rows-1, gy clamped to total_rows-1 (see findings §5 table).
```

### Level 3: Behavior (the contract — the 6 cases ARE the gate)

```bash
# The 6 unit tests assert exactly (verified 6/6 standalone):
#   plain click (5,3,0,10,50,80)        -> x=4, y=2
#   status-line (5,11,0,10,50,80)       -> y=9 (vy clamps to grid_rows-1)
#   scroll offset (5,3,20,10,50,80)     -> y=22 (gy=20+2)
#   gx clamp (200,1,0,10,50,80)         -> x=79
#   gy clamp (1,1,100,10,50,80)         -> y=49 (scroll clamps to total-1)
#   degenerate (5,3,0,0,50,0)/(5,3,0,10,0,80) -> {0,0}/{_,0} (NO underflow)
zig build test --release=fast -- 2>&1 | grep mouseCell   # confirm the 6 test names appear + pass
```

### Level 4: Scope boundary

```bash
# ONLY src/region.zig changed; nothing else touched.
git diff --stat | grep -v 'src/region.zig' && echo "UNEXPECTED other changes" || echo "scope OK"
# mouseCell is module-private (NOT pub) and takes raw u32 coords (NOT app.MouseEvent):
grep -n 'fn mouseCell' src/region.zig   # expect: "fn mouseCell(sx: u32, sy: u32, ..." (no 'pub')
# No applyMouse / .mouse arm / mouse_anchor added (those are S2 / P1.M2.T2.S1):
grep -cE 'applyMouse|mouse_anchor|\.mouse =>' src/region.zig   # expect: 0
```

## Final Validation Checklist

### Technical Validation

- [ ] `zig version` prints `0.15.2`; `zig build --fetch` exits 0.
- [ ] `zig build test --release=fast` exits 0 (6 new mouseCell tests + 20 existing region tests + whole suite).

### Feature Validation

- [ ] `mouseCell` signature exactly `(sx: u32, sy: u32, scroll: u32, grid_rows: u16, total_rows: u32, tty_cols: u16) view.Pos`.
- [ ] Plain click ⇒ `.x=sx-1`, `.y=sy-1` (scroll=0); scroll offset applied (`.y=scroll+(sy-1)`).
- [ ] Status-line row (sy-1 ≥ grid_rows) clamps `.y` to grid_rows-1; over-range col clamps `.x` to tty_cols-1; over-scroll clamps `.y` to total_rows-1.
- [ ] Degenerate grid_rows==0 / tty_cols==0 / total_rows==0 ⇒ `{0,…}`, NO underflow/panic.
- [ ] 6 new `test` fns pass (standalone; no Terminal — safe per the pure-helper pattern).

### Code Quality Validation

- [ ] `mouseCell` is module-private (`fn`, not `pub fn`); takes raw u32 coords (not app.MouseEvent).
- [ ] Uses saturating `-|`/`+|` + the `total_rows >= 1` guard (no plain `-`/`+` that could underflow).
- [ ] Doc-comment documents the 1-based→0-based conversion, the scroll offset, and the status-line-row exclusion.
- [ ] Follows region.zig's standalone pure-helper test pattern (separate `test` fns).
- [ ] ONLY `src/region.zig` changed; `regionHandle`/`RegionCtx`/`view.zig`/`app.zig` UNCHANGED.

### Documentation & Deployment

- [ ] Mode-A doc-comment on `mouseCell` present (the conversion math + scroll + status-line exclusion).
- [ ] No user-facing / config / CLI surface change (internal primitive; mouse becomes user-visible only in P1.M2.T2.S1).

---

## Anti-Patterns to Avoid

- ❌ Don't use plain `-`/`+` in mouseCell — `tty_cols`/`grid_rows` are u16 and can be 0; `total_rows` can be 0.
  Use `(@as(u32, tty_cols) -| 1)`, `(@as(u32, grid_rows) -| 1)`, `scroll +| vy`, and guard `total_rows >= 1`
  before the `- 1`. Plain arithmetic WILL panic on the degenerate tests (Gotcha 1, 2).
- ❌ Don't make `mouseCell` `pub` or change its signature to take `app.MouseEvent`. It is a module-private
  pure helper taking raw u32 coords (testable without a MouseEvent). The signature is pinned by the design + tests (Gotcha 3, 4).
- ❌ Don't bundle the 6 tests into one `test` fn, and don't avoid separate fns fearing the cross-test
  GOTCHA — that GOTCHA (render.zig:838) only affects `Terminal.init` scopes; `mouseCell` constructs none.
  region.zig's 20 existing pure-helper tests are all separate fns — follow that (Gotcha 5).
- ❌ Don't add `applyMouse` / `clampCursorIntoViewport` / the `.mouse` arm / `RegionCtx.mouse_anchor` here.
  Those are P1.M2.T1.S2 and P1.M2.T2.S1. S1 is purely additive: one fn + 6 tests (Gotcha 7).
- ❌ Don't build/test WITHOUT `--release=fast` — Debug linking hits `R_X86_64_PC64` (Gotcha 6).
- ❌ Don't "simplify" the status-line exclusion by clamping to `grid_rows` instead of `grid_rows-1`. The
  grid area is viewport rows `0..grid_rows-1`; the status line is row `grid_rows`. The clamp MUST be
  `grid_rows-1` (verified by the status-line test asserting `.y == 9` for grid_rows=10).

---

**Confidence Score: 10/10** for one-pass implementation success.

The deliverable is one pure function + 6 tests, both **compile- and run-verified standalone under
Zig 0.15.2 (6/6 passed)**. The screen→grid mapping was proven against `view.render` (view.zig:149:
`gy = scroll + vy`; CUP to `vy+1`/col 1) and is the exact inverse of that paint loop; the status-line
row exclusion (`vy` clamped to `grid_rows-1`) and the saturating no-underflow guards are all exercised
by deterministic tests. The task is purely additive (no existing code path calls `mouseCell` yet, so
nothing can regress), module-private, and takes raw u32 coords so it needs no `Terminal`/`MouseEvent`
to test. The only residual risk — an implementer using non-saturating arithmetic — is eliminated by
the verbatim body + Gotcha 1 + the degenerate test that would panic otherwise.