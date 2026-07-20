# ISIG / Signal-Key Fix Design (Issues 2 & 3 — shared root cause)

## Root cause (confirmed by source read)
`app.makeRaw` (src/tui/app.zig:94) clears ICANON/ECHO/IXON/ICRNL/BRKINT/OPOST but leaves
`lflag.ISIG` ENABLED. ISIG makes the kernel translate tty control characters into signals
BEFORE they ever reach stdin as readable bytes:

| Key | Byte | With ISIG ON (current bug) | With ISIG OFF (fixed) |
|-----|------|----------------------------|-----------------------|
| Ctrl-c | 0x03 | → SIGINT → sigHandler restore+reraise → **exit 130** (Issue 3) | byte 0x03 → input.decodeByte ⇒ `.quit` ⇒ **exit 1** (§7.5) |
| Ctrl-z | 0x1a | → SIGTSTP (no handler) → process STOPPED, terminal unrestored (Issue 2) | byte 0x1a → unmapped ⇒ `.ignore` ⇒ swallowed (no suspend) |
| Ctrl-\ | 0x1c | → SIGQUIT → sigHandler restore+reraise → core dump | byte 0x1c → unmapped ⇒ swallowed (no core) |

`input.decodeByte` ALREADY maps `0x03 => .{ .action = .quit }` (⇒ region exits 1) — it is
"effectively dead code" ONLY because ISIG intercepts 0x03 first. Disabling ISIG makes it live.

## The fix (ONE line, in app.makeRaw)
```zig
pub fn makeRaw(original: std.posix.termios) std.posix.termios {
    var raw = original;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.lflag.ISIG = false;   // ← ADD: stop kernel from turning Ctrl-c/z/\ into signals,
                              //   so they arrive as inert bytes input.zig classifies
    raw.iflag.IXON = false;
    raw.iflag.ICRNL = false;
    raw.iflag.BRKINT = false;
    raw.oflag.OPOST = false;
    raw.cflag.CSIZE = .CS8;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    return raw;
}
```
This fixes BOTH Issue 2 and Issue 3 (PRD explicitly recommends this as "the smaller, uniform
fix and aligns the cancel keys with input.zig's byte mappings"). No `input.zig` change needed.

## Unit test update (app.zig makeRaw test — Mode A, rides with the code)
The existing test "makeRaw: clears ICANON/ECHO/IXON/ICRNL/BRKINT/OPOST, sets CS8, MIN=1/TIME=0,
keeps rest" zeroes the termios then SETS the to-be-cleared flags. ISIG is false in a zeroed
termios, so the assertion must PROVE makeRaw clears a SET flag:
1. ADD `input.lflag.ISIG = true;` to the test's input termios.
2. ADD `try std.testing.expectEqual(false, raw.lflag.ISIG);` to the assertions.

Also update the "idempotent over an already-raw input" test to confirm ISIG stays false.

## Scope — what is NOT touched
- **`palette.zig` is OUT OF SCOPE.** It has its OWN raw-mode setup (palette.zig:106-109:
  ICANON/ECHO off, MIN=0/TIME=5). It runs OUTSIDE the popup for the short sync-palette OSC
  query. Changing it risks side effects and is unnecessary — the PRD issues are region-TUI-only.
- The SIGINT/SIGTERM/SIGQUIT handlers (`installSignalHandlers`) STAY — they handle EXTERNAL
  signals (`kill -TERM`, `kill -INT`). With ISIG off, tty-Ctrl-c no longer generates SIGINT
  (it becomes the exit-1 byte path), but external signals still restore-then-reraise correctly.
- No SIGTSTP handler is strictly required: with ISIG off, Ctrl-z is an inert byte (never a
  signal). An external `kill -TSTP` is an out-of-scope edge case (not a tty-control-char path,
  which is what Issue 2 is about). The PRD's recommended fix is ISIG off alone.

## Side-effect analysis (why disabling ISIG is safe)
- The only behavior changes are the three keys above — all become more correct/benign.
- Ctrl-c now matches §7.5 exactly (exit 1, grouped with q/Esc).
- The `classifyByte`/`default_handler`/`default_event_handler` all map 0x03 ⇒ quit — unchanged.
- No existing unit test asserts ISIG==true (the makeRaw test is the only one touching lflag
  flags, and it is updated additively). The 275-test ReleaseFast suite stays green.

## Integration regression harness (tests/region_signal_keys.sh)
A python3 pty drive over an isolated `-L t2h-sig-$$` socket (mirrors region_empty_confirm.sh).
Build the release binary; seed a pane; pty-fork `region --target $PANE`:

1. **Ctrl-z (0x1a):** send 0x1a, drain ~0.4s, send 'j', drain, read status line. Assert:
   - process is NOT stopped (WIFSTOPPED false / still reading input);
   - the status line `row:` CHANGED after 'j' (the TUI kept repainting ⇒ it never suspended);
   - a subsequent 'q' exits cleanly (status → exited, exit code 1).
   - The emitted bytes need NOT contain the restore seq while running (restore happens on quit).
2. **Ctrl-c (0x03):** send 0x03; assert exit code == 1 (NOT 130); assert NO output file and NO
   `.last-output` sidecar (quit ⇒ no output, PRD §7.5).
3. For comparison, drive 'q' once and assert exit 1 (the canonical cancel).

SKIP cleanly (exit 0) if tmux OR python3 absent. Teardown: `kill-session -t s` on the named
socket ONLY (trap). Use the absolute-REAL_TMUX PATH-shim prefixing `-L $SOCK` (no recursion,
no append log ⇒ check-safety clean). Wrap the binary drive under `scripts/safe-run.sh` if a
hardened resource cap is desired. Run ONE harness at a time (AGENTS.md).