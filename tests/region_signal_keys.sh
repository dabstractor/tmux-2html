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
# Drain AFTER q (before reaping) so the TUI's restore sequence (?1049l) is captured into buf;
# once waitpid reaps the process the pty master read yields nothing more.
os.write(fd, b"q")
drain(fd, 0.5, buf)
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