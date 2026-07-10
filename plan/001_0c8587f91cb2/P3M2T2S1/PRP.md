name: "P3.M2.T2.S1 — Selection model: linewise/block, v-toggle, o/O, anchor/cursor (src/tui/select.zig)"
description: |
  The PURE selection MODEL for the copy-mode TUI. Consumes the SHIPPED `input.Action` contract
  (P3.M2.T1.S1) + REUSES `view`'s display types (Pos/Selection/SelMode, P3.M1.T2) and produces a
  `Mode` enum + `Sel{ anchor, cursor, mode }` with the named methods `active/clear/toggle/swapEnds`,
  a `begin` helper, an `extent(cols)` output (the normalized `view.Selection` that drives view
  highlights AND feeds S2's grid-aware conversion), a `viewMode()` status map, and a PURE
  `applyAction` dispatcher. NEW file `src/tui/select.zig` + ONE import line in `src/main.zig`.
  No deps, no build.zig change, no edits to view/input/app/motion, no Terminal construction.

---

## Goal

**Feature Goal**: Implement PRD §7.4's selection state machine as a PURE, grid-free model:
`v` begins LINWISE at the cursor (anchor=cursor); `v` again toggles linewise↔block; `V` linewise;
`Ctrl-v`/`R` block; `o`/`O` swap the cursor to the other end; `Esc` clears (stay in TUI);
movement extends the selection anchor→cursor. The selection's visible extent is the min/max of
anchor/cursor in either order, producing linewise (full row width) or block (rectangle) geometry.

**Deliverable**:
1. **NEW FILE** `src/tui/select.zig` — a PURE, ghostty-vt-free, I/O-free module containing:
   `Mode` (enum none/linewise/block), `Sel{ anchor, cursor, mode }` with methods `active()`,
   `clear()`, `toggle()`, `swapEnds()`, `begin(pos, mode)`, `extent(cols) ?view.Selection`,
   `viewMode() view.SelMode`, and the PURE dispatcher `applyAction(sel, action, cursor)` — all
   fully unit-tested as SEPARATE `test` fns (no Terminal ⇒ no cross-test GOTCHA).
2. **ONE-LINE EDIT** to `src/main.zig` test block: add `_ = @import("tui/select.zig");` after the
   existing `tui/input.zig` import so the model's tests are reachable from the test root.

**Success Definition**: `zig build test -Doptimize=ReleaseFast` passes (all existing tests + ALL
new select.zig tests). Every §7.4 action transitions the Sel to the exact documented state;
`extent()` normalizes either endpoint order to the correct linewise/block `view.Selection`;
`applyAction` is the exact seam region.zig (P3.M3) will call. No new dependencies; no edits to
`view.zig`/`input.zig`/`app.zig`/`motion.zig`/`build.zig`/`build.zig.zon`.

## User Persona (if applicable)

**Target User**: tmux user invoking the interactive `region` copy-mode overlay (PRD §7) to select a
linewise or rectangular region of captured scrollback to render to HTML.

**Use Case**: User presses `v` to start selecting a line range, moves the cursor to extend it,
presses `v` again to switch to a rectangle/block, presses `o` to drive the other end, then `Enter`
to render (P3.M3). While active, the selected cells are highlighted in the TUI overlay.

**User Journey**: (wired by P3.M3 region.zig, which OWNS a `motion.Cursor` + a `select.Sel`) —
`app.readEvent → input.decode → input.Key{kind:.action} → select.applyAction(sel, action, cursor)
→ (region syncs sel.cursor = motion.Cursor.pos on motion) → view.render(selection = sel.extent(cols))
→ highlighted overlay`. On confirm, `sel.extent` → S2 → `render.buildSelection` → HTML.

**Pain Points Addressed**: Faithful vim-style visual selection (linewise + block + `o`/`O`) in a
custom Zig TUI, expressed as a small PURE, deterministic, fully-testable model decoupled from
rendering and the grid.

## Why

- **Completes the TUI input pipeline (the selection half):** P3.M2.T1.S1 SHIPPED the key DECODER
  (`input.Action`); this subtask ships the MODEL that consumes the visual/swap/clear actions.
  Without it, the decoded `v`/`V`/`Ctrl-v`/`o`/`O`/`Esc` keys do nothing.
- **Reuses, never duplicates:** consumes the SHIPPED `view` display types (`view.Pos`,
  `view.Selection`, `view.SelMode`) — `select.zig` is a thin, PURE model that EMITS a
  `view.Selection` (the very struct `view.render`/`view.highlight` already consume). It never
  re-derives geometry and never touches the grid or a `Terminal`.
- **Unblocks siblings:** S2 (P3.M2.T2.S2) consumes `Sel.extent` for the grid-aware pin conversion
  (`cli.SelectionCoords` → `render.buildSelection`); P3.M3 (`region.zig`) OWNS a `Sel`, syncs
  `sel.cursor` with `motion.Cursor.pos`, calls `applyAction` for selection actions, and passes
  `sel.extent(cols)` + `sel.viewMode()` into `view.render`/`view.Status`. This model is their
  foundation.

## What

A new `src/tui/select.zig` that:
- Defines `Mode = enum { none, linewise, block }` and `Sel = struct { anchor: view.Pos, cursor:
  view.Pos, mode: Mode }`.
- Implements the 4 NAMED methods — `active() bool`, `clear() void`, `toggle() void` (linewise↔block;
  `.none` is a no-op), `swapEnds() void` (swap anchor↔cursor) — plus a `begin(pos, mode)` helper.
- Implements `extent(cols: u16) ?view.Selection` (the min/max normalized geometry; null when
  inactive) and `viewMode() view.SelMode` (status-line map).
- Implements the PURE `applyAction(sel: *Sel, action: input.Action, cursor: view.Pos) void`
  dispatcher: `v`/`V`/`Ctrl-v`/`R`/`o`/`O`/`Esc` drive the Sel per §7.4; `quit`/`confirm` are no-ops
  here (region.zig owns the exit/confirm loop).
- Is PURE (no I/O, no allocation, no `Terminal`) ⇒ its tests run as SEPARATE `test` fns (mirrors
  `input.zig` + the parallel `motion.zig`).

### Success Criteria

- [ ] `Sel` defaults to `{ anchor=(0,0), cursor=(0,0), mode=.none }` and `active()==false`.
- [ ] `v` (`visual_toggle`) on an INACTIVE Sel begins LINWISE at `cursor` (anchor=cursor=cursor);
      on an ACTIVE Sel toggles linewise↔block, PRESERVING the endpoints.
- [ ] `V` (`visual_line`) begins linewise when inactive; switches an active Sel to linewise
      (endpoints preserved). `Ctrl-v`/`R` (`visual_block`) mirrors this for `.block`.
- [ ] `o`/`O` (`swap_end`/`swap_end_other`) on an ACTIVE Sel swap anchor↔cursor; on an INACTIVE
      Sel they are a NO-OP.
- [ ] `Esc` (`clear`) sets `mode=.none` (clears; the clear-vs-QUIT decision is region.zig's, not
      select.zig's).
- [ ] `extent(cols)` returns `null` when inactive; for linewise yields `{x1=0,y1=min,y2=max,
      x2=cols-1,rect=false}`; for block yields `{x1=min(ax,cx),y1=min(ay,cy),x2=max(ax,cx),
      y2=max(ay,cy),rect=true}` — ORDER-INDEPENDENT (anchor above/below/left/right of cursor).
- [ ] `viewMode()` maps none→`.none`, linewise→`.line`, block→`.block`.
- [ ] `applyAction` leaves the Sel UNTOUCHED for `.quit`/`.confirm` (those are region.zig's loop
      concern), and guards all visual/swap actions on `active()` correctly.
- [ ] `zig build test -Doptimize=ReleaseFast` passes; select.zig imports ONLY `std`+`view.zig`+
      `input.zig` (no `ghostty-vt`, no `Terminal`).

## All Needed Context

### Context Completeness Check

_If someone knew nothing about this codebase, would they have everything needed to implement this
successfully?_ **YES.** This PRP embeds the exact API to consume (`input.Action` from S1, the
`view` types to reuse with file:line), the authoritative §7.4 per-action state table, the exact
`Sel` method semantics, the `extent()` geometry rules, the S1/S2 scope boundary, the testing
strategy, and the precise build/test commands.

### Documentation & References

```yaml
# MUST READ — the authoritative spec for THIS module (already in the research/ dir)
- docfile: plan/001_0c8587f91cb2/P3M2T2S1/research/design_notes.md
  why: The COMPLETE API + per-action state table + extent geometry + S1/S2 boundary + sync contract
       + Zig gotchas + testing strategy. This IS the build spec — read it end-to-end.
  section: "§1 The public API (the contract surface)" + "§2 Per-action state machine"

- file: src/tui/input.zig
  why: The DECODER CONTRACT — CONSUME its `Action` enum EXACTLY (8 variants). applyAction switches
       on it. Do NOT re-implement decoding.
  pattern: "enum `Action` has exactly: visual_toggle(v), visual_line(V), visual_block(Ctrl-v/R),
            swap_end(o), swap_end_other(O), clear(Esc), quit(q/Ctrl-c), confirm(Enter/y)."
  gotcha: ".clear (Esc) is state-dependent: select.zig's applyAction(.clear) ONLY clears; the
           clear-vs-QUIT decision is region.zig's (input.zig: '.clear (Esc) is state-dependent:
           the handler clears an active selection OR quits when there is nothing to clear')."

- file: src/tui/view.zig
  why: REUSE its display types — single source of truth (NO duplication). select.zig's
       anchor/cursor are `view.Pos`; extent() returns `?view.Selection`; viewMode() returns
       `view.SelMode`. region.zig passes these straight into view.render/view.Status.
  pattern: "view.Pos = struct{x:u32,y:u32} (src/tui/view.zig:49);
            view.Selection = struct{x1:u32,y1:u32,x2:u32,y2:u32,rect:bool=false} (view.zig:54);
            view.SelMode = enum{none,line,block} (view.zig:78);
            view.Viewport.cols is u16 (view.zig:40)."
  gotcha: "view.normSel (view.zig:283) ALREADY min/max's a Selection, so view.render/highlight
           accept EITHER endpoint order — but extent() pre-normalizes anyway so the SAME value is
           correct for S2's cli.SelectionCoords. For LINEWISE view ignores x (returns true for any
           gx once gy in range) — we still emit x1=0,x2=cols-1 for S2."

- file: src/tui/app.zig
  why: Pipeline context only — confirms the EventHandler ctx/fn-pointer seam + that the loop lives
       in region.zig (P3.M3). select.zig does NOT import app.zig (it consumes input.Action, which
       is downstream of app.Event). Read to see WHERE select.zig plugs in.
  pattern: The full loop (P3.M3): .motion ⇒ motion.applyMotion + sel.cursor sync; .action ⇒
           select.applyAction (Esc: clear-vs-quit via sel.active()); .search ⇒ search flow.

- docfile: plan/001_0c8587f91cb2/architecture/tui_region.md
  why: The TUI layering overview — §4 (selection model, THIS subtask) confirms: anchor/cursor/mode
       state; v begins linewise anchor=cursor, v toggles, V/Ctrl-v set mode, o/O swap, Esc clears;
       visible extent via view overlay; convert to ghostty Selection (S2).
  section: "§4 Selection model (select.zig) — own coordinates"

- url: https://vimhelp.org/visual.txt.html
  why: Authoritative vim visual-mode reference (o/O swap-to-other-end; gv; mode switching).
  critical: "This TUI (PRD §7.4) treats o and O IDENTICALLY (both swapEnds) — the vim o-vs-O
             corner distinction (visual-block multi-cell) is NOT modeled (documented v1 limit).
             toggle()/begin() semantics OVERRIDE full-vim where PRD §7.4 differs."
```

### Current Codebase tree (run `tree` in the root of the project)

```bash
$ tree src/ -I 'zig-cache' --dirsfirst
src/
├── tui/
│   ├── app.zig        # P3.M1.T1 — Event/Input/readEvent/runEvents + alt-screen + mouse (SHIPPED)
│   ├── input.zig      # P3.M2.T1.S1 — key DECODER: Key/Motion/Action/Search/Decoder/feed/decode (SHIPPED — CONTRACT)
│   ├── view.zig       # P3.M1.T2 — render + highlight + scroll math + findMatches + Pos/Viewport/Selection/SelMode (SHIPPED — REUSE)
│   └── motion.zig     # P3.M2.T1.S2 — PURE cursor/motion/search NAVIGATION engine (PARALLEL — do NOT import/edit)
├── capture.zig        # P2.M1 — pane capture (region.zig P3.M3 reuses its full mode)
├── cli.zig            # parg flag parser + SelectionCoords (the S2 conversion target struct)
├── ghostty_format.zig # vendored Cell→Style formatter
├── golden_test.zig    # P1.M4 golden harness
├── main.zig           # dispatch + top-level test{} block (ADD ONE @import line HERE)
├── palette.zig        # P1.M2 — queryColors + cache + resolve
└── render.zig         # P1.M3 — renderGrid + buildSelection (the S2 conversion CALL site)
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
src/
├── tui/
│   ├── app.zig        # UNCHANGED
│   ├── input.zig      # UNCHANGED (consumed as a contract — Action enum)
│   ├── view.zig       # UNCHANGED (consumed: Pos, Selection, SelMode, Viewport.cols type)
│   ├── motion.zig     # UNCHANGED (PARALLEL work — do NOT touch; select.zig does NOT import it)
│   └── select.zig     # NEW — the PURE selection MODEL (THIS subtask)
└── main.zig           # ONE new line in the test{} block: `_ = @import("tui/select.zig");`
```

`src/tui/select.zig` responsibilities (the ONLY new file):
- `Mode` (enum none/linewise/block) — the selection mode state.
- `Sel{ anchor: view.Pos, cursor: view.Pos, mode: Mode }` + the methods `active`, `clear`, `toggle`,
  `swapEnds`, `begin`, `extent`, `viewMode`.
- `applyAction(sel, action, cursor)` — the PURE dispatcher (the seam region.zig calls).
- Comprehensive `test` fns (separate — select.zig NEVER constructs a Terminal).

### Known Gotchas of our codebase & Library Quirks

```zig
// CRITICAL: zig build test MUST use -Doptimize=ReleaseFast. Debug hits the R_X86_64_PC64 linker
//   bug with the bundled ghostty C++ SIMD libs (PRD §15; confirmed across all sibling PRPs).
//   EVERY validation command in this PRP uses `zig build test -Doptimize=ReleaseFast`.

// CRITICAL: select.zig is PURE — it NEVER constructs a Terminal. The cross-test GOTCHA
//   (src/render.zig, src/tui/view.zig): a Terminal.init in a SEPARATE test fn CRASHES via
//   process-global state corruption. IMPORTING view.zig (which imports ghostty-vt) is FINE —
//   the bug is about CONSTRUCTION, not import. select.zig only touches view's VALUE structs
//   (Pos/Selection/SelMode) ⇒ its PURE tests are SAFE as separate `test` fns (mirrors input.zig).

// CRITICAL: REUSE view's types — do NOT redefine Pos/Selection/SelMode. select.zig's anchor/
//   cursor are view.Pos; extent() returns ?view.Selection; viewMode() returns view.SelMode.
//   region.zig (P3.M3) passes these straight into view.render(selection:?view.Selection) and
//   view.Status.mode (view.SelMode) — type identity MUST hold.

// CRITICAL: Esc decodes to Action.clear, but the clear-vs-QUIT decision is the HANDLER's
//   (region.zig P3.M3): `if (sel.active()) applyAction(.clear) else quit`. select.zig's
//   applyAction(.clear) ONLY clears (mode=.none) — it does NOT quit. Do NOT add quit logic here.

// CRITICAL: toggle() is a PURE linewise↔block flip. On .none it is a NO-OP (the v-begins path
//   uses begin(), not toggle()). applyAction(.visual_toggle) guards: active?toggle():begin().

// CRITICAL: o and O are TREATED IDENTICALLY (both → swapEnds). PRD §7.4 says "o / O swap cursor
//   to the other end". The vim visual-block o-vs-O corner distinction is NOT modeled (v1 limit).

// CRITICAL: extent() uses @min/@max only (no underflowing subtracts). The one subtract is
//   `cols - 1` for linewise x2 — GUARD cols==0 (`if (cols==0) 0 else @as(u32,cols)-1`). cols is
//   u16 (view.Viewport.cols); widen to u32 BEFORE the subtract. y values are min/max (safe).

// CRITICAL: Sel.cursor must be kept in sync with motion.Cursor.pos by region.zig (P3.M3) —
//   select.zig does NOT import motion.zig. begin() sets anchor=cursor=pos; extent() reads the
//   stored endpoints. This is WHY Sel stores BOTH anchor and cursor (per the contract).

// CRITICAL: the ONE new main.zig import line must NOT collide with the parallel motion.zig line
//   (P3.M2.T1.S2 adds `_ = @import("tui/motion.zig");`). Add ONLY the `tui/select.zig` line;
//   leave motion's line (and all others) untouched. The orchestrator merges both edits.

// CRITICAL: `switch (self.mode)` (3 variants) and `switch (action)` (8 input.Action variants)
//   MUST be exhaustive — Zig compile-errors on a missing variant (a built-in checklist).
```

## Implementation Blueprint

### Data models and structure

`src/tui/select.zig` defines ONLY value structs + pure functions (no `Terminal`, no allocation,
no I/O). Verbatim from `research/design_notes.md §1`:

```zig
const std = @import("std");
const view = @import("view.zig");   // Pos, Selection, SelMode (SHIPPED — reuse)
const input = @import("input.zig"); // Action (S1 CONTRACT — consume)

/// PRD §7.4: v begins LINWISE; v again toggles linewise↔block; V linewise; Ctrl-v/R block.
pub const Mode = enum { none, linewise, block };

/// The interactive selection state. anchor = fixed end (set at begin); cursor = moving end
/// (region.zig P3.M3 syncs it with motion.Cursor.pos). Either may be geometric top-left;
/// extent() normalizes via min/max (mirrors view.normSel).
pub const Sel = struct {
    anchor: view.Pos = .{ .x = 0, .y = 0 },
    cursor: view.Pos = .{ .x = 0, .y = 0 },
    mode: Mode = .none,

    pub fn active(self: Sel) bool { return self.mode != .none; }
    pub fn clear(self: *Sel) void { self.mode = .none; }
    pub fn toggle(self: *Sel) void {           // linewise↔block; .none stays .none (begin() starts)
        self.mode = switch (self.mode) { .linewise => .block, .block => .linewise, .none => .none };
    }
    pub fn swapEnds(self: *Sel) void {           // PRD §7.4 o/O: swap cursor to the other end
        const tmp = self.anchor; self.anchor = self.cursor; self.cursor = tmp;
    }
    pub fn begin(self: *Sel, pos: view.Pos, mode: Mode) void { self.anchor = pos; self.cursor = pos; self.mode = mode; }

    /// Normalized visible extent → view.Selection (drives view overlay + feeds S2). null if inactive.
    pub fn extent(self: Sel, cols: u16) ?view.Selection {
        if (self.mode == .none) return null;
        const a = self.anchor; const c = self.cursor;
        const y1: u32 = @min(a.y, c.y); const y2: u32 = @max(a.y, c.y);
        const last_col: u32 = if (cols == 0) 0 else @as(u32, cols) - 1;
        return switch (self.mode) {
            .none => null,
            .linewise => .{ .x1 = 0, .y1 = y1, .x2 = last_col, .y2 = y2, .rect = false },
            .block => .{ .x1 = @min(a.x, c.x), .y1 = y1, .x2 = @max(a.x, c.x), .y2 = y2, .rect = true },
        };
    }
    pub fn viewMode(self: Sel) view.SelMode {   // status-line map
        return switch (self.mode) { .none => .none, .linewise => .line, .block => .block };
    }
};

/// PURE dispatcher (the seam region.zig calls for selection actions). quit/confirm are no-ops
/// here (region.zig's loop owns exit/confirm). clear only clears (clear-vs-quit is region.zig's).
pub fn applyAction(sel: *Sel, action: input.Action, cursor: view.Pos) void {
    switch (action) {
        .visual_toggle => { if (sel.active()) sel.toggle() else sel.begin(cursor, .linewise); },
        .visual_line   => { if (!sel.active()) sel.begin(cursor, .linewise) else sel.mode = .linewise; },
        .visual_block  => { if (!sel.active()) sel.begin(cursor, .block)   else sel.mode = .block; },
        .swap_end, .swap_end_other => { if (sel.active()) sel.swapEnds(); },
        .clear => sel.clear(),
        .quit, .confirm => {}, // region.zig owns these (exit / confirm-render flow)
    }
}
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: CREATE src/tui/select.zig — module header + imports + types
  - IMPORT: `const std = @import("std"); const view = @import("view.zig"); const input = @import("input.zig");`
  - IMPLEMENT: Mode (3 variants), Sel (anchor/cursor: view.Pos, mode: Mode) + ALL methods EXACTLY
    as the data-model block above (verbatim from research/design_notes.md §1).
  - GOTCHA: anchor/cursor/cursor params are view.Pos (REUSE — do NOT redefine Pos). extent's `cols`
    is u16; widen to u32 before `cols-1`; guard cols==0. mode defaults to .none; the Sel default
    `.{}` yields anchor=cursor=(0,0), mode=.none.
  - NAMING: Mode variants lowercase (none/linewise/block); methods active/clear/toggle/swapEnds/
    begin/extent/viewMode (camelCase, matching view.zig/input.zig style).

Task 2: IMPLEMENT applyAction(sel, action, cursor) — the PURE dispatcher
  - SWITCH exhaustively on input.Action (8 variants) per the state table (design_notes §2):
      visual_toggle ⇒ active?toggle():begin(cursor,.linewise)
      visual_line   ⇒ active?(mode=.linewise):begin(cursor,.linewise)
      visual_block  ⇒ active?(mode=.block):begin(cursor,.block)
      swap_end/swap_end_other ⇒ active?swapEnds():no-op
      clear ⇒ clear();  quit/confirm ⇒ no-op (region.zig owns exit/confirm)
  - GOTCHA: do NOT add quit/confirm logic — those are region.zig's loop concern. applyAction(.quit)
    and applyAction(.confirm) leave the Sel UNTOUCHED (empty arm).
  - GOTCHA: the `switch (action)` MUST be exhaustive (Zig compile-check; 8 variants).

Task 3: CREATE the test block (SEPARATE test fns — select.zig NEVER constructs a Terminal ⇒ SAFE)
  - FOLLOW the test matrix in research/design_notes.md §6. Cover:
      * Defaults + active(): default Sel is inactive; begin⇒active; clear⇒!active.
      * toggle(): linewise→block→linewise; .none→.none (no-op); endpoints PRESERVED across toggle.
      * swapEnds(): anchor↔cursor swap; double-swap is identity; inert-when-called-directly.
      * begin(pos,mode): sets anchor=cursor=pos, mode=mode; overwrites prior state.
      * extent(cols): inactive⇒null; linewise order-independent {0,min,max,cols-1,false}; block
        order-independent {min,min,max,max,true}; cols==0 guard (x2=0); cols=80⇒x2=79; block with
        anchor.x>cursor.x ⇒ x1=min,x2=max.
      * viewMode(): none→.none, linewise→.line, block→.block.
      * applyAction: every branch — visual_toggle active/inactive; visual_line/block active/inactive;
        swap_end/swap_end_other active(inert when inactive); clear; quit/confirm are NO-OPs (Sel
        untouched — assert state unchanged).
      * Mini integration: v(begin) → simulate motion by setting sel.cursor by hand → extent reflects
        extended range → o(swapEnds) → Esc(clear) ⇒ inactive. (No motion import — set fields directly.)
  - PATTERN: mirror src/tui/input.zig test style — `const testing = std.testing;` + `test "name:
    scenario"` + `try testing.expectEqual(...)`. Build Sel literals with `.{ .anchor=...,
    .cursor=..., .mode=... }` + view.Pos `.{ .x=.., .y=.. }`.
  - NAMING: test "{fn}: {scenario}" — descriptive, one concept per test fn.

Task 4: EDIT src/main.zig — wire select.zig into the test root
  - FIND: the test{} block at src/main.zig (the `_ = @import("tui/input.zig");` line at ~497).
  - ADD: ONE line after the input.zig import (and after motion.zig's if present):
        // P3.M2.T2.S1: keep tui/select.zig tests reachable (region.zig, its caller, does NOT
        // exist yet). select.zig is PURE (no Terminal) ⇒ separate test fns (no cross-test GOTCHA).
        _ = @import("tui/select.zig");
  - PRESERVE: every other @import line (incl. the PARALLEL motion.zig line — do NOT touch it);
    NO other main.zig change; NO build.zig / build.zig.zon change.
```

### Implementation Patterns & Key Details

```zig
// === The §7.4 per-action state table (research/design_notes.md §2 — source of truth) ===
//  input.Action        | Sel INACTIVE (!active)         | Sel ACTIVE
//  --------------------|--------------------------------|------------------------------------
//  visual_toggle (v)   | begin(cursor, .linewise)       | toggle()  (linewise↔block, endpoints kept)
//  visual_line (V)     | begin(cursor, .linewise)       | mode = .linewise (endpoints kept)
//  visual_block(C-v/R) | begin(cursor, .block)          | mode = .block    (endpoints kept)
//  swap_end/other(o/O) | NO-OP                          | swapEnds()
//  clear (Esc)         | clear()  (region.zig then QUIT)| clear()  (stay in TUI)
//  quit (q/Ctrl-c)     | — (region.zig exits)           | — (region.zig exits)
//  confirm (Enter/y)   | — (region.zig: empty-warn/exit)| — (region.zig: render selection)
//
// KEY: Esc→Action.clear, but clear-vs-quit is the HANDLER's: `if (sel.active()) applyAction(.clear)
// else quit`. select.zig's applyAction(.clear) ONLY clears. (input.zig contract.)
// KEY: o and O are IDENTICAL here (both swapEnds). PRD §7.4 "o / O swap cursor to the other end".
// KEY: toggle() on .none is a NO-OP — v-begins uses begin(), applyAction guards active?toggle:begin.

// === extent() geometry (research/design_notes.md §3 — the S1→view + S1→S2 output) ===
//  linewise ⇒ { x1=0, y1=min(anchor.y,cursor.y), x2=cols-1, y2=max(anchor.y,cursor.y), rect=false }
//  block    ⇒ { x1=min(ax,cx), y1=min(ay,cy), x2=max(ax,cx), y2=max(ay,cy), rect=true }
//  inactive ⇒ null
// view.normSel (view.zig:283) ALSO min/max's, so order is safe either way — but extent
// pre-normalizes so the SAME value is correct for S2's cli.SelectionCoords. For linewise view
// ignores x (full-row highlight) — we still emit x1=0,x2=cols-1 for S2.

// === The sync contract (why Sel stores BOTH anchor and cursor) ===
// region.zig (P3.M3) OWNS a motion.Cursor + a select.Sel and keeps sel.cursor = Cursor.pos:
//   on .motion while sel.active(): sel.cursor = motionCursor.pos  (motion EXTENDS the selection)
//   on .motion while !active():    cursor moves freely; sel.cursor stale-but-dormant (extent⇒null)
//   begin(pos,mode): anchor=cursor=pos (collapsed seed);  swapEnds(): flips the driven end.
// extent() reads self.anchor + self.cursor directly — no external cursor param needed.
```

### Integration Points

```yaml
BUILD:
  - NO change. select.zig is reached via the existing `src/tui/` import graph + the ONE new
    `_ = @import("tui/select.zig");` line in main.zig's test block. No build.zig / build.zig.zon
    edit; no new dependency (imports ONLY std + view.zig + input.zig).

TEST_ROOT:
  - add to: src/main.zig (the top-level `test {}` block, after the `tui/input.zig` import ~line 497)
  - pattern: "_ = @import(\"tui/select.zig\");"
  - preserve: every other @import line — INCL. the PARALLEL motion.zig line (P3.M2.T1.S2); do NOT
              touch it. The orchestrator merges both edits.

DOWNSTREAM_CONSUMERS (NOT this subtask — for awareness):
  - S2 (P3.M2.T2.S2): extent(cols) → cli.SelectionCoords{ x1,y1,x2,y2,rect } (1:1 field copy) →
      render.buildSelection(screen, coords) (grid-aware pin + clamp + wide-cell rounding). PRD §7.4:
      linewise → Selection{(0,r1),(cols-1,r2),rect=false}; block → Selection{(c1,r1),(c2,r2),rect=true}.
  - P3.M3 region.zig: OWNS a motion.Cursor + a select.Sel; per input.Key:
      .action ⇒ select.applyAction(sel, key.kind.action, cursor.pos); (Esc: clear-vs-quit via
                 sel.active(); confirm: sel.extent→S2→renderGrid(selection)→HTML+sidecar)
      .motion ⇒ cursor = motion.applyMotion(cursor, key.kind.motion, key.count, screenGrid);
                 if (sel.active()) sel.cursor = cursor.pos;   // EXTEND the selection
      render: view.render(out, screen, pal, viewport, cursor.pos, sel.extent(viewport.cols), matches)
              + view.renderStatus(..., .{ .mode = sel.viewMode(), .cursor = cursor.pos, ... })
```

## Validation Loop

> **CRITICAL**: ALL Zig build/test commands MUST use `-Doptimize=ReleaseFast`. Debug hits the
> `R_X86_64_PC64` linker bug with the bundled ghostty C++ SIMD libs (PRD §15). The #1 build gotcha.

### Level 1: Syntax & Type Check (Immediate Feedback)

```bash
# After creating src/tui/select.zig + the main.zig import line — compile the test target.
zig build test -Doptimize=ReleaseFast
# Expected: compiles cleanly. A non-exhaustive `switch (action)` on input.Action (8 variants) or
# `switch (self.mode)` (3 variants) ⇒ compile error naming the missing variant (a BUILT-IN
# checklist). A type mismatch between extent()'s return and view.Selection (e.g. wrong field
# names/types) surfaces here too. Fix BEFORE running tests further.
```

### Level 2: Unit Tests (Component Validation)

```bash
# Run the full test suite (ReleaseFast MANDATORY). select.zig tests run as SEPARATE fns
# (no Terminal ⇒ no cross-test GOTCHA), so a failure points at exactly one test.
zig build test -Doptimize=ReleaseFast
# Expected: ALL tests pass (existing + new select.zig tests). If a select.zig test fails, READ
# the assertion + the expected Sel state from the test name + design_notes §2/§6, then fix.

# To focus debugging on select.zig only:
zig build test -Doptimize=ReleaseFast --test-filter "select"   # (or "extent", "applyAction", etc.)
# (Zig's test runner supports --test-filter <substring> to run only matching tests.)
```

### Level 3: Integration Testing (System Validation)

```bash
# select.zig has NO I/O (PURE) — there is no service to start or endpoint to hit. Its "integration"
# is reaching it from the test root. The one-line main.zig edit IS the integration. Confirm:
zig build test -Doptimize=ReleaseFast  # passes ⇒ select.zig tests are reachable + green

# Build the binary itself still compiles (select.zig is imported by main's test block only; the
# exe path is unaffected, but confirm there's no stray import that breaks the build):
zig build -Doptimize=ReleaseFast
# Expected: builds zig-out/bin/tmux-2html with no errors.
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Exhaustiveness check: the switch on input.Action (8 variants) + Mode (3 variants) is enforced by
# the Zig compiler — a green build == exhaustive dispatch.

# Semantic spot-check (manual reasoning against PRD §7.4 + design_notes §2, encoded as tests):
#   * default Sel ⇒ active()==false; extent(_)==null.
#   * applyAction(.visual_toggle) on inactive ⇒ begin linewise: anchor==cursor==cursor arg.
#   * active linewise + .visual_toggle ⇒ block, endpoints UNCHANGED.
#   * extent(80) linewise with anchor (5,2), cursor (9,7) ⇒ {0,2,79,7,false} (min/max y, x=0/79).
#   * extent(80) block with anchor (9,7), cursor (5,2) ⇒ {5,2,9,7,true} (order-independent min/max).
#   * .swap_end on active swaps anchor↔cursor; on inactive ⇒ NO-OP (endpoints unchanged).
#   * .clear ⇒ mode .none ⇒ extent⇒null.  .quit/.confirm ⇒ Sel UNCHANGED.
# All of the above MUST be present as named test fns (Task 3) and pass.
```

## Final Validation Checklist

### Technical Validation

- [ ] `zig build test -Doptimize=ReleaseFast` passes (zero test failures).
- [ ] `zig build -Doptimize=ReleaseFast` builds the binary with no errors.
- [ ] No new compiler warnings from select.zig.

### Feature Validation

- [ ] `Sel` defaults inactive; `active()`/`clear()`/`toggle()`/`swapEnds()` behave per design_notes §1/§2.
- [ ] `v` begins linewise (anchor=cursor=cursor) when inactive; toggles linewise↔block when active.
- [ ] `V` linewise, `Ctrl-v`/`R` block (begin when inactive; switch mode — endpoints kept — when active).
- [ ] `o`/`O` swap anchor↔cursor when active; NO-OP when inactive.
- [ ] `Esc` (clear) sets mode .none; the clear-vs-quit decision stays in region.zig (NOT select.zig).
- [ ] `extent(cols)` returns null when inactive; normalizes either endpoint order to the correct
      linewise `{0,min,cols-1,max,false}` / block `{min,min,max,max,true}` `view.Selection`.
- [ ] `viewMode()` maps none→.none, linewise→.line, block→.block.
- [ ] `applyAction` leaves the Sel untouched for `.quit`/`.confirm`.

### Code Quality Validation

- [ ] select.zig imports ONLY `std` + `view.zig` + `input.zig` (NO `ghostty-vt`, NO `motion.zig`).
- [ ] REUSES `view`'s Pos/Selection/SelMode (NO duplicate types); anchor/cursor are `view.Pos`.
- [ ] Consumes `input.Action` as-is (NO re-decoding).
- [ ] `switch` on `Mode` (3) and `input.Action` (8) is exhaustive (compiler-enforced).
- [ ] NEVER constructs a `Terminal` (PURE ⇒ separate test fns are SAFE).
- [ ] Only ONE new line added to main.zig; the PARALLEL motion.zig line is left untouched; NO other
      source file modified.

### Documentation & Deployment

- [ ] Module-level `//!` doc comment explains the layering (consumes input.Action + reuses view;
      produces the Sel MODEL + extent for view overlay + S2) — mirror input.zig/view.zig doc style.
