# PRP — P1.M3.T1.S1: Update README.md and overview docs to reflect bug fixes

## Goal

**Feature Goal**: Sweep the cross-cutting user/agent-facing documentation (`README.md`,
`docs/CONFIGURATION.md`, `AGENTS.md`) so that NO prose still describes the pre-fix behavior of the
three shipped fixes (region empty-cell confirm, render `--cols 0`/`--rows 0`, check-safety
scoping). This is the **SOW Mode B final doc sweep** — the implementing subtasks already updated
the inline comments/help/script headers they touched (Mode A); this task covers only the
overview/reference prose.

**Deliverable**: Three reviewed docs (README.md, docs/CONFIGURATION.md, AGENTS.md) with the
**three specific stale references** corrected, and all other prose verified non-stale. No new
sections added (no Changelog/Known-Issues section exists, and the fixes are robustness
improvements, not new capabilities — per the item contract, "no structural change is needed").

**Success Definition**: (1) The two stale region-confirm claims in docs/CONFIGURATION.md no longer
state that region "checks whether a selection was begun"; (2) the AGENTS.md check-safety row
reflects that WARN skips `plan/` and FAIL scans repo-wide via the prose-skip heuristic; (3)
README.md is verified free of stale references (no edit required); (4) `scripts/check-safety.sh`
and `scripts/preflight.sh` still pass clean; (5) no doc describes pre-fix behavior.

## Why

- Docs must not lie about shipped behavior. The Issue 1 fix changed region confirm semantics
  (active-but-blank selections now refuse), and the old docs explicitly contrast region vs render
  in a way that is now wrong.
- The Issue 4 fix changed what `check-safety.sh` flags; AGENTS.md (the normative agent guide)
  describes the old WARN scope, so agents reading it get an inaccurate mental model of the guard.
- A coherent changeset ships its docs in sync. This is the last task before the bug-fix release.

## What

### User-visible behavior
None directly — this is a documentation-only change. Readers of the README, the configuration
reference, and the agent guide see accurate, post-fix descriptions of region confirm, and agents
see an accurate check-safety table.

### Success Criteria
- [ ] docs/CONFIGURATION.md "Confirm and cancel" + "Empty selection" reflect that `region` checks
      the rendered body (agreeing with `render --selection`), and that an empty confirm writes no
      file AND no `.last-output` sidecar.
- [ ] AGENTS.md §3 `check-safety.sh` row reflects WARN skipping `scripts/` AND `plan/`, with FAIL
      scanning repo-wide via the `should_skip()` prose heuristic.
- [ ] README.md reviewed; no stale reference found (no edit needed) — OR edited only if a stale
      reference is found.
- [ ] No new Changelog / Known-Issues / section added.
- [ ] `scripts/check-safety.sh` exits 0; `scripts/preflight.sh` clean; the doc edits introduce no
      shell snippet that itself triggers a FAIL/WARN.

## All Needed Context

### Context Completeness Check

_Passed._ The exact stale strings, their file:line, and their replacement text are given below
(§Implementation Blueprint). A developer with no prior knowledge of this repo can apply the three
edits and run the validation grep/commands.

### Documentation & References

