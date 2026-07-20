# P1.M2.T3.S1 — Research Findings (tests/region_mouse.sh mouse integration harness)

> This is the **integration-test harness** for Issue 1 (PRD §7.6 mouse support). It validates
> the `.mouse` arm wired by P1.M2.T2.S1 by driving the REAL `region` binary through a python3
> pty and sending SGR mouse sequences. It is a TRUE regression detector: FAILs (exit 1) on the
> pre-fix binary (mouse ignored) and PASSes on the post-fix binary.

## 0. Task identity & contract

- **Path**: P1.M2.T3.S1 — "Create tests/region_mouse.sh (python3 pty: SGR click/drag/wheel assertions)".
- **Depends on**: P1.M2.T2.S1 (the `.mouse` arm in `regionHandle` + `RegionCtx.mouse_anchor`),
  which is being implemented in parallel. Treat its PRP as a CONTRACT — assume it lands exactly
  as specified. This harness CONSUMES its output (a mouse-responsive `region` binary).
- **Output (contract)**: "a self-contained PASS/exit-0 harness that FAILS (exit 1) if mouse input
  is ignored (the pre-fix state). Runnable standalone and CI-safe."
- **Safety (contract)**: isolated socket `-L t2h-mouse-$$`; teardown by named session ONLY;
  scratch on real disk; never `kill-server`/`killall`/`pkill`; SKIP cleanly (exit 0) if
  tmux/python3 absent. Honor PRD §0/§0.1 fully.

## 1. The canonical harness pattern (mirror tests/region_empty_confirm.sh + region_signal_keys.sh)

Both siblings define the EXACT shell skeleton this harness must copy (architecture/testing_safety.md
§"Canonical integration-harness pattern" is normative):

1. `set -u`; `cd` to repo root; `BIN=./zig-out/bin/tmux-2html`; `fail() { echo "FAIL: $*" >&2; exit 1; }`.
2. SKIP `exit 0` if `tmux` or `python3` absent (CI runners without them still pass).
3. `REAL_TMUX=$(command -v tmux)`.
4. Build release if `! [ -x "$BIN" ]`: `zig build -Doptimize=ReleaseFast`.
5. `SOCK="t2h-mouse-$$"`; `WORK=$(mktemp -d "${TMPDIR:-/tmp}/t2h-mouse.XXXXXX")`; unique `$OUT`.
6. **PATH shim** (the approved, recursion-free, log-free form): write `$WORK/shim/tmux` =
   `#!/bin/sh\nexec "$REAL_TMUX" -L "$SOCK" "$@"\n`; `chmod +x`; export `PATH="$SHIM:$PATH"`.
7. `tmux -L "$SOCK" new-session -d -s s -x W -y H`; `PANE=$(tmux -L "$SOCK" list-panes -t s -F '#{pane_id}' | head -1)`.
8. Seed content via `send-keys -t s "…" Enter; sleep`.
9. `trap '"$REAL_TMUX" -L "$SOCK" kill-session -t s 2>/dev/null || true; rm -rf "$WORK"' EXIT`.
10. python3 pty drive: `pty.fork()` → child `os.execvpe(binary, ["tmux-2html","region","--target",pane,"--output",out], os.environ.copy())`;
    parent sets winsize, `os.write(fd, b"<SGR-mouse>")`, drains via `select`+`os.read`, `os.waitpid`
    + `os.waitstatus_to_exitcode(status)`, asserts, `sys.exit(0)`/`sys.exit("FAIL: …")`.
11. Wrapper: `PATH="$SHIM:$PATH" python3 - "$PANE" "$BIN" "$OUT" <<'PYEOF' || fail "…"`.

## 2. SGR mouse format — VERIFIED against the binary's decoder (src/tui/app.zig)

`parseMousePayload` (app.zig:375) parses `{b};{x};{y}{M|m}` (bytes after `\x1b[<`). The decode
fn (app.zig:319 `decodeMouse`) confirms the bit layout, so the test bytes are EXACTLY what the
binary interprets as the intended action:

| Sequence | b | decode (app.zig) | MouseEvent |
|---|---|---|---|
| `\x1b[<0;15;2M` | 0 | b&64=0 (not wheel), b&32=0 (not motion), b&3=0=left, term='M' → press | left **press** @ (x=15,y=2) |
| `\x1b[<32;15;3M` | 32 | b&32≠0 → motion; b&3=0=left | left **motion/drag** @ (15,3) |
| `\x1b[<0;15;3m` | 0 | term='m' → release | left **release** @ (15,3) |
| `\x1b[<64;1;1M` | 64 | b&64≠0 → wheel; b&1==0 → wheel_up | **wheel_up** @ (1,1) |
| `\x1b[<65;1;1M` | 65 | b&64; b&1==1 → wheel_down | **wheel_down** |
| `\x1b[<40;…;…M` | 40 | 32|8 → motion + alt + left | **alt-drag** (block, §7.6) |

- x,y are **1-based** character cells (MouseEvent doc, app.zig:259).
- modifiers: alt=(b&8), shift=(b&4), ctrl=(b&16). `m.alt` drives block-drag in applyMouse.
- All sequences above are CONFIRMED to reach `regionHandle`'s `.mouse` arm as the intended
  `app.MouseEvent` (app.zig feeds `parseMousePayload(seq[3..])` → `.mouse`).

## 3. applyMouse semantics (what each SGR byte DOES — from mouse_wiring_design.md + P1.M2.T2.S1)

