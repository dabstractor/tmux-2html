# Bug Fix Requirements

## Overview

End-to-end validation of the **§8.1 HTML Document Envelope Configurability** delta
(P1.M1, marked Complete) plus broader integration testing of the `render` / `pane` /
`region` capture paths against the PRD.

**Testing performed:**
- Built `zig build --release=fast` (clean) and ran `zig build test --release=fast` (all
  tests pass: golden byte-equal, selection goldens, CLI parse, lang resolver, envelope
  structure, capture/truncation math, plugin option threading).
- Ran the two shipped shell harnesses: `tests/plugin_options.sh` (PASS) and
  `tests/envelope_smoke.sh` (PASS — drives region confirm via python3 pty).
- Drove the **real binary** through every HTML output path: `render` (stdout / `--output`
  / `--open`→temp / `--selection` linewise + block / `--title` / `--lang` / C-locale→en),
  `pane` (`--visible` / `--full` / default / `--history` truncation / `--title` /
  `--lang`), `region` (confirm via pty, `--title`/`--lang` override, empty-selection
  guard), `sync-palette` (no-tty / `--force` / `--from file`), `--version`, `--help`,
  unknown subcommand, exit-code contract (0/1/2).
- Verified §8.1 envelope requirements explicitly: `<!DOCTYPE html>` first, single
  `<html lang>` root, `<meta charset="utf-8">` FIRST in `<head>` (byte-offset proven),
  viewport present, `<title>` HTML-escaped (XSS-safe incl. `</title>` injection),
  `<body>` wraps exactly one `<pre>`, page bg = terminal bg, default body margin 0,
  em-dash (U+2014) in contextual title, OSC 8 hyperlinks, truecolor, 256-color,
  unicode/emoji.
- Verified locale lang precedence (LC_ALL > LC_MESSAGES > LANG > en) and BCP-47
  normalization.
- All tmux integration used an **isolated, uniquely-named socket** (`-L t2h-qa-$$`);
  PRD §0 honored — the user's live `default` socket was never touched; teardown was
  `kill-session -t <name>` only.

**Overall quality assessment:** The §8.1 envelope core is **excellent** — every output
path emits a complete, valid HTML5 document, `<title>` is correctly HTML-escaped, and
the `--title` / `--lang` / locale configurability works perfectly when the binary is
invoked directly. Two **Major** issues were found in how user-supplied strings reach
the output, plus one minor. The golden/envelope test suites are thorough on
`<title>` but blind to these two vectors.

---

## Critical Issues (Must Fix)

None. (No bug prevents the primary happy-path capture→HTML flow from working with
default/unset options.)

---

## Major Issues (Should Fix)

### Issue 1: Apostrophe in `@tmux-2html-title` silently breaks ALL prefix bindings

**Severity**: Major
**PRD Reference**: §8.1 (`@tmux-2html-title` configurability), §9.2 (option table),
  §9.3 (bindings). Introduced by the completed task P1.M1.T2.S1 (title threading).
**Expected Behavior**: Setting `set -g @tmux-2html-title "Bob's pane"` and pressing the
  `O` (full), visible, or `C-o` (region) prefix key should capture the pane and produce
  an HTML document whose `<title>` is `Bob's pane`.
**Actual Behavior**: **All three bindings silently fail.** No HTML is produced and the
  status line shows an empty message (`tmux-2html: `). The capture subprocess never
  runs because the generated `run-shell` command is invalid shell syntax.

