# Research Findings — P1.M1.T2.S1 (Plugin options @tmux-2html-title/@tmux-2html-lang → bindings)

> Verified hands-on 2026-07-10 against the LIVE `tmux-2html.tmux` (commit at HEAD of repo).
> The mock-tmux sourcing harness + the contract's edits were built and asserted end-to-end in
> throwaway dirs (`/tmp/t2h-plugin-verify.*`, `/tmp/t2h-plugin-edit.*`); fire-time `/bin/sh`
> arg parsing was proven with an args-echo stub.

## 1. The deliverable in one paragraph

Thread two new tmux user options (`@tmux-2html-title`, `@tmux-2html-lang`) through the existing
`tmux-2html.tmux` loader into its three prefix-table bindings, so a user's
`set -g @tmux-2html-title 'My Pane'` / `set -g @tmux-2html-lang pt-BR` reaches the binary as
`--title`/`--lang` on every capture path. Empty option ⇒ empty fragment ⇒ binary default
(no behavior change). Plus a mocked-tmux test harness (none exists today) and a CONFIGURATION.md
update. The binary already accepts `--title`/`--lang` (S1 Complete); S4 (parallel) wires
pane/region to honor them. **This task is purely the tmux-plugin side.**

## 2. Current `tmux-2html.tmux` shape (verified — the file to EDIT)

POSIX-sh loader, sourced by TPM. Sections:
- **§1** plugin-dir + `TMUX_2HTML_BIN` resolution (env → @tmux-2html-binary-dir → `$plugin_dir/bin`).
- **§2** binary acquisition (`[ -x "$TMUX_2HTML_BIN/tmux-2html" ]` ⇒ `binary_ready=1`; else runs `ensure_binary.sh`).
- **§3** `read_opt()` helper + **8 options** (`full_key, region_key, visible_key, open, font,
  history_limit, output_dir, binary_dir`), then `export full_key region_key … binary_dir`.
  ← **ADD `title_opt`/`lang_opt` + `title_arg`/`lang_arg` HERE, after that export line.**
