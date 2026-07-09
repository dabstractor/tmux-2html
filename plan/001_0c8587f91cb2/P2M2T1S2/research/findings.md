# Research findings — P2.M2.T1.S2 (One-time palette auto-sync popup trigger)

Scope: fill the labeled `## Palette auto-sync popup (one-time) — P2.M2.T1.S2` stub in the
already-implemented `tmux-2html.tmux` loader, and extend `docs/CONFIGURATION.md` §Palette.
No Zig changes. This is a POSIX-sh + docs task.

## 1. Predecessor state (P2.M2.T1.S1) — TREATED AS CONTRACT

`tmux-2html.tmux` is ALREADY FILLED (7024 bytes) by P2.M2.T1.S1. Its structure:
- §1 plugin_dir + TMUX_2HTML_BIN resolution (guarded; never crashes).
- §2 binary acquisition (sync fast-path `[ -x "$TMUX_2HTML_BIN/tmux-2html" ]` → ready;
  else `sh ensure_binary.sh`; exports `binary_ready` ∈ {0,1}).
- §3 `read_opt` helper + ALL 8 `@tmux-2html-*` options read with PRD §9.2 defaults; exports.
- §4 optional `TMUX_2HTML_DEBUG=<file>` test seam — writes resolved vars with `>` (truncate).
- `## Bindings (prefix table) — P2.M2.T2` — STUB (TODO comment; no bind-key calls).
- `## Palette auto-sync popup (one-time) — P2.M2.T1.S2` — **STUB (THIS TASK FILLS IT).**

The exact stub block to replace (verbatim from the live file):
```
# ----------------------------------------------------------------------
# ## Palette auto-sync popup (one-time) — P2.M2.T1.S2
# ----------------------------------------------------------------------
# Cache path (mirror src/palette.zig:240): ${XDG_CACHE_HOME:-$HOME/.cache}/tmux-2html/palette
#   cache_home=${XDG_CACHE_HOME:-$HOME/.cache}; palette_cache="$cache_home/tmux-2html/palette"
#   if [ ! -f "$palette_cache" ]; then
#       tmux display-popup -E -w 100% -h 100% "$TMUX_2HTML_BIN/tmux-2html sync-palette --force"
#   fi
# TODO(P2.M2.T1.S2): implement one-time palette auto-sync here.
# ----------------------------------------------------------------------
```

CONSUMED from the loader (do NOT recompute/re-derive): `$binary_ready`, `$TMUX_2HTML_BIN`,
the no-`set -e` / never-return-non-zero rule, and the `TMUX_2HTML_DEBUG` seam convention.

## 2. The authoritative item contract (wins over the stub's suggestion)

The work-item description (P2.M2.T1.S2) specifies the exact behavior:
> LOGIC: `if [ ! -f "$cache" ]; then tmux display-popup -E -w 50% -h 50% "$BIN/tmux-2html sync-palette"; fi`.
> (Wrap in a short popup, not 100%.) Non-fatal if it fails.

