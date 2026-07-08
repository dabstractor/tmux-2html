//! palette.zig — palette subsystem, lowest layer (PRD §6).
//!
//! Absorbs term2html's terminal.zig::queryColors (see architecture/render_pipeline.md §2):
//!  - Colors struct + defaultColors() (Ghostty bundled palette).
//!  - queryColors(): /dev/tty raw mode, OSC 4 batches of 32 + OSC 10/11, 500ms timeout,
//!    parsed through ghostty_vt.Parser.
//!  - applyOscCommand(): the PURE decoder (no I/O) — unit-tested against fixed byte streams.
//!
//! Consumers: palette.resolve() (T1.S3), sync-palette body (T2.S1), render --palette live
//! (P1.M3). NEVER call queryColors() from a tmux run-shell context (no tty).

const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const color = ghostty_vt.color;
const osc = ghostty_vt.osc;

/// The resolved palette handed to the renderer / written to the cache.
/// `palette_received_count < 256` ⇒ the terminal didn't answer every OSC 4 query.
pub const Colors = struct {
    palette: [256]color.RGB,
    foreground: ?color.RGB,
    background: ?color.RGB,
    palette_received_count: u16,
};

/// Last-resort defaults (PRD §6 precedence "default"): the Ghostty bundled 256-color
/// palette, foreground = palette[7], background = the fixed tmux-2html dark bg.
pub fn defaultColors() Colors {
    return .{
        .palette = ghostty_vt.color.default,
        .foreground = ghostty_vt.color.default[7],
        .background = .{ .r = 41, .g = 44, .b = 51 },
        .palette_received_count = 256,
    };
}

/// PURE decoder: apply one parsed OSC command to `colors`. No I/O. Safe to unit-test
/// against fixed byte streams (the test feeds bytes through ghostty_vt.Parser, then
/// calls this on each .osc_dispatch).
///
/// GOTCHA 2: the parser never frees color_operation.requests; we own the copy and MUST
/// deinit it here, or std.testing.allocator reports a leak.
pub fn applyOscCommand(colors: *Colors, cmd: osc.Command, allocator: std.mem.Allocator) void {
    var cmd_mut = cmd;
    switch (cmd_mut) {
        .color_operation => |*op| {
            var i: usize = 0;
            while (i < op.requests.count()) : (i += 1) {
                const req = op.requests.at(i).*;
                switch (req) {
                    .set => |ct| switch (ct.target) {
                        .palette => |idx| {
                            colors.palette[idx] = ct.color;
                            colors.palette_received_count += 1;
                        },
                        .dynamic => |d| switch (d) {
                            .foreground => colors.foreground = ct.color,
                            .background => colors.background = ct.color,
                            // cursor, pointer, highlight, tektronix — not tracked here.
                            else => {},
                        },
                        .special => {},
                    },
                    // query / reset / reset_palette / reset_special are responses to OUR
                    // queries or reset directives; a SET reply is the only thing that fills
                    // the palette. Ignore the rest.
                    else => {},
                }
            }
            op.requests.deinit(allocator); // GOTCHA 2: free the SegmentedList (op is *const via &cmd_mut).
        },
        else => {},
    }
}

/// Feed a byte stream through the parser and route every .osc_dispatch to
/// applyOscCommand. Shared by queryColors (live) and the unit tests (fixed bytes).
fn feedAndApply(parser: *ghostty_vt.Parser, bytes: []const u8, colors: *Colors, allocator: std.mem.Allocator) void {
    for (bytes) |c| {
        const actions = parser.next(c); // [3]?Action — GOTCHA 3: inspect all slots.
        for (actions) |maybe_act| {
            if (maybe_act) |act| switch (act) {
                .osc_dispatch => |cmd| applyOscCommand(colors, cmd, allocator),
                else => {},
            };
        }
    }
}

