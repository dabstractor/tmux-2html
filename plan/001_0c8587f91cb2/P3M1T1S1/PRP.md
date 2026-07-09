name: "P3.M1.T1.S1 — Alt-screen + raw termios + panic-safe restore + event loop (src/tui/app.zig)"
description: |

---

## Goal

**Feature Goal**: Create `src/tui/app.zig` — the foundational terminal-control module for the
copy-mode TUI (`tmux-2html region`). It is the ONE module that takes over the display-popup's
pty: it (1) **enters** the alternate screen + hides the cursor + switches stdin's tty to raw
termios (no echo, no canonical, byte-at-a-time blocking reads); (2) guarantees the terminal is
**ALWAYS restored** — cooked termios + primary screen + visible cursor — on EVERY exit path
(normal return, `error` return, SIGINT/SIGTERM/SIGQUIT, and Zig `panic`), per PRD §7.1
"Restore on exit, always, including panic"; (3) runs a **forward-compatible event loop** that
blocks on stdin one byte at a time and delegates each byte to a pluggable `Handler` that yields
an `Action` (`.quit` / `.confirm` / `.none`), returning when the handler says quit/confirm.

**Deliverable** (TWO files touched — ONE new, ONE existing — both minimal):
- **CREATE `src/tui/app.zig`** — the full module: `enter() !State`, `exit(state) void`,
  `restoreRaw() void` (the idempotent shared restore), `run(handler: Handler) !Action`,
  the `Action` enum + `Handler` seam + `default_handler` (quit-only: `q`/Ctrl-C/Esc),
  the SIGINT/SIGTERM/SIGQUIT signal-handler installer, and PURE unit-tested helpers
  (`makeRaw`, `classifyByte`, `enter_seq`, `exit_seq`).
- **MODIFY `src/main.zig`** — add (a) ONE import `const tui = @import("tui/app.zig");`,
  (b) a root-level **panic override** (`pub const panic = std.debug.FullPanic(...)`) that calls
  `tui.restoreRaw()` then chains to `std.debug.defaultPanic` so a panic restores the terminal,
  and (c) ONE line in the `test {}` block: `_ = @import("tui/app.zig");` so app.zig's tests are
  reachable from the test root. **Nothing else in main.zig changes** (the `region` dispatch stays
  `error.NotImplemented`; wiring region→app.zig is P3.M3).

**Nothing else changes**: do NOT modify `build.zig`/`build.zig.zon` (verified: `src/tui/` is under
`src/`, auto-compiled into the root module — no build change needed), `PRD.md`, `tasks.json`,
`cli.zig`, `render.zig`, `capture.zig`, `palette.zig`, or any other source. Sibling tasks
(`view.zig` T2, `input.zig`/`select.zig` P3.M2, `region.zig` P3.M3) **do not exist yet** — app.zig's
`Handler` seam is designed so they plug in LATER without rewriting `run()`.

**Success Definition**:
- `zig build test -Doptimize=ReleaseFast` passes; the new unit tests (`makeRaw`, `classifyByte`,
  `enter_seq`/`exit_seq`) are GREEN and reachable from `main.zig`'s `test {}` block.
  (ReleaseFast is MANDATORY — PRD §15 / `main.zig` Gotcha 1: `zig build test` in Debug hits a
  Zig linker bug `R_X86_64_PC64` with the bundled C++ SIMD libs; ReleaseFast is unaffected.)
- The module **compiles cleanly** in `--release=fast` (this is the automated proof that the
  termios / `sigaction` / panic-override APIs are used correctly — `enter`/`exit`/`restoreRaw`/
  `run`/the handler touch the REAL tty and are NOT unit-testable, exactly like `palette.queryColors`
  and `capture.real`, which are compile-verified + manually tested).
- **Manual restore smoke test** (in a real pty via `script`): launch a tiny harness, confirm the
  alt-screen is entered (blank screen, cursor hidden), type `q`, and confirm the terminal is
  restored (cooked termios, primary screen, visible cursor). Repeat with Ctrl-C and `kill -TERM`
  — terminal is restored in all cases. (Procedure in Validation Loop Level 3.)

## User Persona (if applicable)

**Target User**: `tmux-2html region` (P3.M3.T1 — the `region` subcommand body, currently an
`error.NotImplemented` stub in `cli.zig:region`). app.zig is an INTERNAL library consumed by
region; no end user calls it directly.

**Use Case**: PRD §5.3 / §7 — the user triggers the region key (`C-o`), tmux opens a 100%×100%
`display-popup` (a REAL pty) running `tmux-2html region`. region captures the full scrollback into
a grid (P3.M3), then calls `tui.enter()` to take over the pty, `tui.run(handler)` to let the user
move/select (P3.M2 supplies the handler), and on confirm/cancel restores + renders (P3.M3).

**User Journey**: `prefix C-o` → display-popup → `app.enter()` (alt screen + raw) → `app.run(view_input_handler)` → user presses keys → `q`/`Esc`/Ctrl-C → `app.exit(state)`/`restoreRaw()` → popup closes (`-E`) → user is back in their untouched tmux session.

**Pain Points Addressed**: the user's terminal is NEVER left in a broken state (raw mode, blank
alt screen, hidden cursor) if region crashes, panics, or is Ctrl-C'd. This is the hardest
correctness property of the whole TUI and the explicit subject of this subtask.

## Why

- **PRD §7.1 mandates "Enter alternate screen, hide cursor, raw termios (no echo, no canonical).
  Restore on exit (always, including panic)."** This module IS that contract. The display-popup
  gives region a real pty (§2 finding 2) so `/dev/tty` termios + OSC work — app.zig is what makes
  that pty safe to take over and give back.
