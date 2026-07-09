name: "P2.M2.T1.S2 — One-time palette auto-sync popup trigger (tmux-2html.tmux + docs/CONFIGURATION.md §Palette)"
description: |

---

## Goal

**Feature Goal**: Fill the labeled `## Palette auto-sync popup (one-time) — P2.M2.T1.S2` stub
in the already-implemented `tmux-2html.tmux` loader (produced by P2.M2.T1.S1) so that **on the
first plugin load, if no palette cache exists, the loader opens a short `tmux display-popup`
(a real pty, so OSC palette queries work) running `tmux-2html sync-palette`, then closes** — and
**skips** that popup on every subsequent load while the cache exists. The popup is the controlling
tty that `run-shell` (where bindings run) lacks, which is the entire reason it exists (PRD §6,
§9.1 step 4). Extend `docs/CONFIGURATION.md` §Palette with a Mode-A note documenting this
auto-sync behavior and the "sync-palette outside tmux captures the outer terminal palette" caveat.

**Deliverable** (at `/home/dustin/projects/tmux-2html/`):
1. **MODIFY `tmux-2html.tmux`** — REPLACE the existing `## Palette auto-sync popup (one-time) —
   P2.M2.T1.S2` stub block (a TODO comment) with a real, non-fatal implementation: compute the
   palette-cache path **mirroring `src/palette.zig` `cacheBase()`** (XDG absolute-only), then
   `if [ "$binary_ready" = 1 ] && [ ! -f "$palette_cache" ]` fire
   `tmux display-popup -E -w 50% -h 50% "$TMUX_2HTML_BIN/tmux-2html sync-palette"` (the exact
   item-contract command — **no `--force`**, **50%/50%**). Wrap with `2>/dev/null || :` so it is
   non-fatal. Append `palette_cache` / `palette_autosync` to the `TMUX_2HTML_DEBUG` seam.
2. **MODIFY `docs/CONFIGURATION.md`** — EXTEND the existing `## Palette cache` section (created by
   P2.M2.T1.S1) with the auto-sync mechanics + the outside-tmux palette caveat (Mode A).

**Success Definition**:
- First load with **no cache** + binary ready ⇒ the loader issues exactly one
  `tmux display-popup -E -w 50% -h 50% "$TMUX_2HTML_BIN/tmux-2html sync-palette"` (verifiable via
  a fake-`tmux` stub that records the command line).
- With a cache file present ⇒ the loader issues **no** `display-popup` (skipped).
- A relative or empty `XDG_CACHE_HOME` falls back to `$HOME/.cache` (mirrors the Zig
  `cacheBase()` rule) — cache presence is detected at the correct path.
- The popup call is **non-fatal**: `display-popup` failing (old tmux, no attached client,
  sync-palette non-zero exit) never aborts the loader — it sources/runs to exit 0.
- `sh -n tmux-2html.tmux` passes; `shellcheck -s sh tmux-2html.tmux` is clean (or N/A); no bashisms.
- `docs/CONFIGURATION.md` documents the auto-sync behavior + the outside-tmux caveat.

## Why

- **PRD §9.1 step 4 makes this a named entrypoint responsibility.** After resolving BIN, ensuring
  the binary, reading options + binding keys, the loader must "if no palette cache exists, trigger
  the one-time auto-sync popup (§6)."
- **The cache is otherwise never populated on a fresh install**, so every `render`/`pane` (P1.3/P2)
  would fall through `palette.resolve()` to the bundled default palette — wrong colors. The popup
  is the user-invisible bootstrap that captures the *real* terminal palette once.
- **`run-shell` (the binding context) has no `/dev/tty`** (research_tmux.md Claim 3, findings §3),
  so `sync-palette`/`queryColors` cannot run from a binding. `display-popup` is a **real pty**
  (Claim 2) where OSC 4/10/11 queries succeed — that is *why* the auto-sync uses a popup rather
  than a plain `run-shell`.
- **Non-fatal by contract**: the item says "Non-fatal if it fails." A fresh install must not have
  its tmux bricked by a popup that can't open (old tmux, headless/detached, unresponsive terminal).

## What

### Behavior (`tmux-2html.tmux`, the block that replaces the autosync stub)

1. **Compute the cache path**, mirroring `src/palette.zig` `cacheBase()` (XDG honored only if
   set + non-empty + ABSOLUTE; else `$HOME/.cache`):
   ```sh
   cache_home="$HOME/.cache"
   if [ -n "${XDG_CACHE_HOME:-}" ] && [ -n "$XDG_CACHE_HOME" ] \
       && [ "${XDG_CACHE_HOME#/}" != "$XDG_CACHE_HOME" ]; then
       cache_home=$XDG_CACHE_HOME
   fi
   palette_cache="$cache_home/tmux-2html/palette"
   ```
2. **One-time trigger** (PRD §9.1 step 4 + §6; the item-contract command verbatim):
   ```sh
   if [ "$binary_ready" = 1 ] && [ ! -f "$palette_cache" ]; then
       palette_autosync=1
       tmux display-popup -E -w 50% -h 50% \
           "$TMUX_2HTML_BIN/tmux-2html sync-palette" 2>/dev/null || :
   else
       palette_autosync=0
   fi
   ```
