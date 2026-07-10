name: "P3.M3.T1.S2 — region confirm/cancel: renderGrid(selection) + .last-output sidecar + output filename (EDIT src/region.zig ONLY — fill S1's .confirm stub)"
description: |
  Fills the `.confirm => 1` STUB S1 (P3.M3.T1.S1, IN PARALLEL) left in `src/region.zig`'s
  `body()`. On `Enter`/`y`: if no selection begun (`!ctx.sel.active()`) → stderr warn, no file,
  exit 1; else render the user's linewise/block selection to HTML via `render.toGhosttySelection`
  (P3.M2.T2.S2, SHIPPED pub) + the vendored ScreenFormatter against the EXISTING `ctx.grid` (no
  Terminal rebuild), write it to `--output` or a collision-safe `<session>-<unixtime>-<pid>.html`
  in the configured output dir (reuses the SHIPPED `capture.*` filename helpers), `xdg-open` if
  `@tmux-2html-open`/`--open`, write the BARE path to `<selfExeDir>/.last-output` (the sidecar the
  wrapper display-messages — PRD §7.5/§9.3), exit 0. The cancel path (`q`/`Esc`-no-sel/`Ctrl-c` ⇒
  exit 1, no output) is S1's `.quit`/`else` arms — UNCHANGED. Terminal restore (`app.exit`) runs in
  BOTH paths (S1's body-scope `defer`; S2 calls it FIRST in the arm for cooked-mode warns —
  idempotent). EDITS `src/region.zig` ONLY: the `.confirm` arm + ~6 small module-private helpers
  (`renderSelectionHtml`, `resolveOutputPath`, `regionPid`, `selfBinDir`, `writeLastOutput`,
  `writeHtmlAtomic`, `readBoolOption`, `readFontOption`) + the `ghostty_format`/`builtin` imports
  if S1 didn't add them. NO new file, NO edit to render.zig (uses pub `toGhosttySelection`)/
  cli.zig/main.zig/build.zig. The NEW unit-testable surface (resolveOutputPath, writeLastOutput,
  writeHtmlAtomic, readBoolOption, readFontOption, regionPid, selfBinDir — NONE touch a Terminal ⇒
  safe as separate test fns) + manual in-tmux smoke (the arm/renderSelectionHtml need a real pty).

---

## Goal

**Feature Goal**: Complete the `tmux-2html region` confirm/cancel flow per PRD §7.5 + §5.3 + §9.3 +
arch tui_region.md §7 so that, inside the `prefix C-o` display-popup, after a user selects a
linewise or rectangular region and presses `Enter`/`y`, the binary renders EXACTLY that selection
to a standalone HTML file, writes its path to the `.last-output` sidecar the wrapper flashes on the
status line, and exits 0; and if there is no selection it warns + exits 1 (no file). Cancel
(`q`/`Esc`-no-sel/`Ctrl-c`) already exits 1 with no output (S1). This is the LAST piece that makes
`prefix C-o` → select → `Enter` produce an HTML file of exactly the selection + a tmux status-line
message of the path.

**Deliverable**: `src/region.zig` EDITED — (1) the `.confirm` arm of `body()`'s `switch (action)`
replaced (S1 stubbed it `=> 1`) with the full confirm-render flow (§1 of design_notes.md, verbatim);
(2) the module-private helpers it calls (`renderSelectionHtml`, `resolveOutputPath`, `regionPid`,
`selfBinDir`, `writeLastOutput`, `writeHtmlAtomic`, `readBoolOption`, `readFontOption`); (3) the
`ghostty_format` + `builtin` imports if S1's region.zig doesn't already have them; (4) unit tests
for the PURE/Runner-seamed/fs-only helpers (resolveOutputPath, writeLastOutput, writeHtmlAtomic,
readBoolOption, readFontOption, regionPid, selfBinDir) as SEPARATE `test` fns. **No other source
file changes.** render.zig's `toGhosttySelection`/`clampExtent` are CONSUMED unchanged; cli.zig's
`RegionOpts` unchanged; main.zig's dispatch (S1) unchanged; build.zig unchanged.

