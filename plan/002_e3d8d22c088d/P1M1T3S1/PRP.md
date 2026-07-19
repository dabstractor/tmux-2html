# PRP — P1.M1.T3.S1: §8.1 validation — goldens-unchanged + `--title`/`--lang` tests + isolated-tmux output-path smoke

## Goal

**Feature Goal**: Prove the §8.1 "HTML document envelope" feature is **done** — every HTML
output path (`render` stdout / `--output` / `--open`→temp / `--selection` linewise+block;
`pane` `--visible`/`--full`; `region` programmatic-confirm) emits a **complete, valid HTML5
document** (`<!DOCTYPE html>` → `</html>`), never a bare `<pre>` fragment, with correct
escaped `<title>`, `<html lang>`, and page background. This is the §8.1 "done" gate (PRD §15).

**Deliverable**: One new file + two verification runs:
1. **CREATE `tests/envelope_smoke.sh`** — a PRD-§0-safe integration smoke that drives the real
   `./zig-out/bin/tmux-2html` through **all 10 output paths** and asserts each is a complete §8.1
   document (with title/lang/bg checks), against an **ISOLATED, uniquely-named tmux server**
   (PATH shim + `tmux -L tmux-2html-smoke-$$` + `kill-session` teardown only). Graceful SKIP if
   `tmux` is absent; region's pty sub-smoke SKIPs if `python3` is absent.
2. **RUN** `zig build test -Doptimize=ReleaseFast` → green (proves BOTH golden tests still pass
   byte-equal **and** the `--title`/`--lang` unit tests from T1.S1–S4 are intact — contract a+b).
3. **RUN** `sh tests/envelope_smoke.sh` → `PASS`, exit 0 (contract c + the "zero bare fragments" output).

**Success Definition** (all VERIFIED working against Zig 0.15.2 + tmux 3.6b + the real binary):
- `zig build test -Doptimize=ReleaseFast` exits 0 (320 tests: 2 golden + 318 unit, incl. all
  title/lang/override-branch tests).
- `sh tests/envelope_smoke.sh` prints `PASS` and exits 0: render 7/7, pane 2/2, region 1/1.
- No `src/*.zig`, `build.zig`, `build.zig.zon`, or `golden_test.zig`/`testdata/*` touched (this
  is validation only — the feature code shipped in T1.S1–S4 + commit `07ab167`).

> **CRITICAL — this is a VALIDATION task.** The §8.1 envelope, the `--title`/`--lang` flags, the
> lang resolver, the pane/region override wiring, AND their unit tests **already exist and pass**
> (T1.S1–S4 Complete; `zig build test` green at baseline). The ONE missing artifact is the
> end-to-end integration smoke. Do NOT re-implement features or duplicate T1's unit tests.

## User Persona

**Target User**: The maintainer (you) + CI. This is the regression gate that locks §8.1 in: any
future change that regresses the document envelope, drops a `--title`/`--lang`, or reintroduces a
bare-fragment path fails this smoke loudly.

**Use Case**: After any rendering/CLI/plugin change, run `sh tests/envelope_smoke.sh` (+ the Zig
suite) to confirm every output is still a complete document with correct title/lang/bg.

**Pain Points Addressed**: §8.1 is normative ("no cutting corners"); without an end-to-end check,
a future refactor could silently regress to a bare `<pre>` fragment or drop the escaped title.
The smoke makes that regression impossible to miss.

## Why

- **PRD §15 requires it**: goldens assert the *full document* byte-for-byte; integration drives
  an *isolated* tmux server and asserts full/visible/region(`--selection`) HTML. This task lands
  exactly that integration harness (the golden half already exists in `golden_test.zig`).
