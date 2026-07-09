const std = @import("std");
const build_options = @import("build_options");
const parg = @import("parg");
const cli = @import("cli.zig");
const palette = @import("palette.zig");

const version_string = build_options.version;

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
        return cli.pane(allocator, sub_args);
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

test {
    // P1.M2: keep palette.zig tests reachable from the test root (src/main.zig). A top-level
    // test block is compiled ONLY in test mode. (palette is now imported on the exe path too,
    // since sync-palette runs queryColors — Gotcha 1: --release=fast is mandatory regardless.)
    _ = @import("palette.zig");
}

test "dispatch routes known subcommand to cli stub" {
    // render/pane/region still reach a NotImplemented stub. sync-palette is now wired to
    // its body (syncPaletteBody), so dispatch('sync-palette') would run queryColors against
    // the REAL /dev/tty + write the REAL cache — never drive it from a unit test.
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.NotImplemented, dispatch(allocator, "render", &.{}));
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
