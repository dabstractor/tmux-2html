# tmux-2html — Product Requirements & Technical Specification

> Source-of-truth document. Intended to be decomposed into a task breakdown for
> implementation. Every interface, path, flag, and algorithm below is
> normative unless explicitly marked otherwise.

---

## 0. ⚠️ CRITICAL SAFETY RULE — READ BEFORE IMPLEMENTING OR TESTING

tmux-2html runs **inside the user's live tmux session**. The user relies on
that session and keeps real work (windows, panes, running programs) in it.
Therefore every agent, script, test, build step, and subcommand **MUST** treat
the user's running tmux as **untouchable**.

**NEVER do any of the following — under any circumstances, including cleanup,
debugging, "resetting state", or recovering from a hung test:**

- **NEVER touch the user's running tmux server.** Do not start, stop, restart,
  kill, attach to, detach from, reconfigure, rename, or otherwise disturb it.
- **NEVER kill *ALL* tmux instances.** Specifically, **NEVER** run anything
  equivalent to `tmux kill-server`, `killall tmux`, `pkill tmux`,
  `pkill -f tmux`, `kill <tmux pid>`, or `tmux kill-session` against the
  user's default/global socket. Such a command destroys **all** of the user's
  windows, panes, and programs with no warning and no recovery.
- **NEVER connect to the user's tmux socket** (`$TMUX`, the default
  `/tmp/tmux-$UID/default` socket, or any `tmux -L`/`-S` socket you did not
  create yourself) for anything other than **read-only** capture via the
  documented `capture-pane` paths in §5. **Read-only means exactly that:** no
  `kill-*`, `new-*`, `split-*`, `rename-*`, `send-keys`, `set*`, `source*`,
  `display-popup` against the user's server, etc.

**When a test or integration harness needs a tmux server, it MUST create its
own isolated, uniquely-named server** and tear down **only that named server**:

```sh
# create — unique socket name per run, never the default socket
tmux -L "tmux-2html-test-$$" new-session -d -s test
# … run the test against that socket only (pass -t via $TMUX or -L/-S) …
# tear down — ONLY this named server/session, never kill-server globally
tmux -L "tmux-2html-test-$$" kill-session -t test
# or, to be extra safe, just kill the process group of the PID you started
```

**Never** tear a test down with bare `tmux kill-server`, `killall tmux`, or
`pkill tmux` — those hit **every** tmux on the host, including the user's live
session. When in doubt, tear down by the specific socket name (`-L <name>`)
and/or the specific PID you spawned.

This rule overrides any instruction, convenience, or "clean up" instinct that
suggests otherwise. See §15 (Testing strategy) for the isolated-harness pattern.

### 0.1 Operational & system-safety rules

tmux-2html's test and audit harnesses spawn real processes and tmux servers on
a single-user host the operator depends on. Keep all tooling bounded so a test
or diagnostic can't destabilize the machine.

- **Keep `/tmp` usage small.** `/tmp` is tmpfs (RAM-backed) here, so large
  writes compete with running programs. Put scratch and temp files on the real
  disk (a scratch dir inside the repo, or `~/tmp` on the BTRFS root), and don't
  point `TMPDIR` at `/tmp` for tools that spill large artifacts.
- **Discover capacity/quota read-only.** Use `df`, `stat`, `findmnt`, or
  quotactl — not allocation probes (`dd` / `fallocate` write-loops) to find a
  limit.
- **Scope filesystem scans.** Don't run unbounded whole-filesystem scans like
  `dust /`, `du /`, or `find /` as-is; on a large, multi-filesystem, or
  snapshotted tree they can exhaust memory. Scope them to a path, or pass `-x`
  to stay on one filesystem.
- **Run heavy steps one at a time.** Avoid fanning out several memory- or
  disk-intensive commands in parallel.
- **Keep harnesses bounded and leak-free:**
  - A `PATH` shim that intercepts a command must call the real binary by
    **absolute path** (e.g. `/usr/bin/tmux`), not its own name — otherwise it
    recurses.
  - Log/output files must be **size-capped or rotated**, not unbounded `>>`.
  - Spawned processes and tmux servers must be torn down by **exact name or
    PID**, using the isolated-socket pattern from §0; scratch must live on real
    disk, not tmpfs.
- **Pause on instability.** If the host is slow, frozen, or otherwise
  misbehaving, stop and confirm with the operator rather than pushing through.

