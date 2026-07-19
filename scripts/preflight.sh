#!/usr/bin/env bash
# preflight.sh — bounded hygiene scan for runaway/residue after test & audit runs.
# Reports (does NOT delete): giant files, audit scratch dirs, stray temp files,
# and free disk. Stays on one filesystem and skips heavy/generated dirs (PRD §0.1).
#
# Usage: scripts/preflight.sh [--giant MiB]
# Exit: 0 always (reporting tool); non-zero only on usage error.
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
GIANC_MIB=100   # report files >= 100 MiB

while [ $# -gt 0 ]; do
  case "$1" in
    --giant) GIANC_MIB="$2"; shift 2;;
    -h|--help) sed -n '2,10p' "$0"; exit 0;;
    *) echo "preflight: unknown arg: $1 (see --help)" >&2; exit 2;;
  esac
done
GIANC_BYTES=$(( GIANC_MIB * 1024 * 1024 ))

pr() { printf '  '; printf '%s\n' "$*"; }

echo "== giant files (>= ${GIANC_MIB} MiB) under ${ROOT} =="
found_giant=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  sz=$(stat -c %s "$f" 2>/dev/null || echo 0)
  printf '  %10s  %s\n' "$(numfmt --to=iec "$sz" 2>/dev/null || echo "${sz}B")" "$f"
  found_giant=1
done < <(find "$ROOT" -xdev -type f -size "+${GIANC_BYTES}c" \
    -not -path "$ROOT/.git/*" -not -path "$ROOT/.zig-cache/*" \
    -not -path "$ROOT/zig-pkg/*" -not -path "$ROOT/zig-out/*" \
    -not -path "$ROOT/.pi-subagents/*" -not -path "$ROOT/node_modules/*" \
    -print 2>/dev/null)
[ "$found_giant" = 1 ] || pr "(none)"

echo
echo "== audit / scratch residue =="
found_residue=0
while IFS= read -r p; do
  [ -n "$p" ] || continue
  sz=$(stat -c %s "$p" 2>/dev/null || echo 0)
  printf '  %10s  %s\n' "$(numfmt --to=iec "$sz" 2>/dev/null || echo "${sz}B")" "$p"
  found_residue=1
done < <(find "$ROOT" -xdev -maxdepth 4 \
    \( -name '.audit*' -o -name 'calls.log' -o -name 'tmp.????????' -o -name '.last-output' \) \
    -not -path "$ROOT/.git/*" -print 2>/dev/null)
[ "$found_residue" = 1 ] || pr "(none)"

echo
echo "== disk free (repo fs) =="
df -h "$ROOT" | sed 's/^/  /'

echo
echo "preflight: done. If anything above is unexpected, clean it (see AGENTS.md §5)."
exit 0