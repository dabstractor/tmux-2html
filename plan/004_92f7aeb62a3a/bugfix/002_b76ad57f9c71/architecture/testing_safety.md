# Testing Strategy & Safety Constraints

## Hard safety rules (AGENTS.md + PRD §0/§0.1 — NORMATIVE)
- **NEVER** touch the user's running tmux. No kill-server / killall tmux / pkill tmux / pkill -f tmux.
- Integration harnesses create an **isolated, uniquely-named** server: `tmux -L "t2h-<tag>-$$"`.
- Teardown is by **named session** on that socket ONLY: `tmux -L "$SOCK" kill-session -t s`
  (in a `trap … EXIT`). NEVER a bare `kill-server`.
- `/tmp` is tmpfs (RAM) — put scratch on real disk (repo-local `scratch/` or a `$TMPDIR`-on-disk
  `mktemp -d`); do NOT spill large artifacts to `/tmp`.
- **NEVER hand-roll a `tmux` PATH shim** that recurses or uses unbounded `>>` logs. The repo's
  approved pattern (tests/region_empty_confirm.sh) uses a PATH shim that `exec`s the **absolute**
  REAL_TMUX with `-L $SOCK` prefixed, NO append log ⇒ check-safety clean. For any tmux-call
  interception prefer `scripts/with-tmux-audit.sh`.
- Wrap potentially-runaway commands with `scripts/safe-run.sh` (RLIMIT_FSIZE + RLIMIT_CPU).
- Run `scripts/check-safety.sh` before committing + after editing shell; `scripts/preflight.sh`
  after a test run. Run builds/tests/large scans **ONE AT A TIME** (no parallel heavy steps).

## Build / test commands
- Build the binary: `zig build --release=fast` (or `-Doptimize=ReleaseFast`).
- Unit tests: `zig build test -Doptimize=ReleaseFast` (Debug hits a Zig linker bug — MUST be
  ReleaseFast; 275 test fns). This is the CI gate (.github/workflows/ci.yml test job).
- check-safety.sh runs in CI regardless; `git config core.hooksPath scripts/hooks` enables local
  pre-commit (check-safety) + pre-push (ReleaseFast test) hooks (advisory, bypassable).

## Canonical integration-harness pattern (tests/region_empty_confirm.sh)
Every new harness in `tests/` MUST follow this exact shape:
1. `set -u`; `cd` to repo root; `BIN=./zig-out/bin/tmux-2html`.
2. SKIP cleanly (`exit 0`) if `tmux` or `python3` is absent (so CI runners without them pass).
3. `REAL_TMUX=$(command -v tmux)`.
4. Build the release binary if missing: `zig build -Doptimize=ReleaseFast`.
5. Isolated socket `SOCK="t2h-<tag>-$$"`; `WORK=$(mktemp -d …)` on real disk; unique `$OUT`.
6. **PATH shim**: a tiny `shim/tmux` script `exec "$REAL_TMUX" -L "$SOCK" "$@"` (absolute path,
   no recursion, no log). Export `PATH="$SHIM:$PATH"` for the binary + python drive.
7. `tmux -L "$SOCK" new-session -d -s s -x W -y H`; `PANE=$(tmux -L "$SOCK" list-panes … | head -1)`.
8. Seed content via `tmux -L "$SOCK" send-keys -t s "…" Enter; sleep`.
9. `trap '"$REAL_TMUX" -L "$SOCK" kill-session -t s 2>/dev/null; rm -rf "$WORK"' EXIT`.
10. **python3 pty drive**: `pty.fork()` → child `os.execvpe(binary, ["…","region","--target",pane,…], env)`;
    parent sleeps, `os.write(fd, b"<keys/SGR-mouse>")`, drains via `select`+`os.read`, `os.waitpid`,
    `os.waitstatus_to_exitcode(status)` (use the stdlib helper, NOT the raw `>>` bit-shift token which
    trips check-safety R3). Assert exit code + output-file/sidecar presence; `sys.exit(0)` on pass,
    `sys.exit("FAIL: …")` on failure (the `|| fail` shell arm then exits 1).
11. The wrapper `python3 … <<'PYEOF' || fail "…"` makes a python assertion failure fail the script.

## SGR mouse sequences for the mouse harness (tests/region_mouse.sh)
SGR mode 1006 format: `\x1b[<{b};{x};{y}{M|m}` (x,y are **1-based** cells; M=press/motion/wheel,
m=release; `b` encodes button+modifiers: 0=left, +4=shift, +8=alt, +16=ctrl, +32=motion,
64=wheel-up, 65=wheel-down).
- Left **press** at (col=15,row=2): `b"\x1b[<0;15;2M"`.
- Left **motion** (drag) at (col=15,row=3): `b"\x1b[<32;15;3M"` (32 = motion bit | left).
- Left **release** at (col=15,row=3): `b"\x1b[<0;15;3m"`.
- **Wheel up**: `b"\x1b[<64;1;1M"`; **wheel down**: `b"\x1b[<65;1;1M"`.
- **Alt-drag** (block, §7.6): motion `b"\x1b[<40;…;…M"` (40 = 32|8 = motion|alt|left).

### Mouse-harness assertions
1. **Click moves cursor:** drain ~0.7s, capture the status-line `row:N col:M`; send a click at a
   known cell; drain ~0.3s; re-capture. Assert the `col:` (and/or `row:`) CHANGED to the clicked
   cell (proves `regionHandle` consumed the `.mouse` event). Use a pane wide enough (e.g. -x 25)
   and click a column far from the initial cursor (which starts at the last row, col 0).
2. **Drag → confirm writes a file:** press at A → motion to B (3+ rows apart) → release → Enter;
   assert an HTML output file exists and contains expected seeded content (proves drag-select
   began + extended + confirm rendered). Assert NO file when drag is a no-op (regression guard).
3. **Wheel scrolls:** capture status `row:`; send wheel_up; assert the top visible row changed
   (the viewport scrolled). (Assert via the status `row:` shifting, or by seeding distinct line
   markers and checking which are visible — simplest: assert `row:` cursor clamps as the viewport
   scrolls.) Wheel-down mirrors.

## No regressions to guard
- The 4 shipped harnesses (envelope_smoke, plugin_options, region_empty_confirm,
  zero_dimension_reject) MUST stay green. The makeRaw ISIG change is additive (no test asserts
  ISIG==true); the mouse wiring is a NEW `.mouse` arm (keyboard path unchanged). Re-run all 4 +
  `zig build test -Doptimize=ReleaseFast` after each change.