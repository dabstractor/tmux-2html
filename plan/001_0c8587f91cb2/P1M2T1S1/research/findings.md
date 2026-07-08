# Research findings — P1.M2.T1.S1 (Absorb queryColors + Colors struct)

All facts below were read **directly from the cached source**:
- ghostty 1.3.1: `~/.cache/zig/p/ghostty-1.3.1-5UdBCwYm-gQeBa4bu1-sMooCQS4KVriv5wWSIJ_sI-Cb`
- Zig 0.15.2 std: `/home/dustin/.local/opt/zig-x86_64-linux-0.15.2/lib/std`

The architecture doc `render_pipeline.md §2` (VERIFIED) gives the term2html
`queryColors` flow; this file nails the exact `ghostty_vt` + std APIs and the
non-obvious gotchas (allocator wiring, request-list ownership, raw termios).

## 1. ghostty-vt module root + re-exports

- Module name registered in build: **`ghostty-vt`** (HYPHEN). `src/build/GhosttyZig.zig:29`.
- Module **root source file**: `src/lib_vt.zig` (`GhosttyZig.zig:initVt`, `.root_source_file = b.path("src/lib_vt.zig")`).
- `lib_vt.zig` re-exports (all public, all we need):
  - `pub const color = terminal.color;`
  - `pub const osc = terminal.osc;`
  - `pub const Parser = terminal.Parser;`
  - (also: `point`, `page`, `Selection`, `Terminal`, `Stream`, … — not needed here)

So in palette.zig: `const ghostty_vt = @import("ghostty-vt");` then
`ghostty_vt.color`, `ghostty_vt.osc`, `ghostty_vt.Parser`.

## 2. color types (`src/terminal/color.zig`)

- `pub const RGB = packed struct(u24) { r: u8 = 0, g: u8 = 0, b: u8 = 0 }` (line 400).
  - Literal: `RGB{ .r = 41, .g = 44, .b = 51 }`.
  - `pub fn eql(self, other) bool`; `pub fn parse(value: []const u8) error{InvalidFormat}!RGB` (line 541).
  - `@bitSizeOf(RGB) == 24`, `@sizeOf(RGB) == 4`.
- `pub const Palette = [256]RGB;` (line 62).
- `pub const default: Palette = …;` (line 8) — the Ghostty bundled 256-color palette.
- `pub const Dynamic = enum(u5) { foreground = 10, background = 11, cursor = 12, … }` (line 355).

**RGB.parse("rgb:cc/00/00")** = `{ r=204, g=0, b=0 }` (verified via `fromHex`:
2 hex digits → `color * maxInt(u8) / maxInt(u8)`). So:
- `rgb:cc/00/00` → {204,0,0}; `rgb:ff/ff/ff` → {255,255,255}; `rgb:29/2c/33` → {41,44,51}.
These are the values to assert in unit tests.

## 3. Parser (VT state machine) — `src/terminal/Parser.zig`

- `pub fn init() Parser` (line 222) — **NO args**.
- `pub fn deinit(self: *Parser) void` (line 244) — frees the inner osc_parser.
- `pub fn next(self: *Parser, c: u8) [3]?Action` (line 251) — feed ONE byte; returns
  up to 3 actions (exit/transition/entry). **Iterate all 3 slots.**
- `Action = union(enum)` (line 51); the one we care about:
  **`.osc_dispatch: osc.Command`** (line 68).
- **`osc_parser: osc.Parser` is a PUBLIC, mutable field** (line ~219).
  - **GOTCHA A (critical):** `init()` sets `.osc_parser = .init(null)` (null allocator).
    With `alloc == null`, color OSCs are DISCARDED: `osc.zig::ensureAllocator`
    sets `state = .invalid`, and `parsers/color.zig::parse` returns null
    (`parser.alloc orelse { …; return null; }`). **You MUST set the allocator:**
    ```zig
    var parser = ghostty_vt.Parser.init();
    parser.osc_parser.alloc = allocator;   // <-- REQUIRED for color_operation
    defer parser.deinit();
    ```
    This exact pattern is used by ghostty's OWN test `Parser.zig` "osc: 112
    incomplete sequence": `p.osc_parser.alloc = std.testing.allocator;`.

