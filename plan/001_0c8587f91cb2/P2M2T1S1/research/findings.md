# P2.M2.T1.S1 — Entrypoint research findings (verified in-repo + via tmux man/architecture)

> Authoritative sources: `architecture/findings_and_corrections.md §3`, `architecture/research_tmux.md`,
> `architecture/system_context.md`, `architecture/tui_region.md`, `PRD.md §9.1–§9.3 + §10 + §13`,
> live code (`src/palette.zig`, `src/cli.zig`, `build.zig.zon`, `tmux-2html.tmux`, `scripts/`).
> tmux 3.6b is installed locally; `/bin/sh -> bash`.

## 1. Tree reality (verified `ls`)
- `tmux-2html.tmux` is **0 bytes** → this task FILLS it.
- `scripts/` contains only `.gitkeep` → `ensure_binary.sh` + `download.sh` do **NOT** exist yet
  (owned by P2.M3.T1.S1/S2, both Planned). Entrypoint MUST guard their absence.
- `docs/` does **NOT** exist at repo root → this task CREATES `docs/CONFIGURATION.md`.
- A plan-level draft exists at `plan/001_0c8587f91cb2/docs/CONFIGURATION.md` (palette-focused) to draw from.

## 2. Version / binary / packaging (verified `build.zig.zon`)
- `.version = "0.1.0"`; exe `.name = "tmux-2html"`.
- `.paths` includes `"scripts"` AND `"tmux-2html.tmux"` → both are packaged with the plugin.
- Layout assumption (PRD §9.1): plugin installed at `$TMUX_PLUGIN_MANAGER_PATH/tmux-2html`, with
  `bin/tmux-2html` (built/downloaded) and `scripts/{ensure_binary,download}.sh` siblings of `tmux-2html.tmux`.

## 3. Who reads @tmux-2html-* options (verified `src/cli.zig` + P2M1T2S1 PRP)
- `cli.PaneOpts` (src/cli.zig:70): `target,visible,full,history=50000,font="monospace",output,open`.
  **NO `--output-dir`, NO `--palette`** flag. → the pane binary reads `@tmux-2html-output-dir` and
  `@tmux-2html-history-limit` ITSELF at runtime via `tmux show-option` (capture.resolveOutputDir /
  capture.queryOption, per P2M1T2S1 PRP Task 3). font/open come from PaneOpts defaults / flags.
- **Consequence:** the entrypoint reads+exports ALL 8 options (contract requirement + to drive binding-key
  resolution), but pane does NOT need them passed on its CLI — it re-reads output-dir/history-limit itself.
  T2 bindings therefore interpolate ONLY `$TMUX_2HTML_BIN` + the key vars into `bind-key` strings.

## 4. Palette cache path (verified `src/palette.zig:240,372`)
- `${XDG_CACHE_HOME:-$HOME/.cache}/tmux-2html/palette` (XDG_CACHE_HOME honored only if set+non-empty+absolute).
- This is the path the T1.S2 (auto-sync popup) seam must test for existence. POSIX form:
  `cache_home=${XDG_CACHE_HOME:-$HOME/.cache}; palette_cache="$cache_home/tmux-2html/palette"`.

## 5. tmux facts (verified `research_tmux.md` + `findings §3`)
- `show-option -gqv @opt` → `-g` global, `-q` quiet (**empty string, NOT error, on unset**), `-v` value-only.
  `@` = user option (arbitrary string). ⇒ contract's `... || echo default` is WRONG for the unset case
  (−q returns empty, exit 0); use an explicit `-n` test or `${var:-default}`.
- `run-shell` children: NO /dev/tty, but `$TMUX` + `$TMUX_PANE` set. ⇒ `tmux` calls inside the script
  (show-option/bind-key/display-message) connect to the right server automatically.
- `tmux run-shell` is **ASYNC** (background; returns immediately) ⇒ cannot synchronously branch on its exit
  code. ⇒ "on failure skip binding" (PRD §9.1 step 2 / §10 step 4) requires a **synchronous** invocation
  of ensure_binary.sh when the binary is absent. Rationale documented in PRP §"Acquisition strategy".
- `display-popup -E -w 100% -h 100% "<cmd>"` → real pty, closes on exit (tmux ≥ 3.2; we have 3.6b). Used by
  the T1.S2 auto-sync seam and the T2.S2 region binding.
