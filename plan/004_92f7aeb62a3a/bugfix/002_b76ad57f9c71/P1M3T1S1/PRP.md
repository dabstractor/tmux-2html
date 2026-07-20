# PRP — P1.M3.T1.S1: README region/mouse feature section + docs/CONFIGURATION region-keys reference

## Goal

**Feature Goal**: Sync the user-facing documentation so `README.md` and `docs/CONFIGURATION.md`
no longer describe the pre-fix region-TUI input surface. Round 2 shipped three changes — **mouse
is now functional (PRD §7.6)**, **`Ctrl-c` cancels with exit `1`** (was 130), and **`Ctrl-z` is
ignored** (was suspending/freezing the popup). The docs currently say mouse is "not yet
functional" and list it as a "Known limitation", and the README region blurb is keyboard-only.
No new option/env/flag was added — the docs must not invent any.

**Deliverable**: Four targeted prose edits — (1) README region blurb gains mouse + correct
cancel keys; (2) docs/CONFIGURATION.md "Mouse" section rewritten from "not yet functional" to
the click/drag/wheel behavior; (3) the "mouse is not yet functional" Known-limitations bullet
removed; (4) the Overview "two region-overlay deviations" line corrected to one. Plus a verify-
only pass on the cancel references (already accurate) and an optional one-sentence Ctrl-c/Ctrl-z
note in the cancel paragraph.

**Success Definition**: No doc says mouse is non-functional or "no effect in v1"; the README
region blurb describes click/drag/wheel alongside the keyboard and lists `q`/`Esc`/`Ctrl-c` as
cancel (exit `1`) with `Ctrl-z` ignored; the CONFIGURATION Mouse section describes the shipped
behavior; the docs read cleanly (well-formed markdown tables/lists); `check-safety.sh` and
`preflight.sh` stay clean.

## Why

- Docs must not advertise a feature as broken that now works. Mouse (§7.6) is a **supported**
  feature, not roadmap; the old "not yet functional" wording actively misleads users who see the
  cursor enter mouse-reporting mode and try to click.
- The signal-key fixes (Ctrl-c/Ctrl-z) are real user-observable behavior changes; the README
  blurb's cancel list (`or `q` to cancel`) omits `Ctrl-c` and never says `Ctrl-z` is safe.
- A coherent changeset ships its docs in sync. This is the last task before the round-2 release.

## What

### User-visible behavior
None directly — documentation-only. Readers of the README region blurb and the CONFIGURATION
Mouse/cancel sections see accurate, post-fix descriptions.

### Success Criteria
- [ ] docs/CONFIGURATION.md "Mouse" section describes click (move cursor + clear selection),
      drag (linewise; Alt → block), wheel (half-page scroll), always-on, ignored during search.
- [ ] docs/CONFIGURATION.md "Region overlay: mouse is not yet functional" Known-limitations
      bullet is REMOVED; the Overview "two region-overlay deviations" line reflects one (search).
- [ ] README.md region blurb adds mouse (click/drag/wheel) alongside the keyboard and lists
      `q`/`Esc`/`Ctrl-c` as cancel (exit `1`) with `Ctrl-z` ignored.
- [ ] No new `@tmux-2html-*` option / env var / CLI flag is documented (none was added).
- [ ] Cancel references (Selection table `q`/`Ctrl-c`, Cancel paragraph "exits `1`") verified
      accurate post-fix; optional one-sentence Ctrl-c/Ctrl-z note added to the Cancel paragraph.
- [ ] Markdown reads cleanly (no broken tables/lists); `scripts/check-safety.sh` and
      `scripts/preflight.sh` clean.

## All Needed Context

### Context Completeness Check

_Passed._ Every stale string is pinned to a file:line with exact before→after text below
(§Implementation Blueprint). The shipped mouse/signal behavior is sourced from the round-2
architecture docs. A developer with no prior repo knowledge can apply the edits and eyeball-
validate.

### Documentation & References

