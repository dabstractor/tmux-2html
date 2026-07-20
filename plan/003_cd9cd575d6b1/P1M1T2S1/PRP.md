# PRP — P1.M1.T2.S1: Verify README.md vs the new status-line hint; update if stale

## Goal

**Feature Goal**: Sync the README.md region-overlay description to the shipped §7.4
keybindings and the new `renderStatus` status-line hint (`v=sel C-v=block o=swap`) from the
parallel task P1.M1.T1.S1. One stale clause misrepresents the selection keys; correct it. This
is a **Mode B documentation verification + one-line display fix** — no new sections, no
capability blurbs, no code.

**Deliverable**: A single edit to **`README.md`** (the "## The region overlay" paragraph,
lines 99–104): replace the stale clause *"press `v` to toggle between linewise and block
selection"* with the accurate *"press `v` to begin or re-anchor a linewise selection and
`Ctrl-v` to toggle block mode"*. Nothing else changes.

**Success Definition**: README.md's region-overlay paragraph matches §7.4 (`v` begin/re-anchor
linewise; `Ctrl-v` toggle block) and the new on-screen hint (`v=sel`/`C-v=block`); the stale
"toggle between linewise and block" phrasing is gone (grep-verified); only `README.md` is
touched (scope-verified); the decision (changed) is logged.

## User Persona

**Target User**: A new tmux-2html user reading the README to learn the region overlay, then
pressing keys in the overlay and seeing the status-line hint.

**Use Case**: Read "press `v` …" in the README, then see `v=sel C-v=block` on the status line,
and find them consistent (not contradictory).

**Pain Points Addressed**: Today the README says `v` toggles linewise↔block, but the shipped
behavior (and the new on-screen hint) is `v` = begin/re-anchor linewise, `Ctrl-v` = toggle
block. A user who trusts the README would press `v` expecting block mode and get confused.
This fix removes the contradiction.

## Why

- **Correctness / no contradiction with the just-shipped hint**: P1.M1.T1.S1 makes the status
  line advertise `v=sel C-v=block o=swap`. A README that still says "`v` toggles block" now
  directly contradicts the in-app hint a user sees seconds later. The two must agree.
- **§7.4 parity**: PRD §7.4 is explicit — `v` begins/re-anchors **linewise**; `Ctrl-v` toggles
  **block**. The README overview should not misstate the headline §7.4 mechanic.
- **Minimal, low-risk**: a one-clause prose swap in an overview paragraph. No code, no tests,
  no behavior change, no struct/coordinate/render change.
- **Boundary-safe**: the parallel Mode A task (T1.S1) owns `view.zig`, `select.zig`, and
  `docs/CONFIGURATION.md`; this task owns **README.md only**. Zero file overlap.

## What

One clause swap inside the existing "## The region overlay" paragraph. The rest of the
paragraph (Enter to render, q to cancel, "The in-app status line lists every key", and the
CONFIGURATION.md link) stays byte-for-byte.

**Decision logged**: README.md is **CHANGED** (one line) — not "verified consistent, no change".
The evaluation found exactly one stale clause (line 100). All other README content (line 27
"line range or a block"; line 102 "lists every key"; the key-bindings table; the options table
incl. `@tmux-2html-title`/`@tmux-2html-lang`; the subcommand table) is consistent with the
shipped behavior and needs no edit.

### Success Criteria

- [ ] README.md line ~100 no longer says `v` "toggle[s] between linewise and block selection".
- [ ] README.md line ~100 says `v` "begin[s] or re-anchor[s] a linewise selection" and
      `Ctrl-v` "toggle[s] block mode" (matches §7.4 + the new `v=sel C-v=block` hint).
- [ ] `grep -n 'toggle between linewise and block' README.md` → no match.
- [ ] `git diff --stat` → **only `README.md`** changed (no `docs/CONFIGURATION.md`, no `.zig`).
- [ ] The `@plugin 'tmux-2html/tmux-2html'` line (line 51; the download.sh sync invariant) is
      untouched.

## All Needed Context

### Context Completeness Check

_Pass: "If someone knew nothing about this codebase, would they have everything needed to
implement this successfully?"_ — Yes. The exact stale paragraph and the exact corrected
paragraph are given verbatim (read from the live README). The evaluation of every nearby line
(line 27, line 102, the tables) is documented with the keep/fix decision and rationale. The
boundary with the parallel task is explicit. Validation is deterministic grep + scope guards.
This is a paste-one-paragraph task.

### Documentation & References

