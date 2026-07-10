#!/usr/bin/env sh
# download.sh — download the latest prebuilt tmux-2html binary (PRD §10 step 3).
# Detects the platform via `uname -sm` → a platform triple → fetches the matching
# `tmux-2html-<triple>.tar.xz` from the latest GitHub release → verifies its SHA256
# against the release's `SHA256SUMS.txt` (verify BEFORE extract) → extracts the
# binary into the bin dir via an ATOMIC rename (temp created inside the bin dir ⇒
# same filesystem). On any failure (offline, 404, checksum mismatch, unsupported
# platform, no fetch tool, no sha256 tool) → stderr + exit non-zero; the caller
# (scripts/ensure_binary.sh step 3) then falls through and the loader flashes
#   tmux display-message "tmux-2html: install failed (see README)"
# We NEVER call tmux ourselves (tmux-agnostic + unit-testable in CI). Never leaves a
# half-written binary (atomic rename) or a leftover temp (EXIT trap).
#
# Invoked by ensure_binary.sh step 3 as:
#   sh "$plugin_dir/scripts/download.sh" "$bin_dir" 2>/dev/null
# ⇒ $1 = the bin DIR (…/tmux-2html/bin); the binary is "$1/tmux-2html".
# Acceptance (AND-gate): exit 0 AND an executable $1/tmux-2html (caller re-[ -x ]-checks;
# it does NOT trust our exit alone). The caller passes NO version and does NOT re-verify
# the downloaded version ⇒ we download the LATEST release (do NOT bake/pin a version).
# `set -eu` is SAFE: we are a child `sh`, never sourced (ShellCheck SC2187).

set -eu

# ---- config (single sync points) --------------------------------------------
# GitHub repo path segment. The published repo is `tmux-2html/tmux-2html` (the same org/name
# the README's TPM install line uses: set -g @plugin 'tmux-2html/tmux-2html'). The binary,
# --version, options, and release asset prefix all use `tmux-2html`; the repo org/name is the
# ONE place the GitHub release URL must point at. Keep this in sync with README.md's @plugin
# line and .github/workflows/release.yml (which uploads to whichever repo tags `v*`).
# Override via env for forks/mirrors.
REPO=${TMUX_2HTML_REPO:-tmux-2html/tmux-2html}
# Release download base. Default = the latest-published-release shortcut (GitHub
# 302-redirects to the asset blob). For tests, set TMUX_2HTML_DL_BASE=file://$dir to
# fetch a staged fixture dir with ZERO network (curl supports file://). NOTE: `latest`
# resolves only to the newest NON-draft, NON-prerelease release; drafts (how P4.M1
# publishes) 404 here until promoted — that's CORRECT (no release to download yet).
DL_BASE=${TMUX_2HTML_DL_BASE:-https://github.com/$REPO/releases/latest/download}

# ---- inputs -----------------------------------------------------------------
# $1 = bin dir (caller contract). Default-expand for -u + standalone safety;
# also honor an exported $TMUX_2HTML_BIN as a fallback.
bin_dir=${1:-${TMUX_2HTML_BIN:-}}
if [ -z "$bin_dir" ]; then
    echo "tmux-2html: download.sh: no bin dir given (pass it as \$1)" >&2
    exit 2
fi
bin="$bin_dir/tmux-2html"

# temp cleanup on ANY exit (reinforces "never half-written / never leftover temp").
# Empty until set; `${tmp:-}` stays -u-safe even before tmp is assigned. Inline (not
# a named fn) so shellcheck sees no "unused function" (SC2329); end with `|| :` so a
# failing rm never makes the trap return non-zero.
tmp=""
trap '[ -n "${tmp:-}" ] && [ -d "${tmp:-}" ] && rm -rf -- "${tmp:-}" 2>/dev/null || :' EXIT

# ---- platform detection: $(uname -sm) → triple ------------------------------
# GOTCHA: uname -m reports `arm64` on macOS Apple Silicon but `aarch64` on Linux
# ARM64; some kernels report `amd64` not `x86_64`. So combine os+arch in ONE case
# (you CANNOT normalize arch independently of OS) and accept BOTH spellings.
os=$(uname -s 2>/dev/null) || os=""
arch_raw=$(uname -m 2>/dev/null) || arch_raw=""
case "$os-$arch_raw" in
    Linux-x86_64|Linux-amd64)    triple=linux-x86_64  ;;
    Linux-aarch64|Linux-arm64)   triple=linux-aarch64 ;;
    Darwin-x86_64|Darwin-amd64)  triple=macos-x86_64  ;;
    Darwin-arm64|Darwin-aarch64) triple=macos-arm64   ;;
    *)
        echo "tmux-2html: download.sh: unsupported platform ($os $arch_raw); please install Zig or place a binary manually (see README)" >&2
        exit 1
        ;;
esac

tname="tmux-2html-$triple.tar.xz"
url="$DL_BASE/$tname"
sums_url="$DL_BASE/SHA256SUMS.txt"

# ---- fetch helper (curl preferred, wget fallback) ---------------------------
# Returns non-zero on failure; the caller wraps each fetch in `if ! fetch …`.
# curl supports file:// (used by the fixture tests); both exit non-zero on 404/offline.
fetch() {
    # $1 = url, $2 = output file
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$2" "$1"            # -f fail-fast on HTTP>=400 (exit 22); -L follow redirect
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$2" "$1"               # exit 8 on HTTP error, 4 on network failure
    else
        return 3                            # no fetch tool
    fi
}

