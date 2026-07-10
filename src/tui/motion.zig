//! motion.zig — the PURE cursor/motion/search NAVIGATION engine for the copy-mode TUI
//! (PRD §7.2 vim movements + §7.3 search navigation; arch tui_region.md §3/§6).
//!
//! Consumes the decoded `input.Key` (P3.M2.T1.S1 — SHIPPED; CONSUME its `Motion`/`Key`),
//! REUSES `view`'s types (`Pos`/`Viewport`/`Match`) + scroll math (`scrollForCursor`,
//! `pageDown`, `halfPageDown`, `scrollToBottom`, `topOnCursor`, ...) + the `findMatches`
//! scan (P3.M1.T2 — SHIPPED) and produces:
//!   - `Cursor` — the navigable cursor state (pos + viewport).
//!   - a `Grid` line-provider seam (`ctx:*anyopaque` + `getRowFn`) + `Row` (per-byte →
//!     cell-column map) — motion.zig NEVER touches ghostty-vt's `Screen` directly ⇒ it is
//!     PURE and testable via `SliceGrid` (no Terminal ⇒ no cross-test GOTCHA).
//!   - the PURE motion primitives (`wordForward`/`wordBackward`/`wordEnd`/`matchBracket`/
//!     `paragraphBack`/`paragraphFwd`).
//!   - `applyMotion` — the dispatcher switching on ALL 21 `input.Motion` variants.
//!   - `SearchState` + `nextMatch`/`prevMatch` — match-list navigation with wraparound.
//!
//! Layering (arch §3): `app.readEvent → input.decode → input.Key → motion.applyMotion(...) →
//! repaint` / `motion.nextMatch(...) → cursor.pos → scrollForCursor → repaint`. region.zig
//! (P3.M3) OWNS a `Cursor` + `SearchState` in its EventHandler ctx and wires the pipeline.
//!
//! Anti-scope (sibling subtasks — NOT here):
//!   - key DECODING                      — input.zig (S1 CONTRACT — consume, never re-implement).
//!   - scroll math / search SCAN         — view.zig (SHIPPED — reuse, never re-derive/re-scan).
//!   - event loop / pattern typing       — region.zig (P3.M3 — owns Cursor + SearchState).
//!   - selection model                   — select.zig (P3.M2.T2 — reads cursor.pos).
//!
//! Deliberate TUI simplifications (documented divergences from full vim — see
//! `vim_motion_semantics.md`):
//!   - Two-class WORD model: a "word" = a maximal run of NON-WHITESPACE chars (== vim W/B/E).
//!     `foo.bar` is ONE word (vim `w` would split it).
//!   - `{`/`}` jump to the nearest ALL-BLANK row strictly above/below (no consecutive-row
//!     collapsing).
//!   - `%` ALWAYS does bracket matching (count ignored; percent-of-file jumps out of scope).
//!   - `G` with `count <= 1` ⇒ LAST row (the `1G`-vs-`G` ambiguity is a documented v1 limit
//!     of `input.Key.count` defaulting to 1 with NO `has_count` field — see input.zig).

const std = @import("std");
const view = @import("view.zig"); // Pos, Viewport, Match, scroll fns (SHIPPED — reuse)
const input = @import("input.zig"); // Key, Motion, Action, Search (S1 CONTRACT — consume)

// ============================================================================
// Public types — the contract surface (verbatim from research/design_notes.md §1).
// ============================================================================

/// The navigable cursor state. `pos` is a grid cell (x=col, y=row, origin top-left); `viewport`
/// is the visible window. select.zig (P3.M2.T2) reads `.pos`; region.zig (P3.M3) owns a Cursor
/// in its EventHandler ctx and updates it via applyMotion/nextMatch.
pub const Cursor = struct {
    pos: view.Pos,
    viewport: view.Viewport,
};

/// One decoded grid row: UTF-8 text (trailing blank cells TRIMMED — vim getline() semantics) +
/// a per-BYTE → cell-column map (len == text.len). A motion landing on byte `b` sets cursor.x =
/// `col[b]` (wide-char-correct: a `.wide` cell's bytes share its index; spacers are skipped —
/// mirrors view's decodeRow). Borrowed slices (valid until the next Grid.getRow call).
pub const Row = struct { text: []const u8, col: []const u16 };

/// The line-provider seam — MIRRORS capture.Runner / app.Input / input.EventReader (NON-nullable
/// ctx:*anyopaque + one fn pointer + thin method). motion.zig NEVER touches ghostty-vt's Screen
/// directly: all text comes through this seam ⇒ motion.zig's fns are PURE + fully testable via
/// SliceGrid (no Terminal ⇒ safe as separate test fns). region.zig (P3.M3) supplies the prod Grid
/// (built from view.decodeRow — forward contract; see design_notes §4).
pub const Grid = struct {
    ctx: *anyopaque,
    getRowFn: *const fn (ctx: *anyopaque, y: u32) Row,
    total_rows: u32,
    cols: u16, // grid cell width (grid.pages.cols); hard ceiling for cursor.x
    pub fn getRow(self: Grid, y: u32) Row {
        return self.getRowFn(self.ctx, y);
    }
};

pub const Direction = enum { forward, backward };

/// Search navigation state. `matches` is the EXTERNALLY-produced list from view.findMatches
/// (region.zig calls it after the pattern is typed). `current` = index of the last-visited match
/// (null before the first n/N). `direction` = the direction of the last `/` or `?`.
pub const SearchState = struct {
    matches: []const view.Match = &.{},
    current: ?usize = null,
    direction: Direction = .forward,
};

/// TEST Grid — yields Rows from a slice; y >= total_rows ⇒ empty Row (text.len==0). Stable
/// static slices. Must be a stack `var` so `&sg` is `*SliceGrid` (a const yields `*const T`
/// which does NOT coerce to `*anyopaque` for the ctx).
pub const SliceGrid = struct {
    rows: []const Row,
    total_rows: u32,
    cols: u16,
    fn getRowFn(ctx: *anyopaque, y: u32) Row {
        const self: *SliceGrid = @ptrCast(@alignCast(ctx));
        if (y >= self.total_rows) return .{ .text = "", .col = &.{} };
        return self.rows[y];
    }
    pub fn grid(self: *SliceGrid) Grid {
        return .{ .ctx = @ptrCast(self), .getRowFn = getRowFn, .total_rows = self.total_rows, .cols = self.cols };
    }
};

// ============================================================================
// Row helpers (PURE — operate on ONE Row; trivially testable).
// ============================================================================

/// Index of the last non-blank byte, or null for an all-blank row. Blank = byte is ' ' or '\t'.
pub fn lineLastByte(row: Row) ?usize {
    if (row.text.len == 0) return null;
    var i: usize = row.text.len - 1;
    while (true) {
        const b = row.text[i];
        if (b != ' ' and b != '\t') return i;
        if (i == 0) break;
        i -= 1;
    }
    return null;
}

/// Cell col of the last non-blank byte (0 for blank). `$` target.
pub fn lastCellCol(row: Row) u32 {
    if (lineLastByte(row)) |i| return row.col[i];
    return 0;
}

/// Cell col of the first non-blank byte (0 for blank). `^` target.
pub fn firstNonBlankCol(row: Row) u32 {
    for (row.text, 0..) |b, i| {
        if (b != ' ' and b != '\t') return row.col[i];
    }
    return 0;
}

/// `min(x, lastCellCol(row))` capped at `cols-1`. Used to clamp a preserved-x to a new row.
pub fn clampX(row: Row, x: u32, cols: u16) u32 {
    const cap: u32 = @intCast(@as(u32, cols) -| 1);
    return @min(@min(x, lastCellCol(row)), cap);
}

/// True if no non-blank byte (a `{`/`}` paragraph boundary).
pub fn isBlankRow(row: Row) bool {
    return lineLastByte(row) == null;
}

// ============================================================================
// Motion primitives (PURE — operate on Grid via borrowed Rows; never store a Row across calls).
// ============================================================================

// --- byte<->cell helpers -----------------------------------------------------

/// Find the byte index whose cell col == target_x (the smallest such). Returns null if the row
/// is empty or no byte maps to target_x.
fn byteAtCol(row: Row, target_x: u32) ?usize {
    for (row.col, 0..) |c, i| {
        if (@as(u32, c) == target_x) return i;
    }
    return null;
}

// --- word motions (two-class WORD: a word = a maximal run of NON-WHITESPACE) ---
// `w`/`b`/`e` cross rows (a blank row is whitespace); clamp at EOF to last cell of last row,
// at BOF to (0,0). Compute a target BYTE index then pos.x = row.col[byte] (wide-char-correct).

