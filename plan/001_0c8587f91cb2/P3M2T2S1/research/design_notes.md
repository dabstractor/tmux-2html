# P3.M2.T2.S1 — `select.zig` selection model: design notes (the build spec)

> Source of truth for implementing `src/tui/select.zig`. Authored from PRD §7.4, the SHIPPED
> `input.zig` Action contract, the SHIPPED `view.zig` display types, and arch `tui_region.md §4`.
> This file is the contract the PRP embeds — read it end-to-end before coding.

## 0. Scope & layering (what S1 owns vs its neighbours)

```
app.Event ─► input.decode ─► input.Key{ kind: .motion|.action|.search }
                                    │                   │
                          .motion ─►│                   │ .action(visual_*/swap_*/clear) ─►
                          motion.applyMotion            select.applyAction  ← THIS SUBTASK (S1)
                                    │                   │
                                    ▼                   ▼
                            motion.Cursor.pos      select.Sel{ anchor, cursor, mode }
                                    │                   │
                                    └────────┬──────────┘   (region.zig P3.M3 OWNS both +
                                             │               syncs sel.cursor = Cursor.pos)
                                             ▼
                                  select.Sel.extent(cols) ─► view.Selection ─► view.render/highlight (overlay)
                                             │
                                             ▼
                            S2 (P3.M2.T2.S2): extent ─► cli.SelectionCoords ─► render.buildSelection ─► ghostty Selection
```

- **S1 (THIS) owns**: the PURE selection MODEL — `Mode`, `Sel{ anchor, cursor, mode }`, the
  named methods `active/clear/toggle/swapEnds`, a `begin` helper, an `extent(cols)` output that
  produces a `view.Selection` (drives view highlights), a `viewMode()` map for the status line,
  and a PURE `applyAction(sel, action, cursor)` dispatcher (the seam region.zig calls). NO I/O,
  NO Terminal, NO ghostty-vt import ⇒ tests are SAFE as SEPARATE `test` fns.
- **S2 (next) owns**: `Sel.extent` → `cli.SelectionCoords` → `render.buildSelection` (grid-aware
  clamp + wide-cell rounding). S1 does NOT touch `render`/`cli`/`Screen` — S1 is grid-free.
- **P3.M3 region.zig owns**: the event loop; OWNS one `motion.Cursor` + one `select.Sel`; on
  `.motion` updates `Cursor.pos` and (if `sel.active()`) copies `Cursor.pos → sel.cursor`; on
  `.action` calls `select.applyAction`; on `.clear` decides clear-vs-quit via `sel.active()`.

> DO NOT: import `render.zig`/`cli.zig`, construct a `Terminal`, touch `buildSelection`, do
> grid-aware clamping, or re-derive `view.Selection`/`view.Pos`/`view.SelMode` (REUSE view.zig).

## 1. The public API (the contract surface)

