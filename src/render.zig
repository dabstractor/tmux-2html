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
const builtin = @import("builtin");
const ghostty_vt = @import("ghostty-vt");
const Terminal = ghostty_vt.Terminal;
const Selection = ghostty_vt.Selection;
const point = ghostty_vt.point; // point.Point{ .screen = .{ .x, .y } } (P1.M4.T1.S1)
const Screen = ghostty_vt.Screen; // *const Screen param of buildSelection
const fmt = @import("ghostty_format.zig"); // vendored: ScreenFormatter, Options (has font)
const palette = @import("palette.zig"); // Colors, defaultColors()
const cli = @import("cli.zig"); // RenderOpts
const select = @import("tui/select.zig"); // P3.M2.T2.S1: Sel.extent — the PURE TUI selection model (CONSUME as a contract)
const view = @import("tui/view.zig"); // P3.M1.T2: view.Selection (structurally identical to cli.SelectionCoords; the clampExtent bridge target)

/// Geometry for the virtual terminal. cols/rows are u16 to match ghostty `size.CellCountInt`
/// exactly (ghostty size.zig:22), which is what `Terminal.Options` wants.
/// (cli.RenderOpts.cols/rows are ?u16; `run` maps opts -> Size.)
pub const Size = struct {
    cols: u16,
    rows: u16,
};

/// Terminal geometry from ioctl(TIOCGWINSZ). Distinct from `Size` (the VT geometry we
/// RENDER into): WindowSize is what the kernel reports about the controlling terminal.
pub const WindowSize = struct { cols: u16, rows: u16 };

/// Errors determining the column count. Mapped to exit 2 in `run` via `reportSizeError`.
/// These are NOT bubbled as Zig error traces — `run` returns a u8 (2) after a stderr msg.
pub const SizeError = error{
    SizeRequired, // no --cols and no controlling tty
    NoTty, // /dev/tty could not be opened
    IoctlFailed, // ioctl returned an errno
    InvalidWindowSize, // winsize reported 0 cols/rows
    UnsupportedPlatform, // non-Linux (no libc => no portable ioctl layer)
};

/// Upper bound on stdin size. Generous (~256 MiB) — the caller frees the allocation.
/// Mirrors palette.zig's use of `readToEndAlloc` (File.zig:809).
const MAX_STDIN: usize = 1 << 28;

/// Read the controlling terminal's geometry via ioctl(TIOCGWINSZ) (P1.M3.T1.S2).
///
/// The build is `.link_libc=false`, so `std.posix.system` is `std.os.linux` on Linux but a
/// feature-less stub on macOS (no T, no ioctl). We use `std.os.linux` DIRECTLY (it compiles
/// on every target — verified by `zig build-obj -target x86_64-macos`; it's dead code
/// off-Linux, guarded by `builtin.os.tag != .linux`).
///
/// Mirrors the stdlib's own `isatty` (posix.zig:3575): `var wsz: winsize = undefined;
/// linux.syscall3(.ioctl, fd, linux.T.IOCGWINSZ, @intFromPtr(&wsz))`. GOTCHA:
/// `std.posix.winsize` field order is `{ row, col, xpixel, ypixel }` (posix.zig:226) —
/// `col` is field #1 (NOT field #0; reading `ws.row` as cols is a silent bug).
///
/// Opens /dev/tty read-only (`.read_only` is enough for ioctl(TIOCGWINSZ) — we only READ
/// the size; palette.queryColors uses `.read_write` because it WRITES query bytes).
pub fn getSize() SizeError!WindowSize {
    // No libc => no portable ioctl layer off-Linux. Guard so macOS degrades to a size error
    // (caller surfaces exit 2) rather than making a bogus Linux syscall.
    if (builtin.os.tag != .linux) return error.UnsupportedPlatform;
    var tty = std.fs.openFileAbsolute("/dev/tty", .{ .mode = .read_only }) catch return error.NoTty;
    defer tty.close();
    var ws: std.posix.winsize = undefined; // { row, col, xpixel, ypixel }
    const linux = std.os.linux;
    const fd: usize = @bitCast(@as(isize, tty.handle)); // File.handle is c_int -> isize -> usize
    const rc = linux.syscall3(.ioctl, fd, linux.T.IOCGWINSZ, @intFromPtr(&ws));
    switch (linux.E.init(rc)) {
        .SUCCESS => {},
        else => return error.IoctlFailed,
    }
    if (ws.col == 0 or ws.row == 0) return error.InvalidWindowSize;
    return .{ .cols = ws.col, .rows = ws.row };
}

/// Pure decision: which cols to render with? (P1.M3.T1.S2; research/findings.md §2)
/// - explicit `opts_cols` always wins (never probes the tty — safe to unit-test this branch);
/// - else, if there's a controlling tty, read its width via `getSize()`;
/// - else (no tty, no --cols) => `error.SizeRequired` (run maps this to exit 2).
///
/// GOTCHA: "no tty" means no CONTROLLING terminal (palette.hasControllingTty probes
/// /dev/tty), NOT "stdin is a pipe". Piped stdin in a dev terminal STILL has a controlling
/// tty => getSize() is used. The deterministic no-tty case is `setsid` (detaches the tty).
/// GOTCHA: the `has_tty=true` branch calls the REAL getSize (opens /dev/tty) — never assert
/// its value in a unit test (CI has no tty; only assert the explicit-cols + no-tty paths).
pub fn determineCols(opts_cols: ?u16, has_tty: bool) SizeError!u16 {
    if (opts_cols) |c| { // explicit --cols wins; never probes the tty
        if (c < 1) return error.InvalidWindowSize; // explicit --cols 0 -> exit 2 (Issue 2 segfault guard)
        return c;
    }
    if (has_tty) return (try getSize()).cols; // (try ...) — getSize is an error union
    return error.SizeRequired; // no tty, no --cols => exit 2
}

/// Count the lines an editor would show for `ansi` (P1.M3.T1.S2; research/findings.md §3).
/// Used as the default for `--rows` (so piped input with N lines isn't scrolled off under
/// the S1 fallback of rows=24). Counts '\n' + 1 for a trailing partial line; floor 1;
/// clamps to u16. VERIFIED: ""=>1, "a\nb\n"=>2, "a\nb"=>2, "hello"=>1.
fn lineCount(ansi: []const u8) u16 {
    if (ansi.len == 0) return 1;
    var n: u32 = @intCast(std.mem.count(u8, ansi, "\n"));
    if (ansi[ansi.len - 1] != '\n') n += 1; // trailing partial line (no newline)
    if (n == 0) n = 1; // defensive floor
    return @intCast(@min(n, std.math.maxInt(u16)));
}

/// Size ghostty-vt's scrollback limit (in BYTES) for a captured pane so the FULL scrollback is
/// retained. `Terminal.init` defaults `max_scrollback` to 10_000 — but that option is the
/// scrollback limit in BYTES (Screen.Options: "maximum size of scrollback in bytes"), NOT
/// rows, so 10 KiB silently prunes almost all scrollback (a 319-col pane keeps only ~160
/// rows). Measured page-storage cost is ~9.8 bytes/cell, so `lines * cols * 32` (~3.3x
/// headroom for page granularity + any re-wrap) holds the entire capture. This is a LIMIT,
/// not a pre-allocation, so the headroom costs nothing unless the content actually needs it.
pub fn scrollbackBytes(ansi: []const u8, cols: u16) usize {
    return @as(usize, lineCount(ansi)) * @as(usize, @max(cols, 1)) * 32;
}

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
/// `sel` is `?cli.SelectionCoords` (P1.M4.T1.S1): null renders the WHOLE grid; a value is
/// translated to a native `Selection` from Pins via `buildSelection` INSIDE renderGrid (where
/// the loaded screen exists). `font` is `?[]const u8`: null lets the formatter default to
/// "monospace". `out` is `*std.Io.Writer` (the NEW Zig 0.15 IO type) — callers create it.
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
    sel: ?cli.SelectionCoords,
    font: ?[]const u8,
    out: *std.Io.Writer,
) !void {
    var t = try Terminal.init(alloc, .{ .cols = size.cols, .rows = size.rows, .max_scrollback = scrollbackBytes(ansi, size.cols) });
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

    // S1 (P1.M4.T1.S1): build the native Selection from CLI coords now that the screen
    // exists. renderGrid owns the Terminal/Screen, so the coordinate->Pin translation
    // happens here. `t.screens.active` is *Screen (coerces to *const Screen).
    var native_sel: ?Selection = null;
    if (sel) |coords| native_sel = try buildSelection(t.screens.active, coords);

    var f = fmt.ScreenFormatter.init(t.screens.active, .{
        .emit = .html,
        .background = colors.background, // ?color.RGB
        .foreground = colors.foreground, // ?color.RGB
        .palette = &colors.palette, // *const [256]RGB -> ?*const color.Palette
        .font = font, // ?[]const u8
    });
    f.content = .{ .selection = native_sel }; // null = WHOLE grid; some(sel) = sub-grid (inclusive)
    f.extra = .styles; // per-cell <span> styles + OSC-8 <a> hyperlinks
    try out.print("{f}", .{f}); // {f} invokes f.format(*std.Io.Writer)
}

// ---- PRD §8.1 HTML document envelope (normative: "no cutting corners") ----
// renderGrid emits ONLY the `<pre class="term2html-output">…</pre>` fragment (the
// absorbed term2html ScreenFormatter output). PRD §8.1 mandates that EVERY HTML sink
// (render stdout/--output/--selection, pane --visible/--full, region confirm) write a
// COMPLETE, valid HTML5 document wrapping that fragment. `writeDocument` is the shared
// envelope helper: it writes the DOCTYPE → <html> → <head> (charset, viewport, title,
// a body-margin-reset + page-bg style) → <body> → the rendered <pre> fragment → closing
// tags, to `out`. `renderDocument` is the full primitive (build the grid, format the
// fragment INTO the document via a bridge writer). The golden harness (golden_test.zig)
// calls renderDocument so it pins the FULL document byte-for-byte (PRD §15).

/// Document envelope metadata (PRD §8.1). `title` is HTML-escaped by writeDocument;
/// `lang` defaults to "en" (configurable via @tmux-2html-lang/locale — future). The
/// `background` RGB drives the page `<body>` background so the terminal block does not
/// sit in a white margin (§8.1 normative: page bg = resolved terminal bg).
pub const DocumentOpts = struct {
    title: []const u8,
    lang: []const u8 = "en",
    background: ?ghostty_vt.color.RGB = null, // page bg = terminal bg (null => no inline bg)
};

// ---------------------------------------------------------------------------
// Lang resolution (PRD §8.1 <html lang>; algorithm: architecture/lang_resolution.md).
// POSIX locale name -> BCP-47 tag. Precedence: explicit --lang / @tmux-2html-lang
// -> LC_ALL -> LC_MESSAGES -> LANG -> "en". Allocation-free (module-level buffer).
// ---------------------------------------------------------------------------

/// Output buffer for a normalized BCP-47 tag. Overwritten on each call; safe because
/// toBcp47/langFromEnv/resolveLang are each called once per render and the result is
/// stored into DocumentOpts.lang and consumed during that single writeDocument.
/// (A normalized tag is at most 6 chars — `xxx-XX` — so [16] is generous.)
var bcp47_buf: [16]u8 = undefined;

