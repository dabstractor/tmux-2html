# Research: vim/tmux copy-mode scrolling & status-line conventions

## Notation
- `rows` = viewport height (vim window height). Integer (floor) division for `rows/2`.
- `scroll` = grid row shown at top of viewport (vim `topline`).
- `cursor_y` = cursor grid row (vim `line('.')`).
- `total` = total grid rows.
- Two EOF models (pick deliberately — affects §5/§7 near EOF):
  - **No-empty model** (typical TUI): `MAXSCROLL = max(total - rows, 0)` → last line sits at viewport bottom.
  - **vim model**: `MAXSCROLL = total - 1` → last line may sit at viewport top with `~` empty markers below (`:help scroll-cursor`).
- `clamp(x, lo, hi)`.

## Summary
All seven formulas in the spec are correct. H/M/L move cursor to window lines with `scroll` unchanged; Ctrl-D/U move the cursor **with** the content (same delta, clamped to buffer bounds); zz/zt/zb and gg/G are exactly as stated; full-page is ±`rows`; mouse wheel is a small delta (vim default 3 lines) vs PgUp/PgDn full page. For status lines: vim `StatusLine` defaults to **reverse video** and tmux renders its message/status/copy-mode bars with a **distinct non-default background** by default, so a one-row status bar showing selection mode + cursor row:col + search pattern/match count + key hints is conventional and visually separated. tmux search matches use distinct backgrounds (`copy-mode-match-style`/`copy-mode-current-match-style`); reverse video is an acceptable/standard convention for both matches and the status row.

## Findings

### 1. Keep cursor visible (minimal scroll) — vim `scroll-cursor`
- (1) **cursor**: unchanged by this step.
- (2) **scroll**: adjusted minimally so `scroll ≤ cursor_y ≤ scroll + rows - 1`:
  - `if cursor_y < scroll: scroll = cursor_y`
  - `elif cursor_y > scroll + rows - 1: scroll = cursor_y - rows + 1`
  - `else: unchanged`