```zig
//! select.zig — the PURE selection model for the copy-mode TUI (PRD §7.4; arch §4).
//! Owns the interactive selection STATE: an anchor endpoint, a cursor endpoint, and a mode
//! (none/linewise/block). Consumes the SHIPPED `input.Action` contract + REUSES `view`'s
//! display types (Pos/Selection/SelMode). PURE (no I/O, no Terminal) ⇒ its tests are SAFE as
//! separate `test` fns (mirrors input.zig / the parallel motion.zig). region.zig (P3.M3) OWNS
//! a `Sel`; S2 (P3.M2.T2.S2) consumes `Sel.extent` for the grid-aware pin conversion.

const std = @import("std");
const view = @import("view.zig");   // Pos, Selection, SelMode (SHIPPED — reuse, do NOT redefine)
const input = @import("input.zig"); // Action (S1 CONTRACT — consume)

/// The selection mode. `.none` ⇒ no active selection (the Sel exists but is dormant).
/// PRD §7.4: `v` begins LINWISE; `v` again toggles linewise↔block; `V` linewise; `Ctrl-v`/`R` block.
pub const Mode = enum { none, linewise, block };

/// The interactive selection state. `anchor` = the fixed end (set at `begin`, unchanged by
/// motion); `cursor` = the moving end (region.zig keeps it in sync with motion.Cursor.pos).
/// When `mode == .none` the endpoints are DORMANT (ignore them). Either endpoint may be the
/// geometric top-left; `extent()` normalizes via min/max (mirrors view.normSel).
pub const Sel = struct {
    anchor: view.Pos = .{ .x = 0, .y = 0 },
    cursor: view.Pos = .{ .x = 0, .y = 0 },
    mode: Mode = .none,

    /// True when a selection is active (mode != .none). Drives the Esc clear-vs-quit decision
    /// in region.zig + the status line's `<S-sel>` token + `view.Status.has_selection`.
    pub fn active(self: Sel) bool { return self.mode != .none; }

    /// Clear the selection (mode → .none). Endpoints are left stale (dormant); a later `begin`
    /// overwrites them. PRD §7.4 "Esc clears the selection (stays in the TUI)".
    pub fn clear(self: *Sel) void { self.mode = .none; }

    /// Toggle linewise ↔ block (PRD §7.4 "v pressed again toggles"). Only meaningful when
    /// `active()`; on `.none` it is a NO-OP (the `v`-begins path uses `begin`, not toggle).
    /// Endpoints are PRESERVED (only the mode flips) — matches vim visual-mode `v` retoggle.
    pub fn toggle(self: *Sel) void {
        self.mode = switch (self.mode) {
            .linewise => .block,
            .block => .linewise,
            .none => .none,
        };
    }

    /// Swap the anchor and cursor ends (PRD §7.4 "o / O swap cursor to the other end"). Both
    /// `o` and `O` do this in linewise/block mode (PRD treats them identically). After the
    /// swap the cursor is at the former anchor (so subsequent motion moves the OTHER end).
    pub fn swapEnds(self: *Sel) void {
        const tmp = self.anchor;
        self.anchor = self.cursor;
        self.cursor = tmp;
    }

    /// Begin a selection at `pos` in `mode` (PRD §7.4: `v`→linewise, `V`→linewise, `Ctrl-v`/`R`→block).
    /// Sets anchor = cursor = pos (a collapsed seed the user then extends via motion). region.zig
    /// calls this when a visual_* action fires and the Sel is INACTIVE.
    pub fn begin(self: *Sel, pos: view.Pos, mode: Mode) void {
        self.anchor = pos;
        self.cursor = pos;
        self.mode = mode;
    }

    /// The NORMALIZED visible extent as a `view.Selection` (min/max of anchor/cursor). Drives
    /// `view.render`/`view.highlight` (the TUI overlay) AND feeds S2's grid-aware conversion.
    /// Returns `null` when INACTIVE (no highlight). `cols` = grid cell width (view.Viewport.cols).
    ///   linewise ⇒ x1=0, x2=cols-1 (full row width per row in [y1..y2]); rect=false.
    ///   block    ⇒ x1=min(ax,cx), x2=max(ax,cx), y1/y2=min/max; rect=true.
    /// (view.normSel ALSO min/max's, so passing either order is safe; we pre-normalize for S2.)
    pub fn extent(self: Sel, cols: u16) ?view.Selection {
        if (self.mode == .none) return null;
        const a = self.anchor;
        const c = self.cursor;
        const y1: u32 = @min(a.y, c.y);
        const y2: u32 = @max(a.y, c.y);
        const last_col: u32 = if (cols == 0) 0 else @as(u32, cols) - 1; // guard degenerate cols==0
        return switch (self.mode) {
            .none => null,
            .linewise => .{ .x1 = 0, .y1 = y1, .x2 = last_col, .y2 = y2, .rect = false },
            .block => .{ .x1 = @min(a.x, c.x), .y1 = y1, .x2 = @max(a.x, c.x), .y2 = y2, .rect = true },
        };
    }

    /// Map this Sel's mode to the status-line display enum (view.SelMode: none/line/block).
    /// region.zig passes the result into view.Status.mode for renderStatus.
    pub fn viewMode(self: Sel) view.SelMode {
        return switch (self.mode) {
            .none => .none,
            .linewise => .line,
            .block => .block,
        };
    }
};

/// PURE dispatcher: apply a selection `input.Action` to `sel`, using `cursor` as the seed point
/// for `begin`. This is the SEAM region.zig calls for selection actions (it calls motion.applyMotion
/// for `.motion`). `quit`/`confirm` are NOT selection actions ⇒ no-op here (region.zig handles
/// them at the loop level). `.clear` always clears; region.zig decides clear-vs-quit on Esc by
/// checking `sel.active()` BEFORE/after calling this (see §3).
pub fn applyAction(sel: *Sel, action: input.Action, cursor: view.Pos) void {
    switch (action) {
        .visual_toggle => {
            // PRD §7.4: `v` begins LINWISE at cursor when inactive; toggles linewise↔block when active.
            if (sel.active()) sel.toggle() else sel.begin(cursor, .linewise);
        },
        .visual_line => {
            // PRD §7.4: `V` = linewise. If inactive, begin at cursor; if active, switch mode to
            // linewise PRESERVING the endpoints (vim: V in visual mode switches to linewise).
            if (!sel.active()) sel.begin(cursor, .linewise) else sel.mode = .linewise;
        },
        .visual_block => {
            // PRD §7.4: `Ctrl-v`/`R` = block. Same begin/switch logic as visual_line, mode .block.
            if (!sel.active()) sel.begin(cursor, .block) else sel.mode = .block;
        },
        .swap_end, .swap_end_other => {
            // PRD §7.4: `o`/`O` swap cursor to the other end. Vim: a no-op when NOT in visual mode.
            if (sel.active()) sel.swapEnds();
        },
        .clear => sel.clear(), // Esc clears the selection (the clear-vs-QUIT decision is region.zig's)
        .quit, .confirm => {}, // NOT selection actions — handled by region.zig's loop (exit/confirm flow)
    }
}
```

