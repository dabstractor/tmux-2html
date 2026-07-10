# §8.1 Gap Analysis & Wiring Map (Plan 002)

Source-of-truth: PRD §8.1 (normative). Verified against the live tree 2026-07-10.

## What is already done (DO NOT re-implement)

`src/render.zig`:
- `DocumentOpts` (render.zig:187): `{ title: []const u8, lang: []const u8 = "en",
  background: ?color.RGB = null }`. **The `lang` field already exists and defaults
  `"en"`** — callers just never set it.
- `writeDocument` (render.zig:217): the shared envelope (DOCTYPE → `<html lang>`
  → `<head>` [charset FIRST, viewport, escaped title, body-margin-reset +
  page-bg style] → `<body>` → fragment callback → close). HTML-escapes title via
  `writeEscaped`.
- `writeDocumentBytes` (render.zig:245): envelope around a pre-rendered fragment.
- `renderDocument` (render.zig:266): full-doc primitive (envelope + renderGrid).
- `renderToFileAtomic` / `writeDocFileAtomic`: atomic file writes, both emit docs.
- `run` (render.zig:615): all four arms (`--output`, `--open`, stdout,
  `--selection`) route through the envelope. `doc` built at render.zig:636 as
  `DocumentOpts{ .title = "tmux-2html", .background = colors.background }`.

`src/main.zig`: `pane` uses `renderToFileAtomic` (main.zig:465) with
`.{ .title = title, .background = colors.background }` (`title` = `paneTitle`,
main.zig:321). lang ⇒ default `"en"`.

`src/region.zig`: confirm uses `render.writeDocumentBytes` (region.zig:546) with
`.{ .title = title, .background = ctx.colors.background }` (`title` = `regionTitle`,
region.zig:589). lang ⇒ default `"en"`.

`src/golden_test.zig`: both tests call `renderDocument` with a full `DocumentOpts`.

## G1 — `--title` CLI flag (render / pane / region)

**Gap:** no `--title` exists. `RenderOpts`/`PaneOpts`/`RegionOpts` (cli.zig:59/70/81)
have no `title` field; `parseRender`/`parsePane`/`parseRegion` (cli.zig:153/184/216)
don't parse it. PRD §8.1: title "Configurable via `--title`".

**Wiring (add):**
- cli.zig: add `title: ?[]const u8 = null` to all three Opts structs; in each
  parser add `} else if (flag.isLong("title")) { opts.title = try requireValue(&parser); }`
  (mirrors the existing `--font` handling).
- render.zig `run` (render.zig:636): `const title = opts.title orelse "tmux-2html";`
  → `DocumentOpts{ .title = title, .lang = <see G3>, .background = ... }`.
- main.zig `pane` (main.zig:463): `const title = if (opts.title) |t|
  (try allocator.dupe(u8, t)) else (paneTitle(...) catch try allocator.dupe(u8,
  "tmux-2html"));` — explicit `--title` OVERRIDES the computed contextual title.
- region.zig (region.zig:459): same override pattern vs `regionTitle`.

**Default-unchanged invariant:** when `opts.title == null`, behavior is identical
to today. Goldens (which bypass `run`) are unaffected.

## G2 — `@tmux-2html-title` tmux option + bindings

**Gap:** `tmux-2html.tmux` reads 8 `@tmux-2html-*` options (§9.2 table); title is
not among them. PRD §8.1: title "Configurable via … `@tmux-2html-title`".

**Wiring (add):**
- tmux-2html.tmux: `title_opt=$(read_opt @tmux-2html-title "")` (read_opt at §60).
  Build an optional fragment expanded NOW (like `$TMUX_2HTML_BIN`):
  `title_arg=""; [ -n "$title_opt" ] && title_arg="--title '$title_opt'"`.
  Append `\$title_arg`... NO — `$title_arg` expands NOW into the literal run-shell
  command string, so interpolate it bare: `pane --full $title_arg --target '#{pane_id}'`.
  Single-quote the value to survive spaces. (The existing bindings expand
  `$TMUX_2HTML_BIN` now and leave `#{pane_id}` literal for run-shell — mirror that.)
- Apply to all three bindings: O (full), visible (if set), and C-o region popup.
- Record `title_opt`/`title_arg` in the `TMUX_2HTML_DEBUG` test seam (§4) so the
  plugin tests stay deterministic.

## G3 — `@tmux-2html-lang` / locale lang resolution

**Gap:** `DocumentOpts.lang` is never set by callers ⇒ always `"en"`. No
`@tmux-2html-lang` option, no locale derivation. PRD §8.1: lang "default `en`;
configurable via `@tmux-2html-lang` / locale".

**Resolution precedence (the contract — see lang_resolution.md):**
1. `@tmux-2html-lang` (threaded in via binary `--lang` flag) — if set & valid.
2. else locale-derived from env (`LC_ALL` → `LC_MESSAGES` → `LANG`), transformed
   to BCP 47 (`en_US.UTF-8` → `en-US`; `C`/`POSIX`/empty/unset → `en`).
3. else `"en"`.

**Wiring (add):**
- cli.zig: add `lang: ?[]const u8 = null` to the three Opts + parse `--lang`
  (mirrors `--title`). `--lang` is required to thread the tmux option through the
  binary (the binding passes `--lang "$lang_opt"`); it is also the explicit
  override surface.
- render.zig: add a PURE fn, e.g. `langFromEnv() []const u8`, implementing the
  locale algorithm (no /dev/tty, no alloc; uses `std.posix.getenv`). Add
  `resolveLang(explicit: ?[]const u8) []const u8` = `explicit orelse langFromEnv()`
  (defensive: if `explicit` is invalid/`C`/empty → `"en"`). Unit-test both.
- render.zig `run` (render.zig:636): `DocumentOpts{ .title = title,
  .lang = resolveLang(opts.lang), .background = ... }`.
- main.zig `pane` + region.zig: pass `.lang = resolveLang(opts.lang)` in their
  DocumentOpts.
- tmux-2html.tmux: `lang_opt=$(read_opt @tmux-2html-lang "")`; build
  `lang_arg="--lang '$lang_opt'"` only when non-empty; interpolate into bindings
  (same NOW-expansion pattern as title_arg). Record in the debug seam.

**Default-unchanged invariant:** in a no-locale / `C` / `POSIX` env (typical CI),
`resolveLang(null)` returns `"en"` ⇒ render stdout is byte-identical to today.
Goldens are unaffected (harness bypasses `run` and uses `DocumentOpts.lang`'s
`"en"` default directly).

## G4 — Documentation

- **Mode A (rides with the work):**
  - `--title`/`--lang` added to `--help` text (main.zig usage block) → with T1.S1.
  - `docs/CONFIGURATION.md` options table + an §8.1 "Output document" subsection
    (complete-doc structure, title/lang options) → with T2.S1.
- **Mode B (final changeset-level sweep):**
  - `README.md` — surface "standalone complete HTML5 document" output + the
    `--title`/`@tmux-2html-title` and lang config in features/usage → final task.

## Out of scope for this delta

- The core envelope, goldens, and all output-path routing (DONE).
- Re-implementing `DocumentOpts`/`writeDocument` (exists).
- `--title`/`--lang` on `sync-palette` (it emits no HTML).
- A fragment-only/embed mode (PRD §16, explicitly out of v1).
