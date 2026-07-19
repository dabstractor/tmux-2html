# PRP — P1.M2.T2.S1: `resolveLang` treats empty explicit as locale-derived (Issue 4)

## Goal

**Feature Goal**: Fix Issue 4 (PRD §8.1; architecture `system_context.md` §Issue 4): an explicit
`--lang ""` (an empty string passed on the CLI) currently forces `<html lang="en">` instead of
deriving the language from the locale. The cause is `resolveLang` in `src/render.zig`: a non-null
**zero-length** explicit value unwraps to `e=""`, `toBcp47("")` returns `null` (length < 2), and
`orelse "en"` skips `langFromEnv()` (locale derivation). The fix: treat an empty explicit value the
same as unset/null — derive from `LC_ALL → LC_MESSAGES → LANG → "en"` — while leaving the non-empty
behavior (explicit invalid like `"C"`/`"english"` → `"en"`; explicit valid wins) **unchanged**.

**Deliverable** (at `/home/dustin/projects/tmux-2html/`):
- **MODIFY `src/render.zig`** — add a pure, param-taking core `fn resolveLangImpl(explicit,
  lc_all, lc_messages, lang)` holding the empty-string guard; `resolveLang` and `langFromEnv` both
  delegate to it (mirrors the existing `langFromEnv`/`langFromEnvStrings` pub-env-reader +
  pure-param-taker split). Behavior-preserving for every existing case.
- **MODIFY `src/render.zig`** — add deterministic unit tests on `resolveLangImpl` proving:
  empty explicit → locale-derived (e.g. `de-DE`); empty == null (same path); empty + no locale →
  `en`; non-empty invalid still → `en` (unchanged); non-empty valid still wins (unchanged).
- **MODIFY `docs/CONFIGURATION.md`** — clarify (Mode A) that an explicit `--lang ""` is treated as
  unset and falls back to locale derivation.
- **No new files.** `build.zig`, `build.zig.zon`, `cli.zig`, `main.zig`, `region.zig`,
  `ghostty_format.zig` UNCHANGED.

**Success Definition** (VERIFIED against the on-disk `src/render.zig` + Zig 0.15.2):
- `zig build test --release=fast` → exit 0; the new resolveLangImpl tests pass + all existing
  toBcp47/langFromEnvStrings/resolveLang tests still pass.
- `resolveLangImpl(@as(?[]const u8, ""), null, null, "de_DE.UTF-8")` returns `"de-DE"` (locale-
  derived — the fix); the OLD code returned `"en"` here.
- `resolveLangImpl("C", null, null, "de_DE.UTF-8")` still returns `"en"` (non-empty invalid
  behavior unchanged).
- The end-to-end repro: `printf 'hi\n' | LANG=de_DE.UTF-8 ./tmux-2html render --cols 5 --rows 1
  --lang '' | grep '<html'` now shows `lang="de-DE"` (not `en`).

> **`--release=fast` is MANDATORY** for build/test (Debug linking hits the ghostty
> `R_X86_64_PC64` linker bug — same as every render.zig-touching task).

## User Persona

**Target User**: Direct CLI users who pass `--lang ""` (e.g. a wrapper script that always emits a
`--lang "$var"` where `$var` may be empty). The tmux plugin itself is unaffected (it omits `--lang`
via a `[ -n "$lang_opt" ]` guard), so this is a low-impact correctness/consistency fix.

**Use Case**: A user runs `tmux-2html render --lang ''` expecting the documented "empty ⇒
locale-derived" behavior (docs/CONFIGURATION.md:49) to apply to the CLI flag too — not a forced `en`.

**Pain Points Addressed**: Makes the binary's `--lang ""` consistent with (a) the documented
`@tmux-2html-lang` option semantics ("Empty ⇒ locale-derived") and (b) the plugin's own empty-means-
omit convention. Removes a silent surprise where an explicit empty string skips locale detection.

## Why

- **Consistency with documented behavior (PRD §8.1).** docs/CONFIGURATION.md:49 already states
  `@tmux-2html-lang … Empty ⇒ locale-derived, fallback en`. The CLI `--lang` flag is the same
  value baked into the binding; an explicit empty should mean the same thing as an unset option.
