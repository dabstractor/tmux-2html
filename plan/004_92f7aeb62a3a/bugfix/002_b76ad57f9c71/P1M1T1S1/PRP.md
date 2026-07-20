# PRP — P1.M1.T1.S1: add `raw.lflag.ISIG = false;` to `app.makeRaw` + tests + doc-comment

## Goal

**Feature Goal**: Disable `ISIG` in `app.makeRaw` (`src/tui/app.zig`) so the region TUI's
tty-control keys (Ctrl-c/Ctrl-z/Ctrl-\\) arrive as readable bytes that `input.zig`
classifies, instead of being intercepted by the kernel as SIGINT/SIGTSTP/SIGQUIT. This is
the shared one-line root-cause fix for Issue 2 (Ctrl-z freezes the popup, terminal
unrestored) and Issue 3 (Ctrl-c exits 130, not PRD §7.5's exit 1). Update the makeRaw
doc-comment and the two makeRaw unit tests to match.

**Deliverable**: Surgical edits to ONE file (`src/tui/app.zig`):
1. `makeRaw` (line 94): add `raw.lflag.ISIG = false;` immediately after the ECHO line.
2. The makeRaw doc-comment (~line 90): list ISIG among the cleared lflag flags + the rationale.
3. Test 1 ("makeRaw: clears …"): add `input.lflag.ISIG = true;` to the input termios and
   `try std.testing.expectEqual(false, raw.lflag.ISIG);` to the assertions.
4. Test 2 ("makeRaw: idempotent …"): add `try std.testing.expectEqual(false, out.lflag.ISIG);`.

**Success Definition**: `zig build test -Doptimize=ReleaseFast` exits 0. makeRaw now
produces an ISIG=false termios; the two unit tests prove it. No other file changes
(palette.zig/input.zig/region.zig untouched). The region TUI's Ctrl-c/Ctrl-z/Ctrl-\\ now
arrive as readable bytes (the live-pty regression harness for that is the SIBLING task
P1.M1.T2.S1).

## Why

- **Issue 2 (Major)**: Ctrl-z → SIGTSTP (no handler) → process stopped, terminal left in
  raw+alt-screen+hidden-cursor, popup frozen with no in-TUI recovery. Violates PRD §7.1
  ("Restore on exit (always, including panic)").
- **Issue 3 (Minor)**: Ctrl-c → SIGINT → restore+reraise → exit **130**, not PRD §7.5's
  exit **1** (grouped with q/Esc as a cancel).
- **Single uniform root-cause fix**: both stem from `ISIG` left enabled in `makeRaw`.
  Disabling it makes Ctrl-c/z/\\ inert bytes — and `input.decodeByte` *already* maps
  `0x03 ⇒ .quit` (currently dead code only because ISIG intercepts it first). The PRD
  recommends this as "the smaller, uniform fix that aligns the cancel keys with input.zig's
  byte mappings." No `input.zig` change, no SIGTSTP handler needed.

## What

User-visible (region TUI): Ctrl-c cancels to exit 1 (not 130); Ctrl-z/Ctrl-\\ are swallowed
(no suspend, no core dump, terminal always restored). External signals (`kill -TERM`,
`kill -INT`) still restore+reraise via the unchanged handlers.
Technical: one termios flag (`lflag.ISIG = false`) added to `makeRaw`; doc-comment + 2 unit
tests updated. No logic beyond the flag.

### Success Criteria

- [ ] `makeRaw` sets `raw.lflag.ISIG = false;` (immediately after the ECHO line).
- [ ] Doc-comment lists ISIG among cleared lflag flags + notes the rationale (§7.1/§7.5).
- [ ] Test 1 sets `input.lflag.ISIG = true;` and asserts `raw.lflag.ISIG == false`.
- [ ] Test 2 asserts `out.lflag.ISIG == false` (idempotent).
- [ ] `zig build test -Doptimize=ReleaseFast` exits 0.
- [ ] palette.zig / input.zig / motion.zig / select.zig / view.zig / region.zig UNCHANGED.

## All Needed Context

### Context Completeness Check

_Pass: "If someone knew nothing about this codebase, would they have everything needed to
implement this successfully?"_ — Yes. Every edit is given as byte-accurate old→new text
read from the live source (function line, doc-comment, both test inputs/assertions). The
root-cause + side-effect analysis (why ISIG-off is safe) is included, the scope boundaries
(palette.zig's separate raw-mode, the unchanged signal handlers) are explicit, and the
validation command is verified green on the baseline.

### Documentation & References

```yaml
# MUST READ - the authoritative design for this exact fix
- file: plan/004_92f7aeb62a3a/bugfix/002_b76ad57f9c71/architecture/isig_fix_design.md
  why: "Root-cause table (Ctrl-c/z/\\ with ISIG on vs off), the exact one-line fix, the unit-test update recipe, the scope (palette.zig + signal handlers untouched), and the side-effect analysis."
  critical: "§'The fix' shows ISIG goes right after the ECHO line. §'Scope' — palette.zig is OUT OF SCOPE (its own raw-mode); the SIGINT/SIGTERM/SIGQUIT handlers STAY (external signals)."

# MUST READ - the file (and lines) to edit
- file: src/tui/app.zig
  why: "makeRaw at line 94 (doc-comment at 90); the ISIG line goes after line 97 (ECHO). Test 1 at 505 (input ISIG after 510; assertion after 523). Test 2 at 540 (assertion after 547)."
  pattern: "makeRaw: var raw = original; raw.lflag.ICANON=false; raw.lflag.ECHO=false; <ISIG here>; raw.iflag.IXON=false; … Each line has an inline // comment."
  gotcha: "ISIG is a lflag bit (raw.lflag.ISIG), NOT iflag. Add it with the other lflag clears (ICANON/ECHO), not with the iflag group."

# Context - the issue reports this fixes
- file: plan/004_92f7aeb62a3a/bugfix/002_b76ad57f9c71/TEST_RESULTS.md
  section: "Issue 2 (Ctrl-z freezes popup) + Issue 3 (Ctrl-c exit 130)"
  why: "Confirms ISIG-left-on is the shared root cause; pty-verified repro; PRD §7.1/§7.5 references."

- file: plan/004_92f7aeb62a3a/bugfix/002_b76ad57f9c71/P1M1T1S1/research/findings.md
  why: "Companion note: exact byte-accurate before/after per edit, palette.zig out-of-scope confirmation (grep), baseline-gate green."
```

### Current Codebase tree (relevant slice)

```bash
tmux-2html/
└── src/tui/
    └── app.zig   # <— EDIT: makeRaw (line ~97) + doc-comment (~90) + 2 unit tests (505, 540)
# palette.zig : DO NOT EDIT (its own raw-mode, palette.zig:106–109)
# input.zig/motion.zig/select.zig/view.zig/region.zig : DO NOT EDIT
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
tmux-2html/
└── src/tui/
    └── app.zig   # MODIFIED: +1 ISIG line in makeRaw; doc-comment; 2 test assertions/inputs
# NO new files. NO other edits.
```

### Known Gotchas of our codebase & Library Quirks

```zig
// GOTCHA 1 — ISIG is a LFLAG bit (raw.lflag.ISIG), not iflag. Add it with the ICANON/ECHO
//   clears, NOT with the IXON/ICRNL/BRKINT (iflag) group. (app.zig groups lflag clears first.)

// GOTCHA 2 — in the unit test, ISIG is FALSE in a zeroed termios (std.mem.zeroes). So an
//   assertion `expectEqual(false, raw.lflag.ISIG)` would pass TRIVIALLY unless the input
//   SETS it. You MUST add `input.lflag.ISIG = true;` to the input termios, or the test
//   proves nothing (this is exactly why the round-2 audit missed the bug).

// GOTCHA 3 — tests MUST run in ReleaseFast. `zig build test` (Debug) fails with the known
//   Zig 0.15.2 linker bug (R_X86_64_PC64 from bundled C++ SIMD libs), NOT a code error.
//   Always: `zig build test -Doptimize=ReleaseFast` (= `--release=fast`). (PRD §15.)

// GOTCHA 4 — palette.zig has its OWN raw-mode (palette.zig:106–109: ICANON/ECHO off,
//   MIN=0/TIME=5) for the short sync-palette OSC query, OUTSIDE the popup. It does NOT set
//   ISIG. DO NOT change it — the PRD issues are region-TUI-only and changing palette.zig
//   risks side effects on the palette query.

// GOTCHA 5 — the SIGINT/SIGTERM/SIGQUIT handlers (installSignalHandlers) STAY. They handle
//   EXTERNAL signals (kill -TERM/-INT). With ISIG off, tty-Ctrl-c no longer generates SIGINT
//   (it becomes the exit-1 byte path), but external signals still restore+reraise correctly.
//   No SIGTSTP handler is needed (ISIG off ⇒ Ctrl-z is never a signal).
```

## Implementation Blueprint

### Data models and structure

Not applicable — a one-flag termios change; no data models.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: ADD the ISIG clear to makeRaw (src/tui/app.zig, after line 97) — the core fix
  - EXACT OLD:
        raw.lflag.ICANON = false; // no canonical (line) mode
        raw.lflag.ECHO = false; // no echo of keystrokes
        raw.iflag.IXON = false; // disable Ctrl-S/Ctrl-Q flow control
  - EXACT NEW (one line inserted):
        raw.lflag.ICANON = false; // no canonical (line) mode
        raw.lflag.ECHO = false; // no echo of keystrokes
        raw.lflag.ISIG = false; // disable Ctrl-c/z/\ as signals → arrive as bytes input.zig handles (Issues 2 & 3, §7.5)
        raw.iflag.IXON = false; // disable Ctrl-S/Ctrl-Q flow control
  - GOTCHA 1: lflag, not iflag. Place with the ICANON/ECHO clears.

Task 2: UPDATE the makeRaw doc-comment (src/tui/app.zig ~lines 90–93)
  - EXACT OLD:
        /// PURE: produce a raw-mode termios from `original`. Clears ICANON/ECHO (lflag),
        /// IXON/ICRNL/BRKINT (iflag), OPOST (oflag); sets CSIZE=.CS8 (cflag); sets cc[V.MIN]=1 /
        /// cc[V.TIME]=0 (BLOCKING byte-at-a-time reads). Leaves every other field EQUAL to `original`.
        /// No I/O — directly unit-tested.
  - EXACT NEW (add ISIG to the lflag list + a rationale line):
        /// PURE: produce a raw-mode termios from `original`. Clears ICANON/ECHO/ISIG (lflag),
        /// IXON/ICRNL/BRKINT (iflag), OPOST (oflag); sets CSIZE=.CS8 (cflag); sets cc[V.MIN]=1 /
        /// cc[V.TIME]=0 (BLOCKING byte-at-a-time reads). Leaves every other field EQUAL to `original`.
        /// ISIG is cleared so Ctrl-c/Ctrl-z/Ctrl-\ arrive as readable bytes (input.zig classifies
        /// them) instead of kernel signals (SIGINT/SIGTSTP/SIGQUIT) — PRD §7.1 (always restore) /
        /// §7.5 (Ctrl-c ⇒ exit 1, not 130). No I/O — directly unit-tested.
  - DEPENDENCIES: Task 1.

Task 3: UPDATE Test 1 (src/tui/app.zig ~lines 505–538)
  - (a) Input termios — ADD `input.lflag.ISIG = true;` after the ECHO=true line:
        OLD:  input.lflag.ICANON = true;
              input.lflag.ECHO = true;
              input.iflag.IXON = true;
        NEW:  input.lflag.ICANON = true;
              input.lflag.ECHO = true;
              input.lflag.ISIG = true;
              input.iflag.IXON = true;
  - (b) Assertion — ADD `try std.testing.expectEqual(false, raw.lflag.ISIG);` after the ECHO assertion:
        OLD:  try std.testing.expectEqual(false, raw.lflag.ECHO);
              try std.testing.expectEqual(false, raw.iflag.IXON);
        NEW:  try std.testing.expectEqual(false, raw.lflag.ECHO);
              try std.testing.expectEqual(false, raw.lflag.ISIG);
              try std.testing.expectEqual(false, raw.iflag.IXON);
  - GOTCHA 2: you MUST set ISIG=true on the INPUT or the assertion is vacuous.
  - (Optional) rename the test to "makeRaw: clears ICANON/ECHO/ISIG/IXON/ICRNL/BRKINT/OPOST, …"
    so the name stays honest. Not required by the contract.
  - DEPENDENCIES: Task 1.

Task 4: UPDATE Test 2 (src/tui/app.zig ~line 547) — idempotent: ISIG stays false
  - EXACT OLD:
        try std.testing.expectEqual(false, out.lflag.ECHO);
        try std.testing.expectEqual(@as(@TypeOf(out.cflag.CSIZE), .CS8), out.cflag.CSIZE);
  - EXACT NEW (one assertion inserted):
        try std.testing.expectEqual(false, out.lflag.ECHO);
        try std.testing.expectEqual(false, out.lflag.ISIG);
        try std.testing.expectEqual(@as(@TypeOf(out.cflag.CSIZE), .CS8), out.cflag.CSIZE);
  - DEPENDENCIES: Task 1.

Task 5: VALIDATE  (see Validation Loop)
  - RUN: zig build test -Doptimize=ReleaseFast   → expect exit 0
```

### Implementation Patterns & Key Details

```zig
// PATTERN: makeRaw groups flag clears by termios field (lflag first, then iflag, oflag,
// cflag, cc). ISIG is a lflag bit, so it goes with ICANON/ECHO:
raw.lflag.ICANON = false;
raw.lflag.ECHO = false;
raw.lflag.ISIG = false;   // ← ADD (lflag group)
raw.iflag.IXON = false;   // (iflag group starts here)

// CRITICAL: in the unit test, a zeroed termios has ISIG=false already. To PROVE makeRaw
// clears it, the INPUT must set ISIG=true:
input.lflag.ISIG = true;
// ... then assert the OUTPUT cleared it:
try std.testing.expectEqual(false, raw.lflag.ISIG);
// (Without input.ISIG=true, the assertion passes trivially — the exact blind spot that let
//  the bug ship. See GOTCHA 2.)

// CRITICAL: do NOT touch palette.zig (own raw-mode), the signal handlers (external signals),
// or input.zig (0x03⇒.quit already exists, becomes live with ISIG off).
```

### Integration Points

```yaml
TTY RAW MODE (src/tui/app.zig):
  - makeRaw now produces ISIG=false termios. Consumed by the region TUI's raw-mode entry
    (restoreRaw/run, ~app.zig:147). No signature change.
  - installSignalHandlers (SIGINT/SIGTERM/SIGQUIT): UNCHANGED — handle external signals.

DOWNSTREAM / OUT OF SCOPE:
  - P1.M1.T2.S1 (sibling): tests/region_signal_keys.sh — the python3 pty live harness that
    sends 0x1a (no suspend) + 0x03 (exit 1) against an isolated socket. NOT this task.
  - palette.zig: OWN raw-mode (palette.zig:106–109) — UNCHANGED.
  - input.zig/motion.zig/select.zig/view.zig/region.zig: UNCHANGED.
  - README.md / docs/CONFIGURATION.md: the final P1.M3 docs task — no edit here (no public
    API/config/CLI surface change).

CONFIG / DATABASE / ROUTES:
  - none.
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# The build is the compile check. Confirm the file compiles:
zig build -Doptimize=ReleaseFast 2>&1 | tail -5   # expect: clean (exit 0), installs tmux-2html
# A compile error means ISIG was mistyped or placed in the wrong termios group — re-check GOTCHA 1.

# Confirm the ISIG line is present exactly once in makeRaw:
grep -n 'lflag.ISIG' src/tui/app.zig   # expect: the makeRaw line + the 2 test lines (input + assertions)
```

### Level 2: Unit Tests (Component Validation)

```bash
# PRIMARY GATE — ReleaseFast MANDATORY (GOTCHA 3: Debug hits the R_X86_64_PC64 linker bug).
zig build test -Doptimize=ReleaseFast
# Expected: exit 0. The two makeRaw tests now assert ISIG is cleared (Test 1 with ISIG=true
# on the input; Test 2 idempotent). The change is ADDITIVE — no existing test asserts
# ISIG==true, so the full suite stays green.
#
# NOTE: plain `zig build test` (Debug) will FAIL with a linker error UNRELATED to your
# change — do not be fooled (GOTCHA 3 / PRD §15).
```

### Level 3: Integration Testing (System Validation)

```bash
# Not in scope for S1. makeRaw is a PURE termios value function — the unit tests ARE the
# proof. The LIVE pty regression (Ctrl-z no-suspend, Ctrl-c exit-1) is the SIBLING task
# P1.M1.T2.S1 (tests/region_signal_keys.sh), which depends on this S1 change.
# (You can spot-check that the region TUI still enters raw mode + restores on q, but the
#  canonical signal-key validation belongs to T2.S1.)
```

### Level 4: Creative & Domain-Specific Validation

```bash
# (Optional confidence check) Confirm the only termios-producer for the region path changed,
# and palette.zig (the OTHER raw-mode) is untouched:
grep -n 'lflag.ISIG' src/tui/app.zig     # expect: makeRaw + 2 test lines
grep -n 'lflag.ISIG' src/palette.zig     # expect: NO output (palette.zig untouched — GOTCHA 4)
# Confirm the signal handlers are unchanged (still SIGINT/SIGTERM/SIGQUIT, no SIGTSTP added):
grep -n 'installSignalHandlers\|SIGINT\|SIGTERM\|SIGQUIT\|SIGTSTP' src/tui/app.zig | head
```

## Final Validation Checklist

### Technical Validation

- [ ] `zig build -Doptimize=ReleaseFast` builds clean (Level 1).
- [ ] `zig build test -Doptimize=ReleaseFast` exits 0 (Level 2 — primary gate).

### Feature Validation

- [ ] `makeRaw` sets `raw.lflag.ISIG = false;` (right after the ECHO line).
- [ ] Doc-comment lists ISIG + the §7.1/§7.5 rationale.
- [ ] Test 1: `input.lflag.ISIG = true;` + `expectEqual(false, raw.lflag.ISIG)`.
- [ ] Test 2: `expectEqual(false, out.lflag.ISIG)` (idempotent).
- [ ] palette.zig / input.zig / region.zig / motion.zig / select.zig / view.zig UNCHANGED.

### Code Quality Validation

- [ ] ISIG added in the lflag group (not iflag); inline comment explains why.
- [ ] Test INPUT sets ISIG=true (no vacuous assertion — GOTCHA 2).
- [ ] Existing conventions honored (inline `//` comments; expectEqual style).

### Documentation & Deployment

- [ ] makeRaw doc-comment documents ISIG + rationale (Mode A — rides with the code).
- [ ] No README/CONFIGURATION.md edit here (no public API/config/CLI surface — that's P1.M3).

---

## Anti-Patterns to Avoid

- ❌ Don't put ISIG in the iflag group — it's a `lflag` bit; add it with ICANON/ECHO.
- ❌ Don't write a vacuous test — a zeroed termios already has ISIG=false, so you MUST set
  `input.lflag.ISIG = true;` or `expectEqual(false, …)` proves nothing (the round-2 blind spot).
- ❌ Don't touch palette.zig — it has its OWN raw-mode for the sync-palette OSC query; the
  PRD issues are region-TUI-only.
- ❌ Don't add a SIGTSTP handler or change installSignalHandlers — ISIG off makes Ctrl-z an
  inert byte (never a signal); the existing SIGINT/SIGTERM/SIGQUIT handlers handle EXTERNAL
  signals and stay as-is.
- ❌ Don't edit input.zig/motion.zig/select.zig/view.zig/region.zig — input.zig's
  `0x03 ⇒ .quit` already exists and becomes live once ISIG is off.
- ❌ Don't run plain `zig build test` — Debug hits the `R_X86_64_PC64` linker bug. Use
  `zig build test -Doptimize=ReleaseFast`.
- ❌ Don't add the live pty harness (region_signal_keys.sh) here — that's the sibling task
  P1.M1.T2.S1.

---

**Confidence Score: 10/10** for one-pass implementation success.

It is a single termios-flag line (`raw.lflag.ISIG = false;`) in a pure value function, with
the doc-comment and both unit tests specified byte-accurately (including the critical
`input.lflag.ISIG = true;` that prevents a vacuous assertion — the exact blind spot that let
the bug ship). The root-cause + side-effect analysis (why ISIG-off safely fixes both Issues 2
& 3 without touching palette.zig or the signal handlers) is included, and the baseline gate
(`zig build test -Doptimize=ReleaseFast`) was verified EXIT 0. Scope is cleanly bounded from
the sibling live-pty harness (T2.S1), palette.zig's separate raw-mode, and the final docs task.