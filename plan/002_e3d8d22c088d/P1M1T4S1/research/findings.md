# Research findings — P1.M1.T4.S1 (README §8.1 docs sync)

## 0. Task scope (from item + system_context)
- DOCS-ONLY: edit **`README.md`** only. Surface the §8.1 complete-HTML5-document output +
  the title (`--title` / `@tmux-2html-title`) and lang (`--lang` / `@tmux-2html-lang` / locale) knobs.
- `docs/CONFIGURATION.md` is OWNED by P1.M1.T2.S1 (Complete) — DO NOT duplicate its full options
  table; cross-link it instead.
- `src/*.zig`, goldens, build files: READ-ONLY.
- This is the **G4 "documentation reflects §8.1"** gap (system_context.md:52). CONFIGURATION.md half
  is done; **README is the remaining G4 artifact.**

## 1. Current README.md — exact state (grep-verified)
- Line 3 intro already says *"Capture a tmux pane to a standalone, color-faithful HTML document."*
  → consistent w/ §8.1 but does NOT describe the complete-document guarantee (DOCTYPE/charset/
  viewport/escaped title/page-bg), `--title`, `@tmux-2html-title`, `--lang`, or `@tmux-2html-lang`.
- **NO stale "fragment" language exists** in README today (grep for fragment/title/lang/doctype/
  viewport/charset/background matched ONLY line 3). So this task is primarily **ADDITIVE** — surface
  the new content; the "no stale fragment language" contract is satisfied by not introducing any.
- Structure: `# tmux-2html` → intro ¶ → `## Capture modes` → `## Requirements` → `## Installation` →
  `## Key bindings` → `## The region overlay` → `## Command line` (4-row subcommand table + examples
  + exit codes) → `## Configuration` (8-row `@tmux-2html-*` table + CONFIGURATION.md cross-link) →
  `## Known limitations` → `## License and credits`.
- README `## Configuration` table has **8 rows** (full/region/visible-key, output-dir, open, font,
  history-limit, binary-dir) — it is STALE: missing the `@tmux-2html-title` + `@tmux-2html-lang` rows
  added by T2.S1. (README has no option *count* text to update — only CONFIGURATION.md did.)

## 2. Implemented §8.1 behavior to document (ACCURATE to shipped binary)
Envelope (`render.zig` `DocumentOpts` / `writeDocument`, commit 07ab167; golden_test.zig pins it
byte-for-byte): every output path (`render` stdout/--output/--open→temp/--selection linewise+block;
`pane` --visible/--full; `region` confirm) emits
`<!DOCTYPE html>` → `<html lang="…">` → `<head>`(`<meta charset="utf-8">` FIRST, then
`<meta name="viewport" content="width=device-width, initial-scale=1">`, then `<title>`) →
`<body>` (page background = resolved terminal bg; body margin 0) → exactly one
`<pre class="term2html-output">` → `</body></html>`. The `<title>` is HTML-escaped (`& < > " '`).
Never a bare fragment.

**Title** (`render.zig:731-733`; `main.zig:316,336`; `region.zig:591,609`):
- `--title` CLI flag on render/pane/region; `@tmux-2html-title` option (empty default; threaded by
  T2.S1 into all 3 bindings as `--title`).
- Precedence: explicit `--title`/`@tmux-2html-title` wins verbatim; else contextual default; else
  literal `tmux-2html`.
- `render` default: literal `tmux-2html`.
- `pane`/`region` default: `tmux-2html — <session>/<pane> <unixtime>`, where `<unixtime>` =
  `std.time.timestamp()` = **Unix epoch SECONDS** (e.g. `1720000000`), same number used in the
  output filename. Session queried via tmux; falls back to `pane`.

**Lang** (`render.zig` `resolveLang`/`langFromEnv`/`toBcp47`):
- `--lang` CLI flag; `@tmux-2html-lang` option (empty default; threaded by T2.S1).
- Precedence: explicit `--lang`/`@tmux-2html-lang` → `LC_ALL` → `LC_MESSAGES` → `LANG` → `en`.
- Normalized to BCP-47 (`xx-XX`: lowercase language, uppercase region, `_`→`-`, `.codeset`/`@mod`
  stripped). C/POSIX/empty/invalid → `en`.

## 3. ⚠️ CRITICAL DISCREPANCY — iso8601 (docs) vs unixtime (code)
- The **item description** AND **docs/CONFIGURATION.md (line 48)** describe the contextual title as
  `tmux-2html — <session>/<pane> <iso8601>`.
- The **shipped binary** emits `<unixtime>` = Unix epoch seconds (`std.time.timestamp()`),
  e.g. `tmux-2html — mysession/%5 1720000000`. That is NOT ISO 8601 (`2025-07-10T…Z`).
- Contract pts 3 ("accurate to the implemented behavior") + 4 ("matches the shipped §8.1 behavior")
  OVERRIDE the item's example format string.
- **RESOLUTION for README (docs-only; cannot edit code or CONFIGURATION.md here):** describe the
  contextual title at an ACCURATE level — "includes the session, pane id, and a Unix timestamp" —
  WITHOUT claiming ISO 8601 (false) and WITHOUT contradicting CONFIGURATION.md's exact-format string.
  Defer the exact format string to CONFIGURATION.md via the existing cross-link. Surface the
  iso8601-vs-unixtime mismatch as a known pre-existing doc/impl issue (out of scope for this task).

## 4. Edit plan (README.md — concise, additive)
1. **Overview/intro** (expand line-3 ¶ or add a short note): state every capture is a COMPLETE valid
   HTML5 document (single `<!DOCTYPE html>`…`</html>`, charset-first `<head>` w/ viewport + escaped
   title, page background = terminal background). Keep "standalone" wording.
2. **`## Command line`** (examples): show `--title`/`--lang` on a `render` example (one line).
3. **`## Configuration`**: (a) add 2 table rows `@tmux-2html-title` / `@tmux-2html-lang` w/ their
   defaults; (b) a concise note tying the complete-doc guarantee + the two knobs + their contextual
   defaults to the existing CONFIGURATION.md cross-link. Do NOT invent unimplemented flags.

## 5. Validation
- README is prose/tables → no build/test gate. Validate by: `grep` for the surfaced knobs present,
  no `fragment` language introduced, cross-link intact; `zig build test -Doptimize=ReleaseFast`
  stays green (untouched; smoke guard). Optional markdown lint if available.
