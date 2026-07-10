# P3.M3.T1.S2 design notes — confirm/cancel → renderGrid(selection) + .last-output sidecar

> S1 (P3.M3.T1.S1, IN PARALLEL) creates `src/region.zig` with `body()` whose `switch (action)`
> stubs `.confirm => 1`. **S2 FILLS that `.confirm` arm** + adds the helpers it needs. S2 EDITS
> `region.zig` ONLY (S1's file). It does NOT touch render.zig (uses the SHIPPED pub
> `render.toGhosttySelection`), cli.zig, main.zig, or build.zig. The `.quit`/`else` arms (cancel ⇒
> exit 1) are S1's and UNCHANGED. `defer app.exit(state)` (S1) restores the terminal on EVERY path.

## §0 The contract S2 consumes (from S1's region.zig, treated as a contract)

S1's `body(allocator, opts: cli.RegionOpts) anyerror!u8` shape (S1 PRP §2):
```zig
pub fn body(allocator: std.mem.Allocator, opts: cli.RegionOpts) anyerror!u8 {
    const target = opts.target orelse std.posix.getenv("TMUX_PANE") orelse { ...; return 2; };
    const cap = try regionPrepare(allocator, target, capture.real); // capture.Captured (cap.ansi owned)
    defer allocator.free(cap.ansi);
    const colors = palette.resolve(allocator, .cached, true); // INFALLIBLE; has_tty=true (popup pty)
    var t = try ghostty_vt.Terminal.init(allocator, .{ .cols = cap.cols, .rows = cap.rows });
    defer t.deinit(allocator);
    var stream = t.vtStream(); defer stream.deinit();
    for (cap.ansi) |c| { if (c == '\n') try stream.next('\r'); try stream.next(c); }
    const grid: *const ghostty_vt.Screen = t.screens.active;
    const total_rows: u32 = blk: { ... getBottomRight(.screen)+pointFromPin ... }; // >= 1
    ... pre-decode rows, SliceGrid, RegionCtx ...
    var ctx = RegionCtx{ .allocator = allocator, .grid = grid, .colors = colors,
        .tty_cols = ..., .tty_rows = ..., .total_rows = total_rows, .font = opts.font,
        .cursor = ..., .sel = select.Sel{}, .mgrid = mgrid, ... };
    defer ctx.deinit();
    const state = app.enter() catch { stderr "requires a terminal"; return 1; }; // NoTty ⇒ exit 1
    defer app.exit(state); // idempotent restore (atomic `entered` guard)
    repaint(&ctx) catch {};
    const action = app.runEvents(.{ .ctx = @ptrCast(&ctx), .handleFn = regionHandle }) catch |err| switch (err) {
        error.ReadFailed => .quit, else => return err,
    };
    return switch (action) {
        .quit => 1,
        .confirm => 1, // <<<< S1 STUB — S2 REPLACES THIS ARM
        else => 1,     // (.none never returned by runEvents; defensive)
    };
}
```
**S2's in-scope body locals** (all readable inside the `.confirm` arm): `allocator`, `opts`
(cli.RegionOpts: target/font/output/open), `target`, `cap` (Captured), `grid` (*const Screen),
`total_rows`, `colors` (palette.Colors), `ctx` (RegionCtx), `state` (app.State), and `capture.real`
(the pub Runner — usable directly). `RegionCtx` (S1) fields S2 reads: `sel` (select.Sel), `grid`,
`colors`, `tty_cols`, `font`. **S2 does NOT need `cap.ansi`** (it formats the EXISTING `grid`).

## §1 The confirm arm (the ENTIRE behavioral change to body)

The `.confirm => 1` stub becomes a labeled block. `app.exit(state)` is called FIRST so every
subsequent stderr/file write happens in COOKED mode (the empty-selection warn is readable, not
garbled in raw/alt-screen). `app.exit` is idempotent (S1/app.zig atomic `entered` guard) ⇒ the
body-scope `defer app.exit(state)` is a later no-op. This is the ONLY place S2 touches `body`.

