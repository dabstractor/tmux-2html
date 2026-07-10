# PRP — P1.M1.T1.S4: `pane` (main.zig) + `region` (region.zig) honor `--title` override + `--lang`

## Goal

**Feature Goal**: Make the `pane` and `region` subcommands honor the `--title` / `--lang` flags
(added by S1) by (a) letting a non-null `opts.title` OVERRIDE the computed contextual document
title, and (b) threading `resolveLang(opts.lang)` into both `DocumentOpts` constructions — so
`pane --title X --lang Y` / `region --title X --lang Y` emit `<title>X</title>` and
`<html lang="Y-or-locale">` in a complete §8.1 document. Mirrors what S3 did for `render.run`,
applied to the two remaining subcommands.

**Deliverable**: Surgical edits to **`src/main.zig`** (pane) and **`src/region.zig`** (region)
only. No new files. Two small Runner-seamed helper fns (`paneResolveTitle` / `regionResolveTitle`)
make the override logic unit-testable (per the contract), plus a one-param widening of
`renderSelectionHtml` to thread the resolved `lang`. Four new unit tests (two per file) via the
existing `PaneFake` / `OptFake` harnesses. `--help` text is NOT touched (owned by S1).

**Success Definition**:
- `pane --title "X" --lang fr` and `region --title "X" --lang fr` emit `<title>X</title>` (X wins
  over the `tmux-2html — <sess>/<pane> <ts>` default) and `<html lang="fr">` in a complete document
  (end-to-end integration verified in **P1.M1.T3.S1** with isolated tmux; S4 proves wiring via
  compile + unit tests + a render regression guard).
- `pane`/`region` with no flags emit the SAME contextual title as today and `<html lang="en">` in a
  clean (no-locale) environment → behavior is a strict superset of before, consistent with S3.
- `zig build test -Doptimize=ReleaseFast` exits 0; the two golden tests remain byte-equal (S4 never
  touches `render.zig`/`golden_test.zig`, and the goldens bypass `paneBody`/`body`).

## User Persona

**Target User**: Anyone running `tmux-2html pane` or `tmux-2html region` (incl. the tmux plugin in
P1.M1.T2, which will thread `@tmux-2html-title` / `@tmux-2html-lang` through these flags) who wants
a custom document `<title>` (e.g. a pane name) and a correct `<html lang>` (screen readers,
hyphenation).

**Use Case**: `tmux-2html pane --title "build-log" --lang en-US` writes a standalone HTML5 doc
titled "build-log", lang `en-US`, instead of the auto-derived `tmux-2html — <sess>/<pane> <ts>`.

**Pain Points Addressed**: Today pane/region always derive the title from the tmux context and
omit `.lang` (⇒ "en" regardless of locale). S4 makes `--title`/`--lang` actually take effect on
these two subcommands, completing the §8.1 configurability that S1 (flags) + S2 (resolver) + S3
(render wiring) set up.

## Why

- **PRD §8.1 (normative)** requires the document `<title>` "Configurable via `--title`" and
  `<html lang>` "default `en`; configurable via `@tmux-2html-lang` / locale". S1 added the raw
  flags to `PaneOpts`/`RegionOpts`; S2 added `resolveLang`; **S4 is the wiring step** that connects
  them to the documents emitted by the `pane` and `region` subcommands (S3 did `render`).
- **Two shapes, one intent**: pane computes title + builds `DocumentOpts` in the same fn
  (`opts` in scope); region computes title in `body()` but builds `DocumentOpts` inside
  `renderSelectionHtml` (no `opts`) — so `lang` must be threaded. Both are small, localized edits.
- **Boundary-safe**: S4 touches only `main.zig` + `region.zig` (NOT `render.zig`, NOT
  `golden_test.zig`, NOT `cli.zig`). The goldens call `renderDocument` directly with their own
  `DocumentOpts` and bypass `paneBody`/`body`, so this CLI-layer change is provably byte-invisible
  to the pinned suite. Comprehensive `--title`/`--lang` end-to-end output tests + isolated-tmux
  smoke are owned by **P1.M1.T3.S1**; S4 delivers the wiring + unit-level proof.
- **Testability**: the contract explicitly requires the title-override logic to be unit-tested via
  the existing Runner-seamed harness. Because `paneBody`/`body` do I/O (not unit-testable), S4
  extracts tiny `paneResolveTitle`/`regionResolveTitle` helpers (Runner-seamed, mirroring
  `paneTitle`/`regionTitle`) so the override is reachable from a unit test.

## What

A few small, localized edits across two files. Semantics, in plain terms:

1. **Title override (both subcommands)**: when `opts.title` is non-null, the document title is the
   user's value verbatim (the contextual `paneTitle`/`regionTitle` is NOT consulted). When null,
   the existing contextual default (`tmux-2html — <sess>/<pane> <ts>`) is used, with the same
   `catch try allocator.dupe(u8, "tmux-2html")` defensive fallback preserved.
2. **Lang (both subcommands)**: the `DocumentOpts` literal gains `.lang = resolveLang(opts.lang)`
   (pane: `render_mod.resolveLang(opts.lang)` at the literal; region: resolve once in `body()`,
   thread the resolved slice into `renderSelectionHtml`). `opts.lang` null + no locale env → "en".

### Success Criteria

- [ ] `pane --title X --lang fr` / `region --title X --lang fr` → `<title>X</title>` AND
      `<html lang="fr">` (override wins; end-to-end verified in P1.M1.T3.S1; S4 proves wiring).
