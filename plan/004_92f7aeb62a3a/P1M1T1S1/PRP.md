# PRP — P1.M1.T1.S1: pane-anchored region popup binding (+ test fix + Mode A docs)

## Goal

**Feature Goal**: Swap the `C-o` region binding in `tmux-2html.tmux` from a forced
fullscreen popup (`display-popup -E -w 100% -h 100%`) to a **pane-anchored,
borderless popup** sized to exactly overlay the source pane
(`display-popup -B -E -w '#{pane_width}' -h '#{pane_height}' -x P -y P -t '#{pane_id}'`),
matching PRD §7.0 / §9.3. This makes the region TUI's own pty dimensions equal the
captured grid dimensions → 1:1 render fidelity (the fullscreen popup previously gave
a pty wider/taller than the pane). Also fix the now-stale test sed and update the two
CONFIGURATION.md references that say "full-screen". **No Zig changes** — `region.zig`'s
`getSize()` automatically matches the pane-sized popup pty.

**Deliverable**: Surgical edits to THREE files (no new files, no Zig):
1. `tmux-2html.tmux` — one token swap on the C-o binding line (line 214); rewrite the
   comment-block opener (lines 190–192) to drop "full-screen" and cite §7.0.
2. `tests/plugin_options.sh` — make the c.3 REGION sed (line 97) flag-agnostic so it
   still extracts + `/bin/sh -n`-validates the region inner command.
3. `docs/CONFIGURATION.md` — drop "full-screen" from the `@tmux-2html-region-key`
   option-table row (line 41) and the "## The region overlay" section opener
   (lines 97–98); cite §7.0.

**Success Definition**: `sh -n tmux-2html.tmux` + `sh -n tests/plugin_options.sh` parse;
`sh tests/plugin_options.sh` (and `bash tests/plugin_options.sh`) print PASS / exit 0;
`sh scripts/check-safety.sh` exits 0 with no new FAIL/WARN; `sh scripts/preflight.sh`
exits 0. The C-o binding's `run-shell` command (with the new pane-anchored flags)
parses under `/bin/sh -n`. `region.zig`/`capture.zig`/`tui/*`/the palette 50% popup are
untouched.

## Why

- **Render fidelity (PRD §7.0 / §1.1)**: the fullscreen popup gave the TUI a pty sized
  to the *client* (often wider/taller than the pane), so the grid — sized from
  `#{pane_width}` — never filled the overlay and content rendered at the wrong scale.
  A pane-sized, borderless, pane-anchored popup makes the pty dims exactly equal the
  grid dims → the user sizes the pane first and gets a faithful 1:1 render.
- **Non-destructive host (PRD §0)**: an external TUI cannot take over a pane without
  destroying its program (`respawn-pane`/`kill-pane` are forbidden). A `display-popup`
  overlaying the pane is the faithful, non-destructive host — when it closes, the
  original pane is untouched beneath.
- **PRD already landed (commit 382d838)**: this plan implements the code/test/docs to
  match the updated PRD §7.0 / §9.3 / §12 (tmux floor now ≥ 3.3). Only the HOST of the
  region TUI changes; everything else is verbatim.

## What

User-visible: pressing `prefix C-o` (the region key) now opens a borderless popup that
exactly overlays the current pane (same size, same top-left position) instead of a
forced fullscreen window. The rendered width/height matches the pane; the user controls
it by sizing the pane first (zoom with `resize-pane -Z` for a fullscreen render).

Technical:
- The `C-o` binding's `run-shell "…"` string changes ONLY the `display-popup` flag set:
  `display-popup -E -w 100% -h 100%` →
  `display-popup -B -E -w '#{pane_width}' -h '#{pane_height}' -x P -y P -t '#{pane_id}'`.
  The `.last-output` sidecar wrapper, the escaped-double-quote inner-command wrapping,
  and the post-popup `if … display-message` tail are all preserved verbatim.
- `#{pane_width}`/`#{pane_height}`/`#{pane_id}` are tmux formats expanded at fire time
  → they stay SINGLE-QUOTED in the inner command (the `#` would start a shell comment if
  unquoted). `-x P`/`-y P` are literal tokens (no quoting).
