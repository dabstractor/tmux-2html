name: "P3.M1.T1.S2 — Mouse mode enable + SGR mouse decode + input byte read (src/tui/app.zig)"
description: |

---

## Goal

**Feature Goal**: Extend the ALREADY-SHIPPED `src/tui/app.zig` (S1's terminal-control +
event-loop module) with the THREE pieces the work item names: (1) **enable SGR mouse
tracking** on `enter()` / disable on `restoreRaw()` (modes 1000+1002+1006, PRD §7.6 +
arch `tui_region.md` §2); (2) **decode SGR mouse reports** (`\x1b[<{b};{x};{y}M`/`m`)
into a typed `MouseEvent` (button, action, 1-based coords, shift/alt/ctrl modifiers,
wheel/motion/drag); (3) a **`readEvent(input) !Event`** that reads the raw byte stream
from the loop and classifies each logical input into a tagged `Event` union —
**mouse** (fully decoded here), **plain single-byte key** (incl. standalone Esc), or
**raw multi-byte ESC sequence** (CSI/SS3 handed UNDECODED to the key decoder
P3.M2.T1.S1). Output = the typed `Event` stream consumed by the input/select layer
(P3.M2 input.zig/select.zig; P3.M3 region.zig drives it via `runEvents`).

**Deliverable** (ONE file touched — `src/tui/app.zig`, ALL changes ADDITIVE — S1's
shipped symbols stay byte-for-byte identical):
- **MODIFY `enter()`** — one line: write `enter_full_seq` (= `enter_seq ++
  mouse_enable_seq`, comptime concat) instead of `enter_seq`. Enables mouse.
- **MODIFY `restoreRaw()`** — one line: write `restore_seq` (=
  `mouse_disable_seq ++ exit_seq`) instead of `exit_seq`. Disables mouse first,
  then shows cursor + leaves alt screen (one async-signal-safe write — still
  safe in the signal handler / panic override).
- **ADD mouse escape-sequence consts** — `mouse_enable_seq`, `mouse_disable_seq`,
  `enter_full_seq`, `restore_seq`.
- **ADD the `Event` tagged union + supporting types** — `Event`, `MouseEvent`,
  `MouseButton`, `MouseAction`, `EscSeq`, `max_esc_len`.
