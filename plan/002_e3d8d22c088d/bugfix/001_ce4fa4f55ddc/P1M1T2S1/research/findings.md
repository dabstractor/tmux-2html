# Research Findings — P1.M1.T2.S1 (HTML-escape `--font` in `ghostty_format.zig`; Issue 2 XSS)

> Verified hands-on 2026-07-1x in a throwaway build (`/tmp/t2h-fontxss.*`) against the live
> repo. The fix + test were applied, built, and run end-to-end: PASS-after (326 tests green,
> exit 0) and FAIL-before (revert fix, keep test → `325/326, 1 failed` naming this test, exit 1).

## 1. The bug (confirmed: `src/ghostty_format.zig` lines 840-841)

```zig
// line 840 (unchanged by the fix — defines the default):
const font = self.opts.font orelse "monospace";
// line 841 (THE BUG — raw {s} interpolation into the double-quoted style attribute):
buf_writer.print("font-family: {s};", .{font}) catch return error.WriteFailed;
```
`font-family: {s}` bakes the user's `--font` value RAW into `<pre style="max-width: …; font-family: <RAW>; …">`.
A `"` in the value terminates the `style` attribute → arbitrary HTML-attribute injection
(e.g. `a" onmouseover="alert(1)` attaches a JS event handler). This is a stored-XSS vector in
output PRD §8.1 says must be "shareable and trustworthy in any browser".

**Font flow** (verified): `cli.zig opts.font` → `render.zig renderGrid(font: ?[]const u8)`
(:143) → `fmt.ScreenFormatter.init(t.screens.active, .{ …, .font = font })` (:170-ish) →
`self.opts.font` (:840) → unescaped emit (:841). All three subcommands (render/pane/region)
share `renderGrid`, so the fix at the emission point covers all three at once.

## 2. The fix (verbatim, exit-0 verified)

Replace the single line 841 with an inline per-byte HTML-escape loop. The escape set is copied
from the project's own `writeEscaped` (`src/render.zig:299`):

```zig
// ---- BEFORE (line 841, exact, unique) ----
                buf_writer.print("font-family: {s};", .{font}) catch return error.WriteFailed;
```
```zig
// ---- AFTER ----
                // Issue 2 (P1.M1.T2.S1): HTML-escape the font value into the double-quoted
                // style attribute. A raw " breaks out and allows attribute/event-handler
                // injection (stored-XSS) in the shared HTML (PRD §8.1 trust). Escape set
                // matches writeEscaped (render.zig). Single per-byte pass: each input byte
                // maps to one output, so no double-encoding. Default "monospace" is safe.
                buf_writer.writeAll("font-family: ") catch return error.WriteFailed;
                for (font) |c| switch (c) {
                    '"' => buf_writer.writeAll("&quot;") catch return error.WriteFailed,
                    '&' => buf_writer.writeAll("&amp;") catch return error.WriteFailed,
                    '<' => buf_writer.writeAll("&lt;") catch return error.WriteFailed,
                    '>' => buf_writer.writeAll("&gt;") catch return error.WriteFailed,
                    '\'' => buf_writer.writeAll("&#x27;") catch return error.WriteFailed,
                    else => buf_writer.writeByte(c) catch return error.WriteFailed,
                };
                buf_writer.writeAll(";") catch return error.WriteFailed;
```

`font` is `[]const u8` here (line 840 already unwrapped the optional with `orelse`), so
`for (font) |c|` iterates bytes. `buf_writer` (`stream.writer()` from `fixedBufferStream`)
exposes `.writeAll`/`.writeByte`/`.print` (confirmed by adjacent usage at :831/:836/:842). The
`catch return error.WriteFailed` matches the file's existing error idiom. Line 840 is UNCHANGED.

