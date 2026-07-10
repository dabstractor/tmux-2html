name: "P3.M2.T2.S2 — Coordinate → Selection (pin) conversion; clamp + wide-cell rounding (src/render.zig)"
description: |
  The TUI→ghostty SELECTION BRIDGE. Consumes the S1 `select.Sel.extent(cols)` CONTRACT (being
  implemented in parallel) + the LOADED screen + the SHIPPED `render.buildSelection` recipe
  (P1.M4.T1.S1) and produces a native ghostty `Selection` for the confirm-render path (P3.M3.T1.S2).
  ADDS to `src/render.zig`: `pub fn toGhosttySelection(sel, screen, cols) Selection` (infallible;
  clamps x→[0,cols-1]/y→[0,gridLastRow] instead of erroring like the CLI path, then REUSES
  buildSelection's point.Point→pages.pin→Selection.init recipe), a PURE `pub fn clampExtent(ext,
  cols, last_row) cli.SelectionCoords` (the 1:1 view.Selection→cli.SelectionCoords bridge +
  clamp + normalize; unit-testable w/o a Terminal), and two tiny private helpers (`gridLastRow`,
  `wholeGridSelection`). Wide-cell atomicity is DELEGATED to the formatter (VERIFIED: it rounds
  start_x back from spacer_tail + skips spacers in emission) — S2 does NOT hand-roll rounding.
  Two new imports in render.zig (select.zig + view.zig; both one-way, cycle-free). NO new file,
  NO build change, NO edit to buildSelection/select.zig/view.zig/cli.zig/main.zig.

---

## Goal

**Feature Goal**: Bridge the PURE TUI selection model (`select.Sel`, P3.M2.T2.S1) to ghostty's
grid-aware, Pin-based `Selection` so the region TUI's confirm action can render the user's
linewise/block selection to HTML. Specifically: read `sel.extent(cols)` (the already-normalized
linewise/block geometry), CLAMP the coordinates to the loaded grid's bounds (instead of rejecting
out-of-range selections like the CLI `--selection` path), and build the native `Selection` by
REUSING the exact P1.M4.T1.S1 recipe (`point.Point{.screen=...}` → `screen.pages.pin(pt)` →
`Selection.init(sp, ep, rect)`). PRD §13's "wide cells selected atomically (round to cell
boundaries)" is satisfied by DELEGATION to ghostty's formatter (verified primary-source), NOT by
hand-rolled rounding in tmux-2html.

**Deliverable**: `src/render.zig` MODIFIED — (1) two new imports (`tui/select.zig`, `tui/view.zig`);
(2) `pub fn toGhosttySelection(sel: select.Sel, screen: *const Screen, cols: u16) Selection`
(infallible; clamp + reuse buildSelection); (3) `pub fn clampExtent(ext: view.Selection, cols: u16,
last_row: u32) cli.SelectionCoords` (PURE clamp+normalize helper); (4) private `fn gridLastRow(screen)
u32` + `fn wholeGridSelection(screen) Selection`; (5) `clampExtent` tests as SEPARATE `test` fns +
`toGhosttySelection`/wide-cell assertions APPENDED to render.zig's single Terminal test scope.
**No other source file changes.** `buildSelection` is REUSED unchanged; select.zig/view.zig/cli.zig/
main.zig/build.zig untouched.

**Success Definition**:
- `toGhosttySelection(sel, screen, cols)` returns a ghostty `Selection` whose start/end pins
  round-trip (via `pointFromPin`) to the CLAMPED extent coords, with `rectangle` matching the mode.
- A linewise `sel` over rows 1..5 of a 6-row grid ⇒ a Selection that, when formatted, emits R1..R5
  and NOT R0 (reuses the S1 golden shape).
- A block `sel` over cols 2..5 rows 0..2 ⇒ a rectangle Selection that emits `CDEF`, not full rows.
- A `sel` whose cursor.y is BEYOND the grid (e.g. 100 on a 6-row grid) ⇒ CLAMPED (no
  `error.OutOfRange`), whereas the CLI `--selection` path rejects out-of-range coords. This is the
  behavioral delta that makes the TUI confirm path robust.
- A selection whose START lands on a wide glyph's spacer_tail ⇒ the formatted output contains the
  WHOLE glyph exactly once (the formatter rounds back; S2 does nothing special) — PRD §13 satisfied.
- An INACTIVE `sel` ⇒ a whole-grid Selection (defensive; the confirm site only calls when active).
- `zig build -Doptimize=ReleaseFast` links; `zig build test -Doptimize=ReleaseFast` green; existing
  tests + the whole-grid/CLI `--selection` path byte-identical (no regression).

## User Persona (if applicable)

**Target User**: tmux user in the interactive `region` copy-mode overlay (PRD §7) selecting a
linewise or rectangular region of captured scrollback to render to HTML.

**Use Case**: The user presses `v`, moves the cursor to extend a selection, switches to block with
`Ctrl-v`, then `Enter` to render. On `Enter`, region.zig (P3.M3.T1.S2) calls
`toGhosttySelection(sel, screen, cols)` to turn the live TUI selection into a ghostty `Selection`
and renders it. Wide glyphs (CJK/emoji) at the selection boundary are captured whole.

**User Journey**: (wired by P3.M3.T1.S2, which OWNS the confirm loop) — `select.applyAction` builds
the `Sel`; motion extends `sel.cursor`; on `confirm`: `sel.active()` ⇒ `toGhosttySelection(sel,
screen, viewport.cols)` ⇒ ghostty Selection ⇒ renderGrid/ScreenFormatter ⇒ HTML + `.last-output`
sidecar. **Pain Points Addressed**: faithful vim linewise/block selection rendered exactly;
CJK/emoji never split across the selection boundary; the TUI never crashes on an out-of-range
selection (it clamps).

## Why

- **Closes the TUI→render seam.** S1 ships the PURE model (`Sel.extent`); the formatter/`renderGrid`
  speak ghostty's Pin-based `Selection`. S2 is the ONLY thing that converts between them at confirm
  time. Without it, the decoded+modeled selection cannot be rendered.
- **Reuses, never duplicates.** The coordinate→Pin→Selection recipe ALREADY exists as the PUBLIC
  `render.buildSelection` (P1.M4.T1.S1). S2 calls it — it does NOT re-implement pin/Selection logic.
  S2's only NEW logic is the CLAMP (defensive grid-bounds normalization) + the `sel.extent`→coords
  bridge + grid-row discovery.
- **Correctly scopes wide-cell handling.** Primary-source research (`src/ghostty_format.zig`)
  PROVES the formatter already rounds start_x back from a wide cell's `spacer_tail` and skips
  spacers in emission ⇒ glyphs are never split. S2 deliberately does NOT round (rounding here would
  double-round against the formatter and risk off-by-one). This is the key insight that keeps S2 a
  small, safe, 1-point task — and it MUST be respected by the implementer.
- **Unblocks P3.M3.T1.S2.** The confirm path consumes `toGhosttySelection`'s output (a ghostty
  `Selection`), either via a new `renderGrid` `?Selection`-taking path or by formatting the loaded
  screen through `ScreenFormatter` directly. S2 is that path's input.

## What

A new public function + a PURE helper (+ 2 private helpers) in `src/render.zig`:
- `toGhosttySelection(sel: select.Sel, screen: *const Screen, cols: u16) Selection` — reads
  `sel.extent(cols)`; if null (inactive) ⇒ whole-grid Selection; else clamps via `clampExtent` and
  builds via `buildSelection` (clamped ⇒ in-range ⇒ `buildSelection` cannot error). Infallible.
- `clampExtent(ext: view.Selection, cols: u16, last_row: u32) cli.SelectionCoords` — PURE: clamp
  x→[0,cols-1], y→[0,last_row], re-normalize order (defensive min/max), pass `rect` through. The
  1:1 `view.Selection`→`cli.SelectionCoords` bridge (the two structs are field-identical).
- `gridLastRow(screen) u32` (private) — the loaded screen's last row index (mirrors view.zig's
  `total_rows` computation: `getBottomRight(.screen)` + `pointFromPin`).
- `wholeGridSelection(screen) Selection` (private) — untracked top-left..bottom-right Selection
  (the inactive/error fallback; matches the formatter's null-selection = whole-grid semantics).

### Success Criteria

- [ ] `toGhosttySelection` imports `select.Sel` + `view.Selection` + `cli.SelectionCoords` +
      `Screen`/`Selection`/`point` (all already in render.zig's scope) and compiles.
- [ ] A linewise `sel` ⇒ `Selection.init(pin(0,r1), pin(cols-1,r2), false)`; start/end pins
      round-trip via `pointFromPin` to `{0,r1}`/`{cols-1,r2}`, `rectangle==false`.
- [ ] A block `sel` ⇒ `Selection.init(pin(c1,r1), pin(c2,r2), true)`; `rectangle==true`.
- [ ] A `sel` with coords BEYOND the grid (y past last row) ⇒ CLAMPED to gridLastRow; NO
      `error.OutOfRange` (the TUI path is robust; the CLI path still errors — both unchanged).
- [ ] A `sel` whose extent START lands on a wide glyph's `spacer_tail` ⇒ formatting the Selection
      emits the WHOLE glyph exactly once (delegated rounding; verified).
- [ ] An INACTIVE `sel` (`extent` ⇒ null) ⇒ a whole-grid Selection (not a crash).
- [ ] The returned Selection is UNTRACKED (`Selection.init`); the caller does NOT call `deinit`
      (no-op + needs `*Screen`) — documented, matching `buildSelection`'s invariant.
- [ ] `clampExtent` is PURE (no Terminal) and covered by SEPARATE `test` fns.
- [ ] `zig build test -Doptimize=ReleaseFast` green; `zig build -Doptimize=ReleaseFast` links;
      existing whole-grid + CLI `--selection` renders byte-identical (no regression).

## All Needed Context

### Context Completeness Check

_If someone knew nothing about this codebase, would they have everything needed to implement this
successfully?_ **YES.** This PRP embeds: the exact S1 `Sel.extent` contract (with field types + the
linewise/block geometry formulas); the EXACT `buildSelection` recipe to reuse (verbatim source +
file:line); the verbatim primary-source proof that the formatter handles wide-cell atomicity (the
two formatter code blocks + line numbers); the clamp math; the grid-row discovery pattern (copied
from view.zig); the verified cycle-free import graph; the cross-test GOTCHA and where each test
must live; and the precise build/test commands.

### Documentation & References

```yaml
# MUST READ — the COMPLETE build spec for THIS subtask (authored from primary source).
- docfile: plan/001_0c8587f91cb2/P3M2T2S2/research/design_notes.md
  why: The full API (verbatim Zig), the per-fn semantics, the wide-cell delegation proof, the
       reused recipe, the import graph, the gotchas, and the testing matrix. This IS the spec.
  section: "§1 The public API" + "§2 WIDE-CELL ROUNDING IS DELEGATED" + "§6 Testing strategy"

