// ============================================================================
// P3.M3.T1.S1 — region.zig: capture full scrollback -> grid -> launch TUI
//
// THE ORCHESTRATOR every TUI module (app/input/motion/select/view) is waiting
// for. `region.body` resolves the target, captures the FULL pane scrollback
// (honoring @tmux-2html-history-limit), resolves the palette (cached->live->
// default; has_tty=true), builds a ghostty Terminal/grid from the captured
// ANSI (cap.cols x cap.rows; scrollback overflows into history pages so
// total_rows covers ALL of it), pre-decodes every row into a motion.SliceGrid,
// enters the TUI (app.enter), and runs the FULL interactive loop (app.runEvents
// with a RegionCtx handler that decodes input.feed -> motion.applyMotion /
// select.applyAction / search, syncs sel.cursor <- cursor.pos, repaints via
// view.render + view.renderStatus).
//
//   Quit   => exit 1 (PRD 7.5: cancel, no output).
//   Confirm => S1 STUB (exit non-zero; P3.M3.T1.S2 fills render + sidecar).
//
// This module is pure GLUE over the shipped app/view/input/motion/select/
// capture/palette/render modules - nothing is re-implemented. The grid-build is
// renderGrid's verified pattern; the motion Grid reuses the tested SliceGrid;
// selection/motion/search dispatch to the tested functions.
//
// S1<->S2 SEAM: regionHandle returns .confirm on Enter/y; body()'s
//   switch (action) { .confirm => ... }
// arm is where S2 plugs in render.toGhosttySelection(ctx.sel, ctx.grid,
// ctx.tty_cols) -> renderGrid -> .last-output sidecar + output filename +
// --open; then return 0. ctx (sel/grid/colors/font/tty/opts) is in scope.
//
// TESTABILITY: regionPrepare (capture via FakeTmux, NO Terminal) is unit-tested
// (mirrors panePrepare). body/handle/repaint build a Terminal + need a real
// pty + tmux I/O, so they are compile-verified + manually smoke-tested (the
// cross-test GOTCHA forbids a Terminal-building test fn in region.zig; the
// integration they perform is ALREADY tested in each module's own tests).
// ============================================================================

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli.zig");
const capture = @import("capture.zig");
const palette = @import("palette.zig");
const render = @import("render.zig");
const app = @import("tui/app.zig");
const view = @import("tui/view.zig");
const input = @import("tui/input.zig");
const motion = @import("tui/motion.zig");
const select = @import("tui/select.zig");
const fmt = @import("ghostty_format.zig"); // ScreenFormatter (the renderGrid formatter block, verbatim)
const ghostty_vt = @import("ghostty-vt");

const Terminal = ghostty_vt.Terminal;
const Screen = ghostty_vt.Screen;

// ============================================================================
// regionPrepare - the dir-scoped FakeTmux-testable capture core (NO Terminal)
// ============================================================================

/// Dir-scoped testable core: capture the FULL scrollback (region is ALWAYS
/// full - PRD 5.3), honoring @tmux-2html-history-limit (default 50000; RegionOpts
/// has no --history so the cli side is the 50000 default, tightened by the
/// configured limit). `runner` is FakeTmux in tests, `capture.real` in prod.
/// Returns the owned Captured (cap.ansi caller-freed). NO Terminal, NO tty =>
/// SAFE as a separate test fn (no cross-test GOTCHA). Mirrors panePrepare's
/// capture path.
///
/// The `catch error.CaptureFailed` flattens capture's typed errors + option-query
/// errors into one generic error the prod wrapper maps to exit 2.
fn regionPrepare(
    allocator: std.mem.Allocator,
    target: []const u8,
    runner: capture.Runner,
) anyerror!capture.Captured {
    const limit_opt = capture.queryOption(runner, allocator, "@tmux-2html-history-limit") catch
        return error.CaptureFailed;
    defer allocator.free(limit_opt);
    const configured_limit = std.fmt.parseInt(u32, std.mem.trim(u8, limit_opt, " \t\n\r"), 10) catch 50000;
    return capture.capture(runner, allocator, target, .full, 50000, configured_limit) catch
        return error.CaptureFailed;
}

// ============================================================================
// RegionCtx - the handler state (module-private; owns all interactive state)
// ============================================================================

/// The handler ctx OWNS all interactive state (PRD 7; every TUI module
/// designates region.zig as the owner). A stack `var` in body() so `&ctx`
/// coerces to `*anyopaque`. deinit frees owned slices (search.matches +
/// pattern + pattern_buf).
const RegionCtx = struct {
    allocator: std.mem.Allocator,
    grid: *const Screen,
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
        // search.matches may be a non-empty owned slice (findMatches allocates);
        // the default &.{} is borrow-only and must NOT be freed.
        if (self.search.matches.len > 0) self.allocator.free(self.search.matches);
        if (self.pattern) |p| self.allocator.free(p);
        self.pattern_buf.deinit(self.allocator);
    }
};

// ============================================================================
// regionHandle - the app.EventHandler callback (decode -> motion/select/search)
// ============================================================================

