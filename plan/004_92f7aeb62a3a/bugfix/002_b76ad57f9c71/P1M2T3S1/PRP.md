# PRP — P1.M2.T3.S1: `tests/region_mouse.sh` (python3 pty: SGR click/drag/wheel assertions)

## Goal

**Feature Goal**: Create the **integration-test harness for Issue 1 (PRD §7.6 mouse support)**. It
drives the REAL `./zig-out/bin/tmux-2html region` binary through a python3 pty, sends SGR
mode-1006 mouse sequences (click / drag / wheel), and asserts the region TUI actually responds —
click moves the cursor (status `col:` changes), drag→confirm writes an HTML file containing a
seeded marker, wheel scrolls the viewport (status `row:` changes). It is a **true regression
detector**: it FAILs (exit 1) on the pre-fix binary (mouse ignored by `regionHandle`) and PASSes
(exit 0) on the post-fix binary (P1.M2.T2.S1's `.mouse` arm wired).

**Deliverable**: **ONE new file**: `tests/region_mouse.sh` — a self-contained, CI-safe PASS/exit-0
shell harness that mirrors `tests/region_empty_confirm.sh` + `tests/region_signal_keys.sh`
EXACTLY for the safety shell (isolated `-L t2h-mouse-$$` socket, approved PATH shim, named-session
teardown, SKIP-cleanly if tmux/python3 absent). No `.zig`, no other `tests/*.sh`, no docs touched.

**Success Definition**:
- `sh tests/region_mouse.sh` ⇒ prints `PASS: …`, exit 0, on a binary built with P1.M2.T2.S1 applied.
- `sh tests/region_mouse.sh` ⇒ exit 1 (FAIL) on a binary built WITHOUT P1.M2.T2.S1 (mouse ignored)
  — proving the three assertions are genuine detectors, not tautologies.
- `tests/region_mouse.sh` is check-safety-clean **on its own**: `sh scripts/check-safety.sh --paths
  tests/region_mouse.sh` ⇒ `0 FAIL(s), 0 WARN(s)` (the approved shim + `os.waitstatus_to_exitcode`
  keep it clean — see Gotchas D/E/F), and the repo-wide scan must not gain a NEW violation from
  this file. (NOTE: the repo currently carries 1 PRE-EXISTING FAIL in a **sibling** task's
  committed research doc — `P1M1T2S1/research/findings.md:91`, whose prose 'NEVER kill-server'
  trips R1 — it is unrelated to and unowned by this task; do not try to fix it here.)
- `sh scripts/preflight.sh` ⇒ clean. All 5 existing `tests/*.sh` harnesses stay GREEN.
- SKIPs cleanly (exit 0) on a runner without `tmux` or `python3`.

## User Persona

**Target User**: The CI pipeline (`.github/workflows/ci.yml`) and any developer running
`sh tests/region_mouse.sh` locally to confirm mouse support (PRD §7.6) works end-to-end.

**Use Case**: After P1.M2.T2.S1 wires the `.mouse` arm, this harness is the automated proof that
an SGR click/drag/wheel is consumed by `regionHandle` (not dropped, as in the bug). It locks down
the §7.6 behavior so a future refactor cannot silently regress it.

**Pain Points Addressed**: Round-2 testing found mouse is decoded by `app.zig` but discarded by
`regionHandle` — and "no integration test sends a mouse event, so it stayed green" (PRD h2.4).
This harness is exactly that missing test: it sends real SGR bytes and asserts real responses.

## Why

- **Closes the test-coverage gap that let Issue 1 ship.** PRD h2.4: the mouse gap went unnoticed
  because "no integration test sends a mouse event." S1/S2 added PURE unit tests for
  `mouseCell`/`applyMouse`; THIS is the live end-to-end pty proof that the wired arm actually fires.
- **Deterministic FAIL-before/PASS-after.** Every assertion is keyed to a user-visible status-line
  change (`row:`/`col:`) or a written file — not internal state — so it fails identically on the
  buggy binary (mouse ignored ⇒ no change ⇒ no file) and passes on the fixed one. Verified logic
  in `research/findings.md` §6.
- **Reuses the proven, CI-safe harness skeleton.** `region_empty_confirm.sh` and
  `region_signal_keys.sh` already solved the hard parts (pty timing, the 0×0-winsize CI-hang, the
  `>>`-token check-safety trap, scoped teardown). This harness is a 3rd sibling using the same shell.

## What

A single shell script `tests/region_mouse.sh` that:
1. Builds the release binary if missing; SKIPs cleanly if `tmux`/`python3` absent.
2. Creates an isolated `tmux -L t2h-mouse-$$` server via the approved PATH shim; seeds ~30 marker
   lines; tears down by **named session only** on EXIT.
3. Drives `region --target $PANE --output $OUT` through a python3 `pty.fork()`, with the winsize
   set to 24×80 + SIGWINCH (the CI-hang fix), and runs **three assertions**:
   - **(a) CLICK MOVES CURSOR** — SGR left-press+release at (15,2); assert status `col:` increased
     (cursor moved from col 0 → the clicked cell).
   - **(b) DRAG → CONFIRM → FILE** — press(2,1) → motion(2,4) → release(2,4) → Enter; assert exit 0,
     output file exists, and it contains the seeded marker.
   - **(c) WHEEL SCROLLS** — wheel_up at (1,1); assert status `row:` decreased (viewport scrolled).

### Success Criteria

- [ ] `tests/region_mouse.sh` created; `sh -n tests/region_mouse.sh` parses clean.
- [ ] `sh tests/region_mouse.sh` ⇒ PASS, exit 0 (on a P1.M2.T2.S1-applied binary).
- [ ] FAIL-before proof: with the `.mouse` arm removed from `region.zig` (rebuild), the harness
      exits 1 (all three assertions fail on the pre-fix binary).
- [ ] `sh scripts/check-safety.sh --paths tests/region_mouse.sh` ⇒ `0 FAIL, 0 WARN` (the new file is clean on its own); the repo-wide FAIL count is unchanged by this file (1 pre-existing FAIL lives in a sibling doc, `P1M1T2S1/research/findings.md:91` — not ours).
- [ ] SKIPs (exit 0) if `tmux` or `python3` absent.
- [ ] Only `tests/region_mouse.sh` added; no other file touched.

## All Needed Context

### Context Completeness Check

_Pass: "If someone knew nothing about this codebase, would they have everything needed to implement
this successfully?"_ — Yes. The entire `tests/region_mouse.sh` is given verbatim below (ready to
`write`), adapted from the two proven sibling harnesses. The SGR byte sequences are verified against
the binary's actual decoder (`src/tui/app.zig` `parseMousePayload`/`decodeMouse`); the status-line
format `row:{d} col:{d}` is verified at `src/tui/view.zig:241`; the `applyMouse` semantics (press
moves cursor / drag selects / wheel scrolls) are verified in `architecture/mouse_wiring_design.md`;
and the three non-obvious gotchas (tiny-pane hang ⇒ use 80×10; 0×0-winsize CI-hang ⇒ TIOCSWINSZ+
SIGWINCH; scrollback>viewport for the wheel test ⇒ seed ~30 lines) are documented with the exact
fixes. The implementer writes one file and runs `sh tests/region_mouse.sh`.