- **Low-risk, surgical.** The fix is a one-branch guard (`if (e.len == 0) … locale path`) plus a
  small pure-core refactor that mirrors an existing in-file pattern. No flag/API/help-text change;
  non-empty behavior (the documented "explicit invalid → en") is explicitly preserved and tested.
- **Deterministically testable.** Because Zig 0.15.2 std has no `setenv` (and the build is
  `link_libc = false`), the real-env path can't be unit-tested deterministically. Funneling the
  fix through a pure `resolveLangImpl(explicit, lc_all, lc_messages, lang)` (mirroring
  `langFromEnv`/`langFromEnvStrings`) lets the empty branch be proven with fixed string args.

## What

### The bug (current `resolveLang`, render.zig:292)

```zig
pub fn resolveLang(explicit: ?[]const u8) []const u8 {
    if (explicit) |e| return toBcp47(e) orelse "en";  // e="" -> toBcp47("")=null -> "en"  [BUG]
    return langFromEnv();
}
```

### The fix (pure core; resolveLang + langFromEnv delegate to it)

```zig
pub fn resolveLang(explicit: ?[]const u8) []const u8 {
    return resolveLangImpl(explicit, std.posix.getenv("LC_ALL"), std.posix.getenv("LC_MESSAGES"), std.posix.getenv("LANG"));
}

pub fn langFromEnv() []const u8 {
    return resolveLangImpl(null, std.posix.getenv("LC_ALL"), std.posix.getenv("LC_MESSAGES"), std.posix.getenv("LANG"));
}

/// Pure core shared by resolveLang + langFromEnv (Issue 4): an explicit NON-EMPTY value wins
/// (invalid -> "en"); an EMPTY explicit value is treated as UNSET and derives from the locale
/// (LC_ALL -> LC_MESSAGES -> LANG -> "en"); null likewise derives from the locale. Param-taking
/// so it is deterministic & unit-testable without mutating process env (Zig 0.15.2 std has no
/// setenv; build is link_libc=false). Mirrors the langFromEnv/langFromEnvStrings precedent.
fn resolveLangImpl(explicit: ?[]const u8, lc_all: ?[]const u8, lc_messages: ?[]const u8, lang: ?[]const u8) []const u8 {
    if (explicit) |e| {
        if (e.len == 0) return langFromEnvStrings(lc_all, lc_messages, lang); // Issue 4: empty == unset
        return toBcp47(e) orelse "en";
    }
    return langFromEnvStrings(lc_all, lc_messages, lang);
}
```

### Success Criteria

- [ ] `resolveLangImpl` present (module-private `fn`); `resolveLang` and `langFromEnv` both delegate
      to it (one-line bodies each).
- [ ] `resolveLang` signature unchanged: `pub fn resolveLang(explicit: ?[]const u8) []const u8`.
- [ ] New unit tests on `resolveLangImpl` pass: empty→locale (`de-DE`); empty==null; empty+no-locale→`en`;
      non-empty invalid→`en` (unchanged); non-empty valid wins (unchanged).
- [ ] All existing toBcp47 / langFromEnvStrings / resolveLang tests still pass (behavior-preserving).
- [ ] `zig build test --release=fast` → exit 0.
- [ ] `docs/CONFIGURATION.md` clarifies `--lang ""` ⇒ locale-derived.
- [ ] Only `src/render.zig` + `docs/CONFIGURATION.md` changed.

## All Needed Context

### Context Completeness Check

_Pass: "If someone knew nothing about this codebase, would they have everything needed to implement
this successfully?"_ — Yes. The exact buggy function (render.zig:292), the exact cause
(`toBcp47("")`→null→`orelse "en"`), the exact sibling functions to reuse/mirror (`langFromEnv`:281,
`langFromEnvStrings`:272 — pure + param-taking + already tested), the no-`setenv`/`link_libc=false`
constraint that forces the pure-core refactor, the verbatim replacement code, the verbatim tests
(calling the module-private core, as existing tests already call private fns), the docs edit point
(CONFIGURATION.md:49 + 84-86), and the disjoint-from-parallel-work edit regions are all documented
with line citations in `research/findings.md`. The implementer is making a verified, surgical change.

### Documentation & References