```zig
.confirm => confirm_render: {
    // Restore the terminal BEFORE any I/O so warns/opens happen in cooked mode. Idempotent:
    // body's `defer app.exit(state)` (S1) is a later no-op (atomic `entered` guard in app.zig).
    app.exit(state);

    const stderr = std.fs.File.stderr();

    // PRD §7.5 / item description: empty selection ⇒ warn, no file, exit 1. "Empty" == no
    // selection begun (sel inactive). The TUI lets Enter/y through regardless (S1's handler
    // returns .confirm unconditionally); THIS arm is where the empty guard lives.
    if (!ctx.sel.active()) {
        stderr.writeAll("tmux-2html region: no selection (press v to begin, then Enter)\n") catch {};
        break :confirm_render 1;
    }

    // The binding (P2.M2.T2.S2) passes ONLY --target, so opts.font/opts.open are the unused cli
    // defaults. region reads the AUTHORITATIVE @tmux-2html-* options itself (tmux-2html.tmux
    // lines 81-82, 163-164; docs/CONFIGURATION.md "How options are read"). opts.open is OR'd in
    // so a direct `region --open` still works.
    const font = readFontOption(capture.real, allocator) catch ctx.font;
    defer allocator.free(font);
    const do_open = opts.open or readBoolOption(capture.real, allocator, "@tmux-2html-open", true);

    // Render the user's selection against the EXISTING grid (no Terminal rebuild). toGhosttySelection
    // (P3.M2.T2.S2, pub) returns a native ghostty Selection whose pins are tied to ctx.grid; the
    // ScreenFormatter formats it (the SAME block renderGrid uses internally — copy verbatim).
    const html = renderSelectionHtml(allocator, &ctx, font) catch {
        stderr.writeAll("tmux-2html region: render failed\n") catch {};
        break :confirm_render 1;
    };
    defer allocator.free(html);

    // Output path: explicit --output wins; else <session>-<unixtime>-<pid>.html in the configured
    // output dir (mirrors pane's panePrepare via the SHIPPED capture.* pub helpers).
    const path = resolveOutputPath(allocator, opts, target, capture.real) catch {
        stderr.writeAll("tmux-2html region: cannot resolve output path\n") catch {};
        break :confirm_render 1;
    };
    defer allocator.free(path);
    if (std.fs.path.dirname(path)) |dp| std.fs.cwd().makePath(dp) catch {}; // ensure dir exists

    // Atomic write (temp + rename in the same dir — render.zig's writeFileAtomic idiom).
    writeHtmlAtomic(allocator, path, html) catch {
        stderr.writeAll("tmux-2html region: cannot write output file\n") catch {};
        break :confirm_render 1;
    };

    // .last-output sidecar (PRD §7.5 + §9.3): write the BARE output path to a file named
    // `.last-output` in region's OWN executable dir. Exported loader vars ($TMUX_2HTML_BIN) do
    // NOT reach the popup child, so region derives its bin dir via /proc/self/exe (selfExePath).
    // Best-effort: a sidecar write failure does NOT fail the render (the file is already written).
    if (selfBinDir(allocator)) |bin_dir| {
        defer allocator.free(bin_dir);
        writeLastOutput(bin_dir, path) catch {};
    } else |_| {
        stderr.writeAll("tmux-2html region: cannot determine bin dir for .last-output sidecar\n") catch {};
    }

    // --open (best-effort; never changes the exit code — mirrors pane/render.spawnXdgOpen).
    if (do_open) render.spawnXdgOpen(path, allocator);

    break :confirm_render 0;
}
```

## §2 The helpers (NEW in region.zig; all module-private `fn`)

### §2a renderSelectionHtml — toGhosttySelection + ScreenFormatter against ctx.grid

