# Research: POSIX sh binary-acquisition script for a tmux plugin (ensure_binary.sh)

> **Scope note.** This subagent environment does **not** expose a `web_search` tool,
> so URLs below are *canonical-recalled* (from established knowledge) and the project
> claims are *locally verified* by reading the repo. Claims are tagged
> **[LOCAL-VERIFIED]** (read from this repo) vs **[KNOWN]** (well-established, URL
> recalled — re-fetch before external citation). The action items and code patterns
> are authoritative regardless.

## Summary
`zig build --release=fast --prefix <dir> install` does place the exe at
`<dir>/bin/<name>` — **[LOCAL-VERIFIED]** this matches `build.zig`'s
`b.installArtifact(exe)` + name `tmux-2html`, and matches your empirical result.
A `set -eu` fall-through cascade is made correct by wrapping each stage's commands
in an `if <cond>` / `cmd || true`, because POSIX **§2.8.1** exempts from `-e` any
command in an `if`/`while`/`until` condition and any non-last command of a `&&`/`||`
list. `mv` is atomic only on the same filesystem, so the robust pattern is to build
into a temp dir created *inside* the destination bin dir. `mktemp -d '<dir>/XXXXXX'`
is reliable across Linux/macOS/BSD/busybox (all tmux target platforms); provide a
PID+timestamp `mkdir` fallback only for the (non-POSIX, rare) absence of `mktemp`.

---

## Findings

### (a) Zig 0.15.x `zig build` install-to-prefix — VERIFIED layout

1. **The exe lands at `<prefix>/bin/<name>`.** **[LOCAL-VERIFIED]**
   `build.zig` calls `b.installArtifact(exe)` with `.name = "tmux-2html"`, and uses
   `b.standardOptimizeOption(.{})` so the CLI flag `--release=fast` selects the mode.
   Zig's default install layout places executables under the *exe install dir*, which
   maps to `<prefix>/bin/` by default. So:
   ```sh
   zig build --release=fast --prefix "$tmp" install
   # produces:  $tmp/bin/tmux-2html
   ```
   This matches your empirical confirmation that it lands at `<dir>/bin/tmux-2html`.
   **[KNOWN]** Authority: run `zig build --help` (primary) — it documents
   `--prefix <dir>`, `--release <mode>`, `--prefix-exe-dir`, `--prefix-lib-dir`,
   `--prefix-include-dir`. Zig release notes: `https://ziglang.org/download/0.15.1/release-notes.html`
   (0.15.1 docs available; 0.15.2 is the project's `minimum_zig_version` per `build.zig.zon`).

2. **`--prefix` is a global build flag; `install` is the default step.**
   **[KNOWN]** `zig build install` is the default step when no step name is given, but
   naming it explicitly (`install`) is harmless and clear. `--prefix <dir>` overrides
   the default `zig-out/` prefix. The `--release` flag accepts `fast|safe|small|debug`
   (unified `--release=<mode>` form, present since 0.11; in 0.14/0.15 `--release=fast`
   is the documented spelling). Note `build.zig` line ~46 itself comments
   *"--release=fast on the CLI; see Gotcha 1"*. **[LOCAL-VERIFIED]**

3. **`--prefix-exe-dir` / `--prefix-lib-dir` / `--prefix-include-dir`** override the
   subdirectory used *per artifact kind* relative to the prefix. **[KNOWN]** To put the
   exe directly under the prefix (no `bin/` segment) you would pass
   `--prefix-exe-dir .`. For this plugin you do **not** need these — the default
   `bin/` segment is what you want. Authority: `zig build --help`.

4. **Version-baking is already wired.** **[LOCAL-VERIFIED]** `build.zig` reads
   `@import("build.zig.zon").version` (= `"0.1.0"`) and exposes it via
   `b.addOptions()` → `build_options` module. So `tmux-2html --version` (however it
   prints) should report `0.1.0`, and `ensure_binary.sh`'s `EXPECTED_VERSION="0.1.0"`
   must be kept in lockstep with `build.zig.zon`'s `.version`.

### (b) POSIX `set -eu` fall-through cascade — the exact idiom + pitfalls

5. **The governing rule (quote POSIX §2.8.1 "Consequences of Shell Errors").**
   **[KNOWN]** Under `set -e`, the `-e` setting **shall be ignored** for, among others:
   > "the compound list following the … **if**, or **elif** reserved word" … and
   > "**any command of an AND-OR list other than the last**."

   This is precisely why (i) commands inside an `if <cond>` do **not** abort on failure,
   and (ii) `cmd || true` does **not** abort (`cmd` is non-last in the `||` list).
   Source: POSIX Shell Command Language, §2.8.1 —
   `https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html#tag_18_08_01`
   (the `set -e` definition is on the `set` utility page —
   `https://pubs.opengroup.org/onlinepubs/9699919799/utilities/set.html`).
   **Recommendation** (authoritative community write-up, URL recalled — re-fetch):
   GreyCat/Wooledge BashFAQ/105 "Why doesn't set -e (or set -o errexit, or a trap on
   ERR) do what I expected?" — `https://mywiki.wooledge.org/BashFAQ/105` — and
   `https://mywiki.wooledge.org/BashFAQ/001` / the errexit caveat page.