### Why this escape loop is correct
- Single per-byte pass: each input byte → exactly one output. No double-encoding risk (the
  "escape `&` first" rule only matters for sequential whole-string replacement, which we don't do).
- The browser decodes `&quot;` back to `"` for the CSS value, so `font-family: a&quot;b`
  renders correctly as `a"b` (architecture/external_deps.md §HTML Attribute Escaping).
- Default `"monospace"` (line 840) has no special chars → escaping is a no-op for it → zero
  output change for the default case (and thus for goldens).

## 3. `writeEscaped` (render.zig:299) — the canonical escape set (for reference, NOT reused)

```zig
fn writeEscaped(out: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        '&' => try out.writeAll("&amp;"),
        '<' => try out.writeAll("&lt;"),
        '>' => try out.writeAll("&gt;"),
        '"' => try out.writeAll("&quot;"),
        '\'' => try out.writeAll("&#x27;"),
        else => try out.writeByte(c),
    };
}
```
It writes to `*std.Io.Writer` and uses `try` — NOT directly callable on `buf_writer` (a ghostty
fixed-buffer-stream writer whose calls return an error union handled with `catch return
error.WriteFailed`). So the fix inlines the loop with the file's own error idiom. Same set.

## 4. The unit test (verbatim, FAIL-before/PASS-after proven)

`ghostty_format.zig` has **no test blocks** today; `render.zig` does and is reached by the test
step (`main.zig:565 _ = @import("render.zig")`). The test goes in `render.zig`, right after the
existing `test "writeEscaped: …"` (:1338), using its `std.Io.Writer.Allocating` pattern.

```zig
test "renderGrid escapes --font into <pre style> (Issue 2: attribute-injection XSS)" {
    // A " in the font value must NOT break out of the double-quoted style attribute.
    var aw = try std.Io.Writer.Allocating.initCapacity(std.testing.allocator, 1 << 16);
    defer aw.deinit();
    try renderGrid(
        std.testing.allocator,
        "x\n",
        .{ .cols = 1, .rows = 1 },
        palette.defaultColors(),
        null,
        "a\" onmouseover=\"alert(1)", // XSS payload
        &aw.writer,
    );
    const got = aw.writer.buffered();
    // (1) font value is HTML-entity-escaped inside the style attribute:
    try std.testing.expect(std.mem.indexOf(u8, got, "font-family: a&quot; onmouseover=&quot;alert(1);") != null);
    // (2) no raw attribute breakout: the payload never becomes a real HTML attribute:
    try std.testing.expect(std.mem.indexOf(u8, got, "onmouseover=\"alert") == null);
}
```

`renderGrid` is `pub fn renderGrid(alloc, ansi, size, colors, sel, font, out) !void` (:143). The
test calls it as a sibling fn (same file). `palette.defaultColors()` is in scope in render.zig.
Trivial `"x\n"` input is enough — the `<pre style … font-family …>` header is emitted BEFORE the
cell loop, so the font declaration is present even for a 1-cell grid.

### Empirical proof (throwaway build `/tmp/t2h-fontxss.*`)
- **PASS-after** (fix + test applied): `zig build test --release=fast` → exit 0, all 326 tests
  pass (incl. this one + all goldens byte-equal).
- **FAIL-before** (revert the fix at :841, keep the test): → `run test 325/326 passed, 1 failed`
  + `transitive failure`, exit 1, the failing test named exactly
  `'renderGrid escapes --font into <pre style> (Issue 2: attribute-injection XSS)'`.
- ⇒ The test is a genuine regression detector (catches the XSS), not a tautology.

## 5. Goldens are UNAFFECTED (proven)

`golden_test.zig:30` calls `renderDocument` with `font = null` → formatter default
`"monospace"` (line 840) → no special chars → escaping is a byte-for-byte no-op. The PASS-after
run (above) confirms both golden tests still pass byte-equal with the fix in place.

## 6. DOCS deliverable — `docs/CONFIGURATION.md` `@tmux-2html-font` row

Current row (line 45): `| @tmux-2html-font | monospace | CSS font-family used in the rendered HTML. |`
Append a short security note to the Meaning cell (or add a one-line note just under the table),
e.g.: *"The value is HTML-escaped when emitted into the `style` attribute, so a font name
containing `"` or other markup characters cannot inject attributes or scripts."* This is a
security note, no behavior change for normal font names.

**Boundary note**: the parallel task P1.M1.T1.S1 (Issue 1) edits the *title/lang threading*
paragraph in "How options are read" (~lines 84-88). This task edits the **font table row**
(line 45) — a different, non-adjacent location. No textual collision.

## 7. Scope & validation boundaries

- **EDIT** `src/ghostty_format.zig` (line 841 → escape loop) + `src/render.zig` (add test) +
  `docs/CONFIGURATION.md` (font row note).
- **DO NOT touch**: `tmux-2html.tmux` / `tests/plugin_options.sh` (Issue 1, parallel); render
  `writeEscaped`, `renderGrid` signature, `cli.zig`, `golden_test.zig`, `testdata/*` (untouched
  — goldens byte-equal, proven).
- **VALIDATION**: `zig build test --release=fast` → exit 0 (the test step is `b.addTest(.{ .root_module = exe.root_module })` rooted at `src/main.zig`, which reaches render.zig).
  ReleaseFast is MANDATORY (bare `zig build test` Debug hits the `R_X86_64_PC64` linker bug).