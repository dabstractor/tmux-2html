# Research findings — P1.M1.T1.S3: region blank-cell confirm integration test (pty-driven)

Scope: a shell integration test that drives the REAL `region` binary through a python3
pty, confirms a selection over a BLANK row, and asserts the S2 fix holds (exit 1, no
output file, no sidecar). This is the end-to-end regression guard for Issue 1 + Issue 3.

## 1. The proven pty-drive pattern to copy (tests/envelope_smoke.sh:104–131)

The existing REGION block is the canonical pattern. The shape:
```sh
ROF=$W/region.html; rm -f "$ROF"
PATH="$SHIM:$PATH" python3 - "$PANE" "$ROF" <<'PYEOF' || fail "region confirm pty drive"
import os, pty, select, sys, time
pane, out = sys.argv[1], sys.argv[2]
pid, fd = pty.fork()
if pid == 0:
    os.execvpe("./zig-out/bin/tmux-2html",
               ["tmux-2html","region","--target",pane,"--output",out], os.environ.copy())
else:
    time.sleep(0.8); os.write(fd,b"v"); time.sleep(0.2); os.write(fd,b"\r")
    deadline = time.time()+6
    while time.time()<deadline:
        r,_,_=select.select([fd],[],[],0.2)
        if r:
            try: data=os.read(fd,4096)
            except OSError: break
            if not data: break
        else:
            wpid,_=os.waitpid(pid,os.WNOHANG)
            if wpid!=0: break
    try: os.waitpid(pid,0)
    except OSError: pass
    if not os.path.exists(out):
        sys.exit("region: no output file written (confirm did not fire)")
PYEOF
```
envelope_smoke ASSERTS the file EXISTS (non-blank confirm). S3 INVERTS this: assert the
file does NOT exist AND exit code == 1 (blank confirm). The exit-code extraction
(`os.waitpid` → `os.WIFEXITED`/`os.WEXITSTATUS`) is the one addition.

## 2. WHY envelope_smoke.sh is check-safety-clean (must be replicated EXACTLY)

`scripts/check-safety.sh`'s `shim_combo()` WARN fires only when a file has BOTH:
(a) `PATH="...:$PATH"`, AND
(b) `\bexec[[:space:]]` (word-boundary `exec` + space) OR `>>`.
envelope_smoke.sh has (a) but NOT (b): its shim's only `exec` lives INSIDE a printf
format string as `\nexec "%s"` → in the file bytes that's `nexec` → no `\b` boundary
before `e` → `\bexec[[:space:]]` does NOT match. It uses single `>` and `<<'PYEOF'`
(never `>>`). So the second gate grep fails → `shim_combo` returns early → **0 WARN**.

Verified: `scripts/check-safety.sh --paths tests/envelope_smoke.sh tests/plugin_options.sh`
=> `0 FAIL(s), 0 WARN(s)`.

**S3 implication**: the new test MUST use the identical `printf '#!/bin/sh\nexec "%s" -L
"%s" "$@"\n'` shim idiom. A heredoc shim with a BARE `exec "$REAL_TMUX"` on its own line
(`exec` at line start → `\bexec ` matches) combined with `PATH=...:$PATH` would WARN. No
`>>` anywhere.

## 3. The blank-row determinism problem (and the fix: PS1='')

envelope_smoke seeds `printf 'RED pane-content'` WITHOUT Enter → cursor rests at the END
of a content line → non-blank confirm. S3 needs the OPPOSITE: cursor on a BLANK row.

Bug-report setup (`echo realcontent` + Enter) leaves the cursor on the NEW input line —
which by default shows the SHELL PROMPT. On CI ubuntu-latest the default bash prompt is
`$ ` (non-empty) → the cursor row is NON-blank → `selectionBodyEmpty` returns FALSE → the
S2 guard does NOT fire → region writes the file + exits 0 → **the test false-fails**.

