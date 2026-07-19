# Research Findings — P1.M1.T1.S1 (shell_escape for title_arg/lang_arg)

> Every claim below was verified empirically against the live tree + real
> `/bin/sh` (dash) on 2026-07-19. Shell quoting is too fiddly to reason about
> abstractly; the test design was proven to (a) FAIL before the fix and (b) PASS
> after, with one important trap (the "even-quote" case) caught and worked around.

## 1. The bug, confirmed

`tmux-2html.tmux:116` `title_arg="--title '$title_opt'"` wraps the value in naive
single quotes. With `title_opt="Bob's pane"`:
- `title_arg` = `--title 'Bob's pane'` (the embedded `'` closes the single-quote
  string early → unbalanced at `/bin/sh` parse time).
- Reproduced: `/bin/sh -n -c '<O-binding-cmd with buggy title_arg>'` → exit 2,
  `unexpected EOF while looking for matching '''`. Confirmed exactly per Issue 1.

## 2. The fix, confirmed working

Canonical `shell_escape` (from `architecture/external_deps.md §POSIX Shell
Single-Quote Escaping`), proven:
```sh
shell_escape() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
```
- `shell_escape "Bob's pane"` → `'Bob'\''s pane'` ✓
- `shell_escape "My Pane"`   → `'My Pane'` (benign value unchanged ⇒ existing
  test (b) still passes — it greps for `--title 'My Pane'`).
- `shell_escape "a'b'c"`     → `'a'\''b'\''c'` ✓
- metacharacters (`$ \` ; &`) stay safely inside single quotes → `'a$b`c;d&e'` ✓

The edit (TWO lines + the new function; binding lines 160/166/205 are UNCHANGED
because they interpolate `$title_arg`/`$lang_arg`):
- L116 `title_arg="--title '$title_opt'"` → `title_arg="--title $(shell_escape "$title_opt")"`
- L118 `lang_arg="--lang '$lang_opt'"`    → `lang_arg="--lang $(shell_escape "$lang_opt")"`
- shell_escape() defined in §3 right after `read_opt()` (line 66), BEFORE the
  title_arg/lang_arg construction (line 115).

## 3. EXACT line anchors in tmux-2html.tmux (current HEAD)

- `read_opt()`          → line 66  (§3 starts line 60). Define shell_escape() right after.
- `title_opt=`/`lang_opt=` → lines 109/110.
- title_arg/lang_arg construction → lines 115–118 (lines 116 & 118 are the edits).
- `export title_opt lang_opt title_arg lang_arg` → line 119.
- §4 debug seam writes title_arg/lang_arg → lines 135–136.
- O/full binding  → line 160 (`pane --full $title_arg $lang_arg`)
- visible binding → line 166 (`pane --visible $title_arg $lang_arg`)
- C-o/region binding → line 205 (`... region $title_arg $lang_arg ...`)
- All three interpolate the vars UNQUOTED; only the var construction changes.

## 4. THE EVEN-QUOTE TRAP (critical — contract's /bin/sh -n idea is not uniformly reliable)

The contract says "assert the captured bound command parses under /bin/sh -n" for
all 3 bindings. Empirically this is **not a reliable detector** when MULTIPLE
apostrophe-bearing values are present:

- ONE apostrophe value (title OR lang, the other empty) → the buggy naive quotes
  yield an ODD single-quote count in the `/bin/sh -c` string → unbalanced →
  `/bin/sh -n` exit 2. **CAUGHT.** ✓
- TWO apostrophe values (title="Bob's pane" AND lang="it's") → buggy naive quotes
  yield an EVEN single-quote count → they re-pair across token boundaries → the
  string parses (`/bin/sh -n` exit 0) even though the argv is corrupted. **NOT
  CAUGHT.** ✗ (verified: `O BOTH BUGGY exit: 0`).

➡ **The reliable universal detector is the debug-seam escaped-value check**
(`grep -qF "title_arg=--title 'Bob'\''s pane'"`): it directly verifies the `'\''`
escape sequence is present, independent of quote-count arithmetic. Use /bin/sh -n
only as a SUPPLEMENTARY end-to-end check, and only with a SINGLE apostrophe value
(odd count) so it's reliable.

## 5. The region binding has a SECOND quoting layer (also verified)

For O/full + visible, `$title_arg` is interpolated at the TOP level of the
`run-shell` `/bin/sh -c` script → `/bin/sh -n` on the captured command catches the
bug (odd-count case).

For region, `$title_arg` is interpolated INSIDE the double-quoted `display-popup`
argument (`display-popup -E ... "… region $title_arg …"`). Inside double quotes,
single quotes are literal, so `/bin/sh -n` on the captured run-shell command
passes even when buggy. The bug bites one layer DEEPER: when `display-popup`
re-runs the inner popup command via `/bin/sh`. So for region, extract the INNER
command and `/bin/sh -n` THAT:
```sh
inner=$(printf '%s' "$rline" | sed 's/.*display-popup -E -w 100% -h 100% "//; s/"; if.*//')
/bin/sh -n -c "$inner"
```
(verified: region inner buggy→exit 2, fixed→exit 0, odd-count case.)

## 6. Robust test design (proven FAIL-before / PASS-after)

- **(c) title apostrophe, lang EMPTY** (odd count ⇒ reliable /bin/sh -n):
  `run_loader "Bob's pane" "" "v"`; assert debug seam
  `grep -qF "title_arg=--title 'Bob'\''s pane'"`; assert `^lang_arg=$`; then
  /bin/sh -n on the O + visible captured commands AND the region INNER command.
- **(c2) lang apostrophe, title EMPTY** (reliable via the seam):
  `run_loader "" "it's" "v"`; assert `grep -qF "lang_arg=--lang 'it'\''s'"`.
- DO NOT test both apostrophes in one run_loader for /bin/sh -n (even-quote trap).

## 7. grep pattern correctness (proven byte-exact)

`grep -qF "title_arg=--title 'Bob'\''s pane'" "$DBG"`:
- inside POSIX double quotes, `\'` is preserved literally as `\'` (backslash only
  special before `$ \` " \ newline`) → the -F pattern is literally
  `title_arg=--title 'Bob'\''s pane'` = the fixed debug line. ✓
- matches ONLY the escaped (fixed) form; the buggy line (`…'Bob's pane'`, no `\`)
  does NOT match. ✓ (verified.)

## 8. Validation gates (verified on current tree)

- `sh tests/plugin_options.sh` → baseline PASS (exit 0). After fix+test(c)/(c2),
  still PASS.
- `sh scripts/check-safety.sh` → baseline `0 FAIL, 16 WARN` (ALL 16 WARNs are in
  `plan/**/PRP.md` doc files describing shim recipes; NONE in scripts/ or
  tmux-2html.tmux; exit 0). The fix adds a `sed` call inside shell_escape() — no
  PATH-prepend, no `>> calls.log` — so it adds ZERO new FAIL/WARN. R3 requires
  BOTH a PATH-prepend AND an exec/>> sink in one file; tmux-2html.tmux has neither.
  R4 matches only `>> …calls.log`; the debug seam writes to `$TMUX_2HTML_DEBUG`.

## 9. Safety (AGENTS.md §1) — this task is safe

- NO tmux shim is created (we only EDIT option construction in an existing script).
- NO real tmux touched (the test uses the existing mock `tmux()` in plugin_options.sh).
- `/bin/sh -n` is SYNTAX-ONLY (no execution) — cannot run anything.
- NO unbounded `>>` logs (shell_escape uses `$(…)` command substitution, not `>>`).