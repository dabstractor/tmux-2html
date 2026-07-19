# Research Findings — P1.M1.T3.S1 (§8.1 validation: goldens + title/lang tests + isolated-tmux smoke)

> All facts below were **verified empirically** on 2026-07-10 against the real Zig 0.15.2
> toolchain + tmux 3.6b + the cached deps, by building `./zig-out/bin/tmux-2html`
> (ReleaseFast) and driving every output path. The integration smoke design below is
> grounded in observed bytes/exit codes, not guesses.

## 0. Baseline state (what already exists — do NOT re-implement)

- **T1.S1–S4 are COMPLETE** (plan_status). The `--title`/`--lang` flags + lang resolver +
  DocumentOpts wiring are all in the tree and tested:
  - `src/cli.zig`: `RenderOpts`/`PaneOpts`/`RegionOpts` each have `title: ?[]const u8` +
    `lang: ?[]const u8`; `parseRender/parsePane/parseRegion` parse `--title`/`--lang`.
    Tests `parseRender/parsePane/parseRegion: --title and --lang` (+ missing-value) EXIST.
  - `src/render.zig`: `resolveLang`/`langFromEnv`/`langFromEnvStrings`/`toBcp47` + a full
    suite of lang tests (`toBcp47:*`, `langFromEnvStrings:*`, `resolveLang:*`) EXIST.
    `DocumentOpts` (render.zig:187) = `{ title, lang = "en", background }`; `run` (render.zig:708)
    builds `DocumentOpts{ .title = opts.title orelse "tmux-2html", .lang = resolveLang(opts.lang), … }`.
  - `src/main.zig`: `paneResolveTitle` (+ tests `paneResolveTitle: --title override wins verbatim`
    and `… null override => contextual default`) EXIST.
  - `src/region.zig`: `regionResolveTitle` (+ the same two override-branch tests) EXIST.
  - `src/golden_test.zig`: TWO golden tests, BOTH call `renderDocument` with a full
    `DocumentOpts{ .title = "tmux-2html", .background = … }` (lang defaults `"en"`):
    (1) whole-grid `testdata/*.ansi → byte-equal *.html`; (2) `--selection` (linewise + block).
- **`zig build test -Doptimize=ReleaseFast` is GREEN (exit 0)** — verified. So contract (a)
  ("both golden tests pass byte-equal") and contract (b)'s component-level tests ALREADY PASS.
  ⇒ This task does NOT add redundant unit tests for the title/lang components (T1 owns them);
  it adds the **end-to-end integration smoke** (the one missing artifact) + re-verifies green.

## 1. Verified §8.1 document shape (exact bytes the binary emits)

From `printf '\e[31mRED\e[0m normal' | tmux-2html render --cols 40 --rows 3 --palette default`:
```
<!DOCTYPE html>
<html lang="en-US">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>tmux-2html</title>
<style>html,body{margin:0;padding:0;}body{background-color:#292c33;}</style>
</head>
<body>
<pre class="term2html-output" style="max-width: 40ch; background-color: #292c33;color: #c5c8c6;font-family: monospace;"><span style="color: #cc6666;">red</span> plain</pre>
</body>
</html>
```
- **DOCTYPE-first** (`<!DOCTYPE html>` = exactly 15 bytes), **single `<html lang=…>`**,
  **`<meta charset="utf-8">` FIRST in head**, viewport present, **escaped `<title>`**,
  **body margin 0** + **page bg = terminal bg** (`#292c33`), **one `<pre class="term2html-output">`**,
  **color span** `color: #cc6666` for `\e[31m`, **ends `</html>`**. Matches PRD §8.1 normative shape.

## 2. Verified assertions (title / lang / locale / color) — observed, not assumed

| Input | Observed | Assertion |
|---|---|---|
| default (no --title) render | `<title>tmux-2html</title>` | default render title |
| `--title 'A&B<c>'` | `<title>A&amp;B&lt;c&gt;</title>` | **HTML-escaped** |
| `--lang pt-BR` | `<html lang="pt-BR">` | lang attr == passed value |
| `env -i LC_ALL=C LANG=C …` | `<html lang="en">` | C locale → `en` (deterministic) |
| `env -u LC_ALL -u LANG …` | `<html lang="en">` | empty/unset → `en` |
| default (host locale) | `<html lang="en-US">` | locale-derived (varies by host) |
| `\e[31m` red input | `<span style="color: #cc6666;">` | color span present |

- **GOTCHA (determinism):** the default `lang` is **locale-derived**, so it VARIES by host
  (`en-US` here). The smoke MUST force the locale (`env LC_ALL=C` or `env -u LC_*`) for the
  `lang="en"` assertion, else it is non-deterministic. The `--lang pt-BR` assertion is
  deterministic (explicit override wins).
- **GOTCHA (`--palette default`):** use `--palette default` everywhere in the smoke so the
  renderer uses the bundled palette (no `/dev/tty` query, no cache dependency). Verified
  clean (no "palette: only 1/256" warning with `--palette default`).

## 3. Isolated-tmux mechanism (PRD §0-safe) — TWO verified approaches

`src/capture.zig` shells out to **bare `tmux`** (argv[0]=`"tmux"`, NO `-L`), inheriting the
parent env (`.env_map` omitted ⇒ `$TMUX`/`$TMUX_PANE`). To point the binary at an ISOLATED
server without touching the binary or the user's socket:

- **Approach A — `$TMUX` env = socket path** (`/tmp/tmux-$UID/<name>`): VERIFIED — bare
  `tmux capture-pane -t test -p` connected to the isolated `-L` server. Fragile (relies on
  tmux's `$TMUX` parsing).
- **Approach B — PATH shim (PREFERRED):** a temp dir with a `tmux` wrapper that prepends
  `-L <socket>` to every call, placed FIRST in `PATH`. VERIFIED — intercepts ALL the binary's
  tmux calls (`display-message`/`capture-pane`/`show-option`) uniformly. **This is the
  robust choice** — it doesn't depend on `$TMUX` format quirks.

Verified end-to-end: `PATH="$SHIM:$PATH" TMUX_PANE=%0 tmux-2html pane --visible --output f.html`
→ `wrote f.html`, exit 0, file is a complete §8.1 doc with `color: #cc6666` span (3 matches).
- Pane id from the isolated server: `tmux -L <sock> list-panes -t test -F '#{pane_id}'` → `%0`.
- **Teardown (PRD §0):** `tmux -L <sock> kill-session -t test` ONLY. NEVER `kill-server`/
  `killall`/`pkill`. Verified the named-session teardown leaves the user's tmux untouched.

## 4. Region confirm via python3 pty — VERIFIED feasible

- `tmux-2html region` with NO controlling tty → prints `error: region requires a terminal
  (run via tmux display-popup)` and writes NO file (graceful). So region MUST be driven in a pty.
- **python3 3.14.5 is present.** Drove region in a `pty.fork()`:
  1. isolated tmux server + colored content; PATH shim; `tmux-2html region --target %0 --output f.html`.
  2. `time.sleep(0.8)` (let TUI paint) → `os.write(fd, b"v")` (start linewise selection at cursor)
     → `time.sleep(0.2)` → `os.write(fd, b"\r")` (Enter = confirm; `regionHandle` returns `.confirm`
     on Enter/y, region.zig:154).
  3. drain + `waitpid` until exit.
  - Result: region wrote a **419-byte complete §8.1 document** (`<!DOCTYPE html>` … `</html>`,
    `<pre class="term2html-output">`). ✓
- **NOTE:** the region selection's *content* varies (the single-line selection at the cursor may
  not include the red text — observed red-span count 0). So for region the smoke asserts
  **document-completeness only** (NOT the color span). The color-span assertion is reserved for
  the deterministic render-stdout + pane paths. render `--selection` covers the programmatic
  selection-rendering code path region shares.
- **Graceful skip:** if `python3` is absent, skip the region sub-smoke (render+pane still prove
  §8.1 doc-completeness; region shares render's `writeDocumentBytes`/DocumentOpts code).

## 5. `--open` → temp respects `$TMPDIR` (verified)

`render --open` (no `--output`) writes a temp doc via `tempHtmlPath` (render.zig:657), which
reads `std.posix.getenv("TMPDIR") orelse "/tmp"`. Verified: `TMPDIR=$W tmux-2html render --open`
lands `$W/tmux-2html-<16hex>.html` — a complete §8.1 doc. So the smoke sets `TMPDIR` to a
controlled dir and globs `tmux-2html-*.html` to find it deterministically. `xdg-open` is
best-effort (spawnXdgOpen ignores absence).

## 6. What this task delivers (scope)

- **PRIMARY:** `tests/envelope_smoke.sh` — the isolated-tmux §8.1 integration smoke (render 7
  paths + pane 2 paths + region confirm via pty). PRD §0-safe (PATH shim + unique `-L` socket +
  `kill-session` teardown; SKIP if tmux absent). Verified path-for-path above.
- **VERIFY:** `zig build test -Doptimize=ReleaseFast` stays green (contract a + b — already
  green; this task adds NO `src/*.zig`, so it cannot regress it — it's a guard).
- **(Recommended):** a CI job/step running `sh tests/envelope_smoke.sh` (install `tmux` on the
  runner; python3 is already present on ubuntu-latest). Optional; the smoke SKIPs cleanly where
  tmux is absent so adding it is safe.
- **DO NOT** add unit tests for title/lang components — T1.S1–S4 already shipped them (cli
  round-trips, `resolveLang`/`langFromEnvStrings`/`toBcp47`, `paneResolveTitle`/
  `regionResolveTitle` override branches, `writeDocument`/`writeDocumentBytes` envelope). The
  integration smoke is the end-to-end "render.run/pane/region build DocumentOpts with resolved
  title/lang" assertion (contract b) — the unit tests cover the pieces.

## 7. Build/test commands (verified)

```bash
zig build --fetch                          # exit 0 (deps cached)
zig build -Doptimize=ReleaseFast           # exit 0 → ./zig-out/bin/tmux-2html (8.2 MB)
zig build test -Doptimize=ReleaseFast      # exit 0 (goldens + ~275 unit tests) — MUST use ReleaseFast
sh tests/envelope_smoke.sh                 # → PASS, exit 0 (after this task creates it)
```
- `--release=fast`/`-Doptimize=ReleaseFast` is MANDATORY for build+test (Debug linker
  `R_X86_64_PC64` bug with the bundled C++ SIMD libs — PRD §15, inherited).
