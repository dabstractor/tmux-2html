const std = @import("std");
const parg = @import("parg");
const render_mod = @import("render.zig"); // P1.M3.T1.S1: wired so cli.render delegates to render_mod.run. Circular import cli<->render is legal (lazy resolution); parseRender stays pure/ghostty-free.

// ============================================================================
// P1.M1.T3.S2 — parg flag/option parser for all subcommands.
//
// main.zig dispatches the post-subcommand arg slice (args[2..]) here. Each
// subcommand has a typed options struct + a PURE parse function (no I/O,
// unit-testable) returning ParseError!Opts. The pub dispatch fns
// (render/pane/region/syncPalette) own the exit-code contract: --help → print
// help + return 0; parse error → print message + return 1; success → run the
// body (NOT YET IMPLEMENTED → error.NotImplemented, mapped to exit 1 by
// main.zig).
//
// Each flag maps to a PRD §5 field. Consumers (render.zig, capture.zig, ...)
// receive these typed structs and NEVER touch parg directly.
// ============================================================================

// ---- Shared option types ----------------------------------------------------

/// PRD §5.1 `--palette MODE`: default | cached | live. Default value `.cached`
/// means "try cached → live → default"; the resolve precedence lives in
/// palette.zig (P1.M2.T1.S3).
pub const PaletteMode = enum {
    default,
    cached,
    live,

    pub fn fromStr(s: []const u8) ?PaletteMode {
        if (std.mem.eql(u8, s, "default")) return .default;
        if (std.mem.eql(u8, s, "cached")) return .cached;
        if (std.mem.eql(u8, s, "live")) return .live;
        return null;
    }
};

/// PRD §5.4 `--from source`: tty (default) | file PATH.
pub const PaletteSource = union(enum) {
    tty,
    file: []const u8,
};

/// PRD §5.1 `--selection X1,Y1,X2,Y2[,rect]` — parsed coordinates (rect=1 →
/// block). Conversion to ghostty point.Pin / Selection lives in render.zig
/// (P1.M4.T1.S1); cli.zig never imports ghostty.
pub const SelectionCoords = struct {
    x1: u32,
    y1: u32,
    x2: u32,
    y2: u32,
    rect: bool = false,
};

// ---- Per-subcommand option structs -----------------------------------------
// Field names mirror the item contract (PRD §5.1–§5.4).

/// PRD §5.1 `render`.
pub const RenderOpts = struct {
    cols: ?u16 = null,
    rows: ?u16 = null,
    font: []const u8 = "monospace",
    palette_mode: PaletteMode = .cached,
    output: ?[]const u8 = null,
    open: bool = false,
    selection: ?SelectionCoords = null,
    title: ?[]const u8 = null, // PRD §8.1: document <title> (--title; default derived in render.zig)
    lang: ?[]const u8 = null, // PRD §8.1: <html lang> (--lang; resolved/normalized in render.zig S2)
};

/// PRD §5.2 `pane`.
pub const PaneOpts = struct {
    target: ?[]const u8 = null,
    visible: bool = false,
    full: bool = false,
    history: u32 = 50000,
    font: []const u8 = "monospace",
    output: ?[]const u8 = null,
    open: bool = false,
    title: ?[]const u8 = null, // PRD §8.1
    lang: ?[]const u8 = null, // PRD §8.1
};

/// PRD §5.3 `region`.
pub const RegionOpts = struct {
    target: ?[]const u8 = null,
    font: []const u8 = "monospace",
    output: ?[]const u8 = null,
    open: bool = false,
    title: ?[]const u8 = null, // PRD §8.1
    lang: ?[]const u8 = null, // PRD §8.1
};

/// PRD §5.4 `sync-palette`.
pub const SyncPaletteOpts = struct {
    from: PaletteSource = .tty,
    force: bool = false,
};

// ---- Parse errors -----------------------------------------------------------

pub const ParseError = error{
    MissingValue, // a value-option had no argument (e.g. `--cols` at end)
    UnknownFlag, // unrecognized flag / stray positional / `--bool=val`
    InvalidNumber, // --cols/--rows/--history value not a valid integer
    BadPaletteMode, // --palette value not in {default,cached,live}
    BadSelection, // --selection not 4–5 comma-separated ints
    BadPaletteSource, // --from value not "tty" or "file"
    MutualExclusivity, // pane: --visible and --full together
};

