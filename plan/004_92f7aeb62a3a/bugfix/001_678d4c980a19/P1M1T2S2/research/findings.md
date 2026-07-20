# Research Findings — P1.M1.T2.S2: Guard explicit `--rows 0` in `render.run()`

> Issue 2, Fix Site 2 (per `architecture/issue2_zero_dimension_segfault.md`).
> This is the **`--rows`** half of the zero-dimension segfault. Fix Site 1
> (`--cols`/determineCols) is the PARALLEL task **S1**, landing concurrently.

## 1. The bug (root cause) — VERIFIED against the live binary

In `render.run()` the `--rows` default is computed inline:

```zig
// src/render.zig run() sizing block
const cols = determineCols(opts.cols, palette.hasControllingTty()) catch |err| {
    reportSizeError(err);
    return 2; // size error
};
const rows = opts.rows orelse lineCount(ansi); // <-- the bug site (Fix Site 2)
const size = Size{ .cols = cols, .rows = rows };
```

`opts.rows orelse lineCount(ansi)` only fires `orelse` on **null** (no `--rows`).
An **explicit `--rows 0`** makes `opts.rows = 0` (the CLI parser `parseU16`
accepts `0`), so `orelse` does NOT fire → `rows = 0` → `Size{rows=0}` →
`renderGrid` → `Terminal.init(.{.cols, .rows=0})` → **ghostty-vt segfaults**
(documented at `main.zig:504`). The default path is SAFE because `lineCount`
(render.zig:105-109) floors at `>= 1` (`"" => 1`, defensive `if (n==0) n=1`).

**Baseline measured** (build `zig build --release=fast`, under `safe-run.sh`):

| command | result |
|---|---|
| `printf 'x\n' \| $BIN render --cols 5 --rows 0` | **Segmentation fault (core dumped), exit 139** |
| `printf 'x\n' \| $BIN render --cols 5 --rows 0 --selection 0,0,0,0` | **exit 139 (segfault)** |
| `printf 'x\n' \| $BIN render --cols 5 --rows 1` | exit 0 (boundary OK) |
| `printf 'x\n' \| $BIN render --cols 5` (omitted `--rows`) | exit 0 (lineCount default) |

→ Only an **explicit** `--rows 0` crashes. Cores went to `systemd-coredump`
(`/proc/sys/kernel/core_pattern` = pipe); no local core files. `preflight.sh`
clean. `--rows 0 --selection` is covered by the SAME guard (the selection arm
runs AFTER `const size`, so a guard placed right after the `const rows` line
fires first for every output arm).

## 2. The fix — one text-anchored inline guard

Insert between the `const rows = ...` line and the `const size = Size{...}` line:

```zig
const rows = opts.rows orelse lineCount(ansi); // default = input line count
if (rows < 1) { // explicit --rows 0 -> exit 2 (Issue 2 segfault guard); lineCount floors at >= 1
    reportSizeError(error.InvalidWindowSize);
    return 2; // size error
}
const size = Size{ .cols = cols, .rows = rows };
```

This reuses the **exact same** machinery the `cols` path uses one line above
(`reportSizeError(err); return 2;`) and the **existing** `error.InvalidWindowSize`
variant (`SizeError`, render.zig:45). `reportSizeError` is **self-contained**
(line 715: it opens its own `std.fs.File.stderr()`), so calling it here — BEFORE
the local `const stderr = std.fs.File.stderr();` is defined (that happens AFTER
`const size`) — is safe and compiles.

## 3. Typecheck VERIFIED — `reportSizeError(error.InvalidWindowSize)` compiles

Load-bearing question: does passing the **error literal** `error.InvalidWindowSize`
where the param type is the **narrower inferred set** `SizeError` typecheck?
Yes — proven with a standalone probe (`research/_probe2.zig`, Zig 0.15.2):

```zig
const SizeError = error{ SizeRequired, NoTty, IoctlFailed, InvalidWindowSize, UnsupportedPlatform };
fn reportSizeError(err: SizeError) void { ... switch (err) { error.InvalidWindowSize => ... } }
pub fn main() void { reportSizeError(error.InvalidWindowSize); }  // compiles + runs OK
```

