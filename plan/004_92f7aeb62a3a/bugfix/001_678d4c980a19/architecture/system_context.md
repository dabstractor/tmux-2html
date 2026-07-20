# System Context — Bug Fix Release

## Project: tmux-2html
A Zig CLI tool that captures tmux pane content (or reads stdin) and produces
a faithful HTML rendering with full ANSI color, Unicode, and style fidelity.
Three main subcommands: `render` (stdin→HTML), `pane` (tmux capture→HTML),
`region` (interactive TUI selection→HTML).

## Build System
- **Language:** Zig 0.15.2 (single executable, `link_libc = false`)
- **Dependencies:** `parg` (eager, CLI parsing), `ghostty` (lazy, terminal emulation via `ghostty-vt`)
- **Build:** `zig build --release=fast` (ReleaseFast mandatory — Debug hits linker bug with C++ SIMD libs)
- **Tests:** `zig build test --release=fast` — single test target reusing `exe.root_module`; all `test` blocks reachable from `src/main.zig`'s top-level `test {}` import block (~275 tests green)
- **Shell tests:** `tests/envelope_smoke.sh` (§8.1 end-to-end with real binary + isolated tmux + python3 pty), `tests/plugin_options.sh` (mocked tmux, plugin option threading)

## Key Architecture Patterns

### Error/Exit Code Convention
- Exit 0: success
- Exit 1: usage/runtime error (parse errors, write failures, empty selection per PRD §13)
- Exit 2: capture/target error (tmux unavailable, bad target, size detection failure)

### Subcommand Structure
Each subcommand splits logic into:
- **Testable core** (`panePrepare`, `regionPrepare`, etc.): no stdout I/O, returns result struct
- **Prod wrapper** (`paneBody`, `region.body`, `render.run`): resolves paths, does I/O

### Cross-Test GOTCHA
Modules touching `ghostty_vt.Terminal` (`render.zig`, `tui/view.zig`) must have
all Terminal-building assertions in ONE test fn. Separate pure-logic test fns
that don't touch Terminal are safe.

### Testing Mockability Seam
`capture.Runner = { ctx, runFn }` — unit tests inject fake test doubles (`FakeTmux`,
`PaneFake`, `RegionFake`); prod passes `capture.real`.

## Files Involved in Bug Fixes

| File | Role | Issues |
|------|------|--------|
| `src/render.zig` | render subcommand, sizing, HTML generation | 1 (pub helper), 2 (zero-dim guard) |
| `src/region.zig` | region TUI orchestrator, confirm action | 1 (empty guard), 2 (Terminal.init guard) |
| `src/main.zig` | entrypoint, dispatch, pane handler | 2 (existing pane guard to mirror) |
| `src/cli.zig` | CLI flag parsing (parseU16 accepts 0) | 2 (parser accepts 0, fix must be at sizing layer) |
| `tests/envelope_smoke.sh` | integration test harness | 1 (add blank-cell confirm test) |
| `scripts/check-safety.sh` | static safety guard | 4 (WARN noise in plan/) |