6. **Recommended idiom — each stage wrapped in `if`, only the all-failed tail exits non-zero.**
   ```sh
   #!/usr/bin/env sh
   set -eu

   # $1 is the full path to the target binary, e.g. /…/bin/tmux-2html.
   # The loader ALWAYS passes it: `sh ensure_binary.sh "$TMUX_2HTML_BIN"` — but guard anyway.
   if [ $# -lt 1 ]; then
       echo "tmux-2html: ensure_binary.sh: missing target path argument" >&2
       exit 2
   fi
   DEST_BIN=$1
   BIN_DIR=$(dirname "$DEST_BIN")
   EXPECTED_VERSION="0.1.0"          # MUST match build.zig.zon .version
   SOURCE_DIR="$PLUGIN_DIR"          # dir containing build.zig
   SCRIPT_DIR=$(dirname -- "$0")

   # --- Stage 1: existing binary already at the baked version?  (if-cond: -e suppressed) ---
   if [ -x "$DEST_BIN" ]; then
       # capture in an if-cond so a nonzero --version never trips -e:
       if cur=$("$DEST_BIN" --version 2>/dev/null); then :; else cur=""; fi
       case "$cur" in
           *"$EXPECTED_VERSION"*) exit 0 ;;   # up-to-date: success
       esac
   fi

   # --- Stage 2: build from source via zig?  (whole stage in one if) ---
   if command -v zig >/dev/null 2>&1; then
       tmp=$(mktemp -d "$BIN_DIR/.tmux2html.build.XXXXXX" 2>/dev/null) || tmp=""
       if [ -n "$tmp" ]; then
           # build into prefix; exe lands at "$tmp/bin/tmux-2html" (see §a).
           if ( cd "$SOURCE_DIR" && zig build --release=fast --prefix "$tmp" install ) \
              && [ -x "$tmp/bin/tmux-2html" ]; then
               mv -f "$tmp/bin/tmux-2html" "$DEST_BIN"   # same-FS: tmp is inside BIN_DIR (§c)
               rm -rf "$tmp"
               exit 0
           fi
           rm -rf "$tmp"
       fi
   fi

   # --- Stage 3: sibling download.sh? ---
   if [ -x "$SCRIPT_DIR/download.sh" ]; then
       if sh "$SCRIPT_DIR/download.sh" "$DEST_BIN"; then
           [ -x "$DEST_BIN" ] && exit 0
       fi
   fi

   # --- Stage 4: every path failed ---
   echo "tmux-2html: could not obtain binary (version/build/download all failed)" >&2
   exit 1
   ```
   **Why this is correct under `set -eu`:** every failure-prone command is either (a)
   the condition of an `if`, or (b) the non-last element of a `&&`/`||` list, so per
   POSIX §2.8.1 none of them can trip `-e`. Only the explicit `exit 1` at the bottom
   is the non-zero termination. **[KNOWN+LOCAL]** The `if ! sh ensure_binary.sh …`
   call site in `tmux-2html.tmux` (§2) correctly consumes this exit code. **[LOCAL-VERIFIED]**