- [ ] No-flags `pane`/`region` → contextual title unchanged AND `<html lang="en">` in a clean env.
- [ ] `paneResolveTitle`/`regionResolveTitle` unit tests pass (override wins; null ⇒ contextual).
- [ ] `zig build test -Doptimize=ReleaseFast` exits 0; both golden tests still byte-equal.
- [ ] Only `src/main.zig` + `src/region.zig` modified; `--help` text untouched (S1 owns it).

## All Needed Context

### Context Completeness Check

_Pass: "If someone knew nothing about this codebase, would they have everything needed to
implement this successfully?"_ — Yes. Every edit site is given with its exact current text
(unique in its file), the exact replacement, the resolved-signature widening, the import aliases
(`render_mod` in main.zig, `render` in region.zig), the test harnesses to mirror, the type matches
(`opts.title`/`opts.lang` = `?[]const u8`; `resolveLang(?[]const u8) []const u8`), the "byte-
identical" nuance, and the mandatory `ReleaseFast` test flag. This is a paste-and-verify task.

### Documentation & References

```yaml
# MUST EDIT — pane (title site + DocumentOpts + new helper + new tests)
- file: src/main.zig
  section: "paneTitle fn :321; paneBody :427; title compute :463 (+ defer free :464); renderToFileAtomic call :465; DocumentOpts literal :472; render_mod alias :8; PaneFake :693; paneTitle tests :851 + :864"
  why: "THE pane file. Three edits: replace :463 with a paneResolveTitle call (new helper), add .lang to the :472 literal, add 2 unit tests. Match on exact TEXT (line numbers verified current)."
  pattern: "paneBody has opts in scope at BOTH the title site and the DocumentOpts literal, so override+lang wire inline (via the helper + a literal field)."
  gotcha: "render module is aliased render_mod (NOT render) in main.zig — call render_mod.resolveLang(opts.lang)."

# MUST EDIT — region (title site + DocumentOpts + renderSelectionHtml widening + new helper + new tests)
- file: src/region.zig
  section: "render alias :41; body :291; confirm-arm title compute :459 (+ defer free :460); renderSelectionHtml call :461; renderSelectionHtml fn :525; DocumentOpts literal :546; regionTitle fn :589; OptFake :815; optFake :845; regionTitle tests :1009 + :1024"
  why: "THE region file. FOUR edits: replace :459 with a regionResolveTitle call + add a lang resolve, widen renderSelectionHtml sig (:525) + its single call site (:461) with a lang param, add .lang to the :546 literal, add 2 unit tests."
  pattern: "body() has opts in scope at the title site (:459) but the DocumentOpts literal is INSIDE renderSelectionHtml (:546) which has NO opts — so lang must be RESOLVED in body() and THREADED in as a new param."
  gotcha: "renderSelectionHtml has EXACTLY ONE caller (:461, verified) — widening its signature is safe. Resolve lang ONCE in body() and pass the resolved []const u8 (do NOT dupe it — bcp47_buf/static-literal lifetime is stable)."

# INPUT CONTRACT — S1 (Complete): the flags + types on PaneOpts/RegionOpts
- file: src/cli.zig
  section: "PaneOpts :72 (title :80, lang :81); RegionOpts :85 (title :90, lang :91); parsePane --title/--lang :215-218; parseRegion --title/--lang :245-248; --help pane :333-334; --help region :351-352"
  why: "Confirms opts.title/opts.lang are ?[]const u8 on BOTH PaneOpts and RegionOpts — exactly what the helper override + resolveLang expect. S4 does NOT touch cli.zig; --help already documents --title/--lang (S1 owns it)."

# INPUT CONTRACT — S2 (implemented in render.zig): the resolver (pub, same file S2 landed in)
- file: src/render.zig
  section: "DocumentOpts :187 (title []const u8; lang []const u8 = \"en\"); resolveLang pub fn :281; langFromEnv :270; writeDocument :310 (emits <html lang> + <title>); writeDocumentBytes :338; renderToFileAtomic :527"
  why: "resolveLang(?[]const u8) []const u8 is the exact call (explicit --lang normalized; else locale; else \"en\"). renderToFileAtomic/writeDocumentBytes accept the DocumentOpts that carry .lang. writeDocument emits <html lang=\"{doc.lang}\"> + <title>{doc.title}</title> (HTML-escaped) — so setting the fields IS the complete behavior."
  gotcha: "resolveLang returns a slice into module-level bcp47_buf OR the literal \"en\" (both static — no free). Nothing between the resolve and doc.lang consumption re-invokes the resolver ⇒ slice stable (mirrors S3 Gotcha 4)."

# GOLDEN INVARIANT proof — S4 never touches these
- file: src/golden_test.zig
  section: "renderDocument calls :22 + :57; DocumentOpts literals :29 + :64 (.title=\"tmux-2html\", lang defaults \"en\")"
  why: "Goldens build their OWN DocumentOpts and call renderDocument DIRECTLY — they never call paneBody/body. S4 edits only main.zig/region.zig. ⇒ pinned bytes provably unchanged."
  critical: "AFTER the edit run `zig build test -Doptimize=ReleaseFast`; if a golden changes, you accidentally touched render.zig/golden_test.zig — revert."

# CONTRACT SOURCES — S1/S2/S3 (treat as contract)
- file: plan/002_e3d8d22c088d/P1M1T1S1/PRP.md
  why: "Defines opts.title/opts.lang = ?[]const u8 on RenderOpts/PaneOpts/RegionOpts. S1 Complete."
- file: plan/002_e3d8d22c088d/P1M1T1S2/PRP.md
  why: "Defines pub resolveLang(?[]const u8) []const u8 + bcp47_buf static buffer + no-cascade/no-alloc guarantees S4 depends on. S2 implemented in render.zig."
- file: plan/002_e3d8d22c088d/P1M1T1S3/PRP.md
  why: "S3 wired render.run identically (const title = opts.title orelse \"tmux-2html\"; const lang = resolveLang(opts.lang); doc gains .lang). S4 mirrors it for pane + region. Read S3 to confirm the resolveLang idiom + the bcp47_buf-lifetime reasoning."

# PRD normative source
- file: PRD.md
  section: "§8.1 (HTML document envelope — title 'Configurable via --title'; lang 'default en; configurable via @tmux-2html-lang / locale')"
  why: "Normative requirement this wiring satisfies."

# Empirical verification for THIS task
- file: plan/002_e3d8d22c088d/P1M1T1S4/research/findings.md
  why: "Verifies every line anchor, the two-shape analysis, the testability tension + helper resolution, the byte-identical nuance, the bcp47_buf safety, the single-caller proof for renderSelectionHtml, and the ReleaseFast requirement."
```

