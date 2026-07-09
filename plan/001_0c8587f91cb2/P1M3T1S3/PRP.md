# PRP — P1.M3.T1.S3: `--palette MODE` flag (cached→live→default via `palette.resolve`)

## Goal

**Feature Goal**: Wire the already-parsed `--palette default|cached|live` flag (PRD §5.1)
into `render.run` so rendering uses the palette resolved by `palette.resolve` (PRD §6
precedence: `cached→live→default`), instead of unconditionally using `defaultColors()`.
`--palette default` uses the Ghostty bundled palette; `--palette cached` reads the cache
(falling back to live-if-tty then default); `--palette live` queries `/dev/tty` only when a
controlling terminal exists.

**Deliverable**: `src/render.zig` MODIFIED — `run`'s `const colors = palette.defaultColors();`
line replaced with a `palette.resolve(alloc, …)` call, plus ONE private pure helper
`toPaletteMode(cli.PaletteMode) palette.Mode` (a 3-arm switch bridging the two enum types).
**No other source file changes** (cli.zig already parses + documents `--palette`; palette.zig
already implements `resolve`/`Mode`/`hasControllingTty`; main.zig exit plumbing is unchanged).

**Success Definition**:
- `render --palette default --cols 40` → HTML `background-color: #292c33` (Ghostty default bg),
  deterministic, no cache/tty dependency.
- `render --palette cached` with a seeded cache (`bg 1 2 3`) → HTML `background-color: #010203`
  (the cached bg).
- `render --palette cached` with NO cache + no controlling tty → `background-color: #292c33`
  (default fallback; `live` skipped because no tty).
- `render --palette live` with a seeded cache + no tty → `background-color: #050607` (the cached
  bg; proves `live` is skipped without a tty and the cache is the next source).
- Default invocation (no `--palette`) behaves identically to `--palette cached` (the struct default).
- `zig build -Doptimize=ReleaseFast` links; `zig build test -Doptimize=ReleaseFast` green
  (new bridge unit test + all S1/S2/palette/cli/main tests).

## Why

- S1's `run` left a `// S3: palette.resolve(alloc, mode, palette.hasControllingTty())` TODO on the
  `defaultColors()` call. S3 fulfills it. This is the final piece that makes `render` honor the
  PRD §6 palette subsystem (cache file + live OSC query + Ghostty defaults) end-to-end.
- Every downstream subcommand (`pane`, `region`) reuses `renderGrid` with colors from `resolve`, so
  S3 establishes the one palette-resolution call site all of P2/P3 will share.

## What

### User-visible behavior
- `render` selects its palette source from `--palette MODE` (default value: `cached`):
  - `default` — Ghostty bundled 256-color palette (`palette.defaultColors()`); ignores cache + tty.
  - `cached` — read `${XDG_CACHE_HOME:-$HOME/.cache}/tmux-2html/palette`; on miss, try `live` only
    if a controlling tty exists, else fall back to `default`.
  - `live` — query `/dev/tty` via OSC 4/10/11 ONLY when a controlling tty exists (never under
    `run-shell` / CI); on no-tty or query failure, fall back to `cached`, then `default`.
- All three modes are **infallible**: a missing cache or an unresponsive/absent tty never errors
  the render — they degrade gracefully to the next source, bottoming at the Ghostty defaults.
- Output bytes, exit codes (0/1/2), and all other flags are UNCHANGED vs S2.

### Success Criteria
- [ ] `toPaletteMode` maps `.default/.cached/.live` 1:1 (unit test, all three arms).
- [ ] `render --palette default --cols 40` emits `background-color: #292c33` (integration).
- [ ] `render --palette cached` + seeded `bg 1 2 3` cache emits `background-color: #010203` (integration).
- [ ] `render --palette cached` + empty cache + no tty (setsid) emits `background-color: #292c33`, exit 0 (integration).
- [ ] `render --palette live` + seeded `bg 5 6 7` cache + no tty (setsid) emits `background-color: #050607`, exit 0 (integration — proves live→cached ordering).
- [ ] `zig build -Doptimize=ReleaseFast` links; `zig build test -Doptimize=ReleaseFast` green.

