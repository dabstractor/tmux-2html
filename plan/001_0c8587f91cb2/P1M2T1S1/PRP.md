# PRP — P1.M2.T1.S1: Absorb `queryColors()` (OSC 4/10/11) + `Colors` struct

## Goal

**Feature Goal**: Create `src/palette.zig` — the palette subsystem's lowest layer — by
absorbing term2html's `terminal.queryColors` flow (verified in
`render_pipeline.md §2`) and exposing: a `Colors` struct, a `defaultColors()`
constructor, a live `queryColors()` that interrogates `/dev/tty` via OSC 4/10/11
under raw termios with a 500 ms timeout, and a **pure, unit-testable**
`applyOscCommand()` that decodes a `ghostty_vt.osc.Command` (`.color_operation`)
into palette/foreground/background updates. Live `/dev/tty` access is factored so
the **parse→apply logic is tested against fixed byte streams without a tty**.

**Deliverable** (two files at `/home/dustin/projects/tmux-2html/`):
- **CREATE `src/palette.zig`** — `Colors`, `defaultColors()`, `queryColors()`,
  `applyOscCommand()`, + unit tests (~9 tests, no `/dev/tty` touched).
- **MODIFY `src/main.zig`** — add ONE top-level `test` block (`_ = @import("palette.zig");`)
  so palette tests are reachable from the test root. (Additive; ghostty stays LAZY in
  non-test builds.) `build.zig`, `build.zig.zon`, `src/cli.zig` **UNCHANGED**.

**Success Definition** (all VERIFIED against Zig 0.15.2 + cached ghostty 1.3.1):
- `zig build test --release=fast` → exit 0, **all** palette tests pass (no leaks under
  `std.testing.allocator`), plus the existing main/cli tests still pass.
- `zig build --release=fast` → exit 0 (ghostty still lazy in the exe: no palette import
  outside the test block).
- `palette.defaultColors().background == RGB{41,44,51}`; `.foreground == color.default[7]`;
  `.palette == color.default`; `.palette_received_count == 256`.
- `applyOscCommand` fed `\x1b]4;0;rgb:cc/00/00\x07` sets `palette[0] = {204,0,0}`;
  `\x1b]10;rgb:ff/ff/ff\x07` sets `foreground`; `\x1b]11;rgb:29/2c/33\x07` sets `background`;
  a non-color OSC leaves `Colors` untouched; a `query` request sets nothing.

> **`--release=fast` is MANDATORY** on every build/test (Debug `R_X86_64_PC64` linker bug;
> from this task the test path actually compiles ghostty-vt — see Gotcha 5).

## User Persona

**Target User**: (1) The implementers of downstream consumers — `palette.resolve()`
(P1.M2.T1.S3), the `sync-palette` body (P1.M2.T2.S1), and the renderer (P1.M3) — which
call `palette.queryColors()` / `defaultColors()` and consume `Colors`; (2) end users who
run `tmux-2html sync-palette` interactively (the only path that calls `queryColors` live).

**Use Case**: `sync-palette` opens a real pty and runs `tmux-2html sync-palette`, whose
body calls `palette.queryColors()` to capture the terminal's actual 256-color palette +
fg/bg, then (T1.S2) writes the cache. The renderer's `--palette live` (P1.M3.T1.S3) calls
`queryColors()` when a controlling tty exists.

**Pain Points Addressed**: Gives the renderer real colors (not a guessed palette); isolates
all OSC/termios/raw-mode complexity in ONE module so render.zig/capture.zig never touch
termios or the VT parser; makes the parse logic **deterministically testable** (no tty) so
CI can validate color decoding.

## Why

- **Foundation of the palette subsystem (PRD §6).** `Colors` + `defaultColors()` + the
  resolve inputs (`live` via `queryColors`, `default` via `defaultColors`) are consumed by
  T1.S2 (cache I/O), T1.S3 (resolve precedence), the `sync-palette` body, and the renderer.
- **Faithful absorption of term2html's verified flow.** `render_pipeline.md §2` documents the
  exact `terminal.zig::queryColors`: `/dev/tty` raw mode, OSC-4 batches of 32 + OSC 10/11,
  500 ms `V.TIME` timeout, parse via `ghostty_vt.Parser`, extract `.color_operation.requests`.
  This task ports that code into `palette.zig`, renamed and adapted.
- **Isolates the two ghostty gotchas.** (a) the VT `Parser` ships with a `null` osc allocator
  so color ops are silently dropped unless wired; (b) the request `SegmentedList` is never freed
  by the parser — the consumer must `deinit` it. Both are documented verbatim below with the
  ghostty-source line evidence; getting either wrong = silent zero palette or a test leak.

## What

Create `src/palette.zig` exporting:
- `pub const Colors = struct { palette: [256]color.RGB, foreground: ?color.RGB, background: ?color.RGB, palette_received_count: u16 };`
- `pub fn defaultColors() Colors` — Ghostty bundled palette; `fg=color.default[7]`, `bg={41,44,51}`, `count=256`.
- `pub fn queryColors(allocator: std.mem.Allocator) !Colors` — opens `/dev/tty` read_write,
  raw termios (ICANON/ECHO off, `V.MIN=0`, `V.TIME=5`), restores on `defer`; sends OSC 4 in
  batches of 32 + OSC 10/11 on the final batch; reads responses (loop until `read`→0); feeds
  every byte through `ghostty_vt.Parser` (with `osc_parser.alloc = allocator`) and routes each
  `.osc_dispatch` to `applyOscCommand`. Warns if `palette_received_count < 256`.
