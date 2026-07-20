# PRP — P1.M1.T1.S1: status-line hint `<S-sel>` → `v=sel C-v=block o=swap` (§7.1 sync)

## Goal

**Feature Goal**: Sync the copy-mode TUI status line (PRD §7.1) to the
copy-mode-parity selection keys (PRD §7.4). The status line currently shows a
conditional, opaque `<S-sel>` token; replace it with a **static**, always-shown
`v=sel C-v=block o=swap` hint that mirrors the actual §7.4 keybindings. This is a
pure display-string change — no logic, no struct change, no tmux, no new files.

**Deliverable**: Surgical edits to THREE files (no new files):
1. `src/tui/view.zig` — `renderStatus()`: remove the conditional `<S-sel>` write;
   add one unconditional `v=sel C-v=block o=swap` write; update the doc comment;
   update 3 of the 4 `renderStatus` unit tests (Test 4 unchanged).
2. `src/tui/select.zig` — one comment: drop the stale `<S-sel>` token reference.
3. `docs/CONFIGURATION.md` — Mode A: update the status-line format example, the
   token bullet, and the "nothing active" example.

**Success Definition**: `zig build test --release=fast` exits 0; `zig build
--release=fast` builds clean. `renderStatus` output for `[LINE]`, `[BLOCK]`, and
mode=`.none` all contain `v=sel C-v=block o=swap` AND `Enter=render q=quit`, and
contain NO `<S-sel>` token anywhere. The emitted line matches §7.1:
`[LINE|BLOCK]  row:N col:M  /pattern  N match(es)  v=sel C-v=block o=swap  Enter=render q=quit`.

## Why

- **Discoverability / copy-mode parity (PRD §7.4)**: the re-anchorable selection
  (`v` begins/re-anchors linewise, `Ctrl-v` toggles block, `o` swaps ends) is the
  headline §7.4 fix, but the on-screen hint still advertised a meaningless
  `<S-sel>`. The status line should teach the actual keys, exactly like tmux
  copy-mode.
- **Always-shown, not conditional**: `<S-sel>` only appeared *after* a selection
  existed — too late to teach. The new hint is static so users see the keys from
  the first frame.
- **Minimal, safe**: a string-literal change in a pure display function. No struct
  fields removed (`has_selection` is retained — set-but-not-read), so no churn in
  `region.zig` or fixtures. No behavior/coordinate/output change.

## What

User-visible: the region overlay's bottom status line now ends with
`v=sel C-v=block o=swap  Enter=render q=quit` (always), instead of a conditional
`<S-sel>` followed by `Enter=render q=quit`.

Technical:
- `renderStatus` (view.zig:226) builds the line in a 256-byte fixed buffer and
  truncates to `cols`. The ONLY logic change is: drop the
  `if (status.has_selection) try w.writeAll("  <S-sel>");` and insert
  `try w.writeAll("  v=sel C-v=block o=swap");` just before the existing
  `Enter=render q=quit` write.
- The `Status.has_selection` field is RETAINED (still set by region.zig:192) but
  no longer read here — acceptable and intentional.

### Success Criteria

- [ ] `view.zig:247` conditional `<S-sel>` write REMOVED; new unconditional
      `v=sel C-v=block o=swap` write ADDED before `Enter=render q=quit`.
- [ ] `view.zig:216` doc comment updated (no `<S-sel>`).
- [ ] Tests 1/2/3 updated (Test 4 unchanged); `zig build test --release=fast` exit 0.
- [ ] `select.zig:45` comment has no `<S-sel>` reference.
- [ ] `CONFIGURATION.md` lines 114/122/125–126 updated.
- [ ] Zero `<S-sel>` occurrences remain in `src/` or `docs/` (grep-verified).
- [ ] `Status.has_selection` field still present (NOT removed).

## All Needed Context

### Context Completeness Check

_Pass: "If someone knew nothing about this codebase, would they have everything
needed to implement this successfully?"_ — Yes. Every edit is given as an exact
byte-accurate old→new block (read from the live source), the 10 `<S-sel>`
occurrences are fully inventoried (no hidden ones), the validation command is
verified working on the baseline, and the one ambiguity (1-space vs 2-space token
separation) is resolved with the rationale. The implementer does pure text
replacement across 3 files.

### Documentation & References

