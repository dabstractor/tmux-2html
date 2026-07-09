# P1.M4.T1.S1 research — Coordinate → Pin → Selection + `--selection`

> Every claim below was VERIFIED by reading the ghostty v1.3.1 source in the Zig dep cache
> (`~/.cache/zig/p/ghostty-1.3.1-.../src/terminal/`) and by building/probing the current
> `tmux-2html` binary (`zig build -Doptimize=ReleaseFast`). Line numbers are from v1.3.1.

## §0 What S1 closes / the gap

`cli.zig` ALREADY parses `--selection X1,Y1,X2,Y2[,rect]` into `cli.SelectionCoords`
(struct `SelectionCoords{ x1,y1,x2,y2: u32; rect: bool }`, cli.zig:54-61; `parseSelection`
cli.zig:152-170; `RenderOpts.selection: ?SelectionCoords`, cli.zig:71; help already lists
`--selection`, cli.zig render_help). `renderGrid` ALREADY accepts `sel: ?Selection` and sets
`f.content = .{ .selection = sel }`. **The gap**: `run()` always passes `sel: null`, and a
`?Selection` can only be BUILT from `Pin`s, which require a loaded `Screen` — which only
exists INSIDE `renderGrid` (after `Terminal.init` + feeding ANSI). So S1's job is the
coordinate→Pin→Selection translation, wired where the screen actually exists.

## §1 The verified ghostty-vt API (all re-exported by the `ghostty-vt` module root, lib_vt.zig)

`lib_vt.zig` re-exports (verified): `point` (:25), `page` (:32), `PageList` (:48),
`Pin = PageList.Pin` (:50), `Screen` (:53), `Selection` (:55), `Terminal` (:59).
So from `render.zig`: `const point = ghostty_vt.point;`, `const Screen = ghostty_vt.Screen;`,
`const Pin = ghostty_vt.Pin;` (render.zig already has `const Selection = ghostty_vt.Selection;`).

### `point.Point` / `point.Coordinate` (terminal/point.zig:52-82)
```zig
pub const Point = union(Tag) {        // Tag = enum{ active, viewport, screen, history }
    active: Coordinate,
    viewport: Coordinate,
    screen: Coordinate,
    history: Coordinate,
    pub inline fn coord(self: Point) Coordinate { ... }   // returns the inner Coordinate
};
pub const Coordinate = struct {
    x: size.CellCountInt = 0,   // size.CellCountInt == u16  (terminal/size.zig:22)
    y: u32 = 0,
};
```
**Constructing a point from (x=col, y=row):** `point.Point{ .screen = .{ .x = <u16>, .y = <u32> } }`.
`.x` is `u16`; `.y` is `u32`. `cli.SelectionCoords` stores all four as `u32`, so `.x` needs
`@intCast` AFTER guarding against `> maxInt(u16)` (a raw `@intCast` of a u32 > 65535 traps in
Debug/ReleaseSafe and is UB in ReleaseFast).

### `PageList.pin` (terminal/PageList.zig:3875) — coordinate → Pin
```zig
pub fn pin(self: *const PageList, pt: point.Point) ?Pin {
    const x = pt.coord().x;
    if (x >= self.cols) return null;                 // x out of column range
    var p = self.getTopLeft(pt).down(pt.coord().y) orelse return null;  // y out of row range
    p.x = x;
    return p;
}
```
- Takes `point.Point` BY VALUE; the point's **Tag is used** by `getTopLeft(pt)`.
- Returns `null` when `x >= cols` OR `y` runs past the page list (`.down` returns null).
- `Pin` (PageList.zig:5042) is a small value struct (node + x + y) — passed/returned BY VALUE.

### `Selection.init` / `Selection.deinit` (terminal/Selection.zig:55-82)
```zig
pub fn init(start_pin: Pin, end_pin: Pin, rect: bool) Selection {   // Pins BY VALUE
    return .{ .bounds = .{ .untracked = .{ .start = start_pin, .end = end_pin } },
              .rectangle = rect };
}
pub fn deinit(self: Selection, s: *Screen) void {                   // takes MUTABLE *Screen
    switch (self.bounds) {
        .tracked => |v| { s.pages.untrackPin(v.start); s.pages.untrackPin(v.end); },
        .untracked => {},     // <<<< NO-OP for selections built by init()
    }
}
```
- `init` creates an **UNTRACKED** selection (no heap allocation, no tracking handles).
- `deinit` is a **NO-OP for untracked selections**. It also takes a **mutable `*Screen`**,
  which we do NOT have (`t.screens.active` is `*const Screen`). **CONCLUSION: do NOT call
  `sel.deinit(...)`** — it is unnecessary (untracked = nothing to free) and impossible without
  a mutable screen. The contract's pseudo-`defer sel.deinit(...)` is superseded by this finding
  (the contract itself said "VERIFY deinit signature" — VERIFIED: skip it).

### The formatter reads the selection via const methods (terminal/Selection.zig:151-228)
`ScreenFormatter.format` (src/ghostty_format.zig:567-569) sets:
`list_formatter.top_left = sel.topLeft(self.screen);` / `.bottom_right = sel.bottomRight(self.screen);`
`.rectangle = sel.rectangle;`. `topLeft`/`bottomRight`/`order` all take `*const Screen` and work
on UNTRACKED selections (they only read `self.start()`/`self.end()` pins + call
`s.pages.pointFromPin(.screen, …)`). `order()` normalizes start/end direction and uses the
`.screen` tag internally — so start/end may be supplied in ANY order; the formatter handles it.
**This makes `.screen` the correct tag** for our `pin()` calls (consistent with the formatter's
own coordinate reasoning; for a fresh terminal with `rows = line count` there is no scrollback,
so `.screen` top-left == grid row 0).

