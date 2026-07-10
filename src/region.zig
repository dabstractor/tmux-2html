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
    var t = try Terminal.init(allocator, .{ .cols = cap.cols, .rows = cap.rows });
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
    //      Quit => exit 1 (PRD 7.5: cancel, no output). Confirm => exit 1 (S1 STUB: confirm is
    //      recognized but render is S2; no file is produced so exit 0 would be dishonest. S2
    //      changes this to `=> 0` + render + sidecar; the seam is identical). none => exit 1
    //      (unreachable: runEvents returns only on quit/confirm; eof => quit).
    return switch (action) {
        .quit => 1,
        .confirm => 1, // P3.M3.T1.S2: render.toGhosttySelection(sel, grid, tty_cols) -> renderGrid
                       //                  -> .last-output sidecar + output filename + --open; return 0.
        .none => 1,
    };
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