- **The "restore always" guarantee is the foundation every later TUI task depends on.** view.zig
  (T2) writes escape sequences freely, input.zig/select.zig (P3.M2) assume raw byte-at-a-time
  input, and region.zig (P3.M3) calls `enter()`/`run()`/`exit()`. If app.zig's restore is wrong,
  the user's terminal is bricked on every crash — the single highest-risk regression surface.
  Getting it right (defer + signal + panic, ONE shared idempotent `restoreRaw`) in S1 means
  later tasks never revisit terminal control.
- **Forward compatibility via the `Handler` seam.** `run()` is byte-for-byte STABLE; only the
  `Handler` grows (mouse decode = S2, view repaint + vim/search/select = P3.M2). This mirrors
  `capture.zig`'s proven `Runner = { ctx, runFn }` mockability seam and `cli.zig`'s
  `body: *const fn(...) anyerror!u8` pointer — both established, working patterns in this repo.

## What

### Behavior (`src/tui/app.zig` — a NEW ghostty-free stdlib-only module)

1. **`enter() !State`**: read `stdin`'s termios via `std.posix.tcgetattr`; SAVE it (module global
   + into the returned `State`); write `enter_seq` to stdout; set raw termios via
   `std.posix.tcsetattr(fd, .FLUSH, makeRaw(original))`; install SIGINT/SIGTERM/SIGQUIT handlers
   via `std.posix.sigaction`; set the module `entered` flag; return `State{ .fd, .original }`.
2. **`exit(state: State) void`** and **`restoreRaw() void`**: the idempotent shared restore
   (guarded by an atomic `entered` flag so defer + signal + panic never double-restore). Writes
   `exit_seq` via raw `std.posix.write` (async-signal-safe) and restores termios via
   `std.posix.tcsetattr(fd, .NOW, original)`. `restoreRaw()` is the version the signal handler
   and the root panic override call (reads module globals, no params).
3. **`run(handler: Handler) !Action`**: block-read stdin one byte at a time
   (`stdin.read(&[1]u8)`); call `handler.classify(byte)`; return the `Action` on `.quit`/`.confirm`,
   `.none` = keep looping, EOF → `.quit`.
4. **`Handler` seam + `Action` enum + `default_handler`**: `Action = enum{ none, quit, confirm }`;
   `Handler = struct{ ctx: ?*anyopaque, classifyFn: *const fn(?*anyopaque, u8) Action }` (mirrors
   `capture.Runner`); `default_handler` is stateless (ctx=null) and quits on `q`(0x71),
   Ctrl-C(0x03), Esc(0x1b). Later tasks supply richer handlers.
5. **PURE helpers (unit-tested)**: `makeRaw(original: termios) termios`; `classifyByte(u8) Action`;
   the `enter_seq` / `exit_seq` `pub const` byte slices.

### `src/main.zig` — minimal additions (the panic override + test wiring)
- `const tui = @import("tui/app.zig");` (top, with the other imports).
- Root panic override: `pub const panic = std.debug.FullPanic(struct { fn panic(msg: []const u8, ra: ?usize) noreturn { tui.restoreRaw(); std.debug.defaultPanic(msg, ra); } }.panic);`
- In the top-level `test { ... }` block: `_ = @import("tui/app.zig");`.

### Success Criteria

- [ ] `src/tui/app.zig` exists and compiles under `--release=fast`; it imports ONLY `std` (ghostty-free ⇒ its tests are safe as SEPARATE `test` fns, like `capture.zig`/`palette.zig`).
- [ ] Unit tests GREEN: `makeRaw` clears `lflag.{ICANON,ECHO}` + `iflag.{IXON,ICRNL,BRKINT}` + `oflag.OPOST`, sets `cflag.CSIZE = .CS8`, sets `cc[V.MIN]=1`/`cc[V.TIME]=0`, and leaves the other fields EQUAL to the input; `classifyByte('q')`/`(0x03)`/`(0x1b)` == `.quit`, everything else == `.none`; `enter_seq == "\x1b[?1049h\x1b[?25l"`, `exit_seq == "\x1b[?25h\x1b[?1049l"`.
- [ ] `main.zig` panic override present; `main.zig` `test {}` block imports `tui/app.zig`; `zig build test -Doptimize=ReleaseFast` is GREEN (no regressions in the existing suite).
- [ ] Manual smoke test (Level 3): alt-screen entered + raw mode on at launch; terminal fully restored after `q`, after Ctrl-C, and after `kill -TERM`.

## All Needed Context

### Context Completeness Check

_Passed._ An agent who knows nothing about this codebase can implement this from: the verified
termios/signal/panic API reference in `research/verified_termios_api.md`, the LOCAL working
termios precedent at `src/palette.zig:104-111`, the `capture.Runner` seam to mirror for `Handler`,
and `tui_region.md` §1 (with its one typo corrected, flagged below). Every Zig 0.15.2 stdlib
signature below was verified by reading the stdlib at `/home/dustin/.local/opt/zig-x86_64-linux-0.15.2/lib/std/`.

### Documentation & References

