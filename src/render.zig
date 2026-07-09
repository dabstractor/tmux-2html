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
    if (opts_cols) |c| return c; // explicit --cols wins; never probes the tty
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

/// Render `ansi` to HTML and write it to `path` ATOMICALLY (P1.M3.T1.S2; research/findings.md §4).
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
/// Writer.Allocating (`var fw = f.writer(&buf); renderGrid(…, &fw.interface)`). No
/// intermediate buffer => memory-efficient for large panes.
fn renderToFileAtomic(
    alloc: std.mem.Allocator,
    path: []const u8,
    ansi: []const u8,
    size: Size,
    colors: palette.Colors,
    font: ?[]const u8,
) !void {
    const dir_path = std.fs.path.dirname(path) orelse "."; // null for bare filenames
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
    try renderGrid(alloc, ansi, size, colors, null, font, &fw.interface); // sel: null (S4)
    try fw.interface.flush();
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

/// Spawn `xdg-open <path>` and REAP it (P1.M3.T1.S2; research/findings.md §5).
///
/// CRITICAL (ghostty-org/ghostty#5999 — the project we depend on hit this exact bug):
/// spawning xdg-open WITHOUT wait() leaves zombie xdg-open processes. xdg-open returns
/// ~immediately (it hands off to the user's preferred app), so waiting never stalls the
/// render. Any failure (xdg-open missing, headless, non-zero exit) is IGNORED — `--open`
/// is best-effort ("open the output if you can; never fail the render because of it").
fn spawnXdgOpen(path: []const u8, alloc: std.mem.Allocator) void {
    var child = std.process.Child.init(&.{ "xdg-open", path }, alloc); // Child.zig:215
    child.stdin_behavior = .Ignore; // StdIo{Inherit,Ignore,Pipe,Close} (Child.zig:196)
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return; // xdg-open missing / can't spawn => ignore (graceful)
    _ = child.wait() catch return; // reap (no zombie); ignore exit status (ghostty #5999)
}

/// Print a one-line size-error message to stderr (P1.M3.T1.S2; research/findings.md §6).
/// Size errors map to exit 2 (NOT a Zig error trace): `run` calls this then `return 2`.
fn reportSizeError(err: SizeError) void {
    const stderr = std.fs.File.stderr();
    const msg: []const u8 = switch (err) {
        error.SizeRequired => "tmux-2html render: --cols is required when input is not a tty\n",
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

    const colors = palette.defaultColors(); // S3: palette.resolve(alloc, mode, palette.hasControllingTty())

    // Smart sizing (S2). determineCols: explicit --cols wins; else getSize() if a controlling
    // tty exists; else error.SizeRequired => exit 2 (with a stderr msg naming --cols).
    const cols = determineCols(opts.cols, palette.hasControllingTty()) catch |err| {
        reportSizeError(err);
        return 2; // size error
    };
    const rows = opts.rows orelse lineCount(ansi); // default = input line count
    const size = Size{ .cols = cols, .rows = rows };

    const stderr = std.fs.File.stderr();
    if (opts.output) |path| {
        // --output: write the file ATOMICALLY (temp + rename in the same dir).
        renderToFileAtomic(alloc, path, ansi, size, colors, opts.font) catch {
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
        renderToFileAtomic(alloc, tmp, ansi, size, colors, opts.font) catch {
            stderr.writeAll("tmux-2html render: cannot write temp file\n") catch {};
            return 1;
        };
        spawnXdgOpen(tmp, alloc);
    } else {
        // stdout — S1's path, verbatim (no regression).
        // NEW-IO writer bridge (research/findings.md §3, compile-validated):
        // `out_file.writer(&buf)` returns an `fs.File.Writer` WRAPPER whose `.interface` field IS
        // the `std.Io.Writer` the formatter wants. Pass `&fw.interface`, flush `fw.interface`.
        var out_file = std.fs.File.stdout();
        var sbuf: [4096]u8 = undefined;
        var fw = out_file.writer(&sbuf);
        defer fw.interface.flush() catch {};
        renderGrid(alloc, ansi, size, colors, null, opts.font, &fw.interface) catch {
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
    try renderToFileAtomic(falloc, fabs, "\x1b[31mred\x1b[0m", .{ .cols = 40, .rows = 5 }, palette.defaultColors(), "Fira Code");
    var ff = try ftmp.dir.openFile("out.html", .{});
    defer ff.close();
    const fhtml = try ff.readToEndAlloc(falloc, 1 << 20);
    defer falloc.free(fhtml);
    try std.testing.expect(std.mem.indexOf(u8, fhtml, "<pre") != null);
    try std.testing.expect(std.mem.indexOf(u8, fhtml, ">red</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, fhtml, "font-family: Fira Code") != null);
    // Atomicity: the target exists (proves the rename completed). We do NOT iterate the dir
    // here because ghostty-vt's Terminal.init corrupts process-global state such that a
    // subsequent Dir.iterate in the SAME test scope crashes (verified). The no-`.tmp`-left
    // guarantee is structural (rename is the last step; errdefer deletes the temp) and is
    // proven end-to-end by the Level-3 integration test (`ls /tmp/.t2h-out.html.*.tmp`).
    _ = try ftmp.dir.statFile("out.html");
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

test "spawnXdgOpen: does not crash on a bogus path (xdg-open absent => ignored)" {
    // Best-effort: in CI xdg-open is absent => spawn() fails => swallowed; the call returns.
    // On a desktop with xdg-open it would open /nonexistent (which xdg-open tolerates). Either
    // way this must not crash or leak (spawnXdgOpen takes the allocator only for Child.init,
    // which does not retain it after wait/return).
    spawnXdgOpen("/nonexistent", std.testing.allocator);
}
