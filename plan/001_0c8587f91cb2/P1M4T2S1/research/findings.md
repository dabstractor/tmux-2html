# P1.M4.T2.S1 research — Golden harness + testdata (color/attr/OSC8)

> Every claim below was VERIFIED empirically in an isolated copy of the project
> (`/tmp/gotcha_exp`, Zig 0.15.2, ghostty v1.3.1, `-Doptimize=ReleaseFast`). The
> experiments were torn down after; the REAL source tree was NOT modified. Line numbers
> reference the live `src/` files (post P1.M4.T1.S1 landing).

## §0 Headline: the ghostty-vt cross-test "GOTCHA" does NOT reproduce

The codebase (`src/render.zig` comment block above the test, P1.M4.T1.S1 PRP/findings §7)
documents a "verified" rule: *"Terminal.init corrupts process-global state such that a
Terminal.init in a SEPARATE test function crashes (core dump). Sequential renderGrid calls
in the SAME test scope are fine."* That finding drove the S1 implementer to MERGE all
selection assertions into the one `test "renderGrid: …"` function.

**This no longer holds in the current toolchain.** Experiment (isolated copy):

1. Added a SECOND terminal-touching test `test "GOTCHA-EXP: second terminal test"`
   (calls `renderToOwned` → `renderGrid` → `Terminal.init`). Build + run: `EXIT 0`.
2. Added THREE MORE separate terminal tests (4 total new ones). Ran the suite 3×: `EXIT 0`
   every time; no core dump, no SIGSEGV, no abort.
3. Ran the compiled test binary DIRECTLY:
   ```
   47/69 render.test.GOTCHA-EXP: second terminal test (separate fn)...OK
   48/69 render.test.GOTCHA-EXP 2: third terminal test...OK
   49/69 render.test.GOTCHA-EXP 3: fourth terminal test...OK
   50/69 render.test.GOTCHA-EXP 4: fifth terminal test...OK
   All 69 tests passed.
   ```
   → four SEPARATE terminal-touching test functions all ran and passed.