```yaml
# MUST READ — the source of truth for WHAT changed (read before editing docs)
- docfile: plan/004_92f7aeb62a3a/bugfix/001_678d4c980a19/architecture/issue1_region_empty_confirm.md
  why: "Exact region confirm post-fix behavior + the helper reused (render.selectionBodyEmpty)."
  critical: "region now checks the RENDERED BODY, not just 'was a selection begun'. Stderr 'tmux-2html region: selection is empty', exit 1, no file, no .last-output sidecar."

- docfile: plan/004_92f7aeb62a3a/bugfix/001_678d4c980a19/P1M2T1S1/research/findings.md
  why: "Exact post-fix check-safety.sh behavior (Issue 4). WARN skips scripts/ AND plan/; FAIL scans repo-wide; should_skip() drops YAML/JSON key: value prose; result 0 FAIL/0 WARN."
  critical: "The item's baseline is stale (now 6 FAIL/22 WARN). The fix = under_plan() gate on WARN + a should_skip() heuristic for FAIL. Both must be reflected in the AGENTS.md wording."

- docfile: plan/004_92f7aeb62a3a/bugfix/001_678d4c980a19/P1M3T1S1/research/findings.md
  why: "THIS task's research: exact before/after text for all 3 edits + the 'reviewed, not stale' list (so you don't over-edit)."
  section: "§2 (stale refs + before/after), §3 (reviewed-OK, do not edit), §5 (scope discipline)"

# The three files you EDIT (only these; nothing else in the repo)
- file: docs/CONFIGURATION.md
  why: "Edit TWO spots: the 'Confirm and cancel' paragraph (~line 180) and the 'Empty selection' Known-limitations bullet (~line 336). The latter contains the stalest claim ('region checks whether a selection was begun')."

- file: AGENTS.md
  why: "Edit ONE table row: §3 protections table, the scripts/check-safety.sh row (~line 67). Update the WARN scope ('outside scripts/' -> 'outside scripts/ AND plan/') and note the should_skip() prose heuristic for FAIL."

- file: README.md
  why: "REVIEW for stale references (region confirm blurb; --cols mention). Verified via grep: NO stale claim exists. No edit expected — confirm and leave it, unless a re-read finds something."
```

### Current Codebase tree (doc surface only)

```bash
README.md                 # user-facing overview; "Known limitations" section (inherent limits, not bugs)
docs/CONFIGURATION.md     # the reference: options, region overlay, palette, sync-palette, "Known limitations"
AGENTS.md                 # normative agent guide; §3 protections table describes check-safety.sh
# (docs/ contains ONLY CONFIGURATION.md; no CHANGELOG, no docs/README)
```

### Desired Codebase tree

```bash
README.md                 # UNCHANGED (reviewed, no stale reference)
docs/CONFIGURATION.md     # 2 prose edits (Confirm paragraph + Empty-selection bullet)
AGENTS.md                 # 1 table-row edit (check-safety.sh WARN scope + should_skip note)
```

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL: do NOT add a CHANGELOG / "Fixed" / Known-Issues(bugs) section.
# Neither README.md nor docs/CONFIGURATION.md has one; their "Known limitations" sections list
# INHERENT product limits (alt-screen, scrollback cap), not resolved bugs. Per the item contract:
# "If no such section exists, no structural change is needed." Adding bug-fix entries there is a
# category error. Only FIX prose that describes pre-fix behavior.

# CRITICAL: the Issue 2 (render --cols 0/--rows 0 segfault) fix has NO stale doc to update.
# grep confirms no doc claims "--cols 0" is accepted or documents a --cols lower bound. README only
# says "add --cols N" (no constraint claim). So do NOT add new --cols/--rows constraint prose —
# that would be a structural change the contract explicitly defers. Leave it.

# CRITICAL: keep the AGENTS.md wording free of literal dangerous commands. The check-safety.sh row
# must NOT contain a raw `killall tmux` / `exec tmux` / bare `tmux ... kill-server` (the grep rules
# would flag it). Refer to them by NAME ("global tmux kill", "recursive bare-exec tmux") as the
# existing row already does.

# The fixes are ROBUSTNESS improvements to EXISTING features, not new capabilities. Resist the urge
# to expand docs. Tight, faithful wording only.
```

## Implementation Blueprint

### Data models and structure

N/A — documentation-only task. No code, no types.

### Implementation Tasks (ordered; each is an exact text replacement)

```yaml
Task 1: EDIT docs/CONFIGURATION.md — "Confirm and cancel" paragraph (~line 180-183)  [Issue 1]
  - FIND the sentence ending the Confirm paragraph:
      "Confirming with **no** selection prints a warning and exits `1` with no file written."
  - REPLACE with:
      "Confirming with **no selection, or a selection whose rendered body is empty (e.g. a selection covering only blank cells — a trailing blank line)** prints a warning, writes **no file and no `.last-output` sidecar**, and exits `1`."
  - WHY: post-fix an ACTIVE selection over blank cells is also refused (Issue 1); and the sidecar is no longer written either (Issue 3, subsumed). The old wording only covered the inactive case.
  - PRESERVE: the rest of the Confirm paragraph (HTML file, honors @tmux-2html-open, exits 0) and the entire Cancel paragraph.

