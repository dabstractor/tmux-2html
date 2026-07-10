const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const parg = @import("parg");
const cli = @import("cli.zig");
const palette = @import("palette.zig");
const capture = @import("capture.zig");
const render_mod = @import("render.zig");
const tui = @import("tui/app.zig");

const version_string = build_options.version;

// Root panic override (PRD §7.1 "Restore on exit, always, including panic"). std detects this via
// @hasDecl(root, "panic"). The override calls tui.restoreRaw() (idempotent, guarded by the atomic
// `entered` flag ⇒ a no-op when the TUI was never entered) BEFORE std.debug.defaultPanic so a
// panic that fires while the TUI holds the terminal still restores cooked termios + primary
// screen + visible cursor (and THEN prints the stack trace in cooked mode). panic_in_progress
// guards against recursion if restoreRaw itself somehow panics.
pub const panic = std.debug.FullPanic(struct {
    fn panic(msg: []const u8, ra: ?usize) noreturn {
        if (!tui.panic_in_progress) {
            tui.panic_in_progress = true;
            tui.restoreRaw();
        }
        std.debug.defaultPanic(msg, ra);
    }
}.panic);

pub fn main() !u8 {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    return run(allocator, args);
}

fn run(allocator: std.mem.Allocator, args: [][:0]u8) !u8 {
    const stdout = std.fs.File.stdout();
    const stderr = std.fs.File.stderr();

    // parg has no native subcommand support (verified: parg parser.zig yields only
    // .flag / .arg / .unexpected_value tokens). So we peek the FIRST token after the
    // program name: it is either a global flag (--version / --help) or the subcommand
    // positional. This mirrors the term2html pattern: parse, skip program name via
    // nextValue(), then read tokens with next().
    var parser = parg.parseSlice(args, .{});
    defer parser.deinit();
    _ = parser.nextValue(); // discard args[0] (program name)

    const token = parser.next() orelse {
        // no subcommand given
        try printUsage(stderr);
        return 1;
    };

    switch (token) {
        .flag => |flag| {
            if (flag.isLong("version")) {
                try printVersion(stdout);
                return 0;
            }
            if (flag.isLong("help")) {
                try printHelp(stdout);
                return 0;
            }
            // Any other flag in command position is a usage error.
            var buf: [160]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "tmux-2html: unknown option '{s}{s}'\n", .{
                flag.kind.prefix(),
                flag.name,
            }) catch {
                try printUsage(stderr);
                return 1;
            };
            try stderr.writeAll(msg);
            try printUsage(stderr);
            return 1;
        },
        .arg => |name| {
            // The subcommand is always the first positional (args[1]); everything
            // after it (args[2..]) are that subcommand's flags/options.
            return dispatch(allocator, name, args[2..]) catch |err| switch (err) {
                error.NotImplemented => blk: {
                    try stderr.writeAll("tmux-2html: this subcommand is not yet implemented\n");
                    break :blk 1;
                },
                else => |e| return e,
            };
        },
        .unexpected_value => |u| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "tmux-2html: unexpected value '{s}'\n", .{u}) catch {
                try printUsage(stderr);
                return 1;
            };
            try stderr.writeAll(msg);
            try printUsage(stderr);
            return 1;
        },
    }
}

fn dispatch(allocator: std.mem.Allocator, name: []const u8, sub_args: []const []const u8) !u8 {
    if (std.mem.eql(u8, name, "render")) {
        return cli.render(allocator, sub_args);
    } else if (std.mem.eql(u8, name, "pane")) {
        return cli.pane(allocator, sub_args, paneBody);
    } else if (std.mem.eql(u8, name, "region")) {
        return cli.region(allocator, sub_args);
    } else if (std.mem.eql(u8, name, "sync-palette")) {
        return cli.syncPalette(allocator, sub_args, syncPaletteBody);
    }

    const stderr = std.fs.File.stderr();
    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "tmux-2html: unknown subcommand '{s}'\n", .{name});
    try stderr.writeAll(msg);
    try printUsage(stderr);
    return 1;
}

fn printVersion(out: std.fs.File) !void {
    var buf: [64]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "tmux-2html {s}\n", .{version_string});
    try out.writeAll(s);
}

