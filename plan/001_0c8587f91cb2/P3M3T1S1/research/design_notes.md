# P3.M3.T1.S1 design notes — region.zig: capture full scrollback → grid → launch TUI

> Authored from PRIMARY SOURCE (every src/ file + the tui_region.md arch doc read in full).
> This is the complete build spec for the region orchestrator. Every API signature below was
> verified against the SHIPPED source (line numbers cited).

## 0. What region.zig IS (the one orchestrator the TUI modules are waiting for)

EVERY TUI module's doc explicitly designates `region.zig (P3.M3)` as the consumer that OWNS the
interactive state and wires the pipeline. Verified quotes:

- `app.zig`: "P3.M3 region.zig calls runEvents(input_handler)."
- `input.zig`: "region.zig (P3.M3) drives feed() from its own EventHandler under app.runEvents."
- `motion.zig`: "region.zig (P3.M3) OWNS a Cursor + SearchState in its EventHandler ctx and wires
  the pipeline." + "region.zig (P3.M3) supplies the prod Grid (built from view.decodeRow)."
- `select.zig`: "region.zig (P3.M3) OWNS a motion.Cursor + a select.Sel and keeps sel.cursor in
  sync with Cursor.pos; it calls select.applyAction for selection actions and passes sel.extent(cols)
  + sel.viewMode() into view.render/view.Status."
- `view.zig`: "Stateful callers (region.zig, P3.M3) call [render] per keystroke between
  app.runEvents(...) calls."

So S1 = the GLUE that captures, builds the grid, enters the TUI, and runs the full interactive
loop (motion + select + search + repaint + quit). The confirm→render body is P3.M3.T1.S2.

## 1. The dispatch wiring (mirrors pane EXACTLY — pane is the established pattern)

`main.zig` dispatch (currently line ~117): `region` → `cli.region(allocator, sub_args)` which is a
STUB returning `error.NotImplemented`. CHANGE (mirror pane/sync-palette):

```zig
// main.zig top-level imports (add near `const render_mod = @import("render.zig");`):
const region = @import("region.zig"); // P3.M3.T1.S1: region subcommand body (capture → grid → TUI)

// main.zig dispatch — change the region arm from `cli.region(allocator, sub_args)` to:
} else if (std.mem.eql(u8, name, "region")) {
    return cli.region(allocator, sub_args, region.body);
}
```

`cli.region` (currently stub): change signature to take a body fn pointer (VERBATIM pane shape):
```zig
pub fn region(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    body: *const fn (std.mem.Allocator, RegionOpts) anyerror!u8,
) !u8 {
    if (hasHelpFlag(args)) { try write(std.fs.File.stdout(), region_help); return 0; }
    const opts = parseRegion(args) catch |err| { try reportError("region", err); return 1; };
    return body(allocator, opts);
}
```
cli.zig gains NO imports (it stays region/ghostty-free; the body pointer is opaque). This is the
EXACT pattern cli.pane / cli.syncPalette use.

main.zig test block: add `_ = @import("region.zig");` so region.zig's tests are reachable from the
test root (region is a top-level import, so tests are already reachable, but follow the codebase
convention of an explicit test-block import like the other tui modules). AND the existing test
`"dispatch routes known subcommand to cli stub"` currently asserts `dispatch("region", …)` ⇒
`error.NotImplemented` — that test MUST be removed/updated (region is now WIRED and runs real
tmux/tty I/O, exactly like pane/render/sync-palette which are NOT driven from unit tests).

## 2. region.body — the prod wrapper (capture → grid → TUI → loop)

