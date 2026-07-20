# PRP — P1.M1.T2.S1: `tests/region_signal_keys.sh` (python3 pty: Ctrl-z no-suspend, Ctrl-c exit-1)

## Goal

**Feature Goal**: Ship the live-pty regression harness that proves the ISIG fix (P1.M1.T1.S1)
works end-to-end in the region TUI: **Ctrl-z (0x1a) does NOT suspend the process** (ISIG off ⇒
inert byte ⇒ the TUI keeps running and repainting) and **Ctrl-c (0x03) exits 1, not 130** (the
0x03 byte reaches `input.zig` ⇒ `.quit`, instead of being intercepted by the kernel as SIGINT).
This is the integration confirmation of PRD Issues 2 & 3 (PRD §7.1 "always restore" / §7.5
cancel contract).

**Deliverable**: ONE new file, **`tests/region_signal_keys.sh`** — a self-contained PASS/exit-0
harness that mirrors the canonical `tests/region_empty_confirm.sh` safety shell EXACTLY (set -u,
cd repo, SKIP exit 0 if tmux/python3 absent, REAL_TMUX, build-if-missing, isolated `-L t2h-sig-$$`
socket, real-disk `mktemp -d`, absolute-exec PATH shim, trap `kill-session -t s` + rm, python3
pty drive with `drain()` + bounded-wait + SIGKILL, `os.waitstatus_to_exitcode`). It runs THREE
pty drives: (a) Ctrl-z then `k` then `q`; (b) Ctrl-c; (c) `q` comparison.

**Success Definition** (VERIFIED against the fixed repo binary + a throwaway buggy build):
- `sh tests/region_signal_keys.sh` → **PASS**, exit 0 against the ISIG-fixed binary.
- Ctrl-z path: process NOT stopped, status-line `row:` CHANGED after `k` (TUI kept repainting),
  `q` exits 1, restore sequence emitted.
- Ctrl-c path: exit code **1** (NOT 130); no `--output` file; no `.last-output` sidecar.
- `q` path: exit 1.
- **Ctrl-c is a proven regression detector**: against a buggy build (ISIG reverted) Ctrl-c exits
  **130** ⇒ the `code == 1` assertion FAILS (catches the bug).
- `sh scripts/check-safety.sh --paths tests/region_signal_keys.sh` → 0 FAIL / 0 WARN; the 4
  shipped harnesses + `zig build test` stay green.

## User Persona

**Target User**: The maintainer / CI running the region-TUI regression suite after any change to
`tui/app.zig` (raw mode / signal handling) or `input.zig` (byte classification).

**Use Case**: `sh tests/region_signal_keys.sh` proves a user pressing Ctrl-z in the region
overlay won't freeze the popup (terminal left unrestored) and Ctrl-c cancels to exit 1 (matching
`q`/`Esc`, not a 130 signal-death).

**Pain Points Addressed**: Without this harness, the ISIG-left-on gap (Issues 2 & 3) shipped
unnoticed — the makeRaw unit test asserts the flags it *sets*, not the ISIG it leaves enabled,
and `input.zig`'s `0x03 ⇒ .quit` looks correct in isolation. Only a live pty drive reveals that
ISIG intercepts the byte first. This harness is that drive.

## Why

- **Closes the round-2 blind spot (PRD §h2.4)**: "the tty-signal control keys (Ctrl-z/Ctrl-c)
  are never driven against the real TUI, so the ISIG-left-on gap went unnoticed." This harness
  drives exactly those keys.
