//! view.zig — the copy-mode TUI grid renderer (PRD §7.1; arch tui_region.md §5).
//!
//! The ONE pure rendering function the copy-mode TUI uses to paint the captured pane's
//! cell grid to the display-popup's alternate screen in FULL COLOR matching the cached
//! palette. Reuses ghostty-vt's `Style.formatterVt()` SGR emitter (de-risking: do NOT
//! hand-roll SGR), paints per-row cursor addressing (CUP), caps to the viewport, scrolls
//! by the cursor, and shows the active selection + search matches in reverse video
//! (XOR-inverse — the conventional vim/less standout-over-standout model).
//!
//! Scope: PURE + STATELESS. `render()` takes a loaded `*const Screen` + viewport + palette
//! + overlays and writes bytes. It owns NO terminal state, NO event loop, NO capture, and
//! NO previous-frame buffer (v1 = full viewport repaint per call — diff-rendering is
//! explicitly deferred; the contract allows it). Stateful callers (region.zig, P3.M3) call
//! it per keystroke between `app.runEvents(...)` calls.
//!
//! Forward-contract types: `Viewport`/`Pos`/`Selection`/`Match` are defined HERE and are
//! what `select.zig` (P3.M2.T2) and the search layer (P3.M2.T1.S2) will PRODUCE. They are
//! deliberately simple value structs — no coupling to ghostty-vt's Pin-based `Selection`
//! (that's renderGrid's HTML path, P1.M4).
//!
//! Anti-scope (sibling subtasks — do NOT implement here):
//!   - status line / scroll maintenance / search populate — P3.M1.T2.S2
//!   - input decode / selection MODEL                      — P3.M2
//!   - pane capture / `region` loop wiring                 — P3.M3

const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const Screen = ghostty_vt.Screen;
const Cell = ghostty_vt.page.Cell;
const Style = ghostty_vt.Style;
const point = ghostty_vt.point;
const color = ghostty_vt.color;
const palette = @import("../palette.zig"); // Colors (one dir deeper than src/render.zig)

// ---- Public overlay types (forward-contract for select.zig / search) ----------

/// The visible window into the grid. `scroll` = top grid row (screen-tag y) shown
/// (0 = top of scrollback). `cols`/`rows` = popup grid cells for the GRID area (S2 reserves
/// the last tty row for the status line and passes rows = tty_rows - 1).
pub const Viewport = struct {
    cols: u16,
    rows: u16,
    scroll: u32,
};

/// A grid position (screen-tag coords; x=col, y=row, origin top-left). The TUI cursor.
/// render()'s `cursor` param exists so the signature matches the contract; v1 leaves the
/// terminal cursor hidden (app.zig enter() emits `\x1b[?25l`) — positional use is deferred.
pub const Pos = struct { x: u32, y: u32 };

/// A visual selection in grid coords. Either endpoint may be the geometric top-left;
/// render() normalizes. `rect=false` ⇒ LINEWISE (full row width per row in [y1..y2]);
/// `rect=true` ⇒ BLOCK (cols [min(x1,x2)..max(x1,x2)] per row in the y range). PRD §7.4.
pub const Selection = struct {
    x1: u32,
    y1: u32,
    x2: u32,
    y2: u32,
    rect: bool = false,
};

/// A search-match highlight: a contiguous run within ONE row [x1..x2] on row `y`.
/// Multi-row matches = multiple Match entries (one per row touched). The search layer
/// (P3.M2.T1.S2) produces these; render() highlights them with reverse video.
pub const Match = struct {
    y: u32,
    x1: u32,
    x2: u32,
};

// ---- The render entry point (the contract signature) -------------------------