**Steps to Reproduce**:
  1. Build the binary (`zig build --release=fast`).
  2. Reproduce the plugin's binding generation and the resulting shell parse:
     ```sh
     # What tmux-2html.tmux builds (line: title_arg="--title '$title_opt'")
     title_opt="Bob's pane"
     title_arg=""
     [ -n "$title_opt" ] && title_arg="--title '$title_opt'"
     echo "$title_arg"        # => --title 'Bob's pane'   (unbalanced single quotes!)

     # What run-shell fires (#{pane_id} expanded to %0):
     /bin/sh -c "out=\$(/path/tmux-2html pane --full $title_arg --target '%0' 2>/dev/null); \
                 tmux display-message \"tmux-2html: \$out\""
     # => /bin/sh: -c: line 1: unexpected EOF while looking for matching `''
     #    capture subprocess never starts; $out is empty; no HTML file written.
     ```
  3. Confirm with the real binary against an isolated tmux socket: the pane subprocess
     is never invoked and no `.html` is written; `2>/dev/null` swallows the parse error
     so the user sees only an empty status message.

**Root cause**: `tmux-2html.tmux` wraps the option value in **naive single quotes**
  (`title_arg="--title '$title_opt'"`; same pattern for `lang_arg`). A literal
  apostrophe inside the value terminates the single-quoted string early, leaving an
  unbalanced quote that breaks `/bin/sh` parsing of the whole `run-shell` command.
  This affects all three bindings (`O` full, the optional visible key, and the `C-o`
  region `display-popup`) because they all interpolate `$title_arg`.

**Scope of trigger**: ONLY the apostrophe `'` breaks (verified by testing plain,
  `"`, `$`, `` ` ``, `;`, `&`, `(` `)`, and unicode — all others survive single-quote
  wrapping). `@tmux-2html-lang` is **not** affected because its value is normalized to
  a BCP-47 tag (which cannot contain an apostrophe) before threading.

**Why standard validation missed it**: `tests/plugin_options.sh` asserts the threading
  with the benign value `"My Pane"` (no apostrophe), so the quoting is never stress-tested.

**Suggested Fix**: Don't hand-wrap in single quotes — pass the value through the binary
  via an already-safe channel, OR properly escape. Options:
  - **Preferred:** Shell-escape the value with the POSIX-safe idiom that turns `'`
    into `'\''`: e.g. build `title_arg` as `--title <escaped>` where `<escaped>` is the
    value wrapped in single quotes with every embedded `'` replaced by `'\''`. The same
    for `lang_arg`. Add a `tests/plugin_options.sh` case with an apostrophe title.
  - **Alternative:** Have the binary (not the plugin) read `@tmux-2html-title` /
    `@tmux-2html-lang` via `show-option` (as it already does for font/open/output-dir),
    and stop threading them as CLI flags. This removes the shell-quoting layer entirely
    and matches how the other §9.2 options are handled. (Note: the PRD/comments
    deliberately chose CLI-threading for title/lang, so the escape fix is the
    lower-risk change.)
  - In either case, add a plugin test that sets `@tmux-2html-title "Bob's pane"` and
    asserts the bound command both (a) parses under `/bin/sh -n` and (b) yields the
    expected `--title` argv token.

---

### Issue 2: HTML attribute injection / stored-XSS via `--font` / `@tmux-2html-font`

