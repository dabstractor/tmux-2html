# Design notes — docs/ overview sweep (P4.M2.T1.S2)

Synthesis of the two fact sheets + the existing docs/CONFIGURATION.md + the sibling
S1 README contract into concrete decisions for the docs implementer. Read FIRST.

## 1. What this task IS and IS NOT

**IS:** the "Mode B" cross-cutting docs sweep (contract). The single deliverable is
EXPANDING `docs/CONFIGURATION.md` (the "Mode A" options reference created in
P2.M2.T1.S1) into the project's comprehensive reference doc, by ADDING whole-changeset
sections and FIXING drift. The contract names four additions:
1. a coherent top-level overview,
2. a region TUI usage walkthrough,
3. the full edge-case/limits list (PRD §13),
4. attribution/licensing (PRD §14);
plus verifying the sync-palette in-vs-out-of-tmux content and fixing flag drift.

**IS NOT:** this task does NOT touch `README.md` (sibling S1 owns it, in parallel),
does NOT touch any source/build/script, does NOT edit PRD.md or tasks.json. It writes
ONLY to `docs/` (primarily `docs/CONFIGURATION.md`).

## 2. Doc-structure decision: EXPAND docs/CONFIGURATION.md (do NOT split)

Rationale: the sibling README (S1) hardcodes `docs/CONFIGURATION.md` as its single
deep-doc pointer. From the S1 PRP:
- region section: "Point to docs/CONFIGURATION.md + the in-app status line for the full key list."
- config section: "See docs/CONFIGURATION.md for the full options reference, the palette cache, and sync-palette behavior."
- limitations: "Optionally one line linking the rest to docs/CONFIGURATION.md."

Because S1 is in parallel and S2 cannot edit the README, splitting the region/limits
content into separate files (e.g. docs/REGION.md) would break the README's links.
Therfore the region walkthrough, the limitations list, and the attribution section all
go INTO docs/CONFIGURATION.md. The doc grows into "the reference"; that is intended.

Target section order for the expanded docs/CONFIGURATION.md:
1. **Overview** (NEW brief intro — one short paragraph framing the doc as the reference
   for configuration, the region overlay, the palette cache, sync-palette, known limits,
   and licensing). Possibly a small bullet list of what is covered.
2. **Options** (EXISTING — verify; keep the table + the C-o key-conflict note + the
   "how options are read" subsection).
3. **The region overlay** (NEW — the full TUI walkthrough; see §4 below).
4. **Palette cache** (EXISTING — verify; fix the dangling sync-palette reference in the
   "How it is populated" subsection; keep location/format/auto-sync/inside-vs-outside/
   consumed/hand-editing).
5. **The sync-palette command** (NEW section — or fold into Palette cache; document
   `--from tty|file PATH`, `--force`, and the CORRECT exit behavior; see §5 below).
6. **Known limitations** (NEW — the full PRD §13 list + the region deviations; see §6).
7. **Attribution & license** (NEW — PRD §14; see §7).

Use clear H2 headings. Existing H2s (Options, Palette cache) stay; new H2s are added.
Internal cross-links (e.g. the region section linking to sync-palette) are encouraged.

## 3. House style — MATCH the existing docs/CONFIGURATION.md (em dashes ALLOWED)

The existing docs/CONFIGURATION.md ALREADY uses em dashes (U+2014, `—`) — 9 occurrences
— and bold for emphasis. The sibling README (S1) imposes a strict no-em-dash /
no-marketing-words rule, but that rule is README-specific. For the docs, the governing
principle is CONSISTENCY with the existing docs/CONFIGURATION.md:

- **Em dashes (U+2014) ARE permitted** in docs/CONFIGURATION.md (match existing style).
  Do NOT impose the README's no-em-dash rule here.
- **Factual, no puffery.** Avoid marketing tell-words (seamless, powerful, robust,
  blazing, easy, simply, just, amazing, beautiful, leverage, cutting-edge, intuitive).
  This is good technical writing, not a README gate.
- **No hedging.** Behavior is deterministic; state it directly. Drop might/probably
  (except where a genuine conditional like "if the terminal is silent" applies).
- **Bold** for key terms / UI hints is consistent with the existing doc; use sparingly.
- **Voice:** terse, reference-manual tone (like the existing Options section).

Because the existing doc uses em dashes and the new sections will too, the doc stays
internally consistent. The README being em-dash-free is a separate, accepted
cross-doc difference (do NOT try to "fix" the existing em dashes — that is out of scope
and would churn the doc).