/// Pure POSIX-locale -> BCP-47 transform. Strips `.codeset` (from first '.') and
/// `@modifier` (from first '@'), maps `_`->`-`, lowercases the language subtag,
/// uppercases the region subtag, and validates against `^[a-z]{2,3}(-[A-Z]{2})?$`.
/// Returns null for C/POSIX/empty/invalid shapes; the caller falls back to "en".
/// PURE (no I/O, no alloc) -> unit-testable; does NOT mutate its input.
fn toBcp47(locale: []const u8) ?[]const u8 {
    var s = locale;
    if (std.mem.indexOfScalar(u8, s, '.')) |i| s = s[0..i]; // strip .codeset
    if (std.mem.indexOfScalar(u8, s, '@')) |i| s = s[0..i]; // strip @modifier

    // First '_' or '-' separates language from territory.
    var sep_idx: ?usize = null;
    for (s, 0..) |c, i| if (c == '_' or c == '-') {
        sep_idx = i;
        break;
    };

    const lang_src = if (sep_idx) |i| s[0..i] else s;
    const region_src: ?[]const u8 = blk: {
        if (sep_idx) |i| {
            if (i + 1 >= s.len) break :blk null; // trailing separator, no region
            break :blk s[i + 1 ..];
        } else break :blk null;
    };

    // Language subtag: 2-3 lowercase a-z.
    if (lang_src.len < 2 or lang_src.len > 3) return null;
    var out_len: usize = 0;
    for (lang_src) |c| {
        const lc = std.ascii.toLower(c);
        if (lc < 'a' or lc > 'z') return null;
        bcp47_buf[out_len] = lc;
        out_len += 1;
    }

    // Region subtag (optional): exactly 2 uppercase A-Z, no embedded separator.
    if (region_src) |r| {
        if (r.len != 2) return null;
        if (r[0] == '_' or r[0] == '-' or r[1] == '_' or r[1] == '-') return null;
        bcp47_buf[out_len] = '-';
        out_len += 1;
        for (r) |c| {
            const uc = std.ascii.toUpper(c);
            if (uc < 'A' or uc > 'Z') return null;
            bcp47_buf[out_len] = uc;
            out_len += 1;
        }
    }

    return bcp47_buf[0..out_len];
}

/// Pure precedence resolver (LC_ALL -> LC_MESSAGES -> LANG -> "en"). Set-but-EMPTY
/// values count as unset (POSIX override semantics). The first non-empty candidate
/// wins; if its transform fails, fall directly to "en" (no cascade — POSIX: LC_ALL
/// overrides everything). Param-taking so it is deterministic & unit-testable.
fn langFromEnvStrings(lc_all: ?[]const u8, lc_messages: ?[]const u8, lang: ?[]const u8) []const u8 {
    if (lc_all) |v| if (v.len > 0) return toBcp47(v) orelse "en";
    if (lc_messages) |v| if (v.len > 0) return toBcp47(v) orelse "en";
    if (lang) |v| if (v.len > 0) return toBcp47(v) orelse "en";
    return "en";
}

/// Locale-only resolution (precedence + transform + fallback). Reads the process
/// environment via std.posix.getenv. NO /dev/tty.
pub fn langFromEnv() []const u8 {
    return resolveLangImpl(
        null,
        std.posix.getenv("LC_ALL"),
        std.posix.getenv("LC_MESSAGES"),
        std.posix.getenv("LANG"),
    );
}

/// Resolve the <html lang> value (PRD §8.1). Explicit --lang / @tmux-2html-lang wins;
/// an EMPTY explicit value (--lang "") is treated as UNSET and derives from the locale
/// (Issue 4: previously it forced "en"). An explicit invalid value (e.g. "C", "english")
/// degrades defensively to "en". Otherwise derive from the locale; else "en".
pub fn resolveLang(explicit: ?[]const u8) []const u8 {
    return resolveLangImpl(
        explicit,
        std.posix.getenv("LC_ALL"),
        std.posix.getenv("LC_MESSAGES"),
        std.posix.getenv("LANG"),
    );
}

/// Pure core shared by resolveLang + langFromEnv (Issue 4). An explicit NON-EMPTY value
/// wins (invalid -> "en"); an EMPTY explicit value is treated as UNSET and derives from
/// LC_ALL -> LC_MESSAGES -> LANG -> "en" (same as null). Param-taking so it is deterministic
/// & unit-testable without mutating process env (Zig 0.15.2 std has no setenv; link_libc=false).
/// Mirrors the langFromEnv/langFromEnvStrings pub-reader + pure-helper precedent.
fn resolveLangImpl(explicit: ?[]const u8, lc_all: ?[]const u8, lc_messages: ?[]const u8, lang: ?[]const u8) []const u8 {
    if (explicit) |e| {
        if (e.len == 0) return langFromEnvStrings(lc_all, lc_messages, lang); // Issue 4: empty explicit == unset
        return toBcp47(e) orelse "en";
    }
    return langFromEnvStrings(lc_all, lc_messages, lang);
}

/// HTML-escape `s` into `out` (PRD §8.1: <title> etc. is HTML-escaped; cell text stays
/// ghostty-vt's job). Escapes & < > " ' per OWASP. PURE (no alloc) => unit-testable.
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

/// Write the PRD §8.1 document envelope: DOCTYPE, <html lang>, <head> (charset FIRST,
/// viewport, escaped <title>, a body-margin-reset + page-bg style), <body>, then call
/// `fragment_fn` to emit the `<pre>` fragment, then `</body></html>`. The fragment is
/// emitted INLINE via the callback so no intermediate buffer is needed for the whole-grid
/// path (memory-efficient for large panes). charset is the FIRST element in <head> (HTML
/// spec: within the first 1024 bytes). The body background matches the resolved terminal
/// bg (§6) so the terminal block does not sit in a white margin; default body margin is 0.
///
/// `fragment_fn` is a COMPTIME function pointer (so it can be a bound method on a context
/// struct); `ctx` is passed back to it opaquely. This avoids a one-shot allocation for the
/// whole-grid streaming path while letting the buffered path splice in pre-rendered bytes.
pub fn writeDocument(
    out: *std.Io.Writer,
    doc: DocumentOpts,
    comptime Ctx: type,
    ctx: Ctx,
    comptime fragment_fn: *const fn (Ctx, *std.Io.Writer) anyerror!void,
) !void {
    try out.writeAll("<!DOCTYPE html>\n<html lang=\"");
    try writeEscaped(out, doc.lang);
    try out.writeAll("\">\n<head>\n<meta charset=\"utf-8\">\n");
    try out.writeAll("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n");
    try out.writeAll("<title>");
    try writeEscaped(out, doc.title);
    try out.writeAll("</title>\n<style>");
    try out.writeAll("html,body{margin:0;padding:0;}");
    if (doc.background) |bg| {
        try out.print("body{{background-color:#{x:0>2}{x:0>2}{x:0>2};}}", .{ bg.r, bg.g, bg.b });
    }
    try out.writeAll("</style>\n</head>\n<body>\n");
    try fragment_fn(ctx, out); // the <pre> fragment (renderGrid against the SAME writer)
    try out.writeAll("\n</body>\n</html>\n");
}

/// Write a COMPLETE HTML5 document (PRD §8.1) wrapping an ALREADY-RENDERED `<pre>` fragment
/// (`fragment_bytes`) to `out`. Used by the `--selection` and region-confirm paths, which
/// buffer the fragment to validate non-emptiness BEFORE writing. The whole-grid paths use
/// `writeDocument` (streaming, no intermediate buffer). Identical envelope; the fragment is
/// spliced in as a raw `writeAll` (it is already-correct HTML from the formatter).
pub fn writeDocumentBytes(
    out: *std.Io.Writer,
    doc: DocumentOpts,
    fragment_bytes: []const u8,
) !void {
    const Ctx = struct {
        fb: []const u8,
        fn emit(self: @This(), w: *std.Io.Writer) anyerror!void {
            try w.writeAll(self.fb);
        }
    };
    const ctx = Ctx{ .fb = fragment_bytes };
    try writeDocument(out, doc, Ctx, ctx, Ctx.emit);
}

/// The full-document rendering primitive (PRD §8.1): build the grid, then emit the
/// complete HTML5 document (envelope + `<pre>` fragment) to `out`. This is what EVERY
/// output sink calls. `doc` carries the title/lang/background (background defaults to
/// colors.background when the caller passes .background = colors.background). The
/// fragment is rendered directly into the document's writer via a closure-free callback
/// (renderGridFragment below) — no intermediate buffer for the whole-grid path.
pub fn renderDocument(
    alloc: std.mem.Allocator,
    ansi: []const u8,
    size: Size,
    colors: palette.Colors,
    sel: ?cli.SelectionCoords,
    font: ?[]const u8,
    doc: DocumentOpts,
    out: *std.Io.Writer,
) !void {
    // Capture the render params so the fragment callback can invoke renderGrid.
    const Ctx = struct {
        a: std.mem.Allocator,
        an: []const u8,
        sz: Size,
        cl: palette.Colors,
        sl: ?cli.SelectionCoords,
        fnt: ?[]const u8,
        fn render(self: @This(), w: *std.Io.Writer) anyerror!void {
            try renderGrid(self.a, self.an, self.sz, self.cl, self.sl, self.fnt, w);
        }
    };
    const ctx = Ctx{ .a = alloc, .an = ansi, .sz = size, .cl = colors, .sl = sel, .fnt = font };
    try writeDocument(out, doc, Ctx, ctx, Ctx.render);
}

/// Build a ghostty `Selection` from CLI coordinates against a loaded screen (PRD §5.1/§7.4).
/// Reusable: `renderGrid` calls this internally; the TUI (P3.M2.T2.S2) calls it directly.
///
/// Coordinates are CELL INDICES in the loaded grid (x=column, y=row, origin top-left). The
/// `.screen` tag is used (consistent with the formatter's own `order()`/`getTopLeft(.screen)`
/// reasoning; for a fresh terminal sized to the input's line count there is no scrollback,
/// so `.screen` top-left == grid row 0). start/end may be given in ANY order — the formatter
/// normalizes via `Selection.order`.
///
/// Returns `error.OutOfRange` if a coordinate is outside the grid: `x >= cols` or `y` past
/// the last WRITTEN row (the `.screen` page list covers only written rows, so selecting into
/// the unwritten tail is rejected — the safe, intended behavior).
///
/// GOTCHA: do NOT call `Selection.deinit` — `init` creates an UNTRACKED selection (no heap,
/// no tracking handles); `deinit` is a NO-OP for untracked bounds AND it takes a MUTABLE
/// `*Screen` which we don't have (`t.screens.active` is `*const` here). VERIFIED against
/// ghostty v1.3.1 (Selection.zig:55/69).
///
/// GOTCHA: `point.Coordinate.x` is `size.CellCountInt` = u16; `cli.SelectionCoords` stores
/// u32. Guard `x > maxInt(u16)` BEFORE `@intCast` (a raw cast of a u32 > 65535 traps in
/// Debug/ReleaseSafe and is UB in ReleaseFast). `.y` is u32 => direct.
pub fn buildSelection(screen: *const Screen, coords: cli.SelectionCoords) error{OutOfRange}!Selection {
    if (coords.x1 > std.math.maxInt(u16) or coords.x2 > std.math.maxInt(u16))
        return error.OutOfRange;
    const start_pt = point.Point{ .screen = .{ .x = @intCast(coords.x1), .y = coords.y1 } };
    const end_pt = point.Point{ .screen = .{ .x = @intCast(coords.x2), .y = coords.y2 } };
    const sp = screen.pages.pin(start_pt) orelse return error.OutOfRange;
    const ep = screen.pages.pin(end_pt) orelse return error.OutOfRange;
    return Selection.init(sp, ep, coords.rect); // untracked; NO deinit (findings §1)
}

// ---- P3.M2.T2.S2: TUI -> ghostty Selection bridge (the confirm-render input) ----
// S2 is the ONLY thing that converts a PURE TUI `select.Sel` into a native ghostty `Selection`
// against the LOADED screen. It REUSES `buildSelection` (the P1.M4.T1.S1 recipe: point.Point ->
// screen.pages.pin -> Selection.init) — it does NOT re-implement pin/Selection logic. S2's only
// NEW logic is the CLAMP (defensive grid-bounds normalization, so the TUI path is infallible
// where the CLI --selection path errors) + the `select.Sel.extent` -> `cli.SelectionCoords`
// bridge + grid-row discovery.
//
// PRD §13 "wide cells selected atomically (round to cell boundaries)" is SATISFIED BY
// DELEGATION to the vendored formatter (src/ghostty_format.zig): PageFormatter rounds start_x
// BACK from a wide cell's `.spacer_tail` (~line 808) and skips spacers in emission (~line 1019),
// so a glyph is never split. S2 does NOT inspect cell.wide and does NOT round — rounding here
// would double-round against the formatter and risk off-by-one glyph splits (the key insight
// that keeps S2 a small, safe, 1-point task).