```yaml
# MUST READ - authoritative before/after for every edit (line numbers verified)
- file: plan/003_cd9cd575d6b1/architecture/codebase_findings.md
  why: "Exact current state of renderStatus(), the Status struct decision (retain has_selection), and required before/after for every edit incl. tests + docs."
  critical: "§'Required change': remove line 247, add the unconditional write before line 249. §'Status struct': DO NOT remove has_selection."

# MUST READ - the file with the code change + the 4 tests
- file: src/tui/view.zig
  why: "renderStatus() at line 226; the stale write at line 247; doc comment at line 216; the 4 tests at ~713/739/758/779."
  pattern: "renderStatus builds into a fixed buffer via std.Io.Writer.fixed, truncates to cols, writes once + EL+reset. Each token is written with a 2-space prefix (\"  …\")."
  gotcha: "The buffer is 256 bytes; the new hint is ~22 chars — no overflow. Truncation at `cols` still cuts long patterns before reaching the static tail (Test 4 holds)."

# MUST READ - the comment to update
- file: src/tui/select.zig
  why: "Line 45 comment references the `<S-sel>` token that will no longer exist."
  gotcha: "Do NOT change the `active()` fn body — only the doc comment above it."

# MUST READ - the docs to update (Mode A)
- file: docs/CONFIGURATION.md
  why: "Lines 114 (format example), 122–123 (token bullets), 125–126 (nothing-active example). The §7.4 keybinding table ~line 166 is ALREADY current — do NOT touch it."

# Normative source
- file: PRD.md
  section: "§7.1 (status line format) + §7.4 (selection keys v/Ctrl-v/o)"
  why: "§7.1 defines the target format; §7.4 defines what v/Ctrl-v/o DO (so the hint is accurate). NOTE: PRD §7.1 markdown renders `o=swap Enter` with ONE space; the codebase emits 2-space token separation — follow the 2-space form (see Gotcha 1)."

- file: plan/003_cd9cd575d6b1/P1M1T1S1/research/findings.md
  why: "Companion note: the full <S-sel> inventory (10 occurrences), exact current text per edit, space-convention rationale, baseline test-gate confirmation."
```

### Current Codebase tree (relevant slice)

```bash
tmux-2html/
├── src/tui/
│   ├── view.zig       # <— EDIT: renderStatus() + doc comment + 3 tests
│   └── select.zig     # <— EDIT: one doc comment (line 45)
├── docs/
│   └── CONFIGURATION.md  # <— EDIT: status-line format/bullet/example (Mode A)
└── PRD.md
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
tmux-2html/
├── src/tui/view.zig       # MODIFIED: renderStatus hint swap + doc comment + tests 1/2/3
├── src/tui/select.zig     # MODIFIED: 1 comment line (drop <S-sel> ref)
└── docs/CONFIGURATION.md  # MODIFIED: 3 spots (format example, bullet, nothing-active example)
# NO new files. NO struct/logic/coordinate/output changes.
```

### Known Gotchas of our codebase & Library Quirks

```zig
// GOTCHA 1 — SPACE CONVENTION. PRD §7.1 markdown shows `o=swap Enter=render` (ONE space),
//   but every renderStatus token is emitted with a 2-space prefix (`"  v=sel…"`, `"  Enter…"`),
//   so the real output has TWO spaces between `o=swap` and `Enter`. The contract +
//   codebase_findings.md both require the 2-space form. DO NOT "fix" it to 1 space —
//   that would break byte-equality with the other tokens' separation.

// GOTCHA 2 — tests MUST run in ReleaseFast. `zig build test` (Debug) fails with a
//   known Zig 0.15.2 linker bug (R_X86_64_PC64 from bundled C++ SIMD libs), NOT a
//   code error. Always: `zig build test --release=fast`. (PRD §15.)

// GOTCHA 3 — has_selection is RETAINED. It stays in the Status struct (still set by
//   region.zig:192) but is no longer READ by renderStatus. Do NOT remove it — that
//   would churn region.zig + test fixtures and is explicitly out of scope.

// GOTCHA 4 — Test 4 (truncation, cols=10) needs NO assertion change. With a long
//   pattern the line already exceeds 10 chars before the static tail, so truncation
//   to cols=10 cuts at `row:1 col:` regardless of the new hint. Its `line.len <= 10`
//   assertion still holds. (Verified.)

// GOTCHA 5 — the §7.4 keybinding TABLE in CONFIGURATION.md (~line 166) is ALREADY
//   current (lists v / Ctrl-v / o). Do NOT touch it; only the §7.1 status-line
//   format/bullet/example (~lines 114/122/125) need the edit.
```

