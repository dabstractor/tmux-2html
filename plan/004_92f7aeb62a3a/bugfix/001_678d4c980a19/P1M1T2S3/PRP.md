# PRP — P1.M1.T2.S3: Defensively guard region.zig `Terminal.init` against zero dimensions (Issue 2, Fix Site 3)

## Goal

**Feature Goal**: Close the **last unguarded path** to the ghostty-vt zero-dimension segfault
(PRD Issue 2). `region.body()` builds its `Terminal` **DIRECTLY** (`region.zig:326`) — not via
`render.renderGrid` — so the S1/S2 guards in `render.zig` (`determineCols` rejects `--cols 0`;
`run()` rejects `--rows 0`) do **not** cover it. If `cap.cols` or `cap.rows` (from the tmux
capture geometry) were ever `0`, the `Terminal.init(.{ .cols = 0, .rows = 0 })` call would
**segfault** (exit 139) — the exact crash the `pane` path already short-circuits
(`main.zig:500-506`). Add a `cap.cols < 1 or cap.rows < 1` guard immediately before the
`Terminal.init` call that writes a one-line stderr message and returns `2` (capture error,
PRD §5). No segfault, no new types, no new imports, no signature change.

**Deliverable**: **One inline edit to `src/region.zig`** — a 6-line guard block (comment + the
`if (cap.cols < 1 or cap.rows < 1) { try stderr.writeAll(...); return 2; }` check) inserted
immediately before the unique `var t = try Terminal.init(allocator, .{ .cols = cap.cols, … })`
line. **No other files. No new test file** (sibling task **S4** owns the formal zero-dimension
tests; `region.body()` is not unit-testable — see "Why S3 adds NO unit test"). The guard is
**defensive**: real panes always report geometry ≥1, so there is **no user-facing behavior
change** for normal inputs — it only converts a theoretical zero-dim segfault into a graceful
exit 2.

**Success Definition** (baseline verified against the live repo):
- `zig build --release=fast` → clean (the optimized build IS the type check).
- `zig build test --release=fast` → exit 0 (no new test; all existing region/render/golden
  tests green — the guard never fires for ≥1 geometries, which is every test case).
- A zero-dimension capture (cap.cols==0 or cap.rows==0) in `region.body()` → **exit 2** + stderr
  `"tmux-2html region: capture has zero-dimension pane geometry"` (NOT exit 139 segfault).
- `grep -n 'cap.cols < 1 or cap.rows < 1' src/region.zig` → exactly 1 match, immediately before
  the `Terminal.init` call.

## User Persona

**Target User**: Anyone running `tmux-2html region` — primarily a developer using the tmux
keybinding to interactively select and export a region of a pane.

**Use Case**: On a degenerate or mid-resize pane whose tmux `display-message` reports a
zero-dimension geometry, `region` should fail gracefully with a one-line message and a defined
exit code (2), not dump core (139).

