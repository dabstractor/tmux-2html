# PRP — P1.M2.T3.S1: Sync README.md + docs/CONFIGURATION.md changeset documentation (§5 Mode B)

## Goal

**Feature Goal**: Land the **§5 Mode B changeset-level documentation** for the P1 bugfix
changeset. The four implementing subtasks each shipped a code fix **and** their own Mode A
per-subtask doc note; this task owns the **cross-cutting / overview** docs and is the
**backstop** for any Mode A note that was missed. Concretely: (1) make README.md's §8.1
"safe to share / trust in any browser" claim **accurate for the post-changeset state**
(it must reflect that `--font`/`@tmux-2html-font` is now HTML-escaped, not just `<title>`);
(2) confirm/fill the Issue 4 `--lang ""` Mode A note in CONFIGURATION.md if the parallel
P1.M2.T2.S1 did not land it; (3) prove the two safety scripts stay green.

**Deliverable**: **Markdown-only edits to two existing files. No code, no new files.**
1. **`README.md`** — one added sentence in the intro so the HTML-escaping/trust claim covers
   the `font-family` style value (Issue 2), not just `<title>` (Issue 1).
2. **`docs/CONFIGURATION.md`** — *backstop only*: verify the Issue 4 `--lang ""` clarification
   is present in the "How options are read" paragraph; add it **only if absent** (P1.M2.T2.S1
   may already have landed it). Confirm Issues 1 & 2 Mode A notes are present (they are).
3. **Validate** — `sh scripts/check-safety.sh` (stay `0 FAIL`, baseline `16 WARN`) +
   `sh scripts/preflight.sh` (clean) + manual read-through.

**Success Definition**:
- README.md intro states that **every** user-supplied string reaching the HTML — `<title>` **and**
  `--font`/`@tmux-2html-font` — is HTML-escaped, so the "share and trust" guarantee holds for both.
- docs/CONFIGURATION.md contains the Issue 4 `--lang ""` ⇒ locale-derived clarification (whether
  landed by P1.M2.T2.S1 or filled by this backstop). Issues 1 & 2 notes remain present.
- No new doc files created; no `.zig`/`.sh`/`.tmux`/test files touched.
- `sh scripts/check-safety.sh` ⇒ `== result: 0 FAIL(s), 16 WARN(s) ==`, exit 0 (unchanged baseline;
  none of the 16 WARNs are in README.md or CONFIGURATION.md). `sh scripts/preflight.sh` ⇒ clean.

## Why

- **§5 Mode B is this task's reason to exist** (tasks.json): "the catch-all for cross-cutting docs
  that only make sense once the whole changeset is in place." The four Mode A edits are localized
  to each option's row; the README overview and any missed Mode A note have no other owner.
- **The README trust claim is now understated.** PRD §8.1 normatively says "All text inserted into
  the envelope (`<title>`, etc.) is HTML-escaped" and that the document is one you can "open, share,
  and trust in any browser." Before Issue 2, `font-family` was the un-escaped hole; now it is closed
  — but README only mentions `<title>`. Updating README makes the documented guarantee match reality.
- **Defensive backstop.** P1.M2.T2.S1 runs in parallel and owns the Issue 4 Mode A note; if its PR
  lands before this task, the note is present (skip). If not, this task adds it so the changeset's
  docs are complete regardless of subtask ordering. This is exactly the contract's "fill them in here."
- **Zero code risk.** Editing two markdown files cannot break the build, tests, or the binary. The
  only failure mode is a `check-safety.sh` WARN regression, which the guard's prose-skip rule
  (`should_skip()` ignores backticked spans / markdown leaders) makes extremely unlikely.

## What

### The four fixes this changeset ships (the source of truth for the doc summary)