/// Convert a TUI selection model into a native ghostty `Selection` against the LOADED screen,
/// clamping to the grid and DELEGATING wide-cell atomicity to the formatter (PRD §13).
///
/// REUSES the P1.M4.T1.S1 recipe via `buildSelection` (point.Point -> screen.pages.pin ->
/// Selection.init). `cols` is the TUI viewport width (passed to `sel.extent` for the linewise
/// full-row bound x2 = cols-1); x is then clamped to the ACTUAL grid width `screen.pages.cols`.
///
/// PRD §7.4 mapping (produced by `sel.extent`, consumed here):
///   linewise -> Selection{ (0,r1)..(cols-1,r2), rectangle=false }
///   block    -> Selection{ (c1,r1)..(c2,r2), rectangle=true }
///
/// Infallible (returns `Selection`, NOT an error union): clamping guarantees every coord is a
/// valid grid cell, so `buildSelection` (which can only fail on out-of-range) cannot error
/// here. This is the behavioral delta vs the CLI `--selection` path, which REJECTS
/// out-of-range coords with `error.OutOfRange` — the TUI confirm path is robust (it clamps).
/// An INACTIVE `sel` (`extent` -> null) yields a WHOLE-GRID selection (top-left..bottom-right),
/// matching the formatter's own null-selection = whole-grid semantics — but the confirm call
/// site (P3.M3.T1.S2) only calls this when `sel.active()`.
///
/// OWNERSHIP: the returned Selection is UNTRACKED (`Selection.init` creates untracked bounds —
/// no heap, no tracking handles). `Selection.deinit` is a NO-OP for untracked bounds AND it
/// requires a MUTABLE `*Screen` the caller lacks (`t.screens.active` is `*const`), so the
/// caller does NOT call `deinit` — identical to the existing `buildSelection` invariant
/// (verified against ghostty v1.3.1 Selection.zig:55/69). The caller owns the value's
/// lifetime; for the untracked value that means "drop it when done" (no free needed).
pub fn toGhosttySelection(sel: select.Sel, screen: *const Screen, cols: u16) Selection {
    const ext = sel.extent(cols) orelse return wholeGridSelection(screen);
    const last_row = gridLastRow(screen); // u32; 0 if the screen has no rows (guarded)
    const coords = clampExtent(ext, screen.pages.cols, last_row);
    // Clamped -> every coord is a valid grid cell -> buildSelection cannot error. The `catch`
    // is a defensive fallback (no UB in ReleaseFast): on the structurally-unreachable error
    // it renders the whole grid rather than trap.
    return buildSelection(screen, coords) catch wholeGridSelection(screen);
}

/// PURE: clamp a (normalized) `view.Selection` extent to grid bounds -> `cli.SelectionCoords`
/// safe to hand to `buildSelection`. x -> [0,cols-1]; y -> [0,last_row]. Re-normalizes order via
/// min/max (defensive — `select.extent` already min/max's). `cols==0` -> x collapses to 0.
/// NO Terminal, NO ghostty state -> unit-testable as a SEPARATE `test` fn (mirrors
/// render.zig's determineCols/lineCount). `view.Selection` and `cli.SelectionCoords` are
/// STRUCTURALLY IDENTICAL ({x1,y1,x2,y2:u32, rect:bool=false}); this is the 1:1 bridge.
///
/// All coords are u32 (always >= 0) so only the HIGH side is clamped via `@min`. The lone
/// subtract is `cols-1` (cols is u16): widen via `@as(u32, cols)` AFTER the `cols==0` guard to
/// avoid u32 underflow.
pub fn clampExtent(ext: view.Selection, cols: u16, last_row: u32) cli.SelectionCoords {
    const last_col: u32 = if (cols == 0) 0 else @as(u32, cols) - 1;
    const nx1 = @min(ext.x1, ext.x2); // normalize order (defensive)
    const nx2 = @max(ext.x1, ext.x2);
    const ny1 = @min(ext.y1, ext.y2);
    const ny2 = @max(ext.y1, ext.y2);
    return .{
        .x1 = @min(nx1, last_col), // u32 >= 0 always; only clamp the high side
        .y1 = @min(ny1, last_row),
        .x2 = @min(nx2, last_col),
        .y2 = @min(ny2, last_row),
        .rect = ext.rect,
    };
}

/// The last row index of the loaded screen (0-based). Mirrors `view.zig`'s `total_rows`
/// computation: getBottomRight(.screen) + pointFromPin -> coord.y. Returns 0 if the screen has
/// no addressable bottom-right (guarded — never happens for an initialized Terminal, which
/// always has >=1 page). Used to clamp y so `pages.pin` never returns null.
fn gridLastRow(screen: *const Screen) u32 {
    const br = screen.pages.getBottomRight(.screen) orelse return 0;
    const br_pt = screen.pages.pointFromPin(.screen, br) orelse return 0;
    return br_pt.coord().y; // last row index (total_rows = y+1)
}

/// A whole-grid (untracked) Selection: top-left..bottom-right, rectangle=false. The fallback
/// for an INACTIVE sel and the (structurally unreachable) buildSelection error.
/// `getBottomRight(.screen)` does `self.pages.last.?` — safe for any initialized Terminal
/// (Terminal.init creates >=1 page). `orelse tl` is a belt-and-suspenders guard.
fn wholeGridSelection(screen: *const Screen) Selection {
    const tl = screen.pages.getTopLeft(.screen);
    const br = screen.pages.getBottomRight(.screen) orelse tl;
    return Selection.init(tl, br, false); // untracked; no deinit (see toGhosttySelection)
}

/// Render `ansi` to a COMPLETE HTML5 document (PRD §8.1) and write it to `path` ATOMICALLY
/// (P1.M3.T1.S2; research/findings.md §4). Wraps the vendored fragment in the document
/// envelope via `renderDocument`. `doc` carries the title/lang/page-bg (the pane/region callers
/// pass a contextual title + colors.background; render.run passes "tmux-2html").
///
/// Mirrors palette.writeCacheDir's proven atomic idiom: create a temp file IN THE SAME
/// DIRECTORY as the target (same filesystem => `rename` is atomic, no EXDEV), write, best-
/// effort `sync()`, close, `rename(temp -> target)`. Cleans up the temp on any error.
///
/// GOTCHA: `std.fs.path.dirname("out.html") == null` (bare filename). `std.fs.cwd()`
/// returns a Dir you must NOT close. Trick: `dirname(path) orelse "."` + openDir(".") =>
/// a REAL closeable dir handle. For absolute dirnames use `openDirAbsolute`.
///
/// The temp file's `*std.Io.Writer` is the SAME bridge S1 validated for stdout +
/// Writer.Allocating (`var fw = f.writer(&buf); renderDocument(…, &fw.interface)`). No
/// intermediate buffer => memory-efficient for large panes.
pub fn renderToFileAtomic(
    alloc: std.mem.Allocator,
    path: []const u8,
    ansi: []const u8,
    size: Size,
    colors: palette.Colors,
    font: ?[]const u8,
    doc: DocumentOpts,
) !void {
    const dir_path = std.fs.path.dirname(path) orelse "."; // null for bare filenames
    std.fs.cwd().makePath(dir_path) catch {}; // Issue 3: ensure parent dirs exist (idempotent; openDir below reports the real failure)
    const base = std.fs.path.basename(path);

    // Name the temp `.{base}.{rand}.tmp` next to `{base}` (same dir => same filesystem).
    var rnd: [4]u8 = undefined;
    std.crypto.random.bytes(&rnd);
    const tmp_name = try std.fmt.allocPrint(alloc, ".{s}.{x}.tmp", .{ base, @as(u32, @bitCast(rnd)) });
    defer alloc.free(tmp_name);

    // Open the target's directory as a real, closeable handle (cwd() returns one you must
    // NOT close; openDir(".") does close).
    var dir = if (std.fs.path.isAbsolute(dir_path))
        try std.fs.openDirAbsolute(dir_path, .{})
    else
        try std.fs.cwd().openDir(dir_path, .{});
    defer dir.close();

    var f = try dir.createFile(tmp_name, .{}); // truncate default
    errdefer {
        f.close();
        dir.deleteFile(tmp_name) catch {};
    }

    // The S1-validated writer bridge (works for ANY File, not just stdout).
    var buf: [8192]u8 = undefined;
    var fw = f.writer(&buf);
    try renderDocument(alloc, ansi, size, colors, null, font, doc, &fw.interface); // §8.1 envelope; sel: null (S4)
    try fw.interface.flush();
    f.sync() catch {}; // best-effort durability before rename
    f.close();

    try dir.rename(tmp_name, base); // same dir => atomic
}

/// True if a rendered selection's body (between `<pre ...>` and `</pre>`) is empty or
/// all-whitespace — i.e. the selection covered only blank cells (PRD §13 => warn, no output,
/// exit 1). The formatter emits NOTHING for blank cells (verified: a blank grid renders a
/// zero-byte body); plain unstyled text is emitted WITHOUT `<span>`, so body content (NOT
/// `<span>` presence) is the only valid emptiness signal.
///
/// Malformed HTML (no `<pre` / no `>` / no `</pre>`) is treated as NON-empty (returns false) —
/// we never false-positive a real selection into an "empty" failure.
pub fn selectionBodyEmpty(html: []const u8) bool {
    const pre = std.mem.indexOf(u8, html, "<pre") orelse return false;
    const open_end = std.mem.indexOfScalarPos(u8, html, pre, '>') orelse return false;
    const close = std.mem.indexOfPos(u8, html, open_end + 1, "</pre>") orelse return false;
    const body = html[open_end + 1 .. close];
    for (body) |c| if (!std.ascii.isWhitespace(c)) return false;
    return true;
}

/// Write a COMPLETE HTML5 document (PRD §8.1) wrapping a pre-rendered `<pre>` fragment
/// (`fragment_bytes`) to `path` ATOMICALLY (temp + rename in the same dir). Used by the
/// `--selection` path, which buffers the fragment to validate non-emptiness before writing.
/// Mirrors `renderToFileAtomic`'s atomic idiom but for already-rendered fragment bytes.
fn writeDocFileAtomic(alloc: std.mem.Allocator, path: []const u8, doc: DocumentOpts, fragment_bytes: []const u8) !void {
    const dir_path = std.fs.path.dirname(path) orelse "."; // null for bare filenames
    std.fs.cwd().makePath(dir_path) catch {}; // Issue 3: ensure parent dirs exist (idempotent)
    const base = std.fs.path.basename(path);

    var rnd: [4]u8 = undefined;
    std.crypto.random.bytes(&rnd);
    const tmp_name = try std.fmt.allocPrint(alloc, ".{s}.{x}.tmp", .{ base, @as(u32, @bitCast(rnd)) });
    defer alloc.free(tmp_name);

    var dir = if (std.fs.path.isAbsolute(dir_path))
        try std.fs.openDirAbsolute(dir_path, .{})
    else
        try std.fs.cwd().openDir(dir_path, .{});
    defer dir.close();

    var f = try dir.createFile(tmp_name, .{});
    errdefer {
        f.close();
        dir.deleteFile(tmp_name) catch {};
    }
    var buf: [8192]u8 = undefined;
    var fw = f.writer(&buf);
    try writeDocumentBytes(&fw.interface, doc, fragment_bytes);
    try fw.interface.flush();
    f.sync() catch {}; // best-effort durability before rename
    f.close();

    try dir.rename(tmp_name, base); // same dir => atomic
}