- **Integration confirmation of the T1.S1 fix**: T1.S1's unit test (`input.lflag.ISIG = true` +
  `expectEqual(false, raw.lflag.ISIG)`) is the *primary* detector; this harness is the *live*
  end-to-end proof that the flag actually changes behavior in a real pty (Ctrl-c byte reaches
  `input.zig`, Ctrl-z doesn't stop the process).
- **Canonical + safe**: mirrors `region_empty_confirm.sh` exactly (the approved pattern), so it
  is check-safety-clean, CI-safe (SKIPs without tmux/python3), bounded (SIGKILL on timeout), and
  PRD §0-honoring (isolated socket, named-session teardown only).

## What

One new shell harness. Three python pty drives inside one heredoc, each a fresh `pty.fork()`:

1. **(a) Ctrl-z (0x1a)**: drain initial paint → capture `row:` → send `0x1a` → drain → assert
   `waitpid(WNOHANG|WUNTRACED)` shows the process STILL RUNNING (not stopped) → send `k` →
   drain → assert `row:` CHANGED (cursor moved ⇒ TUI alive) → send `q` → assert exit 1 +
   restore sequence present.
2. **(b) Ctrl-c (0x03)**: drain → send `0x03` → assert exit code == 1 (NOT 130) → assert no
   `--output` file.
3. **(c) q**: drain → send `q` → assert exit 1.

Then a shell check that no `.last-output` sidecar references the output (cancel ⇒ no output).

### Success Criteria

- [ ] `tests/region_signal_keys.sh` created; `sh tests/region_signal_keys.sh` → PASS, exit 0.
- [ ] (a) Ctrl-z: not-stopped (WUNTRACED) + `row:` changed after `k` + `q` exit 1 + restore seq.
- [ ] (b) Ctrl-c: exit 1 (NOT 130) + no output file.
- [ ] (c) q: exit 1.
- [ ] No `.last-output` sidecar references the output after (b)/(c).
- [ ] `check-safety.sh --paths tests/region_signal_keys.sh` → 0 FAIL / 0 WARN.
- [ ] The 4 shipped harnesses + `zig build test -Doptimize=ReleaseFast` stay green.

## All Needed Context

### Context Completeness Check

_Pass: "If someone knew nothing about this codebase, would they have everything needed to
implement this successfully?"_ — Yes. The entire harness file is given verbatim below (it IS the
deliverable), mirroring the approved `region_empty_confirm.sh` safety shell. The one subtle
correction (use `k` not `j` — the cursor starts on the bottom row so `j` is clamped) is verified
(`row:` 17→16) and documented. The Ctrl-c FAIL-before/PASS-after is proven empirically (buggy
130 / fixed 1). The check-safety R3 gotcha (`os.waitstatus_to_exitcode`, not `>>`) is baked in.

### Documentation & References

```yaml
# MUST READ FIRST — the canonical harness pattern + the waitstatus_to_exitcode (not >>) gotcha
- file: plan/004_92f7aeb62a3a/bugfix/002_b76ad57f9c71/architecture/testing_safety.md
  section: "Canonical integration-harness pattern (11 steps); SGR/pty-drive conventions; os.waitstatus_to_exitcode"
  why: "Every new tests/ harness MUST follow this exact shape. The PATH shim is absolute-exec (no recursion, no log => check-safety clean). waitstatus_to_exitcode avoids the >> token that trips R3."
  critical: "The drain() helper is NOT optional — bare sleep deadlocks the TUI's paint writes (envelope_smoke.sh hung CI for hours before the drain fix)."

# MUST READ — what the harness verifies (the ISIG fix behavior table)
- file: plan/004_92f7aeb62a3a/bugfix/002_b76ad57f9c71/architecture/isig_fix_design.md
  section: "Root-cause table (Ctrl-c/z/\\ with ISIG on vs off); §Integration regression harness (this task's spec)"
  why: "Defines exactly what (a)/(b)/(c) must assert. Ctrl-z inert => TUI alive; Ctrl-c byte => exit 1 (not 130)."

# MUST MIRROR — the canonical harness (copy its safety shell verbatim)
- file: tests/region_empty_confirm.sh
  why: "THE template. Copy its set -u / cd / SKIP / REAL_TMUX / build / SOCK / WORK / SHIM / trap / PATH-shim / drain() / waitstatus_to_exitcode / bounded-wait+SIGKILL structure. Only the python drive body + assertions differ."
  pattern: "PATH shim: printf '#!/bin/sh\\nexec \"%s\" -L \"%s\" \"$@\"\\n' \"$REAL_TMUX\" \"$SOCK\" > \"$SHIM/tmux\". Wrap: PATH=\"$SHIM:$PATH\" python3 - \"$PANE\" … <<'PYEOF' || fail \"…\"."

# INPUT CONTRACT — the fix this harness consumes (treat as contract; assume it is in the binary)
- file: plan/004_92f7aeb62a3a/bugfix/002_b76ad57f9c71/P1M1T1S1/PRP.md
  why: "T1.M1.T1.S1 adds raw.lflag.ISIG = false; to app.makeRaw (app.zig:100). This harness proves it live. T1.S1 touches src/tui/app.zig ONLY — no overlap with this new tests/ file."
  gotcha: "If the binary is NOT yet ISIG-fixed, this harness FAILS on Ctrl-c (exit 130) and possibly Ctrl-z (suspend) — which is the point (it detects the missing fix)."

# CONTRACT SOURCE — the issue reports
- file: plan/004_92f7aeb62a3a/bugfix/002_b76ad57f9c71/prd_snapshot.md
  section: "Issue 2 (Ctrl-z freezes popup) + Issue 3 (Ctrl-c exit 130≠1)"
  why: "The repros + the shared ISIG root cause + PRD §7.1/§7.5 references."

# Empirical verification for THIS task
- file: plan/004_92f7aeb62a3a/bugfix/002_b76ad57f9c71/P1M1T2S1/research/findings.md
  why: "PASS-after (fixed binary: Ctrl-z inert row 17->16, Ctrl-c exit 1) + FAIL-before (buggy build: Ctrl-c exit 130) + the k-not-j gotcha proof + the WUNTRACED detector."
```

