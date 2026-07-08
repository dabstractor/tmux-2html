# Copy-Mode TUI (`tmux-2html region`) — implementation notes (VERIFIED std-lib)

> The TUI is the ONE component NOT absorbed from term2html (term2html has no TUI). It must be
> written from scratch in Zig using the std library only. This doc gives verified std-lib
> primitives so downstream agents don't reinvent them. Grounded in term2html's
> `terminal.zig` termios usage (VERIFIED working code).

## 1. Hosting & terminal control

- **Launched via** `tmux display-popup -E -w 100% -h 100% "$BIN region --target <pane> …"`
  (PRD §9.3). The popup provides a REAL pty → `/dev/tty` exists → OSC + termios work.
  `-E` closes the popup when `region` exits. So the binary reads/writes ITS OWN
  stdin/stdout/tty directly (no tmux message channel inside the popup — hence the
  `.last-output` sidecar for the wrapper to `display-message`).
- **Alt screen + raw termios (VERIFIED pattern from term2html terminal.zig):**
  ```zig
  const std = @import("std");
  // Enter alt screen, hide cursor:
  stdout.writeAll("\x1b[?1049h\x1b[?25l") catch {};
  defer stdout.writeAll("\x1b[?25l->\x1b[?1049l") catch {}; // restore (always, incl. panic)

  const fd = std.posix.STDIN_FILENO;  // or open /dev/tty
  const original = try std.posix.tcgetattr(fd);
  var raw = original;
  raw.lflag.ICANON = false;   raw.lflag.ECHO = false;
  raw.iflag.IXON = false;     raw.iflag.ICRNL = false;
  raw.iflag.BRKINT = false;
  raw.oflag.OPOST = false;
  raw.cflag.CSIZE = .CS8;
  raw.cc[@intFromEnum(std.posix.system.V.MIN)] = 1;   // blocking, byte at a time
  raw.cc[@intFromEnum(std.posix.system.V.TIME)] = 0;
  try std.posix.tcsetattr(fd, .FLUSH, raw);
  defer std.posix.tcsetattr(fd, .FLUSH, original) catch {};
  ```
  `std.posix.tcgetattr` / `std.posix.tcsetattr(.., .FLUSH, ..)` are the VERIFIED Zig 0.15
  API (term2html uses them). `termios.lflag.ICANON`, `.ECHO`, etc. are bitfields.
  `std.posix.system.V.MIN`/`.TIME` index `cc[]`. **Restore in a `defer` AND register a
  panic/signal handler** so the terminal is never left raw (PRD §7.1 "Restore on exit,
  always, including panic").

## 2. Mouse (SGR mouse mode, PRD §7.6)

- Enable on enter: `stdout.writeAll("\x1b[?1000h\x1b[?1002h\x1b[?1006h")` (1000=normal,
  1002=button-event/motion, 1006=SGR pixel-ish coords). Disable on exit (defer).
- SGR mouse events arrive as `\x1b[<{b};{x};{y}M` (press/move) or `m` (release). Parse the
  three ints. Button `b`: 0=left, 1=middle, 2=right, +modifier bits (Alt=8/16...); motion is
  `b` with bit 32 (`b&32`). Drag = left-hold + motion → extend selection. Alt modifier →
  block selection (PRD §7.6).
- Wheel: `b==64` (up) / `b==65` (down) → scroll.

## 3. Key decoding (input.zig)

- Read bytes from stdin (raw). Decoding order: ESC-prefixed sequences first.
  - `\x1b` alone / within timeout → pure Esc.
  - `\x1b[<` → SGR mouse (see §2).
  - `\x1b[A/B/C/D` → ↑↓→←; `\x1b[1;5D` → Ctrl-←; `\x1b[H/F` → Home/End; `\x1b[5/6~` → PgUp/Dn.
  - Letters a–z (with optional count prefix like `5j`): vim motion set (PRD §7.2).
  - `v`, `V`, `\x12` (Ctrl-v) / `R`, `o`/`O`, `Esc`, `q`, `Enter`/`y`, `/`, `?`, `n`/`N`, `g`/`G`,
    `w b e 0 ^ $ H M L { } %`, `Ctrl-d/u/f/b`.
- **Counts:** parse leading digits before a motion (e.g. `5j` → move down 5).

## 4. Selection model (select.zig) — own coordinates

- Maintain: `cursor: {x,y}` (cell in grid), `anchor: ?{x,y}`, `mode: Linewise|Block|None`.
- `v` → if no selection: begin Linewise, anchor=cursor. If active: toggle Linewise↔Block.
  `V`→Linewise; `Ctrl-v`/`R`→Block. `o`/`O`→swap cursor/anchor. `Esc`→clear (stay in TUI).
- The visible selection is rendered by overlay (view.zig highlights selected cells /
  inverts SGR on the active range). For the ACTUAL HTML output, convert to a ghostty
  `Selection` (render_pipeline.md §4): linewise → pin(0,r1)..pin(cols-1,r2), rect=false;
  block → pin(c1,r1)..pin(c2,r2), rect=true. Selection bounds normalize regardless of
  anchor/cursor order (ghostty handles any order; but round coordinates & clamp to grid).
- **Wide-cell rounding:** selection start/end must snap to cell boundaries (a wide cell is
  selected atomically). ghostty handles this at format time; just feed valid cell coords.

## 5. View rendering (view.zig)

- Diff-render the grid: re-emit only changed rows using cursor addressing (`\x1b[<row>;<col>H`)
  + SGR from the captured cells (mapped through the palette for display). Cap rendered rows to
  viewport; scroll with cursor (PRD §7.1). For a v1 MVP, a full re-render per keystroke may
  suffice for ≤50k rows; optimize later.
- **Status line** (last row, PRD §7.1):
  `[LINE|BLOCK]  row:N col:M  /pattern  N match(es)  <S-sel>Enter=render q=quit`.
- Highlight search matches (reverse video on matched cells). Highlight active selection
  (reverse/invert over the selected range).

## 6. Search (PRD §7.3)

- `/pattern` forward, `?pattern` backward from cursor; `n`/`N` next/prev.
- v1: fixed-string OR regex (configurable via an option, default regex). Find matches by
  scanning decoded cell text per row (strip SGR). Store match list; movement wraps around.

## 7. Confirm / cancel / sidecar (PRD §7.5)

- `Enter`/`y` → if selection empty: warn, no file, exit 1. Else: render selection → HTML to
  `--output` (or output-dir/session-timestamp-pid filename), `--open` if set, write the path
  to `$TMUX_2HTML_BIN/.last-output` (or a documented sidecar path the plugin wrapper reads),
  exit 0.
- `q` / `Esc`(no selection) / `Ctrl-c` → exit 1, no output.
- Output filename collision avoidance: include `#{session_name}` + timestamp + pid (PRD §13).

## 8. Open implementation detail

- `region` reads the FULL scrollback into the grid FIRST (capture.zig full mode), so the TUI
  browses all history. Grid rows = captured rows (scrollback + visible). Cursor/movement
  operate over this full grid.
- The TUI never needs tmux after capture — it works purely on the in-memory grid + the pty
  stdin/stdout. This is why display-popup (real pty) is the correct host.