```yaml
# MUST READ — verified API reference (PRIMARY; do not guess the termios/signal/panic APIs)
- file: plan/001_0c8587f91cb2/P3M1T1S1/research/verified_termios_api.md
  why: Every stdlib signature (tcgetattr/tcsetattr/TCSA, the termios packed-struct field API,
       std.posix.V, SIG/sigaction/sigemptyset/getpid/exit, the FullPanic override), the VMIN/VTIME
       choice, the re-raise idiom, and the corrected exit_seq — all verified against the stdlib.
  critical: The exact field-syntax `raw.lflag.ICANON = false`, `raw.cflag.CSIZE = .CS8`,
            `raw.cc[@intFromEnum(std.posix.V.MIN)] = 1`. Use `std.posix.V` (NOT system.V) to
            match palette.zig. tui_region.md §1 has a TYPO in the restore seq — use `?25h`.

# MUST READ — the architecture doc for the whole TUI (§1 is the verified termios pattern)
- file: plan/001_0c8587f91cb2/architecture/tui_region.md
  why: §1 gives the verified term2html terminal.zig raw pattern (the source of the contract).
       §8 confirms the TUI works purely on the in-memory grid + pty stdin/stdout (no tmux after capture).
  section: §1 (Hosting & terminal control), §8 (Open implementation detail)
  gotcha: §1's restore literal "\x1b[?25l->\x1b[?1049l" uses ?25l (HIDE cursor) — WRONG for restore.
          The correct restore is "\x1b[?25h\x1b[?1049l" (?25h = SHOW cursor, ?1049l = leave alt screen).

# MUST READ — the LOCAL working termios precedent (the strongest reference; in this codebase)
- file: src/palette.zig
  why: Lines 104-111 are VERIFIED working termios usage IN THIS REPO: tcgetattr, the flag-clearing
       idiom, std.posix.V.MIN/TIME, tcsetattr(fd, .FLUSH, raw), and `defer tcsetattr(..., original)`.
  pattern: copy the flag-clearing + cc-indexing syntax exactly; change MIN/TIME to 1/0 (blocking)
           instead of palette's 0/5 (500ms timed OSC read). Mirror the `defer` restore.
  gotcha: palette's restore also uses .FLUSH; the convention on the RESTORE path is .NOW (don't drop
          user input). Either compiles; use .NOW for restore.

# MUST READ — the Handler seam to mirror (proven mockability pattern in this repo)
- file: src/capture.zig
  why: `Runner = struct { ctx: *anyopaque, runFn: *const fn(ctx, argv, alloc) anyerror![]u8 }` is the
       exact shape `Handler` should mirror (ctx + function pointer; @alignCast when recovering the
       typed pointer in 0.15.2). It is ghostty-free ⇒ separately unit-testable — app.zig is too.
  pattern: copy the `{ ctx, runFn }` struct + a thin `pub fn run(...)`/`classify(...)` method.

# READ — the contract spec + the testing/safety rules
- file: PRD.md
  why: §7.1 (Display: enter alt-screen/hide-cursor/raw/restore-always), §0 + §15 (NEVER touch the
       user's running tmux; test on an isolated server; ReleaseFast mandatory for `zig build test`).

# READ — where main.zig's test block + dispatch live (the two files you touch)
- file: src/main.zig
  why: The bottom `test { ... }` block (add `_ = @import("tui/app.zig");`); the top imports
       (add `const tui = @import("tui/app.zig");`); the root scope (add the `pub const panic`
       override). NOTE: `cli.region` stays `error.NotImplemented` — do NOT wire it here.
  gotcha: A root `pub const panic` overrides the WHOLE binary's panic handler — that is intended and
          safe because `tui.restoreRaw()` is a guarded no-op when the TUI hasn't been entered.

# READ (analogue PRP for STRUCTURE/format) — a ghostty-free stdlib-only module, closest analogue
- file: plan/001_0c8587f91cb2/P2M1T1S1/PRP.md
  why: capture.zig is the closest architectural twin: stdlib-only, a {ctx,runFn} seam, pure helpers
       split from real-fd fns, and unit tests that are SAFE as separate fns. Mirror that split.

# EXTERNAL (best-practice references; re-fetch anchors before CI citation)
- url: https://pubs.opengroup.org/onlinepubs/9699919799/functions/V2_chap02.html#tag_15_04
  why: POSIX §2.4.3 async-signal-safe function list — write/raise/kill/sigaction/_exit are safe;
       tcsetattr is NOT formally listed but is universally safe in practice (thin ioctl wrapper).
- url: https://git.savannah.gnu.org/cgit/readline.git/tree/signals.c
  why: GNU readline's restore-then-re-raise signal idiom (restore termios, sigaction(SIG_DFL), kill) —
       the canonical reference for the signal-handler restore path.
```

### Current Codebase tree (relevant slice)

```bash
src/
├── main.zig          # entry; dispatches subcommands; has the root `test {}` block + (you add) `pub const panic`
├── cli.zig           # RegionOpts + region() stub (error.NotImplemented) — DO NOT change
├── palette.zig       # ← LOCAL VERIFIED termios pattern at lines 104-111 (the model to copy)
├── capture.zig       # ← the Runner seam to mirror for Handler
├── render.zig        # WindowSize/getSize (NOT used by app.zig S1 — size defers to view.zig T2)
└── (no tui/ dir yet) # ← you CREATE src/tui/app.zig
plan/001_0c8587f91cb2/architecture/tui_region.md   # §1 verified termios pattern (mind the ?25l typo)
```

### Desired Codebase tree with files to be added/modified

```bash
src/
├── tui/
│   └── app.zig       # NEW — alt-screen + raw termios + panic/signal-safe restore + run() event loop
└── main.zig          # MODIFIED — +import tui, +root `pub const panic` override, +1 test{} import line
```

### Known Gotchas of our codebase & Library Quirks

