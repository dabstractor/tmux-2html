name: "P2.M2.T2.S1 — prefix-table bindings: O (full pane) + visible key (run-shell pane) + display-message notify"
description: |

---

## Goal

**Feature Goal**: Fill the labeled `## Bindings (prefix table)` stub in the already-implemented
`tmux-2html.tmux` loader so that **`prefix O` renders the FULL pane** (scrollback + visible) and,
**only if `@tmux-2html-visible-key` is set**, **`prefix <visible-key>` renders the VISIBLE-only
pane** — both via `tmux run-shell` wrappers around the (DONE) `pane` subcommand, passing
`--target #{pane_id}` (run-shell expands the format at fire time), and **notifying the user via
`tmux display-message "tmux-2html: wrote <file>"`** after the render. Leave a clearly-labeled
sub-stub for the C-o region binding (P2.M2.T2.S2). Do NOT touch the palette auto-sync block.

**Deliverable** (at `/home/dustin/projects/tmux-2html/`):
1. **MODIFY `tmux-2html.tmux`** — REPLACE the existing `## Bindings (prefix table) — P2.M2.T2.S1/S2`
   TODO stub with three things, in this order:
   - the **`O` (full) binding** (gated on `binary_ready`);
   - the **conditional visible binding** (gated on `binary_ready` AND a non-empty `$visible_key`);
   - a **labeled sub-stub** `# C-o region binding — P2.M2.T2.S2 (do not implement here)` so T2.S2
     plugs in cleanly.
   Optionally append `full_bound`/`visible_bound` flags to the `TMUX_2HTML_DEBUG` seam.

**Success Definition**:
- With the binary ready and defaults, sourcing the loader issues exactly one
  `bind-key O run-shell "out=\$(\"$BIN/tmux-2html\" pane --full --target '#{pane_id}' 2>/dev/null); tmux display-message \"tmux-2html: \$out\""`
  (assertable via a fake-`tmux` stub that records `bind-key` argv).