- Formats `#{pane_id}`, `#{pane_width}`, `#{pane_height}` expand in `bind-key`/`run-shell` command strings.
- `C-o` default = `rotate-window` in stock tmux (research_tmux §6); PRD §9.2 note calls it a "debug
  display-message" in THIS user's live config. Either way: setting region-key `C-o` OVERRIDES it. Note stands.

## 6. Exported-var reachability GOTCHA (critical design note)
- Shell vars `export`ed inside the sourced `tmux-2html.tmux` do **NOT** reliably reach later `run-shell`
  children spawned by `bind-key` (those inherit the tmux SERVER env, not the transient source-shell env).
- ⇒ T2 must interpolate resolved values (`$TMUX_2HTML_BIN`, `$full_key`, …) **directly into the bind-key
  command strings at source time** (vars ARE in scope during sourcing). The binary reads output-dir/
  history-limit/open/font itself at runtime. ⇒ the entrypoint's `export` is for the entrypoint's OWN
  binding-generation scope + any direct child (ensure_binary.sh), not for runtime propagation.

## 7. POSIX-sh portability (checklist for the loader; must run under dash/ash/bash-as-sh)
- Use `[ ]` not `[[ ]]`; `command -v` not `which`; `$( )` not backticks; quote ALL expansions
  `[ "$x" = "y" ]`; `${var:-default}` is POSIX; NO arrays; NO `==` (use `=`); `printf` over `echo -n`.
- Do **NOT** `set -e` inside a sourced script (a failed `tmux show-option`/`[ -x ]` would abort the user's
  tmux source). Guard explicitly with `if`/`||`. The contract's #1 hard rule: a missing binary must never
  crash the user's tmux.
- `${BASH_SOURCE[0]}` is a bashism; derive plugin_dir from `$TMUX_PLUGIN_MANAGER_PATH/tmux-2html` (TPM
  convention) instead.

## 8. Acquisition strategy DECISION (sync fast-path + sync acquire-if-absent)
1. **Fast probe** (instant, common case after first install): `[ -x "$TMUX_2HTML_BIN/tmux-2html" ]` → ready.
2. **Acquire** (only when absent/stale): synchronous `sh "$plugin_dir/scripts/ensure_binary.sh"`; branch on
   `$?` → on non-zero, `tmux display-message "tmux-2html: install failed (see README)"` + set `binary_ready=0`
   (T2 will skip `bind-key`). Guard `[ -f ensure_binary.sh ]` first (it doesn't exist yet → notice + ready=0).
3. Non-blocking rationale: TPM already runs the whole `.tmux` via `run-shell` (background); synchronous work
   inside it delays only binding setup, never freezes the user's server. After first install the fast-path
   is instant. This is the robust realization of PRD "on failure skip binding" (async run-shell can't decide).

## 9. Sibling seams (what T1.S1 must EXPORT/leave so siblings plug in WITHOUT restructuring)
- EXPORT for T2 (bindings, P2.M2.T2.S1/S2): `TMUX_2HTML_BIN`, `full_key`, `region_key`, `visible_key`,
  `plugin_dir`. Plus a labeled `## Bindings` section (TODO stub) where T2 adds `tmux bind-key …`.
- EXPORT/seam for T1.S2 (auto-sync popup): the palette-cache existence test + a labeled
  `## Palette auto-sync` section (TODO stub) for `tmux display-popup -E -w 100% -h 100% "… sync-palette …"`.
- The `.last-output` sidecar (`$TMUX_2HTML_BIN/.last-output`, PRD §9.3) is owned by T2.S2 — T1.S1 only
  ensures `$TMUX_2HTML_BIN` is resolved/exported.

## 10. docs/CONFIGURATION.md scope
- PRIMARY deliverable: the full `@tmux-2html-*` options table (defaults + meanings) verbatim-aligned to
  PRD §9.2, + the `C-o` override note + a short "how to set options" intro (`set -g @tmux-2html-foo "v"`
  before `run '~/.tmux/plugins/tpm/tpm'`). Brief palette-cache cross-reference (do NOT duplicate the full
  sync-palette doc — that lives elsewhere / P4.M2.T1.S2 sweep).
- Source to adapt from: `plan/001_0c8587f91cb2/docs/CONFIGURATION.md` (palette prose) + PRD §9.2 table.
