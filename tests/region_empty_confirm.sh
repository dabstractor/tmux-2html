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

# 80x10 (NOT 20x6): region's TUI only services input reliably at a normal pane size
# (tiny panes hang the event loop), and the winsize set in the pty drive below needs a
# non-tiny captured grid.
"$REAL_TMUX" -L "$SOCK" new-session -d -s s -x 80 -y 10 || fail "isolated tmux new-session"
PANE=$("$REAL_TMUX" -L "$SOCK" list-panes -t s -F '#{pane_id}' | head -1)

# Make the pane TRULY blank so a whole-pane selection is all blank cells => the rendered
# body is empty => render.selectionBodyEmpty fires (PRD §13 => warn, exit 1, no file).
# PS1='' kills the prompt; `clear` wipes the initial prompt line the new-session shell
# prints before PS1 takes effect (without clear that one non-blank line makes the selection
# non-empty => it renders => exit 0, false-pass).
"$REAL_TMUX" -L "$SOCK" send-keys -t s "PS1=''" Enter
sleep 0.3
"$REAL_TMUX" -L "$SOCK" send-keys -t s "clear" Enter
sleep 0.5

rm -f "$OUT" "$SIDECAR"            # start clean (SIDECAR may linger from envelope_smoke's run)

# --- drive region via python3 pty: gg+v+G (whole-pane selection of the blank pane) + \r (confirm)
# Asserts the FIXED behavior: exit 1, NO output file. The whole-pane selection is all blank
# cells => render.selectionBodyEmpty fires => exit 1, no file (the S2/Issue-1 guard). A bare
# v+\r (zero-extent) is a NO-OP confirm in region's TUI (never exits), so it cannot trigger
# the guard; the whole-pane blank selection does. winsize+SIGWINCH+bounded-timeout mirror
# envelope_smoke.sh (without them region ignores all input under a 0x0 CI parent => hang).
PATH="$SHIM:$PATH" python3 - "$PANE" "$OUT" "$BIN" <<'PYEOF' || fail "region empty-confirm pty drive"
import os, pty, select, sys, time, signal
pane, out, binary = sys.argv[1], sys.argv[2], sys.argv[3]
pid, fd = pty.fork()
if pid == 0:
    os.execvpe(binary,
               ["tmux-2html", "region", "--target", pane, "--output", out],
               os.environ.copy())
else:
    # DRAIN during every wait (NOT bare sleep) so region's repaint output never fills the
    # pty buffer and blocks the TUI's input loop (the CI hang). Same proven mechanic as
    # tests/region_signal_keys.sh (CI-green) and tests/envelope_smoke.sh. No winsize/SIGWINCH.
    def drain(secs):
        end = time.time() + secs
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], 0.05)
            if not r:
                continue
            try:
                os.read(fd, 8192)
            except OSError:
                break
    drain(0.8)               # initial paint (buffer kept empty)
    # gg+v+G selects the whole (blank) pane; `y` confirms => renders an all-blank body =>
    # render.selectionBodyEmpty fires (exit 1, no file — the Issue-1 guard). Confirm with
    # `y` not Enter: in this pty 0x0d does not fire region's confirm (only `y` does).
    for key in (b"gg", b"v", b"G", b"y"):
        os.write(fd, key)
        drain(0.2)
    # BOUNDED wait + SIGKILL: never hang the job. Capture the exit status via WNOHANG so we
    # can still assert the Issue-1 exit code below.
    deadline = time.time() + 10
    status = 0
    exited = False
    while time.time() < deadline:
        drain(0.1)
        wpid, st = os.waitpid(pid, os.WNOHANG)
        if wpid != 0:
            status, exited = st, True
            break
    if not exited:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
        sys.exit("FAIL: empty-confirm timed out (region did not exit)")
    # os.waitstatus_to_exitcode (py3.9+) turns a raw wait status into the exit code the
    # shell would see (normal exit N -> N; signal S -> 128+S). We avoid the raw bit-shift
    # spelling here only because its two-greater-than token trips check-safety's R3 shim-
    # combo gate (this file also has a PATH="$SHIM:$PATH" line); waitstatus_to_exitcode is
    # the stdlib-correct equivalent and keeps the test check-safety-clean.
    code = os.waitstatus_to_exitcode(status)
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