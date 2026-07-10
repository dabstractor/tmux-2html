# PRP — P1.M1.T2.S1: Read `@tmux-2html-title`/`@tmux-2html-lang` in `tmux-2html.tmux` and thread into bindings

## Goal

**Feature Goal**: Wire two new tmux user options — `@tmux-2html-title` and `@tmux-2html-lang` —
through the existing `tmux-2html.tmux` POSIX-sh loader into **all three** prefix-table bindings
(`O` full, `visible`, `C-o` region popup), so a user's
`set -g @tmux-2html-title 'My Pane'` / `set -g @tmux-2html-lang pt-BR` reaches the binary as
`--title`/`--lang` on every capture path. Empty option ⇒ empty fragment ⇒ the binary's own
default (no behavior change). This is the **tmux-plugin half** of PRD §8.1 configurability
(G2/G3); the binary already accepts `--title`/`--lang` (S1 Complete) and pane/region honor them
(S4, parallel).

**Deliverable**: Three file changes + one new file:
1. **EDIT `tmux-2html.tmux`** — §3 options block (+`title_opt`/`lang_opt`/`title_arg`/`lang_arg`),
   the 3 bindings (interpolate `$title_arg $lang_arg` before `--target`), and the §4
   `TMUX_2HTML_DEBUG` seam (+4 vars).
2. **CREATE `tests/plugin_options.sh`** — a mocked-tmux test harness (none exists today) that
   sources the loader against a `tmux()` shell-function override and asserts (a) defaults ⇒ no
   `--title`/`--lang` in any bound command, (b) options set ⇒ `--title`/`--lang` present in all
   3 bindings, before `--target`. Pure POSIX sh, **no real tmux needed** (PRD §0-safe).
3. **EDIT `docs/CONFIGURATION.md`** — add the 2 new option rows + an "HTML output (§8.1)" note
   + the threading-accuracy clarification.
4. *(Recommended)* **EDIT `.github/workflows/ci.yml`** — add a one-step job to run the new
   shell test on every push/PR (it is deterministic and dependency-free).

**Success Definition** (all VERIFIED working against the live file in throwaway builds):
- `sh tests/plugin_options.sh` prints `PASS` and exits 0.
- With options set, the mock-captured bound commands contain `--title 'My Pane' --lang 'pt-BR'`
  **before** `--target '#{pane_id}'` in all three bindings; with options unset they contain
  neither token (proven end-to-end incl. fire-time `/bin/sh` arg parsing — `'My Pane'` survives
  as one argv element).
- `set -g @tmux-2html-title 'X'` / `set -g @tmux-2html-lang Y` flow through to the binary
  (end-to-end verified in **P1.M1.T3.S1** with isolated tmux; this task proves the threading via
  the mock harness).
- No `src/*.zig` touched; the Zig suite stays green (regression guard).

## User Persona

**Target User**: A tmux user who installs tmux-2html via TPM and wants every generated HTML
document to carry a custom `<title>` (e.g. a pane/server name) and a correct `<html lang>`
(screen readers, hyphenation, browser encoding).

**Use Case**: `set -g @tmux-2html-title "build-log"` + `set -g @tmux-2html-lang en-US` in
`~/.tmux.conf`, then `prefix O` → writes a complete HTML5 doc titled "build-log", `lang="en-US"`.

**Pain Points Addressed**: Today every plugin capture uses the contextual title and `lang="en"`
regardless of locale. §8.1 makes both configurable; S1 added the CLI flags, S4 wires pane/region,
and **this task makes the plugin actually pass the options through** (G2/G3).

## Why

- **PRD §8.1 (normative)**: `<title>` "Configurable via `--title` / `@tmux-2html-title`";
  `<html lang>` "default `en`; configurable via `@tmux-2html-lang` / locale". The CLI side is
  done (S1/S4); the **option → binding** path is the missing half.
- **Mirrors the proven `$TMUX_2HTML_BIN` pattern**: exported shell vars do NOT reach `run-shell`
  children (verified in plan/001 research), so values must be baked into the bind-key string at
  loader-source time. `title`/`lang` are the same kind of value → same NOW-expansion technique.
- **Zero-risk default**: an empty option yields an empty fragment, so existing users see no
  change until they set an option (verified: bound command stays `pane --full --target …`).
- **§0 safety**: the test harness uses a **mock** `tmux` (a shell function), never the user's
  socket — exactly what PRD §0 and plan/002 `system_context.md` require.

## What

Four localized changes (one new file). Semantics, in plain terms:

1. **Read the two options** in §3 (empty default), exactly like the existing 8 options.
2. **Build optional NOW-expanded fragments** `title_arg`/`lang_arg` that are either empty or
   `--title '<value>'` / `--lang '<value>'` (single-quoted to survive spaces at fire time).
