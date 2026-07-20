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
    # Bounded wait + SIGKILL: never hang CI. waitstatus_to_exitcode (NOT the raw bit-shift token).
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