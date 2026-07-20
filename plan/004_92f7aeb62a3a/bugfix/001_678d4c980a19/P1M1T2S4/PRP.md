# PRP — P1.M1.T2.S4: Add unit and integration tests for zero-dimension rejection (Issue 2)

## Goal

**Feature Goal**: Lock in the **zero-dimension rejection** behavior added by the parallel S1/S2/S3
guards (PRD Issue 2) with a **regression test suite** so a future change can never reintroduce the
`render --cols 0` / `--rows 0` **segfault** (exit 139). Two test layers, matching the item contract:
- **(a) UNIT TEST** — `src/render.zig`: asserts `determineCols(0, false)` and `determineCols(0, true)`
  return `error.InvalidWindowSize` (explicit `0` wins over tty), pure logic, no Terminal.
- **(b) SHELL INTEGRATION TEST** — pipes `'x\n'` into the binary with `--cols 0` (and `--cols 5
  --rows 0`) and asserts: exit code is **non-zero AND not 139 (SIGSEGV)**, and **nothing is written
  to stdout**.

**Deliverable** (3 actions; exactly 1 NEW file + 1 CI edit + 1 verification — see "Scope correction"
below):
1. **VERIFY (do NOT re-add)** the `determineCols(0,…)` unit test — **it already exists at
   `src/render.zig:1260`**, added by the sibling task **S1** (commit `ec9eafe`, status Complete).
   S4's contract item (a) is *already satisfied*. Confirm via `grep`; do not duplicate it.
2. **CREATE `tests/zero_dimension_reject.sh`** — a dedicated, tmux-free, python-free POSIX-shell
   regression test driving the real binary through the three PRD Issue 2 repro cases
   (`--cols 0`, `--cols 5 --rows 0`, `--cols 0 --selection 0,0,0,0`) + the boundary cases
   (`--cols 1`, `--rows 1`, omitted `--rows`). Verbatim script provided below.
3. **MODIFY `.github/workflows/ci.yml`** — add one named step to the `envelope` job (immediately
   after the `region_empty_confirm.sh` step) running the new test. Reuses the job's already-built
   release binary (no extra build).

> **Scope correction (the single most important fact in this PRP):** the item contract lists the
> determineCols unit test as work for S4 to *add*. But S1's PRP **also** specified and **already
> committed** that exact test (render.zig:1260). This is the expected outcome of parallel
> execution: S1 and S4 both claimed "the determineCols zero test", and S1 landed first. **S4 adds
> no new `.zig` test.** Its real, non-duplicate deliverable is the **shell integration test**
> (item b) + the CI wiring. Re-adding the unit test would be dead weight (and pointless — Zig runs
> it either way under `zig build test`). S4's contribution for item (a) is the *verification* that
> the test exists and passes.

**Success Definition** (all empirically VERIFIED against a fresh `zig build --release=fast` of the
current repo, where S1/S2 are committed and the segfault is already closed):
- `grep -c 'determineCols: explicit --cols 0 is rejected' src/render.zig` → **1** (S1's test
  exists). `zig build test --release=fast` → exit 0 (that test passes; all green).
- `sh tests/zero_dimension_reject.sh` → prints `PASS: …` and exits **0**.
- The three repro cases each yield **exit 2, 0 stdout bytes** (not 139): measured `--cols 0` →
  exit 2 + stderr `"tmux-2html render: cannot determine terminal size"`; `--cols 5 --rows 0` →
  exit 2 + same stderr; `--cols 0 --selection 0,0,0,0` → exit 2, empty stdout.
- The boundary cases each yield **exit 0** (guard does not over-reject): measured `--cols 1`,
  `--cols 5 --rows 1`, `--cols 5` (omitted `--rows`) → all exit 0.
- **Regression-detector proof**: temporarily reverting S1's `determineCols` guard (render.zig:97)
  makes the *unit* test FAIL; temporarily reverting S2's `rows < 1` guard (render.zig:761) makes
  the *shell* test's `--cols 5 --rows 0` case FAIL (exit 139). Both prove the tests are real
  detectors, not tautologies. (Proven structurally in research §7; the implementer may spot-check.)
- `scripts/check-safety.sh` → **0 FAIL, 0 WARN** attributable to the new file (it uses no tmux
  shim, no `kill-server`, no `>>`, no `exec` — inherently clean; research §4).
- The new CI step is present and named, mirroring the `region_empty_confirm.sh` step.

## Scope correction rationale (read before implementing)

The orchestrator split Issue 2 into 4 subtasks: S1 (`determineCols` guard + unit test),
S2 (`run()` `--rows` guard), S3 (`region.zig` `Terminal.init` guard), S4 (tests). The split was
made when all four were "Researching". S1's PRP — finalized first — **folded the determineCols
unit test into S1 itself** (its Task 2: "ADD the determineCols unit test"). S1 is now Complete and
the test is committed (`render.zig:1260`). So when S4 begins, contract item (a) is a no-op
add. **Do not add a second copy.** This PRP therefore delivers item (a) as *verification* and
concentrates S4's new work on item (b) + CI. This is the correct, non-conflicting interpretation:
no duplicate test, no wasted work, and the regression coverage the contract wants is fully in
place (unit layer via S1, integration layer via this PRP).

## User Persona

