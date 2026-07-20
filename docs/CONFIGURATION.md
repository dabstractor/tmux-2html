# tmux-2html configuration & reference

tmux-2html is configured entirely through tmux user options, named
`@tmux-2html-*`. Set them in `~/.tmux.conf` with
`set -g @tmux-2html-<name> "value"` **before** the TPM run line:

```tmux
# ~/.tmux.conf
set -g @tmux-2html-font "Fira Code"
set -g @tmux-2html-region-key "C-S-o"

# ... then ...
run '~/.tmux/plugins/tpm/tpm'
```

Options are read when the plugin loads (TPM sources `tmux-2html.tmux`), so
changing an option and reloading tmux (`prefix r` / `tmux source-file ~/.tmux.conf`)
applies it. An unset option falls back to its default — you only need to set the
ones you want to change.

## Overview

This document is the reference for configuring and using tmux-2html. It covers:

- **Options** — the ten `@tmux-2html-*` tmux user options and their defaults.
- **The region overlay** — the interactive copy-mode TUI (`prefix C-o`): its
  movement keys, search, selection, confirm/cancel flow, and status line.
- **Palette cache** — how your terminal palette is captured, cached, and consumed.
- **The sync-palette command** — `--from`, `--force`, and its exit behavior.
- **Known limitations** — huge scrollback, alt-screen apps, wide characters,
  OSC 8 hyperlinks, offline failure, and the region-overlay search limitation.
- **Attribution & license** — the project license and upstream notices.

For installation and a feature overview, see the `README.md`.

## Options

| Option | Default | Meaning |
|---|---|---|
| `@tmux-2html-full-key` | `O` | Prefix key: capture the full pane (scrollback + visible). |
| `@tmux-2html-region-key` | `C-o` | Prefix key: open the region overlay (TUI) — a pane-anchored popup sized to the current pane (§7.0). |
| `@tmux-2html-visible-key` | *(empty)* | Prefix key: capture the visible pane only. Unbound by default. |
| `@tmux-2html-output-dir` | `${XDG_DATA_HOME:-~/.local/share}/tmux-2html` | Directory where rendered HTML files are written. |
| `@tmux-2html-open` | `on` | If `on`, run `xdg-open` on the HTML file after writing it. |
| `@tmux-2html-font` | `monospace` | CSS `font-family` used in the rendered HTML. The value is HTML-escaped when emitted into the `style` attribute, so a font name containing `"` or other markup characters cannot inject attributes or scripts. |
| `@tmux-2html-history-limit` | `50000` | Maximum number of scrollback lines captured per pane. |
| `@tmux-2html-binary-dir` | `$TMUX_2HTML_BIN` | Directory containing the `tmux-2html` binary. |
| `@tmux-2html-title` | *(empty)* | Document `<title>`. Empty ⇒ the contextual default (`tmux-2html — <session>/<window>.<pane> <iso8601>` for `pane`/`region`; `tmux-2html` for `render`). |
| `@tmux-2html-lang` | *(empty)* | `<html lang>` attribute (BCP-47 tag). Empty ⇒ locale-derived, fallback `en`. |

> **`C-o` key-conflict note.** `C-o` is already used in the stock tmux prefix
> table (bound to `rotate-window`; in some configs to a debug `display-message`).
> Setting `@tmux-2html-region-key C-o` (the default) **overrides** that binding.
> To preserve the existing `C-o` binding, choose a different key, for example:
>
> ```tmux
> set -g @tmux-2html-region-key "C-S-o"
> ```
>
> Likewise, `@tmux-2html-visible-key` is empty by default, so visible-only
> capture is unbound until you explicitly set it, e.g.
> `set -g @tmux-2html-visible-key "v"`.

### HTML output (§8.1)

Every capture — `render`, `pane`, and `region` alike — is a **complete, valid HTML5 document**
(`<!DOCTYPE html>` … `</html>`), never a bare `<pre>` fragment. The document's `<title>` and
`<html lang>` come from `@tmux-2html-title` and `@tmux-2html-lang`: set them and every generated
page reflects them; leave them empty for the contextual title and locale-derived language.

## How options are read

The loader reads each option with `tmux show-option -gqv @tmux-2html-<name>`. An
unset option prints nothing and falls back to the default above; a set option is
used verbatim (spaces preserved, so fonts like `"Fira Code"` work).

The pane and region commands re-read `@tmux-2html-output-dir`,
`@tmux-2html-history-limit`, `@tmux-2html-open`, and `@tmux-2html-font`
themselves at runtime via `tmux show-option`, so you do not pass them on the
command line — setting the option in `~/.tmux.conf` is enough. The loader
exports the resolved values only to drive key-resolution and the sibling binding
and auto-sync tasks; they are not propagated to `run-shell` children.

