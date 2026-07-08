# Render Pipeline & Selection Model (VERIFIED from term2html + ghostty source)

> The core renderer is a direct adaptation of `aarol/term2html`'s `formatAnsi()` + the
> vendored `ghostty_format.zig`. This doc gives the EXACT verified code shape so downstream
> PRP agents can implement `render.zig` without guessing.

## 1. The pipeline (verified: term2html `src/main.zig::formatAnsi`)

```
stdin/ANSI bytes
   │
   ▼
ghostty_vt.Terminal.init(alloc, .{ .cols, .rows })   ← virtual terminal, EXPLICIT size
   │  var stream = t.vtStream()
   │  for each byte: '\n' → feed '\r' then '\n'; else feed byte     (stream.next(byte))
   ▼
t.screens.active  (*const Screen — the cell grid now holds all SGR/color/OSC-8 state)
   │
   ▼
ScreenFormatter.init(screen, Options{ emit=.html, background, foreground, palette=&pal, font })
   │  formatter.content = .{ .selection = null }      ← null = WHOLE grid
   │     OR  .{ .selection = some_sel }               ← sub-grid (inclusive)
   │  formatter.extra = .styles                        ← emit <style>/inline CSS
   ▼
print("{f}", .{formatter})  →  stdout / --output file
```

**Critical size rule (PRD §2.3):** the virtual terminal MUST be sized to the pane's actual
cols/rows (read from `#{pane_width}`/`#{pane_height}`). Defaulting to 80×150 mis-wraps wide
panes. For `render` subcommand, `--cols` is REQUIRED when there's no tty (or = pane width).

## 2. Palette resolution (verified: term2html `src/terminal.zig::queryColors`)