```yaml
# MUST READ — the authoritative bug analysis + fix recipe + test rationale (line citations)
- file: plan/002_e3d8d22c088d/bugfix/001_ce4fa4f55ddc/P1M2T2S1/research/findings.md
  why: "§1 the bug (toBcp47('') -> null -> orelse 'en'); §2 the 4 sibling fns + exact signatures;
        §3 callers (resolveLang: main.zig:532, region.zig:470, render.zig:747 — signature is fixed);
        §4 the no-setenv/link_libc=false constraint that forces the pure-core refactor; §5 the
        verbatim fix; §6 no conflict with parallel P1.M2.T1.S1 (lines 547/603) or P1.M1.T2.S1; §7
        docs target."
  critical: "Why a pure resolveLangImpl (not a 1-line inline guard): Zig 0.15.2 std has NO setenv
             and link_libc=false, so resolveLang('') via the real env is NOT deterministically
             unit-testable. The pure core (mirroring langFromEnv/langFromEnvStrings) makes the
             empty branch provable with fixed string args. An invariant test resolveLang('')==resolveLang(null)
             is NOT a robust regression test (false-negative in a no-locale env)."

# MUST READ — the file being edited
- file: src/render.zig
  section: "toBcp47 (221, the null-on-empty guard at 239); langFromEnvStrings (272, PURE param-taker,
            the precedent to mirror); langFromEnv (281, pub env-reader); resolveLang (292, the BUGGY fn);
            existing lang tests (1499-1604, the assertion patterns + the env-non-determinism note at 1603)."
  why: "Confirms the exact edit point (292), the exact pure helper to reuse (langFromEnvStrings), and
        that same-file tests MAY call module-private fns (existing tests call private toBcp47/
        langFromEnvStrings/clampExtent/writeFileAtomic)."
  gotcha: "resolveLang's signature is FIXED (3 callers depend on it). langFromEnv must stay pub and
           behavior-identical (its delegation to resolveLangImpl(null,…) is provably == the old
           langFromEnvStrings(…) call). Do NOT change toBcp47 or langFromEnvStrings."

# MUST READ — the contract (the work item description) + PRD issue
- file: PRD.md  # (bugfix PRD, Issue 4)
  section: "§Minor Issues / Issue 4: --lang '' (explicit empty) yields en rather than locale-derived"
  why: "Confirms the expected behavior (empty ⇒ locale-derived), the repro, and that the non-empty
        'explicit invalid → en' behavior is internally consistent and must be preserved."

# MUST READ — docs edit target
- file: docs/CONFIGURATION.md
  section: "line 49 (options table @tmux-2html-lang: 'Empty ⇒ locale-derived, fallback en');
            lines 64-86 (§8.1 HTML output + 'How options are read': the plugin bakes @tmux-2html-lang
            into --lang; 'you can also pass --title/--lang yourself')."
  why: "The natural place to add the one clarifying sentence about --lang '' being treated as unset."

# MUST READ — parallel work (avoid collision)
- file: plan/002_e3d8d22c088d/bugfix/001_ce4fa4f55ddc/P1M2T1S1/PRP.md
  why: "P1.M2.T1.S1 (Issue 3) ALSO edits src/render.zig — at lines 547/603 (makePath) + a test after
        line 1336. This task edits lines 281-294 + tests near 1606. DISJOINT regions => no conflict.
        Do NOT touch renderToFileAtomic/writeDocFileAtomic/writeFileAtomic."
```

### Current Codebase tree (this task's starting point)

```bash
tmux-2html/
├── src/
│   ├── render.zig        # 1606 lines; toBcp47(221) langFromEnvStrings(272) langFromEnv(281) resolveLang(292) ← EDIT
│   ├── main.zig          # resolveLang caller (line 532)                                ← DO NOT TOUCH
│   ├── region.zig        # resolveLang caller (line 470)                                ← DO NOT TOUCH
│   ├── cli.zig  palette.zig  ghostty_format.zig  capture.zig  ...                       ← DO NOT TOUCH
├── docs/CONFIGURATION.md # @tmux-2html-lang row (49) + §8.1/--lang prose (64-86)         ← EDIT (1 sentence)
├── build.zig  build.zig.zon   # link_libc=false (24)                                    ← DO NOT TOUCH
└── PRD.md  plan/  ...
```

### Desired Codebase tree with files to be changed

