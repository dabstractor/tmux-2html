# Research Findings — P1.M1.T2.S1 (Update 3 stale region/runtime refs in README.md → pane-anchored overlay)

> Mode B documentation sweep for plan/004 (pane-anchored region overlay host). Verified by
> reading README.md in full + plan/004 architecture (system_context.md §2.4, external_tmux_popup.md
> claim #5) on 2026-07-1x. Depends on the binding change in P1.M1.T1.S1 (Implementing).

## 1. The decision: THREE targeted edits (not "no change")

README.md has exactly three stale references to the OLD fullscreen region popup. A full grep
scan confirms there are no others. All three must change to match the shipped pane-anchored
binding (PRD §7.0 / §9.3 / §12) and the 3.3 version floor.

### The three spots (exact current text, line numbers verified)

**Spot 1 — "Capture modes" → Region bullet (lines 26–27):**
```
- **Region.** Opens a copy-mode-style full-screen overlay over the scrollback
  and lets you select a line range or a block to render.
```
→ "full-screen overlay" → "pane-anchored overlay (sized to the current pane)".

**Spot 2 — Requirements, tmux version floor (lines 31–32):**
```
- **tmux >= 3.2.** The region overlay and the one-time palette sync use
  `display-popup`, which tmux 3.2 introduced.
```
→ bump `>= 3.2` → `>= 3.3`; rationale: the region overlay uses `-B` borderless + pane-anchored
`-x`/`-y` (tmux 3.3). Keep the nuance that the palette auto-sync popup only needs `display-popup`
(3.2), but the floor follows the region overlay's flags.

**Spot 3 — "## The region overlay" opener (line 99, first sentence of the paragraph):**
```
Press `prefix C-o` to open a full-screen, copy-mode-style overlay over the pane
scrollback. …
```
→ "a full-screen, copy-mode-style overlay" → "a pane-anchored, copy-mode-style overlay (sized to
the current pane)". (The rest of the paragraph — lines 100-104, the v/Ctrl-v/Enter/q clause +
status-line + CONFIGURATION.md link — is already current and stays byte-for-byte.)

## 2. Grep scan — confirms NO other stale wording

```
full-screen|full screen  → lines 26, 99  (both in scope; no others)
tmux version (3.2/3.3)   → lines 31, 32  (both in scope; no others)
```
Other "overlay" mentions are generic and accurate (line 90 "Open the region overlay";
line 97 the heading; line 115 "Interactive copy-mode overlay: select a region, render it";
line 148 the option row). None say "full-screen". Keep all.
Zig `0.15.2` mentions (lines 33/60/69) are Zig, not tmux — keep.

**Line 100–101 (the `v`/`Ctrl-v` selection clause) is already correct** — it was updated in a
prior plan (003: "press `v` to begin or re-anchor a linewise selection and `Ctrl-v` to toggle
block mode"). This task does NOT touch it.

## 3. The 3.3 rationale (HIGH confidence — external_tmux_popup.md claim #5)

- `display-popup` (any form) requires **tmux ≥ 3.2** (introduced then).
- **`-B` (borderless)** shipped in **tmux 3.3** (3.2 always drew a border).
- The single-letter **`-x`/`-y` position tokens** (`M`/`W`/`S`/`P`/`C`; `P` = pane-anchored)
  are **tmux 3.3**.
- The combination `-B` + `-x P`/`-y P` therefore requires **≥ 3.3**. `-B` alone already forces 3.3.
- So the floor `tmux ≥ 3.3` (PRD §12) is correct and NOT over-constrained.
- The one-time palette auto-sync popup is a 50% popup with **no** `-B`/`-x P`/`-y P` → it would
  work on 3.2 — but the version floor is bound to the **region overlay's** flags, which need 3.3.

## 4. Boundary with the parallel task P1.M1.T1.S1 (no collision)

T1.S1 (Implementing) edits **`tmux-2html.tmux`** (binding line 214 + comment), **`tests/plugin_options.sh`**
(c.3 sed), and **`docs/CONFIGURATION.md`** (2 spots — Mode A). Its PRP explicitly defers README.md:
"README.md NOT edited here (separate Mode B task P1.M1.T2.S1)."

This task edits **`README.md` ONLY**. `docs/CONFIGURATION.md` is OFF-LIMITS (Mode A, owned by T1.S1;
the contract: "The per-feature docs/CONFIGURATION.md updates were already handled inline in
P1.M1.T1.S1 (Mode A)."). Zero file overlap ⇒ clean parallel merge.

## 5. No automated README validation; no tmux involved

CI (`.github/workflows/ci.yml`) runs only `zig build test -Doptimize=ReleaseFast` (Zig tests). No
markdown linter, no README structure check. This task involves **no tmux server** (PRD §0/§0.1
trivially satisfied — it's a prose edit). ⇒ The validation gate is **deterministic grep
assertions + manual eyeball** (no build step).

## 6. Cross-file invariant (do NOT regress)

`scripts/download.sh:28` documents that README.md's `@plugin 'tmux-2html/tmux-2html'` line (line 51)
must stay in sync with download.sh's release URL. This task edits the Region bullet (26–27),
Requirements (31–32), and the region-overlay opener (99) — NOT the Installation/`@plugin` section.
The implementer must NOT accidentally touch line 51 or the build/release URL block.

## 7. Validation commands (deterministic, no build)

```bash
# OLD stale wording is GONE:
grep -n -iE 'full-screen|full screen' README.md     # expect: NO match
grep -n '3\.2' README.md                            # expect: NO match (both 3.2 mentions → 3.3)
# NEW accurate wording is PRESENT:
grep -n 'tmux >= 3\.3' README.md                    # expect: 1 match (line ~31)
grep -n 'pane-anchored' README.md                   # expect: 2 matches (bullet ~26 + opener ~99)
# Scope guard: ONLY README.md changed (not CONFIGURATION.md, not tmux-2html.tmux, not .zig):
git diff --stat                                     # expect: README.md only
# Invariant guard: the @plugin line untouched:
grep -n "@plugin 'tmux-2html/tmux-2html'" README.md # expect: line 51, unchanged
```