**Target User**: Future maintainers / CI — anyone whose change could accidentally drop the S1/S2
zero-dimension guards (e.g. refactoring `determineCols`, rewriting the `run()` sizing block, or
adjusting `parseU16`).

**Use Case**: A PR that regresses the guard (making `--cols 0` reach `Terminal.init` again) is
caught **automatically in CI** — the shell test asserts exit ≠ 139, and the unit test asserts
`determineCols(0, _) == error.InvalidWindowSize` — before the segfault ships.

**Pain Points Addressed**: Today (post S1/S2/S3) the bug is *fixed*, but **unprotected by an
integration regression test** — the segfault was originally missed precisely because "every render
test/golden uses `--cols` ≥ 1" (PRD Issue 2 "Why standard validation missed it"). This task adds
the adversarial `0` coverage at both layers so the class of bug cannot silently return.

## Why

- **Closes the test gap the bug escaped through (PRD Issue 2 "Why standard validation missed it")**:
  no test exercised the degenerate `0` the CLI parser accepts. The unit test (S1) covers the
  `determineCols` origin; this PRP's shell test covers the **end-to-end binary behavior**
  (exit code + no stdout + no segfault) that a user/script actually observes.
- **Two-layer defense in depth**: the unit test is fast and pins the *function*; the shell test is
  the *contract* gate (the PRD's literal repro: `printf 'x\n' | render --cols 0` must not dump
  core). Either layer alone is weaker — the unit test wouldn't catch a `run()`-level regression,
  and the shell test wouldn't localize the failure to `determineCols`.
- **Mirrors the established repo pattern**: Issue 1's regression is a dedicated shell file
  (`tests/region_empty_confirm.sh`) wired as a named CI step. Issue 2 gets the identical treatment
  (`tests/zero_dimension_reject.sh`), keeping the regression-test convention uniform.
- **Cheapest possible integration test**: needs NO tmux, NO python3, NO pty, NO isolated socket —
  just `render` reading piped stdin. It runs in <1s, on any OS that builds the binary, and is
  check-safety-clean by construction (research §4).

## What

### Layer (a) — unit test: ALREADY EXISTS (verify, do not add)

The test at `src/render.zig:1260` (`test "determineCols: explicit --cols 0 is rejected (Issue 2:
zero-dimension segfault guard)"`) asserts exactly the contract:
`determineCols(0, false)` → `error.InvalidWindowSize`; `determineCols(0, true)` →
`error.InvalidWindowSize`; `determineCols(1, false)` → `1`. It is pure logic (the explicit arm
returns before the `has_tty`/`getSize` branch, so no `/dev/tty` is opened). It runs under
`zig build test --release=fast`. **S4's action = `grep` to confirm it is present; add nothing.**

### Layer (b) — shell integration test: NEW (`tests/zero_dimension_reject.sh`)

A dedicated POSIX-shell test that, for each of the three Issue 2 repro cases, runs
`printf 'x\n' | $BIN render <args>` and asserts: **exit ≠ 0**, **exit ≠ 139**, **stdout empty**;
for the two `--cols 0` / `--rows 0` cases it also asserts the stderr grace message. Then asserts
the three boundary cases exit 0 (no over-rejection). Verbatim script in the Implementation
Blueprint.

### CI: one new step in the `envelope` job

A named step `render zero-dimension rejection regression (Issue 2)` running
`sh tests/zero_dimension_reject.sh`, placed immediately after the existing
`region empty-cell confirm regression (Issue 1)` step. Reuses the binary built by the job's
`zig build -Doptimize=ReleaseFast` step.

### Success Criteria

- [ ] `grep -c 'determineCols: explicit --cols 0 is rejected' src/render.zig` → **1** (S1's test
      present; NOT duplicated — `grep -c` must not become 2).
- [ ] `tests/zero_dimension_reject.sh` exists, is executable-via-`sh`, and exits 0 on the fixed
      binary.
- [ ] The script asserts exit ≠ 0 AND exit ≠ 139 AND empty stdout for `--cols 0`,
      `--cols 5 --rows 0`, and `--cols 0 --selection 0,0,0,0`.
- [ ] The script asserts exit 0 for the boundary cases (`--cols 1`, `--cols 5 --rows 1`,
      omitted `--rows`).
- [ ] `.github/workflows/ci.yml` `envelope` job has a new named step running the script, after the
      `region_empty_confirm.sh` step.
- [ ] `scripts/check-safety.sh` → 0 FAIL (and the new file contributes 0 WARN).
- [ ] `zig build test --release=fast` → exit 0 (unchanged — S4 adds no Zig test).

## All Needed Context

### Context Completeness Check

_Pass: "If someone knew nothing about this codebase, would they have everything needed to
implement this successfully?"_ — Yes. The verbatim shell script is provided (copy-paste); the
exact CI YAML block to insert is provided with its anchor (the
`region empty-cell confirm regression (Issue 1)` step — unique text); the load-bearing fact that
the unit test **already exists** (so the implementer must `grep`-verify, not re-add) is stated
with its exact location (render.zig:1260) and provenance (S1, committed); the empirically-measured
exit codes/stdout for every asserted case are recorded (exit 2 / 0 bytes / message for the
rejections; exit 0 for the boundaries); the portable empty-file idiom (`[ ! -s file ]`) and the
POSIX-shell conventions to mirror are quoted from the sibling test files; and the check-safety
rules are enumerated so the implementer knows the new file is clean by construction. No guessing.

