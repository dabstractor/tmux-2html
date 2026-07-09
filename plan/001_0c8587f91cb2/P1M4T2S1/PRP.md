name: "P1.M4.T2.S1 — Golden harness + testdata (color/attr/OSC8 cases)"
description: |

---

## Goal

**Feature Goal**: A golden-test harness that renders every `testdata/*.ansi` fixture through
`renderGrid` at a fixed `120×150` size with `defaultColors()` and asserts **byte-equal**
equality against a committed `testdata/*.html`, plus a fixture set covering 16-color,
256-color, truecolor, all SGR attributes, and OSC 8 hyperlinks.

**Deliverable**:
- `testdata/<name>.{ansi,html}` fixture pairs (8 total: 3 vendored inputs + 5 authored).
- `testdata/embed.zig` — a compile-time embed-manifest module exposing `fixtures`.
- A one-block `build.zig` addition wiring a `testdata` module import.
- `src/golden_test.zig` — a new test file with one `test` function that `inline for`s the
  fixtures, calls `renderGrid`, and `expectEqualStrings` against the embedded `.html`.
- A one-line `_ = @import("golden_test.zig");` in `src/main.zig`'s top-level `test {}` block.

**Success Definition**: `zig build test -Doptimize=ReleaseFast` passes, the golden test
appears in the test output, and `testdata/` covers 16/256/truecolor/attributes/links
(OSC 8). The same command with `-Doptimize=Debug` is EXPECTED to fail (known Zig
`R_X86_64_PC64` linker bug, PRD §15) — ReleaseFast is the mandatory gate.

## Why

- **Regression protection.** `renderGrid` + the vendored `ghostty_format.zig` are the heart of
  the product (PRD §8). A golden suite pins their exact HTML output so any future change — a
  ghostty bump, a formatter tweak, a palette-resolution edit — that silently alters output is
  caught immediately rather than shipping subtly-wrong HTML.
- **Mirrors the upstream we absorbed.** term2html's own quality bar is exactly this test
  (`test "output matches testdata"`, architecture/render_pipeline.md §5). Reaching parity
  de-risks every downstream P2/P3 subcommand that reduces to `renderGrid`.
- **Test infra for the rest of P1.M4.** P1.M4.T2.S2 (separate item) adds selection
  sub-rectangle + palette goldens ON TOP of this harness — the embed-manifest module and
  `golden_test.zig` shape established here are the foundation it extends.

## What

A `test` block (`src/golden_test.zig`) that, for each fixture name in `testdata/embed.zig`'s
`fixtures` array: feeds the embedded `.ansi` into `renderGrid` at `Size{ .cols=120, .rows=150 }`
with `palette.defaultColors()`, `sel = null` (whole grid), `font = null`, captures the HTML into
an `std.Io.Writer.Allocating`, and asserts `expectEqualStrings(embedded_html, rendered)`. The
`.html` expected files are **blessed from this project's own binary** (`tmux-2html render --cols
120 --rows 150 --palette default`), so input and expected are self-consistent by construction.

### Success Criteria

- [ ] `testdata/` contains 8 `.ansi`/`.html` pairs: `hyperfine`, `fastfetch`, `hyperlink`
      (vendored inputs, regenerated `.html`), plus `colors16`, `colors256`, `truecolor`,
      `attributes`, `osc8` (authored).
- [ ] `testdata/embed.zig` lists all 8 pairs in a `fixtures` array via `@embedFile`.
- [ ] `src/golden_test.zig` has ONE `test` function iterating `td.fixtures` with byte-equal
      assertions; a mismatch prints the fixture name + byte counts for fast triage.
- [ ] `zig build test -Doptimize=ReleaseFast` exits 0 with the golden test present.
- [ ] Coverage confirmed: 16-color (colors16), 256-color (colors256), truecolor (truecolor),
      attributes (attributes), OSC 8 (hyperlink + osc8) all represented.

## All Needed Context

### Context Completeness Check

_"If someone knew nothing about this codebase, would they have everything needed to implement
this successfully?"_ **Yes** — this PRP includes the exact `renderGrid` signature, the exact
byte format the goldens pin, the verified embed-module workaround for `@embedFile`'s package
boundary, the byte-precise `.ansi` authoring commands, the bless workflow, and the exact
insertion points in `build.zig` and `main.zig`. The ghostty-vt cross-test "GOTCHA" is addressed
(a separate test file is safe in ReleaseFast — the only mode that links).

### Documentation & References

```yaml
# MUST READ — verified architecture + research (read BEFORE implementing)
- docfile: plan/001_0c8587f91cb2/architecture/render_pipeline.md
  why: "§5 is the canonical description of term2html's golden test (the pattern we mirror)"
  section: "§5 Golden test harness + §1 renderGrid pipeline"
  critical: "term2html uses WindowSize{cols=120,rows=150}, defaultColors, expectEqualStrings,
             inline for over names. We mirror the PATTERN, not term2html's .html bytes."

