//! select.zig — the PURE selection model for the copy-mode TUI (PRD §7.4; arch tui_region.md §4).
//!
//! Owns the interactive selection STATE: an anchor endpoint, a cursor endpoint, and a mode
//! (none/linewise/block). Consumes the SHIPPED `input.Action` contract (P3.M2.T1.S1) + REUSES
//! `view`'s display types (Pos/Selection/SelMode, P3.M1.T2) — single source of truth, NO
//! duplicate types. Emits a normalized `view.Selection` (the very struct `view.render`/
//! `view.highlight` consume) for the TUI overlay AND for S2's grid-aware pin conversion
//! (P3.M2.T2.S2 maps it 1:1 to `cli.SelectionCoords` → `render.buildSelection`).
//!
//! PRD §7.4 state machine (copy-mode parity):
//!   `v` begins / RE-ANCHORS a linewise selection at the cursor (discards any prior selection);
//!   `V` is a linewise alias of `v`; `Ctrl-v`/`R` begin block (inactive) or toggle
//!   linewise↔block (active); `o`/`O` swap the cursor to the other end; `Esc` clears (stay
//!   in the TUI); movement extends the selection anchor→cursor.
//!
//! Layering (arch tui_region.md §4): region.zig (P3.M3) OWNS a `motion.Cursor` + a `select.Sel`
//! and keeps `sel.cursor` in sync with `Cursor.pos`; it calls `select.applyAction` for selection
//! actions and passes `sel.extent(cols)` + `sel.viewMode()` into `view.render`/`view.Status`.
//!
//! PURE: no I/O, no allocation, no `Terminal`. select.zig imports `view.zig` (which imports
//! ghostty-vt) + `input.zig` (which imports app.zig) — IMPORTING is fine; the cross-test GOTCHA
//! (render.zig/view.zig) is about CONSTRUCTING a `Terminal` in a separate test fn (process-global
//! state corruption), NOT about importing. select.zig NEVER constructs a Terminal ⇒ its tests are
//! SAFE as SEPARATE `test` fns (mirrors input.zig + the parallel motion.zig).

const std = @import("std");
const view = @import("view.zig"); // Pos, Selection, SelMode (SHIPPED — reuse, do NOT redefine)
const input = @import("input.zig"); // Action (S1 CONTRACT — consume)

/// The selection mode. `.none` ⇒ no active selection (the Sel exists but is dormant).
/// PRD §7.4: `v` begins / re-anchors linewise; `Ctrl-v` begins block (inactive) or toggles
/// linewise↔block (active); `V` is a linewise alias of `v`.
pub const Mode = enum { none, linewise, block };