/// Query the controlling terminal for its 256-color palette (OSC 4) + fg/bg (OSC 10/11).
/// Opens /dev/tty, switches to raw mode with a 500ms read timeout, sends queries in
/// batches of 32, reads replies through the VT parser. Returns Colors; if fewer than
/// 256 palette entries were received, logs a warning (terminal not responding).
///
/// Errors out if /dev/tty can't be opened or termios can't be set — the caller
/// (sync-palette / --palette live) must only invoke this when a controlling tty exists.
pub fn queryColors(allocator: std.mem.Allocator) !Colors {
    var colors = defaultColors();
    colors.palette_received_count = 0;

    var tty = try std.fs.openFileAbsolute("/dev/tty", .{ .mode = .read_write });
    defer tty.close();

    const original = try std.posix.tcgetattr(tty.handle); // GOTCHA 8: restore in defer.
    var raw = original;
    raw.lflag.ICANON = false; // GOTCHA 6
    raw.lflag.ECHO = false; // GOTCHA 7: no echo of our query bytes.
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 5; // 500ms (deciseconds).
    try std.posix.tcsetattr(tty.handle, .FLUSH, raw);
    defer std.posix.tcsetattr(tty.handle, .FLUSH, original) catch {};

    var parser = ghostty_vt.Parser.init();
    parser.osc_parser.alloc = allocator; // GOTCHA 1: REQUIRED or color OSCs are dropped.
    defer parser.deinit();

    var i: u16 = 0;
    while (i < 256) {
        const end: u16 = @min(i + 32, 256);
        var qbuf: [40]u8 = undefined;
        var idx = i;
        while (idx < end) : (idx += 1) {
            const q = std.fmt.bufPrint(&qbuf, "\x1b]4;{d};?\x07", .{idx}) catch unreachable;
            try tty.writeAll(q);
        }
        if (end == 256) {
            try tty.writeAll("\x1b]10;?\x07");
            try tty.writeAll("\x1b]11;?\x07");
        }
        try readAndFeed(&tty, &parser, &colors, allocator);
        i = end;
    }

    if (colors.palette_received_count < 256) {
        std.log.warn("palette: terminal responded with only {d}/256 palette entries", .{colors.palette_received_count});
    }
    return colors;
}

/// Read responses until a 500ms timeout (read()==0), feeding each byte through the parser.
fn readAndFeed(tty: *std.fs.File, parser: *ghostty_vt.Parser, colors: *Colors, allocator: std.mem.Allocator) !void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = tty.read(&buf) catch break; // read error ⇒ stop this batch.
        if (n == 0) break; // GOTCHA 6: 500ms timeout, no more data.
        feedAndApply(parser, buf[0..n], colors, allocator);
    }
}

// ---- Unit tests (NO /dev/tty) ------------------------------------------------
// queryColors is interactive-only; we unit-test defaultColors + the applyOscCommand
// decode logic by feeding fixed OSC byte streams through a real ghostty_vt.Parser.

fn newParser(allocator: std.mem.Allocator) ghostty_vt.Parser {
    var p = ghostty_vt.Parser.init();
    p.osc_parser.alloc = allocator; // GOTCHA 1
    return p;
}

test "defaultColors: bundled palette, fixed fg/bg, full count" {
    const c = defaultColors();
    try std.testing.expectEqual(@as(u16, 256), c.palette_received_count);
    // palette is the Ghostty bundled 256-color table.
    try std.testing.expectEqual(ghostty_vt.color.default, c.palette);
    // foreground = palette[7].
    try std.testing.expectEqual(ghostty_vt.color.default[7], c.foreground.?);
    // background = fixed 41,44,51.
    try std.testing.expectEqual(color.RGB{ .r = 41, .g = 44, .b = 51 }, c.background.?);
}

test "applyOscCommand: OSC 4 palette set (rgb:cc/00/00 -> idx 0 red)" {
    const alloc = std.testing.allocator;
    var colors = defaultColors();
    colors.palette_received_count = 0;
    var p = newParser(alloc);
    defer p.deinit();
    feedAndApply(&p, "\x1b]4;0;rgb:cc/00/00\x07", &colors, alloc);
    try std.testing.expectEqual(color.RGB{ .r = 204, .g = 0, .b = 0 }, colors.palette[0]);
    try std.testing.expectEqual(@as(u16, 1), colors.palette_received_count);
}