- `pub fn applyOscCommand(colors: *Colors, cmd: ghostty_vt.osc.Command, allocator: std.mem.Allocator) void`
  — the **pure** decoder (no I/O): on `.color_operation`, iterate `.requests`; for `.set`:
  `.target.palette idx` → `colors.palette[idx] = color` + bump count; `.target.dynamic == .foreground`
  → `colors.foreground`; `.background` → `colors.background`; ignore `.special`, `.query`, `.reset*`.
  Then `op.requests.deinit(allocator)` (frees the SegmentedList — see Gotcha 2).

And add to `src/main.zig` one top-level `test` block so palette tests run under `zig build test`.

### Success Criteria

- [ ] `src/palette.zig` created with `Colors`/`defaultColors`/`queryColors`/`applyOscCommand` + tests.
- [ ] `src/main.zig` gains exactly one additive top-level `test { _ = @import("palette.zig"); }` block.
- [ ] `build.zig`, `build.zig.zon`, `src/cli.zig` UNCHANGED (`git diff --stat` → only main.zig + new palette.zig).
- [ ] `zig build test --release=fast` → 0 exit; palette tests pass; existing tests pass; no leaks.
- [ ] `applyOscCommand` decodes OSC 4/10/11 set-responses; ignores query/reset/non-color OSCs.
- [ ] `palette.zig` is the ONLY non-test file that `@import("ghostty-vt")` — cli.zig still does not.

## All Needed Context

### Context Completeness Check

_Pass: "If someone knew nothing about this codebase, would they have everything needed to
implement this successfully?"_ — Yes. Every ghostty_vt type path, function signature, enum
value, and both critical gotchas were read **line-by-line from the cached ghostty 1.3.1 +
Zig 0.15.2 std source** (see `research/findings.md` for line citations). The allocator-wiring
pattern (`p.osc_parser.alloc = allocator`) is copied from ghostty's own `Parser.zig` test
"osc: 112 incomplete sequence". The exact `RGB.parse("rgb:cc/00/00") → {204,0,0}` value is
derived from `color.zig::fromHex` (2-digit → `color*255/255`), so test assertions are correct.
The verbatim implementation of the three hard functions is in the Blueprint.

### Documentation & References

```yaml
# MUST READ — the verified term2html queryColors flow (the thing being absorbed)
- file: plan/001_0c8587f91cb2/architecture/render_pipeline.md
  section: "§2 Palette resolution (verified: term2html terminal.zig::queryColors)"
  why: "Authoritative flow: /dev/tty raw mode, OSC-4 batches of 32 + OSC 10/11, V.TIME=5 (500ms),
        feed bytes through ghostty_vt.Parser, extract color_operation.requests, warn if <256."
  critical: "This PRP turns §2 into compilable Zig against the real ghostty_vt API."

# MUST READ — the verified ghostty_vt + std API surface, line citations, and BOTH gotchas
- file: plan/001_0c8587f91cb2/P1M2T1S1/research/findings.md
  why: "Sections 1–11: module root (lib_vt.zig), color.RGB/Palette/default/Dynamic, Parser
        (init/next/osc_parser.alloc GOTCHA A), osc.Command/color_operation/Request/Target/
        ColoredTarget, request-list ownership (GOTCHA B), termios raw-mode API, OSC terminators,
        test-reachability fix, OSC query bytes, defaultColors."
  critical: "Gotcha A (parser.osc_parser.alloc MUST be set or color ops are dropped) + Gotcha B
             (op.requests.deinit(allocator) MUST be called or testing.allocator reports a leak)
             are the two failure modes. Both have source line evidence."

# MUST READ — the contract this task consumes + the lazy-ghostty build graph
- file: plan/001_0c8587f91cb2/P1M1T3S2/PRP.md
  why: "T3.S2 owns src/cli.zig (the parg parser) and LEAVES main.zig + build.zig byte-identical.
        This task adds palette.zig + a one-line main.zig test block; it must NOT touch cli.zig
        (parallel work) and must NOT change build.zig (ghostty-vt already a lazy import there)."
- file: build.zig
  why: "Confirms ghostty-vt is a LAZY dependency added to exe.root_module via addImport; palette.zig
        (relatively @imported from main.zig) inherits that named import — NO build change needed."

# MUST READ — PRD palette subsystem (cache + precedence this task feeds)
- file: PRD.md
  section: "§6 Palette subsystem + §5.4 sync-palette"
  why: "defaultColors() bg=41,44,51 (§6); live query only when a controlling tty exists, NEVER in
        run-shell (§6); sync-palette queries OSC 4/10/11 and exits non-zero on no response (§5.4)."

# Authoritative ghostty source (cached) — read to confirm any API doubt
- file: ~/.cache/zig/p/ghostty-1.3.1-5UdBCwYm-gQeBa4bu1-sMooCQS4KVriv5wWSIJ_sI-Cb/src/lib_vt.zig
  why: "Module root: re-exports color, osc, Parser."
- file: .../src/terminal/color.zig
  section: "RGB (line 400), Palette=[256]RGB (62), default (8), Dynamic enum (355), RGB.parse (541)"
  why: "RGB is packed struct(u24){r,g,b:u8}; default is [256]RGB; Dynamic.foreground/background."
- file: .../src/terminal/Parser.zig
  section: "init (222), next (251) returns [3]?Action, osc_dispatch (68), osc_parser field (~219),
            test 'osc: 112 incomplete sequence' (~898) = the allocator-wiring precedent"
  why: "p.osc_parser.alloc = allocator is REQUIRED (init passes null)."
- file: .../src/terminal/osc.zig
  section: "Command.color_operation (84), ensureAllocator (~445), reset (~395, color_operation=>{})"
  why: "Confirms color ops dropped without alloc + that requests are NEVER freed by the parser."
- file: .../src/terminal/osc/parsers/color.zig
  section: "List=SegmentedList(Request,2) (332), Request/Target/ColoredTarget (338-354),
            parseGetSetAnsiColor (176) shows OSC-4 -> .set.target.palette, RGB.parse(spec)"
  why: "The exact request shape applyOscCommand switches on."

# Zig 0.15.2 std (authoritative)
- file: /home/dustin/.local/opt/zig-x86_64-linux-0.15.2/lib/std/posix.zig
  section: "tcgetattr (6757), tcsetattr (6772), TCSA=.FLUSH (219), V=system.V (173),
            termios=system.termios (169), read (844)"
- file: /home/dustin/.local/opt/zig-x86_64-linux-0.15.2/lib/std/os/linux.zig
  section: "termios extern struct (7591), tc_lflag_t packed{ICANON,ECHO} (7398), V enum MIN/TIME (7512)"
- file: /home/dustin/.local/opt/zig-x86_64-linux-0.15.2/lib/std/fs.zig
  section: "openFileAbsolute (268)"
- file: /home/dustin/.local/opt/zig-x86_64-linux-0.15.2/lib/std/fs/File.zig
  section: "read (847), writeAll (975)"
- file: /home/dustin/.local/opt/zig-x86_64-linux-0.15.2/lib/std/segmented_list.zig
  section: "count (120), at -> *T (115), deinit (109), constIterator (388)"
```