/// `w`: move to the START of the next word, `count` times. Skips the current non-blank run +
/// following whitespace; lands on the next non-blank char. Clamps at EOF to the last cell of
/// the last row.
pub fn wordForward(grid: Grid, start: view.Pos, count: u32, cols: u16) view.Pos {
    if (grid.total_rows == 0) return start;
    var pos = start;
    var remaining = count;
    const cap: u32 = @intCast(@as(u32, cols) -| 1);
    while (remaining > 0) : (remaining -= 1) {
        var row = grid.getRow(pos.y);
        var bi: usize = byteAtCol(row, pos.x) orelse 0;
        // Phase 1: skip the current non-blank run (if on one).
        while (bi < row.text.len and row.text[bi] != ' ' and row.text[bi] != '\t') : (bi += 1) {}
        // Phase 2: skip whitespace (possibly crossing blank rows).
        while (true) {
            while (bi < row.text.len and (row.text[bi] == ' ' or row.text[bi] == '\t')) : (bi += 1) {}
            if (bi < row.text.len) break; // found next non-blank
            // end of this row ⇒ advance to next row
            if (pos.y + 1 >= grid.total_rows) {
                // EOF clamp: last cell of last row.
                row = grid.getRow(grid.total_rows - 1);
                pos = .{ .x = @min(lastCellCol(row), cap), .y = grid.total_rows - 1 };
                return pos;
            }
            pos.y += 1;
            bi = 0;
            row = grid.getRow(pos.y);
        }
        // Landed on the next word's start.
        pos = .{ .x = @min(@as(u32, row.col[bi]), cap), .y = pos.y };
    }
    return pos;
}

/// `b`: move to the START of the previous word, `count` times. Clamps at BOF to (0,0).
pub fn wordBackward(grid: Grid, start: view.Pos, count: u32, cols: u16) view.Pos {
    if (grid.total_rows == 0) return start;
    var pos = start;
    var remaining = count;
    const cap: u32 = @intCast(@as(u32, cols) -| 1);
    while (remaining > 0) : (remaining -= 1) {
        var row = grid.getRow(pos.y);
        var bi: ?usize = byteAtCol(row, pos.x);
        // Step back one byte first (b lands on the START of a word; if already at a start,
        // it goes to the PREVIOUS word).
        if (bi) |idx| {
            if (idx == 0) {
                bi = null; // signal: at row start ⇒ must go up
            } else {
                bi = idx - 1;
            }
        }
        // Skip whitespace backward (possibly crossing blank rows up).
        while (true) {
            if (bi) |idx| {
                // Skip trailing whitespace within this row (scan back). Walk the index down one
                // byte at a time; land `bi` on the first non-blank found (or 0 if all blank up
                // to the start). Ensures progress (no infinite loop).
                var cur_idx = idx;
                while (cur_idx > 0 and (row.text[cur_idx] == ' ' or row.text[cur_idx] == '\t')) : (cur_idx -= 1) {}
                bi = cur_idx;
                // If we're now on non-blank, we're in a word on this row.
                if (row.text.len > 0 and (row.text[cur_idx] != ' ' and row.text[cur_idx] != '\t')) {
                    // Scan back to the start of this word run.
                    var j = cur_idx;
                    while (j > 0 and row.text[j - 1] != ' ' and row.text[j - 1] != '\t') : (j -= 1) {}
                    pos = .{ .x = @min(@as(u32, row.col[j]), cap), .y = pos.y };
                    break;
                }
            }
            // This row had no preceding word ⇒ go up one row.
            if (pos.y == 0) {
                pos = .{ .x = 0, .y = 0 };
                break;
            }
            pos.y -= 1;
            row = grid.getRow(pos.y);
            if (row.text.len == 0) {
                bi = null; // blank row ⇒ keep going up
            } else {
                bi = row.text.len - 1;
            }
        }
    }
    return pos;
}

/// `e`: move to the END of the current/next word, `count` times. If on whitespace or at the
/// end of a word, advance to the next word first. Clamps at EOF to the last cell of last row.
pub fn wordEnd(grid: Grid, start: view.Pos, count: u32, cols: u16) view.Pos {
    if (grid.total_rows == 0) return start;
    var pos = start;
    var remaining = count;
    const cap: u32 = @intCast(@as(u32, cols) -| 1);
    while (remaining > 0) : (remaining -= 1) {
        var row = grid.getRow(pos.y);
        var bi: usize = byteAtCol(row, pos.x) orelse 0;
        // Step forward one byte (e from the end of a word ⇒ next word's end).
        if (bi + 1 < row.text.len) bi += 1;
        // Skip whitespace forward (possibly crossing blank rows).
        while (true) {
            while (bi < row.text.len and (row.text[bi] == ' ' or row.text[bi] == '\t')) : (bi += 1) {}
            if (bi < row.text.len) break; // found a non-blank ⇒ in a word
            if (pos.y + 1 >= grid.total_rows) {
                // EOF clamp.
                row = grid.getRow(grid.total_rows - 1);
                pos = .{ .x = @min(lastCellCol(row), cap), .y = grid.total_rows - 1 };
                return pos;
            }
            pos.y += 1;
            bi = 0;
            row = grid.getRow(pos.y);
        }
        // Scan forward to the END of this word run.
        var j = bi;
        while (j + 1 < row.text.len and row.text[j + 1] != ' ' and row.text[j + 1] != '\t') : (j += 1) {}
        pos = .{ .x = @min(@as(u32, row.col[j]), cap), .y = pos.y };
    }
    return pos;
}

// --- paragraph motions ({/}) — nearest ALL-BLANK row strictly above/below ---

/// `{`: nearest blank row strictly ABOVE `y`, `count` repeats; 0 if none.
pub fn paragraphBack(grid: Grid, start_y: u32, count: u32) u32 {
    var y = start_y;
    var remaining = count;
    while (remaining > 0) : (remaining -= 1) {
        if (y == 0) return 0;
        var found = false;
        var yy = y - 1;
        while (true) : (yy -|= 1) {
            if (isBlankRow(grid.getRow(yy))) {
                y = yy;
                found = true;
                break;
            }
            if (yy == 0) break;
        }
        if (!found) return 0; // no blank row above ⇒ clamp to top
    }
    return y;
}

/// `}`: nearest blank row strictly BELOW `y`, `count` repeats; `total_rows-1` if none.
pub fn paragraphFwd(grid: Grid, start_y: u32, count: u32) u32 {
    if (grid.total_rows == 0) return start_y;
    var y = start_y;
    var remaining = count;
    while (remaining > 0) : (remaining -= 1) {
        if (y + 1 >= grid.total_rows) return grid.total_rows - 1;
        var found = false;
        var yy = y + 1;
        while (yy < grid.total_rows) : (yy += 1) {
            if (isBlankRow(grid.getRow(yy))) {
                y = yy;
                found = true;
                break;
            }
        }
        if (!found) return grid.total_rows - 1; // no blank row below ⇒ clamp to bottom
    }
    return y;
}

// --- % bracket matching (matchBracket) ---
// Pairs: () [] {}. Cursor on a bracket ⇒ jump to its match (forward for openers, backward for
// closers) tracking NESTING DEPTH (count same-type openers/closers; land at depth 0). Cursor
// NOT on a bracket ⇒ scan the current row forward from the cursor for the first bracket; if
// found, match it; if none ⇒ null. Crosses rows. Unbalanced ⇒ null. Count is IGNORED.

const BracketPair = struct { open: u8, close: u8 };
const bracket_pairs = [_]BracketPair{
    .{ .open = '(', .close = ')' },
    .{ .open = '[', .close = ']' },
    .{ .open = '{', .close = '}' },
};

fn classifyBracket(b: u8) ?BracketPair {
    for (bracket_pairs) |p| {
        if (b == p.open or b == p.close) return p;
    }
    return null;
}

/// `%`: bracket match across rows. Returns the matched bracket's cell pos, or null if the cursor
/// is not on a bracket (and none found forward on the row) or the brackets are unbalanced.
pub fn matchBracket(grid: Grid, pos: view.Pos, cols: u16) ?view.Pos {
    if (grid.total_rows == 0) return null;
    _ = cols;
    const row = grid.getRow(pos.y);
    if (row.text.len == 0) return null;

    // STEP 1: find a bracket byte AT pos.x, else scan forward from the first byte with col>=pos.x.
    var bi: ?usize = null;
    var start_scan: usize = 0;
    // First, try the byte(s) whose col == pos.x.
    var i: usize = 0;
    while (i < row.col.len) : (i += 1) {
        if (@as(u32, row.col[i]) == pos.x) {
            if (classifyBracket(row.text[i]) != null) {
                bi = i;
                break;
            }
        }
        if (@as(u32, row.col[i]) >= pos.x and start_scan == 0 and i > 0) {
            // keep scanning; we'll fall back below
        }
    }
    // Not on a bracket at pos.x ⇒ scan forward from the first byte with col >= pos.x.
    if (bi == null) {
        var j: usize = 0;
        while (j < row.text.len) : (j += 1) {
            if (@as(u32, row.col[j]) >= pos.x) {
                start_scan = j;
                break;
            }
        }
        var k = start_scan;
        while (k < row.text.len) : (k += 1) {
            if (classifyBracket(row.text[k]) != null) {
                bi = k;
                break;
            }
        }
        if (bi == null) return null; // no bracket on the row ⇒ no move
    }
    const bidx = bi.?;

    // STEP 2: direction + the matching char of the same pair.
    const pair = classifyBracket(row.text[bidx]).?;
    const fwd = (row.text[bidx] == pair.open);
    const target_char = if (fwd) pair.close else pair.open;
    const same_char = if (fwd) pair.open else pair.close;

    // STEP 3: walk the grid (row by row, byte by byte) in direction from just past bidx,
    // maintaining a depth counter. Land where depth returns to 0.
    var depth: u32 = 1;
    var ry = pos.y;
    var ri: usize = bidx;
    // advance one byte to start
    if (fwd) {
        ri += 1;
    } else {
        if (ri == 0) {
            if (ry == 0) return null;
            ry -= 1;
            const pr = grid.getRow(ry);
            if (pr.text.len == 0) return null;
            ri = pr.text.len - 1;
        } else {
            ri -= 1;
        }
    }

    while (true) {
        const cur_row = grid.getRow(ry);
        if (cur_row.text.len == 0) {
            // empty row ⇒ advance/retreat a row
            if (fwd) {
                if (ry + 1 >= grid.total_rows) return null;
                ry += 1;
                ri = 0;
            } else {
                if (ry == 0) return null;
                ry -= 1;
                const pr = grid.getRow(ry);
                if (pr.text.len == 0) return null;
                ri = pr.text.len - 1;
            }
            continue;
        }
        const b = cur_row.text[ri];
        if (b == same_char) {
            depth += 1;
        } else if (b == target_char) {
            depth -= 1;
            if (depth == 0) {
                return .{ .x = cur_row.col[ri], .y = ry };
            }
        }
        // advance/retreat one byte
        if (fwd) {
            if (ri + 1 < cur_row.text.len) {
                ri += 1;
            } else {
                if (ry + 1 >= grid.total_rows) return null;
                ry += 1;
                ri = 0;
            }
        } else {
            if (ri == 0) {
                if (ry == 0) return null;
                ry -= 1;
                const pr = grid.getRow(ry);
                if (pr.text.len == 0) {
                    // keep going up over the empty row
                    continue;
                }
                ri = pr.text.len - 1;
            } else {
                ri -= 1;
            }
        }
    }
}

