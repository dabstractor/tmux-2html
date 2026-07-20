#!/usr/bin/env bash
# check-safety.sh — deterministic static guard against the anti-patterns that
# caused the 2026-07-18 runaway-audit incident (recursive `tmux` PATH shim +
# unbounded calls.log).
#
# FAIL (exit non-zero) repo-wide on ACTUAL dangerous invocations:
#   R1  catastrophic tmux teardown:
#         - `killall tmux`, `pkill tmux`, `pkill -f …tmux`  (no safe form)
#         - bare `tmux kill-server` / `kill-server` NOT scoped to an isolated
#           `-L <socket>` (a scoped `tmux -L <iso> kill-server` is the PRD §0
#           sanctioned teardown variant, so it is allowed).
#   R2  recursive shim footgun: `exec tmux …` with a bare name instead of an
#       absolute path / variable (PRD §0.1).
# WARN (exit stays 0) everywhere EXCEPT scripts/ AND plan/ on:
#   R3  hand-rolled shim recipe (`PATH="…:$PATH"` + an `exec`/`>>` sink).
#   R4  unbounded audit-log append (`>> …calls.log`).
# (plan/ is human-authored PRP/research/tasks docs whose test-harness recipes are descriptions, not
#  live code. FAIL rules below STILL scan the entire repo; should_skip() drops structured
#  key-value prose like YAML/JSON "section: … exec tmux …" so docs that quote the patterns don't FAIL.)
#
# Precision: documentation is where a rule is *described*; code/snippets are
# where it is *obeyed*. So lines that are prose/comment/search-context are
# skipped: backticked spans, `#`/`//` comments, markdown list/quote/table
# leaders, and lines that are themselves grepping FOR the pattern.
#
# Usage:
#   scripts/check-safety.sh                 # whole-repo bounded scan
#   scripts/check-safety.sh --paths a b c   # scan only the listed files
# Exit: 0 if no FAIL, 1 on any FAIL, 2 usage error.
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"
paths=()
while [ $# -gt 0 ]; do
  case "$1" in
    --paths) shift; while [ $# -gt 0 ]; do paths+=("$1"); shift; done;;
    -h|--help) sed -n '2,28p' "$0"; exit 0;;
    *) echo "check-safety: unknown arg: $1 (see --help)" >&2; exit 2;;
  esac
done

