//! capture.zig — the tmux-capture subsystem (P2.M1.T1.S1 + S2 folded into one final shape).
//!
//! Scope: shell out to `tmux display-message` / `capture-pane` / `show-option` to resolve pane
//! geometry, capture ANSI, query tmux options, and produce a self-contained `Captured` result
//! that the pane subcommand renders. capture.zig is GHOSTTY-FREE, PALETTE-FREE, and PARG-FREE
//! (only `std`/`builtin`), so its unit tests are safe as SEPARATE `test` fns (no Terminal.init
//! cross-test GOTCHA) and it adds zero dependencies to the prod build.
//!
//! Mockability seam: a single-method `Runner` vtable (`{ ctx, runFn }`) threaded per-call as the
//! FIRST arg to every tmux-touching fn. Unit tests inject a `FakeTmux` via `Runner.ctx`; the prod
//! `pane` body passes `real`. This generalizes cli.syncPalette's body pointer + palette.resolve's
//! has_tty param (see research/findings.md §2). NO mutable global => per-test testdata never
//! cross-contaminates.
//!
//! Truncation (S2 delta): detected via `#{history_size} > effective`, NOT row counting. The S2
//! findings prove equal-count truncated/non-truncated cases are ambiguous by row count, so the
//! 3-field geometry query carries `history_size` and `wasTruncated` compares it to the effective
//! cap (strict `>`). The NOTICE text is computed in the pane subcommand (main.zig), not here.

const std = @import("std");
const builtin = @import("builtin");

/// 256 MiB cap on captured stdout. Overrides `Child.run`'s 50 KiB default
/// (`error.StdoutStreamTooLong` on big scrollbacks). See research/findings.md §1.2 fact #2.
const MAX_OUTPUT: usize = 1 << 28;

/// Capture mode (PRD §5.2). `.visible` is the default (only on-screen rows); `.full` captures
/// scrollback + visible (capped by history). Defined LOCALLY (mirrors palette.Mode's local
/// definition convention) so capture stays cli-free; the pane body maps cli.PaneOpts -> Mode.
pub const Mode = enum { visible, full };

/// Pane geometry from tmux (NOT ioctl — run-shell has no controlling tty). u16 cols/rows match
/// ghostty `size.CellCountInt` = `render.Size`. `history_size` is the pane's CURRENT scrollback
/// line count (`#{history_size}`) — drives truncation detection (S2 delta).
pub const Geometry = struct {
    cols: u16,
    rows: u16,
    history_size: u32,
};

/// Capture result. `ansi` is allocator-OWNED (caller frees). `truncated` is set by `capture()`
/// when the pane's scrollback exceeded the effective cap (PRD §13). `history_size`/`effective`
/// are surfaced so the subcommand can build the truncation NOTICE (capture sets them; pane
/// renders the message). `cols`/`rows` feed `render.Size`.
pub const Captured = struct {
    ansi: []u8,
    cols: u16,
    rows: u16,
    truncated: bool,
    history_size: u32,
    effective: u32,
};

/// The mockable seam (research/findings.md §2). ONE method; threaded per-call as the FIRST arg
/// to `geometry`/`capture`/`queryOption`/`querySessionName` so unit tests inject a FakeTmux
/// (per-test bytes in `ctx`) — NO live tmux server in unit tests, NO mutable global. `runFn`
/// type MUST be `anyerror![]u8` exactly (so realRun + FakeTmux.run share one pointer type).
pub const Runner = struct {
    ctx: *anyopaque,
    runFn: *const fn (ctx: *anyopaque, argv: []const []const u8, alloc: std.mem.Allocator) anyerror![]u8,

    pub fn run(self: Runner, argv: []const []const u8, alloc: std.mem.Allocator) anyerror![]u8 {
        return self.runFn(self.ctx, argv, alloc);
    }
};

