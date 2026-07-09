//! render.zig — the ONE rendering primitive (PRD §8, P1.M3.T1.S1).
//!
//! Absorbs term2html's `formatAnsi` + the vendored `ghostty_format.zig` (see
//! architecture/render_pipeline.md §1). `renderGrid` is the single reusable primitive every
//! P2/P3 subcommand (`pane`, `region`) reduces to: get ANSI -> call renderGrid -> write it.
//!
//! Scope (P1.M3.T1.S1): default colors only (S3 owns --palette resolve), minimal cols/rows
//! fallback (S2 owns smart sizing/--output/--open), sel: null (S4 owns --selection Pin).
//!
//! GOTCHA (new Zig 0.15 IO): ghostty_format.ScreenFormatter.format takes a `*std.Io.Writer`
//! (the NEW IO type), NOT an fs.File and NOT fs.File.Writer. Callers bridge via
//! `&fw.interface` (stdout) or `&aw.writer` (test capture). See research/findings.md §3.

const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const Terminal = ghostty_vt.Terminal;
const Selection = ghostty_vt.Selection;
const fmt = @import("ghostty_format.zig"); // vendored: ScreenFormatter, Options (has font)
const palette = @import("palette.zig"); // Colors, defaultColors()
const cli = @import("cli.zig"); // RenderOpts

/// Geometry for the virtual terminal. cols/rows are u16 to match ghostty `size.CellCountInt`
/// exactly (ghostty size.zig:22), which is what `Terminal.Options` wants.
/// (cli.RenderOpts.cols/rows are ?u16; `run` maps opts -> Size.)
pub const Size = struct {
    cols: u16,
    rows: u16,
};

/// Upper bound on stdin size. Generous (~256 MiB) — the caller frees the allocation.
/// Mirrors palette.zig's use of `readToEndAlloc` (File.zig:809).
const MAX_STDIN: usize = 1 << 28;

/// The ONE rendering primitive: ANSI bytes -> self-contained HTML via the vendored
/// ScreenFormatter. Writes a `<pre class="term2html-output">…</pre>` fragment to `out`.
///
/// Pipeline (verified — architecture/render_pipeline.md §1, research/findings.md §1):
///   Terminal.init -> vtStream -> per-byte next() with \n -> \r\n translation
///   -> ScreenFormatter.init(active screen, .{emit=.html, bg, fg, palette, font})
///   -> content.selection = sel (null = WHOLE grid)
///   -> extra = .styles (per-cell <span> inline CSS + OSC-8 <a> hyperlinks)
///   -> out.print("{f}", .{f})
///
/// `sel` is `?Selection`: S1 always passes null. S4 passes a Selection built from Pins.
/// `font` is `?[]const u8`: null lets the formatter default to "monospace".
/// `out` is `*std.Io.Writer` (the NEW Zig 0.15 IO type) — callers create it (see `run` / tests).
///
/// Because `opts.palette` is set, palette colors emit as INLINE RGB (`#rrggbb`) — output is
/// self-contained, no `:root{--vt-palette-N}` CSS block (that block is only from
/// TerminalFormatter, which we do NOT use). color.Palette == [256]color.RGB, so
/// `&colors.palette` is `*const color.Palette`, coercing to `?*const color.Palette`.
pub fn renderGrid(
    alloc: std.mem.Allocator,
    ansi: []const u8,
    size: Size,
    colors: palette.Colors,
    sel: ?Selection,
    font: ?[]const u8,
    out: *std.Io.Writer,
) !void {
    var t = try Terminal.init(alloc, .{ .cols = size.cols, .rows = size.rows });
    defer t.deinit(alloc);

    var stream = t.vtStream();
    defer stream.deinit();
    // Feed bytes ONE at a time so we can translate \n -> \r\n (matches tmux capture output +
    // the verified term2html pattern). nextSlice() exists but can't do the per-newline
    // translation.
    for (ansi) |c| {
        if (c == '\n') try stream.next('\r');
        try stream.next(c);
    }

    var f = fmt.ScreenFormatter.init(t.screens.active, .{
        .emit = .html,
        .background = colors.background, // ?color.RGB
        .foreground = colors.foreground, // ?color.RGB
        .palette = &colors.palette, // *const [256]RGB -> ?*const color.Palette
        .font = font, // ?[]const u8
    });
    f.content = .{ .selection = sel }; // null = WHOLE grid
    f.extra = .styles; // per-cell <span> styles + OSC-8 <a> hyperlinks
    try out.print("{f}", .{f}); // {f} invokes f.format(*std.Io.Writer)
}

/// The `render` subcommand body: read ANSI from stdin, render with defaultColors(), write
/// HTML to stdout, exit 0.
///
/// SCOPE DISCIPLINE (S1 only — respect sibling subtasks):
///   - palette: S3 owns `palette.resolve(alloc, mode, has_tty)`; S1 uses defaultColors() only.
///   - sizing: S2 owns smart defaults (rows = input line count) + --cols required-if-no-tty;
///     S1 uses a minimal cols=80/rows=24 fallback.
///   - sel: S4 owns --selection coordinate -> Pin -> Selection; S1 passes sel: null.
///   - --output/--open: S2 owns those; S1 writes to stdout only.
/// `opts.font` is passed through (renderGrid already takes font) — S2 owns it as a full flag.
pub fn run(alloc: std.mem.Allocator, opts: cli.RenderOpts) !u8 {
    const stdin = std.fs.File.stdin();
    const ansi = try stdin.readToEndAlloc(alloc, MAX_STDIN); // File.zig:809; caller frees.
    defer alloc.free(ansi);

    const colors = palette.defaultColors(); // S3: palette.resolve(alloc, mode, palette.hasControllingTty())
    const size = Size{ .cols = opts.cols orelse 80, .rows = opts.rows orelse 24 }; // S2 refines

    // NEW-IO writer bridge (research/findings.md §3, compile-validated):
    // `out_file.writer(&buf)` returns an `fs.File.Writer` WRAPPER whose `.interface` field IS
    // the `std.Io.Writer` the formatter wants. Pass `&fw.interface`, flush `fw.interface`.
    var out_file = std.fs.File.stdout();
    var buf: [4096]u8 = undefined;
    var fw = out_file.writer(&buf);
    defer fw.interface.flush() catch {};
    try renderGrid(alloc, ansi, size, colors, null, opts.font, &fw.interface);
    return 0;
}