### Documentation & References

```yaml
# MUST READ — this task's own audit (SGR table verified, geometry, FAIL-before proof, gotchas)
- file: plan/004_92f7aeb62a3a/bugfix/002_b76ad57f9c71/P1M2T3S1/research/findings.md
  why: "§2 SGR sequences VERIFIED against app.zig (b&64=wheel, b&32=motion, b&3=button, M/m=press/release);
        §3 applyMouse semantics => why each assertion is deterministic; §4 status format view.zig:241;
        §5 the 3 geometry gotchas (80x10 pane, winsize+SIGWINCH, scrollback>viewport); §6 FAIL-before/PASS-after;
        §7 why this file stays check-safety-clean."
  critical: "GOTCHA C: the wheel test needs scrollback > viewport (grid_rows=23). Seed ~30 marker
             lines or wheel is a no-op => false FAIL. GOTCHA D: use os.waitstatus_to_exitcode, NEVER
             the raw `>>` bit-shift token (this file has PATH=$SHIM:$PATH => R3 fires)."

# MUST MIRROR — the canonical safety shell + pty drive (the "mirror EXACTLY" reference)
- file: tests/region_empty_confirm.sh
  why: "THE skeleton: set -u / cd / fail / SKIP-if-absent / REAL_TMUX / SOCK / WORK=mktemp / the
        approved PATH shim / new-session / trap kill-session+rm / the python pty.fork drive.
        Also the source of the winsize+SIGWINCH CI-hang fix (TIOCSWINSZ 24x80) — COPY IT."
  pattern: "lines 1-46 (shell skeleton) are copied near-verbatim; only SOCK tag, OUT name, pane
            size, seed, and the PYEOF body change."
  gotcha: "It uses pane -x 80 -y 10 with a comment that tiny panes (20x6) HANG region's event loop.
           Override the item's suggested -x 25 -y 8 with this proven 80x10."

# MUST MIRROR — the closest sibling (3-drive python heredoc + helpers + waitstatus_to_exitcode)
- file: tests/region_signal_keys.sh
  why: "THE python pattern: drain(fd,secs,buf), wait_exit(pid,fd) [bounded + SIGKILL], spawn(pane,binary,out),
        os.waitstatus_to_exitcode(st) [NOT `>>`], the `|| fail` wrapper. Copy these helpers verbatim;
        swap the key-bytes for SGR-mouse bytes and the assertions for row:/col:/file checks."
  pattern: "the 3-drive structure (a)/(b)/(c) with a fresh spawn() per drive."

# MUST READ — the design this harness validates (applyMouse click/drag/wheel semantics)
- file: plan/004_92f7aeb62a3a/bugfix/002_b76ad57f9c71/architecture/mouse_wiring_design.md
  why: "Confirms press moves cursor + clears sel + sets anchor; motion extends a linewise (or alt⇒block)
        selection; release finalizes (or clears on a collapsed click); wheel=halfPageUp/Down+clamp.
        These are WHY col:/row:/file change as the assertions expect."

# MUST READ — the normative safety rules + the canonical-harness checklist + the SGR sequence table
- file: plan/004_92f7aeb62a3a/bugfix/002_b76ad57f9c71/architecture/testing_safety.md
  why: "§'Canonical integration-harness pattern' is the 11-step checklist this file follows;
        §'SGR mouse sequences' is the verified byte table; §'Mouse-harness assertions' is the 3-assertion spec."

# CONTRACT — what P1.M2.T2.S1 produces (the mouse-responsive binary this harness consumes)
- file: plan/004_92f7aeb62a3a/bugfix/002_b76ad57f9c71/P1M2T2S1/PRP.md
  why: "Defines the .mouse arm (applyMouse + repaint + return .none) this harness exercises. Assume
        it lands exactly as specified. Do NOT duplicate its work or touch region.zig."

# VERIFIED decode/format sources (read-only — confirm the bytes/format if doubting an assertion)
- file: src/tui/app.zig
  section: "MouseButton(252) MouseAction(253) MouseEvent(259) Event(291) decodeMouse(~319) parseMousePayload(375)"
  why: "Confirms the SGR byte table: b&64⇒wheel(b&1: up/down), b&32⇒motion, b&3⇒button, term 'M'⇒press/'m'⇒release."
- file: src/tui/view.zig
  section: "renderStatus, line 241: w.print(\"row:{d} col:{d}\", .{cursor.y+1, cursor.x+1}); line 727 test."
  why: "Confirms the status-line substrings the assertions grep (row:N col:M, 1-based)."
```

