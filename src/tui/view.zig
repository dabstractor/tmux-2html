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
/// render() paints the cell at `cursor` in reverse video (a copy-mode block cursor) so it's
/// always visible — even before any selection is started. app.zig keeps the terminal's own
/// cursor hidden (`\x1b[?25l`) because view fully repaints every cell each frame.
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

// ---- S2 public overlay types (status line + search mode) ---------------------
// Forward-contract inputs the region.zig loop (P3.M3) + input/select layers
// (P3.M2) SUPPLY. view.zig is stateless: these are value structs the caller fills.

/// What the status line shows for the selection mode (PRD §7.4: v=linewise,
/// Ctrl-v/R=block). select.zig (P3.M2.T2) owns the model; renderStatus only DISPLAYS
/// the mode it's given — view.zig never tracks it.
pub const SelMode = enum { none, line, block };

/// Everything renderStatus needs to paint the PRD §7.1 copy-mode status line. Pure value
/// struct. `matches` is the SAME slice render() inverts (so the "N match(es)" count == the
/// highlighted hits — single source of truth, always consistent). `pattern` null/empty ⇒
/// the search token is omitted. `cursor` is grid coords; renderStatus prints 1-based row:col.
pub const Status = struct {
    mode: SelMode,
    cursor: Pos, // S1's Pos {x,y} (grid coords)
    pattern: ?[]const u8, // null OR empty ⇒ no search token shown
    matches: []const Match, // count = .len → "N match(es)" (shown only when pattern active)
    has_selection: bool,
};

/// Search mode for findMatches. v1 ships FIXED only: Zig 0.15.2 has NO stdlib regex
/// (`std.regex` does not exist — verified) and adding a regex DEPENDENCY needs a
/// build.zig.zon change (out of scope for this subtask). `.regex` is RESERVED for a future
/// task; findMatches uses std.mem.indexOf (fixed-string) per row.
pub const SearchMode = enum { fixed };

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
/// `cursor`    — the TUI cursor (grid coords). The cell at (cursor.x,cursor.y) within the
///               viewport is painted in reverse video (a copy-mode block cursor), so the
///               cursor is always visible even with no active selection.
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
            // Copy-mode block cursor: force the cursor cell to reverse video so it is ALWAYS
            // visible, even before a selection is started (otherwise the only cue was counting
            // j/k presses). This takes PRECEDENCE over the selection/match XOR above, so the
            // cursor can never be canceled back to invisible. Safe with an active selection:
            // select.zig keeps extent = anchor..cursor, so the cursor is always an ENDPOINT
            // (a boundary cell), never a selection interior — this only re-emphasizes the edge.
            if (gy == cursor.y and gx == cursor.x) s.flags.inverse = true;

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
}

// ---- S2 status line entry point (PRD §7.1 — paints the LAST tty row) -----------