## Implementation Blueprint

### Data models and structure

Not applicable — no data models change. `Status.has_selection` is deliberately
retained (set-but-not-read).

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: EDIT renderStatus() core (src/tui/view.zig:246–249) — the display change
  - EXACT OLD (4 lines):
        // <S-sel> (only when a selection is active)
        if (status.has_selection) try w.writeAll("  <S-sel>");
        // static key hints (always shown)
        try w.writeAll("  Enter=render q=quit");
  - EXACT NEW (3 lines; remove the conditional + its comment; add one unconditional write):
        // static key hints (always shown; v/Ctrl-v/o mirror §7.4 selection keys)
        try w.writeAll("  v=sel C-v=block o=swap");
        try w.writeAll("  Enter=render q=quit");
  - WHY FIRST: this is the behavior change the tests + docs describe.
  - GOTCHA: 2-space token separation (Gotcha 1). Do NOT read status.has_selection here anymore.

Task 2: EDIT the doc comment (src/tui/view.zig:216)
  - EXACT OLD:
        ///   `[LINE|BLOCK]  row:N col:M  /pattern  N match(es)  <S-sel>Enter=render q=quit`
  - EXACT NEW:
        ///   `[LINE|BLOCK]  row:N col:M  /pattern  N match(es)  v=sel C-v=block o=swap  Enter=render q=quit`
  - (2 spaces before Enter, matching the codebase token convention.)

Task 3: UPDATE the 3 unit tests (src/tui/view.zig; Test 4 unchanged)
  - Test 1 "renderStatus: [LINE] full line …" — replace these 2 lines:
        OLD:  // <S-sel> shown (has_selection).
        OLD:  try std.testing.expect(std.mem.indexOf(u8, out, "<S-sel>") != null);
        NEW:  // v=sel C-v=block o=swap is now the always-shown hint (no <S-sel> token).
        NEW:  try std.testing.expect(std.mem.indexOf(u8, out, "v=sel C-v=block o=swap") != null);
        NEW:  try std.testing.expect(std.mem.indexOf(u8, out, "<S-sel>") == null);
    (has_selection stays =true in this Status; the hint is now shown regardless.)
  - Test 2 "renderStatus: [BLOCK] mode + field order" — update the comment + add an assertion:
        OLD:  // empty pattern ⇒ no search token; no selection ⇒ no <S-sel>.
        OLD:  try std.testing.expect(std.mem.indexOf(u8, out, "<S-sel>") == null);
        NEW:  // empty pattern ⇒ no search token; the v/Ctrl-v/o hint is always shown (no <S-sel>).
        NEW:  try std.testing.expect(std.mem.indexOf(u8, out, "v=sel C-v=block o=swap") != null);
        NEW:  try std.testing.expect(std.mem.indexOf(u8, out, "<S-sel>") == null);
  - Test 3 "renderStatus: mode=.none omits the bracket …" — ADD one assertion after the
        existing "Enter=render q=quit" check (line ~776):
        ADD:  // the v/Ctrl-v/o hint is shown even in .none mode (always-on).
        ADD:  try std.testing.expect(std.mem.indexOf(u8, out, "v=sel C-v=block o=swap") != null);
  - Test 4 "renderStatus: truncates the line to cols" — NO CHANGE (Gotcha 4).
  - NAMING: keep the existing test names; only edit assertion lines/comments.
  - DEPENDENCIES: Task 1 (the new token must be emitted or these assertions fail).

Task 4: EDIT the select.zig comment (src/tui/select.zig:44–45)
  - EXACT OLD:
        /// True when a selection is active (mode != .none). Drives the Esc clear-vs-quit decision
        /// in region.zig + the status line's `<S-sel>` token + `view.Status.has_selection`.
  - EXACT NEW:
        /// True when a selection is active (mode != .none). Drives the Esc clear-vs-quit decision
        /// in region.zig + `view.Status.has_selection` (retained for future use).
  - GOTCHA: do NOT change the active() function body — only this doc comment.

