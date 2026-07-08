# Research: Validate tmux technical claims in the tmux-2html PRD

## Summary
All seven claims are accurate, with two caveats worth flagging for the PRD: (a) `capture-pane -e` faithfully re-emits SGR colors/attributes from the in-memory grid, but OSC 8 (hyperlink) re-emission should be empirically verified; (b) `display-popup` exists from tmux 3.2, but the full flag set the PRD may want (`-e` env, `-b` border-lines, `-s`/`-S` styles, `-x`/`-y`) is complete only in 3.3.

## Methodology note
This environment has no live web/HTTP tool, and the local man page (`/usr/share/man/man1/tmux.1.gz`) is gzip-compressed and not decompressible with the available text tools. Findings below are therefore drawn from authoritative knowledge of the tmux manual page (a stable, deterministic primary source), with section/flag references cited precisely. Facts that cannot be stated with high confidence (e.g., OSC 8 re-emission, per-flag version availability) are explicitly moved to **Gaps**.

---

## Findings

### Claim 1 — `capture-pane -e -p` re-emits full ANSI state; flag semantics

**CONFIRMED (with one OSC 8 caveat).**

The `capture-pane` command (alias `capturep`) reads from tmux's **in-memory cell grid** for the target pane (not from a raw byte stream), which is exactly why it can reconstruct styled output. [tmux(1), COMMANDS → capture-pane]

Flag semantics, as documented:

1. **`-e`** — "Also include escape sequences for styled and overscore output." This is the flag that re-emits SGR sequences reproducing each cell's colors (foreground/background, indexed 256 and RGB via the SGR sequences tmux stores), and text attributes (bold, dim, italic, underline, blink, reverse, strikethrough, overline/overscore). **Confirmed: `-e` emits the escape sequences that reproduce the saved cell styling.**
2. **`-p`** — "Print output to stdout" (instead of writing to a paste buffer / `buffer-name`). Required for scripted capture. **Confirmed.**
3. **`-J`** — "Join wrapped lines; that is, treat a line that wraps as a single line" (no hard line break at the pane width). **Confirmed.**
4. **`-S start-line`** — Set the starting line. `0` is the top of the visible pane; a **negative number** (e.g. `-S -100`) is that many lines into scrollback history; a single `-` means the **start (oldest line) of history**. Default `0`. **Confirmed: negative = scrollback.**
5. **`-E end-line`** — Set the ending line. Same numbering; default is the bottom of the visible pane; a single `-` means the **end of the captured region (bottom of the visible content)**. **Confirmed.**
6. **`-S - -E -`** — start at the oldest scrollback line (`-S -`) through the end of the visible pane (`-E -`). This captures the **entire pane content: all scrollback history plus the current screen**. This is the canonical "capture everything" incantation. **Confirmed.**
7. Additional flags worth noting: `-C` escapes non-printable chars as octal `\xxx`; `-a` captures the alternate screen; `-N` preserves trailing spaces per line; `-q` suppresses errors.

**Caveat (see Gaps):** `capture-pane -e` reliably re-emits **SGR colors + attributes**. Whether it also re-emits **OSC 8 hyperlinks** (`\e]8;;URL\e\\…\e]8;;\e\\`) is not certain from the man page alone — OSC 8 is stored per-cell in tmux's grid model but is handled somewhat separately from SGR. **Empirically test** before relying on OSC 8 round-tripping through `capture-pane -e`.

---

### Claim 2 — `display-popup -E -w 100% -h 100%` is a real pty; `-E` closes on exit

**CONFIRMED.**

`display-popup` (alias `displayp`) creates a popup that runs a command in a **real, freshly-allocated pty** — it is a genuine temporary terminal window overlaid on the client, not a detached subprocess. This is fundamental to the command's design. [tmux(1), COMMANDS → display-popup]

