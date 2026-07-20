# Research: tmux `display-popup` pane-anchored positioning

## Summary
All five claims hold. `display-popup` itself is new in **tmux 3.2**; the **`-B`** (borderless)
flag and the single-letter **`-x`/`-y` position tokens** (`M`/`W`/`S`/`P`/`C`) are **3.3**
features; with `-x P -y P -t "#{pane_id}"` the popup is anchored to the target pane (left
column + bottom edge), so `-w/-h` equal to `pane_width/pane_height` (borderless) yields an
exact 1:1 overlay; the combined feature set therefore requires **tmux ≥ 3.3**.

## Verification gap (read this first)
I could **NOT** independently fetch the live primary sources this run —
`web_search`/`fetch_content` are unavailable in this subagent, and no tmux source, CHANGES,
or man page exists locally (verified ENOENT on `/usr/share/doc/tmux`, `/usr/share/man`,
`/usr/local/share/man`, `~/tmux`, `~/src/tmux`). Confidence ratings below reflect domain
knowledge plus the project **PRD §7.0**, which documents *prior* verification of these flags
against `cmd-display-menu.c`/`popup.c`. **Do not treat the citations as "verified this run."**
Re-check against CHANGES + `popup.c` before shipping.

## Findings

1. **`-B` (borderless) = tmux 3.3.** [HIGH] `display-popup` appeared in 3.2 with an
   always-drawn border; `-B` (no border) shipped in 3.3 alongside `-b` (border-lines),
   `-s`/`-S` (styles). *Source: tmux CHANGES 3.3 entry; man page `display-popup` `-B` line.*

2. **Position tokens `M`/`W`/`S`/`P`/`C` = tmux 3.3; `P` = pane-anchored.** [MED-HIGH] In
   3.2 `-x`/`-y` accepted numeric cell positions only; the single-letter anchors were added in
   3.3 (shared parser in `cmd-display-menu.c`). `P` = "anchor to the target pane";
   `C`=centre, `M`=mouse, `W`=window, `S`=status line. *Source: man page `display-popup`
   `-x`/`-y`; `popup.c`/`cmd-display-menu.c` position parser.*

3. **`-x P -y P -t "#{pane_id}"` semantics.** [MED] `-x P` → target pane's **left column**;
   `-y P` → target pane's **bottom edge**. tmux anchors the popup at the bottom-left of its
   footprint (grows up-and-right), so `top = bottom − height`; with `-h "#{pane_height}"`
   the popup rows = `[pane_top, pane_bottom]` → exact vertical match. **Caveat:** because
   here `height == pane_height`, the exact-overlay result is robust whether the anchor is read
   as top or bottom — only the internal label (`popup_pane_bottom`) is the soft detail that
   needs `popup.c` confirmation. Horizontally, `-w "#{pane_width}"` + `-x P` covers
   `[pane_left, pane_right]`. *Source: `popup.c` (`popup_position` / `popup_pane_*`).*

4. **`-B` ⇒ inner pty = full `-w`/`-h`.** [HIGH] A bordered popup reserves one cell per side
   for the border, so the inner shell pty is `(w−2) × (h−2)`; `-B` (`BOX_LINES_NONE`) removes
   the border so the pty gets the full `w × h` footprint (no title-bar overhead with no
   border). *Source: `popup.c` border/inner-size calc; man page `-B`.*

5. **Version floor.** [HIGH] `display-popup` (any form) requires **≥ 3.2** (command
   introduced then). The combination `-B` + `-x P`/`-y P` requires **≥ 3.3** (both are 3.3
   features). So tmux-2html's runtime floor of **tmux ≥ 3.3** (PRD §12) is correct and not
   over-constrained — `-B` alone forces 3.3.

## Sources (canonical references — NOT fetched this run)
- **tmux CHANGES file** — github.com/tmux/tmux/blob/master/CHANGES (3.2: `display-popup`;
  3.3: `-B`, `-b`, `-x`/`-y` tokens). *Why: authoritative version/feature history.*
- **tmux `popup.c` / `cmd-display-menu.c`** — github.com/tmux/tmux/blob/master/popup.c.
  *Why: positioning + border/inner-size arithmetic for claims 3 & 4.*
- **tmux man page** — man.openbsd.org/tmux (`display-popup` section). *Why: flag/semantics
  documentation.*
- Dropped: none (no web sources were fetched). Supplementary: project PRD §7.0 / §12.

## Gaps
- **Least-certain boundary:** confirm via CHANGES that 3.2's `-x`/`-y` were numeric-only and
  the `M`/`W`/`S`/`P`/`C` letters are strictly 3.3 (some tokens may have been partially
  present in a late 3.2 — verify before pinning a hard `≥ 3.3` for the *position* part; note
  `-B` alone already mandates 3.3 regardless).
- `popup_pane_bottom` / bottom-left-anchor mechanism in `popup.c` not re-verified this run
  (see claim-3 caveat; the practical exact-overlay outcome is robust either way).
- **Recommended:** add a runtime guard `tmux -V` ≥ 3.3 before invoking the region popup.