Task 5: EDIT docs/CONFIGURATION.md (Mode A) — 3 spots
  - (a) Line ~114 format example:
        OLD:  [LINE|BLOCK]  row:N col:M  /pattern  N match(es)  <S-sel>  Enter=render q=quit
        NEW:  [LINE|BLOCK]  row:N col:M  /pattern  N match(es)  v=sel C-v=block o=swap  Enter=render q=quit
  - (b) Lines ~122–123 token bullets — replace the `<S-sel>` bullet:
        OLD:  - `<S-sel>` — shown only when a selection is active.
        NEW:  - `v=sel C-v=block o=swap` — always shown; press `v` to start/re-anchor a
                linewise selection, `Ctrl-v` to toggle visual block mode, `o` to swap the
                cursor to the other end of the selection (see Selection below).
        (Leave the `- `Enter=render q=quit` — always shown.` bullet as-is.)
  - (c) Lines ~125–126 "nothing active" example:
        OLD:  For example, with nothing active the status line is just
              `row:1 col:1  Enter=render q=quit`.
        NEW:  For example, with nothing active the status line is
              `row:1 col:1  v=sel C-v=block o=swap  Enter=render q=quit`.
  - DO NOT touch the §7.4 keybinding table (~line 166) — already current.

Task 6: VALIDATE  (see Validation Loop)
  - RUN: zig build test --release=fast   → expect exit 0
  - RUN: zig build --release=fast        → expect clean build
  - RUN: grep -rn '<S-sel>' src/ docs/   → expect NO matches
```

### Implementation Patterns & Key Details

```zig
// PATTERN: renderStatus writes each token with a 2-space prefix into a fixed buffer,
// then truncates the whole buffer to `cols` and writes once. The new hint follows the
// same convention — DO NOT introduce a different separator:
try w.writeAll("  v=sel C-v=block o=swap");   // 2-space prefix, like every other token
try w.writeAll("  Enter=render q=quit");

// PATTERN: the tests use std.mem.indexOf(u8, out, "token") != null / == null on the
// captured Allocating-writer output. Mirror that exactly for the new token.

