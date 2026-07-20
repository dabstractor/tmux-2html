# Research Findings — P1.M1.T2.S4 (zero-dimension rejection tests)

## 0. The load-bearing discovery: contract item (a) is ALREADY DONE by S1

The item contract lists two test deliverables:
- (a) a **unit test** in `src/render.zig` asserting `determineCols(0, false)` and
  `determineCols(0, true)` return `error.InvalidWindowSize`.
- (b) a **shell integration test** asserting `render --cols 0` / `--rows 0` exit non-zero,
  not 139, and write nothing to stdout.

**Item (a) is already satisfied.** S1 (commit `ec9eafe "Guard determineCols against explicit
zero width"`, status: **Complete**) added BOTH the guard (`render.zig:97`) AND the exact unit
test the S4 contract describes, verbatim, at **`render.zig:1260`**:

```zig
test "determineCols: explicit --cols 0 is rejected (Issue 2: zero-dimension segfault guard)" {
    // An explicit --cols 0 must NOT reach Terminal.init (ghostty-vt segfaults on a zero-width
    // terminal). determineCols rejects it with error.InvalidWindowSize, which run() maps to
    // exit 2 + a stderr message (no segfault). The explicit arm returns before the has_tty
    // branch, so getSize is never called => safe to assert both. Boundary value 1 is accepted.
    try std.testing.expectError(error.InvalidWindowSize, determineCols(0, false));
    try std.testing.expectError(error.InvalidWindowSize, determineCols(0, true));
    try std.testing.expectEqual(@as(u16, 1), try determineCols(1, false));
```

Verified:
```
$ grep -n 'test "determineCols' src/render.zig
1246:test "determineCols: explicit cols wins (never probes the tty)" {
1253:test "determineCols: no tty + no cols => error.SizeRequired" {
1260:test "determineCols: explicit --cols 0 is rejected (Issue 2: zero-dimension segfault guard)" {
```

**=> S4 must NOT re-add this unit test** (Zig tolerates duplicate `test` names but it is
pointless, the S1 PRP already owns it, and it would be dead weight). S4's deliverable for
item (a) is **verification-only** (grep + the `zig build test` run already executes it).
S4's actual NEW work is item (b), the shell integration test. This is the central scope
adjustment driven by the parallel-execution contract: S1 and S4 both touched "the determineCols
zero test", and S1 landed first.

## 1. Empirical verification of the FIXED binary (built fresh, `zig build --release=fast`, clean)

All three PRD Issue 2 repro cases now exit gracefully (were 139 SIGSEGV before S1/S2):

```
--cols 0                         => exit=2, stdout_bytes=0, stderr="tmux-2html render: cannot determine terminal size"
--cols 5 --rows 0                => exit=2, stdout_bytes=0, stderr="tmux-2html render: cannot determine terminal size"
--cols 0 --selection 0,0,0,0     => exit=2, stdout_bytes=0   (determineCols fires before the selection arm)
--cols 1                         => exit=0   (boundary)
--cols 5 --rows 1                => exit=0   (boundary)
--cols 5  (omitted --rows)       => exit=0   (lineCount default floors at >= 1)
```

Takeaways for the shell-test assertions:
- **Exit code is 2** for all zero-dim cases (S1 routes `--cols 0` → `error.InvalidWindowSize`
  → the `const cols = determineCols(...) catch |err| { reportSizeError(err); return 2; }` block
  at render.zig:757-759; S2 routes `--rows 0` → the `if (rows < 1) { reportSizeError(...);
  return 2; }` guard at render.zig:761-764).
- **stdout is provably empty** (0 bytes) on rejection — graceful, not a partial render.
- The **stderr message** is the EXISTING `reportSizeError` string `"tmux-2html render: cannot
  determine terminal size"` (render.zig:722). Asserting it is a bonus that proves the graceful
  error path ran (vs a panic); the CORE contract gate is exit non-zero + not 139 + empty stdout.
- The contract says "non-zero AND not 139" (NOT "== 2"). The architecture doc allows "either
  exit 1 or 2 is acceptable per PRD §5". => The shell test asserts **`rc != 0 && rc != 139`**
  (robust to either acceptable exit code), and optionally checks the message for the two
  contract-mandatory cases where it was directly verified.

## 2. Why a dedicated test file (not editing envelope_smoke.sh)