- file: src/render.zig
  why: (a) `buildSelection` (line 191) is the RECIPE to REUSE — call it, do NOT modify it.
       (b) renderGrid's sel param + the single Terminal test scope (the cross-test GOTCHA).
       (c) the existing imports + where to add `select`/`view`.
  pattern: "buildSelection(screen, coords) error{OutOfRange}!Selection guards x>maxInt(u16), builds
            point.Point{.screen=.{.x=@intCast(x),.y=y}}, calls screen.pages.pin(pt) orelse
            error.OutOfRange, returns Selection.init(sp,ep,rect). UNTRACKED; NO deinit."
  gotcha: "buildSelection RETURNS error.OutOfRange on out-of-range — S2's clamp makes that
           unreachable. Do NOT change buildSelection to clamp (the CLI path must keep erroring).
           S2 wraps buildSelection with clampExtent so the TUI path is infallible."

- file: src/ghostty_format.zig   # the vendored formatter — PRIMARY SOURCE for the wide-cell finding
  why: PROVES wide-cell atomicity is the FORMATTER's job (NOT S2's). Two mechanisms:
       (1) start boundary rounds back from spacer_tail (~line 808, PageFormatter.formatWithState):
             switch (cells[start_x].wide) { .spacer_tail => start_x - 1, .spacer_head => continue, ... }
       (2) spacers emit NOTHING (~line 1019, the per-cell emit loop):
             switch (cell.wide) { .narrow,.wide=>{}, .spacer_head,.spacer_tail=>continue }
       The PageFormatter doc (~line 685) states it explicitly.
  critical: "DO NOT hand-roll wide-cell rounding in S2 — the formatter already does it; rounding
             here would double-round and risk off-by-one glyph splits. S2 = clamp + recipe ONLY."