/// Owning wrapper for `captureCmd`'s argv. `argv` is the token array (pass to `runner.run`);
/// `history_token` is the ONE owned entry (`"-<N>"`, full mode) that `deinit` frees. Static
/// literals + the borrowed pane slice are NOT freed. Mirrors palette.zig's ArrayList lifetime
/// management (the 0.15.2 unmanaged idiom).
pub const Cmd = struct {
    argv: [][]const u8,
    history_token: ?[]u8 = null,

    pub fn deinit(self: *Cmd, alloc: std.mem.Allocator) void {
        if (self.history_token) |t| alloc.free(t);
        alloc.free(self.argv);
    }
};

/// Errors from the capture subsystem. `BadGeometry` = display-message output not 3 ints;
/// the rest map spawn/exit failures (the prod `pane` body turns these into exit 2).
pub const CaptureError = error{
    BadGeometry, // display-message output not "cols rows history_size"
    TmuxSpawnFailed, // Child.run couldn't spawn
    TmuxNonZeroExit, // tmux exited !=0 (bad pane id, no server, ...)
    TmuxAbnormalExit, // signal/stop
    OutOfMemory,
};

// ============================================================================
// The REAL runner — shells out via std.process.Child.run (verified, findings.md §1).
// ============================================================================

/// The prod subprocess runner. `Child.run` spawns stdin=.Ignore/stdout=.Pipe/stderr=.Pipe,
/// collects both via `std.Io.poll` (deadlock-safe), `wait()`s (reaps — no zombie), returns
/// `RunResult{ term, stdout, stderr }`. `.env_map` UNSET => inherits `$TMUX`/`$TMUX_PANE`
/// (REQUIRED so a bare `tmux` argv[0] connects to the right server). `.expand_arg0` UNSET
/// (`.no_expand`) still PATH-searches argv[0]="tmux" (execvpe). `.max_output_bytes` OVERRIDDEN
/// (default 50 KiB truncates big scrollbacks).
fn realRun(ctx: *anyopaque, argv: []const []const u8, alloc: std.mem.Allocator) anyerror![]u8 {
    _ = ctx; // stateless
    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = argv,
        .max_output_bytes = MAX_OUTPUT, // 1<<28 — NOT the 50 KiB default (would truncate big panes)
        // .env_map omitted => child INHERITS parent env ($TMUX, $TMUX_PANE, PATH)
        // .expand_arg0 omitted (.no_expand) => execvpe still PATH-searches "tmux"
    }) catch return error.TmuxSpawnFailed;
    defer alloc.free(result.stderr); // collected but unused
    switch (result.term) {
        .Exited => |code| if (code != 0) {
            alloc.free(result.stdout);
            return error.TmuxNonZeroExit;
        },
        else => { // .Signal / .Stopped / .Unknown
            alloc.free(result.stdout);
            return error.TmuxAbnormalExit;
        },
    }
    return result.stdout; // caller owns
}

/// Backing state for `real.ctx` — a `var` lvalue so `&real_state` is `*RealState` and coerces to
/// `*anyopaque` (a `const` yields `*const T` which does NOT coerce; see findings.md §2).
const RealState = struct {};
var real_state: RealState = .{};

/// The concrete prod `Runner`. The `pane` body passes THIS to every tmux-touching fn.
pub const real: Runner = .{ .ctx = @ptrCast(&real_state), .runFn = realRun };

// ============================================================================
// PURE argv builders + pure truncation math (unit-testable directly, no I/O).
// ============================================================================

