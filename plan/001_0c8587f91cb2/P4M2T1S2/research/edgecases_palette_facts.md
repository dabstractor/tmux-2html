# PRD §13 Edge Cases + Sync-Palette/Palette-Cache Fact Sheet

Verification against shipped source in `/home/dustin/projects/tmux-2html`. Each
item tagged SHIPPED / PARTIAL / NOT-SHIPPED with file:line evidence and verbatim
user-facing messages. Drives the "Known limitations" + "sync-palette" sections of
docs/CONFIGURATION.md.

Files inspected: `src/capture.zig`, `src/cli.zig`, `src/main.zig`, `src/palette.zig`,
`src/region.zig`, `src/render.zig`, `src/ghostty_format.zig`, `scripts/download.sh`,
`tmux-2html.tmux`, `testdata/osc8.{ansi,html}`, `testdata/embed.zig`,
`src/golden_test.zig`.

---

## §13 Edge Cases

### 1. HUGE SCROLLBACK — cap + truncation notice — **SHIPPED**
- `PaneOpts.history: u32 = 50000` (`cli.zig:75`); `--history N` help: *"with --full,
  cap scrollback to last N lines (default 50000)"* (`cli.zig:299-302`).
- `effectiveHistory = @min(cli_history, configured_limit)` — the TIGHTER of
  `--history` vs `@tmux-2html-history-limit` wins (`capture.zig:165-167`).
- `@tmux-2html-history-limit` read via `tmux show-option -gqv`; unset/empty/non-
  numeric ⇒ fallback 50000 (`main.zig:356-359`, `region.zig:131-134`).
- `wasTruncated = (.full) and (history_size > effective)` — STRICT `>` (`capture.zig:172-174`).
- **Truncation NOTICE** (stderr ALWAYS + best-effort `tmux display-message`), verbatim
  (`main.zig:384-389`, emitted `main.zig:459-464`):
  ```
  tmux-2html: capture truncated to {d} history lines (pane had {d}); older output dropped
  ```
  Note: stderr is guaranteed; the display-message is best-effort (a run-shell context
  may have no tmux client).

### 2. WIDE CHARS / GRAPHEME / EMOJI — atomic wide-cell selection — **SHIPPED** (delegated)
- Cell width from ghostty-vt `Cell.wide` (`{narrow, wide, spacer_head, spacer_tail}`).
- Wide-cell rounding on selection start (`ghostty_format.zig:904-918`): if `start_x`
  is a `.spacer_tail`, rewind to `start_x-1` to include the full wide char.
- Spacer skipping in emission (`ghostty_format.zig:1004-1009`): a wide glyph emits
  exactly once.
- Proof: `render.zig:828-866` test feeds 真 (U+771F), selects linewise, asserts the
  glyph appears exactly once.
- tmux-2html adds NO custom width/grapheme logic; it delegates to the vendored
  formatter (and ultimately ghostty-vt). Document the capability as ghostty-vt's.

### 3. OSC 8 HYPERLINKS → `<a>` — **SHIPPED**
- `renderGrid` sets `f.extra = .styles` ⇒ per-cell `<span>` inline CSS **+ OSC-8
  `<a>` hyperlinks** (`render.zig:179-194`); region does the same (`region.zig:463`).
- `formatHyperlinkOpen` emits `<a style="color: inherit;" href="<uri>">` (HTML-encoded)
  (`ghostty_format.zig:1420-1438`); close emits `</a>` (`:1440-1447`).
- Golden proof: `testdata/osc8.ansi` → `testdata/osc8.html`, embedded in
  `testdata/embed.zig:32`, asserted byte-equal in `golden_test.zig:26-47`.

### 4. EMPTY/ZERO-CELL SELECTION on confirm — warn, no file, exit 1 — **SHIPPED** (two paths)
- **render `--selection`** (`render.zig:640-650`): after rendering, `selectionBodyEmpty`
  checks the `<pre>…</pre>` body; if empty/whitespace ⇒ stderr
  `"tmux-2html render: selection is empty\n"` + `return 1`, **no file written**.
- **region confirm** (`region.zig:236-239`): `if (!ctx.sel.active())` ⇒ stderr
  `"tmux-2html region: no selection (press v to begin, then Enter)\n"` + exit 1,
  no file, no sidecar.