Prefer reading source statically over instrumented runtime harnesses when
possible.

---

## 1. Overview

**tmux-2html** captures the contents of a tmux pane — visible, full scrollback,
or a user-selected region — and renders it to a standalone HTML document that
faithfully reproduces terminal color: 16-color palette, 256-color, 24-bit
truecolor, all text attributes (bold/italic/underline/strikethrough/reverse),
and OSC 8 hyperlinks.

It is distributed as a **TPM (Tmux Plugin Manager) plugin** backed by a single
self-contained **Zig binary** that does capture, an interactive copy-mode-style
selection UI, and ANSI→HTML rendering (reusing the Ghostty VT engine).

### 1.1 Goals
- Three capture modes, all color-preserving:
  1. **Full pane** — entire scrollback + visible content.
  2. **Visible pane** — only the currently visible rows.
  3. **Region** — an interactive, copy-mode-style UI rendered at the **pane's
     own size** over the full scrollback; user selects a **line range or a
     rectangle/block** and renders exactly that. The overlay is sized and
     positioned to exactly match the source pane (§7), never a forced
     fullscreen view — the user controls the rendered width by sizing the pane
     first.
- Output to stdout, a file, and/or auto-open in a browser.
- Real terminal palette fidelity (term2html-equivalent), via a cached palette so
  it works inside tmux bindings where no controlling terminal exists.
- Installable via TPM with zero manual binary steps for end users.
- Every output is a **complete, valid HTML5 document** — it begins with
  `<!DOCTYPE html>`, has a single `<html>` root, a `<head>` (charset, viewport,
  title), and a `<body>` wrapping the rendered terminal. Never a bare fragment;
  see §8.1 ("no cutting corners on the HTML doc").

### 1.2 Non-goals (v1)
- Replacing tmux's built-in copy mode for yanking text.
- Streaming/capturing live output as it arrives (one-shot snapshots only).
- Windows native support (WSL is fine because it is Linux).

## 2. Background & key technical findings

These are established facts, verified during research, that constrain the design.

1. **`tmux capture-pane -e -p`** re-emits the pane's full ANSI state (SGR colors,
   attributes, OSC 8) from tmux's internal cell grid, including scrollback via
   `-S - -E -`. Verified for 16/256/truecolor, hyperlinks. This is the capture
   source for every mode.
2. **No controlling terminal in bindings.** A tmux binding runs its command via
   `run-shell`, whose process has no `/dev/tty`. Anything that queries the
   terminal at runtime (palette via OSC, size via `ioctl(TIOCGWINSZ)`) fails
   there. `$TMUX` and `$TMUX_PANE` **are** set for `run-shell` children.
3. **Size must be explicit.** The renderer rebuilds a virtual terminal of a
   given size from the ANSI stream; defaulting to 80×150 mis-wraps wide panes.
   Pane geometry is read from `#{pane_width}`/`#{pane_height}` and passed in.
4. **The Ghostty VT formatter already supports rendering a selection.**
   `ghostty_format.ScreenFormatter.content.selection` accepts a `Selection`
   (start/end x/y, inclusive) with a rectangle flag, and emits exactly those
   cells as HTML. Both **line-range** (full-width cell range) and **block**
   (rectangle) rendering are built in. Reference: `ghostty_format.zig`
   (Selection import, `content.selection`, rectangle handling).
5. **tmux copy-mode selection formats are unusable for this** (`selection_*_y`
   don't track the live selection; `copy_cursor_line` returns text, not a
   number; origins don't map to `capture-pane -S/-E`). Therefore tmux-2html
   **owns its coordinate system**: it captures the full scrollback, loads it
   into its own VT grid, and the user selects on **that grid**. Selection
   indices map exactly to rendered output. No coordinate bridge to tmux.
6. **Palette layering under tmux.** Inside tmux, `/dev/tty` is tmux's pty, so
   an OSC palette query returns tmux's palette (what the user's theme/tmux
   configures), not the outer terminal emulator's. The palette to capture is a
   user choice; default is the tmux-presented palette.
