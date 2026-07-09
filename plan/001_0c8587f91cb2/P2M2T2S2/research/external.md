# Research: tmux `display-popup` / `run-shell` binding for the tmux-2html `region` wrapper

## Summary
The man-page facts in the proposed binding check out: `display-popup -E` closes the popup when the shell command exits, `-w`/`-h` accept `%` of the client, the popup runs its command in a real pty, and `run-shell` expands `#{...}` formats before invoking the shell (so `#{pane_id}` resolves at fire time). **One framing correction:** a process inside a popup *can* emit a tmux message via `tmux display-message` — the sidecar file is needed because the outer `run-shell` continuation is a **separate process** that must receive the result **string** after the popup closes (a process exit returns only an **int**). **One timing risk to confirm:** whether `tmux display-popup` invoked from `run-shell` blocks the `;` chain until the popup closes.

> **Runtime caveat (read before citing):** This run had **no `web_search` tool**, and the local man page (`/usr/share/man/man1/tmux.1.gz`) is gzip-compressed and not readable by the file reader. The URLs/wording below are recalled from these canonical sources from training knowledge and were **not live-fetched** in this session. Verify exact wording/anchors against man.openbsd.org/tmux before pasting into the PRP. (You already empirically verified the runtime mechanics on tmux 3.6b, so this report covers documentation/refs only, as requested.)

---

## (a) References (canonical sources)

1. **tmux manual page** — <https://man.openbsd.org/tmux>
   *Why:* the authoritative reference for every flag below (`display-popup`/`displayp`, `run-shell`, `bind-key`). The `COMMANDS` and `KEY BINDINGS` sections are the primary citations. *(Section anchors like `#COMMANDS` were not live-verified — open the page and grab the exact anchor.)*
2. **tmux source & CHANGES** — <https://github.com/tmux/tmux> ; CHANGES: <https://raw.githubusercontent.com/tmux/tmux/master/CHANGES>
   *Why:* authoritative for `display-popup` landing in **tmux 3.2**, and for the canonical `tmux.1` wording of `-E`/`-w`/`-h`.
3. **tmux wiki (GitHub)** — <https://github.com/tmux/tmux/wiki>
   *Why:* community-maintained pages (Popup, Formats, Key Bindings) documenting practical usage and the client-requirement gotchas.
4. **tmux GitHub Issues / Discussions** — <https://github.com/tmux/tmux/issues> ; <https://github.com/tmux/tmux/discussions>
   *Why:* searchable archive for the "no current client"/"no clients" errors and popup-result-IPC workarounds. *(Specific issue numbers were **not** confirmed in this run — see Gaps.)*

## (b) Confirmed facts & gotchas

- **`-E` close-on-exit — CONFIRMED.** `display-popup -E [exit|no-exit|exit-copied]` closes the popup automatically when the shell command exits; plain `-E` = `exit`. [1][2]
- **`-w`/`-h` accept `%` — CONFIRMED.** Width/height may be a cell count or a **percentage of the client** size (e.g. `100%`). [1]
- **Popup runs in a real pty / controlling terminal — CONFIRMED.** The popup command runs in a pane with a controlling terminal (window-like), so interactive/TTY programs work. [1]
- **`run-shell` expands formats — CONFIRMED.** `#{...}` in the argument is expanded at **execution time** against the firing context, so `--target '#{pane_id}'` resolves to the focused pane when the key is pressed. [1]
- **`bind-key` without `-T`/`-n` binds the *prefix* table (not the root table) — CONFIRMED + minor correction.** Accessed after `prefix` (default `C-b`); `-n` binds the *root* (no-prefix) table. So `bind-key C-o …` fires on `prefix C-o`. [1, KEY BINDINGS]
- **`display-popup` requires a client — CONFIRMED gotcha.** A popup is drawn on a client; with none attached (or from a detached/script context) you get **"no clients" / "no current client"**. From a key binding it targets the **firing client** (overridable with `-c`). [1][3]
- **Minimum tmux 3.2 — CONFIRMED.** `display-popup` was introduced in tmux 3.2; 3.6b is well above. [2, CHANGES]

## Gotchas (severity-tagged)

- **HIGH — `display-popup` from `run-shell` may not block the `;` chain.** `tmux <command>` CLI invocations classically return **immediately** after issuing the command to the server. If that holds for `display-popup`, your `[ -f .last-output ] && display-message` runs at the instant the popup is *created* (before `tmux-2html region` finishes) and never sees the file. You verified mechanics on 3.6b — specifically confirm the message appears **after** the popup closes. If not, sync with `tmux wait-for` or emit the message from inside the popup command itself.
- **MEDIUM — citations are training-recalled, not live-fetched** this run. Verify exact man-page wording/anchors before citing as primary sources (no `web_search` available; local `tmux.1.gz` unreadable).
- **LOW — "no clients" when fired headless.** Fine for an interactive binding; document it.
- **LOW — quoting.** Nested `"$BIN/…"`, `$(cat …)`, `\"…\"` inside one `run-shell` string is fragile.

## (c) Correction to your understanding

**"A process inside `display-popup` cannot emit a tmux message / talk back to the message channel" — not quite.** The popup command runs in a pty within the **same tmux server**, inherits the tmux environment, and **can** run `tmux display-message` to write to the client's message line. The sidecar file is needed for a *different* reason: your **outer** `run-shell` chain is a **separate process** that runs the `[ -f .last-output ] && display-message` **after** the popup closes and needs the result **string** (the output path). A process exit returns only an **integer** — it cannot hand a string back. So the sidecar/tmp file is the standard **inter-process string IPC** between the popup program and the post-popup continuation. (A full-screen popup also visually occludes the status line while open, which is a second reason to surface the message *after* close via the outer continuation — good UX.)

## Opinion: `;` chaining vs. a wrapper script

Chaining with `;` works but is fragile: (1) the HIGH blocking-semantics risk above, and (2) nested quoting inside one `run-shell` string is hard to read and easy to break. A tiny wrapper script (`$BIN/popup-region.sh`) doing `rm` → `display-popup` → check → `display-message`, with the binding reduced to `bind-key C-o run-shell "$BIN/popup-region.sh '#{pane_id}'"`, is more idiomatic, testable, and quoting-safe. Recommend the script form in the PRP.

## Sources
- **Kept:** man.openbsd.org/tmux — primary man-page authority for every flag above.
- **Kept:** github.com/tmux/tmux (+ CHANGES) — version history (3.2 intro) and canonical `tmux.1` source.
- **Kept:** github.com/tmux/tmux/wiki — practical popup/format guidance.
- **Dropped:** generic "tmux popup tutorial" blog/SEO hits — not authoritative; would need a live fetch to vet.

## Gaps
- **No live web access in this run** (no `web_search`; local `tmux.1.gz` gzip-unreadable). Citations are from training knowledge of canonical sources. Before publishing the PRP: open man.openbsd.org/tmux and confirm exact `-E`/`-w`/`-h`/`run-shell`/`bind-key` wording and section anchors.
- **Specific issue/discussion numbers** for "popup result back to outer shell" and "no current client" were not confirmed (needs live search of tmux issues/discussions). The architectural reasoning stands regardless.
- **`display-popup` blocking semantics via the `tmux` CLI** — couldn't be definitively documented here; needs targeted verification (HIGH residual risk above).

## Supervisor coordination
No decision needed. Flagged for the parent in-line: this research was produced from training knowledge only (web_search unavailable; local man page gzipped/unreadable), so URL wording/anchors and any specific issue numbers must be verified before the PRP cites them as primary sources.
