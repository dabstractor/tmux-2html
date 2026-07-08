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
