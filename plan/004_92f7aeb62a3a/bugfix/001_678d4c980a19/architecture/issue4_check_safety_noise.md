# Issue 4 Architecture: check-safety.sh WARN Noise in plan/

## Problem
`scripts/check-safety.sh` emits 16 WARNs (0 FAILs) from PATH-shim recipe matches
inside `plan/002_e3d8d22c088d/P1M1T3S1/PRP.md`. These are documented test-harness
recipes (PATH-prepend + absolute-path `exec`), not live code. They are in the
human-owned `plan/` tree.

## Current Scoping
`collect_files()` (check-safety.sh) excludes: `.git`, `.zig-cache`, `zig-pkg`,
`zig-out`, `.pi-subagents`, `node_modules`, `scratch`. **`plan/` is NOT excluded.**

The `should_skip()` function skips documentation lines: backtick spans, `#`/`//`
comments, markdown list/quote/table leaders, grep/rg/awk/sed search-context lines.

The WARN patterns (R3 shim_combo, R4 calls.log) apply to files **outside `scripts/`**
(`under_scripts()` check). `plan/` is not under `scripts/`, so it IS scanned.

## Fix Options

### Option A: Exclude `plan/` from WARN scans entirely (recommended)
Add `plan/` to a skip list for WARN-only patterns. The cleanest approach: modify
the WARN-scanning condition (currently `if ! under_scripts "$f"`) to also skip
files under `plan/`:
```bash
under_plan() { case "$1" in "$ROOT/plan/"*|"$ROOT/plan") return 0;; *) return 1;; esac; }
# ...
if ! under_scripts "$f" && ! under_plan "$f"; then
    shim_combo "$f" "$rel"
    scan_pat WARN "$R4" "$f" "$rel"
fi
```

### Option B: Add `plan/` to collect_files() exclusions
This would also exclude `plan/` from FAIL scans, which is undesirable (FAIL
patterns like `killall tmux` should still be caught everywhere).

### Option C: Leave as-is (acceptable)
The PRD explicitly states: "Leaving `plan/` docs alone is also acceptable."
0 FAILs means CI passes. The 16 WARNs are cosmetic noise.

## Recommendation
Option A is the minimal, surgical fix. It preserves FAIL scanning in `plan/`
(safety-critical) while suppressing WARN noise (cosmetic). The comment header in
check-safety.sh should be updated to note the `plan/` exclusion for WARN patterns.

## Documentation Impact
- `scripts/check-safety.sh` header comments (lines 2–28) describe WARN scoping —
  should be updated to mention `plan/` exclusion.
- AGENTS.md §3 describes check-safety.sh behavior — no change needed (already says
  WARN is for patterns outside `scripts/`).