- `region.zig`'s `getSize()` reads the popup's own pty dims via `ioctl(TIOCGWINSZ)`;
  with a pane-sized popup those equal the grid dims automatically — no Zig edit.

### Success Criteria

- [ ] `tmux-2html.tmux` line 214 uses the pane-anchored `-B -E -w '#{pane_width}' -h
      '#{pane_height}' -x P -y P -t '#{pane_id}'` flags; everything else on the line
      is byte-identical to before.
- [ ] The binding's `run-shell` command parses under `/bin/sh -n` (single-quoted `#{…}`).
- [ ] The comment-block opener (lines 190–192) no longer says "full-screen"; cites §7.0.
- [ ] `tests/plugin_options.sh` line 97 sed is flag-agnostic; `sh`/`bash` runs → PASS.
- [ ] `docs/CONFIGURATION.md` lines 41 + 97–98 no longer say "full-screen"; cite §7.0.
- [ ] `region.zig`/`capture.zig`/`tui/*`/the palette 50% popup are UNCHANGED.
- [ ] All baseline gates green (sh -n ×2, test PASS, check-safety 0 new, preflight).

## All Needed Context

### Context Completeness Check

_Pass: "If someone knew nothing about this codebase, would they have everything
needed to implement this successfully?"_ — Yes. Every edit is given as an exact
byte-accurate old→new block read from the live source. The three-layer quoting
(the only non-obvious risk) is fully explained AND empirically proven (the target
line parses under `/bin/sh -n`; the new sed works on both prefixes). The validation
commands are verified green on the baseline. The implementer does pure text
replacement across 3 files.

### Documentation & References

```yaml
# MUST READ FIRST - authoritative: exact current line, target line, quoting GOTCHA, robust sed, the two doc strings
- file: plan/004_92f7aeb62a3a/architecture/system_context.md
  why: "§2.1 exact current + target binding line; §2.1 three-layer quoting GOTCHA; §2.2 the robust sed fix; §2.3 the two CONFIGURATION.md strings; §3 files that MUST NOT change; §4 local env (tmux 3.6a)."
  critical: "§2.1 GOTCHA: #{pane_width}/#{pane_height}/#{pane_id} MUST be single-quoted (tmux fire-time formats; # would comment-start if unquoted). -x P/-y P literal, no quoting. $TMUX_2HTML_BIN/$title_arg/$lang_arg expanded-now."

# MUST READ - tmux 3.3 flag facts + confidence ratings
- file: plan/004_92f7aeb62a3a/architecture/external_tmux_popup.md
  why: "Corroborates -B=borderless (3.3, HIGH), -x P/-y P=pane-anchored (3.3, MED-HIGH), -B⇒inner pty=full footprint (HIGH), floor tmux≥3.3. Locally confirmed: tmux 3.6a, man tmux '-B does not surround the popup by a border', isolated parse check clean."

# MUST READ - the file with the binding change (read it first; line numbers verified)
- file: tmux-2html.tmux
  why: "C-o binding at line 213–214; comment block 188–212 (the 'full-screen' opener is lines 190–192)."
  pattern: "binding: [ \"\$binary_ready\" = 1 ] && tmux bind-key \"\$region_key\" run-shell \"…display-popup … \$TMUX_2HTML_BIN/tmux-2html region \$title_arg \$lang_arg --target '#{pane_id}'…\". Three layers: source-time expansion (\$VAR), literal-tmux-format ('#{…}'), fire-time-escaped (\\\",\\$)."
  gotcha: "Change ONLY the display-popup flag token. The palette auto-sync popup (line ~248, -w 50% -h 50%) is a DIFFERENT popup — do NOT touch it."

# MUST READ - the test sed to fix
- file: tests/plugin_options.sh
  why: "c.3 REGION block lines 92–98; the stale sed is line 97. Uses the mock tmux() harness (no real tmux)."
  gotcha: "The OLD sed hardcodes '-E -w 100% -h 100%' and will NOT match the new prefix → rinner becomes garbage. The fix makes it flag-agnostic ([^\"]*\")."

# MUST READ - the two docs references (Mode A)
- file: docs/CONFIGURATION.md
  why: "Line 41 (@tmux-2html-region-key option row) + lines 97–98 ('## The region overlay' opener). Both say 'full-screen'."
  gotcha: "The §7.4 keybinding table (~line 166) and the palette section (~line 244, 50% popup) are UNRELATED — do NOT touch them."

# Normative source
- file: PRD.md
  section: "§7.0 (the pane-anchored host + verified invocation) + §9.3 (C-o binding) + §12 (tmux ≥ 3.3 floor)"
  why: "§7.0 gives the canonical display-popup invocation and the -B/-x P/-y P/-t semantics; §12 pins the tmux floor to 3.3."

- file: plan/004_92f7aeb62a3a/P1M1T1S1/research/findings.md
  why: "Companion note: empirical proof (target line parses; new sed works on both prefixes; old sed breaks), baseline-gate confirmation, files-MUST-NOT-change list."
```