REUSES the EXISTING grid (no Terminal rebuild) + the P3.M2.T2.S2 bridge. The ScreenFormatter
block is a VERBATIM copy of `render.renderGrid`'s body (render.zig ~lines 140-150): same
`.emit/.background/.foreground/.palette/.font` options, `f.content = .{ .selection = gs }`,
`f.extra = .styles`, `out.print("{f}", .{f})`. The ONLY differences: the screen is `ctx.grid`
(not a freshly-built Terminal) and the selection is `gs` (not built from cli coords).

```zig
const fmt = @import("ghostty_format.zig"); // ADD this import (S1's region.zig does NOT import it)

/// Render ctx.sel against the LOADED ctx.grid to an OWNED HTML buffer (caller frees). Uses
/// render.toGhosttySelection (P3.M2.T2.S2) + the vendored ScreenFormatter (the SAME block
/// render.renderGrid uses internally). NOT unit-testable (touches ctx.grid ⇒ Terminal ⇒ the
/// cross-test GOTCHA); the selection→HTML fidelity is ALREADY proven in render.zig's single
/// Terminal test scope (toGhosttySelection + formatSelOnScreen). region.zig is GLUE over it.
fn renderSelectionHtml(allocator: std.mem.Allocator, ctx: *RegionCtx, font: []const u8) ![]u8 {
    var aw = try std.Io.Writer.Allocating.initCapacity(allocator, 4096);
    defer aw.deinit();
    const gs = render.toGhosttySelection(ctx.sel, ctx.grid, ctx.tty_cols); // infallible; clamps
    var f = fmt.ScreenFormatter.init(ctx.grid, .{
        .emit = .html,
        .background = ctx.colors.background,
        .foreground = ctx.colors.foreground,
        .palette = &ctx.colors.palette,
        .font = font,
    });
    f.content = .{ .selection = gs }; // null = whole grid; some(gs) = the selection sub-grid
    f.extra = .styles;                // per-cell <span> inline CSS + OSC-8 <a> hyperlinks
    try aw.writer.print("{f}", .{f});
    return allocator.dupe(u8, aw.writer.buffered()); // OWNED copy (mirrors render.renderToOwned)
}
```

### §2b resolveOutputPath — --output or <session>-<ts>-<pid>.html in the output dir

Mirrors pane's panePrepare path logic but via the SHIPPED capture.* pub helpers (panePrepare is
coupled to PaneResult in main.zig + its `currentPid` is private, so region reimplements the tiny
pid fn). Unit-testable via a FakeTmux Runner (NO Terminal ⇒ safe as a separate test fn).

```zig
/// Resolve the output path: explicit `--output FILE` wins; else build the collision-safe
/// `<session>-<unixtime>-<pid>.html` in capture.resolveOutputDir (reads @tmux-2html-output-dir).
/// Caller owns the returned slice. Pure-ish (Runner-seamed; NO Terminal ⇒ unit-testable).
fn resolveOutputPath(
    allocator: std.mem.Allocator,
    opts: cli.RegionOpts,
    target: []const u8,
    runner: capture.Runner,
) ![]u8 {
    if (opts.output) |p| return allocator.dupe(u8, p); // explicit --output wins verbatim
    const out_dir = try capture.resolveOutputDir(runner, allocator); // @tmux-2html-output-dir/XDG/HOME
    defer allocator.free(out_dir);
    const session = capture.querySessionName(runner, allocator, target) catch
        try allocator.alloc(u8, 0); // empty ⇒ sanitizeFilename falls back to "pane"
    defer allocator.free(session);
    const sess_trim = std.mem.trim(u8, session, " \t\n\r");
    const ts = std.time.timestamp(); // Unix seconds (matches pane's panePrepare)
    const fname = try capture.buildOutputFilename(allocator, sess_trim, ts, regionPid());
    defer allocator.free(fname);
    return capture.buildOutputPath(allocator, out_dir, fname);
}

/// region's pid for collision-safe filenames (mirrors main.zig's private currentPid; Linux
/// getpid, else 0). Reimplemented here because currentPid is main.zig-private (region must not
/// edit main.zig — S1 owns the main.zig dispatch wiring).
fn regionPid() i32 {
    return if (builtin.os.tag == .linux) @intCast(std.os.linux.getpid()) else 0;
}
```
(`const builtin = @import("builtin");` — S1's region.zig imports it for nothing yet; ADD it if
S1 didn't. `std.time.timestamp` + `std.mem.trim` are std. `capture.resolveOutputDir` returns
`error.NoHome` if neither XDG nor HOME is usable — region maps that to the catch ⇒ exit 1 path.)