### Current Codebase tree (this task's starting point)

```bash
tmux-2html/
├── build.zig            # T1.S2 (parg + build_options + LAZY ghostty-vt)         ← DO NOT TOUCH
├── build.zig.zon        # T1.S1 (ghostty 1.3.1 + parg)                            ← DO NOT TOUCH
├── src/
│   ├── main.zig         # T3.S1 dispatch + tests; test root                       ← ADD 1 test block
│   ├── cli.zig          # T3.S1/T3.S2 parg parser (PARALLEL WORK)                 ← DO NOT TOUCH
│   ├── ghostty_format.zig # T2.S1 vendored formatter                              ← DO NOT TOUCH
│   └── .gitkeep
├── LICENSE  licenses/  scripts/  testdata/  tmux-2html.tmux   # stubs (unchanged)
├── PRD.md  .gitignore  plan/
└── ~/.cache/zig/p/ holds ghostty-1.3.1-... + parg-0.0.0-...  (already fetched)
```

### Desired Codebase tree with files to be changed

```bash
tmux-2html/
├── src/
│   ├── palette.zig      # (NEW, this task) Colors + queryColors + applyOscCommand + tests
│   └── main.zig         # +1 additive top-level test block (palette test reachability)
└── build.zig  build.zig.zon  src/cli.zig   # UNCHANGED
```

### Known Gotchas of our codebase & Library Quirks

```zig
// GOTCHA 1 — CRITICAL: ghostty_vt.Parser.init() sets the inner osc_parser's allocator to
//   NULL (Parser.zig:235 `.osc_parser = .init(null)`). With alloc==null, color OSCs are
//   SILENTLY DROPPED: osc.zig::ensureAllocator sets state=.invalid and parsers/color.zig::parse
//   returns null. You MUST set it yourself after init:
//       var parser = ghostty_vt.Parser.init();
//       parser.osc_parser.alloc = allocator;   // osc_parser is a PUBLIC field
//   Precedent: ghostty's OWN Parser.zig test "osc: 112 incomplete sequence" does exactly
//   `p.osc_parser.alloc = std.testing.allocator;`. WITHOUT this, queryColors() gets ZERO
//   responses and palette_received_count stays 0 (terminal "not responding" false positive).

// GOTCHA 2 — CRITICAL (leak): osc.Parser.reset() handles `.color_operation => {}` (no-op) —
//   the parser NEVER frees the requests SegmentedList. Action.osc_dispatch COPIES the Command
//   (Parser.zig:271 `Action{ .osc_dispatch = cmd.* }`), so applyOscCommand's copy is the only
//   live owner of any heap segments. You MUST call `op.requests.deinit(allocator)` after
//   extracting colors, or std.testing.allocator fails the test with a leak. For ≤2 requests
//   it's a no-op (SegmentedList inline cap = 2); for ≥3 it frees the dynamic segment. One
//   deinit is correct — the parser's stale copy is overwritten on the next parse (no UAF).

// GOTCHA 3 — parser.next(c) returns [3]?Action. You MUST inspect all THREE slots, in order;
//   the osc_dispatch can land in slot [0] (exit action on the terminator byte). Feeding one
//   byte at a time, loop `for (actions) |maybe| if (maybe) |act| switch (act) { .osc_dispatch => ... }`.

// GOTCHA 4 — RGB is `packed struct(u24){r,g,b:u8}`. RGB literal: `.{ .r = 41, .g = 44, .b = 51 }`.
//   color.default is `[256]RGB`; color.default[7] is one RGB. Colors.palette is `[256]RGB` —
//   assignment from color.default is a direct array copy (256 × 3 bytes).

// GOTCHA 5 — CRITICAL: from THIS task, `zig build test` actually compiles ghostty-vt (palette.zig
//   imports it via the reachable test block). The Debug linker hits `R_X86_64_PC64` on ghostty's
//   static C++ SIMD objects. ALWAYS `--release=fast`. `zig build` (non-test) keeps ghostty lazy.

// GOTCHA 6 — termios: use `std.posix.tcgetattr/tcsetattr`, action `.FLUSH` (TCSA enum).
//   `raw.lflag.ICANON = false; raw.lflag.ECHO = false;` (tc_lflag_t is a packed struct of bools).
//   `raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;` and `V.TIME` = 5. V is arch-specific (x86_64:
//   MIN=6, TIME=5) — always use the enum names, never hardcode. MIN=0/TIME=5 ⇒ a read returns
//   after 500ms of silence OR as soon as ≥1 byte arrives; read()==0 ⇒ terminal stopped.

// GOTCHA 7 — ECHO is OFF, so the OSC query bytes you WRITE to /dev/tty are NOT echoed back into
//   your read buffer; you only read the terminal's RESPONSES. Do not try to "skip" your queries.

// GOTCHA 8 — Restore termios in a `defer` that ignores errors: the tty may be torn down first on
//   some paths. `defer std.posix.tcsetattr(tty.handle, .FLUSH, original) catch {};`

// GOTCHA 9 — NEVER call queryColors() from a tmux run-shell context (no controlling tty →
//   openFileAbsolute("/dev/tty") fails). The cache + resolve() (T1.S2/T1.S3) exist precisely so
//   the renderer never needs a tty. queryColors is for sync-palette + --palette live only.

// GOTCHA 10 — std.io.getStdOut() is GONE in 0.15.2 (inherited). Use std.fs.File.stdout()/.stderr()
//   for the warning (or std.log.warn). This module has no stdout output except a log warning.
```