// ---- Unit tests (renderGrid via Allocating writer — NO /dev/tty, NO stdin) ----
// Pattern (research/findings.md §3, compile-validated):
//   var aw = try std.Io.Writer.Allocating.initCapacity(std.testing.allocator, 4096);
//   defer aw.deinit();
//   try renderGrid(std.testing.allocator, ansi, .{ .cols = 40, .rows = 5 }, palette.defaultColors(), null, "monospace", &aw.writer);
//   const html = aw.writer.buffered();
// renderGrid/Terminal must free everything (deinit t, stream) — verify no leaks under
// std.testing.allocator. Do NOT hardcode palette hex values: defaultColors() palette[1] is
// whatever Ghostty bundles; assert SHAPE, not exact color.
//
// GHOSTTY-VT GOTCHA: ghostty-vt's Terminal.init leaves process-global state corrupted such
// that a Terminal.init in a SEPARATE test function crashes (core dump). Sequential renderGrid
// calls in the SAME test scope are fine (verified). So ALL renderGrid assertions live in ONE
// test; renderGrid is the single primitive, so one test covering color/attribute/plain/
// empty/truecolor/ESC-integrity is appropriate and keeps the suite green.

/// Helper: render ANSI into an allocating buffer and return an OWNED copy (caller frees).
/// The copy is necessary because `Allocating.deinit` frees the buffer that `buffered()`
/// points into (returning `buffered()` directly would be a use-after-free after the defer).
fn renderToOwned(ansi: []const u8) ![]u8 {
    var aw = try std.Io.Writer.Allocating.initCapacity(std.testing.allocator, 4096);
    defer aw.deinit();
    try renderGrid(
        std.testing.allocator,
        ansi,
        .{ .cols = 40, .rows = 5 },
        palette.defaultColors(),
        null,
        "monospace",
        &aw.writer,
    );
    return std.testing.allocator.dupe(u8, aw.writer.buffered());
}

test "renderGrid: red foreground emits styled span" {
    // All renderGrid assertions live in THIS test because ghostty-vt's Terminal corrupts
    // process-global state across separate test functions (see the GOTCHA above). Sequential
    // renderGrid calls in one scope work fine; renderGrid is the ONE primitive so one test
    // covering color/attribute/plain/empty/truecolor/ESC-integrity is the right shape.
    const red = try renderToOwned("\x1b[31mred\x1b[0m");
    defer std.testing.allocator.free(red);
    try std.testing.expect(std.mem.indexOf(u8, red, "<span style=") != null);
    try std.testing.expect(std.mem.indexOf(u8, red, ">red</span>") != null);
    // a '#' hex color (do NOT hardcode the hex — defaultColors palette[1] is Ghostty's bundle).
    // ghostty_format emits "color: #rrggbb" (space after the colon).
    try std.testing.expect(std.mem.indexOf(u8, red, "color: #") != null);

    const bold = try renderToOwned("\x1b[1mbold\x1b[0m");
    defer std.testing.allocator.free(bold);
    // ghostty_format emits "font-weight: bold" (space after the colon).
    try std.testing.expect(std.mem.indexOf(u8, bold, "font-weight: bold") != null);
    try std.testing.expect(std.mem.indexOf(u8, bold, ">bold</span>") != null);

    const plain = try renderToOwned("hello world");
    defer std.testing.allocator.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "<pre class=\"term2html-output\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "hello world") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "<span style=") == null); // no span for plain text

    const empty = try renderToOwned("");
    defer std.testing.allocator.free(empty);
    try std.testing.expect(std.mem.indexOf(u8, empty, "<pre") != null);
    try std.testing.expect(std.mem.indexOf(u8, empty, "</pre>") != null);

    const truecolor = try renderToOwned("\x1b[38;2;255;0;0mX\x1b[0m");
    defer std.testing.allocator.free(truecolor);
    // ghostty_format emits "color: #ff0000" (space after the colon).
    try std.testing.expect(std.mem.indexOf(u8, truecolor, "color: #ff0000") != null);
    try std.testing.expect(std.mem.indexOf(u8, truecolor, ">X</span>") != null);

    // A multi-byte SGR (truecolor) followed by a newline: the per-byte \n -> \r\n loop must
    // not split or mangle the ESC sequence. The 'A' after the newline is plain.
    const mixed = try renderToOwned("\x1b[38;2;0;255;0mA\nB\x1b[0m");
    defer std.testing.allocator.free(mixed);
    try std.testing.expect(std.mem.indexOf(u8, mixed, "color: #00ff00") != null);
    try std.testing.expect(std.mem.indexOf(u8, mixed, ">A</span>") != null);
}
