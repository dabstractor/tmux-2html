# Zig 0.15.2 Reader / Poll / fixedBufferStream API Reference

**Status:** every signature below was read from the actual 0.15.2 stdlib at
`/home/dustin/.local/opt/zig-x86_64-linux-0.15.2/lib/std/` and cross-checked
against working code in this repo. `zig version` = 0.15.2. A `zig build` of this
repo **passes semantic/type analysis** (all cited signatures type-check); the
build only fails at the **link** step with a host-toolchain relocation error
(`R_X86_64_PC64` from gcc-16.1.1 `crt1.o:.sframe`), which is environmental and
unrelated to any API cited here.

All line numbers are 1-indexed into the shipped 0.15.2 stdlib unless prefixed
`repo:`.

---

## TL;DR (the answers, one line each)

1. **`File.read`**: `pub fn read(self: File, buffer: []u8) ReadError!usize` —
   **YES, `File.read(buf: []u8) !usize` is correct for 0.15.2.** The repo's
   working idiom is `tty.read(&buf)` in a loop (palette.zig), and
   `stdin.readToEndAlloc(alloc, MAX)` (render.zig).
2. **`AnyReader`** lives at `std.Io.AnyReader` = `@import("Io/DeprecatedReader.zig")`
   (Io.zig:423). There is **no zero-arg `file.reader()` returning AnyReader**; the
   new `File.reader(buf)` takes a buffer and returns the new `File.Reader`
   interface. `AnyReader` is the *deprecated* type-erased reader.
3. **`fixedBufferStream`**: `var fbs = std.io.fixedBufferStream(bytes); const r = fbs.reader();`
   — `.reader()` returns a `GenericReader` (works with `reader: anytype`).
4. **`.readByte()` exists** (returns `error.EndOfStream`, NOT an optional).
   **`.readByteOrNull()` does NOT exist** anywhere in the stdlib. **`.read(buf)`
   exists.**
5. **poll**: `pub fn poll(fds: []pollfd, timeout: i32) PollError!usize`
   (posix.zig:6447). Struct is **`std.posix.pollfd`** (lowercase) =
   `extern struct { fd: fd_t, events: i16, revents: i16 }`. Constant is
   **`std.posix.POLL.IN`** (capital `POLL`). There is **no `std.posix.PollFd`**.
   `timeout<0`=infinite, `0`=immediate, `>0`=ms.
