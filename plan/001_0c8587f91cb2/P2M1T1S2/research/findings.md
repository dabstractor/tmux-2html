# P2.M1.T1.S2 — Research Notes

## Work item (contract)
Parse tmux `capture-pane` output into `Captured`; distinguish visible vs full;
apply the `@tmux-2html-history-limit` cap; set a `truncated` flag. The notice
itself is emitted by the **subcommand layer** (P2.M1.T2.S1), not capture.zig.

## KEY DESIGN DECISION: detect truncation with `#{history_size}`, NOT row counting

The contract phrase "if the captured row count hit the cap" cannot be implemented
literally. Row counting is fundamentally insufficient:

```
history_size = 100000, effective_cap = 50000  ->  tmux emits 50000 history lines  (TRUNCATED)
history_size =  50000, effective_cap = 50000  ->  tmux emits 50000 history lines  (NOT truncated)
```

Both produce an identical captured row count (50000 + visible_rows). Counting
newlines in the ANSI output CANNOT distinguish them. It would either under-report
truncation (miss the huge case) or over-report it (false "truncated" when the
scrollback merely equals the cap).

`#{history_size}` (live-verified below) is the EXACT, deterministic signal:
  truncated = (mode == full) and (history_size > effective_cap)

(history_size == effective_cap means everything fit -> NOT truncated, strict >.)

## Live-verified tmux facts (tmux 3.6b, server running)

```
$ tmux display-message -p "#{history_size}"
49                              # VALID format; scrollback line count for the pane

$ tmux display-message -p "#{pane_width} #{pane_height} #{history_size}"
201 77 49                       # 3-field single-call geometry+history parses cleanly

$ tmux display-message -p "#{@tmux-2html-history-limit}"
[empty]                         # UNSET user option -> empty string; caller must default to 50000
```

Man page (`man tmux`, capture-pane):
  -S/-E specify start/end line. 0 = first visible line; negative = history lines.
  '-' to -S = start of history; '-' to -E = end of the visible pane.
  "-S -<N> -E -" => most-recent N history lines + the full visible pane.
  Default (no -S/-E) => visible contents only.

So `-S -<effective_cap>` captures the LAST effective_cap history lines; anything
older (history_size - effective_cap lines) is dropped => truncated.

`#{@tmux-2html-history-limit}` returning empty when unset is why option resolution
MUST default to 50000. Per architecture/findings_and_corrections.md §3, tmux user
options are read via `tmux show-option -gqv @tmux-2html-*` in the PLUGIN SCRIPT.
=> capture.zig takes the RESOLVED `configured_limit` as a parameter; it does NOT
query the option itself (keeps capture.zig decoupled from option naming, and
avoids parsing an empty/unset token).

## PRD references (exact)
- §5.2: `--history N` with --full, cap scrollback to last N lines (default 50000).
        capture-pane -e -J -p -t <pane> [-S -N -E - | <none>].
- §9.2: `@tmux-2html-history-limit` default `50000` = "max scrollback lines captured".
- §13:  "Huge scrollback (history-limit can be 1,000,000): cap capture at
        @tmux-2html-history-limit (default 50k) with a status notice when truncated."
- §15:  Testing strategy EXPLICITLY lists "capture-line-range -> -S/-E derivation"
        as a required unit test. => the PURE effectiveHistory() + wasTruncated()
        helpers ARE the §15 deliverable.

## S1 contract (capture.zig as S1 builds it) — what S2 MODIFIES
- `pub const Mode = enum { visible, full }`                (keep)
- `pub const Size = struct { cols: u16, rows: u16 }`       (S2 -> rename/extend to Geometry + history_size)
- `pub const Captured = struct { ansi, cols, rows }`       (S2 -> add truncated: bool)
- `geometryCmd` format "#{pane_width} #{pane_height}"      (S2 -> add #{history_size}, 3 fields)
- `parseGeom` requires EXACTLY 2 fields, rejects 3         (S2 -> require EXACTLY 3, reject 2 and 4)
- `captureCmd(alloc, pane, mode, history)` 7/11-elem argv  (S2 -> UNCHANGED; capture() passes effective)
- `capture(b, alloc, pane, mode, history)`                 (S2 -> +configured_limit param; compute effective+truncated)
- `realRun` / `real()` Backend                             (S2 -> UNCHANGED)
- main.zig test{} block: S1 Task 6 adds `_ = @import("capture.zig")`
  => S2 adds NO main.zig line; S2's new tests live inside capture.zig and are
     already surfaced by S1's import.

## effective value semantics
effective = min(--history N, @tmux-2html-history-limit)
  - --history default 50000 (cli.PaneOpts.history: u32 = 50000, confirmed in src/cli.zig)
  - configured_limit default 50000 (PRD §9.2; resolved by subcommand layer)
  - both clamp; the -S flag receives the SMALLER (tighter cap wins).

## Consumer contract for the pane subcommand (P2.M1.T2.S1 — NOT built here)
cap = capture(capture.real(), alloc, pane, mode, opts.history, configured_limit);
  // configured_limit = resolved @tmux-2html-history-limit (default 50000)
renderGrid(alloc, cap.ansi, .{.cols=cap.cols,.rows=cap.rows}, colors, null, opts.font, &out);
defer alloc.free(cap.ansi);
if (cap.truncated) emit_notice(...);   // tmux display-message / stderr

## renderGrid consumer signature (confirmed src/render.zig:130)
pub fn renderGrid(alloc, ansi: []const u8, size: render.Size, ...) 
  render.Size = struct { cols: u16, rows: u16 }   (render.zig:28)
  => pane subcommand maps Geometry{cols,rows,history_size} -> render.Size{cols,rows}
     (history_size + truncated are NOT passed to renderGrid; truncated drives the notice only)

## Validation gate
- `zig build test --release=fast` is MANDATORY (build.zig Gotcha 1: Debug linker bug
  R_X86_64_PC64 with bundled C++ SIMD libs; ReleaseFast unaffected).
- std.testing.allocator catches every leak (argv elems, argv slice, fake dupes, Captured.ansi).

## Why no external/web subagent research
The one genuinely uncertain external question — "how to detect tmux truncation
deterministically" — was answered by LIVE tmux testing (`#{history_size}`), which
is more authoritative than web search for this installed-tool version (3.6b). The
man page + PRD + architecture docs fully specify the rest. Codebase patterns are
read directly (palette.zig = the structural template; cli.PaneOpts; render.renderGrid).
