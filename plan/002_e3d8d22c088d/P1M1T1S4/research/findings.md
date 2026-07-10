# Research Findings — P1.M1.T1.S4

## pane (main.zig) + region (region.zig) honor `--title` override + `--lang`

Companion to `plan/002_e3d8d22c088d/P1M1T1S3/PRP.md` (S3 wired `render.run`). S4 wires the
SAME `opts.title` / `opts.lang` (+ S2 `resolveLang`) into the **pane** and **region**
subcommands. The two code paths have DIFFERENT shapes — documented below.

---

### 1. Verified line anchors (working tree, S1+S2 present; S3 in parallel)

| Site | File:line | Current text (exact, unique) |
|---|---|---|
| pane title compute | `src/main.zig:463` | `const title = paneTitle(allocator, runner, target) catch try allocator.dupe(u8, "tmux-2html");` |
| pane `defer free` | `src/main.zig:464` | `defer allocator.free(title);` |
| pane `DocumentOpts` literal | `src/main.zig:472` | `.{ .title = title, .background = colors.background },` |
| pane render module alias | `src/main.zig:8` | `const render_mod = @import("render.zig");` |
| region title compute | `src/region.zig:459` | `const title = regionTitle(allocator, runner, target) catch try allocator.dupe(u8, "tmux-2html");` |
| region `defer free` | `src/region.zig:460` | `defer allocator.free(title);` |
| region render module alias | `src/region.zig:41` | `const render = @import("render.zig");` |
| `renderSelectionHtml` call | `src/region.zig:461` | `const html = renderSelectionHtml(allocator, &ctx, font, title) catch {` |
| `renderSelectionHtml` sig | `src/region.zig:525` | `fn renderSelectionHtml(allocator: std.mem.Allocator, ctx: *RegionCtx, font: []const u8, title: []const u8) ![]u8` |
| region `DocumentOpts` literal | `src/region.zig:546` | `try render.writeDocumentBytes(&dw.writer, .{ .title = title, .background = ctx.colors.background }, fragment);` |

NOTE: the item description cited `region.zig:546 render.writeDocumentBytes(... DocumentOpts{...})`
AND `region.zig:459 regionTitle(...)`. Both are correct in the live tree. The line numbers in
the contract match the working tree (no S2-style drift here for these sites).

### 2. The pane path is trivial — `opts` is in scope at both sites

`fn paneBody(allocator, opts: cli.PaneOpts)` (`main.zig:427`) computes the title (:463) AND
constructs the `DocumentOpts` literal (:472) in the SAME function where `opts` is the param.
So the override + lang can be wired inline. Two edits:

- :463 → honor override: `if (opts.title) |t| (try allocator.dupe(u8, t)) else (paneTitle(...) catch ...)`.
- :472 → add `.lang = render_mod.resolveLang(opts.lang)`.

### 3. The region path is NOT trivial — the `DocumentOpts` literal is in a SEPARATE fn

`fn body(allocator, opts: cli.RegionOpts)` (`region.zig:291`) computes the title (:459) in its
`confirm` arm, where `opts` IS in scope. BUT the `DocumentOpts` literal lives inside
`fn renderSelectionHtml(allocator, ctx, font, title)` (`region.zig:525`), which does NOT
receive `opts` (only the already-resolved `title`). `renderSelectionHtml` has exactly ONE caller
(`region.zig:461` — verified via grep, no other call sites).

So to add `.lang = resolveLang(opts.lang)` to the region `DocumentOpts` literal, `lang` must be
THREADED from `body()` into `renderSelectionHtml`. Cleanest: resolve once in `body()` and pass
the resolved `[]const u8` as a new trailing param.

### 4. The testability tension (and its resolution)

The item contract (point 3) gives the title logic as an inline `if`/`else` example, AND
separately REQUIRES: "keep title-override tests unit-level via the existing test harness."

These are in tension: the inline `if` lives inside `paneBody`/`body`, which do I/O (tmux
capture, file writes, the region TUI) → NOT unit-testable. To satisfy the unit-test
requirement, extract a small Runner-seamed helper per file:

- `main.zig`: `fn paneResolveTitle(allocator, override: ?[]const u8, runner, pane) ![]u8`
- `region.zig`: `fn regionResolveTitle(allocator, override: ?[]const u8, runner, target) ![]u8`

Each returns the override verbatim (owned dupe) when non-null, else delegates to the existing
`paneTitle`/`regionTitle` with the same `catch try allocator.dupe(u8, "tmux-2html")` fallback.
Semantically IDENTICAL to the contract's inline `if` (verified: `paneTitle` only errors on OOM
of `allocPrint`; its `querySessionName` errors are caught internally → empty session → "pane",
so the "tmux-2html" literal fallback is defensive/dead but MUST be preserved per the contract).
`paneBody`/`body` then call `try paneResolveTitle(...)` / `try regionResolveTitle(...)` and keep
the existing `defer allocator.free(title)` (the helper returns an owned slice).

### 5. Existing test harnesses (verified) — mirror for the new helpers

- **main.zig `PaneFake`** (`main.zig:693`): `PaneFake{ .session = "mysess" }`, `.runFn = PaneFake.run`,
  `runner: capture.Runner = .{ .ctx = @ptrCast(&fake), .runFn = PaneFake.run }`. Existing
  `paneTitle` tests at `main.zig:851` + `:864`.
- **region.zig `OptFake`** (`region.zig:815`) + helper `optFake(options, session)` (`:845`):
  `var fake = optFake(&.{}, "mysess"); defer fake.options.deinit();` then
  `runner: capture.Runner = .{ .ctx = @ptrCast(&fake), .runFn = OptFake.run }`. Existing
  `regionTitle` tests at `region.zig:1009` + `:1024`.

