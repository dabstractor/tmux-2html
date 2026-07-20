# Research Findings — P1.M1.T2.S1 (Guard `determineCols` against explicit `--cols 0`; Issue 2 segfault)

> Verified hands-on 2026-07-1x in a throwaway build (`/tmp/t2h-cols0-final`) against the live
> repo. The fix + test were applied, built, and run end-to-end: PASS-after (tests exit 0;
> `render --cols 0` exits 2 + stderr msg, not segfault) and FAIL-before (test kept, fix reverted
> → `332/333, 1 failed`, the new test named).

## 1. The bug (confirmed: `src/render.zig:97`)

```zig
pub fn determineCols(opts_cols: ?u16, has_tty: bool) SizeError!u16 {
    if (opts_cols) |c| return c;               // ← line 97: explicit --cols returned UNCHECKED
    if (has_tty) return (try getSize()).cols;
    return error.SizeRequired;
}
```
`parseU16` (cli.zig:128) accepts `"0"`, so `--cols 0` flows here, returns `0` unchecked →
`render.run()` builds `Size{ .cols = 0, … }` → `renderGrid` → `Terminal.init(.{ .cols = 0 })` →
**ghostty-vt segfaults** (documented at `main.zig:504`; the `pane` path already guards this).
Reproduced baseline: `printf 'x\n' | ./bin render --cols 0` → exit **139** (segfault), 3/3.

## 2. The fix (verbatim, exit-0 verified) — one arm gets a lower-bound guard

```zig
// ---- BEFORE (line 97, exact, unique) ----
    if (opts_cols) |c| return c; // explicit --cols wins; never probes the tty
```
```zig
// ---- AFTER ----
    if (opts_cols) |c| { // explicit --cols wins; never probes the tty
        if (c < 1) return error.InvalidWindowSize; // explicit --cols 0 -> exit 2 (Issue 2 segfault guard)
        return c;
    }
```
The `tty` branch (`if (has_tty) return (try getSize()).cols;`) and the `SizeRequired` branch are
**untouched** (contract: "Do NOT change the tty branch or the SizeRequired branch"). The tty
branch ALREADY rejects zero (`getSize` render.zig:81: `if (ws.col == 0 or ws.row == 0) return
error.InvalidWindowSize`) — the CLI arm now mirrors it.

## 3. The error plumbing already exists (reused, NO new code)

`error.InvalidWindowSize` is **already** a `SizeError` variant (render.zig:45), **already**
mapped to a stderr message by `reportSizeError` (render.zig:719:
`"tmux-2html render: cannot determine terminal size\n"`), and **already** converted to exit 2 by
`run()`'s catch (render.zig:751-754):
```zig
const cols = determineCols(opts.cols, palette.hasControllingTty()) catch |err| {
    reportSizeError(err);
    return 2; // size error
};
```
So `--cols 0` → `determineCols` returns `error.InvalidWindowSize` → caught → stderr msg →
`return 2`. **No new error-reporting code, no new message, no signature change.**

## 4. The unit test (verbatim, FAIL-before/PASS-after proven)

`render.zig` already has two `determineCols` tests (line 1239 "explicit cols wins"; line 1246
"no tty + no cols => error.SizeRequired"). Add a focused regression test right after the
SizeRequired test (mirroring the `expectError`/`expectEqual` style):

```zig
test "determineCols: explicit --cols 0 is rejected (Issue 2: zero-dimension segfault guard)" {
    // An explicit --cols 0 must NOT reach Terminal.init (ghostty-vt segfaults on a zero-width
    // terminal). determineCols rejects it with error.InvalidWindowSize, which run() maps to
    // exit 2 + a stderr message (no segfault). The explicit arm returns before the has_tty
    // branch, so getSize is never called => safe to assert both. Boundary value 1 is accepted.
    try std.testing.expectError(error.InvalidWindowSize, determineCols(0, false));
    try std.testing.expectError(error.InvalidWindowSize, determineCols(0, true));
    try std.testing.expectEqual(@as(u16, 1), try determineCols(1, false));
}
```
`determineCols(0, true)` is safe to assert: the explicit arm returns **before** the `has_tty`
branch, so `getSize` (which opens /dev/tty) is never called. (The existing 1239 test relies on
the same property: `determineCols(120, true)` → 120, "getSize NOT called".)

## 5. Empirical proof (throwaway build `/tmp/t2h-cols0-final`)

- **PASS-AFTER** (fix + test applied):
  - `zig build test --release=fast` → **exit 0** (all tests pass, incl. the new one).
  - `printf 'x\n' | ./zig-out/bin/tmux-2html render --cols 0` → **exit 2**; stderr
    `"tmux-2html render: cannot determine terminal size"` (the existing reportSizeError msg).
    **NOT 139 segfault.** ✓
- **FAIL-BEFORE** (test kept, fix reverted to upstream):
  - `zig build test --release=fast` → **exit 1**, `332/333 passed, 1 failed`; the failing test
    named exactly `'determineCols: explicit --cols 0 is rejected (Issue 2…)'`. ✓
  - ⇒ The test is a genuine regression detector (catches the missing guard), not a tautology.
- **Baseline** (no fix, repo binary): `render --cols 0` → segfault **139**; `--cols 1`/`--cols 80`
  → exit 0. (Confirms causality + boundary values.)

## 6. Boundary with sibling / parallel tasks (no collision)

- **Parallel task P1.M1.T1.S3** (Implementing, Issue 1): creates `tests/region_empty_confirm.sh`
  + a ci.yml step. Touches **no `*.zig`**. No conflict with this render.zig edit.
- **T1.S1** (Complete, Issue 1): made `selectionBodyEmpty` `pub` in render.zig:609. Different
  region of the file (line 609 vs my line 97) — no textual conflict.
- **Sibling tasks in T2 (this Issue 2 task) — run LATER, not parallel with S1:**
  - **S2** (`--rows 0` guard): edits `render.run()` at render.zig:756 (the `rows` compute, far
    from line 97). Different line; no conflict.
  - **S3** (`region.zig` Terminal.init guard): edits `region.zig:326`. Different file.
  - **S4** (integration tests): shell/binary-level (`--cols 0`/`--rows 0` via the binary).
    Different scope from S1's function-level unit test.
- ⇒ S1's edit (render.zig:97) + test is self-contained and does not collide with any sibling.

## 7. Scope & validation

- **EDIT** `src/render.zig` line 97 (the explicit-cols arm) + add one unit test (~line 1250).
- **DO NOT touch**: the `tty` branch or `SizeRequired` branch in `determineCols`; `getSize`;
  `reportSizeError`; `run()`; `region.zig` (S3); the `--rows` path (S2); `cli.zig`/`parseU16`
  (the guard belongs at the sizing seam, not the shared parser — see architecture doc "Why NOT
  fix at parseU16").
- **VALIDATION**: `zig build test --release=fast` → exit 0. ReleaseFast is MANDATORY (bare
  `zig build test` Debug hits the `R_X86_64_PC64` linker bug). The binary-level `--cols 0`
  exit-2 check is S4's integration territory but is proven to work here.