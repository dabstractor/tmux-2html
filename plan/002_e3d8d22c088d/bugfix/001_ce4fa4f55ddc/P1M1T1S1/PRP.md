# PRP — P1.M1.T1.S1: POSIX `shell_escape` for `title_arg`/`lang_arg` + adversarial test

## Goal

**Feature Goal**: Fix Issue 1 — an apostrophe in `@tmux-2html-title` (e.g.
`"Bob's pane"`) silently breaks ALL three prefix bindings, because
`tmux-2html.tmux` wraps the option value in naive single quotes
(`title_arg="--title '$title_opt'"`) and the embedded `'` unbalances the
`run-shell` command's `/bin/sh` parse. Add a POSIX `shell_escape()` function that
turns every embedded `'` into `'\''` and use it to build `title_arg`/`lang_arg`;
add an adversarial plugin test that proves the bindings still parse with an
apostrophe present.

**Deliverable**: Two edited files + one docs tweak:
1. `tmux-2html.tmux` — add `shell_escape()` in §3 (after `read_opt()`); change the
   `title_arg` and `lang_arg` construction lines to use it.
2. `tests/plugin_options.sh` — add test case (c) (title apostrophe) and (c2)
   (lang apostrophe) asserting the POSIX-escaped form in the debug seam AND that
   the bound commands parse under `/bin/sh -n`.
3. `docs/CONFIGURATION.md` — one-sentence note that threaded values are
   shell-escaped (Mode A, rides with the work).

**Success Definition**: `sh tests/plugin_options.sh` prints PASS (exit 0);
`sh scripts/check-safety.sh` shows `0 FAIL` and no NEW WARN vs baseline (the
baseline already has 16 WARNs, all in `plan/**/PRP.md` docs — none in scripts or
`tmux-2html.tmux`). A benign title (`"My Pane"`) still produces
`--title 'My Pane'` (existing test (b) unchanged). No tmux shim is created and no
real tmux is touched.

## Why

- **Correctness**: with the bug, setting `@tmux-2html-title "Bob's pane"` makes
  the `O` (full), visible, and `C-o` (region) bindings silently no-op (the
  capture subprocess never starts; `2>/dev/null` hides the parse error; the user
  sees only an empty `tmux-2html: ` status message). Issue 1, Major.
- **Defense-in-depth**: `@tmux-2html-lang` is not affected in practice (its value
  is BCP-47-normalized and cannot contain `'`), but the same fix is applied to
  `lang_arg` so the quoting layer is uniformly safe.
- **Low-risk, surgical**: only the `title_arg`/`lang_arg` *construction* changes;
  the three binding lines are untouched (they interpolate the variables), and a
  benign value produces byte-identical output, so no golden/output regression.

## What

User-visible: a title containing an apostrophe (or any shell metacharacter) now
works — pressing `O`/visible/`C-o` captures the pane and produces HTML whose
`<title>` is the exact configured value. No more silent empty status line.

Technical:
- `shell_escape()` outputs its argument wrapped in single quotes with every
  embedded `'` replaced by `'\''` (the POSIX idiom). It is defined in §3 of
  `tmux-2html.tmux`, **before** the `title_arg`/`lang_arg` lines that use it.
- `title_arg="--title $(shell_escape "$title_opt")"` (and same for `lang_arg`).
  `shell_escape` supplies the wrapping single quotes itself, so the old hand-wrapped
  `'$title_opt'` fragment (quotes included) is fully replaced.
- The empty-option guard (`[ -n "$title_opt" ]`) is PRESERVED: empty option ⇒
  empty fragment ⇒ binary default (no behavior change).

### Success Criteria

- [ ] `tmux-2html.tmux` defines `shell_escape()` in §3 before the arg construction.
- [ ] `title_arg`/`lang_arg` built via `$(shell_escape …)`; the `[ -n ]` guard kept.
- [ ] `tests/plugin_options.sh` case (c) passes: title `"Bob's pane"` (lang empty)
      → debug seam shows `title_arg=--title 'Bob'\''s pane'` AND the O/visible
      captured commands + the region INNER popup command all parse under `/bin/sh -n`.