```yaml
# MUST READ — the source of truth for WHAT changed (read before editing docs)
- docfile: plan/004_92f7aeb62a3a/bugfix/002_b76ad57f9c71/architecture/mouse_wiring_design.md
  why: "Exact post-fix mouse behavior: click=move cursor + clear selection; drag=linewise, Alt=block (live toggle); wheel=half-page scroll + clamp; ignored during search; always-on."
  critical: "A click with NO drag leaves NO selection (Enter then behaves as 'no selection'). Wheel is HALF-PAGE (== Ctrl-d/u), not 5-line. No option/flag — mouse is always-on."

- docfile: plan/004_92f7aeb62a3a/bugfix/002_b76ad57f9c71/architecture/isig_fix_design.md
  why: "The ISIG-off root cause + fix for Issues 2 & 3. Ctrl-c -> exit 1 (was 130); Ctrl-z -> ignored (was suspend)."
  critical: "ISIG off => Ctrl-c (0x03) reaches input.zig => .quit => exit 1; Ctrl-z (0x1a) is unmapped => swallowed. Both are now inert bytes, never signals."

- docfile: plan/004_92f7aeb62a3a/bugfix/002_b76ad57f9c71/P1M3T1S1/research/findings.md
  why: "THIS task's research: exact before/after for all 4 edits + the verify-only list (so you don't over-edit) + scope discipline."
  section: "§2 (stale refs + before/after), §3 (already-accurate, verify only), §4 (scope discipline)"

# The two files you EDIT (only these)
- file: README.md
  why: "Edit ONE spot: the 'The region overlay' blurb (~lines 100-107). Add mouse (click/drag/wheel) alongside keyboard; cancel = q/Esc/Ctrl-c (exit 1); Ctrl-z ignored. Concise blurb, NOT a keystroke table."

- file: docs/CONFIGURATION.md
  why: "Edit THREE spots: Overview 'two region-overlay deviations' (~line 31) -> one; '### Mouse (not yet functional in v1)' section (~192-196) -> rewritten Mouse section; Known-limitations 'mouse is not yet functional' bullet (~354-356) -> DELETED. Plus optional one-sentence Ctrl-c/Ctrl-z note in the Cancel paragraph (~187-190)."
```

### Current Codebase tree (doc surface only)

```bash
README.md                 # "The region overlay" blurb (keyboard-only, "or q to cancel") -> edit
docs/CONFIGURATION.md     # Overview list + Mouse section + Known-limitations bullet -> edit (3 spots)
# (AGENTS.md: no region/input prose this round. No CHANGELOG. No markdown linter => eyeball-only.)
```

### Desired Codebase tree

```bash
README.md                 # 1 edit (region overlay blurb)
docs/CONFIGURATION.md     # 3 edits (Overview line, Mouse section, delete mouse-limitation bullet) + optional cancel note
```

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL: the changeset added NO option / env var / CLI flag. Do NOT invent an @tmux-2html-mouse
# option or a --mouse flag. The Mouse section must state mouse is ALWAYS-ON with no knob (preempts
# the reader expecting one). This is explicit in the item contract.

# CRITICAL: a click with NO drag leaves NO selection (applyMouse clears it). The Mouse section must
# say so — otherwise readers will expect "click then Enter" to render the clicked cell.

# CRITICAL: wheel = HALF-PAGE (Ctrl-d/u magnitude), NOT a 5-line tmux default. State half-page;
# architecture/mouse_wiring_design.md calls the 5-line default a deferred future refinement.

# No markdown linter is configured (no .markdownlint*, no remark/mdlint in CI) => validation is
# EYEBALL: read the rendered Mouse bullet list + the region blurb; confirm tables/lists stay
# well-formed (no broken '|' rows, no dangling list items after deleting the limitation bullet).

# Keep README a CONCISE blurb ("not a keystroke table" — item contract). The full keystroke
# reference lives in docs/CONFIGURATION.md; don't duplicate it in the README.