**Pain Points Addressed**: An uncontrolled segfault is none of PRD §5's defined exit codes
(0/1/2), produces a core dump, and violates PRD §0.1 ("a test or diagnostic can't destabilize
the machine"). The `pane` path already guards this exact crash; `region` is the sibling path
that builds its `Terminal` directly and so needs the same defensive guard.

## Why

- **Robustness / no uncontrolled crash (PRD §5 / §0.1)**: `Terminal.init` on a zero-dimension
  terminal segfaults (documented at `main.zig:504`). `region.body()` calls it directly at
  `region.zig:326` with `cap.cols`/`cap.rows` from the capture, bypassing the `renderGrid`
  seam where the S1/S2 guards live. A degenerate/resized pane geometry could yield 0; rejecting
  it before `Terminal.init` is the minimal, correct fix.
- **Defensive closure of the whole class of bug**: S1 (render `determineCols`), S2 (render
  `run()` `--rows 0`), and S3 (region `Terminal.init`) together cover **all three** paths that
  feed dimensions into a `Terminal.init` (architecture doc "Fix Plan" → Fix Sites 1/2/3). S3 is
  the defensive third leg — it cannot be triggered through normal CLI/tmux flow (real panes
  report ≥1), but it guarantees no remaining code path can segfault the vendored VT on a
  zero-dimension input.
- **Reuses existing exit-code + message convention, ZERO new infrastructure**: region already
  exits `2` on capture failures (`region.zig:297`, `304`) and already uses the
  `tmux-2html region: <msg>\n` stderr prefix for runtime diagnostics (`region.zig:448/474/486/
  493/501/513`). S3 reuses both — no new exit code, no new prefix.

## What

One inline guard inserted immediately before the `Terminal.init` call in `region.body()`.
Semantics:

- `cap.cols == 0` OR `cap.rows == 0` → write
  `"tmux-2html region: capture has zero-dimension pane geometry\n"` to stderr → `return 2`
  (capture/target error, PRD §5). **No segfault. No `Terminal.init` reached.**
- `cap.cols >= 1` AND `cap.rows >= 1` (every real pane) → guard never fires → **unchanged**.

### Success Criteria

- [ ] `src/region.zig`: an `if (cap.cols < 1 or cap.rows < 1) { … return 2; }` guard is
      inserted immediately before the `var t = try Terminal.init(allocator, .{ .cols = cap.cols,
      .rows = cap.rows, … });` line.
- [ ] The guard **reuses the existing `body()`-local `stderr` const** (declared line 292) —
      does NOT redeclare `stderr` (would be a `redeclaration of 'stderr'` compile error).
- [ ] The stderr message is exactly `tmux-2html region: capture has zero-dimension pane geometry\n`.
- [ ] The guard is placed AFTER `defer allocator.free(cap.ansi);` (line 310) so an early
      `return 2` safely frees `cap.ansi` (no leak).
- [ ] `body()`, `regionHandle`, `regionPrepare`, `capture.*` signatures are UNCHANGED. No new
      imports (all symbols already in scope).
- [ ] `zig build --release=fast` → clean; `zig build test --release=fast` → exit 0.
- [ ] Normal region invocations (real panes, geometry ≥1) behave identically (guard never fires).

## All Needed Context

### Context Completeness Check

_Pass: "If someone knew nothing about this codebase, would they have everything needed to
implement this successfully?"_ — Yes. The single insertion is given as an exact BEFORE/AFTER
with a unique text anchor (the `var t = try Terminal.init(allocator, .{ .cols = cap.cols, .rows = cap.rows` line — the ONLY `Terminal.init` in the file); the load-bearing fact that `stderr`
is **already in scope** (declared line 292 — verified) and therefore **must be reused, not
redeclared** is stated explicitly; the message wording is verbatim from the authoritative item
contract and matches region's existing `tmux-2html region:` prefix convention (verified at 6
call sites); `cap.cols`/`cap.rows` are confirmed `u16` (so `< 1` ≡ `== 0`); the `defer` that
frees `cap.ansi` is confirmed registered before the guard site (no leak on early return); and
the build/test must use `--release=fast` (Debug hits a Zig 0.15.2 linker bug). No guessing.

### Documentation & References

