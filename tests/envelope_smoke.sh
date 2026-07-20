#!/bin/sh
# tests/envelope_smoke.sh — §8.1 end-to-end integration smoke (PRD §0: isolated tmux only).
#
# Drives the REAL ./zig-out/bin/tmux-2html through every HTML output path and asserts each
# emits a COMPLETE §8.1 document (<!DOCTYPE html> … </html>), never a bare <pre> fragment,
# with correct <title> (escaped) / <html lang> / page-bg. Covers:
#   render: stdout, --output, --open->temp, --selection linewise + block, --title/--lang, C-locale->en
#   pane:   --visible, --full      (against an ISOLATED, uniquely-named tmux server)
#   region: confirm (programmatic, via python3 pty — SKIPped if python3 absent)
#
# PRD §0 SAFETY: creates its OWN `tmux -L tmux-2html-smoke-$$` server via a PATH shim that
# intercepts EVERY tmux call the binary makes, and tears down ONLY that named session
# (`kill-session -t test`). NEVER kill-server/killall/pkill. SKIPs cleanly (exit 0) if tmux
# is absent, so it is safe to add to any CI runner.
#
# Run:  sh tests/envelope_smoke.sh      # -> PASS, exit 0
set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO"
BIN=./zig-out/bin/tmux-2html

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- prerequisites -----------------------------------------------------------
if ! command -v tmux >/dev/null 2>&1; then
    echo "SKIP: tmux not installed (integration smoke needs an isolated tmux server)"
    exit 0
fi
REAL_TMUX=$(command -v tmux)

if [ ! -x "$BIN" ]; then
    echo "building release binary..."
    zig build -Doptimize=ReleaseFast || fail "zig build failed"
fi

have_py=0
command -v python3 >/dev/null 2>&1 && have_py=1

# --- §8.1 document-completeness assertion -----------------------------------
# Starting with <!DOCTYPE html> proves the output is a COMPLETE document, NOT a bare fragment
# (a fragment would start with <pre or <span). Plus the required envelope markers + </html> tail.
check_doc() {
    f=$1
    [ -s "$f" ] || fail "check_doc: $f missing or empty"
    head -c 15 "$f" | grep -q '^<!DOCTYPE html>' || fail "$f: not a complete doc (no <!DOCTYPE html> first -> bare fragment?)"
    grep -q '<html lang=' "$f"                 || fail "$f: missing <html lang="
    grep -q '<meta charset="utf-8">' "$f"      || fail "$f: missing <meta charset=utf-8> (charset-first)"
    grep -q '<pre class="term2html-output"' "$f" || fail "$f: missing <pre class=term2html-output>"
    grep -q '</pre>' "$f"                      || fail "$f: missing </pre>"
    tail -c 12 "$f" | grep -q '</html>'        || fail "$f: does not end with </html>"
}

W=$(mktemp -d "${TMPDIR:-/tmp}/t2h-smoke.XXXXXX")
trap 'rm -rf "$W"' EXIT

# --- RENDER paths (stdin -> stdout/file; no tmux) ----------------------------
ANSI=$W/red.ansi
printf '\033[31mRED\033[0m normal\n' > "$ANSI"

# (1) stdout: complete doc + red color span + default title
"$BIN" render --cols 40 --rows 3 --palette default < "$ANSI" > "$W/r_stdout.html" || fail "render stdout"
check_doc "$W/r_stdout.html"
grep -q 'color: #cc6666' "$W/r_stdout.html"    || fail "render stdout: red color span missing"
grep -q '<title>tmux-2html</title>' "$W/r_stdout.html" || fail "render stdout: default title"

# (2) --title escaped + --lang attribute
"$BIN" render --cols 40 --rows 3 --palette default --title 'A&B<c>' --lang pt-BR < "$ANSI" > "$W/r_title.html" || fail "render --title/--lang"
check_doc "$W/r_title.html"
grep -q '<title>A&amp;B&lt;c&gt;</title>' "$W/r_title.html" || fail "render: --title not HTML-escaped"
grep -q '<html lang="pt-BR">' "$W/r_title.html" || fail "render: --lang attr wrong/missing"

