name: "P4.M2.T1.S2 — docs/ overview sweep: known limitations, sync-palette, region usage"
description: |
  EXPANDS `docs/CONFIGURATION.md` (the "Mode A" options reference created earlier in
  P2.M2.T1.S1) into the project's comprehensive reference doc — the single deep-doc
  target the sibling README (P4.M2.T1.S1) links to. This is the "Mode B" cross-cutting
  docs sweep (PRD §5). Concretely the task: (1) adds a coherent top-level Overview;
  (2) adds a full **region overlay** TUI usage walkthrough (launch, status line,
  movement, search, selection, confirm/cancel) — matching SHIPPED behavior, which
  differs from PRD §7 in two places (search is fixed-string/case-sensitive NOT regex;
  mouse is recognized but NOT yet wired); (3) adds a **sync-palette** command section
  and FIXES the existing dangling "see the sync-palette documentation" reference;
  corrects the exit behavior (exit 2 only when /dev/tty is unopenable; a silent-but-open
  terminal exits 0 with a default-seeded cache + warning); (4) adds a **Known
  limitations** section covering the full PRD §13 list (huge scrollback cap + notice,
  alt-screen apps, empty selection, wide chars/grapheme/emoji, OSC 8 hyperlinks,
  checksum/offline failure) plus the region deviations (mouse, fixed-string search);
  (5) adds an **Attribution & license** section (PRD §14). Verifies the existing Options
  table + Palette cache section for drift. HOUSE STYLE: match the EXISTING
  docs/CONFIGURATION.md (em dashes ARE permitted there — the README's stricter
  no-em-dash rule does NOT apply to docs); factual reference-manual tone; no marketing
  puffery; no hedging. NO source/build/script changes. Does NOT touch README.md
  (sibling S1 owns it, in parallel). The ONE deliverable is the edited
  docs/CONFIGURATION.md; every factual claim is anchored to the two research fact sheets.

---

## Goal

**Feature Goal**: `docs/CONFIGURATION.md` becomes the single, accurate, comprehensive
reference for tmux-2html: configuration options, the region overlay (full TUI
walkthrough), the palette cache, the `sync-palette` command, every known limitation
(PRD §13, including the region deviations), and licensing/attribution (PRD §14) —
with every claim matching the shipped CLI/plugin, no stale references, and no
over-claims (notably: no regex-search or working-mouse claims).

**Deliverable**: ONE edited file — `docs/CONFIGURATION.md`. It gains new H2 sections
(Overview, The region overlay, The sync-palette command, Known limitations,
Attribution & license) and small fixes to existing sections (the dangling sync-palette
reference is resolved; the sync-palette exit behavior is stated correctly). No other
file is created or modified.

**Success Definition**:
- `docs/CONFIGURATION.md` contains a Region overlay section whose key tables and
  behavior text match `region_tui_facts.md` exactly: movement keys + counts; search is
  fixed-string and case-sensitive (NOT regex, NOT configurable); selection `v`/`V`/
  `Ctrl-v`/`R`/`o`/`O`/`Esc`/`q`; confirm `Enter`/`y` renders + sidecar + `--open` +
  exit 0; empty selection warns + exit 1; cancel exits 1 with no output; the exact
  status-line format; mouse documented as NOT yet functional.
- `docs/CONFIGURATION.md` contains a Known limitations section covering all of PRD §13
  (huge scrollback cap 50000 + truncation notice; alt-screen apps target normal screen
  + scrollback, `-a` is a future option; empty selection; wide chars/grapheme/emoji via
  ghostty-vt cell widths; OSC 8 → `<a>`; checksum/offline loud failure) plus the region
  deviations (mouse no-op; fixed-string search), and concurrent-run filename safety.
- `docs/CONFIGURATION.md` contains a sync-palette command section with the CORRECT exit
  behavior (exit 2 when `/dev/tty` cannot be opened; exit 0 + default-seeded cache +
  warning when the terminal is silent-but-open), and the dangling "see the
  sync-palette documentation" reference is gone (resolved to the new section).
- `docs/CONFIGURATION.md` contains an Attribution & license section (MIT, © 2026 Dustin
  Schultz; term2html © 2026 aarol; ghostty VT © 2024 Mitchell Hashimoto / Ghostty
  contributors; notices retained under `licenses/`), with working relative links.
- The existing Options table is unchanged and still matches the 8 shipped defaults.
- Accuracy gates pass: the doc does NOT claim regex/configurable search or working
  mouse; it DOES mention alt-screen, the scrollback cap, and both sync-palette exit
  outcomes.
- House-style gates pass: no banned marketing words, no hedging (em dashes are allowed
  — see gotcha). Markdown is well-formed; all relative links resolve.

## User Persona (if applicable)

**Target User**: a tmux-2html user who has the plugin installed (via the README) and now
wants the reference detail: every option's effect, how the region overlay's keys work,
how the palette is captured/cached, what the limits are, and what is licensed how.

**Use Case**: user pressed `prefix C-o`, is inside the region overlay, and wants the
full key reference (the in-app status line is terse); or user is scripting
`sync-palette`/`render --selection` and needs exact exit behavior; or user hit a
limitation (alt-screen app, truncated scrollback) and wants to confirm it is known.

**User Journey**: README (install + overview) → docs/CONFIGURATION.md (depth): Options →
Region overlay → Palette cache / sync-palette → Known limitations → Attribution.

