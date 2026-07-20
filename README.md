# tmux-2html

Capture a tmux pane to a standalone, color-faithful HTML document.

tmux-2html reads the ANSI-colored output of a tmux pane and renders it to a
self-contained HTML file that preserves the terminal colors. The file opens in
a browser, so you can share, archive, or screenshot a pane without an external
screenshot tool.

Every capture is a complete, valid HTML5 document — a single
`<!DOCTYPE html>`…`</html>` with a `<head>` (charset, viewport, and an
HTML-escaped `<title>`) and a `<body>` whose page background matches the
terminal's, so it opens cleanly in any browser with no wrapping page.
Every user-supplied string that reaches the HTML — the document `<title>`
and the CSS `font-family` set by `--font` / `@tmux-2html-font` — is
HTML-escaped, so a crafted value can never inject markup, attributes, or
scripts into a capture you share.

## Capture modes

tmux-2html offers three capture modes:

- **Full pane.** Captures the entire scrollback plus the visible rows. Use this
  to render everything the pane has produced.
- **Visible pane.** Captures only the rows currently shown in the pane.
- **Region.** Opens a copy-mode-style, pane-anchored overlay over the scrollback
  (sized to the current pane — size the pane first to control the rendered width)
  and lets you select a line range or a block to render.

## Requirements

