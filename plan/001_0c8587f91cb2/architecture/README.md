# Architecture Documentation Index

Authoritative research findings (VERIFIED by reading actual source, 2026-07-08).
The four `research_*.md` files were written offline by subagents and are SUPERSEDED
by the docs below — read these in order:

1. **`findings_and_corrections.md`** — START HERE. Where the PRD differs from reality.
   - Critical: import is `ghostty-vt` (hyphen); `Selection` is Pin-based (not x/y tuples);
     `font` is term2html's custom Options field; vendor a modified `ghostty_format.zig`.
2. **`external_deps.md`** — exact `build.zig.zon` deps (ghostty v1.3.1 hash, parg hash),
   `build.zig` wiring, GHA release matrix, parg CLI API.
3. **`render_pipeline.md`** — the verified render pipeline + the coordinate→Pin→Selection
   recipe (`screen.pages.pin(point.Point) ?Pin`, `Selection.init(start,end,rect)`).
4. **`system_context.md`** — module boundaries & explicit handoffs (capture/palette/render/tui).
5. **`tui_region.md`** — verified std-lib termios/mouse/alt-screen primitives for the TUI.

Key verified facts for implementers:
- `@import("ghostty-vt")` exports: `Terminal`, `Screen`, `color`, `page.{Page,PageList,Row,Cell}`,
  `point.{Point,Coordinate}`, `Selection`, `Style`, `Parser`, `osc.Command`.
- `Terminal.init(alloc, .{.cols,.rows})`; `t.vtStream()`; `stream.next(byte)`; feed `\n`→`\r\n`.
- `t.screens.active` is the `*const Screen` to format.
- `ScreenFormatter.init(screen, opts)`; `opts.font` is term2html's field; `.content = .{.selection = null}`
  for whole grid; `print("{f}", .{formatter})`.
- `PageList.pin(pt: point.Point) ?Pin` (PageList.zig:4145); `pointFromPin(tag, pin)` (4250).
- `Selection.init(start_pin, end_pin, rect)`; field `.rectangle`.
- term2html `.minimum_zig_version = "0.15.2"` (CONFIRMS Zig 0.15.2 target).
