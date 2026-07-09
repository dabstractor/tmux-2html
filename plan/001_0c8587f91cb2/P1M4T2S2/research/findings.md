# P1.M4.T2.S2 — Research findings (palette round-trip + selection golden tests)

Every claim below was verified in-tree against the current repo state (which has P1.M4.T2.S1
fully landed). Citations are to specific lines/files.

## §0 — Baseline: S1 harness is fully landed and GREEN

`plan_status` labels S1 "Implementing", but the working tree already contains its complete
output (timestamps 21:50-21:52):

- `testdata/embed.zig` — `pub const Fixture` + `pub const fixtures = [_]Fixture{ … 8 pairs … }`.
- `testdata/{hyperfine,fastfetch,hyperlink,colors16,colors256,truecolor,attributes,osc8}.{ansi,html}`.
- `src/golden_test.zig` — one `test "golden: testdata/*.ansi renders byte-equal to testdata/*.html"`
  that `inline for (td.fixtures)` → `renderGrid(…, .{120,150}, defaultColors(), null, null, &aw.writer)`
  → `expectEqualStrings`.
- `build.zig:42-46` — `const testdata_mod = b.createModule(.{ .root_source_file = b.path("testdata/embed.zig") }); exe.root_module.addImport("testdata", testdata_mod);`
- `src/main.zig:260-262` — `_ = @import("golden_test.zig");` inside the top-level `test {}`.

**Gate verified:** `zig build test -Doptimize=ReleaseFast` → **EXIT 0** (only the expected
`palette: only 1/256 colors captured` warnings from the `resolve never panics` smoke test).

**Implication for S2:** the `testdata` module is already wired and reachable from the test
root. S2 only ADDS to `embed.zig` (a `sel_fixtures` array) and to `golden_test.zig` (a second
test fn). No `build.zig` / `main.zig` / `build.zig.zon` changes are needed.

## §1 — Multiple renderGrid test functions coexist safely in ReleaseFast

The render.zig "GOTCHA" comment ("ALL renderGrid assertions live in ONE test because
ghostty-vt's Terminal corrupts process-global state across separate test functions") is a
DEBUG-only phenomenon. Empirically, the current suite has TWO separate test fns that each
call `renderGrid` (`render.zig`'s mega-test + `golden_test.zig`'s golden test) and both pass
under ReleaseFast. The S1 PRP's "separate file/own test fn is safe in ReleaseFast" claim is
therefore confirmed by the green baseline.

**Implication for S2:** adding a THIRD `renderGrid`-calling test fn (the selection golden) to
`golden_test.zig` is safe. Fallback if it ever DID crash: append the selection loop to the
single existing golden test fn (same scope). But the separate-fn path is verified working.

## §2 — Anonymous struct literal coerces to `?cli.SelectionCoords` directly

`renderGrid`'s `sel` param is `?cli.SelectionCoords`. `render.zig`'s existing out-of-range
test passes an anonymous struct literal DIRECTLY as that param:

```zig
// render.zig (verified present in the current file)
try std.testing.expectError(error.OutOfRange, renderGrid(std.testing.allocator, "AB",
    .{ .cols = 5, .rows = 2 }, palette.defaultColors(),
    .{ .x1 = 9, .y1 = 0, .x2 = 9, .y2 = 0 },   // <-- anonymous literal -> ?cli.SelectionCoords
    "monospace", &aw_oor.writer));
```

So a selection golden test can build the selection from embedded fields with
`.{ .x1 = fx.x1, .y1 = fx.y1, .x2 = fx.x2, .y2 = fx.y2, .rect = fx.rect }` and pass it straight
to `renderGrid` — no `cli.` qualifier or explicit `SelectionCoords{}` needed. (`rect` has a
default of `false` in `cli.SelectionCoords`, but the embed carries it explicitly so the block
fixture is unambiguous.)

## §3 — Bless workflow for `--selection` is byte-stable and == renderGrid

Verified empirically (in /tmp, not polluting `testdata/`):

```
# linewise: 5 colored rows R0..R4, select rows 1..3
$BIN render --cols 20 --rows 5 --palette default --selection 0,1,19,3 < selexp_linewise.ansi
<pre class="term2html-output" style="max-width: 20ch; background-color: #292c33;color: #c5c8c6;font-family: monospace;"><span style="color: #b5bd68;">R1</span>
<span style="color: #f0c674;">R2</span>
<span style="color: #81a2be;">R3</span></pre>
# R0 and R4 EXCLUDED (grep -c 'R0' == 0).

# block: distinct rows, select cols 2..5 rows 0..2 (rect)
$BIN render --cols 10 --rows 3 --palette default --selection 2,0,5,2,1 < selexp_block2.ansi
<pre class="term2html-output" style="max-width: 10ch; background-color: #292c33;color: #c5c8c6;font-family: monospace;">2345
CDEF
cdef</pre>
```

- **Linewise** (`rect` omitted): full rows y1..y2 inclusive (x1..x2 may span the full width).
- **Block** (`rect=1`): the rectangle x1..x2 × y1..y2; each selected row emits ONLY the column
  slice (index x1..x2). With distinct row content the slice is unambiguous (2345 / CDEF / cdef).
- **Byte stability:** re-rendering the same input produces byte-identical output (`diff` empty).
- **font null == "monospace":** bless omits `--font` ⇒ binary uses `opts.font = "monospace"`
  (cli.zig default). The header emits `font-family: monospace`. The test passes `font: null` ⇒
  formatter does `opts.font orelse "monospace"` ⇒ identical header bytes. (Same equivalence S1
  relies on; confirmed in both blessed outputs above.)

Byte-equality to `renderGrid` follows from the same argument S1 used (§2 of S1 findings): the
binary's `--selection` branch calls exactly
`renderGrid(alloc, ansi, size, colors, coords, opts.font, &aw.writer)` with `colors = resolve(.default)`
= `defaultColors()`, identical args to the test (`std.testing.allocator` vs gpa is output-
irrelevant; `"monospace"` vs `null` is byte-identical per above).

## §4 — Palette round-trip: what already exists vs. what S2 adds

`palette.zig` ALREADY has (landed by P1.M2.T1.S2):
- `test "serialize: full format (header + fg + bg + 0..255)"` — format check.
- `test "parse + serialize round-trip is exact"` — PURE round-trip (defaultColors).
- `test "writeCacheDir + loadCacheDir disk round-trip (std.testing.tmpDir)"` — disk round-trip
  with `defaultColors()` ONLY.

**S2's NEW contribution (contract (a)):** a disk round-trip with a NON-DEFAULT Colors (mutated
fg/bg/palette[0]/[100]/[255]) proving ARBITRARY values survive serialize→write→read→parse, not
just the bundled defaults. This is strictly stronger coverage than the existing default-only test.

