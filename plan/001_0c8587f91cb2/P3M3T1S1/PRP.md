name: "P3.M3.T1.S1 — region.zig: capture full scrollback → grid → launch TUI (NEW src/region.zig + view.zig 1-liner + main.zig/cli.zig dispatch wiring)"
description: |
  The ONE ORCHESTRATOR every TUI module (app/input/motion/select/view) is waiting for. Creates
  `src/region.zig` — `region.body`: resolve target → capture FULL scrollback (regionPrepare, the
  FakeTmux-testable core) → palette.resolve(has_tty=true) → build a ghostty Terminal/grid from the
  captured ANSI (cap.cols×cap.rows; scrollback → history pages so total_rows covers all of it) →
  pre-decode all rows into a motion.SliceGrid → enter the TUI (app.enter) → run the FULL interactive
  loop (app.runEvents with a RegionCtx handler that decodes input.feed → motion.applyMotion /
  select.applyAction / search, syncs sel.cursor←cursor.pos, repaints via view.render+renderStatus).
  Quit ⇒ exit 1 (PRD §7.5). Confirm ⇒ S1 STUB (exit non-zero; P3.M3.T1.S2 fills render+sidecar).
  WIRES the dispatch: cli.region takes a body fn pointer (mirror pane); main.zig passes region.body.
  ONE view.zig change: `fn decodeRow` → `pub fn decodeRow` (motion's Grid needs text+col; non-
  conflicting with the parallel P3.M2.T2.S2 which edits render.zig). region.zig's tests =
  regionPrepare (capture full via FakeTmux; NO Terminal ⇒ safe). body/handler/repaint = compile-
  verified + manual smoke (the TUI needs a real pty). No build.zig change.

---

## Goal

**Feature Goal**: Wire the `tmux-2html region` subcommand end-to-end per PRD §5.3 + §7 + tui_region.md
§8: capture the FULL pane scrollback (honoring `@tmux-2html-history-limit`) into a ghostty grid,
resolve the palette, enter the full-screen TUI, and hand control to the interactive loop so the TUI
**browses all of history in full color** with vim motions, linewise/block selection (`v`), search
(`/` `?` `n` `N`), and quit. This is the GLUE that consumes the shipped app/input/motion/select/view
modules — every one of which explicitly designates `region.zig (P3.M3)` as its orchestrator.

**Deliverable**:
1. **NEW FILE** `src/region.zig` — `pub fn body(allocator, opts: cli.RegionOpts) anyerror!u8` (the
   prod wrapper: capture → grid → TUI → loop); `fn regionPrepare(allocator, target, runner:
   capture.Runner) anyerror!capture.Captured` (the dir-scoped FakeTmux-testable capture core); the
   `RegionCtx` handler-state struct + `regionHandle` (the `app.EventHandler` callback: decode →
   motion/select/search → repaint) + `repaint` (view.render + view.renderStatus + flush) + the two
   search helpers + regionPrepare unit tests (FakeTmux, NO Terminal).
2. **EDIT** `src/cli.zig`: change `pub fn region(allocator, args)` (currently a `NotImplemented`
   stub) to `pub fn region(allocator, args, body: *const fn (Allocator, RegionOpts) anyerror!u8)`
   mirroring `cli.pane` EXACTLY (help → 0; parse error → 1; else `body(allocator, opts)`). **No new
   cli.zig imports.**
3. **EDIT** `src/main.zig`: add `const region = @import("region.zig");`; change the dispatch `region`
   arm to `cli.region(allocator, sub_args, region.body)`; add `_ = @import("region.zig");` to the
   test block; REMOVE/replace the now-stale `test "dispatch routes known subcommand to cli stub"`
   (region is WIRED now — it runs real tmux/tty I/O, like pane/render/sync-palette, so it cannot be
   driven from a unit test).
4. **EDIT** `src/tui/view.zig`: ONE keyword — `fn decodeRow` → `pub fn decodeRow` (line 331), so
   region can pre-decode grid rows into `motion.Row{ text, col }`. `DecodedRow` stays private
   (callers use type inference). Non-conflicting with the parallel P3.M2.T2.S2 (which edits
   render.zig, not view.zig).

**Success Definition**:
- `tmux-2html region` (run inside a `tmux display-popup`) enters the full-screen TUI and paints the
  FULL captured scrollback in color (cached palette), status line on the last row, cursor at the
  bottom (tmux copy-mode entry point).
- `h j k l` / arrows / `w b e` / `0 ^ $` / `gg G` / `Ctrl-d/u/f/b` / `H M L` / `{ }` / `%` move the
  cursor and re-scroll the viewport; counts work (`5j`).
- `v` begins linewise selection; `v` again toggles linewise↔block; `V` linewise; `Ctrl-v`/`R` block;
  `o`/`O` swap ends; motion extends; selection shown in reverse video.
- `/pattern` / `?pattern` enter search-typing (status line shows the in-progress pattern); `Enter`
  highlights matches + jumps to the first; `n`/`N` next/prev with wraparound; `Esc` cancels typing.
- `Esc` clears an active selection (stays in the TUI); `q` / `Esc`-with-no-selection / `Ctrl-c`
  exits the TUI and the process returns exit **1** with no output (PRD §7.5).
- The terminal is ALWAYS restored on exit (normal / error / signal / panic) — `app.exit`'s defer +
  the signal handler + the root panic override already guarantee this (shipped by app.zig).
- `zig build test -Doptimize=ReleaseFast` green (regionPrepare tests + all existing); `zig build
  -Doptimize=ReleaseFast` links; `region --help` prints help + exits 0; `region` with no tty prints
  "requires a terminal" + exits 1.

## User Persona (if applicable)

**Target User**: a tmux user who pressed the `region` binding (`prefix C-o` → `tmux display-popup -E
-w 100% -h 100% "$BIN region --target $TMUX_PANE"`, PRD §9.3) to interactively select a region of a
pane's scrollback and render it to HTML.

**Use Case**: browse the pane's full history in a vim-like copy-mode overlay, select a linewise or
rectangular region, confirm to render. (S1 delivers browsing + selecting + cancelling; the confirm→
render is P3.M3.T1.S2.)

**User Journey**: popup opens → colored scrollback visible at the bottom → user moves/searches/
selects → `q` cancels (popup closes via `-E`, exit 1) OR `Enter` confirms (S2 renders + writes a
sidecar the plugin `display-message`s, exit 0).

**Pain Points Addressed**: tmux's built-in capture is line-based + loses color fidelity; `region`
gives a faithful full-color vim-style overlay over the ENTIRE scrollback with both selection modes,
rendering the exact selected cells to standalone HTML.

## Why

- **Closes the TUI.** app/input/motion/select/view are all SHIPPED + tested but have NO consumer —
  region.zig is their designated orchestrator (every module's doc says so; main.zig's test comments
  call them "region.zig, its only caller, does NOT exist yet"). S1 is what makes the TUI exist.