| Issue | Fix (subtask) | One-line behavior |
|---|---|---|
| 1 — apostrophe in `@tmux-2html-title` silently breaks all prefix bindings | P1.M1.T1.S1 | Threaded `@tmux-2html-title`/`@tmux-2html-lang` values are now POSIX shell-escaped (`'\''`) in the generated `run-shell` bindings, so `Bob's pane` works. |
| 2 — `--font` / `@tmux-2html-font` HTML-attribute injection / stored-XSS | P1.M1.T2.S1 | The `font-family` value is HTML-escaped at the emission point, so a `"` can no longer break out of the `<pre style>` attribute and inject attributes/scripts. |
| 3 — `render --output` does not create parent directories | P1.M2.T1.S1 | `render --output` (and `--selection`) now `makePath` the parent dir, matching `pane`/`region`. (No doc owed — `--help` doesn't mention parent dirs.) |
| 4 — `--lang ""` (explicit empty) yields `en` not locale-derived | P1.M2.T2.S1 | An explicit `--lang ""` is now treated as unset and derives from the locale (`LC_ALL`→`LC_MESSAGES`→`LANG`→`en`), consistent with the `@tmux-2html-lang` option. |

### Success Criteria

- [ ] README.md intro's escaping/trust claim covers **both** `<title>` and `--font`/`@tmux-2html-font`.
- [ ] docs/CONFIGURATION.md "How options are read" paragraph contains the `--lang ""` ⇒ locale-derived
      clarification (landed by P1.M2.T2.S1 **or** added by this backstop — not duplicated).
- [ ] docs/CONFIGURATION.md still contains the Issue 1 shell-escape note (lines ~87-88) and the
      Issue 2 font HTML-escape note (line 45) — verified present, unchanged in substance.
- [ ] No new files; only README.md and (conditionally) docs/CONFIGURATION.md edited.
- [ ] `sh scripts/check-safety.sh` ⇒ `0 FAIL(s), 16 WARN(s)`, exit 0 (no new WARN/FAIL).
- [ ] `sh scripts/preflight.sh` ⇒ no giant files / residue (exit 0, report clean).
- [ ] Manual read-through: no stale claims; README ↔ CONFIGURATION.md ↔ PRD §8.1 consistent.

## All Needed Context

### Context Completeness Check

_Pass: "If someone knew nothing about this codebase, would they have everything needed to implement
this successfully?"_ — Yes. The two exact edit anchors (README intro lines 11-15; CONFIGURATION.md
"How options are read" paragraph lines ~84-88) are quoted verbatim below; the README AFTER text and
the backstop sentence are ready to paste; the Mode A status of all four issues is verified against
git HEAD (`c930c1a`) and the check-safety baseline is captured (`0 FAIL, 16 WARN`). The implementer
edits one sentence in README and conditionally one sentence in CONFIGURATION.md, then runs two
read-only safety scripts.

### Documentation & References

```yaml
# MUST READ — this task's own audit (Mode A status table + README gap analysis + baseline)
- file: plan/002_e3d8d22c088d/bugfix/001_ce4fa4f55ddc/P1M2T3S1/research/findings.md
  why: "§1 the per-issue Mode A status (Issues 1&2 LANDED, Issue 3 none owed, Issue 4 = backstop);
        §3 the README intro gap (only <title> mentioned; must add --font); §5 the exact
        check-safety baseline (0 FAIL, 16 WARN, all in plan/**/PRP.md)."
  critical: "Issue 4 Mode A is the ONLY conditional edit — re-read the paragraph at execution
             time and add the sentence ONLY if absent (P1.M2.T2.S1 may have landed it). Never
             duplicate it."

# MUST EDIT — the project overview (THE primary README deliverable)
- file: README.md
  section: "intro paragraph, lines 11-15 (the single escaping/trust claim: 'HTML-escaped <title>')"
  why: "This is the only place README states the §8.1 trust/escaping guarantee. After Issue 2 it
        understates reality (font-family is also escaped). Expand to cover both."
  pattern: "README is high-level prose; keep the addition to ONE sentence, no new top-level section."

# MUST EDIT (conditionally) — the options reference (backstop for Issue 4)
- file: docs/CONFIGURATION.md
  section: "'How options are read' paragraph, lines ~84-88 (ends '…a title like `Bob's pane` is safe.')"
  why: "P1.M2T2S1's PRP Edit 3 plans to append the --lang '' clarification here. If P1.M2T2S1
        landed it, this paragraph ALREADY has it — SKIP. If absent, append the sentence (Task 2)."
  gotcha: "Do NOT touch the font table row (line 45) or the title/lang shell-escape note (87-88) —
           they are Issues 2 & 1 Mode A, already correct. Issue 3 owes no doc."

# CONTRACT — the normative trust guarantee this task makes README match
- file: PRD.md
  section: "§8.1 HTML document envelope (normative): 'All text inserted into the envelope (<title>,
            etc.) is HTML-escaped'; 'a standalone HTML document you can open, share, and trust in
            any browser.'"
  why: "README's escaping claim must reflect this. Issue 2 extended 'etc.' to include font-family."