### Current Codebase tree (relevant slice)

```bash
tmux-2html/
├── tmux-2html.tmux           # <— EDIT: C-o binding line 214 + comment opener 190–192
├── tests/
│   └── plugin_options.sh     # <— EDIT: c.3 sed line 97 (flag-agnostic)
├── docs/
│   └── CONFIGURATION.md      # <— EDIT: line 41 + lines 97–98 (drop "full-screen")
├── src/region.zig            # DO NOT EDIT (getSize() auto-matches pane-sized pty)
├── src/capture.zig           # DO NOT EDIT
├── src/tui/                  # DO NOT EDIT
└── scripts/{check-safety,preflight}.sh   # run-only gates; DO NOT EDIT
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
tmux-2html/
├── tmux-2html.tmux           # MODIFIED: pane-anchored popup flags + rewritten comment opener
├── tests/plugin_options.sh   # MODIFIED: flag-agnostic c.3 sed (still /bin/sh -n validates inner cmd)
└── docs/CONFIGURATION.md     # MODIFIED: 2 spots drop "full-screen", cite §7.0
# NO new files. NO Zig changes. NO palette-popup change.
```

### Known Gotchas of our codebase & Library Quirks

```sh
# GOTCHA 1 — THREE-LAYER QUOTING (the only real risk). The region binding string is the
#   arg to `bind-key … run-shell "…"`. Inside it:
#   - $TMUX_2HTML_BIN / $title_arg / $lang_arg expand NOW (source time) — exported vars
#     don't reach run-shell children.
#   - #{pane_width} / #{pane_height} / #{pane_id} are tmux FORMATS expanded at FIRE time
#     → they MUST be in SINGLE QUOTES ('#{…}') so /bin/sh leaves them literal. If unquoted,
#     the '#' starts a shell comment and breaks the line. (#{pane_id} is already single-
#     quoted today; the new width/height/-t must follow suit.)
#   - -x P / -y P are literal tokens (no $ / {}) → no quoting.
#   - \" / \$out / \$(…) stay escaped (deferred to fire time).
#   PROVEN: the full target line parses under /bin/sh -n (exit 0).

# GOTCHA 2 — the OLD test sed is now stale. It hardcodes '-E -w 100% -h 100%' and will NOT
#   match the new pane-anchored prefix → rinner becomes garbage. Make it flag-agnostic:
#   sed 's/.*display-popup [^"]*"//; s/"; if.*//'  (matches BOTH old and new prefixes).

# GOTCHA 3 — change ONLY the display-popup flag token. Preserve the .last-output sidecar
#   wrapper, the escaped-double-quote inner-command wrapping, and the if…display-message
#   tail BYTE-FOR-BYTE. Do not "tidy" the rest of the line.

# GOTCHA 4 — the palette auto-sync popup (tmux-2html.tmux ~line 248: -w 50% -h 50%, no
#   -B/-x P/-y P) is a DIFFERENT popup. Do NOT touch it. Grep for "50%" to see it.

# GOTCHA 5 — NO Zig changes. region.zig getSize() reads the popup's own pty dims via
#   ioctl(TIOCGWINSZ); with a pane-sized popup those AUTOMATICALLY equal the captured
#   grid dims → 1:1 fidelity. capture.zig geometry() already reads #{pane_width}.

# GOTCHA 6 — the test uses the MOCK tmux() harness (mktemp + fake binary); it shells to
#   NO real tmux server. Do not add any tmux invocation. A visual popup check is OPTIONAL
#   and ONLY against an isolated named socket (tmux -L <name>), never the user's server.
```

