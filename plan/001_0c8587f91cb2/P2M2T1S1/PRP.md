name: "P2.M2.T1.S1 — tmux-2html.tmux entrypoint: resolve BIN, ensure binary, read @tmux-2html-* options + docs/CONFIGURATION.md"
description: |

---

## Goal

**Feature Goal**: A POSIX-sh `tmux-2html.tmux` loader that, when TPM sources it at load, (1) resolves
`TMUX_2HTML_BIN` + the plugin dir, (2) **gracefully** acquires the binary via `scripts/ensure_binary.sh`
when it is missing/stale — never crashing the user's tmux and skipping binding on failure, (3) reads **all
eight** `@tmux-2html-*` user options with correct defaults and exports them as the seam the sibling
binding/popup tasks consume, and (4) is documented by a new `docs/CONFIGURATION.md` that is the primary
config surface for the full options table.

**Deliverable**:
1. `tmux-2html.tmux` (currently **0 bytes**) — FILLED with a portable POSIX-sh loader: BIN/plugin-dir
   resolution, a guarded binary-acquisition block, an option-reader that reads every `@tmux-2html-*` option
   with the PRD §9.2 default, an `export` of the resolved values, an optional `TMUX_2HTML_DEBUG` test seam,
   and **clearly-labeled stub sections** for the sibling tasks (T2 bindings, T1.S2 auto-sync popup) to fill.
2. `docs/CONFIGURATION.md` (NEW; `docs/` does not exist yet) — the full `@tmux-2html-*` options table
   (defaults + meanings + the `C-o` override note) + a short "how to set options" intro + a brief
   palette-cache cross-reference.

**Success Definition**:
- Sourcing `tmux-2html.tmux` inside a real tmux (3.6b) with **no** options set and **no** binary present
  **succeeds without error** and resolves every option to its PRD §9.2 default (verifiable via the
  `TMUX_2HTML_DEBUG=<file>` seam).
- With overrides set (`set -g @tmux-2html-font "Fira Code"`, `@tmux-2html-region-key "C-S-o"`, …) the
  resolved values reflect the overrides.
- With `TMUX_2HTML_BIN=/nonexistent/bin` (binary absent) **and** `scripts/ensure_binary.sh` absent, sourcing
  still returns success (exit 0) and emits exactly one `display-message`; no tmux error, no broken state.
- `sh -n tmux-2html.tmux` passes; `shellcheck -s sh` (if available) reports no POSIX-portability errors;
  the script contains **no bashisms** (`[[`, `==`, arrays, `set -e`).
- `docs/CONFIGURATION.md` documents all 8 options with defaults matching PRD §9.2 verbatim, the `C-o`
  override note, and how to set them.

## Why

- The entrypoint is the **spine** of the TPM plugin (PRD §9.1). It is the first thing that runs and the
  thing every sibling task (bindings T2, auto-sync T1.S2) plugs into. Getting the option-resolution +
  binary-acquisition contract right here is what makes the rest of P2.M2 composable.