### Current Codebase tree (relevant slice)

```bash
tmux-2html/
├── src/
│   ├── main.zig         # <— EDIT (pane): paneResolveTitle helper + paneBody title site + DocumentOpts lang + 2 tests
│   ├── region.zig       # <— EDIT (region): regionResolveTitle helper + body title/lang + renderSelectionHtml param + DocumentOpts lang + 2 tests
│   ├── render.zig       # S2/S3 territory — resolveLang (pub) already here (DO NOT EDIT)
│   ├── cli.zig          # S1 territory — PaneOpts/RegionOpts .title/.lang already ?[]const u8 (DO NOT EDIT)
│   ├── golden_test.zig  # pins renderDocument bytes (bypasses paneBody/body) — must stay byte-equal (DO NOT EDIT)
│   └── capture.zig      # capture.Runner (the injectable seam both helpers use) (DO NOT EDIT)
├── build.zig            # zig build test roots at src/main.zig module (picks up region.zig + golden tests)
└── PRD.md               # §8.1 normative
```

### Desired Codebase tree with files to be changed

```bash
tmux-2html/
└── src/
    ├── main.zig         # MODIFIED IN PLACE — new paneResolveTitle fn near paneTitle (:~321);
    │                    #   paneBody title site (:463) calls it; DocumentOpts (:472) gains .lang;
    │                    #   2 paneResolveTitle unit tests near the paneTitle tests (:~851).
    └── region.zig       # MODIFIED IN PLACE — new regionResolveTitle fn near regionTitle (:~589);
                         #   body confirm arm (:459) calls it + resolves lang; renderSelectionHtml
                         #   (:525) + its call (:461) gain a lang param; DocumentOpts (:546) gains
                         #   .lang; 2 regionResolveTitle unit tests near regionTitle tests (:~1009).
                         #   NO new files. NO other files. NO --help change.
```

### Known Gotchas of our codebase & Library Quirks