```zig
pub const Colors = struct {
    palette: [256]ghostty_vt.color.RGB,
    foreground: ?ghostty_vt.color.RGB,
    background: ?ghostty_vt.color.RGB,
    palette_received_count: u16,
};
```
`queryColors()`:
1. Open `/dev/tty` read_write (`std.fs.openFileAbsolute("/dev/tty", .{.mode=.read_write})`).
2. `std.posix.tcgetattr(fd)`; set raw: `raw.lflag.ICANON=false; raw.lflag.ECHO=false;`
   `raw.cc[V.MIN]=0; raw.cc[V.TIME]=5;` (500ms read timeout — macOS can't poll /dev/tty).
   `std.posix.tcsetattr(fd, .FLUSH, raw)`; restore in `defer`.
3. Query in batches of 32: write `\x1b]4;{idx};?\x07` for idx in batch. On final batch also
   `\x1b]10;?\x07\x1b]11;?\x07` (fg/bg).
4. Read responses into a buffer; feed each byte through `ghostty_vt.Parser`; on
   `action.osc_dispatch`, `applyOscCommand` extracts `.color_operation.requests` → fills
   `palette[idx]` (`.set.target == .palette`), `.foreground` (`.dynamic == .foreground`),
   `.background` (`.dynamic == .background`).
5. Returns `Colors`. `palette_received_count < 256` → warn (terminal not responding).

**tmux-2html additions to term2html's palette flow (PRD §6):**
- `sync-palette` subcommand runs `queryColors()` then WRITES the cache file.
- Cache path: `${XDG_CACHE_HOME:-$HOME/.cache}/tmux-2html/palette`.
- Cache format (plain text):
  ```
  # tmux-2html palette (queried <iso8601>)
  fg 255 255 255
  bg 41 44 51
  0 0 0 0
  1 204 66 66
  … (0..255)
  255 238 238 238
  ```
- Precedence for rendering (`--palette` overrides): cached → live (only if tty) → default
  (`ghostty_vt.color.default` palette; fg=palette[7], bg=palette[0] OR fixed 41,44,51).
- **Never** call `queryColors()` from a `run-shell` context (no tty) — that's why the cache
  exists. `live` is only attempted by an interactive CLI / inside the display-popup pty.

## 3. getSize / explicit geometry (verified: term2html `src/terminal.zig::getSize`)

```zig
pub const WindowSize = struct { cols: u16, rows: u16 };
pub fn getSize() !WindowSize {
    var tty = try std.fs.openFileAbsolute("/dev/tty", .{.mode=.read_only});
    defer tty.close();
    var ws: std.posix.winsize = undefined;
    const rc = std.posix.system.ioctl(tty.handle, std.posix.system.T.IOCGWINSZ, @intFromPtr(&ws));
    if (rc == -1) return error.IoctlFailed;
    if (ws.col == 0 or ws.row == 0) return error.InvalidWindowSize;
    return .{ .cols = ws.col, .rows = ws.row };
}
```
Note: `T.IOCGWINSZ` (the constant is under `std.posix.system.T`), and `std.posix.winsize`.
**In tmux bindings there is NO tty** → `getSize()` fails → so `pane`/`region` subcommands
must get cols/rows from `tmux display-message -p '#{pane_width}' '#{pane_height}'` (or pass
them explicitly). `render` requires `--cols`.

## 4. Selection → formatter (the region feature; the key integration)

**Problem (PRD oversimplification, corrected in findings_and_corrections.md §0.2):**
`Selection` is Pin-based, not coordinate-based. Pipeline for `--selection X1,Y1,X2,Y2[,rect]`
and the region TUI:

1. Build the Terminal + Screen exactly as §1 (feed full ANSI into `cols×rows` grid).
2. Convert the user's coordinates into `Pin`s on `t.screens.active`. **VERIFIED API**
   (ghostty `PageList.zig` + `point.zig`):
   ```zig
   const point = @import("ghostty-vt").point;
   const PageList = @import("ghostty-vt").page.PageList;
   const Pin = PageList.Pin;
   const Selection = @import("ghostty-vt").Selection;

   // point.Point wraps a coordinate; pt.coord() returns {x, y}.
   // VERIFIED: PageList.pin(pt: point.Point) ?Pin  (returns null if x >= cols)
   const start_pin: Pin = screen.pages.pin(start_pt) orelse return error.OutOfRange;
   const end_pin:   Pin = screen.pages.pin(end_pt)   orelse return error.OutOfRange;
   var sel = Selection.init(start_pin, end_pin, rect);
   defer sel.deinit(...);   // VERIFY deinit signature (takes allocator/pages) against Selection.zig
   ```
   **VERIFY at impl time (small):** how to construct a `point.Point` from (x,y) — read
   ghostty `point.zig` (exports `point.Point`, `point.Coordinate`; `pt.coord()` returns
   `{.x,.y}`). Likely `point.Point{ ... }` with a coordinate or a tag. `Selection.init` is
   verified (`init(start_pin, end_pin, rect)` → sets `.rectangle`). `PageList.pin` is
   verified (line 4145). `pointFromPin(tag, pin)` is the inverse (line 4250).
3. Set `formatter.content = .{ .selection = sel };` (note: NOT null here).
4. Print the formatter. Only cells within the selection (inclusive; rectangle-aware) are emitted.

**Linewise vs block mapping (PRD §7.4 — the coordinate translation):**
- Linewise selection from row r1..r2: `start_pin = screen.pages.pin(pt(x=0, y=r1))`,
  `end_pin = screen.pages.pin(pt(x=cols-1, y=r2))`, `rect=false`.
- Block selection (c1,r1)-(c2,r2): `start_pin = screen.pages.pin(pt(c1, r1))`,
  `end_pin = screen.pages.pin(pt(c2, r2))`, `rect=true`.
  (`pt(x,y)` = build a `point.Point` from coordinates; see impl note in §4 step 2.)
- Coordinates are cell indices in the LOADED grid (after scrollback capture). This is why
  tmux-2html owns its coordinate system (PRD §2.5) — no tmux copy-mode bridge.

## 5. Golden test harness (verified: term2html `src/main.zig::test "output matches testdata"`)

term2html's test is in `main.zig` itself:
```zig
test "output matches testdata" {
    const tests = [_][]const u8{ "hyperfine", "fastfetch", "hyperlink" };
    inline for (tests) |testname| {
        const size = terminal.WindowSize{ .cols = 120, .rows = 150 };
        const colors = defaultColors();            // ghostty_vt.color.default + fixed fg/bg
        // read testdata/<name>.ansi, run formatAnsi into a fixed buffer,
        // read testdata/<name>.html, expectEqualStrings.
    }
}
```
tmux-2html EXTENDS this with **selection sub-rectangle** goldens: take a `.ansi`, render with
`content.selection = <fixed linewise/block sel>`, compare bytes. Put these under
`testdata/`. Also add unit tests for: selection math (line/block from anchor+cursor), palette
parse/serialize, capture-line-range→`-S/-E` derivation, option parsing.

## 6. Files tmux-2html vendors / adapts from term2html

| tmux-2html file | Provenance | Changes |
|---|---|---|
| `src/render.zig` | term2html `main.zig::formatAnsi` + `ghostty_format.zig` | add `--selection`, `--font`, palette-precedence, output-file/open |
| `src/ghostty_format.zig` | term2html `ghostty_format.zig` (vendored) | keep as-is (it already has `font`); MIT notice retained |
| `src/terminal.zig` → `src/palette.zig` | term2html `terminal.zig::queryColors` | rename; add cache read/write; keep OSC query verbatim |
| `src/terminal.zig::getSize` | (inlined into capture.zig or main) | used only for interactive render; pane path uses tmux formats |
| `testdata/*.ansi` | term2html fixtures | reuse + add selection goldens |

## 7. Output fidelity handled entirely by ghostty-vt (no bespoke ANSI parser)

- 16-color: palette lookup → RGB. 256-color, truecolor: exact RGB. Attributes
  (bold/italic/underline/strikethrough/reverse): SGR → inline CSS. OSC 8 hyperlinks → `<a>`.
- Wide chars / grapheme clusters / emoji: ghostty cell widths. Selection rounds to cell
  boundaries (wide cells atomic).
- HTML uses inline styles (RGB) + CSS variables (`var(--vt-palette-N)`) for palette indices;
  the palette is emitted by the formatter's `extra`. The vendored `ghostty_format.zig` is
  already tuned for "idiomatic HTML". Do not re-implement.