3. **Interpolate `$title_arg $lang_arg` bare** into all three binding command strings, before
   `--target '#{pane_id}'`.
4. **Record all four vars** in the `TMUX_2HTML_DEBUG` seam (§4) for deterministic tests.
5. **Ship a mock-tmux test** asserting both cases, and **document** the two new options.

### Success Criteria

- [ ] `tmux-2html.tmux` §3 reads `@tmux-2html-title`/`@tmux-2html-lang` (empty default) + builds
      `title_arg`/`lang_arg`; §4 seam records `title_opt/lang_opt/title_arg/lang_arg`.
- [ ] All 3 bindings interpolate `$title_arg $lang_arg` before `--target '#{pane_id}'`.
- [ ] `sh tests/plugin_options.sh` → `PASS`, exit 0 (both assertion cases).
- [ ] `docs/CONFIGURATION.md` has the 2 new rows + the HTML-output note + threading clarification.
- [ ] No `src/*.zig` changed; `zig build test -Doptimize=ReleaseFast` still exits 0.

## All Needed Context

### Context Completeness Check

_Pass: "If someone knew nothing about this codebase, would they have everything needed to
implement this successfully?"_ — Yes. Every edit site is given as exact BEFORE/AFTER text unique
in its file; the new test file is given verbatim (and was run exit-0 against the live loader);
the quoting semantics (NOW-expansion + fire-time single-quote survival) are proven and
documented with the exact argv the binary receives. No guessing.

### Documentation & References

```yaml
# MUST EDIT — the loader (primary deliverable)
- file: tmux-2html.tmux
  section: "§3 options export line; §4 TMUX_2HTML_DEBUG `>` block; bindings @ lines 139 (O), 145 (visible), 184 (C-o region)"
  why: "THE file. 5 edits: add title/lang opts+fragments after the §3 export line; interpolate $title_arg $lang_arg before --target in the 3 bindings; append 4 printfs to the §4 seam."
  pattern: "Mirrors the proven $TMUX_2HTML_BIN NOW-expansion (exported vars don't reach run-shell children)."
  gotcha: "Line 162 is a COMMENT ('region --target'), NOT a binding — do not edit it. Exactly 3 binding sites (139/145/184)."

# MUST EDIT — docs (DOCS deliverable)
- file: docs/CONFIGURATION.md
  section: "Overview 'eight' bullet; Options table (ends @tmux-2html-binary-dir); 'How options are read' section"
  why: "Add the 2 new option rows + an HTML-output(§8.1) note + the threading-vs-re-read clarification."
  gotcha: "Do NOT add title/lang to the 'pane/region re-read via show-option' list — they are THREADED as flags (this task), unlike font/output-dir/open/history-limit."

# INPUT CONTRACT — the binary side (treat as contract; do NOT re-implement)
- file: src/cli.zig
  section: "PaneOpts.title/lang + RegionOpts.title/lang = ?[]const u8 (S1 Complete); parsePane/parseRegion --title/--lang"
  why: "Confirms the binary ACCEPTS --title/--lang on pane+region — so threading them from the plugin is correct and sufficient. This task does NOT touch cli.zig."

# CONTRACT SOURCES — S1/S4 (parallel) + the §8.1 normative spec
- file: plan/002_e3d8d22c088d/P1M1T1S1/PRP.md
  why: "Defines the --title/--lang flags on PaneOpts/RegionOpts/RenderOpts. S1 Complete."
- file: plan/002_e3d8d22c088d/P1M1T1S4/PRP.md
  why: "S4 (parallel) wires pane/region to honor --title/--lang into DocumentOpts. This task lands the values those flags will receive."
- file: PRD.md
  section: "§8.1 (title via @tmux-2html-title; lang via @tmux-2html-lang/locale); §9.2 (8 options — title/lang rows are NEW); §9.3 (3 bindings pass --target #{pane_id}); §0 (tests use mock/uniquely-named socket — never the user's tmux)"
  why: "Normative requirement + the safety rule the mock harness satisfies."

# ARCHITECTURE — this plan's scope + the threading-vs-re-read distinction
- file: plan/002_e3d8d22c088d/architecture/system_context.md
  section: "Gap table G2/G3 (title/lang via @tmux-2html-*); 'CRITICAL SAFETY (PRD §0)' (mock/uniquely-named socket)"
  why: "Confirms THIS task is G2/G3 (the option→binding path) and that §0 holds for all validation."

# EMPIRICAL VERIFICATION for this task (the evidence base)
- file: plan/002_e3d8d22c088d/P1M1T2S1/research/findings.md
  why: "Records the mock-harness run (baseline + post-edit Cases A/B), the fire-time argv proof, the 'no harness exists' finding, and the verbatim test template."
  critical: "§4 (verified Cases A/B) and §7 (the proven harness) are copy-paste-ready."
```

### Current Codebase tree (relevant slice)

