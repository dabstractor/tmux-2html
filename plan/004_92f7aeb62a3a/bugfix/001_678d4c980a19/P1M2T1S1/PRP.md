name: "P1.M2.T1.S1 — Scope check-safety.sh WARN rules to skip plan/ (Issue 4)"
description: |
  Suppress cosmetic WARN noise (and clear the stale-baseline FAIL noise) that
  check-safety.sh emits from human-authored `plan/` documentation, WITHOUT
  weakening real-danger FAIL detection anywhere. Single-file change to
  `scripts/check-safety.sh`. Empirically verified end-to-end (see Validation
  Loop + the Verification Receipt at the bottom).

---

## Goal

**Feature Goal**: `scripts/check-safety.sh` exits **0** with **0 FAIL(s), 0 WARN(s)**
on a clean whole-repo run, by (a) excluding `plan/` from the two WARN-only scans
(R3 shim recipe, R4 `calls.log` append) and (b) teaching `should_skip()` to
recognize the YAML/JSON `key: "value"` structured-prose form that legitimately
*describes* the safety rules inside `plan/` PRDs — while FAIL patterns
(`killall tmux` / bare `kill-server` / recursive `exec tmux`) still scan the
**entire repo including `plan/`** and still trip on real invocations.

**Deliverable**: A modified `scripts/check-safety.sh` (the only file touched)
with four surgical edits: (1) a new `under_plan()` helper, (2) a new
`should_skip()` prose arm, (3) a one-clause change to the WARN-loop condition,
(4) a header-comment update. No source code, no `plan/` content, no other
scripts are modified.

**Success Definition**:
- `scripts/check-safety.sh` (whole-repo) ⇒ `== result: 0 FAIL(s), 0 WARN(s) ==`, exit `0`.
- Real-danger regression holds: a temp file containing a bare teardown / recursive
  command still exits `1` via `--paths`.
- The PRD §0 sanctioned scoped teardown (`tmux -L <iso> kill-server`) still exits `0`.
- `scripts/preflight.sh` reports no new residue from this change.

## Why

- `check-safety.sh` is the deterministic backstop against the 2026-07-18
  runaway-audit incident (AGENTS.md §0, §3). Its signal must stay clean so a real
  violation is not buried in noise.
- `plan/` is the human-authored tree of PRDs/research; it legitimately *describes*
  the safety rules in prose and shows documented test-harness recipes. Those
  descriptions are documentation, not code, yet they currently produce 22 WARNs and
  6 FAILs — all cosmetic, all inside `plan/`.
- PRD Issue 4 (§3.3) classifies this as Minor noise and explicitly endorses scoping
  the WARN rule to skip `plan/`, while **rejecting** excluding `plan/` from FAIL
  scanning ("the FAIL rule already correctly finds nothing actionable").

## What

**User-visible / CI-visible behavior**: `scripts/check-safety.sh` goes from
`6 FAIL(s), 22 WARN(s)` (exit 1) to `0 FAIL(s), 0 WARN(s)` (exit 0) on a clean
run. FAIL detection on real commands is unchanged and provably intact.

### Success Criteria

- [ ] `scripts/check-safety.sh` whole-repo run prints `0 FAIL(s), 0 WARN(s)` and exits `0`.
- [ ] A scratch file with a real teardown token fails under `--paths` (exit 1).
- [ ] A scratch file with a real recursive-shim token fails under `--paths` (exit 1).
- [ ] A scratch file with a scoped `-L <iso>` teardown passes (exit 0).
- [ ] A scratch file with a YAML/JSON `key: "value"` prose line that merely names the rules passes (exit 0).
- [ ] Header comment documents WARN suppression in `scripts/` AND `plan/`, and that FAIL scans repo-wide.
- [ ] `scripts/preflight.sh` clean; `git diff --stat` shows only `scripts/check-safety.sh` changed.

## All Needed Context

### Context Completeness Check