3. **Debug observability** (append after the §4 `>` write — no conflict; harmless when unset):
   ```sh
   if [ -n "${TMUX_2HTML_DEBUG:-}" ]; then
       { printf 'palette_cache=%s\n' "$palette_cache";
         printf 'palette_autosync=%s\n' "$palette_autosync"; } >> "$TMUX_2HTML_DEBUG"
   fi
   ```

### `docs/CONFIGURATION.md` content (Mode A, extends the existing `## Palette cache` section)

- Auto-sync mechanics: on first plugin load, if no cache exists, tmux-2html opens a
  `tmux display-popup` (a real terminal/pty, ~50%×50%) that runs `sync-palette` once and closes;
  subsequent loads skip it while the cache is present. It is non-fatal — if the popup cannot open
  or the query fails, rendering simply falls back to the bundled default palette.
- The outside-tmux caveat: the auto-sync popup runs **inside** tmux, so it captures the palette
  tmux *presents* to panes (the palette captures are rendered against). Running `sync-palette`
  *outside* tmux captures the outer terminal emulator's palette instead; the two can differ when
  tmux applies `terminal-overrides`, a custom `default-terminal`, or RGB features.

### Success Criteria

- [ ] No cache + binary ready ⇒ exactly one `display-popup -E -w 50% -h 50% "...sync-palette"`
      (no `--force`) is issued by the loader (asserted via fake-`tmux` stub).
- [ ] Cache present ⇒ **no** `display-popup` issued (skipped).
- [ ] Relative/empty `XDG_CACHE_HOME` ⇒ cache detected at `$HOME/.cache/tmux-2html/palette`.
- [ ] `display-popup` failure (no client / unknown command) ⇒ loader still sources/runs to exit 0.
- [ ] `sh -n` passes; no bashisms; `shellcheck -s sh` clean (or N/A).
- [ ] `docs/CONFIGURATION.md` §Palette documents auto-sync + the outside-tmux caveat.
- [ ] No Zig/build changes; PRD.md/tasks.json/prd_snapshot.md/.gitignore untouched; `## Bindings`
      stub left for P2.M2.T2.

## All Needed Context

### Context Completeness Check

_Passes the "No Prior Knowledge" test_: the exact stub block to replace is quoted verbatim (from
the live file); the item-contract command line is given verbatim; the cache-path rule is pinned to
`src/palette.zig` `cacheBase()` (set+non-empty+absolute); the consumed loader symbols
(`$binary_ready`, `$TMUX_2HTML_BIN`, the no-`set -e` rule, the `TMUX_2HTML_DEBUG` `>`-write
convention) are described from the live §1–§4; every load-bearing tmux fact (display-popup = real
pty; run-shell = no tty; `source-file` chokes on shell scripts; `run-shell` propagates `$TMUX`;
display-popup needs a client) is verified empirically against the installed tmux 3.6b on an
isolated socket (see `research/findings.md` §5). The fake-`tmux` test pattern is taken from the
predecessor P2.M2.T1.S1 PRP's Level 2.

### Documentation & References

```yaml
# MUST READ — the file this task edits (the stub to replace is quoted verbatim in research/findings.md §1)
- file: tmux-2html.tmux
  why: "ALREADY FILLED by P2.M2.T1.S1. Replace the `## Palette auto-sync popup (one-time) — P2.M2.T1.S2`
        stub block (the last block in the file) with the real implementation. Consumes $binary_ready
        (§2 export) and $TMUX_2HTML_BIN (§1 export). The §4 TMUX_2HTML_DEBUG block writes with `>`;
        this task APPENDS with `>>` after it (file order ⇒ safe). Do NOT touch §1–§4 or the
        `## Bindings` stub."
  pattern: "POSIX sh; no `set -e`; quoted expansions; `${var#/}` absolute-test; `[ ]` not `[[ ]]`."
  gotcha: "The stub SUGGESTS `-w 100% -h 100% ... --force`; the ITEM CONTRACT overrides it:
           `-w 50% -h 50% ... sync-palette` (no --force). See research/findings.md §2 reconciliation."

# MUST READ — the exact predecessor contract (what produces the loader you edit)
- file: plan/001_0c8587f91cb2/P2M2T1S1/PRP.md
  why: "Defines the loader's structure (§1–§4 + bindings stub + autosync stub), the no-crash rule,
        the read_opt/XDG-absolute-only idiom (§3 data_home — MIRROR it for cache_home), the
        binary_ready export, and the TMUX_2HTML_DEBUG `>` convention. The autosync stub there is the
        placeholder this task fills."
  section: "Task 4 (sibling stub for P2.M2.T1.S2)", "Known Gotchas (POSIX, XDG absolute-only)"

# MUST READ — the cache-path source of truth (mirror cacheBase() EXACTLY)
- file: src/palette.zig
  why: "cachePath() -> ${XDG_CACHE_HOME:-$HOME/.cache}/tmux-2html/palette; cacheBase() honors
        XDG_CACHE_HOME ONLY if set+non-empty+ABSOLUTE else falls back to $HOME/.cache
        (NoHomeDirectory if $HOME unset). The sh cache_home computation must match so the
        `[ ! -f ]` test looks at the SAME path the binary writes/reads."
  section: "cacheBase (~L358), cachePath (~L366)"