```yaml
# MUST READ FIRST — authoritative root-cause + the three fix sites + why NOT parseU16
- file: plan/004_92f7aeb62a3a/bugfix/001_678d4c980a19/architecture/issue2_zero_dimension_segfault.md
  section: "Fix Site 3 (region.zig Terminal.init, line ~326); Why NOT fix at parseU16; Precedent: scrollbackBytes"
  why: "Names this exact task: 'Before Terminal.init, add a check: if cap.cols < 1 or cap.rows < 1, write stderr message and exit 2. Mirrors the main.zig:500-506 pane guard rationale.' Confirms cap.cols/cap.rows come from tmux display-message (always >=1 for real panes) but a degenerate pane could yield 0."
  critical: "region builds its Terminal DIRECTLY (not via renderGrid) — so the render.zig guards (S1/S2) do NOT cover it. The guard belongs at the Terminal.init seam, NOT at parseU16 (region/pane get dims from capture, not the CLI)."

# MUST EDIT — the bug site (THE primary deliverable)
- file: src/region.zig
  section: "body() line 291-326: const stderr (292), capture (302-304), defer free cap.ansi (310), palette.resolve (314), Terminal.init (326)"
  why: "THE file. Insert the guard immediately before the `var t = try Terminal.init(allocator, .{ .cols = cap.cols, .rows = cap.rows, … });` line (326). stderr is ALREADY in scope (292) — reuse it. defer allocator.free(cap.ansi) (310) is registered before the site -> early return 2 is leak-free."
  pattern: "Mirror the pane guard's RATIONALE (main.zig:500-506: don't feed ghostty-vt a zero-dim terminal) but key directly on cap.cols/cap.rows (region has no result.code). Reuse region's own `tmux-2html region: <msg>\\n` stderr prefix (448/474/486/493/501/513) and exit code 2 (297/304)."
  gotcha: "Do NOT redeclare `const stderr = std.fs.File.stderr();` in the guard — it is ALREADY declared at body()'s line 292; re-declaring is a `redeclaration of 'stderr'` compile error. Just reference the existing `stderr`. Anchor on the Terminal.init TEXT, not a line number (the parallel S2 edits render.zig, a DIFFERENT file, so region line numbers are stable; but text-anchoring is still safest)."

# CONTRACT SOURCE — the bug report (root cause + repro + pane precedent)
- file: plan/004_92f7aeb62a3a/bugfix/001_678d4c980a19/prd_snapshot.md   (prd_index §Issue 2 / h3.1)
  section: "Issue 2 (render --cols 0 / --rows 0 segfault); 'Consider the same guard in region defensively (region derives cols from capture...a degenerate pane geometry would reach the same Terminal.init)'"
  why: "Establishes the segfault is 100% reproducible (exit 139), the pane-path precedent (main.zig:504), and that region is the defensive sibling the PRD explicitly flags for the same guard. This PRP implements Fix Site 3."

# PRECEDENT — the pane guard (DO NOT EDIT; this is the rationale to mirror)
- file: src/main.zig
  section: "paneBody lines 500-506: `if (result.code != 0) { ... return result.code; }` with the comment 'feeding ghostty-vt a zero-dimension terminal (Terminal.init cols=0) segfaults'"
  why: "Documents the EXACT segfault region is now guarding against, and shows the codebase's established pattern for short-circuiting before Terminal.init on a zero-dim input."

# SIBLING-TASK BOUNDARIES (do NOT duplicate / collide)
- file: plan/004_92f7aeb62a3a/bugfix/001_678d4c980a19/architecture/issue2_zero_dimension_segfault.md
  section: "Fix Site 1 (determineCols = S1, COMPLETE); Fix Site 2 (render.run --rows = S2, PARALLEL/IMPLEMENTING); Fix Site 3 (region.zig = S3, THIS task); Tests #2 (integration = S4, PLANNED)"
  why: "S1+S2 edit src/render.zig. S3 edits src/region.zig. S4 owns the formal unit+integration test files. S3 = the region Terminal.init guard ONLY + NO test file (would collide with S4; body() is not unit-testable). Different files => no merge conflict with the parallel S2."

# Empirical verification for THIS task
- file: plan/004_92f7aeb62a3a/bugfix/001_678d4c980a19/P1M1T2S3/research/findings.md
  why: "stderr-in-scope PROOF (line 292), the `tmux-2html region:` prefix verified at 6 call sites, capture.Captured.cols/rows confirmed u16 + unbounded, defer-before-site (no leak), Zig 0.15.2 + --release=fast GOTCHA, composability with S2 (different file)."
```

### Current Codebase tree (relevant slice)

```bash
tmux-2html/
├── src/region.zig          # <— EDIT: insert the zero-dim guard in body() before Terminal.init (line 326)
├── src/capture.zig         # Captured{cols:u16,rows:u16}; geometry() parseInt unbounded — DO NOT EDIT
├── src/main.zig            # pane cols=0 guard (500-506) — precedent, DO NOT EDIT
├── src/render.zig          # S1(determineCols)/S2(run --rows) territory — DO NOT EDIT here
└── src/cli.zig             # parseU16 accepts 0 — DO NOT EDIT (guard belongs at Terminal.init seam)
```