/// Write pre-rendered `bytes` to `path` ATOMICALLY (temp + rename in the same dir). Used by
/// the `--selection` path, which buffers output to validate non-emptiness before writing.
/// Mirrors `renderToFileAtomic` (S2) but for already-rendered bytes (no renderGrid call).
/// `renderToFileAtomic` itself is NOT modified (S2 owns it; it always renders the whole grid
/// with `sel: null`). Minor duplication of the atomic idiom is intentional — keeps S2's code
/// untouched (no regression to the whole-grid path).
fn writeFileAtomic(alloc: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
    const dir_path = std.fs.path.dirname(path) orelse "."; // null for bare filenames
    const base = std.fs.path.basename(path);

    var rnd: [4]u8 = undefined;
    std.crypto.random.bytes(&rnd);
    const tmp_name = try std.fmt.allocPrint(alloc, ".{s}.{x}.tmp", .{ base, @as(u32, @bitCast(rnd)) });
    defer alloc.free(tmp_name);

    var dir = if (std.fs.path.isAbsolute(dir_path))
        try std.fs.openDirAbsolute(dir_path, .{})
    else
        try std.fs.cwd().openDir(dir_path, .{});
    defer dir.close();

    var f = try dir.createFile(tmp_name, .{});
    errdefer {
        f.close();
        dir.deleteFile(tmp_name) catch {};
    }
    try f.writeAll(bytes);
    f.sync() catch {}; // best-effort durability before rename
    f.close();

    try dir.rename(tmp_name, base); // same dir => atomic
}

/// Build a temp HTML path under `$TMPDIR`/`/tmp` with 8 random bytes (P1.M3.T1.S2;
/// research/findings.md §5). VERIFIED: ends with `.html`, contains `/tmux-2html-`.
/// Caller owns the returned slice.
fn tempHtmlPath(alloc: std.mem.Allocator) ![]u8 {
    const dir = std.posix.getenv("TMPDIR") orelse "/tmp"; // posix.zig:2029, returns ?[:0]const u8
    var rnd: [8]u8 = undefined;
    std.crypto.random.bytes(&rnd); // std.crypto.random (global CSPRNG)
    const val: u64 = @bitCast(rnd);
    return std.fmt.allocPrint(alloc, "{s}/tmux-2html-{x}.html", .{ dir, val });
}

/// Spawn `argv` fully DETACHED: launch it backgrounded via `/bin/sh` so THIS process never
/// blocks on the child and leaves no zombie.
///
/// Why (the Hyprland/Brave hang regression): on some desktops `xdg-open` launches the GUI app
/// (a browser) and then WAITS for it to exit — so a naive `child.wait()` on xdg-open froze the
/// render until the user closed the browser tab. Verified: `xdg-open <file>` on Hyprland with no
/// browser running blocks past 3 s while it waits on Brave. The OLD code assumed "xdg-open returns
/// ~immediately"; that is false whenever the opener's lifetime is tied to the app it opens.
///
/// The detach: the shell forks `argv` into the background and exits AT ONCE; we `wait()` only on
/// that transient shell (returns immediately) so it is reaped, and `argv` re-parents to init
/// (PID 1) which reaps it in turn — no zombie (the ghostty-org/ghostty#5999 concern), no block.
/// stdin/out/err are sent to /dev/null so the backgrounded child cannot hold our pty open. `env`
/// is the child's environment (`null` => inherit; tests pass a PATH-scoped map pointing at a fake
/// opener so THIS process's env is never mutated). Best-effort throughout: any failure (`/bin/sh`
/// missing, spawn error) is IGNORED — `--open` must never fail the render.
///
/// `argv[0]` is resolved by the shell (PATH unless absolute). Stack-built argv (cap 16) — fine for
/// spawnXdgOpen's 2-element argv; fail closed if a caller ever exceeds it.
fn spawnDetached(alloc: std.mem.Allocator, argv: []const []const u8, env: ?*const std.process.EnvMap) void {
    var buf: [16][]const u8 = undefined;
    buf[0] = "/bin/sh";
    buf[1] = "-c";
    buf[2] = "\"$@\" >/dev/null 2>&1 </dev/null &"; // background argv; all stdio to /dev/null
    buf[3] = "sh"; // $0 (conventional placeholder); argv becomes $1..
    var n: usize = 4;
    for (argv) |a| {
        if (n >= buf.len) return; // argv too long for the stack buffer => ignore (graceful)
        buf[n] = a;
        n += 1;
    }
    var child = std.process.Child.init(buf[0..n], alloc); // Child.zig:215
    child.env_map = env; // null => inherit the current environment (Child.zig:54)
    child.stdin_behavior = .Ignore; // StdIo{Inherit,Ignore,Pipe,Close} (Child.zig:196)
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return; // /bin/sh missing / can't fork => ignore (graceful)
    _ = child.wait() catch return; // reap the SHELL (exits at once); argv is now init's child
}

/// Open `path` in the user's preferred app via `xdg-open`, fully detached (P1.M3.T1.S2 + the
/// Hyprland/Brave non-block fix). Best-effort: `--open` must NEVER fail the render. See
/// `spawnDetached` for why we background + reap the shell instead of `wait()`ing xdg-open.
pub fn spawnXdgOpen(path: []const u8, alloc: std.mem.Allocator) void {
    spawnDetached(alloc, &.{ "xdg-open", path }, null);
}

/// Print a one-line size-error message to stderr (P1.M3.T1.S2; research/findings.md §6).
/// Size errors map to exit 2 (NOT a Zig error trace): `run` calls this then `return 2`.
fn reportSizeError(err: SizeError) void {
    const stderr = std.fs.File.stderr();
    const msg: []const u8 = switch (err) {
        error.SizeRequired => "tmux-2html render: --cols is required when no controlling terminal is available\n",
        error.NoTty, error.IoctlFailed, error.InvalidWindowSize => "tmux-2html render: cannot determine terminal size\n",
        error.UnsupportedPlatform => "tmux-2html render: terminal size detection unsupported on this platform\n",
    };
    stderr.writeAll(msg) catch {};
}

