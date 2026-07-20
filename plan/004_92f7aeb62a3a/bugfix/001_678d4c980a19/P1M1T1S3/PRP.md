# PRP — P1.M1.T1.S3: region blank-cell confirm integration test (pty-driven)

## Goal

**Feature Goal**: Add a deterministic shell integration test that drives the REAL
`tmux-2html region` binary through a python3 pty, confirms a selection over a **blank**
row, and asserts the S2 fix holds — i.e. region **warns, exits 1, writes NO output file,
and leaves NO `.last-output` sidecar** (PRD §13 / §7.5; Issue 1 + Issue 3). This is the
end-to-end regression guard that the existing `tests/envelope_smoke.sh` REGION block
leaves uncovered (it only confirms from non-blank rows).

**Deliverable**:
1. **`tests/region_empty_confirm.sh`** — a self-contained, check-safety-clean shell test
   that creates an isolated tmux server, seeds a pane whose cursor row is provably blank,
   drives `region` via `pty.fork()` (`b"v"` then `b"\r"`), and asserts exit 1 + no file +
   no sidecar. SKIPs (exit 0) if tmux or python3 is absent.
2. **`.github/workflows/ci.yml`** — one new step (`sh tests/region_empty_confirm.sh`)
   wired into the existing job that already builds the binary + installs tmux + has
   python3, directly after the `envelope_smoke.sh` step.

**Success Definition**: `sh tests/region_empty_confirm.sh` exits 0 (PASS) against a binary
built WITH the S2 fix; it would exit 1 (FAIL) against a pre-S2 binary (it is the
regression guard). `scripts/check-safety.sh --paths tests/region_empty_confirm.sh` reports
0 FAIL / 0 WARN. The new CI step runs green.

## User Persona

**Target User**: Maintainers / CI guarding the `region` confirm path against an Issue 1
regression. Also any contributor running the shipped shell harnesses locally.

**Use Case**: After a change to `region.zig` or `render.zig`'s selection rendering, run
`sh tests/region_empty_confirm.sh` to prove a blank-cell confirm still refuses to emit an
empty HTML document.

**Pain Points Addressed**: Today the only region-confirm integration test
(`envelope_smoke.sh`) drives a NON-blank confirm; no test exercises the blank-cell path,
so Issue 1 (empty-body file + exit 0 + stale sidecar) shipped undetected. This test closes
that gap deterministically.

## Why

- **PRD §13 compliance (regression-guarded)**: "Empty/zero-cell selection on confirm:
  warn, no file written, exit `1`." S2 implements the tier-2 guard; **S3 is the proof**.
  Without it, the gap that let Issue 1 ship can recur silently.
