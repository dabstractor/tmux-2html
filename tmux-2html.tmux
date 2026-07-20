#!/usr/bin/env sh
# tmux-2html — TPM plugin loader (POSIX sh).
# Resolves the plugin dir + binary, ensures the binary is present (without ever
# crashing the user's tmux), reads every @tmux-2html-* user option, and exports
# the resolved values as the seam the sibling binding (P2.M2.T2) and palette
# auto-sync popup (P2.M2.T1.S2) tasks consume. Sourced by TPM at load; safe to
# re-source. This script MUST NOT `set -e` and MUST NOT return non-zero: a
# sourced plugin must never abort the user's `source-file` / `prefix I`.

# ----------------------------------------------------------------------
# §1  Plugin dir + binary resolution (guarded; never crash)
# ----------------------------------------------------------------------

# TPM sets TMUX_PLUGIN_MANAGER_PATH to the plugins root when it sources us.
# If it is unset we are not being loaded by TPM; emit one message and bail.
if [ -z "${TMUX_PLUGIN_MANAGER_PATH:-}" ]; then
    tmux display-message "tmux-2html: TMUX_PLUGIN_MANAGER_PATH unset; install via TPM" 2>/dev/null
    return 0 2>/dev/null || exit 0
fi
plugin_dir="$TMUX_PLUGIN_MANAGER_PATH/tmux-2html"

# Binary dir precedence (PRD §9.1): env $TMUX_2HTML_BIN → @tmux-2html-binary-dir
# option → "$plugin_dir/bin" default.
if [ -n "${TMUX_2HTML_BIN:-}" ]; then
    :
elif bin_opt=$(tmux show-option -gqv @tmux-2html-binary-dir 2>/dev/null) && [ -n "$bin_opt" ]; then
    TMUX_2HTML_BIN=$bin_opt
else
    TMUX_2HTML_BIN="$plugin_dir/bin"
fi

export plugin_dir TMUX_2HTML_BIN

# ----------------------------------------------------------------------
# §2  Binary acquisition (sync fast-path + sync acquire-if-absent; never crash)
# ----------------------------------------------------------------------
# tmux run-shell is ASYNC, so we cannot branch on its exit code. TPM already
# backgrounded this whole loader, so invoking ensure_binary.sh SYNCHRONOUSLY via
# `sh` only delays the binding-setup tail — it never freezes the tmux server.

binary_ready=1
if [ -x "$TMUX_2HTML_BIN/tmux-2html" ]; then
    : # common case: binary present + executable; nothing to do.
elif [ -f "$plugin_dir/scripts/ensure_binary.sh" ]; then
    # ensure_binary.sh owns the version-match vs build.zig.zon + build/download.
    # We pass "$TMUX_2HTML_BIN" as $1 (courtesy; it may also read the env we export).
    if ! sh "$plugin_dir/scripts/ensure_binary.sh" "$TMUX_2HTML_BIN" ; then
        tmux display-message "tmux-2html: install failed (see README)" 2>/dev/null
        binary_ready=0
    fi
else
    # ensure_binary.sh absent (dev / incomplete install). Do NOT crash.
    tmux display-message "tmux-2html: installer missing (incomplete install)" 2>/dev/null
    binary_ready=0
fi

export binary_ready

# ----------------------------------------------------------------------
# §3  Option reader + ALL 8 @tmux-2html-* options (PRD §9.2 defaults)
# ----------------------------------------------------------------------
# read_opt uses an explicit -n test: `show-option -gqv @opt` prints EMPTY and
# exits 0 for an UNSET option (the -q flag), so `... || echo default` would NOT
# apply the default. `${var:-default}` / the -n test do.

read_opt() {   # $1 = option name (@tmux-2html-<name>), $2 = default
    _v=$(tmux show-option -gqv "$1" 2>/dev/null)
    if [ -n "$_v" ]; then
        printf '%s' "$_v"
    else
        printf '%s' "$2"
    fi
}

# POSIX shell-escape: wrap $1 in single quotes with every embedded ' replaced
# by '\' (close-quote, escaped-', reopen-quote). Safe to interpolate unquoted
# into a /bin/sh -c string (e.g. tmux run-shell's command). Benign values
# round-trip unchanged: shell_escape "My Pane" -> 'My Pane'.
# Usage: shell_escape "Bob's pane" -> 'Bob'\''s pane'
shell_escape() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# Keys (drive binding generation in P2.M2.T2.S1/S2).
full_key=$(read_opt @tmux-2html-full-key O)
region_key=$(read_opt @tmux-2html-region-key C-o)
# Empty default ⇒ visible-only capture is unbound until the user sets it.
visible_key=$(read_opt @tmux-2html-visible-key "")

