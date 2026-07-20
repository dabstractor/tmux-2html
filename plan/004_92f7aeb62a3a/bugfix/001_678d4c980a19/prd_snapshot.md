# Bug Fix Requirements

## Overview

End-to-end creative validation of the **tmux-2html** implementation against the PRD,
focused on the user-facing surface (every output path, the §8.1 HTML envelope, the
interactive region TUI, plugin bindings, and adversarial/edge inputs).

**Testing performed:**
- Built `zig build --release=fast` (clean) and ran `zig build test --release=fast`
  (all unit tests pass: golden byte-equal, selection goldens, CLI parse, lang resolver,
  envelope structure, capture/truncation math, plugin option threading, select/motion/input
  state machines).
- Ran both shipped shell harnesses: `tests/plugin_options.sh` (PASS) and
  `tests/envelope_smoke.sh` (PASS).
- Drove the **real binary** through every HTML output path: `render` (stdout / `--output` /
  `--open`→temp / `--selection` linewise + block / `--title` / `--lang` / C-locale→en /
  palette default|cached|live), `pane` (`--visible` / `--full` / default / `--history`
  truncation / `--title` / `--lang` / nested `--output` / option re-reads / 8-way
  concurrency), `region` (linewise/block confirm, `y` alias, search, cancel, empty-confirm,
  nested `--output`, blank-cell confirm), `sync-palette` (no-tty / `--force` / `--from file`
  valid+missing+malformed), `--version`, `--help`, unknown subcommand, exit-code contract.
- Verified §8.1 envelope requirements explicitly: `<!DOCTYPE html>` first, single
  `<html lang>` root, `<meta charset="utf-8">` FIRST in `<head>` (byte-offset proven),
  viewport present, `<title>` HTML-escaped (XSS-safe incl. `</title>` injection + raw `<`/`>`/
  quotes), `<body>` wraps exactly one `<pre>`, page bg = terminal bg, default body margin 0,
  em-dash in contextual title, OSC 8 → `<a>`, truecolor, 256-color, unicode/emoji/wide chars,
  huge scrollback (2000 lines: first+last retained), CRLF + truncated-ANSI-at-EOF inputs.
- Verified prior-bug fixes hold: apostrophe-in-`@tmux-2html-title` (`shell_escape` + `/bin/sh
  -n`), `--font` XSS (`&quot;`/`&lt;` escaping), `--lang` empty = locale (Issue 4), nested
  `--output` makePath (Issue 3).
- All tmux integration used **isolated, uniquely-named sockets** (`-L t2h-qa-$$` etc.);
  PRD §0 honored — the user's live `main` session was verified intact before and after every
  test; teardown was `kill-session -t <name>` on my own named sockets only, never
  `kill-server`/`killall`/`pkill`.

**Overall quality assessment:** The core is **strong**. The §8.1 HTML envelope is fully
compliant across every output path; the prior XSS/quoting/makePath bugs are fixed and
covered by regression tests; capture/render/pane/sync-palette all behave correctly including
truncation, concurrency, and exit codes. **Two Major issues** were found, both in paths the
implementation's own comments show the authors were aware of but guarded only partially:
(1) the `region` confirm action does not honor PRD §13's "empty/zero-cell selection" guard
(the sibling `render --selection` path does), and (2) `render --cols 0` / `--rows 0`
segfault because `render.run()` passes the value straight to `Terminal.init` without the
`≥1` lower-bound guard that the `pane` path already has.

---

## Critical Issues (Must Fix)

None. (No bug prevents the primary happy-path capture→HTML flow from working with sane
default/explicit options. Both findings below are Major robustness/correctness gaps on
degenerate-but-accepted inputs and an explicit PRD edge case.)

---

## Major Issues (Should Fix)

### Issue 1: `region` confirm writes an empty-body HTML file (exit 0) for a blank-cell selection — violates PRD §13

**Severity**: Major
**PRD Reference**: §13 ("Empty/zero-cell selection on confirm: warn, no file written, exit
  `1`"), §7.5 (confirm/cancel contract). The PRD §13 requirement is *specifically* about the
  region TUI's `Enter`/`y` confirm action (the `render --selection` path is a direct CLI
  invocation, not a "confirm").
**Expected Behavior**: When the user confirms a selection whose rendered body is empty or
  all-whitespace (e.g. the selection covers only blank cells — a single trailing blank line,
  a blank prompt line, or an empty rectangle), `tmux-2html region` must **warn, write no
  file, and exit 1** — exactly as the `render --selection` path already does.
**Actual Behavior**: The region confirm path writes a **complete-but-empty-body** HTML
  document (a valid `<!DOCTYPE html>…</html>` whose `<pre>` body is empty), writes the bare
  path to the `.last-output` sidecar, and **exits 0**. The user gets a confusing empty HTML
  page opened in the browser and a "wrote <path>" status message pointing at a file with no
  terminal content.

