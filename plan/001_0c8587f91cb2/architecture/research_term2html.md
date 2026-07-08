# Research: upstream `aarol/term2html` (Zig + ghostty VT lib)

> **Source-of-sources caveat (READ FIRST).** This brief was produced **without live web
> access** and without a local clone of the repository. Per supervisor decision, it is
> written from training-data knowledge and tagged with explicit confidence levels. Every
> concrete identifier (struct name, field path, function signature, dependency URL/hash)
> is marked `[CONFIDENCE: …]` and flagged `UNVERIFIED — needs source confirmation` unless
> it rests on a well-established external standard (e.g. OSC color-query semantics, the
> Zig `.zon` dependency format). The supervisor will verify the critical struct names and
> `.zon` syntax via web search. **Treat all LOW/MEDIUM items as hypotheses to confirm
> against the real source, not as ground truth.**

Confidence legend:
- **HIGH** — grounded in a documented external standard (ECMA-48/xterm OSC, Zig PkgMgr).
- **MEDIUM** — consistent with training-data recall of this specific project, plausible, not independently verified here.
- **LOW** — directionally plausible only; near-certain to need correction.

---

## Summary

`aarol/term2html` is a small Zig CLI that renders ANSI/VT100 terminal output to HTML by
embedding the **ghostty** terminal emulator's reusable VT library: it instantiates a
virtual terminal of some cols/rows size, feeds the raw ANSI bytes through ghostty's VT
parser/stream to mutate a screen, then walks the resulting screen cells and emits styled
`<span>` HTML. Color fidelity comes from `terminal.queryColors`, which probes the *host*
terminal's palette via the OSC 4/10/11 query protocol and feeds those colors into the
renderer. Ghostty is declared as a normal Zig package dependency in `build.zig.zon` (a
tarball URL + multihash). Project confidence: the *mechanisms* (OSC color queries, `.zon`
format, virtual-terminal→HTML pipeline) are HIGH; the *exact identifier names and the
dependency hash* are UNVERIFIED and must be confirmed from source.

---

## Findings

### 1. Repository & project structure

1. **Repo exists; URL and exact structure UNVERIFIED.** The project is attributed to
   GitHub user **`aarol`**, project name **`term2html`**, i.e. `https://github.com/aarol/term2html`.
   `[CONFIDENCE: MEDIUM, UNVERIFIED — needs source confirmation]` — confirm the exact URL
   and that this is the Zig/ghostty project (not a same-named shell/Python script).

2. **Likely top-level layout.** A typical small Zig CLI: `build.zig`, `build.zig.zon`,
   `src/` source root, `README.md`, and a `test/` (or `tests/`) fixtures directory. The
   PRD names three source files which are consistent with a clean split:
   - `src/main.zig` — CLI entry: arg parsing, input reading, orchestration
     (read stdin/file → build terminal → feed ANSI → format → write HTML).
   - `src/ghostty_format.zig` — bridge to ghostty's screen formatter; defines the
     `Selection`/formatting adapter and produces the HTML from formatted cells.
   - `src/terminal.zig` — the `Terminal` wrapper around ghostty's VT parser/screen:
     sizing, feeding bytes, and `queryColors`.

   `[CONFIDENCE: MEDIUM, UNVERIFIED]` — the three-file split is plausible and matches the
   PRD, but exact filenames/contents must be read from the real tree. There may also be a
   `src/html.zig` or the HTML emission may live inside `ghostty_format.zig`.

---

### 2. ghostty `ScreenFormatter`, `.content.selection`, and the `Selection` struct

3. **The PRD claim (to verify).** The PRD states:
   `ghostty_format.ScreenFormatter.content.selection` accepts a
   `Selection{ start=(x,y), end=(x,y), rect=bool }`.
   `[CONFIDENCE: LOW–MEDIUM, UNVERIFIED — needs source confirmation]`.