// ============================================================================
// applyMotion — the dispatcher (PURE; switches on ALL 21 input.Motion variants).
// ============================================================================
// Per-variant rules: research/design_notes.md §3 + vim_motion_semantics.md. Vertical motions
// recompute viewport.scroll via view.scrollForCursor (the minimal keep-visible workhorse) UNLESS
// noted. half = viewport.rows / 2 (floor). "clamp into viewport" clamps y to
// [new_scroll, min(total-1, new_scroll+rows-1)]. SATURATING subtract everywhere upward.

/// Apply motion `m` (with `count`) to cursor `c` over `grid`; return the new Cursor. PURE.
pub fn applyMotion(c: Cursor, m: input.Motion, count: u32, grid: Grid) Cursor {
    var out = c;
    const total = grid.total_rows;
    if (total == 0) return out; // empty grid ⇒ no-op (guards every getRow below)
    const last_row = total - 1;
    const rows = c.viewport.rows;
    const cols = c.viewport.cols;
    const half: u32 = @as(u32, rows) / 2;

    switch (m) {
        .left => { // h: x = max(0, x-count) clamped to row; scroll unchanged
            const row = grid.getRow(c.pos.y);
            out.pos.x = if (c.pos.x >= count) c.pos.x - count else 0;
            out.pos.x = @min(out.pos.x, lastCellCol(row));
        },
        .right => { // l: x = min(cols-1, x+count) clamped to row; scroll unchanged
            const row = grid.getRow(c.pos.y);
            const cap: u32 = @intCast(@as(u32, cols) -| 1);
            out.pos.x = @min(@min(c.pos.x +% count, lastCellCol(row)), cap);
        },
        .up => { // k: y = max(0, y-count); x = clampX(newRow); scrollForCursor
            out.pos.y = if (c.pos.y >= count) c.pos.y - count else 0;
            const row = grid.getRow(out.pos.y);
            out.pos.x = clampX(row, c.pos.x, cols);
            out.viewport.scroll = view.scrollForCursor(out.pos.y, out.viewport, total);
        },
        .down => { // j: y = min(last_row, y+count); x = clampX(newRow); scrollForCursor
            out.pos.y = @min(last_row, c.pos.y +% count);
            const row = grid.getRow(out.pos.y);
            out.pos.x = clampX(row, c.pos.x, cols);
            out.viewport.scroll = view.scrollForCursor(out.pos.y, out.viewport, total);
        },
        .word_fwd => { // w
            out.pos = wordForward(grid, c.pos, count, cols);
            out.viewport.scroll = view.scrollForCursor(out.pos.y, out.viewport, total);
        },
        .word_back => { // b
            out.pos = wordBackward(grid, c.pos, count, cols);
            out.viewport.scroll = view.scrollForCursor(out.pos.y, out.viewport, total);
        },
        .word_end => { // e
            out.pos = wordEnd(grid, c.pos, count, cols);
            out.viewport.scroll = view.scrollForCursor(out.pos.y, out.viewport, total);
        },
        .line_start => { // 0: x = 0; scroll unchanged
            out.pos.x = 0;
        },
        .first_nonblank => { // ^: x = firstNonBlankCol(row); scroll unchanged
            const row = grid.getRow(c.pos.y);
            out.pos.x = firstNonBlankCol(row);
        },
        .line_end => { // $: y = min(last_row, y+(count-1)); x = lastCellCol(newRow); scrollForCursor
            out.pos.y = @min(last_row, c.pos.y +% (count -| 1));
            const row = grid.getRow(out.pos.y);
            out.pos.x = lastCellCol(row);
            out.viewport.scroll = view.scrollForCursor(out.pos.y, out.viewport, total);
        },
        .doc_top => { // gg: y = (count>=2 ? count-1 : 0); x = clampX(row); topOnCursor
            out.pos.y = if (count >= 2) @min(last_row, count - 1) else 0;
            const row = grid.getRow(out.pos.y);
            out.pos.x = clampX(row, c.pos.x, cols);
            out.viewport.scroll = view.topOnCursor(out.pos.y, rows, total);
        },
        .doc_bottom => { // G: y = (count>=2 ? count-1 : last_row); x = clampX(row); scrollToBottom/scrollForCursor
            out.pos.y = if (count >= 2) @min(last_row, count - 1) else last_row;
            const row = grid.getRow(out.pos.y);
            out.pos.x = clampX(row, c.pos.x, cols);
            out.viewport.scroll = view.scrollForCursor(out.pos.y, out.viewport, total);
        },
        .half_page_down => { // Ctrl-d: repeat count: y=min(last,y+half); clamp into viewport; halfPageDown/step
            out.pos.y = c.pos.y;
            out.viewport.scroll = c.viewport.scroll;
            var n = count;
            while (n > 0) : (n -= 1) {
                out.pos.y = @min(last_row, out.pos.y +% half);
                out.viewport.scroll = view.halfPageDown(out.viewport.scroll, total, rows);
                // clamp cursor into the new viewport
                const lo = out.viewport.scroll;
                const hi = @min(last_row, out.viewport.scroll + @as(u32, rows) - 1);
                if (out.pos.y < lo) out.pos.y = lo;
                if (out.pos.y > hi) out.pos.y = hi;
            }
            const row = grid.getRow(out.pos.y);
            out.pos.x = clampX(row, c.pos.x, cols);
        },
        .half_page_up => { // Ctrl-u: repeat count: y=max(0,y-half); clamp into viewport; halfPageUp/step
            out.pos.y = c.pos.y;
            out.viewport.scroll = c.viewport.scroll;
            var n = count;
            while (n > 0) : (n -= 1) {
                out.pos.y = if (out.pos.y >= half) out.pos.y - half else 0;
                out.viewport.scroll = view.halfPageUp(out.viewport.scroll, total, rows);
                const lo = out.viewport.scroll;
                const hi = @min(last_row, out.viewport.scroll + @as(u32, rows) - 1);
                if (out.pos.y < lo) out.pos.y = lo;
                if (out.pos.y > hi) out.pos.y = hi;
            }
            const row = grid.getRow(out.pos.y);
            out.pos.x = clampX(row, c.pos.x, cols);
        },
        .page_down => { // Ctrl-f: repeat count: y=min(last,y+rows); clamp into viewport; pageDown/step
            out.pos.y = c.pos.y;
            out.viewport.scroll = c.viewport.scroll;
            var n = count;
            while (n > 0) : (n -= 1) {
                out.pos.y = @min(last_row, out.pos.y +% @as(u32, rows));
                out.viewport.scroll = view.pageDown(out.viewport.scroll, total, rows);
                const lo = out.viewport.scroll;
                const hi = @min(last_row, out.viewport.scroll + @as(u32, rows) - 1);
                if (out.pos.y < lo) out.pos.y = lo;
                if (out.pos.y > hi) out.pos.y = hi;
            }
            const row = grid.getRow(out.pos.y);
            out.pos.x = clampX(row, c.pos.x, cols);
        },
        .page_up => { // Ctrl-b: repeat count: y=max(0,y-rows); clamp into viewport; pageUp/step
            out.pos.y = c.pos.y;
            out.viewport.scroll = c.viewport.scroll;
            const r: u32 = @as(u32, rows);
            var n = count;
            while (n > 0) : (n -= 1) {
                out.pos.y = if (out.pos.y >= r) out.pos.y - r else 0;
                out.viewport.scroll = view.pageUp(out.viewport.scroll, total, rows);
                const lo = out.viewport.scroll;
                const hi = @min(last_row, out.viewport.scroll + @as(u32, rows) - 1);
                if (out.pos.y < lo) out.pos.y = lo;
                if (out.pos.y > hi) out.pos.y = hi;
            }
            const row = grid.getRow(out.pos.y);
            out.pos.x = clampX(row, c.pos.x, cols);
        },
        .viewport_top => { // H: y = min(last, scroll+(count-1)); x = clampX; scroll unchanged
            out.pos.y = @min(last_row, c.viewport.scroll +% (count -| 1));
            const row = grid.getRow(out.pos.y);
            out.pos.x = clampX(row, c.pos.x, cols);
        },
        .viewport_mid => { // M: y = min(last, scroll+rows/2) (count IGNORED); x = clampX; scroll unchanged
            out.pos.y = @min(last_row, c.viewport.scroll +% half);
            const row = grid.getRow(out.pos.y);
            out.pos.x = clampX(row, c.pos.x, cols);
        },
        .viewport_bottom => { // L: y = min(last, scroll+rows-1)-(count-1); x = clampX; scroll unchanged
            const bot = @min(last_row, c.viewport.scroll +% @as(u32, rows) -| 1);
            out.pos.y = if (bot >= (count -| 1)) bot - (count -| 1) else 0;
            const row = grid.getRow(out.pos.y);
            out.pos.x = clampX(row, c.pos.x, cols);
        },
        .paragraph_back => { // {: y = paragraphBack(...); x = clampX; scrollForCursor
            out.pos.y = paragraphBack(grid, c.pos.y, count);
            const row = grid.getRow(out.pos.y);
            out.pos.x = clampX(row, c.pos.x, cols);
            out.viewport.scroll = view.scrollForCursor(out.pos.y, out.viewport, total);
        },
        .paragraph_fwd => { // }: y = paragraphFwd(...); x = clampX; scrollForCursor
            out.pos.y = paragraphFwd(grid, c.pos.y, count);
            const row = grid.getRow(out.pos.y);
            out.pos.x = clampX(row, c.pos.x, cols);
            out.viewport.scroll = view.scrollForCursor(out.pos.y, out.viewport, total);
        },
        .match_bracket => { // %: pos = matchBracket(...) orelse c.pos (no bracket ⇒ UNCHANGED)
            if (matchBracket(grid, c.pos, cols)) |np| {
                out.pos = np;
                out.viewport.scroll = view.scrollForCursor(np.y, out.viewport, total);
            }
            // else: out == c (cursor + scroll unchanged)
        },
    }
    return out;
}

