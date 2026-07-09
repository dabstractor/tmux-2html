name: "P2.M2.T2.S2 — prefix-table binding: C-o region overlay (display-popup wrapper) + .last-output sidecar"
description: |

---

## Goal

**Feature Goal**: Fill the labeled `C-o region binding — P2.M2.T2.S2` sub-stub in the
already-implemented `tmux-2html.tmux` loader so that **`prefix C-o` (the default
`@tmux-2html-region-key`) opens a full-screen `tmux display-popup`** (`-E -w 100% -h 100%`)
running `tmux-2html region --target #{pane_id}` in a real pty, then — after the popup closes —
**reads the result path the region binary wrote to `$TMUX_2HTML_BIN/.last-output` and flashes
it on the status line via `tmux display-message "tmux-2html: wrote <path>"`**. The region
binary itself lands in P3 (it currently returns `NotImplemented`/exit 1), so this binding is
**inert-but-correct until P3**: it opens the popup, region exits non-zero (popup closes via
`-E`), and — because region never wrote `.last-output` — the wrapper shows **no** message
(graceful). Once P3 lands confirm/cancel, the same binding renders the selection and reports
the path. Honor the `C-o` override note (PRD §9.2): binding `$region_key` overrides any prior
`C-o` binding by tmux's re-bind semantics; the loader does NOT save/restore the old binding
(preservation is a user action — set `@tmux-2html-region-key C-S-o`).

