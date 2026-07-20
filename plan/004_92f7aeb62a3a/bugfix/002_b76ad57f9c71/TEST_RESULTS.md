# Bug Fix Requirements

## Overview

End-to-end creative validation (round 2) of the **tmux-2html** implementation against the
PRD, focused on user-facing surfaces the standard validation and round 1 may have missed —
in particular the interactive **region TUI** (PRD §7), where the happy-path confirm action
was already well covered.

**Testing performed:**
- Clean `zig build --release=fast`; `zig build test --release=fast` (all unit tests pass).
- Ran all four shipped shell harnesses: `tests/plugin_options.sh`, `tests/envelope_smoke.sh`,
  `tests/region_empty_confirm.sh`, `tests/zero_dimension_reject.sh` — all PASS.
- Confirmed **both round-1 fixes hold**: region empty-cell confirm now exits 1 with no
  file/sidecar (TIER-2 `selectionBodyEmpty` guard); `render --cols 0` / `--rows 0` now exit 2
  with a message instead of segfaulting.
- Drove the **real binary** through every output path: `render` (stdout/`--output`/`--open`/
  `--selection` linewise+block+reversed+single-cell+out-of-range+empty-body/`--title`/`--lang`/
  C/POSIX→en/`--palette default|cached|live|junk`), `pane` (`--visible`/`--full`/full-scrollback
  capture of all 30 MARKER lines/truncation/`--history 0|5|junk`/no-target→exit 2), `region`
  (linewise/block/`o`+`O` swap/re-anchor/`y`/search/Esc-clears-then-stays/Ctrl-c/Ctrl-z/Ctrl-\\/
  mouse click+drag+wheel/full-scrollback `gg`..`G` select), `sync-palette` (`--from file`
  out-of-range-index/negative-RGB/empty), `--version`, `--help`, exit codes, SIGPIPE/broken-pipe.
- Verified §8.1 envelope byte-for-byte on every path (DOCTYPE first, charset first in `<head>`,
  viewport, escaped `<title>`/`<font>`/`lang`, page bg = terminal bg, exactly one `<pre>`).
- Verified color fidelity: OSC 8 → `<a>`, truecolor (8 distinct colors), wide chars / emoji /
  CJK. Verified `xdg-open` detachment does NOT hang (30 s-blocking fake opener → render
  returned immediately). Verified plugin `tmux-2html.tmux` sources cleanly against an isolated
  server and registers the pane-anchored `C-o` + full-pane bindings. Verified `ensure_binary.sh`
  version-match + the `testdata/*.html` goldens are re-blessed as complete documents.
- **All tmux integration used isolated, uniquely-named sockets** (`-L t2h-*-$$`); PRD §0/§0.1
  honored — the user's live session was never touched; teardown was `kill-session -t <name>`
  on my own named sockets only, never `kill-server`/`killall`/`pkill`.

**Overall quality assessment:** The core is **strong** and the round-1 fixes are solid.
Two **Major** gaps remain, both in the **region TUI** (PRD §7), plus one related **Minor**:
(1) **mouse support (PRD §7.6) is completely non-functional** — the SGR mouse is decoded by
`tui/app.zig` but `region.zig`'s handler has no `.mouse` branch, so click/drag/wheel are all
silently ignored (the code comment admits it is an unfinished "follow-up"); (2) **Ctrl-z
(SIGTSTP) freezes the region popup** with no in-TUI recovery and the terminal left unrestored,
because `makeRaw` does not disable `ISIG` and `SIGTSTP` is not in the installed signal set;
(3) **Ctrl-c exits 130, not PRD §7.5's "exit 1"** — same root cause as (2): `ISIG` intercepts
Ctrl-c as `SIGINT` before `input.zig`'s `0x03 → .quit` mapping can fire (that mapping is
effectively dead code).

---

## Critical Issues (Must Fix)

None. (The primary capture→HTML flows — full/visible pane, and region select+confirm via
**keyboard** — all work correctly. Both findings below are in the region TUI and concern an
unimplemented feature and an uncommon-key robustness gap, not a broken happy path.)

---

## Major Issues (Should Fix)

### Issue 1: Mouse support (PRD §7.6) is completely non-functional — click/drag/wheel are all silently ignored

**Severity**: Major
**PRD Reference**: §7.6 ("Mouse (supported): Click to move cursor; drag to select (linewise
  by default, block with modifier, e.g. Alt); wheel to scroll"). Mouse is listed as a
  **supported** feature in §7.6, NOT in the §16 out-of-scope roadmap.