```bash
tmux-2html/
├── tmux-2html.tmux         # <— EDIT (§3 options + 3 bindings + §4 seam) — primary deliverable
├── docs/CONFIGURATION.md   # <— EDIT (2 rows + HTML note + threading clarification)
├── tests/                  # <— CREATE dir + tests/plugin_options.sh (mocked-tmux harness)
├── .github/workflows/ci.yml # <— (recommended) add a shell-test step
├── src/                    # S1/S2/S3/S4 territory — DO NOT TOUCH
│   ├── cli.zig             #   --title/--lang flags (S1 Complete)
│   ├── main.zig  region.zig #   pane/region honor --title/--lang (S4 parallel)
│   ├── render.zig          #   DocumentOpts{title,lang}, resolveLang (S2/S3)
│   └── golden_test.zig     #   byte-invariant — bypassed by this CLI/plugin change
└── PRD.md                  # §8.1 / §9.2 / §9.3 / §0 normative
```

### Desired Codebase tree with files to be changed

```bash
tmux-2html/
├── tmux-2html.tmux         # MODIFIED — §3 +4 lines (opts) +6 lines (fragments); 3 bindings +$title_arg $lang_arg; §4 +4 printfs
├── docs/CONFIGURATION.md   # MODIFIED — Overview 'eight'→'ten'; +2 table rows; +HTML-output note; +threading clarification
├── tests/
│   └── plugin_options.sh   # ADDED — mocked-tmux harness (verbatim in Blueprint); sh tests/plugin_options.sh → PASS
└── .github/workflows/ci.yml # (recommended) +1 step: sh tests/plugin_options.sh
```

### Known Gotchas of our codebase & Library Quirks

```sh
# GOTCHA 1 — CRITICAL: $title_arg/$lang_arg MUST expand NOW (at loader-source time), NOT at
#   fire time. Exported vars do NOT reach run-shell children (verified plan/001). They sit
#   INSIDE the double-quoted bind-key command string, so the loader's shell expands them when
#   building the string — exactly like $TMUX_2HTML_BIN. Do NOT single-quote them out of expansion.

# GOTCHA 2 — single-quote the VALUE inside the fragment: title_arg="--title '$title_opt'".
#   The literal single quotes become part of the baked string and are re-parsed by run-shell's
#   /bin/sh at fire time, grouping a spaced value into ONE argv element. VERIFIED: 'My Pane'
#   → argv[N]=<My Pane>. Without the single quotes, 'My Pane' would split into two argv and
#   --title would grab only 'My'. (Embedded single quotes in a value are NOT escaped — a known
#   v1 limitation; matches the contract. Do not over-engineer.)

# GOTCHA 3 — empty fragment ⇒ harmless extra spaces. With both options unset the binding string
#   becomes `pane --full   --target '#{pane_id}'`. VERIFIED: the binary receives
#   `pane --full --target %5` — no spurious --title/--lang tokens. Do NOT try to collapse the
#   spaces; the bare `$title_arg $lang_arg` interpolation is the contract.

# GOTCHA 4 — line 162 of tmux-2html.tmux is a COMMENT ("…region --target #{pane_id}…"), NOT a
#   binding. There are EXACTLY 3 binding sites: 139 (O/full), 145 (visible), 184 (C-o popup).
#   Edit only those 3 (each has a unique `pane --full`/`pane --visible`/`region` prefix).

# GOTCHA 5 — the test harness NEEDS NO real tmux. It defines a `tmux()` shell function that
#   overrides the binary, sources the loader, and captures bind-key/display-popup args. This is
#   PRD §0-safe (never connects to any socket) and CI-portable (pure POSIX sh). Do NOT spin up a
#   real tmux server for THIS task's tests — the mock is deterministic and sufficient. (An
#   isolated-tmux end-to-end smoke is P1.M1.T3.S1, not here.)

# GOTCHA 6 — the mock `tmux()` must handle `display-popup` (the region binding + the palette
#   auto-sync both call it) and `display-message` (no-op), not just `show-option`/`bind-key`.
#   Otherwise sourcing aborts on `command not found`. The verbatim harness in the Blueprint
#   handles all four subcommands.

# GOTCHA 7 — the loader's early guard `return 0 2>/dev/null || exit 0` fires only when
#   TMUX_PLUGIN_MANAGER_PATH is unset. The harness SETS it, so the loader proceeds. And the
#   loader has NO `set -e` (a sourced plugin must never abort source-file), so mock quirks
#   won't crash it. Good.

# GOTCHA 8 — title/lang are THREADED (flags), NOT re-read. Unlike font/output-dir/open/
#   history-limit (which pane/region re-read via `tmux show-option` at runtime), the binary
#   does NOT re-read @tmux-2html-title/@tmux-2html-lang — the plugin bakes them into the
#   binding as --title/--lang. Document this accurately (CONFIGURATION.md) to avoid confusion.
```