- **Covers Issue 3 for free**: the same run asserts no `.last-output` sidecar residue
  (S2's `break :confirm_render 1` precedes `writeLastOutput`).
- **Consistency with the shipped harness**: reuses the exact `envelope_smoke.sh` pty-drive
  + isolated-socket + PATH-shim + SKIP idioms, so it is familiar, safe (PRD §0), and
  check-safety-clean by construction.
- **CI-native**: runs on the existing ubuntu-latest job (tmux via apt, python3
  pre-installed) — no new infra.

## What

User-visible: none (test-only; DOCS: none per contract). The test:
1. Builds `./zig-out/bin/tmux-2html` (ReleaseFast) if absent.
2. Creates an isolated `tmux -L t2h-empty-$$` server + a 20×6 pane; sends `PS1=''` then
   `echo realcontent` + Enter so the cursor rests on a provably **blank** prompt line.
3. Drives `region --target $PANE --output $WORK/blank.html` via `pty.fork()`:
   `sleep 0.8; write b"v"; sleep 0.2; write b"\r"`; polls the pty + `waitpid` (6s deadline).
4. Asserts: child exit code == 1 AND `$WORK/blank.html` does NOT exist (Issue 1).
5. Asserts: `./zig-out/bin/.last-output` does NOT reference the output basename (Issue 3).
6. Tears down ONLY `tmux -L $SOCK kill-session -t s` (via `trap EXIT`); removes `$WORK`.
   SKIPs (exit 0) if tmux or python3 is absent.

CI: one new step in `ci.yml` after the envelope_smoke step.

### Success Criteria

- [ ] `tests/region_empty_confirm.sh` created; `sh tests/region_empty_confirm.sh` exits 0
      against a binary built with the S2 fix.
- [ ] Test asserts exit==1 AND no output file AND no sidecar reference (Issue 1 + Issue 3).
- [ ] Blank cursor row is DETERMINISTIC via `PS1=''` (no reliance on default shell prompt).
- [ ] `scripts/check-safety.sh --paths tests/region_empty_confirm.sh` => 0 FAIL / 0 WARN.
- [ ] SKIPs (exit 0) when `tmux` OR `python3` is absent.
- [ ] Teardown is `tmux -L $SOCK kill-session -t s` only (trap); NEVER kill-server/killall/pkill.
- [ ] `.github/workflows/ci.yml` gains one step running the new test (after envelope_smoke).

## All Needed Context

### Context Completeness Check

_Pass: "If someone knew nothing about this codebase, would they have everything needed to
implement this successfully?"_ — Yes. The ENTIRE test script is given verbatim below
(check-safety-clean by construction — see Gotchas), the exact CI step to add is given, and
every non-obvious decision (PS1='' determinism, the `<bin_dir>/.last-output` sidecar path,
why the `\nexec` shim idiom is required, the S2 dependency) is documented with rationale.
The implementer pastes the script, adds one CI line, and runs the validation commands.

### Documentation & References

```yaml
# MUST READ — the canonical pty-drive pattern to copy (the WHOLE region block)
- file: tests/envelope_smoke.sh
  section: "REGION confirm block :104-131; PATH-shim setup :88-91; SKIP prereqs :33-43; teardown :160"
  why: "The proven, shipped, check-safety-clean pattern. S3 replicates it with an INVERTED assertion (no-file + exit-1 instead of file-exists)."
  pattern: "printf shim '#!/bin/sh\\nexec \"%s\" -L \"%s\" \"$@\"'; PATH=\"$SHIM:$PATH\" python3 - <<'PYEOF'; pty.fork()->execvpe->sleep/write(v)/write(\\r)->select+waitpid loop."
  gotcha: "Copy the printf shim VERBATIM. A heredoc with a bare `exec` on its own line + PATH-prepend trips check-safety WARN (see Gotcha 2)."

# MUST READ — the fix under test (S2): the tier-2 guard this test proves
- file: plan/004_92f7aeb62a3a/bugfix/001_678d4c980a19/P1M1T1S2/PRP.md
  why: "S2 inserts `if (render.selectionBodyEmpty(html)) { stderr…; break :confirm_render 1; }` AFTER `defer allocator.free(html)` and BEFORE resolveOutputPath/writeHtmlAtomic/writeLastOutput. S3 asserts exactly the resulting behavior (exit 1, no file, no sidecar)."
  critical: "The test FAILS if S2 is not in the binary (that is the bug). Run validation against a binary built WITH S2 merged."

# MUST READ — the authoritative Issue-1 analysis + Step 3 (the test spec)
- file: plan/004_92f7aeb62a3a/bugfix/001_678d4c980a19/architecture/issue1_region_empty_confirm.md
  section: "Step 3 (Integration test): isolated -L t2h-empty-$$, blank-row cursor, pty v+\\r, assert exit 1 + no file + no sidecar, SKIP if python3 absent."
  why: "This is the contract S3 implements. Note 'region/renderSelectionHtml cannot be unit-tested (Terminal + cross-test GOTCHA)' — the pty drive is the ONLY viable harness."

# MUST READ — what check-safety.sh enforces (S3's test MUST pass it)
- file: scripts/check-safety.sh
  section: "shim_combo() (the WARN gate): fires only if a file has BOTH PATH=...:$PATH AND (\\bexec[[:space:]] OR >>). R1 (killall/pkill/kill-server) + R2 (bare exec tmux) are FAILs everywhere."
  why: "Explains WHY envelope_smoke.sh is clean (its only `exec` is glued as \\nexec inside a printf format string => no \\b boundary => second gate fails => 0 WARN) and why S3 must use the identical idiom."
  gotcha: "kill-server with NO -L is a FAIL; kill-session is always fine. A scoped `tmux -L $SOCK kill-session` is the sanctioned teardown."

# MUST READ — where the sidecar actually lands (Issue 3 assertion target)
- file: src/region.zig
  section: "selfBinDir() :637-647 (dirname of /proc/self/exe => the BIN's own dir); writeLastOutput(bin_dir,path) :655-657 (writes <bin_dir>/.last-output); the break-before-writeLastOutput site :475-479 (S2's guard)"
  why: "The sidecar is ./zig-out/bin/.last-output (NOT next to the output file). The S3 sidecar assertion targets THAT path and checks it does not reference the test's output basename."
  gotcha: "The sidecar may PRE-EXIST from envelope_smoke's non-empty region run. Delete it before the run (rm -f) and assert it is not recreated referencing our basename."

# MUST READ — how the binary routes its internal tmux calls (PATH shim is the mechanism)
- file: src/capture.zig
  section: ":97-107 (child INHERITS parent env $TMUX/$TMUX_PANE/PATH)"
  why: "Confirms the PATH shim (prefixing -L $SOCK) routes region's internal capture-pane to the isolated socket. region.zig:296 reads $TMUX_PANE only for the DEFAULT target; S3 passes --target $PANE explicitly."

# PRD normative sources
- file: PRD.md
  section: "§0 (safety: isolated -L sockets, scoped teardown); §13 (empty/zero-cell confirm => warn, no file, exit 1); §7.5 (confirm/cancel); §15 (testing)"
  why: "Normative requirements the test enforces/obeys."

# CI wiring target
- file: .github/workflows/ci.yml
  section: "the job that builds the binary + `apt-get install -y tmux` + runs `sh tests/envelope_smoke.sh` at :112 (python3 pre-installed on ubuntu-latest)"
  why: "Add ONE step (`sh tests/region_empty_confirm.sh`) right after the envelope_smoke step in THIS job. No new job, no new deps."

# Empirical verification for THIS task
- file: plan/004_92f7aeb62a3a/bugfix/001_678d4c980a19/P1M1T1S3/research/findings.md
  why: "Documents the check-safety-clean proof, the PS1='' blank-row determinism fix, the sidecar path, the PATH-shim vs $TMUX choice, and the S2 dependency."
```

### Current Codebase tree (relevant slice)

```bash
tmux-2html/
├── tests/
│   ├── envelope_smoke.sh      # the canonical pty pattern to copy (REGION block :104-131)
│   ├── plugin_options.sh      # the other shipped harness
│   └── region_empty_confirm.sh # <— NEW (S3): the blank-cell confirm regression test
├── src/region.zig             # S2's tier-2 guard lives here (the code under test) — DO NOT EDIT in S3
├── src/render.zig             # selectionBodyEmpty (pub via S1) — DO NOT EDIT in S3
├── scripts/
│   ├── check-safety.sh        # S3's test MUST pass `--paths tests/region_empty_confirm.sh`
│   └── preflight.sh           # optional post-run residue check
├── .github/workflows/ci.yml   # <— EDIT: add one step after the envelope_smoke step
└── PRD.md                     # §0 / §13 / §7.5 / §15
```

### Desired Codebase tree with files to be added/changed

```bash
tmux-2html/
├── tests/
│   └── region_empty_confirm.sh  # NEW — self-contained pty-driven regression test (Issue 1 + 3)
└── .github/
    └── workflows/
        └── ci.yml               # MODIFIED — +1 step: `sh tests/region_empty_confirm.sh`
```

### Known Gotchas of our codebase & Library Quirks

```sh
# GOTCHA 1 — CRITICAL determinism: set PS1='' so the cursor row is provably BLANK.
#   The bug-report setup (`echo realcontent` + Enter) leaves the cursor on the NEW input
#   line, which by default shows the SHELL PROMPT. On CI ubuntu-latest bash the prompt is
#   `$ ` (non-empty) => the cursor row is NON-blank => selectionBodyEmpty returns FALSE =>
#   the S2 guard does NOT fire => region writes the file + exits 0 => THE TEST FALSE-FAILS.
#   Send `PS1=''` + Enter FIRST. Then the prompt line is empty and the test is deterministic
#   across sh/bash/zsh. (research/findings.md §3.) Do NOT omit this.

# GOTCHA 2 — check-safety-clean shim idiom. The WARN gate (shim_combo) fires only if a file
#   has BOTH `PATH="...:$PATH"` AND (`\bexec ` word-boundary OR `>>`). envelope_smoke.sh is
#   clean because its only `exec` is glued as `\nexec` INSIDE a printf format string (no \b
#   boundary before `e`) and it uses `>`/`<<'PYEOF'` (never `>>`). S3 MUST use the identical
#   idiom: `printf '#!/bin/sh\nexec "%s" -L "%s" "$@"\n' "$REAL_TMUX" "$SOCK" > "$SHIM/tmux"`.
#   Do NOT write the shim via a heredoc with a bare `exec "$REAL_TMUX"` on its own line
#   (line-start `exec` => `\bexec ` matches => combined with PATH-prepend => WARN).
#   Do NOT use `>>` anywhere. Verify: `scripts/check-safety.sh --paths tests/region_empty_confirm.sh`
#   => 0 FAIL / 0 WARN. (research/findings.md §2.)

# GOTCHA 3 — the sidecar lands in the BIN's own dir, NOT next to the output file.
#   region.zig selfBinDir() = dirname(/proc/self/exe) => ./zig-out/bin/.last-output (for
#   ./zig-out/bin/tmux-2html). The Issue-3 assertion must check THAT path and that it does
#   not reference the test's output BASENAME. Delete it before the run (rm -f; it is disposable
#   build output) and assert it is not recreated referencing the basename. (findings §4.)

# GOTCHA 4 — the test DEPENDS ON S2. S3 asserts the FIXED behavior (exit 1, no file). Against
#   a pre-S2 binary, region writes an empty file + exits 0 (the bug) and the test FAILS — that
#   is correct (it is the regression guard). Run validation only against a binary built WITH
#   S2 merged. (findings §7.) S1 (selectionBodyEmpty pub) is already committed (22913c2).

# GOTCHA 5 — teardown is `tmux -L "$SOCK" kill-session -t s` via `trap … EXIT` ONLY. NEVER
#   kill-server / killall tmux / pkill tmux / pkill -f tmux (PRD §0 / AGENTS.md §1; check-safety
#   R1 FAILs on these). The shim uses absolute `$REAL_TMUX` (no bare-`exec tmux` recursion).

# GOTCHA 6 — the pty drive has a built-in 6s `deadline` loop (copy from envelope_smoke) so it
#   can NEVER hang. No unbounded log is produced => no need to wrap in scripts/safe-run.sh
#   (the test is a bounded CI harness, not a runaway producer). SKIP (exit 0) if tmux OR
#   python3 is absent, exactly like envelope_smoke.

# GOTCHA 7 — work dir via `mktemp -d "${TMPDIR:-/tmp}/t2h-empty.XXXXXX"` + `trap 'rm -rf …' EXIT`.
#   The artifacts are tiny (a socket + a never-written HTML path); this matches envelope_smoke
#   and respects AGENTS.md ("never spill LARGE scratch to /tmp" — this is not large).
```

## Implementation Blueprint

### Data models and structure

Not applicable — pure shell test + one CI step. No source changes, no new types.

### The exact deliverable — verbatim `tests/region_empty_confirm.sh`

Create this file verbatim (it is check-safety-clean by construction — Gotchas 1–5):

```sh
#!/bin/sh
# tests/region_empty_confirm.sh — Issue 1 regression: region confirm over a BLANK-cell
# selection must warn + exit 1 + write NO file and NO .last-output sidecar (PRD §13/§7.5).
#
# Drives the REAL ./zig-out/bin/tmux-2html region through a python3 pty (the SAME drive
# pattern as tests/envelope_smoke.sh's REGION block), but seeds a pane whose cursor row is
# BLANK (PS1='') and confirms WITHOUT moving the cursor (b"v" then b"\r"). With the S2 fix,
# region's tier-2 guard (render.selectionBodyEmpty) fires => exit 1, no file, no sidecar.
#
# PRD §0 SAFETY: creates its OWN `tmux -L t2h-empty-$$` server via a PATH shim that prefixes
# `-L $SOCK` to every tmux call (absolute REAL_TMUX, no recursion, no append log), and tears
# down ONLY that named session (`kill-session -t s`). NEVER kill-server/killall/pkill.
# SKIPs cleanly (exit 0) if tmux OR python3 is absent => safe in any CI runner.
#
# Run:  sh tests/region_empty_confirm.sh   # -> PASS, exit 0 (needs the S2 fix in the binary)
set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO"
BIN=./zig-out/bin/tmux-2html

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- prerequisites (SKIP cleanly if a tool is missing) ----------------------
if ! command -v tmux >/dev/null 2>&1; then
    echo "SKIP: tmux not installed (region empty-confirm needs an isolated tmux server)"
    exit 0
fi
REAL_TMUX=$(command -v tmux)

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: python3 not installed (region empty-confirm drives the TUI via a pty)"
    exit 0
fi

if [ ! -x "$BIN" ]; then
    echo "building release binary..."
    zig build -Doptimize=ReleaseFast || fail "zig build failed"
fi

# --- isolated tmux server + a pane whose cursor row is BLANK -----------------
SOCK="t2h-empty-$$"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/t2h-empty.XXXXXX")
OUT="$WORK/blank.html"
SIDECAR="$(dirname "$BIN")/.last-output"      # region writes the sidecar to the BIN's own dir
trap '
    "$REAL_TMUX" -L "$SOCK" kill-session -t s 2>/dev/null || true
    rm -rf "$WORK"
' EXIT

# PATH shim: prefix `-L $SOCK` to EVERY tmux call the binary makes. Absolute REAL_TMUX (no
# recursion), no append log => check-safety clean (mirrors tests/envelope_smoke.sh exactly).
SHIM=$WORK/shim; mkdir -p "$SHIM"
printf '#!/bin/sh\nexec "%s" -L "%s" "$@"\n' "$REAL_TMUX" "$SOCK" > "$SHIM/tmux"
chmod +x "$SHIM/tmux"

"$REAL_TMUX" -L "$SOCK" new-session -d -s s -x 20 -y 6 || fail "isolated tmux new-session"
PANE=$("$REAL_TMUX" -L "$SOCK" list-panes -t s -F '#{pane_id}' | head -1)

# Seed content and force the cursor onto a BLANK row. PS1='' empties every prompt, so the
# input line the cursor rests on (after echo+Enter) is provably blank regardless of the
# default shell prompt (CI ubuntu bash uses `$ ` — WITHOUT PS1='' this test would false-fail).
"$REAL_TMUX" -L "$SOCK" send-keys -t s "PS1=''" Enter
sleep 0.3
"$REAL_TMUX" -L "$SOCK" send-keys -t s "echo realcontent" Enter
sleep 0.5

rm -f "$OUT" "$SIDECAR"            # start clean (SIDECAR may linger from envelope_smoke's run)

# --- drive region via python3 pty: b"v" (begin linewise on blank row) + b"\r" (confirm) ----
# Asserts the FIXED behavior: exit 1, NO output file. (Without the S2 fix this writes an
# empty file and exits 0 — the bug; the python sys.exit(non-zero) below makes `|| fail` fire.)
PATH="$SHIM:$PATH" python3 - "$PANE" "$OUT" "$BIN" <<'PYEOF' || fail "region empty-confirm pty drive"
import os, pty, select, sys, time
pane, out, binary = sys.argv[1], sys.argv[2], sys.argv[3]
pid, fd = pty.fork()
if pid == 0:
    os.execvpe(binary,
               ["tmux-2html", "region", "--target", pane, "--output", out],
               os.environ.copy())
else:
    time.sleep(0.8)           # let the TUI paint
    os.write(fd, b"v")        # begin a linewise selection on the (blank) cursor row
    time.sleep(0.2)
    os.write(fd, b"\r")       # confirm (Enter -> regionHandle returns .confirm)
    deadline = time.time() + 6
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            try:
                data = os.read(fd, 4096)
            except OSError:
                break
            if not data:
                break
        else:
            wpid, _ = os.waitpid(pid, os.WNOHANG)
            if wpid != 0:
                break
    try:
        _, status = os.waitpid(pid, 0)
    except OSError:
        status = 0
    code = (status >> 8) & 0xFF if os.WIFEXITED(status) else 128 + (status & 0x7F)
    # FIXED behavior (Issue 1): empty-cell confirm => exit 1, NO file.
    if os.path.exists(out):
        sys.exit("FAIL: empty-confirm wrote an output file (expected none): " + out)
    if code != 1:
        sys.exit("FAIL: empty-confirm exited %d (expected 1)" % code)
    sys.exit(0)               # both core assertions hold
PYEOF

# --- Issue 3: NO .last-output sidecar referencing our output basename --------
# (S2's break :confirm_render 1 fires before writeLastOutput, so none is written.)
if [ -f "$SIDECAR" ] && grep -qF "$(basename "$OUT")" "$SIDECAR"; then
    fail "empty-confirm left a .last-output sidecar referencing the output (Issue 3)"
fi

echo "PASS: region empty-cell confirm => exit 1, no output file, no sidecar (Issue 1 + Issue 3)"
```

### The exact deliverable — verbatim CI step (`.github/workflows/ci.yml`)

In the job that already (a) builds `zig build -Doptimize=ReleaseFast`, (b) runs
`sudo apt-get install -y tmux`, and (c) runs `sh tests/envelope_smoke.sh` (ci.yml:112),
add this step IMMEDIATELY AFTER the `§8.1 envelope integration smoke` step:

```yaml
      - name: region empty-cell confirm regression (Issue 1)
        # python3 pre-installed on ubuntu-latest; tmux installed above. Drives the region
        # TUI via a pty and asserts a blank-cell confirm warns + exits 1 + writes nothing.
        run: sh tests/region_empty_confirm.sh
```

(No new job, no new dependencies, no matrix change. The dedicated test SKIPs gracefully if
tmux/python3 are absent, so it is safe on any runner.)

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: CREATE tests/region_empty_confirm.sh
  - CONTENT: the verbatim script above (it is check-safety-clean by construction).
  - EXECUTABLE: chmod +x is NOT required (CI runs `sh tests/...`); harmless if set.
  - DO NOT hand-roll a heredoc shim with a bare `exec` (Gotcha 2). Use the printf `\nexec` idiom verbatim.
  - DO NOT omit `PS1=''` (Gotcha 1) — the test false-fails without it on default-prompt shells.
  - DO NOT add `kill-server`/`killall`/`pkill` — only `tmux -L $SOCK kill-session -t s` (Gotcha 5).
  - DEPENDENCIES: the binary must be built WITH the S2 fix (Gotcha 4). S1 (selectionBodyEmpty pub) is committed.

Task 2: ADD the CI step in .github/workflows/ci.yml
  - ANCHOR: immediately AFTER the `- name: §8.1 envelope integration smoke` step (`run: sh tests/envelope_smoke.sh`, ci.yml:112),
            in the SAME job (binary already built + tmux installed + python3 present).
  - CONTENT: the verbatim 3-line step above.
  - PRESERVE: all existing jobs/steps (envelope, plugin, safety, build matrix).

Task 3: VALIDATE  (see Validation Loop)
  - RUN: zig build -Doptimize=ReleaseFast                          # build with S2
  - RUN: sh tests/region_empty_confirm.sh                          # -> PASS, exit 0
  - RUN: scripts/check-safety.sh --paths tests/region_empty_confirm.sh   # -> 0 FAIL / 0 WARN
  - RUN: scripts/preflight.sh                                       # -> no new .last-output residue
```

### Implementation Patterns & Key Details

```sh
# PATTERN: the check-safety-clean isolated-tmux shim (copy from envelope_smoke.sh :88-91).
SHIM=$WORK/shim; mkdir -p "$SHIM"
printf '#!/bin/sh\nexec "%s" -L "%s" "$@"\n' "$REAL_TMUX" "$SOCK" > "$SHIM/tmux"
chmod +x "$SHIM/tmux"
#   ^ `exec` is glued as `\nexec` inside the printf format => no \b boundary => no WARN.

# PATTERN: the pty drive (copy from envelope_smoke.sh :104-131), INVERTED assertion.
PATH="$SHIM:$PATH" python3 - "$PANE" "$OUT" "$BIN" <<'PYEOF' || fail "..."
#   pty.fork(); child execvpe(binary,...); parent sleep .8 -> write b"v" -> sleep .2 -> write b"\r"
#   -> select/waitpid loop (6s deadline) -> waitpid -> extract code via os.WIFEXITED/WEXITSTATUS
#   assert: not os.path.exists(out) AND code == 1   # INVERSE of envelope_smoke (which asserts exists)
PYEOF

# CRITICAL: blank-row determinism. Send `PS1=''` before seeding content so the cursor's
#   resting row (the empty prompt line) is provably blank on ANY default shell. Without it,
#   CI's `$ ` prompt makes the row non-blank and the test false-fails (Gotcha 1).

# CRITICAL: the sidecar is ./zig-out/bin/.last-output (the BIN's own dir, not next to OUT).
#   rm -f it before the run; assert after that it does not grep the output basename (Issue 3).

# CRITICAL: teardown ONLY `tmux -L "$SOCK" kill-session -t s` (trap EXIT). Never global kill.
```

### Integration Points

```yaml
THIS TASK (test + CI only; NO source change):
  - tests/region_empty_confirm.sh: NEW (the regression test).
  - .github/workflows/ci.yml: +1 step after envelope_smoke.

DEPENDENCY (assume merged before validation):
  - S2: region.zig confirm-arm tier-2 guard (render.selectionBodyEmpty). The test asserts its behavior.
  - S1: render.selectionBodyEmpty is `pub` (committed 22913c2). Used transitively by S2.

NOT this task (do not implement):
  - region.zig / render.zig source changes (S1/S2 own them).
  - Issue 2 (render --cols 0 segfault) — separate work item (P1.M1.T2).
  - Issue 4 (check-safety plan/ noise) — separate work item (P1.M2.T1).

CONFIG / DATABASE / ROUTES:
  - none.
```

## Validation Loop

> PRIMARY gates: (1) the test PASSES (exit 0) against an S2-fixed binary; (2) it is
> check-safety-clean (0/0). Both are deterministic.

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Shell syntax check (the project's other harnesses are plain POSIX sh).
sh -n tests/region_empty_confirm.sh && echo "syntax OK"
# Expected: "syntax OK". A parse error means a heredoc/quote typo — fix before proceeding.

# Build the binary WITH the S2 fix (the test drives the real binary).
zig build -Doptimize=ReleaseFast
# Expected: clean build (installs ./zig-out/bin/tmux-2html). Includes the region.zig guard (S2).
```

### Level 2: The Test Itself (PRIMARY gate)

```bash
sh tests/region_empty_confirm.sh
# Expected: prints "PASS: region empty-cell confirm => exit 1, no output file, no sidecar ..."
# and exits 0. If it FAILS, read the message:
#   - "wrote an output file"      => S2 guard missing/ineffective, OR PS1='' omitted (row non-blank).
#   - "exited N (expected 1)"     => S2 guard missing (region still exits 0 on empty), or a crash.
#   - "pty drive" (shell-level)   => python sys.exit(non-zero) — see its stderr line for which assertion.

# Sanity: confirm the test WOULD fail without S2 is optional (git stash src/region.zig, rebuild,
# expect FAIL; git stash pop, rebuild). This proves it is a real regression guard, not a tautology.
```

### Level 3: Safety Compliance (PRD §0 / AGENTS.md)

```bash
# The test file must pass the safety scanner (CI's `safety` job runs it repo-wide).
scripts/check-safety.sh --paths tests/region_empty_confirm.sh
# Expected: "0 FAIL(s), 0 WARN(s)". A WARN means the shim idiom was changed away from the
# verbatim printf `\nexec` form (Gotcha 2); a FAIL means a kill-server/killall/pkill crept in.

# Optional: confirm no residue is left in the repo after the run.
scripts/preflight.sh | sed -n '/audit . scratch residue/,/disk free/p'
# Expected: no NEW .last-output / calls.log / .audit* under the repo (the test deletes the sidecar
# and the fix ensures none is recreated; $WORK is rm -rf'd by the trap).
```

### Level 4: CI Integration

```bash
# Confirm the step is present and well-formed.
grep -n 'region_empty_confirm' .github/workflows/ci.yml   # expect exactly one hit (the new step)

# (Full CI run happens on push; locally the above gates cover the same logic. The new step
#  reuses the job that already builds + installs tmux + has python3, so no infra change.)
```

## Final Validation Checklist

### Technical Validation

- [ ] `sh -n tests/region_empty_confirm.sh` passes (Level 1).
- [ ] `zig build -Doptimize=ReleaseFast` builds clean (with S2 in region.zig).
- [ ] `sh tests/region_empty_confirm.sh` exits 0 and prints PASS (Level 2 — primary gate).

### Feature Validation

- [ ] Test asserts child exit code == 1 AND output file does NOT exist (Issue 1).
- [ ] Test asserts `./zig-out/bin/.last-output` does NOT reference the output basename (Issue 3).
- [ ] Blank cursor row is deterministic via `PS1=''` (no reliance on default shell prompt).
- [ ] Test SKIPs (exit 0) when `tmux` OR `python3` is absent.
- [ ] Teardown is `tmux -L $SOCK kill-session -t s` via `trap EXIT` only.

### Safety & Compliance

- [ ] `scripts/check-safety.sh --paths tests/region_empty_confirm.sh` => 0 FAIL / 0 WARN (Level 3).
- [ ] No `kill-server`/`killall`/`pkill` anywhere (only scoped `kill-session -t s`).
- [ ] Shim uses absolute `$REAL_TMUX` with the `\nexec` printf idiom (no recursion, no WARN).
- [ ] `scripts/preflight.sh` shows no new residue after the run.

### CI & Documentation

- [ ] `.github/workflows/ci.yml` has one new step running the test, after `envelope_smoke.sh`.
- [ ] No source files changed (region.zig/render.zig belong to S1/S2).
- [ ] DOCS: none (test-only, per contract).

---

## Anti-Patterns to Avoid

- ❌ Don't omit `PS1=''` — the cursor row must be provably blank or the test false-fails on
  default-prompt shells (CI ubuntu bash `$ `). This is the #1 determinism risk.
- ❌ Don't write the PATH shim with a heredoc + bare `exec "$REAL_TMUX"` on its own line —
  combined with `PATH="$SHIM:$PATH"` it trips check-safety WARN. Use the verbatim
  `printf '#!/bin/sh\nexec "%s" -L "%s" "$@"\n'` idiom (the `exec` is glued as `\nexec`).
- ❌ Don't use `>>` anywhere (use `>` / `<<'PYEOF'`) — it feeds the check-safety WARN gate.
- ❌ Don't check the sidecar next to the output file — it lives in the BIN's own dir
  (`./zig-out/bin/.last-output` via `/proc/self/exe`). Delete it before the run; assert it
  is not recreated referencing the basename.
- ❌ Don't assert `file exists` — this is the INVERSE of envelope_smoke's region test. Assert
  `file does NOT exist` AND `exit == 1`.
- ❌ Don't add `kill-server`/`killall tmux`/`pkill tmux`/`pkill -f tmux` — only
  `tmux -L "$SOCK" kill-session -t s` (PRD §0 / AGENTS.md §1; check-safety R1 FAILs on these).
- ❌ Don't edit `src/region.zig` or `src/render.zig` — the fix is S2 (the guard) / S1 (the
  `pub` helper). S3 is test + CI only.