7. **An external TUI cannot truly take over a pane; a pane-anchored
   `display-popup` is the faithful host.** tmux copy mode is compiled into the
   server (`window-copy.c`, `mode-tree.c`) and renders into the pane's
   server-owned grid — there is **no** plugin or external API to register a
   new pane/client mode. The pane's pty slave is owned by the program running
   in it, and the only takeover primitives (`respawn-pane`, `kill-pane`)
   destroy that program (forbidden by §0); `pipe-pane` is output-only (no
   input, no terminal surface). Therefore the region TUI runs in a
   `display-popup` **sized and positioned to exactly overlay the source pane**
   — same width/height, same left/top — so content renders 1:1 at the
   size/position the user sees, and when the popup closes the original pane
   (and its program) is untouched beneath. Requires `tmux ≥ 3.3` (`-B`
   borderless popup + pane-anchored `-x`/`-y`); see §7 for the verified
   invocation.

## 3. Architecture

```
┌────────────────────────── TPM plugin (shell) ──────────────────────────┐
│  tmux-2html.tmux  →  sets options, binds keys, ensures binary present  │
│  scripts/ensure_binary.sh  →  build-from-source  ─┐                    │
│                            →  download prebuilt  ─┘ (fallback)         │
└───────────────┬───────────────────────────────────────────────────────┘
                │ invokes
┌───────────────▼─────────── Zig binary: tmux-2html ─────────────────────┐
│  Subcommands: render | pane | region | sync-palette                    │
│                                                                        │
│  capture.zig   ─ tmux capture-pane -e (shells out via $TMUX)           │
│  palette.zig   ─ OSC query + XDG cache (absorbed from term2html)       │
│  render.zig    ─ ghostty-vt grid → HTML (absorbed term2html formatter) │
│  tui/          ─ pane-anchored copy-mode overlay (select line/block)   │
└────────────────────────────────────────────────────────────────────────┘
```

Three capture paths share `capture → grid → render`:
- **Full / Visible pane:** capture → grid (whole) → render whole → HTML.
- **Region:** capture full scrollback → grid → **TUI selects a sub-grid** →
  render that selection → HTML.

## 4. Repository layout

```
tmux-2html/
├── PRD.md                       # this document
├── README.md
├── LICENSE                      # MIT (project)
├── licenses/                    # upstream notices (retained per MIT)
│   ├── TERM2HTML.txt            # © 2026 aarol
│   └── GHOSTTY-VT.txt           # © Mitchell Hashimoto / Ghostty contributors
├── build.zig
├── build.zig.zon                # deps: ghostty (VT), parg, simdutf, …
├── src/
│   ├── main.zig                 # entry; dispatches subcommands
│   ├── cli.zig                  # flags/options parsing
│   ├── capture.zig              # invoke + parse `tmux capture-pane`
│   ├── palette.zig              # OSC 4/10/11 query + cache read/write
│   ├── render.zig               # ANSI → HTML (adapted term2html main/format)
│   └── tui/
│       ├── app.zig              # event loop, raw termios, alt-screen
│       ├── view.zig              # full-repaint VT rendering + status line
│       ├── select.zig           # selection model (linewise/rectangle)
│       └── input.zig            # key decoding (vim + arrows + search)
├── tmux-2html.tmux              # TPM entrypoint (sourced by TPM)
├── scripts/
│   ├── ensure_binary.sh         # build-first / download-fallback
│   └── download.sh              # fetch+verify platform prebuilt
├── testdata/                    # golden *.ansi / *.html pairs
└── .github/workflows/release.yml # 4-platform build/release matrix
```

## 5. The binary — CLI surface

Name: `tmux-2html`. Exit codes: `0` success, `1` usage/runtime error, `2`
capture/target error. `--help` on every subcommand.

### 5.1 `tmux-2html render` — core renderer (stdin → complete HTML5 document)
Reads ANSI from stdin, writes HTML. Used directly for piping and by other
subcommands internally.
```
--cols N           virtual terminal columns (REQUIRED if no tty; = pane width)
--rows N           virtual terminal rows (default: input line count)
--font FAMILY      CSS font-family (default: monospace)
--palette MODE     default | cached | live  (default: cached→live→default)
--output FILE      write here instead of stdout
--open             xdg-open the output (implies --output if none given)
--selection X1,Y1,X2,Y2[,rect]   render only a sub-grid (rect=1 → block)
```
`--selection` exposes the formatter's native selection for scripting/tests.