### Current Codebase tree (relevant slice)

```bash
tmux-2html/
├── tests/
│   ├── region_empty_confirm.sh   # THE template to mirror (read it; do not edit)
│   ├── envelope_smoke.sh         # the drain() proven pattern (read; do not edit)
│   ├── plugin_options.sh         # shipped harness (must stay green; do not edit)
│   ├── zero_dimension_reject.sh  # shipped harness (must stay green; do not edit)
│   └── region_signal_keys.sh     # <— CREATE (this task)
├── src/tui/app.zig               # ISIG fix (P1.M1.T1.S1) — INPUT, do not edit
└── scripts/check-safety.sh       # run-only gate (R3: PATH-shim + >> combo); do not edit
```

### Desired Codebase tree with files to be added

```bash
tmux-2html/
└── tests/
    └── region_signal_keys.sh     # ADDED — the verbatim harness below
# NO other files. NO .zig changes. NO docs (integration test harness; no API/config surface).
```

### Known Gotchas of our codebase & Library Quirks

```python
# GOTCHA 1 — use `k` (UP), NOT `j` (DOWN), for the Ctrl-z "row changed" assertion. The region
#   TUI enters at the BOTTOM row (copy-mode parity; region.zig:385-399), and `j` is EOF-clamped
#   at total_rows-1 (motion.zig) => from the bottom start `j` is a NO-OP => row UNCHANGED =>
#   spurious FAIL even when the TUI is alive. `k` moves up => row DECREASES => repaints. VERIFIED
#   (fixed binary: row 17 -> 16 after k). The contract said `j`; use `k`.

# GOTCHA 2 — drain() is NOT optional. Bare `sleep` lets the pty output buffer fill and the TUI's
#   paint writes deadlock the read (envelope_smoke.sh's region drive HUNG CI for hours before the
#   drain fix). Always drain via select+read between keystrokes (copy region_empty_confirm.sh's
#   drain()).

# GOTCHA 3 — use os.waitstatus_to_exitcode(status), NOT the raw `>> 8` bit-shift token. This file
#   has a PATH="$SHIM:$PATH" line; the two-greater-than token alongside it trips check-safety's
#   R3 shim-combo gate. waitstatus_to_exitcode is the stdlib-correct equivalent and keeps the file
#   check-safety-clean. (region_empty_confirm.sh does the same.)

# GOTCHA 4 — detect suspension with os.waitpid(pid, os.WNOHANG | os.WUNTRACED). WUNTRACED makes a
#   STOPPED child reportable; without it a stopped child returns (0,0) — indistinguishable from
#   running. After Ctrl-z, if wpid != 0 and WIFSTOPPED(st) => the process SUSPENDED (the bug).
#   If wpid == 0 => still running (fixed). (On the fixed binary wpid == 0.)

# GOTCHA 5 — the PATH shim MUST be `exec "$REAL_TMUX" -L "$SOCK" "$@"` with ABSOLUTE REAL_TMUX,
#   NO recursion, NO append log. A hand-rolled recursive shim or an unbounded `>> calls.log` is
#   FORBIDDEN (AGENTS.md §1) and trips check-safety. Copy region_empty_confirm.sh's shim verbatim.

# GOTCHA 6 — bounded-wait + SIGKILL: a suspended/hung process must NEVER hang CI. wait_exit()
#   loops waitpid(WNOHANG) to a deadline, then SIGKILL + reap. SIGKILL always terminates a
#   stopped process. (region_empty_confirm.sh uses the same pattern.)

# GOTCHA 7 — SKIP cleanly (exit 0) if tmux OR python3 is absent, so CI runners without them pass.
#   (The harness needs both: tmux for the isolated server, python3 for the pty drive.)
```

