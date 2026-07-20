# System Context — Region TUI Input-Surface Bugfixes (Round 2)

## Scope
Three issues found in end-to-end creative validation (round 2), ALL in the **region TUI**
(`tmux-2html region`, PRD §7). The core capture→HTML flows and the keyboard-driven region
selection are solid; the gaps are in input surfaces *beyond* the keyboard:
- **Issue 1 (Major, §7.6):** mouse support is decoded but never consumed → click/drag/wheel are no-ops.
- **Issue 2 (Major, §7.1/§7.5):** Ctrl-z (SIGTSTP) freezes the popup, terminal left unrestored.
- **Issue 3 (Minor, §7.5):** Ctrl-c exits 130 (not §7.5's "exit 1").

Issues 2 & 3 share a single one-line root cause.

## The region TUI event pipeline (as-built, confirmed by source read)

```
stdin (raw pty)
  └─ app.readEvent (src/tui/app.zig)        — byte-level read; classifies into app.Event
        app.Event = .key(u8) | .mouse(MouseEvent) | .seq(EscSeq) | .eof
        • SGR mouse (mode 1006) is ENABLED on entry (enter_full_seq) and DECODED by
          parseMousePayload/classifyEscSeq into a fully-typed MouseEvent.
        • makeRaw sets raw termios (ICANON/ECHO/IXON/ICRNL/BRKINT/OPOST OFF; CS8; MIN=1/TIME=0).
        • installSignalHandlers installs SIGINT/SIGTERM/SIGQUIT → restore-then-reraise.
     └─ app.runEvents(handler)              — loops readEvent, dispatches each Event to handler
          └─ regionHandle (src/region.zig:137) — the SOLE EventHandler wired into runEvents
                • search-mode → handleSearchByte
                • else → input.feed(&decoder, ev) → input.Key | null
                     input.feed: .eof/.mouse ⇒ null (mouse DROPPED here — Issue 1)
                  • .motion  ⇒ motion.applyMotion(cursor,...) + sync sel.cursor + repaint
                  • .action  ⇒ quit/confirm/clear-or-quit / select.applyAction + repaint
                  • .search  ⇒ handleSearchAction
                • returns .none for mouse (decode discarded) — Issue 1 root cause
```

### State ownership: `RegionCtx` (src/region.zig:88)
Owns ALL interactive state (a stack `var` in `body()`, address passed as `*anyopaque`):
- `cursor: motion.Cursor` — `{ pos: view.Pos{x,y}, viewport: view.Viewport{cols,rows,scroll} }`
- `sel: select.Sel` — `{ anchor: view.Pos, cursor: view.Pos, mode: Mode(.none/.linewise/.block) }`
- `mgrid: motion.Grid` — pre-decoded grid line-provider (motion primitives read text+col)
- `tty_cols/tty_rows: u16`, `grid_rows: u16` (= tty_rows - 1; last tty row = status line)
- `total_rows: u32` — full scrollback row count
- `decoder: input.Decoder`, `search: motion.SearchState`, `pattern`, `searching`, `pattern_buf`

### Coordinate model (how the grid maps to the popup screen — from view.render)
- `view.render` paints viewport rows: grid row `gy = viewport.scroll + vy` for `vy in 0..rows-1`,
  cursor-addressed to **1-based** screen row `vy+1`, **1-based** screen col starting at 1 (= grid col 0).
- So a **1-based** SGR click at `(sx, sy)` maps to:
  - grid col = `sx - 1`
  - viewport row = `sy - 1`  → grid row = `viewport.scroll + (sy - 1)`
- The status line occupies screen row `tty_rows` (viewport row `grid_rows`); grid area is rows
  `1..grid_rows`. A click on the status line (vy >= grid_rows) must be clamped to the last grid row.

## Issue 1 — Mouse (§7.6): decoded but discarded
- `app.zig` ENABLES SGR mouse (`mouse_enable_seq` in `enter_full_seq`) and DECODES every event:
  `MouseEvent{ button, action, x(1-based), y(1-based), shift, alt, ctrl }`,
  `MouseAction ∈ {press, release, motion, wheel_up, wheel_down}`.
- `regionHandle` calls `input.feed(&decoder, ev)`; `input.feed` returns `null` for `.mouse`
  (input.zig: `case .eof, .mouse => return null`). So `regionHandle` falls through to `return .none`
  and the decoded event is DROPPED. The handler doc-comment (region.zig:135) concedes this is an
  unfinished "follow-up".
- All building blocks for the fix already exist and are unit-tested:
  - cursor move: set `ctx.cursor.pos` + `view.scrollForCursor` (pure).
  - selection: `select.Sel.begin/clear/toggle` + `select.applyAction` + `sel.cursor` sync.
  - scroll: `view.halfPageUp/halfPageDown/pageUp/pageDown` (pure).
- See `mouse_wiring_design.md` for the full design.

## Issues 2 & 3 — ISIG not disabled in makeRaw (shared root cause)
- `app.makeRaw` (app.zig:94) clears ICANON/ECHO (lflag), IXON/ICRNL/BRKINT (iflag), OPOST (oflag);
  sets CS8; MIN=1/TIME=0. It does **NOT** clear `lflag.ISIG`.
- With ISIG ON, the kernel translates tty control chars into signals BEFORE they reach stdin as bytes:
  - Ctrl-z (0x1a) → SIGTSTP → default disposition STOPS the process. `installSignalHandlers`
    installs SIGINT/TERM/QUIT but **not** SIGTSTP ⇒ no restore runs ⇒ terminal left in
    raw+alt-screen+hidden-cursor, popup frozen (Issue 2).
  - Ctrl-c (0x03) → SIGINT → `sigHandler` restores terminal then RE-RAISES ⇒ exit 130 (128+2).
    `input.decodeByte` maps `0x03 => .{ .action = .quit }` (⇒ exit 1) but this is **dead code**
    while ISIG is on — the byte never reaches stdin (Issue 3).
- **Fix (one line, fixes BOTH):** `raw.lflag.ISIG = false;` in `makeRaw`. With ISIG off:
  - Ctrl-c → byte 0x03 → `input.decodeByte` ⇒ `.quit` ⇒ normal `return 1` (matches §7.5 exactly).
  - Ctrl-z → byte 0x1a → unmapped ⇒ `.ignore` ⇒ swallowed (no suspend, terminal intact).
  - Ctrl-\ → byte 0x1c → unmapped ⇒ swallowed (no longer SIGQUIT/core; benign).
  - SIGTERM/SIGINT/SIGQUIT handlers REMAIN valuable for EXTERNAL signals (`kill -TERM`, etc.).
- Scope: `app.makeRaw` ONLY. `palette.zig` has its OWN separate raw-mode (palette.zig:106-109;
  it runs OUTSIDE the popup for the short OSC palette query and is unaffected/untouched).
- See `isig_fix_design.md` for details + the unit-test update.

## Build / test / safety context (AGENTS.md + PRD §0/§0.1/§15)
- Build: `zig build --release=fast`. Tests: `zig build test -Doptimize=ReleaseFast` (275 fns;
  Debug hits a linker bug — MUST use ReleaseFast).
- check-safety.sh FAILs on global tmux kill + recursive bare-exec tmux; WARNs on hand-rolled
  PATH shims outside scripts/+plan/. It greps for `>>` append + `PATH=…:$PATH` combos.
- Integration tests MUST: isolated uniquely-named socket `-L t2h-*-$$`; teardown by named
  session only (`kill-session -t s`); NEVER kill-server/killall/pkill; SKIP cleanly (exit 0)
  if tmux/python3 absent; scratch on real disk (NOT /tmp tmpfs).
- Canonical harness pattern: `tests/region_empty_confirm.sh` (PATH shim prefixing `-L $SOCK`
  with absolute REAL_TMUX, no recursion, no append log; python3 pty.fork drive).
- `scripts/safe-run.sh` caps file size + CPU (RLIMIT_FSIZE/RLIMIT_CPU); `scripts/with-tmux-audit.sh`
  is the approved tmux shim; `scripts/preflight.sh` detects residue. Run builds/tests ONE AT A TIME.