/// Paint the grid's VISIBLE rows to `out` in color (SGR resolved through `pal`),
/// cursor-addressed, capped to `viewport`, with `selection` + `matches` shown in reverse
/// video. Pure + stateless: no terminal state, no previous-frame buffer. v1 = full viewport
/// repaint per call (diff-rendering deferred — the contract allows it).
///
/// `out`       — *std.Io.Writer (new IO); caller (region.zig) bridges stdout via a buffered
///               File writer; tests use std.Io.Writer.Allocating. Do NOT flush mid-render.
/// `grid`      — the loaded screen (t.screens.active from the captured scrollback).
/// `pal`       — the cached palette (palette.Colors). Palette-INDEX cell colors are emitted
///               as explicit RGB pinned to pal.palette (colors match the source pane).
/// `viewport`  — { cols, rows, scroll }: the visible window.
/// `cursor`    — the TUI cursor (grid coords). Unused in v1 (app.zig hides the terminal
///               cursor); param exists so the signature matches the contract.
/// `selection` — ?Selection: the active visual selection (null = none). Reversed.
/// `matches`   — []const Match: search hits to reverse-highlight (empty = none).
pub fn render(
    out: *std.Io.Writer,
    grid: *const Screen,
    pal: palette.Colors,
    viewport: Viewport,
    cursor: Pos,
    selection: ?Selection,
    matches: []const Match,
) !void {
    // Reset attrs once so erased/blank cells take the default bg, not a stale run's bg.
    // NO per-frame \x1b[2J (external_rendering_notes §5): ED does NOT move the cursor AND
    // causes a visible flicker. render() fully overwrites every viewport cell each call
    // (grid cells incl. blanks-as-spaces; below-grid rows erased with \x1b[K), so no clear
    // is needed. The alt-screen is blank on enter (\x1b[?1049h in app.zig).
    try out.writeAll("\x1b[0m");

    // Grid dimensions (computed ONCE per render; O(pages) for the row count).
    // total_rows via getBottomRight(.screen) + pointFromPin (the PUBLIC path —
    // PageList.totalRows() exists but is `fn` not `pub fn`, so we can't call it).
    const total_rows: u32 = blk: {
        const br = grid.pages.getBottomRight(.screen) orelse break :blk 0;
        const br_pt = grid.pages.pointFromPin(.screen, br) orelse break :blk 0;
        break :blk br_pt.coord().y + 1;
    };
    const grid_cols: u16 = grid.pages.cols;
    const cols: u16 = @min(viewport.cols, grid_cols);
    const rows: u16 = viewport.rows;

    var vy: u32 = 0;
    while (vy < rows) : (vy += 1) {
        const gy: u32 = viewport.scroll + vy;
        // CUP to screen row vy+1, col 1 (1-based) — per ROW START, then write sequentially
        // (NOT per-cell CUP). Wide chars auto-advance +2; we skip the spacer cell so
        // column alignment holds (mirrors ghostty_format.zig's row-sequential write).
        try out.print("\x1b[{d};1H", .{vy + 1});

        if (gy >= total_rows) {
            // Below the grid: EL (Erase in Line) to blank it. Handles scroll-past-end
            // without a full \x1b[2J (the one case a full overwrite doesn't cover).
            try out.writeAll("\x1b[K");
            continue;
        }

        // One pin() per visible row — a grid row NEVER spans pages. pin() returns null iff
        // the column is out of range OR the row is past the end (down() fails). Defensive:
        // a row that fails to pin (shouldn't happen here since gy < total_rows) gets EL'd.
        const rp = grid.pages.pin(.{ .screen = .{ .x = 0, .y = gy } }) orelse {
            try out.writeAll("\x1b[K");
            continue;
        };
        const page: *const ghostty_vt.page.Page = &rp.node.data;
        const cells = page.getCells(page.getRow(rp.y)); // full row; index by col == gx

        var last: ?Style = null; // run-length SGR dedup (re-emit only on style change)
        var gx: u32 = 0;
        while (gx < cols) : (gx += 1) {
            const cell = cells[gx];
            // Wide-char spacer handling (mirror ghostty_format.zig's inner loop):
            // a .wide cell holds the 2-col glyph (emit it; terminal advances +2);
            // .spacer_tail/.spacer_head are the consumed 2nd cell — `continue` past them
            // (writing ANYTHING there misaligns / splits the glyph).
            switch (cell.wide) {
                .spacer_head, .spacer_tail => continue,
                .narrow, .wide => {},
            }

            // Highlight = selection OR match. Both render as reverse (XOR in render):
            // an ALREADY-reverse cell under selection returns to NORMAL (the two inverses
            // cancel) — the conventional vim/less standout-over-standout behavior.
            const hi = highlight(gx, gy, selection, matches);
            var s = cellStyle(page, &cell);
            s.flags.inverse = s.flags.inverse ^ hi;

            if (last == null or !s.eql(last.?)) {
                // REUSE Style.formatterVt() — it always emits \x1b[0m first (self-contained
                // styles) then attrs then 38;2/48;2/58;2 RGB. Pin the palette so palette-INDEX
                // cell colors become explicit RGB cached to the source pane's palette.
                var vt = s.formatterVt();
                vt.palette = &pal.palette;
                try out.print("{f}", .{vt});
                last = s;
            }
            try writeGlyph(out, page, &cell); // codepoint (+grapheme trail) or ' '
        }
    }

    try out.writeAll("\x1b[0m"); // leave the terminal's SGR state clean
    _ = cursor; // v1: cursor is hidden (app.zig enter()); positional use deferred.
}