## Implementation Blueprint

### Data models and structure

```zig
const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const color = ghostty_vt.color;
const osc = ghostty_vt.osc;

pub const Colors = struct {
    palette: [256]color.RGB,
    foreground: ?color.RGB,
    background: ?color.RGB,
    palette_received_count: u16,
};
```

### The exact deliverable: `src/palette.zig` (CREATE)

Create this file at `/home/dustin/projects/tmux-2html/src/palette.zig`. The four
hard-to-get-right functions are spelled out verbatim; the OSC-query read loop is
structured exactly as `render_pipeline.md §2` describes.

```zig
//! palette.zig — palette subsystem, lowest layer (PRD §6).
//!
//! Absorbs term2html's terminal.zig::queryColors (see architecture/render_pipeline.md §2):
//!  - Colors struct + defaultColors() (Ghostty bundled palette).
//!  - queryColors(): /dev/tty raw mode, OSC 4 batches of 32 + OSC 10/11, 500ms timeout,
//!    parsed through ghostty_vt.Parser.
//!  - applyOscCommand(): the PURE decoder (no I/O) — unit-tested against fixed byte streams.
//!
//! Consumers: palette.resolve() (T1.S3), sync-palette body (T2.S1), render --palette live
//! (P1.M3). NEVER call queryColors() from a tmux run-shell context (no tty).

const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const color = ghostty_vt.color;
const osc = ghostty_vt.osc;

/// The resolved palette handed to the renderer / written to the cache.
/// `palette_received_count < 256` ⇒ the terminal didn't answer every OSC 4 query.
pub const Colors = struct {
    palette: [256]color.RGB,
    foreground: ?color.RGB,
    background: ?color.RGB,
    palette_received_count: u16,
};

/// Last-resort defaults (PRD §6 precedence "default"): the Ghostty bundled 256-color
/// palette, foreground = palette[7], background = the fixed tmux-2html dark bg.
pub fn defaultColors() Colors {
    return .{
        .palette = ghostty_vt.color.default,
        .foreground = ghostty_vt.color.default[7],
        .background = .{ .r = 41, .g = 44, .b = 51 },
        .palette_received_count = 256,
    };
}

/// PURE decoder: apply one parsed OSC command to `colors`. No I/O. Safe to unit-test
/// against fixed byte streams (the test feeds bytes through ghostty_vt.Parser, then
/// calls this on each .osc_dispatch).
///
/// GOTCHA 2: the parser never frees color_operation.requests; we own the copy and MUST
/// deinit it here, or std.testing.allocator reports a leak.
pub fn applyOscCommand(colors: *Colors, cmd: osc.Command, allocator: std.mem.Allocator) void {
    switch (cmd) {
        .color_operation => |op| {
            var i: usize = 0;
            while (i < op.requests.count()) : (i += 1) {
                const req = op.requests.at(i).*;
                switch (req) {
                    .set => |ct| switch (ct.target) {
                        .palette => |idx| {
                            colors.palette[idx] = ct.color;
                            colors.palette_received_count += 1;
                        },
                        .dynamic => |d| switch (d) {
                            .foreground => colors.foreground = ct.color,
                            .background => colors.background = ct.color,
                            // cursor, pointer, highlight, tektronix — not tracked here.
                            else => {},
                        },
                        .special => {},
                    },
                    // query / reset / reset_palette / reset_special are responses to OUR
                    // queries or reset directives; a SET reply is the only thing that fills
                    // the palette. Ignore the rest.
                    else => {},
                }
            }
            op.requests.deinit(allocator); // GOTCHA 2: free the SegmentedList.
        },
        else => {},
    }
}

/// Feed a byte stream through the parser and route every .osc_dispatch to
/// applyOscCommand. Shared by queryColors (live) and the unit tests (fixed bytes).
fn feedAndApply(parser: *ghostty_vt.Parser, bytes: []const u8, colors: *Colors, allocator: std.mem.Allocator) void {
    for (bytes) |c| {
        const actions = parser.next(c); // [3]?Action — GOTCHA 3: inspect all slots.
        for (actions) |maybe_act| {
            if (maybe_act) |act| switch (act) {
                .osc_dispatch => |cmd| applyOscCommand(colors, cmd, allocator),
                else => {},
            };
        }
    }
}

/// Query the controlling terminal for its 256-color palette (OSC 4) + fg/bg (OSC 10/11).
/// Opens /dev/tty, switches to raw mode with a 500ms read timeout, sends queries in
/// batches of 32, reads replies through the VT parser. Returns Colors; if fewer than
/// 256 palette entries were received, logs a warning (terminal not responding).
///
/// Errors out if /dev/tty can't be opened or termios can't be set — the caller
/// (sync-palette / --palette live) must only invoke this when a controlling tty exists.
pub fn queryColors(allocator: std.mem.Allocator) !Colors {
    var colors = defaultColors();
    colors.palette_received_count = 0;

    var tty = try std.fs.openFileAbsolute("/dev/tty", .{ .mode = .read_write });
    defer tty.close();

    const original = try std.posix.tcgetattr(tty.handle); // GOTCHA 8: restore in defer.
    var raw = original;
    raw.lflag.ICANON = false; // GOTCHA 6
    raw.lflag.ECHO = false; // GOTCHA 7: no echo of our query bytes.
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 5; // 500ms (deciseconds).
    try std.posix.tcsetattr(tty.handle, .FLUSH, raw);
    defer std.posix.tcsetattr(tty.handle, .FLUSH, original) catch {};

    var parser = ghostty_vt.Parser.init();
    parser.osc_parser.alloc = allocator; // GOTCHA 1: REQUIRED or color OSCs are dropped.
    defer parser.deinit();

    var i: u16 = 0;
    while (i < 256) {
        const end: u16 = @min(i + 32, 256);
        var qbuf: [40]u8 = undefined;
        var idx = i;
        while (idx < end) : (idx += 1) {
            const q = std.fmt.bufPrint(&qbuf, "\x1b]4;{d};?\x07", .{idx}) catch unreachable;
            try tty.writeAll(q);
        }
        if (end == 256) {
            try tty.writeAll("\x1b]10;?\x07");
            try tty.writeAll("\x1b]11;?\x07");
        }
        try readAndFeed(&tty, &parser, &colors, allocator);
        i = end;
    }

    if (colors.palette_received_count < 256) {
        std.log.warn("palette: terminal responded with only {d}/256 palette entries", .{colors.palette_received_count});
    }
    return colors;
}

/// Read responses until a 500ms timeout (read()==0), feeding each byte through the parser.
fn readAndFeed(tty: *std.fs.File, parser: *ghostty_vt.Parser, colors: *Colors, allocator: std.mem.Allocator) !void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = tty.read(&buf) catch break; // read error ⇒ stop this batch.
        if (n == 0) break; // GOTCHA 6: 500ms timeout, no more data.
        feedAndApply(parser, buf[0..n], colors, allocator);
    }
}

// ---- Unit tests (NO /dev/tty) ------------------------------------------------
// queryColors is interactive-only; we unit-test defaultColors + the applyOscCommand
// decode logic by feeding fixed OSC byte streams through a real ghostty_vt.Parser.

fn newParser(allocator: std.mem.Allocator) ghostty_vt.Parser {
    var p = ghostty_vt.Parser.init();
    p.osc_parser.alloc = allocator; // GOTCHA 1
    return p;
}

test "defaultColors: bundled palette, fixed fg/bg, full count" {
    const c = defaultColors();
    try std.testing.expectEqual(@as(u16, 256), c.palette_received_count);
    // palette is the Ghostty bundled 256-color table.
    try std.testing.expectEqual(ghostty_vt.color.default, c.palette);
    // foreground = palette[7].
    try std.testing.expectEqual(ghostty_vt.color.default[7], c.foreground.?);
    // background = fixed 41,44,51.
    try std.testing.expectEqual(color.RGB{ .r = 41, .g = 44, .b = 51 }, c.background.?);
}

test "applyOscCommand: OSC 4 palette set (rgb:cc/00/00 -> idx 0 red)" {
    const alloc = std.testing.allocator;
    var colors = defaultColors();
    colors.palette_received_count = 0;
    var p = newParser(alloc);
    defer p.deinit();
    feedAndApply(&p, "\x1b]4;0;rgb:cc/00/00\x07", &colors, alloc);
    try std.testing.expectEqual(color.RGB{ .r = 204, .g = 0, .b = 0 }, colors.palette[0]);
    try std.testing.expectEqual(@as(u16, 1), colors.palette_received_count);
}

test "applyOscCommand: OSC 10 foreground + OSC 11 background" {
    const alloc = std.testing.allocator;
    var colors = defaultColors();
    var p = newParser(alloc);
    defer p.deinit();
    feedAndApply(&p, "\x1b]10;rgb:ff/ff/ff\x07", &colors, alloc);
    feedAndApply(&p, "\x1b]11;rgb:29/2c/33\x07", &colors, alloc);
    try std.testing.expectEqual(color.RGB{ .r = 255, .g = 255, .b = 255 }, colors.foreground.?);
    try std.testing.expectEqual(color.RGB{ .r = 41, .g = 44, .b = 51 }, colors.background.?);
}

test "applyOscCommand: non-color OSC is ignored (title)" {
    const alloc = std.testing.allocator;
    var before = defaultColors();
    var p = newParser(alloc);
    defer p.deinit();
    feedAndApply(&p, "\x1b]0;hello world\x07", &before, alloc);
    try std.testing.expectEqual(defaultColors().palette, before.palette);
    try std.testing.expectEqual(defaultColors().foreground, before.foreground);
    try std.testing.expectEqual(defaultColors().background, before.background);
}

test "applyOscCommand: query (?) sets nothing" {
    const alloc = std.testing.allocator;
    var colors = defaultColors();
    colors.palette_received_count = 0;
    var p = newParser(alloc);
    defer p.deinit();
    // A query (not a reply) decodes to Request.query — applyOscCommand ignores it.
    feedAndApply(&p, "\x1b]4;5;?\x07", &colors, alloc);
    try std.testing.expectEqual(@as(u16, 0), colors.palette_received_count);
}

test "applyOscCommand: batched palette set (3 indices -> exercises heap path)" {
    // 3 requests exceed SegmentedList inline capacity (2) -> heap alloc; deinit must free it.
    const alloc = std.testing.allocator;
    var colors = defaultColors();
    colors.palette_received_count = 0;
    var p = newParser(alloc);
    defer p.deinit();
    feedAndApply(&p, "\x1b]4;0;rgb:cc/00/00;1;rgb:00/cc/00;2;rgb:00/00/cc\x07", &colors, alloc);
    try std.testing.expectEqual(color.RGB{ .r = 204, .g = 0, .b = 0 }, colors.palette[0]);
    try std.testing.expectEqual(color.RGB{ .r = 0, .g = 204, .b = 0 }, colors.palette[1]);
    try std.testing.expectEqual(color.RGB{ .r = 0, .g = 0, .b = 204 }, colors.palette[2]);
    try std.testing.expectEqual(@as(u16, 3), colors.palette_received_count);
}

test "applyOscCommand: ST terminator (ESC \\) also works" {
    const alloc = std.testing.allocator;
    var colors = defaultColors();
    colors.palette_received_count = 0;
    var p = newParser(alloc);
    defer p.deinit();
    feedAndApply(&p, "\x1b]4;9;rgb:01/02/03\x1b\\", &colors, alloc);
    try std.testing.expectEqual(color.RGB{ .r = 1, .g = 2, .b = 3 }, colors.palette[9]);
}
```

