# PRP — P1.M1.T2.S1: Update the three stale region/runtime references in README.md to the pane-anchored overlay

## Goal

**Feature Goal**: Sweep README.md's overview/feature-blurb and version-requirement text so it
matches the shipped **pane-anchored region overlay** (PRD §7.0 / §9.3) and the **tmux ≥ 3.3**
runtime floor (PRD §12), instead of the stale "full-screen overlay" / "tmux >= 3.2" wording left
over from the old fullscreen popup. This is the **Mode B changeset-level documentation task** —
it depends on the binding change in P1.M1.T1.S1 and runs last so the overview matches the whole
pane-anchored-overlay changeset.

**Deliverable**: Three targeted prose edits to **`README.md`** only (no other files, no code):
1. **Region bullet** (lines 26–27): "full-screen overlay" → "pane-anchored overlay (sized to the current pane)".
2. **Requirements** (lines 31–32): bump `**tmux >= 3.2**` → `**tmux >= 3.3**` with the `-B` /
   pane-anchored `-x`/`-y` rationale (and the palette-sync-only-needs-3.2 nuance).
3. **"## The region overlay" opener** (line 99): "a full-screen, copy-mode-style overlay" →
   "a pane-anchored, copy-mode-style overlay (sized to the current pane)".

**Success Definition**: README.md's Region feature bullet, the Requirements tmux-version floor
(3.3), and the region-overlay section opener all describe the pane-anchored overlay and are
consistent with the shipped `C-o` binding; `grep` confirms no stale "full-screen" / "3.2" region
or runtime wording remains; only `README.md` is touched.

## User Persona

**Target User**: A new user reading the README to learn the region overlay and the runtime
requirements, then installing/pressing `prefix C-o`.

**Use Case**: Read "tmux >= 3.3" + "pane-anchored overlay" in the README, then open the overlay
and see it sized exactly to the pane (1:1), and find the docs consistent (not claiming a
fullscreen view or a 3.2 floor that the shipped `-B`/`-x P`/`-y P` flags actually exceed).

**Pain Points Addressed**: Today the README says the overlay is "full-screen" (it is pane-sized)
and requires "tmux >= 3.2" (the region flags `-B` + pane-anchored `-x`/`-y` actually need 3.3).
A user on tmux 3.2 would install, hit the region key, and get a flag/feature failure the README
never warned about. This fix aligns the overview with the shipped behavior + real version floor.

## Why

- **Consistency with the just-shipped binding**: P1.M1.T1.S1 swaps the `C-o` binding to
  `display-popup -B -E -w '#{pane_width}' -h '#{pane_height}' -x P -y P -t '#{pane_id}'`. A
  README that still says "full-screen overlay" and "tmux >= 3.2" now contradicts the shipped
  code. The overview must match.
