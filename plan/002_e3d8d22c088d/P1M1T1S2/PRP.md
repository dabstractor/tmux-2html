# PRP — P1.M1.T1.S2: Pure locale→BCP-47 lang resolver (`langFromEnv` / `resolveLang`) + unit tests

## Goal

**Feature Goal**: Add a pure, deterministic, allocation-free POSIX-locale →
BCP-47 language-tag resolver to `src/render.zig` (next to `DocumentOpts`) that
derives the PRD §8.1 `<html lang>` value, so downstream tasks (S3 `render.run`,
S4 `pane`/`region`) can call `resolveLang(opts.lang)` to populate `DocumentOpts.lang`.

**Deliverable**: A self-contained, purely ADDITIVE edit to **`src/render.zig`
only** — four new functions plus their unit tests, placed after the `DocumentOpts`
struct. No other file changes. No wiring into `DocumentOpts` construction yet
(that is S3). The four functions:
1. `fn toBcp47(locale: []const u8) ?[]const u8` — pure POSIX→BCP-47 transform.
2. `fn langFromEnvStrings(lc_all, lc_messages, lang: ?[]const u8) []const u8` — pure precedence resolver (testable core).
3. `pub fn langFromEnv() []const u8` — thin wrapper reading `std.posix.getenv`.
4. `pub fn resolveLang(explicit: ?[]const u8) []const u8` — explicit-or-locale-or-`en`.

**Success Definition**: `zig build test -Doptimize=ReleaseFast` exits 0 with the
new tests green (TDD cases from the contract all pass); existing 22 render.zig
tests and goldens remain unchanged (additive-only edit); `resolveLang`/`langFromEnv`
are `pub` and available for S3/S4 to consume.

## User Persona

**Target User**: Downstream implementers (S3 `render.run`, S4 `pane`/`region`) who
need a stable `resolveLang(opts.lang) []const u8` to set `DocumentOpts.lang`.

**Use Case**: `DocumentOpts{ .title = ..., .lang = resolveLang(opts.lang), ... }`
yields a valid BCP-47 tag — from `--lang`/`@tmux-2html-lang` if given, else from
the `LC_ALL`→`LC_MESSAGES`→`LANG` locale, else `"en"`.