### The exact deliverable: `src/main.zig` (MODIFY — add ONE block)

Add a single top-level `test` block to `src/main.zig` so `zig build test` reaches
palette.zig's tests. Place it near the existing tests (after `printHelp` / before the
existing `test` blocks is fine). **Do not change anything else in main.zig.**

```zig
test {
    // P1.M2: keep palette.zig tests reachable from the test root (src/main.zig).
    // A top-level test block is compiled ONLY in test mode, so ghostty-vt stays
    // LAZY for a normal `zig build` (no palette import on the exe path).
    _ = @import("palette.zig");
}
```

> Why no build.zig change: palette.zig is `@import`ed relatively from main.zig (the
> `exe.root_module` root), so it is part of `exe.root_module` and shares its named
> imports — including `ghostty-vt`, already registered by `build.zig`'s
> `exe.root_module.addImport("ghostty-vt", …)`. cli.zig already resolves `parg` /
> `build_options` the same way (T3.S1/T3.S2). Verified mechanism.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: CREATE src/palette.zig  (verbatim Blueprint above)
  - IMPORTS: std, ghostty-vt (color + osc + Parser via the module re-exports).
  - KEEP EXACT: Colors struct fields; defaultColors() (color.default, default[7], {41,44,51}, 256);
    applyOscCommand switch (color_operation -> requests -> set -> palette/dynamic, then deinit);
    feedAndApply (inspect all 3 action slots); queryColors (/dev/tty, raw termios, batches of 32,
    OSC 10/11 on final batch, readAndFeed loop, <256 warning); the 7 test blocks.
  - GOTCHA 1: parser.osc_parser.alloc = allocator AFTER init() (else zero palette).
  - GOTCHA 2: op.requests.deinit(allocator) in applyOscCommand (else test leak).
  - PLACEMENT: src/palette.zig (new file).