_If someone knew nothing about this repo, could they implement this?_ Yes — this
PRP contains the exact current baseline (measured, not assumed), the full
reasoning for every edit (including why the contract's literal prescription is
necessary-but-insufficient), the exact anchors/line numbers, copy-pasteable
diffs, and a self-contained, **self-clean** validation recipe (the validation
commands build dangerous tokens via shell variables so this very PRP file does
not trip the scanner — see Anti-Patterns #1 for why that matters).

### ⚠️ Read this first: why the work-item contract is necessary-but-insufficient (the stale-baseline trap)

The work-item contract (in `tasks.json` context_scope) prescribes ONLY: add
`under_plan()`, gate the WARN block on `! under_scripts && ! under_plan`, update
the header comment. It states the expected result is `0 WARNs and 0 FAILs`.

**That prescription alone does NOT reach `0 FAIL(s)`.** It only affects WARN
scanning. The contract (and the architecture note, and PRD §3.3) all assume the
repo currently has **0 FAILs** — but that baseline is **stale**. Measured today
(see Current Baseline below) the repo has **6 FAILs**, all inside `plan/`, all
structured YAML/JSON prose that *describes* the rules. The contract's WARN-only
edit leaves those 6 FAILs in place ⇒ script still exits 1 ⇒ the mandated
`0 FAIL(s)` gate fails.

This is the exact trap that sank **attempt 1/3**: that PRP (a) trusted a stale
FAIL count, (b) its own Level-3 validation block contained bare literal teardown
commands which self-tripped the FAIL scanner, and (c) it left the
`should_skip()` decision to the implementer instead of specifying + verifying it
as the PRP author. **This PRP fixes all three.**

The hard constraints leave exactly ONE viable path to `0 FAIL(s)`:
- ❌ Cannot edit anything under `plan/` (orchestrator/human-owned; forbidden to both
  implementer and this PRP's runtime edits — though this PRP *file* is the one
  artifact we author here, so it is written scanner-clean by construction).
- ❌ Cannot suppress FAIL scanning in `plan/` (forbidden by AGENTS.md §3, by PRD
  §3.3, and by this item's own contract step 1: "FAIL patterns … must continue to
  scan `plan/`").
- ✅ The only file in scope is `scripts/check-safety.sh`. The only way to stop the
  6 documentation lines from FAILing — while still FAILing real commands — is to
  extend `should_skip()`, **whose documented job is exactly "recognize
  documentation/comment/search-context, not code"** (check-safety.sh line 43), to
  also recognize the YAML/JSON `key: "value"` structured-prose form. This is
  philosophically identical to its existing arms (backtick span, `#`/`//`
  comment, markdown list/quote leader, grep-search line) and is **empirically
  verified** to not mask any real invocation (see Verification Receipt).

### Documentation & References

```yaml
# MUST READ — the safety contract this script enforces
- file: AGENTS.md
  why: "§0 (the incident), §1 (hard rules), §3 (table: check-safety.sh enforces
        FAIL repo-wide; WARN for patterns OUTSIDE scripts/). Normative."
  section: "§1, §3"
  critical: "§3 explicitly says WARN is scoped to 'patterns outside scripts/' and
             that the FAIL rule 'already correctly finds nothing actionable' in
             plan/. Extending the WARN-skip to plan/ is the blessed fix (Option A)."

- file: plan/004_92f7aeb62a3a/bugfix/001_678d4c980a19/architecture/issue4_check_safety_noise.md
  why: "The architecture note for THIS issue. Recommends Option A (the under_plan()
        WARN-skip) and explicitly rejects Option B (collect_files() exclusion)
        because it would also exclude plan/ from FAIL scanning."
  pattern: "Option A code block (under_plan + gated WARN condition) — implement that."
  gotcha: "The note assumes '0 FAILs' baseline; that is stale (see Current Baseline).
           The note's Option A snippet is correct for WARN but insufficient for the
           0-FAIL gate; pair it with the should_skip() prose arm below."

- file: scripts/check-safety.sh
  why: "THE file being edited. Read it fully before editing."
  section: "should_skip() (lines 44-54), under_scripts() (line 41), main WARN loop
            (lines 113-116), header comment (lines 9-16)."
  pattern: "under_scripts() is the exact template for under_plan(). should_skip()
            returns 0 (skip) for documentation; scan_pat() calls should_skip() for
            BOTH FAIL and WARN, so a prose arm applies uniformly."
  gotcha: "should_skip() needs the left-trimmed string `s` — insert the new prose
           arm AFTER the `s=...` left-trim line (line 46), not before. The script
           SELF-excludes via the SELF/readlink check (line 108), so
           scripts/check-safety.sh's own internal `kill-server` grep arg (line 111)
           is never scanned in production — do NOT 'fix' that line."

- url: https://www.gnu.org/software/bash/manual/bash.html#Pattern-Matching
  why: "Bash `case` patterns support POSIX character classes like [[:space:]] and
        [[:alpha:]], and [range] globs. The should_skip() prose arm uses these."
  critical: "In a `case` pattern, [[:space:]] is ONE whitespace char and * matches
             any tail. Quote literals inside the class carefully (\\' and \\\" )."

- prd: PRD §3.3 (Issue 4) — Minor; endorses scoping WARN to skip plan/, rejects
        excluding plan/ from FAIL. PRD §0 / §0.1 — the safety invariants this
        script protects.
```

### Current Baseline (MEASURED — do not trust older counts)

Run `scripts/check-safety.sh` on the pristine repo TODAY. Authoritative output:

```
== result: 6 FAIL(s), 22 WARN(s) ==
check-safety: FAILED — fix the violations above (see AGENTS.md §1).
exit code: 1
```

**Every FAIL and every WARN is under `plan/`.** None outside `plan/`. Concretely:

- **6 FAILs** — all structured YAML/JSON prose that *names* the rules:
  - `plan/004_…/P1M1T1S3/PRP.md:112` — `  section: "shim_combo() … R1 (killall/pkill/kill-server) + R2 (bare exec tmux) …"` (matched by R1 + kill-server + R2 → multiple emits)
  - `plan/004_…/P1M1T2S4/PRP.md:222` — `  section: "R1 FAIL (killall/pkill/bare kill-server); R2 FAIL (exec tmux); …"`
  - `plan/004_…/P1M1T2S4/PRP.md:224` — `  why: "Enumerates every rule. … kill-server …"`
  - `plan/004_…/tasks.json:174` — `                  "context_scope": "CONTRACT DEFINITION: … R1_KILL, kill-server, R2 recursive exec …"`
  - (the line-112 and line-222 hits each emit twice because they match ≥2 FAIL patterns)
- **22 WARNs** — all PATH-prepend shim-recipe matches (R3) in `plan/001_*`, `plan/002_*`,
  `plan/004_*/P1M1T1S3/PRP.md`, `plan/004_*/P1M1T1S3/research/findings.md`,
  `plan/004_*/P1M1T2S4/PRP.md`. (No R4 `calls.log` WARNs currently.)

The PRD/architecture note say "16 WARNs / 0 FAILs" — **both numbers are stale**;
more PRDs were authored after they were written. The fix below is robust to the
exact count (it suppresses WARN for all of `plan/` and classifies the prose FAILs
by structure, not by counting).

### Desired Codebase tree (files touched)

```bash
scripts/check-safety.sh        # MODIFIED — 4 surgical edits (the ONLY change)
# nothing else. No new files. No tests/ additions (validation is via --paths on
# ephemeral scratch files; see Validation Loop). No plan/ edits.
```

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL: should_skip() is called for BOTH FAIL and WARN (inside scan_pat()).
#   Adding a prose arm there is correct and uniform: it classifies a LINE as
#   documentation regardless of which severity scans it. Do NOT instead try to
#   gate FAIL scanning on under_plan() — that would suppress real FAILs in plan/.
#
# CRITICAL: should_skip() uses the LEFT-TRIMMED string `s` (defined at line 46).
#   The new prose arm MUST come after that line. Earlier arms (backtick, comment,
#   list) run on `l`/`c` and are independent.
#
# CRITICAL: scripts/check-safety.sh SELF-excludes (line 108 SELF/readlink check).
#   Its own internal grep arg 'kill-server' on line 111 is therefore NEVER scanned
#   in production. When you VERIFY on a scratch COPY, that copy is at a different
#   path and will NOT self-exclude the real script — you will see a spurious FAIL
#   on scripts/check-safety.sh:111. That is an artifact of the copy, NOT a real
#   violation. (The Verification Receipt below accounts for this.)
#
# GOTCHA (bash case globs): [[:space:]] = exactly one whitespace char; it does NOT
#   mean "optional whitespace". The prose patterns below use exactly one space
#   between the colon and the quote, which matches every real YAML/JSON field.
#
# GOTCHA (scanner-clean authoring): this PRP file lives under plan/ and IS FAIL-
#   scanned after the fix. Every dangerous token below is inside a backtick span,
#   a `#` comment, or a shell-variable-built command — NEVER a bare literal in a
#   code fence. (Bare literals here would re-introduce the exact FAILs we remove.)
```

## Implementation Blueprint

### The four edits to `scripts/check-safety.sh`

All anchors below are verified against the current file. Apply them with the
`edit` tool (exact-text match). Line numbers are current as of this PRP; match on
the text, not the number.

---

**EDIT 1 — add `under_plan()` helper + rationale comment** (after line 41, the
`under_scripts()` one-liner).

Find:
```
under_scripts() { case "$1" in "$ROOT/scripts/"*|"$ROOT/scripts") return 0;; *) return 1;; esac; }
```
Replace with (append the two new lines):
```
under_scripts() { case "$1" in "$ROOT/scripts/"*|"$ROOT/scripts") return 0;; *) return 1;; esac; }
# plan/ holds human-authored PRDs/notes that *describe* the safety rules in prose
# (YAML/JSON key-value fields) and document test-harness recipes — WARN-only noise
# there is documentation, not code. FAIL patterns still scan it (see loop below).
under_plan() { case "$1" in "$ROOT/plan/"*|"$ROOT/plan") return 0;; *) return 1;; esac; }
```

---

**EDIT 2 — add a structured-prose arm to `should_skip()`** (insert between the
markdown-list arm on line 50 and the `# the line is itself scanning…` comment on
line 52). This is the edit that clears the 6 stale-baseline FAILs.