### Desired Codebase tree with files to be changed

```bash
tmux-2html/
└── src/region.zig          # MODIFIED — +6-line inline guard in body() before Terminal.init; NO new test, NO new types, NO new imports, NO signature change
# NO other files. NO docs (DOCS: none per contract — defensive internal guard, no user-facing behavior change).
```

### Known Gotchas of our codebase & Library Quirks

```zig
// GOTCHA 1 — stderr is ALREADY in scope. body() declares `const stderr = std.fs.File.stderr();`
//   as its FIRST statement (region.zig:292). The guard at ~326 MUST reuse it. Re-declaring
//   `const stderr = std.fs.File.stderr();` inside the guard block is a COMPILE ERROR:
//   `error: redeclaration of 'stderr'`. The contract's "Obtain stderr via std.fs.File.stderr()
//   if not already in scope" caveat resolves to "it IS in scope — reuse it."

// GOTCHA 2 — the defer is registered BEFORE the guard site, so early return 2 is LEAK-FREE.
//   `defer allocator.free(cap.ansi);` is at line 310; the guard goes after it (before 326).
//   A `return 2` in the guard triggers the defer correctly. Do NOT move the guard above the defer.

// GOTCHA 3 — cap.cols / cap.rows are u16 (capture.zig:47-48). For u16, `< 1` is exactly `== 0`.
//   The contract and the architecture doc both use the `< 1` form — use it (do NOT write `== 0`).

// GOTCHA 4 — capture does NOT bound cols/rows. capture.geometry() does parseInt(u16, "0", 10)
//   successfully (capture.zig:204-205) and capture.capture() returns them unchecked (235-236).
//   So a zero CAN flow into Captured — the guard is genuinely needed, not dead code. (For a real
//   pane tmux always reports >=1, so it's defensive — but not unreachable by construction.)

// GOTCHA 5 — tests MUST run in ReleaseFast. `zig build test` (Debug) fails with the known Zig
//   0.15.2 linker bug (R_X86_64_PC64 from bundled C++ SIMD libs), NOT a code error. Always:
//   `zig build test --release=fast`. (PRD §15; ci.yml runs `zig build test -Doptimize=ReleaseFast`.)

// GOTCHA 6 — region.body() CANNOT be unit-tested. It needs a real tty (app.enter/render.getSize)
//   and a live tmux capture; there are NO `body:` tests in region.zig today (only `regionPrepare:`
//   tests, which inject a fake capture.Runner). A body() zero-dim test would require injecting a
//   zero-geom Captured, which body()'s signature doesn't support. The zero-dim region case is also
//   not reproducible via real tmux (panes report >=1). => S3 adds NO test; the formal zero-dim
//   tests are sibling task S4 (which owns the test files and may test the reproducible render
//   --cols 0 / --rows 0 paths, or add a regionPrepare injection test if it chooses).

// GOTCHA 7 — do NOT fix this at parseU16 (cli.zig). parseU16 is shared by all subcommands;
//   region/pane get dimensions from tmux capture, NOT CLI parsing. The guard belongs at the
//   Terminal.init seam where the dimension originates (architecture doc "Why NOT fix at parseU16").

// GOTCHA 8 — the guard sits BEFORE Terminal.init, which is the ONLY place region feeds dimensions
//   into a Terminal. region does NOT call renderGrid (it builds the Terminal inline at 326 and
//   feeds ANSI via vtStream). So this single guard closes region's entire zero-dim surface.
```

## Implementation Blueprint

### Data models and structure

No new types. `capture.Captured` (capture.zig:45-48) is unchanged. `region.body()` signature
`pub fn body(allocator: std.mem.Allocator, opts: cli.RegionOpts) anyerror!u8` is unchanged.
No structs/fields/imports added. The guard uses only symbols already in scope at the site
(`cap`, `stderr`).