**Pain Points Addressed**: Removes the hard-coded `"en"` default's locale
blindness (PRD §8.1: lang is "default `en`; configurable via
`@tmux-2html-lang` / locale") without any `/dev/tty` or allocation.

## Why

- **PRD §8.1 (normative)** requires `<html lang>` to be "default `en`;
  configurable via `@tmux-2html-lang` / locale". This task implements that
  resolution algorithm. The `--lang` flag (S1) and `@tmux-2html-lang` plugin
  option (P1.M1.T2.S1) both thread through `resolveLang`.
- **Foundation for S3/S4**: those tasks wire `opts.lang` into `DocumentOpts`; they
  need a finished, tested resolver with a stable signature. S2 delivers exactly
  that and nothing more (no behavior change until S3 calls it).
- **Additive = safe**: S2 adds functions + tests only. It does not touch the
  single existing `DocumentOpts{...}` construction (render.zig:636) or any
  rendering path, so goldens and current output are provably unaffected.

## What

Four new functions in `src/render.zig` implementing the algorithm in
`architecture/lang_resolution.md`:

- **`toBcp47(locale)`**: strip `.codeset` (from first `.`) and `@modifier` (from
  first `@`); split lang/region on the first `_` or `-`; lowercase the language
  subtag (validate 2–3 chars, `a–z`); uppercase the region subtag if present
  (validate exactly 2 chars, `A–Z`, no embedded separator); write the result into
  a module-level buffer; return the slice, or `null` if anything fails.
- **`langFromEnvStrings(lc_all, lc_messages, lang)`**: first non-empty candidate
  (LC_ALL → LC_MESSAGES → LANG) wins; transform it; on transform failure fall
  directly to `"en"` (no cascade); if all unset/empty, `"en"`.
- **`langFromEnv()`**: delegate to `langFromEnvStrings` with `std.posix.getenv`
  values for `LC_ALL`/`LC_MESSAGES`/`LANG`.
- **`resolveLang(explicit)`**: `if (explicit) |e| toBcp47(e) orelse "en" else langFromEnv()`.

NO `/dev/tty`. NO allocation (module-level static buffer). NO changes outside
render.zig. NO wiring into `DocumentOpts` (S3).

### Success Criteria

- [ ] `toBcp47`, `langFromEnvStrings` are private fns; `langFromEnv`, `resolveLang` are `pub`.
- [ ] TDD cases pass: `en_US.UTF-8`→`en-US`; `pt_BR.UTF-8`→`pt-BR`;
      `de_DE@euro`→`de-DE`; `zh_CN`→`zh-CN`; `C`/`POSIX`/`C.UTF-8`/empty→`en`
      (null internally); unset→`en`; explicit-invalid→`en`; explicit wins.
- [ ] `zig build test -Doptimize=ReleaseFast` exits 0; existing 22 tests still pass.
- [ ] Only `src/render.zig` is modified; no other file touched.

## All Needed Context

### Context Completeness Check

_Pass: "If someone knew nothing about this codebase, would they have everything
needed to implement this successfully?"_ — Yes. The verbatim, exit-0-verified
function bodies and the verbatim passing test code are below. Exact placement
anchors (after `DocumentOpts` line 192; tests at EOF) are given. Every gotcha —
the static-buffer strategy (why in-place/stack are unsafe), the no-cascade
precedence, the ReleaseFast test requirement, the `.link_libc=false` no-setenv
testability split — is documented with rationale.

### Documentation & References

```yaml
# MUST READ — the authoritative algorithm + sources
- file: plan/002_e3d8d22c088d/architecture/lang_resolution.md
  why: "Defines precedence (LC_ALL→LC_MESSAGES→LANG→en), the to_bcp47 transform steps, the edge-case table, and the .link_libc=false testability split."
  critical: "Specifies the pure-strings-fn + thin-env-wrapper split (no setenv under link_libc=false) and 'prefer no alloc'. This PRP resolves the 'how' (static buffer)."

# MUST READ — companion empirical verification (this PRP's evidence base)
- file: plan/002_e3d8d22c088d/P1M1T1S2/research/findings.md
  why: "Records the 27/27-test verification, the rejected in-place/stack strategies, the no-cascade decision, and the exact render.zig anchors."
  critical: "§2 (why static buffer, not in-place/stack) and §8 (ReleaseFast mandatory for the project test step)."

# MUST READ — the file being edited (read it first; anchors verified against HEAD)
- file: src/render.zig
  section: "DocumentOpts at :187-192; writeEscaped at :196; getenv pattern at :565; DocumentOpts{} at :636; tests :803-1340"
  why: "The ONLY file this task touches. Insert the 4 fns after DocumentOpts (:192); append tests at EOF (:1341)."
  pattern: "Tests are inline `test \"<fn>: <scenario>\" { ... }`. The getenv pattern `std.posix.getenv(\"X\") orelse \"...\"` at :565 is reused."
  gotcha: "Do NOT modify the DocumentOpts{} literal at :636 — wiring .lang is S3. S2 is additive only."

# INPUT CONTRACT — S1 (parallel) adds the raw --lang flag S2 will later resolve
- file: plan/002_e3d8d22c088d/P1M1T1S1/PRP.md
  why: "S1 makes cli.zig store --lang as a raw ?[]const u8 (no validation). S2's resolveLang(opts.lang) is the consumer signature S3/S4 call. S2 does NOT touch cli.zig."
  pattern: "RenderOpts/PaneOpts/RegionOpts gain `lang: ?[]const u8 = null`. resolveLang takes exactly that type."

# PRD normative source
- file: PRD.md
  section: "§8.1 (HTML document envelope — 'lang default en; configurable via @tmux-2html-lang / locale')"
  why: "Normative requirement this implements."

# Zig 0.15.2 std source (authoritative for API signatures)
- file: /home/dustin/.local/opt/zig-x86_64-linux-0.15.2/lib/std/ascii.zig
  why: "toLower (:191) / toUpper (:185) — only A-Z/Z-a change; digits/symbols pass through (so the post-case letter check rejects non-letters)."
- file: /home/dustin/.local/opt/zig-x86_64-linux-0.15.2/lib/std/mem.zig
  why: "indexOfScalar (:1244) — for the .codeset/@modifier strip."
```

### Current Codebase tree (relevant slice)

```bash
tmux-2html/
├── src/
│   ├── render.zig        # <— THE FILE TO EDIT (additive: 4 fns + tests after DocumentOpts)
│   ├── cli.zig           # S1 adds --lang here (DO NOT EDIT in S2)
│   ├── main.zig          # S4 territory (DO NOT EDIT)
│   ├── region.zig        # S4 territory (DO NOT EDIT)
│   └── ...
├── build.zig             # `zig build test` roots a test at src/main.zig's module (picks up render.zig tests)
└── PRD.md
```

### Desired Codebase tree with files to be added/changed

```bash
tmux-2html/
└── src/
    └── render.zig        # MODIFIED IN PLACE — +4 fns (after DocumentOpts :192) + ~15 unit tests (at EOF).
                          #   NO new files. NO other files touched. NO wiring change.
```

### Known Gotchas of our codebase & Library Quirks

```zig
// GOTCHA 1 — tests MUST run in ReleaseFast. `zig build test` (Debug) fails with a
//   known Zig 0.15.2 linker bug (R_X86_64_PC64) from ghostty-vt's bundled C++ SIMD
//   libs — NOT a code error. The project test binary links ghostty-vt (it is rooted
//   at src/main.zig), so Debug fails. Always validate with:
//       zig build test -Doptimize=ReleaseFast
//   (plan/001 findings_and_corrections.md §4, PRD §15, S1's PRP gotcha 1.)

// GOTCHA 2 — use a MODULE-LEVEL STATIC buffer, NOT in-place mutation, NOT a stack buffer.
//   toBcp47 takes []const u8 (immutable). Callers pass env strings (getenv returns const)
//   or, in tests, string literals (".rodata" — read-only). @constCast mutation => UB/segfault.
//   A stack-local [N]u8 returned by slice => dangling pointer (frame gone).
//   => `var bcp47_buf: [16]u8 = undefined;` at module scope. It outlives the call; no alloc.
//   CAVEAT: overwritten each call. resolveLang/langFromEnv are called ONCE per render and
//   the result is stored into DocumentOpts.lang and consumed during that single writeDocument,
//   so no aliasing occurs. In TESTS, check each result BEFORE calling toBcp47 again
//   (holding two returned slices simultaneously aliases them — see Anti-Patterns).

// GOTCHA 3 — precedence does NOT cascade. First NON-EMPTY candidate (LC_ALL→LC_MESSAGES→LANG)
//   wins; if its toBcp47 returns null, fall DIRECTLY to "en" (do NOT try the next candidate).
//   POSIX: "LC_ALL (non-empty) overrides everything"; LC_ALL=C is an explicit choice => en.
//   (Contract TDD cases don't test cascade; non-cascade is simplest + POSIX-faithful.)

// GOTCHA 4 — C/POSIX/empty need NO special-case branch. They fail the language-subtag
//   length check (C=1 char, POSIX=5, ""=0 all violate the 2..3 rule) => null naturally.
//   Don't add `if (std.mem.eql(... "C"))` guards — redundant.

// GOTCHA 5 — under .link_libc=false there is NO setenv. So langFromEnv() (reads real env)
//   is NOT unit-testable deterministically. The pure core is langFromEnvStrings(... params)
//   which tests drive with string literals. langFromEnv is a 1-line getenv wrapper. This split
//   is mandated by the architecture doc and is why the param-taking fn exists.

// GOTCHA 6 — std.posix.getenv returns ?[:0]const u8 (sentinel-terminated) which coerces to
//   ?[]const u8 (the param type). No manual conversion needed. Same call render.zig:565 uses.

// GOTCHA 7 — S2 is ADDITIVE. Do NOT touch the DocumentOpts{} literal at render.zig:636
//   (.lang defaults "en" there today). Wiring .lang = resolveLang(opts.lang) is S3. Touching
//   it now would change goldens prematurely and collide with S3. Leave it.
```

## Implementation Blueprint

### Data models and structure

No new types. The resolver produces a `[]const u8` consumed by the existing
`DocumentOpts.lang: []const u8` field (render.zig:189, default `"en"`). A single
module-level buffer backs the no-alloc returns.

### The exact deliverable — verbatim code (exit-0 verified, 27/27 tests)

Insert this block into `src/render.zig` **immediately after the `DocumentOpts`
struct's closing `};` (line 192)**, before `fn writeEscaped` (line 196). Add a
section banner comment so it reads as one unit.

```zig
// ---------------------------------------------------------------------------
// Lang resolution (PRD §8.1 <html lang>; algorithm: architecture/lang_resolution.md).
// POSIX locale name -> BCP-47 tag. Precedence: explicit --lang / @tmux-2html-lang
// -> LC_ALL -> LC_MESSAGES -> LANG -> "en". Allocation-free (module-level buffer).
// ---------------------------------------------------------------------------

