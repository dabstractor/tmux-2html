# PRP — P1.M1.T1.S3: `render.run` wires resolved title + lang into `DocumentOpts`

## Goal

**Feature Goal**: Make `render.run` honor the `--title` / `--lang` flags (added by S1)
by computing a resolved `title` (`opts.title orelse "tmux-2html"`) and `lang`
(`resolveLang(opts.lang)`) at the single `DocumentOpts{...}` construction site inside
`run`, so all four output arms (`--output` / `--open` / stdout / `--selection`) emit a
complete HTML5 document with the user-supplied `<title>` and `<html lang>`.

**Deliverable**: A surgical edit to **`src/render.zig` only** — one line becomes three
at the `const doc = …` site inside `pub fn run` (now line 729; was 636 before S2 landed).
No new files, no new functions, no per-arm changes (the four arms already reuse `doc`).
`--help` text is NOT touched (owned by S1).

**Success Definition**:
- `render --title "X" --lang fr` emits `<title>X</title>` and `<html lang="fr">` in a
  complete §8.1 document, on stdout AND via `--output`/`--open`/`--selection`.
- `render` with no flags still emits `<title>tmux-2html</title>` and `<html lang="en">`
  (or locale-derived tag) — behavior is a strict superset of before.
- `zig build test -Doptimize=ReleaseFast` exits 0; the two golden tests remain
  byte-equal (the edit is invisible to them — they call `renderDocument` directly).

## User Persona

**Target User**: Anyone running `tmux-2html render` who wants a custom document
`<title>` (e.g. a pane name) and a correct `<html lang>` (e.g. for screen readers /
browser hyphenation). Also the tmux plugin (P1.M1.T2) which will thread
`@tmux-2html-title` / `@tmux-2html-lang` through these same flags.

**Use Case**: `tmux-2html render --title "logs" --lang fr < capture.txt > logs.html`
produces a standalone HTML5 doc titled "logs", lang `fr`.

**Pain Points Addressed**: Today `run` hard-codes `.title = "tmux-2html"` and omits
`.lang` (so it defaults to `"en"` regardless of locale). S3 removes that hard-coding so
the S1 flags and S2 resolver actually take effect on the `render` subcommand.

## Why

- **PRD §8.1 (normative)** requires the document `<title>` to be "Configurable via
  `--title`" and `<html lang>` to be "default `en`; configurable via
  `@tmux-2html-lang` / locale". S1 added the raw flags; S2 added the resolver; **S3 is
  the wiring step** that connects them to the document emitted by `render`.
- **Single chokepoint**: `run` builds `doc` once and all four arms reuse it, so one
  edit fixes all output modes atomically. This is the smallest change that delivers
  §8.1 configurability for the `render` subcommand.
- **Boundary-safe**: goldens call `renderDocument` directly (bypassing `run`), so this
  CLI-layer change provably cannot alter pinned bytes. Comprehensive `--title`/`--lang`
  output assertion tests are owned by **P1.M1.T3.S1**; S3 delivers the wiring + a smoke
  proof and does not duplicate T3's test suite.

## What

A three-line replacement at the `const doc = …` site inside `render.run`:

```zig
const title = opts.title orelse "tmux-2html";
const lang = resolveLang(opts.lang);
const doc = DocumentOpts{ .title = title, .lang = lang, .background = colors.background };
```

- `opts` is the `cli.RenderOpts` parameter of `run` (in scope).
- `resolveLang` is `pub fn resolveLang(explicit: ?[]const u8) []const u8` — defined in the
  SAME file (`src/render.zig:281`, delivered by S2). No import.
- `opts.title` / `opts.lang` are `?[]const u8` (delivered by S1) — types match exactly.

No other change. The four arms (`--selection`, `--output`, `--open`, stdout) already pass
`doc` through to `writeDocFileAtomic` / `writeDocumentBytes` / `renderToFileAtomic` /
`renderDocument`, and `writeDocument` already emits `<html lang="{doc.lang}">` and
`<title>{doc.title}</title>` (HTML-escaped). So setting the two fields is the complete behavior.