# CONTRACT SOURCE — the Mode A/Mode B convention + this task's exact contract
- file: plan/002_e3d8d22c088d/bugfix/001_ce4fa4f55ddc/tasks.json
  section: "P1.M2.T3.S1 context_scope (§5 Mode B); each subtask's context_scope §5 DOCS [Mode A]"
  why: "Confirms Mode A rides-with-the-work, Mode B is the cross-cutting backstop; lists the four
        Mode A obligations verbatim."

# PARALLEL-TASK CONTRACT — defines the Issue 4 Mode A note this task may backstop
- file: plan/002_e3d8d22c088d/bugfix/001_ce4fa4f55ddc/P1M2T2S1/PRP.md
  section: "Edit 3 (docs/CONFIGURATION.md) — the verbatim --lang '' sentence"
  why: "If P1.M2T2S1 has NOT landed its Edit 3, paste THIS EXACT sentence (Task 2 below) so the two
        tasks don't diverge in wording. If it HAS landed it, the wording already matches."

# SAFETY GATES — run-only (AGENTS.md §2/§3); DO NOT EDIT
- file: scripts/check-safety.sh
  why: "Final safety gate (contract LOGIC d). Baseline = 0 FAIL, 16 WARN (all in plan/**/PRP.md).
        Markdown prose edits are skipped by should_skip() (backtick spans / md leaders) — stay green."
- file: scripts/preflight.sh
  why: "Residue/giant-file report. This task creates neither; expect a clean report, exit 0."
