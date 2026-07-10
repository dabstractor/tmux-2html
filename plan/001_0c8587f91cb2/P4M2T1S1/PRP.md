name: "P4.M2.T1.S1 — README.md: install, modes, keybinds, options summary, credits"
description: |
  Creates `README.md` (NEW file, project root). This is the whole-feature overview
  doc (PRD §5 "Mode B"): it summarizes the complete, coherent delta across P1–P4
  for an end user who just cloned the plugin. It is written ONLY after every
  implementing subtask it depends on is done (P1 render/palette, P2 capture/plugin,
  P3 region TUI, P4.M1 release binaries). Covers, per the contract: what tmux-2html
  is; install via TPM (`set -g @plugin 'tmux-2html/tmux-2html'`); prerequisites
  (tmux >= 3.2; Zig 0.15.2 ONLY if building from source); the three capture modes
  (full / visible / region); the keybinds (prefix O / prefix C-o / visible);
  a pointer to `docs/CONFIGURATION.md` for all `@tmux-2html-*` options (with a
  compact summary table in the README itself); the two headline known limitations
  (alt-screen capture PRD §13; huge-scrollback cap); and credits + MIT license
  noting the retained term2html + ghostty notices (PRD §14). HOUSE STYLE (contract,
  non-negotiable): no marketing tell-words, NO em dashes (U+2014), no hedging.
  The deliverable is ONE Markdown file that matches the shipped capabilities with
  zero stale claims. It is an OVERVIEW that POINTS to docs/CONFIGURATION.md for
  depth (the deep docs are owned by the sibling P4.M2.T1.S2 "docs/ overview
  sweep"). NO source/build/script changes. NO edit to docs/CONFIGURATION.md.

---

## Goal

**Feature Goal**: A standalone `README.md` at the repository root that gives a
new user everything they need to install tmux-2html via TPM, understand its three
capture modes and keybinds, find the full options reference, know its limits, and
see its license and credits — written in the project's terse, factual, marketing-
free house style, with every factual claim matching the shipped code.

**Deliverable**: ONE new file — `README.md` (project root). Markdown. Sections in
the order specified in `research/design_notes.md` §2 (H1 + one-liner; capture
modes; requirements; installation via TPM; key bindings; the region overlay;
command line; configuration summary + pointer; known limitations; license &
credits). Optionally a committed screenshot (see design_notes §3 — do NOT block on
it). No other file is created or modified.

**Success Definition**:
- `README.md` exists at the repo root and renders as valid Markdown (headings,
  tables, fenced code blocks, links all well-formed).
- A user can install the plugin by following the README: it shows the exact
  `set -g @plugin 'tmux-2html/tmux-2html'` line placed before the TPM `run` line,
  and tells them to press `prefix I`.
- The README documents the three capture modes and their default keybinds
  (prefix `O` full; prefix `C-o` region; visible unbound by default) exactly as
  shipped.
- The README contains a summary table of the 8 `@tmux-2html-*` options with
  defaults and points to `docs/CONFIGURATION.md` for the full reference.
- The README states the two headline limitations (alt-screen apps; scrollback cap
  at `@tmux-2html-history-limit`, default 50000).
- The README credits MIT + the retained term2html (aarol) and ghostty VT
  (Hashimoto / Ghostty contributors) notices under `licenses/`.
- House-style gates pass: zero em dashes (U+2014), zero banned marketing words,
  zero hedging words (see Validation Loop Level 1).
- Every factual claim (version, subcommand names, flag names, keybinds, option
  defaults, exit codes, credits) is consistent with the verified fact sheet in
  `research/shipped_facts.md` — no stale claims, no invented flags.

## User Persona (if applicable)

**Target User**: a tmux user who wants to share, archive, or screenshot a pane's
colored output as a self-contained HTML file. Two sub-personas: (a) the default
TPM user (installs the plugin, presses a prefix key, never touches Zig); (b) the
build-from-source / direct-CLI user (piping ANSI, scripting, or building locally).

**Use Case**: user adds the plugin to `~/.tmux.conf`, presses `prefix I`, then
presses `prefix O` on a colorful pane and gets an HTML file opened in the browser.

**User Journey**: read README one-liner -> TPM install snippet -> press `prefix I`
-> on first load a one-time palette popup runs -> press `prefix O` (or `C-o` for a
region) -> HTML file is written and (by default) auto-opened.

**Pain Points Addressed**: no existing README exists (the repo currently has none);
users have no install/usage instructions, no keybind reference, and no statement of
limits. This task fills that gap with an accurate, scannable overview.

## Why

- **The project ships with no README.** Every subtask P1–P4 is implemented (per
  `plan_status`), but the repo root has no README.md. A plugin without install
  instructions is effectively unusable by anyone who did not write it.
- **This is the contract's designated whole-feature doc (PRD §5 "Mode B").** It
  depends on all implementing subtasks precisely because it summarizes the
  complete, coherent delta. It exists to prevent shipping a coherent feature with
  no entry point.
- **An accurate README is the install path.** The TPM `set -g @plugin` snippet and
  the `prefix I` instruction are what make the plugin installable in one step.
- **It sets honest expectations.** Stating the alt-screen limitation and the
  scrollback cap up front prevents bug reports for documented non-goals (PRD §1.2,
  §13, §16).

## What

A single Markdown file, `README.md`, covering the sections below (order and
rationale in `research/design_notes.md` §2, derived from the `tmux-plugins/*`
exemplar READMEs):

1. **H1 + one-line description.** One declarative sentence, no puffery.
2. **Capture modes.** The three modes (full pane; visible pane; region), described
   conceptually (one short paragraph or list item each).
3. **Requirements.** tmux >= 3.2 (needs `display-popup`); Zig 0.15.2 ONLY if
   building from source (runtime users do not need it); `xdg-open` optional (for
   auto-open). Platforms: linux and macOS, x86_64 and arm64; no native Windows
   (WSL is fine).
4. **Installation.** TPM primary: the exact `set -g @plugin 'tmux-2html/tmux-2html'`
   line BEFORE `run '~/.tmux/plugins/tpm/tpm'`; install with `prefix I`. A short
   note that the binary is obtained automatically (prebuilt download by default;
   build-from-source if Zig is on PATH; manual fallback). A short build-from-source
   / manual-binary subsection.
5. **Key bindings.** Compact: prefix `O` -> full pane; prefix `C-o` -> region
   overlay; visible pane unbound by default (`set -g @tmux-2html-visible-key`). A
   note that `C-o` overrides the stock prefix-table `C-o` binding.
6. **The region overlay (short).** One paragraph: a copy-mode-style full-screen
   TUI; `v` toggles linewise/block; `Enter` renders, `q` cancels. Point to
   docs/CONFIGURATION.md and the in-app status line for the full key list.
7. **Command line (short).** Name the four subcommands (`render`, `pane`,
   `region`, `sync-palette`) with their one-line `--help` descriptions, note each
   has `--help`, and give ONE example. Do NOT reproduce the full flag tables.
8. **Configuration.** The 8-option summary table (name + default) + one sentence
   pointing to `docs/CONFIGURATION.md` for the full reference.
9. **Known limitations.** The two the contract names: alt-screen apps (nvim, less)
   target the normal screen + scrollback, alt-screen capture is a future option;
   huge scrollback is capped at `@tmux-2html-history-limit` (default 50000) with a
   status notice when truncated.
10. **License & credits.** MIT, (c) 2026 Dustin Schultz; credit term2html
    ((c) 2026 aarol) and ghostty VT ((c) 2024 Mitchell Hashimoto / Ghostty
    contributors), both MIT, notices retained under `licenses/`; point at `LICENSE`.

### House style (contract, non-negotiable)

- **No marketing tell-words.** Banned: `seamless`/`seamlessly`, `powerful`,
  `robust`, `blazing`, `easy`/`easily`, `simply`, `just`, `very`, `amazing`,
  `beautiful`, `leverage`, `cutting-edge`, `intuitive`. (Validation greps these.)
- **No em dashes (U+2014, `—`).** Use a plain ASCII hyphen `-`, a colon `:`,
  parentheses, or two sentences. (CRITICAL: PRD.md and docs/CONFIGURATION.md DO use
  em dashes; do not copy their prose. See gotcha below.)
- **No hedging.** Drop `might`, `probably`, `should`(where deterministic),
  `we hope`. Behavior is deterministic — state it directly.

### Success Criteria

- [ ] `README.md` exists at the repo root and is valid Markdown.
- [ ] TPM install snippet present verbatim (`set -g @plugin 'tmux-2html/tmux-2html'`)
      placed before the `run` line; `prefix I` instruction present.
- [ ] Three capture modes documented; default keybinds (O / C-o / visible-unbound)
      match shipped code.
- [ ] 8-option summary table present with correct defaults; pointer to
      `docs/CONFIGURATION.md` present.
- [ ] Two headline limitations present (alt-screen; scrollback cap 50000).
- [ ] Credits + MIT + retained term2html/ghostty notices present; points at
      `LICENSE` and `licenses/`.
- [ ] House-style gates pass: zero U+2014, zero banned marketing words, zero
      hedging words.
- [ ] Content audit (Validation Level 3): every claim matches `shipped_facts.md`.

## All Needed Context

### Context Completeness Check

_If someone knew nothing about this codebase, would they have everything needed to
implement this successfully?_ **YES.** This PRP embeds: the verified SHIPPED fact
sheet (version string `tmux-2html 0.1.0`; the exact 4 subcommand names + their
`--help` one-liners; the full per-subcommand flag list with defaults; the exact
default keybinds and the 8 `@tmux-2html-*` option defaults; the binary-acquisition
order; exit codes 0/1/2; the exact license/credit strings); the canonical TPM
install snippet and the `prefix I` instruction; the recommended section order
(derived from the `tmux-plugins/*` exemplar READMEs); the HARD house-style rules
(no marketing words, no em dashes, no hedging) with the explicit gotcha that the
source PRD/CONFIGURATION.md use em dashes and must not be copy-pasted; the sibling
boundaries (S2 owns docs/CONFIGURATION.md depth; P4.M1.T1.S2 CI is unrelated); and
concrete, executable validation gates (grep for U+2014 / banned words / hedging;
markdown + link checks; a content-audit checklist). An implementer needs only this
PRP + the two research files it references.

### Documentation & References

```yaml
# MUST READ — the verified fact sheet. The single source of truth for every
# factual claim in the README (version, subcommands, flags, keybinds, options,
# exit codes). Cite it; do not invent.
- docfile: plan/001_0c8587f91cb2/P4M2T1S1/research/shipped_facts.md
  why: §1 version string; §2 the 4 subcommand names + exact --help one-liners;
       §3 the full per-subcommand flag list with defaults (all confirmed against
       src/cli.zig — use this for the summary; do not invent flags); §4 the exact
       bind-key lines + read_opt defaults; §5 the 8 @tmux-2html-* option defaults;
       §6 the ensure_binary.sh acquisition order; §7 exit codes 0/1/2.
  critical: "§7 Risks — region is FULLY implemented (NOT a stub) and download.sh
             EXISTS (NOT 'not yet available'). Ignore the stale comments in
             src/main.zig / src/region.zig / ensure_binary.sh; trust shipped code."

# MUST READ — the README-author synthesis: section order, hard style rules, the
# do-not-copy-from-PRD gotcha, the screenshot decision, the sibling boundaries,
# the accuracy anchors, and the validation approach.
- docfile: plan/001_0c8587f91cb2/P4M2T1S1/research/design_notes.md
  why: §1 the HARD house-style rules + the banned-words grep set + the em-dash
       gotcha; §2 the section order mapped to the contract; §3 screenshot = optional;
       §4 the S2 boundary (README = overview + pointer; S2 = docs depth);
       §6 the accuracy anchors; §7 the validation gates.
  section: "all"

# MUST READ — TPM install convention + README structure + style-guide rationale.
- docfile: plan/001_0c8587f91cb2/P4M2T1S1/research/readme_tpm_conventions.md
  why: §1 the canonical `set -g @plugin 'owner/repo'` snippet, the "plugin lines
       before the run line" rule, the `prefix I` / `prefix U` / `prefix alt-u`
       keybindings, and the `~/.tmux/plugins/` install path; §2 the recommended
       README section order (from tmux-resurrect/continuum/yank); §3 the style-
       guide basis for the no-marketing-words / no-hedging rules + the honest
       finding that the em-dash rule is a PROJECT choice (portability), not a
       style-guide ban.
  section: "all"

# The deep options reference this README POINTS TO. Read it so the summary table
# is consistent and so the pointer line is accurate. Do NOT edit it (S2 owns it).
- file: docs/CONFIGURATION.md
  why: the full @tmux-2html-* options reference (P2.M2.T1.S1). The README's
       configuration section summarizes it and links to it. Mirror its option
       names/defaults exactly (they match shipped_facts §5). Note it uses em
       dashes — do not copy its prose.
  pattern: "Options table + palette cache section + sync-palette section"

# The entrypoint — confirms the keybind + option defaults and the palette
# auto-sync popup behavior the install/first-run note describes.
- file: tmux-2html.tmux
  why: §3 read_opt defaults (full_key=O, region_key=C-o, visible_key="");
       the prefix O / C-o / visible bind-key blocks; the one-time palette
       auto-sync popup (first load, if no cache). Use these to describe first-run
       behavior accurately.
  gotcha: "the visible binding is guarded by `if [ -n "$visible_key" ]`, so it is
           unbound until the user sets @tmux-2html-visible-key. State this."

# The help text actually shipped — the subcommand one-liners in the README's
# command-line section should match these exactly.
- file: src/main.zig
  why: the `usage_text` literal (the Usage/Subcommands/Common options/Exit codes
       block) is the authoritative wording for the subcommand one-liners and the
       exit-code line. Quote the subcommand one-liners verbatim.
  pattern: "usage_text multi-line string literal (printUsage)"

# License + attribution sources for the credits section.
- file: LICENSE
  why: project license = MIT, (c) 2026 Dustin Schultz. The credits section states
       this and points at LICENSE.
- file: licenses/TERM2HTML.txt
  why: upstream term2html notice = MIT, (c) 2026 aarol. Retained per MIT; credited.
- file: licenses/GHOSTTY-VT.txt
  why: upstream ghostty VT notice = MIT, (c) 2024 Mitchell Hashimoto, Ghostty
       contributors. Retained per MIT; credited.

# The PRD sections named by the contract for CONTENT. Read for accuracy; do NOT
# copy prose (PRD uses em dashes + occasional praise phrasing).
- docfile: PRD.md
  why: §1 overview + goals (what it is, the three modes); §4 repo layout (file
       names for credits/links); §7 the region TUI (v toggles linewise/block,
       Enter renders, q cancels — for the short region section); §9 options table
       + bindings (the 8 options + the C-o override note); §13 edge cases/limits
       (alt-screen + scrollback cap — the two headline limitations); §14 licensing
       & attribution (the credits requirement); §16 roadmap (alt-screen capture is
       explicitly out of v1 scope — supports the limitation wording).
  section: "1, 4, 7, 9, 13, 14, 16"

# External — TPM README (canonical install snippet + keybindings).
- url: https://github.com/tmux-plugins/tpm/blob/master/README.md
  why: authoritative source for the `set -g @plugin` form, the "plugin list before
       the run line" rule, and the `prefix I` (install) / `prefix U` (update) /
       `prefix alt-u` (uninstall) keybindings. Mirror its snippet wording.
  critical: "the @plugin line MUST appear before `run '~/.tmux/plugins/tpm/tpm'`;
             TPM parses the list when `run` executes."
```

### Current Codebase tree (run `ls -la` at the repo root)

```bash
$ ls -la
build.zig  build.zig.zon  docs/  LICENSE  licenses/  PRD.md  scripts/  src/  testdata/  tmux-2html.tmux
.github/workflows/   # release.yml (P4.M1.T1.S1, done) + ci.yml (P4.M1.T1.S2, parallel, unrelated)
# (README.md does NOT exist yet — THIS TASK creates it.)
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
README.md            # NEW (THIS TASK). Project-root overview: install, modes, keybinds,
                     #   options summary + pointer, limits, credits. House style enforced.
```

`README.md` responsibilities:
- Be the single entry point for a new user: what it is, how to install via TPM,
  the three capture modes + keybinds, where the full options reference lives
  (`docs/CONFIGURATION.md`), the headline limits, and the license/credits.
- Match shipped capabilities exactly (fact sheet) — no stale or invented claims.
- Follow the house style (no marketing words, no em dashes, no hedging).

### Known Gotchas of our codebase & Library Quirks

```yaml
# CRITICAL: do NOT copy prose from PRD.md or docs/CONFIGURATION.md into the README.
# Both use em dashes (U+2014) and the PRD occasionally uses praise-adjacent phrasing.
# Copying their sentences violates the house style (no em dashes, no marketing words).
# Reuse exact TECHNICAL TOKENS (flag names, option names, default values, the install
# snippet) but write FRESH sentences from research/shipped_facts.md.

# CRITICAL: the em-dash rule is a HARD project rule for THIS README, even though the
# PRD and docs/CONFIGURATION.md use em dashes. The "no em dashes" rule is a PROJECT
# choice (terminal/copy-paste portability), NOT a style-guide ban — so do not cite
# Google/Microsoft as a "ban". Just enforce zero U+2014 in README.md (Validation L1).

# CRITICAL: region is FULLY implemented (confirm renders HTML + writes the
# .last-output sidecar + optional --open, exit 0). download.sh EXISTS and is
# executable. STALE comments in src/main.zig ("region currently returns
# NotImplemented... inert"), src/region.zig ("Confirm => exit 1 (S1 STUB...)"), and
# ensure_binary.sh ("download.sh is P2.M3.T1.S2 (NOT YET DONE)") contradict the
# shipped code. IGNORE those comments; trust research/shipped_facts.md §7 + Risks.
# Do NOT call region a stub or say the download path is unavailable.

# CRITICAL: the default keybinds are prefix O (full), prefix C-o (region), and
# visible = UNBOUND (the visible_key default is the empty string; the binding is
# guarded by `if [ -n "$visible_key" ]`). State that visible capture is opt-in.

# CRITICAL: prefix C-o OVERRIDES the stock tmux prefix-table C-o binding. The README
# must say so (PRD §9.2 note; docs/CONFIGURATION.md key-conflict note), and tell the
# user how to avoid it (set @tmux-2html-region-key to e.g. C-S-o).

# CRITICAL: tmux >= 3.2 is required (display-popup, used for the region overlay and
# the one-time palette auto-sync popup). State it. Zig 0.15.2 is ONLY needed to build
# from source; runtime users never install it (ensure_binary.sh downloads a prebuilt
# binary by default when Zig is absent).

# NOTE: the GitHub owner/repo for the @plugin line is 'tmux-2html/tmux-2html' (per
# the contract). Use that exact form in the install snippet and any links
# (https://github.com/tmux-2html/tmux-2html, .../releases).

# NOTE: the one-time palette auto-sync popup fires on first plugin load if no cache
# exists (tmux-2html.tmux palette section). Worth ONE line in the install/first-run
# note so users are not surprised by a brief popup. It is non-fatal.

# NOTE: this codebase has NO README and NO doc-test framework. Validation is grep +
# markdown/link checks + a content audit (see Validation Loop), not a test command.
```

## Implementation Blueprint

### Data models and structure

No code data models. The "data" is the verified fact sheet
(`research/shipped_facts.md`): version string, subcommand names + one-liners, the
per-subcommand flags, the keybind defaults, the 8 option defaults, exit codes, and
the credit strings. The README's summary table is derived directly from shipped_facts
§5 (options) and §2 (subcommands).

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: READ the three research files + the reference files (do this FIRST)
  - READ research/shipped_facts.md (the fact sheet — source of truth for every claim).
  - READ research/design_notes.md (section order + HARD style rules + gotchas).
  - READ research/readme_tpm_conventions.md (TPM snippet + section order basis).
  - SKIM docs/CONFIGURATION.md (so the summary table + pointer are consistent); note
    it uses em dashes — do not copy its prose.
  - SKIM PRD.md §1/§4/§7/§9/§13/§14/§16 for content accuracy; do not copy prose.
  - GOAL: write FRESH prose from the fact sheet, not paraphrased PRD sentences.

Task 2: CREATE README.md at the repo root with the section order in design_notes §2
  - SECTION 1 (H1 + one-liner): one declarative sentence, no puffery. Example shape:
    "# tmux-2html — Capture a tmux pane to a standalone, color-faithful HTML document."
    (Use a plain hyphen or colon, NOT an em dash.)
  - SECTION 2 (Capture modes): full pane (scrollback + visible); visible pane (only
    the visible rows); region (interactive copy-mode overlay over the full
    scrollback, select a line range or a block). One short paragraph or list each.
  - SECTION 3 (Requirements): tmux >= 3.2; Zig 0.15.2 ONLY if building from source;
    xdg-open optional. Platforms: linux + macOS, x86_64 + arm64; no native Windows.
  - SECTION 4 (Installation): TPM primary — the fenced block:
        set -g @plugin 'tmux-2html/tmux-2html'
    placed BEFORE `run '~/.tmux/plugins/tpm/tpm'`; then `prefix I`. One short note
    on automatic binary acquisition (prebuilt download by default; build-from-source
    if Zig is on PATH; manual fallback). A short "Build from source / manual" sub-
    section (zig 0.15.2 + `zig build --release=fast`, or drop a binary in the bin
    dir). Mention the one-time palette auto-sync popup fires on first load.
  - SECTION 5 (Key bindings): compact table or list — prefix `O` full pane; prefix
    `C-o` region overlay; visible pane unbound by default. Note prefix C-o overrides
    the stock prefix-table C-o; to keep the old binding set
    @tmux-2html-region-key (e.g. C-S-o).
  - SECTION 6 (Region overlay, short): copy-mode-style full-screen TUI; `v` toggles
    linewise/block; `Enter` renders the selection, `q` cancels. Point to
    docs/CONFIGURATION.md + the in-app status line for the full key list.
  - SECTION 7 (Command line, short): the four subcommands with their exact --help
    one-liners (shipped_facts §2), note each has --help, ONE example
    (e.g. `tmux-2html pane --full` or `tmux-2html render < ansi.txt > out.html`).
    Do NOT reproduce the full flag tables.
  - SECTION 8 (Configuration): the 8-option summary table (name + default, from
    shipped_facts §5) + "See docs/CONFIGURATION.md for the full options reference,
    the palette cache, and sync-palette behavior."
  - SECTION 9 (Known limitations): alt-screen apps (nvim, less) target the normal
    screen + scrollback; alt-screen capture is a future option. Huge scrollback is
    capped at @tmux-2html-history-limit (default 50000) with a status notice when
    truncated. Optionally one line linking the rest to docs/CONFIGURATION.md.
  - SECTION 10 (License & credits): MIT, (c) 2026 Dustin Schultz. Credit term2html
    ((c) 2026 aarol, MIT) and the ghostty VT engine ((c) 2024 Mitchell Hashimoto /
    Ghostty contributors, MIT); both upstream MIT notices are retained under
    licenses/ (TERM2HTML.txt, GHOSTTY-VT.txt). Point at LICENSE.
  - NAMING/PLACEMENT: the file is README.md at the repo root (no subdir).
  - FOLLOW pattern: the tmux-plugins/* README voice (terse, factual, TPM-first) —
    see research/readme_tpm_conventions.md §2.
  - GOTCHA: write fresh prose; do not copy PRD.md / docs/CONFIGURATION.md sentences
    (they contain em dashes). Use plain hyphens / colons / parentheses / two
    sentences instead of em dashes.

Task 3: SELF-AUDIT the house style (Validation Level 1) and fix before commit
  - RUN: `grep -nP '\x{2014}' README.md` -> MUST be empty (no em dashes).
  - RUN: `grep -niE '\b(seamless|seamlessly|powerful|robust|blazing|easy|easily|simply|just|very|amazing|beautiful|leverage|cutting-edge|intuitive)\b' README.md`
         -> MUST be empty (no marketing tell-words). (Review any hit; "just"/"very"
         as a literal technical term are fine, but in marketing tone they go.)
  - RUN: `grep -niE '\b(might|probably)\b' README.md` -> MUST be empty (no hedging).
  - FIX any hits by rephrasing (hyphen/colon/two sentences; concrete verb + noun).

Task 4: CONTENT AUDIT against shipped_facts.md (Validation Level 3) and fix drift
  - ASSERT version reference (if any) == `tmux-2html 0.1.0`.
  - ASSERT the 4 subcommand names + one-liners match shipped_facts §2.
  - ASSERT keybinds match shipped_facts §4 (O full; C-o region; visible unbound).
  - ASSERT the 8-option table defaults match shipped_facts §5.
  - ASSERT exit-code line (if present) == "0 success, 1 usage/runtime error,
    2 capture/target error".
  - ASSERT credits strings match LICENSE + licenses/*.txt (Dustin Schultz / aarol /
    Mitchell Hashimoto, Ghostty contributors).
  - ASSERT region is described as working (NOT stubbed) and the download path is
    described as available (NOT "not yet").

Task 5: MARKDOWN + LINK check (Validation Level 2)
  - RUN (if available): `markdownlint README.md` or `mdformat --check README.md`.
    If neither is installed, do a manual eyeball: heading levels nest, fenced code
    blocks close, the options table has a header row + separator, links are valid.
  - CHECK relative links resolve: docs/CONFIGURATION.md, LICENSE,
    licenses/TERM2HTML.txt, licenses/GHOSTTY-VT.txt.
  - CHECK external links point at the right landing pages (TPM README; the plugin's
    own repo / releases at https://github.com/tmux-2html/tmux-2html).
```

### Implementation Patterns & Key Details

```markdown
<!-- The TPM install block (canonical form; @plugin line BEFORE the run line): -->
```tmux
# in ~/.tmux.conf, above the TPM run line
set -g @plugin 'tmux-2html/tmux-2html'

# then, at the very bottom:
run '~/.tmux/plugins/tpm/tpm'
```
Reload tmux, then press `prefix I` to install. tmux-2html fetches its binary
automatically (a prebuilt download by default; a from-source build if Zig 0.15.2
is on PATH).

<!-- The 8-option summary table (defaults from shipped_facts §5): -->
| Option | Default | Meaning |
|---|---|---|
| `@tmux-2html-full-key` | `O` | Prefix key: capture the full pane. |
| `@tmux-2html-region-key` | `C-o` | Prefix key: open the region overlay. |
| `@tmux-2html-visible-key` | *(empty)* | Prefix key: capture the visible pane. Unbound by default. |
| `@tmux-2html-output-dir` | `${XDG_DATA_HOME:-~/.local/share}/tmux-2html` | Where HTML files are written. |
| `@tmux-2html-open` | `on` | Run `xdg-open` on the HTML file after writing. |
| `@tmux-2html-font` | `monospace` | CSS `font-family` in the rendered HTML. |
| `@tmux-2html-history-limit` | `50000` | Max scrollback lines captured per pane. |
| `@tmux-2html-binary-dir` | `$TMUX_2HTML_BIN` | Directory holding the binary. |

See docs/CONFIGURATION.md for the full reference, the palette cache, and
sync-palette behavior.

<!-- House-style in action: -->
# GOOD: "Press prefix O to capture the full pane. The HTML file is written and
#        opened in your browser."
# BAD:  "Press prefix O to seamlessly capture your beautiful pane into blazing-fast
#        HTML — it just works!"   # em dash + marketing words + hedging-via-just
```

### Integration Points

```yaml
FILES REFERENCED BY THE README (must exist; do not create/modify them):
  - docs/CONFIGURATION.md   # the full options reference (P2.M2.T1.S1; S2 owns depth). POINTER target.
  - LICENSE                 # MIT, (c) 2026 Dustin Schultz. POINTER target.
  - licenses/TERM2HTML.txt  # term2html (aarol) MIT notice. POINTER target.
  - licenses/GHOSTTY-VT.txt # ghostty VT (Hashimoto / contributors) MIT notice. POINTER target.
TPM INSTALL (external contract):
  - @plugin line: 'tmux-2html/tmux-2html' (the contract's owner/repo).
  - must precede `run '~/.tmux/plugins/tpm/tpm'`; install via `prefix I`.
SIBLING BOUNDARIES (do not cross):
  - P4.M2.T1.S2 owns docs/CONFIGURATION.md depth (region walkthrough, full §13 list,
    attribution depth). This README is OVERVIEW + POINTER only. Do NOT edit
    docs/CONFIGURATION.md in this task.
  - P4.M1.T1.S2 (ci.yml) is parallel and unrelated to README content; no dependency.
```

## Validation Loop

> **NOTE**: this is a documentation task. There is no test command. Validation is
> (1) house-style greps, (2) Markdown + link checks, (3) a content audit against
> the verified fact sheet. All three are mandatory.

### Level 1: House-style gates (mandatory; run after writing)

```bash
# (a) NO em dashes (U+2014). MUST print nothing.
grep -nP '\x{2014}' README.md && echo "FAIL: em dash present" || echo "OK: no em dashes"

# (b) NO marketing tell-words. MUST print nothing (review any literal-technical use).
grep -niE '\b(seamless|seamlessly|powerful|robust|blazing|easy|easily|simply|very|amazing|beautiful|leverage|cutting-edge|intuitive)\b' README.md \
  && echo "FAIL: review marketing words" || echo "OK: no marketing words"

# (c) NO hedging. MUST print nothing.
grep -niE '\b(might|probably)\b' README.md && echo "FAIL: hedging" || echo "OK: no hedging"

# Expected: all three print "OK: ...". Fix any hit by rephrasing before proceeding.
```

### Level 2: Markdown + link integrity

```bash
# (a) Markdown lint (best-effort; install if convenient):
#   markdownlint README.md        # npm i -g markdownlint-cli
#   mdformat --check README.md    # pip install mdformat
# If neither is available, do a manual eyeball (headings nest, fences close, table
# has header + separator, links valid). Expected: zero errors.

# (b) Relative links resolve (all MUST exist):
for f in docs/CONFIGURATION.md LICENSE licenses/TERM2HTML.txt licenses/GHOSTTY-VT.txt; do
  [ -f "$f" ] && echo "OK: $f" || echo "MISSING: $f"
done

# (c) External links sanity (grep them out; eyeball the targets):
grep -oE 'https?://[^ )"]+' README.md | sort -u
# Expected: TPM README URL (github.com/tmux-plugins/tpm) + the plugin's own repo /
#   releases (github.com/tmux-2html/tmux-2html) + any style-guide/freedesktop links.
#   Confirm each points at the right landing page.
```

### Level 3: Content audit (mandatory; map every claim to the fact sheet)

```bash
# A checklist (run mentally / as grep assertions). Each MUST hold.
# 1. Version (if stated) == tmux-2html 0.1.0
grep -n "0\.1\.0" README.md        # if present, must be the version
# 2. The 4 subcommand names appear:
grep -nE '\b(render|pane|region|sync-palette)\b' README.md
# 3. Default keybinds stated:
grep -nE 'prefix .?O|C-o|visible' README.md
# 4. All 8 option names appear in the summary table:
for o in full-key region-key visible-key output-dir open font history-limit binary-dir; do
  grep -q "@tmux-2html-$o" README.md && echo "OK: $o" || echo "MISSING: $o"
done
# 5. Exit codes (if stated) match 0/1/2:
grep -n "Exit codes\|exit" README.md   # if present: 0 success, 1 usage/runtime, 2 capture/target
# 6. Credits present:
grep -niE "aarol|Hashimoto|Ghostty|Dustin Schultz|MIT" README.md
# 7. Limitations present:
grep -niE "alt.?screen|scrollback|history-limit|50000" README.md
# 8. Pointer to docs/CONFIGURATION.md present:
grep -n "docs/CONFIGURATION.md" README.md
# Expected: every assertion holds. Any drift -> fix the README to match shipped_facts.md.
```

### Level 4: Render + readability (manual)

```bash
# Render the Markdown and read it end to end (GitHub render or a local previewer):
#   - open README.md on github.com (or `glow README.md` / `mdcat README.md` if installed)
#   - confirm the install snippet is copy-pasteable and correct
#   - confirm the options table renders as a table
#   - confirm a new user could install + use the plugin from this doc alone
# (Optional screenshot: generate from an ISOLATED tmux socket per PRD §0, never the
#  user's live server. See design_notes §3. Do NOT block the README on a screenshot.)
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1 house-style gates pass (zero U+2014, zero marketing words, zero hedging).
- [ ] Level 2: Markdown is well-formed; all relative links resolve; external links valid.
- [ ] Level 3 content audit: version, subcommands, flags, keybinds, option defaults,
      exit codes, credits, limitations all match `research/shipped_facts.md`.

### Feature Validation

- [ ] TPM install snippet present verbatim (`set -g @plugin 'tmux-2html/tmux-2html'`)
      before the `run` line; `prefix I` instruction present.
- [ ] Three capture modes documented; default keybinds (O / C-o / visible-unbound)
      match shipped code.
- [ ] 8-option summary table present with correct defaults; pointer to
      `docs/CONFIGURATION.md` present.
- [ ] Two headline limitations present (alt-screen; scrollback cap default 50000).
- [ ] Credits + MIT + retained term2html/ghostty notices present; points at `LICENSE`
      and `licenses/`.
- [ ] region described as working (NOT stubbed); download path described as available.
- [ ] tmux >= 3.2 requirement stated; Zig noted as build-from-source only.

### Code Quality Validation

- [ ] Follows the `tmux-plugins/*` README voice (terse, factual, TPM-first).
- [ ] Fresh prose throughout (no copy-pasted PRD/CONFIGURATION.md sentences).
- [ ] File placement correct: `README.md` at the repo root.
- [ ] Scope respected: overview + pointer only; deep docs left to P4.M2.T1.S2.

### Documentation & Deployment

- [ ] A new user can install and use the plugin from this README alone.
- [ ] No stale claims (region stub, download unavailable, wrong version/flags/keys).
- [ ] No edits to any file other than the new `README.md`.

---

## Anti-Patterns to Avoid

- ❌ Don't copy prose from PRD.md or docs/CONFIGURATION.md — they use em dashes (U+2014)
  and the PRD uses praise phrasing. Write fresh sentences from the fact sheet.
- ❌ Don't use em dashes (U+2014), marketing words, or hedging — the house-style gates
  (Level 1) will fail. Use plain hyphens, colons, parentheses, or two sentences.
- ❌ Don't call region a stub or say the download path is unavailable — both are
  shipped and working (ignore the stale comments in src/main.zig /
  src/region.zig / ensure_binary.sh; trust `shipped_facts.md`).
- ❌ Don't invent flags or options — use exactly the verified set in
  `shipped_facts.md` §3 and §5.
- ❌ Don't reproduce the full flag tables or the palette-cache format spec in the
  README — that depth belongs in docs/CONFIGURATION.md (owned by P4.M2.T1.S2). The
  README is an overview + pointer.
- ❌ Don't edit docs/CONFIGURATION.md, PRD.md, source, build, or scripts — the ONE
  deliverable is `README.md`.
- ❌ Don't state wrong keybinds — defaults are prefix O (full), prefix C-o (region),
  visible UNBOUND. And note prefix C-o overrides the stock prefix-table C-o.
- ❌ Don't omit the tmux >= 3.2 requirement or misstate the Zig requirement (Zig is
  build-from-source ONLY; runtime users get a prebuilt download automatically).
- ❌ Don't block the README on a screenshot — it is optional (design_notes §3); if
  added, generate it from an ISOLATED tmux socket per PRD §0, never the live server.
- ❌ Don't expand scope into a CLI reference manual or a configuration deep-dive —
  the contract asks for install, modes, keybinds, an options summary + pointer, the
  two headline limits, and credits. Keep it an overview.

---

## Confidence Score

**9/10** — The deliverable is a SINGLE new Markdown file (`README.md`) whose every
factual claim is anchored to a VERIFIED fact sheet (`research/shipped_facts.md`,
produced by reading the actual shipped source: build.zig.zon version, src/main.zig
usage_text, src/cli.zig flags, tmux-2html.tmux keybinds/options, ensure_binary.sh
acquisition order, LICENSE + licenses/*.txt). The canonical TPM install snippet and
the recommended section order come from the authoritative TPM README + the
`tmux-plugins/*` exemplars (`research/readme_tpm_conventions.md`). The HARD
house-style rules (no marketing words, no em dashes, no hedging) are explicit and
enforced by concrete grep gates (Validation Level 1). The two key traps are called
out with evidence: (1) do NOT copy PRD/CONFIGURATION.md prose (they use em dashes);
(2) region is fully implemented and download.sh exists — ignore the stale source
comments that say otherwise. The sibling boundary is clean: S2 owns
docs/CONFIGURATION.md depth, so this README is overview + pointer with no overlap;
P4.M1.T1.S2 (ci.yml) is parallel and unrelated. The codebase has no README and no
doc-test framework, so validation is grep + markdown/link checks + a content audit
— all defined as executable commands.

Residual risks (all low): (1) the GitHub owner/repo `tmux-2html/tmux-2html` is
taken from the contract; if the real published repo differs, the @plugin line and
links need a one-token update — mitigated by stating the exact form to use. (2) A
screenshot would strengthen a visual tool's README but is optional and safety-
constrained (isolated tmux per §0); the PRP marks it optional so it cannot block
delivery. (3) Markdown linters may not be installed — mitigated by the manual
eyeball checklist + the grep-based content audit, which catch the substantive
errors (stale claims, style violations, broken relative links). (4) "no marketing
words / no hedging" greps can have rare false positives on literal technical uses
of e.g. "just"/"very" — mitigated by the "review any hit" instruction rather than
a blind fail.
