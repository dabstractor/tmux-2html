# Research findings — P1.M3.T1.S1: README region/mouse + docs/CONFIGURATION region-keys (bugfix round 2)

> **Task type:** SOW Mode B documentation sync (round 2). The implementing subtasks shipped:
> mouse is now FUNCTIONAL in the region TUI (PRD §7.6), and the ISIG fix made `Ctrl-c` cancel
> cleanly (exit 1, not 130) and `Ctrl-z` ignored (no suspend). NO new option/env/flag was added.
> This task updates the overview/reference docs so they no longer describe the pre-fix state.

## 0. The three behavior changes shipped this round (from the round-2 bugfix PRD)

- **Issue 1 (Major) — mouse (§7.6) now works.** Was: decoded by `app.zig` but dropped by
  `regionHandle` (a no-op). Now: a `.mouse` arm in `regionHandle` + pure `mouseCell()` /
  `applyMouse()` consume the SGR `MouseEvent`. Behavior (from
  `architecture/mouse_wiring_design.md`, the contract):
  - **Click** (press+release same cell, no drag): moves cursor to the clicked cell, clears any
    active selection. A plain click leaves NO selection.
  - **Drag** (press → motion → release): begins a selection at the press cell, extends to the
    cursor. **Linewise by default; `Alt` held/toggled → block** (live mode switch mid-drag).
  - **Wheel**: scrolls the viewport **half a page** (like Ctrl-d/u) and clamps the cursor into view.
  - Mouse ignored while typing a search pattern. Always-on; no option/flag.
- **Issue 2 (Major) — Ctrl-z no longer suspends.** Was: SIGTSTP froze the popup, TTY unrestored.
  Fix: `raw.lflag.ISIG = false;` in `makeRaw` → Ctrl-z (0x1a) arrives as an inert byte, unmapped ⇒
  swallowed. No suspend, TTY intact.
- **Issue 3 (Minor) — Ctrl-c now exits 1.** Was: ISIG intercepted Ctrl-c as SIGINT ⇒ exit 130.
  Same fix (ISIG off) ⇒ 0x03 reaches `input.zig` ⇒ `.quit` ⇒ normal exit `1`, grouped with q/Esc.
  The `0x03 → .quit` mapping in `input.zig` is no longer dead code.

## 1. Doc surface in scope (verified via `ls` + `grep`)

Only `README.md` and `docs/CONFIGURATION.md` carry user-facing region/input prose. (`AGENTS.md`
has no region-input prose; round-1 already synced its safety row. No CHANGELOG exists.)
No markdown linter is configured (no .markdownlint*, no remark/mdlint in CI) → **eyeball-only**
validation: read the rendered markdown, confirm tables/lists stay well-formed.

`docs/CONFIGURATION.md` DOES document in-TUI keys (Movement / Search / Selection / Confirm-and-
cancel / Mouse sections) — so the contract's "add the mouse bindings + corrected Ctrl-c exit
code if such a reference exists" applies: the Mouse section is the reference to update, and the
cancel references already say exit `1` (now accurate — verify, don't rewrite).

## 2. STALE references (MUST fix) — exact locations + before/after

### 2.1 docs/CONFIGURATION.md — Overview list, "two region-overlay deviations" (line 31)
**Before:** `…offline failure, and the two region-overlay deviations.`
**Problem:** the two deviations were (a) mouse-not-functional, (b) search-fixed-string. Mouse is
now functional → only ONE deviation remains (search).
**After:** `…offline failure, and the region-overlay search limitation.`
(Also covered by the §2.3/§2.4 edits below; keep this Overview line consistent with them.)

### 2.2 docs/CONFIGURATION.md — "### Mouse (not yet functional in v1)" section (lines 192-196) [Issue 1]
**Before:**
```
### Mouse (not yet functional in v1)

Mouse input is **recognized** by the terminal layer but is not yet wired into
the overlay, so click, drag, and wheel have no effect in v1. Use the keyboard.
This is a known limitation — see [Known limitations](#known-limitations).
```
**After (intended):**
```
### Mouse

The overlay supports the mouse (it enables SGR mouse reporting on entry),
matching tmux copy-mode:

- **Click** moves the cursor to the clicked cell and clears any active
  selection. A click with no drag leaves no selection, so confirming right
  after a click behaves like "no selection".
- **Drag** selects: press and drag to extend a selection from the press cell to
  the cursor. Dragging is **linewise** by default; hold **`Alt`** (or toggle it
  mid-drag) for a **block** selection.
- **Wheel** scrolls the viewport by half a page (like `Ctrl-d` / `Ctrl-u`) and
  keeps the cursor in view.

Mouse input is ignored while you are typing a search pattern. There is no
option to enable or disable the mouse — it is always on, like the keyboard.
```
(The last sentence PREEMPTS a reader expecting a config knob; the changeset added none.)

### 2.3 docs/CONFIGURATION.md — Known limitations "Region overlay: mouse is not yet functional" (lines 354-356) [Issue 1]
**Before:**
```
- **Region overlay: mouse is not yet functional.** Mouse input is enabled and
  decoded at the terminal layer, but the overlay loop never acts on it, so click,
  drag, and wheel have no effect in v1. Use the keyboard.
```
**After:** **DELETE this bullet entirely.** Mouse is no longer a limitation. The next bullet
(`Region overlay: search is fixed-string, case-sensitive.`) becomes the only region deviation.

### 2.4 README.md — "The region overlay" blurb (lines 100-107) [Issues 1/2/3]
**Before:**
```
Press `prefix C-o` to open a pane-anchored, copy-mode-style overlay (sized to
the current pane) over the scrollback. Move the cursor and select a region;
press `v` to begin or re-anchor a linewise selection and `Ctrl-v` to toggle
block mode; press `Enter` to render the selection to an HTML file, or `q` to
cancel. The in-app status line lists every key. See
[docs/CONFIGURATION.md](docs/CONFIGURATION.md) for the full key list and
behavior.
```
**Problem:** keyboard-only; cancel lists only `q` (no Ctrl-c; no mention that Ctrl-z is inert);
no mouse.
**After (intended — concise blurb, NOT a keystroke table):**
```
Press `prefix C-o` to open a pane-anchored, copy-mode-style overlay (sized to
the current pane) over the scrollback. Use the keyboard or the mouse: move the
cursor with the arrow/hjkl keys or by clicking, select a region with `v` /
`Ctrl-v` or by dragging (linewise by default, block with `Alt`), and scroll with
the wheel (or `Ctrl-d` / `Ctrl-u`). Press `Enter` to render the selection to an
HTML file, or cancel with `q`, `Esc`, or `Ctrl-c` (all exit `1`; other control
keys such as `Ctrl-z` are ignored rather than suspending the popup). The in-app
status line lists every key. See [docs/CONFIGURATION.md](docs/CONFIGURATION.md)
for the full key list and behavior.
```

## 3. References REVIEWED and ALREADY ACCURATE (verify-only, no rewrite)

- **docs/CONFIGURATION.md Selection table (line 173):** `| `q` / `Ctrl-c` | cancel and exit |`
  — already groups Ctrl-c with q. Accurate post-fix (Ctrl-c now really does cancel+exit 1). Leave.
- **docs/CONFIGURATION.md "Confirm and cancel" → Cancel paragraph (lines 187-190):**
  "**Cancel** — `q`, `Ctrl-c`, or `Esc` with no selection exits `1`…" — already states exit `1`.
  Post-fix this is now TRUE (was aspirational while ISIG made Ctrl-c exit 130). **Optional
  minimal addition (recommended for changeset fidelity):** append a sentence that Ctrl-c cancels
  as a key (exit 1, not signal death) and Ctrl-z is ignored. Suggested wording:
  *"`Ctrl-c` cancels like the other keys (exit `1`, not a signal death), and `Ctrl-z` is ignored
  — it does not suspend the popup."* (Tack onto the existing Cancel paragraph; keep the
  `--output`/concurrent-run parenthetical.)