4. **What the claim almost certainly maps to.** Ghostty ships a screen-content formatter
   used to materialize selected screen text (the same machinery it uses for clipboard
   copy). A terminal *selection* is canonically modeled as a start point + end point
   (each an x/column, y/row pair) plus a flag for **rectangular** selection (a.k.a.
   "rect" / block selection, the mode terminals/muxes use for column selections). So a
   `Selection{ start: Point, end: Point, rect: bool }` shape is **highly plausible** and
   consistent with how terminal selections are represented industry-wide
   `[CONFIDENCE: MEDIUM for the shape; HIGH for the general selection model]`. What is
   **not verified**:
   - Whether the type is literally named `Selection` (vs. e.g. `terminal.Selection` /
     `Selection.Range`) and which module owns it (ghostty core vs. term2html's
     `ghostty_format.zig` adapter).
   - Whether the access path is `ScreenFormatter.content.selection` or a constructor
     argument / `.selection` option struct.
   - Whether start/end are `.x`/`.y` or `.col`/`.row` or `.x`/`.y` tuples, and their
     coordinate origin (0-based cell coordinates within the screen).
   - The `rect` field name (could be `rect`, `rectangular`, `block`, or a tagged enum
     `mode = .rectangular`).

   **Verify against** `src/ghostty_format.zig` and the ghostty `terminal` package's
   selection types. Note term2html may construct a degenerate full-screen selection
   (start = top-left, end = bottom-right) to force the formatter to emit *all* cells
   rather than a user drag-selection — confirm this is how it coerces full-screen output.

5. **ghostty is the VT engine; the formatter exposes styled cell runs.** term2html does
   not write its own ANSI state machine. It leans on ghostty's terminal/parser/screen
   types and the formatter to walk cells, grouping consecutive cells that share the same
   SGR attributes (fg color, bg color, bold, italic, underline, etc.) into styled spans.
   `[CONFIDENCE: MEDIUM]` for the approach; `UNVERIFIED` for the exact formatter API
   surface (method names, iterator shape, how attributes map to CSS/inline styles).

---

### 3. `terminal.queryColors` — OSC 4 / 10 / 11 palette query