# (3) forced C locale -> lang="en" (deterministic; explicit override not given)
env -i LC_ALL=C LANG=C PATH="$PATH" HOME="$HOME" "$BIN" render --cols 20 --rows 1 --palette default < "$ANSI" > "$W/r_c.html" || fail "render C-locale"
grep -q '<html lang="en">' "$W/r_c.html" || fail "C/empty locale must yield lang=en"

# (4) --output FILE
"$BIN" render --cols 40 --rows 3 --palette default --output "$W/r_out.html" < "$ANSI" || fail "render --output"
check_doc "$W/r_out.html"

# (5) --open -> temp under TMPDIR (xdg-open best-effort, ignored if absent)
TW=$W/tmpopen; mkdir -p "$TW"
TMPDIR="$TW" "$BIN" render --cols 40 --rows 3 --palette default --open < "$ANSI" >/dev/null 2>&1 || true
TOF=$(ls "$TW"/tmux-2html-*.html 2>/dev/null | head -1)
[ -n "$TOF" ] || fail "render --open: no temp html under TMPDIR"
check_doc "$TOF"

# (6) --selection linewise
printf 'line1\nline2\nline3\n' | "$BIN" render --cols 10 --rows 3 --palette default --selection 0,0,9,1 > "$W/r_sel.html" || fail "render --selection linewise"
check_doc "$W/r_sel.html"

# (7) --selection block (rect=1)
printf 'AAAA\nBBBB\nCCCC\n' | "$BIN" render --cols 4 --rows 3 --palette default --selection 0,0,1,2,1 > "$W/r_selb.html" || fail "render --selection block"
check_doc "$W/r_selb.html"
echo "  render: 7/7 paths emit complete §8.1 documents (title/lang/bg correct)"

# --- PANE paths (ISOLATED tmux server via PATH shim) -------------------------
SOCK="tmux-2html-smoke-$$"
SHIM=$W/shim; mkdir -p "$SHIM"
printf '#!/bin/sh\nexec "%s" -L "%s" "$@"\n' "$REAL_TMUX" "$SOCK" > "$SHIM/tmux"
chmod +x "$SHIM/tmux"
"$REAL_TMUX" -L "$SOCK" new-session -d -s test -x 80 -y 10 || fail "isolated tmux new-session"
# Normalize the prompt to a minimal portable form BEFORE seeding content. Without this the
# captured grid's layout — and therefore where the region TUI's copy-mode cursor rests — depends
# on the host's DEFAULT shell/prompt (ubuntu CI bash `$ ` vs e.g. a Starship/Powerlevel multiline
# prompt). That layout dependence is the root cause of the F1 region-confirm flake (validation
# report 2026-07-20): on hosts with a multiline prompt the cursor landed on a blank row, `v`
# began a linewise selection of empty cells, and the Issue-1 "selection is empty" guard rejected
# the confirm (exit 1, no file). `PS1='$ '` collapses every shell to the same single-line prompt
# so the grid is deterministic (mirrors tests/region_empty_confirm.sh's `PS1=''` technique).
"$REAL_TMUX" -L "$SOCK" send-keys -t test "PS1='$ '" Enter
"$REAL_TMUX" -L "$SOCK" send-keys -t test "printf '\\033[31mRED\\033[0m pane-content'" Enter
# Wait until tmux has actually painted the printf OUTPUT before capturing. Replaces a flaky
# fixed `sleep 0.5`: under CI load the capture could fire before the shell ran printf, so
# capture-pane saw no color and "--visible: red color span missing" failed. "RED pane-content"
# (with the space) appears ONLY in the rendered output — the echoed command line has a literal
# '\033[0m' between RED and pane-content, so it can never match this substring.
deadline=$(( $(date +%s) + 5 ))
until "$REAL_TMUX" -L "$SOCK" capture-pane -p -t test | grep -q 'RED pane-content'; do
  [ "$(date +%s)" -ge "$deadline" ] && fail "tmux never painted 'RED pane-content' output"
  sleep 0.1