### Current Codebase tree (relevant slice — this task's starting point)

```bash
tmux-2html/
├── tests/
│   ├── region_empty_confirm.sh   # canonical skeleton + winsize fix (MIRROR)
│   ├── region_signal_keys.sh     # 3-drive python pattern + helpers (MIRROR)
│   ├── envelope_smoke.sh  plugin_options.sh  zero_dimension_reject.sh   ← DO NOT TOUCH
│   └── region_mouse.sh           # <— CREATE (this task)
├── src/region.zig                # has P1.M2.T2.S1's .mouse arm (CONSUME, do not edit)
├── src/tui/app.zig               # SGR decoder (CONSUME)
├── scripts/check-safety.sh  preflight.sh    # validation gates (run-only)
└── zig-out/bin/tmux-2html        # built by the harness if missing
```

### Desired Codebase tree with files to be added

```bash
tmux-2html/
└── tests/
    └── region_mouse.sh           # NEW — self-contained SGR mouse integration harness
# NO other files. No .zig / plugin / build / docs changes.
```

### Known Gotchas of our codebase & Library Quirks

```sh
# GOTCHA A — TINY PANES HANG region's event loop. region_empty_confirm.sh PROVEN 80x10 works and
#   20x6 hangs. The item suggested -x 25 -y 8, but the "mirror EXACTLY" canonical harness overrides it.
#   USE pane -x 80 -y 10. (Click target col 15 is well within 80 cols.) Do NOT use a tiny pane.

# GOTCHA B — pty.fork() leaves the pty window at 0x0; under a 0x0 CI parent region's TUI paints but
#   never services input => a blocking waitpid hangs the job for HOURS. region_empty_confirm's fix:
#   fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24,80,0,0)); os.kill(pid, signal.SIGWINCH).
#   INCLUDE THIS in spawn(). (region_signal_keys omits it but works on its host — be safe, include it.)

# GOTCHA C — the WHEEL test needs scrollback > viewport. grid_rows = pty_rows-1 = 23 (winsize 24).
#   If the captured scrollback <= 23, viewport.scroll stays 0 and wheel is a no-op => false FAIL even
#   post-fix. SEED ~30 marker lines (yes "MOUSEMK line" | head -30) so scrollback ~30 > 23.

# GOTCHA D — NEVER use the raw `>>` exit-code bit-shift token (st >> 8). This file has
#   PATH="$SHIM:$PATH", so check-safety R3 (PATH-prepend + an exec/>> sink in ONE file) would FIRE.
#   Use os.waitstatus_to_exitcode(st) (py3.9+ stdlib) — identical result, check-safety-clean.
#   (Both siblings + the item contract call this out.)

# GOTCHA E — mouse events do NOT exit the TUI. Drives (a) and (c) leave region running; you MUST reap
#   the child (send q, then SIGKILL-fallback + waitpid) so the job never hangs on an open pty. Drive
#   (b) exits on its own (Enter => confirm => exit 0); use wait_exit() for it.

# GOTCHA F — the approved PATH shim is `exec "$REAL_TMUX" -L "$SOCK" "$@"` (ABSOLUTE path, NO append
#   log), written to a SEPARATE file $WORK/shim/tmux. check-safety R3 needs the PATH-prepend AND the
#   exec/>> sink in the SAME file; the sink lives in the generated shim, NOT in region_mouse.sh, so R3
#   does NOT fire. NEVER inline a recursive bare-`exec tmux` or a `>> calls.log` in region_mouse.sh.

# GOTCHA G — teardown is by NAMED SESSION on the isolated socket ONLY: `tmux -L "$SOCK" kill-session
#   -t s`. NEVER kill-server / killall tmux / pkill tmux (check-safety R1 FAILs; PRD §0 forbids it).