### The exact deliverable — verbatim edit

#### FILE: `src/region.zig` — the zero-dimension guard (inline in `body()`, before `Terminal.init`)

Locate the unique line (it is the ONLY `Terminal.init` in the file; currently line 326):

```zig
    var t = try Terminal.init(allocator, .{ .cols = cap.cols, .rows = cap.rows, .max_scrollback = render.scrollbackBytes(cap.ansi, cap.cols) });
```

Insert the guard block immediately BEFORE it:

```zig
// ---- BEFORE (exact, unique — the Terminal.init call) ----
    var t = try Terminal.init(allocator, .{ .cols = cap.cols, .rows = cap.rows, .max_scrollback = render.scrollbackBytes(cap.ansi, cap.cols) });
```
```zig
// ---- AFTER ----
    // (Issue 2 defensive guard) region builds its Terminal DIRECTLY (not via renderGrid), so
    // render.zig's cols/rows guards (S1/S2) don't cover it. cap.cols/rows come from capture
    // (always >=1 for a real pane), but a degenerate/resized pane geometry could yield 0 — and
    // Terminal.init on a zero-dimension terminal segfaults (main.zig:504 rationale). Exit 2
    // (capture error, PRD §5) before reaching Terminal.init. Mirrors the pane guard.
    if (cap.cols < 1 or cap.rows < 1) {
        try stderr.writeAll("tmux-2html region: capture has zero-dimension pane geometry\n");
        return 2; // capture/target error (PRD §5)
    }
    var t = try Terminal.init(allocator, .{ .cols = cap.cols, .rows = cap.rows, .max_scrollback = render.scrollbackBytes(cap.ansi, cap.cols) });
```

That is the entire change. `stderr` is the existing `body()`-local const (region.zig:292) —
**reuse it, do NOT redeclare** (GOTCHA 1). The `defer allocator.free(cap.ansi)` (line 310) is
already registered above, so `return 2` frees `cap.ansi` correctly (GOTCHA 2). `body()`,
`regionHandle`, `regionPrepare`, `capture.*`, `render.*` are UNCHANGED. No test is added (GOTCHA 6).

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: EDIT src/region.zig body() — insert the zero-dim guard (THE fix)
  - Locate the unique line `var t = try Terminal.init(allocator, .{ .cols = cap.cols, .rows = cap.rows, .max_scrollback = render.scrollbackBytes(cap.ansi, cap.cols) });`
    (anchor on TEXT; it is the ONLY `Terminal.init` in the file — currently line 326; region.zig
    line numbers are STABLE because the parallel S2 edits a different file (render.zig), but
    text-anchoring is safest).
  - Insert the guard block (see verbatim edit above) immediately BEFORE that line.
  - REUSE the existing `stderr` const (declared body() line 292) — do NOT redeclare it.
  - Do NOT touch regionHandle, regionPrepare, capture.*, render.*, main.zig, or cli.zig.

Task 2: VALIDATE (see Validation Loop — all commands verified)
  - RUN: scripts/safe-run.sh --cpu 1800 -- zig build --release=fast   → expect clean (the build IS the type check)
  - RUN: zig build test --release=fast                                 → expect exit 0 (no new test; all existing green)
  - RUN: grep -n 'cap.cols < 1 or cap.rows < 1' src/region.zig         → expect exactly 1 match
  - RUN: grep -c 'redeclaration' ; (build clean => no redeclaration error => stderr correctly reused)
```

### Implementation Patterns & Key Details

```zig
// PATTERN: mirror the pane guard's RATIONALE (main.zig:500-506) but key on the capture struct
//   region holds directly. The pane path keys on `result.code != 0` (its capture result is a
//   struct with a code field); region's capture result is `capture.Captured` with cols/rows, so
//   key on those:
    if (cap.cols < 1 or cap.rows < 1) {
        try stderr.writeAll("tmux-2html region: capture has zero-dimension pane geometry\n");
        return 2; // capture/target error (PRD §5)
    }

