# PRP — P1.M1.T1.S1: Add `--title` and `--lang` flags to cli.zig (render/pane/region)

## Goal

**Feature Goal**: Add two new optional CLI flags — `--title TITLE` and `--lang LANG` —
to the `render`, `pane`, and `region` subcommands' option structs and parg parsers
in `src/cli.zig`, surface them in the per-subcommand `--help` text, and cover them
with unit tests (TDD). These flags are the binary-side threading surface for the
PRD §8.1 document-envelope configurability (title + `lang` attribute). They are
deliberately NOT added to `sync-palette` (it emits no HTML).

**Deliverable**: A self-contained edit to **`src/cli.zig` only**:
1. `RenderOpts` / `PaneOpts` / `RegionOpts` each gain `title: ?[]const u8 = null`
   and `lang: ?[]const u8 = null` (nullable, defaulted).
2. `parseRender` / `parsePane` / `parseRegion` each gain two flag branches
   (`--title`, `--lang`) that consume a value via the existing `requireValue`.
3. The `render_help` / `pane_help` / `region_help` string constants each gain a
   `--title` line and a `--lang` line.
4. New + augmented unit tests in cli.zig asserting parse round-trips, null
   defaults, the missing-value error, and that `sync-palette` STILL rejects both
   flags.

**Success Definition**: `zig build test -Doptimize=ReleaseFast` passes (exit 0)
with the new tests green; `parseSyncPalette(&.{"--title", "x"})` still returns
`error.UnknownFlag`; when neither flag is passed, parse output is identical to
before (null defaults). No other file changes.

## Why

- **PRD §8.1 (normative)** requires the output HTML document's `<title>` to be
  "Configurable via `--title`" and the `<html lang>` to be "default `en`;
  configurable via `@tmux-2html-lang` / locale". The binary `--lang` flag is the
  threading surface the tmux plugin (P1.M1.T2.S1) uses to pass the
  `@tmux-2html-lang` option through to the renderer.
- **Foundation for the rest of milestone P1.M1.T1**: S2 builds the locale→BCP-47
  resolver, S3/S4 wire these parsed fields into `DocumentOpts`. None of that can
  land until the parse layer accepts the flags.
- **Default-unchanged invariant**: with null defaults, this change is invisible
  to existing callers and to the golden tests (which bypass the CLI), so it
  cannot regress current output.

## What

User-visible: `tmux-2html render --title "My Pane" --lang fr` (and the same two
flags on `pane` and `region`) now parse successfully instead of erroring with
`unknown or unexpected argument`. `sync-palette` continues to reject them.
`<subcommand> --help` lists the two new flags.

Technical requirements:
- The flags are **value-options** (each takes one argument), parsed identically to
  the existing `--font` branch.