# GOTCHA H — the status line is 1-based: cursor (col 0, last row) prints `row:<last> col:1`. A click
#   at SGR (15,2) => grid cell (14,1) => status `row:2 col:15`. So col: goes 1 -> 15 (increases).
#   wheel_up decreases viewport.scroll => clampCursorIntoViewport pulls the cursor UP => row: decreases.
```

## Implementation Blueprint

### Data models and structure

Not applicable — a shell + python test harness. No types/schemas. The python heredoc uses plain
`bytearray` buffers and `re.findall` over the pty bytes; assertions compare parsed integers.

### The exact deliverable: `tests/region_mouse.sh` (CREATE — verbatim)

> Adapted from `tests/region_signal_keys.sh` (helpers + 3-drive structure) and
> `tests/region_empty_confirm.sh` (skeleton + winsize fix). The SGR bytes are verified against
> `src/tui/app.zig`; the status substrings against `src/tui/view.zig:241`.

```sh
#!/bin/sh
# tests/region_mouse.sh — Issue 1 (PRD §7.6) regression: the region overlay must respond to SGR
# mouse — click MOVES the cursor, drag→Enter WRITES a file, wheel SCROLLS. Drives the REAL
# ./zig-out/bin/tmux-2html region through a python3 pty over an ISOLATED tmux server. Three drives:
# (a) click at a far cell ⇒ status col: increases; (b) drag ⇒ Enter ⇒ exit 0 + output file with a
# seeded marker; (c) wheel_up ⇒ status row: decreases.
#
# PRD §0 SAFETY: own `tmux -L t2h-mouse-$$` server via a PATH shim (absolute REAL_TMUX, no recursion,
# no append log ⇒ check-safety clean); teardown ONLY the named session. NEVER kill-server/killall/
# pkill. SKIPs (exit 0) if tmux OR python3 absent ⇒ CI-safe.
#
# Run:  sh tests/region_mouse.sh   # -> PASS, exit 0 (needs the P1.M2.T2.S1 .mouse arm in the binary)
set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO"
BIN=./zig-out/bin/tmux-2html

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- prerequisites (SKIP cleanly if a tool is missing) ----------------------
if ! command -v tmux >/dev/null 2>&1; then
    echo "SKIP: tmux not installed (region mouse needs an isolated tmux server)"
    exit 0
fi
REAL_TMUX=$(command -v tmux)

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: python3 not installed (region mouse drives the TUI via a pty)"
    exit 0
fi

if [ ! -x "$BIN" ]; then
    echo "building release binary..."
    zig build -Doptimize=ReleaseFast || fail "zig build failed"
fi

# --- isolated tmux server + a pane with ~30 marker lines of scrollback -------
SOCK="t2h-mouse-$$"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/t2h-mouse.XXXXXX")
OUT="$WORK/drag.html"
trap '
    "$REAL_TMUX" -L "$SOCK" kill-session -t s 2>/dev/null || true
    rm -rf "$WORK"
' EXIT

# PATH shim: prefix `-L $SOCK` to EVERY tmux call the binary makes. Absolute REAL_TMUX (no
# recursion), no append log => check-safety clean (mirrors region_empty_confirm.sh exactly).
SHIM=$WORK/shim; mkdir -p "$SHIM"
printf '#!/bin/sh\nexec "%s" -L "%s" "$@"\n' "$REAL_TMUX" "$SOCK" > "$SHIM/tmux"
chmod +x "$SHIM/tmux"

# 80x10 (NOT tiny): region's TUI only services input reliably at a normal pane size (tiny panes
# hang the event loop — see region_empty_confirm.sh). The click target col 15 is well within 80.
"$REAL_TMUX" -L "$SOCK" new-session -d -s s -x 80 -y 10 || fail "isolated tmux new-session"
PANE=$("$REAL_TMUX" -L "$SOCK" list-panes -t s -F '#{pane_id}' | head -1)

# Seed ~30 marker lines so the captured scrollback (~30) EXCEEDS the viewport (grid_rows=23 for a
# 24-row pty) — without that, the wheel test is a no-op (scroll never leaves 0). The repeated marker
# is also what assertion (b) grep-checks in the rendered HTML.
"$REAL_TMUX" -L "$SOCK" send-keys -t s 'yes "MOUSEMK line" | head -30' Enter
sleep 0.6

rm -f "$OUT"

# --- three pty drives (click / drag / wheel) — one python heredoc -------------------------
# drain() keeps the pty buffer empty (NOT bare sleep) so TUI writes never deadlock the read.
# waitstatus_to_exitcode is used INSTEAD of the raw bit-shift token: that token's spelling trips
# check-safety R3 alongside this file's PATH="$SHIM:$PATH" line.
PATH="$SHIM:$PATH" python3 - "$PANE" "$BIN" "$OUT" <<'PYEOF' || fail "region mouse pty drive"
import os, pty, select, sys, time, re, signal, struct, fcntl, termios
pane, binary, out = sys.argv[1], sys.argv[2], sys.argv[3]
MARK = b"MOUSEMK line"   # the seeded marker the drag must render into the HTML

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

def last_status(buf):
    # status line (view.zig:241): "row:{d} col:{d}" (1-based). Return (row,col) of the LAST paint.
    rows = re.findall(rb'row:(\d+)', bytes(buf))
    cols = re.findall(rb'col:(\d+)', bytes(buf))
    if not rows or not cols:
        return None
    return (int(rows[-1]), int(cols[-1]))