**Steps to Reproduce** (against an isolated tmux server — PRD §0 safe):
  1. Build: `zig build --release=fast`.
  2. Create an isolated server and a pane with some content:
     ```sh
     SOCK="t2h-repro-$$"; tmux -L "$SOCK" new-session -d -s s -x 20 -y 6
     PANE=$(tmux -L "$SOCK" list-panes -t s -F '#{pane_id}' | head -1)
     tmux -L "$SOCK" send-keys -t s "echo realcontent" Enter; sleep 0.4
     ```
  3. Drive `region` via a pty: the TUI enters with the cursor on the bottom row (the shell's
     current, blank input line). Press `v` (begin linewise selection at the cursor) then
     `Enter` (confirm) **without moving the cursor**:
     ```sh
     TMUX="/tmp/tmux-$UID/$SOCK,0,0" python3 - <<'PY'
     import os,pty,select,time
     pid,fd=pty.fork()
     if pid==0:
         os.execvpe("./zig-out/bin/tmux-2html",
                    ["tmux-2html","region","--target",os.environ["PANE"],
                     "--output","blank.html"],os.environ.copy())
     time.sleep(0.8); os.write(fd,b"v"); time.sleep(0.2); os.write(fd,b"\r")
     # ...wait for exit...
     PY
     ```
  4. Observe: `blank.html` exists (~430 bytes), its `<pre>` body is empty, exit code is 0,
     and `$TMUX_2HTML_BIN/.last-output` contains `blank.html`.

**Contrast (the correct behavior already exists in the sibling path):**
  ```sh
  printf '     \n' | ./zig-out/bin/tmux-2html render --cols 5 --rows 1 --selection 0,0,4,0
  # => "tmux-2html render: selection is empty", exit 1, NO file written
  ```

**Root cause**: `src/region.zig` (the `.confirm =>` arm, around line 445) only guards
  `if (!ctx.sel.active())` — i.e. "was a selection *begun*?". Its own comment
  (`// "Empty" == no selection begun (sel inactive)`) reveals the misreading: PRD §13's
  "empty/zero-cell selection" means a selection that *renders zero non-blank cells*, not
  merely an inactive one. An *active* selection over blank cells passes the guard and is
  rendered+written unconditionally. `renderSelectionHtml` never consults the emptiness of the
  fragment it produces.

**Why standard validation missed it**: the §8.1 envelope smoke test drives region confirm
  from the *top* of the scrollback (non-blank rows), and `render --selection`'s
  `selectionBodyEmpty` test only covers the CLI path. No test drives a region confirm over
  blank cells.

**Suggested Fix**: After producing the fragment in `region.zig`'s confirm arm (or inside
  `renderSelectionHtml`), reuse the **existing** `render.selectionBodyEmpty()` helper
  (`src/render.zig:609`, already `fn`-private — make it `pub` or add a thin `pub` wrapper) on
  the rendered `<pre>` fragment. If empty, print `tmux-2html region: selection is empty\n` to
  stderr and `break :confirm_render 1` **before** writing the file or the `.last-output`
  sidecar. This mirrors `render.run()`'s `--selection` arm (`src/render.zig:789`) exactly.
  Add a region integration test (python3 pty) that confirms over a known-blank row and
  asserts exit 1 + no output file + no sidecar.

---

### Issue 2: `render --cols 0` and `render --rows 0` segfault (core dump) — uncontrolled crash on accepted CLI input

