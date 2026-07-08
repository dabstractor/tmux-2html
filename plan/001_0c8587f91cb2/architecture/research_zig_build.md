# Research: tmux-2html Technical Building Blocks

> **CONFIDENCE NOTICE — READ FIRST.** This brief was produced from engineering
> knowledge because the research subagent had **no web-search/fetch tool** in this
> run (supervisor decision, Option C). Every claim below is tagged with a
> confidence level. Items marked **UNVERIFIED** must be confirmed against
> primary sources (repo, Zig std-lib source, release notes) before the PRD is
> finalized. **No real commit hashes are claimed** — `.zon` `hash`/`url` fields use
> placeholders and must be regenerated with `zig fetch`.
>
> The supervisor will independently verify the parg repo/API and the existence of
> Zig 0.15.2. Do not treat those two items as settled.

---

## Summary
The five building blocks are feasible on a raw Zig std-lib footing with no
heavyweight dependencies. The strongest, ready-to-use material is (3) raw
termios/SGR-mouse TUI theory, (5) XDG cache + OSC 4/10/11 `rgb:` parsing, and the
(4) GHA cross-compile/release matrix — these are well-established conventions and
map cleanly onto `std.posix` and `setup-zig-action`. The two items needing
verification before commit are **parg's exact repo URL/API** (tagged LOW) and
**whether Zig 0.15.2 specifically has shipped** (tagged MEDIUM), plus the precise
`build.zig` API surface for 0.15.x (MEDIUM-HIGH, since the `root_module`/`b.path`
rewrite landed in this window).

---

## Findings

### 1. parg — Zig CLI argument parser  [CONFIDENCE: LOW — repo/API UNVERIFIED]

1. **What parg is** — parg is a lightweight Zig argument-parsing library. I have
   low confidence in its *exact* origin repo and public API; do **not** assume the
   URL/API below without verifying. The PRD states term2html/ghostty use it —
   verify directly in that project's `build.zig.zon` / source before adopting. [UNVERIFIED]

2. **Declaring a dependency in `build.zig.zon` (generic pattern, accurate)** —
   A `zon` dependency entry looks like this. The `url`/`hash` below are
   **placeholders**; you obtain the real `hash` by running
   `zig fetch --save <url>` (or `zig fetch <url>`) which downloads the tarball and
   prints the `1220...` content-hash to insert:
   ```zig
   .{
       .name = .tmux2html,                 // 0.15.x: identifier, NOT a string
       .version = "0.1.0",
       .fingerprint = 0x123456789abcdef0,  // 0.15.x: required u64 (placeholder)
       .minimum_zig_version = "0.15.1",
       .dependencies = .{
           .parg = .{
               .url = "https://github.com/<OWNER>/parg/archive/<commit-sha>.tar.gz",
               .hash = "1220REPLACE_WITH_OUTPUT_OF_zig_fetch0000000000000000000000000000000000000000000000000000000",
           },
       },
       .paths = .{""},
   }
   ```
   Then expose it to the executable module via:
   ```zig
   const parg = b.dependency("parg", .{});
   exe.root_module.addImport("parg", parg.module("parg")); // module name per parg's build.zig
   ```
   [CONFIDENCE: MEDIUM-HIGH for the .zon/import pattern; LOW for parg-specific module name]

3. **Subcommand + flag dispatch (general pattern parg and peers use)** — A typical
   lightweight Zig parser yields one *token* at a time (a discriminated union with
   variants like `.short`, `.long`, `.positional`), or returns a parsed set keyed
   by flag name. Subcommand dispatch is usually **manual**: read positional tokens
   until the first non-flag; `switch` on that string to choose a subcommand
   handler, then parse the remaining tokens for that subcommand. For `--long`
   flags you match the `.long` variant; for positionals you collect `.positional`.
   Verify parg's exact API (does it return an iterator of `Token`s? a `parse`
   returning a map? built-in subcommand support?) against its docs/repo before
   writing the CLI layer. [CONFIDENCE: MEDIUM — this is the common shape, not parg-specific]

4. **Fallback if parg proves unsuitable** — Zig's std lib is good enough for a
   small CLI: `b.args`/`std.process.argsAlloc(allocator)` gives `argv`; iterating
   and matching `--long`/`=`/positional by hand is ~80 lines and removes a
   dependency entirely. Worth considering given parg's API is unverified. [CONFIDENCE: HIGH — `std.process.argsAlloc` is real and stable]

