# External Dependencies & Constraints

## ghostty-vt (Terminal Emulator)
- **Source:** lazy dependency via `build.zig.zon` → `ghostty` package, module `"ghostty-vt"`
- **Critical constraint:** `Terminal.init` SEGFAULTS on zero dimensions (`cols=0` or `rows=0`).
  Documented in `src/main.zig:504`. This is the root cause of Issue 2.
- **Build constraint:** ReleaseFast mode required. Debug mode hits a linker bug
  (`R_X86_64_PC64`) with bundled C++ SIMD libraries.

## parg (CLI Parser)
- **Source:** eager dependency via `build.zig.zon` → `parg` package
- **Relevance:** `parseU16` (cli.zig:128) uses `std.fmt.parseInt(u16, s, 10)` which
  accepts `0`. The parser layer will never reject `--cols 0` — the guard must be at
  the sizing layer.

## tmux
- **Integration:** External binary (`tmux`) invoked via `capture.Runner` seam.
- **Safety:** PRD §0 mandates isolated, uniquely-named sockets (`-L <name>`), never
  touching the user's live tmux server. All tests in this fix must follow AGENTS.md rules.
- **Geometry source:** `tmux display-message -p "#{pane_width} #{pane_height} #{history_size}"`
  provides cols/rows for `pane` and `region` paths.

## python3
- **Test dependency:** Used in `tests/envelope_smoke.sh` for pty-based region TUI driving.
- All pty-based tests must SKIP cleanly if `python3` is absent (existing pattern).

## No New Dependencies Required
All fixes reuse existing code patterns, error types, and infrastructure.