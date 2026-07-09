# P3.M1.T1.S2 — Design Notes & S1↔S2 Integration Reconciliation

> Companion to `sgr_mouse_encoding.md` (external protocol facts) and
> `zig_reader_poll_api.md` (verified Zig 0.15.2 stdlib). This file captures the
> NON-OBVIOUS integration decisions: how S2 consumes the ALREADY-SHIPPED S1
> `app.zig` (verified at `src/tui/app.zig`, 307 lines) without breaking it, and
> the `readEvent`/`Event`/`Input` seam design.

## 0. Ground truth: S1 is already SHIPPED (not just contracted)

S1's `src/tui/app.zig` exists and is implemented (verified by reading it). The
relevant shipped surface S2 builds on (line numbers from the shipped file):

| Symbol | Line | S1 definition (unchanged by S2) |
|---|---|---|
| `Action` | 30 | `enum { none, quit, confirm }` |
| `State` | 34 | `struct { fd: fd_t, original: termios }` |
| `Handler` | 48 | `struct { ctx: ?*anyopaque, classifyFn: *const fn(?*anyopaque,u8)Action }; pub fn classify(u8)Action` |
| `enter_seq` | 61 | `"\x1b[?1049h\x1b[?25l"` |
| `exit_seq` | 62 | `"\x1b[?25h\x1b[?1049l"` |
| `restoreRaw()` | 117 | writes `exit_seq`; `tcsetattr(.NOW, original)` |
| `enter()` | 134 | writes `enter_seq`; `tcsetattr(.FLUSH, makeRaw)`; installs signals |
| `exit(state)` | 151 | delegates to `restoreRaw()` |
| `run(Handler)` | 201 | byte loop: `stdin.read(&[1]u8)` → `handler.classify(byte)` |
| `default_handler` | 222 | quits on `q`/0x03/0x1b |

main.zig ALREADY has S1 wiring: `const tui = @import("tui/app.zig")` (line 9),
the root `pub const panic` override calling `tui.restoreRaw()` (lines 19-27),
and the test-block import `_ = @import("tui/app.zig");` (line 489).

**⇒ S2 touches ONLY `src/tui/app.zig`.** No main.zig, no build.zig change — S2's
new tests are already reachable via the existing test-block import.

## 1. The S1↔S2 tension and its resolution

- **S1 design intent** (from S1 PRP + app.zig comments): `run()` is the "STABLE
  forward-compat surface"; S2 was anticipated to "decode SGR mouse in a STATEFUL
  Handler.ctx" (accumulate `\x1b[<...` bytes in the byte-handler). S1's `run()`/
  `Handler`/`classify(byte)` are byte-level.
- **S2 work-item contract** (authoritative): a `readEvent(reader) !Event` that
  returns a tagged `Event` union (mouse / plain-key / esc-seq), output "typed
  Event stream consumed by the input/select layer" (P3.M2 input.zig/select.zig).