- Note: the two paths use different "empty" definitions (render = rendered-body
  whitespace; region = no selection begun at all). Both satisfy "warn, no file, exit 1".

### 5. ALT-SCREEN APPS (nvim, less) — normal screen + scrollback ONLY — **SHIPPED**
- `captureCmd` base argv (BOTH modes): `{ tmux, capture-pane, -e, -J, -p, -t, pane }`.
  `.full` appends `{ -S, -<history>, -E, - }`. **`-a` is NEVER added** (`capture.zig:149-163`).
- Unit tests (`capture.zig:155`, `:159-161`) assert the exact token counts (7 visible,
  11 full) with no `-a`.
- Alt-screen capture (`capture-pane -a`) is genuinely absent; a documented future option.

### 6. CHECKSUM MISMATCH / OFFLINE — loud, instructive fail — **SHIPPED**
`scripts/download.sh` verifies SHA256 against `SHA256SUMS.txt` before extract. On
mismatch/missing entry (verbatim):
```
tmux-2html: download.sh: SHA256 mismatch (or no entry) for $tname
  expected: ${expected:-<none>}
  actual:   $actual
  Please install Zig or place a binary manually (see README).
```
Other loud paths (all → exit 1, all instructive): unsupported platform; no curl/wget;
download failure (offline/404/no release); no sha256 tool. The loader then flashes
`tmux display-message "tmux-2html: install failed (see README)"`.

### 7. CONCURRENT RUNS — collision-safe filenames — **SHIPPED**
- `buildOutputFilename` (`capture.zig:324-333`): `"{s}-{d}-{d}.html"` ⇒
  `<sanitized-session>-<unixtime>-<pid>.html`. Session sanitized to
  `[A-Za-z0-9._-]` (empty ⇒ `pane`); unixtime = `std.time.timestamp()`; pid = Linux
  `getpid()` else 0.
- pane (`main.zig:371-377`) and region (`region.zig:486-496`) both use it. Explicit
  `--output` bypasses auto-naming.
- Note: there is NO `pane.zig` module; filename/path construction lives in `capture.zig`.

---

## Sync-Palette + Palette-Cache Behavior

### 8. sync-palette flags + exit behavior — **PARTIAL** (flag drift trap)
- Flags SHIPPED (`cli.zig:83-86,277-293`): `--from tty|file PATH` (default `.tty`;
  `--from file PATH` consumes the path as a second value), `--force` (default false).
  Help (`cli.zig:226-234`): *"--from source tty (default) | file PATH"*, *"--force
  re-query even if a cache exists"*.
- `--from file PATH` SHIPPED (`main.zig:204-209`): seeds the cache from a palette file
  via `palette.loadColorsFile`; failure ⇒ exit 1 *"error: cannot read palette file
  '{path}'"*.
- `--force` SHIPPED (`main.zig:191-197`): `shouldRun(cache_exists, force) = force or
  !cache_exists`. Without `--force`, an existing cache is left untouched.

**Exit-on-no-response nuance (CORRECT THE DOCS):**
- `--from tty` opens `/dev/tty` with a **500 ms per-batch read timeout**
  (`raw.cc[V.TIME] = 5`; `palette.zig:117-160`).
- **`/dev/tty` unopenable / termios fails** (no controlling tty, e.g. run-shell) ⇒
  `queryColors` errors ⇒ **exit 2**, verbatim: *"error: cannot query terminal palette
  (no controlling tty or terminal unresponsive)"* (`main.zig:207-212`).
- **`/dev/tty` opens but the terminal stays silent** (OSC unanswered) ⇒ reads until
  the 500 ms timeout, returns `Colors` seeded from `defaultColors()` with
  `palette_received_count < 256`, emits `std.log.warn("palette: terminal responded
  with only {d}/256 palette entries", ...)`, and **RETURNS SUCCESS (exit 0)** — the
  summary says e.g. *"queried 0/256 colors; cache at <path>"*.

> ⚠ The PRD claim "exit non-zero if the terminal does not respond within timeout" is
> only HALF true. A silent-but-open terminal yields exit 0 + a default-seeded cache +
> a warning. Exit non-zero (code 2) happens ONLY when `/dev/tty` cannot be opened.
> Document BOTH outcomes precisely.