// --help / usage text is the CLI doc surface (PRD §5, Mode A). Keep it accurate as
// subcommands gain real flag parsing (T3.S2+).
const usage_text =
    \\Usage: tmux-2html <subcommand> [options]
    \\       tmux-2html --version | --help
    \\
    \\Convert tmux pane output to standalone HTML.
    \\
    \\Subcommands:
    \\  render        Read ANSI from stdin, write HTML (core renderer).
    \\  pane          Capture a tmux pane and convert it to HTML.
    \\  region        Interactive copy-mode overlay: select a region, render it.
    \\  sync-palette  Query the terminal palette and cache it.
    \\
    \\Common options:
    \\  --version     Print the version and exit.
    \\  --help        Show this help.
    \\
    \\Exit codes: 0 success, 1 usage/runtime error, 2 capture/target error.
    \\
;

fn printUsage(out: std.fs.File) !void {
    try out.writeAll(usage_text);
}

fn printHelp(out: std.fs.File) !void {
    try out.writeAll(usage_text);
}

// ---- sync-palette body (PRD §5.4 + §6) --------------------------------------
// The user-facing command: acquire a palette (query /dev/tty OR load a file) and write the
// cache. Wired into cli.syncPalette via a function pointer (cli stays ghostty-free; main.zig
// is the one module allowed to import both cli and palette). The dir-scoped core
// (syncPaletteDir) is unit-tested via std.testing.tmpDir; the prod wrapper (syncPaletteBody)
// resolves the real cache dir and prints the summary.

/// Result of the dir-scoped sync core: an exit code + an allocator-owned summary line.
/// Every return path of syncPaletteDir allocates a summary; the caller frees it.
const SyncResult = struct { code: u8, summary: []u8 };

/// Decision: do we acquire+write? PRD §5.4 "--force re-query even if a cache exists" =>
/// without force, skip when a cache already exists. Pure (unit-tested).
fn shouldRun(cache_exists: bool, force: bool) bool {
    return force or !cache_exists;
}

/// The dir-scoped testable core. cache_dir/cache_filename = where the cache lives (tmpDir in
/// tests); cache_display_path is only used to build the human-readable summary. The tty
/// branch is NOT exercised in CI (queryColors opens the real /dev/tty) — it is
/// compile-verified + manually tested. Returns {code, summary}; does NO stdout I/O.
fn syncPaletteDir(
    allocator: std.mem.Allocator,
    opts: cli.SyncPaletteOpts,
    cache_dir: std.fs.Dir,
    cache_filename: []const u8,
    cache_display_path: []const u8,
) anyerror!SyncResult {
    // cache exists?
    const cache_exists = if (cache_dir.statFile(cache_filename)) |_| true else |_| false;

    // PRD §5.4: without --force, leave an existing cache untouched (skip acquire too).
    if (!shouldRun(cache_exists, opts.force)) {
        return .{ .code = 0, .summary = try std.fmt.allocPrint(
            allocator,
            "palette cache already exists at {s}; use --force to re-query",
            .{cache_display_path},
        ) };
    }

    // Acquire Colors from the chosen source.
    var colors: palette.Colors = undefined;
    var label: []const u8 = "queried"; // tty
    switch (opts.from) {
        .tty => {
            colors = palette.queryColors(allocator) catch return .{ .code = 2, .summary =
                try std.fmt.allocPrint(
                    allocator,
                    "error: cannot query terminal palette (no controlling tty or terminal unresponsive)",
                    .{},
                ) };
        },
        .file => |path| {
            label = "loaded";
            colors = palette.loadColorsFile(allocator, path) catch return .{ .code = 1, .summary =
                try std.fmt.allocPrint(
                    allocator,
                    "error: cannot read palette file '{s}'",
                    .{path},
                ) };
        },
    }

    // Write (atomic; caller ensured cache_dir exists).
    palette.writeCacheDir(cache_dir, cache_filename, allocator, colors) catch return .{ .code =
        1, .summary = try std.fmt.allocPrint(allocator, "error: failed to write cache", .{}) };

    // Partial-response warning (queryColors also warns for tty; this covers the file path).
    if (colors.palette_received_count < 256) {
        std.log.warn("palette: only {d}/256 colors captured", .{colors.palette_received_count});
    }

    return .{ .code = 0, .summary = try std.fmt.allocPrint(
        allocator,
        "{s} {d}/256 colors; cache at {s}",
        .{ label, colors.palette_received_count, cache_display_path },
    ) };
}