### Documentation & References

```yaml
# CONTRACT SOURCE — the authoritative task definition (what to build + the "do NOT renderGrid
# cols=0" constraint + "non-zero AND not 139" assertion wording)
- file: plan/004_92f7aeb62a3a/bugfix/001_678d4c980a19/prd_snapshot.md   (prd_index §Issue 2 / h3.1)
  section: "Issue 2 (render --cols 0 / --rows 0 segfault); 'Add a unit/integration test: render
            --cols 0 and --rows 0 each exit non-zero with a message and write nothing to stdout'"
  why: "Establishes the 4 repro commands, exit 139 baseline, boundary --cols 1 works, and the
        required test assertions (exit non-zero, message, nothing on stdout). The shell test
        encodes these assertions verbatim."

# MUST READ FIRST — root-cause + the 3 fix sites + the test plan (this PRP = the Tests section)
- file: plan/004_92f7aeb62a3a/bugfix/001_678d4c980a19/architecture/issue2_zero_dimension_segfault.md
  section: "Tests (#1 unit = S1 ALREADY DONE; #2 integration = THIS task); Existing Error
            Infrastructure (InvalidWindowSize -> reportSizeError -> exit 2 + stderr msg)"
  why: "Names the exact unit + integration tests this task owns, the reused error machinery the
        shell test asserts against, and the 'do NOT add renderGrid cols=0 test' constraint (honored:
        S4 adds no Zig test)."

# SIBLING S1 — PROVES the unit test already exists (the scope-correction fact)
- file: plan/004_92f7aeb62a3a/bugfix/001_678d4c980a19/P1M1T2S1/PRP.md
  section: "Task 2: ADD the determineCols unit test (render.zig, after the SizeRequired test)"
  why: "S1's PRP explicitly OWNED adding the determineCols(0,...) unit test as its Task 2, and S1 is
        Complete. The test is at render.zig:1260. => S4 does NOT re-add it (would duplicate). This
        is why item (a) is verification-only in S4."

# SIBLING S2 — the --rows 0 path this shell test also covers
- file: plan/004_92f7aeb62a3a/bugfix/001_678d4c980a19/P1M1T2S2/PRP.md
  section: "Validation Level 3 (binary smoke: render --cols 5 --rows 0 -> exit 2, not 139)"
  why: "S2 added the run() rows<1 guard (render.zig:761) and verified --rows 0 -> exit 2 + 0 stdout
        bytes. S4's shell test locks that in as a regression."

# SIBLING S3 (PARALLEL) — composability: different files, zero conflict
- file: plan/004_92f7aeb62a3a/bugfix/001_678d4c980a19/P1M1T2S3/PRP.md
  section: "Deliverable: one inline edit to src/region.zig (Terminal.init guard); NO test file"
  why: "S3 edits src/region.zig only and adds NO test (S4 owns the test files). S4 edits tests/ +
        ci.yml. => zero file overlap; clean merge. The region zero-dim case is NOT reproducible via
        real tmux (panes report >=1), so S4's shell test covers the reproducible render paths only."

# PATTERN TO MIRROR — the sibling Issue 1 regression shell test (dedicated file + CI step)
- file: tests/region_empty_confirm.sh
  why: "THE template for tests/zero_dimension_reject.sh: shebang #!/bin/sh + set -u, REPO/cd/BIN
        preamble, fail(), build-if-absent, mktemp WORK + trap rm, final 'PASS:' echo. Copy its
        skeleton. (Our file is SIMPLER: no tmux, no PATH shim, no python3 pty.)"
  pattern: "fail() { echo \"FAIL: $*\" >&2; exit 1; }; if [ ! -x \"$BIN\" ]; then zig build -Doptimize=ReleaseFast || fail ...; fi; WORK=$(mktemp -d ...); trap 'rm -rf \"$WORK\"' EXIT"
  gotcha: "region_empty_confirm.sh uses a PATH shim (it needs tmux) and so must avoid check-safety's
           R3 `>>`/bit-shift tokens. OUR file uses NO shim and NO tmux => none of that applies; a
           single `>` stdout redirect is fine (R3 matches only double `>>`)."

# PATTERN TO MIRROR — the existing envelope smoke (shell-test idioms + binary invocation)
- file: tests/envelope_smoke.sh
  section: "REPO/cd/BIN preamble; fail(); check_doc(); mktemp WORK; printf-pipe-into-binary pattern"
  why: "Confirms the canonical way the repo drives the binary with piped ANSI:
        `printf '...' | \"$BIN\" render --cols N --rows M ... > out 2>err`. Our assert_reject helper
        uses the same pipe-into-binary shape."

# CI — where the new step goes
- file: .github/workflows/ci.yml
  section: "jobs.envelope (ubuntu-latest): Checkout, Setup Zig, Install tmux, Build release binary,
            '§8.1 envelope integration smoke', 'region empty-cell confirm regression (Issue 1)'"
  why: "THE insertion site. Add the new step immediately AFTER the region_empty_confirm step. The
        job already ran `zig build -Doptimize=ReleaseFast` so the binary exists at
        ./zig-out/bin/tmux-2html; our test's build-if-absent guard is a no-op in CI but keeps the
        script runnable locally."