// ---- Small parse helpers (pure) --------------------------------------------

/// Consume the value of a value-option. Handles both `--name value` and
/// `--name=value` (parg's nextValue covers both via its internal .value
/// state).
///
/// GOTCHA: parg's nextValue() blindly pulls the next raw token, so `--cols
/// --rows` would otherwise consume "--rows" as the cols value. We treat a
/// value that looks like another flag (len>1, leading '-') as a missing value
/// instead — friendlier and matches user intent. A lone "-" (stdin) is allowed.
fn requireValue(parser: anytype) ParseError![]const u8 {
    const v = parser.nextValue() orelse return error.MissingValue;
    if (v.len > 1 and v[0] == '-') return error.MissingValue;
    return v;
}

fn parseU16(s: []const u8) ParseError!u16 {
    return std.fmt.parseInt(u16, s, 10) catch error.InvalidNumber;
}

fn parseU32(s: []const u8) ParseError!u32 {
    return std.fmt.parseInt(u32, s, 10) catch error.InvalidNumber;
}

/// `X1,Y1,X2,Y2[,rect]` → SelectionCoords. rect=1 → block; anything else →
/// linewise (rect=false).
fn parseSelection(s: []const u8) ParseError!SelectionCoords {
    var it = std.mem.splitScalar(u8, s, ',');
    var vals: [5]?u32 = .{ null, null, null, null, null };
    var n: usize = 0;
    while (it.next()) |part| {
        if (n >= 5) return error.BadSelection;
        vals[n] = std.fmt.parseInt(u32, part, 10) catch return error.BadSelection;
        n += 1;
    }
    if (n < 4) return error.BadSelection; // need at least x1,y1,x2,y2
    return .{
        .x1 = vals[0].?,
        .y1 = vals[1].?,
        .x2 = vals[2].?,
        .y2 = vals[3].?,
        .rect = if (n == 5) (vals[4].? == 1) else false,
    };
}

// ---- Per-subcommand parsers (pure, return ParseError!Opts) -----------------

pub fn parseRender(args: []const []const u8) ParseError!RenderOpts {
    var opts = RenderOpts{};
    var parser = parg.parseSlice(args, .{});
    defer parser.deinit();
    while (parser.next()) |token| {
        switch (token) {
            .flag => |flag| {
                if (flag.isLong("cols")) {
                    opts.cols = try parseU16(try requireValue(&parser));
                } else if (flag.isLong("rows")) {
                    opts.rows = try parseU16(try requireValue(&parser));
                } else if (flag.isLong("font")) {
                    opts.font = try requireValue(&parser);
                } else if (flag.isLong("palette")) {
                    opts.palette_mode = PaletteMode.fromStr(try requireValue(&parser)) orelse return error.BadPaletteMode;
                } else if (flag.isLong("output")) {
                    opts.output = try requireValue(&parser);
                } else if (flag.isLong("open")) {
                    opts.open = true;
                } else if (flag.isLong("selection")) {
                    opts.selection = try parseSelection(try requireValue(&parser));
                } else if (flag.isLong("title")) {
                    opts.title = try requireValue(&parser);
                } else if (flag.isLong("lang")) {
                    opts.lang = try requireValue(&parser);
                } else {
                    return error.UnknownFlag;
                }
            },
            .arg, .unexpected_value => return error.UnknownFlag,
        }
    }
    return opts;
}