/// The prod wrapper — resolve the REAL cache dir, ensure it exists, delegate, print summary.
/// Maps cachePath/dirname/openDir failures to exit 1. The body fn pointer type is
/// `*const fn(Allocator, SyncPaletteOpts) anyerror!u8`, so this MUST be `anyerror!u8`.
fn syncPaletteBody(allocator: std.mem.Allocator, opts: cli.SyncPaletteOpts) anyerror!u8 {
    const stdout = std.fs.File.stdout();
    const cache_path = palette.cachePath(allocator) catch {
        try stdout.writeAll("error: cannot determine cache directory (HOME unset)\n");
        return 1;
    };
    defer allocator.free(cache_path);
    const dir_path = std.fs.path.dirname(cache_path) orelse {
        try stdout.writeAll("error: invalid cache path\n");
        return 1; // GOTCHA 7: nullable dirname
    };
    std.fs.cwd().makePath(dir_path) catch {}; // GOTCHA 6: writeCacheDir needs the dir to exist
    var dir = std.fs.openDirAbsolute(dir_path, .{}) catch {
        try stdout.writeAll("error: cannot open cache directory\n");
        return 1;
    };
    defer dir.close();
    const result = try syncPaletteDir(
        allocator,
        opts,
        dir,
        std.fs.path.basename(cache_path),
        cache_path,
    );
    defer allocator.free(result.summary); // GOTCHA 9: summary is allocator-owned
    try stdout.writeAll(result.summary);
    try stdout.writeAll("\n");
    return result.code;
}

// ---- pane body (PRD §5.2 + §9 + §13) ----------------------------------------
// The user-facing command: resolve a target pane, capture it via `tmux capture-pane`
// (visible or full-scrollback, history-capped), resolve the palette from the CACHE (no
// /dev/tty probe under run-shell), render the WHOLE grid to a collision-safe HTML file
// (`<session>-<unixtime>-<pid>.html`) in the configured output dir — or to an explicit
// `--output FILE`. Optionally `xdg-open`s the result. Exits 2 on capture/target errors.
//
// Mirrors syncPaletteDir/Body: a dir-scoped testable core (panePrepare) that does capture +
// filename + dir + truncation computation WITHOUT renderGrid (the ghostty-vt single-test-
// scope GOTCHA forbids a pane unit test that calls renderGrid), plus a prod wrapper (paneBody)
// that resolves real paths, renders, and prints the summary. Target resolution is INJECTABLE
// (panePrepare takes the resolved target) so the no-tty path is unit-testable without setenv.

/// Result of the dir-scoped pane prepare core. `output_path`/`summary`/`notice` are
/// allocator-owned (caller frees); `notice` is null unless the capture was truncated. The core
/// does NO stdout I/O (mirrors SyncResult{code,summary}). `cap_ansi` is the OWNED captured ANSI
/// so the prod wrapper can render it (the core frees it via freePaneResult).
const PaneResult = struct {
    code: u8,
    summary: []u8,
    output_path: []u8,
    notice: ?[]u8,
    cap_ansi: []u8,
    cols: u16,
    rows: u16,
};

/// Free every allocator-owned field of a PaneResult (idempotent over a zero-init result).
fn freePaneResult(allocator: std.mem.Allocator, r: *PaneResult) void {
    allocator.free(r.summary);
    allocator.free(r.output_path);
    if (r.notice) |n| allocator.free(n);
    allocator.free(r.cap_ansi);
}

/// The pane process id for collision-safe filenames. Linux uses `getpid`; off-Linux the value
/// collapses to 0 (unixtime alone still disambiguates concurrent runs within a second; the
/// plugin's run-shell concurrency is coarse enough that this is acceptable). os/linux.zig:1841.
fn currentPid() i32 {
    return if (builtin.os.tag == .linux) @intCast(std.os.linux.getpid()) else 0;
}

/// Build a failure PaneResult (allocator-owned summary). The caller still must free the result's
/// owned fields via freePaneResult; this helper allocates empty placeholders for the others so
/// freePaneResult is always safe.
fn failPane(allocator: std.mem.Allocator, code: u8, msg: []const u8) !PaneResult {
    return .{
        .code = code,
        .summary = try std.fmt.allocPrint(allocator, "{s}", .{msg}),
        .output_path = try allocator.alloc(u8, 0),
        .notice = null,
        .cap_ansi = try allocator.alloc(u8, 0),
        .cols = 0,
        .rows = 0,
    };
}