- **ADD the `Input` byte-source seam** (mirrors `capture.zig`'s `Runner`) +
  `FdInput` (prod: stdin fd + `std.posix.poll` timed read) + `SliceInput`
  (test: `fixedBufferStream`).
- **ADD `readEvent(input: Input) anyerror!Event`** — blocks for the first byte,
  accumulates an ESC sequence with a ~50ms inter-byte timeout (+ CSI-final
  fast-stop), then calls the PURE `classifyEscSeq`.
- **ADD PURE decoders** — `decodeButton(b, term)`, `parseMousePayload(payload)`,
  `classifyEscSeq(seq)`, `makeEscSeq(seq)` (all slice-based, fully unit-tested).
- **ADD the event-level loop seam** — `EventHandler` (mirrors S1's `Handler`),
  `runEvents(handler: EventHandler) !Action`, `default_event_handler` (quit on
  `q`/Ctrl-C/Esc **key** events — the event-level analogue of S1's
  `default_handler`).

**Nothing else changes**: S1's `run()`/`Handler`/`default_handler`/`makeRaw`/
`classifyByte`/`enter_seq`/`exit_seq`/`exit()`/`State`/`Action`/the signal
handler/the globals are UNCHANGED (kept as the byte-level smoke-test path; S2's
event-level surface is what P3.M2/P3.M3 use). Do NOT touch `main.zig` (it ALREADY
imports `tui/app.zig`, has the panic override, and the test-block import from S1 —
S2's new tests are already reachable), `build.zig`/`build.zig.zon`, `PRD.md`,
`tasks.json`, `cli.zig`, `render.zig`, `capture.zig`, `palette.zig`, or any other
source. No new files. Sibling tasks (`view.zig` P3.M1.T2, `input.zig`/`select.zig`
P3.M2, `region.zig` P3.M3) do NOT exist yet — S2's `Event`/`EventHandler` seams are
designed so they plug in LATER without rewriting `readEvent`/`runEvents`.

**Success Definition**:
- `zig build test -Doptimize=ReleaseFast` passes; the new PURE unit tests
  (`decodeButton`, `parseMousePayload`, `classifyEscSeq`, `readEvent` via
  `SliceInput`, mouse-sequence byte literals) are GREEN and reachable from
  `main.zig`'s `test {}` block; S1's existing app.zig tests stay GREEN (zero
  regressions). (ReleaseFast is MANDATORY — PRD §15 / main.zig Gotcha: Debug-mode
  `zig build test` hits the Zig linker bug `R_X86_64_PC64` with the bundled C++
  SIMD libs; ReleaseFast is unaffected.)
- The module **compiles cleanly** in `--release=fast` — this is the automated proof
  that the `std.posix.poll` / `pollfd` / `POLL` / `std.posix.read` APIs and the
  `Input`/`EventHandler`/`FdInput` vtable seams are used correctly
  (`readEvent`/`runEvents`/`FdInput` touch the REAL fd and are NOT unit-testable —
  compile-verified + integration-tested, exactly like `palette.queryColors`,
  `capture.real`, and S1's `enter`/`run`/`restoreRaw`).
- **Manual / integration check** (Level 3): `enter_full_seq` emits the mouse-enable
  bytes and `restore_seq` emits the mouse-disable bytes (verified via the const
  unit tests); a real mouse click in the popup decodes to a `MouseEvent` is
  deferred to P3.M3's region integration test (isolated tmux server, PRD §0/§15),
  since wiring `region`→`runEvents` is P3.M3, NOT S2.

## User Persona (if applicable)

**Target User**: `tmux-2html region` (P3.M3.T1 — the `region` subcommand body,
currently an `error.NotImplemented` stub in `cli.zig:region`). app.zig's
`readEvent`/`Event` stream is an INTERNAL library consumed by region's input
handler (P3.M2); no end user calls it directly.

**Use Case**: PRD §7.6 / §5.3 — the user triggers `prefix C-o`, tmux opens a 100%×100%
`display-popup` (a REAL pty) running `tmux-2html region`. region captures the full
scrollback into a grid (P3.M3), then calls `tui.enter()` (alt screen + raw + **mouse
on**), `tui.runEvents(input_handler)` (P3.M2's handler consumes the `Event` stream),
and on confirm/cancel restores (`restoreRaw` → **mouse off** + cooked termios). Mouse:
click → move cursor; drag → extend selection (linewise by default, **block with
Alt**); wheel → scroll (PRD §7.6).

**User Journey**: `prefix C-o` → display-popup → `enter()` (alt screen + raw + mouse
enabled) → `runEvents(view_input_handler)` → user clicks/drags/wheels →
`readEvent` decodes each into a `MouseEvent` → P3.M2 handler updates cursor/selection
→ `q`/`Esc`/Ctrl-C → `exit(state)`/`restoreRaw()` (mouse disabled + terminal restored)
→ popup closes (`-E`).

**Pain Points Addressed**: (1) The user gets working mouse selection/scroll in the
copy-mode overlay. (2) The terminal + mouse mode are NEVER left enabled on crash
(restoreRaw disables mouse before leaving the alt screen, on every exit path incl.
signal/panic — S1's "restore always" guarantee now also covers mouse teardown).

## Why

- **PRD §7.6 mandates mouse support** ("Click to move cursor; drag to select
  (linewise by default, **block with modifier, e.g. Alt**); wheel to scroll"). This
  subtask delivers the decode half: `readEvent` turns raw pty bytes into typed
  `MouseEvent`s the select layer (P3.M2.T2) can act on. The Alt-bit → block-drag
  policy is the consumer's, but S2 must REPORT the Alt modifier correctly.
- **arch `tui_region.md` §2 is the verified contract**: enable
  `\x1b[?1000h\x1b[?1002h\x1b[?1006h` on enter, disable on exit; SGR events
  `\x1b[<{b};{x};{y}M`/`m`; b bits left/mid/right=0/1/2, motion=bit32, wheel=64/65,
  Alt→block. S2 implements exactly this, with the modifier bit layout pinned to the
  AUTHORITATIVE xterm values (Alt=8, Ctrl=16 — see research).
- **The lone-Esc / esc-sequence disambiguation is THE central input-decoding
  problem** and must be solved ONCE, here, in the foundation. `readEvent` uses a
  `poll`-based ~50ms inter-byte gap (+ CSI-final fast-stop) so arrows/mouse decode
  with zero added latency and a true lone-Esc pays only 50ms (standard; libvaxis/
  termbox do the same). Getting this right in S2 means P3.M2's key decoder receives
  clean, unambiguous events instead of a raw byte soup.
- **Forward compatibility via two seams.** `Input` (readEvent's byte source) mirrors
  `capture.Runner`; `EventHandler` (Event→Action) mirrors S1's `Handler`. `runEvents`
  + `readEvent` are STABLE: P3.M2 only supplies a richer `EventHandler`
  (vim/search/select); P3.M3 only calls `runEvents`. S1's byte-level `run()`
  intentionally stays as the minimal smoke-test path.

## What

### Behavior (`src/tui/app.zig` — ADDITIONS to the shipped S1 module; stdlib-only)

1. **Mouse escape sequences** (new `pub const`s near `enter_seq`/`exit_seq`):
   `mouse_enable_seq = "\x1b[?1000h\x1b[?1002h\x1b[?1006h"` (1000=click report,
   1002=button-event motion=drag, 1006=SGR format), `mouse_disable_seq` = the `l`
   forms; `enter_full_seq = enter_seq ++ mouse_enable_seq` (comptime concat);
   `restore_seq = mouse_disable_seq ++ exit_seq` (disable mouse FIRST, then show
   cursor + leave alt).
2. **`enter()`**: write `enter_full_seq` (was `enter_seq`). **`restoreRaw()`**: write
   `restore_seq` (was `exit_seq`). Nothing else in those fns changes; `exit()`
   unchanged (delegates to `restoreRaw`).
3. **`Event` union + types**: `Event = union(enum){ key: u8, mouse: MouseEvent, seq:
   EscSeq, eof: void }`. `MouseEvent{ button, action, x:u32, y:u32, shift:bool,
   alt:bool, ctrl:bool }` (x,y = 1-based SGR cells). `MouseButton{left,middle,right,
   none}`. `MouseAction{press,release,motion,wheel_up,wheel_down}`. `EscSeq{ bytes:
   [16]u8, len:u8, slice() []const u8 }`.
4. **`Input` seam** (`{ctx:*anyopaque, readByteTimeoutFn}` + `readByteTimeout(ms:i32)
   anyerror!?u8`; `ms<0`=block, `>=0`=timeout→null). `FdInput` (prod: stdin fd +
   `std.posix.poll`). `SliceInput` (test: `fixedBufferStream`).
5. **`readEvent(input: Input) anyerror!Event`**: block-read first byte (`ms=-1`);
   `null`⇒`.eof`; non-ESC⇒`.key(byte)`; ESC⇒accumulate `[16]u8` follow-up bytes
   (`ms=esc_followup_ms=50`) until a 50ms gap OR a CSI-final byte (`0x40..=0x7e`,
   guarded `len>=3`) OR full; then PURE `classifyEscSeq(buf)`.
6. **PURE decoders** (slice-based; fully unit-tested): `decodeButton(b:u32,term:u8)`,
   `parseMousePayload(payload []const u8) ?MouseEvent`, `classifyEscSeq(seq
   []const u8) Event`, `makeEscSeq(seq []const u8) EscSeq`.
7. **`EventHandler`** (`{ctx:?*anyopaque, handleFn}` + `handle(Event) Action`) +
   **`runEvents(handler: EventHandler) !Action`** (owns a stack `FdInput`, loops
   `readEvent`→`handler.handle`, returns on `.quit`/`.confirm`, `.eof` on a handler
   `.none`-after-eof ⇒ `.quit`) + **`default_event_handler`** (quits on `key`
   `q`/0x03/0x1b).

### Success Criteria

- [ ] `src/tui/app.zig` still imports ONLY `std` (ghostty-free ⇒ S2's new tests are
  SAFE as separate `test` fns, like S1's). No new files; no main.zig/build.zig change.
- [ ] S1's symbols unchanged: `enter_seq`/`exit_seq` byte-literal tests still pass;
  `run`/`Handler`/`default_handler`/`makeRaw`/`classifyByte`/`exit`/`State`/`Action`
  untouched.
- [ ] `enter()` writes `enter_full_seq`; `restoreRaw()` writes `restore_seq` (unit
  tests assert the exact byte literals; restoreRaw is compile-verified).
- [ ] PURE tests GREEN: `decodeButton` (left/mid/right, motion=bit32, wheel 64/65,
  release via `m`, shift=4/alt=8/ctrl=16, Alt-drag=40); `parseMousePayload`
  (`"0;5;10M"`, `"32;5;10M"`, `"64;5;10M"`, malformed→null);
  `classifyEscSeq` (`"\x1b"`→key(0x1b), `"\x1b[<0;5;10M"`→mouse, `"\x1b[A"`→seq,
  `"\x1b[1;5D"`→seq, `"\x1bOH"`→seq); `readEvent` via `SliceInput`
  (`"\x1b[<0;5;10M"`→mouse, `"x"`→key('x'), `"\x1b"`→key(0x1b)).
- [ ] `zig build -Doptimize=ReleaseFast` compiles (poll/pollfd/POLL/read APIs +
  vtable seams correct); `zig build test -Doptimize=ReleaseFast` GREEN (no regressions).

## All Needed Context

### Context Completeness Check

_Passed._ An agent who knows nothing about this codebase can implement this from: the
VERIFIED SGR-mouse bit layout in `research/sgr_mouse_encoding.md`, the VERIFIED
Zig 0.15.2 `poll`/`read`/`fixedBufferStream` API signatures (file:line cited) in
`research/zig_reader_poll_api.md`, the S1↔S2 integration reconciliation in
`research/design_notes.md`, the SHIPPED S1 `src/tui/app.zig` (read it — S2 edits
specific lines), the `capture.Runner` seam to mirror for `Input`, and S1's `Handler`
to mirror for `EventHandler`. Every xterm mouse fact is pinned to the authoritative
xterm ctlseqs; every Zig signature to the shipped 0.15.2 stdlib.

### Documentation & References

```yaml
# MUST READ — the authoritative protocol facts (PRIMARY; do not guess the bit layout)
- file: plan/001_0c8587f91cb2/P3M1T1S2/research/sgr_mouse_encoding.md
  why: Exact SGR format \x1b[<{b};{x};{y}M/m, the bit layout (0/1/2=btn, 3=none/hover;
       bit2(4)=Shift; bit3(8)=Alt/Meta; bit4(16)=Control; bit5(32)=motion; bits6-7
       wheel 64/65), modes 1000/1002/1003, drag sequence (b=0 press, b=32 motion,
       b=0 'm' release), Alt-drag = 0|8|32=40, wheel uses 'M' and has NO release.
  critical: RESOLVES the work item's "Alt = b&8 or 16" ambiguity → Alt = (b&8),
            Ctrl = (b&16). x,y are 1-based CHARACTER cells (NOT pixels; pixel mode is
            the separate ?1016). SGR release keeps the button in `b` and is signaled
            by the LOWERCASE 'm' terminator (unlike legacy mode's b=3).

# MUST READ — the verified Zig 0.15.2 stdlib APIs (PRIMARY; do not guess poll/read)
- file: plan/001_0c8587f91cb2/P3M1T1S2/research/zig_reader_poll_api.md
  why: Every signature, read from the shipped stdlib: std.posix.poll(fds:[]pollfd,
       timeout:i32) PollError!usize (posix.zig:6447); std.posix.pollfd = extern struct
       {fd, events:i16, revents:i16} (os/linux.zig:7041); std.posix.POLL.IN=0x001
       (posix.zig:92 / os/linux.zig:7050); File.read(buf)ReadError!usize (File.zig:847);
       fixedBufferStream(bytes).reader() returns GenericReader (works with anytype);
       readByte() returns error.EndOfStream (NOT optional); readByteOrNull() DOES NOT
       EXIST — build it. The recommended Input-seam design + FdInput/SliceInput impls.
  critical: spelling is std.posix.pollfd (lowercase struct) + std.posix.POLL (capital
            const) — there is NO std.posix.PollFd. poll timeout is i32 ms (<0 inf, 0
            immediate, >0 ms); poll retries EINTR internally. std.posix.read(fd,&[1]u8)
            returns 0 on EOF. fixedBufferStream var must be `var` (reader() takes *Self).

# MUST READ — the S1↔S2 integration reconciliation + final Event/Input design
- file: plan/001_0c8587f91cb2/P3M1T1S2/research/design_notes.md
  why: Why S2 ADDS an event-level surface instead of rewriting S1's byte-level run();
       the lone-Esc poll strategy; the readEvent-accumulates / classifyEscSeq-is-pure
       split; the exact enter()/restoreRaw() one-line edits; the Event union + EscSeq
       + MouseEvent fields; the modifier resolution.
  critical: S2 changes ONLY two lines of S1 code (enter()'s writeAll arg,
            restoreRaw()'s write arg) + adds NEW symbols; enter_seq/exit_seq consts
            and their S1 unit test stay IDENTICAL.

# MUST READ — the SHIPPED module you are extending (read it; S2 edits specific lines)
- file: src/tui/app.zig
  why: S1 is ALREADY IMPLEMENTED (307 lines). S2 ADDS to it. enter() is at ~line 134
       (edit the `stdout().writeAll(enter_seq)` line → enter_full_seq); restoreRaw()
       is at ~line 117 (edit the `std.posix.write(saved_fd, exit_seq)` line →
       restore_seq); enter_seq/exit_seq consts at ~lines 61-62 (ADD mouse consts
       nearby); run()/default_handler at ~lines 201-222 (ADD the event-level seam
       BELOW them); tests at the bottom (ADD S2 tests there).
  gotcha: Do NOT touch run/Handler/default_handler/makeRaw/classifyByte/exit/State/
          Action/enter_seq/exit_seq/the signal handler/the globals — they are S1's
          contract and stay byte-identical. main.zig already has all S1 wiring; S2
          adds NOTHING to main.zig.

# MUST READ — the Input seam to mirror (proven mockability pattern in this repo)
- file: src/capture.zig
  why: `Runner = struct { ctx: *anyopaque, runFn: *const fn(ctx,*...) anyerror![]u8 }`
       (lines 58-66) + the prod singleton `real` (line 130) + FakeTmux test double +
       `@ptrCast(@alignCast(ctx))` recovery (line 356) is the EXACT shape `Input`
       (non-nullable ctx) should mirror. FdInput = the prod impl; SliceInput = the
       test double (like FakeTmux).
  pattern: copy the {ctx, fn} struct + thin method; @alignCast MANDATORY in 0.15.2.

# MUST READ — the EventHandler seam to mirror (S1's own proven pattern)
- file: src/tui/app.zig   # lines 48-54 (Handler) + 222 (default_handler)
  why: S1's `Handler = { ctx: ?*anyopaque, classifyFn, pub fn classify }` + the
       nullable-ctx default (stateless) is the EXACT shape `EventHandler` should
       mirror, but consuming an `Event` instead of a `u8`. default_event_handler is
       the event-level twin of default_handler.
  pattern: nullable ctx (?*anyopaque) for EventHandler (matches S1.Handler); the
           Input seam uses NON-nullable ctx (*anyopaque) — it mirrors capture.Runner.

# READ — the contract spec + the testing/safety rules
- file: PRD.md
  why: §7.6 (Mouse: click move / drag select linewise-default block-with-Alt / wheel
       scroll), §7.1 (enter/restore-always — now also covers mouse disable on exit),
       §0 + §15 (NEVER touch the user's running tmux; ReleaseFast mandatory for tests).

# READ — the architecture doc for the TUI (§2 is the verified mouse contract)
- file: plan/001_0c8587f91cb2/architecture/tui_region.md
  why: §2 gives the exact enable seq + SGR parse rules (the source of the work item).
       §3 confirms non-mouse ESC sequences go to the key decoder (input.zig
       P3.M2.T1.S1) — i.e. S2 returns them as raw `.seq`, does NOT decode arrows/vim.
  gotcha: §2 says "Alt=8/16..." loosely — the authoritative value is 8 (xterm); see
          research/sgr_mouse_encoding.md. §2's "1006=SGR pixel-ish coords" is loose —
          1006 is CHARACTER-cell coords (1-based); pixel mode is the separate ?1016.

# EXTERNAL (best-practice references; re-fetch anchors before CI citation)
- url: https://invisible-island.net/xterm/ctlseqs/ctlseqs.html
  why: xterm ctlseqs — "Mouse Tracking" section is the PRIMARY authority for the SGR
       format, the modifier masks (4/8/16), motion bit (32), wheel (64/65), and modes
       1000/1002/1003/1006. Cite this for every bit-layout assertion.
- url: https://github.com/tmux/tmux/blob/master/tty-keys.c
  why: tmux's real-world SGR `<` parser + mask decode — corroborates xterm semantics.
```

### Current Codebase tree (relevant slice)

```bash
src/
├── main.zig          # ALREADY has S1 wiring (import tui, panic override, test import) — S2 changes NOTHING here
├── capture.zig       # ← the Runner seam (ctx:*anyopaque, runFn) to mirror for Input
└── tui/
    └── app.zig       # ← SHIPPED by S1 (307 lines). S2 ADDS: mouse consts, Event/Input/readEvent/
                      #   EventHandler/runEvents + tests; edits TWO lines (enter/restoreRaw args).
plan/001_0c8587f91cb2/architecture/tui_region.md  # §2 = the mouse contract
plan/001_0c8587f91cb2/P3M1T1S2/research/          # sgr_mouse_encoding.md, zig_reader_poll_api.md, design_notes.md
```

### Desired Codebase tree with files to be added/modified

```bash
src/
└── tui/
    └── app.zig       # MODIFIED (additive) — +mouse seqs, +Event/MouseEvent/EscSeq, +Input/FdInput/SliceInput,
                      #   +readEvent +PURE decoders, +EventHandler/runEvents/default_event_handler, +tests;
                      #   enter()→enter_full_seq, restoreRaw()→restore_seq. (NO other file changes.)
```

### Known Gotchas of our codebase & Library Quirks

```zig
// CRITICAL: `zig build test` (Debug) HITS a Zig linker bug (R_X86_64_PC64) with the bundled
//   C++ SIMD libs. Tests MUST run as `zig build test -Doptimize=ReleaseFast` (PRD §15).
//   Every Validation command below uses ReleaseFast.

// CRITICAL: app.zig imports ONLY `std` (NO ghostty-vt). S2 MUST keep it std-only — modules that
//   do NOT call ghostty_vt.Terminal.init are SAFE to have many separate `test` fns (no
//   single-test-scope GOTCHA). poll/read/fixedBufferStream are all in std.

// CRITICAL: poll spelling in Zig 0.15.2 is std.posix.poll(fds: []pollfd, timeout: i32), the struct
//   is std.posix.pollfd = extern struct { fd: fd_t, events: i16, revents: i16 } (LOWERCASE — there
//   is NO std.posix.PollFd), and the constant is std.posix.POLL.IN (CAPITAL POLL). Verified at
//   posix.zig:6447/92/143 + os/linux.zig:7041/7050. poll retries EINTR internally.

// CRITICAL: the modifier bit layout (xterm ctlseqs, authoritative): Shift=4, Alt/Meta=8,
//   Control=16, Motion=32, wheel=64(up)/65(down). Alt = (b & 8) != 0 — the work item's "b&8 or 16"
//   is imprecise; 16 is Ctrl, NOT Alt. Report alt/ctrl/shift as separate bools; the BLOCK-drag
//   policy on Alt is the SELECT layer's job (P3.M2.T2), not S2's.

// CRITICAL: SGR mouse coords (mode 1006) are 1-based CHARACTER cells, unbounded decimal (how 1006
//   avoids the legacy ~223 limit). Pixel coords are the separate ?1016 mode (NOT used here). The
//   consumer subtracts 1 for 0-based grid indexing — MouseEvent carries the raw 1-based x/y.

// CRITICAL: SGR RELEASE is signaled by the LOWERCASE 'm' terminator, and b RETAINS the button
//   number (e.g. release of left = "\x1b[<0;5;10m", b=0). Do NOT use the legacy b=3 release rule.
//   Wheel (64/65) uses the 'M' (press) terminator and emits NO release event.

// CRITICAL: a lone ESC (0x1b) vs the start of an escape sequence is ambiguous under raw blocking
//   reads. readEvent resolves it with a poll-based ~50ms inter-byte gap (esc_followup_ms) after
//   the ESC byte: a 50ms gap ⇒ lone Esc ⇒ Event.key(0x1b); more bytes ⇒ a sequence. The CSI-final
//   fast-stop (0x40..=0x7e, guarded len>=3) ends arrows/mouse the instant their final byte arrives
//   so they pay ZERO added latency; only a true lone-Esc pays 50ms (standard, acceptable). '<'
//   (0x3C) is in the CSI PARAMETER range (0x30-0x3F) so it never false-triggers the fast-stop.

// GOTCHA: readByte() (on AnyReader/GenericReader) returns error.EndOfStream (an ERROR, not an
//   optional); readByteOrNull() DOES NOT EXIST in 0.15.2 — build it: `r.readByte() catch |e|
//   switch(e){ error.EndOfStream => null, else => return e }`. But readEvent uses the Input seam
//   (readByteTimeout returns ?u8), NOT a raw reader — so this mainly affects parseEvent IF you
//   choose a reader-based pure variant. The PRP uses SLICE-based pure decoders (no reader) to avoid
//   this entirely; classifyEscSeq([]const u8) is the pure entry point.

// GOTCHA: the Input.ctx is *anyopaque (NON-nullable, mirrors capture.Runner); recover with
//   @ptrCast(@alignCast(ctx)) — @alignCast is MANDATORY in 0.15.2 (capture.zig:356). The Input must
//   be a stack `var` so &input is *T (a const yields *const T which does NOT coerce — capture
//   findings.md §2). EventHandler.ctx is ?*anyopaque (nullable, mirrors S1.Handler).

// GOTCHA: enter()/restoreRaw() edits are ONE LINE each (the writeAll/write argument). Do NOT
//   restructure those fns. enter uses stdout().writeAll (buffered File write — fine, NOT signal
//   context). restoreRaw uses std.posix.write (raw, async-signal-safe — called from the signal
//   handler + panic override, so ONE write of restore_seq is better than two).

// GOTCHA: `++` concatenation of two `pub const` string literals is COMPTIME in Zig —
//   `enter_seq ++ mouse_enable_seq` and `mouse_disable_seq ++ exit_seq` produce comptime-known
//   arrays. This lets enter()/restoreRaw() do a SINGLE write each (cleaner; restoreRaw stays one
//   async-signal-safe syscall). enter_seq/exit_seq themselves stay UNCHANGED (S1's test still passes).
```

## Implementation Blueprint

### Data models and structure

```zig
// src/tui/app.zig — ADD these types BELOW S1's `default_handler` (≈ line 222). std-only.

/// Max bytes captured for one ESC sequence (CSI/SS3 ≤ ~8; Alt+char = 2; mouse ≤ ~12). 16 is
/// generous. Bounds the readEvent accumulation buffer + the EscSeq fixed array.
pub const max_esc_len: usize = 16;
/// The inter-byte gap (ms) after an ESC byte used to detect end-of-sequence / a lone Esc.
/// 50ms: terminals send sequences atomically, so real sequences never gap; a true lone-Esc
/// pays this once (standard; libvaxis/termbox use similar). Tunable.
pub const esc_followup_ms: i32 = 50;

pub const MouseButton = enum { left, middle, right, none };
pub const MouseAction = enum { press, release, motion, wheel_up, wheel_down };

/// A decoded SGR (mode 1006) mouse event. x/y are 1-based CHARACTER cells as reported by the
/// terminal (mode 1006 is NOT pixel — pixel is the separate ?1016 mode). The consumer (select.zig,
/// P3.M2.T2) subtracts 1 for 0-based grid indexing. `alt` is set when (b & 8) — the SELECT layer
/// switches a drag to BLOCK selection when alt is set during motion (PRD §7.6).
pub const MouseEvent = struct {
    button: MouseButton,
    action: MouseAction,
    x: u32, // 1-based SGR column
    y: u32, // 1-based SGR row
    shift: bool, // (b & 4)
    alt: bool, // (b & 8)  — Alt/Meta; consumer uses for block-drag (PRD §7.6)
    ctrl: bool, // (b & 16)
};

/// A raw multi-byte ESC sequence (CSI \x1b[... / SS3 \x1bO... / Alt+char \x1b<char>) handed
/// UNDECODED to the key decoder (P3.M2.T1.S1 input.zig). Bytes INCLUDE the leading 0x1b so the
/// decoder can pattern-match "\x1b[A" etc. Fixed inline buffer (no allocation).
pub const EscSeq = struct {
    bytes: [max_esc_len]u8 = [_]u8{0} ** max_esc_len,
    len: u8 = 0,
    pub fn slice(self: EscSeq) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// A decoded terminal input event — the typed stream `readEvent` produces, consumed by the
/// input/select layer (P3.M2 input.zig, select.zig). Three categories (arch §3 + work item):
///   .key   = a single non-sequence byte (printable, control, or standalone Esc 0x1b)
///   .mouse = a fully decoded SGR mouse event (THIS subtask's core deliverable)
///   .seq   = a raw ESC sequence for the key decoder P3.M2.T1.S1 (arrows/Ctrl-mods/fn/vim)
///   .eof   = stdin closed
pub const Event = union(enum) {
    key: u8,
    mouse: MouseEvent,
    seq: EscSeq,
    eof: void,
};
```

### The `Input` byte-source seam (mirrors `capture.Runner`)

```zig
// The mockable byte source readEvent reads from — MIRRORS capture.zig:58-66 `Runner`. ONE method;
// ctx is *anyopaque (NON-nullable, like Runner) — prod FdInput + test SliceInput both carry state.
// timeout_ms: <0 = BLOCK forever (first byte of an event); >=0 = wait ≤ that many ms, return null
// on timeout/EOF. This split lets readEvent block for byte 1 then time-out the ESC follow-up.
pub const Input = struct {
    ctx: *anyopaque,
    readByteTimeoutFn: *const fn (ctx: *anyopaque, timeout_ms: i32) anyerror!?u8,

    pub fn readByteTimeout(self: Input, timeout_ms: i32) anyerror!?u8 {
        return self.readByteTimeoutFn(self.ctx, timeout_ms);
    }
};
```

### PURE decoders (slice-based; fully unit-tested — no reader, no timing)

```zig
const MouseDecode = struct {
    button: MouseButton,
    action: MouseAction,
    shift: bool,
    alt: bool,
    ctrl: bool,
};

/// PURE: decode the SGR button/motion integer `b` + terminator ('M' press/motion/wheel, 'm'
/// release) into button/action/modifier fields. Bit layout (xterm ctlseqs, authoritative):
///   bits0-1 (0/1/2/3) = button (0=left,1=middle,2=right,3=none/hover); bit2(4)=Shift;
///   bit3(8)=Alt/Meta; bit4(16)=Control; bit5(32)=motion; bits6-7(64/65)=wheel up/down.
/// Alt=(b&8); Ctrl=(b&16). Wheel 64=up/65=down (b&1 distinguishes), no release event.
pub fn decodeButton(b: u32, term: u8) MouseDecode {
    const shift = (b & 4) != 0;
    const alt = (b & 8) != 0;
    const ctrl = (b & 16) != 0;
    if ((b & 64) != 0) { // wheel
        return .{ .button = .none, .action = if ((b & 1) == 0) .wheel_up else .wheel_down,
            .shift = shift, .alt = alt, .ctrl = ctrl };
    }
    const motion = (b & 32) != 0;
    const btn: MouseButton = switch (b & 3) {
        0 => .left, 1 => .middle, 2 => .right, else => .none,
    };
    const action: MouseAction = if (motion) .motion else (if (term == 'm') .release else .press);
    return .{ .button = btn, .action = action, .shift = shift, .alt = alt, .ctrl = ctrl };
}

/// PURE: parse a complete SGR mouse payload "{b};{x};{y}{M|m}" (the bytes AFTER "\x1b[<") into a
/// MouseEvent, or null if malformed. b/x/y are unsigned decimals; the LAST byte is the terminator
/// ('M' = press/motion/wheel, 'm' = release). Exactly 3 ';' fields.
pub fn parseMousePayload(payload: []const u8) ?MouseEvent {
    if (payload.len < 1) return null;
    const term = payload[payload.len - 1];
    if (term != 'M' and term != 'm') return null;
    const nums = payload[0 .. payload.len - 1]; // "b;x;y"
    var it = std.mem.splitScalar(u8, nums, ';');
    const b_s = it.next() orelse return null;
    const x_s = it.next() orelse return null;
    const y_s = it.next() orelse return null;
    if (it.next() != null) return null; // exactly 3 fields
    const b = std.fmt.parseInt(u32, b_s, 10) catch return null;
    const x = std.fmt.parseInt(u32, x_s, 10) catch return null;
    const y = std.fmt.parseInt(u32, y_s, 10) catch return null;
    const d = decodeButton(b, term);
    return .{ .button = d.button, .action = d.action, .x = x, .y = y,
        .shift = d.shift, .alt = d.alt, .ctrl = d.ctrl };
}

/// PURE: copy a raw ESC slice into a fixed EscSeq (clamp to max_esc_len). The slice is assumed to
/// INCLUDE the leading 0x1b (so the key decoder can match "\x1b[A" etc.).
pub fn makeEscSeq(seq: []const u8) EscSeq {
    var e: EscSeq = .{};
    const n = @min(seq.len, max_esc_len);
    @memcpy(e.bytes[0..n], seq[0..n]);
    e.len = @intCast(n);
    return e;
}

/// PURE: classify a COMPLETE ESC sequence (INCLUDING the leading 0x1b) into an Event.
///   "\x1b" alone                     → .key(0x1b)   (standalone Esc)
///   "\x1b[<{b};{x};{y}{M|m}"         → .mouse       (fully decoded; malformed → fall to .seq)
///   any other "\x1b[..." / "\x1bO..." / "\x1b<char>" → .seq (raw bytes for the key decoder)
pub fn classifyEscSeq(seq: []const u8) Event {
    if (seq.len == 1) return .{ .key = 0x1b }; // lone Esc
    if (seq.len >= 3 and seq[1] == '[' and seq[2] == '<') {
        if (parseMousePayload(seq[3..])) |m| return .{ .mouse = m };
        // malformed SGR mouse → hand the raw bytes to the decoder (robust fallback)
    }
    return .{ .seq = makeEscSeq(seq) };
}

/// PURE: true if `c` is a CSI/SS3 final byte (0x40..=0x7e). Used by readEvent's fast-stop.
/// '<' (0x3c) is in the PARAMETER range (0x30-0x3f) so it never matches here.
fn isCsiFinal(c: u8) bool {
    return c >= 0x40 and c <= 0x7e;
}
```

### `readEvent` (timing-dependent; tested via `SliceInput`, real-fd via `FdInput`)

```zig
/// Read one logical input event from `input`. Blocks for the first byte (timeout < 0):
///   null ⇒ .eof; a non-ESC byte ⇒ .key(byte); an ESC byte ⇒ accumulate the sequence with a
///   ~esc_followup_ms inter-byte gap (+ CSI-final fast-stop) into a [max_esc_len]u8 buffer, then
///   PURE classifyEscSeq. Errors propagate (e.g. error.ReadFailed from poll/read). NOT pure
/// (timing) — exercised via SliceInput in tests; FdInput + poll is compile-verified + manual.
pub fn readEvent(input: Input) anyerror!Event {
    const first = (try input.readByteTimeout(-1)) orelse return .eof; // block for byte 1
    if (first != 0x1b) return .{ .key = first }; // plain single byte (printable/control)

    // ESC seen — accumulate the rest of the sequence.
    var buf: [max_esc_len]u8 = [_]u8{0} ** max_esc_len;
    buf[0] = 0x1b;
    var len: usize = 1;
    while (len < max_esc_len) {
        const b = try input.readByteTimeout(esc_followup_ms);
        if (b == null) break; // 50ms gap ⇒ end of sequence (or lone Esc if len==1)
        buf[len] = b.?;
        len += 1;
        if (len >= 3 and isCsiFinal(buf[len - 1])) break; // CSI/SS3 final byte ⇒ done (no latency)
    }
    return classifyEscSeq(buf[0..len]); // PURE decode of the accumulated bytes
}
```

### `Input` impls (prod + test)

```zig
// PROD — real stdin fd + poll. Blocks (ms<0) or polls-then-reads (ms>=0).
const FdInput = struct {
    fd: std.posix.fd_t,
    fn readByteTimeout(ctx: *anyopaque, timeout_ms: i32) anyerror!?u8 {
        const self: *FdInput = @ptrCast(@alignCast(ctx)); // @alignCast MANDATORY (0.15.2)
        if (timeout_ms >= 0) {
            var fds = [_]std.posix.pollfd{.{ .fd = self.fd, .events = std.posix.POLL.IN, .revents = 0 }};
            if ((try std.posix.poll(&fds, timeout_ms)) == 0) return null; // timed out
        }
        var b: [1]u8 = undefined;
        const n = try std.posix.read(self.fd, &b); // 0 = EOF
        if (n == 0) return null;
        return b[0];
    }
};

// TEST — fixedBufferStream; ignores timeout, returns null at EOF (models "no more bytes now").
const SliceInput = struct {
    fbs: *std.io.FixedBufferStream([]const u8),
    fn readByteTimeout(ctx: *anyopaque, _: i32) anyerror!?u8 {
        const self: *SliceInput = @ptrCast(@alignCast(ctx));
        var one: [1]u8 = undefined;
        const n = try self.fbs.read(&one); // infallible (FixedBufferStream([]const u8) read is error{})
        return if (n == 0) null else one[0];
    }
};
```

### The event-level loop seam (mirrors S1's `Handler`/`run`/`default_handler`)

```zig
/// Pluggable per-EVENT handler — MIRRORS S1's `Handler` (nullable ctx), but consumes a decoded
/// `Event` instead of a raw byte. This is the event-level seam P3.M2's input/select handlers
/// implement; P3.M3 region.zig calls runEvents(input_handler). S1's byte-level run()/Handler stay
/// as the smoke-test path — S2's runEvents/EventHandler is what the real TUI uses.
pub const EventHandler = struct {
    ctx: ?*anyopaque,
    handleFn: *const fn (ctx: ?*anyopaque, ev: Event) Action,
    pub fn handle(self: EventHandler, ev: Event) Action {
        return self.handleFn(self.ctx, ev);
    }
};

/// Block-read decoded events via readEvent (stdin FdInput) and dispatch each to `handler.handle`.
/// Returns the Action on .quit/.confirm; .eof from readEvent ⇒ .quit (stdin closed). Errors
/// (error.ReadFailed etc.) propagate. P3.M3 region.zig calls this with P3.M2's handler.
pub fn runEvents(handler: EventHandler) !Action {
    var fd_in: FdInput = .{ .fd = std.fs.File.stdin().handle };
    const input: Input = .{ .ctx = @ptrCast(&fd_in), .readByteTimeoutFn = FdInput.readByteTimeout };
    while (true) {
        const ev = try readEvent(input);
        if (ev == .eof) return .quit; // stdin closed
        switch (handler.handle(ev)) {
            .none => continue,
            .quit => return .quit,
            .confirm => return .confirm,
        }
    }
}

/// The event-level default: quits on `key` events for 'q'(0x71), Ctrl-C(0x03), Esc(0x1b). Stateless
/// (ctx=null). The event-level twin of S1's default_handler. P3.M2 supplies the real handler.
fn defaultEventHandle(_: ?*anyopaque, ev: Event) Action {
    return switch (ev) {
        .key => |b| switch (b) { 'q', 0x03, 0x1b => .quit, else => .none },
        else => .none, // mouse / seq handled by richer handlers (P3.M2)
    };
}
pub const default_event_handler: EventHandler = .{ .ctx = null, .handleFn = defaultEventHandle };
```

### The mouse escape sequences + the two one-line enter/restoreRaw edits

```zig
// ADD near enter_seq/exit_seq (≈ lines 61-62). Comptime `++` of string-literal consts.
pub const mouse_enable_seq = "\x1b[?1000h\x1b[?1002h\x1b[?1006h"; // click + button-event motion(drag) + SGR format
pub const mouse_disable_seq = "\x1b[?1000l\x1b[?1002l\x1b[?1006l";
pub const enter_full_seq = enter_seq ++ mouse_enable_seq; // alt+hide-cursor, THEN enable mouse
pub const restore_seq = mouse_disable_seq ++ exit_seq; // disable mouse FIRST, THEN show cursor + leave alt
```

```zig
// EDIT enter() (≈ line 142) — change the writeAll argument:
//   BEFORE: try std.fs.File.stdout().writeAll(enter_seq);
//   AFTER:  try std.fs.File.stdout().writeAll(enter_full_seq);
```
```zig
// EDIT restoreRaw() (≈ line 124) — change the write argument:
//   BEFORE: _ = std.posix.write(saved_fd, exit_seq) catch {};
//   AFTER:  _ = std.posix.write(saved_fd, restore_seq) catch {};
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: ADD mouse escape-sequence consts + comptime concatenations to src/tui/app.zig
  - IMPLEMENT: mouse_enable_seq, mouse_disable_seq, enter_full_seq (= enter_seq ++
    mouse_enable_seq), restore_seq (= mouse_disable_seq ++ exit_seq). PLACE near enter_seq/exit_seq.
  - FOLLOW pattern: the existing enter_seq/exit_seq `pub const` string literals (lines 61-62).
  - NAMING: snake_case consts; the `_seq` suffix matches S1's enter_seq/exit_seq.
  - GOTCHA: `++` on two `pub const` string literals is COMPTIME — enter_full_seq/restore_seq are
    comptime-known arrays. enter_seq/exit_seq themselves stay UNCHANGED (S1's test still passes).

Task 2: EDIT enter() — write enter_full_seq instead of enter_seq (ONE LINE)
  - FIND: `try std.fs.File.stdout().writeAll(enter_seq);` in enter() (≈ line 142).
  - REPLACE WITH: `try std.fs.File.stdout().writeAll(enter_full_seq);`
  - PRESERVE: every other line of enter() (tcgetattr, saved=, saved_fd=, tcsetattr, signals,
    entered.store, return). NOT signal context ⇒ buffered File write is fine.
  - GOTCHA: do NOT restructure enter(); it's a single-arg change.

Task 3: EDIT restoreRaw() — write restore_seq instead of exit_seq (ONE LINE)
  - FIND: `_ = std.posix.write(saved_fd, exit_seq) catch {};` in restoreRaw() (≈ line 124).
  - REPLACE WITH: `_ = std.posix.write(saved_fd, restore_seq) catch {};`
  - PRESERVE: the atomic `entered.swap` guard, the `saved_fd < 0` guard, the tcsetattr restore.
    restore_seq disables mouse FIRST then shows cursor + leaves alt — one async-signal-safe write.
  - GOTCHA: exit() is UNCHANGED (it delegates to restoreRaw). restoreRaw is called by the signal
    handler + panic override ⇒ keep it ONE raw write (do not split into two writes).

Task 4: ADD the Event union + supporting types (max_esc_len, esc_followup_ms, MouseButton,
        MouseAction, MouseEvent, EscSeq, Event) — see Data models. PLACE below default_handler.
  - NAMING: CamelCase types; the Event variants match the work item's three categories + eof.
  - GOTCHA: MouseEvent.x/y are 1-based SGR cells (document it); alt=(b&8), ctrl=(b&16).

Task 5: ADD the Input seam + FdInput + SliceInput — see "The Input byte-source seam".
  - FOLLOW pattern: src/capture.zig:58-66 `Runner` (ctx: *anyopaque NON-nullable + fn + thin method)
    for Input; src/capture.zig:130 `real` + :356 `@ptrCast(@alignCast)` for FdInput.
  - GOTCHA: Input.ctx is *anyopaque (NON-nullable); FdInput/SliceInput must be stack `var` so &x is
    *T (a const yields *const T — won't coerce). @alignCast is MANDATORY in 0.15.2.
  - GOTCHA: poll spelling = std.posix.pollfd (lowercase) + std.posix.POLL.IN (capital). poll(fds,
    timeout:i32); poll returns 0 on timeout. std.posix.read(fd,&[1]u8) returns 0 on EOF.

Task 6: ADD the PURE decoders (decodeButton, parseMousePayload, makeEscSeq, classifyEscSeq,
        isCsiFinal) — see PURE decoders. ALL slice-based (no reader, no timing) ⇒ unit-testable.
  - FOLLOW pattern: the "pure parse vs real-fd" split in capture.zig (pure helpers are separate
    `test` fns with no seam; real-fd fns are compile-verified + manual).
  - GOTCHA: SGR release = lowercase 'm' terminator with b RETAINING the button (NOT legacy b=3).
    Wheel 64/65 use 'M' and have NO release. decodeButton must check (b&64) BEFORE (b&32)/terminator.

Task 7: ADD readEvent(input: Input) — see readEvent. Blocks byte 1 (ms<0); ESC ⇒ accumulate with
        esc_followup_ms gap + isCsiFinal fast-stop; classifyEscSeq at the end.
  - DEPENDENCIES: Input (Task 5) + classifyEscSeq (Task 6).
  - GOTCHA: first-byte null ⇒ .eof; ESC + immediate 50ms-timeout null ⇒ classifyEscSeq("\x1b") ⇒
    .key(0x1b) (lone Esc). The isCsiFinal guard needs len>=3 so a 2-byte Alt+char ("\x1bx") reads
    until the 50ms gap (rare in vim; acceptable). Non-ESC byte ⇒ .key(byte) with ZERO latency.

Task 8: ADD EventHandler + runEvents + default_event_handler — see the loop-seam block.
  - FOLLOW pattern: S1's Handler (ctx: ?*anyopaque NULLABLE + fn + method) for EventHandler; S1's
    run() for runEvents (loop → dispatch → return on quit/confirm); S1's default_handler for
    default_event_handler. PLACE near S1's run/default_handler.
  - GOTCHA: runEvents owns the FdInput on its stack (var fd_in) and passes &fd_in. .eof ⇒ .quit.
    S1's run()/Handler/default_handler stay UNCHANGED (do not delete/rename them).

Task 9: ADD unit tests for the PURE surface + readEvent(via SliceInput) — see Validation Loop L2.
  - COVERAGE: decodeButton (left/mid/right/none, motion=bit32, wheel 64/65, release via 'm',
    shift=4/alt=8/ctrl=16, Alt-drag b=40→motion+alt); parseMousePayload (valid 3-field, malformed
    2-field/4-field/non-numeric/wrong-terminator → null); classifyEscSeq (lone Esc, mouse, CSI seq,
    SS3 seq, Alt+char, malformed-mouse→seq); readEvent via SliceInput (mouse seq, plain key, lone
    Esc, eof); the 4 new mouse-seq consts' exact bytes.
  - PLACE: in app.zig's test section (bottom), as SEPARATE `test` fns (app.zig is ghostty-free ⇒ safe).
  - GOTCHA: SliceInput wraps a `var fbs = std.io.fixedBufferStream("...")` (fbs MUST be `var`); wire
    Input via `.{ .ctx = @ptrCast(&s), .readByteTimeoutFn = SliceInput.readByteTimeout }`. Compare
    Events with std.testing.expectEqual (tagged unions compare structurally). For .seq compare
    slice() bytes; for .mouse compare field-by-field (or expectEqual on the whole MouseEvent).
  - NOT tested (real fd): enter/restoreRaw edits, FdInput, runEvents, readEvent's real timing —
    compile-verified + manual/integration (mirrors palette.queryColors/capture.real/S1's enter/run).
```

### Integration Points

```yaml
BUILD:
  - change: NONE. app.zig is under src/ (root module); S2's additions are pulled into BOTH the
    prod exe and the test binary transitively (main.zig already @imports tui/app.zig from S1).
    No build.zig / build.zig.zon edit. No new files.
  - verify: `zig build -Doptimize=ReleaseFast` succeeds; `zig build test -Doptimize=ReleaseFast` GREEN.

MAIN.ZIG:
  - change: NONE. S1 already added `const tui = @import("tui/app.zig")`, the root panic override
    (calls tui.restoreRaw()), and the test-block `_ = @import("tui/app.zig");`. S2's new tests are
    reachable via that import; S2 adds NOTHING to main.zig.

MOUSE MODE WIRING (the S1↔S2 hand-off):
  - enter() now emits mouse_enable_seq (via enter_full_seq); restoreRaw() emits mouse_disable_seq
    (via restore_seq). So EVERY exit path (defer exit, signal re-raise, panic) disables mouse +
    restores the terminal — S1's "restore always" guarantee now also covers mouse teardown.

FUTURE CONSUMERS (do NOT implement now — boundary docs only):
  - P3.M1.T2 (view.zig): renders grid + status line; uses render.getSize() for the viewport. Does
    NOT touch readEvent — it is driven by repaints the EventHandler triggers.
  - P3.M2.T1 (input.zig): supplies the REAL EventHandler — consumes .key (vim motions/search/
    counts) + .seq (decode arrows/Ctrl-mods/fn keys — this is the "key decoder" the work item names)
    + .mouse (cursor move / drag-select / wheel-scroll). Yields .confirm on Enter/y with a selection.
  - P3.M2.T2 (select.zig): reads mouse.alt during a drag to switch linewise→BLOCK (PRD §7.6);
    converts the final selection to a ghostty Selection (pin) for renderGrid.
  - P3.M3.T1 (region.zig): captures full scrollback → grid → tui.enter(); _ = try tui.runEvents(handler);
    defer tui.exit(state); on .confirm renders the selection.
```

## Validation Loop

> **MANDATORY:** every `zig build`/`zig build test` below uses `-Doptimize=ReleaseFast`
> (PRD §15 / main.zig Gotcha: Debug-mode `zig build test` hits the Zig linker bug
> `R_X86_64_PC64` with the bundled C++ SIMD libs; ReleaseFast is unaffected).

### Level 1: Syntax & Style (Immediate Feedback)

```bash
cd /home/dustin/projects/tmux-2html
# Compile the whole binary in ReleaseFast — primary proof that the poll/pollfd/POLL/read APIs +
# the Input/EventHandler/FdInput vtable seams are used CORRECTLY (readEvent/runEvents/FdInput
# touch the REAL fd and aren't unit-testable — this compile IS their API check, like S1's enter).
zig build -Doptimize=ReleaseFast
# Expected: zero errors. If poll spelling (pollfd vs PollFd), POLL.IN, @ptrCast/@alignCast, the
# `++` comptime concat, or the vtable fn-pointer types are wrong, it fails HERE — read the error,
# fix against research/zig_reader_poll_api.md + research/design_notes.md.
```

### Level 2: Unit Tests (the PURE + SliceInput-testable core)

```bash
cd /home/dustin/projects/tmux-2html
# Run the full suite (includes app.zig's new tests via main.zig's existing test-block import).
zig build test -Doptimize=ReleaseFast
# Expected: all GREEN — S2's new tests + ZERO regressions in S1's app.zig tests + the rest of the suite.
#
# The new tests to ADD (in src/tui/app.zig, as separate `test` fns):
#   - mouse seq literals: mouse_enable_seq == "\x1b[?1000h\x1b[?1002h\x1b[?1006h";
#     mouse_disable_seq == "\x1b[?1000l\x1b[?1002l\x1b[?1006l"; enter_full_seq ==
#     "\x1b[?1049h\x1b[?25l\x1b[?1000h\x1b[?1002h\x1b[?1006h"; restore_seq ==
#     "\x1b[?1000l\x1b[?1002l\x1b[?1006l\x1b[?25h\x1b[?1049l". (And enter_seq/exit_seq unchanged.)
#   - decodeButton: b=0/'M'→left/press; b=1/'M'→middle/press; b=2/'M'→right/press; b=0/'m'→left/
#     release; b=32/'M'→left/motion (drag); b=64/'M'→none/wheel_up; b=65/'M'→none/wheel_down;
#     b=8/'M'→left/press + alt; b=16/'M'→left/press + ctrl; b=4/'M'→left/press + shift;
#     b=40/'M' (=0|8|32)→left/motion + alt (Alt-drag); b=35/'M' (=3|32)→none/motion.
#   - parseMousePayload: "0;5;10M"→MouseEvent{left,press,5,10,no,no,no}; "32;5;10M"→left/motion;
#     "64;1;1M"→wheel_up; "0;1;1m"→release; "0;5"→null (2 fields); "0;5;10;1M"→null (4 fields);
#     "0;5;10X"→null (bad terminator); "a;b;cM"→null (non-numeric); ""→null.
#   - classifyEscSeq: "\x1b"→.key(0x1b); "\x1b[<0;5;10M"→.mouse{left,press,5,10};
#     "\x1b[<35;2;3M"→.mouse{none,motion,2,3}; "\x1b[A"→.seq (slice "\x1b[A"); "\x1b[1;5D"→.seq
#     (slice "\x1b[1;5D"); "\x1bOH"→.seq (slice "\x1bOH"); "\x1bx"→.seq (slice "\x1bx");
#     "\x1b[<badM"→.seq (malformed mouse falls through to raw seq).
#   - readEvent via SliceInput: feed "\x1b[<0;5;10M"→.mouse{left,press,5,10}; feed "x"→.key('x');
#     feed "\x1b"→.key(0x1b) (SliceInput returns null at EOF ⇒ lone Esc); feed ""→.eof.
#   - default_event_handler.handle: .key('q')→.quit; .key(0x03)→.quit; .key(0x1b)→.quit;
#     .key('j')→.none; .mouse(...)→.none; .seq(...)→.none.
```

### Level 3: Integration / manual check (real fd — enter/restoreRaw/FdInput/runEvents)

> enter()/restoreRaw()/readEvent(real fd)/runEvents touch the REAL tty and are NOT unit-testable —
> this is their validation (mirrors how palette.queryColors / capture.real / S1's enter+run are
> compile-verified + manually tested). Since `region` isn't wired until P3.M3, do a CONST/compile
> assertion now and DEFER the live-mouse-decode assertion to P3.M3's region integration test
> (isolated tmux server per PRD §0/§15). **Do NOT wire region here.** Teardown: only artifacts you create.

```bash
cd /home/dustin/projects/tmux-2html
# (a) The mouse teardown is PROVEN by the const unit test (restore_seq disables mouse before
#     leaving the alt screen) — that's the Level 2 test above; no live terminal needed.
# (b) Confirm the module is ghostty-free (app.zig must stay std-only so its tests are safe):
! grep -n 'ghostty' src/tui/app.zig   # Expected: no matches (grep exits 1)
# (c) Confirm S1's symbols are UNCHANGED (S2 only added + edited 2 lines):
grep -n 'pub const enter_seq = "\\x1b\[?1049h\\x1b\[?25l"' src/tui/app.zig   # still present, identical
grep -n 'pub const exit_seq = "\\x1b\[?25h\\x1b\[?1049l"' src/tui/app.zig    # still present, identical
grep -n 'pub fn run(handler: Handler)' src/tui/app.zig                        # S1 byte loop still present
# (d) Confirm the 2 one-line edits landed:
grep -n 'writeAll(enter_full_seq)' src/tui/app.zig           # enter() now writes enter_full_seq
grep -n 'write(saved_fd, restore_seq)' src/tui/app.zig       # restoreRaw() now writes restore_seq
#
# (e) OPTIONAL live smoke (defer the full mouse-decode assertion to P3.M3): in a real terminal or
#     `script` pty, run a TEMPORARY scratch harness that calls enter(); then runEvents(
#     default_event_handler) (which only reacts to q/Esc/Ctrl-C keys); type 'q' to quit; confirm
#     the terminal + mouse mode are restored. To actually verify MOUSE decode end-to-end, wait for
#     P3.M3's region integration (it will click/drag/wheel and assert the selection). DELETE the
#     scratch harness after — never commit it, never touch a tmux server.
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Confirm the event-classification boundary is correct (the three-way split the work item requires):
#   mouse is FULLY decoded (not handed raw); non-mouse ESC sequences are handed RAW (.seq, NOT
#   decoded — that's P3.M2.T1.S1's job); plain bytes are .key.
grep -n 'pub const Event = union(enum)' src/tui/app.zig       # variants: key, mouse, seq, eof
grep -n 'pub fn readEvent' src/tui/app.zig                    # the readEvent(input) entry point
grep -n 'pub fn classifyEscSeq' src/tui/app.zig               # the PURE classifier (unit-tested)
# Confirm the modifier resolution is authoritative (Alt=8, Ctrl=16 — the xterm values):
grep -n 'b & 8' src/tui/app.zig                               # alt
grep -n 'b & 16' src/tui/app.zig                              # ctrl
grep -n 'b & 64' src/tui/app.zig                              # wheel (checked BEFORE motion/terminator)
# Confirm mouse is disabled BEFORE the alt screen is left on teardown (signal/panic-safe order):
grep -n 'restore_seq = mouse_disable_seq ++ exit_seq' src/tui/app.zig
```

## Final Validation Checklist

### Technical Validation

- [ ] `zig build -Doptimize=ReleaseFast` succeeds (poll/pollfd/POLL/read APIs + Input/EventHandler/FdInput seams correct).
- [ ] `zig build test -Doptimize=ReleaseFast` is GREEN — S2's new tests pass + ZERO regressions (S1's app.zig tests + the rest of the suite).
- [ ] app.zig still imports ONLY `std` (ghostty-free ⇒ separate test fns are safe).
- [ ] No new build.zig / build.zig.zon / main.zig changes (verified: S2 adds only to app.zig; main.zig already wires tui from S1).

### Feature Validation

- [ ] `enter()` writes `enter_full_seq` (alt+hide-cursor+mouse-enable); `restoreRaw()` writes `restore_seq` (mouse-disable+show-cursor+leave-alt) — unit-tested (const literals) + compile-verified.
- [ ] SGR mouse fully decoded: `decodeButton`/`parseMousePayload` handle left/mid/right, motion (bit32), wheel (64/65), release ('m' with button retained), shift=4/alt=8/ctrl=16 (unit-tested).
- [ ] `readEvent` classifies the three categories: mouse→`.mouse`, plain byte→`.key`, ESC sequence→`.seq`, stdin-closed→`.eof` (unit-tested via SliceInput).
- [ ] Lone-Esc disambiguated from sequences via ~50ms poll gap + CSI-final fast-stop (compile-verified; the logic is exercised by SliceInput for complete sequences and lone-Esc-at-EOF).
- [ ] `runEvents(handler)` + `default_event_handler` + `EventHandler` seam compile + the default quits on q/Ctrl-C/Esc key events.
- [ ] Scope boundary respected: NO arrow/vim/function-key DECODING (raw `.seq` → P3.M2.T1.S1), NO selection/block-drag POLICY (consumer P3.M2.T2 reads `mouse.alt`), NO view/status rendering (P3.M1.T2), NO region wiring (P3.M3), NO size query.

### Code Quality Validation

- [ ] Follows existing patterns: `Input` mirrors `capture.Runner` (non-nullable ctx, @ptrCast/@alignCast); `EventHandler`/`default_event_handler` mirror S1's `Handler`/`default_handler` (nullable ctx); pure-vs-realfd split mirrors capture.zig.
- [ ] S1's shipped symbols (`run`/`Handler`/`default_handler`/`makeRaw`/`classifyByte`/`enter_seq`/`exit_seq`/`exit`/`State`/`Action`/signal handler/globals) are byte-for-byte UNCHANGED.
- [ ] `restoreRaw()` stays ONE idempotent raw write (now of `restore_seq`) — still async-signal-safe for the signal handler + panic override; mouse is disabled before the alt screen is left.
- [ ] Anti-patterns avoided (check against Anti-Patterns section).

### Documentation & Deployment

- [ ] No user-facing docs (item contract: "DOCS: none — internal"). Code is self-documenting with the WHY comments above.
- [ ] `cli.region` remains `error.NotImplemented` (wiring is P3.M3 — do NOT touch it here).

---

## Anti-Patterns to Avoid

- ❌ Don't DECODE arrows / vim keys / function keys in S2 — those are raw `.seq` events handed to the key decoder P3.M2.T1.S1. S2 decodes ONLY SGR mouse. (Work item: "dispatch to key decoder P3.M2.T1.S1".)
- ❌ Don't implement the block-drag / selection POLICY in S2 — report `mouse.alt`; the select layer (P3.M2.T2) decides linewise vs block. S2 just reports modifiers.
- ❌ Don't change/delete/rename S1's `run()`/`Handler`/`default_handler`/`makeRaw`/`classifyByte`/`enter_seq`/`exit_seq`/`exit`/`State`/`Action`/signal handler/globals. S2 ADDS an event-level surface alongside them; it edits exactly TWO lines (enter/restoreRaw write args).
- ❌ Don't write mouse-disable and exit_seq as TWO separate `std.posix.write` calls in `restoreRaw()` — use the comptime `restore_seq = mouse_disable_seq ++ exit_seq` so it's ONE async-signal-safe write (it runs in the signal handler + panic override).
- ❌ Don't use `b & 16` for Alt (that's Ctrl) or `b & 8` for Ctrl — xterm is Alt=8, Ctrl=16. Don't use the legacy `b==3` release rule — SGR release is the lowercase `m` terminator with the button retained.
- ❌ Don't use `std.posix.PollFd` (doesn't exist) — it's `std.posix.pollfd` (lowercase struct) + `std.posix.POLL.IN` (capital const). Don't pass a non-blocking read without poll for the ESC follow-up — a lone Esc would block forever waiting for a next byte.
- ❌ Don't make `Input.ctx` nullable (it mirrors capture.Runner's NON-nullable `*anyopaque`) or `EventHandler.ctx` non-nullable (it mirrors S1.Handler's nullable `?*anyopaque`) — each seam follows its closest analogue; `@alignCast` is mandatory when recovering the typed pointer.
- ❌ Don't forget `fbs`/`fd_in`/`SliceInput`/`FdInput` must be stack `var` (mutable) so `&x` is `*T` and coerces to `*anyopaque` — a `const` yields `*const T` which does NOT coerce (capture findings.md §2).
- ❌ Don't add a `mouse_enabled` field to `State` — mouse enable/disable is purely the escape sequences (handled in enter/restoreRaw); State stays as S1 defined it.
- ❌ Don't run `zig build test` without `-Doptimize=ReleaseFast` — Debug mode hits the R_X86_64_PC64 linker bug (PRD §15).
- ❌ Don't touch `main.zig`, `build.zig`, `build.zig.zon`, or create any new file — S2 edits ONLY `src/tui/app.zig` (additive), and main.zig already has all S1 wiring (S2's tests are reachable via the existing test-block import).
- ❌ Don't wire `region` to `runEvents` — that's P3.M3. S2 only ships the library (`readEvent`/`runEvents`/`Event`/`EventHandler`) + the enter/restoreRaw mouse bytes.
- ❌ Don't run any test against the user's running tmux, or `tmux kill-server`/`pkill tmux` (PRD §0). Any live smoke uses its OWN pty / scratch binary; the full mouse-decode assertion is deferred to P3.M3's isolated-server integration test.