=> This task uses **`-w 50% -h 50%`** (NOT the stub's `100%`) and **no `--force`** (NOT the
stub's `--force`). RECONCILIATION: the stub was only a placeholder; the item contract is
authoritative. `--force` is REDUNDANT here because the `if [ ! -f "$palette_cache" ]` guard
already guarantees no cache exists, and `sync-palette` with no cache + no `--force` still
acquires (syncPaletteDir `shouldRun(cache_exists=false, force=false) == true`; see
src/main.zig syncPaletteDir). So omitting `--force` produces identical behavior and matches
the contract verbatim.

## 3. Cache path — MUST mirror `src/palette.zig` cacheBase() (XDG absolute-only)

`palette.cachePath()` → `${XDG_CACHE_HOME:-$HOME/.cache}/tmux-2html/palette`, BUT XDG is
honored ONLY if set + non-empty + ABSOLUTE (else falls back to `$HOME/.cache`). Confirmed in
src/palette.zig `cacheBase()` (lines ~358-366): `if (x.len != 0 and isAbsolute(x)) return x;`
else `getenv("HOME") orelse error.NoHomeDirectory`.

The predecessor's §3 already encodes the SAME rule for output_dir (`data_home`). The stub's
shorthand `cache_home=${XDG_CACHE_HOME:-$HOME/.cache}` is WRONG (honors a relative/empty
XDG). This task MUST use the correct absolute-only form (mirrors §3's `data_home` block):
```sh
cache_home="$HOME/.cache"
if [ -n "${XDG_CACHE_HOME:-}" ] && [ -n "$XDG_CACHE_HOME" ] \
    && [ "${XDG_CACHE_HOME#/}" != "$XDG_CACHE_HOME" ]; then
    cache_home=$XDG_CACHE_HOME      # set, non-empty, AND absolute (starts with /)
fi
palette_cache="$cache_home/tmux-2html/palette"
```
`${var#/}` strips a leading `/`; if the result differs from the original, the value started
with `/` ⇒ absolute. This is the POSIX idiom for "starts with /".

## 4. display-popup facts (verified — research_tmux.md Claim 2/7 + findings §3)

- `tmux display-popup -E -w <pct> -h <pct> <cmd>` opens a popup with a REAL freshly-allocated
  pty; the command has a `/dev/tty` so OSC palette queries (sync-palette → queryColors) WORK.
  This is the ENTIRE reason the popup exists: `run-shell` (where bindings run) has NO tty, so
  sync-palette can't query the palette there. The popup provides the controlling tty.
- `-E` = close popup automatically when the command exits.
- `-w 50% -h 50%` = half the client (a short popup; per item contract).
- Requires tmux ≥ 3.2 (PRD §12 runtime requirement). On older tmux, `display-popup` is an
  unknown command → handled by the non-fatal wrapper (no explicit version gate needed).
- TARGETS THE CURRENT CLIENT. At TPM plugin-load time a client is attached ⇒ popup shows.

## 5. CRITICAL testing mechanics (verified empirically against an isolated tmux 3.6b server)

Ran probes against `tmux -L t2h-probe-$$ ...` (isolated socket, §0-compliant):
- **`tmux source-file ./shell-style.tmux` FAILS** with `unknown command: echo` (exit 1).
  tmux parses `source-file` content as tmux commands, NOT shell. => The loader (a POSIX-sh
  script) MUST be loaded via `run-shell`, never `source-file`. (TPM uses run-shell; correct.)
- **`tmux -L sock run-shell "sh ./tmux-2html.tmux"` WORKS**: run-shell propagates `$TMUX`
  (e.g. `TMUX=/tmp/tmux-1000/t2h-probe-$$,...,0`) so every bare `tmux` call inside the loader
  reaches the ISOLATED server. Verified: `tmux set -g @probe_ran yes` inside run-shell was
  observable via `tmux -L sock show-option -gv @probe_ran` ⇒ `yes`. => This is the correct
  Level-3 invocation. Must `set-environment TMUX_PLUGIN_MANAGER_PATH` first (loader bails §1
  if unset).
- **`tmux display-popup` against a DETACHED session FAILS** with `no current client` (exit 1).
  => The actual popup CANNOT be rendered in a headless/detached test. Like sync-palette's
  live-tty path, real popup rendering is MANUAL-ONLY. The decision logic + the exact command
  string are tested deterministically via a fake-`tmux` stub (Level 2). The detached-server
  "no current client" failure is REPURPOSED as the Level-3 non-fatal assertion: the loader
  must source/exit 0 even though display-popup failed.

=> Three-layer test strategy:
  - Level 2 (PRIMARY, deterministic, no real server): fake `tmux` on PATH intercepts
    `display-popup` and records the command line; `show-option` returns empty (unset);
    `display-message`/`bind-key` no-op. Drive HOME at a tmpdir to control the cache path.
  - Level 3 (real isolated server via run-shell): non-crash + non-fatal-popup proof.
  - Level 4 (manual): real attached client, watch the popup pop + sync-palette summary.

## 6. Non-fatal design

The loader never `set -e` and never returns non-zero (predecessor's hard rule). The popup
line uses `tmux display-popup ... 2>/dev/null || :` so:
- old tmux without `display-popup` (unknown command) → suppressed, continued.
- no attached client (`no current client`) → suppressed, continued.
- sync-palette exits non-zero (terminal unresponsive) → popup closes via -E; -E closes on
  ANY exit incl. non-zero, so the popup just goes away; `|| :` keeps the loader at 0.
`2>/dev/null` keeps the user's status line clean (popup fires at most ONCE — first load with
no cache — so even un-suppressed it's a one-time blip; suppressing is the cleaner choice).

Gate on `[ "$binary_ready" = 1 ]`: do NOT attempt sync-palette if the binary is absent (it
would just error inside a popup). Mirrors the bindings' binary_ready gate.

## 7. Docs deliverable (Mode A, extends P2.M2.T1.S1)

The live `docs/CONFIGURATION.md` (created by T1.S1) has a brief `## Palette cache` section
that already says: "...or automatically — once — by the plugin's auto-sync popup on first
load when no cache exists." This task EXTENDS that section (per item: "note this auto-sync
behavior (and that running sync-palette outside tmux captures the outer terminal palette)"):
- Add the auto-sync mechanics: first load + no cache ⇒ `tmux display-popup` (real pty,
  50%×50%) runs `sync-palette` once; subsequent loads skip it while the cache exists;
  non-fatal on failure.
- Add the OUTSIDE-TMUX caveat: running `sync-palette` (or relying on auto-sync) outside tmux
  captures the OUTER terminal emulator's palette, which can differ from the palette tmux
  presents to panes (terminal-overrides / default-terminal / RGB features). The auto-sync
  popup runs INSIDE tmux, so it captures the tmux-presented palette (the correct one for
  captures). Wording adapted from the plan-level draft's "Inside tmux vs. outside tmux".

## 8. Out of scope / do NOT touch

- PRD.md, tasks.json, prd_snapshot.md, .gitignore (FORBIDDEN).
- build.zig, build.zig.zon, src/*.zig (no Zig changes — this is shell + docs).
- §1–§4 of the loader (T1.S1's work) — only REPLACE the autosync stub block + optionally
  APPEND palette_cache/palette_autosync to the debug file (via `>>`, AFTER §4's `>` write,
  so no conflict). The `## Bindings` stub stays a stub (P2.M2.T2's job).
- The palette cache itself (never write the real cache from tests).
