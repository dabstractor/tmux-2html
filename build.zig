// S1 minimal build.zig stub — intentionally near-empty.
//
// S1's job is the MANIFEST (build.zig.zon), not the build graph. Full wiring
// (ghostty-vt import, parg module, -Dsimd option, version baking, test step,
// and the "tmux-2html" executable target) lands in sibling task P1.M1.T1.S2.
//
// The build runner only needs a parseable build.zig to evaluate the manifest
// for `zig build --fetch`; fetch resolves DECLARED deps without requiring them
// WIRED here (verified: empty build fn -> fetch exit 0).
const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b;
}