// ============================================================================
// Search navigation (PURE — operates on []const Match + cursor).
// ============================================================================

/// First match whose start `(y, x1)` is strictly AFTER (dir=.forward) / BEFORE (dir=.backward)
/// the cursor, with WRAPAROUND. Forward: scan matches in order; first with (m.y, m.x1) >
/// (cursor.y, cursor.x); if none, wrap to matches[0]. Backward: mirror; if none, wrap to last.
/// Empty matches ⇒ null. Returns `{ x: m.x1, y: m.y }`. A match whose start is AT the cursor is
/// NOT "after" — `n` on a match-start lands on the NEXT match.
pub fn nextMatch(s: SearchState, cursor: view.Pos, dir: Direction) ?view.Pos {
    if (s.matches.len == 0) return null;
    const fwd = (dir == .forward);
    for (s.matches) |m| {
        const after = (m.y > cursor.y) or (m.y == cursor.y and m.x1 > cursor.x);
        const before = (m.y < cursor.y) or (m.y == cursor.y and m.x1 < cursor.x);
        const hit = if (fwd) after else before;
        if (hit) return .{ .x = m.x1, .y = m.y };
    }
    // wraparound: forward ⇒ matches[0]; backward ⇒ matches[len-1]
    const idx: usize = if (fwd) 0 else s.matches.len - 1;
    const m = s.matches[idx];
    return .{ .x = m.x1, .y = m.y };
}

/// `prevMatch` = `nextMatch` with the opposite direction (one fn, dir param — no duplication).
/// region.zig (P3.M3) sets SearchState.direction from the last `/` or `?`.
pub fn prevMatch(s: SearchState, cursor: view.Pos) ?view.Pos {
    return nextMatch(s, cursor, if (s.direction == .forward) .backward else .forward);
}

// ============================================================================
// Unit tests — ALL as SEPARATE `test` fns (motion.zig constructs NO Terminal ⇒ safe; mirrors
// app.zig + input.zig). Pure fns only; the Grid seam is exercised via SliceGrid.
// ============================================================================

const testing = std.testing;

/// Build a Row with an IDENTITY col map (col[i] == i) from a comptime ASCII literal.
fn asciiRow(comptime s: []const u8) Row {
    const cols = comptime blk: {
        var c: [s.len]u16 = undefined;
        for (0..s.len) |i| c[i] = @intCast(i);
        break :blk c;
    };
    return .{ .text = s, .col = &cols };
}

// ---- Row helpers ------------------------------------------------------------

test "lineLastByte: last non-blank byte index; null for all-blank/empty" {
    try testing.expectEqual(@as(?usize, 4), lineLastByte(asciiRow("hello")));
    try testing.expectEqual(@as(?usize, 1), lineLastByte(asciiRow("ab  "))); // trailing blanks: last non-blank is 'b' at idx 1
    try testing.expectEqual(@as(?usize, null), lineLastByte(asciiRow("   "))); // all blank
    try testing.expectEqual(@as(?usize, null), lineLastByte(asciiRow(""))); // empty
    try testing.expectEqual(@as(?usize, 0), lineLastByte(asciiRow("a"))); // single non-blank
}

test "lastCellCol: cell col of last non-blank byte; 0 for blank" {
    try testing.expectEqual(@as(u32, 4), lastCellCol(asciiRow("hello")));
    try testing.expectEqual(@as(u32, 1), lastCellCol(asciiRow("ab  ")));
    try testing.expectEqual(@as(u32, 0), lastCellCol(asciiRow("   ")));
    // wide-ish col map: last non-blank byte index 3 ⇒ col[3] = 6
    const cols = [_]u16{ 5, 5, 6, 6 };
    try testing.expectEqual(@as(u32, 6), lastCellCol(.{ .text = "abcd", .col = &cols }));
}

test "firstNonBlankCol: cell col of first non-blank byte; 0 for blank" {
    try testing.expectEqual(@as(u32, 0), firstNonBlankCol(asciiRow("hello")));
    try testing.expectEqual(@as(u32, 2), firstNonBlankCol(asciiRow("  ab")));
    try testing.expectEqual(@as(u32, 0), firstNonBlankCol(asciiRow("   ")));
    // wide-ish col map: first non-blank byte index 2 ⇒ col[2] = 6
    const cols = [_]u16{ 5, 5, 6, 6 };
    try testing.expectEqual(@as(u32, 6), firstNonBlankCol(.{ .text = "  ab", .col = &cols }));
}

test "clampX: min(x, lastCellCol) capped at cols-1" {
    const row = asciiRow("abc"); // lastCellCol = 2
    try testing.expectEqual(@as(u32, 0), clampX(row, 0, 80));
    try testing.expectEqual(@as(u32, 2), clampX(row, 5, 80)); // capped to last cell
    try testing.expectEqual(@as(u32, 1), clampX(row, 1, 80));
    // cols ceiling: cols=2 ⇒ cap at 1
    try testing.expectEqual(@as(u32, 1), clampX(row, 9, 2));
    // blank row ⇒ lastCellCol 0
    const blank = asciiRow("   ");
    try testing.expectEqual(@as(u32, 0), clampX(blank, 5, 80));
}

test "isBlankRow: true iff no non-blank byte" {
    try testing.expect(!isBlankRow(asciiRow("hello")));
    try testing.expect(!isBlankRow(asciiRow("  x")));
    try testing.expect(isBlankRow(asciiRow("   ")));
    try testing.expect(isBlankRow(asciiRow("")));
    try testing.expect(isBlankRow(asciiRow("\t\t")));
}

// ---- wordForward ------------------------------------------------------------

test "wordForward: single row — skips current word + whitespace" {
    var sg = SliceGrid{ .rows = &.{asciiRow("foo bar baz")}, .total_rows = 1, .cols = 80 };
    const g = sg.grid();
    // w from (0,0) ⇒ (4,0) [start of "bar"]; then (8,0) [start of "baz"]
    try testing.expectEqual(view.Pos{ .x = 4, .y = 0 }, wordForward(g, .{ .x = 0, .y = 0 }, 1, 80));
    try testing.expectEqual(view.Pos{ .x = 8, .y = 0 }, wordForward(g, .{ .x = 4, .y = 0 }, 1, 80));
}

test "wordForward: count jumps multiple words" {
    var sg = SliceGrid{ .rows = &.{asciiRow("foo bar baz")}, .total_rows = 1, .cols = 80 };
    const g = sg.grid();
    // 2w from (0,0) ⇒ (8,0) [start of "baz"]
    try testing.expectEqual(view.Pos{ .x = 8, .y = 0 }, wordForward(g, .{ .x = 0, .y = 0 }, 2, 80));
}