- file: src/tui/select.zig   # S1 (PREDECESSOR, parallel) — CONSUME as a CONTRACT
  why: `Sel.extent(cols: u16) ?view.Selection` is S2's INPUT. linewise ⇒ {x1=0,y1=min,y2=max,
       x2=cols-1,rect=false}; block ⇒ {x1=min(ax,cx),y1=min(ay,cy),x2=max(ax,cx),y2=max(ay,cy),
       rect=true}; null when mode==.none (inactive). Assume it ships EXACTLY thus (S1 PRP).
  pattern: "extent is PURE min/max (no grid access) + the guarded cols-1 for linewise x2. S2 reads
            it; S2 does NOT re-derive geometry or touch Sel's methods."
  gotcha: "select.zig is PURE (no ghostty-vt, no Terminal) — do NOT add Selection/pin logic there.
           The bridge lives in render.zig (which has ghostty + buildSelection)."

- file: src/tui/view.zig
  why: `view.Selection = struct{ x1,y1,x2,y2: u32, rect: bool = false }` (view.zig:54) — STRUCTURALLY
       IDENTICAL to cli.SelectionCoords (cli.zig:35). clampExtent is the 1:1 bridge. ALSO: view.zig's
       `total_rows` computation (getBottomRight(.screen)+pointFromPin) is the pattern gridLastRow
       copies (view.zig render(), ~line 110).
  gotcha: "view.Viewport.cols is u16; point.Coordinate.x is u16 (point.zig:75); .y is u32. clampExtent's
           cols param is u16; widen via @as(u32,cols) AFTER the cols==0 guard before the -1."

- file: src/cli.zig
  why: `cli.SelectionCoords = struct{ x1,y1,x2,y2: u32, rect: bool = false }` (cli.zig:35) — the
       target struct clampExtent returns (and buildSelection consumes). Do NOT modify it.
  gotcha: "cli.zig → render.zig is an EXISTING lazy cycle (cli.zig:3, documented). render.zig →
           select.zig → view.zig/input.zig/app.zig does NOT cycle back to render.zig (verified)."

# ghostty primary source (in zig-pkg/) — read to CONFIRM the API, then cite.
- file: zig-pkg/ghostty-1.3.1-.../src/terminal/Selection.zig
  why: `init(start_pin,end_pin,rect) Selection` (line 55) creates UNTRACKED bounds; `deinit(self,
        s:*Screen)` (line 69) is a NO-OP for untracked AND needs a MUTABLE *Screen. ⇒ caller does
        NOT deinit. start/end may be in ANY order (formatter normalizes via order/topLeft, line 200/151).
- file: zig-pkg/ghostty-1.3.1-.../src/terminal/PageList.zig
  why: `pin(pt: point.Point) ?Pin` (line 3875) returns null iff x>=cols OR down(y) fails ⇒ after S2's
        clamp, pin NEVER returns null. `getBottomRight(.screen) ?Pin` (line 4943) = last page's
        (rows-1,cols-1); `getTopLeft(.screen) Pin`; `pointFromPin(.screen, pin) ?Point` (line 3980).
- file: zig-pkg/ghostty-1.3.1-.../src/terminal/point.zig
  why: `point.Point = union(Tag){ .screen: Coordinate }`; `Coordinate{ x: size.CellCountInt=u16,
        y: u32 }` (line 66-80). Construction: `point.Point{ .screen = .{ .x=@intCast(x), .y=y } }`.