```bash
tmux-2html/
├── src/
│   └── render.zig        # + resolveLangImpl (pure core); resolveLang + langFromEnv delegate; +5 tests
└── docs/CONFIGURATION.md # +1 clarifying sentence (--lang "" => locale-derived)
```

### Known Gotchas of our codebase & Library Quirks

```zig
// GOTCHA 1 — resolveLang's SIGNATURE IS FIXED. Three callers depend on it: main.zig:532,
//   region.zig:470, render.zig:747 (all pass opts.lang: ?[]const u8). Keep it
//   `pub fn resolveLang(explicit: ?[]const u8) []const u8`. Only its BODY changes (delegation).

// GOTCHA 2 — NO setenv in Zig 0.15.2 std, AND build.zig sets link_libc=false (line 24) => no libc
//   setenv either. A unit test CANNOT set LANG=de_DE.UTF-8 to make resolveLang("") deterministic
//   through the real env. This is WHY the fix funnels through a PURE resolveLangImpl(explicit,
//   lc_all, lc_messages, lang) (mirroring langFromEnv/langFromEnvStrings): the empty branch is then
//   provable with fixed string args. Do NOT attempt to mock env; do NOT add a libc dependency.

// GOTCHA 3 — An invariant test `resolveLang("") == resolveLang(null)` is NOT a robust regression
//   test: in an env with no locale, langFromEnv() returns "en", so the OLD buggy code
//   (resolveLang("")="en") ALSO satisfies the invariant (false negative). Test the pure core
//   resolveLangImpl with EXPLICIT locale args instead — that fails on the old code in ANY env.

// GOTCHA 4 — Same-file tests MAY call module-private fns. The existing tests already call private
//   toBcp47, langFromEnvStrings, clampExtent, writeFileAtomic, writeEscaped. So testing the private
//   resolveLangImpl directly is idiomatic (no need to make it pub).

// GOTCHA 5 — langFromEnv must remain BEHAVIOR-IDENTICAL. Today it calls langFromEnvStrings(getenv…).
//   After the refactor it calls resolveLangImpl(null, getenv…) which calls langFromEnvStrings(getenv…).
//   Provably identical. Do NOT change its precedence (LC_ALL > LC_MESSAGES > LANG > "en") or remove it
//   (it's the public locale-only resolver; delegating keeps it DRY + alive instead of dead-but-pub).

// GOTCHA 6 — toBcp47 writes into module-level bcp47_buf (static); its result is only valid until the
//   next toBcp47 call. resolveLang/resolveLangImpl return that slice (or "en"/a langFromEnvStrings
//   result). Callers (main.zig:532 etc.) use it immediately — unchanged by this fix. Do NOT add
//   allocation/free.

// GOTCHA 7 — build/test MUST use --release=fast: Debug linking hits the ghostty R_X86_64_PC64 linker
//   bug. `zig build test` (no release flag) FAILS. Always `zig build test --release=fast`.

// GOTCHA 8 — Do NOT touch the parallel P1.M2.T1.S1 edit regions: renderToFileAtomic (547),
//   writeDocFileAtomic (603), writeFileAtomic (639), or the test inserted after line 1336. This
//   task's edits are at 281-294 + tests near 1606 — disjoint.
```

## Implementation Blueprint

### Data models and structure

No data-model changes. The only types are already in `render.zig`: `?[]const u8` (explicit/lang
params) and `[]const u8` (return). `resolveLangImpl` reuses `langFromEnvStrings` and `toBcp47`
unchanged.

### The exact deliverable: `src/render.zig` (EDIT — replace 2 fns + add 1 fn + add tests)

**Edit 1 — replace `langFromEnv` + `resolveLang` and insert `resolveLangImpl`** (render.zig:281-294).
The current block is:

```zig
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

Replace with:

```zig
/// Locale-only resolution (precedence + transform + fallback). Reads the process
/// environment via std.posix.getenv. NO /dev/tty.
pub fn langFromEnv() []const u8 {
    return resolveLangImpl(
        null,
        std.posix.getenv("LC_ALL"),
        std.posix.getenv("LC_MESSAGES"),
        std.posix.getenv("LANG"),
    );
}