pub fn parsePane(args: []const []const u8) ParseError!PaneOpts {
    var opts = PaneOpts{};
    var parser = parg.parseSlice(args, .{});
    defer parser.deinit();
    while (parser.next()) |token| {
        switch (token) {
            .flag => |flag| {
                if (flag.isLong("target")) {
                    opts.target = try requireValue(&parser);
                } else if (flag.isLong("visible")) {
                    opts.visible = true;
                } else if (flag.isLong("full")) {
                    opts.full = true;
                } else if (flag.isLong("history")) {
                    opts.history = try parseU32(try requireValue(&parser));
                } else if (flag.isLong("font")) {
                    opts.font = try requireValue(&parser);
                } else if (flag.isLong("output")) {
                    opts.output = try requireValue(&parser);
                } else if (flag.isLong("open")) {
                    opts.open = true;
                } else if (flag.isLong("title")) {
                    opts.title = try requireValue(&parser);
                } else if (flag.isLong("lang")) {
                    opts.lang = try requireValue(&parser);
                } else {
                    return error.UnknownFlag;
                }
            },
            .arg, .unexpected_value => return error.UnknownFlag,
        }
    }
    if (opts.visible and opts.full) return error.MutualExclusivity;
    return opts;
}

pub fn parseRegion(args: []const []const u8) ParseError!RegionOpts {
    var opts = RegionOpts{};
    var parser = parg.parseSlice(args, .{});
    defer parser.deinit();
    while (parser.next()) |token| {
        switch (token) {
            .flag => |flag| {
                if (flag.isLong("target")) {
                    opts.target = try requireValue(&parser);
                } else if (flag.isLong("font")) {
                    opts.font = try requireValue(&parser);
                } else if (flag.isLong("output")) {
                    opts.output = try requireValue(&parser);
                } else if (flag.isLong("open")) {
                    opts.open = true;
                } else if (flag.isLong("title")) {
                    opts.title = try requireValue(&parser);
                } else if (flag.isLong("lang")) {
                    opts.lang = try requireValue(&parser);
                } else {
                    return error.UnknownFlag;
                }
            },
            .arg, .unexpected_value => return error.UnknownFlag,
        }
    }
    return opts;
}

pub fn parseSyncPalette(args: []const []const u8) ParseError!SyncPaletteOpts {
    var opts = SyncPaletteOpts{};
    var parser = parg.parseSlice(args, .{});
    defer parser.deinit();
    while (parser.next()) |token| {
        switch (token) {
            .flag => |flag| {
                if (flag.isLong("from")) {
                    const v = try requireValue(&parser);
                    if (std.mem.eql(u8, v, "tty")) {
                        opts.from = .tty;
                    } else if (std.mem.eql(u8, v, "file")) {
                        // `--from file PATH`: the path is the next value.
                        opts.from = .{ .file = try requireValue(&parser) };
                    } else {
                        return error.BadPaletteSource;
                    }
                } else if (flag.isLong("force")) {
                    opts.force = true;
                } else {
                    return error.UnknownFlag;
                }
            },
            .arg, .unexpected_value => return error.UnknownFlag,
        }
    }
    return opts;
}

// ---- --help detection + per-subcommand help text ---------------------------

fn hasHelpFlag(args: []const []const u8) bool {
    for (args) |a| if (std.mem.eql(u8, a, "--help")) return true;
    return false;
}

fn write(out: std.fs.File, s: []const u8) !void {
    try out.writeAll(s);
}

// Mode A: the --help text IS the per-subcommand documentation (PRD §5).
const render_help =
    \\Usage: tmux-2html render [options]
    \\
    \\Read ANSI from stdin, write HTML. Used directly for piping and by other
    \\subcommands internally.
    \\
    \\Options:
    \\  --cols N            virtual terminal columns (REQUIRED if no tty; = pane width)
    \\  --rows N            virtual terminal rows (default: input line count)
    \\  --font FAMILY       CSS font-family (default: monospace)
    \\  --title TITLE       document <title> (default: "tmux-2html" or derived)
    \\  --lang LANG         document lang, BCP-47 (default: en / locale)
    \\  --palette MODE      default | cached | live  (default: cached->live->default)
    \\  --output FILE       write here instead of stdout
    \\  --open              xdg-open the output (implies --output if none given)
    \\  --selection X1,Y1,X2,Y2[,rect]   render only a sub-grid (rect=1 -> block)
    \\  --help              show this help
    \\
    \\Exit codes: 0 success, 1 usage/runtime error, 2 size/terminal error.
    \\
;