**Conclusion for the golden harness:** it MAY live in its own `test` function (and even its
own file). It is NOT forced into the `renderGrid` test. (Hypothesis for why the old finding
diverges: it was likely Debug-mode-only, and the build-env caveat forces ReleaseFast, which
is also what PRD §15 mandates. Either way, ReleaseFast — the only mode that links here — is
clean.) The golden test still uses `inline for` over fixtures within ONE test function
(term2html's idiom), which is the MOST conservative structure (single scope) and would be
safe even if the GOTCHA were real. Belt-and-suspenders.

## §1 `@embedFile` cannot escape the package root — use an embed module

`@embedFile` from `src/render.zig` with `"../testdata/..."` FAILS to compile:
```
error: embed of file outside package path: '../testdata/exp.ansi'
```
The exe module root is `src/` (root_source_file = `src/main.zig`), so `@embedFile` is
confined to `src/` and below. Keeping `testdata/` at the repo root (the established layout —
`.gitkeep` is there, `build.zig.zon .paths` lists `"testdata"`) requires a separate module
whose root lives INSIDE `testdata/`.

**Verified solution (Option B):** an embed-manifest module.
- `testdata/embed.zig`:
  ```zig
  pub const Fixture = struct { name: []const u8, ansi: []const u8, html: []const u8 };
  pub const fixtures = [_]Fixture{
      .{ .name = "color16", .ansi = @embedFile("color16.ansi"), .html = @embedFile("color16.html") },
      // … one entry per fixture …
  };
  ```
  (siblings of `embed.zig` ARE inside the `testdata` package, so `@embedFile` resolves.)
- `build.zig` (insert before `b.installArtifact(exe);`):
  ```zig
  const testdata_mod = b.createModule(.{ .root_source_file = b.path("testdata/embed.zig") });
  exe.root_module.addImport("testdata", testdata_mod);
  ```
  The test step uses `exe.root_module` (`b.addTest(.{ .root_module = exe.root_module })`),
  so the test inherits the `"testdata"` import for free.
- Verified: prod build `EXIT 0` (binary 7.5 MB, **unaffected** — an unreferenced module is
  lazily never compiled into the prod binary; only the test root pulls it in).

`testdata/.gitkeep` stays; the manifest + fixture pairs live alongside it.

## §2 Byte-equality: binary output == renderGrid output (the golden guarantee)

The whole point of a golden test is `expectEqualStrings(generated_html, renderGrid_output)`.
VERIFIED that the binary's stdout path produces the SAME bytes the test's `renderGrid` call
produces, so goldens can be blessed by piping the binary:

- Generated `testdata/exp.html` via `tmux-2html render --cols 120 --rows 150 --palette default`
  on a sample `.ansi`. Output:
  `<pre class="term2html-output" style="max-width: 120ch; background-color: #292c33;color: #c5c8c6;font-family: monospace;">hello<span style="color: #cc6666;">red</span></pre>`
- Embedded it and asserted `expectEqualStrings(td.exp_html, renderGrid(ansi,{120,150}))`:
  **PASSED** (`51/70 golden_test.test.golden: …byte-equal to binary-generated exp.html...OK`).

The exact byte format the goldens pin:
- Header: `<pre class="term2html-output" style="max-width: {cols}ch; background-color: #{bg};color: #{fg};font-family: {font};">`
  (note: NO space between `;` and the next property; `#rrggbb` lowercased hex).
- defaultColors(): `bg=#292c33` (41,44,51), `fg=#c5c8c6` (palette[7]=197,200,198),
  `palette[1]=#cc6666` (red), `palette[2]=#b5bd68`, etc. — all from `ghostty_vt.color.default`.
- Styled cell: `<span style="color: #rrggbb;…">text</span>` (space after colon). Plain text:
  no `<span>`. Rows separated by literal `\n` (whitespace:pre). Ends with `</pre>`.

**Bless workflow:** for each `.ansi`, run
`zig-out/bin/tmux-2html render --cols 120 --rows 150 --palette default < testdata/X.ansi > testdata/X.html`
then commit both. `--rows 150` MUST be explicit (the subcommand defaults rows to lineCount;
the test pins rows=150 per term2html). font: omit `--font` so the formatter defaults to
`"monospace"` (== the test's `"monospace"` arg → identical bytes; `opts.font orelse
"monospace"` inside the formatter).

## §3 Why term2html's committed `.html` fixtures CANNOT be vendored verbatim

- Our `src/ghostty_format.zig` header (line 15): *"This is copied from the Ghostty codebase
  and has been modified to output more idiomatic HTML as well as provide more control over
  the output."* → our formatter DIVERGES from term2html's. term2html's committed `.html`
  goldens are from its (un-modified) formatter and will NOT byte-match ours.
- Web search confirmed `https://github.com/aarol/term2html` exists, but raw `.ansi`/`.html`
  bytes are not fetchable with the available tools (the web tool returns search summaries,
  not raw content), and the bytes would be for a divergent formatter regardless.

**Decision:** adopt term2html's test PATTERN (`inline for` names, fixed `WindowSize{cols=120,
rows=150}`, `defaultColors`, `expectEqualStrings` — per architecture/render_pipeline.md §5)
but ALWAYS regenerate the `.html` with our own binary. The `.ansi` inputs are the "baseline"
(real-world-style captures OR crafted representative ANSI); the `.html` is our renderer's
authoritative output. This is byte-exact and self-contained. Real captures (hyperfine/
fastfetch if installed) are a welcome enhancement for the 3 "baseline" fixtures, but crafted
ANSI is the guaranteed path and is what the PRP specifies.

## §4 Formatter attribute→CSS mapping (so fixtures are meaningful)

Grep of `src/ghostty_format.zig` (formatStyle):
- bold  → `font-weight: bold;`
- italic → `font-style: italic;`
- underline / strikethrough / blink → `text-decoration-line: …;` (underline, line-through, blink)
- underline style → `text-decoration-style: solid|double|wavy|dotted|dashed;`
- underline color → `text-decoration-color: #rrggbb;`
- (dim SGR 2, reverse SGR 7: NOT found in the CSS emit — the formatter does not render these
  as distinct CSS. reverse MAY swap fg/bg at the cell level. The golden captures whatever
  actually happens, so include them in the `attributes` fixture; do NOT assert a specific
  CSS string for them — the byte-equal golden is the assertion.)

Confirmed-supported attributes for the `attributes` fixture: **bold (1), italic (3),
underline (4), blink (5), strikrethrough (9)**, plus combinations (`1;4`, `3;9`). The
existing `renderGrid` test already pins `font-weight: bold` and `color: #ff0000`.

## §5 OSC 8 hyperlink format (the `osc8` fixture + formatter emit)

- OSC 8 byte form (xterm hyperlink spec, STANDARD): `\x1b]8;;<URI>\x1b\\<text>\x1b]8;;\x1b\\`
  (ST = `ESC \` = `\x1b\\`; BEL `\x07` is also a valid ST and ghostty's parser accepts both
  — `palette.zig` tests exercise both terminators).
- Formatter emit (VERIFIED in `ghostty_format.zig` `formatHyperlinkOpen`/`Close`, lines
  1420/1440): open `<a style="color: inherit;" href="<URI>">` … text … close `</a>`.
  Hyperlink emit requires `f.extra = .styles` (which `renderGrid` already sets) — the
  `Extra.styles` / `.hyperlink` flag is on by default in the `.styles` aggregate.

## §6 The fixed size: cols=120, rows=150

term2html uses `WindowSize{ .cols = 120, .rows = 150 }` (architecture/render_pipeline.md §5,
the contract's LOGIC clause). Pin this in BOTH the test and the bless command. rows=150 with
short input is harmless — the formatter emits only WRITTEN cells (blank rows emit nothing;
verified: `renderToOwned` uses rows=5 for 1-line input and the body is just the content).
cols=120 affects `max-width: 120ch` and line wrapping — fixtures are authored to fit ≤120
cols so wrapping is deterministic. Even if a fixture wraps, the `.html` is blessed from the
SAME 120×150 render, so the pair stays consistent.

## §7 Current state (builds on the now-landed P1.M4.T1.S1)

- `src/render.zig`: `renderGrid(alloc, ansi, size: Size, colors, sel: ?cli.SelectionCoords,
  font: ?[]const u8, out: *std.Io.Writer)` (signature now takes COORDS, not a Selection;
  S1 builds the native Selection internally). `pub fn buildSelection`, `fn selectionBodyEmpty`,
  `fn writeFileAtomic`, `fn renderToOwned`, `fn renderSelOwned` all present. The single
  `test "renderGrid: red foreground emits styled span"` (line 519) now ALSO holds S1's
  selection assertions. `src/main.zig` test block imports `render.zig` + `palette.zig`.
- `testdata/` exists with only `.gitkeep` (P1.M4.T2 owns the fixtures).
- This task (P1.M4.T2.S1) owns: `testdata/*.{ansi,html}` + `testdata/embed.zig`,
  a `build.zig` one-block addition, a NEW `src/golden_test.zig` (separate test fn, safe per
  §0), and the one-line `_ = @import("golden_test.zig");` in main.zig's test block.
- P1.M4.T2.S2 (separate item) owns selection sub-rectangle goldens + palette parse/serialize
  goldens — do NOT add those here.

## §8 Confirmations + one correction (re-verified in-tree, Zig 0.15.2 + ghostty v1.3.1)

Every structural claim in §0–§7 was re-confirmed by building the in-tree binary
(`zig build -Doptimize=ReleaseFast`, EXIT 0) and rendering representative ANSI through
`./zig-out/bin/tmux-2html render --cols 120`. The debug linker bug (PRD §15) reproduces
EXACTLY: plain `zig build test` fails with `R_X86_64_PC64`; `zig build test
-Doptimize=ReleaseFast` passes (EXIT 0, existing render/palette/cli suite green). So the
validation gate is `zig build test -Doptimize=ReleaseFast` (ReleaseFast is mandatory).

**§4 CORRECTION — reverse & dim DO emit CSS.** §4's grep claimed "dim SGR 2, reverse SGR 7:
NOT found in the CSS emit." That is wrong; the empirical render shows both emit distinct,
deterministic CSS. Full attribute→CSS map (all byte-captured from the binary):

| SGR | ANSI | CSS emitted by ghostty_format |
|-----|------|-------------------------------|
| 1   | bold            | `font-weight: bold` |
| 3   | italic          | `font-style: italic` |
| 4   | underline       | `text-decoration-line: underline;text-decoration-style: solid` |
| 9   | strikethrough   | `text-decoration-line: line-through` |
| 7   | reverse         | `filter: invert(100%)` |
| 2   | dim/faint       | `opacity: 0.5` |
| combo e.g. 1;3;4 | `text-decoration-line: underline;text-decoration-style: solid;font-weight: bold;font-style: italic` |

So the `attributes` fixture (bold/italic/underline/strike/reverse/dim + combos) has
fully deterministic expected CSS — every entry is assertable, not just byte-pinned.

**Header byte format (pinned by every golden):**
`<pre class="term2html-output" style="max-width: 120ch; background-color: #292c33;color: #c5c8c6;font-family: monospace;">…</pre>`
(defaultColors: bg=#292c33 (41,44,51), fg=#c5c8c6 = palette[7] (197,200,198), font=monospace.)

**ghostty default palette values (for fixture authoring / sanity):**
- normal fg 30–37: #1d1f21 #cc6666 #b5bd68 #f0c674 #81a2be #b294bb #8abeb7 #c5c8c6
- bright fg 90–97: #666666 #d54e53 #b9ca4a #e7c547 #7aa6da #c397d8 #70c0b1 #eaeaea
- bg uses the same RGBs (40–47 / 100–107).
- 256 cube/grayscale samples: 5;1=#cc6666 5;22=#005f00 5;82=#5fff00 5;196=#ff0000 5;214=#ffaf00
  5;232=#080808 5;245=#8a8a8a 5;255=#eeeeee. truecolor 38;2;255;0;0 → #ff0000 (exact).

**OSC 8 nesting (captured):** a link inside a styled span renders as
`<span style="color: #cc6666;">before <a style="color: inherit;" href="URI">link</a> after</span>`.
GOTCHA when authoring fixtures: OSC 8 MUST be terminated by BEL (0x07) or ST (ESC \); a
literal `^G` in a printf is two ASCII chars and produces a malformed (eaten) sequence.

**main.ziz insertion point:** the top-level `test { }` block (lines 253–260) pulls in
palette.zig + render.zig. Add `_ = @import("golden_test.zig");` immediately after the
existing `_ = @import("render.zig");` (line 259). golden_test.zig is a SEPARATE file with
its OWN `test` function (safe per §0 — the cross-test GOTCHA does not reproduce in
ReleaseFast, which is the only mode that links here).

**Bless workflow re-confirmed byte-equal:** `--rows 150` vs omitting `--rows` (binary
defaults rows to input line count) produce IDENTICAL bytes — the formatter trims trailing
blank rows, so the row count only matters if content exceeds it (none of our fixtures do).
`--cols`, `--rows`, `--palette` flags all exist (cli.zig:160–163). Bless with
`--palette default` to force deterministic defaultColors() (avoids cached/live tty probing).

**Vendored inputs saved:** the 3 term2html `.ansi` inputs are saved as
`research/{hyperfine,fastfetch,hyperlink}.ansi.ref` (fetched from
`https://raw.githubusercontent.com/aarol/term2html/main/testdata/<name>.ansi`, MIT — already
covered by licenses/TERM2HTML.txt). Their `.html` are NOT vendored (§3: divergent formatter).
fastfetch.ansi is a 256-color ASCII-art logo + system info; hyperfine.ansi is benchmark
output with bold + 16-colors + UTF-8 special chars; hyperlink.ansi is a single OSC 8 link.