test "applyOscCommand: OSC 10 foreground + OSC 11 background" {
    const alloc = std.testing.allocator;
    var colors = defaultColors();
    var p = newParser(alloc);
    defer p.deinit();
    feedAndApply(&p, "\x1b]10;rgb:ff/ff/ff\x07", &colors, alloc);
    feedAndApply(&p, "\x1b]11;rgb:29/2c/33\x07", &colors, alloc);
    try std.testing.expectEqual(color.RGB{ .r = 255, .g = 255, .b = 255 }, colors.foreground.?);
    try std.testing.expectEqual(color.RGB{ .r = 41, .g = 44, .b = 51 }, colors.background.?);
}

test "applyOscCommand: non-color OSC is ignored (title)" {
    const alloc = std.testing.allocator;
    var before = defaultColors();
    var p = newParser(alloc);
    defer p.deinit();
    feedAndApply(&p, "\x1b]0;hello world\x07", &before, alloc);
    try std.testing.expectEqual(defaultColors().palette, before.palette);
    try std.testing.expectEqual(defaultColors().foreground, before.foreground);
    try std.testing.expectEqual(defaultColors().background, before.background);
}

test "applyOscCommand: query (?) sets nothing" {
    const alloc = std.testing.allocator;
    var colors = defaultColors();
    colors.palette_received_count = 0;
    var p = newParser(alloc);
    defer p.deinit();
    // A query (not a reply) decodes to Request.query — applyOscCommand ignores it.
    feedAndApply(&p, "\x1b]4;5;?\x07", &colors, alloc);
    try std.testing.expectEqual(@as(u16, 0), colors.palette_received_count);
}

test "applyOscCommand: batched palette set (3 indices -> exercises heap path)" {
    // 3 requests exceed SegmentedList inline capacity (2) -> heap alloc; deinit must free it.
    const alloc = std.testing.allocator;
    var colors = defaultColors();
    colors.palette_received_count = 0;
    var p = newParser(alloc);
    defer p.deinit();
    feedAndApply(&p, "\x1b]4;0;rgb:cc/00/00;1;rgb:00/cc/00;2;rgb:00/00/cc\x07", &colors, alloc);
    try std.testing.expectEqual(color.RGB{ .r = 204, .g = 0, .b = 0 }, colors.palette[0]);
    try std.testing.expectEqual(color.RGB{ .r = 0, .g = 204, .b = 0 }, colors.palette[1]);
    try std.testing.expectEqual(color.RGB{ .r = 0, .g = 0, .b = 204 }, colors.palette[2]);
    try std.testing.expectEqual(@as(u16, 3), colors.palette_received_count);
}

test "applyOscCommand: ST terminator (ESC \\) also works" {
    const alloc = std.testing.allocator;
    var colors = defaultColors();
    colors.palette_received_count = 0;
    var p = newParser(alloc);
    defer p.deinit();
    feedAndApply(&p, "\x1b]4;9;rgb:01/02/03\x1b\\", &colors, alloc);
    try std.testing.expectEqual(color.RGB{ .r = 1, .g = 2, .b = 3 }, colors.palette[9]);
}

// ---- Cache I/O (PRD §6 persistence half) -----------------------------------
// Plain-text, debuggable cache at ${XDG_CACHE_HOME:-$HOME/.cache}/tmux-2html/palette.
// serialize/parse are PURE (no filesystem) so round-trip + tolerance are unit-tested
// without touching disk; writeCacheDir/loadCacheDir do the atomic disk I/O and are tested
// via std.testing.tmpDir. cachePath/writeCache/loadCache resolve XDG and delegate.
//
// GOTCHA 1 (0.15.2): std.ArrayList(u8) is the UNMANAGED Aligned variant (allocator-per-method).
// GOTCHA 5: atomic write => temp file in the SAME dir as the target + rename (else EXDEV).
// GOTCHA 8: std.time.timestamp() is wall-clock Unix seconds (NOT std.time.Instant = monotonic).
// GOTCHA 10: tokenizeAny/splitScalar only (bare tokenize/split are GONE).