- **docs/CONFIGURATION.md region-overlay intro (line ~104-105):** "Confirming a selection
  renders it to an HTML file … Canceling exits with no output." — high-level summary; the
  mouse/cancel-key detail lives in the Mouse + Confirm-and-cancel sections. Leave.
- **README.md "Known limitations"** — has NO mouse bullet (only alt-screen apps + scrollback
  cap). Nothing to remove there. Leave.
- **docs/CONFIGURATION.md status-line format (~line 117-130):** unchanged by this changeset
  (no mouse token added to the status line). Leave.

## 4. Scope discipline (what NOT to do)

- Do NOT add a Changelog / "Fixed" section (none exists; these are robustness/feature-completion
  fixes, and the contract says keep README a concise blurb).
- Do NOT invent any `@tmux-2html-*` option, env var, or CLI flag for mouse. The Mouse section
  must state mouse is always-on with no knob.
- Do NOT edit `src/`, `tests/`, `scripts/`, `.github/` (Mode A + P1.M1.*/P1.M2.* own those).
  P1.M2.T3.S1 (parallel, in flight) only adds `tests/region_mouse.sh` — it touches NO docs, so
  no conflict.
- Do NOT turn the README region blurb into a keystroke table (contract: "concise feature blurb,
  not a keystroke table").
- Do NOT change the status-line format string (unchanged).

## 5. Post-fix facts to keep wording faithful (from architecture/mouse_wiring_design.md + isig_fix_design.md)

- Click (no drag) → cursor moves + selection CLEARED (Enter then ⇒ "no selection" exit 1).
- Drag → linewise; Alt → block (live toggle mid-drag); extends anchor→cursor.
- Wheel → half-page scroll (== Ctrl-d/u magnitude), cursor clamped into view.
- Mouse ignored during search-pattern typing.
- Ctrl-c → `.quit` → exit `1` (ISIG off ⇒ 0x03 reaches input.zig). Ctrl-z (0x1a) → unmapped ⇒
  swallowed (no SIGTSTP, TTY restored on real exit).

## 6. Validation (eyeball — no markdown linter in repo)

- Re-grep: `grep -niE "not yet functional|no effect in v1|two region-overlay" README.md
  docs/CONFIGURATION.md` ⇒ NOTHING (all stale phrases gone).
- Read the edited Mouse section + README blurb rendered; confirm the bullet list and tables stay
  well-formed (no broken `|` rows, no dangling list items).
- `scripts/check-safety.sh` ⇒ must not gain a violation from the .md edits (it won't — they're
  prose, and the wording contains no literal `killall tmux`/`exec tmux`).
- `scripts/preflight.sh` ⇒ clean.
- (Sanity, optional) Build + run `sh tests/region_mouse.sh` and `sh tests/region_signal_keys.sh`
  to confirm the binary matches the documented mouse + Ctrl-c/Ctrl-z behavior.