### §2c selfBinDir + writeLastOutput — the .last-output sidecar

region CANNOT see $TMUX_2HTML_BIN (exported loader vars don't reach run-shell/popup children —
P2.M2.T2.S2 GOTCHA). So it derives its OWN bin dir via `/proc/self/exe` (selfExePath). The sidecar
content is the BARE output path (the wrapper prepends "tmux-2html: wrote "). `writeLastOutput` is
split from `selfBinDir` so it is dir-scoped + unit-testable (inject a tmpDir as bin_dir).

```zig
/// region's OWN executable dir (where .last-output is written). Uses /proc/self/exe
/// (std.fs.selfExePath) since $TMUX_2HTML_BIN is NOT visible to the popup child. Caller owns the
/// returned slice. selfExePath is VERIFIED Zig 0.15.2 (fs.zig:545; takes a caller buffer, returns
/// a slice into it; max_path_bytes buffer is the documented size).
fn selfBinDir(allocator: std.mem.Allocator) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = try std.fs.selfExePath(&buf); // SelfExePathError if /proc unavailable (never in popup)
    const dir = std.fs.path.dirname(exe) orelse "."; // null for a bare filename ⇒ cwd
    return allocator.dupe(u8, dir);
}

/// Write the BARE `output_path` to `<bin_dir>/.last-output` (the wrapper reads it to display-message).
/// Overwrites (the wrapper pre-clears it via `rm -f`). Dir-scoped + unit-testable (inject tmpDir).
fn writeLastOutput(bin_dir: []const u8, output_path: []const u8) !void {
    const sidecar = try std.fs.path.join(std.heap.page_allocator, &.{ bin_dir, ".last-output" });
    defer std.heap.page_allocator.free(sidecar);
    var f = try std.fs.cwd().createFile(sidecar, .{ .truncate = true });
    defer f.close();
    try f.writeAll(output_path); // BARE path, NO "wrote" prefix (the wrapper prepends it)
}
```
(GOTCHA: `std.fs.path.join` needs an allocator; page_allocator is fine for this tiny transient
string. Alternatively use std.fmt.allocPrint(allocator, "{s}/.last-output", .{bin_dir}) + a free —
match whatever region.zig's idiom is. The join must NOT leak.)

### §2d writeHtmlAtomic — atomic temp+rename for the pre-rendered HTML buffer

Copies render.zig's PRIVATE `writeFileAtomic` idiom (render.zig ~lines 470-500) VERBATIM.
`render.renderToFileAtomic` is pub but renders the WHOLE grid (sel:null) — unusable for a
selection. `render.writeFileAtomic` is private. region reimplements the ~15-line atomic idiom
(temp + rename in the SAME dir ⇒ atomic, no EXDEV) for its pre-rendered buffer. No Terminal ⇒
unit-testable as a separate test fn (tmpDir round-trip).

```zig
/// Write pre-rendered `bytes` to `path` ATOMICALLY (temp + rename in the same dir). Mirrors
/// render.zig's writeFileAtomic idiom (same-dir temp ⇒ atomic rename). Cleans up the temp on
/// error. Unit-testable (fs only; NO Terminal).
fn writeHtmlAtomic(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
    const dir_path = std.fs.path.dirname(path) orelse ".";
    const base = std.fs.path.basename(path);
    var rnd: [4]u8 = undefined;
    std.crypto.random.bytes(&rnd);
    const tmp_name = try std.fmt.allocPrint(allocator, ".{s}.{x}.tmp", .{ base, @as(u32, @bitCast(rnd)) });
    defer allocator.free(tmp_name);
    var dir = if (std.fs.path.isAbsolute(dir_path))
        try std.fs.openDirAbsolute(dir_path, .{})
    else
        try std.fs.cwd().openDir(dir_path, .{});
    defer dir.close();
    var f = try dir.createFile(tmp_name, .{});
    errdefer { f.close(); dir.deleteFile(tmp_name) catch {}; }
    try f.writeAll(bytes);
    f.sync() catch {}; // best-effort durability before rename
    f.close();
    try dir.rename(tmp_name, base); // same dir ⇒ atomic
}
```

### §2e readBoolOption + readFontOption — the @tmux-2html-* option readers

region reads its behavior options itself (the binding passes only --target). Both Runner-seamed ⇒
unit-testable. `capture.queryOption` returns "" for unset (caller applies the default).

```zig
/// Read a boolean @tmux-2html-* option. "on"/"true"/"yes"/"1" ⇒ true; empty/unset ⇒ `default`;
/// any other value (e.g. "off") ⇒ false. Runner-seamed ⇒ unit-testable.
fn readBoolOption(runner: capture.Runner, allocator: std.mem.Allocator, name: []const u8, default: bool) bool {
    const v = capture.queryOption(runner, allocator, name) catch return default;
    defer allocator.free(v);
    const t = std.mem.trim(u8, v, " \t\n\r");
    if (t.len == 0) return default;
    return std.ascii.eqlIgnoreCase(t, "on") or std.ascii.eqlIgnoreCase(t, "true") or
        std.ascii.eqlIgnoreCase(t, "yes") or std.mem.eql(u8, t, "1");
}

/// Read @tmux-2html-font (default "monospace"). Caller owns the returned slice.
fn readFontOption(runner: capture.Runner, allocator: std.mem.Allocator) ![]u8 {
    const v = try capture.queryOption(runner, allocator, "@tmux-2html-font");
    defer allocator.free(v);
    const t = std.mem.trim(u8, v, " \t\n\r");
    if (t.len == 0) return allocator.dupe(u8, "monospace");
    return allocator.dupe(u8, t);
}
```

## §3 The render approach: WHY toGhosttySelection + format ctx.grid (NOT renderGrid rebuild)

`render.renderGrid(alloc, ansi, size, colors, sel: ?cli.SelectionCoords, font, out)` takes
`?cli.SelectionCoords` and builds its OWN Terminal internally. `render.toGhosttySelection(sel,
screen, cols)` returns a NATIVE `Selection` whose PINS are tied to `screen` (ctx.grid) — those
pins are INVALID for any other Terminal (a Pin is bound to the PageList it was created from). So
the two are mutually exclusive:
  - toGhosttySelection ⇒ format against ctx.grid DIRECTLY (ScreenFormatter). [S2's choice]
  - renderGrid ⇒ pass `cli.SelectionCoords` from `render.clampExtent(ext, cols, last_row)` (also
    pub from P3.M2.T2.S2) and let renderGrid rebuild an identical Terminal. [valid alternative]

S2 picks **toGhosttySelection + format ctx.grid** because: (a) it is exactly what the item
description says (`sel = toGhosttySelection(...)`) and what P3.M2.T2.S2 built toGhosttySelection
FOR (its doc: "the confirm-render input ... against the LOADED screen"); (b) it reuses the
EXISTING grid (no Terminal rebuild — cheaper, zero fidelity risk); (c) the ScreenFormatter block
is a verbatim copy of renderGrid's body (cited line-by-line). The ALTERNATIVE
(clampExtent + renderGrid) is equally correct — if the implementer prefers maximal renderGrid
reuse, swap §2a for:
```zig
// ALTERNATIVE renderSelectionHtml (option c — rebuild via renderGrid):
fn renderSelectionHtml(allocator, ctx: *RegionCtx, font: []const u8) ![]u8 {
    const ext = ctx.sel.extent(ctx.tty_cols) orelse return error.EmptySelection; // active() already checked
    const coords = render.clampExtent(ext, ctx.grid.pages.cols, ctx.total_rows - 1);
    var aw = try std.Io.Writer.Allocating.initCapacity(allocator, 4096);
    defer aw.deinit();
    try render.renderGrid(allocator, ctx_ansi, .{ .cols = ctx_cap_cols, .rows = ctx_cap_rows },
        ctx.colors, coords, font, &aw.writer); // needs cap.ansi + cap geometry in scope
    return allocator.dupe(u8, aw.writer.buffered());
}
```
(option c needs `cap.ansi` + `cap.cols`/`cap.rows` threaded into the arm; S1's body has `cap` in
scope so this is feasible. But it leaves `toGhosttySelection` prod-unused. Prefer option b.)

## §4 Unit-testable surface (ALL safe as SEPARATE test fns — NO Terminal anywhere)

S2's NEW logic that does NOT touch a Terminal (⇒ safe under the cross-test GOTCHA):
  - `resolveOutputPath` — Runner-seamed (FakeTmux). Tests: --output passthrough; auto-name
    (`<session>-<ts>-<pid>.html`) under resolveOutputDir; session fallback.
  - `writeLastOutput` — fs only (tmpDir as bin_dir). Test: writes the BARE path to
    `<bin_dir>/.last-output`; read back == input; no prefix.
  - `writeHtmlAtomic` — fs only (tmpDir). Test: writes bytes; read back == input; target exists
    (proves the rename completed). (Dir.iterate crashes under the test runner per render.zig's
    note, so do NOT iterate for `.tmp`; the rename-is-last-step invariant proves no leftover.)
  - `readBoolOption` / `readFontOption` — Runner-seamed. Tests: on/off/empty/unset/junk.
  - `regionPid` — getpid. Test: Linux ⇒ > 0.
  - `selfBinDir` — selfExePath. Test: returns a non-empty dir (the test binary's dir).

NOT unit-testable (Terminal + tty + tmux I/O ⇒ compile-verified + MANUAL Level 3/4):
  - the `.confirm` arm itself, `renderSelectionHtml` (touches ctx.grid), `body`.
  - Their integration (toGhosttySelection + ScreenFormatter) is ALREADY proven in render.zig's
    single Terminal test scope (P3.M2.T2.S2: formatSelOnScreen + the lw/block/clamp/wide asserts).

### §4a The region test FakeTmux (for resolveOutputPath/readFontOption/readBoolOption)
S1 added a FakeTmux for regionPrepare tests (module-private). S2's option/filename tests need a
fake that answers `show-option` (output-dir/font/open) + `display-message` (session_name). Define
a SELF-CONTAINED local fake (mirror main.zig's PaneFake) so S2's tests don't depend on S1's
exact FakeTmux naming:
```zig
const OptFake = struct {
    options: std.StringHashMap([]const u8),
    session: []const u8 = "sess",
    fn run(ctx: *anyopaque, argv: []const []const u8, alloc: std.mem.Allocator) anyerror![]u8 {
        const self: *OptFake = @ptrCast(@alignCast(ctx));
        const has = struct { fn f(a: []const []const u8, n: []const u8) bool {
            for (a) |x| if (std.mem.eql(u8, x, n)) return true; return false; } }.f;
        if (has(argv, "display-message")) {
            if (has(argv, "#{session_name}")) return alloc.dupe(u8, self.session);
            return error.UnexpectedArgv;
        }
        if (has(argv, "show-option")) {
            if (argv.len >= 4) if (self.options.get(argv[argv.len-1])) |v| return alloc.dupe(u8, v);
            return alloc.alloc(u8, 0); // unset ⇒ empty
        }
        return error.UnexpectedArgv;
    }
};
```

## §5 Gotchas (the load-bearing ones)

- **app.exit(state) FIRST in the arm.** The empty-selection warn (stderr) + xdg-open must happen
  in COOKED mode, not raw/alt-screen. `defer app.exit(state)` (S1) runs AFTER the switch; calling
  `app.exit(state)` at the top of the arm restores early. Idempotent (app.zig atomic `entered`
  guard) ⇒ the deferred call is a no-op. Do NOT skip this or the warn is garbled.
- **The empty-selection guard is `!ctx.sel.active()`.** S1's handler returns `.confirm` on Enter/y
  REGARDLESS of sel state (it does not gate confirm on a selection). So a user CAN press Enter with
  no selection; THIS arm catches it (warn + exit 1, no file, no sidecar). "Empty" == inactive sel.
- **toGhosttySelection is infallible** (returns `Selection`, not an error union — it CLAMPS instead
  of erroring). So `renderSelectionHtml`'s only error paths are OOM/write. Do NOT `try` the
  toGhosttySelection call's result as an error union.
- **ctx.grid stays valid after app.exit.** app.exit restores the DISPLAY terminal (termios/screen);
  ctx.grid is the in-memory ghostty Terminal (freed by `defer t.deinit` at body end). So formatting
  ctx.grid in renderSelectionHtml AFTER app.exit is safe.
- **The sidecar is BEST-EFFORT.** A `.last-output` write failure (e.g. bin dir not writable) must
  NOT fail the render — the HTML file is already written. The arm logs to stderr + continues to 0.
  (The wrapper only display-messages if .last-output exists; a missing sidecar ⇒ no message, which
  is graceful, not a crash.)
- **region must NOT print the summary to stdout.** The popup closes via `-E` on exit; stdout is the
  popup pty. The path reaches the user ONLY via the .last-output sidecar → wrapper → display-message
  (PRD §7.5: the popup has no tmux message channel). The ONLY stderr output is the warn/error lines.
- **The binding passes ONLY --target.** So opts.font/opts.open/output are the cli defaults; region
  reads @tmux-2html-font/@tmux-2html-open/output-dir itself (capture.queryOption/resolveOutputDir).
  Passing --font/--open from the binding would error (parseRegion accepts them, but the binding
  intentionally doesn't — single source of truth). opts.open is OR'd in for direct invocation.
- **writeHtmlAtomic duplicates render.zig's writeFileAtomic** (private). This is INTENTIONAL — keeps
  render.zig untouched (P3.M2.T2.S2 owns it in parallel) and render.renderToFileAtomic renders the
  whole grid (sel:null), unusable for a selection. The idiom is small (~15 lines) + cited verbatim.
- **regionPid duplicates main.zig's currentPid** (private). Intentional — region must not edit
  main.zig (S1 owns the dispatch wiring there). 3 lines.
- **selfExePath buffer = std.fs.max_path_bytes** (Zig 0.15.2 fs.zig:545; `selfExePath(out_buffer:
  []u8) SelfExePathError![]u8`). Do NOT use the old `selfExePathAlloc` unless you prefer the alloc
  variant (`selfExePathAlloc(allocator) ![]u8`, fs.zig:521) — either works; the buffer variant
  avoids an allocation.
- **zig build test MUST use -Doptimize=ReleaseFast.** Debug hits the R_X86_64_PC64 linker bug with
  the bundled ghostty C++ SIMD libs (PRD §15). EVERY validation command uses ReleaseFast.
- **No new file, NO edit to render.zig/cli.zig/main.zig/build.zig.** S2 edits region.zig ONLY
  (fills the .confirm arm + adds the §2 helpers + the `fmt`/`builtin` imports if S1 didn't add them).