- The hard rule (contract #1): **a missing binary must never crash the user's tmux.** tmux sources the plugin
  on every config load / `prefix I`; an unguarded failure bricks the user's session. This PRP makes every
  step defensive (explicit `if`/`||`, no `set -e`, existence guards).
- The `@tmux-2html-*` options are the **only** user-facing configuration surface for the plugin. They must
  be overridable and correctly defaulted; the docs are the primary place users learn them (PRD §9.2,
  "primary config doc surface").

## What

### Entrypoint behavior (`tmux-2html.tmux`, POSIX sh)

1. Resolve, in this order, **without crashing** if anything is missing:
   - `plugin_dir = "$TMUX_PLUGIN_MANAGER_PATH/tmux-2html"` (TPM install location; where `scripts/` live).
     If `TMUX_PLUGIN_MANAGER_PATH` is unset → emit one `display-message` and `return 0` (skip everything;
     do not crash).
   - `TMUX_2HTML_BIN`: env `$TMUX_2HTML_BIN` if set → else `@tmux-2html-binary-dir` option if non-empty →
     else `"$plugin_dir/bin"` (PRD §9.1 default).
2. **Binary acquisition** (sync fast-path + sync acquire-if-absent — see "Acquisition strategy"):
   - If `[ -x "$TMUX_2HTML_BIN/tmux-2html" ]` → ready, proceed.
   - Else if `[ -f "$plugin_dir/scripts/ensure_binary.sh" ]` → `sh "$plugin_dir/scripts/ensure_binary.sh"`
     synchronously; on non-zero exit → `tmux display-message "tmux-2html: install failed (see README)"`
     and set `binary_ready=0`.
   - Else (ensure_binary.sh absent — e.g. dev/incomplete install) → `tmux display-message
     "tmux-2html: installer missing (incomplete install)"` and `binary_ready=0`.
   - Never `set -e`; never `return` non-zero from the sourced script.
3. **Read options** — every `@tmux-2html-*` with its PRD §9.2 default, via a `read_opt <name> <default>`
   helper that uses an explicit `-n` test (NOT `|| echo` — see gotcha). Export each.
4. **Seams** for siblings (stubs, clearly labeled; not implemented here):
   - `## Bindings (P2.M2.T2.S1/S2)` — TODO block; `$TMUX_2HTML_BIN`, `$full_key`, `$region_key`,
     `$visible_key` are ready to consume.
   - `## Palette auto-sync popup (P2.M2.T1.S2)` — TODO block; palette-cache path test stub.
5. **Optional test seam**: if `TMUX_2HTML_DEBUG=<file>` is set, write `key=value` lines of the resolved vars
   to that file (harmless in prod when unset).

### `docs/CONFIGURATION.md` content

- Short intro: how to set a tmux-2html option (`set -g @tmux-2html-foo "value"` in `~/.tmux.conf` **before**
  `run '~/.tmux/plugins/tpm/tpm'`).
- The full options table (defaults + meanings), aligned verbatim to PRD §9.2.
- The `C-o` key-conflict / override note (PRD §9.2 callout) and how to preserve the old binding.
- A brief palette-cache cross-reference (location + that it's populated by `sync-palette` / auto-sync popup)
  — do NOT duplicate the full sync-palette doc.

### Success Criteria

- [ ] `tmux-2html.tmux` sources cleanly (exit 0) under tmux 3.6b in all three paths: defaults, overrides,
      missing-binary.
- [ ] All 8 options resolve to PRD §9.2 defaults when unset; honor overrides when set.
- [ ] A missing binary + missing `ensure_binary.sh` ⇒ exactly one `display-message`, no crash, `binary_ready=0`.
- [ ] `sh -n` passes; no bashisms; `shellcheck -s sh` clean (or N/A).
- [ ] `docs/CONFIGURATION.md` exists with all 8 options + defaults + `C-o` override note + how-to-set intro.
- [ ] Sibling seams (Bindings, Palette auto-sync) are present as labeled stubs consuming the exported vars.

## All Needed Context

### Context Completeness Check

_Passes the "No Prior Knowledge" test_: every tmux fact (show-option flags, run-shell async, display-popup)
is cited to the in-repo verified architecture; the option table + defaults come verbatim from PRD §9.2; the
binary's own option-reading is pinned to `src/cli.zig:70` + the P2.M1.T2.S1 PRP; the palette-cache path to
`src/palette.zig:240,372`; the version/binary/packaging to `build.zig.zon`; and the validation commands use
the locally-installed tmux 3.6b with a throwaway socket. An implementer who has never seen this codebase can
build it from this PRP + the cited files.

### Documentation & References

```yaml
# MUST READ — in-repo authoritative sources
- file: PRD.md
  why: §9.1 entrypoint responsibilities (resolve BIN; ensure binary; read options; bind keys; auto-sync);
       §9.2 the OPTIONS TABLE (verbatim defaults + meanings + the C-o override note); §9.3 bindings (the
       sibling that consumes this task's exports); §10 ensure_binary.sh failure contract (step 4: "Any
       failure → display-message 'install failed (see README)' and skip binding"); §13 edge cases
       (concurrent-run filenames, history cap).
  section: "§9.1", "§9.2", "§9.3", "§10", "§13"
- file: plan/001_0c8587f91cb2/architecture/findings_and_corrections.md
  why: §3 "tmux integration facts (verified)" — show-option -gqv @opt returns EMPTY on unset (-q, not an
       error); run-shell children have NO /dev/tty but $TMUX/$TMUX_PANE ARE set (so tmux calls inside the
       script reach the server); display-popup -E -w 100% -h 100% is a real pty (≥3.2); @ user options.
  section: "§3"
- file: plan/001_0c8587f91cb2/architecture/research_tmux.md
  why: Claim 5 (show-option -gqv semantics), Claim 3 (run-shell: no tty, $TMUX set), Claim 2 (display-popup
       is a real pty), Claim 6 (C-o default = rotate-window ⇒ override note stands), Claim 7 (display-popup
       requires ≥3.2). These are the load-bearing facts for the loader.
  section: "Claim 2", "Claim 3", "Claim 5", "Claim 6", "Claim 7"
- file: plan/001_0c8587f91cb2/architecture/system_context.md
  why: §1 the two-layer diagram (TPM plugin shell layer → Zig binary); confirms the entrypoint's place and
       that it invokes the binary via run-shell / display-popup.
  section: "§1", "§3 (capture/palette/render contracts)"
- file: plan/001_0c8587f91cb2/P2M1T2S1/PRP.md
  why: CONTRACT for what the pane binary does at runtime — it reads @tmux-2html-output-dir and
       -history-limit ITSELF via `tmux show-option` (capture.resolveOutputDir / capture.queryOption,
       Task 3). ⇒ the entrypoint does NOT need to pass output-dir/history-limit on the pane CLI; it reads
       them only to satisfy the contract + drive binding-key resolution. Do not duplicate that work.
  section: "Task 3 (capture.resolveOutputDir / queryOption)", "Known Gotchas"
- file: plan/001_0c8587f91cb2/docs/CONFIGURATION.md
  why: existing PLAN-LEVEL draft of the config doc (palette-focused prose). Adapt its palette section as the
       brief cross-reference; the NEW repo-level docs/CONFIGURATION.md must additionally carry the full
       @tmux-2html-* options table (the primary deliverable for this task).
  section: whole file

# Consumed code symbols (REUSE — do NOT reimplement)
- file: src/cli.zig:70              # pub const PaneOpts { target,visible,full,history=50000,font="monospace",output,open }
  why: PROOF the binary has NO --output-dir / --palette flag ⇒ it reads @tmux-2html-output-dir and
       -history-limit itself at runtime (see P2M1T2S1 PRP). Lets the entrypoint skip passing them.
- file: src/palette.zig:240,372     # cache path = ${XDG_CACHE_HOME:-$HOME/.cache}/tmux-2html/palette
  why: the EXACT path the T1.S2 auto-sync seam must test for existence (XDG_CACHE_HOME honored only if
       set+non-empty+absolute). Mirror that rule in the sh stub.
- file: build.zig.zon               # .version="0.1.0"; exe name "tmux-2html"; .paths incl. "scripts" + "tmux-2html.tmux"
  why: confirms the binary name + that scripts/ and the loader are packaged together (plugin layout:
       plugin_dir/{tmux-2html.tmux, scripts/, bin/}). NOT needed for version-matching here (that's
       ensure_binary.sh's job, P2.M3.T1.S1).

# External (stable, primary)
- url: https://man.openbsd.org/tmux#OPTIONS
  why: `show-option` flags — `-g` (global), `-q` (quiet ⇒ empty, not error, on unset), `-v` (value only);
       `@` user options are stored verbatim as strings.
  critical: with `-q`, an UNSET option prints nothing and exits 0 — so the contract's `... || echo default`
            idiom is WRONG for the unset case; use an explicit `[ -n ]` test or `${var:-default}`.
- url: https://man.openbsd.org/tmux#COMMANDS            # run-shell, display-message, display-popup, bind-key
  why: run-shell is ASYNC (cannot branch on its exit code synchronously); display-message `-d` duration /
       default status-line target; display-popup `-E` close-on-exit, `-w/-h 100%`.
- url: https://github.com/tmux-plugins/tpm              # TMUx Plugin Manager: how .tmux is sourced
  why: TPM runs each plugin's `.tmux` via run-shell at load; sets TMUX_PLUGIN_MANAGER_PATH to the plugins
       root. ⇒ tmux calls inside the loader reach the live server; plugin_dir = $TPMPM/tmux-2html.
```

### Current Codebase tree (relevant subset)

```bash
tmux-2html.tmux       # 0 bytes — THIS TASK FILLS IT (POSIX sh loader)
build.zig.zon         # .version="0.1.0"; .paths incl. "scripts","tmux-2html.tmux"  (packaged together)
scripts/              # ONLY .gitkeep — ensure_binary.sh/download.sh do NOT exist yet (P2.M3)
src/cli.zig           # PaneOpts:70 (NO --output-dir/--palette ⇒ binary reads options itself)
src/palette.zig       # cache path 240/372 = ${XDG_CACHE_HOME:-$HOME/.cache}/tmux-2html/palette
PRD.md                # §9.1–§9.3, §10, §13
docs/                 # DOES NOT EXIST — THIS TASK CREATES docs/CONFIGURATION.md
plan/001_0c8587f91cb2/docs/CONFIGURATION.md   # plan-level draft (palette prose) — adapt, don't copy wholesale
plan/001_0c8587f91cb2/architecture/{findings_and_corrections,research_tmux,system_context,tui_region}.md
```

### Desired Codebase tree with file responsibilities

```bash
tmux-2html.tmux       # FILLED. POSIX sh loader:
                      #   - resolve plugin_dir + TMUX_2HTML_BIN (guarded)
                      #   - acquire binary (sync fast-path + sync ensure_binary.sh-if-absent; never crash)
                      #   - read_opt helper + read ALL 8 @tmux-2html-* options w/ PRD §9.2 defaults; export
                      #   - optional TMUX_2HTML_DEBUG=<file> test seam
                      #   - labeled stub sections: "## Bindings (P2.M2.T2)" + "## Palette auto-sync (P2.M2.T1.S2)"
docs/
  CONFIGURATION.md    # NEW. Full @tmux-2html-* options table (defaults+meanings) + C-o override note +
                      #   how-to-set intro + brief palette-cache cross-reference. PRIMARY config doc surface.
# build.zig.zon: NO CHANGE (tmux-2html.tmux + scripts already in .paths; docs/ is fine outside .paths).
```

### Known Gotchas of our codebase & Library Quirks

```sh
# CRITICAL (hard rule): a missing binary must NEVER crash the user's tmux. Do NOT `set -e` in this sourced
# script (a failing `tmux show-option` / `[ -x ]` would abort the user's `source-file`). Guard EVERY step
# with `if`/`||` and end failure paths with `return 0` (sourced scripts return, they don't exit).

# GOTCHA: `show-option -gqv @opt` prints EMPTY and exits 0 for an UNSET option (the -q flag), so the
# contract's example `tmux show-option -gqv @tmux-2html-font || echo monospace` does NOT apply the default
# on unset (|| never fires). Use an explicit non-empty test or ${var:-default}:
#     v=$(tmux show-option -gqv @tmux-2html-font 2>/dev/null); font=${v:-monospace}

# GOTCHA: `tmux run-shell` is ASYNC (background; returns immediately) ⇒ you CANNOT synchronously branch on
# its exit code. PRD §9.1/§10 "on failure skip binding" therefore needs ensure_binary.sh invoked
# SYNCHRONOUSLY (`sh "$plugin_dir/scripts/ensure_binary.sh"`) so `$?` is decidable. TPM already runs the
# whole .tmux under run-shell, so this does not freeze the user's tmux server (only delays binding setup).

# GOTCHA: `export`ed shell vars do NOT reach later `run-shell` children spawned by `bind-key` (they inherit
# the tmux SERVER env, not the transient source-shell env). ⇒ T2 must interpolate $TMUX_2HTML_BIN / key vars
# DIRECTLY into the bind-key command strings at source time. The binary re-reads output-dir/history-limit/
# open/font itself via show-option at runtime (src/cli.zig:70 has no --output-dir flag). So the entrypoint's
# export is for its OWN binding-generation scope + ensure_binary.sh, NOT runtime propagation.

# GOTCHA: ensure_binary.sh does NOT exist yet (P2.M3.T1.S1, Planned). MUST guard `[ -f ... ]` before invoking
# it; absence ⇒ display-message + binary_ready=0 (do not crash). Same defensive stance for download.sh.

# GOTCHA: POSIX portability (must run under dash/ash/bash-as-sh): use `[ ]` not `[[ ]]`; `=` not `==`;
# `command -v` not `which`; `$( )` not backticks; quote every expansion `[ "$a" = "$b" ]`; `${var:-default}`
# is POSIX; NO arrays; NO `${BASH_SOURCE[0]}` (derive plugin_dir from $TMUX_PLUGIN_MANAGER_PATH instead).

# GOTCHA: XDG absolute-only rule (mirrors src/palette.zig:361 cacheBase): honor XDG_DATA_HOME / XDG_CACHE_HOME
# only if set, non-empty, AND absolute; else fall back to $HOME/.... The entrypoint's output-dir default and
# the auto-sync cache test must apply the same rule so they agree with the binary.
```

## Implementation Blueprint

### Acquisition strategy (the one non-obvious design decision — read this)

The contract says "`run-shell` scripts/ensure_binary.sh if the binary is missing; on failure skip binding".
`tmux run-shell` is **asynchronous** — it cannot drive a synchronous bind/skip decision. The robust
realization (non-blocking + decidable):

1. **Fast probe** (instant; the common case after first install): `[ -x "$TMUX_2HTML_BIN/tmux-2html" ]` →
   binary ready; skip acquisition entirely. This makes every reload after first install instant.
2. **Acquire** (only when the probe fails): `sh "$plugin_dir/scripts/ensure_binary.sh"` **synchronously**,
   then branch on `$?`. ensure_binary.sh itself does the existence + `--version` match (PRD §10 step 1) and
   is idempotent. On non-zero → `tmux display-message "tmux-2html: install failed (see README)"` + `binary_ready=0`
   (T2 will skip `bind-key`). Guard `[ -f "$plugin_dir/scripts/ensure_binary.sh" ]` first.
3. **Why non-blocking**: TPM already runs the entire `.tmux` via `run-shell` (background). Synchronous work
   *inside* the loader therefore delays only the binding-setup tail; it never freezes the user's tmux server
   or blocks `source-file`. First install takes time regardless (build/download); subsequent loads hit the
   instant fast-path. This satisfies PRD §9.1 step 2 + §10 step 4 literally ("on failure … skip binding").

`ensure_binary.sh` owns the version-match against `build.zig.zon`'s `0.1.0` (P2.M3.T1.S1). The entrypoint
does **not** need a version constant; it only triggers acquisition and consumes the exit code.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: FILL tmux-2html.tmux — header + POSIX hygiene + plugin_dir/BIN resolution (guarded)
  - SHEBANG: `#!/usr/bin/env sh` (portable; TPM runs it with sh regardless, but be explicit).
  - HEADER comment: one-line purpose + "sourced by TPM; safe to re-source".
  - NO `set -e`. (Hard rule: a sourced script must never abort the user's tmux on a failing command.)
  - plugin_dir resolution (TPM convention):
      if [ -z "${TMUX_PLUGIN_MANAGER_PATH:-}" ]; then
          tmux display-message "tmux-2html: TMUX_PLUGIN_MANAGER_PATH unset; install via TPM"
          return 0 2>/dev/null || exit 0   # `return` when sourced; `exit` fallback if exec'd
      fi
      plugin_dir="$TMUX_PLUGIN_MANAGER_PATH/tmux-2html"
  - TMUX_2HTML_BIN resolution (env → option → default):
      if [ -n "${TMUX_2HTML_BIN:-}" ]; then :;
      elif bin_opt=$(tmux show-option -gqv @tmux-2html-binary-dir 2>/dev/null) && [ -n "$bin_opt" ]; then
          TMUX_2HTML_BIN=$bin_opt;
      else TMUX_2HTML_BIN="$plugin_dir/bin"; fi
  - export plugin_dir TMUX_2HTML_BIN     # consume-able by T2 + ensure_binary.sh
  - FOLLOW: POSIX-sh checklist (Gotchas). NAMING: snake_case shell vars.

Task 2: Binary acquisition block (sync fast-path + sync acquire-if-absent; never crash)
  - binary_ready=1
  - if [ -x "$TMUX_2HTML_BIN/tmux-2html" ]; then
        : # common case: ready, nothing to do
    elif [ -f "$plugin_dir/scripts/ensure_binary.sh" ]; then
        # SYNCHRONOUS so $? is decidable (run-shell is async; see Acquisition strategy).
        if ! sh "$plugin_dir/scripts/ensure_binary.sh" "$TMUX_2HTML_BIN" ; then
            tmux display-message "tmux-2html: install failed (see README)"
            binary_ready=0
        fi
    else
        # ensure_binary.sh absent (dev / incomplete install). Do NOT crash.
        tmux display-message "tmux-2html: installer missing (incomplete install)"
        binary_ready=0
    fi
  - export binary_ready
  - NOTE: passing "$TMUX_2HTML_BIN" as $1 to ensure_binary.sh is a courtesy; the exact arg/env contract is
    owned by P2.M3.T1.S1. If that task prefers env, ensure_binary.sh can read $TMUX_2HTML_BIN (we export it).
    Keep this call site the single integration point so P2.M3 can adjust the signature in one place.
  - GUARD: every branch ends gracefully; no `return` non-zero; the sourced script always returns 0.

Task 3: Option reader + read ALL 8 @tmux-2html-* options with PRD §9.2 defaults
  - read_opt helper (POSIX; -n test, NOT `|| echo`):
      read_opt() {  # $1 = option name (e.g. @tmux-2html-font), $2 = default
          _v=$(tmux show-option -gqv "$1" 2>/dev/null)
          if [ -n "$_v" ]; then printf '%s' "$_v"; else printf '%s' "$2"; fi
      }
  - KEYS (drive binding generation in T2):
      full_key=$(read_opt @tmux-2html-full-key O)
      region_key=$(read_opt @tmux-2html-region-key C-o)
      visible_key=$(read_opt @tmux-2html-visible-key "")    # empty default ⇒ unbound (T2 binds only if non-empty)
  - BEHAVIOR options (the binary re-reads these itself; exported here for the contract + any wrapper):
      open=$(read_opt @tmux-2html-open on)
      font=$(read_opt @tmux-2html-font monospace)
      history_limit=$(read_opt @tmux-2html-history-limit 50000)
  - output_dir with XDG absolute-only default (mirror src/palette.zig:361 rule; binary is authoritative but
    keep them in agreement):
      output_dir=$(read_opt @tmux-2html-output-dir "")
      if [ -z "$output_dir" ]; then
          data_home=$HOME/.local/share
          if [ -n "${XDG_DATA_HOME:-}" ] && [ "${XDG_DATA_HOME#/}" != "$XDG_DATA_HOME" ] && [ -n "$XDG_DATA_HOME" ]; then
              data_home=$XDG_DATA_HOME      # set, non-empty, AND absolute (starts with /)
          fi
          output_dir="$data_home/tmux-2html"
      fi
  - binary_dir=$TMUX_2HTML_BIN   # @tmux-2html-binary-dir default = $TMUX_2HTML_BIN (already folded in Task 1)
  - export full_key region_key visible_key open font history_limit output_dir binary_dir
  - GOTCHA: `_v`/`_` helper-local vars — prefix with `_` and don't `export` them (keep namespace clean).

Task 4: Optional TMUX_2HTML_DEBUG test seam + sibling stub sections
  - DEBUG SEAM (harmless when unset; makes the integration test assertable):
      if [ -n "${TMUX_2HTML_DEBUG:-}" ]; then
          {
              printf 'plugin_dir=%s\n' "$plugin_dir"
              printf 'TMUX_2HTML_BIN=%s\n' "$TMUX_2HTML_BIN"
              printf 'binary_ready=%s\n' "$binary_ready"
              printf 'full_key=%s\n' "$full_key"
              printf 'region_key=%s\n' "$region_key"
              printf 'visible_key=%s\n' "$visible_key"
              printf 'output_dir=%s\n' "$output_dir"
              printf 'open=%s\n' "$open"
              printf 'font=%s\n' "$font"
              printf 'history_limit=%s\n' "$history_limit"
              printf 'binary_dir=%s\n' "$binary_dir"
          } > "$TMUX_2HTML_DEBUG"
      fi
  - SIBLING STUB — Bindings (P2.M2.T2.S1/S2 owns this; DO NOT implement, just leave the labeled seam):
      # ------------------------------------------------------------------
      # ## Bindings (prefix table) — P2.M2.T2.S1 (O + visible) / P2.M2.T2.S2 (C-o region)
      # Consumes: $TMUX_2HTML_BIN, $full_key, $region_key, $visible_key, $binary_ready
      # Pattern: interpolate the resolved values DIRECTLY into bind-key command strings, e.g.
      #   [ "$binary_ready" = 1 ] && tmux bind-key "$full_key" run-shell \
      #       "$TMUX_2HTML_BIN/tmux-2html pane --full --target '#{pane_id}'"
      # The binary reads output-dir/history-limit/open/font itself via show-option — do NOT pass them.
      # ------------------------------------------------------------------
  - SIBLING STUB — Palette auto-sync popup (P2.M2.T1.S2 owns this; DO NOT implement):
      # ------------------------------------------------------------------
      # ## Palette auto-sync popup (one-time) — P2.M2.T1.S2
      # Cache path (mirror src/palette.zig:240): ${XDG_CACHE_HOME:-$HOME/.cache}/tmux-2html/palette
      #   cache_home=${XDG_CACHE_HOME:-$HOME/.cache}; palette_cache="$cache_home/tmux-2html/palette"
      #   if [ ! -f "$palette_cache" ]; then
      #       tmux display-popup -E -w 100% -h 100% "$TMUX_2HTML_BIN/tmux-2html sync-palette --force"
      #   fi
      # ------------------------------------------------------------------
  - End the file cleanly (no trailing `exit` that would kill the sourcing shell).

Task 5: CREATE docs/CONFIGURATION.md — the primary config doc surface
  - TITLE + one-paragraph intro: tmux-2html is configured via tmux user options (`@tmux-2html-*`). Set them
    in ~/.tmux.conf with `set -g @tmux-2html-<name> "value"` BEFORE the TPM run line
    (`run '~/.tmux/plugins/tpm/tpm'`). Options are read when the plugin loads.
  - THE OPTIONS TABLE (verbatim-aligned to PRD §9.2): all 8 rows with Option | Default | Meaning. Use the
    exact defaults: full-key=O, region-key=C-o, visible-key=(empty/unbound), output-dir=
    ${XDG_DATA_HOME:-~/.local/share}/tmux-2html, open=on, font=monospace, history-limit=50000,
    binary-dir=$TMUX_2HTML_BIN.
  - THE C-o OVERRIDE NOTE (PRD §9.2 callout): C-o overrides the existing prefix-table binding (rotate-window
    in stock tmux; a debug display-message in this user's live config). To preserve it, set a different key,
    e.g. `set -g @tmux-2html-region-key C-S-o`. Also note visible-key is empty by default ⇒ visible-only
    capture is unbound until the user sets it.
  - A "How options are read" note: the loader reads each via `tmux show-option -gqv`; an unset option falls
    back to the default. The pane/region binary re-reads output-dir/history-limit/open/font at runtime too,
    so changing an option and reloading tmux applies it.
  - A brief PALETTE CACHE cross-reference (location
    ${XDG_CACHE_HOME:-$HOME/.cache}/tmux-2html/palette; populated by `tmux-2html sync-palette` or the
    one-time auto-sync popup; honored XDG only if absolute). Do NOT duplicate the full sync-palette doc.
  - FOLLOW: the existing plan-level draft `plan/001_0c8587f91cb2/docs/CONFIGURATION.md` for prose tone on
    the palette section; but this repo-level file's PRIMARY content is the options table.
  - PLACEMENT: docs/CONFIGURATION.md (create the docs/ directory).
```

### Implementation Patterns & Key Details

```sh
# ===== the option-reader idiom (CORRECT; the contract's `|| echo` is wrong for unset — see Gotchas) =====
read_opt() {                                   # $1 = @tmux-2html-<name>, $2 = default
    _v=$(tmux show-option -gqv "$1" 2>/dev/null)
    if [ -n "$_v" ]; then printf '%s' "$_v"; else printf '%s' "$2"; fi
}
font=$(read_opt @tmux-2html-font monospace)    # unset → "monospace"; set → the value (spaces preserved)

# ===== never-crash sourcing guard (the hard rule) =====
# A sourced script must `return`, not `exit`. Use this idiom at every early-out:
some_guard || { tmux display-message "tmux-2html: <reason>"; return 0 2>/dev/null || exit 0; }
# `return 0 2>/dev/null` succeeds when sourced; the `|| exit 0` covers the rare exec'd case.

# ===== BIN precedence (env → option → default) =====
if [ -n "${TMUX_2HTML_BIN:-}" ]; then :
elif bin_opt=$(tmux show-option -gqv @tmux-2html-binary-dir 2>/dev/null) && [ -n "$bin_opt" ]; then
    TMUX_2HTML_BIN=$bin_opt
else
    TMUX_2HTML_BIN="$plugin_dir/bin"           # PRD §9.1 default
fi

# ===== acquisition is SYNCHRONOUS (run-shell is async — see Acquisition strategy) =====
if [ -x "$TMUX_2HTML_BIN/tmux-2html" ]; then :           # fast-path: ready
elif [ -f "$plugin_dir/scripts/ensure_binary.sh" ]; then
    sh "$plugin_dir/scripts/ensure_binary.sh" "$TMUX_2HTML_BIN" || {            # decidable $?
        tmux display-message "tmux-2html: install failed (see README)"; binary_ready=0; }
else
    tmux display-message "tmux-2html: installer missing (incomplete install)"; binary_ready=0
fi
```

### Integration Points

```yaml
TPM (sourcing):
  - TPM runs tmux-2html.tmux via run-shell at load; sets TMUX_PLUGIN_MANAGER_PATH.
  - tmux calls inside the loader (show-option/display-message/bind-key) reach the live server ($TMUX set).
SIBLING — P2.M2.T2.S1/S2 (bindings): consumes $TMUX_2HTML_BIN, $full_key, $region_key, $visible_key,
  $binary_ready. Interpolates them DIRECTLY into `tmux bind-key … run-shell "… pane/region …"` strings at
  source time (exported vars do NOT reach run-shell children). Does NOT pass output-dir/font/history-limit
  (the binary reads them). The `.last-output` sidecar ($TMUX_2HTML_BIN/.last-output) is T2.S2's concern.
SIBLING — P2.M2.T1.S2 (auto-sync popup): consumes $TMUX_2HTML_BIN; tests the palette cache at
  ${XDG_CACHE_HOME:-$HOME/.cache}/tmux-2html/palette; launches `tmux display-popup -E -w 100% -h 100%
  "$TMUX_2HTML_BIN/tmux-2html sync-palette --force"`.
SIBLING — P2.M3.T1.S1 (ensure_binary.sh): owns version-match vs build.zig.zon 0.1.0 + zig-build/download
  fallback + atomic rename. Entrypoint invokes it with "$TMUX_2HTML_BIN" as $1 (adjustable in one place).
BUILD/PACKAGE (build.zig.zon): NO CHANGE — "scripts" + "tmux-2html.tmux" already in .paths; docs/ is fine
  outside .paths (it is documentation, not a build input).
```

## Validation Loop

### Level 1: Syntax & Style (after writing the loader)

```bash
sh -n tmux-2html.tmux && echo "syntax OK"          # POSIX syntax check (mandatory)
# POSIX-portability lint (install if available; informational if not):
command -v shellcheck >/dev/null && shellcheck -s sh tmux-2html.tmux || echo "shellcheck N/A"
# Bashism scan (dash would reject these): expect ZERO hits.
grep -nE '\[\[|==|BASH_SOURCE|declare |local |let |\becho -n|~' tmux-2html.tmux || echo "no bashisms"
# Expected: "syntax OK"; shellcheck clean or N/A; "no bashisms".
```

### Level 2: Option-resolution logic (no live tmux needed — pure sh + a fake tmux)

```bash
# Stub `tmux` so the reader can be exercised without a server. Put a fake tmux first on PATH:
mkdir -p /tmp/t2h-fakebin
cat > /tmp/t2h-fakebin/tmux <<'EOF'
#!/usr/bin/env sh
# Fake tmux: echo canned option values for known names, empty for the rest (mimics -q on unset).
case "$*" in
  *@tmux-2html-font*)        printf 'Fira Code\n';;   # override
  *@tmux-2html-region-key*)  printf 'C-S-o\n';;        # override
  *)                          printf '';;               # unset => empty
esac
EOF
chmod +x /tmp/t2h-fakebin/tmux
# Extract+source just the read_opt + reads by defining TMUX_PLUGIN_MANAGER_PATH, a ready binary path, and
# pointing PATH at the stub; then dump the vars via the DEBUG seam:
TMUX_PLUGIN_MANAGER_PATH=/tmp \
TMUX_2HTML_BIN=/tmp/t2h-bin \
TMUX_2HTML_DEBUG=/tmp/t2h-unset.env \
PATH=/tmp/t2h-fakebin:$PATH sh ./tmux-2html.tmux 2>/dev/null || true
# Now unset the overrides to test DEFAULTS: a second stub that returns empty for everything:
cat > /tmp/t2h-fakebin/tmux <<'EOF'
#!/usr/bin/env sh
: # always empty (every option unset)
EOF
TMUX_2HTML_DEBUG=/tmp/t2h-defaults.env PATH=/tmp/t2h-fakebin:$PATH sh ./tmux-2html.tmux 2>/dev/null || true
echo "--- defaults ---"; cat /tmp/t2h-defaults.env
# Expected (defaults.env): full_key=O  region_key=C-o  visible_key=  font=monospace  open=on
#                         history_limit=50000  binary_dir=/tmp/t2h-bin
# Expected (unset/override env): font=Fira Code  region_key=C-S-o  (full_key=O, etc. default)
```

### Level 3: Integration (real tmux 3.6b, throwaway socket)

```bash
sock=t2h-it-$$
tmux -L "$sock" -f /dev/null new-session -d -s t2h
# 1) DEFAULTS path: no options set, no binary present, no ensure_binary.sh → must NOT crash (exit 0).
TMUX_2HTML_DEBUG=/tmp/t2h-it-defaults.env \
  tmux -L "$sock" source-file ./tmux-2html.tmux; echo "source-exit=$?"
grep -qx 'full_key=O'            /tmp/t2h-it-defaults.env && echo "full_key OK"
grep -qx 'region_key=C-o'        /tmp/t2h-it-defaults.env && echo "region_key OK"
grep -qx 'font=monospace'        /tmp/t2h-it-defaults.env && echo "font OK"
grep -qx 'history_limit=50000'   /tmp/t2h-it-defaults.env && echo "history OK"
grep -qx 'binary_ready=0'        /tmp/t2h-it-defaults.env && echo "no-binary handled OK"

# 2) OVERRIDES path:
tmux -L "$sock" set -g @tmux-2html-font "Fira Code"
tmux -L "$sock" set -g @tmux-2html-region-key "C-S-o"
tmux -L "$sock" set -g @tmux-2html-visible-key "v"
TMUX_2HTML_DEBUG=/tmp/t2h-it-over.env tmux -L "$sock" source-file ./tmux-2html.tmux
grep -qx 'font=Fira Code'   /tmp/t2h-it-over.env && echo "font override OK"
grep -qx 'region_key=C-S-o' /tmp/t2h-it-over.env && echo "region override OK"
grep -qx 'visible_key=v'    /tmp/t2h-it-over.env && echo "visible override OK"

# 3) GRACEFUL DEGRADATION: bogus BIN + missing ensure_binary.sh ⇒ exit 0, no server error.
tmux -L "$sock" clear-history 2>/dev/null  # drop messages
TMUX_2HTML_BIN=/nonexistent/bin tmux -L "$sock" source-file ./tmux-2html.tmux; echo "degrade-exit=$?"
# (Optional) confirm a display-message was emitted:
tmux -L "$sock" show-messages 2>/dev/null | grep -i 'tmux-2html' || echo "(message shown on status line)"

tmux -L "$sock" kill-server
# Expected: all three source-file calls exit 0; defaults/overrides/degradation assertions pass.
```

### Level 4: Docs validation

```bash
# docs/CONFIGURATION.md exists and carries the full table + the override note.
test -f docs/CONFIGURATION.md && echo "doc exists"
# all 8 options present:
for o in full-key region-key visible-key output-dir open font history-limit binary-dir; do
    grep -q "@tmux-2html-$o" docs/CONFIGURATION.md && echo "ok: $o" || echo "MISSING: $o"
done
# defaults present verbatim:
grep -q 'O' docs/CONFIGURATION.md && grep -q 'C-o' docs/CONFIGURATION.md && grep -q '50000' docs/CONFIGURATION.md
# the C-o override note:
grep -qi 'override' docs/CONFIGURATION.md && grep -qi 'C-S-o' docs/CONFIGURATION.md
# how-to-set intro:
grep -qi 'set -g' docs/CONFIGURATION.md
# Expected: all 8 options ok; defaults + override note + how-to-set present.
```

## Final Validation Checklist

### Technical Validation
- [ ] `sh -n tmux-2html.tmux` passes; no bashisms (`grep` Level 1 clean).
- [ ] `shellcheck -s sh` clean (or N/A).
- [ ] Level 2 fake-tmux: defaults + override resolution correct.
- [ ] Level 3 real-tmux: sources exit 0 in defaults / overrides / missing-binary paths.
- [ ] `docs/CONFIGURATION.md` passes Level 4 (all 8 options + defaults + override note + how-to-set).

### Feature Validation
- [ ] All 8 `@tmux-2html-*` options resolve to PRD §9.2 defaults when unset.
- [ ] Overrides (`font`, `region-key`, `visible-key`, …) are honored.
- [ ] Missing binary + missing `ensure_binary.sh` ⇒ one `display-message`, no crash, `binary_ready=0`.
- [ ] Sibling seams (`## Bindings`, `## Palette auto-sync`) present as labeled stubs; `$TMUX_2HTML_BIN` +
      key vars exported and ready to consume.
- [ ] `TMUX_2HTML_DEBUG` seam writes the resolved vars (test-only; harmless when unset).

### Code Quality Validation
- [ ] No `set -e`; every early-out uses `return 0 2>/dev/null || exit 0`; the sourced script never returns non-zero.
- [ ] POSIX-portable (`[ ]`, `=`, `command -v`, `$( )`, quoted expansions, `${var:-default}`, no arrays).
- [ ] `read_opt` uses the `-n` test (not the contract's `|| echo`) so unset ⇒ default.
- [ ] Acquisition is synchronous + guarded (run-shell async can't decide bind/skip; ensure_binary.sh absence guarded).
- [ ] No duplication of the binary's own option-reading (output-dir/history-limit passed nowhere on the pane CLI).
- [ ] docs/CONFIGURATION.md is the primary config surface; palette coverage is a brief cross-reference (no duplication).

### Documentation & Deployment
- [ ] `tmux-2html.tmux` has a clear header comment (purpose + "safe to re-source").
- [ ] Stub sections name the owning sibling task + the consumed vars (so T2/T1.S2 plug in without restructuring).
- [ ] `docs/CONFIGURATION.md` covers how to set options + the C-o override note (user-facing safety info).

---

## Anti-Patterns to Avoid

- ❌ Don't `set -e` in this sourced script — a failing `tmux show-option`/`[ -x ]` would abort the user's tmux `source-file`.
- ❌ Don't use `tmux run-shell ensure_binary.sh` for the acquisition if you need to branch on its result — it is ASYNC; invoke `sh ensure_binary.sh` synchronously (TPM already backgrounded the whole loader).
- ❌ Don't use the contract's `tmux show-option -gqv @opt || echo default` — `-q` makes unset return empty (exit 0), so `||` never fires; use the `-n` test / `${var:-default}`.
- ❌ Don't `export` vars expecting `bind-key … run-shell` children to inherit them — they won't (server env, not source-shell env). T2 interpolates values into the bind-key strings at source time.
- ❌ Don't pass `--output-dir`/`--font`/`--history` on the pane CLI from the binding — `src/cli.zig:70` has no such flags; the binary reads the options itself. (Double source of truth ⇒ drift.)
- ❌ Don't assume `scripts/ensure_binary.sh` exists — it doesn't yet (P2.M3). Guard `[ -f ]` or the loader crashes on every source.
- ❌ Don't hardcode the plugin name twice — derive `plugin_dir` from `$TMUX_PLUGIN_MANAGER_PATH/tmux-2html` (TPM convention), not from `dirname "$0"`/`$BASH_SOURCE` (non-POSIX / fragile when sourced).
- ❌ Don't implement bindings (T2) or the auto-sync popup (T1.S2) here — leave labeled stubs; this task is BIN + ensure + options + docs only.
- ❌ Don't add `docs/` or `tmux-2html.tmux` to `.gitignore`; don't touch `PRD.md`/`tasks.json`/`prd_snapshot.md`.

---

## Confidence Score: 8/10

The loader is small and every load-bearing tmux fact is verified in-repo (show-option `-q` semantics,
run-shell async/no-tty, display-popup, XDG rules) plus the live installed tmux 3.6b. The two residual risks
that keep this from 9–10: (1) the **sync-vs-async acquisition** decision deviates from the PRD's literal
"`run-shell`" wording — but it is the only way to satisfy "on failure skip binding" and is documented as a
justified, non-blocking realization (TPM already backgrounded the loader); (2) the entrypoint's
output-dir/font/history-limit `export` is partly redundant with the binary's own `show-option` reads —
deliberate (contract + binding-seam), but the implementer must NOT also pass them on the pane CLI (anti-
pattern). Both are mitigated by explicit tasks/gotchas above and a real-tmux Level-3 integration test.
