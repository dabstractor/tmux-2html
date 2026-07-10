# System Context — Plan 002 (PRD §8.1 delta)

## What this plan is

`plan/002_e3d8d22c088d` is a **delta** on top of `plan/001_0c8587f91cb2` (which
decomposed PRD v1 and was fully implemented — see the git history). The PRD was
revised to v2 with **one substantive change: §8.1 "HTML document envelope"**
("no cutting corners on the HTML doc"). The PRD diff (001→002 snapshot) is:

1. **§1.1 Goals** — new bullet: every output is a *complete, valid HTML5 document*
   (`<!DOCTYPE html>` → `</html>`), never a bare fragment.
2. **§5.1** — title changed `stdin → HTML` → `stdin → complete HTML5 document`.
3. **§8 pipeline step 5** — emit a *complete HTML5 document* wrapping the `<pre>`.
4. **§8.1 (NEW, normative)** — the document envelope spec: required skeleton in
   exact order, normative requirements (DOCTYPE, `<html lang>`, charset-first,
   viewport, HTML-escaped title, page bg = terminal bg, body margin 0, no fragment).
5. **§15** — golden tests assert the *full document* byte-for-byte; committed
   `testdata/*.html` (term2html fragments) MUST be re-blessed as complete docs.

## Current codebase state (verified hands-on, 2026-07-10)

- Zig 0.15.2, tmux 3.6b present. `zig build --release=fast` ✅. `zig build test --release=fast` ✅.
- **§8.1 core envelope is ALREADY IMPLEMENTED** in commit `07ab167` ("Make every
  HTML output a complete document"). Specifically:
  - `src/render.zig` has `DocumentOpts`, `writeDocument`, `writeDocumentBytes`,
    `renderDocument`, `writeEscaped`, `renderToFileAtomic`, `writeDocFileAtomic`.
  - **Every** HTML output path routes through the envelope (verified by scout +
    runtime smoke): `render` stdout / `--output` / `--open` / `--selection`;
    `pane` `--visible`/`--full` (writes a complete-doc file); `region` confirm
    (uses `render.writeDocumentBytes`). **No production path emits a bare `<pre>**
    fragment.** (`renderGrid` is the fragment primitive and is always wrapped.)
  - All `testdata/*.html` were **re-blessed** as complete documents
    (`<!DOCTYPE html>` first, page-bg style, `</html>` last).
  - `src/golden_test.zig` calls `renderDocument` (full doc) and asserts
    byte-equal to the re-blessed goldens for both whole-grid and `--selection`
    (linewise + block) fixtures.
  - Title default forms are correct: `render` → `tmux-2html`;
    `pane`/`region` → `tmux-2html — <session>/<pane> <unixtime>`
    (`paneTitle`/`regionTitle`). Page bg = resolved terminal bg; body margin 0;
    `<meta charset="utf-8">` is first in `<head>`; viewport present; title
    HTML-escaped.

## The remaining gap (what Plan 002 must deliver)

§8.1's **normative configurability** requirements are NOT yet implemented:

| # | Requirement (PRD §8.1) | Status | Wiring point |
|---|---|---|---|
| G1 | title configurable via **`--title`** (CLI) | MISSING | `src/cli.zig` (RenderOpts/PaneOpts/RegionOpts + parseRender/parsePane/parseRegion); `render.run` / `pane` (`main.zig`) / `region` (`region.zig`) build `DocumentOpts` |
| G2 | title configurable via **`@tmux-2html-title`** (tmux option) | MISSING | `tmux-2html.tmux` (read_opt) + the prefix-table bindings (O / visible / C-o region) |
| G3 | lang default `en`, configurable via **`@tmux-2html-lang` / locale** | PARTIAL — `DocumentOpts.lang` defaults `"en"` but is never overridden by callers; no option, no locale derivation | `src/cli.zig` (`--lang` flag, needed to thread the option in) + `src/render.zig` (locale→lang resolution) + `tmux-2html.tmux` (`@tmux-2html-lang`) |
| G4 | Documentation reflects §8.1 | MISSING | `README.md`, `docs/CONFIGURATION.md` |

So **Plan 002 = finish the §8.1 configurability (G1–G3) + validate + sync docs (G4)**.
The core envelope (the bulk of §8.1) is already done and tested — do NOT re-plan it.

## CRITICAL SAFETY (PRD §0) — must hold for all validation work

The user's live tmux session is **untouchable**. Any integration test MUST spin up
its OWN isolated, uniquely-named server and tear down ONLY that:
`tmux -L "tmux-2html-test-$$" new-session -d -s test` … `tmux -L "..." kill-session -t test`.
NEVER `tmux kill-server` / `killall tmux` / `pkill tmux` / connect to the user's
socket for anything but read-only `capture-pane`. (The hands-on smoke in this
research used `tmux -L "tmux-2html-verify-$$"` and tore down only that socket.)

## Architectural invariants to preserve (do not regress)

- **Goldens stay byte-identical.** `golden_test.zig` calls `renderDocument`
  DIRECTLY with `DocumentOpts{ .title = "tmux-2html", .lang = "en"(default), … }`.
  The new CLI `--title`/`--lang` flags live in `render.run` / `pane` / `region`,
  which the golden harness does NOT exercise. ⇒ adding the flags cannot change
  golden bytes. Do NOT alter `DocumentOpts.lang`'s `"en"` default.
- **`renderGrid` stays the fragment primitive;** every sink wraps it via the
  envelope helpers. Do not introduce a new bare-fragment sink.
- **Default behavior unchanged when no option/flag/locale is given**: render
  stdout title `tmux-2html`, lang `en`; pane/region keep the contextual title.
- Build is `.link_libc=false`; locale env is read via `std.posix.getenv`
  (already used in `render.zig` for `TMPDIR`). Lang derivation must be PURE
  (no /dev/tty, no allocation needed for the common case) and unit-testable.
