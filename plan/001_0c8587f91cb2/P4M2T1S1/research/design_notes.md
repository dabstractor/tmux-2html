# Design notes — README.md (P4.M2.T1.S1)

Synthesis of `shipped_facts.md` + `readme_tpm_conventions.md` into the concrete
decisions the README implementer must follow. Read this before writing the file.

## 1. House style — HARD RULES (the contract mandates these)

Source: contract "Use the write-tech-docs conventions (no marketing tell-words,
no em dashes, no hedging)."

- **No marketing tell-words.** Banned set (grep these out before commit):
  `seamless`, `seamlessly`, `powerful`, `robust`, `blazing`, `blazing-fast`,
  `easy`, `easily`, `simply`, `just`, `very`, `amazing`, `beautiful`, `leverage`,
  `cutting-edge`, `modern`(as an adjective of praise), `intuitive`. Use a
  measured verb + a concrete noun instead ("captures a tmux pane and writes an
  HTML document").
- **No em dashes (U+2014, `—`).** Use a plain ASCII hyphen `-`, a colon `:`,
  parentheses, or two sentences. This is a PROJECT rule (terminal/copy-paste
  portability), NOT a style-guide ban — Google/Microsoft only counsel restraint,
  so do not cite them as a "ban".
- **No hedging.** Drop `might`, `probably`, `should`(where behavior is
  deterministic), `we hope`, `may`. Behavior is deterministic — state it.
  Examples: "press `prefix O` to capture the full pane", not "pressing prefix O
  should capture the pane".

### CRITICAL gotcha: do NOT copy prose from PRD.md or docs/CONFIGURATION.md

Both PRD.md and docs/CONFIGURATION.md DO use em dashes (U+2014) heavily, and the
PRD occasionally uses praise-adjacent phrasing. Copying their sentences into the
README will violate the house style. Write FRESH prose from the fact sheet in
`shipped_facts.md`. You may reuse exact technical tokens (flag names, option
names, default values, the install snippet) but not whole sentences.

## 2. Section order (matches tmux-plugins/* exemplars, tuned to the contract)

The contract's LOGIC list maps to this order. Keep the README an OVERVIEW; deep
detail lives in docs/CONFIGURATION.md (owned by sibling P4.M2.T1.S2).

1. **H1 + one-line description** — one declarative sentence: what tmux-2html does.
   No puffery. (e.g. "Capture a tmux pane to a standalone, color-faithful HTML
   document.")
2. **What it does / capture modes** — the three modes (full / visible / region),
   one paragraph or short list each, conceptual (not flag tables).
3. **Requirements** — tmux >= 3.2 (for `display-popup`); Zig 0.15.2 ONLY if
   building from source (runtime users need not install it); `xdg-open` optional
   (for auto-open). Platforms: linux and macOS, x86_64 and arm64. No native
   Windows (WSL is fine).
4. **Installation** — TPM primary: the exact `set -g @plugin 'tmux-2html/tmux-2html'`
   line BEFORE the `run '~/.tmux/plugins/tpm/tpm'` line; install with `prefix I`.
   Brief note on how the binary is obtained automatically (prebuilt download by
   default; build-from-source if Zig is present; manual fallback). One short
   manual/build-from-source subsection.
5. **Key bindings** — compact: `prefix O` full pane; `prefix C-o` region overlay;
   visible pane unbound by default (set `@tmux-2html-visible-key`). Note the
   `C-o` override of the stock prefix table.
6. **The region overlay (short)** — one paragraph: copy-mode-style full-screen
   TUI; `v` toggles linewise/block; `Enter` renders, `q` cancels. Point to
   docs/CONFIGURATION.md + the in-app status line for the full key list.
7. **Command line (short)** — name the four subcommands (render / pane / region /
   sync-palette) with their one-line descriptions from `--help`, and say each has
   `--help`. Do NOT duplicate the full flag tables — that is docs/CONFIGURATION.md
   territory. Show ONE example (e.g. `tmux-2html pane --full` or piping
   `... | tmux-2html render`).
8. **Configuration** — one sentence + a compact summary table of the 8
   `@tmux-2html-*` options with defaults, then "See docs/CONFIGURATION.md for the
   full options reference, the palette cache, and sync-palette behavior."
9. **Known limitations** — the two the contract names: (a) alternate-screen apps
   (nvim, less) — capture targets the normal screen + scrollback, alt-screen
   capture is a future option (PRD §13/§16); (b) huge scrollback is capped at
   `@tmux-2html-history-limit` (default 50000) with a status notice when
   truncated. Optionally one line linking the rest to docs/.
10. **License & credits** — MIT, (c) 2026 Dustin Schultz. Credit the absorbed
    term2html ((c) 2026 aarol, MIT) and the ghostty VT engine ((c) 2024 Mitchell
    Hashimoto / Ghostty contributors, MIT); both upstream MIT notices are retained
    under `licenses/` (TERM2HTML.txt, GHOSTTY-VT.txt). One line pointing at
    `LICENSE`.

## 3. Screenshot — OPTIONAL, do not block on it

A rendered-HTML sample is the strongest proof for a visual tool, but generating
one safely requires an ISOLATED tmux server (PRD §0 safety rule: never touch the
user's live tmux). The contract does NOT require a screenshot. Treat it as an
optional enhancement: if added, generate it from a uniquely-named test socket
(`tmux -L tmux-2html-readme-$$ ...`), render, screenshot the browser, commit the
PNG, and reference it. If skipped, ship without it. Do NOT stall the README on a
screenshot.

## 4. Boundary with sibling P4.M2.T1.S2 (docs/ overview sweep)

S2 owns the DEEP docs in docs/CONFIGURATION.md: the region TUI usage walkthrough,
sync-palette in-vs-out-of-tmux behavior, full edge-case/limits detail (PRD §13),
and attribution depth. S1 (this README) is the OVERVIEW + POINTER. Concretely:
- README includes the 8-option SUMMARY table (names + defaults) and points to
  docs/CONFIGURATION.md for the full reference.
- README does NOT reproduce the palette-cache format spec, the full §13 list, or
  a multi-paragraph region walkthrough — those are S2's.

Do not edit docs/CONFIGURATION.md in this task (S2 owns it).

## 5. Boundary with parallel P4.M1.T1.S2 (CI test job)

P4.M1.T1.S2 creates `.github/workflows/ci.yml` (runs `zig build test
-Doptimize=ReleaseFast` on push/PR). It is UNRELATED to README content. No
conflict; no dependency. The README does not need to mention CI.

## 6. Accuracy anchors (do not drift from these — `shipped_facts.md` is the source)

- Version string printed: `tmux-2html 0.1.0` (build.zig.zon `.version`).
- Exactly 4 subcommands: `render`, `pane`, `region`, `sync-palette` (names + the
  one-line `--help` descriptions in `shipped_facts.md` §2).
- Flags: the full per-subcommand flag list with defaults is in
  `shipped_facts.md` §3 — all verified against src/cli.zig. Use it for the
  summary; do not invent flags.
- Keybinds: prefix `O` -> `pane --full`; prefix `C-o` -> region `display-popup`
  (100%x100%); visible unbound by default. Defaults from `tmux-2html.tmux`.
- 8 options: full-key=O, region-key=C-o, visible-key=(empty), open=on,
  font=monospace, history-limit=50000, output-dir=${XDG_DATA_HOME:-~/.local/share}/tmux-2html,
  binary-dir=$TMUX_2HTML_BIN.
- Binary acquisition order: version-match -> `zig build` (if Zig) -> download
  prebuilt (SHA256-verified) -> fail with a tmux message. So a user WITHOUT Zig
  gets a downloaded prebuilt binary automatically; a user WITH Zig builds from
  source on load.
- Exit codes: 0 success, 1 usage/runtime error, 2 capture/target error.
- region is FULLY implemented (confirm renders + writes HTML + sidecar + optional
  open, exit 0). Do NOT call it a stub. download.sh EXISTS and is executable. Do
  NOT say "download not yet available". (Stale comments in src/main.zig /
  src/region.zig / ensure_binary.sh contradict this — ignore them; trust the
  shipped code per `shipped_facts.md` §7 + Risks.)

## 7. Validation approach (no test framework exists for docs)

This codebase has no README and no doc-test framework. Define the gates in the
PRP as concrete, executable checks:
- `grep -nP '\x{2014}' README.md` -> MUST be empty (no em dashes).
- grep the banned marketing words (§1) -> MUST be empty.
- grep hedging words (`\b(might|probably)\b`) -> MUST be empty.
- markdown well-formedness: render check via a linter if available
  (`markdownlint`/`mdformat`), else a manual heading/code-fence/link eyeball.
- link check: every relative link resolves (`docs/CONFIGURATION.md`, `LICENSE`,
  `licenses/TERM2HTML.txt`, `licenses/GHOSTTY-VT.txt`) and external links point
  at the right landing pages (TPM README, the plugin's own repo/releases).
- content audit: a checklist mapping each factual claim in the README to its
  anchor in `shipped_facts.md` (version, flags, keybinds, options, exit codes,
  credits) so nothing is stale or invented.
