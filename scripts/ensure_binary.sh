#!/usr/bin/env sh
# ensure_binary.sh — acquire the tmux-2html binary (PRD §10).
# Order: (1) existing binary whose --version matches the baked constant → done;
#        (2) `zig build --release=fast` into the bin dir (atomic rename) → done;
#        (3) scripts/download.sh (latest GitHub release, SHA256-verified) → done;
#        (4) any failure → stderr diagnostic + exit non-zero (the loader flashes
#            `tmux display-message "tmux-2html: install failed (see README)"` and
#            skips binding — we NEVER call tmux ourselves: tmux-agnostic + unit-
#            testable). Never leaves a half-written binary (atomic rename).
# Invoked by tmux-2html.tmux §2 as:
#   sh "$plugin_dir/scripts/ensure_binary.sh" "$TMUX_2HTML_BIN"
# ⇒ $1 = the bin DIR (…/tmux-2html/bin); $0 = our absolute path.
# `set -eu` is SAFE: we are a child `sh`, never sourced (ShellCheck SC2187).

set -eu

# ---- inputs + paths ---------------------------------------------------------
# $1 = bin dir (loader contract). Default-expand for -u + standalone/CI safety;
# also honor an exported $TMUX_2HTML_BIN as a fallback.
bin_dir=${1:-${TMUX_2HTML_BIN:-}}
if [ -z "$bin_dir" ]; then
    echo "tmux-2html: ensure_binary.sh: no bin dir given (pass it as \$1)" >&2
    exit 2
fi
bin="$bin_dir/tmux-2html"

# Plugin dir = the dir holding build.zig (= parent of scripts/). Derive from $0;
# the loader invokes us by ABSOLUTE path (so dirname is already absolute), and a
# standalone/CI run from the repo root yields a relative-but-usable "." path.
script_dir=$(dirname -- "$0")
plugin_dir=$(dirname -- "$script_dir")

# Baked plugin version — MUST match build.zig.zon `.version` (single sync point:
# bump both together). main.zig printVersion prints `tmux-2html <version>`.
EXPECTED_VERSION="0.1.0"

# tmp cleanup on ANY exit (reinforces "never half-written"); empty until set.
# Inline (not a named fn) so shellcheck sees no "unused function"; `${tmp:-}`
# stays -u-safe even before tmp is assigned.
tmp=""
trap '[ -n "${tmp:-}" ] && [ -d "${tmp:-}" ] && rm -rf -- "${tmp:-}" 2>/dev/null || :' EXIT

# ---- step 1: existing binary at the baked version? → done -------------------
if [ -x "$bin" ]; then
    # Capture --version safely: under set -e, `x=$(...)` in dash ABORTS on a
    # failing $(...); the trailing `|| cur=""` makes the assignment a non-last
    # list element (POSIX §2.8.1) so a failing/empty --version does NOT abort.
    cur=$("$bin" --version 2>/dev/null) || cur=""
    if [ "$cur" = "tmux-2html $EXPECTED_VERSION" ]; then
        exit 0
    fi
fi

# ---- step 2: build from source via zig? → done ------------------------------
if command -v zig >/dev/null 2>&1; then
    # Temp dir INSIDE bin_dir ⇒ same filesystem ⇒ the final `mv` is an atomic
    # rename (no EXDEV copy). Positional mktemp template (NOT -t: GNU vs BSD
    # differ). PID+epoch mkdir fallback for the rare mktemp-less host.
    tmp=$(mktemp -d "$bin_dir/.buildXXXXXX" 2>/dev/null) || {
        _ts=$(date +%s 2>/dev/null) || _ts=0
        tmp="$bin_dir/.build.$$.$_ts"
        mkdir -m 700 "$tmp" 2>/dev/null || tmp=""
    }
    if [ -n "$tmp" ]; then
        # cd into the source dir (build.zig lives there) + install to the temp
        # prefix; the exe lands at $tmp/bin/tmux-2html. The whole pipeline is
        # the condition of an `if` ⇒ a failed/aborted build (and even a failed
        # mv) FALLS THROUGH to download instead of aborting (POSIX §2.8.1).
        if ( cd "$plugin_dir" && zig build --release=fast --prefix "$tmp" install ) \
           && [ -x "$tmp/bin/tmux-2html" ] \
           && mv -f "$tmp/bin/tmux-2html" "$bin"; then
            exit 0
        fi
        # build/artifact/mv failed → fall through to download (trap cleans tmp).
    fi
fi

# ---- step 3: download.sh (latest release; SHA256-verified) → done -----------
# download.sh is P2.M3.T1.S2 (NOT YET DONE). Guard before invoking; until S2
# lands this step is skipped → falls through to step 4 (correct: no download
# capability yet). Handshake: S1 passes the bin dir; S2 downloads/verifies/
# extracts into it; S1 accepts via [ -x $bin ] (S2 owns tarball version/SHA).
if [ -x "$plugin_dir/scripts/download.sh" ]; then
    if sh "$plugin_dir/scripts/download.sh" "$bin_dir" 2>/dev/null; then
        [ -x "$bin" ] && exit 0
    fi
fi

# ---- step 4: every path failed → loud failure (loader flashes the message) --
echo "tmux-2html: ensure_binary.sh: could not obtain binary (version/build/download all failed)" >&2
exit 1