/// PURE argv builder for `tmux capture-pane` (verified vs local tmux 3.6b man page, findings.md §3).
///
/// - base (BOTH modes): `{ "tmux", "capture-pane", "-e", "-J", "-p", "-t", pane }` (7 tokens).
/// - `.full`: append `{ "-S", "-<history>", "-E", "-" }` (=> 11 tokens). `-S`/`-E` take the NEXT
///   argv token as their value even when it starts with `-`; NEVER glue (`-S-50000` is wrong).
///   `history_token` is owned (`"-<N>"`, freed by `Cmd.deinit`); the pane slice is BORROWED.
///
/// `capture` passes the EFFECTIVE cap (not the raw `--history`), so the `-S` flag receives the
/// tighter of `--history` vs `@tmux-2html-history-limit`.
pub fn captureCmd(
    alloc: std.mem.Allocator,
    pane: []const u8,
    mode: Mode,
    history: u32,
) !Cmd {
    var list: std.ArrayList([]const u8) = .empty; // unmanaged (0.15.2 idiom; palette.zig uses this)
    errdefer list.deinit(alloc);
    try list.appendSlice(alloc, &.{ "tmux", "capture-pane", "-e", "-J", "-p", "-t", pane });
    var hist_tok: ?[]u8 = null;
    if (mode == .full) {
        hist_tok = try std.fmt.allocPrint(alloc, "-{d}", .{history}); // e.g. "-50000" (OWNED)
        errdefer if (hist_tok) |t| alloc.free(t);
        try list.appendSlice(alloc, &.{ "-S", hist_tok.?, "-E", "-" });
    }
    return .{ .argv = try list.toOwnedSlice(alloc), .history_token = hist_tok };
}

/// PURE: the effective history cap = min(cli `--history`, configured `@tmux-2html-history-limit`).
/// Both default to 50000 (cli.PaneOpts.history, PRD §9.2); the tighter cap wins (S2 findings).
pub fn effectiveHistory(cli_history: u32, configured_limit: u32) u32 {
    return @min(cli_history, configured_limit);
}

/// PURE: was the capture truncated? `.visible` never truncates (no scrollback). `.full` truncates
/// iff the pane's scrollback (`history_size`) STRICTLY exceeded the effective cap (findings.md:
/// equal-count cases are ambiguous by row counting; `#{history_size}` is the exact signal).
pub fn wasTruncated(mode: Mode, history_size: u32, effective: u32) bool {
    return (mode == .full) and (history_size > effective);
}

// ============================================================================
// geometry + capture — shell out via the Runner seam (FakeTmux in tests, real in prod).
// ============================================================================

/// Pane geometry + scrollback size via ONE `display-message` call (findings.md §3.1 + S2 delta).
///
/// Runs `tmux display-message -p -t <pane> "#{pane_width} #{pane_height} #{history_size}"`
/// (ONE format-string argv token => ONE subprocess call printing "80 24 49\n"), trims, splits on
/// `' '`, requires EXACTLY 3 integer fields (cols u16, rows u16, history_size u32). Malformed
/// (not 3 ints, or 2/4 fields) => `error.BadGeometry`.
pub fn geometry(runner: Runner, alloc: std.mem.Allocator, pane: []const u8) CaptureError!Geometry {
    const out = runner.run(
        &.{ "tmux", "display-message", "-p", "-t", pane, "#{pane_width} #{pane_height} #{history_size}" },
        alloc,
    ) catch |err| switch (err) {
        error.TmuxSpawnFailed => return error.TmuxSpawnFailed,
        error.TmuxNonZeroExit => return error.TmuxNonZeroExit,
        error.TmuxAbnormalExit => return error.TmuxAbnormalExit,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.TmuxAbnormalExit, // FakeTmux errors + any unexpected -> fail geometry
    };
    defer alloc.free(out);
    const s = std.mem.trim(u8, out, " \t\n\r");
    var it = std.mem.splitScalar(u8, s, ' ');
    const cols_s = it.next() orelse return error.BadGeometry;
    const rows_s = it.next() orelse return error.BadGeometry;
    const hist_s = it.next() orelse return error.BadGeometry;
    if (it.next() != null) return error.BadGeometry; // a 4th token => malformed
    const cols = std.fmt.parseInt(u16, cols_s, 10) catch return error.BadGeometry;
    const rows = std.fmt.parseInt(u16, rows_s, 10) catch return error.BadGeometry;
    const history_size = std.fmt.parseInt(u32, hist_s, 10) catch return error.BadGeometry;
    return .{ .cols = cols, .rows = rows, .history_size = history_size };
}