const pane_help =
    \\Usage: tmux-2html pane [options]
    \\
    \\Capture a tmux pane and convert it to HTML.
    \\
    \\Options:
    \\  --target PANE       target pane id (default: $TMUX_PANE)
    \\  --visible           only the visible rows (default)
    \\  --full              entire scrollback + visible (mutually exclusive of --visible)
    \\  --history N         with --full, cap scrollback to last N lines (default 50000)
    \\  --font FAMILY       CSS font-family
    \\  --title TITLE       document <title> (default: "tmux-2html" or derived)
    \\  --lang LANG         document lang, BCP-47 (default: en / locale)
    \\  --output FILE       write here instead of stdout
    \\  --open              xdg-open the output
    \\  --help              show this help
    \\
    \\Exit codes: 0 success, 1 usage/runtime error, 2 capture/target error.
    \\
;

const region_help =
    \\Usage: tmux-2html region [options]
    \\
    \\Interactive copy-mode overlay: select a region, render it.
    \\
    \\Options:
    \\  --target PANE       target pane id (default: $TMUX_PANE)
    \\  --font FAMILY       CSS font-family
    \\  --title TITLE       document <title> (default: "tmux-2html" or derived)
    \\  --lang LANG         document lang, BCP-47 (default: en / locale)
    \\  --output FILE       write here instead of stdout
    \\  --open              xdg-open the output
    \\  --help              show this help
    \\
    \\Exit codes: 0 success, 1 usage/runtime error, 2 capture/target error.
    \\
;

const sync_palette_help =
    \\Usage: tmux-2html sync-palette [options]
    \\
    \\Query the terminal palette and cache it.
    \\
    \\Options:
    \\  --from source       tty (default) | file PATH
    \\  --force             re-query even if a cache exists
    \\  --help              show this help
    \\
    \\Exit codes: 0 success, 1 usage/runtime error, 2 no controlling terminal.
    \\
;

// ---- Error reporting --------------------------------------------------------

fn reportError(sub: []const u8, err: ParseError) !void {
    const stderr = std.fs.File.stderr();
    const msg: []const u8 = switch (err) {
        error.MissingValue => "missing value for option",
        error.UnknownFlag => "unknown or unexpected argument",
        error.InvalidNumber => "invalid numeric value",
        error.BadPaletteMode => "--palette must be default|cached|live",
        error.BadSelection => "--selection must be X1,Y1,X2,Y2[,rect]",
        error.BadPaletteSource => "--from must be 'tty' or 'file PATH'",
        error.MutualExclusivity => "--visible and --full are mutually exclusive",
    };
    var buf: [160]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "tmux-2html {s}: {s}\n", .{ sub, msg });
    try stderr.writeAll(s);
}

// ---- Dispatch entry points (main.zig calls these) --------------------------
// Signature unchanged from T3.S1: (allocator, args) !u8.

pub fn render(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    if (hasHelpFlag(args)) {
        try write(std.fs.File.stdout(), render_help);
        return 0;
    }
    const opts = parseRender(args) catch |err| {
        try reportError("render", err);
        return 1;
    };
    return render_mod.run(allocator, opts);
}

pub fn pane(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    body: *const fn (std.mem.Allocator, PaneOpts) anyerror!u8,
) !u8 {
    if (hasHelpFlag(args)) {
        try write(std.fs.File.stdout(), pane_help);
        return 0;
    }
    const opts = parsePane(args) catch |err| {
        try reportError("pane", err);
        return 1;
    };
    return body(allocator, opts);
}

pub fn region(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    body: *const fn (std.mem.Allocator, RegionOpts) anyerror!u8,
) !u8 {
    if (hasHelpFlag(args)) {
        try write(std.fs.File.stdout(), region_help);
        return 0;
    }
    const opts = parseRegion(args) catch |err| {
        try reportError("region", err);
        return 1;
    };
    return body(allocator, opts);
}

pub fn syncPalette(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    body: *const fn (std.mem.Allocator, SyncPaletteOpts) anyerror!u8,
) !u8 {
    if (hasHelpFlag(args)) {
        try write(std.fs.File.stdout(), sync_palette_help);
        return 0;
    }
    const opts = parseSyncPalette(args) catch |err| {
        try reportError("sync-palette", err);
        return 1;
    };
    return body(allocator, opts);
}