/// Emit a cell's glyph: the codepoint (+ any grapheme-cluster trail) or a space for blanks
/// (so bg colors / bg-only cells paint). Mirrors ghostty_format.zig's writeCell.
fn writeGlyph(out: *std.Io.Writer, page: *const ghostty_vt.page.Page, cell: *const Cell) !void {
    if (!cell.hasText()) {
        try out.writeByte(' ');
        return;
    }
    try out.print("{u}", .{cell.codepoint()});
    if (cell.content_tag == .codepoint_grapheme) {
        if (page.lookupGrapheme(cell)) |trail| {
            for (trail) |cp| try out.print("{u}", .{cp});
        }
    }
}

// ---- PURE helpers (unit-tested in their own test fns — no Terminal) -----------

/// cellStyle — VERBATIM from src/ghostty_format.zig (the proven Cell→Style mapping).
/// Returns the default Style `{}` for cells with no styling (style_id 0 / !hasStyling);
/// otherwise derefs the page's RefCountedSet style lookup (page.styles.get returns *const Style).
fn cellStyle(page: *const ghostty_vt.page.Page, cell: *const Cell) Style {
    return switch (cell.content_tag) {
        inline .codepoint, .codepoint_grapheme => if (!cell.hasStyling()) .{} else
            page.styles.get(page.memory, cell.style_id).*,
        .bg_color_palette => .{ .bg_color = .{ .palette = cell.content.color_palette } },
        .bg_color_rgb => .{ .bg_color = .{ .rgb = .{
            .r = cell.content.color_rgb.r,
            .g = cell.content.color_rgb.g,
            .b = cell.content.color_rgb.b,
        } } },
    };
}

/// The normalized bounds of a Selection (top-left/bottom-right). Either endpoint may be the
/// geometric top-left; select.zig may pass either order, so render() normalizes.
fn normSel(s: Selection) struct { x1: u32, y1: u32, x2: u32, y2: u32, rect: bool } {
    return .{
        .x1 = @min(s.x1, s.x2),
        .y1 = @min(s.y1, s.y2),
        .x2 = @max(s.x1, s.x2),
        .y2 = @max(s.y1, s.y2),
        .rect = s.rect,
    };
}

/// Is grid cell (gx,gy) inside the selection? LINEWISE: row in [y1..y2] (full row width).
/// BLOCK (rect=true): row in [y1..y2] AND col in [x1..x2].
fn inSelection(gx: u32, gy: u32, s: Selection) bool {
    const n = normSel(s);
    if (gy < n.y1 or gy > n.y2) return false;
    if (n.rect) return gx >= n.x1 and gx <= n.x2;
    return true; // linewise: full row width
}

