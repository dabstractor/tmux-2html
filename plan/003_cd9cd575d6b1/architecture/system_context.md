# System Context — Plan 003 (§7.1 Status-Line Hint Sync)

## Delta scope

Plan 003 is a **display-only micro-delta** against the PRD's §7.1 status-line
format. The PRD's §7.1 text was updated (in a prior session, commit `400b0eb`)
to advertise the copy-mode-parity keybindings:

```
[LINE|BLOCK]  row:N col:M  /pattern  N match(es)  v=sel C-v=block o=swap  Enter=render q=quit
```

…replacing the old `<S-sel>` conditional token. The TUI selection *behavior*
(§7.4) was also updated and is fully tested. However, the status-line
**display code** in `renderStatus()` was never changed — it still emits the
stale `<S-sel>` conditional. This plan closes exactly that one gap.

## What is already DONE (verified — do NOT re-implement)

| Item | Status | Evidence |
|---|---|---|
| §0.1 Operational safety tooling | DONE | `scripts/check-safety.sh`, `safe-run.sh`, `with-tmux-audit.sh`, `preflight.sh`, `hooks/pre-commit`, `.gitignore` — all exist and are wired |
| §7.4 Selection model (copy-mode parity) | DONE | `src/tui/select.zig` `applyAction()` (lines ~147–166): `v`/`V` ⇒ re-anchor linewise; `Ctrl-v`/`R` ⇒ toggle block; `o`/`O` ⇒ swap ends. Tests at `select.zig:391–624` |
| §7.4 Input decoding | DONE | `src/tui/input.zig` lines 236–240 decode all keys correctly |
| §17 Decisions log text | DONE | PRD text only, landed in `400b0eb` |

## What this plan does

**Sole gap:** Update `renderStatus()` in `src/tui/view.zig` to emit the new
static key-hint segment (`v=sel C-v=block o=swap`) instead of the old
conditional `<S-sel>` token, update the four `renderStatus` unit tests, and
update `docs/CONFIGURATION.md` to match.

## Safety considerations

- This is a **display-only** change — it touches no tmux server, no shell-out,
  no filesystem, no IPC. The §0/§0.1 isolated-harness rules are trivially
  satisfied.
- All work is pure Zig unit tests on `renderStatus` + a release build.
- If a TUI smoke test is desired, it MUST use an isolated, uniquely-named socket
  per PRD §0 — but none is required for this delta.

## Build environment

- Zig 0.15.2 is on PATH (verified).
- `zig build test` hits a known Debug-mode linker bug (`R_X86_64_PC64`) with
  bundled C++ SIMD libs; tests must run in `ReleaseFast`:
  `zig build test --release=fast`.

## Key files involved

| File | Role |
|---|---|
| `src/tui/view.zig` | `renderStatus()` function (lines 226–256), `Status` struct (line 84–91), doc comment (line 216), 4 unit tests (lines 713–800) |
| `src/tui/select.zig` | Line 45 comment references the old `<S-sel>` token — update comment only |
| `src/region.zig` | Line 192 sets `has_selection` — NO change needed (field retained per delta §3 recommendation) |
| `docs/CONFIGURATION.md` | Lines 114, 122–126 show the stale format — update to §7.1 shape |