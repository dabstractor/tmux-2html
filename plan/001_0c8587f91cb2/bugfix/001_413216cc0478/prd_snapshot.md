# Bug Fix Requirements

## Overview

Creative end-to-end QA of the tmux-2html implementation against the PRD. Testing
covered: the `render` subcommand (stdin → HTML, `--selection`, `--open`, palette
modes, OSC 8, truecolor, unicode, empty inputs, out-of-range selections), the
`pane` subcommand (driven against an **isolated, uniquely-named tmux server** per
PRD §0 — never the user's), the `region` TUI (driven through a real pty:
cancel/quit, selection, confirm-render), the TPM plugin loader (`tmux-2html.tmux`),
and the binary-acquisition scripts (`ensure_binary.sh`, `download.sh` with a
mocked file:// fixture for checksum pass/mismatch).

Overall quality is strong: the core render pipeline is correct (16/256/truecolor,
attributes, OSC 8 hyperlinks, wide-cell/emoji atomicity, the full §8.1 HTML
document envelope), `download.sh` SHA256 verification works in both pass and
mismatch cases, the `region` TUI launches/selects/confirms, and exit codes are
correct on the paths tested. Two Major bugs break documented user-facing behavior,
and several Minor spec deviations exist around HTML document metadata.

Testing was performed with the binary built from the current tree
(`zig-out/bin/tmux-2html` 0.1.0).

## Critical Issues (Must Fix)

None. Core rendering, capture, and the region TUI all function.

## Major Issues (Should Fix)

### Issue 1: `pane` subcommand ignores `@tmux-2html-open` and `@tmux-2html-font` options (the primary `prefix O` workflow)

**Severity**: Major
**PRD Reference**: §9.2 (options table — `@tmux-2html-open` default `on`, `@tmux-2html-font` default `monospace`), §9.3 (bindings "read output-dir/open/font from options")
**Expected Behavior**: When invoked from the `prefix O` binding (which passes only `--target` and `--full`), the `pane` command should re-read `@tmux-2html-font` and `@tmux-2html-open` from tmux options itself, so that a user who sets `@tmux-2html-font "Fira Code"` gets `font-family: Fira Code` in the output, and a user with the default `@tmux-2html-open on` gets the rendered file auto-opened in the browser. The plugin loader comment and `docs/CONFIGURATION.md` ("How options are read") both explicitly document this: *"The pane and region commands re-read @tmux-2html-output-dir, @tmux-2html-history-limit, @tmux-2html-open, and @tmux-2html-font themselves at runtime via `tmux show-option`."*
**Actual Behavior**: `paneBody` (`src/main.zig`) only reads `@tmux-2html-history-limit` (via `panePrepare`) and `@tmux-2html-output-dir` (via `capture.resolveOutputDir`). It renders with `opts.font` (the CLI default `"monospace"`) and only opens when `opts.open` (CLI flag, default `false`) is set. Since the binding passes neither `--font` nor `--open`, `prefix O` ALWAYS uses `monospace` and NEVER auto-opens — regardless of the user's `@tmux-2html-font` / `@tmux-2html-open` settings. This directly contradicts the PRD, the README ("xdg-open auto-opens the HTML file after writing when @tmux-2html-open is on (the default)"), and the plugin's own inline comments. Notably `region.zig` implements this correctly (`readFontOption` / `readBoolOption`), proving the intended design — `pane` was simply not given the same treatment.
**Steps to Reproduce** (against an isolated tmux server):
```sh
SOCK="t2h-test-$$"; tmux -L "$SOCK" new-session -d -s s; PANE=$(tmux -L "$SOCK" display-message -p -t s:0.0 '#{pane_id}')
tmux -L "$SOCK" set-option -g @tmux-2html-open on
tmux -L "$SOCK" set-option -g @tmux-2html-font "Fira Code"
export TMUX="/tmp/tmux-1000/$SOCK,0,0"
# Run EXACTLY what the prefix-O binding runs:
out=$(zig-out/bin/tmux-2html pane --full --target "$PANE"); file=$(echo "$out" | sed 's/^wrote //')
grep -o 'font-family: [^;]*' "$file"   # => "font-family: monospace"  (should be "Fira Code")
# (no xdg-open is ever attempted, despite @tmux-2html-open=on)
tmux -L "$SOCK" kill-session -t s
```
**Suggested Fix**: In `paneBody` (`src/main.zig`), mirror `region.zig`'s confirm arm: resolve the effective font via a `readFontOption`-style helper (default `"monospace"`) and the effective open flag via a `readBoolOption("@tmux-2html-open", true)` OR'd with `opts.open`, then pass the resolved font to `renderToFileAtomic` and gate `spawnXdgOpen` on the resolved open flag. (The `readBoolOption`/`readFontOption` helpers already exist in `region.zig`; consider hoisting them into `capture.zig` so both subcommands share them.)

### Issue 2: `region` confirm-render writes an empty HTML file and returns success (exit 0) for a blank/zero-cell selection

**Severity**: Major
**PRD Reference**: §13 ("Empty/zero-cell selection on confirm: warn, no file written, exit 1"), §7.5
**Expected Behavior**: When the user confirms a selection that covers only blank cells, the region command must warn, write NO file, and exit `1`.
**Actual Behavior**: The confirm arm of `region.body` (`src/region.zig`) guards only on `!ctx.sel.active()` (selection not begun). An ACTIVE selection whose rendered body is empty (e.g. a linewise selection over blank prompt lines) passes that guard, `renderSelectionHtml` produces an HTML document with an empty `<pre class="term2html-output" ...></pre>`, `writeHtmlAtomic` writes it to disk, the `.last-output` sidecar is written, and the command returns `0` (success). This violates all three PRD §13 mandates (warn / no file / exit 1). The `render --selection` path handles this correctly via `selectionBodyEmpty` (`src/render.zig`), but `region` does not reuse that check.
**Steps to Reproduce** (driven through a pty against an isolated server; the cursor starts on the last/blank row):
```sh
# region launches with cursor on the last (blank) row; begin a selection there and confirm:
# keys sent to the pty:  v   (begin linewise selection at cursor)   \r  (confirm)
python3 -c '
import os,pty,sys,time,select
pid,fd=pty.fork()
if pid==0: os.execvp(sys.argv[1],sys.argv[1:])
time.sleep(0.6); os.write(fd,b"v"); time.sleep(0.2); os.write(fd,b"\r"); time.sleep(0.6)
while select.select([fd],[],[],0.4)[0]:
    try:
        if not os.read(fd,65536): break
    except OSError: break
_,st=os.waitpid(pid,0); print("exit",os.WEXITSTATUS(st) if os.WIFEXITED(st) else None)
' zig-out/bin/tmux-2html region --target "$PANE"
# => prints "exit 0" and a NEW empty-body HTML file appears in the output dir
```
Confirmed empirically: output dir file count increased by one; the new file's `<pre>` body was empty; exit code was 0.
**Suggested Fix**: After `renderSelectionHtml` in the confirm arm, reuse `render.selectionBodyEmpty` (or check the fragment between `<pre` and `</pre>` for non-whitespace) and, when empty, print the warning to stderr, skip `writeHtmlAtomic` / sidecar / open, and `break :confirm_render 1`.

### Issue 3: Mouse support is not implemented in the region TUI (click/drag/wheel do nothing)

**Severity**: Major
**PRD Reference**: §7.6 ("Mouse (supported): Click to move cursor; drag to select (linewise by default, block with modifier, e.g. Alt); wheel to scroll.")
**Expected Behavior**: Inside the region overlay, a mouse click moves the cursor, a drag selects (linewise by default; block with Alt), and the wheel scrolls the viewport — as documented under v1 scope (the section header literally reads "Mouse (supported)").
**Actual Behavior**: `app.enter` enables mouse mode and `app.zig` decodes SGR mouse sequences (`\x1b[?1000h \x1b[?1002h \x1b[?1006h`), but `regionHandle` (`src/region.zig`) discards every mouse event: the `.mouse` event branch falls through to `return .none` ("ignore mouse/seq"), and the code comment confirms this is an unimplemented follow-up ("Mouse is a NO-OP in S1 (PRD 7.6 mouse wiring is a follow-up)… a later task only adds the regionHandle mouse branch"). Consequently click/drag/wheel have zero effect in the overlay, contradicting the PRD's stated v1 feature set. Keyboard selection (the `v` + motion path) works, so this is a missing feature rather than a total loss of selection capability.
**Steps to Reproduce**: Launch `tmux-2html region` in a real terminal (or `tmux display-popup`); click anywhere, drag, or scroll the wheel — the cursor and viewport do not respond. (Only keyboard `h j k l` / arrows / `v` work.)
**Suggested Fix**: Add a `.mouse` case to `regionHandle` (and/or thread decoded mouse events from `app.classify` into `input.feed`) that maps press→cursor move, drag-with-button-held→selection extend (toggle to block when the Alt modifier bit is set), and wheel up/down→viewport scroll, reusing the existing `motion`/`select` primitives.

## Minor Issues (Nice to Fix)

### Issue 4: Missing `--title` flag (title is not configurable)

**Severity**: Minor
**PRD Reference**: §8.1 ("`<title>` … Configurable via `--title` / `@tmux-2html-title`."), §5.1/§5.2/§5.3 (subcommand flag surfaces)
**Expected Behavior**: The document `<title>` is configurable via a `--title` CLI flag and/or an `@tmux-2html-title` tmux option on the relevant subcommands.
**Actual Behavior**: No `--title` flag is defined in any options struct (`src/cli.zig`); `render` rejects `--title` as an unknown flag (`tmux-2html render: unknown or unexpected argument`). No `@tmux-2html-title` option is read anywhere. The title is hardcoded: `tmux-2html` for `render`, and the session/pane/timestamp form for `pane`/`region`.
**Steps to Reproduce**: `printf x | zig-out/bin/tmux-2html render --cols 5 --title "My Title" --palette default` → exit 1, `unknown or unexpected argument`.
**Suggested Fix**: Add a `title: ?[]const u8` to the option structs, parse `--title`, and let an explicit value (or `@tmux-2html-title`) override the computed default; thread it into the `DocumentOpts.title` passed to the envelope helper.

### Issue 5: Missing `@tmux-2html-lang` / locale configurability for the `<html lang>` attribute

**Severity**: Minor
**PRD Reference**: §8.1 ("`<html>` … carrying a `lang` attribute (default `en`; configurable via `@tmux-2html-lang` / locale).")
**Expected Behavior**: The `<html lang="...">` attribute is configurable via an `@tmux-2html-lang` option (or derived from the locale), defaulting to `en`.
**Actual Behavior**: `DocumentOpts.lang` defaults to `"en"` and is never read from any option or the locale. The code comment in `src/render.zig` even marks this as "future".
**Steps to Reproduce**: Set `@tmux-2html-lang fr`; render any pane; output still contains `<html lang="en">`.
**Suggested Fix**: Read `@tmux-2html-lang` (with locale fallback) in the pane/region bodies and pass it through `DocumentOpts.lang`.

### Issue 6: `pane`/`region` document title format deviates from PRD §8.1

**Severity**: Minor
**PRD Reference**: §8.1 (default title form: `tmux-2html — <session>/<window>.<pane> <iso8601>`)
**Expected Behavior**: The default `<title>` for `pane`/`region` is `tmux-2html — <session>/<window>.<pane> <iso8601>`, e.g. `tmux-2html — testsess/1.0 2026-07-10T10:20:00Z`.
**Actual Behavior**: `paneTitle` (`src/main.zig`) and `regionTitle` (`src/region.zig`) produce `tmux-2html — <session>/<pane_id> <unixtime>` — e.g. `tmux-2html — testsess/%0 1783693046`. Two deviations: (a) the `<window>` component is missing (the pane id `%0` is used where `<window>.<pane>` is specified, even though `#{window_index}` is queryable); (b) a Unix epoch integer is used instead of an ISO 8601 timestamp.
**Steps to Reproduce**: Render any pane and inspect `<title>` (e.g. via the `prefix O` repro in Issue 1).
**Suggested Fix**: Query `#{session_name}:#{window_index}.#{pane_index}` (or the window name) for the location component and format the timestamp as ISO 8601 (the `palette.zig` `formatIso8601` helper already does this and could be reused/exposed).

## Testing Summary

- Total tests performed: ~35 (CLI/help/exit-code matrix, render color/attr/OSC8/truecolor/unicode/empty/selection edge cases, pane visible+full against an isolated tmux server, region TUI cancel+select+confirm via pty, plugin loader, download.sh checksum pass/mismatch, golden/unit `zig build test -Doptimize=ReleaseFast`)
- Passing: ~29
- Failing: 6 (Issues 1, 2, 3 = Major; Issues 4, 5, 6 = Minor)
- Areas with good coverage: core ANSI→HTML fidelity (16/256/truecolor, attributes, OSC 8, wide-cell/emoji), the §8.1 full-document envelope (DOCTYPE/charset/viewport/title-escape/body-bg), `render --selection` (linewise/block/out-of-range/empty), `pane` capture+geometry+truncation, `download.sh` SHA256 verification (pass + mismatch), exit-code contracts, the isolated-server safety pattern (PRD §0).
- Areas needing more attention: honoring `@tmux-2html-open`/`@tmux-2html-font` from the `pane` path (Issue 1), empty-selection validation in the `region` confirm path (Issue 2), mouse handling in the region TUI (Issue 3), and the §8.1 document-metadata configurability (title/lang) and title-format (Issues 4–6). The `region` TUI's full vim-motion/search surface was smoke-tested (launch + select + confirm) but not exhaustively key-by-key.