**Success Definition**:
- Inside a `tmux display-popup`, after `v`-selecting a region + `Enter`: an HTML file appears at
  `--output` (if given) or `<output-dir>/<session>-<unixtime>-<pid>.html` containing EXACTLY the
  selected cells (linewise = full rows; block = the rectangle) in full color, `.last-output` (in
  the binary's own dir) holds the BARE path, and — after the popup closes — the status line flashes
  `tmux-2html: wrote <path>` (the wrapper reads the sidecar). Exit 0.
- `Enter`/`y` with NO selection begun → stderr `tmux-2html region: no selection …`, NO file, NO
  sidecar, exit 1.
- `q`/`Esc`(no selection)/`Ctrl-c` → exit 1, no file, no sidecar (S1's `.quit`/`.else` — unchanged).
- The terminal is ALWAYS restored (cooked termios + primary screen) on every exit — S1's
  `defer app.exit(state)` + S2's early `app.exit(state)` in the arm (idempotent).
- `@tmux-2html-font` is honored in the HTML (the binding passes only `--target`, so region reads
  font/open/output-dir itself); `@tmux-2html-open` (default `on`) triggers `xdg-open`.
- `zig build test -Doptimize=ReleaseFast` green (new helper tests + all existing); `zig build
  -Doptimize=ReleaseFast` links; `region --help` still prints help + exit 0 (S1, unaffected).

## User Persona (if applicable)

**Target User**: a tmux user who pressed `prefix C-o` (PRD §9.3) to interactively select a colored
region of a pane's scrollback and render it to HTML.

**Use Case**: browse full scrollback in a vim-like overlay, `v`-select a linewise or block region,
`Enter` to render exactly it. (Browsing/selecting/cancelling = S1; confirm→render+sidecar = S2.)

**User Journey**: popup opens → select → `Enter` → HTML file of the selection is written, popup
closes (`-E`), status line flashes `tmux-2html: wrote <path>`. Or `Enter` with no selection → warn,
popup closes, exit 1, nothing written.

**Pain Points Addressed**: faithful full-color rendering of EXACTLY the selected cells (linewise +
rectangular; wide glyphs atomic via the formatter); the popup↔status-line gap bridged by the
`.last-output` sidecar (the popup has no tmux message channel).

## Why

- **Closes the region feature.** S1 wires the entire interactive loop (motion/select/search/quit⇒1)
  but STUBS `.confirm` (exit 1, no file). S2 is the confirm→render flow — without it `prefix C-o` →
  select → `Enter` produces nothing. S2 is what makes the selection renderable + the path reportable.
- **Faithful to PRD §7.5 + §9.3 + arch §7.** `Enter`/`y` renders the selection to HTML (`--output`
  or the collision-safe filename), `--open` if set, writes the path to `.last-output` for the
  wrapper to `display-message`, exit 0; empty selection / cancel ⇒ exit 1, no output.
- **Reuses, never duplicates.** S2 is GLUE: `render.toGhosttySelection` (P3.M2.T2.S2) + the vendored
  `ScreenFormatter` (the exact block `render.renderGrid` uses) for the selection render; the SHIPPED
  `capture.resolveOutputDir`/`querySessionName`/`buildOutputFilename`/`buildOutputPath` for the
  filename; `render.spawnXdgOpen` for `--open`; `palette.Colors` (S1's ctx) for color. The only NEW
  logic is the arm's orchestration + the sidecar/selfExeDir/option-read/atomic-write helpers.
- **Honors the binding contract.** The `C-o` wrapper (P2.M2.T2.S2, shipped) passes ONLY
  `--target #{pane_id}` and reads `$TMUX_2HTML_BIN/.last-output` after the popup closes. So region
  reads font/open/output-dir itself (docs/CONFIGURATION.md "How options are read") + writes the
  sidecar to its OWN bin dir (exported vars don't reach the popup child).

## What

A single EDIT to `src/region.zig` (the file S1 creates): replace the `.confirm => 1` stub in
`body()`'s `switch (action)` with the confirm-render labeled block, + add the ~6 helpers it calls +
their unit tests. See `research/design_notes.md` for the VERBATIM Zig (it IS the spec). Highlights:

- **The `.confirm` arm** (design_notes §1): `app.exit(state)` first (cooked-mode restores) → if
  `!ctx.sel.active()` warn + exit 1 → read `@tmux-2html-font`/`@tmux-2html-open` (binding passes
  only `--target`) → `renderSelectionHtml` (toGhosttySelection + ScreenFormatter against ctx.grid)
  → `resolveOutputPath` (`--output` or `<session>-<ts>-<pid>.html` in the output dir) →
  `makePath(dirname)` → `writeHtmlAtomic` → `selfBinDir` + `writeLastOutput` (sidecar) →
  `spawnXdgOpen` if open → exit 0. Every error path → stderr msg + exit 1 (no partial sidecar).
- **renderSelectionHtml** (§2a): `render.toGhosttySelection(ctx.sel, ctx.grid, ctx.tty_cols)` →
  `fmt.ScreenFormatter.init(ctx.grid, …)` (VERBATIM copy of renderGrid's options block) → owned HTML.
- **resolveOutputPath** (§2b): `opts.output` wins; else `capture.resolveOutputDir` +
  `capture.querySessionName` + `capture.buildOutputFilename(…, regionPid())` + `capture.buildOutputPath`.
- **selfBinDir** (§2c): `std.fs.selfExePath(&buf)` (Zig 0.15.2 fs.zig:545) → `dirname`. (region
  can't see `$TMUX_2HTML_BIN`.)
- **writeLastOutput** (§2c): write the BARE path to `<bin_dir>/.last-output` (dir-scoped ⇒ testable).
- **writeHtmlAtomic** (§2d): render.zig's `writeFileAtomic` idiom (temp + rename, same dir).
- **readBoolOption/readFontOption** (§2e): `capture.queryOption` for `@tmux-2html-open`/font.

### Success Criteria

- [ ] `body()`'s `.confirm` arm implements the full flow; `.quit`/`.else` arms UNCHANGED (exit 1).
- [ ] `Enter`/`y` + active selection ⇒ HTML file of EXACTLY the selection written; `.last-output`
      sidecar holds the BARE path; exit 0 (manual Level 3/4 — needs a real pty + tmux pane).
- [ ] `Enter`/`y` + NO selection ⇒ stderr warn, NO file, NO sidecar, exit 1.
- [ ] `q`/`Esc`(no-sel)/`Ctrl-c` ⇒ exit 1, no output (S1, unchanged).
- [ ] `@tmux-2html-font` honored; `@tmux-2html-open`/`--open` ⇒ `xdg-open`; `--output` or auto-name.
- [ ] Terminal restored on EVERY exit (S1 defer + S2 early `app.exit`).
- [ ] `zig build test -Doptimize=ReleaseFast` green (new helper tests + existing); binary links.

## All Needed Context

### Context Completeness Check

_If someone knew nothing about this codebase, would they have everything needed to implement this
successfully?_ **YES.** This PRP embeds: the EXACT `.confirm` arm (verbatim Zig in design_notes §1);
every helper with its full body (§2a–§2e); the verbatim ScreenFormatter block to copy (cited from
render.zig renderGrid ~lines 140-150); the precise S1 body locals in scope (§0); the toGhosttySelection
contract (infallible; pins tied to ctx.grid; WHY format-ctx.grid not renderGrid-rebuild — §3); the
.last-output sidecar contract (bare path, region's OWN bin dir via selfExePath, best-effort); the
binding-passes-only-`--target` fact (⇒ region reads options itself); the testable surface + a
self-contained FakeTmux (§4); every gotcha (§5); and the build/test commands.

### Documentation & References

```yaml
# MUST READ — the COMPLETE build spec for THIS subtask (authored from primary source, verbatim Zig).
- docfile: plan/001_0c8587f91cb2/P3M3T1S2/research/design_notes.md
  why: The verbatim .confirm arm + every helper (renderSelectionHtml/resolveOutputPath/regionPid/
       selfBinDir/writeLastOutput/writeHtmlAtomic/readBoolOption/readFontOption), the render approach
       rationale (§3), the testable surface + FakeTmux (§4), the gotchas (§5). This IS the spec.
  section: "§1 The confirm arm" + "§2 The helpers" + "§3 render approach" + "§4 tests" + "§5 gotchas"

# The S1 PRP — region.zig's EXACT shape (body, RegionCtx, the .confirm stub S2 fills). CONTRACT.
- docfile: plan/001_0c8587f91cb2/P3M3T1S1/PRP.md
  why: S1 CREATES region.zig with body() whose switch stubs `.confirm => 1`. S2 treats S1's body as a
       contract: the in-scope locals (allocator/opts/target/cap/grid/total_rows/colors/ctx/state),
       RegionCtx fields (sel/grid/colors/tty_cols/font), app.enter/exit + the idempotent restore,
       the .quit/.else arms (cancel ⇒ exit 1, UNCHANGED by S2). Read §0 of design_notes (the excerpt).
  section: "Goal/Deliverable (body, RegionCtx)" + "DOWNSTREAM (P3.M3.T1.S2 … the S2 seam)"

# PRD + architecture (the behavioral contract)
- docfile: PRD.md
  why: §7.5 (Enter/y ⇒ render selection → HTML to --output/--open, write path to sidecar, exit 0;
       empty ⇒ warn no file exit 1; q/Esc(no-sel)/Ctrl-c ⇒ exit 1 no output); §5.3 (region flags);
       §9.2 (@tmux-2html-open default on, @tmux-2html-font, @tmux-2html-output-dir); §9.3 (the C-o
       wrapper reads $TMUX_2HTML_BIN/.last-output; region writes the result path there); §13
       (collision-safe <session>-<ts>-<pid> filenames; wide cells atomic).
  section: "7.5 Confirm / cancel" + "5.3 region" + "9.2 Options" + "9.3 Bindings"
- docfile: plan/001_0c8587f91cb2/architecture/tui_region.md
  why: §7 "Confirm / cancel / sidecar" — the verbatim behavior (Enter/y ⇒ render → --output or
       output-dir/session-timestamp-pid, --open if set, write path to .last-output, exit 0; empty ⇒
       warn no file exit 1; q/Esc(no-sel)/Ctrl-c ⇒ exit 1). §1 (the popup is a real pty; no tmux
       message channel inside ⇒ the sidecar).
  section: "§7 Confirm / cancel / sidecar"

# The .last-output sidecar CONTRACT (the cross-task seam with the wrapper, P2.M2.T2.S2).
- docfile: plan/001_0c8587f91cb2/P2M2T2S2/PRP.md
  why: The wrapper (shipped) does: `rm -f $BIN/.last-output`; `display-popup … region --target #{pane_id}`;
       `if [ -f $BIN/.last-output ]; then out=$(cat …); display-message "tmux-2html: wrote $out"; fi`.
       So region MUST write the BARE path (no "wrote" prefix) to `.last-output` in its OWN bin dir,
       ONLY on confirm (cancel/empty ⇒ no write ⇒ the rm -f keeps it absent ⇒ no stale message).
       GOTCHA (from this PRP): exported loader vars ($TMUX_2HTML_BIN) do NOT reach run-shell/popup
       children ⇒ region derives its bin dir via /proc/self/exe (selfExePath), NOT from an env var.
  section: "Goal (sidecar content/lifecycle)" + "Known Gotchas (.last-output sidecar contract)"

# The upstream modules/functions S2 CONSUMES (all SHIPPED — read to confirm signatures, then call).
- file: src/render.zig   # the SELECTION BRIDGE + the formatter block to copy (P3.M2.T2.S2 ADDED these)
  why: (a) `pub fn toGhosttySelection(sel: select.Sel, screen: *const Screen, cols: u16) Selection`
       — INFALLIBLE (returns Selection, NOT an error union; CLAMPS instead of erroring). Returns a
       Selection whose PINS are tied to `screen` ⇒ format against THAT screen (ctx.grid), NOT a
       rebuilt Terminal. An inactive sel ⇒ a whole-grid Selection (but S2 only calls when active()).
       (b) The ScreenFormatter block inside `renderGrid` (~lines 140-150) is the VERBATIM pattern
       renderSelectionHtml copies: `fmt.ScreenFormatter.init(screen, .{.emit=.html, .background,
       .foreground, .palette=&colors.palette, .font})` + `f.content=.{.selection=gs}` + `f.extra=
       .styles` + `out.print("{f}", .{f})`. (c) `pub fn spawnXdgOpen(path, alloc)` (reaps; best-effort).
       (d) `pub fn clampExtent(ext, cols, last_row) cli.SelectionCoords` — the ALTERNATIVE path (§3).
  pattern: "renderGrid's formatter block is the recipe; renderSelectionHtml reuses it with ctx.grid +
            the toGhosttySelection result instead of a fresh Terminal + buildSelection."
  gotcha: "toGhosttySelection is INFALLIBLE — do NOT `try` it as an error union. renderToFileAtomic
           renders the WHOLE grid (sel:null) — unusable for a selection; writeHtmlAtomic reimplements
           the atomic idiom for the pre-rendered buffer. writeFileAtomic is PRIVATE — do not edit
           render.zig to expose it (P3.M2.T2.S2 owns render.zig in parallel)."
- file: src/tui/select.zig   # P3.M2.T2.S1 (SHIPPED) — the selection MODEL S2 renders
  why: `Sel.active() bool` (mode != .none — S2's empty guard); `Sel.extent(cols) ?view.Selection`
       (consumed by toGhosttySelection, NOT by S2 directly). S2 reads `ctx.sel` (S1 keeps it in sync
       with the cursor). `Mode = enum{none,linewise,block}`.
  gotcha: "active() is the empty-selection signal. S2 does NOT call extent() itself (toGhosttySelection
           does, internally)."
- file: src/capture.zig   # P2.M1 (SHIPPED) — the filename + option helpers S2 reuses
  why: `pub const real: Runner` (the prod runner — region passes it to queryOption/resolveOutputDir/
       querySessionName); `pub fn resolveOutputDir(runner, alloc) ![]u8` (reads @tmux-2html-output-dir
       → XDG → HOME; `error.NoHome`); `pub fn querySessionName(runner, alloc, pane) ![]u8`; `pub fn
       queryOption(runner, alloc, name) ![]u8` ("" for unset); `pub fn buildOutputFilename(alloc,
       session, unixtime, pid) ![]u8` (`<sanitized-session>-<ts>-<pid>.html`); `pub fn buildOutputPath(
       alloc, dir, fname) ![]u8`; `Runner = struct{ctx, runFn}` (FakeTmux in tests).
  pattern: "resolveOutputPath mirrors pane's panePrepare path branch (main.zig) but via these pub
            helpers. capture is GHOSTTY-FREE ⇒ its fns are safe to call from region's unit tests."
- file: src/main.zig   # paneBody + panePrepare + currentPid — the TEMPLATE S2 mirrors (READ ONLY)
  why: (a) `paneBody` is the precedent: resolveOutputDir + makePath + renderToFileAtomic + truncation
       notice + spawnXdgOpen. region's confirm arm mirrors its structure (minus truncation — region
       renders a selection, not a capture). (b) `panePrepare`'s output-path branch (`opts.output` else
       `<session>-<ts>-<pid>.html`) is EXACTLY resolveOutputPath's logic. (c) `fn currentPid() i32`
       (private: Linux getpid else 0) — region reimplements it as `regionPid` (can't call main.zig's
       private fn; region must not edit main.zig — S1 owns the dispatch wiring).
  gotcha: "Do NOT edit main.zig. paneBody uses opts.font/opts.open (the cli flags) because the O
           binding passes only --target — but region READS @tmux-2html-font/@tmux-2html-open itself
           (the documented, correct behavior; see docs/CONFIGURATION.md). S2 follows the docs."
- file: src/tui/app.zig   # P3.M1.T1.S1 (SHIPPED) — enter/exit/runEvents
  why: `enter() !State` (S1 calls it; `error.NoTty` if stdin isn't a tty); `exit(State)` (idempotent
       restore via the atomic `entered` guard — S2 calls it FIRST in the arm; S1's defer is a later
       no-op); `runEvents(handler) !Action` (returns .quit/.confirm). `Action = enum{none,quit,confirm}`.
  gotcha: "exit() is IDEMPOTENT — calling it in the arm + S1's defer is safe (no double-restore bug).
           ctx.grid stays valid after exit() (the in-memory Terminal is freed by S1's defer t.deinit,
           independent of the display-terminal restore)."
- file: src/ghostty_format.zig   # the vendored formatter — ADD this import to region.zig (if absent)
  why: `ScreenFormatter.init(screen, Options)` + `.content = .{ .selection: ?Selection }` + `.extra =
       .styles` + `print("{f}", .{f})`. `Options{ emit, background, foreground, palette, font }`. This
       is what renderGrid uses; renderSelectionHtml reuses it verbatim (design_notes §2a).
  gotcha: "region.zig must `const fmt = @import(\"ghostty_format.zig\");` (S1's import list does NOT
           include it — S2 adds it). It is a sibling file in src/, so the bare import path works."
- file: tmux-2html.tmux   # the wrapper that READS .last-output (lines 158-189) — READ ONLY
  why: CONFIRMS the sidecar contract: the C-o wrapper does `rm -f $BIN/.last-output` (pre-popup clear),
       `display-popup … region --target '#{pane_id}'`, then `if [ -f $BIN/.last-output ]; out=$(cat …);
       display-message "tmux-2html: wrote $out"; fi`. So region writes the BARE path on confirm only;
       cancel/empty ⇒ no write ⇒ the rm keeps it absent ⇒ no message. Lines 81-82, 163-164 confirm
       region reads font/open/output-dir itself (the binding passes ONLY --target).
  section: "§3 option reader (lines 81-82)" + "C-o binding block (lines 158-189)"

# Zig std primary source (in the installed toolchain) — the selfExePath API S2 uses.
- file: /home/dustin/.local/opt/zig-x86_64-linux-0.15.2/lib/std/fs.zig
  why: `pub fn selfExePath(out_buffer: []u8) SelfExePathError![]u8` (line 545 — writes into a caller
       buffer, returns a slice into it; use a `[std.fs.max_path_bytes]u8` buffer). Alt:
       `selfExePathAlloc(allocator) ![]u8` (line 521). VERIFIED in the installed Zig 0.15.2.
- url: https://ziglang.org/download/0.15.1/release-notes.html   # Writer/Reader API (the new IO)
  why: `std.Io.Writer.Allocating.initCapacity(alloc, n)` + `.writer` + `.buffered()` is the verified
       buffer-capture pattern renderGrid's tests use (renderToOwned). renderSelectionHtml mirrors it.
```

### Current Codebase tree (run `tree src/` in the project root)

```bash
$ tree src/ -I 'zig-cache' --dirsfirst
src/
├── tui/
│   ├── app.zig        # P3.M1.T1 — enter/exit/runEvents + Event/Action (SHIPPED)
│   ├── input.zig      # P3.M2.T1.S1 — Decoder/feed/Key/KeyKind (SHIPPED)
│   ├── view.zig       # P3.M1.T2 — render/renderStatus/decodeRow/findMatches/Pos/Viewport/Selection (SHIPPED)
│   ├── select.zig     # P3.M2.T2.S1 — Sel/active/extent/applyAction/Mode (SHIPPED)
│   └── motion.zig     # P3.M2.T1.S2 — Cursor/applyMotion/SliceGrid (SHIPPED)
├── capture.zig        # P2.M1 — real/Runner/resolveOutputDir/querySessionName/queryOption/buildOutput* (SHIPPED)
├── cli.zig            # parg parser + RegionOpts (SHIPPED — UNCHANGED)
├── ghostty_format.zig # vendored ScreenFormatter (SHIPPED — ADD import to region.zig)
├── golden_test.zig    # P1.M4 golden harness
├── main.zig           # dispatch + paneBody/panePrepare/currentPid (SHIPPED — UNCHANGED; the TEMPLATE)
├── palette.zig        # P1.M2 — resolve/Colors (SHIPPED)
├── region.zig         # P3.M3.T1.S1 (IN PARALLEL) — body/regionPrepare/RegionCtx/regionHandle/repaint ← THIS SUBTASK EDITS
└── render.zig         # P1.M3/P1.M4/P3.M2.T2.S2 — renderGrid/toGhosttySelection/clampExtent/spawnXdgOpen (SHIPPED — CONSUME)
```

### Desired Codebase tree with files to be added/edited

```bash
src/
└── region.zig         # EDIT (S1 created it): fill the .confirm arm + add the §2 helpers + their tests
                         #      + the ghostty_format/builtin imports if S1 didn't add them.
# (No new files; NO edit to render.zig/cli.zig/main.zig/build.zig/tmux-2html.tmux.)
```

`src/region.zig` new responsibilities (the ONLY edited file):
- The `.confirm` arm of `body()`'s `switch (action)` — the full confirm-render flow (design_notes §1).
- `fn renderSelectionHtml(allocator, ctx, font) ![]u8` — toGhosttySelection + ScreenFormatter → owned HTML.
- `fn resolveOutputPath(allocator, opts, target, runner) ![]u8` — `--output` or collision-safe auto-name.
- `fn regionPid() i32` — Linux getpid else 0 (mirrors main.zig's private currentPid).
- `fn selfBinDir(allocator) ![]u8` — /proc/self/exe dir (where `.last-output` goes).
- `fn writeLastOutput(bin_dir, output_path) !void` — write the BARE path to `<bin_dir>/.last-output`.
- `fn writeHtmlAtomic(allocator, path, bytes) !void` — atomic temp+rename (render.zig's writeFileAtomic idiom).
- `fn readBoolOption(runner, alloc, name, default) bool` — `@tmux-2html-open` parser.
- `fn readFontOption(runner, alloc) ![]u8` — `@tmux-2html-font` reader (default "monospace").
- Unit tests for the helpers (resolveOutputPath/writeLastOutput/writeHtmlAtomic/readBoolOption/
  readFontOption/regionPid/selfBinDir) as SEPARATE `test` fns (NONE touch a Terminal ⇒ safe).

### Known Gotchas of our codebase & Library Quirks

```zig
// CRITICAL: zig build test MUST use -Doptimize=ReleaseFast. Debug hits the R_X86_64_PC64 linker
//   bug with the bundled ghostty C++ SIMD libs (PRD §15). EVERY validation command uses ReleaseFast.

// CRITICAL: the cross-test GOTCHA — ghostty-vt Terminal.init corrupts process-global state such
//   that a Terminal.init in a SEPARATE test fn CRASHES. renderSelectionHtml/the .confirm arm touch
//   ctx.grid (Terminal) ⇒ they are NOT unit-tested (compile + manual). S2's unit-testable helpers
//   (resolveOutputPath/writeLastOutput/writeHtmlAtomic/readBoolOption/readFontOption/regionPid/
//   selfBinDir) do NOT touch a Terminal ⇒ SAFE as separate test fns. The selection→HTML fidelity
//   they rely on is ALREADY proven in render.zig's single Terminal scope (P3.M2.T2.S2 tests).

// CRITICAL: call app.exit(state) FIRST in the .confirm arm. The empty-selection warn (stderr) +
//   xdg-open must happen in COOKED mode, not raw/alt-screen (else the warn is garbled). app.exit is
//   IDEMPOTENT (app.zig atomic `entered` guard) ⇒ S1's body-scope `defer app.exit(state)` is a later
//   no-op. ctx.grid stays valid after app.exit (the in-memory Terminal is freed by S1's defer t.deinit).

// CRITICAL: toGhosttySelection is INFALLIBLE (returns Selection, NOT an error union — it CLAMPS).
//   Do NOT `try` it. Its pins are tied to ctx.grid ⇒ format against ctx.grid (ScreenFormatter), NOT
//   a rebuilt renderGrid Terminal. See design_notes §3 for the rationale + the clampExtent+renderGrid
//   ALTERNATIVE (equally valid; prefer toGhosttySelection since it's what P3.M2.T2.S2 built it for).

// CRITICAL: the binding passes ONLY --target. So opts.font/opts.open are the cli defaults; region
//   reads @tmux-2html-font/@tmux-2html-open ITSELF via capture.queryOption (tmux-2html.tmux lines
//   81-82, 163-164; docs/CONFIGURATION.md "How options are read"). opts.open is OR'd in (direct
//   `region --open`). output: opts.output if non-null, else resolveOutputDir auto-name.

// CRITICAL: the .last-output sidecar = the BARE output path (NO "wrote" prefix — the wrapper
//   prepends it) in region's OWN bin dir (derived via std.fs.selfExePath — $TMUX_2HTML_BIN is NOT
//   visible to the popup child). Write ONLY on confirm; cancel/empty ⇒ no write (the wrapper's
//   pre-popup `rm -f` keeps it absent ⇒ no stale message). Best-effort: a sidecar failure must NOT
//   fail the render (the HTML file is already written) — log to stderr + continue to exit 0.

// CRITICAL: region must NOT print the summary to stdout. The popup closes via -E on exit; stdout is
//   the popup pty. The path reaches the user ONLY via .last-output → wrapper → display-message
//   (PRD §7.5: the popup has no tmux message channel). The ONLY stderr output is warn/error lines.

// CRITICAL: writeHtmlAtomic + regionPid DUPLICATE render.zig's writeFileAtomic / main.zig's
//   currentPid (both private). INTENTIONAL — keeps render.zig (P3.M2.T2.S2 owns it in parallel) +
//   main.zig (S1 owns the dispatch wiring) untouched. ~15 + 3 lines, cited verbatim.

// CRITICAL: selfExePath buffer = std.fs.max_path_bytes (Zig 0.15.2 fs.zig:545). `selfExePath(
//   out_buffer: []u8) SelfExePathError![]u8` writes into the caller buffer + returns a slice into it.
//   dirname(exe) orelse "." for a bare filename. selfExePathAlloc(allocator) (fs.zig:521) is the
//   allocating alternative — either works.

// NOTE: the empty-selection guard is !ctx.sel.active(). S1's handler returns .confirm on Enter/y
//   REGARDLESS of sel state (it does not gate confirm on a selection). So a user CAN press Enter
//   with no selection; the .confirm arm catches it (warn + exit 1). "Empty" == inactive sel (a
//   selection covering blank cells is NOT empty — it renders, per the user's choice).
```

## Implementation Blueprint

### Data models and structure

No new PUBLIC types. S2 reuses `cli.RegionOpts`, `capture.{Runner, real, resolveOutputDir,
querySessionName, queryOption, buildOutputFilename, buildOutputPath}`, `palette.Colors`,
`render.{toGhosttySelection, spawnXdgOpen}`, `select.Sel`, `app.State`, `view.{Selection, Pos}`,
S1's `RegionCtx`, the vendored `fmt.ScreenFormatter`, and ghostty-vt `Screen`/`Selection`. The
helpers are module-private `fn`s. Verbatim Zig for every helper is in `research/design_notes.md §2`.

```zig
// ---- ADD to src/region.zig imports (if S1 didn't) ----
const builtin = @import("builtin");           // regionPid: os.tag == .linux
const fmt = @import("ghostty_format.zig");    // ScreenFormatter (the renderGrid formatter block)
// (S1 already imports: std, cli, capture, palette, render, app, view, input, motion, select, ghostty_vt)
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: EDIT src/region.zig — add the ghostty_format + builtin imports (if S1 didn't)
  - ADD `const fmt = @import("ghostty_format.zig");` + `const builtin = @import("builtin");` near
    S1's imports (if absent). VERIFY S1's import block first — only add what's missing.
  - WHY: renderSelectionHtml uses fmt.ScreenFormatter; regionPid uses builtin.os.tag.
  - GOTCHA: ghostty_format.zig is a SIBLING in src/ ⇒ the bare `@import("ghostty_format.zig")` path.

Task 2: ADD the helpers (design_notes §2a–§2e) — regionPid, readBoolOption, readFontOption FIRST
        (PURE/Runner-seamed; no dep on the arm)
  - IMPLEMENT regionPid (§2b tail), readBoolOption (§2e), readFontOption (§2e) EXACTLY as design_notes.
  - PATTERN: capture.queryOption returns "" for unset ⇒ apply the default. readBoolOption:
    "on"/"true"/"yes"/"1" (case-insensitive via std.ascii.eqlIgnoreCase) ⇒ true; "" ⇒ default; else false.
  - GOTCHA: readBoolOption/readFontOption take `runner: capture.Runner` (region passes capture.real
    in the arm; FakeTmux in tests). They are SAFE as separate test fns (NO Terminal).

Task 3: ADD resolveOutputPath + selfBinDir + writeLastOutput + writeHtmlAtomic (design_notes §2b–§2d)
  - IMPLEMENT resolveOutputPath (§2b): opts.output ⇒ dupe; else resolveOutputDir + querySessionName
    + buildOutputFilename(…, regionPid()) + buildOutputPath. Free intermediates (out_dir/session/fname).
  - IMPLEMENT selfBinDir (§2c): selfExePath(&max_path_bytes buf) → dirname orelse "." → dupe.
  - IMPLEMENT writeLastOutput (§2c): join bin_dir + "/.last-output" → createFile(.truncate) → writeAll(bare path) → close.
  - IMPLEMENT writeHtmlAtomic (§2d): VERBATIM render.zig writeFileAtomic idiom (temp + rename, same dir).
  - GOTCHA: writeLastOutput uses std.fs.path.join (page_allocator) OR allocPrint — match region.zig's
    idiom + free it. writeHtmlAtomic cleans up the temp on error (errdefer close+delete).

Task 4: ADD renderSelectionHtml (design_notes §2a) — the render against ctx.grid
  - IMPLEMENT renderSelectionHtml EXACTLY as design_notes §2a: Allocating writer → toGhosttySelection
    (ctx.sel, ctx.grid, ctx.tty_cols) → ScreenFormatter.init(ctx.grid, .{emit/html/background/
    foreground/palette/font}) → f.content=.{.selection=gs} → f.extra=.styles → print → dupe(buffered()).
  - COPY the ScreenFormatter options block VERBATIM from render.renderGrid (render.zig ~lines 140-150):
    same .emit/.background/.foreground/.palette/.font. The ONLY diffs: screen=ctx.grid, selection=gs.
  - GOTCHA: toGhosttySelection is INFALLIBLE (no `try`). NOT unit-testable (ctx.grid ⇒ Terminal ⇒
    cross-test GOTCHA); compile + manual. Fidelity proven in render.zig's tests.

Task 5: EDIT body() — replace the `.confirm => 1` stub with the confirm-render arm (design_notes §1)
  - CHANGE `.confirm => 1,` to the labeled block in design_notes §1 (app.exit first → empty guard →
    read font/open → renderSelectionHtml → resolveOutputPath → makePath → writeHtmlAtomic →
    selfBinDir+writeLastOutput → spawnXdgOpen → break :blk 0). Every error path ⇒ stderr + break :blk 1.
  - PRESERVE the `.quit => 1` + `else => 1` arms (S1's cancel path — UNCHANGED).
  - GOTCHA: app.exit(state) FIRST (cooked-mode warns; idempotent). The arm references S1's body
    locals (state/ctx/opts/target/allocator/capture.real) — all in scope. Label the block
    `confirm_render` (or any label) so the breaks are explicit.

Task 6: ADD unit tests for the helpers (design_notes §4) — SEPARATE test fns (NO Terminal ⇒ safe)
  - resolveOutputPath: OptFake (design_notes §4a) with @tmux-2html-output-dir set + session "s";
    assert --output passthrough (opts.output ⇒ exact path); assert auto-name under out_dir matching
    `<session>-<digits>-<digits>.html`; assert session-fallback ("pane") when session empty.
  - writeLastOutput: std.testing.tmpDir as bin_dir; write a path; read back `<tmp>/.last-output` ⇒
    equals the input (BARE, no prefix).
  - writeHtmlAtomic: tmpDir; write bytes; read back ⇒ equals input; statFile(target) succeeds (rename
    completed). Do NOT Dir.iterate (crashes under the runner — render.zig note).
  - readBoolOption: OptFake with @tmux-2html-open ∈ {on, off, "", unset, ON, yes, 1, junk}; assert
    true/false/default/false.
  - readFontOption: OptFake with @tmux-2html-font set ⇒ value; unset ⇒ "monospace".
  - regionPid: Linux ⇒ > 0 (guard builtin.os.tag).
  - selfBinDir: returns a non-empty slice (the test binary's dir).
  - RUN `zig build test -Doptimize=ReleaseFast` after this task — all new tests pass + no regressions.
```

### Implementation Patterns & Key Details

```zig
// === The .confirm arm skeleton (design_notes §1 — the ENTIRE body change) ===
//   .confirm => confirm_render: {
//       app.exit(state);                                 // restore FIRST (idempotent; cooked-mode warns)
//       const stderr = std.fs.File.stderr();
//       if (!ctx.sel.active()) { stderr.writeAll("…no selection…") catch {}; break :confirm_render 1; }
//       const font = readFontOption(capture.real, allocator) catch ctx.font;
//       defer allocator.free(font);
//       const do_open = opts.open or readBoolOption(capture.real, allocator, "@tmux-2html-open", true);
//       const html = renderSelectionHtml(allocator, &ctx, font) catch { stderr…; break :confirm_render 1; };
//       defer allocator.free(html);
//       const path = resolveOutputPath(allocator, opts, target, capture.real) catch { stderr…; break :confirm_render 1; };
//       defer allocator.free(path);
//       if (std.fs.path.dirname(path)) |dp| std.fs.cwd().makePath(dp) catch {};
//       writeHtmlAtomic(allocator, path, html) catch { stderr…; break :confirm_render 1; };
//       if (selfBinDir(allocator)) |bin_dir| { defer allocator.free(bin_dir); writeLastOutput(bin_dir, path) catch {}; }
//       else |_| { stderr.writeAll("…bin dir…") catch {}; }
//       if (do_open) render.spawnXdgOpen(path, allocator);
//       break :confirm_render 0;
//   },

// === renderSelectionHtml (the formatter block is renderGrid's body, VERBATIM — design_notes §2a) ===
//   fn renderSelectionHtml(allocator, ctx: *RegionCtx, font: []const u8) ![]u8 {
//       var aw = try std.Io.Writer.Allocating.initCapacity(allocator, 4096);
//       defer aw.deinit();
//       const gs = render.toGhosttySelection(ctx.sel, ctx.grid, ctx.tty_cols); // INFALLIBLE
//       var f = fmt.ScreenFormatter.init(ctx.grid, .{
//           .emit = .html, .background = ctx.colors.background, .foreground = ctx.colors.foreground,
//           .palette = &ctx.colors.palette, .font = font,
//       });
//       f.content = .{ .selection = gs }; f.extra = .styles;
//       try aw.writer.print("{f}", .{f});
//       return allocator.dupe(u8, aw.writer.buffered());   // mirrors render.renderToOwned
//   }

// === resolveOutputPath (mirrors pane's panePrepare path branch via SHIPPED capture.* — §2b) ===
//   fn resolveOutputPath(allocator, opts, target, runner) ![]u8 {
//       if (opts.output) |p| return allocator.dupe(u8, p);
//       const out_dir = try capture.resolveOutputDir(runner, allocator); defer allocator.free(out_dir);
//       const session = capture.querySessionName(runner, allocator, target) catch try allocator.alloc(u8, 0);
//       defer allocator.free(session);
//       const fname = try capture.buildOutputFilename(allocator, std.mem.trim(u8, session, " \t\n\r"),
//           std.time.timestamp(), regionPid());
//       defer allocator.free(fname);
//       return capture.buildOutputPath(allocator, out_dir, fname);
//   }

// === the sidecar (region's OWN bin dir via /proc/self/exe — §2c) ===
//   fn selfBinDir(allocator) ![]u8 {
//       var buf: [std.fs.max_path_bytes]u8 = undefined;
//       const exe = try std.fs.selfExePath(&buf);              // fs.zig:545 (Zig 0.15.2)
//       return allocator.dupe(u8, std.fs.path.dirname(exe) orelse ".");
//   }
//   fn writeLastOutput(bin_dir, output_path) !void {
//       const sc = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/.last-output", .{bin_dir});
//       defer std.heap.page_allocator.free(sc);
//       var f = try std.fs.cwd().createFile(sc, .{ .truncate = true }); defer f.close();
//       try f.writeAll(output_path);                            // BARE path (wrapper prepends "wrote ")
//   }
```

### Integration Points

```yaml
BUILD:
  - NO change. region.zig is in src/; main.zig (S1) imports it. ghostty_format is a sibling import.
    The test step uses exe.root_module (build.zig) so region.zig's tests are reachable. No build edit.

DISPATCH:
  - NO change. main.zig (S1) already dispatches `region` → `cli.region(allocator, sub_args, region.body)`.
    S2 edits region.body's INTERNALS (the .confirm arm), not its signature.

SIDE_CONTRACT (the wrapper, P2.M2.T2.S2 — shipped, READ ONLY):
  - The C-o wrapper: `rm -f $BIN/.last-output`; `display-popup … region --target #{pane_id}`; then
    `if [ -f $BIN/.last-output ]; out=$(cat …); display-message "tmux-2html: wrote $out"; fi`.
  - region's OBLIGATION: write the BARE path to `.last-output` in its OWN bin dir on CONFIRM ONLY.
    cancel/empty ⇒ no write (the rm keeps it absent ⇒ no stale message).

CANCEL_PATH (S1, UNCHANGED):
  - body()'s `.quit => 1` + `else => 1` arms (q/Esc-no-sel/Ctrl-c/EOF ⇒ exit 1, no output). S2 does
    NOT touch them. The terminal restore (defer app.exit) covers them.

TEST_ROOT:
  - NO main.zig change. region.zig is ALREADY imported by the test root (S1 added `_ = @import
    ("region.zig");`). S2's new test fns are reachable via that import.
```

## Validation Loop

> **CRITICAL**: ALL Zig build/test commands MUST use `-Doptimize=ReleaseFast`. Debug hits the
> `R_X86_64_PC64` linker bug with the bundled ghostty C++ SIMD libs (PRD §15). The #1 build gotcha.

### Level 1: Syntax & Type Check (Immediate Feedback)

```bash
# After Tasks 1–6 — compile the test target + the binary.
zig build test -Doptimize=ReleaseFast
# Expected: compiles cleanly. A type mismatch (e.g. toGhosttySelection treated as an error union,
# a missing fmt/builtin import, RegionCtx field name, the labeled-block break type) surfaces here.
# A "use of private declaration" ⇒ the ghostty_format import is missing. Fix BEFORE proceeding.
zig build -Doptimize=ReleaseFast
# Expected: builds zig-out/bin/tmux-2html with no errors (region.zig is on the exe path).
```

### Level 2: Unit Tests (the helpers — the unit-testable surface)

```bash
# Full suite (ReleaseFast MANDATORY). S2's helper tests are SEPARATE fns (NO Terminal ⇒ safe).
zig build test -Doptimize=ReleaseFast
# Expected: ALL tests pass (existing + resolveOutputPath/writeLastOutput/writeHtmlAtomic/
#   readBoolOption/readFontOption/regionPid/selfBinDir). A failure points at exactly one helper.

# Focus debugging on region.zig's new tests:
zig build test -Doptimize=ReleaseFast --test-filter "resolveOutputPath"
zig build test -Doptimize=ReleaseFast --test-filter "writeLastOutput"
zig build test -Doptimize=ReleaseFast --test-filter "writeHtmlAtomic"
# (Zig's test runner supports --test-filter <substring>.)
```

### Level 3: Integration Testing (the confirm flow — needs a real pty + tmux pane; MANUAL)

```bash
# The .confirm arm + renderSelectionHtml need a real pty (the display-popup) + a tmux pane with
# scrollback. S2's automated gates are Level 1 + Level 2 + the --help/no-tty checks (S1). The full
# confirm flow is MANUAL:

# (a) Automated (S1, unaffected): --help works; no tty ⇒ exit 1.
./zig-out/bin/tmux-2html region --help            # prints region help, exit 0.
echo "" | ./zig-out/bin/tmux-2html region --target %0 ; echo "exit=$?"  # exit=1 (no tty).

# (b) MANUAL (the PRD path): inside a tmux session with a pane that has scrollback + content:
tmux display-popup -E -w 100% -h 100% "zig-out/bin/tmux-2html region --target $TMUX_PANE"
# Verify (S1): full colored scrollback; cursor at the bottom. Then S2's flow:
#   - v (begin selection) → move to extend → Enter.
#     EXPECT: a file appears under ${XDG_DATA_HOME:-~/.local/share}/tmux-2html/ named
#     <session>-<ts>-<pid>.html containing EXACTLY the selected cells (linewise = full rows;
#     block = the rectangle) in full color. The popup closes (-E). exit 0.
#   - The .last-output sidecar holds the BARE path:
ls -la "$(dirname "$(readlink -f zig-out/bin/tmux-2html)")/.last-output"
cat "$(dirname "$(readlink -f zig-out/bin/tmux-2html)")/.last-output"   # the bare output path
#   - (Via the real C-o binding:) the status line flashes `tmux-2html: wrote <path>`.
#   - Press Enter with NO selection begun (no v): EXPECT stderr "no selection", NO file, exit 1.
#   - q / Esc(no-sel) / Ctrl-c: popup closes, exit 1, no file (S1).
#   - Verify terminal is restored after each (cooked termios, primary screen, visible cursor).

# (c) MANUAL (--output + --open overrides via direct invocation is hard without a pty; test the
#     filename/sidecar logic by setting @tmux-2html-output-dir + @tmux-2html-font + @tmux-2html-open):
tmux set -g @tmux-2html-output-dir /tmp/t2h-out
tmux set -g @tmux-2html-font "Fira Code"
tmux set -g @tmux-2html-open on
tmux display-popup -E -w 100% -h 100% "zig-out/bin/tmux-2html region --target $TMUX_PANE"
# After select + Enter: /tmp/t2h-out/<session>-<ts>-<pid>.html exists; grep "font-family: Fira Code"
# in it; xdg-open spawned (a browser window opens). Reset: tmux set -gu @tmux-2html-output-dir …
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Wide-glyph + block selection (MANUAL, in the popup): select a region spanning CJK/emoji (真, 😀)
# in BOTH linewise and block modes; confirm; open the HTML; verify each wide glyph renders WHOLE
# (never split) — the formatter rounds start back from spacer_tail + skips spacers (PRD §13, proven
# in render.zig's toGhosttySelection wide-cell test; S2 delegates, does nothing special).

# Sidecar lifecycle (MANUAL): run C-o → select → Enter (confirm) → confirm .last-output has the path;
# then C-o → q (cancel) → confirm .last-output is ABSENT (the wrapper's pre-popup rm -f cleared it +
# region wrote nothing on cancel). This proves cancel is silent (no stale message).

# Terminal-restore safety (MANUAL): inside the popup, select a region then Ctrl-C (or kill -TERM the
# region process mid-selection); verify the terminal is restored (app.exit via S1's defer + the signal
# handler). S2's early app.exit in the arm is an ADDITIONAL restore on the confirm path (idempotent).
```

## Final Validation Checklist

### Technical Validation

- [ ] `zig build test -Doptimize=ReleaseFast` passes (zero failures; existing + S2's helper tests).
- [ ] `zig build -Doptimize=ReleaseFast` builds the binary with no errors.
- [ ] No new compiler warnings from region.zig.
- [ ] `ghostty_format`/`builtin` imports present in region.zig (if S1 didn't add them).

### Feature Validation

- [ ] `Enter`/`y` + active selection ⇒ HTML of EXACTLY the selection written to `--output` or
      `<output-dir>/<session>-<ts>-<pid>.html`; `.last-output` holds the BARE path; exit 0 (manual).
- [ ] `Enter`/`y` + NO selection ⇒ stderr warn, NO file, NO sidecar, exit 1.
- [ ] `q`/`Esc`(no-sel)/`Ctrl-c`/EOF ⇒ exit 1, no output (S1's `.quit`/`.else` — unchanged).
- [ ] `@tmux-2html-font` honored in the HTML; `@tmux-2html-open`/`--open` ⇒ `xdg-open`;
      `--output` or auto-name in `@tmux-2html-output-dir`/XDG/HOME.
- [ ] Terminal restored on EVERY exit (S1's defer + S2's early `app.exit` in the confirm arm).
- [ ] Wide glyphs render whole across the selection boundary (PRD §13 — delegated to the formatter).

### Code Quality Validation

- [ ] REUSES `render.toGhosttySelection` (P3.M2.T2.S2) + the ScreenFormatter block (verbatim from
      renderGrid) + `capture.*` filename helpers + `render.spawnXdgOpen` + S1's ctx — nothing
      selection/render/filename-related is re-implemented (writeHtmlAtomic/regionPid are cited dupes
      of private fns, intentional to avoid editing render.zig/main.zig).
- [ ] The `.confirm` arm is the ONLY body change; `.quit`/`.else` arms UNCHANGED.
- [ ] The confirm arm + renderSelectionHtml are NOT unit-tested (Terminal + tty + tmux I/O) — they
      are compile-verified + manually smoke-tested; the PURE/fs/Runner-seamed helpers ARE unit-tested
      as separate fns. The cross-test GOTCHA is respected (no Terminal-building test fn).
- [ ] Owned memory fully freed (font/html/path/bin_dir + the Allocating writer via defer; the
      sidecar's join string); no leaks under std.testing.allocator in the helper tests.
- [ ] `app.exit(state)` called FIRST in the arm (cooked-mode warns); idempotent with S1's defer.

### Documentation & Deployment

- [ ] The `.confirm` arm has a comment explaining: app.exit-first (cooked warns), the empty guard,
      option-reading (binding passes only --target), toGhosttySelection+ScreenFormatter (no rebuild),
      the sidecar (bare path, own bin dir, best-effort), and the S1↔S2 seam.
- [ ] Each helper has a doc comment (purpose + why it's unit-testable / not).
- [ ] The `.last-output` sidecar content (BARE path) + location (own bin dir) are documented to match
      the wrapper contract (P2.M2.T2.S2).

---

## Anti-Patterns to Avoid

- ❌ Don't `try` `render.toGhosttySelection` — it is INFALLIBLE (returns `Selection`, not an error
  union; it CLAMPS). Its pins are tied to `ctx.grid` ⇒ format against `ctx.grid` (ScreenFormatter),
  NOT a rebuilt renderGrid Terminal. (See design_notes §3.)
- ❌ Don't skip `app.exit(state)` at the top of the `.confirm` arm — the empty-selection warn (stderr)
  + xdg-open must happen in COOKED mode. (Idempotent; S1's defer is a later no-op.)
- ❌ Don't gate the confirm on `sel.active()` in S1's HANDLER — the empty guard lives in the `.confirm`
  ARM (S2). The handler returns `.confirm` on Enter/y unconditionally (S1's design).
- ❌ Don't edit render.zig (P3.M2.T2.S2 owns it in parallel) — consume `toGhosttySelection`/
  `clampExtent`/`spawnXdgOpen` as-is. writeHtmlAtomic reimplements the atomic idiom (writeFileAtomic
  is private) rather than exposing it.
- ❌ Don't edit main.zig (S1 owns the dispatch wiring) — regionPid reimplements the 3-line currentPid.
- ❌ Don't use `render.renderToFileAtomic` for the selection — it renders the WHOLE grid (sel:null).
  renderSelectionHtml formats ctx.grid with the selection directly.
- ❌ Don't print the summary to stdout — the popup closes via `-E`; the path reaches the user ONLY via
  the `.last-output` sidecar → wrapper → display-message (PRD §7.5).
- ❌ Don't write the sidecar with a "wrote " prefix or to a hardcoded path — BARE path, region's OWN
  bin dir (selfExePath), on CONFIRM ONLY (cancel/empty ⇒ no write).
- ❌ Don't fail the render on a sidecar write error — the HTML is already written; log + continue to 0.
- ❌ Don't rely on `$TMUX_2HTML_BIN` — exported loader vars don't reach the popup child. Use selfExePath.
- ❌ Don't ignore `@tmux-2html-font`/`@tmux-2html-open` (the binding passes only `--target`) — read
  them via `capture.queryOption` (docs/CONFIGURATION.md "How options are read").
- ❌ Don't build a Terminal in a region.zig unit test (cross-test GOTCHA) — test only the
  PURE/fs/Runner-seamed helpers; renderSelectionHtml + the arm are compile + manual.
- ❌ Don't change the `.quit`/`.else` arms (cancel ⇒ exit 1 is S1's, correct per PRD §7.5).
- ❌ Don't skip ReleaseFast — `zig build test` WITHOUT `-Doptimize=ReleaseFast` fails to LINK.
- ❌ Don't add `--font`/`--open`/`--output-dir` to the binding or parseRegion — region reads them
  itself; the binding intentionally passes only `--target` (single source of truth).

---

## Confidence Score

**8/10** — Every upstream function S2 consumes is SHIPPED + tested: `render.toGhosttySelection`
(P3.M2.T2.S2, with its own lw/block/clamp/wide-cell formatter tests proving the selection→HTML
fidelity), the SHIPPED `capture.*` filename helpers (resolveOutputDir/querySessionName/
buildOutputFilename/buildOutputPath — exercised by pane's tests), `render.spawnXdgOpen`, S1's
RegionCtx + app.enter/exit, and the vendored ScreenFormatter (the renderGrid block S2 copies
verbatim). S2 is pure GLUE: the `.confirm` arm orchestrates tested pieces + adds small helpers
(option-read, sidecar, atomic-write, pid) that are each unit-testable (NO Terminal ⇒ cross-test-safe).
The complete verbatim Zig for the arm + every helper is authored in `research/design_notes.md`. The
deliverable is ONE edited file (region.zig) — the arm + ~6 helpers + tests — and touches nothing else.

Residual risks: (1) the `.last-output` sidecar location (region's OWN bin dir via selfExePath) must
match the wrapper's `$TMUX_2HTML_BIN/.last-output` read — VERIFIED: the wrapper expands
`$TMUX_2HTML_BIN` to the absolute bin path (where the binary lives), and selfExePath returns that
same binary's dir, so they coincide (Level 3 manual check confirms). (2) The confirm flow (arm +
renderSelectionHtml) needs a real pty + tmux pane ⇒ manual smoke (Level 3/4); the automated surface
is the helper tests + compile. (3) The app.exit-first-in-arm ordering relies on S1's body naming the
app.State local `state` + app.exit being idempotent — both confirmed in S1's PRP + app.zig. (4) The
option-reading (font/open) is the one behavioral choice that diverges from pane's ACTUAL shipped
behavior (pane uses opts.font/opts.open) — S2 follows the DOCS + binding contract (region reads them
itself), which is the documented intent; if pane is later fixed to match, region already complies.
The PARALLEL S1 (region.zig's body/RegionCtx) is the dependency — S2 treats S1's `.confirm => 1` stub
+ the in-scope locals as a contract (design_notes §0) and fills ONLY that arm.