## Implementation Blueprint

### Data models and structure

No data models (POSIX sh + Markdown only). The "model" is four shell variables
(`title_opt`, `lang_opt`, `title_arg`, `lang_arg`) computed in §3 and consumed by the bindings
+ the §4 seam.

### The exact deliverable — verbatim edits

#### FILE 1: `tmux-2html.tmux` (5 edits)

**Edit 1 — §3 options: add the two options + fragments.** Find the unique line (the §3 export):

```sh
# ---- BEFORE (exact, unique) ----
export full_key region_key visible_key open font history_limit output_dir binary_dir
```
Replace with:
```sh
# ---- AFTER ----
export full_key region_key visible_key open font history_limit output_dir binary_dir

# §8.1 HTML envelope knobs (P1.M1.T2.S1): document <title> + <html lang>. Empty default
# ⇒ the binary uses its own default (contextual title / locale-or-"en" lang). Unlike
# font/output-dir/open/history-limit (which the binary re-reads via show-option), these
# are THREADED into the bindings below as --title/--lang flags (the binary accepts both
# since P1.M1.T1.S1).
title_opt=$(read_opt @tmux-2html-title "")
lang_opt=$(read_opt @tmux-2html-lang "")
# NOW-expanded optional fragments (mirrors the $TMUX_2HTML_BIN interpolation: exported
# vars don't reach run-shell children, so bake them in at source time). Empty option ⇒
# empty fragment ⇒ binary default. Single-quoted so a spaced value survives run-shell's
# /bin/sh re-parse at fire time.
title_arg=""
[ -n "$title_opt" ] && title_arg="--title '$title_opt'"
lang_arg=""
[ -n "$lang_opt" ] && lang_arg="--lang '$lang_opt'"
export title_opt lang_opt title_arg lang_arg
```

**Edit 2 — `O` (full) binding (line 139).** Replace the unique inner substring:
```sh
# ---- BEFORE (exact, unique) ----
pane --full --target '#{pane_id}'
# ---- AFTER ----
pane --full $title_arg $lang_arg --target '#{pane_id}'
```

**Edit 3 — `visible` binding (line 145).** Replace the unique inner substring:
```sh
# ---- BEFORE (exact, unique) ----
pane --visible --target '#{pane_id}'
# ---- AFTER ----
pane --visible $title_arg $lang_arg --target '#{pane_id}'
```

**Edit 4 — `C-o` region popup (line 184).** Replace the unique inner substring:
```sh
# ---- BEFORE (exact, unique) ----
region --target '#{pane_id}'
# ---- AFTER ----
region $title_arg $lang_arg --target '#{pane_id}'
```

**Edit 5 — §4 `TMUX_2HTML_DEBUG` seam.** Find the unique block tail and add 4 printfs:
```sh
# ---- BEFORE (exact, unique) ----
        printf 'binary_dir=%s\n'      "$binary_dir"
    } > "$TMUX_2HTML_DEBUG"
# ---- AFTER ----
        printf 'binary_dir=%s\n'      "$binary_dir"
        printf 'title_opt=%s\n'       "$title_opt"
        printf 'lang_opt=%s\n'        "$lang_opt"
        printf 'title_arg=%s\n'       "$title_arg"
        printf 'lang_arg=%s\n'        "$lang_arg"
    } > "$TMUX_2HTML_DEBUG"
```
(Align the `"$var"` column to taste; the existing printfs use padded `%s` labels. Functionally
the alignment is irrelevant — the test greps `^title_arg=` etc.)

#### FILE 2: `tests/plugin_options.sh` (CREATE — verbatim, exit-0 verified)

Create a new `tests/` directory and this file. It was run against the live loader (baseline +
post-edit) and passes both assertion cases. Pure POSIX sh — no tmux, no Zig, no deps.

