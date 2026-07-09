# External research — P1.M2.T2.S1 (sync-palette)

Source: researcher subagent (knowledge-based; URLs are canonical but were NOT live-fetched
this run — no web_search tool). Facts cross-checked against the PRD/codebase contracts; only
design-validating conclusions retained.

## Design validation

### Exit codes — our 0/1/2 scheme is sound
- 0 success / 1 usage-runtime / 2 capture-target is internally consistent (PRD §5).
- Caveat: shell `getopt` convention reserves `2` for *usage* errors; since we assign usage→1
  and capture/target→2, the two are distinct inside tmux-2html, but **document the mapping
  in `--help`** (already done: "Exit codes: 0 success, 1 usage/runtime error." — extend to
  mention 2 for sync-palette). No `sysexits` (64/66/69) adoption needed for v1.
- "No controlling tty / terminal unresponsive" → **exit 2** (capture target unavailable): defensible.
- `--from file` not-found/malformed → **exit 1** (runtime/usage; matches user expectation for
  file-not-found). [Our choice; researcher noted users often expect 1 here.]

### Partial response (count < 256) — warn + backfill is conventional; we already backfill
- Partial palettes are NORMAL (many terminals answer 0–15 but return defaults/silence for the
  216-cube + grayscale). No major tool (pywal, termenv, Gogh, base16) fails hard on partial.
- **Our design already does the right thing**: `palette.parse`/`queryColors` SEED from
  `defaultColors()` (the bundled xterm/Ghostty 256 table), so missing indices are backfilled
  with sane defaults. count<256 → `std.log.warn` (already in queryColors) + WRITE cache + exit 0.
  queryColors ERROR (no /dev/tty / termios fail / unreachable) → exit 2. This matches the
  "warn-and-backfill; hard-fail only on total failure" recommendation. ✓
- No `--strict` flag needed for v1 (out of scope; the contract doesn't ask for it).

### /dev/tty detection — queryColors' ERROR is the correct signal (do NOT use isatty(stdin))
- Correct "can I query?" test = `open("/dev/tty", O_RDWR)` → fails `ENXIO`/`ENODEV` with no
  controlling tty (tmux run-shell, cron, daemons). `isatty(stdin)` is the WRONG test: it
  conflates "stdin is a tty" with "I have a controlling terminal" and wrongly fails for
  piped-but-interactive invocations.
- **Our design**: `queryColors` already opens `/dev/tty` read_write (S1) and ERRORS on no-tty.
  sync-palette catches that error → exit 2. We do NOT need `palette.hasControllingTty()` (S3)
  for this — queryColors' error IS the signal. This DECOUPLES T2.S1 from S3. ✓

### Docs caveat wording (in-tmux vs outer-terminal) — verbatim-ish to use
> "Run `tmux-2html sync-palette` from **inside** the tmux session whose captures you're
> generating. It queries the palette exactly as tmux presents it to panes — which is the
> palette your captures are rendered against, so it produces the closest color match. If you
> run it **outside** tmux (directly in your terminal emulator), you capture the emulator's own
> palette instead; the two can differ when tmux applies `terminal-overrides`, a custom
> `default-terminal`, or RGB features. When in doubt, run it inside tmux."
- Basis: a pane's /dev/tty is the pty tmux allocated; tmux answers OSC 4/10/11 ITSELF from its
  own palette table (does not forward to the outer emulator by default). `allow-passthrough`
  (tmux ≥3.3) is not a reliable palette-query path.

### `--from file` precedent
- pywal cache-consumer model (`~/.cache/wal/colors` plain hex-per-line) is the strongest
  precedent for "load a palette from a text file into a cache". Headless seeding (capture on an
  interactive box, `--from file` on a headless/CI box) is a legitimate, common need and the
  natural fallback when no controlling tty exists.
- Our format is the PRD §6 plain-text format (`fg`/`bg`/`N R G B`), not Xresources — kept
  consistent with the cache format so the same `parse` decodes both.

## Key URLs (canonical; unverified-this-run)
- XTerm ctlseqs (OSC 4/10/11 grammar, rgb: scaling): https://invisible-island.net/xterm/ctlseqs/ctlseqs.html
- Linux `open(2)` (ENXIO for /dev/tty, no controlling tty): https://man7.org/linux/man-pages/man2/open.2.html
- Linux `console_codes(4)` (console ignores OSC 4 query): https://man7.org/linux/man-pages/man4/console_codes.4.html
- tmux man page (OSC handling, run-shell lacks ctty): https://man.openbsd.org/tmux
