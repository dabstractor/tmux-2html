# PRP — P1.M3.T1.S2: Sizing (--cols/--rows), --font, --output, --open

## Goal

**Feature Goal**: Refine `render.run` (built by S1) so the `render` subcommand produces
correctly-sized output for every invocation context: `--cols` is enforced when there is no
controlling terminal, otherwise the real terminal size is read via `ioctl(TIOCGWINSZ)`;
`--rows` defaults to the input's line count; HTML is written to `--output` atomically (or
stdout); and `--open` materializes a temp file then spawns `xdg-open`. `--font` is validated
end-to-end (it was already threaded by S1).

**Deliverable**: `src/render.zig` MODIFIED — S1's `render.run` extended with: a verified
`getSize()`, a pure `determineCols`/`lineCount`, an atomic `renderToFileAtomic`, a
`tempHtmlPath`, and a `spawnXdgOpen` that reaps its child. Plus unit tests for the pure
helpers and an atomic-write round-trip. **No other source file changes** (cli.zig already
parses all five flags in P1.M1.T3.S2; main.zig was already updated by S1).

**Success Definition**:
- `printf 'x' | setsid bash -c 'render render'` ⇒ exit 2, stderr names `--cols` (no tty).
- `printf 'hello\nworld\n' | tmux-2html render --cols 80` ⇒ stdout HTML holds BOTH lines
  (rows defaulted to the 2-line input; nothing scrolled off).
- `printf '…' | tmux-2html render --cols 80 --output out.html` ⇒ writes `out.html`
  atomically (no leftover `.tmp`), stdout empty, `out.html` contains valid `<pre …>` HTML.
- `printf '…' | tmux-2html render --cols 80 --font 'Fira Code' --output o.html` ⇒ `o.html`
  contains `font-family: Fira Code`.
- `printf '…' | tmux-2html render --cols 80 --open` ⇒ exit 0, a temp file exists in
  `$TMPDIR`/`/tmp`, xdg-open is spawned-and-reaped (no zombie; headless failure ignored).
- `zig build` compiles on x86_64-linux AND cross-compiles to x86_64-macos (no libc).
- `zig build test` green (new helper tests + all S1/palette/cli/main tests).

## Why

- S1's `run` uses a throwaway size (`cols orelse 80, rows orelse 24`) and writes only to
  stdout, explicitly deferring sizing/output/open to S2. S2 delivers the real `render` UX:
  right-sized output (PRD §2.3 "size must be explicit"), file output, and one-click open.
- Every downstream subcommand (`pane`, `region`) reuses `renderGrid` + these same output/open
  helpers, so S2's atomic-write + xdg-open logic is shared infrastructure for P2/P3.

## What

### User-visible behavior
- `render` reads ANSI from stdin and writes HTML to **stdout** (default), an **`--output`
  file** (atomic temp+rename), or a **temp file** when `--open` is given without `--output`.
- `--cols N` is **required** when the process has no controlling terminal (tmux run-shell,
  CI, cron). With a tty and no `--cols`, the terminal's width is used automatically.
- `--rows N` defaults to the number of lines in the input.
- `--open` launches the user's default app via `xdg-open` (failure is ignored gracefully).
- Exit codes: **0** success, **1** runtime/write error, **2** size error (no tty + no
  `--cols`, or terminal size undeterminable).

### Success Criteria
- [ ] `determineCols(null, false)` → `error.SizeRequired`; `determineCols(80, _)` → 80 (unit).
- [ ] `lineCount` returns 1/2/2/1 for `""`/`"a\nb\n"`/`"a\nb"`/`"hello"` (unit).
- [ ] `renderToFileAtomic` writes the target, leaves no `.tmp`, content is valid HTML (unit,
      std.testing.tmpDir + std.testing.allocator, no leak).
