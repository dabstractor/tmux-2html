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
    } > "$TMUX_2HTML_DEBUG"
fi

# ----------------------------------------------------------------------
# ## Bindings (prefix table) — P2.M2.T2.S1 (O + visible) / P2.M2.T2.S2 (C-o region)
# ----------------------------------------------------------------------
# Consumes: $TMUX_2HTML_BIN, $full_key, $region_key, $visible_key, $binary_ready
# Pattern: interpolate the resolved values DIRECTLY into bind-key command strings, e.g.
#   [ "$binary_ready" = 1 ] && tmux bind-key "$full_key" run-shell \
#       "$TMUX_2HTML_BIN/tmux-2html pane --full --target '#{pane_id}'"
# The binary reads output-dir/history-limit/open/font itself via show-option — do NOT pass them.
# (exported shell vars do NOT reach run-shell children spawned by bind-key.)
# TODO(P2.M2.T2.S1/S2): implement prefix-table bindings here.
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