- docfile: plan/001_0c8587f91cb2/P1M4T2S1/research/findings.md
  why: "The empirical ground truth for THIS task — every claim was rendered/built in-tree."
  section: "§0 (GOTCHA does not reproduce in ReleaseFast), §1 (@embedFile embed-module),
            §2 (binary==renderGrid byte-equal), §3 (do NOT vendor term2html .html), §8 (CSS map)"
  critical: "§4 is CORRECTED by §8: reverse→filter:invert(100%), dim→opacity:0.5 DO emit CSS.
             §1 is the build.zig/embed.zig solution. §2 is the bless command."

# THE PRIMITIVE UNDER TEST — read its full signature + the existing test pattern
- file: src/render.zig
  why: "renderGrid is what the golden harness calls. Its existing tests show the EXACT
        Allocating-writer pattern (renderToOwned) to copy. The single mega-test there is
        UNCHANGED by this task."
  pattern: "var aw = try std.Io.Writer.Allocating.initCapacity(alloc, N); defer aw.deinit();
            try renderGrid(alloc, ansi, .{.cols=120,.rows=150}, palette.defaultColors(), null, null, &aw.writer);
            const html = aw.writer.buffered();  // valid until aw.deinit()"
  gotcha: "renderGrid's font param: pass null (→ formatter defaults 'monospace') to MATCH the
           bless command (which omits --font). Passing the literal \"monospace\" is byte-identical
           (formatter does opts.font orelse \"monospace\") but null mirrors the binary path exactly."

- file: src/palette.zig
  why: "defaultColors() — the deterministic palette the test AND bless command both use."
  pattern: "palette.defaultColors() => palette=ghostty_vt.color.default, foreground=palette[7]
            (#c5c8c6), background={41,44,51} (#292c33), palette_received_count=256."
  gotcha: "Do NOT call palette.resolve() in the test (it may probe /dev/tty or read the cache —
           non-deterministic). defaultColors() is pure/deterministic."

# THE BINARY used to bless goldens
- file: src/cli.zig
  why: "confirms --cols / --rows / --palette flags exist (lines 160-163) for the bless command."
  pattern: "render --cols N --rows N --palette {default|cached|live}; --palette default forces
            defaultColors() deterministically (no tty/cache)."

# UPSTREAM FIXTURE INPUTS (vendored .ansi ONLY — never their .html)
- url: https://raw.githubusercontent.com/aarol/term2html/main/testdata/hyperfine.ansi
  why: "real-world benchmark ANSI (bold + 16-colors + UTF-8 special chars) — a baseline input."
  critical: "MIT (aarol); already covered by licenses/TERM2HTML.txt. Vendor the .ansi ONLY;
             regenerate .html with our binary (our formatter diverges — findings §3)."
- url: https://raw.githubusercontent.com/aarol/term2html/main/testdata/fastfetch.ansi
  why: "rich 256-color ASCII-art logo + system info — exercises the 256-color cube heavily."
- url: https://raw.githubusercontent.com/aarol/term2html/main/testdata/hyperlink.ansi
  why: "a single OSC 8 hyperlink — the canonical links case."
  critical: "OSC 8 uses BEL (0x07) terminator in this file; ghostty accepts BEL or ST (ESC \\)."
  # NOTE: copies of all three .ansi are also saved at research/{name}.ansi.ref as an offline
  # fallback if the fetch above is unavailable — author an equivalent .ansi if needed.
```

### Current Codebase tree (relevant subset)

```bash
src/
  main.zig            # top-level `test {}` block (lines 253-260) — ADD one import here
  render.zig          # renderGrid() + existing single mega-test (UNCHANGED by this task)
  palette.zig         # defaultColors() (UNCHANGED)
  cli.zig             # --cols/--rows/--palette (UNCHANGED)
  ghostty_format.zig  # vendored formatter (UNCHANGED — the thing goldens pin)
build.zig             # ADD one block: testdata embed-module import
build.zig.zon         # .paths already lists "testdata" (NO change needed)
testdata/
  .gitkeep            # (stays)
licenses/TERM2HTML.txt # already present (covers vendored .ansi inputs)
```

### Desired Codebase tree with files to be added

```bash
testdata/
  .gitkeep                 # (unchanged)
  embed.zig        # NEW — pub const fixtures = [_]Fixture{ ... @embedFile pairs ... }
  hyperfine.ansi   # NEW — vendored input
  hyperfine.html   # NEW — blessed (our binary)
  fastfetch.ansi   # NEW — vendored input
  fastfetch.html   # NEW — blessed
  hyperlink.ansi   # NEW — vendored input
  hyperlink.html   # NEW — blessed
  colors16.ansi    # NEW — authored (16 fg/bg, normal+bright)
  colors16.html    # NEW — blessed
  colors256.ansi   # NEW — authored (cube + grayscale)
  colors256.html   # NEW — blessed
  truecolor.ansi   # NEW — authored (38;2;r;g;b / 48;2;r;g;b)
  truecolor.html   # NEW — blessed
  attributes.ansi  # NEW — authored (bold/italic/underline/strike/reverse/dim + combos)
  attributes.html  # NEW — blessed
  osc8.ansi        # NEW — authored (multiple links + link-in-styled-span)
  osc8.html        # NEW — blessed
src/
  golden_test.zig  # NEW — one test fn: inline for over td.fixtures, renderGrid, expectEqualStrings
  main.zig         # MODIFIED — +1 line in the `test {}` block
build.zig          # MODIFIED — +1 block: testdata embed-module import
```

### Known Gotchas of our codebase & Library Quirks

```zig
// CRITICAL: `zig build test` (Debug) FAILS to LINK — Zig 0.15.2 emits
// `R_X86_64_PC64` relocations for the bundled C++ SIMD libs (ghostty simdutf/highway/utfcpp).
// PRD §15 mandates ReleaseFast. The gate is ALWAYS:  zig build test -Doptimize=ReleaseFast
// (verified EXIT 0). Do NOT report a Debug-mode link failure as a bug in your work.

// CRITICAL: @embedFile is CONFINED to a module's package root. The exe/test root is src/, so
// @embedFile("../testdata/x.ansi") from src/ FAILS ("file outside package path"). Solution: a
// SEPARATE module whose root is testdata/embed.zig — its sibling .ansi/.html ARE inside that
// package, so @embedFile("x.ansi") resolves. Wire it in build.zig (see Task 4). Verified.

// CRITICAL: do NOT vendor term2html's committed .html fixtures. Our src/ghostty_format.zig is
// a MODIFIED copy ("more idiomatic HTML") and our defaultColors() fg is palette[7]=#c5c8c6
// (term2html hardcodes #ffffff), plus we emit class="term2html-output" and max-width: (not
// overflow:auto;width:). term2html's .html will NOT byte-match. ALWAYS bless .html from our
// own binary. (The .ansi INPUTS are renderer-independent and safe to vendor.)

// GOTCHA: OSC 8 sequences MUST be terminated by BEL (0x07) or ST (ESC \). When authoring
// fixtures via printf, BEL is \007 (or \a). A literal "^G" in a shell string is TWO ascii
// chars and produces a malformed (silently eaten) sequence. Byte-precision is required.

// GOTCHA: ghostty_format emits a hyperlink's closing </a> LAZILY at the start of the NEXT
// cell run. If a hyperlink run is active across a '\n' (or across an SGR change on the next
// line), the </a> lands on the following line and can mis-nest with a <span>. So keep each
// OSC 8 scenario on ONE line with NO active link immediately before a newline (put trailing
// plain text / a closed span last). The osc8.ansi fixture above is a single line for this
// reason — it blesses to clean, well-formed HTML. (A golden CAN pin ugly output, but clean
// fixtures are far easier to read and maintain.)

// GOTCHA: bless with --palette default to force deterministic defaultColors(). Without it,
// resolve() may read the cache or probe /dev/tty (non-deterministic across machines), and the
// blessed .html would not match a clean machine's renderGrid(defaultColors()).

// GOTCHA (non-issue here, but noted): render.zig documents a "ghostty-vt cross-test GOTCHA"
// (Terminal.init in a separate test fn crashes). It does NOT reproduce in ReleaseFast (findings
// §0, empirically re-verified). golden_test.zig is a SEPARATE file/test-fn and is safe. The
// single inline-for-within-one-fn structure is still used (term2html's idiom; belt-and-suspenders).
```

## Implementation Blueprint

### Data models and structure

No new runtime data models. The only new type is the embed-manifest entry (compile-time only):

```zig
// testdata/embed.zig
pub const Fixture = struct { name: []const u8, ansi: []const u8, html: []const u8 };
pub const fixtures = [_]Fixture{ /* one per fixture pair, @embedFile'd */ };
```

The golden test consumes `td.fixtures` (where `td = @import("testdata")`). All `.ansi`/`.html`
bytes are baked into the test binary at compile time — zero runtime file I/O, zero CWD
sensitivity.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: CREATE the 8 testdata/*.ansi INPUT fixtures
  - VENDOR 3 inputs from term2html (MIT; licenses/TERM2HTML.txt already covers them). Fetch:
      curl -fsSL https://raw.githubusercontent.com/aarol/term2html/main/testdata/hyperfine.ansi -o testdata/hyperfine.ansi
      curl -fsSL https://raw.githubusercontent.com/aarol/term2html/main/testdata/fastfetch.ansi -o testdata/fastfetch.ansi
      curl -fsSL https://raw.githubusercontent.com/aarol/term2html/main/testdata/hyperlink.ansi -o testdata/hyperlink.ansi
    FALLBACK (no network): copies are at research/{name}.ansi.ref — `cp` those, or author an
    equivalent representative .ansi. (If you cannot get hyperfine/fastfetch, drop them and keep
    hyperlink + the 5 authored fixtures — the 16/256/truecolor/attr/links coverage is still met.)
  - AUTHOR 5 inputs with EXACT bytes (run these printf commands from the repo root; each ends
    with a trailing newline so the rendered .html has deterministic row structure):
      printf 'Normal: \033[30mK\033[31mR\033[32mG\033[33mY\033[34mB\033[35mM\033[36mC\033[37mW\033[0m\nBright: \033[90mK\033[91mR\033[92mG\033[93mY\033[94mB\033[95mM\033[96mC\033[97mW\033[0m\nBG: \033[41m \033[42m \033[43m \033[0m\n' > testdata/colors16.ansi
      printf 'Cube: \033[38;5;196mR\033[38;5;46mG\033[38;5;226mY\033[38;5;21mB\033[38;5;201mM\033[38;5;51mC\033[0m\nGray: \033[38;5;232m0\033[38;5;240m1\033[38;5;248m2\033[38;5;255m3\033[0m\nBG: \033[48;5;88m \033[48;5;22m \033[0m\n' > testdata/colors256.ansi
      printf 'FG: \033[38;2;255;0;0mR\033[38;2;0;255;0mG\033[38;2;0;0;255mB\033[38;2;128;64;200mP\033[0m\nBG: \033[48;2;255;128;0m \033[48;2;0;128;255m \033[0m\n' > testdata/truecolor.ansi
      printf '\033[1mbold\033[0m \033[3mitalic\033[0m \033[4munderline\033[0m \033[9mstrike\033[0m \033[7mreverse\033[0m \033[2mdim\033[0m\n\033[1;4mbold-underline\033[0m \033[3;9mitalic-strike\033[0m\n' > testdata/attributes.ansi
      printf '\033]8;;https://a.example\007A\033]8;;\007 \033]8;;https://b.example\007B\033]8;;\007 \033[31mbefore \033]8;;https://c.example\007link\033]8;;\007 after\033[0m\n' > testdata/osc8.ansi
    NAMING: lowercase, no extension variants (colors16, colors256, truecolor, attributes, osc8).
    GOTCHA: \007 = BEL terminator for OSC 8 (NOT literal "^G"). Verify with `cat -v testdata/osc8.ansi`.

Task 2: BUILD the binary, then BLESS the 8 testdata/*.html expected outputs
  - BUILD first (ReleaseFast, same mode tests run in):
      zig build -Doptimize=ReleaseFast
  - BLESS each .html from the binary at the FIXED golden size, forcing default palette:
      for n in hyperfine fastfetch hyperlink colors16 colors256 truecolor attributes osc8; do
        ./zig-out/bin/tmux-2html render --cols 120 --rows 150 --palette default \
          < testdata/$n.ansi > testdata/$n.html
      done
  - WHY THIS IS BYTE-EQUAL TO THE TEST: the binary's stdout path calls exactly
    renderGrid(alloc, ansi, .{120,150}, defaultColors(), null, null, out) — identical args to
    the test. --rows 150 is explicit (binary otherwise defaults rows to line count; identical
    after trim, but pin 150 to match the test exactly). --palette default => defaultColors().
    No --font => null => formatter defaults "monospace". VERIFIED byte-equal (findings §2/§8).
  - SANITY-CHECK one blessed file starts with the pinned header:
      head -c 90 testdata/attributes.html
    Expect: <pre class="term2html-output" style="max-width: 120ch; background-color: #292c33;color: #c5c8c6;font-family: monospace;">...

Task 3: CREATE testdata/embed.zig (the embed-manifest module)
  - IMPLEMENT: pub const Fixture struct + pub const fixtures array, one entry per pair.
  - Each entry: .{ .name = "<n>", .ansi = @embedFile("<n>.ansi"), .html = @embedFile("<n>.html") }
  - FILE LIVES IN testdata/ (its root IS the package; siblings resolve via @embedFile).
  - SEE full file content in "Implementation Patterns" below — copy it verbatim.
  - DEPENDENCIES: the .ansi/.html files from Tasks 1-2 MUST exist (else @embedFile fails to
    COMPILE — a missing fixture is a compile error, not a runtime error).

Task 4: MODIFY build.zig — wire the testdata embed-module import
  - ADD one block immediately BEFORE `b.installArtifact(exe);`:
        // P1.M4.T2.S1: embed golden fixtures (testdata/embed.zig roots a package so @embedFile
        // can reach its sibling .ansi/.html). Unreferenced on the prod path => not compiled in.
        const testdata_mod = b.createModule(.{ .root_source_file = b.path("testdata/embed.zig") });
        exe.root_module.addImport("testdata", testdata_mod);
  - WHY this reaches tests: the test step is `b.addTest(.{ .root_module = exe.root_module })` —
    it shares exe.root_module, so the "testdata" import is inherited by the test for free.
  - VERIFY prod is unaffected after wiring: `zig build -Doptimize=ReleaseFast` still succeeds
    and `ls -l zig-out/bin/tmux-2html` size is unchanged (lazy module; findings §1).

Task 5: CREATE src/golden_test.zig (the harness — separate file, own test fn)
  - IMPLEMENT: one `test "golden: ..."` function that `inline for (td.fixtures) |fx|` renders
    fx.ansi via renderGrid at .{120,150} with defaultColors(), sel=null, font=null, into an
    Allocating writer, and asserts expectEqualStrings(fx.html, aw.writer.buffered()).
  - ON MISMATCH: print the fixture name + expected/got byte counts BEFORE returning the error
    (a raw expectEqualStrings dumps the whole HTML — the name+counts line makes triage instant).
  - SEE full file content in "Implementation Patterns" below — copy it verbatim.
  - IMPORTS: const std, render = @import("render.zig"), palette = @import("palette.zig"),
    td = @import("testdata"). No ghostty-vt import needed (renderGrid encapsulates it).
  - DEPENDENCIES: Tasks 3+4 (the testdata module) must be wired first.

Task 6: MODIFY src/main.zig — make the golden test reachable
  - ADD one line in the top-level `test {}` block (lines 253-260), right after the existing
    `_ = @import("render.zig");` (line 259):
        _ = @import("golden_test.zig");
  - WHY: a top-level `test {}` block is compiled only in test mode and is what makes a sibling
    file's tests part of the test root. This mirrors how palette.zig/render.zig are already
    pulled in (lines 257-259).

Task 7: RUN the gate and confirm coverage
  - zig build test -Doptimize=ReleaseFast    # MUST exit 0
  - Confirm the golden test ran (see Validation Loop Level 2 for the exact check).
```

### Implementation Patterns & Key Details

```zig
// ===== testdata/embed.zig — copy verbatim (adjust the fixture list to what you created) =====
//! embed.zig — compile-time embed of the golden fixtures (P1.M4.T2.S1).
//! @embedFile is confined to a module's package root; this file roots the testdata/ package so
//! its sibling .ansi/.html pairs resolve. Wired into the build via build.zig
//! (exe.root_module.addImport("testdata", testdata_mod)).
pub const Fixture = struct { name: []const u8, ansi: []const u8, html: []const u8 };

pub const fixtures = [_]Fixture{
    .{ .name = "hyperfine", .ansi = @embedFile("hyperfine.ansi"), .html = @embedFile("hyperfine.html") },
    .{ .name = "fastfetch", .ansi = @embedFile("fastfetch.ansi"), .html = @embedFile("fastfetch.html") },
    .{ .name = "hyperlink", .ansi = @embedFile("hyperlink.ansi"), .html = @embedFile("hyperlink.html") },
    .{ .name = "colors16", .ansi = @embedFile("colors16.ansi"), .html = @embedFile("colors16.html") },
    .{ .name = "colors256", .ansi = @embedFile("colors256.ansi"), .html = @embedFile("colors256.html") },
    .{ .name = "truecolor", .ansi = @embedFile("truecolor.ansi"), .html = @embedFile("truecolor.html") },
    .{ .name = "attributes", .ansi = @embedFile("attributes.ansi"), .html = @embedFile("attributes.html") },
    .{ .name = "osc8", .ansi = @embedFile("osc8.ansi"), .html = @embedFile("osc8.html") },
};
```

```zig
// ===== src/golden_test.zig — copy verbatim =====
//! golden_test.zig — golden harness: testdata/*.ansi -> byte-equal *.html (P1.M4.T2.S1).
//!
//! Mirrors term2html's `test "output matches testdata"` (architecture/render_pipeline.md §5):
//! inline for over fixtures, fixed Size{120,150}, defaultColors(), expectEqualStrings. Fixtures
//! are embedded at compile time via the `testdata` module (testdata/embed.zig). The .html is
//! blessed from THIS binary (`render --cols 120 --rows 150 --palette default`), so the pair is
//! self-consistent; the test pins it against future regressions.
//!
//! Separate file/own test fn is safe: the documented "ghostty-vt cross-test GOTCHA" does not
//! reproduce in ReleaseFast (the only mode that links here; research findings §0/§8). The
//! single inline-for-within-one-fn structure is term2html's idiom and stays safe regardless.

const std = @import("std");
const render = @import("render.zig");
const palette = @import("palette.zig");
const td = @import("testdata");

test "golden: testdata/*.ansi renders byte-equal to testdata/*.html" {
    inline for (td.fixtures) |fx| {
        var aw = try std.Io.Writer.Allocating.initCapacity(std.testing.allocator, 1 << 16);
        defer aw.deinit();
        try render.renderGrid(
            std.testing.allocator,
            fx.ansi,
            .{ .cols = 120, .rows = 150 },
            palette.defaultColors(),
            null, // sel: whole grid. (P1.M4.T2.S2 owns selection sub-rectangle goldens.)
            null, // font: null => formatter defaults "monospace" (matches the no---font bless cmd).
            &aw.writer,
        );
        const got = aw.writer.buffered();
        std.testing.expectEqualStrings(fx.html, got) catch |err| {
            std.debug.print(
                "\n[golden] fixture '{s}' mismatch ({s}): expected {d} bytes, got {d} bytes\n",
                .{ fx.name, @errorName(err), fx.html.len, got.len },
            );
            return err;
        };
    }
}
```

```zig
// ===== build.zig — the ONE block to add (before `b.installArtifact(exe);`) =====
    // P1.M4.T2.S1: embed the golden fixtures as a module so tests can @embedFile testdata/*.
    // @embedFile is confined to a module's package root; testdata/embed.zig roots testdata/,
    // so its sibling .ansi/.html resolve. Unreferenced on the prod path => not compiled in.
    const testdata_mod = b.createModule(.{ .root_source_file = b.path("testdata/embed.zig") });
    exe.root_module.addImport("testdata", testdata_mod);
```

```zig
// ===== src/main.zig — the ONE line to add inside the `test {}` block (after render.zig) =====
    _ = @import("render.zig");
    _ = @import("golden_test.zig"); // P1.M4.T2.S1: golden harness (color/attr/OSC8 testdata)
```

**Pinned byte format reference (so blessed output is sanity-checkable, NOT to hand-author):**
- Header: `<pre class="term2html-output" style="max-width: 120ch; background-color: #292c33;color: #c5c8c6;font-family: monospace;">`
  (no space after `;`; `#rrggbb` lowercase). defaultColors: bg=#292c33, fg=#c5c8c6.
- Attribute CSS: bold=`font-weight: bold`; italic=`font-style: italic`;
  underline=`text-decoration-line: underline;text-decoration-style: solid`;
  strike=`text-decoration-line: line-through`; reverse=`filter: invert(100%)`; dim=`opacity: 0.5`.
- Color CSS: fg=`color: #rrggbb`; bg=`background-color: #rrggbb`. Plain text: no `<span>`.
- OSC 8: `<a style="color: inherit;" href="URI">text</a>` (nestable inside a `<span>`).
- Ends `</pre>`. Rows separated by literal `\n` (whitespace:pre).

### Integration Points

```yaml
BUILD (build.zig):
  - add: "a `testdata` module (root_source_file = testdata/embed.zig) imported into exe.root_module"
  - pattern: "b.createModule(.{ .root_source_file = b.path(\"testdata/embed.zig\") }) then addImport(\"testdata\", mod)"
  - placement: "immediately before b.installArtifact(exe); — the test step inherits exe.root_module"

TEST ROOT (src/main.zig):
  - add: "_ = @import(\"golden_test.zig\");"
  - placement: "inside the top-level test {} block (lines 253-260), after _ = @import(\"render.zig\");"

PACKAGE (build.zig.zon):
  - NO CHANGE — .paths already lists "testdata" (verified). Fixtures are picked up automatically.

LICENSING:
  - NO CHANGE — licenses/TERM2HTML.txt already present and covers the 3 vendored .ansi inputs.
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# After creating embed.zig / golden_test.zig and editing build.zig + main.zig:
zig build -Doptimize=ReleaseFast            # prod build must still succeed (module is lazy)
zig build test -Doptimize=ReleaseFast       # the GATE — see Level 2 for the test check
# Expected: both succeed, exit 0. A Debug-mode `R_X86_64_PC64` link error is EXPECTED and is
# NOT a defect in this work — ReleaseFast is mandatory (PRD §15). If ReleaseFast fails to
# COMPILE, the most likely cause is a missing testdata/<n>.ansi or .html referenced by embed.zig
# (@embedFile of a nonexistent file is a COMPILE error naming the path) — create/bless it.
```

### Level 2: Unit Tests (Component Validation)

```bash
# The gate. MUST exit 0.
zig build test -Doptimize=ReleaseFast

# Confirm the golden test actually RAN (not silently skipped). Run the compiled test binary
# directly and grep for the golden test name:
.find .zig-cache -name 'test' -type f -newermt '-5 minutes' 2>/dev/null | head -1 \
  | xargs -r ./ 2>/dev/null | grep -i golden || \
  ( echo "build the test runner list:"; \
    zig build test -Doptimize=ReleaseFast --summary all 2>&1 | grep -iE 'golden|test' | head )

# Expected: a line like  "golden: testdata/*.ansi renders byte-equal to testdata/*.html...OK"
# and "All N tests passed" with no failures. If a golden FAILS, the [golden] fixture '<name>'
# mismatch line names the culprit — re-bless THAT fixture (Task 2) and re-run.
```

### Level 3: Integration Testing (System Validation)

```bash
# Prove binary stdout == renderGrid output (the byte-equality guarantee underpinning the goldens):
# bless a fixture, then re-render it — the bytes must be byte-stable across runs.
./zig-out/bin/tmux-2html render --cols 120 --rows 150 --palette default < testdata/attributes.ansi \
  | diff - testdata/attributes.html && echo "STABLE: binary output matches committed golden"

# Prove prod binary size is UNAFFECTED by the testdata module (it must be lazy / unreferenced):
ls -l zig-out/bin/tmux-2html   # note the size; it should match a build from before this task
# (the testdata module is only pulled in by main.zig's test-only `test {}` block, never the exe)

# Prove OSC 8 BEL bytes survived authoring (catches the "^G" literal-byte bug):
cat -v testdata/osc8.ansi | grep -q '\^G' && echo "OSC8 BEL terminators present (good)" \
  || echo "WARN: no BEL (^G) in osc8.ansi — OSC 8 sequences may be malformed"

# Expected: STABLE matches, binary size unchanged, BEL terminators present.
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Coverage audit — confirm every required category has a fixture that actually exercises it:
for n in colors16 colors256 truecolor attributes osc8 hyperlink; do
  test -f testdata/$n.ansi && test -f testdata/$n.html && echo "OK  $n" || echo "MISSING $n"
done
# Spot-check each blessed .html contains the expected CSS signal (sanity, not assertion):
grep -q 'font-weight: bold'        testdata/attributes.html && echo "bold OK"
grep -q 'filter: invert(100%)'     testdata/attributes.html && echo "reverse OK"
grep -q 'text-decoration-line'     testdata/attributes.html && echo "underline/strike OK"
grep -q 'opacity: 0.5'             testdata/attributes.html && echo "dim OK"
grep -q '<a style="color: inherit;" href=' testdata/osc8.html && echo "osc8 link OK"
grep -q 'color: #'                 testdata/colors16.html && echo "16-color OK"
grep -q 'color: #'                 testdata/colors256.html && echo "256-color OK"
grep -q 'color: #ff0000'           testdata/truecolor.html && echo "truecolor OK"
# Expected: all OK lines print. (If a signal is absent, the fixture's .ansi didn't emit that SGR —
# re-author the .ansi and re-bless the .html.)

# Refresh workflow (whenever renderGrid/ghostty_format changes and goldens must move):
#   zig build -Doptimize=ReleaseFast
#   for n in hyperfine fastfetch hyperlink colors16 colors256 truecolor attributes osc8; do
#     ./zig-out/bin/tmux-2html render --cols 120 --rows 150 --palette default \
#       < testdata/$n.ansi > testdata/$n.html
#   done
#   zig build test -Doptimize=ReleaseFast   # green again
# Commit BOTH the .ansi and the regenerated .html together.
```

## Final Validation Checklist

### Technical Validation

- [ ] `zig build -Doptimize=ReleaseFast` succeeds (prod unaffected by the testdata module).
- [ ] `zig build test -Doptimize=ReleaseFast` exits 0.
- [ ] The `golden: ...` test appears in the test output and passes.
- [ ] All 8 fixture pairs exist under `testdata/` and are listed in `testdata/embed.zig`.
- [ ] `build.zig.zon` `.paths` includes `testdata` (it already does — no change).
- [ ] A Debug-mode link failure (`R_X86_64_PC64`) is NOT treated as a defect.

### Feature Validation

- [ ] Coverage: 16-color (colors16), 256-color (colors256), truecolor (truecolor),
      attributes (attributes), OSC 8 (hyperlink + osc8) all present and green.
- [ ] Vendored inputs (hyperfine/fastfetch/hyperlink .ansi) present; their `.html` are
      REGENERATED by our binary (not term2html's — byte-equal to renderGrid).
- [ ] Binary stdout is byte-stable vs the committed goldens (Level 3 diff).
- [ ] On a golden mismatch the test prints the fixture name + byte counts (not a raw dump).

### Code Quality Validation

- [ ] `golden_test.zig` follows the existing `renderToOwned` Allocating-writer pattern.
- [ ] File placement matches the desired tree (testdata/embed.zig, src/golden_test.zig).
- [ ] No scope creep: selection sub-rectangle + palette goldens are LEFT TO P1.M4.T2.S2.
- [ ] No new runtime dependencies; fixtures are compile-time `@embedFile` (zero runtime I/O).
- [ ] The existing `test "renderGrid: red foreground emits styled span"` in render.zig is
      UNCHANGED (this task adds a parallel test file, it does not touch that one).

### Documentation & Deployment

- [ ] No new env vars. No user-facing docs (contract DOCS §5: "none — test infra").
- [ ] licenses/TERM2HTML.txt already covers the vendored .ansi inputs (no new notice needed).
- [ ] The bless/refresh workflow is documented above for future maintainers.

---

## Anti-Patterns to Avoid

- ❌ Don't vendor term2html's committed `.html` fixtures — our formatter diverges (class
  attribute, max-width vs overflow/width, fg #c5c8c6 vs #ffffff). Always bless from our binary.
- ❌ Don't run tests in Debug — the `R_X86_64_PC64` link failure is a toolchain bug (PRD §15),
  not your code. The gate is `zig build test -Doptimize=ReleaseFast`.
- ❌ Don't use `@embedFile("../testdata/...")` from `src/` — it's outside the package root.
  Use the `testdata/embed.zig` manifest module (siblings resolve).
- ❌ Don't call `palette.resolve()` in the test (tty/cache probing = non-deterministic). Use
  `palette.defaultColors()` directly, and bless with `--palette default`.
- ❌ Don't bless without `--rows 150` and `--palette default` — the test pins exactly those.
- ❌ Don't author OSC 8 fixtures with a literal `^G`; BEL is byte `0x07` (`\007` in printf).
- ❌ Don't add selection/palette goldens here — that's P1.M4.T2.S2's scope.
- ❌ Don't merge the golden harness into render.zig's mega-test "for safety" — a separate file
  is verified safe in ReleaseFast and keeps the harness clean/extendable for S2.