/// Resolve the <html lang> value (PRD §8.1). Explicit --lang / @tmux-2html-lang wins;
/// an EMPTY explicit value (--lang "") is treated as UNSET and derives from the locale
/// (Issue 4: previously it forced "en"). An explicit invalid value (e.g. "C", "english")
/// degrades defensively to "en". Otherwise derive from the locale; else "en".
pub fn resolveLang(explicit: ?[]const u8) []const u8 {
    return resolveLangImpl(
        explicit,
        std.posix.getenv("LC_ALL"),
        std.posix.getenv("LC_MESSAGES"),
        std.posix.getenv("LANG"),
    );
}

/// Pure core shared by resolveLang + langFromEnv (Issue 4). An explicit NON-EMPTY value
/// wins (invalid -> "en"); an EMPTY explicit value is treated as UNSET and derives from
/// LC_ALL -> LC_MESSAGES -> LANG -> "en" (same as null). Param-taking so it is deterministic
/// & unit-testable without mutating process env (Zig 0.15.2 std has no setenv; link_libc=false).
/// Mirrors the langFromEnv/langFromEnvStrings pub-reader + pure-helper precedent.
fn resolveLangImpl(explicit: ?[]const u8, lc_all: ?[]const u8, lc_messages: ?[]const u8, lang: ?[]const u8) []const u8 {
    if (explicit) |e| {
        if (e.len == 0) return langFromEnvStrings(lc_all, lc_messages, lang); // Issue 4: empty explicit == unset
        return toBcp47(e) orelse "en";
    }
    return langFromEnvStrings(lc_all, lc_messages, lang);
}
```

> Anchor uniqueness: the `pub fn langFromEnv() []const u8 {` + `pub fn resolveLang(explicit: ?[]const u8) []const u8 {`
> pair is unique in render.zig. The full 14-line `Before` block above matches exactly one location.

**Edit 2 — add unit tests.** Insert immediately AFTER the existing
`test "resolveLang: explicit null falls to env (non-empty result)"` (the last test, ends at the
file's closing — render.zig:1606). These test the **module-private** `resolveLangImpl` directly
(same-file tests may call private fns — Gotcha 4):

```zig
// ---- resolveLangImpl: Issue 4 (empty explicit == unset -> locale-derived) ----

test "resolveLangImpl: empty explicit derives from locale (Issue 4)" {
    // The bug: resolveLang("") used to force "en" (toBcp47("") -> null -> orelse "en").
    // The fix: empty explicit is treated as unset -> locale derivation.
    try std.testing.expectEqualStrings("de-DE", resolveLangImpl(@as(?[]const u8, ""), null, null, "de_DE.UTF-8"));
}

test "resolveLangImpl: empty explicit == null (identical locale path)" {
    // Empty and unset take the SAME code path -> identical result, for any locale.
    try std.testing.expectEqualStrings(
        resolveLangImpl(null, null, null, "pt_BR.UTF-8"),
        resolveLangImpl(@as(?[]const u8, ""), null, null, "pt_BR.UTF-8"),
    );
}

test "resolveLangImpl: empty explicit + no locale -> en" {
    try std.testing.expectEqualStrings("en", resolveLangImpl(@as(?[]const u8, ""), null, null, null));
    try std.testing.expectEqualStrings("en", resolveLangImpl(@as(?[]const u8, ""), "", "", ""));
}

test "resolveLangImpl: non-empty invalid still -> en (unchanged by Issue 4 fix)" {
    // Explicit invalid (C/english) still forces "en" — the fix does NOT change non-empty behavior,
    // and an explicit value still WINS over the locale (no cascade to LANG).
    try std.testing.expectEqualStrings("en", resolveLangImpl("C", null, null, "de_DE.UTF-8"));
    try std.testing.expectEqualStrings("en", resolveLangImpl("english", "de_DE.UTF-8", null, null));
}

test "resolveLangImpl: non-empty valid wins over locale (unchanged)" {
    try std.testing.expectEqualStrings("fr", resolveLangImpl("fr", "de_DE.UTF-8", null, null));
    try std.testing.expectEqualStrings("en-US", resolveLangImpl("en_US.UTF-8", null, null, "de_DE"));
}
```

**Edit 3 — docs/CONFIGURATION.md.** In the "How options are read" paragraph (lines 84-86), append one
clarifying sentence after "You can also pass `--title`/`--lang` yourself when running the binary
standalone.":

> Passing `--lang ""` (an explicit empty string) is treated the same as omitting the flag: the
> `<html lang>` value is derived from your locale (`LC_ALL` → `LC_MESSAGES` → `LANG`), falling back
> to `en`. (An explicit non-empty value that fails to parse as a BCP-47 tag — e.g. `C` — still falls
> back to `en`.)

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: EDIT src/render.zig — refactor langFromEnv + resolveLang to delegate to a new pure resolveLangImpl
  - REPLACE the langFromEnv(281)+resolveLang(292) block with the 3-fn version in Edit 1 (langFromEnv
    and resolveLang become one-line delegations; resolveLangImpl holds the empty guard).
  - CONSUMES: existing private langFromEnvStrings(272) + toBcp47(221) UNCHANGED.
  - PRESERVE: resolveLang signature (Gotcha 1); langFromEnv behavior (Gotcha 5); toBcp47 static buf
    semantics (Gotcha 6).
  - GOTCHA 2,8: no setenv/libc; disjoint from parallel edit regions (547/603/639).

Task 2: ADD unit tests in src/render.zig (after the last existing test, ~line 1606)
  - ADD the 5 resolveLangImpl tests in Edit 2 (empty→locale; empty==null; empty+no-locale→en;
    non-empty invalid→en unchanged; non-empty valid wins unchanged).
  - FOLLOW pattern: existing toBcp47/langFromEnvStrings tests (expectEqualStrings on pure fns).
  - GOTCHA 3,4: test the PURE core (not resolveLang via real env); private fns are callable from
    same-file tests.

Task 3: EDIT docs/CONFIGURATION.md — add the --lang "" clarification (Edit 3)
  - APPEND the one sentence to the "How options are read" paragraph (lines 84-86).
  - Do NOT duplicate the options-table row (line 49) — it already says "Empty ⇒ locale-derived".

Task 4: VALIDATE (see Validation Loop)
  - RUN: zig build test --release=fast     # new tests + all existing pass
  - RUN: zig build --release=fast           # build the binary
  - RUN: the Issue 4 repro (Level 3)        # LANG=de_DE.UTF-8 render --lang '' -> lang="de-DE"
```

### Implementation Patterns & Key Details

```zig
// PATTERN: pub env-reader + pure param-taking core. This EXACT split already exists in render.zig
//   (langFromEnv reads getenv -> langFromEnvStrings(params)). resolveLang now follows the same shape:
//   resolveLang/getenv -> resolveLangImpl(params). The pure core is deterministic & unit-testable.
pub fn resolveLang(explicit: ?[]const u8) []const u8 {
    return resolveLangImpl(explicit, std.posix.getenv("LC_ALL"), std.posix.getenv("LC_MESSAGES"), std.posix.getenv("LANG"));
}

// PATTERN: the empty-guard. An explicit ?[]const u8 that is non-null but zero-length is treated as
//   unset (falls to the locale path), identical to null. Non-empty still wins (invalid -> "en").
fn resolveLangImpl(explicit: ?[]const u8, lc_all: ?[]const u8, lc_messages: ?[]const u8, lang: ?[]const u8) []const u8 {
    if (explicit) |e| {
        if (e.len == 0) return langFromEnvStrings(lc_all, lc_messages, lang); // Issue 4
        return toBcp47(e) orelse "en";
    }
    return langFromEnvStrings(lc_all, lc_messages, lang);
}

// PATTERN: deterministic unit test on the pure core (private fn, same-file). The OLD code returns
//   "en" for resolveLangImpl("", null, null, "de_DE.UTF-8"); the NEW code returns "de-DE" — so this
//   test is a true regression guard that FAILS on the buggy code in ANY environment.
test "resolveLangImpl: empty explicit derives from locale (Issue 4)" {
    try std.testing.expectEqualStrings("de-DE", resolveLangImpl(@as(?[]const u8, ""), null, null, "de_DE.UTF-8"));
}
```

### Integration Points

```yaml
BUILD GRAPH:
  - consumes (unchanged): build.zig, build.zig.zon, all other src/*.zig. No new imports (resolveLangImpl
    reuses existing std.posix.getenv + langFromEnvStrings + toBcp47).
  - produces: src/render.zig with the pure resolveLangImpl core + tests; docs/CONFIGURATION.md clarification.
  - PARALLEL WORK: P1.M2.T1.S1 (Issue 3) edits render.zig at lines 547/603 + test after 1336; P1.M1.T2.S1
    (Issue 2) edits ghostty_format.zig + test after 1338. This task's edits (281-294 + tests ~1606) are
    DISJOINT. Do NOT touch those regions.

CLI SURFACE (PRD §5/§8.1):
  - No flag/API/help-text change. --lang still accepts a BCP-47 tag; "" now means "derive from locale"
    (consistent with the documented @tmux-2html-lang option semantics). render --help is unchanged.
```

## Validation Loop

> Re-run verbatim. EVERY build/test command MUST include `--release=fast` (Gotcha 7).

### Level 1: Syntax & Style (Immediate Feedback)

```bash
zig version            # MUST print: 0.15.2
zig build --fetch      # exit 0 (deps cached)
```

### Level 2: Unit tests (PRIMARY gate — proves the fix deterministically)

```bash
# New resolveLangImpl tests + ALL existing toBcp47/langFromEnvStrings/resolveLang tests. No leaks
# (no allocation in the lang path — toBcp47 uses a static buf).
zig build test --release=fast          # expect: all passed, exit 0

# If "unhandled relocation type R_X86_64_PC64" -> forgot --release=fast (Gotcha 7).
# If "unable to resolve ... resolveLangImpl" in a test -> the test fn is in a DIFFERENT file than
#   render.zig (resolveLangImpl is module-private). Keep the tests in src/render.zig (Gotcha 4).
# If a test "resolveLangImpl: empty explicit derives from locale" FAILS with got="en" -> the empty
#   guard `if (e.len == 0)` is missing or wrong (the fix wasn't applied).
```

### Level 3: Integration — the actual bug repro (proves resolveLang end-to-end)

```bash
zig build --release=fast               # expect: exit 0; zig-out/bin/tmux-2html produced
BIN="zig-out/bin/tmux-2html"

# Exact repro from the issue (architecture system_context.md §Issue 4). Before the fix this printed
# <html lang="en">; after the fix it prints <html lang="de-DE"> (locale-derived under LANG=de_DE.UTF-8).
printf 'hi\n' | LANG=de_DE.UTF-8 LC_ALL= LC_MESSAGES= "$BIN" render --cols 5 --rows 1 --lang '' \
  | grep '<html'        # expect: <html lang="de-DE">
# (also confirm the no-locale fallback still yields en:)
printf 'hi\n' | LANG= LC_ALL= LC_MESSAGES= "$BIN" render --cols 5 --rows 1 --lang '' \
  | grep '<html'        # expect: <html lang="en">
# (and the non-empty invalid behavior is unchanged:)
printf 'hi\n' | "$BIN" render --cols 5 --rows 1 --lang 'C' \
  | grep '<html'        # expect: <html lang="en">
```

### Level 4: Scope boundary (Domain Validation)

```bash
# ONLY src/render.zig + docs/CONFIGURATION.md changed; build files + other src files untouched.
git diff --stat build.zig build.zig.zon src/main.zig src/region.zig src/cli.zig src/ghostty_format.zig  # expect: no output
git diff --stat src/render.zig docs/CONFIGURATION.md                                                     # expect: both modified

# toBcp47 / langFromEnvStrings UNCHANGED (only langFromEnv/resolveLang bodies + new resolveLangImpl + tests):
git diff src/render.zig | grep -E '^\+.*fn (toBcp47|langFromEnvStrings)' && echo "UNEXPECTED change to sibling fns" || echo "sibling fns untouched: OK"
```

## Final Validation Checklist

### Technical Validation

- [ ] `zig version` prints `0.15.2`; `zig build --fetch` exits 0.
- [ ] `zig build test --release=fast` exits 0 (new resolveLangImpl tests + all existing tests pass).
- [ ] `zig build --release=fast` exits 0; `zig-out/bin/tmux-2html` produced.

### Feature Validation

- [ ] `resolveLangImpl(@as(?[]const u8, ""), null, null, "de_DE.UTF-8")` == `"de-DE"` (the fix).
- [ ] `resolveLangImpl(@as(?[]const u8, ""), null, null, null)` == `"en"` (empty + no locale → en).
- [ ] `resolveLangImpl("C", null, null, "de_DE.UTF-8")` == `"en"` (non-empty invalid unchanged).
- [ ] `resolveLangImpl("fr", "de_DE.UTF-8", null, null)` == `"fr"` (non-empty valid wins unchanged).
- [ ] Bug repro: `LANG=de_DE.UTF-8 … render --lang ''` → `<html lang="de-DE">` (was `en`).
- [ ] `resolveLang` signature unchanged; `langFromEnv` behavior unchanged.

### Code Quality Validation

- [ ] The pure-core refactor mirrors the existing `langFromEnv`/`langFromEnvStrings` split (idiomatic).
- [ ] `toBcp47` / `langFromEnvStrings` NOT modified (only langFromEnv/resolveLang bodies + new fn + tests).
- [ ] Tests call the module-private `resolveLangImpl` directly (same-file; Gotcha 4).
- [ ] No allocation/free added in the lang path (toBcp47 uses static `bcp47_buf`; Gotcha 6).

### Documentation & Deployment

- [ ] `docs/CONFIGURATION.md` clarifies that `--lang ""` is treated as unset → locale-derived.
- [ ] No flag/API/help-text change; no new env vars.

---

## Anti-Patterns to Avoid

- ❌ Don't apply the fix as a 1-line inline guard in `resolveLang` and then test `resolveLang("")` via
  the real env — Zig 0.15.2 std has NO `setenv` and `link_libc=false` (Gotcha 2), so the test can't
  set `LANG`. Funnel through the pure `resolveLangImpl` (mirroring `langFromEnv/langFromEnvStrings`)
  and test it with fixed string args.
- ❌ Don't write the regression test as `resolveLang("") == resolveLang(null)` only — in a no-locale
  env both return `"en"` on the OLD code too (false negative; Gotcha 3). Assert the actual derived
  value (`"de-DE"`) via the pure core.
- ❌ Don't change `resolveLang`'s signature (3 callers depend on it; Gotcha 1) or remove `langFromEnv`
  (public locale-only resolver; keep it delegating to the pure core — Gotcha 5).
- ❌ Don't modify `toBcp47` or `langFromEnvStrings` — they are correct and already tested; the bug is
  solely in how `resolveLang` dispatches an empty explicit value.
- ❌ Don't add allocation in the lang path — `toBcp47` writes to the static `bcp47_buf`; results are
  used immediately by callers (Gotcha 6). No `free` needed.
- ❌ Don't build/test WITHOUT `--release=fast` — Debug linking hits `R_X86_64_PC64` (Gotcha 7).
- ❌ Don't touch the parallel P1.M2.T1.S1 regions (renderToFileAtomic 547 / writeDocFileAtomic 603 /
  writeFileAtomic 639 / test after 1336) or P1.M1.T2.S1's ghostty_format.zig — disjoint from this
  task's edits at 281-294 + tests ~1606 (Gotcha 8).

---

**Confidence Score: 9/10** for one-pass implementation success.

The bug is precisely diagnosed from the on-disk source (`resolveLang`:292; `toBcp47("")`→null at the
:239 length guard; `orelse "en"`). The fix reuses the exact pure helper (`langFromEnvStrings`:272)
already in the file and mirrors the exact pub-reader/pure-core split (`langFromEnv`/`langFromEnvStrings`)
already established there — so it is idiomatic and behavior-preserving for every existing case (all
current toBcp47/langFromEnvStrings/resolveLang tests continue to pass). The one genuine constraint —
no `setenv` in Zig 0.15.2 std with `link_libc=false` — is what forces the pure `resolveLangImpl`
refactor (rather than a 1-line inline guard), and that refactor is precisely what enables a robust,
env-independent regression test (`resolveLangImpl("", null, null, "de_DE.UTF-8") == "de-DE"`, which
FAILS on the buggy code in any environment). The edit regions (281-294 + tests ~1606) are disjoint
from the parallel P1.M2.T1.S1 (547/603 + test ~1336) and P1.M1.T2.S1 (ghostty_format.zig) work. The
only residual risk is a docs-merge interaction with the later P1.M2.T3.S1 changeset-summary task,
mitigated by this being a single targeted sentence in a specific paragraph.