**Severity**: Major
**PRD Reference**: §8.1 ("a standalone HTML document you can open, share, and trust in
  any browser" and "All text inserted into the envelope (`<title>`, etc.) is
  HTML-escaped"), §5.1 (`--font FAMILY`), §9.2 (`@tmux-2html-font`). Pre-existing in the
  absorbed formatter, but it violates the §8.1 trust/escaping guarantee and standard
  validation is blind to it (goldens assert `<title>` escaping only).
**Expected Behavior**: A user-supplied font family is rendered safely into the
  `<pre style="font-family: …">` attribute; a value containing `"`, `<`, `>`, etc. is
  HTML-escaped so it cannot break out of the attribute or inject markup. This matters
  because tmux-2html output is explicitly designed to be **shared and opened in any
  browser** (§8.1).
**Actual Behavior**: The font value is inserted into the `<pre>` `style` attribute
  **unescaped**. A double-quote in the value breaks out of the attribute and injects
  **arbitrary HTML attributes** — including DOM-event handlers that execute JavaScript
  when the shared HTML is viewed.

**Steps to Reproduce**:
  ```sh
  # (a) via the CLI --font flag (render / pane / region all share the formatter):
  printf 'x\n' | ./zig-out/bin/tmux-2html render --cols 3 --rows 1 \
      --font 'a" onmouseover="alert(document.domain)'
  # Emits:
  # <pre class="term2html-output" style="max-width: 3ch; ...font-family: a"
  #      onmouseover="alert(document.domain);">x</pre>
  # A parser confirms a second attribute `onmouseover` is now attached to <pre>.

  # (b) via the @tmux-2html-font tmux option (read by pane/region via show-option):
  tmux set-option -g @tmux-2html-font 'bad" onmouseover="alert(1)'
  # ...any subsequent O / visible / C-o capture bakes the payload into the HTML.
  ```
  The injected `onmouseover` handler fires when a victim hovers the terminal content
  (a natural interaction when reading captured output). Other breakouts (`onfocus` +
  `tabindex`, overlay `style`, etc.) are also reachable. Angle brackets in the value
  stay inside the quoted style string and do **not** inject tags, so the vector is
  specifically attribute breakout via `"` (and, defensively, `'` `<` `>`).

**Why it matters / threat model**: This is a **stored-XSS** vector in output that §8.1
  says should be trustworthy to share. Scenario: a user copies a `tmux.conf` snippet
  (or receives one) containing a crafted `@tmux-2html-font`; every HTML they generate
  and share executes attacker-controlled JS in recipients' browsers. Even in single-user
  use it lets a careless font value corrupt the document's structure/trust.

**Why standard validation missed it**: `testdata/*.html` goldens and the envelope unit
  tests cover the **`<title>`** field escaping (verified: `</title><script>` is safely
  escaped to `&lt;/title&gt;&lt;script&gt;`). No golden or test exercises a `--font`
  value containing a double-quote, so the `<pre style>` injection is uncaught. The §8.1
  helper `writeEscaped` is correct; the gap is that `--font` flows into the formatter's
  `<pre>` **without** going through any escaping.

**Suggested Fix**: HTML-escape the font family before emitting it into the `style`
  attribute (at minimum escape `"` → `&quot;`; for defense-in-depth also `'` `<` `>` `&`,
  matching `writeEscaped`). The natural home is wherever the `font-family:` CSS
  declaration is generated (the absorbed `ScreenFormatter` block in
  `src/ghostty_format.zig` / the `renderGrid` path), or — if the formatter is treated as
  immutable upstream code — wrap/escape the `opts.font` value at the `render`/`pane`/
  `region` call boundary before handing it to the formatter. Add a golden/test case with
  `--font 'a"b'` asserting the emitted `style` contains `font-family: a&quot;b` (or
  equivalent safe encoding) and that no extra attribute can be introduced.

---

## Minor Issues (Nice to Fix)

### Issue 3: `render --output` does not create parent directories

**Severity**: Minor
**PRD Reference**: §5.1 (`--output FILE write here instead of stdout`).
**Expected Behavior**: Writing to a path whose parent directory does not yet exist
  either creates the directory tree or documents that the directory must pre-exist.
**Actual Behavior**: `pane` calls `makePath(out_dir)` before writing, but `render`
  does not — `render --output nested/deep/out.html` fails with
  `tmux-2html render: cannot write output file` and exit 1 when `nested/deep/` is
  absent. The two subcommands are inconsistent for what is the same `--output` flag.
**Steps to Reproduce**:
  ```sh
  rm -rf nested
  printf 'hi\n' | ./zig-out/bin/tmux-2html render --cols 5 --rows 1 \
      --output nested/deep/out.html   # => exit 1, "cannot write output file"
  ```
**Suggested Fix**: Either `makePath(dirname(path))` in the `render` `--output` path
  (mirroring `pane`), or document in the `render --help` text that the parent directory
  must exist. Small inconsistency, low impact.

### Issue 4: `--lang ""` (explicit empty) yields `en` rather than locale-derived

**Severity**: Minor (behavior clarification)
**PRD Reference**: §8.1 (`<html lang>` default `en`; configurable via locale).
**Expected Behavior**: Arguably an explicit empty `--lang ""` should mean "derive from
  locale" (the documented default), consistent with how the plugin omits the flag when
  the option is unset.
**Actual Behavior**: `resolveLang("")` calls `toBcp47("")` which returns null (length <
  2), so it falls back to `"en"` — i.e. an explicit empty string skips locale
  derivation and forces `en`.
**Steps to Reproduce**:
  ```sh
  # Under LANG=de_DE.UTF-8:
  printf 'hi\n' | ./zig-out/bin/tmux-2html render --cols 5 --rows 1 --lang '' \
    | grep '<html'      # => <html lang="en">   (locale de-DE ignored)
  ```
**Impact**: Very low — the plugin never passes `--lang ""` (it omits the flag via the
  `[ -n "$lang_opt" ]` guard), so this only affects direct CLI use of `--lang ""`. The
  current "explicit invalid → en" behavior is internally consistent and defensible; just
  note it is a deliberate choice (or, if locale-derivation is preferred for the empty
  case, treat an empty explicit value as null in `resolveLang`).

---

## Testing Summary

- **Total tests performed**: ~70 distinct checks across build, unit/golden, shell
  harnesses, and live binary integration (all 3 subcommands, all output paths, error/
  exit-code matrix, edge/special-char inputs, locale/lang matrix, pty-driven region TUI,
  concurrent runs, isolated-tmux capture).
- **Passing**: the §8.1 envelope core and the happy-path capture→HTML flow for all
  three modes (render/pane/region) with default and configured options. Build clean;
  `zig build test` green; both shell harnesses green; goldens byte-equal.
- **Failing / issues filed**: 2 Major (Issue 1 apostrophe-in-title silent binding
  failure; Issue 2 font HTML-attribute injection / stored-XSS) + 2 Minor.
- **Areas with good coverage**: the §8.1 envelope itself (DOCTYPE/charset-first/
  viewport/escaped-title/page-bg/single-`<pre>`/single-`<html>`), `--title`/`--lang`
  CLI + locale/BCP-47 resolution (all three subcommands, all output arms), golden
  byte-equality, exit-code contract, capture/truncation, OSC 8 / truecolor / 256 /
  unicode fidelity, plugin option threading (non-adversarial values), region confirm/
  empty-guard via pty.
- **Areas needing more attention**: adversarial / special-character inputs crossing the
  **shell-quoting boundary** (Issue 1: `@tmux-2html-title` → binding) and the
  **HTML-attribute boundary** (Issue 2: `--font`/`@tmux-2html-font` → `<pre style>`).
  These are exactly the two vectors the current golden/plugin tests do not exercise.
  Recommend adding: (a) a `plugin_options.sh` case with an apostrophe title; (b) a
  golden/unit case with a double-quote in `--font`.