- **Faithful to PRD §5.3 + tui_region.md §8.** region captures FULL scrollback FIRST (so the TUI
  browses all history), works purely on the in-memory grid + the popup pty, and never needs tmux
  after capture. S1 implements exactly that pipeline.
- **Clean S1↔S2 seam.** S1 wires the entire interactive loop (motion + select + search + repaint +
  quit→exit 1); S2 only fills the `.confirm` arm (toGhosttySelection → renderGrid → `.last-output`
  sidecar + output filename + `--open`). The loop, the ctx (sel/grid/colors/font/opts), and the
  confirm recognition are all in place after S1.
- **Reuses, never duplicates.** region.zig is pure GLUE: capture (P2), palette.resolve (P1.M2),
  Terminal/grid build (the renderGrid/view pattern), app.enter/exit/runEvents (P3.M1.T1),
  view.render/renderStatus/decodeRow/findMatches/scrollForCursor/scrollToBottom (P3.M1.T2),
  input.feed/Decoder (P3.M2.T1.S1), motion.applyMotion/Cursor/SliceGrid/SearchState/nextMatch/
  prevMatch (P3.M2.T1.S2), select.applyAction/Sel/extent/viewMode (P3.M2.T2). Nothing is re-implemented.

## What

A new `src/region.zig` orchestrator + the dispatch/view wiring. See `research/design_notes.md` for
the verbatim Zig (body, regionPrepare, RegionCtx, regionHandle, repaint, search helpers) — it IS the
spec. Highlights:

- **region.body** (prod, NOT unit-testable — Terminal + tty + tmux I/O): resolve target (exit 2 if
  none) → `regionPrepare` (capture full; exit 2 on failure) → `palette.resolve(allocator, .cached,
  true)` → `Terminal.init(cols=cap.cols, rows=cap.rows)` + feed `cap.ansi` (\n→\r\n) → `grid =
  t.screens.active` → `total_rows` (getBottomRight+1) → `render.getSize()` for tty cols/rows
  (fallback cap geometry) → pre-decode all rows into `[]motion.Row` → `motion.SliceGrid.grid()` →
  build `RegionCtx` (cursor at the bottom, scroll=scrollToBottom) → `app.enter()` (NoTty ⇒ exit 1) →
  `defer app.exit` → `repaint` → `app.runEvents(handler)` → switch action (quit⇒1, confirm⇒1 S1
  stub, none⇒1). All owned memory freed via defers (cap.ansi, the Terminal, the rows array + each
  row's text/col, RegionCtx.deinit).
- **regionPrepare** (dir-scoped, TESTABLE via FakeTmux): query `@tmux-2html-history-limit` (default
  50000) → `capture.capture(runner, alloc, target, .full, 50000, configured_limit)` → `Captured`.
- **regionHandle** (the EventHandler callback): search-typing branch (collect raw bytes; Enter ⇒
  `findMatches` + `nextMatch` jump; Esc cancels; Backspace edits) ELSE `input.feed` → motion
  (`applyMotion` + sync `sel.cursor` + repaint) / action (quit/confirm/clear-or-quit/visual-swap via
  `select.applyAction`) / search (`handleSearchAction`). Mouse ⇒ `.none` (S1 no-op; follow-up).
- **repaint**: `view.render` (grid+colors+viewport+cursor+sel.extent+matches) + `view.renderStatus`
  + flush, via a local buffered stdout writer (`fs.File.stdout().writer(&buf).interface`).

### Success Criteria

- [ ] `region.body` compiles + links into `zig-out/bin/tmux-2html`.
- [ ] `cli.region` takes a body fn pointer (mirror `cli.pane`); `main.zig` dispatch passes
      `region.body`; `region --help` prints help + exit 0; parse errors → exit 1.
- [ ] `regionPrepare` captures FULL (`.full` mode) honoring `@tmux-2html-history-limit` (verified
      by FakeTmux tests: full ANSI returned, cols/rows echoed, configured limit tightens the cap).
- [ ] Inside a `tmux display-popup`, `region` paints the full colored scrollback + status line;
      motion/select/search/quit all work (manual smoke, Level 3).
- [ ] `q` / `Esc`(no selection) / `Ctrl-c` / EOF ⇒ exit **1**, no output; terminal restored.
- [ ] `Esc` with an ACTIVE selection ⇒ clears it (stays in the TUI); `Enter`/`y` ⇒ confirm path
      (S1 stub; S2 renders).
- [ ] `zig build test -Doptimize=ReleaseFast` green (regionPrepare tests + all existing tests; the
      stale dispatch-region stub test removed/updated).
- [ ] `view.decodeRow` is `pub` (one keyword); no other view.zig behavior changes.

## All Needed Context

### Context Completeness Check

_If someone knew nothing about this codebase, would they have everything needed to implement this
successfully?_ **YES.** This PRP embeds: the verbatim Zig for every function (body, regionPrepare,
RegionCtx, regionHandle, repaint, search helpers — in `research/design_notes.md`); the EXACT dispatch
wiring (cli.region signature mirroring cli.pane, main.zig dispatch arm, the test-block import + the
stale-test removal); the one-line view.zig change + WHY (decodeRow pub, DecodedRow private via type
inference); the cross-test GOTCHA and what is/isn't unit-testable; the S1↔S2 seam; the manual smoke-
test procedure; and every upstream API signature with file:line citations.

### Documentation & References

```yaml
# MUST READ — the COMPLETE build spec for THIS subtask (authored from primary source, verbatim Zig).
- docfile: plan/001_0c8587f91cb2/P3M3T1S1/research/design_notes.md
  why: The full region.zig (body/regionPrepare/RegionCtx/regionHandle/repaint/search helpers), the
       dispatch wiring, the view.zig change, the import graph, the cross-test GOTCHA, the S1↔S2 seam,
       edge cases. This IS the spec.
  section: "§2 region.body" + "§3 regionPrepare" + "§4 RegionCtx/handle/repaint" + "§5 view.zig change"

# PRD + architecture (the behavioral contract)
- docfile: PRD.md
  why: §5.3 (region flags + "capture full scrollback into a grid; launch the full-screen TUI; on
       confirm render the selection; on cancel exit no output"); §7.1–§7.5 (display/movement/search/
       selection/confirm-cancel); §7.6 (mouse — S1 NO-OP, follow-up); §6 (palette precedence).
  section: "5.3 tmux-2html region" + "7. The copy-mode TUI"
- docfile: plan/001_0c8587f91cb2/architecture/tui_region.md
  why: §8 ("region reads the FULL scrollback into the grid FIRST (capture full mode) … works purely
       on the in-memory grid + the pty") — the core design tenet. §7 (confirm/cancel/sidecar — S2).
       §1–§6 (the verified std-lib primitives app/view/input/select/motion were built from).
  section: "§8 Open implementation detail" + "§7 Confirm / cancel / sidecar"

# The upstream modules region.zig CONSUMES (all SHIPPED — read to confirm signatures, then call)
- file: src/tui/app.zig
  why: `enter() !State` (alt screen + raw termios + mouse + signal handlers; `error.NoTty` if stdin
       isn't a tty); `exit(State)` (idempotent restore via the atomic `entered` guard — defer it);
       `runEvents(handler: EventHandler) !Action` (drives `readEvent` + `handler.handle`; returns on
       .quit/.confirm; .eof ⇒ .quit; `error.ReadFailed` on stdin read error); `EventHandler = { ctx:
       ?*anyopaque, handleFn: *const fn(?*anyopaque, Event) Action }`; `Event = union{key:u8,
       mouse:MouseEvent, seq:EscSeq, eof}`, `Action = enum{none,quit,confirm}`.
  gotcha: "enter() writes enter_full_seq (alt+hide-cursor+mouse) to STDOUT; region must call it AFTER
           capture so a capture failure doesn't leave the terminal raw. exit() is idempotent — safe
           to defer even though the signal handler + panic override ALSO call restoreRaw."
- file: src/tui/view.zig   # EDIT: decodeRow fn → pub fn (line 331)
  why: (a) `pub fn render(out: *std.Io.Writer, grid, pal, viewport: Viewport, cursor: Pos,
       selection: ?Selection, matches: []const Match)` — paints the grid in color (SGR via the cached
       palette), capped to viewport, scroll-by-cursor, selection+matches in reverse video. (b) `pub
       fn renderStatus(out, tty_rows: u16, cols: u16, status: Status)` — the last-row status line.
       (c) `pub fn decodeRow(alloc, grid, total_rows, y) !DecodedRow` — currently PRIVATE; S1 makes
       it pub so region pre-decodes rows into motion.Row{ text, col } (rowText returns text ONLY).
       (d) `pub fn findMatches(alloc, grid, needle, .fixed, total_rows) ![]Match`; (e)
       `pub fn scrollForCursor(cursor_y, viewport, total_rows) u32`; (f) `pub fn scrollToBottom(
       total_rows, viewport_rows) u32`. Types: `Viewport{cols,rows,scroll}`, `Pos{x,y}`,
       `Selection{x1,y1,x2,y2,rect}`, `Match{y,x1,x2}`, `Status{mode:SelMode,cursor,pattern,matches,
       has_selection}`, `SelMode=enum{none,line,block}`.
  pattern: "render is PURE+STATELESS (no prev-frame buffer; v1 = full viewport overwrite per call —
            no 2J, per-row CUP + content + below-grid EL). region calls it per keystroke."
  gotcha: "DecodedRow STAYS private — Zig lets a pub fn return a private struct; callers bind the
           result via type inference (`const d = try view.decodeRow(...); rows[y] = .{.text=d.text,
           .col=d.col}`) and never name the type. So ONE keyword change; no other view.zig edit."
- file: src/tui/input.zig
  why: `pub fn feed(self: *Decoder, ev: app.Event) ?Key` (the CORE state machine; INFALLIBLE — no
       `try`; returns null while accumulating digit/`g`, on .eof/.mouse, or on an ignored byte);
       `Decoder = struct{ count, has_count, pending_g }` (zero-init with `.{}`); `Key{ count: u32=1,
       kind: KeyKind }`; `KeyKind = union{ motion: Motion, action: Action, search: Search }`.
       `Action` includes visual_toggle/visual_line/visual_block/swap_end/swap_end_other/clear/quit/
       confirm; `Search` = start_forward/start_backward/next/prev.
  pattern: "region keeps ONE Decoder in RegionCtx; calls feed(&decoder, ev) per event. feed handles
            count parsing + the `gg` prefix; region switches on the returned Key.kind."
  gotcha: "feed returns null for .mouse — region's handler must route mouse SEPARATELY (S1: .none
           no-op). The clear-vs-quit decision on Esc is REGION's (check sel.active() BEFORE acting),
           NOT input's."
- file: src/tui/motion.zig
  why: `pub fn applyMotion(c: Cursor, m: input.Motion, count: u32, grid: Grid) Cursor` (PURE; switches
       on all 21 motions; recomputes viewport.scroll via view.scrollForCursor); `Cursor = struct{
       pos: view.Pos, viewport: view.Viewport }`; `Grid = struct{ ctx, getRowFn, total_rows, cols }`;
       `Row = struct{ text: []const u8, col: []const u16 }`; `SliceGrid = struct{ rows: []const Row,
       total_rows, cols, pub fn grid(self: *SliceGrid) Grid }` (the TESTED prod-Grid builder region
       REUSES — supply `rows` pre-decoded from view.decodeRow); `SearchState{ matches: []const Match,
       current: ?usize, direction: Direction }`; `pub fn nextMatch(s, cursor, dir) ?Pos`;
       `pub fn prevMatch(s, cursor) ?Pos`; `Direction = enum{forward,backward}`.
  pattern: "region pre-decodes ALL rows once into []Row, builds `var sg = motion.SliceGrid{...}; const
            mgrid = sg.grid();`, passes mgrid to every applyMotion call. sg must be a `var` (its
            grid() takes *SliceGrid)."
  gotcha: "SliceGrid.grid() takes `self: *SliceGrid` — sg MUST be a stack `var` lvalue (a const yields
           *const T which does NOT coerce to *anyopaque for ctx). Keep sg alive for the whole session
           (its `rows` are borrowed)."
- file: src/tui/select.zig
  why: `Sel = struct{ anchor: Pos, cursor: Pos, mode: Mode }` (`.{}` zero-init = inactive); methods
       `active()`, `clear()`, `extent(cols: u16) ?view.Selection` (null when inactive; the value
       view.render + S2 consume), `viewMode() view.SelMode`; `pub fn applyAction(sel: *Sel, action:
       input.Action, cursor: view.Pos)` — the PURE dispatcher for visual_toggle/line/block/swap_end/
       swap_end_other (clear/quit/confirm are NO-OPs here; region handles those). `Mode = enum{
       none, linewise, block }`.
  pattern: "region OWNS a Sel; after every motion sets `sel.cursor = cursor.pos` (extends an active
            selection, anchor fixed). Calls applyAction for the visual/swap actions; handles clear
            (Esc: clear-or-quit) + quit + confirm ITSELF before/instead of applyAction."
  gotcha: "select.zig is the PARALLEL P3.M2.T2.S1 (SHIPPED). extent(cols) is the S2 input — region
           passes tty_cols so linewise x2 = cols-1."
- file: src/capture.zig
  why: `pub const real: Runner` (the prod tmux runner); `pub fn capture(runner, alloc, pane, mode:
       Mode, history: u32, configured_limit: u32) CaptureError!Captured` (mode `.full` ⇒ `-S -<eff>
       -E -`; effective = min(history, configured_limit)); `pub fn queryOption(runner, alloc, name)
       ![]u8` (empty ⇒ unset); `Captured{ ansi: []u8 (owned), cols: u16, rows: u16, truncated, ... }`;
       `Mode = enum{ visible, full }`; `Runner = struct{ ctx, runFn }` (the mockable seam — FakeTmux
       in tests).
  pattern: "regionPrepare mirrors panePrepare's capture path: queryOption(@tmux-2html-history-limit)
            → parseInt (default 50000) → capture(.full, 50000, configured_limit). RegionOpts has NO
            --history field, so the cli side is the 50000 default."
- file: src/palette.zig
  why: `pub fn resolve(allocator, mode: Mode, has_tty: bool) Colors` — INFALLIBLE (returns Colors,
       NO `!`); precedence cached→live→default (PRD §6). `Mode = enum{ default, cached, live }`.
       `pub const Colors`, `pub fn defaultColors() Colors`.
  gotcha: "resolve's allocator is the FIRST arg; it is NOT a `try` (infallible). region passes
           has_tty=TRUE per the item contract (the display-popup gives a real pty). If run outside a
           popup, the live branch fails gracefully → cached/default; still correct."
- file: src/render.zig
  why: `pub fn getSize() SizeError!WindowSize` (ioctl on stdout → {cols, rows}; works in the popup
       since stdout IS the pty); `pub const WindowSize = struct{ cols: u16, rows: u16 }`; `pub const
       Size`. (S2 will use `render.toGhosttySelection` + `renderGrid`; S1 only needs getSize.)
  gotcha: "getSize can fail if stdout isn't a tty — region falls back to the pane geometry
           (cap.cols/cap.rows); app.enter() will then fail NoTty and region exits 1."
- file: src/cli.zig   # EDIT: region signature (mirror pane)
  why: `pub const RegionOpts = struct{ target: ?[]const u8, font: []const u8, output, open }`;
       `pub fn parseRegion(args) ParseError!RegionOpts` (PURE, already shipped); `pub fn region(
       allocator, args)` is the CURRENT stub (`_ = opts; return error.NotImplemented`) — S1 changes
       it to take a `body: *const fn(Allocator, RegionOpts) anyerror!u8` mirroring `pub fn pane(
       allocator, args, body)` EXACTLY (line ~362). `region_help` const already exists.
  pattern: "cli.pane is the TEMPLATE: help⇒0, parseError⇒reportError+1, else body(allocator,opts).
            cli.zig gains ZERO imports (it stays region/ghostty-free; body is an opaque fn pointer)."
- file: src/main.zig   # EDIT: dispatch + import + test block
  why: (a) `fn dispatch` (line ~108) — the `region` arm currently calls `cli.region(allocator,
       sub_args)`; change to `cli.region(allocator, sub_args, region.body)`. (b) add top-level
       `const region = @import("region.zig");`. (c) the test block (line ~480) — add `_ =
       @import("region.zig");`. (d) the test `dispatch routes known subcommand to cli stub` (line
       ~497) asserts `dispatch("region", &.{}) ⇒ error.NotImplemented` — REMOVE it (region is now
       WIRED; like pane/render/sync-palette it runs real I/O and can't be driven from a test).
  pattern: "pane is the TEMPLATE for the body-pointer dispatch (dispatch calls cli.pane(…,
            paneBody); paneBody is a top-level fn in main.zig). region.body lives in region.zig
            instead (the deliverable is region.zig), but the dispatch shape is identical."
  gotcha: "main.zig ALREADY imports `tui = @import(\"tui/app.zig\")` for the root panic override
           (restoreRaw on panic) — that stays. region.zig is an ADDITIONAL top-level import."

# ghostty primary source (region builds a Terminal — confirm the init/feed/screen API)
- file: zig-pkg/ghostty-1.3.1-.../src/terminal/Terminal.zig
  why: `Terminal.init(alloc, .{ .cols, .rows }) !Terminal`; `t.vtStream()` (the VT parser feed);
       `t.screens.active` (`*Screen` — coerces to `*const Screen`); `t.deinit(alloc)`. region keeps
       the Terminal alive for the whole session (defer t.deinit at end of body).
- file: src/render.zig   # the grid-build is renderGrid's body, VERIFIED — region reuses the pattern
  why: renderGrid (line 130) does `Terminal.init(cols, rows)` + `for (ansi) |c| { if (c=='\n') try
       stream.next('\r'); try stream.next(c); }` + reads `t.screens.active`. region's grid-build is
       IDENTICAL (just doesn't format immediately — it keeps the Terminal for the TUI). total_rows =
       the getBottomRight(.screen)+pointFromPin+coord().y+1 pattern from view.render (line ~115).
```

### Current Codebase tree

```bash
$ tree src/ -I 'zig-cache' --dirsfirst
src/
├── tui/
│   ├── app.zig        # P3.M1.T1 — enter/exit/runEvents + EventHandler + Event/Action (SHIPPED)
│   ├── input.zig      # P3.M2.T1.S1 — Decoder/feed/Key/KeyKind/Motion/Action/Search (SHIPPED)
│   ├── view.zig       # P3.M1.T2 — render/renderStatus/decodeRow/findMatches/scroll* (SHIPPED — EDIT decodeRow→pub)
│   ├── select.zig     # P3.M2.T2.S1 — Sel/extent/applyAction/Mode (SHIPPED)
│   └── motion.zig     # P3.M2.T1.S2 — Cursor/applyMotion/SliceGrid/SearchState/nextMatch (SHIPPED)
├── capture.zig        # P2.M1 — real/Runner/capture/queryOption/Captured/Mode (SHIPPED)
├── cli.zig            # parg parser + RegionOpts/PaneOpts; region STUB (EDIT: add body ptr, mirror pane)
├── ghostty_format.zig # vendored Cell→Style HTML formatter (S2 uses; S1 doesn't)
├── golden_test.zig    # P1.M4 golden harness
├── main.zig           # dispatch + panic override + paneBody/syncPaletteBody (EDIT: +region import/arm/test)
├── palette.zig        # P1.M2 — resolve/Colors/defaultColors/hasControllingTty (SHIPPED)
└── render.zig         # P1.M3/P1.M4 — renderGrid/buildSelection/getSize (SHIPPED; S2 adds toGhosttySelection)
```

### Desired Codebase tree with files to be added/edited

```bash
src/
├── tui/
│   └── view.zig       # EDIT: `fn decodeRow` → `pub fn decodeRow` (line 331; ONE keyword)
├── cli.zig            # EDIT: region() signature → +body fn pointer (mirror pane)
├── main.zig           # EDIT: +`const region` import, dispatch region arm → region.body, test-block import,
│                      #       remove the stale "dispatch routes region ⇒ NotImplemented" test
└── region.zig         # NEW: body + regionPrepare + RegionCtx + regionHandle + repaint + search helpers
                         #      + regionPrepare FakeTmux unit tests
```

`src/region.zig` responsibilities (the ONLY new file):
- `pub fn body(allocator, opts) anyerror!u8` — the prod wrapper (capture → grid → TUI → loop).
- `fn regionPrepare(allocator, target, runner) anyerror!capture.Captured` — FakeTmux-testable core.
- `const RegionCtx` — handler state (grid/colors/tty/cursor/sel/decoder/search/pattern/...).
- `fn regionHandle(ctx, ev) app.Action` — the EventHandler callback (decode → motion/select/search).
- `fn repaint(ctx) !void` — view.render + renderStatus + flush.
- `fn handleSearchByte` / `fn handleSearchAction` — the search-typing + search-navigation helpers.
- Tests: regionPrepare (full capture via a local FakeTmux double; NO Terminal ⇒ safe).

### Known Gotchas of our codebase & Library Quirks

```zig
// CRITICAL: zig build test MUST use -Doptimize=ReleaseFast. Debug hits the R_X86_64_PC64 linker
//   bug with the bundled ghostty C++ SIMD libs (PRD §15; confirmed across all sibling PRPs).
//   EVERY validation command in this PRP uses `zig build test -Doptimize=ReleaseFast`.

// CRITICAL: the cross-test GOTCHA — ghostty-vt Terminal.init corrupts process-global state such
//   that a Terminal.init in a SEPARATE test fn CRASHES (core dump). region.zig BUILDS a Terminal
//   (in body) ⇒ region.zig CANNOT have a Terminal-building test fn. regionPrepare tests use
//   FakeTmux (NO Terminal) ⇒ SAFE as separate test fns (mirrors panePrepare). body/handle/repaint
//   are compile-verified + manually smoke-tested (Level 3). The integration they perform
//   (view.render/motion.applyMotion/select.applyAction/input.feed) is ALREADY tested in each
//   module's own tests + view.zig's single Terminal scope.

// CRITICAL: app.enter() must be called AFTER capture + grid-build, so a capture/target failure
//   (exit 2) leaves the terminal in cooked mode. The `defer app.exit(state)` is the error/panic
//   safety net; exit() is idempotent (atomic `entered` guard) so defer + signal handler + panic
//   override never double-restore.

// CRITICAL: the Terminal row count is cap.rows (the pane's VISIBLE height), NOT total_rows.
//   Feeding the full scrollback ANSI into cols×cap.rows makes overflow lines scroll into ghostty
//   history pages; total_rows (getBottomRight+1) then covers ALL of them. This is how pane's
//   renderToFileAtomic works (size = {cap.cols, cap.rows}) and how the TUI browses all history
//   (tui_region.md §8). Do NOT init the Terminal with total_rows rows.

// CRITICAL: feed captured ANSI with \n→\r\n (the verified renderGrid/view pattern; tmux capture
//   output uses \n). `for (cap.ansi) |c| { if (c == '\n') try stream.next('\r'); try stream.next(c); }`.

// CRITICAL: palette.resolve(allocator, .cached, true) — allocator is the FIRST arg; resolve is
//   INFALLIBLE (returns Colors, NO `try`). has_tty=TRUE per the item contract.

// CRITICAL: motion.SliceGrid.grid() takes `self: *SliceGrid` ⇒ the SliceGrid MUST be a stack `var`
//   lvalue (a const yields *const T which does NOT coerce to *anyopaque). Keep it alive for the
//   whole session (its `rows` slice is borrowed). Same for RegionCtx (`&ctx` must be *RegionCtx).

// CRITICAL: make view.decodeRow pub (ONE keyword, line 331). DecodedRow STAYS private — Zig lets a
//   pub fn return a private struct; callers bind via type inference. Non-conflicting with the
//   parallel P3.M2.T2.S2 (which edits render.zig, NOT view.zig). Do NOT re-implement decodeRow.

// CRITICAL: the S1↔S2 seam — regionHandle returns .confirm on Enter/y; body()'s `switch (action)`
//   .confirm arm is where S2 plugs in render.toGhosttySelection + renderGrid + sidecar + filename.
//   ctx (sel/grid/colors/font/opts/tty) is in scope. S1 STUBS .confirm (exit non-zero: no file is
//   produced, so exit 0 would be dishonest). Document the choice either way; the seam is identical.

// CRITICAL: Esc clear-vs-quit is REGION's decision, NOT input's/select's. On .clear: if
//   sel.active() ⇒ sel.clear() + repaint (stay in TUI); else ⇒ return .quit (PRD §7.4/§7.5). Check
//   sel.active() BEFORE acting (select.applyAction no-ops on clear/quit/confirm).

// NOTE: mouse (PRD §7.6) is a NO-OP in S1 (regionHandle returns .none for .mouse events). app.zig
//   already DECODES SGR mouse; a follow-up adds the regionHandle mouse branch (click→move, drag→
//   select, wheel→scroll). Do NOT block S1 on mouse; document it as deferred.
```

## Implementation Blueprint

### Data models and structure

No new PUBLIC types beyond `RegionCtx` (handler state, module-private). region.zig reuses
`cli.RegionOpts`, `capture.{Runner, Captured, real}`, `palette.Colors`, `render.WindowSize`,
`app.{State, EventHandler, Event, Action}`, `view.{Viewport, Pos, Selection, Match, Status,
SelMode}`, `input.{Decoder, Key, KeyKind, Motion, Action, Search}`, `motion.{Cursor, Grid, Row,
SliceGrid, SearchState, Direction}`, `select.{Sel, Mode}`, and ghostty-vt `Terminal`/`Screen`.
Verbatim Zig for every function is in `research/design_notes.md` §2–§4.

```zig
// ---- src/region.zig imports (verified cycle-free; region is a leaf consumer) ----
const std = @import("std");
const cli = @import("cli.zig");
const capture = @import("capture.zig");
const palette = @import("palette.zig");
const render = @import("render.zig");
const app = @import("tui/app.zig");
const view = @import("tui/view.zig");
const input = @import("tui/input.zig");
const motion = @import("tui/motion.zig");
const select = @import("tui/select.zig");
const ghostty_vt = @import("ghostty-vt");

// ---- RegionCtx (the handler state — module-private) ----
const RegionCtx = struct {
    allocator: std.mem.Allocator,
    grid: *const ghostty_vt.Screen,
    colors: palette.Colors,
    tty_cols: u16, tty_rows: u16, grid_rows: u16, total_rows: u32,
    font: []const u8,
    cursor: motion.Cursor,
    sel: select.Sel,
    mgrid: motion.Grid,
    decoder: input.Decoder = .{},
    search: motion.SearchState = .{},
    pattern: ?[]const u8 = null,
    searching: bool = false,
    pattern_buf: std.ArrayList(u8) = .{},
    fn deinit(self: *RegionCtx) void { /* free search.matches, pattern, pattern_buf */ }
};
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: EDIT src/tui/view.zig — make decodeRow pub (ONE keyword, line 331)
  - CHANGE `fn decodeRow(` → `pub fn decodeRow(`.
  - LEAVE `const DecodedRow` private (line 326) — callers use type inference.
  - VERIFY: no other view.zig behavior changes; existing view.zig tests still pass.
  - WHY: motion.Grid needs {text, col} per row; rowText returns text only. region pre-decodes rows
    via decodeRow. Non-conflicting with parallel P3.M2.T2.S2 (edits render.zig).

Task 2: EDIT src/cli.zig — region() takes a body fn pointer (mirror pane, ~line 362)
  - CHANGE `pub fn region(allocator, args) !u8` →
        pub fn region(allocator, args, body: *const fn (std.mem.Allocator, RegionOpts) anyerror!u8) !u8
  - BODY: keep the `hasHelpFlag ⇒ region_help ⇒ 0` + `parseRegion ⇒ reportError ⇒ 1` prefix;
    replace `_ = opts; return error.NotImplemented;` with `return body(allocator, opts);`.
  - GOTCHA: cli.zig gains ZERO imports (mirror cli.pane — body is an opaque fn pointer).

Task 3: CREATE src/region.zig — regionPrepare (the testable core) + its FakeTmux + tests FIRST
  - IMPLEMENT regionPrepare EXACTLY as design_notes §3 (queryOption @tmux-2html-history-limit →
    parseInt default 50000 → capture.capture(runner, alloc, target, .full, 50000, configured_limit)).
  - ADD a local FakeTmux double (mirror main.zig's PaneFake: cols/rows/history_size/ansi/session/
    history_limit; run() answers display-message/capture-pane/show-option). LOCAL to region.zig
    (capture's FakeTmux is module-private).
  - ADD tests (design_notes §7): regionPrepare returns Captured with the full ANSI + echoed cols/rows
    (full mode); capture failure (FakeTmux errors) ⇒ error.CaptureFailed; @tmux-2html-history-limit
    honored (configured tightens the cap). NO Terminal anywhere ⇒ safe as separate test fns.
  - RUN `zig build test -Doptimize=ReleaseFast` after this task — regionPrepare tests must pass.

Task 4: CREATE src/region.zig — RegionCtx + regionHandle + repaint + search helpers
  - IMPLEMENT RegionCtx (design_notes §4), regionHandle (the EventHandler callback), repaint,
    handleSearchByte, handleSearchAction — EXACTLY as design_notes §4.
  - PATTERN: regionHandle switches on input.feed(&decoder, ev) Key.kind: motion⇒applyMotion+sync
    sel.cursor+repaint; action⇒(quit/confirm/clear-or-quit/else select.applyAction); search⇒
    handleSearchAction. Searching branch (handleSearchByte) intercepts raw bytes.
  - GOTCHA: clear (Esc) checks sel.active() FIRST — clear if active, else .quit. Mouse ⇒ .none
    (S1 no-op). repaint errors are swallowed (`catch {}`) — the TUI must not crash on a write blip.

Task 5: CREATE src/region.zig — body() (the prod wrapper; wires everything)
  - IMPLEMENT body EXACTLY as design_notes §2: resolve target (exit 2) → regionPrepare (exit 2) →
    palette.resolve(.,.cached,true) → Terminal.init(cap.cols,cap.rows)+feed(\n→\r\n) → grid/total_rows
    → getSize (fallback cap geom) → pre-decode []motion.Row → SliceGrid.grid() → RegionCtx (cursor
    at bottom, scroll=scrollToBottom) → app.enter (NoTty⇒exit 1) → defer app.exit → repaint →
    runEvents → switch (quit⇒1, confirm⇒1 stub, none⇒1).
  - GOTCHA: defer order — cap.ansi free, Terminal.deinit, rows array (+each row text/col),
    RegionCtx.deinit, app.exit. app.enter AFTER capture+grid-build (cooked mode on capture failure).
  - GOTCHA: SliceGrid is a `var` (grid() takes *SliceGrid); RegionCtx is a `var` (&ctx → *anyopaque).

Task 6: EDIT src/main.zig — wire the dispatch + test block
  - ADD `const region = @import("region.zig");` near the other top-level imports.
  - CHANGE the dispatch `region` arm: `return cli.region(allocator, sub_args, region.body);`
  - ADD `_ = @import("region.zig");` to the test block (convention; region is also a top-level
    import so tests are already reachable, but be explicit like the tui modules).
  - REMOVE the `test "dispatch routes known subcommand to cli stub"` (it asserts region⇒NotImplemented;
    region is now WIRED + runs real I/O — undriveable from a unit test, exactly like pane).
  - VERIFY: the panic override (main.zig top) still compiles (it uses tui.restoreRaw; unaffected).
```

### Implementation Patterns & Key Details

```zig
// === The grid-build (VERIFIED — it is renderGrid's body; region reuses it, just keeps the Terminal) ===
//   var t = try ghostty_vt.Terminal.init(allocator, .{ .cols = cap.cols, .rows = cap.rows });
//   defer t.deinit(allocator);
//   var stream = t.vtStream(); defer stream.deinit();
//   for (cap.ansi) |c| { if (c == '\n') try stream.next('\r'); try stream.next(c); }
//   const grid: *const ghostty_vt.Screen = t.screens.active;
//   const total_rows: u32 = blk: {  // mirrors view.render's computation (view.zig ~line 115)
//       const br = grid.pages.getBottomRight(.screen) orelse break :blk 1;
//       const br_pt = grid.pages.pointFromPin(.screen, br) orelse break :blk 1;
//       break :blk br_pt.coord().y + 1;
//   };

// === The motion Grid (REUSES the TESTED SliceGrid — no custom adapter) ===
//   var rows = try allocator.alloc(motion.Row, total_rows);
//   defer { for (rows) |r| { allocator.free(r.text); allocator.free(r.col); } allocator.free(rows); }
//   var y: u32 = 0;
//   while (y < total_rows) : (y += 1) {
//       const d = try view.decodeRow(allocator, grid, total_rows, y); // decodeRow is pub (Task 1)
//       rows[y] = .{ .text = d.text, .col = d.col };
//   }
//   var sgrid = motion.SliceGrid{ .rows = rows, .total_rows = total_rows, .cols = grid.pages.cols };
//   const mgrid: motion.Grid = sgrid.grid();  // sgrid MUST be a `var` (grid() takes *SliceGrid)
//   // ... cursor = motion.applyMotion(cursor, key.kind.motion, key.count, mgrid); ...

// === The handler core (the dispatch on the decoded Key) ===
//   if (input.feed(&ctx.decoder, ev)) |key| switch (key.kind) {
//       .motion => |m| { ctx.cursor = motion.applyMotion(ctx.cursor, m, key.count, ctx.mgrid);
//                        ctx.sel.cursor = ctx.cursor.pos; repaint(ctx) catch {}; },
//       .action => |a| switch (a) {
//           .quit => return .quit,
//           .confirm => return .confirm,      // S2 renders; body() stubs
//           .clear => if (ctx.sel.active()) { ctx.sel.clear(); repaint(ctx) catch {}; } else return .quit,
//           else => { select.applyAction(&ctx.sel, a, ctx.cursor.pos); repaint(ctx) catch {}; },
//       },
//       .search => |s| handleSearchAction(ctx, s),
//   }
//   return .none;  // feed returned null (accumulating / eof / mouse / ignored)

// === The repaint (local buffered stdout writer — the render.zig run() bridge pattern) ===
//   var buf: [16384]u8 = undefined;
//   var fw = std.fs.File.stdout().writer(&buf);
//   const w = &fw.interface;
//   try view.render(w, ctx.grid, ctx.colors, ctx.cursor.viewport, ctx.cursor.pos,
//       if (ctx.sel.active()) ctx.sel.extent(ctx.tty_cols) else null, ctx.search.matches);
//   try view.renderStatus(w, ctx.tty_rows, ctx.tty_cols, .{
//       .mode = ctx.sel.viewMode(), .cursor = ctx.cursor.pos,
//       .pattern = if (ctx.searching) ctx.pattern_buf.items else ctx.pattern,
//       .matches = ctx.search.matches, .has_selection = ctx.sel.active() });
//   try w.flush();
```

### Integration Points

```yaml
BUILD:
  - NO change. region.zig is in src/; main.zig imports it via @import("region.zig"). The test step
    uses exe.root_module (build.zig) so region.zig's tests are reachable once main.zig imports it.
    region.zig imports ghostty-vt (available to all src/ files). No build.zig / build.zig.zon edit.

DISPATCH:
  - cli.zig: region() gains a body fn pointer (Task 2).
  - main.zig: dispatch region arm → cli.region(allocator, sub_args, region.body) (Task 6).

DOWNSTREAM (P3.M3.T1.S2 — NOT this subtask; for awareness):
  - body()'s `switch (action) { .confirm => ... }` arm is the S2 seam. S2 changes `.confirm => 1` to
    `.confirm => blk: { render.toGhosttySelection(ctx.sel, ctx.grid, ctx.tty_cols) → renderGrid →
    write .last-output sidecar + output filename + --open; break :blk 0; }`. ctx (sel, grid, colors,
    font=opts.font, output=opts.output, open=opts.open) is already in scope.

TEST_ROOT:
  - main.zig test block: + `_ = @import("region.zig");` (Task 6). regionPrepare tests live IN
    region.zig (its test fns are reachable via the import). region is ALSO a top-level import
    (dispatch), so tests are doubly reachable.
```

## Validation Loop

> **CRITICAL**: ALL Zig build/test commands MUST use `-Doptimize=ReleaseFast`. Debug hits the
> `R_X86_64_PC64` linker bug with the bundled ghostty C++ SIMD libs (PRD §15). The #1 build gotcha.

### Level 1: Syntax & Type Check (Immediate Feedback)

```bash
# After Tasks 1–6 — compile the test target + the binary.
zig build test -Doptimize=ReleaseFast
# Expected: compiles cleanly. A type mismatch (e.g. region.body's signature ≠ the cli body pointer,
# RegionCtx missing a field, decodeRow call arity) surfaces here. A missing import surfaces as
# "unable to find ... ". The view.zig decodeRow-pub change surfaces as "use of private declaration"
# if NOT applied. Fix BEFORE running tests further.
zig build -Doptimize=ReleaseFast
# Expected: builds zig-out/bin/tmux-2html with no errors (the new region import is on the exe path).
```

### Level 2: Unit Tests (regionPrepare — the ONLY unit-testable surface)

```bash
# Full suite (ReleaseFast MANDATORY). regionPrepare tests are separate fns (FakeTmux, NO Terminal).
zig build test -Doptimize=ReleaseFast
# Expected: ALL tests pass (existing + regionPrepare: full capture, capture-failure⇒error,
# history-limit honored). The stale "dispatch routes region ⇒ NotImplemented" test is GONE (Task 6).

# Focus debugging on region.zig only:
zig build test -Doptimize=ReleaseFast --test-filter "regionPrepare"
# (Zig's test runner supports --test-filter <substring>.)
```

### Level 3: Integration Testing (the TUI — needs a real pty; MANUAL)

```bash
# The TUI cannot run in CI (it needs a real pty + a tmux pane with content). S1's automated gates
# are Level 1 + Level 2 + the --help / no-tty checks below. The full interactive TUI is MANUAL:

# (a) Automated: --help works (the cli.region help prefix; no body call).
./zig-out/bin/tmux-2html region --help
# Expected: prints the region help text (region_help const), exit 0.

# (b) Automated: no tty ⇒ app.enter fails NoTty ⇒ exit 1 + the message (stdin piped, not a pty).
echo "" | ./zig-out/bin/tmux-2html region --target %0 ; echo "exit=$?"
# Expected: stderr "error: region requires a terminal (run via tmux display-popup)", exit=1.
# (If run inside tmux with $TMUX_PANE set but stdin piped, same. If tmux is unavailable, capture
#  fails first ⇒ "cannot capture pane", exit 2.)

# (c) MANUAL (the PRD path): inside a tmux session with a pane that has scrollback, run the binding
#     or manually open the popup:
tmux display-popup -E -w 100% -h 100% "zig-out/bin/tmux-2html region --target $TMUX_PANE"
# Verify: full colored scrollback shows (cached palette); status line on the last row; cursor at the
# bottom. Then: hjkl/arrows move + re-scroll; v selects (reverse video); v again toggles block;
# /foo Enter highlights + jumps; n/N cycle; Esc clears selection / Esc(no-sel) quits; q quits.
# On quit the popup closes (-E) and `echo $?` (if captured) is 1 (PRD §7.5: cancel, no output).
# (Enter ⇒ exit 1 in S1 — the confirm-render is P3.M3.T1.S2; the popup still closes via -E.)
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Wide-glyph + scrollback integrity (MANUAL, in the popup): point region at a pane with CJK/emoji +
# a long scrollback; verify wide glyphs render correctly (no splits — view.render skips spacers),
# scrolling through the full history reaches the top (total_rows = full scrollback), and selection
# over a wide glyph highlights the WHOLE glyph. (view.zig's single Terminal test already proves the
# per-cell fidelity; this confirms the region wiring preserves it end-to-end.)

# Terminal-restore safety (MANUAL): inside the popup, hit Ctrl-C mid-selection (or `kill -TERM` the
# process from another shell). Verify the terminal is restored (cooked termios + primary screen +
# visible cursor) — app.zig's signal handler + the root panic override guarantee this; S1 inherits
# it via app.enter/exit. (No new signal handling in region.zig.)
```

## Final Validation Checklist

### Technical Validation

- [ ] `zig build test -Doptimize=ReleaseFast` passes (zero failures; existing + regionPrepare).
- [ ] `zig build -Doptimize=ReleaseFast` builds the binary with no errors.
- [ ] `view.decodeRow` is `pub`; no other view.zig behavior changed (existing view tests green).
- [ ] No new compiler warnings from region.zig / cli.zig / main.zig / view.zig.

### Feature Validation

- [ ] `cli.region` takes a body fn pointer (mirror `cli.pane`); `region --help` ⇒ 0; parse errors ⇒ 1.
- [ ] `regionPrepare` captures FULL (`.full`) honoring `@tmux-2html-history-limit` (FakeTmux tests).
- [ ] Inside a `tmux display-popup`, `region` paints the full colored scrollback + status line; cursor
      at the bottom (manual, Level 3).
- [ ] vim motions + counts, `v`/`V`/`Ctrl-v`/`R` selection, `o`/`O`, `/` `?` `n` `N` search all work
      (manual, Level 3).
- [ ] `Esc` clears an active selection (stays in TUI); `q`/`Esc`(no-sel)/`Ctrl-c`/EOF ⇒ exit 1, no
      output, terminal restored (manual + the no-tty automated check).
- [ ] Terminal ALWAYS restored on normal/error/signal/panic exit (inherited from app.zig).

### Code Quality Validation

- [ ] REUSES every shipped module (app/view/input/motion/select/capture/palette/render) — nothing
      re-implemented (the grid-build is renderGrid's verified pattern; the motion Grid reuses the
      tested SliceGrid; selection/motion/search dispatch to the tested functions).
- [ ] region.zig is pure GLUE: the only NEW logic is the handler's event→action routing + the
      search-typing byte collection.
- [ ] `body`/`handle`/`repaint` are NOT unit-tested (Terminal + tty + tmux I/O) — they are compile-
      verified + manually smoke-tested; regionPrepare (NO Terminal) IS unit-tested. The cross-test
      GOTCHA is respected (no Terminal-building test fn in region.zig).
- [ ] Owned memory fully freed (cap.ansi, Terminal, rows array + each row text/col, RegionCtx.deinit)
      via defers; std.testing.allocator not used in region.zig (regionPrepare uses it via FakeTmux).
- [ ] The dispatch wiring mirrors pane EXACTLY (body fn pointer); main.zig's stale region-stub test
      removed.

### Documentation & Deployment

- [ ] region.zig has a module doc comment (the orchestrator's purpose + the S1↔S2 seam).
- [ ] `body`/`regionHandle`/`repaint` have doc comments explaining: capture-then-enter ordering,
      the grid-build (cap.rows → history pages), the cursor/scroll init (bottom, tmux copy-mode),
      the clear-vs-quit Esc decision, the confirm stub (S2 fills render), the mouse NO-OP (follow-up).
- [ ] The S1↔S2 seam (`.confirm` arm) is explicitly marked `// P3.M3.T1.S2: render + sidecar`.

---

## Anti-Patterns to Avoid

- ❌ Don't init the Terminal with `total_rows` rows — use `cap.rows` (the pane's visible height);
  overflow becomes ghostty history pages; `total_rows` (getBottomRight+1) covers all of them.
- ❌ Don't build a Terminal in a region.zig unit test (cross-test GOTCHA — it crashes). Test only
  regionPrepare (FakeTmux, no Terminal). body/handle/repaint = compile + manual.
- ❌ Don't re-implement `view.decodeRow` — make it `pub` (one keyword) and reuse it.
- ❌ Don't re-implement grid-build / SGR paint / pin-Selection — region is GLUE over renderGrid's
  pattern + view.render + the shipped motion/select/input.
- ❌ Don't call `app.enter()` before capture/grid-build — a capture failure (exit 2) must leave the
  terminal cooked. `defer app.exit` is the safety net (idempotent).
- ❌ Don't hardcode the Esc behavior in input/select — clear-vs-quit is REGION's decision (check
  `sel.active()` first: clear if active, else quit).
- ❌ Don't swallow the `app.runEvents` error silently — map `error.ReadFailed` to `.quit` (cancel);
  propagate unexpected errors.
- ❌ Don't wire mouse in S1 (regionHandle returns `.none` for `.mouse`) — app.zig already decodes it;
  a follow-up adds click/drag/wheel. Document the deferral.
- ❌ Don't render on confirm in S1 — that's P3.M3.T1.S2's scope (toGhosttySelection + renderGrid +
  sidecar + filename). S1's `.confirm` arm is a documented stub.
- ❌ Don't touch `cli.RegionOpts` (add no `--history` field) — region uses the 50000 default capped
  by `@tmux-2html-history-limit`, mirroring pane.
- ❌ Don't skip ReleaseFast — `zig build test` WITHOUT `-Doptimize=ReleaseFast` fails to LINK.
- ❌ Don't leave the stale `"dispatch routes region ⇒ NotImplemented"` test — region is WIRED now.

---

## Confidence Score

**8/10** — Every upstream module is SHIPPED + tested (app/view/input/motion/select/capture/palette/
render), and each explicitly designates region.zig as its orchestrator with a documented contract.
The grid-build is renderGrid's verified pattern; the motion Grid reuses the tested SliceGrid; the
handler is straightforward event→action routing over `input.feed` → `motion.applyMotion` /
`select.applyAction` / search; repaint is two proven view calls + flush. The complete verbatim Zig is
authored in `research/design_notes.md`. The deliverable is one new file (region.zig) + three small
edits (cli.zig signature, main.zig dispatch/import/test, view.zig one keyword).

Residual risks: (1) the handler's search-typing byte collection is the one piece of genuinely NEW
stateful logic (raw bytes, not via the decoder) — fully specified in design_notes §4 with deterministic
behavior (Enter/Esc/Backspace/printable); exercised manually in Level 3. (2) The TUI cannot be unit-
tested (Terminal + tty + tmux I/O) — regionPrepare (FakeTmux) is the automated surface; the full loop
is manual smoke (Level 3 in-tmux). (3) The pre-decode-all-rows memory (~12 MiB for 50k rows) is
acceptable for v1 but noted; the on-demand adapter is a documented future optimization. (4) The S1
confirm-stub exit code (1 vs 0) is a documented choice with an identical S2 seam either way. The
PARALLEL P3.M2.T2.S2 (render.zig toGhosttySelection) is decoupled — S1 does NOT call it (confirm is
stubbed); S2 will, consuming S1's loop + ctx. The one shared file between S1 and S2 is render.zig's
API surface (S1 uses only the EXISTING getSize; S2 adds toGhosttySelection) — no edit conflict.