```zig
/// PRD §5.3 + §7 + tui_region.md §8. Resolve target, capture FULL scrollback (honoring
/// @tmux-2html-history-limit), resolve the palette (cached→live→default; has_tty=true — the
/// display-popup gives a real pty), build the grid, enter the TUI, and hand control to the app
/// loop (motion + select + search + repaint). Quit ⇒ exit 1 (no output). Confirm ⇒ exit 0
/// (P3.M3.T1.S2 adds render + sidecar here). NOT unit-testable (Terminal + tty + tmux I/O) —
/// compile-verified + manually smoke-tested (Level 3). Mirrors paneBody's structure.
pub fn body(allocator: std.mem.Allocator, opts: cli.RegionOpts) anyerror!u8 {
    const stderr = std.fs.File.stderr();
    const runner = capture.real;

    // (1) Resolve target: --target wins; else $TMUX_PANE; else exit 2 (mirrors paneBody).
    const target = opts.target orelse std.posix.getenv("TMUX_PANE") orelse {
        try stderr.writeAll("error: no target pane ($TMUX_PANE unset and no --target)\n");
        return 2;
    };

    // (2) Capture FULL scrollback (regionPrepare — the testable core; honors history cap).
    //     cap.ansi is owned; freed at end of scope. cap.cols/rows = pane geometry.
    const cap = regionPrepare(allocator, target, runner) catch {
        try stderr.writeAll("error: cannot capture pane (bad target or tmux unavailable)\n");
        return 2;
    };
    defer allocator.free(cap.ansi);

    // (3) Palette: cached→live→default. has_tty=TRUE — the display-popup provides a real pty
    //     (PRD §6; item contract). resolve is INFALLIBLE (returns Colors, no '!').
    const colors = palette.resolve(allocator, .cached, true);

    // (4) Build the grid: a Terminal sized to the pane's geometry; feed the FULL scrollback
    //     ANSI (\n→\r\n, the verified renderGrid/view pattern). Lines past cap.rows scroll into
    //     ghostty history pages; total_rows (getBottomRight+1) covers ALL of them ⇒ the TUI
    //     browses the entire scrollback (tui_region.md §8). The Terminal stays alive for the
    //     WHOLE session (view.render + motion read t.screens.active read-only).
    var t = try ghostty_vt.Terminal.init(allocator, .{ .cols = cap.cols, .rows = cap.rows });
    defer t.deinit(allocator);
    var stream = t.vtStream();
    defer stream.deinit();
    for (cap.ansi) |c| { if (c == '\n') try stream.next('\r'); try stream.next(c); }
    const grid: *const ghostty_vt.Screen = t.screens.active;

    // total_rows = the screen's last row index + 1 (mirrors view.render's computation).
    const total_rows: u32 = blk: {
        const br = grid.pages.getBottomRight(.screen) orelse break :blk 1;
        const br_pt = grid.pages.pointFromPin(.screen, br) orelse break :blk 1;
        break :blk br_pt.coord().y + 1;
    };

    // (5) Tty size (the popup IS the tty ⇒ getSize works via ioctl on stdout). Fallback to the
    //     pane geometry if stdout isn't a tty (defensive; app.enter will then fail NoTty below).
    const ws: render.WindowSize = render.getSize() catch .{ .cols = cap.cols, .rows = cap.rows };
    const tty_cols: u16 = ws.cols;
    const tty_rows: u16 = ws.rows;
    const grid_rows: u16 = if (tty_rows == 0) 1 else tty_rows -| 1; // last row = status line

    // (6) Pre-decode ALL rows ONCE into a motion.SliceGrid-compatible []Row (motion's pure
    //     primitives read text+col WITHOUT touching ghostty). ~12 MiB for a 50k-row scrollback
    //     (PRD §13 cap) — acceptable v1. REUSES the TESTED SliceGrid (no custom adapter, no
    //     per-keystroke re-decode). Requires view.decodeRow to be pub (see §5).
    var rows = try allocator.alloc(motion.Row, total_rows);
    defer { for (rows) |r| { allocator.free(r.text); allocator.free(r.col); } allocator.free(rows); }
    {
        var y: u32 = 0;
        while (y < total_rows) : (y += 1) {
            // decodeRow is pub (DecodedRow stays private; callers use type inference — VERIFIED
            // Zig allows returning a private struct from a pub fn; fields accessible via the value).
            const d = try view.decodeRow(allocator, grid, total_rows, y);
            rows[y] = .{ .text = d.text, .col = d.col };
        }
    }
    var sgrid = motion.SliceGrid{ .rows = rows, .total_rows = total_rows, .cols = grid.pages.cols };
    const mgrid: motion.Grid = sgrid.grid();

    // (7) Initial cursor + viewport: tmux copy-mode ENTERS AT THE BOTTOM (latest line visible).
    //     cursor at the last row, col 0; scroll = bottom.
    const init_scroll = view.scrollToBottom(total_rows, grid_rows);
    var ctx = RegionCtx{
        .allocator = allocator,
        .grid = grid,
        .colors = colors,
        .tty_cols = tty_cols,
        .tty_rows = tty_rows,
        .grid_rows = grid_rows,
        .total_rows = total_rows,
        .font = opts.font,
        .cursor = .{ .pos = .{ .x = 0, .y = if (total_rows > 0) total_rows - 1 else 0 },
                     .viewport = .{ .cols = tty_cols, .rows = grid_rows, .scroll = init_scroll } },
        .sel = .{},
        .mgrid = mgrid,
    };
    defer ctx.deinit();

    // (8) Enter the TUI (alt screen + raw termios + mouse + signal handlers). NoTty ⇒ the
    //     binary isn't on a pty (not in a display-popup) ⇒ exit 1.
    var state = app.enter() catch {
        try stderr.writeAll("error: region requires a terminal (run via tmux display-popup)\n");
        return 1;
    };
    defer app.exit(state); // idempotent restore (signal handler + panic override share restoreRaw)

    // (9) Initial paint, then hand control to the event loop.
    repaint(&ctx) catch {};
    const handler = app.EventHandler{ .ctx = @ptrCast(&ctx), .handleFn = regionHandle };
    const action = app.runEvents(handler) catch |err| switch (err) {
        error.ReadFailed => app.Action.quit, // stdin read error ⇒ treat as cancel
        else => return err,
    };

    // (10) Loop exited. Terminal restores via the defer above (so any post-loop I/O is cooked).
    //      Quit ⇒ exit 1 (PRD §7.5: cancel, no output). Confirm ⇒ exit 0 (P3.M3.T1.S2 adds the
    //      render: render.toGhosttySelection(sel, grid, cols) → renderGrid → .last-output sidecar
    //      + output filename + --open).
    return switch (action) {
        .quit => 1,
        .confirm => 1, // S1 STUB: confirm is recognized but render is S2. Exit non-zero so the
                       // popup stays usable until S2 wires render; S2 changes this to `=> 0` + render.
        .none => 1,   // unreachable (runEvents returns only on quit/confirm; eof ⇒ quit)
    };
}
```

