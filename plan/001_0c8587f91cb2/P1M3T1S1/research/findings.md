# Research findings — P1.M3.T1.S1: renderGrid() core pipeline + render subcommand

> **Authority:** All API signatures below were read directly from the **ghostty v1.3.1
> source** at `~/.cache/zig/p/ghostty-1.3.1-…/src/` and the **Zig 0.15.2 stdlib** at
> `~/.local/opt/zig-x86_64-linux-0.15.2/lib/std/`. The new-IO writer pipeline was
> **compile-validated** (`zig run` + `zig test`) in a throwaway program — see §3.

## 1. The verified renderGrid pipeline (ghostty v1.3.1 + vendored ghostty_format.zig)

```
ansi bytes
  │  var t = try Terminal.init(alloc, .{ .cols, .rows });  defer t.deinit(alloc);
  │  var stream = t.vtStream();                            defer stream.deinit();
  │  for (ansi) |c| { if (c=='\n') stream.next('\r'); stream.next(c); }   // \n -> \r\n
  ▼
t.screens.active   // *const Screen
  │  var f = ScreenFormatter.init(t.screens.active, .{ .emit=.html, .background, .foreground, .palette=&colors.palette, .font });
  │  f.content = .{ .selection = sel };   // null = WHOLE grid; some(sel) = sub-grid (S4)
  │  f.extra = .styles;                   // per-cell <span> styles + <a> hyperlinks
  ▼
out.print("{f}", .{f});   // out: *std.Io.Writer — emits <pre class="term2html-output" …>…</pre>
```

Source locations (ghostty-1.3.1):
- `Terminal.init(alloc, Options{ cols, rows, … })` → `src/terminal/Terminal.zig:219`. Options struct `:208` (`cols: size.CellCountInt`, `rows`, defaults). `vtStream() :264` → `ReadonlyStream`.
- `ReadonlyStream` = `stream.Stream(Handler)` from `src/terminal/stream_readonly.zig:20`.
- `stream.next(c: u8) !void` → `src/terminal/stream.zig:578` (feed ONE byte). `nextSlice([]const u8)` at `:467` (SIMD batch; not used here — we need per-byte `\n`→`\r\n`).
- `color.Palette = [256]RGB` → `src/terminal/color.zig:48`. `color.default: Palette` at `:8`. **So `&colors.palette` (where `colors.palette: [256]color.RGB`) IS a `*const color.Palette`.**
- `size.CellCountInt = u16` → `src/terminal/size.zig:22`. **Render-local `Size{cols,rows: u16}` matches Terminal.Options exactly.**
- `Selection.init(start_pin, end_pin, rect: bool)` → `src/terminal/Selection.zig:55`, sets `.rectangle`. `sel: null` ⇒ formatter emits whole grid (ScreenFormatter.Content = `{ none, selection: ?Selection }`).
- `ScreenFormatter.init(screen: *const Screen, opts)` + `.content` + `.extra` + `format(writer: *std.Io.Writer)` → vendored `src/ghostty_format.zig` (already in tree, has `font`).

## 2. Options / Colors mapping (the ONE type bridge)

`palette.Colors` (src/palette.zig, already implemented in P1.M2.T1.S1):
```zig
pub const Colors = struct {
    palette: [256]color.RGB,            // == color.Palette
    foreground: ?color.RGB,
    background: ?color.RGB,
    palette_received_count: u16,
};
pub fn defaultColors() Colors;          // Ghostty bundled palette, fg=palette[7], bg={41,44,51}
```
→ maps to `ghostty_format.Options`:
```zig
.{ .emit = .html,
   .background = colors.background,      // ?color.RGB  (Options.background is ?color.RGB ✓)
   .foreground = colors.foreground,      // ?color.RGB
   .palette    = &colors.palette,        // *const [256]RGB coerces to ?*const color.Palette ✓
   .font       = font,                   // ?[]const u8
}
```
Because `opts.palette` is set, palette colors emit as **inline RGB `#rrggbb`** (HtmlFormatter.formatColor
with palette present) — output is **self-contained**, NO `:root{--vt-palette-N}` CSS block needed.
That block is only emitted by `TerminalFormatter` (NOT used). We use `ScreenFormatter` directly.

## 3. NEW-IO WRITER — the critical gotcha (COMPILE-VALIDATED)

ghostty_format's `ScreenFormatter.format` takes `writer: *std.Io.Writer` (the **new** Zig 0.15 IO type,
`std.Io.Writer`, with vtable + buffer). The rest of this codebase (main.zig/cli.zig) uses the OLD
`file.writeAll`. The bridge:

**stdout (render subcommand):**
```zig
var out_file = std.fs.File.stdout();
var buf: [4096]u8 = undefined;
var fw = out_file.writer(&buf);          // returns fs.File.Writer (File.zig:1552), NOT std.Io.Writer!
defer fw.interface.flush() catch {};     // the std.Io.Writer lives in fw.interface
try renderGrid(alloc, ansi, size, colors, null, font, &fw.interface);  // pass &fw.interface
```
- `file.writer(buffer) → fs.File.Writer` (File.zig:2120). `fs.File.Writer` is a WRAPPER struct whose
  `.interface: std.Io.Writer` field (File.zig:1563) is the thing the formatter wants. **Pass `&fw.interface`,
  flush `fw.interface`.** ✅ validated by `zig run`.
- `std.Io.Writer.print(comptime fmt, args) Error!void` (Writer.zig:593), `.flush()` (:309), `.writeAll` (:530).
  `{f}` invokes a struct's `format(writer: *std.Io.Writer)` method (the 0.15 formattable contract). ✅

