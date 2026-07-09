# PRP — P1.M2.T1.S3: `palette.resolve()` precedence (cached → live → default)

## Goal

**Feature Goal**: Add the **precedence/resolution layer** to `src/palette.zig` (PRD §6) — the
final piece of the palette subsystem's T1 trio. Implement an **infallible**
`resolve(allocator, mode, has_tty) Colors` that selects the render palette by mode-specific
ordering (`cached` → live[only if a controlling tty] → `default`; `live` → live[only if tty]
→ `cached` → `default`; `default` → bundled defaults), and a `hasControllingTty() bool` that
probes `/dev/tty` read-only (the POSIX idiom: open fails with ENXIO when there is no
controlling terminal — i.e. the entire `run-shell` context, which is why the cache exists). It
**consumes** S1's `queryColors`/`defaultColors` and S2's `cachePath`/`loadCache` (+ the
module-private dir-scoped `loadCacheDir`), and is consumed by the renderer
(`--palette MODE`, P1.M3.T1.S3), `sync-palette` (P1.M2.T2.S1), and `pane`/`region`.

**Deliverable** (at `/home/dustin/projects/tmux-2html/`):
- **MODIFY `src/palette.zig`** — ADD to the existing file (S1 + S2 already define
  `Colors`/`defaultColors`/`queryColors`/`applyOscCommand` and `cachePath`/`writeCache`/
  `loadCache`/`loadCacheDir`): a `pub const Mode` enum (`default`/`cached`/`live` + `fromStr`),
  `pub fn hasControllingTty() bool`, `pub fn resolve(allocator, mode, has_tty) Colors`, the
  module-private dir-scoped `resolveDir`/`resolveNoCache`/`hasControllingTtyAt`/`liveOr`
  helpers, and ~7 new unit tests. Do NOT alter anything S1/S2 defined.
