name: "P2.M1.T2.S1 — pane subcommand: capture → renderGrid + filename collision avoidance + open"
description: |

---

## Goal

**Feature Goal**: A working `tmux-2html pane` subcommand that resolves a target pane, captures it via
`tmux capture-pane` (visible or full-scrollback, history-capped), resolves the palette in the tty-less
`run-shell` context, renders the **whole** grid to a self-contained HTML file, and writes it to a
**collision-safe** filename (`<session>-<unixtime>-<pid>.html`) in the configured output dir — or to an
explicit `--output FILE`. Optionally `xdg-open`s the result. Exits `2` on capture/target errors.

**Deliverable**:
1. `src/capture.zig` — the tmux-capture subsystem module (the prerequisite `P2.M1.T1.S1`/`S2`
   deliverable is **absent from the tree**; see "Critical dependency situation" below). It implements the
   full final contract: `Mode`, `Geometry`, `Captured`, the `Runner` mockable seam + `real`, `geometry`,
   `captureCmd`, `effectiveHistory`, `wasTruncated`, `capture`, plus the pane-helpers (`queryOption`,
   `querySessionName`, `resolveOutputDir`, `sanitizeFilename`, `buildOutputFilename`), a `FakeTmux` test
   double, and unit tests.
2. The `pane` subcommand **wired end-to-end**: a dir-scoped testable core `paneCore` + prod wrapper
   `paneBody` in `src/main.zig`, threaded through `cli.pane(alloc, args, body)` (mirroring
   `syncPalette`). `src/cli.zig`'s `pane` dispatch is changed from `error.NotImplemented` to call the body.
3. `src/main.zig` test block reaches capture's tests via `_ = @import("capture.zig");`.

**Success Definition**:
- `tmux-2html pane --full` (run inside tmux, `$TMUX`/`$TMUX_PANE` set) writes a valid standalone HTML
  file named `<session>-<unixtime>-<pid>.html` into `${XDG_DATA_HOME:-~/.local/share}/tmux-2html/`, using
  the **cached** palette (no `/dev/tty` probe).
- `tmux-2html pane --output /tmp/x.html --visible` writes exactly `/tmp/x.html`.
- `--open` spawns `xdg-open` on the written path (best-effort, never fails the command).
- Two concurrent `run-shell pane` invocations write two distinct files (no clobber).
- A nonexistent pane / unset `$TMUX_PANE`+no `--target` → exit `2` with a stderr message.
- `zig build test --release=fast` passes (all new + existing tests).

## Critical dependency situation (READ FIRST — affects task ordering)