```zig
// CRITICAL: `zig build test` (Debug) HITS a Zig linker bug (R_X86_64_PC64) with the bundled
//   C++ SIMD libs. Tests MUST run as `zig build test -Doptimize=ReleaseFast` (PRD §15).
//   Every Validation command below uses ReleaseFast.

// CRITICAL: app.zig imports ONLY `std` (NO ghostty-vt). This is deliberate: modules that do NOT
//   call ghostty_vt.Terminal.init are SAFE to have many separate `test` fns (no single-test-scope
//   GOTCHA that constrains render.zig/golden_test.zig). Keep it std-only — adding a ghostty
//   import here would re-introduce that constraint and is out of scope anyway.

// CRITICAL: the termios flags are TYPED packed structs, not raw ints. Set them by NAME:
//   raw.lflag.ICANON = false;            // bool field
//   raw.cflag.CSIZE = .CS8;              // ENUM field (CS5|CS6|CS7|CS8)
//   raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;   // cc is [NCCS]u8; @intFromEnum gives the index

// CRITICAL: use `.FLUSH` on ENTER (discards stray typeahead) and `.NOW` on RESTORE (don't drop
//   user input). Both are std.posix.TCSA enum members. palette.zig uses .FLUSH for both; .NOW on
//   restore is the safer convention and compiles identically.

// CRITICAL: VMIN=1 / VTIME=0 (BLOCKING, byte-at-a-time) for the event loop — NOT palette's 0/5.
//   Forgetting them, or MIN=0/TIME=0, busy-loops (read() returns 0 immediately). A SIGINT during
//   the blocking read returns EINTR — but our handler RE-RAISES, so the loop never observes it.

// CRITICAL: tui_region.md §1 restore sequence is a TYPO ("\x1b[?25l..." = HIDE cursor).
//   The correct restore is SHOW cursor + leave alt screen: "\x1b[?25h\x1b[?1049l".

// CRITICAL: the signal handler + root panic override have NO context argument, so the saved
//   termios MUST be a module-level `var` (guarded by an atomic `entered` flag). restoreRaw() must
//   be IDEMPOTENT (atomic swap on `entered`) so defer + handler + panic never double-restore.

// GOTCHA: `.link_libc = false` (build.zig). So you CANNOT use libc `openpty`. enter() uses the
//   stdin/stdout fds the display-popup already wired up (region's process inherits the pty as
//   fd 0/fd 1). Do NOT open /dev/tty yourself in app.zig (unlike palette.queryColors, which runs
//   outside the popup) — the popup IS the tty.

// GOTCHA: Zig 0.15.2 `sigaction` handler signature is `*align(1) const fn (i32) callconv(.c) void`
//   — note `align(1)` is REQUIRED on the fn pointer type, and `callconv(.c)`. sig is `u8` in the
//   std.posix.sigaction call; the handler receives it as `i32` — cast with @intCast when re-raising.

// GOTCHA: the root panic override MUST be in main.zig (the root file), detected via @hasDecl(root,"panic").
//   app.zig EXPOSES restoreRaw(); main.zig's panic override CALLS it then chains to defaultPanic.
```

## Implementation Blueprint

### Data models and structure

```zig
// src/tui/app.zig — top of file. Ghostty-free (imports ONLY std) ⇒ separate test fns are safe.

const std = @import("std");

/// Why the run loop stopped. S1 yields only .quit (default_handler). .confirm is RESERVED —
/// future select/input handlers yield it on Enter/y with an active selection. region.zig (P3.M3)
/// maps .confirm→render+sidecar, .quit→no output. .none = byte consumed, keep looping.
pub const Action = enum { none, quit, confirm };

/// Saved terminal state. Carries ONLY what's needed to restore. S1 fields: fd + original termios.
/// S2 may add a `mouse_enabled` flag; the struct GROWS without changing enter/exit signatures.
pub const State = struct {
    fd: std.posix.fd_t,
    original: std.posix.termios,
};

/// Pluggable per-byte handler — MIRRORS capture.zig's `Runner = { ctx, runFn }` seam. S1 ships
/// `default_handler` (stateless). Later tasks build a Handler with a typed ctx:
///   S2 mouse      → ctx owns a decode buffer; classify() accumulates \x1b[<... sequences
///   T2 view       → ctx points at the view; classify() triggers repaint side-effects
///   P3.M2 input   → ctx points at the key decoder (vim/search) → returns motions
///   P3.M2 select  → classify() yields .confirm on Enter/y with an active selection
/// `run()`'s body never changes across any of these — only WHICH Handler is passed in.
/// ctx is ?*anyopaque (nullable) so the stateless default passes null. Recover a typed pointer
/// in a future handler via `@ptrCast(@alignCast(ctx.?))` (capture.zig 0.15.2 rule).
pub const Handler = struct {
    ctx: ?*anyopaque,
    classifyFn: *const fn (ctx: ?*anyopaque, byte: u8) Action,

    pub fn classify(self: Handler, byte: u8) Action {
        return self.classifyFn(self.ctx, byte);
    }
};
```

### Module-level backstop state (handler + panic have no context arg ⇒ globals)