test "wordForward: foo.bar is ONE word (two-class model) — w from col 0 ⇒ last cell" {
    var sg = SliceGrid{ .rows = &.{asciiRow("foo.bar")}, .total_rows = 1, .cols = 80 };
    const g = sg.grid();
    // foo.bar is a single non-blank run (no next word) ⇒ EOF clamp ⇒ last cell (6).
    try testing.expectEqual(view.Pos{ .x = 6, .y = 0 }, wordForward(g, .{ .x = 0, .y = 0 }, 1, 80));
}

test "wordForward: crosses rows; blank row is whitespace" {
    var sg = SliceGrid{
        .rows = &.{ asciiRow("foo"), asciiRow(""), asciiRow("bar") },
        .total_rows = 3,
        .cols = 80,
    };
    const g = sg.grid();
    // w from (0,0) [in "foo"] ⇒ skip "foo" + blank row 1 ⇒ (0,2) [start of "bar"]
    try testing.expectEqual(view.Pos{ .x = 0, .y = 2 }, wordForward(g, .{ .x = 0, .y = 0 }, 1, 80));
}

test "wordForward: EOF clamp to last cell of last row" {
    var sg = SliceGrid{ .rows = &.{ asciiRow("foo"), asciiRow("bar") }, .total_rows = 2, .cols = 80 };
    const g = sg.grid();
    // w from (0,1) [in last-row "bar"] ⇒ no next word ⇒ clamp to last cell (2,1)
    try testing.expectEqual(view.Pos{ .x = 2, .y = 1 }, wordForward(g, .{ .x = 0, .y = 1 }, 1, 80));
}

// ---- wordBackward -----------------------------------------------------------

test "wordBackward: single row — previous word start" {
    var sg = SliceGrid{ .rows = &.{asciiRow("foo bar baz")}, .total_rows = 1, .cols = 80 };
    const g = sg.grid();
    // b from (4,0) [start of "bar"] ⇒ (0,0) [start of "foo"]
    try testing.expectEqual(view.Pos{ .x = 0, .y = 0 }, wordBackward(g, .{ .x = 4, .y = 0 }, 1, 80));
    // b from (8,0) [start of "baz"] ⇒ (4,0) [start of "bar"]
    try testing.expectEqual(view.Pos{ .x = 4, .y = 0 }, wordBackward(g, .{ .x = 8, .y = 0 }, 1, 80));
}

test "wordBackward: count jumps multiple words" {
    var sg = SliceGrid{ .rows = &.{asciiRow("foo bar baz")}, .total_rows = 1, .cols = 80 };
    const g = sg.grid();
    // 2b from (8,0) ⇒ (0,0)
    try testing.expectEqual(view.Pos{ .x = 0, .y = 0 }, wordBackward(g, .{ .x = 8, .y = 0 }, 2, 80));
}

test "wordBackward: BOF clamp to (0,0)" {
    var sg = SliceGrid{ .rows = &.{asciiRow("foo")}, .total_rows = 1, .cols = 80 };
    const g = sg.grid();
    // b from (0,0) ⇒ already at BOF ⇒ (0,0)
    try testing.expectEqual(view.Pos{ .x = 0, .y = 0 }, wordBackward(g, .{ .x = 0, .y = 0 }, 1, 80));
}

test "wordBackward: crosses rows; blank row is whitespace" {
    var sg = SliceGrid{
        .rows = &.{ asciiRow("foo"), asciiRow(""), asciiRow("bar") },
        .total_rows = 3,
        .cols = 80,
    };
    const g = sg.grid();
    // b from (0,2) [start of "bar"] ⇒ up over blank row 1 ⇒ (0,0) [start of "foo"]
    try testing.expectEqual(view.Pos{ .x = 0, .y = 0 }, wordBackward(g, .{ .x = 0, .y = 2 }, 1, 80));
}

// ---- wordEnd ---------------------------------------------------------------

test "wordEnd: single row — end of current word" {
    var sg = SliceGrid{ .rows = &.{asciiRow("foo bar")}, .total_rows = 1, .cols = 80 };
    const g = sg.grid();
    // e from (0,0) ⇒ end of "foo" (2,0)
    try testing.expectEqual(view.Pos{ .x = 2, .y = 0 }, wordEnd(g, .{ .x = 0, .y = 0 }, 1, 80));
    // e from (2,0) [end of "foo"] ⇒ end of "bar" (6,0)
    try testing.expectEqual(view.Pos{ .x = 6, .y = 0 }, wordEnd(g, .{ .x = 2, .y = 0 }, 1, 80));
}

test "wordEnd: count jumps multiple words" {
    var sg = SliceGrid{ .rows = &.{asciiRow("foo bar baz")}, .total_rows = 1, .cols = 80 };
    const g = sg.grid();
    // 2e from (0,0) ⇒ end of "bar" (6,0)
    try testing.expectEqual(view.Pos{ .x = 6, .y = 0 }, wordEnd(g, .{ .x = 0, .y = 0 }, 2, 80));
}

test "wordEnd: EOF clamp to last cell of last row" {
    var sg = SliceGrid{ .rows = &.{ asciiRow("foo"), asciiRow("bar") }, .total_rows = 2, .cols = 80 };
    const g = sg.grid();
    // e from (1,1) [in "bar"] ⇒ end of "bar" (2,1); then e again ⇒ no next word ⇒ clamp (2,1)
    try testing.expectEqual(view.Pos{ .x = 2, .y = 1 }, wordEnd(g, .{ .x = 1, .y = 1 }, 1, 80));
    try testing.expectEqual(view.Pos{ .x = 2, .y = 1 }, wordEnd(g, .{ .x = 2, .y = 1 }, 1, 80));
}

// ---- matchBracket ----------------------------------------------------------

test "matchBracket: cursor on each opener ( [ { matches forward" {
    var sg = SliceGrid{ .rows = &.{asciiRow("(a) [b] {c}")}, .total_rows = 1, .cols = 80 };
    const g = sg.grid();
    // ( at col 0 ⇒ ) at col 2
    try testing.expectEqual(@as(?view.Pos, .{ .x = 2, .y = 0 }), matchBracket(g, .{ .x = 0, .y = 0 }, 80));
    // [ at col 4 ⇒ ] at col 6
    try testing.expectEqual(@as(?view.Pos, .{ .x = 6, .y = 0 }), matchBracket(g, .{ .x = 4, .y = 0 }, 80));
    // { at col 8 ⇒ } at col 10
    try testing.expectEqual(@as(?view.Pos, .{ .x = 10, .y = 0 }), matchBracket(g, .{ .x = 8, .y = 0 }, 80));
}

test "matchBracket: cursor on each closer ) ] } matches backward" {
    var sg = SliceGrid{ .rows = &.{asciiRow("(a) [b] {c}")}, .total_rows = 1, .cols = 80 };
    const g = sg.grid();
    try testing.expectEqual(@as(?view.Pos, .{ .x = 0, .y = 0 }), matchBracket(g, .{ .x = 2, .y = 0 }, 80));
    try testing.expectEqual(@as(?view.Pos, .{ .x = 4, .y = 0 }), matchBracket(g, .{ .x = 6, .y = 0 }, 80));
    try testing.expectEqual(@as(?view.Pos, .{ .x = 8, .y = 0 }), matchBracket(g, .{ .x = 10, .y = 0 }, 80));
}

test "matchBracket: forward nesting ((a)(b)) — first ( matches last )" {
    var sg = SliceGrid{ .rows = &.{asciiRow("((a)(b))")}, .total_rows = 1, .cols = 80 };
    const g = sg.grid();
    // col 0 ( ⇒ last ) at col 7
    try testing.expectEqual(@as(?view.Pos, .{ .x = 7, .y = 0 }), matchBracket(g, .{ .x = 0, .y = 0 }, 80));
    // col 1 ( ⇒ ) at col 3
    try testing.expectEqual(@as(?view.Pos, .{ .x = 3, .y = 0 }), matchBracket(g, .{ .x = 1, .y = 0 }, 80));
    // col 4 ( ⇒ ) at col 6
    try testing.expectEqual(@as(?view.Pos, .{ .x = 6, .y = 0 }), matchBracket(g, .{ .x = 4, .y = 0 }, 80));
}

test "matchBracket: cursor NOT on bracket ⇒ line-forward-search finds first bracket" {
    var sg = SliceGrid{ .rows = &.{asciiRow("  (a)")}, .total_rows = 1, .cols = 80 };
    const g = sg.grid();
    // cursor at col 0 (space); scan forward ⇒ ( at col 2 ⇒ match ) at col 4
    try testing.expectEqual(@as(?view.Pos, .{ .x = 4, .y = 0 }), matchBracket(g, .{ .x = 0, .y = 0 }, 80));
}

test "matchBracket: no bracket on row ⇒ null (no move)" {
    var sg = SliceGrid{ .rows = &.{asciiRow("abc def")}, .total_rows = 1, .cols = 80 };
    const g = sg.grid();
    try testing.expectEqual(@as(?view.Pos, null), matchBracket(g, .{ .x = 0, .y = 0 }, 80));
}