- **tmux >= 3.3.** The region overlay is a borderless, pane-anchored
  `display-popup` (`-B` plus pane-positioned `-x`/`-y`), and those flags need
  tmux 3.3. (`display-popup` itself is 3.2, and the one-time palette sync popup
  uses only that — but the version floor follows the region overlay's flags.)
- **Zig 0.15.2** is required only to build from source. Runtime users do not
  need Zig; the plugin fetches a prebuilt binary on first load.
- **`xdg-open`** is optional. It auto-opens the HTML file after writing when
  `@tmux-2html-open` is `on` (the default).

Platforms: Linux and macOS, on x86_64 and arm64. There is no native Windows
build; run it under WSL.

## Installation

### With TPM (recommended)

Add the plugin to `~/.tmux.conf`. The `@plugin` line must appear before the TPM
`run` line, because TPM parses the plugin list when `run` executes:

```tmux
# list of plugins
set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'tmux-2html/tmux-2html'

# initialize TPM (keep at the bottom of ~/.tmux.conf)
run '~/.tmux/plugins/tpm/tpm'
```

Reload tmux (`tmux source ~/.tmux.conf`), then press `prefix I` to install.

On first load the plugin obtains its binary automatically. It tries, in order:
a version-matched binary already present, a from-source build (if Zig 0.15.2 is
on `PATH`), then a SHA256-verified prebuilt download. If all three fail it
prints a tmux message.

On the first load it also runs a one-time palette auto-sync popup if no palette
cache exists yet. The popup is brief and non-fatal.

### Build from source or manual binary

To build from source you need Zig 0.15.2:

```sh
git clone https://github.com/tmux-2html/tmux-2html
cd tmux-2html
zig build --release=fast
```

The binary is at `zig-out/bin/tmux-2html`. Put it on `PATH`, or point TPM at it
by setting `@tmux-2html-binary-dir` to the directory that holds the binary.

For a manual install under TPM, drop the binary into the plugin's `bin/`
directory (`~/.tmux/plugins/tmux-2html/bin/`).

## Key bindings

The default bindings are added to the prefix table:

| Key | Action |
|---|---|
| `prefix O` | Capture the full pane. |
| `prefix C-o` | Open the region overlay. |
| *(unbound)* | Capture the visible pane. Bind it by setting `@tmux-2html-visible-key`. |

`prefix C-o` overrides the stock tmux prefix-table `C-o` binding. To keep the
stock binding, set `@tmux-2html-region-key` to a different key, for example
`C-S-o`.

## The region overlay

Press `prefix C-o` to open a pane-anchored, copy-mode-style overlay (sized to
the current pane) over the scrollback. Use the keyboard or the mouse: move the
cursor with the arrow/hjkl keys or by clicking, select a region with `v` /
`Ctrl-v` or by dragging (linewise by default, block with `Alt`), and scroll with
the wheel (or `Ctrl-d` / `Ctrl-u`). Press `Enter` to render the selection to an
HTML file, or cancel with `q`, `Esc`, or `Ctrl-c` (all exit `1`; other control
keys such as `Ctrl-z` are ignored rather than suspending the popup). The in-app
status line lists every key. See [docs/CONFIGURATION.md](docs/CONFIGURATION.md)
for the full key list and behavior.

## Command line

The `tmux-2html` binary has four subcommands. Each accepts `--help` for its
full flag list.

| Subcommand | Description |
|---|---|
| `render` | Read ANSI from stdin, write HTML (core renderer). |
| `pane` | Capture a tmux pane and convert it to HTML. |
| `region` | Interactive copy-mode overlay: select a region, render it. |
| `sync-palette` | Query the terminal palette and cache it. |

Capture the active pane's full scrollback:

```sh
tmux-2html pane --full
```

Render piped ANSI to a file (in a headless/CI context with no
controlling terminal, add `--cols N`):

```sh
tmux-2html render < ansi.txt > out.html
```

Set the document title and language (each subcommand also accepts `--help`):

```sh
tmux-2html render --title "build log" --lang en-US < ansi.txt > out.html
```

Exit codes: `0` success, `1` usage or runtime error, `2` capture or target
error.

## Configuration

tmux-2html reads these `@tmux-2html-*` options. Set them in `~/.tmux.conf`
before the TPM `run` line.

| Option | Default | Meaning |
|---|---|---|
| `@tmux-2html-full-key` | `O` | Prefix key: capture the full pane. |
| `@tmux-2html-region-key` | `C-o` | Prefix key: open the region overlay. |
| `@tmux-2html-visible-key` | *(empty)* | Prefix key: capture the visible pane. Unbound by default. |
| `@tmux-2html-output-dir` | `${XDG_DATA_HOME:-~/.local/share}/tmux-2html` | Where HTML files are written. |
| `@tmux-2html-open` | `on` | Run `xdg-open` on the HTML file after writing. |
| `@tmux-2html-font` | `monospace` | CSS `font-family` in the rendered HTML. |
| `@tmux-2html-history-limit` | `50000` | Max scrollback lines captured per pane. |
| `@tmux-2html-binary-dir` | `$TMUX_2HTML_BIN` | Directory holding the binary. |
| `@tmux-2html-title` | *(empty)* | Document `<title>`. Empty ⇒ the contextual default (`tmux-2html` for `render`; a title including the session name, window id, pane id, and an ISO 8601 timestamp for `pane`/`region`). |
| `@tmux-2html-lang` | *(empty)* | `<html lang>` attribute (BCP-47). Empty ⇒ derived from the locale (`LC_ALL`/`LC_MESSAGES`/`LANG`), falling back to `en`. |

Every capture is a complete HTML5 document (see above). The `<title>` and
`<html lang>` are configurable: set `@tmux-2html-title` /
`@tmux-2html-lang`, or pass `--title` / `--lang` on the command line (the CLI
flags override the options). See [docs/CONFIGURATION.md](docs/CONFIGURATION.md)
for the full options reference, the palette cache, and sync-palette behavior.

## Known limitations

- **Alternate-screen apps.** Applications that switch to the alternate screen
  (nvim, less, and similar) are captured on the normal screen plus scrollback.
  Capturing the alternate screen itself is a future option, not a current mode.
- **Large scrollback cap.** Capture is capped at `@tmux-2html-history-limit`
  lines (default `50000`). When a pane exceeds the cap, tmux-2html truncates
  the capture and prints a status notice.

## License and credits

tmux-2html is MIT licensed, (c) 2026 Dustin Schultz. See [LICENSE](LICENSE).

It builds on two upstream projects, both MIT licensed, whose notices are
retained under [licenses/](licenses/):

- **term2html** ([licenses/TERM2HTML.txt](licenses/TERM2HTML.txt)), (c) 2026
  aarol. The HTML rendering core.
- **ghostty VT** ([licenses/GHOSTTY-VT.txt](licenses/GHOSTTY-VT.txt)),
  (c) 2024 Mitchell Hashimoto, Ghostty contributors. The terminal emulator
  engine used to interpret ANSI sequences.