```yaml
# MUST EDIT — the only file this task touches
- file: README.md
  section: "## The region overlay (lines 99-104); the stale clause wraps lines 100-101"
  why: "THE file. Replace the one stale clause; keep the rest of the paragraph."
  pattern: "Overview prose; the detailed §7.4 keybinding table lives in docs/CONFIGURATION.md (do NOT duplicate it here)."
  gotcha: "Do NOT touch the Installation section / @plugin line (line 51) — scripts/download.sh:28 depends on it."

# NORMATIVE — what the corrected text must match
- file: PRD.md
  section: "§7.4 (v = begin/re-anchor linewise; Ctrl-v = toggle block; o = swap ends) + §7.1 (status line: v=sel C-v=block o=swap Enter=render q=quit)"
  why: "§7.4 defines the real key behavior; §7.1 defines the on-screen hint the README must not contradict."

# INPUT CONTRACT — the new status-line hint (produced by the parallel task; treat as contract)
- file: plan/003_cd9cd575d6b1/P1M1T1S1/PRP.md
  why: "renderStatus now emits `v=sel C-v=block o=swap Enter=render q=quit` (always shown). The README fix makes the prose agree with this hint. T1.S1 also edits docs/CONFIGURATION.md — this task must NOT."

# OFF-LIMITS (owned by T1.S1 — do NOT edit here)
- file: docs/CONFIGURATION.md
  why: "Already updated in P1.M1.T1.S1 (Mode A). The contract: 'do NOT re-edit it here.' The §7.4 keybinding table + status-line format already live there."

# Companion evaluation note
- file: plan/003_cd9cd575d6b1/P1M1T2S1/research/findings.md
  why: "Records the full README scan, the keep/fix decision per line, the boundary proof, and the deterministic grep gates."
```

### Current Codebase tree (relevant slice)

```bash
tmux-2html/
├── README.md                 # <— EDIT: the region-overlay paragraph (lines 99-104)
├── docs/CONFIGURATION.md     # OFF-LIMITS (P1.M1.T1.S1 / Mode A owns it)
├── src/tui/view.zig          # OFF-LIMITS (P1.M1.T1.S1)
└── PRD.md                    # normative (§7.1 / §7.4)
```

### Desired Codebase tree with files to be changed

```bash
tmux-2html/
└── README.md                 # MODIFIED — one clause in the region-overlay paragraph
# NO other files. NO code. NO docs/CONFIGURATION.md. NO new files/sections.
```

### Known Gotchas of our codebase & Library Quirks

```markdown
# GOTCHA 1 — `v` does NOT toggle linewise/block. The stale clause says it does. Per §7.4:
#   v     = begin / re-anchor a selection in LINEWISE mode (re-pressing v moves the anchor).
#   Ctrl-v = TOGGLE block (rectangle) mode (this is the linewise<->block switch).
#   o     = swap cursor to the other end.
# The corrected clause must attribute block-toggle to Ctrl-v, not v.

# GOTCHA 2 — keep the paragraph's OTHER clauses intact. "press Enter to render … or q to
#   cancel", "The in-app status line lists every key", and the CONFIGURATION.md link all
#   stay. This is a ONE-CLAUSE swap + natural reflow, not a rewrite.

# GOTCHA 3 — do NOT pull §7.4 detail (re-anchor mechanics, o/Esc/V/R aliases) into the README.
#   That detail lives in docs/CONFIGURATION.md by design; the README is an overview. The
#   contract: "Do NOT add new sections, feature lists, or capability blurbs."

# GOTCHA 4 — line 102 ("The in-app status line lists every key") stays. The contract says it
#   is generic and needs no change; it is in fact MORE accurate now (the new hint shows 5 keys
#   vs the old <S-sel> + 2). Touching it is scope creep.

# GOTCHA 5 — do NOT touch the Installation section / the @plugin line (line 51).
#   scripts/download.sh:28 documents that download.sh's release URL must stay in sync with
#   README.md's @plugin line. This task edits the region-overlay paragraph only.

# GOTCHA 6 — there is NO markdown linter / README validation in CI (ci.yml runs only Zig
#   tests). So the validation gate is deterministic grep + manual eyeball, not a build step.
```

## Implementation Blueprint

### Data models and structure

Not applicable — prose only. No data models, no code.

### The exact deliverable — verbatim edit (README.md, "## The region overlay")

Replace the entire paragraph (lines 99–104) so the line wrap reflows cleanly:

```markdown
<!-- ---- BEFORE (exact, lines 99-104) ---- -->
Press `prefix C-o` to open a full-screen, copy-mode-style overlay over the pane
scrollback. Move the cursor and select a region; press `v` to toggle between
linewise and block selection; press `Enter` to render the selection to an HTML
file, or `q` to cancel. The in-app status line lists every key. See
[docs/CONFIGURATION.md](docs/CONFIGURATION.md) for the full key list and
behavior.
```
```markdown
<!-- ---- AFTER ---- -->
Press `prefix C-o` to open a full-screen, copy-mode-style overlay over the pane
scrollback. Move the cursor and select a region; press `v` to begin or re-anchor
a linewise selection and `Ctrl-v` to toggle block mode; press `Enter` to render
the selection to an HTML file, or `q` to cancel. The in-app status line lists
every key. See [docs/CONFIGURATION.md](docs/CONFIGURATION.md) for the full key
list and behavior.
```

The only semantic change is the clause `press \`v\` to toggle between linewise and block
selection` → `press \`v\` to begin or re-anchor a linewise selection and \`Ctrl-v\` to toggle
block mode`. Everything else (Enter/q, "lists every key", the link) is preserved; surrounding
line breaks are reflowed only to keep the paragraph readable.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: EDIT README.md — fix the stale selection clause (the only change)
  - REPLACE the region-overlay paragraph (lines 99-104) with the corrected paragraph above.
  - The semantic change: "v toggles linewise/block" -> "v begins/re-anchors linewise; Ctrl-v toggles block".
  - KEEP: Enter-to-render, q-to-cancel, "lists every key", the CONFIGURATION.md link.
  - DO NOT: add §7.4 detail (re-anchor/o/Esc/V/R aliases) — that lives in CONFIGURATION.md.
  - DO NOT: touch line 27 (accurate), line 102 (generic, keep), the Installation/@plugin line,
            the key-bindings table, the options table, or the subcommand table.

Task 2: LOG the decision in task completion notes
  - State: "README.md CHANGED — one clause (line ~100): 'v toggles linewise/block' -> 'v
    begin/re-anchor linewise; Ctrl-v toggle block'. All other README content verified
    consistent; no change. docs/CONFIGURATION.md untouched (owned by P1.M1.T1.S1)."

Task 3: VALIDATE (see Validation Loop — deterministic grep + scope guard; no build step)
```

### Implementation Patterns & Key Details

```markdown
PATTERN: the corrected clause mirrors both PRD §7.4 and the new on-screen hint, using the
same key names so README prose and the status line agree:
  - README:  press `v` to begin or re-anchor a linewise selection and `Ctrl-v` to toggle block mode
  - hint:    v=sel  C-v=block   (renderStatus, after P1.M1.T1.S1)
  - PRD §7.4: v = begin/re-anchor linewise; Ctrl-v = toggle block

CRITICAL: this is a one-clause display fix. Do not expand the README's scope — the detailed
keybinding table, the re-anchor mechanics, and the o/Esc/V/R aliases all stay in
docs/CONFIGURATION.md (which T1.S1 already synced).
```

### Integration Points

```yaml
README.md (this task):
  - region-overlay paragraph corrected; consistent with §7.4 + the new status-line hint.

docs/CONFIGURATION.md (OFF-LIMITS — P1.M1.T1.S1):
  - already holds the §7.1 status-line format + the §7.4 keybinding table. Do NOT re-edit.

CODE (OFF-LIMITS):
  - src/tui/view.zig (renderStatus) + src/tui/select.zig — edited by P1.M1.T1.S1. No code
    change in this task; the §7.4 keys already work — this only fixes the prose.

CROSS-FILE INVARIANT (do NOT regress):
  - scripts/download.sh:28: README.md's @plugin line (line 51) must stay in sync with
    download.sh's release URL. This task does NOT touch line 51.

CONFIG / DATABASE / ROUTES:
  - none.
```

## Validation Loop

> No build/test step applies (pure prose; no markdown linter in CI). The gate is deterministic
> grep assertions + a scope guard + a manual eyeball of the rendered paragraph.

### Level 1: Content Assertions (Immediate Feedback)

```bash
cd /home/dustin/projects/tmux-2html

# (1) The STALE phrasing is GONE:
grep -n 'toggle between linewise and block' README.md
# Expected: NO output (no match).

# (2) The CORRECT phrasing is PRESENT:
grep -n 'begin or re-anchor a linewise selection' README.md   # Expected: 1 match (~line 100)
grep -n 'Ctrl-v` to toggle block mode' README.md              # Expected: 1 match (~line 100)
```

### Level 2: Scope Guard (only README.md changed)

```bash
git diff --stat
# Expected: ONLY README.md. If docs/CONFIGURATION.md or any src/*.zig appears, STOP — you
# crossed the task boundary (CONFIGURATION.md is P1.M1.T1.S1; code is out of scope). Revert
# the stray edit.