## Implementation Blueprint

### Data models and structure

Not applicable — pure POSIX sh + markdown; no data models. The change is one flag-set
token + a sed regex + two prose edits.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: SWAP the display-popup flags (tmux-2html.tmux line 214) — the core change
  - EXACT OLD (line 214):
        "last=\"$TMUX_2HTML_BIN/.last-output\"; rm -f \"\$last\"; tmux display-popup -E -w 100% -h 100% \"$TMUX_2HTML_BIN/tmux-2html region $title_arg $lang_arg --target '#{pane_id}'\"; if [ -f \"\$last\" ]; then out=\$(cat \"\$last\"); tmux display-message \"tmux-2html: wrote \$out\"; fi"
  - EXACT NEW (line 214):
        "last=\"$TMUX_2HTML_BIN/.last-output\"; rm -f \"\$last\"; tmux display-popup -B -E -w '#{pane_width}' -h '#{pane_height}' -x P -y P -t '#{pane_id}' \"$TMUX_2HTML_BIN/tmux-2html region $title_arg $lang_arg --target '#{pane_id}'\"; if [ -f \"\$last\" ]; then out=\$(cat \"\$last\"); tmux display-message \"tmux-2html: wrote \$out\"; fi"
  - The ONLY difference: `display-popup -E -w 100% -h 100%` → `display-popup -B -E -w '#{pane_width}' -h '#{pane_height}' -x P -y P -t '#{pane_id}'`.
  - GOTCHA 1: single-quote #{…}; -x P/-y P literal. PROVEN to parse under /bin/sh -n.
  - WHY FIRST: this is the behavior change the test + docs describe.

