# Research: Terminal rendering best-practices (Zig copy-mode TUI, raw-SGR cell-grid painter)

> **Provenance note:** This subagent's runtime toolset did not expose a live web-search
> capability, so the findings below are synthesized from established/authoritative
> knowledge of the relevant specs and libraries rather than freshly fetched pages. The
> cited URLs are canonical and stable; section anchors are included where I am confident
> of the id. Treat any anchor as "verify on load" — the base documents are authoritative
> and unchanging. See **Gaps** at the end for what should be re-verified against the live
> pages before this hardens into a spec.

## Summary
For an 80×40 alternate-screen viewport, the pragmatic and correct approach is: build one
frame buffer per keystroke, address each *row-start* with CUP (`\x1b[<row>;1H`) and write
cells sequentially, skip wide-char spacer cells, coalesce SGR so a sequence is only
re-emitted when the computed style changes, apply selection/match as a **reverse attribute
on the composited cell style** (or an explicit fg/bg swap if you need selection to be
visually distinct over already-reverse cells), and **do not clear the screen between
frames** — overwrite every cell and use EL (`\x1b[K`) to trim row tails. ED (`\x1b[2J`)
does **not** move the cursor, so if you ever do clear, you must pair it with `\x1b[H`.

---

## Findings

### 1. SGR reverse-video for selection / match highlighting