/// Is grid cell (gx,gy) inside any match? (Match is a single-row range [x1..x2] on row y.)
fn inAnyMatch(gx: u32, gy: u32, matches: []const Match) bool {
    for (matches) |m| if (m.y == gy and gx >= m.x1 and gx <= m.x2) return true;
    return false;
}

/// Combined highlight for a cell (selection OR match). Both render as inverse (XOR in render).
pub fn highlight(gx: u32, gy: u32, sel: ?Selection, matches: []const Match) bool {
    if (sel) |s| if (inSelection(gx, gy, s)) return true;
    return inAnyMatch(gx, gy, matches);
}

/// Clamp scroll so the viewport can't scroll past the grid end. (S2 passes the clamped
/// scroll; this is the pure math, unit-tested independently.)
pub fn clampScroll(scroll: u32, total_rows: u32, viewport_rows: u16) u32 {
    if (total_rows <= viewport_rows) return 0;
    const max = total_rows - @as(u32, viewport_rows);
    return @min(scroll, max);
}

// ---- PURE helper unit tests (separate test fns — no Terminal ⇒ no cross-test GOTCHA) ----

test "normSel: normalizes either-order endpoints; identity for already-ordered" {
    const a = normSel(.{ .x1 = 5, .y1 = 1, .x2 = 0, .y2 = 3 });
    try std.testing.expectEqual(@as(u32, 0), a.x1);
    try std.testing.expectEqual(@as(u32, 1), a.y1);
    try std.testing.expectEqual(@as(u32, 5), a.x2);
    try std.testing.expectEqual(@as(u32, 3), a.y2);
    try std.testing.expectEqual(false, a.rect);
    // Already-ordered is identity.
    const b = normSel(.{ .x1 = 1, .y1 = 2, .x2 = 3, .y2 = 4, .rect = true });
    try std.testing.expectEqual(@as(u32, 1), b.x1);
    try std.testing.expectEqual(@as(u32, 2), b.y1);
    try std.testing.expectEqual(@as(u32, 3), b.x2);
    try std.testing.expectEqual(@as(u32, 4), b.y2);
    try std.testing.expectEqual(true, b.rect);
}

test "inSelection: linewise — any col in [y1..y2]" {
    const s = Selection{ .x1 = 0, .y1 = 1, .x2 = 0, .y2 = 3 }; // linewise (rect=false)
    try std.testing.expect(inSelection(0, 1, s));
    try std.testing.expect(inSelection(5, 3, s)); // full row width regardless of x
    try std.testing.expect(inSelection(9, 2, s)); // any col in-range row
    try std.testing.expect(!inSelection(0, 0, s)); // row above range
    try std.testing.expect(!inSelection(0, 4, s)); // row below range
}

test "inSelection: block (rect) — col in [x1..x2] AND row in [y1..y2]" {
    const s = Selection{ .x1 = 1, .y1 = 0, .x2 = 3, .y2 = 2, .rect = true };
    try std.testing.expect(inSelection(1, 0, s)); // corner
    try std.testing.expect(inSelection(3, 2, s)); // opposite corner
    try std.testing.expect(inSelection(2, 1, s)); // middle
    try std.testing.expect(!inSelection(0, 0, s)); // col out (left)
    try std.testing.expect(!inSelection(4, 1, s)); // col out (right)
    try std.testing.expect(!inSelection(2, 3, s)); // row out
}

test "inAnyMatch: hit/miss across rows + cols" {
    const matches = [_]Match{.{ .y = 2, .x1 = 1, .x2 = 3 }};
    try std.testing.expect(inAnyMatch(1, 2, &matches)); // left edge
    try std.testing.expect(inAnyMatch(3, 2, &matches)); // right edge
    try std.testing.expect(inAnyMatch(2, 2, &matches)); // middle
    try std.testing.expect(!inAnyMatch(0, 2, &matches)); // col before
    try std.testing.expect(!inAnyMatch(4, 2, &matches)); // col after
    try std.testing.expect(!inAnyMatch(1, 1, &matches)); // wrong row
    // Empty slice ⇒ never.
    try std.testing.expect(!inAnyMatch(1, 2, &[_]Match{}));
}