# check-safety.sh scans .md too, but only for literal dangerous shell (killall tmux / exec tmux).
# The new wording references keys/by-name, so it won't trip — but don't paste a literal
# `killall tmux`/`exec tmux` into any doc.
```

## Implementation Blueprint

### Data models and structure

N/A — documentation-only task. No code, no types.

### Implementation Tasks (ordered; each is an exact text replacement)

```yaml
Task 1: EDIT docs/CONFIGURATION.md — rewrite the Mouse section (~lines 192-196)  [Issue 1]
  - FIND:
      ### Mouse (not yet functional in v1)

      Mouse input is **recognized** by the terminal layer but is not yet wired into
      the overlay, so click, drag, and wheel have no effect in v1. Use the keyboard.
      This is a known limitation — see [Known limitations](#known-limitations).
  - REPLACE WITH:
      ### Mouse

      The overlay supports the mouse (it enables SGR mouse reporting on entry),
      matching tmux copy-mode:

      - **Click** moves the cursor to the clicked cell and clears any active
        selection. A click with no drag leaves no selection, so confirming right
        after a click behaves like "no selection".
      - **Drag** selects: press and drag to extend a selection from the press cell
        to the cursor. Dragging is **linewise** by default; hold **`Alt`** (or toggle
        it mid-drag) for a **block** selection.
      - **Wheel** scrolls the viewport by half a page (like `Ctrl-d` / `Ctrl-u`) and
        keeps the cursor in view.

      Mouse input is ignored while you are typing a search pattern. There is no
      option to enable or disable the mouse — it is always on, like the keyboard.
  - WHY: mouse is now functional (§7.6). The old "not yet wired / no effect in v1" is wrong.
  - GOTCHA: keep "click with no drag leaves no selection" + "half a page" + "no option" — all faithful to the shipped applyMouse()/mouse_wiring_design.md.

Task 2: EDIT docs/CONFIGURATION.md — DELETE the mouse Known-limitations bullet (~lines 354-356)  [Issue 1]
  - FIND and DELETE the entire bullet:
      - **Region overlay: mouse is not yet functional.** Mouse input is enabled and
        decoded at the terminal layer, but the overlay loop never acts on it, so click,
        drag, and wheel have no effect in v1. Use the keyboard.
  - WHY: mouse is no longer a limitation. The next bullet (search fixed-string) becomes the only region deviation.
  - PRESERVE: the surrounding bullets (huge scrollback, alt-screen, empty selection, wide chars, OSC 8, binary acquisition, region search, concurrent runs). Ensure the list stays well-formed after deletion.

Task 3: EDIT docs/CONFIGURATION.md — Overview list "two region-overlay deviations" (~line 31)  [Issue 1]
  - FIND the fragment:  "…offline failure, and the two region-overlay deviations."
  - REPLACE WITH:       "…offline failure, and the region-overlay search limitation."
  - WHY: with mouse functional, only ONE region deviation remains (search fixed-string/case-sensitive). Keeps the Overview consistent with Tasks 1 & 2.
  - PRESERVE: the rest of the Overview bullet list (Options / region overlay / palette cache / sync-palette / attribution).

Task 4: EDIT README.md — "The region overlay" blurb (~lines 100-107)  [Issues 1/2/3]
  - FIND:
      Press `prefix C-o` to open a pane-anchored, copy-mode-style overlay (sized to
      the current pane) over the scrollback. Move the cursor and select a region;
      press `v` to begin or re-anchor a linewise selection and `Ctrl-v` to toggle
      block mode; press `Enter` to render the selection to an HTML file, or `q` to
      cancel. The in-app status line lists every key. See
      [docs/CONFIGURATION.md](docs/CONFIGURATION.md) for the full key list and
      behavior.
  - REPLACE WITH:
      Press `prefix C-o` to open a pane-anchored, copy-mode-style overlay (sized to
      the current pane) over the scrollback. Use the keyboard or the mouse: move the
      cursor with the arrow/hjkl keys or by clicking, select a region with `v` /
      `Ctrl-v` or by dragging (linewise by default, block with `Alt`), and scroll
      with the wheel (or `Ctrl-d` / `Ctrl-u`). Press `Enter` to render the selection
      to an HTML file, or cancel with `q`, `Esc`, or `Ctrl-c` (all exit `1`; other
      control keys such as `Ctrl-z` are ignored rather than suspending the popup).
      The in-app status line lists every key. See
      [docs/CONFIGURATION.md](docs/CONFIGURATION.md) for the full key list and
      behavior.
  - WHY: blurb was keyboard-only + "or q to cancel"; now covers mouse (click/drag/wheel) and the corrected cancel set (q/Esc/Ctrl-c, exit 1) + Ctrl-z inert.
  - DISCIPLINE: this is a CONCISE blurb, not a keystroke table — do not enumerate every motion key (that's in CONFIGURATION.md).

Task 5: VERIFY (no rewrite) docs/CONFIGURATION.md cancel references  [Issues 2/3]
  - READ the Selection table row (~line 173): `| `q` / `Ctrl-c` | cancel and exit |`  => ALREADY groups Ctrl-c with q. Accurate post-fix. Leave.
  - READ the Cancel paragraph (~lines 187-190): "**Cancel** — `q`, `Ctrl-c`, or `Esc` with no selection exits `1` …"  => ALREADY states exit `1`. Post-fix this is now TRUE (was aspirational under the ISIG bug). Leave the existing sentence.
  - OPTIONAL (recommended for changeset fidelity): append ONE sentence to that Cancel paragraph, after the "exits `1` and produces no output." clause:
      "`Ctrl-c` cancels like the other keys (exit `1`, not a signal death), and `Ctrl-z` is ignored — it does not suspend the popup."
    (Keep the existing `--output` / concurrent-run parenthetical after it.)
  - WHY: the contract asks the cancel reference to reflect Ctrl-c ⇒ exit 1 (already there) AND Ctrl-z ignored (the optional sentence adds it faithfully). Minimal.
```

### Implementation Patterns & Key Details

```text
# Single discipline: ONLY fix prose describing pre-fix behavior; do not add capability docs or
# knobs. Four edits (Tasks 1-4) + one verify/optional (Task 5). The Mouse section is the heart
# of the change; the README blurb + Overview line + deleted limitation bullet keep everything
# consistent so no doc contradicts another.

# Faithful-fact checklist for new wording (do not deviate — from mouse_wiring_design.md):
#   click (no drag)  -> cursor moves, selection CLEARED
#   drag             -> linewise; Alt -> block (live mid-drag toggle); extends anchor->cursor
#   wheel            -> HALF-PAGE scroll (== Ctrl-d/u), cursor clamped into view
#   mouse during search-typing -> ignored
#   mouse            -> always-on, NO option/flag/env
#   Ctrl-c           -> exit 1 (ISIG off => 0x03 reaches input.zig)
#   Ctrl-z           -> ignored (0x1a unmapped => swallowed; no SIGTSTP)
```

### Integration Points

```yaml
DOCS (the only files touched):
  - README.md: 1 edit (region overlay blurb).
  - docs/CONFIGURATION.md: 3 edits (Overview line, Mouse section, delete mouse-limitation bullet) + optional 1-sentence cancel note.

DEPENDS ON (already shipped / in flight — treat as contracts):
  - P1.M1.T1.S1 (ISIG off in makeRaw) — COMPLETE. Ctrl-c exits 1, Ctrl-z ignored.
  - P1.M1.T2.S1 (tests/region_signal_keys.sh) — COMPLETE.
  - P1.M2.T1.S1/S2 + P1.M2.T2.S1 (mouse wiring) — COMPLETE. Mouse functional as documented.
  - P1.M2.T3.S1 (tests/region_mouse.sh) — IN FLIGHT (parallel). Adds ONLY a test harness; touches
    NO docs => no conflict with this task.

NOT TOUCHED (other tasks own):
  - src/, tests/, scripts/, .github/, AGENTS.md (AGENTS.md has no region/input prose this round).
```

## Validation Loop

### Level 1: Stale-phrase removal (deterministic grep)

```bash
# These stale phrases MUST be gone after the edits:
grep -rniE "not yet functional|no effect in v1|two region-overlay deviations" README.md docs/CONFIGURATION.md
# Expected: NO output.

grep -nE "or `q` to cancel" README.md   # the old keyboard-only cancel clause
# Expected: NO output (replaced by the q/Esc/Ctrl-c blurb).
```

### Level 2: Safety + residue gates still pass

```bash
scripts/check-safety.sh; echo "exit=$?"
# Expected: no NEW violation from the .md edits (prose only; no literal killall/exec tmux). The
# scan already runs repo-wide; .md edits referencing keys by name do not trip it.

scripts/preflight.sh
# Expected: clean (no >100 MiB files, no residue, disk OK).
```

### Level 3: Accuracy spot-check (the docs match the shipped binary)

```bash
# Mouse: an SGR click should move the cursor; a drag+Enter should write a file; wheel should scroll.
# (Requires P1.M2.T2.S1 applied + P1.M2.T3.S1 harness.) If the harness exists:
sh tests/region_mouse.sh && echo "mouse: PASS"   # documents click/drag/wheel => matches Mouse section

# Signal keys: Ctrl-c exits 1; Ctrl-z does not suspend. (Requires P1.M1.T1.S1 applied.)
sh tests/region_signal_keys.sh && echo "signal keys: PASS"

# Manual read-back: open docs/CONFIGURATION.md "Mouse" + README "The region overlay"; confirm
# they describe click/drag/wheel and q/Esc/Ctrl-c (exit 1) / Ctrl-z ignored as above.
```

### Level 4: Markdown well-formedness (eyeball — no linter in repo)

```bash
# No markdown linter is configured => eyeball. Confirm:
#   - the rewritten Mouse section's bullet list renders (3 bullets, consistent `-` markers);
#   - deleting the mouse limitation bullet did not leave a dangling/empty list or merge bullets;
#   - the README blurb is a single paragraph (no broken inline code spans);
#   - the Overview list still has its 6 bullets with the corrected "search limitation" fragment.
git diff --stat README.md docs/CONFIGURATION.md
git diff README.md docs/CONFIGURATION.md | grep -E '^\+\s*###|^\+\s*-\s'   # sanity: new headings/bullets
```

## Final Validation Checklist

### Technical Validation
- [ ] Level 1 grep: stale phrases ("not yet functional", "no effect in v1", "two region-overlay deviations", "or `q` to cancel") are gone.
- [ ] `scripts/check-safety.sh` does not gain a violation from the edits.
- [ ] `scripts/preflight.sh` clean.
- [ ] `git diff` shows ONLY the targeted prose edits in README.md + docs/CONFIGURATION.md.

### Feature Validation
- [ ] docs/CONFIGURATION.md Mouse section describes click/drag(linewise+Alt-block)/wheel(half-page), always-on, ignored during search, no knob.
- [ ] docs/CONFIGURATION.md "mouse is not yet functional" limitation bullet is DELETED; Overview reflects ONE region deviation (search).
- [ ] README region blurb: mouse (click/drag/wheel) alongside keyboard; cancel = q/Esc/Ctrl-c (exit `1`); Ctrl-z ignored.
- [ ] No doc describes pre-fix (non-functional mouse / Ctrl-c=130 / Ctrl-z=suspend) behavior.

### Code Quality / Discipline Validation
- [ ] No new Changelog / section added beyond the targeted edits (README stays a concise blurb).
- [ ] No invented `@tmux-2html-*` option / env var / CLI flag for mouse.
- [ ] Did NOT edit src/, tests/, scripts/, .github/, AGENTS.md (other tasks own those; P1.M2.T3.S1 touches no docs).
- [ ] Mouse-section wording is faithful (click clears selection; wheel = half-page; Alt = block; no knob).
- [ ] Markdown tables/lists well-formed after the edits (eyeball).

### Documentation & Deployment
- [ ] New wording matches the shipped binary (click/drag/wheel + Ctrl-c exit 1 + Ctrl-z ignored).
- [ ] No internal markdown link/anchor broken (edits are in-paragraph/in-list; the deleted limitation bullet was self-contained; no heading renames except Mouse "###" which has no inbound anchor link).

---

## Anti-Patterns to Avoid

- ❌ Don't invent a mouse option/flag/env — the changeset added none; say mouse is always-on.
- ❌ Don't claim wheel scrolls a fixed 3/5 lines — it's HALF-PAGE (Ctrl-d/u magnitude).
- ❌ Don't claim a click selects — a click with no drag CLEARS the selection (moves cursor only).
- ❌ Don't turn the README blurb into a keystroke table — keep it concise (contract).
- ❌ Don't leave the "two region-overlay deviations" Overview line or the "mouse is not yet functional" limitation bullet — both are now false and must be fixed/removed.
- ❌ Don't edit src/, tests/, scripts/, AGENTS.md — Mode A / P1.M1.* / P1.M2.* / round-1 own those.
- ❌ Don't reword the cancel references beyond the optional one-sentence Ctrl-c/Ctrl-z note — they already say exit `1` and group Ctrl-c with q.
- ❌ Don't paste literal `killall tmux`/`exec tmux` into any doc — check-safety.sh scans .md too.

---

## Confidence Score: 9/10

A small, deterministic documentation sweep. Every stale reference is pinned to file:line with
exact before→after text (verified by grep), the post-fix mouse/signal facts are sourced from the
round-2 architecture docs (mouse_wiring_design.md, isig_fix_design.md), and the "already accurate,
verify-only" set is explicit (prevents over-editing). The 1/10 residual is ordinary proofreading
risk (markdown list/table well-formedness after deleting a bullet — eyeball-checked). No code, no
builds; gates are grep + check-safety + preflight + a git-diff audit.