# PRP — P1.M1.T2.S1: Guard `determineCols` against explicit `--cols 0` (Issue 2 segfault, Fix Site 1)

## Goal

**Feature Goal**: Close the `render --cols 0` segfault (PRD Issue 2) at its origin: `determineCols`
(`src/render.zig:97`) currently returns an explicit `--cols` value **unchecked**
(`if (opts_cols) |c| return c;`), so `--cols 0` flows straight into `Terminal.init(.{ .cols = 0 })`
and ghostty-vt **segfaults** (exit 139). Add a `c < 1` lower-bound guard that returns the
**existing** `error.InvalidWindowSize`, which the **existing** `run()` catch already maps to exit 2
+ a stderr message. No segfault, no new error-reporting code.

**Deliverable**: Two edits to **`src/render.zig`** (no other files, no new error variant, no
signature change):
1. **Line 97** — the explicit-cols arm: bare `return c` → guarded `if (c < 1) return error.InvalidWindowSize; return c;`.
2. **One unit test** (~line 1250, after the existing `SizeRequired` test) asserting
   `determineCols(0, false)` / `determineCols(0, true)` → `error.InvalidWindowSize` and
   `determineCols(1, false)` → `1`.

**Success Definition** (all VERIFIED in a throwaway build against the live repo):
- `zig build test --release=fast` → exit 0 (new test passes + all existing tests green).
- `printf 'x\n' | ./bin render --cols 0` → **exit 2** + stderr
  `"tmux-2html render: cannot determine terminal size"` (NOT exit 139 segfault).
- The new test is a **proven regression detector**: with the fix reverted (test kept) it FAILS
  (`332/333, 1 failed`, this test named); with the fix it PASSES.
- `determineCols(1, false)` / `determineCols(80, false)` still return `1` / `80`; signature unchanged.

## User Persona

**Target User**: Anyone running `tmux-2html render` (incl. scripts/CI) who passes `--cols 0` — a
natural typo or a miscomputed value.

**Use Case**: `tmux-2html render --cols 0 < ansi.txt` should fail gracefully with a one-line
message and a defined exit code (2), not dump core.