The `@tmux-2html-title` and `@tmux-2html-lang` options are the exception: the plugin bakes them
into the key bindings as `--title`/`--lang` flags (above), so the binary receives them directly
rather than re-reading them. You can also pass `--title`/`--lang` yourself when running the
binary standalone. Values containing special characters (including apostrophes) are POSIX
shell-escaped in the generated bindings, so a title like `Bob's pane` is safe.

Passing `--lang ""` (an explicit empty string) is treated the same as omitting the flag: the
`<html lang>` value is derived from your locale (`LC_ALL` → `LC_MESSAGES` → `LANG`), falling back
to `en`. (An explicit non-empty value that fails to parse as a BCP-47 tag — e.g. `C` — still falls
back to `en`.)

## The region overlay

`prefix C-o` (the `@tmux-2html-region-key`) opens the region overlay: a
pane-anchored, borderless `tmux display-popup` sized to exactly overlay the
source pane (`#{pane_width}`×`#{pane_height}`; §7.0), running `tmux-2html region`. The overlay first
captures the pane's **full scrollback** (honoring `@tmux-2html-history-limit`),
so you browse all history, not just the visible rows. The cursor starts on the
**last** row, like tmux copy-mode.

Confirming a selection renders it to an HTML file (and honors
`@tmux-2html-open`). Canceling exits with no output.

### What you see

The overlay paints the captured grid in full color, with the **cursor shown as a
reverse-video block** (like tmux copy mode) so you can always see where you are —
even before starting a selection — and a status line on the bottom row. The status
line has the exact format:

```
[LINE|BLOCK]  row:N col:M  /pattern  N match(es)  v=sel C-v=block o=swap  Enter=render q=quit
```

- `[LINE]` or `[BLOCK]` — the selection mode tag. **Omitted entirely when nothing
  is selected.**
- `row:N col:M` — the 1-based cursor position.
- `/pattern  N match(es)` — shown only when a search pattern is active; `N` is
  the number of matches.
- `v=sel C-v=block o=swap` — always shown; press `v` to start/re-anchor a
  linewise selection, `Ctrl-v` to toggle visual block mode, `o` to swap the
  cursor to the other end of the selection (see Selection below).
- `Enter=render q=quit` — always shown.

For example, with nothing active the status line is
`row:1 col:1  v=sel C-v=block o=swap  Enter=render q=quit`.

### Movement

| Key | Action |
|---|---|
| `h` `j` `k` `l`, arrow keys | move one cell left/down/up/right |
| `w` `b` `e` | next/previous word, end of word (two-class WORD — see note) |
| `0` `^` `$` | line start / first non-blank / line end |
| `gg` / `G` | top / bottom of scrollback |
| `Ctrl-d` / `Ctrl-u` | half-page down / up |
| `Ctrl-f` / `Ctrl-b` (or `PgDn` / `PgUp`) | full-page down / up |
| `H` `M` `L` | viewport top / middle / bottom |
| `{` `}` | previous / next blank line |
| `%` | matching bracket (`()`, `[]`, `{}`) |

Counts work: `5j` moves down five rows, `10G` goes to row 10, `2$` moves down
then to the end of that line. A leading `0` is *line start*, not a count — only
a digit that follows another digit extends the count.

> **Word-motion note.** Word motions use a two-class WORD model: a "word" is a
> maximal run of non-whitespace (like vim `W` / `B` / `E`, not vim `w` / `b` /
> `e`). So `foo.bar` is one word; `w` jumps over it whole.

### Search

`/` searches forward, `?` searches backward, and `n` / `N` jump to the
next / previous match (wrapping around the scrollback). Matches are highlighted
in reverse video. `Esc` cancels a half-typed pattern.

Search is **fixed-string and case-sensitive** — it is not regex, and it is not
configurable. Type `/pattern` then `Enter`; `n` and `N` move between the
literal matches.

### Selection

| Key | Action |
|---|---|
| `v` | begin / **re-anchor** a linewise selection at the cursor (discards any prior selection; the only way to move the starting line) |
| `V` | linewise alias of `v` (re-anchor) |
| `Ctrl-v` (or `R`) | begin a block selection; if one is already active, toggle linewise ↔ block (rectangle-toggle, as in tmux) |
| `o` | swap the cursor to the other end of the selection |
| `O` | same as `o` in v1 (block-corner distinction is not modeled) |
| `Esc` | clear the selection and stay in the overlay |
| `q` / `Ctrl-c` | cancel and exit |

Movement extends the active selection (the anchor stays fixed; the cursor
follows). `Esc` with no active selection also cancels and exits.

### Confirm and cancel