- **No new files. No docs.** `src/main.zig`, `build.zig`, `build.zig.zon`, `src/cli.zig`
  **UNCHANGED** — the top-level `test { _ = @import("palette.zig"); }` block already exists
  (added in S1), so new tests in palette.zig are auto-reachable from `zig build test`. (The
  item contract says DOCS: none — the cache is documented in S2's `docs/CONFIGURATION.md`, the
  `--palette` flag is documented in render's `--help`, already present in `src/cli.zig`.)

**Success Definition** (all VERIFIED against Zig 0.15.2 + cached ghostty 1.3.1):
- `zig build test --release=fast` → exit 0, all NEW resolve/tty tests pass **plus** S1 + S2
  tests still pass, no leaks under `std.testing.allocator`.
- `zig build --release=fast` → exit 0 (ghostty stays lazy on the exe path; no new imports).
- **Precedence correctness** (pinned by unit tests — see Validation):
  - `resolve(_, .default, _)` == `defaultColors()` **regardless of `has_tty` or cache state.**
  - `resolveDir(.cached, has_tty=false)` with a seeded tmpDir cache returns that **cache**; with
    **no** cache file it falls through to `defaultColors()` (live is skipped because
    `has_tty=false`).
  - `resolveDir(.live, has_tty=false)` with **no** cache returns `defaultColors()` (live skipped,
    cache absent); with a cache present it returns the **cache** (live skipped, cache hit).
  - `resolveDir(.live, has_tty=false)` with a cache present returns the **cache**, proving the
    `live`→`cached`→`default` ordering when live is unavailable.
- **Infallibility**: `resolve()` returns `Colors` (NOT `!Colors`) for every mode × `has_tty`
  combination; it never propagates an error and never panics (every `cachePath`/`loadCacheDir`/
  `queryColors` error is swallowed and routed to the next lower source, bottoming at `defaultColors()`).
- **Controlling-tty probe**: `hasControllingTtyAt("/dev/null") == true`;
  `hasControllingTtyAt("/dev/tmux-2html-no-such-probe") == false`; `hasControllingTty()` returns a
  bool and equals `hasControllingTtyAt("/dev/tty")` (proves no panic); uses `openFileAbsolute(.{})`
  which is read-only AND `allow_ctty=false` (default — never steals a controlling tty).

> **`--release=fast` is MANDATORY** on every build/test (Debug `R_X86_64_PC64` linker bug
> inherited from S1: the test path compiles ghostty-vt).

## User Persona

**Target User**: Downstream implementers — the renderer's `--palette MODE` (P1.M3.T1.S3), the
`sync-palette` body (P1.M2.T2.S1), and the `pane`/`region` subcommands — which call
`palette.resolve(mode, palette.hasControllingTty())` once to obtain the `Colors` to feed the
formatter. (End users never call `resolve` directly.)

**Use Case**: `render`/`pane` parse `--palette MODE` into `cli.PaletteMode`, bridge it to
`palette.Mode`, then call `palette.resolve(allocator, mode, palette.hasControllingTty())`. In a
tmux `run-shell` context (the plugin's `O`/visible bindings) `hasControllingTty()` is **false**
(no `/dev/tty`), so `resolve` uses the **cache** (populated once by the `display-popup`
auto-sync or an explicit `sync-palette`). Run interactively / inside a `display-popup`, the probe
is true and `live` (`queryColors`) captures the real terminal palette. `default` always yields the
bundled Ghostty palette.

**Pain Points Addressed**: One call site gets a usable palette in **every** context (interactive,
`display-popup`, or tty-less `run-shell`) without each caller re-implementing the
cached→live→default dance or knowing about `/dev/tty`. The tty probe guarantees `queryColors` is
**never** attempted where it would hang/fail (PRD §6: live "only when a controlling terminal
exists … never in `run-shell`").

## Why

- **Completes the palette subsystem's resolution contract (PRD §6).** S1 produced the *capture*
  (`queryColors`) and *defaults* (`defaultColors`); S2 produced the *store* (`loadCache`/`writeCache`);
  this task produces the *decision* — which source to use, in what order, gated by tty availability.
  The renderer cannot ship without it.
- **Isolates the tty-safety rule in ONE place.** PRD §6 + the item contract require `live`
  (`queryColors`) to be attempted **only** when a controlling tty exists. `resolve` enforces this via
  the `has_tty` parameter + `hasControllingTty()`; no caller can accidentally trigger a `/dev/tty`
  open from `run-shell`. (`queryColors` itself errors without a tty — `resolve` turns that error into
  a graceful fallback.)
- **Infallible by design.** Callers get `Colors`, never an error to handle — the renderer/pane/region
  code stays linear. Every failure mode (no `$HOME`, no cache file, no tty, terminal not responding)
  collapses to the bundled defaults, so rendering *always* produces output.
- **Faithful to the verified std API surface.** `openFileAbsolute("/dev/tty", .{})` (read-only,
  `allow_ctty=false` by default — File.zig:113), `openDirAbsolute`, `path.dirname` (nullable,
  path.zig:845) were read line-by-line from the cached Zig 0.15.2 source (citations in
  `research/findings.md`). No `setenv` in std ⇒ tests use S2's dir-scoped `loadCacheDir`/`writeCacheDir`
  via `std.testing.tmpDir` (same pattern S2 already established), never mutating process env.

## What

### Public API added to `src/palette.zig`

```zig
/// Palette source selection (PRD §6 precedence). Mirrors cli.PaletteMode's three
/// values but lives here so palette.zig does NOT import cli.zig (cli must stay
/// ghostty-free). The renderer bridges cli.PaletteMode -> Mode with a 3-arm switch.
pub const Mode = enum {
    default, // bundled Ghostty palette (defaultColors) — ignores cache + tty
    cached,  // loadCache, fall back to live(if tty) / default
    live,    // queryColors(if tty), fall back to cached / default

    pub fn fromStr(s: []const u8) ?Mode { /* "default"|"cached"|"live" -> ?Mode */ }
};

/// Does this process have a controlling terminal? Probes /dev/tty read-only
/// (openFileAbsolute(.{}) => mode=.read_only, allow_ctty=false). open() fails with
/// ENXIO when there is NO controlling tty (the tmux run-shell condition). Never
/// acquires a controlling tty; never panics.
pub fn hasControllingTty() bool;

/// Resolve the palette to render with (PRD §6 precedence). INFALLIBLE: returns
/// Colors (never !Colors), swallowing every cachePath/loadCache/queryColors error
/// and bottoming out at defaultColors(). `has_tty` is a parameter (not probed
/// internally) so callers pass palette.hasControllingTty() and tests can inject it.
pub fn resolve(allocator: std.mem.Allocator, mode: Mode, has_tty: bool) Colors;
```

### Precedence matrix (the contract, made exact)

| mode | step 1 | step 2 (on miss) | step 3 (on miss) |
|-------|----------------------|----------------------------------|--------------------|
| `default` | `defaultColors()` | (none — ignores cache & tty) | |
| `cached` | `loadCache` | `queryColors` **only if `has_tty`** | `defaultColors()` |
| `live` | `queryColors` **only if `has_tty`** | `loadCache` | `defaultColors()` |

> "miss" = the source errored (cache file absent / malformed-truncated-as-error, or
> `queryColors` failed because the tty didn't respond / none exists). Note `loadCache` already
> **tolerates partial files** (S2: seeds from `defaultColors`, only hard-errors on a malformed
> line) — so a *present* cache is treated as a hit even if incomplete.

### Success Criteria

- [ ] `pub const Mode` (+ `fromStr`) and `pub fn hasControllingTty`/`pub fn resolve` added to
      `src/palette.zig`; module-private `resolveDir`/`resolveNoCache`/`hasControllingTtyAt`/
      `liveOr` present.
- [ ] `src/main.zig`, `build.zig`, `build.zig.zon`, `src/cli.zig` **UNCHANGED**.
- [ ] `zig build test --release=fast` → exit 0; new resolve/tty tests + S1 + S2 tests pass; no leaks.
- [ ] `resolve` returns `Colors` (no `!`); every mode × `has_tty` yields a valid `Colors`.
- [ ] `resolve(_, .default, _)` == `defaultColors()` always.
- [ ] Precedence ordering verified via `resolveDir` + tmpDir (see Validation Level 3).
- [ ] `hasControllingTtyAt("/dev/null")==true`, `hasControllingTtyAt(<bogus>)==false`;
      `hasControllingTty()` == `hasControllingTtyAt("/dev/tty")`.

## All Needed Context

### Context Completeness Check

_Pass: "If someone knew nothing about this codebase, would they have everything needed to
implement this successfully?"_ — Yes. Every consumed S1/S2 signature (`queryColors(alloc)!Colors`,
`defaultColors() Colors`, `cachePath(alloc)![]u8`, `loadCacheDir(dir,name,alloc)!Colors`,
`writeCacheDir(dir,name,alloc,colors)!void`) is fixed by the S1/S2 PRPs (treat them as contracts).
Every new std API (`std.fs.openFileAbsolute(path, File.OpenFlags)` with `mode=.read_only` +
`allow_ctty=false` defaults at File.zig:94/113; `std.fs.openDirAbsolute` fs.zig:243;
`std.fs.path.dirname` nullable path.zig:845; `std.fs.path.basename` path.zig:979) was read
**directly from the cached Zig 0.15.2 source** with line citations in `research/findings.md`, and
the critical `/dev/tty` ENXIO-on-no-controlling-tty behavior + the `allow_ctty=false` default were
confirmed from File.zig source comments. No `setenv` exists in std (verified) ⇒ the tmpDir-based
test design is forced and correct. The precedence table is verbatim from PRD §6 + the item contract.

### Documentation & References

```yaml
# MUST READ — the file you are ADDING to (S1 + S2 already live here)
- file: src/palette.zig
  why: "ALREADY EXISTS with Colors/defaultColors/queryColors/applyOscCommand (S1) and
        cachePath/writeCache/loadCache/loadCacheDir/writeCacheDir/serialize/parse (S2). This task
        APPENDS a resolve section. Read it first to match doc-comment style, the ghostty_vt import
        aliases (color = ghostty_vt.color), and the module-level header comment."
  pattern: "queryColors(allocator) !Colors ERRORS without a controlling tty (it opens /dev/tty).
            loadCacheDir(dir, filename, allocator) !Colors is module-private (S2) — call it from
            resolveDir. cachePath(allocator) ![]u8 errors on missing $HOME (S2)."
  gotcha: "Do NOT touch anything S1/S2 defined. New pub fns + Mode enum + new tests append to the
           SAME file, in a clearly-marked '---- Resolve precedence ----' section."

# MUST READ — the consumed S2 contract (cachePath/loadCache/loadCacheDir/writeCacheDir signatures)
- file: plan/001_0c8587f91cb2/P1M2T1S2/PRP.md
  why: "S2 is IN PROGRESS in parallel. Treat its PRP as a contract: it WILL define
        pub cachePath(allocator) ![]u8, pub loadCache(allocator) !Colors, and module-private
        fn loadCacheDir(dir, filename, allocator) !Colors + fn writeCacheDir(dir, filename,
        allocator, colors) !void. resolveDir calls loadCacheDir; tests seed a tmpDir with
        writeCacheDir. Do NOT re-implement cache I/O — consume S2's helpers."
  critical: "loadCacheDir's tolerance: a PRESENT-but-partial cache is a HIT (seeded from
             defaultColors); loadCacheDir only hard-errors on a missing file or a malformed line.
             resolve treats any loadCacheDir SUCCESS as a cache hit."

# MUST READ — the consumed S1 contract (queryColors/defaultColors/Colors)
- file: plan/001_0c8587f91cb2/P1M2T1S1/PRP.md
  why: "S1 is COMPLETE. queryColors(allocator) !Colors opens /dev/tty and ERRORS without a
        controlling tty — that is exactly why resolve gates it on has_tty. defaultColors() Colors
        is the bottom-of-fallback. Colors is a value type (~774 B); return it by value."
  critical: "queryColors' error on no-tty is the designed signal resolve relies on. NEVER call
             queryColors unconditionally."

# MUST READ — the verified std API surface + tty-probe idiom (line citations)
- file: plan/001_0c8587f91cb2/P1M2T1S3/research/findings.md
  why: "§3 controlling-tty probe via openFileAbsolute(.{}) (read-only + allow_ctty=false default);
        §2 precedence matrix; §4 dirname nullable / openDirAbsolute error.FileNotFound;
        §5 NO setenv in std => tmpDir-based testing (mirrors S2); §6 Mode-enum layering (palette
        must NOT import cli); §8 carry-over --release=fast gotcha; §9 why resolve returns Colors."
  critical: "openFileAbsolute flags MUST be .{} (mode=.read_only AND allow_ctty=false). Setting
             allow_ctty=true would steal a controlling tty; setting mode=.read_write is unnecessary.
             Do NOT use std.posix.isatty (wrong tool — tests an fd, not controlling-tty presence)."

# MUST READ — PRD §6 precedence (the source of truth for the matrix)
- file: PRD.md
  section: "§6 Palette subsystem (Precedence for rendering)"
  why: "cached -> live(only when a controlling terminal exists; never in run-shell) -> default.
        default = Ghostty bundled palette. This task is the literal encoding of that list."
  critical: "The tty gate on 'live' is a hard PRD requirement, not a nice-to-have."

# Authoritative Zig 0.15.2 std (cached) — confirm any API doubt
- file: /home/dustin/.local/opt/zig-x86_64-linux-0.15.2/lib/std/fs.zig
  section: "openFileAbsolute (268) -> File.OpenError!File; openDirAbsolute (243) -> File.OpenError!Dir"
- file: /home/dustin/.local/opt/zig-x86_64-linux-0.15.2/lib/std/fs/File.zig
  section: "OpenFlags (93): mode: OpenMode = .read_only (94); allow_ctty: bool = false (113, default —
            'allow the opened file to automatically become the controlling TTY'). OpenMode enum (81):
            read_only/write_only/read_write."
- file: /home/dustin/.local/opt/zig-x86_64-linux-0.15.2/lib/std/fs/path.zig
  section: "dirname (845) -> ?[]const u8 (NULLABLE; null for no-dir path); basename (979); isAbsolute (277)"
- file: /home/dustin/.local/opt/zig-x86_64-linux-0.15.2/lib/std/posix.zig
  section: "isatty (3548) -> bool — EXISTS but is the WRONG tool (tests an fd); do not use for
            controlling-tty detection. (Cited only to document why we DON'T use it.)"
- file: /home/dustin/.local/opt/zig-x86_64-linux-0.15.2/lib/std/testing.zig
  section: "tmpDir (626) -> TmpDir{ .dir, .parent_dir, .sub_path }; TmpDir.cleanup() (618)"
```

### Current Codebase tree (this task's starting point)

```bash
tmux-2html/
├── build.zig            # T1.S2 (LAZY ghostty-vt)                                 ← DO NOT TOUCH
├── build.zig.zon        # T1.S1 (ghostty 1.3.1 + parg)                            ← DO NOT TOUCH
├── src/
│   ├── main.zig         # T3.S1 dispatch + tests; ALREADY has palette test block  ← DO NOT TOUCH
│   ├── palette.zig      # S1 (Colors/queryColors/defaultColors) + S2 (cache I/O)  ← ADD resolve layer
│   ├── cli.zig          # T3.S1/T3.S2 parg parser (defines cli.PaletteMode)       ← DO NOT TOUCH
│   ├── ghostty_format.zig # T2.S1 vendored formatter                              ← DO NOT TOUCH
│   └── .gitkeep
├── docs/CONFIGURATION.md # S2 cache docs (## Palette)                              ← DO NOT TOUCH
├── LICENSE  licenses/  scripts/  testdata/  tmux-2html.tmux   # stubs (unchanged)
├── PRD.md  .gitignore  plan/
└── ~/.cache/zig/p/ holds ghostty-1.3.1-... + parg-0.0.0-...  (already fetched)
```

### Desired Codebase tree with files to be changed

```bash
tmux-2html/
└── src/
    └── palette.zig      # + Mode enum + hasControllingTty + resolve
                         #   + resolveDir/resolveNoCache/hasControllingTtyAt/liveOr + ~7 tests
# build.zig  build.zig.zon  src/main.zig  src/cli.zig  docs/  # UNCHANGED
```

### Known Gotchas of our codebase & Library Quirks

```zig
// GOTCHA 1 — resolve() returns Colors, NOT !Colors. The item contract: "a single resolve()
//   callers use; never panics on missing tty." So signature: pub fn resolve(allocator,
//   mode, has_tty) Colors — NO '!'. Internally catch EVERY error from cachePath/loadCacheDir/
//   queryColors and route to the next source; bottom out at defaultColors(). A stray '!' in the
//   return type fails the Success Criterion and forces callers to handle errors they shouldn't.

// GOTCHA 2 — queryColors() ERRORS without a controlling tty (S1: it opens /dev/tty read_write).
//   That error is the DESIGNED signal resolve relies on for the live->cached->default fallback.
//   Never call queryColors unconditionally; gate it on has_tty (the parameter), and always
//   `catch` its result inside resolve so a non-responding terminal can't escape.

// GOTCHA 3 — hasControllingTty probe flags MUST be .{} (the default OpenFlags): mode=.read_only
//   AND allow_ctty=false (File.zig:113). openFileAbsolute("/dev/tty", .{}) is correct.
//   - Do NOT pass allow_ctty=true — it could make the opened file the controlling tty (side effect).
//   - Do NOT pass mode=.read_write — a read-only probe is enough and matches the contract.
//   - Do NOT use std.posix.isatty(fd) — it tests whether an fd is a tty, NOT whether the process
//     has a controlling terminal (stdin can be a pipe in an interactive shell => isatty false even
//     though a controlling tty exists). /dev/tty open is the POSIX-correct idiom.

// GOTCHA 4 — /dev/tty open with NO controlling terminal fails with ENXIO (Zig maps it into the
//   File.OpenError set). hasControllingTtyAt catches |_| => return false. That is the run-shell
//   condition (PRD §6 / architecture findings §3): run-shell children have $TMUX set but NO /dev/tty.
//   This is the ENTIRE reason the cache + resolve exist.

// GOTCHA 5 — NO setenv in Zig 0.15.2 std (verified: grep finds nothing). So tests CANNOT point
//   XDG_CACHE_HOME at a tmpdir by mutating process env. Solution (mirrors S2's dir-scoped pattern):
//   make the cache attempt dir-scoped — a private resolveDir(dir, filename, allocator, mode,
//   has_tty) that calls S2's loadCacheDir for the cache source. Tests drive resolveDir via
//   std.testing.tmpDir + S2's writeCacheDir. Public resolve() just resolves the dir from cachePath
//   and delegates; on cachePath/openDirAbsolute failure it calls resolveNoCache (cacheless
//   precedence). This is the ONLY way to test the cached/live ordering deterministically.

// GOTCHA 6 — only test resolveDir / resolve with has_tty=FALSE in CI. The has_tty=true branch
//   calls queryColors, which opens a REAL /dev/tty (needs an interactive terminal). In CI there is
//   no controlling tty, so queryColors would error — but we deliberately don't assert on the live
//   path at all; we assert the has_tty=false paths (cache hit, cache miss -> default) and the
//   default path, and verify hasControllingTty separately. Exactly like S1 leaves queryColors
//   compile-only in tests. (resolve with has_tty=true still must not PANIC — a smoke test that it
//   returns a valid Colors is fine, since the live error is swallowed -> falls through.)

// GOTCHA 7 — std.fs.path.dirname is NULLABLE (path.zig:845): returns ?[]const u8. A cache path
//   always has a dirname, but handle the null with `orelse` -> fall back to resolveNoCache. Do not
//   unwrap with `.` (compile error on optional) or `.?` (panic on the degenerate no-dir path).

// GOTCHA 8 (carried from S1/S2) — `zig build test` compiles ghostty-vt; the Debug linker hits
//   R_X86_64_PC64. ALWAYS pass --release=fast to every build/test command.

// GOTCHA 9 — palette.zig must NOT `@import("cli.zig")`. cli.zig is the ghostty-free parser layer
//   (imports only parg/std); palette.zig is the ghostty-aware engine layer. Importing cli would
//   invert the layering and pull parg into palette's graph. Define Mode LOCALLY in palette.zig (same
//   three fields as cli.PaletteMode). The renderer (P1.M3.T1.S3) bridges the two with a 3-arm switch.

// GOTCHA 10 — Colors is a value type (~774 B: [256]RGB=768 + 2 optionals + u16). resolve returns it
//   BY VALUE; the caller owes no deallocation. The allocator passed to resolve is only for the
//   transient cachePath string and any loadCacheDir/queryColors scratch — resolve frees the path
//   string itself (defer allocator.free(path)); loadCacheDir/queryColors own+free their own scratch.
```

## Implementation Blueprint

### Data models and structure

```zig
// No NEW data types beyond Mode. This task CONSUMES the existing Colors (S1) and the cache
// helpers (S2). Mode mirrors cli.PaletteMode but is defined here to keep palette.zig cli-free.
pub const Mode = enum {
    default,
    cached,
    live,

    pub fn fromStr(s: []const u8) ?Mode {
        if (std.mem.eql(u8, s, "default")) return .default;
        if (std.mem.eql(u8, s, "cached")) return .cached;
        if (std.mem.eql(u8, s, "live")) return .live;
        return null;
    }
};
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: ADD to src/palette.zig — `pub const Mode` enum + fromStr
  - IMPLEMENT Mode { default, cached, live } with fromStr(s) ?Mode matching cli.PaletteMode.fromStr
    ("default"/"cached"/"live" -> ?Mode; else null).
  - NAMING: pub const Mode; values lower_snake matching the enum style used elsewhere (PaletteMode
    in cli.zig uses the same three lowercase identifiers).
  - GOTCHA 9: define it LOCALLY; do NOT import cli.zig.
  - PLACEMENT: append in src/palette.zig in a clearly-marked "---- Resolve precedence ----" section,
    ABOVE the new tests (after S2's cache section).

Task 2: ADD hasControllingTty + hasControllingTtyAt  (the /dev/tty probe, Gotchas 3/4)
  - IMPLEMENT fn hasControllingTtyAt(path: []const u8) bool:
      var f = std.fs.openFileAbsolute(path, .{}) catch return false;  // read-only, allow_ctty=false
      f.close();
      return true;
  - IMPLEMENT pub fn hasControllingTty() bool: return hasControllingTtyAt("/dev/tty");
  - GOTCHA 3: flags MUST be .{} (NOT .{ .mode = .read_write }, NOT allow_ctty=true).
  - NAMING: hasControllingTtyAt is module-private (fn); hasControllingTty is pub.
  - PLACEMENT: same "---- Resolve precedence ----" section.

Task 3: ADD resolveDir (dir-scoped precedence CORE — testable, Gotcha 5) + tiny helpers
  - IMPLEMENT fn liveOr(allocator, has_tty, fallback: Colors) Colors:
      if (!has_tty) return fallback;
      return queryColors(allocator) catch fallback;   // Gotcha 2: swallow queryColors errors
  - IMPLEMENT fn resolveDir(dir: std.fs.Dir, filename: []const u8, allocator, mode, has_tty) Colors:
      return switch (mode) {
          .default => defaultColors(),
          .cached => blk: {
              if (loadCacheDir(dir, filename, allocator)) |c| break :blk c else |_| {}
              break :blk liveOr(allocator, has_tty, defaultColors());   // live(if tty) -> default
          },
          .live => blk: {
              if (has_tty) {
                  if (queryColors(allocator)) |c| break :blk c else |_| {}
              }
              if (loadCacheDir(dir, filename, allocator)) |c| break :blk c else |_| {}
              break :blk defaultColors();
          },
      };
  - CONSUMES: S2's loadCacheDir(dir, filename, allocator) !Colors (cache source); S1's
    queryColors(allocator) !Colors (live source); S1's defaultColors() (fallback).
  - GOTCHA 1 + 2: resolveDir returns Colors (no '!'); every error swallowed via `else |_| {}`.
  - NAMING: module-private fn (tested directly because it's in the same file — same as S2's
    loadCacheDir/writeCacheDir).
  - PLACEMENT: same section.

Task 4: ADD resolveNoCache + public resolve  (dir resolution + cacheless fallback, Gotchas 1/7)
  - IMPLEMENT fn resolveNoCache(allocator, mode, has_tty) Colors:
      return switch (mode) {
          .default => defaultColors(),
          // No cache dir available: live(if tty) -> default. (cached/live collapse identically.)
          .cached, .live => liveOr(allocator, has_tty, defaultColors()),
      };
  - IMPLEMENT pub fn resolve(allocator: std.mem.Allocator, mode: Mode, has_tty: bool) Colors:
      const path = cachePath(allocator) catch return resolveNoCache(allocator, mode, has_tty);
      defer allocator.free(path);
      const dir_path = std.fs.path.dirname(path) orelse
          return resolveNoCache(allocator, mode, has_tty);   // Gotcha 7: nullable dirname
      var dir = std.fs.openDirAbsolute(dir_path, .{}) catch
          return resolveNoCache(allocator, mode, has_tty);   // dir missing => no cache
      defer dir.close();
      return resolveDir(dir, std.fs.path.basename(path), allocator, mode, has_tty);
  - CONSUMES: S2's cachePath(allocator) ![]u8. Uses std.fs.path.dirname (?[]const u8) + basename +
    openDirAbsolute (all verified, §4 of findings).
  - GOTCHA 1: returns Colors (NO '!'). GOTCHA 7: dirname handled with `orelse`.
  - NAMING: resolveNoCache module-private; resolve pub. resolve is the SINGLE entry callers use.
  - PLACEMENT: same section.

Task 5: ADD unit tests to src/palette.zig  (tmpDir + pure; NO real tty, NO env mutation, Gotchas 5/6)
  - TEST "Mode.fromStr: round-trips the three modes":
      fromStr("default")==.default; "cached"==.cached; "live"==.live; fromStr("neon")==null;
      fromStr("")==null.
  - TEST "hasControllingTtyAt: /dev/null openable -> true; bogus path -> false":
      try expect(hasControllingTtyAt("/dev/null") == true);
      try expect(hasControllingTtyAt("/dev/tmux-2html-no-such-probe-xyz") == false);
      (Both ABSOLUTE paths — openFileAbsolute asserts absolute.)
  - TEST "hasControllingTty: returns a bool, equals the /dev/tty probe (no panic)":
      const b = hasControllingTty();
      try expect(b == true or b == false);                 // env-dependent value; just prove no panic
      try expect(b == hasControllingTtyAt("/dev/tty"));    // same probe
  - TEST "resolve(.default, ...) == defaultColors() regardless of has_tty":
      const alloc = std.testing.allocator;
      try expectEqualColors(defaultColors(), resolve(alloc, .default, false));
      try expectEqualColors(defaultColors(), resolve(alloc, .default, true));
      (resolve(.default) never touches cache/tty — deterministic in any env.)
  - TEST "resolveDir(.cached, has_tty=false): cache HIT returns the cached Colors":
      var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
      const orig = someNonDefaultColors();                 // a Colors != defaultColors()
      try writeCacheDir(tmp.dir, "palette", alloc, orig);  // S2 helper seeds the tmpDir
      const got = resolveDir(tmp.dir, "palette", alloc, .cached, false);
      try expectEqualColors(orig, got);                    // cache hit -> exact cache
  - TEST "resolveDir(.cached, has_tty=false): cache MISS -> defaultColors (live skipped)":
      var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
      // NO writeCacheDir -> loadCacheDir errors -> live skipped (has_tty=false) -> default.
      const got = resolveDir(tmp.dir, "palette", alloc, .cached, false);
      try expectEqualColors(defaultColors(), got);
  - TEST "resolveDir(.live, has_tty=false): live skipped; cache HIT returns cache; MISS -> default":
      var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
      const orig = someNonDefaultColors();
      try writeCacheDir(tmp.dir, "palette", alloc, orig);
      try expectEqualColors(orig, resolveDir(tmp.dir, "palette", alloc, .live, false)); // cache hit
      var tmp2 = std.testing.tmpDir(.{}); defer tmp2.cleanup();
      try expectEqualColors(defaultColors(), resolveDir(tmp2.dir, "palette", alloc, .live, false));
  - TEST "resolveDir(.default, ...) == defaultColors() always (ignores cache + tty)":
      var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
      try writeCacheDir(tmp.dir, "palette", alloc, someNonDefaultColors());
      try expectEqualColors(defaultColors(), resolveDir(tmp.dir, "palette", alloc, .default, false));
  - (OPTIONAL smoke) "resolve never panics for any mode x has_tty" — loop all 6 combos, assert each
    returns a Colors whose foreground/background are non-null (every path bottoms at defaultColors,
    whose fg/bg are non-null). This guards Gotcha 1 + 2 without asserting env-dependent values.
  - HELPERS for the tests:
      fn someNonDefaultColors() Colors { var c = defaultColors(); c.background = .{.r=1,.g=2,.b=3};
        c.palette[0] = .{.r=9,.g=9,.b=9}; return c; }   // differs from default in bg + palette[0]
      fn expectEqualColors(a: Colors, b: Colors) !void { try expectEqual(a.palette, b.palette);
        try expectEqual(a.foreground, b.foreground); try expectEqual(a.background, b.background);
        try expectEqual(a.palette_received_count, b.palette_received_count); }
    (Some S1/S2 tests compare Colors fields directly; reuse the field-wise helper for clarity.
     expectEqual on [256]RGB arrays works — S1's tests already do expectEqual(color.default, c.palette).)
  - COVERAGE: Mode.fromStr; tty probe true/false + no-panic; default-always; cached hit/miss;
    live hit/miss(has_tty=false); default-ignores-cache. Uses std.testing.allocator + tmpDir;
    NO env mutation, NO real tty, NO leaks (writeCacheDir's allocations are internal; resolve frees
    its cachePath string).
  - PLACEMENT: append to the existing "---- Unit tests ----" section in palette.zig (or a new
    "---- Resolve tests ----" subsection right after).

Task 6: VALIDATE  (see Validation Loop — every command verified against this toolchain)
  - RUN: zig build test --release=fast      # new resolve/tty tests + S1 + S2 tests pass, no leaks
  - RUN: zig build --release=fast           # ghostty stays lazy; exe builds
  - RUN: git diff --stat src/main.zig build.zig build.zig.zon src/cli.zig docs/   # expect: unchanged
```

### Implementation Patterns & Key Details

```zig
// PATTERN: the /dev/tty controlling-terminal probe. openFileAbsolute(.{}) = read-only AND
// allow_ctty=false (defaults), so it never acquires a controlling tty. ENXIO on no-ctty => false.
fn hasControllingTtyAt(path: []const u8) bool {
    var f = std.fs.openFileAbsolute(path, .{}) catch return false;
    f.close();
    return true;
}
pub fn hasControllingTty() bool {
    return hasControllingTtyAt("/dev/tty");
}

// PATTERN: live-or-fallback. queryColors is ONLY attempted when has_tty; its error is swallowed.
fn liveOr(allocator: std.mem.Allocator, has_tty: bool, fallback: Colors) Colors {
    if (!has_tty) return fallback;
    return queryColors(allocator) catch fallback;
}

// PATTERN: the precedence core (dir-scoped so it's testable with tmpDir). Returns Colors (no '!').
fn resolveDir(dir: std.fs.Dir, filename: []const u8, allocator: std.mem.Allocator,
              mode: Mode, has_tty: bool) Colors {
    return switch (mode) {
        .default => defaultColors(),
        .cached => blk: {
            if (loadCacheDir(dir, filename, allocator)) |c| break :blk c else |_| {}
            break :blk liveOr(allocator, has_tty, defaultColors());
        },
        .live => blk: {
            if (has_tty) {
                if (queryColors(allocator)) |c| break :blk c else |_| {}
            }
            if (loadCacheDir(dir, filename, allocator)) |c| break :blk c else |_| {}
            break :blk defaultColors();
        },
    };
}

// PATTERN: public resolve — resolve the cache dir, delegate to resolveDir, fall back gracefully.
//   Infallible (returns Colors). Every cachePath/openDirAbsolute error -> cacheless precedence.
pub fn resolve(allocator: std.mem.Allocator, mode: Mode, has_tty: bool) Colors {
    const path = cachePath(allocator) catch return resolveNoCache(allocator, mode, has_tty);
    defer allocator.free(path);
    const dir_path = std.fs.path.dirname(path) orelse
        return resolveNoCache(allocator, mode, has_tty);
    var dir = std.fs.openDirAbsolute(dir_path, .{}) catch
        return resolveNoCache(allocator, mode, has_tty);
    defer dir.close();
    return resolveDir(dir, std.fs.path.basename(path), allocator, mode, has_tty);
}
fn resolveNoCache(allocator: std.mem.Allocator, mode: Mode, has_tty: bool) Colors {
    return switch (mode) {
        .default => defaultColors(),
        .cached, .live => liveOr(allocator, has_tty, defaultColors()),
    };
}
```

### Integration Points

```yaml
BUILD GRAPH:
  - consumes (unchanged): build.zig (LAZY ghostty-vt via exe.root_module.addImport),
    build.zig.zon, src/main.zig (test block already present from S1). src/cli.zig (parallel/complete
    — defines cli.PaletteMode; palette.zig does NOT import it). docs/CONFIGURATION.md (S2).
  - produces: additions to src/palette.zig (Mode + hasControllingTty + resolve + dir-scoped helpers).
  - next (P1.M3.T1.S3 renderer --palette): cli.parseRender -> RenderOpts.palette_mode (cli.PaletteMode);
              bridge to palette.Mode via a 3-arm switch; call
              palette.resolve(allocator, mode, palette.hasControllingTty()); feed the Colors to the
              formatter Options (palette/foreground/background).
  - next (P1.M2.T2.S1 sync-palette body): writes the cache via S2's writeCache; does NOT call resolve
              (it PRODUCES the cache, not consumes it). sync-palette's --from tty path calls queryColors
              directly (it always runs in a real pty via display-popup / interactively).
  - next (P2.M1.T2 / P3.M3.T1 pane & region wiring): same one-liner as the renderer.

CONFIG / ENV:
  - resolve reads XDG_CACHE_HOME / HOME indirectly via S2's cachePath (no new env vars).
  - hasControllingTty reads /dev/tty (no env). Returns false under tmux run-shell, in CI, behind pipes.

FILESYSTEM SURFACE:
  - resolve MAY open $XDG_CACHE_HOME/tmux-2html/ (read-only, via openDirAbsolute) + read …/palette.
    It NEVER writes. All open errors are tolerated (-> cacheless precedence).

TEST DISCOVERY:
  - New tests in palette.zig run via the EXISTING main.zig test-block import (no main.zig change).
  - tmpDir-based resolveDir tests use std.testing.tmpDir (throwaway .zig-cache/tmp/<rand>/); never
    touch the real $XDG_CACHE_HOME. Pure Mode.fromStr / hasControllingTtyAt tests touch no filesystem.

DOCUMENTATION:
  - NONE for this item (contract: DOCS none). The cache is documented in S2's docs/CONFIGURATION.md;
    the --palette flag is already documented in src/cli.zig's render_help ("default | cached | live
    (default: cached->live->default)"). Do not duplicate.

CALLER BRIDGE (documented for P1.M3.T1.S3 — NOT implemented here):
  - cli.PaletteMode -> palette.Mode: explicit 3-arm switch (NOT @enumFromInt/@intFromEnum — fragile).
  - const colors = palette.resolve(allocator, mode, palette.hasControllingTty());
```

## Validation Loop

> Re-run verbatim. EVERY build/test command MUST include `--release=fast` (Gotcha 8).

### Level 1: Syntax & Style (Immediate Feedback)

```bash
zig version            # MUST print: 0.15.2
zig build --fetch      # exit 0 (deps cached; instant)
```

### Level 2: Build + unit tests (PRIMARY gate)

```bash
# New resolve/tty tests + S1 + S2 palette tests + existing main/cli tests. No leaks.
zig build test --release=fast          # expect: all passed, exit 0

# Exe still builds; ghostty stays LAZY on the non-test path (no new imports).
zig build --release=fast               # expect: exit 0
ls -la zig-out/bin/tmux-2html          # expect: ELF binary exists

# If "unhandled relocation type R_X86_64_PC64" -> forgot --release=fast (Gotcha 8).
# If "expected type 'Colors', found '!Colors'" or a caller must handle an error -> resolve leaked a
#   '!' into its return type (Gotcha 1). Remove it; swallow errors internally.
# If "error: expected .* allow_ctty" / openFileAbsolute type mismatch -> passed non-.{} flags (Gotcha 3).
# If testing.allocator reports a leak -> forgot `defer allocator.free(path)` in resolve() (the cachePath
#   string). loadCacheDir/queryColors own their own scratch; resolve owns only `path`.
```

### Level 3: Behavior (the contract — precedence + infallibility + tty probe)

```bash
# The unit tests ARE the Level-3 gate (no real tty / real $XDG_CACHE_HOME in CI). They assert:
#   Mode.fromStr: default/cached/live round-trip; "neon"/"" -> null.
#   hasControllingTtyAt("/dev/null") == true; hasControllingTtyAt("/dev/tmux-2html-no-such-probe-xyz")
#     == false (proves the open-and-catch idiom + read-only/allow_ctty=false flags).
#   hasControllingTty() returns a bool AND == hasControllingTtyAt("/dev/tty") (no panic).
#   resolve(alloc, .default, false) == resolve(alloc, .default, true) == defaultColors() (default
#     ignores cache + tty — deterministic in any environment).
#   resolveDir(.cached, has_tty=false) + seeded tmpDir cache -> the EXACT cached Colors (cache HIT).
#   resolveDir(.cached, has_tty=false) + NO cache -> defaultColors() (live skipped: has_tty=false).
#   resolveDir(.live, has_tty=false) + cache -> the cache (live skipped, cache HIT — proves live->cached
#     ordering); resolveDir(.live, has_tty=false) + NO cache -> defaultColors().
#   resolveDir(.default, ...) + a present cache -> STILL defaultColors() (default ignores cache).
#   (Optional smoke) resolve over all 3 modes x {has_tty true,false} -> each returns Colors with
#     non-null foreground/background (infallible; bottoms at defaultColors).
zig build test --release=fast -- 2>&1 | tail    # confirm resolve/tty test names appear + pass
```

### Level 4: Scope boundary (Domain Validation)

```bash
# ONLY palette.zig changed; build files + main.zig + cli.zig + docs/ untouched.
git diff --stat build.zig build.zig.zon src/main.zig src/cli.zig docs/   # expect: no output (unchanged)
git diff --stat src/palette.zig                                          # expect: palette.zig modified (additions)

# ghostty stayed lazy for the exe (no new imports on the non-test path):
time zig build --release=fast 2>&1 | tail -1        # expect: well under a minute (cached)

# (Optional, interactive only — NOT in CI, requires a real controlling tty):
#   Once P1.M3.T1.S3 lands, `tmux-2html render --palette live` in a real terminal exercises the
#   has_tty=true branch end-to-end. Before then, resolve's live branch is compile-verified only
#   (exactly like S1's queryColors is compile-only in tests).
```

## Final Validation Checklist

### Technical Validation

- [ ] `zig version` prints `0.15.2`; `zig build --fetch` exits 0.
- [ ] `zig build test --release=fast` exits 0 (new resolve/tty tests + S1 + S2 + existing tests, no leaks).
- [ ] `zig build --release=fast` exits 0; `zig-out/bin/tmux-2html` produced.

### Feature Validation

- [ ] `resolve` returns `Colors` (NO `!`); never panics for any mode × `has_tty`.
- [ ] `resolve(_, .default, _)` == `defaultColors()` always (ignores cache + tty).
- [ ] Precedence: `resolveDir(.cached, false)` cache-hit → cache; cache-miss → defaultColors (live skipped).
- [ ] Precedence: `resolveDir(.live, false)` cache-hit → cache (live skipped); cache-miss → defaultColors.
- [ ] `hasControllingTty()` probes `/dev/tty` read-only (`openFileAbsolute(.{})`); returns false on no
      controlling tty (run-shell); never acquires a controlling tty (`allow_ctty=false`).
- [ ] `hasControllingTtyAt("/dev/null")==true`; bogus absolute path → false.
- [ ] `live`/`queryColors` is NEVER attempted when `has_tty=false` (PRD §6 tty gate).

### Code Quality Validation

- [ ] `resolve` swallows every `cachePath`/`loadCacheDir`/`queryColors` error internally (Gotcha 1/2).
- [ ] `hasControllingTtyAt` uses `openFileAbsolute(path, .{})` — read-only AND `allow_ctty=false` (Gotcha 3).
- [ ] `palette.zig` does NOT `@import("cli.zig")`; `Mode` is defined locally (Gotcha 9).
- [ ] `std.fs.path.dirname` result handled with `orelse` (nullable; Gotcha 7).
- [ ] resolve frees its `cachePath` string (`defer allocator.free(path)`); no leaks.
- [ ] `src/main.zig`, `build.zig`, `build.zig.zon`, `src/cli.zig`, `docs/` unchanged.
- [ ] Tests use `std.testing.tmpDir` (resolveDir) + pure fns (Mode.fromStr, hasControllingTtyAt); NO env
      mutation, NO real tty (Gotchas 5/6).

### Documentation & Deployment

- [ ] No new docs (contract: DOCS none). Cache docs live in S2's `docs/CONFIGURATION.md`; `--palette`
      flag already documented in `src/cli.zig` `render_help`.
- [ ] No new env vars (XDG_CACHE_HOME / HOME already standard via S2's cachePath).

---

## Anti-Patterns to Avoid

- ❌ Don't give `resolve` a `!Colors` return type — the contract demands an **infallible** `Colors`
  ("never panics on missing tty"). Swallow every `cachePath`/`loadCacheDir`/`queryColors` error
  internally and bottom out at `defaultColors()` (Gotcha 1).
- ❌ Don't call `queryColors` unconditionally or let its error escape — it ERRORS without a controlling
  tty (S1). Gate it on `has_tty` and `catch` it (Gotcha 2). That gate is the PRD §6 tty requirement.
- ❌ Don't probe the controlling tty with `std.posix.isatty(fd)` — it tests whether an fd is a tty, not
  whether the process has a controlling terminal (a piped stdin is non-tty even with a ctty). Use the
  `/dev/tty` open idiom (Gotcha 3).
- ❌ Don't pass anything but `.{}` to `openFileAbsolute` for the probe — `mode=.read_write` is
  unnecessary, and `allow_ctty=true` could steal a controlling tty. Defaults are correct (Gotcha 3).
- ❌ Don't try to test the cache path by mutating `XDG_CACHE_HOME` — Zig 0.15.2 std has NO `setenv`
  (verified). Use the dir-scoped `resolveDir` + `std.testing.tmpDir` + S2's `writeCacheDir`
  (Gotcha 5), exactly mirroring S2's own `loadCacheDir`/`writeCacheDir` test pattern.
- ❌ Don't write a test that exercises `resolveDir`/`resolve` with `has_tty=true` and asserts on the
  live value — `queryColors` needs a real tty and isn't available in CI. Assert the `has_tty=false`
  paths + the `default` path; leave the live branch compile-verified (like S1's queryColors) (Gotcha 6).
- ❌ Don't `@import("cli.zig")` from `palette.zig` to reuse `PaletteMode` — cli is the ghostty-free
  parser layer; palette is the ghostty-aware engine. Define `Mode` locally; the renderer bridges them
  with a 3-arm switch (Gotcha 9). Don't bridge with `@enumFromInt(@intFromEnum(...))` — field-order
  coupling; use the explicit switch.
- ❌ Don't unwrap `std.fs.path.dirname(path)` with `.?` — it's nullable (`?[]const u8`); use `orelse`
  and fall back to the cacheless precedence (Gotcha 7).
- ❌ Don't build/test WITHOUT `--release=fast` — palette.zig compiles ghostty-vt in the test path; Debug
  linking hits `R_X86_64_PC64` (Gotcha 8).
- ❌ Don't modify `build.zig`, `build.zig.zon`, `src/main.zig`, `src/cli.zig`, or `docs/` — the main.zig
  test block already reaches palette.zig (S1), and ghostty-vt is already a lazy import. This task only
  APPENDS a resolve section to palette.zig.
- ❌ Don't alter anything S1/S2 defined (`Colors`, `defaultColors`, `queryColors`, `applyOscCommand`,
  `cachePath`, `writeCache`, `loadCache`, `loadCacheDir`, `writeCacheDir`, `serialize`, `parse`, their
  tests). Resolve CONSUMES those; it must not redefine or break them.
- ❌ Don't have `resolve` allocate the `cachePath` string without freeing it — `cachePath` returns an
  owned `[]u8`; `defer allocator.free(path)` or `std.testing.allocator` reports a leak.

---

**Confidence Score: 9/10** for one-pass implementation success.

Every consumed S1/S2 signature (`queryColors(alloc)!Colors`, `defaultColors() Colors`,
`cachePath(alloc)![]u8`, `loadCacheDir(dir,name,alloc)!Colors`, `writeCacheDir(dir,name,alloc,colors)!void`)
is fixed by the S1/S2 PRPs (treated as contracts; S2 is being implemented in parallel but its PRP
pins these exact signatures). Every new Zig 0.15.2 std API was read line-by-line from the cached
source (citations in `research/findings.md`): `openFileAbsolute(path, File.OpenFlags)` with the
`mode=.read_only` + `allow_ctty=false` defaults confirmed at File.zig:94/113 (the comment "allow the
opened file to automatically become the controlling TTY" proves `.{}` is the correct, non-stealing
probe); `openDirAbsolute` (fs.zig:243); `path.dirname` nullable (path.zig:845); `path.basename`
(path.zig:979). The `/dev/tty` ENXIO-on-no-controlling-tty behavior is the documented POSIX idiom
(also called out in architecture findings §3 for the run-shell condition). The critical testing
constraint — NO `setenv` in std (verified) — forces and validates the dir-scoped `resolveDir` +
`std.testing.tmpDir` design, which mirrors S2's own established `loadCacheDir`/`writeCacheDir`
pattern. The precedence table is verbatim from PRD §6 + the item contract, and every branch is
pinned by a deterministic unit test (default-always, cached hit/miss, live hit/miss with
`has_tty=false`, tty-probe true/false). The only residual risk is the `has_tty=true`/live branch,
which is deliberately compile-only in CI (exactly like S1's `queryColors`) and exercised live only
once the renderer lands — its correctness is structurally guaranteed by the `if (has_tty)` gate and
the `queryColors(...) catch fallback` swallow, both of which ARE unit-tested in shape.
