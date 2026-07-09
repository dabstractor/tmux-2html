# Research findings — P1.M2.T2.S1 (sync-palette command)

## 1. Task & contract (verbatim from item description)

- Default `--from tty`. `--force` re-queries even if cache exists.
- Exits non-zero if terminal doesn't respond within timeout
  (`palette_received_count<256` → warning; total failure → error exit).
- INPUT: `cli.SyncPaletteOpts{from, force}` (cli.zig, P1.M1.T3.S2 — DONE);
  `palette.queryColors` / `writeCache` (P1.M2.T1).
- LOGIC: in main.zig dispatch + a `syncPalette(opts)` fn. `--from tty` → queryColors
  (requires /dev/tty; if absent, error exit 2). `--from file PATH` → loadColors from a
  file instead. Unless cache exists AND not `--force`, writeCache. Print summary
  (`queried N/256 colors; cache at <path>`).
- DOCS: Mode A — document sync-palette + in-tmux-vs-outer-terminal caveat in
  `docs/CONFIGURATION.md` §sync-palette.

## 2. Consumed contracts (read directly from source — treat as FIXED)

### palette.zig (S1 + S2 — ALREADY IN THE FILE)
- `pub const Colors = struct { palette: [256]color.RGB, foreground: ?color.RGB,
  background: ?color.RGB, palette_received_count: u16 }`
- `pub fn defaultColors() Colors` — Ghostty palette, fg=default[7], bg={41,44,51}, count=256.
- `pub fn queryColors(allocator) !Colors` — opens `/dev/tty` read_write; **ERRORS** if
  /dev/tty can't be opened (no controlling tty) OR termios fails. Raw mode, OSC-4 batches
  of 32 + OSC 10/11, 500ms V.TIME timeout. Logs `std.log.warn` if count<256.
- `pub fn cachePath(allocator) ![]u8` — `${XDG_CACHE_HOME:-$HOME/.cache}/tmux-2html/palette`;
  errors `NoHomeDirectory` if $HOME unset. Caller owns the slice.
- `pub fn loadCache(allocator) !Colors` — reads cachePath; PROPAGATES FileNotFound if absent;
  seeds from defaultColors; errors only on malformed line / missing $HOME.
- `pub fn writeCache(allocator, colors) !void` — makePath parent + openDirAbsolute +
  writeCacheDir (atomic temp+rename). The dir-scoped helpers `loadCacheDir` /
  `writeCacheDir` are currently **module-private**.
- `fn parse(text) !Colors` (private) — plain-text decoder; errors `MalformedLine`.

### palette.zig (S3 — PARALLEL, treat PRP as contract; will be in the file at impl time)
- `pub const Mode = enum { default, cached, live }` + `fromStr`.
- `pub fn hasControllingTty() bool` — probes /dev/tty read-only (openFileAbsolute(.{}));
  false under run-shell / no controlling tty. **Not strictly needed by sync-palette**
  (queryColors already errors on no-tty), but available.
- `pub fn resolve(allocator, mode, has_tty) Colors` — infallible. sync-palette does NOT
  use resolve (it PRODUCES the cache, not consumes it).

### cli.zig (P1.M1.T3.S2 — DONE)
- `pub const PaletteSource = union(enum) { tty, file: []const u8 }`.
- `pub const SyncPaletteOpts = struct { from: PaletteSource = .tty, force: bool = false }`.
- `pub fn parseSyncPalette(args) ParseError!SyncPaletteOpts` — PURE, pub, unit-tested.
  Handles `--from tty` / `--from file PATH` / `--force` / `--help`.
- `pub fn syncPalette(allocator, args) !u8` — currently: --help→print+0; parse error→
  reportError+1; success→`return error.NotImplemented`. **MUST be wired to the body.**
- `fn hasHelpFlag`, `fn reportError`, `const sync_palette_help` are **module-private**.

### main.zig (current dispatch)
- `dispatch(allocator, name, sub_args) !u8` routes `sync-palette` → `cli.syncPalette(...)`.
- `run()` maps `error.NotImplemented` → "not yet implemented" + exit 1.
- main.zig imports ONLY `cli.zig`, `parg`, `build_options` on the exe path. palette.zig is
  imported ONLY in the top-level `test {}` block (S1). **This task must add
  `const palette = @import("palette.zig")` to the exe path** (sync-palette runs queryColors).

## 3. Build / ghostty-vt facts (EMPIRICALLY VERIFIED)