- [ ] `tests/plugin_options.sh` case (c2) passes: lang `"it's"` → debug seam shows
      `lang_arg=--lang 'it'\''s'`.
- [ ] Existing cases (a)/(b) still PASS unchanged (benign value byte-identical).
- [ ] `sh tests/plugin_options.sh` exits 0; `sh scripts/check-safety.sh` exits 0
      with no new FAIL/WARN.

## All Needed Context

### Context Completeness Check

_Pass: "If someone knew nothing about this codebase, would they have everything
needed to implement this successfully?"_ — Yes. The exact two lines to change, the
verbatim `shell_escape()` function, the exact insertion point, ready-to-paste test
code (proven FAIL-before/PASS-after), the precise docs paragraph, and verified
validation commands are all below. The implementer edits two shell files + one
docs line. Two non-obvious traps (the even-quote case and region's nested
quoting) are fully explained so the test actually catches the regression.

### Documentation & References

```yaml
# MUST READ - the authoritative fix recipe + canonical shell_escape
- file: plan/002_e3d8d22c088d/bugfix/001_ce4fa4f55ddc/architecture/external_deps.md
  section: "§POSIX Shell Single-Quote Escaping (Issue 1)"
  why: "Canonical shell_escape() + how tmux run-shell re-parses the bound command via /bin/sh."
  critical: "The sed expression must be s/'/'\\\\''/g (shell-reduces to s/'/'\\''/g). Copy verbatim."

- file: plan/002_e3d8d22c088d/bugfix/001_ce4fa4f55ddc/TEST_RESULTS.md  (or prd_snapshot Issue 1)
  section: "Issue 1"
  why: "The bug report: repro steps, root cause (naive single quotes), scope (only ' breaks; lang unaffected in practice)."

# MUST READ - the file being fixed (read it first; line numbers verified against HEAD)
- file: tmux-2html.tmux
  why: "THE file to edit. read_opt() at line 66; title_arg/lang_arg at lines 115-118; bindings at 160/166/205."
  pattern: "Option construction: `title_opt=$(read_opt @tmux-2html-title \"\")`; `title_arg=\"\"; [ -n \"$title_opt\" ] && title_arg=\"--title '$title_opt'\"`. Bindings interpolate `$title_arg` UNQUOTED."
  gotcha: "Define shell_escape() AFTER read_opt() (both §3 helpers) but BEFORE line 115 (the arg construction that calls it). The binding lines 160/166/205 stay UNCHANGED — they already interpolate the vars."

# MUST READ - the test harness to extend (read it first)
- file: tests/plugin_options.sh
  why: "Contains run_loader() ($1=title $2=lang $3=visible), the mock tmux(), $CAPTURE, and $DBG. Existing cases (a)/(b) are the pattern to follow."
  pattern: "run_loader sets DBG=$W/debug.txt; loader §4 writes `title_arg=%s`/`lang_arg=%s` lines; mock captures bind-key as `BK <key> run-shell <cmd>`."

- file: plan/002_e3d8d22c088d/bugfix/001_ce4fa4f55ddc/P1M1T1S1/research/findings.md
  why: "Companion note: exact anchors, the EVEN-QUOTE TRAP (why /bin/sh -n alone is unreliable), region's nested-quoting layer, proven grep patterns."
  critical: "§4 + §6: test title-apostrophe with lang EMPTY (odd quote count) for a reliable /bin/sh -n; use the debug-seam grep as the universal detector."

- file: scripts/check-safety.sh
  why: "The deterministic safety guard (AGENTS.md §3). Baseline = 0 FAIL, 16 WARN (all in plan/ PRP.md docs). The fix must add none."
  gotcha: "R3 (WARN) needs BOTH a PATH-prepend AND an exec/>> sink in one file — tmux-2html.tmux has neither. R4 matches only `>> …calls.log`. shell_escape's `$(… | sed …)` triggers neither."
```

### Current Codebase tree (relevant slice)

```bash
tmux-2html/
├── tmux-2html.tmux           # <— EDIT: add shell_escape() in §3; change title_arg/lang_arg lines
├── tests/
│   └── plugin_options.sh     # <— EDIT: add test cases (c) + (c2) for apostrophe values
├── docs/
│   └── CONFIGURATION.md      # <— EDIT: one note in the "How options are read" title/lang paragraph
├── scripts/
│   └── check-safety.sh       # run-only (validation gate); DO NOT EDIT
└── PRD.md
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
tmux-2html/
├── tmux-2html.tmux           # MODIFIED: +shell_escape() fn; title_arg/lang_arg use it (2 lines)
├── tests/plugin_options.sh   # MODIFIED: +adversarial test (c) title + (c2) lang apostrophe cases
└── docs/CONFIGURATION.md     # MODIFIED: +1 sentence (shell-escaping safety note)
# NO new files. NO Zig changes (this is a shell-only fix).
```

### Known Gotchas of our codebase & Library Quirks

```sh
# GOTCHA 1 — /bin/sh -n is NOT a uniformly reliable detector (THE EVEN-QUOTE TRAP).
#   ONE apostrophe value (title XOR lang)  => naive quotes => ODD single-quote count
#     in the /bin/sh -c string => unbalanced => /bin/sh -n exits 2. CAUGHT.
#   TWO apostrophe values (title AND lang) => EVEN count => they re-pair across tokens
#     => /bin/sh -n exits 0 even though argv is corrupted. NOT CAUGHT.
#   => The RELIABLE universal detector is the debug-seam escaped-value grep (the
#      '\'\'' sequence is present iff shell_escape ran). Use /bin/sh -n only as a
#      SUPPLEMENTARY end-to-end check, and only with a SINGLE apostrophe value.

# GOTCHA 2 — the region binding has a NESTED quoting layer.
#   For O/visible, $title_arg is at the TOP level of run-shell's /bin/sh -c script,
#   so /bin/sh -n on the captured command catches the bug (odd-count case).
#   For region, $title_arg is INSIDE the double-quoted display-popup arg
#   (`display-popup ... "...region $title_arg..."`). Single quotes are literal
#   inside double quotes, so /bin/sh -n on the captured run-shell command passes
#   even when buggy. The bug bites when display-popup RE-RUNS the inner command.
#   => For region, extract the INNER popup command and /bin/sh -n THAT:
#        inner=$(printf '%s' "$rline" | sed 's/.*display-popup -E -w 100% -h 100% "//; s/"; if.*//')

# GOTCHA 3 — shell_escape must be defined BEFORE the lines that call it.
#   Put it in §3 right after read_opt() (line 66). It is a plain shell function;
#   no `export` needed (functions are visible to later code in the same sourced file).

# GOTCHA 4 — the empty-option guard MUST be preserved.
#   `[ -n "$title_opt" ] && title_arg=...` stays. Empty option => title_arg="" =>
#   binary default. shell_escape is only called when the value is non-empty.
#   (shell_escape "" would return "''", but we never call it on empty.)

# GOTCHA 5 — benign values are byte-identical before/after the fix.
#   shell_escape "My Pane" => 'My Pane' (no embedded '). So existing test (b),
#   which greps `--title 'My Pane'`, still passes. Do NOT "also escape" the
#   benign test values.

# GOTCHA 6 — the sed expression is shell-quoted. Write EXACTLY:
#     sed "s/'/'\\\\''/g"
#   The shell reduces the double-quoted "\\\\" to "\\" and "\\'" stays, yielding
#   sed arg s/'/'\''/g (replace ' with '\''). Do not "simplify" the backslashes.

# GOTCHA 7 — command substitution $(…) strips trailing newlines. title/lang
#   values come from tmux show-option and never contain trailing newlines, so the
#   canonical one-liner is fine (no need for the "alternative without command
#   substitution" variant in external_deps.md).
```

## Implementation Blueprint

### Data models and structure

Not applicable — pure POSIX sh; no data models. The single new abstraction is the
`shell_escape()` function.

### The exact `shell_escape()` function (verbatim, from external_deps.md, proven)

```sh
# POSIX shell-escape: wrap $1 in single quotes with every embedded ' replaced by '\''.
# Usage: shell_escape "Bob's pane" -> 'Bob'\''s pane'  (safe to interpolate unquoted
# into a /bin/sh -c string). Benign values round-trip unchanged ('My Pane').
shell_escape() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: ADD shell_escape() to tmux-2html.tmux (§3, after read_opt)
  - ANCHOR: the read_opt() function ends around line 73 (defined at line 66). Insert
    shell_escape() IMMEDIATELY AFTER read_opt()'s closing brace, before the option
    reads (line 76 onward). Both are §3 helpers.
  - CONTENT: the verbatim function in the Blueprint above.
  - WHY FIRST: it must be defined before Task 2's lines execute at source time.
  - SAFETY: this is a sed pipeline in $(…) — NOT a PATH shim, NOT an unbounded log.
    scripts/check-safety.sh will still be green (see Validation §1).

Task 2: CHANGE title_arg / lang_arg construction (tmux-2html.tmux lines 116 & 118)
  - EDIT line 116:
      BEFORE:  [ -n "$title_opt" ] && title_arg="--title '$title_opt'"
      AFTER:   [ -n "$title_opt" ] && title_arg="--title $(shell_escape "$title_opt")"
  - EDIT line 118:
      BEFORE:  [ -n "$lang_opt" ] && lang_arg="--lang '$lang_opt'"
      AFTER:   [ -n "$lang_opt" ] && lang_arg="--lang $(shell_escape "$lang_opt")"
  - NOTE: shell_escape supplies the wrapping single quotes, so the old '$title_opt'
    fragment (quotes included) is fully replaced — do NOT keep stray surrounding quotes.
  - DO NOT touch the binding lines (160/166/205): they interpolate $title_arg/$lang_arg
    unchanged and now receive the escaped form automatically.
  - DEPENDENCIES: Task 1 (shell_escape must exist).

Task 3: ADD adversarial test cases (c) + (c2) to tests/plugin_options.sh
  - INSERT after the existing case (b) block, before the final `echo "PASS: …"` line.
  - CONTENT (verbatim, proven FAIL-before/PASS-after):
        # (c) Apostrophe in @tmux-2html-title MUST be POSIX shell-escaped, else the
        # naive single-quote wrap unbalances /bin/sh parsing of the run-shell command
        # and the binding silently no-ops (Issue 1). lang EMPTY here so the buggy form
        # has an ODD single-quote count (=> /bin/sh -n reliably catches it; see GOTCHA 1).
        run_loader "Bob's pane" "" "v"
        # (c.1) PRIMARY detector (reliable for all 3 bindings — they share title_arg):
        #       the debug seam must show the POSIX-escaped form, not the naive wrap.
        grep -qF "title_arg=--title 'Bob'\''s pane'" "$DBG" || fail "c: title not shell-escaped (debug seam)"
        grep -qx 'lang_arg=' "$DBG" || fail "c: lang_arg should be empty"
        # (c.2) END-TO-END: O/full + visible captured commands parse under /bin/sh -n.
        for sub in 'pane --full' 'pane --visible'; do
            cmd=$(printf '%s' "$CAPTURE" | grep -F -- "$sub" | head -1 | sed 's/^BK [^ ]* run-shell //')
            [ -n "$cmd" ] || fail "c: no '$sub' binding captured"
            /bin/sh -n -c "$cmd" 2>/dev/null || fail "c: '$sub' command fails /bin/sh -n (apostrophe not escaped)"
        done
        # (c.3) REGION has a nested quoting layer (GOTCHA 2): the bug hides inside the
        # double-quoted display-popup arg at the run-shell level, so /bin/sh -n the
        # INNER popup command that display-popup re-runs at fire time.
        rline=$(printf '%s' "$CAPTURE" | grep -F 'region' | head -1)
        [ -n "$rline" ] || fail "c: no region binding captured"
        rinner=$(printf '%s' "$rline" | sed 's/.*display-popup -E -w 100% -h 100% "//; s/"; if.*//')
        /bin/sh -n -c "$rinner" 2>/dev/null || fail "c: region inner popup command fails /bin/sh -n"
        #
        # (c2) Apostrophe in @tmux-2html-lang (defense-in-depth; BCP-47-normalized in
        #      practice so this is unlikely, but the same escaping applies). title EMPTY.
        run_loader "" "it's" "v"
        grep -qF "lang_arg=--lang 'it'\''s'" "$DBG" || fail "c2: lang not shell-escaped (debug seam)"
        grep -qx 'title_arg=' "$DBG" || fail "c2: title_arg should be empty"
  - FOLLOW pattern: existing (a)/(b) — run_loader then grep on $DBG/$CAPTURE, fail() on mismatch.
  - NAMING: test comments (c)/(c2); fail() messages prefix "c:"/"c2:".
  - GOTCHA: do NOT combine title+lang apostrophes in one run_loader for /bin/sh -n
    (even-quote trap, GOTCHA 1). The debug-seam grep is the reliable detector.
  - DEPENDENCIES: Tasks 1+2 (the fix must be in place or these FAIL — which is the point).

Task 4: UPDATE docs/CONFIGURATION.md (Mode A — one sentence)
  - ANCHOR: the "How options are read" section's LAST paragraph (the one explaining
    that @tmux-2html-title/@tmux-2html-lang are "the exception" baked into bindings
    as --title/--lang flags; ~lines 84-88).
  - ADD one sentence at the end of that paragraph, e.g.:
      "Values containing special characters (including apostrophes) are POSIX
       shell-escaped in the generated bindings, so a title like `Bob's pane` is safe."
  - DO NOT touch the options table rows (lines 48-49) or other sections.

