# P2.M2.T2.S2 research findings — C-o region binding (display-popup wrapper) + `.last-output` sidecar

Verified by reading the live repo (`tmux-2html.tmux`, `src/cli.zig`, `src/main.zig`,
`docs/CONFIGURATION.md`, `PRD.md`) + the sibling PRPs (P2.M2.T2.S1, P2.M2.T1.S2) + the
tmux research briefs. Every load-bearing fact is cited.

---

## §1  The exact C-o sub-stub block to REPLACE (verbatim, `tmux-2html.tmux` L157–161)

It sits immediately AFTER the O+visible bindings block (P2.M2.T2.S1) and immediately
BEFORE the `## Palette auto-sync popup` block (P2.M2.T1.S2):

```
# ------------------------------------------------------------------
# C-o region binding — P2.M2.T2.S2 (display-popup wrapper + .last-output sidecar)
# Consumes: $region_key, $TMUX_2HTML_BIN, $binary_ready. NOT implemented here.
# ------------------------------------------------------------------
# ----------------------------------------------------------------------
```

The trailing `# ---...` (29-dash) closes the C-o stub; the `# ------...` (70-dash) is a
separator before the autosync block. Replace the C-o stub (the 5 lines above) with the real
implementation; keep ONE separator line before the autosync block (mirrors the O-block's
trailing separator).

Consumed loader symbols (all set in §1–§3, unchanged by this task):
- `$region_key` — `read_opt @tmux-2html-region-key C-o` (§3, L77). Default `C-o`.
- `$TMUX_2HTML_BIN` — resolved in §1 (env → @tmux-2html-binary-dir → `$plugin_dir/bin`),
  ABSOLUTE in all branches. Exported.
- `$binary_ready` — `1` if the binary is present+executable (else `0`, §2).
- `${TMUX_2HTML_DEBUG:-}` — optional debug file (§4 writes with `>`; this task APPENDS with `>>`).

## §2  The region subcommand surface (what the wrapper invokes)

`src/cli.zig` `RegionOpts` (frozen, P1.M1.T3.S2):
```
RegionOpts { target: ?[]const u8 = null, font: []const u8 = "monospace",
             output: ?[]const u8 = null, open: bool = false }
parseRegion accepts ONLY: --target PANE --font FAMILY --output FILE --open
```
- NO `--history`, NO `--full`/`--visible`, NO `--palette`, NO `--output-dir`, NO
  `--last-output`. (parseRegion returns `error.UnknownFlag` for anything else.)
- `cli.region` currently returns `error.NotImplemented` → mapped to exit 1 by main.zig
  ("this subcommand is not yet implemented"). The body lands in P3.M3.T1.
- ⇒ The wrapper passes ONLY `--target #{pane_id}`. region resolves font/open/output-dir
  from `@tmux-2html-*` ITSELF at runtime via `tmux show-option` — EXACTLY as `pane` does
  (src/main.zig `paneBody` uses `capture.resolveOutputDir` + `capture.queryOption`). This is
  confirmed by docs/CONFIGURATION.md "How options are read": "The pane and region commands
  re-read @tmux-2html-output-dir, @tmux-2html-history-limit, @tmux-2html-open, and
  @tmux-2html-font themselves at runtime via tmux show-option, so you do not pass them on the
  command line." So passing --font/--open/--output-dir from the binding would error (--output-dir
  unknown) or duplicate truth. Same constraint as the O binding.

## §3  The `.last-output` sidecar CONTRACT (the cross-task seam with P3.M3.T1.S2)

PRD §9.3 (authoritative): "The region path writes the result path to
`$TMUX_2HTML_BIN/.last-output` for the wrapper to `display-message`."  PRD §7.5: on confirm,
"display the path via tmux message (written to a sidecar file the plugin reads, since the
popup has no tmux message channel)."

WHY a sidecar (not stdout / not a direct `tmux display-message` from region): the region TUI
runs INSIDE `tmux display-popup` — a real pty, but the popup's child has NO `$TMUX` socket
access to call `tmux display-message` against the user's server reliably, and run-shell's
auto-display of stdout is context-dependent + lacks the required `tmux-2html:` prefix. So
region WRITES the bare output path to a file the wrapper (which runs in the run-shell /bin/sh
context, WITH `$TMUX`) reads after the popup closes. (research_tmux.md Claim 2/3: popup = real
pty / no tmux channel; run-shell = $TMUX set.)