/// The full capture: geometry + capture-pane run -> `Captured`. `history` is the cli `--history`
/// value; `configured_limit` is the resolved `@tmux-2html-history-limit` (default 50000). The
/// `-S` flag receives the EFFECTIVE cap (`effectiveHistory`), and `truncated` is computed via
/// `wasTruncated(mode, geom.history_size, effective)`. `ansi` is caller-owned (free via Captured).
pub fn capture(
    runner: Runner,
    alloc: std.mem.Allocator,
    pane: []const u8,
    mode: Mode,
    history: u32,
    configured_limit: u32,
) CaptureError!Captured {
    const geom = try geometry(runner, alloc, pane);
    const eff = effectiveHistory(history, configured_limit);
    const trunc = wasTruncated(mode, geom.history_size, eff);
    var cmd = try captureCmd(alloc, pane, mode, eff); // pass eff (the cap), NOT raw history
    defer cmd.deinit(alloc);
    const ansi = runner.run(cmd.argv, alloc) catch |err| switch (err) {
        error.TmuxSpawnFailed => return error.TmuxSpawnFailed,
        error.TmuxNonZeroExit => return error.TmuxNonZeroExit,
        error.TmuxAbnormalExit => return error.TmuxAbnormalExit,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.TmuxAbnormalExit,
    };
    return .{
        .ansi = ansi,
        .cols = geom.cols,
        .rows = geom.rows,
        .truncated = trunc,
        .history_size = geom.history_size,
        .effective = eff,
    };
}

// ============================================================================
// pane-helpers — option/session queries + output-dir/filename resolution (Runner-seamed).
// ============================================================================

/// Query a global tmux user option (`@tmux-2html-output-dir`, `@tmux-2html-history-limit`, ...).
/// Runs `tmux show-option -gqv <name>` (`-g` global, `-q` quiet on unset, `-v` value only).
/// On ANY error OR empty result => returns an empty owned slice (caller treats empty as "unset"
/// => default). Verified: an unset `@option` prints empty (findings.md / S2 research).
pub fn queryOption(runner: Runner, alloc: std.mem.Allocator, name: []const u8) ![]u8 {
    const out = runner.run(&.{ "tmux", "show-option", "-gqv", name }, alloc) catch {
        return alloc.alloc(u8, 0); // empty owned slice => caller treats as "unset"
    };
    defer alloc.free(out);
    const trimmed = std.mem.trim(u8, out, " \t\n\r");
    return alloc.dupe(u8, trimmed);
}

/// Query the session name for a pane (`#{session_name}`). Returns a TRIMMED owned slice. On error
/// => empty (caller falls back to "pane").
pub fn querySessionName(runner: Runner, alloc: std.mem.Allocator, pane: []const u8) ![]u8 {
    const out = runner.run(
        &.{ "tmux", "display-message", "-p", "-t", pane, "#{session_name}" },
        alloc,
    ) catch {
        return alloc.alloc(u8, 0);
    };
    defer alloc.free(out);
    const trimmed = std.mem.trim(u8, out, " \t\n\r");
    return alloc.dupe(u8, trimmed);
}

/// Resolve the output directory (PRD §9.2). Precedence:
///   1. explicit `@tmux-2html-output-dir` (if set + non-empty) wins;
///   2. else `$XDG_DATA_HOME/tmux-2html` (only if XDG_DATA_HOME is set, non-empty, AND absolute —
///      the freedesktop basedir-spec rule, mirrored from palette.cacheBase for XDG_CACHE_HOME);
///   3. else `$HOME/.local/share/tmux-2html`.
/// Caller owns the returned slice. `error.NoHome` if neither XDG nor HOME is usable.
pub fn resolveOutputDir(runner: Runner, alloc: std.mem.Allocator) ![]u8 {
    const opt = try queryOption(runner, alloc, "@tmux-2html-output-dir");
    defer alloc.free(opt);
    const t = std.mem.trim(u8, opt, " \t\n\r");
    if (t.len > 0) return alloc.dupe(u8, t); // explicit @tmux-2html-output-dir wins

    if (std.posix.getenv("XDG_DATA_HOME")) |x| {
        if (x.len != 0 and std.fs.path.isAbsolute(x)) {
            return std.fmt.allocPrint(alloc, "{s}/tmux-2html", .{x});
        }
    }
    const home = std.posix.getenv("HOME") orelse return error.NoHome;
    return std.fmt.allocPrint(alloc, "{s}/.local/share/tmux-2html", .{home});
}