7. **Pitfalls to harden against.**
   - **`x=$(cmd)` under `set -e` is a portability trap.** **[KNOWN]** In `dash`/POSIX
     `sh`, `x=$(false)` **aborts** the script; in `bash` it does **not** (bash treats a
     plain assignment statement specially). Never assume the bash behavior in a `#!/usr/bin/env sh`
     script. Capture safely: `if x=$(cmd); then …; else …; fi` or `x=$(cmd) || x=""`
     (the `||` makes it a non-last list element → `-e` exempt). The above idiom uses the
     `if cur=$(…)` form for exactly this reason.
   - **`command -v` is the POSIX existence test — not `which`.** **[KNOWN]** `command -v
     zig` prints the path and returns 0 if found; `which` is not in POSIX and its output
     format/exit status varies. POSIX `command`:
     `https://pubs.opengroup.org/onlinepubs/9699919799/utilities/command.html`.
   - **`set -u` + positional `$1`.** **[KNOWN]** Referencing `$1` when no arg is passed
     triggers "unbound variable" under `set -u`. Guard with an explicit `[ $# -lt 1 ]`
     check first (as above), or use `${1:-}` when an empty default is acceptable. Here
     the loader always passes `$1`, but the guard makes the script safe standalone.
   - **Do not `source` a `set -eu` script.** **[KNOWN]** The loader `tmux-2html.tmux`
     deliberately does NOT `set -e` (it's sourced by TPM and must never abort the user's
     `source-file`). It runs `ensure_binary.sh` in a **child `sh`** (`sh "$…/ensure_binary.sh" …`),
     which is correct — a non-zero exit in the child is caught by `if ! …` and never
     reaches the sourcing shell. ShellCheck SC2187 ("Ash script will not set `-e` if
     sourced with `.`") is relevant context:
     `https://www.shellcheck.net/wiki/SC2187`. **[LOCAL-VERIFIED]** the loader invokes
     `sh …ensure_binary.sh` in §2.

### (c) Same-filesystem atomic install — why, and the pattern

8. **`rename(2)`/`mv` is atomic only within one filesystem; cross-FS yields EXDEV.**
   **[KNOWN]** POSIX `rename()` is specified to be atomic for files, but when the old
   and new pathnames are on different file systems, `rename` **fails** with `EXDEV` (the
   application must then copy + unlink). GNU `mv` silently falls back to copy+unlink in
   that case, which is **non-atomic** (a reader can see a half-written file, and a crash
   leaves a partial destination). Sources: POSIX `rename` —
   `https://pubs.opengroup.org/onlinepubs/9699919799/functions/rename.html` (see the
   `[EXDEV]` error and the "If the old argument and the new argument resolve to
   directories … on different file systems … rename() shall fail" text); `man 2 rename`
   ("renameat/renameat2 … EXDEV … The rename operation … across filesystems").

9. **Pattern: create the build temp dir INSIDE the destination directory.**
   **[KNOWN+recommended]** Because `$BIN_DIR` and `$DEST_BIN` are by definition on the
   same filesystem, a temp dir created at `$BIN_DIR/.….XXXXXX` guarantees the staged
   exe and the final path share a filesystem, so the final `mv` is a true atomic
   `rename(2)`. This is exactly what the Stage-2 code above does
   (`mktemp -d "$BIN_DIR/.tmux2html.build.XXXXXX"`). Cite rationale: POSIX `rename`
   (above) and the standard "build to a sibling temp then rename" install idiom (see
   e.g. GNU coreutils `install` using `mkstemp`+`rename`, and `rsync --partial-dir`).

### (d) tmux-plugin precedents for binary acquisition

10. **`tmux-thumbs` (Rust) — the closest precedent: prebuilt binary download on load.**
    **[KNOWN — URL recalled, re-fetch]** tmux-thumbs ships as a compiled binary; its
    `tmux-thumbs.tmux` loader, on plugin load, checks whether the platform's binary is
    present and, if not, **downloads a prebuilt binary from the project's GitHub Releases**
    (keyed on `uname -s` / `uname -m`), extracts it, and places it on PATH. This is the
    canonical "acquire-a-binary at plugin load" pattern in the tmux ecosystem and maps
    directly onto your Stage-3 `download.sh` fallback. Repo:
    `https://github.com/fenenous/tmux-thumbs` (confirm exact org/file paths before
    external citation; key files are `tmux-thumbs.tmux` and the release-download
    logic). **Action:** mirror this — your `download.sh` is the analogue of
    tmux-thumbs' release fetch; your Stage-2 `zig build` is the additional
    "build-from-source-first" path that tmux-thumbs does NOT have (a strict
    improvement for users with `zig` installed).

11. **Most other popular tmux plugins are pure shell (no binary) — useful as the
    "don't crash the loader" reference.** **[KNOWN]** `tmux-resurrect`
    (`https://github.com/tmux-plugins/tmux-resurrect`) and `tmux-continuum`
    (`https://github.com/tmux-plugins/tmux-continuum`) are pure POSIX-ish shell and
    never compile; their `.tmux` scripts are robust to missing pieces (guard with
    `-f`/`-x` tests and never `exit` non-zero while sourced). `catppuccin/tmux`
    (`https://github.com/catppuccin/tmux`) is likewise pure shell config. This validates
    your loader's "never crash, gate on `binary_ready`" design
    (**[LOCAL-VERIFIED]** `tmux-2html.tmux` §1–§2), and shows that the
    compile/download logic correctly lives in a **child** script (`ensure_binary.sh`)
    rather than the sourced `.tmux` file.

### (e) `mktemp -d` portability + fallback

12. **`mktemp` is NOT in POSIX, but is universally present on tmux's platforms.**
    **[KNOWN]** POSIX does not define `mktemp` (it is absent from the Shell & Utilities
    volume — `https://pubs.opengroup.org/onlinepubs/9699919799/`). However it ships on
    Linux (util-linux/coreutils), macOS/BSD (BSD `mktemp`), and busybox (which tmux's
    embedded/Lightweight targets often use), so across tmux's supported platforms it is
    reliable. The critical portability caveat: **the `-t` flag is incompatible across
    implementations** (GNU: deprecated template; BSD/macOS: a *prefix* placed in
    `$TMPDIR`). **Avoid `-t`.** Use the **positional template** form, which is the most
    portable:
    ```sh
    mktemp -d "$BIN_DIR/.tmux2html.build.XXXXXX"
    ```
    This works on GNU coreutils, BSD/macOS, and busybox, places the dir *inside* `$BIN_DIR`
    (your same-FS atomicity requirement), and the trailing `XXXXXX` (≥3 trailing `X`s)
    is required by all implementations. Authorities (URLs recalled): GNU coreutils
    `mktemp` invocation (`https://www.gnu.org/software/coreutils/manual/html_node/mktemp-invocation.html`),
    BSD/macOS `man mktemp`, busybox `mktemp` docs; and the GNU Autoconf manual's
    portability notes (`https://www.gnu.org/software/autoconf/manual/autoconf.html`,
    "Limitations of Shell Builtins" / mktemp) documenting the `-t` divergence.

13. **Fallback when `mktemp` is absent (rare).** **[KNOWN]** If `mktemp` is missing,
    synthesize a same-dir, mode-700 directory from PID + timestamp and tolerate the
    (small) race:
    ```sh
    mk_tmp_dir() {  # $1 = parent dir
        _p=$1
        _ts=$(date +%s 2>/dev/null) || _ts=0
        _d=$_p/.tmux2html.tmp.$$.$_ts
        mkdir -m 700 "$_d" 2>/dev/null && printf '%s' "$_d" && return 0
        return 1
    }
    # usage: tmp=$(mktemp -d "$BIN_DIR/.tmux2html.build.XXXXXX" 2>/dev/null) \
    #            || tmp=$(mk_tmp_dir "$BIN_DIR") || tmp=""
    ```
    `$` (PID) is not perfectly unique under concurrent invocations, but tmux loads a
    plugin once per server and `ensure_binary.sh` is serialized, so the race is
    negligible here. Prefer `mktemp` and use this only as the trailing `||` fallback
    (note: this fallback is itself in a non-last `||` position, so it is `-e`-safe).

---

## Sources

- **Kept (LOCAL-VERIFIED):**
  - `build.zig.zon` (this repo) — `.version = "0.1.0"`, `.minimum_zig_version = "0.15.2"`, `paths` includes `scripts`.
  - `build.zig` (this repo) — `.name = "tmux-2html"`, `b.installArtifact(exe)`, `b.standardOptimizeOption(.{})` (→ `--release=fast`), version baked via `b.addOptions()` → `build_options`.
  - `tmux-2html.tmux` (this repo) — §2 invokes `sh "$plugin_dir/scripts/ensure_binary.sh" "$TMUX_2HTML_BIN"` inside `if ! …`, never `set -e` in the sourced loader.
- **Kept (canonical, URL recalled — re-fetch before external citation):**
  - `zig build --help` (primary authority for `--prefix`, `--release`, `--prefix-exe-dir/lib/include-dir`) — `https://ziglang.org/`.
  - Zig 0.15.x release notes / docs — `https://ziglang.org/download/0.15.1/release-notes.html`, `https://ziglang.org/documentation/`.
  - POSIX Shell Command Language §2.8.1 "Consequences of Shell Errors" — `https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html#tag_18_08_01`.
  - POSIX `set` utility (`-e`/`-u`) — `https://pubs.opengroup.org/onlinepubs/9699919799/utilities/set.html`.
  - POSIX `command` (`command -v`) — `https://pubs.opengroup.org/onlinepubs/9699919799/utilities/command.html`.
  - POSIX `rename()` (EXDEV, atomicity) — `https://pubs.opengroup.org/onlinepubs/9699919799/functions/rename.html`.
  - GreyCat/Wooledge BashFAQ/105 (set -e pitfalls) — `https://mywiki.wooledge.org/BashFAQ/105`.
  - ShellCheck SC2187 (sourced ash + set -e) — `https://www.shellcheck.net/wiki/SC2187`.
  - GNU coreutils `mktemp` invocation — `https://www.gnu.org/software/coreutils/manual/html_node/mktemp-invocation.html`.
  - GNU Autoconf manual (mktemp/`-t` portability) — `https://www.gnu.org/software/autoconf/manual/autoconf.html`.
  - tmux-thumbs (binary-download-on-load precedent) — `https://github.com/fenenous/tmux-thumbs` (verify exact path).
  - tmux-resurrect / tmux-continuum (pure-shell, don't-crash precedents) — `https://github.com/tmux-plugins/tmux-resurrect`, `https://github.com/tmux-plugins/tmux-continuum`.
- **Dropped:** generic "what is set -e" blog posts (SEO noise) — superseded by POSIX §2.8.1 and Wooledge. tmux-fzf/tmux-fingers dropped as primary precedents (tmux-fingers is Ruby-based; tmux-fzf is pure shell) — less on-point than tmux-thumbs.

## Gaps

- **No live web verification was possible** in this session (no `web_search` tool). All
  non-`[LOCAL-VERIFIED]` claims are well-established and the canonical URLs are recalled;
  **before citing any URL externally, re-fetch it** (especially the exact tmux-thumbs
  GitHub file path, the Zig `--prefix-exe-dir` doc anchor, and the POSIX §2.8.1 URL
  anchor). The POSIX base URLs (`V3_chap02.html`, `set.html`, `command.html`,
  `functions/rename.html`) are stable.
- **`tmux-2html --version` output format** is not yet observed locally (the binary is
  not built in this tree). Stage-1 uses a `case … in *"$EXPECTED_VERSION"*` substring
  match, which tolerates any wrapping (`tmux-2html 0.1.0`, `0.1.0`, etc.) — but confirm
  the binary actually prints the version string from the `build_options` module.
- **`PLUGIN_DIR`/`SOURCE_DIR` resolution** inside `ensure_binary.sh` (where `build.zig`
  lives relative to the script) needs a concrete definition; `SCRIPT_DIR=$(dirname -- "$0")`
  and `SOURCE_DIR=$(dirname -- "$0")/..` (or `= "$PLUGIN_DIR"`) should be pinned to the
  install layout (TPM clones the repo into `$TMUX_PLUGIN_MANAGER_PATH/tmux-2html`, which
  contains `build.zig` + `scripts/ensure_binary.sh`).

## Supervisor coordination
None required for this research task. One environment limitation surfaced that the
parent/reviewer should be aware of (and is fully flagged above): **no `web_search` tool
was available**, so external URLs are canonical-recalled and should be re-fetched before
external citation. The action items (verified zig command, the `set -eu` idiom, the
same-FS `mv` pattern, mktemp verdict + fallback) are authoritative and implementation-ready.