# ---- stage the temp INSIDE bin_dir (same FS ⇒ atomic mv) --------------------
tmp=$(mktemp -d "$bin_dir/.dlXXXXXX" 2>/dev/null) || {
    _ts=$(date +%s 2>/dev/null) || _ts=0
    tmp="$bin_dir/.dl.$$.$_ts"
    mkdir -m 700 "$tmp" 2>/dev/null || tmp=""
}
if [ -z "$tmp" ]; then
    echo "tmux-2html: download.sh: could not create temp dir in $bin_dir" >&2
    exit 1
fi
tb="$tmp/$tname"
sums="$tmp/SHA256SUMS.txt"

# ---- fetch the tarball + the checksum manifest ------------------------------
# NOTE: do NOT write `if ! fetch …; then rc=$?` — the `!` NEGATES the exit status, so
# `$?` in the then-branch is ALWAYS 0 and the `case $rc` can never distinguish the
# "no curl/wget" (rc=3) path. Instead capture the code with `fetch … || rc=$?`
# (a non-last element of a `||` list ⇒ POSIX §2.8.1 exempts it from set -e, and `$?`
# at `rc=$?` is fetch's true exit). A fetch failure then falls through to a loud exit
# (the trap cleans tmp).
rc=0
fetch "$url" "$tb" || rc=$?
if [ "$rc" -ne 0 ]; then
    case $rc in
        3) echo "tmux-2html: download.sh: no curl/wget on PATH; please install Zig or place a binary manually (see README)" >&2 ;;
        *) echo "tmux-2html: download.sh: failed to download $url (offline? no published release yet?)" >&2 ;;
    esac
    exit 1
fi
rc=0
fetch "$sums_url" "$sums" || rc=$?
if [ "$rc" -ne 0 ]; then
    echo "tmux-2html: download.sh: failed to download $sums_url (offline? no published release yet?)" >&2
    exit 1
fi

# ---- SHA256 verify the TARBALL (verify-before-extract) ----------------------
# Compute: try sha256sum, fall back to `shasum -a 256` (macOS has no sha256sum).
# Both emit `<64hex>  <file>`; take field 1. The pipeline ENDS in awk (exit 0) so a
# bare `actual=$(… | awk …)` is set -e-safe (the pipeline exit is awk's = 0).
if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum -- "$tb" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
    actual=$(shasum -a 256 -- "$tb" | awk '{print $1}')
else
    echo "tmux-2html: download.sh: no sha256 tool (need sha256sum or shasum)" >&2
    exit 1
fi
# Lookup the expected hash for OUR tarball basename from SHA256SUMS.txt. Robust to:
#   * leading `./` (the char before the basename is then `/`, NOT a space) ⇒ the
#     prefix class is `[[:space:]/]` (whitespace OR slash), not `[[:space:]]` alone;
#   * CRLF endings ⇒ the suffix is `[[:space:]]*$` (NOT a bare `$`), because the
#     line ends with `\r` and `tr -d '\r'` runs AFTER grep so it can't rescue a
#     `$` anchor that sits after the `\r`;
#   * one/two-space sep and lines for OTHER platforms' tarballs (works whether the
#     file has 1 line or all 4); the `[[:space:]/]` prefix + basename + EOL anchor
#     prevent a longer/different name (e.g. `-linux-aarch64` vs `-linux-x86_64`)
#     from false-matching.
# The pipeline ends in head (exit 0) so `expected=$(… | head -n1)` is set -e-safe;
# empty when no line matches.
expected=$(grep -E "[[:space:]/]${tname}[[:space:]]*$" "$sums" | tr -d '\r' | awk '{print $1}' | head -n1)
# Case-insensitive compare (some tools uppercase the digest).
a=$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')
e=$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')
if [ -z "$e" ] || [ "$a" != "$e" ]; then
    echo "tmux-2html: download.sh: SHA256 mismatch (or no entry) for $tname" >&2
    echo "  expected: ${expected:-<none>}" >&2
    echo "  actual:   $actual" >&2
    echo "  Please install Zig or place a binary manually (see README)." >&2
    exit 1
fi

# ---- extract + atomic install -----------------------------------------------
# tar -xJf works on GNU tar AND macOS bsdtar (libarchive, native xz — no external
# xz needed on macOS). We verify BEFORE extract (path-traversal safety); extract
# into the throwaway temp (NOT directly into bin). The tarball's top-level entry is
# the bare `tmux-2html` ⇒ after extract `$tmp/tmux-2html` exists.
if ! tar -xJf "$tb" -C "$tmp"; then
    echo "tmux-2html: download.sh: failed to extract $tname (missing xz backend?)" >&2
    exit 1
fi
if [ ! -f "$tmp/tmux-2html" ]; then
    echo "tmux-2html: download.sh: $tname did not contain a 'tmux-2html' entry" >&2
    exit 1
fi
chmod 0755 "$tmp/tmux-2html"
# Atomic install: same-FS rename (temp is inside bin_dir). A reader/crash sees EITHER
# the old binary or the new one, never a partial file.
mv -f "$tmp/tmux-2html" "$bin"

exit 0