Task 5: VALIDATE  (see Validation Loop)
  - RUN: sh tests/plugin_options.sh   → expect "PASS", exit 0
  - RUN: sh scripts/check-safety.sh   → expect "0 FAIL(s)", no new WARN vs baseline
```

### Implementation Patterns & Key Details

```sh
# PATTERN: the two-line edit. shell_escape adds the wrapping quotes; keep the [ -n ] guard.
[ -n "$title_opt" ] && title_arg="--title $(shell_escape "$title_opt")"
[ -n "$lang_opt" ]  && lang_arg="--lang $(shell_escape "$lang_opt")"

# PATTERN: the debug-seam grep is the reliable regression detector (works for ALL
# three bindings because they share title_arg/lang_arg). Inside POSIX double quotes,
# \' is preserved literally as \' (backslash is only special before $ ` " \ newline),
# so the -F pattern is exactly the fixed debug line:
grep -qF "title_arg=--title 'Bob'\''s pane'" "$DBG"

# CRITICAL: /bin/sh -n is SYNTAX-ONLY (no execution) — it cannot run the capture.
# It is safe to invoke on the captured/mock command strings in the test.
```

### Integration Points

```yaml
PLUGIN BINDINGS (tmux-2html.tmux):
  - title_arg/lang_arg (lines 116/118) now escaped; consumed UNCHANGED by bindings at 160/166/205.
  - §4 debug seam (lines 135-136) automatically reflects the escaped values (no edit needed).