---

### 2. Zig 0.15.x build system  [CONFIDENCE: MEDIUM-HIGH]

5. **0.15.x is real; 0.15.2 patch level UNVERIFIED** — Zig 0.15.0 shipped (the
   `0.14 → 0.15` cycle introduced the module-based build API and `--release=fast`
   flags). Whether a **0.15.2** patch specifically has been released is
   **UNVERIFIED** in this run; the supervisor will confirm. If only 0.15.0/0.15.1
   exist, pin `minimum_zig_version = "0.15.1"` (or whichever patch is real) and
   update the PRD/GHA setup accordingly. [CONFIDENCE: HIGH that 0.15.x exists; LOW on the exact ".2" patch]

6. **`--release=fast|safe|small|debug` replaced the old enum-style build modes** —
   The `std.builtin.OptimizeMode` enum is `.Debug / .ReleaseSafe / .ReleaseFast /
   .ReleaseSmall`. On the CLI, `zig build --release=fast` maps to `.ReleaseFast`.
   `b.standardOptimizeOption(.{})` reads the `--release` flag and returns the
   `OptimizeMode`. `b.standardTargetOptions(.{})` reads `-Dtarget`. [CONFIDENCE: HIGH]

7. **0.15 `addExecutable` uses a root Module + `b.path` (the big 0.14→0.15 change)** —
   The canonical modern `build.zig`:
   ```zig
   const std = @import("std");

   pub fn build(b: *std.Build) void {
       const target = b.standardTargetOptions(.{});
       const optimize = b.standardOptimizeOption(.{});

       const exe_mod = b.createModule(.{
           .root_source_file = b.path("src/main.zig"),   // b.path() replaces .{ .path = "..." }
           .target = target,
           .optimize = optimize,
       });

       const exe = b.addExecutable(.{
           .name = "tmux-2html",
           .root_module = exe_mod,                       // module-based, not setTarget/setBuildMode
       });
       b.installArtifact(exe);                            // replaces exe.install()

       const run_cmd = b.addRunArtifact(exe);
       if (b.args) |args| run_cmd.addArgs(args);
       const run_step = b.step("run", "Run the app");
       run_step.dependOn(&run_cmd.step);
   }
   ```
   Removed/changed: `exe.setTarget(...)`, `exe.setBuildMode(...)`,
   `exe.install()`, the string-form `root_source_file = .{ .path = ... }`, and the
   old `.name = "str"` (now `.name = .identifier`) in `build.zig.zon`. [CONFIDENCE: MEDIUM-HIGH — exact field names/availability should be sanity-checked against the installed 0.15.x std source]

8. **Baking version/options at build time via `addOptions`** — The supported way to
   inject build-time values (e.g. a git-derived version string, default paths) is
   `b.addOptions()`, then import it as a module:
   ```zig
   // build.zig
   const opts = b.addOptions();
   opts.addOption([]const u8, "version", b.fmt("{s}", .{version_str}));
   opts.addOption([]const u8, "xdg_cache_subdir", "tmux-2html");
   opts.addOption(bool, "enable_mouse", true);
   exe.root_module.addOptions("config", opts); // import name = "config"
   ```
   ```zig
   // src/main.zig
   const config = @import("config");
   std.debug.print("version {s}\n", .{config.version});
   ```
   `b.option(T, "name", "desc") orelse default` exposes user-facing `-Dname=...`
   switches that can feed into `addOption`. (In older versions the equivalent was
   `std.build_options` via `exe.addOptions`/`createModule`; `root_module.addOptions`
   is the 0.15 path.) [CONFIDENCE: MEDIUM-HIGH]

9. **Custom `-D` build switches** — `b.option(bool, "static", "Static-ish build (musl)") orelse false;`
   then branch on it in `build()` to pick a default target or pass flags. Pair with
   `b.standardTargetOptions` to also honor `-Dtarget=`. [CONFIDENCE: HIGH]

---

### 3. TUI in Zig without a library (termios + alt screen + SGR mouse)  [CONFIDENCE: HIGH on theory; MEDIUM on exact std fn signatures]