// ============================================================================
// PURE filename helpers (collision-safe naming, PRD §13).
// ============================================================================

/// Sanitize a session name into a filename-safe token: replace every char NOT in `[A-Za-z0-9._-]`
/// with `_`; if empty => "pane". Session names can contain spaces/slashes. PURE.
pub fn sanitizeFilename(name: []const u8, out: []u8) []const u8 {
    var w: usize = 0;
    for (name) |c| {
        const ok = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or c == '.' or c == '_' or c == '-';
        if (out.len > w) {
            out[w] = if (ok) c else '_';
            w += 1;
        }
    }
    if (w == 0) {
        const fallback = "pane";
        const n = @min(fallback.len, out.len);
        @memcpy(out[0..n], fallback[0..n]);
        return out[0..n];
    }
    return out[0..w];
}

/// Build the collision-safe output filename `<sanitized-session>-<unixtime>-<pid>.html`. unixtime
/// (wall-clock seconds) + pid alone guarantee uniqueness across concurrent run-shell invocations;
/// session is a human hint (PRD §13). PURE. Caller owns the returned slice.
pub fn buildOutputFilename(
    alloc: std.mem.Allocator,
    session: []const u8,
    unixtime: i64,
    pid: i32,
) ![]u8 {
    var buf: [256]u8 = undefined;
    const san = sanitizeFilename(session, &buf);
    return std.fmt.allocPrint(alloc, "{s}-{d}-{d}.html", .{ san, unixtime, pid });
}

/// Join a directory + filename into a path. PURE. Caller owns the returned slice.
pub fn buildOutputPath(alloc: std.mem.Allocator, dir: []const u8, filename: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, filename });
}

// ============================================================================
// Tests — FakeTmux-driven (NO live tmux) + PURE helper unit tests. capture.zig does NOT touch
// Terminal.init, so these are SAFE as separate `test` fns (no ghostty-vt cross-test GOTCHA).
// ============================================================================

/// The test double: returns canned bytes per tmux subcommand. Per-instance state lives in `ctx`
/// (NO mutable global => per-test testdata never cross-contaminates; the key mockability proof).
const FakeTmux = struct {
    cols: u16,
    rows: u16,
    history_size: u32,
    ansi: []const u8,
    session: []const u8 = "sess",
    options: std.StringHashMap([]const u8),

    fn run(ctx: *anyopaque, argv: []const []const u8, alloc: std.mem.Allocator) anyerror![]u8 {
        const self: *FakeTmux = @ptrCast(@alignCast(ctx)); // @alignCast MANDATORY (0.15.2)
        if (hasArg(argv, "display-message")) {
            // geometry (3-field) vs session_name — distinguish by the format token.
            if (hasArg(argv, "#{pane_width} #{pane_height} #{history_size}")) {
                return std.fmt.allocPrint(alloc, "{d} {d} {d}", .{ self.cols, self.rows, self.history_size });
            }
            if (hasArg(argv, "#{session_name}")) {
                return alloc.dupe(u8, self.session);
            }
            return error.UnexpectedArgv;
        }
        if (hasArg(argv, "capture-pane")) {
            return alloc.dupe(u8, self.ansi); // caller frees
        }
        if (hasArg(argv, "show-option")) {
            // argv = { "tmux", "show-option", "-gqv", name }
            if (argv.len >= 4) {
                const name = argv[argv.len - 1];
                if (self.options.get(name)) |v| return alloc.dupe(u8, v);
            }
            return alloc.alloc(u8, 0); // unset => empty (caller treats as default)
        }
        return error.UnexpectedArgv;
    }
};

fn hasArg(argv: []const []const u8, needle: []const u8) bool {
    for (argv) |a| if (std.mem.eql(u8, a, needle)) return true;
    return false;
}