## 4. Region overlay section — content & accuracy (from region_tui_facts.md)

Add an H2 "The region overlay" with subsections. Lead with: launched by `prefix C-o`
(the `@tmux-2html-region-key`), which opens a full-screen `tmux display-popup` running
`tmux-2html region`. It captures the FULL scrollback first, so you browse all history
(the TUI enters at the bottom, like tmux copy-mode). On confirm it renders the
selection to HTML; on cancel it exits with no output.

Subsections:
- **What you see** — the captured grid in full color, plus a status line. Give the
  exact status-line format from the fact sheet (`[LINE|BLOCK]  row:N col:M  /pattern
  N match(es)  <S-sel>  Enter=render q=quit`), noting the mode tag is omitted with no
  selection, the search token only appears with a pattern, and `<S-sel>` only with a
  selection.
- **Movement** — a compact table: `h j k l` / arrows; `w b e`; `0 ^ $`; `gg` / `G`;
  `Ctrl-d/u` half-page; `Ctrl-f/b` (or PgUp/PgDn) full-page; `H M L`; `{ }`; `%`.
  Note counts work (e.g. `5j`). Optional one-line note: word motions use a two-class
  WORD model (a "word" is a run of non-whitespace, like vim `W`/`B`/`E`), so `foo.bar`
  is one word.
- **Search** — `/` forward, `?` backward, `n` / `N` next/prev (wrap around). STATE
  PLAINLY: search is **fixed-string and case-sensitive** (not regex, not configurable).
  Matches are highlighted in reverse video.
- **Selection** — `v` begins a linewise selection at the cursor; pressing `v` again
  toggles linewise ↔ block. `V` forces linewise; `Ctrl-v` (or `R`) forces block.
  `o` swaps the cursor to the other end (in v1 `O` does the same). Movement extends
  the selection. `Esc` clears the selection (and stays in the overlay); `Esc` with no
  selection, or `q`, quits.
- **Confirm and cancel** — `Enter` (or `y`) renders the current selection to an HTML
  file (writes a `.last-output` sidecar so the plugin can flash the path; honors
  `@tmux-2html-open`) and exits 0. Confirming with no selection warns and exits 1 with
  no file. `q` / `Esc` (no selection) / `Ctrl-c` cancel with no output (exit 1).
- **A note on mouse** (be honest): mouse input is recognized by the terminal but is not
  yet wired into the overlay, so click/drag/wheel do nothing in v1. (This is the §7.6
  deviation — document it under Known limitations too; do NOT claim mouse works.)

Accuracy gates (Validation): the section must NOT claim regex search, configurable
search, or working mouse.

## 5. sync-palette section + fixing the dangling reference — accuracy (from edgecases_palette_facts.md §8)

Two things to do:
1. **Fix the dangling reference.** The existing "How it is populated" subsection says:
   *"via `tmux-2html sync-palette` (see the sync-palette documentation for `--from` and
   `--force`)"* — but no separate sync-palette doc exists. Replace that parenthetical
   with a pointer to the new sync-palette section (or inline the flags there).
2. **Add a "The sync-palette command" section** documenting:
   - `--from tty` (default) queries OSC 4/10/11 against `/dev/tty`; `--from file PATH`
     seeds the cache from a palette file instead.
   - `--force` re-queries even when a cache already exists.
   - **The CORRECT exit behavior** (the main accuracy fix): exit 2 if there is no
     controlling tty (`/dev/tty` cannot be opened — e.g. under `tmux run-shell`); if the
     tty opens but the terminal does not answer within the ~500 ms timeout, it exits 0
     with a cache seeded from the bundled default palette and logs how many of 256
     entries were received. Do NOT claim a blanket "exits non-zero on timeout."
   - A one-line pointer back to the Palette cache section for location/format.

## 6. Known limitations section — content (from edgecases_palette_facts.md §1-7 + region deviations)

Add an H2 "Known limitations" listing, as a tight bulleted list (each item one or two
sentences). Cover all of PRD §13, with the shipped nuance where relevant:
- **Huge scrollback** — capture is capped at `@tmux-2html-history-limit` (default 50000);
  when truncated, a notice is printed (and shown on the tmux status line when a client
  exists).
