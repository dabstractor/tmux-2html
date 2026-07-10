# Region TUI — Shipped Key-Binding & Behavior Fact Sheet

Source of truth: the code under `/home/dustin/projects/tmux-2html/src`. PRD §7
(`PRD.md:259-306`) is the *intended* design; where the shipped code differs, the
code wins and the deviation is flagged. This sheet drives the region section of
docs/CONFIGURATION.md.

Layering:
- `tui/input.zig` **decodes** raw bytes/ESC-sequences → a normalized `Key`.
- `tui/motion.zig` **applies** a decoded motion to a `Cursor` over a `Grid`.
- `tui/select.zig` is the **pure selection model** (anchor/cursor/mode).
- `tui/view.zig` is the **pure renderer** (grid paint + status line + scroll + match scan).
- `tui/app.zig` owns **terminal control + event loop + mouse decode**.
- `region.zig` is the **orchestrator** (capture → grid → TUI loop → confirm-render).

All 21 motions are fully implemented in `motion.applyMotion` (`motion.zig:480-595`).

---

## 1. MOVEMENT (input decode `input.zig` + motion apply `motion.zig`)

| Key(s) | Decoded | Motion | Notes |
|---|---|---|---|
| `h` / `←` | yes | `.left` | x = max(0, x-count) |
| `l` / `→` | yes | `.right` | x = min(cols-1, x+count) |
| `j` / `↓` | yes | `.down` | recomputes scroll |
| `k` / `↑` | yes | `.up` | recomputes scroll |
| `w` | yes | `.word_fwd` | **two-class WORD** (deviation D1) |
| `b` | yes | `.word_back` | two-class WORD |
| `e` | yes | `.word_end` | two-class WORD |
| `0` / Home | yes | `.line_start` | leading `0` is line_start, NOT a count |
| `^` | yes | `.first_nonblank` | |
| `$` / End | yes | `.line_end` | `2$` moves down then to end |
| `gg` | yes (two-key) | `.doc_top` | count carries (`5gg`) |
| `G` | yes | `.doc_bottom` | |
| `Ctrl-d` / Ctrl-↓ | yes | `.half_page_down` | |
| `Ctrl-u` / Ctrl-↑ | yes | `.half_page_up` | |
| `Ctrl-f` / PgDn | yes | `.page_down` | |
| `Ctrl-b` / PgUp | yes | `.page_up` | |
| `H` | yes | `.viewport_top` | |
| `M` | yes | `.viewport_mid` | count ignored |
| `L` | yes | `.viewport_bottom` | |
| `{` | yes | `.paragraph_back` | nearest ALL-BLANK row above |
| `}` | yes | `.paragraph_fwd` | nearest ALL-BLANK row below |
| `%` | yes | `.match_bracket` | `()` `[]` `{}`, nesting-tracked, count ignored |

Arrows also accept SS3 (`\x1bOA..`). Ctrl-arrows (`\x1b[1;5A/B/C/D`): A⇒half-up,
B⇒half-down, C⇒word-fwd, D⇒word-back. Home/End accept multiple CSI forms.

**Counts:** YES, supported. Leading digits `1`-`9` extend the count; `0` only
extends an *active* count (so a leading `0` = line_start). `5j`, `10j`, `5gg`,
`2$`, `3q` work. Capped at 1,000,000.

### Documented v1 simplifications vs vim (`motion.zig:24-31`)
- **D1 — two-class WORD.** A "word" = a maximal run of NON-WHITESPACE (== vim
  `W`/`B`/`E`). `foo.bar` is ONE word; vim `w` would split on `.`.
- **D2 — `{`/`}`** jump to the nearest ALL-BLANK row strictly above/below; no
  consecutive-blank-row collapsing.
- **D3 — `%`** always does bracket matching; no percent-of-file jump.
- **D4 — `1G` ambiguity.** `Key` carries only a resolved `count` (default 1), no
  `has_count` field. Plain `G` and `1G` both go to the LAST row (vim `1G`→row 1).
  `5G`→row 4 works. Same for `gg`.

