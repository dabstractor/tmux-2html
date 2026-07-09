# Research findings — P1.M3.T1.S2: Sizing (--cols/--rows), --font, --output, --open

> **Authority:** Every Zig API signature below was read directly from the **Zig 0.15.2
> stdlib** at `~/.local/opt/zig-x86_64-linux-0.15.2/lib/std/` and **compile-validated** with
> `zig test` (Linux) + `zig build-obj -target x86_64-macos` (macOS cross) in a throwaway
> probe (`s2_probe.zig`, all tests passed). The xdg-open behavior note is sourced from
> ghostty-org/ghostty#5999 (the exact bug our ghostty-vt dependency hit).

## 0. What S2 owns (scope boundary — RESPECT siblings)

S2 **refines `render.run`** (created by S1, currently minimal) to add:
- **Smart sizing:** `--cols` REQUIRED when no controlling tty; otherwise fall back to
  `getSize()` (ioctl `TIOCGWINSZ`). `--rows` defaults to the input's line count.
- **`--output FILE`:** write HTML there ATOMICALLY (temp + rename, same dir).
- **`--open`:** if no `--output`, materialize a temp file (`--open` implies `--output`),
  write there, then spawn `xdg-open <file>` (ignore failure).
- **`--font`:** ALREADY threaded end-to-end by S1 (`run` passes `opts.font` → `renderGrid`
  → `ScreenFormatter.Options.font`). S2 only ADDS integration validation (font appears in
  the emitted `font-family:`) and ensures it flows to every output target (stdout/file/temp).

S2 does NOT touch:
- **S1:** `renderGrid` signature/body (unchanged — S2 calls it as-is with `sel: null`).
- **S3:** `--palette MODE` → `palette.resolve` (S2 keeps `palette.defaultColors()`).
- **S4:** `--selection` coordinate→Pin (S2 always passes `sel: null`).
- **cli.zig:** all five flags are ALREADY parsed in P1.M1.T3.S2 (`RenderOpts` +
  `parseRender`). S2 is **render.zig-only** (+ no main.zig change beyond what S1 already did).

## 1. getSize() — ioctl TIOCGWINSZ (VERIFIED + cross-platform compiles)