/// Output buffer for a normalized BCP-47 tag. Overwritten on each call; safe because
/// toBcp47/langFromEnv/resolveLang are each called once per render and the result is
/// stored into DocumentOpts.lang and consumed during that single writeDocument.
/// (A normalized tag is at most 6 chars — `xxx-XX` — so [16] is generous.)
var bcp47_buf: [16]u8 = undefined;

/// Pure POSIX-locale -> BCP-47 transform. Strips `.codeset` (from first '.') and
/// `@modifier` (from first '@'), maps `_`->`-`, lowercases the language subtag,
/// uppercases the region subtag, and validates against `^[a-z]{2,3}(-[A-Z]{2})?$`.
/// Returns null for C/POSIX/empty/invalid shapes; the caller falls back to "en".
/// PURE (no I/O, no alloc) -> unit-testable; does NOT mutate its input.
fn toBcp47(locale: []const u8) ?[]const u8 {
    var s = locale;
    if (std.mem.indexOfScalar(u8, s, '.')) |i| s = s[0..i]; // strip .codeset
    if (std.mem.indexOfScalar(u8, s, '@')) |i| s = s[0..i]; // strip @modifier

    // First '_' or '-' separates language from territory.
    var sep_idx: ?usize = null;
    for (s, 0..) |c, i| if (c == '_' or c == '-') {
        sep_idx = i;
        break;
    };

    const lang_src = if (sep_idx) |i| s[0..i] else s;
    const region_src: ?[]const u8 = blk: {
        if (sep_idx) |i| {
            if (i + 1 >= s.len) break :blk null; // trailing separator, no region
            break :blk s[i + 1 ..];
        } else break :blk null;
    };

    // Language subtag: 2-3 lowercase a-z.
    if (lang_src.len < 2 or lang_src.len > 3) return null;
    var out_len: usize = 0;
    for (lang_src) |c| {
        const lc = std.ascii.toLower(c);
        if (lc < 'a' or lc > 'z') return null;
        bcp47_buf[out_len] = lc;
        out_len += 1;
    }

    // Region subtag (optional): exactly 2 uppercase A-Z, no embedded separator.
    if (region_src) |r| {
        if (r.len != 2) return null;
        if (r[0] == '_' or r[0] == '-' or r[1] == '_' or r[1] == '-') return null;
        bcp47_buf[out_len] = '-';
        out_len += 1;
        for (r) |c| {
            const uc = std.ascii.toUpper(c);
            if (uc < 'A' or uc > 'Z') return null;
            bcp47_buf[out_len] = uc;
            out_len += 1;
        }
    }

    return bcp47_buf[0..out_len];
}