- With `@tmux-2html-visible-key` UNSET ⇒ the loader issues **no** visible `bind-key` (skipped).
- With `@tmux-2html-visible-key "v"` set ⇒ the loader issues a second `bind-key v run-shell "... pane --visible --target '#{pane_id}' ..."`.
- With `binary_ready=0` ⇒ the loader issues **no** bind-keys at all (the §9.1 "on failure skip
  binding" rule).
- In a real attached tmux session: `prefix O` captures the current pane (full), writes
  `<output-dir>/<session>-<ts>-<pid>.html`, and flashes `tmux-2html: wrote <path>` on the status
  line. `prefix <visible-key>` does the same for visible-only.
- `sh -n tmux-2html.tmux` passes; `shellcheck -s sh` clean (or N/A); no bashisms in the new block.
- No Zig/build changes; `PRD.md`/`tasks.json`/`prd_snapshot.md`/`.gitignore` untouched; the
  autosync block and §1–§4 untouched.

## Why

- **PRD §9.3 makes `prefix O` the primary user entry point** for rendering a pane. Without this
  binding the (DONE) `pane` subcommand is unreachable from the keyboard — the plugin produces no
  output. This task is the wire between the user's keypress and the renderer.
- **PRD §9.1 step 2/3**: after resolving BIN + ensuring the binary + reading options, the loader
  must "bind keys (§9.3)" — and skip binding when the binary failed to install.
- **`run-shell` is the only correct context for pane** from a binding: it has no `/dev/tty`
  (verified), which is exactly why pane resolves the palette from the **cache** (not a live OSC
  probe) — the whole cached-palette design (P1.M2) exists for this path. The binding just runs pane.
- **`#{pane_id}` format expansion** lets the binding target the pane the user was in when they
  pressed the key, with zero state plumbing (run-shell expands it at fire time — proven in research).
- **The conditional visible key** keeps the default key table clean (PRD §9.2: visible is empty by
  default ⇒ unbound) while letting power-users opt into a visible-only capture.

## What

### Behavior (`tmux-2html.tmux`, the block that replaces the Bindings stub)

1. **`O` (full) binding** — gated on `[ "$binary_ready" = 1 ]`:
   ```sh
   [ "$binary_ready" = 1 ] && tmux bind-key "$full_key" run-shell \
       "out=\$(\"$TMUX_2HTML_BIN/tmux-2html\" pane --full --target '#{pane_id}' 2>/dev/null); tmux display-message \"tmux-2html: \$out\""
   ```
2. **Visible binding** — gated on `binary_ready` AND a non-empty `$visible_key`:
   ```sh
   if [ -n "$visible_key" ]; then
       [ "$binary_ready" = 1 ] && tmux bind-key "$visible_key" run-shell \
           "out=\$(\"$TMUX_2HTML_BIN/tmux-2html\" pane --visible --target '#{pane_id}' 2>/dev/null); tmux display-message \"tmux-2html: \$out\""
   fi
   ```
3. **C-o region sub-stub** (leave for T2.S2; do NOT implement):
   ```sh
   # ------------------------------------------------------------------
   # C-o region binding — P2.M2.T2.S2 (display-popup wrapper + .last-output)
   # Consumes: $region_key, $TMUX_2HTML_BIN, $binary_ready. NOT implemented here.
   # ------------------------------------------------------------------
   ```
4. (Optional) **`TMUX_2HTML_DEBUG` append** (`>>`; §4 already wrote with `>` and runs first):
   ```sh
   if [ -n "${TMUX_2HTML_DEBUG:-}" ]; then
       { printf 'full_bound=%s\n'    "$([ "$binary_ready" = 1 ] && echo 1 || echo 0)";
         printf 'visible_bound=%s\n' "$([ "$binary_ready" = 1 ] && [ -n "$visible_key" ] && echo 1 || echo 0)"; } >> "$TMUX_2HTML_DEBUG"
   fi
   ```

### What the binding does at FIRE time (run-shell expands `#{pane_id}` → e.g. `%5`, then `/bin/sh` runs)
1. `out=$(... tmux-2html pane --full --target %5 2>/dev/null)` → pane captures the pane, resolves
   output-dir/history/font from options itself, writes `<dir>/<session>-<ts>-<pid>.html`, prints
   `wrote <path>` to stdout (captured into `$out`); stderr suppressed (pane self-notifies on
   truncation).
2. `tmux display-message "tmux-2html: $out"` → flashes `tmux-2html: wrote <path>` on the status
   line of the client that pressed the key.

### Success Criteria
- [ ] Defaults + binary ready ⇒ exactly one `bind-key O run-shell "... pane --full --target '#{pane_id}' ..."`
      with `display-message` in the command string (fake-tmux assertion).
- [ ] `visible-key` unset ⇒ **no** visible bind-key; set to `v` ⇒ a `bind-key v ... pane --visible ...`.
- [ ] `binary_ready=0` ⇒ **no** bind-keys (full or visible).
- [ ] The stored binding string has `#{pane_id}` **literal** (expands at fire time) and `$TMUX_2HTML_BIN`
      **already expanded** to the abs path at source time (assert via `list-keys`/fake-tmux).
- [ ] `sh -n` passes; no bashisms; `shellcheck -s sh` clean (or N/A).
- [ ] No Zig/build/docs changes; autosync block, §1–§4, and the C-o sub-stub left intact.

## All Needed Context

### Context Completeness Check

_Passes the "No Prior Knowledge" test_: the exact stub block to replace is quoted verbatim from the
live `tmux-2html.tmux`; the exact (two-layer-quoted) binding command strings are given verbatim and
were **proven end-to-end against tmux 3.6b + the built binary** (run-shell expanded `#{pane_id}`,
`$(...)` captured pane's `wrote <path>`, `bind-key` stored the quoting correctly); the consumed
loader symbols (`$TMUX_2HTML_BIN`, `$full_key`, `$visible_key`, `$binary_ready`, the no-`set -e`
rule, the `TMUX_2HTML_DEBUG` `>`-then-`>>` ordering) are read from the live §1–§4; and the
runtime pane contract (stdout = `wrote <path>`, stderr = 0 bytes on success, no `--output-dir` flag,
pane reads options itself) is read from `src/main.zig`/`src/cli.zig`. An implementer who has never
seen this codebase can ship it from this PRP + the cited files.

### Documentation & References

```yaml
# MUST READ — the file this task edits (the stub to replace is quoted verbatim in research/findings.md §1)
- file: tmux-2html.tmux
  why: "ALREADY FILLED by P2.M2.T1.S1 (7024 B). Replace the `## Bindings (prefix table) — P2.M2.T2.S1/S2`
        TODO stub with the O(full) binding + conditional visible binding + a C-o sub-stub. Consumes
        $TMUX_2HTML_BIN (§1), $full_key/$visible_key/$binary_ready (§2/§3). Do NOT touch §1–§4 or the
        `## Palette auto-sync popup` block (P2.M2.T1.S2, parallel)."
  pattern: "POSIX sh; no `set -e`; quoted expansions; the §1–§4 + the autosync block are untouched."

# MUST READ — the predecessor contract (produces the loader + symbols this task consumes)
- file: plan/001_0c8587f91cb2/P2M2T1S1/PRP.md
  why: "Defines the loader structure (§1–§4 + bindings stub + autosync stub), the no-crash rule, the
        read_opt idiom, the binary_ready export, and the CRITICAL note: 'exported shell vars do NOT
        reach run-shell children spawned by bind-key' ⇒ interpolate $TMUX_2HTML_BIN DIRECTLY into the
        bind-key string at source time; 'the binary reads output-dir/history-limit/open/font itself
        via show-option — do NOT pass them.' The bindings stub there is the placeholder this task fills."
  section: "Task 4 (sibling stub)", "Known Gotchas (POSIX; vars don't reach run-shell; don't pass options)"

# MUST READ — the runtime pane contract (what the binding invokes)
- file: src/main.zig
  why: "paneBody: on success stdout = `wrote <path>\\n` (summary); on failure stdout = error line + exit
        2; stderr = 0 bytes on success (only the truncation notice on truncation, which pane ALSO
        display-messages itself). pane does NOT emit `display-message \"wrote <file>\"` — that is THIS
        task's job. Target resolves from --target else $TMUX_PANE else exit 2."
  section: "paneBody (~L343–459)", "panePrepare summary lines"
- file: src/cli.zig
  why: "PaneOpts has --target/--visible/--full/--history/--font/--output/--open. NO --output-dir and
        NO --palette. parsePane default mode = visible. ⇒ the binding passes ONLY --target #{pane_id}
        + the mode flag; pane resolves output-dir/history/font/open from @tmux-2html-* itself."
  section: "PaneOpts:70", "pane_help:302"

# MUST READ — the PRD authority for this behavior
- file: PRD.md
  why: "§9.3 bindings (O→run-shell pane --full --target #{pane_id} …; visible key if set → … pane --visible …;
        notify via tmux display-message); §9.1 step 2 (on install failure skip binding); §9.2 options
        (full-key=O, visible-key=empty⇒unbound); §13 (collision-safe filenames — pane handles this)."
  section: "§9.1", "§9.2", "§9.3", "§13"

# MUST READ — verified tmux facts (load-bearing for the quoting + the decision to capture stdout)
- file: plan/001_0c8587f91cb2/architecture/findings_and_corrections.md
  section: "§3 tmux integration facts"
  why: "run-shell children have no /dev/tty but $TMUX/$TMUX_PANE are set; #{pane_id}/#{pane_width}/
        #{pane_height} expand in bindings (run-shell expands formats). Confirms the binding context."
- file: plan/001_0c8587f91cb2/architecture/research_tmux.md
  why: "Claim 4 (#{pane_id} expands inside `bind-key x run-shell 'echo #{pane_id}'` at execution time);
        Claim 3 (run-shell: no tty, $TMUX set); Claim 6 (C-o default = rotate-window ⇒ override note).
        These justify the #{pane_id}-literal-at-store-time design and the visible-key opt-in."
- file: plan/001_0c8587f91cb2/P2M2T2S1/research/findings.md
  why: "EVERY load-bearing mechanic in this PRP is PROVEN here against tmux 3.6b + the built binary:
        TEST A (run-shell expands #{pane_id}→%0); TEST B (the exact wrapper captured `wrote <real path>`);
        TEST C (list-keys shows the stored quoting is correct); TEST F (bind-key w/o -T ⇒ prefix table);
        TEST G (pane stderr = 0 bytes on success). Cite this for the exact command strings + validation."

# External (stable, primary)
- url: https://man.openbsd.org/tmux#COMMANDS            # bind-key, run-shell, display-message
  why: "bind-key (no -T) binds in the prefix/root table; run-shell executes a shell command (and EXPANDS
        formats in its argument before running it); display-message shows on the status line (format-
        expands its arg). Verified empirically — see research/findings.md §4–§7."
  critical: "run-shell expands #{...} at fire time, so the binding stores `#{pane_id}` LITERALLY and lets
             run-shell expand it; $TMUX_2HTML_BIN must be expanded at SOURCE time (exported vars don't
             reach run-shell children)."
- url: https://man.openbsd.org/tmux#FORMATS             # #{pane_id}, #{session_name}
  why: "#{pane_id} is the live target pane id (%N) at the moment the binding fires. pane resolves
        #{session_name} itself, so the binding only needs --target #{pane_id}."
```

### Current Codebase tree (relevant subset)

```bash
tmux-2html.tmux       # FILLED by P2.M2.T1.S1 (7024 B). §1–§4 + bindings STUB + autosync STUB. ← EDIT (replace bindings stub ONLY)
src/main.zig          # paneBody/panePrepare — the runtime pane I/O contract (stdout=`wrote <path>`).   ← READ ONLY
src/cli.zig           # PaneOpts:70, pane_help:302 — confirms NO --output-dir flag; default mode=visible. ← READ ONLY
zig-out/bin/tmux-2html # the BUILT binary (verifies pane's real stdout during testing).                  ← test only
PRD.md                # §9.1–§9.3, §13.                                                                            ← READ ONLY
build.zig build.zig.zon src/*.zig scripts/   # no Zig/build changes this task.                          ← DO NOT TOUCH
```

### Desired Codebase tree with file responsibilities

```bash
tmux-2html.tmux       # bindings STUB replaced by: the O(full) bind-key (gated binary_ready) +
                      #   the conditional visible bind-key (gated binary_ready + non-empty visible_key) +
                      #   a labeled C-o region sub-stub (T2.S2) + optional TMUX_2HTML_DEBUG append.
# (No new files; no Zig/build/docs changes; §1–§4 + autosync block untouched.)
```

### Known Gotchas of our codebase & Library Quirks

```sh
# CRITICAL (two-layer quoting — PROVEN, research/findings.md §4): the run-shell command string is
#   built by sh at SOURCE time, but RUN by /bin/sh at FIRE time. So:
#     * $TMUX_2HTML_BIN  → expanded by sh NOW (unescaped, inside double quotes). MUST be a real path
#       in the stored binding (exported vars do NOT reach run-shell children).
#     * #{pane_id}       → NOT special to sh → stored LITERALLY → run-shell expands it at fire time.
#     * $( ... )         → ESCAPE as \$( ... ) so sh stores it literally for run-shell's shell.
#     * " and $out       → ESCAPE as \" and \$out.
#   The exact line in the Implementation Patterns block below was verified end-to-end (TEST B/C).

# CRITICAL (exported vars do NOT reach run-shell children): a `bind-key … run-shell "$BIN/…"` child
#   inherits the tmux SERVER env, not the transient source-shell env. So $TMUX_2HTML_BIN MUST be
#   interpolated into the bind-key string at source time. (Inherited from P2.M2.T1.S1 gotcha.)

# GOTCHA: do NOT pass --output-dir/--font/--history/--open to pane from the binding. src/cli.zig
#   PaneOpts has NO --output-dir flag and NO --palette flag; pane resolves output-dir/history/font/open
#   itself via `tmux show-option` at runtime. Passing them would (a) error (--output-dir unknown) and
#   (b) duplicate the source of truth. The binding passes ONLY --target #{pane_id} + the mode flag.

# GOTCHA: pane prints `wrote <path>` to stdout and does NOT itself emit display-message for the
#   success path (only a best-effort display-message for the truncation NOTICE). So the binding MUST
#   capture pane's stdout with $(...) and feed it to `tmux display-message "tmux-2html: $out"`.

# GOTCHA: suppress pane's stderr with 2>/dev/null. On success pane writes 0 bytes to stderr (TEST G);
#   on truncation it writes the notice to stderr AND self-notifies via display-message, so suppressing
#   stderr avoids double-noise while the user still gets pane's own notice + our "wrote … (truncated)".

# GOTCHA (minor, accept): tmux display-message does FORMAT EXPANSION on its argument. The captured
#   $out is `wrote <sanitized-path>`; sanitized filenames use only [A-Za-z0-9._-] and the default
#   output-dir has no `#`/`{`/`%`, so it round-trips cleanly. Only a user-set @tmux-2html-output-dir
#   containing a literal `#{...}` could be mangled — extreme edge case; no workaround for defaults.

# GOTCHA: bind-key with NO -T binds in the PREFIX (root) table (TEST F) = exactly PRD §9.3. Do not add
#   -T root (that is a different table in some tmux docs). Either omit -T or use -T prefix.

# GOTCHA: the loader MUST NOT `set -e` and must NEVER return non-zero (a sourced plugin cannot abort
#   the user's source-file). A failing bind-key (e.g. an invalid key token) just prints tmux's error
#   and sourcing continues. Gate on `[ "$binary_ready" = 1 ]` so a missing binary binds nothing.

# GOTCHA (POSIX portability): `[ ]` not `[[ ]]`; `=` not `==`; `$( )` not backticks; quote every
#   expansion; no arrays; no `local`. `/bin/sh` here is bash-as-sh but the script must run under
#   dash/ash too (shellcheck -s sh enforces it). The `\"` / `\$( )` escapes are POSIX-clean.

# GOTCHA (debug seam ordering): §4 writes TMUX_2HTML_DEBUG with `>` (truncate). This task's optional
#   debug append MUST use `>>` AND run AFTER §4 in file order. The bindings block sits BEFORE the
#   autosync block (T1.S2) in the file; both append with `>>` after §4 ⇒ no truncation/conflict.

# GOTCHA (testing): `tmux source-file ./tmux-2html.tmux` FAILS (tmux parses source-file content as tmux
#   commands, not shell). Load the loader via `run-shell` (propagates $TMUX): set-environment the vars
#   on an ISOLATED socket, then `tmux -L sock run-shell "sh ./tmux-2html.tmux"`. For the deterministic
#   decision+command-string tests use a fake-`tmux` stub (Level 2); the live key-press is manual (Level 4).
```

## Implementation Blueprint

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: MODIFY tmux-2html.tmux — REPLACE the `## Bindings (prefix table)` stub with the real bindings
  - LOCATE the stub block (quoted verbatim in research/findings.md §1), currently:
        # ------------------------------------------------------------------
        # ## Bindings (prefix table) — P2.M2.T2.S1 (O + visible) / P2.M2.T2.S2 (C-o region)
        # ----------------------------------------------------------------------
        # Consumes: $TMUX_2HTML_BIN, $full_key, $region_key, $visible_key, $binary_ready
        # Pattern: interpolate the resolved values DIRECTLY into bind-key command strings, e.g.
        #   [ "$binary_ready" = 1 ] && tmux bind-key "$full_key" run-shell
        #       "$TMUX_2HTML_BIN/tmux-2html pane --full --target '#{pane_id}'"
        # The binary reads output-dir/history-limit/open/font itself via show-option — do NOT pass them.
        # (exported shell vars do NOT reach run-shell children spawned by bind-key.)
        # TODO(P2.M2.T2.S1/S2): implement prefix-table bindings here.
        # ----------------------------------------------------------------------
    and replace it (the whole commented stub) with the Implementation Patterns block below.
  - IMPLEMENT (see Implementation Patterns): the O(full) bind-key (gated binary_ready); the conditional
    visible bind-key (gated binary_ready + non-empty visible_key, mode --visible); a labeled C-o region
    sub-stub for T2.S2; and the optional TMUX_2HTML_DEBUG append (full_bound/visible_bound).
  - CONSUMES: $TMUX_2HTML_BIN (§1), $full_key/$visible_key (§3), $binary_ready (§2). DOES NOT consume
    $region_key (T2.S2). DOES NOT touch §1–§4 or the autosync block.
  - NAMING: full_bound, visible_bound (snake_case debug flags; lowercase).
  - GUARD: every path ends cleanly (no set -e; the `[ ] && …` idiom is robustly exit-0).

Task 2: VALIDATE (every command verified — see Validation Loop)
  - sh -n tmux-2html.tmux; shellcheck -s sh; bashism grep.
  - Level 2 fake-tmux: defaults ⇒ one full bind-key w/ pane --full + #{pane_id} literal + display-message;
    visible unset ⇒ no visible bind-key; visible="v" ⇒ visible bind-key w/ pane --visible; binary_ready=0
    ⇒ no bind-keys; $TMUX_2HTML_BIN expanded in the stored string.
  - Level 3 real isolated server via run-shell: non-crash (exit 0) + list-keys shows prefix-table O.
  - Level 4 manual: real client, prefix O renders the full pane + status-line "tmux-2html: wrote <path>".
```

### Implementation Patterns & Key Details

```sh
# ===== the block that REPLACES the bindings stub (verbatim-ready; proven TEST B/C) =====
# ----------------------------------------------------------------------
# ## Bindings (prefix table) — P2.M2.T2.S1 (O + visible)
# ----------------------------------------------------------------------
# PRD §9.3: prefix O renders the FULL pane; the visible key (if set) renders visible-only.
# Both are run-shell wrappers around `pane`, which resolves output-dir/history/font/open
# itself via show-option (do NOT pass them). run-shell expands #{pane_id} at fire time and
# has no /dev/tty, so pane uses the CACHED palette. We capture pane's stdout (`wrote <path>`)
# and flash it on the status line via display-message. Gated on binary_ready (§9.1: skip
# binding when the install failed). No set -e — a bad key just prints tmux's error.

# O (full) — prefix O renders the whole pane (scrollback + visible).
# Quoting: $TMUX_2HTML_BIN expanded NOW; #{pane_id} stored literally (run-shell expands it);
# \$(…)/\"/\$out escaped so run-shell's /bin/sh runs them at fire time.
[ "$binary_ready" = 1 ] && tmux bind-key "$full_key" run-shell \
    "out=\$(\"$TMUX_2HTML_BIN/tmux-2html\" pane --full --target '#{pane_id}' 2>/dev/null); tmux display-message \"tmux-2html: \$out\""

# Visible (only if @tmux-2html-visible-key is set; empty default ⇒ unbound, PRD §9.2/§9.3).
if [ -n "$visible_key" ]; then
    [ "$binary_ready" = 1 ] && tmux bind-key "$visible_key" run-shell \
        "out=\$(\"$TMUX_2HTML_BIN/tmux-2html\" pane --visible --target '#{pane_id}' 2>/dev/null); tmux display-message \"tmux-2html: \$out\""
fi

# Optional test seam (APPEND with >>; §4 already wrote with > and runs first in file order).
if [ -n "${TMUX_2HTML_DEBUG:-}" ]; then
    {
        printf 'full_bound=%s\n'    "$([ "$binary_ready" = 1 ] && echo 1 || echo 0)"
        printf 'visible_bound=%s\n' "$([ "$binary_ready" = 1 ] && [ -n "$visible_key" ] && echo 1 || echo 0)"
    } >> "$TMUX_2HTML_DEBUG"
fi

# ------------------------------------------------------------------
# C-o region binding — P2.M2.T2.S2 (display-popup wrapper + .last-output sidecar)
# Consumes: $region_key, $TMUX_2HTML_BIN, $binary_ready. NOT implemented here.
# ------------------------------------------------------------------
# ----------------------------------------------------------------------

# WHY capture stdout (not rely on run-shell auto-display): run-shell's stdout display is
#   context-dependent (status line vs copy mode vs CLI terminal) and does NOT prepend the
#   "tmux-2html:" prefix the contract requires. An explicit `display-message "tmux-2html: $out"`
#   is deterministic, matches §9.3, and shows on the firing client's status line.
# WHY 2>/dev/null on pane: pane writes 0 bytes to stderr on success (TEST G); on truncation it
#   writes the notice to stderr AND self-notifies via display-message, so suppressing stderr
#   avoids double-noise while the user still gets pane's notice + our "wrote … (truncated)".
# WHY no --output-dir/--font/--history/--open: PaneOpts has no --output-dir; pane reads them
#   itself (src/cli.zig:70, src/main.zig panePrepare). Passing them errors / duplicates truth.
```

### Integration Points

```yaml
LOADER (tmux-2html.tmux):
  - consumes: $TMUX_2HTML_BIN (§1), $full_key/$visible_key (§3), $binary_ready (§2), $HOME/$XDG_* (none here).
  - produces: prefix-table bind-keys (O full; visible if set); optional full_bound/visible_bound in TMUX_2HTML_DEBUG.
  - does NOT touch §1–§4, the autosync block (T1.S2), or the C-o region sub-stub (T2.S2).
PANE (P2.M1.T2.S1, DONE): the binding runs `tmux-2html pane --full|--visible --target #{pane_id}`.
  pane resolves output-dir/history/font/open from @tmux-2html-* itself; writes
  <output-dir>/<session>-<ts>-<pid>.html; prints `wrote <path>` to stdout; exit 0/1/2.
TMUX RUNTIME: run-shell expands #{pane_id} at fire time (≥ any 3.x); display-message shows on the
  firing client's status line. No minimum-version bump (run-shell/bind-key/display-message are ancient).
TEST ISOLATION (PRD §0): tests use a uniquely-named isolated socket (`tmux -L t2h-...`) loaded via
  run-shell for the non-crash check, and a fake-`tmux` stub for the deterministic decision/command-string
  tests. Never touch the user's running server. The live key-press is manual (Level 4).
BUILD/PACKAGE: NO CHANGE — tmux-2html.tmux is already in build.zig.zon .paths; no Zig/docs changes.
```

## Validation Loop

### Level 1: Syntax & Style (after editing the loader)

```bash
sh -n tmux-2html.tmux && echo "syntax OK"           # POSIX syntax (mandatory)
command -v shellcheck >/dev/null && shellcheck -s sh tmux-2html.tmux || echo "shellcheck N/A"
# Bashism scan (dash would reject these): expect ZERO hits in the NEW block.
grep -nE '\[\[|==|BASH_SOURCE|declare |local |let |~|<\(' tmux-2html.tmux || echo "no bashisms"
# Expected: "syntax OK"; shellcheck clean (the `\"`/`\$( )` escapes and `${var:-}` are POSIX-clean)
# or N/A; "no bashisms".
```

### Level 2: Decision + exact command string (PRIMARY — fake tmux, no real server, deterministic)

```bash
# Stub `tmux` so we can exercise the loader WITHOUT a server. The fake records bind-key argv to a
# log; returns empty for show-option (unset ⇒ defaults apply via read_opt); no-ops everything else.
work=$(mktemp -d); fakebin="$work/fakebin"; pm="$work/pm"; bin="$work/bin"
mkdir -p "$fakebin" "$pm" "$bin"
cat > "$fakebin/tmux" <<'EOF'
#!/usr/bin/env sh
case "$1" in
  show-option) printf '';;                 # unset ⇒ empty (read_opt applies defaults)
  display-message) :;;                     # no-op
  bind-key)
    # record the FULL bind-key command line the loader issued
    printf '%s\n' "$*" >> "$T2H_BIND_LOG"
    ;;
esac
EOF
chmod +x "$fakebin/tmux"
: > "$bin/tmux-2html"; chmod +x "$bin/tmux-2html"     # binary_ready=1 fast-path

run_case() {  # $1=label; sets up env then sources the loader; checks the bind log
  rm -f "$work/bind.log"; export T2H_BIND_LOG="$work/bind.log"
  PATH="$fakebin:$PATH" HOME="$work/home" TMUX_PLUGIN_MANAGER_PATH="$pm" \
    TMUX_2HTML_BIN="$bin" sh ./tmux-2html.tmux
}

# (a) DEFAULTS + binary ready ⇒ exactly ONE bind-key (O full) with the right shape.
mkdir -p "$work/home"; run_case a
n=$(wc -l < "$work/bind.log"); [ "$n" = 1 ] && echo "PASS a: one bind-key issued"
grep -q '^O ' "$work/bind.log" && echo "PASS a: bound key = O"
grep -q 'pane --full' "$work/bind.log" && echo "PASS a: full mode"
grep -q "target '#{pane_id}'" "$work/bind.log" && echo "PASS a: #{pane_id} stored LITERALLY"
grep -q 'display-message' "$work/bind.log" && echo "PASS a: notify via display-message"
grep -q '"'"'"$bin"'"'"'/tmux-2html' "$work/bind.log" && echo "PASS a: \$TMUX_2HTML_BIN expanded at source time"
# visible must be ABSENT in the defaults case:
grep -q 'pane --visible' "$work/bind.log" && echo "FAIL a: visible bound by default" || echo "PASS a: no visible bind (unset)"

# (b) visible-key SET ⇒ a SECOND bind-key (v visible).
PATH="$fakebin:$PATH" HOME="$work/home" TMUX_PLUGIN_MANAGER_PATH="$pm" TMUX_2HTML_BIN="$bin" \
  sh -c 'set --; . /dev/stdin' <<EOF 2>/dev/null || true
# set the option by making the fake return it
EOF
# (easier: a fake that returns the visible-key value)
cat > "$fakebin/tmux" <<'EOF'
#!/usr/bin/env sh
case "$1" in
  show-option) case "$4" in *@tmux-2html-visible-key*) printf 'v';; *) printf '';; esac;;
  display-message) :;;
  bind-key) printf '%s\n' "$*" >> "$T2H_BIND_LOG";;
esac
EOF
chmod +x "$fakebin/tmux"
rm -f "$work/bind.log"; export T2H_BIND_LOG="$work/bind.log"
PATH="$fakebin:$PATH" HOME="$work/home" TMUX_PLUGIN_MANAGER_PATH="$pm" TMUX_2HTML_BIN="$bin" sh ./tmux-2html.tmux
n=$(wc -l < "$work/bind.log"); [ "$n" = 2 ] && echo "PASS b: two bind-keys (O + v)"
grep -q '^v ' "$work/bind.log" && grep -q 'pane --visible' "$work/bind.log" && echo "PASS b: visible bound to v"

# (c) binary NOT ready (missing executable) ⇒ NO bind-keys.
rm -f "$bin/tmux-2html"
# restore the all-empty fake
cat > "$fakebin/tmux" <<'EOF'
#!/usr/bin/env sh
case "$1" in show-option) printf '';; display-message|bind-key) :;; esac
EOF
chmod +x "$fakebin/tmux"
rm -f "$work/bind.log"; export T2H_BIND_LOG="$work/bind.log"
PATH="$fakebin:$PATH" HOME="$work/home" TMUX_PLUGIN_MANAGER_PATH="$pm" TMUX_2HTML_BIN="$bin" sh ./tmux-2html.tmux
[ ! -s "$work/bind.log" ] && echo "PASS c: binary_ready gate held (no bind-keys when binary absent)"
rm -rf "$work"
# Expected: PASS a (one O-full bind-key, literal #{pane_id}, display-message, BIN expanded, no visible),
#           PASS b (two bind-keys incl. v visible), PASS c (no bind-keys when binary_ready=0).
```

### Level 3: Real isolated tmux server (§0-compliant; non-crash + prefix-table proof)

```bash
# IMPORTANT (PRD §0): use a UNIQUE isolated socket; NEVER the user's server. Load via run-shell
# (source-file REJECTS shell scripts). We assert the loader completes cleanly AND that `O` lands
# in the PREFIX table with the correct run-shell body.
sock="t2h-it-$$"
tmux -L "$sock" -f /dev/null new-session -d -s t2h
work=$(mktemp -d); pm="$work/pm"; bin="$work/bin"; mkdir -p "$pm" "$bin"
: > "$bin/tmux-2html"; chmod +x "$bin/tmux-2html"     # binary_ready=1
for v in TMUX_PLUGIN_MANAGER_PATH TMUX_2HTML_BIN TMUX_2HTML_DEBUG; do :; done
tmux -L "$sock" set-environment TMUX_PLUGIN_MANAGER_PATH "$pm"
tmux -L "$sock" set-environment TMUX_2HTML_BIN "$bin"
tmux -L "$sock" set-environment TMUX_2HTML_DEBUG "$work/debug.env"

# (1) Defaults: loader must complete cleanly + bind O in the prefix table.
tmux -L "$sock" run-shell "sh $(pwd)/tmux-2html.tmux"; echo "run-shell-exit=$?"
sleep 0.3
echo "--- list-keys -T prefix O ---"
tmux -L "$sock" list-keys -T prefix O 2>&1
# The stored binding must contain: pane --full, target '#{pane_id}' (literal), display-message.
lk=$(tmux -L "$sock" list-keys -T prefix O 2>&1)
echo "$lk" | grep -q 'pane --full' && echo "PASS: O bound to pane --full"
echo "$lk" | grep -q "pane_id" && echo "PASS: target uses #{pane_id}"
echo "$lk" | grep -q 'display-message' && echo "PASS: notify via display-message"
# visible must NOT be bound in the defaults case:
tmux -L "$sock" list-keys -T prefix 2>&1 | grep -q 'pane --visible' \
  && echo "FAIL: visible bound by default" || echo "PASS: no visible bind (unset)"
# Debug seam recorded the decision:
grep -qx 'full_bound=1' "$work/debug.env" 2>/dev/null && echo "PASS: full_bound=1"
grep -qx 'visible_bound=0' "$work/debug.env" 2>/dev/null && echo "PASS: visible_bound=0"

# (2) Set visible-key ⇒ reload ⇒ visible now bound too.
tmux -L "$sock" set -g @tmux-2html-visible-key "v"
rm -f "$work/debug.env"
tmux -L "$sock" run-shell "sh $(pwd)/tmux-2html.tmux"; sleep 0.3
tmux -L "$sock" list-keys -T prefix v 2>&1 | grep -q 'pane --visible' && echo "PASS: visible bound to v after reload"
grep -qx 'visible_bound=1' "$work/debug.env" 2>/dev/null && echo "PASS: visible_bound=1 after reload"

# (3) Non-crash when binary is absent (binary_ready=0 ⇒ no bind-keys; loader still exits clean).
tmux -L "$sock" set-environment TMUX_2HTML_BIN "/nonexistent/bin"
rm -f "$work/debug.env"
tmux -L "$sock" run-shell "sh $(pwd)/tmux-2html.tmux"; echo "no-binary run-shell-exit=$?"
grep -qx 'full_bound=0' "$work/debug.env" 2>/dev/null && echo "PASS: no bind when binary_ready=0"
tmux -L "$sock" list-sessions >/dev/null 2>&1 && echo "PASS: server alive (non-fatal)"

tmux -L "$sock" kill-server; rm -rf "$work"
# Expected: all PASS lines; server stays alive; O bound in the prefix table with the correct body.
```

### Level 4: Manual / interactive (real attached client — NOT in CI)

```bash
# In a REAL tmux session (attached client), with the binary installed:
#   1. Source the plugin (or restart tmux / prefix I).
#   2. Fill a pane with some colored output, then press:  prefix O
#      Expect: a file appears under ${XDG_DATA_HOME:-~/.local/share}/tmux-2html/ named
#      <session>-<ts>-<pid>.html, AND the status line flashes:
#        tmux-2html: wrote <abs/path>.html
ls -t "${XDG_DATA_HOME:-$HOME/.local/share}/tmux-2html/" | head
#   3. Set a visible key and re-source, then press:  prefix <your-visible-key>
tmux set -g @tmux-2html-visible-key "v"; tmux run "$TMUX_2HTML_BIN/../tmux-2html.tmux" 2>/dev/null || tmux source ~/.tmux.conf
#      Expect: prefix v renders the VISIBLE-only pane + the same status-line notification.
#   4. Truncation: set a tiny history-limit + a long-scrollback pane, press prefix O.
#      Expect: status line `tmux-2html: wrote <path> (truncated)` AND pane's own truncation notice.
```

## Final Validation Checklist

### Technical Validation
- [ ] `sh -n tmux-2html.tmux` passes; no bashisms in the new block (Level 1 grep clean).
- [ ] `shellcheck -s sh tmux-2html.tmux` clean (or N/A).
- [ ] Level 2 fake-tmux: defaults ⇒ exactly one `O` full bind-key with `pane --full`,
      `#{pane_id}` literal, `display-message`, and `$TMUX_2HTML_BIN` expanded; visible unset ⇒
      no visible bind; visible=`v` ⇒ a second `v` visible bind; `binary_ready=0` ⇒ no bind-keys.
- [ ] Level 3 real isolated server (run-shell): loader completes cleanly; `O` is in the **prefix**
      table with the correct run-shell body; visible binds after setting the option; `binary_ready=0`
      ⇒ no bind-keys; server stays alive.

### Feature Validation
- [ ] `prefix O` (full) + `prefix <visible-key>` (if set) both render the target pane and flash
      `tmux-2html: wrote <path>` on the status line (Level 4 manual).
- [ ] Visible binding exists ONLY when `@tmux-2html-visible-key` is non-empty (default ⇒ unbound).
- [ ] Bindings are gated on `binary_ready=1` (§9.1 "on failure skip binding").
- [ ] The binding passes ONLY `--target #{pane_id}` + the mode flag (no output-dir/font/history/open).
- [ ] `#{pane_id}` is stored LITERAL (run-shell expands it at fire time); `$TMUX_2HTML_BIN` is
      expanded at source time (exported vars don't reach run-shell children).

### Code Quality Validation
- [ ] POSIX-portable (`[ ]`, `=`, `$( )`, quoted expansions, no arrays/`local`, no `set -e`).
- [ ] Two-layer quoting correct (`\"`, `\$( )`, `\$out` escaped; `#{pane_id}` literal).
- [ ] Debug append uses `>>` and runs after §4's `>` (file order) — no truncation/conflict.
- [ ] §1–§4, the autosync block (T1.S2), and the C-o region sub-stub (T2.S2) are untouched.
- [ ] No Zig/build/docs changes; `PRD.md`/`tasks.json`/`prd_snapshot.md`/`.gitignore` untouched.

### Documentation & Deployment
- [ ] No new docs (the item contract: keybinds are documented in `docs/CONFIGURATION.md` (P2.M2.T1.S1,
      already done) + the final README (P4.M2)).
- [ ] No new env vars; no packaging change (`tmux-2html.tmux` already in build.zig.zon .paths).

---

## Anti-Patterns to Avoid

- ❌ Don't pass `--output-dir`/`--font`/`--history`/`--open` to pane from the binding —
  `src/cli.zig` PaneOpts has **no `--output-dir` flag**; pane reads them itself via `show-option`.
  Passing `--output-dir` errors (`unknown option`); passing the others duplicates the truth.
- ❌ Don't escape `#{pane_id}` or try to expand it in sh — run-shell expands it at **fire time**.
  Store it LITERAL (it's not special to sh inside double quotes). (PROVEN: TEST A.)
- ❌ Don't forget to escape `\$(…)`, `\"`, `\$out` — without the backslashes sh expands them at
  source time and the stored binding breaks. (PROVEN correct as written: TEST C.)
- ❌ Don't rely on run-shell's auto-display of stdout for the notification — it's context-dependent
  and lacks the required `tmux-2html:` prefix. Capture stdout with `$(…)` and call `display-message`
  explicitly. (Contract: `display-message "tmux-2html: wrote <file>"`.)
- ❌ Don't `set -e` or return non-zero — a sourced plugin cannot abort the user's `source-file`.
  A bad key token just prints tmux's error; sourcing continues.
- ❌ Don't omit the `binary_ready` gate — `§9.1` requires "on failure skip binding". With
  `binary_ready=0` the loader must issue NO bind-keys.
- ❌ Don't bind the visible key unconditionally — its default is empty (unbound); bind it only inside
  `if [ -n "$visible_key" ]`.
- ❌ Don't use `-T root` — in tmux the prefix table IS the root table; omit `-T` (or use `-T prefix`).
  (PROVEN: TEST F.)
- ❌ Don't implement the C-o region binding (T2.S2) or touch the autosync block (T1.S2) — leave a
  labeled sub-stub for C-o; the autosync block is owned by the parallel task.
- ❌ Don't test via `tmux source-file ./tmux-2html.tmux` (it rejects shell scripts) — load via
  `run-shell` on an ISOLATED socket (Level 3); use a fake-`tmux` stub for the deterministic checks
  (Level 2); render manually with a real client (Level 4).
- ❌ Don't touch the user's running tmux server in tests — use a unique isolated socket (`tmux -L
  t2h-…`) and tear down only that socket.

---

**Confidence Score: 9/10**

This is a small, well-scoped POSIX-sh task, and every load-bearing mechanic is **empirically proven**
against the installed tmux 3.6b + the built binary (research/findings.md): run-shell expands
`#{pane_id}` (TEST A); the exact two-layer-quoted wrapper captured pane's real `wrote <path>` output
(TEST B); `list-keys` confirms the stored quoting is correct (TEST C); `bind-key` without `-T` lands
in the prefix table (TEST F); pane writes 0 bytes to stderr on success so `2>/dev/null` is safe
(TEST G). The exact stub block to replace is quoted verbatim from the live file; the consumed loader
symbols and the no-`set -e` rule are read from the live §1–§4; the runtime pane contract (stdout =
`wrote <path>`, no `--output-dir` flag, pane reads options itself) is read from `src/main.zig`/`src/cli.zig`.
The decision logic + exact command string are deterministically testable via a fake-`tmux` stub
(Level 2) and a real isolated server (Level 3); only the live key-press render is manual (Level 4),
exactly like the sibling autosync-popup task. The one residual risk — matching the two-layer escaping
byte-for-byte — is mitigated by giving the exact proven line verbatim and by dedicated Level 2/3
assertions on the stored binding string.