The build is `.link_libc = false` (build.zig:25). Consequence:
`std.posix.system` = `std.os.linux` on Linux, but a **feature-less stub** on macOS
(posix.zig:44 → the stub has no `T`, no `ioctl`, `fd_t = void`). So `std.posix.system.T…`
only compiles on Linux. **Use `std.os.linux` directly** (it compiles on every target —
verified by `zig build-obj -target x86_64-macos`; it's just dead code off-Linux).

Verified shapes (read from the stdlib):
- `std.posix.winsize = extern struct { row: u16, col: u16, xpixel: u16, ypixel: u16 }`
  (posix.zig:226). **NOTE: `row` is field 0, `col` is field 1.**
- `std.os.linux.T.IOCGWINSZ` (os/linux.zig:4823 etc., per-arch) — the ioctl request number.
- `std.os.linux.syscall3(.ioctl, fd: usize, request, arg: usize) usize` (os/linux.zig).
- `std.os.linux.E.init(rc) → E` — decode the raw syscall return into an errno enum.
- The stdlib's OWN `isatty` (posix.zig:3575) does exactly: `var wsz: winsize = undefined;
  const rc = linux.syscall3(.ioctl, fd, linux.T.IOCGWINSZ, @intFromPtr(&wsz)); switch
  (linux.E.init(rc)) {.SUCCESS=>…}`. Mirror it.

VERIFIED implementation (compiles Linux + macOS; passes `zig test`):
```zig
const builtin = @import("builtin");
pub const WindowSize = struct { cols: u16, rows: u16 };

pub fn getSize() !WindowSize {
    // No libc => no portable ioctl layer off-Linux. Guard so macOS degrades to an error
    // (caller surfaces "size error" => exit 2) rather than making a bogus Linux syscall.
    if (builtin.os.tag != .linux) return error.UnsupportedPlatform;
    var tty = std.fs.openFileAbsolute("/dev/tty", .{ .mode = .read_only }) catch return error.NoTty;
    defer tty.close();
    var ws: std.posix.winsize = undefined;
    const linux = std.os.linux;
    const fd: usize = @bitCast(@as(isize, tty.handle));   // File.handle is c_int → isize → usize
    const rc = linux.syscall3(.ioctl, fd, linux.T.IOCGWINSZ, @intFromPtr(&ws));
    switch (linux.E.init(rc)) {
        .SUCCESS => {},
        else => return error.IoctlFailed,
    }
    if (ws.col == 0 or ws.row == 0) return error.InvalidWindowSize;
    return .{ .cols = ws.col, .rows = ws.row };
}
```
`/dev/tty` open mode `.read_only` is enough for `ioctl(TIOCGWINSZ)` (palette.zig's
`hasControllingTty` uses `.{}` = read-only; `queryColors` uses `.read_write` because it
WRITES query bytes). For getSize we only read the size → `.read_only`.

## 2. The cols DECISION (exit 2 on size error) + the "tty" subtlety

The item contract: "--cols is REQUIRED if no tty"; "Exit 2 on size/capture errors".
**"no tty" = no CONTROLLING terminal** (`palette.hasControllingTty()`, which probes
`/dev/tty`), NOT "stdin is not a tty". So in a dev terminal with piped stdin
(`printf … | render`), the controlling tty STILL exists → getSize() is used (the user's
terminal width). Only tmux run-shell / CI / cron / headless (no `/dev/tty`) require `--cols`.

Pure decision fn (unit-testable; the `has_tty=true` branch calls real getSize — only the
non-getSize paths are unit-asserted, mirroring how palette.zig tests leave queryColors alone):
```zig
pub const SizeError = error{ SizeRequired, NoTty, IoctlFailed, InvalidWindowSize, UnsupportedPlatform };

pub fn determineCols(opts_cols: ?u16, has_tty: bool) SizeError!u16 {
    if (opts_cols) |c| return c;            // explicit --cols wins; never probes tty
    if (has_tty) return (try getSize()).cols;  // (try …) — getSize() is an error union
    return error.SizeRequired;              // no tty, no --cols => exit 2
}
```
VERIFIED (probe): `determineCols(80, false)` → 80; `determineCols(null, false)` →
error.SizeRequired; `determineCols(120, true)` → 120 (explicit path; getSize NOT called).

**Deterministic "no tty → exit 2" integration test:** run the binary under `setsid`
(detaches the controlling tty): `setsid bash -c "printf x | $BIN render"` ⇒
`hasControllingTty()` = false ⇒ exit 2. `setsid` is standard on Linux.

## 3. rows default = input line count (VERIFIED)

`std.mem.count(u8, ansi, "\n")` counts newlines. Robust "line count a text editor shows"
(count newlines + 1 for a trailing line with no newline; floor 1; clamp u16):
```zig
fn lineCount(ansi: []const u8) u16 {
    if (ansi.len == 0) return 1;
    var n: u32 = @intCast(std.mem.count(u8, ansi, "\n"));
    if (ansi[ansi.len - 1] != '\n') n += 1;   // trailing partial line
    if (n == 0) n = 1;
    return @intCast(@min(n, std.math.maxInt(u16)));
}
```
VERIFIED (probe): `""`→1, `"a\nb\n"`→2, `"a\nb"`→2, `"hello"`→1. The contract says "count
\n"; this is the robust form (raw `\n`-count under-counts `"a\nb"` as 1 row, which would
scroll "b" off the VT — `Options.trim=true` only trims TRAILING blanks, not missing rows).

## 4. Atomic file write (reuses palette.zig's proven pattern + the dirname-`.` trick)

palette.zig already proves the atomic write idiom (writeCacheDir): create a temp file IN THE
SAME DIRECTORY as the target (same filesystem ⇒ `rename` is atomic), write, best-effort
`sync()`, close, `rename(temp → target)`, clean up temp on error. render.zig needs its OWN
copy (palette's is palette-specific) but the shape is identical.

Gotcha: `std.fs.path.dirname(path)` is **nullable** (`?[]const u8`) for a bare filename like
`"out.html"`. `std.fs.cwd()` returns a Dir you must NOT close. **Trick: `dirname(path)
orelse "."`** then `std.fs.cwd().openDir(".", .{})` — opens cwd as a REAL, closeable Dir.
For absolute dirnames use `std.fs.openDirAbsolute`. Verified API names:
- `std.fs.Dir.createFile(sub_path, .{}) File.OpenError!File` (fs/Dir.zig:983)
- `std.fs.File.sync() SyncError!void` (fs/File.zig:217)
- `std.fs.Dir.rename(old_sub, new_sub) RenameError!void` (fs/Dir.zig:1772)
- `std.fs.Dir.deleteFile`, `std.fs.path.dirname/basename/isAbsolute`

renderGrid writes DIRECTLY into the temp file's `*std.Io.Writer` (the writer bridge works for
ANY File, not just stdout — verified): `var fw = f.writer(&buf); renderGrid(…, &fw.interface);
fw.interface.flush();` (same `&fw.interface` bridge S1 validated for stdout +
`Writer.Allocating`). No intermediate buffer → memory-efficient for large panes.

VERIFIED `renderToFileAtomic(allocator, abs_path, ansi, size, colors, font)` into a
`std.testing.tmpDir`: writes the file, leaves NO `.tmp` behind, content is valid HTML.

## 5. --open temp file (VERIFIED) + spawn xdg-open WITH wait (AVOID ZOMBILES)

No `std.fs.tmpName` in 0.15.2 (grep: none). Build a temp path from `$TMPDIR`/`/tmp` + random
hex (8 bytes → u64):
```zig
fn tempHtmlPath(alloc: std.mem.Allocator) ![]u8 {
    const dir = std.posix.getenv("TMPDIR") orelse "/tmp";   // posix.zig:2029, returns ?[:0]const u8
    var rnd: [8]u8 = undefined;
    std.crypto.random.bytes(&rnd);                           // std.crypto.random (global)
    const val: u64 = @bitCast(rnd);
    return std.fmt.allocPrint(alloc, "{s}/tmux-2html-{x}.html", .{ dir, val });
}
```
VERIFIED (probe): ends with `.html`, contains `/tmux-2html-`.

**xdg-open spawn — MUST call wait() (CRITICAL, from ghostty's own bug):**
ghostty-org/ghostty#5999 "Open actions do not perform wait() … This results in zombie
xdg-open processes." The project we depend on hit this exact bug. **Spawn + wait, ignore the
Term.** (xdg-open normally returns immediately — see unix.stackexchange q/74605 "xdg-open
always returns immediately" — so waiting does not stall the render.)
```zig
fn spawnXdgOpen(path: []const u8, alloc: std.mem.Allocator) void {
    var child = std.process.Child.init(&.{ "xdg-open", path }, alloc);  // process/Child.zig:215
    child.stdin_behavior = .Ignore;     // StdIo{Inherit,Ignore,Pipe,Close} (Child.zig:196)
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return;         // xdg-open missing / can't spawn => ignore (graceful)
    _ = child.wait() catch return;      // reap the child (no zombie); ignore exit status
}
```
VERIFIED API (read from process/Child.zig): `Child.init(argv: []const []const u8, alloc)
ChildProcess`; `.spawn() SpawnError!void` ("on success must call kill or wait"); `.wait()
WaitError!Term` where `Term = union(enum){ Exited: u8, Signal: u32, Stopped: u32 }`. Compiles
on macOS (verified) — there `xdg-open` is absent → `spawn()` fails → ignored (PRD §5.1 fixes
`xdg-open`; macOS support for `open` is out of v1 scope).

## 6. Exit-code plumbing (run returns !u8; size=2, write=1)

`main.run`'s dispatch does `dispatch(...) catch |err| switch(err){ error.NotImplemented=>1,
else => |e| return e }`. So a u8 returned by `render.run` flows straight to process exit
(`run → cli.render → dispatch → main.run → main → exit`). `render.run` is `!u8`:
- **Size error** (determineCols fails): print message to stderr, `return 2` (NOT an error —
  the contract's "Exit 2 on size/capture errors").
- **Output write error** (file create/write/rename, or stdout flush): print to stderr,
  `return 1` (render_help: "1 usage/runtime error"). Keep it explicit (don't let it bubble
  as a raw Zig error trace → exit 1 with a stack dump).
- renderGrid-internal OOM etc.: propagate (rare). 

`reportSizeError(err)` switches on SizeError to print a helpful one-liner
("--cols is required when input is not a tty" / "cannot determine terminal size").

## 7. run() structure (what S2 changes vs S1's run)

S1's `run` reads stdin → `defaultColors()` → `Size{cols: opts.cols orelse 80, rows: opts.rows
orelse 24}` → renderGrid → stdout. S2 KEEPS stdin-read + defaultColors + sel=null, and:
1. Replaces the size line with `determineCols(opts.cols, palette.hasControllingTty())` (→2
   on error) + `opts.rows orelse lineCount(ansi)`.
2. Replaces the unconditional-stdout block with a 3-arm switch:
   `opts.output` → renderToFileAtomic + (if open) spawnXdgOpen(output);
   `opts.open` (no output) → tempHtmlPath → renderToFileAtomic → spawnXdgOpen(temp);
   else → stdout (S1's path, verbatim).
`--font` is passed to renderGrid unchanged in all three arms.

## 8. What NOT to do (gotchas that bite)

- ❌ Don't reference `std.posix.system.T.IOCGWINSZ` / `std.posix.system.ioctl` — that's the
  libc/stub namespace; compiles Linux-only. Use `std.os.linux`.
- ❌ Don't forget `winsize` field order is `{row, col, …}` (col is field 1, NOT field 0).
- ❌ Don't spawn xdg-open without `wait()` (ghostty #5999 zombie bug).
- ❌ Don't `close()` a Dir returned by `std.fs.cwd()` — use the `dirname(path) orelse "."` +
  `openDir(".")` trick so the dir is always a real closeable handle.
- ❌ Don't write the temp file in a DIFFERENT dir than the target (cross-filesystem rename →
  EXDEV non-atomic). Temp MUST be same dir as target (the `.{base}.{rand}.tmp` name).
- ❌ Don't test the has_tty path of `determineCols` in a unit test (calls real /dev/tty) —
  assert only the explicit-cols + no-tty paths; use `setsid` for the integration exit-2 test.
- ❌ Don't hardcode "stdout" — S2 must preserve S1's stdout path byte-for-byte (no regression).
- ❌ Don't expand into S3 (--palette) or S4 (--selection). S2 keeps `defaultColors()` + null sel.