test "captureCmd: visible => exactly 7 tokens, no -S/-E, history_token==null" {
    const alloc = std.testing.allocator;
    var cmd = try captureCmd(alloc, "%5", .visible, 50000);
    defer cmd.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 7), cmd.argv.len);
    try std.testing.expectEqualStrings("tmux", cmd.argv[0]);
    try std.testing.expectEqualStrings("capture-pane", cmd.argv[1]);
    try std.testing.expectEqualStrings("-e", cmd.argv[2]);
    try std.testing.expectEqualStrings("-J", cmd.argv[3]);
    try std.testing.expectEqualStrings("-p", cmd.argv[4]);
    try std.testing.expectEqualStrings("-t", cmd.argv[5]);
    try std.testing.expectEqualStrings("%5", cmd.argv[6]);
    try std.testing.expect(!hasArg(cmd.argv, "-S"));
    try std.testing.expect(!hasArg(cmd.argv, "-E"));
    try std.testing.expectEqual(@as(?[]u8, null), cmd.history_token);
}

test "captureCmd: full => 11 tokens incl -S -<history> -E - ; argv[8] aliases history_token; 1000 => '-1000'" {
    const alloc = std.testing.allocator;
    var cmd = try captureCmd(alloc, "%7", .full, 1000);
    defer cmd.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 11), cmd.argv.len);
    try std.testing.expectEqualStrings("-S", cmd.argv[7]);
    try std.testing.expectEqualStrings("-1000", cmd.argv[8]);
    try std.testing.expectEqualStrings("-E", cmd.argv[9]);
    try std.testing.expectEqualStrings("-", cmd.argv[10]);
    // history_token aliases argv[8] (same slice)
    try std.testing.expect(cmd.history_token != null);
    try std.testing.expectEqualStrings(cmd.argv[8], cmd.history_token.?);
    try std.testing.expect(cmd.argv[8].ptr == cmd.history_token.?.ptr);
}

test "captureCmd: full with history=50000 => '-50000' token" {
    const alloc = std.testing.allocator;
    var cmd = try captureCmd(alloc, "%1", .full, 50000);
    defer cmd.deinit(alloc);
    try std.testing.expectEqualStrings("-50000", cmd.history_token.?);
}

test "geometry: fake '80 24 49' => Geometry{80,24,49}" {
    const alloc = std.testing.allocator;
    var opts = std.StringHashMap([]const u8).init(alloc);
    defer opts.deinit();
    var fake = FakeTmux{ .cols = 80, .rows = 24, .history_size = 49, .ansi = "", .options = opts };
    const runner: Runner = .{ .ctx = @ptrCast(&fake), .runFn = FakeTmux.run };
    const geom = try geometry(runner, alloc, "%5");
    try std.testing.expectEqual(@as(u16, 80), geom.cols);
    try std.testing.expectEqual(@as(u16, 24), geom.rows);
    try std.testing.expectEqual(@as(u32, 49), geom.history_size);
}

test "geometry: malformed cases => error.BadGeometry" {
    const alloc = std.testing.allocator;
    // A fake whose display-message reply is malformed for the 3-field parse.
    const MalformedFake = struct {
        reply: []const u8,
        fn run(ctx: *anyopaque, argv: []const []const u8, a: std.mem.Allocator) anyerror![]u8 {
            _ = argv;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return a.dupe(u8, self.reply);
        }
    };
    const cases = [_][]const u8{ "bogus", "80 24", "80 24 49 1", "80 24 notanum", "" };
    for (cases) |reply| {
        var fake = MalformedFake{ .reply = reply };
        const runner: Runner = .{ .ctx = @ptrCast(&fake), .runFn = MalformedFake.run };
        try std.testing.expectError(error.BadGeometry, geometry(runner, alloc, "%5"));
    }
}

test "effectiveHistory: min of the two" {
    try std.testing.expectEqual(@as(u32, 1000), effectiveHistory(1000, 50000));
    try std.testing.expectEqual(@as(u32, 50000), effectiveHistory(50000, 50000));
    try std.testing.expectEqual(@as(u32, 1000), effectiveHistory(50000, 1000));
    try std.testing.expectEqual(@as(u32, 0), effectiveHistory(0, 50000));
}