New `paneResolveTitle`/`regionResolveTitle` tests are Terminal-free + Runner-seamed ⇒ separate
test fns are safe (NO cross-test GOTCHA — do NOT build a Terminal in these tests). They go
alongside the existing `paneTitle`/`regionTitle` tests in the same file.

### 6. resolveLang / langFromEnv behavior (verified — `render.zig:261-283`)

```zig
pub fn resolveLang(explicit: ?[]const u8) []const u8 {
    if (explicit) |e| return toBcp47(e) orelse "en";  // explicit --lang (normalized) wins
    return langFromEnv();                              // else locale, else "en"
}
```
`langFromEnv()` reads `LC_ALL` → `LC_MESSAGES` → `LANG` (first non-empty, BCP-47-normalized),
else returns the string literal `"en"`. **In a clean env (no locale vars) → "en".** Returns a
slice into module-level `bcp47_buf` (or the static `"en"` literal) — static lifetime, NO free.

### 7. "byte-identical to today" — the precise guarantee

The contract says "Default (no flags) byte-identical to today." Precise reading (consistent
with S3 + PRD §8.1 "default en; configurable via @tmux-2html-lang / locale"):

1. **Goldens byte-identical** — `golden_test.zig` calls `renderDocument` DIRECTLY with its OWN
   `DocumentOpts{ .title = "tmux-2html", ... }` (`lang` defaults `"en"`) and NEVER calls
   `paneBody`/`body`. S4 touches only `main.zig` + `region.zig` (NOT `render.zig`, NOT
   `golden_test.zig`). ⇒ pinned bytes are provably unchanged. HARD guarantee.
2. **No-flags, clean CI env** — `resolveLang(null)` → `langFromEnv()` → "en" (no locale vars).
   ⇒ pane/region default output is byte-identical to today in CI. Holds.
3. **No-flags, locale env** — `resolveLang(null)` → locale tag (e.g. "en-US"). This is the
   INTENDED §8.1 behavior and matches what S3 already did for `render`. NOT a regression.
4. **Contextual title unchanged** — when no `--title`, the helper delegates to `paneTitle`/
   `regionTitle` exactly as today. The override only applies when `--title` is given. Holds always.

So the implementer must NOT force `lang = "en"` for the no-flag pane/region case (that would
contradict S3 + §8.1). `.lang = resolveLang(opts.lang)` is correct as-is.

### 8. bcp47_buf lifetime (safe) — mirrors S3 Gotcha 4

- pane: `render_mod.resolveLang(opts.lang)` is evaluated inline at the `DocumentOpts` literal
  (:472). Between that evaluation and `doc.lang` consumption (inside `renderToFileAtomic` →
  `renderDocument` → `writeDocument`, which writes `<html lang>`), NOTHING re-invokes
  `resolveLang`/`toBcp47`/`langFromEnv`. Slice stable. ✓
- region: `const lang = render.resolveLang(opts.lang)` is evaluated once in `body()` (:~460),
  passed by value (slice header copy) into `renderSelectionHtml`, consumed by
  `writeDocumentBytes` → `writeDocument`. Nothing in between re-invokes the resolver. ✓

Do NOT add a `dupe`/copy of the resolved lang slice — the single result is stable until consumed.

### 9. Tests MUST run in ReleaseFast (Zig 0.15.2 linker bug)

Plain `zig build test` (Debug) fails with `R_X86_64_PC64` relocations from ghostty-vt's bundled
C++ SIMD libs — NOT a code error. Always: `zig build test -Doptimize=ReleaseFast`
(plan/001 findings_and_corrections.md §4; PRD §15; S1/S2/S3 PRPs).

### 10. Binary smoke is LIMITED for pane/region (tmux-dependent)

- `pane` requires `$TMUX_PANE`/`--target` + a live `tmux capture-pane`; without tmux it exits 2
  (no target) or short-circuits at `result.code != 0` BEFORE reaching the title/DocumentOpts
  site (`main.zig:451`). So the title/lang site is NOT reachable without a real pane.
- `region` drives an interactive copy-mode TUI — not smoke-testable headless.

⇒ S4's PRIMARY validation gate is **unit tests** (Level 2). Level 3 is: (a) `zig build
--release=fast` succeeds (proves main.zig + region.zig compile with the new `DocumentOpts`
literals + `resolveLang` calls); (b) `render --title/--lang` regression (S4 must NOT break
render — S3's wiring stays intact); (c) `pane`/`region` graceful-fail without tmux (exit 2/1,
no crash). The pane/region title/lang **end-to-end** is owned by **P1.M1.T3.S1**
("isolated-tmux output-path smoke"), per the contract.

### 11. Files touched / NOT touched

- TOUCH: `src/main.zig` (paneResolveTitle helper + paneBody title site + DocumentOpts lang +
  2 unit tests), `src/region.zig` (regionResolveTitle helper + body title site + lang resolve +
  renderSelectionHtml param + DocumentOpts lang + 2 unit tests).
- DO NOT TOUCH: `src/render.zig` (S2/S3 territory; resolveLang already pub), `src/cli.zig`
  (S1 — opts.title/opts.lang already `?[]const u8` on PaneOpts :80/:81 + RegionOpts :90/:91),
  `src/golden_test.zig` (must stay byte-equal), `--help` text (owned by S1 — already documents
  --title/--lang for pane/region at cli.zig:333-334 + :351-352), docs (owned by P1.M1.T2/T4).