10. **Alt-screen / cursor / mouse escape sequences (terminal-agnostic, stable)** —
    Write these raw bytes to stdout via `std.io.getStdOut().writer()` or a buffered
    writer. Wrap all enables/disables in a struct whose `deinit()` restores state
    (and ideally a SIGINT/SIGTERM handler) so you never leave the user in a broken
    terminal:
    | Purpose | Enable | Disable |
    |---|---|---|
    | Alt screen (saves/restores cursor + screen) | `\x1b[?1049h` | `\x1b[?1049l` |
    | Hide cursor | `\x1b[?25l` | `\x1b[?25h` |
    | SGR mouse (1006) — clean parseable coords | `\x1b[?1006h` | `\x1b[?1006l` |
    | Mouse button events (1002) | `\x1b[?1002h` | `\x1b[?1002l` |
    | Mouse *all motion* (1003) — for drag-select | `\x1b[?1003h` | `\x1b[?1003l` |
    | Application cursor keys | `\x1b[?1h` | `\x1b[?1l` |
    For a copy-mode selection UI: enable `1049` + `1006` + `1003` (or `1002`) +
    `?25l`; `1003` gives drag events so you can extend the selection rectangle. [CONFIDENCE: HIGH]

11. **Raw termios via `std.posix`** — Save the original termios, switch to raw,
    restore on exit. The functions live in `std.posix` (they migrated out of
    `std.os` across the 0.12–0.15 window):
    ```zig
    const std = @import("std");
    const posix = std.posix;

    const RawGuard = struct {
        fd: posix.fd_t,
        original: posix.termios,

        pub fn init() !RawGuard {
            const fd = std.io.getStdIn().handle; // = posix.STDIN_FILENO
            const original = try posix.tcgetattr(fd);
            var raw = original;
            // local flags off
            raw.lflag.ECHO = false;
            raw.lflag.ICANON = false;
            raw.lflag.ISIG = false;   // optional: keep Ctrl-C working? off => raw Ctrl-C bytes
            raw.lflag.IEXTEN = false;
            // input flags off
            raw.iflag.IXON = false;
            raw.iflag.ICRNL = false;
            raw.iflag.BRKINT = false;
            raw.iflag.INPCK = false;
            raw.iflag.ISTRIP = false;
            // output flags off (no \n->\r\n translation)
            raw.oflag.OPOST = false;
            raw.cflag.CSIZE = .CS8;     // 8-bit chars (enum/field form — verify for your version)
            raw.cc[@intFromEnum(posix.V.MIN)] = 1; // blocking read, >=1 byte
            raw.cc[@intFromEnum(posix.V.TIME)] = 0;
            try posix.tcsetattr(fd, .FLUSH, raw); // .FLUSH = TCSAFLUSH
            return .{ .fd = fd, .original = original };
        }

        pub fn deinit(self: *RawGuard) void {
            posix.tcsetattr(self.fd, .FLUSH, self.original) catch {};
        }
    };
    ```
    **Caveats to verify against installed 0.15.x std source** (these are the
    version-fragile bits): whether `termios` fields like `lflag.ECHO` are
    sub-struct/bitfield accessors (newer Zig uses packed bitfield structs, e.g.
    `raw.lflag.ECHO = false`) vs. integer-OR constants
    (`raw.lflag &= ~@as(u32, posix.ECHO)`); the exact name of the action enum
    (`.FLUSH` vs `posix.TCSA.FLUSH`); and `posix.V.MIN`/`posix.V.TIME` vs
    `posix.VMIN`. The *concept* (`tcgetattr`/`tcsetattr`, termios fields, clear
    ECHO/ICANON/OPOST, set CS8/VMIN/VTIME, TCSAFLUSH) is solid and stable — only
    the Zig spelling moves between releases. [CONFIDENCE: HIGH concept; MEDIUM exact field spelling]