`zig build-exe` exit 0; runtime prints `"cannot determine terminal size\n"`.
The error literal coerces to `SizeError` because `InvalidWindowSize ∈ SizeError`
(comptime-known member). → The fix uses the verbatim contract form; no `@errSetCast`
needed. (A non-member like `error.NoSuchError` IS rejected, sanity-checked.)

## 4. Composability with S1 (parallel) — VERIFIED, no collision

S1 is **landing concurrently** (verified: `git diff src/render.zig` already shows
S1's edit in the working tree). S1 touches:
- `determineCols` explicit arm (lines 96-99; was 1 line, now 4 → net +3 lines),
- a new unit test after line ~1253.

S1's +3-line edit **shifted** the `run()` block: `const rows = ...` moved from
**line 757 → line 760**. **Therefore S2 MUST anchor on the unique TEXT**
`const rows = opts.rows orelse lineCount(ansi);`, NEVER on a line number (the
docs say "756" / "757"; reality is 760 post-S1, 757 pre-S1). The two edits occupy
**non-overlapping text regions** (S1 at ~line 96 + ~1253; S2 at ~line 760) →
**clean merge, zero conflict**, regardless of which lands first.

## 5. Testing — why S2 adds NO unit test (asymmetry with S1)

S1 included a unit test because `determineCols` is a **pure function** (no stdin,
no `Terminal`) → trivially assertable. **S2 cannot**, because the `rows` value is
computed **inline inside `run()`**, and `run()`:

1. **reads stdin unconditionally first** (`readToEndAlloc` at line ~740). In a
   unit test, stdin may be a TTY → `readToEndAlloc` **blocks forever** (no EOF),
   or a pipe → `""`. Non-deterministic. (This is why render.zig has NO `run:`
   tests today.)
2. then constructs `Terminal.init` etc.

So the `--rows 0` path is **integration-testable only** (architecture doc Test
#2: "cannot be easily unit-tested without Terminal (cross-test GOTCHA)").
`run()` is not refactored to accept `ansi` as a param (out of scope per contract).

**Decomposition (boundary-respecting):**
- **S2 (this task)**: the inline guard ONLY. Regression detection = the binary
  smoke in Validation Level 3 (the implementer RUNS it; `--rows 0` must exit 2 +
  stderr, NOT 139). No committed test file (would collide with S4's scope).
- **S4** ("Add unit and integration tests for zero-dimension rejection"): owns the
  formal shell integration test (`render --rows 0` / `--cols 0` → exit non-zero +
  message, no stdout, no segfault).

S2 deliberately does NOT create a test file — S1 created no file either (it added
a unit test INSIDE render.zig). A shell test file in S2 would duplicate/conflict
with S4.

## 6. Boundaries (do NOT do these in S2)

- ❌ Do NOT refactor `run()` to extract a `determineRows` helper just to make it
  unit-testable — the contract specifies an **inline guard**, and a helper test
  ("explicit 0 returns 0") would be a tautology proving nothing about the guard.
- ❌ Do NOT touch `determineCols`/line 97 (S1 territory) or `region.zig`/line ~326
  (`Terminal.init` guard = S3) or add test files (S4).
- ❌ Do NOT invent a new `SizeError` variant or new message — `InvalidWindowSize`
  already maps to `"tmux-2html render: cannot determine terminal size\n"` (719).
- ❌ Do NOT change `parseU16` (cli.zig) — shared by region/pane (derive dims from
  tmux capture, not CLI); guard belongs at the sizing seam.

## 7. Confidence

The fix is a 3-line inline guard reusing 100% existing error machinery (same
`reportSizeError` + `return 2` as the cols path, same `InvalidWindowSize` variant).
The typecheck of the error-literal→`SizeError` coercion is **proven**. The
baseline segfault (139) and boundary behavior (`--rows 1` / omitted → exit 0) are
**measured**. Composability with S1 is **verified** (non-overlapping text). The
only thing not directly run is the post-fix binary (I may not edit src/ as a
research agent), but the post-fix outcome (exit 2 + the existing stderr message)
follows mechanically from the proven reuse. **Confidence: 10/10.**