# MUST READ — what the popup actually runs (so the command string is right)
- file: plan/001_0c8587f91cb2/P1M2T2S1/PRP.md
  why: "`tmux-2html sync-palette` (no --force) with NO existing cache => acquires (queryColors) +
        writes cache + exit 0 (shouldRun(false,false)=true). So the auto-sync needs NO --force:
        the [ ! -f ] guard already guarantees no cache. Inside the display-popup pty, queryColors
        HAS a /dev/tty so it succeeds (exit 0); only under run-shell/pipe would it exit 2."
  section: "Behavior matrix", "shouldRun"

# MUST READ — the PRD authority for this behavior
- file: PRD.md
  why: "§9.1 step 4 (auto-sync popup after options/bindings); §6 (auto-sync on first plugin load
        if no cache exists; document that sync-palette outside tmux captures the outer terminal
        palette); §12 (runtime tmux >= 3.2 for display-popup); §0 (tests use ISOLATED named
        sockets — the plugin's own display-popup against the user's session is intended product
        behavior, NOT a §0 violation; tests must not touch the user's server)."
  section: "§0", "§6", "§9.1", "§12"

# MUST READ — verified tmux facts (load-bearing for correctness + testing)
- file: plan/001_0c8587f91cb2/architecture/research_tmux.md
  why: "Claim 2 (display-popup = real pty, -E close-on-exit, -w/-h %); Claim 3 (run-shell: no tty,
        $TMUX set); Claim 7 (display-popup requires >= 3.2). These justify WHY a popup (not run-shell)."
- file: plan/001_0c8587f91cb2/architecture/findings_and_corrections.md
  section: "§3 tmux integration facts"
  why: "Confirms display-popup = real pty (OSC works); run-shell no /dev/tty; user-options idiom."

# MUST READ — the doc this task extends (live file; already created by P2.M2.T1.S1)
- file: docs/CONFIGURATION.md
  why: "Has a `## Palette cache` section that already mentions the auto-sync popup in one sentence.
        This task EXTENDS it (does not duplicate the cache-format/sync-palette-flag reference, which
        the §Palette section already cross-links)."
- file: plan/001_0c8587f91cb2/docs/CONFIGURATION.md
  why: "Plan-level draft with the 'Inside tmux vs. outside tmux' caveat wording to adapt for the
        outside-tmux note (Mode A)."

# External (stable, primary)
- url: https://man.openbsd.org/tmux#COMMANDS            # display-popup, run-shell, source-file
  why: "display-popup -E (close on exit), -w/-h accept % of client; targets the current client.
        run-shell runs a shell command with $TMUX set (propagates to the server). source-file parses
        tmux commands (NOT shell) — verified empirically it rejects shell-style .tmux files."
  critical: "display-popup needs an attached client; against a detached test server it errors
             'no current client' — so the popup itself is manual-only; the decision+command string
             are tested via a fake-tmux stub (Level 2)."
- url: https://specifications.freedesktop.org/basedir-spec/latest/
  why: "XDG_CACHE_HOME honored only when absolute (the cacheBase() rule this task mirrors in sh)."