def wait_exit(pid, fd, deadline_s=8):
    # Bounded wait + SIGKILL: never hang CI. waitstatus_to_exitcode (NOT the `>>` bit-shift token).
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
    # pty.fork() leaves the window at 0x0; under a 0x0 CI parent region's TUI never services input
    # (hangs for hours). Set a real size + SIGWINCH so the event loop reads the mouse bytes.
    # Same fix as region_empty_confirm.sh. winsize 24x80 => grid_rows = 23.
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
    os.kill(pid, signal.SIGWINCH)
    return pid, fd

def reap(pid, fd):
    # Mouse events don't exit the TUI: graceful q, then SIGKILL fallback + waitpid (never hang CI).
    try: os.write(fd, b"q")
    except OSError: pass
    drain(fd, 0.4)
    try: os.close(fd)
    except OSError: pass
    deadline = time.time() + 4
    while time.time() < deadline:
        wpid, _ = os.waitpid(pid, os.WNOHANG)
        if wpid != 0:
            return
    os.kill(pid, signal.SIGKILL)
    os.waitpid(pid, 0)

# ---- (a) CLICK MOVES CURSOR: left-press+release at a FAR cell => status col: increases ----
buf = bytearray()
pid, fd = spawn(pane, binary, out)
drain(fd, 0.8, buf)                       # initial paint; cursor starts at the LAST row, col 0 => col:1
before = last_status(buf)
# SGR (mode 1006): \x1b[<{b};{x};{y}{M|m}; x,y are 1-based cells. b=0 left; M=press, m=release.
os.write(fd, b"\x1b[<0;15;2M")            # left press   @ (col=15,row=2) => cursor -> grid (14,1)
drain(fd, 0.25, buf)
os.write(fd, b"\x1b[<0;15;2m")            # left release @ (15,2) (collapsed => no selection; cursor stays)
drain(fd, 0.25, buf)
after = last_status(buf)
reap(pid, fd)
if before is None or after is None:
    sys.exit("FAIL: (a) no status line captured (%s -> %s)" % (before, after))
# Cursor was at col 0 (status col:1); the click must move it toward col 15 (status col:15) => increase.
if not (after[1] > before[1]):
    sys.exit("FAIL: (a) click did NOT move cursor col (%s -> %s) — mouse IGNORED" % (before, after))

# ---- (b) DRAG -> CONFIRM WRITES FILE: press A, motion B (3 rows), release, Enter ----
if os.path.exists(out):
    os.remove(out)
buf = bytearray()
pid, fd = spawn(pane, binary, out)
drain(fd, 0.8, buf)
os.write(fd, b"\x1b[<0;2;1M");  drain(fd, 0.15, buf)   # press   @ (2,1)  (begin anchor)
os.write(fd, b"\x1b[<32;2;4M"); drain(fd, 0.15, buf)   # motion  @ (2,4)  (32=motion|left => extend drag)
os.write(fd, b"\x1b[<0;2;4m");  drain(fd, 0.15, buf)   # release @ (2,4)  (finalize selection)
os.write(fd, b"\r");            drain(fd, 0.2, buf)    # Enter => confirm selection -> render -> exit 0
exited, code = wait_exit(pid, fd)
try: os.close(fd)
except OSError: pass
if not exited:
    sys.exit("FAIL: (b) region did not exit after drag+Enter (timed out)")
if code != 0:
    sys.exit("FAIL: (b) drag+confirm exited %d (expected 0 — non-empty selection renders)" % code)
if not os.path.exists(out):
    sys.exit("FAIL: (b) drag+confirm wrote NO output file (selection never began)")
with open(out, "rb") as f:
    html = f.read()
if MARK not in html:
    sys.exit("FAIL: (b) output file missing the seeded marker (drag selected nothing)")

# ---- (c) WHEEL SCROLLS: wheel_up => viewport scrolls, cursor clamps up, row: decreases ----
buf = bytearray()
pid, fd = spawn(pane, binary, out)
drain(fd, 0.8, buf)
before = last_status(buf)
os.write(fd, b"\x1b[<64;1;1M")            # wheel_up (b=64 => b&64 wheel, b&1==0 => up)
drain(fd, 0.3, buf)
after = last_status(buf)
reap(pid, fd)
if before is None or after is None:
    sys.exit("FAIL: (c) no status line captured (%s -> %s)" % (before, after))
# Cursor starts at the bottom (last row). wheel_up scrolls the viewport toward history top; the
# cursor clamps into the new (higher) viewport => status row: DECREASES. Needs scrollback>viewport
# (seeded ~30 lines > grid_rows 23) or scroll is pinned at 0 and wheel is a no-op.
if not (after[0] < before[0]):
    sys.exit("FAIL: (c) wheel_up did NOT scroll (row: %s -> %s) — mouse IGNORED" % (before, after))

sys.exit(0)   # all three mouse assertions passed
PYEOF

