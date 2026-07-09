# VERIFIED ghostty-vt cell/grid/style API for view.zig (P3.M1.T2.S1)

Every signature below was read directly from the shipped ghostty-vt 1.3.1 source
(`zig-pkg/ghostty-...-Cb/src/terminal/*.zig`). File:line cited. This is the PRIMARY
research — do not guess the API; cite this.

## 0. Module surface (`src/lib_vt.zig`)

`@import("ghostty-vt")` exports (lib_vt.zig:33-66):
- `point` (terminal/point.zig) — `point.Point`, `point.Coordinate`, `point.Tag`
- `color` (terminal/color.zig) — `color.RGB`, `color.Palette = [256]RGB`, `color.default`
- `page` (terminal/page.zig) — `page.Cell`, `page.Page`, `page.Row`
- `page.PageList` (terminal/PageList.zig) — `PageList`, `PageList.Pin`
- `Screen` (terminal/Screen.zig), `Terminal`, `Selection`, `Style` (terminal/style.zig)
- `Cell = page.Cell` is also re-exported at the top level (lib_vt.zig `pub const Cell = page.Cell`).

So in view.zig: `const ghostty_vt = @import("ghostty-vt"); const Screen = ghostty_vt.Screen; const Cell = ghostty_vt.page.Cell; const Style = ghostty_vt.Style; const point = ghostty_vt.point;`

## 1. point.Point / Coordinate / Tag (point.zig:30-90)

```zig
pub const Tag = enum { active, viewport, screen, history };
//   .screen = WHOLE grid (scrollback + active written area). top-left = oldest scrollback
//             row; bottom-right = last WRITTEN cell. THIS is the tag for the region TUI grid
//             (region browses all captured scrollback). point.zig:31-50.
pub const Coordinate = struct { x: size.CellCountInt = 0, y: u32 = 0 }; // x=u16, y=u32
pub const Point = union(Tag) { active, viewport, screen, history: Coordinate };
// Build a screen-tag point:  point.Point{ .screen = .{ .x = col, .y = row } }
```
`size.CellCountInt = u16` (size.zig:22). So `Coordinate.x` is u16; `Coordinate.y` is u32
(can exceed a single page — needed for scrollback across pages).

## 2. PageList — the grid container (terminal/PageList.zig)

`Screen` has field `pages: PageList` (Screen.zig:39). `PageList` is a linked list of `Page`s.
Relevant public members:

- `pub fn pin(self: *const PageList, pt: point.Point) ?Pin` (PageList.zig:3875)
  Converts a `point.Point` → `?Pin`. Returns `null` iff `pt.coord().x >= self.cols`
  OR the row is past the end (down() fails). Implementation: `getTopLeft(pt).down(y)` then
  `p.x = x`. **This is how view.zig maps a grid (gx, gy) to a cell.** One `pin()` per ROW
  at gx=0 is enough (then iterate the row's cells directly via getCells — a row never spans
  pages).
- `pub const Pin = struct { node: *PageNode, x: CellCountInt, y: CellCountInt, ... }`
  (PageList.zig:5042). `pin.node.data` is the `Page`; `pin.x`/`pin.y` are LOCAL column/row
  within that page. `pin.node.data.size.{cols,rows}` are that page's dimensions.
- `pub fn getTopLeft(self, tag) Pin` (PageList.zig:4908). `.screen` ⇒ first page's row 0.
- `pub fn getBottomRight(self, tag) ?Pin` (PageList.zig:4943). `.screen` ⇒ last page, last
  written row, last col. Never null for `.screen` (always ≥1 page).
- `pub fn pointFromPin(self, tag, p) ?point.Point` (PageList.zig:3980). Inverse of pin.
  O(pages) — traverses the list. Used ONCE per render to get the total grid row count.
