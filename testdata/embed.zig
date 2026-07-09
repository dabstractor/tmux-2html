//! embed.zig — compile-time embed of the golden fixtures (P1.M4.T2.S1).
//! @embedFile is confined to a module's package root; this file roots the testdata/ package so
//! its sibling .ansi/.html pairs resolve. Wired into the build via build.zig
//! (exe.root_module.addImport("testdata", testdata_mod)).
pub const Fixture = struct { name: []const u8, ansi: []const u8, html: []const u8 };

pub const fixtures = [_]Fixture{
    .{ .name = "hyperfine", .ansi = @embedFile("hyperfine.ansi"), .html = @embedFile("hyperfine.html") },
    .{ .name = "fastfetch", .ansi = @embedFile("fastfetch.ansi"), .html = @embedFile("fastfetch.html") },
    .{ .name = "hyperlink", .ansi = @embedFile("hyperlink.ansi"), .html = @embedFile("hyperlink.html") },
    .{ .name = "colors16", .ansi = @embedFile("colors16.ansi"), .html = @embedFile("colors16.html") },
    .{ .name = "colors256", .ansi = @embedFile("colors256.ansi"), .html = @embedFile("colors256.html") },
    .{ .name = "truecolor", .ansi = @embedFile("truecolor.ansi"), .html = @embedFile("truecolor.html") },
    .{ .name = "attributes", .ansi = @embedFile("attributes.ansi"), .html = @embedFile("attributes.html") },
    .{ .name = "osc8", .ansi = @embedFile("osc8.ansi"), .html = @embedFile("osc8.html") },
};

// Selection fixtures (P1.M4.T2.S2): each pairs an .ansi/.html with the EXACT geometry
// (cols/rows) + selection coords the .html was blessed under. The golden test renders each
// .ansi via renderGrid with its embedded coords and asserts byte-equal to the .html. S1's
// whole-grid fixtures (above, sel=null) are UNTOUCHED; this extends the harness to
// sub-rectangle selection (linewise + block). The .html is blessed from this binary
// (`render --cols N --rows M --palette default --selection X1,Y1,X2,Y2[,rect]`), so the
// embedded geometry EXACTLY matches the bless command.
pub const SelFixture = struct {
    name: []const u8,
    ansi: []const u8,
    html: []const u8,
    cols: u16,
    rows: u16,
    x1: u32,
    y1: u32,
    x2: u32,
    y2: u32,
    rect: bool,
};

pub const sel_fixtures = [_]SelFixture{
    .{
        .name = "sel_linewise",
        .ansi = @embedFile("sel_linewise.ansi"),
        .html = @embedFile("sel_linewise.html"),
        .cols = 20,
        .rows = 5,
        .x1 = 0,
        .y1 = 1,
        .x2 = 19,
        .y2 = 3,
        .rect = false,
    },
    .{
        .name = "sel_block",
        .ansi = @embedFile("sel_block.ansi"),
        .html = @embedFile("sel_block.html"),
        .cols = 10,
        .rows = 3,
        .x1 = 2,
        .y1 = 0,
        .x2 = 5,
        .y2 = 2,
        .rect = true,
    },
};