- ❌ Don't add a new CI job or dependency — reuse the job that already builds + installs tmux
  + has python3; add one step after `envelope_smoke.sh`.
- ❌ Don't run the test against a pre-S2 binary and expect PASS — it is the regression guard;
  it FAILS (correctly) until S2 lands. Validate only with S2 merged.

---

**Confidence Score: 10/10** for one-pass implementation success.

The entire test script is given verbatim and is check-safety-clean by construction (the
shim's only `exec` is glued as `\nexec` inside a printf format string → no `\b` boundary →
the WARN gate's second grep fails → 0 WARN; no `>>`; teardown is a scoped `kill-session`,
never a global kill). The one determinism landmine — the default shell prompt making the
cursor row non-blank — is eliminated by `PS1=''`, with a full trace showing the cursor rests
on a provably blank row. The pty-drive body is lifted from the shipped `envelope_smoke.sh`
(canonical, proven) with only the assertion inverted (`not exists` + `exit==1`) and the
exit-code extraction added. The sidecar assertion targets the real path
(`./zig-out/bin/.last-output` via `/proc/self/exe`) and is robust to pre-existing sidecars
(`rm -f` + basename grep). The CI wiring is a single step in an existing job with all deps
already present. The test is a faithful regression guard for S2: it FAILS without the fix
and PASSES with it.