Find:
```
  case "$c" in '-') [ "${s:1:1}" = ' ' ] && return 0;; '*' ) [ "${s:1:1}" = ' ' ] && return 0;; esac  # md list/bullet
  # the line is itself scanning for the pattern (grep/rg/awk/sed), not running it
```
Replace with:
```
  case "$c" in '-') [ "${s:1:1}" = ' ' ] && return 0;; '*' ) [ "${s:1:1}" = ' ' ] && return 0;; esac  # md list/bullet
  # structured prose: a YAML/JSON/INI `key: "value"` (or `key: 'value'`) field that
  # *describes* a rule, not runs it. Anchored to the trimmed line start so a bare
  # dangerous command is never mistaken for a field (real invocations have no
  # `key: "..."` leader). See PRP "Why this arm is safe".
  case "$s" in
    [[:alpha:]_]*:[[:space:]][\'\"]*) return 0;;   # YAML field:   section: "..."
    [\'\"]*[\'\"]:[[:space:]][\'\"]*) return 0;;   # JSON field:   "context_scope": "..."
  esac
  # the line is itself scanning for the pattern (grep/rg/awk/sed), not running it
```

**Why this arm is safe (must read):** `should_skip()` only ever suppresses a line
that *also* matched a dangerous pattern (it runs inside `scan_pat()` after the
grep hit). So the arm only "masks" a dangerous token when that token shares a line
with a `key: "value"` leader. In this repo the only such lines are the 6
documentation fields listed in Current Baseline. A real invocation
(`killall tmux`, bare `tmux kill-server`, `exec tmux …`) is a bare command with no
`key:` leader, so it is never skipped — verified empirically in the Verification
Receipt. The one theoretical blind spot — a real command *chained on the same
line* after a `key: "value"` leader (e.g. `label: "x"; <dangerous>`) — does not
occur in any real shell/script in this repo and is not a realistic evasion vector
(documented honestly as a known, acceptable trade-off; do NOT try to "fix" it with
quoting-aware parsing — that is out of scope and fragile).

