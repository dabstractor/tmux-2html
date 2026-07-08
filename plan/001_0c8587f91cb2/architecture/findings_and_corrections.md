# Architecture Findings & PRD Corrections (VERIFIED from source)

> **Authority note:** This document is the source of truth for downstream PRP agents. It
> was produced by **directly reading the actual source code** of `aarol/term2html` and
> `ghostty-org/ghostty` (fetched 2026-07-08), NOT from training-knowledge guesses. Where it
> contradicts a PRD claim, this document wins. The four `research_*.md` briefs were written
> offline by subagents and are **superseded** by this file.

## 0. Critical corrections to the PRD (READ FIRST)

The PRD is broadly accurate but contains these inaccuracies / oversimplifications that
MUST be fixed during implementation:

1. **Module import name is `ghostty-vt` (HYPHEN), not `ghostty_vt` (underscore).**
   - PRD §3/§8 imply `ghostty_vt.Terminal`. The actual Zig import is `@import("ghostty-vt")`.
   - term2html aliases it locally: `const ghostty_vt = @import("ghostty-vt");` (so source
     reads `ghostty_vt.Terminal`, but the import string is `ghostty-vt`).
   - In `build.zig`: `exe.root_module.addImport("ghostty-vt", dep.module("ghostty-vt"));`
   - **Action:** every Zig file uses `@import("ghostty-vt")`. The build wires `dep.module("ghostty-vt")`.

2. **`Selection` is NOT constructed from raw x/y tuples.** It uses `Pin` objects.
   - PRD §2.4 / §7.4 claim `Selection{ start=(0,r1), end=(cols-1,r2), rect=false }`.
   - Reality (verified `Selection.zig`): `Selection.init(start_pin, end_pin, rect)` where
     `start_pin`/`end_pin` are `PageList.Pin` values, NOT coordinates.
   - `rectangle: bool` field (not `rect`).
   - To build a selection from (x,y) coordinates you must convert coordinates → `Pin`
     via the screen's `PageList` API (see §3 below). This is a real implementation task
     that the PRD under-scopes. The `--selection X1,Y1,X2,Y2[,rect]` CLI must do this
     coordinate→Pin translation before handing a `Selection` to the formatter.

3. **`ScreenFormatter.Content` is a union `{ none, selection: ?Selection }`.**
   - PRD §8 says "set `content.selection`". Exact: `formatter.content = .{ .selection = null };`
     for whole grid, or `.{ .selection = some_selection }` for a sub-grid.
   - `ScreenFormatter.init(screen, opts)` takes a `*const Screen` (= `t.screens.active`),
     NOT a `*Terminal`. (`TerminalFormatter` takes the terminal; `ScreenFormatter` takes a screen.)