**Confirm** — `Enter` (or `y`) renders the current selection to an HTML file,
writes a `.last-output` sidecar next to the binary (so the plugin can flash the
output path), honors `@tmux-2html-open`, and exits `0`. Confirming with **no
selection, or a selection whose rendered body is empty (e.g. a selection
covering only blank cells — a trailing blank line)** prints a warning, writes
**no file and no `.last-output` sidecar**, and exits `1`.

**Cancel** — `q`, `Ctrl-c`, or `Esc` with no selection exits `1` and produces no
output. `Ctrl-c` cancels like the other keys (exit `1`, not a signal death), and
`Ctrl-z` is ignored — it does not suspend the popup. (An explicit `--output`
overrides the default `<session>-<unixtime>-<pid>.html` filename; see
[Known limitations](#known-limitations) for the concurrent-run naming.)

### Mouse

The overlay supports the mouse (it enables SGR mouse reporting on entry),
matching tmux copy-mode:

- **Click** moves the cursor to the clicked cell and clears any active
  selection. A click with no drag leaves no selection, so confirming right
  after a click behaves like "no selection".
- **Drag** selects: press and drag to extend a selection from the press cell to
  the cursor. Dragging is **linewise** by default; hold **`Alt`** (or toggle it
  mid-drag) for a **block** selection.
- **Wheel** scrolls the viewport by half a page (like `Ctrl-d` / `Ctrl-u`) and
  keeps the cursor in view.

Mouse input is ignored while you are typing a search pattern. There is no
option to enable or disable the mouse — it is always on, like the keyboard.

## Palette cache

tmux-2html renders using the terminal palette you actually have, even when there is
no controlling terminal (the `run-shell` plugin flow). It caches your palette to a
plain-text file so it survives across runs.

### Cache location

```
${XDG_CACHE_HOME:-$HOME/.cache}/tmux-2html/palette
```

`XDG_CACHE_HOME` is honored only when it is set, non-empty, **and** absolute. An
empty or relative value falls back to `$HOME/.cache`, per the
[XDG Base Directory Specification](https://specifications.freedesktop.org/basedir-spec/latest/).

### Format

The file is plain text and human-debuggable. A full file is 258 lines:

```
# tmux-2html palette (queried 2026-07-08T14:30:00Z)
fg 255 255 255
bg 41 44 51
0 0 0 0
1 204 66 66
…
255 238 238 238
```

- Line 1: a header comment (`# …`) recording when the palette was captured, as an
  ISO 8601 / RFC 3339 UTC timestamp. Ignored on read.
- Lines 2-3: `fg R G B` and `bg R G B`, the terminal foreground and background.
- Lines 4-259: `i R G B` for each palette index `0` through `255`. Each `R G B` is
  a decimal byte (0-255).

Every component is a decimal integer separated by spaces, so you can `grep`, `sed`,
or hand-edit the file.

### How it is populated

The cache can be populated manually — via `tmux-2html sync-palette` (see
[The sync-palette command](#the-sync-palette-command) for `--from` and
`--force`) — or automatically, once, by the plugin's auto-sync popup on first
load when no cache exists.

#### Palette auto-sync (first load)

On the first plugin load, if no palette cache exists, tmux-2html opens a short
`tmux display-popup` (a real terminal/pty, roughly 50% × 50% of the client) that
runs `sync-palette` once and then closes. Subsequent loads skip the popup as long
as the cache is present, so you normally never see it.

The popup exists because the pane/region capture commands run through
`tmux run-shell`, which has **no controlling terminal**, so an OSC palette query
cannot work there. `display-popup` allocates a real pty where `sync-palette`'s OSC
4 / 10 / 11 queries succeed — that pty is the whole reason the auto-sync uses a
popup rather than a plain `run-shell`.

The auto-sync is **non-fatal**: if the popup cannot open (an older tmux without
`display-popup`, a headless or detached session with no attached client) or the
palette query fails, the loader continues and rendering falls back to the
bundled default palette. It never blocks or breaks your tmux. If you want a real
palette on such a box, run `tmux-2html sync-palette --from file` manually (seed
the cache from a file captured on an interactive machine).

#### Inside tmux vs. outside tmux

The auto-sync popup runs **inside** tmux, so it captures the palette that tmux
*presents* to panes — which is the palette your captures are rendered against, so
it produces the closest color match.

Running `tmux-2html sync-palette` **outside** tmux (directly in your terminal
emulator) captures the outer terminal emulator's own palette instead. The two can
differ when tmux applies `terminal-overrides`, a custom `default-terminal`, or RGB
features. When in doubt, let the auto-sync run inside tmux, or run `sync-palette`
from inside the tmux session whose captures you are generating.

### How it is consumed

Render precedence for `--palette` (default chain `cached → live → default`):

1. `cached` — read the cache if present.
2. `live` — query `/dev/tty` (only when a controlling terminal exists; never in
   `run-shell`).
3. `default` — the bundled Ghostty 256-color palette (last resort).

### Hand-editing

The file is plain text. You can delete or edit individual lines freely. Missing
entries fall back to the bundled default palette, so a partial file still renders.
A line that looks like a data line but does not parse (non-numeric field, wrong
field count, palette index greater than 255) is rejected; everything else is
tolerated.

## The sync-palette command

`tmux-2html sync-palette` captures the terminal palette and writes it to the
[Palette cache](#palette-cache). Its flags:

| Flag | Default | Meaning |
|---|---|---|
| `--from tty` | *(default)* | Query OSC 4 / 10 / 11 against `/dev/tty` and cache the result. |
| `--from file PATH` | — | Seed the cache from a palette file at `PATH` instead of querying a terminal. |
| `--force` | `false` | Re-query even when a cache already exists. Without `--force`, an existing cache is left untouched. |

### Exit behavior

`sync-palette --from tty` opens `/dev/tty` and reads the OSC responses with a
roughly 500 ms per-batch timeout. The two failure outcomes differ:

- **Exit `2`** when `/dev/tty` cannot be opened or its termios cannot be set
  (there is no controlling terminal — for example, when `sync-palette` is invoked
  under `tmux run-shell`). This is a hard failure; no cache is written.
- **Exit `0`** when `/dev/tty` opens but the terminal does not answer within the
  timeout (a silent-but-open terminal). In this case the cache is still written,
  seeded from the bundled default palette, and `sync-palette` logs a warning with
  how many of 256 entries were actually received (e.g. `0/256`).

So a non-zero exit means "I had no terminal to query at all," not "the terminal
was slow." The latter is treated as success with a default-seeded cache and a
warning. (This is why the plugin's auto-sync popup can run in any attached
client: a silent terminal still yields a usable cache.)

`--from file PATH` exits `1` with `error: cannot read palette file '<path>'` if
the file cannot be read; otherwise it seeds the cache and exits `0`.

For the cache location and file format, see [Palette cache](#palette-cache).

## Known limitations

- **Huge scrollback.** Capture is capped at `@tmux-2html-history-limit` (default
  `50000`). The tighter of `--history` and the option wins. When capture is
  truncated, tmux-2html prints a notice on stderr (and, best-effort, on the tmux
  status line when a client exists): `tmux-2html: capture truncated to <N>
  history lines (pane had <M>); older output dropped`.
- **Alternate-screen apps (nvim, less).** Capture targets the **normal screen and
  scrollback only** (`tmux capture-pane` without `-a`). The live alternate-screen
  UI is not captured. Alternate-screen capture is a future option, not currently
  shipped.
- **Empty selection.** Confirming an empty selection — **no selection begun, or
  an active selection whose rendered body is all blank cells** (e.g. a single
  trailing blank line, or an empty rectangle) — warns, writes no file and no
  `.last-output` sidecar, and exits `1`. Both `render --selection` and `region`
  guard this by checking the rendered body, so the two paths agree.
- **Wide characters, grapheme clusters, and emoji.** Cell widths come from the
  ghostty VT engine (via the vendored formatter). Selection rounds to cell
  boundaries, so a wide cell (e.g. 真, many emoji) is selected and emitted as a
  unit — never split or doubled. tmux-2html adds no width or grapheme logic of
  its own.
- **OSC 8 hyperlinks.** Terminal hyperlinks (OSC 8) are preserved and become
  `<a>` links in the HTML, via ghostty-vt.
- **Binary acquisition failures (checksum mismatch / offline).** If the release
  download fails its SHA256 check, or there is no network, the download fails
  loudly with an instruction to install Zig and rebuild, or place a binary
  manually. The loader then flashes `tmux-2html: install failed (see README)`.

- **Region overlay: search is fixed-string, case-sensitive.** There is no regex
  search and no case-insensitive option in v1.
- **Concurrent runs.** Output filenames are `<session>-<unixtime>-<pid>.html`
  (session name, Unix timestamp, and process id), so parallel captures in the same
  session do not collide. An explicit `--output` overrides the auto-generated
  name.

## Attribution & license

tmux-2html is **MIT-licensed** — see [LICENSE](../LICENSE), © 2026 Dustin Schultz.

It incorporates code from two upstream MIT-licensed projects, whose notices are
retained under `licenses/`:

- **term2html** — the HTML rendering logic tmux-2html absorbs. © 2026 aarol. See
  [licenses/TERM2HTML.txt](../licenses/TERM2HTML.txt).
- **ghostty VT engine** — the terminal model tmux-2html depends on for cell
  widths, grapheme handling, and OSC 8 hyperlink rendering. © 2024 Mitchell
  Hashimoto, Ghostty contributors. See
  [licenses/GHOSTTY-VT.txt](../licenses/GHOSTTY-VT.txt).

No proprietary code is included. The `README.md` credits both upstreams.