### Success Criteria

- [ ] `render --title X --lang fr` → `<title>X</title>` AND `<html lang="fr">` present.
- [ ] `render` (no flags) → `<title>tmux-2html</title>` AND `<html lang="…">` (en or locale).
- [ ] `render --lang en_US.UTF-8` → `<html lang="en-US">` (resolver normalizes).
- [ ] `zig build test -Doptimize=ReleaseFast` exits 0; both golden tests still byte-equal.
- [ ] Only `src/render.zig` modified; `--help` text untouched (S1 owns it).

## All Needed Context

### Context Completeness Check

_Pass: "If someone knew nothing about this codebase, would they have everything needed
to implement this successfully?"_ — Yes. The exact old line (unique in the file) and its
exact three-line replacement are given below with line anchors verified against the live
tree. The types, the resolver signature, the four-arm reuse, the golden-safety proof, and
the mandatory `ReleaseFast` test flag are all documented. This is a paste-and-verify task.

### Documentation & References

```yaml
# MUST READ — the file being edited (anchors verified against the working tree: S1+S2 present)
- file: src/render.zig
  section: "DocumentOpts struct :187-192; resolveLang pub fn :281; writeDocument :310 (emits lang+title); run :708; const doc :729"
  why: "THE ONLY file to edit. The single const doc = DocumentOpts{...} at :729 is the edit site."
  pattern: "doc is built once in run and reused by all four arms; writeDocument writes <html lang> and <title> from doc fields."
  gotcha: "Item description cites line 636 — that was pre-S2. S2 inserted ~120 lines after DocumentOpts, moving the site to :729. Match on the TEXT, not the line number (see edit below)."

# MUST READ — proof the edit is golden-invisible
- file: src/golden_test.zig
  section: "renderDocument calls at :22 and :57; DocumentOpts literals at :29 and :64"
  why: "Golden tests build their OWN DocumentOpts{ .title = \"tmux-2html\", ... } (lang defaults en) and call renderDocument DIRECTLY — they never call run. So editing run cannot change golden bytes."
  critical: "This is the CRITICAL INVARIANT from the contract. Verify it after the edit: zig build test -Doptimize=ReleaseFast, both golden tests still pass byte-equal."

# INPUT CONTRACT — S1 (Complete): the flags + their types
- file: src/cli.zig
  section: "RenderOpts struct :59 (title :67, lang :68); parseRender --title/--lang branches :180-183"
  why: "Confirms opts.title / opts.lang are ?[]const u8 (nullable, defaulted null) — exactly what orelse/resolveLang expect. S3 does NOT touch cli.zig."
  pattern: "opts is the cli.RenderOpts parameter of run (already in scope at :708)."

# INPUT CONTRACT — S2 (implemented in file): the resolver
- file: src/render.zig
  section: "pub fn resolveLang(explicit: ?[]const u8) []const u8 at :281 (toBcp47 :210, langFromEnvStrings :261, langFromEnv :270, bcp47_buf :203)"
  why: "resolveLang(opts.lang) is the exact call. Returns a slice into module-level bcp47_buf OR the literal \"en\" — both static lifetime, no free."
  gotcha: "bcp47_buf is overwritten per toBcp47 call, BUT resolveLang is called ONCE here and nothing between it and doc.lang consumption (renderGrid/renderDocument/renderToFileAtomic/writeDocumentBytes) re-invokes it — slice is stable. (S2 PRP Gotcha 2.)"

# CONTRACT SOURCES — what S1/S2 produce (treat as contract)
- file: plan/002_e3d8d22c088d/P1M1T1S1/PRP.md
  why: "Defines opts.title/opts.lang = ?[]const u8. RenderOpts/PaneOpts/RegionOpts all gain them. S1 is Complete."
- file: plan/002_e3d8d22c088d/P1M1T1S2/PRP.md
  why: "Defines resolveLang(?[]const u8) []const u8 (pub) + the bcp47_buf static-buffer + no-cascade + no-alloc guarantees S3 depends on. S2 implemented in file."

# PRD normative source
- file: PRD.md
  section: "§8.1 (HTML document envelope — title 'Configurable via --title'; lang 'default en; configurable via @tmux-2html-lang / locale')"
  why: "Normative requirement this wiring satisfies."

# Empirical verification for THIS task
- file: plan/002_e3d8d22c088d/P1M1T1S3/research/findings.md
  why: "Documents the 636->729 line drift, the four-arm reuse table, the type match, the golden-invisibility proof, and the bcp47_buf lifetime safety."
```

