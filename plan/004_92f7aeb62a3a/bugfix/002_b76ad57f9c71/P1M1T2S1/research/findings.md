# Research Findings — P1.M1.T2.S1 (tests/region_signal_keys.sh: Ctrl-z no-suspend, Ctrl-c exit-1)

> The ISIG fix (P1.M1.T1.S1) is ALREADY APPLIED (app.zig:100). Verified the harness behavior
> against both the fixed repo binary (PASS-after) and a throwaway buggy build (ISIG reverted,
> FAIL-before for Ctrl-c). All drives used an isolated `-L t2h-*-$$` socket + PATH shim
> (absolute REAL_TMUX, no recursion) — PRD §0 honored; the user's tmux was never touched.

## 1. The canonical template to mirror EXACTLY: tests/region_empty_confirm.sh

Every new `tests/` harness MUST follow this shape (architecture/testing_safety.md §"Canonical
integration-harness pattern"):
`set -u` → `cd` repo root → `BIN=./zig-out/bin/tmux-2html` → `fail()` → SKIP exit 0 if
tmux/python3 absent → `REAL_TMUX=$(command -v tmux)` → build release if missing →
`SOCK="t2h-<tag>-$$"` → `WORK=$(mktemp -d …)` on real disk → **PATH shim**
(`printf '#!/bin/sh\nexec "%s" -L "%s" "$@"\n' "$REAL_TMUX" "$SOCK" > "$SHIM/tmux"`) →
`new-session -d -s s -x W -y H` → `PANE=$(list-panes …|head -1)` → seed content →
`trap '"$REAL_TMUX" -L "$SOCK" kill-session -t s; rm -rf "$WORK"' EXIT` →
**python3 pty drive** (`pty.fork()` → child `os.execvpe`; parent `drain()` via select+read,
`os.waitpid`, `os.waitstatus_to_exitcode`) → `PATH="$SHIM:$PATH" python3 - … <<'PYEOF' || fail`.

The python `drain(secs)` helper is CRITICAL (not bare `sleep`): it keeps the pty output buffer
empty so the TUI's paint writes never deadlock (envelope_smoke.sh's region drive "hung CI for
hours" via this exact pattern before the drain fix). Use `os.waitstatus_to_exitcode(status)`
(NOT the raw `>>` bit-shift token — its two-greater-than spelling trips check-safety R3 because
this file also has a `PATH="$SHIM:$PATH"` line).

## 2. The CRUX: use `k` (up), NOT `j` (down) — for the Ctrl-z "TUI kept repainting" assertion

The region TUI enters at the BOTTOM row (copy-mode parity): region.zig:385-399 —
*"tmux copy-mode ENTERS AT THE BOTTOM (latest line visible). cursor at the last row, col 0"*.
`j` (down) is EOF-clamped at `total_rows-1` (motion.zig) → from the bottom start it is a NO-OP
→ the status-line `row:` does NOT change → a spurious FAIL even when the TUI is alive.
`k` (up) reliably moves the cursor up → `row:` DECREASES → the status line repaints.

**VERIFIED** (fixed binary, -x 25 -y 6, seed `printf 'L1\n…\nL5\n'`): `row:` went **17 → 16**
after `k`. So the contract's `j` must be **`k`** in the harness — this is the one correction a
literal reading of the contract would get wrong. The status-line token is `row:{d} col:{d}`
(1-based; view.zig:241: `status.cursor.y + 1`). Parse it with `re.findall(rb'row:(\d+)', buf)`
taking the LAST match.

## 3. Ctrl-c case — FAIL-before/PASS-after PROVEN (the rock-solid detector)

| binary | Ctrl-c (0x03) result | harness `code == 1`? |
|---|---|---|
| FIXED (repo, ISIG off) | exit **1** (0x03 → input.decodeByte ⇒ .quit ⇒ exit 1) | PASS ✓ |
| BUGGY (throwaway, ISIG reverted) | exit **130** (0x03 → SIGINT → restore+reraise) | FAIL ✓ (catches it) |

So the `assert code == 1 (NOT 130)` assertion is a genuine regression detector. Also assert NO
`--output` file and NO `.last-output` sidecar (quit ⇒ no output, §7.5).

## 4. Ctrl-z case — assertions (robust on the fixed binary; suspend-detection via WUNTRACED)

Fixed binary (VERIFIED): Ctrl-z (0x1a) is an inert byte (input.decodeByte leaves it unmapped ⇒
.ignore ⇒ swallowed) → the TUI keeps running → `k` moves the cursor (`row:` changes) → `q`
exits 1 (restore sequence emitted). PASS.

Assertions (per the contract + isig_fix_design.md §1):
1. After `0x1a` + a short drain: `os.waitpid(pid, os.WNOHANG | os.WUNTRACED)` ⇒ `(0, 0)` (still
   RUNNING — not stopped, not exited). WUNTRACED is what makes a STOPPED child reportable; if the
   process were suspended (the bug) this returns `(pid, stopped_status)` with WIFSTOPPED ⇒ FAIL.
2. Send `k`; drain; the status-line `row:` CHANGED (decreased) ⇒ the TUI kept repainting ⇒ it
   never suspended. (Use `k`, not `j` — §2.)
3. Send `q`; bounded-wait for exit; assert `code == 1` (clean cancel).
4. (Strengthener) the emitted bytes contain the restore sequence `\x1b[?1049l` (terminal
   restored on the q-exit — proves the TTY wasn't left broken by 0x1a).

**Honest note on Ctrl-z FAIL-before**: the issue report (h3.1) observed suspension via pty
("rc=SIGNALED, alt_screen_restored=False"). In my throwaway buggy build the suspend was not
deterministically reproducible (the orphaned pty.fork session can affect SIGTSTP delivery). The
WUNTRACED check (1) is the canonical detector when suspend does reproduce; the row-change (2) +
clean-q-exit (3) confirm the FIXED behavior regardless. The PRIMARY ISIG regression detector is
the T1.S1 unit test (`input.lflag.ISIG = true` + `expectEqual(false, raw.lflag.ISIG)`); this
harness is the live integration confirmation, with Ctrl-c (§3) as its rock-solid signal.

## 5. q-comparison case

Fresh drive: send `q`; assert exit 1 (the canonical cancel, grouped with Ctrl-c per §7.5).
VERIFIED: `q` → exit 1 on both fixed and buggy binaries (q is a normal key, unaffected by ISIG).

## 6. Boundary / safety

- **Parallel task P1.M1.T1.S1** (Implementing → effectively done, app.zig:100): edits
  `src/tui/app.zig` (the ISIG fix). This task creates `tests/region_signal_keys.sh` — a NEW
  file. Zero overlap.
- **check-safety**: the PATH shim is `exec "$REAL_TMUX" -L "$SOCK" "$@"` (absolute, no
  recursion, no append log) ⇒ R3's shim-combo gate does NOT fire (mirrors region_empty_confirm.sh
  which is 0 FAIL/0 WARN). Use `os.waitstatus_to_exitcode` (not `>>`) so the python heredoc
  doesn't add the R3-triggering token alongside the `PATH="$SHIM:$PATH"` line.
- **PRD §0/§0.1**: isolated `-L t2h-sig-$$` socket; teardown `kill-session -t s` ONLY (trap);
  scratch on real disk (`mktemp -d`); bounded-wait + SIGKILL so a suspended process can't hang
  CI; SKIP exit 0 if tmux/python3 absent. NEVER kill-server/killall/pkill.
- **DO NOT touch**: any `.zig` (the fix is T1.S1); the 4 shipped harnesses (re-run them green).

## 7. Validation

- `sh tests/region_signal_keys.sh` → PASS, exit 0 (against the fixed binary; Ctrl-z inert +
  Ctrl-c exit 1 + q exit 1).
- `sh scripts/check-safety.sh --paths tests/region_signal_keys.sh` → 0 FAIL / 0 WARN.
- Re-run the 4 shipped harnesses + `zig build test -Doptimize=ReleaseFast` → all green (the new
  harness is additive; nothing else changes).