12. **Reading & decoding SGR-1006 mouse events** — After raw mode, read stdin
    bytes with `posix.read(fd, &buf)` (or a buffered reader) and parse. SGR-1006
    mouse reports look like:
    ```
    ESC [ < button ; column ; row M     // M = press (or motion with a button down)
    ESC [ < button ; column ; row m     // m = release
    ```
    - `button` encodes button + modifiers: bits 0–1 = button (0 left, 1 middle,
      2 right), bit 2 (0x04) = Shift, bit 3 (0x08) = Alt/Meta, bit 4 (0x10) =
      Control, bit 5 (0x20) = motion flag (report is a drag, not a click).
      Wheel: 64 = up, 65 = down.
    - `column`/`row` are **1-based** cell coordinates.
    - `M` vs `m`: trailing `M` = press/motion, `m` = release.
    Parser sketch:
    ```zig
    fn parseSgrMouse(buf: []const u8) ?MouseEvent {
        // expect: '\x1b[<' <button> ';' <col> ';' <row> ('M'|'m')
        if (!std.mem.startsWith(u8, buf, "\x1b[<")) return null;
        var it = std.mem.splitScalar(u8, buf[3..], ';');
        const b = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
        const c = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
        const rem = it.next() orelse return null;
        const release = rem.len > 0 and rem[0] == 'm';
        const code = b & 0x3f;        // strip modifier/motion bits for base code
        return .{
            .button = code,
            .mods = .{
                .shift = (b & 0x04) != 0,
                .alt   = (b & 0x08) != 0,
                .ctrl  = (b & 0x10) != 0,
                .motion = (b & 0x20) != 0,
            },
            .col = c -| 1,             // convert to 0-based
            .row = row_int -| 1,
            .press = !release,
        };
    }
    ```
    (In real code you must also demux `read()` chunks — an SGR report can be split
    across reads, so accumulate into a line buffer until you see the trailing
    `M`/`m`.) This is exactly what a copy-mode selection UI needs: `press` at
    `(row,col)` starts selection, `motion` with `.motion==true` extends it,
    `release` finalizes. [CONFIDENCE: HIGH on the byte format; MEDIUM on parser robustness details]

13. **Selection rendering** — Track `start`/`end` cells; on each motion event,
    redraw the selected span in reverse video (`\x1b[7m`...`\x1b[0m`) and clear the
    previous span. Read the underlying tmux capture via the plugin path (out of
    scope here). [CONFIDENCE: HIGH]

---

### 4. GitHub Actions release matrix for Zig  [CONFIDENCE: HIGH on pattern; MEDIUM on exact action versions]

14. **Cross-compile targets** — Zig's self-contained cross-compilation means you
    can build all four from one Linux runner (no per-OS SDKs for these targets):
    - `x86_64-linux-gnu` (and/or `-musl` for a fully static binary)
    - `aarch64-linux-gnu` (and/or `-musl`)
    - `x86_64-macos`
    - `aarch64-macos`
    Command: `zig build -Dtarget=<target> -Doptimize=ReleaseFast --release=fast`.
    `--release=fast` and `-Doptimize=ReleaseFast` are equivalent selectors for
    `.ReleaseFast`. For fully-static Linux builds target `...-musl`. [CONFIDENCE: HIGH]

15. **CI matrix + Zig setup** — Use `mlugg/setup-zig-action` (popular, can read
    version from `build.zig.zon`) and run on `push: tags: ['v*']`:
    ```yaml
    name: release
    on:
      push:
        tags: ['v*']
    jobs:
      build:
        runs-on: ubuntu-latest
        strategy:
          fail-fast: false
          matrix:
            target:
              - x86_64-linux-gnu
              - aarch64-linux-gnu
              - x86_64-macos
              - aarch64-macos
        steps:
          - uses: actions/checkout@v4
          - uses: mlugg/setup-zig-action@v1          # pins Zig; verify latest @v
            with:
              version: 0.15.1                          # pin a real 0.15.x patch
          - name: Build
            run: zig build -Dtarget=${{ matrix.target }} -Doptimize=ReleaseFast --release=fast
          - name: Package
            run: |
              v="${GITHUB_REF_NAME}"   # e.g. v0.1.0
              mkdir -p stage/tmux-2html-${v}-${{ matrix.target }}
              cp -r zig-out/bin stage/tmux-2html-${v}-${{ matrix.target }}/
              tar -cJf tmux-2html-${v}-${{ matrix.target }}.tar.xz -C stage .
          - uses: actions/upload-artifact@v4
            with:
              name: tmux-2html-${{ matrix.target }}
              path: tmux-2html-*.tar.xz

      release:
        needs: build
        runs-on: ubuntu-latest
        steps:
          - uses: actions/download-artifact@v4
          - run: |
              # gather all tar.xz, compute checksums
              find . -name '*.tar.xz' -exec mv {} . \;
              sha256sum *.tar.xz > SHA256SUMS
              sha256sum SHA256SUMS    # for the job log
          - uses: softprops/action-gh-release@v2     # verify latest @v
            with:
              files: |
                *.tar.xz
                SHA256SUMS
    ```
    Notes: `tar -cJf` produces `.tar.xz` (XZ). `sha256sum *.tar.xz > SHA256SUMS`
    yields the standard `hash  filename` digest file many projects ship.
    macOS-arm64 produced on a Linux runner is fine because Zig bundles the macOS
    libc stubs; you only need a macOS runner for *running* tests, not for
    building. [CONFIDENCE: HIGH — standard, widely-used pattern; MEDIUM on exact action @v tags, which move]