/// Pure precedence resolver (LC_ALL -> LC_MESSAGES -> LANG -> "en"). Set-but-EMPTY
/// values count as unset (POSIX override semantics). The first non-empty candidate
/// wins; if its transform fails, fall directly to "en" (no cascade — POSIX: LC_ALL
/// overrides everything). Param-taking so it is deterministic & unit-testable.
fn langFromEnvStrings(lc_all: ?[]const u8, lc_messages: ?[]const u8, lang: ?[]const u8) []const u8 {
    if (lc_all) |v| if (v.len > 0) return toBcp47(v) orelse "en";
    if (lc_messages) |v| if (v.len > 0) return toBcp47(v) orelse "en";
    if (lang) |v| if (v.len > 0) return toBcp47(v) orelse "en";
    return "en";
}

/// Locale-only resolution (precedence + transform + fallback). Reads the process
/// environment via std.posix.getenv (same pattern as tempHtmlPath at :565). NO /dev/tty.
pub fn langFromEnv() []const u8 {
    return langFromEnvStrings(
        std.posix.getenv("LC_ALL"),
        std.posix.getenv("LC_MESSAGES"),
        std.posix.getenv("LANG"),
    );
}

/// Resolve the <html lang> value (PRD §8.1). Explicit --lang / @tmux-2html-lang
/// wins; an explicit invalid value (e.g. "C", "english") degrades defensively to
/// "en". Otherwise derive from the locale; else "en".
pub fn resolveLang(explicit: ?[]const u8) []const u8 {
    if (explicit) |e| return toBcp47(e) orelse "en";
    return langFromEnv();
}
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: INSERT the 4 lang-resolution functions into src/render.zig
  - ANCHOR: immediately AFTER the DocumentOpts struct's closing `};` (render.zig:192),
            BEFORE `fn writeEscaped` (render.zig:196).
  - CONTENT: the verbatim block above (bcp47_buf + toBcp47 + langFromEnvStrings + langFromEnv + resolveLang).
  - VISIBILITY: toBcp47 + langFromEnvStrings are private `fn`; langFromEnv + resolveLang are `pub fn`.
  - NAMING: exactly toBcp47 / langFromEnvStrings / langFromEnv / resolveLang (contract + downstream S3/S4 depend on these names).
  - DO NOT modify DocumentOpts (already has lang:"en"), writeEscaped, or the DocumentOpts{} literal at :636.
  - WHY FIRST: tests (Task 2) reference these symbols.

