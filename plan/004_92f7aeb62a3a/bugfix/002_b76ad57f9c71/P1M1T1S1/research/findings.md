# Research Findings — P1.M1.T1.S1 (add `ISIG = false` to app.makeRaw)

> Small, surgical root-cause fix (1 pt). Verified against the live source;
> baseline test gate run green. Issues 2 & 3 share this one-line root cause.

## 1. The one-line fix (src/tui/app.zig, in makeRaw)

Add `raw.lflag.ISIG = false;` immediately AFTER the existing `raw.lflag.ECHO = false;`
line (currently app.zig:97). makeRaw (app.zig:94) clears ICANON/ECHO (lflag),
IXON/ICRNL/BRKINT (iflag), OPOST (oflag), sets CS8, MIN=1/TIME=0 — but leaves ISIG ON,
so the kernel turns Ctrl-c/z/\ into SIGINT/SIGTSTP/SIGQUIT before they reach stdin as
bytes. ISIG off makes them inert bytes that input.zig classifies (0x03 ⇒ .quit ⇒ exit 1).

## 2. Why it fixes both Issues 2 & 3 (and is safe)

| Key | Byte | ISIG ON (bug) | ISIG OFF (fix) |
|-----|------|---------------|----------------|
| Ctrl-c | 0x03 | SIGINT ⇒ restore+reraise ⇒ exit **130** (Issue 3) | byte 0x03 ⇒ input.decodeByte `.quit` ⇒ **exit 1** (§7.5) |
| Ctrl-z | 0x1a | SIGTSTP (no handler) ⇒ STOPPED, TTY unrestored (Issue 2) | byte 0x1a ⇒ unmapped ⇒ `.ignore` ⇒ swallowed |
| Ctrl-\ | 0x1c | SIGQUIT ⇒ restore+reraise ⇒ core dump | byte 0x1c ⇒ unmapped ⇒ swallowed |

`input.decodeByte` ALREADY maps `0x03 ⇒ .{ .action = .quit }` — "dead code" only because
ISIG intercepted 0x03 first. The SIGINT/SIGTERM/SIGQUIT handlers (installSignalHandlers)
STAY (they handle EXTERNAL signals like `kill -TERM`; with ISIG off, tty-Ctrl-c no longer
generates SIGINT but external signals still restore+reraise). No SIGTSTP handler needed
(ISIG off ⇒ Ctrl-z is never a signal).

## 3. Exact current text (verified) for byte-accurate edits

**makeRaw function (app.zig:94–107)** — insert one line after the ECHO line:
```
    raw.lflag.ICANON = false; // no canonical (line) mode
    raw.lflag.ECHO = false; // no echo of keystrokes
    raw.lflag.ISIG = false; //  ← ADD: disable signal chars (Ctrl-c/z/\) → arrive as bytes input.zig handles, not kernel signals (Issues 2 & 3, §7.5)
    raw.iflag.IXON = false; // disable Ctrl-S/Ctrl-Q flow control
```

**makeRaw doc-comment (app.zig:90–93)** — add ISIG to the cleared-flags list + rationale:
```
OLD: /// PURE: produce a raw-mode termios from `original`. Clears ICANON/ECHO (lflag),
     /// IXON/ICRNL/BRKINT (iflag), OPOST (oflag); ...
NEW: /// PURE: produce a raw-mode termios from `original`. Clears ICANON/ECHO/ISIG (lflag),
     /// IXON/ICRNL/BRKINT (iflag), OPOST (oflag); ...
ADD: /// ISIG is cleared so Ctrl-c/Ctrl-z/Ctrl-\ arrive as readable bytes (input.zig
     /// classifies them) instead of kernel signals (SIGINT/SIGTSTP/SIGQUIT) — PRD §7.1
     /// (always restore) / §7.5 (Ctrl-c ⇒ exit 1, not 130).
```

**Test 1 input (app.zig:509–510)** — ISIG is false in a zeroed termios, so SET it to prove
makeRaw clears it:
```
    input.lflag.ICANON = true;
    input.lflag.ECHO = true;
    input.lflag.ISIG = true;   //  ← ADD
    input.iflag.IXON = true;
```
**Test 1 assertion (app.zig:522–523)**:
```
    try std.testing.expectEqual(false, raw.lflag.ECHO);
    try std.testing.expectEqual(false, raw.lflag.ISIG);   //  ← ADD
    try std.testing.expectEqual(false, raw.iflag.IXON);
```

**Test 2 assertion (app.zig:546–547)** — idempotent test: assert ISIG stays false:
```
    try std.testing.expectEqual(false, out.lflag.ECHO);
    try std.testing.expectEqual(false, out.lflag.ISIG);   //  ← ADD
    try std.testing.expectEqual(@as(@TypeOf(out.cflag.CSIZE), .CS8), out.cflag.CSIZE);
```

(Optional accuracy tweak: rename Test 1 from "clears ICANON/ECHO/IXON/…" to
"clears ICANON/ECHO/ISIG/IXON/…" so the name stays honest. Not required by the contract.)

## 4. Scope — what is NOT touched

- **palette.zig is OUT OF SCOPE.** It has its OWN separate raw-mode (palette.zig:106–109:
  ICANON/ECHO off, MIN=0/TIME=5) for the short sync-palette OSC query. It does NOT set ISIG
  (leaves the original) and runs OUTSIDE the popup. Changing it risks side effects and is
  unnecessary — the PRD issues are region-TUI-only. Confirmed by grep.
- input.zig / motion.zig / select.zig / view.zig / region.zig: UNCHANGED. (input.zig's
  `0x03 ⇒ .quit` mapping already exists and becomes live once ISIG is off — no edit needed.)
- installSignalHandlers / the SIGINT/SIGTERM/SIGQUIT handlers: UNCHANGED (they handle
  EXTERNAL signals).

## 5. Side-effect analysis (why disabling ISIG is safe)

- The only behavior changes are the three tty-control keys (Ctrl-c/z/\) — all become more
  correct/benign. Ctrl-c now matches §7.5 exactly (exit 1).
- No existing unit test asserts ISIG==true (the makeRaw test is the only one touching lflag
  flags; it is updated additively). The ReleaseFast suite stays green.
- `classifyByte`/`default_handler` map 0x03 ⇒ quit — unchanged.

## 6. Validation gate (verified on baseline)

```
zig build test -Doptimize=ReleaseFast   # EXIT 0 on baseline (ReleaseFast MANDATORY — Debug hits R_X86_64_PC64 linker bug, PRD §15)
```
Note: S1 alone changes makeRaw's output (ISIG=false termios) but the only CONSUMER is the
region TUI's raw-mode entry (app.zig:~147 restoreRaw/run). The unit tests are the regression
guard; the live pty harness (Ctrl-z no-suspend, Ctrl-c exit-1) is the SIBLING task
P1.M1.T2.S1 (tests/region_signal_keys.sh) — NOT this task.