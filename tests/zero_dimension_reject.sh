#!/bin/sh
# tests/zero_dimension_reject.sh — Issue 2 regression: render --cols 0 / --rows 0 must NOT
# segfault (exit 139). Before the S1/S2 guards, an explicit zero dimension flowed into
# Terminal.init(.{ .cols = 0, .rows = 0 }) and the vendored ghostty-vt segfaulted (core dump).
# Now determineCols (render.zig:97) and run() (render.zig:761) reject it with exit 2 +
# "tmux-2html render: cannot determine terminal size" on stderr (PRD §5 exit codes; §0.1
# "prefer graceful failure"). This locks that in: a future change that drops either guard
# reintroduces exit 139 and FAILS this test.
#
# No tmux, no python3, no pty needed — just `render` reading piped stdin. Runs anywhere the
# release binary builds; check-safety clean (no PATH shim, no kill-server, no append log).
#
# Run:  sh tests/zero_dimension_reject.sh    # -> PASS, exit 0 (needs the S1+S2 fixes)
set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO"
BIN=./zig-out/bin/tmux-2html

fail() { echo "FAIL: $*" >&2; exit 1; }

if [ ! -x "$BIN" ]; then
    echo "building release binary..."
    zig build -Doptimize=ReleaseFast || fail "zig build failed"
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/t2h-zero.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# assert_reject <label> <want_stderr_substring_or_empty> -- <render args...>
# Pipes 'x\n' into render; asserts: exit non-zero, NOT 139 (SIGSEGV), and EMPTY stdout.
# If <want> is non-empty, also asserts that substring appears on stderr (graceful error path).
assert_reject() {
    label="$1"; want="$2"; shift 3   # shift past label, want, and the '--' separator
    out="$WORK/o"; err="$WORK/e"
    printf 'x\n' | "$BIN" render "$@" >"$out" 2>"$err"
    rc=$?
    [ "$rc" -ne 0 ]   || fail "$label: expected non-zero exit, got 0 (zero-dim accepted => guard missing, Issue 2)"
    [ "$rc" -ne 139 ] || fail "$label: exit 139 = SIGSEGV (zero-dim segfault regressed, Issue 2)"
    [ ! -s "$out" ]   || fail "$label: stdout not empty (partial render leaked bytes)"
    if [ -n "$want" ]; then
        grep -qF "$want" "$err" || fail "$label: stderr missing expected message ('$want')"
    fi
    echo "  $label: exit $rc, empty stdout$([ -n "$want" ] && echo ', stderr msg ok')"
}

# --- the three PRD Issue 2 repro cases (all were exit 139 SIGSEGV before S1/S2) ---
MSG="cannot determine terminal size"
assert_reject "--cols 0"              "$MSG" -- --cols 0
assert_reject "--cols 5 --rows 0"     "$MSG" -- --cols 5 --rows 0
# determineCols fires BEFORE the --selection arm, so the same exit/stdout contract holds;
# message assertion skipped here to stay robust to selection-path wording.
assert_reject "--cols 0 --selection"  ""     -- --cols 0 --selection 0,0,0,0

# --- boundary: the guard must NOT over-reject valid dimensions (exit 0) ---
printf 'x\n' | "$BIN" render --cols 1          >/dev/null 2>&1 || fail "--cols 1 wrongly rejected (guard over-fires)"
printf 'x\n' | "$BIN" render --cols 5 --rows 1 >/dev/null 2>&1 || fail "--cols 5 --rows 1 wrongly rejected"
printf 'x\n' | "$BIN" render --cols 5          >/dev/null 2>&1 || fail "omitted --rows wrongly rejected (lineCount default)"
echo "  boundary: cols=1, rows=1, omitted-rows all accepted (exit 0)"

echo "PASS: render rejects zero dimensions with a non-zero/non-139 exit + empty stdout (Issue 2 segfault closed)"