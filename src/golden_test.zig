//! golden_test.zig — golden harness: testdata/*.ansi -> byte-equal *.html (P1.M4.T2.S1).
//!
//! Mirrors term2html's `test "output matches testdata"` (architecture/render_pipeline.md §5):
//! inline for over fixtures, fixed Size{120,150}, defaultColors(), expectEqualStrings. Fixtures
//! are embedded at compile time via the `testdata` module (testdata/embed.zig). The .html is
//! blessed from THIS binary (`render --cols 120 --rows 150 --palette default`), so the pair is
//! self-consistent; the test pins it against future regressions.
//!
//! Separate file/own test fn is safe: the documented "ghostty-vt cross-test GOTCHA" does not
//! reproduce in ReleaseFast (the only mode that links here; research findings §0/§8). The
//! single inline-for-within-one-fn structure is term2html's idiom and stays safe regardless.

const std = @import("std");
const render = @import("render.zig");
const palette = @import("palette.zig");
const td = @import("testdata");

test "golden: testdata/*.ansi renders byte-equal to testdata/*.html" {
    inline for (td.fixtures) |fx| {
        var aw = try std.Io.Writer.Allocating.initCapacity(std.testing.allocator, 1 << 16);
        defer aw.deinit();
        try render.renderGrid(
            std.testing.allocator,
            fx.ansi,
            .{ .cols = 120, .rows = 150 },
            palette.defaultColors(),
            null, // sel: whole grid. (P1.M4.T2.S2 owns selection sub-rectangle goldens.)
            null, // font: null => formatter defaults "monospace" (matches the no---font bless cmd).
            &aw.writer,
        );
        const got = aw.writer.buffered();
        std.testing.expectEqualStrings(fx.html, got) catch |err| {
            std.debug.print(
                "\n[golden] fixture '{s}' mismatch ({s}): expected {d} bytes, got {d} bytes\n",
                .{ fx.name, @errorName(err), fx.html.len, got.len },
            );
            return err;
        };
    }
}