test "matchBracket: unbalanced ⇒ null" {
    var sg = SliceGrid{ .rows = &.{asciiRow("(abc")}, .total_rows = 1, .cols = 80 };
    const g = sg.grid();
    try testing.expectEqual(@as(?view.Pos, null), matchBracket(g, .{ .x = 0, .y = 0 }, 80));
    var sg2 = SliceGrid{ .rows = &.{asciiRow("abc)")}, .total_rows = 1, .cols = 80 };
    const g2 = sg2.grid();
    try testing.expectEqual(@as(?view.Pos, null), matchBracket(g2, .{ .x = 3, .y = 0 }, 80));
}

test "matchBracket: cross-row match" {
    var sg = SliceGrid{ .rows = &.{ asciiRow("(abc"), asciiRow("def)") }, .total_rows = 2, .cols = 80 };
    const g = sg.grid();
    // ( at (0,0) ⇒ ) at (3,1)
    try testing.expectEqual(@as(?view.Pos, .{ .x = 3, .y = 1 }), matchBracket(g, .{ .x = 0, .y = 0 }, 80));
}

// ---- paragraphBack / paragraphFwd ------------------------------------------

test "paragraphBack: nearest blank row strictly above" {
    var sg = SliceGrid{
        .rows = &.{ asciiRow("a"), asciiRow(""), asciiRow("b"), asciiRow("c") },
        .total_rows = 4,
        .cols = 80,
    };
    const g = sg.grid();
    // { from row 3 ⇒ row 1 (blank)
    try testing.expectEqual(@as(u32, 1), paragraphBack(g, 3, 1));
}

test "paragraphFwd: nearest blank row strictly below" {
    var sg = SliceGrid{
        .rows = &.{ asciiRow("a"), asciiRow("b"), asciiRow(""), asciiRow("c") },
        .total_rows = 4,
        .cols = 80,
    };
    const g = sg.grid();
    // } from row 0 ⇒ row 2 (blank)
    try testing.expectEqual(@as(u32, 2), paragraphFwd(g, 0, 1));
}

test "paragraphBack/paragraphFwd: count repeats" {
    var sg = SliceGrid{
        .rows = &.{ asciiRow(""), asciiRow("a"), asciiRow(""), asciiRow("b"), asciiRow(""), asciiRow("c") },
        .total_rows = 6,
        .cols = 80,
    };
    const g = sg.grid();
    // 2} from row 1 ⇒ row 4 (skip the blank at row 2, then land on blank at row 4)
    try testing.expectEqual(@as(u32, 4), paragraphFwd(g, 1, 2));
    // 2{ from row 5 ⇒ row 1 (skip blank at row 4, then land on blank at row 1... wait row 0 is blank too)
    // row 4 is blank, row 1 is NOT — recompute. rows: 0=blank,1=a,2=blank,3=b,4=blank,5=c
    // { from 5: nearest blank above is 4; from 4 nearest blank above is 2 ⇒ 2
    try testing.expectEqual(@as(u32, 2), paragraphBack(g, 5, 2));
}

test "paragraphBack: no blank above ⇒ clamp to 0 (BOF)" {
    var sg = SliceGrid{ .rows = &.{ asciiRow("a"), asciiRow("b") }, .total_rows = 2, .cols = 80 };
    const g = sg.grid();
    try testing.expectEqual(@as(u32, 0), paragraphBack(g, 1, 1));
}

test "paragraphFwd: no blank below ⇒ clamp to last row (EOF)" {
    var sg = SliceGrid{ .rows = &.{ asciiRow("a"), asciiRow("b") }, .total_rows = 2, .cols = 80 };
    const g = sg.grid();
    try testing.expectEqual(@as(u32, 1), paragraphFwd(g, 0, 1));
}

// ---- SliceGrid --------------------------------------------------------------

test "SliceGrid: rows[y] passthrough; y >= total_rows ⇒ empty Row" {
    var sg = SliceGrid{ .rows = &.{ asciiRow("a"), asciiRow("bc") }, .total_rows = 2, .cols = 80 };
    const g = sg.grid();
    try testing.expectEqualStrings("a", g.getRow(0).text);
    try testing.expectEqualStrings("bc", g.getRow(1).text);
    const past = g.getRow(2);
    try testing.expectEqual(@as(usize, 0), past.text.len);
    try testing.expectEqual(@as(usize, 0), past.col.len);
}

// ---- applyMotion: horizontal (h/l/0/^/$) ------------------------------------

test "applyMotion: h moves left by count; clamps to 0 and lastCellCol" {
    var sg = SliceGrid{ .rows = &.{asciiRow("abc")}, .total_rows = 1, .cols = 80 };
    const g = sg.grid();
    const vp = view.Viewport{ .cols = 80, .rows = 5, .scroll = 0 };
    // h from (2,0) count 1 ⇒ (1,0)
    var out = applyMotion(.{ .pos = .{ .x = 2, .y = 0 }, .viewport = vp }, .left, 1, g);
    try testing.expectEqual(view.Pos{ .x = 1, .y = 0 }, out.pos);
    try testing.expectEqual(@as(u32, 0), out.viewport.scroll);
    // 5h from (2,0) ⇒ clamps to 0
    out = applyMotion(.{ .pos = .{ .x = 2, .y = 0 }, .viewport = vp }, .left, 5, g);
    try testing.expectEqual(view.Pos{ .x = 0, .y = 0 }, out.pos);
}

test "applyMotion: l moves right by count; clamps to lastCellCol/cols-1" {
    var sg = SliceGrid{ .rows = &.{asciiRow("abc")}, .total_rows = 1, .cols = 80 };
    const g = sg.grid();
    const vp = view.Viewport{ .cols = 80, .rows = 5, .scroll = 0 };
    var out = applyMotion(.{ .pos = .{ .x = 0, .y = 0 }, .viewport = vp }, .right, 1, g);
    try testing.expectEqual(view.Pos{ .x = 1, .y = 0 }, out.pos);
    // 9l clamps to last cell (2)
    out = applyMotion(.{ .pos = .{ .x = 0, .y = 0 }, .viewport = vp }, .right, 9, g);
    try testing.expectEqual(view.Pos{ .x = 2, .y = 0 }, out.pos);
}

test "applyMotion: 0 sets x=0; ^ sets x=firstNonBlankCol" {
    var sg = SliceGrid{ .rows = &.{asciiRow("  abc")}, .total_rows = 1, .cols = 80 };
    const g = sg.grid();
    const vp = view.Viewport{ .cols = 80, .rows = 5, .scroll = 0 };
    var out = applyMotion(.{ .pos = .{ .x = 4, .y = 0 }, .viewport = vp }, .line_start, 1, g);
    try testing.expectEqual(view.Pos{ .x = 0, .y = 0 }, out.pos);
    out = applyMotion(.{ .pos = .{ .x = 0, .y = 0 }, .viewport = vp }, .first_nonblank, 1, g);
    try testing.expectEqual(view.Pos{ .x = 2, .y = 0 }, out.pos);
}

test "applyMotion: $ sets x=lastCellCol; 2$ moves down then end" {
    var sg = SliceGrid{ .rows = &.{ asciiRow("ab"), asciiRow("cdef") }, .total_rows = 2, .cols = 80 };
    const g = sg.grid();
    const vp = view.Viewport{ .cols = 80, .rows = 5, .scroll = 0 };
    // $ from (0,0) ⇒ last cell of row 0 (1,0)
    var out = applyMotion(.{ .pos = .{ .x = 0, .y = 0 }, .viewport = vp }, .line_end, 1, g);
    try testing.expectEqual(view.Pos{ .x = 1, .y = 0 }, out.pos);
    // 2$ from (0,0) ⇒ end of NEXT row (3,1)
    out = applyMotion(.{ .pos = .{ .x = 0, .y = 0 }, .viewport = vp }, .line_end, 2, g);
    try testing.expectEqual(view.Pos{ .x = 3, .y = 1 }, out.pos);
}

// ---- applyMotion: vertical (j/k) with scrollForCursor -----------------------

test "applyMotion: j moves down by count; k moves up by count" {
    var sg = SliceGrid{
        .rows = &.{ asciiRow("a"), asciiRow("b"), asciiRow("c"), asciiRow("d") },
        .total_rows = 4,
        .cols = 80,
    };
    const g = sg.grid();
    const vp = view.Viewport{ .cols = 80, .rows = 5, .scroll = 0 }; // 4 rows fit in 5
    // 5j from (0,0) ⇒ clamp to last row (3,0)... wait x stays; (0,3)
    var out = applyMotion(.{ .pos = .{ .x = 0, .y = 0 }, .viewport = vp }, .down, 5, g);
    try testing.expectEqual(view.Pos{ .x = 0, .y = 3 }, out.pos);
    // 5k from (0,3) ⇒ clamp to (0,0)
    out = applyMotion(.{ .pos = .{ .x = 0, .y = 3 }, .viewport = vp }, .up, 5, g);
    try testing.expectEqual(view.Pos{ .x = 0, .y = 0 }, out.pos);
    // scroll unchanged (grid fits in viewport)
    try testing.expectEqual(@as(u32, 0), out.viewport.scroll);
}