### Current Codebase tree (relevant slice)

```bash
tmux-2html/
├── src/
│   ├── render.zig        # <— THE ONLY FILE TO EDIT (3-line change at the const doc site in run, now :729)
│   ├── cli.zig           # S1 territory — RenderOpts.title/lang already present (DO NOT EDIT)
│   ├── golden_test.zig   # pins renderDocument bytes (bypasses run) — must stay byte-equal
│   ├── main.zig          # S4 territory (pane wiring)        (DO NOT EDIT)
│   └── region.zig        # S4 territory (region wiring)      (DO NOT EDIT)
├── build.zig             # zig build test roots at src/main.zig module (picks up render.zig + golden tests)
└── PRD.md                # §8.1 normative
```

### Desired Codebase tree with files to be changed

```bash
tmux-2html/
└── src/
    └── render.zig        # MODIFIED IN PLACE — the single `const doc = DocumentOpts{...}` in run
                          #   becomes 3 lines (compute title + lang, then build doc with all 3 fields).
                          #   NO new files. NO other files. NO --help change.
```

### Known Gotchas of our codebase & Library Quirks

```zig
// GOTCHA 1 — line drift 636 -> 729. The item description cites render.zig:636, but S2
//   inserted the lang-resolution block (~120 lines) AFTER DocumentOpts. The const doc
//   site is now :729. ALWAYS match on the exact TEXT (it is unique in the file):
//       const doc = DocumentOpts{ .title = "tmux-2html", .background = colors.background };
//   not on a line number. (research/findings.md §1.)

// GOTCHA 2 — tests MUST run in ReleaseFast. `zig build test` (Debug) fails with a known
//   Zig 0.15.2 linker bug (R_X86_64_PC64) from ghostty-vt's bundled C++ SIMD libs — NOT a
//   code error. Always use:
//       zig build test -Doptimize=ReleaseFast
//   (plan/001 findings_and_corrections.md §4; PRD §15; S1/S2 PRPs.)

// GOTCHA 3 — the goldens are GOLDEN-INVARIANT to this edit, but only because they call
//   renderDocument DIRECTLY (golden_test.zig:22,:57) with their OWN DocumentOpts literal
//   (golden_test.zig:29,:64: .title="tmux-2html", lang defaults "en"). They never call run.
//   So editing run's doc construction is provably invisible to them. AFTER the edit, run
//   `zig build test -Doptimize=ReleaseFast` and confirm the two golden tests still pass
//   byte-equal — if they change, you edited the wrong site or accidentally touched
//   renderDocument/writeDocument. (research/findings.md §5.)

// GOTCHA 4 — resolveLang returns a slice into the MODULE-LEVEL bcp47_buf (render.zig:203)
//   OR the string literal "en". Both have static lifetime -> no free needed. doc.lang holds
//   the slice. It stays valid because NOTHING between the resolveLang(opts.lang) call and the
//   consumption of doc.lang (in writeDocument via whichever arm runs) re-invokes
//   toBcp47/resolveLang/langFromEnv. (research/findings.md §7; S2 PRP Gotcha 2.) Do NOT add
//   a duplicate/dup call or copy — the single resolved slice is sufficient.

// GOTCHA 5 — do NOT add --title/--lang unit tests for run here. The codebase deliberately
//   does NOT unit-test run (it does I/O: stdin, file write, xdg-open). The tested layer is
//   the pure primitives (renderGrid/writeDocument/writeDocumentBytes/renderDocument). Formal
//   --title/--lang OUTPUT assertion tests are owned by P1.M1.T3.S1. S3's proof is a binary
//   smoke check (Level 3) + the golden-unchanged gate. (research/findings.md §6.)

// GOTCHA 6 — opts.title/opts.lang are ?[]const u8 (nullable). `opts.title orelse "tmux-2html"`
//   yields []const u8 for DocumentOpts.title. resolveLang already accepts ?[]const u8, so pass
//   opts.lang DIRECTLY — do not unwrap it first.

// GOTCHA 7 — --help text is OWNED BY S1 (it is already correct: cli.zig:310-311 documents
//   --title/--lang). S3 does NOT touch --help. DOCS: none here, per contract.
```