**Pain Points Addressed**: the current docs/CONFIGURATION.md has NO region walkthrough,
NO limitations list, NO attribution, a dangling reference, and an imprecise
sync-palette story. Users currently have only the terse in-app status line and the PRD
(which over-claims mouse/regex). This task fills those gaps accurately.

## Why

- **The README (S1) links here for depth.** S1's README points to docs/CONFIGURATION.md
  for the full options reference, the palette cache, sync-palette behavior, the region
  key list, and (optionally) limitations. If docs/CONFIGURATION.md lacks that content,
  the README's links are empty promises. S2 is the task that fulfills them.
- **Honest docs prevent bug reports.** Stating the alt-screen limitation, the scrollback
  cap, the fixed-string-only search, and the not-yet-functional mouse up front prevents
  users filing bugs for documented non-goals / known v1 gaps (PRD §1.2, §13, §16).
- **The shipped behavior differs from the PRD in two user-visible places** (region
  search = fixed-string not regex; region mouse = no-op). The docs must reflect the
  SHIPPED code, not the PRD's intent — otherwise the docs lie. This is the core accuracy
  obligation of the task.
- **The dangling reference and the imprecise sync-palette exit story are real defects**
  in the current doc. Fixing them is explicitly in scope ("fix any drift between docs
  and actual flags/behavior").

## What

Edit `docs/CONFIGURATION.md` in place, producing these sections (order and content per
`research/design_notes.md` §2):

1. **Overview** (NEW, top of file). One short paragraph + an optional bullet list of
   what the doc covers (options, the region overlay, the palette cache, sync-palette,
   known limitations, attribution). Frames the doc as the reference.
2. **Options** (EXISTING). Verify the table + the `C-o` key-conflict note + "How options
   are read". Do NOT change the defaults (they match shipped code). No drift expected.
3. **The region overlay** (NEW). Full TUI walkthrough (see Implementation Tasks for the
   exact subsections and accuracy constraints).
4. **Palette cache** (EXISTING). Verify; FIX the dangling "see the sync-palette
   documentation for `--from` and `--force`" reference (point to the new sync-palette
   section or inline). Keep location/format/auto-sync/inside-vs-outside/consumed/hand-
   editing.
5. **The sync-palette command** (NEW). `--from tty|file PATH`, `--force`, and the
   CORRECT exit behavior (exit 2 on no controlling tty; exit 0 + default-seeded cache +
   warning on a silent-but-open terminal).
6. **Known limitations** (NEW). Full PRD §13 list + region deviations (see Tasks).
7. **Attribution & license** (NEW). PRD §14 (see Tasks).

### Success Criteria

- [ ] Region overlay section present and accurate (movement table, fixed-string search,
      selection keys, confirm/cancel, status-line format, full-scrollback browse).
- [ ] Region section does NOT claim regex/configurable search or working mouse; mouse is
      documented as not-yet-functional.
- [ ] Known limitations section covers all of PRD §13 + the two region deviations +
      concurrent-run filename safety.
- [ ] sync-palette section states BOTH exit outcomes correctly; the dangling reference
      is resolved.
- [ ] Attribution & license section present with working links to `LICENSE` and
      `licenses/*.txt`.
- [ ] Options table unchanged and correct; no invented flags anywhere.
- [ ] House-style gates pass (no marketing words, no hedging; em dashes allowed).
- [ ] Markdown well-formed; all relative links resolve.

## All Needed Context

### Context Completeness Check

_If someone knew nothing about this codebase, would they have everything needed to
implement this successfully?_ **YES.** This PRP embeds: the exact doc-structure
decision (expand, do not split, because the README hardcodes the docs/CONFIGURATION.md
link and S2 cannot edit the README); the full region TUI key/behavior fact sheet
(`region_tui_facts.md`) including the TWO places where shipped code differs from PRD §7
(fixed-string search; mouse no-op) and the exact status-line format string; the full
§13 edge-case verification + sync-palette/palette-cache fact sheet
(`edgecases_palette_facts.md`) including the sync-palette exit-behavior correction and
all verbatim user-facing messages; the house-style rule (match the existing
docs/CONFIGURATION.md — em dashes permitted, factual, no puffery, no hedging) with the
explicit gotcha that the README's stricter rule does NOT apply here; the sibling
boundaries (do not touch README.md; S1 owns it); and concrete, executable validation
gates (grep accuracy assertions, markdown/link checks, a drift check). An implementer
needs only this PRP + the three research files it references.

### Documentation & References