- **§4** `TMUX_2HTML_DEBUG` seam (writes option values with `>`; "makes integration tests
  assertable"). ← **APPEND the 4 new vars to this `>` block.**
- **Bindings**: `O` (full) line **139**, `visible` (if set) line **145**, `C-o` region popup
  line **184**. Each has exactly one `--target '#{pane_id}'`. ← **Interpolate `$title_arg $lang_arg`
  before `--target` in all three.** (Line 162 is a COMMENT, not a binding.)
- Palette auto-sync popup at the end (calls `tmux display-popup` — mock must no-op it).

The three binding inner-strings (unique, exact):
```
pane --full --target '#{pane_id}'        # line 139 (O)
pane --visible --target '#{pane_id}'     # line 145 (visible)
region --target '#{pane_id}'             # line 184 (C-o popup)
```

## 3. The contract's edit pattern (VERIFIED — mirrors the `$TMUX_2HTML_BIN` interpolation)

`$TMUX_2HTML_BIN` is expanded NOW (at loader-source time) into the bind-key string because
exported vars do NOT reach `run-shell` children. `title_opt`/`lang_opt` are the same kind of
value ⇒ build NOW-expanded optional fragments:

```sh
title_opt=$(read_opt @tmux-2html-title "")
lang_opt=$(read_opt @tmux-2html-lang "")
title_arg=""
[ -n "$title_opt" ] && title_arg="--title '$title_opt'"
lang_arg=""
[ -n "$lang_opt" ] && lang_arg="--lang '$lang_opt'"
export title_opt lang_opt title_arg lang_arg
```
Then in each binding: `pane --full $title_arg $lang_arg --target '#{pane_id}'` (etc.).
- Empty option ⇒ fragment is `""` ⇒ string becomes `pane --full   --target …` (extra spaces,
  harmless — verified: binary receives `pane --full --target %5`, no spurious tokens).
- Single quotes around `$title_opt` survive run-shell's `/bin/sh` re-parse at FIRE time so a
  value with spaces stays one argv element (verified: `My Pane` → `argv[4]=<My Pane>`).

## 4. Empirical verification — exit-clean, all assertions pass

### 4a. Mock-tmux sourcing harness (NO real tmux needed — PRD §0 safe)
A shell `tmux()` function overrides the binary. `show-option -gqv @X` returns seeded values;
`bind-key`/`display-popup` append their command string to a capture file; `display-message`
no-ops. Set `TMUX_PLUGIN_MANAGER_PATH` + a fake executable binary (⇒ `binary_ready=1` ⇒ bindings
fire) + `TMUX_2HTML_DEBUG`, then `. tmux-2html.tmux`.

**Baseline (current file, no title/lang):** both unset and "would-be-set" cases produce
IDENTICAL bound commands with ZERO `--title`/`--lang`. ✓ (proves today's behavior; the test's
"defaults ⇒ none" assertion already holds pre-edit for title/lang, and the harness runs.)

**Post-edit (contract applied to a copy):**
- Case A — defaults (unset): `grep -c -- '--title|--lang' capture` → **0**; debug seam shows
  `title_opt=` / `lang_opt=` / `title_arg=` / `lang_arg=` (all empty). ✓
- Case B — set (`title='My Pane'`, `lang='pt-BR'`, `visible='v'`): ALL THREE bound commands
  contain `--title 'My Pane' --lang 'pt-BR'` BEFORE `--target '#{pane_id}'`:
  ```
  O      → pane --full    --title 'My Pane' --lang 'pt-BR' --target '#{pane_id}'
  v      → pane --visible --title 'My Pane' --lang 'pt-BR' --target '#{pane_id}'
  C-o    → … region       --title 'My Pane' --lang 'pt-BR' --target '#{pane_id}'   (inside display-popup)
  ```
  debug seam: `title_arg=--title 'My Pane'`, `lang_arg=--lang 'pt-BR'`. ✓

### 4b. Fire-time `/bin/sh` arg parsing (single-quote survival) — PROVEN with args-echo stub
Simulating the exact run-shell command string (after tmux expands `#{pane_id}`→`%5`):
```
set   → argv: pane | --full | --title | My Pane | --lang | pt-BR | --target | %5   (8 argv, 'My Pane' = ONE)
unset → argv: pane | --full | --target | %5                                        (4 argv, no spurious tokens)
```

## 5. There is NO existing plugin test harness

Searched the whole repo (excluding `zig-pkg/`): no `*.bats`, no `tests/` dir, no shell test
sourcing `tmux-2html.tmux`. The only tests are `src/golden_test.zig` (Zig) + `testdata/`.
CI (`.github/workflows/ci.yml`) runs ONLY `zig build test -Doptimize=ReleaseFast`.

The contract says "extend the existing plugin test harness" — but the §4 `TMUX_2HTML_DEBUG`
seam was explicitly designed ("makes integration tests assertable") FOR exactly this kind of
mocked-tmux test. **⇒ This task CREATES the harness** (`tests/plugin_options.sh`) using the
verified mock pattern in §4. It needs NO tmux binary (pure POSIX sh), so it is §0-safe and
CI-portable. The proven harness template is in §7 below.

## 6. DOCS deliverable — `docs/CONFIGURATION.md`

Current "Options" table has the same 8 rows as PRD §9.2 (no title/lang). The "Overview" says
"the **eight** `@tmux-2html-*`". Edits:
- Update "eight" → "ten" in the Overview bullet.
- Add 2 rows to the Options table:
  - `@tmux-2html-title` | *(empty)* | Document `<title>`. Empty ⇒ contextual default
    (`tmux-2html — <session>/<pane> <iso8601>` for pane/region; `tmux-2html` for render).
  - `@tmux-2html-lang` | *(empty)* | `<html lang>` (BCP-47). Empty ⇒ locale-derived, fallback `en`.
- Add a short "HTML output (§8.1)" subsection/note: every capture is a COMPLETE HTML5 document
  (`<!DOCTYPE html>`→`</html>`); `<title>`/`lang` come from these two knobs.
- IMPORTANT accuracy note: unlike `font`/`output-dir`/`open`/`history-limit` (which the binary
  RE-READS via `show-option`), `title`/`lang` are THREADED by the plugin as `--title`/`--lang`
  flags (this task). Do NOT add them to the "re-read themselves" list — that would be wrong.

## 7. The proven harness template (for the PRP's verbatim test file)

```sh
#!/bin/sh
# tests/plugin_options.sh — mocked-tmux plugin option test (PRD §0: never touches real tmux).
# Sources tmux-2html.tmux with a `tmux()` override; asserts @tmux-2html-title/@tmux-2html-lang
# thread into all prefix-table bindings. Pure POSIX sh — needs NO tmux binary.
set -u
fail() { echo "FAIL: $*" >&2; exit 1; }
W=$(mktemp -d "${TMPDIR:-/tmp}/t2h-plugin.XXXXXX"); trap 'rm -rf "$W"' EXIT
PLUG="$W/plugins"; mkdir -p "$PLUG/tmux-2html/bin"
REPO=$(cd "$(dirname "$0")/.." && pwd)
cp "$REPO/tmux-2html.tmux" "$PLUG/tmux-2html/tmux-2html.tmux"
printf '#!/bin/sh\nexit 0\n' > "$PLUG/tmux-2html/bin/tmux-2html"; chmod +x "$PLUG/tmux-2html/bin/tmux-2html"

run_loader() {  # $1=title $2=lang $3=visible  → sets $CAPTURE + $DBG
  CAP="$W/cap.txt"; : > "$CAP"; DBG="$W/debug.txt"; : > "$DBG"
  _T="$1"; _L="$2"; _V="$3"
  ( tmux() {
      case "$1" in
        show-option) case "$3" in
            @tmux-2html-title) printf '%s' "$_T" ;; @tmux-2html-lang) printf '%s' "$_L" ;;
            @tmux-2html-visible-key) printf '%s' "$_V" ;; @tmux-2html-full-key) printf O ;;
            @tmux-2html-region-key) printf 'C-o' ;; @tmux-2html-open) printf on ;;
            @tmux-2html-font) printf monospace ;; @tmux-2html-history-limit) printf 50000 ;;
            @tmux-2html-output-dir|@tmux-2html-binary-dir) printf '' ;; *) printf '' ;;
          esac ;;
        bind-key) printf 'BK %s ' "$2" >> "$CAP"; shift 2; printf '%s\n' "$*" >> "$CAP" ;;
        display-popup) printf 'PP ' >> "$CAP"; shift; printf '%s\n' "$*" >> "$CAP" ;;
        display-message) : ;; *) : ;;
      esac
    }
    export TMUX_PLUGIN_MANAGER_PATH="$PLUG" TMUX_2HTML_DEBUG="$DBG" _T _L _V
    . "$PLUG/tmux-2html/tmux-2html.tmux" )
  CAPTURE=$(cat "$CAP")
}

# (a) defaults ⇒ NO --title/--lang anywhere; debug seam fragments empty
run_loader "" "" "v"
printf '%s' "$CAPTURE" | grep -E -- '--title|--lang' && fail "defaults: --title/--lang present"
grep -q '^title_arg=$' "$DBG" || fail "defaults: title_arg not empty"
grep -q '^lang_arg=$'  "$DBG" || fail "defaults: lang_arg not empty"

# (b) set ⇒ --title/--lang present in all 3, BEFORE --target
run_loader "My Pane" "pt-BR" "v"
for sub in 'pane --full' 'pane --visible' 'region'; do
  line=$(printf '%s' "$CAPTURE" | grep -E "$sub" | head -1)
  [ -n "$line" ] || fail "set: no bound cmd for '$sub'"
  pre=$(printf '%s' "$line" | sed 's/--target.*//')
  printf '%s' "$pre" | grep -qF -- "--title 'My Pane'" || fail "set: '$sub' --title missing/before-target"
  printf '%s' "$pre" | grep -qF -- "--lang 'pt-BR'"     || fail "set: '$sub' --lang missing/before-target"
done
grep -q "^title_arg=--title 'My Pane'" "$DBG" || fail "set: debug title_arg"
grep -q "^lang_arg=--lang 'pt-BR'"     "$DBG" || fail "set: debug lang_arg"
echo "PASS: @tmux-2html-title/@tmux-2html-lang thread into all bindings"
```

## 8. Scope & safety boundaries

- **EDIT only** `tmux-2html.tmux` (options block + 3 bindings + §4 seam) and `docs/CONFIGURATION.md`.
- **CREATE** `tests/plugin_options.sh` (new file; new `tests/` dir).
- **DO NOT touch** any `src/*.zig` (S1 owns flags, S2/S3/S4 own render/pane/region wiring,
  golden_test.zig is the byte-invariant). **DO NOT touch** the user's running tmux (§0) — the
  harness uses a mock, never a real socket.
- CI wiring of the new shell test is OPTIONAL (one extra step in ci.yml); include it only if it
  does not expand scope — the test is pure sh and deterministic, so it is a trivial, safe add.