## All Needed Context

### Context Completeness Check

_Passed._ A developer new to this repo implements S3 from: this PRP's **compile-validated** code
blocks (the bridge switch + resolve call shape were verified by an isolated `zig test` probe), the
exact `palette.resolve` signature (read from `src/palette.zig:545`, infallible — returns `Colors` not
`!Colors`), the deterministic HTML color anchors (verified against the current binary + formatter
source), and the working build/test gates (`-Doptimize=ReleaseFast`). The one environment trap
(Debug `zig build` fails to LINK under GCC 16 — not a code problem) is called out so the implementer
doesn't mistake it for a regression.

### Documentation & References

```yaml
# MUST READ — THIS task's research (every claim verified against the installed Zig 0.15.2 + binary)
- docfile: plan/001_0c8587f91cb2/P1M3T1S3/research/findings.md
  why: "The gap S3 closes, the resolve API surface, the type bridge (compile-validated probe), the
        exact call-site change, the ReleaseFast build caveat, deterministic color anchors, cache
        seeding, setsid no-tty trick, scope discipline, S2 ordering."
  section: "§0 gap, §1 resolve API, §2 bridge, §3 call-site, §4 build env, §5 anchors, §6 seeding"

# The PRD contract source
- docfile: plan/001_0c8587f91cb2/prd_snapshot.md
  why: "§6 Palette subsystem (precedence cached->live->default; live only when a tty exists) and
        §5.1 render (--palette MODE line). The exact precedence wording S3 implements."

# The sibling PRP that defines run()'s post-merge shape (S2 runs before S3)
- docfile: plan/001_0c8587f91cb2/P1M3T1S2/PRP.md
  why: "S2 REFINES run() (adds sizing/output/open). Its run() keeps the EXACT line S3 replaces:
        `const colors = palette.defaultColors(); // S3: palette.resolve(...)`. S3 must NOT touch
        S2's determineCols/renderToFileAtomic/spawnXdgOpen logic."
  section: "Implementation Patterns (the full refined run() — S3 edits ONLY the colors line)"

# Existing source files to FOLLOW / CONSUME (DO NOT EDIT)
- file: src/palette.zig
  why: "CONSUME (already Complete + tested): Mode enum (line 463), hasControllingTty() (491),
        resolve(allocator, mode, has_tty) Colors (545, INFALLIBLE), defaultColors() (28). resolve
        frees its own cachePath scratch; swallows all cache/tty errors; bottoms at defaultColors()."
  pattern: "resolve(allocator: std.mem.Allocator, mode: Mode, has_tty: bool) Colors — note it takes
            has_tty as a PARAMETER (caller passes palette.hasControllingTty()); resolve does NOT probe
            the tty itself (testability)."
  gotcha: "resolve returns Colors (NOT !Colors) — NO `try` at the call site. The contract snippet
           `palette.resolve(mode, palette.hasControllingTty())` OMITS the allocator; pass `alloc`."

- file: src/render.zig   # (S1 created it; S2 refines run(); S3 edits ONE line + adds ONE helper)
  why: "S3's baseline. run(alloc, opts: cli.RenderOpts) !u8 computes `colors` ONCE after the stdin
        read; that single value flows to every output arm. renderGrid + Size + S2's helpers are
        UNCHANGED."
  pattern: "run(): stdin.readToEndAlloc -> `const colors = <THIS LINE>;` -> sizing/output/open ->
            return u8. S3 swaps `<THIS LINE>` from defaultColors() to resolve()."
  gotcha: "Do NOT restructure run(); do NOT touch S2's sizing/output/open code; do NOT change
           renderGrid's signature. `sel: null` stays (S4 owns --selection)."

