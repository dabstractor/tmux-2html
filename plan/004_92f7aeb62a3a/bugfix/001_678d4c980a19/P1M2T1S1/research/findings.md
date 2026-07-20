# Research findings — P1.M2.T1.S1: scope check-safety.sh WARN rules to skip plan/ (Issue 4)

All facts verified empirically against the on-disk `scripts/check-safety.sh` (124 lines) and a
scratch copy of the proposed fix (results reproduced below).

## 0. CRITICAL: the item's baseline is STALE — there are now 6 FAILs, not 0

The item + architecture note (`issue4_check_safety_noise.md`) assume "16 WARNs, 0 FAILs" and
prescribe a WARN-only `under_plan` fix. **The current repo is 6 FAILs, 22 WARNs, exit 1** (all in
`plan/`):

```
$ scripts/check-safety.sh 2>&1 | grep 'result:'
== result: 6 FAIL(s), 22 WARN(s)        # exit 1
```

The 6 FAILs are FALSE POSITIVES from sibling docs that *quote the pattern names in prose*:
- `plan/004…/P1M1T1S3/PRP.md:112` — YAML `section: "… R2 (bare exec tmux) are FAILs everywhere."` (R2 + kill-server)
- `plan/004…/P1M1T2S4/PRP.md:222` — YAML `section: "R1 FAIL (…); R2 FAIL (exec tmux); …"` (R2 + kill-server)
- `plan/004…/P1M1T2S4/PRP.md:224` — YAML `why: "… no kill-server, …"` (kill-server)
- `plan/004…/tasks.json:174` — JSON `"context_scope": "… kill-server …"` (kill-server) — the orchestrator-embedded item description.

**Consequence: the item's literal WARN-only fix is INSUFFICIENT to reach its own success
criterion** ("0 FAILs, exit 0"). Applying only `under_plan` to the WARN block leaves the 6 FAILs
→ check-safety.sh still exits 1. This is an internal contradiction in the item: it says "FAIL
must scan plan/" AND "result: 0 FAILs" — both can't hold while plan/ prose triggers FAIL.

## 1. The faithful reconciliation (chosen): keep FAIL scanning plan/ + complete should_skip()

The item says (and the DOCS section wants) "FAIL patterns scan the entire repo". The script's own
design philosophy (header line 18) is: *"documentation is where a rule is **described**; code/
snippets are where it is **obeyed**."* `should_skip()` is the mechanism that separates the two.
It already skips backtick spans, `#`/`//` comments, markdown list/quote leaders, and grep-context
lines. It just doesn't recognize **YAML/JSON structured key-value prose** (`key: "value"`).

The fix that honors ALL of the item's statements (WARN suppression + FAIL-scans-plan/ + 0 FAILs +
docs "FAIL scans entire repo") is to ADD ONE heuristic to `should_skip()`:

```bash
case "$s" in *:[[:space:]][\'\"]*) return 0;; esac   # structured key: "value" (YAML/JSON prose) => doc, not code
```

This skips a line only when it contains `: "` or `: '` (colon, space, quote) — i.e. a structured
field value. Real dangerous commands never match that shape; verified below.

**Why this is necessary (not extra scope):** it is the device that makes "FAIL scans plan/" and
"0 FAILs" simultaneously true. Without it, the item is unsatisfiable. It is consistent with the
item's letter (FAIL calls stay unconditional/plan/-scanning) and its docs instruction.

## 2. The two changes, precisely