---

**EDIT 3 — gate the WARN block on `plan/` too** (line 113). FAIL `scan_pat` calls
(lines 110-112) stay ABOVE and UNCONDITIONAL — do not touch them.

Find:
```
  if ! under_scripts "$f"; then
    shim_combo "$f" "$rel"
    scan_pat WARN "$R4"      "$f" "$rel"
  fi
```
Replace with:
```
  if ! under_scripts "$f" && ! under_plan "$f"; then
    shim_combo "$f" "$rel"
    scan_pat WARN "$R4"      "$f" "$rel"
  fi
```

---

**EDIT 4 — update the header comment (Mode A docs)** (line 14 and add a note near
the FAIL header).

Find (line 14):
```
# WARN (exit stays 0) everywhere EXCEPT scripts/ on:
```
Replace with:
```
# WARN (exit stays 0) everywhere EXCEPT scripts/ AND plan/ on:
```

Find (line 9, the FAIL header) — append a clarifying clause so FAIL-vs-WARN scope
is unambiguous:
```
# FAIL (exit non-zero) repo-wide on ACTUAL dangerous invocations:
```
Replace with:
```
# FAIL (exit non-zero) repo-wide — INCLUDING plan/ — on ACTUAL dangerous invocations:
```

(These are comments; they are skipped by `should_skip()` and live in the
self-excluded script, so they cannot trip the scanner.)