test "applyMotion: j recomputes scroll via scrollForCursor (cursor pushed below viewport)" {
    // 20-row grid, 5-row viewport, scroll 0. j to row 10 ⇒ cursor below ⇒ scroll = 10-(5-1)=6.
    var rows_buf: [20]Row = undefined;
    for (0..20) |i| rows_buf[i] = asciiRow("a");
    var sg = SliceGrid{ .rows = rows_buf[0..], .total_rows = 20, .cols = 80 };
    const g = sg.grid();
    const vp = view.Viewport{ .cols = 80, .rows = 5, .scroll = 0 };
    const out = applyMotion(.{ .pos = .{ .x = 0, .y = 0 }, .viewport = vp }, .down, 10, g);
    try testing.expectEqual(view.Pos{ .x = 0, .y = 10 }, out.pos);
    try testing.expectEqual(@as(u32, 6), out.viewport.scroll);
}

// ---- applyMotion: word motions (w/b/e) --------------------------------------

test "applyMotion: w/b/e dispatch to primitives" {
    var sg = SliceGrid{ .rows = &.{asciiRow("foo bar baz")}, .total_rows = 1, .cols = 80 };
    const g = sg.grid();
    const vp = view.Viewport{ .cols = 80, .rows = 5, .scroll = 0 };
    var out = applyMotion(.{ .pos = .{ .x = 0, .y = 0 }, .viewport = vp }, .word_fwd, 1, g);
    try testing.expectEqual(view.Pos{ .x = 4, .y = 0 }, out.pos);
    out = applyMotion(.{ .pos = .{ .x = 4, .y = 0 }, .viewport = vp }, .word_back, 1, g);
    try testing.expectEqual(view.Pos{ .x = 0, .y = 0 }, out.pos);
    out = applyMotion(.{ .pos = .{ .x = 0, .y = 0 }, .viewport = vp }, .word_end, 1, g);
    try testing.expectEqual(view.Pos{ .x = 2, .y = 0 }, out.pos);
}

// ---- applyMotion: gg / G (count semantics) ----------------------------------

test "applyMotion: plain gg (count<=1) ⇒ row 0; 5gg ⇒ row 4" {
    var rows_buf: [20]Row = undefined;
    for (0..20) |i| rows_buf[i] = asciiRow("a");
    var sg = SliceGrid{ .rows = rows_buf[0..], .total_rows = 20, .cols = 80 };
    const g = sg.grid();
    const vp = view.Viewport{ .cols = 80, .rows = 5, .scroll = 10 };
    // plain gg ⇒ row 0
    var out = applyMotion(.{ .pos = .{ .x = 0, .y = 10 }, .viewport = vp }, .doc_top, 1, g);
    try testing.expectEqual(view.Pos{ .x = 0, .y = 0 }, out.pos);
    try testing.expectEqual(@as(u32, 0), out.viewport.scroll); // topOnCursor(0) = 0
    // 5gg ⇒ row 4
    out = applyMotion(.{ .pos = .{ .x = 0, .y = 10 }, .viewport = vp }, .doc_top, 5, g);
    try testing.expectEqual(view.Pos{ .x = 0, .y = 4 }, out.pos);
}

test "applyMotion: plain G (count<=1) ⇒ last row; 5G ⇒ row 4" {
    var rows_buf: [20]Row = undefined;
    for (0..20) |i| rows_buf[i] = asciiRow("a");
    var sg = SliceGrid{ .rows = rows_buf[0..], .total_rows = 20, .cols = 80 };
    const g = sg.grid();
    const vp = view.Viewport{ .cols = 80, .rows = 5, .scroll = 0 };
    // plain G ⇒ last row (19)
    var out = applyMotion(.{ .pos = .{ .x = 0, .y = 0 }, .viewport = vp }, .doc_bottom, 1, g);
    try testing.expectEqual(view.Pos{ .x = 0, .y = 19 }, out.pos);
    try testing.expectEqual(@as(u32, 15), out.viewport.scroll); // maxscroll = 20-5
    // 5G ⇒ row 4
    out = applyMotion(.{ .pos = .{ .x = 0, .y = 0 }, .viewport = vp }, .doc_bottom, 5, g);
    try testing.expectEqual(view.Pos{ .x = 0, .y = 4 }, out.pos);
}

// ---- applyMotion: half-page (Ctrl-d/u) --------------------------------------

test "applyMotion: Ctrl-d moves cursor +half and scrolls half page down" {
    // 20 rows, 10-row viewport, scroll 0, cursor 0. half=5. Ctrl-d ⇒ y=5, scroll=5.
    var rows_buf: [20]Row = undefined;
    for (0..20) |i| rows_buf[i] = asciiRow("a");
    var sg = SliceGrid{ .rows = rows_buf[0..], .total_rows = 20, .cols = 80 };
    const g = sg.grid();
    const vp = view.Viewport{ .cols = 80, .rows = 10, .scroll = 0 };
    const out = applyMotion(.{ .pos = .{ .x = 0, .y = 0 }, .viewport = vp }, .half_page_down, 1, g);
    try testing.expectEqual(view.Pos{ .x = 0, .y = 5 }, out.pos);
    try testing.expectEqual(@as(u32, 5), out.viewport.scroll);
}

test "applyMotion: Ctrl-u moves cursor -half and scrolls half page up" {
    // 20 rows, 10-row viewport, scroll 10, cursor 15. half=5. Ctrl-u ⇒ y=10, scroll=5.
    var rows_buf: [20]Row = undefined;
    for (0..20) |i| rows_buf[i] = asciiRow("a");
    var sg = SliceGrid{ .rows = rows_buf[0..], .total_rows = 20, .cols = 80 };
    const g = sg.grid();
    const vp = view.Viewport{ .cols = 80, .rows = 10, .scroll = 10 };
    const out = applyMotion(.{ .pos = .{ .x = 0, .y = 15 }, .viewport = vp }, .half_page_up, 1, g);
    try testing.expectEqual(view.Pos{ .x = 0, .y = 10 }, out.pos);
    try testing.expectEqual(@as(u32, 5), out.viewport.scroll);
}

// ---- applyMotion: full-page (Ctrl-f/b) --------------------------------------

test "applyMotion: Ctrl-f moves cursor +rows and scrolls full page down" {
    // 20 rows, 5-row viewport, scroll 0, cursor 0. Ctrl-f ⇒ y=5, scroll=5.
    var rows_buf: [20]Row = undefined;
    for (0..20) |i| rows_buf[i] = asciiRow("a");
    var sg = SliceGrid{ .rows = rows_buf[0..], .total_rows = 20, .cols = 80 };
    const g = sg.grid();
    const vp = view.Viewport{ .cols = 80, .rows = 5, .scroll = 0 };
    const out = applyMotion(.{ .pos = .{ .x = 0, .y = 0 }, .viewport = vp }, .page_down, 1, g);
    try testing.expectEqual(view.Pos{ .x = 0, .y = 5 }, out.pos);
    try testing.expectEqual(@as(u32, 5), out.viewport.scroll);
}

test "applyMotion: Ctrl-b moves cursor -rows and scrolls full page up" {
    // 20 rows, 5-row viewport, scroll 10, cursor 12. Ctrl-b ⇒ y=7, scroll=5.
    var rows_buf: [20]Row = undefined;
    for (0..20) |i| rows_buf[i] = asciiRow("a");
    var sg = SliceGrid{ .rows = rows_buf[0..], .total_rows = 20, .cols = 80 };
    const g = sg.grid();
    const vp = view.Viewport{ .cols = 80, .rows = 5, .scroll = 10 };
    const out = applyMotion(.{ .pos = .{ .x = 0, .y = 12 }, .viewport = vp }, .page_up, 1, g);
    try testing.expectEqual(view.Pos{ .x = 0, .y = 7 }, out.pos);
    try testing.expectEqual(@as(u32, 5), out.viewport.scroll);
}

// ---- applyMotion: H / M / L (viewport-relative; scroll unchanged) -----------

test "applyMotion: H/M/L jump within viewport; scroll unchanged" {
    // 20 rows, 10-row viewport, scroll 5 ⇒ visible rows 5..14.
    var rows_buf: [20]Row = undefined;
    for (0..20) |i| rows_buf[i] = asciiRow("a");
    var sg = SliceGrid{ .rows = rows_buf[0..], .total_rows = 20, .cols = 80 };
    const g = sg.grid();
    const vp = view.Viewport{ .cols = 80, .rows = 10, .scroll = 5 };
    // H ⇒ scroll+0 = 5
    var out = applyMotion(.{ .pos = .{ .x = 0, .y = 10 }, .viewport = vp }, .viewport_top, 1, g);
    try testing.expectEqual(view.Pos{ .x = 0, .y = 5 }, out.pos);
    try testing.expectEqual(@as(u32, 5), out.viewport.scroll); // unchanged
    // M ⇒ scroll+rows/2 = 5+5 = 10
    out = applyMotion(.{ .pos = .{ .x = 0, .y = 0 }, .viewport = vp }, .viewport_mid, 1, g);
    try testing.expectEqual(view.Pos{ .x = 0, .y = 10 }, out.pos);
    try testing.expectEqual(@as(u32, 5), out.viewport.scroll); // unchanged
    // L ⇒ scroll+rows-1 = 5+9 = 14
    out = applyMotion(.{ .pos = .{ .x = 0, .y = 0 }, .viewport = vp }, .viewport_bottom, 1, g);
    try testing.expectEqual(view.Pos{ .x = 0, .y = 14 }, out.pos);
    try testing.expectEqual(@as(u32, 5), out.viewport.scroll); // unchanged
    // 3H ⇒ scroll+(3-1) = 7
    out = applyMotion(.{ .pos = .{ .x = 0, .y = 0 }, .viewport = vp }, .viewport_top, 3, g);
    try testing.expectEqual(view.Pos{ .x = 0, .y = 7 }, out.pos);
    // 2L ⇒ (scroll+rows-1)-(2-1) = 14-1 = 13
    out = applyMotion(.{ .pos = .{ .x = 0, .y = 0 }, .viewport = vp }, .viewport_bottom, 2, g);
    try testing.expectEqual(view.Pos{ .x = 0, .y = 13 }, out.pos);
}