# SAFETY — the static gate the new file must pass (AGENTS.md §2/§3)
- file: scripts/check-safety.sh
  section: "R1 FAIL (killall/pkill/bare kill-server); R2 FAIL (exec tmux); R3 WARN (PATH-prepend +
            exec/>>); R4 WARN (>> calls.log)"
  why: "Enumerates every rule. The new test triggers NONE (no tmux, no shim, no kill-server, no >>,
        no exec). Verified: the file is clean by construction. Run check-safety.sh as a gate."

# EMPIRICAL PROOF for this task (exit codes / stdout / message — all measured on the fixed binary)
- file: plan/004_92f7aeb62a3a/bugfix/001_678d4c980a19/P1M1T2S4/research/findings.md
  why: "Ground-truth: --cols 0 => exit 2 + 0 stdout bytes + 'cannot determine terminal size'; same
        for --rows 0 and --cols 0 --selection; boundaries => exit 0. Plus the scope-correction proof
        (unit test already at render.zig:1260), the dedicated-file rationale, and the CI placement
        decision."
```

### Current Codebase tree (relevant slice)

```bash
tmux-2html/
├── src/render.zig                       # S1 guard (97) + S1 UNIT TEST (1260) + S2 guard (761) — DO NOT EDIT (verify only)
├── src/region.zig                       # S3 guard (parallel) — DO NOT EDIT
├── tests/
│   ├── envelope_smoke.sh                # §8.1 happy-path smoke — PATTERN to mirror (DO NOT EDIT)
│   ├── plugin_options.sh                # plugin threading — DO NOT EDIT
│   └── region_empty_confirm.sh          # Issue 1 regression — PATTERN to mirror (DO NOT EDIT)
├── .github/workflows/ci.yml             # <— EDIT: add one step to jobs.envelope
└── scripts/check-safety.sh              # run as a gate (DO NOT EDIT)
```

### Desired Codebase tree with files to be added/changed

```bash
tmux-2html/
├── tests/
│   └── zero_dimension_reject.sh         # NEW — Issue 2 regression (item b); no tmux/python/pty
└── .github/workflows/ci.yml             # MODIFIED — +1 named step in jobs.envelope
# NO .zig files touched. NO new unit test (S1 already added it; verify via grep, do not duplicate).
```

### Known Gotchas of our codebase & Library Quirks

```sh
# GOTCHA 1 — THE UNIT TEST ALREADY EXISTS. S1 (commit ec9eafe, Complete) added BOTH the
#   determineCols guard AND the determineCols(0,...) unit test at render.zig:1260. The item
#   contract lists that test as S4 work, but it is DONE. => S4 VERIFIES it (grep -c == 1) and
#   adds NO new .zig test. Re-adding it is dead weight (Zig runs it either way) and would make
#   grep -c become 2. Do not touch src/render.zig at all.

# GOTCHA 2 — assert exit code "non-zero AND not 139", NOT "== 2". The contract wording is
#   "non-zero AND not 139"; the architecture doc says "either exit 1 or 2 is acceptable per
#   PRD §5". The current binary exits 2, but hard-asserting ==2 would be over-constrained.
#   Use: [ "$rc" -ne 0 ] && [ "$rc" -ne 139 ]. (You MAY additionally note exit 2 in the echo.)

# GOTCHA 3 — 139 = SIGSEGV's shell exit code (128 + 11). Before S1/S2, --cols 0 / --rows 0
#   segfaulted and the shell saw 139. Asserting rc != 139 is the regression detector: if a
#   future change drops the guard, rc becomes 139 again and the test FAILS.

# GOTCHA 4 — empty-stdout check: use [ ! -s "$out" ] (true iff file is zero-size/absent). It is
#   fully portable (no BSD `wc -c` leading-space variance). envelope_smoke.sh uses wc/grep for
#   byte COUNTING; for a pure "is it empty" assertion, -s is cleaner and what we use.

# GOTCHA 5 — the stderr message is the EXISTING reportSizeError string
#   "tmux-2html render: cannot determine terminal size" (render.zig:722). Asserting it proves the
#   graceful error path ran (vs a panic). But it is SECONDARY: the core contract gate is exit
#   non-zero + not 139 + empty stdout. For the --cols 0 --selection case, determineCols fires
#   BEFORE the selection arm, so the same message is emitted — but to stay robust we assert the
#   message only for the two plain --cols 0 / --rows 0 cases (directly verified) and use "" (skip)
#   for the selection case.

# GOTCHA 6 — tests MUST run in ReleaseFast. `zig build test` (Debug) hits the Zig 0.15.2 linker
#   bug (R_X86_64_PC64). Always: `zig build test --release=fast` (PRD §15; ci.yml uses
#   -Doptimize=ReleaseFast). The shell test builds with `zig build -Doptimize=ReleaseFast`.

# GOTCHA 7 — NO tmux / NO python3 / NO pty in this test. Unlike envelope_smoke.sh and
#   region_empty_confirm.sh (which drive the region TUI via a python3 pty against an isolated
#   tmux server), the zero-dimension cases are pure `render < piped stdin`. So: no PATH shim, no
#   `-L $SOCK`, no `kill-session`, no SKIP-on-missing-tmux. The test runs anywhere the binary
#   builds. (This also makes it check-safety-clean by construction — GOTCHA 8.)