is_text() { case "$(file -b --mime-type "$1" 2>/dev/null)" in text/*|*xml|*json|*javascript|*shellscript) return 0;; *) return 1;; esac; }
under_scripts() { case "$1" in "$ROOT/scripts/"*|"$ROOT/scripts") return 0;; *) return 1;; esac; }
# plan/ holds human-authored PRP/research/tasks docs that *describe* the safety patterns (e.g. a
# YAML "section: … bare exec tmux …"). WARN is suppressed there (documented harness recipes); FAIL
# still scans the whole repo — should_skip() drops the structured-prose FAIL matches (see below).
under_plan() { case "$1" in "$ROOT/plan/"*|"$ROOT/plan") return 0;; *) return 1;; esac; }

# Return 0 (skip) when a line is documentation/comment/search-context, not code.
# (Standalone test on one line — does NOT see surrounding context. Use is_doc_line()
# below for the context-aware per-file classification.)
should_skip() {
  local l="$1" s c
  case "$l" in *'`'*) return 0;; esac                       # backtick span => prose
  s="${l#"${l%%[![:space:]]*}"}"                             # left-trim
  c="${s:0:1}"
  case "$c" in '#'|'/') return 0;; esac                     # comment (# or //)
  case "$c" in '>') return 0;; '|'*) return 0;; esac        # md quote / pipe-led (invalid cmd)
  case "$c" in '-') [ "${s:1:1}" = ' ' ] && return 0;; '*' ) [ "${s:1:1}" = ' ' ] && return 0;; esac  # md list/bullet
  # the line is itself scanning for the pattern (grep/rg/awk/sed), not running it
  if printf '%s' "$l" | grep -qE '\b(grep|rg|ack|ag|awk|sed)\b'; then return 0; fi
  case "$s" in *:[[:space:]][\'\"]*) return 0;; esac   # structured key: "value" (YAML/JSON prose) => doc, not code
  return 1
}

# is_doc_line <line> : same heuristics as should_skip(), plus a soft-indent
# continuation rule — a line whose first non-space char is NOT a list bullet but which
# is indented relative to a preceding skipped doc line is treated as that line's wrapped
# continuation (inherits doc classification). This is what keeps wrapped markdown prose
# like "  ... NEVER kill-server ..." from tripping FAIL on the literal pattern name.
# (Context is supplied by the caller via _DOC_CTX: 1 = last non-blank line was doc.)
is_doc_line() {
  local l="$1" s c leading
  s="${l#"${l%%[![:space:]]*}"}"                             # left-trimmed
  # Continuation/wrapped line of a doc block: indented (leading whitespace) and not a
  # bullet itself, while the immediately preceding non-blank line was classified as doc.
  leading="${l%%[![:space:]]*}"
  if [ -n "$leading" ] && [ "${_DOC_CTX:-0}" = 1 ]; then
    c="${s:0:1}"
    case "$c" in
      '-') [ "${s:1:1}" = ' ' ] || return 0;;            # a new bullet is NOT a continuation
      '*' ) [ "${s:1:1}" = ' ' ] || return 0;;
      *) return 0;;                                     # indented wrapped prose => doc
    esac
  fi
  should_skip "$l"
}

# Compute the sorted list of line numbers that are documentation context for a file.
# Walks the file top-to-bottom tracking whether the previous non-blank line was doc, so
# wrapped continuations inherit classification. Lines inside a fenced code block
# (``` ... ```) are always doc. Output: one line-number per doc line.
doc_lines_of() {
  local f="$1" ln=0 in_fence=0 line trimmed
  _DOC_CTX=0
  while IFS= read -r line || [ -n "$line" ]; do
    ln=$((ln+1))
    # blank lines neither emit nor reset doc context (they just separate paragraphs)
    if [ -z "${line//[[:space:]]/}" ]; then continue; fi
    trimmed="${line#"${line%%[![:space:]]*}"}"
    # fenced code block toggle: a line whose first chars are ``` (or ~~~)
    case "$trimmed" in
      '```'*|'~~~'*)
        if [ "$in_fence" = 1 ]; then in_fence=0; else in_fence=1; fi
        printf '%s\n' "$ln"   # the fence line itself is doc
        _DOC_CTX=1
        continue
        ;;
    esac
    if [ "$in_fence" = 1 ]; then
      printf '%s\n' "$ln"     # content inside a code block is doc
      _DOC_CTX=1
      continue
    fi
    if is_doc_line "$line"; then
      printf '%s\n' "$ln"
      _DOC_CTX=1
    else
      _DOC_CTX=0
    fi
  done < "$f"
}

fails=0; warns=0
emit() { # sev rel line text
  printf '  [%s] %s:%s: %s\n' "$1" "$2" "$3" "$4"
  case "$1" in FAIL) fails=$((fails+1));; WARN) warns=$((warns+1));; esac
}

# scan_pat <sev> <pattern> <file> <rel> [mode]
# mode "killserver" => only FAIL when the line has no isolated `-L <sock>`.
# Doc classification uses the precomputed _DOCFILE (newline-separated line numbers).
scan_pat() {
  local sev="$1" pat="$2" f="$3" rel="$4" mode="${5:-}" line ln txt
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    ln="${line%%:*}"; txt="${line#*:}"
    is_doc_member "$ln" && continue
    if [ "$mode" = "killserver" ]; then
      case "$txt" in *-L*) continue;; esac    # scoped to an isolated socket => safe
    fi
    emit "$sev" "$rel" "$ln" "$txt"
  done < <(grep -InE "$pat" "$f" 2>/dev/null || true)
}

# is_doc_member <lineno> : 0 (doc) if <lineno> appears in the precomputed _DOCFILE set.
is_doc_member() {
  [ -n "${_DOCFILE:-}" ] || return 1
  grep -qxF "$1" "$_DOCFILE" 2>/dev/null
}

# R3 combo: a file that BOTH prepends to PATH and has an exec/>> sink.
shim_combo() {
  local f="$1" rel="$2" line ln txt
  grep -qE 'PATH="[^"]*:\$PATH"|PATH=[^:]*:\$PATH' "$f" 2>/dev/null || return 0
  grep -qE '\bexec[[:space:]]|>>' "$f" 2>/dev/null || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    ln="${line%%:*}"; txt="${line#*:}"
    is_doc_member "$ln" && continue
    emit WARN "$rel" "$ln" "PATH-prepend shim recipe (prefer scripts/with-tmux-audit.sh): $txt"
  done < <(grep -InE 'PATH="[^"]*:\$PATH"|PATH=[^:]*:\$PATH' "$f" 2>/dev/null || true)
}

R1_KILL='killall[[:space:]]+tmux|pkill[[:space:]]+tmux|pkill[[:space:]]+-f[[:space:]]+[^[:space:]]*tmux'
R2='exec[[:space:]]+tmux([[:space:]]|$|[[:punct:]])'
R4='>>[[:space:]]*[^[:space:]]*calls\.log'

collect_files() {
  if [ "${#paths[@]}" -gt 0 ]; then printf '%s\n' "${paths[@]}"; return; fi
  find "$ROOT" -xdev -type f -size -2M \
    -not -path "$ROOT/.git/*" -not -path "$ROOT/.zig-cache/*" \
    -not -path "$ROOT/zig-pkg/*"  -not -path "$ROOT/zig-out/*" \
    -not -path "$ROOT/.pi-subagents/*" -not -path "$ROOT/node_modules/*" \
    -not -path "$ROOT/scratch/*" -print 2>/dev/null
}

echo "== check-safety: scanning =="
while IFS= read -r f; do
  [ -f "$f" ] || continue
  is_text "$f" || continue
  [ "$(readlink -f "$f" 2>/dev/null || echo "$f")" = "$SELF" ] && continue   # don't scan self
  rel="${f#$ROOT/}"
  _DOCFILE="$(mktemp)"
  doc_lines_of "$f" > "$_DOCFILE" 2>/dev/null || true
  scan_pat FAIL "$R1_KILL"   "$f" "$rel"
  scan_pat FAIL 'kill-server' "$f" "$rel" killserver
  scan_pat FAIL "$R2"        "$f" "$rel"
  if ! under_scripts "$f" && ! under_plan "$f"; then
    shim_combo "$f" "$rel"
    scan_pat WARN "$R4"      "$f" "$rel"
  fi
  rm -f "$_DOCFILE"; unset _DOCFILE
done < <(collect_files)

echo
echo "== result: ${fails} FAIL(s), ${warns} WARN(s) =="
if [ "$fails" -gt 0 ]; then
  echo "check-safety: FAILED — fix the violations above (see AGENTS.md §1)." >&2
  exit 1
fi
exit 0