/// The dir-scoped testable core (NO real tmux, NO renderGrid). `runner` is FakeTmux in tests,
/// `capture.real` in prod; `target` is the RESOLVED pane id (the prod wrapper resolves it from
/// `--target`/`$TMUX_PANE` so the no-tty path is unit-testable without setenv); `out_dir` is an
/// absolute dir path the caller already ensured exists. Computes the capture, the collision-safe
/// output path, and the truncation notice text (PRD §13). Returns a PaneResult; does NO stdout I/O.
fn panePrepare(
    allocator: std.mem.Allocator,
    opts: cli.PaneOpts,
    target: []const u8,
    out_dir: []const u8,
    runner: capture.Runner,
) anyerror!PaneResult {
    const mode: capture.Mode = if (opts.full) .full else .visible; // visible is the default

    // Resolve @tmux-2html-history-limit (default 50000 if unset/empty/non-numeric).
    const limit_opt = capture.queryOption(runner, allocator, "@tmux-2html-history-limit") catch
        return failPane(allocator, 2, "cannot query tmux options");
    defer allocator.free(limit_opt);
    const configured_limit = std.fmt.parseInt(u32, std.mem.trim(u8, limit_opt, " \t\n\r"), 10) catch 50000;

    // Capture (geometry + capture-pane). A bad target / unavailable tmux => exit 2.
    const cap = capture.capture(runner, allocator, target, mode, opts.history, configured_limit) catch
        return failPane(allocator, 2, "cannot capture pane (bad target or tmux unavailable)");
    // cap.ansi is owned; we transfer ownership into PaneResult.cap_ansi (freed by freePaneResult).

    // Resolve the output path. `--output FILE` wins; else build the collision-safe name from
    // session + unixtime + pid into the configured output dir.
    var path: []u8 = undefined;
    var path_owned_by_us = false; // true when WE allocated path (not opts.output)
    if (opts.output) |p| {
        path = try allocator.dupe(u8, p);
        path_owned_by_us = true;
    } else {
        const session = capture.querySessionName(runner, allocator, target) catch
            return failPane(allocator, 2, "cannot resolve session name");
        defer allocator.free(session);
        const sess_trim = std.mem.trim(u8, session, " \t\n\r");
        const ts = std.time.timestamp(); // Unix seconds, wall clock (palette.zig uses this)
        const pid = currentPid();
        const fname = try capture.buildOutputFilename(allocator, sess_trim, ts, pid);
        defer allocator.free(fname);
        path = try capture.buildOutputPath(allocator, out_dir, fname);
        path_owned_by_us = true;
    }
    // From here `path` is owned by us; on any subsequent error we must free it.
    if (!path_owned_by_us) unreachable; // both branches above set it true
    errdefer allocator.free(path);

    // Truncation NOTICE text (PRD §13). Computed here (cap is in scope) so it is unit-testable;
    // the prod wrapper (paneBody) does the actual stderr/display-message I/O (core does NO I/O).
    var notice: ?[]u8 = null;
    errdefer if (notice) |n| allocator.free(n);
    if (cap.truncated) {
        notice = std.fmt.allocPrint(
            allocator,
            "tmux-2html: capture truncated to {d} history lines (pane had {d}); older output dropped",
            .{ cap.effective, cap.history_size },
        ) catch null; // best-effort; null falls back to the plain summary
    }

    const summary = if (notice != null)
        try std.fmt.allocPrint(allocator, "wrote {s} (truncated)", .{path})
    else
        try std.fmt.allocPrint(allocator, "wrote {s}", .{path});

    return .{
        .code = 0,
        .summary = summary,
        .output_path = path,
        .notice = notice,
        .cap_ansi = cap.ansi,
        .cols = cap.cols,
        .rows = cap.rows,
    };
}