echo "PASS: region mouse — click moves cursor, drag→confirm writes file, wheel scrolls (Issue 1 / §7.6)"
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: CREATE tests/region_mouse.sh (the verbatim script above)
  - WRITE the full file (Blueprint §"exact deliverable") with execute permission (chmod +x optional;
    the harness is invoked via `sh tests/region_mouse.sh`, matching the siblings).
  - MIRROR region_empty_confirm.sh for the shell skeleton (set -u / cd / fail / SKIP / SOCK / WORK /
    shim / trap) and region_signal_keys.sh for the python helpers (drain/wait_exit/spawn/last_*).
  - GOTCHA A: pane -x 80 -y 10 (NOT the item's 25x8 — tiny panes hang region's event loop).
  - GOTCHA B: spawn() sets TIOCSWINSZ 24x80 + SIGWINCH (the 0x0-winsize CI-hang fix).
  - GOTCHA C: seed ~30 marker lines (`yes "MOUSEMK line" | head -30`) so scrollback > grid_rows(23).
  - GOTCHA D: os.waitstatus_to_exitcode (NEVER the `>>` bit-shift token).
  - GOTCHA E: reap() after the non-exiting drives (a) and (c); wait_exit() for drive (b).
  - WHY ONE TASK: it is a single self-contained file; the three assertions are independent drives
    in one heredoc, each a true regression detector (findings.md §6).

Task 2: VALIDATE (see Validation Loop)
  - RUN: sh -n tests/region_mouse.sh                       # parses clean
  - RUN: sh tests/region_mouse.sh                          # PASS, exit 0 (needs P1.M2.T2.S1 binary)
  - RUN: sh scripts/check-safety.sh --paths tests/region_mouse.sh   # THIS file: 0 FAIL, 0 WARN
  - RUN: sh scripts/preflight.sh                           # clean
  - RUN: the FAIL-before proof (Level 3)                   # exit 1 on the pre-fix binary
```

### Implementation Patterns & Key Details

```sh
# PATTERN: three independent pty drives, one fresh spawn() each (mirrors region_signal_keys.sh a/b/c).
#   Mouse does not exit the TUI, so (a) and (c) reap() after asserting; (b) exits on Enter.

# PATTERN: status-line parsing via re.findall (last match = most recent paint). view.zig:241 emits
#   "row:{d} col:{d}" (1-based). last_status() returns (row, col) or None.
rows = re.findall(rb'row:(\d+)', bytes(buf)); cols = re.findall(rb'col:(\d+)', bytes(buf))

# PATTERN: the SGR bytes are VERIFIED against app.zig's decoder — they are not guesses:
#   \x1b[<0;15;2M  => b=0(left), M => press     @ (15,2)
#   \x1b[<32;2;4M  => b=32(motion|left), M => drag @ (2,4)
#   \x1b[<0;2;4m   => b=0, m => release         @ (2,4)
#   \x1b[<64;1;1M  => b=64(b&64 wheel, b&1==0 => up)

# CRITICAL: the assertions are keyed to USER-VISIBLE effects (status row:/col: change, file written),
#   so they fail identically when regionHandle DROPS .mouse (pre-fix) and pass when it consumes it.
```

### Integration Points

```yaml
CI / TEST SUITE:
  - tests/region_mouse.sh joins the 5 existing harnesses (envelope_smoke, plugin_options,
    region_empty_confirm, region_signal_keys, zero_dimension_reject). It is invoked the same way
    (`sh tests/region_mouse.sh`) and SKIPs cleanly where tmux/python3 are absent.

CONSUMED (contract — do NOT modify):
  - P1.M2.T2.S1's .mouse arm in src/region.zig (applyMouse + repaint + return .none). This harness
    only EXERCISES it via the real binary; it never imports/edits region.zig.
  - src/tui/app.zig's SGR decoder (parseMousePayload/decodeMouse) — the bytes are matched to it.
  - src/tui/view.zig:241 status format ("row:{d} col:{d}") — the regexes are matched to it.

SAFETY GATES (run-only):
  - scripts/check-safety.sh: tests/region_mouse.sh must be 0 FAIL/0 WARN on its own (--paths); the file adds no repo-wide violation (the 1 pre-existing FAIL is in a sibling doc, not ours).
  - scripts/preflight.sh: must report clean (no giant files / residue).

CONFIG / DATABASE / ROUTES / BUILD:
  - none. Pure test-harness addition.
```

## Validation Loop

> This task creates a TEST HARNESS, not product code. The PRIMARY gate is `sh tests/region_mouse.sh`
> ⇒ PASS (exit 0) on a P1.M2.T2.S1-applied binary, PLUS the FAIL-before proof that it catches the
> bug. `zig build test` is unchanged (no `.zig` edit) but run for sanity.

### Level 1: Syntax & Style (Immediate Feedback)

```bash
cd /home/dustin/projects/tmux-2html
sh -n tests/region_mouse.sh && echo "region_mouse.sh parses OK"

# Safety guard (AGENTS.md §3) — deterministic; this file must stay clean:
sh scripts/check-safety.sh
# THIS task's gate (isolated — the new file must be clean on its own):
sh scripts/check-safety.sh --paths tests/region_mouse.sh
# Expected: "== result: 0 FAIL(s), 0 WARN(s) ==" and exit 0. If non-zero, you used the raw `>>` token
#   (Gotcha D) or an inline recursive shim (Gotcha F): switch to os.waitstatus_to_exitcode and keep
#   the exec in the generated $WORK/shim/tmux only.
# (Repo-wide `sh scripts/check-safety.sh` currently reports 1 PRE-EXISTING FAIL in a SIBLING task's
#  committed research doc — P1M1T2S1/research/findings.md:91, prose 'NEVER kill-server' trips R1 —
#  unowned by this task. Confirm your work does not change it: the FAIL count must not rise above
#  that pre-existing 1, and tests/region_mouse.sh must NOT appear in any FAIL/WARN line.)
```

### Level 2: The harness itself (PRIMARY gate)

```bash
# Needs the P1.M2.T2.S1 .mouse arm in the binary. Build it if stale:
zig build -Doptimize=ReleaseFast || zig build --release=fast