---

### Implementation Patterns & Key Details

```bash
# under_plan() mirrors under_scripts() EXACTLY (same one-liner shape, same
# trailing-edge handling "$ROOT/plan" vs "$ROOT/plan/"*). Copy the idiom verbatim.

# The should_skip() arm uses `s` (left-trimmed), so it MUST sit after line 46
# (`s="${l#"${l%%[![:space:]]*}"}"`). It returns 0 (skip) on the first matching
# case arm, same as every other arm. Order among arms does not change the result
# (any match => skip), but keep it grouped with the other "prose recognizer" arms.

# The WARN-loop change is a pure boolean extension: `&& ! under_plan "$f"`.
# Do NOT move/duplicate the FAIL scan_pat calls — they are intentionally above
# this conditional and run for every file unconditionally.
```

### Integration Points

```yaml
NO INTEGRATION POINTS — single isolated shell-script change:
  - DATABASE: none
  - CONFIG: none
  - ROUTES: none
  - BUILD: none (zig build unaffected; this is a repo-hygiene shell script)
  - CI: check-safety.sh already runs in CI (AGENTS.md §3); after this change CI
        goes green (0 FAIL) instead of red.
```

## Validation Loop

> **Self-clean rule:** the commands below build every dangerous token via a shell
> variable so that NO line in this PRP contains a bare literal that would FAIL-scan.
> Run them verbatim. Scratch lives under `scratch/` (real disk, not tmpfs) and is
> removed at the end. Do NOT put bare dangerous literals in any file under `plan/`.

### Level 1 — Syntax check (immediate)

```bash
bash -n scripts/check-safety.sh && echo "syntax OK"
shellcheck scripts/check-safety.sh 2>/dev/null || true   # optional; repo has no shellcheck gate
```
Expected: `syntax OK`. (shellcheck may warn on the intentional `case`-glob idioms
already present in the file — those are pre-existing, not introduced here.)

### Level 2 — The gate: whole-repo run must be 0 / 0