/// The prod wrapper — resolve the REAL output dir + target, ensure the dir exists, prepare,
/// render the whole grid to the output path (atomic temp+rename via renderToFileAtomic),
/// print the summary, emit the truncation notice (stderr + best-effort display-message), and
/// optionally xdg-open the result. Maps capture/write failures to exit 2/1. The body fn pointer
/// type is `*const fn(Allocator, PaneOpts) anyerror!u8`, so this MUST be `anyerror!u8`.
fn paneBody(allocator: std.mem.Allocator, opts: cli.PaneOpts) anyerror!u8 {
    const stdout = std.fs.File.stdout();
    const stderr = std.fs.File.stderr();
    const runner = capture.real;

    // Resolve the target: --target wins; else $TMUX_PANE; else exit 2.
    const target = opts.target orelse std.posix.getenv("TMUX_PANE") orelse {
        try stdout.writeAll("error: no target pane ($TMUX_PANE unset and no --target)\n");
        return 2;
    };

    // Resolve the output dir (PRD §9.2). Ensure it exists (idempotent).
    const out_dir = capture.resolveOutputDir(runner, allocator) catch {
        try stdout.writeAll("error: cannot determine output directory\n");
        return 1;
    };
    defer allocator.free(out_dir);
    std.fs.cwd().makePath(out_dir) catch {};

    // Prepare (capture + filename + truncation text; NO render). capture failure => exit 2.
    var result = try panePrepare(allocator, opts, target, out_dir, runner);
    defer freePaneResult(allocator, &result);

    // If prepare failed (bad target / unavailable tmux / option query error), short-circuit
    // BEFORE rendering: the failure result has cols=0/rows=0/empty ansi, and feeding ghostty-vt
    // a zero-dimension terminal (Terminal.init cols=0) segfaults. Report the summary + exit.
    if (result.code != 0) {
        try stdout.writeAll(result.summary);
        try stdout.writeAll("\n");
        return result.code;
    }

    // Render the WHOLE grid to the output path (atomic temp+rename). renderToFileAtomic calls
    // renderGrid(sel:null) internally. Palette from CACHE (no /dev/tty under run-shell).
    const colors = palette.resolve(allocator, .cached, palette.hasControllingTty()); // INFALLIBLE
    render_mod.renderToFileAtomic(
        allocator,
        result.output_path,
        result.cap_ansi,
        .{ .cols = result.cols, .rows = result.rows },
        colors,
        opts.font,
    ) catch {
        try stdout.writeAll("error: cannot write output file\n");
        return 1;
    };

    // Truncation notice (PRD §13): core computed the text into result.notice. stderr ALWAYS;
    // display-message is best-effort (run-shell contexts without a tmux client still succeed).
    if (result.notice) |n| {
        stderr.writeAll(n) catch {};
        stderr.writeAll("\n") catch {};
        _ = runner.run(&.{ "tmux", "display-message", "-p", n }, allocator) catch {};
    }

    // Summary to stdout.
    try stdout.writeAll(result.summary);
    try stdout.writeAll("\n");

    // --open: best-effort (never changes the exit code).
    if (opts.open) render_mod.spawnXdgOpen(result.output_path, allocator);

    return result.code;
}

test {
    // P1.M2: keep palette.zig tests reachable from the test root (src/main.zig). A top-level
    // test block is compiled ONLY in test mode. (palette is now imported on the exe path too,
    // since sync-palette runs queryColors — Gotcha 1: --release=fast is mandatory regardless.)
    _ = @import("palette.zig");
    // P1.M3.T1.S1: keep render.zig tests reachable (renderGrid unit tests).
    _ = @import("render.zig");
    // P1.M4.T2.S1: golden harness (color/attr/OSC8 testdata) — embeds testdata/* via the
    // "testdata" module wired in build.zig.
    _ = @import("golden_test.zig");
    // P2.M1: keep capture.zig unit tests reachable.
    _ = @import("capture.zig");
    // P3.M1.T1.S1: keep tui/app.zig unit tests reachable (ghostty-free ⇒ separate test fns).
    _ = @import("tui/app.zig");
    // P3.M1.T2.S1: keep tui/view.zig unit tests reachable (region.zig, its only caller, does
    // NOT exist yet — without this import the tests are unreachable). view.zig imports
    // ghostty-vt ⇒ its Terminal-building assertions share ONE test fn (the cross-test GOTCHA).
    _ = @import("tui/view.zig");
    // P3.M2.T1.S1: keep tui/input.zig unit tests reachable (region.zig, its caller, does
    // NOT exist yet — without this import the tests are unreachable). input.zig is
    // ghostty-free ⇒ separate test fns (no cross-test GOTCHA).
    _ = @import("tui/input.zig");
    // P3.M2.T1.S2: keep tui/motion.zig tests reachable (region.zig, its caller, does
    // NOT exist yet). motion.zig is PURE (no Terminal) ⇒ separate test fns (no cross-test
    // GOTCHA).
    _ = @import("tui/motion.zig");
    // P3.M2.T2.S1: keep tui/select.zig tests reachable (region.zig, its caller, does
    // NOT exist yet). select.zig is PURE (no Terminal) ⇒ separate test fns (no cross-test
    // GOTCHA).
    _ = @import("tui/select.zig");
}

test "dispatch routes known subcommand to cli stub" {
    // `render` is WIRED (P1.M3.T1.S1) and `pane` is WIRED (P2.M1.T2.S1) — both run real I/O
    // (stdin / tmux / files), so they must NOT be driven from a unit test. Only `region` still
    // reaches a NotImplemented stub. `sync-palette` runs queryColors against the REAL /dev/tty +
    // writes the REAL cache — never drive it from a test.
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.NotImplemented, dispatch(allocator, "region", &.{}));
}