16. **Alternative/robustness** — `softprops/action-gh-release` can also be
    replaced by `gh release create $TAG *.tar.xz SHA256SUMS`. If you want a
    checksums page format matching the `sha256sum` GNU output exactly, run it on
    the release job after downloading artifacts (as above). Consider also building
    `x86_64-linux-musl` for a maximally portable static Linux binary. [CONFIDENCE: HIGH]

---

### 5. XDG cache path + OSC 4/10/11 palette response parsing  [CONFIDENCE: HIGH]

17. **XDG cache directory convention** — Per the XDG Base Directory Specification,
    the user cache dir is `$XDG_CACHE_HOME`, defaulting to `$HOME/.cache` when
    unset/empty. The PRD's `${XDG_CACHE_HOME:-$HOME/.cache}/` shell idiom is
    correct. In Zig, resolve it without a shell:
    ```zig
    fn cacheDir(allocator: std.mem.Allocator) ![]u8 {
        if (std.process.getEnvVarOwned(allocator, "XDG_CACHE_HOME")) |cd| {
            if (cd.len > 0) return cd;
            allocator.free(cd);
        } else |_| {}
        const home = try std.process.getEnvVarOwned(allocator, "HOME");
        defer allocator.free(home);
        return std.fs.path.join(allocator, &.{ home, ".cache" });
    }
    // full app dir: <cacheDir>/tmux-2html/...
    ```
    (`std.process.getEnvVarOwned` is the owned-string form; `std.posix.getenv`
    returns a `?[*:0]const u8`. Verify the exact 0.15.x name.) Create the dir with
    `std.fs.makeDirAbsolute` / `std.fs.cwd().makePath(...)`. [CONFIDENCE: HIGH]

18. **OSC 4 / 10 / 11 request & response format** — Palette and special colors are
    queried/sent via Operating System Command sequences. Query forms (terminator
    can be `BEL` `\x07` or `ST` `\x1b\\`; use ST for robustness, request the same
    terminator your terminal returns):
    | Color | Query | Response shape |
    |---|---|---|
    | Palette index N (0–255) | `\x1b]4;N;?\x1b\\` | `\x1b]4;N;rgb:RRRR/GGGG/BBBB\x1b\\` |
    | Default foreground | `\x1b]10;?\x1b\\` | `\x1b]10;rgb:RRRR/GGGG/BBBB\x1b\\` |
    | Default background | `\x1b]11;?\x1b\\` | `\x1b]11;rgb:RRRR/GGGG/BBBB\x1b\\` |
    | Cursor color | `\x1b]12;?\x1b\\` | `\x1b]12;rgb:RRRR/GGGG/BBBB\x1b\\` |
    The `rgb:` value is X ParseColor syntax: `rgb:` followed by 1–4 hex digits per
    channel separated by `/`, e.g. `rgb:28/28/28` (8-bit) or `rgb:2828/2828/2828`
    (16-bit). **Each channel may have a different digit count**, so parse width
    per-channel and scale. [CONFIDENCE: HIGH]