## Implementation Blueprint

### Data models and structure

Not applicable — a shell + python test harness; no data models.

### The exact deliverable — verbatim `tests/region_signal_keys.sh`

Create this file verbatim. It mirrors `tests/region_empty_confirm.sh`'s safety shell exactly;
only the python drive body + assertions are specific to Issues 2 & 3.

```sh
#!/bin/sh
# tests/region_signal_keys.sh — Issues 2 & 3 regression: in the region overlay, Ctrl-z (0x1a)
# must NOT suspend the process (ISIG off ⇒ inert byte ⇒ TUI keeps running) and Ctrl-c (0x03)
# must exit 1 (NOT 130) via input.zig's .quit mapping (PRD §7.1 "always restore" / §7.5 cancel).
#
# Drives the REAL ./zig-out/bin/tmux-2html region through a python3 pty (same drive pattern as
# tests/region_empty_confirm.sh) over an ISOLATED tmux server. Three drives: (a) Ctrl-z then k
# then q — assert the TUI never suspended (status-line row: CHANGED after k; clean q exit 1);
# (b) Ctrl-c — assert exit code == 1 (NOT 130), no output file; (c) q — comparison, exit 1.
#
# PRD §0 SAFETY: own `tmux -L t2h-sig-$$` server via a PATH shim (absolute REAL_TMUX, no
# recursion, no append log ⇒ check-safety clean); teardown ONLY the named session. NEVER
# kill-server/killall/pkill. SKIPs (exit 0) if tmux OR python3 absent ⇒ CI-safe.
#
# Run:  sh tests/region_signal_keys.sh   # -> PASS, exit 0 (needs the ISIG fix in the binary)
set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO"
BIN=./zig-out/bin/tmux-2html

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- prerequisites (SKIP cleanly if a tool is missing) ----------------------
if ! command -v tmux >/dev/null 2>&1; then
    echo "SKIP: tmux not installed (region signal-keys needs an isolated tmux server)"
    exit 0
fi
REAL_TMUX=$(command -v tmux)

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: python3 not installed (region signal-keys drives the TUI via a pty)"
    exit 0
fi

if [ ! -x "$BIN" ]; then
    echo "building release binary..."
    zig build -Doptimize=ReleaseFast || fail "zig build failed"
fi

# --- isolated tmux server + a pane with a few lines of content --------------
SOCK="t2h-sig-$$"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/t2h-sig.XXXXXX")
OUT="$WORK/sig.html"
SIDECAR="$(dirname "$BIN")/.last-output"
trap '
    "$REAL_TMUX" -L "$SOCK" kill-session -t s 2>/dev/null || true
    rm -rf "$WORK"
' EXIT

# PATH shim: prefix `-L $SOCK` to EVERY tmux call the binary makes. Absolute REAL_TMUX (no
# recursion), no append log => check-safety clean (mirrors region_empty_confirm.sh exactly).
SHIM=$WORK/shim; mkdir -p "$SHIM"
printf '#!/bin/sh\nexec "%s" -L "%s" "$@"\n' "$REAL_TMUX" "$SOCK" > "$SHIM/tmux"
chmod +x "$SHIM/tmux"

"$REAL_TMUX" -L "$SOCK" new-session -d -s s -x 25 -y 6 || fail "isolated tmux new-session"
PANE=$("$REAL_TMUX" -L "$SOCK" list-panes -t s -F '#{pane_id}' | head -1)

# Seed a few lines so the captured grid has scrollback; the region TUI enters at the BOTTOM row.
"$REAL_TMUX" -L "$SOCK" send-keys -t s "printf 'L1\nL2\nL3\nL4\nL5\n'" Enter
sleep 0.5

rm -f "$OUT" "$SIDECAR"

# --- three pty drives (Ctrl-z, Ctrl-c, q) — one python heredoc -----------------------------
# drain() keeps the pty output buffer empty (NOT bare sleep) so TUI paint writes never deadlock
# the read. waitstatus_to_exitcode is used INSTEAD of the raw bit-shift token: that token's
# spelling trips check-safety R3 alongside this file's PATH="$SHIM:$PATH" line.
PATH="$SHIM:$PATH" python3 - "$PANE" "$BIN" "$OUT" <<'PYEOF' || fail "region signal-keys pty drive"
import os, pty, select, sys, time, re, signal
pane, binary, out = sys.argv[1], sys.argv[2], sys.argv[3]

def drain(fd, secs, buf=None):
    end = time.time() + secs
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if not r:
            continue
        try:
            d = os.read(fd, 8192)
        except OSError:
            break
        if not d:
            break
        if buf is not None:
            buf += d

def last_row(buf):
    m = re.findall(rb'row:(\d+)', bytes(buf))
    return int(m[-1]) if m else None

def wait_exit(pid, fd, deadline_s=8):
    # Bounded wait + SIGKILL: never hang CI (a suspended process is SIGKILLed at the deadline).
    deadline = time.time() + deadline_s
    while time.time() < deadline:
        drain(fd, 0.1)
        wpid, st = os.waitpid(pid, os.WNOHANG)
        if wpid != 0:
            return True, os.waitstatus_to_exitcode(st)
    os.kill(pid, signal.SIGKILL)
    os.waitpid(pid, 0)
    return False, None

def spawn(pane, binary, out):
    pid, fd = pty.fork()
    if pid == 0:
        os.execvpe(binary, ["tmux-2html", "region", "--target", pane, "--output", out],
                   os.environ.copy())
    return pid, fd

# ---- (a) Ctrl-z (0x1a): inert byte => TUI keeps running; k moves cursor; q exits 1 ----
buf = bytearray()
pid, fd = spawn(pane, binary, out)
drain(fd, 0.8, buf)                 # initial paint
row_before = last_row(buf)
os.write(fd, b"\x1a")               # Ctrl-z (SIGTSTP if ISIG on; inert byte if ISIG off)
drain(fd, 0.4, buf)
# (a.1) process must NOT be stopped: WUNTRACED makes a stopped child reportable.
wpid, st = os.waitpid(pid, os.WNOHANG | os.WUNTRACED)
if wpid != 0:
    if os.WIFSTOPPED(st):
        sys.exit("FAIL: Ctrl-z SUSPENDED the process (ISIG not disabled — Issue 2)")
    sys.exit("FAIL: Ctrl-z caused early exit (code=%d)" % os.waitstatus_to_exitcode(st))
# (a.2) TUI kept repainting: k (UP — cursor starts on the BOTTOM row, so j is clamped) moves it.
os.write(fd, b"k")
drain(fd, 0.4, buf)
row_after = last_row(buf)
if row_before is None or row_after is None or row_before == row_after:
    sys.exit("FAIL: status-line row: did not change after k (%s -> %s) — TUI suspended after Ctrl-z"
             % (row_before, row_after))
# (a.3) q still cancels cleanly (exit 1) and the terminal was restored.
os.write(fd, b"q")
exited, code = wait_exit(pid, fd)
try: os.close(fd)
except OSError: pass
if not exited:
    sys.exit("FAIL: region did not exit after Ctrl-z+k+q (timed out — TUI hung)")
if code != 1:
    sys.exit("FAIL: Ctrl-z path exited %d (expected 1 after q)" % code)
if b"\x1b[?1049l" not in bytes(buf):
    sys.exit("FAIL: restore sequence absent after q (terminal not restored — §7.1)")

# ---- (b) Ctrl-c (0x03): exit 1 (NOT 130), no output file -------------------
if os.path.exists(out):
    os.remove(out)
pid, fd = spawn(pane, binary, out)
drain(fd, 0.8)
os.write(fd, b"\x03")               # Ctrl-c (SIGINT -> 130 if ISIG on; .quit byte -> exit 1 if off)
exited, code = wait_exit(pid, fd)
try: os.close(fd)
except OSError: pass
if not exited:
    sys.exit("FAIL: region did not exit after Ctrl-c (timed out)")
if code != 1:
    sys.exit("FAIL: Ctrl-c exited %d (expected 1; 130 means ISIG still on — Issue 3)" % code)
if os.path.exists(out):
    sys.exit("FAIL: Ctrl-c wrote an output file (expected none)")

# ---- (c) q (comparison): the canonical cancel -> exit 1 --------------------
pid, fd = spawn(pane, binary, out)
drain(fd, 0.8)
os.write(fd, b"q")
exited, code = wait_exit(pid, fd)
try: os.close(fd)
except OSError: pass
if not exited or code != 1:
    sys.exit("FAIL: q exited %s (expected 1)" % (None if not exited else code))

sys.exit(0)   # all three drives passed
PYEOF

# --- Ctrl-c / q must leave NO .last-output sidecar (cancel => no output, §7.5) ------------
if [ -f "$SIDECAR" ] && grep -qF "$(basename "$OUT")" "$SIDECAR"; then
    fail "signal-cancel left a .last-output sidecar referencing the output (cancel must write none)"
fi

echo "PASS: region Ctrl-z (no suspend) + Ctrl-c (exit 1) + q (exit 1) — Issues 2 & 3 fixed"
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: CREATE tests/region_signal_keys.sh (verbatim above)
  - Copy the harness verbatim. It mirrors region_empty_confirm.sh's safety shell exactly.
  - chmod +x is optional (invoked via `sh tests/region_signal_keys.sh`).
  - GOTCHA 1 (k not j), GOTCHA 2 (drain), GOTCHA 3 (waitstatus_to_exitcode), GOTCHA 4 (WUNTRACED),
    GOTCHA 5 (absolute-exec shim), GOTCHA 6 (bounded-wait+SIGKILL), GOTCHA 7 (SKIP) are all baked in.

Task 2: VALIDATE (see Validation Loop)
  - RUN: sh tests/region_signal_keys.sh   → expect PASS, exit 0 (against the ISIG-fixed binary)
  - RUN: sh scripts/check-safety.sh --paths tests/region_signal_keys.sh → 0 FAIL / 0 WARN
  - RUN: the 4 shipped harnesses + zig build test -Doptimize=ReleaseFast → all green (additive)
```