NOTE on the S1 confirm stub: returning 1 (not 0) on confirm is a deliberate, honest placeholder —
S1 does NOT render (no file is produced), so exit 0 would be a lie. The handler still RETURNS
`.confirm` on Enter/y, so S2 only has to (a) change the `.confirm => 1` arm to `.confirm => 0` and
(b) add the render+sidecar body before the return. The loop + ctx + grid + colors + sel are all in
place for S2. (If the team prefers the popup to close on confirm even pre-S2, change the stub to
`=> 0`; document the choice either way. The seam is identical.)

## 3. regionPrepare — the dir-scoped testable core (NO Terminal, NO tty)

Mirrors panePrepare's capture half. region has NO output-filename/dir logic in S1 (that's S2), so
the core is just "capture full, honoring the history cap":

```zig
/// Dir-scoped testable core: capture the FULL scrollback (region is ALWAYS full — PRD §5.3),
/// honoring @tmux-2html-history-limit (default 50000; RegionOpts has no --history so the cli side
/// is the 50000 default, tightened by the configured limit). `runner` is FakeTmux in tests,
/// `capture.real` in prod. Returns the owned Captured (cap.ansi caller-freed). NO Terminal, NO
/// tty ⇒ SAFE as a separate test fn (no cross-test GOTCHA). Mirrors panePrepare's capture path.
fn regionPrepare(allocator: std.mem.Allocator, target: []const u8, runner: capture.Runner) anyerror!capture.Captured {
    const limit_opt = capture.queryOption(runner, allocator, "@tmux-2html-history-limit") catch
        return error.CaptureFailed;
    defer allocator.free(limit_opt);
    const configured_limit = std.fmt.parseInt(u32, std.mem.trim(u8, limit_opt, " \t\n\r"), 10) catch 50000;
    return capture.capture(runner, allocator, target, .full, 50000, configured_limit) catch
        return error.CaptureFailed;
}
```
(The `catch error.CaptureFailed` flattens capture's typed errors + option-query errors into one
generic error the prod wrapper maps to exit 2. If finer granularity is wanted, propagate
capture.CaptureError directly — either is fine; the prod wrapper prints a generic message.)