/// The `render` subcommand body: read ANSI from stdin, render with defaultColors(), and
/// write HTML to **stdout** (default), an **`--output` file** (atomic temp+rename), or a
/// **temp file** when `--open` is given without `--output` (then spawn xdg-open).
///
/// Returns: **0** success, **1** runtime/write error, **2** size error (no tty + no
/// `--cols`, or terminal size undeterminable). Size errors print a stderr msg then `return 2`
/// (NOT a Zig error trace); write errors print a stderr msg then `return 1`.
///
/// SCOPE DISCIPLINE (S2 refines S1's minimal run; respect sibling subtasks):
///   - palette: S3 owns `palette.resolve(alloc, mode, has_tty)`; S2 uses defaultColors() only.
///   - sizing: S2 OWNS smart sizing — `--cols` required if no controlling tty (else getSize()),
///     `--rows` defaults to the input's line count. (S1 used cols orelse 80, rows orelse 24.)
///   - sel: S4 owns --selection coordinate -> Pin -> Selection; S2 passes sel: null.
///   - --output/--open: S2 OWNS atomic file write + temp-path + xdg-open.
/// `opts.font` is passed straight through to renderGrid in all three output arms.
pub fn run(alloc: std.mem.Allocator, opts: cli.RenderOpts) !u8 {
    const stdin = std.fs.File.stdin();
    const ansi = try stdin.readToEndAlloc(alloc, MAX_STDIN); // File.zig:809; caller frees.
    defer alloc.free(ansi);

    // S3: honor --palette MODE via palette.resolve (PRD §6 precedence: cached→live→default).
    // resolve is INFALLIBLE (returns Colors, NOT !Colors) => NO `try`. The allocator is the
    // FIRST arg (the contract snippet omitted it); opts.palette_mode is cli.PaletteMode, a
    // DISTINCT type from palette.Mode (identical variant names) bridged by toPaletteMode.
    const colors = palette.resolve(alloc, toPaletteMode(opts.palette_mode), palette.hasControllingTty());

    // Smart sizing (S2). determineCols: explicit --cols wins; else getSize() if a controlling
    // tty exists; else error.SizeRequired => exit 2 (with a stderr msg naming --cols).
    const cols = determineCols(opts.cols, palette.hasControllingTty()) catch |err| {
        reportSizeError(err);
        return 2; // size error
    };
    const rows = opts.rows orelse lineCount(ansi); // default = input line count
    if (rows < 1) { // explicit --rows 0 -> exit 2 (Issue 2 segfault guard); lineCount floors at >= 1
        reportSizeError(error.InvalidWindowSize);
        return 2; // size error
    }
    const size = Size{ .cols = cols, .rows = rows };

    const stderr = std.fs.File.stderr();
    // PRD §8.1: --title/--lang (S1) resolved here (S2's resolveLang). All four output arms
    // (--output/--open/stdout/--selection) reuse this `doc`, so resolving once propagates to all.
    // title: explicit --title, else "tmux-2html". lang: explicit --lang/normalize, else locale, else "en".
    // resolveLang returns a slice into module-level bcp47_buf (or "en"); both static — no free.
    const title = opts.title orelse "tmux-2html";
    const lang = resolveLang(opts.lang);
    const doc = DocumentOpts{ .title = title, .lang = lang, .background = colors.background };
    if (opts.selection) |coords| {
        // S1 (P1.M4.T1.S1): --selection renders only the inclusive sub-grid (PRD §5.1/§7.4).
        // Render to a buffer so we can (a) detect an empty/zero-cell selection (PRD §13 => no
        // output, exit 1) and (b) route the SAME bytes to any sink. renderGrid builds the native
        // Selection internally. The non-selection path (below) is byte-identical to before.
        var aw = std.Io.Writer.Allocating.initCapacity(alloc, 4096) catch {
            stderr.writeAll("tmux-2html render: out of memory\n") catch {};
            return 1;
        };
        defer aw.deinit();
        renderGrid(alloc, ansi, size, colors, coords, opts.font, &aw.writer) catch |err| switch (err) {
            error.OutOfRange => {
                stderr.writeAll("tmux-2html render: selection out of range\n") catch {};
                return 1;
            },
            else => {
                stderr.writeAll("tmux-2html render: write failed\n") catch {};
                return 1;
            },
        };
        const html = aw.writer.buffered(); // slice into aw's buffer; used before defer aw.deinit()
        if (selectionBodyEmpty(html)) {
            stderr.writeAll("tmux-2html render: selection is empty\n") catch {};
            return 1;
        }
        if (opts.output) |path| {
            writeDocFileAtomic(alloc, path, doc, html) catch {
                stderr.writeAll("tmux-2html render: cannot write output file\n") catch {};
                return 1;
            };
            if (opts.open) spawnXdgOpen(path, alloc);
        } else if (opts.open) {
            const tmp = tempHtmlPath(alloc) catch {
                stderr.writeAll("tmux-2html render: cannot allocate temp path\n") catch {};
                return 1;
            };
            defer alloc.free(tmp);
            writeDocFileAtomic(alloc, tmp, doc, html) catch {
                stderr.writeAll("tmux-2html render: cannot write temp file\n") catch {};
                return 1;
            };
            spawnXdgOpen(tmp, alloc);
        } else {
            // stdout: wrap the fragment in the §8.1 document and write it.
            var out_file = std.fs.File.stdout();
            var sbuf: [4096]u8 = undefined;
            var fw = out_file.writer(&sbuf);
            writeDocumentBytes(&fw.interface, doc, html) catch {
                stderr.writeAll("tmux-2html render: write failed\n") catch {};
                return 1;
            };
            fw.interface.flush() catch {
                stderr.writeAll("tmux-2html render: write failed\n") catch {};
                return 1;
            };
        }
        return 0;
    }
    if (opts.output) |path| {
        // --output: write the file ATOMICALLY (temp + rename in the same dir).
        renderToFileAtomic(alloc, path, ansi, size, colors, opts.font, doc) catch {
            stderr.writeAll("tmux-2html render: cannot write output file\n") catch {};
            return 1;
        };
        if (opts.open) spawnXdgOpen(path, alloc); // --output + --open => open the written file
    } else if (opts.open) {
        // --open without --output: materialize a temp file, write it, open it.
        const tmp = tempHtmlPath(alloc) catch {
            stderr.writeAll("tmux-2html render: cannot allocate temp path\n") catch {};
            return 1;
        };
        defer alloc.free(tmp);
        renderToFileAtomic(alloc, tmp, ansi, size, colors, opts.font, doc) catch {
            stderr.writeAll("tmux-2html render: cannot write temp file\n") catch {};
            return 1;
        };
        spawnXdgOpen(tmp, alloc);
    } else {
        // stdout: emit the COMPLETE §8.1 document (envelope + fragment).
        var out_file = std.fs.File.stdout();
        var sbuf: [4096]u8 = undefined;
        var fw = out_file.writer(&sbuf);
        defer fw.interface.flush() catch {};
        renderDocument(alloc, ansi, size, colors, null, opts.font, doc, &fw.interface) catch {
            stderr.writeAll("tmux-2html render: write failed\n") catch {};
            return 1;
        };
    }
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

/// Helper: render ANSI into an allocating buffer WITH a selection, returning an OWNED copy
/// (caller frees). Same use-after-free rationale as `renderToOwned` (Allocating.deinit frees
/// the buffer that `buffered()` points into).
fn renderSelOwned(ansi: []const u8, size: Size, coords: cli.SelectionCoords) ![]u8 {
    var aw = try std.Io.Writer.Allocating.initCapacity(std.testing.allocator, 4096);
    defer aw.deinit();
    try renderGrid(
        std.testing.allocator,
        ansi,
        size,
        palette.defaultColors(),
        coords,
        "monospace",
        &aw.writer,
    );
    return std.testing.allocator.dupe(u8, aw.writer.buffered());
}

/// Helper (P3.M2.T2.S2): format a NATIVE ghostty Selection (the output of toGhosttySelection)
/// against an ALREADY-LOADED screen into an allocating buffer, returning an OWNED copy (caller
/// frees). CRITICAL: the Selection's pins MUST be valid for THIS screen (pins are tied to the
/// specific PageList they were created from) — so the caller passes the SAME screen it built the
/// Selection against. This is the toGhosttySelection equivalent of renderSelOwned (which takes
/// cli.SelectionCoords); it lets the S2 Terminal-scope tests FORMAT a toGhosttySelection result
/// and assert on the HTML. No internal Terminal (the screen is the caller's).
fn formatSelOnScreen(screen: *const Screen, gs: ?Selection) ![]u8 {
    var aw = try std.Io.Writer.Allocating.initCapacity(std.testing.allocator, 4096);
    defer aw.deinit();
    var f = fmt.ScreenFormatter.init(screen, .{
        .emit = .html,
        .background = palette.defaultColors().background,
        .foreground = palette.defaultColors().foreground,
        .palette = &palette.defaultColors().palette,
        .font = "monospace",
    });
    f.content = .{ .selection = gs };
    f.extra = .styles;
    try aw.writer.print("{f}", .{f});
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

    // ---- S2 atomic-file round-trip (renderToFileAtomic) lives HERE, not in its own test, ----
    // because ghostty-vt's Terminal.init corrupts process-global state across SEPARATE test
    // functions (see the GOTCHA at the top). renderToFileAtomic calls renderGrid =>
    // Terminal.init, so its assertions MUST share this single Terminal.init scope. This block
    // proves (1) the target is written with valid HTML, (2) the red span survived the file
    // bridge, (3) --font flows into font-family, (4) no leak under std.testing.allocator.
    // (Atomicity / no-`.tmp`-left is verified end-to-end by the Level-3 `ls` integration check;
    // Dir.iterate returns error.Unexpected under this test runner so it can't be asserted here.)
    const falloc = std.testing.allocator;
    var ftmp = std.testing.tmpDir(.{});
    defer ftmp.cleanup();
    const fdir_abs = try ftmp.dir.realpathAlloc(falloc, ".");
    defer falloc.free(fdir_abs);
    const fabs = try std.fmt.allocPrint(falloc, "{s}/out.html", .{fdir_abs});
    defer falloc.free(fabs);
    try renderToFileAtomic(falloc, fabs, "\x1b[31mred\x1b[0m", .{ .cols = 40, .rows = 5 }, palette.defaultColors(), "Fira Code", .{ .title = "tmux-2html", .background = palette.defaultColors().background });
    var ff = try ftmp.dir.openFile("out.html", .{});
    defer ff.close();
    const fhtml = try ff.readToEndAlloc(falloc, 1 << 20);
    defer falloc.free(fhtml);
    // §8.1 envelope: the file is a COMPLETE document, not a bare fragment.
    try std.testing.expect(std.mem.startsWith(u8, fhtml, "<!DOCTYPE html>"));
    try std.testing.expect(std.mem.indexOf(u8, fhtml, "<html") != null);
    try std.testing.expect(std.mem.indexOf(u8, fhtml, "<meta charset=\"utf-8\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, fhtml, "<title>tmux-2html</title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, fhtml, "<body>") != null);
    try std.testing.expect(std.mem.indexOf(u8, fhtml, "</html>") != null);
    try std.testing.expect(std.mem.indexOf(u8, fhtml, "<pre") != null);
    try std.testing.expect(std.mem.indexOf(u8, fhtml, ">red</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, fhtml, "font-family: Fira Code") != null);
    // Atomicity: the target exists (proves the rename completed). We do NOT iterate the dir
    // here because ghostty-vt's Terminal.init corrupts process-global state such that a
    // subsequent Dir.iterate in the SAME test scope crashes (verified). The no-`.tmp`-left
    // guarantee is structural (rename is the last step; errdefer deletes the temp) and is
    // proven end-to-end by the Level-3 integration test (`ls /tmp/.t2h-out.html.*.tmp`).
    _ = try ftmp.dir.statFile("out.html");

    // ---- S1 (P1.M4.T1.S1) selection sub-grid rendering — APPENDED here (NOT a new test fn), ----
    // because ghostty-vt's Terminal.init corrupts process-global state across SEPARATE test
    // functions (the GOTCHA at the top). Sequential renderGrid calls in the SAME scope are
    // fine. These exercise buildSelection (via renderGrid): linewise, block, and out-of-range.

    // LINEWISE: 6 rows R0..R5, select rows 1..5  =>  R1..R5 present, R0 absent.
    const lw = try renderSelOwned("R0\nR1\nR2\nR3\nR4\nR5", .{ .cols = 80, .rows = 6 },
        .{ .x1 = 0, .y1 = 1, .x2 = 79, .y2 = 5 });
    defer std.testing.allocator.free(lw);
    try std.testing.expect(std.mem.indexOf(u8, lw, "R1") != null);
    try std.testing.expect(std.mem.indexOf(u8, lw, "R5") != null);
    try std.testing.expect(std.mem.indexOf(u8, lw, "R0") == null); // row 0 excluded

    // BLOCK: 3 rows of ABCDEFGHIJ, select cols 2..5 rows 0..2  =>  CDEF present, full row absent.
    const blk = try renderSelOwned("ABCDEFGHIJ\nABCDEFGHIJ\nABCDEFGHIJ", .{ .cols = 10, .rows = 3 },
        .{ .x1 = 2, .y1 = 0, .x2 = 5, .y2 = 2, .rect = true });
    defer std.testing.allocator.free(blk);
    try std.testing.expect(std.mem.indexOf(u8, blk, "CDEF") != null);
    try std.testing.expect(std.mem.indexOf(u8, blk, "ABCDEFGHIJ") == null); // only the block cols

    // OUT OF RANGE: x=9 with --cols 5 (x >= cols) => error.OutOfRange from renderGrid directly.
    var aw_oor = try std.Io.Writer.Allocating.initCapacity(std.testing.allocator, 64);
    defer aw_oor.deinit();
    try std.testing.expectError(error.OutOfRange, renderGrid(std.testing.allocator, "AB",
        .{ .cols = 5, .rows = 2 }, palette.defaultColors(), .{ .x1 = 9, .y1 = 0, .x2 = 9, .y2 = 0 },
        "monospace", &aw_oor.writer));

    // ---- S2 (P3.M2.T2.S2) toGhosttySelection / gridLastRow / wholeGridSelection assertions ----
    // APPENDED here (NOT a new test fn) because toGhosttySelection/gridLastRow/wholeGridSelection
    // touch the LOADED screen => they need a Terminal in scope => the ghostty-vt cross-test GOTCHA
    // applies (a Terminal.init in a SEPARATE test fn crashes). These build their OWN Terminal
    // (via formatSelOnScreen + inline Terminal.init) within THIS shared scope. Each block sets
    // up a select.Sel by hand (.anchor/.cursor/.mode — NO input/motion import), calls
    // toGhosttySelection, and verifies via pin->pointFromPin round-trip + ScreenFormatter output.

    // (S2-a) LINEWISE: 6 rows R0..R5, sel linewise anchor(0,1) cursor(0,5) cols=80.
    //   toGhosttySelection -> Selection whose start/end pins round-trip to {0,1}/{79,5},
    //   rectangle==false. Formatting it emits R1..R5, NOT R0 (reuses the S1 golden shape).
    {
        var t = try Terminal.init(std.testing.allocator, .{ .cols = 80, .rows = 6 });
        defer t.deinit(std.testing.allocator);
        var stream = t.vtStream();
        defer stream.deinit();
        for ("R0\nR1\nR2\nR3\nR4\nR5") |c| {
            if (c == '\n') try stream.next('\r');
            try stream.next(c);
        }
        const screen = t.screens.active;
        const sel = select.Sel{
            .anchor = .{ .x = 0, .y = 1 },
            .cursor = .{ .x = 0, .y = 5 },
            .mode = .linewise,
        };
        const gs = toGhosttySelection(sel, screen, 80);
        // Pin round-trip: gs.start()/end() -> pointFromPin(.screen, pin) -> coord().
        const s = screen.pages.pointFromPin(.screen, gs.start()).?.coord();
        const e = screen.pages.pointFromPin(.screen, gs.end()).?.coord();
        try std.testing.expectEqual(@as(u16, 0), s.x); // linewise start x = 0
        try std.testing.expectEqual(@as(u32, 1), s.y); // start row = 1
        try std.testing.expectEqual(@as(u16, 79), e.x); // linewise end x = cols-1 = 79
        try std.testing.expectEqual(@as(u32, 5), e.y); // end row = 5
        try std.testing.expectEqual(false, gs.rectangle);
        // Format the Selection -> HTML has R1..R5, NOT R0.
        const html = try formatSelOnScreen(screen, gs);
        defer std.testing.allocator.free(html);
        try std.testing.expect(std.mem.indexOf(u8, html, "R1") != null);
        try std.testing.expect(std.mem.indexOf(u8, html, "R5") != null);
        try std.testing.expect(std.mem.indexOf(u8, html, "R0") == null); // row 0 excluded
    }

    // (S2-b) BLOCK: 3 rows of ABCDEFGHIJ, sel block anchor(2,0) cursor(5,2) cols=10.
    //   -> Selection start/end pins round-trip to {2,0}/{5,2}, rectangle==true.
    //   Formatting it emits "CDEF", NOT full rows.
    {
        var t = try Terminal.init(std.testing.allocator, .{ .cols = 10, .rows = 3 });
        defer t.deinit(std.testing.allocator);
        var stream = t.vtStream();
        defer stream.deinit();
        for ("ABCDEFGHIJ\nABCDEFGHIJ\nABCDEFGHIJ") |c| {
            if (c == '\n') try stream.next('\r');
            try stream.next(c);
        }
        const screen = t.screens.active;
        const sel = select.Sel{
            .anchor = .{ .x = 2, .y = 0 },
            .cursor = .{ .x = 5, .y = 2 },
            .mode = .block,
        };
        const gs = toGhosttySelection(sel, screen, 10);
        const s = screen.pages.pointFromPin(.screen, gs.start()).?.coord();
        const e = screen.pages.pointFromPin(.screen, gs.end()).?.coord();
        try std.testing.expectEqual(@as(u16, 2), s.x);
        try std.testing.expectEqual(@as(u32, 0), s.y);
        try std.testing.expectEqual(@as(u16, 5), e.x);
        try std.testing.expectEqual(@as(u32, 2), e.y);
        try std.testing.expectEqual(true, gs.rectangle);
        const html = try formatSelOnScreen(screen, gs);
        defer std.testing.allocator.free(html);
        try std.testing.expect(std.mem.indexOf(u8, html, "CDEF") != null);
        try std.testing.expect(std.mem.indexOf(u8, html, "ABCDEFGHIJ") == null); // only the block cols
    }

    // (S2-c) CLAMP (the TUI delta): sel linewise with cursor.y BEYOND the grid (100 on a 6-row
    //   grid) -> toGhosttySelection CLAMPS y to gridLastRow (5) instead of error.OutOfRange.
    //   Contrast: the CLI --selection path (above) errors on out-of-range. (No assertError here.)
    {
        var t = try Terminal.init(std.testing.allocator, .{ .cols = 80, .rows = 6 });
        defer t.deinit(std.testing.allocator);
        var stream = t.vtStream();
        defer stream.deinit();
        for ("R0\nR1\nR2\nR3\nR4\nR5") |c| {
            if (c == '\n') try stream.next('\r');
            try stream.next(c);
        }
        const screen = t.screens.active;
        try std.testing.expectEqual(@as(u32, 5), gridLastRow(screen)); // 6 rows => last index 5
        const sel = select.Sel{
            .anchor = .{ .x = 0, .y = 1 },
            .cursor = .{ .x = 0, .y = 100 }, // BEYOND the grid
            .mode = .linewise,
        };
        const gs = toGhosttySelection(sel, screen, 80); // infallible: clamps, no error
        const s = screen.pages.pointFromPin(.screen, gs.start()).?.coord();
        const e = screen.pages.pointFromPin(.screen, gs.end()).?.coord();
        try std.testing.expectEqual(@as(u32, 1), s.y); // start row = 1
        try std.testing.expectEqual(@as(u32, 5), e.y); // end row CLAMPED 100 -> 5
        try std.testing.expectEqual(false, gs.rectangle);
    }

    // (S2-d) INACTIVE => whole-grid: sel mode=.none -> a whole-grid Selection spanning
    //   top-left..bottom-right (formatting it emits the FULL grid). extent() returns null when
    //   mode==.none, so toGhosttySelection falls back to wholeGridSelection.
    {
        var t = try Terminal.init(std.testing.allocator, .{ .cols = 10, .rows = 2 });
        defer t.deinit(std.testing.allocator);
        var stream = t.vtStream();
        defer stream.deinit();
        for ("AB\nCD") |c| {
            if (c == '\n') try stream.next('\r');
            try stream.next(c);
        }
        const screen = t.screens.active;
        const sel = select.Sel{ .mode = .none }; // inactive
        try std.testing.expect(!sel.active());
        const gs = toGhosttySelection(sel, screen, 10);
        // whole-grid: start = top-left (0,0), end = bottom-right. A 2x10 grid => end {9,1}.
        const s = screen.pages.pointFromPin(.screen, gs.start()).?.coord();
        const e = screen.pages.pointFromPin(.screen, gs.end()).?.coord();
        try std.testing.expectEqual(@as(u16, 0), s.x);
        try std.testing.expectEqual(@as(u32, 0), s.y);
        try std.testing.expectEqual(@as(u16, 9), e.x); // cols-1
        try std.testing.expectEqual(@as(u32, 1), e.y); // gridLastRow
        try std.testing.expectEqual(false, gs.rectangle);
        // Formatting the whole-grid Selection emits BOTH rows (full grid).
        const html = try formatSelOnScreen(screen, gs);
        defer std.testing.allocator.free(html);
        try std.testing.expect(std.mem.indexOf(u8, html, "AB") != null);
        try std.testing.expect(std.mem.indexOf(u8, html, "CD") != null);
    }

    // (S2-e) WIDE-CELL ATOMICITY (PRD §13 by DELEGATION): feed a wide glyph (真 U+771F =
    //   UTF-8 e7 9c 9f) at col 0 (occupies cols 0-1; col 1 is spacer_tail) into cols=4 rows=1;
    //   sel linewise covering row 0. The Selection's start pin maps to x=0 (the .wide cell).
    //   Formatting it emits the glyph EXACTLY ONCE (the formatter rounds start back from
    //   spacer_tail + skips spacers in emission; S2 did nothing special). This PROVES PRD §13
    //   is satisfied by delegation to the formatter, NOT by S2 hand-rolling rounding.
    {
        var t = try Terminal.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
        defer t.deinit(std.testing.allocator);
        var stream = t.vtStream();
        defer stream.deinit();
        for ("\xe7\x9c\x9f") |c| try stream.next(c); // 真
        const screen = t.screens.active;
        const sel = select.Sel{
            .anchor = .{ .x = 0, .y = 0 },
            .cursor = .{ .x = 0, .y = 0 },
            .mode = .linewise,
        };
        const gs = toGhosttySelection(sel, screen, 4);
        // Format the Selection -> the wide glyph appears EXACTLY ONCE. The formatter HTML-encodes
        // the codepoint as a NUMERIC character reference (&#30495; for 真 U+771F), so we count
        // THAT (not the raw UTF-8 bytes). The spacer cell (col 1) emits NOTHING (formatter skips
        // spacers), so the glyph appears exactly once — proving PRD §13 atomicity by DELEGATION
        // (S2 did nothing special; the formatter rounds start back from spacer_tail + skips
        // spacers in emission).
        const html = try formatSelOnScreen(screen, gs);
        defer std.testing.allocator.free(html);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, html, "&#30495;"));
        // Sanity: the raw UTF-8 bytes do NOT appear (the formatter encoded them).
        try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, html, "\xe7\x9c\x9f"));
    }

    // ---- scrollback retention regression (ghostty max_scrollback is BYTES, not rows) ----
    // Feeding MANY more lines than `rows` must keep the WHOLE scrollback, not just the tail.
    // Terminal.init defaults max_scrollback to 10_000 BYTES (~10 KiB), which prunes almost
    // everything; scrollbackBytes(ansi, cols) sizes it to the content. 400 lines into a
    // 5-row terminal => BOTH the first (L000) and last (L399) survive. Without the fix, L000
    // (and ~375 earlier rows) are pruned and only the tail remains.
    {
        const a = std.testing.allocator;
        var synth: std.ArrayList(u8) = .{};
        defer synth.deinit(a);
        var i: usize = 0;
        while (i < 400) : (i += 1) {
            try synth.writer(a).print("L{d:0>3}", .{i});
            try synth.append(a, '\n');
        }
        var aw = try std.Io.Writer.Allocating.initCapacity(a, 1 << 20);
        defer aw.deinit();
        try renderGrid(a, synth.items, .{ .cols = 40, .rows = 5 }, palette.defaultColors(), null, null, &aw.writer);
        const out = try a.dupe(u8, aw.writer.buffered());
        defer a.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "L000") != null); // first line retained
        try std.testing.expect(std.mem.indexOf(u8, out, "L399") != null); // last line retained
    }
}