- `zig build` (Debug) FAILS: `R_X86_64_PC64` linker error. ghostty-vt is ALREADY compiled
  into the exe (the `build-exe` line shows `--dep ghostty-vt -Mghostty-vt=...`), because
  build.zig registers `ghostty-vt` as an import on `exe.root_module` unconditionally.
  ⇒ The S1/S2/S3 "ghostty stays lazy on the exe path" claim is INACTIVE: ghostty is on the
  exe path already. Adding `const palette = @import("palette.zig")` to main.zig does NOT
  newly pull ghostty in (it's already there).
- `zig build --release=fast` SUCCEEDS (baseline verified: exe built, 3.7 MB).
  ⇒ **`--release=fast` is MANDATORY for BOTH exe and test builds** (Debug linker bug).
- `tmux-2html sync-palette --help` → prints help, exit 0 (works now).
- `tmux-2html sync-palette` → "not yet implemented", exit 1 (NotImplemented path).

## 4. Zig 0.15.2 std APIs needed (VERIFIED line-by-line in cached std source)

- `std.fs.Dir.statFile(sub_path) StatFileError!Stat` (Dir.zig:2688) — errors FileNotFound
  if missing. Use for the cache_exists check: `_ = dir.statFile(name) catch false`.
- `std.fs.Dir.openFile(sub_path, File.OpenFlags) File.OpenError!File` (Dir.zig:818) — for
  relative PATH in loadColorsFile. `std.fs.cwd()` (fs.zig:220) returns the cwd Dir.
- `std.fs.openFileAbsolute(path, File.OpenFlags)` (fs.zig:268) — for absolute PATH.
- `File.OpenFlags` default mode = `.read_only` (File.zig:93). `.{}` = read-only. ✓
- `std.fs.Dir.makePath(sub_path)` (Dir.zig:1175) — idempotent mkdir; tolerates existing.
- `File.readToEndAlloc(allocator, max_bytes) ![]u8` (File.zig:809) — used by S2's loadCacheDir.
- `std.fs.path.isAbsolute(path) bool` (path.zig:277); `dirname(path) ?[]const u8` (845,
  NULLABLE); `basename(path) []const u8` (979). All used by S2's cachePath/writeCache.
- NO `setenv` in std (verified in S3) ⇒ tests cannot redirect XDG_CACHE_HOME; use
  `std.testing.tmpDir` for isolated cache dir, mirroring S2's pattern.

## 5. Design decisions (reconciling PRD §5.4 + §6 + the item contract)

### Exit codes
- 0: success (cache written, OR cache exists & not force → skipped; summary printed).
- 1: runtime error — `--from file PATH` unreadable/missing/malformed; cache-path/`$HOME`
  problems; write failure.
- 2: capture/target error — `--from tty` and queryColors errors (no /dev/tty / termios
  fails / terminal unreachable). **Pinned by contract point 4: "missing tty → exit 2".**

### Acquire-vs-write gating (PRD §5.4: "--force re-query even if a cache exists")
- `--force` = re-query/re-load AND overwrite. WITHOUT `--force`, if cache EXISTS → skip
  BOTH acquire and write (no point querying just to discard; and this lets `sync-palette`
  succeed without a tty when a cache is already present).
- Decision fn: `shouldRun(cache_exists, force) = !cache_exists or force`.
- This is the SENSIBLE reading of PRD §5.4 ("--force re-query even if a cache exists" ⇒
  without force, no re-query when cache exists). The contract's "Unless cache exists AND
  not force, writeCache" is the write half of the SAME condition.

### Partial response (count < 256)
- queryColors already logs `std.log.warn` for count<256. sync-palette treats ANY
  successfully-returned Colors (incl. count 0) as a WARN + WRITE + exit 0 (literal
  contract: "palette_received_count<256 → warning"). queryColors ERROR → exit 2.
- Summary reports `N/256` so the user sees the count.

### Summary line
- tty : `queried N/256 colors; cache at <path>`
- file: `loaded N/256 colors; cache at <path>`
- skip: `palette cache already exists at <path>; use --force to re-query`
- Printed to stdout. Warnings to stderr (std.log.warn).

## 6. Architecture / wiring decision

- **Body lives in main.zig** (contract: "In main.zig dispatch + a syncPalette(opts) fn").
  main.zig is the ONLY module allowed to import BOTH cli (ghostty-free) and palette
  (ghostty-aware). cli.zig MUST stay ghostty-free (S1/S2/S3 boundary) ⇒ body cannot be
  in cli.zig.
- **Wiring**: change `cli.syncPalette` to accept an injected body fn pointer
  `run: *const fn(allocator, SyncPaletteOpts) anyerror!u8`; on successful parse, call
  `run(allocator, opts)` instead of `return error.NotImplemented`. main.zig dispatch passes
  `syncPaletteBody`. This keeps cli's --help/parse/report logic (no duplication, no dead
  code, no exposed internals) and keeps cli ghostty-free (it never imports palette; just
  calls a fn pointer).
- **palette.zig change**: ADD ONE pub fn `loadColorsFile(allocator, path) !Colors`
  (opens file relative-or-absolute, readToEndAlloc, calls existing private `parse`).
  Needed because `parse` is private and the `--from file` path must decode a palette file.
  Add it in the cache I/O section (NOT where S3 appends resolve at the end) ⇒ no conflict.
- **Testability**: factor a PURE `shouldRun(cache_exists, force) bool` + PURE summary
  formatter in main.zig (testable without I/O). Add a dir-scoped core
  `syncPaletteDir(...)` returning `{ code, summary }` so `--from file` acquire+write+skip
  is tested via `std.testing.tmpDir` (no real-cache mutation). Expose S2's
  `writeCacheDir`/`loadCacheDir` as `pub` (2-keyword additive change) so the core can do
  dir-scoped cache I/O. tty path (queryColors) stays compile-verified + interactive-only,
  exactly like S1 leaves queryColors.

## 7. Docs target
- `docs/CONFIGURATION.md` already has `## Palette` (S2). ADD a `### sync-palette`
  subsection covering: --from tty (default) / --from file PATH; --force; exit codes;
  partial-response warning; and the in-tmux-vs-outer-terminal caveat (PRD §6: inside tmux
  → tmux-presented palette; outside tmux / in display-popup → outer terminal palette).