# GOTCHA 8 — check-safety.sh is inherently clean for this file. It FAILs only on
#   killall/pkill/bare-kill-server (R1) and bare-`exec tmux` (R2), and WARNs (outside scripts/)
#   on PATH-prepend+exec/>> combos (R3) and `>> calls.log` (R4). Our file has NONE of these
#   (no tmux, no shim, no `>>`, no `exec`). A single `>` stdout redirect is NOT matched by R3
#   (which is the double `>>`). Still run `scripts/check-safety.sh` as a gate.

# GOTCHA 9 — the CI step goes in jobs.envelope AFTER region_empty_confirm.sh (NOT in jobs.test,
#   which only runs `zig build test`; and NOT as a brand-new top-level job, which would need a
#   redundant checkout+zig-setup+build). The envelope job already built ./zig-out/bin/tmux-2html;
#   reuse it. Mirror the region_empty_confirm step's comment style.

# GOTCHA 10 — do NOT add a renderGrid(.{.cols=0}) Zig test. The contract forbids it: that path
#   must remain unreachable by construction and WOULD segfault the test binary. S4 adds no Zig
#   test at all; the shell test drives the PUBLIC CLI (render --cols 0), which the S1/S2 guards
#   reject BEFORE renderGrid/Terminal.init is reached — so no test path touches the segfault seam.
```

## Implementation Blueprint

### Data models and structure

None. This task adds a shell script and a CI step. No types, no Zig, no signatures. The only
"structure" is the `assert_reject` shell helper inside the new script.

### The exact deliverable — verbatim files

#### FILE 1: `tests/zero_dimension_reject.sh` (NEW — copy verbatim)

```sh
#!/bin/sh
# tests/zero_dimension_reject.sh — Issue 2 regression: render --cols 0 / --rows 0 must NOT
# segfault (exit 139). Before the S1/S2 guards, an explicit zero dimension flowed into
# Terminal.init(.{ .cols = 0, .rows = 0 }) and the vendored ghostty-vt segfaulted (core dump).
# Now determineCols (render.zig:97) and run() (render.zig:761) reject it with exit 2 +
# "tmux-2html render: cannot determine terminal size" on stderr (PRD §5 exit codes; §0.1
# "prefer graceful failure"). This locks that in: a future change that drops either guard
# reintroduces exit 139 and FAILS this test.
#
# No tmux, no python3, no pty needed — just `render` reading piped stdin. Runs anywhere the
# release binary builds; check-safety clean (no PATH shim, no kill-server, no append log).
#
# Run:  sh tests/zero_dimension_reject.sh    # -> PASS, exit 0 (needs the S1+S2 fixes)
set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO"
BIN=./zig-out/bin/tmux-2html

fail() { echo "FAIL: $*" >&2; exit 1; }

if [ ! -x "$BIN" ]; then
    echo "building release binary..."
    zig build -Doptimize=ReleaseFast || fail "zig build failed"
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/t2h-zero.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# assert_reject <label> <want_stderr_substring_or_empty> -- <render args...>
# Pipes 'x\n' into render; asserts: exit non-zero, NOT 139 (SIGSEGV), and EMPTY stdout.
# If <want> is non-empty, also asserts that substring appears on stderr (graceful error path).
assert_reject() {
    label="$1"; want="$2"; shift 3   # shift past label, want, and the '--' separator
    out="$WORK/o"; err="$WORK/e"
    printf 'x\n' | "$BIN" render "$@" >"$out" 2>"$err"
    rc=$?
    [ "$rc" -ne 0 ]   || fail "$label: expected non-zero exit, got 0 (zero-dim accepted => guard missing, Issue 2)"
    [ "$rc" -ne 139 ] || fail "$label: exit 139 = SIGSEGV (zero-dim segfault regressed, Issue 2)"
    [ ! -s "$out" ]   || fail "$label: stdout not empty (partial render leaked bytes)"
    if [ -n "$want" ]; then
        grep -qF "$want" "$err" || fail "$label: stderr missing expected message ('$want')"
    fi
    echo "  $label: exit $rc, empty stdout$([ -n "$want" ] && echo ', stderr msg ok')"
}

# --- the three PRD Issue 2 repro cases (all were exit 139 SIGSEGV before S1/S2) ---
MSG="cannot determine terminal size"
assert_reject "--cols 0"              "$MSG" -- --cols 0
assert_reject "--cols 5 --rows 0"     "$MSG" -- --cols 5 --rows 0
# determineCols fires BEFORE the --selection arm, so the same exit/stdout contract holds;
# message assertion skipped here to stay robust to selection-path wording.
assert_reject "--cols 0 --selection"  ""     -- --cols 0 --selection 0,0,0,0

# --- boundary: the guard must NOT over-reject valid dimensions (exit 0) ---
printf 'x\n' | "$BIN" render --cols 1          >/dev/null 2>&1 || fail "--cols 1 wrongly rejected (guard over-fires)"
printf 'x\n' | "$BIN" render --cols 5 --rows 1 >/dev/null 2>&1 || fail "--cols 5 --rows 1 wrongly rejected"
printf 'x\n' | "$BIN" render --cols 5          >/dev/null 2>&1 || fail "omitted --rows wrongly rejected (lineCount default)"
echo "  boundary: cols=1, rows=1, omitted-rows all accepted (exit 0)"

