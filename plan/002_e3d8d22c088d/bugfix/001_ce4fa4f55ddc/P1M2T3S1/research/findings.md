# P1.M2.T3.S1 — Research Findings (changeset-level documentation backstop)

> This is the **§5 Mode B** changeset-level documentation task. Mode A (per-subtask
> doc updates that "ride with the work") was done by each implementing subtask; this
> task owns **cross-cutting / overview docs** and is the **backstop** for any missed
> Mode A update. It depends on ALL four implementing subtasks being complete.

## 0. Task identity & contract (from tasks.json)

- **Path**: P1.M2.T3.S1 — "Sync changeset-level documentation". Parent P1.M2.T3
  description: "Final documentation sweep to ensure README.md and docs/CONFIGURATION.md
  reflect all security and behavior improvements from this changeset. Per §5 Mode B,
  this is the catch-all for cross-cutting docs that only make sense once the whole
  changeset is in place."
- **Inputs**: completed changes from P1.M1.T1.S1 (Issue 1), P1.M1.T2.S1 (Issue 2),
  P1.M2.T1.S1 (Issue 3), P1.M2.T2.S1 (Issue 4); existing README.md; existing
  docs/CONFIGURATION.md; PRD Testing Summary (h2.4) — the two vectors standard
  validation was blind to.
- **Outputs (verbatim from contract)**: "Updated README.md and docs/CONFIGURATION.md
  reflecting the complete changeset. No stale claims about behavior that has changed."
- **Hard constraints**: (c) Do NOT create new doc files — prefer updating existing.
  (d) Run `scripts/check-safety.sh` and `scripts/preflight.sh` as a final safety check.
- **This IS the documentation task** — no further doc updates needed downstream.

## 1. The four implementing subtasks — what each changed + its Mode A doc