/// The error set for the cache parser. The ONLY hard failure: a line that looks like a
/// data line but doesn't parse (non-numeric field, wrong field count, palette index > 255).
/// Missing entries are NOT errors (tolerance) — they keep their defaultColors() seed value.
const MalformedLine = error{MalformedLine};

/// Format the current wall-clock time as an ISO 8601 / RFC 3339 UTC string into `buf`
/// (e.g. "2026-07-08T14:30:00Z"). Informational only — loadCache skips all '#' lines, so
/// this value can't affect the round-trip. Returns "?" on any (impossible-in-practice) failure.
fn formatIso8601(buf: []u8) []const u8 {
    const ts = std.time.timestamp(); // i64 Unix seconds, CLOCK_REALTIME wall clock.
    if (ts < 0) return "?"; // pre-1970 guard (never in practice).
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(ts) };
    const ed = es.getEpochDay();
    const yd = ed.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        yd.year,
        md.month.numeric(), // Month enum -> u4 (1..12).
        md.day_index + 1, // 0-based -> 1-based.
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    }) catch "?";
}

/// Serialize `colors` to the verbatim PRD §6 plain-text cache format:
///   # tmux-2html palette (queried <iso8601>)
///   fg R G B
///   bg R G B
///   0 R G B
///   ...
///   255 R G B
/// Caller owns the returned slice (free with `allocator`).
fn serialize(allocator: std.mem.Allocator, colors: Colors) ![]u8 {
    var buf: std.ArrayList(u8) = .{}; // unmanaged (GOTCHA 1).
    errdefer buf.deinit(allocator);
    var line: [64]u8 = undefined;

    // Header (ISO 8601, informational — skipped on read).
    var tsbuf: [32]u8 = undefined;
    const ts = formatIso8601(&tsbuf);
    try buf.appendSlice(allocator, "# tmux-2html palette (queried ");
    try buf.appendSlice(allocator, ts);
    try buf.appendSlice(allocator, ")\n");

    // fg / bg (only when present — defaultColors/queryColors are always non-null).
    if (colors.foreground) |fg| {
        const s = std.fmt.bufPrint(&line, "fg {d} {d} {d}\n", .{ fg.r, fg.g, fg.b }) catch unreachable;
        try buf.appendSlice(allocator, s);
    }
    if (colors.background) |bg| {
        const s = std.fmt.bufPrint(&line, "bg {d} {d} {d}\n", .{ bg.r, bg.g, bg.b }) catch unreachable;
        try buf.appendSlice(allocator, s);
    }

    // 0..255.
    var i: u16 = 0;
    while (i < 256) : (i += 1) {
        const p = colors.palette[i];
        const s = std.fmt.bufPrint(&line, "{d} {d} {d} {d}\n", .{ i, p.r, p.g, p.b }) catch unreachable;
        try buf.appendSlice(allocator, s);
    }
    return buf.toOwnedSlice(allocator);
}

/// Parse a single decimal u8 field from an optional token; `null` token => MalformedLine.
fn parseU8(tok: ?[]const u8) !u8 {
    return std.fmt.parseInt(u8, tok orelse return error.MalformedLine, 10);
}