## 2. SEARCH (`input.zig:252-256`, wired in `region.zig`)

- `/` forward, `?` backward, `n` next, `N` prev (with wraparound).
- `/`/`?` enter pattern-typing: `Enter` finalizes + jumps to first match; `Esc`
  cancels; Backspace/Ctrl-H deletes; printable appends.
- **FIXED-STRING only, case-sensitive.** `view.SearchMode = enum { fixed }`
  (`view.zig:96`); `.regex` is RESERVED but NOT implemented (Zig 0.15.2 has no
  stdlib regex). NOT configurable. No ignore-case.
- Matches shown in **reverse video**; an already-inverse cell returns to normal.

> **DEVIATION from PRD §7.3** ("regex or fixed-string, configurable"): shipped =
> fixed-string only, case-sensitive. Document it as-is; do NOT claim regex.

## 3. SELECTION (`select.zig`, applied via `region.zig`)

`Sel{ anchor, cursor, mode }`, `Mode = { none, linewise, block }`.

| Key | Action | Behavior |
|---|---|---|
| `v` | `.visual_toggle` | inactive ⇒ begin LINewise at cursor (anchor=cursor); active ⇒ toggle linewise↔block |
| `V` | `.visual_line` | begin/force linewise |
| `Ctrl-v` (0x16) / `R` | `.visual_block` | begin/force block |
| `o` | `.swap_end` | active ⇒ swap anchor↔cursor; inactive ⇒ no-op |
| `O` | `.swap_end_other` | **identical to `o`** (block-corner distinction not modeled) |
| `Esc` | `.clear` | region.zig decides: if selection active ⇒ clear + stay; else ⇒ quit |
| `q` / Ctrl-c | `.quit` | exit |

Movement extends the selection (anchor fixed, cursor follows).

**Output mapping (`select.extent` `select.zig:88-100`):**
- linewise ⇒ `{ x1=0, y1=min, x2=cols-1, y2=max, rect=false }`.
- block ⇒ `{ x1=min(ax,cx), y1=min, x2=max(ax,cx), y2=max, rect=true }`.
Matches PRD §7.4 exactly.

## 4. CONFIRM / CANCEL (`region.zig` `.confirm` arm, ~lines 395-420)

**Confirm** — `Enter` (0x0d/0x0a) or `y` → fully implemented:
1. `app.exit(state)` FIRST (restore cooked mode); idempotent.
2. **Empty-selection guard:** `if (!ctx.sel.active())` ⇒ stderr
   `"tmux-2html region: no selection (press v to begin, then Enter)\n"`, **no
   file, exit 1** (`region.zig:236-239`).
3. Reads `@tmux-2html-font` (default `monospace`) + `@tmux-2html-open` (default on).
4. `renderSelectionHtml` via the vendored `ScreenFormatter`.
5. Output path: explicit `--output` wins; else `<session>-<unixtime>-<pid>.html`
   in the resolved output dir.
6. `writeHtmlAtomic` (temp + same-dir rename).
7. **`.last-output` sidecar**: bare output path to `<bin-dir>/.last-output`
   (bin dir via `/proc/self/exe`). Best-effort.
8. `--open` best-effort.
9. **exit 0** on success; every error ⇒ stderr + exit 1.

**Cancel** — `q` / Ctrl-c, or `Esc` with no active selection ⇒ **exit 1, no output**.
Ctrl-c also covered by the SIGINT restore-then-re-raise handler.

> ⚠ STALE header comment in `region.zig:2-11` still calls confirm a "S1 STUB".
> OUTDATED. The confirm-render flow is fully implemented. Do NOT document it as a stub.

## 5. MOUSE (`app.zig` decode; NOT wired into the loop) — **MAJOR DEVIATION**

- Mouse is **ENABLED** at the terminal level: modes 1000 (click) + 1002
  (button-event/drag) + 1006 (SGR) (`app.zig:98-101`).