Task 2: MODIFY src/main.zig  (add ONE additive top-level test block)
  - ADD: the `test { _ = @import("palette.zig"); }` block above.
  - PRESERVE: all existing main.zig content (T3.S1 dispatch + tests). Touch NOTHING else.
  - DO NOT touch build.zig, build.zig.zon, src/cli.zig (PARALLEL WORK / already complete).

Task 3: VALIDATE  (see Validation Loop — all commands verified-working intent)
  - RUN: zig build test --release=fast      # palette tests + existing tests pass, no leaks
  - RUN: zig build --release=fast           # ghostty stays lazy (fast); exe builds
```

### Implementation Patterns & Key Details

```zig
// PATTERN: route a parsed command into Colors. The switch is exhaustive over the union
// variants we care about; everything else (query/reset/non-color OSC) is a no-op.
pub fn applyOscCommand(colors: *Colors, cmd: osc.Command, allocator: std.mem.Allocator) void {
    switch (cmd) {
        .color_operation => |op| {
            var i: usize = 0;
            while (i < op.requests.count()) : (i += 1) {
                const req = op.requests.at(i).*;   // SegmentedList.at -> *Request; .* derefs.
                switch (req) {
                    .set => |ct| switch (ct.target) {   // ct: ColoredTarget { target, color }
                        .palette => |idx| { colors.palette[idx] = ct.color; colors.palette_received_count += 1; },
                        .dynamic => |d| switch (d) { .foreground => colors.foreground = ct.color, .background => colors.background = ct.color, else => {} },
                        .special => {},
                    },
                    else => {},   // query / reset / reset_palette / reset_special
                }
            }
            op.requests.deinit(allocator);   // GOTCHA 2
        },
        else => {},
    }
}