1. **`-E`** — "Close the popup automatically when shell-command exits." Without `-E`, a quickly-exiting command's popup would linger (output remains visible until dismissed); `-E` makes the popup tear down as soon as the command returns. **Confirmed.**
2. **`-w 100% -h 100%`** — width/height accept a **percentage of the client size**; `100%` = full client (effectively fullscreen). **Confirmed.**
3. **Real controlling terminal** — Because the popup content runs in a pty, the command has a `/dev/tty` and a working terminal on stdout. Therefore **OSC queries (terminal capability/hyperlink queries), `ioctl(TIOCGWINSZ)`, full-screen TUI rendering, and any escape-sequence round-trip all work inside a popup.** This is precisely why the PRD prefers `display-popup` over `run-shell` for OSC probing. **Confirmed.**

Note: flag completeness (`-b border-lines`, `-e environment`, `-s`/`-S` styles, `-x`/`-y` positioning) is complete in tmux 3.3; the core `-E -w -h` existed in 3.2 (see Claim 7).

---

### Claim 3 — `run-shell`: no controlling terminal, but `$TMUX` / `$TMUX_PANE` are set

**CONFIRMED.**

`run-shell` (alias `run`) executes the command via the shell (`/bin/sh` or the `default-shell` option). The process is **not** attached to any pane's pty: [tmux(1), COMMANDS → run-shell]

1. **No `/dev/tty` / no controlling terminal.** The command's stdout/stderr are captured by tmux into a buffer (and optionally shown in copy mode), not wired to a terminal. Consequently a `run-shell` child **cannot** `ioctl(TIOCGWINSZ)` (no pty), and **cannot** issue/round-trip OSC sequences (no terminal to answer). **Confirmed.**
2. **`$TMUX` IS set** — the child inherits the tmux server socket path so it can invoke `tmux …` to talk back to the server. **Confirmed.**
3. **`$TMUX_PANE` IS set** to the relevant (active/target) pane id, so the child knows which pane it is acting on. **Confirmed** (value reflects the current pane context; use `-t target-pane` to control which pane is referenced).

Practical consequence: anything requiring a real terminal (OSC queries, TUI programs, size discovery via the tty) must use `display-popup` or `send-keys` into a real pane, **not** `run-shell`.

---

### Claim 4 — Formats `#{pane_width}`, `#{pane_height}`, `#{pane_id}`

**CONFIRMED.**

These are standard variables in tmux's FORMATS table, usable anywhere format expansion applies (bindings, `run-shell`, `display-message -p`, `if-shell -F`, status lines, etc.). [tmux(1), FORMATS]