```yaml
# MUST READ — the region TUI fact sheet. Source of truth for every region claim.
# CRITICAL: it flags TWO deviations from PRD §7 the docs must reflect (fixed-string
# search; mouse no-op) and gives the exact status-line format string.
- docfile: plan/001_0c8587f91cb2/P4M2T1S2/research/region_tui_facts.md
  why: §1 movement key table + counts + the two-class WORD note; §2 search (fixed-string,
       case-sensitive, NOT regex/configurable); §3 selection keys + linewise/block
       output mapping; §4 confirm/cancel (Enter/y render + sidecar + --open + exit 0;
       empty selection warn + exit 1; q/Esc/Ctrl-c exit 1); §5 MOUSE IS A NO-OP (the
       §7.6 deviation); §6 the EXACT status-line format; §8 full-scrollback browse.
  critical: "do NOT claim regex search or working mouse; both are shipped deviations
             from PRD §7. Also ignore the STALE region.zig header comment that calls
             confirm a 'S1 STUB' — it is fully implemented."

# MUST READ — the §13 edge-case + sync-palette/palette fact sheet. Source of truth for
# the Known limitations + sync-palette sections.
- docfile: plan/001_0c8587f91cb2/P4M2T1S2/research/edgecases_palette_facts.md
  why: §1-7 every PRD §13 item SHIPPED with verbatim notices (scrollback cap +
       truncation notice text; wide-char atomicity via ghostty-vt; OSC8 -> <a>; empty
       selection two paths; alt-screen NOT captured, no -a; checksum/offline loud fail
       text; concurrent-run filename pattern); §8 sync-palette flags + the CORRECT exit
       behavior (exit 2 only on unopenable /dev/tty; silent-but-open -> exit 0 +
       default-seeded cache + warning) — this is the main accuracy fix; §9-11 palette
       cache format/location/XDG + auto-sync popup (50%x50%, non-fatal) + inside-vs-
       outside-tmux capture.
  critical: "do NOT claim a blanket 'timeout -> non-zero exit'. State BOTH outcomes.
             Attribute wide-char/OSC8 capability to ghostty-vt, not tmux-2html code.
             Do NOT document alt-screen capture (-a) as supported."

# MUST READ — the docs-author synthesis: structure decision, house style, accuracy
# corrections, sibling boundaries, the accuracy anchors, the validation approach.
- docfile: plan/001_0c8587f91cb2/P4M2T1S2/research/design_notes.md
  why: §2 why we EXPAND docs/CONFIGURATION.md (not split) — the README link contract;
       §3 house style (match existing doc; em dashes ALLOWED; the README rule does NOT
       apply); §4 region section content + accuracy; §5 sync-palette section + the
       dangling-reference fix; §6 limitations content; §7 attribution content;
       §8 sibling boundaries; §9 accuracy anchors; §10 validation.
  section: "all"

# The file being EDITED. Read it fully first; preserve its existing voice/structure.
- file: docs/CONFIGURATION.md
  why: the existing Options table + C-o key-conflict note + "How options are read" +
       Palette cache section (location/format/population/auto-sync/inside-vs-outside/
       consumed/hand-editing). Verify these; fix the dangling reference at line ~101-102.
  pattern: "H2 sections; bold for key terms; em dashes for asides; fenced tmux/text blocks"
  gotcha: "this doc ALREADY uses em dashes (9 occurrences). Match that style in new
           sections. Do NOT impose the README's no-em-dash rule here."

# The sibling README CONTRACT (being implemented in parallel). Read so the docs stay
# consistent with what the README promises/links. Do NOT edit it.
- docfile: plan/001_0c8587f91cb2/P4M2T1S1/PRP.md
  why: confirms the README links to docs/CONFIGURATION.md for options, palette cache,
       sync-palette behavior, the region key list, and (optionally) limitations — which
       is WHY the region/limits content must live in docs/CONFIGURATION.md. Also confirms
       the README has its own brief credits line (so the docs Attribution section is the
       deeper reference, not a duplicate).
  section: "Task 2 (section order), Integration Points, Sibling Boundaries"

# Verified option defaults + flags (the README's fact sheet). Use to confirm the Options
# table has zero drift and that any CLI flag mentioned in docs is real.
- docfile: plan/001_0c8587f91cb2/P4M2T1S1/research/shipped_facts.md
  why: §3 the per-subcommand flags (sync-palette --from/--force; region --target/--font/
       --output/--open; render --palette cached|live|default; pane --visible/--full/
       --history); §5 the 8 @tmux-2html-* defaults (must match the Options table
       verbatim); §7 exit codes 0/1/2.
  critical: "the Options table in docs/CONFIGURATION.md already matches §5 — do NOT
             change the defaults. Use §3 to verify any CLI flag the docs mention."

# License/attribution sources for the Attribution section (relative links must resolve).
- file: LICENSE
  why: project license = MIT, © 2026 Dustin Schultz.
- file: licenses/TERM2HTML.txt
  why: upstream term2html notice = MIT, © 2026 aarol. Retained per MIT.
- file: licenses/GHOSTTY-VT.txt
  why: upstream ghostty VT notice = MIT, © 2024 Mitchell Hashimoto, Ghostty contributors.

# The PRD sections named by the contract for CONTENT. Read for accuracy; the SHIPPED
# fact sheets override the PRD where they differ (region search; mouse; sync-palette exit).
- docfile: PRD.md
  why: §7 region TUI (intended design — but shipped differs per region_tui_facts.md);
       §13 edge cases (the limitations list); §14 licensing & attribution; §16 roadmap
       (alt-screen capture is out of v1 — supports the limitation wording).
  section: "7, 13, 14, 16"
  gotcha: "do NOT copy PRD §7.3 (regex) or §7.6 (mouse) verbatim — shipped code differs."
```

### Current Codebase tree (run `ls -la` at the repo root)

```bash
$ ls -la docs/
CONFIGURATION.md   # the ONLY docs file today (Mode A, P2.M2.T1.S1). THIS TASK expands it.
$ ls -la licenses/
GHOSTTY-VT.txt  TERM2HTML.txt  .gitkeep
$ ls LICENSE  # exists (MIT, © 2026 Dustin Schultz)
# README.md does NOT exist yet (sibling S1 creates it, in parallel — do NOT create/edit it here)
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
docs/CONFIGURATION.md   # EDITED (THIS TASK). Comprehensive reference: Overview, Options,
                        #   The region overlay, Palette cache, The sync-palette command,
                        #   Known limitations, Attribution & license.
```

