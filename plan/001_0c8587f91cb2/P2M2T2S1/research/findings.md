# P2.M2.T2.S1 — Research findings (empirically verified)

Scope: the **prefix-table bindings** for `O` (full pane) + the conditional visible-key
binding, both `run-shell` wrappers around the (DONE) `pane` subcommand. This task
**replaces the `## Bindings` stub** in `tmux-2html.tmux`; it does NOT touch the autosync
stub (P2.M2.T1.S2, implemented in parallel) or the C-o region binding (P2.M2.T2.S2).

All tmux facts below were verified against the **installed tmux 3.6b on an isolated named
socket** (`tmux -L t2h-research-*`) and against the **built binary** at `zig-out/bin/tmux-2html`.
No live web was needed; the tmux manual is the stable primary source.

---

## 1. The exact loader stub block to REPLACE (verbatim, from the live `tmux-2html.tmux`)

```sh
# ----------------------------------------------------------------------
# ## Bindings (prefix table) — P2.M2.T2.S1 (O + visible) / P2.M2.T2.S2 (C-o region)
# ----------------------------------------------------------------------
# Consumes: $TMUX_2HTML_BIN, $full_key, $region_key, $visible_key, $binary_ready
# Pattern: interpolate the resolved values DIRECTLY into bind-key command strings, e.g.
#   [ "$binary_ready" = 1 ] && tmux bind-key "$full_key" run-shell \
#       "$TMUX_2HTML_BIN/tmux-2html pane --full --target '#{pane_id}'"
# The binary reads output-dir/history-limit/open/font itself via show-option — do NOT pass them.
# (exported shell vars do NOT reach run-shell children spawned by bind-key.)
# TODO(P2.M2.T2.S1/S2): implement prefix-table bindings here.
# ----------------------------------------------------------------------
```

**Action:** replace this whole commented stub with (a) the **O (full) binding**, (b) the
**conditional visible binding**, and (c) a **clearly-labeled sub-stub** for the C-o region
binding that T2.S2 will fill. Do NOT implement the C-o region binding. Do NOT touch the
autosync block below it (T1.S2 owns it).

## 2. Consumed loader symbols (already exported by §1–§3; this task only READS them)

- `$TMUX_2HTML_BIN` — absolute binary dir (§1). Interpolated into the run-shell command at
  **source time** (exported vars do NOT reach run-shell children — see §4 gotcha).
- `$full_key` — `@tmux-2html-full-key` value, default `O` (§3 `read_opt`).
- `$visible_key` — `@tmux-2html-visible-key` value, default **empty** ⇒ visible is unbound
  until the user sets it (§3). THIS TASK binds visible **only if non-empty**.
- `$region_key` — present but belongs to T2.S2 (C-o). This task does NOT consume it.
- `$binary_ready` — `1` when the binary is present+executable; `0` on install failure (§2).
  THIS TASK gates every `bind-key` on `[ "$binary_ready" = 1 ]`.
- No `set -e` in the loader (hard rule). `bind-key` failures must never abort sourcing.
- `TMUX_2HTML_DEBUG` (§4) is the test seam — this task may **append** binding info to it
  with `>>` (§4 writes with `>` and runs first in file order).

## 3. pane (DONE, P2.M1.T2.S1) — exact runtime I/O contract (read from `src/main.zig`)

- **CLI flags (src/cli.zig PaneOpts):** `--target PANE`, `--visible` (default), `--full`
  (mutually exclusive of --visible), `--history N`, `--font FAMILY`, `--output FILE`,
  `--open`. **There is NO `--output-dir` flag and NO `--palette` flag.**
- **pane resolves everything else itself** via `tmux show-option` at runtime:
  `@tmux-2html-output-dir` (capture.resolveOutputDir), `@tmux-2html-history-limit`
  (capture.queryOption), and reads `--font`/`--open` defaults from options too
  (cli defaults: font=monospace, open=on). ⇒ **The binding passes ONLY `--target #{pane_id}`
  (and the mode flag `--full`/`--visible`). It does NOT pass output-dir/font/history/open.**
- **stdout on success:** exactly one line, `wrote <abs/path/file.html>` (or
  `wrote <path> (truncated)` when PRD §13 truncation hit). Trailing `\n`. (paneBody:
  `stdout.writeAll(result.summary); stdout.writeAll("\n")`.)
- **stdout on failure:** the error line, e.g. `error: no target pane (...)`, then exits 2.
  (paneBody prints the summary line and returns the code on the failure path too.)
- **stderr on success:** **0 bytes** (VERIFIED: `pane --full --target %0 2>/x 1>/dev/null`
  ⇒ stderr file 0 bytes; exit 0). Stderr carries ONLY the truncation NOTICE when truncated,
  and pane ALSO emits that notice itself via a best-effort `tmux display-message -p <notice>`.
  ⇒ The binding captures **stdout only**; `2>/dev/null` is safe (pane self-notifies on
  truncation).
- **pane does NOT itself emit `display-message "tmux-2html: wrote <file>"`.** That success
  notification is THIS task's responsibility (the contract: "After render, `tmux
  display-message "tmux-2html: wrote <file>"`"). ⇒ The binding wrapper must capture pane's
  stdout and feed it to `display-message`.

## 4. CRITICAL — `run-shell` expands `#{pane_id}`; quoting is two-layer (PROVEN, TEST A/B/C)

**TEST A** — `tmux -L sock run-shell "printf 'expanded=[#{pane_id}]' > /tmp/x"`: tmux's own
echo-back showed `expanded=[%0]` ⇒ **`run-shell` expands `#{pane_id}` at fire time** (it
does NOT pass `#{...}` literally to the shell). Confirmed also by `findings_and_corrections.md`
§3 and `research_tmux.md` Claim 4.