**`src/capture.zig` does not exist.** Verified: `ls src/capture.zig` fails; `main.zig`'s test block
imports only palette/render/golden_test. Yet `tasks.json` marks `P2.M1.T1.S1` ("Pane geometry +
capture-pane command builder") **Complete**. This is the same pipeline-state corruption that halted
sibling **P2.M1.T1.S2** (see `../P2M1T1S2/issue_feedback.md`): S1 never landed, so the `Captured` type
that T2.S1 consumes is absent.

**Therefore this PRP is a self-contained CREATE.** It builds `src/capture.zig` in its **final shape**
(apply the S1 contract + the S2 delta together — no intermediate "S1 then rename" dance) and then wires
`pane`. This is exactly option (2) the S2 issue feedback names ("regenerate downstream PRPs as
self-contained CREATE specs"). The capture contract is taken **verbatim** from the already-done,
live-verified research in this repo — there is no guessing:
- `../P2M1T1S1/PRP.md` + `../P2M1T1S1/research/findings.md` (authoritative design; verified Zig 0.15.2
  `Child.run` + the `Runner` vtable seam + tmux 3.6b argv).
- `../P2M1T1S2/research/findings.md` (the S2 delta: `Geometry` gains `history_size`, `Captured` gains
  `truncated`, geometry becomes 3-field, `effectiveHistory`/`wasTruncated` are pure, `configured_limit`).

If the orchestrator later re-runs S1/S2, capture.zig will already satisfy them (they should no-op).

## Why

- `pane` is the primary user-facing capture flow — the plugin's `O` binding runs `run-shell "... pane
  --full --target #{pane_id}"` (PRD §9.3). Without it the plugin has no output.
- Concurrent `run-shell` captures (e.g. a user mashing `O`) must not clobber each other → session +
  unixtime + pid filenames (PRD §13).
- In the `run-shell` context there is **no controlling tty** (PRD §2.1, verified), so the palette must
  come from the **cache** (the live `/dev/tty` OSC query is skipped) — this is exactly what the
  `sync-palette` cache (P1.M2) exists to provide.

## What

```
tmux-2html pane [options]
  --target PANE       target pane id (default: $TMUX_PANE)
  --visible           only the visible rows (default)
  --full              entire scrollback + visible (mutually exclusive of --visible)
  --history N         with --full, cap scrollback to last N lines (default 50000)
  --font FAMILY       CSS font-family (default: monospace)
  --output FILE       write here instead of <output-dir>/<session>-<ts>-<pid>.html
  --open              xdg-open the output
```

### Success Criteria

- [ ] `pane --full` writes a standalone HTML file (contains `<pre class="term2html-output"…>`) to the
      configured output dir under a `<session>-<unixtime>-<pid>.html` name.
- [ ] With no `--target` and `$TMUX_PANE` unset → exit `2`, stderr message, no file written.
- [ ] A capture failure (bad pane id) → exit `2`.
- [ ] A write failure (output dir unwritable) → exit `1`.
- [ ] `--output FILE` writes exactly `FILE` (no auto-naming).
- [ ] `--open` opens the written path; never changes the exit code.
- [ ] Concurrent runs produce distinct files (unixtime+pid unique).
- [ ] Palette resolves from cache (no `/dev/tty` access under run-shell).
- [ ] Huge scrollback beyond `@tmux-2html-history-limit` → file still written AND a truncation notice
      emitted (PRD §13).
- [ ] `zig build test --release=fast` passes; no leaks under `std.testing.allocator`.

## All Needed Context

### Context Completeness Check

_Passes the "No Prior Knowledge" test_: every consumed API signature is given with its file:line, the
capture contract is reproduced verbatim from in-repo research, the exact tmux argv arrays are blessed,
and the validation commands are project-specific and verified. An implementer who has never seen this
codebase can build it from this PRP + the cited files.

### Documentation & References

```yaml
# MUST READ — in-repo authoritative sources (the capture design is already done + live-verified)
- file: plan/001_0c8587f91cb2/P2M1T1S1/PRP.md
  why: the AUTHORITATIVE capture.zig design (Size, Mode, Captured, Runner vtable, Cmd, real/realRun,
       geometry, captureCmd, capture, FakeTmux). Copy the blessed argv arrays + Implementation Patterns.
  section: "Implementation Tasks" + "Implementation Patterns & Key Details" + "Blessed argv reference"
- file: plan/001_0c8587f91cb2/P2M1T1S1/research/findings.md
  why: verified Zig 0.15.2 Child.run stdout capture (max_output_bytes override, env inheritance, reap),
       the mockable Runner seam rationale, and tmux 3.6b argv (display-message / capture-pane / -S/-E).
  section: "§1 Thread A", "§2 Thread B", "§3 Thread C"
- file: plan/001_0c8587f91cb2/P2M1T1S2/research/findings.md
  why: the S2 delta to fold in: Geometry{cols,rows,history_size}, Captured{...,truncated}, 3-field
       geometry format, effectiveHistory()/wasTruncated() are pure, configured_limit param, truncation
       detection via #{history_size} (NOT row counting). Apply these directly to capture.zig at birth.
  section: "KEY DESIGN DECISION" + "Consumer contract for the pane subcommand"
- file: PRD.md   # the live PRD (also snapshot at plan/.../prd_snapshot.md)
  why: §5.2 pane flags; §9.2 option table (@tmux-2html-output-dir, -history-limit, -open, -font);
       §9.3 bindings (pane is run via run-shell --target #{pane_id}, notify via display-message);
       §13 edge cases (history cap + truncation notice; concurrent-run filename uniqueness).
  section: "§5.2", "§9.2", "§9.3", "§13"

# Consumed APIs (REUSE — do NOT reimplement)
- file: src/render.zig:130   # pub fn renderGrid(alloc, ansi, size, colors, sel:?cli.SelectionCoords, font:?[]const u8, *std.Io.Writer)
  why: the ONE render primitive. pane renders the WHOLE grid => pass sel: null.
  pattern: see src/render.zig:214 renderToFileAtomic — atomic temp+rename write of a whole-grid render.
           REUSE renderToFileAtomic for the pane output (it calls renderGrid with sel:null internally).
  gotcha: out must be *std.Io.Writer (NEW IO). renderToFileAtomic already builds the writer bridge.
- file: src/render.zig:214   # fn renderToFileAtomic(alloc, path, ansi, render.Size, colors, font:?[]const u8) !void
  why: THE pane output path — renders ansi to `path` atomically (temp+rename, same dir). Reuse as-is.
- file: src/render.zig   # pub fn spawnXdgOpen(path, alloc)  (best-effort; reaps child; ghostty#5999)
  why: the --open handler. Reuse as-is (it ignores all failures).
- file: src/palette.zig:545  # pub fn resolve(alloc, mode: palette.Mode, has_tty: bool) Colors  (INFALLIBLE)
  why: pane colors. Call resolve(alloc, .cached, palette.hasControllingTty()).
  gotcha: returns Colors, NOT !Colors — NO `try`. .cached + has_tty=false (run-shell) => cached->default.
- file: src/palette.zig:361  # fn cacheBase()  (the XDG resolution pattern to MIRROR for the output dir)
  why: template for resolveOutputDir's XDG_DATA_HOME logic: honor env only if set, non-empty, AND
       absolute; else fall back to $HOME/.local/share.
- file: src/cli.zig:70    # pub const PaneOpts { target, visible, full, history:u32=50000, font, output, open }
  why: the parsed input. parsePane (cli.zig:184) is PURE and already wired; the body receives PaneOpts.
  gotcha: there is NO --palette flag on pane and NO --output-dir flag; pane hardcodes palette .cached and
          resolves output-dir via tmux option (see Implementation Tasks). Do NOT touch the parser.
- file: src/main.zig:162 / src/main.zig:223  # syncPaletteDir (dir-scoped testable core) / syncPaletteBody (prod wrapper)
  why: the EXACT pattern to mirror for pane. main.zig is the ONE module allowed to import cli+palette
       (and now render+capture). Thread the body through cli.pane(alloc, args, body) like syncPalette.
  pattern: SyncResult{code,summary} dir-scoped core tested via std.testing.tmpDir; prod wrapper resolves
           real paths + prints summary. Do the same: PaneResult{code,summary,output_path}.
- file: src/cli.zig:412  # pub fn syncPalette(alloc, args, body: *const fn(Allocator,SyncPaletteOpts)anyerror!u8)
  why: the body-function-pointer wiring pattern. Change cli.pane (cli.zig:384) from NotImplemented to the
       SAME shape: parse, on error reportError+return 1, else call body(allocator, opts).

# External (stable, primary)
- url: https://specifications.freedesktop.org/basedir-spec/latest/
  why: XDG_DATA_HOME resolution: honor only if set, non-empty, AND absolute; else $HOME/.local/share.
  critical: a relative/empty XDG_DATA_HOME must fall back (mirrors palette.cacheBase for XDG_CACHE_HOME).
```

### Current Codebase tree (relevant subset)

```bash
src/
  main.zig          # dispatch (cli.pane → NotImplemented); syncPaletteDir/Body pattern; test block
  cli.zig           # PaneOpts:70, parsePane:184, pane:384 (stub), syncPalette:412 (body-pointer pattern)
  render.zig        # renderGrid:130, renderToFileAtomic:214, writeFileAtomic:279, spawnXdgOpen, Size:28
  palette.zig       # resolve:545, hasControllingTty:491, Mode:463, cacheBase:361 (XDG pattern)
  ghostty_format.zig
  golden_test.zig
testdata/           # *.ansi / *.html golden fixtures
build.zig           # test step; zig build test REQUIRES -Doptimize=ReleaseFast
```

### Desired Codebase tree with file responsibilities

```bash
src/
  capture.zig       # NEW. tmux-capture subsystem (ghostty-free, palette-free, parg-free).
                    #   Types: Mode, Geometry, Captured, Runner(vtable), Cmd, real.
                    #   Fns: realRun, captureCmd (pure), geometry, effectiveHistory (pure),
                    #        wasTruncated (pure), capture, queryOption, querySessionName,
                    #        resolveOutputDir (XDG + @tmux-2html-output-dir), sanitizeFilename (pure),
                    #        buildOutputFilename (pure), buildOutputPath (pure).
                    #   Tests: FakeTmux-driven (NO live tmux) + pure-helper unit tests.
  main.zig          # MODIFIED: add `_ = @import("capture.zig");` to test block; add paneCore (dir-scoped
                    #   testable) + paneBody (prod wrapper); dispatch('pane') threads paneBody.
  cli.zig           # MODIFIED: pane(alloc,args) → pane(alloc,args,body); body call replaces NotImplemented.
build.zig           # NO CHANGE (capture.zig under src/ is auto-compiled on prod+test paths).
```

### Known Gotchas of our codebase & Library Quirks

```zig
// CRITICAL: src/capture.zig does NOT exist yet — this PRP CREATES it (full final S1+S2 contract).
//           Do NOT assume it; build it per Tasks 1–3 before wiring pane (Task 4).

// Child.run DEFAULT max_output_bytes is 50 KiB — FAR too small for full-scrollback capture
// (error.StdoutStreamTooLong). capture.realRun MUST pass .max_output_bytes = 1<<28.

// Child.run with .env_map UNSET inherits the parent env ($TMUX, $TMUX_PANE, PATH) — REQUIRED so a
// bare `tmux` argv[0] connects to the right server. Do NOT set env_map. .expand_arg0 default
// (.no_expand) STILL PATH-searches argv[0]="tmux". Child.run reaps internally (no zombie).

// palette.resolve returns Colors (NOT !Colors) — never `try` it. pane uses .cached +
// palette.hasControllingTty() (false under run-shell => live skipped => cached->default).

// renderGrid's out param is *std.Io.Writer (NEW IO). Do NOT build the bridge yourself — REUSE
// render.renderToFileAtomic(alloc, path, ansi, size, colors, font) which does renderGrid(sel:null)
// + atomic temp+rename internally.

// GHOSTTY-VT GOTCHA: separate test functions that each call Terminal.init (via renderGrid) CRASH
// (process-global state corruption). capture.zig NEVER touches Terminal.init => its tests are SAFE as
// separate `test` fns. Do NOT add a pane unit test that calls renderGrid — render is already proven in
// render.zig's single-scope test; cover pane's new logic (capture/filename/options) WITHOUT renderGrid,
// and verify the full render path via the Level-3 integration test.

// `zig build test` REQUIRES `-Doptimize=ReleaseFast` (Debug linker bug R_X86_64_PC64 with the bundled
// C++ SIMD libs; build.zig). Always pass --release=fast.

// std.ArrayList(T) is the UNMANAGED variant: init `var list: std.ArrayList(T) = .empty;`, pass `alloc`
// to appendSlice/toOwnedSlice/deinit (the 0.15.2 idiom palette.zig uses).

// capture.Runner.runFn type MUST be `anyerror![]u8` (not a narrow set) so realRun + FakeTmux.run share
// one pointer type. `*anyopaque -> *T` recovery needs `@ptrCast(@alignCast(ctx))` — @alignCast MANDATORY.
// The state backing ctx must be a `var` lvalue (a `const` yields *const T which won't coerce).
```

## Implementation Blueprint

### Data models and structure (src/capture.zig — final S1+S2 shape)

```zig
const std = @import("std");
const builtin = @import("builtin");

pub const Mode = enum { visible, full };

/// Pane geometry from tmux (NOT ioctl). u16 cols/rows match ghostty CellCountInt = render.Size.
/// history_size is the pane's CURRENT scrollback line count (#{history_size}) — drives truncation.
pub const Geometry = struct { cols: u16, rows: u16, history_size: u32 };

/// Capture result. `ansi` is allocator-OWNED (caller frees). `truncated` is set by capture() when
/// the pane's scrollback exceeded the effective cap (PRD §13). `history_size`/`effective` are surfaced
/// so the subcommand can build the truncation NOTICE (capture sets them; pane renders the message).
pub const Captured = struct { ansi: []u8, cols: u16, rows: u16, truncated: bool, history_size: u32, effective: u32 };

/// The mockable seam (generalizes cli.syncPalette's body pointer + palette.resolve's has_tty param).
/// ONE method; threaded per-call as the FIRST arg to geometry/capture/queryOption/querySessionName so
/// unit tests inject a FakeTmux (per-test bytes in ctx) — NO live tmux server in unit tests, NO mutable
/// global. runFn type MUST be `anyerror![]u8` exactly.
pub const Runner = struct {
    ctx: *anyopaque,
    runFn: *const fn (ctx: *anyopaque, argv: []const []const u8, alloc: std.mem.Allocator) anyerror![]u8,
    pub fn run(self: Runner, argv: []const []const u8, alloc: std.mem.Allocator) anyerror![]u8 {
        return self.runFn(self.ctx, argv, alloc);
    }
};

/// Owning wrapper for captureCmd's argv. argv is the token array (pass to runner.run); history_token is
/// the ONE owned entry ("-<N>", full mode) that deinit frees. Static literals + the borrowed pane slice
/// are NOT freed. Mirror palette.zig's ArrayList lifetime mgmt.
pub const Cmd = struct {
    argv: [][]const u8,
    history_token: ?[]u8 = null,
    pub fn deinit(self: *Cmd, alloc: std.mem.Allocator) void {
        if (self.history_token) |t| alloc.free(t);
        alloc.free(self.argv);
    }
};

pub const CaptureError = error{
    BadGeometry,          // display-message output not "cols rows history_size"
    TmuxSpawnFailed,      // Child.run couldn't spawn
    TmuxNonZeroExit,      // tmux exited !=0 (bad pane id, no server, ...)
    TmuxAbnormalExit,     // signal/stop
    OutOfMemory,
};

const MAX_OUTPUT: usize = 1 << 28; // 256 MiB — overrides Child.run's 50 KiB default
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: CREATE src/capture.zig — types + Runner seam + real runner (S1 Tasks 1–2)
  - IMPLEMENT the data models above (Mode, Geometry, Captured, Runner, Cmd, CaptureError, MAX_OUTPUT).
  - IMPLEMENT realRun(ctx, argv, alloc) anyerror![]u8:
      const result = std.process.Child.run(.{
          .allocator = alloc, .argv = argv, .max_output_bytes = MAX_OUTPUT,
          // .env_map OMITTED => inherits $TMUX/$TMUX_PANE. .expand_arg0 OMITTED => PATH-searches.
      }) catch return error.TmuxSpawnFailed;
      defer alloc.free(result.stderr);
      switch (result.term) {
          .Exited => |code| if (code != 0) { alloc.free(result.stdout); return error.TmuxNonZeroExit; },
          else    => { alloc.free(result.stdout); return error.TmuxAbnormalExit; },
      }
      return result.stdout; // caller owns
  - STATE: `const RealState = struct {};` + `var real_state: RealState = .{};` (var, NOT const).
  - `pub const real: Runner = .{ .ctx = @ptrCast(&real_state), .runFn = realRun };`
  - FOLLOW pattern: render.zig spawnXdgOpen (Child idiom). Source: ../P2M1T1S1/research/findings.md §1.
  - PLACEMENT: src/capture.zig. Imports: std, builtin ONLY (ghostty-free, palette-free).

Task 2: captureCmd (PURE) + geometry (3-field) + effectiveHistory/wasTruncated (PURE) + capture
  - captureCmd(alloc, pane, mode, history) !Cmd — PURE argv builder:
      base (both modes): { "tmux","capture-pane","-e","-J","-p","-t",pane } (7).
      if mode==.full: hist = allocPrint("-{d}", .{history}); append { "-S", hist, "-E", "-" } (=> 11).
      Return Cmd{ argv: toOwnedSlice, history_token: hist-if-full-else-null }. pane is BORROWED.
      GOTCHA: -S/-E take the NEXT token even when it starts with '-'; NEVER glue ("-S-50000" is wrong).
  - geometry(runner, alloc, pane) !Geometry — 3-FIELD (S2 delta, NOT 2):
      out = runner.run(&.{ "tmux","display-message","-p","-t",pane, "#{pane_width} #{pane_height} #{history_size}" }, alloc)
      trim; splitScalar(' '); require EXACTLY 3 fields; parseInt u16,u16,u32; return Geometry.
      Malformed (not 3 ints) => error.BadGeometry. (Verify: #{history_size} prints a plain int; S2 findings.)
  - effectiveHistory(cli_history: u32, configured_limit: u32) u32 — PURE: @min(cli_history, configured_limit).
      (cli PaneOpts.history default 50000; configured_limit default 50000; tighter cap wins.)
  - wasTruncated(mode, history_size: u32, effective: u32) bool — PURE: (mode == .full) and (history_size > effective).
      (history_size == effective => everything fit => NOT truncated; strict >. Rationale: S2 findings —
       row-counting CANNOT distinguish equal-count truncated/non-truncated cases; #{history_size} can.)
  - capture(runner, alloc, pane, mode, history, configured_limit) !Captured:
      geom = geometry(runner, alloc, pane);
      eff  = effectiveHistory(history, configured_limit);
      trunc= wasTruncated(mode, geom.history_size, eff);
      var cmd = captureCmd(alloc, pane, mode, eff); defer cmd.deinit(alloc);   // pass eff (the cap), NOT history
      ansi  = runner.run(cmd.argv, alloc);                                     // caller owns via Captured
      return .{ .ansi = ansi, .cols = geom.cols, .rows = geom.rows, .truncated = trunc,
                .history_size = geom.history_size, .effective = eff };
  - SOURCE: ../P2M1T1S1/PRP.md "Implementation Patterns" (copy realRun/captureCmd/geometry bodies) +
            ../P2M1T1S2/research/findings.md (apply the 3-field + effectiveHistory + wasTruncated delta).

Task 3: capture.zig — pane-helpers (queryOption, querySessionName, resolveOutputDir) + PURE filename fns
  - queryOption(runner, alloc, name) ![]u8: run &.{ "tmux","show-option","-gqv",name }; return trimmed stdout.
      On ANY error OR empty result => return an empty owned slice (caller treats empty as "unset" => default).
      (Verified: unset @option prints empty; show-option needs -g (global) -q (quiet on unset) -v (value only).)
  - querySessionName(runner, alloc, pane) ![]u8: run &.{ "tmux","display-message","-p","-t",pane,"#{session_name}" };
      return trimmed stdout. On error => empty (caller falls back to "pane").
  - resolveOutputDir(runner, alloc) ![]u8 — produces the FULL output dir path (PRD §9.2 default
      `${XDG_DATA_HOME:-~/.local/share}/tmux-2html`). NOTE: do NOT blindly mirror palette.cacheBase —
      that helper returns $HOME only (a latent discrepancy vs its own $HOME/.cache doc comment). Produce
      the correct path for BOTH cases explicitly:
      opt = queryOption(runner, alloc, "@tmux-2html-output-dir"); defer alloc.free(opt);
      const t = std.mem.trim(u8, opt, " \t\n\r");
      if (t.len > 0) return alloc.dupe(u8, t);          // explicit @tmux-2html-output-dir wins
      if (std.posix.getenv("XDG_DATA_HOME")) |x| {
          if (x.len != 0 and std.fs.path.isAbsolute(x))
              return std.fmt.allocPrint(alloc, "{s}/tmux-2html", .{x});
      }
      const home = std.posix.getenv("HOME") orelse return error.NoHome;
      return std.fmt.allocPrint(alloc, "{s}/.local/share/tmux-2html", .{home});
      (Honor XDG_DATA_HOME only if set, non-empty, AND absolute — same rule as palette.cacheBase for
      XDG_CACHE_HOME; the freedesktop basedir-spec requires this. Caller owns the returned slice.)
  - sanitizeFilename(name) -> []const u8 into a caller buffer (or allocPrint): replace every char NOT in
      [A-Za-z0-9._-] with '_'; if empty => "pane". PURE, unit-tested. (Session names can contain spaces/slashes.)
  - buildOutputFilename(alloc, session, unixtime: i64, pid) ![]u8:
      return allocPrint("{s}-{d}-{d}.html", .{ sanitize(session), unixtime, pid }). (sanitize first.)
  - buildOutputPath(alloc, dir, filename) ![]u8: allocPrint("{s}/{s}", .{dir, filename}). PURE.

Task 4: MODIFY src/cli.zig — wire the pane body via a function pointer (mirror syncPalette:412)
  - CHANGE pub fn pane(allocator, args) !u8  =>  pub fn pane(allocator, args, body) !u8 where
      body: *const fn (std.mem.Allocator, cli.PaneOpts) anyerror!u8
  - BODY (mirror syncPalette exactly): hasHelpFlag(args) => print pane_help + return 0;
      parsePane(args) catch |err| { reportError("pane", err); return 1; };  else return body(allocator, opts).
  - PRESERVE: pane_help text, parsePane, reportError. Do NOT add flags (no --output-dir / --palette).

Task 5: MODIFY src/main.zig — paneBody (prod) + paneCore (dir-scoped testable) + dispatch + test import
  - ADD to the top-level `test { … }` block (alongside palette/render/golden_test imports):
      `_ = @import("capture.zig"); // P2.M1: keep capture.zig unit tests reachable.`
  - ADD imports: `const capture = @import("capture.zig");` (render is reachable via cli.zig's import, or
      add `const render_mod = @import("render.zig");` to main.zig to call renderToFileAtomic/spawnXdgOpen).
  - PaneResult = struct { code: u8, summary: []u8, output_path: []u8, notice: ?[]u8 };
      (all allocator-owned; notice is null unless truncated. Mirrors SyncResult{code,summary} but adds
      path + optional notice so the prod wrapper owns ALL I/O — the core does NONE, exactly like
      syncPaletteDir which returns a summary and never writes stdout itself.)
  - paneCore(alloc, opts, runner, out_dir) anyerror!PaneResult  — the dir-scoped testable core (NO real
      tmux, NO real $HOME; `runner` is FakeTmux in tests, `out_dir` is a tmpDir-realpath in tests):
      target = opts.target orelse std.posix.getenv("TMUX_PANE") orelse
               return fail(2, "no target pane ($TMUX_PANE unset and no --target)");
      mode = if (opts.full) .full else .visible;        // visible is the default
      configured_limit = parseU32Opt(capture.queryOption(runner, alloc, "@tmux-2html-history-limit")) orelse 50000;
      cap = capture.capture(runner, alloc, target, mode, opts.history, configured_limit) catch
            return fail(2, "cannot capture pane (bad target or tmux unavailable)");
      defer alloc.free(cap.ansi);
      path = if (opts.output) |p| alloc.dupe(alloc, p) else blk: {
          session = capture.querySessionName(runner, alloc, target); defer alloc.free(session);
          sess = if (trim(session).len>0) sanitize(...) else "pane";
          fname = capture.buildOutputFilename(alloc, sess, std.time.timestamp(), currentPid());
          dir   = out_dir;     // already resolved+ensured by the caller (prod wrapper or test)
          break :blk capture.buildOutputPath(alloc, dir, fname);
      };
      defer alloc.free(path);
      colors = palette.resolve(alloc, .cached, palette.hasControllingTty());
      capture/render: render_mod.renderToFileAtomic(alloc, path, cap.ansi,
                .{ .cols=cap.cols, .rows=cap.rows }, colors, opts.font) catch
          return fail(1, "cannot write output file");
      // Truncation NOTICE text (PRD §13) — computed here (cap is in scope) so it is unit-testable;
      // the prod wrapper (paneBody) does the actual stderr/display-message I/O (core does NO I/O).
      notice = if (cap.truncated)
          allocPrint("tmux-2html: capture truncated to {d} history lines (pane had {d}); older output dropped",
                     .{ cap.effective, cap.history_size })
      else null;
      summary = if (notice != null)
          allocPrint("wrote {s} (truncated)", .{path})
      else allocPrint("wrote {s}", .{path});
      return .{ .code=0, .summary=summary, .output_path=alloc.dupe(path), .notice=notice };
    NOTE: renderToFileAtomic calls renderGrid => Terminal.init. paneCore's UNIT TEST must therefore NOT
    also be a Terminal.init scope in a SEPARATE fn (ghostty GOTCHA). Two safe options — pick ONE:
      (a) Split paneCore at the render seam: a panePrepare(…)->{cap,path,truncated} (FakeTmux+tmpDir, NO
          render) that is unit-tested, and paneBody does prepare+render. panePrepare is the tested core.
      (b) Keep paneCore whole but exercise it in the ONE existing renderGrid test scope in render.zig
          (append assertions there), never as a standalone test fn.
    RECOMMENDED (a): test capture+filename+dir+truncation WITHOUT renderGrid (render is already proven).
  - currentPid(): on Linux `std.os.linux.getpid()` (os/linux.zig:1841). Guard `builtin.os.tag == .linux`.
  - paneBody(alloc, opts) anyerror!u8 — the prod wrapper (signature matches the body fn pointer):
      runner = capture.real;
      out_dir = capture.resolveOutputDir(runner, alloc) catch { stderr "cannot determine output dir"; return 1; };
      defer alloc.free(out_dir);  std.fs.cwd().makePath(out_dir) catch {};   // ensure it exists (idempotent)
      result = paneCore(alloc, opts, runner, out_dir);  defer free summary+output_path+notice;
      if (result.notice) |n| {                        // PRD §13 truncation notice — core computed the text
          std.fs.File.stderr().writeAll(n);            // always to stderr
          _ = runner.run(&.{ "tmux","display-message","-p", n }, alloc) catch {};  // best-effort; ignore
      }
      stdout writeAll(result.summary ++ "\n");
      if opts.open: render_mod.spawnXdgOpen(result.output_path, alloc);
      return result.code;
  - dispatch('pane'): change `return cli.pane(allocator, sub_args);` => `return cli.pane(allocator, sub_args, paneBody);`

Task 6: Truncation notice (PRD §13) — ALREADY wired in Task 5 (paneCore computes the text into
  PaneResult.notice; paneBody does stderr + best-effort display-message). No additional work; this task
  exists only to flag the PRD §13 requirement as satisfied. Captured carries truncated + history_size +
  effective (Task 1 data model) so NO re-query is needed. Do NOT fail the command if the display-message
  best-effort call errors (run-shell contexts without a tmux client still succeed).

Task 7: capture.zig unit tests (NO live tmux, NO ghostty-vt => separate test fns are SAFE)
  - FakeTmux{ cols:u16, rows:u16, history_size:u32, ansi:[]const u8, options:StrMap, session:[]const u8 }
    with run(ctx,argv,alloc): recover self via @ptrCast(@alignCast(ctx)); then:
      hasArg "display-message" with "#{pane_width..." => allocPrint "{c} {r} {h}"
      hasArg "display-message" with "#{session_name}"  => dupe(self.session)
      hasArg "capture-pane"                              => dupe(self.ansi)
      hasArg "show-option"                               => dupe(options[name]) or ""
      else error.UnexpectedArgv
  - TEST "captureCmd: visible => exactly 7 tokens, no -S/-E, history_token==null".
  - TEST "captureCmd: full => 11 tokens incl -S -<history> -E - ; argv[8] aliases history_token.?; history=1000 => '-1000'".
  - TEST "geometry: fake '80 24 49' => Geometry{80,24,49}; 'bogus'/'80 24'/'80 24 49 1' => error.BadGeometry".
  - TEST "effectiveHistory: min of the two; wasTruncated: full+history_size>eff => true; ==eff => false; visible => false".
  - TEST "capture: fake ansi + geometry + effective => Captured{ansi,cols,rows,truncated per history_size}".
  - TEST "two Fakes with different testdata do not cross-contaminate" (proves no mutable global).
  - TEST "queryOption: unset => empty; set => trimmed value". "querySessionName: returns trimmed; empty=>fallback".
  - TEST "sanitizeFilename: 'my session' => 'my_session'; 'a/b' => 'a_b'; '' => 'pane'".
  - TEST "buildOutputFilename: 's',1700000000,1234 => 's-1700000000-1234.html'".
  - Use std.testing.allocator throughout (verify no leaks: argv elems, history_token, Captured.ansi, paths).

Task 8: main.zig panePrepare unit test (dir-scoped, FakeTmux + std.testing.tmpDir; NO renderGrid)
  - Drive the paneCore/panePrepare path with a FakeTmux + a tmpDir realpath as out_dir; assert:
      visible+full(no history) => a path under out_dir matching `<session>-<digits>-<digits>.html`;
      cap.truncated set when history_size > effective (FakeTmux.history_size large, history small);
      exit code 2 when target resolution yields nothing (pass opts.target=null and inject empty TMUX_PANE
        via the core taking target explicitly — see note below).
  - NOTE on $TMUX_PANE in tests: std has no setenv. Make target resolution INJECTABLE: paneCore takes the
    resolved target (or a getenv thunk) rather than calling std.posix.getenv directly, OR have the prod
    paneBody resolve target and pass it into paneCore. (Mirror how syncPaletteDir takes cache_dir as a param
    instead of resolving $HOME internally.) This keeps the no-tty path unit-testable.
```

### Implementation Patterns & Key Details

```zig
// ===== blessed tmux argv (verified vs local tmux 3.6b man page — copy these EXACT token lists) =====
// visible : ["tmux","capture-pane","-e","-J","-p","-t","<PANE>"]                                 (7)
// full    : ["tmux","capture-pane","-e","-J","-p","-t","<PANE>","-S","-<N>","-E","-"]            (11)
// geometry: ["tmux","display-message","-p","-t","<PANE>","#{pane_width} #{pane_height} #{history_size}"] (3 fields)
// session : ["tmux","display-message","-p","-t","<PANE>","#{session_name}"]
// option  : ["tmux","show-option","-gqv","@tmux-2html-output-dir"]   (and ...-history-limit)
// notice  : ["tmux","display-message","-p","<message text>"]          (best-effort; ignore failure)
// -e re-emits SGR+OSC8; -J joins soft-wrapped lines; -p => stdout; -t => target. -S/-E take the NEXT
// token as their value even when it begins with '-'. env_map UNSET => child inherits $TMUX/$TMUX_PANE.

// ===== the pane output write — REUSE render.renderToFileAtomic (render.zig:214) =====
// It renders ansi with sel:null (whole grid) into `path` ATOMICALLY (temp+rename, same dir). Do NOT
// re-implement renderGrid or the writer bridge. pane just supplies: path, cap.ansi,
// render.Size{.cols=cap.cols,.rows=cap.rows}, colors (palette.resolve), opts.font.
// Then, if opts.open, render.spawnXdgOpen(path, alloc)  (best-effort; never fails the command).

// ===== palette resolution for pane (tty-less run-shell) =====
const colors = palette.resolve(alloc, .cached, palette.hasControllingTty());
// resolve is INFALLIBLE (returns Colors, NOT !Colors) — NO `try`. .cached + hasControllingTty()==false
// under run-shell => loadCache -> (live skipped) -> default. Exactly the contract: "has_tty=false so
// live is skipped in run-shell".

// ===== collision-safe filename (PRD §13) =====
const ts:  i64  = std.time.timestamp();                 // Unix seconds, wall clock (palette.zig uses this)
const pid: i32  = if (builtin.os.tag == .linux) std.os.linux.getpid() else 0;  // os/linux.zig:1841
const fname = try capture.buildOutputFilename(alloc, session_sanitized, ts, pid); // "sess-1700000000-1234.html"
// unixtime+pid alone guarantee uniqueness across concurrent run-shell invocations; session is a human hint.
```

### Integration Points

```yaml
TEST ROOT (src/main.zig):
  - add "_ = @import(\"capture.zig\");" to the existing top-level `test { }` block.
  - pattern: mirror the existing _ = @import("palette.zig"); / render.zig / golden_test.zig lines.
DISPATCH (src/main.zig:86):
  - change `return cli.pane(allocator, sub_args);` => `return cli.pane(allocator, sub_args, paneBody);`
CLI (src/cli.zig:384):
  - pane(alloc,args) => pane(alloc,args, body: *const fn(Allocator,PaneOpts)anyerror!u8); call body.
BUILD (build.zig) / PACKAGE (build.zig.zon): NO CHANGE (capture.zig under src/ is auto-compiled).
PLUGIN (tmux-2html.tmux, P2.M2 — NOT this task): runs `run-shell ".../tmux-2html pane --full --target #{pane_id}"`.
  pane resolves output-dir/history-limit itself via show-option, so the binding needs no extra args.
```

## Validation Loop

### Level 1: Syntax & Style (after each file)

```bash
# prod build MUST compile (capture.zig is on the prod path; pane wiring is live)
zig build -Doptimize=ReleaseFast
# Expected: zero errors. If errors, READ them — common: ArrayList .empty idiom, @alignCast, anyopaque coerce.
```

### Level 2: Unit Tests (component validation)

```bash
# capture.zig tests are separate fns (no ghostty-vt Terminal.init => no cross-test GOTCHA).
# Run the WHOLE suite (ReleaseFast is MANDATORY — Debug hits the bundled-SIMD linker bug).
zig build test --release=fast
# Expected: ALL pass, no leaks under std.testing.allocator.
#   - captureCmd visible(7)/full(11) argv + -<history> token
#   - geometry 3-field parse + BadGeometry on 2/4 fields
#   - effectiveHistory=min, wasTruncated strict-> and visible=>false
#   - capture via FakeTmux (two fakes don't cross-contaminate)
#   - queryOption unset=>empty, querySessionName, sanitizeFilename, buildOutputFilename
#   - panePrepare (dir-scoped, FakeTmux + tmpDir): correct path shape + truncated flag + exit-2 no-target
```

### Level 3: Integration Testing (inside a REAL tmux — manual / CI)

```bash
# Pre: a palette cache exists (so the tty-less path has colors). If not:
#   setsid tmux-2html sync-palette --force   # or capture interactively first

# 1) Full capture from a run-shell-like (tty-less) context:
TMUX_PANE=%5 tmux-2html pane --full        # %5 = a real pane id in your session
# Expected: exit 0; a file at $XDG_DATA_HOME/tmux-2html (or ~/.local/share/tmux-2html)/<session>-<ts>-<pid>.html
ls -t "${XDG_DATA_HOME:-$HOME/.local/share}/tmux-2html/" | head
#   => contains valid HTML: grep '<pre class="term2html-output"' <file>

# 2) Explicit output + open:
tmux-2html pane --visible --output /tmp/pane.html --open
test -f /tmp/pane.html && echo OK     # => OK

# 3) Concurrent runs do not clobber (fire 3 in parallel from run-shell):
for i in 1 2 3; do (tmux-2html pane --full &); done; wait
ls "${XDG_DATA_HOME:-$HOME/.local/share}/tmux-2html/" | wc -l   # => >=3 new distinct files

# 4) Error path: no target, no $TMUX_PANE => exit 2
env -u TMUX_PANE tmux-2html pane; echo "exit=$?"   # => exit=2
# 5) Bad pane id => exit 2
tmux-2html pane --target %999999; echo "exit=$?"   # => exit=2

# 6) Truncation notice: set a tiny history-limit override and a pane with scrollback, then:
tmux-2html pane --full --history 5
# Expected: file written + a stderr/display-message notice mentioning truncation.
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Confirm pane does NOT touch /dev/tty in the run-shell path (the whole point of the cached palette):
strace -f -e trace=openat tmux-2html pane --full 2>&1 | grep -c '/dev/tty'   # => 0 under setsid/run-shell
# Confirm the rendered HTML uses palette colors (inline #rrggbb spans), proving the cache was consumed:
grep -o 'color: #[0-9a-f]*' /tmp/pane.html | head
```

## Final Validation Checklist

### Technical Validation
- [ ] `zig build -Doptimize=ReleaseFast` compiles (capture.zig on the prod path).
- [ ] `zig build test --release=fast` passes — all new + existing tests, no leaks.
- [ ] main.zig test block imports capture.zig; dispatch threads paneBody; cli.pane calls the body.
- [ ] No new flags added to cli.PaneOpts/parsePane (parser untouched).

### Feature Validation
- [ ] `pane --full` (inside tmux) writes `<session>-<unixtime>-<pid>.html` under the output dir.
- [ ] `--output FILE` writes exactly FILE; `--open` opens it (best-effort).
- [ ] No target / bad pane → exit 2; write failure → exit 1; success → exit 0.
- [ ] Palette from cache (no `/dev/tty` under run-shell — Level 4 strace).
- [ ] Concurrent runs → distinct files; huge scrollback → truncation notice (PRD §13).
- [ ] Help text (`pane --help`) unchanged and accurate.

### Code Quality Validation
- [ ] capture.zig is ghostty-free + palette-free + parg-free (only std/builtin imports).
- [ ] pane orchestration in main.zig mirrors syncPaletteDir/Body (dir-scoped core + prod wrapper).
- [ ] capture.Runner reused for ALL tmux calls (geometry/capture/show-option/session/notice) — no ad-hoc Child.spawn.
- [ ] No raw magic numbers: MAX_OUTPUT=1<<28, defaults 50000, "pane" fallback, all named.
- [ ] No `try` on palette.resolve (it returns Colors, not !Colors).

### Documentation & Deployment
- [ ] pane_help (cli.zig) remains the CLI doc surface (PRD §5.2). No separate docs (per the item contract).
- [ ] Exit-code contract documented in help (0/1/2).

---

## Anti-Patterns to Avoid

- ❌ Don't re-implement renderGrid / the writer bridge / atomic write — REUSE `render.renderToFileAtomic`.
- ❌ Don't probe `/dev/tty` in pane — palette.resolve(.cached, hasControllingTty()) skips live under run-shell.
- ❌ Don't set `Child.run`'s `.env_map` (must inherit `$TMUX`/`$TMUX_PANE`) or omit `.max_output_bytes` (50 KiB default truncates).
- ❌ Don't detect truncation by counting captured rows — use `#{history_size} > effective` (S2 findings: equal counts are ambiguous).
- ❌ Don't glue `-S-50000` — pass `-S` and `-50000` as SEPARATE argv tokens.
- ❌ Don't add a pane unit test that calls renderGrid in its own `test` fn (ghostty-vt cross-test crash) — test capture/filename/options WITHOUT renderGrid; rely on render.zig + Level-3 for the render path.
- ❌ Don't call `std.posix.getenv` directly inside the dir-scoped test core (no setenv in std) — make target/output-dir INJECTABLE params (mirror syncPaletteDir taking `cache_dir`).
- ❌ Don't assume `src/capture.zig` exists — CREATE it (Tasks 1–3) before wiring pane (Task 4+).

---

## Confidence Score: 8/10

The capture subsystem is fully designed and live-verified in-repo (no guessing). The new pane logic
reuses three proven primitives (capture via FakeTmux-tested seam; `render.renderToFileAtomic`; `palette.resolve`)
plus a handful of pure, unit-tested helpers. The two residual risks that keep this from 9–10: (1) the
ghostty-vt single-Terminal-init-test GOTCHA constrains how pane's render path is tested (mitigated by
splitting prepare/render and a Level-3 integration test); (2) the option/output-dir resolution via
`show-option` is robust-by-fallback but only fully exercised end-to-end inside a real tmux (Level 3).