Task 2: REWRITE the comment-block opener (tmux-2html.tmux lines 190–192)
  - EXACT OLD (lines 190–192):
        # PRD §9.3 + §7.5: prefix <region_key> (default C-o) opens a full-screen tmux
        # display-popup (a REAL pty — run-shell has no /dev/tty, so the region TUI + the
        # palette can only run inside the popup) running `tmux-2html region --target
        # #{pane_id}`.
  - EXACT NEW (describe pane-anchored borderless host; cite §7.0; keep the REAL-pty rationale):
        # PRD §9.3 + §7.0: prefix <region_key> (default C-o) opens a pane-anchored,
        # borderless tmux display-popup (-B; sized #{pane_width}x#{pane_height}; anchored
        # over the pane top-left via -x P -y P) so the TUI's pty dims exactly match the
        # captured grid (1:1 fidelity). It is a REAL pty (run-shell has no /dev/tty, so the
        # region TUI + palette can only run inside it) running `tmux-2html region --target
        # #{pane_id}`.
  - Keep the rest of the comment block (lines 193–212: .last-output sidecar, quoting
    layers) intact. (OPTIONAL accuracy tweak at line ~208: note #{pane_width}/#{pane_height}
    are also stored-literal alongside #{pane_id}.)
  - DEPENDENCIES: Task 1.

Task 3: FIX the c.3 REGION sed (tests/plugin_options.sh line 97) — flag-agnostic
  - EXACT OLD (line 97):
        rinner=$(printf '%s' "$rline" | sed 's/.*display-popup -E -w 100% -h 100% "//; s/"; if.*//')
  - EXACT NEW (line 97):
        rinner=$(printf '%s' "$rline" | sed 's/.*display-popup [^"]*"//; s/"; if.*//')
  - NOTE: [^"]* consumes any flags (old -E -w 100% -h 100% OR new -B -E -w '…' -h '…' -x P -y P -t '…'),
    then the first " opens the inner command. Trailing s/"; if.*// unchanged. PROVEN to
    extract the inner `tmux-2html region … --target '#{pane_id}'` from BOTH prefixes.
  - DO NOT change the surrounding c.3 lines (rline grep, [ -n ] guard, /bin/sh -n assert).
  - DEPENDENCIES: Task 1 (the binding must use the new prefix or the test is moot).

Task 4: UPDATE docs/CONFIGURATION.md — drop "full-screen" (Mode A)
  - (a) Line 41 (option-table row):
        OLD: | `@tmux-2html-region-key` | `C-o` | Prefix key: open the full-screen region overlay (TUI). |
        NEW: | `@tmux-2html-region-key` | `C-o` | Prefix key: open the region overlay (TUI) — a pane-anchored popup sized to the current pane (§7.0). |
  - (b) Lines 97–98 (section opener):
        OLD: `prefix C-o` (the `@tmux-2html-region-key`) opens the region overlay: a
             full-screen `tmux display-popup` running `tmux-2html region`. The overlay first
        NEW: `prefix C-o` (the `@tmux-2html-region-key`) opens the region overlay: a
             pane-anchored, borderless `tmux display-popup` sized to exactly overlay the
             source pane (`#{pane_width}`×`#{pane_height}`; §7.0), running `tmux-2html region`. The overlay first
  - Keep the rest of the section (full-scrollback capture, cursor-on-last-row, confirm/cancel) unchanged.
  - DO NOT touch the §7.4 keybinding table (~line 166) or the palette section (~line 244).

Task 5: VALIDATE  (see Validation Loop)
  - RUN: sh -n tmux-2html.tmux ; sh -n tests/plugin_options.sh   → both OK
  - RUN: sh tests/plugin_options.sh  AND  bash tests/plugin_options.sh   → PASS / exit 0
  - RUN: sh scripts/check-safety.sh   → exit 0, no new FAIL/WARN
  - RUN: sh scripts/preflight.sh      → exit 0
```

### Implementation Patterns & Key Details

```sh
# PATTERN: the binding is a single double-quoted run-shell string. Token layers:
#   expanded-NOW   : $TMUX_2HTML_BIN, $title_arg, $lang_arg
#   literal-format : '#{pane_width}' '#{pane_height}' '#{pane_id}'  (tmux fire-time; SINGLE-QUOTED)
#   literal-token  : -x P -y P                                       (no $ / {})
#   fire-escaped   : \" \$out \$(…)                                  (deferred to /bin/sh)
# Swap ONLY the display-popup flag token; leave the wrapper + tail byte-identical.

# PATTERN: the c.3 sed strips the BK prefix + the display-popup flags, leaving the inner
# command between the first " and the "; if — robust to ANY flag set:
rinner=$(printf '%s' "$rline" | sed 's/.*display-popup [^"]*"//; s/"; if.*//')

# CRITICAL: region.zig's getSize() reads the popup's OWN pty via ioctl(TIOCGWINSZ). When
# the popup is pane-sized (-w #{pane_width} -h #{pane_height}, borderless -B), the pty
# dims AUTOMATICALLY equal cap.cols/cap.rows → 1:1. No Zig edit.
```

### Integration Points

```yaml
PLUGIN BINDINGS (tmux-2html.tmux):
  - C-o region binding line 214: popup flag set swapped; wrapper + tail unchanged.
  - §3 debug seam: UNCHANGED (title_arg/lang_arg unaffected; this is a popup-flag change).
  - palette auto-sync popup (~line 248, 50%): UNCHANGED — different popup.

TEST HARNESS (tests/plugin_options.sh):
  - c.3 sed (line 97): flag-agnostic; still /bin/sh -n validates the inner region cmd.
  - mock tmux() harness: UNCHANGED; no real tmux.

DOCS (docs/CONFIGURATION.md):
  - line 41 + 97–98: drop "full-screen", cite §7.0.

DOWNSTREAM / OUT OF SCOPE:
  - src/region.zig, src/capture.zig, src/tui/*: UNCHANGED (getSize()/geometry() auto-match).
  - README.md: 3 stale references (region bullet, tmux floor 3.2→3.3, region opener) are
    the SEPARATE Mode B task P1.M1.T2.S1. Do NOT edit README here.
  - tmux version floor doc (3.2→3.3) belongs to the README Mode B task, not here.

CONFIG / DATABASE / ROUTES:
  - none.
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# POSIX sh parse check (no execution):
sh -n tmux-2html.tmux       && echo "tmux-2html.tmux parses OK"
sh -n tests/plugin_options.sh && echo "plugin_options.sh parses OK"
# Expected: both OK. A parse error means the quoting got mangled — re-check GOTCHA 1.

# Safety guard (AGENTS.md §3) — must stay green:
sh scripts/check-safety.sh
# Expected: "== result: 0 FAIL(s), 16 WARN(s) ==" and exit 0. The 16 WARNs are all in
# plan/**/PRP.md docs (pre-existing). If you see a 17th WARN or any FAIL referencing
# tmux-2html.tmux/tests/, STOP (your edit must not look like a shim/calls.log — it won't).

sh scripts/preflight.sh     # residue/disk check; expected exit 0
```

### Level 2: Unit / Harness Tests (Component Validation)

```bash
# THE PRIMARY GATE for this shell change. Run under BOTH sh and bash (contract lists bash).
sh   tests/plugin_options.sh   # expect: PASS, exit 0
bash tests/plugin_options.sh   # expect: PASS, exit 0
# The c.3 block extracts the region inner command via the flag-agnostic sed and /bin/sh -n
# validates it (with an apostrophe title). PASS means the new prefix is correctly captured
# AND the inner command still parses.
#
# To PROVE the test actually exercises the NEW prefix: the OLD sed (hardcoded
# '-E -w 100% -h 100%') would leave rinner garbage on the new line — so if you temporarily
# reverted ONLY the sed (not the binding), c.3 would FAIL. (Confirming it's a real check.)
```

### Level 3: Integration Testing (System Validation)

```bash
# No real tmux at impl time (PRD §0). The /bin/sh -n checks INSIDE the harness are the
# end-to-end syntax proof. Additionally, eyeball the exact emitted binding parses:
sh -c '
  BIN=/fake/bin
  new="last=\"$BIN/.last-output\"; rm -f \"\$last\"; tmux display-popup -B -E -e '\''#'\'' -w '\''#{pane_width}'\'' -h '\''#{pane_height}'\'' -x P -y P -t '\''#{pane_id}'\'' \"$BIN/tmux-2html region --target '\''#{pane_id}'\''\"; if [ -f \"\$last\" ]; then out=\$(cat \"\$last\"); fi"
  /bin/sh -n -c "$new" && echo "target binding parses under /bin/sh -n"
'
# (The exact line lives in tmux-2html.tmux:214; the above is a faithful isolated echo.
#  Simplest: grep the committed line and /bin/sh -n the post-expansion form — the harness
#  c.3 block already does this via the mock capture.)
```

### Level 4: Creative & Domain-Specific Validation

```bash
# OPTIONAL visual popup check — ONLY against an ISOLATED named socket, NEVER the user's
# server (PRD §0). Requires an attached client (popups don't display headless). Skip if
# headless — the local parse check (system_context.md §4) already confirmed the flag set
# is syntactically valid on tmux 3.6a with NO usage/flag error.
#
# tmux version floor confirmation (corroborates -B/-x P/-y P are live):
tmux -V    # expect 3.6a (>= 3.3); man tmux | grep -A2 display-popup  confirms -B borderless

# Regression guard: confirm the palette auto-sync popup (50%) is UNTOUCHED:
grep -n 'display-popup -E -w 50% -h 50%' tmux-2html.tmux   # expect: the ONE palette line, unchanged
grep -n '100% -h 100%' tmux-2html.tmux                     # expect: NO output (old fullscreen token gone)
grep -n "-pane_width" tmux-2html.tmux                      # expect: the new C-o binding line
```

## Final Validation Checklist

### Technical Validation

- [ ] `sh -n tmux-2html.tmux` + `sh -n tests/plugin_options.sh` parse clean (Level 1).
- [ ] `sh tests/plugin_options.sh` AND `bash tests/plugin_options.sh` → PASS, exit 0 (Level 2).
- [ ] `sh scripts/check-safety.sh` → exit 0, no new FAIL/WARN (Level 1).
- [ ] `sh scripts/preflight.sh` → exit 0 (Level 1).

### Feature Validation

- [ ] C-o binding uses `-B -E -w '#{pane_width}' -h '#{pane_height}' -x P -y P -t '#{pane_id}'`.
- [ ] The binding's run-shell command parses under `/bin/sh -n` (single-quoted `#{…}`).
- [ ] Wrapper + tail byte-identical; only the display-popup flag token changed.
- [ ] Comment opener (190–192) drops "full-screen", cites §7.0.
- [ ] CONFIGURATION.md lines 41 + 97–98 drop "full-screen", cite §7.0.
- [ ] region.zig / capture.zig / tui/* / palette 50% popup UNCHANGED.

### Code Quality Validation

- [ ] Three-layer quoting honored (GOTCHA 1): `#{…}` single-quoted, `$VAR` expanded-now,
      `\"`/`\$` fire-escaped, `-x P`/`-y P` literal.
- [ ] Test sed is flag-agnostic (works on old AND new prefix — forward/backward robust).
- [ ] Comment + docs accurately describe the pane-anchored host (no "full-screen" lies).
- [ ] No Zig changes (getSize() auto-matches the pane-sized pty).

### Documentation & Deployment

- [ ] CONFIGURATION.md region-overlay references consistent with the binding (Mode A).
- [ ] README.md NOT edited here (separate Mode B task P1.M1.T2.S1).

---

## Anti-Patterns to Avoid

- ❌ Don't unquote `#{pane_width}`/`#{pane_height}`/`#{pane_id}` — the `#` starts a shell
  comment at `/bin/sh` parse time and breaks the line. Keep them SINGLE-QUOTED (as
  `#{pane_id}` already is today).
- ❌ Don't change anything on line 214 EXCEPT the `display-popup` flag token — the
  `.last-output` wrapper, the escaped-double-quote inner-command wrapping, and the
  `if … display-message` tail are preserved byte-for-byte.
- ❌ Don't touch the palette auto-sync popup (`-w 50% -h 50%`, ~line 248) — it's a
  different popup with no `-B`/`-x P`/`-y P`.
- ❌ Don't keep the OLD hardcoded sed (`-E -w 100% -h 100%`) — it won't match the new
  prefix and c.3 silently degrades. Use the flag-agnostic `[^"]*` form.
- ❌ Don't edit any Zig file (region.zig/capture.zig/tui/*) — `getSize()` auto-matches the
  pane-sized popup pty; this is purely a popup-flag change.
- ❌ Don't edit README.md or the tmux-version-floor doc here — those are the separate
  Mode B task (P1.M1.T2.S1).
- ❌ Don't run `tmux kill-server`/`killall tmux`/`pkill tmux` or touch the user's server
  (PRD §0). The test uses the mock harness; a visual check (optional) is isolated-socket only.
- ❌ Don't leave any `100% -h 100%` token in the C-o binding (grep must be clean) and don't
  leave any "full-screen" in the C-o comment / the two CONFIGURATION.md region spots.

---

**Confidence Score: 10/10** for one-pass implementation success.

The change is a single flag-token swap on one line (with the wrapper/tail preserved
verbatim), and every shell-quoting claim was proven empirically: the target binding line
parses under `/bin/sh -n` (exit 0 — single-quoted `#{…}` survives), the new flag-agnostic
sed extracts the inner region command from BOTH old and new prefixes, and the old sed
provably breaks on the new line (garbage). All four baseline gates (`sh -n` ×2, test PASS
under sh+bash, `check-safety.sh` 0 new, `preflight.sh`) were run green. The three-layer
quoting (the only real risk) is fully explained, and the files-MUST-NOT-change list
(region.zig auto-matching, palette 50% popup, tui/*) is explicit. Scope is cleanly bounded
from the README Mode B task and all Zig code.