```zig
// THE shared crash-recovery state. `entered` is the idempotency guard (atomic so defer +
// signal + panic can't double-restore from different contexts). Set in enter(); cleared by
// restoreRaw(). saved/saved_fd are read by the signal handler + panic override.
var entered = std.atomic.Value(bool).init(false);
var saved: ?std.posix.termios = null;
var saved_fd: std.posix.fd_t = -1;
var panic_in_progress = false; // recursion guard for the root panic override

// Escape sequences (PRD §7.1; tui_region.md §1 with the ?25l typo CORRECTED).
pub const enter_seq = "\x1b[?1049h\x1b[?25l"; // enter alt screen (?1049h) + hide cursor (?25l)
pub const exit_seq  = "\x1b[?25h\x1b[?1049l";  // SHOW cursor (?25h) + leave alt screen (?1049l)
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: CREATE src/tui/app.zig — PURE helpers + Action/State/Handler/sequences
  - IMPLEMENT: `Action` enum, `State` struct, `Handler` seam (above), `enter_seq`/`exit_seq` consts.
  - IMPLEMENT: `pub fn makeRaw(original: std.posix.termios) std.posix.termios` — copy `original`,
    clear lflag.{ICANON,ECHO}; iflag.{IXON,ICRNL,BRKINT}; oflag.OPOST; set cflag.CSIZE=.CS8;
    set cc[@intFromEnum(std.posix.V.MIN)]=1, cc[...TIME]=0. Return the modified copy. PURE.
  - IMPLEMENT: `pub fn classifyByte(byte: u8) Action` — 'q'(0x71), Ctrl-C(0x03), Esc(0x1b) ⇒ .quit;
    else .none. PURE.
  - FOLLOW pattern: src/palette.zig:104-111 (the EXACT flag-clearing + cc-indexing syntax; copy it,
    change MIN/TIME to 1/0) and src/capture.zig `Runner` (the {ctx, classifyFn} seam shape).
  - NAMING: snake_case fns, CamelCase types; `pub const` for the escape sequences.
  - WRITE UNIT TESTS HERE (Task 6) — they live in the same file, appended below the impl.

Task 2: ADD module-level backstop + restoreRaw() to src/tui/app.zig
  - IMPLEMENT: the `var entered`, `var saved`, `var saved_fd`, `var panic_in_progress` globals (above).
  - IMPLEMENT: `pub fn restoreRaw() void` — IDEMPOTENT restore.
      if (!entered.swap(false, .acq_rel)) return;     // already restored (defer/handler/panic)
      // raw write (async-signal-safe) of exit_seq to the tty's stdout; restore termios on the saved fd.
      _ = std.posix.write(saved_fd, exit_seq) catch {};            // saved_fd is the pty (stdin==pty)
      if (saved) |s| std.posix.tcsetattr(saved_fd, .NOW, s) catch {};
  - GOTCHA: restoreRaw uses saved_fd (the pty stdin fd) for BOTH the escape write and the termios
    restore — in the display-popup, stdin/stdout are the same pty, so writing alt-screen escapes to
    saved_fd works AND tcsetattr on saved_fd restores the terminal. Using one fd avoids needing
    STDOUT_FILENO in the signal handler. (Verify: writing escapes to fd 0 in raw mode is fine — pty
    is bidirectional.)
  - NOT unit-testable (real fd) — compile-verified + manually tested (mirrors palette.queryColors).

Task 3: ADD enter() + exit() to src/tui/app.zig
  - IMPLEMENT: `pub fn enter() !State`:
      const stdin = std.fs.File.stdin(); const fd = stdin.handle;
      const original = std.posix.tcgetattr(fd) catch return error.NoTty;  // .NotATerminal etc.
      saved = original; saved_fd = fd;                                   // backstop for handler/panic
      try std.fs.File.stdout().writeAll(enter_seq);                      // alt screen + hide cursor
      try std.posix.tcsetattr(fd, .FLUSH, makeRaw(original));            // .FLUSH on enter (drop typeahead)
      installSignalHandlers();                                           // Task 4
      entered.store(true, .release);
      return .{ .fd = fd, .original = original };
  - IMPLEMENT: `pub fn exit(state: State) void` — for the caller's `defer exit(state)`. Delegates to
    restoreRaw() (so the defer path shares the ONE idempotent restore). The `state` param documents
    the enter/exit pairing (contract requirement); the actual values come from the module globals
    set in enter() (they're equal to state). Set `entered=false` via restoreRaw's swap.
  - NOT unit-testable — compile-verified + manually tested.

Task 4: ADD the signal-handler installer + handler to src/tui/app.zig
  - IMPLEMENT: `fn sigHandler(sig: c_int) callconv(.c) void` — the re-raise idiom:
      restoreRaw();                                                     // restore termios + leave alt screen
      const s: u8 = @intCast(sig);
      var dfl = std.posix.Sigaction{ .handler = .{ .handler = std.posix.SIG.DFL },
                                     .mask = std.posix.sigemptyset(), .flags = 0 };
      std.posix.sigaction(s, &dfl, null);                               // reset to default disposition
      std.posix.kill(std.posix.getpid(), s);                            // re-raise → dies with 128+s
      std.posix.exit(@intCast(128 + sig));                              // fallback (shouldn't return)
  - IMPLEMENT: `fn installSignalHandlers() void`:
      const h: ?std.posix.Sigaction.handler_fn = &sigHandler;
      var act = std.posix.Sigaction{ .handler = .{ .handler = h },
                                     .mask = std.posix.sigemptyset(), .flags = 0 };
      std.posix.sigaction(std.posix.SIG.INT, &act, null);   // Ctrl-C
      std.posix.sigaction(std.posix.SIG.TERM, &act, null);  // kill
      std.posix.sigaction(std.posix.SIG.QUIT, &act, null);  // Ctrl-\ (cleanup + core)
  - GOTCHA: the handler_fn type is `*align(1) const fn (i32) callconv(.c) void` — your fn MUST be
    `callconv(.c)` and take `c_int`/`i32`. `std.posix.SIG.DFL` is `?Sigaction.handler_fn` (ptrFromInt(0)).
    sigaction takes `u8`; SIG.INT/Term/QUIT are comptime_int → coerce.
  - NOT unit-testable — compile-verified + manually tested (Level 3 Ctrl-C + kill -TERM).

Task 5: ADD run() + default_handler to src/tui/app.zig
  - IMPLEMENT: `pub fn run(handler: Handler) !Action`:
      const stdin = std.fs.File.stdin();
      var buf: [1]u8 = undefined;
      while (true) {
          const n = stdin.read(&buf) catch return error.ReadFailed;     // 0..=1 (raw, MIN=1)
          if (n == 0) return .quit;                                      // EOF
          switch (handler.classify(buf[0])) {
              .none => continue,
              .quit, .confirm => return .{ ... },                        // yield the Action
          }
      }
  - IMPLEMENT: `pub const default_handler: Handler = .{ .ctx = null, .classifyFn = defaultClassify };`
    with `fn defaultClassify(_: ?*anyopaque, byte: u8) Action { return classifyByte(byte); }`.
  - FOLLOW pattern: src/render.zig:361 + src/palette.zig:144 (the `File.read(&buf) !usize` idiom).
  - run() is the STABLE forward-compat surface — later tasks only change WHICH Handler is passed.

Task 6: ADD unit tests to src/tui/app.zig (the testable core)
  - TEST makeRaw: build a termios with ICANON/ECHO/IXON/ICRNL/BRKINT/OPOST SET and CSIZE!=CS8; call
    makeRaw; assert each flag is cleared, cflag.CSIZE==.CS8, cc[V.MIN]==1, cc[V.TIME]==0, AND that
    unrelated fields (ispeed/ospeed) are unchanged from the input. (Use a default termios literal;
    the packed structs default all bools to false — set the ones you test to true first.)
  - TEST classifyByte: assert classifyByte('q')/.==.quit, (0x03)==.quit, (0x1b)==.quit; and a few
    non-quit bytes ('j','\n','h',0x00,0xff)==.none.
  - TEST sequences: std.testing.expectEqualStrings(enter_seq, "\x1b[?1049h\x1b[?25l");
    expectEqualStrings(exit_seq, "\x1b[?25h\x1b[?1049l").
  - COVERAGE: these 3 pure surfaces. enter/exit/restoreRaw/run/sigHandler/installSignalHandlers are
    NOT tested (real fd) — compile-verified + manually tested (Level 3), exactly like palette.queryColors.
  - These are SAFE as separate `test` fns (app.zig is ghostty-free — no Terminal.init GOTCHA).

Task 7: MODIFY src/main.zig — import + root panic override + test wiring
  - ADD (top, with imports): `const tui = @import("tui/app.zig");`
  - ADD (root scope, e.g. near `version_string`): the panic override —
        pub const panic = std.debug.FullPanic(struct {
            fn panic(msg: []const u8, ra: ?usize) noreturn {
                if (!tui.panic_in_progress) {                 // recursion guard
                    tui.panic_in_progress = true;             // (expose panic_in_progress as pub var)
                    tui.restoreRaw();                          // restore terminal (guarded no-op if TUI not entered)
                }
                std.debug.defaultPanic(msg, ra);              // standard trace + abort
            }
        }.panic);
    GOTCHA: this overrides panic for the WHOLE binary — INTENDED + SAFE because restoreRaw() is a
    guarded no-op when the TUI wasn't entered (flag false). render/pane/sync-palette panics are
    unaffected except the terminal is restored first IF raw mode was active (it isn't, for them).
  - ADD (in the bottom `test { ... }` block, alongside the other @import lines):
        _ = @import("tui/app.zig"); // P3.M1.T1.S1: keep tui/app.zig tests reachable from the test root.
  - PRESERVE: `cli.region` stays `error.NotImplemented`; all existing imports/tests untouched.
  - GOTCHA: expose `panic_in_progress` as `pub var` in app.zig so main.zig's override can read/set it
    (Task 2 listed it as `var`; make it `pub var`). Alternatively keep the guard INSIDE restoreRaw
    (restoreRaw checks panic_in_progress) so main.zig just calls `tui.restoreRaw()` unconditionally —
    PREFER this simpler form: `tui.restoreRaw(); std.debug.defaultPanic(msg, ra);` and let restoreRaw
    itself be fully idempotent (the `entered` swap already guards re-entry; add a panic_in_progress
    check inside restoreRaw if you want belt-and-suspenders). Pick the form that compiles cleanest.
```