- [ ] `render` with no tty + no `--cols` → exit 2 (setsid integration test).
- [ ] `render --cols 80 --output out.html` writes the file atomically; stdout empty.
- [ ] `render --cols 80 --font 'Fira Code' --output o.html` → `o.html` has `font-family: Fira Code`.
- [ ] `render --cols 80 --open` → exit 0; temp HTML file created in `$TMPDIR`/`/tmp`.
- [ ] `printf 'hello\nworld\n' | render --cols 80` → both words present (rows defaulted).
- [ ] `zig build` compiles (Linux); cross-compiles to x86_64-macos (no libc); `zig build test` green.

## All Needed Context

### Context Completeness Check

_Passed._ A developer who has never seen this repo can implement S2 from: this PRP's
**compile-validated** code blocks (every signature was `zig test`/`zig build-obj`-verified
against the installed Zig 0.15.2 stdlib on Linux + macOS), S1's `render.zig` contract
(`renderGrid` + the minimal `run` this task refines), and the explicit scope boundary vs
S3/S4. The single most surprising fact (spawn xdg-open **with** `wait()` or you get zombies —
ghostty's own bug #5999) is called out in the gotchas.

### Documentation & References

```yaml
# MUST READ — the verified S2 API surface (all compile-validated; see research/findings.md)
- docfile: plan/001_0c8587f91cb2/P1M3T1S2/research/findings.md
  why: "THIS task's research. Every Zig 0.15.2 signature pinned to stdlib line numbers + a
        passing probe (s2_probe.zig) + the ghostty #5999 zombie finding."
  section: "§1 getSize (ioctl via std.os.linux), §2 cols decision + exit 2, §3 lineCount,
            §4 atomic write + dirname-'.' trick, §5 temp path + spawn-with-wait,
            §6 exit plumbing, §7 run() delta vs S1, §8 gotchas"

- docfile: plan/001_0c8587f91cb2/P1M3T1S1/PRP.md
  why: "S1 is being implemented IN PARALLEL. Its `render.zig` (renderGrid + minimal run) is
        S2's BASELINE. S2 REFINES run; it does NOT touch renderGrid."
  section: "Implementation Tasks Task 1 (renderGrid — UNCHANGED by S2), Task 2 (the minimal
            run S2 refines), Known Gotchas (the *std.Io.Writer bridge — reused for file output)"

- docfile: plan/001_0c8587f91cb2/architecture/render_pipeline.md
  why: "PRD §5.1 contract source. §3 = the verified getSize() shape (ioctl TIOCGWINSZ);
        §1 = the renderGrid pipeline S2 calls unchanged."
  section: "§3 (getSize), §1 (pipeline)"

# Existing source files to FOLLOW / CONSUME (DO NOT EDIT)
- file: src/render.zig   # (created by S1; S2 MODIFIES only run() + adds helpers)
  why: "S2's baseline. renderGrid(alloc, ansi, size, colors, sel, font, out: *std.Io.Writer)
        is UNCHANGED. S2 refines run() (S1 left `cols orelse 80, rows orelse 24`, stdout-only)
        and ADDS getSize/determineCols/lineCount/renderToFileAtomic/tempHtmlPath/spawnXdgOpen."
  pattern: "S1's run(): stdin.readToEndAlloc -> defaultColors() -> Size{...} -> fw.interface
            writer bridge -> renderGrid -> return 0. S2 keeps stdin/colors/sel=null and
            rewrites the size line + output block."
  gotcha: "renderGrid's `out` is *std.Io.Writer — the SAME bridge (`f.writer(&buf).interface`)
           works for stdout AND opened files AND Writer.Allocating. Reuse it for file output."

- file: src/palette.zig
  why: "CONSUME: palette.hasControllingTty() (probes /dev/tty, returns bool) for the cols
        decision; palette.defaultColors() for colors (S3 will swap to palette.resolve);
        palette.writeCacheDir's atomic-write idiom to mirror in renderToFileAtomic."
  pattern: "writeCacheDir: createFile(tmp, .{}) in SAME dir as target -> writeAll -> sync()
            catch {} -> close -> rename(tmp, base); errdefer cleans tmp. Mirror exactly."
  gotcha: "S2 must NOT call palette.resolve (that's S3). S2 stays on defaultColors()."

- file: src/cli.zig
  why: "CONSUME: cli.RenderOpts {cols: ?u16, rows: ?u16, font: []const u8='monospace',
        output: ?[]const u8, open: bool, …}. ALL FIVE flags are ALREADY parsed by parseRender
        (P1.M1.T3.S2). S2 does NOT edit cli.zig."
  pattern: "render() after parseRender: `return render_mod.run(allocator, opts);` (S1 wired it)."

- file: src/main.zig
  why: "Exit-code plumbing. dispatch does `dispatch(...) catch |err| switch(err){ NotImplemented=>1,
        else => return e }`. So a u8 from render.run flows straight to process exit. S2 changes
        NOTHING here (S1 already updated the test block + dropped the render NotImplemented assertion)."
  pattern: "no edits needed. S2's `return 2`/`return 1` from run() reach exit unchanged."

# External (the one non-stdlib design decision — xdg-open)
- url: https://github.com/ghostty-org/ghostty/discussions/5999
  why: "ghostty's OWN bug: spawning xdg-open WITHOUT wait() => zombie processes. PROVES S2
        must spawn + wait (ignore Term). This is the dependency we build on hitting the trap."
  critical: "Always child.spawn() then child.wait(); never spawn-and-forget for xdg-open."
- url: https://docs.oracle.com/cd/E88353_01/html/E37839/xdg-open-1.html
  why: "xdg-open opens a file/URL in the user's preferred app; returns ~immediately (so waiting
        does not stall). PRD §5.1 fixes 'xdg-open' (no macOS `open` fallback in v1)."
```

### Current Codebase tree (post-S1, S2's baseline)

```bash
src/
├── main.zig            # dispatch + --version/--help; test root imports palette.zig + render.zig (S1)
├── cli.zig             # RenderOpts/parseRender DONE (all 5 flags); render()->render.run (S1)
├── palette.zig         # hasControllingTty(), defaultColors(), writeCacheDir (atomic pattern) — CONSUME
├── render.zig          # S1: pub Size, pub renderGrid(...), pub run() [minimal]. S2 REFINES run().
└── ghostty_format.zig  # VENDORED — DO NOT EDIT
build.zig / build.zig.zon   # .link_libc=false; ghostty(LAZY)+parg; min_zig 0.15.2; matrix incl. macos
```

### Desired Codebase tree (this task)

```bash
src/
├── render.zig          # MODIFIED: run() refined (sizing+output+open); +getSize/determineCols/
                        #           lineCount/renderToFileAtomic/tempHtmlPath/spawnXdgOpen + tests
└── (all other files unchanged)
```

### Known Gotchas of our codebase & Library Quirks

```zig
// CRITICAL — the build is .link_libc=FALSE (build.zig:25). So std.posix.system is std.os.linux
// on Linux but a feature-less stub on macOS (no T, no ioctl). Use std.os.linux DIRECTLY for the
// ioctl (it compiles on every target — verified; dead code off-Linux), guarded by builtin.os.tag.

// CRITICAL — std.posix.winsize field order is { row, col, xpixel, ypixel }. col is field #1.

// CRITICAL — spawn xdg-open WITH wait() (ghostty #5999: spawn-without-wait => zombies). xdg-open
// returns ~immediately, so waiting never stalls; ignoring its Term satisfies "--open ignore failure".

// CRITICAL — std.fs.path.dirname("out.html") == null (bare filename). std.fs.cwd() returns a Dir
// you must NOT close. Trick: `dirname(path) orelse "."` + cwd().openDir(".") => a real closeable dir.

// CRITICAL — atomic rename needs the temp file in the SAME dir as the target (same filesystem;
// cross-dir rename => EXDEV non-atomic). Name it `.{base}.{rand}.tmp` next to `{base}`.

// The *std.Io.Writer bridge (S1-validated) is identical for stdout, opened files, and
// Writer.Allocating: `var fw = file.writer(&buf); renderGrid(…, &fw.interface); fw.interface.flush();`

// "--cols required if no tty" means no CONTROLLING tty (palette.hasControllingTty() probes /dev/tty),
// NOT "stdin is not a tty". Piped stdin in a dev terminal STILL has a controlling tty => getSize().
// Deterministic no-tty test: run under `setsid` (detaches controlling tty).

// cols errors => return 2 (NOT a Zig error — run() returns u8; print stderr msg, return 2).
// write errors => return 1 (print stderr msg, return 1; don't bubble a raw error trace).
```

## Implementation Blueprint

### Data models and structure

```zig
// src/render.zig — ADDED types/helpers (renderGrid + Size from S1 are unchanged above these).
const std = @import("std");
const builtin = @import("builtin");
const palette = @import("palette.zig");
const cli = @import("cli.zig");
// (ghostty_vt, fmt imports + Size + renderGrid stay exactly as S1 wrote them.)

/// Terminal geometry from ioctl(TIOCGWINSZ).
pub const WindowSize = struct { cols: u16, rows: u16 };

/// Errors determining the column count. Mapped to exit 2 in run().
pub const SizeError = error{
    SizeRequired, // no --cols and no controlling tty
    NoTty, // /dev/tty could not be opened
    IoctlFailed, // ioctl returned an errno
    InvalidWindowSize, // winsize reported 0 cols/rows
    UnsupportedPlatform, // non-Linux (no libc => no portable ioctl layer)
};
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: MODIFY src/render.zig — ADD getSize() (VERIFIED, compile-validated Linux+macOS)
  - IMPLEMENT: pub fn getSize() !WindowSize  (research/findings.md §1 — copy the block verbatim)
  - DETAILS: `if (builtin.os.tag != .linux) return error.UnsupportedPlatform;` guard; open
      /dev/tty read_only; `var ws: std.posix.winsize = undefined;` (NOTE field order row,col);
      `const linux = std.os.linux; const fd: usize = @bitCast(@as(isize, tty.handle));`
      `const rc = linux.syscall3(.ioctl, fd, linux.T.IOCGWINSZ, @intFromPtr(&ws));`
      `switch (linux.E.init(rc)) { .SUCCESS => {}, else => return error.IoctlFailed, }`
      reject ws.col==0 or ws.row==0; return .{ .cols = ws.col, .rows = ws.row }.
  - FOLLOW: stdlib's own isatty (posix.zig:3575). NAMING: getSize. PLACEMENT: render.zig (private).
  - GOTCHA: use std.os.linux, NOT std.posix.system (libc=false => macOS stub). Verified compiles.

Task 2: ADD determineCols + lineCount (PURE — unit-tested)
  - IMPLEMENT: pub fn determineCols(opts_cols: ?u16, has_tty: bool) SizeError!u16
      `if (opts_cols) |c| return c; if (has_tty) return (try getSize()).cols; return error.SizeRequired;`
  - IMPLEMENT: fn lineCount(ansi: []const u8) u16  (research/findings.md §3 — copy verbatim;
      empty=>1; count "\n"; +1 if trailing line w/o newline; floor 1; @min(maxInt(u16))).
  - FOLLOW: research/findings.md §2/§3 (verified probe values). NAMING: determineCols, lineCount.

Task 3: ADD renderToFileAtomic (ATOMIC; mirrors palette.writeCacheDir)
  - IMPLEMENT: fn renderToFileAtomic(alloc: std.mem.Allocator, path: []const u8,
        ansi: []const u8, size: Size, colors: palette.Colors, font: ?[]const u8) !void
      1. `const dir_path = std.fs.path.dirname(path) orelse ".";`  (null-bare-filename trick)
         `const base = std.fs.path.basename(path);`
      2. `var rnd: [4]u8 = undefined; std.crypto.random.bytes(&rnd);`
         `const tmp_name = try std.fmt.allocPrint(alloc, ".{s}.{x}.tmp", .{ base, @as(u32, @bitCast(rnd)) });`
         `defer alloc.free(tmp_name);`
      3. `var dir = if (std.fs.path.isAbsolute(dir_path)) try std.fs.openDirAbsolute(dir_path, .{}) else try std.fs.cwd().openDir(dir_path, .{});`
         `defer dir.close();`  (openDir(".") returns a real closeable cwd dir)
      4. `var f = try dir.createFile(tmp_name, .{});`
         `errdefer { f.close(); dir.deleteFile(tmp_name) catch {}; }`
      5. `var buf: [8192]u8 = undefined; var fw = f.writer(&buf);`  (the S1-validated writer bridge)
         `try renderGrid(alloc, ansi, size, colors, null, font, &fw.interface);`  (sel: null — S4)
         `try fw.interface.flush(); f.sync() catch {}; f.close();`
      6. `try dir.rename(tmp_name, base);`  (same dir => atomic)
  - FOLLOW: palette.writeCacheDir (proven idiom) + research/findings.md §4. NAMING: renderToFileAtomic.

Task 4: ADD tempHtmlPath + spawnXdgOpen (--open helpers)
  - IMPLEMENT: fn tempHtmlPath(alloc) ![]u8  (research/findings.md §5 — TMPDIR/`/tmp` + 8 random
      bytes @bitCast u64 => `{s}/tmux-2html-{x}.html`). VERIFIED ends with .html.
  - IMPLEMENT: fn spawnXdgOpen(path: []const u8, alloc: std.mem.Allocator) void
      `var child = std.process.Child.init(&.{ "xdg-open", path }, alloc);`
      `child.stdin_behavior = .Ignore; child.stdout_behavior = .Ignore; child.stderr_behavior = .Ignore;`
      `child.spawn() catch return;`  (xdg-open missing => ignore)
      `_ = child.wait() catch return;`  (REAP — ghostty #5999 zombie fix; ignore Term)
  - FOLLOW: research/findings.md §5 (verified Child API). NAMING: tempHtmlPath, spawnXdgOpen.

Task 5: MODIFY src/render.zig — REFINE run() (the core change vs S1's minimal run)
  - REPLACE S1's run() body. Keep: stdin read (readToEndAlloc, MAX_STDIN, defer free);
    `const colors = palette.defaultColors();` (S3 will swap to resolve); `sel: null` everywhere.
  - NEW sizing: `const cols = determineCols(opts.cols, palette.hasControllingTty()) catch |err| { reportSizeError(err); return 2; };`
      `const rows = opts.rows orelse lineCount(ansi); const size = Size{ .cols = cols, .rows = rows };`
  - NEW output (3-arm):
        const stderr = std.fs.File.stderr();
        if (opts.output) |path| {
            renderToFileAtomic(alloc, path, ansi, size, colors, opts.font) catch {
                stderr.writeAll("tmux-2html render: cannot write output file\n") catch {};
                return 1;
            };
            if (opts.open) spawnXdgOpen(path, alloc);
        } else if (opts.open) {
            const tmp = tempHtmlPath(alloc) catch {
                stderr.writeAll("tmux-2html render: cannot allocate temp path\n") catch {};
                return 1;
            };
            defer alloc.free(tmp);
            renderToFileAtomic(alloc, tmp, ansi, size, colors, opts.font) catch {
                stderr.writeAll("tmux-2html render: cannot write temp file\n") catch {};
                return 1;
            };
            spawnXdgOpen(tmp, alloc);
        } else {
            // stdout — S1's path, verbatim (no regression).
            var out_file = std.fs.File.stdout();
            var sbuf: [4096]u8 = undefined;
            var fw = out_file.writer(&sbuf);
            defer fw.interface.flush() catch {};
            renderGrid(alloc, ansi, size, colors, null, opts.font, &fw.interface) catch {
                stderr.writeAll("tmux-2html render: write failed\n") catch {};
                return 1;
            };
        }
        return 0;
  - ADD: fn reportSizeError(err: SizeError) void — switch to print a one-liner to stderr:
        SizeRequired => "tmux-2html render: --cols is required when input is not a tty\n",
        NoTty|IoctlFailed|InvalidWindowSize => "tmux-2html render: cannot determine terminal size\n",
        UnsupportedPlatform => "tmux-2html render: terminal size detection unsupported on this platform\n"
  - GOTCHA: `determineCols(null, true)` calls real getSize (opens /dev/tty) — fine at runtime;
      never assert its value in a unit test. GOTCHA: opts.font is []const u8 (non-null default
      "monospace"); pass straight through (the `?[]const u8` param accepts it).
  - PRESERVE: S1's MAX_STDIN const, the renderGrid primitive, Size struct, all S1 unit tests.

Task 6: ADD unit tests in src/render.zig (PURE helpers + atomic round-trip; NO stdin, NO tty, NO xdg)
  - TEST determineCols: (80,false)=>80; (120,true)=>120 (explicit; getSize NOT called);
      (null,false)=>error.SizeRequired.  (Do NOT call determineCols(null,true) — hits real /dev/tty.)
  - TEST lineCount: ""=>1, "a\nb\n"=>2, "a\nb"=>2, "hello"=>1, many-lines clamps to maxInt(u16).
  - TEST tempHtmlPath: ends with ".html", contains "/tmux-2html-". (free with defer.)
  - TEST renderToFileAtomic (std.testing.tmpDir + std.testing.allocator):
      resolve abs path via tmp.dir.realpathAlloc(alloc, ".") + join "out.html"; call
      renderToFileAtomic(alloc, abs, "\x1b[31mred\x1b[0m", .{.cols=40,.rows=5}, defaultColors(),
      "Fira Code"); read abs back; assert contains "<pre" and ">red</span>" and "font-family: Fira Code";
      then iterate tmp.dir: assert EXACTLY ONE entry remains ("out.html" — proves temp was renamed,
      not left behind). No leak under std.testing.allocator.
  - TEST spawnXdgOpen does not crash on a bogus path (best-effort: `spawnXdgOpen("/nonexistent",
      std.testing.allocator);` — xdg-open missing => spawn fails => swallowed; the call just returns).
  - NAMING: test "determineCols: explicit cols wins", test "lineCount: counts input lines", etc.
  - NOTE: renderGrid's own tests (red/bold/plain/empty/truecolor) are S1's — leave them; S2 only
      ADDS the helper + atomic tests. `--font` is asserted via the atomic round-trip test above.
```

### Implementation Patterns & Key Details

```zig
// The full refined run() (replaces S1's minimal run). renderGrid + Size are S1's, unchanged.
pub fn run(alloc: std.mem.Allocator, opts: cli.RenderOpts) !u8 {
    const stdin = std.fs.File.stdin();
    const ansi = try stdin.readToEndAlloc(alloc, MAX_STDIN); // S1's const
    defer alloc.free(ansi);

    const colors = palette.defaultColors(); // S3: palette.resolve(alloc, mode, palette.hasControllingTty())

    const cols = determineCols(opts.cols, palette.hasControllingTty()) catch |err| {
        reportSizeError(err);
        return 2; // size error
    };
    const rows = opts.rows orelse lineCount(ansi);
    const size = Size{ .cols = cols, .rows = rows };

    const stderr = std.fs.File.stderr();
    if (opts.output) |path| {
        renderToFileAtomic(alloc, path, ansi, size, colors, opts.font) catch {
            stderr.writeAll("tmux-2html render: cannot write output file\n") catch {};
            return 1;
        };
        if (opts.open) spawnXdgOpen(path, alloc);
    } else if (opts.open) {
        const tmp = tempHtmlPath(alloc) catch {
            stderr.writeAll("tmux-2html render: cannot allocate temp path\n") catch {};
            return 1;
        };
        defer alloc.free(tmp);
        renderToFileAtomic(alloc, tmp, ansi, size, colors, opts.font) catch {
            stderr.writeAll("tmux-2html render: cannot write temp file\n") catch {};
            return 1;
        };
        spawnXdgOpen(tmp, alloc);
    } else {
        var out_file = std.fs.File.stdout();
        var sbuf: [4096]u8 = undefined;
        var fw = out_file.writer(&sbuf);
        defer fw.interface.flush() catch {};
        renderGrid(alloc, ansi, size, colors, null, opts.font, &fw.interface) catch {
            stderr.writeAll("tmux-2html render: write failed\n") catch {};
            return 1;
        };
    }
    return 0;
}
```

### Integration Points

```yaml
BUILD: none. build.zig is unchanged. S2 uses only stdlib (std.os.linux, std.process.Child,
       std.crypto.random, std.fs) already pulled in. Confirms .link_libc=false compatibility:
       std.os.linux compiles on the macos cross target (verified dead-code).

CLI (src/cli.zig): NOT EDITED. parseRender already yields RenderOpts{cols,rows,font,output,open}.
       render() already calls render_mod.run(allocator, opts) (S1 wired it).

MAIN (src/main.zig): NOT EDITED. The u8 returned by run() flows to process exit unchanged.

PALETTE (src/palette.zig): consumed (hasControllingTty, defaultColors). S3 later swaps to resolve.

SCOPE: S2 keeps defaultColors() + sel: null. Does NOT implement --palette (S3) or --selection (S4).
```

## Validation Loop

### Level 1: Syntax & Style (compile gate)

```bash
zig build                       # compiles the exe on Linux (ghostty-vt still linked via S1)
# Expected: success. (Zig has no separate lint; `zig build` IS the type+compile gate.)

# Cross-compile sanity (P4's matrix; prove no libc / no macOS-only API leaked in):
zig build-obj src/render.zig -fno-emit-bin -target x86_64-macos 2>&1 | head
# Expected: no errors. (getSize's std.os.linux refs compile as dead code off-Linux — verified.)
```

### Level 2: Unit Tests (PURE helpers + atomic round-trip; no tty/stdin/xdg)

```bash
zig build test
# Expected: all green — new determineCols/lineCount/tempHtmlPath/renderToFileAtomic/spawnXdgOpen
# tests + S1's renderGrid tests + all palette/cli/main tests. No leak under std.testing.allocator.
```

### Level 3: Integration (the real CLI)

```bash
BIN="zig build run --"

# (1) stdout path UNCHANGED (S1 regression): red span to stdout
printf '\033[31mred\033[0m' | $BIN render --cols 40 | grep -o '>red</span>'

# (2) --rows default = input line count: both lines survive (would scroll off under rows=1)
printf 'hello\nworld\n' | $BIN render --cols 80 | grep -c 'hello'   # => 1
printf 'hello\nworld\n' | $BIN render --cols 80 | grep -c 'world'   # => 1

# (3) --output writes the file atomically; stdout empty
printf '\033[31mred\033[0m' | $BIN render --cols 40 --output /tmp/t2h-out.html
test -s /tmp/t2h-out.html && echo "file written"
grep -o '>red</span>' /tmp/t2h-out.html
ls /tmp/.t2h-out.html.*.tmp 2>/dev/null && echo "TEMP LEAK (bad)" || echo "no temp leak (good)"

# (4) --font flows to the file's font-family
printf 'x' | $BIN render --cols 40 --font 'Fira Code' --output /tmp/t2h-font.html
grep -o 'font-family: Fira Code' /tmp/t2h-font.html

# (5) no controlling tty + no --cols => exit 2 (setsid detaches the controlling tty)
setsid bash -c "printf 'x' | $BIN render" >/dev/null 2>&1; echo "exit=$?"   # => 2
#   (stderr should name --cols: `setsid bash -c "printf x | $BIN render" 2>&1 | grep -o -- '--cols'`)

# (6) --open with no --output => temp file in $TMPDIR//tmp + exit 0 (xdg-open absent in CI => ignored)
printf 'x' | $BIN render --cols 40 --open; echo "exit=$?"                  # => 0
ls -t "${TMPDIR:-/tmp}"/tmux-2html-*.html 2>/dev/null | head -1            # a fresh temp exists

# (7) --output + --open => file written AND xdg-open spawned on it (exit 0)
printf 'x' | $BIN render --cols 40 --output /tmp/t2h-both.html --open; echo "exit=$?"   # => 0
test -s /tmp/t2h-both.html && echo "file written"
```

### Level 4: Regression (don't break P1.M1/P1.M2/S1)

```bash
zig build test                                                  # palette + cli + main + renderGrid tests still pass
zig build run -- --version | grep -q 'tmux-2html'               # version surface intact
zig build run -- render --help | grep -q -- '--cols N'          # help surface (all 5 flags) intact
zig build run -- sync-palette --help                            # sibling subcommand help intact
# Expected: all pass. (render --help text already lists --cols/--rows/--font/--output/--open.)
```

## Final Validation Checklist

### Technical Validation
- [ ] `zig build` succeeds (Linux).
- [ ] `zig build-obj src/render.zig -fno-emit-bin -target x86_64-macos` succeeds (no libc leak).
- [ ] `zig build test` green (new helper + atomic tests; no allocator leak).

### Feature Validation
- [ ] `render` no-tty + no `--cols` → exit 2; stderr names `--cols` (setsid test).
- [ ] `render --output FILE` writes the file atomically (no `.tmp` left); stdout empty.
- [ ] `render --font F --output o.html` → `font-family: F` in `o.html`.
- [ ] `render --open` (no output) → temp file created, exit 0 (xdg-open failure ignored).
- [ ] `render --cols 80` (piped, default rows) holds every input line.

### Scope Discipline (RESPECT sibling tasks)
- [ ] Did NOT implement `--palette` resolve (S3) — used `defaultColors()` only.
- [ ] Did NOT implement `--selection` coordinate→Pin (S4) — `sel: null` only.
- [ ] Did NOT modify `renderGrid`, `cli.zig`, `main.zig`, `palette.zig`, `ghostty_format.zig`,
      `build.zig`, or `build.zig.zon`.
- [ ] Did NOT regress S1's stdout path (identical bytes for the no-output/no-open case).

### Code Quality
- [ ] Follows conventions: `std.fs.File.stdout()/stderr()` (main.zig), `@import` style,
      DEBUG-style comments citing stdlib line numbers + the ghostty #5999 finding.
- [ ] `cli.parseRender` stays pure/ghostty-free (untouched); `renderGrid` signature untouched.
- [ ] xdg-open is spawned WITH `wait()` (no zombie — ghostty #5999).

---

## Anti-Patterns to Avoid

- ❌ Don't reference `std.posix.system.T.IOCGWINSZ`/`.ioctl` — that's the libc/stub namespace
  (compiles Linux-only under `link_libc=false`). Use `std.os.linux` (compiles everywhere).
- ❌ Don't forget `winsize` is `{ row, col, … }` (col is field 1) — reading `ws.row` as cols is a silent bug.
- ❌ Don't spawn xdg-open without `wait()` — ghostty #5999 zombie bug. Always `spawn()` then `wait()`.
- ❌ Don't `close()` a `std.fs.cwd()` Dir — use `dirname(path) orelse "."` + `openDir(".")`.
- ❌ Don't write the temp file outside the target's dir (cross-fs rename → EXDEV, non-atomic).
- ❌ Don't unit-test the `has_tty=true` branch of `determineCols` (it opens real /dev/tty).
- ❌ Don't let size errors bubble as Zig errors (stack trace) — `run` returns `2` (a u8) after a stderr msg.
- ❌ Don't reimplement `renderGrid` or change its signature — S2 calls it unchanged.
- ❌ Don't expand into S3 (`--palette`/resolve) or S4 (`--selection`/Pin) — `defaultColors()` + `sel: null`.
- ❌ Don't assume "no tty" means "stdin is a pipe" — it's `palette.hasControllingTty()` (`/dev/tty`).

---

## Confidence Score: 9/10

Every API (getSize ioctl, `std.process.Child` spawn/wait, the `*std.Io.Writer` file bridge,
`std.crypto.random`, `std.posix.getenv`, atomic createFile/sync/rename) was **read from the
installed Zig 0.15.2 stdlib** and **compile-validated** by a passing probe (`zig test` on
Linux + `zig build-obj -target x86_64-macos`), and the one runtime design risk (xdg-open
zombies) is pinned to ghostty-org/ghostty#5999 with the proven fix (spawn + wait). The
remaining 1/10 is ordinary friction (exact `std.process.Child` field inference, the atomic
round-trip test's directory-iteration API), not architectural uncertainty.