## 4. osc.Command + color_operation — `src/terminal/osc.zig` + `osc/parsers/color.zig`

`Command = union(Key)` (osc.zig:25). The variant:
```zig
.color_operation: struct {
    op: color.Operation,
    requests: color.List = .{},
    terminator: Terminator = .st,
}
```
- `osc.color` namespace = `parsers.color` (osc.zig:20 `pub const color = parsers.color;`).
- `pub const List = std.SegmentedList(Request, 2);` (color.zig:332) — inline cap 2.
  - `.count() usize`; `.at(i) *Request`; `.deinit(allocator) void`; `.constIterator(0)`.
- `pub const Request = union(enum) { set: ColoredTarget, query: Target, reset: Target, reset_palette, reset_special };`
- `pub const Target = union(enum) { palette: u8, special: SpecialColor, dynamic: DynamicColor };`
- `pub const ColoredTarget = struct { target: Target, color: RGB };`

So a SET response decodes as:
`Request{ .set = .{ .target = .{ .palette = <idx> }, .color = <RGB> } }`
(palette index) or
`Request{ .set = .{ .target = .{ .dynamic = .foreground }, .color = <RGB> } }` (fg),
`.background` (bg).

**GOTCHA B (critical — leak):** `osc.Parser.reset()` handles `.color_operation => {}`
(no-op) — it does NOT free `requests`. The parser never frees color_operation
requests. Since `Action.osc_dispatch = cmd.*` COPIES the Command (Parser.zig:271),
the copy's `requests` SegmentedList owns the only live reference to any heap
segments. **The consumer MUST call `op.requests.deinit(allocator)` after extracting
colors**, or it leaks (testing.allocator fails the test). For ≤2 requests there is
no heap alloc (inline capacity), so deinit is a no-op there; for ≥3 it frees the
dynamic segment. Freeing once is correct (the parser's stale copy is overwritten
without access on the next parse — no UAF).

## 5. OSC terminators (for unit-test byte streams)

Verified via `Parser.zig` tests "osc: change window title" / "(end in esc)":
- **BEL (0x07)** terminates an OSC and yields `.osc_dispatch` on that same byte.
- **ESC (0x1b) followed by '\\' (0x5c)** (the `ST`) also terminates (the dispatch
  action is returned by the `next(0x1b)` call; the following `next('\\')` is the
  literal terminator consumed by the osc parser).

Use BEL (`\x07`) in tests — simplest (one byte, dispatch on the same `next` call),
and it is what term2html uses for its query bytes (`render_pipeline.md §2`).

## 6. termios raw mode — Zig 0.15.2 `std.posix`

- `pub fn tcgetattr(handle: fd_t) TermiosGetError!termios` (posix.zig:6757).
- `pub fn tcsetattr(handle: fd_t, optional_action: TCSA, termios_p: termios) TermiosSetError!void` (posix.zig:6772).
- `pub const TCSA = enum(c_uint) { NOW, DRAIN, FLUSH, _ };` (posix.zig:219) → use **`.FLUSH`**.
- `pub const termios = system.termios;` `pub const V = system.V;` (posix.zig:169,173).
- On x86_64 linux (`os/linux.zig:7591` else-branch): `termios = extern struct {
    iflag, oflag, cflag, lflag, line, cc: [NCCS]cc_t, ispeed, ospeed }`.
- `tc_lflag_t = packed struct(tcflag_t) { ICANON: bool = false, ECHO: bool = false, … }`
  (`os/linux.zig:7398`+). So: `raw.lflag.ICANON = false; raw.lflag.ECHO = false;`
- `V = enum(u32) { … TIME = 5, MIN = 6, … }` on x86_64 (`os/linux.zig:7522` else).
  Use the enum names (portable across arches): `raw.cc[@intFromEnum(V.MIN)] = 0;`
  `raw.cc[@intFromEnum(V.TIME)] = 5;`. `cc` is `[NCCS]u8`; 0 and 5 fit.