THE AGREED CONTRACT (this task + P3.M3.T1.S2 must match EXACTLY):
- LOCATION: `$TMUX_2HTML_BIN/.last-output` (the directory containing the `tmux-2html` binary).
  - The WRAPPER reads it from `"$TMUX_2HTML_BIN/.last-output"` with `$TMUX_2HTML_BIN`
    expanded at SOURCE time (exported vars do NOT reach run-shell children — inherited gotcha).
  - REGION (P3) must write it in its OWN executable directory (= `$TMUX_2HTML_BIN`). region
    does NOT receive `$TMUX_2HTML_BIN` (the popup child inherits the SERVER env, where
    `$TMUX_2HTML_BIN` was only a transient loader export) — so P3 must derive the bin dir from
    `argv[0]` / `/proc/self/exe` (Linux) / `_NSGetExecutablePath` (macOS). THIS IS P3'S JOB;
    this task only reads from `$TMUX_2HTML_BIN/.last-output` and trusts region wrote there.
- CONTENT: the BARE absolute output path (the HTML file), NO `wrote` prefix, NO trailing
  newline required (`$(cat ...)` strips trailing newlines anyway). The wrapper prepends
  `wrote` in `display-message "tmux-2html: wrote <path>"` → matches the O binding's
  `tmux-2html: wrote <path>` format exactly.
- LIFECYCLE: the wrapper does `rm -f "$last"` BEFORE the popup (clears any stale file from a
  prior run). On CONFIRM region writes the path → `[ -f "$last" ]` true → message shows. On
  CANCEL region exits 1 WITHOUT writing → `$last` stays absent → no message (the `rm -f`
  guarantees no stale message on cancel). region MUST NOT touch `.last-output` on the cancel
  path (it only ever WRITES it on a successful confirm).