```sh
#!/bin/sh
# tests/plugin_options.sh — mocked-tmux plugin option test (PRD §0: never touches real tmux).
#
# Sources tmux-2html.tmux with a `tmux()` shell-function override and asserts that the
# §8.1 options @tmux-2html-title / @tmux-2html-lang thread into ALL prefix-table bindings
# (O full, visible, C-o region) as --title/--lang, BEFORE --target. Pure POSIX sh — needs
# NO tmux binary, so it is safe to run anywhere (incl. CI) and never touches the user's socket.
#
# Run:  sh tests/plugin_options.sh      # → prints PASS, exit 0
set -u

fail() { echo "FAIL: $*" >&2; exit 1; }

# Isolated fake plugin tree: binary "present" + executable ⇒ binary_ready=1 ⇒ bindings fire.
W=$(mktemp -d "${TMPDIR:-/tmp}/t2h-plugin.XXXXXX")
trap 'rm -rf "$W"' EXIT
PLUG="$W/plugins"
mkdir -p "$PLUG/tmux-2html/bin"
REPO=$(cd "$(dirname "$0")/.." && pwd)
cp "$REPO/tmux-2html.tmux" "$PLUG/tmux-2html/tmux-2html.tmux"
printf '#!/bin/sh\nexit 0\n' > "$PLUG/tmux-2html/bin/tmux-2html"; chmod +x "$PLUG/tmux-2html/bin/tmux-2html"

# Source the loader under a mock `tmux`. $1=title $2=lang $3=visible seed the option values
# the mock returns for `show-option`. Captures every bind-key/display-popup command string.
run_loader() {
    CAP="$W/cap.txt"; : > "$CAP"
    DBG="$W/debug.txt"; : > "$DBG"
    _T="$1"; _L="$2"; _V="$3"
    (
        tmux() {
            case "$1" in
                show-option)
                    case "$3" in
                        @tmux-2html-title) printf '%s' "$_T" ;;
                        @tmux-2html-lang)  printf '%s' "$_L" ;;
                        @tmux-2html-visible-key) printf '%s' "$_V" ;;
                        @tmux-2html-full-key) printf 'O' ;;
                        @tmux-2html-region-key) printf 'C-o' ;;
                        @tmux-2html-open) printf 'on' ;;
                        @tmux-2html-font) printf 'monospace' ;;
                        @tmux-2html-history-limit) printf '50000' ;;
                        @tmux-2html-output-dir|@tmux-2html-binary-dir) printf '' ;;
                        *) printf '' ;;
                    esac ;;
                bind-key) printf 'BK %s ' "$2" >> "$CAP"; shift 2; printf '%s\n' "$*" >> "$CAP" ;;
                display-popup) printf 'PP ' >> "$CAP"; shift; printf '%s\n' "$*" >> "$CAP" ;;
                display-message) : ;;
                *) : ;;
            esac
        }
        export TMUX_PLUGIN_MANAGER_PATH="$PLUG"
        export TMUX_2HTML_DEBUG="$DBG"
        export _T _L _V
        . "$PLUG/tmux-2html/tmux-2html.tmux"
    )
    CAPTURE=$(cat "$CAP")
}

# (a) DEFAULTS (both options unset) ⇒ NO --title/--lang in any bound command; seam fragments empty.
run_loader "" "" "v"   # visible='v' so all 3 bindings fire (O, visible, C-o)
printf '%s' "$CAPTURE" | grep -E -- '--title|--lang' && fail "defaults: --title/--lang present (expected none)"
grep -q '^title_arg=$' "$DBG" || fail "defaults: title_arg not empty in debug seam"
grep -q '^lang_arg=$'  "$DBG" || fail "defaults: lang_arg not empty in debug seam"

# (b) OPTIONS SET ⇒ --title/--lang present in ALL 3 bindings, BEFORE --target.
run_loader "My Pane" "pt-BR" "v"
for sub in 'pane --full' 'pane --visible' 'region'; do
    line=$(printf '%s' "$CAPTURE" | grep -E -- "$sub" | head -1)
    [ -n "$line" ] || fail "set: no bound command matched '$sub'"
    pre=$(printf '%s' "$line" | sed 's/--target.*//')   # everything BEFORE --target
    printf '%s' "$pre" | grep -qF -- "--title 'My Pane'" || fail "set: '$sub' missing --title 'My Pane' before --target"
    printf '%s' "$pre" | grep -qF -- "--lang 'pt-BR'"   || fail "set: '$sub' missing --lang 'pt-BR' before --target"
done
grep -q "^title_arg=--title 'My Pane'" "$DBG" || fail "set: debug seam title_arg wrong"
grep -q "^lang_arg=--lang 'pt-BR'"     "$DBG" || fail "set: debug seam lang_arg wrong"

echo "PASS: @tmux-2html-title/@tmux-2html-lang thread into all bindings (defaults empty; set ⇒ flags before --target)"
```

#### FILE 3: `docs/CONFIGURATION.md` (4 edits)

**Edit A — Overview count.** Replace:
```markdown
- **Options** — the eight `@tmux-2html-*` tmux user options and their defaults.
```
with:
```markdown
- **Options** — the ten `@tmux-2html-*` tmux user options and their defaults.
```

**Edit B — Options table: add 2 rows.** Find the table's last row (unique):
```markdown
| `@tmux-2html-binary-dir` | `$TMUX_2HTML_BIN` | Directory containing the `tmux-2html` binary. |
```
Append immediately after it:
```markdown
| `@tmux-2html-title` | *(empty)* | Document `<title>`. Empty ⇒ the contextual default (`tmux-2html — <session>/<pane> <iso8601>` for `pane`/`region`; `tmux-2html` for `render`). |
| `@tmux-2html-lang` | *(empty)* | `<html lang>` attribute (BCP-47 tag). Empty ⇒ locale-derived, fallback `en`. |
```

