# Vim Motion Semantics (authoritative) — for `src/tui/motion.zig` (P3.M2.T1.S2)

Source of every fact: vim `motion.txt` / `options.txt` on vimhelp.org. Each rule below is
deterministic-test-ready. Where the common copy-mode-TUI simplification diverges from full
vim, it is flagged with **TUI-SIMPLIFICATION**.

Primary URL: https://vimhelp.org/motion.txt.html (tags cited as `:help <tag>`).

---

## 1. Word motions `w` / `b` / `e`

vim's lowercase `w/b/e` use a **three-class** character model:
1. whitespace (space/tab/newline);
2. keyword (`'iskeyword'`, default `A-Za-z0-9_`);
3. non-blank non-keyword (punctuation).

A *word* = a maximal run of chars in the SAME non-whitespace class. So `foo!!!bar` = 3 words.

**TUI-SIMPLIFICATION (ADOPTED):** This TUI implements the **two-class WORD model** (a *word* =
a maximal run of NON-WHITESPACE chars), which equals vim's uppercase `W`/`B`/`E`. This is the
near-universal copy-mode convention (less, tmux copy-mode) and is far simpler + deterministic.
`foo.bar` is ONE word under this model (vim `w` would split it). Documented divergence.

- `w` ([count]) — move to the START of the next word. Skip the current non-blank run + following
  whitespace; land on the next non-blank char. Crosses newlines (a blank row is whitespace).
  At EOF (no next word) ⇒ land on the last cell of the last row (clamp). `[count]` repeats.
- `b` ([count]) — move to the START of the previous word. At BOF ⇒ clamp to (0,0). Repeats.
- `e` ([count]) — move to the END of the current word (if not already at its end) else the end of
  the next word. Crosses rows. At EOF ⇒ last cell of last word. (vim `e` does NOT stop on empty
  rows — only on the end of a non-blank word.)

vimhelp: `:help word`, `:help WORD`, `:help w`, `:help b`, `:help e`, `:help word-motions`.

## 2. Line motions `0` / `^` / `$`

- `0` — column 0 (first cell). No count.
- `^` — first NON-BLANK cell of the row. No count. Blank/whitespace-only row ⇒ cell 0.
- `$` — last cell of the row (last non-blank). `[count]$` ⇒ move `count-1` rows DOWN, then end.
  So `2$` = end of the NEXT row. Blank row ⇒ cell 0.

vimhelp: `:help 0`, `:help ^`, `:help $`.

## 3. `gg` / `G` (goto line)

- `gg` — FIRST row (no count); `[count]gg` ⇒ row `count`. Lands on first non-blank (vim
  `'startofline'`).
- `G` — LAST row (no count); `[count]G` ⇒ row `count`.
- **CONFIRMED: plain `G` = LAST row; `1G` = row 1; they DIFFER.**

**CRITICAL AMBIGUITY (this codebase):** `input.zig` (P3.M2.T1.S1) resolves `Key.count` to `1`
when NO count was typed (deliberate design — no `has_count` field). So the decoder CANNOT
distinguish plain `G` (count default 1) from `1G` (count explicit 1) — both arrive as
`Key{count:1, .doc_bottom}`.

**RESOLUTION (ADOPTED, documented v1 limitation):**
- `G` (doc_bottom): `count <= 1` ⇒ LAST row (`total_rows-1`); `count >= 2` ⇒ row `count-1`.
  This makes the common plain-`G` (→ last row) correct; the only casualty is `1G` (vim → row 1,
  this TUI → last row). Acceptable for v1; flagged in Anti-Patterns.
- `gg` (doc_top): `count <= 1` ⇒ row 0 (vim `1gg`=row 1 ✓); `count >= 2` ⇒ row `count-1` (✓).

vimhelp: `:help gg`, `:help G`.

## 4. `CTRL-D` / `CTRL-U` (half-page)

vim scrolls the viewport AND moves the cursor by the SAME number of lines (`'scroll'` ≈ half the
window height), so the **cursor stays at the same screen row** while the text under it changes.