```

### Current Codebase tree (relevant slice — this task's starting point)

```bash
tmux-2html/
├── README.md              # <— EDIT: intro escaping/trust claim (add --font)             [ALWAYS]
├── docs/
│   └── CONFIGURATION.md   # <— EDIT (backstop): --lang "" note IF P1.M2T2S1 missed it   [CONDITIONAL]
├── scripts/
│   ├── check-safety.sh    # run-only (validation gate); DO NOT EDIT
│   └── preflight.sh       # run-only (validation gate); DO NOT EDIT
└── (no other files touched — no .zig/.sh/.tmux/test changes)
```

### Desired Codebase tree with files to be changed

```bash
tmux-2html/
├── README.md              # MODIFIED — +1 sentence in intro (font-family escaping; Issue 2)
└── docs/CONFIGURATION.md  # MODIFIED (CONDITIONAL) — +1 sentence IF Issue 4 Mode A is absent
# NO new files. NO code/test/build changes.
```

### Known Gotchas of our codebase & Library Quirks

```markdown
<!-- GOTCHA 1 — ISSUE 4 IS A CONDITIONAL BACKSTOP, NOT AN UNCONDITIONAL EDIT.
     P1.M2.T2.S1 runs in parallel and owns the Issue 4 Mode A note in the SAME "How options are
     read" paragraph. This task runs AFTER it (T3 depends on T2). RE-READ the paragraph at
     execution time:
       - If the --lang "" sentence is ALREADY there → SKIP (do NOT duplicate / reword).
       - If it is ABSENT → append the exact sentence from Task 2 (matches P1M2T2S1's wording).
     Never add the sentence twice; never collide by editing the same line P1.M2T2S1 just wrote. -->

<!-- GOTCHA 2 — DO NOT RE-EDIT THE LANDED MODE A NOTES.
     Issues 1 (title/lang shell-escape, CONFIGURATION.md ~87-88) and 2 (font HTML-escape, line 45)
     are already committed (commits 6626071, 916035f). Verify they are present; do not reword them
     unless a claim is factually wrong. Rewording risks a merge conflict with nothing gained. -->

<!-- GOTCHA 3 — ISSUE 3 OWES NO DOC. render --help does not mention parent-directory creation,
     and neither README nor CONFIGURATION.md ever claimed --output fails on missing dirs. Do not
     invent a note for it. (If you find a stale claim that --output requires the dir to exist,
     remove it — but none exists at HEAD; verified.) -->

<!-- GOTCHA 4 — README IS HIGH-LEVEL; DON'T OVER-EDIT.
     The shell-escaping of title/lang in bindings (Issue 1) is a plugin-binding detail that lives
     in CONFIGURATION.md, not README. Add it to README ONLY as an optional, clearly-marked extra
     (Task 4). The REQUIRED README change is the single intro trust/escaping sentence (Task 1). -->

<!-- GOTCHA 5 — check-safety.sh SKIPS PROSE. Its should_skip() ignores backticked spans, '#'/‘//’
     comments, and markdown list/quote/table leaders. So escaped-attribute examples like
     `&quot;` or `--font 'a" onmouseover="alert(1)'` inside backticks will NOT trip R3/R4. The
     baseline is 0 FAIL / 16 WARN (all in plan/**/PRP.md). Your edits must keep it there. -->

<!-- GOTCHA 6 — THIS IS A DOCS TASK: NO `zig build` / `zig build test` GATE.
     The four code fixes each shipped their own proven test + build gate. Touching markdown cannot
     affect the build. The gates for THIS task are check-safety.sh + preflight.sh + manual review.
     (An OPTIONAL binary smoke in Level 3 re-confirms the --font claim but tests P1.M1.T2.S1, not
     these docs.) -->
```

## Implementation Blueprint

### Data models and structure

Not applicable — pure Markdown documentation. No types, schemas, or data flow.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 0: RE-READ the two target files at execution time (do not trust stale line numbers)
  - READ README.md (intro, lines ~9-16) and docs/CONFIGURATION.md ("How options are read",
    lines ~78-90; font row line ~45; title/lang note ~87-88).
  - WHY: P1.M2.T2.S1 may have shifted line numbers / landed the Issue 4 sentence. Anchor edits
    on the QUOTED TEXT, not line numbers.
  - CONFIRM: Issues 1 & 2 Mode A notes are present (font row HTML-escape; title/lang shell-escape).
    If somehow absent, add them too (backstop covers all four) — but at HEAD they are present.

Task 1: EDIT README.md — make the §8.1 trust/escaping claim cover --font (REQUIRED)
  - ANCHOR (verbatim, unique — the intro paragraph, lines 11-15):
      Every capture is a complete, valid HTML5 document — a single
      `<!DOCTYPE html>`…`</html>` with a `<head>` (charset, viewport, and an
      HTML-escaped `<title>`) and a `<body>` whose page background matches the
      terminal's, so it opens cleanly in any browser with no wrapping page.
  - REPLACE WITH (one added sentence after the existing paragraph; keeps the original intact):
      Every capture is a complete, valid HTML5 document — a single
      `<!DOCTYPE html>`…`</html>` with a `<head>` (charset, viewport, and an
      HTML-escaped `<title>`) and a `<body>` whose page background matches the
      terminal's, so it opens cleanly in any browser with no wrapping page.
      Every user-supplied string that reaches the HTML — the document `<title>`
      and the CSS `font-family` set by `--font` / `@tmux-2html-font` — is
      HTML-escaped, so a crafted value can never inject markup, attributes, or
      scripts into a capture you share.
  - WHY: Issue 2 closed the last un-escaped hole (font-family). README's "trust in any browser"
    guarantee (PRD §8.1) now genuinely holds for both vectors. This single sentence makes the
    documented guarantee match reality without a new section (contract: prefer existing prose).
  - DO NOT add a new top-level "Security"/"Trust" section — the intro already carries the claim.

Task 2: CONDITIONALLY EDIT docs/CONFIGURATION.md — Issue 4 backstop (ONLY IF ABSENT)
  - RE-READ the "How options are read" paragraph (the one ending "…a title like `Bob's pane` is safe.").
  - IF it ALREADY contains a sentence saying `--lang ""` is treated as unset / locale-derived
    (P1.M2.T2.S1 landed it): SKIP THIS TASK ENTIRELY. Do not duplicate.
  - IF ABSENT, append this EXACT sentence (wording matches P1M2T2S1's PRP Edit 3 to avoid divergence)
    to the end of that paragraph, after "…a title like `Bob's pane` is safe.":
      Passing `--lang ""` (an explicit empty string) is treated the same as omitting the flag:
      the `<html lang>` value is derived from your locale (`LC_ALL` → `LC_MESSAGES` → `LANG`),
      falling back to `en`. (An explicit non-empty value that fails to parse as a BCP-47 tag —
      e.g. `C` — still falls back to `en`.)
  - WHY: Issue 4's behavior change must be documented at the option/flag reference. This is the
    backstop contract item ("If any Mode A updates were missed by the implementing subtasks,
    fill them in here").
  - DO NOT touch the font row (line 45) or the title/lang shell-escape note (87-88) — verified present.

Task 3 (OPTIONAL, low priority): README.md Command-line --lang note (only if you want completeness)
  - ANCHOR: the Command-line section example `tmux-2html render --title "build log" --lang en-US < ansi.txt > out.html`.
  - OPTIONALLY add a one-line aside: omitting `--lang` (or passing `--lang ""`) derives the
    `<html lang>` from your locale; see docs/CONFIGURATION.md.
  - WHY: surfaces Issue 4's user-facing behavior in the quickstart. NOT required — the Configuration
    options-table row already documents locale derivation. Skip if it bloats the section.

Task 4: VALIDATE (see Validation Loop)
  - RUN: sh scripts/check-safety.sh   # expect: 0 FAIL, 16 WARN, exit 0
  - RUN: sh scripts/preflight.sh      # expect: clean report, exit 0
  - MANUAL: read README.md + CONFIGURATION.md top-to-bottom; confirm no stale claims and that the
    escaping/trust wording is consistent across README ↔ CONFIGURATION.md ↔ PRD §8.1.
```

### Implementation Patterns & Key Details

```markdown
<!-- PATTERN: README trust claim stays one sentence, scoped to "what reaches the HTML".
     The §8.1 guarantee is about ENVELOPE/ATTRIBUTE safety (<title> text + style attribute).
     Do not promise things outside the envelope (cell text is ghostty-vt's job; OSC 8 links
     are a deliberate feature, not an injection). "markup, attributes, or scripts" is precise. -->

<!-- PATTERN: the backstop is idempotent. Task 2 checks presence before adding, so running it
     before OR after P1.M2T2.S1 lands the note yields exactly one copy. Anchor the presence
     check on the distinctive substring "--lang \"\" (an explicit empty string)" or
     "derived from your locale" in that paragraph. -->

<!-- CRITICAL: never edit code/build/test files. If you find yourself touching .zig/.sh/.tmux
     or build.zig, STOP — that is a different subtask. This task is markdown-only. -->
```

### Integration Points

```yaml
DOCUMENTATION SURFACE:
  - README.md: the intro trust/escaping claim (Task 1, REQUIRED).
  - docs/CONFIGURATION.md: the Issue 4 --lang "" backstop sentence (Task 2, CONDITIONAL).

PARALLEL / UPSTREAM (contract — do NOT re-implement or collide):
  - P1.M1.T1.S1 (Issue 1, shell-escape) — Mode A LANDED (CONFIGURATION.md ~87-88). Verify only.
  - P1.M1.T2.S1 (Issue 2, font HTML-escape) — Mode A LANDED (CONFIGURATION.md line 45). Verify only.
  - P1.M2.T1.S1 (Issue 3, --output makePath) — no Mode A owed. No edit.
  - P1.M2.T2.S1 (Issue 4, --lang "") — Mode A IN PROGRESS. Task 2 backstops it.

SAFETY GATES (run-only):
  - scripts/check-safety.sh: must stay 0 FAIL / 16 WARN baseline.
  - scripts/preflight.sh: must report clean.

CONFIG / DATABASE / ROUTES / BUILD:
  - none. Pure docs.
```

## Validation Loop

> This is a **documentation-only task**: there is NO Zig build, NO unit test, NO golden gate.
> The four code fixes each carried their own proven test gates (see their PRPs). The gates below
> are the correct ones for a docs task per AGENTS.md §2/§3 and the contract LOGIC (d).

### Level 1: Static safety guard (PRIMARY gate)

```bash
cd /home/dustin/projects/tmux-2html
sh scripts/check-safety.sh
# Expected: "== result: 0 FAIL(s), 16 WARN(s) ==" and exit 0.
#   - The 16 WARNs are ALL pre-existing "PATH-prepend shim recipe" hits inside plan/**/PRP.md docs
#     (captured baseline at HEAD c930c1a). NONE are in README.md or docs/CONFIGURATION.md.
#   - If a NEW WARN or any FAIL references README.md / docs/CONFIGURATION.md, you likely wrote an
#     un-backticked PATH=…:$PATH or `>> calls.log` recipe in prose. Re-wrap it in backticks
#     (should_skip() skips backtick spans) or remove it. The escaping examples (&quot;, --font 'a"…')
#     inside backticks are safe.
sh scripts/preflight.sh
# Expected: clean report — "(none)" under giant files and residue; exit 0 (always). This task
#   creates no scratch/giant files, so any surprise is from another run — note it, don't delete
#   blindly (AGENTS.md §5).
```

### Level 2: Markdown sanity (manual read-through)

```bash
# Confirm the two edits landed exactly once and read well. Anchor on the distinctive strings:
grep -n "and the CSS \`font-family\`" README.md            # Expected: exactly ONE match (Task 1)
grep -nc "explicit empty string" docs/CONFIGURATION.md     # Expected: 0 (if P1.M2T2.S1 landed it
                                                           #   before you) OR 1 (if you added it).
                                                           #   NEVER > 1 (no duplication).
grep -n "HTML-escaped when emitted into the \`style\`" docs/CONFIGURATION.md  # Expected: 1 (Issue 2, present)
grep -n "POSIX" docs/CONFIGURATION.md                       # Expected: 1 (Issue 1, present)

# No code files changed:
git diff --stat -- '*.zig' '*.sh' '*.tmux' build.zig build.zig.zon 'tests/*'  # Expected: no output
git diff --stat README.md docs/CONFIGURATION.md            # Expected: README always; CONFIGURATION
                                                           #   conditional on Task 2.

# Optionally render to eyeball formatting (markdownlint if available, else just read):
command -v markdownlint >/dev/null && markdownlint README.md docs/CONFIGURATION.md || echo "(no markdownlint; visual review)"
```

### Level 3: Consistency cross-check (README ↔ CONFIGURATION ↔ PRD §8.1)

```bash
# The README trust claim must now mention BOTH <title> and font-family (the §8.1 vectors):
grep -c -i 'font-family\|--font\|@tmux-2html-font' README.md   # Expected: >=1 (Task 1 added it)

# Confirm no STALE claim that --output requires a pre-existing dir (Issue 3 made this false):
grep -ni 'output.*exist\|cannot write\|parent director\|must exist' README.md docs/CONFIGURATION.md
# Expected: no hits (Issue 3 owed no doc; nothing stale to remove). If a hit appears, remove/fix it.

# Confirm the --lang "" behavior is documented SOMEWHERE in CONFIGURATION.md (Issue 4):
grep -ni 'lang ""\|empty string\|locale-derived\|derived from' docs/CONFIGURATION.md
# Expected: >=1 (the options-table row "Empty ⇒ locale-derived" always counts; plus Task 2's sentence
#   if added).

# OPTIONAL binary smoke — re-confirms the README --font claim holds (tests P1.M1.T2.S1, not the docs):
# zig build --release=fast 2>/dev/null && printf 'x\n' | ./zig-out/bin/tmux-2html render --cols 3 \
#   --rows 1 --font 'a" onmouseover="alert(1)' | grep -o 'font-family: [^;]*;'
# Expected (if run): font-family: a&quot; onmouseover=&quot;alert(1)   (escaped, no breakout)
# Skip if the binary isn't built — this is a re-test of Issue 2, not a gate for this docs task.
```

### Level 4: Final safety re-run (after ALL edits)

```bash
# Re-run both safety scripts one last time (contract LOGIC d — "after all edits"):
sh scripts/check-safety.sh && echo "check-safety: OK" || echo "check-safety: REGRESSION — fix"
sh scripts/preflight.sh
# Expected: check-safety 0 FAIL / 16 WARN (unchanged); preflight clean.
```

## Final Validation Checklist

### Technical Validation

- [ ] `sh scripts/check-safety.sh` ⇒ `0 FAIL(s), 16 WARN(s)`, exit 0 (Level 1 — primary gate).
- [ ] `sh scripts/preflight.sh` ⇒ clean report, exit 0 (Level 1).
- [ ] No code/build/test files changed: `git diff --stat -- '*.zig' '*.sh' '*.tmux' build.zig` empty.
- [ ] README.md and (conditionally) docs/CONFIGURATION.md are the only doc files changed.

### Feature Validation

- [ ] README.md intro states user-supplied strings reaching the HTML — `<title>` AND
      `--font`/`@tmux-2html-font` — are HTML-escaped (the §8.1 trust guarantee, now accurate).
- [ ] docs/CONFIGURATION.md contains the Issue 4 `--lang ""` ⇒ locale-derived note (exactly ONCE).
- [ ] docs/CONFIGURATION.md Issues 1 & 2 Mode A notes still present (font HTML-escape; title/lang
      shell-escape) — verified, substance unchanged.
- [ ] No stale claims: nothing says `--output` requires a pre-existing dir (Issue 3 fixed that).
- [ ] No duplication: the `--lang ""` sentence appears at most once (backstop did not double-add).

### Code Quality Validation

- [ ] README addition is ONE sentence in existing prose (no new top-level section invented).
- [ ] CONFIGURATION.md backstop sentence matches P1M2T2S1's wording verbatim (no divergence).
- [ ] Edits anchor on quoted text, not line numbers (P1.M2.T2.S1 may have shifted lines).
- [ ] No new doc files created (contract §c — prefer updating existing files).

### Documentation & Deployment

- [ ] README ↔ docs/CONFIGURATION.md ↔ PRD §8.1 wording is consistent (manual read-through).
- [ ] Internal markdown links still resolve (README → docs/CONFIGURATION.md, → LICENSE).
- [ ] No new env vars / config / flags (docs-only).

---

## Anti-Patterns to Avoid

- ❌ Don't run `zig build` / `zig build test` as a gate — this is a docs task; markdown edits
  cannot affect the build. The code fixes' gates already passed. (Level 3's binary smoke is OPTIONAL
  and re-tests Issue 2, not this task.)
- ❌ Don't UNCONDITIONALLY add the Issue 4 `--lang ""` sentence to CONFIGURATION.md — P1.M2.T2.S1
  may have already landed it in the SAME paragraph. Re-read first; add ONLY if absent; never duplicate.
- ❌ Don't reword the already-landed Issues 1 & 2 Mode A notes (font row line 45; title/lang ~87-88)
  — they are committed and correct. Rewording risks a pointless merge conflict.
- ❌ Don't invent a doc note for Issue 3 (`--output` makePath) — `render --help` doesn't mention
  parent dirs and no doc ever claimed --output fails on missing dirs. There is nothing to add or remove.
- ❌ Don't create SECURITY.md / CHANGES.md / CHANGELOG.md / a new "Trust" section — contract §c says
  prefer updating existing files. The README intro already carries the trust claim; expand it in place.
- ❌ Don't write un-backticked shell recipes (e.g. a literal `PATH=…:$PATH` or `>> calls.log`) in the
  markdown prose — `check-safety.sh` would flag it. Keep any command examples inside backtick spans
  (which `should_skip()` exempts). The escaping examples (`&quot;`, `--font 'a"…'`) are already backticked.
- ❌ Don't anchor edits on line numbers — P1.M2.T2.S1 edits the same CONFIGURATION.md paragraph and
  may have shifted lines. Anchor on the verbatim quoted text in Task 1 / Task 2.
- ❌ Don't touch any `.zig`/`.sh`/`.tmux`/test/build file — that is a different subtask's scope.
- ❌ Don't skip the final `scripts/check-safety.sh` + `scripts/preflight.sh` re-run — contract LOGIC (d)
  requires them "after all edits," and they are this task's only deterministic gate.

---

**Confidence Score: 9/10** for one-pass implementation success.

This is a tightly-scoped, markdown-only task with two exact edit anchors quoted verbatim (README intro
lines 11-15; CONFIGURATION.md "How options are read" paragraph ending "…`Bob's pane` is safe."), a
ready-to-paste README sentence, and a backstop sentence whose wording is pinned to P1.M2T2.S1's PRP
Edit 3 so the two cannot diverge. The Mode A status of all four issues was verified against git HEAD
(`c930c1a`): Issues 1 & 2 notes are already committed (6626071, 916035f), Issue 3 owes no doc, and
Issue 4 is the single conditional edit (present ⇒ skip; absent ⇒ add). The `check-safety.sh` baseline
is captured (`0 FAIL, 16 WARN`, all in `plan/**/PRP.md`, none in the edited files), and the guard's
prose-skip rule means the escaping examples in backticks cannot trip R3/R4. The one residual risk —
the parallel P1.M2.T2.S1 landing its Issue 4 note in the same paragraph this task may touch — is
explicitly handled by the "re-read, add-only-if-absent, never duplicate" backstop logic in Task 2,
which is idempotent in either execution order. There is no build to break and no test to fail; the
deterministic gates (check-safety + preflight) are read-only and bounded. The 1-point residual is for
the (unlikely) case a reviewer wants README to also surface the shell-escaping binding detail, which
Task 4 covers optionally without being required.