- FIELDS: `PageList.cols` (column count — referenced in pin() at :3879) and `PageList.rows`
  (the ACTIVE-area row count, i.e. the terminal's `rows` — referenced in getTopLeft active
  at :4925). **`PageList.cols` IS the grid column count. `PageList.rows` is NOT total rows.**

### Total grid rows (screen tag) — compute ONCE per render
```zig
const br = grid.pages.getBottomRight(.screen).?;   // last written cell's Pin (never null)
const br_pt = grid.pages.pointFromPin(.screen, br).?; // Coordinate (never null for a screen pin)
const total_rows: u32 = br_pt.coord().y + 1;          // grid row count (screen tag)
const grid_cols: u16   = grid.pages.cols;             // column count
```
(`pointFromPin` is O(pages) but called once/render — fine. `totalRows()` exists at
PageList.zig:4970 but is `fn` not `pub fn`, so we can't call it. The br/pointFromPin path
is the public way.)

## 3. Page — row/cell access (terminal/page.zig)

`pin.node.data` is a `Page` (page.zig:84). PUBLIC fields: `memory: []align(...) u8`
(page.zig:98), `styles: StyleSet` (page.zig:138), `hyperlink_set`, `size.{cols,rows}`.
PUBLIC row/cell accessors (page.zig):

- `pub inline fn getRow(self: *const Page, y: usize) *Row` (page.zig:989) — y is the LOCAL
  row within the page (== `pin.y`).
- `pub inline fn getCells(self: *const Page, row: *Row) []Cell` (page.zig:995) — the full
  row's cells. Index by LOCAL column (== grid column gx, since columns are uniform).
- `pub inline fn getRowAndCell(self, x, y) struct{...}` (page.zig:1008) — single cell accessor.
- `pub inline fn lookupGrapheme(self, cell) ?[]u21` (page.zig:1546) — trailing codepoints for a
  grapheme cluster (only when `cell.content_tag == .codepoint_grapheme`).
- `pub inline fn lookupHyperlink(self, cell) ?hyperlink.Id` (page.zig:1232).

So to get the cell at grid (gx, gy):
```zig
const row_pin = grid.pages.pin(.{ .screen = .{ .x = 0, .y = gy } }) orelse null; // null = past end
if (row_pin) |rp| {
    const page = rp.node.data;
    const cells = page.getCells(page.getRow(rp.y)); // full row
    const cell = cells[gx];                          // LOCAL x == gx (columns uniform)
}
```
A row never spans pages, so one `pin()` per row + `getCells` gives the entire row. (pageIterator
/PageListFormatter exist for full-grid iteration but are overkill for a viewport paint.)

## 4. Cell (terminal/page.zig:1962) — `packed struct(u64)`

PUBLIC fields/methods (all used by `src/ghostty_format.zig` — the proven pattern):
- `content_tag: ContentTag` — enum: `codepoint, codepoint_grapheme, bg_color_palette,
  bg_color_rgb` (page.zig:2004).
- `content: packed union { codepoint: u21, color_palette: u8, color_rgb: RGB }` (page.zig:1968).
  Active tag set by `content_tag`.
- `style_id: StyleId` (u16-ish; `size.StyleCountInt`) (page.zig:1981). 0 == default style
  (no lookup needed).
- `wide: Wide` — enum `narrow, wide, spacer_tail, spacer_head` (page.zig:2026). RENDERING RULE:
  `.wide` cells hold a 2-col char (emit the char, terminal advances 2 cols); `.spacer_tail`/
  `.spacer_head` are the 2nd cell of a wide char — **SKIP them** (do not write anything, their
  column is consumed by the wide char). `.narrow` is a normal 1-col cell.
- `pub fn hasText(self) bool` (page.zig: ~2090) — true iff codepoint != 0 (false for bg-only).
- `pub fn hasStyling(self) bool` — true iff the cell has non-default style.
- `pub fn isEmpty(self) bool` (page.zig:2112).
- `pub fn codepoint(self) u21` (page.zig) — the primary codepoint.
- `pub fn hasTextAny(cells: []const Cell) bool` — any cell in the slice has text (STATIC/namespace
  call: `Cell.hasTextAny(slice)`).