Fix: send `PS1=''` + Enter BEFORE `echo realcontent`. Then every prompt is empty, so the
input line the cursor rests on is provably blank regardless of the default shell.
Trace (pane `-x 20 -y 6`, PS1=''):
- after `PS1=''` Enter: cursor on a blank prompt line.
- after `echo realcontent` Enter: rows = `echo realcontent` / `realcontent` / `` (blank
  prompt, cursor here). `v` selects the blank row → empty body → guard fires → exit 1.

PS1 is honored by sh/bash/zsh (all plausible default shells in a detached session).

## 4. The `.last-output` sidecar path (Issue 3 assertion target)

`region.zig:637–657`: `selfBinDir()` = `dirname(std.fs.selfExePath())` (the binary's OWN
dir via `/proc/self/exe`); `writeLastOutput(bin_dir, path)` writes the BARE output path to
`<bin_dir>/.last-output`. So when running `./zig-out/bin/tmux-2html`, the sidecar lands at
**`./zig-out/bin/.last-output`** (NOT next to the output file).

The S2 fix `break :confirm_render 1` fires BEFORE `writeLastOutput` (region.zig:498), so
the empty path writes NO sidecar. But envelope_smoke's (non-empty) region run writes a
sidecar there too → it may PRE-EXIST. Robust assertion: delete it before the run
(`rm -f "$SIDECAR"`) and assert after that it does NOT contain the test's unique output
basename. (It lives in disposable build output `zig-out/bin`, so `rm -f` is safe.)

## 5. Socket routing: PATH shim (chosen) vs `$TMUX` env

The binary's internal `tmux capture-pane` (capture.zig:97,107) INHERITS the parent env
(`$TMUX`, `$TMUX_PANE`). Two ways to route it to the isolated socket:
- (a) PATH shim prefixing `-L $SOCK` (envelope_smoke's choice) — intercepts EVERY tmux call.
- (b) `TMUX="/tmp/tmux-$UID/$SOCK,w,p"` env (the bug report's repro).

S3 uses (a) — identical to the shipped harness, already check-safety-clean, and the region
block of envelope_smoke already uses it. region.zig:296 reads `$TMUX_PANE` only for the
DEFAULT target; S3 passes `--target $PANE` explicitly so target resolution is deterministic.

## 6. CI wiring

`.github/workflows/ci.yml`: a job builds the binary (`zig build -Doptimize=ReleaseFast`),
installs tmux (`apt-get install -y tmux`), and has python3 pre-installed on ubuntu-latest,
then runs `sh tests/envelope_smoke.sh` (ci.yml:112). S3 adds ONE step right after it:
`sh tests/region_empty_confirm.sh`. (The `safety` job runs `check-safety.sh` separately —
S3 must pass it; the dedicated test file is check-safety-clean per §2.)

## 7. Dependency on S2 (the fix under test)

The test ASSERTS the fixed behavior. If S2 (the tier-2 `selectionBodyEmpty` guard in
region.zig's confirm arm) is NOT yet in the binary, region writes an empty file + exits 0
(the bug) → the test FAILS. That is the CORRECT pre-fix behavior; the test is the
regression guard and must run AFTER S2 lands. Current tree: S1 committed (22913c2,
`selectionBodyEmpty` pub); S2 in progress (`src/region.zig` modified). S3's validation
gate assumes S2 is merged (build includes the guard).

## 8. Safety-script compliance (AGENTS.md §2/§3)

- `check-safety.sh --paths tests/region_empty_confirm.sh` => must be 0/0 (validated by the
  printf-`\nexec` shim idiom, §2). Run it as a gate.
- Teardown is `tmux -L "$SOCK" kill-session -t s` via `trap … EXIT` — NEVER kill-server/
  killall/pkill (R1 FAIL). The shim uses absolute `$REAL_TMUX` (no R2 recursion).
- `preflight.sh` after the run: must show no new `.last-output` residue (the test deletes
  + does-not-recreate it). Optional gate.
- The pty drive has a built-in 6s `deadline` loop → no hang; no unbounded log → no need to
  wrap in `safe-run.sh` (the test is a bounded CI harness, not a runaway producer).

## 9. SKIP semantics

Both envelope_smoke SKIPs (exit 0) are replicated: `command -v tmux` and `command -v
python3`. A CI runner without either must not fail the suite.