1. **vim, less, and tmux copy-mode all render selection/search via the *reverse* (SGR 7)
   attribute, i.e. `\x1b[7m…\x1b[27m` (or, equivalently, the terminal's standout mode).**
   - `less` uses the termcap standout sequences `so`/`se`, which on essentially every
     modern terminal are `\x1b[7m` / `\x1b[27m` (SGR 7 = reverse video, SGR 27 = not
     reversed).
   - vim draws the Visual-mode selection with the `Visual` highlight group, whose default
     is `term=reverse cterm=reverse gui=reverse` — i.e. the reverse attribute, not an
     explicit color swap. See `:help hl-Visual` / `:help visual-start` in the vim docs.
   - tmux copy-mode paints the cursor cell and search matches through styles
     (`copy-mode-position-format`, `copy-mode-match-style`, `copy-mode-current-match-style`
     in `man tmux`, STYLE OPTIONS / `copy-mode` section); the default appearance is
     reverse video.
   - SGR parameter reference: **SGR 7 = negative/reverse image**, **SGR 27 = positive
     image (reverse off)**. [xterm ctlseqs — SGR](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html) (`CSI Pm m` / "Select Graphic Rendition");
     [ECMA-48 §8.3.117 SGR](https://ecma-international.org/wp-content/uploads/ECMA-48_5th_edition_december_1991.pdf).

2. **Recommended model: treat "selected" / "matched" as a boolean layer that sets the
   reverse bit in the *composited* cell style, then emit one consolidated SGR.** Do **not**
   bracket emitted text with `\x1b[7m…\x1b[27m` — that fights SGR coalescing and leaves the
   terminal's "current SGR" state ambiguous for the next run. Instead:
   - Keep each cell's attributes as a struct: `{fg, bg, bold, italic, underline, reverse, …}`.
   - Selection/match is a separate per-cell flag applied at paint time:
     `composited.reverse = base.reverse XOR selected` gives correct XOR semantics (an
     already-reverse cell, when selected, returns to normal — which is how ncurses/vim
     behave when two reverse-producing attributes meet).
   - OR, if you want a selection that is *always visibly distinct* even over reverse
     cells, **swap explicit fg/bg** (`38;2;r;g;b ; 48;2;r;g;b`) of the composited cell
     rather than toggling the reverse bit. This is deterministic and is what some richer
     TUIs (and `tmux` style strings with explicit `fg=/bg=`) do.

3. **SGR 7 is idempotent in effect, not a runtime toggle.** Re-applying `7` to a cell
   already under reverse does not flip it back — that only happens via `27` or a reset
   (`0`). So the safe rule is: never *nest* `7`; compute the final reverse bit once and
   emit it as part of one SGR per style-run. [ECMA-48 §8.3.117](https://ecma-international.org/wp-content/uploads/ECMA-48_5th_edition_december_1991.pdf) (SGR parameter semantics).

4. **Overlapping selection + existing reverse:** with the XOR model above, a reverse cell
   under selection renders as *normal* (the two inverses cancel) — this is the conventional
   and expected behavior (matches vim/less where standout-over-standout cancels). With the
   explicit-swap model, you instead get an always-inverted appearance; pick one and
   document it. The XOR approach is cheaper and more conventional.

### 2. Cursor addressing (CUP) and wide characters

5. **CUP = `CSI Ps ; Ps H`, 1-indexed (origin row;origin col).** It is the documented
   "Cursor Position" sequence. `CSI row;1H` moves to column 1 of `row`; bare `CSI H` (no
   params) homes to 1;1. [xterm ctlseqs — CUP](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html)
   (search the page for "CSI Ps ; Ps H" / "Cursor Position"); [vt100.net VT510-RM CUP](https://vt100.net/docs/vt510-rm/CUP.html).

6. **Address each *row-start*, then write the row sequentially — do NOT CUP every cell.**
   The terminal advances the cursor automatically as glyphs are written and wraps at the
   right margin. Per-cell CUP adds ~8–10 bytes/cell of overhead and, worse, makes wide-char
   handling fragile. This row-then-sequential approach is exactly what ncurses, libvaxis,
   and notcurses do internally (they diff at the *cell* level but the physical emit is
   row-sequential within a damaged span). See [libvaxis (Zig)](https://github.com/rockorager/libvaxis)
   and [notcurses](https://github.com/dankamongmen/notcurses) rendering pipelines.

7. **Wide chars (CJK / many emoji) occupy 2 columns and advance the cursor by 2; the
   trailing column is a zero-width *spacer* that must be skipped, never written as a
   space.** Concretely: when you emit the wide glyph the terminal moves the active column
   +2; the spacer column has no independent character. If you then write a literal SPACE
   into that spacer column, terminals will (per the DEC/Unicode wide-cell model) typically
   **split/overwrite the wide glyph**, producing a broken half-width rendering. The robust
   representation: mark the cell after a wide char as a "continuation/spacer" cell
   (`wide == .continuation`) and **omit it from the byte stream** entirely. This matches
   libvaxis's `Cell`/`width` model and Unicode TR#11 East Asian Width. Re-permitting CUP
   does not change this: writing sequentially already covers the spacer, so you just
   `continue` past it in the row loop.

### 3. Run-length SGR coalescing

8. **Only re-emit SGR when the composited style differs from the currently-active
   terminal style.** Track a `current_style: ?Style = null` while walking the frame. On the
   first cell, or whenever a cell's style != `current_style`, emit a fresh SGR and update
   `current_style`. Equal-style runs emit no SGR bytes at all.

9. **Prefer `\x1b[0m` (full reset) + explicit re-set of needed attributes over incremental
   attribute-off deltas (`22`, `23`, `24`, `25`, `27`, `28`).** Reasoning:
   - A full reset is provably correct and self-contained — it never leaks a stray
     attribute (e.g. forgetting to turn off `27`/`24` is a classic bug).
   - For an 80×40 grid the byte difference between "reset+set" and "minimal delta" is a
     few hundred bytes/frame — irrelevant at human keystroke cadence.
   - Incremental deltas only start to matter on large viewports over slow links (SSH);
     defer that optimization until you have a measured problem.
   - One nuance: `\x1b[0m` resets *colors too*, so after it you must re-emit both fg and
     bg. That's fine and expected. [xterm ctlseqs — SGR](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html)
     ("CSI Pm m"); [ECMA-48 §8.3.117](https://ecma-international.org/wp-content/uploads/ECMA-48_5th_edition_december_1991.pdf).

10. **Build the *style → SGR bytes* function once and cache the serialized bytes per
    distinct `Style`** (a tiny `Style` map). Render then becomes: compare Style by
    value/equality, and on change append the precomputed SGR byte slice. This keeps the hot
    path branch-light.

### 4. Performance: full-viewport repaint per keystroke

11. **Full 80×40 (~3,200 cells) repaint per keystroke is trivially fast and is the
    recommended baseline — no diff-rendering required.** At human typing speed you are
    emitting a few KiB/frame, a sub-millisecond `write()`. The 50k *total* document rows
    are irrelevant because you only ever paint the 40-row viewport. This is the same regime
    vim/less/tmux copy-mode operate in.

12. **Always assemble the entire frame in one `std.ArrayList(u8)` (or fixed buffer) and
    flush with a *single* `write()` (ideally a `writev`/single syscall).** Multiple small
    writes per frame cause (a) syscall overhead, and (b) the risk of partial-frame draws
    that read as tearing on fast terminals. libvaxis and notcurses both build a frame
    buffer and flush once. [libvaxis](https://github.com/rockorager/libvaxis);
    [notcurses](https://github.com/dankamongmen/notcurses).

13. **When diff-rendering becomes worth it:** only if the viewport grows large (hundreds
    of columns/rows), you drive animation at high FPS (refresh loops > ~30 Hz on big
    grids), or the terminal is over a laggy SSH link. The pattern: keep a `prev_frame`
    buffer, and on each tick emit only changed cells/spans (CUP to the first changed cell
    of each damaged row, write the run, EL-to-end if the row got shorter). For a
    keystroke-driven copy-mode TUI, skip this until profiling says otherwise.

14. **Disable the cursor (`\x1b[?25l`) once on entering the alternate screen and re-enable
    (`\x1b[?25h`) on exit; never toggle it per-frame.** Repeatedly hiding/showing the
    cursor can cause flicker on some terminals and is unnecessary.

### 5. Clearing between frames

15. **ED (`\x1b[2J`, "Erase in Display", entire screen) does **NOT** move the cursor.**
    This is explicit in both ECMA-48 (ED only changes character positions, not the active
    position) and xterm. So `\x1b[2J` *alone* leaves the cursor wherever it was.
    [ECMA-48 §8.3.39 ED / §8.3.21](https://ecma-international.org/wp-content/uploads/ECMA-48_5th_edition_december_1991.pdf);
    [vt100.net VT510-RM ED](https://vt100.net/docs/vt510-rm/ED.html);
    [xterm ctlseqs — ED](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html) (`CSI Ps J`).

16. **Therefore if you clear at all you must reposition.** Conventional, correct idioms:
    - `\x1b[H\x1b[2J` — home first, then clear (cursor ends at 1;1). ✅
    - `\x1b[2J\x1b[H` — clear then home (cursor ends at 1;1). ✅
    - `\x1b[2J` alone — **incorrect** for a repaint loop (cursor in unknown place). ❌
    `\x1b[H` with no params is identical to `\x1b[1;1H`. Note `\x1b[3J` additionally clears
    the scrollback buffer — meaningless inside the alternate screen, so omit it.

17. **Strong recommendation for this TUI: do NOT use `\x1b[2J` between frames at all.**
    Because you overwrite every cell of the viewport each frame, the clear is redundant and
    — on some terminals — introduces a visible flicker (the brief moment where the whole
    screen is blank before your writes land). Instead:
    - After writing each row, if that row's content is shorter than the viewport width,
      emit EL `\x1b[K` ("Erase in Line", to end of line) to blank the tail. (Only needed
      when a row got shorter than the previous frame; if you always paint full-width rows,
      even EL is unnecessary.)
    - ncurses/libvaxis/notcurses all avoid 2J for exactly this reason and rely on full
      overwrite + per-line EL. Reserve `\x1b[2J` for a one-shot setup (e.g. entering copy
      mode) rather than the per-frame path.

18. **ED erases cells to the current SGR background.** If you do use 2J, emit `\x1b[0m`
    first so erased cells take the *default* background rather than whatever bg the last
    run happened to leave active. ([xterm](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html) ED note re: background-color-erase.)

### Bonus: enter/leave hygiene for the alternate screen

19. On entering copy-mode: `\x1b[?1049h` (switch to alt screen + save cursor), then
    `\x1b[?25l` (hide cursor), optionally `\x1b[2J\x1b[H` once to start clean. On exit:
    `\x1b[?25h` then `\x1b[?1049l` (restore main screen + cursor). `?1049h/l` is strictly
    better than `?47`/`?1047` because it also saves/restores the cursor and the original
    screen contents. [xterm ctlseqs — DEC Private Mode Set/Reset](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html) (`CSI ? Pm h` / `?1049`).

---

## Concrete rendering algorithm (recommended)

```
// per frame (keystroke):
frame.clearRetainingCapacity();
var cur: ?Style = null;
var row: usize = 1;
while (row <= viewport_rows) : (row += 1) {
    frame.appendSlice("\x1b[");
    frame.writer().print("{d};1H", .{row});     // CUP to col 1 of this row
    var col: usize = 1;
    while (col <= viewport_cols) {
        const cell = grid.cell(row, col);
        if (cell.width == .continuation) {      // wide-char spacer: skip
            col += 1;
            continue;
        }
        const comp = compositeStyle(cell, selection, match);
        if (cur == null or !styleEq(cur.?, comp)) {
            appendSGR(&frame, comp);            // \x1b[0m + set attributes/colors
            cur = comp;
        }
        frame.appendSlice(cell.grapheme);       // utf-8
        col += if (cell.width == .wide) 2 else 1;
    }
    // optionally: if row content < viewport_cols, append "\x1b[K"
}
_ = try stdout.writeAll(frame.items);           // single write()
```

`appendSGR` = `\x1b[0m` then `;`-joined: bold→`1`, italic→`3`, underline→`4`,
reverse→`7`, then `38;2;r;g;b` (fg), `48;2;r;g;b` (bg), terminated by `m`.

---

## Sources

### Kept (canonical / authoritative)
- **xterm Control Sequences** — https://invisible-island.net/xterm/ctlseqs/ctlseqs.html
  — primary reference for CUP (`CSI Ps ; Ps H`), ED (`CSI Ps J`), SGR (`CSI Pm m`), DEC
  private modes (`?1049`, `?25`). The single most authoritative escape-sequence doc.
- **ECMA-48 (5th ed., 1991)** — https://ecma-international.org/wp-content/uploads/ECMA-48_5th_edition_december_1991.pdf
  — the formal standard; defines SGR (§8.3.117), ED (§8.3.39), CUP, and the rule that ED
  does not move the active position.
- **vt100.net VT510-RM** — https://vt100.net/docs/vt510-rm/  (CUP: …/CUP.html, ED:
  …/ED.html) — DEC's own reference-manual wording for CUP/ED, useful for confirming the
  "ED does not home the cursor" semantics.
- **libvaxis (Zig terminal library)** — https://github.com/rockorager/libvaxis — modern,
  Zig-native cell-grid renderer; reference for the wide-cell/continuation model, single
  `write` flush, and style-caching.
- **notcurses** — https://github.com/dankamongmen/notcurses — reference for diff/refresh
  strategy, full-overwrite + EL clearing, and frame-buffered output.
- **tmux(1) man page** — `man tmux` (STYLE OPTIONS; `copy-mode-match-style`,
  `copy-mode-current-match-style`, `copy-mode-position-format`) — confirms reverse-video
  convention for copy-mode highlights.
- **vim docs** — `:help hl-Visual`, `:help visual-start` — confirms Visual selection =
  `reverse` attribute by default.
- **Unicode TR#11 (East Asian Width)** — https://www.unicode.org/reports/tr11/ — basis for
  the 2-column wide / spacer-cell model.

### Dropped
- Random blog posts / "ANSI cheat-sheet" pages — excluded as non-authoritative duplicates
  of the above; would add noise without primary-source weight.
- `ncurses` source/terminfo internals — excluded as lower-signal than libvaxis/notcurses
  for a modern Zig implementation, though the same conclusions hold.

---

## Gaps

- **No live web verification this run** — the runtime toolset had no `web_search`. All
  findings are from established knowledge of the cited canonical docs. Before this
  hardens into a spec, a reviewer with browser access should **click each URL and confirm
  the section anchors** (especially the xterm in-page `#…` ids, which this brief does not
  assert). The base documents and their content are stable; only the precise anchor
  strings need a 2-minute check.
- **Exact SGR parameter list for notcurses'/libvaxis' internal emit** was not read from
  source this run; the recommended `appendSGR` is the standard, widely-correct subset
  (bold/italic/underline/reverse + truecolor fg/bg). If the project needs 256-color or
  named-color modes, that mapping should be added.
- **Terminal-specific quirks** (e.g. macOS Terminal.app's historical oddities with
  `?1049`, or mlterm's wide-char handling) are not enumerated; if a specific target
  terminal is in scope, it should be tested directly.
- **Suggested next step:** if a search-capable pass is available, fetch the xterm ctlseqs
  page and the libvaxis `Loop.zig`/rendering source to (a) lock in the exact SGR/DEC-mode
  anchors and (b) confirm libvaxis' spacer-skip + single-write implementation as a
  reference implementation.

---

## Supervisor coordination
Notified supervisor of task start (progress_update). No blocking decision required — this
is a self-contained research brief written to the authoritative output path. Returning
the result for review.