// CRITICAL: has_selection is RETAINED in Status (set by region.zig:192) but renderStatus
// no longer branches on it. Removing the field is OUT OF SCOPE (would churn region.zig).
```

### Integration Points

```yaml
TUI STATUS LINE (src/tui/view.zig):
  - renderStatus() output format changes; consumed unchanged by tui/app.zig (which just
    paints renderStatus's bytes on the last row). No caller signature change.

SELECTION MODEL (src/tui/select.zig):
  - the `active()` fn + Sel struct are UNCHANGED; only a doc comment is updated.
  - The §7.4 keys (v/Ctrl-v/o) already work — this task only makes the hint ACCURATE.

DOCS (docs/CONFIGURATION.md):
  - §7.1 status-line format/bullet/example updated; §7.4 keybind table already current.

DOWNSTREAM / OUT OF SCOPE:
  - region.zig (sets has_selection) — UNCHANGED.
  - README.md — generic "lists every key" line (~102) is still accurate; the Mode B task
    (P1.M1.T2.S1) verifies the overview docs. Do NOT edit README here.
  - No coordinate/output/render change; no tmux; no CLI change.

CONFIG / DATABASE / ROUTES:
  - none.
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Zig compiles as it type-checks; the build is the check. Confirm both files parse:
zig build --release=fast 2>&1 | tail -5    # expect: clean (exit 0), installs tmux-2html
# If you see a view.zig/select.zig compile error, fix the edit shape first.

# Confirm ZERO <S-sel> remnants in the touched surfaces:
grep -rn '<S-sel>' src/ docs/   # expect: NO output
# (A non-empty result means a spot was missed — see the 10-occurrence inventory in
#  research/findings.md §1.)
```

### Level 2: Unit Tests (Component Validation)

```bash
# PRIMARY GATE — ReleaseFast is MANDATORY (Gotcha 2: Debug hits the R_X86_64_PC64 linker bug).
zig build test --release=fast
# Expected: exit 0. The 3 updated renderStatus tests assert v=sel C-v=block o=swap is
# present (and <S-sel> absent); Test 4 (truncation) still passes unchanged.
#
# NOTE: plain `zig build test` (no --release=fast) will FAIL with a linker error that is
# UNRELATED to your change — do not be fooled (see Gotcha 2 / PRD §15).
```

### Level 3: Integration Testing (System Validation)

```bash
# renderStatus is a pure function over a Status struct (no Terminal, no tty). The unit
# tests ARE the integration proof. Additionally, eyeball the exact emitted line:
zig build --release=fast
# (Optional, in a scratch Zig snippet or via the test harness) confirm the full line for
# [LINE] mode reads exactly:
#   [LINE]  row:3 col:4  /foo  3 match(es)  v=sel C-v=block o=swap  Enter=render q=quit
# and for .none mode reads:
#   row:1 col:1  v=sel C-v=block o=swap  Enter=render q=quit
# (the updated Test 1 and the added Test 3 assertion encode these.)
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Regression guard: confirm the new hint does NOT break the buffer/truncation invariant.
# The line for a long pattern + small cols must still be <= cols (no wrap, no overflow):
#   Test 4 already covers cols=10 → line truncated to "row:1 col:" (<= 10). It passes.

# Consistency guard: confirm docs match code byte-for-byte. After edits, the
# CONFIGURATION.md format example and the renderStatus doc comment (view.zig:216) should
# be the SAME string:
diff <(grep -m1 'row:N col:M' docs/CONFIGURATION.md) <(sed -n '216p' src/tui/view.zig | sed 's/.*`//; s/`$//')
# (Expected: empty diff, modulo the leading `///   ` doc prefix — both strings match.)
```

## Final Validation Checklist

### Technical Validation

- [ ] `zig build --release=fast` builds clean (Level 1).
- [ ] `zig build test --release=fast` exits 0 (Level 2 — primary gate).
- [ ] `grep -rn '<S-sel>' src/ docs/` returns nothing (Level 1).

### Feature Validation

- [ ] renderStatus emits `v=sel C-v=block o=swap` for `[LINE]`, `[BLOCK]`, AND `.none`.
- [ ] No `<S-sel>` token in any renderStatus output.
- [ ] `Enter=render q=quit` still always present; field order matches §7.1.
- [ ] `Status.has_selection` field still present (NOT removed).
- [ ] CONFIGURATION.md format/bullet/example updated; §7.4 keybind table untouched.

### Code Quality Validation

- [ ] New writeAll uses the 2-space token convention (matches siblings).
- [ ] Doc comment (view.zig:216) matches the code's actual output.
- [ ] select.zig `active()` body unchanged (only the comment).
- [ ] Test names unchanged; only assertion lines/comments edited (Test 4 untouched).

### Documentation & Deployment

- [ ] CONFIGURATION.md §7.1 status-line section consistent with the code (Mode A).
- [ ] No new env vars / config; no CLI surface change.

---

## Anti-Patterns to Avoid

- ❌ Don't run plain `zig build test` — it fails on the Debug linker bug
  (`R_X86_64_PC64`). Use `zig build test --release=fast`.
- ❌ Don't change the token separator to 1 space to "match the PRD" — the codebase
  uses 2-space token separation everywhere; the contract requires the 2-space form.
- ❌ Don't remove `Status.has_selection` — it's retained (set by region.zig); removing
  it churns region.zig + fixtures and is out of scope.
- ❌ Don't touch the §7.4 keybinding table in CONFIGURATION.md (~line 166) — it's
  already current; only the §7.1 status-line spots need editing.
- ❌ Don't change `select.active()` or any selection logic — this is a DISPLAY-STRING
  change only; the §7.4 keys already work.
- ❌ Don't edit region.zig, README.md, or any Zig logic/coordinates — out of scope
  (README is the separate Mode B task P1.M1.T2.S1).
- ❌ Don't leave any `<S-sel>` remnant — grep `src/` and `docs/` must be clean (10
  occurrences inventoried; all must be converted/removed).

---

**Confidence Score: 10/10** for one-pass implementation success.

This is a surgical string-literal swap in a pure display function, with every edit
specified as byte-accurate old→new text read from the live source. All 10 `<S-sel>`
occurrences are inventoried (none hidden); the one ambiguity (1-vs-2-space
separation) is resolved with rationale; the `has_selection` retain-decision and the
Test-4-no-change reasoning are explicit; and the validation gate
(`zig build test --release=fast`) was verified EXIT 0 on the baseline. No logic,
struct, coordinate, or output change — so zero regression surface beyond the 3 edited
files. Scope is cleanly bounded from region.zig, README (Mode B task), and the §7.4
keybinding table.