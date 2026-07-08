# tmux-2html — Product Requirements & Technical Specification

> Source-of-truth document. Intended to be decomposed into a task breakdown for
> implementation. Every interface, path, flag, and algorithm below is
> normative unless explicitly marked otherwise.

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
  3. **Region** — an interactive, full-screen, copy-mode-style UI over the full
     scrollback; user selects a **line range or a rectangle/block** and renders
     exactly that.
- Output to stdout, a file, and/or auto-open in a browser.
- Real terminal palette fidelity (term2html-equivalent), via a cached palette so
  it works inside tmux bindings where no controlling terminal exists.
- Installable via TPM with zero manual binary steps for end users.

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
│  tui/          ─ full-screen copy-mode overlay (select line/block)     │
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
│       ├── view.zig              # full-screen VT rendering + status line
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

### 5.1 `tmux-2html render` — core renderer (stdin → HTML)
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
a grid; launch the **full-screen TUI** (§7); on confirm, render the current
selection (line or block) and emit HTML; on cancel, exit with no output.

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

Feels exactly like tmux copy-mode: a **full-screen overlay** taking over the
client via `tmux display-popup -E -w 100% -h 100%` running the binary.

### 7.1 Display
- Enter alternate screen (`\e[?1049h`), hide cursor, raw termios (no echo, no
  canonical). Restore on exit (always, including panic).
- Render the captured grid in **full color** using SGR + cursor addressing
  against the cached palette (colors match what the pane shows). Diff-rendering
  for performance on large grids; cap rendered rows to viewport, scroll with
  the cursor.
- **Status line** (last row), copy-mode-style:
  `[LINE|BLOCK]  row:N col:M  /pattern  N match(es)  <S-sel>Enter=render q=quit`.

### 7.2 Movement (vim + arrows)
`h j k l` and `← ↓ ↑ →`; `w b e`; `0 ^ $`; `g g` / `G`; `Ctrl-d/u` half-page;
`Ctrl-f/b` full-page; `H M L` viewport top/mid/bottom; `{ }` paragraph; `%`
matching. Counts supported (e.g. `5j`).

### 7.3 Search
`/pattern` forward, `?pattern` backward, `n` / `N` next/prev; regex (or
fixed-string, configurable). Matches highlighted in the grid.

### 7.4 Selection — both modes via `v`
- `v` begins selection at the cursor in **linewise** mode (anchor = cursor).
- `v` pressed again toggles the active selection **linewise ↔ rectangle/block**.
- Movement extends the selection from anchor to cursor.
- `o` / `O` swap cursor to the other end of the selection.
- `Esc` clears the selection (stays in the TUI); `q` quits.
- Aliases for familiarity: `V` linewise, `Ctrl-v`/`R` rectangle.

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
5. Emit HTML to stdout/`--output`; `--open` launches `xdg-open`.

All color classes are handled by ghostty-vt: 16 (palette lookup), 256,
truecolor (exact RGB), attributes, and OSC 8 hyperlinks. No bespoke ANSI parser.

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
- `C-o` → `run-shell` a wrapper that launches the full-screen popup:
  `tmux display-popup -E -w 100% -h 100% "$TMUX_2HTML_BIN/tmux-2html region --target #{pane_id} …"`
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
- Runtime: `tmux ≥ 3.2` (`display-popup`), `xdg-open` (optional, for `--open`).
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
- **Unit tests:** selection math (line/rectangle from anchor+cursor),
  palette parse/serialize, capture-line-range → `-S/-E` derivation, option
  parsing.
- **Plugin tests:** `ensure_binary.sh` under mocked environments (Zig present,
  Zig absent → download, download fails); key-binding registration.
- **Integration:** drive a detached tmux server + pty client, capture known
  colored output, assert rendered HTML contains expected colors/content for
  full, visible, and region (programmatic `--selection`) paths.
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
- **Selection model:** line-range + block, toggled via `v`.
- **Plugin form:** full TPM plugin (entrypoint, options, bindings, install hook).
- **Binary acquisition:** build-from-source first (if Zig), else download
  prebuilt; both paths shipped.
- **Platforms:** linux/macos × x86_64/aarch64.
- **Palette:** cached real palette (sync command + one-time auto-sync popup);
  precedence cached → live → default.
- **Bindings:** `O` full pane, `C-o` region (overrides existing debug bind),
  visible-pane provided but unbound.
- **TUI host:** full-screen `tmux display-popup` (100%×100%), copy-mode feel.
- **Coordinates:** owned (no tmux copy-mode formats).