test "highlight: sel-only / match-only / both ⇒ true; neither ⇒ false" {
    const sel = Selection{ .x1 = 0, .y1 = 0, .x2 = 9, .y2 = 0 }; // linewise row 0
    const matches = [_]Match{.{ .y = 1, .x1 = 0, .x2 = 2 }};
    try std.testing.expect(highlight(0, 0, sel, &matches)); // sel hits row 0
    try std.testing.expect(highlight(0, 1, sel, &matches)); // match hits row 1
    try std.testing.expect(!highlight(0, 2, sel, &matches)); // neither
    try std.testing.expect(!highlight(0, 9, null, &[_]Match{})); // neither (null sel, no matches)
}

test "clampScroll: scroll past end clamps; total<=rows ⇒ 0; in-range passthrough" {
    try std.testing.expectEqual(@as(u32, 0), clampScroll(0, 10, 4)); // in-range
    try std.testing.expectEqual(@as(u32, 6), clampScroll(6, 10, 4)); // in-range (max=6)
    try std.testing.expectEqual(@as(u32, 6), clampScroll(7, 10, 4)); // over max ⇒ clamp
    try std.testing.expectEqual(@as(u32, 6), clampScroll(100, 10, 4)); // way over ⇒ clamp
    // total <= viewport_rows ⇒ always 0 (grid fits, no scrolling).
    try std.testing.expectEqual(@as(u32, 0), clampScroll(0, 3, 4));
    try std.testing.expectEqual(@as(u32, 0), clampScroll(100, 3, 4));
    try std.testing.expectEqual(@as(u32, 0), clampScroll(5, 4, 4)); // exact fit
}

// ---- The ONE render integration test (ALL Terminal-building assertions in ONE test fn) ----
// GHOSTTY-VT GOTCHA: Terminal.init leaves process-global state corrupted such that a
// Terminal.init in a SEPARATE test function CRASHES (core dump) (src/render.zig GOTCHA,
// verified). Sequential render() calls in the SAME scope are fine. So ALL render(...)-with-
// a-Terminal assertions share this ONE test fn. PURE helpers above are separate test fns
// (no Terminal ⇒ safe, exactly like render.zig's determineCols/lineCount).

const Terminal = ghostty_vt.Terminal;

/// Build a Screen from ANSI bytes by constructing a Terminal (cols×rows), feeding bytes
/// (\n→\r\n — matches tmux capture output + the verified term2html pattern), then calling
/// view.render into an Allocating writer and returning an OWNED copy of the buffered bytes
/// (caller frees; the Allocating buffer is freed by `defer aw.deinit()` so returning
/// `buffered()` directly would be a use-after-free). Mirrors render.zig's renderToOwned.
fn renderOwned(
    alloc: std.mem.Allocator,
    ansi: []const u8,
    cols: u16,
    rows: u16,
    viewport: Viewport,
    selection: ?Selection,
    matches: []const Match,
) ![]u8 {
    var t = try Terminal.init(alloc, .{ .cols = cols, .rows = rows });
    defer t.deinit(alloc);

    var stream = t.vtStream();
    defer stream.deinit();
    for (ansi) |c| {
        if (c == '\n') try stream.next('\r');
        try stream.next(c);
    }

    var aw = try std.Io.Writer.Allocating.initCapacity(alloc, 4096);
    defer aw.deinit();
    try render(
        &aw.writer,
        t.screens.active,
        palette.defaultColors(),
        viewport,
        .{ .x = 0, .y = 0 },
        selection,
        matches,
    );
    return alloc.dupe(u8, aw.writer.buffered());
}