sh tests/region_mouse.sh
# Expected: "PASS: region mouse — click moves cursor, drag→confirm writes file, wheel scrolls …"
#   and exit 0. Covers all three drives: (a) col increase, (b) exit 0 + file + marker, (c) row decrease.
#
# Diagnostics:
#   "SKIP: tmux/python3 not installed" => the runner lacks a tool; that is a clean SKIP (exit 0), not a fail.
#   "FAIL: (a) click did NOT move cursor col" => the .mouse arm is absent or applyMouse press didn't
#      move the cursor (P1.M2.T2.S1 not applied/merged) — the expected PRE-FIX result.
#   "FAIL: (a) no status line captured" => the TUI never painted => likely forgot the TIOCSWINSZ
#      winsize fix (Gotcha B) or used a tiny pane (Gotcha A).
#   "FAIL: (c) wheel_up did NOT scroll" + you DID seed ~30 lines => scroll math issue; if you seeded
#      FEWER than 24 lines, scrollback <= grid_rows(23) and wheel is legitimately a no-op (Gotcha C).
```

### Level 3: FAIL-before proof (the test is a genuine detector, not a tautology)

```bash
# Prove the harness catches the bug: temporarily disable the .mouse arm in region.zig, rebuild, run.
# (P1.M2.T2.S1's arm is `switch (ev) { .mouse => |m| { applyMouse(...); repaint(ctx) catch {};
#  return .none; }, else => {} }` — comment the applyMouse+repaint lines, leaving just `else => {}`
#  so mouse falls through to input.feed which drops it.)

zig build -Doptimize=ReleaseFast
sh tests/region_mouse.sh; echo "exit=$?"
# Expected: exit 1 (FAIL) — at minimum drive (a): "click did NOT move cursor col … mouse IGNORED".
#   (Drives (b) and (c) also fail on the pre-fix binary: (b) no selection => Enter exits 1, no file;
#    (c) wheel ignored => row: unchanged.)
# Then RESTORE the .mouse arm, rebuild, re-run => exit 0. This confirms the harness is a real
# regression detector (findings.md §6).