done
PANE=$("$REAL_TMUX" -L "$SOCK" list-panes -t test -F '#{pane_id}' | head -1)

# pane --visible
PATH="$SHIM:$PATH" TMUX_PANE="$PANE" "$BIN" pane --visible --output "$W/p_vis.html" >/dev/null 2>&1 || fail "pane --visible"
check_doc "$W/p_vis.html"
grep -q 'color: #cc6666' "$W/p_vis.html" || fail "pane --visible: red color span missing"

# pane --full
PATH="$SHIM:$PATH" TMUX_PANE="$PANE" "$BIN" pane --full --output "$W/p_full.html" >/dev/null 2>&1 || fail "pane --full"
check_doc "$W/p_full.html"
echo "  pane:   2/2 paths emit complete §8.1 documents (against isolated tmux)"

# --- REGION confirm (programmatic, via python3 pty) --------------------------
if [ "$have_py" -eq 0 ]; then
    echo "  region: SKIP (python3 absent — render --selection covers the same render path)"
else
    ROF=$W/region.html; rm -f "$ROF"
    PATH="$SHIM:$PATH" python3 - "$PANE" "$ROF" <<'PYEOF' || fail "region confirm pty drive"
import os, pty, select, sys, time, signal, struct, fcntl, termios
pane, out = sys.argv[1], sys.argv[2]
pid, fd = pty.fork()
if pid == 0:
    os.execvpe("./zig-out/bin/tmux-2html",
               ["tmux-2html", "region", "--target", pane, "--output", out],
               os.environ.copy())
else:
    # pty.fork() leaves the pty window size at 0x0. region's TUI still paints (default size)
    # but its input loop then NEVER services keys — the TUI sits idle and a blocking
    # waitpid hangs the job for hours. That is what hung CI runs 29755955109 / 29762462640 /
    # 29764587186 (a non-interactive CI parent yields 0x0). Set a real size + raise SIGWINCH
    # so the event loop starts reading input. Verified: without this region ignores even `q`.
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
    os.kill(pid, signal.SIGWINCH)
    time.sleep(0.8)           # let the TUI paint
    # `v` RE-ANCHORS a linewise selection but leaves it ZERO-extent; extend it by MOVING
    # (src/tui/select.zig). region enters copy-mode AT THE BOTTOM (src/region.zig), so go
    # to the top (gg), begin (v), jump to the bottom (G) -> whole-pane non-empty selection
    # (contains the colored content). Without the post-`v` motion the Issue-1 empty guard
    # rejects it.
    for key in (b"gg", b"v", b"G", b"\r"):
        os.write(fd, key)
        time.sleep(0.2)
    # BOUNDED wait + SIGKILL: even if region never exits for any reason, FAIL in ~10s
    # instead of hanging the job for 6h. Replaces the old blocking os.waitpid(pid, 0).
    deadline = time.time() + 10
    exited = False
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try:
                os.read(fd, 4096)
            except OSError:
                break
        wpid, _ = os.waitpid(pid, os.WNOHANG)
        if wpid != 0:
            exited = True
            break
    if not exited:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
        sys.exit("region: timed out (did not exit after gg/v/G/Enter)")
    if not os.path.exists(out):
        sys.exit("region: no output file written (confirm did not fire)")
PYEOF
    check_doc "$ROF"
    echo "  region: 1/1 confirm emits a complete §8.1 document (via python3 pty)"
fi

# --- teardown: ONLY the named isolated session (PRD §0 — never kill-server) --
"$REAL_TMUX" -L "$SOCK" kill-session -t test 2>/dev/null || true

echo "PASS: §8.1 end-to-end — every output path is a complete document (title/lang/bg correct; zero bare fragments)"