// PATTERN: reuse region's own `tmux-2html region: <msg>\n` stderr prefix — it is the established
//   convention for region's runtime diagnostics (region.zig:448/474/486/493/501/513). Do NOT use
//   the bare `error: ...` prefix (that's only for setup failures at 297/304/403, before any TUI work).

// PATTERN: reuse region's exit code 2 for capture failures (region.zig:297 no-target, 304 cannot-
//   capture). The zero-dim geometry IS a capture-domain problem, so exit 2 (PRD §5) is correct.

// CRITICAL: reuse the existing `stderr` const (body() line 292) — do NOT redeclare. Re-declaring
//           `const stderr` in the same scope is a `redeclaration of 'stderr'` compile error (GOTCHA 1).
// CRITICAL: the guard goes AFTER `defer allocator.free(cap.ansi);` (line 310) so `return 2` is
//           leak-free (GOTCHA 2). Do NOT place it above the defer.
// CRITICAL: this is the ONLY place region feeds dimensions into a Terminal (no renderGrid), so one
//           guard closes region's entire zero-dim surface (GOTCHA 8).
```

### Integration Points

```yaml
REGION GRID BUILD (src/region.zig body()):
  - the zero-dim guard fires only on cap.cols==0 or cap.rows==0; -> stderr msg -> exit 2.
  - cap.cols/cap.rows now validated >= 1 before the ONLY Terminal.init in region.

DOWNSTREAM / OUT OF SCOPE (sibling tasks in T2; do NOT implement here):
  - S1: determineCols --cols 0 guard (render.zig ~96) — COMPLETE.
  - S2: render.run() --rows 0 guard (render.zig run()) — PARALLEL/IMPLEMENTING (different file, no conflict).
  - S4: formal unit + integration tests for zero-dimension rejection (render --cols 0 / --rows 0 / region) —
        PLANNED; OWNS the test files. S3 adds NO test file (would collide with S4; body() not unit-testable).
  - parseU16 (cli.zig:128) — DO NOT change (guard belongs at the Terminal.init seam, not the shared parser).

CONFIG / DATABASE / ROUTES:
  - none.
```

## Validation Loop

> PRIMARY gate: `zig build test --release=fast` → exit 0 (no new test; proves the edit compiles +
> nothing regressed). Plus the grep confirming the guard landed at the right site. S3 needs NO tmux
> for its core validation (the zero-dim region case is not reproducible via real tmux — panes report
> ≥1 — which is exactly why this is a *defensive* guard; its correctness follows mechanically from
> the reused exit-2/stderr machinery, verified to be in scope and compile).

### Level 1: Syntax & Style (Immediate Feedback)

```bash
cd /home/dustin/projects/tmux-2html
# The optimized build IS the type check. Confirms the guard compiles (incl. reuse of the existing
# `stderr` const — NOT a redeclaration). A `redeclaration of 'stderr'` error here means you
# mistakenly re-declared stderr instead of reusing the body()-local const (region.zig:292).
scripts/safe-run.sh --cpu 1800 -- zig build --release=fast 2>&1 | tail -5
# Expected: clean (exit 0). Any error naming region.zig => (a) you redeclared `stderr` (reuse the
# existing const — GOTCHA 1), or (b) a typo in `cap.cols`/`cap.rows`/`stderr`/the message string.
```

### Level 2: Unit Tests (compiles + nothing regressed)

```bash
zig build test --release=fast
# Expected: exit 0. S3 adds NO test (body() can't be unit-tested — GOTCHA 6: it needs a real tty +
# live tmux capture). The regionPrepare tests (783+), render tests, goldens (all use geometry >= 1,
# so the guard never fires), and the S1/S2 edits (if landed) all remain green.
# NOTE: must be --release=fast; plain `zig build test` (Debug) hits the R_X86_64_PC64 linker bug (GOTCHA 5).
```

### Level 3: Confidence checks (the guard landed at the right site, surgical)

```bash
# Confirm the guard reads exactly `if (cap.cols < 1 or cap.rows < 1)` and reuses the existing stderr:
grep -n 'cap.cols < 1 or cap.rows < 1' src/region.zig                 # expect: exactly 1 match in body()
grep -n 'capture has zero-dimension pane geometry' src/region.zig     # expect: exactly 1 match (the guard)
# Confirm stderr is declared ONCE in body() (line 292) and NOT redeclared in the guard:
grep -n 'const stderr = std.fs.File.stderr()' src/region.zig          # expect: exactly 1 match (line 292)

