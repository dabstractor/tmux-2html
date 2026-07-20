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

# Required Zig version — MUST match build.zig.zon `.minimum_zig_version`
# (single sync point: bump both together). The project's build.zig.zon declares
# only a MINIMUM (no exact pin), but newer Zig releases routinely break stdlib
# APIs this project compiles against (e.g. 0.16.0 removed `linkLibCpp`/
# `EnvMap`/`linkSystemLibrary2`), so a too-new system zig fails the build loudly
# and wastes the attempt. To stay robust we accept a zig whose MAJOR.MINOR equals
# the pin (0.15.x) and whose patch is >= the pin's patch; anything older OR newer
# is skipped in favor of the download path. This also covers the report's
# scenario (a /usr/bin/zig 0.16.0 shadowing a pinned ~/.local/bin/zig 0.15.2).
NEED_ZIG="0.15.2"

# ver2int MAJOR.MINOR.PATCH → a single comparable integer (pads each component
# to 4 digits, e.g. 0.15.2 -> 00000150002). Pure POSIX parameter expansion; no
# external deps. Unknown/malformed input yields 0 (treated as "too old").
ver2int() {
    v=${1:-0}
    maj=${v%%.*}                    # major (everything before first .)
    rest=${v#*.}                    # MINOR.PATCH remainder
    min=${rest%%.*}
    pat=${rest#*.}                  # patch (or MINOR.PATCH if no 2nd .)
    [ "$pat" = "$rest" ] && pat=0   # no patch component -> 0
    # strip any trailing pre-release suffix (e.g. 0.15.2-dev.42+abc -> 2)
    pat=${pat%%[!0-9]*}
    # default empty components to 0 (so non-numeric junk -> 0)
    maj=${maj:-0}; min=${min:-0}; pat=${pat:-0}
    printf '%04d%04d%04d' "$maj" "$min" "$pat" 2>/dev/null || printf '000000000000'
}

# zig_ok VERSION -> 0 if VERSION is build-compatible with NEED_ZIG, else 1.
# Compatible = same MAJOR.MINOR as NEED_ZIG and patch >= NEED_ZIG's patch
# (rejects both too-old 0.14.x and too-new 0.16.x). Pre-release suffixes are
# stripped before the patch compare (0.15.2-dev.42 is treated as 0.15.2).
zig_ok() {
    have=$(ver2int "$1"); need=$(ver2int "$NEED_ZIG")
    # zero-pad major.minor to 8 digits, compare as integers (patch ignored here)
    have_mm=${have%????};      need_mm=${need%????}      # drop last 4 = patch
    [ "$have_mm" = "$need_mm" ] || return 1               # MAJOR.MINOR must match
    have_p=${have#$have_mm};   need_p=${need#$need_mm}    # the 4-digit patch
    [ "$have_p" -ge "$need_p" ]
}

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
# Find a COMPATIBLE zig on PATH (MAJOR.MINOR == NEED_ZIG, see zig_ok). A bare `command -v zig`
# is NOT enough: a system zig of an incompatible version (e.g. /usr/bin/zig
# 0.16.0 when we need 0.15.2) appears earlier on PATH than the project's pinned
# zig and would fail the build loudly + waste the attempt. Scan PATH for the
# first zig whose `version` is compatible; if none qualifies, skip straight to
# the download path (step 3). Resolved to an ABSOLUTE path so the build subshell
# uses that exact binary (no bare-name re-resolution).
zig_bin=""
_oldifs=$IFS
IFS=:
for _d in $PATH; do
    IFS=$_oldifs
    [ -n "$_d" ] || continue
    [ -x "$_d/zig" ] || continue
    # capture version safely (set -e safe: trailing || vv="")
    vv=$("$_d/zig" version 2>/dev/null) || vv=""
    if [ -n "$vv" ] && zig_ok "$vv"; then
        zig_bin="$_d/zig"
        break
    fi
done
IFS=$_oldifs
if [ -n "$zig_bin" ]; then
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
        if ( cd "$plugin_dir" && "$zig_bin" build --release=fast --prefix "$tmp" install ) \
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
