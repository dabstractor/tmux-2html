# PRP — P1.M4.T1.S1: Coordinate → Pin → Selection construction + `--selection` flag

## Goal

**Feature Goal**: Wire the already-parsed `--selection X1,Y1,X2,Y2[,rect]` flag (PRD §5.1) into
`render.run` by translating the CLI coordinates into a native ghostty `Selection` (Pin-based),
built from the loaded screen's pages, and passing it to the formatter so only the selected
sub-grid is emitted (linewise by default; `rect=1` → block). This is the exact coordinate→Pin
machinery the region TUI reuses (P3.M2.T2.S2) and the final piece that makes `renderGrid`
honor a sub-grid selection.

**Deliverable**: `src/render.zig` MODIFIED — (1) `renderGrid`'s `sel` param changes from
`?Selection` to `?cli.SelectionCoords` and it builds the native `Selection` internally via a
new **public** `buildSelection(screen, coords)`; (2) `run()` gains an early `--selection`
branch that renders to a buffer, rejects empty/out-of-range selections (PRD §13), and routes
the bytes to stdout/`--output`/`--open`; (3) two small private helpers (`selectionBodyEmpty`,
`writeFileAtomic`). **No other source file changes** (`cli.zig` already parses + documents
`--selection` since P1.M1.T3.S2; `main.zig`/`palette.zig`/`ghostty_format.zig`/`build.zig`
untouched).

**Success Definition**:
- `printf 'R0\nR1\nR2\nR3\nR4\nR5' | tmux-2html render --cols 80 --selection 0,1,79,5` → HTML
  contains `R1`…`R5` and does **not** contain `R0` (linewise rows 1–5).
- `printf 'ABCDEFGHIJ\nABCDEFGHIJ\nABCDEFGHIJ' | tmux-2html render --cols 10 --selection
  2,0,5,2,1` → HTML contains `CDEF` and does **not** contain `ABCDEFGHIJ` (block cols 2–5).
- `--selection 9,0,9,0` with `--cols 5` (x ≥ cols) → stderr `selection out of range`, exit 1.
- A selection of only blank cells → stderr `selection is empty`, **no** output written, exit 1.
- `--selection` composes with `--output` (atomic file write) and `--open`.
- Whole-grid renders (no `--selection`) are **byte-identical** to before (S1/S2/S3 unchanged).
- `zig build -Doptimize=ReleaseFast` links; `zig build test -Doptimize=ReleaseFast` green.

## Why

- `renderGrid` already threads `sel: ?Selection` through to `f.content = .{ .selection = sel }`,
  but `run()` always passed `null`. A `Selection` can only be built from `Pin`s, and a `Pin`
  requires a loaded `Screen` — which only exists *inside* `renderGrid` (after `Terminal.init` +
  feeding ANSI). S1 closes that gap by building the Selection where the screen exists.
