# Delta PRD — §7.1 Status-Line Hint Sync (copy-mode parity follow-up)

> Delta scope: **Previous PRD → Current PRD** (this session). Source of truth is
> `PRD.md`. Every interface/path below is normative unless marked otherwise.
>
> **Read first:** PRD §0 and §0.1 (safety). This delta changes **display-only**
> TUI text; it touches no tmux server, so the §0/§0.1 isolated-harness rules are
> trivially satisfied (all work is pure unit tests on `renderStatus` + a build).

---

## 1. What changed in the PRD (diff summary)

Four textual changes between the previous and current PRD:

| # | PRD locus | Change | Lines |
|---|---|---|---|
| 1 | **§0.1** (new) | Added "Operational & system-safety rules" subsection: bounded `/tmp` usage, read-only capacity discovery, scoped FS scans, sequential heavy steps, bounded/leak-free harnesses, pause-on-instability. | ~25 added |
| 2 | **§7.1** | Status-line key hint changed from `…  <S-sel>Enter=render q=quit` to `…  v=sel C-v=block o=swap Enter=render q=quit`. | 1 |
| 3 | **§7.4** | Selection model rewritten: heading "both modes via `v`" → "tmux copy-mode parity". `v` now **begins/re-anchors** a linewise selection (discards prior); `Ctrl-v` **toggles** visual block (does not re-anchor); `V`=alias of `v`, `R`=alias of `Ctrl-v`. Fixes old behavior where `V` locked the starting line. | ~20 restructured |
| 4 | **§17** | Decisions-log "Selection model" entry updated to describe `v` re-anchor + `Ctrl-v` toggle. | 2 |

## 2. Implementation state — most of this delta is ALREADY DONE

Verified against the repo (this is reference, **not** work to redo):

- **§0.1 — DONE.** The normative safety tooling already exists and is wired into
  CI: `scripts/check-safety.sh` (static guard), `scripts/safe-run.sh`
  (`RLIMIT_FSIZE`/`RLIMIT_CPU` caps), `scripts/with-tmux-audit.sh` (approved
  absolute-path, recursion-guarded, byte-capped tmux shim),
  `scripts/preflight.sh` (residue/runaway scan), `scripts/hooks/pre-commit`,
  `.gitignore`. `AGENTS.md` maps every §0.1 bullet to a script. The shipped
  tests (`tests/*.sh`) do not misuse `/tmp`. PRD text landed in commit `e9e5042`.
  **→ No new implementation work for §0.1.**
- **§7.4 — DONE.** `src/tui/select.zig` `applyAction()` (lines ~147–166)
  correctly implements copy-mode parity: `visual_toggle`/`visual_line` (`v`/`V`)
  ⇒ `sel.begin(cursor, .linewise)` (re-anchor, discard prior);
  `visual_block` (`Ctrl-v`/`R`) ⇒ inactive→begin block / active→`toggle()`
  (no re-anchor); `swap_end`/`swap_end_other` (`o`/`O`) ⇒ `swapEnds()`.
  `src/tui/input.zig` (lines 236–240) decodes `v`/`V`/`0x16`/`R`/`o`/`O`
  correctly. Comprehensive tests exist (`select.zig:391–624`). PRD text landed
  in commit `400b0eb`. **→ No new implementation work for §7.4.**
- **§17 — DONE.** PRD text only; landed in `400b0eb`. **→ No work.**

**The sole remaining gap is #2, the §7.1 status-line key hint.** The TUI
selection *behavior* matches the new §7.4, but the status *line* still advertises
the old single-key model, so the on-screen hints are stale/inconsistent with the
actual keybindings. This delta closes exactly that gap.

## 3. The gap (normative)

**Current PRD §7.1** (selector `h2.7/h3.8`) mandates the copy-mode status line:

```
[LINE|BLOCK]  row:N col:M  /pattern  N match(es)  v=sel C-v=block o=swap Enter=render q=quit
```

**Actual code** (`src/tui/view.zig`, `renderStatus()`, lines ~216, 246–249)
still emits the **previous** shape:

```
…  <S-sel>  Enter=render q=quit      // <S-sel> is conditional on status.has_selection
```

Required change:
- Drop the conditional `  <S-sel>` token.
- Emit a single **static** key-hint segment `  v=sel C-v=block o=swap` before the
  existing static `  Enter=render q=quit` segment (so the always-shown tail reads
  `…  v=sel C-v=block o=swap  Enter=render q=quit`, matching §7.1 exactly).
- The `[LINE]`/`[BLOCK]` bracket, `row:N col:M`, and `/pattern  N match(es)`
  fields are unchanged.