6. **OSC query semantics (the HIGH-confidence core).** `queryColors` interrogates the
   *host* terminal (the one the user runs term2html in) for its actual color scheme, so
   the generated HTML reproduces real colors rather than guessing a palette. The protocol
   is standard xterm/ECMA-48 (`ST` = string terminator = `ESC \` or `BEL`):
   - **OSC 4** — query a palette entry: request `OSC 4 ; Ps ; ? ST`
     (e.g. `\x1b]4;0;?\x1b\\`), response `OSC 4 ; Ps ; <spec> ST`. Multiple indices batch
     as `OSC 4 ; 0 ; ? ; 1 ; ? ; 2 ; ? … ST`. `Ps` is the color index (0–15 ANSI, often
     extended 0–255).
   - **OSC 10** — query default **foreground**: request `OSC 10 ; ? ST`, response
     `OSC 10 ; <spec> ST`.
   - **OSC 11** — query default **background**: request `OSC 11 ; ? ST`, response
     `OSC 11 ; <spec> ST`.
   The response `<spec>` is the X11 `rgb:` form: `rgb:RRRR/GGGG/BBBB` (1–4 hex digits per
   channel). Converting to 8-bit typically takes the high byte (or scales 4-bit nibbles).
   `[CONFIDENCE: HIGH — this is documented xterm control-sequence behavior, not
   term2html-specific.]`

7. **How `queryColors` is implemented (UNVERIFIED detail).** Based on the name and the
   OSC protocol, the expected flow is: switch the controlling tty to **raw mode**; write
   the OSC 4 (indices 0–15, possibly 0–255) + OSC 10/11 queries to the tty; **read back**
   the responses, using a synchronization marker (commonly a DSR/`OSC 5n` or a trailing
   distinct OSC) to know when all replies have arrived; parse the `rgb:` specs into RGB
   values; and return a palette struct (e.g. `Palette{ .colors: [N]Color, .fg, .bg }`)
   that the formatter consults when resolving "default" / indexed colors to concrete RGB
   for HTML styling. `[CONFIDENCE: MEDIUM — mechanism sound; exact signature, struct
   shape, raw-mode/sync technique, and whether it queries 16 or 256 colors are
   UNVERIFIED.]` Confirm against `src/terminal.zig`. Likely has a signature resembling
   `pub fn queryColors(terminal: *Terminal) !Palette` — **exact signature UNVERIFIED**.

8. **Graceful fallback expected.** Because OSC queries can fail (piped stdin, terminals
   that ignore them, timeouts), `queryColors` almost certainly degrades to a sensible
   built-in default palette (xterm/GNOME-style 16 colors) when no response arrives.
   `[CONFIDENCE: MEDIUM, UNVERIFIED]`.

---

### 4. `build.zig.zon` dependency on ghostty (URL/hash)

9. **The `.zon` dependency format is HIGH-confidence; the ghostty URL/hash are
   placeholders.** Zig packages are declared in `build.zig.zon` under `.dependencies`
   as a tarball `url` + multihash `hash` (the `hash` is `1220` + the base16/base32
   sha2-256, a multihash of the archive contents; computed automatically by `zig fetch`
   / `zig build --fetch`). The standard declaration is:

   ```zig
   // build.zig.zon  (illustrative — exact values UNVERIFIED)
   .{
       .name = .term2html,
       .version = "<VERIFY>",
       .minimum_zig_version = "<VERIFY>",
       .dependencies = .{
           .ghostty = .{
               .url = "<VERIFY: https://github.com/ghostty-org/ghostty/archive/<commit-sha>.tar.gz>",
               .hash = "<VERIFY: fetch the ghostty package then read the .hash value zig computes>",
               .lazy = false,
           },
       },
       .paths = .{ "build.zig", "build.zig.zon", "src" },
   }
   ```

   `[CONFIDENCE: HIGH for the schema/syntax of `.dependencies` / `.url` / `.hash`;
   CONFIDENCE: LOW for the specific ghostty tarball URL and commit; hash left as a
   placeholder and MUST NOT be guessed — an incorrect hash will hard-fail the build.]`

10. **Wiring it in `build.zig` (UNVERIFIED module name).** A dependency is consumed via
    `b.dependency("ghostty", .{})` and its module added to the executable, e.g.:

    ```zig
    // build.zig  (illustrative — ghostty module name UNVERIFIED)
    const ghostty = b.dependency("ghostty", .{});
    exe.root_module.addImport("ghostty", ghostty.module("ghostty")); // module name may differ
    // then in source: const ghostty = @import("ghostty");
    ```

    `[CONFIDENCE: HIGH for the `b.dependency` / `addImport` pattern; CONFIDENCE: LOW for
    ghostty's exact exposed module name(s) and whether extra build options / a C build of
    a `libghostty` artifact are required.]` Ghostty is a large C-interoperable codebase;
    confirm whether depending on it pulls a pure-Zig module or also compiles C sources
    (which affects cross-compilation / linking).

---

### 5. Virtual-terminal sizing (cols/rows) & feeding ANSI through the VT stream

11. **Pipeline (UNVERIFIED exact API).** The render pipeline is conceptually: create a
    ghostty `Terminal`/`Screen` of `cols × rows`; feed the raw ANSI bytes via ghostty's VT
    parser/stream so the screen state mutates (writing glyphs, applying SGR, scrolling);
    then read cells off the screen and format. `[CONFIDENCE: MEDIUM for the pipeline
    shape; the names `vtStream`, `Terminal`, `Parser`, `Screen`, `init(cols, rows)` are
    UNVERIFIED and likely approximate.]`

12. **Sizing strategy (the key unknown).** A virtual terminal must be pre-sized, but a
    file of arbitrary ANSI may have arbitrary line widths/heights. Plausible strategies:
    (a) **pre-scan** the decoded input to find the max line width and line count, then
    size the terminal to that (avoids unwanted wrapping/truncation — most likely for an
    ANSI→HTML tool); (b) a fixed default (e.g. 80×24) that lets ghostty wrap content; or
    (c) a CLI flag (`--cols`/`--rows`). `[CONFIDENCE: LOW–MEDIUM — pre-scan-to-fit is the
    most likely design but UNVERIFIED; confirm the exact default + whether wrapping
    occurs.]` The PRD should pin this down because it directly affects HTML fidelity
    (does a 200-col line wrap at 80?).

13. **`vtStream` / feed mechanism (UNVERIFIED).** Whatever ghostty's public programmatic
    entry point is (likely something like `Terminal.init(alloc, cols, rows)` then a
    `terminal.stream().print(bytes)` or `parser.parse(bytes)` callback into the terminal),
    term2html feeds the *entire* ANSI blob so all SGR/color/cursor state is replayed
    before formatting. `[CONFIDENCE: LOW for names, MEDIUM for the "feed everything then
    read screen" approach.]`

---

### 6. Test harness — golden `*.ansi → *.html`

14. **Golden-test pattern (HIGH-confidence pattern; UNVERIFIED file/function names).**
    A standard Zig golden-test setup: a `test/` directory holds paired fixtures
    (`foo.ansi` input + `foo.html` expected), and a test iterates the fixtures, runs the
    full pipeline (build terminal → feed `.ansi` → format → compare to `.html`), and
    fails on byte/normalized diff. `[CONFIDENCE: HIGH that it's a golden/fixture test;
    CONFIDENCE: LOW for exact directory name (`test/` vs `tests/`), fixture glob, and
    comparison normalization (whitespace/CSS-class-stability).]`

15. **Likely fixtures.** Expect representative cases: basic text, 16-color and 256-color
    SGR, truecolor (`SGR 38;2;r;g;b`), bold/italic/underline, nested attributes, cursor
    movement, and possibly a screen-dump-style ANSI. The HTML output format
    (inline styles vs. CSS classes vs. semantic `<span>` nesting) is itself a contract the
    tests pin down — confirm whether the expected HTML uses inline `style="color:#..."`
    or class-based styling, since tmux-2html will inherit/replace this. `[CONFIDENCE:
    MEDIUM, UNVERIFIED.]`

---

## Sources

Because this brief was produced offline, "sources" are organized by *type of evidence*
rather than live URLs to confirm. (No URLs were fetched.)

- **Kept / authoritative basis:**
  - xterm/ECMA-48 control-sequence spec for **OSC 4 / 10 / 11** color query/response and
    the `rgb:` response format — HIGH-confidence grounding for §3.
    (`invisible-island.net/…/ctlseqs.html`, `https://vt100.net` — standard references.)
  - Zig Package Manager docs for **`.zon` `.dependencies` / `.url` / `.hash` (multihash)**
    and the `b.dependency(...)` / `addImport` consumption pattern — HIGH-confidence
    grounding for §4. (`ziglang.org` build-system docs.)
  - General terminal-selection model (start/end point + rectangular flag) — grounds the
    plausibility of the `Selection` shape in §2.

- **Dropped / not usable:** Any SEO blog posts or generic "ansi2html" writeups — not
  specific to `aarol/term2html`'s Zig/ghostty implementation and excluded as unreliable.

- **NOT fetched (must be fetched to confirm):** `https://github.com/aarol/term2html` and
  its `build.zig.zon`, `src/main.zig`, `src/ghostty_format.zig`, `src/terminal.zig`,
  and test fixtures; plus the ghostty package's terminal/formatter/selection type
  definitions.

---

## Gaps (prominent — read before relying on this brief)

**Nothing in §1, §2, §5, §6 has been independently verified.** The following are the
concrete items that MUST be confirmed from the real source before the architecture plan
depends on them:

1. **Exact repo URL** `https://github.com/aarol/term2html` — confirm it is the
   Zig/ghostty project and get the canonical clone URL + latest commit.
2. **`ScreenFormatter` API** — confirm the type name, the access path
   `ScreenFormatter.content.selection`, the `Selection` struct's exact fields
   (`start`/`end` as `.x/.y` vs `.col/.row`, and `rect` vs `mode`/enum), and which module
   owns each type (ghostty core vs. term2html adapter). This is the PRD's central claim
   and is currently UNVERIFIED.
3. **`terminal.queryColors` signature + struct** — exact function signature, palette
   struct shape, raw-mode/sync implementation, and 16-vs-256 color coverage.
4. **`build.zig.zon`** — the **exact** ghostty tarball URL and commit, and the **computed
   `.hash`** (run `zig fetch <url>` to obtain it; do not guess). Also the module name and
   whether C sources are compiled.
5. **VT sizing strategy** — fixed default vs. pre-scan-to-fit vs. CLI flag; the default
   cols/rows; wrapping behavior. Materially affects HTML fidelity.
6. **`vtStream`/feed API names** — exact ghostty programmatic entry point for feeding bytes.
7. **Test harness** — fixture directory name, glob, normalization rules, and the **HTML
   output contract** (inline styles vs. CSS classes, span nesting), since tmux-2html will
   reuse or replace this format.
8. **License** of `aarol/term2html` (relevant if tmux-2html absorbs/derives code).

**Suggested next steps:** clone `aarol/term2html`; read `build.zig.zon`, the three
`src/*.zig` files, and `test/`; grep ghostty for `ScreenFormatter` / `Selection` /
`queryColors` / `vtStream`; run `zig fetch` on the ghostty URL to capture the real hash.

---

## Supervisor coordination

Web access was unavailable (tools limited to `read`/`write`/`contact_supervisor`/
`intercom`; no `web_search`; no local clone of the repo). Escalated via
`contact_supervisor` (`reason: need_decision`). Supervisor instructed: write from training
knowledge with per-item CONFIDENCE tags and `UNVERIFIED` markers, a prominent Gaps
section, and a placeholder (non-fabricated) `.zon` hash; supervisor will verify critical
struct names and `.zon` syntax via web search. This brief follows that instruction.
