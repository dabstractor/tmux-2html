# Research Findings — P1.M1.T2.S3: Defensively guard region.zig Terminal.init against zero dimensions

All findings below are **measured/verified directly** against the live repo (Zig 0.15.2),
not assumed.

## 1. The bug site — region.zig `body()` Terminal.init (line 326)

`src/region.zig` `body()` builds the ghostty-vt `Terminal` **DIRECTLY** (not via `renderGrid`):

```zig
// src/region.zig:326
var t = try Terminal.init(allocator, .{
    .cols = cap.cols,
    .rows = cap.rows,
    .max_scrollback = render.scrollbackBytes(cap.ansi, cap.cols),
});
```

Because region bypasses `render.renderGrid`, the S1/S2 guards in `render.zig`
(`determineCols` rejects `--cols 0`; `run()` rejects `--rows 0`) **do not cover region**.
`cap.cols`/`cap.rows` come from `capture.Captured` (region.zig:302-304 → `regionPrepare` →
`capture.capture`). The vendored ghostty-vt **segfaults on a zero-dimension terminal**
(documented at main.zig:504). So if `cap.cols == 0` or `cap.rows == 0` ever reached line 326,
region would segfault instead of failing gracefully.

## 2. CRITICAL CORRECTION TO THE CONTRACT — stderr is ALREADY in scope

The item contract says: *"Obtain stderr via `std.fs.File.stderr()` if not already in scope
at that point in the code."*

**Verified: stderr IS already in scope.** `body()` declares it as its very first statement:

```zig
// src/region.zig:291-292
pub fn body(allocator: std.mem.Allocator, opts: cli.RegionOpts) anyerror!u8 {
    const stderr = std.fs.File.stderr();   // <-- ALREADY IN SCOPE at line 292
```

The guard at ~line 326 must therefore **REUSE the existing `stderr` const**. Re-declaring
`const stderr = std.fs.File.stderr();` inside the guard block would be a **redeclaration
compile error** (Zig: `error: redeclaration of 'stderr'`). The contract's "if not already in
scope" caveat resolves to "it is in scope — reuse it." This matches how the confirm arm
(region.zig:486) and every other `body()` diagnostic reuses the same `stderr` const.

## 3. The message prefix convention — `tmux-2html region:` is correct

Verified against the live file: region's **runtime diagnostics** all use the
`tmux-2html region: <msg>\n` prefix:

```
region.zig:448  "tmux-2html region: no selection (press v to begin, then Enter)\n"
region.zig:474  "tmux-2html region: render failed\n"
region.zig:486  "tmux-2html region: selection is empty\n"
region.zig:493  "tmux-2html region: cannot resolve output path\n"
region.zig:501  "tmux-2html region: cannot write output file\n"
region.zig:513  "tmux-2html region: cannot determine bin dir for .last-output sidecar\n"
```

(The bare `error: ...` prefix at lines 297/304/403 is used only for *setup* failures —
no-target / cannot-capture / no-tty — before any TUI work; the contract's `tmux-2html region:`
wording matches the runtime-diagnostic convention exactly.)

**Contract message (verbatim, authoritative):**
`"tmux-2html region: capture has zero-dimension pane geometry\n"`

## 4. cap.cols / cap.rows are u16; capture does NOT bound them

`src/capture.zig`:
- `pub const Captured = struct { ansi: []u8, cols: u16, rows: u16, ... }` (lines 45-48).
- `geometry()` (parseGeometry) does `std.fmt.parseInt(u16, cols_s, 10)` with **no lower-bound
  check** (capture.zig:200-207). `parseInt(u16, "0", 10)` succeeds and yields `0`.
- `capture()` returns `{ .cols = geom.cols, .rows = geom.rows, ... }` **unchecked**
  (capture.zig:235-236).

So a degenerate geometry reporting "0" flows unimpeded into `Captured.cols/rows`. For a real
tmux pane `display-message` always reports ≥1, but the guard is cheap insurance against a
degenerate/resized pane or a future capture source. → The `< 1` guard is genuinely needed.

For `u16`, `< 1` is exactly equivalent to `== 0`. The contract uses `< 1`; use that form.

## 5. The defer is registered BEFORE the guard site → early return is SAFE

The capture is acquired and its `defer` is registered at lines 302-310:

```zig
const cap = regionPrepare(allocator, target, runner) catch { ... return 2; };
defer allocator.free(cap.ansi);   // line 310 — registered BEFORE the guard site
```

The guard goes AFTER line 310 (and before line 326). So an early `return 2` in the guard
**correctly triggers `defer allocator.free(cap.ansi)`** — no leak. (palette.resolve at 314 is
infallible and cheap; running it before the guard is harmless, so placing the guard
immediately before the Terminal.init is fine.)