### 5.2 `tmux-2html pane` — capture a pane → HTML
```
--target PANE      target pane id (default: $TMUX_PANE)
--visible          only the visible rows (default)
--full             entire scrollback + visible (mutually exclusive of --visible)
--history N        with --full, cap scrollback to last N lines (default 50000)
--font FAMILY      CSS font-family
--output FILE
--open
```
Behavior: resolve `#{pane_width}`/`#{pane_height}` for `--target`; run
`tmux capture-pane -e -J -p -t <pane> [-S -N -E - | <none>]`; pipe to the
renderer with explicit cols/rows.

### 5.3 `tmux-2html region` — interactive copy-mode overlay → HTML
```
--target PANE      target pane id (default: $TMUX_PANE)
--font FAMILY
--output FILE
--open
```
Behavior: capture full scrollback (`-S - -E -`, honoring `--history` cap) into
a grid; launch the **region TUI in a popup sized to the pane** (§7); on
confirm, render the current selection (line or block) and emit HTML; on
cancel, exit with no output.

### 5.4 `tmux-2html sync-palette` — query + cache the palette
```
--from source     tty (default) | file PATH
--force           re-query even if a cache exists
```
Queries OSC 4 (palette 0–255), OSC 10 (fg), OSC 11 (bg) against `/dev/tty`
(absorbed term2html `terminal.queryColors`), writes the cache (§6), prints a
summary. Exits non-zero if the terminal doesn't respond within timeout.

### 5.5 `tmux-2html --version` / `--help`

## 6. Palette subsystem

**Cache location:** `${XDG_CACHE_HOME:-$HOME/.cache}/tmux-2html/palette`.
**Format:** plain text, debuggable:
```
# tmux-2html palette (queried <iso8601>)
fg 255 255 255
bg 41 44 51
0 0 0 0
1 204 66 66
…
255 238 238 238
```

**Precedence for rendering** (`--palette` overrides):
1. `cached` — read cache if present.
2. `live` — query `/dev/tty` (only when a controlling terminal exists, e.g. the
   CLI run interactively; never in `run-shell`).
3. `default` — Ghostty bundled palette (last resort).

**Population:**
- `sync-palette` explicit command (run wherever the user wants the palette
  captured; default inside tmux → captures the tmux-presented palette).
- **Auto-sync on first plugin load** if no cache exists: the entrypoint opens a
  `tmux display-popup` (real pty, so OSC works), runs `tmux-2html sync-palette`,
  and closes. This runs once; subsequent loads skip it while the cache exists.
  Document that running `sync-palette` *outside* tmux captures the outer
  terminal emulator palette instead.

## 7. The copy-mode TUI (`tmux-2html region`)

Feels exactly like tmux copy-mode: an overlay **the exact size and position of
the source pane**, not a forced fullscreen view. The TUI runs in a
`display-popup` sized to the pane's width/height and anchored over the pane's
top-left, so the captured content renders 1:1 at the size the user sees.

### 7.0 Host: a pane-anchored popup, and why not the pane itself
An external TUI **cannot** run inside the pane the way built-in copy mode
does. tmux copy/choose/view modes are compiled into the server and render into
the pane's server-owned grid; there is no plugin or external API to register a
new pane/client mode. The pane's pty is owned by the program running in it, and
the only takeover primitives (`respawn-pane`, `kill-pane`) destroy that program
— forbidden by §0. `pipe-pane` is output-only. So the faithful,
non-destructive host is a `display-popup` **sized and positioned to exactly
overlay the pane**; when it closes, the original pane and its program are
untouched beneath.

Verified invocation (flags confirmed against tmux `cmd-display-menu.c` /
`popup.c`, present since **tmux 3.3**):

```sh
tmux display-popup -B -E \
  -w "#{pane_width}" -h "#{pane_height}" \
  -x P -y P \
  -t "#{pane_id}" \
  "$TMUX_2HTML_BIN/tmux-2html region --target #{pane_id} …"
```

- `-w #{pane_width}` / `-h #{pane_height}` — total popup footprint = the pane's
  dimensions (formats; the result is the outer size `pd->sx`/`pd->sy`).
- `-B` — **borderless** (`BOX_LINES_NONE`). With a border the inner pty would
  be footprint-minus-2 (one cell per side lost to the border); borderless makes
  the inner pty the **full** `pane_width × pane_height`. No chrome also matches
  copy mode, which has no border.
