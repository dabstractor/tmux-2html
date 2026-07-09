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

### sync-palette

`tmux-2html sync-palette` captures a terminal palette and writes the cache. It is
the command you run once so that later `render` / `pane` runs produce HTML that uses
your real terminal colors, even from a tty-less `run-shell` context.

```
Usage: tmux-2html sync-palette [options]

Options:
  --from source       tty (default) | file PATH
  --force             re-query even if a cache exists
  --help              show this help

Exit codes: 0 success, 1 usage/runtime error, 2 capture/target error.
```

- **`--from tty`** (the default) queries `/dev/tty` using OSC 4 (256-color palette)
  and OSC 10 / 11 (foreground / background), then writes the cache. This needs a
  controlling terminal: it works interactively and inside a `tmux display-popup`
  (a real pty), but fails under `tmux run-shell`, cron, or behind a pipe.
- **`--from file PATH`** imports a palette from a plain-text file in the same
  format as the cache (see [Format](#format)). This is how you seed the cache on a
  headless or CI box: capture a palette on an interactive machine, copy the file
  over, and run `sync-palette --from file`. Relative paths resolve against the
  current directory; absolute paths are accepted.
- **`--force`** re-acquires the palette and overwrites the cache even when one
  already exists. Without `--force`, an existing cache is left untouched and
  `sync-palette` prints `palette cache already exists at <path>; use --force to
  re-query` without touching `/dev/tty`.

**Exit codes:**

- `0` — the cache was written, or a cache already existed and was skipped (no
  `--force`).
- `1` — runtime error: an unreadable, missing, or malformed `--from file` path;
  the cache directory could not be determined or written (`$HOME` unset, permission
  error).
- `2` — capture/target error: `--from tty` was used but the terminal could not be
  queried (no controlling tty, or the terminal did not respond). This is the code
  to expect under `tmux run-shell` or any tty-less context.

**Partial responses.** Many terminals answer only the first 16 colors and return
defaults or silence for the 216-cube and grayscale range. `sync-palette` treats a
partial response as success: it warns (to stderr) that fewer than 256 colors were
captured, backfills the missing indices from the bundled default palette, writes
the cache, and exits `0`. A count below 256 is normal, not a failure.

#### Inside tmux vs. outside tmux

Run `tmux-2html sync-palette` from **inside** the tmux session whose captures
you're generating. It queries the palette exactly as tmux presents it to panes,
which is the palette your captures are rendered against, so it produces the closest
color match. If you run it **outside** tmux (directly in your terminal emulator),
you capture the emulator's own palette instead; the two can differ when tmux
applies `terminal-overrides`, a custom `default-terminal`, or RGB features. When in
doubt, run it inside tmux.

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
