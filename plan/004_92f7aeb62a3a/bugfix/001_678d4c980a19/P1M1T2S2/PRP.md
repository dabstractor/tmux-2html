# PRP — P1.M1.T2.S2: Guard explicit `--rows 0` in `render.run()` (Issue 2 segfault, Fix Site 2)

## Goal

**Feature Goal**: Close the `render --rows 0` segfault (PRD Issue 2) at its `run()`-level origin.
`render.run()` computes `const rows = opts.rows orelse lineCount(ansi);` — `orelse` fires only on
**null** (omitted `--rows`), so an **explicit `--rows 0`** (which the CLI parser `parseU16` accepts)
yields `rows = 0`, flows into `Size{ .rows = 0 }` → `Terminal.init(.{ .rows = 0 })`, and the vendored
ghostty-vt **segfaults** (exit 139). Add a `rows < 1` guard right after the rows computation that
calls the **existing** `reportSizeError(error.InvalidWindowSize)` then `return 2` — the **exact same**
exit/message the `cols` path already uses one line above. No segfault, no new error variant, no new
message, no signature change. (The default `--rows` path is already safe: `lineCount` floors at ≥1.)

**Deliverable**: **One inline edit to `src/render.zig`** (insert a 3-line guard between the
`const rows = …` line and the `const size = Size{…}` line). **No other files. No new error variant.
No new message. No new test file.** (`run()` is not unit-testable — it reads stdin first, which
blocks in a test; the `--rows 0` path is integration-tested in sibling task **S4**. See "Why S2 adds
NO unit test" below.)

**Success Definition** (baseline VERIFIED in a throwaway build of the live repo; post-fix outcome
follows mechanically from the reused machinery):
- `printf 'x\n' | ./bin render --cols 5 --rows 0` → **exit 2** + stderr
  `"tmux-2html render: cannot determine terminal size"` (NOT exit 139 segfault). [baseline = 139]
- `render --cols 5 --rows 0 --selection 0,0,0,0` → **exit 2** (same; the selection arm runs AFTER
  `const size`, so the guard covers every output arm). [baseline = 139]
- `render --cols 5 --rows 1` → exit 0 (boundary, unchanged). [baseline = 0 ✓]
- `render --cols 5` (omitted `--rows`) → exit 0 (`lineCount` default, unchanged). [baseline = 0 ✓]
- `zig build test --release=fast` → exit 0 (S1's `determineCols` test + all existing green; S2 adds no test).

## User Persona

**Target User**: Anyone running `tmux-2html render` (incl. scripts/CI) who passes `--rows 0` — a
typo or a miscomputed height.

**Use Case**: `tmux-2html render --cols 80 --rows 0 < ansi.txt` should fail gracefully with a
one-line message and a defined exit code (2), not dump core.

**Pain Points Addressed**: Today it **segfaults** (exit 139, core dump) — an undefined exit code
that breaks script error-handling and violates PRD §0.1 ("a test or diagnostic can't destabilize the
machine"). The `pane` path already guards this exact crash (`main.zig:504`); the sibling `--cols` fix
(S1) lands at `determineCols`; the `--rows` half was never guarded because `rows` is computed inline
in `run()`, not through a shared function.

## Why

- **Robustness / no uncontrolled crash (PRD §5 / §0.1)**: a segfault is none of the defined exit
  codes (0/1/2) and produces a core dump. The CLI parser accepts `0`, so the renderer owns the
  validation. Rejecting an explicit `--rows 0` right after it's computed is the minimal, correct fix.
- **Reuses existing infrastructure, ZERO new code**: the `cols` path *already* does
  `reportSizeError(err); return 2;` immediately above; `error.InvalidWindowSize` *already* exists
  (`SizeError`, render.zig:45); `reportSizeError` *already* maps it to the stderr message
  `"tmux-2html render: cannot determine terminal size\n"` (render.zig:719). S2's guard is literally
  the cols path's two lines, pointed at an explicit error literal. The default `--rows` path is
  already safe (`lineCount` floors at ≥1), so the guard only ever fires on an explicit `--rows 0`.
- **Covers every output arm for free**: the guard sits *between* `const rows` and `const size`,
  which is *before* the `--selection` branch — so `--rows 0`, `--rows 0 --output`, `--rows 0 --open`,
  and `--rows 0 --selection` are all closed by this one guard.

## What

One inline guard inserted after the `--rows` default computation. Semantics:

- `opts.rows == 0` (explicit `--rows 0`) → `reportSizeError(error.InvalidWindowSize)` prints the
  existing stderr line → `return 2`. **No segfault.**
- `opts.rows` omitted → `lineCount(ansi)` (always ≥1) → guard never fires → unchanged.
- `opts.rows == 1` (boundary) → `1` → guard never fires → unchanged.

### Success Criteria

- [ ] `src/render.zig`: a `if (rows < 1) { reportSizeError(error.InvalidWindowSize); return 2; }`
      guard is inserted between the `const rows = opts.rows orelse lineCount(ansi);` line and the
      `const size = Size{ .cols = cols, .rows = rows };` line.
- [ ] `determineCols`, `reportSizeError`, `SizeError`, `lineCount`, `getSize` are UNCHANGED.
- [ ] `render --rows 0` → exit 2 + the existing stderr message (NOT 139).
- [ ] `render --rows 1` / omitted `--rows` → exit 0 (unchanged).
- [ ] `zig build test --release=fast` → exit 0 (no new test; S1's + all existing green).

## All Needed Context

### Context Completeness Check

_Pass: "If someone knew nothing about this codebase, would they have everything needed to implement
this successfully?"_ — Yes. The single insertion is given as an exact BEFORE/AFTER with a unique
text anchor (the `const rows = …` line, which is the ONLY such line in the file); the reused
error plumbing is quoted with line numbers; the load-bearing typecheck
(`reportSizeError(error.InvalidWindowSize)` — error literal coercing to the narrower `SizeError`
param) is **proven** to compile and run in Zig 0.15.2; the baseline segfault (139) and boundary
behavior (`--rows 1`/omitted → exit 0) are **measured** against the live binary; and composability
with the parallel S1 edit is **verified** (non-overlapping text regions). No guessing.

### Documentation & References

```yaml
# MUST READ FIRST — authoritative root-cause + the three fix sites + why NOT parseU16
- file: plan/004_92f7aeb62a3a/bugfix/001_678d4c980a19/architecture/issue2_zero_dimension_segfault.md
  section: "Fix Site 2 (render.run --rows); Existing Error Infrastructure (reused); Why NOT fix at parseU16; Tests #2"
  why: "Names the run() rows line, the exact fixed form (reportSizeError(error.InvalidWindowSize) + return 2), the reused SizeError/reportSizeError plumbing, and the GOTCHA that the --rows path is integration-testable only."
  critical: "InvalidWindowSize already exists + is already mapped to exit 2 + the 'cannot determine terminal size' message. No new error-reporting code. The guard belongs at the sizing seam, NOT the shared parseU16 (region/pane get dims from tmux capture, not the CLI)."

# MUST EDIT — the bug site (THE primary deliverable)
- file: src/render.zig
  section: "SizeError incl. InvalidWindowSize (line 45); reportSizeError (715-723, self-contained — opens its own stderr); run() sizing block: cols catch (756-759), const rows (760), const size (761); local `const stderr` defined AFTER const size (~763)"
  why: "THE file. Insert the 3-line guard between the `const rows = opts.rows orelse lineCount(ansi);` line and the `const size = Size{ .cols = cols, .rows = rows };` line. reportSizeError is safe to call here (it makes its own stderr) even though the local `stderr` const is defined later."
  pattern: "Mirror the cols path literally: `reportSizeError(<SizeError value>); return 2; // size error`. The only difference is the rows path passes an explicit error literal (proven to typecheck) instead of a caught `err`."
  gotcha: "lineCount (105-109) floors at >=1, so ONLY an explicit --rows 0 reaches the guard. Do NOT anchor on a line number — the parallel S1 edit (+3 lines at ~96) shifts this block (757 pre-S1, 760 post-S1); anchor on the unique TEXT `const rows = opts.rows orelse lineCount(ansi);`."

# CONTRACT SOURCE — the bug report
- file: plan/004_92f7aeb62a3a/bugfix/001_678d4c980a19/prd_snapshot.md  (or prd_index §Issue 2 / h3.1)
  section: "Issue 2 (render --cols 0 / --rows 0 segfault), repro, root cause (Terminal.init cols/rows=0 segfaults)"
  why: "Establishes the segfault is 100% reproducible (exit 139), the boundary --rows 1 works, and the pane-path precedent (main.zig:504). This PRP implements Fix Site 2 (render.run --rows)."

# PARALLEL TASK (S1) — lands concurrently; MUST compose cleanly
- file: plan/004_92f7aeb62a3a/bugfix/001_678d4c980a19/P1M1T2S1/PRP.md
  why: "S1 edits determineCols (line ~96, +3 lines) + adds a unit test (~1253). Verified in the working tree: it shifts the run() rows line 757 -> 760. S1 and S2 touch NON-OVERLAPPING text regions => clean merge, no conflict. Anchor S2 on TEXT so it is immune to S1's line shift."

# SIBLING-TASK BOUNDARIES (do NOT duplicate / collide)
- file: plan/004_92f7aeb62a3a/bugfix/001_678d4c980a19/architecture/issue2_zero_dimension_segfault.md
  section: "Fix Site 1 (determineCols, line ~97 = S1); Fix Site 3 (region.zig Terminal.init, line ~326 = S3); Tests #2 (integration test = S4)"
  why: "S1 = determineCols (PARALLEL). S3 = region.zig Terminal.init guard. S4 = formal unit+integration tests for zero-dimension rejection. S2 = the run() --rows guard ONLY (this PRP). Different lines/files => no collision."

# Empirical verification for THIS task
- file: plan/004_92f7aeb62a3a/bugfix/001_678d4c980a19/P1M1T2S2/research/findings.md
  why: "Baseline segfault (139) + boundary (exit 0) measured on the live binary; the reportSizeError(error.InvalidWindowSize) typecheck PROVEN via a standalone Zig 0.15.2 probe; S1 composability verified via git diff; stdin-blocking GOTCHA explaining why no unit test."
```

### Current Codebase tree (relevant slice)

```bash
tmux-2html/
├── src/render.zig          # <— EDIT: insert the 3-line rows<1 guard in run() (between const rows & const size)
├── src/main.zig            # pane cols=0 guard (line 504) — precedent, DO NOT EDIT
├── src/cli.zig             # parseU16 accepts 0 — DO NOT EDIT (guard belongs at sizing seam)
├── src/region.zig          # S3 territory (Terminal.init guard) — DO NOT EDIT here
└── src/golden_test.zig     # DO NOT EDIT (goldens use rows >= 1, unaffected)
```

### Desired Codebase tree with files to be changed

```bash
tmux-2html/
└── src/render.zig          # MODIFIED — +3-line inline guard in run(); NO new test, NO new error variant, NO signature change
# NO other files. NO docs (the stderr message already exists in reportSizeError; DOCS: none).
```

### Known Gotchas of our codebase & Library Quirks

```zig
// GOTCHA 1 — ANCHOR ON TEXT, NOT LINE NUMBER. The parallel S1 edit expands determineCols' explicit
//   arm from 1 line to 4 (net +3) at ~line 96, which shifts the run() block: the `const rows = …`
//   line is 757 on a clean tree, 760 once S1 lands. The PRD/architecture docs say "756"/"757".
//   Locate the edit site by its UNIQUE TEXT — `const rows = opts.rows orelse lineCount(ansi);` —
//   which is the only such line in the file. Then insert the guard + leave `const size = Size{…}`
//   immediately after.

// GOTCHA 2 — reportSizeError is SELF-CONTAINED (safe to call before the local `stderr` exists).
//   reportSizeError (715) opens its OWN stderr (`const stderr = std.fs.File.stderr();` inside the fn).
//   The run()-local `const stderr` is defined AFTER `const size` (~763). So calling reportSizeError
//   in the guard (between `const rows` and `const size`) compiles fine — do NOT try to use the local
//   `stderr` const (it isn't in scope yet) and do NOT move the guard below `const size`.

// GOTCHA 3 — `reportSizeError(error.InvalidWindowSize)` TYPECHECKS (PROVEN). Passing an error LITERAL
//   where the param type is the narrower inferred set `SizeError` works: the literal coerces because
//   InvalidWindowSize is a comptime-known member of SizeError. Verified with a standalone Zig 0.15.2
//   probe (research/findings.md §3): `zig build-exe` exit 0, runtime prints the message. No
//   @errSetCast needed. Use the verbatim contract form.

// GOTCHA 4 — lineCount (105-109) floors at >= 1 (`"" => 1`, `if (n==0) n=1`). So the `orelse`
//   default path can NEVER produce rows==0; ONLY an explicit `--rows 0` can. The guard is
//   `if (rows < 1)` (equivalent to `== 0` for u16; match the contract's `< 1`).

// GOTCHA 5 — tests MUST run in ReleaseFast. `zig build test` (Debug) fails with the known Zig 0.15.2
//   linker bug (R_X86_64_PC64 from bundled C++ SIMD libs), NOT a code error. Always:
//   `zig build test --release=fast`. (PRD §15; ci.yml runs `zig build test -Doptimize=ReleaseFast`.)

// GOTCHA 6 — the --rows 0 path CANNOT be unit-tested. run() reads stdin unconditionally FIRST
//   (readToEndAlloc, ~line 740); in a unit test stdin may be a TTY -> readToEndAlloc BLOCKS forever
//   (no EOF). That is why render.zig has NO `run:` tests today, and why this fix adds NO unit test.
//   The formal shell integration test (`render --rows 0` -> exit non-zero + msg, no segfault) is
//   sibling task S4. S2's regression check is the binary smoke in Validation Level 3.

// GOTCHA 7 — do NOT fix this at parseU16 (cli.zig). parseU16 is shared by all subcommands;
//   region/pane get dimensions from tmux capture, not CLI parsing. The guard belongs at the sizing/
//   Terminal.init seam (architecture doc "Why NOT fix at parseU16").
```

## Implementation Blueprint

### Data models and structure

No new types. `SizeError` (render.zig:39-46) already includes `InvalidWindowSize`. `run()` signature
`pub fn run(alloc: std.mem.Allocator, opts: cli.RenderOpts) !u8` is unchanged. `lineCount`
(render.zig:105) signature unchanged. No structs/fields added.

### The exact deliverable — verbatim edit

#### FILE: `src/render.zig` — the `rows < 1` guard (inline in `run()`)

Locate the unique line `const rows = opts.rows orelse lineCount(ansi); // default = input line count`
(it is the ONLY such line; currently ~line 760 post-S1 / ~757 pre-S1 — anchor on text, not number).
Insert the guard block between it and the `const size = …` line:

```zig
// ---- BEFORE (exact, unique — the rows-computation + size-construction pair) ----
    const rows = opts.rows orelse lineCount(ansi); // default = input line count
    const size = Size{ .cols = cols, .rows = rows };
```
```zig
// ---- AFTER ----
    const rows = opts.rows orelse lineCount(ansi); // default = input line count
    if (rows < 1) { // explicit --rows 0 -> exit 2 (Issue 2 segfault guard); lineCount floors at >= 1
        reportSizeError(error.InvalidWindowSize);
        return 2; // size error
    }
    const size = Size{ .cols = cols, .rows = rows };
```

That is the entire change. The `cols` catch block immediately above (lines ~756-759) is UNCHANGED.
`determineCols`, `reportSizeError`, `lineCount`, `getSize` are UNCHANGED. No test is added (GOTCHA 6).

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: EDIT src/render.zig run() — insert the rows<1 guard (THE fix)
  - Locate the unique line `const rows = opts.rows orelse lineCount(ansi); // default = input line count`
    (anchor on TEXT; it is currently ~line 760 because S1's +3-line determineCols edit shifted it
    from 757; the docs say "756"/"757" — ignore the number, match the text).
  - Insert the 4-line `if (rows < 1) { reportSizeError(error.InvalidWindowSize); return 2; }` block
    (see verbatim edit above) BETWEEN that line and `const size = Size{ .cols = cols, .rows = rows };`.
  - Do NOT touch the cols catch above, determineCols, reportSizeError, lineCount, or getSize.

Task 2: VALIDATE (see Validation Loop — all commands verified)
  - RUN: zig build --release=fast                       → expect clean (the optimized build IS the type check)
  - RUN: zig build test --release=fast                  → expect exit 0 (no new test; S1's + all existing green)
  - RUN: printf 'x\n' | $BIN render --cols 5 --rows 0   → expect exit 2 + stderr msg (NOT 139 segfault)
  - RUN: printf 'x\n' | $BIN render --cols 5 --rows 1   → expect exit 0 (boundary unchanged)
  - RUN: printf 'x\n' | $BIN render --cols 5            → expect exit 0 (omitted --rows unchanged)
```

### Implementation Patterns & Key Details

```zig
// PATTERN: mirror the cols path one line above. The cols catch is:
//     const cols = determineCols(...) catch |err| { reportSizeError(err); return 2; };
// The rows guard is the same two actions, with an explicit error literal (proven to typecheck):
    if (rows < 1) {
        reportSizeError(error.InvalidWindowSize);   // reuses the existing message (render.zig:719)
        return 2; // size error
    }

// PATTERN: the guard sits BEFORE const size, which is BEFORE the --selection branch, so it closes
// every output arm (stdout / --output / --open / --selection) for --rows 0 in one place.

// CRITICAL: do NOT anchor on a line number (S1 shifts this block +3 lines). Match the unique text.
// CRITICAL: reportSizeError makes its OWN stderr; do NOT reference the run()-local `stderr` const
//           (defined later, after `const size`). Calling reportSizeError here compiles (GOTCHA 2).
```

### Integration Points

```yaml
RENDER SIZING (src/render.zig run()):
  - the rows<1 guard fires only on explicit --rows 0; -> reportSizeError(InvalidWindowSize) -> exit 2.
  - cols (determineCols, S1) and rows are now BOTH guarded before Size is constructed.

DOWNSTREAM / OUT OF SCOPE (sibling tasks in T2; do NOT implement here):
  - S1: determineCols --cols 0 guard (render.zig ~96) — PARALLEL, lands concurrently (verified in working tree).
  - S3: region.zig Terminal.init zero-dim guard (region.zig ~326) — separate task.
  - S4: formal unit + integration tests for zero-dimension rejection (render --cols 0 / --rows 0 / region) —
        separate task; OWNS the shell test file. S2 adds NO test file (would collide with S4).
  - parseU16 (cli.zig:128) — DO NOT change (guard belongs at the sizing seam, not the shared parser).

CONFIG / DATABASE / ROUTES:
  - none.
```

## Validation Loop

> PRIMARY gate: `zig build test --release=fast` → exit 0 (no new test; proves the edit compiles +
> nothing regressed). Plus the binary smoke proving the segfault is closed (Level 3). The baseline
> (139 segfault) and boundary (exit 0) values below were MEASURED on the live repo.

### Level 1: Syntax & Style (Immediate Feedback)

```bash
cd /home/dustin/projects/tmux-2html
# The optimized build IS the type check. Confirms the guard compiles (incl. the error-literal coercion).
scripts/safe-run.sh --cpu 1800 -- zig build --release=fast 2>&1 | tail -5
# Expected: clean (exit 0). An error naming render.zig => (a) you anchored on a stale line number
# instead of the unique `const rows = …` text, or (b) a typo in the guard (`rows`/`reportSizeError`/the
# error name). The error-literal form `reportSizeError(error.InvalidWindowSize)` is PROVEN to compile.
```

### Level 2: Unit Tests (compiles + nothing regressed)

```bash
zig build test --release=fast
# Expected: exit 0. S2 adds NO test (run() can't be unit-tested — GOTCHA 6: it reads stdin first,
# which blocks in a test). S1's "determineCols: explicit --cols 0 …" test, the lineCount tests, and
# all goldens (which use rows >= 1, so the guard never fires) remain green.
# NOTE: this run will ALSO execute S1's edit if it has landed — both S1+S2 are expected green together.
```

### Level 3: Binary / End-to-End Smoke (the segfault is closed — PRIMARY detector)

```bash
zig build --release=fast
BIN=./zig-out/bin/tmux-2html

# The PRD Issue 2 repro — AFTER the fix, exit 2 + stderr msg (NOT 139 segfault). [baseline measured = 139]
printf 'x\n' | $BIN render --cols 5 --rows 0; echo "exit=$?"
# Expected: stderr "tmux-2html render: cannot determine terminal size"; exit code 2 (NOT 139).

# The --selection arm is covered by the SAME guard (it runs after const size): [baseline measured = 139]
printf 'x\n' | $BIN render --cols 5 --rows 0 --selection 0,0,0,0 >/dev/null 2>&1; echo "rows=0+sel exit=$?"
# Expected: 2 (NOT 139).

# Boundary values still work (unchanged): [baseline measured = 0]
printf 'x\n' | $BIN render --cols 5 --rows 1 >/dev/null 2>&1; echo "rows=1 exit=$?"   # expect 0
printf 'x\n' | $BIN render --cols 5          >/dev/null 2>&1; echo "omitted exit=$?"  # expect 0 (lineCount default)

# Confirm NOTHING is written to stdout on the --rows 0 rejection (graceful, not a partial render):
printf 'x\n' | $BIN render --cols 5 --rows 0 2>/dev/null | wc -c   # expect 0 bytes
```

### Level 4: Confidence checks

```bash
# Confirm the guard reads exactly `if (rows < 1)` with reportSizeError(error.InvalidWindowSize):
grep -n 'if (rows < 1) {' src/render.zig                                       # expect: 1 match in run()
grep -n 'reportSizeError(error.InvalidWindowSize)' src/render.zig             # expect: 1 match (the guard)
# (getSize's own zero-check at line 81 uses `return error.InvalidWindowSize`, a DIFFERENT form — fine.)

# Confirm the edit is surgical (only src/render.zig changed; and within it, only the run() guard):
git diff --stat    # Expected: src/render.zig (and S1's concurrent edit, if landed — also src/render.zig).

# Confirm goldens are unaffected (the guard never fires for rows >= 1):
git stash && zig build test --release=fast >/tmp/before.txt 2>&1; git stash pop
zig build test --release=fast >/tmp/after.txt  2>&1
diff <(grep -c passed /tmp/before.txt) <(grep -c passed /tmp/after.txt)   # expect identical counts
```

## Final Validation Checklist

### Technical Validation

- [ ] `zig build --release=fast` builds clean (Level 1 — the optimized build is the type check).
- [ ] `zig build test --release=fast` exits 0 (Level 2 — no new test; S1's + all existing green).
- [ ] Goldens unaffected (rows >= 1 everywhere → guard never fires for them).

### Feature Validation

- [ ] `render --cols 5 --rows 0` → exit 2 + stderr `"tmux-2html render: cannot determine terminal size"` (no segfault; baseline was 139).
- [ ] `render --cols 5 --rows 0 --selection 0,0,0,0` → exit 2 (no segfault; baseline was 139).
- [ ] `render --cols 5 --rows 1` → exit 0 (boundary, unchanged).
- [ ] `render --cols 5` (omitted `--rows`) → exit 0 (lineCount default, unchanged).
- [ ] `--rows 0` writes 0 bytes to stdout (graceful rejection, not a partial render).

### Code Quality Validation

- [ ] Only `src/render.zig` run() changed — the 3-line guard inserted between `const rows` and `const size`.
- [ ] Reuses `error.InvalidWindowSize` + `reportSizeError` (no new variant, no new message).
- [ ] Anchored on the unique TEXT `const rows = opts.rows orelse lineCount(ansi);` (immune to S1's line shift).
- [ ] Does NOT touch `determineCols` (S1), `reportSizeError`, `lineCount`, `getSize`, `region.zig` (S3),
      `cli.zig` (`parseU16`), `golden_test.zig`, or add any test file (S4).

### Documentation & Deployment

- [ ] No docs change (the stderr message already exists in `reportSizeError`; DOCS: none per contract).
- [ ] No new env vars / config / CLI surface.

---

## Anti-Patterns to Avoid

- ❌ Don't anchor on a line number ("756"/"757") — the parallel S1 edit shifts this block +3 lines
  (verified: 757 → 760). Match the unique TEXT `const rows = opts.rows orelse lineCount(ansi);` (GOTCHA 1).
- ❌ Don't invent a new `SizeError` variant or a new stderr message — `InvalidWindowSize` already exists
  (render.zig:45) and is already wired to exit 2 + `"tmux-2html render: cannot determine terminal size\n"`
  (render.zig:719). Reuse it (mirror the cols path verbatim).
- ❌ Don't use the run()-local `stderr` const in the guard — it's defined AFTER `const size`, not yet in
  scope. `reportSizeError` opens its OWN stderr (GOTCHA 2); just call it.
- ❌ Don't refactor `run()` to extract a `determineRows` helper just to unit-test it — the contract
  specifies an inline guard, and a helper test ("explicit 0 returns 0") would be a tautology that
  proves nothing about the `if (rows < 1)` guard. The rows path is integration-tested in S4 (GOTCHA 6).
- ❌ Don't add a shell test file in S2 — S4 owns the formal integration tests; a file here would
  duplicate/collide with S4's scope.
- ❌ Don't touch `determineCols`/line ~96 (S1 territory), `region.zig`/`Terminal.init` (~326, S3),
  `parseU16` (cli.zig — shared by region/pane; guard belongs at the sizing seam), or goldens.
- ❌ Don't run plain `zig build test` (Debug) — it hits the `R_X86_64_PC64` linker bug. Use
  `--release=fast` (GOTCHA 5).
- ❌ Don't worry that the guard only checks `rows` — `cols` is already guarded by S1's `determineCols`
  edit (which errors before `cols` is ever assigned), and `lineCount` floors `rows` at ≥1 for the
  default path, so `if (rows < 1)` is the complete rows-side guard.

---

**Confidence Score: 10/10** for one-pass implementation success.

The fix is a 3-line inline guard inserted between two unique, adjacent lines in `run()`. It reuses
**100% existing machinery**: the *same* `reportSizeError` + `return 2` the `cols` path uses one line
above, the *same* `error.InvalidWindowSize` variant (`SizeError`, render.zig:45), and the *same*
stderr message (render.zig:719). The one non-obvious point — that passing the error literal
`error.InvalidWindowSize` where a `SizeError` param is expected typechecks — is **proven** via a
standalone Zig 0.15.2 probe (`build-exe` exit 0, runtime prints the message). The baseline segfault
(139) for `--rows 0` (and `--rows 0 --selection`) and the boundary behavior (`--rows 1`/omitted →
exit 0) are **measured** against the live binary. Composability with the **parallel S1** edit is
**verified**: S1 touches `determineCols` (~line 96) + a unit test (~1253); S2 touches the `run()`
sizing block (~line 760) — non-overlapping text regions → clean merge, and the PRP anchors on unique
TEXT so it is immune to S1's +3-line shift. S2 deliberately adds **no unit test** (`run()` reads
stdin first, which blocks in a test — the rows path is integration-tested in sibling S4) and **no
test file** (would collide with S4). The implementer pastes a proven-compiling guard and runs one
build + one binary smoke. Segfault closed, exit code defined, boundary preserved.