test "version string is non-empty" {
    try std.testing.expect(version_string.len > 0);
}

// ---- sync-palette unit tests (drive syncPaletteDir via std.testing.tmpDir; NEVER the tty path) ----
// syncPaletteDir is dir-scoped so the --from file + cache-exists/force decision is tested in
// isolation. The tty branch (queryColors opens the REAL /dev/tty) is compile-verified +
// manually exercised, exactly like palette.zig S1 leaves queryColors.

test "shouldRun: force or no-cache => true; cache+!force => false" {
    try std.testing.expect(shouldRun(false, false));
    try std.testing.expect(shouldRun(false, true));
    try std.testing.expect(shouldRun(true, true));
    try std.testing.expect(!shouldRun(true, false));
}

/// Join an absolute tmp dir path with a filename into an owned slice.
fn joinPath(allocator: std.mem.Allocator, dir_abs: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_abs, name });
}

test "syncPaletteDir --from file writes cache when none exists" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Write a source palette file INSIDE the tmp dir, then resolve its ABSOLUTE path
    // (loadColorsFile branches on isAbsolute; an absolute path avoids cwd dependence).
    try tmp.dir.writeFile(.{ .sub_path = "source.txt", .data = "fg 1 2 3\nbg 4 5 6\n0 10 20 30\n" });
    const dir_abs = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_abs);
    const source_abs = try joinPath(alloc, dir_abs, "source.txt");
    defer alloc.free(source_abs);

    const opts = cli.SyncPaletteOpts{ .from = .{ .file = source_abs }, .force = false };
    const result = try syncPaletteDir(alloc, opts, tmp.dir, "palette", "/c/palette");
    defer alloc.free(result.summary);

    try std.testing.expectEqual(@as(u8, 0), result.code);
    try std.testing.expect(std.mem.indexOf(u8, result.summary, "loaded") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.summary, "/256") != null);

    // The cache now holds the source palette. (palette_received_count after reload is 256:
    // serialize writes every index 0..255, seeded from defaults for the unparsed ones, so
    // the on-disk file has 256 index lines. The summary above still correctly says "1/256" —
    // that count came from parsing the SOURCE before serialization backfilled the rest.)
    const got = try palette.loadCacheDir(tmp.dir, "palette", alloc);
    try std.testing.expectEqual(@as(u8, 1), got.foreground.?.r);
    try std.testing.expectEqual(@as(u8, 4), got.background.?.r);
    try std.testing.expectEqual(@as(u8, 10), got.palette[0].r);
    try std.testing.expectEqual(@as(u16, 256), got.palette_received_count);
}

test "syncPaletteDir --from file skips when cache exists and not --force" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Seed the cache with a distinctive Colors (bg.r == 200).
    var colors_a = palette.defaultColors();
    colors_a.background = .{ .r = 200, .g = 0, .b = 0 };
    try palette.writeCacheDir(tmp.dir, "palette", alloc, colors_a);

    // Source has DIFFERENT colors (bg.r == 4); without --force the cache must stay colors_a.
    try tmp.dir.writeFile(.{ .sub_path = "source.txt", .data = "fg 1 2 3\nbg 4 5 6\n0 10 20 30\n" });
    const dir_abs = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_abs);
    const source_abs = try joinPath(alloc, dir_abs, "source.txt");
    defer alloc.free(source_abs);

    const opts = cli.SyncPaletteOpts{ .from = .{ .file = source_abs }, .force = false };
    const result = try syncPaletteDir(alloc, opts, tmp.dir, "palette", "/c/palette");
    defer alloc.free(result.summary);

    try std.testing.expectEqual(@as(u8, 0), result.code);
    try std.testing.expect(std.mem.indexOf(u8, result.summary, "already exists") != null);

    // Cache UNCHANGED.
    const got = try palette.loadCacheDir(tmp.dir, "palette", alloc);
    try std.testing.expectEqual(@as(u8, 200), got.background.?.r);
}