- file: zig-pkg/ghostty-1.3.1-.../src/terminal/page.zig
  why: `Cell.Wide = enum(u2){ narrow=0, wide=1, spacer_tail=2, spacer_head=3 }` (line 2026) — the
        wide-cell states the formatter switches on (confirming §2's delegation).

- docfile: plan/001_0c8587f91cb2/architecture/render_pipeline.md
  why: §4 "Selection → formatter" — the VERIFIED coordinate→Pin→Selection pipeline (the recipe) +
       the linewise/block mapping (PRD §7.4). §7 confirms "selection rounds to cell boundaries
       (wide cells atomic)" is handled by ghostty cell widths.
  section: "§4 Selection → formatter" + "§7 Output fidelity"
- docfile: plan/001_0c8587f91cb2/architecture/findings_and_corrections.md
  why: §0.2 (Selection is Pin-based, not coord-based; build via screen.pages.pin + Selection.init;
        untracked; NO deinit) — the authoritative correction the recipe implements.
  section: "§0.2 Selection is NOT constructed from raw x/y tuples"

- url: https://ghostty.org/docs/api  # (context only; the v1.3.1 source in zig-pkg/ is authoritative)
  why: ghostty VT API reference. The pinned source in zig-pkg/ (Selection.zig/PageList.zig/point.zig)
       is the GROUND TRUTH for this Zig 0.15.2 + ghostty 1.3.1 build — prefer it over web docs.
```

### Current Codebase tree (run `tree src/` in the project root)

```bash
$ tree src/ -I 'zig-cache' --dirsfirst
src/
├── tui/
│   ├── app.zig        # P3.M1.T1 — Event/Input/readEvent + alt-screen + mouse (SHIPPED; imports std only)
│   ├── input.zig      # P3.M2.T1.S1 — key DECODER: Key/Motion/Action/Search (SHIPPED; imports app.zig)
│   ├── view.zig       # P3.M1.T2 — render + highlight + findMatches + Pos/Viewport/Selection/SelMode (SHIPPED — REUSE types)
│   ├── select.zig     # P3.M2.T2.S1 — PURE selection MODEL: Sel/extent/applyAction (PARALLEL — CONSUME extent as CONTRACT)
│   └── motion.zig     # P3.M2.T1.S2 — PURE cursor NAVIGATION (PARALLEL — do NOT touch/import)
├── capture.zig        # P2.M1 — pane capture
├── cli.zig            # parg parser + SelectionCoords (the clamp target struct; ≡ view.Selection)
├── ghostty_format.zig # vendored Cell→Style HTML formatter (PRIMARY SOURCE for the wide-cell finding)
├── golden_test.zig    # P1.M4 golden harness
├── main.zig           # dispatch + top-level test{} block (UNCHANGED)
├── palette.zig        # P1.M2 — queryColors + cache + resolve
└── render.zig         # P1.M3/P1.M4 — renderGrid + buildSelection (the RECIPE) ← THIS SUBTASK EDITS
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
src/
├── tui/
│   └── ... (ALL UNCHANGED — select.zig consumed as a contract; view.zig's Selection reused)
└── render.zig           # EDIT: +2 imports, +toGhosttySelection, +clampExtent, +gridLastRow,
                         #       +wholeGridSelection, +clampExtent tests, +toGhosttySelection test block
```

`src/render.zig` new responsibilities (the ONLY edited file):
- `toGhosttySelection(sel, screen, cols) Selection` — the TUI→ghostty Selection bridge (public).
- `clampExtent(ext, cols, last_row) cli.SelectionCoords` — PURE clamp+normalize (public; testable).
- `gridLastRow(screen) u32` + `wholeGridSelection(screen) Selection` — private helpers.
- Tests: `clampExtent` as separate (PURE) `test` fns; `toGhosttySelection` assertions APPENDED to
  the single Terminal test scope.

### Known Gotchas of our codebase & Library Quirks

```zig
// CRITICAL: zig build test MUST use -Doptimize=ReleaseFast. Debug hits the R_X86_64_PC64 linker
//   bug with the bundled ghostty C++ SIMD libs (PRD §15; confirmed across all sibling PRPs).
//   EVERY validation command in this PRP uses `zig build test -Doptimize=ReleaseFast`.

// CRITICAL: WIDE-CELL ROUNDING IS THE FORMATTER'S JOB — NOT S2's. Verified primary-source
//   (src/ghostty_format.zig): PageFormatter rounds start_x back from spacer_tail (~line 808) and
//   skips spacers in emission (~line 1019). DO NOT inspect cell.wide or round coords in S2; that
//   would double-round against the formatter and risk off-by-one glyph splits. S2 = clamp + recipe.

// CRITICAL: the cross-test GOTCHA — ghostty-vt Terminal.init corrupts process-global state such
//   that a Terminal.init in a SEPARATE test fn CRASHES (core dump). toGhosttySelection/gridLastRow/
//   wholeGridSelection touch the screen ⇒ their tests MUST share render.zig's SINGLE Terminal test
//   scope (the "renderGrid: red foreground..." test, where S1's lw/block/out-of-range assertions
//   already live). APPEND there; do NOT add a new Terminal-building test fn. clampExtent is PURE
//   (no Terminal) ⇒ its tests ARE separate fns (mirrors determineCols/lineCount).

// CRITICAL: buildSelection RETURNS error{OutOfRange} — do NOT modify it (the CLI --selection path
//   must keep erroring on out-of-range coords). S2 wraps it: clampExtent guarantees in-range ⇒
//   buildSelection cannot error ⇒ `catch wholeGridSelection(screen)` is a defensive no-UB fallback.

// CRITICAL: Selection.init creates UNTRACKED bounds (no heap). Selection.deinit is a NO-OP for
//   untracked AND requires a MUTABLE *Screen the caller lacks (t.screens.active is *const). So the
//   caller does NOT call deinit — identical to buildSelection's existing invariant. The contract's
//   "Deinit by caller" = the caller owns the value's lifetime; for the untracked value that's a no-op.

// CRITICAL: REUSE buildSelection — do NOT re-implement pin/Selection logic. REUSE select.Sel.extent
//   — do NOT re-derive geometry. REUSE view.Selection/cli.SelectionCoords — do NOT redefine types.

// CRITICAL: render.zig → select.zig is a NEW, one-way dependency (verified cycle-free: select→
//   {view,input→app(std)}, none point back to render). It is INTENTIONAL for DRY reuse of
//   buildSelection + faithfulness to toGhosttySelection(sel, screen, cols). Import is LAZY (render/
//   pane paths never reference select) ⇒ zero runtime cost. Document the import's purpose.

// CRITICAL: u32 min/max only in clampExtent; no underflowing subtracts. The lone subtract is
//   `cols - 1` (cols is u16) — widen via @as(u32, cols) AFTER the `cols == 0` guard. x/y are u32
//   (always >= 0); clamp the HIGH side only (@min(coord, bound)).

// CRITICAL: getBottomRight(.screen) does self.pages.last.? — panics if pages.last is null. An
//   initialized Terminal ALWAYS has >=1 page, so it is safe for any screen region.zig/tests build.
//   wholeGridSelection's `orelse tl` guards the pointFromPin step, not the internal .?.
```

## Implementation Blueprint

### Data models and structure

No new types. S2 reuses: `select.Sel` + `select.Sel.extent` (S1), `view.Selection` + `view.Pos`
(view.zig), `cli.SelectionCoords` (cli.zig), and `Screen`/`Selection`/`point`/`Pin` (ghostty-vt,
already imported by render.zig). Verbatim from `research/design_notes.md §1`:

```zig
// ---- add to src/render.zig imports (after `const cli = @import("cli.zig");` ~line 23) ----
const select = @import("tui/select.zig"); // P3.M2.T2.S1: Sel.extent — the TUI selection model (CONSUME)
const view = @import("tui/view.zig");     // P3.M1.T2: view.Selection — structurally == cli.SelectionCoords

// ---- the public bridge (near buildSelection, ~line 199) ----

/// Convert a TUI selection model into a native ghostty `Selection` against the LOADED screen,
/// clamping to the grid and DELEGATING wide-cell atomicity to the formatter (PRD §13). REUSES the
/// P1.M4.T1.S1 recipe via `buildSelection`. Infallible (clamped ⇒ buildSelection cannot error).
/// UNTRACKED result; caller does NOT deinit (no-op + needs *Screen — see buildSelection's GOTCHA).
/// An INACTIVE sel (extent ⇒ null) yields a whole-grid Selection (formatter null-selection semantics).
pub fn toGhosttySelection(sel: select.Sel, screen: *const Screen, cols: u16) Selection {
    const ext = sel.extent(cols) orelse return wholeGridSelection(screen);
    const coords = clampExtent(ext, screen.pages.cols, gridLastRow(screen));
    return buildSelection(screen, coords) catch wholeGridSelection(screen); // clamped ⇒ unreachable
}

/// PURE: clamp a (normalized) `view.Selection` extent to grid bounds → `cli.SelectionCoords`.
/// x→[0,cols-1]; y→[0,last_row]; re-normalize order (defensive). cols==0 ⇒ x collapses to 0.
/// view.Selection ≡ cli.SelectionCoords ({x1,y1,x2,y2:u32, rect:bool=false}); this is the 1:1 bridge.
pub fn clampExtent(ext: view.Selection, cols: u16, last_row: u32) cli.SelectionCoords {
    const last_col: u32 = if (cols == 0) 0 else @as(u32, cols) - 1;
    const nx1 = @min(ext.x1, ext.x2); // normalize order (defensive — select.extent already min/max's)
    const nx2 = @max(ext.x1, ext.x2);
    const ny1 = @min(ext.y1, ext.y2);
    const ny2 = @max(ext.y1, ext.y2);
    return .{
        .x1 = @min(nx1, last_col), // u32 >= 0 always; clamp the high side only
        .y1 = @min(ny1, last_row),
        .x2 = @min(nx2, last_col),
        .y2 = @min(ny2, last_row),
        .rect = ext.rect,
    };
}

/// The last row index of the loaded screen (0-based). Mirrors view.zig's total_rows computation.
fn gridLastRow(screen: *const Screen) u32 {
    const br = screen.pages.getBottomRight(.screen) orelse return 0;
    const br_pt = screen.pages.pointFromPin(.screen, br) orelse return 0;
    return br_pt.coord().y; // last row index (total_rows = y+1)
}

/// A whole-grid (untracked) Selection — the inactive/error fallback.
fn wholeGridSelection(screen: *const Screen) Selection {
    const tl = screen.pages.getTopLeft(.screen);
    const br = screen.pages.getBottomRight(.screen) orelse tl;
    return Selection.init(tl, br, false); // untracked; no deinit
}
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: EDIT src/render.zig — add the two imports
  - ADD after `const cli = @import("cli.zig");` (~line 23):
        const select = @import("tui/select.zig"); // P3.M2.T2.S2: Sel.extent — the TUI selection model
        const view   = @import("tui/view.zig");   // view.Selection (structurally == cli.SelectionCoords)
  - VERIFY no cycle: select.zig→{view,input→app(std)}; view.zig→{ghostty-vt,palette}; neither → render.
  - GOTCHA: do NOT import motion.zig/input.zig/app.zig directly — reach them transitively via select.

Task 2: ADD the PURE clampExtent helper (+ its private gridLastRow/wholeGridSelection) near buildSelection
  - IMPLEMENT clampExtent EXACTLY as the data-model block above (verbatim from design_notes §1).
  - IMPLEMENT gridLastRow + wholeGridSelection (private) as in design_notes §1b.
  - GOTCHA: clampExtent uses @min/@max only; the lone subtract `cols-1` is guarded by `cols==0` and
    widened via @as(u32,cols). x/y are u32 (>=0); clamp HIGH side only. cols is u16 (screen.pages.cols).
  - GOTCHA: gridLastRow copies view.zig's getBottomRight+pointFromPin pattern; the `orelse return 0`
    guards empty/degenerate screens (never happens for an initialized Terminal, but defensive).
  - NAMING: clampExtent/gridLastRow/wholeGridSelection (camelCase, matching render.zig style).

Task 3: ADD the public toGhosttySelection bridge
  - IMPLEMENT toGhosttySelection EXACTLY as the data-model block (verbatim from design_notes §1).
  - REUSE: `sel.extent(cols)` (S1 contract), `clampExtent` (Task 2), `buildSelection` (existing).
  - GOTCHA: `orelse return wholeGridSelection(screen)` for the inactive (extent null) case — do NOT
    panic on null. `catch wholeGridSelection(screen)` is a defensive no-UB fallback (clamped ⇒ unreachable).
  - GOTCHA: do NOT call Selection.deinit; the result is untracked (document on the fn, mirror buildSelection).

Task 4: ADD clampExtent tests as SEPARATE `test` fns (PURE — no Terminal ⇒ safe per the cross-test GOTCHA)
  - COVER the matrix in design_notes §6a: linewise passthrough; block passthrough; x-clamp-high;
    y-clamp-high; cols==0 guard; order-normalization (reversed input); rect preserved; last_row==0.
  - PATTERN: mirror render.zig's determineCols/lineCount tests — `try std.testing.expectEqual(...)`.
    Build view.Selection literals `.{ .x1=.., .y1=.., .x2=.., .y2=.., .rect=.. }`; assert cli.SelectionCoords.

Task 5: APPEND toGhosttySelection/gridLastRow/wholeGridSelection assertions to render.zig's SINGLE
        Terminal test (the "renderGrid: red foreground..." test — cross-test GOTCHA)
  - COVER design_notes §6b: build a Terminal (in the shared scope), feed ANSI, set up a select.Sel by
    hand (`.anchor`/`.cursor`/`.mode` — NO input/motion import), call toGhosttySelection, verify.
  - VERIFY linewise: round-trip gs.start()/end() via screen.pages.pointFromPin(.screen, pin).coord()
    ⇒ {0,r1}/{cols-1,r2}; rectangle==false; THEN format via ScreenFormatter (f.content=.{.selection=gs})
    ⇒ HTML has R1..R5, NOT R0 (reuses the S1 golden assertion shape).
  - VERIFY block: ⇒ {c1,r1}/{c2,r2}, rectangle==true; format ⇒ HTML has "CDEF", not full rows.
  - VERIFY clamp (the delta): sel with cursor.y beyond the grid (e.g. 100 on 6 rows) ⇒ CLAMPS to
    gridLastRow (5); NO error.OutOfRange (contrast the CLI path which errors).
  - VERIFY inactive ⇒ whole-grid: sel mode=.none ⇒ gs spans top-left..bottom-right; format ⇒ full grid.
  - VERIFY wide-cell delegation: feed a wide glyph (真 U+771F, UTF-8 e7 9c 9f) at col 0 (cols 0-1; col 1
    is spacer_tail) into cols=4 rows=1; sel linewise row 0; format gs ⇒ glyph appears EXACTLY ONCE
    (formatter rounds; S2 did nothing). Proves PRD §13 satisfied by delegation.
  - PATTERN: the ScreenFormatter formatting snippet is renderGrid's body (fmt.ScreenFormatter.init +
    f.content=.{.selection=gs} + f.extra=.styles + out.print("{f}")). Use std.Io.Writer.Allocating
    (render.zig's renderSelOwned helper ALREADY does this — REUSE/extend it for a ?Selection input).
  - GOTCHA: ALL of these share the ONE Terminal-init scope — do NOT add a new test fn (cross-test crash).
```

### Implementation Patterns & Key Details

```zig
// === The reused recipe (P1.M4.T1.S1 — render.buildSelection, line 191) ===
// S2 CALLS this; it is UNCHANGED. After clampExtent, coords are always in-range ⇒ it cannot error.
//   pub fn buildSelection(screen, coords: cli.SelectionCoords) error{OutOfRange}!Selection {
//       if (coords.x1 > maxInt(u16) or coords.x2 > maxInt(u16)) return error.OutOfRange;
//       const start_pt = point.Point{ .screen = .{ .x = @intCast(coords.x1), .y = coords.y1 } };
//       const end_pt   = point.Point{ .screen = .{ .x = @intCast(coords.x2), .y = coords.y2 } };
//       const sp = screen.pages.pin(start_pt) orelse return error.OutOfRange;
//       const ep = screen.pages.pin(end_pt)   orelse return error.OutOfRange;
//       return Selection.init(sp, ep, coords.rect); // UNTRACKED; NO deinit
//   }

// === The wide-cell finding (WHY S2 does NOT round) ===
// src/ghostty_format.zig PageFormatter.formatWithState, the per-row cells_subset extraction (~line 808):
//   const row_start_x = if (start_x > 0 and (rectangle or y == start_y)) start_x: {
//       break :start_x switch (cells[start_x].wide) {
//           .spacer_tail => start_x - 1,   // round BACK to include the full wide glyph (ATOMIC)
//           .spacer_head  => continue,     // spacer_head on first row ⇒ skip the row
//           .narrow, .wide => start_x,
//       };
//   } else 0;
// ...and the per-cell emit loop (~line 1019):
//   switch (cell.wide) { .narrow,.wide => {}, .spacer_head,.spacer_tail => continue } // spacers emit nothing
// ⇒ the glyph is NEVER split. S2's pins feed this; S2 does NOT touch cell.wide. PRD §13 ✓ by delegation.

// === The clamp (S2's ONLY new arithmetic) ===
//   clampExtent clamps the HIGH side only (coords are u32 >= 0): @min(coord, bound).
//   cols-1 guarded (cols==0 ⇒ 0); y clamped to gridLastRow (= the screen's last row index, NOT the
//   written-line count — getBottomRight(.screen) returns the last page's rows-1, i.e. the full screen).
//   After clamp, x in [0,cols-1] and y in [0,gridLastRow] ⇒ pages.pin never returns null ⇒ buildSelection
//   never errors ⇒ toGhosttySelection is infallible.

// === The test verification pattern (round-trip pins → coords) ===
//   const gs = toGhosttySelection(sel, screen, cols);
//   const s = screen.pages.pointFromPin(.screen, gs.start()).?.coord(); // {x:u16, y:u32}
//   const e = screen.pages.pointFromPin(.screen, gs.end()).?.coord();
//   try testing.expectEqual(@as(u16, 0), s.x);      // linewise start x
//   try testing.expectEqual(@as(u32, r1), s.y);
//   try testing.expectEqual(false, gs.rectangle);
// (pointFromPin is the inverse of pin — PageList.zig:3980; verified.)
```

### Integration Points

```yaml
BUILD:
  - NO change. render.zig already imports ghostty-vt (Selection/Screen/point) + cli.zig. S2 adds the
    `select` + `view` imports (reached via the existing src/tui/ graph). No build.zig / build.zig.zon edit.

DOWNSTREAM_CONSUMER (NOT this subtask — for awareness; P3.M3.T1.S2 wires the confirm loop):
  - region.zig OWNS a select.Sel + a loaded Terminal/Screen. On `confirm` (and sel.active()):
      const gs = render.toGhosttySelection(sel, t.screens.active, viewport.cols);
      // then render gs to HTML. Two options for P3.M3.T1.S2 (ITS choice, NOT S2's):
      //   (a) add a renderGrid variant taking `?Selection` (bypassing buildSelection); OR
      //   (b) format t.screens.active directly via ScreenFormatter with content.selection = gs.
      // S2 only PRODUCES gs; it does NOT change renderGrid's signature.

TEST_ROOT:
  - NO main.zig change. render.zig is ALREADY imported by the test root (main.zig test block).
    toGhosttySelection/clampExtent tests live IN render.zig (its test fns are already reachable).
```

## Validation Loop

> **CRITICAL**: ALL Zig build/test commands MUST use `-Doptimize=ReleaseFast`. Debug hits the
> `R_X86_64_PC64` linker bug with the bundled ghostty C++ SIMD libs (PRD §15). The #1 build gotcha.

### Level 1: Syntax & Type Check (Immediate Feedback)

```bash
# After adding the imports + toGhosttySelection + clampExtent + helpers — compile the test target.
zig build test -Doptimize=ReleaseFast
# Expected: compiles cleanly. A type mismatch (e.g. clampExtent returning the wrong struct, or
# toGhosttySelection's return type ≠ Selection) surfaces here. A missing import (select/view)
# surfaces as "unable to find ... ". Fix BEFORE running tests further.
# Also confirm the binary still links (render.zig is in the exe path):
zig build -Doptimize=ReleaseFast
# Expected: builds zig-out/bin/tmux-2html with no errors (the new select/view imports are lazy;
# render/pane paths never reference them, so the exe is unaffected).
```

### Level 2: Unit Tests (Component Validation)

```bash
# Full suite (ReleaseFast MANDATORY). clampExtent tests are SEPARATE fns (PURE) ⇒ a failure points
# at exactly one clamp case. toGhosttySelection tests share the single Terminal scope.
zig build test -Doptimize=ReleaseFast
# Expected: ALL tests pass (existing + new clampExtent fns + the appended toGhosttySelection block).

# Focus debugging on S2 only:
zig build test -Doptimize=ReleaseFast --test-filter "clampExtent"   # the PURE clamp cases
# (Zig's test runner supports --test-filter <substring>. toGhosttySelection assertions live inside
#  the "renderGrid: red foreground..." test, so filter on "renderGrid" to reach them.)
```

### Level 3: Integration Testing (System Validation)

```bash
# S2 has NO CLI surface (it is a library fn consumed by P3.M3.T1.S2). Its "integration" is reaching
# it from the test root + the binary still linking. Confirm:
zig build test -Doptimize=ReleaseFast   # ⇒ toGhosttySelection/clampExtent reachable + green
zig build -Doptimize=ReleaseFast        # ⇒ exe links (no stray import breaks the build)

# Regression guard: the CLI --selection path (buildSelection, UNCHANGED) still behaves identically.
printf 'R0\nR1\nR2\nR3\nR4\nR5' | ./zig-out/bin/tmux-2html render --cols 80 --selection 0,1,79,5 | grep -c R5
# Expected: 1 (R5 present); and grep -c R0 ⇒ 0 (R0 excluded). Unchanged from P1.M4.T1.S1.
printf 'ABCDEFGHIJ\nABCDEFGHIJ\nABCDEFGHIJ' | ./zig-out/bin/tmux-2html render --cols 10 --selection 2,0,5,2,1 | grep -c CDEF
# Expected: 3 (CDEF on each of 3 rows). Unchanged.
# Out-of-range CLI selection STILL errors (buildSelection unchanged; S2's clamp is TUI-only):
printf 'AB' | ./zig-out/bin/tmux-2html render --cols 5 --selection 9,0,9,0 ; echo "exit=$?"
# Expected: stderr "selection out of range", exit=1. (Proves S2 did NOT weaken the CLI path.)
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Wide-cell atomicity (PRD §13) — encoded as a toGhosttySelection test (in the single Terminal scope):
# feed a wide glyph (真, U+771F) at col 0 (cols 0-1; col 1 = spacer_tail), select row 0 linewise,
# format the Selection, and assert the glyph appears EXACTLY ONCE. This PROVES the formatter rounds
# (start back from spacer_tail) + skips spacers, with S2 doing nothing special. (See Task 5.)
# The test asserts: std.mem.count(u8, html, "\xe7\x9c\x9f") == 1.

# Clamp robustness (the TUI delta) — encoded as a toGhosttySelection test: a sel with cursor.y beyond
# the grid CLAMPS (renders through the last row) instead of error.OutOfRange. (See Task 5.)
# Contrast: the CLI --selection path still errors on out-of-range (Level 3 regression guard above).
```

## Final Validation Checklist

### Technical Validation

- [ ] `zig build test -Doptimize=ReleaseFast` passes (zero test failures; existing + new).
- [ ] `zig build -Doptimize=ReleaseFast` builds the binary with no errors.
- [ ] No new compiler warnings from render.zig.

### Feature Validation

- [ ] `toGhosttySelection(sel, screen, cols)` returns a ghostty `Selection` for active linewise/block sels.
- [ ] Linewise ⇒ `{(0,r1),(cols-1,r2),rectangle=false}`; block ⇒ `{(c1,r1),(c2,r2),rectangle=true}`
      (verified by pin→pointFromPin round-trip + formatting the sub-grid HTML).
- [ ] Out-of-grid coords CLAMP (no `error.OutOfRange`) — the TUI delta vs the CLI path.
- [ ] A START on a wide glyph's `spacer_tail` ⇒ the formatted output has the WHOLE glyph once (PRD §13).
- [ ] An INACTIVE sel ⇒ a whole-grid Selection (no crash; matches formatter null-selection semantics).
- [ ] The CLI `--selection` path is byte-identical (buildSelection UNCHANGED; out-of-range still errors).

### Code Quality Validation

- [ ] REUSES `buildSelection` (NO modification), `select.Sel.extent` (NO re-derivation), `view.Selection`/
      `cli.SelectionCoords` (NO redefinition).
- [ ] Does NOT hand-roll wide-cell rounding (delegated to the formatter — documented with line refs).
- [ ] `clampExtent` is PURE (separate test fns); `toGhosttySelection` tests share the single Terminal scope.
- [ ] The `select`/`view` imports are one-way + cycle-free (documented); render/pane paths unaffected.
- [ ] u32 min/max only; `cols-1` guarded + widened; no underflowing subtracts.

### Documentation & Deployment

- [ ] `toGhosttySelection`/`clampExtent` have doc comments explaining: the recipe reuse, the clamp
      (vs the CLI error), the wide-cell DELEGATION (cite the formatter), the untracked/no-deinit
      ownership, and the inactive⇒whole-grid fallback.
- [ ] The new `select`/`view` imports have inline `why` comments (matching render.zig's import style).

---

## Anti-Patterns to Avoid

- ❌ Don't hand-roll wide-cell rounding — the formatter does it (verified); rounding here double-rounds.
- ❌ Don't modify `buildSelection` — REUSE it; the CLI path must keep erroring on out-of-range.
- ❌ Don't re-derive selection geometry — `select.Sel.extent` (S1) is the single source.
- ❌ Don't redefine `view.Selection`/`cli.SelectionCoords` — they are field-identical; clampExtent bridges.
- ❌ Don't add Selection/pin logic to `select.zig` — it is PURE (ghostty-free); the bridge is in render.zig.
- ❌ Don't construct a `Terminal` in a SEPARATE test fn (cross-test GOTCHA) — append toGhosttySelection
  assertions to render.zig's single Terminal test; clampExtent tests are separate (PURE).
- ❌ Don't call `Selection.deinit` on the result — it is UNTRACKED (no-op + needs `*Screen`); document it.
- ❌ Don't panic on `extent` returning null — an inactive sel ⇒ whole-grid (defensive).
- ❌ Don't add a CLI flag or change `renderGrid`'s signature — S2 is a library fn; wiring is P3.M3.T1.S2.
- ❌ Don't import motion.zig/input.zig/app.zig directly in render.zig — reach them via select.zig.
- ❌ Don't skip ReleaseFast — `zig build test` WITHOUT `-Doptimize=ReleaseFast` fails to LINK.
- ❌ Don't touch the PARALLEL select.zig/motion.zig files (or their main.zig import lines).

---

## Confidence Score

**9/10** — Both upstream contracts are SHIPPED-or-contractually-defined: `render.buildSelection`
(P1.M4.T1.S1) is the EXACT recipe to reuse (verbatim source in this PRP), and `select.Sel.extent`
(S1) is a clean, fully-specified contract. The load-bearing uncertainty — "does S2 need wide-cell
rounding?" — is RESOLVED by primary-source reading of the vendored formatter (`src/ghostty_format.zig`):
it rounds `start_x` back from `spacer_tail` (~line 808) and skips spacers in emission (~line 1019),
so PRD §13 is satisfied by DELEGATION (S2 does nothing special). The complete API, clamp math,
grid-row discovery (copied from view.zig), verified cycle-free import graph, the cross-test GOTCHA +
where each test lives, and the testing matrix are authored in `research/design_notes.md`. The
deliverable is a few functions + tests in ONE file (render.zig). Residual risks: (1) getting the
`orelse`/`catch` fallback semantics exactly right (inactive⇒whole-grid; defensive no-UB catch) —
fully enumerated with deterministic tests; (2) the toGhosttySelection assertions sharing the single
Terminal test scope — pattern is established (S1's lw/block/out-of-range tests already live there).
The PARALLEL S1 (select.zig) and motion.zig work are decoupled (distinct files; S2 only CONSUMES
select.Sel.extent as a contract).
