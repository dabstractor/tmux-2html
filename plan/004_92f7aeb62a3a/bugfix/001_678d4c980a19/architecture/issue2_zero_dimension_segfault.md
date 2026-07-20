# Issue 2 Architecture: Render --cols 0 / --rows 0 Segfault

## Root Cause
`render --cols 0` / `--rows 0` is accepted by CLI parser (`parseU16` at `cli.zig:128`
returns `0` for `"0"`), flows through `determineCols` (`render.zig:97`:
`if (opts_cols) |c| return c;` — no lower bound) and `render.run()` (`render.zig:756`:
`const rows = opts.rows orelse lineCount(ansi)` — `orelse` only fires on null, not on
explicit `0`), becomes `Size{ .cols = 0, .rows = 0 }`, and is passed to `Terminal.init`
via `renderGrid` (`render.zig:154`). The vendored ghostty-vt **segfaults on a zero-
dimension terminal** (documented in `main.zig:504` comment).

The `pane` path already guards this indirectly (`main.zig:500–506`: keyed on
`result.code != 0`, since failed capture populates cols=0/rows=0). The `render`
subcommand never got the same guard.

## Fix Plan

### Fix Site 1: `determineCols` rejects explicit `--cols 0`
- File: `src/render.zig:97`
- Current: `if (opts_cols) |c| return c;`
- Fixed: `if (opts_cols) |c| { if (c < 1) return error.InvalidWindowSize; return c; }`
- Rationale: `InvalidWindowSize` already exists in `SizeError` (render.zig:45) and is
  already mapped to exit 2 + stderr message by `reportSizeError` (render.zig:715–723).
  The `run()` catch at render.zig:751–754 already converts any `SizeError` → exit 2.
  **No new error-reporting code needed.**

### Fix Site 2: `render.run()` rejects explicit `--rows 0`
- File: `src/render.zig:756–757`
- Current: `const rows = opts.rows orelse lineCount(ansi);`
- After this line, add: `if (rows < 1) { reportSizeError(error.InvalidWindowSize); return 2; }`
- `lineCount` already floors at ≥1, so only an explicit `--rows 0` triggers this.

### Fix Site 3 (defensive): `region.zig` Terminal.init guard
- File: `src/region.zig:326`
- Before `Terminal.init`, add a check: if `cap.cols < 1 or cap.rows < 1`,
  write stderr message and exit 2.
- `cap.cols`/`cap.rows` come from tmux `display-message` (always ≥1 for real panes),
  but a degenerate/resized pane geometry could theoretically yield 0.
- This mirrors the `main.zig:500–506` pane guard rationale.

### Why NOT fix at `parseU16`
`parseU16` is shared by all subcommands. `region`/`pane` get dimensions from tmux
capture, not CLI parsing — rejecting `0` at the parser layer would be the wrong scope.
The guard belongs at the sizing/`Terminal.init` seam where dimensions originate.

### Existing Error Infrastructure (reused, no changes needed)
```
SizeError (render.zig:39) includes: InvalidWindowSize
reportSizeError (render.zig:715) maps → "cannot determine terminal size" + stderr
render.run catch (render.zig:751) → return 2
```

### Tests
1. Unit test: `determineCols(0, false) == error.InvalidWindowSize` (extends existing test at render.zig:1239)
2. The explicit `--rows 0` path cannot be easily unit-tested without Terminal (cross-test GOTCHA).
   It can be covered by a shell integration test: `printf 'x\n' | ./zig-out/bin/tmux-2html render --rows 0`
   should exit non-zero with a message, not segfault.
3. Do NOT add a `renderGrid(.{.cols=0})` test — that path must remain unreachable by construction.

### Precedent: `scrollbackBytes` already does `@max(cols, 1)`
`render.zig:116`: `scrollbackBytes` does `@max(cols, 1)` defensively — evidence the
codebase already anticipates `cols==0` in adjacent math.