- file: src/cli.zig   # NOT EDITED
  why: "CONSUME: RenderOpts.palette_mode : PaletteMode = .cached (line 63); PaletteMode enum (25);
        parseRender already maps `--palette MODE` -> opts.palette_mode (167). render_help already
        documents `--palette MODE` (the contract's 'flag in help' is already satisfied)."
  gotcha: "cli.PaletteMode and palette.Mode are SEPARATE types by design (cli.zig must stay
           ghostty-free; palette.zig must not import cli.zig). They have identical variant names —
           bridge with a 3-arm switch in render.zig."

- file: src/main.zig   # NOT EDITED
  why: "Exit plumbing: the u8 from render.run flows to process exit unchanged. S3 adds no new
        exit code (resolve is infallible). The test block imports render.zig so render.zig's new
        bridge test is reachable."

# Formatter output format (for precise assertions)
- file: src/ghostty_format.zig   # NOT EDITED (vendored)
  why: "PageFormatter.formatWithState emits the <pre> header with LOWERCASE 2-digit hex:
        `background-color: #{x:0>2}{x:0>2}{x:0>2};`. defaultColors bg 41,44,51 -> #292c33."
  pattern: "<pre class=\"term2html-output\" style=\"max-width: {cols}ch; background-color: #...; ...\">"
```

### Current Codebase tree (S3's baseline = post-S2)

```bash
src/
├── main.zig            # dispatch + --version/--help; test root imports palette.zig + render.zig — CONSUME
├── cli.zig             # RenderOpts.palette_mode + parseRender + render_help ALL DONE — CONSUME, NOT EDITED
├── palette.zig         # Mode, hasControllingTty(), resolve(), defaultColors() ALL DONE — CONSUME, NOT EDITED
├── render.zig          # S1: renderGrid + Size + run; S2: sizing/output/open; S3: edits ONE line + adds helper
└── ghostty_format.zig  # VENDORED — DO NOT EDIT
build.zig / build.zig.zon   # .link_libc=false; ghostty(LAZY)+parg; min_zig 0.15.2 — NOT EDITED
```

### Desired Codebase tree (this task)

```bash
src/
├── render.zig          # MODIFIED: run()'s colors line -> palette.resolve(...); +toPaletteMode helper + test
└── (all other files unchanged)
```

### Known Gotchas of our codebase & Library Quirks

```zig
// CRITICAL — resolve is INFALLIBLE: `pub fn resolve(...) Colors` (palette.zig:545), NOT `!Colors`.
// Do NOT write `try palette.resolve(...)`. Assign directly: `const colors = palette.resolve(...);`.

// CRITICAL — resolve's REAL signature is (allocator, mode, has_tty). The item-contract snippet wrote
// `palette.resolve(mode, palette.hasControllingTty())` and OMITTED the allocator. Pass `alloc`:
//   palette.resolve(alloc, toPaletteMode(opts.palette_mode), palette.hasControllingTty())

// CRITICAL — cli.PaletteMode and palette.Mode are DISTINCT types (identical variant names). resolve
// takes palette.Mode; opts.palette_mode is cli.PaletteMode. Bridge with the 3-arm toPaletteMode switch.
// Do NOT use @intFromEnum/@enumFromInt (fragile to reordering); the switch is self-documenting + robust.

// CRITICAL (build env) — bare `zig build` and `zig build test` FAIL TO LINK under this machine's
// GCC 16 (fatal: unhandled relocation R_X86_64_PC64 in crt1.o:.sframe). This is a toolchain artifact,
// NOT a code error — compilation/type-checking succeeds. Use `-Doptimize=ReleaseFast` for BOTH build
// and test (those link + run cleanly). Do NOT mistake the Debug link error for a regression.

// resolve() probes NOTHING about the tty itself — it takes has_tty as a parameter so callers pass
// palette.hasControllingTty() and tests can inject it. Always pass palette.hasControllingTty() from run().