## 2. Per-action state machine (PRD §7.4 — authoritative)

| input.Action | Sel INACTIVE (`!active`)            | Sel ACTIVE                            |
|-------------|-------------------------------------|---------------------------------------|
| visual_toggle (v) | `begin(cursor, .linewise)`   | `toggle()` (linewise↔block)           |
| visual_line (V)   | `begin(cursor, .linewise)`   | `mode = .linewise` (keep endpoints)   |
| visual_block (Ctrl-v/R) | `begin(cursor, .block)` | `mode = .block` (keep endpoints)    |
| swap_end (o) / swap_end_other (O) | no-op        | `swapEnds()`                          |
| clear (Esc) | `clear()` (region.zig then sees `!active` ⇒ QUIT on the bare Esc) | `clear()` (stay in TUI) |
| quit (q/Ctrl-c) | — (region.zig exits)            | — (region.zig exits)                  |
| confirm (Enter/y) | — (region.zig: empty-sel warn+exit 1 / else render) | — (region.zig: render selection) |

**Key rule (input.zig contract):** Esc decodes to `Action.clear` and the HANDLER (region.zig)
decides clear-vs-quit — `if (sel.active()) applyAction(.clear) else quit`. select.zig's
`applyAction(.clear)` just clears; it does NOT quit. (Confirmed by input.zig: ".clear (Esc) is
state-dependent: the handler clears an active selection OR quits when there is nothing to clear".)

**o/O equivalence:** PRD §7.4 says "o / O swap cursor to the other end" — treated identically.
In vim the o/O distinction matters only in visual-BLOCK with multi-cell corners; this TUI (PRD
§7.4) does not model that, so both → `swapEnds()`. Documented v1 simplification.

**toggle on .none is a no-op** because the `v`-begins path uses `begin`, not `toggle`. This keeps
`toggle()` a PURE linewise↔block flip (only ever called when active, via applyAction's guard).

## 3. The extent computation (the S1→view + S1→S2 output)

`Sel.extent(cols)` is the SINGLE source of the normalized selection geometry. It is PURE (no
grid access — pure min/max of the stored endpoints). Two consumers:

- **view overlay (S1's direct output):** `view.render(... selection: ?view.Selection ...)`
  + `view.highlight(gx, gy, sel: ?view.Selection, ...)` invert cells inside the extent. NOTE:
  `view.normSel` (view.zig:283) ALSO min/max's, so for BLOCK either endpoint order is safe; for
  LINEWISE view ignores x entirely (returns true for any gx once gy in range) — but we STILL emit
  `x1=0, x2=cols-1` so the same value is correct for S2.
- **S2 conversion (S1 feeds S2):** S2 calls `sel.extent(cols)` to get the `view.Selection`, maps
  it 1:1 to `cli.SelectionCoords{ x1,y1,x2,y2,rect }`, then `render.buildSelection(screen, coords)`
  (which pins + clamps to the grid). PRD §7.4 mapping:
    * linewise → `Selection{ (0,r1), (cols-1,r2), rect=false }`
    * block    → `Selection{ (c1,r1), (c2,r2), rect=true }`
  S2 owns the grid-aware clamp + wide-cell rounding (PRD §7.4 "round coordinates & clamp to
  grid"); S1's `extent` is grid-free (pure arithmetic). This is the S1/S2 scope boundary.

**cols source:** `view.Viewport.cols` (region.zig passes it; it is the popup grid cell width).
Guard `cols==0` defensively (`last_col=0`) — never happens in practice (popup ≥1 col) but avoids
u32 underflow on `cols-1`.

## 4. Why Sel stores BOTH anchor and cursor (the sync contract)

The contract pins `Sel = struct { anchor, cursor, mode }` — so BOTH endpoints live in the Sel,
NOT borrowed from `motion.Cursor`. Consequence: **region.zig keeps `sel.cursor` in sync with the
motion cursor.** Specifically (P3.M3, documented here so the model is unambiguous):
- On `.motion` while `sel.active()`: `sel.cursor = motionCursor.pos` (motion EXTENDS the
  selection — anchor fixed, cursor moves). `motion.applyMotion` updates `Cursor.pos`; region.zig
  copies it into `sel.cursor`.
- On `.motion` while `!active()`: cursor moves freely; `sel.cursor` is stale-but-dormant (ignored
  by `extent`, which returns null when inactive).
- `begin(pos, mode)` sets anchor = cursor = pos (collapsed seed).
- `swapEnds()` swaps the two stored endpoints (so the user now drives the former anchor).

This is why `extent()` reads `self.anchor` + `self.cursor` directly — no external cursor needed.

## 5. Gotchas (Zig 0.15.2 + this codebase)

- **PURE ⇒ separate test fns are SAFE.** select.zig imports `view.zig` (which imports
  ghostty-vt) + `input.zig` (which imports app.zig). Importing is fine — the cross-test GOTCHA
  (render.zig/view.zig) is about CONSTRUCTING a `Terminal` in a separate test fn (process-global
  state corruption), NOT about importing. select.zig NEVER constructs a Terminal ⇒ its tests run
  as SEPARATE `test` fns (mirrors input.zig + the parallel motion.zig).
- **`zig build test` MUST use `-Doptimize=ReleaseFast`** (PRD §15; the R_X86_64_PC64 linker bug
  with the bundled ghostty C++ SIMD libs in Debug). EVERY validation command uses it.
- **u32 min/max, no subtracts that underflow.** extent() only uses `@min`/`@max` (safe). The
  lone subtract is `cols - 1`, guarded by the `cols == 0` check (`@as(u32, cols) - 1` would be
  fine since cols>=1 after the guard). No `y - count`-style underflows here (unlike motion.zig).
- **`view.Selection.x1..x2/y1..y2` are `u32`; `view.Pos.x/y` are `u32`.** No casts needed. `cols`
  is `u16` (view.Viewport.cols); widen with `@as(u32, cols)` before the subtract.
- **REUSE view's types — do NOT redefine Pos/Selection/SelMode.** select.zig's `anchor`/`cursor`
  are `view.Pos`; `extent` returns `?view.Selection`; `viewMode` returns `view.SelMode`. Single
  source of truth (region.zig passes these straight into `view.render`/`view.Status`).
- **`switch (self.mode)` and `switch (action)` MUST be exhaustive.** Zig compile-errors if a
  variant is missed — use this as a checklist (Mode has 3 variants; input.Action has 8).
- **NO dependency on `motion.zig`.** select.zig uses `view.Pos` directly (NOT `motion.Cursor`).
  region.zig (P3.M3) owns both a `motion.Cursor` and a `select.Sel` and syncs `sel.cursor`.
  This keeps select.zig decoupled from the parallel S2-of-T1 (motion) work — no import cycle.
- **NO main.zig import-line CONFLICT with the parallel motion.zig.** Both add ONE line to the
  test block. They are DIFFERENT lines (`tui/select.zig` vs `tui/motion.zig`) — the orchestrator
  merges both; this PRP adds ONLY its own line and MUST NOT touch motion's line.

## 6. Testing strategy (separate `test` fns — SAFE; PURE, no Terminal)

Mirror `src/tui/input.zig` test style (`const testing = std.testing;` + `test "name: scenario"` +
`try testing.expectEqual(...)`). Cover:

- **Sel defaults + active():** a default Sel (`.{}`) has mode `.none`, `active()==false`; after
  `begin`, `active()==true`; after `clear`, `active()==false`.
- **toggle():** linewise→block→linewise; `.none`→`.none` (no-op); endpoints PRESERVED across a
  toggle (only mode flips).
- **swapEnds():** anchor↔cursor swap; idempotent under double-swap; inert data when inactive
  (still swaps the stored endpoints — document: swapEnds swaps regardless, applyAction guards).
- **begin(pos, mode):** sets anchor=cursor=pos, mode=mode; overwrites prior state.
- **extent(cols):**
    * inactive ⇒ null.
    * linewise, anchor above cursor ⇒ `{0, y_lo, cols-1, y_hi, rect=false}` (y_lo<y_hi).
    * linewise, anchor BELOW cursor ⇒ SAME normalized {y_lo,y_hi} (order-independent).
    * linewise cols-1 boundary (cols=80 ⇒ x2=79); cols=0 ⇒ x2=0 (guard).
    * block, anchor top-left / cursor bottom-right ⇒ rect, min/max x and y.
    * block, anchor bottom-right / cursor top-left ⇒ SAME normalized extent (order-independent).
    * block with anchor.x > cursor.x ⇒ x1=min, x2=max.
- **viewMode():** none→.none, linewise→.line, block→.block.
- **applyAction dispatcher (the seam):**
    * `.visual_toggle` inactive ⇒ begin linewise at cursor (anchor=cursor=cursor, mode=linewise).
    * `.visual_toggle` active linewise ⇒ mode block (endpoints preserved).
    * `.visual_toggle` active block ⇒ mode linewise.
    * `.visual_line` inactive ⇒ begin linewise; active block ⇒ mode linewise (endpoints preserved).
    * `.visual_block` inactive ⇒ begin block; active linewise ⇒ mode block.
    * `.swap_end`/`.swap_end_other` active ⇒ swapEnds; inactive ⇒ NO-OP (endpoints unchanged).
    * `.clear` ⇒ mode none.
    * `.quit`/`.confirm` ⇒ NO-OP on the Sel (the Sel is untouched — region.zig owns these).
- **A small integration-style test:** simulate `v` (begin) → motion moves cursor → `sel.cursor`
  updated by the "caller" → `extent` reflects the extended range → `o` → `swapEnds` flips the
  driven end → `Esc` → `clear` ⇒ inactive. (Use plain struct updates to mimic region.zig; no
  motion import needed — just set `sel.cursor` by hand.)

All tests are value-struct assertions — NO allocation, NO Terminal, NO I/O.

## 7. File footprint (exactly)

- **CREATE** `src/tui/select.zig` (the whole module: imports, `Mode`, `Sel`+methods, `applyAction`,
  + the `test` block).
- **EDIT** `src/main.zig`: add ONE line to the test block — `_ = @import("tui/select.zig");` —
  placed AFTER the existing `tui/input.zig` import (line ~497). Do NOT touch the motion.zig line
  (parallel work) or any other import.
- **NO** build.zig / build.zig.zon change. select.zig is reached via the `src/tui/` import graph
  + the one new main.zig test-import. Imports ONLY `std` + `view.zig` + `input.zig`.