# Confirm the guard sits BEFORE the Terminal.init (and AFTER the defer free cap.ansi):
awk 'NR>=305 && NR<=335' src/region.zig | grep -nE 'defer allocator.free\(cap.ansi\)|cap.cols < 1|Terminal.init'
# Expected output order: defer allocator.free(cap.ansi) ... cap.cols < 1 ... Terminal.init
# (defer first => early return 2 is leak-free; guard before Terminal.init => no segfault reachable.)

# Confirm the edit is surgical (only src/region.zig changed):
git diff --stat
# Expected: src/region.zig only. (The parallel S2, if landed, also shows src/render.zig — a DIFFERENT
# file; that's expected and non-conflicting.)
```

### Level 4: Optional manual smoke (no segfault on a degenerate capture — if you choose to force it)

> This guard is **defensive** and is NOT triggerable through normal tmux (real panes report geometry
> ≥1). There is no clean CLI/tmux reproducer for the zero-dim region case, so Level 4 is OPTIONAL.
> The guard's correctness follows from (a) the compile proof (Level 1), (b) the reused, verified
> exit-2/stderr machinery (region already exits 2 on capture failure at lines 297/304 with the same
> `tmux-2html region:` prefix family), and (c) the placement proof (Level 3: guard before
> Terminal.init). If you want an empirical check, the cleanest is a temporary throwaway probe: build
> region with a forced-zero `cap` and confirm exit 2 (NOT 139) — but do NOT commit such a probe.

```bash
# (OPTIONAL — only if you want empirical proof; not required for the success criteria.)
# The render --cols 0 path (S1's territory, now COMPLETE) IS reproducible and demonstrates the SAME
# crash class is closed in the sibling path — region's guard is the structural mirror:
printf 'x\n' | ./zig-out/bin/tmux-2html render --cols 0 >/dev/null 2>&1; echo "render --cols 0 exit=$?"
# Expected (post-S1): non-zero (2), NOT 139. (This is S1's validation, included only to show the
# shared crash class is handled; region's own guard is validated by Levels 1-3 above.)
```

## Final Validation Checklist

### Technical Validation

- [ ] `zig build --release=fast` builds clean (Level 1 — the optimized build is the type check).
- [ ] `zig build test --release=fast` exits 0 (Level 2 — no new test; all existing green).
- [ ] Goldens/regionPrepare/render tests unaffected (all use geometry ≥1 → guard never fires).

### Feature Validation

- [ ] `grep -n 'cap.cols < 1 or cap.rows < 1' src/region.zig` → exactly 1 match, before Terminal.init.
- [ ] The guard reuses the existing `stderr` const (NOT redeclared) — confirmed by `grep -c 'const
      stderr = std.fs.File.stderr()' src/region.zig` == 1.
- [ ] The guard is placed after `defer allocator.free(cap.ansi);` (Level 3 awk ordering) → early
      `return 2` is leak-free.
- [ ] Message is exactly `tmux-2html region: capture has zero-dimension pane geometry\n`.
- [ ] Normal region invocations (real panes, geometry ≥1) behave identically (guard never fires).

### Code Quality Validation

- [ ] Only `src/region.zig` `body()` changed — the guard inserted immediately before `Terminal.init`.
- [ ] Reuses region's existing `tmux-2html region:` stderr prefix + exit code 2 (no new convention).
- [ ] Anchored on the unique TEXT `var t = try Terminal.init(allocator, .{ .cols = cap.cols, .rows = cap.rows` (immune to line-number drift).
- [ ] Does NOT touch `regionHandle`/`regionPrepare`, `render.*` (S1/S2), `main.zig` (pane precedent),
      `capture.*`, `cli.zig` (`parseU16`), or add any test file (S4).