```zig
// GOTCHA 1 — region's DocumentOpts literal is in a SEPARATE fn from where opts is in scope.
//   body() (region.zig:291) computes the title at :459 (opts in scope) but the DocumentOpts
//   literal lives INSIDE renderSelectionHtml (region.zig:546), which receives only `title`
//   (NOT opts). So you CANNOT write `.{ .lang = resolveLang(opts.lang) }` at :546 directly —
//   opts isn't there. RESOLVE lang once in body() and THREAD it in as a new param. (findings §3.)
//   renderSelectionHtml has EXACTLY ONE caller (region.zig:461) — widening the sig is safe.

// GOTCHA 2 — import aliases DIFFER per file. main.zig uses `render_mod` (main.zig:8);
//   region.zig uses `render` (region.zig:41). Pane calls `render_mod.resolveLang(opts.lang)`;
//   region calls `render.resolveLang(opts.lang)`. Do not mix them up.

// GOTCHA 3 — tests MUST run in ReleaseFast. `zig build test` (Debug) fails with a known Zig
//   0.15.2 linker bug (R_X86_64_PC64) from ghostty-vt's bundled C++ SIMD libs — NOT a code
//   error. Always: `zig build test -Doptimize=ReleaseFast`. (findings §9; plan/001 §4; PRD §15.)

// GOTCHA 4 — "byte-identical to today" is a NARROW guarantee, NOT "lang stays en forever".
//   (a) Goldens byte-identical — they bypass paneBody/body (S4 doesn't touch render.zig). HARD.
//   (b) No-flags + clean CI env → resolveLang(null) → "en" (no locale vars) → byte-identical.
//   (c) No-flags + locale env → locale tag (e.g. "en-US") — INTENDED §8.1 behavior, matches S3.
//   (d) Contextual title unchanged when no --title (helper delegates to paneTitle/regionTitle).
//   Do NOT force lang = "en" for the no-flag case — that contradicts S3 + §8.1. resolveLang is
//   correct as-is. (findings §7.)

// GOTCHA 5 — resolveLang returns a slice into MODULE-LEVEL bcp47_buf (render.zig:202) OR the
//   literal "en". Both static lifetime → NO free. Nothing between the resolve and doc.lang
//   consumption re-invokes the resolver → slice stable. Do NOT dupe/copy it. (findings §8;
//   S3 Gotcha 4.)

// GOTCHA 6 — pane/region title/lang are NOT binary-smoke-testable here. pane needs a live tmux
//   pane ($TMUX_PANE/--target + capture-pane); without tmux it exits 2 or short-circuits at
//   result.code != 0 (main.zig:451) BEFORE reaching the title/DocumentOpts site. region drives
//   an interactive copy-mode TUI (not headless). So S4's PRIMARY gate is UNIT TESTS (Level 2);
//   the end-to-end pane/region --title/--lang check is owned by P1.M1.T3.S1 (isolated tmux).
//   (findings §10.)

// GOTCHA 7 — the "tmux-2html" literal fallback in the helper is DEFENSIVE/DEAD but MUST stay.
//   paneTitle/regionTitle only error on OOM of allocPrint (their querySessionName errors are
//   caught internally → empty session → "pane"). So the `catch try allocator.dupe(u8,
//   "tmux-2html")` rarely fires; you cannot trigger it in a unit test. Preserve it per the
//   contract ("preserve the existing defer free + fallback"); do NOT write a test for it.
//   (findings §4.)

// GOTCHA 8 — cross-test GOTCHA (region.zig). Tests that build a ghostty-vt Terminal share ONE
//   test fn scope. paneResolveTitle/regionResolveTitle are Terminal-free + Runner-seamed ⇒ they
//   get SEPARATE test fns (safe). Do NOT build a Terminal in the new tests. (findings §5.)

// GOTCHA 9 — opts.title/opts.lang are ?[]const u8 (nullable). In the helper, `if (override) |t|`
//   captures the non-null slice. Pass opts.lang DIRECTLY to resolveLang (it accepts ?[]const u8);
//   do NOT unwrap it first. (mirrors S3 Gotcha 6.)
```

## Implementation Blueprint

### Data models and structure

No new types. `DocumentOpts` (`render.zig:187`) already has `title: []const u8`,
`lang: []const u8 = "en"`, `background: ?ghostty_vt.color.RGB = null`. S4 merely populates
`title` from the override-or-contextual helper and `lang` from `resolveLang(opts.lang)` at the
two `DocumentOpts` constructions (pane `:472`, region `:546`), instead of hard-coding title
from the context only and leaving `lang` at its `"en"` default.

### The exact deliverable — verbatim edits

#### FILE 1: `src/main.zig` (pane)

**Edit 1a — new helper.** Add this `fn` immediately AFTER `paneTitle` (which ends at `main.zig:~328`,
right before `fn failPane`). It is semantically identical to the contract's inline `if`/`else`
example, but factored out so it is unit-testable:

```zig
/// Resolve the PRD §8.1 document title for a pane (S4): `--title` (opts.title) OVERRIDE wins
/// verbatim; else the contextual default (paneTitle: 'tmux-2html — <sess>/<pane> <ts>'); else
/// the literal "tmux-2html" if the contextual query/alloc fails. Caller owns + must free the
/// returned slice. Runner-seamed (delegates to paneTitle's injectable runner) => unit-testable
/// via the existing PaneFake harness (mirrors the paneTitle tests below). P1.M1.T1.S4.
fn paneResolveTitle(
    allocator: std.mem.Allocator,
    override: ?[]const u8,
    runner: capture.Runner,
    pane: []const u8,
) ![]u8 {
    if (override) |t| return allocator.dupe(u8, t);
    return paneTitle(allocator, runner, pane) catch try allocator.dupe(u8, "tmux-2html");
}
```

**Edit 1b — paneBody title site (`main.zig:463`).** Replace:

```zig
// ---- BEFORE (exact, unique) ----
    const title = paneTitle(allocator, runner, target) catch try allocator.dupe(u8, "tmux-2html");
```
with:
```zig
// ---- AFTER ----
    // PRD §8.1 / P1.M1.T1.S4: --title (opts.title) overrides the contextual title; else
    // paneTitle's default. Factored into paneResolveTitle so the override is unit-testable.
    const title = try paneResolveTitle(allocator, opts.title, runner, target);
```
The next line (`defer allocator.free(title);` at `:464`) is UNCHANGED — the helper returns an
owned slice.

**Edit 1c — pane DocumentOpts literal (`main.zig:472`).** Replace:

```zig
// ---- BEFORE (exact, unique) ----
        .{ .title = title, .background = colors.background },
```
with:
```zig
// ---- AFTER ----
        // PRD §8.1 / P1.M1.T1.S4: <html lang> = explicit --lang (normalized), else locale, else "en".
        .{ .title = title, .lang = render_mod.resolveLang(opts.lang), .background = colors.background },
```

**Edit 1d — two unit tests.** Add them immediately AFTER the existing `paneTitle` tests (which
end at `main.zig:~880`), mirroring their `PaneFake` setup:

```zig
test "paneResolveTitle: --title override wins verbatim (no tmux query)" {
    const alloc = std.testing.allocator;
    var fake = PaneFake{ .session = "mysess" }; // would echo #{session_name} — but override wins
    const runner: capture.Runner = .{ .ctx = @ptrCast(&fake), .runFn = PaneFake.run };

    const title = try paneResolveTitle(alloc, "My Override", runner, "%7");
    defer alloc.free(title);
    // Override is returned VERBATIM; the contextual paneTitle is NOT consulted.
    try std.testing.expectEqualStrings("My Override", title);
}

test "paneResolveTitle: null override => contextual default" {
    const alloc = std.testing.allocator;
    var fake = PaneFake{ .session = "mysess" };
    const runner: capture.Runner = .{ .ctx = @ptrCast(&fake), .runFn = PaneFake.run };

    const title = try paneResolveTitle(alloc, null, runner, "%7");
    defer alloc.free(title);
    // Delegates to paneTitle => PRD §8.1 default form 'tmux-2html — <session>/<pane> <unixtime>'.
    try std.testing.expect(std.mem.startsWith(u8, title, "tmux-2html — mysess/%7 "));
    const ts_s = title["tmux-2html — mysess/%7 ".len..];
    _ = try std.fmt.parseInt(i64, ts_s, 10);
}
```

#### FILE 2: `src/region.zig` (region)

**Edit 2a — new helper.** Add this `fn` immediately AFTER `regionTitle` (which ends at
`region.zig:~596`, right before `fn selfBinDir`). Mirrors `paneResolveTitle`:

```zig
/// Resolve the PRD §8.1 document title for a region (S4): `--title` (opts.title) OVERRIDE wins
/// verbatim; else the contextual default (regionTitle); else the literal "tmux-2html". Caller
/// owns + must free. Runner-seamed (delegates to regionTitle's injectable runner) =>
/// unit-testable via the existing OptFake harness (mirrors the regionTitle tests). P1.M1.T1.S4.
fn regionResolveTitle(
    allocator: std.mem.Allocator,
    override: ?[]const u8,
    runner: capture.Runner,
    target: []const u8,
) ![]u8 {
    if (override) |t| return allocator.dupe(u8, t);
    return regionTitle(allocator, runner, target) catch try allocator.dupe(u8, "tmux-2html");
}
```

**Edit 2b — body() confirm-arm title site + lang resolve (`region.zig:459`).** Replace:

```zig
// ---- BEFORE (exact, unique) ----
            const title = regionTitle(allocator, runner, target) catch try allocator.dupe(u8, "tmux-2html");
            defer allocator.free(title);
            const html = renderSelectionHtml(allocator, &ctx, font, title) catch {
```
with:
```zig
// ---- AFTER ----
            // PRD §8.1 / P1.M1.T1.S4: --title (opts.title) overrides the contextual title; else
            // regionTitle's default. Factored into regionResolveTitle (unit-testable). lang is
            // resolved ONCE here (static-lifetime slice) and threaded into renderSelectionHtml
            // (which has no `opts` in scope) so the DocumentOpts literal can carry it.
            const title = try regionResolveTitle(allocator, opts.title, runner, target);
            defer allocator.free(title);
            const lang = render.resolveLang(opts.lang);
            const html = renderSelectionHtml(allocator, &ctx, font, title, lang) catch {
```

**Edit 2c — widen `renderSelectionHtml` signature (`region.zig:525`).** Replace:

```zig
// ---- BEFORE (exact, unique) ----
fn renderSelectionHtml(allocator: std.mem.Allocator, ctx: *RegionCtx, font: []const u8, title: []const u8) ![]u8 {
```
with:
```zig
// ---- AFTER ----
fn renderSelectionHtml(allocator: std.mem.Allocator, ctx: *RegionCtx, font: []const u8, title: []const u8, lang: []const u8) ![]u8 {
```
Also refresh its doc comment above (`:~505-515`) so "title passed in from body" reads
"title + lang passed in from body" (one-line tweak; keeps the doc accurate). Optional but tidy.

**Edit 2d — region DocumentOpts literal (`region.zig:546`).** Replace:

```zig
// ---- BEFORE (exact, unique) ----
    try render.writeDocumentBytes(&dw.writer, .{ .title = title, .background = ctx.colors.background }, fragment);
```
with:
```zig
// ---- AFTER ----
    // PRD §8.1 / P1.M1.T1.S4: <html lang> threaded in from body() (resolved once via resolveLang).
    try render.writeDocumentBytes(&dw.writer, .{ .title = title, .lang = lang, .background = ctx.colors.background }, fragment);
```

**Edit 2e — two unit tests.** Add them immediately AFTER the existing `regionTitle` tests (which
end at `region.zig:~1035`), mirroring their `optFake` setup:

```zig
test "regionResolveTitle: --title override wins verbatim (no tmux query)" {
    const alloc = testing.allocator;
    var fake = optFake(&.{}, "mysess"); // would echo #{session_name} — but override wins
    defer fake.options.deinit();
    const runner: capture.Runner = .{ .ctx = @ptrCast(&fake), .runFn = OptFake.run };

    const title = try regionResolveTitle(alloc, "Region Override", runner, "%7");
    defer alloc.free(title);
    // Override is returned VERBATIM; the contextual regionTitle is NOT consulted.
    try testing.expectEqualStrings("Region Override", title);
}

test "regionResolveTitle: null override => contextual default" {
    const alloc = testing.allocator;
    var fake = optFake(&.{}, "mysess");
    defer fake.options.deinit();
    const runner: capture.Runner = .{ .ctx = @ptrCast(&fake), .runFn = OptFake.run };

    const title = try regionResolveTitle(alloc, null, runner, "%7");
    defer alloc.free(title);
    // Delegates to regionTitle => PRD §8.1 default form 'tmux-2html — <session>/<pane> <unixtime>'.
    try testing.expect(std.mem.startsWith(u8, title, "tmux-2html — mysess/%7 "));
    const ts_s = title["tmux-2html — mysess/%7 ".len..];
    _ = try std.fmt.parseInt(i64, ts_s, 10);
}
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: EDIT src/main.zig — pane wiring (4 edits: 1a-1d)
  - 1a: ADD paneResolveTitle fn right after paneTitle (ends ~:328). Body as given above.
  - 1b: REPLACE main.zig:463 (title compute) with the paneResolveTitle call; KEEP defer free (:464).
  - 1c: REPLACE main.zig:472 (DocumentOpts literal) — add .lang = render_mod.resolveLang(opts.lang).
  - 1d: ADD the two paneResolveTitle unit tests after the paneTitle tests (~:880), mirroring PaneFake.
  - NAMING: paneResolveTitle (snake_case fn); test "paneResolveTitle: ..." (matches paneTitle tests).
  - WHY FIRST: compile + tests (Task 3) exercise this wiring.
  - DO NOT touch render.zig, cli.zig, golden_test.zig, --help.

Task 2: EDIT src/region.zig — region wiring (5 edits: 2a-2e)
  - 2a: ADD regionResolveTitle fn right after regionTitle (ends ~:596). Body as given above.
  - 2b: REPLACE region.zig:459 (title compute) with the regionResolveTitle call + add `const lang =
        render.resolveLang(opts.lang);`; KEEP defer free (:460); UPDATE the renderSelectionHtml call
        (:461) to pass `lang` as a new trailing arg.
  - 2c: WIDEN renderSelectionHtml sig (:525) — append `, lang: []const u8`. Refresh its doc comment.
  - 2d: REPLACE region.zig:546 (DocumentOpts literal) — add .lang = lang.
  - 2e: ADD the two regionResolveTitle unit tests after the regionTitle tests (~:1035), mirroring optFake.
  - NAMING: regionResolveTitle; renderSelectionHtml keeps its name (only +1 param); test "regionResolveTitle: ...".
  - DEPENDENCIES: regionResolveTitle (2a) called by 2b; lang threaded 2b→2c→2d.
  - DO NOT touch render.zig, cli.zig, golden_test.zig, --help.

Task 3: VALIDATE — goldens unchanged + full test suite green (PRIMARY gate)
  - RUN: zig build test -Doptimize=ReleaseFast   -> expect exit 0, ALL tests pass
  - CRITICAL CHECK: the two golden tests still pass BYTE-EQUAL (they bypass paneBody/body; this
    proves the invariant). If they change, you touched render.zig/golden_test.zig — revert.
  - NEW TESTS: paneResolveTitle (override + null) + regionResolveTitle (override + null) all pass.
  - NOTE: plain `zig build test` (Debug) fails with an unrelated linker bug — use ReleaseFast (Gotcha 3).

Task 4: VALIDATE — binary build + render regression + graceful-fail smoke
  - RUN: zig build --release=fast
  - render regression (S4 must NOT break render): echo '' | ./zig-out/bin/tmux-2html render --title X --lang fr
      -> <title>X</title> + <html lang="fr"> (S3 wiring intact).
  - pane/region graceful-fail without tmux: ./zig-out/bin/tmux-2html pane --target %1 ; echo "exit=$?"
      -> exit 2 (no target) or 1; NO segfault (proves main.zig/region.zig compiled into the binary
      with the new DocumentOpts literals). The title/lang SITE is NOT reachable without a live tmux
      pane (short-circuits at result.code != 0, main.zig:451) — the end-to-end check is P1.M1.T3.S1.
```

### Implementation Patterns & Key Details

```zig
// PATTERN: factor the override into a Runner-seamed helper so it is UNIT-TESTABLE (the contract
//   requires unit-level tests). paneBody/body do I/O (tmux capture / TUI) and are NOT testable.
//   The helper delegates to the existing paneTitle/regionTitle for the contextual path, so the
//   existing paneTitle/regionTitle tests + behavior are unchanged.
fn paneResolveTitle(allocator, override: ?[]const u8, runner, pane) ![]u8 {
    if (override) |t| return allocator.dupe(u8, t);          // --title wins verbatim
    return paneTitle(allocator, runner, pane) catch          // contextual default
        try allocator.dupe(u8, "tmux-2html");                // defensive fallback (preserved)
}
// paneBody: const title = try paneResolveTitle(allocator, opts.title, runner, target);
//           defer allocator.free(title);  // unchanged — helper returns an owned slice

// PATTERN: resolve lang ONCE; reuse the single static-lifetime slice (no dupe).
//   pane:   inline at the DocumentOpts literal: .lang = render_mod.resolveLang(opts.lang)
//   region: resolve in body() (opts in scope), thread the []const u8 into renderSelectionHtml,
//           set .lang = lang at its DocumentOpts literal. renderSelectionHtml has ONE caller.

// CRITICAL: goldens call renderDocument DIRECTLY with their own DocumentOpts literal
//   (.title="tmux-2html", lang defaults "en") and NEVER call paneBody/body. S4 edits only
//   main.zig + region.zig. So the edit is invisible to them. Verify:
//   zig build test -Doptimize=ReleaseFast -> golden tests still byte-equal.

// CRITICAL: resolveLang is in render.zig (S2) — reach it via the file's alias (render_mod in
//   main.zig; render in region.zig). It accepts ?[]const u8 — pass opts.lang DIRECTLY (no unwrap).
```

### Integration Points

```yaml
THIS TASK (edits to 2 existing files, no new integration):
  - src/main.zig: paneResolveTitle fn + paneBody title site (:463) + DocumentOpts lang (:472) + 2 tests.
  - src/region.zig: regionResolveTitle fn + body title/lang (:459) + renderSelectionHtml param (:525,:461)
        + DocumentOpts lang (:546) + 2 tests.

UPSTREAM (already present — treat as contract, do NOT re-implement):
  - S1 (Complete): cli.PaneOpts.title/lang (:80/:81) + cli.RegionOpts.title/lang (:90/:91) = ?[]const u8.
  - S2 (in render.zig): pub resolveLang(?[]const u8) []const u8 (:281) + DocumentOpts.lang default "en" (:189).
  - S3 (parallel, in render.zig): render.run already wires resolveLang the same way — S4 mirrors it.

DOWNSTREAM (NOT this task — do not implement):
  - P1.M1.T2.S1: tmux-2html.tmux threads @tmux-2html-title/@tmux-2html-lang as --title/--lang
        (lands in opts.title/opts.lang, which S4 now consumes).
  - P1.M1.T3.S1: formal --title/--lang end-to-end output tests + isolated-tmux pane/region smoke
        (S4 provides wiring + unit tests + a render regression guard only).

CONFIG / DATABASE / ROUTES:
  - none. (Pure in-process field population; reads opts + LC_ALL/LC_MESSAGES/LANG via resolveLang.)
```

## Validation Loop

> PRIMARY gates: (1) `zig build test -Doptimize=ReleaseFast` exits 0 with goldens byte-equal
> (the CRITICAL INVARIANT) AND the four new unit tests pass; (2) the binary builds and render is
> unbroken. pane/region title/lang **end-to-end** is owned by P1.M1.T3.S1 (needs isolated tmux).

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# The optimized build IS the syntax/type check. Confirms both files compile with the new
# DocumentOpts literals, the resolveLang calls, the widened renderSelectionHtml sig, and the
# new helpers/tests.
zig build --release=fast 2>&1 | head -30
# Expected: success. An `error:` naming main.zig => wrong render_mod alias or a typo in the
# helper/edits; naming region.zig => renderSelectionHtml call/sig mismatch (did you pass `lang`
# at :461 AND add the param at :525?) or a wrong render alias. Types are type-checked:
# paneResolveTitle returns ![]u8 (try-able); render_mod.resolveLang(?[]const u8)->[]const u8;
# DocumentOpts.title/lang both []const u8; opts.title/opts.lang ?[]const u8.
```

### Level 2: Unit & Golden Tests (PRIMARY gate — goldens must be byte-equal)

```bash
# Full suite incl. the two golden tests + the four new resolve-title tests. MUST use ReleaseFast.
zig build test -Doptimize=ReleaseFast
# Expected: exit 0. ALL tests pass. CRITICAL: the two golden tests in golden_test.zig still pass
# BYTE-EQUAL (they call renderDocument directly with their own DocumentOpts literal and never call
# paneBody/body, and S4 doesn't touch render.zig). If a golden test changes, STOP — you
# accidentally edited render.zig/golden_test.zig; revert.
# NEW: "paneResolveTitle: --title override wins verbatim" + "paneResolveTitle: null override =>
#   contextual default" + "regionResolveTitle: --title override wins verbatim" + "regionResolveTitle:
#   null override => contextual default" all PASS.
```

### Level 3: Integration / Binary Smoke (regression guard — end-to-end is T3.S1)

```bash
zig build --release=fast
BIN=./zig-out/bin/tmux-2html

# --- render regression (S4 must NOT break render — S3's wiring stays intact) ---
echo '' | $BIN render --title X --lang fr > /tmp/s4_render.html
grep -o '<title>[^<]*</title>' /tmp/s4_render.html   # expect: <title>X</title>
grep -o '<html lang="[^"]*"'      /tmp/s4_render.html # expect: <html lang="fr"

# --- pane/region graceful-fail without tmux (proves they COMPILED into the binary with the new
#     DocumentOpts literals; no segfault). The title/lang SITE is not reachable without a live pane
#     (short-circuits at result.code != 0), so this is a compile+no-crash check, NOT a lang check. ---
$BIN pane --target %1 >/tmp/s4_pane.out 2>&1; echo "pane exit=$?"
# expect: exit 2 (no such pane / $TMUX_PANE unset) or 1; NO crash/segfault. (End-to-end title/lang
#         for pane is P1.M1.T3.S1 with isolated tmux.)
$BIN region --target %1 >/tmp/s4_region.out 2>&1; echo "region exit=$?"
# expect: non-zero (region needs an interactive copy-mode TUI); NO crash. (End-to-end for region is
#         P1.M1.T3.S1.)

# Expected: render reflects X/fr (regression guard). pane/region fail cleanly without tmux
# (compile + no-crash proof). The four unit tests (Level 2) are the S4 proof of the override wiring.
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Confirm --help text is UNCHANGED for pane + region (S1 owns it) — a diff regression guard:
$BIN pane   --help | grep -E -- '--title|--lang'   # expect both help lines present, unchanged
$BIN region --help | grep -E -- '--title|--lang'   # expect both help lines present, unchanged

# (The pane/region --title/--lang END-TO-END output assertion — <title>X</title> + <html lang="fr">
#  from a real `pane --title X --lang fr` / `region --title X --lang fr` — requires a live tmux
#  session and is owned by P1.M1.T3.S1 "isolated-tmux output-path smoke". S4 does not duplicate it.)
```

## Final Validation Checklist

### Technical Validation

- [ ] `zig build --release=fast` succeeds (Level 1).
- [ ] `zig build test -Doptimize=ReleaseFast` exits 0 (Level 2).
- [ ] Both golden tests pass BYTE-EQUAL (CRITICAL INVARIANT — they bypass `paneBody`/`body`).
- [ ] The four new unit tests pass (paneResolveTitle ×2, regionResolveTitle ×2).

### Feature Validation

- [ ] override wins: `paneResolveTitle`/`regionResolveTitle` return `opts.title` verbatim when set.
- [ ] null ⇒ contextual default (delegates to `paneTitle`/`regionTitle`).
- [ ] pane `DocumentOpts` (`main.zig:472`) carries `.lang = render_mod.resolveLang(opts.lang)`.
- [ ] region `DocumentOpts` (`region.zig:546`) carries `.lang = lang` (threaded from `body()`).
- [ ] render regression: `render --title X --lang fr` → `<title>X</title>` + `<html lang="fr">`.
- [ ] `--help` text unchanged for pane + region (S1 owns it).

### Code Quality Validation

- [ ] Only `src/main.zig` + `src/region.zig` modified; no new files.
- [ ] `paneResolveTitle`/`regionResolveTitle` are Runner-seamed (mirrors `paneTitle`/`regionTitle`).
- [ ] `renderSelectionHtml` widening is consistent (sig :525 + call :461 both updated; one caller).
- [ ] `resolveLang` called once per subcommand; result reused (no `bcp47_buf` aliasing/dupe).
- [ ] `defer allocator.free(title)` preserved at both sites (helper returns an owned slice).
- [ ] No Terminal built in the new tests (cross-test GOTCHA avoided).

### Documentation & Deployment

- [ ] No user-facing/help change (DOCS: none — `--help` owned by S1; plugin/config owned by P1.M1.T2).
- [ ] No new env vars (reads LC_ALL/LC_MESSAGES/LANG via the existing S2 resolver).
- [ ] `renderSelectionHtml` doc comment refreshed (title + lang passed in from body).

---

## Anti-Patterns to Avoid

- ❌ Don't write `.{ .lang = resolveLang(opts.lang) }` at region's `:546` literal directly — `opts`
  is NOT in scope inside `renderSelectionHtml`. Resolve `lang` once in `body()` and THREAD it in.
- ❌ Don't mix the import aliases — main.zig uses `render_mod`, region.zig uses `render`.
- ❌ Don't run plain `zig build test` — it fails on the Debug linker bug (`R_X86_64_PC64` from
  ghostty-vt's C++ libs). Use `zig build test -Doptimize=ReleaseFast`.
- ❌ Don't touch `render.zig` / `cli.zig` / `golden_test.zig` — S2/S3 own render, S1 owns the
  flags, and the goldens must stay byte-equal (which they will, untouched). `--help` is S1's.
- ❌ Don't force `lang = "en"` for the no-flag pane/region case — that contradicts S3 + PRD §8.1.
  `resolveLang(null)` is correct (⇒ locale-or-"en"); it is byte-identical to "en" only in a clean env.
- ❌ Don't dupe/copy the resolved lang slice or call `resolveLang` more than once per subcommand —
  `bcp47_buf` would alias; the single result is stable until consumed.
- ❌ Don't unwrap `opts.lang` before passing to `resolveLang` — it accepts `?[]const u8` directly.
  `opts.title` uses `if (override) |t|`; `opts.lang` does not unwrap.
- ❌ Don't inline the title-override `if` into `paneBody`/`body` and skip the helper — the contract
  REQUIRES unit-level tests, and `paneBody`/`body` are not unit-testable (I/O). The helper makes it
  reachable. (The helper is semantically identical to the contract's inline example.)
- ❌ Don't write a unit test for the `catch try allocator.dupe(u8, "tmux-2html")` fallback — it is
  defensive/dead (paneTitle/regionTitle only OOM-fail) and cannot be triggered. Preserve it, don't
  test it. The override + null tests are the meaningful coverage.
- ❌ Don't build a ghostty-vt Terminal in the new tests — the cross-test GOTCHA forbids it; the
  resolve-title helpers are Terminal-free + Runner-seamed ⇒ separate test fns.

---

**Confidence Score: 10/10** for one-pass implementation success.

The two edits per file are small, localized, and type-checked: the helpers return `![]u8`
(owned, freed by the existing `defer`); `resolveLang(?[]const u8) []const u8` (S2, reached via
each file's alias) feeds `DocumentOpts.lang: []const u8`; `opts.title`/`opts.lang` are
`?[]const u8` (S1) on both `PaneOpts` and `RegionOpts`. The one non-trivial wrinkle — region's
`DocumentOpts` literal living inside `renderSelectionHtml` (no `opts`) — has a single verified
caller, so widening the signature with a threaded `lang` param is safe and fully specified.
The CRITICAL golden invariant is proven: `golden_test.zig` calls `renderDocument` directly and
bypasses `paneBody`/`body`, and S4 touches neither `render.zig` nor `golden_test.zig`, so the
pinned suite is provably byte-unchanged. The "byte-identical to today" nuance (resolveLang(null)
⇒ "en" only in a clean env; locale-derivation is the intended §8.1 behavior matching S3) is
documented so the implementer does not "fix" a non-bug. The bcp47_buf aliasing risk is precluded
(resolve once, consume before any re-invoke). The unit tests reuse the existing, verified
`PaneFake`/`optFake` Runner-seamed harnesses. The implementer is pasting exit-safe edits and
running two verified commands.
