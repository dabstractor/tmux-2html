# Research findings — P1.M2.T1.S3: `palette.resolve()` precedence

> All std APIs below were read line-by-line from the cached Zig 0.15.2 source
> (`/home/dustin/.local/opt/zig-x86_64-linux-0.15.2/lib/std`). Citations are file:line.

## 0. What this task is (one paragraph)

Add the **precedence/resolution layer** to `src/palette.zig`: a `Mode` enum
`{ default, cached, live }`, an infallible `resolve(allocator, mode, has_tty) Colors`
that implements the PRD §6 precedence (cached → live[only if tty] → default, with
mode-specific ordering), and `hasControllingTty() bool` (open `/dev/tty` read-only,
close, return true/false). It CONSUMES S1's `queryColors`/`defaultColors` and S2's
`cachePath`/`loadCache` (and S2's dir-scoped `loadCacheDir`). No new files, no docs
(the contract says DOCS: none — the cache docs are S2's, the flag is render's help).

## 1. Consumed contracts (the API surface this task builds on)

- **S1 (`src/palette.zig`, COMPLETE):**
  - `pub const Colors = struct { palette: [256]color.RGB, foreground: ?color.RGB, background: ?color.RGB, palette_received_count: u16 };`
  - `pub fn defaultColors() Colors` — Ghostty bundled palette; `fg=color.default[7]`, `bg={41,44,51}`, count=256.
  - `pub fn queryColors(allocator: std.mem.Allocator) !Colors` — opens `/dev/tty` read_write, raw termios, OSC 4/10/11, returns `!Colors` (errors if `/dev/tty` can't be opened → i.e. no controlling tty). **ERRORS on no-tty** → that is precisely why resolve() guards it with `has_tty`.
- **S2 (`src/palette.zig`, IN PROGRESS — treat its PRP as a contract):**
  - `pub fn cachePath(allocator: std.mem.Allocator) ![]u8` — `${XDG_CACHE_HOME:-$HOME/.cache}/tmux-2html/palette`. Errors on no `$HOME`. Caller owns the slice.
  - `pub fn loadCache(allocator: std.mem.Allocator) !Colors` — opens the real cache file; seeds `defaultColors()`, tolerates missing entries; errors only on missing file / malformed line.
  - **`fn loadCacheDir(dir: std.fs.Dir, filename: []const u8, allocator: std.mem.Allocator) !Colors`** — dir-scoped helper (module-private). THIS is what resolveDir calls for deterministic tmpDir testing (mirrors S2's own writeCacheDir/loadCacheDir test pattern).
  - `fn writeCacheDir(dir, filename, allocator, colors) !void` — used by tests to seed a tmpDir cache.
- **S1 also fixed test reachability:** `src/main.zig` already has the top-level
  `test { _ = @import("palette.zig"); }` block. New S3 tests in palette.zig are
  **auto-reachable** — NO main.zig edit. `build.zig`/`build.zig.zon`/`src/cli.zig` UNCHANGED.

## 2. The precedence logic (PRD §6 + item contract), made precise

The item contract dictates per-mode ordering, with `has_tty` gating the **live**
attempt:

| mode     | attempt order                                                       |
|----------|---------------------------------------------------------------------|
| `default`| → `defaultColors()` (never touches cache or tty)                    |
| `cached` | → `loadCache` ; on miss → `queryColors` (only if `has_tty`) → `default` |
| `live`   | → `queryColors` (only if `has_tty`) ; on miss → `loadCache` → `default` |

Crucially, `resolve()` is **infallible** (returns `Colors`, NOT `!Colors`) and
"never panics on missing tty" — every error from `cachePath`/`loadCache`/`queryColors`
is swallowed and routed to the next lower source, bottoming out at `defaultColors()`.

## 3. Controlling-tty detection — the `/dev/tty` open idiom (verified)

The contract: "Expose `hasControllingTty()` (try open `/dev/tty` read-only, close,
return true/false)."

- `/dev/tty` is the process's **controlling terminal** alias. It EXISTS as a device
  node even with no controlling tty, but **`open("/dev/tty")` FAILS with ENXIO**
  ("No such device or address") when the process has NO controlling terminal. This is
  exactly the run-shell condition (PRD §6, architecture findings §3). So
  "open succeeded ⇒ we have a controlling tty" is the correct POSIX idiom
  (more reliable than `isatty(STDIN_FILENO)`, which is false for a piped stdin even in
  an interactive shell).
- `std.fs.openFileAbsolute(path, flags)` (fs.zig:268) takes `File.OpenFlags`.
- `File.OpenFlags` (File.zig:93): `mode: OpenMode = .read_only` (default) **and**
  **`allow_ctty: bool = false`** (File.zig:113, default). This is the key flag:
  > "Set this to allow the opened file to automatically become the controlling TTY
  > for the current process." — default false.
  - With `allow_ctty=false` (the default `.{}`), opening `/dev/tty` **probes without
    stealing/acquiring** a controlling tty. So `openFileAbsolute("/dev/tty", .{})`
    is the correct, safe probe: success ⇒ a controlling tty already exists; failure
    ⇒ none. We must NOT set `allow_ctty=true`.
- `std.posix.isatty(handle: fd_t) bool` (posix.zig:3548) EXISTS but is the wrong tool:
  it tests whether a given fd is a tty, not whether the process has a controlling
  terminal. (stdin may be a pipe in an interactive shell.) Don't use it here.

### Testable factoring (mirrors S2's `cacheBase()`/dir-scoped pattern)
```zig
fn hasControllingTtyAt(path: []const u8) bool {          // module-private, testable
    var f = std.fs.openFileAbsolute(path, .{}) catch return false;  // read-only, allow_ctty=false
    f.close();
    return true;
}
pub fn hasControllingTty() bool { return hasControllingTtyAt("/dev/tty"); }
```
Unit-test `hasControllingTtyAt` with **absolute** paths (openFileAbsolute asserts
absolute): `/dev/null` (openable ⇒ true) and a bogus absolute path like
`/dev/tmux-2html-no-such-probe-xyz` (⇒ false). Both are deterministic in any
environment. (`hasControllingTty()` itself is env-dependent — in CI there is no
controlling tty ⇒ false; interactively ⇒ true — so only assert it returns a bool +
equals `hasControllingTtyAt("/dev/tty")`, proving it doesn't panic.)

## 4. Path/dir helpers (verified, identical to S2's usage)

- `std.fs.path.dirname(path: []const u8) ?[]const u8` (path.zig:845) — **nullable**;
  returns null for a path with no directory component. Always handle the null.
- `std.fs.path.basename(path: []const u8) []const u8` (path.zig:979, cited in S2).
- `std.fs.openDirAbsolute(dir_path: []const u8, flags: Dir.OpenOptions) File.OpenError!Dir`
  (fs.zig:243) — fails with `error.FileNotFound` if the dir doesn't exist (e.g. cache
  never written). resolve() catches that and falls back to the cacheless path.

## 5. NO setenv in Zig std → env-mutation testing is impossible cleanly

Confirmed: `grep -rn "pub fn setenv" std/posix.zig std/process*` ⇒ **nothing**. Zig
0.15.2 std does not expose `setenv`/`unsetenv`. So the S3 tests **cannot** point
`XDG_CACHE_HOME` at a tmpdir by mutating process env. (S2 reached the same conclusion
for `cachePath` and instead extracted a `cacheBase()` helper + dir-scoped fns.)

**Consequence / decision:** make resolve's cache attempt dir-scoped too — a private
`resolveDir(dir, filename, allocator, mode, has_tty) Colors` that uses S2's
`loadCacheDir` for the cache source, and `queryColors` (real `/dev/tty`) for live.
Public `resolve()` just resolves the cache dir from `cachePath` and delegates; on any
dir-resolution failure it falls back to a tiny `resolveNoCache()`. Tests drive
`resolveDir` via `std.testing.tmpDir` + S2's `writeCacheDir` (exactly S2's pattern),
and only exercise `has_tty=false` (the `queryColors` branch needs a real tty and is
excluded from CI, exactly like S1's `queryColors` is compile-only in tests).

## 6. `Mode` enum — where does it live? (layering decision)

The item contract says resolve takes "a mode enum `{default, cached, live}` (or the
PRD `--palette MODE` string)". There is ALREADY a `cli.PaletteMode` (cli.zig) with the
same three fields. **Do NOT import cli.zig from palette.zig.** Rationale:
- `palette.zig` imports `ghostty-vt`; `cli.zig` imports only `parg`/`std` (it must stay
  ghostty-free — it's a pure parser). Making palette depend on cli would (a) invert the
  layering (cli is the interface layer; palette is the engine) and (b) pull parg into
  palette's graph.
- The two enums are intentionally separate: `cli.PaletteMode` is the *parsed* value
  (no ghostty); `palette.Mode` is the *engine* value (ghostty context). The renderer
  (P1.M3.T1.S3) **bridges** them with a 3-arm `switch`:
  ```zig
  const m: palette.Mode = switch (opts.palette_mode) {
      .default => .default, .cached => .cached, .live => .live,
  };
  const colors = palette.resolve(alloc, m, palette.hasControllingTty());
  ```
  (Do NOT use `@enumFromInt(@intFromEnum(...))` — relies on field order; the explicit
  switch is robust and self-documenting.)
- `palette.Mode` also gets a `fromStr` so it can be constructed from the raw `--palette`
  string too (the contract's "or the PRD `--palette MODE` string" path), mirroring
  `cli.PaletteMode.fromStr`.

## 7. Caller pattern (what P1.M3.T1.S3 / sync-palette / render will do)

```zig
// resolve is INFALLIBLE — returns Colors directly, swallows every error:
const colors: palette.Colors = palette.resolve(
    allocator,
    mode,                       // palette.Mode{ .default | .cached | .live }
    palette.hasControllingTty(),// false under tmux run-shell, in CI, behind pipes
);
// colors.palette / colors.foreground / colors.background are always usable
// (every branch bottoms out at defaultColors(), whose fg/bg are non-null).
```

## 8. Carry-over gotchas from S1/S2 (still in force)

- **GOTCHA (release=fast):** `zig build test` compiles ghostty-vt; the Debug linker
  hits `R_X86_64_PC64`. EVERY build/test command MUST include `--release=fast`.
- `queryColors` opens `/dev/tty` and ERRORS without a controlling tty (that's why
  resolve gates it on `has_tty`). Never call it unconditionally.
- `cachePath` errors on a missing `$HOME` (degenerate) — resolve catches that.
- `Colors` is a plain value type (~774 bytes); return it BY VALUE (no allocator
  ownership of the result). The allocator passed to resolve is only for the transient
  `cachePath` string and any `loadCache`/`queryColors` scratch — resolve frees them.

## 9. Why resolve() returns Colors, not !Colors

The item contract: "OUTPUT: a single `resolve()` callers use; never panics on missing
tty." So the signature is `pub fn resolve(allocator, mode, has_tty) Colors` — **no `!`**.
Internally it must `catch` every error from `cachePath`/`loadCacheDir`/`queryColors` and
route to the next source. This is the central behavioural requirement and the thing the
tests pin down (every branch yields a valid, default-bottomed Colors).