test "syncPaletteDir --from file --force overwrites an existing cache" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var colors_a = palette.defaultColors();
    colors_a.background = .{ .r = 200, .g = 0, .b = 0 };
    try palette.writeCacheDir(tmp.dir, "palette", alloc, colors_a);

    try tmp.dir.writeFile(.{ .sub_path = "source.txt", .data = "fg 1 2 3\nbg 4 5 6\n0 10 20 30\n" });
    const dir_abs = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_abs);
    const source_abs = try joinPath(alloc, dir_abs, "source.txt");
    defer alloc.free(source_abs);

    const opts = cli.SyncPaletteOpts{ .from = .{ .file = source_abs }, .force = true };
    const result = try syncPaletteDir(alloc, opts, tmp.dir, "palette", "/c/palette");
    defer alloc.free(result.summary);

    try std.testing.expectEqual(@as(u8, 0), result.code);
    // Cache OVERWRITTEN with the source colors.
    const got = try palette.loadCacheDir(tmp.dir, "palette", alloc);
    try std.testing.expectEqual(@as(u8, 4), got.background.?.r);
}

test "syncPaletteDir --from file <missing> => exit 1" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const opts = cli.SyncPaletteOpts{ .from = .{ .file = "/tmp/tmux-2html-no-such-source-xyz" }, .force = false };
    const result = try syncPaletteDir(alloc, opts, tmp.dir, "palette", "/c/palette");
    defer alloc.free(result.summary);

    try std.testing.expectEqual(@as(u8, 1), result.code);
    try std.testing.expect(std.mem.indexOf(u8, result.summary, "cannot read palette file") != null);
}

test "syncPaletteDir --from file <malformed> => exit 1" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "source.txt", .data = "0 notanumber 0 0\n" });
    const dir_abs = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_abs);
    const source_abs = try joinPath(alloc, dir_abs, "source.txt");
    defer alloc.free(source_abs);

    const opts = cli.SyncPaletteOpts{ .from = .{ .file = source_abs }, .force = false };
    const result = try syncPaletteDir(alloc, opts, tmp.dir, "palette", "/c/palette");
    defer alloc.free(result.summary);

    try std.testing.expectEqual(@as(u8, 1), result.code);
}

// ---- panePrepare unit tests (dir-scoped, FakeTmux + std.testing.tmpDir; NO renderGrid) ----
// panePrepare is split from paneBody at the render seam so capture + filename + dir + truncation
// logic is unit-testable WITHOUT ghostty-vt Terminal.init (the cross-test GOTCHA forbids a pane
// unit test that calls renderGrid; render is already proven in render.zig's single scope).
// target is INJECTABLE (panePrepare takes it resolved) so the no-tty path needs no setenv.

/// Test double for the capture.Runner seam: returns canned bytes per tmux subcommand, with
/// per-instance state (NO mutable global => no cross-test contamination). Mirrors capture.zig's
/// FakeTmux but lives here (capture's is module-private). The pane_id is echoed for session_name.
const PaneFake = struct {
    cols: u16 = 80,
    rows: u16 = 24,
    history_size: u32 = 0,
    ansi: []const u8 = "\x1b[31mhi\x1b[0m\n",
    session: []const u8 = "mysess",
    history_limit: ?[]const u8 = null, // @tmux-2html-history-limit value (null = unset)

    fn run(ctx: *anyopaque, argv: []const []const u8, alloc: std.mem.Allocator) anyerror![]u8 {
        const self: *PaneFake = @ptrCast(@alignCast(ctx));
        // helper: does argv contain needle?
        const hasArg = struct {
            fn f(a: []const []const u8, needle: []const u8) bool {
                for (a) |x| if (std.mem.eql(u8, x, needle)) return true;
                return false;
            }
        }.f;

        if (hasArg(argv, "display-message")) {
            if (hasArg(argv, "#{pane_width} #{pane_height} #{history_size}"))
                return std.fmt.allocPrint(alloc, "{d} {d} {d}", .{ self.cols, self.rows, self.history_size });
            if (hasArg(argv, "#{session_name}"))
                return alloc.dupe(u8, self.session);
            return error.UnexpectedArgv;
        }
        if (hasArg(argv, "capture-pane")) return alloc.dupe(u8, self.ansi);
        if (hasArg(argv, "show-option")) {
            // argv = { "tmux", "show-option", "-gqv", name }
            if (argv.len >= 4) {
                const name = argv[argv.len - 1];
                if (std.mem.eql(u8, name, "@tmux-2html-history-limit")) {
                    if (self.history_limit) |v| return alloc.dupe(u8, v);
                }
            }
            return alloc.alloc(u8, 0); // unset => empty
        }
        return error.UnexpectedArgv;
    }
};

