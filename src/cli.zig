const std = @import("std");

// P1.M1.T3.S1 stubs. The real flag parsing + behavior lands in later milestones
// (T3.S2: parg flag parser; P1.M2/P1.M3/P2/P3: subcommand bodies).
// Each returns the process exit code (0 ok, 1 usage/runtime, 2 capture/target).
// For this subtask they all report "not yet implemented" via error.NotImplemented.

pub fn render(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    _ = allocator;
    _ = args;
    return error.NotImplemented;
}

pub fn pane(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    _ = allocator;
    _ = args;
    return error.NotImplemented;
}

pub fn region(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    _ = allocator;
    _ = args;
    return error.NotImplemented;
}

pub fn syncPalette(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    _ = allocator;
    _ = args;
    return error.NotImplemented;
}