// ---- S2 unit tests (PURE helpers + atomic round-trip; NO stdin, NO tty, NO xdg) ----
// Pattern (research/findings.md §2/§3/§4/§5): the size/line/temp helpers are pure and
// deterministic, so they are unit-asserted directly. renderToFileAtomic's HTML/font round-trip
// lives inside the single renderGrid test scope (ghostty-vt corrupts state across separate
// test functions). determineCols's has_tty=true branch opens the REAL /dev/tty and is NOT
// asserted on in CI (the `setsid` integration exit-2 test covers that path). renderGrid's own
// tests are S1's — unchanged.

test "determineCols: explicit cols wins (never probes the tty)" {
    // The explicit-cols branch returns immediately; has_tty is irrelevant here.
    try std.testing.expectEqual(@as(u16, 80), try determineCols(80, false));
    try std.testing.expectEqual(@as(u16, 120), try determineCols(120, true)); // explicit; getSize NOT called
    try std.testing.expectEqual(@as(u16, 1), try determineCols(1, false));
}

test "determineCols: no tty + no cols => error.SizeRequired" {
    // The deterministic no-tty path (the `setsid` integration test exercises this end-to-end).
    try std.testing.expectError(error.SizeRequired, determineCols(null, false));
    // NOTE: determineCols(null, true) calls the REAL getSize (opens /dev/tty) — never assert
    // its value in a unit test (CI has no controlling tty; that path is integration-tested).
}

test "determineCols: explicit --cols 0 is rejected (Issue 2: zero-dimension segfault guard)" {
    // An explicit --cols 0 must NOT reach Terminal.init (ghostty-vt segfaults on a zero-width
    // terminal). determineCols rejects it with error.InvalidWindowSize, which run() maps to
    // exit 2 + a stderr message (no segfault). The explicit arm returns before the has_tty
    // branch, so getSize is never called => safe to assert both. Boundary value 1 is accepted.
    try std.testing.expectError(error.InvalidWindowSize, determineCols(0, false));
    try std.testing.expectError(error.InvalidWindowSize, determineCols(0, true));
    try std.testing.expectEqual(@as(u16, 1), try determineCols(1, false));
}

test "lineCount: counts input lines" {
    try std.testing.expectEqual(@as(u16, 1), lineCount(""));
    try std.testing.expectEqual(@as(u16, 2), lineCount("a\nb\n"));
    try std.testing.expectEqual(@as(u16, 2), lineCount("a\nb")); // trailing partial line
    try std.testing.expectEqual(@as(u16, 1), lineCount("hello"));
    try std.testing.expectEqual(@as(u16, 3), lineCount("a\nb\nc\n"));
    try std.testing.expectEqual(@as(u16, 3), lineCount("a\nb\nc"));
}

test "lineCount: many lines clamp to maxInt(u16)" {
    // Build a string with > 65535 newlines; lineCount must clamp, not overflow.
    const alloc = std.testing.allocator;
    const big = try alloc.alloc(u8, 70000);
    defer alloc.free(big);
    @memset(big, '\n');
    try std.testing.expectEqual(@as(u16, std.math.maxInt(u16)), lineCount(big));
}

test "tempHtmlPath: ends with .html and contains /tmux-2html-" {
    const alloc = std.testing.allocator;
    const p = try tempHtmlPath(alloc);
    defer alloc.free(p);
    try std.testing.expect(std.mem.endsWith(u8, p, ".html"));
    try std.testing.expect(std.mem.indexOf(u8, p, "/tmux-2html-") != null);
}

/// cli.PaletteMode -> palette.Mode bridge (P1.M3.T1.S3). The two enums are DISTINCT types
/// by design (cli.zig must stay ghostty-free; palette.zig must NOT import cli.zig) but
/// share variant names. resolve() takes palette.Mode; opts.palette_mode is cli.PaletteMode.
/// A switch (not @intFromEnum/@enumFromInt) is robust to declaration reordering and
/// self-documents the 1:1 mapping.
fn toPaletteMode(m: cli.PaletteMode) palette.Mode {
    return switch (m) {
        .default => .default,
        .cached => .cached,
        .live => .live,
    };
}