- `--lang` is stored as an **opaque nullable string at the parse layer** — NO
  BCP-47 validation here (that is `resolveLang`'s job in S2). `--title` likewise
  stores any string (HTML escaping happens later in `render.zig`).
- `--title`/`--lang` must remain **off `sync-palette`** (it emits no HTML).

### Success Criteria

- [ ] `RenderOpts`, `PaneOpts`, `RegionOpts` each have `title: ?[]const u8 = null`
      and `lang: ?[]const u8 = null`.
- [ ] `parseRender`/`parsePane`/`parseRegion` accept `--title`/`--lang` and store
      the value; `--title=VAL` (equals form) also works (free via `requireValue`).
- [ ] `parseSyncPalette` STILL returns `error.UnknownFlag` for `--title`/`--lang`.
- [ ] `render_help`/`pane_help`/`region_help` each document `--title`/`--lang`;
      `sync_palette_help` and main.zig `usage_text` are UNCHANGED.
- [ ] Unit tests (TDD) cover: round-trip on all three subcommands, null defaults,
      missing-value error, and sync-palette rejection.
- [ ] `zig build test -Doptimize=ReleaseFast` exits 0.
- [ ] When neither flag is passed, behavior is identical to before (invariant).

## All Needed Context

### Context Completeness Check

_Pass: "If someone knew nothing about this codebase, would they have everything
needed to implement this successfully?"_ — Yes. Every edit is specified with its
exact structural anchor in `src/cli.zig`, the verbatim mirror pattern (the
existing `--font` branch), the verbatim new code to insert, the corrected help-text
location, ready-to-paste test code, and the verified test command. The implementer
edits ONE file (`src/cli.zig`) following the explicit `if/else if` chain pattern.

### Documentation & References

```yaml
# MUST READ - the gap analysis that defines this task's exact wiring
- file: plan/002_e3d8d22c088d/architecture/envelope_gap_analysis.md
  section: "§G1 (--title) and §G3 (--lang)"
  why: "Authoritative wiring map. §G1 says: add title to the three Opts + parse it mirroring --font. §G3 says: add lang the same way; --lang threads the @tmux-2html-lang tmux option."
  critical: "Both sections specify the exact branch: `} else if (flag.isLong(\"title\")) { opts.title = try requireValue(&parser); }`. Copy verbatim."

# MUST READ - the file being edited (read it first; anchors verified against HEAD)
- file: src/cli.zig
  why: "The ONLY file this task touches. Contains the Opts structs, parsers, requireValue helper, help constants, and unit tests."
  pattern: "Each parser is `pub fn parseX(args) ParseError!XOpts { var opts = XOpts{}; var parser = parg.parseSlice(args, .{}); defer parser.deinit(); while (parser.next()) |token| switch (token) { .flag => |flag| { if (...) ... else { return error.UnknownFlag; } }, .arg, .unexpected_value => return error.UnknownFlag } ...; return opts; }`"
  gotcha: "There are TWO UnknownFlag returns per parser. Insert the new branches before the one INSIDE the .flag arm (`else { return error.UnknownFlag; }`), NOT the switch-level `.arg, .unexpected_value => return error.UnknownFlag` line."

- file: plan/002_e3d8d22c088d/P1M1T1S1/research/findings.md
  why: "Companion note: exact line anchors, the contract-mislabel correction (help text in cli.zig not main.zig), the ReleaseFast test gotcha, backward-compat safety proof."
  critical: "Documents WHY `zig build test` alone fails (R_X86_64_PC64 Debug linker bug) and that ReleaseFast is mandatory."

- file: PRD.md
  section: "§8.1 (HTML document envelope, normative)"
  why: "Normative source: title 'Configurable via --title'; lang 'default en; configurable via @tmux-2html-lang / locale'. The --lang flag is the binary threading surface."

# READ for awareness of scope boundary (do NOT implement these here)
- file: src/render.zig
  section: "DocumentOpts at render.zig:187 (.lang already defaults \"en\"), writeDocument at render.zig:217"
  why: "Confirms the downstream target ALREADY EXISTS and needs no change in S1. S3/S4 wire opts.title/lang into DocumentOpts; S2 adds resolveLang. S1 does NOT touch render.zig."
```

### Current Codebase tree (relevant slice)

```bash
tmux-2html/
├── src/
│   ├── cli.zig          # <— THE FILE TO EDIT (Opts structs + parsers + help + tests)
│   ├── main.zig         # top-level usage_text (DO NOT EDIT — no per-subcommand flag list there)
│   ├── render.zig       # DocumentOpts/writeDocument (DO NOT EDIT — S3/S4 territory)
│   ├── region.zig       # (DO NOT EDIT — S4 territory)
│   └── ...
├── build.zig            # `zig build test` roots a test at src/main.zig's module (incl. cli.zig tests)
└── PRD.md
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
tmux-2html/
└── src/
    └── cli.zig          # MODIFIED IN PLACE — 3 structs gain title/lang fields;
                         #   3 parsers gain title/lang branches; 3 help constants
                         #   gain 2 lines each; +unit tests. NO new files. NO other files touched.
```

### Known Gotchas of our codebase & Library Quirks

```zig
// GOTCHA 1 — tests MUST run in ReleaseFast. `zig build test` (Debug) fails with
//   a known Zig 0.15.2 linker bug (R_X86_64_PC64 from bundled C++ SIMD libs),
//   NOT a code error. Always validate with:
//       zig build test -Doptimize=ReleaseFast
//   (plan/001.../findings_and_corrections.md §4, PRD §15.)

// GOTCHA 2 — the per-subcommand --help text is in cli.zig (render_help /
//   pane_help / region_help / sync_palette_help constants), NOT main.zig. The
//   item contract says "src/main.zig" — that is a MISLABEL. main.zig has only a
//   top-level usage_text with subcommand one-liners (no flag list). Edit cli.zig.

// GOTCHA 3 — two UnknownFlag returns per parser. Insert the new `--title`/`--lang`
//   branches before the flag-chain else INSIDE the `.flag => |flag| { ... }` arm
//   (`} else { return error.UnknownFlag; }`). Leave the switch-level
//   `.arg, .unexpected_value => return error.UnknownFlag,` line untouched.

// GOTCHA 4 — `requireValue` (cli.zig:~122) treats a value that looks like another
//   flag (len>1, leading '-') as error.MissingValue. So `--title --lang x` makes
//   --title error MissingValue (it does NOT swallow "--lang"). A lone "-" (stdin)
//   is allowed. Reuse requireValue verbatim — do NOT write a new helper.

// GOTCHA 5 — do NOT validate the --lang value at the parse layer. cli.zig stores
//   whatever string is given (like --font). BCP-47 / locale normalization is
//   resolveLang's job in S2. Storing it raw here is correct and intended.

// GOTCHA 6 — do NOT add --title/--lang to SyncPaletteOpts/parseSyncPalette.
//   sync-palette emits no HTML (PRD §5.4). The contract requires it stay OFF.
//   Add a test proving parseSyncPalette STILL returns error.UnknownFlag for them.

// GOTCHA 7 — adding defaulted fields (title/lang = null) is backward-compatible.
//   Every Opts literal in the codebase uses .{} or PARTIAL named-field init that
//   relies on defaults (verified: cli.zig parsers, main.zig + region.zig tests).
//   No full-field literal exists → nothing else needs updating.
```

## Implementation Blueprint

### Data models and structure

The three option structs gain two nullable, defaulted fields each. Place them at
the **end** of each struct (before the closing `};`), grouped with a one-line
comment citing PRD §8.1, so existing field order/comments are undisturbed.

```zig
// In RenderOpts  (cli.zig:59) — append after `selection: ?SelectionCoords = null,`:
    title: ?[]const u8 = null, // PRD §8.1: document <title> (--title; default derived in render.zig)
    lang: ?[]const u8 = null,  // PRD §8.1: <html lang> (--lang; resolved/normalized in render.zig S2)

// In PaneOpts    (cli.zig:70) — append after `open: bool = false,`:
    title: ?[]const u8 = null, // PRD §8.1
    lang: ?[]const u8 = null,  // PRD §8.1

// In RegionOpts  (cli.zig:81) — append after `open: bool = false,`:
    title: ?[]const u8 = null, // PRD §8.1
    lang: ?[]const u8 = null,  // PRD §8.1
```

(Placement at the end is a recommendation for minimal diff; Zig does not care
about field order. The nullable defaults are what guarantee the invariant.)

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: ADD title/lang fields to the three Opts structs (cli.zig)
  - EDIT RenderOpts  (anchor: `pub const RenderOpts = struct {`)   → append title + lang (code above)
  - EDIT PaneOpts    (anchor: `pub const PaneOpts = struct {`)     → append title + lang
  - EDIT RegionOpts  (anchor: `pub const RegionOpts = struct {`)   → append title + lang
  - DO NOT edit SyncPaletteOpts.
  - NAMING: `title` / `lang` (match the contract + §G1/G3). Type `?[]const u8`, default `null`.

Task 2: ADD the two parse branches to the three parsers (cli.zig)
  - In parseRender/parsePane/parseRegion, inside the `.flag => |flag| { if (...) ... }` chain,
    IMMEDIATELY BEFORE the final `} else { return error.UnknownFlag; }`, insert:
        } else if (flag.isLong("title")) {
            opts.title = try requireValue(&parser);
        } else if (flag.isLong("lang")) {
            opts.lang = try requireValue(&parser);
  - FOLLOW pattern: the existing `--font` branch (`} else if (flag.isLong("font")) { opts.font = try requireValue(&parser); }`).
  - NAMING: `flag.isLong("title")` / `flag.isLong("lang")` (long flags; no short forms per PRD §5).
  - DO NOT add these branches to parseSyncPalette (it must keep rejecting them).
  - DEPENDENCIES: Task 1 (opts.title / opts.lang fields must exist).

Task 3: UPDATE the per-subcommand --help text (cli.zig, NOT main.zig — see Gotcha 2)
  - In render_help (anchor: `const render_help =`): add two lines to the Options list:
        \\  --title TITLE       document <title> (default: "tmux-2html" or derived)
        \\  --lang LANG         document lang, BCP-47 (default: en / locale)
    Place them right after the `--font FAMILY` line for logical grouping; MATCH the
    existing column alignment (flag column ~20 chars, then description).
  - Repeat the SAME two lines in pane_help and region_help.
  - DO NOT edit sync_palette_help (no HTML output) or main.zig usage_text (top-level only).
  - DEPENDENCIES: none (independent of Tasks 1–2 but ships together).

Task 4: ADD/AUGMENT unit tests (TDD — cli.zig, `// ---- Unit tests ----` section)
  - AUGMENT the existing `test "parseRender: defaults"`: assert title/lang are null:
        try std.testing.expectEqual(@as(?[]const u8, null), opts.title);
        try std.testing.expectEqual(@as(?[]const u8, null), opts.lang);
    (and likewise add the same two assertions to `parsePane`/`parseRegion` defaults tests, or
     add small defaults checks if none exist for those subcommands.)
  - CREATE round-trip tests (follow the `test "parseRender: all options"` style):
        test "parseRender: --title and --lang" {
            const opts = try parseRender(&[_][]const u8{ "--title", "My Pane", "--lang", "fr" });
            try std.testing.expectEqualStrings("My Pane", opts.title.?);
            try std.testing.expectEqualStrings("fr", opts.lang.?);
        }
        test "parsePane: --title and --lang" {
            const opts = try parsePane(&[_][]const u8{ "--target", "%5", "--title", "T", "--lang", "en-US" });
            try std.testing.expectEqualStrings("T", opts.title.?);
            try std.testing.expectEqualStrings("en-US", opts.lang.?);
        }
        test "parseRegion: --title and --lang" {
            const opts = try parseRegion(&[_][]const u8{ "--title", "R", "--lang", "de" });
            try std.testing.expectEqualStrings("R", opts.title.?);
            try std.testing.expectEqualStrings("de", opts.lang.?);
        }
  - CREATE negative/error tests:
        test "parseRender: --title missing value" {
            try std.testing.expectError(error.MissingValue, parseRender(&[_][]const u8{"--title"}));
            // flag-like value is treated as missing (requireValue gotcha):
            try std.testing.expectError(error.MissingValue, parseRender(&[_][]const u8{ "--title", "--lang", "x" }));
        }
        test "parseRender: --lang missing value" {
            try std.testing.expectError(error.MissingValue, parseRender(&[_][]const u8{"--lang"}));
        }
  - CREATE the sync-palette-still-rejects test (enforces Gotcha 6 / contract):
        test "parseSyncPalette: rejects --title and --lang" {
            try std.testing.expectError(error.UnknownFlag, parseSyncPalette(&[_][]const u8{ "--title", "x" }));
            try std.testing.expectError(error.UnknownFlag, parseSyncPalette(&[_][]const u8{ "--lang", "en" }));
        }
  - FOLLOW pattern: existing `test "parseRender: ..."` blocks (bufPrint-free, direct expectEqual/expectError).
  - NAMING: `test "<fn>: <scenario>"`.
  - COVERAGE: round-trip (×3) + null defaults + missing-value (×2) + sync-palette rejection.
  - PLACEMENT: alongside the existing `parseRender`/`parsePane`/`parseRegion`/`parseSyncPalette` tests.
  - DEPENDENCIES: Tasks 1+2 (fields + branches must exist for the tests to compile/pass).

Task 5: VALIDATE  (see Validation Loop)
  - RUN: zig build test -Doptimize=ReleaseFast   → expect exit 0
  - RUN: ./zig-out/bin/tmux-2html render --help  (after `zig build --release=fast`) → eyeball new lines
```

### Implementation Patterns & Key Details

```zig
// PATTERN: the exact parse-branch edit (mirror of --font). Drop into the existing
// if/else-if chain in parseRender / parsePane / parseRegion, right before its `else`:
            } else if (flag.isLong("title")) {
                opts.title = try requireValue(&parser);
            } else if (flag.isLong("lang")) {
                opts.lang = try requireValue(&parser);
            } else {
                return error.UnknownFlag;
            }

// PATTERN: requireValue is reused as-is (cli.zig:~122). It already handles both
// `--name value` and `--name=value`, and rejects flag-like values as MissingValue.

// CRITICAL: NO new ParseError variant is needed. `--title`/`--lang` cannot fail
// beyond MissingValue/UnknownFlag, both of which already exist and are already
// reported by reportError(). Do not touch ParseError / reportError().

// CRITICAL: NO validation of the lang value here. `--lang "xyz"` parses fine;
// resolveLang (S2) decides validity. cli.zig is intentionally permissive.
```

### Integration Points

```yaml
STRUCTS:
  - RenderOpts  (+title, +lang)  → consumed by render_mod.run via cli.render (S3 wires them)
  - PaneOpts    (+title, +lang)  → consumed by pane body fn (main.zig, S4 wires them)
  - RegionOpts  (+title, +lang)  → consumed by region body fn (region.zig, S4 wires them)

DOWNSTREAM (NOT this task — do not implement):
  - S2: render.zig resolveLang(opts.lang) + langFromEnv()
  - S3: render.zig run() → DocumentOpts{ .title = opts.title orelse "tmux-2html", .lang = resolveLang(opts.lang), ... }
  - S4: main.zig pane + region.zig honor opts.title override + resolveLang(opts.lang)
  - P1.M1.T2.S1: tmux-2html.tmux passes --title/--lang from @tmux-2html-title/@tmux-2html-lang

CONFIG / DATABASE / ROUTES:
  - none (pure parse-layer change; no I/O, no env, no files).
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Zig compiles-on-save conceptually; there is no separate linter. The build is the check.
# Sanity: the file still parses (catches a malformed struct/parser edit fast):
zig build test -Doptimize=ReleaseFast 2>&1 | head -20
# Expected: compiles. If you see `error: ...` referencing cli.zig lines, fix the edit shape first.
```

### Level 2: Unit Tests (Component Validation)

```bash
# PRIMARY GATE — ReleaseFast is MANDATORY (Gotcha 1: Debug hits the R_X86_64_PC64 linker bug).
zig build test -Doptimize=ReleaseFast
# Expected: exit 0. The new tests (parseRender/parsePane/parseRegion --title/--lang round-trips,
# null defaults, missing-value errors, and parseSyncPalette rejection) all pass.
#
# NOTE: `zig build test` WITHOUT -Doptimize=ReleaseFast will FAIL with a linker error
# that is unrelated to your code — do not be fooled (see Gotcha 1).
```

### Level 3: Integration Testing (System Validation)

```bash
# Build the real binary (optimized) and eyeball the new --help lines on each subcommand:
zig build --release=fast
./zig-out/bin/tmux-2html render --help | grep -E '\-\-title|\-\-lang'   # expect BOTH lines
./zig-out/bin/tmux-2html pane   --help | grep -E '\-\-title|\-\-lang'   # expect BOTH lines
./zig-out/bin/tmux-2html region --help | grep -E '\-\-title|\-\-lang'   # expect BOTH lines
./zig-out/bin/tmux-2html sync-palette --help | grep -E '\-\-title|\-\-lang'  # expect NOTHING (off sync-palette)

# Confirm the flags are now ACCEPTED (previously "unknown argument") and the OFF-sync-palette rule:
echo '' | ./zig-out/bin/tmux-2html render --title "T" --lang en 2>&1 | head -3   # no usage error
./zig-out/bin/tmux-2html sync-palette --title x 2>&1 | head -2                    # "unknown or unexpected argument", exit 1
./zig-out/bin/tmux-2html sync-palette --lang en 2>&1 | head -2; echo "exit=$?"    # exit 1 (rejected)

# Expected: render/pane/region accept the flags; sync-palette rejects both; --help shows the lines.
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Regression guard: confirm the default-unchanged invariant. With NO new flags,
# `render` output must be byte-identical to before this change (title/lang null ⇒
# DocumentOpts still gets its defaults in S3/S4 which are unchanged today).
# (Optional — only meaningful once S3/S4 wire the flags; for S1, just confirm
#  `echo '' | zig-out/bin/tmux-2html render` still exits 0 and emits a doc.)
echo '' | ./zig-out/bin/tmux-2html render >/dev/null; echo "render no-flags exit=$?"  # expect 0

# Negative parse: a flag-like value must NOT be swallowed as a title (requireValue gotcha):
echo '' | ./zig-out/bin/tmux-2html render --title --lang en 2>&1 | head -1   # "missing value for option", exit 1
```

## Final Validation Checklist

### Technical Validation

- [ ] `zig build test -Doptimize=ReleaseFast` exits 0 (Level 2 — primary gate).
- [ ] All new/augmented cli.zig unit tests pass (round-trips ×3, defaults null, missing-value, sync-palette rejection).
- [ ] `zig build --release=fast` succeeds; binary runs.

### Feature Validation

- [ ] `RenderOpts`/`PaneOpts`/`RegionOpts` have nullable defaulted `title`/`lang`.
- [ ] `parseRender`/`parsePane`/`parseRegion` accept `--title`/`--lang` (space and `=value` forms).
- [ ] `parseSyncPalette` STILL returns `error.UnknownFlag` for `--title`/`--lang`.
- [ ] `render_help`/`pane_help`/`region_help` list `--title`/`--lang`; `sync_palette_help` does not.
- [ ] main.zig `usage_text` is UNCHANGED (corrected contract mislabel).
- [ ] Default-unchanged invariant holds (null when flags absent).

### Code Quality Validation

- [ ] New branches mirror the existing `--font` branch exactly (no new helper, no new error variant).
- [ ] `requireValue` reused as-is (Gotcha 4 honored; flag-like value ⇒ MissingValue).
- [ ] No lang-value validation at the parse layer (deferred to S2 resolveLang).
- [ ] No edits to render.zig, region.zig, main.zig, or any other file (cli.zig only).
- [ ] Field placement keeps existing comments/order intact.

### Documentation & Deployment

- [ ] Per-subcommand `--help` accurately documents the new flags (Mode A docs ride with this task).
- [ ] No new env vars / config (pure parse-layer change).

---

## Anti-Patterns to Avoid

- ❌ Don't run plain `zig build test` — it fails on the Debug linker bug
  (`R_X86_64_PC64`). Use `zig build test -Doptimize=ReleaseFast`.
- ❌ Don't edit main.zig for the per-subcommand help text — that's a contract
  mislabel. The `*_help` constants are in **cli.zig**. main.zig's `usage_text` is
  top-level and stays untouched.
- ❌ Don't add `--title`/`--lang` to `SyncPaletteOpts`/`parseSyncPalette` —
  sync-palette emits no HTML; it must keep rejecting them (add a test for it).
- ❌ Don't validate/normalize the `--lang` value in cli.zig — that's `resolveLang`
  (S2). Store it raw, like `--font`.
- ❌ Don't introduce a new `ParseError` variant or touch `reportError()` — the
  flags only ever fail with the existing `MissingValue`/`UnknownFlag`.
- ❌ Don't wire the fields into `DocumentOpts` / render.zig / region.zig / main.zig
  here — that's S3/S4. S1 is parse-layer + help + tests only.
- ❌ Don't break the default-unchanged invariant — new fields MUST default to `null`
  so existing callers and golden tests are unaffected.

---

**Confidence Score: 10/10** for one-pass implementation success.

Every edit is pinned to a verified structural anchor in `src/cli.zig` (struct
names, parser names, the exact `--font` branch to mirror, the exact flag-chain
`else` insertion point). The contract's two inaccuracies — the help-text file
mislabel (cli.zig, not main.zig) and the implicit `zig build test` assumption
(Debug fails; ReleaseFast required) — are both caught and corrected from
empirical runs against the real Zig 0.15.2 toolchain. The change is backward-
compatible (all Opts literals use defaults), confined to one file, and fully
test-specified with ready-to-paste TDD cases. Scope is cleanly bounded from
sibling tasks S2/S3/S4 and the plugin task P1.M1.T2.S1.
