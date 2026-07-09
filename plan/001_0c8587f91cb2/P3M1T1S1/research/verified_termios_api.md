# P3.M1.T1.S1 — Verified Zig 0.15.2 stdlib APIs (termios / signals / panic)

> All signatures below were verified by reading the Zig 0.15.2 stdlib at
> `/home/dustin/.local/opt/zig-x86_64-linux-0.15.2/lib/std/` AND the
> VERIFIED working termios usage already in THIS codebase at `src/palette.zig:104-111`.
> This is the authoritative reference for the PRP. Do NOT guess these APIs.

## 1. termios (the crux)

**Local precedent (strongest reference) — `src/palette.zig:104-111`:**
```zig
const original = try std.posix.tcgetattr(tty.handle);   // GOTCHA 8: restore in defer.
var raw = original;
raw.lflag.ICANON = false;                                // GOTCHA 6
raw.lflag.ECHO = false;                                  // GOTCHA 7
raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
raw.cc[@intFromEnum(std.posix.V.TIME)] = 5;              // 500ms (deciseconds)
try std.posix.tcsetattr(tty.handle, .FLUSH, raw);
defer std.posix.tcsetattr(tty.handle, .FLUSH, original) catch {};
```

**Stdlib signatures (verified):**
- `pub fn tcgetattr(handle: fd_t) TermiosGetError!termios` — `posix.zig:6757`
  - `TermiosGetError = TIOCError || UnexpectedError`; includes `error.NotATerminal`.
- `pub fn tcsetattr(handle: fd_t, optional_action: TCSA, termios_p: termios) TermiosSetError!void` — `posix.zig:6772`
  - `TermiosSetError = TermiosGetError || error{ProcessOrphaned}`.
- `pub const TCSA = enum(c_uint){ NOW, DRAIN, FLUSH }` — `posix.zig:219`.
- `pub const termios = system.termios` — `posix.zig:169`.

**The `termios` struct (os/linux.zig:7575, x86_64 shape):** an `extern struct` whose
fields are TYPED packed structs, so each flag is a named bool/bitfield you set directly:
```
termios{
  iflag: tc_iflag_t,   // packed struct(tcflag_t): IGNBRK, BRKINT, ICRNL, IXON, ... (os/linux.zig:7234)
  oflag: tc_oflag_t,   // packed struct(tcflag_t): OPOST, ONLCR, ...            (os/linux.zig:7311)
  cflag: tc_cflag_t,   // packed struct(tcflag_t): CSIZE(enum:CS5..CS8), CREAD, ... (os/linux.zig:7370)
  lflag: tc_lflag_t,   // packed struct(tcflag_t): ICANON, ECHO, ECHOE, IEXTEN, ... (os/linux.zig:7460)
  line: cc_t,
  cc: [NCCS]cc_t,      // cc_t = u8; indexed by @intFromEnum(V.MIN/V.TIME)
  ispeed: speed_t, ospeed: speed_t,
}
```
- **Set flags by name:** `raw.lflag.ICANON = false;` (bool field). `raw.cflag.CSIZE = .CS8;` (enum field).
- **cc indexing:** `raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;`
  - `pub const V = system.V` — `posix.zig:173`. `system.V` is an enum(u32) with `.MIN`/`.TIME`/... (os/linux.zig:7482; x86_64: MIN=6, TIME=5 — the enum VALUE is the cc[] index, so `@intFromEnum` is correct regardless of numeric value).
  - Use `std.posix.V` (matches palette.zig local precedent), NOT `std.posix.system.V` (both valid; system.V is the raw re-export).

## 2. fd / stdout / stdin idioms in THIS codebase
- `std.fs.File.stdin()` / `std.fs.File.stdout()` — wrappers; `.handle` is the `fd_t`.
- `stdin.handle == std.posix.STDIN_FILENO`; `stdout.handle == std.posix.STDOUT_FILENO`.
- Read: `stdin.read(&buf) !usize` (render.zig:361, palette.zig:144 idiom). Returns 0 on EOF.
- In a `tmux display-popup` pty, stdin AND stdout are dup'd to the SAME pty slave, so
  writing escape sequences to STDOUT and doing termios on STDIN both hit the same terminal
  (tcgetattr/tcsetattr work on either fd — termios is a property of the terminal, not the fd).

## 3. Signals (for panic-safe restore on Ctrl-C / kill)
- `pub const SIG = system.SIG` — `posix.zig:104`. `SIG` is a struct with `pub const INT = 2; TERM = 15; QUIT = 3;`
  and `pub const DFL: ?Sigaction.handler_fn = @ptrFromInt(0);` `pub const IGN = ... = @ptrFromInt(1);` (os/linux.zig:3730).
- `pub const Sigaction = system.Sigaction` — `posix.zig:114` (os/linux.zig:5712):
  ```
  Sigaction{
    pub const handler_fn = *align(1) const fn (i32) callconv(.c) void;
    pub const sigaction_fn = *const fn (i32, *const siginfo_t, ?*anyopaque) callconv(.c) void;
    handler: extern union { handler: ?handler_fn, sigaction: ?sigaction_fn },
    mask: sigset_t,
    flags: c_ulong,   // 0 for a basic restore-then-re-raise handler
  }
  ```