test "spawnXdgOpen: does not crash on a bogus path (xdg-open absent => ignored)" {
    // With the detached impl we spawn /bin/sh (always present) and run `xdg-open <bogus>` in the
    // background; xdg-open absent (CI) => the background job fails silently (stdio to /dev/null),
    // the shell exits, we reap it. Either way this must not crash or leak (spawnXdgOpen takes the
    // allocator only for Child.init, which does not retain it after wait/return).
    spawnXdgOpen("/nonexistent", std.testing.allocator);
}

test "spawnDetached: returns promptly even when the child blocks (xdg-open→browser hang)" {
    // REGRESSION for the Hyprland/Brave hang: xdg-open launched the browser and WAITED on it, so a
    // naive child.wait() froze the render until the user closed the tab. spawnDetached backgrounds
    // the child and reaps only the throwaway shell, so it MUST return far sooner than the fake
    // opener's 10 s sleep. The fake is a real "xdg-open" reached via a PATH scoped to the CHILD
    // ONLY (passed as child.env_map; this process's PATH is untouched => sibling tests are
    // unaffected). The opener records its PID so the lingering sleeper is reaped, not left behind.
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_abs = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_abs);
    const marker = try std.fmt.allocPrint(alloc, "{s}/pid", .{dir_abs});
    defer alloc.free(marker);

    // Fake "xdg-open": write its PID ($$), then block 10 s (a browser that won't exit). +x via mode.
    {
        var f = try tmp.dir.createFile("xdg-open", .{ .mode = 0o755 });
        defer f.close();
        try f.writeAll("#!/bin/sh\necho $$ > \"$1\"\nsleep 10\n");
    }

    // Child-only env: a copy of this env with PATH narrowed to find BOTH the fake opener and
    // `sleep`. EnvMap.put COPIES its args, so free the temp slice after the put.
    var env = try std.process.getEnvMap(alloc);
    defer env.deinit();
    const path_val = try std.fmt.allocPrint(alloc, "{s}:/usr/bin:/bin", .{dir_abs});
    defer alloc.free(path_val);
    try env.put("PATH", path_val);
    const env_ptr: *const std.process.EnvMap = &env;

    // The deadline proof: must return in ≪ 10 s. 3 s is generous for fork+exec+shell-exit on any
    // CI box and 3× under the sleeper — a blocking (pre-fix) implementation would blow through it.
    const start = std.time.Instant.now() catch unreachable;
    spawnDetached(alloc, &.{ "xdg-open", marker }, env_ptr);
    const elapsed_ns = (std.time.Instant.now() catch unreachable).since(start);
    if (elapsed_ns >= 3 * std.time.ns_per_s) {
        std.debug.print(
            "\n[spawnDetached] BLOCKED on the child: {d}ms elapsed (expected <3000; sleeper=10s)\n",
            .{elapsed_ns / std.time.ns_per_ms},
        );
        return error.TestUnexpected;
    }

    // Hygiene: reap the lingering sleeper. It re-parented to init when its shell exited, so poll
    // briefly for the PID marker (the opener writes it almost immediately) and signal it. A miss
    // is harmless — the sleeper self-exits after its (short) sleep; this just keeps the box clean.
    var pid_bytes: ?[]u8 = null;
    defer if (pid_bytes) |b| alloc.free(b);
    var attempts: usize = 0;
    while (attempts < 200 and pid_bytes == null) : (attempts += 1) {
        if (std.fs.cwd().readFileAlloc(alloc, marker, 64)) |b| {
            pid_bytes = b;
        } else |_| {
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }
    if (pid_bytes) |b| {
        const pid_str = std.mem.trim(u8, b, " \t\n\r");
        if (std.fmt.parseInt(std.posix.pid_t, pid_str, 10)) |pid| {
            _ = std.posix.kill(pid, std.posix.SIG.TERM) catch {};
        } else |_| {}
    }
}

// ---- S3 unit test (the bridge; PURE — no tty, no stdin, no ghostty-vt init) ----
// resolve's own precedence is already exhaustively covered by palette.zig's 7 resolve/
// resolveDir tests. The bridge is the ONLY new logic in render.zig, so testing it here is
// sufficient + cheap. This does NOT call renderGrid and does NOT spawn ghostty-vt
// Terminal, so it does NOT collide with the S1 single-renderGrid-test-scope GOTCHA.
// Assert enum tags (NOT hex values) — the Colors values are palette.zig's responsibility.

test "toPaletteMode: maps all three cli.PaletteMode variants to palette.Mode" {
    try std.testing.expectEqual(palette.Mode.default, toPaletteMode(.default));
    try std.testing.expectEqual(palette.Mode.cached, toPaletteMode(.cached));
    try std.testing.expectEqual(palette.Mode.live, toPaletteMode(.live));
}

// ---- S1 (P1.M4.T1.S1) PURE unit tests (selectionBodyEmpty + writeFileAtomic) ----
// These do NOT touch ghostty-vt Terminal, so they get their OWN test functions (the
// cross-test GOTCHA only affects Terminal.init scopes).

test "selectionBodyEmpty: blank body => true; content => false" {
    // Zero-byte body (blank grid => <pre ...></pre>).
    try std.testing.expect(selectionBodyEmpty("<pre class=\"x\" style=\"a:b;\"></pre>"));
    // All-whitespace body.
    try std.testing.expect(selectionBodyEmpty("<pre class=\"x\">   \n  \t </pre>"));
    // Plain text body.
    try std.testing.expect(!selectionBodyEmpty("<pre class=\"x\">hi</pre>"));
    // Styled-span body (plain text may lack a span, so body content — NOT span presence — is
    // the only valid emptiness signal).
    try std.testing.expect(!selectionBodyEmpty("<pre class=\"x\"><span style=\"color:#fff;\">A</span></pre>"));
    // Malformed HTML (no <pre tag at all) => treat as NON-empty (never false-positive).
    try std.testing.expect(!selectionBodyEmpty("no pre tag at all"));
}

test "writeFileAtomic: writes target, leaves no .tmp" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_abs);
    const abs = try std.fmt.allocPrint(alloc, "{s}/out.html", .{dir_abs});
    defer alloc.free(abs);
    try writeFileAtomic(alloc, abs, "<pre>BODY</pre>");
    var f = try tmp.dir.openFile("out.html", .{});
    defer f.close();
    const got = try f.readToEndAlloc(alloc, 1 << 16);
    defer alloc.free(got);
    try std.testing.expectEqualStrings("<pre>BODY</pre>", got);
    // Atomicity: the target exists with the exact bytes (proves the rename completed). We do
    // NOT iterate the dir here because Zig 0.15.2's Dir.iterate panics under std.testing.tmpDir
    // (EBADF in lseek_SET — the dir isn't opened with iteration permissions). The no-`.tmp`-left
    // guarantee is structural (rename is the last step; errdefer deletes the temp on any error)
    // and is proven end-to-end by the Level-3 integration check.
    _ = try tmp.dir.statFile("out.html");
}

test "writeDocFileAtomic: creates nested parent dirs (Issue 3: render --output)" {
    // writeDocFileAtomic shares the IDENTICAL dir_path + openDir structure as renderToFileAtomic,
    // so it proves the makePath fix for the atomic-write idiom. It does NOT touch Terminal
    // (render.zig:838 GOTCHA), so it is safe as its own test fn — unlike renderToFileAtomic.
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_abs);
    // nested/deep/ does NOT exist under tmp — makePath must create it.
    const nested = try std.fmt.allocPrint(alloc, "{s}/nested/deep/out.html", .{dir_abs});
    defer alloc.free(nested);
    try writeDocFileAtomic(alloc, nested, .{ .title = "t" }, "<pre>NESTED</pre>");

    // File created with a valid §8.1 document (DOCTYPE first, fragment present, closes </html>).
    var f = try tmp.dir.openFile("nested/deep/out.html", .{});
    defer f.close();
    const got = try f.readToEndAlloc(alloc, 1 << 16);
    defer alloc.free(got);
    try std.testing.expect(std.mem.startsWith(u8, got, "<!DOCTYPE html>"));
    try std.testing.expect(std.mem.indexOf(u8, got, "<pre>NESTED</pre>") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "</html>") != null);
}

// ---- §8.1 HTML document envelope unit tests (PURE/IO-only -> separate test fns) ----
// writeEscaped/writeDocument/writeDocumentBytes do NOT touch ghostty-vt Terminal => they are
// safe as separate test fns (the cross-test GOTCHA only affects Terminal.init scopes). They
// verify the PRD §8.1 normative requirements: DOCTYPE first, charset first in <head>, viewport,
// escaped <title>, <body> wrapping the fragment, page bg from the resolved terminal background.

test "writeEscaped: escapes & < > \" ' and passes through safe bytes" {
    var aw = try std.Io.Writer.Allocating.initCapacity(std.testing.allocator, 256);
    defer aw.deinit();
    try writeEscaped(&aw.writer, "a<b>&\"'\xc2\xa3"); // \xc2\xa3 = £ (safe UTF-8 byte pair)
    try std.testing.expectEqualStrings("a&lt;b&gt;&amp;&quot;&#x27;\xc2\xa3", aw.writer.buffered());
}

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

test "writeDocument: full §8.1 envelope (DOCTYPE first, charset first in head, title escaped)" {
    // Fragment callback that emits a canned <pre> (no Terminal => no cross-test GOTCHA).
    const Ctx = struct {
        fn emit(_: @This(), w: *std.Io.Writer) anyerror!void {
            try w.writeAll("<pre>FRAGMENT</pre>");
        }
    };
    var aw = try std.Io.Writer.Allocating.initCapacity(std.testing.allocator, 1024);
    defer aw.deinit();
    try writeDocument(&aw.writer, .{
        .title = "a<b>&c",
        .background = .{ .r = 41, .g = 44, .b = 51 },
    }, Ctx, .{}, Ctx.emit);
    const out = aw.writer.buffered();
    // DOCTYPE is the FIRST bytes.
    try std.testing.expect(std.mem.startsWith(u8, out, "<!DOCTYPE html>"));
    // <html lang> root.
    try std.testing.expect(std.mem.indexOf(u8, out, "<html lang=\"en\">") != null);
    // charset is the FIRST element in <head> (appears before viewport/title).
    const head = std.mem.indexOf(u8, out, "<head>\n").?;
    const charset = std.mem.indexOf(u8, out, "<meta charset=\"utf-8\">").?;
    const viewport = std.mem.indexOf(u8, out, "<meta name=\"viewport").?;
    const title = std.mem.indexOf(u8, out, "<title>").?;
    try std.testing.expect(head < charset and charset < viewport and charset < title);
    // title is HTML-escaped.
    try std.testing.expect(std.mem.indexOf(u8, out, "<title>a&lt;b&gt;&amp;c</title>") != null);
    // viewport content.
    try std.testing.expect(std.mem.indexOf(u8, out, "width=device-width, initial-scale=1") != null);
    // page background = resolved terminal bg (#292c33).
    try std.testing.expect(std.mem.indexOf(u8, out, "body{background-color:#292c33;}") != null);
    // <body> wraps the fragment; document ends with </html>.
    try std.testing.expect(std.mem.indexOf(u8, out, "<body>\n<pre>FRAGMENT</pre>") != null);
    try std.testing.expect(std.mem.endsWith(u8, out, "</body>\n</html>\n"));
}

test "writeDocument: null background => no inline body bg style" {
    const Ctx = struct {
        fn emit(_: @This(), w: *std.Io.Writer) anyerror!void {
            try w.writeAll("<pre>X</pre>");
        }
    };
    var aw = try std.Io.Writer.Allocating.initCapacity(std.testing.allocator, 512);
    defer aw.deinit();
    try writeDocument(&aw.writer, .{ .title = "t" }, Ctx, .{}, Ctx.emit);
    try std.testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), "background-color:#") == null);
}