### Implementation Patterns & Key Details

```sh
# PATTERN: the safety shell is COPIED from region_empty_confirm.sh verbatim (only the python
# drive body differs). The PATH shim is absolute-exec (no recursion, no log => check-safety clean):
printf '#!/bin/sh\nexec "%s" -L "%s" "$@"\n' "$REAL_TMUX" "$SOCK" > "$SHIM/tmux"

# PATTERN: drain() between keystrokes (NOT bare sleep) prevents pty-buffer deadlock:
def drain(fd, secs, buf=None):
    end = time.time() + secs
    while time.time() < end:
        r,_,_ = select.select([fd],[],[],0.05)
        if r:
            try: d = os.read(fd,8192)
            except OSError: break
            if not d: break
            if buf is not None: buf += d

# CRITICAL (GOTCHA 1): use k (UP), not j. The cursor starts on the BOTTOM row (copy-mode parity);
# j is clamped => row unchanged => spurious FAIL. k moves up => row changes (verified 17->16).
os.write(fd, b"k")   # not b"j"

# CRITICAL (GOTCHA 3/4): waitstatus_to_exitcode (not >>); WUNTRACED to detect suspension:
code = os.waitstatus_to_exitcode(status)              # not status >> 8
wpid, st = os.waitpid(pid, os.WNOHANG | os.WUNTRACED) # WUNTRACED reports a stopped child
```