**Pain Points Addressed**: Today it **segfaults** (exit 139, core dump) — an undefined exit code
that breaks script error-handling and violates PRD §0.1 ("a test or diagnostic can't destabilize
the machine" / prefer graceful failure). The `pane` path already guards this exact crash; `render`
never got the guard.

## Why

- **Robustness / no uncontrolled crash (PRD §5 / §0.1)**: a segfault is none of the defined exit
  codes (0/1/2) and produces a core dump. The CLI parser accepts `0`, so the renderer owns the
  validation. Rejecting it at `determineCols` is the minimal, correct fix.
- **Reuses existing infrastructure**: `error.InvalidWindowSize` is already a `SizeError` variant
  (render.zig:45); `reportSizeError` already maps it to a stderr message (render.zig:719); `run()`
  already catches any `SizeError` → exit 2 (render.zig:751-754). **Zero new error-reporting code.**
  The tty-derived branch (`getSize`) already rejects zero the same way — this makes the CLI arm
  consistent with it.
- **Minimal, surgical, boundary-safe**: one arm of one function + one test. The `tty` branch and
  `SizeRequired` branch are untouched. The sibling `--rows` guard (S2, render.zig:756), the
  `region.zig` defensive guard (S3), and the integration tests (S4) are separate tasks — this is
  the function-level unit fix.

## What

One arm of `determineCols` gains a `c < 1` guard; one unit test is added. Semantics:

- `determineCols(0, _)` → `error.InvalidWindowSize` (the explicit arm returns before the `has_tty`
  branch, so `getSize` is never called — safe to assert even with `has_tty=true`).
- `determineCols(c, _)` for `c ≥ 1` → `c` (unchanged).
- `run()` catches the error → `reportSizeError` prints `"tmux-2html render: cannot determine
  terminal size\n"` to stderr → returns `2`. **No segfault.**

### Success Criteria

- [ ] `src/render.zig:97` explicit-cols arm guards `c < 1` → `error.InvalidWindowSize`.
- [ ] `tty` branch and `SizeRequired` branch UNCHANGED; `determineCols` signature unchanged.
- [ ] New unit test asserts `determineCols(0, false)` / `(0, true)` → `error.InvalidWindowSize`
      and `(1, false)` → `1`.
- [ ] `zig build test --release=fast` → exit 0 (new test + all existing green).
- [ ] Regression-detector proof: reverting line 97 makes the new test FAIL (Level 2 note).

## All Needed Context

### Context Completeness Check

_Pass: "If someone knew nothing about this codebase, would they have everything needed to
implement this successfully?"_ — Yes. The single line to change is given as exact BEFORE/AFTER
(unique in the file); the verbatim test (proven FAIL-before/PASS-after) is given with its exact
insertion anchor; the reused error plumbing is quoted with line numbers; and the whole fix was
built and run in a throwaway copy: with the fix, all tests pass and `render --cols 0` exits 2 +
stderr (not 139); without the fix, the new test fails (named). No guessing.

### Documentation & References

```yaml
# MUST READ FIRST — authoritative root-cause + the three fix sites + why NOT parseU16
- file: plan/004_92f7aeb62a3a/bugfix/001_678d4c980a19/architecture/issue2_zero_dimension_segfault.md
  section: "Fix Site 1 (determineCols); Existing Error Infrastructure (reused); Why NOT fix at parseU16; Tests #1"
  why: "Names line 97, the exact fixed form, the reused SizeError/reportSizeError/run-catch plumbing, and the unit test that extends render.zig:1239."
  critical: "InvalidWindowSize already exists + is already mapped to exit 2. No new error-reporting code. The guard belongs at the sizing seam, NOT the shared parseU16 (region/pane get dims from tmux capture, not the CLI)."

# MUST EDIT — the bug site + the test home (THE primary deliverable)
- file: src/render.zig
  section: "SizeError (line 45); getSize zero-rejection (line 81); determineCols (line 95-100, fix line 97); reportSizeError (715-723); run() catch (751-754); existing determineCols tests (1239 'explicit cols wins', 1246 'SizeRequired')"
  why: "THE file. Edit line 97; add the test after line ~1250. The error plumbing (InvalidWindowSize -> reportSizeError -> run catch return 2) is reused verbatim, no changes."
  pattern: "Existing tests use std.testing.expectError(error.X, fn(...)) for the error path and expectEqual(@as(u16, N), try fn(...)) for the success path. Mirror that."
  gotcha: "determineCols(0, true) is SAFE to assert — the explicit arm returns before the has_tty branch, so getSize (which opens /dev/tty) is never called. The existing 1239 test relies on the same property."

# CONTRACT SOURCE — the bug report
- file: plan/004_92f7aeb62a3a/bugfix/001_678d4c980a19/prd_snapshot.md  (or prd_index §Issue 2 / h3.1)
  section: "Issue 2 (render --cols 0 / --rows 0 segfault)"
  why: "Repro, root cause (determineCols unchecked + Terminal.init cols=0 segfault), the pane-path precedent (main.zig:504). This PRP implements Fix Site 1 (determineCols)."

# SIBLING-TASK BOUNDARIES (do NOT duplicate / collide)
- file: plan/004_92f7aeb62a3a/bugfix/001_678d4c980a19/architecture/issue2_zero_dimension_segfault.md
  section: "Fix Site 2 (render.run --rows, line 756 = S2); Fix Site 3 (region.zig Terminal.init, line 326 = S3)"
  why: "S2/S3/S4 are sibling tasks in T2 (run later, not parallel with S1). S1 edits line 97 ONLY. S2 edits line 756; S3 edits region.zig:326; S4 adds integration tests. Different lines/files => no collision."
- file: plan/004_92f7aeb62a3a/bugfix/001_678d4c980a19/P1M1T1S3/PRP.md
  why: "The PARALLEL task (Issue 1, Implementing) creates tests/region_empty_confirm.sh + a ci.yml step — touches NO *.zig. No conflict with this render.zig edit. (T1.S1, Complete, made selectionBodyEmpty pub at render.zig:609 — different region from line 97.)"

# Empirical verification for THIS task
- file: plan/004_92f7aeb62a3a/bugfix/001_678d4c980a19/P1M1T2S1/research/findings.md
  why: "Throwaway-build proof: PASS-after (tests exit 0; render --cols 0 exit 2 + stderr, not 139) + FAIL-before (test kept, fix reverted -> 332/333 1 failed, named) + baseline segfault (139)."
```

### Current Codebase tree (relevant slice)

```bash
tmux-2html/
├── src/render.zig          # <— EDIT: line 97 (determineCols explicit arm) + add 1 test (~1250)
├── src/main.zig            # pane cols=0 guard (line 504) — precedent, DO NOT EDIT
├── src/cli.zig             # parseU16 accepts 0 — DO NOT EDIT (guard belongs at sizing seam)
├── src/region.zig          # S3 territory (Terminal.init guard) — DO NOT EDIT here
└── src/golden_test.zig     # DO NOT EDIT (goldens use cols >= 1, unaffected)
```

### Desired Codebase tree with files to be changed

```bash
tmux-2html/
└── src/render.zig          # MODIFIED — line 97 gains the c < 1 guard; +1 unit test
# NO other files. NO new error variant. NO signature change. NO docs (message already exists).
```

### Known Gotchas of our codebase & Library Quirks

```zig
// GOTCHA 1 — the explicit arm returns BEFORE the has_tty branch. So determineCols(0, true) hits
//   the explicit arm and returns error.InvalidWindowSize WITHOUT calling getSize (which opens
//   /dev/tty). This makes (0, true) SAFE to assert in a unit test (CI has no tty). The existing
//   1239 test relies on the identical property: determineCols(120, true) -> 120, "getSize NOT
//   called". Do NOT hesitate to assert the (0, true) case.

// GOTCHA 2 — reuse error.InvalidWindowSize; do NOT invent a new SizeError variant. It already
//   exists (render.zig:45), is already mapped to a stderr message by reportSizeError (719:
//   "tmux-2html render: cannot determine terminal size"), and is already caught by run()
//   (751-754) -> return 2. Adding a new variant would require new reportSizeError + message
//   wiring — out of scope and unnecessary.

// GOTCHA 3 — tests MUST run in ReleaseFast. `zig build test` (Debug) fails with the known Zig
//   0.15.2 linker bug (R_X86_64_PC64 from bundled C++ SIMD libs), NOT a code error. Always:
//   `zig build test --release=fast`. (PRD §15; ci.yml.)

// GOTCHA 4 — do NOT fix this at parseU16 (cli.zig:128). parseU16 is shared by all subcommands;
//   region/pane get dimensions from tmux capture, not CLI parsing. Rejecting 0 at the parser
//   would be the wrong scope. The guard belongs at the sizing/Terminal.init seam (architecture
//   doc "Why NOT fix at parseU16").

// GOTCHA 5 — do NOT touch the tty branch (getSize) or the SizeRequired branch. getSize already
//   rejects zero (render.zig:81: `if (ws.col == 0 or ws.row == 0) return error.InvalidWindowSize`);
//   this fix makes the CLI arm consistent with it. The contract: "Do NOT change the tty branch
//   or the SizeRequired branch."

// GOTCHA 6 — scrollbackBytes (render.zig:116) already does @max(cols, 1) defensively, evidence
//   the codebase anticipates cols==0 in adjacent math. This fix removes the need for that
//   defense at the source (cols can no longer be 0 from determineCols), but do NOT remove the
//   @max (it's harmless and out of scope).
```

## Implementation Blueprint

### Data models and structure

No new types. `SizeError` (render.zig:39-46) already includes `InvalidWindowSize`. `determineCols`
signature `pub fn determineCols(opts_cols: ?u16, has_tty: bool) SizeError!u16` is unchanged.

### The exact deliverable — verbatim edits

#### FILE 1: `src/render.zig` — the guard (line 97)

Find the unique line 97 and replace it. (The `tty` branch and `SizeRequired` branch below it are
UNCHANGED.)

```zig
// ---- BEFORE (exact, unique — line 97) ----
    if (opts_cols) |c| return c; // explicit --cols wins; never probes the tty
```
```zig
// ---- AFTER ----
    if (opts_cols) |c| { // explicit --cols wins; never probes the tty
        if (c < 1) return error.InvalidWindowSize; // explicit --cols 0 -> exit 2 (Issue 2 segfault guard)
        return c;
    }
```

#### FILE 2: `src/render.zig` — the unit test (add after the `SizeRequired` test, ~line 1250)

Add this test **immediately after** the existing `test "determineCols: no tty + no cols => error.SizeRequired"`
block (which ends ~line 1251 with the `// its value in a unit test ...` comment + `}`). Mirror the
file's `expectError`/`expectEqual` style:

```zig
test "determineCols: explicit --cols 0 is rejected (Issue 2: zero-dimension segfault guard)" {
    // An explicit --cols 0 must NOT reach Terminal.init (ghostty-vt segfaults on a zero-width
    // terminal). determineCols rejects it with error.InvalidWindowSize, which run() maps to
    // exit 2 + a stderr message (no segfault). The explicit arm returns before the has_tty
    // branch, so getSize is never called => safe to assert both. Boundary value 1 is accepted.
    try std.testing.expectError(error.InvalidWindowSize, determineCols(0, false));
    try std.testing.expectError(error.InvalidWindowSize, determineCols(0, true));
    try std.testing.expectEqual(@as(u16, 1), try determineCols(1, false));
}
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: EDIT src/render.zig line 97 — the explicit-cols lower-bound guard (THE fix)
  - Replace line 97 (the bare `if (opts_cols) |c| return c;`) with the guarded block above.
  - The tty branch (line 98) and SizeRequired branch (line 99) are UNCHANGED.
  - WHY FIRST: Task 2's test exercises this path.

Task 2: ADD the determineCols unit test (src/render.zig, after the SizeRequired test ~line 1250)
  - Add the verbatim test above, mirroring the existing expectError/expectEqual style.
  - Asserts: determineCols(0, false) -> error.InvalidWindowSize; (0, true) -> error.InvalidWindowSize;
    (1, false) -> 1. (The existing 1239 test already covers (80, false)->80 and (120, true)->120.)
  - NAMING: test "determineCols: explicit --cols 0 is rejected (Issue 2: zero-dimension segfault guard)".
  - DEPENDENCIES: Task 1 (the guard must be in place or this test FAILS — which is the point).

Task 3: VALIDATE (see Validation Loop — all verified exit 0)
  - RUN: zig build test --release=fast   → expect exit 0 (new test + all existing green)
  - PROVE the test is a real detector: temporarily revert ONLY line 97, re-run → the new test
    FAILS (332/333 1 failed, named). Restore. (Proven in research §5.)
```

### Implementation Patterns & Key Details

```zig
// PATTERN: guard the explicit arm with the SAME error the tty branch already uses, so the
// existing run() catch + reportSizeError handle it with zero new code:
if (opts_cols) |c| {
    if (c < 1) return error.InvalidWindowSize;   // mirrors getSize's render.zig:81 check
    return c;
}

// PATTERN: the regression test uses expectError for the rejected path + expectEqual for the
// boundary. (0, true) is safe to assert — the explicit arm short-circuits before getSize.
try std.testing.expectError(error.InvalidWindowSize, determineCols(0, false));
try std.testing.expectEqual(@as(u16, 1), try determineCols(1, false));

// CRITICAL: goldens (golden_test.zig) and every render test use cols >= 1, so this guard is
// invisible to them (verified: all tests pass with the fix). Do NOT touch golden_test.zig.
```

### Integration Points

```yaml
RENDER SIZING (src/render.zig):
  - determineCols line 97 now rejects --cols 0; run() catch (751-754) -> reportSizeError -> exit 2.
  - getSize (line 81) already rejected tty-derived zero the same way — the two arms are now consistent.

DOWNSTREAM / OUT OF SCOPE (sibling tasks in T2; do NOT implement here):
  - S2: render.run() --rows 0 guard (render.zig:756) — separate task.
  - S3: region.zig Terminal.init zero-dim guard (region.zig:326) — separate task.
  - S4: integration tests (binary-level render --cols 0 / --rows 0 / region) — separate task.
  - parseU16 (cli.zig:128) — DO NOT change (guard belongs at the sizing seam, not the shared parser).

PARALLEL TASK (P1.M1.T1.S3, Issue 1):
  - creates tests/region_empty_confirm.sh + a ci.yml step; touches NO *.zig. No conflict.

CONFIG / DATABASE / ROUTES:
  - none.
```

## Validation Loop

> PRIMARY gate: `zig build test --release=fast` → exit 0 with the new test passing. Plus the
> FAIL-before proof that the test catches the regression, and (proven here) the binary no longer
> segfaults.

### Level 1: Syntax & Style (Immediate Feedback)

```bash
cd /home/dustin/projects/tmux-2html
# The optimized build IS the type check. Confirms the guarded block + the new test compile.
zig build --release=fast 2>&1 | head -20
# Expected: clean (exit 0). An error naming render.zig => a typo in the guarded block (did you
# keep the tty/SizeRequired branches? is `c` still u16?) or in the test (expectError arg order).
```

### Level 2: Unit Tests (PRIMARY gate)

```bash
zig build test --release=fast
# Expected: exit 0. ALL tests pass, incl. the new "determineCols: explicit --cols 0 is rejected
# (Issue 2: zero-dimension segfault guard)" and the existing determineCols tests (1239/1246).
# Goldens are unaffected (they use cols >= 1).
#
# PROOF the test is a real detector (do this once, then restore):
#   1. Temporarily revert line 97 to `if (opts_cols) |c| return c;` (drop the guard).
#   2. Re-run `zig build test --release=fast` → expect: `run test N/N+1 passed, 1 failed`,
#      the failing test named "determineCols: explicit --cols 0 is rejected …", exit 1.
#   3. Restore the guard. Re-run → all pass, exit 0.
# (This confirms the test catches the missing guard. Proven in research §5.)
```

### Level 3: Binary / End-to-End Smoke (the segfault is closed)

```bash
zig build --release=fast
BIN=./zig-out/bin/tmux-2html

# The PRD Issue 2 repro — AFTER the fix, exit 2 + stderr msg (NOT 139 segfault):
printf 'x\n' | $BIN render --cols 0; echo "exit=$?"
# Expected: stderr "tmux-2html render: cannot determine terminal size"; exit code 2 (NOT 139).

# Boundary values still work (unchanged):
printf 'x\n' | $BIN render --cols 1  >/dev/null 2>&1; echo "cols=1 exit=$?"   # expect 0
printf 'x\n' | $BIN render --cols 80 >/dev/null 2>&1; echo "cols=80 exit=$?"  # expect 0
# NOTE: --rows 0 still segfaults until S2 lands — that is a SEPARATE task (render.zig:756).
#       This task (S1) closes the --cols 0 path only, per the contract.
```

### Level 4: Confidence checks

```bash
# Confirm the guard reads exactly c < 1 (not <= 0 or == 0 — all equivalent for u16, but match
# the contract's "c < 1"):
grep -n 'if (c < 1) return error.InvalidWindowSize' src/render.zig   # expect: 1 match (line 97)

# Confirm goldens are byte-identical to HEAD (the guard must not change cols>=1 output):
git stash && zig build test --release=fast >/tmp/before.txt 2>&1; git stash pop
zig build test --release=fast >/tmp/after.txt  2>&1
diff <(grep -c passed /tmp/before.txt) <(grep -c passed /tmp/after.txt)  # +1 test in 'after'

# Confirm the edit is surgical (only render.zig changed):
git diff --stat    # Expected: src/render.zig ONLY.
```

## Final Validation Checklist

### Technical Validation

- [ ] `zig build --release=fast` builds clean (Level 1).
- [ ] `zig build test --release=fast` exits 0 (Level 2 — primary gate).
- [ ] New test "determineCols: explicit --cols 0 is rejected (Issue 2…)" PASSES.
- [ ] Regression-detector proof: reverting line 97 makes the new test FAIL (Level 2 note).
- [ ] Existing determineCols tests (1239/1246) + goldens still pass.

### Feature Validation

- [ ] `render --cols 0` → exit 2 + stderr `"tmux-2html render: cannot determine terminal size"` (no segfault).
- [ ] `determineCols(1, false)` / `(80, false)` still return `1` / `80`.
- [ ] `tty` branch and `SizeRequired` branch unchanged; signature unchanged.

### Code Quality Validation

- [ ] Only `src/render.zig` line 97 + one new test changed — nothing else.
- [ ] Reuses `error.InvalidWindowSize` (no new SizeError variant, no new message).
- [ ] Guard reads `c < 1` (matches the contract; equivalent to `== 0` for u16 but explicit).
- [ ] Does NOT touch `getSize`, `reportSizeError`, `run()`, `region.zig`, `cli.zig`, or goldens.

### Documentation & Deployment

- [ ] No docs change (the stderr message already exists in `reportSizeError`; DOCS: none).
- [ ] No new env vars / config / CLI surface.

---

## Anti-Patterns to Avoid

- ❌ Don't return `0` from the explicit arm without the guard — that's the bug (segfault). Add the
  `if (c < 1) return error.InvalidWindowSize;` check.
- ❌ Don't invent a new `SizeError` variant or a new stderr message — `InvalidWindowSize` already
  exists and is already wired to exit 2 + `"tmux-2html render: cannot determine terminal size"`.
  Reuse it (GOTCHA 2).
- ❌ Don't touch the `tty` branch (`getSize`) or the `SizeRequired` branch — the contract forbids
  it; `getSize` already rejects zero the same way (GOTCHA 5).
- ❌ Don't fix this at `parseU16` (cli.zig) — it's shared by region/pane (which derive dims from
  tmux capture, not the CLI). The guard belongs at the sizing seam (GOTCHA 4).
- ❌ Don't touch `region.zig` (the Terminal.init guard is S3), `render.run()` `--rows` (S2), or
  integration tests (S4) — those are sibling tasks in T2; S1 is the `determineCols` fix only.
- ❌ Don't hesitate to assert `determineCols(0, true)` — the explicit arm short-circuits before
  `getSize`, so it's safe in a unit test (GOTCHA 1).
- ❌ Don't run plain `zig build test` (Debug) — it hits the `R_X86_64_PC64` linker bug. Use
  `--release=fast` (GOTCHA 3).
- ❌ Don't remove the defensive `@max(cols, 1)` in `scrollbackBytes` (line 116) — it's harmless
  and out of scope (GOTCHA 6).

---

**Confidence Score: 10/10** for one-pass implementation success.

The fix is one arm of one function gaining a `c < 1` guard that returns the **already-existing**
`error.InvalidWindowSize` — and the entire error-reporting path (`SizeError.InvalidWindowSize` →
`reportSizeError` stderr → `run()` catch `return 2`) is reused verbatim, so no new wiring is
needed. The whole change — guard + unit test — was built and run in a throwaway copy of the live
repo: with the fix, **all tests pass** (incl. the new one) and `render --cols 0` exits **2** with
the existing stderr message (not segfault 139); with the fix reverted (test kept), the build fails
`332/333, 1 failed` and the one failure is exactly this test — so it is a proven regression
detector, not a tautology. The baseline segfault (139) and the boundary values (`--cols 1`/`--cols
80` → exit 0) were also confirmed. The non-obvious points are all handled: `determineCols(0, true)`
is safe to assert (the explicit arm short-circuits before `getSize`), the tty/SizeRequired branches
are untouched, and the guard is at the sizing seam (not the shared `parseU16`). Scope is cleanly
bounded from the sibling `--rows` guard (S2), the `region.zig` guard (S3), the integration tests
(S4), and the parallel Issue 1 task (T1.S3, which touches no `.zig`). The implementer pastes an
exit-0-verified guard + test and runs one command.