- `-x P` / `-y P` — the built-in "anchor to the target pane" position tokens
  (`-x P` → `popup_pane_left` = the pane's left column; `-y P` →
  `popup_pane_bottom`, and `-y` is resolved as the bottom edge then
  `top = bottom − height`, so with `height = pane_height` the popup's top row
  is the pane's top row).
- `-t "#{pane_id}"` — the pane the position tokens are computed against; must
  be the pane being overlaid.

Net effect: the TUI receives a pty of exactly `pane_width × pane_height` at the
pane's exact screen location. The user controls the rendered width/height by
sizing the pane first (zoom it with `resize-pane -Z` for a fullscreen render);
tmux-2html never imposes a wider view than the pane.

### 7.1 Display
- Enter alternate screen (`\e[?1049h`), hide cursor, raw termios (no echo, no
  canonical). Restore on exit (always, including panic).
- Render the captured grid in **full color** using SGR + cursor addressing
  against the cached palette (colors match what the pane shows). Diff-rendering
  for performance on large grids; cap rendered rows to viewport, scroll with
  the cursor.
- **Status line** (last row), copy-mode-style:
  `[LINE|BLOCK]  row:N col:M  /pattern  N match(es)  v=sel C-v=block o=swap Enter=render q=quit`.

### 7.2 Movement (vim + arrows)
`h j k l` and `← ↓ ↑ →`; `w b e`; `0 ^ $`; `g g` / `G`; `Ctrl-d/u` half-page;
`Ctrl-f/b` full-page; `H M L` viewport top/mid/bottom; `{ }` paragraph; `%`
matching. Counts supported (e.g. `5j`).

### 7.3 Search
`/pattern` forward, `?pattern` backward, `n` / `N` next/prev; regex (or
fixed-string, configurable). Matches highlighted in the grid.

### 7.4 Selection — tmux copy-mode parity
Mirrors tmux copy-mode-vi: a selection is owned by a fixed **anchor** (start)
plus the live **cursor** (moving end). Critically, the anchor can be **re-placed
at any time** by moving the cursor and pressing `v` again — this fixes the old
behavior (where `V` locked the starting line until you exited the overlay) and
makes the selection fully re-anchorable, exactly like tmux copy mode.

- `v` — **begin / restart selection** at the current cursor position. Sets the
  anchor to the cursor, (re)enters **linewise** mode (rectangle flag OFF), and
  discards any prior selection. Move the cursor, then press `v` again to
  re-anchor the start of the selection on the new line; repeat freely. This is
  the only way to change the starting line, and it never exits the overlay.
- `Ctrl-v` — **enter visual block (rectangle) mode.** If no selection is
  active, begins a rectangle selection at the cursor; if a selection is active,
  switches it to block mode (anchor + cursor retained). Pressing `Ctrl-v`
  again toggles back to linewise (rectangle OFF) — i.e. rectangle-toggle, as in
  tmux. `Ctrl-v` does **not** re-anchor; use `v` to move the start.
- Movement extends the selection from the anchor to the cursor in the current
  mode (linewise = full-width line range, block = rectangle).
- `o` / `O` swap the cursor to the other end of the selection.
- `Esc` clears the selection (stays in the TUI); `q` quits.
- Familiarity aliases (do not re-anchor on their own — use `v` for that):
  `V` = linewise begin (alias for `v`), `R` = block begin (alias for
  `Ctrl-v`).

**Selection → output mapping (own coordinates, exact):**
- Linewise → formatter `Selection{ start=(0,r1), end=(cols-1,r2), rect=false }`.
- Block    → formatter `Selection{ start=(c1,r1), end=(c2,r2), rect=true }`.
- Coordinates are cell indices in the loaded grid; the formatter emits exactly
  those cells inclusive (§2 finding 4).

### 7.5 Confirm / cancel
- `Enter` (or `y`) → render current selection to HTML (per `--output`/`--open`),
  display the path via tmux message (written to a sidecar file the plugin reads,
  since the popup has no tmux message channel), exit `0`.
- `q` / `Esc` (when no selection) / `Ctrl-c` → exit `1`, no output.

### 7.6 Mouse (supported)
Click to move cursor; drag to select (linewise by default, block with modifier,
e.g. Alt); wheel to scroll.

## 8. Rendering engine (`render.zig`)

Absorbs term2html's approach (`src/main.zig`, `src/ghostty_format.zig`,
`src/terminal.zig`) under `licenses/TERM2HTML.txt`, depending on **ghostty** as
a Zig dependency (`build.zig.zon`).

