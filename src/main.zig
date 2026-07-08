const std = @import("std");
const build_options = @import("build_options");
const parg = @import("parg");
const ghostty_vt = @import("ghostty-vt");

// S2 build-graph validation stub. Real CLI dispatch (--help, subcommands,
// flag parsing) is P1.M1.T3.S1, which will REPLACE/expand this file.
pub fn main() !void {
    // Force every imported module to be analyzed — proves the build wiring resolves.
    _ = parg;
    _ = ghostty_vt.Terminal;

    const gpa = std.heap.page_allocator;
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    const stdout = std.fs.File.stdout();
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--version")) {
            var buf: [64]u8 = undefined;
            const out = try std.fmt.bufPrint(&buf, "tmux-2html {s}\n", .{build_options.version});
            try stdout.writeAll(out);
            return;
        }
    }
    try stdout.writeAll("tmux-2html (build-graph stub; full CLI is P1.M1.T3.S1)\n");
}

test "smoke: build_options version is non-empty" {
    try std.testing.expect(build_options.version.len > 0);
}