Task 2: APPEND the unit tests to src/render.zig (TDD)
  - ANCHOR: end of file (render.zig is 1341 lines; last test ends ~:1340). Append after it.
  - CONTENT: the verbatim tests below. Follow the existing `test "<fn>: <scenario>"` naming.
  - COVERAGE: toBcp47 (valid + case-norm + already-BCP47 + 3-letter-lang + all-null cases),
              langFromEnvStrings (precedence + empty-as-unset + invalid-fallback), resolveLang (explicit wins/normalized/C/invalid/null).
  - GOTCHA: check each toBcp47 result IMMEDIATELY (static buffer aliases on next call — see Gotcha 2).
  - DO NOT add a deterministic test for langFromEnv() itself (reads real env; not deterministic — Gotcha 5).
            The resolveLang(null) test only asserts non-empty (host-env-dependent).
  - DEPENDENCIES: Task 1.

Task 3: VALIDATE  (see Validation Loop)
  - RUN: zig build test -Doptimize=ReleaseFast   → expect exit 0, all tests pass
```

### The exact tests — verbatim (append at EOF; these are the verified passing set)

```zig
// ---- Lang resolution unit tests (PRD §8.1; architecture/lang_resolution.md) ----

test "toBcp47: en_US.UTF-8 -> en-US" {
    try std.testing.expectEqualStrings("en-US", toBcp47("en_US.UTF-8").?);
}
test "toBcp47: pt_BR.UTF-8 -> pt-BR" {
    try std.testing.expectEqualStrings("pt-BR", toBcp47("pt_BR.UTF-8").?);
}
test "toBcp47: de_DE@euro -> de-DE" {
    try std.testing.expectEqualStrings("de-DE", toBcp47("de_DE@euro").?);
}
test "toBcp47: zh_CN -> zh-CN" {
    try std.testing.expectEqualStrings("zh-CN", toBcp47("zh_CN").?);
}
test "toBcp47: plain lang en -> en" {
    try std.testing.expectEqualStrings("en", toBcp47("en").?);
}
test "toBcp47: case normalization en_us -> en-US" {
    try std.testing.expectEqualStrings("en-US", toBcp47("en_us").?);
}
test "toBcp47: already BCP-47 en-US -> en-US" {
    try std.testing.expectEqualStrings("en-US", toBcp47("en-US").?);
}
test "toBcp47: 3-letter lang eng_GB -> eng-GB" {
    try std.testing.expectEqualStrings("eng-GB", toBcp47("eng_GB").?);
}
test "toBcp47: C -> null" {
    try std.testing.expectEqual(@as(?[]const u8, null), toBcp47("C"));
}
test "toBcp47: POSIX -> null" {
    try std.testing.expectEqual(@as(?[]const u8, null), toBcp47("POSIX"));
}
test "toBcp47: C.UTF-8 -> null" {
    try std.testing.expectEqual(@as(?[]const u8, null), toBcp47("C.UTF-8"));
}
test "toBcp47: empty -> null" {
    try std.testing.expectEqual(@as(?[]const u8, null), toBcp47(""));
}
test "toBcp47: too-long lang english -> null" {
    try std.testing.expectEqual(@as(?[]const u8, null), toBcp47("english"));
}
test "toBcp47: 1-char lang e_US -> null" {
    try std.testing.expectEqual(@as(?[]const u8, null), toBcp47("e_US"));
}
test "toBcp47: 3-char region en_USA -> null" {
    try std.testing.expectEqual(@as(?[]const u8, null), toBcp47("en_USA"));
}