TEST HARNESS (tests/plugin_options.sh):
  - run_loader() mock already returns arbitrary _T/_L seeds incl. apostrophes — no harness change.
  - $DBG (debug seam) and $CAPTURE (mock bind-key/display-popup) already captured — reused.

DOCS (docs/CONFIGURATION.md):
  - one sentence in the title/lang threading paragraph.

DOWNSTREAM / OUT OF SCOPE:
  - Issue 2 (--font HTML-attribute XSS) is a SEPARATE task (P1.M1.T2.S1) in Zig — do not touch.
  - Issues 3 & 4 (render --output mkdir; --lang "" locale) are separate tasks — do not touch.
  - Do NOT change the Zig binary; --title/--lang already accept arbitrary strings (P1.M1.T1.S1).

CONFIG / DATABASE / ROUTES:
  - none.
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# POSIX sh has no linter step; the test harness is the check. First, sanity-parse the edited script:
sh -n tmux-2html.tmux && echo "tmux-2html.tmux parses OK"          # syntax-only, no execution
sh -n tests/plugin_options.sh && echo "plugin_options.sh parses OK"

# Safety guard (AGENTS.md §3) — deterministic; must stay green:
sh scripts/check-safety.sh
# Expected: "== result: 0 FAIL(s), 16 WARN(s) ==" and exit 0. The 16 WARNs are all in
# plan/**/PRP.md docs (pre-existing) — NONE in tmux-2html.tmux or tests/. If you see a
# 17th WARN or any FAIL referencing your edited files, STOP and re-check (see GOTCHA in
# Task 1: shell_escape's $(… | sed …) must not be mistaken for a shim — it isn't).
```

### Level 2: Unit / Harness Tests (Component Validation)

```bash
# THE PRIMARY GATE for this shell fix.
sh tests/plugin_options.sh
# Expected: "PASS: …" and exit 0. Covers: (a) defaults empty; (b) benign set values;
# (c) title apostrophe (seam-escaped + /bin/sh -n on O/visible + region inner);
# (c2) lang apostrophe (seam-escaped).
#
# To PROVE the test actually catches the bug: temporarily revert ONE edit line
# (e.g. change title_arg back to "--title '$title_opt'"), re-run → case (c) must FAIL
# with "c: title not shell-escaped (debug seam)". Then restore. (This confirms the
# test is a real regression detector, not a tautology.)
```

### Level 3: Integration Testing (System Validation)

```bash
# No real tmux, no live capture — the harness mock is the integration surface (by design,
# PRD §0: never touch the user's tmux). The /bin/sh -n checks IN the harness ARE the
# end-to-end syntax proof for the generated bindings. Additionally, eyeball the escape:
sh -c '. ./tmux-2html.tmux' 2>/dev/null   # not meaningful standalone (needs TPM env); skip if it errors.
# Instead, directly exercise shell_escape in isolation (proven):
sh -c 'shell_escape() { printf "'"'"'%s'"'"'" "$(printf '"'"'%s'"'"' "$1" | sed "s/'"'"'/'"'"'\\\\'"'"''"'"'/g")"; }; shell_escape "Bob'"'"'s pane"'
# Expected output: 'Bob'\''s pane'
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Adversarial: prove the FIXED binding yields correct argv (round-trip), not just "parses".
# Simulate what run-shell fires (escaped title), and confirm /bin/sh splits --title + the value:
sh -c 'set -- --title '\''Bob'\''s pane'\''; printf "argc=%d title=[%s]\n" $# "$2"'
# Expected: argc=2 title=[Bob's pane]   (the apostrophe survives as a literal in the value token)

