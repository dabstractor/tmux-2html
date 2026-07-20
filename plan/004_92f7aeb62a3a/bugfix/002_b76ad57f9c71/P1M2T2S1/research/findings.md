# Research findings — P1.M2.T2.S1 (wire `.mouse` arm into regionHandle + RegionCtx.mouse_anchor)

## 1. The task (Issue 1 wiring, PRD §7.6)

`regionHandle` (src/region.zig:244) is the SOLE `app.EventHandler` wired into `app.runEvents`
(region.zig:526 `app.EventHandler{ .ctx = &ctx, .handleFn = regionHandle }`). `app.Event` is
`union(enum) { key: u8, mouse: MouseEvent, seq: EscSeq, eof: void }` (app.zig:291). SGR mouse is
decoded into `.mouse` by app.zig, but `input.feed` returns `null` for `.mouse` (input.zig:
`.eof, .mouse => return null`), so `regionHandle` fell through to `return .none` and DROPPED every
mouse event. This task wires the `.mouse` arm so click/drag/wheel actually do something.

## 2. Consumed contracts (all VERIFIED on-disk — S1+S2 are merged)

- `fn mouseCell(sx, sy, scroll, grid_rows:u16, total_rows:u32, tty_cols:u16) view.Pos`
  (region.zig:127) — S1, merged. Pure 1-based-SGR→0-based-grid coordinate conversion.
- `fn applyMouse(cursor: *motion.Cursor, sel: *select.Sel, mouse_anchor: *?view.Pos, m: app.MouseEvent,
  grid_rows: u16, total_rows: u32, tty_cols: u16) void` (region.zig:166) — S2, ON DISK. The §7.6
  state machine (press/motion/release/wheel_up/wheel_down). 8 unit tests present (region.zig:1295+).
- `fn clampCursorIntoViewport(cursor, sel, total_rows:u32, grid_rows:u16) void` (region.zig:142) — S2.
- `fn repaint(ctx: *RegionCtx) !void` (region.zig:286) — existing; repaints grid + status line.
- `app.MouseEvent = struct { button, action, x, y, shift, alt, ctrl }` (app.zig:259);
  `MouseAction = enum { press, release, motion, wheel_up, wheel_down }` (app.zig:253).
- `view.Pos` (view.zig:50) — `{ x: u32, y: u32 }`; imported in region.zig (line 43).

## 3. Exact edit points (current line numbers, read from the on-disk file)

### RegionCtx struct (line 88) — add ONE field after `sel` (line 98)
Fields in order: `cursor: motion.Cursor,` (97), `sel: select.Sel,` (98), `mgrid: motion.Grid,` (99).
Add `mouse_anchor: ?view.Pos = null,` BETWEEN sel and mgrid. **Has a default (`= null`)** ⇒ the
existing `body()` RegionCtx struct literal (region.zig:407, DESIGNATED init) needs NO change —
precedent: RegionCtx already has 5 defaulted fields (decoder/search/pattern/searching/pattern_buf)
that the body() literal omits. Zig applies the default.

### regionHandle (line 244) — add the `.mouse` switch arm between the search-mode return and input.feed
Current body:
```zig
fn regionHandle(opaque_ctx: ?*anyopaque, ev: app.Event) app.Action {
    const ctx: *RegionCtx = @ptrCast(@alignCast(opaque_ctx.?));
    // ---- SEARCH MODE: collect pattern bytes directly (decoder idle) ----
    if (ctx.searching) return handleSearchByte(ctx, ev);          // line 248

    // ---- NORMAL MODE: feed the decoder ----                       // line 250
    if (input.feed(&ctx.decoder, ev)) |key| {                      // line 251
        ...
    }
    // input.feed returns null while accumulating (digit/g), on .eof/.mouse, ...   // line 277
    return .none;                                                  // line 276/278
}
```
Insert (per item contract, verbatim) AFTER line 248 and BEFORE the `// ---- NORMAL MODE` line:
```zig
    // ---- MOUSE (PRD §7.6): consume the decoded SGR event BEFORE the keyboard decoder ----
    switch (ev) {
        .mouse => |m| {
            applyMouse(&ctx.cursor, &ctx.sel, &ctx.mouse_anchor, m, ctx.grid_rows, ctx.total_rows, ctx.tty_cols);
            repaint(ctx) catch {};
            return .none;
        },
        else => {}, // key / seq / eof fall through to the keyboard decoder below
    }
```
- `app.Event` has exactly 4 variants (key/mouse/seq/eof) ⇒ `switch (ev) { .mouse => |m| …, else => {} }`
  is exhaustive (the `else` covers key/seq/eof). Compiles.