## Implementation Blueprint

### Data models and structure

No new types. `DocumentOpts` (`render.zig:187`) already has `title: []const u8`,
`lang: []const u8 = "en"`, `background: ?ghostty_vt.color.RGB = null`. S3 merely populates
`title` and `lang` from resolved inputs instead of hard-coding `title` and leaving `lang`
at its default.

### The exact deliverable — verbatim edit

In `src/render.zig`, inside `pub fn run` (starts :708), replace the single line at **:729**:

```zig
// ---- BEFORE (exact text — unique in the file) ----
    const doc = DocumentOpts{ .title = "tmux-2html", .background = colors.background };
```

with:

```zig
// ---- AFTER ----
    // PRD §8.1: --title/--lang (S1) resolved here (S2's resolveLang). All four output arms
    // (--output/--open/stdout/--selection) reuse this `doc`, so resolving once propagates to all.
    // title: explicit --title, else "tmux-2html". lang: explicit --lang/normalize, else locale, else "en".
    // resolveLang returns a slice into module-level bcp47_buf (or "en"); both static — no free.
    const title = opts.title orelse "tmux-2html";
    const lang = resolveLang(opts.lang);
    const doc = DocumentOpts{ .title = title, .lang = lang, .background = colors.background };
```

That is the ENTIRE change. Surrounding lines are untouched (the `const stderr = …` above
and the `if (opts.selection)` block below stay exactly as-is).

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: EDIT the const doc site in src/render.zig (inside pub fn run, :729)
  - MATCH on exact text: `const doc = DocumentOpts{ .title = "tmux-2html", .background = colors.background };`
    (do NOT rely on the line number — S2 shifted it from 636 to 729; match the unique string).
  - REPLACE with the 3-line form above (title = opts.title orelse "tmux-2html"; lang = resolveLang(opts.lang);
    const doc = DocumentOpts{ .title = title, .lang = lang, .background = colors.background };).
  - KEEP the two-line comment minimal (or omit) — the surrounding code is self-documenting.
  - DO NOT touch DocumentOpts struct (:187), writeDocument (:310), renderDocument (:359),
    the four arms, or anything outside run. DO NOT touch cli.zig / main.zig / region.zig.
  - DO NOT add a duplicate/copy of the lang slice — the single resolveLang result is reused
    (bcp47_buf is stable until doc.lang is consumed — Gotcha 4).
  - WHY FIRST: the build (Task 2) and smoke checks (Task 3) exercise this wiring.

Task 2: VALIDATE — goldens unchanged + full test suite green
  - RUN: zig build test -Doptimize=ReleaseFast   -> expect exit 0, ALL tests pass
  - CRITICAL CHECK: the two golden tests still pass BYTE-EQUAL (they bypass run; this proves
    the CRITICAL INVARIANT from the contract). If they change, you edited the wrong site.
  - NOTE: plain `zig build test` (Debug) fails with an unrelated linker bug — use ReleaseFast (Gotcha 2).

