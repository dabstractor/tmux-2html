# Research findings — P1.M3.T1.S1: Update README.md and overview docs to reflect bug fixes

> **Task type:** SOW Mode B documentation sweep (cross-cutting docs). The implementing
> subtasks (P1.M1.T1/T2, P1.M2.T1) already updated the inline comments/help/headers they
> touched (Mode A). THIS task sweeps README.md, docs/CONFIGURATION.md, AGENTS.md for any
> PROSE that still describes PRE-FIX behavior.

## 0. The three fixes this changeset ships (from the bugfix PRD)

- **Issue 1 (Major)** — `region` confirm over blank cells: previously wrote an empty-body HTML
  file + `.last-output` sidecar and exited 0. **Now** reuses `render.selectionBodyEmpty()` on the
  rendered fragment; if empty, prints `tmux-2html region: selection is empty`, writes no file and
  no sidecar, exits 1 — matching the `render --selection` path. (`src/region.zig` confirm arm;
  `render.selectionBodyEmpty` made `pub`.)
- **Issue 2 (Major)** — `render --cols 0` / `--rows 0`: previously segfaulted (Terminal.init
  cols=0). **Now** rejected with `tmux-2html render: --cols and --rows must be >= 1`, exit 1,
  nothing on stdout. (`src/render.zig` determineCols / run.) Also defensively guarded in region.
- **Issue 4 (Minor)** — `scripts/check-safety.sh`: WARN rule no longer fires on `plan/` docs, and
  `should_skip()` now drops YAML/JSON `key: "value"` prose so FAIL rules (which still scan repo-
  wide, including plan/) no longer false-positive on docs that merely *quote* the pattern names.
  Result: 0 FAIL / 0 WARN for the repo. (P1.M2.T1.S1, in flight in parallel — treat its PRP as a
  contract: the check-safety behavior below is what will ship.)

## 1. Doc surface in scope (verified via `ls` + `grep`)

Only three files hold user/agent-facing prose: `README.md`, `docs/CONFIGURATION.md`, `AGENTS.md`.
(`docs/` contains exactly one file: CONFIGURATION.md. No CHANGELOG, no separate docs/README.)

Neither README.md nor docs/CONFIGURATION.md has a **Changelog** or **Known Issues (bugs)**
section. Both have a **"Known limitations"** section — but that lists *inherent product
limitations* (alt-screen apps, scrollback cap), NOT resolved bugs. Per the item contract:
> "If no such section exists, no structural change is needed — the fixes are robustness
> improvements to existing features, not new capabilities."
→ **Do NOT add a Changelog or a new section.** Only FIX prose that describes pre-fix behavior.

## 2. STALE references found (MUST fix) — exact locations + before/after

### 2.1 docs/CONFIGURATION.md — "Confirm and cancel" paragraph (lines ~180-183) [Issue 1]
**Before (line 180-183):**
> **Confirm** — `Enter` (or `y`) renders the current selection to an HTML file, writes a
> `.last-output` sidecar next to the binary (so the plugin can flash the output path), honors
> `@tmux-2html-open`, and exits `0`. Confirming with **no** selection prints a warning and exits
> `1` with no file written.

**Problem:** "Confirming with **no** selection" only covers the inactive-selection case. Post-fix,
an *active* selection whose body is all blank cells ALSO warns + no file + no sidecar + exit 1.

**After (intended):** extend the last sentence to:
> Confirming with **no selection, or a selection whose rendered body is empty (e.g. a selection
> covering only blank cells — a trailing blank line)** prints a warning, writes **no file and no
> `.last-output` sidecar**, and exits `1`.

### 2.2 docs/CONFIGURATION.md — "Known limitations" → "Empty selection" bullet (lines ~336-338) [Issue 1] — THE stalest claim
**Before (line 336-338):**
> - **Empty selection.** Confirming an empty selection warns and writes no file (exit `1`).
>   `render --selection` and `region` each guard this in their own way (render checks the rendered
>   body; region checks whether a selection was begun).

**Problem:** "region checks whether a selection was begun" is the EXACT pre-fix behavior the bug
fixed. Post-fix, `region` checks the **rendered body** too (`render.selectionBodyEmpty`), so the
two paths now AGREE rather than differing.

**After (intended):**
> - **Empty selection.** Confirming an empty selection — **no selection begun, or an active
>   selection whose rendered body is all blank cells** (e.g. a single trailing blank line, or an
>   empty rectangle) — warns, writes no file and no `.last-output` sidecar, and exits `1`. Both
>   `render --selection` and `region` guard this by checking the rendered body, so the two paths
>   agree.

