# Configuration

## Palette

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

- `tmux-2html sync-palette` queries `/dev/tty` (OSC 4 / 10 / 11) and writes the
  cache (see `--from` and `--force`). Run this wherever you want the palette
  captured; inside tmux it captures the tmux-presented palette, outside tmux the
  outer terminal emulator palette.
- On first plugin load, if no cache exists, tmux-2html auto-syncs once via a
  `tmux display-popup` (a real pty, so OSC works) and then skips re-syncing while
  the cache is present.

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