test "wasTruncated: full + history_size>eff => true; ==eff => false; visible => false" {
    // full, strictly greater => truncated
    try std.testing.expect(wasTruncated(.full, 100000, 50000));
    // full, equal => everything fit => NOT truncated
    try std.testing.expect(!wasTruncated(.full, 50000, 50000));
    // full, less => NOT truncated
    try std.testing.expect(!wasTruncated(.full, 100, 50000));
    // visible never truncates (no scrollback)
    try std.testing.expect(!wasTruncated(.visible, 100000, 50000));
    try std.testing.expect(!wasTruncated(.visible, 0, 50000));
}

test "capture: fake ansi + geometry => Captured (truncated per history_size)" {
    const alloc = std.testing.allocator;
    var opts = std.StringHashMap([]const u8).init(alloc);
    defer opts.deinit();
    const testdata = "\x1b[31mred\x1b[0m\nplain\n";
    var fake = FakeTmux{
        .cols = 80,
        .rows = 24,
        .history_size = 49,
        .ansi = testdata,
        .options = opts,
    };
    const runner: Runner = .{ .ctx = @ptrCast(&fake), .runFn = FakeTmux.run };
    // visible: history_size 49 < effective => NOT truncated
    const cap = try capture(runner, alloc, "%5", .visible, 50000, 50000);
    defer alloc.free(cap.ansi);
    try std.testing.expectEqual(@as(u16, 80), cap.cols);
    try std.testing.expectEqual(@as(u16, 24), cap.rows);
    try std.testing.expectEqual(@as(u32, 49), cap.history_size);
    try std.testing.expectEqual(@as(u32, 50000), cap.effective);
    try std.testing.expect(!cap.truncated);
    try std.testing.expectEqualStrings(testdata, cap.ansi);

    // full, small effective, big history_size => truncated
    var opts2 = std.StringHashMap([]const u8).init(alloc);
    defer opts2.deinit();
    var fake2 = FakeTmux{
        .cols = 80,
        .rows = 24,
        .history_size = 100000,
        .ansi = testdata,
        .options = opts2,
    };
    const runner2: Runner = .{ .ctx = @ptrCast(&fake2), .runFn = FakeTmux.run };
    const cap2 = try capture(runner2, alloc, "%5", .full, 50000, 50000);
    defer alloc.free(cap2.ansi);
    try std.testing.expect(cap2.truncated);
    try std.testing.expectEqual(@as(u32, 50000), cap2.effective);
}

test "capture: effective = min(cli, configured)" {
    const alloc = std.testing.allocator;
    var opts = std.StringHashMap([]const u8).init(alloc);
    defer opts.deinit();
    var fake = FakeTmux{ .cols = 80, .rows = 24, .history_size = 100000, .ansi = "x", .options = opts };
    const runner: Runner = .{ .ctx = @ptrCast(&fake), .runFn = FakeTmux.run };
    // cli=1000, configured=500 => effective 500, history_size 100000 > 500 => truncated
    const cap = try capture(runner, alloc, "%5", .full, 1000, 500);
    defer alloc.free(cap.ansi);
    try std.testing.expectEqual(@as(u32, 500), cap.effective);
    try std.testing.expect(cap.truncated);
}

