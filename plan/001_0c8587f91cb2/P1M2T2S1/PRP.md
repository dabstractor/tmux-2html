# PRP — P1.M2.T2.S1: `sync-palette` command (`--from`, `--force`) → writeCache

## Goal

**Feature Goal**: Implement the **`tmux-2html sync-palette` subcommand body** (PRD §5.4 + §6) —
the user-facing command that captures a terminal palette and writes the cache. It consumes the
already-built pieces: `cli.SyncPaletteOpts{from, force}` (cli.zig, T3.S2 — DONE), and
`palette.queryColors` / `palette.writeCache` / cache I/O (palette.zig, T1.S1 + T1.S2 — DONE;
T1.S3 resolve is parallel and NOT consumed by this task). Behaviour: `--from tty` (default)
queries `/dev/tty` via OSC 4/10/11 and caches the result; `--from file PATH` imports a palette
from a plain-text file into the cache; `--force` re-acquires/overwrites even when a cache already
exists; without `--force`, an existing cache is left untouched (PRD §5.4: "re-query even if a
cache exists" ⇒ without force, no re-query when a cache exists). Prints a one-line summary;
exits `2` when the terminal can't be queried (no controlling tty), `1` for runtime/file errors,
`0` on success.

**Deliverable** (at `/home/dustin/projects/tmux-2html/`):
- **MODIFY `src/cli.zig`** — wire `syncPalette` to the body via an **injected function pointer**
  (`body: *const fn(Allocator, SyncPaletteOpts) anyerror!u8`); on successful parse it calls
  `body(allocator, opts)` instead of `return error.NotImplemented`. cli.zig stays ghostty-free.
- **MODIFY `src/main.zig`** — add `const palette = @import("palette.zig")`; change the
  `sync-palette` dispatch arm to pass a new `syncPaletteBody` fn; add `syncPaletteBody` (prod
  wrapper: resolve real cache dir, print summary), a dir-scoped **testable core**
  `syncPaletteDir` (acquire → decide → write → `{code, summary}`), the pure decision fn
  `shouldRun`, a `SyncResult` struct, and unit tests; **update** the existing dispatch test
  (drop the now-stale `sync-palette → NotImplemented` assertion).
- **MODIFY `src/palette.zig`** — ADD `pub fn loadColorsFile(allocator, path) !Colors`
  (open + read + `parse`; for `--from file`); make the dir-scoped cache helpers
  `loadCacheDir` / `writeCacheDir` **`pub`** (so the CLI core + tests do dir-scoped cache I/O
  via `std.testing.tmpDir`, never mutating the real `$XDG_CACHE_HOME`). Additive; placed in the
  cache I/O section (NOT where S3 appends `resolve` at the end ⇒ no merge conflict).
- **MODIFY `docs/CONFIGURATION.md`** — ADD a `### sync-palette` subsection (Mode A docs):
  flags, exit codes, partial-response warning, and the **in-tmux-vs-outer-terminal** palette
  caveat (PRD §6).

**Success Definition** (all VERIFIED against Zig 0.15.2 + cached ghostty 1.3.1):
- `zig build test --release=fast` → exit 0; new sync-palette tests + all S1/S2/S3 palette tests
  + existing cli tests pass; no leaks under `std.testing.allocator`.
- `zig build --release=fast` → exit 0; `zig-out/bin/tmux-2html` produced.
- `tmux-2html sync-palette --help` → prints help (unchanged), exit 0.
- `tmux-2html sync-palette` (interactive, real tty) → writes
  `${XDG_CACHE_HOME:-$HOME/.cache}/tmux-2html/palette`, prints
  `queried N/256 colors; cache at <path>`, exit 0. (Live tty verified manually, not in CI.)
- `tmux-2html sync-palette --from file <valid>` → writes cache from the file, prints
  `loaded N/256 colors; cache at <path>`, exit 0.
- `tmux-2html sync-palette` with an existing cache and no `--force` → prints
  `palette cache already exists at <path>; use --force to re-query`, exit 0, **does not** touch
  `/dev/tty`.
- `tmux-2html sync-palette --from tty` with no controlling tty → exit 2 (capture/target error).

> **`--release=fast` is MANDATORY** on every build/test. EMPIRICALLY VERIFIED: `zig build`
> (Debug) fails with `unhandled relocation type R_X86_64_PC64` (ghostty-vt is already compiled
> into the exe — `build.zig` registers `ghostty-vt` on `exe.root_module` unconditionally; the
> S1/S2/S3 "ghostty stays lazy on the exe path" note is INACTIVE). Adding
> `const palette = @import("palette.zig")` to main.zig does NOT newly pull ghostty in.

## User Persona

**Target User**: (1) End users who want their HTML captures to use the *real* terminal palette
(running `sync-palette` once inside tmux); (2) headless/CI users who seed the cache from a known
palette file (`--from file`); (3) the auto-sync on first plugin load (P2.M2.T1.S2) which spawns
`sync-palette` inside a `tmux display-popup` (a real pty).

**Use Case**: After installing tmux-2html, run `tmux-2html sync-palette` inside tmux. It queries
the palette tmux presents to panes (the one captures render against) and caches it. Subsequent
`render`/`pane` runs (P1.M3/P2) use `palette.resolve(...)` which reads that cache when no
controlling tty exists (the `run-shell` plugin flow). On a headless box, `sync-palette --from
file my-palette.txt` seeds the cache without needing a terminal.

**Pain Points Addressed**: One command produces/refreshes the palette cache; `--force` forces a
refresh; `--from file` works where no queryable terminal exists; the cache makes rendering
correct even from tty-less `run-shell` contexts.

## Why

- **Completes the palette subsystem's user-facing surface (PRD §5.4 + §6).** T1 produced the
  engine (query/cache/resolve); this task exposes it as the `sync-palette` command users (and the
  P2 auto-sync popup) actually run. Without it the cache is never populated and `resolve` always
  falls through to `default`.
- **Isolates the tty-using code path behind an explicit command.** `queryColors` opens `/dev/tty`
  and MUST NOT run from `run-shell` (no controlling tty). Only `sync-palette` (run interactively
  or inside a `display-popup`) and `render --palette live` invoke it. The cache + `resolve` are
  the tty-free path for everything else.
- **Decouples from S3.** The tty-presence signal is `queryColors`' own error (it opens `/dev/tty`
  read_write and errors on no controlling tty — the POSIX `ENXIO` idiom). This task does NOT call
  `palette.hasControllingTty()` (S3), so it does not depend on S3 landing first.