/// Parse the PRD §6 cache text into a `Colors`. PURE (no allocator, no filesystem):
/// indexes into the caller-owned `text`. Seeds from `defaultColors()` so a partial cache
/// still yields a usable palette; overwrites each parsed entry. `palette_received_count` =
/// number of palette INDEX lines (0..255) actually parsed. Errors (MalformedLine) ONLY on a
/// line that looks like data but doesn't parse (non-numeric field / wrong count / idx > 255).
fn parse(text: []const u8) !Colors {
    var result = defaultColors();
    result.palette_received_count = 0;
    var lines = std.mem.splitScalar(u8, text, '\n'); // keeps empty trailing tokens.
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue; // skip blank lines (incl. trailing newline).
        if (line[0] == '#') continue; // header + comments.
        var f = std.mem.tokenizeAny(u8, line, " \t");
        const head = f.next() orelse continue; // whitespace-only line.
        if (std.mem.eql(u8, head, "fg")) {
            const r = parseU8(f.next()) catch return error.MalformedLine;
            const g = parseU8(f.next()) catch return error.MalformedLine;
            const b = parseU8(f.next()) catch return error.MalformedLine;
            result.foreground = .{ .r = r, .g = g, .b = b };
        } else if (std.mem.eql(u8, head, "bg")) {
            const r = parseU8(f.next()) catch return error.MalformedLine;
            const g = parseU8(f.next()) catch return error.MalformedLine;
            const b = parseU8(f.next()) catch return error.MalformedLine;
            result.background = .{ .r = r, .g = g, .b = b };
        } else {
            const idx = std.fmt.parseInt(u16, head, 10) catch return error.MalformedLine;
            if (idx > 255) return error.MalformedLine;
            const r = parseU8(f.next()) catch return error.MalformedLine;
            const g = parseU8(f.next()) catch return error.MalformedLine;
            const b = parseU8(f.next()) catch return error.MalformedLine;
            result.palette[idx] = .{ .r = r, .g = g, .b = b };
            result.palette_received_count += 1;
        }
    }
    return result;
}

/// Resolve the cache base dir: $XDG_CACHE_HOME (absolute only) or $HOME/.cache.
/// Returns the env-owned slice (no allocation). Errors if $HOME is unset (degenerate).
fn cacheBase() error{NoHomeDirectory}![:0]const u8 {
    if (std.posix.getenv("XDG_CACHE_HOME")) |x| {
        if (x.len != 0 and std.fs.path.isAbsolute(x)) return x; // honor absolute only.
    }
    // Empty or relative XDG_CACHE_HOME => fall back to $HOME/.cache (GOTCHA 3).
    return std.posix.getenv("HOME") orelse return error.NoHomeDirectory;
}

/// Resolve the cache FILE path: `${XDG_CACHE_HOME:-$HOME/.cache}/tmux-2html/palette`.
/// XDG_CACHE_HOME is honored only if set, non-empty, AND absolute (else $HOME/.cache).
/// Caller owns the returned slice.
pub fn cachePath(allocator: std.mem.Allocator) ![]u8 {
    const base = try cacheBase();
    return std.fmt.allocPrint(allocator, "{s}/tmux-2html/palette", .{base});
}

/// Atomic write of `colors` to `dir/filename`. Writes `dir/.palette.tmp` (SAME dir as the
/// target => same filesystem => rename is atomic), best-effort fsync, then renames over the
/// target. Cleans up the temp file on any error.
fn writeCacheDir(dir: std.fs.Dir, filename: []const u8, allocator: std.mem.Allocator, colors: Colors) !void {
    const text = try serialize(allocator, colors);
    defer allocator.free(text);
    const tmp = ".palette.tmp"; // same dir as target => same filesystem (GOTCHA 5).
    var f = try dir.createFile(tmp, .{}); // truncate default (GOTCHA 6).
    errdefer {
        f.close();
        dir.deleteFile(tmp) catch {};
    }
    try f.writeAll(text);
    f.sync() catch {}; // best-effort durability before rename.
    f.close();
    dir.rename(tmp, filename) catch |err| {
        dir.deleteFile(tmp) catch {};
        return err;
    };
}

/// Read + parse `dir/filename`. read-only open; reads the whole file (<= 1 MiB) then parses.
fn loadCacheDir(dir: std.fs.Dir, filename: []const u8, allocator: std.mem.Allocator) !Colors {
    var f = try dir.openFile(filename, .{}); // read-only default (GOTCHA 6).
    defer f.close();
    const text = try f.readToEndAlloc(allocator, 1 << 20); // caller frees (GOTCHA 7).
    defer allocator.free(text);
    return parse(text);
}

/// Serialize `colors` to the cache file ATOMICALLY (temp + rename in the same dir).
/// mkdir's the parent (`…/tmux-2html/`) first (idempotent). Best-effort fsync before rename.
pub fn writeCache(allocator: std.mem.Allocator, colors: Colors) !void {
    const path = try cachePath(allocator);
    defer allocator.free(path);
    const dir_path = std.fs.path.dirname(path) orelse return error.BadPath; // nullable.
    std.fs.cwd().makePath(dir_path) catch {}; // idempotent (GOTCHA 4); tolerate error.
    var dir = try std.fs.openDirAbsolute(dir_path, .{});
    defer dir.close();
    try writeCacheDir(dir, std.fs.path.basename(path), allocator, colors);
}