/// The interactive selection state. `anchor` = the fixed end (set at `begin`, unchanged by
/// motion); `cursor` = the moving end (region.zig P3.M3 keeps it in sync with motion.Cursor.pos).
/// When `mode == .none` the endpoints are DORMANT (ignore them). Either endpoint may be the
/// geometric top-left; `extent()` normalizes via min/max (mirrors view.normSel).
pub const Sel = struct {
    anchor: view.Pos = .{ .x = 0, .y = 0 },
    cursor: view.Pos = .{ .x = 0, .y = 0 },
    mode: Mode = .none,

    /// True when a selection is active (mode != .none). Drives the Esc clear-vs-quit decision
    /// in region.zig + the status line's `<S-sel>` token + `view.Status.has_selection`.
    pub fn active(self: Sel) bool {
        return self.mode != .none;
    }

    /// Clear the selection (mode → .none). Endpoints are left stale (dormant); a later `begin`
    /// overwrites them. PRD §7.4 "Esc clears the selection (stays in the TUI)".
    pub fn clear(self: *Sel) void {
        self.mode = .none;
    }

    /// Toggle linewise ↔ block (PRD §7.4: `Ctrl-v` pressed again toggles back). Only meaningful
    /// when `active()`; on `.none` it is a NO-OP (the `v`-begins path uses `begin`, not toggle).
    /// Endpoints are PRESERVED (only the mode flips) — rectangle-toggle, as in tmux copy mode.
    pub fn toggle(self: *Sel) void {
        self.mode = switch (self.mode) {
            .linewise => .block,
            .block => .linewise,
            .none => .none,
        };
    }

    /// Swap the anchor and cursor ends (PRD §7.4 "o / O swap cursor to the other end"). Both
    /// `o` and `O` do this in linewise/block mode (PRD treats them identically — the vim
    /// visual-block o-vs-O corner distinction is a documented v1 simplification, NOT modeled).
    /// After the swap the cursor is at the former anchor (so subsequent motion moves the OTHER
    /// end). `applyAction` guards this on `active()`; calling `swapEnds` directly on a dormant
    /// Sel still swaps the stored endpoints (harmless — extent returns null while inactive).
    pub fn swapEnds(self: *Sel) void {
        const tmp = self.anchor;
        self.anchor = self.cursor;
        self.cursor = tmp;
    }

    /// Begin a selection at `pos` in `mode` (PRD §7.4: `v`→linewise, `V`→linewise, `Ctrl-v`/`R`→block).
    /// Sets anchor = cursor = pos (a collapsed seed the user then extends via motion). region.zig
    /// calls this (via applyAction) when a visual_* action fires and the Sel is INACTIVE.
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
    /// (view.normSel ALSO min/max's, so passing either order is safe; we pre-normalize for S2
    /// so the SAME value is correct for S2's cli.SelectionCoords.)
    pub fn extent(self: Sel, cols: u16) ?view.Selection {
        if (self.mode == .none) return null;
        const a = self.anchor;
        const c = self.cursor;
        const y1: u32 = @min(a.y, c.y);
        const y2: u32 = @max(a.y, c.y);
        // Guard degenerate cols==0 (never happens in practice — popup ≥1 col — but avoids
        // u32 underflow on cols-1). Widen cols (u16) to u32 BEFORE the subtract.
        const last_col: u32 = if (cols == 0) 0 else @as(u32, cols) - 1;
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
/// them at the loop level — exit / confirm-render flow). `.clear` always clears; region.zig
/// decides clear-vs-quit on Esc by checking `sel.active()` BEFORE calling this (see design_notes §2).
///
/// PRD §7.4 per-action state table (authoritative — copy-mode parity):
///   visual_toggle (v)     ALWAYS begin(cursor,.linewise) — RE-ANCHORS at the cursor, DISCARDING
///                         any prior selection (the only way to move the starting line)
///   visual_line (V)       alias of `v`: begin(cursor,.linewise) (re-anchor)
///   visual_block (Ctrl-v/R) inactive ⇒ begin(cursor,.block); active ⇒ toggle() (linewise↔block).
///                         Does NOT re-anchor (use `v` to move the start).
///   swap_end/other (o/O)  inactive ⇒ NO-OP;                   active ⇒ swapEnds()
///   clear (Esc)           clear() — the clear-vs-QUIT decision is region.zig's
///   quit (q/Ctrl-c)       NO-OP on Sel (region.zig exits)
///   confirm (Enter/y)     NO-OP on Sel (region.zig: render selection)
pub fn applyAction(sel: *Sel, action: input.Action, cursor: view.Pos) void {
    switch (action) {
        .visual_toggle, .visual_line => {
            // PRD §7.4: `v` begins / RESTARTS selection at the cursor in linewise mode, DISCARDING
            // any prior selection ("the only way to change the starting line"). `V` is a linewise
            // alias of `v` (PRD §7.4 familiarity aliases) => same re-anchor behavior.
            sel.begin(cursor, .linewise);
        },
        .visual_block => {
            // PRD §7.4: `Ctrl-v`/`R` enters visual block. Inactive ⇒ begin block at cursor; ACTIVE
            // ⇒ TOGGLE linewise↔block (rectangle-toggle, as in tmux), endpoints PRESERVED. Does
            // NOT re-anchor (use `v` to move the start).
            if (!sel.active()) sel.begin(cursor, .block) else sel.toggle();
        },
        .swap_end, .swap_end_other => {
            // PRD §7.4: `o`/`O` swap cursor to the other end. Vim: a no-op when NOT in visual mode.
            if (sel.active()) sel.swapEnds();
        },
        .clear => sel.clear(), // Esc clears the selection (the clear-vs-QUIT decision is region.zig's)
        .quit, .confirm => {}, // NOT selection actions — handled by region.zig's loop (exit/confirm flow)
    }
}

// ============================================================================
// Unit tests — ALL as SEPARATE `test` fns (select.zig is PURE, no Terminal ⇒ SAFE; mirrors
// input.zig + the parallel motion.zig). Pure value-struct assertions — NO allocation, NO I/O.
// ============================================================================

const testing = std.testing;

// ---- Sel defaults + active() ------------------------------------------------

test "Sel: default is inactive — mode .none, anchor=cursor=(0,0), active()==false" {
    const s: Sel = .{};
    try testing.expectEqual(Mode.none, s.mode);
    try testing.expectEqual(view.Pos{ .x = 0, .y = 0 }, s.anchor);
    try testing.expectEqual(view.Pos{ .x = 0, .y = 0 }, s.cursor);
    try testing.expect(!s.active());
}

test "active: true for linewise/block, false for none" {
    try testing.expect(!(Sel{ .mode = .none }).active());
    try testing.expect((Sel{ .mode = .linewise }).active());
    try testing.expect((Sel{ .mode = .block }).active());
}

test "begin: sets anchor=cursor=pos, mode=mode; overwrites prior state" {
    var s: Sel = .{};
    // Start from a non-default state to confirm begin overwrites it.
    s.anchor = .{ .x = 9, .y = 9 };
    s.cursor = .{ .x = 8, .y = 7 };
    s.mode = .block;
    s.begin(.{ .x = 3, .y = 4 }, .linewise);
    try testing.expectEqual(view.Pos{ .x = 3, .y = 4 }, s.anchor);
    try testing.expectEqual(view.Pos{ .x = 3, .y = 4 }, s.cursor);
    try testing.expectEqual(Mode.linewise, s.mode);
    try testing.expect(s.active());
}

test "begin: block mode" {
    var s: Sel = .{};
    s.begin(.{ .x = 5, .y = 6 }, .block);
    try testing.expectEqual(Mode.block, s.mode);
    try testing.expectEqual(view.Pos{ .x = 5, .y = 6 }, s.anchor);
    try testing.expectEqual(view.Pos{ .x = 5, .y = 6 }, s.cursor);
}

test "clear: sets mode .none (endpoints left stale but dormant)" {
    var s = Sel{ .anchor = .{ .x = 1, .y = 2 }, .cursor = .{ .x = 3, .y = 4 }, .mode = .linewise };
    s.clear();
    try testing.expectEqual(Mode.none, s.mode);
    try testing.expect(!s.active());
    // Endpoints are left stale (documented; a later begin overwrites them).
    try testing.expectEqual(view.Pos{ .x = 1, .y = 2 }, s.anchor);
    try testing.expectEqual(view.Pos{ .x = 3, .y = 4 }, s.cursor);
}

// ---- toggle() ---------------------------------------------------------------

test "toggle: linewise → block → linewise (endpoints PRESERVED)" {
    var s = Sel{ .anchor = .{ .x = 1, .y = 2 }, .cursor = .{ .x = 3, .y = 4 }, .mode = .linewise };
    s.toggle();
    try testing.expectEqual(Mode.block, s.mode);
    // endpoints unchanged
    try testing.expectEqual(view.Pos{ .x = 1, .y = 2 }, s.anchor);
    try testing.expectEqual(view.Pos{ .x = 3, .y = 4 }, s.cursor);
    s.toggle();
    try testing.expectEqual(Mode.linewise, s.mode);
    try testing.expectEqual(view.Pos{ .x = 1, .y = 2 }, s.anchor);
    try testing.expectEqual(view.Pos{ .x = 3, .y = 4 }, s.cursor);
}

test "toggle: block → linewise" {
    var s = Sel{ .mode = .block };
    s.toggle();
    try testing.expectEqual(Mode.linewise, s.mode);
}

test "toggle: .none → .none (NO-OP — v-begins uses begin(), not toggle())" {
    var s: Sel = .{}; // mode .none
    s.toggle();
    try testing.expectEqual(Mode.none, s.mode);
    try testing.expect(!s.active());
}

// ---- swapEnds() -------------------------------------------------------------

test "swapEnds: swaps anchor ↔ cursor" {
    var s = Sel{ .anchor = .{ .x = 1, .y = 2 }, .cursor = .{ .x = 9, .y = 8 }, .mode = .linewise };
    s.swapEnds();
    try testing.expectEqual(view.Pos{ .x = 9, .y = 8 }, s.anchor);
    try testing.expectEqual(view.Pos{ .x = 1, .y = 2 }, s.cursor);
    try testing.expectEqual(Mode.linewise, s.mode); // mode unchanged
}

test "swapEnds: double-swap is identity" {
    var s = Sel{ .anchor = .{ .x = 5, .y = 6 }, .cursor = .{ .x = 7, .y = 8 }, .mode = .block };
    s.swapEnds();
    s.swapEnds();
    try testing.expectEqual(view.Pos{ .x = 5, .y = 6 }, s.anchor);
    try testing.expectEqual(view.Pos{ .x = 7, .y = 8 }, s.cursor);
    try testing.expectEqual(Mode.block, s.mode);
}

test "swapEnds: called directly on a dormant Sel still swaps stored endpoints (harmless)" {
    // applyAction guards swapEnds on active(); but swapEnds itself is unconditional on the stored
    // endpoints. Since extent returns null when inactive, a stale swap is harmless. Document it.
    var s = Sel{ .anchor = .{ .x = 2, .y = 3 }, .cursor = .{ .x = 4, .y = 5 }, .mode = .none };
    s.swapEnds();
    try testing.expectEqual(view.Pos{ .x = 4, .y = 5 }, s.anchor);
    try testing.expectEqual(view.Pos{ .x = 2, .y = 3 }, s.cursor);
    try testing.expectEqual(Mode.none, s.mode); // still inactive
    try testing.expect(!s.active());
    try testing.expectEqual(@as(?view.Selection, null), s.extent(80));
}

// ---- extent() — inactive / linewise ------------------------------------------

test "extent: inactive ⇒ null" {
    const s: Sel = .{}; // mode .none
    try testing.expectEqual(@as(?view.Selection, null), s.extent(80));
}

test "extent: linewise anchor above cursor ⇒ {0, y_lo, cols-1, y_hi, rect=false}" {
    const s = Sel{
        .anchor = .{ .x = 5, .y = 2 },
        .cursor = .{ .x = 9, .y = 7 },
        .mode = .linewise,
    };
    // cols=80 ⇒ x2=79; y1=min(2,7)=2, y2=max(2,7)=7. x is IGNORED for linewise (x1=0, x2=cols-1).
    const got = s.extent(80).?;
    try testing.expectEqual(@as(u32, 0), got.x1);
    try testing.expectEqual(@as(u32, 2), got.y1);
    try testing.expectEqual(@as(u32, 79), got.x2);
    try testing.expectEqual(@as(u32, 7), got.y2);
    try testing.expectEqual(false, got.rect);
}

test "extent: linewise anchor BELOW cursor ⇒ SAME normalized {y_lo, y_hi} (order-independent)" {
    const s = Sel{
        .anchor = .{ .x = 9, .y = 7 },
        .cursor = .{ .x = 5, .y = 2 },
        .mode = .linewise,
    };
    const got = s.extent(80).?;
    try testing.expectEqual(@as(u32, 0), got.x1);
    try testing.expectEqual(@as(u32, 2), got.y1); // min(7,2)=2
    try testing.expectEqual(@as(u32, 79), got.x2);
    try testing.expectEqual(@as(u32, 7), got.y2); // max(7,2)=7
    try testing.expectEqual(false, got.rect);
}

test "extent: linewise cols=0 ⇒ x2=0 (guard; no u32 underflow)" {
    const s = Sel{ .anchor = .{ .x = 0, .y = 0 }, .cursor = .{ .x = 0, .y = 1 }, .mode = .linewise };
    const got = s.extent(0).?;
    try testing.expectEqual(@as(u32, 0), got.x1);
    try testing.expectEqual(@as(u32, 0), got.x2); // cols==0 guard ⇒ 0, NOT underflow
    try testing.expectEqual(@as(u32, 0), got.y1);
    try testing.expectEqual(@as(u32, 1), got.y2);
    try testing.expectEqual(false, got.rect);
}

test "extent: linewise cols=1 ⇒ x2=0 (cols-1=0)" {
    const s = Sel{ .anchor = .{ .x = 0, .y = 0 }, .cursor = .{ .x = 0, .y = 0 }, .mode = .linewise };
    const got = s.extent(1).?;
    try testing.expectEqual(@as(u32, 0), got.x2); // cols=1 ⇒ 1-1=0
}

// ---- extent() — block --------------------------------------------------------

test "extent: block anchor top-left / cursor bottom-right ⇒ rect, min/max x and y" {
    const s = Sel{
        .anchor = .{ .x = 2, .y = 1 },
        .cursor = .{ .x = 8, .y = 5 },
        .mode = .block,
    };
    const got = s.extent(80).?;
    try testing.expectEqual(@as(u32, 2), got.x1); // min(2,8)=2
    try testing.expectEqual(@as(u32, 1), got.y1); // min(1,5)=1
    try testing.expectEqual(@as(u32, 8), got.x2); // max(2,8)=8
    try testing.expectEqual(@as(u32, 5), got.y2); // max(1,5)=5
    try testing.expectEqual(true, got.rect);
}

test "extent: block anchor bottom-right / cursor top-left ⇒ SAME normalized (order-independent)" {
    const s = Sel{
        .anchor = .{ .x = 8, .y = 5 },
        .cursor = .{ .x = 2, .y = 1 },
        .mode = .block,
    };
    const got = s.extent(80).?;
    try testing.expectEqual(@as(u32, 2), got.x1);
    try testing.expectEqual(@as(u32, 1), got.y1);
    try testing.expectEqual(@as(u32, 8), got.x2);
    try testing.expectEqual(@as(u32, 5), got.y2);
    try testing.expectEqual(true, got.rect);
}

test "extent: block with anchor.x > cursor.x ⇒ x1=min, x2=max" {
    const s = Sel{
        .anchor = .{ .x = 9, .y = 0 },
        .cursor = .{ .x = 3, .y = 4 },
        .mode = .block,
    };
    const got = s.extent(80).?;
    try testing.expectEqual(@as(u32, 3), got.x1); // min(9,3)=3
    try testing.expectEqual(@as(u32, 9), got.x2); // max(9,3)=9
    try testing.expectEqual(@as(u32, 0), got.y1); // min(0,4)=0
    try testing.expectEqual(@as(u32, 4), got.y2); // max(0,4)=4
    try testing.expectEqual(true, got.rect);
}

// ---- viewMode() --------------------------------------------------------------

test "viewMode: none → .none, linewise → .line, block → .block" {
    try testing.expectEqual(view.SelMode.none, (Sel{ .mode = .none }).viewMode());
    try testing.expectEqual(view.SelMode.line, (Sel{ .mode = .linewise }).viewMode());
    try testing.expectEqual(view.SelMode.block, (Sel{ .mode = .block }).viewMode());
}

// ---- applyAction: visual_toggle ---------------------------------------------

test "applyAction: .visual_toggle on INACTIVE Sel ⇒ begin linewise at cursor (anchor=cursor=cursor)" {
    var s: Sel = .{}; // inactive
    const cur: view.Pos = .{ .x = 5, .y = 6 };
    applyAction(&s, .visual_toggle, cur);
    try testing.expectEqual(Mode.linewise, s.mode);
    try testing.expectEqual(cur, s.anchor);
    try testing.expectEqual(cur, s.cursor);
    try testing.expect(s.active());
}

test "applyAction: .visual_toggle on ACTIVE linewise ⇒ RE-ANCHOR at cursor (begin linewise, discards prior)" {
    // PRD §7.4: `v` ALWAYS begins/re-anchors a linewise selection at the cursor, discarding any
    // prior selection. It does NOT toggle mode. This is the only way to move the starting line.
    var s = Sel{ .anchor = .{ .x = 1, .y = 2 }, .cursor = .{ .x = 3, .y = 4 }, .mode = .linewise };
    const cur: view.Pos = .{ .x = 9, .y = 9 };
    applyAction(&s, .visual_toggle, cur); // cursor arg IS the new anchor (re-anchor)
    try testing.expectEqual(Mode.linewise, s.mode); // still linewise (NOT toggled to block)
    try testing.expectEqual(cur, s.anchor); // re-anchored at cursor
    try testing.expectEqual(cur, s.cursor); // collapsed seed
}

test "applyAction: .visual_toggle on ACTIVE block ⇒ RE-ANCHOR at cursor (begin linewise, discards block)" {
    // `v` re-anchors at the cursor in LINEWISE mode even when the prior selection was block —
    // it discards the block mode + endpoints and restarts linewise (PRD §7.4: "re-enters linewise").
    var s = Sel{ .anchor = .{ .x = 1, .y = 2 }, .cursor = .{ .x = 3, .y = 4 }, .mode = .block };
    const cur: view.Pos = .{ .x = 5, .y = 6 };
    applyAction(&s, .visual_toggle, cur);
    try testing.expectEqual(Mode.linewise, s.mode); // linewise, NOT block
    try testing.expectEqual(cur, s.anchor);
    try testing.expectEqual(cur, s.cursor);
}

// ---- applyAction: visual_line ------------------------------------------------

test "applyAction: .visual_line on INACTIVE Sel ⇒ begin linewise at cursor" {
    var s: Sel = .{};
    const cur: view.Pos = .{ .x = 7, .y = 8 };
    applyAction(&s, .visual_line, cur);
    try testing.expectEqual(Mode.linewise, s.mode);
    try testing.expectEqual(cur, s.anchor);
    try testing.expectEqual(cur, s.cursor);
}

test "applyAction: .visual_line on ACTIVE block ⇒ RE-ANCHOR linewise at cursor (alias of v)" {
    // PRD §7.4: `V` is a linewise alias of `v` => re-anchors at the cursor, discarding prior.
    var s = Sel{ .anchor = .{ .x = 2, .y = 3 }, .cursor = .{ .x = 4, .y = 5 }, .mode = .block };
    const cur: view.Pos = .{ .x = 6, .y = 7 };
    applyAction(&s, .visual_line, cur);
    try testing.expectEqual(Mode.linewise, s.mode);
    try testing.expectEqual(cur, s.anchor);
    try testing.expectEqual(cur, s.cursor);
}

test "applyAction: .visual_line on ACTIVE linewise ⇒ RE-ANCHOR linewise at cursor" {
    // `V` re-anchors even when already linewise (alias of `v`, not a mode-stay).
    var s = Sel{ .anchor = .{ .x = 2, .y = 3 }, .cursor = .{ .x = 4, .y = 5 }, .mode = .linewise };
    const cur: view.Pos = .{ .x = 8, .y = 9 };
    applyAction(&s, .visual_line, cur);
    try testing.expectEqual(Mode.linewise, s.mode);
    try testing.expectEqual(cur, s.anchor);
    try testing.expectEqual(cur, s.cursor);
}

// ---- applyAction: visual_block -----------------------------------------------

test "applyAction: .visual_block on INACTIVE Sel ⇒ begin block at cursor" {
    var s: Sel = .{};
    const cur: view.Pos = .{ .x = 7, .y = 8 };
    applyAction(&s, .visual_block, cur);
    try testing.expectEqual(Mode.block, s.mode);
    try testing.expectEqual(cur, s.anchor);
    try testing.expectEqual(cur, s.cursor);
}

test "applyAction: .visual_block on ACTIVE linewise ⇒ TOGGLE to block (endpoints preserved)" {
    // PRD §7.4: `Ctrl-v` toggles linewise↔block when active; does NOT re-anchor.
    var s = Sel{ .anchor = .{ .x = 2, .y = 3 }, .cursor = .{ .x = 4, .y = 5 }, .mode = .linewise };
    applyAction(&s, .visual_block, .{ .x = 0, .y = 0 }); // cursor arg IGNORED when active
    try testing.expectEqual(Mode.block, s.mode);
    try testing.expectEqual(view.Pos{ .x = 2, .y = 3 }, s.anchor); // endpoints preserved
    try testing.expectEqual(view.Pos{ .x = 4, .y = 5 }, s.cursor);
}

test "applyAction: .visual_block on ACTIVE block ⇒ TOGGLE back to linewise (rectangle OFF)" {
    // PRD §7.4: "Pressing Ctrl-v again toggles back to linewise (rectangle OFF)".
    var s = Sel{ .anchor = .{ .x = 2, .y = 3 }, .cursor = .{ .x = 4, .y = 5 }, .mode = .block };
    applyAction(&s, .visual_block, .{ .x = 0, .y = 0 });
    try testing.expectEqual(Mode.linewise, s.mode); // toggled BACK to linewise
    try testing.expectEqual(view.Pos{ .x = 2, .y = 3 }, s.anchor);
    try testing.expectEqual(view.Pos{ .x = 4, .y = 5 }, s.cursor);
}

// ---- applyAction: swap_end / swap_end_other ----------------------------------

test "applyAction: .swap_end on ACTIVE Sel ⇒ swapEnds (anchor↔cursor)" {
    var s = Sel{ .anchor = .{ .x = 1, .y = 2 }, .cursor = .{ .x = 9, .y = 8 }, .mode = .linewise };
    applyAction(&s, .swap_end, .{ .x = 0, .y = 0 });
    try testing.expectEqual(view.Pos{ .x = 9, .y = 8 }, s.anchor);
    try testing.expectEqual(view.Pos{ .x = 1, .y = 2 }, s.cursor);
    try testing.expectEqual(Mode.linewise, s.mode);
}

test "applyAction: .swap_end_other on ACTIVE Sel ⇒ swapEnds (identical to .swap_end)" {
    var s = Sel{ .anchor = .{ .x = 1, .y = 2 }, .cursor = .{ .x = 9, .y = 8 }, .mode = .block };
    applyAction(&s, .swap_end_other, .{ .x = 0, .y = 0 });
    try testing.expectEqual(view.Pos{ .x = 9, .y = 8 }, s.anchor);
    try testing.expectEqual(view.Pos{ .x = 1, .y = 2 }, s.cursor);
    try testing.expectEqual(Mode.block, s.mode);
}

test "applyAction: .swap_end on INACTIVE Sel ⇒ NO-OP (endpoints unchanged)" {
    var s = Sel{ .anchor = .{ .x = 1, .y = 2 }, .cursor = .{ .x = 9, .y = 8 }, .mode = .none };
    applyAction(&s, .swap_end, .{ .x = 0, .y = 0 });
    try testing.expectEqual(Mode.none, s.mode);
    try testing.expectEqual(view.Pos{ .x = 1, .y = 2 }, s.anchor);
    try testing.expectEqual(view.Pos{ .x = 9, .y = 8 }, s.cursor);
}

test "applyAction: .swap_end_other on INACTIVE Sel ⇒ NO-OP (endpoints unchanged)" {
    var s = Sel{ .anchor = .{ .x = 1, .y = 2 }, .cursor = .{ .x = 9, .y = 8 }, .mode = .none };
    applyAction(&s, .swap_end_other, .{ .x = 0, .y = 0 });
    try testing.expectEqual(Mode.none, s.mode);
    try testing.expectEqual(view.Pos{ .x = 1, .y = 2 }, s.anchor);
    try testing.expectEqual(view.Pos{ .x = 9, .y = 8 }, s.cursor);
}

// ---- applyAction: clear / quit / confirm -------------------------------------

test "applyAction: .clear ⇒ mode .none (Sel becomes inactive)" {
    var s = Sel{ .anchor = .{ .x = 1, .y = 2 }, .cursor = .{ .x = 3, .y = 4 }, .mode = .linewise };
    applyAction(&s, .clear, .{ .x = 0, .y = 0 });
    try testing.expectEqual(Mode.none, s.mode);
    try testing.expect(!s.active());
    try testing.expectEqual(@as(?view.Selection, null), s.extent(80));
}

test "applyAction: .quit ⇒ NO-OP (Sel untouched — region.zig owns exit)" {
    var s = Sel{ .anchor = .{ .x = 1, .y = 2 }, .cursor = .{ .x = 3, .y = 4 }, .mode = .linewise };
    const before = s;
    applyAction(&s, .quit, .{ .x = 0, .y = 0 });
    try testing.expectEqual(before.mode, s.mode);
    try testing.expectEqual(before.anchor, s.anchor);
    try testing.expectEqual(before.cursor, s.cursor);
}

test "applyAction: .confirm ⇒ NO-OP (Sel untouched — region.zig owns the confirm-render flow)" {
    var s = Sel{ .anchor = .{ .x = 1, .y = 2 }, .cursor = .{ .x = 3, .y = 4 }, .mode = .block };
    const before = s;
    applyAction(&s, .confirm, .{ .x = 0, .y = 0 });
    try testing.expectEqual(before.mode, s.mode);
    try testing.expectEqual(before.anchor, s.anchor);
    try testing.expectEqual(before.cursor, s.cursor);
}

test "applyAction: .quit on INACTIVE Sel ⇒ NO-OP" {
    var s: Sel = .{};
    applyAction(&s, .quit, .{ .x = 0, .y = 0 });
    try testing.expectEqual(Mode.none, s.mode);
    try testing.expect(!s.active());
}

test "applyAction: .confirm on INACTIVE Sel ⇒ NO-OP" {
    var s: Sel = .{};
    applyAction(&s, .confirm, .{ .x = 0, .y = 0 });
    try testing.expectEqual(Mode.none, s.mode);
    try testing.expect(!s.active());
}

// ---- Mini integration: v(begin) → motion extends → o(swapEnds) → Esc(clear) ---
// Simulates the region.zig loop by setting sel.cursor directly (region.zig syncs it with
// motion.Cursor.pos). No motion import — just plain struct field writes.

test "integration: v(begin) → extend cursor → extent reflects range → o(swapEnds) → Esc(clear)" {
    var s: Sel = .{};
    const start: view.Pos = .{ .x = 3, .y = 2 };

    // (1) user presses v at the cursor → begin linewise at the cursor.
    applyAction(&s, .visual_toggle, start);
    try testing.expectEqual(Mode.linewise, s.mode);
    try testing.expectEqual(start, s.anchor);
    try testing.expectEqual(start, s.cursor);

    // (2) user moves the cursor down 3 rows — region.zig copies Cursor.pos → sel.cursor.
    s.cursor = .{ .x = 5, .y = 5 };
    // extent now covers rows 2..5, full width (cols=80 ⇒ x2=79), linewise.
    const e1 = s.extent(80).?;
    try testing.expectEqual(@as(u32, 0), e1.x1);
    try testing.expectEqual(@as(u32, 2), e1.y1);
    try testing.expectEqual(@as(u32, 79), e1.x2);
    try testing.expectEqual(@as(u32, 5), e1.y2);
    try testing.expectEqual(false, e1.rect);

    // (3) user presses o → swapEnds: anchor becomes (5,5), cursor becomes (3,2) (the former
    //     anchor). The visible extent is UNCHANGED (min/max normalization), but the DRIVEN end
    //     is now (3,2) — subsequent motion moves the top end.
    applyAction(&s, .swap_end, .{ .x = 0, .y = 0 });
    try testing.expectEqual(view.Pos{ .x = 5, .y = 5 }, s.anchor);
    try testing.expectEqual(view.Pos{ .x = 3, .y = 2 }, s.cursor);
    const e2 = s.extent(80).?;
    try testing.expectEqual(e1.y1, e2.y1); // same normalized extent
    try testing.expectEqual(e1.y2, e2.y2);

    // (4) user presses Esc → clear. Sel becomes inactive; extent ⇒ null.
    applyAction(&s, .clear, .{ .x = 0, .y = 0 });
    try testing.expect(!s.active());
    try testing.expectEqual(@as(?view.Selection, null), s.extent(80));
}

test "integration: v(begin linewise) → Ctrl-v(toggle to block) → extent becomes rect" {
    // PRD §7.4: `v` re-anchors linewise (never toggles); `Ctrl-v` toggles linewise↔block when active.
    var s: Sel = .{};
    const start: view.Pos = .{ .x = 2, .y = 1 };
    applyAction(&s, .visual_toggle, start); // v ⇒ begin linewise at start
    s.cursor = .{ .x = 8, .y = 5 }; // extend
    // linewise extent: full rows 1..5.
    const e1 = s.extent(80).?;
    try testing.expectEqual(false, e1.rect);
    try testing.expectEqual(@as(u32, 0), e1.x1);
    try testing.expectEqual(@as(u32, 79), e1.x2);

    // Ctrl-v ⇒ toggle to block. Endpoints PRESERVED (rectangle-toggle).
    applyAction(&s, .visual_block, .{ .x = 0, .y = 0 });
    try testing.expectEqual(Mode.block, s.mode);
    // block extent: rect, x=min(2,8)=2..max=8, y=min(1,5)=1..max=5.
    const e2 = s.extent(80).?;
    try testing.expectEqual(true, e2.rect);
    try testing.expectEqual(@as(u32, 2), e2.x1);
    try testing.expectEqual(@as(u32, 1), e2.y1);
    try testing.expectEqual(@as(u32, 8), e2.x2);
    try testing.expectEqual(@as(u32, 5), e2.y2);
}

test "integration: v(begin) → move → v(RE-ANCHOR on new line) → starting line moved" {
    // PRD §7.4: pressing `v` again RE-ANCHORS the selection at the cursor on the new line. This is
    // the headline copy-mode-parity fix ("the only way to change the starting line").
    var s: Sel = .{};
    applyAction(&s, .visual_toggle, .{ .x = 3, .y = 2 }); // v ⇒ anchor=cursor=(3,2), linewise
    s.cursor = .{ .x = 5, .y = 6 }; // move cursor down (anchor stays (3,2))
    try testing.expectEqual(view.Pos{ .x = 3, .y = 2 }, s.anchor);
    // extent rows 2..6.
    const e1 = s.extent(80).?;
    try testing.expectEqual(@as(u32, 2), e1.y1);
    try testing.expectEqual(@as(u32, 6), e1.y2);

    // `v` again at the new cursor position (5,6) ⇒ re-anchor there; prior selection discarded.
    applyAction(&s, .visual_toggle, .{ .x = 5, .y = 6 });
    try testing.expectEqual(view.Pos{ .x = 5, .y = 6 }, s.anchor); // re-anchored
    try testing.expectEqual(view.Pos{ .x = 5, .y = 6 }, s.cursor); // collapsed seed
    try testing.expectEqual(Mode.linewise, s.mode); // still linewise
}