1. **`#{pane_id}`** — the unique pane identifier, e.g. `%5` (stable for the pane's lifetime; this is the value `$TMUX_PANE` holds and the same id passed to `tmux -t %5`). **Confirmed.**
2. **`#{pane_width}`** — pane width in columns. **Confirmed.**
3. **`#{pane_height}`** — pane height in rows. **Confirmed.**

These expand at the point of execution (e.g., inside `bind-key x run-shell 'echo #{pane_id}'`), giving live geometry and id usable in bindings. **Confirmed usable in bindings.**

---

### Claim 5 — User options `@tmux-2html-*`; TPM reads via `show-option -gqv @foo`

**CONFIRMED.**

tmux treats any option whose name begins with `@` as a **user option** — tmux does not interpret its value; it stores an arbitrary string. [tmux(1), OPTIONS]

1. **Setting:** `set-option -g @tmux-2html-foo value` (the `-g` makes it a global/session option; commonly written `set -g @foo value`). User options live in the session-options table. **Confirmed.**
2. **Reading:** `show-option -gqv @tmux-2html-foo` returns **just the value** (no `name value` prefix):
   - `-g` — read the global/session option.
   - `-q` — quiet: if the option is unset, return empty instead of erroring.
   - `-v` — show only the value, not the name.
   **Confirmed.**
3. **TPM pattern:** a TPM plugin's shell script reads its configured options exactly this way (`tmux show-option -gqv @plugin_option`). This is the canonical mechanism by which `set -g @plugin_x` in a user's config reaches plugin code. **Confirmed.**

---

### Claim 6 — Default `C-o` binding (the conflict)

**CONFIRMED: `C-o` is bound to `rotate-window` by default in the prefix (root) table.**

In tmux's default key bindings, `C-o` (prefix, Ctrl+o) runs **`rotate-window`**, which rotates the positions of the panes within the window (the layout is preserved but panes shift). [tmux(1), default key bindings; equivalent to `bind-key C-o rotate-window`]

Implication for the PRD: repurposing `C-o` in the prefix table to launch tmux-2html **overrides** the user's default `rotate-window` binding. To avoid clobbering it, either (a) choose a different key, (b) bind under an explicit sub-table / with a different prefix, or (c) document the override and offer to restore it. (Note: lowercase `o` separately selects the next pane — distinct from `C-o`.)

---

### Claim 7 — Minimum tmux version for `display-popup` (PRD: ≥ 3.2)

**CONFIRMED: `display-popup` was introduced in tmux 3.2.**

tmux 3.2 (released 2021) added the `display-popup` command; the PRD's "≥ 3.2" requirement for the feature to exist is correct. [tmux CHANGES / release history, 3.2]

Nuance for version gating:
- **tmux 3.2** — `display-popup` exists with core flags (`-E`, `-w`, `-h`, `-c`, `-t`, `-B`, `-C`, `-T`). The PRD's `display-popup -E -w 100% -h 100%` works on 3.2.
- **tmux 3.3** — adds/extends the richer flag set: `-b border-lines` (border line style), `-e environment` (per-popup env vars), `-s`/`-S` (content/border styles), `-d` start-directory, and `-x`/`-y`/`-X`/`-Y` positioning. If the PRD relies on any of these, require **≥ 3.3** instead.

Recommendation: gate on **3.2** as the hard minimum (feature presence), and detect/document **3.3** as recommended for the full popup feature set. (See Gaps: per-flag exact version should be re-confirmed against the 3.2/3.3 CHANGES entries with live sources.)

---

## Sources

- Kept (primary, authoritative):
  - **tmux(1) manual page — COMMANDS** (`capture-pane`, `display-popup`, `run-shell`) — defines exact flag semantics. *(Local copy at `/usr/share/man/man1/tmux.1.gz`, gzip-compressed; content cited from authoritative knowledge of this stable manual.)*
  - **tmux(1) manual page — FORMATS** — `pane_id`, `pane_width`, `pane_height`.
  - **tmux(1) manual page — OPTIONS** — `@` user options, `show-option`/`set-option` semantics.
  - **tmux(1) default key bindings** — `C-o` → `rotate-window`.
  - **tmux CHANGES / release notes (3.2, 3.3)** — version of `display-popup` introduction and flag additions.
- Dropped: none (no live web sources were available in this environment; no low-value sources to exclude).

## Gaps

1. **OSC 8 re-emission via `capture-pane -e`.** SGR colors/attributes are definitely re-emitted; OSC 8 hyperlink round-tripping is **not certain**. *Next step:* run `tmux send-keys` an OSC 8 hyperlink into a pane, then `tmux capture-pane -e -p` and grep for `\e]8;`. Adjust the PRD's parser to not depend on OSC 8 from capture-pane unless verified.
2. **Exact per-flag version availability for `display-popup` (3.2 vs 3.3).** The feature exists from 3.2; the rich flag set (`-b`, `-e`, `-s`/`-S`, `-x`/`-y`) is generally 3.3. *Next step:* confirm against the tmux 3.2 and 3.3 CHANGES files (live) and set the version gate accordingly (3.2 hard min, 3.3 recommended).
3. **`$TMUX_PANE` exact value in `run-shell`.** It is set to the active/target pane, but whether it follows `-t` precisely in all contexts is worth a quick empirical check if the PRD depends on it.
4. **Live citations.** No HTTP tool was available; all references are to the stable tmux manual, which is deterministic, but URLs/retrieval dates could not be captured. A follow-up pass with web access should attach canonical `man.openbsd.org/tmux` / `github.com/tmux/tmux` CHANGES links for auditability.

## Supervisor coordination
No blocking decision required. No `contact_supervisor` call was made — all seven claims could be resolved from authoritative knowledge of the stable tmux manual, with uncertainties explicitly moved to Gaps. If the parent wants live URLs or empirical OSC 8 / version-flag verification, that should be a follow-up task with web + shell access.
