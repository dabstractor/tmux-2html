# System Context — Plan 004: Pane-Anchored Region Overlay Host

> **Scope of this plan.** This is a **delta plan** against the committed `PRD.md`
> (snapshot: `plan/004_92f7aeb62a3a/prd_snapshot.md`). The PRD text for this change
> **already landed** in commit `382d838` ("Anchor region overlay to source pane
> dimensions", PRD.md only, +80/−13). Plan 004 implements the **code + test + docs**
> to match the updated PRD. It changes **exactly one design decision**: the host of
> the `region` TUI. Everything below was verified by reading the live repo files
> (not the delta's assertions) on `tmux 3.6a`.

---

## 1. The one design decision that changed

The `C-o` region binding launches a `tmux display-popup` that runs the region TUI.

| Aspect | TODAY (committed code) | TARGET (PRD §7.0 / §9.3) |
|---|---|---|
| Popup geometry | `display-popup -E -w 100% -h 100%` (forced fullscreen = client dims) | `display-popup -B -E -w "#{pane_width}" -h "#{pane_height}" -x P -y P -t "#{pane_id}"` (pane-sized, borderless, anchored over the pane) |
| Inner pty size | client_width × client_height (often wider/taller than the pane) | exactly `pane_width × pane_height` (1:1 with the captured grid) |
| Position | fullscreen / centered | top-left aligned over the source pane (`-x P -y P`) |
| tmux floor | ≥ 3.2 (`display-popup` exists) | ≥ 3.3 (`-B` borderless + pane-anchored `-x`/`-y`) |

**Why:** the fullscreen popup gave the TUI a pty *wider* than the captured pane, so
the grid (sized from `#{pane_width}`) never filled the overlay and content rendered at
the wrong scale. A pane-sized, borderless popup makes the TUI's own pty dims (read via
`ioctl(TIOCGWINSZ)` in `region.zig`) **exactly equal** the grid dims → 1:1 fidelity.

## 2. Verified current state of every file this delta touches

### 2.1 `tmux-2html.tmux` — the `C-o` region binding (MUST change)

The binding lives in the "C-o region binding — P2.M2.T2.S2" section. The exact current
line (after source-time expansion of `$TMUX_2HTML_BIN`, `$title_arg`, `$lang_arg`) is:

```sh
[ "$binary_ready" = 1 ] && tmux bind-key "$region_key" run-shell \
    "last=\"$TMUX_2HTML_BIN/.last-output\"; rm -f \"\$last\"; tmux display-popup -E -w 100% -h 100% \"$TMUX_2HTML_BIN/tmux-2html region $title_arg $lang_arg --target '#{pane_id}'\"; if [ -f \"\$last\" ]; then out=\$(cat \"\$last\"); tmux display-message \"tmux-2html: wrote \$out\"; fi"
```

The **only** token that changes is the `display-popup` flag set:
`display-popup -E -w 100% -h 100%` →
`display-popup -B -E -w '#{pane_width}' -h '#{pane_height}' -x P -y P -t '#{pane_id}'`.

Everything else is **preserved verbatim**: the `last=…/.last-output` sidecar wrapper,
the pre-popup `rm -f`, the post-popup `if [ -f "$last" ] … display-message` tail, and
the escaped-double-quote wrapping of the inner popup command.

**Three-layer quoting (GOTCHA — must survive the edit).** The whole region command is
the argument to `bind-key … run-shell "…"`. Inside it:
- `$TMUX_2HTML_BIN` is expanded **NOW** at source time (exported vars don't reach
  run-shell children) — appears in `last=`, the binary path, and `.last-output`.
- `$title_arg` / `$lang_arg` are expanded **NOW** (baked at source time).
- `#{pane_id}` is stored **LITERAL** — run-shell expands it at fire time. It is in
  single quotes (`--target '#{pane_id}'`) so run-shell's `/bin/sh` leaves it alone.
- The NEW `#{pane_width}`, `#{pane_height}` (and the second `#{pane_id}` in `-t`) are
  **also tmux formats** that must survive `/bin/sh` literally → they go in **single
  quotes**: `-w '#{pane_width}' -h '#{pane_height}' -t '#{pane_id}'`. `-x P` / `-y P`
  are literal tokens (no `$`, no `{}`) and need no quoting.
- `\"`, `\$out`, `\$(…)` stay escaped (deferred to fire time).

Target source line (the single replacement):

```sh
[ "$binary_ready" = 1 ] && tmux bind-key "$region_key" run-shell \
    "last=\"$TMUX_2HTML_BIN/.last-output\"; rm -f \"\$last\"; tmux display-popup -B -E -w '#{pane_width}' -h '#{pane_height}' -x P -y P -t '#{pane_id}' \"$TMUX_2HTML_BIN/tmux-2html region $title_arg $lang_arg --target '#{pane_id}'\"; if [ -f \"\$last\" ]; then out=\$(cat \"\$last\"); tmux display-message \"tmux-2html: wrote \$out\"; fi"
```

**Comment block above the binding** (the `# PRD §9.3 + §7.5: … opens a full-screen tmux
display-popup …` block) currently claims "full-screen". It MUST be rewritten to describe
the pane-anchored, borderless host and cite **§7.0** (so the comment no longer lies).

### 2.2 `tests/plugin_options.sh` — the `c.3` sed pattern (MUST change)

The test sources `tmux-2html.tmux` under a mock `tmux()` and validates that the region
inner popup command parses under `/bin/sh -n`. The `c.3` block (REGION nested quoting)
hardcodes the OLD fullscreen prefix in its sed extraction:

```sh
rinner=$(printf '%s' "$rline" | sed 's/.*display-popup -E -w 100% -h 100% "//; s/"; if.*//')
```

This sed **will not match** the new pane-anchored prefix, so `rinner` becomes empty /
garbage and the `/bin/sh -n` assertion is meaningless (or spuriously passes on empty).

**Robust fix (recommended):** stop hardcoding the flag set; strip up to the first
`display-popup ` and the first `"` after it, regardless of flags:

```sh
rinner=$(printf '%s' "$rline" | sed "s/.*display-popup [^\"]*\"//; s/\"; if.*//")
```

This matches BOTH the old (`-E -w 100% -h 100%`) and new (`-B -E -w '…' -h '…' -x P -y P -t '…'`)
prefixes, because `[^"]*` consumes any flags containing no `"`, then the first `"` opens
the inner command. The trailing `s/"; if.*//` is unchanged. The assertion intent (the
apostrophe-escaped inner region command parses cleanly) is unchanged.

The test uses the existing **mock** tmux harness (`W=$(mktemp …)`; a shell-function
override). It touches **no real tmux server** → satisfies PRD §0 / §0.1 trivially. The
mock captures `bind-key)` as `BK <key> run-shell <rest>` and the c.3 block greps that
capture for the line containing `region`.

### 2.3 `docs/CONFIGURATION.md` — two "full-screen" references (Mode A, ride with the work)

1. **Options table** — the `@tmux-2html-region-key` row currently reads:
   `Prefix key: open the full-screen region overlay (TUI).`
   → rewrite to describe the pane-anchored overlay (sized to the current pane).
2. **"## The region overlay" section opener** — currently:
   "`prefix C-o` (the `@tmux-2html-region-key`) opens the region overlay: a
   full-screen `tmux display-popup` running `tmux-2html region`."
   → rewrite to "a pane-anchored `tmux display-popup` sized to exactly overlay the
   source pane (`#{pane_width}`×`#{pane_height}`, borderless)", citing §7.0. Keep the
   rest of the section (full-scrollback capture, cursor-on-last-row, confirm/cancel)
   unchanged.

These are the docs **directly touched by the binding change**, so they ride WITH the
binding subtask (Mode A), not as a separate docs task.

### 2.4 `README.md` — three stale references (Mode B, final sweep; depends on the binding)

1. **Capture modes → Region bullet**: "Opens a copy-mode-style **full-screen** overlay
   over the scrollback …" → pane-anchored, sized to the current pane.
2. **Requirements** (tmux version floor): "**tmux >= 3.2.** … `display-popup`, which
   tmux 3.2 introduced." → **tmux >= 3.3**, because the region overlay uses `-B`
   borderless + pane-anchored `-x`/`-y` (PRD §7.0 / §12). The palette auto-sync popup
   (a 50% popup, no `-B`/`-x P`/`-y P`) still works on 3.2; the version floor is bound
   to the region overlay's flags.
3. **"## The region overlay" opener**: "open a **full-screen**, copy-mode-style
   overlay over the pane scrollback" → pane-anchored, sized to the pane.

These are overview-level (feature blurb + version requirement) → the final Mode B task.

## 3. Files that MUST NOT change (verified — no Zig work)

- **`src/region.zig`** — line ~346 does `const ws = render.WindowSize = render.getSize()
  catch .{ .cols = cap.cols, .rows = cap.rows };`. `getSize()` reads the popup's own pty
  via `ioctl(TIOCGWINSZ)`. When the popup is pane-sized, the pty dims **automatically**
  equal the captured grid dims (`cap.cols`/`cap.rows` from `#{pane_width}`/`#{pane_height}`).
  No edit needed — the change is purely the popup flag set.
- **`src/capture.zig`** — `geometry()` reads `#{pane_width} #{pane_height} #{history_size}`
  in one `display-message` call. Unchanged.
- **The palette auto-sync popup** (`tmux-2html.tmux` §"Palette auto-sync popup") is a
  DIFFERENT popup (`-w 50% -h 50%`, no `-B`/`-x P`/`-y P`). Do NOT touch it.
- **`src/tui/*`** (app/view/select/input/motion) — the TUI internals are unchanged.

## 4. Local environment (verified)

- `tmux -V` → **3.6a** (≥ 3.3, so all flags are live and testable).
- `tmux display-popup` usage confirms valid flags: `-BCEkN`, `-w`, `-h`, `-x`, `-y`,
  `-t`, `-e`, etc. **`-B` = borderless** (confirmed by `man tmux`: "-B does not surround
  the popup by a border"). `popup_pane_left` / `popup_pane_bottom` exist as formats.
- Isolated-server parse check: `tmux -L <sock> display-popup -B -E -w '#{pane_width}' -h
  '#{pane_height}' -x P -y P -t <pane> 'true'` produced only **"no current client"**
  (headless: popups need an attached client to *display*) — **no USAGE / flag error**,
  i.e. the flag set and `P` position tokens are syntactically valid on 3.6a. A full
  visual confirmation requires an attached client (the manual check in §5 of the delta).

## 5. Safety (PRD §0 / §0.1 + AGENTS.md)

This delta touches a **tmux binding string**, a **test helper**, and **docs**. It shells
to **no** tmux server at implementation time; the test uses the existing mock. The new
`-t "#{pane_id}"` is a `display-popup` **target for position computation** — not a
mutation of the user's pane. The safety scripts (`scripts/check-safety.sh`,
`scripts/preflight.sh`) MUST still be run as gates. `scripts/with-tmux-audit.sh` is not
needed (no tmux-call interception here).