// ---- Unit tests -------------------------------------------------------------

test "parseRender: all options" {
    const args = &[_][]const u8{ "--cols", "80", "--rows", "24", "--font", "Fira Code", "--palette", "live", "--output", "out.html", "--open", "--selection", "0,0,10,5,1" };
    const opts = try parseRender(args);
    try std.testing.expectEqual(@as(?u16, 80), opts.cols);
    try std.testing.expectEqual(@as(?u16, 24), opts.rows);
    try std.testing.expectEqualStrings("Fira Code", opts.font);
    try std.testing.expectEqual(PaletteMode.live, opts.palette_mode);
    try std.testing.expectEqualStrings("out.html", opts.output.?);
    try std.testing.expect(opts.open);
    const sel = opts.selection.?;
    try std.testing.expectEqual(@as(u32, 0), sel.x1);
    try std.testing.expectEqual(@as(u32, 5), sel.y2);
    try std.testing.expect(sel.rect);
}

test "parseRender: defaults" {
    const opts = try parseRender(&.{});
    try std.testing.expectEqual(@as(?u16, null), opts.cols);
    try std.testing.expectEqualStrings("monospace", opts.font);
    try std.testing.expectEqual(PaletteMode.cached, opts.palette_mode);
    try std.testing.expect(!opts.open);
    try std.testing.expectEqual(@as(?SelectionCoords, null), opts.selection);
    try std.testing.expectEqual(@as(?[]const u8, null), opts.title);
    try std.testing.expectEqual(@as(?[]const u8, null), opts.lang);
}

test "parseRender: --title and --lang" {
    const opts = try parseRender(&[_][]const u8{ "--title", "My Pane", "--lang", "fr" });
    try std.testing.expectEqualStrings("My Pane", opts.title.?);
    try std.testing.expectEqualStrings("fr", opts.lang.?);
}

test "parseRender: --title missing value" {
    try std.testing.expectError(error.MissingValue, parseRender(&[_][]const u8{"--title"}));
    // flag-like value is treated as missing (requireValue gotcha):
    try std.testing.expectError(error.MissingValue, parseRender(&[_][]const u8{ "--title", "--lang", "x" }));
}

test "parseRender: --lang missing value" {
    try std.testing.expectError(error.MissingValue, parseRender(&[_][]const u8{"--lang"}));
}

test "parseRender: --cols=value form" {
    const opts = try parseRender(&[_][]const u8{ "--cols=120" });
    try std.testing.expectEqual(@as(?u16, 120), opts.cols);
}

test "parseRender: missing value" {
    try std.testing.expectError(error.MissingValue, parseRender(&[_][]const u8{"--cols"}));
    try std.testing.expectError(error.MissingValue, parseRender(&[_][]const u8{ "--cols", "--rows", "24" }));
}

test "parseRender: invalid number" {
    try std.testing.expectError(error.InvalidNumber, parseRender(&[_][]const u8{ "--cols", "abc" }));
}

test "parseRender: bad palette mode" {
    try std.testing.expectError(error.BadPaletteMode, parseRender(&[_][]const u8{ "--palette", "neon" }));
}

test "parseRender: bad selection" {
    try std.testing.expectError(error.BadSelection, parseRender(&[_][]const u8{ "--selection", "1,2,3" }));
    try std.testing.expectError(error.BadSelection, parseRender(&[_][]const u8{ "--selection", "a,b,c,d" }));
}

test "parseRender: selection without rect (linewise)" {
    const opts = try parseRender(&[_][]const u8{ "--selection", "1,2,3,4" });
    try std.testing.expect(!opts.selection.?.rect);
}

test "parseRender: unknown flag and positional" {
    try std.testing.expectError(error.UnknownFlag, parseRender(&[_][]const u8{ "--bogus" }));
    try std.testing.expectError(error.UnknownFlag, parseRender(&[_][]const u8{"extra.txt"}));
    try std.testing.expectError(error.UnknownFlag, parseRender(&[_][]const u8{ "--open=yes" }));
}