test "writeDocumentBytes: wraps a pre-rendered fragment in the full §8.1 document" {
    var aw = try std.Io.Writer.Allocating.initCapacity(std.testing.allocator, 512);
    defer aw.deinit();
    try writeDocumentBytes(&aw.writer, .{ .title = "tmux-2html" }, "<pre>PRE-RENDERED</pre>");
    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, out, "<!DOCTYPE html>"));
    try std.testing.expect(std.mem.indexOf(u8, out, "<pre>PRE-RENDERED</pre>") != null);
    try std.testing.expect(std.mem.endsWith(u8, out, "</html>\n"));
}

// ---- P3.M2.T2.S2 PURE unit tests (clampExtent — NO Terminal -> separate test fns, safe) ----
// clampExtent is PURE (no ghostty-vt state) -> it gets its OWN test functions, exactly like
// determineCols/lineCount/selectionBodyEmpty above. The cross-test GOTCHA (Terminal.init
// corrupts process-global state across SEPARATE test fns) does NOT apply here. view.Selection
// and cli.SelectionCoords are STRUCTURALLY IDENTICAL ({x1,y1,x2,y2:u32, rect:bool=false}).

test "clampExtent: linewise in-range passthrough (no clamp)" {
    const got = clampExtent(.{ .x1 = 0, .y1 = 2, .x2 = 79, .y2 = 7, .rect = false }, 80, 23);
    try std.testing.expectEqual(@as(u32, 0), got.x1);
    try std.testing.expectEqual(@as(u32, 2), got.y1);
    try std.testing.expectEqual(@as(u32, 79), got.x2);
    try std.testing.expectEqual(@as(u32, 7), got.y2);
    try std.testing.expectEqual(false, got.rect);
}

test "clampExtent: block in-range passthrough (no clamp)" {
    const got = clampExtent(.{ .x1 = 3, .y1 = 1, .x2 = 9, .y2 = 5, .rect = true }, 10, 9);
    try std.testing.expectEqual(@as(u32, 3), got.x1);
    try std.testing.expectEqual(@as(u32, 1), got.y1);
    try std.testing.expectEqual(@as(u32, 9), got.x2);
    try std.testing.expectEqual(@as(u32, 5), got.y2);
    try std.testing.expectEqual(true, got.rect);
}

test "clampExtent: x clamp high (x2 beyond grid)" {
    // x2=99 with cols=10 -> clamped to 9. x1=0 stays 0.
    const got = clampExtent(.{ .x1 = 0, .y1 = 0, .x2 = 99, .y2 = 0, .rect = false }, 10, 5);
    try std.testing.expectEqual(@as(u32, 0), got.x1);
    try std.testing.expectEqual(@as(u32, 9), got.x2); // 99 -> 9
    try std.testing.expectEqual(@as(u32, 0), got.y1);
    try std.testing.expectEqual(@as(u32, 0), got.y2);
}

test "clampExtent: y clamp high (y beyond last_row)" {
    // y1=50, y2=60 with last_row=23 -> both clamped to 23. x1=x2=0 (in-range, no clamp).
    const got = clampExtent(.{ .x1 = 0, .y1 = 50, .x2 = 0, .y2 = 60, .rect = false }, 80, 23);
    try std.testing.expectEqual(@as(u32, 23), got.y1); // 50 -> 23
    try std.testing.expectEqual(@as(u32, 23), got.y2); // 60 -> 23
    try std.testing.expectEqual(@as(u32, 0), got.x1);
    try std.testing.expectEqual(@as(u32, 0), got.x2); // x2=0 in-range (NOT clamped to last_col)
}

test "clampExtent: cols==0 guard (x collapses to 0, no u32 underflow)" {
    const got = clampExtent(.{ .x1 = 0, .y1 = 0, .x2 = 0, .y2 = 5, .rect = false }, 0, 5);
    try std.testing.expectEqual(@as(u32, 0), got.x1);
    try std.testing.expectEqual(@as(u32, 0), got.x2); // cols==0 -> 0, NOT underflow
    try std.testing.expectEqual(@as(u32, 0), got.y1);
    try std.testing.expectEqual(@as(u32, 5), got.y2);
}

test "clampExtent: order normalization (reversed input) -> min/max re-applied" {
    // Reversed input {9,7,0,2}: x1=min(9,0)=0, x2=max(9,0)=9, y1=min(7,2)=2, y2=max(7,2)=7.
    const got = clampExtent(.{ .x1 = 9, .y1 = 7, .x2 = 0, .y2 = 2, .rect = false }, 10, 9);
    try std.testing.expectEqual(@as(u32, 0), got.x1);
    try std.testing.expectEqual(@as(u32, 2), got.y1);
    try std.testing.expectEqual(@as(u32, 9), got.x2);
    try std.testing.expectEqual(@as(u32, 7), got.y2);
    try std.testing.expectEqual(false, got.rect);
}

test "clampExtent: rect=true preserved through clamp" {
    const got = clampExtent(.{ .x1 = 1, .y1 = 1, .x2 = 99, .y2 = 99, .rect = true }, 10, 5);
    try std.testing.expectEqual(true, got.rect); // rect survives the clamp
    try std.testing.expectEqual(@as(u32, 9), got.x2); // x2 clamped
    try std.testing.expectEqual(@as(u32, 5), got.y2); // y2 clamped
}

test "clampExtent: last_row==0 (degenerate) -> y collapses to 0" {
    const got = clampExtent(.{ .x1 = 0, .y1 = 5, .x2 = 0, .y2 = 5, .rect = false }, 10, 0);
    try std.testing.expectEqual(@as(u32, 0), got.y1); // 5 -> 0
    try std.testing.expectEqual(@as(u32, 0), got.y2); // 5 -> 0
    try std.testing.expectEqual(@as(u32, 0), got.x1);
    try std.testing.expectEqual(@as(u32, 0), got.x2); // x2=0 < last_col=9, no clamp needed
}

// ---- Lang resolution unit tests (PRD §8.1; architecture/lang_resolution.md) ----

test "toBcp47: en_US.UTF-8 -> en-US" {
    try std.testing.expectEqualStrings("en-US", toBcp47("en_US.UTF-8").?);
}
test "toBcp47: pt_BR.UTF-8 -> pt-BR" {
    try std.testing.expectEqualStrings("pt-BR", toBcp47("pt_BR.UTF-8").?);
}
test "toBcp47: de_DE@euro -> de-DE" {
    try std.testing.expectEqualStrings("de-DE", toBcp47("de_DE@euro").?);
}
test "toBcp47: zh_CN -> zh-CN" {
    try std.testing.expectEqualStrings("zh-CN", toBcp47("zh_CN").?);
}
test "toBcp47: plain lang en -> en" {
    try std.testing.expectEqualStrings("en", toBcp47("en").?);
}
test "toBcp47: case normalization en_us -> en-US" {
    try std.testing.expectEqualStrings("en-US", toBcp47("en_us").?);
}
test "toBcp47: already BCP-47 en-US -> en-US" {
    try std.testing.expectEqualStrings("en-US", toBcp47("en-US").?);
}
test "toBcp47: 3-letter lang eng_GB -> eng-GB" {
    try std.testing.expectEqualStrings("eng-GB", toBcp47("eng_GB").?);
}
test "toBcp47: C -> null" {
    try std.testing.expectEqual(@as(?[]const u8, null), toBcp47("C"));
}
test "toBcp47: POSIX -> null" {
    try std.testing.expectEqual(@as(?[]const u8, null), toBcp47("POSIX"));
}
test "toBcp47: C.UTF-8 -> null" {
    try std.testing.expectEqual(@as(?[]const u8, null), toBcp47("C.UTF-8"));
}
test "toBcp47: empty -> null" {
    try std.testing.expectEqual(@as(?[]const u8, null), toBcp47(""));
}
test "toBcp47: too-long lang english -> null" {
    try std.testing.expectEqual(@as(?[]const u8, null), toBcp47("english"));
}
test "toBcp47: 1-char lang e_US -> null" {
    try std.testing.expectEqual(@as(?[]const u8, null), toBcp47("e_US"));
}
test "toBcp47: 3-char region en_USA -> null" {
    try std.testing.expectEqual(@as(?[]const u8, null), toBcp47("en_USA"));
}

test "langFromEnvStrings: LC_ALL wins over LC_MESSAGES and LANG" {
    try std.testing.expectEqualStrings("en-US", langFromEnvStrings("en_US.UTF-8", "pt_BR.UTF-8", "de_DE"));
}
test "langFromEnvStrings: LC_MESSAGES when LC_ALL null" {
    try std.testing.expectEqualStrings("pt-BR", langFromEnvStrings(null, "pt_BR.UTF-8", "de_DE"));
}
test "langFromEnvStrings: LANG when LC_ALL and LC_MESSAGES null" {
    try std.testing.expectEqualStrings("de-DE", langFromEnvStrings(null, null, "de_DE@euro"));
}
test "langFromEnvStrings: all null -> en" {
    try std.testing.expectEqualStrings("en", langFromEnvStrings(null, null, null));
}
test "langFromEnvStrings: empty treated as unset -> en" {
    try std.testing.expectEqualStrings("en", langFromEnvStrings("", "", ""));
}
test "langFromEnvStrings: LC_ALL=C (invalid, no cascade) -> en" {
    try std.testing.expectEqualStrings("en", langFromEnvStrings("C", "en_US.UTF-8", "en_US.UTF-8"));
}

test "resolveLang: explicit valid wins over locale" {
    try std.testing.expectEqualStrings("fr", resolveLang("fr"));
}
test "resolveLang: explicit locale normalized" {
    try std.testing.expectEqualStrings("en-US", resolveLang("en_US.UTF-8"));
}
test "resolveLang: explicit C -> en" {
    try std.testing.expectEqualStrings("en", resolveLang("C"));
}
test "resolveLang: explicit invalid -> en" {
    try std.testing.expectEqualStrings("en", resolveLang("english"));
}
test "resolveLang: explicit null falls to env (non-empty result)" {
    // langFromEnv() reads the real host env (not deterministic); just assert validity.
    const got = resolveLang(null);
    try std.testing.expect(got.len > 0);
}

// ---- resolveLangImpl: Issue 4 (empty explicit == unset -> locale-derived) ----

test "resolveLangImpl: empty explicit derives from locale (Issue 4)" {
    // The bug: resolveLang("") used to force "en" (toBcp47("") -> null -> orelse "en").
    // The fix: empty explicit is treated as unset -> locale derivation.
    try std.testing.expectEqualStrings("de-DE", resolveLangImpl(@as(?[]const u8, ""), null, null, "de_DE.UTF-8"));
}

test "resolveLangImpl: empty explicit == null (identical locale path)" {
    // Empty and unset take the SAME code path -> identical result, for any locale.
    try std.testing.expectEqualStrings(
        resolveLangImpl(null, null, null, "pt_BR.UTF-8"),
        resolveLangImpl(@as(?[]const u8, ""), null, null, "pt_BR.UTF-8"),
    );
}

test "resolveLangImpl: empty explicit + no locale -> en" {
    try std.testing.expectEqualStrings("en", resolveLangImpl(@as(?[]const u8, ""), null, null, null));
    try std.testing.expectEqualStrings("en", resolveLangImpl(@as(?[]const u8, ""), "", "", ""));
}

test "resolveLangImpl: non-empty invalid still -> en (unchanged by Issue 4 fix)" {
    // Explicit invalid (C/english) still forces "en" — the fix does NOT change non-empty behavior,
    // and an explicit value still WINS over the locale (no cascade to LANG).
    try std.testing.expectEqualStrings("en", resolveLangImpl("C", null, null, "de_DE.UTF-8"));
    try std.testing.expectEqualStrings("en", resolveLangImpl("english", "de_DE.UTF-8", null, null));
}

test "resolveLangImpl: non-empty valid wins over locale (unchanged)" {
    try std.testing.expectEqualStrings("fr", resolveLangImpl("fr", "de_DE.UTF-8", null, null));
    try std.testing.expectEqualStrings("en-US", resolveLangImpl("en_US.UTF-8", null, null, "de_DE"));
}