- **Correct version floor (PRD §12 / §7.0)**: `display-popup` itself is 3.2, but the region
  overlay's `-B` (borderless) + `-x P`/`-y P` (pane-anchored position tokens) are **3.3**
  features — `-B` alone forces 3.3 (external_tmux_popup.md claim #5, HIGH). The README's 3.2
  floor understates the real requirement.
- **Accurate capability description (PRD §1.1 / §7.0)**: the overlay is sized and positioned to
  exactly match the source pane (1:1 render fidelity); the user controls the rendered width by
  sizing the pane first. "Full-screen" misrepresents this.
- **Minimal, low-risk, boundary-safe**: three prose edits in one overview file. No code, no
  tests, no behavior change. The parallel Mode A task (T1.S1) owns `tmux-2html.tmux`,
  `tests/plugin_options.sh`, and `docs/CONFIGURATION.md`; this task owns **README.md only** →
  zero file overlap, clean parallel merge.

## What

Three localized prose edits in `README.md`. No new sections, no capability blurbs beyond what
the shipped behavior already does — this is a wording + version-bump fix (Mode B).

1. **Region bullet**: "full-screen overlay" → "pane-anchored overlay (sized to the current pane)".
2. **Requirements**: `**tmux >= 3.2**` → `**tmux >= 3.3**`; rationale = region overlay uses `-B`
   borderless + pane-anchored `-x`/`-y` (tmux 3.3); keep the nuance that the palette auto-sync
   popup only needs `display-popup` (3.2) but the floor follows the region overlay's flags.
3. **Region-overlay opener**: "full-screen, copy-mode-style overlay" → "pane-anchored,
   copy-mode-style overlay (sized to the current pane)".

### Success Criteria

- [ ] README.md Region bullet (lines ~26–27) says "pane-anchored", not "full-screen".
- [ ] README.md Requirements (lines ~31–32) says `**tmux >= 3.3**` with the `-B`/`-x`/`-y`
      rationale and the palette-sync-3.2 nuance; no "3.2" remains anywhere in README.md.
- [ ] README.md region-overlay opener (line ~99) says "pane-anchored", not "full-screen".
- [ ] `grep -n -iE 'full-screen|full screen' README.md` → no match.
- [ ] `grep -n '3\.2' README.md` → no match.
- [ ] `git diff --stat` → **only `README.md`** changed (no `docs/CONFIGURATION.md`, no
      `tmux-2html.tmux`, no `.zig`).
- [ ] The `@plugin 'tmux-2html/tmux-2html'` line (line 51; the `scripts/download.sh:28` sync
      invariant) is untouched.

## All Needed Context

### Context Completeness Check

_Pass: "If someone knew nothing about this codebase, would they have everything needed to
implement this successfully?"_ — Yes. All three edits are given as exact BEFORE/AFTER text read
from the live README (line numbers verified). A full grep scan confirms there are no other stale
spots. The 3.3 rationale is documented (HIGH confidence, from external_tmux_popup.md claim #5).
The boundary with the parallel Mode A task is explicit (README.md only; CONFIGURATION.md
off-limits). Validation is deterministic grep + scope guards. This is a paste-three-edits task.

### Documentation & References

```yaml
# MUST EDIT — the only file this task touches
- file: README.md
  section: "Capture modes → Region bullet (lines 26-27); Requirements tmux floor (lines 31-32); '## The region overlay' opener (line 99)"
  why: "THE file. Three prose edits; nothing else in README changes."
  pattern: "Overview prose; the detailed region/keybinding reference lives in docs/CONFIGURATION.md (do NOT duplicate)."
  gotcha: "Do NOT touch the Installation section / @plugin line (line 51) — scripts/download.sh:28 depends on it. Do NOT touch line 100-101 (the v/Ctrl-v clause is already correct from plan/003)."

# MUST READ FIRST — authoritative: the exact three README references + the 3.3 rationale
- file: plan/004_92f7aeb62a3a/architecture/system_context.md
  section: "§2.4 (the three README references) + §1 (tmux floor 3.2 → 3.3 table)"
  why: "Names the exact three spots and the rationale for each. §3 lists files that MUST NOT change (region.zig/capture.zig/tui/*/palette popup)."
  critical: "The version floor is bound to the REGION overlay's flags (3.3), even though the palette auto-sync popup (50%, no -B/-x P/-y P) only needs display-popup (3.2)."

# MUST READ — the 3.3 version-floor facts + confidence
- file: plan/004_92f7aeb62a3a/architecture/external_tmux_popup.md
  section: "claim #5 (Version floor) + claim #1 (-B = 3.3) + claim #2 (-x P/-y P = 3.3)"
  why: "HIGH-confidence: display-popup=3.2; -B borderless + -x P/-y P pane-anchored = 3.3; -B alone forces 3.3. So tmux >= 3.3 is correct, not over-constrained."

# NORMATIVE — what the corrected text must match
- file: PRD.md
  section: "§1.1 Goals (region = 'rendered at the pane's own size'; 'user controls the rendered width by sizing the pane first'); §7.0 (pane-anchored popup host + verified invocation); §9.3 (C-o binding); §12 (tmux >= 3.3 floor)"
  why: "§1.1/§7.0 define the pane-anchored behavior the README must describe; §12 pins the tmux floor to 3.3."

# INPUT CONTRACT — the binding change (produced by the parallel task; treat as contract)
- file: plan/004_92f7aeb62a3a/P1M1T1S1/PRP.md
  why: "T1.S1 swaps the C-o binding to the pane-anchored popup and updates docs/CONFIGURATION.md (Mode A). This README sweep makes the overview agree. T1.S1 explicitly defers README.md to this task; do NOT re-edit its files."

# OFF-LIMITS (owned by T1.S1 — do NOT edit here)
- file: docs/CONFIGURATION.md
  why: "Already updated in P1.M1.T1.S1 (Mode A): region-key row + region-overlay section. The contract: 'The per-feature docs/CONFIGURATION.md updates were already handled inline in P1.M1.T1.S1 (Mode A).'"

# Companion evaluation note
- file: plan/004_92f7aeb62a3a/P1M1T2S1/research/findings.md
  why: "Full grep scan (confirms exactly 3 stale spots), the 3.3 rationale, the boundary proof, the v/Ctrl-v-already-correct note, and the deterministic grep gates."
```

### Current Codebase tree (relevant slice)

```bash
tmux-2html/
├── README.md                 # <— EDIT: Region bullet (26-27) + Requirements (31-32) + region opener (99)
├── docs/CONFIGURATION.md     # OFF-LIMITS (P1.M1.T1.S1 / Mode A)
├── tmux-2html.tmux           # OFF-LIMITS (P1.M1.T1.S1)
├── tests/plugin_options.sh   # OFF-LIMITS (P1.M1.T1.S1)
└── PRD.md                    # normative (§1.1 / §7.0 / §9.3 / §12)
```

### Desired Codebase tree with files to be changed

```bash
tmux-2html/
└── README.md                 # MODIFIED — 3 prose edits (region bullet + tmux floor + region opener)
# NO other files. NO code. NO docs/CONFIGURATION.md. NO new files/sections.
```

### Known Gotchas of our codebase & Library Quirks

```markdown
# GOTCHA 1 — the version floor is bound to the REGION overlay's flags, NOT display-popup itself.
#   display-popup = 3.2; -B (borderless) + -x P/-y P (pane-anchored) = 3.3; -B ALONE forces 3.3.
#   So README must say "tmux >= 3.3". Keep the nuance: the palette auto-sync popup (50%, no
#   -B/-x P/-y P) only needs display-popup (3.2), but the floor follows the region overlay.

# GOTCHA 2 — the region overlay is PANE-SIZED, not fullscreen. "Full-screen" is the stale word
#   in TWO spots (line 26 bullet, line 99 opener); both become "pane-anchored ... (sized to the
#   current pane)". The user controls the rendered width by sizing the pane first (PRD §1.1/§7.0).

# GOTCHA 3 — line 100-101 (the v / Ctrl-v selection clause) is ALREADY correct (updated in
#   plan/003). Do NOT touch it. This task edits only line 99's "full-screen" → "pane-anchored".

# GOTCHA 4 — keep the version-floor NUANCE in the Requirements bullet. Don't just say "3.3";
#   explain WHY (region flags) and note the palette popup only needs 3.2. The contract requires
#   this nuance so a reader understands the floor is driven by the region overlay specifically.

# GOTCHA 5 — do NOT touch the Installation section / the @plugin line (line 51).
#   scripts/download.sh:28 documents that download.sh's release URL must stay in sync with
#   README.md's @plugin line. This task edits the Region bullet, Requirements, and region-opener
#   only — all far from line 51.

# GOTCHA 6 — there is NO markdown linter / README validation in CI (ci.yml runs only Zig tests),
#   and this task involves NO tmux server (PRD §0/§0.1 trivially satisfied). So the validation
#   gate is deterministic grep + scope guard + manual eyeball, NOT a build step.
```

## Implementation Blueprint

### Data models and structure

Not applicable — prose only. No data models, no code, no config.

### The exact deliverable — verbatim edits (README.md, three spots)

#### Spot 1 — Region bullet (lines 26–27)

```markdown
<!-- ---- BEFORE (exact, lines 26-27) ---- -->
- **Region.** Opens a copy-mode-style full-screen overlay over the scrollback
  and lets you select a line range or a block to render.
```
```markdown
<!-- ---- AFTER ---- -->
- **Region.** Opens a copy-mode-style, pane-anchored overlay over the scrollback
  (sized to the current pane — size the pane first to control the rendered width)
  and lets you select a line range or a block to render.
```

#### Spot 2 — Requirements, tmux version floor (lines 31–32)

```markdown
<!-- ---- BEFORE (exact, lines 31-32) ---- -->
- **tmux >= 3.2.** The region overlay and the one-time palette sync use
  `display-popup`, which tmux 3.2 introduced.
```
```markdown
<!-- ---- AFTER ---- -->
- **tmux >= 3.3.** The region overlay is a borderless, pane-anchored
  `display-popup` (`-B` plus pane-positioned `-x`/`-y`), and those flags need
  tmux 3.3. (`display-popup` itself is 3.2, and the one-time palette sync popup
  uses only that — but the version floor follows the region overlay's flags.)
```

#### Spot 3 — "## The region overlay" opener (the paragraph at lines 99–104)

Replace the whole paragraph so the line wrap reflows cleanly. The ONLY semantic change is the
first sentence's "full-screen … overlay over the pane scrollback" → "pane-anchored … overlay
(sized to the current pane) over the scrollback"; the v/Ctrl-v/Enter/q/status-line/link tail
(lines 100-104) is preserved verbatim (it is already correct).

```markdown
<!-- ---- BEFORE (exact, lines 99-104) ---- -->
Press `prefix C-o` to open a full-screen, copy-mode-style overlay over the pane
scrollback. Move the cursor and select a region; press `v` to begin or re-anchor
a linewise selection and `Ctrl-v` to toggle block mode; press `Enter` to render
the selection to an HTML file, or `q` to cancel. The in-app status line lists
every key. See [docs/CONFIGURATION.md](docs/CONFIGURATION.md) for the full key
list and behavior.
```
```markdown
<!-- ---- AFTER ---- -->
Press `prefix C-o` to open a pane-anchored, copy-mode-style overlay (sized to
the current pane) over the scrollback. Move the cursor and select a region;
press `v` to begin or re-anchor a linewise selection and `Ctrl-v` to toggle
block mode; press `Enter` to render the selection to an HTML file, or `q` to
cancel. The in-app status line lists every key. See
[docs/CONFIGURATION.md](docs/CONFIGURATION.md) for the full key list and
behavior.
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: EDIT README.md — the three stale references (Spots 1, 2, 3 above)
  - Spot 1 (lines 26-27): Region bullet "full-screen overlay" -> "pane-anchored overlay (sized to the current pane)".
  - Spot 2 (lines 31-32): bump "tmux >= 3.2" -> "tmux >= 3.3" with the -B/-x/-y rationale + palette-3.2 nuance.
  - Spot 3 (lines 99-104): opener "full-screen, copy-mode-style overlay" -> "pane-anchored, copy-mode-style overlay (sized to the current pane)"; preserve the v/Ctrl-v/Enter/q/status-line/link tail.
  - DO NOT: touch line 51 (@plugin / download.sh sync invariant), line 100-101 (v/Ctrl-v already correct),
            the Installation section, the subcommand/options tables, or any other file.

Task 2: VALIDATE (see Validation Loop — deterministic grep + scope guard; no build step, no tmux)
  - RUN the grep gates; confirm only README.md changed; confirm the @plugin line is intact.

Task 3: LOG the decision in task completion notes
  - State: "README.md CHANGED — 3 spots: Region bullet (full-screen -> pane-anchored), Requirements
    (tmux >= 3.2 -> >= 3.3 with -B/-x/-y rationale + palette-3.2 nuance), region-overlay opener
    (full-screen -> pane-anchored). Line 100-101 (v/Ctrl-v) already correct (plan/003), untouched.
    docs/CONFIGURATION.md untouched (Mode A, P1.M1.T1.S1)."
```

### Implementation Patterns & Key Details

```markdown
PATTERN: the three edits mirror PRD §1.1/§7.0 (pane-anchored, pane-sized, user-sizes-pane-first)
and §12 (tmux >= 3.3). Use "pane-anchored" consistently so grep is clean:
  - bullet (Spot 1):  "pane-anchored overlay over the scrollback (sized to the current pane …)"
  - opener (Spot 3):  "pane-anchored, copy-mode-style overlay (sized to the current pane)"
  => grep 'pane-anchored' README.md  → 2 matches.

CRITICAL: the Requirements bullet (Spot 2) must keep the NUANCE — display-popup is 3.2 and the
palette auto-sync popup only needs that, but the floor follows the REGION overlay's flags (3.3).
Don't strip the nuance to a bare "tmux >= 3.3"; the contract requires it.
```

### Integration Points

```yaml
README.md (this task):
  - Region bullet + Requirements tmux floor + region-overlay opener all describe the pane-anchored
    overlay and the 3.3 floor; consistent with the shipped C-o binding.

docs/CONFIGURATION.md (OFF-LIMITS — P1.M1.T1.S1 / Mode A):
  - region-key option row + region-overlay section already updated there. Do NOT re-edit.

CODE (OFF-LIMITS — P1.M1.T1.S1 + no Zig work):
  - tmux-2html.tmux (binding) + tests/plugin_options.sh (sed) edited by T1.S1.
  - src/region.zig getSize() auto-matches the pane-sized popup pty — NO Zig change in this plan.

CROSS-FILE INVARIANT (do NOT regress):
  - scripts/download.sh:28: README.md's @plugin line (line 51) must stay in sync with the release
    URL. This task does NOT touch line 51.

CONFIG / DATABASE / ROUTES:
  - none.
```

## Validation Loop

> No build/test step applies (pure prose; no markdown linter in CI; no tmux involved — PRD
> §0/§0.1 trivially satisfied). The gate is deterministic grep assertions + a scope guard +
> a manual eyeball of the rendered sections.

### Level 1: Content Assertions (Immediate Feedback)

```bash
cd /home/dustin/projects/tmux-2html

# (1) The STALE wording is GONE:
grep -n -iE 'full-screen|full screen' README.md     # Expected: NO output (no match).
grep -n '3\.2' README.md                            # Expected: NO output (both 3.2 mentions -> 3.3).

# (2) The CORRECT wording is PRESENT:
grep -n 'tmux >= 3\.3' README.md                    # Expected: 1 match (~line 31).
grep -n 'pane-anchored' README.md                   # Expected: 2 matches (bullet ~26 + opener ~99).
grep -n '\-B` plus pane-positioned' README.md       # Expected: 1 match (the rationale, ~line 32).
```

### Level 2: Scope Guard (only README.md changed)

```bash
git diff --stat
# Expected: ONLY README.md. If docs/CONFIGURATION.md, tmux-2html.tmux, tests/, or any src/*.zig
# appears, STOP — you crossed the task boundary (those are P1.M1.T1.S1 / Mode A / code; out of
# scope). Revert the stray edit.

# Cross-file invariant untouched (scripts/download.sh:28 sync):
grep -n "@plugin 'tmux-2html/tmux-2html'" README.md # Expected: line 51, unchanged.
```

### Level 3: Consistency Eyeball (README ↔ shipped binding ↔ PRD)

```bash
# Eyeball the three edited sections render as clean prose (no broken list/code-fence):
sed -n '19,40p' README.md     # Capture modes (Region bullet) + Requirements (tmux floor)
sed -n '97,105p' README.md    # The region overlay opener
# Confirm consistency:
#   README bullet :  "pane-anchored overlay … sized to the current pane"
#   README opener :  "pane-anchored, copy-mode-style overlay (sized to the current pane)"
#   README floor  :  "tmux >= 3.3" (region overlay's -B + pane-anchored -x/-y)
#   Shipped C-o   :  display-popup -B -E -w '#{pane_width}' -h '#{pane_height}' -x P -y P -t '#{pane_id}'
#   PRD §7.0/§12  :  pane-anchored host; tmux >= 3.3
# All four agree the overlay is pane-sized (not fullscreen) and the floor is 3.3. Consistent.

# Final stale-wording sweep (catches anything missed):
grep -niE 'full-screen|full screen|tmux >= 3\.[012]' README.md   # Expected: NO output.
```

### Level 4: Render Check (optional)

```bash
# If a markdown renderer is handy, eyeball the Region bullet, Requirements, and region-overlay
# section each render cleanly (no broken wrapping/list). Markdown is whitespace-tolerant, so the
# reflow is cosmetic — this is a confidence check, not a gate.
```

## Final Validation Checklist

### Technical Validation

- [ ] `grep -n -iE 'full-screen|full screen' README.md` → no match (Level 1).
- [ ] `grep -n '3\.2' README.md` → no match (Level 1).
- [ ] `grep -n 'tmux >= 3\.3' README.md` → 1 match (Level 1).
- [ ] `grep -n 'pane-anchored' README.md` → 2 matches (Level 1).
- [ ] `git diff --stat` → only `README.md` (Level 2 scope guard).
- [ ] `@plugin` line 51 unchanged (Level 2 invariant).

### Feature Validation

- [ ] Region bullet describes a pane-anchored, pane-sized overlay (not fullscreen).
- [ ] Requirements states `tmux >= 3.3` with the `-B`/`-x`/`-y` rationale + palette-3.2 nuance.
- [ ] Region-overlay opener says "pane-anchored … (sized to the current pane)".
- [ ] README is consistent with the shipped `C-o` binding and PRD §7.0/§12.
- [ ] Line 100-101 (v/Ctrl-v) and the @plugin line untouched.

### Code Quality Validation

- [ ] Only the three intended prose spots changed; no new sections/capability blurbs.
- [ ] No detail duplicated from docs/CONFIGURATION.md into the README overview.
- [ ] `docs/CONFIGURATION.md`, `tmux-2html.tmux`, `tests/`, and all `.zig` NOT edited.
- [ ] "pane-anchored" used consistently (2 grep matches); version-floor nuance retained.

### Documentation & Deployment

- [ ] README region/runtime text matches the shipped pane-anchored overlay + 3.3 floor.
- [ ] No new env vars / config / CLI surface.

---

## Anti-Patterns to Avoid

- ❌ Don't declare "no change needed" — three spots are provably stale (grep confirms exactly
  line 26, lines 31-32, line 99). Fix all three.
- ❌ Don't keep "tmux >= 3.2" — the region overlay's `-B` + pane-anchored `-x`/`-y` need 3.3
  (`-B` alone forces 3.3). The floor must be `>= 3.3` (PRD §12, external_tmux_popup claim #5).
- ❌ Don't strip the version-floor nuance to a bare "tmux >= 3.3" — keep the rationale (region
  flags) and the note that the palette auto-sync popup only needs `display-popup` (3.2). The
  contract requires this nuance.
- ❌ Don't describe the overlay as "full-screen" — it is pane-sized and pane-anchored (PRD §1.1/§7.0).
  "full-screen" must be gone from both line 26 and line 99 (grep must be clean).
- ❌ Don't touch `docs/CONFIGURATION.md` — it is owned by the parallel Mode A task (P1.M1.T1.S1);
  the contract: "do NOT re-edit it here."
- ❌ Don't touch `tmux-2html.tmux`, `tests/plugin_options.sh`, or any `.zig` — those are T1.S1 /
  code; this task is README.md only.
- ❌ Don't touch line 100-101 (the `v`/`Ctrl-v` selection clause) — it is already correct (updated
  in plan/003). Only line 99's "full-screen" changes in that paragraph.
- ❌ Don't touch the Installation section / `@plugin` line (line 51) — `scripts/download.sh:28`
  depends on it being in sync with the release URL.
- ❌ Don't invent a build/test gate or invoke tmux — there is no markdown linter, no README check
  in CI, and this is a prose edit (PRD §0/§0.1 trivially satisfied). The gate is grep + scope
  guard + eyeball.

---

**Confidence Score: 10/10** for one-pass implementation success.

This is three targeted prose edits in one overview file. Each BEFORE/AFTER is given verbatim
(read from the live README, line numbers verified), and a full grep scan confirms there are
exactly three stale spots — no hidden ones. The corrected text mirrors PRD §1.1/§7.0
(pane-anchored, pane-sized, user-sizes-pane-first) and §12 (tmux ≥ 3.3), and the 3.3 rationale
is HIGH-confidence from external_tmux_popup.md claim #5 (`-B` borderless + `-x P`/`-y P`
pane-anchored are both 3.3; `-B` alone forces 3.3; the palette 50% popup only needs 3.2 but the
floor follows the region overlay). The boundary is clean (README.md only; `docs/CONFIGURATION.md`,
`tmux-2html.tmux`, `tests/`, and all `.zig` are off-limits, owned by T1.S1 / Mode A / code), and
the `@plugin`/download.sh cross-file invariant is explicitly preserved. Line 100-101 (the
`v`/`Ctrl-v` clause) is already correct from plan/003 and is left untouched. Validation is
deterministic grep + a scope guard — no build step needed for prose. The implementer pastes three
edits and runs the grep gates.