## 6. The pane-path precedent (main.zig:500-506) — the exact rationale to mirror

```zig
// src/main.zig:500-506 (paneBody) — DO NOT EDIT, this is the PRECEDENT
// If prepare failed (bad target / unavailable tmux / option query error), short-circuit
// BEFORE rendering: the failure result has cols=0/rows=0/empty ansi, and feeding ghostty-vt
// a zero-dimension terminal (Terminal.init cols=0) segfaults. Report the summary + exit.
if (result.code != 0) {
    try stdout.writeAll(result.summary);
    try stdout.writeAll("\n");
    return result.code;
}
```

Region's guard mirrors this *rationale* (don't feed ghostty-vt a zero-dimension terminal) but
keys directly on `cap.cols`/`cap.rows` (region has no `result.code`; it has the `Captured`
struct in hand). Exit code = `2` (capture/target error per PRD §5), matching region's other
capture-failure exits (region.zig:297, 304).

## 7. Test ownership — S3 adds the GUARD only; S4 owns formal tests

- The task tree assigns **P1.M1.T2.S4 = "Add unit and integration tests for zero-dimension
  rejection"**. S4 OWNS the test files.
- `region.body()` is NOT unit-testable in isolation: it requires a real tty (calls
  `app.enter`/`render.getSize`/Terminal) and a live tmux capture. There are NO `body:` tests
  in region.zig today; only `regionPrepare:` tests exist (region.zig:783+), which inject a
  fake `capture.Runner`. A `body()` zero-dim test would require injecting a zero-geom
  `Captured` into `body()`, which its signature does not support.
- The zero-dim region case is **not reproducible in practice** (real panes report ≥1), so it
  is a defensive guard — the contract explicitly says "DOCS: none — defensive internal guard;
  for normal pane geometries there is no user-facing behavior change."
- Therefore: **S3 adds the guard and NO test file** (would collide with S4). S3's validation =
  clean build + all existing unit tests pass (nothing regresses) + grep confirming the guard.
  (Mirrors how sibling S2 deliberately added no test, deferring to S4.)

## 8. Composability with parallel S2 (render.zig) — NO conflict

- **S2 (parallel)** edits `src/render.zig` `run()` — the `--rows 0` guard.
- **S3 (this task)** edits `src/region.zig` `body()` — the Terminal.init guard.
- **Different files → zero text-overlap → clean merge.** No line-number anchoring concerns
  across the two. (S1 already landed in render.zig; T1, which also touched region.zig's confirm
  arm, is COMPLETE — so S3 is the sole in-flight region.zig edit.)

## 9. Build/test GOTCHAS (carry over from S2's verified findings)

- `zig build test` in **Debug** hits the Zig 0.15.2 `R_X86_64_PC64` linker bug from bundled
  C++ SIMD libs. **Always use `--release=fast`** (PRD §15; ci.yml runs
  `zig build test -Doptimize=ReleaseFast`).
- The optimized build (`zig build --release=fast`) IS the type check.
- All tmux interaction in validation (if any manual smoke is attempted) MUST use an isolated
  uniquely-named socket (`-L t2h-...`) per AGENTS.md / PRD §0 — never touch the user's live
  tmux. But S3 needs NO tmux for its core validation (build + unit tests + grep).

## 10. Exact insertion — verbatim

FILE: `src/region.zig`. Anchor on the unique `var t = try Terminal.init(allocator, .{ .cols = cap.cols, .rows = cap.rows` line (the ONLY `Terminal.init` in the file). Insert the guard immediately BEFORE it:

```zig
    // (Issue 2 defensive guard) region builds its Terminal DIRECTLY (not via renderGrid), so
    // render.zig's cols/rows guards don't cover it. cap.cols/rows come from capture (always
    // >=1 for a real pane), but a degenerate/resized pane geometry could yield 0 — and
    // Terminal.init on a zero-dimension terminal segfaults (main.zig:504 rationale). Exit 2
    // (capture error, PRD §5) before reaching Terminal.init. Mirrors the pane guard.
    if (cap.cols < 1 or cap.rows < 1) {
        try stderr.writeAll("tmux-2html region: capture has zero-dimension pane geometry\n");
        return 2; // capture/target error (PRD §5)
    }
    var t = try Terminal.init(allocator, .{ .cols = cap.cols, .rows = cap.rows, .max_scrollback = render.scrollbackBytes(cap.ansi, cap.cols) });
```

That is the entire change. `stderr` is the existing `body()`-local const (line 292). No new
imports (all symbols already in scope). No other files touched. No test added (S4 owns tests).