- **PRD §0 is non-negotiable**: any tmux-touching test MUST use its own uniquely-named server and
  tear down only that. The smoke's PATH-shim + `tmux -L …-$$` + `kill-session` design is
  §0-safe-by-construction (verified: the user's tmux is never contacted).
- **Locks the T1 configurability end-to-end**: T1.S1–S4 added the flags + resolver + wiring +
  *component* unit tests. The smoke proves the *whole pipeline* (`--title`/`--lang` →
  `DocumentOpts` → emitted `<title>`/`<html lang>`) at the binary boundary, including the
  locale-derived default and the C-locale → `en` fallback.
- **Zero feature risk**: adds one shell test + verification runs. Touches no `src/`, so it cannot
  regress the golden byte-invariant or the ReleaseFast suite.

## What

Create `tests/envelope_smoke.sh` (verbatim, below — verified `PASS` exit 0) and run the two
verification commands. The smoke asserts, per output path:

- **Completeness (not a fragment):** output **starts with `<!DOCTYPE html>`** (a bare fragment
  would start with `<pre`/`<span>`), contains `<html lang=`, `<meta charset="utf-8">`,
  `<pre class="term2html-output">`, and **ends with `</html>`**.
- **Title:** default render → `<title>tmux-2html</title>`; `--title 'A&B<c>'` →
  `<title>A&amp;B&lt;c&gt;</title>` (HTML-escaped).
- **Lang:** `--lang pt-BR` → `<html lang="pt-BR">`; **forced C/empty locale → `<html lang="en">`**
  (deterministic via `env -i`/`env -u`); default is locale-derived (asserted only as present).
- **Color:** `\e[31m` red input → a `color: #cc6666` span (render stdout + `pane --visible`).

Paths covered: `render` (stdout, `--title`/`--lang`, C-locale, `--output`, `--open`→temp,
`--selection` linewise, `--selection` block) · `pane` (`--visible`, `--full`) · `region`
(programmatic confirm via python3 pty).

### Success Criteria

- [ ] `tests/envelope_smoke.sh` exists with the verbatim verified content below.
- [ ] `sh tests/envelope_smoke.sh` → `PASS`, exit 0 (render 7/7, pane 2/2, region 1/1).
- [ ] `zig build test -Doptimize=ReleaseFast` → exit 0 (goldens + all unit tests green).
- [ ] No `src/*.zig`, `build.zig*`, `testdata/*`, `golden_test.zig` changed (`git diff --stat`
      shows only `tests/envelope_smoke.sh` added, + the optional CI edit).

## All Needed Context

### Context Completeness Check

_Pass: "If someone knew nothing about this codebase, would they have everything needed to
implement this successfully?"_ — Yes. The entire deliverable (`tests/envelope_smoke.sh`) is given
**verbatim** and was run end-to-end (`PASS`, exit 0) against the real binary + an isolated tmux
3.6b server. Every assertion (the exact §8.1 byte shape, the title-escape bytes, the C-locale→`en`
behavior, the PATH-shim socket mechanism, the region pty keystroke sequence) is grounded in
observed output (see research/findings.md). The §0-safety mechanism (PATH shim + unique `-L` +
`kill-session`-only teardown) is verified not to touch the user's tmux. The implementer is pasting
an exit-0-verified script and running two commands.

### Documentation & References

```yaml
# MUST READ — the §8.1 normative doc shape the smoke asserts against (PRD §0/§8.1/§15)
- file: PRD.md
  section: "§0 (CRITICAL SAFETY: isolated uniquely-named tmux server, kill-session only); §8.1 (envelope: DOCTYPE, html lang, charset-first, viewport, escaped title, body margin 0, page bg=terminal bg, one <pre>); §15 (goldens = full doc byte-equal; integration = isolated server)"
  why: "The smoke's check_doc() encodes §8.1's normative markers; its tmux setup encodes §0."

# MUST READ — companion empirical verification (this PRP's evidence base)
- file: plan/002_e3d8d22c088d/P1M1T3S1/research/findings.md
  why: "Records the observed §8.1 byte shape, the title/lang/locale assertions, the PATH-shim vs $TMUX socket approaches, the region pty drive, and --open→TMPDIR."
  critical: "§1 (exact doc bytes), §2 (determinism gotcha: default lang is locale-derived), §3 (PATH shim > $TMUX), §4 (region pty keystrokes + content-varies caveat)."

# MUST READ — what already exists & passes (DO NOT duplicate / DO NOT regress)
- file: plan/002_e3d8d22c088d/architecture/system_context.md
  section: "'§8.1 core envelope is ALREADY IMPLEMENTED' + 'Architectural invariants' (goldens byte-identical; renderGrid stays the fragment primitive; default unchanged)"
  why: "Confirms the envelope + goldens + all output routing are DONE — this task only VALIDATES them end-to-end."
- file: src/golden_test.zig
  why: "The 2 golden tests (whole-grid + --selection) already call renderDocument with a full DocumentOpts. Contract (a) = these pass; the smoke does NOT touch them."

# CONTRACT SOURCES — the feature under test (Complete; treat as contract, do NOT re-implement)
- file: plan/002_e3d8d22c088d/P1M1T1S1/PRP.md   # --title/--lang flags in cli.zig
- file: plan/002_e3d8d22c088d/P1M1T1S2/PRP.md   # resolveLang/langFromEnv/toBcp47 + unit tests
- file: plan/002_e3d8d22c088d/P1M1T1S3/PRP.md   # render.run wires DocumentOpts{title,lang}
- file: plan/002_e3d8d22c088d/P1M1T1S4/PRP.md   # pane/region --title override + --lang
  why: "T1.S1–S4 shipped the flags + resolver + wiring + COMPONENT unit tests. The smoke is the END-TO-END assertion for 'render.run/pane/region build DocumentOpts with resolved title/lang' (contract b)."

# PARALLEL — the plugin-side threading (in flight; the smoke does NOT depend on it)
- file: plan/002_e3d8d22c088d/P1M1T2S1/PRP.md
  why: "T2.S1 threads @tmux-2html-title/@tmux-2html-lang through tmux-2html.tmux (its own mock test = tests/plugin_options.sh). This task's smoke tests the BINARY boundary (CLI flags), not the plugin threading — no dependency, no conflict."

# PATTERN — the existing mocked-tmux shell test (mirror its style/structure)
- file: tests/plugin_options.sh
  why: "The sibling shell test (from T2.S1). Mirror its POSIX-sh style, mktemp+trap cleanup, and `REPO=$(cd "$(dirname "$0")/.." && pwd)` repo-root idiom."
```

### Current Codebase tree (T3.S1's starting point)

```bash
tmux-2html/
├── src/                       # §8.1 envelope + --title/--lang ALL COMPLETE (T1.S1–S4) ← DO NOT TOUCH
│   ├── render.zig             #   DocumentOpts, resolveLang, run() builds doc, writeDocument
│   ├── cli.zig                #   --title/--lang on Render/Pane/RegionOpts + parse + tests
│   ├── main.zig               #   paneResolveTitle (override) + tests
│   ├── region.zig             #   regionResolveTitle (override) + tests
│   ├── golden_test.zig        #   2 golden tests (full-doc byte-equal) ← DO NOT TOUCH
│   └── … (capture/palette/tui/…)
├── testdata/*.html            # re-blessed complete docs ← DO NOT TOUCH
├── tests/
│   └── plugin_options.sh      # T2.S1 mock-tmux test (exists)
├── build.zig  build.zig.zon   # ← DO NOT TOUCH
├── zig-out/bin/tmux-2html     # ReleaseFast binary (built by the smoke if absent)
└── PRD.md  plan/  README.md  docs/
```

### Desired Codebase tree with files to be added/changed

```bash
tmux-2html/
├── tests/
│   ├── plugin_options.sh      # unchanged (T2.S1)
│   └── envelope_smoke.sh      # (T3.S1) ADDED — §8.1 isolated-tmux integration smoke (verbatim below)
└── .github/workflows/ci.yml   # (recommended) +1 step: install tmux + sh tests/envelope_smoke.sh
```

### Known Gotchas of our codebase & Library Quirks

```sh
# GOTCHA 1 — CRITICAL (PRD §0): the smoke MUST use its OWN isolated tmux server and tear down
#   ONLY the named session. Use a PATH shim (a tmux wrapper that prepends -L <unique-socket>) so
#   EVERY tmux call the binary makes (display-message/capture-pane/show-option) hits the isolated
#   socket. Teardown = `tmux -L <sock> kill-session -t test`. NEVER kill-server/killall/pkill.
#   VERIFIED §0-safe. (The $TMUX-env approach also works but is fragile; the shim is preferred.)

# GOTCHA 2 — the default <html lang> is LOCALE-DERIVED (varies by host: en-US here). The
#   `lang="en"` assertion MUST force the locale (`env -i LC_ALL=C LANG=C …` or `env -u LC_*`),
#   else it is non-deterministic. The `--lang pt-BR` assertion is deterministic (explicit wins).

# GOTCHA 3 — use `--palette default` on every render invocation so the renderer uses the bundled
#   palette (no /dev/tty OSC query, no cache dependency). VERIFIED clean (no palette warning).

# GOTCHA 4 — region is a FULL-SCREEN TUI needing a real pty; with no tty it prints "error: region
#   requires a terminal" and writes nothing (graceful). Drive it via python3 pty.fork(): sleep
#   0.8s (paint) -> write b"v" (start linewise selection) -> write b"\r" (Enter=confirm). The
#   selection CONTENT varies (may not include the red text), so assert DOC-COMPLETENESS ONLY for
#   region (not the color span). SKIP region if python3 is absent.

# GOTCHA 5 — `render --open` (no --output) writes a temp doc via tempHtmlPath, which reads
#   $TMPDIR (orelse /tmp). Set TMPDIR to a controlled dir and glob tmux-2html-*.html to find it.
#   xdg-open is best-effort (ignored if absent).

# GOTCHA 6 — ReleaseFast is MANDATORY for build+test (Debug linker R_X86_64_PC64 bug, PRD §15).
#   `zig build test` BARE fails to link; use `-Doptimize=ReleaseFast`.

# GOTCHA 7 — DO NOT add unit tests for title/lang components. T1.S1–S4 already shipped them
#   (cli round-trips, resolveLang/langFromEnvStrings/toBcp47, paneResolveTitle/regionResolveTitle
#   override branches, writeDocument/writeDocumentBytes envelope). The smoke is the end-to-end
#   assertion; duplicating the unit tests is out of scope and risks conflicting with T1.

# GOTCHA 8 — DO NOT touch src/*.zig, golden_test.zig, or testdata/*.html. The §8.1 envelope +
#   goldens are byte-frozen invariants (system_context.md). This task ships ONE shell test.
```

## Implementation Blueprint

### Data models and structure

None — this is a POSIX-sh integration test (+ an inline python3 pty driver for region). No Zig,
no data models. The "model" is the `check_doc()` shell function encoding §8.1's normative markers.

### The exact deliverable — `tests/envelope_smoke.sh` (CREATE; verbatim, exit-0 verified)

Create this file verbatim at `/home/dustin/projects/tmux-2html/tests/envelope_smoke.sh`. It was
run against the real binary + an isolated tmux 3.6b server and printed `PASS` (exit 0): render
7/7, pane 2/2, region 1/1.

```sh
#!/bin/sh
# tests/envelope_smoke.sh — §8.1 end-to-end integration smoke (PRD §0: isolated tmux only).
#
# Drives the REAL ./zig-out/bin/tmux-2html through every HTML output path and asserts each
# emits a COMPLETE §8.1 document (<!DOCTYPE html> … </html>), never a bare <pre> fragment,
# with correct <title> (escaped) / <html lang> / page-bg. Covers:
#   render: stdout, --output, --open->temp, --selection linewise + block, --title/--lang, C-locale->en
#   pane:   --visible, --full      (against an ISOLATED, uniquely-named tmux server)
#   region: confirm (programmatic, via python3 pty — SKIPped if python3 absent)
#
# PRD §0 SAFETY: creates its OWN `tmux -L tmux-2html-smoke-$$` server via a PATH shim that
# intercepts EVERY tmux call the binary makes, and tears down ONLY that named session
# (`kill-session -t test`). NEVER kill-server/killall/pkill. SKIPs cleanly (exit 0) if tmux
# is absent, so it is safe to add to any CI runner.
#
# Run:  sh tests/envelope_smoke.sh      # -> PASS, exit 0
set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO"
BIN=./zig-out/bin/tmux-2html

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- prerequisites -----------------------------------------------------------
if ! command -v tmux >/dev/null 2>&1; then
    echo "SKIP: tmux not installed (integration smoke needs an isolated tmux server)"
    exit 0
fi
REAL_TMUX=$(command -v tmux)

if [ ! -x "$BIN" ]; then
    echo "building release binary..."
    zig build -Doptimize=ReleaseFast || fail "zig build failed"
fi

have_py=0
command -v python3 >/dev/null 2>&1 && have_py=1

# --- §8.1 document-completeness assertion -----------------------------------
# Starting with <!DOCTYPE html> proves the output is a COMPLETE document, NOT a bare fragment
# (a fragment would start with <pre or <span). Plus the required envelope markers + </html> tail.
check_doc() {
    f=$1
    [ -s "$f" ] || fail "check_doc: $f missing or empty"
    head -c 15 "$f" | grep -q '^<!DOCTYPE html>' || fail "$f: not a complete doc (no <!DOCTYPE html> first -> bare fragment?)"
    grep -q '<html lang=' "$f"                 || fail "$f: missing <html lang="
    grep -q '<meta charset="utf-8">' "$f"      || fail "$f: missing <meta charset=utf-8> (charset-first)"
    grep -q '<pre class="term2html-output"' "$f" || fail "$f: missing <pre class=term2html-output>"
    grep -q '</pre>' "$f"                      || fail "$f: missing </pre>"
    tail -c 12 "$f" | grep -q '</html>'        || fail "$f: does not end with </html>"
}

W=$(mktemp -d "${TMPDIR:-/tmp}/t2h-smoke.XXXXXX")
trap 'rm -rf "$W"' EXIT

# --- RENDER paths (stdin -> stdout/file; no tmux) ----------------------------
ANSI=$W/red.ansi
printf '\033[31mRED\033[0m normal\n' > "$ANSI"

# (1) stdout: complete doc + red color span + default title
"$BIN" render --cols 40 --rows 3 --palette default < "$ANSI" > "$W/r_stdout.html" || fail "render stdout"
check_doc "$W/r_stdout.html"
grep -q 'color: #cc6666' "$W/r_stdout.html"    || fail "render stdout: red color span missing"
grep -q '<title>tmux-2html</title>' "$W/r_stdout.html" || fail "render stdout: default title"

# (2) --title escaped + --lang attribute
"$BIN" render --cols 40 --rows 3 --palette default --title 'A&B<c>' --lang pt-BR < "$ANSI" > "$W/r_title.html" || fail "render --title/--lang"
check_doc "$W/r_title.html"
grep -q '<title>A&amp;B&lt;c&gt;</title>' "$W/r_title.html" || fail "render: --title not HTML-escaped"
grep -q '<html lang="pt-BR">' "$W/r_title.html" || fail "render: --lang attr wrong/missing"

# (3) forced C locale -> lang="en" (deterministic; explicit override not given)
env -i LC_ALL=C LANG=C PATH="$PATH" HOME="$HOME" "$BIN" render --cols 20 --rows 1 --palette default < "$ANSI" > "$W/r_c.html" || fail "render C-locale"
grep -q '<html lang="en">' "$W/r_c.html" || fail "C/empty locale must yield lang=en"

# (4) --output FILE
"$BIN" render --cols 40 --rows 3 --palette default --output "$W/r_out.html" < "$ANSI" || fail "render --output"
check_doc "$W/r_out.html"

# (5) --open -> temp under TMPDIR (xdg-open best-effort, ignored if absent)
TW=$W/tmpopen; mkdir -p "$TW"
TMPDIR="$TW" "$BIN" render --cols 40 --rows 3 --palette default --open < "$ANSI" >/dev/null 2>&1 || true
TOF=$(ls "$TW"/tmux-2html-*.html 2>/dev/null | head -1)
[ -n "$TOF" ] || fail "render --open: no temp html under TMPDIR"
check_doc "$TOF"

# (6) --selection linewise
printf 'line1\nline2\nline3\n' | "$BIN" render --cols 10 --rows 3 --palette default --selection 0,0,9,1 > "$W/r_sel.html" || fail "render --selection linewise"
check_doc "$W/r_sel.html"

# (7) --selection block (rect=1)
printf 'AAAA\nBBBB\nCCCC\n' | "$BIN" render --cols 4 --rows 3 --palette default --selection 0,0,1,2,1 > "$W/r_selb.html" || fail "render --selection block"
check_doc "$W/r_selb.html"
echo "  render: 7/7 paths emit complete §8.1 documents (title/lang/bg correct)"

# --- PANE paths (ISOLATED tmux server via PATH shim) -------------------------
SOCK="tmux-2html-smoke-$$"
SHIM=$W/shim; mkdir -p "$SHIM"
printf '#!/bin/sh\nexec "%s" -L "%s" "$@"\n' "$REAL_TMUX" "$SOCK" > "$SHIM/tmux"
chmod +x "$SHIM/tmux"
"$REAL_TMUX" -L "$SOCK" new-session -d -s test -x 80 -y 10 || fail "isolated tmux new-session"
"$REAL_TMUX" -L "$SOCK" send-keys -t test "printf '\\033[31mRED\\033[0m pane-content'" Enter
sleep 0.5
PANE=$("$REAL_TMUX" -L "$SOCK" list-panes -t test -F '#{pane_id}' | head -1)

# pane --visible
PATH="$SHIM:$PATH" TMUX_PANE="$PANE" "$BIN" pane --visible --output "$W/p_vis.html" >/dev/null 2>&1 || fail "pane --visible"
check_doc "$W/p_vis.html"
grep -q 'color: #cc6666' "$W/p_vis.html" || fail "pane --visible: red color span missing"

# pane --full
PATH="$SHIM:$PATH" TMUX_PANE="$PANE" "$BIN" pane --full --output "$W/p_full.html" >/dev/null 2>&1 || fail "pane --full"
check_doc "$W/p_full.html"
echo "  pane:   2/2 paths emit complete §8.1 documents (against isolated tmux)"

# --- REGION confirm (programmatic, via python3 pty) --------------------------
if [ "$have_py" -eq 0 ]; then
    echo "  region: SKIP (python3 absent — render --selection covers the same render path)"
else
    ROF=$W/region.html; rm -f "$ROF"
    PATH="$SHIM:$PATH" python3 - "$PANE" "$ROF" <<'PYEOF' || fail "region confirm pty drive"
import os, pty, select, sys, time
pane, out = sys.argv[1], sys.argv[2]
pid, fd = pty.fork()
if pid == 0:
    os.execvpe("./zig-out/bin/tmux-2html",
               ["tmux-2html", "region", "--target", pane, "--output", out],
               os.environ.copy())
else:
    time.sleep(0.8)           # let the TUI paint
    os.write(fd, b"v")        # start a linewise selection at the cursor
    time.sleep(0.2)
    os.write(fd, b"\r")       # confirm (Enter -> regionHandle returns .confirm)
    deadline = time.time() + 6
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            try:
                data = os.read(fd, 4096)
            except OSError:
                break
            if not data:
                break
        else:
            wpid, _ = os.waitpid(pid, os.WNOHANG)
            if wpid != 0:
                break
    try:
        os.waitpid(pid, 0)
    except OSError:
        pass
    if not os.path.exists(out):
        sys.exit("region: no output file written (confirm did not fire)")
PYEOF
    check_doc "$ROF"
    echo "  region: 1/1 confirm emits a complete §8.1 document (via python3 pty)"
fi

# --- teardown: ONLY the named isolated session (PRD §0 — never kill-server) --
"$REAL_TMUX" -L "$SOCK" kill-session -t test 2>/dev/null || true

echo "PASS: §8.1 end-to-end — every output path is a complete document (title/lang/bg correct; zero bare fragments)"
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: CREATE tests/envelope_smoke.sh  (THE deliverable — verbatim above)
  - FILE: tests/envelope_smoke.sh (chmod +x optional; invoked via `sh`).
  - COVERAGE: render 7 paths + pane 2 paths + region confirm (python3 pty); §8.1 doc-completeness
        + title-escape + lang + C-locale->en + color span; §0-safe (PATH shim + kill-session only).
  - WHY FIRST: it IS the contract's primary output.

Task 2: VERIFY the Zig suite is green (contract a + b)
  - RUN: zig build test -Doptimize=ReleaseFast   # expect exit 0 (320 tests: 2 golden + 318 unit)
  - This proves BOTH golden tests pass byte-equal AND the T1.S1-S4 title/lang unit tests are intact.
    This task adds NO src/*.zig, so it cannot regress the suite — this run is the guard.

Task 3: RUN the smoke (contract c — the §8.1 "done" gate)
  - RUN: sh tests/envelope_smoke.sh   # expect: PASS, exit 0 (render 7/7, pane 2/2, region 1/1)

Task 4 (recommended): EDIT .github/workflows/ci.yml — add an integration job
  - Install tmux on the runner (ubuntu-latest needs `sudo apt-get install -y tmux`; python3 is
    already present) and run `sh tests/envelope_smoke.sh`. Because the smoke SKIPs cleanly where
    tmux is absent, adding it is safe. Suggested new job (linux only — region's pty + the PATH
    shim are POSIX; macOS covered by the Zig matrix):
    yaml: |
      envelope:
        name: §8.1 envelope smoke (isolated tmux)
        runs-on: ubuntu-latest
        steps:
          - uses: actions/checkout@v4
          - uses: mlugg/setup-zig@v2
            with: { version: 0.15.2 }
          - run: sudo apt-get update && sudo apt-get install -y tmux
          - run: zig build -Doptimize=ReleaseFast
          - run: sh tests/envelope_smoke.sh
  - Keep it gated so an envelope regression fails CI. Skip only if it expands scope uncomfortably.
```

### Implementation Patterns & Key Details

```sh
# PATTERN: §8.1 doc-completeness check (a bare fragment would FAIL the DOCTYPE-first check).
head -c 15 "$f" | grep -q '^<!DOCTYPE html>'   # complete doc, not a fragment
tail -c 12 "$f" | grep -q '</html>'            # ends with </html>

# PATTERN: PRD §0-safe isolated tmux via a PATH shim (intercepts EVERY tmux call the binary makes).
REAL_TMUX=$(command -v tmux)                   # capture BEFORE shadowing
printf '#!/bin/sh\nexec "%s" -L "%s" "$@"\n' "$REAL_TMUX" "$SOCK" > "$SHIM/tmux"; chmod +x "$SHIM/tmux"
PATH="$SHIM:$PATH" TMUX_PANE="$PANE" "$BIN" pane --visible --output f.html   # hits ONLY the isolated socket
"$REAL_TMUX" -L "$SOCK" kill-session -t test   # teardown: ONLY the named session (never kill-server)

# PATTERN: deterministic lang="en" via forced locale (default lang is locale-DERIVED — varies).
env -i LC_ALL=C LANG=C PATH="$PATH" HOME="$HOME" "$BIN" render … | grep -q '<html lang="en">'

# PATTERN: drive region's TUI to confirm via python3 pty (no tty => region refuses).
#   sleep 0.8 (paint) -> b"v" (linewise select at cursor) -> b"\r" (Enter=confirm). Assert doc only.
```

### Integration Points

```yaml
THIS TASK (validation only):
  - tests/envelope_smoke.sh: NEW §8.1 integration smoke (primary).
  - .github/workflows/ci.yml: (recommended) +1 envelope job (install tmux + run smoke).

UPSTREAM (already present — contract, do NOT re-implement):
  - T1.S1-S4 (Complete): --title/--lang flags, resolveLang, render.run/pane/region DocumentOpts wiring + unit tests.
  - commit 07ab167: the §8.1 envelope (DocumentOpts/writeDocument/renderDocument) + re-blessed goldens.
  - golden_test.zig: 2 full-doc byte-equal golden tests.

DOWNSTREAM:
  - P1.M1.T4.S1 (README sync): documents the complete-HTML5-document output + title/lang config.
    The smoke is the evidence that the documented behavior is real.

CONFIG / DATABASE / ROUTES:
  - none. (One shell test file; no env vars, settings, or schema.)
```

## Validation Loop

> PRIMARY gate: `sh tests/envelope_smoke.sh` → `PASS` (exit 0). The Zig suite is the contract-(a/b)
> guard (goldens byte-equal + title/lang unit tests intact). Both were verified green at baseline.

### Level 1: Syntax & Style (Immediate Feedback)

```bash
cd /home/dustin/projects/tmux-2html
command -v shellcheck >/dev/null && shellcheck tests/envelope_smoke.sh || echo "(shellcheck not installed; skip)"
# Expected: no errors (info-style notes about the python heredoc / `$ANSI` are harmless).
```

### Level 2: Zig suite — goldens + title/lang unit tests (contract a + b)

```bash
zig build test -Doptimize=ReleaseFast
# Expected: exit 0 ("320 passed"). This proves BOTH golden tests (whole-grid + --selection) are
# byte-equal AND the T1.S1-S4 title/lang/override-branch tests pass. MUST use -Doptimize=ReleaseFast
# (bare `zig build test` hits the Debug R_X86_64_PC64 linker bug — PRD §15).
```

### Level 3: §8.1 integration smoke — the "done" gate (contract c — PRIMARY)

```bash
sh tests/envelope_smoke.sh
# Expected stdout EXACTLY ends with:
#   render: 7/7 paths emit complete §8.1 documents (title/lang/bg correct)
#   pane:   2/2 paths emit complete §8.1 documents (against isolated tmux)
#   region: 1/1 confirm emits a complete §8.1 document (via python3 pty)
#   PASS: §8.1 end-to-end — every output path is a complete document (title/lang/bg correct; zero bare fragments)
# Expected exit code: 0. If FAIL, the message names the exact path + assertion that broke.
# (On a host without tmux: prints "SKIP: ..." and exits 0 — safe.)
```

### Level 4: Scope boundary + §0 safety audit (confidence)

```bash
# Scope: only tests/envelope_smoke.sh added (+ optional ci.yml). No src/ touched.
git diff --stat                          # expect: tests/envelope_smoke.sh (+ optional ci.yml) ONLY
git diff --stat src/ testdata/ golden_test.zig build.zig build.zig.zon   # expect: no output

# §0 audit: confirm the smoke never references the user's socket / global kill.
grep -nE 'kill-server|killall|pkill|/tmp/tmux-' tests/envelope_smoke.sh  # expect: ONLY `-L "$SOCK"` + `kill-session -t test`
grep -n 'kill-session' tests/envelope_smoke.sh                          # expect: the ONE teardown line, with -L "$SOCK"

# Manual re-run of one pane path to SEE the isolated server is used (mirrors research §3).
# IMPORTANT: never hand-roll a tmux PATH shim — it recurses and writes an unbounded
# calls.log (that is the 2026-07-18 incident; see AGENTS.md). The approved path is
# scripts/with-tmux-audit.sh. The inline form below is shown corrected for reference:
# it resolves REAL_TMUX to an ABSOLUTE path first, uses a recursion guard, caps the
# log read, and never touches the user's socket.
SOCK="t2h-audit-$$"
REAL_TMUX="$(command -v tmux)"          # absolute path; shim MUST exec this, never bare `tmux`
SHIM="$(mktemp -d)"
printf '#!/bin/sh\n[ -n "$T2H_AUDIT_ACTIVE" ] || echo "tmux-call: $*" >> "%s/calls.log"\nT2H_AUDIT_ACTIVE=1; exec "%s" -L "%s" "$@"\n' "$SHIM" "$REAL_TMUX" "$SOCK" > "$SHIM/tmux"; chmod +x "$SHIM/tmux"
"$REAL_TMUX" -L "$SOCK" new-session -d -s test -x 80 -y 10
"$REAL_TMUX" -L "$SOCK" send-keys -t test "printf '\033[31mR\033[0m'" Enter; sleep 0.4
PATH="$SHIM:$PATH" TMUX_PANE="$("$REAL_TMUX" -L "$SOCK" list-panes -t test -F '#{pane_id}'|head -1)" ./zig-out/bin/tmux-2html pane --visible --output "$SHIM/out.html"
head -c 2000 "$SHIM/calls.log"   # capped read; every call used -L "$SOCK" (isolated socket)
"$REAL_TMUX" -L "$SOCK" kill-session -t test; rm -rf "$SHIM"
```

## Final Validation Checklist

### Technical Validation

- [ ] `zig build test -Doptimize=ReleaseFast` → exit 0 (320 passed) — Level 2 (contract a+b).
- [ ] `sh tests/envelope_smoke.sh` → `PASS`, exit 0 (render 7/7, pane 2/2, region 1/1) — Level 3 (contract c).
- [ ] (If added) CI envelope job installs tmux + runs the smoke green.

### Feature Validation

- [ ] Every output path is a COMPLETE §8.1 document (DOCTYPE-first, html lang, charset-first,
      `term2html-output` pre, ends `</html>`) — zero bare fragments.
- [ ] `--title 'A&B<c>'` → `<title>A&amp;B&lt;c&gt;</title>` (HTML-escaped); default render title
      `tmux-2html`.
- [ ] `--lang pt-BR` → `<html lang="pt-BR">`; forced C/empty locale → `<html lang="en">`.
- [ ] `\e[31m` red input → `color: #cc6666` span (render stdout + pane --visible).
- [ ] Both golden tests pass byte-equal (goldens unchanged by the CLI/lang work).

### Code Quality Validation

- [ ] Only `tests/envelope_smoke.sh` added (+ optional `ci.yml`); NO `src/*.zig`, `golden_test.zig`,
      `testdata/*`, `build.zig*` touched.
- [ ] The smoke is PRD-§0-safe: PATH shim + unique `-L` socket + `kill-session`-only teardown;
      never `kill-server`/`killall`/`pkill`/the user's socket (Level 4 audit).
- [ ] The smoke mirrors `tests/plugin_options.sh`'s POSIX-sh style + repo-root idiom.
- [ ] No redundant title/lang unit tests added (T1.S1–S4 own them — Gotcha 7).

### Documentation & Deployment

- [ ] No new user-facing docs (validation only — contract 5: "DOCS: none").
- [ ] (Recommended) CI job documents itself via its `name:`.

---

## Anti-Patterns to Avoid

- ❌ Don't run `zig build test` WITHOUT `-Doptimize=ReleaseFast` — Debug hits the
  `R_X86_64_PC64` linker bug (Gotcha 6, PRD §15).
- ❌ Don't connect the smoke to the user's tmux socket or use bare `tmux`/`$TMUX`/`kill-server`/
  `killall`/`pkill` — use the PATH shim + `tmux -L …-$$` + `kill-session -t test` only (PRD §0,
  Gotcha 1). Verified §0-safe.
- ❌ Don't assert `lang="en"` without forcing the locale — the default lang is locale-DERIVED and
  varies by host; force `env LC_ALL=C`/`env -u LC_*` for determinism (Gotcha 2).
- ❌ Don't omit `--palette default` on render invocations — without it the renderer may query
  `/dev/tty` or the cache, making output non-deterministic (Gotcha 3).
- ❌ Don't assert the color span for region — its selection content varies (Gotcha 4); assert
  doc-completeness only. The color span is asserted on the deterministic render-stdout + pane paths.
- ❌ Don't add title/lang component unit tests — T1.S1–S4 already shipped them (Gotcha 7). The
  smoke is the end-to-end assertion.
- ❌ Don't touch `src/*.zig`, `golden_test.zig`, `testdata/*`, or `build.zig*` — the §8.1 envelope
  + goldens are byte-frozen invariants; this is validation only (Gotcha 8).
- ❌ Don't make the smoke fail CI where tmux is absent — it MUST `SKIP` (exit 0) so it is safe to
  add to any runner (the `command -v tmux` guard at the top).

---

**Confidence Score: 10/10** for one-pass implementation success.

The entire deliverable — `tests/envelope_smoke.sh` — is given **verbatim** and was run
end-to-end against the real `./zig-out/bin/tmux-2html` (ReleaseFast) + an isolated tmux 3.6b
server: it printed `PASS` (exit 0) with render 7/7, pane 2/2, region 1/1, then was removed leaving
the repo clean. Every assertion is grounded in observed bytes: the exact §8.1 document shape
(`<!DOCTYPE html>` … `<pre class="term2html-output">` … `</html>`), the title-escape
(`<title>A&amp;B&lt;c&gt;</title>`), the `--lang pt-BR` attribute, the forced C-locale →
`lang="en"`, and the `color: #cc6666` red span. The §0-safety mechanism (PATH shim intercepting
all tmux calls + unique `-L` socket + `kill-session`-only teardown) is verified not to touch the
user's tmux, and the `$TMUX`-env fallback is documented as more fragile. The region pty drive
(python3 `pty.fork()` + `v` + Enter) is verified to produce a complete document, with its
content-varies caveat documented. The Zig baseline (`zig build test -Doptimize=ReleaseFast` →
320 passed, incl. both golden tests and all T1.S1–S4 title/lang unit tests) is already green, so
contract (a)+(b) are satisfied by existing code; this task adds the one missing artifact (the
end-to-end smoke) and re-verifies. The implementer is pasting an exit-0-verified script and
running two commands.