`docs/CONFIGURATION.md` responsibilities after this task:
- Be the single depth target the README links to: full options reference, region TUI
  walkthrough, palette cache, sync-palette command, every known limitation, attribution.
- Match shipped behavior exactly (fact sheets) — no stale claims, no over-claims.
- Match the existing doc's factual, em-dash-permitting reference-manual voice.

### Known Gotchas of our codebase & Library Quirks

```yaml
# CRITICAL: the README (S1) and docs/CONFIGURATION.md use DIFFERENT style rules. The
# README is em-dash-free (a README-specific project rule). docs/CONFIGURATION.md ALREADY
# uses em dashes (9 occurrences). For the NEW sections, MATCH docs/CONFIGURATION.md
# (em dashes permitted, factual, bold for key terms). Do NOT try to remove the existing
# em dashes — that is out of scope and would churn the doc.

# CRITICAL: region search is FIXED-STRING and CASE-SENSITIVE (NOT regex, NOT
# configurable). PRD §7.3 says "regex or fixed-string, configurable" — that is NOT
# shipped (view.zig SearchMode = enum{fixed}; .regex reserved, unimplemented). Document
# fixed-string only. (region_tui_facts.md §2.)

# CRITICAL: region MOUSE is a NO-OP. PRD §7.6 says "Mouse (supported)" — but mouse is
# only enabled+decoded at the terminal layer; the TUI loop never acts on it
# (region.regionHandle has no mouse branch). Document mouse as NOT yet functional,
# under both the region section and Known limitations. Do NOT claim click/drag/wheel
# work. (region_tui_facts.md §5.)

# CRITICAL: sync-palette exit behavior is the main accuracy fix. It is NOT a blanket
# "exits non-zero on timeout." Exit 2 happens ONLY when /dev/tty cannot be opened (no
# controlling tty, e.g. run-shell). A tty that opens but stays silent exits 0 with a
# cache seeded from the bundled default palette and a warning (palette_received_count <
# 256). State BOTH outcomes. (edgecases_palette_facts.md §8.)

# CRITICAL: there is a DANGLING REFERENCE in the current doc (~line 101-102): "see the
# sync-palette documentation for --from and --force" — no such separate doc exists.
# Resolve it: point to the new "The sync-palette command" section (or inline the flags).

# CRITICAL: ignore the STALE region.zig header comment that calls the confirm flow a
# "S1 STUB". The confirm-render flow is FULLY implemented (renders + sidecar + --open +
# exit 0). Do NOT document region as a stub. (region_tui_facts.md §4.)

# NOTE: alt-screen capture (tmux capture-pane -a) is NOT shipped and is a future option.
# Do NOT document it as supported. Document that pane/region capture the normal screen +
# scrollback only. (edgecases_palette_facts.md §5.)

# NOTE: attribute wide-character / grapheme / emoji handling and OSC 8 hyperlink
# preservation to the ghostty VT engine (via the vendored ghostty_format.zig formatter),
# NOT to tmux-2html's own code. tmux-2html adds no custom width/hyperlink logic.

# NOTE: the auto-sync popup is -w 50% -h 50% (NOT 100%). The existing doc already says
# "roughly 50% x 50%" — that is accurate; keep it.

# NOTE: this is a documentation task. There is no test command. Validation is grep
# accuracy gates + markdown/link checks + a drift check (see Validation Loop).
```

## Implementation Blueprint

### Data models and structure

No code data models. The "data" is the two fact sheets: the region key/behavior table
and the §13/§9-11 verification table. The doc's Region overlay section is a direct
render of `region_tui_facts.md`; the Known limitations section is a direct render of
`edgecases_palette_facts.md` §1-7 + the region deviations; the sync-palette section is
a direct render of `edgecases_palette_facts.md` §8.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: READ the three research files + the reference files (do this FIRST)
  - READ research/region_tui_facts.md (the region truth — note the TWO deviations:
    fixed-string search; mouse no-op).
  - READ research/edgecases_palette_facts.md (the §13 + sync-palette/palette truth —
    note the sync-palette exit-behavior correction).
  - READ research/design_notes.md (structure decision + house style + accuracy fixes).
  - READ docs/CONFIGURATION.md fully (the file you are editing; note its voice, its em
    dashes, and the dangling sync-palette reference at ~line 101-102).
  - SKIM P4M2T1S1/PRP.md (the README contract — what links here) and
    P4M2T1S1/research/shipped_facts.md §3/§5 (flags + option defaults for the drift
    check).
  - SKIM PRD.md §7/§13/§14/§16 for content; the fact sheets OVERRIDE the PRD where they
    differ (region search, mouse, sync-palette exit).
  - GOAL: write reference prose from the fact sheets; where you reuse PRD/CONFIGURATION
    sentences, keep them factual (em dashes are fine in this doc).

Task 2: ADD the "Overview" section at the TOP of docs/CONFIGURATION.md
  - One short paragraph: docs/CONFIGURATION.md is the reference for configuring and using
    tmux-2html (options, the region overlay, the palette cache, sync-palette, known
    limits, licensing). Optionally a 4-6 bullet list of the sections.
  - NAMING/PLACEMENT: H2 "## Overview" as the first section (after the H1 "# ..."). If
    the H1 is currently "# Configuration", you may keep it or broaden it to e.g.
    "# tmux-2html configuration & reference" (your call; keep it simple).

