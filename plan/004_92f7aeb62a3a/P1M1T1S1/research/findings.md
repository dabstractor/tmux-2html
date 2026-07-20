# Research Findings — P1.M1.T1.S1 (pane-anchored region popup binding)

> Every shell-quoting claim below was verified empirically against real `/bin/sh`
> (dash) on 2026-07-19, and every baseline gate was run green. Three-layer
> quoting is too fiddly to reason about abstractly — the target line and the new
> sed were PROVEN to work.

## 1. The ONE change (tmux-2html.tmux line 214)

A single token swap inside the C-o region binding's `run-shell "…"` string:

- OLD token: `display-popup -E -w 100% -h 100%`
- NEW token: `display-popup -B -E -w '#{pane_width}' -h '#{pane_height}' -x P -y P -t '#{pane_id}'`

EVERYTHING ELSE on line 214 is preserved verbatim: the `last="$TMUX_2HTML_BIN/.last-output"; rm -f "\$last"; …` wrapper, the escaped-double-quote wrapping of the inner popup command (`\"$TMUX_2HTML_BIN/tmux-2html region $title_arg $lang_arg --target '#{pane_id}'\"`), and the `if [ -f "\$last" ]; then …; fi` tail.

Full NEW line 214 (exact):
```
    "last=\"$TMUX_2HTML_BIN/.last-output\"; rm -f \"\$last\"; tmux display-popup -B -E -w '#{pane_width}' -h '#{pane_height}' -x P -y P -t '#{pane_id}' \"$TMUX_2HTML_BIN/tmux-2html region $title_arg $lang_arg --target '#{pane_id}'\"; if [ -f \"\$last\" ]; then out=\$(cat \"\$last\"); tmux display-message \"tmux-2html: wrote \$out\"; fi"
```

## 2. CRITICAL three-layer quoting (verified — see §5)

`#{pane_width}`, `#{pane_height}`, and BOTH `#{pane_id}` occurrences (the new `-t`
one AND the existing `--target` one) are **tmux format variables** that run-shell
expands at FIRE time, so they MUST be in **SINGLE QUOTES** inside the inner
command — exactly as `#{pane_id}` already is today. If unquoted, the `#` starts a
shell comment at `/bin/sh` parse time and breaks the line. `-x P`/`-y P` are
literal tokens (no `$`/`{}`) and need no quoting. `$TMUX_2HTML_BIN`,
`$title_arg`, `$lang_arg` stay expanded-now (baked at source time). `\"`, `\$`,
`\$(…)` stay escaped (deferred to fire time).

## 3. The test fix (tests/plugin_options.sh line 97)

The c.3 REGION sed hardcodes the OLD `-E -w 100% -h 100%` prefix, so it will NOT
match the new pane-anchored prefix → `rinner` becomes garbage and the
`/bin/sh -n` assertion is meaningless.

- OLD (line 97): `rinner=$(printf '%s' "$rline" | sed 's/.*display-popup -E -w 100% -h 100% "//; s/"; if.*//')`
- NEW (line 97): `rinner=$(printf '%s' "$rline" | sed 's/.*display-popup [^"]*"//; s/"; if.*//')`

`[^"]*` consumes any flags containing no `"`, then the first `"` opens the inner
command. Matches BOTH old and new prefixes. The trailing `s/"; if.*//` is
unchanged. The assertion intent (apostrophe-escaped inner region command parses
under `/bin/sh -n`) is unchanged.

## 4. The comment block + CONFIGURATION.md rewrites

- **tmux-2html.tmux lines 190–192** (comment opener): currently says "opens a
  full-screen tmux display-popup". Rewrite to describe the pane-anchored,
  borderless host (`-B`, sized `#{pane_width}`×`#{pane_height}`, anchored over
  the pane top-left via `-x P -y P`), and cite **§7.0** (not §7.5). Keep the rest
  of the comment block (.last-output sidecar, quoting layers) intact.
  - OPTIONAL accuracy tweak (line ~208): the quoting comment lists `#{pane_id} →
    stored LITERAL`; now `#{pane_width}`/`#{pane_height}` are also literal — a
    one-phrase addition keeps it honest. Not required for correctness.
- **docs/CONFIGURATION.md line 41** (option table): `Prefix key: open the
  full-screen region overlay (TUI).` → pane-anchored overlay sized to the pane.
- **docs/CONFIGURATION.md lines 97–98** (section opener): `…opens the region
  overlay: a full-screen tmux display-popup running tmux-2html region.` →
  pane-anchored, borderless, sized to exactly overlay the source pane
  (`#{pane_width}`×`#{pane_height}`), cite §7.0. Keep the rest of the section.

## 5. Empirical proof (all PASS)

- TARGET binding line (post source-time expansion, apostrophe title+lang):
  `/bin/sh -n -c "$new"` → **exit 0**. The single-quoted `#{…}` survives.
- NEW robust sed on OLD bk line → extracts
  `/fake/bin/tmux-2html region … --target '#{pane_id}'`; `/bin/sh -n` → exit 0.
- NEW robust sed on NEW bk line → SAME inner command extracted; `/bin/sh -n` → exit 0.
- OLD sed on NEW line → garbage (no match) → PROVES the old sed is stale and the
  fix is necessary.

## 6. Files that MUST NOT change (verified — no Zig work)

- **src/region.zig** (~line 346): `getSize()` reads the popup's own pty via
  `ioctl(TIOCGWINSZ)`. When the popup is pane-sized, the pty dims AUTOMATICALLY
  equal the captured grid dims → 1:1 fidelity. No edit.
- **src/capture.zig**: `geometry()` reads `#{pane_width} #{pane_height}`.
  Unchanged.
- **The palette auto-sync popup** (tmux-2html.tmux line ~248): a DIFFERENT popup
  (`-w 50% -h 50%`, no `-B`/`-x P`/`-y P`). Do NOT touch it.
- **src/tui/\***: unchanged.

## 7. Baseline gates (all green, 2026-07-19)

- `tmux -V` → 3.6a (≥ 3.3; `-B`/`-x P`/`-y P` all live).
- `sh -n tmux-2html.tmux` / `sh -n tests/plugin_options.sh` → OK.
- `sh tests/plugin_options.sh` → exit 0 (PASS); `bash tests/plugin_options.sh` → exit 0.
- `sh scripts/check-safety.sh` → exit 0, `0 FAIL, 16 WARN` (ALL 16 WARNs in
  `plan/**/PRP.md` doc files — pre-existing; NONE in scripts/ or tmux-2html.tmux).
  The fix adds a flag set + a sed tweak — no PATH-shim, no `calls.log` → no new WARN/FAIL.
- `sh scripts/preflight.sh` → exit 0; disk fine.

## 8. Safety (PRD §0 / §0.1 + AGENTS.md) — this task is safe

- The test uses the existing **mock** `tmux()` harness (mktemp dir + fake binary);
  it shells to NO real tmux server.
- No tmux shim created; no real tmux touched at impl time.
- `/bin/sh -n` is SYNTAX-ONLY (no execution).
- The new `-t "#{pane_id}"` is a `display-popup` position target — NOT a mutation
  of the user's pane.
- A visual popup check is OPTIONAL and ONLY against an isolated named socket
  (`tmux -L <name>`), never the user's server (PRD §0).