### 9. Palette cache location + plain-text format + XDG rule — **SHIPPED**
- Location `${XDG_CACHE_HOME:-$HOME/.cache}/tmux-2html/palette` (`palette.zig:437-445`).
- `cacheBase` (`palette.zig:429-435`): honors `$XDG_CACHE_HOME` ONLY if set, non-empty,
  AND absolute (`std.fs.path.isAbsolute`); else `$HOME/.cache`; errors if `$HOME` unset.
- Format (`palette.zig:383-416`, `serialize`):
  ```
  # tmux-2html palette (queried <ISO8601-UTC>)
  fg R G B
  bg R G B
  0 R G B
  …
  255 R G B
  ```
  Header = `# tmux-2html palette (queried ` + RFC3339/ISO8601 UTC + `)`. 256 index
  lines `N R G B`. Round-trip exactness proven (`palette.zig:628-692`).
- Parser tolerance: missing entries keep their default seed; the ONLY hard error is
  `MalformedLine` (non-numeric / wrong field count / idx > 255). Comment lines skipped.
- Atomic write (`palette.zig:448-466`): `dir/.palette.tmp` + rename, best-effort `sync()`.

### 10. Auto-sync popup in tmux-2html.tmux — **SHIPPED**
- Cache path computed identically to the binary (`XDG` honored only if set+non-empty+
  absolute via `[ "${XDG_CACHE_HOME#/}" != "$XDG_CACHE_HOME" ]`).
- One-time trigger, gated on `binary_ready` AND `[ ! -f "$palette_cache" ]`, NO `--force`:
  ```sh
  if [ "$binary_ready" = 1 ] && [ ! -f "$palette_cache" ]; then
      palette_autosync=1
      tmux display-popup -E -w 50% -h 50% \
          "$TMUX_2HTML_BIN/tmux-2html sync-palette" 2>/dev/null || :
  else
      palette_autosync=0
  fi
  ```
- **Non-fatal:** `2>/dev/null || :` swallows any failure. The loader never aborts.
- Size `-w 50% -h 50%` (NOT 100%; contract said "short popup"). If it fails, no cache
  is written and later renders fall through `palette.resolve(.cached,...)` → live-or-default.

### 11. Inside-tmux vs outside-tmux palette capture — **SHIPPED** (inherent)
- `sync-palette --from tty` opens `/dev/tty` (`palette.zig:122`) and sends OSC 4/10/11.
- Whichever terminal owns `/dev/tty` is what gets queried:
  - **Inside tmux** (the auto-sync popup, or any pane): `/dev/tty` is a tmux pty ⇒ the
    tmux-presented palette (tmux's applied `terminal-overrides`/theme).
  - **Outside tmux** (a plain shell): `/dev/tty` is the outer terminal emulator ⇒ that
    terminal's configured palette.
- No code branch distinguishes the two; it is the inherent semantics of querying
  `/dev/tty`. The auto-sync runs inside a `display-popup` (a real tmux pty) so it
  captures the tmux-presented palette.

---

## Summary

| # | Item | Status |
|---|------|--------|
| 1 | Huge scrollback cap + truncation notice | SHIPPED |
| 2 | Wide chars/grapheme/emoji atomic selection | SHIPPED (delegated) |
| 3 | OSC 8 hyperlinks → `<a>` | SHIPPED |
| 4 | Empty selection ⇒ warn, no file, exit 1 | SHIPPED (two paths) |
| 5 | Alt-screen NOT captured (no `-a`) | SHIPPED |
| 6 | Checksum/offline ⇒ loud fail | SHIPPED |
| 7 | Concurrent-run collision-safe filenames | SHIPPED |
| 8 | sync-palette flags + exit-on-no-response | PARTIAL (timeout exit only on unopenable tty) |
| 9 | Palette cache location/format/XDG | SHIPPED |
| 10 | Auto-sync popup once-if-no-cache, non-fatal | SHIPPED |
| 11 | Inside-vs-outside tmux palette capture | SHIPPED (inherent) |

## Residual doc-accuracy notes
- **#8 is the main trap:** do NOT claim a blanket "timeout ⇒ non-zero exit." State both
  outcomes (exit 2 if no controlling tty; exit 0 + default-seeded cache + warning if the
  terminal is silent-but-open).
- **#2/#3:** attribute the capability to ghostty-vt (via the vendored formatter), not to
  tmux-2html code.
- **#5:** do NOT document alt-screen capture (`-a`) as supported; it is a future option.
- **#4:** the two "empty selection" paths use different definitions; that is fine to state.