// Default background HTML = `background-color: #292c33` (41,44,51, lowercase hex). This is the
// deterministic anchor for `--palette default` AND the fallback for cached/live on miss+no-tty.

// `render --palette live` opens a REAL /dev/tty when a controlling tty exists (interactive use). It is
// never exercised in CI; under `setsid` (no controlling tty) it skips the query and falls to cache/default.
```

## Implementation Blueprint

### Data models and structure

```zig
// src/render.zig — NO new public types. S3 adds ONE private helper (the bridge).
// (renderGrid, Size, and S2's helpers stay exactly as their authors wrote them.)
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: MODIFY src/render.zig — ADD the type bridge (PURE, unit-tested)
  - IMPLEMENT: a PRIVATE fn bridging the two enums:
        fn toPaletteMode(m: cli.PaletteMode) palette.Mode {
            return switch (m) {
                .default => .default,
                .cached  => .cached,
                .live    => .live,
            };
        }
  - WHY: cli.PaletteMode (cli.zig:25) and palette.Mode (palette.zig:463) are distinct types with
      identical variant names; resolve takes palette.Mode. The S2 PRP prescribed this 3-arm switch.
  - COMPILE-VALIDATED: an isolated /tmp/s3probe (zig test) round-trips all three arms OK.
  - NAMING: toPaletteMode. PLACEMENT: render.zig (private, near run() or with the other private fns).
  - GOTCHA: a switch (not @intFromEnum/@enumFromInt) is robust to declaration reordering.

Task 2: MODIFY src/render.zig — SWAP the colors line in run() (the core change)
  - FIND the single line (exists in BOTH the S1 baseline and the S2-refined run(), right after the
      stdin `readToEndAlloc` + defer, before sizing):
        const colors = palette.defaultColors();
  - REPLACE with:
        const colors = palette.resolve(alloc, toPaletteMode(opts.palette_mode), palette.hasControllingTty());
  - DETAILS: `alloc` is run()'s first param; `opts.palette_mode` is cli.RenderOpts.palette_mode
      (default .cached); `palette.hasControllingTty()` is the tty gate (live is skipped when false).
  - GOTCHA: NO `try` — resolve returns Colors (infallible). The contract snippet omitted the allocator;
      the REAL signature is resolve(allocator, mode, has_tty) — pass `alloc` FIRST.
  - PRESERVE: every other line of run() (S2's determineCols/lineCount/renderToFileAtomic/tempHtmlPath/
      spawnXdgOpen, the three output arms, the `sel: null` arguments to renderGrid). S3 edits ONLY the
      colors line. renderGrid, Size, MAX_STDIN, and all existing tests are untouched.