test "langFromEnvStrings: LC_ALL wins over LC_MESSAGES and LANG" {
    try std.testing.expectEqualStrings("en-US", langFromEnvStrings("en_US.UTF-8", "pt_BR.UTF-8", "de_DE"));
}
test "langFromEnvStrings: LC_MESSAGES when LC_ALL null" {
    try std.testing.expectEqualStrings("pt-BR", langFromEnvStrings(null, "pt_BR.UTF-8", "de_DE"));
}
test "langFromEnvStrings: LANG when LC_ALL and LC_MESSAGES null" {
    try std.testing.expectEqualStrings("de-DE", langFromEnvStrings(null, null, "de_DE@euro"));
}
test "langFromEnvStrings: all null -> en" {
    try std.testing.expectEqualStrings("en", langFromEnvStrings(null, null, null));
}
test "langFromEnvStrings: empty treated as unset -> en" {
    try std.testing.expectEqualStrings("en", langFromEnvStrings("", "", ""));
}
test "langFromEnvStrings: LC_ALL=C (invalid, no cascade) -> en" {
    try std.testing.expectEqualStrings("en", langFromEnvStrings("C", "en_US.UTF-8", "en_US.UTF-8"));
}

test "resolveLang: explicit valid wins over locale" {
    try std.testing.expectEqualStrings("fr", resolveLang("fr"));
}
test "resolveLang: explicit locale normalized" {
    try std.testing.expectEqualStrings("en-US", resolveLang("en_US.UTF-8"));
}
test "resolveLang: explicit C -> en" {
    try std.testing.expectEqualStrings("en", resolveLang("C"));
}
test "resolveLang: explicit invalid -> en" {
    try std.testing.expectEqualStrings("en", resolveLang("english"));
}
test "resolveLang: explicit null falls to env (non-empty result)" {
    // langFromEnv() reads the real host env (not deterministic); just assert validity.
    const got = resolveLang(null);
    try std.testing.expect(got.len > 0);
}
```

### Implementation Patterns & Key Details

```zig
// PATTERN: pure transform into a module-level buffer (no alloc, no input mutation).
fn toBcp47(locale: []const u8) ?[]const u8 {
    var s = locale;
    if (std.mem.indexOfScalar(u8, s, '.')) |i| s = s[0..i]; // strip .codeset
    if (std.mem.indexOfScalar(u8, s, '@')) |i| s = s[0..i]; // strip @modifier
    // ... find first '_'/'-', validate+normalize lang (2-3 lc a-z) and region (2 uc A-Z)
    // ... into bcp47_buf, return bcp47_buf[0..out_len].
}