| Subtask | Issue | Code change | Mode A doc obligation | Mode A status (verified) |
|---|---|---|---|---|
| P1.M1.T1.S1 | 1 — apostrophe in `@tmux-2html-title` breaks bindings | `tmux-2html.tmux`: `shell_escape()` + `title_arg`/`lang_arg` use it; `tests/plugin_options.sh` + apostrophe cases | CONFIGURATION.md: note threaded title/lang values are shell-escaped | ✅ **LANDED** — CONFIGURATION.md lines 87-88 ("Values containing special characters (including apostrophes) are POSIX shell-escaped … `Bob's pane` is safe.") |
| P1.M1.T2.S1 | 2 — `--font` HTML-attribute injection / stored-XSS | `src/ghostty_format.zig:841`: raw `{s}` → per-byte HTML-escape loop; `src/render.zig` + XSS test | CONFIGURATION.md: note font value is HTML-escaped in the `style` attribute | ✅ **LANDED** — CONFIGURATION.md line 45 ("The value is HTML-escaped when emitted into the `style` attribute, so a font name containing `"` … cannot inject attributes or scripts.") |
| P1.M2.T1.S1 | 3 — `render --output` doesn't create parent dirs | `src/render.zig`: `makePath` in `renderToFileAtomic` (547) + `writeDocFileAtomic` (603); + nested-dir test | **NONE** — PRD/PRP explicitly: "No flag/API/help-text change; no doc edit" (`render --help` doesn't mention parent dirs; no stale claim exists) | ✅ N/A (no doc owed). No README/CONFIGURATION text claims --output fails on missing dirs. |
| P1.M2.T2.S1 | 4 — `--lang ""` yields `en` not locale-derived | `src/render.zig`: `resolveLang`/`langFromEnv` delegate to pure `resolveLangImpl` with empty-guard; + tests | CONFIGURATION.md: clarify explicit `--lang ""` == unset → locale-derived | ⚠️ **IN PROGRESS** (parallel). Its planned Edit 3 adds one sentence to the "How options are read" paragraph. **NOT yet present** at current git HEAD. **This task is the backstop** — verify & fill if missing. |

## 2. Current Mode A doc state — verified via git + grep (HEAD = c930c1a)

```
docs/CONFIGURATION.md   M  (Mode A for Issues 1 & 2 already committed)
src/render.zig          M  (Issue 3 makePath committed in c930c1a; Issue 4 in progress)
```

- CONFIGURATION.md line 45 (font row) — Issue 2 escaping note: PRESENT.
- CONFIGURATION.md lines 87-88 (title/lang threading) — Issue 1 shell-escaping note: PRESENT.
- CONFIGURATION.md line 49 (lang options-table row) — says "Empty ⇒ locale-derived, fallback `en`."
  This describes the OPTION, not the CLI `--lang ""` flag. Accurate; no change needed.
- CONFIGURATION.md "How options are read" paragraph (lines ~84-88) — Issue 4 `--lang ""`
  clarification: **ABSENT** at HEAD (P1.M2.T2.S1 has not committed it yet). → BACKSTOP TARGET.

## 3. README.md audit (the cross-cutting owner of this task)

README sections (verified): Capture modes, Requirements, Installation, Key bindings,
region overlay, Command line, Configuration, Known limitations, License and credits.
**There is NO dedicated security/trust section.**

The single escaping/trust claim in README is the intro (lines 11-15):

> Every capture is a complete, valid HTML5 document — a single
> `<!DOCTYPE html>`…`</html>` with a `<head>` (charset, viewport, and an
> **HTML-escaped `<title>`**) and a `<body>` whose page background matches the
> terminal's, so it opens cleanly in any browser with no wrapping page.

**Gap vs §8.1 trust guarantee (PRD):** §8.1 normatively requires "All text inserted
into the envelope (`<title>`, etc.) is HTML-escaped" and that the document is one
you can "open, share, and trust in any browser." After Issue 2, the `font-family`
style value is ALSO escaped — but the README intro only mentions `<title>`. The
trust guarantee is now **broader than the README states**.

Per contract LOGIC (a): "ensure it reflects that --font is now HTML-escaped" →
expand the intro escaping claim to cover `--font` / `@tmux-2html-font` too.

**"Known issues now fixed" check (contract LOGIC a, last clause):** README "Known
limitations" lists only (1) alternate-screen apps and (2) the history-limit cap.
NEITHER is one of the four fixed issues. → **Nothing to remove.** No stale claim.

**Command-line section** shows `tmux-2html render --title "build log" --lang en-US`.
No stale claim. After Issue 4, omitting/empty `--lang` derives from the locale — a
one-line accurate enhancement, but the Configuration options-table row already
documents it. OPTIONAL, low priority.

## 4. What this task must DO (concrete edits)

1. **README.md** — update the intro escaping/trust claim so it reflects the §8.1
   guarantee accurately for the post-changeset state: `<title>` AND `font-family`
   are escaped (Issue 2). Keep it to one added clause/sentence; do NOT invent a new
   top-level section (contract: prefer updating existing prose).
2. **docs/CONFIGURATION.md** — BACKSTOP only:
   - Issues 1 & 2 Mode A: already present → **confirm, do not duplicate**.
   - Issue 4 Mode A: re-read the "How options are read" paragraph; if the `--lang ""`
     clarification is absent (P1.M2.T2.S1 did not land it), ADD the one sentence from
     P1M2T2S1's PRP Edit 3. If present, SKIP (avoid double-add / merge collision).
   - Issue 3: no doc owed → no edit.
3. **Validate**: `sh scripts/check-safety.sh` (must stay `0 FAIL`, 16 WARN baseline;
   none of which are in README/CONFIGURATION) + `sh scripts/preflight.sh` (clean).

## 5. check-safety.sh baseline (captured at HEAD c930c1a)

```
== result: 0 FAIL(s), 16 WARN(s) ==    EXIT=0
```
All 16 WARNs are `PATH-prepend shim recipe` hits inside `plan/**/PRP.md` DOCS —
**ZERO** in README.md or docs/CONFIGURATION.md. My edits are markdown prose; the
guard's `should_skip()` skips backticked spans / markdown list/quote/table leaders,
so adding escaped-attribute examples like `&quot;` / `--font 'a"…'` will NOT trip
R3/R4. The implementer must simply confirm the WARN count stays at 16 (no new hits
in the edited files) and FAIL stays 0.

## 6. Why no Zig build / unit test gate

This is a documentation-only task: **no `.zig`, `.sh`, `.tmux`, or test files are
touched.** The four code fixes each shipped their own proven test + `zig build test`
gate (see their PRPs). This task's validation is: (1) the two safety scripts stay
green, (2) a manual read-through confirms no stale/inaccurate claims, (3) internal
markdown links still resolve (README → docs/CONFIGURATION.md, LICENSE). An OPTIONAL
binary smoke (`render --font 'a"…'` → escaped) confirms the documented claim holds,
but it re-tests P1.M1.T2.S1's work, not this task's docs.

## 7. Parallel-execution / merge notes

- P1.M2.T2.S1 edits the SAME "How options are read" paragraph this backstop may
  touch for Issue 4. **This task runs AFTER P1.M2.T2.S1** (T3 depends on T2). Re-read
  the paragraph at execution time and add the sentence ONLY if absent → no collision.
- Issues 1 & 2 Mode A are already committed (6626071, 916035f) — do not re-edit those
  lines; if rewording for global consistency, preserve the factual claims.
- Do NOT create SECURITY.md / CHANGES.md / etc. (contract §c). Update existing files.