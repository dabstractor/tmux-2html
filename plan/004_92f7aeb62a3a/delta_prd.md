# Delta PRD — Pane-Anchored Region Overlay Host

> Delta against the committed `PRD.md` (snapshot in `plan/004_92f7aeb62a3a/prd_snapshot.md`).
> The PRD change is **already landed** in commit `382d838` ("Anchor region overlay to
> source pane dimensions", PRD.md only: +80/−13). This delta implements the **code +
> test + docs** to match the updated PRD. It is a **single design-decision change**;
> keep scope tight.

---

## 1. What changed (diff analysis)

The PRD changed **exactly one design decision**: the host for the `region` TUI.

| Aspect | Before (committed code today) | After (updated PRD) |
|---|---|---|
| Popup geometry | `display-popup -E -w 100% -h 100%` (forced fullscreen = client dims) | `display-popup -B -E -w "#{pane_width}" -h "#{pane_height}" -x P -y P -t "#{pane_id}"` (pane-sized, borderless, anchored over the pane) |
| Inner pty size | client_width × client_height (often wider/taller than the pane) | exactly pane_width × pane_height (1:1 with the grid) |
| Position | centered / fullscreen | top-left aligned over the source pane (`-x P -y P`) |
| tmux runtime | ≥ 3.2 (`display-popup` exists) | ≥ 3.3 (`-B` borderless + pane-anchored `-x`/`-y` position tokens) |
| Rationale | none recorded | new PRD §2 finding #7 + §7.0: an external program cannot take over a pane (copy mode is server-internal; `respawn-pane`/`kill-pane` destroy the program, forbidden by §0; `pipe-pane` is output-only). A pane-overlay popup is the faithful, non-destructive host. |

**Why it matters:** the fullscreen popup gave the TUI a pty *wider* than the captured
pane, so the grid (sized from `#{pane_width}`) never filled the overlay and content
rendered at the wrong scale. A pane-sized, borderless popup makes the TUI's own pty
dims (read via `ioctl(TIOCGWINSZ)` in `region.zig`) **exactly equal** the grid dims —
1:1 rendering fidelity, and the user controls the rendered width by sizing the pane
first.

**Sizing:** this is a **small-to-medium change**. One binding string in one shell
script, one test helper pattern, and a doc sweep across two files. **No Zig code
changes** — `region.zig:346` already does
`const ws = render.getSize() catch .{ .cols = cap.cols, .rows = cap.rows }`,
so when the popup is pane-sized everything aligns automatically.

## 2. Removed / out-of-scope

- The PRD's new §2 finding #7 and §7.0 are **rationale documentation** — they explain
  *why* the design is what it is. They require no code; the rationale already
  justifies the binding string below. Do not re-derive or re-verify the tmux internals.
- No change to the `region` Zig subcommand, the TUI event loop, the selection model,
  the renderer, the palette subsystem, capture, or any other subcommand.
- The palette auto-sync popup (`docs/CONFIGURATION.md:244`, a 50% popup) is a
  **different** popup and is **not** affected. Do not touch it.

## 3. Scope of work (requirements)

### R1 — Region binding uses the pane-anchored popup (PRD §7.0, §9.3)

The `C-o` region binding in **`tmux-2html.tmux`** (currently the single line at the
`[ "$binary_ready" = 1 ] && tmux bind-key "$region_key" run-shell \` block) MUST launch
the popup with the PRD §7.0/§9.3 invocation instead of the fullscreen one.

**Normative target invocation** (from PRD §9.3), with the existing `.last-output`
sidecar wrapper preserved around it:
```
tmux display-popup -B -E -w "#{pane_width}" -h "#{pane_height}" -x P -y P -t "#{pane_id}" \
  "$TMUX_2HTML_BIN/tmux-2html region --target '#{pane_id}' …"
```
The `-B` (borderless), `-w "#{pane_width}"`, `-h "#{pane_height}"`, `-x P`, `-y P`, and
`-t "#{pane_id}"` flags are all required. The `.last-output` read-back +
`display-message` tail and the pre-popup `rm -f` are **unchanged** — only the
`display-popup` flag set changes.

**Quoting GOTCHA (must preserve the proven three-layer pattern):** `#{pane_width}`,
`#{pane_height}`, and `#{pane_id}` are **tmux formats** that must survive the run-shell
`/bin/sh` *literally* and be expanded by tmux at fire time — so they go in **single
quotes** inside the inner command (exactly as `#{pane_id}` already does today). Do
**not** let them be expanded now. `$TMUX_2HTML_BIN`, `$title_arg`, `$lang_arg` remain
expanded-now (exported vars don't reach run-shell children). The whole inner
`display-popup` command stays wrapped in the escaped double quotes (`\"…\"`) of the
outer `bind-key … run-shell "…"` string.

**Comment block** above the binding (the `# PRD §9.3 + §7.5: … opens a full-screen tmux
display-popup …` block) must be updated to describe the pane-anchored popup and cite
§7.0, so the comment no longer claims "full-screen".

- **Doc-with-work (Mode A):** `docs/CONFIGURATION.md` — update the two region-overlay
  references that still say "full-screen":
  - line 41 (the `@tmux-2html-region-key` option row): "open the full-screen region
    overlay (TUI)" → describe the pane-anchored overlay (sized to the current pane).
  - lines ~98 (the "## The region overlay" section opener): "a full-screen
    `tmux display-popup` running `tmux-2html region`" → a pane-anchored
    `display-popup` sized to exactly overlay the source pane (`#{pane_width}`×
    `#{pane_height}`, borderless), citing §7.0. Keep the rest of the section
    (scrollback capture, cursor-on-last-row, confirm/cancel) as-is.

### R2 — Region binding test matches the new invocation (PRD §15)

**`tests/plugin_options.sh`** currently extracts the inner popup command with a sed
pattern hardcoded to the old fullscreen prefix:
```
sed 's/.*display-popup -E -w 100% -h 100% "//; s/"; if.*//'
```
(line ~97, inside the `c.3` "REGION nested quoting" block). This pattern will **fail to
match** the new pane-anchored prefix, breaking the `/bin/sh -n` validation of the inner
region command. Update the sed extraction so it strips the new
`display-popup -B -E -w '#{pane_width}' -h '#{pane_height}' -x P -y P -t '#{pane_id}' "`
prefix (or, more robustly, strips up to the first `display-popup ` and the closing of
its shell-quoted region command) and still leaves the inner
`tmux-2html region … --target '#{pane_id}'` string for `/bin/sh -n`. The assertion's
intent (the apostrophe/region inner command parses cleanly) is unchanged.

The test runs against the existing **mock** tmux harness (no real tmux server is
touched — satisfies §0/§0.1 trivially).

### R3 — Sync changeset-level documentation (Mode B; depends on R1+R2)

**`README.md`** has three region/runtime references that are now stale and only make
sense once the binding change (R1) is in place:

- line 26 (feature bullet): "Opens a copy-mode-style **full-screen** overlay over the
  scrollback" → pane-anchored overlay sized to the current pane.
- lines 31–32 (Requirements): "**tmux >= 3.2.** … `display-popup`, which tmux 3.2
  introduced." → **tmux >= 3.3**, because the region overlay uses `-B` borderless +
  pane-anchored `-x`/`-y` position tokens (PRD §7.0/§12). (The palette auto-sync popup
  only needs `display-popup`, which 3.2 has, so the binding of the *version floor* to
  the region overlay's flags is the correct framing.)
- line 99 ("## The region overlay" opener): "open a **full-screen**, copy-mode-style
  overlay over the pane scrollback" → pane-anchored, sized to the pane.

These are overview-level (feature blurb + version requirement), so they are the final
Mode B sweep. Do not add new capability claims; this is a wording + version-bump fix.

---

## 4. What is already done (do NOT re-implement)

| Item | Status | Evidence |
|---|---|---|
| PRD text for §1.1, §2 #7, §3, §5.3, §7/§7.0, §9.3, §12, §17 | DONE | commit `382d838` |
| §0.1 safety tooling (`check-safety.sh`, `safe-run.sh`, `with-tmux-audit.sh`, `preflight.sh`) | DONE | prior sessions |
| §7.4 selection model + status-line hints (copy-mode parity) | DONE | Plan 003 (commit `13b5798`); `src/tui/select.zig`, `view.zig` |
| Region Zig subcommand sizing (`getSize()` → tty dims; grid from pane geometry) | DONE | `src/region.zig:346`, `src/capture.zig:182` — needs **no** change; pane-sized popup makes them align automatically |
| `.last-output` sidecar wrapper + `display-message` tail | DONE | `tmux-2html.tmux` C-o binding — preserved verbatim around the new flags |

## 5. Verification

```sh
# 1. Static: the loader is valid POSIX sh and the test harness still parses.
sh -n tmux-2html.tmux
sh -n tests/plugin_options.sh

# 2. Plugin option/binding test (mock tmux; no real server touched).
bash tests/plugin_options.sh    # expect: PASS

# 3. Safety gate (no §1 anti-patterns introduced by the new flags/strings).
scripts/check-safety.sh
scripts/preflight.sh

# 4. (Optional) confirm the Zig suite is unaffected — run in ReleaseFast (PRD §15).
zig build test --release=fast
```

Manual check (only if a live isolated tmux is available — **never** the user's
server): bind `C-o`, open a non-zoomed pane, trigger the region overlay, and confirm
the popup is the exact width/height of the pane (content fills it edge-to-edge, no
border) and closes leaving the original pane's program untouched. This is optional;
the mock-based `tests/plugin_options.sh` is the required gate.

## 6. Safety

This delta touches **only** a tmux binding string, a test helper, and documentation.
It shells out to **no** tmux server at implementation time; the test uses the existing
mock. The §0 (never touch the user's tmux) and §0.1 (bounded, leak-free harnesses)
rules are trivially satisfied. The new `-t "#{pane_id}"` is a **display-popup target**
for position computation — it is not a mutation of the user's pane.

---

## 7. Task breakdown (proportional: 1 phase, 1 milestone, 2 tasks)

### Phase P1 — Pane-anchored region overlay

#### Milestone P1.M1 — Implement the binding, its test, and the detailed doc

**Task P1.M1.T1 — Region binding uses the pane-anchored popup (R1 + R2 + Mode A docs)**
Replace the `display-popup -E -w 100% -h 100%` flag set in the `C-o` binding
(`tmux-2html.tmux`) with the PRD §7.0/§9.3 pane-anchored, borderless invocation
(`-B -w "#{pane_width}" -h "#{pane_height}" -x P -y P -t "#{pane_id}"`), preserving the
existing `.last-output` sidecar wrapper and the three-layer quoting (tmux formats in
single quotes; `$TMUX_2HTML_BIN`/`$title_arg`/`$lang_arg` expanded now). Update the
comment block above the binding to describe the pane-anchored host and cite §7.0. Update
the `tests/plugin_options.sh` sed extraction (c.3 block) to match the new prefix so the
inner-command `/bin/sh -n` validation still passes. Update the two "full-screen"
region-overlay references in `docs/CONFIGURATION.md` (Mode A doc-with-work). Verify with
`sh -n`, `tests/plugin_options.sh`, `scripts/check-safety.sh`, and
`scripts/preflight.sh`.
  - **Subtask P1.M1.T1.S1** — Edit the binding string + comment in `tmux-2html.tmux`,
    the sed pattern in `tests/plugin_options.sh`, and the two `docs/CONFIGURATION.md`
    region-overlay lines; run the verification commands. (1 story point.)

**Task P1.M1.T2 — Sync README.md to the pane-anchored overlay (R3, Mode B)**
Update the three stale region/runtime references in `README.md`: the feature bullet
(line 26, "full-screen overlay"), the Requirements version floor (lines 31–32,
"tmux >= 3.2 … tmux 3.2 introduced" → "tmux >= 3.3", because the region overlay needs
`-B` borderless + pane-anchored `-x`/`-y`), and the region-overlay section opener
(line 99, "full-screen, copy-mode-style overlay"). This is the final changeset-level
sweep; it depends on T1 so the overview matches the shipped binding. Log the
changed/unchanged decision in completion notes.
  - **Subtask P1.M1.T2.S1** — Apply the three `README.md` edits; confirm no other
    region/runtime wording is stale. (1 story point; depends on P1.M1.T1.S1.)