- `pub fn sigemptyset() sigset_t` — `posix.zig:5851`. Build the mask: `.mask = std.posix.sigemptyset()`.
- `pub fn sigaction(sig: u8, noalias act: ?*const Sigaction, noalias oact: ?*Sigaction) void` — `posix.zig:5894`.
  (sig is `u8`; `SIG.INT` is comptime_int → coerces.)
- `pub fn kill(pid: pid_t, sig: u8) ...` and `pub fn getpid() pid_t` — for re-raise.
- `pub fn exit(status: u8) noreturn` — `posix.zig:777` (kernel `exit_group`; async-signal-safe; the `_exit` equivalent).

**Async-signal-safety verdict (POSIX.1 §2.4.3 + practical):** `write(2)`, `raise`, `kill`,
`sigaction`, `exit`/`_exit` are on the POSIX async-signal-safe list. `tcsetattr`/`tcgetattr`
are NOT formally on it (they're thin `ioctl` syscall wrappers with no malloc/locks) but are
UNIVERSALLY used in signal handlers in practice (ncurses/readline/vim/tmux all restore termios
from signal handlers). For the PRP: a SIGINT/SIGTERM handler may legally call `std.posix.write`
and, in practice, `tcsetattr` — never `printf`/`malloc`. (Self-pipe/signalfd is the formally-clean
alternative but overkill for this short-lived region process.)

## 4. Zig 0.15.2 panic override (verified — builtin.zig:1085)
The root file may provide `pub const panic = std.debug.FullPanic(struct {
  fn panic(msg: []const u8, ra: ?usize) noreturn { ... }
}.panic);`. std detects this via `@hasDecl(root, "panic")`. Our override calls `tui.restoreRaw()`
(idempotent, guarded) THEN `std.debug.defaultPanic(msg, ra)` so the stack trace still prints
(in cooked mode, on the primary screen). MUST live in the root file = `src/main.zig`.

## 5. CRITICAL CORRECTION to tui_region.md §1 (typo)
The arch doc literally writes the restore sequence as `"\x1b[?25l->\x1b[?1049l"` — the `?25l`
is the cursor-HIDE code (wrong for restore). The canonical RESTORE is SHOW cursor + leave alt screen:
`exit_seq = "\x1b[?25h\x1b[?1049l"` (`?25h` = show cursor; `?1049l` = leave alt screen).
Enter sequence is correct: `enter_seq = "\x1b[?1049h\x1b[?25l"` (`?1049h` enter alt; `?25l` hide cursor).

## 6. TCSA choice (enter vs restore)
- ENTER raw mode with `.FLUSH` — discards stray typeahead so the TUI starts clean (matches palette.zig + tui_region.md §1).
- RESTORE with `.NOW` — simplest, no waiting, doesn't drop input the user may have just typed.
  (tui_region.md §1 + palette.zig use `.FLUSH` for restore too; `.NOW` is the safer convention on
  the restore path. Either compiles; pick `.NOW` for restore.)

## 7. VMIN/VTIME for the event loop (NOT palette's timed read)
palette.zig uses MIN=0/TIME=5 (500ms timeout) for OSC query reads. The TUI event loop wants
**MIN=1, TIME=0** = blocking read, returns as soon as ≥1 byte arrives (event-driven). This is the
correct setting; pitfalls are MIN=0/TIME=0 (busy-loop, read returns 0) or forgetting to set them.
A SIGINT during the blocking read interrupts it (EINTR) — but our handler re-raises, so the
process terminates before the loop observes the EINTR.

## 8. The re-raise idiom (restore → reset disposition → re-raise)
Inside the signal handler:
1. `restoreRaw()` (idempotent; termios + exit_seq via raw write).
2. Reset disposition to default: `sigaction(sig, &.{.handler=.{.handler=SIG.DFL}, .mask=sigemptyset(), .flags=0}, null)`.
3. Re-raise: `std.posix.kill(std.posix.getpid(), sig)` (or raise). Now the default disposition fires → process dies with exit 128+sig (SIGINT→130).
4. Fallback: `std.posix.exit(@intCast(128 + sig))` if re-raise somehow returns.
Never call `printf`/`malloc`/buffered-`exit` in the handler — use raw `write` + `std.posix.exit`.

## 9. The three-mechanism "restore always" rule
- `defer exit(state)` in the caller (region body, P3.M3) → normal + error returns.
- `sigaction` SIGINT/SIGTERM/SIGQUIT handler → restore + re-raise → Ctrl-C / kill.
- root `pub const panic` override → `restoreRaw()` + `defaultPanic` → Zig panics.
All three call ONE shared idempotent `restoreRaw()` guarded by a module-level atomic `entered` flag
(handler + panic have no context arg → saved termios MUST be a module-level `var`). This is the
single most important structural rule.

## Sources (recalled — re-fetch anchors before citing in CI)
- POSIX §2.4.3 async-signal-safe list: https://pubs.opengroup.org/onlinepubs/9699919799/functions/V2_chap02.html#tag_15_04
- POSIX tcsetattr (NOW/DRAIN/FLUSH): https://pubs.opengroup.org/onlinepubs/9699919799/functions/tcsetattr.html
- GNU readline signals.c (restore-then-re-raise reference): https://git.savannah.gnu.org/cgit/readline.git/tree/signals.c
- libvaxis (Zig TUI raw-mode + signals): https://github.com/rockorager/libvaxis