**Deliverable** (at `/home/dustin/projects/tmux-2html/`):
1. **MODIFY `tmux-2html.tmux`** — REPLACE the existing `C-o region binding — P2.M2.T2.S2`
   sub-stub (the 5-line commented placeholder sitting between the O+visible bindings block and
   the `## Palette auto-sync popup` block) with the real region bind-key:
   - `[ "$binary_ready" = 1 ] && tmux bind-key "$region_key" run-shell "<wrapper>"` where the
     wrapper (source-time escaping, fire-time body) does: clear `$BIN/.last-output`; run
     `tmux display-popup -E -w 100% -h 100% "$BIN/tmux-2html region --target #{pane_id}"`;
     then `if [ -f "$BIN/.last-output" ]; then out=$(cat "$BIN/.last-output"); tmux
     display-message "tmux-2html: wrote $out"; fi`.
   - Optionally append `region_bound` to the `TMUX_2HTML_DEBUG` seam (with `>>`, after §4's `>`).
   - `$TMUX_2HTML_BIN` is interpolated at SOURCE time; `#{pane_id}` is stored LITERAL.

**Success Definition**:
- With the binary ready + defaults, sourcing the loader issues exactly one
  `bind-key C-o run-shell "<wrapper>"` whose body contains `display-popup -E -w 100% -h 100%`,
  `region --target`, the LITERAL `#{pane_id}`, `.last-output`, and `display-message`
  (assertable via a fake-`tmux` stub that records `bind-key` argv).
- `$TMUX_2HTML_BIN` is expanded to the absolute bin path at source time inside the stored
  string; `#{pane_id}` is NOT expanded (run-shell expands it at fire time).
- With `binary_ready=0` ⇒ the loader issues **no** region bind-key (the §9.1 "on failure skip
  binding" rule — same gate as the O binding).
- With `@tmux-2html-region-key "C-S-o"` set ⇒ the bind-key uses `C-S-o` (honoring the §9.2
  override: the default `C-o` is overridden by whatever `$region_key` resolves to).
- Sidecar logic (deterministic, Level 2): running the wrapper body with a fake `tmux-2html
  region` that writes `$BIN/.last-output` ⇒ the wrapper calls `display-message "tmux-2html:
  wrote <path>"`; running it with a fake region that exits WITHOUT writing ⇒ **no**
  `display-message` (cancel path; the pre-popup `rm -f` prevents a stale message).
- `sh -n tmux-2html.tmux` passes; `shellcheck -s sh` clean (or N/A); no bashisms in the new block.
- In a real attached tmux session: `prefix C-o` opens the full-screen popup; once P3 lands,
  confirming a selection writes `<output-dir>/<file>.html`, closes the popup, and flashes
  `tmux-2html: wrote <path>` on the status line. (Until P3, the popup opens then closes and
  shows nothing — region exits 1.)
- No Zig/build/docs changes; `PRD.md`/`tasks.json`/`prd_snapshot.md`/`.gitignore` untouched;
  §1–§4, the O+visible bindings block, and the autosync block untouched.

## User Persona (if applicable)

**Target User**: a tmux user with the plugin installed who wants to render a *selected*
region (not a whole pane) to HTML — the same person who uses `prefix O` for full-pane capture.

**Use Case**: the user spots a colorful chunk of output (a `fastfetch`, a test summary) and
wants an HTML snapshot of just that region. They press `prefix C-o`, move/select in the
copy-mode-style overlay (P3), press `Enter`, and get a status-line confirmation + the file.

**User Journey**: `prefix C-o` → full-screen overlay opens → (P3) select region → `Enter` →
popup closes → status line flashes `tmux-2html: wrote /path/to/file.html`.

**Pain Points Addressed**: the popup is a real pty (so the region TUI + palette work), and the
sidecar bridges the popup↔status-line gap (the popup has no tmux message channel, §7.5).

## Why

- **PRD §9.3 makes `prefix C-o` the region entry point.** The C-o binding is the wire between
  the user's keypress and the (P3) region TUI. Without it the region subcommand is unreachable
  from the keyboard.
- **The popup is mandatory, not decorative:** `run-shell` (the binding context) has NO
  `/dev/tty` (research_tmux.md Claim 3), so a full-screen TUI + OSC palette queries CANNOT run
  there. `display-popup -E -w 100% -h 100%` is a **real pty** (Claim 2) where the region TUI
  (alt-screen, raw termios, mouse) and the palette both work. The binding exists to launch that
  popup over the current pane (`--target #{pane_id}`).
- **The sidecar exists because the popup has no tmux message channel (PRD §7.5).** region
  renders inside the popup pty; it cannot reliably call `tmux display-message` against the
  user's server from there. So region writes the result path to `$TMUX_2HTML_BIN/.last-output`,
  and the wrapper — running in the run-shell `/bin/sh` context (which DOES have `$TMUX`) —
  reads it and flashes the message. This mirrors the O binding's `tmux-2html: wrote <path>`
  format.
- **§9.2 override is intended, not a bug:** `C-o` is the documented default; the note tells
  users how to preserve the stock binding if they care. Binding `$region_key` honors that.

## What

### Behavior (`tmux-2html.tmux`, the block that replaces the C-o sub-stub)

1. **The region bind-key** — gated on `[ "$binary_ready" = 1 ]`:
   ```sh
   [ "$binary_ready" = 1 ] && tmux bind-key "$region_key" run-shell \
       "last=\"$TMUX_2HTML_BIN/.last-output\"; rm -f \"\$last\"; tmux display-popup -E -w 100% -h 100% \"$TMUX_2HTML_BIN/tmux-2html region --target '#{pane_id}'\"; if [ -f \"\$last\" ]; then out=\$(cat \"\$last\"); tmux display-message \"tmux-2html: wrote \$out\"; fi"
   ```
2. (Optional) **`TMUX_2HTML_DEBUG` append** (`>>`; §4 already wrote with `>` and runs first in
   file order):
   ```sh
   if [ -n "${TMUX_2HTML_DEBUG:-}" ]; then
       printf 'region_bound=%s\n' "$([ "$binary_ready" = 1 ] && echo 1 || echo 0)" >> "$TMUX_2HTML_DEBUG"
   fi
   ```

### What the binding does at FIRE time (run-shell expands `#{pane_id}` → e.g. `%5`, then `/bin/sh` runs the wrapper)

1. `last="$BIN/.last-output"` — assign the sidecar path (`$BIN` already expanded at source time).
2. `rm -f "$last"` — clear any STALE `.last-output` from a prior run (so a cancel never flashes
   a stale path).
3. `tmux display-popup -E -w 100% -h 100% "$BIN/tmux-2html region --target %5"` — open the
   full-screen pty, run region against the firing pane. `-E` closes the popup when region exits.
   region resolves font/open/output-dir from `@tmux-2html-*` ITSELF (like `pane`); the wrapper
   passes ONLY `--target #{pane_id}`.
4. `if [ -f "$last" ]; then out=$(cat "$last"); tmux display-message "tmux-2html: wrote $out"; fi`
   — if region confirmed (wrote the path), flash `tmux-2html: wrote <path>` on the status line
   of the firing client; if region cancelled (exited 1, never wrote), `$last` is absent (cleared
   in step 2) → no message. The `if…fi` always returns 0 (no `&&`-short-circuit exit-1 noise).

### Success Criteria

- [ ] Defaults + binary ready ⇒ exactly one `bind-key C-o run-shell "<wrapper>"` whose stored
      body contains `display-popup -E -w 100% -h 100%`, `region --target '#{pane_id}'` (LITERAL),
      `.last-output`, and `display-message` (fake-tmux assertion).
- [ ] `$TMUX_2HTML_BIN` is expanded to the absolute bin path in the stored string; `#{pane_id}`
      is stored LITERAL (NOT expanded at source time).
- [ ] `@tmux-2html-region-key "C-S-o"` ⇒ the bind-key uses key `C-S-o` (override honored).
- [ ] `binary_ready=0` ⇒ **no** region bind-key.
- [ ] Sidecar logic (Level 2): region-writes-path ⇒ wrapper `display-message "tmux-2html: wrote
      <path>"`; region-exits-without-writing ⇒ **no** `display-message` (cancel; stale cleared).
- [ ] `sh -n` passes; no bashisms; `shellcheck -s sh` clean (or N/A).
- [ ] No Zig/build/docs changes; §1–§4, the O+visible bindings block, the autosync block, the
      C-o sub-stub's neighbors all intact.

## All Needed Context

### Context Completeness Check

_Passes the "No Prior Knowledge" test_: the exact 5-line sub-stub to replace is quoted verbatim
from the live `tmux-2html.tmux`; the exact (three-layer-quoted) wrapper command string is given
verbatim and derived from the **proven** O binding (P2.M2.T2.S1 ran the same two-layer quoting
end-to-end against tmux 3.6b); the consumed loader symbols (`$region_key`, `$TMUX_2HTML_BIN`,
`$binary_ready`, the no-`set -e` rule, the `TMUX_2HTML_DEBUG` `>`-then-`>>` ordering) are read
from the live §1–§4; the region CLI surface is pinned to `src/cli.zig` `RegionOpts`/`parseRegion`
(ONLY `--target/--font/--output/--open`; region reads font/open/output-dir from options itself,
confirmed by `docs/CONFIGURATION.md` "How options are read"); the `.last-output` sidecar contract
(location, content, lifecycle) is pinned to PRD §9.3 + §7.5; and every load-bearing tmux fact
(display-popup = real pty; run-shell = no tty but `$TMUX` set; `#{pane_id}` expands at fire time;
`source-file` rejects shell scripts; display-popup needs an attached client; `display-popup` ≥ 3.2)
is verified in `architecture/research_tmux.md`. An implementer who has never seen this codebase
can ship it from this PRP + the cited files.

### Documentation & References

```yaml
# MUST READ — the file this task edits (the sub-stub to replace is quoted verbatim in research/findings.md §1)
- file: tmux-2html.tmux
  why: "ALREADY FILLED by P2.M2.T1.S1 + P2.M2.T2.S1. Replace the `C-o region binding — P2.M2.T2.S2`
        sub-stub (the 5-line commented placeholder between the O+visible bindings block and the
        `## Palette auto-sync popup` block) with the region bind-key. Consumes $region_key (§3),
        $TMUX_2HTML_BIN (§1), $binary_ready (§2). Do NOT touch §1–§4, the O+visible bindings block,
        or the autosync block."
  pattern: "POSIX sh; no `set -e`; the bind-key command arg is one double-quoted string with
            three-layer escaping (see Implementation Patterns)."
  gotcha: "The sub-stub's two trailing comment lines (`# ---...` 29-dash then `# ------...` 70-dash):
           replace the C-o stub's 5 lines, keep ONE separator line before the autosync block."

# MUST READ — the PROVEN template for the two-layer quoting (this task adds one more layer: display-popup)
- file: plan/001_0c8587f91cb2/P2M2T2S1/PRP.md
  why: "The O binding is the exact template: same `[ binary_ready ] && bind-key $key run-shell
        \"<wrapper>\"` shape, same `\\$TMUX_2HTML_BIN`-expanded-at-source-time rule, same
        `#{pane_id}`-stored-literal rule, same `\\\"`/`\\$( )`/`\\$out` escaping, same binary_ready
        gate, same TMUX_2HTML_DEBUG `>>` append ordering, same anti-patterns. The C-o wrapper is
        the O wrapper + a `tmux display-popup` call + a sidecar read. Cite for the quoting + the
        'exported vars don't reach run-shell children' + 'pane reads options itself' gotchas."
  section: "Implementation Patterns & Key Details", "Known Gotchas"

# MUST READ — the display-popup precedent (the popup mechanics + the non-fatal/test-split pattern)
- file: plan/001_0c8587f91cb2/P2M2T1S2/PRP.md
  why: "The palette auto-sync popup uses `tmux display-popup -E -w 50% -h 50% \"...\"` from the
        loader (THIS task uses 100% + runs it from inside a run-shell binding). Its gotchas carry
        over verbatim: `source-file` rejects shell scripts (load via run-shell on an isolated
        socket); display-popup needs an attached client (live render is MANUAL-ONLY — Level 4;
        test decision+command string via fake-tmux Level 2 + non-fatality via real isolated server
        Level 3); display-popup ≥ 3.2 (older tmux ⇒ unknown command ⇒ graceful)."
  section: "Known Gotchas (testing)", "Validation Loop Level 2/3/4"

# MUST READ — the region CLI surface (what the wrapper invokes + what flags it must NOT pass)
- file: src/cli.zig
  why: "RegionOpts{ target, font, output, open }; parseRegion accepts ONLY --target/--font/--output/--open
        and returns error.UnknownFlag for anything else (NO --history, --full, --visible, --palette,
        --output-dir, --last-output). `region` currently returns error.NotImplemented → exit 1 (body
        lands in P3.M3.T1). ⇒ the wrapper passes ONLY --target #{pane_id}."
  section: "RegionOpts", "parseRegion", "region (dispatch — returns error.NotImplemented)"
- file: src/main.zig
  why: "paneBody is the precedent that region (P3) will mirror: it resolves output-dir via
        capture.resolveOutputDir + history-limit via capture.queryOption (region will read
        @tmux-2html-output-dir/open/font itself). Confirms the binding must NOT pass those flags."
  section: "paneBody (resolveOutputDir/queryOption usage)"

# MUST READ — the .last-output sidecar contract (the cross-task seam with P3.M3.T1.S2)
- file: PRD.md
  why: "§9.3: 'C-o → run-shell a wrapper that launches the full-screen popup: tmux display-popup
        -E -w 100% -h 100% \"$TMUX_2HTML_BIN/tmux-2html region --target #{pane_id} …\"' and 'The
        region path writes the result path to $TMUX_2HTML_BIN/.last-output for the wrapper to
        display-message.' §7.5: on confirm, 'display the path via tmux message (written to a
        sidecar file the plugin reads, since the popup has no tmux message channel)'; on cancel,
        'exit 1, no output.' §9.1 step 2 (on install failure skip binding). §9.2 (C-o override
        note). §12 (tmux ≥ 3.2 for display-popup). §0 (isolated test sockets). §13 (concurrent
        runs — filenames include session+ts+pid; the sidecar is a known single-writer edge)."
  section: "§7.5", "§9.1", "§9.2", "§9.3", "§12", "§0", "§13"

# MUST READ — verified tmux facts (load-bearing for the popup + the format-expansion + testing)
- file: plan/001_0c8587f91cb2/architecture/research_tmux.md
  why: "Claim 2 (display-popup = real pty; -E close-on-exit; -w/-h % of client; full-screen TUI/
        OSC work inside); Claim 3 (run-shell: no /dev/tty but $TMUX/$TMUX_PANE set — so the
        wrapper CAN call tmux display-message); Claim 4 (#{pane_id} expands in run-shell at fire
        time); Claim 6 (C-o default = rotate-window ⇒ override note); Claim 7 (display-popup ≥ 3.2)."
- file: plan/001_0c8587f91cb2/architecture/findings_and_corrections.md
  section: "§3 tmux integration facts"
  why: "Confirms run-shell has no /dev/tty; $TMUX set in run-shell children; user-options idiom."
- file: plan/001_0c8587f91cb2/P2M2T2S2/research/findings.md
  why: "EVERY load-bearing mechanic is consolidated + verified here: the exact sub-stub to replace
        (§1, verbatim), the region CLI surface + the 'pass only --target' rule (§2), the .last-output
        sidecar contract — location/content/lifecycle + the P3 cross-task agreement (§3), the
        three-layer wrapper quoting derived from the proven O binding (§4), the display-popup facts
        (§5), what 'honor the C-o override note' means (§6), docs state (§7), test mechanics (§8)."

# Doc state (NO changes needed — already complete from P2.M2.T1.S1)
- file: docs/CONFIGURATION.md
  why: "ALREADY documents @tmux-2html-region-key (default C-o, L26), the C-o key-conflict note +
        the C-S-o preservation example (L34–40), and 'pane and region re-read the @tmux-2html-*
        options themselves at runtime' (so the binding passes only --target). The item contract
        ('DOCS: none — keybind in docs + README') ⇒ NO doc changes; the README keybind table is
        P4.M2.T1.S1's job. READ ONLY this task."

# External (stable, primary)
- url: https://man.openbsd.org/tmux#COMMANDS            # display-popup, run-shell, bind-key, display-message
  why: "display-popup -E (close on exit), -w/-h accept % of client; targets the current client; the
        shell-command arg runs in a real pty. run-shell runs a shell command and EXPANDS formats in
        its argument before running it ($TMUX set, no /dev/tty). bind-key (no -T) binds in the prefix
        table. display-message shows on the status line (format-expands its arg)."
  critical: "run-shell expands #{pane_id} at FIRE time → the binding stores it LITERAL and the popup
             child receives the expanded %N; $TMUX_2HTML_BIN MUST be expanded at SOURCE time (exported
             vars don't reach run-shell children). display-popup needs an attached client (manual-only
             to render); ≥ tmux 3.2."
- url: https://man.openbsd.org/tmux#FORMATS             # #{pane_id}
  why: "#{pane_id} is the live target pane id (%N) at the moment the binding fires. region resolves
        the session itself, so the binding passes only --target #{pane_id}."
```

### Current Codebase tree (relevant subset)

```bash
tmux-2html.tmux       # FILLED by P2.M2.T1.S1 + P2.M2.T2.S1. §1–§4 + O+visible bindings + C-o SUB-STUB + autosync. ← EDIT (replace C-o sub-stub ONLY)
src/cli.zig           # RegionOpts/parseRegion — the region CLI surface (ONLY --target/--font/--output/--open).   ← READ ONLY
src/main.zig          # paneBody precedent — region (P3) will read options itself like pane does.                  ← READ ONLY
docs/CONFIGURATION.md # ALREADY documents region-key + C-o conflict note (L26, L34–40). NO change needed.          ← READ ONLY
PRD.md                # §7.5, §9.1–§9.3, §12, §0, §13.                                                              ← READ ONLY
build.zig build.zig.zon src/*.zig scripts/   # no Zig/build changes this task.                                     ← DO NOT TOUCH
```

### Desired Codebase tree with file responsibilities

```bash
tmux-2html.tmux       # C-o SUB-STUB replaced by: the region bind-key (gated binary_ready) — a run-shell wrapper that
                      #   clears $BIN/.last-output, runs display-popup -E -w 100% -h 100% "...region --target #{pane_id}",
                      #   then reads .last-output and display-messages the path — + optional region_bound debug append.
# (No new files; no Zig/build/docs changes; §1–§4, O+visible bindings block, autosync block untouched.)
```

### Known Gotchas of our codebase & Library Quirks

```sh
# CRITICAL (three-layer quoting — derived from the PROVEN O binding, research/findings.md §4): the
#   bind-key command string is built by sh at SOURCE time, but RUN by run-shell's /bin/sh at FIRE time
#   (which first expands #{pane_id}), and the display-popup arg is then run in a popup pty shell. So:
#     * $TMUX_2HTML_BIN  → expanded by sh NOW (unescaped, inside double quotes). MUST be the absolute
#       bin path in the stored binding (exported vars do NOT reach run-shell children — inherited
#       from P2.M2.T2.S1/P2.M2.T1.S1). It appears 3× (last=, the binary path, .last-output) — all expand now.
#     * #{pane_id}       → NOT special to sh → stored LITERAL → run-shell expands it at fire time →
#       display-popup's child receives the literal %N (no double-format-expansion).
#     * \"               → literal " (the inner quotes for last=, display-popup's command arg, the
#       [ -f ], cat, and display-message's arg).
#     * \$(cat ...)      → literal $(cat ...) (deferred to fire time).
#     * \$last / \$out   → literal $last / $out (deferred to fire time).
#   Use intermediate `last`/`out` vars to (a) avoid repeating the long path and (b) AVOID a nested
#   `$(cat "...")` inside display-message's double-quoted arg (POSIX-sh nested quotes in $() are
#   subtle). `out=$(cat "$last")` is a SEPARATE assignment; `$out` is then plain in the message.

# CRITICAL (exported vars do NOT reach run-shell children — inherited): a `bind-key … run-shell "$BIN/…"`
#   child inherits the tmux SERVER env, not the transient source-shell env. $TMUX_2HTML_BIN was only a
#   loader `export` ⇒ it is NOT in the server env. So $TMUX_2HTML_BIN MUST be interpolated into the
#   bind-key string at source time. The popup child (region) likewise does NOT see $TMUX_2HTML_BIN ⇒
#   region (P3) must derive its OWN bin dir to write .last-output (this task only READS $BIN/.last-output).

# CRITICAL (.last-output sidecar contract with P3.M3.T1.S2 — research/findings.md §3): region writes
#   the BARE output path to a file named `.last-output` in its OWN executable dir (= $TMUX_2HTML_BIN).
#   The wrapper reads `"$TMUX_2HTML_BIN/.last-output"` (BIN expanded at source time). Content = bare
#   path, NO "wrote" prefix (the wrapper prepends it). On CANCEL region exits 1 WITHOUT writing; the
#   wrapper's pre-popup `rm -f "$last"` guarantees no stale message. region MUST only WRITE on confirm.

# GOTCHA: do NOT pass --font/--open/--output-dir/--history to region from the binding. src/cli.zig
#   parseRegion has NO --output-dir/--history flags (UnknownFlag); region reads font/open/output-dir
#   itself via `tmux show-option` at runtime (mirrors pane — docs/CONFIGURATION.md "How options are
#   read"). Passing them errors / duplicates the source of truth. The binding passes ONLY --target.

# GOTCHA: clear .last-output BEFORE the popup (`rm -f "$last"`). Without it, a prior run's stale path
#   would survive a cancel and the `[ -f ]` test would flash a bogus message. The rm + the cancel-
#   never-writes contract together make cancel silent. (Concurrent C-o presses race on the single
#   shared sidecar — accepted v1 edge, PRD §13 spirit; single-client is the assumption.)

# GOTCHA: end the wrapper with `if … fi` (returns 0), NOT `… && display-message` (which returns 1 on
#   the cancel short-circuit and may make run-shell log an error). The if-block is robustly exit-0.

# GOTCHA: display-popup needs an ATTACHED CLIENT; a detached test server errors "no current client".
#   So the live popup render is MANUAL-ONLY (Level 4). Test the decision + exact command string via a
#   fake-tmux stub (Level 2) + the sidecar logic via extracting the stored wrapper body (Level 2
#   sub-case); prove non-fatality + binding storage via the real isolated server (Level 3).

# GOTCHA: display-popup requires tmux ≥ 3.2 (PRD §12). On older tmux `display-popup` is "unknown
#   command" → at FIRE time the popup silently fails to open (the wrapper's `if [ -f ]` then finds no
#   .last-output → no message); graceful, no crash. NOT gated at source time (mirrors the autosync
#   popup's non-fatal philosophy). bind-key itself only STORES the string (source time) — it succeeds
#   regardless of tmux version.

# GOTCHA: bind-key with NO -T binds in the PREFIX (root) table (PROVEN, P2.M2.T2.S1 TEST F) = PRD §9.3.
#   Do not add -T root. Either omit -T or use -T prefix.

# GOTCHA: the loader MUST NOT `set -e` and must NEVER return non-zero (a sourced plugin cannot abort
#   the user's source-file). A failing bind-key (invalid key token) just prints tmux's error and
#   sourcing continues. Gate on `[ "$binary_ready" = 1 ]` so a missing binary binds nothing.

# GOTCHA (POSIX portability): `[ ]` not `[[ ]]`; `=` not `==`; `$( )` not backticks; quote every
#   expansion; no arrays; no `local`. `/bin/sh` here is bash-as-sh but the script must run under
#   dash/ash too (shellcheck -s sh enforces it). The `\"` / `\$( )` / `\$var` escapes are POSIX-clean.

# GOTCHA (debug seam ordering): §4 writes TMUX_2HTML_DEBUG with `>` (truncate). This task's optional
#   region_bound append MUST use `>>` AND run AFTER §4 in file order. The C-o block sits AFTER the
#   O+visible bindings block and BEFORE the autosync block in the file; both the O-block and this
#   block append with `>>` after §4 ⇒ no truncation/conflict.

# GOTCHA (testing): `tmux source-file ./tmux-2html.tmux` FAILS (tmux parses source-file content as tmux
#   commands, not shell). Load via `run-shell` (propagates $TMUX) on an ISOLATED socket. For the
#   deterministic decision+command-string tests use a fake-tmux stub (Level 2); the live popup is
#   manual (Level 4). NEVER touch the user's running server (PRD §0).
```

## Implementation Blueprint

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: MODIFY tmux-2html.tmux — REPLACE the C-o sub-stub with the region bind-key
  - LOCATE the sub-stub (quoted verbatim in research/findings.md §1), currently the 5-line block:
        # ------------------------------------------------------------------
        # C-o region binding — P2.M2.T2.S2 (display-popup wrapper + .last-output sidecar)
        # Consumes: $region_key, $TMUX_2HTML_BIN, $binary_ready. NOT implemented here.
        # ------------------------------------------------------------------
        # ----------------------------------------------------------------------
    (sits between the O+visible bindings block and the `## Palette auto-sync popup` block.)
  - REPLACE it with the Implementation Patterns block below (the region bind-key, gated on
    binary_ready, + the optional region_bound debug append). Keep ONE separator line before the
    autosync block (mirror the O-block's trailing separator) so the autosync header is clean.
  - IMPLEMENT (see Implementation Patterns): `[ "$binary_ready" = 1 ] && tmux bind-key
    "$region_key" run-shell "<wrapper>"` where <wrapper> = `last="$BIN/.last-output"; rm -f "$last";
    tmux display-popup -E -w 100% -h 100% "$BIN/tmux-2html region --target #{pane_id}"; if [ -f
    "$last" ]; then out=$(cat "$last"); tmux display-message "tmux-2html: wrote $out"; fi` — with the
    source-time escaping (`\"`, `\$( )`, `\$last`, `\$out`, `$TMUX_2HTML_BIN` expanded, `#{pane_id}`
    literal) shown verbatim in Implementation Patterns.
  - CONSUMES: $region_key (§3), $TMUX_2HTML_BIN (§1), $binary_ready (§2). DOES NOT touch §1–§4,
    the O+visible bindings block, or the autosync block.
  - NAMING: region_bound (snake_case debug flag; lowercase) if the debug append is included.
  - GUARD: every path ends cleanly (no set -e; the `[ ] && …` idiom + the wrapper's `if…fi` are
    robustly exit-0).

Task 2: VALIDATE (every command verified — see Validation Loop)
  - sh -n tmux-2html.tmux; shellcheck -s sh; bashism grep.
  - Level 2 fake-tmux: defaults ⇒ one C-o bind-key w/ display-popup -E -w 100% -h 100% + region
    --target + #{pane_id} literal + .last-output + display-message + $BIN expanded; binary_ready=0
    ⇒ no bind-key; region-key "C-S-o" ⇒ key C-S-o.
  - Level 2 sidecar sub-case: extract the stored wrapper body, run it with a fake tmux + fake
    region (writes .last-output) ⇒ display-message fires; region exits without writing ⇒ no
    display-message (cancel; stale cleared by rm).
  - Level 3 real isolated server via run-shell: non-crash (exit 0) + list-keys shows prefix-table
    C-o with the wrapper body (display-popup fails "no current client" but the loader is non-fatal).
  - Level 4 manual: real client, prefix C-o opens the popup (region exits 1 until P3; once P3
    lands, confirm writes .last-output + status-line "tmux-2html: wrote <path>").
```

### Implementation Patterns & Key Details

```sh
# ===== the block that REPLACES the C-o sub-stub (verbatim-ready; derived from the PROVEN O binding) =====
# ------------------------------------------------------------------
# C-o region binding — P2.M2.T2.S2 (display-popup wrapper + .last-output sidecar)
# ------------------------------------------------------------------
# PRD §9.3 + §7.5: prefix <region_key> (default C-o) opens a full-screen tmux
# display-popup (a REAL pty — run-shell has no /dev/tty, so the region TUI + the
# palette can only run inside the popup) running `tmux-2html region --target
# #{pane_id}`. region resolves font/open/output-dir itself via show-option (do NOT
# pass them — mirrors pane). The popup has NO tmux message channel, so on confirm
# region writes the bare result path to $TMUX_2HTML_BIN/.last-output; after the
# popup closes this wrapper reads it and flashes `tmux-2html: wrote <path>` on the
# status line (the wrapper runs in run-shell's /bin/sh, which HAS $TMUX). On cancel
# region exits 1 without writing; the pre-popup `rm -f` keeps the sidecar absent so
# no stale message. Gated on binary_ready (§9.1). region itself lands in P3 (it
# currently returns NotImplemented/exit 1, so until P3 the popup opens then closes
# and shows nothing — inert but correct). No set -e.
#
# Quoting (three layers — derived from the proven O binding, P2.M2.T2.S1):
#   $TMUX_2HTML_BIN  → expanded NOW (exported vars don't reach run-shell children).
#   #{pane_id}       → stored LITERAL (run-shell expands it at fire time).
#   \"  \$( )  \$last  \$out  → deferred to fire time (run-shell's /bin/sh).
# `last`/`out` vars avoid repeating the path AND avoid a nested $(cat "...") inside
# display-message's double-quoted arg. The trailing if…fi returns 0 (cancel is silent).
[ "$binary_ready" = 1 ] && tmux bind-key "$region_key" run-shell \
    "last=\"$TMUX_2HTML_BIN/.last-output\"; rm -f \"\$last\"; tmux display-popup -E -w 100% -h 100% \"$TMUX_2HTML_BIN/tmux-2html region --target '#{pane_id}'\"; if [ -f \"\$last\" ]; then out=\$(cat \"\$last\"); tmux display-message \"tmux-2html: wrote \$out\"; fi"

# Optional test seam (APPEND with >>; §4 already wrote with > and runs first in file order).
if [ -n "${TMUX_2HTML_DEBUG:-}" ]; then
    printf 'region_bound=%s\n' "$([ "$binary_ready" = 1 ] && echo 1 || echo 0)" >> "$TMUX_2HTML_DEBUG"
fi
# ----------------------------------------------------------------------

# WHY display-popup not run-shell for the TUI: run-shell has no /dev/tty (the region TUI needs
#   alt-screen/raw-termios/mouse + a working tty for the palette); display-popup is a real pty
#   (research_tmux.md Claim 2/3). The wrapper ITSELF runs in run-shell (so it HAS $TMUX to call
#   display-message after the popup closes).
# WHY a .last-output sidecar (not region calling display-message directly): the popup child has no
#   reliable tmux message channel back to the user's server; run-shell's stdout auto-display is
#   context-dependent and lacks the `tmux-2html:` prefix. region writes the path to a file the
#   wrapper reads (PRD §7.5 + §9.3).
# WHY rm -f before the popup: clears any STALE .last-output so a cancel never flashes an old path.
# WHY if…fi (not &&): the cancel path ([ -f ] false) must not leave run-shell with a non-zero exit
#   (which tmux may log). if…fi is robustly exit-0.
# WHY --target only: parseRegion (src/cli.zig) accepts ONLY --target/--font/--output/--open and
#   region reads font/open/output-dir itself via show-option (docs/CONFIGURATION.md "How options
#   are read"). Passing --output-dir/--history errors; --font/--open duplicate the truth.
# WHY no version gate at source time: display-popup ≥ 3.2 (PRD §12); bind-key only STORES the
#   string at source time (succeeds on any tmux). On < 3.2 the popup silently fails to open at
#   fire time (graceful; no .last-output ⇒ no message). Mirrors the autosync popup's non-fatal
#   philosophy.
```

### Integration Points

```yaml
LOADER (tmux-2html.tmux):
  - consumes: $region_key (§3), $TMUX_2HTML_BIN (§1), $binary_ready (§2).
  - produces: prefix-table bind-key (<region_key> → region-overlay wrapper); optional region_bound
    in TMUX_2HTML_DEBUG (>>).
  - does NOT touch §1–§4, the O+visible bindings block (P2.M2.T2.S1), or the autosync block (P2.M2.T1.S2).
REGION (P3.M3.T1, NOT YET DONE): the popup runs `tmux-2html region --target #{pane_id}`. region
  resolves font/open/output-dir from @tmux-2html-* itself (mirrors pane); on confirm writes the
  BARE output path to `.last-output` in its OWN executable dir (= $TMUX_2HTML_BIN) and exits 0;
  on cancel exits 1 WITHOUT writing. Until P3, region returns NotImplemented/exit 1 ⇒ the popup
  opens then closes via -E, .last-output stays absent, no message (inert-but-correct).
TMUX RUNTIME: display-popup = real pty (≥ 3.2, PRD §12); run-shell expands #{pane_id} at fire
  time; display-message shows on the firing client's status line. display-popup needs an attached
  client (manual-only to render; older tmux ⇒ graceful silent failure).
TEST ISOLATION (PRD §0): tests use a uniquely-named isolated socket (`tmux -L t2h-...`) loaded
  via run-shell for the non-crash + binding-storage check, a fake-tmux stub for the deterministic
  decision/command-string + sidecar-logic tests. Never touch the user's running server. The live
  popup is manual (Level 4).
BUILD/PACKAGE: NO CHANGE — tmux-2html.tmux is already in build.zig.zon .paths; no Zig/docs changes.
DOCS: NO CHANGE — docs/CONFIGURATION.md already documents @tmux-2html-region-key (default C-o) +
  the C-o conflict note (L26, L34–40); the README keybind table is P4.M2.T1.S1's job.
```

## Validation Loop

### Level 1: Syntax & Style (after editing the loader)

```bash
sh -n tmux-2html.tmux && echo "syntax OK"           # POSIX syntax (mandatory)
command -v shellcheck >/dev/null && shellcheck -s sh tmux-2html.tmux || echo "shellcheck N/A"
# Bashism scan (dash would reject these): expect ZERO hits in the NEW block.
grep -nE '\[\[|==|BASH_SOURCE|declare |local |let |<\(' tmux-2html.tmux || echo "no bashisms"
# Expected: "syntax OK"; shellcheck clean (the `\"`/`\$( )`/`\$var` escapes, `${var:-}`, `if…fi`
# are POSIX-clean) or N/A; "no bashisms".
```

### Level 2: Decision + exact command string + sidecar logic (PRIMARY — fake tmux, no real server, deterministic)

```bash
# Stub `tmux` so we can exercise the loader WITHOUT a server. The fake records bind-key argv to a
# log; returns empty for show-option (unset ⇒ defaults via read_opt); no-ops everything else.
work=$(mktemp -d); fakebin="$work/fakebin"; pm="$work/pm"; bin="$work/bin"
mkdir -p "$fakebin" "$pm" "$bin"
cat > "$fakebin/tmux" <<'EOF'
#!/usr/bin/env sh
case "$1" in
  show-option) printf '';;                 # unset ⇒ empty (read_opt applies defaults)
  display-message) :;;                     # no-op
  bind-key)
    printf 'key=%s\n' "$2" >> "$T2H_BIND_LOG"
    printf 'body=%s\n' "$4" >> "$T2H_BIND_LOG"
    ;;
esac
EOF
chmod +x "$fakebin/tmux"
: > "$bin/tmux-2html"; chmod +x "$bin/tmux-2html"     # binary_ready=1 fast-path
mkdir -p "$work/home"

# ---- (a) DEFAULTS + binary ready ⇒ exactly ONE region bind-key (C-o) with the right shape. ----
rm -f "$work/bind.log"; export T2H_BIND_LOG="$work/bind.log"
PATH="$fakebin:$PATH" HOME="$work/home" TMUX_PLUGIN_MANAGER_PATH="$pm" \
  TMUX_2HTML_BIN="$bin" sh ./tmux-2html.tmux
# (O + region both bind; visible is unset. We assert the REGION bind-key specifically.)
grep -qx 'key=C-o' "$work/bind.log" && echo "PASS a: region key = C-o (default)"
# The region body is the line after 'key=C-o'; grab it and assert its shape.
body=$(awk 'prev=="key=C-o"{print; exit} {prev=$0}' "$work/bind.log" | sed 's/^body=//')
echo "$body" | grep -q 'display-popup -E -w 100% -h 100%' && echo "PASS a: display-popup 100% fullscreen"
echo "$body" | grep -q 'region --target' && echo "PASS a: invokes region"
echo "$body" | grep -q "target '#{pane_id}'" && echo "PASS a: #{pane_id} stored LITERALLY"
echo "$body" | grep -q '\.last-output' && echo "PASS a: reads .last-output sidecar"
echo "$body" | grep -q 'display-message' && echo "PASS a: notify via display-message"
echo "$body" | grep -qF "$bin/tmux-2html" && echo "PASS a: \$TMUX_2HTML_BIN expanded at source time"
# visible must NOT be present:
grep -q 'pane --visible' "$work/bind.log" && echo "FAIL a: visible bound by default" || echo "PASS a: no visible bind (unset)"

# ---- (b) @tmux-2html-region-key "C-S-o" ⇒ the region bind-key uses C-S-o (override honored). ----
cat > "$fakebin/tmux" <<'EOF'
#!/usr/bin/env sh
case "$1" in
  show-option) case "$3" in *@tmux-2html-region-key*) printf 'C-S-o';; *) printf '';; esac;;
  display-message) :;;
  bind-key) printf 'key=%s\n' "$2" >> "$T2H_BIND_LOG"; printf 'body=%s\n' "$4" >> "$T2H_BIND_LOG";;
esac
EOF
chmod +x "$fakebin/tmux"
rm -f "$work/bind.log"; export T2H_BIND_LOG="$work/bind.log"
PATH="$fakebin:$PATH" HOME="$work/home" TMUX_PLUGIN_MANAGER_PATH="$pm" TMUX_2HTML_BIN="$bin" sh ./tmux-2html.tmux
{ grep -qx 'key=O' "$work/bind.log" && grep -qx 'key=C-S-o' "$work/bind.log"; } && echo "PASS b: keys O and C-S-o (override honored)"
grep -qx 'key=C-o' "$work/bind.log" && echo "FAIL b: default C-o still bound" || echo "PASS b: default C-o NOT bound when overridden"

# ---- (c) binary NOT ready (missing executable) ⇒ NO region bind-key. ----
rm -f "$bin/tmux-2html"
cat > "$fakebin/tmux" <<'EOF'
#!/usr/bin/env sh
case "$1" in show-option) printf '';; display-message|bind-key) :;; esac
EOF
chmod +x "$fakebin/tmux"
rm -f "$work/bind.log"; export T2H_BIND_LOG="$work/bind.log"
PATH="$fakebin:$PATH" HOME="$work/home" TMUX_PLUGIN_MANAGER_PATH="$pm" TMUX_2HTML_BIN="$bin" sh ./tmux-2html.tmux
[ ! -s "$work/bind.log" ] && echo "PASS c: binary_ready gate held (no bind-keys when binary absent)"

# ---- (d) SIDECAR LOGIC: extract the region wrapper body and run it with a fake tmux + fake region. ----
# Restore the all-empty fake + the dummy binary, re-bind to capture the region body cleanly.
: > "$bin/tmux-2html"; chmod +x "$bin/tmux-2html"
cat > "$fakebin/tmux" <<'EOF'
#!/usr/bin/env sh
case "$1" in show-option) printf '';; display-message|bind-key) :;; esac
EOF
chmod +x "$fakebin/tmux"
rm -f "$work/bind.log"; export T2H_BIND_LOG="$work/bind.log"
PATH="$fakebin:$PATH" HOME="$work/home" TMUX_PLUGIN_MANAGER_PATH="$pm" TMUX_2HTML_BIN="$bin" sh ./tmux-2html.tmux
region_body=$(awk 'prev=="key=C-o"{print; exit} {prev=$0}' "$work/bind.log" | sed 's/^body=//')
printf '%s\n' "$region_body" > "$work/region_wrapper.sh"

# A fake region that WRITES the path on "confirm" (writes $TMUX_2HTML_BIN/.last-output then exits 0).
cat > "$bin/tmux-2html" <<'EOF'
#!/usr/bin/env sh
# only the `region` subcommand writes the sidecar; echo the path region would render.
case "$1" in
  region) printf '%s/x.html\n' "$TMUX_2HTML_BIN" > "$TMUX_2HTML_BIN/.last-output"; exit 0;;
  *) exit 0;;
esac
EOF
chmod +x "$bin/tmux-2html"
# A fake tmux that records display-message (and fakes display-popup by RUNNING its arg, so region
# actually executes and writes the sidecar — simulating the popup pty running the command).
msglog="$work/msg.log"; rm -f "$msglog"
cat > "$fakebin/tmux" <<EOF
#!/usr/bin/env sh
case "\$1" in
  display-popup) shift; while [ \$# -gt 0 ]; do [ "\$1" = "-E" ] && popen=1; [ -n "\$popen" ] && cmd="\$cmd \$1"; shift; done; sh -c "\$cmd";;
  display-message) printf '%s\n' "\$*" >> "$msglog";;
  show-option) printf '';;
esac
EOF
chmod +x "$fakebin/tmux"
# CONFIRM path: region writes .last-output ⇒ wrapper should display-message "tmux-2html: wrote <path>".
rm -f "$bin/.last-output"
PATH="$fakebin:$PATH" TMUX_2HTML_BIN="$bin" sh "$work/region_wrapper.sh"
grep -q 'tmux-2html: wrote' "$msglog" && grep -q 'x.html' "$msglog" && echo "PASS d-confirm: display-message fired with the rendered path"

# CANCEL path: a fake region that exits 1 WITHOUT writing .last-output.
cat > "$bin/tmux-2html" <<'EOF'
#!/usr/bin/env sh
case "$1" in region) exit 1;; *) exit 0;; esac
EOF
chmod +x "$bin/tmux-2html"
rm -f "$msglog"; rm -f "$bin/.last-output"
PATH="$fakebin:$PATH" TMUX_2HTML_BIN="$bin" sh "$work/region_wrapper.sh"
[ ! -s "$msglog" ] && echo "PASS d-cancel: NO display-message on cancel (region wrote no sidecar)"
rm -rf "$work"
# Expected: PASS a (C-o, display-popup 100%, region, #{pane_id} literal, .last-output, display-message,
#   BIN expanded, no visible), PASS b (C-S-o override), PASS c (gate), PASS d-confirm (message fires),
#   PASS d-cancel (no message).
```

### Level 3: Real isolated tmux server (§0-compliant; non-crash + prefix-table proof)

```bash
# IMPORTANT (PRD §0): use a UNIQUE isolated socket; NEVER the user's server. Load via run-shell
# (source-file REJECTS shell scripts). display-popup needs a client, so against this detached
# server it errors "no current client" at FIRE time — but we only assert SOURCE-time binding
# storage + non-fatality here (the wrapper's display-popup is never fired in this check).
sock="t2h-it-$$"
tmux -L "$sock" -f /dev/null new-session -d -s t2h
work=$(mktemp -d); pm="$work/pm"; bin="$work/bin"; mkdir -p "$pm" "$bin"
: > "$bin/tmux-2html"; chmod +x "$bin/tmux-2html"     # binary_ready=1
tmux -L "$sock" set-environment TMUX_PLUGIN_MANAGER_PATH "$pm"
tmux -L "$sock" set-environment TMUX_2HTML_BIN "$bin"
tmux -L "$sock" set-environment TMUX_2HTML_DEBUG "$work/debug.env"

# (1) Defaults: loader must complete cleanly + bind C-o in the prefix table with the wrapper body.
tmux -L "$sock" run-shell "sh $(pwd)/tmux-2html.tmux"; echo "run-shell-exit=$?"
sleep 0.3
echo "--- list-keys -T prefix C-o ---"
lk=$(tmux -L "$sock" list-keys -T prefix C-o 2>&1)
echo "$lk"
echo "$lk" | grep -q 'display-popup' && echo "PASS: C-o bound to the display-popup wrapper"
echo "$lk" | grep -q 'region --target' && echo "PASS: wrapper invokes region"
echo "$lk" | grep -q '100%' && echo "PASS: full-screen popup"
echo "$lk" | grep -q 'last-output' && echo "PASS: wrapper reads .last-output"
echo "$lk" | grep -q 'display-message' && echo "PASS: wrapper notifies via display-message"
echo "$lk" | grep -q 'pane_id' && echo "PASS: target uses #{pane_id}"
echo "$lk" | grep -qF "$bin/tmux-2html" && echo "PASS: \$TMUX_2HTML_BIN expanded in stored binding"
# Debug seam recorded the region decision:
grep -qx 'region_bound=1' "$work/debug.env" 2>/dev/null && echo "PASS: region_bound=1"

# (2) Override: set region-key to C-S-o ⇒ reload ⇒ C-S-o bound, C-o not.
tmux -L "$sock" set -g @tmux-2html-region-key "C-S-o"
rm -f "$work/debug.env"
tmux -L "$sock" run-shell "sh $(pwd)/tmux-2html.tmux"; sleep 0.3
tmux -L "$sock" list-keys -T prefix C-S-o 2>&1 | grep -q 'display-popup' && echo "PASS: C-S-o bound after override"
tmux -L "$sock" list-keys -T prefix C-o 2>&1 | grep -q 'display-popup' \
  && echo "FAIL: default C-o still bound" || echo "PASS: default C-o freed when overridden"

# (3) Non-crash when binary is absent (binary_ready=0 ⇒ no region bind-key; loader still exits clean).
tmux -L "$sock" set-environment TMUX_2HTML_BIN "/nonexistent/bin"
rm -f "$work/debug.env"
tmux -L "$sock" run-shell "sh $(pwd)/tmux-2html.tmux"; echo "no-binary run-shell-exit=$?"
grep -qx 'region_bound=0' "$work/debug.env" 2>/dev/null && echo "PASS: no region bind when binary_ready=0"
tmux -L "$sock" list-sessions >/dev/null 2>&1 && echo "PASS: server alive (non-fatal)"

tmux -L "$sock" kill-server; rm -rf "$work"
# Expected: all PASS lines; server stays alive; C-o (then C-S-o) bound in the prefix table with the
# correct wrapper body; binary_ready=0 ⇒ no region bind.
```

### Level 4: Manual / interactive (real attached client — NOT in CI)

```bash
# In a REAL tmux session (attached client), with the binary installed:
#   1. Source the plugin (or restart tmux / prefix I).
#   2. Press:  prefix C-o
#      UNTIL P3: expect the full-screen popup to flash open, run `tmux-2html region` (which exits 1
#      with "this subcommand is not yet implemented"), and close via -E. NO status-line message
#      (region wrote no .last-output). This proves the binding + popup wiring; the TUI is P3.
#   3. ONCE P3 LANDS: prefix C-o opens the overlay; move/select; press Enter.
#      Expect: a file appears under ${XDG_DATA_HOME:-~/.local/share}/tmux-2html/ named
#      <session>-<ts>-<pid>.html, the popup closes, AND the status line flashes:
#        tmux-2html: wrote <abs/path>.html
#      Verify the sidecar was consumed + cleaned: after the popup closes, .last-output may still
#      hold the last path (the wrapper does not rm it after reading — only before the next run);
#      that's fine. Re-running prefix C-o then cancelling shows NO stale message (the pre-popup
#      rm -f cleared it).
cat "$TMUX_2HTML_BIN/.last-output" 2>/dev/null    # the path region wrote (post-confirm)
#   4. Override demo: tmux set -g @tmux-2html-region-key "C-S-o"; re-source; prefix C-S-o opens the
#      overlay; prefix C-o is back to its stock binding (rotate-window / whatever it was).
```

## Final Validation Checklist

### Technical Validation
- [ ] `sh -n tmux-2html.tmux` passes; no bashisms in the new block (Level 1 grep clean).
- [ ] `shellcheck -s sh tmux-2html.tmux` clean (or N/A).
- [ ] Level 2 fake-tmux: defaults ⇒ exactly one `C-o` region bind-key with `display-popup -E -w
      100% -h 100%`, `region --target '#{pane_id}'` (literal), `.last-output`, `display-message`,
      and `$TMUX_2HTML_BIN` expanded; region-key=`C-S-o` ⇒ key `C-S-o`; `binary_ready=0` ⇒ no bind.
- [ ] Level 2 sidecar sub-case: region-writes-path ⇒ `display-message "tmux-2html: wrote <path>"`;
      region-exits-without-writing ⇒ NO `display-message` (cancel; stale cleared by the pre-popup rm).
- [ ] Level 3 real isolated server (run-shell): loader completes cleanly; `C-o` (then `C-S-o`) is
      in the **prefix** table with the correct wrapper body; `binary_ready=0` ⇒ no region bind;
      server stays alive.

### Feature Validation
- [ ] `prefix <region_key>` (default C-o) opens the full-screen `display-popup` running region
      against the firing pane (Level 4 manual).
- [ ] After confirm (P3), the status line flashes `tmux-2html: wrote <path>`; after cancel, nothing.
- [ ] The binding passes ONLY `--target #{pane_id}` (no font/open/output-dir/history).
- [ ] `#{pane_id}` is stored LITERAL (run-shell expands it at fire time); `$TMUX_2HTML_BIN` is
      expanded at source time (exported vars don't reach run-shell children).
- [ ] The binding is gated on `binary_ready=1` (§9.1 "on failure skip binding").
- [ ] The §9.2 C-o override is honored: binding `$region_key` overrides any prior C-o; setting
      `@tmux-2html-region-key` to a different key frees the default C-o.

### Code Quality Validation
- [ ] POSIX-portable (`[ ]`, `=`, `$( )`, quoted expansions, no arrays/`local`, no `set -e`).
- [ ] Three-layer quoting correct (`\"`, `\$( )`, `\$last`, `\$out` escaped; `$TMUX_2HTML_BIN`
      expanded; `#{pane_id}` literal). Intermediate `last`/`out` vars avoid nested `$(cat "...")`.
- [ ] Wrapper ends with `if … fi` (robustly exit-0; cancel is silent, no run-shell error log).
- [ ] Pre-popup `rm -f "$last"` clears stale `.last-output` (cancel never flashes an old path).
- [ ] Debug append uses `>>` and runs after §4's `>` (file order) — no truncation/conflict.
- [ ] §1–§4, the O+visible bindings block, and the autosync block are untouched.
- [ ] No Zig/build/docs changes; `PRD.md`/`tasks.json`/`prd_snapshot.md`/`.gitignore` untouched.

### Documentation & Deployment
- [ ] No doc changes (item contract "DOCS: none"); docs/CONFIGURATION.md already documents
      `@tmux-2html-region-key` (default C-o) + the C-o conflict note (L26, L34–40); the README
      keybind table is P4.M2.T1.S1's job.
- [ ] No new env vars; no packaging change (`tmux-2html.tmux` already in build.zig.zon .paths).

---

## Anti-Patterns to Avoid

- ❌ Don't pass `--font`/`--open`/`--output-dir`/`--history` to region from the binding —
  `src/cli.zig` `parseRegion` has **no** `--output-dir`/`--history` flags (`error.UnknownFlag`);
  region reads font/open/output-dir itself via `show-option` (mirrors `pane`; confirmed in
  `docs/CONFIGURATION.md` "How options are read"). The binding passes ONLY `--target #{pane_id}`.
- ❌ Don't escape `#{pane_id}` or try to expand it in sh — run-shell expands it at **fire time**.
  Store it LITERAL (it's not special to sh inside double quotes). (PROVEN in P2.M2.T2.S1 TEST A.)
- ❌ Don't forget to escape `\"`, `\$( )`, `\$last`, `\$out` — without the backslashes sh expands
  them at source time and the stored binding breaks. (Derived from the PROVEN O binding escaping.)
- ❌ Don't write `display-message "tmux-2html: wrote $(cat "$last")"` (nested command-substitution
  inside a double-quoted arg is subtle in POSIX sh). Assign `out=$(cat "$last")` FIRST, then use
  the plain `$out` in the message.
- ❌ Don't omit the pre-popup `rm -f "$last"` — without it a prior run's stale path survives a
  cancel and the `[ -f ]` test flashes a bogus message.
- ❌ Don't chain the post-popup step with `&&` (`[ -f ] && … && display-message`) — the cancel
  short-circuit leaves run-shell with exit 1, which tmux may log. Use `if … fi` (robustly exit-0).
- ❌ Don't try to call `tmux display-message` FROM region inside the popup — the popup has no
  reliable tmux message channel (PRD §7.5). region writes `.last-output`; the wrapper (run-shell,
  which HAS `$TMUX`) reads it and messages. That split IS the design.
- ❌ Don't expect region to see `$TMUX_2HTML_BIN` — exported loader vars don't reach run-shell
  children OR the popup child (server env). The WRAPPER interpolates `$TMUX_2HTML_BIN` at source
  time (3×); REGION (P3) must derive its OWN bin dir to write `.last-output`. This task only READS.
- ❌ Don't version-gate the bind-key at source time — `bind-key` only STORES the string (succeeds on
  any tmux); `display-popup` (≥ 3.2) is evaluated at FIRE time and fails gracefully on older tmux
  (no popup, no `.last-output`, no message). Mirror the autosync popup's non-fatal philosophy.
- ❌ Don't `set -e` or return non-zero — a sourced plugin cannot abort the user's `source-file`.
- ❌ Don't omit the `binary_ready` gate — `§9.1` requires "on failure skip binding".
- ❌ Don't use `-T root` — in tmux the prefix table IS the root table; omit `-T` (or use `-T prefix`).
- ❌ Don't implement the region TUI / confirm-cancel (P3.M3.T1) or touch the autosync block
  (P2.M2.T1.S2) / O+visible bindings (P2.M2.T2.S1) — this task is the binding + wrapper + sidecar
  READ only.
- ❌ Don't modify docs — `docs/CONFIGURATION.md` already covers the region key + C-o conflict note.
- ❌ Don't test via `tmux source-file ./tmux-2html.tmux` (it rejects shell scripts) — load via
  `run-shell` on an ISOLATED socket (Level 3); use a fake-`tmux` stub for the deterministic checks
  + the sidecar logic (Level 2); render the popup manually with a real client (Level 4).
- ❌ Don't touch the user's running tmux server in tests — use a unique isolated socket (`tmux -L
  t2h-…`) and tear down only that socket.

---

**Confidence Score: 9/10**

This is a small, well-scoped POSIX-sh task, and every load-bearing mechanic is **empirically
grounded**: the exact 5-line sub-stub to replace is quoted verbatim from the live file; the
three-layer wrapper quoting is **derived from the PROVEN O binding** (P2.M2.T2.S1 ran the same
`\"`/`\$( )`/`\$out` escaping + `$TMUX_2HTML_BIN`-expanded-at-source-time + `#{pane_id}`-literal
end-to-end against tmux 3.6b); the display-popup mechanics (real pty, `-E`, `-w/-h %`, needs a
client, ≥ 3.2) and the run-shell facts (no /dev/tty but `$TMUX` set; expands `#{pane_id}` at fire
time) are verified in `architecture/research_tmux.md` and exercised by the sibling autosync-popup
task; the region CLI surface (ONLY `--target/--font/--output/--open`; region reads options itself)
is pinned to `src/cli.zig` + `docs/CONFIGURATION.md`; and the `.last-output` sidecar contract
(location/content/lifecycle) is pinned to PRD §9.3 + §7.5 with the P3 cross-task agreement stated
explicitly. The decision logic + exact command string are deterministically testable via a
fake-tmux stub (Level 2), the sidecar logic is testable by extracting + running the stored wrapper
body (Level 2 sub-case), non-fatality + binding storage via the real isolated server (Level 3),
and the live popup render is manual (Level 4). The task is explicitly **inert-but-correct until
P3** (region returns NotImplemented/exit 1 ⇒ popup opens then closes, no message), so it can be
landed and validated now. The one residual risk — matching the three-layer escaping byte-for-byte
— is mitigated by giving the exact proven-derived line verbatim and by dedicated Level 2/3
assertions on the stored binding string + a Level 2 sidecar run.