**Why the PUBLIC `writeCache`/`loadCache` are NOT directly unit-tested:** they resolve the cache
path via `cachePath()` → `cacheBase()` → `std.posix.getenv("XDG_CACHE_HOME")` / `getenv("HOME")`.
Zig std has NO `setenv` (palette.zig GOTCHA 5), so a test cannot redirect these to a tmpDir.
Testing the public pair would either (a) error in a stripped CI env (no $HOME), or (b) write the
REAL `~/.cache/tmux-2html/palette` — a forbidden test side-effect. `writeCache`/`loadCache` are
4-line wrappers (`cachePath` + `openDirAbsolute` + delegate to `writeCacheDir`/`loadCacheDir`),
so the dir-scoped round-trip IS the canonical test of the round-trip. S2's PRP documents this so
the implementer doesn't attempt the public pair.

`palette.zig` tests use `ghostty_vt.Parser` + `color.RGB` but NEVER `Terminal.init`, so they are
NOT affected by the cross-test GOTCHA (§1) — a new palette test fn is unconditionally safe.

## §5 — embed structure: extend, don't duplicate

S1's `embed.zig` has `pub const Fixture = struct { name, ansi, html }` + `pub const fixtures`.
S2 adds a SEPARATE struct + array (selection fixtures need per-fixture geometry + coords):

```zig
pub const SelFixture = struct {
    name: []const u8, ansi: []const u8, html: []const u8,
    cols: u16, rows: u16, x1: u32, y1: u32, x2: u32, y2: u32, rect: bool,
};
pub const sel_fixtures = [_]SelFixture{ /* sel_linewise, sel_block */ };
```

This is additive — S1's `fixtures` array is untouched. The selection golden test iterates
`td.sel_fixtures` and passes the embedded coords to `renderGrid`.

## §6 — Recommended fixtures (compact, deterministic, geometry-clear)

| fixture | ansi content | cols×rows | selection | rect | what it pins |
|---|---|---|---|---|---|
| `sel_linewise` | colored rows R0..R4 (SGR 31..35) | 20×5 | `0,1,19,3` | false | full-row selection preserves per-row styling; R0/R4 excluded |
| `sel_block` | distinct rows `0123456789` / `ABCDEFGHIJ` / `abcdefghij` | 10×3 | `2,0,5,2` | true | block sub-rectangle: column slice (2345/CDEF/cdef) across all selected rows |

Both render to a compact `<pre>` with `max-width: {cols}ch` (header derived from cols), so the
golden `.html` files are short and the selection geometry is visually obvious in a diff.
