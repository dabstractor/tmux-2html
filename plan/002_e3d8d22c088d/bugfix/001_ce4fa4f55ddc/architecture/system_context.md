# System Context — Bug Fix 001

## Project: tmux-2html

A Zig CLI tool (`render` / `pane` / `region` / `sync-palette` subcommands) that captures tmux
pane output (via `tmux capture-pane -e -p`) and renders it to a standalone HTML5 document
using an absorbed Ghostty VT formatter. A POSIX sh TPM plugin (`tmux-2html.tmux`) reads
`@tmux-2html-*` tmux options and binds prefix keys to invoke the binary.

## Architecture (relevant to these bugs)

```
tmux-2html.tmux (POSIX sh plugin)
  ├── reads @tmux-2html-* options via `tmux show-option -gqv`
  ├── constructs title_arg / lang_arg (shell-quoted CLI fragments)
  ├── binds O / visible / C-o keys via `tmux bind-key ... run-shell "..."`
  │       └── run-shell fires /bin/sh -c "..." with #{pane_id} expanded
  └── palette auto-sync popup (display-popup)

src/cli.zig       — parseRender/parsePane/parseRegion: --font, --title, --lang, --output
src/render.zig     — renderGrid → Terminal → ScreenFormatter; writeDocument (§8.1 envelope)
                     resolveLang, toBcp47, langFromEnv, writeEscaped
                     renderToFileAtomic, writeDocFileAtomic (atomic file write)
src/ghostty_format.zig — absorbed Ghostty ScreenFormatter: <pre style="font-family: ...">
src/main.zig       — subcommand dispatch; pane path (makePath + renderToFileAtomic)
src/region.zig     — region TUI path (makePath + renderSelectionHtml)
src/palette.zig    — OSC palette query + cache
```

## Issue Summary

| # | Severity | Area | Root Cause |
|---|----------|------|------------|
| 1 | Major | Shell quoting | `tmux-2html.tmux` wraps option values in naive single quotes |
| 2 | Major | XSS / HTML injection | `ghostty_format.zig:841` emits font unescaped into `<pre style>` |
| 3 | Minor | File I/O | `renderToFileAtomic`/`writeDocFileAtomic` don't `makePath` parent dir |
| 4 | Minor | Locale/Lang | `resolveLang("")` treats empty explicit as invalid → "en", not locale |

## Key Files & Line Numbers (verified)

### Issue 1: Shell quoting in tmux-2html.tmux
- **File**: `tmux-2html.tmux`
- **Bug location** (~lines 111-115):
  ```sh
  title_arg=""
  [ -n "$title_opt" ] && title_arg="--title '$title_opt'"
  lang_arg=""
  [ -n "$lang_opt" ] && lang_arg="--lang '$lang_opt'"
  ```
- **Affected bindings** (3): O/full (~line 138), visible (~line 145), C-o/region (~line 185)
  — all interpolate `$title_arg` / `$lang_arg` into `run-shell "... /bin/sh -c ..."`
- **Fix**: POSIX-safe shell escape — wrap in `'...'` and replace every `'` with `'\''`
- **Alternative (PRD-suggested)**: have binary read title/lang via `show-option` like font/open/output-dir

### Issue 2: HTML attribute injection via --font
- **File**: `src/ghostty_format.zig`
- **Bug location** (lines 840-841):
  ```zig
  const font = self.opts.font orelse "monospace";
  buf_writer.print("font-family: {s};", .{font}) catch return error.WriteFailed;
  ```
  `{s}` interpolates the font value RAW into the `style` attribute. A `"` breaks out.
- **Font flow**: cli.zig `opts.font: []const u8` → render.zig `renderGrid(font: ?[]const u8)`
  → `ScreenFormatter.init(.font = font)` → ghostty_format.zig `self.opts.font` → unescaped emit
- **`writeEscaped` helper** (render.zig:299): escapes `& < > " '` — the same set needed here
- **`buf_writer`** is a ghostty stream writer: has `.print()`, `.writeAll()`, `.writeByte()` methods
- **Fix**: Replace `buf_writer.print("font-family: {s};", .{font})` with inline escape loop
- **Golden tests** (golden_test.zig:30): use `null` font → "monospace" → NO special chars →
  goldens will NOT change when escaping is added. Safe.

### Issue 3: render --output parent dirs
- **File**: `src/render.zig`
- **Bug location**: `renderToFileAtomic` (line 538) and `writeDocFileAtomic` (line 602)
  both open the parent dir via `openDir` WITHOUT calling `makePath` first → fails if dir absent
- **Contrast — pane does it right**: `main.zig:496` → `std.fs.cwd().makePath(out_dir) catch {};`
- **Contrast — region does it right**: `region.zig:484` → `std.fs.cwd().makePath(dp) catch {};`
- **Fix**: Add `makePath(dir_path)` before `openDir` in both functions
- **Error message**: `"tmux-2html render: cannot write output file\n"` (render.zig:774, 808)

### Issue 4: --lang "" yields "en"
- **File**: `src/render.zig`
- **Bug location** (lines 292-294):
  ```zig
  pub fn resolveLang(explicit: ?[]const u8) []const u8 {
      if (explicit) |e| return toBcp47(e) orelse "en";  // "" → toBcp47 → null → "en"
      return langFromEnv();
  }
  ```
- `opts.lang` is `?[]const u8`; `--lang ""` sets it to `@as(?[]const u8, "")` (non-null!)
- `toBcp47("")` returns null (length < 2) → falls back to `"en"`, skipping locale derivation
- **Fix**: Add `if (e.len == 0) return langFromEnv();` before the toBcp47 call

## Testing Infrastructure

### Shell harnesses (tests/)
- `tests/plugin_options.sh` — mocked-tmux test (no real tmux needed); sources tmux-2html.tmux
  with a `tmux()` shell-function override; captures bind-key/display-popup command strings;
  asserts --title/--lang threading. Current case (b) uses `"My Pane"` (no apostrophe).
- `tests/envelope_smoke.sh` — real binary through all HTML paths against isolated tmux socket

### Zig unit/golden tests (src/)
- `src/golden_test.zig` — testdata/*.ansi → byte-equal *.html (inline for, Size{120,150})
- `src/render.zig` tests — `writeEscaped`, `writeDocument`, `toBcp47`, `resolveLang` unit tests
- `src/cli.zig` tests — `parseRender`, `parsePane`, `parseRegion` flag parsing tests

### Safety infrastructure (scripts/)
- `scripts/check-safety.sh` — static guard; FAILs on global tmux kill + recursive bare-exec;
  WARNs on hand-rolled PATH shim outside scripts/. **Issue 1 fix does NOT trip any pattern**
  (no PATH manipulation, no exec, no >>). Run before committing.
- `scripts/safe-run.sh` — wraps commands under RLIMIT_FSIZE + RLIMIT_CPU
- `scripts/preflight.sh` — bounded scan for giant files, audit residue, low disk

## Documentation Files
- `docs/CONFIGURATION.md` — documents all @tmux-2html-* options, --font, --title, --lang
- `README.md` — project overview, features, usage examples

## Build System
- `zig build --release=fast` (clean build)
- `zig build test --release=fast` (all unit + golden tests)
- Shell tests: `sh tests/plugin_options.sh`, `sh tests/envelope_smoke.sh`