**Semantics:** MIN=0, TIME=5 → each `tty.read(&buf)` returns after a 500 ms
inter-byte timeout OR as soon as ≥1 byte is available (whichever first). A read
that returns `0` bytes ⇒ terminal stopped responding ⇒ done. (This is why
term2html doesn't poll /dev/tty — macOS can't; render_pipeline.md §2.)

## 7. /dev/tty open + read/write

- `std.fs.openFileAbsolute("/dev/tty", .{ .mode = .read_write }) File.OpenError!File` (fs.zig:268).
- `File.read(buffer: []u8) ReadError!usize` (File.zig:847); `File.writeAll(bytes)` (File.zig:975);
  `File.write(bytes)` (File.zig:966).
- Restore termios in a `defer` (ignore errors): `defer std.posix.tcsetattr(tty.handle, .FLUSH, original) catch {};`

## 8. Test reachability (build/test integration — IMPORTANT)

- `build.zig` test step: `b.addTest(.{ .root_module = exe.root_module })`; root = `src/main.zig`.
- Zig runs ONLY tests reachable from the test root via `@import`. palette.zig is a
  NEW file imported by nothing yet → its tests would NOT run under `zig build test`.
- **Fix (no build.zig change):** add a top-level `test` block to `src/main.zig`:
  ```zig
  test {
      // P1.M2: keep palette.zig tests reachable from the test root.
      // Top-level test blocks are only compiled in test mode, so ghostty-vt
      // stays LAZY for normal `zig build`.
      _ = @import("palette.zig");
  }
  ```
  Why this works with no build edit: `palette.zig` is relatively `@import`ed from
  `main.zig` (the exe.root_module root), so it shares `exe.root_module`'s named
  imports — including **`ghostty-vt`** (already added by `build.zig`'s
  `exe.root_module.addImport("ghostty-vt", …)`). `@import("ghostty-vt")` in
  palette.zig resolves through that table. Verified equivalent: cli.zig already
  does `@import("parg")` / `@import("build_options")` the same way (T3.S1/T3.S2).
- **`--release=fast` is MANDATORY** for `zig build test` from this task onward:
  palette.zig `@import("ghostty-vt")` now actually compiles ghostty in the test
  path → the Debug `R_X86_64_PC64` linker bug (research_ghostty_vt.md §6) WILL
  fire in a Debug test build. `zig build` (non-test) keeps ghostty lazy (fast).

## 9. The OSC query byte sequences (term2html, render_pipeline.md §2)

- Palette index query (OSC 4): `\x1b]4;{idx};?\x07` (BEL terminator).
- Foreground query (OSC 10): `\x1b]10;?\x07`.
- Background query (OSC 11): `\x1b]11;?\x07`.
- Send palette queries in **batches of 32** (idx 0..31, 32..63, …, 224..255);
  append `\x1b]10;?\x07\x1b]11;?\x07` to the **final** batch (idx 224..255).
- After each batch write, read responses (loop until `tty.read` returns 0) and feed
  every byte through the VT Parser; route each `.osc_dispatch` to `applyOscCommand`.

## 10. defaultColors() + Colors struct (item contract)

```zig
pub const Colors = struct {
    palette: [256]color.RGB,
    foreground: ?color.RGB,
    background: ?color.RGB,
    palette_received_count: u16,
};

pub fn defaultColors() Colors {
    return .{
        .palette = ghostty_vt.color.default,            // [256]RGB
        .foreground = ghostty_vt.color.default[7],      // palette[7] (white-ish)
        .background = .{ .r = 41, .g = 44, .b = 51 },   // fixed (PRD §6)
        .palette_received_count = 256,
    };
}
```

`queryColors()` starts from `defaultColors()` then zeroes `palette_received_count`
and overwrites palette/fg/bg from live responses. `palette_received_count < 256`
after the loop ⇒ log the "terminal not responding" warning.

## 11. Confidence

Every struct field, function signature, enum value, and the two critical gotchas
(allocator wiring + request-list ownership) were read line-by-line from the cached
ghostty 1.3.1 + Zig 0.15.2 std source. The allocator-wiring pattern is copied from
ghostty's own `Parser.zig` test. No guessing.