Task 3: VERIFY the existing "Options" section (no edits unless drift found)
  - CONFIRM the 8-option table matches shipped_facts §5 (full-key=O, region-key=C-o,
    visible-key=(empty), output-dir=${XDG_DATA_HOME:-~/.local/share}/tmux-2html, open=on,
    font=monospace, history-limit=50000, binary-dir=$TMUX_2HTML_BIN). It already does.
  - KEEP the C-o key-conflict note and the "How options are read" subsection as-is.
  - DO NOT change defaults or invent flags.

Task 4: ADD the "The region overlay" section (the largest new section)
  - LEAD: launched by prefix C-o (@tmux-2html-region-key), which opens a full-screen
    tmux display-popup running `tmux-2html region`. It captures the FULL scrollback
    first (honoring @tmux-2html-history-limit), so you browse all history; the overlay
    opens at the bottom (like tmux copy-mode). Confirm renders the selection to HTML;
    cancel exits with no output.
  - SUBSECTION "What you see": the captured grid in full color + a status line. Give the
    EXACT status-line format from region_tui_facts.md §6:
      [LINE|BLOCK]  row:N col:M  /pattern  N match(es)  <S-sel>  Enter=render q=quit
    Note: the [LINE]/[BLOCK] tag is omitted when nothing is selected; the /pattern token
    appears only with an active search; <S-sel> appears only with a selection.
  - SUBSECTION "Movement": a compact table — h j k l + arrows; w b e; 0 ^ $; gg / G;
    Ctrl-d/u half-page; Ctrl-f/b (or PgUp/PgDn) full-page; H M L; { } paragraph; %
    matching bracket. Note counts work (e.g. 5j). One-line note: word motions use a
    two-class WORD model (a word is a run of non-whitespace, like vim W/B/E), so
    foo.bar is one word.
  - SUBSECTION "Search": / forward, ? backward, n / N next/prev (wrap around). STATE
    PLAINLY: search is fixed-string and case-sensitive — not regex, not configurable.
    Matches are highlighted in reverse video. (Mention Esc cancels a half-typed pattern.)
  - SUBSECTION "Selection": v begins a linewise selection at the cursor; v again toggles
    linewise <-> block. V forces linewise; Ctrl-v (or R) forces block. o swaps the
    cursor to the other end (in v1 O does the same). Movement extends the selection.
    Esc clears the selection and stays in the overlay.
  - SUBSECTION "Confirm and cancel": Enter (or y) renders the current selection to an
    HTML file, writes a .last-output sidecar (so the plugin can flash the path), honors
    @tmux-2html-open, and exits 0. Confirming with no selection warns and exits 1 with
    no file. q / Esc (no selection) / Ctrl-c cancel with no output (exit 1).
  - SUBSECTION or NOTE "Mouse": mouse input is recognized by the terminal but is not yet
    wired into the overlay, so click, drag, and wheel have no effect in v1.
  - FOLLOW pattern: the existing doc's H2/H3 + table + bold style.
  - GOTCHA: do NOT claim regex/configurable search or working mouse.

Task 5: VERIFY the existing "Palette cache" section + FIX the dangling reference
  - CONFIRM location (${XDG_CACHE_HOME:-$HOME/.cache}/tmux-2html/palette), the plain-
    text format (header comment + fg/bg + 0..255), the XDG rule (honored only if set +
    non-empty + absolute), auto-sync popup (50%x50%, non-fatal), inside-vs-outside-tmux
    capture, the consume precedence (cached -> live -> default), hand-editing tolerance.
    All accurate per edgecases_palette_facts.md §9-11.
  - FIX the dangling reference (~line 101-102): change "via tmux-2html sync-palette (see
    the sync-palette documentation for --from and --force)" to point at the new "The
    sync-palette command" section (e.g. "via tmux-2html sync-palette — see The sync-
    palette command below for --from and --force") or inline the two flags.

Task 6: ADD the "The sync-palette command" section
  - DOCUMENT --from tty (default; queries OSC 4/10/11 against /dev/tty) and
    --from file PATH (seed the cache from a palette file instead).
  - DOCUMENT --force (re-query even when a cache already exists).
  - STATE THE CORRECT EXIT BEHAVIOR (the main accuracy fix): exit 2 if there is no
    controlling tty (/dev/tty cannot be opened — e.g. under tmux run-shell); if the tty
    opens but the terminal does not answer within the ~500 ms timeout, exit 0 with a
    cache seeded from the bundled default palette and a logged count of how many of 256
    entries were received. Do NOT claim a blanket "exits non-zero on timeout."
  - ONE-LINE pointer back to the Palette cache section for location/format.
  - GOTCHA: this is where the PRD's "exits non-zero on timeout" is only half true —
    state both outcomes precisely (edgecases_palette_facts.md §8).