**test capture (renderGrid unit tests):**
```zig
var aw = try std.Io.Writer.Allocating.initCapacity(alloc, 4096);
defer aw.deinit();
try renderGrid(alloc, ansi, size, colors, null, "monospace", &aw.writer);
const html = aw.writer.buffered();        // written bytes (Allocating.flush is noop; drain appends)
```
- `std.Io.Writer.Allocating` (Writer.zig:~2530): `.initCapacity(alloc, n)`, field `.writer: std.Io.Writer`,
  `.deinit()`, `.buffered()` returns `writer.buffer[0..writer.end]`. ✅ validated by `zig test` (1/1 passed).
  `.toOwnedSlice()` / `.toArrayList()` also available for owned output.

## 4. stdin read

`std.fs.File.stdin().readToEndAlloc(alloc, max_bytes) → ![]u8` (File.zig:809). Already used in palette.zig
(`f.readToEndAlloc(allocator, 1 << 20)`). For stdin use a generous cap (e.g. `1 << 28` ≈ 256 MiB) or the
PRD scrollback cap; caller frees. No tty interaction here — `render` is pure stdin→stdout.

## 5. Output shape (what "valid HTML" means here)

`ScreenFormatter` → `PageListFormatter` → `PageFormatter.formatWithState` HTML branch emits:
```
<pre class="term2html-output" style="max-width: Nch; background-color:#rrggbb; color:#rrggbb; font-family: <font>;">
  …per-cell <span style="color:#rrggbb;background-color:#…;font-weight:bold;…">text</span>…
  …<a style="color: inherit;" href="URI">linktext</a>…   (OSC 8)
</pre>
```
This is a **self-contained `<pre>` fragment** (term2html goldens compare exactly this fragment — NOT a full
`<html><body>` document). For S1 piping (`printf … | tmux-2html render --cols 40`) a fragment IS valid HTML
and matches term2html's contract. Trailing blank rows are trimmed (`Options.trim = true` default). No full-doc
wrapper is required by the PRD §8 contract for the `render` subcommand.

`\033[31m` (SGR fg palette idx 1) + `opts.palette` set → `<span style="color:#<palette[1]>">red</span>`.
For defaultColors(), palette[1] is the Ghostty bundled red — **do NOT hardcode the hex** in tests; assert a
`<span style="...color:#....">` wrapping `red`.

## 6. Scope boundaries (RESPECT sibling subtasks — do NOT implement these)

- **S2** owns: smart sizing defaults (rows = input line count), `--cols` required-if-no-tty validation,
  `--output FILE`, `--open` (xdg-open), and `--font` as a fully-featured flag. → S1 only PASSES `opts.font`
  through and uses a minimal cols/rows fallback.
- **S3** owns: `--palette MODE` → `palette.resolve(alloc, mode, has_tty)`. → S1 calls `palette.defaultColors()` only.
- **S4** owns: `--selection X1,Y1,X2,Y2[,rect]` coordinate→Pin→Selection. → S1 always passes `sel: null`.

S1's render body uses a **minimal fallback size** (`opts.cols orelse 80`, `opts.rows orelse 24`) — deliberately
temporary; S2 refines. The formatter trims trailing blank rows so rows=24 with 1 line of content stays compact.

## 7. Wiring cli.render → render.run (circular import is OK in Zig)

Currently `cli.render` parses opts then returns `error.NotImplemented` (cli.zig). S1 wires:
- `render.zig`: `pub fn run(alloc, opts: cli.RenderOpts) !u8` — reads stdin, defaultColors(), renderGrid→stdout.
  `render.zig` does `const cli = @import("cli.zig");` (for the RenderOpts type) + `const palette = @import("palette.zig");`
  + `const ghostty_vt = @import("ghostty-vt");` + `const fmt = @import("ghostty_format.zig");`.
- `cli.zig`: `const render = @import("render.zig");`; in `pub fn render(...)` after a successful `parseRender`,
  call `return render.run(allocator, opts);` (instead of `_ = opts; return error.NotImplemented;`).
- **Circular import (cli↔render) is fine** in Zig (lazy module resolution). The P1.M2 principle "cli must stay
  ghostty-free" means cli's PARSE functions never reference ghostty types — importing render.zig at module top
  does not violate that (the parse fns stay pure/unit-testable).
- **Effect on lazy ghostty dep:** once `render` is wired, the EXE path imports ghostty (via render), so
  `zig build` now compiles ghostty into the binary (expected — this is P1.M3's whole point). Tests already pull
  ghostty via palette.zig's test block in main.zig.

## 8. Test that MUST be updated in main.zig

`main.zig` has:
```zig
test "dispatch routes known subcommand to cli stub" {
    try std.testing.expectError(error.NotImplemented, dispatch(allocator, "render", &.{}));
    try std.testing.expectError(error.NotImplemented, dispatch(allocator, "sync-palette", &.{}));
}
```
After S1, `dispatch("render")` NO LONGER returns NotImplemented (it runs render, which reads stdin). Drop the
`render` assertion from this test (keep whatever sibling subcommands are still NotImplemented at impl time —
note sync-palette may be done in parallel by P1.M2.T2.S1). Do NOT invoke real dispatch("render") in a unit test
(it would read the test process's stdin). Test the render body through `renderGrid` + Allocating writer, not via main dispatch.

## 9. Validation commands (verified in THIS repo)

- `zig build` (exe now compiles ghostty-vt into the binary).
- `zig build test` (renderGrid unit tests + existing palette/cli tests).
- `printf '\033[31mred\033[0m' | zig build run -- render --cols 40` → emits `<pre class="term2html-output" …><span style="…color:#…">red</span></pre>`.
- `printf '\033[1mbold\033[0m' | ./zig-out/bin/tmux-2html render --cols 40` → `<span style="…font-weight:bold;">bold</span>`.