These are *different abstractions* (byte→Action vs reader→Event). Resolution:
**S2 ADDS an event-level surface and does NOT remove or change S1's run/Handler.
S1's byte-level `run()`/`default_handler` stay as the smoke-test path; S2's
event-level `readEvent`/`EventHandler`/`runEvents` is the surface P3.M2/P3.M3
use.** This honors S1's "run() never changes" guarantee AND delivers the S2
contract. The two seams mirror their respective analogues:
- `Input` (readEvent's byte source) mirrors `capture.Runner` (`{ctx:*anyopaque,
  fn}` — non-nullable ctx; `@ptrCast(@alignCast)` to recover).
- `EventHandler` mirrors S1's `Handler` (`{ctx:?*anyopaque, fn}` — nullable ctx).

## 2. The lone-Esc / esc-sequence ambiguity (THE crux of input decoding)

A single `0x1b` byte is ambiguous: a standalone Esc key vs the start of a
multi-byte escape sequence (`\x1b[A`, `\x1b[<0;1;1M`, ...). With raw blocking
reads (S1's VMIN=1/VTIME=0), there is no peek — you must use **timing**.

**Chosen mechanism: `std.posix.poll` with a short inter-byte timeout** (verified
`posix.zig:6447`: `poll(fds: []pollfd, timeout: i32)`; `std.posix.pollfd` =
`extern struct { fd, events, revents }`; `std.posix.POLL.IN = 0x001`; timeout in
ms, 0=immediate, <0=infinite). After reading `0x1b`, read follow-up bytes with a
~50ms timeout; a 50ms gap = end-of-sequence. Terminals send sequences
atomically, so the common CSI/SS3 cases (arrows, mouse) resolve with ZERO added
latency; ONLY a true lone-Esc pays the 50ms (standard; libvaxis/termbox do this).

A `isCsiFinal(c)` fast-stop (`0x40 <= c <= 0x7E`, guarded by `len >= 3`) ends a
CSI/SS3 sequence the instant its final byte arrives (mouse terminator M/m and
arrow letters A/B/C/D are all in this range), so arrows/mouse don't wait the full
50ms. `<` (0x3C) is in the CSI PARAMETER range (0x30-0x3F), so it never false-
triggers the fast-stop.

## 3. The readEvent accumulation + pure-classify split (unit-testability)

`readEvent(input: Input)` accumulates the raw sequence bytes (timing-dependent;
NOT pure), then hands the accumulated slice to the PURE `classifyEscSeq(bytes)
Event` (timing-free; fully unit-tested with byte slices). This mirrors the
capture.zig "pure parse vs real-fd execution" split. Three pure, slice-based
decoders, all unit-tested:
- `decodeButton(b: u32, term: u8) MouseDecode` — bit layout → button/action/mods.
- `parseMousePayload(payload: []const u8) ?MouseEvent` — "{b};{x};{y}{M|m}" → MouseEvent.
- `classifyEscSeq(seq: []const u8) Event` — full ESC-inclusive slice → Event (mouse/key/seq).

`readEvent` itself is exercised in tests via `SliceInput` (a `fixedBufferStream`
`Input` impl) — for COMPLETE sequences (mouse, arrows) and the lone-Esc-at-EOF
case. Real-fd timing (FdInput + poll) is compile-verified + manual/integration.

## 4. Event union (final design)

```
Event = union(enum) { key: u8, mouse: MouseEvent, seq: EscSeq, eof: void }
```
- `key: u8` — a single non-sequence byte (printable, control, or standalone Esc
  signaled by `0x1b`). P3.M2's key decoder consumes these for vim keys/motions.
- `mouse: MouseEvent` — FULLY decoded SGR mouse (this subtask's core deliverable).
- `seq: EscSeq` — raw multi-byte ESC sequence (CSI `\x1b[...` / SS3 `\x1bO...` /
  Alt+char `\x1b<char>`), bytes INCLUDING the leading `0x1b`, handed UNDECODED to
  the key decoder P3.M2.T1.S1 (arrows, Ctrl-mods, function keys). S2 does NOT
  decode arrows/vim — that is explicitly P3.M2.T1.S1's job (work item: "dispatch
  to key decoder P3.M2.T1.S1").
- `eof` — stdin closed.

`EscSeq` = `{ bytes: [16]u8, len: u8 }` (fixed inline buffer; CSI/SS3 ≤ ~8
bytes; 16 generous). No allocation.

## 5. Modifier resolution (the work item's "b&8 or 16" ambiguity)

xterm ctlseqs (verified): **Shift=4, Alt/Meta=8, Control=16, Motion=32, wheel
64(up)/65(down).** So **Alt = `(b & 8) != 0`** and Ctrl = `(b & 16) != 0`. The
work item's "b&8 or 16" for Alt was imprecise — `8` is Alt, `16` is Ctrl. PRD
§7.6 "drag selects linewise by default, block with modifier e.g. Alt" ⇒ the
select layer (P3.M2.T2) switches to BLOCK when `mouse.alt` is set during a drag.
S2 reports `alt`/`ctrl`/`shift` booleans; the policy (block-drag) is the
consumer's. Coordinates are 1-based SGR cells (consumer subtracts 1 for grid).

## 6. enter()/restoreRaw() mouse wiring (additive, exact shipped-code edits)

- ADD `mouse_enable_seq`, `mouse_disable_seq`, and comptime concatenations
  `enter_full_seq = enter_seq ++ mouse_enable_seq`, `restore_seq =
  mouse_disable_seq ++ exit_seq` (Zig `++` on string-literal consts = comptime).
- `enter()`: the single `stdout().writeAll(enter_seq)` line →
  `stdout().writeAll(enter_full_seq)` (alt screen + hide cursor + enable mouse,
  one write). NOT signal context ⇒ buffered File write is fine.
- `restoreRaw()`: the `std.posix.write(saved_fd, exit_seq)` line →
  `std.posix.write(saved_fd, restore_seq)` (disable mouse FIRST, then show cursor
  + leave alt screen; one async-signal-safe write). exit() is unchanged (it
  delegates to restoreRaw).
- S1's `enter_seq`/`exit_seq` consts and their unit test are UNCHANGED (S2 adds
  NEW consts; the test still passes). State struct unchanged (no `mouse_enabled`
  flag needed — enable/disable is purely the escape sequences).