```

### Current Codebase tree (relevant subset)

```bash
tmux-2html.tmux        # FILLED by P2.M2.T1.S1 (7024 B). §1–§4 + bindings stub + autosync STUB. ← EDIT (replace autosync stub)
docs/CONFIGURATION.md  # Created by P2.M2.T1.S1 (3418 B). Has `## Palette cache` (brief).         ← EDIT (extend §Palette)
src/palette.zig        # cachePath()/cacheBase() = the path this task must mirror in sh.          ← DO NOT TOUCH
PRD.md                 # §6, §9.1, §12, §0.                                                                       ← READ ONLY
build.zig build.zig.zon src/*.zig scripts/        # no Zig/build changes this task.                ← DO NOT TOUCH
plan/001_0c8587f91cb2/docs/CONFIGURATION.md      # plan-level draft (caveat wording source).       ← reference only
```

### Desired Codebase tree with file responsibilities

```bash
tmux-2html.tmux        # autosync STUB replaced by: cache_home computation (XDG absolute-only) +
                       #   gated `tmux display-popup -E -w 50% -h 50% "...sync-palette" 2>/dev/null || :`
                       #   + TMUX_2HTML_DEBUG append (palette_cache, palette_autosync). Non-fatal.
docs/CONFIGURATION.md  # `## Palette cache` extended: auto-sync mechanics + outside-tmux caveat.
# (No new files; no Zig/build changes; bindings stub + §1–§4 untouched.)
```

### Known Gotchas of our codebase & Library Quirks

```sh
# CRITICAL (hard rule, inherited): the loader MUST NEVER crash the user's tmux. No `set -e`; a
# sourced/executed plugin must end at exit 0 regardless of any failing command. The popup line
# uses `... 2>/dev/null || :` so a display-popup failure (old tmux / no client / sync-palette
# non-zero) is swallowed. (`|| :` = the POSIX no-op true; `|| true` is fine too.)

# GOTCHA: the stub in the live file SUGGESTS `-w 100% -h 100% ... sync-palette --force`. The ITEM
#   CONTRACT is authoritative: `-w 50% -h 50% ... sync-palette` (NO --force). --force is REDUNDANT
#   because the `if [ ! -f "$palette_cache" ]` guard already ensures no cache exists, and
#   sync-palette with no cache acquires unconditionally (shouldRun(false,false)=true). See research §2.

# GOTCHA: cache_home MUST use the XDG-absolute-only rule (mirror src/palette.zig cacheBase + the
#   loader's own §3 data_home block), NOT the stub's naive `${XDG_CACHE_HOME:-$HOME/.cache}`. A
#   relative/empty XDG_CACHE_HOME must fall back to $HOME/.cache, else the sh `[ ! -f ]` test looks
#   at a different path than the binary writes => the popup would fire every load (or never).
#   POSIX "starts with /" test: `[ "${XDG_CACHE_HOME#/}" != "$XDG_CACHE_HOME" ]`.

# GOTCHA: gate on `[ "$binary_ready" = 1 ]`. Do NOT run sync-palette when the binary is absent — it
#   would just fail noisily inside a popup. Mirrors the bindings' binary_ready gate (P2.M2.T2).

# GOTCHA: $TMUX_2HTML_BIN inside the display-popup command MUST be expanded at source time (it is
#   a shell var in the loader's scope), NOT passed through for the popup shell to expand. So write
#   `"$TMUX_2HTML_BIN/tmux-2html sync-palette"` as ONE double-quoted argument so the loader expands
#   $TMUX_2HTML_BIN into a single command string that display-popup's shell then runs.

# GOTCHA: the §4 TMUX_2HTML_DEBUG block writes with `>` (truncate). This task's debug append MUST
#   use `>>` AND run AFTER §4 in file order (the autosync block is the file's last block ⇒ it is).
#   Appending from two places is safe ONLY because §4 runs first with `>`.

# GOTCHA (testing): `tmux source-file ./tmux-2html.tmux` FAILS (`unknown command: echo`, exit 1) —
#   tmux parses source-file content as tmux commands, not shell. Load the loader via `run-shell`
#   (which propagates $TMUX to the isolated server): `tmux -L sock set-environment
#   TMUX_PLUGIN_MANAGER_PATH <pm>; tmux -L sock run-shell "sh ./tmux-2html.tmux"`. Verified empirically.

# GOTCHA (testing): `tmux display-popup` needs an attached client; a detached test server errors
#   `no current client`. So the popup is MANUAL-ONLY to render. Test the DECISION + exact command
#   string via a fake-`tmux` stub (Level 2); prove non-fatality via the real isolated server (Level 3).

# GOTCHA (POSIX portability): `[ ]` not `[[ ]]`; `=` not `==`; `$( )` not backticks; quote every
#   expansion; `${var:-default}` / `${var#/}` are POSIX; no arrays; no `local`. `/bin/sh` here is
#   bash-as-sh but the script must run under dash/ash too (shellcheck -s sh enforces it).

# GOTCHA (test env control): the cache path is $XDG_CACHE_HOME-if-absolute else $HOME/.cache. The
#   Level 2 fake-tmux harness MUST empty XDG_CACHE_HOME (pass "") for the HOME-driven cases because
#   the AMBIENT XDG_CACHE_HOME (e.g. /home/user/.cache) would otherwise win and the cache-present
#   test would look at the wrong path. An empty XDG_CACHE_HOME is treated as unset by both the sh
#   block and src/palette.zig cacheBase() (consistent fallback to $HOME/.cache). Verified.
```

## Implementation Blueprint

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: MODIFY tmux-2html.tmux — REPLACE the autosync stub block with the real implementation
  - LOCATE the file's LAST block, currently:
        # ------------------------------------------------------------------
        # ## Palette auto-sync popup (one-time) — P2.M2.T1.S2
        # ------------------------------------------------------------------
        # Cache path (mirror src/palette.zig:240): ...
        #   cache_home=${XDG_CACHE_HOME:-$HOME/.cache}; palette_cache="$cache_home/tmux-2html/palette"
        #   if [ ! -f "$palette_cache" ]; then
        #       tmux display-popup -E -w 100% -h 100% "$TMUX_2HTML_BIN/tmux-2html sync-palette --force"
        #   fi
        # TODO(P2.M2.T1.S2): implement one-time palette auto-sync here.
        # ------------------------------------------------------------------
    and replace it (the whole commented stub) with the Implementation Patterns block below.
  - IMPLEMENT (see Implementation Patterns): cache_home (XDG absolute-only) + palette_cache;
    the gated display-popup (binary_ready AND !-f) using `-E -w 50% -h 50% "...sync-palette"`
    (NO --force; 50%/50% per contract) wrapped `2>/dev/null || :`; set palette_autosync 0/1;
    TMUX_2HTML_DEBUG append (`>>`) of palette_cache + palette_autosync.
  - CONSUMES: $binary_ready (§2), $TMUX_2HTML_BIN (§1). DOES NOT touch §1–§4 or the bindings stub.
  - NAMING: cache_home, palette_cache, palette_autosync (snake_case, lowercase; prefix _ not needed).
  - GUARD: every path ends cleanly; the block's last statement is robustly exit-0 (`|| :` / `if`).

Task 2: MODIFY docs/CONFIGURATION.md — EXTEND `## Palette cache` with auto-sync + caveat
  - LOCATE the existing `## Palette cache` section (created by P2.M2.T1.S1; ends with the sentence
    "...or automatically — once — by the plugin's auto-sync popup on first load when no cache
    exists. See the sync-palette documentation for ...").
  - ADD a `### Palette auto-sync (first load)` subsection (or expand the existing sentence into a
    short paragraph + caveat) covering:
      * On first plugin load, if no cache exists, tmux-2html opens a short `tmux display-popup`
        (a real terminal/pty, ~50%×50%) that runs `sync-palette` once and closes; subsequent loads
        skip it while the cache is present.
      * Non-fatal: if the popup can't open (older tmux, headless) or the query fails, rendering
        simply falls back to the bundled default palette.
      * The OUTSIDE-TMUX caveat (adapt wording from plan/.../docs/CONFIGURATION.md "Inside tmux
        vs. outside tmux"): the auto-sync popup runs INSIDE tmux and captures the palette tmux
        presents to panes (the one captures render against). Running `sync-palette` OUTSIDE tmux
        captures the outer terminal emulator's palette instead; the two can differ when tmux
        applies terminal-overrides / a custom default-terminal / RGB features.
  - DO NOT duplicate the cache file format or the sync-palette flag reference (the section already
    cross-links "See the sync-palette documentation ...").
  - PLACEMENT: within/after `## Palette cache`; keep the existing `## Options` table untouched.

Task 3: VALIDATE (every command verified — see Validation Loop)
  - sh -n tmux-2html.tmux; shellcheck -s sh; bashism grep.
  - Level 2 fake-tmux: no-cache ⇒ display-popup recorded w/ sync-palette + 50%; cache ⇒ none;
    relative XDG ⇒ fallback path.
  - Level 3 real isolated server via run-shell: non-crash (exit 0) despite display-popup
    "no current client"; palette_cache/palette_autosync in TMUX_2HTML_DEBUG.
  - Level 4 manual: real client, watch the popup pop + sync-palette summary on a fresh cache.
```

### Implementation Patterns & Key Details

```sh
# ===== the block that REPLACES the autosync stub (verbatim-ready; mirrors §3 data_home) =====
# ----------------------------------------------------------------------
# ## Palette auto-sync popup (one-time) — P2.M2.T1.S2
# ----------------------------------------------------------------------
# PRD §9.1 step 4 + §6: on first load, if no palette cache exists, pop a real
# pty (tmux display-popup) running sync-palette, then close. The popup is the
# controlling tty that run-shell (the binding context) lacks, so OSC palette
# queries succeed there. Runs once; skipped while the cache exists. Non-fatal.

# Cache path — mirror src/palette.zig cacheBase(): XDG_CACHE_HOME honored only
# if set, non-empty, AND absolute; otherwise $HOME/.cache (same rule as §3
# output-dir's data_home). The sh [ ! -f ] test must look at the SAME path the
# binary writes/reads, or the popup would mis-fire.
cache_home="$HOME/.cache"
if [ -n "${XDG_CACHE_HOME:-}" ] && [ -n "$XDG_CACHE_HOME" ] \
    && [ "${XDG_CACHE_HOME#/}" != "$XDG_CACHE_HOME" ]; then
    cache_home=$XDG_CACHE_HOME      # set + non-empty + absolute (starts with /)
fi
palette_cache="$cache_home/tmux-2html/palette"

# One-time trigger (item-contract command verbatim: 50%/50%, NO --force — the
# [ ! -f ] guard already guarantees no cache, so sync-palette acquires anyway).
# Gated on binary_ready so a missing binary doesn't error inside a popup.
# `2>/dev/null || :` ⇒ non-fatal on old tmux / no client / sync-palette failure.
if [ "$binary_ready" = 1 ] && [ ! -f "$palette_cache" ]; then
    palette_autosync=1
    tmux display-popup -E -w 50% -h 50% \
        "$TMUX_2HTML_BIN/tmux-2html sync-palette" 2>/dev/null || :
else
    palette_autosync=0
fi

# Debug observability (APPEND with >>; §4 already wrote with > and runs first).
if [ -n "${TMUX_2HTML_DEBUG:-}" ]; then
    {
        printf 'palette_cache=%s\n'   "$palette_cache"
        printf 'palette_autosync=%s\n' "$palette_autosync"
    } >> "$TMUX_2HTML_DEBUG"
fi
# ----------------------------------------------------------------------

# WHY no --force:  sync-palette with no cache + no --force still acquires
#   (syncPaletteDir shouldRun(cache_exists=false, force=false) == true). The
#   stub's --force was a placeholder; the item contract omits it.
# WHY 50% not 100%: item contract ("Wrap in a short popup, not 100%").
# WHY display-popup not run-shell: run-shell has no /dev/tty (OSC fails); the
#   popup is a real pty where queryColors succeeds (research_tmux.md Claim 2/3).
```

### Integration Points

```yaml
LOADER (tmux-2html.tmux):
  - consumes: $binary_ready (§2), $TMUX_2HTML_BIN (§1), $HOME / $XDG_CACHE_HOME (env).
  - produces: the one-time display-popup call; palette_cache + palette_autosync in TMUX_2HTML_DEBUG.
  - does NOT touch §1–§4 or the `## Bindings` stub (P2.M2.T2 owns bindings).
SYNC-PALETTE (P1.M2.T2.S1, DONE): the popup runs `tmux-2html sync-palette` (default --from tty);
  inside the popup pty it has a /dev/tty ⇒ queryColors succeeds ⇒ cache written, exit 0. Under a
  tty-less context it would exit 2, but the popup guarantees a tty.
TMUX RUNTIME: requires tmux >= 3.2 for display-popup (PRD §12). Older tmux ⇒ unknown command ⇒
  non-fatal (`2>/dev/null || :`); rendering falls back to the default palette.
TEST ISOLATION (PRD §0): tests use a uniquely-named isolated socket (`tmux -L t2h-...`) loaded
  via run-shell, NEVER the user's running server. The plugin's own display-popup against the user's
  attached session is intended product behavior (§9.1 step 4), NOT a §0 violation.
BUILD/PACKAGE: NO CHANGE — tmux-2html.tmux is already in build.zig.zon .paths; docs/ is fine
  outside .paths.
```

## Validation Loop

### Level 1: Syntax & Style (after editing the loader)

```bash
sh -n tmux-2html.tmux && echo "syntax OK"           # POSIX syntax (mandatory)
command -v shellcheck >/dev/null && shellcheck -s sh tmux-2html.tmux || echo "shellcheck N/A"
# Bashism scan (dash would reject these): expect ZERO hits in the NEW block.
grep -nE '\[\[|==|BASH_SOURCE|declare |local |let |~|<\(' tmux-2html.tmux || echo "no bashisms"
# Expected: "syntax OK"; shellcheck clean (the `2>/dev/null || :` and `${var#/}` are POSIX-clean)
# or N/A; "no bashisms".
```

### Level 2: Decision + exact command string (PRIMARY — fake tmux, no real server, deterministic)

> **Gotcha (env control):** the cache path is `$XDG_CACHE_HOME` (if absolute) else `$HOME/.cache`. To
> make it deterministic the harness MUST empty `XDG_CACHE_HOME` for the HOME-driven cases (a/b/d),
> because the AMBIENT `XDG_CACHE_HOME` (e.g. `/home/user/.cache`) would otherwise win and the
> cache-present test would look at the wrong path. An empty `XDG_CACHE_HOME=` is treated as unset by
> both the sh block (`[ -n "${XDG_CACHE_HOME:-}" ]` ⇒ false) and `src/palette.zig` `cacheBase()`
> (`x.len != 0`), so both fall back to `$HOME/.cache` consistently.

```bash
# Stub `tmux` so we can exercise the loader WITHOUT a server or a GUI. The fake records any
# display-popup command to a log; returns empty for show-option (unset); no-ops everything else.
work=$(mktemp -d); fakebin="$work/fakebin"; pm="$work/pm"; bin="$work/bin"
mkdir -p "$fakebin" "$pm" "$bin"
cat > "$fakebin/tmux" <<'EOF'
#!/usr/bin/env sh
case "$1" in
  show-option) printf '';;                 # unset => empty (the -q semantic); defaults apply
  display-message|bind-key) :;;           # no-op
  display-popup)
    # record the FULL command line the loader asked the popup to run
    printf '%s\n' "$*" >> "$T2H_POPUP_LOG"
    ;;
esac
EOF
chmod +x "$fakebin/tmux"
# A dummy executable so §2's fast-path `[ -x "$TMUX_2HTML_BIN/tmux-2html" ]` ⇒ binary_ready=1.
: > "$bin/tmux-2html"; chmod +x "$bin/tmux-2html"
mkdir -p "$work/home"

# run_case <xdg_value> : sources the loader under a controlled env. Pass "" to EMPTY XDG_CACHE_HOME
# (=> fallback to $HOME/.cache) or a value to test the XDG branch. Records display-popup calls.
run_case() {  # $1 = XDG_CACHE_HOME value to set for this run ("" => empty/unset semantics)
  rm -f "$work/popup.log"; export T2H_POPUP_LOG="$work/popup.log"
  PATH="$fakebin:$PATH" HOME="$work/home" TMUX_PLUGIN_MANAGER_PATH="$pm" \
    TMUX_2HTML_BIN="$bin" XDG_CACHE_HOME="$1" sh ./tmux-2html.tmux
}

# (a) NO cache + binary ready ⇒ display-popup fires with sync-palette (no --force) + 50%.
rm -rf "$work/home/.cache"
run_case ""          # empty XDG => cache path = $work/home/.cache/tmux-2html/palette (absent)
grep -q 'display-popup' "$work/popup.log" && grep -q 'sync-palette' "$work/popup.log" \
  && grep -q '50%' "$work/popup.log" && echo "PASS a: popup fired"
! grep -q -- '--force' "$work/popup.log" && echo "PASS a: no --force (contract)"

# (b) cache PRESENT at the HOME/.cache path (XDG emptied) ⇒ no display-popup.
mkdir -p "$work/home/.cache/tmux-2html"; : > "$work/home/.cache/tmux-2html/palette"
run_case ""
[ ! -s "$work/popup.log" ] && echo "PASS b: popup skipped (cache exists)"

# (c) RELATIVE XDG_CACHE_HOME ⇒ fallback to $HOME/.cache (cache still detected there ⇒ skip).
run_case "relative/cache"     # relative => not honored => cache path stays $work/home/.cache/...
[ ! -s "$work/popup.log" ] && echo "PASS c: relative XDG fell back to \$HOME/.cache (cache hit)"

# (d) binary NOT ready (missing executable) ⇒ no popup even with no cache.
rm -f "$bin/tmux-2html"; rm -rf "$work/home/.cache"
run_case ""
[ ! -s "$work/popup.log" ] && echo "PASS d: binary_ready gate held (no popup when binary absent)"

# (e) ABSOLUTE XDG_CACHE_HOME is honored (sanity for the mirror rule): seed cache THERE ⇒ skip.
: > "$bin/tmux-2html"; chmod +x "$bin/tmux-2html"    # restore dummy binary
mkdir -p "$work/xdg/tmux-2html"; : > "$work/xdg/tmux-2html/palette"
run_case "$work/xdg"
[ ! -s "$work/popup.log" ] && echo "PASS e: absolute XDG honored (cache hit at XDG path)"
rm -rf "$work"
# Expected: PASS a (fired, no --force), b (skipped), c (relative fallback), d (gate), e (absolute honored).
```

### Level 3: Real isolated tmux server (§0-compliant; non-crash + non-fatal proof)

```bash
# IMPORTANT (PRD §0): use a UNIQUE isolated socket; NEVER the user's server. Load the loader via
# run-shell (source-file REJECTS shell scripts — verified). display-popup needs a client, so against
# this detached server it errors "no current client" — which PROVES the non-fatal requirement.
sock="t2h-it-$$"
tmux -L "$sock" -f /dev/null new-session -d -s t2h
work=$(mktemp -d); pm="$work/pm"; bin="$work/bin"; mkdir -p "$pm" "$bin"
: > "$bin/tmux-2html"; chmod +x "$bin/tmux-2html"     # binary_ready=1
rm -rf "$work/home"; mkdir -p "$work/home"             # NO cache ⇒ popup will be ATTEMPTED

# Make TMUX_PLUGIN_MANAGER_PATH + HOME visible to run-shell children on this server.
tmux -L "$sock" set-environment TMUX_PLUGIN_MANAGER_PATH "$pm"
tmux -L "$sock" set-environment TMUX_2HTML_BIN "$bin"
tmux -L "$sock" set-environment HOME "$work/home"
tmux -L "$sock" set-environment TMUX_2HTML_DEBUG "$work/debug.env"

# Load the plugin the way TPM does (run-shell). display-popup errors "no current client"
# (no attached client) but the loader MUST still complete cleanly.
tmux -L "$sock" run-shell "sh $(pwd)/tmux-2html.tmux"; echo "run-shell done"
sleep 0.3
# Non-fatal + correct decision observability via the debug seam:
test -f "$work/debug.env" && grep -qx "palette_autosync=1" "$work/debug.env" && echo "PASS: decision=fire"
grep -q "^palette_cache=" "$work/debug.env" && echo "PASS: palette_cache recorded"
# The popup was ATTEMPTED but failed (no client) — the loader did NOT crash:
tmux -L "$sock" server-access 2>/dev/null; tmux -L "$sock" list-sessions >/dev/null 2>&1 && echo "PASS: server alive (non-fatal)"

# Now SEED the cache and reload ⇒ decision should flip to skip.
mkdir -p "$work/home/.cache/tmux-2html"; : > "$work/home/.cache/tmux-2html/palette"
rm -f "$work/debug.env"
tmux -L "$sock" run-shell "sh $(pwd)/tmux-2html.tmux"; sleep 0.3
grep -qx "palette_autosync=0" "$work/debug.env" && echo "PASS: decision=skip when cache exists"

tmux -L "$sock" kill-server; rm -rf "$work"
# Expected: decision flips 1→0 with/without cache; server stays alive (non-fatal popup failure).
```

### Level 4: Manual / interactive (real attached client — NOT in CI)

```bash
# In a REAL tmux session with an attached client, on a machine with a fresh (absent) palette cache:
rm -f "${XDG_CACHE_HOME:-$HOME/.cache}/tmux-2html/palette"
# Re-source the plugin (or restart tmux / prefix I). Expect: a ~50% popup appears, runs
#   `tmux-2html sync-palette` (prints "queried N/256 colors; cache at <path>"), and closes.
# Then verify the cache was written + a second load does NOT pop:
test -f "${XDG_CACHE_HOME:-$HOME/.cache}/tmux-2html/palette" && echo "cache written"
head "${XDG_CACHE_HOME:-$HOME/.cache}/tmux-2html/palette"     # PRD §6 plain-text format
# Re-source again ⇒ NO popup (cache exists). Delete the cache + re-source ⇒ popup fires again.
```

## Final Validation Checklist

### Technical Validation
- [ ] `sh -n tmux-2html.tmux` passes; no bashisms in the new block (Level 1 grep clean).
- [ ] `shellcheck -s sh tmux-2html.tmux` clean (or N/A).
- [ ] Level 2 fake-tmux: no-cache ⇒ popup fires with `sync-palette` + `50%` + NO `--force`; cache
      ⇒ skipped; relative `XDG_CACHE_HOME` ⇒ `$HOME/.cache` fallback; missing binary ⇒ no popup.
- [ ] Level 3 real isolated server (run-shell): loader completes cleanly despite display-popup
      "no current client"; `palette_autosync` flips 1→0 when the cache is seeded; server stays alive.
- [ ] `docs/CONFIGURATION.md` `## Palette cache` extended with auto-sync mechanics + outside-tmux caveat.

### Feature Validation
- [ ] First load + no cache + binary ready ⇒ exactly one `display-popup -E -w 50% -h 50% "...sync-palette"`.
- [ ] Cache present ⇒ popup skipped on every subsequent load.
- [ ] `XDG_CACHE_HOME` relative/empty ⇒ cache detected at `$HOME/.cache/tmux-2html/palette` (mirrors Zig).
- [ ] Popup is non-fatal: old tmux / no client / sync-palette non-zero never aborts the loader (exit 0).
- [ ] Gate on `binary_ready=1` (no popup when the binary is absent).

### Code Quality Validation
- [ ] POSIX-portable (`[ ]`, `=`, `$( )`, quoted expansions, `${var#/}`, no arrays/`local`).
- [ ] cache_home mirrors `src/palette.zig` `cacheBase()` + the loader's §3 `data_home` rule (XDG absolute-only).
- [ ] No `set -e`; popup line ends with `2>/dev/null || :`; the block's last statement is robustly exit-0.
- [ ] Debug append uses `>>` and runs after §4's `>` (file order) — no truncation/conflict.
- [ ] No duplication of cache-format / sync-palette-flag docs (cross-link preserved).
- [ ] §1–§4 of the loader and the `## Bindings` stub are untouched; no Zig/build changes.

### Documentation & Deployment
- [ ] `docs/CONFIGURATION.md` documents the auto-sync behavior (popup = real pty; once; skipped while
      cache exists; non-fatal) and the outside-tmux palette caveat.
- [ ] No new env vars (HOME / XDG_CACHE_HOME already used); no packaging change.

---

## Anti-Patterns to Avoid

- ❌ Don't use the stub's `-w 100% -h 100% ... --force` — the ITEM CONTRACT is `-w 50% -h 50% ...
  sync-palette` (no --force). The stub was a placeholder; `--force` is redundant given the `[ ! -f ]`
  guard (`shouldRun(false,false)=true`).
- ❌ Don't use the stub's naive `${XDG_CACHE_HOME:-$HOME/.cache}` for cache_home — a relative/empty
  XDG must fall back to `$HOME/.cache` (mirror `src/palette.zig` `cacheBase()`). Use the
  `${XDG_CACHE_HOME#/}` absolute test, exactly like §3's `data_home`.
- ❌ Don't omit the `binary_ready` gate — running `sync-palette` against a missing binary errors
  noisily inside a popup. Gate like the bindings do.
- ❌ Don't make the popup fatal — never `set -e`; always end the call with `2>/dev/null || :`. A
  sourced/executed plugin must return 0 even if display-popup fails (old tmux / no client).
- ❌ Don't test by `tmux source-file ./tmux-2html.tmux` — source-file parses tmux commands, not
  shell (`unknown command: echo`, exit 1). Load via `run-shell` (propagates `$TMUX`).
- ❌ Don't expect to render the popup in a headless/detached test — display-popup needs a client
  (`no current client`). Test the decision + command string via a fake-`tmux` stub (Level 2); prove
  non-fatality via the real isolated server (Level 3); render manually (Level 4).
- ❌ Don't touch the user's running tmux server in tests — use a unique isolated socket (`tmux -L
  t2h-...`) and tear down ONLY that socket. (The plugin's own display-popup in the user's attached
  session is intended product behavior, not a §0 violation.)
- ❌ Don't write the real palette cache from a test, and don't leave `$TMUX_2HTML_DEBUG` set in prod.
- ❌ Don't touch §1–§4, the `## Bindings` stub, build.zig/build.zig.zon, src/*.zig, PRD.md,
  tasks.json, prd_snapshot.md, or .gitignore.
- ❌ Don't duplicate the cache file format / sync-palette flag reference in docs — the section
  already cross-links "See the sync-palette documentation".

---

**Confidence Score: 9/10**

This is a small, well-scoped POSIX-sh + docs task. Every load-bearing fact is verified in-repo or
empirically: the exact stub block to replace is quoted verbatim from the live file; the item-contract
command line (`-w 50% -h 50%`, no `--force`) is given verbatim and reconciled against the stub's
suggestion; the cache-path rule is pinned to `src/palette.zig` `cacheBase()` + the loader's own §3
`data_home`; the consumed loader symbols (`$binary_ready`, `$TMUX_2HTML_BIN`, the no-`set -e` rule,
the `TMUX_2HTML_DEBUG` `>`-convention) are read from the live §1–§4; and the three tmux testing
mechanics (`source-file` rejects shell scripts; `run-shell` propagates `$TMUX`; `display-popup` needs
a client) are confirmed against the installed tmux 3.6b on an isolated socket. The decision logic +
exact command string are deterministically testable via a fake-`tmux` stub; non-fatality is provable
via the real isolated server; only the live popup render is manual (exactly like sync-palette's live
tty path). The one residual risk — matching the XDG-absolute-only rule exactly in sh — is mitigated
by mirroring the loader's own §3 `data_home` block verbatim and by a dedicated Level 2(c) test.