### 2.3 AGENTS.md — §3 protections table, `check-safety.sh` row (line 67) [Issue 4]
**Before (line 67):**
> | `scripts/check-safety.sh` | Static guard against §1 anti-patterns | `grep` rules; **FAIL** on global tmux kill + recursive bare-`exec tmux`; **WARN** on hand-rolled shim recipe (`PATH=…:$PATH` + append) outside `scripts/`. Exits non-zero on FAIL. |

**Problem:** WARN "outside `scripts/`" no longer holds — post-fix WARN also skips `plan/`. And FAIL
now relies on `should_skip()` to drop structured `key: "value"` prose so repo-wide FAIL scanning
doesn't false-positive on plan/ docs that quote the patterns.

**After (intended):**
> | `scripts/check-safety.sh` | Static guard against §1 anti-patterns | `grep` rules; **FAIL** on global tmux kill + recursive bare-`exec tmux`; **WARN** on hand-rolled shim recipe (`PATH=…:$PATH` + append) outside `scripts/` **and `plan/`**. FAIL rules scan repo-wide (including `plan/`) but `should_skip()` drops documentation (backticks, comments, and YAML/JSON `key: "value"` prose), so plan/ docs that merely quote the pattern names don't false-positive. Exits non-zero on FAIL. |

## 3. References REVIEWED and CONFIRMED NOT stale (no edit — verify only)

- **README.md** — entire file reviewed via `grep`. The "The region overlay" blurb ("press `Enter`
  to render the selection to an HTML file") is a high-level summary and does NOT contradict the
  empty-confirm guard (the detail correctly lives in docs/CONFIGURATION.md). The "Command line"
  mention of `--cols N` makes **no constraint claim** (doesn't say 0 is accepted) → the Issue 2
  segfault fix has **no stale doc to update** (per contract: "no structural change is needed").
  README "Known limitations" has no "Empty selection" bullet. → **README needs no edit.**
- **docs/CONFIGURATION.md line 104** ("Confirming a selection renders it to an HTML file") —
  high-level region-overlay intro summary; the confirm/empty detail is in the "Confirm and cancel"
  subsection (fixed in §2.1). Leave the summary as-is (optional: a one-clause "unless empty" hint;
  not required).
- **AGENTS.md line 13** (`plan/002_*/P1M1T3S1/PRP.md`) — a *factual historical* reference to where
  the ~12 GB incident pattern was documented. NOT a claim about check-safety scanning scope. Leave.
- **AGENTS.md lines 51-52** ("run check-safety.sh … after editing shell or plan docs") — still
  accurate (you SHOULD run it after editing plan docs; post-fix it won't false-positive). Leave.

## 4. Exact post-fix facts to keep wording faithful (from fix PRPs/architecture)

- Region empty confirm stderr: `tmux-2html region: selection is empty` (mirrors
  `tmux-2html render: selection is empty` from the `render --selection` path). Exit 1. No file,
  no `.last-output` sidecar. (architecture/issue1_region_empty_confirm.md.)
- `render --cols 0` / `--rows 0` stderr: `tmux-2html render: --cols and --rows must be >= 1`,
  exit 1, nothing on stdout. (PRD Issue 2; render.zig.) — NOT documented in any user doc by design
  (no stale claim existed); do not add a new section for it.
- check-safety post-fix: 0 FAIL / 0 WARN repo-wide. WARN gated by `!under_scripts && !under_plan`;
  FAIL scans repo-wide; `should_skip()` adds `case "$s" in *:[[:space:]][\'\"]*) return 0;; esac`
  to skip YAML/JSON `key: "value"` prose. (P1.M2.T1.S1/research/findings.md.)

## 5. Scope discipline (what NOT to do)

- Do NOT add a CHANGELOG / "Fixed" / "Known Issues (bugs)" section (contract: no such section
  exists; fixes are robustness improvements, not new capabilities).
- Do NOT edit the implementing-source files, scripts/, src/, tests/, or .github/ (Mode A already
  did / is doing that; P1.M2.T1.S1 owns scripts/check-safety.sh).
- Do NOT reword the README region blurb or `--cols N` mention (not stale).
- Do NOT touch the historical `plan/002_*` reference in AGENTS.md §0 (factual).

## 6. Validation

- Re-grep after edits: `grep -niE "whether a selection was begun|outside .scripts. "` on the three
  files must return NOTHING (the two stale phrases are gone).
- `scripts/check-safety.sh` must still exit 0 (edits are to .md files in repo root + docs/ +
  AGENTS.md; none are shell/snippets, so they cannot introduce a FAIL/WARN; and the §2.3 wording
  must not itself contain a literal dangerous command like `killall tmux`).
- `scripts/preflight.sh` clean (no residue).