## 4. RegionCtx + regionHandle + repaint (the interactive loop)

```zig
/// The handler ctx OWNS all interactive state (PRD §7; every TUI module designates region.zig as
/// the owner). A stack `var` in body() so `&ctx` coerces to `*anyopaque`. deinit frees owned
/// slices (search.matches + pattern_buf).
const RegionCtx = struct {
    allocator: std.mem.Allocator,
    grid: *const ghostty_vt.Screen,
    colors: palette.Colors,
    tty_cols: u16,
    tty_rows: u16,
    grid_rows: u16, // tty_rows - 1 (status line)
    total_rows: u32,
    font: []const u8, // opts.font (S2 passes to renderGrid; S1 paints with colors only)
    cursor: motion.Cursor,
    sel: select.Sel,
    mgrid: motion.Grid,
    decoder: input.Decoder = .{},
    search: motion.SearchState = .{},
    pattern: ?[]const u8 = null, // last finalized search pattern (for the status line)
    searching: bool = false,
    pattern_buf: std.ArrayList(u8) = .{},

    fn deinit(self: *RegionCtx) void {
        if (self.search.matches.len > 0) self.allocator.free(self.search.matches);
        if (self.pattern) |p| self.allocator.free(p);
        self.pattern_buf.deinit(self.allocator);
    }
};

/// The EventHandler callback (app.runEvents drives it). Decodes each Event, applies motion/select/
/// search, repaints, returns .quit/.confirm/.none. Infallible-ish (repaint errors swallowed — the
/// TUI must not crash on a transient write error; matches app.zig's resilient-write stance).
fn regionHandle(opaque_ctx: ?*anyopaque, ev: app.Event) app.Action {
    const ctx: *RegionCtx = @ptrCast(@alignCast(opaque_ctx.?));

    // ---- SEARCH MODE: collect pattern bytes directly (decoder idle) ----
    if (ctx.searching) return handleSearchByte(ctx, ev);

    // ---- NORMAL MODE: feed the decoder ----
    if (input.feed(&ctx.decoder, ev)) |key| {
        switch (key.kind) {
            .motion => |m| {
                ctx.cursor = motion.applyMotion(ctx.cursor, m, key.count, ctx.mgrid);
                ctx.sel.cursor = ctx.cursor.pos; // sync ⇒ extends an active selection (anchor fixed)
                repaint(ctx) catch {};
            },
            .action => |a| switch (a) {
                .quit => return .quit,
                .confirm => return .confirm, // S2 renders; body() stubs
                .clear => { // PRD §7.4/§7.5: Esc clears an active selection, else quits
                    if (ctx.sel.active()) { ctx.sel.clear(); repaint(ctx) catch {}; }
                    else return .quit;
                },
                else => { // visual_toggle/line/block/swap_end/swap_end_other
                    select.applyAction(&ctx.sel, a, ctx.cursor.pos);
                    repaint(ctx) catch {};
                },
            },
            .search => |s| handleSearchAction(ctx, s),
        }
    }
    // input.feed returns null while accumulating (digit/g), on .eof/.mouse, or on an ignored byte.
    // .mouse is a NO-OP in S1 (PRD §7.6 mouse wiring is a follow-up; .none keeps the loop alive).
    return .none;
}

/// Paint the grid + status line (PRD §7.1). Full viewport overwrite per call (view.render's v1
/// design — no 2J, just per-row CUP + content + below-grid EL). Local buffered stdout writer.
fn repaint(ctx: *RegionCtx) !void {
    var buf: [16384]u8 = undefined;
    var fw = std.fs.File.stdout().writer(&buf);
    const w = &fw.interface;
    const sel_ext: ?view.Selection = if (ctx.sel.active()) ctx.sel.extent(ctx.tty_cols) else null;
    try view.render(w, ctx.grid, ctx.colors, ctx.cursor.viewport, ctx.cursor.pos, sel_ext, ctx.search.matches);
    try view.renderStatus(w, ctx.tty_rows, ctx.tty_cols, .{
        .mode = ctx.sel.viewMode(),
        .cursor = ctx.cursor.pos,
        .pattern = if (ctx.searching) ctx.pattern_buf.items else ctx.pattern,
        .matches = ctx.search.matches,
        .has_selection = ctx.sel.active(),
    });
    try w.flush();
}
```