// PATTERN: env-probing split for testability (.link_libc=false has no setenv).
fn langFromEnvStrings(lc_all, lc_messages, lang: ?[]const u8) []const u8 { ... } // pure, tested
pub fn langFromEnv() []const u8 {                                    // thin wrapper
    return langFromEnvStrings(std.posix.getenv("LC_ALL"), std.posix.getenv("LC_MESSAGES"), std.posix.getenv("LANG"));
}

// CRITICAL: no cascade. `toBcp47(v) orelse "en"` returns "en" immediately on failure;
// do NOT write a loop that tries lc_all then lc_messages then lang on transform failure.

// CRITICAL: toBcp47 must NOT @constCast its input — string-literal test inputs are
// read-only. All normalization writes go to bcp47_buf, never back to `locale`.
```

### Integration Points

```yaml
THIS TASK (additive, no integration yet):
  - src/render.zig: +4 fns after DocumentOpts (:192), +tests at EOF. Nothing else.

DOWNSTREAM (NOT this task — do not implement):
  - S3: render.run — change render.zig:636 area to DocumentOpts{ .lang = resolveLang(opts.lang), ... }.
  - S4: main.zig pane + region.zig — honor opts.lang override via resolveLang(opts.lang).
  - P1.M1.T2.S1: tmux-2html.tmux passes @tmux-2html-lang through as --lang (lands in opts.lang).

CONFIG / DATABASE / ROUTES:
  - none (pure helper; reads LC_ALL/LC_MESSAGES/LANG + the explicit arg only).
```

## Validation Loop

> The PRIMARY gate is `zig build test -Doptimize=ReleaseFast` (Gotcha 1). The
> project test binary links ghostty-vt's C++ libs, so plain `zig build test`
> (Debug) fails with the unrelated `R_X86_64_PC64` linker bug.

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# The build is the syntax check. Confirm the new symbols parse + the file still compiles.
zig build test -Doptimize=ReleaseFast 2>&1 | head -20
# Expected: compiles. An `error: ...` referencing the new render.zig lines means a typo
# in the inserted block — fix the shape first (the verbatim block above is exit-0-tested).
```

### Level 2: Unit Tests (Component Validation — PRIMARY gate)

```bash
zig build test -Doptimize=ReleaseFast
# Expected: exit 0. The new tests (toBcp47 valid/null/case-norm, langFromEnvStrings
# precedence/empty/invalid-fallback, resolveLang explicit/normalized/C/invalid/null)
# all pass, alongside the existing 22 render.zig tests.
#
# NOTE: `zig build test` WITHOUT -Doptimize=ReleaseFast will FAIL with a linker error
# unrelated to your code (Gotcha 1) — do not be fooled.
```

### Level 3: Integration Testing (System Validation)

```bash
# Build the real binary (optimized) and confirm the additive edit changed NOTHING
# about current output (lang wiring is S3; today DocumentOpts.lang still defaults "en").
zig build --release=fast
echo '' | ./zig-out/bin/tmux-2html render | grep -o '<html lang="[a-zA-Z-]*">'   # expect: <html lang="en">
# Expected: still "en" — S2 does not wire resolveLang into DocumentOpts yet. This proves
# the additive-only invariant (goldens unaffected). If the lang attribute changed, you
# accidentally edited render.zig:636 (S3 territory) — revert that.

# Regression: the existing golden suite must still pass (it calls renderDocument; lang is "en").
zig build test -Doptimize=ReleaseFast 2>&1 | grep -i golden || true
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Confirm resolveLang is actually reachable/wired as a pub symbol (S3/S4 will call it).
# (No binary surface yet — S3 wires it. Here, just confirm it compiled as pub:)
grep -n 'pub fn resolveLang\|pub fn langFromEnv' src/render.zig   # expect BOTH lines present

# Confirm the no-cascade behavior holds for the documented edge (LC_ALL=C => en, not LANG):
# (covered by the "langFromEnvStrings: LC_ALL=C" unit test in Level 2.)
```

## Final Validation Checklist

### Technical Validation