**Therefore the binding command string has TWO quoting layers:**
1. **sh (source time):** `$TMUX_2HTML_BIN` is interpolated NOW (it must be a real path in
   the stored binding); `\$(...)`, `\"`, `\$out` are ESCAPED so sh passes them literally.
2. **run-shell (fire time):** the stored string runs in `/bin/sh`; `#{pane_id}` is expanded
   by tmux BEFORE the shell runs, then `$( ... )` captures pane's stdout, then
   `display-message` shows it.

**The exact source-time sh line (proven by TEST B + TEST C):**
```sh
[ "$binary_ready" = 1 ] && tmux bind-key "$full_key" run-shell \
    "out=\$(\"$TMUX_2HTML_BIN/tmux-2html\" pane --full --target '#{pane_id}' 2>/dev/null); tmux display-message \"tmux-2html: \$out\""
```
- `$full_key` is OUTSIDE the run-shell string (bind-key's 2nd arg) ⇒ sh expands to `O`.
- `"$TMUX_2HTML_BIN/..."` INSIDE double quotes ⇒ sh expands to the abs path NOW.
- `#{pane_id}` ⇒ not special to sh ⇒ stored literally ⇒ run-shell expands at fire time.
- `\$( ... )` ⇒ stored as `$( ... )` ⇒ run-shell's shell runs it at fire time.
- `\"...\"` and `\$out` ⇒ stored as `"..."` and `$out`.

**TEST B result** (the decisive end-to-end proof): firing the equivalent run-shell against a
real pane captured pane's stdout:
```
wrote /home/dustin/.local/share/tmux-2html/t-1783624709-4007708.html
```
i.e. `#{pane_id}`→`%0`, pane captured the real pane, wrote a real HTML file, and `$(...)`
captured the `wrote <path>` line. **The whole pipeline works.**

**TEST C result** — `list-keys -T prefix O` showed the stored binding preserves the quoting:
```
bind-key -T prefix O run-shell "out=$(\"/abs/tmux-2html\" pane --full --target '#{pane_id}' 2>/dev/null); printf '%s' \"\$out\" > ..."
```
`#{pane_id}` stored literally (expands at fire time); `$(\"...\")` and `\"\$out\"` correctly
escaped. **The quoting is correct as written.**

## 5. `bind-key` defaults to the prefix (root) table (PROVEN, TEST F)

`tmux bind-key O run-shell "echo hi"` (no `-T`) ⇒ `list-keys -T prefix O` shows it in the
**prefix table**. So **`tmux bind-key "$full_key" run-shell "..."` (no `-T`) binds in the
prefix table** = exactly PRD §9.3 ("Bindings (prefix table)"). (Explicit `-T prefix` also
works and is equivalent; the predecessor stub's example omits `-T`, matching PRD §9.3.)

## 6. The visible binding is a simple `if [ -n "$visible_key" ]` (TEST E)

```sh
if [ -n "$visible_key" ]; then
    [ "$binary_ready" = 1 ] && tmux bind-key "$visible_key" run-shell \
        "out=\$(\"$TMUX_2HTML_BIN/tmux-2html\" pane --visible --target '#{pane_id}' 2>/dev/null); tmux display-message \"tmux-2html: \$out\""
fi
```
Empty `$visible_key` (the default) ⇒ **skip** (visible-only capture stays unbound), matching
PRD §9.2 "(empty) unbound by default" and §9.3 "(visible key, if set)". `--visible` is
explicit (pane's default mode is visible anyway, but the contract says `pane --visible`).

## 7. `display-message` semantics + the one minor gotcha

- `tmux display-message "msg"` (no flags) shows `msg` on the **status line of the current
  client** for `display-time` (default ~750ms, configurable). When fired from a binding,
  the client that pressed the key IS the current client ⇒ it works. (`-p` prints to stdout
  instead — useful for tests; do NOT use `-p` in the real binding.)
- **GOTCHA (minor, accept):** `display-message` does **format expansion** on its argument.
  The captured `$out` is `wrote <sanitized-path>`; sanitized filenames use only
  `[A-Za-z0-9._-]` (no `#`/`{`/`%`) and the default output-dir has none either, so the
  default path round-trips cleanly. ONLY a user-set `@tmux-2html-output-dir` containing a
  literal `#{...}` or `#`-style token could be mangled — an extreme edge case, not worth a
  workaround. (Documented as a known minor gotcha; no action for defaults.)

## 8. Non-fatality + §0 test isolation (inherited from the loader)

- The loader has **no `set -e`**; a failing `bind-key` (e.g. an invalid key token) simply
  prints tmux's error and sourcing continues. Keep it that way — never add `set -e`.
- The binding uses **only `$TMUX_2HTML_BIN` + the key vars** (all already resolved/guarded);
  no new crash surface.
- **§0:** tests use a **unique isolated socket** (`tmux -L t2h-...`) and a **fake-`tmux`
  stub** for the deterministic decision/command-string tests; the live key-press render is
  manual-only (exactly like the autosync popup). Never touch the user's running server.

## 9. What this task does NOT do (boundaries — respect sibling tasks)

- **Does NOT implement the C-o region binding** (P2.M2.T2.S2) — leave a labeled sub-stub.
- **Does NOT touch the `## Palette auto-sync popup` block** (P2.M2.T1.S2, parallel).
- **Does NOT pass output-dir/font/history/open to pane** — pane reads them itself (anti-pattern).
- **Does NOT touch §1–§4**, `src/*`, `build.zig*`, `PRD.md`, `tasks.json`, `prd_snapshot.md`,
  `.gitignore`. (No Zig/build changes; no docs change — the item contract says keybinds are
  documented in `docs/CONFIGURATION.md` (P2.M2.T1.S1, already done) + the final README.)