**Expected Behavior**: In the region overlay, a mouse **click moves the cursor** to the
  clicked cell; a **drag selects** (linewise by default, block with Alt); the **wheel
  scrolls** the viewport — exactly as tmux copy-mode and the PRD promise.
**Actual Behavior**: **All mouse input is a no-op.** The TUI *enables* SGR mouse reporting on
  entry (`\x1b[?1000h\x1b[?1002h\x1b[?1006h`, `src/tui/app.zig:69`) and *decodes* every SGR
  event into a typed `MouseEvent` (`parseMousePayload`, `src/tui/app.zig:375`), but the region
  event handler **`regionHandle` (`src/region.zig:137`) has no `.mouse` branch**. `input.feed`
  returns `null` for `.mouse` events (comment at `src/region.zig:131`/`:169`:
  *"input.feed returns null … on .eof/.mouse"*), so `regionHandle` falls through to `return
  .none` and the decoded event is **discarded**. The handler's own doc-comment concedes this:
  `src/region.zig:135` — *"Mouse is a NO-OP in S1 (PRD 7.6 mouse wiring is a follow-up … a
  later task only adds the regionHandle mouse branch)."* That follow-up was never done.

  Because mouse reporting is *enabled*, a user reasonably expects it to work; the cursor
  changes / the terminal enters mouse-reporting mode, yet nothing responds — making the
  non-functionality more confusing than if mouse were simply disabled.

**Steps to Reproduce** (against an isolated tmux server — PRD §0 safe):
  1. Build: `zig build --release=fast`.
  2. Create an isolated server + pane with content, then drive `region` over a pty and send
     an SGR click at a known cell, capturing the status line's `row:N col:M` before/after:
     ```sh
     SOCK="t2h-mouse-$$"; tmux -L "$SOCK" new-session -d -s s -x 25 -y 6
     PANE=$(tmux -L "$SOCK" list-panes -t s -F '#{pane_id}' | head -1)
     tmux -L "$SOCK" send-keys -t s "printf 'LNE0XY content\n'" Enter; sleep 0.4
     TMUX="/tmp/tmux-$UID/$SOCK,0,0" python3 - <<'PY'
     # pty-fork ./zig-out/bin/tmux-2html region --target $PANE; drain 0.7s; read status;
     # write b"\x1b[<0;15;2M"  (SGR left-press col=15,row=2); drain 0.3s; read status again.
     PY
     ```
  3. Observe: the `row:/col:` shown in the status line is **identical before and after the
     click** (cursor did not move). Likewise an SGR drag
     (`\x1b[<0;2;1M` press → `\x1b[<32;15;3M` motion → `\x1b[<0;15;3m` release) followed by
     `Enter` produces **no file** (selection never began), and wheel events
     (`\x1b[<64;1;1M`) do not scroll. (Verified: `click did NOT move cursor (mouse IGNORED)`.)

**Contrast (keyboard works perfectly)**: the SAME selection via keyboard (`v` … `j` …
  `Enter`) writes a correct HTML file; `gg`…`v`…`G`…`Enter` selects the full scrollback.
  Only the **mouse** path is dead.

**Root cause**: `regionHandle` (`src/region.zig:137`) is the sole `EventHandler` wired into
  `runEvents` (`src/region.zig:420`). It switches only on `input.feed`'s decoded `Key`
  (`.motion`/`.action`/`.search`); `.mouse` events yield `null` from `input.feed` and are
  dropped. No code path translates a `MouseEvent` into a cursor move / selection / scroll.