test "render: full-color grid, selection, match, viewport cap, wide char, below-grid" {
    const alloc = std.testing.allocator;

    // (a) plain text "AB" → output contains "AB" + a CUP "\x1b[1;1H".
    {
        const out = try renderOwned(alloc, "AB", 10, 2, .{ .cols = 10, .rows = 2, .scroll = 0 }, null, &[_]Match{});
        defer alloc.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "AB") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[1;1H") != null); // CUP to row 1, col 1
    }

    // (b) a red-fg ANSI cell ("\x1b[31mX\x1b[0m") under defaultColors() → output contains
    //     "\x1b[38;2;" (palette[1] resolved to RGB, NOT "\x1b[38;5;N") and "X".
    //     Do NOT hardcode the exact RGB — Ghostty's bundled palette[1] value.
    {
        const out = try renderOwned(alloc, "\x1b[31mX\x1b[0m", 10, 2, .{ .cols = 10, .rows = 2, .scroll = 0 }, null, &[_]Match{});
        defer alloc.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[38;2;") != null); // palette-index → RGB
        try std.testing.expect(std.mem.indexOf(u8, out, "X") != null);
    }

    // (c) a Selection over the 'X' cell → those bytes include "\x1b[7m" (reverse).
    {
        const out = try renderOwned(alloc, "\x1b[31mX\x1b[0m", 10, 2, .{ .cols = 10, .rows = 2, .scroll = 0 },
            .{ .x1 = 0, .y1 = 0, .x2 = 0, .y2 = 0 }, &[_]Match{});
        defer alloc.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[7m") != null);
    }

    // (d) a Match over the 'X' cell → "\x1b[7m".
    {
        const out = try renderOwned(alloc, "X", 10, 2, .{ .cols = 10, .rows = 2, .scroll = 0 }, null,
            &[_]Match{.{ .y = 0, .x1 = 0, .x2 = 0 }});
        defer alloc.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[7m") != null);
    }

    // (e) viewport capping: 6-row grid (R0..R5), viewport.rows=3 scroll=2 ⇒ only R2,R3,R4
    //     present; R0/R1/R5 absent.
    {
        const out = try renderOwned(alloc, "R0\nR1\nR2\nR3\nR4\nR5", 10, 6,
            .{ .cols = 10, .rows = 3, .scroll = 2 }, null, &[_]Match{});
        defer alloc.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "R2") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "R3") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "R4") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "R0") == null); // above viewport
        try std.testing.expect(std.mem.indexOf(u8, out, "R1") == null); // above viewport
        try std.testing.expect(std.mem.indexOf(u8, out, "R5") == null); // below viewport
    }

    // (f) a wide char (CJK 真, U+771F) → the glyph appears once; no extra trailing space for
    //     the spacer cell. Count the UTF-8 occurrences of the glyph.
    {
        const out = try renderOwned(alloc, "\xe7\x9c\x9f", 10, 2, .{ .cols = 10, .rows = 2, .scroll = 0 }, null, &[_]Match{});
        defer alloc.free(out);
        // 真 = U+771F = UTF-8 e7 9c 9f. Count occurrences: exactly 1 (spacer cell skipped).
        const glyph = "\xe7\x9c\x9f";
        const count = std.mem.count(u8, out, glyph);
        try std.testing.expectEqual(@as(usize, 1), count);
    }

    // (g) below-grid: viewport.rows=10 with a 2-row grid ⇒ the extra rows get "\x1b[K" and
    //     contain no grid glyphs (R0/R1 ARE grid rows; the below-grid rows are blanked).
    {
        const out = try renderOwned(alloc, "R0\nR1", 10, 2, .{ .cols = 10, .rows = 10, .scroll = 0 }, null, &[_]Match{});
        defer alloc.free(out);
        // The two grid rows are present.
        try std.testing.expect(std.mem.indexOf(u8, out, "R0") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "R1") != null);
        // Below-grid rows (vy 2..9) each get an EL ("\x1b[K") — at least 8 of them.
        const el_count = std.mem.count(u8, out, "\x1b[K");
        try std.testing.expect(el_count >= 8);
    }
}