- **Testable by design.** The acquire→decide→write logic lives in a dir-scoped core
  (`syncPaletteDir`) driven by `std.testing.tmpDir`, so the `--from file` path and the
  cache-exists/`--force` decision are unit-tested in isolation; the tty path (real `/dev/tty`) is
  compile-verified + manually-exercised, exactly like S1 leaves `queryColors`.

## What

### Behaviour (the contract, made exact)

| invocation | acquire | write cache? | exit | summary (stdout) |
|---|---|---|---|---|
| `sync-palette` (no cache) | `queryColors` | yes | 0 | `queried N/256 colors; cache at <p>` |
| `sync-palette` (cache exists, no `--force`) | **skipped** | no | 0 | `palette cache already exists at <p>; use --force to re-query` |
| `sync-palette --force` | `queryColors` | yes (overwrite) | 0 | `queried N/256 colors; cache at <p>` |
| `sync-palette` (no `/dev/tty`) | `queryColors` errors | — | **2** | `error: cannot query terminal palette ...` |
| `sync-palette --from file P` (no cache) | `loadColorsFile(P)` | yes | 0 | `loaded N/256 colors; cache at <p>` |
| `sync-palette --from file P` (cache exists, no force) | **skipped** | no | 0 | `palette cache already exists at <p>; ...` |
| `sync-palette --from file P --force` | `loadColorsFile(P)` | yes | 0 | `loaded N/256 colors; cache at <p>` |
| `sync-palette --from file <missing/malformed>` | `loadColorsFile` errors | — | **1** | `error: cannot read palette file 'P'` |