**ADOPTED:** `half = viewport.rows / 2` (floor).
- `Ctrl-d`: `new_scroll = view.halfPageDown(scroll, total, rows)`; `new_y = min(total-1, y+half)`;
  then clamp `new_y` into the new viewport `[new_scroll, min(total-1, new_scroll+rows-1)]` so the
  cursor stays visible (≈ same screen row). `x` preserved (clamped to new row's last cell).
- `Ctrl-u`: mirror with `view.halfPageUp` + `new_y = max(0, y-half)`.

vimhelp: `:help CTRL-D`, `:help CTRL-U`, `:help 'scroll'`.

## 5. `CTRL-F` / `CTRL-B` (full page)

vim moves the cursor ≈ one window height and keeps it in the new viewport (screen row changes).

**ADOPTED:**
- `Ctrl-f`: `new_scroll = view.pageDown(scroll, total, rows)`; `new_y = min(total-1, y+rows)`;
  clamp into viewport.
- `Ctrl-b`: `new_scroll = view.pageUp(scroll, total, rows)`; `new_y = max(0, y-rows)`; clamp.

vimhelp: `:help CTRL-F`, `:help CTRL-B`.

## 6. `H` / `M` / `L` (window-relative)

- `H` — row `viewport.scroll + (count-1)` (default count 1 ⇒ the top visible row).
- `M` — row `viewport.scroll + rows/2` (count IGNORED). Clamp to `total-1`.
- `L` — row `min(total-1, viewport.scroll + rows-1) - (count-1)` (default count 1 ⇒ bottom row).

`x` preserved (clamped to the target row's last cell). **TUI-SIMPLIFICATION:** vim resets the
column to first-non-blank under `'startofline'` (default on); this TUI preserves+clamps `x`
(predictable; documented divergence).

vimhelp: `:help H`, `:help M`, `:help L`.

## 7. `{` / `}` (paragraph)

A paragraph boundary = an EMPTY (all-whitespace) row.

**TUI-SIMPLIFICATION (ADOPTED):** vim COLLAPSES a run of consecutive empty rows into one
separator; this TUI jumps to the nearest blank row STRICTLY above/below the cursor (stopping on
each blank row), `count` repeats. (Collapsing is a refinement; the simple "jump to next/prev
blank row" is the copy-mode norm and trivially testable.)

- `{` (paragraph_back): nearest blank row strictly ABOVE cursor (row `y` where text is all
  whitespace), scanning up; if none ⇒ 0. Repeats `count` times.
- `}` (paragraph_fwd): nearest blank row strictly BELOW; if none ⇒ `total_rows-1`. Repeats.

vimhelp: `:help {`, `:help }`, `:help paragraph`.

## 8. `%` (bracket matching)

Default pairs: `()`, `[]`, `{}`.

- If cursor is ON a bracket ⇒ jump to its MATCH (forward for openers, backward for closers),
  tracking **nesting depth** (count same-type openers/closers; land at depth 0). Scan crosses
  rows (forward or backward over the grid text).
- If cursor is NOT on a bracket ⇒ vim searches the REST of the current line forward for the first
  bracket, then matches it. **ADOPTED:** same — search the current row forward (from cursor) for
  the first bracket char; if found, match it; if none ⇒ no move (return null).
- **Count:** vim `[count]%` = jump to the line that is `count`% through the file (NOT repeated
  matching). **TUI-SIMPLIFICATION (ADOPTED):** `%` ALWAYS does bracket matching; count is IGNORED.
  (Percent-of-file jumps are out of scope for a copy-mode TUI.)

vimhelp: `:help %`, `:help matchpairs`, `:help 'matchpairs'`.

---

## Count-semantics summary (this TUI's adopted behavior)

| Motion | Count behavior (ADOPTED) |
|---|---|
| `h` `l` | repeat `count` cells (clamp) |
| `j` `k` | repeat `count` rows (clamp + scroll) |
| `w` `b` `e` | repeat `count` words |
| `0` `^` | no count |
| `$` | end of row `count-1` below |
| `gg` | row `count` (0 if count≤1) |
| `G` | row `count` (LAST if count≤1) ← the documented ambiguity |
| `Ctrl-d` `Ctrl-u` | half-page × (count applies: move/scroll `count`×half) |
| `Ctrl-f` `Ctrl-b` | full page × `count` |
| `H` | `count-1` from top |
| `M` | ignored |
| `L` | `count-1` from bottom |
| `{` `}` | repeat `count` blank-row jumps |
| `%` | ignored (always bracket-match) |

> **`Ctrl-d`/`u`/`f`/`b` count:** since `input.Key.count` defaults to 1, plain `Ctrl-d` = one
> half-page. `5Ctrl-d` = 5×half-page (repeat the half-page step `count` times). ADOPTED: apply
> `count` as a repeat of the half/full-page step (NOT vim's "set `'scroll'`=count" semantics).
