# System Context & Module Boundaries (VERIFIED)

> High-level architecture and how modules hand off. Grounded in the verified term2html /
> ghostty source (see findings_and_corrections.md, external_deps.md, render_pipeline.md).

## 1. Two-layer product

```
┌────────────────────── TPM plugin (shell) ──────────────────────┐
│ tmux-2html.tmux  → resolve BIN, ensure binary, read options,   │
│                    bind keys, one-time palette auto-sync popup  │
│ scripts/ensure_binary.sh → build (zig) | download prebuilt     │
│ scripts/download.sh      → fetch+sha256+extract                 │
└───────────────┬────────────────────────────────────────────────┘
                │ invokes (run-shell / display-popup)
┌───────────────▼─────────── Zig binary: tmux-2html ──────────────┐
│ main.zig  → dispatch subcommand (peek first positional w/ parg) │
│ cli.zig   → flag/option parsing (parg wrapper)                  │
│ capture.zig  → run `tmux capture-pane -e -J -p ...`, read geom  │
│ palette.zig  → queryColors (OSC) + XDG cache (absorbed)         │
│ render.zig   → Terminal→grid→ScreenFormatter→HTML (+selection)  │
│ ghostty_format.zig (VENDORED from term2html; has `font`)        │
│ tui/{app,view,select,input}.zig → copy-mode overlay             │
└─────────────────────────────────────────────────────────────────┘
```

## 2. Subcommand dispatch (cli.zig owns this)

parg has NO native subcommand support (external_deps.md §4). So `main.zig`:
1. `std.process.args()` → `parg.parse`.
2. Read first positional (`.arg` token via `next()` BEFORE the flag loop): `render|pane|region|sync-palette`.
   (Handle `--version`/`--help` first if present.)
3. Dispatch to `cli.render(...)`, `cli.pane(...)`, etc. Each consumes the remaining flags.
Exit codes: 0 ok, 1 usage/runtime, 2 capture/target error.

## 3. Module contracts (explicit handoffs)

### capture.zig
- **INPUT:** pane id (`--target` or `$TMUX_PANE`), mode (visible/full), history limit.
- **LOGIC:** resolve geometry via `tmux display-message -p -t <pane> '#{pane_width}'` /
  `'#{pane_height}'` (two calls or one combined). Build the capture command:
  `tmux capture-pane -e -J -p -t <pane> [-S -<hist> -E -]`. Shells out using `$TMUX` socket
  (`std.process.Child`, env inherits `$TMUX`/`$TMUX_PANE`).
- **OUTPUT:** `Captured { ansi: []u8, cols: u16, rows: u16 }`. The `cols/rows` come from tmux
  (NOT a tty ioctl — there is no tty in run-shell).
- **MOCKING:** for unit tests, replace the `tmux` invocation with a function pointer / a
  testdata `.ansi` file. Never require a live tmux server in unit tests (integration only).

### palette.zig (absorbs term2html terminal.zig::queryColors)
- **INPUT:** a mode (cached/live/default/from-file) + an optional tty handle.
- **LOGIC:**
  - `queryColors()` — VERIFIED OSC flow (render_pipeline.md §2). Opens `/dev/tty`.
  - `loadCache(path) Colors!` / `writeCache(path, Colors)` — parse/emit the plain-text format.
  - `resolve(mode)` precedence: cached→live→default. `live` only when `/dev/tty` is usable.
- **OUTPUT:** `Colors { palette[256], fg, bg, count }` (exactly term2html's struct).
- **MOCKING:** `queryColors` is only exercised interactively; tests cover parse/serialize +
  precedence logic against fixed `Colors` values.

### render.zig (absorbs term2html main.zig::formatAnsi + ghostty_format.zig)
- **INPUT:** `Captured` (or raw stdin for `render`), `Colors`, size, optional `Selection`,
  font, output target.
- **LOGIC:** VERIFIED pipeline (render_pipeline.md §1, §4). `Terminal.init` → `vtStream`
  (`\n`→`\r\n`) → `ScreenFormatter.init(t.screens.active, opts)` →
  `content = .{ .selection = sel_or_null }` → `print("{f}", .{formatter})`.
- **OUTPUT:** HTML bytes to stdout / `--output` file; `--open` → spawn `xdg-open`.
- **The `Selection` for `render --selection X1,Y1,X2,Y2[,rect]`:** parse the 4–5 ints →
  `point.Point`s → `screen.pages.pin(pt)` → `Selection.init(rect)`.

### tui/ (region subcommand)
- **INPUT:** `Captured` (full scrollback) + `Colors` + grid size.
- **LOGIC:** launch full-screen alt-screen TUI; render grid in color; vim+arrow movement;
  search; `v` selection (linewise↔block); confirm/cancel.
- **OUTPUT:** on confirm, produce a `Selection` (linewise or block, §7.4 mapping) and hand to
  `render.zig`; write result path to `.last-output` sidecar for the plugin wrapper.
- **HOST:** `tmux display-popup -E -w 100% -h 100%` gives a REAL pty (OSC works; raw termios
  works). This is the ONLY place live termios is safe to set (besides sync-palette).

## 4. Where each PRD technical constraint is satisfied

| PRD constraint | How / where | Verified source |
|---|---|---|
| capture-pane `-e -p` emits ANSI/SGR/OSC8 | capture.zig builds the cmd | PRD §2.1 + man |
| no tty in run-shell; $TMUX set | capture uses $TMUX socket; palette uses cache | findings §3 |
| explicit size | cols/rows from `#{pane_width/height}` | render_pipeline §1, §3 |
| formatter supports selection | `content.selection: ?Selection`, pin-based | render_pipeline §4 |
| owned coordinates (no tmux copy-mode) | TUI selects on its own grid | render_pipeline §4 |
| palette layering | palette.zig precedence cached→live→default | render_pipeline §2 |

## 5. Testing boundaries (PRD §15)

- Unit (no tmux, no tty): selection math, palette parse/serialize, `-S/-E` derivation,
  option parsing, render-with-selection (feed testdata `.ansi`).
- Golden: `testdata/*.ansi → *.html` byte compare (+ selection sub-rect goldens).
- Integration: detached tmux server + pty client, known colored output, assert HTML for
  full/visible/region(`--selection`) paths.
- `zig build test` runs in **ReleaseFast** (Debug linker bug with C++ SIMD libs — PRD §15).