# All OTHER shipped harnesses stay GREEN (this task touches no product code):
for t in tests/*.sh; do [ "$t" = "tests/region_mouse.sh" ] && continue; sh "$t" >/dev/null 2>&1 \
  && echo "PASS $t" || echo "FAIL/SKIP $t"; done

# And the unit suite is unchanged (no .zig edit by THIS task):
zig build test -Doptimize=ReleaseFast   # exit 0
```

### Level 4: Scope boundary + final hygiene (Domain Validation)

```bash
# ONLY tests/region_mouse.sh is added; no .zig / plugin / build / docs / other-tests changes:
git status --short             # expect: ?? tests/region_mouse.sh  (and nothing else from this task)
git diff --stat -- 'src/*.zig' 'tmux-2html.tmux' build.zig README.md docs/  # expect: no output

# The three SGR drives + helpers are all present:
grep -c 'last_status' tests/region_mouse.sh          # expect: >=1 (status parser)
grep -c '\\x1b\[<' tests/region_mouse.sh             # expect: >=4 (press/motion/release/wheel bytes)
grep -c 'waitstatus_to_exitcode' tests/region_mouse.sh   # expect: >=1 (NOT `>>`)
grep -n 'kill-session -t s' tests/region_mouse.sh    # expect: scoped teardown (never kill-server)

# Final hygiene (AGENTS.md §2/§3) — run after the test:
sh scripts/preflight.sh      # expect: no giant files, no residue, exit 0
```

## Final Validation Checklist

### Technical Validation

- [ ] `sh -n tests/region_mouse.sh` parses clean (Level 1).
- [ ] `sh scripts/check-safety.sh --paths tests/region_mouse.sh` ⇒ `0 FAIL, 0 WARN`, exit 0; the repo-wide scan is unchanged by this file (Level 1).
- [ ] `sh scripts/preflight.sh` ⇒ clean (Level 4).
- [ ] `zig build test -Doptimize=ReleaseFast` ⇒ exit 0 (no `.zig` edit; sanity only).

### Feature Validation

- [ ] `sh tests/region_mouse.sh` ⇒ PASS, exit 0 on a P1.M2.T2.S1-applied binary (Level 2 — primary gate).
- [ ] FAIL-before proof: disabling the `.mouse` arm makes the harness exit 1 (Level 3).
- [ ] Drive (a): click ⇒ status `col:` increases. Drive (b): drag+Enter ⇒ exit 0 + file with marker.
      Drive (c): wheel_up ⇒ status `row:` decreases.
- [ ] SKIPs cleanly (exit 0) when `tmux` or `python3` is absent.

### Code Quality Validation

- [ ] Shell skeleton mirrors `region_empty_confirm.sh` (set -u/cd/fail/SKIP/SOCK/WORK/shim/trap).
- [ ] Python helpers mirror `region_signal_keys.sh` (drain/wait_exit/spawn + `waitstatus_to_exitcode`).
- [ ] winsize+SIGWINCH set in `spawn()` (Gotcha B); pane is 80×10 (Gotcha A); ~30 markers seeded (Gotcha C).
- [ ] SGR bytes match `app.zig`'s decoder; status regexes match `view.zig:241`.
- [ ] Teardown is scoped `kill-session -t s` on `-L "$SOCK"`; never `kill-server`/`pkill` (Gotcha G).

### Documentation & Deployment

- [ ] No docs change here (the changeset-level README/CONFIGURATION mouse text is P1.M3.T1.S1).
- [ ] Harness header comment explains what it tests + the PRD §0 safety posture.

---

## Anti-Patterns to Avoid

- ❌ Don't use a tiny pane (`-x 25 -y 8` as the item suggested) — `region_empty_confirm.sh` PROVEN tiny
  panes hang region's event loop. Use `-x 80 -y 10` (the "mirror EXACTLY" canonical size). (Gotcha A.)
- ❌ Don't omit the `TIOCSWINSZ`+`SIGWINCH` in `spawn()` — under a 0×0 CI parent region never services
  input and `waitpid` hangs the job for hours. Copy `region_empty_confirm.sh`'s fix. (Gotcha B.)
- ❌ Don't seed fewer than ~24 marker lines — the wheel test needs `scrollback > grid_rows(23)` or
  `viewport.scroll` is pinned at 0 and wheel is a legitimate no-op (false FAIL). Seed ~30. (Gotcha C.)
- ❌ Don't use `st >> 8` (or any raw `>>` bit-shift) for the exit code — this file has `PATH="$SHIM:$PATH"`,
  so check-safety R3 (PATH-prepend + `>>`/`exec` sink in ONE file) FAILS. Use `os.waitstatus_to_exitcode`. (Gotcha D.)
- ❌ Don't forget to `reap()` the child after the non-exiting drives (a)/(c) — mouse doesn't exit the TUI,
  so an un-reaped pty hangs CI. Send `q` + SIGKILL-fallback + `waitpid`. (Gotcha E.)
- ❌ Don't inline a recursive `exec tmux` or a `>> calls.log` in `region_mouse.sh` — keep the `exec` in
  the generated `$WORK/shim/tmux` (separate file) so check-safety R3 doesn't fire. Use the approved shim. (Gotcha F.)
- ❌ Don't tear down with `kill-server`/`killall`/`pkill` — scoped `kill-session -t s` on `-L "$SOCK"` only. (Gotcha G; PRD §0.)
- ❌ Don't touch `region.zig`, the other `tests/*.sh`, the plugin, build files, README, or CONFIGURATION.md
  — this is a single new test file. The `.mouse` arm is P1.M2.T2.S1; the docs are P1.M3.T1.S1.
- ❌ Don't assert on internal state — assert on the USER-VISIBLE status line (`row:`/`col:`) and the
  written file, so the test fails identically when mouse is dropped (pre-fix) regardless of internals.
- ❌ Don't reuse a single `spawn()` across drives — each drive needs a fresh `region` invocation (the
  prior drive either exited (b) or was reaped (a)/(c)). Mirror `region_signal_keys.sh`'s 3-spawn structure.

---

**Confidence Score: 9/10** for one-pass implementation success.

The entire deliverable is ONE file given verbatim, adapted from two CI-green sibling harnesses
(`region_empty_confirm.sh` for the shell skeleton + winsize fix; `region_signal_keys.sh` for the
python helpers + 3-drive structure + `waitstatus_to_exitcode`). Every load-bearing fact is verified
against source: the SGR byte table against `app.zig`'s `decodeMouse`/`parseMousePayload`
(b&64⇒wheel, b&32⇒motion, b&3⇒button, `M`/`m`⇒press/release); the status-line substrings against
`view.zig:241` (`row:{d} col:{d}`, 1-based, with a unit test at :727); and the click/drag/wheel
semantics against `architecture/mouse_wiring_design.md`'s `applyMouse` spec (press moves cursor +
clears sel; motion extends a linewise/alt-block selection; release finalizes; wheel=halfPage+clamp).
The three assertions are deterministic USER-VISIBLE effects (col increase, file+marker, row decrease),
each a proven FAIL-before/PASS-after detector (findings.md §6). The four non-obvious traps — tiny-pane
hang (⇒80×10), 0×0-winsize CI-hang (⇒TIOCSWINSZ+SIGWINCH), scrollback≤viewport wheel no-op
(⇒seed ~30 lines), and the `>>`-token check-safety R3 trip (⇒`waitstatus_to_exitcode`) — are all
called out with the exact fix copied from a proven sibling. The file stays check-safety-clean by
construction (approved separate-file shim, scoped `kill-session`, no `>>` sink in `region_mouse.sh`).
The 1-point residual risk is pty timing flake on a slow CI runner (mitigated by generous 0.8/0.25/0.3s
drains matching the siblings, and a bounded `wait_exit`+SIGKILL that can never hang); if a drive is
flaky, bumping the post-event drain by 0.1–0.2s fixes it without touching the logic.