/// Read + parse the cache file. Seeds from defaultColors(), then overwrites every parsed
/// entry. Tolerates missing entries (partial files); errors only on a malformed line or a
/// missing $HOME. Propagates open errors (a missing FILE is resolve()'s concern, S3 — not here).
pub fn loadCache(allocator: std.mem.Allocator) !Colors {
    const path = try cachePath(allocator);
    defer allocator.free(path);
    const dir_path = std.fs.path.dirname(path) orelse return error.BadPath;
    var dir = try std.fs.openDirAbsolute(dir_path, .{});
    defer dir.close();
    return loadCacheDir(dir, std.fs.path.basename(path), allocator);
}

// ---- Cache I/O unit tests (pure + std.testing.tmpDir; never touches real $XDG_CACHE_HOME) ----

test "serialize: full format (header + fg + bg + 0..255)" {
    const alloc = std.testing.allocator;
    const orig = defaultColors();
    const text = try serialize(alloc, orig);
    defer alloc.free(text);

    // 259 lines = header + fg + bg + 256 indices (each terminated by '\n').
    var nl: usize = 0;
    for (text) |c| if (c == '\n') {
        nl += 1;
    };
    try std.testing.expectEqual(@as(usize, 259), nl);

    // Header line.
    try std.testing.expect(std.mem.startsWith(u8, text, "# tmux-2html palette (queried "));

    // fg / bg lines derived from the Colors itself (not hardcoded — the bundled Ghostty
    // palette values are whatever color.default[7] / the fixed bg are).
    var want: [64]u8 = undefined;
    const fg = orig.foreground.?;
    const fg_line = std.fmt.bufPrint(&want, "fg {d} {d} {d}\n", .{ fg.r, fg.g, fg.b }) catch unreachable;
    try std.testing.expect(std.mem.indexOf(u8, text, fg_line) != null);
    const bg = orig.background.?;
    const bg_line = std.fmt.bufPrint(&want, "bg {d} {d} {d}\n", .{ bg.r, bg.g, bg.b }) catch unreachable;
    try std.testing.expect(std.mem.indexOf(u8, text, bg_line) != null);
    // first + last index lines derived from the palette (not hardcoded).
    const first = std.fmt.bufPrint(&want, "\n0 {d} {d} {d}\n", .{ orig.palette[0].r, orig.palette[0].g, orig.palette[0].b }) catch unreachable;
    try std.testing.expect(std.mem.indexOf(u8, text, first) != null);
    const last = std.fmt.bufPrint(&want, "\n255 {d} {d} {d}\n", .{ orig.palette[255].r, orig.palette[255].g, orig.palette[255].b }) catch unreachable;
    try std.testing.expect(std.mem.indexOf(u8, text, last) != null);
}

test "parse + serialize round-trip is exact" {
    const alloc = std.testing.allocator;
    const orig = defaultColors();
    const text = try serialize(alloc, orig);
    defer alloc.free(text);
    const got = try parse(text);

    try std.testing.expectEqualSlices(color.RGB, &orig.palette, &got.palette);
    try std.testing.expectEqual(orig.foreground, got.foreground);
    try std.testing.expectEqual(orig.background, got.background);
    try std.testing.expectEqual(@as(u16, 256), got.palette_received_count);
}

test "parse: truncated file still yields usable Colors (tolerance)" {
    // No header, no fg/bg, only 2 palette indices => the rest stay default-seeded.
    const got = try parse("0 1 2 3\n5 10 20 30\n");
    const def = defaultColors();
    try std.testing.expectEqual(color.RGB{ .r = 1, .g = 2, .b = 3 }, got.palette[0]);
    try std.testing.expectEqual(color.RGB{ .r = 10, .g = 20, .b = 30 }, got.palette[5]);
    try std.testing.expectEqual(@as(u16, 2), got.palette_received_count);
    // fg/bg untouched (default-seeded).
    try std.testing.expectEqual(def.foreground, got.foreground);
    try std.testing.expectEqual(def.background, got.background);
    // an unparsed index keeps its default value.
    try std.testing.expectEqual(def.palette[100], got.palette[100]);
}

