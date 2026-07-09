# P2.M1.T2.S1 — Research Notes (pane subcommand)

## THE BLOCKING DEPENDENCY: `src/capture.zig` does not exist

**Verified:** `ls src/capture.zig` → No such file. `src/main.zig`'s test block imports only
palette/render/golden_test — no capture import. Yet `plan/.../tasks.json` marks P2.M1.T1.S1
("Pane geometry + capture-pane command builder") **Complete**.

This is the SAME pipeline-state corruption that halted sibling **P2.M1.T1.S2** (see
`../P2M1T1S2/issue_feedback.md`): S1's deliverable never landed, so S2 (a MODIFY/delta on
S1's end-state) could not run. T2.S1 consumes the `Captured` type from S2, so it is
transitively blocked too.

**Resolution chosen (one-pass success over scope purity):** This PRP is a **self-contained
CREATE**. It builds `src/capture.zig` implementing the FULL final contract (post-S1+post-S2,
per the authoritative S1 PRP + S1/S2 research findings already in the repo) AND wires the
`pane` subcommand. This is exactly option (2) the S2 issue feedback names: "regenerate
downstream PRPs as self-contained CREATE (not MODIFY) specs." If the orchestrator later
re-runs S1/S2, they will find capture.zig present and should be treated as already-satisfied.

The capture.zig contract is taken **verbatim** from:
- `../P2M1T1S1/PRP.md` (authoritative naming/design: Size, Mode, Captured, Runner, Cmd, real,
  geometry, captureCmd, capture, FakeTmux) — and
- `../P2M1T1S1/research/findings.md` (verified Zig 0.15.2 `Child.run` stdout capture +
  mockable `Runner` vtable seam + tmux 3.6b argv).
- `../P2M1T1S2/research/findings.md` (the S2 delta: Geometry adds `history_size`, Captured
  adds `truncated`, geometry format becomes 3-field, `effectiveHistory`/`wasTruncated` are
  pure, `configured_limit` param). Applied directly so capture.zig is born in its final shape.

So no fresh capture-design research was needed — it is already done and live-verified in the
repo. The genuinely NEW T2.S1 logic (collision-safe filename, output-dir option resolution,
palette wiring, render delegation, truncation notice, open) is specified in the PRP.

## Consumed API surfaces (exact, with line numbers)

- `render.renderGrid(alloc, ansi, size: render.Size, colors, sel: ?cli.SelectionCoords,
  font: ?[]const u8, out: *std.Io.Writer)` — render.zig:130. The single render primitive.
- `render.renderToFileAtomic(alloc, path, ansi, size: render.Size, colors, font: ?[]const u8)`
  — render.zig:214. Atomic temp+rename write of a WHOLE-grid render (sel:null). REUSE THIS.
- `render.spawnXdgOpen(path, alloc)` — render.zig (best-effort, reaps the child).
- `render.Size = struct { cols: u16, rows: u16 }` — render.zig:28.
- `palette.resolve(alloc, mode: palette.Mode, has_tty: bool) Colors` — palette.zig:545
  (INFALLIBLE; returns Colors, not !Colors).
- `palette.hasControllingTty() bool` — palette.zig:491 (false under run-shell).
- `palette.Mode = enum { default, cached, live }` — palette.zig:463.
- `palette.cacheBase()` — palette.zig:361: the XDG resolution pattern to MIRROR for the
  output dir (XDG honored only if set, non-empty, AND absolute; else $HOME fallback).
- `cli.PaneOpts { target, visible, full, history:u32=50000, font, output, open }` — cli.zig:70.
- `cli.parsePane(args)` — cli.zig:184 (PURE; already wired, returns NotImplemented).
- `main.syncPaletteDir` / `main.syncPaletteBody` — main.zig:162 / main.zig:223: the DIR-SCOPED
  testable core + prod wrapper pattern to MIRROR for pane (body fn pointer threaded through
  `cli.pane(alloc, args, body)`, exactly like `cli.syncPalette(alloc, args, body)`).

## Key design decisions

1. **Output dir + history-limit are resolved by the subcommand layer** via
   `tmux show-option -gqv @tmux-2html-*` (reusing capture's `Runner` seam so it is
   FakeTmux-testable). Rationale: PRD §9.2/§9.3 + `findings_and_corrections.md §3` say options
   are read via show-option; S2's findings name the subcommand as the resolver of
   `configured_limit`. Defaults: output-dir `${XDG_DATA_HOME:-~/.local/share}/tmux-2html`,
   history-limit 50000. Empty/unset or tmux-unavailable → default.
2. **Filename collision avoidance:** `<session>-<unixtime>-<pid>.html`. session from
   `tmux display-message -p -t <pane> '#{session_name}'` (sanitized for filesystem safety;
   fallback "pane"). unixtime = `std.time.timestamp()` (i64 secs). pid = `std.os.linux.getpid()`.
   unixtime+pid alone guarantee uniqueness; session is a human hint.
3. **`--output FILE` overrides** the dir+auto-name (writes exactly there, no session/ts/pid).
4. **Palette:** `palette.resolve(alloc, .cached, palette.hasControllingTty())`. There is no
   `--palette` flag on pane; `.cached` is fixed. Under run-shell hasControllingTty()==false so
   live is skipped → cached→default (matches the contract "has_tty=false so live is skipped").
5. **Truncation notice (PRD §13):** `capture` sets `Captured.truncated`; the subcommand emits
   the notice (stderr always + best-effort `tmux display-message` via runner).
6. **Testability:** capture.zig never touches ghostty-vt `Terminal.init` → its tests are
   SEPARATE test fns (no cross-test GOTCHA). The pure helpers (effectiveHistory, wasTruncated,
   sanitizeFilename, buildOutputFilename, buildOutputPath) are unit-tested directly. The
   option/session queries go through the `Runner` seam → FakeTmux-testable. render is NOT
   re-tested in the pane path (already proven in render.zig); end-to-end is a Level-3 test.

## Zig 0.15.2 specifics (verified against bundled stdlib)

- `std.os.linux.getpid() pid_t` — os/linux.zig:1841 (Linux-only; the build targets Linux).
- `std.time.timestamp() i64` — time.zig:16 (Unix seconds, wall clock). Already used by
  palette.zig's `formatIso8601`.
- `std.ArrayList(T) = .empty` (unmanaged; alloc on appendSlice/toOwnedSlice/deinit) — the
  idiom palette.zig uses.
- `std.process.Child.run(.{ .allocator, .argv, .max_output_bytes })` reaps internally; env_map
  UNSET → inherits `$TMUX`/`$TMUX_PANE`; default max_output 50 KiB MUST be overridden (1<<28).
- Build: `zig build test` REQUIRES `-Doptimize=ReleaseFast` (Debug linker bug with bundled
  C++ SIMD libs; see build.zig). capture.zig does NOT hit the ghostty-vt Terminal.init
  cross-test GOTCHA, but the rest of the suite does → keep ReleaseFast.

## Confidence: HIGH
The capture subsystem design is fully specified + live-verified in the repo (no guessing).
The new pane logic reduces to: reuse capture (FakeTmux-tested) + reuse render.renderToFileAtomic
(proven) + pure filename/dir helpers (unit-tested) + option queries through the existing seam.