**Suggested Fix**: Add a `.mouse` arm to `regionHandle` (before / alongside the
  `input.feed` call) that consumes the already-decoded `app.MouseEvent`:
  - **press** at (x,y) → move the cursor (`motion` jump) and (optionally) begin a selection;
  - **motion (drag)** → if a button is held, extend the current selection (linewise; switch to
    block when `ev.alt`, per §7.6); move the cursor to the drag cell;
  - **release** → finalize the drag selection;
  - **wheel_up/wheel_down** → scroll the viewport (`motion.viewport` / half-page).
  The building blocks already exist: `motion.applyMotion`, `select.applyAction` /
  `select.Sel`, and `view.scrollToBottom`/viewport math. Coordinate conversion is
  1-based SGR (`MouseEvent.x/y`) → 0-based grid cell (note `MouseEvent` doc: "x/y are 1-based
  CHARACTER cells"). Add an integration test (python3 pty) that SGR-clicks and asserts the
  status-line `row:/col:` changes, plus a drag→confirm→file test.

---

### Issue 2: Ctrl-z (SIGTSTP) freezes the region popup with no in-TUI recovery and the terminal left unrestored

**Severity**: Major
**PRD Reference**: §7.1 ("Restore on exit (always, including panic)" — the codebase built an
  explicit safety net: root panic override + signal handler + atomic `entered` flag,
  specifically to ALWAYS restore the terminal), §7.5 (cancel contract), §0.1 ("Keep harnesses
  bounded … leak-free").
**Expected Behavior**: Pressing Ctrl-z in the region overlay must not leave the TTY in a
  broken state. Either it is ignored (like any other unmapped key) or it is handled with the
  terminal restored. The §7.1 "always restore" guarantee must hold for the suspend case too.
**Actual Behavior**: **The process is suspended (SIGTSTP) and the terminal is NOT restored.**
  `makeRaw` (`src/tui/app.zig:94–104`) clears `ICANON`/`ECHO`/`IXON`/`ICRNL`/`BRKINT`/`OPOST`
  but **does NOT clear `ISIG`**, so the kernel still translates tty control characters into
  signals. `installSignalHandlers` (`src/tui/app.zig`) installs handlers for **SIGINT, SIGTERM,
  SIGQUIT only — NOT SIGTSTP**. So Ctrl-z → kernel delivers `SIGTSTP` → the default
  disposition **stops the process** before any restore runs. Result (verified via pty):
  ```
  Ctrl-z SIGTSTP: rc=SIGNALED  alt_screen_restored=False
  ```
  The popup's pty is left in **raw + alternate-screen + hidden-cursor** mode, the `tmux-2html`
  process is stopped, and the popup (launched with `display-popup -E`, which closes only when
  the command **exits**) stays open showing a frozen TUI that no longer reads input. There is
  **no in-TUI recovery**: keystrokes go to a stopped process. The user must recover from
  *another* client (e.g. `tmux display-popup -C`, or `kill -CONT <pid>` to resume then `q`),
  which a typical user will not know to do.

**Steps to Reproduce**:
  ```sh
  zig build --release=fast
  SOCK="t2h-sig-$$"; tmux -L "$SOCK" new-session -d -s s -x 25 -y 6
  PANE=$(tmux -L "$SOCK" list-panes -t s -F '#{pane_id}' | head -1)
  tmux -L "$SOCK" send-keys -t s "echo hi" Enter; sleep 0.4
  # pty-fork region, send a single Ctrl-z (0x1a), then inspect exit status + whether the
  # restore sequence (\x1b[?1049l / \x1b[?25h) was emitted.
  TMUX="/tmp/tmux-$UID/$SOCK,0,0" python3 - <<'PY'
  import os,pty,select,time,signal
  pid,fd=pty.fork()
  if pid==0:
      os.execvpe("./zig-out/bin/tmux-2html",["tmux-2html","region","--target",os.environ["PANE"]],os.environ.copy())
  time.sleep(0.6); os.write(fd,b"\x1a")  # Ctrl-z
  out=b""
  end=time.time()+0.6
  while time.time()<end:
      r,_,_=select.select([fd],[],[],0.05)
      if r:
          try: out+=os.read(fd,65536)
          except OSError: break
  os.close(fd)
  # process is STOPPED (SIGTSTP); restore sequence absent from `out`.
  PY
  ```
  Observe: exit status `WIFSTOPPED` (or SIGHUP-on-pty-close of the stopped proc), and the
  emitted bytes contain **no** `\x1b[?1049l`/`\x1b[?25h` restore sequence.

**Why standard validation missed it**: every region test (shipped + round 1) drives the TUI
  with `q`/`v`/`Enter`/`y`/search keys; none exercises Ctrl-z, and the unit tests for
  `makeRaw` assert the flags it *does* set, not the `ISIG` it omits.

**Suggested Fix** (one line, also fixes Issue 3): add `raw.lflag.ISIG = false;` to `makeRaw`
  (`src/tui/app.zig`, alongside the existing `ICANON`/`ECHO` clears). With `ISIG` off, Ctrl-z
  arrives as the inert byte `0x1a`, which `input.zig` does not map ⇒ swallowed (`.ignore`) ⇒
  no suspend, no broken TTY. (Equivalently, also add a `SIGTSTP` handler to
  `installSignalHandlers` that restores-then-re-raises — but disabling `ISIG` is the smaller,
  uniform fix and aligns the cancel keys with `input.zig`'s byte mappings.) Add an integration
  test: send `0x1a` to the region TUI and assert the process keeps running (status line still
  repaints on a subsequent `j`) and that `q` still exits cleanly.

---

## Minor Issues (Nice to Fix)

### Issue 3: `Ctrl-c` exits 130, not PRD §7.5's "exit 1" (same root cause as Issue 2)

**Severity**: Minor
**PRD Reference**: §7.5 ("`q` / `Esc` (when no selection) / `Ctrl-c` → exit `1`, no output").
**Expected Behavior**: `Ctrl-c` cancels the region overlay and the process exits with code
  **1** — grouped with `q`/`Esc` as an equivalent cancel action.
**Actual Behavior**: `Ctrl-c` exits **130** (signal death: 128 + SIGINT(2)). Verified
  reproducible (3/3 runs: `Ctrl-c trial N: rc=130`; `q: rc=1` for comparison).
**Root cause**: same as Issue 2 — `makeRaw` leaves `ISIG` enabled, so Ctrl-c (0x03) is
  intercepted by the kernel as `SIGINT` and **never reaches stdin as a byte**. The restore-
  then-re-raise signal handler (`sigHandler`, `src/tui/app.zig`) restores the terminal (good)
  but then re-raises `SIGINT` → the process dies with the conventional 128+sig status. The
  `0x03 → .{ .action = .quit }` mapping in `src/tui/input.zig:240` is therefore **effectively
  dead code** — it can only fire if `ISIG` is off. (The presence of that mapping is strong
  evidence the authors *intended* Ctrl-c to be handled as a key, i.e. `ISIG` was meant to be
  disabled.)
**Impact**: low. In the shipped `display-popup -E` configuration the popup closes on any exit
  and the `C-o` binding wrapper reads only the `.last-output` sidecar (it never inspects the
  exit code), so the user sees identical behavior (cancel, no output, terminal restored). The
  130-vs-1 discrepancy is observable only when scripting `tmux-2html region` directly and
  checking `$?`.
**Suggested Fix**: identical to Issue 2 — `raw.lflag.ISIG = false;` in `makeRaw`. With `ISIG`
  off, `0x03` reaches `input.zig` ⇒ `.quit` ⇒ the normal `return 1` path (matching §7.5
  exactly). Add a regression test: pty-send `\x03`, assert exit code `1` (not 130) and that no
  output file / sidecar is produced.

---

## Testing Summary

- **Total tests performed:** ~90 distinct scenarios across render / pane / region (incl. full
  interactive TUI: movement, selection, block, `o`/`O` swap, re-anchor, search, confirm,
  cancel, **mouse**, **signal keys**) / sync-palette / CLI / envelope / palette / plugin /
  install / safety.
- **Passing:** the overwhelming majority — all unit tests, all 4 shell harnesses, both
  round-1 fixes (empty-selection guard, zero-dimension guard), every §8.1 envelope path, all
  color fidelity (OSC8/truecolor/256/16/wide/emoji), capture + full-scrollback + truncation +
  history caps, xdg-open non-block detachment, plugin sourcing + binding registration,
  ensure_binary version match, re-blessed goldens, SIGPIPE handling, locale/lang resolution,
  nested-output, concurrency.
- **Failing (bugs found):** 2 Major (Issue 1: mouse non-functional; Issue 2: Ctrl-z freezes
  popup) + 1 Minor (Issue 3: Ctrl-c exit 130≠1). Issues 2 and 3 share a single one-line root
  cause (`ISIG` not cleared in `makeRaw`).
- **Areas with good coverage:** §8.1 HTML envelope (every path, byte-verified); keyboard-driven
  region selection (linewise/block/swap/re-anchor/search/confirm/cancel); capture +
  scrollback + truncation; palette precedence + file parsing; CLI parse + exit codes; title/
  font/lang escaping (XSS-hardened); xdg-open detachment; plugin binding registration + the
  round-1 regression guards.
- **Areas needing more attention:** **the region TUI's input surface beyond the keyboard** —
  (a) **mouse (§7.6)** is decoded but never consumed (Issue 1; no integration test sends a
  mouse event, so it stayed green); (b) the **tty-signal control keys** (Ctrl-z/Ctrl-c) are
  never driven against the real TUI, so the `ISIG`-left-on gap (Issues 2 & 3) and the missing
  `SIGTSTP` handler went unnoticed. The signal issue is especially subtle because the *unit*
  test for `makeRaw` asserts the flags it sets rather than the `ISIG` it leaves enabled, and
  `input.zig`'s `0x03` mapping looks correct in isolation — only a live pty drive reveals that
  `ISIG` intercepts the byte first.