**Edit A — `under_plan()` + WARN gate** (the item's literal ask; handles the 22 WARNs):
- Add after `under_scripts()` (line 41):
  ```bash
  under_plan() { case "$1" in "$ROOT/plan/"*|"$ROOT/plan") return 0;; *) return 1;; esac; }
  ```
- Change the WARN condition (main loop ~line 110) from `if ! under_scripts "$f"; then` to
  `if ! under_scripts "$f" && ! under_plan "$f"; then`.

**Edit B — `should_skip()` heuristic** (handles the 6 FAILs; keeps FAIL scanning plan/):
- In `should_skip()` (lines 44–55), just before the final `return 1`, add:
  ```bash
    case "$s" in *:[[:space:]][\'\"]*) return 0;; esac   # structured key: "value" (YAML/JSON prose) => doc, not code
  ```
  (`s` is the left-trimmed line already in scope at that point.)

**Edit C — header comment + rationale comment** (Mode A docs):
- WARN section (lines 10–13): `everywhere EXCEPT scripts/` → `everywhere EXCEPT scripts/ AND plan/`,
  plus a note that FAIL rules still scan repo-wide and `should_skip()` drops structured prose.
- One-line rationale comment above `under_plan()`.

## 3. Empirical verification (scratch copy of the proposed fix, full-repo run)

Applied Edits A+B to a scratch copy and ran the full scan:
- **0 WARN** (down from 22) — `under_plan` suppresses the plan/ harness-recipe WARNs.
- **0 real FAIL** — the `: "` heuristic skips the 6 plan/ prose FAILs (verified: every FAILing
  line is `section: "…"` / `why: "…"` / `"context_scope": "…"`, all of which contain `: "`).
- The ONLY residual FAIL in the scratch run was `scripts/check-safety.sh:111` — a **test artifact**:
  the *copy* scans the *real* script (it can't recognize the real script as SELF). The real script's
  SELF-skip (`readlink -f` == SELF) is proven to work: the unmodified full run reports **zero**
  `scripts/check-safety.sh:` FAILs. So in production the patched script skips itself → **0/0**.

**Real danger is still caught** (heuristic does NOT weaken detection):
- `printf 'killall tmux\n' > scratch/real_danger.sh; check-safety --paths scratch/real_danger.sh`
  → `[FAIL] scratch/real_danger.sh:1: killall tmux`, exit 1. ✓
- The heuristic can only suppress a FAIL on a line that contains BOTH a dangerous pattern AND `: "`
  (colon-space-quote) — i.e. a YAML/JSON doc field. No shell/Zig code in this repo has that shape;
  real `killall tmux` / `exec tmux` / `tmux -L x kill-server` have no `: "` → never skipped.

Heuristic direct test (all behave correctly):
| line | result |
|---|---|
| `section: "R1 FAIL … R2 FAIL (exec tmux)"` | SKIP ✓ |
| `why: "… no kill-server …"` | SKIP ✓ |
| `"context_scope": "CONTRACT …"` (JSON) | SKIP ✓ |
| `exec tmux new-session -d -s test` | KEEP (FAIL) ✓ |
| `killall tmux` | KEEP (FAIL) ✓ |
| `tmux -L t2h-qa kill-server` | KEEP, then killserver `-L` mode skips (allowed scoped teardown) ✓ |

## 4. Rejected alternative: exclude plan/ from FAIL too

Simpler (one condition), but it **contradicts the item's explicit "FAIL patterns scan the entire
repo"** and the DOCS instruction. The should_skip heuristic (Edit B) is strictly more faithful
(FAIL still scans plan/) and equally effective (0/0), at the cost of one heuristic line. Chosen.

## 5. Parallel-context check

P1.M1.T2.S4 (parallel) touches `src/render.zig` (unit test) + `tests/zero_dimension_reject.sh`
(NEW) + `.github/workflows/ci.yml` — **not** `scripts/check-safety.sh`. Its PRP even cites
check-safety.sh as a gate to *run* (0 FAIL/0 WARN attributable to its new file). No collision.
(Its own PRP.md at line 222 is one of the plan/ prose FAIL sources Edit B fixes — that's expected;
the heuristic handles any plan/ doc that quotes pattern names, present or future.)

## 6. Confidence

The fix is 3 small edits (1 helper fn, 1 heuristic line, 1 condition `&&`, +comments). The 0/0
result and the "real danger still FAILs" guarantee were both reproduced empirically. The only
judgment call — adding the should_skip heuristic beyond the item's literal WARN-only ask — is
forced by the item's own contradictory success criterion and is the most contract-faithful
resolution. No guessing.