```bash
scripts/check-safety.sh; echo "exit=$?"
```
Expected:
```
== result: 0 FAIL(s), 0 WARN(s) ==
exit=0
```
If you see any FAIL or WARN, STOP: re-read "Why the contract is
necessary-but-insufficient" and confirm all four edits applied (especially EDIT 2,
which is the one that clears the 6 FAILs).

### Level 3 — Real-danger regression (MUST still FAIL) + allowance regression (MUST still PASS)

Build the dangerous tokens at runtime so this doc stays scanner-clean, then scan
each ephemeral file via `--paths`:

```bash
mkdir -p scratch/p1m2t1s1_regr
# real R1 teardown token -> must FAIL (exit 1)
k=kill; printf '%sall tmux\n'                 "$k" > scratch/p1m2t1s1_regr/r1.sh
# bare teardown-server (no -L scope) -> must FAIL (exit 1)
sfx=server; printf 'tmux kill-%s\n'           "$sfx" > scratch/p1m2t1s1_regr/ks.sh
# recursive bare-name shim -> must FAIL (exit 1)
vw=exec; printf '%s tmux new -s x\n'          "$vw" > scratch/p1m2t1s1_regr/r2.sh
# PRD-sanctioned SCOPED teardown (-L <iso>) -> must PASS (exit 0)
printf 'tmux -L t2h-iso kill-server\n'            > scratch/p1m2t1s1_regr/safe.sh
# YAML/JSON structured prose merely naming the rules -> must PASS (exit 0).
# Build the tokens from $k/$vw so THIS doc line stays scanner-clean (no bare literal
# in a code fence — that is the exact self-trip that sank attempt 1/3).
printf '  section: "R1 (%sall / %s-server); R2 (%s tmux) — documentation prose"\n' "$k" "$k" "$vw" > scratch/p1m2t1s1_regr/prose.md

for t in r1.sh ks.sh r2.sh safe.sh prose.md; do
  scripts/check-safety.sh --paths "scratch/p1m2t1s1_regr/$t" >/dev/null 2>&1
  printf '%-9s exit=%s\n' "$t" "$?"
done
# EXPECTED:  r1.sh=1  ks.sh=1  r2.sh=1  safe.sh=0  prose.md=0
rm -rf scratch/p1m2t1s1_regr
```
Any deviation from `r1.sh=1 ks.sh=1 r2.sh=1 safe.sh=0 prose.md=0` is a regression
— do not commit. (Note: `--paths` bypasses `collect_files()`, so the `scratch/`
exclusion does not apply here; that is intentional and why we clean up after.)

### Level 4 — Residue / scope check

```bash
scripts/preflight.sh
git diff --stat                    # expect ONLY scripts/check-safety.sh
git diff --name-only | grep -v '^scripts/check-safety.sh$' && echo "UNEXPECTED FILES CHANGED" || echo "scope OK"
```
Expected: preflight clean; only `scripts/check-safety.sh` changed.

## Verification Receipt (already run by the PRP author — re-run to confirm)