`regionHandle`'s `.mouse` arm calls `applyMouse(&cursor, &sel, &mouse_anchor, m, grid_rows,
total_rows, tty_cols)`. Behavior (PRD §7.6 / tmux copy-mode-mouse parity):

- **press** → `cursor.pos = cell`; `sel.clear()`; `sel.cursor = cursor.pos`; `mouse_anchor = cell`.
- **motion (drag)** → if anchor set: `sel.begin(anchor, block?m.alt:linewise)` (or live mode-switch);
  `cursor.pos = cell`; `sel.cursor = cursor.pos` (extends anchor→cursor).
- **release** → if anchor set: `cursor.pos = cell`; `sel.cursor`; `mouse_anchor = null`; if the
  selection collapsed (anchor==cursor ⇒ a click with no drag) ⇒ `sel.clear()`.
- **wheel_up** → `viewport.scroll = halfPageUp(...)`; `clampCursorIntoViewport(...)`.
- **wheel_down** → `halfPageDown(...)`; clamp.

This makes all three assertions deterministic:
- **(a) click moves cursor**: a press at SGR (15,2) sets `cursor.pos` to grid cell (14,1). The
  status line (view.zig:241) prints `row:{cursor.y+1} col:{cursor.x+1}` ⇒ `col:` goes 1→15. ✓
- **(b) drag→confirm→file**: press(2,1)→motion(2,4)→release(2,4) leaves a linewise selection
  spanning grid rows 0..3; `Enter` confirms ⇒ renders ⇒ writes `--output` containing seeded
  markers. ✓
- **(c) wheel scrolls**: cursor starts at the bottom (last row). `wheel_up` decreases
  `viewport.scroll`; `clampCursorIntoViewport` pulls the cursor UP into the new viewport ⇒ status
  `row:` DECREASES. (Requires scrollback > viewport — see §5 gotcha.) ✓

## 4. Status-line format — VERIFIED (src/tui/view.zig:241)

```zig
try w.print("row:{d} col:{d}", .{ status.cursor.y + 1, status.cursor.x + 1 });
```

So the pty bytes contain `row:N col:M` (1-based). Test regexes: `rb'row:(\d+)'` and `rb'col:(\d+)'`
(take the LAST match — the most recent repaint). Confirmed by view.zig:727 unit test asserting
`"row:3 col:4"`. The sibling region_signal_keys.sh already parses `row:` this way (`last_row`).

## 5. Geometry + the three non-obvious gotchas

- **GOTCHA A — tiny panes HANG region's event loop.** region_empty_confirm.sh explicitly warns:
  "80x10 (NOT 20x6): region's TUI only services input reliably at a normal pane size (tiny panes
  hang the event loop)". The item contract suggested `-x 25 -y 8`, but the canonical "mirror
  EXACTLY" reference (region_empty_confirm) PROVEN 80x10 works and tiny sizes hang. **Use pane
  `-x 80 -y 10`** (overrides the item's 25x8); the click target col 15 is well within 80 cols.
- **GOTCHA B — pty.fork() leaves the window at 0x0; region then never services input (CI hang).**
  region_empty_confirm's fix: `fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24,80,0,0))`
  + `os.kill(pid, signal.SIGWINCH)`. **MUST include this** (harmless if redundant; fatal if needed).
  region_signal_keys omits it (works on its host) but for a mouse harness with tighter timing we
  take the safer region_empty_confirm path. winsize 24×80 ⇒ grid_rows = 23.
- **GOTCHA C — the wheel test needs scrollback > viewport.** `grid_rows` = pty_rows − 1 = 23. If
  total_rows ≤ 23, `scroll` is always 0 and wheel is a no-op ⇒ false FAIL even post-fix. **Seed
  ~30 marker lines** (via a portable `seq` loop) so the captured scrollback ≈ 30 > 23 ⇒ wheel_up
  moves `scroll` from 7→0 and clamps the cursor up ⇒ `row:` decreases. ✓
- **GOTCHA D — NEVER use the raw `>>` bit-shift exit-code token.** This file has `PATH="$SHIM:$PATH"`,
  so check-safety's R3 shim-combo rule (PATH-prepend + `>>` sink in one file) would fire on `st >> 8`.
  Use `os.waitstatus_to_exitcode(st)` (py3.9+ stdlib). The item + both siblings call this out.
- **GOTCHA E — reap every child.** Mouse events do NOT exit the TUI; drives (a) and (c) leave it
  open. After asserting, send `q` then SIGKILL-fallback + `waitpid` (never hang CI on an open pty).
  Drive (b) exits on its own (Enter ⇒ confirm ⇒ exit 0).

## 6. FAIL-before / PASS-after proof (the test is a true regression detector)

- **Pre-fix** (P1.M2.T2.S1 NOT applied — `regionHandle` drops `.mouse`):
  - (a) click ignored ⇒ before col == after col == 1 ⇒ `after[1] > before[1]` is False ⇒ **FAIL**.
  - (b) drag ignored ⇒ no selection ⇒ `Enter` ⇒ region's empty-selection guard exits 1, no file ⇒
    `code != 0` AND `not os.path.exists(out)` ⇒ **FAIL**.
  - (c) wheel ignored ⇒ before row == after row ⇒ `after[0] >= before[0]` is True ⇒ **FAIL**.
- **Post-fix** (`.mouse` arm wired): all three move ⇒ **PASS** (exit 0).
- So the harness fails on the buggy binary and passes on the fixed one — a genuine detector,
  not a tautology. (Manual proof: temporarily comment out the `.mouse` arm in region.zig, rebuild,
  run `sh tests/region_mouse.sh` ⇒ exit 1; restore, rebuild ⇒ exit 0.)

## 7. check-safety baseline + why this file stays clean

**Repo-wide scan TODAY: `1 FAIL, 0 WARN`.** The 1 FAIL is PRE-EXISTING and lives in a **sibling**
task's committed research doc — `P1M1T2S1/research/findings.md:91`, whose prose 'NEVER kill-server'
trips R1 (bare `kill-server` with no `-L`). It is NOT in `tests/` and NOT owned by this task; do not
edit it. THIS task's gate is that `tests/region_mouse.sh` is clean **on its own**
(`sh scripts/check-safety.sh --paths tests/region_mouse.sh` ⇒ `0 FAIL, 0 WARN`) and adds no NEW
repo-wide violation. This file achieves that because it:
- Uses the APPROVED shim form (`exec "$REAL_TMUX" -L "$SOCK" "$@"`, absolute path, NO append log)
  ⇒ does NOT trip R3 (which needs `PATH=…:$PATH` + an `exec`/`>>` sink in the SAME file — the
  shim's `exec` is in a SEPARATE generated file `$WORK/shim/tmux`, not in region_mouse.sh itself).
- Uses `os.waitstatus_to_exitcode` (NOT `>>`) ⇒ the only remaining R3 trigger (`>>` sink) is absent.
- Uses `kill-session -t s` (scoped) ⇒ R1 killserver rule's `-L` exemption applies.
So `tests/region_mouse.sh` is check-safety-clean **on its own** (`--paths` ⇒ 0/0) and adds no NEW
repo-wide violation. Confirmed by the two siblings (region_signal_keys.sh, region_empty_confirm.sh)
which are identical in shape and scan clean via `--paths`.

## 8. Scope boundary (do NOT touch)

- ONLY create `tests/region_mouse.sh`. Do NOT modify any `.zig`, the other `tests/*.sh`, the
  plugin, build files, README, or CONFIGURATION.md. Do NOT re-implement mouse wiring (that is
  P1.M2.T2.S1). Do NOT add a unit test for mouse (the click/drag/wheel LOGIC is covered by
  P1.M2.T1.S1/S2's pure tests; THIS is the integration proof).
- The sibling P1.M3.T1.S1 (docs) owns README/CONFIGURATION mouse-text; leave it alone.