- `&ctx.mouse_anchor` is `*?view.Pos` ⇒ matches applyMouse's `mouse_anchor: *?view.Pos` param. ✓
- arg order: `(cursor, sel, mouse_anchor, m, grid_rows:u16, total_rows:u32, tty_cols:u16)` matches
  applyMouse's signature EXACTLY (S2's Gotcha 2: grid_rows before total_rows). ✓
- `repaint(ctx) catch {}` swallows write errors — matches the resilient-write stance already used
  in every other regionHandle arm (and the fn-level doc-comment).
- Search mode is entered FIRST (line 248) ⇒ mouse is naturally ignored while typing a search pattern
  (handleSearchByte returns .none for non-key events, region.zig:315). No change needed there.

### regionHandle doc-comment (lines 231-243) — remove the stale "Mouse is a NO-OP" note
Replace the NORMAL-MODE paragraph + the Mouse-NO-OP note with text stating mouse is wired (§7.6),
consumed before the keyboard decoder. Also update the trailing comment at line 277
("on .eof/.mouse" → "on .eof/.seq" since .mouse is now consumed above input.feed).

## 4. Why NO new unit test for the wiring

`regionHandle` needs a full `RegionCtx` whose `grid: *const Screen` (ghostty Screen) triggers the
cross-test process-global-state GOTCHA (render.zig:838) — it is NOT unit-testable in isolation. That
is PRECISELY why S1/S2 split mouseCell + applyMouse out as PURE fns (already unit-tested: 6 + 8
tests). The wiring is a 4-line branch whose correctness is covered by:
  (a) the S1 mouseCell + S2 applyMouse/clamp pure unit tests (the actual click/drag/wheel logic);
  (b) the upcoming P1.M2.T3.S1 pty integration harness (tests/region_mouse.sh — SGR click/drag/wheel).
The contract explicitly defers integration testing to P1.M2.T3.S1 and says only "verify build + the
shipped harnesses stay GREEN — the change is a NEW branch; the keyboard path is untouched."

## 5. Scope / no-conflict

- ONLY src/region.zig changes (3 edits: 1 field + 1 switch arm + doc-comment). Do NOT touch
  input.zig/motion.zig/select.zig/view.zig/app.zig (all consumed, none modified).
- Disjoint from S2 (P1.M2.T1.S2): S2 added applyMouse/clampCursorIntoViewport (142-210) + 8 tests
  (1295+). This task edits RegionCtx field (98), regionHandle arm (248-251), doc-comment (231-243/277)
  — no overlap.
- Consumed downstream by P1.M2.T3.S1 (tests/region_mouse.sh pty harness).

## 6. Build/test gate (verified)

- `zig build test --release=fast` is GREEN on the current (pre-edit) tree (exit 0). `--release=fast`
  is mandatory (Debug hits R_X86_64_PC64); it is equivalent to the contract's `-Doptimize=ReleaseFast`.
- Shipped harnesses (PRD §0-safe, isolated sockets): tests/envelope_smoke.sh, plugin_options.sh,
  region_empty_confirm.sh, region_signal_keys.sh, zero_dimension_reject.sh. (The contract said "4";
  there are now 5 — region_signal_keys.sh landed with P1.M1.T2.S1. Reference "all tests/*.sh".)
- After the edit: build + tests stay green (NEW branch, keyboard path untouched); harnesses unaffected
  (none drive mouse — that is P1.M2.T3.S1's job).