- **Alternate-screen apps (nvim, less)** — capture targets the normal screen +
  scrollback only (`tmux capture-pane` without `-a`); the live alt-screen UI is not
  captured. Alt-screen capture is a future option.
- **Empty selection** — confirming an empty selection warns and writes no file (exit 1).
- **Wide characters, grapheme clusters, emoji** — handled by the ghostty VT engine's
  cell widths; selection rounds to cell boundaries so a wide cell is selected as a unit.
- **OSC 8 hyperlinks** — preserved and become `<a>` links in the HTML (via ghostty-vt).
- **Binary acquisition failures (checksum mismatch / offline)** — the download fails
  loudly with an instruction to install Zig and rebuild, or place a binary manually.
- **Region overlay: mouse is not yet functional** — input is recognized but click,
  drag, and wheel have no effect in v1.
- **Region overlay: search is fixed-string, case-sensitive** — no regex, not configurable.
- (Optional) **Concurrent runs** — output filenames include the session name, a
  timestamp, and the pid, so parallel captures do not collide.

Attribute wide-char/OSC8 capability to ghostty-vt (via the vendored formatter), not to
tmux-2html's own code. Do NOT document alt-screen capture (`-a`) as supported.

## 7. Attribution & license section — content (PRD §14)

Add an H2 "Attribution & license". Keep it factual and slightly deeper than the
README's credits line (the README has the brief version; this is the reference). State:
- tmux-2html is MIT-licensed (`LICENSE`), © 2026 Dustin Schultz.
- It absorbs term2html's rendering logic (MIT, © 2026 aarol); the upstream notice is
  retained at `licenses/TERM2HTML.txt`.
- It depends on the ghostty VT engine (MIT, © 2024 Mitchell Hashimoto, Ghostty
  contributors); the upstream notice is retained at `licenses/GHOSTTY-VT.txt`.
- No proprietary code. The README credits both upstreams.

Point at `LICENSE` and the two `licenses/*.txt` files (relative links must resolve).

## 8. Sibling boundaries (do not cross)

- **S1 (README.md):** S1 owns the README and is being implemented in parallel. Do NOT
  create or edit README.md. The README will link to docs/CONFIGURATION.md for region
  keys, options, palette, sync-palette, and (optionally) limits — so the content the
  README points to MUST live in docs/CONFIGURATION.md (this is why we expand, not split).
- **S1 also owns a brief credits line** in the README; S2's Attribution section is the
  deeper reference. No conflict (README = brief, docs = depth). Do not duplicate the
  README's TPM install snippet or keybind summary — those are README concerns; docs
  should reference behavior, not re-explain installation.
- **P4.M1.T1.S2 (ci.yml):** parallel and unrelated to docs content.

## 9. Accuracy anchors (do not drift)

- Region keys/behavior: region_tui_facts.md (fixed-string search; mouse NOT wired;
  counts work; full scrollback browsed; status-line format exact).
- §13 edge cases: edgecases_palette_facts.md §1-7 (all SHIPPED with the noted nuances).
- sync-palette exit behavior: edgecases_palette_facts.md §8 (exit 2 only on unopenable
  tty; silent-but-open ⇒ exit 0 + default-seeded cache + warning).
- Options table defaults: already correct in docs/CONFIGURATION.md (match
  P4M2T1S1/research/shipped_facts.md §5: full-key=O, region-key=C-o, visible-key=(empty),
  open=on, font=monospace, history-limit=50000, output-dir=${XDG_DATA_HOME:-~/.local/share}/tmux-2html,
  binary-dir=$TMUX_2HTML_BIN). Do NOT change them.
- Auto-sync popup size: `-w 50% -h 50%` (the existing doc already says "roughly 50% ×
  50%" — that is accurate; keep it).

## 10. Validation approach (no test framework for docs)

- Markdown well-formedness: headings nest, fences close, tables have header + separator.
- Link check: every relative link resolves (`LICENSE`, `licenses/TERM2HTML.txt`,
  `licenses/GHOSTTY-VT.txt`, `README.md` only if referenced). Internal anchor links work.
- Accuracy gates (grep): the doc must NOT claim regex search, configurable search, or
  working mouse; it MUST mention the alt-screen limitation, the scrollback cap, the
  sync-palette exit-2-on-no-tty behavior, and the default-seeded-cache-on-silent behavior.
- Drift gate: the options table still matches the 8 shipped defaults; no invented flags.
- Consistency: new sections match the existing factual, em-dash-permitting style.
