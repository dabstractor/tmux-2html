const std = @import("std");
const build_options = @import("build_options");
const parg = @import("parg");
const cli = @import("cli.zig");

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
        return cli.syncPalette(allocator, sub_args);
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

test "dispatch routes known subcommand to cli stub" {
    // Known subcommand reaches the cli stub, which reports NotImplemented.
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.NotImplemented, dispatch(allocator, "render", &.{}));
    try std.testing.expectError(error.NotImplemented, dispatch(allocator, "sync-palette", &.{}));
}

test "version string is non-empty" {
    try std.testing.expect(version_string.len > 0);
}