// PATTERN: feed one byte at a time; next() returns [3]?Action (exit/transition/entry).
fn feedAndApply(parser: *ghostty_vt.Parser, bytes: []const u8, colors: *Colors, alloc: std.mem.Allocator) void {
    for (bytes) |c| {
        const actions = parser.next(c);
        for (actions) |maybe_act| if (maybe_act) |act| switch (act) {
            .osc_dispatch => |cmd| applyOscCommand(colors, cmd, alloc),
            else => {},
        };
    }
}

// PATTERN: raw termios + restore. FLUSH discards pending I/O before applying.
const original = try std.posix.tcgetattr(tty.handle);
var raw = original;
raw.lflag.ICANON = false;
raw.lflag.ECHO = false;
raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
raw.cc[@intFromEnum(std.posix.V.TIME)] = 5;
try std.posix.tcsetattr(tty.handle, .FLUSH, raw);
defer std.posix.tcsetattr(tty.handle, .FLUSH, original) catch {};

// PATTERN: OSC query bytes (BEL terminator). Batch palette indices 32 at a time.
//   \x1b]4;{idx};?\x07   (OSC 4 query)    \x1b]10;?\x07  (fg)   \x1b]11;?\x07  (bg)
```

### Integration Points

```yaml
BUILD GRAPH:
  - consumes (unchanged): build.zig (LAZY ghostty-vt via exe.root_module.addImport),
    build.zig.zon, src/main.zig (test root). src/cli.zig (PARALLEL — do not touch).
  - produces: src/palette.zig + 1 additive test block in src/main.zig.
  - next (P1.M2.T1.S2 cache I/O): reads/writes Colors from the XDG cache file.
  - next (P1.M2.T1.S3 resolve): palette.resolve(mode) returns Colors via cached → live
              (queryColors, only if tty) → default (defaultColors).
  - next (P1.M2.T2.S1 sync-palette body): cli.SyncPaletteOpts → queryColors/--from file → writeCache.
  - next (P1.M3 renderer): consumes Colors.palette/foreground/background for HTML color resolution.

CONFIG / ENV:
  - queryColors opens "/dev/tty" (no env). It MUST NOT run under tmux run-shell (no tty →
    openFileAbsolute fails → error). resolve() + cache are the tty-free path.

TEST DISCOVERY:
  - palette.zig tests run via the src/main.zig test-block import (Task 2). ghostty-vt compiles
    in test mode only; the exe stays ghostty-lazy.
```

## Validation Loop

> Re-run verbatim. EVERY build/test command MUST include `--release=fast` (Gotcha 5).

### Level 1: Syntax & Style (Immediate Feedback)

```bash
zig version            # MUST print: 0.15.2
zig build --fetch      # exit 0 (deps cached; instant)
```

### Level 2: Build + unit tests (PRIMARY gate)

```bash
# All palette tests + existing main/cli tests. No leaks (std.testing.allocator).
zig build test --release=fast          # expect: all passed, exit 0

# Exe still builds; ghostty stays LAZY on the non-test path (fast build).
zig build --release=fast               # expect: exit 0
ls -la zig-out/bin/tmux-2html          # expect: ELF binary exists

# If "unhandled relocation type R_X86_64_PC64" -> forgot --release=fast (Gotcha 5).
# If palette tests report "QueryResponseQuery..." or zero count -> forgot
#   parser.osc_parser.alloc = allocator (Gotcha 1).
# If testing.allocator reports a leak in applyOscCommand -> forgot op.requests.deinit (Gotcha 2).
```

### Level 3: Behavior (the contract — feed fixed bytes, assert colors)

```bash
# The unit tests ARE the Level-3 gate (no live tty in CI). They assert:
#   defaultColors().background == {41,44,51}; foreground == default[7]; palette == default; count==256
#   OSC 4  rgb:cc/00/00 -> palette[0]={204,0,0}, count=1
#   OSC 10 rgb:ff/ff/ff -> foreground;  OSC 11 rgb:29/2c/33 -> background
#   non-color OSC (title) -> Colors unchanged
#   query (?) -> nothing set
#   batched 3-set -> heap path + count=3 (leak check)
#   ST terminator (ESC \) -> works too
zig build test --release=fast -- 2>&1 | tail   # confirm palette test names appear + pass