# Behavior options (the pane/region binary re-reads these itself via show-option;
# exported here for the contract + any wrapper; do NOT pass them on the pane CLI).
open=$(read_opt @tmux-2html-open on)
font=$(read_opt @tmux-2html-font monospace)
history_limit=$(read_opt @tmux-2html-history-limit 50000)

# output-dir default: ${XDG_DATA_HOME:-~/.local/share}/tmux-2html, with XDG
# honored only if set, non-empty, AND absolute (mirrors src/palette.zig:361 rule).
output_dir=$(read_opt @tmux-2html-output-dir "")
if [ -z "$output_dir" ]; then
    data_home="$HOME/.local/share"
    if [ -n "${XDG_DATA_HOME:-}" ] && [ -n "$XDG_DATA_HOME" ] \
        && [ "${XDG_DATA_HOME#/}" != "$XDG_DATA_HOME" ]; then
        data_home=$XDG_DATA_HOME
    fi
    output_dir="$data_home/tmux-2html"
fi

# @tmux-2html-binary-dir default = $TMUX_2HTML_BIN (already folded into it in §1).
binary_dir=$TMUX_2HTML_BIN

export full_key region_key visible_key open font history_limit output_dir binary_dir

# §8.1 HTML envelope knobs (P1.M1.T2.S1): document <title> + <html lang>. Empty default
# ⇒ the binary uses its own default (contextual title / locale-or-"en" lang). Unlike
# font/output-dir/open/history-limit (which the binary re-reads via show-option), these
# are THREADED into the bindings below as --title/--lang flags (the binary accepts both
# since P1.M1.T1.S1).
title_opt=$(read_opt @tmux-2html-title "")
lang_opt=$(read_opt @tmux-2html-lang "")
# NOW-expanded optional fragments (mirrors the $TMUX_2HTML_BIN interpolation: exported
# vars don't reach run-shell children, so bake them in at source time). Empty option ⇒
# empty fragment ⇒ binary default. Single-quoted so a spaced value survives run-shell's
# /bin/sh re-parse at fire time.
title_arg=""
[ -n "$title_opt" ] && title_arg="--title $(shell_escape "$title_opt")"
lang_arg=""
[ -n "$lang_opt" ] && lang_arg="--lang $(shell_escape "$lang_opt")"
export title_opt lang_opt title_arg lang_arg

# ----------------------------------------------------------------------
# §4  Optional test seam (harmless when unset; makes integration tests assertable)
# ----------------------------------------------------------------------
if [ -n "${TMUX_2HTML_DEBUG:-}" ]; then
    {
        printf 'plugin_dir=%s\n'      "$plugin_dir"
        printf 'TMUX_2HTML_BIN=%s\n'  "$TMUX_2HTML_BIN"
        printf 'binary_ready=%s\n'    "$binary_ready"
        printf 'full_key=%s\n'        "$full_key"
        printf 'region_key=%s\n'      "$region_key"
        printf 'visible_key=%s\n'     "$visible_key"
        printf 'output_dir=%s\n'      "$output_dir"
        printf 'open=%s\n'            "$open"
        printf 'font=%s\n'            "$font"
        printf 'history_limit=%s\n'   "$history_limit"
        printf 'binary_dir=%s\n'      "$binary_dir"
        printf 'title_opt=%s\n'       "$title_opt"
        printf 'lang_opt=%s\n'        "$lang_opt"
        printf 'title_arg=%s\n'       "$title_arg"
        printf 'lang_arg=%s\n'        "$lang_arg"
    } > "$TMUX_2HTML_DEBUG"
fi

# ----------------------------------------------------------------------
# ## Bindings (prefix table) — P2.M2.T2.S1 (O + visible)
# ----------------------------------------------------------------------
# PRD §9.3: prefix O renders the FULL pane; the visible key (if set) renders
# visible-only. Both are run-shell wrappers around `pane`, which resolves
# output-dir/history/font/open itself via show-option (do NOT pass them).
# run-shell expands #{pane_id} at fire time and has no /dev/tty, so pane uses
# the CACHED palette. We capture pane's stdout (`wrote <path>`) and flash it on
# the status line via display-message. Gated on binary_ready (§9.1: skip
# binding when the install failed). No set -e — a bad key just prints tmux's
# error and sourcing continues.