Pipeline:
1. Create `ghostty_vt.Terminal` sized `cols × rows`.
2. Feed the captured ANSI through a `vtStream` (translate `\n`→`\r\n` as
   term2html does).
3. Resolve palette per §6 precedence.
4. Build `ScreenFormatter` with `background/foreground/palette/font`; set
   `content.selection` (whole grid = `null`, or the user's selection).
5. Emit a **complete HTML5 document** (§8.1) wrapping the rendered `<pre>` to
   stdout/`--output`; `--open` launches `xdg-open`.

All color classes are handled by ghostty-vt: 16 (palette lookup), 256,
truecolor (exact RGB), attributes, and OSC 8 hyperlinks. No bespoke ANSI parser.

### 8.1 HTML document envelope (normative — "no cutting corners")

Every HTML output — from `render`, `pane`, and `region`, **including the
`--selection` and TUI-confirm paths** — MUST be a complete, valid HTML5
document, never a fragment. The absorbed term2html `ScreenFormatter` emits only
the terminal `<pre>` fragment; `render.zig` (or a shared envelope helper)
wraps that fragment in the full document below before writing to
stdout/`--output`. This is the difference between "a `<pre>` blob" and "a
standalone HTML document you can open, share, and trust in any browser."

Required skeleton, in this exact order:

```html
<!DOCTYPE html>
<html lang="<lang>">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title><title></title>
    <style> /* optional: body margin reset; page bg = terminal bg */ </style>
  </head>
  <body>
    <pre class="term2html-output" …>…rendered cells…</pre>
  </body>
</html>
```

Normative requirements:
- **`<!DOCTYPE html>`** is always the first bytes emitted (declares HTML5).
- **`<html>`** is the single root element, carrying a `lang` attribute
  (default `en`; configurable via `@tmux-2html-lang` / locale).
- **`<head>`** contains, at minimum:
  - `<meta charset="utf-8">` — **mandatory and first inside `<head>`**.
    Terminal output is arbitrary Unicode; without an explicit charset the
    browser's encoding sniff can mojibake it. Per the HTML spec the charset
    declaration must appear within the first 1024 bytes, so it precedes
    everything else in `<head>`.
  - `<meta name="viewport" content="width=device-width, initial-scale=1">` —
    so the page reflows readably at any width / on mobile, not just a wide
    desktop window.
  - `<title>` — a meaningful, **HTML-escaped** title. Default form:
    `tmux-2html — <session>/<window>.<pane> <iso8601>` for `pane`/`region`;
    `tmux-2html` (or `--title`) for `render` from stdin. Configurable via
    `--title` / `@tmux-2html-title`.
- **`<body>`** wraps exactly one `<pre>` (the formatter output). The **page
  background matches the resolved terminal background color** (§6) so the
  terminal block does not sit inside a white margin, and default body margin is
  `0` (the `<pre>` owns its own box/padding).
- All text inserted into the envelope (`<title>`, etc.) is HTML-escaped; cell
  text escaping continues to be handled by ghostty-vt as today.
- **No output path emits a bare fragment.** A fragment-only mode (for embedding
  the `<pre>` inside another page) is explicitly out of scope for v1 (see §16);
  the only v1 behavior is a full document.

Verification: the §15 renderer golden tests assert the **full document**
byte-for-byte (`<!DOCTYPE html>` → `</html>`), not just the `<pre>`. The
committed `testdata/*.html` are bare fragments inherited from term2html and
MUST be re-blessed as complete documents when this is implemented.

## 9. tmux plugin

### 9.1 Entrypoint `tmux-2html.tmux`
Sourced by TPM at load. Responsibilities:
1. Resolve `TMUX_2HTML_BIN` (default: `$TMUX_PLUGIN_MANAGER_PATH/tmux-2html/bin`).
2. `run-shell` `scripts/ensure_binary.sh` (§10) if the binary is missing or
   version-stale; on success proceed, on failure `display-message` an error
   with manual instructions and skip binding.
3. Read options (§9.2), bind keys (§9.3).
4. If no palette cache exists, trigger the one-time auto-sync popup (§6).

### 9.2 Options (tmux user options, `@tmux-2html-*`)
| Option | Default | Meaning |
|---|---|---|
| `@tmux-2html-full-key` | `O` | prefix key: full pane (scrollback+visible) |
| `@tmux-2html-region-key` | `C-o` | prefix key: region overlay (TUI) |
| `@tmux-2html-visible-key` | *(empty)* | prefix key: visible pane only (unbound by default) |
| `@tmux-2html-output-dir` | `${XDG_DATA_HOME:-~/.local/share}/tmux-2html` | where HTML files are written |
| `@tmux-2html-open` | `on` | `xdg-open` after writing |
| `@tmux-2html-font` | `monospace` | CSS font-family |
| `@tmux-2html-history-limit` | `50000` | max scrollback lines captured |
| `@tmux-2html-binary-dir` | `$TMUX_2HTML_BIN` | where the binary lives |

> **Key conflict note:** `C-o` is already bound in the live prefix table (to a
> debug `display-message`). Setting `@tmux-2html-region-key C-o` **overrides**
> it. To preserve the old binding, set a different key (e.g. `C-S-o`).

### 9.3 Bindings (prefix table)
- `O`   → `run-shell "$TMUX_2HTML_BIN/tmux-2html pane --full --target #{pane_id} …"`
- `C-o` → `run-shell` a wrapper that launches the **pane-anchored** popup
  (§7.0), sized to the current pane:
  `tmux display-popup -B -E -w "#{pane_width}" -h "#{pane_height}" -x P -y P -t "#{pane_id}" "$TMUX_2HTML_BIN/tmux-2html region --target #{pane_id} …"`
- *(visible key, if set)* → `… pane --visible …`

Bindings pass `--target #{pane_id}`, read output-dir/open/font from options,
and notify via `tmux display-message`. The region path writes the result path
to `$TMUX_2HTML_BIN/.last-output` for the wrapper to `display-message`.

## 10. Binary acquisition (`scripts/ensure_binary.sh`)

Order, per the agreed flipped-hybrid:
1. If `$TMUX_2HTML_BIN/tmux-2html` exists and `--version` matches the plugin →
   done.
2. If `zig` is on PATH → `zig build --release=fast` into the bin dir. On
   success → done.
3. Otherwise (no Zig, or build failed) → `scripts/download.sh`:
   detect `$(uname -sm)` → map to a platform triple → download the matching
   tarball from the latest GitHub release → verify SHA256 against
   `SHA256SUMS.txt` → extract into the bin dir.
4. Any failure → `tmux display-message "tmux-2html: install failed (see README)"`
   and skip binding. Never leave a half-written binary (atomic rename).

Platform triples: `linux-x86_64`, `linux-aarch64`, `macos-x86_64`,
`macos-arm64`.

## 11. Build & release

- **Zig 0.15.2** (pinned; `minimum_zig_version`). Dependencies via
  `build.zig.zon`: `ghostty` (VT + format), `parg`, and ghostty's transitive C++
  SIMD libs (simdutf/highway/utfcpp) — built automatically.
- Release mode: `--release=fast`. Optional `-Dsimd=false` for no-SIMD targets.
- **CI (`.github/workflows/release.yml`)** on tag `v*`: a 4-target matrix
  (linux/macos × x86_64/aarch64) cross-/native-builds, packages each as
  `tmux-2html-<triple>.tar.xz`, generates `SHA256SUMS.txt`, uploads to the
  GitHub release. `macos-arm64` and `linux-aarch64` native runners preferred
  (cross where unavailable).
- Version baked in via `build_options` and surfaced by `--version`.

## 12. Dependencies & pinned versions
- Zig 0.15.2 (build-time only for path 2; runtime users need not install it).
- ghostty (VT) — MIT, © Mitchell Hashimoto / Ghostty contributors.
- term2html logic (absorbed) — MIT, © 2026 aarol.
- Runtime: `tmux ≥ 3.3` (`display-popup` with `-B` borderless + pane-anchored
  `-x`/`-y`, per §7.0), `xdg-open` (optional, for `--open`).
- No Python, no Node, no external `term2html` binary at runtime.

## 13. Edge cases & limits
- **Huge scrollback** (`history-limit` can be 1,000,000): cap capture at
  `@tmux-2html-history-limit` (default 50k) with a status notice when truncated.
- **Wide characters / grapheme clusters / emoji:** handled by ghostty-vt cell
  widths; selection rounds to cell boundaries (wide cells selected atomically).
- **OSC 8 hyperlinks:** preserved (ghostty-vt); become `<a>` in HTML.
- **Empty/zero-cell selection on confirm:** warn, no file written, exit `1`.
- **Alternate-screen apps (nvim, less):** documented limitation — capture
  targets the normal screen + scrollback. Capturing the alt screen (`-a`) is a
  future option.
- **Checksum mismatch / offline:** download path fails loudly; instruct the user
  to install Zig and rebuild, or place a binary manually.
- **Concurrent runs:** output filenames include session + timestamp + pid to
  avoid collisions.

## 14. Licensing & attribution
- Project licensed **MIT**; retain upstream MIT notices for absorbed term2html
  code and the ghostty dependency under `licenses/`. `README` credits both.
- No proprietary code.

## 15. Testing strategy
- **Renderer golden tests:** `testdata/*.ansi` → compare `*.html` byte-for-byte
  (extend term2html's existing test harness); cases for 16/256/truecolor,
  attributes, OSC 8, and **selection sub-rectangles** (linewise + block).
  Goldens assert the **full HTML document** (§8.1: `<!DOCTYPE html>` →
  `</html>`), not a bare `<pre>`; the committed `testdata/*.html` are term2html
  fragments and **must be re-blessed as complete documents** when §8.1 lands.
- **Unit tests:** selection math (line/rectangle from anchor+cursor),
  palette parse/serialize, capture-line-range → `-S/-E` derivation, option
  parsing.
- **Plugin tests:** `ensure_binary.sh` under mocked environments (Zig present,
  Zig absent → download, download fails); key-binding registration.
- **Integration:** drive a **dedicated, isolated** tmux server + pty client
  (see §0 — **never** the user's running server). Use a uniquely-named socket
  per run (`tmux -L "tmux-2html-test-$$" new-session -d -s test`) and tear down
  **only that named socket/session** (e.g. `tmux -L "tmux-2html-test-$$" kill-session -t test`),
  or kill the exact PID you spawned. **NEVER** run `tmux kill-server`,
  `killall tmux`, `pkill tmux`, or anything that kills **all** tmux instances —
  it would destroy the user's live session. Against that isolated server,
  capture known colored output and assert the rendered HTML contains expected
  colors/content for full, visible, and region (programmatic `--selection`)
  paths.
- **Note:** `zig build test` currently hits a Zig Debug-mode linker bug
  (`R_X86_64_PC64`) with the bundled C++ SIMD libs on this toolchain; release
  builds are unaffected. CI should run tests in `ReleaseFast` or track the
  upstream fix.

## 16. Roadmap (out of v1 scope)
- In-TUI **live colored preview** of the selection before confirm.
- Alternate-screen capture (`capture-pane -a`) for nvim/less snapshots.
- tmux copy-mode interop (yank the selection to the tmux buffer in addition to
  HTML).
- Configurable themes / CSS, image (sixel/kitty) pass-through.

## 17. Decisions log
- **Stack:** Zig single binary (reuses ghostty-vt; absorbs term2html). Rationale:
  best fidelity, single language/build, in-house.
- **Selection model:** line-range + block; `v` begins / re-anchors a linewise
  selection at the cursor, `Ctrl-v` toggles visual block (tmux copy-mode parity).
- **Plugin form:** full TPM plugin (entrypoint, options, bindings, install hook).
- **Binary acquisition:** build-from-source first (if Zig), else download
  prebuilt; both paths shipped.
- **Platforms:** linux/macos × x86_64/aarch64.
- **Palette:** cached real palette (sync command + one-time auto-sync popup);
  precedence cached → live → default.
- **Bindings:** `O` full pane, `C-o` region (overrides existing debug bind),
  visible-pane provided but unbound.
- **TUI host:** pane-anchored `tmux display-popup` — sized to the pane
  (`#{pane_width}×#{pane_height}`, `-x P -y P`, borderless `-B`), copy-mode
  feel. True pane takeover is impossible for an external program (copy mode is
  server-internal; no takeover API); the pane-overlay popup is the faithful,
  non-destructive host (§7.0). Requires tmux ≥ 3.3.
- **Coordinates:** owned (no tmux copy-mode formats).