# (Optional, interactive only — NOT in CI, requires a real controlling tty):
#   echo "run sync-palette in a terminal once T2.S1 lands" — queryColors is exercised end-to-end there.
```

### Level 4: Scope boundary (Domain Validation)

```bash
# ONLY main.zig changed + palette.zig added; build files + cli.zig untouched.
git diff --stat build.zig build.zig.zon src/cli.zig   # expect: no output (unchanged)
git diff --stat src/main.zig                          # expect: main.zig modified (1 block added)
git status --short src/palette.zig                    # expect: new untracked file

# ghostty stayed lazy for the exe (no palette import on the non-test path):
time zig build --release=fast 2>&1 | tail -1          # expect: well under a minute (cached)
```

## Final Validation Checklist

### Technical Validation

- [ ] `zig version` prints `0.15.2`; `zig build --fetch` exits 0.
- [ ] `zig build test --release=fast` exits 0 (palette tests + existing tests pass, no leaks).
- [ ] `zig build --release=fast` exits 0; `zig-out/bin/tmux-2html` produced.

### Feature Validation

- [ ] `defaultColors()` returns `color.default` palette, `foreground=color.default[7]`,
      `background=RGB{41,44,51}`, `palette_received_count=256`.
- [ ] `applyOscCommand` decodes OSC 4 palette sets (`rgb:cc/00/00`→{204,0,0}), OSC 10 fg,
      OSC 11 bg; ignores query/reset/non-color OSCs; handles ST and BEL terminators.
- [ ] Batched 3-set exercises the SegmentedList heap path with no leak (Gotcha 2).
- [ ] `queryColors` compiles (raw termios, OSC batches of 32, readAndFeed loop, <256 warning).

### Code Quality Validation

- [ ] `palette.zig` matches the Blueprint: `parser.osc_parser.alloc = allocator` (Gotcha 1);
      `op.requests.deinit(allocator)` in applyOscCommand (Gotcha 2); `next()` 3-slot loop.
- [ ] `src/main.zig` gains exactly ONE additive top-level `test` block; nothing else changed.
- [ ] `build.zig`, `build.zig.zon`, `src/cli.zig` unchanged.
- [ ] `palette.zig` is the only non-test file `@import("ghostty-vt")`.

### Documentation & Deployment

- [ ] No new env vars. The `<256` warning uses `std.log.warn` (no stdout clutter).
- [ ] Internal module — no user-facing docs (DOCS: none, per the item contract).

---

## Anti-Patterns to Avoid

- ❌ Don't forget `parser.osc_parser.alloc = allocator;` after `Parser.init()` — `init()` passes
  `null`, so every color OSC is silently dropped and you get a zero palette (Gotcha 1). The
  ghostty Parser test "osc: 112 incomplete sequence" sets it; mirror that.
- ❌ Don't skip `op.requests.deinit(allocator)` in applyOscCommand — `osc.Parser.reset()` does
  `=> {}` for color_operation, so the SegmentedList leaks; `std.testing.allocator` fails the
  test (Gotcha 2). Free it once (the Action copy owns the live reference).
- ❌ Don't inspect only `actions[0]` from `parser.next()` — up to 3 actions can be returned and
  the `osc_dispatch` may be in any slot; loop all three (Gotcha 3).
- ❌ Don't build/test WITHOUT `--release=fast` — palette.zig now compiles ghostty-vt in the test
  path, and Debug linking hits `R_X86_64_PC64` (Gotcha 5).
- ❌ Don't hardcode termios `MIN`/`TIME` indices — use `@intFromEnum(std.posix.V.MIN)` /
  `V.TIME` (arch-specific; Gotcha 6). Don't forget `ECHO=false` or you'll read your own queries
  back (Gotcha 7). Don't forget to restore termios in a `defer … catch {}` (Gotcha 8).
- ❌ Don't call `queryColors()` from tmux `run-shell` / any no-tty path — it opens `/dev/tty`,
  which fails. That's why the cache + `resolve()` exist (Gotcha 9, PRD §6).
- ❌ Don't modify `build.zig`, `build.zig.zon`, or `src/cli.zig` — ghostty-vt is already a lazy
  import on `exe.root_module` (palette.zig inherits it via the main.zig import); cli.zig is
  parallel work.
- ❌ Don't parse `rgb:` specs yourself — `ghostty_vt.osc` (via `RGB.parse`) already decodes the
  response into `Request{ .set = .{ .target, .color } }`. applyOscCommand just switches on it.
- ❌ Don't count `palette_received_count` on `.query`/`.reset` — only `.set.target.palette`.

---

**Confidence Score: 9/10** for one-pass implementation success.

Every `ghostty_vt` type path, function signature, enum value, and both critical gotchas were
read line-by-line from the cached ghostty 1.3.1 + Zig 0.15.2 std source (citations in
`research/findings.md`). The allocator-wiring pattern (`p.osc_parser.alloc = allocator`) is
copied from ghostty's own `Parser.zig` test. The exact `RGB.parse("rgb:cc/00/00") → {204,0,0}`
test value is derived from `color.zig::fromHex`, so assertions are correct by construction, not
guesses. The test-reachability fix (one main.zig test block) is verified to need no build change
because palette.zig inherits `exe.root_module`'s `ghostty-vt` named import via the relative
`@import` from main.zig. The only residual risk is interactive `/dev/tty` behavior, which is
deliberately excluded from CI (the contract says unit-test the decode logic against fixed byte
streams) — `queryColors` itself compiles and follows the verified term2html flow but is
exercised live only when `sync-palette` (T2.S1) lands.
