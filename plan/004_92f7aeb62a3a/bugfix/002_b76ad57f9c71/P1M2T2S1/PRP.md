# PRP — P1.M2.T2.S1: `RegionCtx.mouse_anchor` + `.mouse` arm in `regionHandle` + doc-comment

## Goal

**Feature Goal**: Wire the **`.mouse` arm into `regionHandle`** (Issue 1 / PRD §7.6) so the region TUI
actually responds to SGR mouse input — click moves the cursor, drag selects (linewise, block with Alt),
wheel scrolls — instead of silently discarding every decoded `app.MouseEvent`. The pure building blocks
already exist and are unit-tested (S1 `mouseCell`, S2 `applyMouse`/`clampCursorIntoViewport`); this task
is the **4-line wiring branch** + a new `RegionCtx.mouse_anchor` field that connects them to the live
event loop, plus a doc-comment update removing the stale "Mouse is a NO-OP" note. No logic is invented
here — only connected.

**Deliverable** (ONE file changed: `/home/dustin/projects/tmux-2html/src/region.zig`):
- **ADD** `mouse_anchor: ?view.Pos = null,` to `RegionCtx` (after `sel`, line 98) — the drag anchor
  `applyMouse` reads/writes.
- **ADD** a `switch (ev) { .mouse => |m| { applyMouse(...); repaint(ctx) catch {}; return .none; },
  else => {} }` arm in `regionHandle` — placed AFTER the search-mode early-return and BEFORE the
  `input.feed` keyboard decoder, so mouse is consumed first and never reaches `input.feed`.
- **REWRITE** `regionHandle`'s doc-comment: remove the "Mouse is a NO-OP / follow-up" note and the stale
  "feed returns null … on .mouse" framing; state mouse is wired (§7.6) and consumed before the decoder.
- **No new files. No new unit test** (the click/drag/wheel logic is already covered by S1/S2's pure
  tests; the pty integration harness is P1.M2.T3.S1). `input.zig`/`motion.zig`/`select.zig`/`view.zig`/
  `app.zig` UNCHANGED.

**Success Definition** (VERIFIED against the on-disk `src/region.zig` + Zig 0.15.2):
- `zig build test --release=fast` → exit 0 (all ~275 fns green; the new branch compiles and the
  keyboard path is untouched).
- All shipped harnesses (`tests/*.sh`) stay GREEN.
- `regionHandle` now consumes `.mouse` (applyMouse + repaint + `.none`) instead of dropping it; the
  decoded SGR stream drives cursor/selection/scroll via the S1/S2 primitives.