### Implementation Patterns & Key Details

```zig
// === makeRaw — the PURE, unit-tested core. Copy the flag syntax from palette.zig:106-109. ===
pub fn makeRaw(original: std.posix.termios) std.posix.termios {
    var raw = original;
    raw.lflag.ICANON = false;   // no canonical (line) mode
    raw.lflag.ECHO = false;     // no echo of keystrokes
    raw.iflag.IXON = false;     // disable Ctrl-S/Ctrl-Q flow control
    raw.iflag.ICRNL = false;    // don't translate CR→NL
    raw.iflag.BRKINT = false;   // SIGINT on break off
    raw.oflag.OPOST = false;    // no output processing (we emit raw escapes)
    raw.cflag.CSIZE = .CS8;     // 8-bit chars (term2html/tui_region §1)
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;  // BLOCKING: read returns ≥1 byte (palette uses 0)
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0; // no inter-byte timer (palette uses 5)
    return raw;
}

// === restoreRaw — ONE idempotent restore called by defer (via exit) + signal handler + panic ===
pub fn restoreRaw() void {
    if (!entered.swap(false, .acq_rel)) return;       // already restored ⇒ no-op (double-restore safe)
    if (saved_fd < 0) return;                          // never entered ⇒ nothing to restore
    _ = std.posix.write(saved_fd, exit_seq) catch {};  // raw write (async-signal-safe): show cursor + leave alt
    if (saved) |s| std.posix.tcsetattr(saved_fd, .NOW, s) catch {}; // .NOW restore (don't drop user input)
}

// === The caller's shape (P3.M3 region.zig — NOT in this subtask, shown for context) ===
//   var state = try tui.enter();
//   defer tui.exit(state);                  // normal + error returns
//   const act = try tui.run(tui.default_handler);   // S1 quits on q/Ctrl-C/Esc; later: a real handler
//   switch (act) { .confirm => render(...), .quit => {}, .none => unreachable }
```