test "panePrepare: visible + no history => path under out_dir matching <session>-<digits>-<digits>.html" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_abs);

    var fake = PaneFake{}; // history_size 0, session "mysess"
    const runner: capture.Runner = .{ .ctx = @ptrCast(&fake), .runFn = PaneFake.run };
    const opts = cli.PaneOpts{ .target = "%5", .visible = true };

    var result = try panePrepare(alloc, opts, "%5", dir_abs, runner);
    defer freePaneResult(alloc, &result);

    try std.testing.expectEqual(@as(u8, 0), result.code);
    // path is under out_dir
    try std.testing.expect(std.mem.startsWith(u8, result.output_path, dir_abs));
    // basename matches <sanitized-session>-<digits>-<digits>.html
    const base = std.fs.path.basename(result.output_path);
    try std.testing.expect(std.mem.startsWith(u8, base, "mysess-"));
    try std.testing.expect(std.mem.endsWith(u8, base, ".html"));
    // truncated flag absent (visible mode)
    try std.testing.expect(result.notice == null);
    try std.testing.expect(std.mem.indexOf(u8, result.summary, "wrote ") != null);
}

test "panePrepare: full with big history_size + small history => notice set (truncated)" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_abs);

    var fake = PaneFake{ .history_size = 100000, .history_limit = "500" };
    const runner: capture.Runner = .{ .ctx = @ptrCast(&fake), .runFn = PaneFake.run };
    // --history 1000, configured limit 500 => effective 500; history_size 100000 > 500 => truncated
    const opts = cli.PaneOpts{ .target = "%5", .full = true, .history = 1000 };

    var result = try panePrepare(alloc, opts, "%5", dir_abs, runner);
    defer freePaneResult(alloc, &result);
    try std.testing.expectEqual(@as(u8, 0), result.code);
    try std.testing.expect(result.notice != null);
    try std.testing.expect(std.mem.indexOf(u8, result.notice.?, "truncated") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.notice.?, "500") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.notice.?, "100000") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.summary, "(truncated)") != null);
}

test "panePrepare: --output FILE => path is exactly FILE (no auto-naming)" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_abs);
    const explicit = try std.fmt.allocPrint(alloc, "{s}/x.html", .{dir_abs});
    defer alloc.free(explicit);

    var fake = PaneFake{};
    const runner: capture.Runner = .{ .ctx = @ptrCast(&fake), .runFn = PaneFake.run };
    const opts = cli.PaneOpts{ .target = "%5", .visible = true, .output = explicit };

    var result = try panePrepare(alloc, opts, "%5", dir_abs, runner);
    defer freePaneResult(alloc, &result);
    try std.testing.expectEqual(@as(u8, 0), result.code);
    try std.testing.expectEqualStrings(explicit, result.output_path);
}

test "panePrepare: capture failure (FakeTmux errors on geometry) => exit 2" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_abs);

    // A fake that always errors (simulates a bad pane id / unavailable tmux).
    const ErrFake = struct {
        fn run(_: *anyopaque, _: []const []const u8, _: std.mem.Allocator) anyerror![]u8 {
            return error.TmuxNonZeroExit;
        }
    };
    var fake = ErrFake{};
    const runner: capture.Runner = .{ .ctx = @ptrCast(&fake), .runFn = ErrFake.run };
    const opts = cli.PaneOpts{ .target = "%999999", .visible = true };

    var result = try panePrepare(alloc, opts, "%999999", dir_abs, runner);
    defer freePaneResult(alloc, &result);
    try std.testing.expectEqual(@as(u8, 2), result.code);
    try std.testing.expect(std.mem.indexOf(u8, result.summary, "cannot capture pane") != null);
}

test "panePrepare: @tmux-2html-history-limit unset => defaults to 50000" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_abs);

    // history_size 60000 > effective 50000 (default, since limit unset) => truncated; but only in
    // full mode. visible => not truncated regardless. Verify the default-limit path doesn't error.
    var fake = PaneFake{ .history_size = 60000, .history_limit = null };
    const runner: capture.Runner = .{ .ctx = @ptrCast(&fake), .runFn = PaneFake.run };
    const opts = cli.PaneOpts{ .target = "%5", .full = true, .history = 50000 };

    var result = try panePrepare(alloc, opts, "%5", dir_abs, runner);
    defer freePaneResult(alloc, &result);
    try std.testing.expectEqual(@as(u8, 0), result.code);
    try std.testing.expect(result.notice != null); // 60000 > 50000 default
}

test "currentPid: returns a non-negative pid on Linux" {
    const pid = currentPid();
    if (builtin.os.tag == .linux) {
        try std.testing.expect(pid > 0);
    } else {
        try std.testing.expectEqual(@as(i32, 0), pid);
    }
}