/// Paint the LAST tty row (`tty_rows`, 1-based) with the PRD §7.1 copy-mode status line:
///   `[LINE|BLOCK]  row:N col:M  /pattern  N match(es)  <S-sel>Enter=render q=quit`
/// in reverse+bold (vim `StatusLine` default = reverse; convention confirmed). `cols` is the
/// tty width (a long pattern is truncated so the line fits; no wrap). `tty_rows` is the row
/// to paint (1-based) — the caller passes the LAST screen row; S1's render() paints rows
/// `1..tty_rows-1`, so renderStatus is called AFTER render() with the SAME `matches` slice
/// render() inverted (the "N match(es)" count is therefore always consistent with the grid
/// highlights). Pure given `status`; writes to `out` (*std.Io.Writer).
///
/// Trailing EL (`\x1b[K`) clears stale chars from a longer previous status line (same
/// rationale as S1's below-grid EL — no per-frame 2J). `\x1b[0m` resets SGR state.
pub fn renderStatus(out: *std.Io.Writer, tty_rows: u16, cols: u16, status: Status) !void {
    // CUP to the last row + reverse + bold (vim StatusLine default).
    try out.print("\x1b[{d};1H\x1b[7m\x1b[1m", .{tty_rows});

    // Build the field string in a small fixed buffer, truncate to `cols`, then write once
    // (so a long pattern doesn't wrap to the next row). 256 bytes is generous for the format.
    var buf: [256]u8 = undefined;
    var fw = std.Io.Writer.fixed(&buf);
    const w = &fw;
    // [LINE]/[BLOCK] (omit when mode == .none)
    if (status.mode != .none) {
        const tag: []const u8 = if (status.mode == .line) "LINE" else "BLOCK";
        try w.print("[{s}]  ", .{tag});
    }
    // row:N col:M (1-based, vim/tmux convention)
    try w.print("row:{d} col:{d}", .{ status.cursor.y + 1, status.cursor.x + 1 });
    // /pattern  N match(es) (only when a pattern is active — non-null AND non-empty)
    if (status.pattern) |p| if (p.len > 0) {
        try w.print("  /{s}  {d} match(es)", .{ p, status.matches.len });
    };
    // <S-sel> (only when a selection is active)
    if (status.has_selection) try w.writeAll("  <S-sel>");
    // static key hints (always shown)
    try w.writeAll("  Enter=render q=quit");

    var line = fw.buffered();
    if (line.len > cols) line = line[0..cols]; // truncate to viewport width (no wrap)
    try out.writeAll(line);
    try out.writeAll("\x1b[K\x1b[0m"); // EL (clear stale tail) + reset
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

// ---- S2 match finding (enables the status line "N match(es)" + the grid highlights) ----
// findMatches PRODUCES the []Match slice that render() inverts and renderStatus counts.
// decodeRow walks ONE grid row's cells (the verified S1 path: pin → getRow → getCells) into
// UTF-8 text + a per-BYTE → cell-column map; findInRow is the PURE string scan. v1 =
// fixed-string (Zig 0.15.2 has no stdlib regex; SearchMode.fixed only).

/// One grid row decoded to plain UTF-8 + a per-BYTE → cell-column map (len == text.len).
/// A match's byte range [bs..be-1] maps to inclusive CELL columns col[bs]..col[be-1].
/// Wide-char safe: a `.wide` cell's bytes share its cell index; its spacer is SKIPPED (so
/// the next cell's index is wide_idx+2 — keeps columns aligned, mirroring S1 render's
/// spacer-skip). Grapheme-trail codepoints share the SAME cell index.
const DecodedRow = struct { text: []u8, col: []u16 };

// P3.M3.T1.S1: `pub` so region.zig can pre-decode grid rows into motion.Row{ text, col }.
// DecodedRow STAYS private (line 326) — Zig lets a pub fn return a private struct; callers
// bind the result via type inference. Non-conflicting with the parallel P3.M2.T2.S2 (render.zig).
/// Walk ONE grid row's cells into UTF-8 text + a per-byte cell-column map. Returns empty
/// text/col for rows past the grid (`gy >= total_rows`) or rows that fail to pin. Terminal-
/// needed (Screen walk). `total_rows` is the grid row count (the caller computes it once).
pub fn decodeRow(
    alloc: std.mem.Allocator,
    grid: *const Screen,
    total_rows: u32,
    gy: u32,
) !DecodedRow {
    var text: std.ArrayList(u8) = .{};
    errdefer text.deinit(alloc);
    var col: std.ArrayList(u16) = .{};
    errdefer col.deinit(alloc);

    if (gy >= total_rows)
        return .{ .text = try text.toOwnedSlice(alloc), .col = try col.toOwnedSlice(alloc) };

    const rp = grid.pages.pin(.{ .screen = .{ .x = 0, .y = gy } }) orelse
        return .{ .text = try text.toOwnedSlice(alloc), .col = try col.toOwnedSlice(alloc) };
    const page: *const ghostty_vt.page.Page = &rp.node.data;
    const cells = page.getCells(page.getRow(rp.y));
    const grid_cols: u32 = grid.pages.cols;

    // last_written = byte index of the end of the last NON-BLANK cell's text. Trailing
    // unwritten blank cells (the cells past the row's written content) are trimmed so
    // rowText("hello") == "hello" (vim getline() semantics), not "hello     ". A TYPED
    // space (codepoint 0x20) has hasText()==true so it is preserved; only unwritten cells
    // (hasText()==false) are trimmed when they form the trailing run.
    var last_written: usize = 0;
    var gx: u32 = 0;
    while (gx < grid_cols) : (gx += 1) {
        const cell = cells[gx];
        // Wide-char spacer handling (mirror S1 render's inner loop): spacers contribute
        // nothing — their column is consumed by the .wide cell. Skip them entirely.
        switch (cell.wide) {
            .spacer_head, .spacer_tail => continue,
            .narrow, .wide => {},
        }
        const cellx: u16 = @intCast(gx);
        var cp_buf: [4]u8 = undefined;
        if (cell.hasText()) {
            // Append the primary codepoint's UTF-8 bytes, each tagged with cellx.
            const n = std.unicode.utf8Encode(cell.codepoint(), &cp_buf) catch 0;
            for (cp_buf[0..n]) |by| {
                try text.append(alloc, by);
                try col.append(alloc, cellx);
            }
            // Grapheme-cluster trail (codepoint_grapheme): each trailing cp shares cellx.
            if (cell.content_tag == .codepoint_grapheme) {
                if (page.lookupGrapheme(&cell)) |trail| {
                    for (trail) |cp| {
                        const m = std.unicode.utf8Encode(cp, &cp_buf) catch continue;
                        for (cp_buf[0..m]) |by| {
                            try text.append(alloc, by);
                            try col.append(alloc, cellx);
                        }
                    }
                }
            }
            last_written = text.items.len;
        } else {
            // Blank / bg-only cell → one space (keeps text.len aligned with cells).
            try text.append(alloc, ' ');
            try col.append(alloc, cellx);
        }
    }
    // Truncate the trailing blank-cell run (text.len and col.len shrink together — they
    // stayed parallel, so col[last_written] is still the correct cell column).
    text.items.len = last_written;
    col.items.len = last_written;
    return .{ .text = try text.toOwnedSlice(alloc), .col = try col.toOwnedSlice(alloc) };
}

/// PUBLIC convenience: decode a row to plain UTF-8 text (caller frees). Used by region.zig
/// if it needs the text (e.g. yanking); findMatches calls decodeRow internally.
pub fn rowText(alloc: std.mem.Allocator, grid: *const Screen, total_rows: u32, y: u32) ![]u8 {
    const d = try decodeRow(alloc, grid, total_rows, y);
    alloc.free(d.col);
    return d.text;
}

/// PURE: scan decoded `text` for ALL non-overlapping occurrences of `needle` (std.mem.indexOf
/// loop), map each hit's byte range to inclusive CELL columns via `col`, and append
/// `Match{ .y = y, .x1 = col[hit], .x2 = col[hit + needle.len - 1] }` to `list`. needle.len==0
/// or longer than text ⇒ nothing. Multiple hits per row ⇒ multiple Matches.
fn findInRow(
    text: []const u8,
    col: []const u16,
    needle: []const u8,
    y: u32,
    list: *std.ArrayList(Match),
    alloc: std.mem.Allocator,
) !void {
    if (needle.len == 0 or needle.len > text.len) return;
    var start: usize = 0;
    while (start <= text.len - needle.len) {
        const hit = std.mem.indexOfPos(u8, text, start, needle) orelse break;
        const be = hit + needle.len; // exclusive end; last matched byte = be-1
        try list.append(alloc, .{ .y = y, .x1 = col[hit], .x2 = col[be - 1] });
        start = be; // non-overlapping: next search starts after this hit
    }
}

/// Scan EVERY grid row for `needle`, producing per-row Match ranges (inclusive CELL columns).
/// v1: fixed-string (`SearchMode.fixed` only — no stdlib regex in Zig 0.15.2). needle.len==0
/// ⇒ empty result. Case-sensitive (vim default; `/i` is a future option). Caller owns the
/// returned slice (free with the SAME allocator). `total_rows` = grid row count.
pub fn findMatches(
    alloc: std.mem.Allocator,
    grid: *const Screen,
    needle: []const u8,
    mode: SearchMode,
    total_rows: u32,
) ![]Match {
    var list: std.ArrayList(Match) = .{};
    errdefer list.deinit(alloc);
    // v1 ships .fixed only; the mode param reserves the seam for a future regex dependency.
    if (mode == .fixed and needle.len > 0) {
        var y: u32 = 0;
        while (y < total_rows) : (y += 1) {
            const d = try decodeRow(alloc, grid, total_rows, y);
            defer alloc.free(d.text);
            defer alloc.free(d.col);
            try findInRow(d.text, d.col, needle, y, &list, alloc);
        }
    }
    return list.toOwnedSlice(alloc);
}

/// Clamp scroll so the viewport can't scroll past the grid end. (S2 passes the clamped
/// scroll; this is the pure math, unit-tested independently.)
pub fn clampScroll(scroll: u32, total_rows: u32, viewport_rows: u16) u32 {
    if (total_rows <= viewport_rows) return 0;
    const max = total_rows - @as(u32, viewport_rows);
    return @min(scroll, max);
}

// ---- S2 PURE viewport scroll arithmetic (vim :help scroll.txt — validated formulas) ----
// Every fn returns a scroll clamped to [0, max(0,total-rows)] via clampScroll (the NO-EMPTY
// EOF model: MAXSCROLL = max(0,total-rows) — consistent with S1; no '~' empty markers here).
// The input layer (P3.M2.T1 vim motions) COMPOSES these; S2 provides arithmetic only.
// SATURATING subtract everywhere (u32 underflow traps in Debug / is UB-adjacent in ReleaseFast).

/// Keep the cursor visible with MINIMAL scroll (the workhorse — call after every cursor
/// move). scroll-cursor semantics with scrolloff=0 (`:help scroll-cursor`). If the cursor
/// is already in [scroll, scroll+rows-1] the scroll is unchanged; if above, snap top to the
/// cursor; if below, snap so the cursor is the last visible row. `total<=rows ⇒ 0`.
pub fn scrollForCursor(cursor_y: u32, viewport: Viewport, total_rows: u32) u32 {
    const rows = viewport.rows;
    if (total_rows <= rows) return 0;
    const last = viewport.scroll + @as(u32, rows) - 1; // last visible grid row
    const new: u32 = if (cursor_y < viewport.scroll) cursor_y
        else if (cursor_y > last) cursor_y - (@as(u32, rows) - 1)
        else viewport.scroll;
    return clampScroll(new, total_rows, rows);
}

/// zz: center the viewport on the cursor. The cursor is UNCHANGED (the input layer keeps
/// it); only scroll moves. `scroll = cursor_y - rows/2` (saturating), clamped.
pub fn centerOnCursor(cursor_y: u32, viewport_rows: u16, total_rows: u32) u32 {
    const half = @as(u32, viewport_rows) / 2;
    const c = if (cursor_y >= half) cursor_y - half else 0;
    return clampScroll(c, total_rows, viewport_rows);
}

/// zt: cursor at the TOP of the viewport. `scroll = cursor_y`, clamped.
pub fn topOnCursor(cursor_y: u32, viewport_rows: u16, total_rows: u32) u32 {
    return clampScroll(cursor_y, total_rows, viewport_rows);
}

/// zb: cursor at the BOTTOM of the viewport. `scroll = cursor_y - (rows-1)` (saturating),
/// clamped.
pub fn bottomOnCursor(cursor_y: u32, viewport_rows: u16, total_rows: u32) u32 {
    const up = if (cursor_y >= @as(u32, viewport_rows) - 1)
        cursor_y - (@as(u32, viewport_rows) - 1)
    else
        0;
    return clampScroll(up, total_rows, viewport_rows);
}

/// Ctrl-f / PgDn: `+rows`, clamped.
pub fn pageDown(scroll: u32, total_rows: u32, viewport_rows: u16) u32 {
    return clampScroll(scroll + @as(u32, viewport_rows), total_rows, viewport_rows);
}

/// Ctrl-b / PgUp: `-rows` (saturating), clamped.
pub fn pageUp(scroll: u32, total_rows: u32, viewport_rows: u16) u32 {
    const r = @as(u32, viewport_rows);
    const s = if (scroll >= r) scroll - r else 0;
    return clampScroll(s, total_rows, viewport_rows);
}

/// Ctrl-d: `+rows/2` (floor), clamped.
pub fn halfPageDown(scroll: u32, total_rows: u32, viewport_rows: u16) u32 {
    return clampScroll(scroll + @as(u32, viewport_rows) / 2, total_rows, viewport_rows);
}

/// Ctrl-u: `-rows/2` (floor, saturating), clamped.
pub fn halfPageUp(scroll: u32, total_rows: u32, viewport_rows: u16) u32 {
    const half = @as(u32, viewport_rows) / 2;
    const s = if (scroll >= half) scroll - half else 0;
    return clampScroll(s, total_rows, viewport_rows);
}

/// G: max scroll (last line at viewport bottom). `clampScroll(maxInt, …) = max(0,total-rows)`.
pub fn scrollToBottom(total_rows: u32, viewport_rows: u16) u32 {
    return clampScroll(std.math.maxInt(u32), total_rows, viewport_rows);
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

// ---- S2 PURE scroll-math tests (separate test fns — NO Terminal ⇒ no cross-test GOTCHA) ----
// Formulas validated against vim :help scroll.txt (research/external_scroll_statusline.md).

test "scrollForCursor: minimal keep-visible; in-view unchanged; total<=rows ⇒ 0" {
    // cursor above viewport ⇒ scroll snaps to cursor (top = cursor).
    try std.testing.expectEqual(@as(u32, 8), scrollForCursor(8, .{ .cols = 10, .rows = 5, .scroll = 10 }, 20));
    // cursor below viewport ⇒ cursor becomes the last visible row (scroll = cursor-(rows-1)).
    try std.testing.expectEqual(@as(u32, 12), scrollForCursor(16, .{ .cols = 10, .rows = 5, .scroll = 10 }, 20));
    // cursor already in view ⇒ scroll unchanged.
    try std.testing.expectEqual(@as(u32, 10), scrollForCursor(12, .{ .cols = 10, .rows = 5, .scroll = 10 }, 20));
    // total <= rows ⇒ always 0 regardless of cursor/scroll.
    try std.testing.expectEqual(@as(u32, 0), scrollForCursor(2, .{ .cols = 10, .rows = 5, .scroll = 0 }, 3));
    try std.testing.expectEqual(@as(u32, 0), scrollForCursor(2, .{ .cols = 10, .rows = 5, .scroll = 4 }, 3));
    // near EOF clamp: cursor 19 (last row), rows 5, scroll 10 ⇒ cursor-(rows-1)=15, maxscroll=15.
    try std.testing.expectEqual(@as(u32, 15), scrollForCursor(19, .{ .cols = 10, .rows = 5, .scroll = 10 }, 20));
    // cursor 0 from any scroll ⇒ 0.
    try std.testing.expectEqual(@as(u32, 0), scrollForCursor(0, .{ .cols = 10, .rows = 5, .scroll = 10 }, 20));
}

test "centerOnCursor: zz centers on cursor; saturating subtract at top; clamps at EOF" {
    // cursor 15, rows 10 (half 5) ⇒ 15-5 = 10; maxscroll=10 ⇒ 10.
    try std.testing.expectEqual(@as(u32, 10), centerOnCursor(15, 10, 20));
    // cursor 2, half 5 ⇒ saturate to 0.
    try std.testing.expectEqual(@as(u32, 0), centerOnCursor(2, 10, 20));
    // clamp at EOF: cursor 19, rows 10, total 20 ⇒ maxscroll=10 (19-5=14 clamps to 10).
    try std.testing.expectEqual(@as(u32, 10), centerOnCursor(19, 10, 20));
    // total <= rows ⇒ 0.
    try std.testing.expectEqual(@as(u32, 0), centerOnCursor(3, 10, 5));
}

test "topOnCursor: zt puts cursor at viewport top; clamps at EOF" {
    // cursor 17, rows 5, total 20 ⇒ maxscroll 15; 17 > 15 ⇒ clamp to 15.
    try std.testing.expectEqual(@as(u32, 15), topOnCursor(17, 5, 20));
    // cursor 3 ⇒ scroll 3 (in range).
    try std.testing.expectEqual(@as(u32, 3), topOnCursor(3, 5, 20));
    // total <= rows ⇒ 0.
    try std.testing.expectEqual(@as(u32, 0), topOnCursor(3, 5, 3));
}

test "bottomOnCursor: zb puts cursor at viewport bottom; saturating + clamp" {
    // cursor 17, rows 5 ⇒ 17-(5-1)=13; maxscroll 15 ⇒ 13.
    try std.testing.expectEqual(@as(u32, 13), bottomOnCursor(17, 5, 20));
    // cursor 2, rows 5 ⇒ 2-(5-1) underflows ⇒ saturate to 0.
    try std.testing.expectEqual(@as(u32, 0), bottomOnCursor(2, 5, 20));
    // cursor 0, rows 5 ⇒ saturate 0.
    try std.testing.expectEqual(@as(u32, 0), bottomOnCursor(0, 5, 20));
    // total <= rows ⇒ 0.
    try std.testing.expectEqual(@as(u32, 0), bottomOnCursor(2, 5, 3));
}

test "pageDown/pageUp: ±rows; clamp at EOF; saturating up at BOF" {
    // scroll 10, rows 5, total 20 ⇒ down 15, up 5.
    try std.testing.expectEqual(@as(u32, 15), pageDown(10, 20, 5));
    try std.testing.expectEqual(@as(u32, 5), pageUp(10, 20, 5));
    // pageDown past EOF clamps: scroll 17, rows 5, total 20 ⇒ maxscroll 15.
    try std.testing.expectEqual(@as(u32, 15), pageDown(17, 20, 5));
    // pageUp saturating: scroll 2, rows 5 ⇒ 0.
    try std.testing.expectEqual(@as(u32, 0), pageUp(2, 20, 5));
    // total <= rows ⇒ 0 for both.
    try std.testing.expectEqual(@as(u32, 0), pageDown(0, 3, 5));
    try std.testing.expectEqual(@as(u32, 0), pageUp(0, 3, 5));
}

test "halfPageDown/halfPageUp: ±rows/2 (floor); clamp; saturating up" {
    // scroll 2, rows 10 (half 5) ⇒ down 7, up 0 (2<5 saturates).
    try std.testing.expectEqual(@as(u32, 7), halfPageDown(2, 20, 10));
    try std.testing.expectEqual(@as(u32, 0), halfPageUp(2, 20, 10));
    // scroll 10, rows 10, total 20 ⇒ down clamps at maxscroll 10 (10 already at max).
    try std.testing.expectEqual(@as(u32, 10), halfPageDown(10, 20, 10));
    // halfPageUp from mid: scroll 10, half 5 ⇒ 5.
    try std.testing.expectEqual(@as(u32, 5), halfPageUp(10, 20, 10));
    // halfPageDown past EOF clamps: scroll 8, rows 10, total 20 ⇒ maxscroll 10 (8+5=13⇒10).
    try std.testing.expectEqual(@as(u32, 10), halfPageDown(8, 20, 10));
    // total <= rows ⇒ 0.
    try std.testing.expectEqual(@as(u32, 0), halfPageDown(0, 3, 5));
    try std.testing.expectEqual(@as(u32, 0), halfPageUp(0, 3, 5));
}

test "scrollToBottom: G ⇒ max(0, total-rows); total<=rows ⇒ 0" {
    try std.testing.expectEqual(@as(u32, 15), scrollToBottom(20, 5)); // max(0,20-5)
    try std.testing.expectEqual(@as(u32, 0), scrollToBottom(3, 5)); // total<=rows
    try std.testing.expectEqual(@as(u32, 0), scrollToBottom(5, 5)); // exact fit
    try std.testing.expectEqual(@as(u32, 6), scrollToBottom(10, 4)); // max(0,10-4)
}

// ---- S2 renderStatus tests (PURE — Status struct only, no Terminal) ----

/// Render a Status into an Allocating writer and return an OWNED copy of the bytes
/// (caller frees; Allocating.deinit frees the buffer that buffered() points into).
fn statusOwned(alloc: std.mem.Allocator, tty_rows: u16, cols: u16, status: Status) ![]u8 {
    var aw = try std.Io.Writer.Allocating.initCapacity(alloc, 4096);
    defer aw.deinit();
    try renderStatus(&aw.writer, tty_rows, cols, status);
    return alloc.dupe(u8, aw.writer.buffered());
}

test "renderStatus: [LINE] full line — exact field order, reverse SGR, EL tail" {
    const alloc = std.testing.allocator;
    const matches = [_]Match{ .{ .y = 0, .x1 = 0, .x2 = 1 }, .{ .y = 1, .x1 = 0, .x2 = 1 }, .{ .y = 2, .x1 = 0, .x2 = 1 } };
    const out = try statusOwned(alloc, 24, 80, .{
        .mode = .line,
        .cursor = .{ .x = 3, .y = 2 },
        .pattern = "foo",
        .matches = &matches,
        .has_selection = true,
    });
    defer alloc.free(out);
    // CUP to last row + reverse + bold.
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[24;1H\x1b[7m\x1b[1m") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[LINE]") != null);
    // 1-based row:col (cursor.y+1=3, cursor.x+1=4).
    try std.testing.expect(std.mem.indexOf(u8, out, "row:3 col:4") != null);
    // /pattern  N match(es) (N = matches.len = 3).
    try std.testing.expect(std.mem.indexOf(u8, out, "/foo  3 match(es)") != null);
    // <S-sel> shown (has_selection).
    try std.testing.expect(std.mem.indexOf(u8, out, "<S-sel>") != null);
    // static hints.
    try std.testing.expect(std.mem.indexOf(u8, out, "Enter=render q=quit") != null);
    // trailing EL + reset.
    try std.testing.expect(std.mem.endsWith(u8, out, "\x1b[K\x1b[0m"));
}

test "renderStatus: [BLOCK] mode + field order" {
    const alloc = std.testing.allocator;
    const out = try statusOwned(alloc, 24, 80, .{
        .mode = .block,
        .cursor = .{ .x = 0, .y = 0 },
        .pattern = "",
        .matches = &[_]Match{},
        .has_selection = false,
    });
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "[BLOCK]") != null);
    // 1-based: cursor (0,0) ⇒ row:1 col:1.
    try std.testing.expect(std.mem.indexOf(u8, out, "row:1 col:1") != null);
    // empty pattern ⇒ no search token; no selection ⇒ no <S-sel>.
    try std.testing.expect(std.mem.indexOf(u8, out, "match(es)") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<S-sel>") == null);
    try std.testing.expect(std.mem.endsWith(u8, out, "\x1b[K\x1b[0m"));
}

test "renderStatus: mode=.none omits the bracket; no pattern omits /pat" {
    const alloc = std.testing.allocator;
    const out = try statusOwned(alloc, 24, 80, .{
        .mode = .none,
        .cursor = .{ .x = 5, .y = 9 },
        .pattern = null,
        .matches = &[_]Match{},
        .has_selection = false,
    });
    defer alloc.free(out);
    // no bracket tag.
    try std.testing.expect(std.mem.indexOf(u8, out, "[LINE]") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[BLOCK]") == null);
    // 1-based: cursor (5,9) ⇒ row:10 col:6.
    try std.testing.expect(std.mem.indexOf(u8, out, "row:10 col:6") != null);
    // null pattern ⇒ no search token.
    try std.testing.expect(std.mem.indexOf(u8, out, "match(es)") == null);
    // static hints still present.
    try std.testing.expect(std.mem.indexOf(u8, out, "Enter=render q=quit") != null);
}

test "renderStatus: truncates the line to cols (no wrap)" {
    const alloc = std.testing.allocator;
    // Very long pattern + cols=10 ⇒ the emitted line (between SGR prologue and EL tail) ≤ 10.
    const out = try statusOwned(alloc, 24, 10, .{
        .mode = .none,
        .cursor = .{ .x = 0, .y = 0 },
        .pattern = "a_really_long_pattern_that_exceeds_the_width",
        .matches = &[_]Match{},
        .has_selection = false,
    });
    defer alloc.free(out);
    // The structure is: CUP + reverse/bold + <line ≤ cols> + EL + reset.
    // Strip the trailing "\x1b[K\x1b[0m" and confirm the line region is ≤ 10 bytes.
    const tail = "\x1b[K\x1b[0m";
    try std.testing.expect(std.mem.endsWith(u8, out, tail));
    const line_end = out.len - tail.len;
    // Find where the line starts: after the prologue "\x1b[24;1H\x1b[7m\x1b[1m".
    const prologue = "\x1b[24;1H\x1b[7m\x1b[1m";
    const line_start = std.mem.indexOf(u8, out, prologue).? + prologue.len;
    const line = out[line_start..line_end];
    try std.testing.expect(line.len <= 10);
}

// ---- S2 findInRow tests (PURE — string + col_map, no Terminal) ----

test "findInRow: single hit maps byte-range to cell cols; multiple hits; edge cases" {
    const alloc = std.testing.allocator;
    // (a) "hello world", identity col_map 0..10, needle "world", y=3 ⇒ one Match {3,6,10}.
    {
        var list: std.ArrayList(Match) = .{};
        defer list.deinit(alloc);
        const text = "hello world";
        const cols = [_]u16{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
        try findInRow(text, &cols, "world", 3, &list, alloc);
        try std.testing.expectEqual(@as(usize, 1), list.items.len);
        try std.testing.expectEqual(@as(u32, 3), list.items[0].y);
        try std.testing.expectEqual(@as(u32, 6), list.items[0].x1);
        try std.testing.expectEqual(@as(u32, 10), list.items[0].x2);
    }
    // (b) "aaa", identity, needle "a", y=0 ⇒ three non-overlapping Matches {0,0,0}{0,1,1}{0,2,2}.
    {
        var list: std.ArrayList(Match) = .{};
        defer list.deinit(alloc);
        const text = "aaa";
        const cols = [_]u16{ 0, 1, 2 };
        try findInRow(text, &cols, "a", 0, &list, alloc);
        try std.testing.expectEqual(@as(usize, 3), list.items.len);
        try std.testing.expectEqual(@as(u32, 0), list.items[0].x1);
        try std.testing.expectEqual(@as(u32, 0), list.items[0].x2);
        try std.testing.expectEqual(@as(u32, 1), list.items[1].x1);
        try std.testing.expectEqual(@as(u32, 1), list.items[1].x2);
        try std.testing.expectEqual(@as(u32, 2), list.items[2].x1);
        try std.testing.expectEqual(@as(u32, 2), list.items[2].x2);
    }
    // (c) empty needle ⇒ nothing.
    {
        var list: std.ArrayList(Match) = .{};
        defer list.deinit(alloc);
        const cols = [_]u16{ 0, 1, 2 };
        try findInRow("abc", &cols, "", 0, &list, alloc);
        try std.testing.expectEqual(@as(usize, 0), list.items.len);
    }
    // (d) needle longer than text ⇒ nothing.
    {
        var list: std.ArrayList(Match) = .{};
        defer list.deinit(alloc);
        const cols = [_]u16{ 0, 1 };
        try findInRow("ab", &cols, "abcd", 0, &list, alloc);
        try std.testing.expectEqual(@as(usize, 0), list.items.len);
    }
    // (e) wide-ish col_map: bytes 0..3 → cols [5,5,6,6]; needle covering bytes 1..2 ⇒
    //     x1=col[1]=5, x2=col[2]=6 (a 2-byte needle maps to inclusive cell cols).
    {
        var list: std.ArrayList(Match) = .{};
        defer list.deinit(alloc);
        const text = "abcd"; // needle "bc" hits bytes 1..2
        const cols = [_]u16{ 5, 5, 6, 6 };
        try findInRow(text, &cols, "bc", 0, &list, alloc);
        try std.testing.expectEqual(@as(usize, 1), list.items.len);
        try std.testing.expectEqual(@as(u32, 5), list.items[0].x1);
        try std.testing.expectEqual(@as(u32, 6), list.items[0].x2);
    }
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
        // Off-grid cursor: the content/selection/match/viewport assertions below are about the
        // GRID paint, so they must NOT be perturbed by the (separately tested) cursor highlight.
        .{ .x = 0, .y = std.math.maxInt(u32) },
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

    // ---- S2 match-finding assertions (APPENDED to this single Terminal test fn — ----
    // the ghostty-vt cross-test GOTCHA: a Terminal.init in a SEPARATE test fn crashes).
    // All decodeRow/rowText/findMatches assertions share THIS scope. std.testing.allocator
    // verifies no leaks (every owned slice is freed before the fn ends).

    // (h) rowText decodes a row to plain UTF-8; findMatches finds a 2-char needle's cell range.
    {
        var t = try Terminal.init(alloc, .{ .cols = 10, .rows = 4 });
        defer t.deinit(alloc);
        var stream = t.vtStream();
        defer stream.deinit();
        for ("hello\nworld") |c| {
            if (c == '\n') try stream.next('\r');
            try stream.next(c);
        }
        const grid = t.screens.active;
        const total: u32 = blk: {
            const br = grid.pages.getBottomRight(.screen) orelse break :blk 0;
            const br_pt = grid.pages.pointFromPin(.screen, br) orelse break :blk 0;
            break :blk br_pt.coord().y + 1;
        };
        // rowText(y=0) == "hello".
        const rt = try rowText(alloc, grid, total, 0);
        defer alloc.free(rt);
        try std.testing.expectEqualStrings("hello", rt);
        // rowText(y=1) == "world".
        const rt1 = try rowText(alloc, grid, total, 1);
        defer alloc.free(rt1);
        try std.testing.expectEqualStrings("world", rt1);
        // findMatches("ll", .fixed) ⇒ one Match on row 0 at x1=2, x2=3.
        const m_ll = try findMatches(alloc, grid, "ll", .fixed, total);
        defer alloc.free(m_ll);
        try std.testing.expectEqual(@as(usize, 1), m_ll.len);
        try std.testing.expectEqual(@as(u32, 0), m_ll[0].y);
        try std.testing.expectEqual(@as(u32, 2), m_ll[0].x1);
        try std.testing.expectEqual(@as(u32, 3), m_ll[0].x2);
    }

    // (i) multiple hits across rows: findMatches("o", .fixed) on "hello\nworld" ⇒ two Matches
    //     (row 0 x4..4, row 1 x1..4). "world" has 'o' at col 1 AND col 4 ("w-o-r-l-d" → no,
    //     'o' is only at col 1). Re-check: row 0 'o' at col 4; row 1 'o' at col 1.
    {
        var t = try Terminal.init(alloc, .{ .cols = 10, .rows = 4 });
        defer t.deinit(alloc);
        var stream = t.vtStream();
        defer stream.deinit();
        for ("hello\nworld") |c| {
            if (c == '\n') try stream.next('\r');
            try stream.next(c);
        }
        const grid = t.screens.active;
        const total: u32 = blk: {
            const br = grid.pages.getBottomRight(.screen) orelse break :blk 0;
            const br_pt = grid.pages.pointFromPin(.screen, br) orelse break :blk 0;
            break :blk br_pt.coord().y + 1;
        };
        const m_o = try findMatches(alloc, grid, "o", .fixed, total);
        defer alloc.free(m_o);
        // "hello" → 'o' at col 4; "world" → 'o' at col 1. Two hits total.
        try std.testing.expectEqual(@as(usize, 2), m_o.len);
        try std.testing.expectEqual(@as(u32, 0), m_o[0].y);
        try std.testing.expectEqual(@as(u32, 4), m_o[0].x1);
        try std.testing.expectEqual(@as(u32, 4), m_o[0].x2);
        try std.testing.expectEqual(@as(u32, 1), m_o[1].y);
        try std.testing.expectEqual(@as(u32, 1), m_o[1].x1);
        try std.testing.expectEqual(@as(u32, 1), m_o[1].x2);
    }

    // (j) empty needle ⇒ empty slice (and no leaks).
    {
        var t = try Terminal.init(alloc, .{ .cols = 10, .rows = 2 });
        defer t.deinit(alloc);
        var stream = t.vtStream();
        defer stream.deinit();
        for ("hello") |c| try stream.next(c);
        const grid = t.screens.active;
        const total: u32 = blk: {
            const br = grid.pages.getBottomRight(.screen) orelse break :blk 0;
            const br_pt = grid.pages.pointFromPin(.screen, br) orelse break :blk 0;
            break :blk br_pt.coord().y + 1;
        };
        const m = try findMatches(alloc, grid, "", .fixed, total);
        defer alloc.free(m);
        try std.testing.expectEqual(@as(usize, 0), m.len);
    }

    // (k) wide char (CJK 真 U+771F): findMatches for the glyph's text ⇒ the Match's x1/x2
    //     are the inclusive CELL cols. The wide glyph spans 2 cells (col 0 .wide, col 1
    //     spacer); its text is one codepoint. So x1 == x2 == 0 (the .wide cell's col; the
    //     spacer is skipped, not double-counted).
    {
        var t = try Terminal.init(alloc, .{ .cols = 10, .rows = 2 });
        defer t.deinit(alloc);
        var stream = t.vtStream();
        defer stream.deinit();
        // 真 = U+771F = UTF-8 e7 9c 9f. Feed it as raw bytes (the VT decodes UTF-8).
        for ("\xe7\x9c\x9f") |c| try stream.next(c);
        const grid = t.screens.active;
        const total: u32 = blk: {
            const br = grid.pages.getBottomRight(.screen) orelse break :blk 0;
            const br_pt = grid.pages.pointFromPin(.screen, br) orelse break :blk 0;
            break :blk br_pt.coord().y + 1;
        };
        // rowText(y=0) == the 真 glyph as UTF-8.
        const rt = try rowText(alloc, grid, total, 0);
        defer alloc.free(rt);
        try std.testing.expectEqualStrings("\xe7\x9c\x9f", rt);
        // findMatches for the glyph text ⇒ one Match, x1=x2=0 (the .wide cell's col).
        const m = try findMatches(alloc, grid, "\xe7\x9c\x9f", .fixed, total);
        defer alloc.free(m);
        try std.testing.expectEqual(@as(usize, 1), m.len);
        try std.testing.expectEqual(@as(u32, 0), m[0].y);
        try std.testing.expectEqual(@as(u32, 0), m[0].x1);
        try std.testing.expectEqual(@as(u32, 0), m[0].x2);
    }

    // (l) multiple hits per row: "abab" + needle "ab" ⇒ two non-overlapping Matches on row 0
    //     at cols 0..1 and 2..3.
    {
        var t = try Terminal.init(alloc, .{ .cols = 10, .rows = 2 });
        defer t.deinit(alloc);
        var stream = t.vtStream();
        defer stream.deinit();
        for ("abab") |c| try stream.next(c);
        const grid = t.screens.active;
        const total: u32 = blk: {
            const br = grid.pages.getBottomRight(.screen) orelse break :blk 0;
            const br_pt = grid.pages.pointFromPin(.screen, br) orelse break :blk 0;
            break :blk br_pt.coord().y + 1;
        };
        const m = try findMatches(alloc, grid, "ab", .fixed, total);
        defer alloc.free(m);
        try std.testing.expectEqual(@as(usize, 2), m.len);
        try std.testing.expectEqual(@as(u32, 0), m[0].y);
        try std.testing.expectEqual(@as(u32, 0), m[0].x1);
        try std.testing.expectEqual(@as(u32, 1), m[0].x2);
        try std.testing.expectEqual(@as(u32, 0), m[1].y);
        try std.testing.expectEqual(@as(u32, 2), m[1].x1);
        try std.testing.expectEqual(@as(u32, 3), m[1].x2);
    }

    // (m) cursor visibility (no selection): the cell under the cursor is painted reverse (a
    //     copy-mode block cursor) so the user always sees where they are. Built inline (NOT via
    //     renderOwned, which pins an OFF-GRID cursor) because this case needs the cursor ON-grid.
    //     Cursor on 'B' (x=1,y=0) over "AB" ⇒ 'B' is reverse; both glyphs still render.
    {
        var t = try Terminal.init(alloc, .{ .cols = 10, .rows = 2 });
        defer t.deinit(alloc);
        var stream = t.vtStream();
        defer stream.deinit();
        for ("AB") |c| {
            if (c == '\n') try stream.next('\r');
            try stream.next(c);
        }
        var aw = try std.Io.Writer.Allocating.initCapacity(alloc, 4096);
        defer aw.deinit();
        try render(
            &aw.writer,
            t.screens.active,
            palette.defaultColors(),
            .{ .cols = 10, .rows = 2, .scroll = 0 },
            .{ .x = 1, .y = 0 },
            null,
            &[_]Match{},
        );
        const out = try alloc.dupe(u8, aw.writer.buffered());
        defer alloc.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[7m") != null); // 'B' cursor is reverse
        try std.testing.expect(std.mem.indexOf(u8, out, "A") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "B") != null);
    }

    // (n) cursor on a BLANK trailing cell (past the row's written content) still renders a
    //     visible reverse-video block — the cursor must never vanish on empty space.
    {
        var t = try Terminal.init(alloc, .{ .cols = 10, .rows = 2 });
        defer t.deinit(alloc);
        var stream = t.vtStream();
        defer stream.deinit();
        for ("A") |c| try stream.next(c); // only col 0 written; cursor lands on blank col 5
        var aw = try std.Io.Writer.Allocating.initCapacity(alloc, 4096);
        defer aw.deinit();
        try render(
            &aw.writer,
            t.screens.active,
            palette.defaultColors(),
            .{ .cols = 10, .rows = 2, .scroll = 0 },
            .{ .x = 5, .y = 0 },
            null,
            &[_]Match{},
        );
        const out = try alloc.dupe(u8, aw.writer.buffered());
        defer alloc.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[7m") != null); // reverse block on blank
    }
}