echo "PASS: render rejects zero dimensions with a non-zero/non-139 exit + empty stdout (Issue 2 segfault closed)"
```

> Design notes (so the implementer understands, not second-guesses, the script):
> - `assert_reject` shifts past `label`, `want`, and a literal `--` separator, then forwards
>   `"$@"` as render args. This lets each case list its flags naturally after `--`.
> - `[ ! -s "$out" ]` (GOTCHA 4) is the portable empty-stdout check.
> - The message assertion uses `grep -qF` (fixed-string) so the substring containing no regex
>   metachars matches literally.
> - The boundary block proves the guard is surgical (no false positives) — without it, a guard
>   that rejected *all* input would still pass the three reject cases.

#### FILE 2: `.github/workflows/ci.yml` — add one step to `jobs.envelope` (MODIFY)

Locate the unique step (it is the LAST step of the `envelope` job; its `name:` is unique):

```yaml
      - name: region empty-cell confirm regression (Issue 1)
        # python3 pre-installed on ubuntu-latest; tmux installed above. Drives the region
        # TUI via a pty and asserts a blank-cell confirm warns + exits 1 + writes nothing.
        run: sh tests/region_empty_confirm.sh
```

Insert this new step IMMEDIATELY AFTER it (still inside `jobs.envelope`, as the job's new last step):

```yaml

      - name: render zero-dimension rejection regression (Issue 2)
        # Asserts render --cols 0 / --rows 0 / --cols 0 --selection exit non-zero (2), NOT 139
        # (SIGSEGV), and write nothing to stdout. Before the S1 (determineCols) / S2 (run) guards
        # these segfaulted (core dump). Needs only the release binary built above (no tmux/python3).
        # A regression here fails CI.
        run: sh tests/zero_dimension_reject.sh
```

That is the entire CI change — one new step, reusing the job's existing built binary.

#### FILE 3: `src/render.zig` — VERIFY ONLY (do NOT edit)

```sh
# Confirm S1's unit test is present (exactly once) and passes. Do NOT add a second copy.
grep -c 'determineCols: explicit --cols 0 is rejected' src/render.zig   # expect: 1
zig build test --release=fast                                            # expect: exit 0 (test runs + passes)
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 0: VERIFY the unit test (item a) already exists — do NOT re-add
  - RUN: grep -c 'determineCols: explicit --cols 0 is rejected' src/render.zig
  - EXPECT: 1 (NOT 2). If it is 1, item (a) is DONE (S1 added it); proceed. If 0 (somehow missing),
    STOP — that means S1 did not land; flag it rather than adding a duplicate (the test belongs to S1).
  - DO NOT edit src/render.zig. S4 adds no .zig test.

