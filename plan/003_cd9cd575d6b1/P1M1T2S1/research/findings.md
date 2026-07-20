# Research Findings — P1.M1.T2.S1 (Verify README.md vs the new status-line hint; update if stale)

> Mode B documentation-sync task for plan/003 (§7.1 status-line hint change). Verified by
> reading README.md in full (2026-07-1x) and cross-checking against PRD §7.4 + the new
> `renderStatus` hint from the parallel task P1.M1.T1.S1.

## 1. The decision: ONE-LINE CHANGE (line 100), not "no change"

README.md line 100 (in the "## The region overlay" paragraph) is **stale**:

> … Move the cursor and select a region; press `v` to toggle between **linewise and block
> selection**; press `Enter` …

Per PRD §7.4, `v` does **NOT** toggle linewise↔block:
- `v` — **begin / re-anchor** a selection in **linewise** mode (rectangle OFF). Re-pressing `v`
  moves the anchor; it never switches to block.
- `Ctrl-v` — **toggle block** (rectangle) mode. THIS is the linewise↔block toggle.

So "press `v` to toggle between linewise and block selection" actively misrepresents the
shipped §7.4 behavior — and the contract flags exactly this. The new status-line hint from
T1.S1 (`v=sel C-v=block o=swap`) makes the real keys visible on-screen, which would
contradict a README that still says `v` toggles block. **The README must be fixed.**

### The exact fix (one clause swap)
The stale clause (wrapping lines 100→101) is replaced; the rest of the paragraph is kept:

```
… press `v` to toggle between linewise and block selection; press `Enter` …   ← STALE
… press `v` to begin or re-anchor a linewise selection and `Ctrl-v` to toggle block mode; press `Enter` …   ← FIX
```

This mirrors the new status-line hint (`v=sel`/`C-v=block`) and §7.4, is minimal (a clause
swap, no new section/blurb), and keeps the surrounding text (Enter/q, "lists every key", the
CONFIGURATION.md link) byte-for-byte.

## 2. Everything else in README.md is CONSISTENT (no change)

Full scan of README.md for selection/status-line phrasing:
- **Line 27** ("lets you select a line range or a block to render") — **accurate** (linewise =
  line range, block = block). Keep.
- **Line 100–101** — STALE (see §1). **Fix.**
- **Line 102** ("The in-app status line lists every key") — **generic, keep**. The contract says
  this needs no change; it is in fact *more* accurate now: before T1.S1 the status line showed
  the opaque `<S-sel>` + `Enter=render q=quit` (2 keys); after T1.S1 it shows
  `v=sel C-v=block o=swap Enter=render q=quit` (5 keys). "Lists every key" is a fair lay summary
  of the always-shown action keys. Touching it would be scope creep.
- The §7.4 keybinding detail (re-anchor mechanics, `o` swap, `Esc` clear, `V`/`R` aliases)
  correctly lives in `docs/CONFIGURATION.md`, NOT the README overview — do not pull it in.

## 3. Boundary with the parallel task P1.M1.T1.S1 (no collision)

T1.S1 edits **`src/tui/view.zig`**, **`src/tui/select.zig`**, and **`docs/CONFIGURATION.md`**
(Mode A). Its PRP explicitly defers README.md to this task ("Do NOT edit README here … the Mode
B task P1.M1.T2.S1 verifies the overview docs").

This task edits **`README.md` ONLY**. `docs/CONFIGURATION.md` is OFF-LIMITS here (the contract:
"docs/CONFIGURATION.md was already updated in P1.M1.T1.S1 (Mode A); do NOT re-edit it here").
Zero file overlap ⇒ clean parallel merge.

## 4. No automated README validation exists

CI (`.github/workflows/ci.yml`) runs only `zig build test -Doptimize=ReleaseFast` (Zig tests).
No markdown linter, no README structure check. (scripts/download.sh:28 notes a *separate*
cross-file invariant — "keep download.sh's GitHub URL in sync with README.md's `@plugin` line"
— which is NOT touched by this edit and is out of scope.) ⇒ The validation gate for this task
is **deterministic grep assertions + manual eyeball** (no build step needed; this is prose).

## 5. Pre-existing cross-file note (do NOT regress)

`scripts/download.sh:28` documents that README.md's `@plugin 'tmux-2html/tmux-2html'` line
(line 51) must stay in sync with download.sh's release URL. This task edits the **region-overlay
paragraph (lines 99-104)**, NOT the `@plugin` line — so that invariant is untouched. The
implementer must NOT accidentally edit the Installation/`@plugin` section.

## 6. Validation commands (deterministic, no build)

```bash
# OLD stale phrasing is GONE:
grep -n 'toggle between linewise and block' README.md          # expect: NO match
# NEW accurate phrasing is PRESENT:
grep -n 'begin or re-anchor a linewise selection' README.md    # expect: 1 match (line ~100)
grep -n 'Ctrl-v` to toggle block mode' README.md               # expect: 1 match
# Scope guard: ONLY README.md changed (not CONFIGURATION.md, not any .zig):
git diff --stat                                                 # expect: README.md only
# Sanity: the @plugin line (download.sh sync invariant) untouched:
grep -n "@plugin 'tmux-2html/tmux-2html'" README.md            # expect: line 51 unchanged
```