6. **Recommended design**: a small `Input` interface struct (mirrors
   capture.zig's `Runner` seam) with `readByteTimeout(ms) !?u8` — one impl
   wraps `fd + poll` (prod), one wraps `fixedBufferStream` (tests). Keep the
   pure ESC-sequence parser a separate `fn parseEvent(reader: anytype)` unit test.
7. **capture.zig seam**: `Runner = struct { ctx: *anyopaque, runFn, run }`
   (capture.zig:58-66); tests inject `FakeTmux` via `.{ .ctx = @ptrCast(&fake),
   .runFn = FakeTmux.run }`.

---

## 0. Namespace reality: `std.io` == `std.Io`

Both spellings work in 0.15.2; lowercase is an alias of the capital one:

```zig
// std/std.zig
pub const Io = @import("Io.zig");   // std.zig:22
pub const io = Io;                  // std.zig:82   <-- alias
```

So `std.io.fixedBufferStream`, `std.io.AnyReader`, `std.io.GenericReader` are all
valid and identical to the `std.Io.*` forms. There is **no separate
`std/io.zig`** file (only `std/Io.zig` + `std/Io/` dir); `std.io` is purely the
alias. The repo already uses the capital form in prod: `std.Io.Writer.Allocating`
(repo: render.zig, selection arm). **Prefer `std.io.*` for reader/poll to match
the question; it compiles either way.**

---

## 1. Reading bytes from stdin — the verified `File.read` signature

```zig
// std/fs/File.zig:842-848
pub const ReadError = posix.ReadError;
pub const PReadError = posix.PReadError;

pub fn read(self: File, buffer: []u8) ReadError!usize {   // :847
    if (is_windows) {
        return windows.ReadFile(self.handle, buffer, null);
    }
    return posix.read(self.handle, buffer);
}
```

**Answer: YES.** `File.read(self: File, buf: []u8) !usize` is exactly the 0.15.2
signature. It calls `posix.read` (non-blocking w.r.t. termios `V.MIN/V.TIME` —
see palette.zig below). `readAll` exists but is marked "Deprecated in favor of
`Reader`" (File.zig:854).

The bulk-read helper used by render.zig:
```zig
// std/fs/File.zig:809
pub fn readToEndAlloc(self: File, allocator: Allocator, max_bytes: usize) ![]u8 { ... }
```

### Working repo idiom A — bulk read (repo: src/render.zig:360-362)
```zig
const stdin = std.fs.File.stdin();
const ansi = try stdin.readToEndAlloc(alloc, MAX_STDIN); // File.zig:809; caller frees.
defer alloc.free(ansi);
```

### Working repo idiom B — byte/chunk loop with timeout via termios (repo: src/palette.zig)
The terminal-input pattern this repo ALREADY USES for timed reads. It sets
`V.MIN=0` (return immediately even if 0 bytes) and `V.TIME=5` (500ms cap), then
loops on `read`:

```zig
// repo: src/palette.zig:107-112  (termios for timed reads)
var raw = original;
raw.lflag.ICANON = false;
raw.lflag.ECHO = false;
raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
raw.cc[@intFromEnum(std.posix.V.TIME)] = 5; // 500ms (deciseconds).

// repo: src/palette.zig:143-152  (the read loop)
fn readAndFeed(tty: *std.fs.File, ...) !void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = tty.read(&buf) catch break; // read error ⇒ stop this batch.
        if (n == 0) break;                    // GOTCHA 6: 500ms timeout, no more data.
        feedAndApply(parser, buf[0..n], ...);
    }
}
```

**Key fact for terminal input:** with `V.MIN=0 / V.TIME=N`, `File.read(&buf)`
returns `0` on timeout (not an error). This is the palette.zig mechanism. For the
new TUI ESC-disambiguation you have **two** viable mechanisms — termios
`V.TIME` (repo-proven) OR `std.posix.poll` (Q5). poll is cleaner for "one timeout
after a byte already read" because you don't have to flip termios between modes.

---

## 2. `std.io.AnyReader` in 0.15.2

```zig
// std/Io.zig:423
pub const AnyReader = @import("Io/DeprecatedReader.zig");
```

The imported file *is itself the struct* (`const Self = @This();` at
Io/DeprecatedReader.zig:380), so `AnyReader` is a concrete, type-erased struct:

```zig
// std/Io/DeprecatedReader.zig:1-9
context: *const anyopaque,
readFn: *const fn (context: *const anyopaque, buffer: []u8) anyerror!usize,

pub const Error = anyerror;

pub fn read(self: Self, buffer: []u8) anyerror!usize {
    return self.readFn(self.context, buffer);
}
```

### How to get an AnyReader from a `std.fs.File`

There is **no** `file.reader()` that returns `AnyReader`. The options are:

| Call | Returns | Where |
|---|---|---|
| `file.deprecatedReader()` | `File.DeprecatedReader` (= `GenericReader(File, ReadError, read)`) | File.zig:1093, :1097 |
| `fbs.reader()` (fixedBufferStream) | `GenericReader(*FixedBufferStream, error{}, read)` | fixed_buffer_stream.zig:27, :33 |
| any `GenericReader` value `g` | `g.any()` → **`AnyReader`** | Io.zig:282 |
| `file.reader(buf)` | new `File.Reader` interface (`interface: std.Io.Reader`) — **NOT** AnyReader | File.zig:2105 |

```zig
// std/fs/File.zig:1093, :1097
pub const DeprecatedReader = io.GenericReader(File, ReadError, read);
pub fn deprecatedReader(file: File) DeprecatedReader { return .{ .context = file }; }

// std/fs/File.zig:2105  (NEW interface reader — needs a caller-owned buffer)
pub fn reader(file: File, buffer: []u8) Reader { return .init(file, buffer); }
```

The new `File.Reader` (File.zig:1117) is a vtable/buffer struct carrying an
`interface: std.Io.Reader`; it is a different beast from `AnyReader` and is
**not** what you want for a tiny byte-at-a-time TUI loop. For stdin input prefer
raw `File.read(&buf)` (see Q1/Q5/Q6).

### Is the old `std.io.Reader(...)` generic comptime struct gone?

Not gone — **renamed**. The comptime generic is now the **function**
`GenericReader`:
```zig
// std/Io.zig:86
pub fn GenericReader(
    comptime Context: type,
    comptime ReadError: type,
    comptime readFn: fn (context: Context, buffer: []u8) ReadError!usize,
) type { ... }
```
The old call shape `std.io.Reader(Ctx, E, readFn)` is dead; the modern spelling
is `std.io.GenericReader(Ctx, E, readFn)`. The type-erased version is
`std.io.AnyReader` (a plain struct, not generic).

---

## 3. `std.io.fixedBufferStream` — create + get a reader

```zig
// std/Io.zig:427, :429
pub const FixedBufferStream = @import("Io/fixed_buffer_stream.zig").FixedBufferStream;
pub const fixedBufferStream = @import("Io/fixed_buffer_stream.zig").fixedBufferStream;

// std/Io/fixed_buffer_stream.zig:10-13
pub fn FixedBufferStream(comptime Buffer: type) type { ... }   // Buffer = []u8 | []const u8

// :27  the reader type it returns:
pub const Reader = io.GenericReader(*Self, ReadError, read);   // ReadError = error{}  (:16)

// :33
pub fn reader(self: *Self) Reader { return .{ .context = self }; }

// :43  (its read — no errors possible)
pub fn read(self: *Self, dest: []u8) ReadError!usize { ... }

// :99
pub fn fixedBufferStream(buffer: anytype) FixedBufferStream(Slice(@TypeOf(buffer))) {
    return .{ .buffer = buffer, .pos = 0 };
}
```

`fixedBufferStream` is marked "Deprecated in favor of `std.Io.Reader.fixed`", but
it **is present and works** in 0.15.2 and is the simplest way to feed bytes to a
`reader: anytype` parser in a unit test.

### Exact test harness (feeds `"\x1b[<0;5;10M"` to `readEvent(reader: anytype)`)

```zig
test "parse SGR mouse report \\x1b[<0;5;10M" {
    const seq = "\x1b[<0;5;10M";            // *const [13:0]u8 -> coerces to []const u8
    var fbs = std.io.fixedBufferStream(seq); // fbs MUST be `var` (reader() takes *Self)
    const ev = try parseEvent(fbs.reader()); // reader: anytype = GenericReader(..., error{}, read)
    try std.testing.expectEqualStrings(...); // assert decoded Event
}
```

Gotchas: `fbs` must be a mutable `var` because `reader(self: *Self)` needs an
address; a string literal coerces to `[]const u8`, giving
`FixedBufferStream([]const u8)` whose `read` is infallible (`error{}`).

---

## 4. Reader methods — what exists, signatures, error vs optional

On **`AnyReader`** (std/Io/DeprecatedReader.zig):

```zig
pub fn read(self: Self, buffer: []u8) anyerror!usize { ... }      // :9
pub fn readAll(self: Self, buffer: []u8) anyerror!usize { ... }   // :21
pub fn readNoEof(self: Self, buf: []u8) anyerror!void { ... }     // :36  (error.EndOfStream if short)
pub fn readByte(self: Self) anyerror!u8 { ... }                   // :232  returns error.EndOfStream
```
```zig
// std/Io/DeprecatedReader.zig:231-236  (readByte body — the canonical "no byte" signal)
/// Reads 1 byte from the stream or returns `error.EndOfStream`.
pub fn readByte(self: Self) anyerror!u8 {
    var result: [1]u8 = undefined;
    const amt_read = try self.read(result[0..]);
    if (amt_read < 1) return error.EndOfStream;
    return result[0];
}
```

On the **generic** `GenericReader` (std/Io.zig):
```zig
pub inline fn read(self: Self, buffer: []u8) Error!usize { ... }  // :106
pub inline fn readByte(self: Self) NoEofError!u8 { ... }          // :219  returns error.EndOfStream
// NoEofError = ReadError || error{EndOfStream}  (Io.zig:97-100)
pub inline fn any(self: *const Self) AnyReader { ... }            // :282
```

**Answers:**
- `.read(buf) !usize` — exists on both. Returns count (0 = EOF).
- `.readByte() !u8` — exists on both. **Returns `error.EndOfStream`** when no byte
  (an ERROR, **not** an optional).
- `.readByteOrNull()` — **DOES NOT EXIST** in the entire stdlib (verified:
  `grep -rn readByteOrNull lib/std` → zero matches). Build it yourself:

```zig
// readByteOrNull idiom (verified pattern from stdlib's own internals)
fn readByteOrNull(r: anytype) !?u8 {
    return r.readByte() catch |err| switch (err) {
        error.EndOfStream => null,
        else => return err,
    };
}
```
(This exact `catch error.EndOfStream => ...` shape is used throughout the
stdlib, e.g. DeprecatedReader.zig:160, :179, :224.)

---

## 5. `std.posix.poll` — timed peek to disambiguate lone ESC

### Signature
```zig
// std/posix.zig:6447
pub fn poll(fds: []pollfd, timeout: i32) PollError!usize { ... }
```
On Linux it forwards straight to `system.poll(fds.ptr, fds_count, timeout)`
(posix.zig:6461) and retries on `EINTR` (posix.zig:6464). `PollError` (posix.zig
above 6447) = `SignalInterrupt | SystemResources | UnexpectedError`.

### The `pollfd` struct (lowercase!) and `POLL` constant (capital!)
```zig
// std/posix.zig:92
pub const POLL = system.POLL;
// std/posix.zig:143
pub const pollfd = system.pollfd;

// std/os/linux.zig:7041
pub const nfds_t = usize;
pub const pollfd = extern struct {
    fd: fd_t,
    events: i16,
    revents: i16,
};

// std/os/linux.zig:7049
pub const POLL = struct {
    pub const IN = 0x001;
    pub const PRI = 0x002;
    pub const OUT = 0x004;
    pub const ERR = 0x008;
    pub const HUP = 0x010;
    pub const NVAL = 0x020;
    pub const RDNORM = 0x040;
    pub const RDBAND = 0x080;
};
```

**Exact spelling in 0.15.2 (answers the Q5 "is it POLL or pollfd?"):**
- The struct is **`std.posix.pollfd`** — **all-lowercase** (an `extern struct`
  re-exported from the OS layer). There is **no `std.posix.PollFd`**.
- The constant group is **`std.posix.POLL`** — **capital** — and you index it as
  **`std.posix.POLL.IN`**. (Do not write `std.posix.POLL.IN` as a field of a
  bool-flag termios `POLL` struct — that's a different `POLL`; the poll(2) one is
  this integer-namespace `POLL`.)

### timeout (i32) semantics
POSIX `poll(2)`, passed through unchanged:
- `timeout < 0` → block indefinitely until an event / signal.
- `timeout == 0` → **immediate, non-blocking** check; return count of ready fds
  (0 if none).
- `timeout > 0` → wait up to `timeout` milliseconds.

Return value = number of `pollfd` entries with non-zero `revents` (0 = timed out
with nothing ready).

### Calling poll to test "is stdin (fd 0) readable right now, within N ms"

```zig
const std = @import("std");

/// `true` if at least one byte is readable on `fd` within `timeout_ms`,
/// `false` on timeout. Errors propagate.
fn dataReady(fd: std.posix.fd_t, timeout_ms: i32) !bool {
    var fds = [_]std.posix.pollfd{
        .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 },
    };
    const n = try std.posix.poll(&fds, timeout_ms); // posix.zig:6447
    return n > 0 and (fds[0].revents & std.posix.POLL.IN != 0);
}

// After reading 0x1b, disambiguate a lone Esc from an escape sequence:
//   if (try dataReady(stdin_fd, 50)) { /* more bytes coming => it's a sequence */ }
//   else { /* lone Esc key */ }
```
For stdin specifically: `const fd: std.posix.fd_t = std.fs.File.stdin().handle;`
(fd 0). `POLL.IN` (0x001) means "readable / data available".

> Note: `poll` reports readability; you still read the byte(s) with `File.read`
> afterward. For the very first byte of an event you want a **blocking** read
> (`poll` with `timeout=-1`, or `V.MIN=1`), then use `poll(.., 50)` only for the
> follow-up bytes after an ESC.

---

## 6. Cleanest design for `readEvent` — generic `anytype` vs an `Input` interface

### The tension
A pure `fn readEvent(reader: anytype) !Event` is beautifully unit-testable (feed
a `fixedBufferStream`) **but cannot do the timed peek after ESC** — neither
`AnyReader` nor `GenericReader` exposes an fd or a timeout. The ESC-vs-sequence
decision needs environment-specific behaviour (poll on an fd, or termios
`V.TIME`).

### Recommendation: mirror capture.zig — a small 2-field `Input` interface struct

This is the **exact pattern already proven in this repo** (Q7). Define a one- or
two-method vtable struct threaded as the first arg; two concrete impls; the pure
byte→`Event` decode is a separate `anytype` fn that stays 100% unit-tested.

```zig
/// The mockable seam (mirrors capture.zig:58-66 `Runner`).
/// ONE method covers both blocking-first-byte and timed-follow-up needs:
///   readByteTimeout(input, null_ms_or_block)  ->  ?u8
pub const Input = struct {
    ctx: *anyopaque,
    readByteTimeoutFn: *const fn (ctx: *anyopaque, timeout_ms: i32) anyerror!?u8,

    /// timeout_ms: -1 = block forever (first byte of an event);
    /// >=0 = wait at most that many ms; returns null on timeout/EOF.
    pub fn readByteTimeout(self: Input, timeout_ms: i32) anyerror!?u8 {
        return self.readByteTimeoutFn(self.ctx, timeout_ms);
    }
};

fn readEvent(input: Input) !Event {
    const first = (try input.readByteTimeout(-1)) orelse return error.EndOfStream; // block for 1st
    if (first != 0x1b) return decodePrintableOrControl(first);
    // ESC seen — timed peek to separate lone Esc from a sequence:
    const next = try input.readByteTimeout(50); // 50ms; tune 50-100
    if (next == null) return .{ .key = .escape }; // lone Esc
    return parseEscape(input, next.?);            // pure decoder (anytype-testable)
}
```

**Two impls:**

```zig
// PROD — real stdin + poll (Q5)
const FdInput = struct {
    fd: std.posix.fd_t,
    fn readByteTimeout(ctx: *anyopaque, timeout_ms: i32) anyerror!?u8 {
        const self: *FdInput = @ptrCast(@alignCast(ctx));
        if (timeout_ms >= 0) {
            var fds = [_]std.posix.pollfd{.{ .fd = self.fd, .events = std.posix.POLL.IN, .revents = 0 }};
            if ((try std.posix.poll(&fds, timeout_ms)) == 0) return null; // timed out
        }
        var b: [1]u8 = undefined;
        const n = try std.posix.read(self.fd, &b); // or std.fs.File.read
        if (n == 0) return null;                   // EOF
        return b[0];
    }
};
// usage: const in: Input = .{ .ctx = @ptrCast(&fd_in), .readByteTimeoutFn = FdInput.readByteTimeout };

// TEST — fixedBufferStream; any positive timeout returns null at EOF instantly
const SliceInput = struct {
    fbs: *std.io.FixedBufferStream([]const u8),
    fn readByteTimeout(ctx: *anyopaque, _: i32) anyerror!?u8 {
        const self: *SliceInput = @ptrCast(@alignCast(ctx));
        var one: [1]u8 = undefined;
        const n = try self.fbs.read(&one); // infallible (error{})
        return if (n == 0) null else one[0];
    }
};
```

```zig
// Unit test injects the slice impl — NO fd, NO poll:
test "lone ESC after 50ms timeout" {
    var fbs = std.io.fixedBufferStream("\x1b");
    var s = SliceInput{ .fbs = &fbs };
    const in: Input = .{ .ctx = @ptrCast(&s), .readByteTimeoutFn = SliceInput.readByteTimeout };
    try std.testing.expectEqual(Event{ .key = .escape }, try readEvent(in));
}
```

### Why this beats pure `reader: anytype`
- `readEvent` itself stays **non-generic** (one monomorphization) yet fully
  testable, identical in spirit to capture.zig's `Runner`.
- The timed-peek (environment-specific) lives **only** in `FdInput`; the parser
  sees a uniform `?u8`-on-timeout contract.
- The byte→`Event` decode (CSI/SS3 parameter parsing) should additionally be a
  **separate** `fn parseEvent(reader: anytype) !Event` that operates on a
  `fixedBufferStream` of just the post-ESC bytes — giving you the pure-parser
  unit tests (Q3 harness) for free, independent of timing.

**Decision rule:** use `reader: anytype` for the *pure* parser (decode bytes →
Event, no timeouts); use the `Input` interface struct for the *event loop*
(ESC disambiguation, blocking first byte). Don't try to make one `anytype` fn do
both.

---

## 7. The capture.zig pure-vs-realfd seam (the pattern to mirror)

### The seam (repo: src/capture.zig:54-66)
```zig
/// The mockable seam (research/findings.md §2). ONE method; threaded per-call as the FIRST arg
/// to `geometry`/`capture`/`queryOption`/`querySessionName` so unit tests inject a FakeTmux
/// (per-test bytes in `ctx`) — NO live tmux server in unit tests, NO mutable global. `runFn`
/// type MUST be `anyerror![]u8` exactly (so realRun + FakeTmux.run share one pointer type).
pub const Runner = struct {
    ctx: *anyopaque,
    runFn: *const fn (ctx: *anyopaque, argv: []const []const u8, alloc: std.mem.Allocator) anyerror![]u8,

    pub fn run(self: Runner, argv: []const []const u8, alloc: std.mem.Allocator) anyerror![]u8 {
        return self.runFn(self.ctx, argv, alloc);
    }
};
```
The prod singleton (repo: capture.zig:130): `pub const real: Runner =
.{ .ctx = @ptrCast(&real_state), .runFn = realRun };`

### How tests inject the double (repo: src/capture.zig:347-356)
```zig
const FakeTmux = struct {
    cols: u16, rows: u16, history_size: u32, ansi: []const u8,
    session: []const u8 = "sess",
    options: std.StringHashMap([]const u8),

    fn run(ctx: *anyopaque, argv: []const []const u8, alloc: std.mem.Allocator) anyerror![]u8 {
        const self: *FakeTmux = @ptrCast(@alignCast(ctx)); // @alignCast MANDATORY (0.15.2)
        ...
    }
};
```
Per-test wiring (repo: capture.zig:430-431, repeated for every test):
```zig
var fake = FakeTmux{ .cols = 80, .rows = 24, .history_size = 49, .ansi = "", .options = opts };
const runner: Runner = .{ .ctx = @ptrCast(&fake), .runFn = FakeTmux.run };
```

**Pattern takeaways for `readEvent`:**
1. ONE-method vtable `{ ctx: *anyopaque, <fn> }`, threaded as first arg.
2. Two impls share the **exact** fn-pointer type (here `anyerror!?u8`).
3. `@ptrCast` + `@alignCast` to recover the concrete impl from `ctx` (`@alignCast`
   is **mandatory** in 0.15.2 — capture.zig:356 calls it out).
4. Per-test state lives in the on-stack `var fake`/`var s`; **no mutable global**
   => tests never cross-contaminate (proven by capture.zig:529 "two fakes ...
   do not cross-contaminate").
5. Pure helpers (decode, sanitize) are **separate** `test` fns with no seam —
   exactly the split recommended in Q6.

---

## Appendix: citation index

| Claim | File:line |
|---|---|
| `std.io = Io` alias | std/std.zig:82 |
| `pub const Io` | std/std.zig:22 |
| `File.read(self, []u8) ReadError!usize` | std/fs/File.zig:847 |
| `File.readToEndAlloc` | std/fs/File.zig:809 |
| `File.readAll` (deprecated) | std/fs/File.zig:854 |
| `File.DeprecatedReader = GenericReader(...)` | std/fs/File.zig:1093 |
| `File.deprecatedReader()` | std/fs/File.zig:1097 |
| `File.Reader` (new interface struct) | std/fs/File.zig:1117 |
| `File.reader(file, buffer)` (needs buf) | std/fs/File.zig:2105 |
| `AnyReader = @import("Io/DeprecatedReader.zig")` | std/Io.zig:423 |
| AnyReader fields `context`/`readFn` | std/Io/DeprecatedReader.zig:1-2 |
| `AnyReader.read` | std/Io/DeprecatedReader.zig:9 |
| `AnyReader.readByte` (error.EndOfStream) | std/Io/DeprecatedReader.zig:232 |
| `const Self = @This()` (file is AnyReader struct) | std/Io/DeprecatedReader.zig:380 |
| `GenericReader(...)` comptime fn | std/Io.zig:86 |
| GenericReader `readByte` | std/Io.zig:219 |
| GenericReader `.any() -> AnyReader` | std/Io.zig:282 |
| `FixedBufferStream(Buffer)` | std/Io/fixed_buffer_stream.zig:10 |
| FBS `.Reader = GenericReader(...)` | std/Io/fixed_buffer_stream.zig:27 |
| FBS `.reader(self: *Self)` | std/Io/fixed_buffer_stream.zig:33 |
| FBS `.read` (infallible) | std/Io/fixed_buffer_stream.zig:43 |
| `fixedBufferStream(buffer: anytype)` | std/Io/fixed_buffer_stream.zig:99 |
| `readByteOrNull` absent | grep -rn over lib/std → 0 hits |
| `posix.poll(fds, timeout: i32)` | std/posix.zig:6447 |
| `posix.POLL = system.POLL` | std/posix.zig:92 |
| `posix.pollfd = system.pollfd` | std/posix.zig:143 |
| `pollfd` extern struct fields | std/os/linux.zig:7041 |
| `POLL.IN = 0x001` | std/os/linux.zig:7050 |
| repo termios V.MIN=0/V.TIME=5 | src/palette.zig:107-112 |
| repo `tty.read(&buf)` loop | src/palette.zig:143-152 |
| repo `stdin.readToEndAlloc` | src/render.zig:362 |
| repo `Runner` seam | src/capture.zig:58-66 |
| repo `const real: Runner` | src/capture.zig:130 |
| repo `FakeTmux` + `@alignCast` | src/capture.zig:347-356 |
| repo test wiring `.{ .ctx=@ptrCast(&fake), ...}` | src/capture.zig:430-431 |