### Search helpers (the only stateful new logic in S1)

```zig
/// Handle a byte while in search-typing mode (PRD §7.3). Enter ⇒ finalize (findMatches + jump to
/// first); Esc/Backspace ⇒ edit/cancel; printable ⇒ append. Repaint after each (status shows the
/// in-progress pattern). input.zig's contract: the decoder emits START only; region collects the
/// pattern directly from the raw stream (decoder idle).
fn handleSearchByte(ctx: *RegionCtx, ev: app.Event) app.Action {
    const b = switch (ev) { .key => |k| k, else => return .none }; // ignore mouse/seq while typing
    if (b == 0x0d or b == 0x0a) { // Enter → finalize
        ctx.searching = false;
        if (ctx.pattern_buf.items.len > 0) {
            const owned = ctx.allocator.dupe(u8, ctx.pattern_buf.items) catch {
                ctx.pattern_buf.clearRetainingCapacity(); repaint(ctx) catch {}; return .none;
            };
            if (ctx.pattern) |old| ctx.allocator.free(old);
            ctx.pattern = owned;
            // free old matches, scan the grid, jump to the first hit
            if (ctx.search.matches.len > 0) ctx.allocator.free(ctx.search.matches);
            ctx.search.matches = view.findMatches(ctx.allocator, ctx.grid, ctx.pattern.?, .fixed, ctx.total_rows) catch &.{};
            ctx.search.current = null;
            if (motion.nextMatch(ctx.search, ctx.cursor.pos, ctx.search.direction)) |np| {
                ctx.cursor.pos = np;
                ctx.cursor.viewport.scroll = view.scrollForCursor(np.y, ctx.cursor.viewport, ctx.total_rows);
            }
        } else {
            ctx.pattern = null;
        }
        repaint(ctx) catch {};
        return .none;
    }
    if (b == 0x1b) { ctx.searching = false; ctx.pattern_buf.clearRetainingCapacity(); repaint(ctx) catch {}; return .none; }
    if (b == 0x7f or b == 0x08) { // Backspace/Ctrl-H
        if (ctx.pattern_buf.items.len > 0) ctx.pattern_buf.items.len -= 1;
        repaint(ctx) catch {}; return .none;
    }
    if (b >= 0x20) ctx.pattern_buf.append(ctx.allocator, b) catch {}; // printable
    repaint(ctx) catch {};
    return .none;
}

/// /, ? ⇒ enter search-typing (set direction); n/N ⇒ jump next/prev (wraparound). PRD §7.3.
fn handleSearchAction(ctx: *RegionCtx, s: input.Search) void {
    switch (s) {
        .start_forward, .start_backward => {
            ctx.searching = true;
            ctx.search.direction = if (s == .start_forward) .forward else .backward;
            ctx.pattern_buf.clearRetainingCapacity();
            repaint(ctx) catch {};
        },
        .next => {
            if (motion.nextMatch(ctx.search, ctx.cursor.pos, ctx.search.direction)) |np| {
                ctx.cursor.pos = np;
                ctx.cursor.viewport.scroll = view.scrollForCursor(np.y, ctx.cursor.viewport, ctx.total_rows);
                repaint(ctx) catch {};
            }
        },
        .prev => {
            if (motion.prevMatch(ctx.search, ctx.cursor.pos)) |np| {
                ctx.cursor.pos = np;
                ctx.cursor.viewport.scroll = view.scrollForCursor(np.y, ctx.cursor.viewport, ctx.total_rows);
                repaint(ctx) catch {};
            }
        },
    }
}
```