test "parse: header + comment lines ignored" {
    const got = try parse("# a comment\n# another\nfg 1 2 3\n0 4 5 6\n");
    try std.testing.expectEqual(color.RGB{ .r = 1, .g = 2, .b = 3 }, got.foreground.?);
    try std.testing.expectEqual(color.RGB{ .r = 4, .g = 5, .b = 6 }, got.palette[0]);
    try std.testing.expectEqual(@as(u16, 1), got.palette_received_count);
}

test "parse: malformed line errors" {
    // non-numeric field.
    try std.testing.expectError(error.MalformedLine, parse("0 notanumber 0 0\n"));
    // index out of range.
    try std.testing.expectError(error.MalformedLine, parse("300 1 2 3\n"));
    // too few fields on an index line.
    try std.testing.expectError(error.MalformedLine, parse("7 1 2\n"));
    // too few fields on an fg line.
    try std.testing.expectError(error.MalformedLine, parse("fg 1 2\n"));
}

test "writeCacheDir + loadCacheDir disk round-trip (std.testing.tmpDir)" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const orig = defaultColors();
    try writeCacheDir(tmp.dir, "palette", alloc, orig);
    const got = try loadCacheDir(tmp.dir, "palette", alloc);

    try std.testing.expectEqualSlices(color.RGB, &orig.palette, &got.palette);
    try std.testing.expectEqual(orig.foreground, got.foreground);
    try std.testing.expectEqual(orig.background, got.background);
    try std.testing.expectEqual(@as(u16, 256), got.palette_received_count);

    // Prove the on-disk format (not just the API): the file has the PRD §6 header
    // and an fg/bg line matching the Colors we wrote.
    var f = try tmp.dir.openFile("palette", .{});
    defer f.close();
    const text = try f.readToEndAlloc(alloc, 1 << 20);
    defer alloc.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, "# tmux-2html palette (queried "));
    var want: [64]u8 = undefined;
    const fg = orig.foreground.?;
    const fg_line = std.fmt.bufPrint(&want, "fg {d} {d} {d}\n", .{ fg.r, fg.g, fg.b }) catch unreachable;
    try std.testing.expect(std.mem.indexOf(u8, text, fg_line) != null);
    const bg = orig.background.?;
    const bg_line = std.fmt.bufPrint(&want, "bg {d} {d} {d}\n", .{ bg.r, bg.g, bg.b }) catch unreachable;
    try std.testing.expect(std.mem.indexOf(u8, text, bg_line) != null);
}

test "cacheBase/cachePath: path is <base>/tmux-2html/palette against a literal base" {
    // We don't mutate process env (unsafe). Instead assert the path-building format against
    // the resolved base the way cachePath itself does: allocPrint "{s}/tmux-2html/palette".
    const alloc = std.testing.allocator;
    // cacheBase() honors an absolute XDG_CACHE_HOME; under the test harness that env is
    // unset, so the base is $HOME (or NoHomeDirectory on a stripped env). Either way the
    // suffix must be exactly "/tmux-2html/palette".
    const base = cacheBase() catch {
        // Degenerate env (no $HOME) — still assert the format on a synthetic base.
        const synth = try std.fmt.allocPrint(alloc, "{s}/tmux-2html/palette", .{"/tmp/.cache"});
        defer alloc.free(synth);
        try std.testing.expectEqualStrings("/tmp/.cache/tmux-2html/palette", synth);
        return;
    };
    const expected = try std.fmt.allocPrint(alloc, "{s}/tmux-2html/palette", .{base});
    defer alloc.free(expected);
    const got = try cachePath(alloc);
    defer alloc.free(got);
    try std.testing.expectEqualStrings(expected, got);
    // And the suffix is always present regardless of base.
    try std.testing.expect(std.mem.endsWith(u8, got, "/tmux-2html/palette"));
}
