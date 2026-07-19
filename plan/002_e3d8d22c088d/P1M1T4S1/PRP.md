# PRP — P1.M1.T4.S1: README.md — surface standalone complete-HTML5-document output + title/lang config

## Goal

**Feature Goal**: Sync `README.md` to reflect the shipped §8.1 behavior: (1) state that **every
capture is a complete, valid HTML5 document** — a single `<!DOCTYPE html>`…`</html>` with a
charset-first `<head>` (charset/viewport/**HTML-escaped title**), a `<body>` whose page background
equals the terminal background, and exactly one `<pre>` — never a bare fragment; and (2) surface the
two new §8.1 configurability knobs: the **title knob** (`--title` CLI; `@tmux-2html-title` option;
contextual default) and the **lang knob** (`--lang` CLI; `@tmux-2html-lang` / locale-derived, default
`en`). Close the G4 "documentation reflects §8.1" gap for the README half (the CONFIGURATION.md half
landed in P1.M1.T2.S1).

**Deliverable**: **EDIT `README.md` ONLY** — three localized, additive changes (no new files, no code):
1. **Overview/intro** — name the complete-HTML5-document guarantee (keep the existing "standalone"
   wording on line 3; do **not** introduce "fragment" language).
2. **`## Command line`** — one concise example showing `--title`/`--lang` on `render`.
3. **`## Configuration`** — add the `@tmux-2html-title` and `@tmux-2html-lang` table rows, plus a
   short note tying the complete-document guarantee + both knobs + their contextual defaults to the
   existing `docs/CONFIGURATION.md` cross-link (do not duplicate its full options table).

**Success Definition**:
- README's output/config description **matches the shipped §8.1 behavior** — no stale language, no
  invented flags/options, the new `--title`/`--lang`/`@tmux-2html-title`/`@tmux-2html-lang` knobs are
  surfaced, the complete-document guarantee is stated, and the `docs/CONFIGURATION.md` cross-link is
  intact.
- **Only `README.md` is changed** (`git diff --stat` shows a single file). `docs/CONFIGURATION.md`,
  `src/*.zig`, goldens, `build.zig*`, `tmux-2html.tmux` are untouched (owned by T2.S1 / T1 / earlier).
- `zig build test -Doptimize=ReleaseFast` remains green (regression guard — no code touched).

> **CRITICAL — this is a DOCS-ONLY task (Mode B changeset-level docs sync).** The §8.1 envelope, the
> `--title`/`--lang` flags, the lang resolver, the pane/region override wiring, AND
> `docs/CONFIGURATION.md` **already exist and are Complete** (T1.S1–S4, T2.S1, commit 07ab167). This
> task writes **README prose/tables only** — it does not implement, re-spec, or duplicate anything.

## User Persona

**Target User**: A new user reading the GitHub README to decide whether tmux-2html fits their need,
and an existing user who wants to know how to set a custom document `<title>` / `<html lang>`.

**Use Case**: A user opens README, sees that every capture is a real standalone HTML5 document (open
in any browser, no wrapping page needed), and learns they can override the title (`--title` /
`@tmux-2html-title`) and language (`--lang` / `@tmux-2html-lang`) — then follows the cross-link to
`docs/CONFIGURATION.md` for the full options reference.

**Pain Points Addressed**: Today README never tells you the output is a *complete* document (only
"standalone…HTML document" on line 3), and is silent on the title/lang knobs added by §8.1.

## Why

- **PRD §8.1 is normative** ("no cutting corners") and the README is the project's front door — it
  must reflect that every output is a complete HTML5 document, not a `<pre>` blob.
- **Closes G4** (architecture/system_context.md:52): "Documentation reflects §8.1 — MISSING —
  `README.md`, `docs/CONFIGURATION.md`." CONFIGURATION.md is done (T2.S1); README is the last piece.
- **Surfaces real configurability** (G2/G3): T1.S1–S4 shipped `--title`/`--lang` + locale resolution;
  T2.S1 shipped `@tmux-2html-title`/`@tmux-2html-lang` threading. Users can't adopt what isn't
  documented in the README.
- **Zero risk**: prose/markdown edits to one file; cannot regress the binary or tests.

## What

Three additive edits to `README.md`. Semantics:

1. **Overview/intro (near line 3)** — expand the existing "standalone…HTML document" statement to
   state the **complete-HTML5-document guarantee**: a single `<!DOCTYPE html>`…`</html>`, a
   `<head>` with charset/viewport/**HTML-escaped title**, a `<body>` whose page background matches
   the terminal background. Keep "standalone"; do **not** say "fragment". Stay concise.
2. **`## Command line` (examples)** — add one `render` example using `--title`/`--lang` so the CLI
   knobs are visible alongside the existing examples.
3. **`## Configuration` (table + note)** — add two rows (`@tmux-2html-title`, `@tmux-2html-lang`)
   with their defaults, and a concise note describing the contextual title default and the
   locale-derived `lang` (default `en`), cross-linking `docs/CONFIGURATION.md` for the full reference.

### Success Criteria

- [ ] README states the complete-HTML5-document guarantee (DOCTYPE→`</html>`, charset-first head,
      escaped title, page background = terminal background) — **no "fragment" language introduced**.
- [ ] `--title` and `--lang` appear in a `## Command line` example.
- [ ] `@tmux-2html-title` and `@tmux-2html-lang` rows added to the `## Configuration` table, with
      accurate defaults (empty ⇒ contextual title / locale-derived lang).
- [ ] A concise note ties the complete-doc guarantee + the two knobs to the existing
      `docs/CONFIGURATION.md` cross-link (no duplicated full options table).
- [ ] **Only `README.md` changed**; `docs/CONFIGURATION.md`, `src/*`, goldens, build files untouched.

## All Needed Context

### Context Completeness Check

_Pass: "If someone knew nothing about this codebase, would they have everything needed to implement
this successfully?"_ — Yes. The exact current `README.md` structure and the three edit sites are
given below with BEFORE/AFTER anchors; the precise implemented behavior (envelope bytes, title
precedence + **unixtime** format, lang resolution algorithm, option names + defaults) is recorded
verbatim from `src/render.zig`/`main.zig`/`region.zig`. The one sharp edge — the **iso8601 (docs) vs
unixtime (code)** title-format mismatch — is called out with a concrete resolution. No guessing.

### Documentation & References

```yaml
# MUST EDIT — the sole deliverable
- file: README.md
  section: "intro ¶ (line 3); ## Command line (subcommand table + examples + exit codes); ## Configuration (8-row @tmux-2html-* table + docs/CONFIGURATION.md cross-link)"
  why: "THE file. 3 additive edits: complete-doc guarantee in the overview; --title/--lang render example; +2 Configuration rows + a concise note."
  pattern: "Mirror README's existing concise tone + the Configuration table's `| Option | Default | Meaning |` columns + its CONFIGURATION.md cross-link."
  gotcha: "README's ## Configuration table is currently STALE (8 rows) — it predates the title/lang options. Add exactly the 2 new rows; don't reorder."

# MUST READ — the shipped §8.1 behavior to describe ACCURATELY (contract, do NOT re-implement)
- file: src/render.zig
  section: "DocumentOpts (title/lang/background); writeDocument (<!DOCTYPE html>…</html> envelope, charset-first head, viewport, HTML-escaped title); resolveLang/langFromEnv/toBcp47 (precedence: explicit→LC_ALL→LC_MESSAGES→LANG→en; BCP-47 normalize; C/POSIX/empty→en)"
  why: "Source of truth for the exact envelope + lang resolution the README must describe."
- file: src/main.zig
  section: "paneResolveTitle/paneTitle (lines ~316-336): default contextual title `tmux-2html — <session>/<pane> <unixtime>` where <unixtime> = std.time.timestamp() = Unix epoch SECONDS"
  why: "Source of truth for the pane contextual title. CRITICAL: it is a UNIX TIMESTAMP, not ISO 8601 — see Gotcha."
- file: src/region.zig
  section: "regionResolveTitle/regionTitle (lines ~591-620): same contextual title shape as pane"
  why: "region shares the pane contextual title; same unixtime format."

# CONTRACT SOURCES — already-Complete features surfaced by this README sync (treat as contract)
- file: plan/002_e3d8d22c088d/P1M1T1S1/PRP.md   # --title/--lang flags on Render/Pane/RegionOpts
- file: plan/002_e3d8d22c088d/P1M1T1S2/PRP.md   # resolveLang/langFromEnv/toBcp47 + unit tests
- file: plan/002_e3d8d22c088d/P1M1T1S3/PRP.md   # render.run wires DocumentOpts{title,lang}
- file: plan/002_e3d8d22c088d/P1M1T1S4/PRP.md   # pane/region --title override + --lang
- file: plan/002_e3d8d22c088d/P1M1T2S1/PRP.md   # @tmux-2html-title/@tmux-2html-lang threaded into bindings + docs/CONFIGURATION.md rows
  why: "Define exactly what shipped. README must surface these — and must NOT invent flags T1/T2 didn't implement."

# OWNED ELSEWHERE — do NOT duplicate or edit
- file: docs/CONFIGURATION.md
  why: "The full @tmux-2html-* options reference, incl. the title/lang rows + an 'HTML output (§8.1)' note — OWNED by T2.S1 (Complete). README cross-links it; do not restate its full table."

# PARALLEL — validation (in flight; no dependency)
- file: plan/002_e3d8d22c088d/P1M1T3S1/PRP.md
  why: "T3.S1 is the §8.1 end-to-end smoke (tests/envelope_smoke.sh). It does not touch README; this task does not touch tests. No conflict, no dependency."

# NORMATIVE SPEC
- file: PRD.md
  section: "§8.1 (HTML document envelope, normative); §1.1 (Goal: 'Every output is a complete, valid HTML5 document')"
  why: "The requirement this README documents."
```

### Current Codebase tree (T4.S1's starting point)

```bash
tmux-2html/
├── README.md                 # (T4.S1) EDIT — the sole deliverable
├── docs/CONFIGURATION.md     # DONE (T2.S1) — cross-link, do NOT edit/duplicate
├── src/{render,main,region,cli}.zig  # §8.1 COMPLETE (T1.S1–S4) — READ-ONLY
├── src/golden_test.zig + testdata/*  # byte-frozen goldens — READ-ONLY
├── tmux-2html.tmux           # @tmux-2html-title/lang threaded (T2.S1) — READ-ONLY
├── tests/{envelope_smoke,plugin_options}.sh  # (T3.S1 / T2.S1) — READ-ONLY
└── build.zig  build.zig.zon  # READ-ONLY
```

### Desired Codebase tree with files to be changed

```bash
tmux-2html/
└── README.md   # (T4.S1) EDITED — +complete-doc guarantee (overview), +--title/--lang example
                #                     (Command line), +@tmux-2html-title/@tmux-2html-lang rows + note
                #                     (Configuration). One file changed; nothing else.
```

### Known Gotchas of our codebase & Library Quirks

```markdown
# GOTCHA 1 — CRITICAL: the contextual title timestamp is a UNIX TIMESTAMP, NOT ISO 8601.
#   main.zig paneTitle / region.zig regionTitle build: `tmux-2html — <session>/<pane> {d}` with
#   ts = std.time.timestamp() => Unix epoch SECONDS, e.g. `1720000000`. The item description AND
#   docs/CONFIGURATION.md (line 48) say `<iso8601>` — that is INACCURATE to the shipped binary.
#   Contract pts 3+4 ("accurate to the implemented behavior" / "matches the shipped §8.1 behavior")
#   OVERRIDE the item's example format string.
#   RESOLUTION (docs-only; cannot edit code or CONFIGURATION.md here): in README, describe the
#   contextual title at an ACCURATE level — e.g. "includes the session name, pane id, and a Unix
#   timestamp" — WITHOUT claiming ISO 8601 (false) and WITHOUT printing a format string that
#   contradicts CONFIGURATION.md. Defer the exact format to CONFIGURATION.md via the cross-link.
#   Do NOT propagate the iso8601 claim into the README. (Flag the pre-existing doc/impl mismatch
#   in the PR; it is out of scope for this docs-only task.)

# GOTCHA 2 — docs/CONFIGURATION.md is NOT yours. It is owned by T2.S1 (Complete) and already has the
#   @tmux-2html-title / @tmux-2html-lang rows + an "HTML output (§8.1)" note. README must CROSS-LINK
#   it (the existing "[docs/CONFIGURATION.md](docs/CONFIGURATION.md)" link) and must NOT restate its
#   full options table. Editing CONFIGURATION.md = scope violation.

# GOTCHA 3 — the existing README ## Configuration table is STALE: it lists 8 @tmux-2html-* options
#   (full/region/visible-key, output-dir, open, font, history-limit, binary-dir) and is missing
#   @tmux-2html-title / @tmux-2html-lang. Add exactly those 2 rows in the existing 3-column format
#   (`| Option | Default | Meaning |`); do not reorder existing rows.

# GOTCHA 4 — do NOT invent flags/options. The only §8.1 knobs that shipped are --title / --lang
#   (CLI, all 3 subcommands) and @tmux-2html-title / @tmux-2html-lang (tmux options). There is no
#   --document/--doctype/--background flag. Do not promise a fragment/embed mode (explicitly out of
#   scope for v1, PRD §16) — every output is a full document.

# GOTCHA 5 — no code/test/build contact. README is prose/markdown; the only regression guard is
#   re-running `zig build test -Doptimize=ReleaseFast` (must stay green — proves nothing in src/
#   moved). There is no README build step.
```

## Implementation Blueprint

### Data models and structure

None — markdown prose/tables. No data models, no code.

### The three edits (README.md — concise, additive; follow the existing tone)

The current README structure (verified): `# tmux-2html` → intro ¶ (lines 1-6) → `## Capture modes`
→ `## Requirements` → `## Installation` → `## Key bindings` → `## The region overlay` →
`## Command line` (4-row subcommand table + 2 examples + exit codes) → `## Configuration` (8-row
table + CONFIGURATION.md cross-link) → `## Known limitations` → `## License and credits`.

**EDIT 1 — Overview/intro: state the complete-HTML5-document guarantee.**

The current intro ¶ (lines 3-6) is:

```markdown
Capture a tmux pane to a standalone, color-faithful HTML document.

tmux-2html reads the ANSI-colored output of a tmux pane and renders it to a
self-contained HTML file that preserves the terminal colors. The file opens in a
browser, so you can share, archive, or screenshot a pane without an external
screenshot tool.
```

Add a concise sentence/short note — either appended to the existing second paragraph or as a tight
follow-on — stating that **every capture is a complete, valid HTML5 document**: a single
`<!DOCTYPE html>`…`</html>`, a `<head>` with `charset`, `viewport`, and an **HTML-escaped** `<title>`,
and a `<body>` whose **page background matches the terminal background**. Keep the word "standalone";
do **not** introduce "fragment". Example phrasing (adapt to the existing voice):

> Every capture is a complete, valid HTML5 document — a single `<!DOCTYPE html>`…`</html>` with a
> `<head>` (charset, viewport, escaped `<title>`) and a `<body>` whose background matches the
> terminal's, so it opens cleanly in any browser with no wrapping page.

**EDIT 2 — `## Command line`: show `--title`/`--lang` on a `render` example.**

After the existing examples (currently `tmux-2html pane --full` and `tmux-2html render < ansi.txt > out.html`),
add one concise example, e.g.:

```sh
tmux-2html render --title "build log" --lang en-US < ansi.txt > out.html
```

Keep it to one line; do not enumerate every flag (the subcommand table already says "Each accepts
`--help` for its full flag list").

**EDIT 3 — `## Configuration`: add the two option rows + a concise note.**

(a) Add two rows to the existing `@tmux-2html-*` table (3-column `| Option | Default | Meaning |`),
after the existing rows (do not reorder):

| Option | Default | Meaning |
|---|---|---|
| `@tmux-2html-title` | *(empty)* | Document `<title>`. Empty ⇒ the contextual default (`tmux-2html` for `render`; a contextual title including the session, pane id, and a Unix timestamp for `pane`/`region`). |
| `@tmux-2html-lang` | *(empty)* | `<html lang>` attribute (BCP-47). Empty ⇒ derived from the locale (`LC_ALL`/`LC_MESSAGES`/`LANG`), falling back to `en`. |

> Note the title "Meaning" deliberately says **"a Unix timestamp"** (accurate to `std.time.timestamp()`)
> and does **not** claim ISO 8601 — see Gotcha 1. You can also pass `--title`/`--lang` on the CLI
> (they override the option), as shown in the Command line example.

(b) Add a concise note (a few sentences) tying it together + the existing CONFIGURATION.md
cross-link. The README already ends its Configuration section with "See
[docs/CONFIGURATION.md](docs/CONFIGURATION.md) for the full options reference…"; keep/extend that
cross-link so readers get the complete table (incl. title/lang) and the palette cache details. Do
not duplicate CONFIGURATION.md's full table. Example note:

> Every capture is a complete HTML5 document (see above). The `<title>` and `<html lang>` are
> configurable: set `@tmux-2html-title` / `@tmux-2html-lang`, or pass `--title` / `--lang` on the
> command line. See [docs/CONFIGURATION.md](docs/CONFIGURATION.md) for the full options reference.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: EDIT README.md — Overview/intro (EDIT 1)
  - TARGET: the intro ¶ (lines 3-6), keeping line 3's "standalone…HTML document" wording.
  - ADD: 1-2 sentences stating the complete-HTML5-document guarantee (DOCTYPE→</html>, charset-first
        head w/ viewport + escaped <title>, page background = terminal background).
  - CONSTRAINT: do NOT use the word "fragment"; stay concise; match the existing voice.
  - ACCURACY: every claim maps to shipped code (render.zig DocumentOpts/writeDocument; commit 07ab167).

Task 2: EDIT README.md — ## Command line example (EDIT 2)
  - TARGET: after the existing `tmux-2html render < ansi.txt > out.html` example.
  - ADD: one example: `tmux-2html render --title "build log" --lang en-US < ansi.txt > out.html`.
  - CONSTRAINT: one line only; no full flag enumeration (the table already points to --help).

Task 3: EDIT README.md — ## Configuration rows + note (EDIT 3)
  - ADD: @tmux-2html-title + @tmux-2html-lang rows to the existing 3-col table (no reordering).
  - DEFAULTS: title *(empty)* ⇒ contextual (tmux-2html for render; session/pane/Unix-timestamp for
        pane/region — NOT iso8601, Gotcha 1); lang *(empty)* ⇒ locale-derived (LC_ALL→LC_MESSAGES→
        LANG), fallback en.
  - ADD: concise note tying complete-doc + the two knobs + keep the docs/CONFIGURATION.md cross-link.
  - CONSTRAINT: do NOT duplicate CONFIGURATION.md's full table; do NOT edit CONFIGURATION.md.

Task 4: VERIFY scope + regression guard
  - RUN: git diff --stat  → expect ONLY README.md.
  - RUN: zig build test -Doptimize=ReleaseFast  → expect exit 0 (unchanged; no src touched).
  - RUN: grep checks below → knobs surfaced, no "fragment", cross-link intact.
```

### Implementation Patterns & Key Details

```markdown
# PATTERN: surface a knob accurately without over-claiming (title).
#   Implemented: --title / @tmux-2html-title override; else contextual default; else "tmux-2html".
#   render default  -> literal "tmux-2html".
#   pane/region     -> "tmux-2html — <session>/<pane> <unixtime>"  (Unix SECONDS, NOT ISO 8601).
#   README phrasing -> name the components (session, pane, Unix timestamp); defer exact string to
#                      docs/CONFIGURATION.md. Never print "<iso8601>" (false).

# PATTERN: describe lang resolution at the level users act on.
#   Implemented precedence: explicit --lang/@tmux-2html-lang -> LC_ALL -> LC_MESSAGES -> LANG -> "en";
#   normalized to BCP-47 (xx-XX); C/POSIX/empty/invalid -> "en".
#   README phrasing -> "locale-derived, default en" + name the override; details live in CONFIGURATION.md.

# PATTERN: keep the existing cross-link alive.
#   [docs/CONFIGURATION.md](docs/CONFIGURATION.md) already appears in ## Configuration; extend/don't
#   drop it so the full options table (incl. title/lang) stays one click away.
```

### Integration Points

```yaml
THIS TASK (docs-only):
  - README.md: EDITED (overview + Command line + Configuration). The ONLY file changed.

UPSTREAM (already present — contract, do NOT re-implement):
  - T1.S1-S4 (Complete): --title/--lang flags, resolveLang, render.run/pane/region DocumentOpts wiring.
  - T2.S1 (Complete): @tmux-2html-title/@tmux-2html-lang threaded into bindings + docs/CONFIGURATION.md rows.
  - commit 07ab167: the §8.1 envelope (DocumentOpts/writeDocument/renderDocument) + re-blessed goldens.
  - T3.S1 (parallel, in flight): tests/envelope_smoke.sh §8.1 end-to-end smoke — no README contact.

DOWNSTREAM: none. (README is the last G4 artifact for §8.1.)

CONFIG / DATABASE / ROUTES: none. (Markdown prose/tables only.)
```

## Validation Loop

> PRIMARY gate: README content checks (grep) + scope check (git diff --stat) + regression guard
> (Zig suite stays green). This is a docs task — there is no README build step.

### Level 1: Content accuracy & completeness (grep checks)

```bash
cd /home/dustin/projects/tmux-2html

# (a) the complete-document guarantee is present (overview)
grep -niE 'complete.*html5|<!DOCTYPE|charset|viewport|html-escaped|escaped .?title|background.*terminal' README.md
#   expect: at least the DOCTYPE/charset/viewport/escaped-title/page-bg mentions.

# (b) the four knobs are surfaced
grep -niE -- '--title|--lang|@tmux-2html-title|@tmux-2html-lang' README.md
#   expect: --title and --lang (Command line example) + @tmux-2html-title and @tmux-2html-lang (table rows).

# (c) NO "fragment" language introduced (contract pt 4)
grep -niE 'fragment|bare .?pre.? blob|embed' README.md
#   expect: NO output (README must not promise a fragment/embed mode — out of scope, PRD §16).

# (d) the CONFIGURATION.md cross-link is intact
grep -n 'docs/CONFIGURATION.md' README.md
#   expect: the link still present in ## Configuration.

# (e) ACCURACY: README must NOT claim ISO 8601 for the contextual title (code uses Unix seconds)
grep -niE 'iso.?8601' README.md
#   expect: NO output (if it appears, it's inaccurate to the binary — remove/rephrase per Gotcha 1).
```

### Level 2: Scope check — README only

```bash
git diff --stat
# expect: README.md ONLY.
git diff --stat docs/CONFIGURATION.md src/ testdata/ golden_test.zig build.zig build.zig.zon tmux-2html.tmux tests/
# expect: no output (none of these are touched).
```

### Level 3: Regression guard — Zig suite stays green (no code touched)

```bash
zig build test -Doptimize=ReleaseFast
# expect: exit 0 (320 passed, incl. both goldens + all T1 title/lang unit tests). MUST use
# -Doptimize=ReleaseFast (bare `zig build test` hits the Debug R_X86_64_PC64 linker bug — PRD §15).
# This is a guard only: README edits cannot affect it; a non-green result means an unrelated regression.
```

### Level 4: Markdown sanity (optional)

```bash
# If a markdown linter is available (e.g. markdownlint-cli2), run it on README.md.
command -v markdownlint >/dev/null 2>&1 && markdownlint README.md || echo "(markdownlint not installed; visual review only)"
# Expected: no new errors from the added table rows / note (keep 3-col `| Option | Default | Meaning |`).
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1 grep checks pass: complete-doc guarantee present; all four knobs surfaced; **no
      "fragment" language**; CONFIGURATION.md cross-link intact; **no "iso8601" claim**.
- [ ] Level 2: `git diff --stat` shows **only README.md**; no `docs/CONFIGURATION.md`/`src/`/goldens/
      build/`tmux-2html.tmux`/`tests/` touched.
- [ ] Level 3: `zig build test -Doptimize=ReleaseFast` → exit 0 (regression guard; no code moved).

### Feature Validation

- [ ] README states every capture is a **complete, valid HTML5 document** (DOCTYPE→`</html>`,
      charset-first head w/ viewport + **HTML-escaped** title, page background = terminal background).
- [ ] `--title` and `--lang` appear in a `## Command line` example.
- [ ] `@tmux-2html-title` and `@tmux-2html-lang` rows added to the `## Configuration` table with
      accurate defaults (empty ⇒ contextual title / locale-derived lang).
- [ ] The contextual-title description is **accurate to the binary** (Unix timestamp, NOT ISO 8601).
- [ ] A concise note ties the complete-doc guarantee + both knobs to the CONFIGURATION.md cross-link;
      the full options table is **not** duplicated.

### Code Quality Validation

- [ ] Only `README.md` changed; matches the desired codebase tree (one file).
- [ ] Follows the existing README tone, table format (`| Option | Default | Meaning |`), and
      cross-link convention.
- [ ] No invented flags/options; no promise of a fragment/embed mode (PRD §16 out of scope).
- [ ] No edits to files owned by T2.S1 (`docs/CONFIGURATION.md`), T1/T3 (`src/`, `tests/`).

### Documentation & Deployment

- [ ] README is self-consistent and consistent with the shipped binary (title/lang/envelope).
- [ ] The pre-existing iso8601-vs-unixtime doc/impl mismatch is noted in the PR (out of scope here).

---

## Anti-Patterns to Avoid

- ❌ Don't claim the contextual title is **ISO 8601** — the binary emits a **Unix timestamp**
  (`std.time.timestamp()`); describe it accurately and defer the exact format to CONFIGURATION.md
  (Gotcha 1). Contract pts 3+4 ("accurate to implemented behavior") override the item's example.
- ❌ Don't edit `docs/CONFIGURATION.md` — it is owned by T2.S1 (Complete); README only cross-links it
  (Gotcha 2).
- ❌ Don't introduce "fragment"/"embed" language or promise a fragment mode — every output is a full
  document; fragment-only is explicitly out of scope for v1 (PRD §16, Gotcha 4). Contract pt 4.
- ❌ Don't invent flags (`--document`/`--doctype`/`--background`) or enumerate the full flag set —
  only `--title`/`--lang` and `@tmux-2html-title`/`@tmux-2html-lang` shipped (Gotcha 4).
- ❌ Don't touch `src/*.zig`, goldens, `build.zig*`, `tmux-2html.tmux`, or `tests/` — this is a
  README-only docs sync; `zig build test` must stay green as a regression guard (Gotcha 5).
- ❌ Don't run `zig build test` WITHOUT `-Doptimize=ReleaseFast` — Debug hits the `R_X86_64_PC64`
  linker bug (PRD §15).

---

**Confidence Score: 10/10** for one-pass implementation success.

This is a docs-only task with three small, additive edits to a single markdown file, and every edit
site is given with exact BEFORE/AFTER anchors against the current README. The behavior to describe is
recorded verbatim from the shipped code (`render.zig` `DocumentOpts`/`writeDocument`/`resolveLang`;
`main.zig`/`region.zig` contextual titles), and the one sharp edge — the **iso8601 (docs) vs unixtime
(code)** title-format mismatch — is flagged with a concrete, accuracy-preserving resolution (describe
the components, defer the exact string to CONFIGURATION.md, never print `<iso8601>`). The scope is
tight (README only; CONFIGURATION.md/src/tests are explicitly off-limits), the validation is grep +
`git diff --stat` + the Zig regression guard, and no code can regress because none is touched. The
implementer is editing prose to match already-shipped, already-validated (T1.S1–S4 Complete, T2.S1
Complete, T3.S1 smoke in flight) behavior.