The contract: "add shell assertions to tests/envelope_smoke.sh **(or a dedicated render test)**".
Decision: **dedicated `tests/zero_dimension_reject.sh`**. Rationale:
1. **Separation of concerns.** `envelope_smoke.sh` asserts §8.1 doc-completeness across every
   *happy* output path (`<!DOCTYPE html> … </html>`). Zero-dimension is an *adversarial
   rejection* test (assert the binary refuses + doesn't crash) — a different concern. Mixing
   them muddies both.
2. **Sibling precedent.** Issue 1's regression (region empty-cell confirm) is its own file,
   `tests/region_empty_confirm.sh`, NOT folded into envelope_smoke.sh. Same pattern => a
   named regression file per bug, each its own CI step.
3. **Zero tmux / zero python3 dependency.** This test needs ONLY `render` reading piped stdin
   (no PATH shim, no pty, no isolated socket). It is the most portable test in the repo —
   splitting it out makes that independence explicit and keeps it runnable even where tmux is
   absent (unlike envelope_smoke which SKIPs without tmux).

## 3. CI wiring precedent (where to add the step)

`.github/workflows/ci.yml` structure:
- `test` job: `zig build test -Doptimize=ReleaseFast` (runs the Zig unit tests, incl. S1's
  determineCols test at render.zig:1260).
- `envelope` job (ubuntu-latest): installs tmux, builds the release binary, runs
  `tests/envelope_smoke.sh` then `tests/region_empty_confirm.sh` as named steps. **This is the
  home for shell integration regressions** — both reuse the already-built binary.

=> Add the zero-dimension step to the `envelope` job, immediately after
`region_empty_confirm.sh`. It reuses the binary built by the job's `zig build -Doptimize=ReleaseFast`
step (no extra build). Name it `render zero-dimension rejection regression (Issue 2)` to mirror
the `region empty-cell confirm regression (Issue 1)` naming.

(Why not its own top-level job? That needs a fresh checkout + zig setup + build — ~2 min of CI
for a test that runs in <1s. The `envelope` job already has the binary. The sibling
region_empty_confirm.sh made the identical call.)

## 4. check-safety.sh: the new file is inherently clean (verified the rules)

`scripts/check-safety.sh` FAIL/WARN rules (read in full):
- **R1 FAIL**: `killall tmux` / `pkill tmux` / `pkill -f …tmux` / bare `kill-server` (not `-L`-scoped).
- **R2 FAIL**: `exec tmux …` (bare name).
- **R3 WARN** (outside `scripts/`): a file that BOTH prepends to PATH AND has an `exec`/`>>` sink.
- **R4 WARN** (outside `scripts/`): `>> …calls.log`.

The zero-dimension test needs **none** of these: no tmux (so no shim, no `kill-session`), no
`exec`, no `>>`, no append log. => It is check-safety-clean by construction. (Contrast:
envelope_smoke.sh and region_empty_confirm.sh DO use a PATH shim, which is why they're careful
to use absolute `REAL_TMUX` and `kill-session -t <name>` — we inherit none of that complexity.)

NOTE on the WARN rule's `>>` token: `region_empty_confirm.sh`'s own comment notes check-safety's
R3 combo trips on the literal two-greater-than `>>` token AND on the bit-shift spelling. Our
file has neither. We DO use a single `>` redirect for capturing stdout (`>"$out"`) — R3 only
matches the double `>>`, so single `>` is fine (envelope_smoke.sh uses single `>` redirects
extensively and is clean).

## 5. Shell-test conventions to mirror (from envelope_smoke.sh + region_empty_confirm.sh)

- Shebang `#!/bin/sh`; `set -u`.
- `REPO=$(cd "$(dirname "$0")/.." && pwd); cd "$REPO"; BIN=./zig-out/bin/tmux-2html`.
- `fail() { echo "FAIL: $*" >&2; exit 1; }`.
- Build-if-absent: `if [ ! -x "$BIN" ]; then echo "building..."; zig build -Doptimize=ReleaseFast || fail ...; fi`.
- `WORK=$(mktemp -d "${TMPDIR:-/tmp}/t2h-… .XXXXXX"); trap 'rm -rf "$WORK"' EXIT`.
- Final line: `echo "PASS: …"`.

Portable empty-stdout check: `[ ! -s "$out" ]` (true iff the file is zero-size/absent) — avoids
`wc -c` BSD leading-space variance. This is what we use (envelope_smoke uses `wc -c | grep` for
byte-counting; for a pure "is it empty" check `-s` is cleaner and fully portable).

## 6. Composability with the parallel S3

S3 edits `src/region.zig` (the region `Terminal.init` zero-dim guard). S4 edits `tests/`
(new file) + `.github/workflows/ci.yml` (new step). **Zero file overlap** with S3 and with
the committed S1/S2 (which edited `src/render.zig`). S4 touches NO `.zig` source at all (the
unit test it "owns" per the contract was already added by S1). => Clean merge, no conflict.

## 7. The "do NOT add a renderGrid with cols=0 test" constraint

The item contract: "Do NOT add a renderGrid with cols=0 test — that path must remain
unreachable by construction (it would segfault the test binary)." This is honored trivially:
S4 adds no Zig test at all (item (a) already done by S1). The shell test drives the binary
through the PUBLIC CLI surface (`render --cols 0`), which the S1/S2 guards reject *before*
`renderGrid`/`Terminal.init` is ever reached — so no test path touches the segfaulting seam.