**Edit C — HTML output (§8.1) note.** Add this short note as a new paragraph right after the
Options table's `> **C-o key-conflict note.**` blockquote (i.e. just before `## How options are read`):

```markdown
### HTML output (§8.1)

Every capture — `render`, `pane`, and `region` alike — is a **complete, valid HTML5 document**
(`<!DOCTYPE html>` … `</html>`), never a bare `<pre>` fragment. The document's `<title>` and
`<html lang>` come from `@tmux-2html-title` and `@tmux-2html-lang`: set them and every generated
page reflects them; leave them empty for the contextual title and locale-derived language.
```

**Edit D — threading clarification.** In `## How options are read`, the existing text says the
binary re-reads `output-dir`/`history-limit`/`open`/`font` itself. Append one sentence so users
do not expect `title`/`lang` to be re-read too. After the sentence ending *"… they are not
propagated to `run-shell` children."* add:

```markdown
The `@tmux-2html-title` and `@tmux-2html-lang` options are the exception: the plugin bakes them
into the key bindings as `--title`/`--lang` flags (above), so the binary receives them directly
rather than re-reading them. You can also pass `--title`/`--lang` yourself when running the
binary standalone.
```

#### FILE 4 (recommended): `.github/workflows/ci.yml` — add a shell-test step

The new test is deterministic and dependency-free, so running it in CI prevents rot. Add a
second job (or a step in the existing `test` job AFTER the Zig tests). Simplest: a new job that
needs no Zig:

```yaml
  plugin:
    name: plugin options (sh)
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Plugin option threading test (mocked tmux; no tmux required)
        run: sh tests/plugin_options.sh
```
(If you prefer one job, add `- name: Plugin option test\n  run: sh tests/plugin_options.sh` as a
step in `test` after the Zig step. Either is fine; keep it gated so a regression fails CI.)

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: EDIT tmux-2html.tmux — options + fragments + bindings + seam (5 edits: 1-5 above)
  - Edit 1: after the §3 `export … binary_dir` line, add title_opt/lang_opt + title_arg/lang_arg.
  - Edits 2-4: the 3 bindings (lines 139/145/184) — interpolate `$title_arg $lang_arg` before --target.
  - Edit 5: §4 seam — append the 4 printfs after `binary_dir`.
  - DO NOT edit line 162 (a comment). DO NOT touch src/*.zig.
  - WHY FIRST: Task 2's harness sources THIS file.

Task 2: CREATE tests/plugin_options.sh (verbatim above) + tests/ dir
  - FILE: tests/plugin_options.sh (chmod +x optional; invoked via `sh`).
  - RUN: sh tests/plugin_options.sh → expect: PASS, exit 0.
  - COVERAGE: (a) defaults ⇒ no --title/--lang + empty seam fragments; (b) set ⇒ flags present
        in all 3 bindings before --target + populated seam.
  - SAFETY: mock `tmux()` only; never a real socket (PRD §0).

Task 3: EDIT docs/CONFIGURATION.md (4 edits: A-D above)
  - A: 'eight' → 'ten'. B: +2 table rows. C: +HTML output (§8.1) note. D: +threading clarification.
  - ACCURACY: do NOT add title/lang to the "re-read via show-option" list (Gotcha 8).

Task 4 (recommended): EDIT .github/workflows/ci.yml — add the plugin job/step (FILE 4 above).
  - Keep it gated so a regression fails CI. Skip only if it expands scope uncomfortably.

Task 5: VALIDATE (see Validation Loop — all verified exit 0).
  - sh tests/plugin_options.sh → PASS.
  - zig build test -Doptimize=ReleaseFast → still green (no Zig touched; regression guard).
```

### Implementation Patterns & Key Details

```sh
# PATTERN: NOW-expanded optional fragment (mirrors $TMUX_2HTML_BIN). Exported vars don't reach
#   run-shell children, so bake the value into the bind-key string at source time. Empty ⇒ "".
title_arg=""
[ -n "$title_opt" ] && title_arg="--title '$title_opt'"   # single-quotes are LITERAL in the baked string

# PATTERN: bare interpolation inside the double-quoted bind-key command string. The loader's
#   shell expands $title_arg/$lang_arg NOW; run-shell's /bin/sh re-parses (single-quotes group
#   spaced values) at FIRE time.
#   "... pane --full $title_arg $lang_arg --target '#{pane_id}' ..."
#   #{pane_id} stays literal (single-quoted) for tmux to expand at fire time.

# PATTERN: mock-tmux test (PRD §0-safe). A shell `tmux()` function overrides the binary; the
#   harness sources the loader, captures bind-key/display-popup args, asserts. No tmux needed.

# CRITICAL: there are exactly 3 binding sites (139/145/184). Line 162 is a comment. The mock
#   must handle show-option + bind-key + display-popup + display-message (else sourcing aborts).
```

### Integration Points

```yaml
THIS TASK (plugin-side threading):
  - tmux-2html.tmux: §3 options + 3 bindings + §4 seam.
  - tests/plugin_options.sh: new mocked-tmux harness.
  - docs/CONFIGURATION.md: 2 rows + note + clarification.
  - .github/workflows/ci.yml: (recommended) +1 shell-test step.

UPSTREAM (already present — contract, do NOT re-implement):
  - S1 (Complete): cli.PaneOpts/RegionOpts/RenderOpts .title/.lang = ?[]const u8 + --title/--lang parsing.
  - S4 (parallel): pane (main.zig) + region (region.zig) honor --title/--lang → DocumentOpts.
  - S2/S3 (render.zig): DocumentOpts{title,lang}, resolveLang, writeDocument emits <title>/<html lang>.

DOWNSTREAM (NOT this task):
  - P1.M1.T3.S1: isolated-tmux end-to-end smoke (set @tmux-2html-title → prefix O → assert
        <title> in the written HTML). This task's harness proves the threading; T3.S1 proves
        the full binary round-trip with a real (uniquely-named) tmux server.

CONFIG / DATABASE / ROUTES:
  - none. (Two new tmux user options; no env vars, no settings files, no schema.)
```

## Validation Loop

> PRIMARY gate: `sh tests/plugin_options.sh` → PASS (the mock harness proves the threading for
> both cases). The Zig suite is a regression guard (no `src/` is touched). An isolated-tmux
> end-to-end check is owned by P1.M1.T3.S1 (not duplicated here, per PRD §0).

### Level 1: Syntax & Style (Immediate Feedback)

```bash
cd /home/dustin/projects/tmux-2html
# POSIX-sh sanity: source-check the loader parses (the harness does this); optional lint:
command -v shellcheck >/dev/null && shellcheck tmux-2html.tmux tests/plugin_options.sh || echo "(shellcheck not installed; skip)"
# Expected: no errors (info-style notes about the mock's unused `$1` branches are harmless).
```

### Level 2: Plugin Option Threading Test (PRIMARY gate)

```bash
sh tests/plugin_options.sh
# Expected stdout EXACTLY ends with:
#   PASS: @tmux-2html-title/@tmux-2html-lang thread into all bindings (defaults empty; set ⇒ flags before --target)
# Expected exit code: 0. If FAIL, the message names the exact assertion that broke.
```

### Level 3: Zig Regression Guard (proves no src/ breakage)

```bash
zig build test -Doptimize=ReleaseFast
# Expected: exit 0, all tests green. This task touches NO Zig, so this is a guard that you did
# not accidentally edit src/. If it fails, you touched a .zig file — revert it.
# (Use -Doptimize=ReleaseFast: bare `zig build test` hits the Debug R_X86_64_PC64 linker bug.)
```

### Level 4: Manual mock re-run + golden-capture inspection (confidence)

```bash
# Re-run the harness mentally/inline to SEE the captured bound commands (mirrors research §4):
W=$(mktemp -d); PLUG="$W/plugins"; mkdir -p "$PLUG/tmux-2html/bin"
cp tmux-2html.tmux "$PLUG/tmux-2html/tmux-2html.tmux"
printf '#!/bin/sh\nexit 0\n' > "$PLUG/tmux-2html/bin/tmux-2html"; chmod +x "$PLUG/tmux-2html/bin/tmux-2html"
CAP="$W/cap.txt"; : > "$CAP"
( tmux() { case "$1" in
      show-option) case "$3" in @tmux-2html-title) printf 'My Pane';; @tmux-2html-lang) printf pt-BR;;
          @tmux-2html-visible-key) printf v;; @tmux-2html-full-key) printf O;; @tmux-2html-region-key) printf C-o;;
          @tmux-2html-open) printf on;; @tmux-2html-font) printf monospace;; @tmux-2html-history-limit) printf 50000;;
          *) printf '';; esac ;;
      bind-key) printf 'BK %s ' "$2" >> "$CAP"; shift 2; printf '%s\n' "$*" >> "$CAP";;
      display-popup) printf 'PP ' >> "$CAP"; shift; printf '%s\n' "$*" >> "$CAP";;
      display-message);; *) ;; esac }
  TMUX_PLUGIN_MANAGER_PATH="$PLUG" TMUX_2HTML_DEBUG="$W/dbg" . "$PLUG/tmux-2html/tmux-2html.tmux" )
grep -E 'pane --|region --' "$CAP"   # expect --title 'My Pane' --lang 'pt-BR' before --target in all 3
rm -rf "$W"
# (No real tmux was contacted — the `tmux()` function shadowed the binary. PRD §0 holds.)
```

## Final Validation Checklist

### Technical Validation

- [ ] `sh tests/plugin_options.sh` → `PASS`, exit 0 (Level 2 — primary gate).
- [ ] `zig build test -Doptimize=ReleaseFast` → exit 0 (Level 3 — regression guard).
- [ ] (If added) CI plugin job/step runs `sh tests/plugin_options.sh` green.

### Feature Validation

- [ ] `tmux-2html.tmux` §3 reads `@tmux-2html-title`/`@tmux-2html-lang` (empty default) + builds
      `title_arg`/`lang_arg`; §4 seam records all 4 vars.
- [ ] All 3 bindings (lines 139/145/184) interpolate `$title_arg $lang_arg` before `--target`.
- [ ] Defaults ⇒ no `--title`/`--lang` token in any bound command (assertion (a)).
- [ ] Set ⇒ `--title '<v>'`/`--lang '<v>'` present in all 3, before `--target` (assertion (b)).
- [ ] `docs/CONFIGURATION.md` has the 2 new rows + HTML-output note + threading clarification.

### Code Quality Validation

- [ ] Only `tmux-2html.tmux`, `docs/CONFIGURATION.md`, `tests/plugin_options.sh` (+ optional
      `ci.yml`) changed; NO `src/*.zig` touched.
- [ ] The fragment pattern mirrors the existing `$TMUX_2HTML_BIN` NOW-expansion (no new pattern).
- [ ] The harness is §0-safe (mock `tmux()`; no real socket; cleans its temp dir via `trap`).
- [ ] Line 162 (comment) untouched; exactly 3 binding sites edited.

### Documentation & Deployment

- [ ] CONFIGURATION.md count updated ("eight" → "ten"); 2 rows + note + clarification accurate.
- [ ] title/lang documented as THREADED (flags), NOT re-read (Gotcha 8 reflected).
- [ ] No new env vars (two new tmux user options only).

---

## Anti-Patterns to Avoid

- ❌ Don't expand `$title_arg`/`$lang_arg` at fire time — they MUST bake in NOW (inside the
  double-quoted bind-key string) because exported vars don't reach `run-shell` children
  (Gotcha 1). Single-quote the VALUE, not the variable.
- ❌ Don't drop the single quotes around `$title_opt` in the fragment — a spaced title would
  split into two argv at fire time (`My Pane` → `My` + `Pane`). Verified the quotes group it
  (Gotcha 2).
- ❌ Don't edit line 162 — it's a comment, not a binding. Exactly 3 sites: 139/145/184 (Gotcha 4).
- ❌ Don't spin up a real tmux server for THIS task's tests — the mock harness is deterministic,
  §0-safe, and sufficient (Gotcha 5). The isolated-tmux end-to-end smoke is P1.M1.T3.S1.
- ❌ Don't forget `display-popup`/`display-message` in the mock `tmux()` — the region binding and
  the palette auto-sync both call `display-popup`; without a handler, sourcing aborts (Gotcha 6).
- ❌ Don't add `@tmux-2html-title`/`@tmux-2html-lang` to the "binary re-reads via show-option"
  list in CONFIGURATION.md — they are THREADED as flags (Gotcha 8).
- ❌ Don't touch `src/*.zig` — S1 owns the flags, S2/S3/S4 own the wiring, golden_test.zig is the
  byte-invariant. This task is purely the plugin + docs + a shell test.
- ❌ Don't collapse the "extra spaces" when both options are empty — the bare `$title_arg $lang_arg`
  interpolation is the contract and is harmless (Gotcha 3; verified: no spurious tokens).
- ❌ Don't run plain `zig build test` (Debug) — it hits the `R_X86_64_PC64` linker bug. Use
  `-Doptimize=ReleaseFast` (Level 3).

---

**Confidence Score: 10/10** for one-pass implementation success.

Every edit is specified as exact BEFORE/AFTER text unique in its file; the new test file is given
verbatim and was run exit-0 against the live `tmux-2html.tmux` (baseline confirmed no title/lang
today; post-edit Cases A/B confirmed `--title 'My Pane' --lang 'pt-BR'` before `--target` in all
three bindings, and empty-fragment defaults produce zero spurious tokens). The non-obvious
quoting semantics — NOW-expansion of `$title_arg`/`$lang_arg` (exported vars don't reach
`run-shell` children) plus fire-time single-quote survival — were proven with an args-echo stub
(`'My Pane'` → one argv element). The "no existing harness" reality is confronted head-on: this
task creates `tests/plugin_options.sh` using the verified mock-`tmux` pattern, which is §0-safe
(no real socket) and CI-portable (pure POSIX sh). The DOCS edits are anchored to unique text and
include the critical threading-vs-re-read accuracy note. No `src/*.zig` is touched, so the golden
byte-invariant and the ReleaseFast suite are unaffected. The implementer is pasting verified
edits and running two commands.