Task 7: ADD the "Known limitations" section (full PRD §13 + region deviations)
  - A tight bulleted list, each item one or two sentences. Cover:
    * Huge scrollback — capped at @tmux-2html-history-limit (default 50000); when
      truncated, a notice is printed (and shown on the tmux status line when a client
      exists). (verbatim notice optional.)
    * Alternate-screen apps (nvim, less) — capture targets the normal screen + scrollback
      only (tmux capture-pane without -a); the live alt-screen UI is not captured.
      Alt-screen capture is a future option.
    * Empty selection — confirming an empty selection warns and writes no file (exit 1).
    * Wide characters / grapheme clusters / emoji — handled by the ghostty VT engine's
      cell widths; selection rounds to cell boundaries so a wide cell is selected as a
      unit.
    * OSC 8 hyperlinks — preserved and become <a> links in the HTML (via ghostty-vt).
    * Binary acquisition failures (checksum mismatch / offline) — the download fails
      loudly with an instruction to install Zig and rebuild, or place a binary manually.
    * Region overlay: mouse is not yet functional (input is recognized but click/drag/
      wheel have no effect in v1).
    * Region overlay: search is fixed-string, case-sensitive (no regex, not configurable).
    * (Optional) Concurrent runs — output filenames include session + timestamp + pid,
      so parallel captures do not collide.
  - GOTCHA: attribute wide-char/OSC8 to ghostty-vt; do NOT document -a as supported.

Task 8: ADD the "Attribution & license" section (PRD §14)
  - tmux-2html is MIT-licensed (LICENSE), © 2026 Dustin Schultz.
  - It absorbs term2html's rendering logic (MIT, © 2026 aarol); upstream notice retained
    at licenses/TERM2HTML.txt.
  - It depends on the ghostty VT engine (MIT, © 2024 Mitchell Hashimoto, Ghostty
    contributors); upstream notice retained at licenses/GHOSTTY-VT.txt.
  - No proprietary code. The README credits both upstreams.
  - USE relative links: [LICENSE](../LICENSE) or [LICENSE](LICENSE) depending on how the
    existing doc references repo-root files (check existing link style; docs/ is one
    level down, so ../LICENSE / ../licenses/TERM2HTML.txt). Verify they resolve.