Task 2: EDIT docs/CONFIGURATION.md — "Known limitations" -> "Empty selection" bullet (~line 336-338)  [Issue 1 — THE stalest claim]
  - FIND the bullet:
      "- **Empty selection.** Confirming an empty selection warns and writes no file (exit `1`). `render --selection` and `region` each guard this in their own way (render checks the rendered body; region checks whether a selection was begun)."
  - REPLACE with:
      "- **Empty selection.** Confirming an empty selection — **no selection begun, or an active selection whose rendered body is all blank cells** (e.g. a single trailing blank line, or an empty rectangle) — warns, writes no file and no `.last-output` sidecar, and exits `1`. Both `render --selection` and `region` guard this by checking the rendered body, so the two paths agree."
  - WHY: "region checks whether a selection was begun" was the EXACT pre-fix behavior the bug fixed. Post-fix region uses render.selectionBodyEmpty() and now AGREES with render.
  - PRESERVE: all other Known-limitations bullets (scrollback, alt-screen, wide chars, OSC 8, binary acquisition, region mouse, region search, concurrent runs).

Task 3: EDIT AGENTS.md — §3 protections table, scripts/check-safety.sh row (~line 67)  [Issue 4]
  - FIND the table cell (3rd column) reading:
      "`grep` rules; **FAIL** on global tmux kill + recursive bare-`exec tmux`; **WARN** on hand-rolled shim recipe (`PATH=…:$PATH` + append) outside `scripts/`. Exits non-zero on FAIL."
  - REPLACE with:
      "`grep` rules; **FAIL** on global tmux kill + recursive bare-`exec tmux`; **WARN** on hand-rolled shim recipe (`PATH=…:$PATH` + append) outside `scripts/` **and `plan/`**. FAIL rules scan repo-wide (including `plan/`) but `should_skip()` drops documentation (backticks, comments, and YAML/JSON `key: \"value\"` prose), so plan/ docs that merely quote the pattern names don't false-positive. Exits non-zero on FAIL."
  - WHY: post-fix WARN skips plan/ (under_plan gate) and FAIL no longer false-positives on plan/ prose (should_skip heuristic). The old "outside scripts/" WARN scope is wrong.
  - GOTCHA: keep the pattern references by NAME (do not write a literal `killall tmux`/`exec tmux` — check-safety would flag this very file). The `PATH=…:$PATH` token in the existing wording is fine (it is the documented recipe name, already present and not flagged).
  - PRESERVE: the rest of §3 (safe-run.sh, with-tmux-audit.sh, preflight.sh, hooks, .gitignore rows) and all other AGENTS.md sections.

Task 4: REVIEW README.md — confirm NO stale reference (expected: no edit)
  - Read README.md "The region overlay" (blurb: "press `Enter` to render the selection to an HTML file, or `q` to cancel") and "Command line" ("add `--cols N`").
  - VERIFY (grep): `grep -niE "selection was begun|always writes|--cols 0|rows 0|outside .scripts." README.md` returns NOTHING.
  - These blurbs are high-level summaries that do NOT contradict post-fix behavior (empty-confirm detail lives in docs/CONFIGURATION.md; no --cols constraint is claimed). LEAVE README.md UNCHANGED.
  - Only edit README.md if a re-read surfaces a stale claim the grep missed. If so, apply the minimal faithful wording fix (do not expand the blurb).

Task 5: REVIEW docs/CONFIGURATION.md line ~104 (region overlay intro) — optional, likely no edit
  - Line ~104: "Confirming a selection renders it to an HTML file (and honors `@tmux-2html-open`). Canceling exits with no output."
  - This is a one-line region-overlay SUMMARY; the confirm/empty detail is fully covered in "Confirm and cancel" (Task 1). LEAVE as-is. (Optional, only if it reads as contradictory: append "(unless the selection is empty — see below)". Not required.)