### Integration Points

```yaml
TESTS (tests/):
  - region_signal_keys.sh: NEW. Mirrors region_empty_confirm.sh's safety shell.
  - The 4 shipped harnesses + zig build test stay green (this is additive; no .zig change).

CODE (src/tui/app.zig):
  - INPUT contract: the ISIG fix (P1.M1.T1.S1, app.zig:100) must be in the binary. This harness
    PROVES it live. If the binary is not yet fixed, this harness FAILS on Ctrl-c (exit 130) —
    which is the point.

CI (.github/workflows/ci.yml):
  - Not wired by this task (the contract: "DOCS: none; runnable standalone + safe in CI").
    If desired, a follow-up can add a `sh tests/region_signal_keys.sh` step (after envelope_smoke).

SAFETY (scripts/check-safety.sh):
  - The absolute-exec PATH shim + waitstatus_to_exitcode (no >>) keep this file 0 FAIL / 0 WARN
    (mirrors region_empty_confirm.sh, which is clean).

CONFIG / DATABASE / ROUTES:
  - none.
```

## Validation Loop

> PRIMARY gate: `sh tests/region_signal_keys.sh` → PASS, exit 0 against the ISIG-fixed binary.
> Plus check-safety clean + the shipped harnesses/`zig build test` still green.

