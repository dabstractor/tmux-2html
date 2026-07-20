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

# (c) Apostrophe in @tmux-2html-title MUST be POSIX shell-escaped, else the
# naive single-quote wrap unbalances /bin/sh parsing of the run-shell command
# and the binding silently no-ops (Issue 1). lang EMPTY here so the buggy form
# has an ODD single-quote count (=> /bin/sh -n reliably catches it; see GOTCHA 1).
run_loader "Bob's pane" "" "v"
# (c.1) PRIMARY detector (reliable for all 3 bindings — they share title_arg):
#       the debug seam must show the POSIX-escaped form, not the naive wrap.
grep -qF "title_arg=--title 'Bob'\''s pane'" "$DBG" || fail "c: title not shell-escaped (debug seam)"
grep -qx 'lang_arg=' "$DBG" || fail "c: lang_arg should be empty"
# (c.2) END-TO-END: O/full + visible captured commands parse under /bin/sh -n.
for sub in 'pane --full' 'pane --visible'; do
    cmd=$(printf '%s' "$CAPTURE" | grep -F -- "$sub" | head -1 | sed 's/^BK [^ ]* run-shell //')
    [ -n "$cmd" ] || fail "c: no '$sub' binding captured"
    /bin/sh -n -c "$cmd" 2>/dev/null || fail "c: '$sub' command fails /bin/sh -n (apostrophe not escaped)"
done
# (c.3) REGION has a nested quoting layer (GOTCHA 2): the bug hides inside the
# double-quoted display-popup arg at the run-shell level, so /bin/sh -n the
# INNER popup command that display-popup re-runs at fire time.
rline=$(printf '%s' "$CAPTURE" | grep -F 'region' | head -1)
[ -n "$rline" ] || fail "c: no region binding captured"
rinner=$(printf '%s' "$rline" | sed 's/.*display-popup [^"]*"//; s/"; if.*//')
/bin/sh -n -c "$rinner" 2>/dev/null || fail "c: region inner popup command fails /bin/sh -n"
#
# (c2) Apostrophe in @tmux-2html-lang (defense-in-depth; BCP-47-normalized in
#      practice so this is unlikely, but the same escaping applies). title EMPTY.
run_loader "" "it's" "v"
grep -qF "lang_arg=--lang 'it'\''s'" "$DBG" || fail "c2: lang not shell-escaped (debug seam)"
grep -qx 'title_arg=' "$DBG" || fail "c2: title_arg should be empty"

echo "PASS: @tmux-2html-title/@tmux-2html-lang thread into all bindings (defaults empty; set ⇒ flags before --target)"