- PRD §2 finding 4 + §7.4: the formatter's native selection supports both line-range and
  rectangle/block rendering, inclusive on both ends. Exposing `--selection` on `render` gives
  scriptable/testable access to that machinery (PRD §5.1: "`--selection` exposes the
  formatter's native selection for scripting/tests").
- Contract point 4: the public `buildSelection(screen, coords)` is the **exact** reusable
  builder P3.M2.T2.S2 (region TUI coordinate→Selection conversion) calls.

## What

### User-visible behavior
- `render --selection X1,Y1,X2,Y2[,rect]` renders only the cells in the inclusive sub-grid
  `(x1,y1)…(x2,y2)`. `x`=column, `y`=row, origin top-left, indices in the loaded grid.
- `rect` omitted or `0` → **linewise** (full-width range: x-bounds apply only to the first/last
  row). `rect=1` → **block/rectangle** (x-bounds apply to *every* row).
- Start/end may be given in any order; the formatter normalizes (verified — `Selection.order`).
- A coordinate outside the grid (`x >= cols` or `y` past the last written row) → exit 1 with
  `tmux-2html render: selection out of range`.
- A valid-coordinate selection that covers only blank cells → exit 1 with
  `tmux-2html render: selection is empty` (PRD §13; no output written).
- Output bytes, exit codes (0/1/2), palette behavior, and all other flags are UNCHANGED when
  `--selection` is omitted.

### Success Criteria
- [ ] Linewise sub-grid emits exactly the selected rows (Level 3 #1).
- [ ] Block sub-grid emits exactly the selected columns on every selected row (Level 3 #2).
- [ ] Out-of-range coordinate → `selection out of range`, exit 1 (Level 3 #3).
- [ ] Blank-cell selection → `selection is empty`, no output, exit 1 (Level 3 #4).
- [ ] `--selection` composes with `--output` (atomic) and `--open` (Level 3 #5/#6).
- [ ] Whole-grid path byte-identical to pre-S4 (Level 4 regression).
- [ ] `zig build -Doptimize=ReleaseFast` links; `zig build test -Doptimize=ReleaseFast` green.

## All Needed Context

### Context Completeness Check

_Passed._ A developer new to this repo implements S1 from: the **verified** ghostty-vt API
(read directly from the v1.3.1 source — exact signatures with line numbers), the compile-shape
of every new function (mirrors existing `renderToFileAtomic`/`renderToOwned`), the probed HTML
output structure (blank grid → zero-byte body), the working build/test gates, and the
ghostty-vt test GOTCHA. The one subtlety (do NOT call `Selection.deinit`) is documented with
the source proof.

### Documentation & References

```yaml
# MUST READ — THIS task's research (every claim verified against ghostty v1.3.1 source + the binary)
- docfile: plan/001_0c8587f91cb2/P1M4T1S1/research/findings.md
  why: "The verified API (point.Point union + .screen tag; PageList.pin; Selection.init by-value
        Pins + untracked; deinit is a NO-OP for untracked and needs mutable *Screen => DO NOT call
        it); the refactor (renderGrid builds the native Selection internally); empty-selection
        detection (zero-byte body); the .screen-tag rationale; build-env caveat; test GOTCHA."
  section: "§0 gap, §1 API, §2 refactor, §3 empty check, §4 errors, §5 scope, §6 build, §7 GOTCHA"

# The architecture source of truth (VERIFIED from source) — §0.2 + §4 are THIS task's contract
- docfile: plan/001_0c8587f91cb2/architecture/findings_and_corrections.md
  why: "§0.2: Selection is Pin-based (NOT coordinate tuples); rectangle field (not rect); must
        convert coords->Pin via PageList. §0.3: ScreenFormatter.Content = union{none, selection:
        ?Selection}. §2.4: Selection.init(start_pin,end_pin,rect)."
- docfile: plan/001_0c8587f91cb2/architecture/render_pipeline.md
  why: "§4: the EXACT selection pipeline — build Terminal+Screen, pin() the coords, Selection.init,
        set content.selection = sel, print. §4 also flags 'VERIFY deinit signature' and 'how to
        build a point.Point' — BOTH VERIFIED in findings.md §1 (deinit => skip; point =>
        .{ .screen = .{ .x, .y } })."

# The PRD contract
- docfile: plan/001_0c8587f91cb2/prd_snapshot.md
  why: "§5.1 render (--selection X1,Y1,X2,Y2[,rect]; rect=1 -> block; exposes native selection for
        scripting/tests); §7.4 Selection -> output mapping (linewise start=(0,r1) end=(cols-1,r2)
        rect=false; block start=(c1,r1) end=(c2,r2) rect=true; cell indices in the loaded grid);
        §13 edge case (Empty/zero-cell selection on confirm: warn, no file, exit 1)."

# The parallel sibling PRP — S3 is being implemented concurrently; S4 builds on run()'s shape
- docfile: plan/001_0c8587f91cb2/P1M3T1S3/PRP.md
  why: "S3 changes the ONE `colors` line in run() to palette.resolve(...). S4 does NOT touch that
        line. S4 adds the selection branch + threads opts.selection. The two PRPs edit DIFFERENT
        regions of run() (colors line vs the output arms + new early branch) and compose cleanly."

# Existing source files to FOLLOW / CONSUME
- file: src/render.zig   # S4 EDITS THIS FILE (renderGrid sig + run branch + 3 helpers + tests)
  why: "renderGrid already builds the Terminal, feeds ANSI, and sets f.content = .{ .selection = sel }.
        S1 (P1.M3.T1.S1) created it; S2 added sizing/output/open; S3 swaps the colors line; S4 wires
        --selection. renderToOwned/renderToFileAtomic/tempHtmlPath/spawnXdgOpen are the patterns to
        mirror (Allocating writer; atomic temp+rename; xdg-open reap)."
  pattern: "renderGrid(alloc,ansi,size,colors,sel,font,out); renderToFileAtomic (atomic idiom);
            renderToOwned (Allocating writer test helper)."
  gotcha: "ghostty-vt Terminal.init corrupts process-global state across SEPARATE test functions
           (core dump). ALL renderGrid/Terminal assertions (selection included) MUST live in the ONE
           existing `test \"renderGrid: …\"` function — APPEND to it. Pure helpers get own tests."

- file: src/cli.zig   # NOT EDITED — CONSUME SelectionCoords
  why: "SelectionCoords{ x1,y1,x2,y2: u32; rect: bool = false } (cli.zig:54-61); parseSelection
        (152-170) already parses `--selection X1,Y1,X2,Y2[,rect]` (rect==1 => true); RenderOpts.
        selection: ?SelectionCoords (71); render_help already lists `--selection` (contract §5 done)."
  gotcha: "cli.zig MUST stay ghostty-free. SelectionCoords stores u32 (not u16); buildSelection
           must guard x > maxInt(u16) before @intCast (point.Coordinate.x is size.CellCountInt = u16)."

- file: src/ghostty_format.zig   # NOT EDITED (vendored)
  why: "ScreenFormatter.Content = union{ none, selection: ?Selection } (line ~477); format() (555)
        sets list_formatter.top_left = sel.topLeft(screen) / .bottom_right = sel.bottomRight(screen)
        / .rectangle = sel.rectangle (567-569); PageListFormatter iterates tl..br INCLUSIVE,
        rectangle applies x-bounds to every row (636-641). Blank cells emit NOTHING (verified)."

# Verified ghostty-vt source (read directly; line numbers from v1.3.1)
- file: ~/.cache/zig/p/ghostty-1.3.1-*/src/terminal/point.zig
  why: "Point = union(Tag){ active, viewport, screen, history: Coordinate } (:52); Coordinate{ x:
        size.CellCountInt(=u16), y: u32 } (:69). Build: point.Point{ .screen = .{ .x, .y } }."
- file: ~/.cache/zig/p/ghostty-1.3.1-*/src/terminal/PageList.zig
  why: "pin(self: *const PageList, pt: point.Point) ?Pin (:3875) — returns null if x>=cols OR y past
        the page list; uses pt's TAG via getTopLeft(pt). Pin = value struct (:5042). screen.pages is
        a PageList (Screen.zig:39)."
- file: ~/.cache/zig/p/ghostty-1.3.1-*/src/terminal/Selection.zig
  why: "init(start_pin: Pin, end_pin: Pin, rect: bool) Selection (:55) — Pins BY VALUE, creates
        UNTRACKED. deinit(self, *Screen) (:69) — NO-OP for untracked AND needs MUTABLE *Screen => DO
        NOT CALL. topLeft/bottomRight/order take *const Screen, normalize order, use .screen tag."
- file: ~/.cache/zig/p/ghostty-1.3.1-*/src/lib_vt.zig   # the ghostty-vt module root
  why: "re-exports point(:25), page(:32), PageList(:48), Pin(:50), Screen(:53), Selection(:55),
        Terminal(:59). So `const point = ghostty_vt.point; const Screen = ghostty_vt.Screen;`."
```

### Current Codebase tree (S1's baseline = post-S3, with S4's edits marked)

```bash
src/
├── main.zig            # dispatch + --version/--help; test root imports render.zig — CONSUME
├── cli.zig             # SelectionCoords + parseSelection + render_help ALL DONE — CONSUME, NOT EDITED
├── palette.zig         # resolve/Mode/hasControllingTty/defaultColors — CONSUME, NOT EDITED
├── render.zig          # S1: renderGrid+Size; S2: sizing/output/open; S3: colors line; S4: THIS TASK
└── ghostty_format.zig  # VENDORED — DO NOT EDIT
build.zig / build.zig.zon   # NOT EDITED
testdata/                   # EMPTY — P1.M4.T2 (golden harness) owns it; S4 uses inline fixtures
```

### Desired Codebase tree (this task)

```bash
src/
├── render.zig          # MODIFIED: renderGrid sel param -> ?cli.SelectionCoords + internal build;
│                       #   +pub buildSelection; +selectionBodyEmpty; +writeFileAtomic; run() branch; tests
└── (all other files unchanged)
```

### Known Gotchas of our codebase & Library Quirks

```zig
// CRITICAL — DO NOT call sel.deinit(...). Selection.init creates an UNTRACKED selection (no heap,
// no tracking handles); Selection.deinit is a NO-OP for untracked bounds (Selection.zig:79) AND it
// takes a MUTABLE *Screen which we don't have (t.screens.active is *const Screen). The contract's
// pseudo `defer sel.deinit(...)` is superseded — it said "VERIFY deinit signature"; VERIFIED => skip.

// CRITICAL — point.Coordinate.x is size.CellCountInt = u16 (point.zig:72, size.zig:22). cli stores
// u32. A raw @intCast of a u32 > maxInt(u16) TRAPS in Debug/ReleaseSafe and is UB in ReleaseFast.
// GUARD coords.x1/x2 > maxInt(u16) => error.OutOfRange BEFORE @intCast. (.y is u32 => direct.)

// CRITICAL — use the `.screen` TAG when building point.Points: `point.Point{ .screen = .{.x,.y} }`.
// PageList.pin uses the point's tag via getTopLeft(pt); the formatter's own order()/getTopLeft use
// `.screen` internally, so `.screen` is consistent. For render (rows = line count, no scrollback),
// `.screen` top-left == grid row 0. Selecting rows past the last WRITTEN row => pin null => OutOfRange
// (`.screen` covers only written rows; this is the safe, intended behavior).

// CRITICAL (test GOTCHA) — ghostty-vt Terminal.init corrupts process-global state across SEPARATE
// test functions (core dump). Sequential renderGrid calls in the SAME test scope are fine. So APPEND
// all selection/Terminal assertions to the EXISTING `test "renderGrid: …"` fn; do NOT add a 2nd
// terminal-touching test. selectionBodyEmpty + writeFileAtomic are PURE => own test fns.

// CRITICAL (build env) — bare `zig build` / `zig build test` FAIL TO LINK under GCC 16
// (R_X86_64_PC64 in crt1.o:.sframe) — toolchain artifact, not a code error. Use -Doptimize=ReleaseFast
// for BOTH build and test (those link + run cleanly).

// The formatter emits NOTHING for blank cells (verified: 5 blank lines => `<pre ...></pre>`, zero-byte
// body). Plain unstyled text is emitted WITHOUT <span> (S1's test confirms). So "no <span>" is NOT an
// emptiness signal — only the BODY between `<pre ...>` and `</pre>` is (empty/whitespace => empty).

// renderGrid's sel param changes ?Selection -> ?cli.SelectionCoords. ALL existing null call sites
// (renderToOwned, renderToFileAtomic, run's stdout arm) keep passing null — now typed ?cli.SelectionCoords.
// renderToFileAtomic is NOT modified (S2 owns it; it always renders the whole grid with sel: null).
```

## Implementation Blueprint

### Data models and structure

```zig
// src/render.zig — NO new public TYPES. S4 adds functions, not types.
// New top-level imports (render.zig already has ghostty_vt, Terminal, Selection):
const point = ghostty_vt.point;   // point.Point, point.Coordinate
const Screen = ghostty_vt.Screen; // *const Screen param of buildSelection
// (Pin is returned by screen.pages.pin() with inferred type — no explicit const needed.)
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: MODIFY src/render.zig — ADD the `point`/`Screen` imports
  - ADD after the existing `const Selection = ghostty_vt.Selection;` line:
        const point = ghostty_vt.point;
        const Screen = ghostty_vt.Screen;
  - WHY: buildSelection builds point.Point{ .screen = ... } and takes a *const Screen.
  - VERIFY: lib_vt.zig re-exports point (:25) and Screen (:53) — confirmed.

Task 2: MODIFY src/render.zig — ADD `pub fn buildSelection` (the reusable builder; VERIFIED API)
  - IMPLEMENT:
      /// Build a ghostty Selection from CLI coords against a loaded screen (PRD §5.1/§7.4).
      /// Reusable: renderGrid calls this internally; the TUI (P3.M2.T2.S2) calls it directly.
      /// Coords are CELL INDICES in the loaded grid (x=col, y=row, origin top-left). `.screen` tag
      /// (consistent with the formatter's own coordinate reasoning). start/end may be any order.
      /// error.OutOfRange if a coord is outside the grid (x>=cols or y past the last written row).
      pub fn buildSelection(screen: *const Screen, coords: cli.SelectionCoords) error{OutOfRange}!Selection {
          // .x is size.CellCountInt (u16); cli stores u32. Guard before @intCast.
          if (coords.x1 > std.math.maxInt(u16) or coords.x2 > std.math.maxInt(u16))
              return error.OutOfRange;
          const start_pt = point.Point{ .screen = .{ .x = @intCast(coords.x1), .y = coords.y1 } };
          const end_pt   = point.Point{ .screen = .{ .x = @intCast(coords.x2), .y = coords.y2 } };
          const sp = screen.pages.pin(start_pt) orelse return error.OutOfRange;
          const ep = screen.pages.pin(end_pt)   orelse return error.OutOfRange;
          return Selection.init(sp, ep, coords.rect); // untracked; NO deinit (findings §1)
      }
  - NAMING: buildSelection. PLACEMENT: render.zig, near renderGrid (private-helpers region OK too).
  - GOTCHA: NO deinit (untracked; deinit is a no-op + needs mutable *Screen). Guards x>maxInt(u16).
  - GOTCHA: screen.pages.pin works on *const Screen (pin takes *const PageList). start/end ANY order.

Task 3: MODIFY src/render.zig — CHANGE renderGrid's sel param + build the native Selection internally
  - CHANGE the signature: `sel: ?Selection,` -> `sel: ?cli.SelectionCoords,`
  - AFTER the ANSI feed loop, BEFORE `var f = fmt.ScreenFormatter.init(...)`, ADD:
        // S1 (P1.M4.T1.S1): build the native Selection from CLI coords now that the screen exists.
        // renderGrid owns the Terminal/Screen, so the coordinate->Pin translation happens here.
        var native_sel: ?Selection = null;
        if (sel) |coords| native_sel = try buildSelection(t.screens.active, coords);
  - CHANGE the content line to use native_sel: `f.content = .{ .selection = native_sel };`
  - UPDATE renderGrid's doc comment: `sel` is now `?cli.SelectionCoords` (null = whole grid);
    remove the "S4 passes a Selection built from Pins" note (S4 passes coords + builds internally).
  - PRESERVE: Terminal.init/deinit, the per-byte \n->\r\n feed loop, ScreenFormatter.init opts,
    f.extra = .styles, out.print. The non-selection path (sel==null) is byte-identical to before.
  - GOTCHA: t.screens.active is *const Screen (ScreenFormatter.init already takes it). buildSelection
    takes *const Screen => matches. error.OutOfRange from buildSelection propagates via `try`.

Task 4: MODIFY src/render.zig — ADD `fn selectionBodyEmpty` (PURE; PRD §13 empty check)
  - IMPLEMENT:
      /// True if a rendered selection's body (between `<pre ...>` and `</pre>`) is empty or
      /// all-whitespace — i.e. the selection covered only blank cells (PRD §13 => warn, exit 1).
      /// The formatter emits NOTHING for blank cells (verified); plain text is emitted without
      /// <span>, so body content (not <span> presence) is the only valid signal.
      fn selectionBodyEmpty(html: []const u8) bool {
          const pre = std.mem.indexOf(u8, html, "<pre") orelse return false;
          const open_end = std.mem.indexOfScalarPos(u8, html, pre, '>') orelse return false;
          const close = std.mem.indexOfPos(u8, html, open_end + 1, "</pre>") orelse return false;
          const body = html[open_end + 1 .. close];
          for (body) |c| if (!std.ascii.isWhitespace(c)) return false;
          return true;
      }
  - NAMING: selectionBodyEmpty. PLACEMENT: render.zig private-helpers region.
  - GOTCHA: treat malformed HTML (no <pre / no </pre>) as NON-empty (return false) — never false-positive.

Task 5: MODIFY src/render.zig — ADD `fn writeFileAtomic` (atomic write of pre-rendered bytes)
  - IMPLEMENT (mirror renderToFileAtomic's proven temp+rename idiom; writes `bytes` instead of rendering):
      /// Write pre-rendered `bytes` to `path` ATOMICALLY (temp + rename in the same dir). Used by
      /// the --selection path, which buffers output to validate non-emptiness before writing.
      /// Mirrors renderToFileAtomic (S2) but for already-rendered bytes (no renderGrid call).
      fn writeFileAtomic(alloc: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
          const dir_path = std.fs.path.dirname(path) orelse ".";
          const base = std.fs.path.basename(path);
          var rnd: [4]u8 = undefined;
          std.crypto.random.bytes(&rnd);
          const tmp_name = try std.fmt.allocPrint(alloc, ".{s}.{x}.tmp", .{ base, @as(u32, @bitCast(rnd)) });
          defer alloc.free(tmp_name);
          var dir = if (std.fs.path.isAbsolute(dir_path))
              try std.fs.openDirAbsolute(dir_path, .{})
          else
              try std.fs.cwd().openDir(dir_path, .{});
          defer dir.close();
          var f = try dir.createFile(tmp_name, .{});
          errdefer { f.close(); dir.deleteFile(tmp_name) catch {}; }
          try f.writeAll(bytes);
          f.sync() catch {};
          f.close();
          try dir.rename(tmp_name, base);
      }
  - NAMING: writeFileAtomic. PLACEMENT: render.zig near renderToFileAtomic.
  - GOTCHA: do NOT modify renderToFileAtomic (S2 owns it; it always renders whole-grid sel:null).
    Minor duplication of the atomic idiom is intentional — keeps S2's code untouched (no regression).

Task 6: MODIFY src/render.zig — ADD the `--selection` branch to run()
  - FIND: after `const size = Size{ .cols = cols, .rows = rows };` and the existing
      `const stderr = std.fs.File.stderr();` line, INSERT (before the existing `if (opts.output)`):
        if (opts.selection) |coords| {
            // Render to a buffer so we can (a) detect an empty/zero-cell selection (PRD §13) and
            // (b) route the same bytes to any sink. renderGrid builds the native Selection internally.
            var aw = std.Io.Writer.Allocating.initCapacity(alloc, 4096) catch {
                stderr.writeAll("tmux-2html render: out of memory\n") catch {};
                return 1;
            };
            defer aw.deinit();
            renderGrid(alloc, ansi, size, colors, coords, opts.font, &aw.writer) catch |err| switch (err) {
                error.OutOfRange => {
                    stderr.writeAll("tmux-2html render: selection out of range\n") catch {};
                    return 1;
                },
                else => {
                    stderr.writeAll("tmux-2html render: write failed\n") catch {};
                    return 1;
                },
            };
            const html = aw.writer.buffered();
            if (selectionBodyEmpty(html)) {
                stderr.writeAll("tmux-2html render: selection is empty\n") catch {};
                return 1;
            }
            if (opts.output) |path| {
                writeFileAtomic(alloc, path, html) catch {
                    stderr.writeAll("tmux-2html render: cannot write output file\n") catch {};
                    return 1;
                };
                if (opts.open) spawnXdgOpen(path, alloc);
            } else if (opts.open) {
                const tmp = tempHtmlPath(alloc) catch {
                    stderr.writeAll("tmux-2html render: cannot allocate temp path\n") catch {};
                    return 1;
                };
                defer alloc.free(tmp);
                writeFileAtomic(alloc, tmp, html) catch {
                    stderr.writeAll("tmux-2html render: cannot write temp file\n") catch {};
                    return 1;
                };
                spawnXdgOpen(tmp, alloc);
            } else {
                std.fs.File.stdout().writeAll(html) catch {
                    stderr.writeAll("tmux-2html render: write failed\n") catch {};
                    return 1;
                };
            }
            return 0;
        }
  - WHY the buffer: the empty check must inspect rendered bytes; routing the same buffer to any sink
      keeps the three output arms consistent. The non-selection path (below) is UNCHANGED.
  - PRESERVE: S3's `colors` line (palette.resolve) — do NOT touch it. The existing non-selection
      `if (opts.output) |path| { ... } else if (opts.open) { ... } else { stdout }` block stays verbatim
      (it still passes sel:null to renderGrid/renderToFileAtomic). S4 only INSERTS the early branch.
  - GOTCHA: `aw.writer.buffered()` is a slice into aw's buffer; use it BEFORE the block's `defer aw.deinit()`
      frees it (all routing happens inside the block). std.fs.File.stdout().writeAll is fine here.

Task 7: ADD tests to src/render.zig (APPEND terminal-touching assertions; separate pure tests)
  - ADD a sibling test helper next to renderToOwned:
        fn renderSelOwned(ansi: []const u8, size: Size, coords: cli.SelectionCoords) ![]u8 {
            var aw = try std.Io.Writer.Allocating.initCapacity(std.testing.allocator, 4096);
            defer aw.deinit();
            try renderGrid(std.testing.allocator, ansi, size, palette.defaultColors(), coords, "monospace", &aw.writer);
            return std.testing.allocator.dupe(u8, aw.writer.buffered());
        }
  - APPEND to the EXISTING `test "renderGrid: red foreground emits styled span"` (the ONE terminal
      scope — do NOT create a 2nd terminal-touching test, per the GOTCHA):
        // S1 (P1.M4.T1.S1): selection sub-grid rendering.
        const lw = try renderSelOwned("R0\nR1\nR2\nR3\nR4\nR5", .{ .cols = 80, .rows = 6 },
            .{ .x1 = 0, .y1 = 1, .x2 = 79, .y2 = 5 }); // linewise rows 1..5
        defer std.testing.allocator.free(lw);
        try std.testing.expect(std.mem.indexOf(u8, lw, "R1") != null);
        try std.testing.expect(std.mem.indexOf(u8, lw, "R5") != null);
        try std.testing.expect(std.mem.indexOf(u8, lw, "R0") == null); // row 0 excluded

        const blk = try renderSelOwned("ABCDEFGHIJ\nABCDEFGHIJ\nABCDEFGHIJ", .{ .cols = 10, .rows = 3 },
            .{ .x1 = 2, .y1 = 0, .x2 = 5, .y2 = 2, .rect = true }); // block cols 2..5
        defer std.testing.allocator.free(blk);
        try std.testing.expect(std.mem.indexOf(u8, blk, "CDEF") != null);
        try std.testing.expect(std.mem.indexOf(u8, blk, "ABCDEFGHIJ") == null); // only the block cols

        // out-of-range (x >= cols) => error.OutOfRange (drive renderGrid directly to see the error)
        var aw_oor = try std.Io.Writer.Allocating.initCapacity(std.testing.allocator, 64);
        defer aw_oor.deinit();
        try std.testing.expectError(error.OutOfRange, renderGrid(std.testing.allocator, "AB",
            .{ .cols = 5, .rows = 2 }, palette.defaultColors(), .{ .x1 = 9, .y1 = 0, .x2 = 9, .y2 = 0 },
            "monospace", &aw_oor.writer));
  - ADD a SEPARATE pure test (no Terminal — safe):
        test "selectionBodyEmpty: blank body => true; content => false" {
            try std.testing.expect(selectionBodyEmpty("<pre class=\"x\" style=\"a:b;\"></pre>"));
            try std.testing.expect(selectionBodyEmpty("<pre class=\"x\">   \n  \t </pre>"));
            try std.testing.expect(!selectionBodyEmpty("<pre class=\"x\">hi</pre>"));
            try std.testing.expect(!selectionBodyEmpty("<pre class=\"x\"><span style=\"color:#fff;\">A</span></pre>"));
            try std.testing.expect(!selectionBodyEmpty("no pre tag at all")); // malformed => non-empty
        }
  - ADD a SEPARATE pure test (tmpDir round-trip; mirrors renderToFileAtomic's atomic test):
        test "writeFileAtomic: writes target, leaves no .tmp" {
            const alloc = std.testing.allocator;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const dir_abs = try tmp.dir.realpathAlloc(alloc, ".");
            defer alloc.free(dir_abs);
            const abs = try std.fmt.allocPrint(alloc, "{s}/out.html", .{dir_abs});
            defer alloc.free(abs);
            try writeFileAtomic(alloc, abs, "<pre>BODY</pre>");
            var f = try tmp.dir.openFile("out.html", .{});
            defer f.close();
            const got = try f.readToEndAlloc(alloc, 1 << 16);
            defer alloc.free(got);
            try std.testing.expectEqualStrings("<pre>BODY</pre>", got);
            var it = tmp.dir.iterate(); // exactly one entry ("out.html"); no .tmp leaked
            var count: usize = 0;
            while (try it.next()) |e| { count += 1; try std.testing.expect(!std.mem.endsWith(u8, e.name, ".tmp")); }
            try std.testing.expectEqual(@as(usize, 1), count);
        }
  - NOTE: main.zig's `test { _ = @import("render.zig"); }` already makes all render.zig tests reachable.
```

### Implementation Patterns & Key Details

```zig
// renderGrid after S1's edit (the substantive diff is small):
pub fn renderGrid(
    alloc: std.mem.Allocator,
    ansi: []const u8,
    size: Size,
    colors: palette.Colors,
    sel: ?cli.SelectionCoords, // CHANGED: was ?Selection. null = whole grid.
    font: ?[]const u8,
    out: *std.Io.Writer,
) !void {
    var t = try Terminal.init(alloc, .{ .cols = size.cols, .rows = size.rows });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    for (ansi) |c| { if (c == '\n') try stream.next('\r'); try stream.next(c); }

    // S1: build the native Selection now that the screen exists (renderGrid owns the Terminal).
    var native_sel: ?Selection = null;
    if (sel) |coords| native_sel = try buildSelection(t.screens.active, coords);

    var f = fmt.ScreenFormatter.init(t.screens.active, .{
        .emit = .html, .background = colors.background, .foreground = colors.foreground,
        .palette = &colors.palette, .font = font,
    });
    f.content = .{ .selection = native_sel }; // null = whole grid; some(sel) = sub-grid (inclusive)
    f.extra = .styles;
    try out.print("{f}", .{f});
}

// run()'s new early branch (inserted after `size`/`stderr`, before the existing output arms).
// The existing whole-grid output arms (opts.output / opts.open / stdout) stay VERBATIM below it.
if (opts.selection) |coords| {
    var aw = std.Io.Writer.Allocating.initCapacity(alloc, 4096) catch { /*oom*/ return 1; };
    defer aw.deinit();
    renderGrid(alloc, ansi, size, colors, coords, opts.font, &aw.writer) catch |err| switch (err) {
        error.OutOfRange => { stderr.writeAll("...selection out of range\n") catch {}; return 1; },
        else => { stderr.writeAll("...write failed\n") catch {}; return 1; },
    };
    const html = aw.writer.buffered();
    if (selectionBodyEmpty(html)) { stderr.writeAll("...selection is empty\n") catch {}; return 1; }
    // route html to stdout / writeFileAtomic(--output) / writeFileAtomic(temp)+xdg-open
    return 0;
}
```

### Integration Points

```yaml
BUILD: none. build.zig unchanged. S1 adds no new modules (point/Screen are fields of the already-
       imported ghostty_vt). No platform-specific code.

CLI (src/cli.zig): NOT EDITED. parseRender already yields opts.selection (?SelectionCoords);
       render_help already lists `--selection X1,Y1,X2,Y2[,rect]` (contract §5 already satisfied).

MAIN (src/main.zig): NOT EDITED. S1 adds no new exit code plumbing; the u8 from run() still flows to
       process exit. (selection out-of-range / empty => exit 1, an existing code.) The test block
       already imports render.zig.

SCOPE: S1 edits render.zig ONLY. Does NOT touch the S3 `colors` line, renderToFileAtomic (S2),
       cli.zig, palette.zig, main.zig, ghostty_format.zig, build.zig. Does NOT create testdata/
       (P1.M4.T2 owns the golden harness). The public buildSelection is the reuse point for P3.M2.T2.S2.
```

## Validation Loop

> **Build-env caveat (read first):** On this machine (Zig 0.15.2 + GCC 16), bare `zig build`
> and bare `zig build test` FAIL TO LINK (`fatal: unhandled relocation R_X86_64_PC64 in
> crt1.o:.sframe`) — a toolchain artifact, not a code error. Use `-Doptimize=ReleaseFast` for
> both build and test (those link + run cleanly). Do not mistake the Debug link error for a
> regression.

### Level 1: Syntax & Type (compile + cross-compile gate)

```bash
zig build -Doptimize=ReleaseFast
# Expected: success -> zig-out/bin/tmux-2html. (The real compile+link gate in this env.)

# Cross-compile sanity (prove no platform-only API leaked in; point/Screen resolve on all targets):
zig build-obj src/render.zig -fno-emit-bin -target x86_64-macos 2>&1 | head
# Expected: no errors (EXIT 0). S1 adds no platform-specific code.
```

### Level 2: Unit Tests (selectionBodyEmpty + writeFileAtomic are PURE; renderGrid selection in the ONE terminal test)

```bash
zig build test -Doptimize=ReleaseFast
# Expected: all green — new selection assertions appended to the renderGrid test + the 2 new pure
# tests + S1's renderGrid test + S2's helper/atomic tests + S3's bridge test + all palette/cli/main
# tests. No leak under std.testing.allocator.
# NOTE: if the renderGrid test core-dumps, the ghostty-vt cross-test GOTCHA bit — ensure ALL
# Terminal-touching assertions are in the ONE `test "renderGrid: …"` fn (no 2nd terminal test).
```

### Level 3: Integration (the real CLI — deterministic, no tty needed)

```bash
BIN="zig-out/bin/tmux-2html"
test -x "$BIN" || { echo "build first"; exit 1; }

# (1) LINEWISE: 6 rows R0..R5, select rows 1..5  =>  R1..R5 present, R0 absent
printf 'R0\nR1\nR2\nR3\nR4\nR5' | "$BIN" render --cols 80 --selection 0,1,79,5 > /tmp/s1-lw.html
grep -q R1 /tmp/s1-lw.html && grep -q R5 /tmp/s1-lw.html && ! grep -q R0 /tmp/s1-lw.html && echo "linewise OK"

# (2) BLOCK: 3 rows of ABCDEFGHIJ, select cols 2..5 rows 0..2  =>  CDEF present, full row absent
printf 'ABCDEFGHIJ\nABCDEFGHIJ\nABCDEFGHIJ' | "$BIN" render --cols 10 --selection 2,0,5,2,1 > /tmp/s1-blk.html
grep -q CDEF /tmp/s1-blk.html && ! grep -q ABCDEFGHIJ /tmp/s1-blk.html && echo "block OK"

# (3) OUT OF RANGE: x=9 with --cols 5  =>  exit 1, stderr "selection out of range", NO stdout body
printf 'AB' | "$BIN" render --cols 5 --selection 9,0,9,0 > /tmp/s1-oor.out 2> /tmp/s1-oor.err; echo "exit=$?"
test ! -s /tmp/s1-oor.out && grep -q "selection out of range" /tmp/s1-oor.err && echo "out-of-range OK"

# (4) EMPTY: 3 rows AB/CD/EF with --cols 80, select blank cols 50..79  =>  exit 1, "selection is empty"
printf 'AB\nCD\nEF' | "$BIN" render --cols 80 --selection 50,0,79,2 > /tmp/s1-emp.out 2> /tmp/s1-emp.err; echo "exit=$?"
test ! -s /tmp/s1-emp.out && grep -q "selection is empty" /tmp/s1-emp.err && echo "empty OK"

# (5) --selection + --output (atomic file write)
printf 'R0\nR1\nR2' | "$BIN" render --cols 10 --selection 0,0,9,1 --output /tmp/s1-out.html
test -s /tmp/s1-out.html && grep -q R1 /tmp/s1-out.html && ! grep -q R2 /tmp/s1-out.html && echo "output OK"

# (6) reversed coords still work (formatter normalizes order): select rows 5..1 == rows 1..5
printf 'R0\nR1\nR2\nR3\nR4\nR5' | "$BIN" render --cols 80 --selection 0,5,79,1 > /tmp/s1-rev.html
grep -q R1 /tmp/s1-rev.html && grep -q R5 /tmp/s1-rev.html && ! grep -q R0 /tmp/s1-rev.html && echo "reversed OK"
```

### Level 4: Regression (don't break S1/S2/S3 / whole-grid path)

```bash
BIN="zig-out/bin/tmux-2html"
zig build test -Doptimize=ReleaseFast                                 # all tests green
"$BIN" render --help | grep -q -- '--selection X1,Y1,X2,Y2'           # help surface intact (unchanged)
# whole-grid path byte-identical to pre-S4 (no --selection):
printf '\033[31mred\033[0m' | "$BIN" render --cols 40 | grep -o '>red</span>'
printf 'x' | "$BIN" render --cols 40 --output /tmp/s1-reg.html && test -s /tmp/s1-reg.html   # S2 --output intact
# S3 palette path intact (resolve still called; --selection composes with --palette):
printf 'x' | "$BIN" render --cols 40 --palette default --selection 0,0,0,0 | grep -o 'background-color: #292c33'
# Expected: all pass. Whole-grid output is byte-identical to S3 (the non-selection run() path is unchanged).
```

## Final Validation Checklist

### Technical Validation
- [ ] `zig build -Doptimize=ReleaseFast` succeeds (links).
- [ ] `zig build-obj src/render.zig -fno-emit-bin -target x86_64-macos` succeeds (no new platform API).
- [ ] `zig build test -Doptimize=ReleaseFast` green (no leak under std.testing.allocator).

### Feature Validation
- [ ] Linewise sub-grid emits rows 1–5 only (Level 3 #1).
- [ ] Block sub-grid emits cols 2–5 only, every selected row (Level 3 #2).
- [ ] Out-of-range coord → `selection out of range`, exit 1, no output (Level 3 #3).
- [ ] Blank-cell selection → `selection is empty`, exit 1, no output (Level 3 #4).
- [ ] `--selection` composes with `--output` (Level 3 #5) and reversed coords (Level 3 #6).
- [ ] `--selection` composes with `--palette` (Level 4).

### Scope Discipline (RESPECT sibling tasks)
- [ ] Edited ONLY `src/render.zig`.
- [ ] Did NOT modify `cli.zig`, `main.zig`, `palette.zig`, `ghostty_format.zig`, `build.zig`.
- [ ] Did NOT touch the S3 `colors` line (`palette.resolve`) in `run()`.
- [ ] Did NOT modify `renderToFileAtomic` (S2 owns it; whole-grid file/open path unchanged).
- [ ] Did NOT create `testdata/` fixtures (P1.M4.T2 owns the golden harness).
- [ ] All Terminal-touching test assertions are in the ONE existing `test "renderGrid: …"` fn.

### Code Quality
- [ ] `buildSelection` is `pub` (the P3.M2.T2.S2 reuse point) and takes `*const Screen`.
- [ ] No `sel.deinit(...)` called (untracked + needs mutable `*Screen` — documented).
- [ ] x coords guarded against `> maxInt(u16)` before `@intCast` (no trap/UB).
- [ ] `.screen` tag used for `point.Point` (formatter-consistent; documented rationale).
- [ ] Empty-selection check uses body content (not `<span>` presence — plain text has no span).

---

## Anti-Patterns to Avoid

- ❌ Don't call `sel.deinit(...)` — `init` makes an UNTRACKED selection; `deinit` is a no-op for
  untracked bounds AND needs a mutable `*Screen` you don't have. (The contract pseudo-code said
  "VERIFY deinit signature" — VERIFIED: skip it.)
- ❌ Don't build `point.Point` with the wrong tag — use `.screen` (`point.Point{ .screen = .{.x,.y} }`),
  consistent with the formatter's own `order()`/`getTopLeft(.screen)`.
- ❌ Don't `@intCast` a u32 coord straight to the u16 `Coordinate.x` without guarding
  `> maxInt(u16)` — it traps in Debug/ReleaseSafe and is UB in ReleaseFast.
- ❌ Don't pass Pins by pointer to `Selection.init` — it takes `Pin` BY VALUE (verified).
- ❌ Don't try to build the `Selection` in `run()` — it has no `Screen`; build it inside `renderGrid`
  (which owns the `Terminal`) via `buildSelection`. That's why renderGrid's `sel` param became coords.
- ❌ Don't use "no `<span>`" as the empty-selection signal — plain unstyled text is emitted WITHOUT a
  span (S1's test proves it). Use the body content (empty/whitespace between `<pre …>` and `</pre>`).
- ❌ Don't add a SECOND test function that calls `renderGrid`/`Terminal.init` — ghostty-vt corrupts
  cross-test global state (core dump). APPEND to the existing `test "renderGrid: …"` fn.
- ❌ Don't modify `renderToFileAtomic` (S2) or the S3 `colors` line — S4 only INSERTS the selection
  branch + adds helpers; the whole-grid path must stay byte-identical.
- ❌ Don't edit `cli.zig` for `--selection` — parsing + help are done since P1.M1.T3.S2.

---

## Confidence Score: 9/10

Every ghostty-vt API call (`point.Point{ .screen = … }`, `screen.pages.pin`, `Selection.init` by-value
Pins, the formatter's `sel.topLeft/bottomRight/screen`-tag reading) is verified against the v1.3.1
source with line numbers. The renderGrid signature change is minimal and all existing `null` call sites
stay valid. The empty-selection detection is grounded in probed binary output (blank grid → zero-byte
body). The build-env caveat and the ghostty-vt cross-test GOTCHA are both documented with working
gates. The remaining 1/10 is ordinary integration friction: confirming `selectionBodyEmpty` flags the
specific blank-region fixture (cols 50–79 of short rows) exactly as expected — trivially verified by
Level 3 #4 — and that appending ~3 more `Terminal.init` calls to the one renderGrid test stays within
the GOTCHA's "same scope is fine" guarantee.
