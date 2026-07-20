# PRP — P1.M1.T1.S2: Add empty-selection guard in `region.zig` confirm arm

## Goal

**Feature Goal**: Close the PRD §13 / Issue 1 gap in `src/region.zig`'s `.confirm`
arm by adding a **tier-2 emptiness guard** that fires AFTER the selection is
rendered: if the rendered HTML body is empty/all-whitespace (an active selection
over blank cells), warn to stderr, write **no** HTML file, write **no**
`.last-output` sidecar, and exit **1** — mirroring the sibling `render --selection`
path exactly. Also correct the inline comment that misread PRD §13.

**Deliverable**: A self-contained edit to **`src/region.zig` only**:
1. Insert a 5-line guard block immediately after `defer allocator.free(html);`
   (region.zig:475), before `resolveOutputPath` (region.zig:479).
2. Rewrite the comment at region.zig:441–444 to document the **two-tier** guard
   (tier 1 = no selection begun / inactive; tier 2 = selection over blank cells).

No other file changes. No new test in this task (the helper's logic is already
unit-tested in render.zig; the pty integration test is **S3**).

**Success Definition**: `zig build test --release=fast` exits 0 (no regression —
non-empty confirms have content, so the new guard never fires on the existing
path); `zig build --release=fast` builds clean; on an empty/blank-cell confirm
the region path now writes nothing to disk/sidecar and exits 1 (proven by S3's
pty test; for S2 the manual repro from the bug report or pure reasoning suffices).

## User Persona

**Target User**: End users of `tmux-2html region` (the interactive copy-mode TUI).