/// The EventHandler callback (app.runEvents drives it). Decodes each Event,
/// applies motion/select/search, repaints, returns .quit/.confirm/.none.
/// Repaint errors are swallowed (the TUI must not crash on a transient write
/// error; matches app.zig's resilient-write stance).
///
/// SEARCH MODE: when `searching` is true, raw bytes are collected directly into
/// pattern_buf (the input decoder is idle). Enter finalizes, Esc cancels,
/// Backspace edits, printable appends (handleSearchByte).
///
/// NORMAL MODE: feed the decoder. On a decoded Key: motion => applyMotion +
/// sync sel.cursor + repaint; action => quit/confirm/clear-or-quit/else
/// select.applyAction; search => handleSearchAction. feed returns null while
/// accumulating (digit/g), on .eof/.mouse, or on an ignored byte.
///
/// Esc clear-vs-quit is REGION's decision (NOT input's/select's): on .clear, if
/// sel.active() => clear + repaint (stay in TUI); else => .quit (PRD 7.4/7.5).
/// Mouse is a NO-OP in S1 (PRD 7.6 mouse wiring is a follow-up; .none keeps the
/// loop alive). app.zig already DECODES SGR mouse; a later task only adds the
/// regionHandle mouse branch.
fn regionHandle(opaque_ctx: ?*anyopaque, ev: app.Event) app.Action {
    const ctx: *RegionCtx = @ptrCast(@alignCast(opaque_ctx.?));

    // ---- SEARCH MODE: collect pattern bytes directly (decoder idle) ----
    if (ctx.searching) return handleSearchByte(ctx, ev);

    // ---- NORMAL MODE: feed the decoder ----
    if (input.feed(&ctx.decoder, ev)) |key| {
        switch (key.kind) {
            .motion => |m| {
                ctx.cursor = motion.applyMotion(ctx.cursor, m, key.count, ctx.mgrid);
                ctx.sel.cursor = ctx.cursor.pos; // sync => extends an active selection (anchor fixed)
                repaint(ctx) catch {};
            },
            .action => |a| switch (a) {
                .quit => return .quit,
                .confirm => return .confirm, // S2 renders; body() stubs
                .clear => { // PRD 7.4/7.5: Esc clears an active selection, else quits
                    if (ctx.sel.active()) {
                        ctx.sel.clear();
                        repaint(ctx) catch {};
                    } else return .quit;
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
    return .none;
}

// ============================================================================
// repaint - view.render + view.renderStatus + flush (the per-keystroke paint)
// ============================================================================

/// Paint the grid + status line (PRD 7.1). Full viewport overwrite per call
/// (view.render's v1 design - no 2J, just per-row CUP + content + below-grid
/// EL). Local buffered stdout writer (the render.zig run() bridge pattern).
fn repaint(ctx: *RegionCtx) !void {
    var buf: [16384]u8 = undefined;
    var out_file = std.fs.File.stdout();
    var fw = out_file.writer(&buf);
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

// ============================================================================
// Search helpers (the only stateful NEW logic in S1)
// ============================================================================

/// Handle a byte while in search-typing mode (PRD 7.3). Enter => finalize
/// (findMatches + jump to first); Esc/Backspace => edit/cancel; printable =>
/// append. Repaint after each (status shows the in-progress pattern). input.zig's
/// contract: the decoder emits START only; region collects the pattern directly
/// from the raw stream (decoder idle).
fn handleSearchByte(ctx: *RegionCtx, ev: app.Event) app.Action {
    const b = switch (ev) {
        .key => |k| k,
        else => return .none, // ignore mouse/seq while typing
    };
    if (b == 0x0d or b == 0x0a) { // Enter -> finalize
        ctx.searching = false;
        if (ctx.pattern_buf.items.len > 0) {
            const owned = ctx.allocator.dupe(u8, ctx.pattern_buf.items) catch {
                ctx.pattern_buf.clearRetainingCapacity();
                repaint(ctx) catch {};
                return .none;
            };
            if (ctx.pattern) |old| ctx.allocator.free(old);
            ctx.pattern = owned;
            // free old matches (if any), scan the grid, jump to the first hit
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
        ctx.pattern_buf.clearRetainingCapacity();
        repaint(ctx) catch {};
        return .none;
    }
    if (b == 0x1b) { // Esc -> cancel search-typing (stay in TUI)
        ctx.searching = false;
        ctx.pattern_buf.clearRetainingCapacity();
        repaint(ctx) catch {};
        return .none;
    }
    if (b == 0x7f or b == 0x08) { // Backspace / Ctrl-H
        if (ctx.pattern_buf.items.len > 0) ctx.pattern_buf.items.len -= 1;
        repaint(ctx) catch {};
        return .none;
    }
    if (b >= 0x20) ctx.pattern_buf.append(ctx.allocator, b) catch {}; // printable
    repaint(ctx) catch {};
    return .none;
}

/// /, ? => enter search-typing (set direction); n/N => jump next/prev (wraparound).
/// PRD 7.3.
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

// ============================================================================
// body - the prod wrapper (capture -> grid -> TUI -> loop)
// ============================================================================

/// PRD 5.3 + 7 + tui_region.md 8. Resolve target, capture FULL scrollback
/// (honoring @tmux-2html-history-limit), resolve the palette (cached->live->
/// default; has_tty=true - the display-popup gives a real pty), build the grid,
/// enter the TUI, and hand control to the app loop (motion + select + search +
/// repaint). Quit => exit 1 (no output). Confirm => exit 1 (S1 STUB; P3.M3.T1.S2
/// adds render + sidecar here and changes this arm to exit 0). NOT unit-testable
/// (Terminal + tty + tmux I/O) - compile-verified + manually smoke-tested
/// (Level 3). Mirrors paneBody's structure.
pub fn body(allocator: std.mem.Allocator, opts: cli.RegionOpts) anyerror!u8 {
    const stderr = std.fs.File.stderr();
    const runner = capture.real;

    // (1) Resolve target: --target wins; else $TMUX_PANE; else exit 2 (mirrors paneBody).
    const target = opts.target orelse std.posix.getenv("TMUX_PANE") orelse {
        try stderr.writeAll("error: no target pane ($TMUX_PANE unset and no --target)\n");
        return 2;
    };

    // (2) Capture FULL scrollback (regionPrepare - the testable core; honors history cap).
    //     cap.ansi is owned; freed at end of scope. cap.cols/rows = pane geometry.
    const cap = regionPrepare(allocator, target, runner) catch {
        try stderr.writeAll("error: cannot capture pane (bad target or tmux unavailable)\n");
        return 2;
    };
    defer allocator.free(cap.ansi);

    // (3) Palette: cached->live->default. has_tty=TRUE - the display-popup provides a real
    //     pty (PRD 6; item contract). resolve is INFALLIBLE (returns Colors, no '!').
    const colors = palette.resolve(allocator, .cached, true);

    // (4) Build the grid: a Terminal sized to the pane's geometry; feed the FULL scrollback
    //     ANSI (\n -> \r\n, the verified renderGrid/view pattern). Lines past cap.rows scroll
    //     into ghostty history pages; total_rows (getBottomRight+1) covers ALL of them => the
    //     TUI browses the entire scrollback (tui_region.md 8). The Terminal stays alive for the
    //     WHOLE session (view.render + motion read t.screens.active read-only).
    //
    //     GOTCHA: the Terminal row count is cap.rows (the pane's VISIBLE height), NOT
    //     total_rows. Do NOT init the Terminal with total_rows rows.
    //
    //     SCROLLBACK SIZING: ghostty's max_scrollback is BYTES, not rows, and Terminal.init
    //     defaults it to 10_000 (~10 KiB) — which prunes almost all scrollback (only ~160 rows
    //     survive on a 319-col pane). Size it to the captured content via render.scrollbackBytes
    //     so the whole scrollback is retained. See render.scrollbackBytes for the derivation.
    var t = try Terminal.init(allocator, .{ .cols = cap.cols, .rows = cap.rows, .max_scrollback = render.scrollbackBytes(cap.ansi, cap.cols) });
    defer t.deinit(allocator);
    var stream = t.vtStream();
    defer stream.deinit();
    for (cap.ansi) |c| {
        if (c == '\n') try stream.next('\r');
        try stream.next(c);
    }
    const grid: *const Screen = t.screens.active;

    // total_rows = the screen's last row index + 1 (mirrors view.render's computation).
    const total_rows: u32 = blk: {
        const br = grid.pages.getBottomRight(.screen) orelse break :blk 1;
        const br_pt = grid.pages.pointFromPin(.screen, br) orelse break :blk 1;
        break :blk br_pt.coord().y + 1;
    };

    // (5) Tty size (the popup IS the tty => getSize works via ioctl on /dev/tty). Fallback to
    //     the pane geometry if stdout isn't a tty (defensive; app.enter will then fail NoTty
    //     below and region exits 1).
    const ws: render.WindowSize = render.getSize() catch .{ .cols = cap.cols, .rows = cap.rows };
    const tty_cols: u16 = ws.cols;
    const tty_rows: u16 = ws.rows;
    const grid_rows: u16 = if (tty_rows == 0) 1 else tty_rows -| 1; // last row = status line

    // (6) Pre-decode ALL rows ONCE into a motion.SliceGrid-compatible []Row (motion's pure
    //     primitives read text+col WITHOUT touching ghostty). ~12 MiB for a 50k-row scrollback
    //     (PRD 13 cap) - acceptable v1. REUSES the TESTED SliceGrid (no custom adapter, no
    //     per-keystroke re-decode). Requires view.decodeRow to be pub.
    var rows = try allocator.alloc(motion.Row, total_rows);
    defer {
        for (rows) |r| {
            allocator.free(r.text);
            allocator.free(r.col);
        }
        allocator.free(rows);
    }
    {
        var y: u32 = 0;
        while (y < total_rows) : (y += 1) {
            // decodeRow is pub (DecodedRow stays private; callers use type inference).
            const d = try view.decodeRow(allocator, grid, total_rows, y);
            rows[y] = .{ .text = d.text, .col = d.col };
        }
    }
    // sgrid MUST be a stack `var` (grid() takes *SliceGrid); keep it alive for the whole
    // session (its `rows` slice is borrowed).
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
        .cursor = .{
            .pos = .{ .x = 0, .y = if (total_rows > 0) total_rows - 1 else 0 },
            .viewport = .{ .cols = tty_cols, .rows = grid_rows, .scroll = init_scroll },
        },
        .sel = .{},
        .mgrid = mgrid,
    };
    defer ctx.deinit();

    // (8) Enter the TUI (alt screen + raw termios + mouse + signal handlers). NoTty => the
    //     binary isn't on a pty (not in a display-popup) => exit 1. MUST be called AFTER
    //     capture + grid-build so a capture failure (exit 2) leaves the terminal in cooked mode.
    //     `defer app.exit(state)` is the error/panic safety net; exit() is idempotent (atomic
    //     `entered` guard) so defer + signal handler + panic override never double-restore.
    const state = app.enter() catch {
        try stderr.writeAll("error: region requires a terminal (run via tmux display-popup)\n");
        return 1;
    };
    defer app.exit(state);

    // (9) Initial paint, then hand control to the event loop. error.ReadFailed from stdin =>
    //     treat as cancel (.quit); propagate unexpected errors.
    repaint(&ctx) catch {};
    const handler = app.EventHandler{ .ctx = @ptrCast(&ctx), .handleFn = regionHandle };
    const action = app.runEvents(handler) catch |err| switch (err) {
        error.ReadFailed => app.Action.quit,
        else => return err,
    };

    // (10) Loop exited. Terminal restores via the defer above (so any post-loop I/O is cooked).
    //      Quit => exit 1 (PRD 7.5: cancel, no output). Confirm => P3.M3.T1.S2 render + sidecar
    //      (toGhosttySelection -> ScreenFormatter against ctx.grid -> writeHtmlAtomic ->
    //      .last-output sidecar -> --open; exit 0 on success). none => exit 1 (unreachable:
    //      runEvents returns only on quit/confirm; eof => quit).
    //
    //      The confirm arm calls app.exit(state) FIRST so every subsequent stderr/file write
    //      happens in COOKED mode (the empty-selection warn is readable, not garbled in raw /
    //      alt-screen). app.exit is idempotent (app.zig atomic `entered` guard) => the body-scope
    //      `defer app.exit(state)` above is a later no-op. ctx.grid stays valid after app.exit (the
    //      in-memory Terminal is freed by `defer t.deinit` at body end, independent of the display
    //      restore).
    return switch (action) {
        .quit => 1,
        // P3.M3.T1.S2: the confirm-render flow (design_notes S1). The binding (P2.M2.T2.S2)
        // passes ONLY --target, so region reads @tmux-2html-font/@tmux-2html-open itself; opts.open
        // is OR'd in so a direct `region --open` still works. The path reaches the user ONLY via
        // the .last-output sidecar -> wrapper -> display-message (the popup has no tmux message
        // channel; region must NOT print to stdout). Every error path => stderr + exit 1 (no
        // partial sidecar). The sidecar is BEST-EFFORT: a .last-output write failure must NOT fail
        // the render (the HTML is already written) => log + continue to 0.
        .confirm => confirm_render: {
            app.exit(state); // restore FIRST (cooked-mode warns; idempotent with the defer above)

            // PRD §13 / §7.5: empty selection on confirm => warn, no file, exit 1. This is the
            // FIRST of TWO guards (TWO-TIER): tier 1 (here) = no selection begun at all
            // (sel inactive) — the user hit Enter without pressing v. TIER 2 (after the render,
            // below) catches an ACTIVE selection whose rendered body is blank cells. The TUI
            // handler returns .confirm unconditionally, so both guards live in THIS arm.
            // (`stderr` is body()'s already-declared stderr writer.)
            if (!ctx.sel.active()) {
                stderr.writeAll("tmux-2html region: no selection (press v to begin, then Enter)\n") catch {};
                break :confirm_render 1;
            }

            // Read the AUTHORITATIVE @tmux-2html-* options (binding passes only --target). font:
            // readFontOption defaults to "monospace" on unset; on a query error fall back to
            // ctx.font (the cli default, usually also "monospace"). open: OR opts.open (direct
            // `region --open`) with @tmux-2html-open (default on). See docs/CONFIGURATION.md
            // "How options are read".
            const font = readFontOption(runner, allocator) catch ctx.font;
            defer allocator.free(font);
            const do_open = opts.open or readBoolOption(runner, allocator, "@tmux-2html-open", true);

            // Render the user's selection against the EXISTING grid (no Terminal rebuild).
            // toGhosttySelection (P3.M2.T2.S2, pub) returns a native ghostty Selection whose pins
            // are tied to ctx.grid; the ScreenFormatter formats it (the SAME block renderGrid uses
            // internally, copied verbatim into renderSelectionHtml). The title is built here (body
            // has runner + target in scope).
            // PRD §8.1 / P1.M1.T1.S4: --title (opts.title) overrides the contextual title; else
            // regionTitle's default. Factored into regionResolveTitle (unit-testable). lang is
            // resolved ONCE here (static-lifetime slice) and threaded into renderSelectionHtml
            // (which has no `opts` in scope) so the DocumentOpts literal can carry it.
            const title = try regionResolveTitle(allocator, opts.title, runner, target);
            defer allocator.free(title);
            const lang = render.resolveLang(opts.lang);
            const html = renderSelectionHtml(allocator, &ctx, font, title, lang) catch {
                stderr.writeAll("tmux-2html region: render failed\n") catch {};
                break :confirm_render 1;
            };
            defer allocator.free(html);

            // PRD §13 / Issue 1 — TIER 2 guard. An ACTIVE selection over blank cells (a blank
            // prompt line, trailing blank row, or empty rectangle) renders a zero-non-blank-cell
            // body even though tier 1 (sel.active()) passed. selectionBodyEmpty scans the <pre>
            // body of the full §8.1 document (the envelope has exactly one <pre>); warn + exit 1
            // BEFORE resolveOutputPath/writeHtmlAtomic/writeLastOutput so neither the HTML file
            // nor the .last-output sidecar is produced. Mirrors render.zig:788 (render --selection).
            if (render.selectionBodyEmpty(html)) {
                stderr.writeAll("tmux-2html region: selection is empty\n") catch {};
                break :confirm_render 1;
            }

            // Output path: explicit --output wins; else <session>-<unixtime>-<pid>.html in the
            // configured output dir (mirrors pane's panePrepare via the SHIPPED capture.* helpers).
            const path = resolveOutputPath(allocator, opts, target, runner) catch {
                stderr.writeAll("tmux-2html region: cannot resolve output path\n") catch {};
                break :confirm_render 1;
            };
            defer allocator.free(path);
            if (std.fs.path.dirname(path)) |dp| std.fs.cwd().makePath(dp) catch {}; // ensure dir exists

            // Atomic write (temp + rename in the same dir; render.zig's writeFileAtomic idiom).
            writeHtmlAtomic(allocator, path, html) catch {
                stderr.writeAll("tmux-2html region: cannot write output file\n") catch {};
                break :confirm_render 1;
            };

            // .last-output sidecar (PRD 7.5 + 9.3): write the BARE output path to a file named
            // `.last-output` in region's OWN executable dir. Exported loader vars ($TMUX_2HTML_BIN)
            // do NOT reach the popup child, so region derives its bin dir via /proc/self/exe
            // (selfExePath). Best-effort: a sidecar write failure does NOT fail the render.
            if (selfBinDir(allocator)) |bin_dir| {
                defer allocator.free(bin_dir);
                writeLastOutput(bin_dir, path) catch {};
            } else |_| {
                stderr.writeAll("tmux-2html region: cannot determine bin dir for .last-output sidecar\n") catch {};
            }

            // --open (best-effort; never changes the exit code; mirrors render.spawnXdgOpen).
            if (do_open) render.spawnXdgOpen(path, allocator);

            break :confirm_render 0;
        },
        .none => 1, // unreachable: runEvents returns only on quit/confirm; eof => quit
    };
}

// ============================================================================
// P3.M3.T1.S2 helpers (the confirm-render support) — all module-private `fn`s.
// NONE touch a Terminal => ALL are safe as separate unit-test fns (the cross-test
// GOTCHA forbids Terminal-building test fns, but these are PURE / fs-only /
// Runner-seamed). renderSelectionHtml is the ONE exception (formats ctx.grid) =>
// it is compile-verified + manually smoke-tested (Level 3); its fidelity is
// ALREADY proven in render.zig's single Terminal test scope (P3.M2.T2.S2).
// ============================================================================

/// Render ctx.sel against the LOADED ctx.grid to an OWNED FULL HTML document (PRD §8.1:
/// complete document, never a fragment; caller frees). Uses `render.toGhosttySelection`
/// (P3.M2.T2.S2, pub, INFALLIBLE — clamps instead of erroring) + the vendored ScreenFormatter
/// (the SAME block `render.renderGrid` uses internally, copied verbatim) to produce the `<pre>`
/// fragment, then wraps it in the document envelope via `render.writeDocumentBytes`. NOT
/// unit-testable (touches ctx.grid => Terminal => the cross-test GOTCHA); the selection->HTML
/// fidelity is ALREADY proven in render.zig's single Terminal test scope (toGhosttySelection +
/// formatSelOnScreen). region.zig is GLUE over it.
///
/// WHY format ctx.grid (NOT a renderGrid rebuild): toGhosttySelection returns a native
/// Selection whose pins are tied to ctx.grid (pins are bound to the PageList they were created
/// from) => the formatter MUST run against THAT SAME screen. A renderGrid rebuild would build a
/// different Terminal (its pins would be invalid for this Selection) — that's the alternative
/// clampExtent+renderGrid path (see design_notes S3), avoided here.
fn renderSelectionHtml(allocator: std.mem.Allocator, ctx: *RegionCtx, font: []const u8, title: []const u8, lang: []const u8) ![]u8 {
    var aw = try std.Io.Writer.Allocating.initCapacity(allocator, 4096);
    defer aw.deinit();
    const gs = render.toGhosttySelection(ctx.sel, ctx.grid, ctx.tty_cols); // infallible; clamps
    // VERBATIM copy of render.renderGrid's formatter block (render.zig ~lines 140-150): the
    // ONLY diffs are screen=ctx.grid + selection=gs (vs a fresh Terminal + buildSelection).
    var f = fmt.ScreenFormatter.init(ctx.grid, .{
        .emit = .html,
        .background = ctx.colors.background,
        .foreground = ctx.colors.foreground,
        .palette = &ctx.colors.palette,
        .font = font,
    });
    f.content = .{ .selection = gs }; // null = whole grid; some(gs) = the selection sub-grid
    f.extra = .styles; // per-cell <span> inline CSS + OSC-8 <a> hyperlinks
    try aw.writer.print("{f}", .{f});
    const fragment = aw.writer.buffered(); // the <pre> fragment

    // Wrap the fragment in the §8.1 document envelope (title + lang passed in from body).
    var dw = try std.Io.Writer.Allocating.initCapacity(allocator, 4096);
    defer dw.deinit();
    // PRD §8.1 / P1.M1.T1.S4: <html lang> threaded in from body() (resolved once via resolveLang).
    try render.writeDocumentBytes(&dw.writer, .{ .title = title, .lang = lang, .background = ctx.colors.background }, fragment);
    return allocator.dupe(u8, dw.writer.buffered()); // OWNED full-document copy
}

/// Resolve the output path: explicit `--output FILE` wins; else build the collision-safe
/// `<session>-<unixtime>-<pid>.html` in `capture.resolveOutputDir` (reads @tmux-2html-output-dir /
/// XDG / HOME). Caller owns the returned slice. Mirrors pane's panePrepare path logic via the
/// SHIPPED capture.* pub helpers. Pure-ish (Runner-seamed; NO Terminal => unit-testable).
///
/// On a session-name query failure, the session falls back to "" (sanitizeFilename => "pane").
/// `resolveOutputDir` returns `error.NoHome` if neither XDG nor HOME is usable => maps to the
/// caller's error path (exit 1).
fn resolveOutputPath(
    allocator: std.mem.Allocator,
    opts: cli.RegionOpts,
    target: []const u8,
    runner: capture.Runner,
) ![]u8 {
    if (opts.output) |p| return allocator.dupe(u8, p); // explicit --output wins verbatim
    const out_dir = try capture.resolveOutputDir(runner, allocator); // @tmux-2html-output-dir/XDG/HOME
    defer allocator.free(out_dir);
    // querySessionName returns "" on error (=> sanitizeFilename falls back to "pane").
    const session = capture.querySessionName(runner, allocator, target) catch
        try allocator.alloc(u8, 0);
    defer allocator.free(session);
    const sess_trim = std.mem.trim(u8, session, " \t\n\r");
    const ts = std.time.timestamp(); // Unix seconds (matches pane's panePrepare)
    const fname = try capture.buildOutputFilename(allocator, sess_trim, ts, regionPid());
    defer allocator.free(fname);
    return capture.buildOutputPath(allocator, out_dir, fname);
}

/// region's pid for collision-safe filenames (mirrors main.zig's private currentPid; Linux
/// getpid, else 0). Reimplemented here because currentPid is main.zig-private (region must not
/// edit main.zig — S1 owns the main.zig dispatch wiring). PURE => unit-testable.
fn regionPid() i32 {
    return if (builtin.os.tag == .linux) @intCast(std.os.linux.getpid()) else 0;
}

/// Build the PRD §8.1 default document title for a region: `tmux-2html — <session>/<window>.<pane> <iso8601>`.
/// Mirrors main.zig's paneTitle (region shares the pane context). The session + window id are
/// queried via tmux (session falls back to "pane" on query failure; window is omitted if
/// unavailable). The timestamp is the ISO 8601 UTC wall-clock time (palette.formatIso8601).
/// Caller owns the returned slice. Runner-seamed => unit-testable (mirrors paneTitle's query path).
fn regionTitle(allocator: std.mem.Allocator, runner: capture.Runner, target: []const u8) ![]u8 {
    const session = capture.querySessionName(runner, allocator, target) catch
        try allocator.alloc(u8, 0);
    defer allocator.free(session);
    const sess_trim = std.mem.trim(u8, session, " \t\n\r");
    const sess: []const u8 = if (sess_trim.len > 0) sess_trim else "pane";

    // window id (PRD §8.1: <window> component). Empty/unset => omit it.
    const window = capture.queryWindowId(runner, allocator, target) catch
        try allocator.alloc(u8, 0);
    defer allocator.free(window);
    const win_trim = std.mem.trim(u8, window, " \t\n\r");

    var tsbuf: [32]u8 = undefined;
    const ts = palette.formatIso8601(&tsbuf); // PRD §8.1: <iso8601> (e.g. 2026-07-19T05:22:29Z)

    if (win_trim.len > 0) {
        return std.fmt.allocPrint(allocator, "tmux-2html — {s}/{s}.{s} {s}", .{ sess, win_trim, target, ts });
    }
    return std.fmt.allocPrint(allocator, "tmux-2html — {s}/{s} {s}", .{ sess, target, ts });
}

/// Resolve the PRD §8.1 document title for a region (S4): `--title` (opts.title) OVERRIDE wins
/// verbatim; else the contextual default (regionTitle); else the literal "tmux-2html". Caller
/// owns + must free. Runner-seamed (delegates to regionTitle's injectable runner) =>
/// unit-testable via the existing OptFake harness (mirrors the regionTitle tests). P1.M1.T1.S4.
fn regionResolveTitle(
    allocator: std.mem.Allocator,
    override: ?[]const u8,
    runner: capture.Runner,
    target: []const u8,
) ![]u8 {
    if (override) |t| return allocator.dupe(u8, t);
    return regionTitle(allocator, runner, target) catch try allocator.dupe(u8, "tmux-2html");
}

/// region's OWN executable dir (where `.last-output` is written). Uses /proc/self/exe
/// (`std.fs.selfExePath`) since `$TMUX_2HTML_BIN` is NOT visible to the popup child (exported
/// loader vars don't reach run-shell/popup children — P2.M2.T2.S2 GOTCHA). Caller owns the
/// returned slice. selfExePath is VERIFIED Zig 0.15.2 (fs.zig:545; takes a caller buffer,
/// returns a slice into it; `max_path_bytes` is the documented buffer size). fs-only =>
/// unit-testable.
fn selfBinDir(allocator: std.mem.Allocator) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = try std.fs.selfExePath(&buf); // SelfExePathError if /proc unavailable (never in popup)
    const dir = std.fs.path.dirname(exe) orelse "."; // null for a bare filename => cwd
    return allocator.dupe(u8, dir);
}

/// Write the BARE `output_path` to `<bin_dir>/.last-output` (the wrapper reads it to
/// display-message "tmux-2html: wrote <path>"). Overwrites (the wrapper pre-clears it via
/// `rm -f`). Dir-scoped + unit-testable (inject a tmpDir as bin_dir). The content is the BARE
/// path, NO "wrote" prefix (the wrapper prepends it). Uses page_allocator for the tiny transient
/// join string (freed before return — no leak).
fn writeLastOutput(bin_dir: []const u8, output_path: []const u8) !void {
    const sidecar = try std.fs.path.join(std.heap.page_allocator, &.{ bin_dir, ".last-output" });
    defer std.heap.page_allocator.free(sidecar);
    var f = try std.fs.cwd().createFile(sidecar, .{ .truncate = true });
    defer f.close();
    try f.writeAll(output_path); // BARE path, NO "wrote" prefix
}

/// Write pre-rendered `bytes` to `path` ATOMICALLY (temp + rename in the same dir). Mirrors
/// render.zig's writeFileAtomic idiom (same-dir temp => atomic rename, no EXDEV). Cleans up the
/// temp on error. Duplicates render.zig's PRIVATE writeFileAtomic INTENTIONALLY — keeps
/// render.zig untouched (P3.M2.T2.S2 owns it in parallel); render.renderToFileAtomic renders
/// the WHOLE grid (sel:null), unusable for a pre-rendered selection buffer. fs-only =>
/// unit-testable (tmpDir round-trip).
fn writeHtmlAtomic(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
    const dir_path = std.fs.path.dirname(path) orelse "."; // null for bare filenames
    const base = std.fs.path.basename(path);

    // Name the temp `.{base}.{rand}.tmp` next to `{base}` (same dir => same filesystem).
    var rnd: [4]u8 = undefined;
    std.crypto.random.bytes(&rnd);
    const tmp_name = try std.fmt.allocPrint(allocator, ".{s}.{x}.tmp", .{ base, @as(u32, @bitCast(rnd)) });
    defer allocator.free(tmp_name);

    // Open the target's directory as a real, closeable handle (cwd() returns one you must NOT
    // close; openDir(".") does close).
    var dir = if (std.fs.path.isAbsolute(dir_path))
        try std.fs.openDirAbsolute(dir_path, .{})
    else
        try std.fs.cwd().openDir(dir_path, .{});
    defer dir.close();

    var f = try dir.createFile(tmp_name, .{}); // truncate default
    errdefer {
        f.close();
        dir.deleteFile(tmp_name) catch {};
    }
    try f.writeAll(bytes);
    f.sync() catch {}; // best-effort durability before rename
    f.close();

    try dir.rename(tmp_name, base); // same dir => atomic
}

/// Read a boolean @tmux-2html-* option (the binding passes only --target, so region reads its
/// behavior options itself). "on"/"true"/"yes"/"1" (case-insensitive) => true; empty/unset =>
/// `default`; any other value (e.g. "off", "junk") => false. Runner-seamed => unit-testable.
fn readBoolOption(runner: capture.Runner, allocator: std.mem.Allocator, name: []const u8, default: bool) bool {
    const v = capture.queryOption(runner, allocator, name) catch return default; // query error => default
    defer allocator.free(v);
    const t = std.mem.trim(u8, v, " \t\n\r");
    if (t.len == 0) return default;
    return std.ascii.eqlIgnoreCase(t, "on") or std.ascii.eqlIgnoreCase(t, "true") or
        std.ascii.eqlIgnoreCase(t, "yes") or std.mem.eql(u8, t, "1");
}

/// Read @tmux-2html-font (default "monospace"). Caller owns the returned slice. ""/unset =>
/// "monospace". Runner-seamed => unit-testable.
fn readFontOption(runner: capture.Runner, allocator: std.mem.Allocator) ![]u8 {
    const v = try capture.queryOption(runner, allocator, "@tmux-2html-font");
    defer allocator.free(v);
    const t = std.mem.trim(u8, v, " \t\n\r");
    if (t.len == 0) return allocator.dupe(u8, "monospace");
    return allocator.dupe(u8, t);
}

// ============================================================================
// Unit tests - regionPrepare (FakeTmux, NO Terminal => safe as separate fns)
// ============================================================================

const testing = std.testing;

/// Test double for the capture.Runner seam (mirrors main.zig's PaneFake but
/// local to region.zig; capture's FakeTmux is module-private). Returns canned
/// bytes per tmux subcommand, with per-instance state (NO mutable global => no
/// cross-test contamination). The pane_id is NOT echoed (regionPrepare does not
/// query session_name).
const RegionFake = struct {
    cols: u16 = 80,
    rows: u16 = 24,
    history_size: u32 = 0,
    ansi: []const u8 = "\x1b[31mhi\x1b[0m\n",
    history_limit: ?[]const u8 = null, // @tmux-2html-history-limit value (null = unset)

    fn run(ctx: *anyopaque, argv: []const []const u8, alloc: std.mem.Allocator) anyerror![]u8 {
        const self: *RegionFake = @ptrCast(@alignCast(ctx));
        // helper: does argv contain needle?
        const hasArg = struct {
            fn f(a: []const []const u8, needle: []const u8) bool {
                for (a) |x| if (std.mem.eql(u8, x, needle)) return true;
                return false;
            }
        }.f;

        if (hasArg(argv, "display-message")) {
            // region captures geometry as "cols rows history_size".
            if (hasArg(argv, "#{pane_width} #{pane_height} #{history_size}"))
                return std.fmt.allocPrint(alloc, "{d} {d} {d}", .{ self.cols, self.rows, self.history_size });
            return error.UnexpectedArgv;
        }
        if (hasArg(argv, "capture-pane")) return alloc.dupe(u8, self.ansi);
        if (hasArg(argv, "show-option")) {
            // argv = { "tmux", "show-option", "-gqv", name }
            if (argv.len >= 4) {
                const name = argv[argv.len - 1];
                if (std.mem.eql(u8, name, "@tmux-2html-history-limit")) {
                    if (self.history_limit) |v| return alloc.dupe(u8, v);
                }
            }
            return alloc.alloc(u8, 0); // unset => empty
        }
        return error.UnexpectedArgv;
    }
};

test "regionPrepare: full capture returns the canned ANSI + echoed geometry" {
    const alloc = testing.allocator;
    var fake = RegionFake{ .cols = 100, .rows = 30, .history_size = 5, .ansi = "line1\nline2\n\x1b[32mgreen\x1b[0m\n" };
    const runner: capture.Runner = .{ .ctx = @ptrCast(&fake), .runFn = RegionFake.run };

    const cap = try regionPrepare(alloc, "%7", runner);
    defer alloc.free(cap.ansi);

    // FULL mode: the canned ANSI is returned verbatim (the effective cap is min(50000, 50000)).
    try testing.expectEqualStrings("line1\nline2\n\x1b[32mgreen\x1b[0m\n", cap.ansi);
    try testing.expectEqual(@as(u16, 100), cap.cols);
    try testing.expectEqual(@as(u16, 30), cap.rows);
    // history_size 5 < effective 50000 => NOT truncated.
    try testing.expect(!cap.truncated);
}

test "regionPrepare: capture failure (FakeTmux errors) => error.CaptureFailed" {
    const alloc = testing.allocator;
    // A fake that always errors (simulates a bad pane id / unavailable tmux).
    const ErrFake = struct {
        fn run(_: *anyopaque, _: []const []const u8, _: std.mem.Allocator) anyerror![]u8 {
            return error.TmuxNonZeroExit;
        }
    };
    var fake = ErrFake{};
    const runner: capture.Runner = .{ .ctx = @ptrCast(&fake), .runFn = ErrFake.run };

    try testing.expectError(error.CaptureFailed, regionPrepare(alloc, "%999999", runner));
}

test "regionPrepare: @tmux-2html-history-limit tightens the cap (truncation detected)" {
    const alloc = testing.allocator;
    // history_size 100000, configured limit 500 => effective 500 => truncated.
    var fake = RegionFake{ .history_size = 100000, .history_limit = "500" };
    const runner: capture.Runner = .{ .ctx = @ptrCast(&fake), .runFn = RegionFake.run };

    const cap = try regionPrepare(alloc, "%5", runner);
    defer alloc.free(cap.ansi);

    // effective = min(50000, 500) = 500; history_size 100000 > 500 => truncated.
    try testing.expect(cap.truncated);
    try testing.expectEqual(@as(u32, 500), cap.effective);
    try testing.expectEqual(@as(u32, 100000), cap.history_size);
}

test "regionPrepare: @tmux-2html-history-limit unset => defaults to 50000 (not truncated under default)" {
    const alloc = testing.allocator;
    // history_size 49999 < effective 50000 (default) => NOT truncated.
    var fake = RegionFake{ .history_size = 49999, .history_limit = null };
    const runner: capture.Runner = .{ .ctx = @ptrCast(&fake), .runFn = RegionFake.run };

    const cap = try regionPrepare(alloc, "%5", runner);
    defer alloc.free(cap.ansi);

    try testing.expect(!cap.truncated);
    try testing.expectEqual(@as(u32, 50000), cap.effective);
}

test "regionPrepare: @tmux-2html-history-limit non-numeric => defaults to 50000" {
    const alloc = testing.allocator;
    // A non-numeric configured value falls back to the 50000 default.
    var fake = RegionFake{ .history_size = 10, .history_limit = "not-a-number" };
    const runner: capture.Runner = .{ .ctx = @ptrCast(&fake), .runFn = RegionFake.run };

    const cap = try regionPrepare(alloc, "%5", runner);
    defer alloc.free(cap.ansi);

    try testing.expect(!cap.truncated);
    try testing.expectEqual(@as(u32, 50000), cap.effective);
}

// ============================================================================
// P3.M3.T1.S2 helper unit tests — ALL safe as separate fns (NO Terminal).
// resolveOutputPath / readBoolOption / readFontOption use the OptFake Runner
// (below); writeLastOutput / writeHtmlAtomic are fs-only (tmpDir); regionPid /
// selfBinDir are PURE / fs. The cross-test GOTCHA is respected (no Terminal).
// ============================================================================

/// Test double for the capture.Runner seam for the OPTION + filename helpers
/// (self-contained, mirrors main.zig's PaneFake). Answers `show-option` (any
/// @tmux-2html-* name => its value or "" for unset) + `display-message`
/// (`#{session_name}` => self.session). Per-instance state => no cross-test
/// contamination. NO Terminal => safe.
const OptFake = struct {
    options: std.StringHashMap([]const u8),
    session: []const u8 = "sess",
    window: []const u8 = "@2",

    fn run(ctx: *anyopaque, argv: []const []const u8, alloc: std.mem.Allocator) anyerror![]u8 {
        const self: *OptFake = @ptrCast(@alignCast(ctx));
        const hasArg = struct {
            fn f(a: []const []const u8, needle: []const u8) bool {
                for (a) |x| if (std.mem.eql(u8, x, needle)) return true;
                return false;
            }
        }.f;
        if (hasArg(argv, "display-message")) {
            if (hasArg(argv, "#{session_name}")) return alloc.dupe(u8, self.session);
            if (hasArg(argv, "#{window_id}")) return alloc.dupe(u8, self.window);
            return error.UnexpectedArgv;
        }
        if (hasArg(argv, "show-option")) {
            // argv = { "tmux", "show-option", "-gqv", name }
            if (argv.len >= 4) {
                const name = argv[argv.len - 1];
                if (self.options.get(name)) |v| return alloc.dupe(u8, v);
            }
            return alloc.alloc(u8, 0); // unset => empty
        }
        return error.UnexpectedArgv;
    }
};

/// Build an OptFake with a set of options (convenience for the option tests). `options`
/// is a slice of `.k`/`.v` field tuples (anonymous struct literals coerce to this).
fn optFake(options: []const struct { k: []const u8, v: []const u8 }, session: []const u8) OptFake {
    var f = OptFake{ .options = std.StringHashMap([]const u8).init(testing.allocator), .session = session };
    for (options) |kv| f.options.put(kv.k, kv.v) catch {};
    return f;
}

test "resolveOutputPath: explicit --output wins verbatim" {
    const alloc = testing.allocator;
    var fake = optFake(&.{}, "sess");
    defer fake.options.deinit();
    const runner: capture.Runner = .{ .ctx = @ptrCast(&fake), .runFn = OptFake.run };

    const opts = cli.RegionOpts{ .target = "%5", .output = "/tmp/my-out.html", .open = false };
    const path = try resolveOutputPath(alloc, opts, "%5", runner);
    defer alloc.free(path);
    // --output is returned verbatim (no dir join, no session/ts/pid).
    try testing.expectEqualStrings("/tmp/my-out.html", path);
}

test "resolveOutputPath: auto-name under @tmux-2html-output-dir matches <session>-<ts>-<pid>.html" {
    const alloc = testing.allocator;
    var fake = optFake(&.{.{ .k = "@tmux-2html-output-dir", .v = "/tmp/t2h-out-region" }}, "mysess");
    defer fake.options.deinit();
    const runner: capture.Runner = .{ .ctx = @ptrCast(&fake), .runFn = OptFake.run };

    const opts = cli.RegionOpts{ .target = "%5" }; // output null => auto-name
    const path = try resolveOutputPath(alloc, opts, "%5", runner);
    defer alloc.free(path);

    // Expect: /tmp/t2h-out-region/mysess-<digits>-<digits>.html
    try testing.expect(std.mem.startsWith(u8, path, "/tmp/t2h-out-region/mysess-"));
    try testing.expect(std.mem.endsWith(u8, path, ".html"));
    // The middle = <unixtime>-<pid> (both numeric). Slice off prefix + ".html".
    const mid = path["/tmp/t2h-out-region/mysess-".len .. path.len - ".html".len];
    var it = std.mem.splitScalar(u8, mid, '-');
    const ts_s = it.next() orelse return error.MissingTimestamp;
    const pid_s = it.next() orelse return error.MissingPid;
    try testing.expect(it.next() == null); // exactly two components
    _ = try std.fmt.parseInt(i64, ts_s, 10);
    _ = try std.fmt.parseInt(i32, pid_s, 10);
}

test "resolveOutputPath: empty session falls back to 'pane'" {
    const alloc = testing.allocator;
    var fake = optFake(&.{.{ .k = "@tmux-2html-output-dir", .v = "/tmp/t2h-out-region2" }}, "");
    defer fake.options.deinit();
    const runner: capture.Runner = .{ .ctx = @ptrCast(&fake), .runFn = OptFake.run };

    const opts = cli.RegionOpts{ .target = "%5" };
    const path = try resolveOutputPath(alloc, opts, "%5", runner);
    defer alloc.free(path);
    // sanitizeFilename("") => "pane".
    try testing.expect(std.mem.startsWith(u8, path, "/tmp/t2h-out-region2/pane-"));
}

test "writeLastOutput: writes the BARE path to <bin_dir>/.last-output (no prefix)" {
    // Use a tmpDir as the bin_dir (dir-scoped => testable without a real bin dir).
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(bin_path);

    try writeLastOutput(bin_path, "/some/output/selection.html");

    // Read back <bin_path>/.last-output => equals the input BARE path (no "wrote" prefix).
    const sidecar_path = try std.fs.path.join(testing.allocator, &.{ bin_path, ".last-output" });
    defer testing.allocator.free(sidecar_path);
    const got = try std.fs.cwd().readFileAlloc(testing.allocator, sidecar_path, 4096);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("/some/output/selection.html", got);
}

test "writeHtmlAtomic: writes bytes + target exists (read-back round-trip)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir_path);
    const target = try std.fs.path.join(testing.allocator, &.{ dir_path, "out.html" });
    defer testing.allocator.free(target);

    const payload = "<html><body>hello selection</body></html>";
    try writeHtmlAtomic(testing.allocator, target, payload);

    // Read back => equals input (proves the bytes landed + the rename completed).
    const got = try std.fs.cwd().readFileAlloc(testing.allocator, target, 4096);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(payload, got);
    // statFile succeeds (the rename completed => target exists).
    _ = try std.fs.cwd().statFile(target);
}

test "readBoolOption: on/true/yes/1 => true; off/junk => false; empty/unset => default" {
    // Helper: build a one-option fake + run readBoolOption + cleanup.
    const check = struct {
        fn run(val: []const u8, default: bool) bool {
            var f = OptFake{ .options = std.StringHashMap([]const u8).init(testing.allocator) };
            defer f.options.deinit();
            f.options.put("@tmux-2html-open", val) catch {};
            const runner: capture.Runner = .{ .ctx = @ptrCast(&f), .runFn = OptFake.run };
            return readBoolOption(runner, testing.allocator, "@tmux-2html-open", default);
        }
    }.run;

    try testing.expect(check("on", false));
    try testing.expect(check("ON", false)); // case-insensitive
    try testing.expect(check("true", false));
    try testing.expect(check("yes", false));
    try testing.expect(check("1", false));
    try testing.expect(!check("off", false));
    try testing.expect(!check("junk", false));
    // empty value => default (true here).
    try testing.expect(check("", true));
}

test "readBoolOption: unset option => default" {
    const alloc = testing.allocator;
    var fake = optFake(&.{}, "sess"); // no @tmux-2html-open => unset
    defer fake.options.deinit();
    const runner: capture.Runner = .{ .ctx = @ptrCast(&fake), .runFn = OptFake.run };

    try testing.expect(readBoolOption(runner, alloc, "@tmux-2html-open", true)); // unset => default true
}

test "readFontOption: set => value; unset/empty => 'monospace'" {
    const alloc = testing.allocator;

    // set value => returned (trimmed)
    {
        var fake = optFake(&.{.{ .k = "@tmux-2html-font", .v = "Fira Code" }}, "sess");
        defer fake.options.deinit();
        const runner: capture.Runner = .{ .ctx = @ptrCast(&fake), .runFn = OptFake.run };
        const font = try readFontOption(runner, alloc);
        defer alloc.free(font);
        try testing.expectEqualStrings("Fira Code", font);
    }
    // unset => "monospace"
    {
        var fake = optFake(&.{}, "sess");
        defer fake.options.deinit();
        const runner: capture.Runner = .{ .ctx = @ptrCast(&fake), .runFn = OptFake.run };
        const font = try readFontOption(runner, alloc);
        defer alloc.free(font);
        try testing.expectEqualStrings("monospace", font);
    }
    // empty value => "monospace"
    {
        var fake = optFake(&.{.{ .k = "@tmux-2html-font", .v = "   " }}, "sess");
        defer fake.options.deinit();
        const runner: capture.Runner = .{ .ctx = @ptrCast(&fake), .runFn = OptFake.run };
        const font = try readFontOption(runner, alloc);
        defer alloc.free(font);
        try testing.expectEqualStrings("monospace", font);
    }
}

test "regionPid: Linux => > 0; else >= 0" {
    const pid = regionPid();
    if (builtin.os.tag == .linux) {
        try testing.expect(pid > 0); // getpid is always >= 1 on Linux
    } else {
        try testing.expect(pid >= 0); // non-Linux => 0 (regionPid's documented fallback)
    }
}

test "regionTitle: session + window + pane + ISO8601 => 'tmux-2html — <sess>/<win>.<pane> <iso8601>'" {
    const alloc = testing.allocator;
    var fake = optFake(&.{}, "mysess");
    fake.window = "@2"; // echoes #{window_id}
    defer fake.options.deinit();
    const runner: capture.Runner = .{ .ctx = @ptrCast(&fake), .runFn = OptFake.run };

    const title = try regionTitle(alloc, runner, "%7");
    defer alloc.free(title);
    // PRD §8.1 default form: 'tmux-2html — <session>/<window>.<pane> <iso8601>'.
    try testing.expect(std.mem.startsWith(u8, title, "tmux-2html — mysess/@2.%7 "));
    const ts_s = title["tmux-2html — mysess/@2.%7 ".len..];
    try testing.expectEqual(@as(usize, 20), ts_s.len); // YYYY-MM-DDTHH:MM:SSZ
    try testing.expectEqual(@as(u8, 'Z'), ts_s[ts_s.len - 1]);
}

test "regionTitle: empty window => omit window component" {
    const alloc = testing.allocator;
    var fake = optFake(&.{}, "mysess");
    fake.window = "";
    defer fake.options.deinit();
    const runner: capture.Runner = .{ .ctx = @ptrCast(&fake), .runFn = OptFake.run };

    const title = try regionTitle(alloc, runner, "%7");
    defer alloc.free(title);
    try testing.expect(std.mem.startsWith(u8, title, "tmux-2html — mysess/%7 "));
    const ts_s = title["tmux-2html — mysess/%7 ".len..];
    try testing.expectEqual(@as(usize, 20), ts_s.len);
    try testing.expectEqual(@as(u8, 'Z'), ts_s[ts_s.len - 1]);
}

test "regionTitle: empty session falls back to 'pane'" {
    const alloc = testing.allocator;
    var fake = optFake(&.{}, ""); // empty session_name => falls back to "pane"
    fake.window = "@1";
    defer fake.options.deinit();
    const runner: capture.Runner = .{ .ctx = @ptrCast(&fake), .runFn = OptFake.run };

    const title = try regionTitle(alloc, runner, "%5");
    defer alloc.free(title);
    try testing.expect(std.mem.startsWith(u8, title, "tmux-2html — pane/@1.%5 "));
}

test "regionResolveTitle: --title override wins verbatim (no tmux query)" {
    const alloc = testing.allocator;
    var fake = optFake(&.{}, "mysess"); // would echo #{session_name} — but override wins
    defer fake.options.deinit();
    const runner: capture.Runner = .{ .ctx = @ptrCast(&fake), .runFn = OptFake.run };

    const title = try regionResolveTitle(alloc, "Region Override", runner, "%7");
    defer alloc.free(title);
    // Override is returned VERBATIM; the contextual regionTitle is NOT consulted.
    try testing.expectEqualStrings("Region Override", title);
}

test "regionResolveTitle: null override => contextual default" {
    const alloc = testing.allocator;
    var fake = optFake(&.{}, "mysess");
    defer fake.options.deinit();
    const runner: capture.Runner = .{ .ctx = @ptrCast(&fake), .runFn = OptFake.run };

    const title = try regionResolveTitle(alloc, null, runner, "%7");
    defer alloc.free(title);
    // Delegates to regionTitle => PRD §8.1 default form 'tmux-2html — <session>/<window>.<pane> <iso8601>'.
    try testing.expect(std.mem.startsWith(u8, title, "tmux-2html — mysess/@2.%7 "));
    const ts_s = title["tmux-2html — mysess/@2.%7 ".len..];
    try testing.expectEqual(@as(usize, 20), ts_s.len);
    try testing.expectEqual(@as(u8, 'Z'), ts_s[ts_s.len - 1]);
}

test "selfBinDir: returns a non-empty dir (the test binary's dir)" {
    const alloc = testing.allocator;
    const dir = try selfBinDir(alloc);
    defer alloc.free(dir);
    try testing.expect(dir.len > 0); // the running test binary's directory
}

