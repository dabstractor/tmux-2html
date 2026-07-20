# PRP — P1.M1.T1.S1: make `selectionBodyEmpty` `pub` in render.zig

## Goal

**Feature Goal**: Change `selectionBodyEmpty` in `src/render.zig` from module-private
(`fn`) to exported (`pub fn`) so the sibling task (P1.M1.T1.S2) can call
`render.selectionBodyEmpty(...)` from `region.zig`'s confirm arm to honor PRD §13's
empty/zero-cell-selection guard. This is a **visibility-only** change — no logic, no body,
no caller, no test changes.

**Deliverable**: A one-keyword edit on `src/render.zig:609`: `fn selectionBodyEmpty` →
`pub fn selectionBodyEmpty`. That is the entire deliverable.

**Success Definition**: `zig build test --release=fast` exits 0 (the existing
`selectionBodyEmpty` unit test at render.zig:1317 stays green); `zig build --release=fast`
builds clean. The symbol `render.selectionBodyEmpty` is now callable from other modules
(unlocking S2). No behavior change for any current caller.

## Why

- **Enables the Issue 1 fix (PRD §13)**: the region TUI's `Enter`/`y` confirm currently
  writes an empty-body HTML file (exit 0) when the selection covers only blank cells,
  because `region.zig` has no emptiness check. The *correct* check already exists in
  `render.zig` (`selectionBodyEmpty`, used by the `render --selection` path at line 789),
  but it is module-private. Making it `pub` lets S2 reuse the proven helper instead of
  duplicating the logic — DRY and consistency between the two selection-rendering paths.
- **Minimal, safe**: a `pub` keyword is still callable within its own module, so the
  existing same-module caller (render.zig:789) and unit test (render.zig:1317) are
  completely unaffected. S1 changes behavior for nobody; it only *unlocks* the symbol.

## What

User-visible: nothing (internal visibility change; no CLI/config/API surface).
Technical: add the `pub` keyword to the `selectionBodyEmpty` declaration. The function
itself (scan the `<pre>…</pre>` body for non-whitespace; true if empty/all-whitespace,
false otherwise incl. malformed HTML) is unchanged.

### Success Criteria

- [ ] `src/render.zig:609` reads `pub fn selectionBodyEmpty(html: []const u8) bool {`.
- [ ] The function body, the caller at render.zig:789, and the unit test at
      render.zig:1317–1328 are byte-identical to before.