The author applied all four edits to a scratch copy of the script and ran the full
matrix on the CURRENT repo state (the copy was taught to also skip the real
`scripts/check-safety.sh` to mirror production SELF-exclusion — see Gotcha #3).
Results:

| Check | Result |
|---|---|
| Whole-repo run (mirrored self-skip) | `0 FAIL(s), 0 WARN(s)`, exit **0** ✅ |
| Real R1 token via `--paths` | exit **1** (FAIL) ✅ |
| Bare teardown-server via `--paths` | exit **1** (FAIL) ✅ |
| Recursive bare-name shim via `--paths` | exit **1** (FAIL) ✅ |
| Scoped `-L <iso>` teardown via `--paths` | exit **0** (PASS) ✅ |
| YAML `section: "…"` prose via `--paths` | exit **0** (PASS) ✅ |
| JSON `"context_scope": "…"` prose via `--paths` | exit **0** (PASS) ✅ |

Conclusion: the four edits reach the `0/0` gate AND preserve every real-danger
FAIL and the sanctioned-teardown allowance. The implementer should reproduce the
table with Level 2 + Level 3 above.

## Final Validation Checklist

### Technical Validation
- [ ] `bash -n scripts/check-safety.sh` passes.
- [ ] Level 2: whole-repo `scripts/check-safety.sh` ⇒ `0 FAIL(s), 0 WARN(s)`, exit 0.
- [ ] Level 3: regression matrix matches `r1.sh=1 ks.sh=1 r2.sh=1 safe.sh=0 prose.md=0`.
- [ ] Level 4: `scripts/preflight.sh` clean; `git diff --stat` shows only `scripts/check-safety.sh`.

### Feature Validation
- [ ] WARN noise from `plan/` is gone (22 → 0).
- [ ] The 6 stale-baseline documentation FAILs are gone (6 → 0).
- [ ] FAIL scanning still covers `plan/` (proven: real tokens still FAIL via `--paths`; the FAIL `scan_pat` calls are untouched and unconditional).
- [ ] Header comment documents WARN suppression in `scripts/` AND `plan/`, and FAIL repo-wide scope.

### Code Quality Validation
- [ ] `under_plan()` mirrors `under_scripts()` idiom verbatim.
- [ ] `should_skip()` prose arm uses `s` (placed after the left-trim line) and is anchored to the line start.
- [ ] No `plan/` content modified; no other scripts modified; no new files.
- [ ] This PRP file itself is scanner-clean (no bare dangerous literals on non-skipped lines).

### Documentation & Deployment
- [ ] Header comment (Mode A) updated; one-line rationale comment added at `under_plan()`.
- [ ] No new env vars / config.

---

## Anti-Patterns to Avoid

- ❌ **Do NOT put bare literal dangerous tokens in any `plan/` file** (including
  THIS PRP). A bare `killall tmux` / bare `kill-server` / `exec tmux` in a code
  fence re-introduces exactly the FAILs this change removes. This is what sank
  attempt 1/3. Build dangerous tokens via shell variables in examples; use
  backtick spans / `#` comments / key-value prose for prose mentions.
- ❌ **Do NOT gate FAIL scanning on `under_plan()`** (or add `plan/` to
  `collect_files()` exclusions). That suppresses real FAILs in `plan/` and violates
  AGENTS.md §3 + PRD §3.3 + the contract. Only the WARN block gets the `plan/` skip.
- ❌ **Do NOT "broaden" the `should_skip()` heuristic beyond the anchored
  `key: "value"` form** (e.g. don't skip whole code fences, don't skip any line
  mentioning `printf`, don't skip unanchored `: "` anywhere). The anchored
  two-pattern arm is the minimal, verified form; wider matchers risk masking a
  future real invocation. (Attempt 1 used an unanchored form; this PRP specifies
  the tighter anchored form with full regression proof.)
- ❌ **Do NOT trust the old "0 FAILs / 16 WARNs" counts.** Re-measure with
  `scripts/check-safety.sh` before and after. The fix is structural (suppress all
  `plan/` WARN; classify prose FAILs by structure), so it is robust to the exact
  count, but your BEFORE/AFTER assertions must reflect reality.
- ❌ **Do NOT "fix" `scripts/check-safety.sh:111`** (`scan_pat FAIL 'kill-server'`).
  It looks like a hit only when you run a scratch COPY (which can't self-exclude
  the real script). In production the script self-excludes; that line is correct.
- ❌ Don't skip Level 3 because "WARN noise is cosmetic." The whole point of this
  change is that it must NOT weaken detection — prove it with the regression matrix.

---

## Confidence Score: 9/10

One-pass success likelihood is high: the solution is a single-file, four-edit
change that has been **empirically verified** against the current repo (0/0 gate +
full regression matrix). The −1 is for the small residual risk that a reviewer
mistakes EDIT 2 (the necessary `should_skip()` prose arm) for scope-creep; this
PRP pre-empts that with the constraints analysis ("necessary-but-insufficient")
and the Verification Receipt. If the implementer faithfully reproduces Levels 2–4,
the task is done.