## §2 The refactor (WHERE the selection is built)

`run()` cannot build a `Selection` — it has no `Terminal`/`Screen`; `renderGrid` builds the
terminal internally. So the coordinate→Pin→Selection translation MUST happen inside
`renderGrid` (after feeding ANSI, when `t.screens.active` exists). Concretely:

- **`renderGrid` signature change**: `sel: ?Selection` → `sel: ?cli.SelectionCoords`
  (cli is already imported in render.zig). Inside, after the feed loop:
  ```zig
  var native: ?Selection = null;
  if (sel) |c| native = try buildSelection(t.screens.active, c);
  ...
  f.content = .{ .selection = native };
  ```
- **New `pub fn buildSelection(screen: *const Screen, coords: cli.SelectionCoords) error{OutOfRange}!Selection`**
  — the reusable coordinate→Selection builder. `renderGrid` calls it; the TUI (P3.M2.T2.S2)
  reuses it directly (contract point 4). Public + takes `*const Screen` (matches
  `t.screens.active` and the TUI's loaded screen).
- All existing `renderGrid(..., null, ...)` call sites (`renderToOwned`, `renderToFileAtomic`,
  `run`'s stdout arm) keep passing `null` — now typed `?cli.SelectionCoords`. **No change to
  those call sites' `null` arguments.**

## §3 Empty / zero-cell selection (PRD §13, contract point 3)

PRD §13: "Empty/zero-cell selection on confirm: warn, no file written, exit 1." Contract point
3 extends it to `render`. **VERIFIED output structure** (built the current binary, probed):

| input                       | rendered body (between `<pre ...>` and `</pre>`) |
|-----------------------------|--------------------------------------------------|
| empty / N blank lines       | **empty (zero bytes)** — `<pre ...></pre>`        |
| `AB\n<red>CD</red>\nEF`     | `AB\n<span …>CD</span>\nEF`                       |

So a selection of only blank/unwritten cells renders a **zero-byte body**. Detection is simple
and robust: **the rendered selection is "empty" iff the body between the opening tag's `>` and
`</pre>` is empty or all-whitespace.** (Plain unstyled text is emitted WITHOUT `<span>` —
confirmed by S1's test — so "no `<span>`" is NOT a valid emptiness signal; the body-length /
whitespace check is.) Implement as a small pure helper `selectionBodyEmpty(html) bool`.

Because the empty check must inspect rendered bytes, the `--selection` path renders to an
**`std.Io.Writer.Allocating` buffer** (not the streaming sink), validates non-empty, then routes
the buffer to the chosen sink. The non-selection path (sel == null) is UNCHANGED (streams to
stdout / `renderToFileAtomic`) — zero regression to S1/S2/S3. Routing the buffer to a file
needs a new `writeFileAtomic(alloc, path, bytes)` (same proven temp+rename idiom as
`renderToFileAtomic`, applied to pre-rendered bytes). `renderToFileAtomic` is NOT modified
(S2 owns it; it always renders the whole grid with `sel: null`).

## §4 Error model & exit codes

- `--selection` with a coord outside the grid (`x >= cols` or `y >= rows`) → `pin()` returns
  null → `buildSelection` returns `error.OutOfRange` → `renderGrid` propagates it → `run`
  prints `tmux-2html render: selection out of range\n` and returns **1**.
- A valid-coordinate selection of all-blank cells → renders OK but `selectionBodyEmpty` is true
  → `run` prints `tmux-2html render: selection is empty\n`, writes NO output, returns **1**.
- All other exit codes (0 success, 2 size error) and S3's palette behavior are UNCHANGED.

## §5 Scope boundaries (respect siblings)

- **cli.zig**: NOT edited (`--selection` parsing + help already complete since P1.M1.T3.S2).
- **palette.zig / main.zig / ghostty_format.zig / build.zig**: NOT edited.
- **S3 (P1.M3.T1.S3, in parallel)**: changes the ONE `colors` line in `run()` to
  `palette.resolve(...)`. S4 does NOT touch that line; S4 adds the selection branch and
  threads `opts.selection`. S4's edits are in DIFFERENT regions of `run()` (the output arms
  + a new early selection branch), so the two PRPs compose cleanly.
- **P1.M4.T2 (golden harness)**: owns `testdata/` fixtures. S4 uses INLINE `printf` fixtures
  in its integration tests; it does NOT create testdata files.

## §6 Build-env caveat (same as S3)

Bare `zig build` / `zig build test` FAIL TO LINK under this machine's GCC 16
(`fatal: unhandled relocation R_X86_64_PC64 in crt1.o:.sframe`) — toolchain artifact, not a
code error. Use `-Doptimize=ReleaseFast` for BOTH build and test.

## §7 ghostty-vt test GOTCHA (from S1, still applies)

`Terminal.init` corrupts process-global state such that a `Terminal.init` in a SEPARATE test
function core-dumps. Sequential `renderGrid` calls in the SAME test scope are fine. Therefore
ALL renderGrid-with-a-terminal assertions (selection included) MUST live in the ONE existing
`test "renderGrid: …"` function — APPEND to it, do not add a second terminal-touching test.
`selectionBodyEmpty` and `writeFileAtomic` are PURE (no Terminal) → they get their OWN separate
test functions.