Task 3: ADD a unit test for the bridge in src/render.zig (PURE; no tty, no stdin, no ghostty-vt init)
  - TEST "toPaletteMode: maps all three cli.PaletteMode variants to palette.Mode":
      expectEqual(palette.Mode.default, toPaletteMode(.default));
      expectEqual(palette.Mode.cached,  toPaletteMode(.cached));
      expectEqual(palette.Mode.live,    toPaletteMode(.live));
  - WHY: the bridge is the ONLY new logic in render.zig (resolve itself is already exhaustively tested
      in palette.zig's 7 resolve/resolveDir tests). Testing the bridge here is sufficient + cheap.
  - GOTCHA: this test does NOT call renderGrid and does NOT spawn ghostty-vt Terminal, so it does NOT
      collide with the S1 "single renderGrid test scope" GOTCHA (ghostty-vt corrupts cross-test global
      state). The bridge is a pure enum mapping — safe in any test scope.
  - NOTE: leave S1's renderGrid test and S2's helper/atomic tests exactly as they are; S3 only ADDS
      this one bridge test. main.zig's `test { _ = @import("render.zig"); }` already makes it reachable.
```

### Implementation Patterns & Key Details

```zig
// The ENTIRE substantive change in run(). Only the colors line moves; everything else is S2's, verbatim.
pub fn run(alloc: std.mem.Allocator, opts: cli.RenderOpts) !u8 {
    const stdin = std.fs.File.stdin();
    const ansi = try stdin.readToEndAlloc(alloc, MAX_STDIN); // S1/S2
    defer alloc.free(ansi);

    // ---- S3: the ONE changed line (was: palette.defaultColors()) ----
    const colors = palette.resolve(alloc, toPaletteMode(opts.palette_mode), palette.hasControllingTty());

    // ---- everything below is S2's (sizing + 3 output arms); UNCHANGED ----
    const cols = determineCols(opts.cols, palette.hasControllingTty()) catch |err| { ...; return 2; };
    const rows = opts.rows orelse lineCount(ansi);
    const size = Size{ .cols = cols, .rows = rows };
    // ... renderToFileAtomic / tempHtmlPath / stdout, all using `colors` ...
    return 0;
}

/// cli.PaletteMode -> palette.Mode bridge. The two enums are distinct types by design
/// (cli.zig stays ghostty-free; palette.zig must not import cli.zig) but share variant
/// names. resolve() takes palette.Mode; opts.palette_mode is cli.PaletteMode.
fn toPaletteMode(m: cli.PaletteMode) palette.Mode {
    return switch (m) {
        .default => .default,
        .cached => .cached,
        .live => .live,
    };
}
```

### Integration Points

```yaml
BUILD: none. build.zig unchanged. S3 introduces NO new imports (palette + cli already imported in
       render.zig). No platform-specific code (resolve/hasControllingTty already cross-compile).

CLI (src/cli.zig): NOT EDITED. parseRender already yields opts.palette_mode (default .cached);
       render_help already lists `--palette MODE` (contract's "flag in help" already satisfied).

MAIN (src/main.zig): NOT EDITED. resolve is infallible => no new exit code; the u8 from run() still
       flows to process exit unchanged. The test block already imports render.zig.

PALETTE (src/palette.zig): CONSUMED (resolve/Mode/hasControllingTty/defaultColors), NOT edited.

SCOPE: S3 changes only the colors line + adds toPaletteMode. Does NOT touch --selection (S4,
       sel: null stays), does NOT restructure run(), does NOT modify any other file.
```

## Validation Loop

> **Build-env caveat (read first):** On this machine (Zig 0.15.2 + GCC 16), bare `zig build`
> and bare `zig build test` FAIL TO LINK with `fatal: unhandled relocation R_X86_64_PC64 in
> crt1.o:.sframe`. That is a toolchain artifact, not a code error (compilation succeeds; only
> the final link fails). Use `-Doptimize=ReleaseFast` for both build and test — those link +
> run cleanly. Do not mistake the Debug link error for a regression from your change.

### Level 1: Syntax & Type (compile + cross-compile gate)

```bash
zig build -Doptimize=ReleaseFast
# Expected: success → zig-out/bin/tmux-2html. (This is the real compile+link gate in this env.)

# Cross-compile sanity (prove no new platform-only API leaked in; render.zig resolves modules):
zig build-obj src/render.zig -fno-emit-bin -target x86_64-macos 2>&1 | head
# Expected: no errors (EXIT 0). S3 adds no platform-specific code.
```

### Level 2: Unit Tests (the bridge; no tty/stdin/ghostty-vt)

```bash
zig build test -Doptimize=ReleaseFast
# Expected: all green — new toPaletteMode test + S1's renderGrid test + S2's helper/atomic tests
# + all palette/cli/main tests. No leak under std.testing.allocator.
# (resolve's own precedence is already covered by palette.zig's 7 resolve/resolveDir tests.)
```

### Level 3: Integration (the real CLI — deterministic, setsid for no-tty)

```bash
BIN="zig-out/bin/tmux-2html"

# (0) sanity: the binary exists from Level 1
test -x "$BIN" || { echo "build first"; exit 1; }

# (1) --palette default  =>  Ghostty default bg #292c33 (deterministic; no cache/tty dep)
printf '\033[31mred\033[0m' | "$BIN" render --cols 40 --palette default \
  | grep -o 'background-color: #292c33' && echo "default OK"

# (2) --palette cached + SEEDED cache (bg 1 2 3 => #010203)
TC=$(mktemp -d); mkdir -p "$TC/tmux-2html"
printf '# t\nbg 1 2 3\n' > "$TC/tmux-2html/palette"   # tolerant parser: bg-only file is valid
printf 'x' | XDG_CACHE_HOME="$TC" "$BIN" render --cols 40 --palette cached \
  | grep -o 'background-color: #010203' && echo "cached-hit OK"
rm -rf "$TC"

# (3) --palette cached + NO cache + NO tty (setsid)  =>  default fallback #292c33, exit 0
TC=$(mktemp -d)   # empty: no palette file
setsid bash -c "printf 'x' | XDG_CACHE_HOME='$TC' '$BIN' render --cols 40 --palette cached" \
  | grep -o 'background-color: #292c33' && echo "cached-miss->default OK"
rm -rf "$TC"

# (4) --palette live + SEEDED cache (bg 5 6 7 => #050607) + NO tty (setsid)
#     proves live is SKIPPED without a tty and the cache is the next source (live->cached->default)
TC=$(mktemp -d); mkdir -p "$TC/tmux-2html"
printf '# t\nbg 5 6 7\n' > "$TC/tmux-2html/palette"
setsid bash -c "printf 'x' | XDG_CACHE_HOME='$TC' '$BIN' render --cols 40 --palette live" \
  | grep -o 'background-color: #050607' && echo "live->cached(skip tty) OK"
rm -rf "$TC"

# (5) --palette live + NO cache + NO tty (setsid)  =>  default fallback #292c33, exit 0
TC=$(mktemp -d)
setsid bash -c "printf 'x' | XDG_CACHE_HOME='$TC' '$BIN' render --cols 40 --palette live; echo EXIT=\$?" \
  | grep -oE 'background-color: #292c33|EXIT=0'
rm -rf "$TC"

# (6) default (no --palette) behaves like --palette cached (struct default = .cached)
TC=$(mktemp -d); mkdir -p "$TC/tmux-2html"
printf '# t\nbg 1 2 3\n' > "$TC/tmux-2html/palette"
printf 'x' | XDG_CACHE_HOME="$TC" "$BIN" render --cols 40 \
  | grep -o 'background-color: #010203' && echo "default-flag == cached OK"
rm -rf "$TC"

# (7) bad mode is still rejected at parse time (cli.zig, unchanged) => exit 1, not a crash
printf 'x' | "$BIN" render --cols 40 --palette neon; echo "exit=$?"   # => 1
"$BIN" render --palette neon --cols 40 2>&1 | grep -o -- '--palette must be default|cached|live'
```

### Level 4: Regression (don't break S1/S2/palette/cli/main)

```bash
BIN="zig-out/bin/tmux-2html"
zig build test -Doptimize=ReleaseFast                                 # palette + cli + main + render tests green
"$BIN" render --help | grep -q -- '--palette MODE'                    # help surface intact (already listed)
printf '\033[31mred\033[0m' | "$BIN" render --cols 40 | grep -o '>red</span>'   # S1 stdout path intact
printf 'x' | "$BIN" render --cols 40 --output /tmp/t2h-s3.html && test -s /tmp/t2h-s3.html   # S2 --output intact
# Expected: all pass. The stdout path produces byte-identical output to S2 for --palette default
# (resolve(.default) == defaultColors() exactly).
```

## Final Validation Checklist

### Technical Validation
- [ ] `zig build -Doptimize=ReleaseFast` succeeds (links).
- [ ] `zig build-obj src/render.zig -fno-emit-bin -target x86_64-macos` succeeds (no new platform API).
- [ ] `zig build test -Doptimize=ReleaseFast` green (new bridge test; no allocator leak).

### Feature Validation
- [ ] `render --palette default` → `background-color: #292c33` (Level 3 #1).
- [ ] `render --palette cached` + seeded cache → `background-color: #010203` (Level 3 #2).
- [ ] `render --palette cached` + no cache + no tty → `background-color: #292c33`, exit 0 (Level 3 #3).
- [ ] `render --palette live` + seeded cache + no tty → `background-color: #050607` (Level 3 #4).
- [ ] `render --palette live` + no cache + no tty → `background-color: #292c33`, exit 0 (Level 3 #5).
- [ ] Default (no flag) == `--palette cached` (Level 3 #6).
- [ ] `--palette neon` rejected at parse time, exit 1 (Level 3 #7).

### Scope Discipline (RESPECT sibling tasks)
- [ ] Edited ONLY the `colors` line in `run()` + added `toPaletteMode`; touched NO other line of run().
- [ ] Did NOT modify `renderGrid`, `cli.zig`, `main.zig`, `palette.zig`, `ghostty_format.zig`,
      `build.zig`, or `build.zig.zon`.
- [ ] Did NOT implement `--selection` (S4) — `sel: null` everywhere.
- [ ] Did NOT add docs (help already lists `--palette MODE`; contract §5 satisfied).
- [ ] Did NOT regress S1's stdout path or S2's `--output`/`--open`/sizing.

### Code Quality
- [ ] `toPaletteMode` follows render.zig's private-helper convention (e.g. `renderToOwned`).
- [ ] resolve is called WITHOUT `try` (infallible); the allocator is passed first.
- [ ] DEBUG-style comments note the infallibility + the type-bridge rationale.

---

## Anti-Patterns to Avoid

- ❌ Don't write `try palette.resolve(...)` — it returns `Colors`, not `!Colors` (infallible by design).
- ❌ Don't omit the allocator — the contract snippet `palette.resolve(mode, hasControllingTty())` is
  shorthand; the real signature is `resolve(allocator, mode, has_tty)`. Pass `alloc` first.
- ❌ Don't bridge with `@intFromEnum`/`@enumFromInt` — fragile to reordering; use the explicit 3-arm switch.
- ❌ Don't restructure `run()` or touch S2's sizing/output/open code — S3 edits exactly the one `colors` line.
- ❌ Don't edit cli.zig/main.zig/palette.zig — the flag is parsed + documented, resolve is implemented + tested.
- ❌ Don't expand into S4 (`--selection`/Pin) — `sel: null` stays.
- ❌ Don't panic the Debug `zig build` link error — it's a GCC-16 toolchain artifact, not your change; use ReleaseFast.
- ❌ Don't probe the tty from resolve (it can't) — pass `palette.hasControllingTty()` as the `has_tty` argument.
- ❌ Don't hardcode palette hex values in unit tests — `toPaletteMode` returns enum tags, assert those (resolve's
  own tests in palette.zig already assert the Colors values; no need to duplicate).

---

## Confidence Score: 9/10

The substantive change is a single line swap + a compile-validated pure bridge (verified by an
isolated `zig test` probe). `palette.resolve`/`Mode`/`hasControllingTty` ALREADY EXIST, are Complete,
and are covered by 7 passing unit tests in palette.zig — S3 only WIRES them behind the already-parsed
flag. Every validation command was run against the current binary: the deterministic color anchors
(`#292c33` default, `#010203`/`#050607` seeded) and the `XDG_CACHE_HOME` + `setsid` no-tty mechanics
are all confirmed working. The build-env caveat (Debug link failure under GCC 16) is documented with
the working ReleaseFast gate. The remaining 1/10 is ordinary friction (the exact S2-refined run()
line-count when S3 starts), not architectural uncertainty — and the replacement is identical whether
S3 starts from the S1 baseline or the S2-refined run().