# Cross-file invariant untouched (scripts/download.sh:28 sync):
grep -n "@plugin 'tmux-2html/tmux-2html'" README.md
# Expected: line 51, unchanged.
```

### Level 3: Consistency Eyeball (README ↔ hint ↔ §7.4)

```bash
# Render/eyeball the corrected paragraph and confirm the three sources agree:
sed -n '99,104p' README.md
# README clause:  "press `v` to begin or re-anchor a linewise selection and `Ctrl-v` to toggle block mode"
# Status-line:    v=sel  C-v=block   (src/tui/view.zig renderStatus, after T1.S1)
# PRD §7.4:       v = begin/re-anchor linewise; Ctrl-v = toggle block
# All three attribute block-toggle to Ctrl-v, NOT v. Consistent.

# Confirm no OTHER stale selection/status-line phrasing leaked in elsewhere:
grep -niE 'toggle|linewise|block|status line|<S-sel>' README.md
# Expected: line 27 ("line range or a block" — accurate, keep), line ~100 (the fix),
#           line ~102 ("lists every key" — generic, keep). No new/stale occurrences.
```

### Level 4: Render Check (optional)

```bash
# If a markdown renderer is handy, eyeball the region-overlay section renders as one clean
# paragraph (no broken list/code-fence). Markdown is whitespace-tolerant, so the reflow is
# cosmetic — this is just a confidence check, not a gate.
```

## Final Validation Checklist

### Technical Validation

- [ ] `grep -n 'toggle between linewise and block' README.md` → no match (Level 1).
- [ ] `grep -n 'begin or re-anchor a linewise selection' README.md` → 1 match (Level 1).
- [ ] `git diff --stat` → only `README.md` (Level 2 scope guard).
- [ ] `@plugin` line 51 unchanged (Level 2 invariant).

### Feature Validation

- [ ] README region-overlay clause attributes block-toggle to `Ctrl-v`, not `v`.
- [ ] README is now consistent with the new status-line hint (`v=sel C-v=block`) and §7.4.
- [ ] Line 27 ("line range or a block"), line 102 ("lists every key"), and all tables untouched.
- [ ] Decision logged: README.md CHANGED (one clause).

### Code Quality Validation

- [ ] Only the region-overlay paragraph changed; no new sections/blurbs/capability lists.
- [ ] No §7.4 detail (re-anchor/o/Esc/V/R aliases) duplicated into the README overview.
- [ ] `docs/CONFIGURATION.md` NOT edited (owned by P1.M1.T1.S1).
- [ ] No code (`*.zig`) edited.

### Documentation & Deployment

- [ ] README prose matches the shipped behavior + on-screen hint.
- [ ] No new env vars / config / CLI surface.

---

## Anti-Patterns to Avoid

- ❌ Don't declare "no change needed" — the evaluation found one stale clause (line 100). Fix it.
- ❌ Don't attribute block-toggle to `v` — that's the bug. §7.4 + the new hint both put block on
  `Ctrl-v`; `v` begins/re-anchors linewise.
- ❌ Don't expand the README into a §7.4 reference — the detailed keybinding table, re-anchor
  mechanics, and `o`/`Esc`/`V`/`R` aliases belong in `docs/CONFIGURATION.md` (already current
  via T1.S1). This is an overview one-clause fix, not a docs expansion.
- ❌ Don't touch `docs/CONFIGURATION.md` — it is owned by the parallel Mode A task
  (P1.M1.T1.S1); the contract says "do NOT re-edit it here."
- ❌ Don't touch any `*.zig`, the key-bindings table, the options table, line 27, or line 102 —
  all verified consistent; only the region-overlay clause (line ~100) changes.
- ❌ Don't edit the Installation section / `@plugin` line (line 51) — `scripts/download.sh:28`
  depends on it being in sync with the release URL.
- ❌ Don't invent a build/test gate — there is no markdown linter and no README validation in
  CI. The gate is grep + scope guard + eyeball. (Don't run `zig build` expecting it to validate
  prose — it won't, and it's out of scope.)

---

**Confidence Score: 10/10** for one-pass implementation success.

This is a single-clause prose swap in one overview paragraph. The stale text and the corrected
text are both given verbatim (read from the live README), the evaluation of every nearby line
(line 27 keep, line 102 keep, the tables keep) is documented with rationale, and the
corrected clause is verified consistent with PRD §7.4 and the new `v=sel C-v=block` status-line
hint from the parallel task. The boundary is clean (README.md only; `docs/CONFIGURATION.md`
and all `.zig` are off-limits, owned by T1.S1), and the `@plugin`/download.sh cross-file
invariant is explicitly preserved. Validation is deterministic grep + a scope guard — no build
step needed for prose. The implementer pastes one corrected paragraph and runs three grep
checks.