4. **`font` is term2html's custom addition to `Options`, not a stock ghostty field.**
   - term2html's `ghostty_format.zig` is a **modified vendored copy** of ghostty's
     `formatter.zig` (it adds `font: ?[]const u8` to `Options` and "more idiomatic HTML").
   - tmux-2html must **vendor its own modified copy** of `ghostty_format.zig` (do NOT
     import the formatter from ghostty directly — ghostty's stock formatter has no `font`).
   - This matches PRD §8 "absorbs term2html's approach (src/ghostty_format.zig)". Good.

5. **ghostty version pinned is v1.3.1** (not "latest"). URL/hash verified (see external_deps.md).

6. **The `--selection` render flag exists in ghostty's formatter natively** but the
   `Selection` requires Pin construction — so tmux-2html's `render --selection` and the
   region TUI both reduce to: build Screen → convert user coords to Pins → `Selection.init`
   → `content.selection` → print formatter.

## 1. Project reality

- **Greenfield repo.** Only `PRD.md` + `plan/` exist. No `src/`, no `build.zig`. Everything
  is to be created.
- **`aarol/term2html` is the upstream to absorb.** MIT license (© 2024 Mitchell Hashimoto
  for the formatter code; the term2html glue © aarol). Its `minimum_zig_version = "0.15.2"`
  — **confirms Zig 0.15.2 is real and is the target.**
- **term2html source layout (verified):** `src/main.zig`, `src/ghostty_format.zig`,
  `src/terminal.zig`, `build.zig`, `build.zig.zon`, `testdata/{hyperfine,fastfetch,hyperlink}.{ansi,html}`,
  `.github/workflows/build-binaries.yml`, `LICENSE`, `README.md`.

## 2. Verified ghostty-vt API surface (what tmux-2html imports)

From `@import("ghostty-vt")`, these are re-exported (per term2html's `ghostty_format.zig`):
```
color          // color.RGB, color.Palette, color.default
size           // Size type
kitty          // kitty graphics
modespkg       // terminal modes
Screen         // ghostty's Screen type (a screen is a cell grid)
Terminal       // the VT terminal emulator
page.Cell      // a single cell
page.Page      // a page of cells
page.PageList  // the page list (holds rows); PageList.Pin = position handle
page.Row       // a row of cells
point.Coordinate // a coordinate type
Selection      // selection model (Pin-based)
Style          // text style (SGR attributes)
Parser         // the low-level VT parser (used to parse OSC responses in queryColors)
osc.Command    // parsed OSC command
```

### 2.1 `ghostty_vt.Terminal` — the VT emulator (verified from main.zig)
```zig
var t: ghostty_vt.Terminal = try .init(allocator, .{ .cols = cols, .rows = rows });
defer t.deinit(allocator);

// VT stream feeds bytes and mutates the terminal's screen state
var stream = t.vtStream();       // returns a stream object
defer stream.deinit();
stream.next(byte);               // feed one byte at a time
// IMPORTANT: translate '\n' -> '\r\n' (feed '\r' then '\n'); matches tmux capture output

t.screens.active   // *const Screen — the active screen to format
```

### 2.2 `ScreenFormatter` — HTML emitter (verified from formatter.zig + term2html)
```zig
// term2html's ghostty_format.zig:
pub const ScreenFormatter = struct {
    screen: *const Screen,
    opts: Options,
    content: Content,
    extra: Extra,
    pin_map: ?PinMap,

    pub const Content = union(enum) {
        none,                          // only terminal state, no cell text
        selection: ?Selection,         // null = whole grid; some(sel) = sub-grid (inclusive)
    };
    pub const Extra = packed struct { cursor: bool, /* ... styles etc */ };
};
// .init takes (screen, opts); then set .content and .extra; print with "{f}".
```

### 2.3 `Options` (term2html-modified; note `font`)
```zig
pub const Options = struct {
    emit: Format,              // .plain | .vt | .html
    unwrap: bool = false,      // unwrap soft-wrapped lines
    trim: bool = true,         // trim trailing whitespace
    codepoint_map: ?std.MultiArrayList(CodepointMap) = .{},
    background: ?color.RGB = null,
    foreground: ?color.RGB = null,
    palette: ?*const color.Palette = null,
    font: ?[]const u8,         // <-- term2html's custom addition (CSS font-family)
};
```

### 2.4 `Selection` — the selection model (verified from Selection.zig)
```zig
const PageList = @import("ghostty-vt").page.PageList;
const Pin = PageList.Pin;
const Selection = @import("ghostty-vt").Selection;

// Fields:
//   bounds: Bounds    // untracked{start:Pin,end:Pin} | tracked{start:*Pin,end:*Pin}
//   rectangle: bool   // default false
//
// Constructor:
pub fn init(start_pin: Pin, end_pin: Pin, rect: bool) Selection
// start/end can be in ANY order; use topLeft()/order(screen) to normalize.
// Inclusive on both ends when fed to the formatter.
```
**OPEN DETAIL (verify during impl):** how to convert a (x=col, y=row) into a `Pin` on the
loaded screen. Likely `screen.pages.getPin(x, y)` or `screen.pages.getPin(.{ .x = x, .y = y })`.
The `page.PageList` API exposes Pin construction. Downstream agents MUST read ghostty's
`PageList.zig` / `Screen.zig` to find the exact `getPin`/pin-from-coordinate call before
implementing selection. See `render_pipeline.md` §4.

## 3. tmux integration facts (verified)

- `tmux capture-pane -e -J -p -t <pane> -S -N -E -` → full scrollback to end, with escape
  sequences (SGR/OSC), joined wrapped lines, to stdout. `-S -` = `-S -<historylimit>`.
  Plain visible capture omits `-S`/`-E`.
- `#{pane_width}`, `#{pane_height}`, `#{pane_id}` resolve in bindings (run-shell expands formats).
- `run-shell` children have NO `/dev/tty`; `$TMUX` and `$TMUX_PANE` ARE set. OSC/termios
  queries fail there → palette must be cached (sync-palette runs in a real pty via
  display-popup, or interactively).
- `tmux display-popup -E -w 100% -h 100% "<cmd>"` opens a full-screen popup with a REAL
  controlling pty (OSC works). `-E` closes popup when cmd exits. Requires tmux ≥ 3.2 (actually
  display-popup landed in tmux 3.2; `-E` close-on-exit and `-w/-h 100%` supported since 3.2).
- tmux user options: `set-option -g @tmux-2html-foo "value"`; read via
  `tmux show-option -gqv @tmux-2html-foo` in the plugin script and shell.
- `C-o` is NOT a standard default tmux binding in the prefix table (tmux's default `O` is
  none; the PRD's "C-o bound to a debug display-message" refers to a *live* custom config in
  this user's environment, not a tmux shipping default). The PRD's override note stands.

## 4. Build / toolchain facts (verified)

- **Zig 0.15.2** is the pinned `minimum_zig_version` (term2html uses it; GHA uses
  `mlugg/setup-zig@v2` with `version: 0.15.2`). Build API uses the 0.15 `root_module` /
  `createModule` style (see `build.zig` in external_deps.md).
- **ghostty v1.3.1** + **parg** (judofyr/parg) are the deps (exact URLs/hashes in external_deps.md).
- `-Dsimd` option (default true). Cross-compile targets: `x86_64-linux-gnu`, `aarch64-linux-gnu`,
  `x86_64-macos`, `aarch64-macos`. Non-native SIMD builds use `-Dsimd=false` (term2html's
  matrix uses it for cross targets).
- term2html packages as `tar.gz`; tmux-2html PRD wants `tar.xz` + `SHA256SUMS.txt` (extension
  differs — minor).
- The Zig Debug-mode linker bug (`R_X86_64_PC64`) with bundled C++ SIMD libs is real per PRD
  §15; tests run in ReleaseFast.