# Defense-in-depth sweep — other shell metacharacters must stay inert inside single quotes:
for v in 'a$b' 'a`b`c' 'a;b' 'a&b' 'a(b)' 'a"b' 'café ☕'; do
    esc=$(printf "'%s'" "$(printf '%s' "$v" | sed "s/'/'\\\\''/g")")
    /bin/sh -n -c "x=$esc" 2>/dev/null && echo "OK: $v => $esc" || echo "FAIL parse: $v"
done
# Expected: all OK (every value is safe inside the escaped single-quote wrapping).
```

## Final Validation Checklist

### Technical Validation

- [ ] `sh -n tmux-2html.tmux` and `sh -n tests/plugin_options.sh` parse clean.
- [ ] `sh tests/plugin_options.sh` → PASS, exit 0 (Level 2 — primary gate).
- [ ] `sh scripts/check-safety.sh` → `0 FAIL(s)`, exit 0, no new WARN (Level 1).
- [ ] Regression-detector proof: reverting the fix makes case (c) FAIL (Level 2 note).

### Feature Validation

- [ ] `shell_escape()` defined in §3 after `read_opt()`, before the arg construction.
- [ ] `title_arg`/`lang_arg` use `$(shell_escape …)`; `[ -n ]` empty-guard preserved.
- [ ] Test (c): title `"Bob's pane"` → seam escaped + O/visible + region-inner `/bin/sh -n` pass.
- [ ] Test (c2): lang `"it's"` → seam escaped.
- [ ] Existing (a)/(b) PASS unchanged; benign value byte-identical.
- [ ] Binding lines 160/166/205 UNCHANGED.

### Code Quality Validation

- [ ] `shell_escape` is the canonical POSIX idiom (sed expr `s/'/'\\\\''/g`), not a reinvention.
- [ ] Test uses the debug-seam grep as the reliable detector (not /bin/sh -n alone).
- [ ] No tmux shim created; no real tmux touched; `/bin/sh -n` is syntax-only.
- [ ] No unbounded `>>` logs; no PATH manipulation.
- [ ] docs/CONFIGURATION.md note added in the right paragraph (Mode A).

### Documentation & Deployment

- [ ] CONFIGURATION.md notes shell-escaping safety for title/lang values.
- [ ] No new env vars / config.

---

## Anti-Patterns to Avoid

- ❌ Don't rely on `/bin/sh -n` ALONE as the regression detector — the even-quote
  trap (two apostrophe values ⇒ even count ⇒ parses despite corruption) makes it
  unreliable. The debug-seam escaped-value grep is the reliable universal detector.
- ❌ Don't test title+lang apostrophes together in one `run_loader` for the
  `/bin/sh -n` check — use one-at-a-time (odd count) so it reliably catches the bug.
- ❌ Don't `/bin/sh -n` the region binding's *run-shell* command and call it done —
  the bug hides inside the double-quoted `display-popup` arg; extract and check the
  INNER popup command.
- ❌ Don't edit the binding lines (160/166/205) — they interpolate `$title_arg`/
  `$lang_arg` unchanged; only the arg *construction* (lines 116/118) changes.
- ❌ Don't drop the `[ -n "$title_opt" ]` empty-guard — empty option must stay
  empty-fragment (binary default), not become `--title ''`.
- ❌ Don't "also escape" the benign test value in case (b) — `shell_escape "My Pane"`
  is `'My Pane'`, so (b) passes unchanged; leave it.
- ❌ Don't simplify the sed backslashes (`s/'/'\\\\''/g`) — the shell quoting is
  load-bearing; verbatim only.
- ❌ Don't create a tmux PATH shim, touch real tmux, or add unbounded `>>` logs
  (AGENTS.md §1). This fix is a `$(… | sed …)` pipeline — safe and check-safety-green.
- ❌ Don't touch the Zig binary or stray into Issue 2/3/4 — those are separate tasks.

---

**Confidence Score: 10/10** for one-pass implementation success.

The fix is two lines + one function (verbatim from the verified architecture doc),
and the binding lines are untouched. Every shell-quoting claim was proven
empirically against real `/bin/sh`: the bug reproduces (exit 2), the fix parses
(exit 0), benign values are byte-identical (test (b) unaffected), and the
debug-seam grep distinguishes fixed from buggy byte-exactly. Two non-obvious
traps that the contract's "/bin/sh -n for all three" suggestion would have
stumbled on — the **even-quote trap** (two apostrophes balance and parse despite
corruption) and **region's nested display-popup quoting** — are caught and the
test design works around them, so the test is a genuine regression detector
(proven FAIL-before/PASS-after) rather than a tautology. `check-safety.sh` stays
green by construction (no shim, no `calls.log`). Scope is cleanly bounded from
Issues 2/3/4 and the Zig layer.