// ---- applyMotion: paragraph ({/}) -------------------------------------------

test "applyMotion: { jumps to nearest blank above; } to nearest blank below" {
    var sg = SliceGrid{
        .rows = &.{ asciiRow("a"), asciiRow(""), asciiRow("b"), asciiRow("c") },
        .total_rows = 4,
        .cols = 80,
    };
    const g = sg.grid();
    const vp = view.Viewport{ .cols = 80, .rows = 5, .scroll = 0 };
    // { from row 3 ⇒ row 1
    var out = applyMotion(.{ .pos = .{ .x = 0, .y = 3 }, .viewport = vp }, .paragraph_back, 1, g);
    try testing.expectEqual(view.Pos{ .x = 0, .y = 1 }, out.pos);
    // } from row 0 ⇒ ... no blank below row 0 until? rows: 0=a,1=blank,2=b,3=c ⇒ row 1
    out = applyMotion(.{ .pos = .{ .x = 0, .y = 0 }, .viewport = vp }, .paragraph_fwd, 1, g);
    try testing.expectEqual(view.Pos{ .x = 0, .y = 1 }, out.pos);
}

// ---- applyMotion: % (match_bracket) -----------------------------------------

test "applyMotion: % matches bracket; no bracket on row ⇒ cursor unchanged" {
    // (abc): cursor on '(' ⇒ match ')' (forward). cursor NOT on a bracket but a bracket is
    // forward on the row ⇒ vim searches forward for the first bracket and matches it.
    var sg = SliceGrid{ .rows = &.{asciiRow("(abc)")}, .total_rows = 1, .cols = 80 };
    const g = sg.grid();
    const vp = view.Viewport{ .cols = 80, .rows = 5, .scroll = 0 };
    // % from (0,0) [on '('] ⇒ (4,0)
    var out = applyMotion(.{ .pos = .{ .x = 0, .y = 0 }, .viewport = vp }, .match_bracket, 1, g);
    try testing.expectEqual(view.Pos{ .x = 4, .y = 0 }, out.pos);
    // % from (2,0) [on 'b' — not a bracket, but ')' is forward on the row ⇒ search forward,
    // find ')' at col 4, match its opener '(' at col 0]
    out = applyMotion(.{ .pos = .{ .x = 2, .y = 0 }, .viewport = vp }, .match_bracket, 1, g);
    try testing.expectEqual(view.Pos{ .x = 0, .y = 0 }, out.pos);
    // % on a row with NO bracket at all ⇒ cursor UNCHANGED (no move, scroll unchanged)
    var sg2 = SliceGrid{ .rows = &.{asciiRow("abc def")}, .total_rows = 1, .cols = 80 };
    const g2 = sg2.grid();
    out = applyMotion(.{ .pos = .{ .x = 2, .y = 0 }, .viewport = vp }, .match_bracket, 1, g2);
    try testing.expectEqual(view.Pos{ .x = 2, .y = 0 }, out.pos);
    try testing.expectEqual(@as(u32, 0), out.viewport.scroll); // unchanged
}

// ---- nextMatch / prevMatch --------------------------------------------------

test "nextMatch: forward — strictly-after returns first match past cursor" {
    const matches = [_]view.Match{
        .{ .y = 0, .x1 = 2, .x2 = 4 },
        .{ .y = 0, .x1 = 7, .x2 = 9 },
        .{ .y = 1, .x1 = 0, .x2 = 2 },
    };
    const s = SearchState{ .matches = &matches, .direction = .forward };
    // cursor at (0,0) ⇒ first strictly-after is (0,2)
    try testing.expectEqual(@as(?view.Pos, .{ .x = 2, .y = 0 }), nextMatch(s, .{ .x = 0, .y = 0 }, .forward));
    // cursor at (0,2) [ON a match start] ⇒ NOT after ⇒ next is (0,7)
    try testing.expectEqual(@as(?view.Pos, .{ .x = 7, .y = 0 }), nextMatch(s, .{ .x = 2, .y = 0 }, .forward));
    // cursor at (0,5) ⇒ (0,7)
    try testing.expectEqual(@as(?view.Pos, .{ .x = 7, .y = 0 }), nextMatch(s, .{ .x = 5, .y = 0 }, .forward));
}

test "nextMatch: forward wraparound — past last match ⇒ matches[0]" {
    const matches = [_]view.Match{
        .{ .y = 0, .x1 = 2, .x2 = 4 },
        .{ .y = 0, .x1 = 7, .x2 = 9 },
    };
    const s = SearchState{ .matches = &matches, .direction = .forward };
    // cursor past the last match (0,10) ⇒ wrap to matches[0] (0,2)
    try testing.expectEqual(@as(?view.Pos, .{ .x = 2, .y = 0 }), nextMatch(s, .{ .x = 10, .y = 0 }, .forward));
    // cursor on last match (0,9) ⇒ next-after wraps to (0,2)
    try testing.expectEqual(@as(?view.Pos, .{ .x = 2, .y = 0 }), nextMatch(s, .{ .x = 9, .y = 0 }, .forward));
}

test "nextMatch: backward — strictly-before returns first match before cursor (reverse order)" {
    const matches = [_]view.Match{
        .{ .y = 0, .x1 = 2, .x2 = 4 },
        .{ .y = 0, .x1 = 7, .x2 = 9 },
    };
    const s = SearchState{ .matches = &matches, .direction = .backward };
    // cursor at (0,8) ⇒ first strictly-before is (0,2)
    try testing.expectEqual(@as(?view.Pos, .{ .x = 2, .y = 0 }), nextMatch(s, .{ .x = 8, .y = 0 }, .backward));
    // cursor at (0,7) [ON a match start] ⇒ NOT before ⇒ wrap to last (0,7)? No: strictly-before 7 is 2.
    try testing.expectEqual(@as(?view.Pos, .{ .x = 2, .y = 0 }), nextMatch(s, .{ .x = 7, .y = 0 }, .backward));
}

test "nextMatch: backward wraparound — before first match ⇒ matches[last]" {
    const matches = [_]view.Match{
        .{ .y = 0, .x1 = 2, .x2 = 4 },
        .{ .y = 0, .x1 = 7, .x2 = 9 },
    };
    const s = SearchState{ .matches = &matches, .direction = .backward };
    // cursor at (0,0) ⇒ no match strictly before ⇒ wrap to last (0,7)
    try testing.expectEqual(@as(?view.Pos, .{ .x = 7, .y = 0 }), nextMatch(s, .{ .x = 0, .y = 0 }, .backward));
}

test "nextMatch: empty matches ⇒ null" {
    const s = SearchState{ .matches = &.{} };
    try testing.expectEqual(@as(?view.Pos, null), nextMatch(s, .{ .x = 0, .y = 0 }, .forward));
    try testing.expectEqual(@as(?view.Pos, null), nextMatch(s, .{ .x = 0, .y = 0 }, .backward));
}

test "prevMatch: forward direction ⇒ searches backward" {
    const matches = [_]view.Match{
        .{ .y = 0, .x1 = 2, .x2 = 4 },
        .{ .y = 0, .x1 = 7, .x2 = 9 },
    };
    const s = SearchState{ .matches = &matches, .direction = .forward };
    // prevMatch with forward direction ⇒ backward search ⇒ cursor at (0,8) ⇒ (0,2)
    try testing.expectEqual(@as(?view.Pos, .{ .x = 2, .y = 0 }), prevMatch(s, .{ .x = 8, .y = 0 }));
}

// ---- applyMotion: empty grid is a no-op -------------------------------------

test "applyMotion: empty grid (total_rows=0) ⇒ cursor unchanged for every variant" {
    var sg = SliceGrid{ .rows = &.{}, .total_rows = 0, .cols = 80 };
    const g = sg.grid();
    const vp = view.Viewport{ .cols = 80, .rows = 5, .scroll = 0 };
    const c = Cursor{ .pos = .{ .x = 3, .y = 2 }, .viewport = vp };
    // spot-check a few variants — all should be no-ops.
    inline for ([_]input.Motion{ .left, .right, .up, .down, .word_fwd, .doc_top, .doc_bottom, .match_bracket }) |mv| {
        const out = applyMotion(c, mv, 1, g);
        try testing.expectEqual(c.pos, out.pos);
        try testing.expectEqual(vp.scroll, out.viewport.scroll);
    }
}