KNOWN LIMITATIONS (accepted for v1, PRD §13 spirit):
- Concurrent C-o presses on two clients race on the single shared `.last-output` (the second
  `rm -f` could delete the first's file mid-flight). Single-client is the v1 assumption.
- If `$TMUX_2HTML_BIN` is read-only (e.g. a system-installed binary), region cannot write
  `.last-output` there → the confirm message silently won't show (render still succeeds). The
  PRD pins the location to `$TMUX_2HTML_BIN`; P3 may add a fallback later. Not this task.

## §4  The wrapper command string (THREE-layer quoting — derived from the proven O binding)

The O binding (P2.M2.T2.S1, PROVEN end-to-end vs tmux 3.6b) is the template:
```
[ "$binary_ready" = 1 ] && tmux bind-key "$full_key" run-shell \
    "out=\$(\"$TMUX_2HTML_BIN/tmux-2html\" pane --full --target '#{pane_id}' 2>/dev/null); tmux display-message \"tmux-2html: \$out\""
```
Its quoting rules (carry over verbatim):
- The bind-key command arg is ONE double-quoted string (built by sh at SOURCE time).
- `$TMUX_2HTML_BIN` → expanded NOW (unescaped) — exported vars don't reach run-shell children.
- `#{pane_id}` → NOT special to sh → stored LITERAL → run-shell expands it at fire time.
- `\"` → literal `"`; `\$( )` → literal `$( )`; `\$out`/`\$last` → literal `$out`/`$last`
  (all deferred to fire time, run by run-shell's /bin/sh).

The C-o wrapper (at FIRE time, what run-shell's /bin/sh must run after `#{pane_id}`→`%5`):
```
last="$BIN/.last-output"; rm -f "$last"; tmux display-popup -E -w 100% -h 100% "$BIN/tmux-2html region --target %5"; if [ -f "$last" ]; then out=$(cat "$last"); tmux display-message "tmux-2html: wrote $out"; fi
```
Using intermediate `last`/`out` vars (a) avoids repeating the long path 3× and (b) AVOIDS a
nested `$(cat "...")` inside `display-message`'s double-quoted arg (POSIX-sh nested quotes in
`$()` are subtle). `out=$(cat "$last")` is a SEPARATE assignment, then `$out` is plain in the
message — no nesting. The trailing `if ...; fi` always returns 0 (no `&&`-short-circuit exit-1
on cancel that run-shell might log).

The stored bind-key string (source-time, what THIS task writes in the file) — see the PRP
"Implementation Patterns" block for the exact byte-for-byte escaping. KEY: `last=\"$...\"`,
`rm -f \"\$last\"`, `display-popup ... \"$.../tmux-2html region --target #{pane_id}\"`,
`[ -f \"\$last\" ]`, `out=\$(cat \"\$last\")`, `display-message \"... \$out\"`.

## §5  tmux display-popup facts (load-bearing — research_tmux.md Claim 2/7)

- `display-popup -E -w 100% -h 100%` = a REAL freshly-allocated pty (full-screen = 100% of the
  client). `-E` = close on exit. The command arg runs in that pty with a /dev/tty ⇒ the region
  TUI can do alt-screen/raw-termios/mouse (P3).  (Claim 2)
- Introduced in tmux 3.2; PRD §12 pins runtime `tmux ≥ 3.2`. On older tmux `display-popup` is
  "unknown command" → at FIRE time the popup silently fails to open (the wrapper's `if [ -f ]`
  then finds no `.last-output` → no message); graceful, no crash. NOT gated at source time
  (mirrors the autosync popup's non-fatal `2>/dev/null || :` philosophy).  (Claim 7)
- `#{pane_id}` is expanded by run-shell (the binding context) BEFORE display-popup runs, so
  display-popup receives the literal `%5` — no double-format-expansion concern. `%` in `100%`
  is NOT a tmux format token (formats are `#{...}`/`#(...)`), so it passes through untouched.
- display-popup needs an ATTACHED CLIENT; a detached test server errors "no current client" ⇒
  the live popup render is MANUAL-ONLY (Level 4). Test the decision + exact command string via
  a fake-tmux stub (Level 2) and prove non-fatality + binding storage via the real isolated
  server (Level 3) — SAME test split as the autosync popup (P2.M2.T1.S2).

## §6  The C-o override note (§9.2) — what "honor" means

PRD §9.2 + docs/CONFIGURATION.md L34–40: `C-o` is already bound in the stock prefix table
(`rotate-window`; in some configs a debug `display-message`). Setting
`@tmux-2html-region-key C-o` (the default) **overrides** it. "To preserve the old binding,
set a different key (e.g. `C-S-o`)." → This is a USER action (set the option), NOT loader
logic. The loader simply binds `$region_key` (default `C-o`), which overrides whatever was
there per tmux's re-bind semantics. The loader does NOT save/restore the old binding (out of
scope; the note frames preservation as a user choice). docs/CONFIGURATION.md ALREADY documents
this (L34–40), so NO doc change is needed for the conflict note.

## §7  Docs state (item contract: "DOCS: none — keybind in docs + README")

docs/CONFIGURATION.md is ALREADY complete for this task (done in P2.M2.T1.S1):
- L26: `@tmux-2html-region-key` default `C-o` in the Options table.
- L34–40: the C-o key-conflict note + the `C-S-o` preservation example.
- "How options are read" (L43+): states pane AND region re-read the @tmux-2html-* options
  themselves (so the binding passes only `--target`).
The README keybind table is P4.M2.T1.S1's job (Planned). ⇒ THIS TASK DOES NOT MODIFY DOCS.

## §8  Test mechanics (inherited + verified from the sibling PRPs)

- `tmux source-file ./tmux-2html.tmux` FAILS (tmux parses source-file as tmux commands, not
  shell — "unknown command: echo", exit 1). Load the loader via `run-shell` on an ISOLATED
  socket: `tmux -L sock set-environment TMUX_PLUGIN_MANAGER_PATH <pm>; ...; tmux -L sock
  run-shell "sh ./tmux-2html.tmux"`. (verified, P2.M2.T1.S2 findings §5.)
- For the deterministic decision + exact command string, stub `tmux` (records `bind-key`
  argv) — NO real server needed (Level 2).
- For non-fatality + binding storage, use a real isolated server via run-shell (Level 3).
- For the sidecar logic, extract the stored wrapper body (argv[4] of the recorded bind-key)
  and run it under /bin/sh with a fake `tmux` (records display-popup/display-message) + a fake
  `tmux-2html region` (writes `.last-output` on "confirm") — proves rm→popup→cat→message and
  the cancel case (region exits without writing → no message). DETERMINISTIC (Level 2 sub-case).
- PRD §0: tests use a UNIQUE isolated socket (`tmux -L t2h-...`); NEVER the user's server.

## §9  Files touched / NOT touched

EDIT: `tmux-2html.tmux` ONLY (replace the §1 C-o stub; add the region bind-key gated on
`binary_ready`; optional `region_bound` debug append with `>>`).
DO NOT TOUCH: §1–§4, the O+visible bindings block (P2.M2.T2.S1), the autosync block
(P2.M2.T1.S2), any `src/*.zig`, `build.*`, `PRD.md`, `tasks.json`, `prd_snapshot.md`,
`.gitignore`, `docs/` (already complete). No Zig/build/docs changes.