- Update the `renderStatus` doc comment (line ~216) to the new hint string.
- `view.Status.has_selection` (line 90) becomes unused by `renderStatus` after
  this change. **Recommended (minimal):** retain the field — it is cheap, set by
  the caller, and the `[LINE]/[BLOCK]` bracket already conveys active-mode state;
  do not churn `region.zig`/test fixtures. (Optional: if a clean removal is
  preferred, also drop the field + its test fixtures + the `select.zig:45`
  comment referencing it. Either is acceptable; pick the minimal one.)

**Affected tests** (`src/tui/view.zig`, pure unit tests on `renderStatus`):
- `test "renderStatus: [LINE] full line …"` (~713) asserts `<S-sel>` present
  when `has_selection=true` → change to assert `v=sel C-v=block o=swap` present.
- `test "renderStatus: [BLOCK] mode + field order"` (~739) asserts `<S-sel>`
  absent when `has_selection=false` → the new hint is **always** shown, so change
  to assert the hint is present and that no `<S-sel>` token remains.
- `test "renderStatus: mode=.none omits the bracket …"` (~758) and the
  truncation test (~779): update any stale `<S-sel>`/hint expectations;
  confirm truncation still clamps to `cols` with the longer static tail.

## 4. Documentation impact

- **Mode A — doc-with-work (rides with the implementing task):**
  `docs/CONFIGURATION.md` currently **shows the old status line** and documents
  the old token semantics — line 114 reproduces
  `[LINE|BLOCK]  row:N col:M  /pattern  N match(es)  <S-sel>  Enter=render q=quit`,
  line 122 says *"`<S-sel>` — shown only when a selection is active"*, and
  line 123 lists `Enter=render q=quit`. These MUST be updated to the §7.1 shape:
  replace `<S-sel>` with the always-shown `v=sel C-v=block o=swap` hint and drop
  the "shown only when a selection is active" sentence. (The §7.4 keybinding
  table at `docs/CONFIGURATION.md:166` is already current — do not touch.)
  `README.md:102` says only *"The in-app status line lists every key"* (generic)
  → no change.
- **Mode B — changeset-level docs:** **Not applicable.** This is a one-line
  display fix with no new capability; `README.md`'s copy-mode/region description
  is already accurate to the shipped §7.4 behavior. No standalone changeset
  doc-sync task.

## 5. Work breakdown

One phase, one milestone, one task — sized to the actual (small) gap.

### Phase P1 — §7.1 Status-line hint sync

#### Milestone P1.M1 — Sync the TUI status line to the copy-mode-parity keybindings

**Task P1.M1.T1 — `renderStatus` emits `v=sel C-v=block o=swap`; tests + CONFIGURATION.md updated**

- **Subtask P1.M1.T1.S1** — Update `src/tui/view.zig` `renderStatus()`: remove
  the conditional `  <S-sel>` write; add the static `  v=sel C-v=block o=swap`
  segment immediately before `  Enter=render q=quit`; update the function
  doc-comment example to the §7.1 string; update the three `renderStatus` unit
  tests ([LINE]/[BLOCK]/mode=.none + truncation) to assert the new hint and the
  absence of `<S-sel>`. Verify `zig build test --release=fast` is green and the
  golden/envelope/select suites are byte-unchanged (this is display-only). No
  tmux integration is required; if a TUI smoke is desired it MUST use an
  isolated, uniquely-named socket per PRD §0 (never the user's server).
  - *Mode A doc:* update `docs/CONFIGURATION.md` lines ~114/122/123 to the new
    status-line shape in this same subtask.

## 6. Acceptance / verification

- `zig build --release=fast` clean; `zig build test --release=fast` green.
- `renderStatus` output for `[LINE]`, `[BLOCK]`, and `mode=.none` all contain
  `v=sel C-v=block o=swap` and `Enter=render q=quit`, and contain **no**
  `<S-sel>` token.
- The emitted status line matches PRD §7.1 byte-for-byte in field order:
  `[LINE|BLOCK]  row:N col:M  /pattern  N match(es)  v=sel C-v=block o=swap Enter=render q=quit`.
- `docs/CONFIGURATION.md` status-line example matches the code.
- PRD §0/§0.1 honored throughout (display-only change; no global tmux teardown).

## 7. Out of scope (do NOT do)

- Do **not** re-implement §0.1 tooling or §7.4 selection logic — both are
  complete and tested (see §2). Only the §7.1 status-line *display* is stale.
- Do **not** alter the `[LINE]`/`[BLOCK]` bracket, `row:col`, or search fields.
- Do **not** add new CLI flags, tmux options, or HTML-output changes — this
  delta is TUI-display-only.