- [ ] The o/O equivalence + toggle-on-.none-is-no-op + Esc clear-vs-quit-is-handler's are documented
      as deliberate TUI decisions (matching PRD §7.4 + design_notes).

---

## Anti-Patterns to Avoid

- ❌ Don't re-implement key DECODING — `input.zig` (S1) is the CONTRACT; consume `input.Action`.
- ❌ Don't redefine `Pos`/`Selection`/`SelMode` — REUSE `view`'s (single source of truth).
- ❌ Don't import `render.zig`/`cli.zig`/`motion.zig`/`ghostty-vt` — select.zig is PURE + decoupled.
- ❌ Don't construct a `Terminal` (the cross-test GOTCHA) — select.zig is value-structs + pure fns.
- ❌ Don't add quit/confirm logic to `applyAction` — those are region.zig's loop concern (empty arm).
- ❌ Don't make `applyAction(.clear)` quit — it ONLY clears; clear-vs-quit is the handler's decision.
- ❌ Don't model the vim o-vs-O corner distinction — PRD §7.4 treats them identically (swapEnds).
- ❌ Don't do grid-aware clamping/wide-cell rounding — that's S2 (P3.M2.T2.S2); extent() is pure arithmetic.
- ❌ Don't forget the `cols==0` guard on `cols-1` (u32 underflow avoidance) in `extent()`.
- ❌ Don't touch the PARALLEL motion.zig file or its main.zig import line — add ONLY select's line.
- ❌ Don't skip ReleaseFast — `zig build test` WITHOUT `-Doptimize=ReleaseFast` fails to LINK.

---

## Confidence Score

**9/10** — Exceptionally well-scoped: both upstream contracts (`input.Action` from S1, `view`'s
Pos/Selection/SelMode from P3.M1.T2) are SHIPPED, and view.normSel already normalizes arbitrary
endpoint order — so select.zig is a thin, PURE model that EMITS the very `view.Selection` view
already consumes. The complete API + per-action state table + extent geometry + S1/S2 boundary +
testing matrix are authored in `research/design_notes.md`. The deliverable is ONE new PURE file
(no Terminal ⇒ no cross-test GOTCHA) + ONE import line. The only residual risk is getting the
o/O-on-inactive (no-op) and V/Ctrl-v-switch-mode (endpoints preserved) branches exactly right —
but these are fully enumerated with deterministic test cases. `-Doptimize=ReleaseFast` is the
single build criticality, and the PARALLEL motion.zig work is decoupled (no import, distinct
main.zig line).