- SGR decode is **fully implemented** (`app.zig:decodeButton`/`parseMousePayload`):
  button, action (press/release/motion/wheel), modifiers (shift=b&4, **alt=b&8**,
  ctrl=b&16); wheel 64=up/65=down; coords are 1-based character cells.
- **BUT mouse actions are NOT wired into the TUI loop.** `region.regionHandle` has
  no mouse branch; `input.feed` returns null for `.mouse` ⇒ `.none` keeps the loop
  alive. The region.zig comment states it: *"Mouse is a NO-OP in S1 ... app.zig
  already DECODES SGR mouse; a later task only adds the regionHandle mouse branch."*

**Net shipped behavior:** mouse is enabled + decoded, but click-to-move,
drag-to-select, and wheel scroll are all **NO-OPs** in the live TUI.

> **DEVIATION from PRD §7.6** ("Mouse (supported)"). Document mouse as NOT yet
> functional (a known limitation), do NOT claim it works.

## 6. STATUS LINE — exact format (`view.renderStatus`, `view.zig:~210-250`)

Painted on the last tty row in reverse+bold, truncated to cols, trailing EL+reset.

Fields, in order:
```
[LINE|BLOCK]  row:N col:M  /pattern  N match(es)  <S-sel>  Enter=render q=quit
```
- mode tag `[LINE]`/`[BLOCK]` — **omitted entirely when no selection** (`mode==.none`).
- `row:{d} col:{d}` — **1-based** (cursor.y+1, cursor.x+1).
- search token `  /{s}  {d} match(es)` — only when pattern non-empty; N = matches.len.
- `<S-sel>` — only when a selection is active.
- `  Enter=render q=quit` — always shown.

Examples:
- Everything active: `[LINE]  row:3 col:4  /foo  3 match(es)  <S-sel>  Enter=render q=quit`
- Nothing active: `row:1 col:1  Enter=render q=quit`

Matches PRD §7.1 exactly.

## 7. DISPLAY (`app.zig` + `view.zig`)

- Enter: `\x1b[?1049h\x1b[?25l` (+ mouse enable). Leave: disable mouse, then
  `\x1b[?25h` (show cursor) + `\x1b[?1049l` (leave alt).
- Raw termios: clears ICANON/ECHO, IXON/ICRNL/BRKINT, OPOST; CS8; MIN=1/TIME=0.
- **Restore on every exit incl. panic**: one idempotent restore guarded by an
  atomic `entered` flag, shared by the defer path, the SIGINT/SIGTERM/SIGQUIT
  handler (restore-then-re-raise), and the root panic override in `main.zig`.
- Viewport: full repaint per call (no `\x1b[2J`, avoids flicker); scroll
  recomputed after each cursor move; clamped to grid end. (Diff-rendering is
  deferred — perf only, not a behavior difference.)

## 8. Full scrollback is browsed

YES. `region.body` captures in `.full` mode (honoring `@tmux-2html-history-limit`,
default cap 50000), builds a `Terminal` at pane geometry, feeds all captured ANSI,
pre-decodes every row into a `motion.SliceGrid`, and sets the initial cursor at
the LAST row (tmux copy-mode enters at the bottom). So the TUI browses the ENTIRE
scrollback, not just the visible pane.

---

## Deviations summary (what docs must reflect honestly)

| Area | PRD says | Shipped | Doc action |
|---|---|---|---|
| MOUSE §7.6 | supported (click/drag/wheel) | enabled+decoded but NO-OP | document as NOT functional (known limitation) |
| SEARCH §7.3 | regex or fixed-string, configurable | fixed-string, case-sensitive, not configurable | document fixed-string only |
| WORDS §7.2 | vim w/b/e | two-class WORD (== vim W/B/E) | optional note |
| o/O §7.4 | vim o/O corner | identical | optional note |
| Diff-render §7.1 | for perf | full repaint | do not document (perf only) |