Task 3: VALIDATE — binary smoke checks (title + lang wired across the four arms)
  - RUN: zig build --release=fast
  - STDOUT arm: echo '' | ./zig-out/bin/tmux-2html render --title "My Pane" --lang fr
      -> grep for <title>My Pane</title> and <html lang="fr">
  - DEFAULTS: echo '' | ./zig-out/bin/tmux-2html render
      -> <title>tmux-2html</title> and <html lang="…"> (en or locale-derived)
  - NORMALIZATION: echo '' | ./zig-out/bin/tmux-2html render --lang en_US.UTF-8
      -> <html lang="en-US">
  - ESCAPE (title with HTML metachar): echo '' | ./zig-out/bin/tmux-2html render --title 'a < b & c'
      -> <title>a &lt; b &amp; c</title> (writeEscaped handles it — confirms no regression)
  - --output arm: echo '' | ./zig-out/bin/tmux-2html render --title X --lang de --output /tmp/s3.html
      then grep /tmp/s3.html for <title>X</title> and <html lang="de"> (proves --output arm reuses doc).
  - Expected: every arm reflects the resolved title/lang (see Validation Loop for exact commands).
```

### Implementation Patterns & Key Details

```zig
// PATTERN: resolve once at the single doc chokepoint; all four arms inherit it.
//   run builds doc ONCE (:729), then:
//     --selection: writeDocFileAtomic(…, doc, html) / writeDocumentBytes(…, doc, html)
//     --output:    renderToFileAtomic(…, opts.font, doc)
//     --open:      renderToFileAtomic(…, opts.font, doc)
//     stdout:      renderDocument(…, opts.font, doc, &fw.interface)
//   writeDocument emits <html lang="{doc.lang}"> and <title>{doc.title}</title> (HTML-escaped).

// PATTERN: orelse for the nullable title; pass nullable lang straight to resolveLang.
const title = opts.title orelse "tmux-2html";   // ?[]const u8 -> []const u8
const lang = resolveLang(opts.lang);            // ?[]const u8 -> []const u8 (en if null/locale unset)

// CRITICAL: goldens call renderDocument DIRECTLY with their own DocumentOpts literal
//   (.title="tmux-2html", lang defaults "en") and NEVER call run. So this edit is invisible
//   to them. Verify: zig build test -Doptimize=ReleaseFast -> golden tests still byte-equal.

// CRITICAL: resolveLang is in the SAME file (render.zig:281) — NO import. opts is already the
//   cli.RenderOpts parameter of run (in scope). No new deps, no new alloc.
```

### Integration Points

```yaml
THIS TASK (single 3-line edit, no new integration):
  - src/render.zig: the `const doc = …` site in run (:729) gains resolved title + lang.

DOWNSTREAM (NOT this task — do not implement):
  - S4: main.zig (pane) + region.zig — honor opts.title override + opts.lang via resolveLang
        in THEIR DocumentOpts constructions (pane passes a contextual title today).
  - P1.M1.T2.S1: tmux-2html.tmux threads @tmux-2html-title/@tmux-2html-lang as --title/--lang
        (lands in opts.title/opts.lang, which S3 now consumes).
  - P1.M1.T3.S1: formal --title/--lang output assertion tests + isolated-tmux output-path smoke
        (S3 provides only the wiring + a binary smoke proof).

CONFIG / DATABASE / ROUTES:
  - none. (Pure in-process field population; reads opts + LC_ALL/LC_MESSAGES/LANG via resolveLang.)
```

## Validation Loop

> PRIMARY gates: (1) `zig build test -Doptimize=ReleaseFast` exits 0 with goldens
> byte-equal (the CRITICAL INVARIANT); (2) binary smoke shows title+lang wired on all arms.

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# The optimized build IS the syntax/type check. Confirm the 3-line edit compiles.
zig build --release=fast 2>&1 | head -20
# Expected: success. An `error:` naming render.zig means a typo in the edit — the exact
# replacement above is type-checked (opts.title ?[]const u8 orelse -> []const u8;
# resolveLang(?[]const u8) -> []const u8; DocumentOpts.title/lang both []const u8).
```