test "parsePane: full set" {
    const args = &[_][]const u8{ "--target", "%5", "--full", "--history", "1000", "--font", "mono", "--output", "p.html", "--open" };
    const opts = try parsePane(args);
    try std.testing.expectEqualStrings("%5", opts.target.?);
    try std.testing.expect(opts.full);
    try std.testing.expect(!opts.visible);
    try std.testing.expectEqual(@as(u32, 1000), opts.history);
    const default_opts = PaneOpts{};
    try std.testing.expectEqual(@as(u32, 50000), default_opts.history);
}

test "parsePane: visible default flag alone" {
    const opts = try parsePane(&[_][]const u8{"--visible"});
    try std.testing.expect(opts.visible);
    try std.testing.expect(!opts.full);
    try std.testing.expectEqual(@as(?[]const u8, null), opts.title);
    try std.testing.expectEqual(@as(?[]const u8, null), opts.lang);
}

test "parsePane: --title and --lang" {
    const opts = try parsePane(&[_][]const u8{ "--target", "%5", "--title", "T", "--lang", "en-US" });
    try std.testing.expectEqualStrings("T", opts.title.?);
    try std.testing.expectEqualStrings("en-US", opts.lang.?);
}

test "parsePane: visible and full are mutually exclusive" {
    try std.testing.expectError(error.MutualExclusivity, parsePane(&[_][]const u8{ "--visible", "--full" }));
    try std.testing.expectError(error.MutualExclusivity, parsePane(&[_][]const u8{ "--full", "--visible" }));
}

test "parseRegion: options" {
    const opts = try parseRegion(&[_][]const u8{ "--target", "%9", "--font", "Serif", "--output", "r.html", "--open" });
    try std.testing.expectEqualStrings("%9", opts.target.?);
    try std.testing.expectEqualStrings("Serif", opts.font);
    try std.testing.expect(opts.open);
    try std.testing.expectEqual(@as(?[]const u8, null), opts.title);
    try std.testing.expectEqual(@as(?[]const u8, null), opts.lang);
}

test "parseRegion: --title and --lang" {
    const opts = try parseRegion(&[_][]const u8{ "--title", "R", "--lang", "de" });
    try std.testing.expectEqualStrings("R", opts.title.?);
    try std.testing.expectEqualStrings("de", opts.lang.?);
}

test "parseRegion: rejects pane-only flags" {
    try std.testing.expectError(error.UnknownFlag, parseRegion(&[_][]const u8{"--full"}));
}

test "parseSyncPalette: tty default and force" {
    const opts = try parseSyncPalette(&[_][]const u8{"--force"});
    try std.testing.expectEqual(PaletteSource.tty, opts.from);
    try std.testing.expect(opts.force);
}

test "parseSyncPalette: explicit tty" {
    const opts = try parseSyncPalette(&[_][]const u8{ "--from", "tty" });
    try std.testing.expectEqual(PaletteSource.tty, opts.from);
}

test "parseSyncPalette: from file PATH" {
    const opts = try parseSyncPalette(&[_][]const u8{ "--from", "file", "/cache/palette.txt" });
    try std.testing.expect(opts.from == .file);
    try std.testing.expectEqualStrings("/cache/palette.txt", opts.from.file);
}

test "parseSyncPalette: bad source" {
    try std.testing.expectError(error.BadPaletteSource, parseSyncPalette(&[_][]const u8{ "--from", "ftp" }));
    try std.testing.expectError(error.MissingValue, parseSyncPalette(&[_][]const u8{"--from"}));
}

test "parseSyncPalette: rejects --title and --lang" {
    try std.testing.expectError(error.UnknownFlag, parseSyncPalette(&[_][]const u8{ "--title", "x" }));
    try std.testing.expectError(error.UnknownFlag, parseSyncPalette(&[_][]const u8{ "--lang", "en" }));
}

test "hasHelpFlag" {
    try std.testing.expect(hasHelpFlag(&[_][]const u8{ "--cols", "--help" }));
    try std.testing.expect(hasHelpFlag(&[_][]const u8{"--help"}));
    try std.testing.expect(!hasHelpFlag(&[_][]const u8{ "--cols", "80" }));
    try std.testing.expect(!hasHelpFlag(&[_][]const u8{ "--help=1" }));
}
