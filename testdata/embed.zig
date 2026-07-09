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
