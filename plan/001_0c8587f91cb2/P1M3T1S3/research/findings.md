# P1.M3.T1.S3 Research Findings — `--palette MODE` flag via `palette.resolve`

> Scope: in `render.run`, replace the `palette.defaultColors()` call with
> `palette.resolve(alloc, <mode>, palette.hasControllingTty())`, adding a tiny
> `cli.PaletteMode -> palette.Mode` bridge. This is a SURGICAL change: one call
> site + one pure helper. Everything resolve needs already exists and is tested
> (P1.M2.T1.S3 is Complete).

## §0. The gap S3 closes (confirmed against the CURRENT binary)

The `--palette` flag is ALREADY parsed (cli.zig:167 → `opts.palette_mode`) and
ALREADY documented in `render_help` (cli.zig). But `render.run` (render.zig)
**ignores `opts.palette_mode` entirely** and always calls `palette.defaultColors()`:

```
printf '\033[31mred\033[0m' | ./zig-out/bin/tmux-2html render --cols 40 --palette default   → background-color: #292c33
printf '\033[31mred\033[0m' | ./zig-out/bin/tmux-2html render --cols 40 --palette cached     → background-color: #292c33   (SAME — flag ignored)
printf '\033[31mred\033[0m' | ./zig-out/bin/tmux-2html render --cols 40 --palette live       → background-color: #292c33   (SAME — flag ignored)
```

S3 makes those three invocations behave differently per PRD §6 precedence.

## §1. The `palette.resolve` API surface (EXISTS, Complete, tested)

`src/palette.zig` (read in full). Relevant declarations:

```zig
pub const Mode = enum {            // palette.zig:463
    default, cached, live,
    pub fn fromStr(s: []const u8) ?Mode { ... }
};

pub fn hasControllingTty() bool { ... }   // palette.zig:491 — opens /dev/tty RO; ENXIO→false

pub fn resolve(allocator: std.mem.Allocator, mode: Mode, has_tty: bool) Colors   // palette.zig:545
//   INFALLIBLE: returns Colors (NOT !Colors). Every cachePath/loadCache/queryColors
//   error is swallowed; bottoms out at defaultColors(). resolve frees its own
//   cachePath scratch (defer allocator.free(path)).
```

Precedence (palette.zig `resolveDir`, verified by 7 passing unit tests):
- `.default` → `defaultColors()` (ignores cache + tty).
- `.cached`  → `loadCache` → (if miss) `liveOr(has_tty)` → default.
- `.live`    → `queryColors` (only if `has_tty`) → (if err/no-tty) `loadCache` → default.

So S3 needs ZERO new palette logic. It only WIRES the existing `resolve` into
`render.run` behind the already-parsed flag.

## §2. The type bridge: `cli.PaletteMode` -> `palette.Mode` (the only NEW code)

Two SEPARATE enums exist by design (palette.zig comment line ~460:
"palette.zig must NOT import cli.zig"; cli.zig must stay ghostty-free):

```zig
cli.PaletteMode  { default, cached, live }   // cli.zig:25 — RenderOpts.palette_mode : PaletteMode = .cached
palette.Mode     { default, cached, live }   // palette.zig:463
```

Identical variant names, but distinct types. `palette.resolve` takes `palette.Mode`,
`opts.palette_mode` is `cli.PaletteMode`. Bridge = a 3-arm switch (prescribed by the
S2 PRP: "The renderer bridges cli.PaletteMode -> Mode with a 3-arm switch"):

```zig
fn toPaletteMode(m: cli.PaletteMode) palette.Mode {
    return switch (m) {
        .default => .default,
        .cached  => .cached,
        .live    => .live,
    };
}
```

COMPILE-VALIDATED by an isolated probe (`/tmp/s3probe`, `zig test`, both tests OK):
round-trips all three modes, and `resolve(alloc, toPaletteMode(.live), false)` is
infallible (returns `Colors`, no `try`). A switch (not `@intFromEnum`/`@enumFromInt`)
is robust to declaration reordering and self-documents the mapping.

## §3. The exact call-site change in `render.run`

`run(alloc, opts: cli.RenderOpts) !u8` computes `colors` ONCE at the top (right after
the stdin read) and that single `colors` value flows to ALL output arms (stdout /
`--output` file / `--open` temp) in BOTH the S1 baseline and the S2-refined run().
So S3 touches exactly ONE line:

```zig
// BEFORE (S1 baseline AND S2-refined):
const colors = palette.defaultColors();

// AFTER (S3):
const colors = palette.resolve(alloc, toPaletteMode(opts.palette_mode), palette.hasControllingTty());
```