**Severity**: Major
**PRD Reference**: §5.1 (`--cols N` / `--rows N`), §5 ("Exit codes: 0 success, 1 usage/
  runtime error, 2 capture/target error"), §0.1 ("Keep harnesses bounded … so a test or
  diagnostic can't destabilize the machine" / prefer graceful failure). A segfault is none of
  the defined exit codes and produces a core dump.
**Expected Behavior**: `tmux-2html render --cols 0` / `--rows 0` should fail gracefully —
  print a one-line usage error and exit `1` (usage error), exactly as `--cols abc` already
  does. The CLI parser (`parseU16`) accepts `0`, so the renderer owns the validation.
**Actual Behavior**: **Segmentation fault (core dumped), exit 139.** Reproducible 100% of
  the time (3/3 runs for `--cols 0`, 2/2 for `--rows 0`); `--cols 0 --selection …` also
  segfaults. Boundary values `--cols 1` / `--rows 1` work fine.

**Steps to Reproduce**:
  ```sh
  zig build --release=fast
  printf 'x\n' | ./zig-out/bin/tmux-2html render --cols 0     # => Segmentation fault, exit 139
  printf 'x\n' | ./zig-out/bin/tmux-2html render --cols 5 --rows 0   # => Segmentation fault, exit 139
  printf 'x\n' | ./zig-out/bin/tmux-2html render --cols 0 --selection 0,0,0,0  # => Segmentation fault, exit 139
  printf 'x\n' | ./zig-out/bin/tmux-2html render --cols 1     # => exit 0 (boundary OK)
  ```

**Root cause**: `src/render.zig` — `determineCols()` (line ~96) returns the explicit
  `--cols` value **unchecked** (`if (opts_cols) |c| return c;` — no lower bound), and
  `render.run()` (lines ~753–757) passes `cols`/`rows` straight into `Size{}` →
  `renderDocument` → `renderGrid` → `Terminal.init(.{ .cols = 0, … })`, which segfaults in
  the ghostty-vt `Terminal`. The codebase **already knows** about this exact crash: the
  `pane` path explicitly short-circuits on `cols=0` to avoid it
  (`src/main.zig:504`: *"feeding ghostty-vt a zero-dimension terminal (Terminal.init
  cols=0) segfaults. Report the summary + exit"*) — but the `render` subcommand never got the
  same guard. (`lineCount` is floored at 1, so only an *explicit* `--rows 0` triggers the
  rows variant; `--cols 0` is the more natural typo.)

**Why standard validation missed it**: every render test/golden uses `--cols` ≥ 1 (e.g. 40).
  No test exercises the degenerate `0` value the parser accepts.

**Suggested Fix**: In `render.run()` (or `determineCols`), reject `cols == 0` / `rows == 0`
  *before* constructing `Size`. Simplest: after computing `cols`/`rows`, if either is `0`,
  write `tmux-2html render: --cols and --rows must be >= 1\n` to stderr and `return 1`.
  (For `--cols`, folding it into `determineCols` as a new `SizeError` — e.g. reuse
  `error.InvalidWindowSize` — would also unify it with the tty-derived zero-size path that
  already exits 2 via `reportSizeError`; either exit 1 or 2 is acceptable per PRD §5, the key
  is *no segfault*.) Add a unit/integration test: `render --cols 0` and `--rows 0` each exit
  non-zero with a message and write nothing to stdout. Consider the same guard in `region`
  defensively (region derives `cols` from capture, which is always ≥1 for a real pane, but a
  degenerate pane geometry would reach the same `Terminal.init`).

---

## Minor Issues (Nice to Fix)

### Issue 3: Stale `.last-output` sidecar residue after a region confirm over blank cells (consequence of Issue 1)

**Severity**: Minor (cosmetic / side-effect of Issue 1)
**PRD Reference**: §9.3 / §7.5 (the `.last-output` sidecar contract). Once Issue 1 is fixed
  (no file written on empty-cell confirm), the sidecar is naturally not written either. Noted
  only because `scripts/preflight.sh` flags the residue.
**Expected Behavior**: A cancelled or empty-confirm region run leaves no `.last-output`.
**Actual Behavior**: Today, the empty-cell confirm (Issue 1) writes the sidecar pointing at
  the empty HTML file, so `$TMUX_2HTML_BIN/.last-output` lingers.
**Suggested Fix**: Resolved implicitly by the Issue 1 fix (write the sidecar only *after* the
  non-empty render succeeds). No separate work.

### Issue 4: `check-safety.sh` emits WARNs for PATH-shim recipes inside `plan/002_*/…/PRP.md`

**Severity**: Minor (noise, not a defect)
**PRD Reference**: AGENTS.md §3 (the approved shim is `scripts/with-tmux-audit.sh`).
**Observed**: `scripts/check-safety.sh` reports 16 WARNs (0 FAILs), all matched inside
  `plan/002_e3d8d22c088d/P1M1T3S1/PRP.md` — these are *documented* test-harness recipes
  (PATH-prepend + absolute-path `exec`), not live code, and are in the human-owned `plan/`
  tree. The shipped `scripts/with-tmux-audit.sh` and `tests/*.sh` are clean.
**Suggested Fix**: None required for correctness. If the WARN noise is undesirable, the
  `check-safety.sh` grep could scope its WARN rule to skip `plan/` (the FAIL rule already
  correctly finds nothing actionable). Leaving `plan/` docs alone is also acceptable.

---

## Testing Summary

- **Total tests performed:** ~70 distinct scenarios across render / pane / region /
  sync-palette / CLI / envelope / palette / plugin / safety.
- **Passing:** the overwhelming majority — all unit tests, both shell harnesses, every §8.1
  envelope path, all prior-bug regressions (XSS, quoting, makePath, lang), capture/truncation,
  concurrency, exit-code contract, OSC8/unicode/emoji/wide-char/scrollback fidelity.
- **Failing (bugs found):** 2 Major (Issue 1: region empty-cell confirm; Issue 2: render
  `--cols 0`/`--rows 0` segfault), + 2 Minor consequences/noise.
- **Areas with good coverage:** §8.1 HTML document envelope (excellent — every output path,
  byte-verified); CLI parsing + exit codes; title/lang/font escaping (XSS-hardened); capture
  + truncation math + collision-safe filenames + concurrency; palette precedence
  (cached→live→default); plugin option threading + binding `shell_escape`; selection model
  (line/block/toggle/swap/re-anchor) unit coverage.
- **Areas needing more attention:** the **region confirm→render integration** (Issue 1 shows
  the only integration-tested confirm path used non-blank rows, leaving the blank-cell guard
  untested); **degenerate dimension inputs** to `render` (Issue 2 — no test passes `--cols 0`);
  the `render --cols 0`/`--rows 0` lower bound is the one place the `pane` path's hard-won
  `Terminal.init` segfault guard was not propagated to the sibling subcommand.