test "capture: two fakes with different testdata do not cross-contaminate" {
    const alloc = std.testing.allocator;
    var opts1 = std.StringHashMap([]const u8).init(alloc);
    defer opts1.deinit();
    var opts2 = std.StringHashMap([]const u8).init(alloc);
    defer opts2.deinit();
    var fake_a = FakeTmux{ .cols = 80, .rows = 24, .history_size = 0, .ansi = "AAA", .options = opts1 };
    var fake_b = FakeTmux{ .cols = 40, .rows = 10, .history_size = 0, .ansi = "BBB", .options = opts2 };
    const ra: Runner = .{ .ctx = @ptrCast(&fake_a), .runFn = FakeTmux.run };
    const rb: Runner = .{ .ctx = @ptrCast(&fake_b), .runFn = FakeTmux.run };
    const ca = try capture(ra, alloc, "%1", .visible, 50000, 50000);
    defer alloc.free(ca.ansi);
    const cb = try capture(rb, alloc, "%2", .visible, 50000, 50000);
    defer alloc.free(cb.ansi);
    try std.testing.expectEqualStrings("AAA", ca.ansi);
    try std.testing.expectEqualStrings("BBB", cb.ansi);
    try std.testing.expectEqual(@as(u16, 80), ca.cols);
    try std.testing.expectEqual(@as(u16, 40), cb.cols);
}

test "queryOption: unset => empty; set => trimmed value" {
    const alloc = std.testing.allocator;
    var opts = std.StringHashMap([]const u8).init(alloc);
    defer opts.deinit();
    try opts.put("@tmux-2html-output-dir", "/custom/dir\n");
    var fake = FakeTmux{ .cols = 80, .rows = 24, .history_size = 0, .ansi = "", .options = opts };
    const runner: Runner = .{ .ctx = @ptrCast(&fake), .runFn = FakeTmux.run };

    // set => trimmed
    const v = try queryOption(runner, alloc, "@tmux-2html-output-dir");
    defer alloc.free(v);
    try std.testing.expectEqualStrings("/custom/dir", v);

    // unset => empty
    const e = try queryOption(runner, alloc, "@tmux-2html-history-limit");
    defer alloc.free(e);
    try std.testing.expectEqual(@as(usize, 0), e.len);
}

test "querySessionName: returns trimmed value; empty fallback handled by caller" {
    const alloc = std.testing.allocator;
    var opts = std.StringHashMap([]const u8).init(alloc);
    defer opts.deinit();
    var fake = FakeTmux{ .cols = 80, .rows = 24, .history_size = 0, .ansi = "", .session = "my session\n", .options = opts };
    const runner: Runner = .{ .ctx = @ptrCast(&fake), .runFn = FakeTmux.run };
    const s = try querySessionName(runner, alloc, "%5");
    defer alloc.free(s);
    try std.testing.expectEqualStrings("my session", s);
}

test "sanitizeFilename: replaces unsafe chars; empty => 'pane'" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("my_session", sanitizeFilename("my session", &buf));
    try std.testing.expectEqualStrings("a_b", sanitizeFilename("a/b", &buf));
    try std.testing.expectEqualStrings("abc-123._", sanitizeFilename("abc-123._", &buf));
    try std.testing.expectEqualStrings("pane", sanitizeFilename("", &buf));
    // whitespace-only => underscores (NOT empty => NOT the "pane" fallback)
    try std.testing.expectEqualStrings("___", sanitizeFilename("   ", &buf));
}

test "sanitizeFilename: buffer-bounded write" {
    var buf: [4]u8 = undefined;
    const out = sanitizeFilename("abcdefgh", &buf);
    try std.testing.expectEqual(@as(usize, 4), out.len);
    try std.testing.expectEqualStrings("abcd", out);
}

test "buildOutputFilename: 's',1700000000,1234 => 's-1700000000-1234.html'" {
    const alloc = std.testing.allocator;
    const fname = try buildOutputFilename(alloc, "s", 1700000000, 1234);
    defer alloc.free(fname);
    try std.testing.expectEqualStrings("s-1700000000-1234.html", fname);
}

test "buildOutputFilename: sanitizes the session name" {
    const alloc = std.testing.allocator;
    const fname = try buildOutputFilename(alloc, "my session", 1700000000, 1234);
    defer alloc.free(fname);
    try std.testing.expectEqualStrings("my_session-1700000000-1234.html", fname);
}

test "buildOutputPath: joins dir + filename" {
    const alloc = std.testing.allocator;
    const p = try buildOutputPath(alloc, "/tmp/out", "s-1-2.html");
    defer alloc.free(p);
    try std.testing.expectEqualStrings("/tmp/out/s-1-2.html", p);
}