NOTE: the item-contract snippet wrote `palette.resolve(mode, palette.hasControllingTty())`
— it OMITS the allocator. The REAL signature is `resolve(allocator, mode, has_tty)`.
Pass `alloc` (run's first param).

## §4. Build environment — CRITICAL (Debug linker is broken; use ReleaseFast)

This machine: Zig 0.15.2 + GCC 16.1.1.

```
zig build                          → fatal linker error: unhandled relocation type R_X86_64_PC64
                                     in crt1.o:.sframe   (GCC 16 .sframe section; Zig 0.15.2 can't link it)
                                     ** compilation/type-check SUCCEEDS; only the final LINK fails **
zig build test                     → SAME link failure (test binary must link too)
zig build -Doptimize=ReleaseFast   → SUCCESS → zig-out/bin/tmux-2html  ✓
zig build test -Doptimize=ReleaseFast → SUCCESS, all tests pass  ✓
zig build-obj src/render.zig -fno-emit-bin -target x86_64-macos → EXIT 0 ✓ (cross-compile gate still valid)
```

=> The PRP's Level 1/Level 2 gates use `-Doptimize=ReleaseFast` for BOTH build and
test. (The S1/S2 PRPs wrote bare `zig build` / `zig build test`; those fail to LINK
here even on clean code. Document this so the implementer doesn't chase a phantom
"my change broke the build".)

## §5. Deterministic test anchors (verified against the current binary + formatter source)

From `ghostty_format.zig` `PageFormatter.formatWithState` (the HTML `<pre>` header):
```
<pre class="term2html-output" style="max-width: {cols}ch; background-color: #{bg}; color: #{fg}; font-family: {font};">
```
Hex is LOWERCASE, 2-digit-per-channel (`{x:0>2}`).

- `defaultColors().background = .{ .r=41, .g=44, .b=51 }` → **`background-color: #292c33`**
  (VERIFIED: current binary prints exactly this). This is the deterministic anchor for
  `--palette default`, AND the fallback for `.cached`/`.live` on cache-miss + no-tty.
- A seeded cache with `bg 1 2 3` → **`background-color: #010203`**.
- A seeded cache with `bg 5 6 7` → **`background-color: #050607`**.

## §6. Cache seeding for integration tests (VERIFIED)

`palette.cacheBase()` honors `XDG_CACHE_HOME` when set, non-empty, AND absolute
(palette.zig). `resolve(.cached)` reads `<XDG_CACHE_HOME>/tmux-2html/palette`. VERIFIED
by running the existing binary:

```
TC=$(mktemp -d)
echo "fg 100 110 120
bg 1 2 3
0 9 9 9" > /tmp/seed.txt
XDG_CACHE_HOME="$TC" ./zig-out/bin/tmux-2html sync-palette --from file /tmp/seed.txt
# → loaded 1/256 colors; cache at $TC/tmux-2html/palette   (file exists, bg line = "bg 1 2 3")
```

For integration tests we can seed the file DIRECTLY (no sync-palette needed):
`printf '# t\nbg 1 2 3\n' > "$TC/tmux-2html/palette"`. The parser is tolerant
(missing entries keep `defaultColors()` seed values), so a minimal bg-only file is valid.

## §7. No-tty determinism via `setsid` (the S2 PRP trick, reused)

`palette.hasControllingTty()` opens `/dev/tty` RO; open fails with ENXIO when the
process has NO controlling tty. `setsid bash -c "..."` creates a new session with no
controlling tty → `hasControllingTty()` returns false deterministically (works in CI
AND a dev terminal). This is how we force the `.live`→skip and `.cached`-miss→default
paths without depending on the ambient environment. (Render under setsid still needs
`--cols` because S2's `determineCols` errors without a tty; pass `--cols 40`.)

## §8. Scope discipline (what S3 does NOT do)

- Does NOT touch S2's sizing (`determineCols`/`lineCount`/`getSize`), output
  (`renderToFileAtomic`/`tempHtmlPath`), or open (`spawnXdgOpen`) logic.
- Does NOT touch `cli.zig` (parse + help already done in P1.M1.T3.S2), `main.zig`,
  `palette.zig`, `ghostty_format.zig`, `build.zig`, `build.zig.zon`.
- Does NOT implement `--selection` coordinate→Pin (S4 / P1.M4.T1.S1) — `sel: null` stays.
- Does NOT add docs beyond help (contract §5: "none — flag in help"; help already lists it).

## §9. Sibling-task ordering note (S2 runs before S3)

`plan_status`: S2 = Implementing, S3 = Researching. S3 is implemented AFTER S2 merges.
The `colors` line S3 replaces exists in the SAME place in both the S1 baseline
(`const colors = palette.defaultColors();` after the stdin read) and the S2-refined run
(S2 keeps that exact line with a `// S3: palette.resolve(...)` comment). So the
replacement is identical regardless of which baseline S3 starts from.