**Use Case**: The user presses `v` to begin a selection on a blank row (e.g. the
shell's current empty input line, or a trailing blank line) and hits `Enter`/`y`
to confirm without moving the cursor.

**Pain Points Addressed**: Today this writes a confusing complete-but-empty-body
HTML page, writes a `.last-output` sidecar pointing at it, and exits 0 — the user
gets a blank browser page. After this fix: a clear `tmux-2html region: selection
is empty` warning, no file, no sidecar, exit 1 — exactly like `render --selection`.

## Why

- **PRD §13 compliance** (normative): "Empty/zero-cell selection on confirm: warn,
  no file written, exit `1`." The requirement is *specifically* about the region
  TUI's `Enter`/`y` confirm. The region path guarded only the *inactive-selection*
  case (tier 1) and missed the *active-selection-over-blank-cells* case (tier 2).
- **Consistency with the sibling path**: `render --selection` already does this
  check (`render.zig:788`, `selectionBodyEmpty`). Reusing the SAME proven helper
  (made `pub` by S1) keeps the two selection-rendering paths identical in behavior.
- **Resolves Issue 3 for free**: the `.last-output` sidecar write
  (`writeLastOutput`, region.zig:498) is AFTER the new break point, so the empty
  path never writes the sidecar — no stale residue.
- **Minimal & safe**: additive control-flow (one `if` + `break`) reusing an
  existing, unit-tested helper. Non-empty confirms are provably unaffected
  (`selectionBodyEmpty` ⇒ `false` for any content).

## What

User-visible: confirming a blank-cell selection in `tmux-2html region` now prints
`tmux-2html region: selection is empty` to stderr, creates no file and no
`.last-output` sidecar, and exits 1. Confirming a non-empty selection is
unchanged (file + sidecar + exit 0).

Technical: one `if (render.selectionBodyEmpty(html)) { stderr…; break :confirm_render 1; }`
inserted between the html `defer` (line 475) and the output-path resolution (line
479), plus a comment rewrite at lines 441–444 describing the two-tier guard.

### Success Criteria

- [ ] Guard inserted after `defer allocator.free(html);` (region.zig:475), before
      the output-path comment / `resolveOutputPath` (region.zig:477/479).
- [ ] Empty path `break :confirm_render 1` (NOT `return 1`) — region's confirm is
      a labeled block; the break value becomes the exit code.
- [ ] Message exactly `tmux-2html region: selection is empty\n` to `stderr` (mirrors
      `render.zig:789` with a `region` prefix; newline-terminated like every other
      region stderr line).
- [ ] Comment at region.zig:441–444 rewritten to document tier 1 (inactive) vs
      tier 2 (blank cells) and correct the PRD §13 misreading.
- [ ] `zig build test --release=fast` exits 0; `zig build --release=fast` builds.
- [ ] Only `src/region.zig` modified; no other file touched.

## All Needed Context

### Context Completeness Check

_Pass: "If someone knew nothing about this codebase, would they have everything
needed to implement this successfully?"_ — Yes. Both edits are given verbatim
(before/after) with exact line anchors verified against HEAD. The defer/break
semantics (why html is freed and the file/sidecar writes are skipped) are
explained. The reason `selectionBodyEmpty` works on the full-document `html`
(single `<pre>` in the §8.1 envelope; malformed ⇒ non-empty fallback) is given.
No guessing required.

### Documentation & References

```yaml
# MUST READ — the Issue 1 analysis + fix plan (authoritative)
- file: plan/004_92f7aeb62a3a/bugfix/001_678d4c980a19/architecture/issue1_region_empty_confirm.md
  why: "Specifies the exact insertion point, the guard code, the 'selectionBodyEmpty works on full-doc html' rationale, and that Issue 3 is subsumed."
  critical: "Insert AFTER defer allocator.free(html) and BEFORE resolveOutputPath so neither file nor sidecar is written."

# MUST READ — the input contract: S1 makes selectionBodyEmpty pub (assume done)
- file: plan/004_92f7aeb62a3a/bugfix/001_678d4c980a19/P1M1T1S1/PRP.md
  why: "S1 changes `fn selectionBodyEmpty` -> `pub fn selectionBodyEmpty` at render.zig:609. S2 calls `render.selectionBodyEmpty(html)`; do NOT re-edit render.zig."
  pattern: "S1 is visibility-only; the helper body/caller/test are unchanged."

# MUST READ — the file being edited
- file: src/region.zig
  section: ".confirm arm :438-509; tier-1 guard :445; html defer :475; resolveOutputPath :479; writeHtmlAtomic :487; writeLastOutput :498"
  why: "The ONLY file this task touches. Insert the guard after :475; rewrite the comment at :441-444."
  pattern: "Every error path uses `stderr.writeAll(...) catch {}; break :confirm_render 1;` (best-effort stderr + labeled-block break). The new guard mirrors this exactly."
  gotcha: "Use `break :confirm_render 1`, NOT `return 1`. The sibling render.zig:788 uses `return 1` because render.run is a function; region's confirm is a labeled EXPRESSION block whose value is the exit code."

# MUST READ — the sibling correct pattern (mirror it)
- file: src/render.zig
  section: "selectionBodyEmpty :609-620 (pub via S1); the --selection caller :788-791"
  why: "The exact idiom to mirror: `if (selectionBodyEmpty(html)) { stderr.writeAll(\"tmux-2html render: selection is empty\\n\") catch {}; return 1; }`. Region swaps `return` -> `break :confirm_render` and `render:` -> `region:` prefix."
  pattern: "selectionBodyEmpty finds the first <pre>, its closing </pre>, scans the body for non-whitespace; true=empty/all-ws, false=content OR malformed (safe non-empty fallback)."

# PRD normative source
- file: PRD.md
  section: "§13 (Empty/zero-cell selection on confirm: warn, no file written, exit 1) + §7.5 (confirm/cancel contract)"
  why: "Normative requirement this implements."
```

### Current Codebase tree (relevant slice)

```bash
tmux-2html/
├── src/
│   ├── region.zig        # <— THE FILE TO EDIT (confirm arm :438-509)
│   ├── render.zig        # selectionBodyEmpty pub (S1) — DO NOT EDIT in S2
│   └── ...
├── build.zig             # `zig build test` roots at src/main.zig (picks up region/render tests)
└── PRD.md
```

### Desired Codebase tree with files to be added/changed

```bash
tmux-2html/
└── src/
    └── region.zig        # MODIFIED IN PLACE — +tier-2 guard block after :475; comment rewrite :441-444.
                          #   NO new files. NO other files touched.
```

### Known Gotchas of our codebase & Library Quirks

```zig
// GOTCHA 1 — use `break :confirm_render 1`, NOT `return 1`. region's `.confirm` arm is a
//   labeled EXPRESSION block (`confirm_render: { ... break :confirm_render N; }`); the break
//   value becomes the switch-arm result = the exit code. The sibling render.zig:788 uses
//   `return 1` because render.run is a plain function — do NOT copy that verbatim. The
//   existing tier-1 guard at region.zig:447 already uses the correct `break :confirm_render 1`.

// GOTCHA 2 — defers ALWAYS run on break (no leak). `defer allocator.free(html)` at :475 runs
//   when the block exits via `break :confirm_render 1`, so html is freed. The break skips
//   resolveOutputPath (:479), writeHtmlAtomic (:487), writeLastOutput (:498), spawnXdgOpen
//   — so NO file, NO sidecar, NO browser open. This is what resolves Issue 3 too.

// GOTCHA 3 — selectionBodyEmpty works on region's FULL-document `html`. renderSelectionHtml
//   (region.zig:535) returns the complete <!DOCTYPE…</html> doc (fragment wrapped via
//   render.writeDocumentBytes, then allocator.dupe'd). The §8.1 envelope has exactly ONE <pre>,
//   so the helper's first-`<pre` scan lands on the content body. Malformed HTML ⇒ return false
//   (non-empty fallback) ⇒ the guard can NEVER false-positive into suppressing a real render.

// GOTCHA 4 — tests MUST run in ReleaseFast. `zig build test` (Debug) fails with the known
//   Zig 0.15.2 linker bug (R_X86_64_PC64 from ghostty-vt's C++ SIMD libs), NOT a code error.
//   Always: `zig build test --release=fast`. (PRD §15; consistent with S1/S3.)

// GOTCHA 5 — `html` is []u8 (owned full-doc copy); selectionBodyEmpty takes []const u8.
//   []u8 coerces to []const u8 — no conversion needed.

// GOTCHA 6 — S2 adds NO new test. The helper's logic is unit-tested in render.zig (the
//   selectionBodyEmpty test). The END-TO-END proof of the new empty path (pty-driven blank-cell
//   confirm ⇒ exit 1 + no file + no sidecar) is S3's integration test. S2's gate is
//   compile + existing suite green + the additive-control-flow reasoning (non-empty ⇒
//   selectionBodyEmpty ⇒ false ⇒ guard skipped ⇒ unchanged).
```

## Implementation Blueprint

### Data models and structure

Not applicable — pure control-flow insert reusing an existing helper; no types change.

### The exact deliverable — verbatim before/after (both edits)

**EDIT A — insert the tier-2 guard** (after `defer allocator.free(html);` at
region.zig:475, before the output-path comment at 477).

OLD (current text, region.zig:475 → 479):
```zig
            defer allocator.free(html);

            // Output path: explicit --output wins; else <session>-<unixtime>-<pid>.html in the
            // configured output dir (mirrors pane's panePrepare via the SHIPPED capture.* helpers).
            const path = resolveOutputPath(allocator, opts, target, runner) catch {
```

NEW (insert the guard block between the defer and the output-path comment):
```zig
            defer allocator.free(html);

            // PRD §13 / Issue 1 — TIER 2 guard. An ACTIVE selection over blank cells (a blank
            // prompt line, trailing blank row, or empty rectangle) renders a zero-non-blank-cell
            // body even though tier 1 (sel.active()) passed. selectionBodyEmpty scans the <pre>
            // body of the full §8.1 document (the envelope has exactly one <pre>); warn + exit 1
            // BEFORE resolveOutputPath/writeHtmlAtomic/writeLastOutput so neither the HTML file
            // nor the .last-output sidecar is produced. Mirrors render.zig:788 (render --selection).
            if (render.selectionBodyEmpty(html)) {
                stderr.writeAll("tmux-2html region: selection is empty\n") catch {};
                break :confirm_render 1;
            }

            // Output path: explicit --output wins; else <session>-<unixtime>-<pid>.html in the
            // configured output dir (mirrors pane's panePrepare via the SHIPPED capture.* helpers).
            const path = resolveOutputPath(allocator, opts, target, runner) catch {
```

**EDIT B — rewrite the tier-1 comment** (region.zig:441–444) to correct the PRD §13
misreading and document the two-tier guard.

OLD (current text, region.zig:441–444):
```zig
            // PRD 7.5: empty selection => warn, no file, exit 1. "Empty" == no selection begun
            // (sel inactive). The TUI lets Enter/y through regardless (the handler returns
            // .confirm unconditionally); THIS arm is where the empty guard lives. (`stderr` is
            // body()'s already-declared stderr writer.)
```

NEW:
```zig
            // PRD §13 / §7.5: empty selection on confirm => warn, no file, exit 1. This is the
            // FIRST of TWO guards (TWO-TIER): tier 1 (here) = no selection begun at all
            // (sel inactive) — the user hit Enter without pressing v. TIER 2 (after the render,
            // below) catches an ACTIVE selection whose rendered body is blank cells. The TUI
            // handler returns .confirm unconditionally, so both guards live in THIS arm.
            // (`stderr` is body()'s already-declared stderr writer.)
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: INSERT the tier-2 guard block (src/region.zig)
  - ANCHOR: immediately AFTER `defer allocator.free(html);` (region.zig:475), BEFORE the
            `// Output path:` comment (region.zig:477).
  - CONTENT: the verbatim 8-line comment + `if (render.selectionBodyEmpty(html)) { ... break :confirm_render 1; }` block above (EDIT A "NEW").
  - EXACT: `render.selectionBodyEmpty(html)` (render alias @ region.zig:41; helper pub via S1).
  - EXACT: message `tmux-2html region: selection is empty\n` (region prefix; newline-terminated).
  - EXACT: `break :confirm_render 1` (labeled-block break, NOT return — Gotcha 1).
  - DO NOT add this guard inside renderSelectionHtml or anywhere else — only the confirm arm.
  - DEPENDENCIES: S1 (selectionBodyEmpty must be pub). Assume S1 done (contract).

Task 2: REWRITE the tier-1 comment (src/region.zig:441-444)
  - CONTENT: the verbatim replacement above (EDIT B "NEW") — documents the two-tier guard
            and corrects the PRD §13 misreading ("empty" = renders zero non-blank cells,
            not merely inactive selection).
  - KEEP: the useful notes (handler returns .confirm unconditionally; stderr is body()'s writer).

Task 3: VALIDATE  (see Validation Loop)
  - RUN: zig build test --release=fast   → expect exit 0 (no regression)
  - RUN: zig build --release=fast        → expect clean build
  - (OPTIONAL) manual repro from the bug report to prove the new empty path (else defer to S3's pty test)
```

### Implementation Patterns & Key Details

```zig
// PATTERN: the region confirm error-path idiom (every existing branch uses this).
//   The new guard mirrors it exactly — only the condition + message differ:
            if (render.selectionBodyEmpty(html)) {
                stderr.writeAll("tmux-2html region: selection is empty\n") catch {};
                break :confirm_render 1;
            }

// PATTERN (sibling, for reference — do NOT copy the `return`): render.zig:788
//   if (selectionBodyEmpty(html)) {
//       stderr.writeAll("tmux-2html render: selection is empty\n") catch {};
//       return 1;                       // render.run is a function -> return; region -> break
//   }

// CRITICAL: insert AFTER `defer allocator.free(html);` so the owned html is freed on the
// break path (defers run on break). Inserting BEFORE the defer would leak html on the empty path.

// CRITICAL: the break must precede resolveOutputPath/writeHtmlAtomic/writeLastOutput so NO
// file and NO sidecar are written. That placement is what also fixes Issue 3 (sidecar residue).
```

### Integration Points

```yaml
THIS TASK (region.zig only):
  - confirm arm gains tier-2 empty guard after the html defer; comment rewritten.
  - region.zig imports `render` (already present, :41) and uses `render.selectionBodyEmpty` (pub via S1).

DEPENDENCY (assume complete):
  - S1: selectionBodyEmpty is `pub fn` at render.zig:609. S2 consumes it; does NOT edit render.zig.

DOWNSTREAM (NOT this task):
  - S3: python3 pty integration test — blank-cell confirm => exit 1 + no output file + no .last-output sidecar.
  - Issue 3 (sidecar residue): resolved implicitly by S2 (break precedes writeLastOutput). No separate work.

CONFIG / DATABASE / ROUTES:
  - none.
```

## Validation Loop

> PRIMARY gate: `zig build test --release=fast` (Gotcha 4). Plain `zig build test`
> (Debug) fails on the `R_X86_64_PC64` linker bug from ghostty-vt's C++ libs.

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# The build is the compile check. Confirm region.zig still compiles with the new guard.
zig build --release=fast 2>&1 | tail -5
# Expected: clean build (installs tmux-2html). A compile error referencing the new lines means
# a typo (e.g. `return` instead of `break :confirm_render`, or a missing `render.` prefix) — fix it.

# Confirm the guard is present and uses the labeled-block break (not return):
grep -n 'selection is empty\|break :confirm_render 1' src/region.zig   # expect BOTH the message + the break
```

### Level 2: Unit Tests (Component Validation — PRIMARY gate)

```bash
zig build test --release=fast
# Expected: exit 0. The change is ADDITIVE control-flow: non-empty confirms have content =>
# selectionBodyEmpty => false => the guard does not fire => the existing path is byte-identical.
# The selectionBodyEmpty helper's own unit test (render.zig) still passes (S1 made it pub; logic unchanged).
#
# NOTE: `zig build test` WITHOUT --release=fast fails with the unrelated Debug linker bug (Gotcha 4).
# The END-TO-END proof of the NEW empty path is S3's pty test; S2's gate is compile + no regression.
```

### Level 3: Integration Testing (System Validation)

```bash
# Regression: a NON-empty region confirm must be unchanged (file + sidecar + exit 0).
# (Drive via the existing envelope_smoke harness if available, which confirms from non-blank rows.)
zig build --release=fast
tests/envelope_smoke.sh 2>&1 | tail -5    # if present; expect PASS (non-blank confirm path unaffected)

# New empty path — MANUAL repro (optional for S2; the deterministic pty version is S3).
# Build, then confirm a blank-cell selection in the TUI and observe:
#   - stderr: "tmux-2html region: selection is empty"
#   - exit code: 1
#   - NO output HTML file created
#   - NO $TMUX_2HTML_BIN/.last-output sidecar (Issue 3 also fixed)
# (Use an ISOLATED tmux socket per PRD §0/AGENTS.md: `tmux -L t2h-empty-$$ ...`; never kill-server.)
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Confirm the two edits are in place and well-formed:
grep -n 'TIER 2\|TWO-TIER\|selection is empty' src/region.zig   # expect the comment + the message
# Confirm region.zig is the ONLY changed source file:
git diff --name-only src/   # expect: src/region.zig only (render.zig belongs to S1, not S2)
```

## Final Validation Checklist

### Technical Validation

- [ ] `zig build --release=fast` builds clean (Level 1).
- [ ] `zig build test --release=fast` exits 0 (Level 2 — primary gate; no regression).

### Feature Validation

- [ ] Tier-2 guard inserted after `defer allocator.free(html);` (region.zig:475), before `resolveOutputPath`.
- [ ] Guard uses `break :confirm_render 1` (labeled-block break, NOT `return 1`).
- [ ] Message is `tmux-2html region: selection is empty\n` to `stderr` (region prefix, newline-terminated).
- [ ] Empty path writes NO file (writeHtmlAtomic skipped) and NO sidecar (writeLastOutput skipped).
- [ ] Comment at region.zig:441–444 documents the two-tier guard + corrects the PRD §13 misreading.
- [ ] Non-empty confirm path is unchanged (file + sidecar + exit 0).
- [ ] Only `src/region.zig` modified.

### Code Quality Validation

- [ ] Mirrors the sibling `render --selection` check (render.zig:788) — same helper, region prefix.
- [ ] Reuses `render.selectionBodyEmpty` (pub via S1) — no duplicated logic.
- [ ] Follows the existing region error-path idiom (`stderr.writeAll(...) catch {}; break :confirm_render N;`).
- [ ] No new imports needed (`render` alias + `stderr` writer already in scope).

### Documentation & Deployment

- [ ] Inline comment corrected (Mode A — the PRD §13 misreading fixed; two-tier guard documented).
- [ ] No external doc files change for this subtask.

---

## Anti-Patterns to Avoid

- ❌ Don't use `return 1` — region's confirm is a labeled block; use `break :confirm_render 1`.
  (`return 1` is the sibling render.zig:788 form because render.run is a function.)
- ❌ Don't insert the guard BEFORE `defer allocator.free(html);` — that would leak the owned
  html on the empty path. The defer must precede the guard so it runs on break.
- ❌ Don't insert it after `resolveOutputPath`/`writeHtmlAtomic`/`writeLastOutput` — the
  break must fire BEFORE all three so no file and no sidecar are written (that placement is
  also what fixes Issue 3).
- ❌ Don't edit `render.zig` — `selectionBodyEmpty`'s `pub` visibility is S1's job (assume done).
  S2 only consumes `render.selectionBodyEmpty`.
- ❌ Don't duplicate the emptiness logic or add a "thin wrapper" — call the existing helper.
- ❌ Don't omit the `\n` in the message — every region stderr line is newline-terminated; the
  sibling render message has one too.
- ❌ Don't run plain `zig build test` — Debug hits the `R_X86_64_PC64` linker bug. Use
  `zig build test --release=fast`.
- ❌ Don't add the pty integration test here — that's S3. S2 is the guard + comment only.
- ❌ Don't use a global tmux kill in any manual repro — use an isolated `-L <name>` socket and
  teardown by named session only (PRD §0 / AGENTS.md §1).

---

**Confidence Score: 10/10** for one-pass implementation success.

The change is a surgical, 5-line control-flow insert + a comment rewrite in a single
file, reusing a helper that is already `pub` (S1) and already unit-tested. Every line
anchor (tier-1 guard :445; html defer :475; resolveOutputPath :479; writeHtmlAtomic :487;
writeLastOutput :498) is verified against HEAD, and both edits are given verbatim
(before/after). The two failure modes an implementer could hit — using `return` instead
of `break :confirm_render`, and inserting before the `defer` (leak) — are called out as
gotchas. The defer/break semantics guarantee no leak and no file/sidecar on the empty
path, and `selectionBodyEmpty`'s single-`<pre>`/malformed⇒false logic guarantees it
cannot false-positive on a real render. The additive nature (non-empty ⇒ false ⇒ guard
skipped) means the existing test suite cannot regress. The end-to-end pty proof is S3.