- End-to-end (manual, or via P1.M2.T3.S1's pty harness): an SGR click at a cell moves the cursor
  (status-line `row:/col:` changes); a drag selects; the wheel scrolls.

> **`--release=fast` is MANDATORY** for build/test (Debug linking hits the ghostty `R_X86_64_PC64`
> linker bug — same as every render/region-touching task). Equivalent to the contract's
> `-Doptimize=ReleaseFast`.

## User Persona

**Target User**: End users of the region overlay (`tmux-2html region`, opened via the plugin's
`prefix C-o` / `@tmux-2html-region-key`). Today the TUI *enables* SGR mouse reporting on entry and the
cursor visibly enters mouse mode, yet click/drag/wheel do nothing — more confusing than if mouse were
disabled. After this task it behaves like tmux copy-mode-mouse.

**Use Case**: In the region overlay a user left-clicks to jump the cursor, drags to select a range
(hold Alt for a block), and scrolls the wheel to move the viewport — then `Enter` renders the selection.

**Pain Points Addressed**: Closes the §7.6 promise (mouse is listed SUPPORTED, not in §16 out-of-scope);
removes the silent-no-op surprise. The fix is layered — S1/S2 already proved the click/drag/wheel
semantics deterministically; this task just turns the key.

## Why

- **Closes Issue 1 (PRD §7.6), the only remaining Major gap.** Round-2 testing found mouse is decoded
  by `app.zig` but discarded by `regionHandle`; the S1/S2 split isolated the pure logic (unit-tested),
  and THIS task is the final connective tissue.
- **Zero new logic ⇒ zero new risk.** The 4-line branch calls already-tested pure fns
  (`applyMouse`/`mouseCell`/`clampCursorIntoViewport`) and the existing `repaint`. The keyboard path
  (`input.feed` → `motion`/`select`/`search`) is structurally untouched — mouse is consumed in a
  separate `switch` arm placed *before* it.
- **Search-mode isolation is preserved.** `if (ctx.searching) return handleSearchByte(...)` runs FIRST,
  so mouse is naturally ignored while typing a search pattern (no change needed there).

## What

### The wiring (verbatim from the item contract)

**(a) `RegionCtx` field** — insert after `sel: select.Sel,` (line 98), before `mgrid`:
```zig
    mouse_anchor: ?view.Pos = null,
```

**(b) `regionHandle` `.mouse` arm** — insert after `if (ctx.searching) return handleSearchByte(ctx, ev);`
(line 248) and before the `// ---- NORMAL MODE: feed the decoder ----` / `input.feed` block (line 250-251):
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

**(c) doc-comment** — replace the NORMAL-MODE paragraph + the Mouse-NO-OP note (lines ~231-243) and the
trailing `.mouse`-in-feed comment (line ~277). See Edit 3 in the Blueprint for the verbatim replacement.

### Success Criteria

- [ ] `mouse_anchor: ?view.Pos = null,` present on `RegionCtx` (after `sel`); `body()` struct literal
      UNCHANGED (default applies — designated init omits defaulted fields).
- [ ] `regionHandle` has the `.mouse` switch arm consuming `applyMouse` + `repaint` + `return .none`,
      placed AFTER the search-mode return and BEFORE `input.feed`.
- [ ] `regionHandle` doc-comment no longer says "Mouse is a NO-OP"; states mouse is wired (§7.6),
      consumed before the decoder.
- [ ] `zig build test --release=fast` → exit 0 (new branch compiles; keyboard path untouched).
- [ ] All `tests/*.sh` harnesses GREEN.
- [ ] ONLY `src/region.zig` changed; `input.zig`/`motion.zig`/`select.zig`/`view.zig`/`app.zig` untouched.

## All Needed Context

### Context Completeness Check

_Pass: "If someone knew nothing about this codebase, would they have everything needed to implement this
successfully?"_ — Yes. The three exact edits (field line 98, switch arm between 248 and 251, doc-comment
231-243 + 277) with verbatim text are specified below; every consumed signature
(`applyMouse(cursor,sel,mouse_anchor,m,grid_rows,total_rows,tty_cols)`, `repaint(ctx)!void`,
`app.Event` 4-variant union, `view.Pos`) is verified on-disk in `research/findings.md`; the
`app.Event` switch exhaustiveness (4 variants: key/mouse/seq/eof), the arg-order match to `applyMouse`
(S2's pinned `(grid_rows, total_rows, tty_cols)` order), the designated-init safety of adding a defaulted
field, the search-mode-first ordering, and the "no new unit test" rationale (regionHandle needs a ghostty
`Screen` → cross-test GOTCHA) are all documented. The implementer is making 3 surgical edits to one file.

### Documentation & References

```yaml
# MUST READ — the authoritative edit points + consumed signatures + no-test rationale (line citations)
- file: plan/004_92f7aeb62a3a/bugfix/002_b76ad57f9c71/P1M2T2S1/research/findings.md
  why: "§2 consumed contracts (mouseCell:127, applyMouse:166, clampCursorIntoViewport:142, repaint:286,
        app.Event union); §3 the exact 3 edit points with current line numbers + verbatim text; §4 why NO
        new unit test (regionHandle needs a ghostty Screen → cross-test GOTCHA; logic is S1/S2-tested +
        P1.M2.T3.S1 pty harness); §5 scope/no-conflict; §6 build gate (--release=fast ≡ -Doptimize=ReleaseFast)."
  critical: "app.Event has exactly 4 variants (key/mouse/seq/eof) => `switch (ev){ .mouse=>..., else=>{} }`
             is exhaustive. applyMouse arg order is (cursor,sel,mouse_anchor,m,grid_rows:u16,total_rows:u32,
             tty_cols:u16) — grid_rows BEFORE total_rows (S2 Gotcha 2). `&ctx.mouse_anchor` is *?view.Pos,
             matching the param. mouse is consumed BEFORE input.feed so feed's `.mouse=>null` is never hit."

# MUST READ — the S2 contract (applyMouse/clampCursorIntoViewport — already on disk, merged)
- file: plan/004_92f7aeb62a3a/bugfix/002_b76ad57f9c71/P1M2T1S2/PRP.md
  why: "S2 is ON DISK: applyMouse(166) + clampCursorIntoViewport(142) + 8 tests(1295+). This task CALLS
        applyMouse; do NOT re-implement or touch it. S2's Gotcha 2 (param order) is the load-bearing detail."

# MUST READ — the S1 contract (mouseCell — merged)
- file: plan/004_92f7aeb62a3a/bugfix/002_b76ad57f9c71/P1M2T1S1/PRP.md
  why: "mouseCell(127) is the pure SGR→grid coordinate primitive applyMouse calls internally. Do NOT touch it."

# MUST READ — the design this realizes (Issue 1 / §7.6 wiring)
- file: plan/004_92f7aeb62a3a/bugfix/002_b76ad57f9c71/architecture/mouse_wiring_design.md
  why: "The authoritative wiring design: the .mouse arm + RegionCtx.mouse_anchor are THIS task; applyMouse/
        clampCursorIntoViewport were S2. Confirms the consume-before-decoder placement and that search mode
        naturally ignores mouse."

# MUST READ — the file being edited + the consumed app types
- file: src/region.zig
  section: "RegionCtx(88: sel at 98, mgrid at 99); mouseCell(127); applyMouse(166) clampCursorIntoViewport(142);
            regionHandle(244) + its doc-comment(231-243) + trailing comment(277); the search-mode return(248);
            input.feed(251); repaint(286); body() RegionCtx literal(407, designated); EventHandler wiring(526)."
  why: "Confirms the exact insertion points, that region.zig already imports `view` (for view.Pos), and that
        body()'s literal is designated (so a defaulted new field needs no literal change)."
- file: src/tui/app.zig
  section: "Event(291) = union(enum){key:u8, mouse:MouseEvent, seq:EscSeq, eof:void}; MouseEvent(259);
            MouseAction(253); MouseButton(252)."
  why: "Confirms the switch is exhaustive with `else => {}` and that `.mouse => |m|` captures MouseEvent."

# PRD context (this is the §7.6 fix)
- file: PRD.md  # (bugfix PRD round-2, Major Issue 1)
  section: "Major Issue 1 (Mouse §7.6 non-functional) + §7.6 ('Click to move cursor; drag to select
            [linewise default, block with Alt]; wheel to scroll')"
  why: "Confirms the exact semantics the wired applyMouse implements and that mouse is SUPPORTED (not §16)."
```

### Current Codebase tree (this task's starting point — S1+S2 merged)

```bash
tmux-2html/
├── src/
│   ├── region.zig         # 1295+ lines; mouseCell(127) applyMouse(166) clamp(142)+tests; regionHandle(244)  ← EDIT (3 edits)
│   ├── tui/app.zig        # Event/MouseEvent/MouseAction (consumed)                                  ← DO NOT TOUCH
│   ├── tui/input.zig      # .eof/.mouse => null (the reason mouse was dropped)                      ← DO NOT TOUCH
│   ├── tui/motion.zig  select.zig  view.zig                                                          ← DO NOT TOUCH
│   └── …
├── tests/*.sh             # 5 shipped harnesses (region_signal_keys.sh from P1.M1.T2.S1)             ← DO NOT TOUCH
├── build.zig  build.zig.zon                                                                           ← DO NOT TOUCH
```

### Desired Codebase tree with files to be changed

```bash
tmux-2html/
└── src/
    └── region.zig        # +RegionCtx.mouse_anchor field + .mouse switch arm in regionHandle + doc-comment
```

### Known Gotchas of our codebase & Library Quirks

```zig
// GOTCHA 1 — app.Event is a 4-variant union (key/mouse/seq/eof). `switch (ev) { .mouse => |m| …,
//   else => {} }` is EXHAUSTIVE (else covers key/seq/eof). Do NOT list the other variants explicitly
//   (they must fall through to input.feed); use `else => {}` so the switch is a pure pre-filter.

// GOTCHA 2 — applyMouse's arg order is PINNED (S2 Gotcha 2): (cursor, sel, mouse_anchor, m,
//   grid_rows: u16, total_rows: u32, tty_cols: u16) — grid_rows BEFORE total_rows. Call it as
//   applyMouse(&ctx.cursor, &ctx.sel, &ctx.mouse_anchor, m, ctx.grid_rows, ctx.total_rows, ctx.tty_cols).
//   A swap compiles (both u16/u32 mismatches are caught by the type system EXCEPT grid_rows/tty_cols
//   which are both u16) — so double-check the ORDER against the signature at region.zig:166.

// GOTCHA 3 — PLACE the arm AFTER `if (ctx.searching) return handleSearchByte(ctx, ev);` and BEFORE
//   `if (input.feed(...))`. Ordering matters: (a) search mode must run first so mouse is ignored while
//   typing a pattern (handleSearchByte returns .none for non-key events); (b) mouse must run before
//   input.feed so the decoded .mouse is consumed (input.feed returns null on .mouse — placing the arm
//   AFTER input.feed would still drop it).

// GOTCHA 4 — `mouse_anchor: ?view.Pos = null` has a DEFAULT, so the body() RegionCtx literal (line 407,
//   designated init) needs NO edit. RegionCtx already has 5 defaulted fields (decoder/search/pattern/
//   searching/pattern_buf) the literal omits; this one is identical in kind. Do NOT add mouse_anchor to
//   the body() literal (it would still compile, but it's unnecessary and would imply it's non-default).

// GOTCHA 5 — `repaint(ctx) catch {}` (swallow). repaint is `!void`; a transient write error must not
//   crash the TUI. This matches EVERY other arm in regionHandle and the fn-level doc-comment's stated
//   "resilient-write stance". Do NOT `try repaint(ctx)`.

// GOTCHA 6 — NO new unit test for the wiring. regionHandle needs a full RegionCtx whose `grid:
//   *const Screen` (ghostty Screen) trips the cross-test process-global-state GOTCHA (render.zig:838) —
//   it is not unit-testable in isolation. That is WHY S1/S2 split mouseCell + applyMouse out as PURE fns
//   (6 + 8 tests already cover the actual click/drag/wheel logic). The pty integration proof is
//   P1.M2.T3.S1 (tests/region_mouse.sh). This task's gate is "build + shipped harnesses stay GREEN".

// GOTCHA 7 — build/test MUST use --release=fast: Debug linking hits the ghostty R_X86_64_PC64 linker
//   bug. `zig build test` (no release flag) FAILS. (--release=fast ≡ -Doptimize=ReleaseFast.)

// GOTCHA 8 — SCOPE: only the 3 edits to region.zig. Do NOT modify input.zig (its `.mouse => return null`
//   is now dead for the region path but correct in shape and consumed nowhere else problematically —
//   leave it), motion.zig, select.zig, view.zig, or app.zig. Do NOT touch S1/S2's mouseCell/applyMouse/
//   clampCursorIntoViewport or their tests (1295+).
```

## Implementation Blueprint

### Data models and structure

No new types. `mouse_anchor: ?view.Pos` reuses `view.Pos` (`{ x: u32, y: u32 }`, already imported). It is
the drag anchor `applyMouse` reads (on `.motion`) and clears (on `.release`); `null` means "no press in
progress" (click-vs-drag discrimination). Default `null`.

### The exact deliverable: `src/region.zig` (3 EDITS)

**Edit 1 — `RegionCtx.mouse_anchor` field.** In the `RegionCtx` struct, after `sel: select.Sel,`
(line 98) and before `mgrid: motion.Grid,` (line 99), add one line:

```zig
    cursor: motion.Cursor,
    sel: select.Sel,
    mouse_anchor: ?view.Pos = null, // PRD §7.6: drag anchor (set on press, cleared on release); null = no drag
    mgrid: motion.Grid,
```

**Edit 2 — `regionHandle` `.mouse` arm.** Insert between the search-mode return (line 248) and the
`// ---- NORMAL MODE` comment (line 250):

Before (current):
```zig
    // ---- SEARCH MODE: collect pattern bytes directly (decoder idle) ----
    if (ctx.searching) return handleSearchByte(ctx, ev);

    // ---- NORMAL MODE: feed the decoder ----
    if (input.feed(&ctx.decoder, ev)) |key| {
```
After (new arm inserted):
```zig
    // ---- SEARCH MODE: collect pattern bytes directly (decoder idle) ----
    if (ctx.searching) return handleSearchByte(ctx, ev);

    // ---- MOUSE (PRD §7.6): consume the decoded SGR event BEFORE the keyboard decoder ----
    // click moves cursor; drag selects (linewise default, block with Alt); wheel scrolls.
    switch (ev) {
        .mouse => |m| {
            applyMouse(&ctx.cursor, &ctx.sel, &ctx.mouse_anchor, m, ctx.grid_rows, ctx.total_rows, ctx.tty_cols);
            repaint(ctx) catch {};
            return .none;
        },
        else => {}, // key / seq / eof fall through to the keyboard decoder below
    }

    // ---- NORMAL MODE: feed the decoder ----
    if (input.feed(&ctx.decoder, ev)) |key| {
```

Also update the trailing comment after the `input.feed` block (line ~277):
Before: `// input.feed returns null while accumulating (digit/g), on .eof/.mouse, or on an ignored byte.`
After:  `// input.feed returns null while accumulating (digit/g), on .eof/.seq, or on an ignored byte (.mouse is consumed above).`

**Edit 3 — `regionHandle` doc-comment.** Replace the NORMAL-MODE paragraph + Mouse-NO-OP note (lines
~231-243). Current:
```zig
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
```
Replace with:
```zig
/// MOUSE (PRD §7.6): a `.mouse` event is consumed FIRST — before the keyboard
/// decoder — via applyMouse (the click/drag/wheel state machine: click moves the
/// cursor, drag selects [linewise by default, block with Alt], wheel scrolls),
/// then repaint + return .none. (Mouse is ignored in SEARCH MODE — handleSearchByte
/// returns .none for non-key events.)
///
/// NORMAL MODE (keyboard): feed the decoder. On a decoded Key: motion =>
/// applyMotion + sync sel.cursor + repaint; action => quit/confirm/clear-or-quit/
/// else select.applyAction; search => handleSearchAction. feed returns null while
/// accumulating (digit/g), on .eof/.seq, or on an ignored byte (.mouse never
/// reaches feed — it is consumed above).
///
/// Esc clear-vs-quit is REGION's decision (NOT input's/select's): on .clear, if
/// sel.active() => clear + repaint (stay in TUI); else => .quit (PRD 7.4/7.5).
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: ADD RegionCtx.mouse_anchor field (src/region.zig, after line 98)
  - ADD `mouse_anchor: ?view.Pos = null,` (with the trailing comment) between `sel` and `mgrid`.
  - GOTCHA 4: default `= null` => body() literal (line 407, designated) needs NO change.
  - NAMING: mouse_anchor (matches applyMouse's param name + the item contract).

Task 2: ADD the .mouse switch arm in regionHandle (src/region.zig, between lines 248 and 250)
  - ADD the `switch (ev) { .mouse => |m| { applyMouse(...); repaint(ctx) catch {}; return .none; },
            else => {} }` block verbatim (Edit 2).
  - GOTCHA 1: `else => {}` makes the switch exhaustive (app.Event is key/mouse/seq/eof).
  - GOTCHA 2: applyMouse arg order (cursor,sel,mouse_anchor,m,grid_rows,total_rows,tty_cols).
  - GOTCHA 3: place AFTER the search-mode return, BEFORE input.feed.
  - GOTCHA 5: `repaint(ctx) catch {}` (swallow — resilient-write stance).
  - ALSO update the trailing comment (line ~277): drop ".mouse" (now consumed above).

Task 3: REWRITE regionHandle's doc-comment (src/region.zig, lines ~231-243)
  - REPLACE the NORMAL-MODE paragraph + Mouse-NO-OP note with the §7.6-wired text (Edit 3).
  - REMOVE "Mouse is a NO-OP in S1 …" and the stale "feed returns null … on .eof/.mouse" framing.

Task 4: VALIDATE (see Validation Loop)
  - RUN: zig build test --release=fast     # exit 0 (new branch compiles; keyboard path untouched)
  - RUN: all tests/*.sh harnesses           # GREEN (none drive mouse; that is P1.M2.T3.S1)
  - RUN (optional, manual): the Issue 1 pty repro (Level 3) — SGR click moves the cursor
```

### Implementation Patterns & Key Details

```zig
// PATTERN: consume mouse in a dedicated switch arm BEFORE the keyboard decoder. app.Event is a 4-variant
//   union; `else => {}` lets key/seq/eof fall through unchanged. applyMouse (S2) owns ALL the
//   click/drag/wheel state-machine logic; regionHandle only routes + repaints.
switch (ev) {
    .mouse => |m| {
        applyMouse(&ctx.cursor, &ctx.sel, &ctx.mouse_anchor, m, ctx.grid_rows, ctx.total_rows, ctx.tty_cols);
        repaint(ctx) catch {}; // resilient-write: a transient error must not crash the TUI
        return .none;          // mouse never produces .quit/.confirm
    },
    else => {}, // key / seq / eof => keyboard decoder (input.feed) below
}

// PATTERN: a defaulted RegionCtx field needs no body() literal edit. RegionCtx already omits 5 defaulted
//   fields (decoder/search/pattern/searching/pattern_buf) in its designated body() literal (line 407);
//   mouse_anchor:?view.Pos = null is identical in kind.
mouse_anchor: ?view.Pos = null,
```

### Integration Points

```yaml
BUILD GRAPH:
  - consumes (unchanged): build.zig, build.zig.zon, all src/*.zig. region.zig already imports std/app/
    view/motion/select. S1 mouseCell(127) + S2 applyMouse(166)/clampCursorIntoViewport(142) are on disk.
  - produces: src/region.zig with the wired .mouse arm + RegionCtx.mouse_anchor + updated doc-comment.
  - next (P1.M2.T3.S1): tests/region_mouse.sh — the python3 pty harness asserting SGR click moves the
    cursor (status-line row:/col: changes), drag→confirm→file, and wheel scroll. NOT this task.

TUI/RENDER CONTRACT (DO NOT CHANGE):
  - applyMouse/mouseCell/clampCursorIntoViewport (S1/S2) are the verified inverse of view.render's
    screen→grid mapping. This task only routes the decoded MouseEvent into them; it re-derives nothing.
  - Search mode (`if (ctx.searching) return handleSearchByte(...)`) runs BEFORE the mouse arm, so mouse is
    naturally ignored while typing a search pattern (no special-casing needed — handleSearchByte returns
    .none for non-key events, region.zig:315).
```

## Validation Loop

> Re-run verbatim. EVERY build/test command MUST include `--release=fast` (Gotcha 7).

### Level 1: Syntax & Style (Immediate Feedback)

```bash
zig version            # MUST print: 0.15.2
zig build --fetch      # exit 0 (deps cached)
```

### Level 2: Build + unit tests (PRIMARY gate — the new branch compiles; keyboard path untouched)

```bash
# Whole suite (~275 fns incl. S1's 6 mouseCell + S2's 8 applyMouse tests + ~20 region pure helpers).
zig build test --release=fast          # expect: all passed, exit 0

# All shipped harnesses stay GREEN (none drive mouse; mouse proof is P1.M2.T3.S1):
for t in tests/*.sh; do sh "$t" >/dev/null 2>&1 && echo "PASS $t" || echo "FAIL $t"; done

# Diagnostics:
#   "unhandled relocation type R_X86_64_PC64" -> forgot --release=fast (Gotcha 7).
#   "expected ... found ..." / type error on the applyMouse call -> arg-order mismatch (Gotcha 2):
#     re-check (cursor,sel,mouse_anchor,m,grid_rows,total_rows,tty_cols) vs applyMouse's signature (166).
#   "switch must be exhaustive" -> listed variants explicitly instead of `else => {}` (Gotcha 1).
#   "mouse_anchor" not found / cannot take address -> the field wasn't added to RegionCtx (Task 1 missed).
```

### Level 3: Integration — the actual bug repro (proves the wiring end-to-end; also P1.M2.T3.S1's job)

> This is a manual pty drive now; the automated version lands in P1.M2.T3.S1 (tests/region_mouse.sh).
> Run against an ISOLATED tmux server (PRD §0 — never the user's live session; teardown by named socket only).

```bash
zig build --release=fast               # expect: exit 0; zig-out/bin/tmux-2html produced
SOCK="t2h-mouse-$$"; tmux -L "$SOCK" new-session -d -s s -x 25 -y 6
PANE=$(tmux -L "$SOCK" list-panes -t s -F '#{pane_id}' | head -1)
tmux -L "$SOCK" send-keys -t s "printf 'LNE0XY content\n'" Enter; sleep 0.4
TMUX="/tmp/tmux-$UID/$SOCK,0,0" PANE="$PANE" python3 - <<'PY'
# pty-fork ./zig-out/bin/tmux-2html region --target $PANE
# drain ~0.7s; snapshot the status line's row:/col: (BEFORE)
# write b"\x1b[<0;15;2M" (SGR left-press col=15,row=2); drain ~0.3s; snapshot status line (AFTER)
# ASSERT: AFTER row:/col: DIFFER from BEFORE (cursor moved). (Pre-fix: identical => mouse IGNORED.)
# Optional: drag (\x1b[<0;2;1M press .. \x1b[<32;15;3M motion .. \x1b[<0;15;3m release) then Enter
#           => an HTML file is written (selection began/extended); wheel (\x1b[<64;1;1M) scrolls.
PY
tmux -L "$SOCK" kill-session -t s   # scoped teardown — MY named socket only (PRD §0)
```

### Level 4: Scope boundary (Domain Validation)

```bash
# ONLY src/region.zig changed; build files + other src files untouched.
git diff --stat | grep -v 'src/region.zig' && echo "UNEXPECTED other changes" || echo "scope OK"
# The 3 edits landed:
grep -n 'mouse_anchor: ?view.Pos' src/region.zig          # expect: 1 hit (RegionCtx field)
grep -n '\.mouse =>' src/region.zig                         # expect: 1 hit (the new switch arm)
grep -n 'Mouse is a NO-OP' src/region.zig || echo "stale note removed: OK"   # expect: removed
# input.zig/motion.zig/select.zig/view.zig/app.zig UNCHANGED:
git diff --stat src/tui/input.zig src/tui/motion.zig src/tui/select.zig src/tui/view.zig src/tui/app.zig  # expect: no output
```

## Final Validation Checklist

### Technical Validation

- [ ] `zig version` prints `0.15.2`; `zig build --fetch` exits 0.
- [ ] `zig build test --release=fast` exits 0 (whole suite; new branch compiles; keyboard path untouched).
- [ ] All `tests/*.sh` harnesses PASS.

### Feature Validation

- [ ] `RegionCtx.mouse_anchor: ?view.Pos = null` present (after `sel`); `body()` literal unchanged.
- [ ] `regionHandle` consumes `.mouse` via `applyMouse` + `repaint(ctx) catch {}` + `return .none`, placed
      after the search-mode return and before `input.feed`.
- [ ] `regionHandle` doc-comment states mouse is wired (§7.6); the "Mouse is a NO-OP" note is gone.
- [ ] (Manual/L3, or P1.M2.T3.S1) SGR click moves the cursor (status-line `row:/col:` changes); drag
      selects; wheel scrolls.

### Code Quality Validation

- [ ] The `.mouse` switch uses `else => {}` (exhaustive over app.Event's 4 variants; Gotcha 1).
- [ ] `applyMouse` call arg order matches its signature (Gotcha 2); `repaint` errors swallowed (Gotcha 5).
- [ ] The arm is ordered AFTER search-mode and BEFORE `input.feed` (Gotcha 3).
- [ ] ONLY `src/region.zig` changed; `input.zig`/`motion.zig`/`select.zig`/`view.zig`/`app.zig` untouched.

### Documentation & Deployment

- [ ] `regionHandle` doc-comment updated (Mode A): §7.6 mouse arm documented; stale follow-up note removed.
- [ ] No README/CONFIGURATION.md change here (that is the final P1.M3 docs task).

---

## Anti-Patterns to Avoid

- ❌ Don't place the `.mouse` arm AFTER `input.feed` — `input.feed` returns `null` on `.mouse`, so the event
  would still be dropped. Consume mouse BEFORE the decoder (Gotcha 3). And don't place it BEFORE the
  search-mode return — search mode must win so mouse is ignored while typing a pattern.
- ❌ Don't swap `applyMouse`'s `grid_rows`/`total_rows` args — they're `(grid_rows:u16, total_rows:u32,
  tty_cols:u16)` (S2 Gotcha 2). grid_rows/tty_cols are both u16 so a swap there compiles silently; double-
  check against the signature at region.zig:166.
- ❌ Don't list app.Event's variants explicitly in the switch (`.key`, `.seq`, `.eof`) — use `else => {}` so
  the arm is a pure pre-filter and the keyboard path stays literally unchanged (Gotcha 1).
- ❌ Don't `try repaint(ctx)` — swallow with `catch {}`; a transient write error must not crash the TUI
  (matches every other arm + the fn doc-comment's resilient-write stance; Gotcha 5).
- ❌ Don't add a unit test for the wiring — `regionHandle` needs a ghostty `Screen` (RegionCtx.grid) which
  trips the cross-test process-global-state GOTCHA. The click/drag/wheel LOGIC is already covered by S1/S2's
  pure tests; the pty proof is P1.M2.T3.S1 (Gotcha 6). This task's gate is build + shipped harnesses green.
- ❌ Don't add `mouse_anchor` to the `body()` RegionCtx literal — it has a default (`= null`); the designated
  literal already omits 5 other defaulted fields (Gotcha 4).
- ❌ Don't modify `input.zig` (its `.eof/.mouse => return null` is now unreachable on the region path but is
  correct in shape and shared) or `motion.zig`/`select.zig`/`view.zig`/`app.zig`. Don't touch S1/S2's
  `mouseCell`/`applyMouse`/`clampCursorIntoViewport` or their tests (Gotcha 8).
- ❌ Don't leave the stale "Mouse is a NO-OP" / "feed returns null … on .eof/.mouse" doc-comment text —
  update it (Task 3); the contract explicitly requires removing the stale framing.
- ❌ Don't build/test WITHOUT `--release=fast` — Debug linking hits `R_X86_64_PC64` (Gotcha 7).

---

**Confidence Score: 9/10** for one-pass implementation success.

The fix is a verified, surgical 3-edit change to one file: one defaulted struct field (`mouse_anchor:
?view.Pos = null`), one 4-line `switch` arm, and a doc-comment rewrite. Every consumed signature
(`applyMouse` at region.zig:166, `repaint(ctx)!void` at 286, `app.Event`'s 4-variant union at app.zig:291,
`view.Pos`) is verified on-disk, and the exact call (`applyMouse(&ctx.cursor, &ctx.sel, &ctx.mouse_anchor,
m, ctx.grid_rows, ctx.total_rows, ctx.tty_cols)`) matches applyMouse's pinned arg order. S1/S2 (mouseCell +
applyMouse + clampCursorIntoViewport + 14 tests) are already merged and green, so the click/drag/wheel
*logic* is already proven — this task only connects it to the live event loop. The new branch is disjoint
from the keyboard path (a separate `switch` placed before `input.feed`), so it cannot regress existing
behavior; the build is green pre-edit and must stay green post-edit. The arg-order detail (Gotcha 2:
grid_rows before total_rows, both-u16 silent-swap risk) and the placement (Gotcha 3: after search-mode,
before input.feed) are the two things to get exactly right on first pass, both called out with diagnostics.
The only residual risk is that the end-to-end pty proof is deferred to P1.M2.T3.S1 (regionHandle is not
unit-testable in isolation due to the ghostty Screen cross-test GOTCHA) — mitigated by the L3 manual repro
and by the S1/S2 pure tests already locking down the semantics this arm invokes.