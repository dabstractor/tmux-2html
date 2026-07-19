#!/usr/bin/env bash
# safe-run.sh — run a command under hard kernel resource caps so a runaway
# cannot fill the disk or spin forever. This is the deterministic backstop for
# the 2026-07-18 incident: the only thing that stops a single process writing
# one file without bound is RLIMIT_FSIZE.
#
# Defaults are generous for normal builds/tests but lethal to a runaway:
# 1 GiB max file, 20 min max CPU. Tune with flags.
#
# Usage:
#   scripts/safe-run.sh [--fsize MiB] [--cpu SEC] [--] <cmd...>
#   scripts/safe-run.sh --fsize 512 --cpu 300 -- ./zig build test
#
# Accuracy note: RLIMIT_FSIZE units vary by tool (`prlimit` = bytes, exact;
# `ulimit -f` block size is shell/kernel-dependent). We prefer `prlimit`, which
# is unambiguous, and fall back to `ulimit` (best-effort) only if absent.
#
# Deliberately NOT set:
#   - ulimit -u (NPROC): a *user-wide* counter; a low value breaks the
#     operator's other processes on a shared session.
#   - ulimit -v (VMEM): a runaway *file* grows on disk, not in RSS, so a VMEM
#     cap would not have helped and can break over-allocating runtimes.
set -uo pipefail

FSIZE_MIB=1024    # max size of any single file created (RLIMIT_FSIZE)
CPU_SEC=1200      # max CPU seconds for the whole run (RLIMIT_CPU)

while [ $# -gt 0 ]; do
  case "$1" in
    --fsize) FSIZE_MIB="$2"; shift 2;;
    --cpu)   CPU_SEC="$2";   shift 2;;
    --) shift; break;;
    -h|--help) sed -n '2,24p' "$0"; exit 0;;
    *) echo "safe-run: unknown arg: $1 (see --help)" >&2; exit 2;;
  esac
done
[ $# -gt 0 ] || { echo "safe-run: no command given (-- <cmd>)" >&2; exit 2; }

FSIZE_BYTES=$(( FSIZE_MIB * 1024 * 1024 ))

if command -v prlimit >/dev/null 2>&1; then
  # Plain numeric soft limits (proven exact in calibration). Soft RLIMIT_FSIZE is
  # what raises SIGXFSZ; a buggy runaway isn't trying to raise limits, so soft is
  # sufficient enforcement. (Some prlimit builds reject the `:hard` keyword form.)
  echo "safe-run: caps (prlimit) — fsize<=${FSIZE_MIB}MiB (${FSIZE_BYTES}B), cpu<=${CPU_SEC}s, core=0" >&2
  exec prlimit --fsize="$FSIZE_BYTES" --cpu="$CPU_SEC" --core=0 -- "$@"
fi

# Fallback: ulimit. CPU (-t) and core (-c) are unambiguous; -f uses 512-byte
# blocks per POSIX (some shells differ, so this path is best-effort).
ulimit -f $(( FSIZE_BYTES / 512 )) 2>/dev/null || echo "safe-run: warn: cannot set ulimit -f" >&2
ulimit -t "$CPU_SEC" 2>/dev/null || echo "safe-run: warn: cannot set ulimit -t" >&2
ulimit -c 0 2>/dev/null || true
echo "safe-run: caps (ulimit, best-effort) — fsize<=~${FSIZE_MIB}MiB, cpu<=${CPU_SEC}s, core=0" >&2
exec "$@"