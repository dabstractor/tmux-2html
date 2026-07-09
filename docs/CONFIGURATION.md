# Configuration

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

## Options

| Option | Default | Meaning |
|---|---|---|
| `@tmux-2html-full-key` | `O` | Prefix key: capture the full pane (scrollback + visible). |
| `@tmux-2html-region-key` | `C-o` | Prefix key: open the full-screen region overlay (TUI). |
| `@tmux-2html-visible-key` | *(empty)* | Prefix key: capture the visible pane only. Unbound by default. |
| `@tmux-2html-output-dir` | `${XDG_DATA_HOME:-~/.local/share}/tmux-2html` | Directory where rendered HTML files are written. |
| `@tmux-2html-open` | `on` | If `on`, run `xdg-open` on the HTML file after writing it. |
| `@tmux-2html-font` | `monospace` | CSS `font-family` used in the rendered HTML. |
| `@tmux-2html-history-limit` | `50000` | Maximum number of scrollback lines captured per pane. |
| `@tmux-2html-binary-dir` | `$TMUX_2HTML_BIN` | Directory containing the `tmux-2html` binary. |

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

The cache can be populated manually — via `tmux-2html sync-palette` (see the
sync-palette documentation for `--from` and `--force`) — or automatically, once, by
the plugin's auto-sync popup on first load when no cache exists.

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
palette query fails, the loader simply continues and rendering falls back to the
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