### Level 2: Unit & Golden Tests (PRIMARY gate — goldens must be byte-equal)

```bash
# Full suite incl. the two golden tests. MUST use ReleaseFast (Gotcha 2).
zig build test -Doptimize=ReleaseFast
# Expected: exit 0. ALL tests pass. CRITICAL: the two golden tests in golden_test.zig still
# pass BYTE-EQUAL (they call renderDocument directly with their own DocumentOpts literal and
# never call run, so this edit is invisible to them). If a golden test changes, STOP — you
# edited the wrong site or touched renderDocument/writeDocument; revert and re-match the text.
```

### Level 3: Integration / Binary Smoke (proves the wiring across the four arms)

```bash
zig build --release=fast
BIN=./zig-out/bin/tmux-2html

# --- stdout arm: explicit title + lang ---
echo '' | $BIN render --title "My Pane" --lang fr > /tmp/s3_out.html
grep -o '<title>[^<]*</title>'     /tmp/s3_out.html   # expect: <title>My Pane</title>
grep -o '<html lang="[^"]*"'       /tmp/s3_out.html   # expect: <html lang="fr"

# --- defaults (no flags) ---
echo '' | $BIN render > /tmp/s3_def.html
grep -o '<title>[^<]*</title>'     /tmp/s3_def.html   # expect: <title>tmux-2html</title>
grep -o '<html lang="[^"]*"'       /tmp/s3_def.html   # expect: <html lang="en"> (or locale)

# --- normalization (locale form -> BCP-47) ---
echo '' | $BIN render --lang en_US.UTF-8 > /tmp/s3_norm.html
grep -o '<html lang="[^"]*"'       /tmp/s3_norm.html  # expect: <html lang="en-US"

# --- title HTML-escaping (no regression in writeEscaped) ---
echo '' | $BIN render --title 'a < b & c' > /tmp/s3_esc.html
grep -o '<title>[^<]*</title>'     /tmp/s3_esc.html   # expect: <title>a &lt; b &amp; c</title>

# --- --output arm (proves --output reuses the same resolved doc) ---
echo '' | $BIN render --title X --lang de --output /tmp/s3_file.html
grep -o '<title>[^<]*</title>'     /tmp/s3_file.html  # expect: <title>X</title>
grep -o '<html lang="[^"]*"'       /tmp/s3_file.html  # expect: <html lang="de"

# Expected: every grep prints exactly the documented line. If an arm does NOT reflect the
# resolved title/lang, the edit did not land at the run chokepoint (re-check Task 1).
```

### Level 4: Creative & Domain-Specific Validation

```bash
# --open arm smoke (best-effort; headless may have no xdg-open — the render still succeeds).
#   Confirms the --open path (renderToFileAtomic to a temp file) also carries resolved doc.
echo '' | $BIN render --title OPEN --lang es --open 2>/dev/null
# (xdg-open may print nothing/fail in CI; that is fine. The point is the render completes
#  exit 0 and the temp file it wrote carries the resolved envelope. Skip if no display.)

# --selection arm is owned by S4 (--selection coordinate plumbing); S3 does NOT test it.
# (The selection arm reuses the same `doc`, so the wiring is transitively covered once S3
#  lands. T3.S1 covers selection-level integration.)

# Confirm --help text is UNCHANGED (S1 owns it) — a diff regression guard:
$BIN render --help | grep -E -- '--title|--lang'   # expect both help lines still present, unchanged
```

## Final Validation Checklist

### Technical Validation