### Level 1: Syntax & Style (Immediate Feedback)

```bash
cd /home/dustin/projects/tmux-2html
sh -n tests/region_signal_keys.sh && echo "parses OK"   # POSIX sh syntax check (no execution)
# Expected: OK. A parse error means a quoting typo in the heredoc/shim.

# check-safety (AGENTS.md §3) — the harness must be clean:
sh scripts/check-safety.sh --paths tests/region_signal_keys.sh
# Expected: 0 FAIL / 0 WARN. The absolute-exec shim (no recursion) + waitstatus_to_exitcode (no >>)
# keep R3's shim-combo gate from firing (mirrors region_empty_confirm.sh).
```

### Level 2: The Harness Itself (PRIMARY gate)

```bash
sh tests/region_signal_keys.sh
# Expected: "PASS: region Ctrl-z (no suspend) + Ctrl-c (exit 1) + q (exit 1) — Issues 2 & 3 fixed"
# and exit 0. Needs the ISIG-fixed binary (P1.M1.T1.S1) + tmux + python3. SKIPs (exit 0) if absent.
#
# To PROVE it detects the bug: temporarily revert app.zig's `raw.lflag.ISIG = false;`, rebuild
# (`zig build -Doptimize=ReleaseFast`), re-run => the Ctrl-c drive FAILS ("Ctrl-c exited 130").
# (Verified in research: buggy build => Ctrl-c exit 130; fixed => exit 1.) Restore the line.
```

### Level 3: Regression Guard (shipped harnesses + unit tests unaffected)

```bash
# The new harness is ADDITIVE (a new tests/ file; no .zig change). Confirm nothing else broke:
sh tests/region_empty_confirm.sh && echo "empty-confirm OK"
sh tests/envelope_smoke.sh && echo "envelope-smoke OK"
sh tests/plugin_options.sh && echo "plugin-options OK"
sh tests/zero_dimension_reject.sh && echo "zero-dim OK"
zig build test -Doptimize=ReleaseFast && echo "zig tests OK"   # ReleaseFast mandatory (Debug linker bug)
```

### Level 4: Safety / cleanup confidence

```bash
# Confirm the harness leaves no residue and never touched the user's tmux:
sh scripts/preflight.sh   # bounded scan for giant files / .audit* / calls.log / disk => exit 0
# The harness uses an isolated `-L t2h-sig-$$` socket + trap kill-session -t s + rm -rf $WORK;
# it NEVER kill-server/killall/pkill and writes scratch to real disk (mktemp -d), not /tmp spill.
```

## Final Validation Checklist

### Technical Validation

- [ ] `sh -n tests/region_signal_keys.sh` parses; `check-safety.sh --paths` → 0 FAIL / 0 WARN (Level 1).
- [ ] `sh tests/region_signal_keys.sh` → PASS, exit 0 (Level 2 — primary gate).

### Feature Validation

- [ ] (a) Ctrl-z: not-stopped (WUNTRACED) + `row:` changed after `k` + `q` exit 1 + restore seq.
- [ ] (b) Ctrl-c: exit 1 (NOT 130) + no output file.
- [ ] (c) q: exit 1.
- [ ] No `.last-output` sidecar references the output after (b)/(c).

