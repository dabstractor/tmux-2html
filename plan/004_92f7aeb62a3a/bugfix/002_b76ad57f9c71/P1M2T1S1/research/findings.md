# Research findings — P1.M2.T1.S1: pure `mouseCell()` SGR→grid conversion + unit tests

All facts read from the on-disk source; the `mouseCell` implementation + 6 tests were
**compile- and run-verified** standalone under Zig 0.15.2 (6/6 passed). The design is
`architecture/mouse_wiring_design.md`; this file verifies its claims against the real code.

## 1. The two input types (verified)

- `app.MouseEvent` (`src/tui/app.zig:259`): `x: u32` (1-based SGR column), `y: u32` (1-based
  SGR row). Doc at `:255`: *"x/y are 1-based CHARACTER cells as reported by the terminal."*
  Consumed by `applyMouse` (P1.M2.T1.S2), NOT by `mouseCell` directly (mouseCell takes the
  raw `sx,sy` ints so it is testable without a MouseEvent).
- `view.Pos` (`src/tui/view.zig:50`): `pub const Pos = struct { x: u32, y: u32 };` — the
  return type (a 0-based grid cell: `.x` = grid column, `.y` = grid row).

## 2. The screen→grid mapping (verified against `view.render`, src/tui/view.zig:117-172)

`view.render` walks viewport rows `vy = 0..rows-1` and for each computes the GRID row:
```
const gy: u32 = viewport.scroll + vy;            // line 149
try out.print("\x1b[{d};1H", .{vy + 1});          // CUP to 1-based screen row vy+1, col 1   (line 151)
... cells indexed by gx (grid col), gx = 0..cols-1 // line 171
```
So a 1-based screen click `(sx, sy)` ⇒ grid col `gx = sx-1`, viewport row `vy = sy-1`, grid
row `gy = scroll + (sy-1)`. The status line occupies the LAST tty row (screen row `tty_rows`
= viewport row `grid_rows`), so the grid area is viewport rows `0..grid_rows-1`; a click on
the status line (`sy-1 >= grid_rows`) must clamp `vy` to `grid_rows-1`. This is EXACTLY what
`mouseCell` does. (`grid_rows` is computed in `region.zig:358` as `tty_rows -| 1`.)

## 3. RegionCtx fields mouseCell's caller (applyMouse, S2) will pass (verified)

`RegionCtx` (`src/region.zig:88`): `tty_cols: u16` (:92), `tty_rows: u16` (:93),
`grid_rows: u16` (:94, = tty_rows-1), `total_rows: u32` (:95), `cursor: motion.Cursor` (:97),
`sel: select.Sel` (:98). NO `mouse_anchor` field yet (that's P1.M2.T2.S1). S1 does NOT touch
RegionCtx — it only adds the standalone `mouseCell` fn. `region.zig` already imports `app`
(:42), `view` (:43), `motion` (:45), `select` (:46). ✓

## 4. The test pattern (verified — mouseCell is PURE ⇒ safe as separate `test` fns)

`src/region.zig` has **20 existing `test` fns** (lines 792-1147), ALL for pure helpers
(regionPrepare, resolveOutputPath, writeLastOutput, writeHtmlAtomic, readBoolOption,
readFontOption, regionPid, regionTitle, …). `mouseCell` constructs NO `Terminal`/`Screen`
(unlike `renderGrid`), so it follows the SAME safe pattern: standalone `test` fns. (Contrast:
the cross-test GOTCHA at `render.zig:838` only affects Terminal.init scopes — N/A here.)

## 5. The implementation (verbatim from the design; COMPILE- + RUN-VERIFIED)

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

**Compile/run verification** (standalone `zig test` under Zig 0.15.2, 6/6 passed):
| test | input (sx,sy,scroll,grid_rows,total_rows,tty_cols) | expected | ✓ |
|---|---|---|---|
| plain click maps sx-1/sy-1 | (5,3,0,10,50,80) | x=4, y=2 (gy=0+2) | ✓ |
| status-line row clamps to last grid row | (5,11,0,10,50,80) sy>grid_rows | y=9 (vy clamps to grid_rows-1) | ✓ |
| scroll offset applied | (5,3,20,10,50,80) | y=22 (gy=20+2) | ✓ |
| gx clamps to tty_cols-1 | (200,1,0,10,50,80) | x=79 | ✓ |
| gy clamps to total_rows-1 | (1,50,0,10,50,80) and (1,1,100,10,50,80) | y=9 ; y=49 (scroll clamps to total-1) | ✓ |
| degenerate grid_rows==0/tty_cols==0/total_rows==0 no underflow | (5,3,0,0,50,0) and (5,3,0,10,0,80) | x=0,y=0 ; y=0 | ✓ |

## 6. Placement + scope

- **Placement:** new "---- Mouse wiring (PRD §7.6) ----" section immediately BEFORE
  `regionHandle` (`src/region.zig:138`). Additive — touches NO existing code; sets up S2
  (`applyMouse` + `clampCursorIntoViewport`) to extend the same section right after `mouseCell`.
  The 6 `test` fns go at the bottom of the file alongside the other 20 pure-helper tests.
- **Scope (S1 ONLY):** add `mouseCell` (module-private `fn`) + its doc-comment + 6 `test` fns.
  Do NOT add `applyMouse`/`clampCursorIntoViewport` (S2), the `.mouse` arm in `regionHandle`
  or the `RegionCtx.mouse_anchor` field (P1.M2.T2.S1). Purely additive; one new fn.

## 7. Parallel-context check

P1.M1.T2.S1 (parallel) creates `tests/region_signal_keys.sh` (a NEW shell harness) — it does
NOT touch `src/region.zig`. No collision. (It is the Ctrl-z/Ctrl-c ISIG regression harness.)

## 8. Build/test gate

`zig build test --release=fast` — `--release=fast` is mandatory (the Debug linker hits the
ghostty `R_X86_64_PC64` bug). The new tests are reachable from the test root via region.zig's
existing test discovery (region.zig is `@import`ed by main.zig, the test root).

## 9. Confidence

The fn is verbatim from the validated design and was independently compile- + run-verified
(6/6). The types, the render mapping, and RegionCtx field names all match. The task is purely
additive (one fn + 6 tests + a doc-comment). No guessing.