Task 9: SELF-AUDIT (Validation Levels 1-3) and fix before considering the task done
  - RUN the house-style greps (marketing words, hedging) -> fix any hits.
  - RUN the accuracy greps (must NOT claim regex/mouse; MUST mention alt-screen,
    scrollback cap, both sync-palette exit outcomes).
  - RUN the link check (LICENSE, licenses/*.txt resolve; any internal anchors work).
  - RUN the drift check (options table still matches the 8 shipped defaults).
```

### Implementation Patterns & Key Details

```markdown
<!-- Status-line format (quote it exactly in the region section): -->
[LINE|BLOCK]  row:N col:M  /pattern  N match(es)  <S-sel>  Enter=render q=quit
<!-- mode tag omitted with no selection; /pattern only with a pattern; <S-sel> only with
     a selection. -->

<!-- Movement table shape (compact): -->
| Key | Action |
|---|---|
| `h j k l`, arrows | move one cell |
| `w b e` | next/previous word, end of word (two-class WORD) |
| `0` `^` `$` | line start / first non-blank / line end |
| `gg` / `G` | top / bottom of scrollback |
| `Ctrl-d` / `Ctrl-u` | half-page down / up |
| `Ctrl-f` / `Ctrl-b` (PgDn / PgUp) | full-page down / up |
| `H` `M` `L` | viewport top / middle / bottom |
| `{` `}` | previous / next blank line |
| `%` | matching bracket |
Counts work (e.g. `5j`).

<!-- ACCURACY in action (the two deviations): -->
# GOOD: "Search is fixed-string and case-sensitive. Type /pattern, then Enter; n / N
#        jump between matches. (Regex search is not supported in v1.)"
# BAD:  "Search supports regex or fixed-string, configurable."   # NOT shipped

# GOOD: "Mouse input is recognized but not yet wired into the overlay; click, drag, and
#        wheel have no effect in v1."
# BAD:  "Mouse is supported: click to move, drag to select, wheel to scroll."  # NOT shipped

<!-- sync-palette exit accuracy: -->
# GOOD: "sync-palette exits 2 if there is no controlling terminal (e.g. under tmux
#        run-shell). If the terminal opens but does not respond within the timeout, it
#        exits 0 with a cache seeded from the default palette and a warning."
# BAD:  "sync-palette exits non-zero if the terminal does not respond within the timeout."
#       # only half true — do NOT use this blanket form.
```

### Integration Points

```yaml
FILES REFERENCED BY THE DOC (must exist; do not create/modify them):
  - LICENSE                  # MIT, © 2026 Dustin Schultz. LINK target (../LICENSE).
  - licenses/TERM2HTML.txt   # term2html (aarol) MIT notice. LINK target.
  - licenses/GHOSTTY-VT.txt  # ghostty VT (Hashimoto / contributors) MIT notice. LINK target.
  - README.md                # created by sibling S1 (parallel). The doc may reference it
                             #   for install/overview, but README.md is owned by S1.
SIBLING BOUNDARIES (do not cross):
  - S1 (README.md) owns the README and links to docs/CONFIGURATION.md for region keys,
    options, palette, sync-palette, and (optionally) limits. Therfore region/limits/
    sync-palette content MUST live in docs/CONFIGURATION.md (expand, do not split into
    separate files). Do NOT create or edit README.md.
  - S1 also has a brief credits line; the docs Attribution section is the deeper
    reference (no duplication conflict).
  - P4.M1.T1.S2 (ci.yml) is parallel and unrelated to docs content.
```

## Validation Loop

> **NOTE**: this is a documentation task. There is no test command. Validation is
> (1) house-style greps, (2) accuracy greps (the core obligation), (3) markdown/link
> checks, (4) a drift check. All are mandatory.

### Level 1: House-style gates (run after editing)

```bash
# (a) NO marketing tell-words. MUST print nothing (review any literal-technical use).
grep -niE '\b(seamless|seamlessly|powerful|robust|blazing|easy|easily|simply|amazing|beautiful|leverage|cutting-edge|intuitive)\b' docs/CONFIGURATION.md \
  && echo "FAIL: review marketing words" || echo "OK: no marketing words"

# (b) NO hedging. MUST print nothing (genuine conditionals like "if the terminal is
#     silent" are fine; "might/probably" as vague hedging are not).
grep -niE '\b(might|probably)\b' docs/CONFIGURATION.md \
  && echo "FAIL: review hedging" || echo "OK: no hedging"

# (c) Em dashes ARE allowed in docs/CONFIGURATION.md (match existing style). This is a
#     NON-gate here — run it only to confirm consistency, NOT to enforce removal:
grep -cP '\x{2014}' docs/CONFIGURATION.md   # informational only; do NOT zero this out
# Expected: >= 0 (em dashes permitted). Do NOT treat a non-zero count as a failure.

# Expected (a) and (b): "OK: ...". Fix any hit by rephrasing. (c) is informational.
```

### Level 2: Accuracy gates (the CORE obligation — run and assert)

```bash
# (a) MUST mention alt-screen as a limitation:
grep -niE 'alt(ernate)?[- ]screen' docs/CONFIGURATION.md && echo "OK" || echo "FAIL: no alt-screen"

# (b) MUST mention the scrollback cap (50000):
grep -niE 'history-limit|50000|scrollback' docs/CONFIGURATION.md && echo "OK" || echo "FAIL: no scrollback cap"

# (c) MUST state both sync-palette exit outcomes (exit 2 on no tty; exit 0 + default on silent):
grep -niE 'exit 2|no controlling|/dev/tty' docs/CONFIGURATION.md && echo "OK" || echo "FAIL: no sync exit-2"
grep -niE 'default.*palette|seeded|silent|does not respond' docs/CONFIGURATION.md && echo "OK" || echo "FAIL: no silent-terminal outcome"

# (d) MUST NOT claim regex/configurable search (the §7.3 deviation):
grep -niE 'regex|regular expression|configurable search|ignore.?case' docs/CONFIGURATION.md \
  && echo "FAIL: review regex claim (search is fixed-string only)" || echo "OK: no regex claim"

# (e) MUST NOT claim working mouse (the §7.6 deviation). Allow "not yet"/"no effect":
grep -niE 'mouse' docs/CONFIGURATION.md | grep -viE 'not yet|no effect|not.*wir|recogni|no-op|no op|not functional' \
  && echo "FAIL: review mouse claim (mouse is a no-op in v1)" || echo "OK: no working-mouse claim"

# (f) The dangling reference MUST be gone:
grep -n 'sync-palette documentation' docs/CONFIGURATION.md \
  && echo "FAIL: dangling reference still present" || echo "OK: dangling reference resolved"

# Expected: (a)(b)(c)(d-OK)(e-OK)(f-OK) all hold. Fix the doc to match the fact sheets.
```

### Level 3: Markdown + link integrity

```bash
# (a) Markdown lint (best-effort):
#   markdownlint docs/CONFIGURATION.md   # npm i -g markdownlint-cli
#   mdformat --check docs/CONFIGURATION.md
# If neither is available, do a manual eyeball: headings nest, fences close, every table
# has a header + separator row, no broken internal anchors. Expected: zero errors.

# (b) Relative links resolve (all MUST exist):
for f in LICENSE licenses/TERM2HTML.txt licenses/GHOSTTY-VT.txt; do
  [ -f "$f" ] && echo "OK: $f" || echo "MISSING: $f"
done
# Also check the doc's links use the right relative path from docs/ (../LICENSE etc.):
grep -oE '\]\([^)]+\)' docs/CONFIGURATION.md | sort -u

# (c) Section structure sanity — the new H2s are present:
grep -nE '^## ' docs/CONFIGURATION.md
# Expected to include: Overview, Options, The region overlay, Palette cache,
#   The sync-palette command, Known limitations, Attribution & license (names may vary
#   slightly). Confirm each exists.
```

### Level 4: Drift check + read-through (manual)

```bash
# (a) Options table drift: the 8 defaults still match shipped code.
for o in full-key region-key visible-key output-dir open font history-limit binary-dir; do
  grep -q "@tmux-2html-$o" docs/CONFIGURATION.md && echo "OK: $o" || echo "MISSING: $o"
done
# Confirm defaults unchanged: O / C-o / (empty) / ... / 50000 (see shipped_facts §5).

# (b) Any CLI flag mentioned in the doc is real (no invented flags):
grep -oE '\-\-[a-z-]+' docs/CONFIGURATION.md | sort -u
# Cross-check against shipped_facts §3 (render/pane/region/sync-palette flags).

# (c) Read the doc end to end (GitHub render or glow/mdcat). Confirm a user could learn
#     the region keys, the limits, and the sync-palette behavior from it alone, and that
#     nothing contradicts the in-app status line or the shipped --help text.
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1 house-style gates pass (no marketing words, no hedging; em dashes allowed).
- [ ] Level 2 accuracy gates pass: alt-screen + scrollback cap mentioned; both
      sync-palette exit outcomes stated; NO regex/configurable-search claim; NO
      working-mouse claim; dangling reference resolved.
- [ ] Level 3: Markdown well-formed; all relative links resolve; the 7 H2 sections exist.
- [ ] Level 4: options table has zero drift; no invented CLI flags.

### Feature Validation

- [ ] Region overlay section accurate (movement + counts; fixed-string case-sensitive
      search; selection keys; confirm/cancel + sidecar + --open; status-line format;
      full-scrollback browse).
- [ ] Known limitations section covers all of PRD §13 + the two region deviations +
      concurrent-run filename safety.
- [ ] sync-palette section states both exit outcomes correctly; `--from`/`--force` documented.
- [ ] Attribution & license section present with working links to `LICENSE` and
      `licenses/*.txt`.
- [ ] Overview section present and frames the doc.
- [ ] Options + Palette cache sections verified (no regressions; dangling reference fixed).

### Code Quality Validation

- [ ] New sections match the existing docs/CONFIGURATION.md voice (factual, reference-
      manual, em-dash-permitting, bold for key terms).
- [ ] No content duplicated from the README (docs = depth; README = overview).
- [ ] Scope respected: only docs/CONFIGURATION.md edited; no source/build/script changes.

### Documentation & Deployment

- [ ] A user can learn the region keys, the limits, and sync-palette behavior from this
      doc alone.
- [ ] No stale claims (region stub, regex search, working mouse, blanket timeout-exit,
      alt-screen `-a` supported).
- [ ] No edits to any file other than docs/CONFIGURATION.md.

---

## Anti-Patterns to Avoid

- ❌ Don't claim region search is regex or configurable — it is fixed-string and
  case-sensitive (PRD §7.3 is NOT shipped; trust `region_tui_facts.md` §2).
- ❌ Don't claim region mouse works (click/drag/wheel) — it is recognized but a no-op in
  v1 (PRD §7.6 is NOT shipped; trust `region_tui_facts.md` §5).
- ❌ Don't claim a blanket "sync-palette exits non-zero on timeout" — exit 2 only when
  /dev/tty is unopenable; a silent-but-open terminal exits 0 with a default-seeded cache
  + warning (trust `edgecases_palette_facts.md` §8).
- ❌ Don't document alt-screen capture (`tmux capture-pane -a`) as supported — it is not
  shipped; it is a future option (`edgecases_palette_facts.md` §5).
- ❌ Don't split the region/limits content into separate docs files — the README (S1)
  hardcodes docs/CONFIGURATION.md as the link target, and S2 cannot edit the README.
  Expand docs/CONFIGURATION.md instead.
- ❌ Don't impose the README's no-em-dash rule on docs/CONFIGURATION.md — the existing
  doc uses em dashes; match it. (Don't churn the existing em dashes either.)
- ❌ Don't call region a stub or cite the stale `region.zig` header comment — the confirm
  flow is fully implemented (`region_tui_facts.md` §4).
- ❌ Don't invent flags or change option defaults — the Options table already matches
  shipped code (`shipped_facts.md` §5); verify, don't mutate.
- ❌ Don't edit README.md, PRD.md, source, build, or scripts — the ONE deliverable is the
  edited docs/CONFIGURATION.md.
- ❌ Don't leave the dangling "see the sync-palette documentation" reference — resolve it
  to the new sync-palette section.

---

## Confidence Score

**9/10** — The deliverable is a SINGLE edited file (`docs/CONFIGURATION.md`) whose every
factual claim is anchored to two VERIFIED fact sheets produced by reading the actual
shipped source: `region_tui_facts.md` (every region key/behavior, the exact status-line
format string, and the TWO shipped deviations from PRD §7 — fixed-string search and
no-op mouse — each with file:line evidence) and `edgecases_palette_facts.md` (every PRD
§13 item verified SHIPPED with verbatim user-facing messages, plus the
sync-palette/palette-cache behavior and the exit-behavior correction). The structure
decision (expand docs/CONFIGURATION.md, do not split) is forced by the sibling README
contract (S1 hardcodes the docs/CONFIGURATION.md link; S2 cannot edit the README), so
there is no ambiguity about where content lives. The house-style rule (match the existing
doc — em dashes permitted — NOT the README's stricter rule) is explicit and grounded in
the existing doc's actual style. The core accuracy obligation is encoded as concrete grep
gates (Level 2): the doc must NOT claim regex/mouse and MUST state both sync-palette exit
outcomes, the alt-screen limit, and the scrollback cap. The dangling-reference fix and
the drift check are explicit. The sibling boundaries are clean (S1 owns README; S2 owns
docs; P4.M1.T1.S2 is unrelated). Validation is grep + markdown/link checks + a drift
check — all defined as executable commands.

Residual risks (all low): (1) Markdown linters may not be installed — mitigated by the
manual eyeball checklist + the grep-based accuracy/drift gates, which catch the
substantive errors. (2) The accuracy grep for "mouse" (Level 2e) can false-positive on a
legitimate phrase like "mouse input is recognized" — mitigated by the allow-list
(`not yet|no effect|not.*wir|recogni|no-op`) and the "review" rather than blind-fail
instruction. (3) The cross-doc style difference (README em-dash-free, docs em-dash-permitting)
is intentional and documented; an implementer who mechanically applies the README rule
would needlessly churn the doc — mitigated by the explicit "em dashes ARE permitted /
do NOT impose the README rule" guidance in three places. (4) The H1 title ("Configuration"
vs a broader title) is left to the implementer's judgment with a keep-it-simple nudge,
since the doc's scope legitimately broadens — low risk because the section H2s carry the
structure.