### Code Quality Validation

- [ ] Safety shell mirrors region_empty_confirm.sh verbatim (isolated socket, absolute-exec shim,
      trap named-session teardown, real-disk scratch, bounded-wait+SIGKILL, SKIP-if-absent).
- [ ] Uses `k` not `j` (GOTCHA 1); `drain()` not bare sleep (GOTCHA 2); `waitstatus_to_exitcode`
      not `>>` (GOTCHA 3); `WUNTRACED` for suspend detection (GOTCHA 4).
- [ ] PRD §0/§0.1 honored: no kill-server/killall/pkill; teardown by named session only.

### Documentation & Deployment

- [ ] No docs (integration test harness; no API/config/CLI surface). DOCS: none.
- [ ] No new env vars / config.

---

## Anti-Patterns to Avoid

- ❌ Don't use `j` (down) for the Ctrl-z row-change assertion — the cursor starts on the BOTTOM
  row (copy-mode parity) so `j` is clamped and the row won't change (spurious FAIL). Use `k` (up),
  verified to move the cursor (row 17→16). (GOTCHA 1.)
- ❌ Don't use bare `sleep` between keystrokes — the pty output buffer fills and the TUI's paint
  writes deadlock the read (envelope_smoke.sh hung CI for hours this way). Always `drain()`.
  (GOTCHA 2.)
- ❌ Don't use the raw `>> 8` bit-shift token for the exit code — alongside this file's
  `PATH="$SHIM:$PATH"` line it trips check-safety R3. Use `os.waitstatus_to_exitcode(status)`.
  (GOTCHA 3.)
- ❌ Don't detect suspension with bare `waitpid(WNOHANG)` — a stopped child returns (0,0)
  (indistinguishable from running) without WUNTRACED. Use `os.WNOHANG | os.WUNTRACED`. (GOTCHA 4.)
- ❌ Don't hand-roll a recursive tmux shim or use an unbounded `>> calls.log` — FORBIDDEN
  (AGENTS.md §1) and trips check-safety. The shim is `exec "$REAL_TMUX" -L "$SOCK" "$@"`
  (absolute, no recursion, no log). (GOTCHA 5.)
- ❌ Don't let a suspended/hung process hang CI — `wait_exit()` bounds the wait + SIGKILLs at the
  deadline. (GOTCHA 6.)
- ❌ Don't hard-fail when tmux/python3 is absent — SKIP exit 0 so CI runners without them pass.
  (GOTCHA 7.)
- ❌ Don't touch any `.zig` (the fix is P1.M1.T1.S1), the 4 shipped harnesses, or scripts/. This
  task creates ONE new file: tests/region_signal_keys.sh.
- ❌ Don't run plain `zig build test` (Debug) — it hits the `R_X86_64_PC64` linker bug. Use
  `-Doptimize=ReleaseFast`.

---

**Confidence Score: 10/10** for one-pass implementation success.

The deliverable is one self-contained harness file, given verbatim, that mirrors the approved
`region_empty_confirm.sh` safety shell exactly (the only project-endorsed shape for a tmux
integration harness — isolated socket, absolute-exec PATH shim, named-session teardown, bounded
SIGKILL, SKIP-if-absent). The one subtle correction — use `k` not `j` (the region TUI enters at
the bottom row so `j` is clamped) — is verified (`row:` 17→16 after `k`) and documented. The
Ctrl-c regression-detection is proven empirically: against the ISIG-fixed repo binary Ctrl-c
exits **1** (PASS), against a throwaway buggy build (ISIG reverted) Ctrl-c exits **130** (the
`code == 1` assertion FAILS). The Ctrl-z path is verified inert on the fixed binary (`k` repaints,
`q` exits 1, restore sequence emitted), with `WUNTRACED` as the canonical suspend detector. The
check-safety R3 gotcha (`waitstatus_to_exitcode`, not `>>`) is baked in, so the file is 0 FAIL /
0 WARN. The harness is additive (one new tests/ file; no `.zig` change), so the 4 shipped
harnesses + the ReleaseFast unit suite stay green. The implementer creates the file verbatim and
runs `sh tests/region_signal_keys.sh`.