- [ ] No new types, imports, or signature changes.

### Documentation & Deployment

- [ ] No docs change (DOCS: none per contract — defensive internal guard; no user-facing behavior
      change for normal pane geometries).
- [ ] No new env vars / config / CLI surface.

---

## Anti-Patterns to Avoid

- ❌ Don't redeclare `const stderr = std.fs.File.stderr();` in the guard — it's ALREADY declared at
  `body()` line 292; re-declaring is a `redeclaration of 'stderr'` compile error. Reuse the existing
  `stderr` const (GOTCHA 1). The contract's "if not already in scope" caveat resolves to "it is."
- ❌ Don't invent a new stderr message or exit code — region already exits `2` on capture failures
  (region.zig:297/304) and already uses the `tmux-2html region: <msg>\n` prefix for runtime
  diagnostics (448/474/486/493/501/513). Use the contract's verbatim message + exit 2.
- ❌ Don't write `== 0` — the contract and architecture doc use the `< 1` form (equivalent for u16);
  match them (`if (cap.cols < 1 or cap.rows < 1)`).
- ❌ Don't place the guard above `defer allocator.free(cap.ansi);` (line 310) — it must be AFTER the
  defer so an early `return 2` frees `cap.ansi` (GOTCHA 2).
- ❌ Don't add a unit test or a shell test file in S3 — `region.body()` is not unit-testable (needs a
  real tty + live tmux capture; GOTCHA 6), the zero-dim region case isn't reproducible via real tmux,
  and S4 OWNS the formal zero-dimension tests. A test file here would duplicate/collide with S4.
- ❌ Don't fix this at `parseU16` (cli.zig) — region/pane get dimensions from tmux capture, not CLI
  parsing; the guard belongs at the `Terminal.init` seam (architecture doc "Why NOT fix at parseU16").
- ❌ Don't touch `render.zig` (S1/S2 territory — `determineCols`/`run()`), `main.zig` (pane precedent),
  `capture.zig`, or `regionHandle`/`regionPrepare`.
- ❌ Don't run plain `zig build test` (Debug) — it hits the `R_X86_64_PC64` linker bug. Use
  `--release=fast` (GOTCHA 5).
- ❌ Don't anchor on a line number ("326") — match the unique TEXT
  `var t = try Terminal.init(allocator, .{ .cols = cap.cols, .rows = cap.rows`. (Region line numbers
  are stable because S2 edits render.zig, but text-anchoring is still safest.)

---

**Confidence Score: 10/10** for one-pass implementation success.

The fix is a single inline guard inserted before the unique `Terminal.init` line in `region.body()`.
It reuses **100% existing machinery**: the *same* `stderr` const already in scope at `body()` line 292
(**verified** — reusing it avoids a redeclaration compile error), the *same* `tmux-2html region:`
stderr prefix family (verified at 6 call sites), and the *same* exit code `2` region uses for capture
failures (verified at lines 297/304). The placement is **proven** leak-free (`defer
allocator.free(cap.ansi)` is registered at line 310, before the guard site). `cap.cols`/`cap.rows` are
**confirmed** `u16` from `capture.Captured` (capture.zig:47-48), and `capture.capture()` is **confirmed**
to pass them through unbounded (so the guard is genuinely reachable in principle, not dead code).
The guard is **defensive** — real panes always report geometry ≥1, so there is no user-facing behavior
change; it only converts a theoretical zero-dim segfault (exit 139) into a graceful exit 2.
Composability with the **parallel S2** is **verified**: S2 edits `src/render.zig`, S3 edits
`src/region.zig` — different files, zero text overlap, clean merge. S3 deliberately adds **no unit
test** (`body()` needs a real tty + live tmux and isn't unit-testable; the zero-dim region case isn't
reproducible via real tmux) and **no test file** (S4 owns the formal zero-dimension tests). The
implementer pastes the guard, runs one build + one test suite + one grep. Segfault path closed, exit
code defined, normal behavior preserved.