## 5. The ONE view.zig change: make `decodeRow` pub

`view.decodeRow` (view.zig:331) is PRIVATE; region needs it (motion's Grid needs text+col per row;
`pub fn rowText` returns text ONLY, freeing col). Making `decodeRow` pub exposes `{text, col}`.
`DecodedRow` (view.zig:326) STAYS private — Zig permits returning a private struct from a pub fn;
callers bind the result via type inference (`const d = try view.decodeRow(...); rows[y] = .{
.text = d.text, .col = d.col };`) and never name the type. So the change is ONE keyword:

```zig
// view.zig:331  fn decodeRow(  →  pub fn decodeRow(
```
NON-CONFLICTING with the parallel P3.M2.T2.S2 (which edits render.zig, NOT view.zig). The
alternative — re-implementing decodeRow's ~50 lines of wide-char/grapheme logic in region.zig — is a
DRY violation and a bug magnet. Making decodeRow pub is the right call. (Verified: no other caller
is broken by the keyword; rowText already calls decodeRow internally.)

## 6. Why this scope, and the S1↔S2 seam

- S1 OUTPUT (item contract): "`tmux-2html region` (inside a display-popup) shows the full colored
  scrollback in the TUI." ⇒ the TUI is VISIBLE and BROWSABLE. That requires wiring motion+select+
  search+repaint (all shipped modules; region is their only consumer). The MINIMUM (paint + quit
  only) would leave the TUI useless (can't scroll/move/select).
- S2 (P3.M3.T1.S2): "Confirm/cancel → renderGrid(selection) + .last-output sidecar + output
  filename." S2 OWNS the confirm→render→sidecar→filename→--open path. It does NOT re-wire motion/
  select/search. So S1 MUST wire the full loop; S2 only fills the `.confirm` arm.
- The seam: regionHandle returns `.confirm` on Enter/y; body()'s `switch (action) { .confirm => … }`
  is where S2 plugs in `render.toGhosttySelection(ctx.sel, ctx.grid, ctx.tty_cols)` → renderGrid →
  sidecar + filename + open + `return 0`. ctx (sel, grid, colors, font, opts) is already in scope.

## 7. The cross-test GOTCHA + what's unit-testable

ghostty-vt's `Terminal.init` corrupts process-global state such that a `Terminal.init` in a
SEPARATE test fn CRASHES (core dump) — the constraint that forces render.zig + view.zig to put ALL
Terminal-building assertions in ONE shared test fn (verified across every sibling PRP).

region.zig BUILDS a Terminal (in body, to load the grid). So region.zig CANNOT have a Terminal-
building test fn. Consequences:
- `regionPrepare` (capture via FakeTmux, NO Terminal) ⇒ SAFE as separate test fns (mirrors
  panePrepare). This is region.zig's PRIMARY unit-test surface.
- `body` / `regionHandle` / `repaint` / the grid-build are NOT unit-testable (Terminal + tty + tmux
  I/O). They are COMPILE-VERIFIED + MANUALLY smoke-tested (Level 3: inside a tmux display-popup, or
  a scripted pty harness). The integration they perform (view.render, motion.applyMotion,
  select.applyAction, input.feed) is ALREADY tested in each module's own tests + view.zig's single
  Terminal scope — region.zig is pure GLUE over proven functions.

So region.zig's tests = regionPrepare (full capture via FakeTmux; capture-failure ⇒ error) + the
FakeTmux double (reuse main.zig's PaneFake shape, local to region.zig). NO Terminal anywhere.

## 8. Manual smoke test (Level 3) — the TUI can't run in CI

The TUI needs a real pty + a tmux pane with content. Two paths:
1. **In-tmux (the PRD path):** in a tmux session with a pane that has scrollback, run the binding
   (`prefix C-o` → `tmux display-popup -E -w 100% -h 100% "$BIN region --target %N"`), or manually:
   `tmux display-popup -E -w 100% -h 100% "zig-out/bin/tmux-2html region --target <pane-id>"`.
   Verify: full colored scrollback shows; hjkl/arrows move; v selects; / searches; q quits (popup
   closes, exit 1); Enter exits (popup closes, exit 1 pre-S2).
2. **Scripted pty (CI-friendly, future):** spawn the binary in a pseudo-tty (Python `pty`/`pexpect`
   or a Zig pty helper), feed a fake capture by pre-seeding `$TMUX_PANE` + a tmux stub — but region
   shells out to REAL tmux, so this needs a tmux server with a pane. Out of scope for S1; note as a
   follow-up. For S1, the in-tmux smoke test (path 1) is the validation.

The AUTOMATED gates S1 can rely on: `zig build test -Doptimize=ReleaseFast` (regionPrepare + all
existing tests green) + `zig build -Doptimize=ReleaseFast` (binary links) + `./zig-out/bin/tmux-2html
region --help` (prints help, exit 0) + `./zig-out/bin/tmux-2html region` with no tty (app.enter
fails → exit 1 + the "requires a terminal" message). The full interactive TUI = manual (path 1).

## 9. Import graph (verified cycle-free)

region.zig imports: std, builtin, cli, capture, palette, render, app, view, input, motion, select,
ghostty_vt. NONE of those import region (it's new). Existing cycles (cli↔render lazy) are unchanged.
render.zig after S2 adds select+view imports; region→render is unaffected (region is a leaf
consumer). view→{ghostty_vt, palette}; input→app; motion→{view,input}; select→{view,input} — none
reach back to region. Clean.

## 10. Edge cases / gotchas (accumulated)

- **`\n`→`\r\n`** when feeding captured ANSI (matches renderGrid + view tests + tmux capture output).
- **Terminal row count = cap.rows** (the pane's VISIBLE height), NOT total_rows. Scrollback becomes
  ghostty history pages; total_rows (getBottomRight+1) covers them. Verified pattern (pane's
  renderToFileAtomic does the same with size = {cap.cols, cap.rows}).
- **`palette.resolve(allocator, .cached, true)`** — the allocator is the FIRST arg; resolve is
  INFALLIBLE (no `try`). has_tty=TRUE per the item contract (popup = real pty).
- **app.exit is idempotent** (atomic `entered` guard in restoreRaw). The `defer app.exit(state)` is
  the error/panic safety net; body() does not need an explicit second call (no post-loop terminal
  I/O in S1). S2's file writes happen before the return; the defer restores after.
- **Mouse is a NO-OP in S1** (regionHandle returns .none for .mouse). PRD §7.6 mouse wiring (click-
  to-move, drag-select, wheel-scroll) is a follow-up; app.zig already DECODES mouse, so a later task
  only adds the regionHandle mouse branch. Document this in the PRP.
- **`scrollToBottom` for the initial scroll** so the user lands on the latest output (tmux copy-mode
  enters at the bottom). cursor.y = total_rows - 1.
- **RegionCtx is a `var`** (stack lvalue) so `&ctx` is `*RegionCtx` → coerces to `*anyopaque`
  (capture.zig's 0.15.2 rule; a `const` yields `*const T` which does NOT coerce).
- **pre-decode memory** ~12 MiB for 50k rows (PRD §13 cap) — acceptable v1. The on-demand adapter
  alternative (decode one row at a time, cache the last, free on next) is leaner but adds lifetime
  juggling; pre-decode reuses the TESTED SliceGrid. Note the alternative for a future optimization.
- **ReleaseFast MANDATORY** for build/test (the ghostty C++ SIMD linker bug — every sibling PRP).