**Decision function**: `shouldRun(cache_exists, force) = force or !cache_exists`. Acquire and
write happen together (both gated by `shouldRun`) — there is no point querying the tty just to
discard the result, and skipping acquire lets `sync-palette` succeed without a tty when a cache
is already present. (This is the sensible reading of PRD §5.4 "re-query even if a cache exists" ⇒
without `--force`, no re-query when a cache exists; the contract's "Unless cache exists AND not
`--force`, writeCache" is the write half of the same condition.)

**Partial response**: `queryColors` already logs `std.log.warn` for `palette_received_count < 256`
and seeds every missing index from `defaultColors()` (warn + backfill — the conventional choice).
`sync-palette` treats any successfully-returned `Colors` (including count 0) as WARN + WRITE +
exit 0 (literal contract: "palette_received_count<256 → warning"). Only a `queryColors` ERROR
(total failure: no `/dev/tty` / termios fails) is exit 2.

**Exit codes**: `0` success/skip · `1` runtime/file error (bad `--from file`, cache-path/`$HOME`
problem, write failure) · `2` capture/target error (`--from tty` and the terminal can't be
queried). PRD §5: "2 capture/target error"; contract point 4: "missing tty → exit 2".

### Success Criteria

- [ ] `cli.syncPalette` accepts an injected body fn pointer and calls it on successful parse
      (no more `error.NotImplemented` for sync-palette); cli.zig does NOT import palette/ghostty.
- [ ] `main.zig` adds `const palette = @import("palette.zig")`; dispatch wires `sync-palette` →
      `syncPaletteBody`; `syncPaletteBody` + dir-scoped `syncPaletteDir` + `shouldRun` +
      `SyncResult` present; the existing dispatch test no longer asserts NotImplemented for
      sync-palette.
- [ ] `palette.loadColorsFile(allocator, path) !Colors` present (pub); `loadCacheDir` /
      `writeCacheDir` are `pub`.
- [ ] `docs/CONFIGURATION.md` has a `### sync-palette` subsection with the caveat.
- [ ] `zig build test --release=fast` exits 0 (new tests + existing, no leaks).
- [ ] `zig build --release=fast` exits 0; `sync-palette --help` still works (exit 0).
- [ ] Behavior matrix above holds (tty path verified manually; file/skip paths via unit tests).

## All Needed Context

### Context Completeness Check

_Pass: "If someone knew nothing about this codebase, would they have everything needed to
implement this successfully?"_ — Yes. Every consumed signature is fixed by source/PRP-contract:
`cli.SyncPaletteOpts{from: PaletteSource, force: bool}` + `cli.parseSyncPalette` (read in
cli.zig); `palette.queryColors(alloc)!Colors`, `palette.cachePath(alloc)![]u8`,
`palette.writeCacheDir(dir,name,alloc,colors)!void`, `palette.loadCacheDir(dir,name,alloc)!Colors`,
`palette.parse(text)!Colors` (read in palette.zig). Every NEW Zig 0.15.2 std API
(`Dir.statFile`, `Dir.openFile`, `fs.cwd()`, `openFileAbsolute`, `Dir.makePath`,
`readToEndAlloc`, `path.isAbsolute/dirname/basename`, `Dir.writeFile`, `Dir.realpathAlloc`) was
verified line-by-line in the cached std source (citations in `research/findings.md`). The exit-code
mapping, partial-response handling, and docs-caveat wording were validated by external research
(`research/external.md`): warn+backfill is conventional (we already backfill via the
`defaultColors()` seed), `/dev/tty` open is the correct tty-presence test (queryColors' error is
the signal — no `isatty`), and the in-tmux caveat wording is verbatim-ready.

### Documentation & References

```yaml
# MUST READ — the file whose dispatch arm + body you are ADDING
- file: src/main.zig
  why: "dispatch() routes sync-palette -> cli.syncPalette (currently). run() maps
        error.NotImplemented -> exit 1. main.zig imports cli/parg/build_options; palette only in
        the test{} block. This task adds `const palette` on the exe path + the body fns."
  pattern: "dispatch is an if/else-if chain returning !u8. run() catches NotImplemented. The
            existing test 'dispatch routes known subcommand to cli stub' asserts NotImplemented
            for render AND sync-palette — you MUST drop the sync-palette assertion (it is now
            implemented)."
  gotcha: "Do NOT call the full dispatch('sync-palette') from a unit test after wiring — the body
           would open /dev/tty + write the real cache. Test the dir-scoped core (syncPaletteDir),
           not the prod dispatch path."

# MUST READ — the parse layer you wire through (body injected via fn pointer)
- file: src/cli.zig
  why: "syncPalette(allocator, args) !u8 currently does --help/parse/reportError then
        `return error.NotImplemented`. SyncPaletteOpts + PaletteSource + parseSyncPalette are
        pub; hasHelpFlag/reportError/sync_palette_help are module-private."
  pattern: "Change ONLY syncPalette: add a `body: *const fn(Allocator, SyncPaletteOpts) anyerror!u8`
            param; replace `return error.NotImplemented` with `return body(allocator, opts)`. Leave
            render/pane/region UNCHANGED (they still return NotImplemented)."
  gotcha: "cli.zig must stay ghostty-free — it must NOT @import palette/ghostty. The body is
           INJECTED from main.zig (which imports palette); cli just calls the fn pointer. The body
           fn in main.zig must declare its return type as `anyerror!u8` to EXACTLY match the
           pointer type (an inferred `!u8` may not coerce cleanly to a fn-pointer type)."

# MUST READ — the engine you consume + the 2 fns you make pub + loadColorsFile you add
- file: src/palette.zig
  why: "ALREADY HAS (S1+S2): Colors, defaultColors, queryColors(alloc)!Colors [errors on no tty],
        cachePath(alloc)![]u8 [NoHomeDirectory on missing $HOME], writeCache(alloc,colors)!void,
        loadCache(alloc)!Colors, and module-private loadCacheDir/writeCacheDir/parse. THIS TASK:
        add pub loadColorsFile(alloc, path)!Colors; flip loadCacheDir+writeCacheDir to pub."
  pattern: "loadColorsFile mirrors loadCache's read but for an arbitrary path: branch on
            path.isAbsolute -> openFileAbsolute vs cwd().openFile; readToEndAlloc(1<<20); return
            parse(text). Place it next to loadCache/writeCache in the cache I/O section."
  gotcha: "S3 (parallel) APPENDS a '---- Resolve precedence ----' section + tests at the END of
           palette.zig. Add loadColorsFile + the pub flips in the EXISTING cache I/O section
           (near loadCache/writeCache), NOT at the end, to avoid a textual merge conflict with S3.
           Do NOT touch any S1/S2/S3 symbol (Colors/defaultColors/queryColors/cachePath/
           loadCache/writeCache/parse/resolve/hasControllingTty/Mode) beyond the 2 pub flips."

# MUST READ — the consumed S1+S2 contracts (exact signatures, fixed)
- file: plan/001_0c8587f91cb2/P1M2T1S1/PRP.md
  why: "queryColors(allocator) !Colors opens /dev/tty read_write and ERRORS without a controlling
        tty — that error is the exit-2 signal sync-palette relies on. Colors is a value type
        (~774 B); return/handle by value."
- file: plan/001_0c8587f91cb2/P1M2T1S2/PRP.md
  why: "cachePath(allocator) ![]u8 = ${XDG_CACHE_HOME:-$HOME/.cache}/tmux-2html/palette (NoHomeDirectory
        if $HOME unset). writeCacheDir(dir,filename,allocator,colors)!void does atomic temp+rename
        (does NOT mkdir — caller ensures the dir exists). loadCacheDir(dir,filename,allocator)!Colors
        seeds from defaultColors, hard-errors only on missing file / malformed line."
- file: plan/001_0c8587f91cb2/P1M2T1S3/PRP.md
  why: "S3 is PARALLEL. It adds Mode/hasControllingTty/resolve at the END of palette.zig. This task
        does NOT consume resolve/hasControllingTty (queryColors' own error is the tty signal) and
        does NOT add at the end — so the two tasks do not collide. Treat S3 as contract only."

# MUST READ — research (verified std APIs + design decisions + external validation)
- file: plan/001_0c8587f91cb2/P1M2T2S1/research/findings.md
  why: "§2 consumed signatures; §3 build/ghostty facts (--release=fast MANDATORY for exe AND test;
        ghostty already on exe path); §4 verified std APIs with line citations; §5 exit-code /
        gating / partial-response design; §6 wiring decision (fn-pointer injection + dir-scoped
        core)."
- file: plan/001_0c8587f91cb2/P1M2T2S1/research/external.md
  why: "Validates exit codes (0/1/2 sound; document 2 in help), partial-response (warn+backfill is
        conventional — we backfill via defaultColors seed), /dev/tty detection (queryColors' error
        is correct; isatty(stdin) is wrong), and the in-tmux docs caveat wording (verbatim)."

# MUST READ — PRD §5.4 (sync-palette) + §6 (palette subsystem) = source of truth
- file: PRD.md
  section: "§5.4 sync-palette + §6 Palette subsystem"
  why: "--from tty|file PATH; --force re-query even if cache exists; exits non-zero if terminal
        doesn't respond; cache at ${XDG_CACHE_HOME:-$HOME/.cache}/tmux-2html/palette; document that
        sync-palette outside tmux captures the outer terminal palette."
  critical: "The tty gate ('live only when a controlling terminal exists; never in run-shell') is
             enforced by queryColors erroring on no-tty — sync-palette turns that into exit 2."

# Authoritative Zig 0.15.2 std (cached) — confirm any API doubt
- file: /home/dustin/.local/opt/zig-x86_64-linux-0.15.2/lib/std/fs/Dir.zig
  section: "statFile (2688) StatFileError!Stat [FileNotFound if missing]; openFile (818)
            File.OpenError!File; makePath (1175); writeFile (2470, WriteFileOptions{sub_path,data});
            realpathAlloc (1389) ![]u8; access (2485)."
- file: /home/dustin/.local/opt/zig-x86_64-linux-0.15.2/lib/std/fs.zig
  section: "cwd (220) -> Dir; openFileAbsolute (268)."
- file: /home/dustin/.local/opt/zig-x86_64-linux-0.15.2/lib/std/fs/File.zig
  section: "OpenFlags (93): mode=.read_only default => .{} = read-only; readToEndAlloc (809)
            (allocator, max_bytes) ![]u8."
- file: /home/dustin/.local/opt/zig-x86_64-linux-0.15.2/lib/std/fs/path.zig
  section: "isAbsolute (277) bool; dirname (845) ?[]const u8 (NULLABLE); basename (979) []const u8."
```

### Current Codebase tree (this task's starting point)

```bash
tmux-2html/
├── build.zig            # registers ghostty-vt on exe.root_module (ghostty already on exe path)  ← DO NOT TOUCH
├── build.zig.zon        # ghostty 1.3.1 + parg                                                       ← DO NOT TOUCH
├── src/
│   ├── main.zig         # dispatch + run + tests; imports cli only (palette in test{} only)        ← ADD palette import + body + wire + tests
│   ├── palette.zig      # S1 (Colors/queryColors/defaultColors) + S2 (cache I/O) [+S3 resolve]     ← ADD loadColorsFile; pub loadCacheDir/writeCacheDir
│   ├── cli.zig          # T3.S2 parg parser; syncPalette returns NotImplemented                     ← WIRE body via fn pointer
│   ├── ghostty_format.zig # T2.S1 vendored formatter (NOT imported on exe path)                    ← DO NOT TOUCH
│   └── .gitkeep
├── docs/CONFIGURATION.md # S2 cache docs (## Palette)                                                ← ADD ### sync-palette
├── LICENSE  licenses/  scripts/  testdata/  tmux-2html.tmux   # stubs                               ← DO NOT TOUCH
└── PRD.md  .gitignore  plan/
```

### Desired Codebase tree with files to be changed

```bash
tmux-2html/
├── src/
│   ├── cli.zig          # syncPalette: + body fn-pointer param; success -> body(allocator, opts)
│   ├── main.zig         # + const palette; dispatch arm -> cli.syncPalette(..., syncPaletteBody)
│   │                    #   + syncPaletteBody (prod) + syncPaletteDir (testable core) + shouldRun
│   │                    #   + SyncResult + unit tests; update existing dispatch test
│   └── palette.zig      # + pub fn loadColorsFile; loadCacheDir/writeCacheDir -> pub
└── docs/CONFIGURATION.md # + ### sync-palette (flags, exit codes, in-tmux caveat)
# build.zig  build.zig.zon  src/ghostty_format.zig  other docs  # UNCHANGED
```

### Known Gotchas of our codebase & Library Quirks

```zig
// GOTCHA 1 — `zig build` (Debug) FAILS with R_X86_64_PC64 (empirically verified). ghostty-vt is
//   ALREADY compiled into the exe (build.zig registers it on exe.root_module unconditionally).
//   So `--release=fast` is MANDATORY for BOTH `zig build` and `zig build test`. Adding
//   `const palette = @import("palette.zig")` to main.zig does NOT newly pull ghostty in.

// GOTCHA 2 — cli.zig MUST stay ghostty-free (S1/S2/S3 boundary). The sync-palette BODY needs
//   palette (queryColors/writeCache), so it CANNOT live in cli.zig. It lives in main.zig (the one
//   module allowed to import both cli and palette). Wire it via a FUNCTION POINTER injected into
//   cli.syncPalette — cli never imports palette; it just calls the injected fn. The body fn in
//   main.zig MUST declare `anyerror!u8` (NOT inferred `!u8`) so it exactly matches the pointer
//   type `*const fn(Allocator, SyncPaletteOpts) anyerror!u8`.

// GOTCHA 3 — queryColors(allocator) ERRORS without a controlling tty (S1: it opens /dev/tty
//   read_write; ENXIO when none). That error IS the exit-2 signal. Do NOT pre-check with
//   palette.hasControllingTty() (S3) — it would add an S3 dependency and a redundant probe.
//   Do NOT use std.posix.isatty(stdin) — wrong question (stdin can be a pipe while a controlling
//   tty exists). Catch queryColors' error in the body and map to exit 2.

// GOTCHA 4 — The existing main.zig test "dispatch routes known subcommand to cli stub" asserts
//   `expectError(error.NotImplemented, dispatch(allocator, "sync-palette", &.{}))`. After wiring,
//   dispatch('sync-palette') calls the body (queryColors) — NOT NotImplemented. You MUST drop the
//   sync-palette assertion (keep render/pane/region). NEVER add a test that drives the full
//   dispatch('sync-palette') path: in an interactive env it would open the REAL /dev/tty, set raw
//   termios, send OSC queries, and write the REAL cache. Test the dir-scoped core instead.

// GOTCHA 5 — NO setenv in Zig 0.15.2 std (verified in S3). Tests CANNOT redirect XDG_CACHE_HOME.
//   So the testable core (syncPaletteDir) takes a std.fs.Dir + filename (dir-scoped), driven by
//   std.testing.tmpDir — exactly mirroring S2's loadCacheDir/writeCacheDir test pattern. The prod
//   wrapper (syncPaletteBody) resolves the real cache dir via palette.cachePath and delegates.

// GOTCHA 6 — writeCacheDir does NOT mkdir its parent (S2: writeCache does the makePath; the
//   dir-scoped helper assumes the dir exists). syncPaletteBody MUST makePath(cacheDir) before
//   openDirAbsolute + writeCacheDir. In tests, std.testing.tmpDir already exists, so the core
//   does NOT makePath (the caller owns dir creation). Keep makePath in syncPaletteBody only.

// GOTCHA 7 — std.fs.path.dirname is NULLABLE (?[]const u8). cachePath always yields a path with a
//   dirname, but handle null with `orelse { ...return 1; }` (do NOT `.?` — panic on degenerate).

// GOTCHA 8 — loadColorsFile must accept RELATIVE or ABSOLUTE paths (a user-supplied --from file
//   PATH). Branch on std.fs.path.isAbsolute(path): absolute -> openFileAbsolute(path, .{}),
//   relative -> std.fs.cwd().openFile(path, .{}). Both use OpenFlags .{} = read-only. readToEndAlloc
//   with max 1<<20 (same cap as loadCacheDir). Then return parse(text) (MalformedLine propagates).

// GOTCHA 9 — The summary string is allocator-owned ([]u8). syncPaletteDir returns SyncResult
//   { code, summary }; the caller (syncPaletteBody) prints summary to stdout then
//   `defer allocator.free(result.summary)`. Every early-return error path in syncPaletteDir ALSO
//   allocates a summary (so the field is always non-null); free it uniformly. std.testing.allocator
//   will report a leak if any summary is dropped.

// GOTCHA 10 — palette.zig S3 (parallel) APPENDS at the END (resolve section + tests). Add
//   loadColorsFile + the pub flips in the EXISTING cache I/O section (near loadCache/writeCache),
//   NOT at the file end, to avoid colliding with S3's append. Do not reorder existing code.

// GOTCHA 11 — `cli.SyncPaletteOpts.from` is `PaletteSource = union(enum){ tty, file: []const u8 }`.
//   Switch on it: `.tty => queryColors`, `.file => |path| loadColorsFile(path)`. The parsed `path`
//   slice points into the process argv (caller-owned, lives for the process) — no copy needed.
```

## Implementation Blueprint

### Data models and structure

```zig
// ---- main.zig (new) ----
const palette = @import("palette.zig"); // exe path now needs palette (sync-palette runs queryColors)

/// Result of the dir-scoped sync core: an exit code + an allocator-owned summary line.
const SyncResult = struct { code: u8, summary: []u8 };

/// Decision: do we acquire+write? PRD §5.4 "--force re-query even if a cache exists" =>
/// without force, skip when a cache already exists. Pure (unit-tested).
fn shouldRun(cache_exists: bool, force: bool) bool {
    return force or !cache_exists;
}

// ---- palette.zig (new) ----
/// Read + parse a palette file at an arbitrary path (`--from file PATH` source). Relative paths
/// resolve against cwd; absolute paths via openFileAbsolute. Same plain-text format as the cache.
/// Propagates open errors (FileNotFound) and MalformedLine.
pub fn loadColorsFile(allocator: std.mem.Allocator, path: []const u8) !Colors {
    var f = if (std.fs.path.isAbsolute(path))
        try std.fs.openFileAbsolute(path, .{})
    else
        try std.fs.cwd().openFile(path, .{});
    defer f.close();
    const text = try f.readToEndAlloc(allocator, 1 << 20);
    defer allocator.free(text);
    return parse(text);
}
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: MODIFY src/palette.zig — add pub loadColorsFile + flip loadCacheDir/writeCacheDir to pub
  - ADD pub fn loadColorsFile(allocator: std.mem.Allocator, path: []const u8) !Colors per Blueprint
    (isAbsolute branch -> openFileAbsolute vs cwd().openFile; readToEndAlloc(1<<20); parse(text)).
  - CHANGE `fn loadCacheDir(...)` -> `pub fn loadCacheDir(...)` and `fn writeCacheDir(...)` ->
    `pub fn writeCacheDir(...)` (add the `pub` keyword ONLY; signatures/bodies unchanged).
  - CONSUMES: existing private parse(text) !Colors (do NOT re-implement parsing).
  - PLACEMENT: in the EXISTING cache I/O section (right after loadCache/writeCache), NOT at the
    file end (S3 appends resolve there). 
  - GOTCHA 8, 10: isAbsolute branch; do not collide with S3's end-of-file append.
  - DO NOT touch Colors/defaultColors/queryColors/cachePath/loadCache/writeCache/parse/applyOscCommand
    or anything S3 defines (Mode/hasControllingTty/resolve).

Task 2: MODIFY src/cli.zig — inject the body fn pointer into syncPalette
  - CHANGE pub fn syncPalette to:
      pub fn syncPalette(
          allocator: std.mem.Allocator,
          args: []const []const u8,
          body: *const fn (std.mem.Allocator, SyncPaletteOpts) anyerror!u8,
      ) !u8
  - KEEP its body: hasHelpFlag -> print sync_palette_help + return 0; parseSyncPalette catch ->
    reportError + return 1. REPLACE the `_ = opts; return error.NotImplemented;` tail with
    `return body(allocator, opts);`.
  - GOTCHA 2: cli.zig stays ghostty-free; body is injected, never imported. Leave
    render/pane/region UNCHANGED (still return error.NotImplemented).
  - NAMING: the param is `body` (a fn pointer). No new pub types required.

Task 3: MODIFY src/main.zig — add palette import, wire dispatch, add the body + testable core + tests
  - ADD at top (next to `const cli = @import("cli.zig");`): `const palette = @import("palette.zig");`
  - CHANGE the dispatch arm: `} else if (std.mem.eql(u8, name, "sync-palette")) {`
        `return cli.syncPalette(allocator, sub_args, syncPaletteBody);` (was: cli.syncPalette(allocator, sub_args))
  - ADD SyncResult struct + shouldRun (pure) per Blueprint.
  - ADD fn syncPaletteDir(allocator, opts, cache_dir, cache_filename, cache_display_path) anyerror!SyncResult
        per the Implementation Patterns block below (the dir-scoped testable core).
  - ADD fn syncPaletteBody(allocator, opts) anyerror!u8 per Blueprint: resolve cachePath, makePath
        parent, openDirAbsolute, delegate to syncPaletteDir, print summary+\n, free summary, return code.
        Map cachePath/dirname/openDir failures to exit 1 with an inline stderr/stdout message.
  - UPDATE the existing test "dispatch routes known subcommand to cli stub": REMOVE the
        `expectError(error.NotImplemented, dispatch(allocator, "sync-palette", &.{}))` line; keep
        the render assertion (still NotImplemented). (GOTCHA 4)
  - ADD unit tests (see Task 5).
  - GOTCHA 1,2,3,4,5,6,7,9: --release=fast; anyerror!u8 on body; queryColors error -> exit 2; drop
        stale assertion; tmpDir core; makePath in wrapper only; nullable dirname; free every summary.

Task 4: MODIFY docs/CONFIGURATION.md — add ### sync-palette subsection
  - ADD a `### sync-palette` subsection under `## Palette` covering: what it does; --from tty
        (default) / --from file PATH; --force; the exit codes (0/1/2); partial-response warning;
        and the in-tmux-vs-outer-terminal caveat (use the verbatim wording from research/external.md).
  - KEEP the existing subsections (Cache location, Format, How it is populated, How it is consumed,
        Hand-editing). The "How it is populated" bullet already mentions sync-palette; the new
        subsection EXPANDS it with flags + the caveat. Do not duplicate the cache format.

Task 5: ADD unit tests (main.zig + palette.zig)
  main.zig tests (drive syncPaletteDir via std.testing.tmpDir; NEVER the tty path):
  - TEST "shouldRun: force or no-cache => true; cache+!force => false":
      shouldRun(false,false)==true; shouldRun(false,true)==true; shouldRun(true,true)==true;
      shouldRun(true,false)==false.
  - TEST "syncPaletteDir --from file writes cache when none exists":
      tmpDir; writeFile a source palette ("fg 1 2 3\nbg 4 5 6\n0 10 20 30\n"); realpathAlloc(".") ->
      join "source.txt" for an ABSOLUTE source path; opts.from=.{.file=source_abs}; force=false.
      result = syncPaletteDir(alloc, opts, tmp.dir, "palette", "/c/palette").
      expect code==0; summary contains "loaded" and "/256"; loadCacheDir(tmp.dir,"palette",alloc)
      => foreground.?.r==1, background.?.r==4, palette[0].r==10, palette_received_count==1.
  - TEST "syncPaletteDir --from file skips when cache exists and not --force":
      tmpDir; seed cache via writeCacheDir(tmp.dir,"palette",alloc, colorsA) where colorsA has a
      distinctive bg; writeFile source with DIFFERENT colors; opts.from=source, force=false.
      expect code==0; summary contains "already exists"; loadCacheDir => STILL colorsA (unchanged).
  - TEST "syncPaletteDir --from file --force overwrites an existing cache":
      tmpDir; seed colorsA; source has colorsB; force=true. expect code==0; loadCacheDir => colorsB.
  - TEST "syncPaletteDir --from file <missing> => exit 1":
      opts.from=.{.file="/tmp/tmux-2html-no-such-source-xyz"}; expect code==1; summary contains
      "cannot read palette file".
  - TEST "syncPaletteDir --from file <malformed> => exit 1":
      writeFile source "0 notanumber 0 0\n"; expect code==1 (parse MalformedLine -> loadColorsFile error).
  palette.zig tests (for the new pub fns):
  - TEST "loadColorsFile: absolute path round-trip (tmpDir + realpathAlloc)":
      tmpDir; writeFile "src.txt" with a known palette; realpathAlloc -> abs; loadColorsFile(abs)
      => expected fg/bg/palette[0]/count.
  - TEST "loadColorsFile: missing file errors": loadColorsFile("/tmp/...nope") => error.
  - TEST "loadColorsFile: relative path works": writeFile into a tmp cwd? (prefer absolute; if
      testing relative, chdir is unsafe — SKIP relative in CI, absolute path test is sufficient.)
  - (writeCacheDir/loadCacheDir disk round-trip is ALREADY tested by S2; no need to re-test.)
  - GOTCHA 4,5,9: no dispatch-driven tty test; tmpDir everywhere; free every result.summary.

Task 6: VALIDATE (see Validation Loop — every command verified against this toolchain)
  - RUN: zig build test --release=fast   # new tests + S1/S2/S3 palette + cli tests; no leaks
  - RUN: zig build --release=fast        # exe builds
  - RUN: ./zig-out/bin/tmux-2html sync-palette --help  # exit 0, help unchanged
  - RUN: git diff --stat build.zig build.zig.zon src/ghostty_format.zig  # expect: unchanged
```

### Implementation Patterns & Key Details

```zig
// PATTERN (cli.zig): inject the body so cli stays ghostty-free and keeps its --help/parse/report.
pub fn syncPalette(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    body: *const fn (std.mem.Allocator, SyncPaletteOpts) anyerror!u8,
) !u8 {
    if (hasHelpFlag(args)) {
        try write(std.fs.File.stdout(), sync_palette_help);
        return 0;
    }
    const opts = parseSyncPalette(args) catch |err| {
        try reportError("sync-palette", err);
        return 1;
    };
    return body(allocator, opts); // <-- was: return error.NotImplemented
}

// PATTERN (main.zig): the dir-scoped testable core. Returns {code, summary}; no stdout I/O.
//   cache_dir/cache_filename = where the cache lives (tmpDir in tests). cache_display_path is
//   only used to build the human-readable summary. The tty branch is NOT exercised in CI
//   (queryColors opens the real /dev/tty) — it is compile-verified + manually tested.
fn syncPaletteDir(
    allocator: std.mem.Allocator,
    opts: cli.SyncPaletteOpts,
    cache_dir: std.fs.Dir,
    cache_filename: []const u8,
    cache_display_path: []const u8,
) anyerror!SyncResult {
    // cache exists?
    const cache_exists = if (cache_dir.statFile(cache_filename)) |_| true else |_| false;

    // PRD §5.4: without --force, leave an existing cache untouched (skip acquire too).
    if (!shouldRun(cache_exists, opts.force)) {
        return .{ .code = 0, .summary = try std.fmt.allocPrint(allocator,
            "palette cache already exists at {s}; use --force to re-query", .{cache_display_path}) };
    }

    // Acquire Colors from the chosen source.
    var colors: palette.Colors = undefined;
    var label: []const u8 = "queried"; // tty
    switch (opts.from) {
        .tty => {
            colors = palette.queryColors(allocator) catch return .{ .code = 2, .summary =
                try std.fmt.allocPrint(allocator,
                    "error: cannot query terminal palette (no controlling tty or terminal unresponsive)", .{}) };
        },
        .file => |path| {
            label = "loaded";
            colors = palette.loadColorsFile(allocator, path) catch return .{ .code = 1, .summary =
                try std.fmt.allocPrint(allocator, "error: cannot read palette file '{s}'", .{path}) };
        },
    }

    // Write (atomic; caller ensured cache_dir exists).
    palette.writeCacheDir(cache_dir, cache_filename, allocator, colors) catch return .{ .code = 1,
        .summary = try std.fmt.allocPrint(allocator, "error: failed to write cache", .{}) };

    // Partial-response warning (queryColors also warns for tty; this covers the file path).
    if (colors.palette_received_count < 256) {
        std.log.warn("palette: only {d}/256 colors captured", .{colors.palette_received_count});
    }

    return .{ .code = 0, .summary = try std.fmt.allocPrint(allocator,
        "{s} {d}/256 colors; cache at {s}", .{ label, colors.palette_received_count, cache_display_path }) };
}

// PATTERN (main.zig): the prod wrapper — resolve the REAL cache dir, ensure it exists, delegate.
fn syncPaletteBody(allocator: std.mem.Allocator, opts: cli.SyncPaletteOpts) anyerror!u8 {
    const stdout = std.fs.File.stdout();
    const cache_path = palette.cachePath(allocator) catch {
        try stdout.writeAll("error: cannot determine cache directory (HOME unset)\n");
        return 1;
    };
    defer allocator.free(cache_path);
    const dir_path = std.fs.path.dirname(cache_path) orelse {
        try stdout.writeAll("error: invalid cache path\n");
        return 1; // GOTCHA 7: nullable dirname
    };
    std.fs.cwd().makePath(dir_path) catch {}; // GOTCHA 6: writeCacheDir needs the dir to exist
    var dir = std.fs.openDirAbsolute(dir_path, .{}) catch {
        try stdout.writeAll("error: cannot open cache directory\n");
        return 1;
    };
    defer dir.close();
    const result = try syncPaletteDir(allocator, opts, dir, std.fs.path.basename(cache_path), cache_path);
    defer allocator.free(result.summary); // GOTCHA 9: summary is allocator-owned
    try stdout.writeAll(result.summary);
    try stdout.writeAll("\n");
    return result.code;
}
```

### Integration Points

```yaml
BUILD GRAPH:
  - consumes (unchanged): build.zig (registers ghostty-vt on exe.root_module — already on exe path),
    build.zig.zon. main.zig now @imports palette.zig on the EXE path (palette was already compiled
    into the exe; this adds the import binding, not new ghostty compilation).
  - produces: wired sync-palette command (cli body injection + main.zig body + palette.loadColorsFile
    + pub loadCacheDir/writeCacheDir + docs).
  - next (P2.M2.T1.S2 auto-sync popup): spawns `tmux-2html sync-palette` inside a tmux display-popup
    (a real pty => queryColors works => cache populated once, then skipped while present).
  - next (P1.M3 renderer): reads the cache via palette.resolve(_, .cached, has_tty) — the cache this
    command writes. sync-palette does NOT call resolve (it PRODUCES the cache).

CONFIG / ENV:
  - syncPaletteBody reads XDG_CACHE_HOME / HOME via palette.cachePath (no new env vars).
  - The tty branch opens /dev/tty (via queryColors); only safe interactively / in a display-popup.

FILESYSTEM SURFACE:
  - Writes ${XDG_CACHE_HOME:-$HOME/.cache}/tmux-2html/palette (atomic temp+rename via writeCacheDir).
  - Reads an arbitrary --from file PATH (read-only). Never writes anywhere but the cache.

TEST DISCOVERY:
  - main.zig tests run via the existing top-level test blocks (no new test-root wiring). palette.zig
    tests run via the S1 main.zig `test { _ = @import("palette.zig"); }` block.
  - dir-scoped tests use std.testing.tmpDir; NO env mutation, NO real /dev/tty, NO real cache write.

DOCUMENTATION:
  - docs/CONFIGURATION.md gains ### sync-palette (Mode A). The cache format/location docs (S2) are
    unchanged. The --help text in cli.zig (sync_palette_help) already documents --from/--force; this
    task does NOT need to change --help (the exit-code line "0 success, 1 usage/runtime error" may
    optionally be extended to mention 2, but the top-level usage_text already states the full scheme).
```

## Validation Loop

> Re-run verbatim. EVERY build/test command MUST include `--release=fast` (Gotcha 1).

### Level 1: Syntax & Style (Immediate Feedback)

```bash
zig version            # MUST print: 0.15.2
zig build --fetch      # exit 0 (deps cached; instant)
```

### Level 2: Build + unit tests (PRIMARY gate)

```bash
# New sync-palette tests (main.zig + palette.zig) + S1/S2/S3 palette tests + cli tests. No leaks.
zig build test --release=fast          # expect: all passed, exit 0

# Exe builds (palette now on the exe path; ghostty already compiled in).
zig build --release=fast               # expect: exit 0
ls -la zig-out/bin/tmux-2html          # expect: ELF binary exists

# If "unhandled relocation type R_X86_64_PC64" -> forgot --release=fast (Gotcha 1).
# If "expected type '*const fn(...)...', found 'fn(...)' / inferred error set" -> the body fn's
#   return type is inferred `!u8`; declare it `anyerror!u8` to match the injected pointer (Gotcha 2).
# If testing.allocator reports a leak -> a SyncResult.summary was not freed, OR a tmpDir/allocPrint
#   result leaked. Every syncPaletteDir return path allocates a summary; the caller must free it.
# If the "dispatch routes known subcommand to cli stub" test fails on sync-palette -> you forgot to
#   drop the stale NotImplemented assertion (Gotcha 4).
```

### Level 3: Behavior — the contract (unit tests ARE the file/skip gate; tty is manual)

```bash
# The dir-scoped unit tests ARE the Level-3 gate for the file/skip/force paths. They assert:
#   shouldRun(false,false)=true; (false,true)=true; (true,true)=true; (true,false)=false.
#   --from file + no cache -> write; loadCacheDir matches source fg/bg/palette[0]/count; code 0.
#   --from file + cache + !force -> "already exists"; cache UNCHANGED; code 0.
#   --from file + cache + --force -> cache OVERWRITTEN; code 0.
#   --from file <missing> -> code 1 ("cannot read palette file").
#   --from file <malformed> -> code 1 (parse MalformedLine).
#   loadColorsFile(abs path) round-trip; missing -> error.
zig build test --release=fast -- 2>&1 | tail    # confirm sync-palette test names appear + pass
```

### Level 4: Manual / interactive (tty path — NOT in CI; run in a real terminal)

```bash
# sync-palette --help is deterministic (safe in CI):
./zig-out/bin/tmux-2html sync-palette --help    # expect: help text, exit 0

# (Interactive, real terminal — run by hand, NOT in the test suite):
rm -f "${XDG_CACHE_HOME:-$HOME/.cache}/tmux-2html/palette"
./zig-out/bin/tmux-2html sync-palette           # expect: "queried N/256 colors; cache at <path>", exit 0
cat "${XDG_CACHE_HOME:-$HOME/.cache}/tmux-2html/palette" | head   # expect: PRD §6 plain-text cache
./zig-out/bin/tmux-2html sync-palette           # 2nd run, cache exists, no --force -> "already exists", exit 0
./zig-out/bin/tmux-2html sync-palette --force   # -> "queried N/256 colors; cache at <path>", exit 0 (re-queried)

# --from file (headless import):
printf 'fg 1 2 3\nbg 4 5 6\n0 10 20 30\n' > /tmp/mypalette.txt
./zig-out/bin/tmux-2html sync-palette --from file /tmp/mypalette.txt --force
# expect: "loaded 1/256 colors; cache at <path>", exit 0; cache now has fg 1 2 3 / bg 4 5 6 / 0 10 20 30

# no controlling tty -> exit 2 (simulate: run detached from any tty, e.g. via setsid/nohup with stdin closed,
# or simply under `tmux run-shell` where /dev/tty is absent):
setsid -w ./zig-out/bin/tmux-2html sync-palette --force < /dev/null > /dev/null 2>&1; echo "exit: $?"
# expect: exit 2 (queryColors could not open /dev/tty). (Exact reproduction depends on the shell/env;
#         the unit-testable guarantee is: queryColors error -> code 2, verified structurally in the core.)
```

## Final Validation Checklist

### Technical Validation

- [ ] `zig version` prints `0.15.2`; `zig build --fetch` exits 0.
- [ ] `zig build test --release=fast` exits 0 (new sync-palette tests + S1/S2/S3 palette + cli tests, no leaks).
- [ ] `zig build --release=fast` exits 0; `zig-out/bin/tmux-2html` produced.
- [ ] `./zig-out/bin/tmux-2html sync-palette --help` exits 0 (help unchanged).

### Feature Validation

- [ ] `cli.syncPalette` takes an injected `body` fn pointer and calls `body(allocator, opts)` on
      successful parse (no more `error.NotImplemented` for sync-palette); cli.zig is ghostty-free.
- [ ] `--from tty` (default): queryColors → writeCache → `queried N/256 colors; cache at <p>`, exit 0.
- [ ] `--from file PATH`: loadColorsFile → writeCache → `loaded N/256 colors; cache at <p>`, exit 0.
- [ ] cache exists + not `--force`: skip acquire+write → `palette cache already exists …`, exit 0.
- [ ] `--force`: re-acquire + overwrite even when cache exists.
- [ ] `--from tty` with no controlling tty (queryColors error) → exit 2.
- [ ] `--from file` missing/malformed (loadColorsFile error) → exit 1.
- [ ] Partial response (count<256) → warning + cache still written + exit 0 (backfill via defaultColors).

### Code Quality Validation

- [ ] `syncPaletteBody` declares `anyerror!u8` (matches the injected pointer type; Gotcha 2).
- [ ] `syncPaletteDir` is dir-scoped (takes `std.fs.Dir`), returns `SyncResult`, does NO stdout I/O.
- [ ] `shouldRun` is pure (force or !cache_exists).
- [ ] `syncPaletteBody` makePath's the parent dir before openDirAbsolute+writeCacheDir (Gotcha 6).
- [ ] Every `SyncResult.summary` is freed by the caller (`defer allocator.free(result.summary)`; Gotcha 9).
- [ ] `palette.loadColorsFile` branches on `path.isAbsolute` (Gotcha 8); `loadCacheDir`/`writeCacheDir` are `pub`.
- [ ] `palette.zig` additions are in the cache I/O section (NOT the file end; Gotcha 10); no S1/S2/S3 symbol altered.
- [ ] The existing dispatch test drops the sync-palette NotImplemented assertion (Gotcha 4).
- [ ] `build.zig`, `build.zig.zon`, `src/ghostty_format.zig` unchanged.

### Documentation & Deployment

- [ ] `docs/CONFIGURATION.md` has a `### sync-palette` subsection: flags, exit codes, partial-response
      warning, and the in-tmux-vs-outer-terminal caveat (PRD §6).
- [ ] No new env vars (XDG_CACHE_HOME / HOME already used via palette.cachePath).

---

## Anti-Patterns to Avoid

- ❌ Don't put the sync-palette body in `cli.zig` — cli is the ghostty-free parser layer; the body
  needs `palette` (queryColors/writeCache). Put it in `main.zig` and inject it via a fn pointer
  (Gotcha 2). Don't `@import("palette.zig")` from `cli.zig`.
- ❌ Don't declare the body with an inferred `!u8` return and pass it where a
  `*const fn(...) anyerror!u8` is expected — declare the body as `anyerror!u8` explicitly so it
  matches the pointer type (Gotcha 2).
- ❌ Don't pre-check tty presence with `palette.hasControllingTty()` (S3) or `std.posix.isatty(stdin)`.
  `queryColors` already errors on no controlling tty — catch that error and map to exit 2 (Gotcha 3).
  This keeps the task decoupled from S3.
- ❌ Don't forget to drop the `sync-palette → NotImplemented` assertion in the existing dispatch test
  — after wiring, that path runs the body (queryColors), which would touch the real `/dev/tty` and
  write the real cache if driven from a test (Gotcha 4). Test the dir-scoped core, never the full
  dispatch path.
- ❌ Don't try to redirect `XDG_CACHE_HOME` in tests — Zig 0.15.2 std has NO `setenv` (Gotcha 5). Make
  the core dir-scoped (`syncPaletteDir(..., cache_dir, cache_filename, ...)`) and drive it with
  `std.testing.tmpDir`, exactly mirroring S2's `loadCacheDir`/`writeCacheDir` test pattern.
- ❌ Don't call `writeCacheDir` without ensuring its parent dir exists — the dir-scoped helper does NOT
  `makePath` (that's `writeCache`'s job). `syncPaletteBody` must `makePath` before `openDirAbsolute`
  (Gotcha 6). (In tests, `tmpDir` already exists.)
- ❌ Don't `try` to mutate process env or the real `$XDG_CACHE_HOME` from a unit test — use tmpDir.
- ❌ Don't append your `palette.zig` additions at the file END — S3 (parallel) appends its resolve
  section + tests there. Add `loadColorsFile` + the `pub` flips in the EXISTING cache I/O section to
  avoid a merge conflict (Gotcha 10).
- ❌ Don't re-implement palette parsing in `main.zig` — `palette.parse` (private) already decodes the
  PRD §6 format; expose it via the new `pub fn loadColorsFile` (which calls `parse`).
- ❌ Don't build/test WITHOUT `--release=fast` — Debug linking hits `R_X86_64_PC64` (Gotcha 1).
- ❌ Don't change `build.zig`, `build.zig.zon`, `src/ghostty_format.zig`, or the S1/S2/S3 palette
  symbols. This task is additive wiring (main.zig body + cli injection + 1 new pub fn + 2 pub flips
  + docs).
- ❌ Don't leak a `SyncResult.summary` — every return path of `syncPaletteDir` allocates one; the
  caller must `defer allocator.free(result.summary)` or `std.testing.allocator` reports a leak (Gotcha 9).
- ❌ Don't treat `palette_received_count < 256` as failure — partial palettes are normal; warn + write
  + exit 0 (the `defaultColors()` seed backfills missing indices). Only a `queryColors` ERROR is exit 2.

---

**Confidence Score: 9/10** for one-pass implementation success.

Every consumed signature is fixed by source/PRP-contract (read directly from `src/palette.zig` and
`src/cli.zig`): `cli.SyncPaletteOpts{from: PaletteSource, force: bool}` + `cli.parseSyncPalette`;
`palette.queryColors(alloc)!Colors` (errors on no tty — the exit-2 signal), `palette.cachePath(alloc)![]u8`,
`palette.writeCacheDir(dir,name,alloc,colors)!void`, `palette.loadCacheDir(dir,name,alloc)!Colors`,
`palette.parse(text)!Colors`. Every NEW Zig 0.15.2 std API was verified line-by-line in the cached
source (`Dir.statFile`:2688, `Dir.openFile`:818, `fs.cwd()`:220, `openFileAbsolute`:268,
`Dir.makePath`:1175, `File.readToEndAlloc`:809, `path.isAbsolute`:277 / `dirname`:845 (nullable) /
`basename`:979, `Dir.writeFile`:2470 / `WriteFileOptions`, `Dir.realpathAlloc`:1389). The build
behavior is empirically confirmed (`zig build` Debug fails R_X86_64_PC64; `--release=fast` succeeds;
ghostty already on the exe path). The exit-code mapping, partial-response handling, and docs-caveat
wording are validated by external research (warn+backfill is conventional and we already backfill via
`defaultColors()`; `/dev/tty` open is the correct tty test; the in-tmux caveat wording is verbatim-ready).
The only residual risk is the live `/dev/tty` path (`queryColors`), which is deliberately
compile-verified + manually-exercised (exactly like S1 leaves `queryColors`) — its error→exit-2
mapping and the file/skip/force decision are fully pinned by deterministic dir-scoped unit tests.