### Integration Points

```yaml
BUILD:
  - change: NONE. `src/tui/` is under `src/`, which is the root module's package root
    (build.zig: root_source_file = src/main.zig). app.zig is pulled into BOTH the prod exe and the
    test binary transitively once main.zig @imports it (Task 7). No build.zig / build.zig.zon edit.
  - verify: `zig build -Doptimize=ReleaseFast` succeeds; `zig build test -Doptimize=ReleaseFast` GREEN.

TEST WIRING:
  - add to: src/main.zig `test { ... }` block (alongside `_ = @import("capture.zig");` etc.)
  - line:  `_ = @import("tui/app.zig");`

PANIC HOOK (whole binary):
  - add to: src/main.zig ROOT scope (must be root — detected via @hasDecl(root,"panic"))
  - form:  `pub const panic = std.debug.FullPanic(struct{ fn panic(msg, ra) noreturn {...} }.panic);`
  - calls: `tui.restoreRaw()` then `std.debug.defaultPanic(msg, ra)`.

FUTURE CONSUMERS (do NOT implement now — boundary docs only):
  - P3.M1.T1.S2 (mouse): extends enter/exit to also write `\x1b[?1000h\x1b[?1002h\x1b[?1006h` and
    decode SGR mouse in a stateful Handler.ctx. app.zig's run() is unchanged.
  - P3.M1.T2 (view.zig): reuses render.getSize() for the viewport; renders grid + status line. app.zig S1 owns NO rendering + NO size query.
  - P3.M2.T1 (input.zig): supplies the real Handler (vim motions/search/counts) — multi-byte decode buffer lives in its Handler.ctx.
  - P3.M2.T2 (select.zig): its Handler yields .confirm on Enter/y with an active selection.
  - P3.M3.T1 (region.zig): captures full scrollback → grid → calls tui.enter()/run()/exit(); on .confirm renders the selection.
```

## Validation Loop

> **MANDATORY:** every `zig build`/`zig build test` below uses `-Doptimize=ReleaseFast`
> (PRD §15 / main.zig Gotcha 1: Debug-mode `zig build test` hits a Zig linker bug
> `R_X86_64_PC64` with the bundled C++ SIMD libs; ReleaseFast is unaffected).

### Level 1: Syntax & Style (Immediate Feedback)

```bash
cd /home/dustin/projects/tmux-2html
# Compile the whole binary in ReleaseFast — this is the primary proof that the termios /
# sigaction / FullPanic APIs are used CORRECTLY (enter/exit/run can't be unit-tested).
zig build -Doptimize=ReleaseFast
# Expected: zero errors. If the termios field syntax, TCSA member, sigaction handler type, or
# FullPanic form is wrong, it fails HERE — read the error, fix against research/verified_termios_api.md.
```

### Level 2: Unit Tests (the testable core)

```bash
cd /home/dustin/projects/tmux-2html
# Run the full suite (includes app.zig's makeRaw/classifyByte/sequence tests via main.zig's test block).
zig build test -Doptimize=ReleaseFast
# Expected: all GREEN, including the new app.zig tests and ZERO regressions in the existing suite.
#
# If you want to see app.zig's tests in isolation while developing, temporarily comment other
# @import lines — but the GATE is the full `zig build test -Doptimize=ReleaseFast` being green.
```

### Level 3: Manual restore smoke test (real pty — enter/exit/restoreRaw/signal/panic)

> enter()/exit()/restoreRaw()/run()/sigHandler/installSignalHandlers touch the REAL tty and are
> NOT unit-testable — this manual test is their validation (mirrors how palette.queryColors /
> capture.real are compile-verified + manually tested). Since `region` isn't wired until P3.M3,
> use `script` (util-linux) to provide a pty and a tiny throwaway harness, OR a temporary local
> test main. **Do NOT wire region here.** Teardown: only the process you started.

```bash
cd /home/dustin/projects/tmux-2html
# OPTION A — throwaway harness via `script` (provides a pty; -q quiet, -f flush, -c command).
# Replace ./harness with a TEMPORARY binary that calls tui.enter(); _=tui.run(tui.default_handler); tui.exit(state);
# (build it in a scratch dir / a `zig build test`-style temp exe; DELETE it after — never commit it).
#
# 1) Normal quit on 'q':
printf 'q' | script -qfc './scratch_tui_harness' /dev/null   # should enter alt-screen, restore, exit cleanly
# 2) Ctrl-C (SIGINT) — terminal MUST still be restored:
printf '\003' | script -qfc './scratch_tui_harness' /dev/null
# 3) SIGTERM via kill:
./scratch_tui_harness & PID=$!; sleep 0.3; kill -TERM $PID; wait $PID;  # alt screen left, termios cooked
#
# Verify RESTORE explicitly with stty around the run (real interactive terminal):
stty -g > /tmp/before;  ./scratch_tui_harness < /dev/tty  (type q)  ; stty -g > /tmp/after; diff /tmp/before /tmp/after
# Expected: NO diff (termios identical before/after). Repeat piping '\003' and using kill -TERM.
#
# Cleanup (NEVER touch a tmux server; only the scratch artifact you created):
rm -f ./scratch_tui_harness /tmp/before /tmp/after
```

```bash
# OPTION B — if a throwaway harness is awkward, DEFER the end-to-end restore assertion to P3.M3's
# region integration test (isolated tmux server per PRD §0/§15), and for S1 rely on:
#   (1) Level 1 compile (API correctness), (2) Level 2 unit tests (pure logic), and
#   (3) a quick interactive eyeball: run the harness in your terminal, see a blank alt screen with
#       no cursor, press q, confirm you're back on the primary screen with the cursor visible.
# Record which option you used in the implementation summary.
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Confirm the module is ghostty-free (a discipline check — adding a ghostty import would re-introduce
# the single-test-scope GOTCHA and is out of scope):
! grep -n 'ghostty' src/tui/app.zig   # Expected: no matches (grep exits 1)

# Confirm the corrected exit_seq (the tui_region.md §1 typo is NOT in your code):
grep -n 'exit_seq' src/tui/app.zig    # Expected: exit_seq = "\x1b[?25h\x1b[?1049l"  (?25h, NOT ?25l)

# Confirm main.zig wires the panic override + test import:
grep -n 'pub const panic = std.debug.FullPanic' src/main.zig   # Expected: 1 match
grep -n '@import("tui/app.zig")' src/main.zig                  # Expected: 2 matches (const tui + test block)
```

## Final Validation Checklist

### Technical Validation

- [ ] `zig build -Doptimize=ReleaseFast` succeeds (termios/sigaction/FullPanic APIs used correctly).
- [ ] `zig build test -Doptimize=ReleaseFast` is GREEN — new app.zig unit tests pass + ZERO regressions.
- [ ] app.zig imports ONLY `std` (ghostty-free ⇒ separate test fns are safe).
- [ ] No new build.zig / build.zig.zon changes (verified: `src/tui/` auto-compiled into the root module).

### Feature Validation

- [ ] `makeRaw` clears ICANON/ECHO/IXON/ICRNL/BRKINT/OPOST, sets CSIZE=.CS8, cc[V.MIN]=1/cc[V.TIME]=0, leaves other fields intact (unit-tested).
- [ ] `classifyByte` returns .quit for q/Ctrl-C/Esc, .none otherwise (unit-tested).
- [ ] `enter_seq`/`exit_seq` are the exact corrected bytes (?25h on restore, NOT ?25l) (unit-tested).
- [ ] Manual smoke test (Level 3): terminal restored after `q`, after Ctrl-C, after `kill -TERM`.
- [ ] `run(default_handler)` returns `.quit` on EOF and on the three quit bytes; loops on everything else.

### Code Quality Validation

- [ ] Follows existing codebase patterns: termios syntax from `palette.zig:104-111`; `Handler` seam mirrors `capture.Runner`; stdin read idiom from `render.zig`/`palette.zig`.
- [ ] `restoreRaw()` is ONE idempotent function shared by defer (via exit) + signal handler + panic override (the "restore always" rule).
- [ ] Saved termios is a module-level `var` (handler + panic have no context arg); `entered` atomic flag guards double-restore.
- [ ] Scope boundary respected: NO mouse (S2), NO key decoding/vim/search (P3.M2.T1), NO selection (P3.M2.T2), NO grid/status rendering (T2 view.zig), NO confirm→render/sidecar (P3.M3), NO size query (T2). app.zig S1 = terminal control + event loop ONLY.

### Documentation & Deployment

- [ ] No user-facing docs (item contract: "DOCS: none — internal"). Code is self-documenting with the WHY comments above.
- [ ] `cli.region` remains `error.NotImplemented` (wiring is P3.M3 — do NOT touch it here).

---

## Anti-Patterns to Avoid

- ❌ Don't open `/dev/tty` in app.zig (unlike palette.queryColors, which runs outside the popup). The display-popup IS the tty — use the inherited stdin/stdout fds. `.link_libc=false` means no libc `openpty` anyway.
- ❌ Don't use `.FLUSH` on the RESTORE path for termios if it would drop user input — `.NOW` is the convention on restore (`.FLUSH` is for ENTER, to drop stray typeahead). (palette.zig uses .FLUSH for restore too; either compiles — prefer .NOW.)
- ❌ Don't copy tui_region.md §1's restore literal verbatim — its `?25l` is a cursor-HIDE typo. Use `?25h` (show) on restore.
- ❌ Don't create new patterns: the `Handler` seam mirrors `capture.Runner`; the termios syntax mirrors `palette.zig`; the stdin-read idiom mirrors `render.zig`/`palette.zig`. Reuse them.
- ❌ Don't wire `region` to app.zig — that's P3.M3. S1 only ships the library + the main.zig panic/test wiring.
- ❌ Don't add a ghostty import to app.zig — it must stay std-only so its tests are safe as separate fns (and it's out of scope anyway).
- ❌ Don't run `zig build test` without `-Doptimize=ReleaseFast` — Debug mode hits the R_X86_64_PC64 linker bug (PRD §15).
- ❌ Don't call `printf`/`malloc`/buffered `exit` in the signal handler — use raw `std.posix.write` + `std.posix.exit`/re-raise (async-signal-safe).
- ❌ Don't leave `VMIN`/`VTIME` unset, or set MIN=0/TIME=0 (busy-loop). The loop needs MIN=1/TIME=0 (blocking, byte-at-a-time).
- ❌ Don't put the panic override anywhere but `main.zig` (the root file) — std detects it via `@hasDecl(root, "panic")`.
- ❌ Don't run any test against the user's running tmux, or `tmux kill-server`/`pkill tmux` (PRD §0). The manual harness uses its OWN pty / scratch binary only.