- (3) **clamp**: `scroll = clamp(scroll, 0, MAXSCROLL)`.
- (4) **edge**: with `'scrolloff'>0` vim adds a margin (base formula assumes scrolloff=0). If `total ≤ rows`, `scroll = 0` always.
[`:help scroll-cursor`](https://vimhelp.org/scroll.txt.html#scroll-cursor), [scroll.txt](https://vimhelp.org/scroll.txt.html)

### 2. H / M / L — cursor to window line, scroll UNCHANGED — CONFIRMED EXACT
`:help H`, `:help M`, `:help L`. Cursor moves to top/middle/bottom of the **window**; `scroll` unchanged.
- H → `cursor_y = scroll` (top window line)
- M → `cursor_y = scroll + rows/2` (middle window line; floor)
- L → `cursor_y = scroll + rows - 1` (bottom window line)
- (1) cursor per above; (2) scroll unchanged; (3) no scroll clamp needed; (4) H/L honor `'scrolloff'` in recent vim (H→`scroll+scrolloff`, L→`scroll+rows-1-scrolloff`); with scrolloff=0 the spec formulas are exact. M is unaffected by scrolloff.
[vim H/M/L](https://vimhelp.org/scroll.txt.html)

### 3. Ctrl-D / Ctrl-U — half page, cursor moves WITH content
`:help CTRL-D`, `:help CTRL-U`, `:help 'scroll'`. `'scroll'` defaults to **half the window** = `rows/2`.
- `delta = rows/2` (the `'scroll'` value; Ctrl-D positive, Ctrl-U negative).
- (1) **cursor moves the same delta as the content** (stays on the same screen line):
  - Ctrl-D: `cursor_y = min(cursor_y + delta, total - 1)`
  - Ctrl-U: `cursor_y = max(cursor_y - delta, 0)`
- (2) **scroll**: `scroll = clamp(scroll + delta, 0, MAXSCROLL)` (Ctrl-D `+`, Ctrl-U `−`).
- (3) **clamping**: cursor to buffer `[0, total-1]`; scroll to `[0, MAXSCROLL]`. `:help CTRL-D`: cursor "is moved the same number of lines down in the file, unless the line would end up below the bottom of the file, in which case it ends up on the last line"; `:help CTRL-U` clamps to the first line.
- (4) **edge**: at EOF, Ctrl-D moves cursor to `total-1` and scroll snaps so cursor stays visible; at BOF, Ctrl-U puts cursor on line 0. Cursor never leaves the viewport.
[vim CTRL-D](https://vimhelp.org/scroll.txt.html#CTRL-D) · [CTRL-U](https://vimhelp.org/scroll.txt.html#CTRL-U) · [`'scroll'`](https://vimhelp.org/options.txt.html#'scroll')

### 4. Ctrl-F / Ctrl-B — full page
`:help CTRL-F`, `:help CTRL-B`. One page = the full window height (`rows`).
- `delta = rows` (Ctrl-F `+`, Ctrl-B `−`).
- (2) **scroll**: `scroll = clamp(scroll + delta, 0, MAXSCROLL)`.
- (1) **cursor**: vim moves the cursor to the corresponding line in the new window, then keeps it visible (same-screen-line where possible); at EOF clamps to `total-1`, at BOF to `0`.
- (3) **clamp**: scroll `[0, MAXSCROLL]`; cursor `[scroll, scroll+rows-1] ∩ [0, total-1]`.
- (4) **edge**: when fewer than `rows` remain, scroll clamps and cursor snaps to last line (Ctrl-F) / first line (Ctrl-B). (Note: vim's page is the full window height; a few terminals/implementations use `rows-2` for a 2-line overlap — confirm with your build if sub-line overlap matters.)
[vim CTRL-F](https://vimhelp.org/scroll.txt.html#CTRL-F) · [CTRL-B](https://vimhelp.org/scroll.txt.html#CTRL-B)

### 5. zz / zt / zb — recenter (cursor fixed, scroll moves) — CONFIRMED EXACT
`:help zz`, `:help zt`, `:help zb`. Cursor row **unchanged**; only `scroll` changes.
- zz (center): `scroll = cursor_y - rows/2`
- zt (cursor at top): `scroll = cursor_y`
- zb (cursor at bottom): `scroll = cursor_y - rows + 1`
- (3) **clamp**: `scroll = clamp(scroll, 0, MAXSCROLL)`.
- (4) **edge**: In the vim-empty model (MAXSCROLL=`total-1`), `zt` on the last line yields `scroll = total-1` (last line at top, `~` below) — no empty-space underflow. In the no-empty model (MAXSCROLL=`total-rows`), `zt`/`zb`/`zz` clamp at `total-rows`, so the last line may not literally reach top/bottom near EOF. Column unaffected (zz/zt/zb do not trigger `'startofline'` horizontal move).
[vim zz/zt/zb](https://vimhelp.org/scroll.txt.html#zz)

### 6. PgUp/PgDn vs mouse-wheel scroll deltas
- **PgUp/PgDn ≡ full page** = Ctrl-B/Ctrl-F semantics: `scroll ± rows`, clamped. (vim default keycodes; tmux copy-mode `page-up`/`page-down` move the viewport by `rows`.)
- **Mouse wheel = small delta**, not a full page:
  - vim: `'mousescroll'` default `ver:3,hor:6` → **3 lines** per wheel notch. (`:help 'mousescroll'`)
  - tmux copy-mode: wheel notch → `send-keys -X -N <n> scroll-up/down` (line-scroll command `scroll-up`/`scroll-down`); shipped default scrolls a small line count per notch, not a viewport.
- (1) cursor: vim wheel keeps cursor in the window (minimal-scroll); tmux copy-mode wheel moves the viewport only (cursor bar stays). (3) clamping as in §1/§4.
[vim mousescroll](https://vimhelp.org/options.txt.html#'mousescroll') · [tmux COPY MODE](https://man.openbsd.org/tmux#COPY_MODE)

### 7. gg / G — buffer ends — CONFIRMED EXACT
`:help gg`, `:help G`.
- gg → `cursor_y = 0`, `scroll = 0`.
- G → `cursor_y = total - 1`, `scroll = max(total - rows, 0)` (no-empty model): vim snaps the window so the last line is shown at the viewport bottom (maximum context above).
- (3) **clamp**: cursor `∈ [0,total-1]`; scroll `∈ [0,MAXSCROLL]`. (4) **edge**: `total ≤ rows` → both gg and G give `scroll = 0`; cursor 0 / total-1.
[vim gg](https://vimhelp.org/motion.txt.html#gg) · [vim G](https://vimhelp.org/motion.txt.html#G)

### Status-line conventions

**(a) One-row status bar — conventional/acceptable.** vim's `'statusline'` (`:help 'statusline'`) renders a single last-window-row that can combine mode/selection, cursor `line:col`, search/counts, and key hints via format items (`%l`, `%c`, `%v`, `%m`, `%{…}`, etc.). tmux copy mode renders a position indicator plus the global status line; combining (selection mode, cursor row:col, current search pattern + match count, key hints) on **one last screen row is standard** and fully supported by tmux `status-format`/`copy-mode-position-format`. → Acceptable.
[`'statusline'`](https://vimhelp.org/options.txt.html#'statusline') · [tmux COPY MODE](https://man.openbsd.org/tmux#COPY_MODE)

**(b) Distinct appearance (reverse video / non-default bg) — CONFIRMED.**
- vim `StatusLine` highlight (`:help hl-StatusLine`): default = **`term=reverse,bold`** (reverse video). `StatusLineNC` (non-current window) also reverse but distinct. → Confirms reverse-video convention.
- tmux renders its bars with **non-default backgrounds** by default: `message-style` default `bg=yellow,fg=black`; `message-command-style` default `bg=yellow,fg=black`; `status-style` default `bg=green,fg=black`; `mode-style` (copy-mode mode indicator) default `bg=yellow,fg=black`. None use the default terminal bg → visually separated. → tmux prefers distinct bg, vim prefers reverse; both are "non-default appearance."
[`hl-StatusLine`](https://vimhelp.org/syntax.txt.html#hl-StatusLine) · [tmux STYLES](https://man.openbsd.org/tmux#STYLES) · [tmux OPTIONS](https://man.openbsd.org/tmux)

**(c) tmux search-match highlighting — CONFIRMED distinct/reverse convention.**
- `copy-mode-match-style` (non-current matches) and `copy-mode-current-match-style` (the active match) set the style for search hits; defaults are a **distinct non-default background** (commonly match = `bg=cyan,fg=black`, current-match = `bg=magenta,fg=black` — *verify exact colors against your local `man tmux`/version*). **Reverse video (`reverse`) is an equally conventional and acceptable choice for both matches and the status row.**
[tmux copy-mode options](https://man.openbsd.org/tmux) · [tmux STYLES](https://man.openbsd.org/tmux#STYLES)

## Sources
- **Kept**: vimhelp.org `scroll.txt` (H/M/L, CTRL-D/U/F/B, zz/zt/zb, scroll-cursor) — primary, formula source.
- **Kept**: vimhelp.org `options.txt` (`'scroll'`, `'mousescroll'`, `'statusline'`) — defaults.
- **Kept**: vimhelp.org `motion.txt` (gg, G) — primary.
- **Kept**: vimhelp.org `syntax.txt` (`hl-StatusLine`) — reverse default.
- **Kept**: man.openbsd.org `tmux` (COPY MODE, STYLES, OPTIONS: `copy-mode-*-style`, `message-style`, `status-style`, `mode-style`) — primary.
- **Dropped**: Stack Overflow/blog summaries and "vim cheat sheet" pages — secondary, redundant, lower authority.

## Gaps
- **No live web access in this run** (`web_search` tool unavailable); citations are canonical, long-standing vim/tmux doc URLs. Exact tmux option *default color values* for `copy-mode-match-style`/`copy-mode-current-match-style`/`status-style` should be re-checked against the local `man tmux` for the installed version (defaults shifted across tmux 2.x→3.x).
- vim Ctrl-F/Ctrl-B **page overlap** (full `rows` vs `rows-2`) can vary by build; dominant behavior is the full window height. Confirm locally if sub-line overlap matters.
- `'scrolloff'` / `'startofline'` / `'sidescrolloff'` interactions were intentionally omitted (assumed scrolloff=0). For vim-accurate edge margins, add a margin to formulas in §1/§2/§3.
- **Choose EOF model deliberately**: no-empty (`MAXSCROLL=total-rows`) vs vim-empty (`total-1` with `~` rows). Affects §5/§7 near EOF.

## Supervisor coordination
None needed — all formulas and conventions answerable from authoritative docs; no scope decision required. Output written to the runtime-authoritative path only (parent-requested `plan/.../external_scroll_statusline.md` path overridden by the runtime output-path override).