- [ ] `zig build test -Doptimize=ReleaseFast` exits 0 (Level 2 — primary gate).
- [ ] All new render.zig tests pass (toBcp47 ×15, langFromEnvStrings ×6, resolveLang ×5).
- [ ] Existing 22 render.zig tests still pass (no regression).
- [ ] `zig build --release=fast` succeeds; binary runs.

### Feature Validation

- [ ] `toBcp47`/`langFromEnvStrings` are private; `langFromEnv`/`resolveLang` are `pub`.
- [ ] Contract TDD cases pass: en_US.UTF-8→en-US; pt_BR.UTF-8→pt-BR; de_DE@euro→de-DE;
      zh_CN→zh-CN; C/POSIX/C.UTF-8/empty→en; unset→en; explicit-invalid→en; explicit wins.
- [ ] Additive-only: `<html lang>` is still `en` today (no premature wiring — S3).
- [ ] Only `src/render.zig` modified; no other file touched.

### Code Quality Validation

- [ ] No allocation (module-level `bcp47_buf`); no `/dev/tty`; no input mutation.
- [ ] Testability split honored (pure `langFromEnvStrings` tested; `langFromEnv` not asserted deterministically).
- [ ] No cascade in precedence (`toBcp47(v) orelse "en"` returns immediately).
- [ ] Naming matches the contract exactly (S3/S4 import `resolveLang`/`langFromEnv`).
- [ ] Tests check each `toBcp47` result before the next call (static-buffer aliasing avoided).

### Documentation & Deployment

- [ ] Internal helper — no user-facing/config/API surface change (DOCS: none, per contract).
- [ ] No new env vars introduced (reads existing LC_ALL/LC_MESSAGES/LANG only).

---

## Anti-Patterns to Avoid

- ❌ Don't run plain `zig build test` — it fails on the Debug linker bug
  (`R_X86_64_PC64` from ghostty-vt's C++ libs). Use `zig build test -Doptimize=ReleaseFast`.
- ❌ Don't mutate `toBcp47`'s `[]const u8` input via `@constCast` — test inputs are
  string literals in read-only memory (UB/segfault). Write only to `bcp47_buf`.
- ❌ Don't return a slice into a stack-local buffer (dangling pointer). Use the
  module-level `bcp47_buf`.
- ❌ Don't hold two `toBcp47` results at once — the static buffer aliases them.
  Check each result before the next call (in tests AND any future caller).
- ❌ Don't cascade precedence on transform failure (LC_ALL=C → trying LANG is wrong;
  POSIX says LC_ALL overrides). Fall directly to `"en"`.
- ❌ Don't add special-case `if (eql("C"))` guards — C/POSIX/empty fail the lang
  length check naturally.
- ❌ Don't try to unit-test `langFromEnv()` deterministically — under `.link_libc=false`
  there's no `setenv`. Test `langFromEnvStrings` (the pure param-taking core) instead.
- ❌ Don't wire `resolveLang` into `DocumentOpts{...}` at render.zig:636 — that's S3.
  S2 is additive functions + tests only; touching :636 changes goldens and collides with S3.
- ❌ Don't edit cli.zig / main.zig / region.zig — S1 owns the `--lang` flag; S4 owns
  pane/region wiring. S2 is render.zig only.

---

**Confidence Score: 10/10** for one-pass implementation success.

The exact function bodies and test code in this PRP were compiled and executed
against the real Zig 0.15.2 toolchain (27/27 tests passed, exit 0). Every std-lib
API used (`std.mem.indexOfScalar`, `std.ascii.toLower/toUpper`, `std.posix.getenv`,
`std.testing.*`) is confirmed present in 0.15.2 and already in use in `src/render.zig`.
The two design decisions that an implementer could get wrong — the no-alloc strategy
(static buffer, NOT in-place/stack) and the no-cascade precedence — are documented
with the unsafe alternatives explicitly rejected and rationale given. Placement
anchors (after `DocumentOpts` :192; tests at EOF :1341) are verified against HEAD,
and the additive-only scope guarantees no golden regression and no collision with
S1 (cli.zig) or S3/S4 (wiring). The implementer is pasting exit-0-verified code.