```

### Implementation Patterns & Key Details

```text
# The single discipline: ONLY change prose that describes pre-fix behavior; do not add capability
# docs or sections. Three edits (Tasks 1-3) + two verify-only reviews (Tasks 4-5).

# Faithful-fact checklist for the new wording (do not deviate):
#   - region empty confirm  -> stderr "tmux-2html region: selection is empty", exit 1, NO file, NO .last-output
#   - render --selection    -> same check (selectionBodyEmpty), the two paths now AGREE
#   - check-safety WARN     -> skips scripts/ AND plan/
#   - check-safety FAIL     -> scans repo-wide; should_skip() drops backticks/comments/YAML-JSON key:"value" prose
#   - Issue 2 (--cols 0)    -> NOT documented anywhere by design; do NOT add --cols constraint prose
```

### Integration Points

```yaml
DOCS (the only files touched):
  - docs/CONFIGURATION.md: 2 edits (Confirm paragraph, Empty-selection bullet).
  - AGENTS.md: 1 edit (§3 check-safety.sh table row).
  - README.md: 0 edits (verify-only).

DEPENDS ON (already shipped / in flight — treat as contracts):
  - P1.M1.T1.* (Issue 1 region empty-confirm) — COMPLETE. Selection-body-empty guard is live in src/region.zig.
  - P1.M1.T2.* (Issue 2 render zero-dimension) — COMPLETE. No doc change required (no stale claim).
  - P1.M2.T1.S1 (Issue 4 check-safety scoping) — IN FLIGHT (parallel). Its PRP/research define the
    exact post-fix check-safety behavior used in Task 3's wording. Do NOT edit scripts/check-safety.sh
    (that is P1.M2.T1.S1's file); this task only documents its outcome in AGENTS.md.
```

## Validation Loop

### Level 1: Stale-phrase removal (deterministic grep)

```bash
# These two stale phrases MUST be gone from the docs after the edits:
grep -rniE "whether a selection was begun|checks whether a selection" README.md docs/CONFIGURATION.md AGENTS.md
# Expected: NO output (the stale region claim is removed).

grep -nE "outside \`scripts/\`\.\s" AGENTS.md   # the old WARN-scope phrasing in the table
# Expected: NO output (replaced by "outside `scripts/` and `plan/`").
```

### Level 2: Safety gates still pass (the edits must not introduce a FAIL/WARN)

```bash
scripts/check-safety.sh; echo "exit=$?"
# Expected: 0 FAIL / 0 WARN, exit 0. The .md edits contain no live shell snippet; the AGENTS.md
# wording refers to dangerous patterns BY NAME, not literally. (If it non-zero exits, the new
# wording likely contains a literal `killall tmux`/`exec tmux` — rephrase to the pattern NAME.)

scripts/preflight.sh
# Expected: clean (no >100 MiB files, no .audit*/calls.log residue, disk OK).
```

### Level 3: Accuracy spot-check (the new wording matches shipped behavior)

```bash
# Region empty confirm now refuses (post Issue 1) — the docs claim it does:
printf '     \n' | ./zig-out/bin/tmux-2html render --cols 5 --rows 1 --selection 0,0,4,0
# Expected: "tmux-2html render: selection is empty", exit 1, no file. (Mirrors what region now does.)

# render --cols 0 now exits 1 (post Issue 2) — confirm the binary matches (docs intentionally don't mention it):
printf 'x\n' | ./zig-out/bin/tmux-2html render --cols 0; echo "exit=$?"
# Expected: "tmux-2html render: --cols and --rows must be >= 1", exit 1. (No doc edit needed; just sanity.)

# Manual read-back: open docs/CONFIGURATION.md "Confirm and cancel" + "Empty selection", and AGENTS.md §3
# row, and confirm they describe the behaviors above (refuse empty; WARN skips plan/).
```

### Level 4: No-structural-change audit

```bash
# Confirm NO new section was added (diff should show ONLY in-place prose edits, no new headings):
git diff --stat README.md docs/CONFIGURATION.md AGENTS.md
git diff README.md docs/CONFIGURATION.md AGENTS.md | grep -E '^\+\s*##'   # new headings added?
# Expected: README.md unchanged (or trivial); docs/CONFIGURATION.md + AGENTS.md show only the
# targeted line edits; the second grep returns NOTHING (no new "## " headings / CHANGELOG / etc.).
```

## Final Validation Checklist

### Technical Validation
- [ ] Level 1 grep: stale phrases ("whether a selection was begun"; old WARN-scope wording) are gone.
- [ ] `scripts/check-safety.sh` exits 0 (edits introduced no flagged snippet).
- [ ] `scripts/preflight.sh` clean.
- [ ] `git diff` shows ONLY targeted prose edits in docs/CONFIGURATION.md + AGENTS.md; README.md unchanged (or verify-only).

### Feature Validation
- [ ] docs/CONFIGURATION.md "Confirm and cancel" + "Empty selection" state region checks the rendered body and agrees with render; empty confirm writes no file AND no `.last-output`.
- [ ] AGENTS.md §3 check-safety row: WARN skips `scripts/` AND `plan/`; FAIL scans repo-wide via `should_skip()` prose heuristic.
- [ ] README.md reviewed; no stale reference (region blurb, `--cols N` mention are accurate high-level summaries).
- [ ] No pre-fix behavior described anywhere in the three docs.

### Code Quality / Discipline Validation
- [ ] No new Changelog / Known-Issues / section added (no structural change — contract-compliant).
- [ ] No new `--cols`/`--rows` constraint prose added (Issue 2 has no stale doc to fix).
- [ ] Did NOT edit src/, scripts/, tests/, .github/, or build files (Mode A / P1.M2.T1.S1 own those).
- [ ] AGENTS.md wording keeps dangerous patterns referenced by NAME (no literal `killall tmux`/`exec tmux`).
- [ ] Did not touch the factual historical `plan/002_*` reference in AGENTS.md §0.

### Documentation & Deployment
- [ ] New wording is faithful to the exact shipped behavior (stderr strings, exit codes, sidecar absence).
- [ ] No internal markdown link/anchor broken (edits are in-paragraph/in-cell; no heading renames).

---

## Anti-Patterns to Avoid

- ❌ Don't add a CHANGELOG / "Fixed in v1.x" / Known-Issues(bugs) section — the contract says no structural change.
- ❌ Don't add `--cols`/`--rows ≥ 1` constraint docs — no stale claim existed; that's a structural change.
- ❌ Don't over-edit README.md or the region-overlay intro summary — they're accurate; only the detailed reference (CONFIGURATION.md) had stale claims.
- ❌ Don't write literal dangerous commands (`killall tmux`, `exec tmux`) into AGENTS.md — check-safety.sh would flag this very file. Reference patterns by name.
- ❌ Don't edit scripts/check-safety.sh, src/, or tests/ — that's Mode A / P1.M1.* / P1.M2.T1.S1. This task is docs-only.
- ❌ Don't claim region and render "differ" — the whole point of the Issue 1 fix is that they now AGREE (both check the rendered body).
- ❌ Don't touch AGENTS.md §0's `plan/002_*` reference — it's a factual historical pointer, not a scope claim.

---

## Confidence Score: 9/10

This is a small, deterministic documentation sweep. Every stale reference is pinned to a
file:line with exact before→after text (verified by grep), the "reviewed, not stale" set is
explicit (prevents over-editing), and the post-fix facts are sourced from the fix PRPs/architecture
(Issue 1) and the parallel P1.M2.T1.S1 research (Issue 4). The 1/10 residual is ordinary
proofreading risk (markdown rendering of the edited table cell). No code, no builds — the gates are
grep + check-safety + preflight + a git-diff structural audit.