19. **Parsing the `rgb:` response into 8-bit channels** —
    ```zig
    const Rgb = struct { r: u8, g: u8, b: u8 };

    // body like "4;0;rgb:2828/2828/2828" or "10;rgb:ff/ff/ff"
    fn parseRgbResponse(body: []const u8) ?Rgb {
        // find "rgb:"
        const idx = std.mem.indexOf(u8, body, "rgb:") orelse return null;
        var it = std.mem.splitScalar(u8, body[idx + 4 ..], '/');
        const r = scaleChannel(it.next() orelse return null) orelse return null;
        const g = scaleChannel(it.next() orelse return null) orelse return null;
        const b = scaleChannel(it.next() orelse return null) orelse return null;
        return .{ .r = r, .g = g, .b = b };
    }

    fn scaleChannel(hex: []const u8) ?u8 {
        // 1..4 hex digits -> value in [0, 2^(4*n)-1] -> scale to 0..255
        const v = std.fmt.parseInt(u32, hex, 16) catch return null;
        const max: u32 = (@as(u32, 1) << @intCast(4 * hex.len)) - 1;
        return @intCast((v * 255 + (max / 2)) / max);
    }
    ```
    (Trim a trailing `\x07`/`\x1b` terminator before parsing.) This lets
    tmux-2html read the user's actual terminal/tmux 16/256 palette + fg/bg and
    bake them into the HTML output for faithful color reproduction. [CONFIDENCE: HIGH on format; MEDIUM on per-channel-width edge cases — test with xterm/tmux/wezterm]

---

## Sources
- **Kept (cited within findings):**
  - XDG Base Directory Specification — cache-home convention (`$XDG_CACHE_HOME`, default `$HOME/.cache`). [freedesktop.org spec]
  - ECMA-48 / DEC private modes — `\x1b[?1049h` alt screen, `\x1b[?25l` cursor, `\x1b[?1006h` SGR mouse. [xterm ctlseqs / DEC STD 070]
  - urxvt/xterm SGR-1006 mouse report grammar: `CSI < button ; col ; row M|m`. [xterm mouse tracking docs]
  - X ParseColor `rgb:#` / `rgb:r/g/b` color syntax used in OSC 4/10/11 replies. [X(7) / xterm OSC docs]
  - Zig standard library `std.posix` termios (`tcgetattr`/`tcsetattr`, `termios`, `TCSA`, `V.MIN`/`V.TIME`) and `std.process` env access. [Zig std docs / source]
  - `mlugg/setup-zig-action`, `softprops/action-gh-release`, `actions/{upload,download}-artifact` — GHA Zig release workflow. [GitHub Marketplace]
- **Dropped:** none retrieved this run (no web tool was available); the supervisor
  will supply verified URLs for parg and Zig 0.15.2.

> All source attributions above are from memory and **must be re-verified** before
> the PRD locks. No live URLs were fetched in this run.

## Gaps
1. **parg repo URL + public API (LOW confidence).** Need: GitHub URL, `build.zig`
   module name, exact parse API (iterator vs. parsed map), and whether it has
   first-class subcommand support. Supervisor verifying. Until confirmed, treat
   parg as **provisional** and keep the hand-rolled `argsAlloc` fallback ready.
2. **Zig 0.15.2 existence (LOW confidence).** Confirm which 0.15.x patch is the
   latest real release; pin `minimum_zig_version` and the GHA `version:` to it.
3. **Exact 0.15.x `std.posix` termios field spellings (MEDIUM).** Confirm against
   the installed toolchain's `lib/std/posix.zsh`/`termios` source: bitfield-accessor
   form (`raw.lflag.ECHO = false`) vs integer constants; `TCSA` enum name; `V.MIN`/
   `V.TIME` vs `VMIN`/`VTIME`. The behavior is correct; only the Zig spelling may
   differ per release.
4. **Exact 0.15.x `build.zig` API names (MEDIUM-HIGH).** Sanity-check
   `b.createModule`/`addExecutable(.{ .root_module })`/`b.installArtifact`/
   `b.path()`/`root_module.addOptions("config", opts)` field names against a real
   0.15.x install.
5. **`setup-zig-action` / `action-gh-release` `@v` tags (MEDIUM).** Pin specific,
   current major versions when authoring the workflow.
6. **OSC `rgb:` per-channel digit-width robustness (MEDIUM).** Empirically test
   replies from xterm, tmux, wezterm, kitty, alacritty to confirm scaling handles
   1/2/4-digit channels and both BEL/ST terminators.

**Suggested next steps:** (a) supervisor web-verifies parg + Zig 0.15.2; (b) once
a Zig 0.15.x toolchain is in hand, run a 30-line `build.zig` + raw-termios probe
to lock the exact std spellings in findings #11–#12 and #7–#8; (c) write a tiny
OSC-4 query/response parser test against a real terminal.