- [ ] `zig build test --release=fast` exits 0.
- [ ] `zig build --release=fast` builds clean (the symbol now exports).
- [ ] No other file changes (region.zig / capture.zig / tui/* untouched — S2 adds the call).

## All Needed Context

### Context Completeness Check

_Pass: "If someone knew nothing about this codebase, would they have everything
needed to implement this successfully?"_ — Yes. It is a single keyword insertion on one
line; the exact before/after is given verbatim, the unaffected caller and test are named
with line numbers, and the validation command is verified working. No codebase knowledge
beyond "edit this one keyword" is required.

### Documentation & References

```yaml
# MUST READ - the issue this unblocks (Issue 1, PRD §13 empty-selection guard)
- file: plan/004_92f7aeb62a3a/bugfix/001_678d4c980a19/architecture/issue1_region_empty_confirm.md
  why: "The Issue 1 analysis: selectionBodyEmpty (render.zig:609) is the proven helper; the Suggested Fix says 'make it pub or add a thin pub wrapper'. S1 does the 'make it pub' option; S2 adds the region.zig call."
  critical: "This task is ONLY the visibility change. The region.zig guard + the pty integration test are S2 and S3 — do NOT implement them here."

# MUST READ - the file (and line) to edit
- file: src/render.zig
  why: "Line 609 = the declaration (fn → pub fn). Line 789 = the unchanged same-module caller. Lines 1317–1328 = the unchanged unit test."
  pattern: "fn selectionBodyEmpty(html: []const u8) bool { … } — scans <pre>…</pre> body for non-whitespace; true if empty/all-ws, false otherwise (malformed ⇒ false)."
  gotcha: "Change ONLY the keyword. The body, the line-789 caller, and the 1317 test are all unaffected by fn→pub (a pub fn is callable within its own module identically)."

- file: plan/004_92f7aeb62a3a/bugfix/001_678d4c980a19/P1M1T1S1/research/findings.md
  why: "Companion note: confirms region.zig has 0 current references (S2 adds the first), the baseline gate is green, and the scope boundary vs S2/S3."
```

### Current Codebase tree (relevant slice)

```bash
tmux-2html/
└── src/
    └── render.zig   # <— EDIT line 609: fn → pub fn (visibility only)
# region.zig, capture.zig, tui/* : UNCHANGED (S2 adds the region.zig call)
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
tmux-2html/
└── src/
    └── render.zig   # MODIFIED: one keyword (fn → pub fn) on line 609
# NO new files. NO other edits.
```

### Known Gotchas of our codebase & Library Quirks

```zig
// GOTCHA 1 — a pub fn is still callable within its own module. So the same-module caller
//   at render.zig:789 (`if (selectionBodyEmpty(html)) {`) and the unit test at render.zig:1317
//   need NO change. Do not "update" them — they are identical before and after.

// GOTCHA 2 — tests MUST run in ReleaseFast. `zig build test` (Debug) fails with the known
//   Zig 0.15.2 linker bug (R_X86_64_PC64 from bundled C++ SIMD libs), NOT a code error.
//   Always: `zig build test --release=fast`. (PRD §15.)

// GOTCHA 3 — S1 alone adds NO new caller. region.zig does not yet reference
//   selectionBodyEmpty (grep -c = 0). The only observable effect of S1 is that the symbol
//   becomes exported, so S2's `render.selectionBodyEmpty(...)` call will compile. Do not
//   add the region.zig call here (that's S2).

// GOTCHA 4 — do NOT add a "thin pub wrapper" variant. The Issue 1 analysis offered two
//   options ("make it pub" OR "add a thin pub wrapper"); this task is the simpler "make it
//   pub" option (single keyword, zero new code).
```

## Implementation Blueprint

### Data models and structure

Not applicable — no data models; a one-keyword visibility change.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: EDIT the declaration (src/render.zig:609) — the entire change
  - EXACT OLD (line 609):
        fn selectionBodyEmpty(html: []const u8) bool {
  - EXACT NEW (line 609):
        pub fn selectionBodyEmpty(html: []const u8) bool {
  - The ONLY difference is the leading `pub ` keyword. The body (lines 610–615), the
    caller at line 789, and the unit test at lines 1317–1328 are UNTOUCHED.
  - VERIFY (post-edit): grep -n 'fn selectionBodyEmpty' src/render.zig  → line 609 shows `pub fn`.

Task 2: VALIDATE  (see Validation Loop)
  - RUN: zig build test --release=fast   → expect exit 0 (the 1317 unit test stays green)
  - RUN: zig build --release=fast        → expect clean build (the pub symbol exports)
```

### Implementation Patterns & Key Details

```zig
// The change: add `pub` to the declaration. Nothing else.
//   BEFORE:  fn selectionBodyEmpty(html: []const u8) bool {
//   AFTER:   pub fn selectionBodyEmpty(html: []const u8) bool {
//
// The function (unchanged) scans the <pre>…</pre> body for non-whitespace:
//   true  ⇒ empty / all-whitespace  (PRD §13 ⇒ region confirm must warn + exit 1, no file)
//   false ⇒ has content OR malformed HTML (safe non-empty fallback)
// Used today by render.zig:789 (the --selection arm); S2 will reuse it from region.zig.
```

### Integration Points

```yaml
MODULE EXPORTS (src/render.zig):
  - selectionBodyEmpty becomes pub (exported). Callers WITHIN render.zig (line 789) are
    unaffected. NEW cross-module callers (region.zig, added in S2) can now compile.

DOWNSTREAM / OUT OF SCOPE:
  - S2 (sibling): add `if (render.selectionBodyEmpty(fragment)) { …exit 1… }` in region.zig's
    `.confirm =>` arm, before writing the file/.last-output sidecar. Do NOT add it here.
  - S3 (sibling): the python3 pty integration test for blank-cell region confirm. Not here.
  - region.zig / capture.zig / tui/*: UNCHANGED in S1.

CONFIG / DATABASE / ROUTES:
  - none.
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# The build is the compile check. Confirm the file still compiles + the symbol exports:
zig build --release=fast 2>&1 | tail -5    # expect: clean (exit 0), installs tmux-2html
# A compile error here means the keyword was mistyped or the wrong line was edited — re-check.

# Confirm the declaration is now pub (and there's still exactly ONE definition):
grep -n 'fn selectionBodyEmpty' src/render.zig   # expect line 609: `pub fn selectionBodyEmpty(...)`
```

### Level 2: Unit Tests (Component Validation)

```bash
# PRIMARY GATE — ReleaseFast MANDATORY (Gotcha 2: Debug hits the R_X86_64_PC64 linker bug).
zig build test --release=fast
# Expected: exit 0. The existing `selectionBodyEmpty` unit test (render.zig:1317) — which
# asserts blank⇒true, whitespace⇒true, content⇒false, span⇒false, malformed⇒false — stays
# green unchanged (visibility does not affect the test).
```

### Level 3: Integration Testing (System Validation)

```bash
# Not applicable for S1 — there is no new behavior to integrate. S1 is a pure visibility
# change with zero new callers. The compile (Level 1) + the unchanged unit test (Level 2)
# ARE the proof. The cross-module call that consumes the now-pub symbol is added in S2.
```

### Level 4: Creative & Domain-Specific Validation

```bash
# (Optional, for confidence) Prove the symbol is now cross-module-callable by confirming it
# is NOT marked private — a quick compile probe that references it would work, but S2 IS
# that probe. For S1, the grep + the green test gate suffice.
grep -n 'pub fn selectionBodyEmpty' src/render.zig   # expect line 609
```

## Final Validation Checklist

### Technical Validation

- [ ] `zig build --release=fast` builds clean (Level 1).
- [ ] `zig build test --release=fast` exits 0 (Level 2 — primary gate).

### Feature Validation

- [ ] `src/render.zig:609` reads `pub fn selectionBodyEmpty(html: []const u8) bool {`.
- [ ] Function body (610–615), caller (789), and unit test (1317–1328) byte-identical.
- [ ] No other file changed (region.zig/capture.zig/tui/* untouched).

### Code Quality Validation

- [ ] Only the `pub` keyword added; no new code, no wrapper, no duplication.
- [ ] Existing conventions honored (the file already uses `pub fn` for exported helpers).

### Documentation & Deployment

- [ ] No docs (internal visibility change; no user-facing/config/API surface).

---

## Anti-Patterns to Avoid

- ❌ Don't change the function body, algorithm, or return type — visibility ONLY.
- ❌ Don't edit the same-module caller (render.zig:789) or the unit test (render.zig:1317) —
  a `pub fn` is callable within its own module identically; they are unaffected.
- ❌ Don't add the region.zig guard here — that's S2. S1 only *unlocks* the symbol.
- ❌ Don't add a "thin pub wrapper" — the Issue 1 analysis offered two options; this task is
  the simpler "make it pub" (single keyword).
- ❌ Don't run plain `zig build test` — Debug hits the `R_X86_64_PC64` linker bug. Use
  `zig build test --release=fast`.
- ❌ Don't touch region.zig / capture.zig / tui/* / any test — out of scope for S1.

---

**Confidence Score: 10/10** for one-pass implementation success.

It is a single keyword insertion (`fn` → `pub fn`) on one verified line (render.zig:609),
with the unaffected caller (line 789) and unit test (lines 1317–1328) named explicitly.
Because a `pub fn` is callable within its own module exactly as `fn` is, the change has zero
behavioral effect on existing code — it only exports the symbol so S2's `region.zig` call
compiles. The baseline test gate (`zig build test --release=fast`) was verified EXIT 0, and
the change cannot regress it. Scope is cleanly bounded from S2 (the region.zig guard) and S3
(the pty integration test).