- [ ] `zig build --release=fast` succeeds (Level 1).
- [ ] `zig build test -Doptimize=ReleaseFast` exits 0 (Level 2).
- [ ] Both golden tests pass BYTE-EQUAL (CRITICAL INVARIANT — they bypass `run`).
- [ ] No existing test regressed (there is no `run`-level test, so this is automatic).

### Feature Validation

- [ ] stdout arm: `--title X --lang fr` → `<title>X</title>` + `<html lang="fr">`.
- [ ] defaults: `<title>tmux-2html</title>` + `<html lang="…">` (en/locale).
- [ ] normalization: `--lang en_US.UTF-8` → `<html lang="en-US">`.
- [ ] `--output` arm reflects the resolved title + lang (same `doc` reused).
- [ ] title HTML-escaping intact (`--title 'a < b & c'` → escaped).
- [ ] `--help` text unchanged (S1 owns it).

### Code Quality Validation

- [ ] Only `src/render.zig` modified; the change is the single `const doc` site in `run`.
- [ ] No new files, functions, imports, or allocations.
- [ ] `resolveLang(opts.lang)` called exactly once; result reused (no `bcp47_buf` aliasing).
- [ ] No per-arm duplication — all four arms inherit the resolved `doc`.
- [ ] Naming/placement matches codebase conventions (no new patterns introduced).

### Documentation & Deployment

- [ ] No user-facing/help change (DOCS: none — `--help` owned by S1).
- [ ] No new env vars (reads LC_ALL/LC_MESSAGES/LANG via the existing S2 resolver).

---

## Anti-Patterns to Avoid

- ❌ Don't match on line number `636` — S2 shifted the site to `:729`. Match on the exact
  unique TEXT of the `const doc = …` line.
- ❌ Don't run plain `zig build test` — it fails on the Debug linker bug
  (`R_X86_64_PC64` from ghostty-vt's C++ libs). Use `zig build test -Doptimize=ReleaseFast`.
- ❌ Don't touch `renderDocument` / `writeDocument` / `DocumentOpts` struct / the four arms —
  they already do the right thing. S3 is the ONE `const doc` line in `run`.
- ❌ Don't add `--title`/`--lang` unit tests for `run` here — the codebase doesn't unit-test
  `run` (I/O dispatcher); formal output tests are owned by P1.M1.T3.S1. S3 proves wiring
  via the Level 3 binary smoke + the golden-unchanged gate.
- ❌ Don't duplicate/copy the resolved lang slice or call `resolveLang` more than once —
  `bcp47_buf` would alias; the single result is stable until consumed (Gotcha 4).
- ❌ Don't unwrap `opts.lang` before passing to `resolveLang` — it accepts `?[]const u8`
  directly. `opts.title` uses `orelse`; `opts.lang` does not.
- ❌ Don't edit cli.zig / main.zig / region.zig / golden_test.zig — S1 owns the flags, S4 owns
  pane/region, and the goldens must stay byte-equal (which they will, untouched).
- ❌ Don't change `--help` text — S1 owns it and it is already correct.

---

**Confidence Score: 10/10** for one-pass implementation success.

This is a three-line, type-checked replacement at a single unique site. The input types
(`opts.title`/`opts.lang` = `?[]const u8`, from S1) match the consumers exactly
(`orelse` for title; `resolveLang(?[]const u8)` for lang, from S2 — both in the same file,
no import). The four output arms already reuse `doc`, and `writeDocument` already emits
both envelope attributes from `doc` fields (HTML-escaped), so no per-arm or envelope change
is required. The CRITICAL golden invariant is proven: `golden_test.zig` calls
`renderDocument` directly with its own `DocumentOpts` literal and never `run`, so the edit
is byte-invisible to the pinned suite — verified by `zig build test -Doptimize=ReleaseFast`.
The only non-obvious risk (the `bcp47_buf` static-buffer aliasing) is precluded by the fact
that nothing re-invokes the resolver between `resolveLang(opts.lang)` and the consumption of
`doc.lang`. The implementer is pasting an exit-safe edit and running two verified commands.