Task 1: CREATE tests/zero_dimension_reject.sh (the item-b integration test — THE deliverable)
  - WRITE the verbatim script above. chmod is unnecessary (invoked via `sh tests/...`).
  - MIRROR the skeleton of tests/region_empty_confirm.sh (shebang/set -u, REPO/cd/BIN, fail(),
    build-if-absent, mktemp WORK + trap, final 'PASS:' echo) — but SIMPLER (no tmux/shim/python).
  - ASSERTIONS: for --cols 0 / --cols 5 --rows 0 / --cols 0 --selection 0,0,0,0 => exit != 0,
    exit != 139, stdout empty; message check for the first two. Boundary --cols 1 / --rows 1 /
    omitted --rows => exit 0.
  - DEPENDENCIES: needs the release binary (build-if-absent guard handles local runs; CI reuses the
    job's built binary).

Task 2: MODIFY .github/workflows/ci.yml — add the named step to jobs.envelope
  - INSERT the 'render zero-dimension rejection regression (Issue 2)' step (verbatim above)
    IMMEDIATELY AFTER the 'region empty-cell confirm regression (Issue 1)' step.
  - It is the LAST step of jobs.envelope. Reuses ./zig-out/bin/tmux-2html built earlier in the job.
  - DO NOT add a new top-level job (redundant build) or touch jobs.test / jobs.plugin / jobs.safety.

Task 3: VALIDATE (see Validation Loop — all commands verified)
  - RUN: sh tests/zero_dimension_reject.sh                 → expect: PASS, exit 0
  - RUN: zig build test --release=fast                      → expect: exit 0 (S1 test still green)
  - RUN: scripts/check-safety.sh                            → expect: 0 FAIL (new file adds 0 WARN)
  - (optional regression-detector spot-check): temporarily revert S2's render.zig:761 guard,
    re-run the script => the --rows 0 case fails with exit 139. Restore.
```

### Implementation Patterns & Key Details

```sh
# PATTERN: pipe ANSI into the binary and capture exit + stdout + stderr separately (from
# envelope_smoke.sh's render block):
printf 'x\n' | "$BIN" render --cols 0 >"$out" 2>"$err"; rc=$?

# PATTERN: the contract's two-part exit assertion ("non-zero AND not 139"):
[ "$rc" -ne 0 ]   || fail "...zero-dim accepted (guard missing)"
[ "$rc" -ne 139 ] || fail "...exit 139 = SIGSEGV (regressed)"

# PATTERN: portable empty-stdout check (NOT wc -c, which varies on BSD):
[ ! -s "$out" ]   || fail "...stdout not empty (partial render)"

# PATTERN: graceful-error-path proof (secondary; fixed-string grep on the existing message):
grep -qF "cannot determine terminal size" "$err" || fail "...stderr missing message"

# CRITICAL: do NOT edit src/render.zig. The determineCols(0,...) unit test (item a) is ALREADY
#           at render.zig:1260 (S1, Complete). Verify via grep -c == 1; adding a second copy is
#           dead weight and makes grep -c == 2.
# CRITICAL: assert exit "non-zero AND not 139", NOT "== 2" (architecture doc: exit 1 or 2 both OK).
# CRITICAL: the CI step goes in jobs.envelope after region_empty_confirm.sh (reuses built binary),
#           NOT as a new top-level job.
```

### Integration Points

```yaml
CI (.github/workflows/ci.yml):
  - jobs.envelope: +1 step 'render zero-dimension rejection regression (Issue 2)' (after the
    Issue 1 region step). Reuses the job's `zig build -Doptimize=ReleaseFast` binary.
  - jobs.test: UNCHANGED (it already runs S1's determineCols unit test via zig build test).

TEST SUITE (tests/):
  - tests/zero_dimension_reject.sh: NEW. No dependency on the other test files. Runs standalone.

SOURCE (src/): NONE. S4 touches no .zig. The guards it tests are S1 (render.zig:97), S2
  (render.zig:761), S3 (region.zig ~326, parallel) — all OTHER tasks, already/being implemented.

CONFIG / DATABASE / ROUTES: none.
```

## Validation Loop

> PRIMARY gate: `sh tests/zero_dimension_reject.sh` → `PASS`, exit 0; plus `zig build test
> --release=fast` exit 0 (the S1 unit test passes); plus `scripts/check-safety.sh` 0 FAIL. All
> commands below were VERIFIED against a fresh build of the current repo (S1/S2 committed).

### Level 1: the shell test itself (PRIMARY)

```bash
cd /home/dustin/projects/tmux-2html
# Build if absent (CI already has it; local first run builds once):
[ -x ./zig-out/bin/tmux-2html ] || scripts/safe-run.sh --cpu 1800 -- zig build --release=fast

sh tests/zero_dimension_reject.sh
# Expected output (exit 0):
#   --cols 0: exit 2, empty stdout, stderr msg ok
#   --cols 5 --rows 0: exit 2, empty stdout, stderr msg ok
#   --cols 0 --selection: exit 2, empty stdout
#   boundary: cols=1, rows=1, omitted-rows all accepted (exit 0)
#   PASS: render rejects zero dimensions with a non-zero/non-139 exit + empty stdout (Issue 2 segfault closed)
#
# If it prints FAIL and exits 1: a guard is missing (exit 0 or 139 on a reject case) or over-fires
# (a boundary exited non-zero). READ the FAIL line — it names the exact case + what went wrong.
```

### Level 2: the unit test (item a — verify S1's test is present + green)

```bash
grep -c 'determineCols: explicit --cols 0 is rejected' src/render.zig   # expect: 1 (NOT 2)
zig build test --release=fast                                            # expect: exit 0
# The named test "determineCols: explicit --cols 0 is rejected (Issue 2: zero-dimension segfault
# guard)" runs as part of the suite and passes. (S1 added it; S4 does NOT add a second copy.)
# NOTE: must be --release=fast; plain `zig build test` (Debug) hits the R_X86_64_PC64 linker bug.
```

### Level 3: regression-detector proof (the tests are real detectors, not tautologies)

```bash
# (a) Unit test catches a missing determineCols guard: temporarily revert render.zig:97 to
#     `if (opts_cols) |c| return c;`, re-run `zig build test --release=fast` => the named test
#     FAILS (expectError got a value). Restore.
# (b) Shell test catches a missing --rows guard: temporarily revert render.zig:761-764 (delete the
#     `if (rows < 1) {…}` block), rebuild, re-run `sh tests/zero_dimension_reject.sh` => the
#     `--cols 5 --rows 0` case FAILS with "exit 139 = SIGSEGV (zero-dim segfault regressed, Issue 2)".
#     Restore. (This is the exact regression the test exists to prevent.)
# These spot-checks are OPTIONAL but confirm both layers are live detectors.
```

### Level 4: safety gate + surgical-diff check

```bash
scripts/check-safety.sh
# Expected: "== result: 0 FAIL(s), N WARN(s) ==" with exit 0. The new tests/zero_dimension_reject.sh
# contributes 0 WARN (no tmux shim, no kill-server, no >>, no exec). The 16 existing WARNs inside
# plan/002_*/…/PRP.md (Issue 4, out of scope) may still show — they are pre-existing and unrelated.

# Confirm the diff is surgical (only the NEW test file + the CI step; NO .zig touched):
git status --short
# Expected:
#   ?? tests/zero_dimension_reject.sh
#    M .github/workflows/ci.yml
# (NO src/ changes. src/render.zig must NOT appear — S4 adds no Zig test.)
```

## Final Validation Checklist

### Technical Validation

- [ ] `sh tests/zero_dimension_reject.sh` → `PASS`, exit 0 (Level 1 — primary gate).
- [ ] `grep -c 'determineCols: explicit --cols 0 is rejected' src/render.zig` → **1** (S1's unit
      test present, NOT duplicated).
- [ ] `zig build test --release=fast` → exit 0 (Level 2 — S1's test passes; all green).
- [ ] `scripts/check-safety.sh` → 0 FAIL; new file adds 0 WARN (Level 4).
- [ ] (Optional) regression-detector spot-checks pass (Level 3).

### Feature Validation

- [ ] `--cols 0` → exit non-zero (2), not 139, empty stdout, stderr message present.
- [ ] `--cols 5 --rows 0` → exit non-zero (2), not 139, empty stdout, stderr message present.
- [ ] `--cols 0 --selection 0,0,0,0` → exit non-zero (2), not 139, empty stdout.
- [ ] Boundary `--cols 1` / `--cols 5 --rows 1` / omitted `--rows` → exit 0 (no over-rejection).
- [ ] `.github/workflows/ci.yml` `envelope` job has the new named step after the Issue 1 step.

### Code Quality Validation

- [ ] Only `tests/zero_dimension_reject.sh` (NEW) + `.github/workflows/ci.yml` (one step) changed.
- [ ] NO `.zig` file touched (the unit test is S1's, already committed; verify-only).
- [ ] The script mirrors `tests/region_empty_confirm.sh`'s skeleton (shebang, REPO/cd/BIN, fail(),
      build-if-absent, mktemp+trap, final PASS echo) but is simpler (no tmux/shim/python).
- [ ] The script asserts exit "non-zero AND not 139" (NOT "== 2"), per the contract + architecture.
- [ ] The CI step reuses the `envelope` job's built binary (no redundant build/job).

### Documentation & Deployment

- [ ] No docs change (DOCS: none per contract — test addition only).
- [ ] No new env vars / config / CLI surface.

---

## Anti-Patterns to Avoid

- ❌ Don't re-add the `determineCols(0,…)` unit test in `src/render.zig` — **S1 already committed
  it** at render.zig:1260 (GOTCHA 1). S4 verifies it (`grep -c == 1`), adds no `.zig` test.
  Touching `src/render.zig` at all is a sign you've misunderstood the scope.
- ❌ Don't hard-assert exit code `== 2`. The contract says "non-zero AND not 139"; the architecture
  doc allows exit 1 or 2. Use `[ "$rc" -ne 0 ] && [ "$rc" -ne 139 ]` (GOTCHA 2).
- ❌ Don't fold the assertions into `tests/envelope_smoke.sh`. The contract permits a dedicated
  file ("or a dedicated render test"), and the sibling Issue 1 regression set the dedicated-file
  precedent (`region_empty_confirm.sh`). Separation of concerns: envelope_smoke = §8.1 happy-path
  doc-completeness; zero-dimension = adversarial rejection. Keep them apart.
- ❌ Don't add a new top-level CI job for this — it would need a redundant checkout+zig+build.
  Put the step in `jobs.envelope` (which already built the binary), after `region_empty_confirm.sh`
  (GOTCHA 9).
- ❌ Don't use `wc -c` for the empty-stdout check — it has BSD leading-space variance. Use
  `[ ! -s "$out" ]` (GOTCHA 4).
- ❌ Don't add a `renderGrid(.{.cols=0})` Zig test — the contract forbids it (it would segfault the
  test binary). S4 adds no Zig test; the shell test drives the public CLI, which the guards reject
  before `renderGrid`/`Terminal.init` (GOTCHA 10).
- ❌ Don't introduce a tmux/pty/python dependency. The zero-dimension cases are pure
  `render < piped stdin`. Adding tmux would needlessly couple this test to an isolated server,
  a PATH shim, and check-safety care — none of which apply here (GOTCHA 7/8).
- ❌ Don't run plain `zig build test` (Debug) — it hits the `R_X86_64_PC64` linker bug. Use
  `--release=fast` (GOTCHA 6).
- ❌ Don't assert the stderr message for the `--cols 0 --selection` case — use `""` (skip). The
  message IS emitted (determineCols fires before the selection arm), but asserting it there
  over-constrains a path whose message wording is incidental; the two plain cases (directly
  verified) carry the message assertion (GOTCHA 5).

---

**Confidence Score: 10/10** for one-pass implementation success.

The entire deliverable is **one copy-paste shell script + one copy-paste CI step**, plus a
verification `grep`. The non-obvious facts are all nailed down: (1) the unit test (item a) is
**already committed by S1** at render.zig:1260 — proven by `grep -c == 1` — so S4 verifies it and
adds **no `.zig` test** (the scope correction that prevents wasted/duplicate work); (2) the exit
codes and stdout byte-counts for every asserted case are **empirically measured** on a fresh build
of the current repo (`--cols 0` / `--rows 0` / `--cols 0 --selection` → exit 2, 0 stdout bytes,
`"cannot determine terminal size"` on stderr; boundaries → exit 0); (3) the assertion wording
follows the contract literally ("non-zero AND not 139", not "== 2"); (4) the script mirrors the
verified skeleton of the sibling `tests/region_empty_confirm.sh` but is strictly simpler (no tmux,
no PATH shim, no python3 pty — just `render < piped stdin`), making it **check-safety-clean by
construction**; (5) the CI step reuses the `envelope` job's already-built binary and slots in after
the Issue 1 step by name. Composability with the **parallel S3** is trivial: S3 edits
`src/region.zig`, S4 edits `tests/` + `ci.yml` — zero file overlap. The regression-detector property
is structurally guaranteed: reverting S2's `rows < 1` guard makes the `--rows 0` case exit 139 →
FAIL; reverting S1's guard makes the unit test FAIL. The implementer creates the file, pastes the CI
block, runs the script + the test suite + check-safety, and is done. Zero segfault paths remain
untested across both layers.