## 5. Style (terminal/style.zig:20) — the SGR model (THE KEY for view.zig)

```zig
pub const Style = struct {
    fg_color: Color = .none,
    bg_color: Color = .none,
    underline_color: Color = .none,
    flags: Flags = .{},
    // Flags = packed struct(u16){ bold, italic, faint, blink, inverse, invisible,
    //   strikethrough, overline, underline: sgr.Attribute.Underline, _padding }  (style.zig:34)
    pub const Color = union(Tag){ none: void, palette: u8, rgb: color.RGB }; // style.zig:62
    pub fn default(self) bool ...   // style.zig — true iff eql(.{})
    pub fn eql(self, other) bool    // field-wise; works for run-length dedup
    pub fn formatterVt(self) VTFormatter  // style.zig — SGR emitter (see §6)
};
```
- `flags.inverse` is a PUBLIC bool field. So `var s = cell_style; s.flags.inverse = true;` compiles
  (Flags is a `const` private type name, but its FIELDS are public — field access works on a copy).
- `Style` is a plain struct (copy by value: `var s: Style = cell_style;`).

## 6. Style.formatterVt() — the READY-MADE SGR emitter (style.zig VTFormatter)

`style.formatterVt()` returns `Style.VTFormatter{ .style = &style }` with a settable field
`palette: ?*const color.Palette = null`. Print it with `{f}`:

```zig
var vt = style.formatterVt();
vt.palette = &colors.palette;          // resolve palette indices → RGB (pins colors to cache)
try out.print("{f}", .{vt});           // emits the SGR
```

VERIFIED output (style.zig unit tests, exact byte literals):
- Empty style ⇒ `"\x1b[0m"` (always resets FIRST — styles are self-contained).
- bold ⇒ `"\x1b[0m\x1b[1m"`; italic `\x1b[3m`; faint `\x1b[2m`; blink `\x1b[5m`;
  inverse `\x1b[7m`; invisible `\x1b[8m`; strikethrough `\x1b[9m`; overline `\x1b[53m`.
- underline: single `\x1b[4m`; double `\x1b[4:2m`; curly `\x1b[4:3m`; dotted `\x1b[4:4m`;
  dashed `\x1b[4:5m`.
- fg rgb (255,128,64) ⇒ `"\x1b[38;2;255;128;64m"`; bg rgb (32,64,96) ⇒ `"\x1b[48;2;32;64;96m"`;
  underline_color rgb ⇒ `\x1b[58;2;...m`.
- palette idx WITH palette set: idx 1 + color.default ⇒ `"\x1b[38;2;204;102;102m"` (RESOLVED to
  RGB). WITHOUT palette set: idx 42 ⇒ `"\x1b[38;5;42m"` (raw index — relies on terminal palette).

**CRITICAL for "colors match the cached palette":** set `vt.palette = &colors.palette` so
palette-indexed cell colors are emitted as explicit RGB pinned to the cached values (not
`\x1b[38;5;N` which would use the popup terminal's live palette). This guarantees the rendered
colors match the captured pane regardless of the popup terminal's current palette.
(style.zig VTFormatter.formatColor, style.zig:~ "palette => |idx| { if (self.palette) |p| { rgb =
p[idx]; emit 38;2;rgb } else emit 38;5;idx }".)

## 7. cellStyle — mirror ghostty_format.zig's cellStyle (src/ghostty_format.zig ~line 1240)

`src/ghostty_format.zig` already converts a Cell → Style (for HTML/VT output). Copy this logic
verbatim — it's the proven mapping:

```zig
fn cellStyle(page: *const Page, cell: *const Cell) Style {
    return switch (cell.content_tag) {
        inline .codepoint, .codepoint_grapheme => if (!cell.hasStyling()) .{} else
            page.styles.get(page.memory, cell.style_id).*,
        .bg_color_palette => .{ .bg_color = .{ .palette = cell.content.color_palette } },
        .bg_color_rgb     => .{ .bg_color = .{ .rgb = .{
            .r = cell.content.color_rgb.r, .g = cell.content.color_rgb.g, .b = cell.content.color_rgb.b } } },
    };
}
```
`page.styles.get(page.memory, style_id)` returns `*const Style` (RefCountedSet lookup —
ghostty_format.zig derefs with `.*`). For default cells (style_id 0 / !hasStyling) returns `{}`
(the default Style).

## 8. writer type — `*std.Io.Writer` (the NEW Zig 0.15 IO)

`Style.formatterVt().format` (and every ghostty-vt formatter) takes a `*std.Io.Writer`. So
view.zig's `render(out: *std.Io.Writer, ...)`. Bridge to a real tty in region.zig exactly as
render.zig does (`src/render.zig` run()):
```zig
var out_file = std.fs.File.stdout();
var sbuf: [4096]u8 = undefined;
var fw = out_file.writer(&sbuf);          // fs.File.Writer wrapper
defer fw.interface.flush() catch {};
view.render(&fw.interface, grid, colors, viewport, ...);  // &fw.interface IS *std.Io.Writer
```
TEST bridge (mirror style.zig / render.zig tests): `var aw = try std.Io.Writer.Allocating.init(alloc);
defer aw.deinit(); ... view.render(&aw.writer, ...); const got = aw.writer.buffered();`

## 9. The cross-test GOTCHA applies to view.zig

view.zig imports ghostty-vt and (in tests) constructs a `ghostty_vt.Terminal` to build a Screen
for render() to paint. **ghostty-vt's Terminal.init leaves process-global state corrupted such
that a Terminal.init in a SEPARATE test function crashes (core dump)** (src/render.zig GOTCHA;
verified). So:
- ALL `render(...)` integration assertions that build a Terminal MUST share ONE `test` fn.
- PURE helpers (viewport row math, selection/match containment, style-inverse) that do NOT touch
  Terminal.get separate `test` fns (like render.zig's determineCols/lineCount tests).

view.zig is NOT std-only (unlike app.zig) — it imports ghostty-vt — so the single-renderGrid-
scope constraint is the same as render.zig's.

## 10. Test reachability — main.zig test block must add view.zig

`src/main.zig` test block (main.zig:476-490) currently does `_ = @import("tui/app.zig");`.
view.zig is a NEW file and region.zig (its only caller) does NOT exist yet, so its tests are
UNREACHABLE until added. The implementer MUST add ONE line to the main.zig test block:
`_ = @import("tui/view.zig");` (next to the `tui/app.zig` import). No build.zig change (view.zig
is under src/ root module, reachable from both exe and test transitively once imported).

## 11. Mandatory ReleaseFast for tests

`zig build test` (Debug) hits a Zig linker bug (R_X86_64_PC64) with the bundled C++ SIMD libs.
Tests MUST run as `zig build test -Doptimize=ReleaseFast` (PRD §15; render.zig / app.zig
Gotcha). Every validation command uses ReleaseFast.

## 12. Confirmed-unnecessary APIs (do NOT use)

- `PageList.totalRows()` (PageList.zig:4970) is `fn` not `pub fn` — can't call. Use the
  br/pointFromPin path in §2.
- `PageListFormatter` / `pageIterator` (PageList.zig:4885) — full-grid iteration with Pin
  ranges; overkill for a viewport paint and doesn't do cursor addressing / viewport capping /
  selection-inverse. view.zig paints the viewport directly (pin-per-row + getCells).
- `Selection` (Pin-based) is NOT needed here — view.zig takes a simple row/col Selection struct
  (select.zig P3.M2.T2 builds it). The Pin-based `Selection` is only for renderGrid's HTML path.