# O (full) — prefix O renders the whole pane (scrollback + visible).
# Quoting: $TMUX_2HTML_BIN expanded NOW; #{pane_id} stored literally (run-shell
# expands it); \$(…)/\"/\$out escaped so run-shell's /bin/sh runs them at fire time.
[ "$binary_ready" = 1 ] && tmux bind-key "$full_key" run-shell \
    "out=\$(\"$TMUX_2HTML_BIN/tmux-2html\" pane --full $title_arg $lang_arg --target '#{pane_id}' 2>/dev/null); tmux display-message \"tmux-2html: \$out\""

# Visible (only if @tmux-2html-visible-key is set; empty default ⇒ unbound,
# PRD §9.2/§9.3).
if [ -n "$visible_key" ]; then
    [ "$binary_ready" = 1 ] && tmux bind-key "$visible_key" run-shell \
        "out=\$(\"$TMUX_2HTML_BIN/tmux-2html\" pane --visible $title_arg $lang_arg --target '#{pane_id}' 2>/dev/null); tmux display-message \"tmux-2html: \$out\""
fi

# Optional test seam (APPEND with >>; §4 already wrote with > and runs first
# in file order). Records the binding decisions for deterministic tests.
if [ -n "${TMUX_2HTML_DEBUG:-}" ]; then
    {
        printf 'full_bound=%s\n'    "$([ "$binary_ready" = 1 ] && echo 1 || echo 0)"
        printf 'visible_bound=%s\n' "$([ "$binary_ready" = 1 ] && [ -n "$visible_key" ] && echo 1 || echo 0)"
    } >> "$TMUX_2HTML_DEBUG"
fi

# ------------------------------------------------------------------
# C-o region binding — P2.M2.T2.S2 (display-popup wrapper + .last-output sidecar)
# ------------------------------------------------------------------
# PRD §9.3 + §7.0: prefix <region_key> (default C-o) opens a pane-anchored,
# borderless tmux display-popup (-B; sized #{pane_width}x#{pane_height}; anchored
# over the pane top-left via -x P -y P) so the TUI's pty dims exactly match the
# captured grid (1:1 fidelity). It is a REAL pty (run-shell has no /dev/tty, so the
# region TUI + palette can only run inside it) running `tmux-2html region --target
# #{pane_id}`. region resolves font/open/output-dir itself via show-option (do
# NOT pass them — mirrors pane). The popup has NO tmux message channel, so on
# confirm region writes the bare result path to $TMUX_2HTML_BIN/.last-output;
# after the popup closes this wrapper reads it and flashes `tmux-2html: wrote
# <path>` on the status line (the wrapper runs in run-shell's /bin/sh, which
# HAS $TMUX). On cancel region exits 1 without writing; the pre-popup `rm -f`
# keeps the sidecar absent so no stale message. Gated on binary_ready (§9.1).
# region itself lands in P3 (it currently returns NotImplemented/exit 1, so
# until P3 the popup opens then closes and shows nothing — inert but correct).
# No set -e.
#
# Quoting (three layers — derived from the proven O binding, P2.M2.T2.S1):
#   $TMUX_2HTML_BIN  → expanded NOW (exported vars don't reach run-shell
#     children). Appears 3×: last=, the binary path, .last-output — all expand
#     now.
#   #{pane_id}       → stored LITERAL (run-shell expands it at fire time).
#   "  \$( )  \$last  \$out  → deferred to fire time (run-shell's /bin/sh).
# `last`/`out` vars avoid repeating the path AND avoid a nested $(cat "...")
# inside display-message's double-quoted arg. The trailing if…fi returns 0
# (cancel is silent).
[ "$binary_ready" = 1 ] && tmux bind-key "$region_key" run-shell \
    "last=\"$TMUX_2HTML_BIN/.last-output\"; rm -f \"\$last\"; tmux display-popup -B -E -w '#{pane_width}' -h '#{pane_height}' -x P -y P -t '#{pane_id}' \"$TMUX_2HTML_BIN/tmux-2html region $title_arg $lang_arg --target '#{pane_id}'\"; if [ -f \"\$last\" ]; then out=\$(cat \"\$last\"); tmux display-message \"tmux-2html: wrote \$out\"; fi"

# Optional test seam (APPEND with >>; §4 already wrote with > and runs first
# in file order). Records the region binding decision for deterministic tests.
if [ -n "${TMUX_2HTML_DEBUG:-}" ]; then
    printf 'region_bound=%s\n' "$([ "$binary_ready" = 1 ] && echo 1 || echo 0)" >> "$TMUX_2HTML_DEBUG"
fi
# ----------------------------------------------------------------------

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
# ----------------------------------------------------------------------
