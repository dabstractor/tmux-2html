# P2.M3.T1.S1 — findings (consolidated, verified)

Every load-bearing fact below was verified against THIS repo or empirically run in this
session (tagged) / is established POSIX practice (cited in external.md). An implementer who
has never seen this codebase can ship `scripts/ensure_binary.sh` from these notes + external.md.

## §1  The deliverable boundary (scope) — ONE file, no loader/zig/docs change

- **Deliverable = `scripts/ensure_binary.sh` ONLY.** Not the loader, not build.zig(.zon),
  not docs. (Item contract OUTPUT: "`scripts/ensure_binary.sh` produces a working binary or
  fails loudly." DOCS: "none — install flow documented in README (P4.M2)".)
- **Do NOT modify `tmux-2html.tmux`** — it is a "Complete" contract (P2.M2.T1.S1) AND
  P2.M2.T2.S2 is editing it IN PARALLEL right now (the C-o region binding block). ensure_binary.sh
  is the loader's DEPENDENCY, not its peer. The loader already calls us correctly (§2).
- `scripts/` currently holds only `.gitkeep`; `ensure_binary.sh` is a NEW file. `scripts/` is in
  build.zig.zon `.paths` (shipped with the package) and is cloned by TPM (git clone, not zig pkg).

## §2  The loader §2 contract we CONSUME (verbatim from the live `tmux-2html.tmux`)

```sh
binary_ready=1
if [ -x "$TMUX_2HTML_BIN/tmux-2html" ]; then
    :                                     # common case: binary present + executable
elif [ -f "$plugin_dir/scripts/ensure_binary.sh" ]; then
    if ! sh "$plugin_dir/scripts/ensure_binary.sh" "$TMUX_2HTML_BIN" ; then
        tmux display-message "tmux-2html: install failed (see README)" 2>/dev/null
        binary_ready=0
    fi
else
    tmux display-message "tmux-2html: installer missing (incomplete install)" 2>/dev/null
    binary_ready=0
fi
```

**Therefore (contract for ensure_binary.sh):**
1. **Invoked as a CHILD `sh`:** `sh "$plugin_dir/scripts/ensure_binary.sh" "$TMUX_2HTML_BIN"`.
   `$1 = $TMUX_2HTML_BIN`. It is NOT sourced (the loader is sourced; we are exec'd). ⇒ `set -eu`
   is SAFE inside ensure_binary.sh — it only affects the child, never the user's source-file
   (research/external.md §b.7, ShellCheck SC2187). The contract's "`set -eu`" is honored.
2. **Exit code is the interface:** exit 0 ⇒ binary ready (loader keeps `binary_ready=1`). exit
   non-zero ⇒ loader emits `tmux display-message "tmux-2html: install failed (see README)"` +
   sets `binary_ready=0` (bindings skipped, §9.1).
3. **THE LOADER ALREADY OWNS the user-facing `display-message`.** ⇒ ensure_binary.sh MUST NOT
   call `tmux display-message` itself (would double-flash the identical message; and it must stay
   tmux-agnostic so it is unit-testable / runnable in CI without a tmux server). ensure_binary.sh
   writes a diagnostic to **stderr** on final failure + exits non-zero; the loader turns that into
   the status-line message. This SATISFIES the contract's "on failure → message + skip binding"
   (the user sees the message either way; binding is skipped via `binary_ready=0`). — verified
   deviation, documented; improves testability.
4. **The loader fast-paths on `[ -x ]`.** It calls ensure_binary.sh ONLY when the binary is NOT
   executable. So ensure_binary.sh's step-1 version *comparison* is reached when: the binary is
   missing, OR exists-but-not-executable. (The "exists + executable + stale-version" case is not
   reached via the loader in v1 — that's the loader's pre-existing fast-path; not our concern. We
   still implement step 1 correctly so the script is right standalone/CI and if the loader ever
   loosens its fast-path. P2.M2.T1.S1 PRP: "ensure_binary.sh itself does the existence +
   --version match (PRD §10 step 1) and is idempotent.")

## §3  The version string (LOCKED — verified empirically this session)

- `build.zig.zon`: `.version = "0.1.0"` (string form). `minimum_zig_version = "0.15.2"`.
- `build.zig`: `version_string = @import("build.zig.zon").version;` → `b.addOptions()` bakes it
  into the `build_options` module → `src/main.zig` `printVersion` prints `tmux-2html {s}\n`.
- **EMPIRICAL: `./zig-out/bin/tmux-2html --version` ⇒ `tmux-2html 0.1.0` (exit 0).** [VERIFIED]
- ⇒ the step-1 comparison target is the EXACT full line `tmux-2html 0.1.0` (compare the whole
  `--version` stdout, after command-substitution strips the trailing newline). A substring/word
  match also works but a full-line compare is strictest + simplest.

## §4  The version CONSTANT — where it lives

- Contract: "Plugin version comes from a baked constant in the plugin (must match binary
  --version)." ⇒ a literal at the top of ensure_binary.sh: `EXPECTED_VERSION="0.1.0"`.
- **Sync gotcha (documented):** this literal MUST be kept in lockstep with `build.zig.zon`
  `.version`. Drift is low-frequency (version bumps are rare) and in v1 nearly moot (the loader
  fast-paths on `[ -x ]`, so the comparison rarely fires — §2.4). 2 sync points only:
  `build.zig.zon` + `scripts/ensure_binary.sh`. (Alternative considered + rejected as the
  primary: `sed`-parsing `.version` out of build.zig.zon at runtime — drift-free but adds a
  fragile regex + is "derived" not "baked"; the contract says "baked constant". Parse is noted as
  a possible future improvement, NOT the shipped design.)

## §5  The build command + install layout (LOCKED — verified empirically this session)

- zig 0.15.2 is installed at `/home/dustin/.local/bin/zig`. `--release=fast` is correct (research
  §a.2; build.zig uses `b.standardOptimizeOption(.{})`).
- **EMPIRICAL: `zig build --release=fast --prefix /tmp/x install` (deps cached) ⇒ builds in
  ~18.5s, installs the executable at `/tmp/x/bin/tmux-2html`, and `--version` ⇒ `tmux-2html 0.1.0`.**
  [VERIFIED] So `--prefix <dir>` places the exe at **`<dir>/bin/tmux-2html`** (zig's default exe
  install subdir is `bin/`; `zig build --help` documents `--prefix`, `--prefix-exe-dir`).
- `zig build` MUST run with CWD = the dir containing `build.zig` (= `$plugin_dir`, which TPM clones
  to `$TMUX_PLUGIN_MANAGER_PATH/tmux-2html`). It fetches ghostty+parg into `~/.cache/zig` on first
  build (network required); offline ⇒ build fails ⇒ fall through to download (§8).
- `zig build` writes a local `.zig-cache/` + the install prefix inside `$plugin_dir`/`$tmp`. That is
  acceptable (TPM plugins live in a writable user dir; `.zig-cache` is gitignored).

## §6  Atomicity — "never leave a half-written binary"

- **`rename(2)`/`mv` is atomic ONLY on the same filesystem** (cross-FS ⇒ EXDEV; `mv` then falls
  back to non-atomic copy+unlink — a reader/crash can see a partial file). POSIX `rename`:
  https://pubs.opengroup.org/onlinepubs/9699919799/functions/rename.html (research/external.md §c).
- ⇒ the build temp dir MUST live **INSIDE `$bin_dir`** (same FS as the destination by definition),
  so the final `mv temp/tmux-2html → $bin_dir/tmux-2html` is a true atomic rename. This mirrors the
  Zig-side precedent `renderToFileAtomic` (src/render.zig:203–253: temp `.{base}.{rand}.tmp` IN THE
  SAME DIR → `rename(temp,target)`).
- Pattern: `tmp=$(mktemp -d "$bin_dir/.buildXXXXXXXX" 2>/dev/null)` (positional template, NOT `-t`
  — `-t` differs GNU vs BSD; research/external.md §e.12). Fallback if mktemp absent: PID+epoch
  `mkdir -m 700`. Build into `$tmp` via `--prefix`, locate `$tmp/bin/tmux-2html`, `mv -f` to
  `$bin_dir/tmux-2html`, then `rm -rf "$tmp"`. A cleanup `trap` guarantees the temp is removed on
  any exit/signal (reinforces "never half-written").

## §7  POSIX `set -eu` + the fall-through cascade (the core idiom)

- **POSIX §2.8.1:** under `set -e`, the `-e` is IGNORED for (a) commands in an `if`/`elif`/`while`
  condition, and (b) any command of an `&&`/`||` list OTHER THAN THE LAST.
  (https://pubs.opengroup.org/onlinepubs/9699919799/utilities/set.html) ⇒ the cascade wraps each
  stage's failure-prone command as the CONDITION of an `if` (or non-last in `&&`), so an
  intermediate failure FALLS THROUGH instead of aborting. Only the explicit `exit 1` at the bottom
  is the non-zero termination. [VERIFIED idiom, research/external.md §b]
- **Pitfall — `x=$(cmd)` under `set -e`:** `dash`/POSIX `sh` ABORT on `x=$(false)`; `bash` does not.
  Never assume the bash behavior in a `#!/usr/bin/env sh` script. Capture safely as a non-last
  list element: `got=$(cmd) && [ "$got" = ... ]` (the `$(cmd)` is non-last ⇒ exempt). Used for the
  `--version` probe. [research/external.md §b.7]
- **`command -v zig`** is the POSIX existence test (NOT `which`, which is non-POSIX + output
  varies). `command -v zig >/dev/null 2>&1` ⇒ true if zig on PATH. [POSIX `command`]
- **`set -u` + `$1`:** referencing `$1` with no arg aborts. Use `${1:-${TMUX_2HTML_BIN:-}}`
  (default-expansion is `-u`-safe) and a `[ -n ]` guard.

## §8  The download.sh handshake (S2 does not exist yet — P2.M3.T1.S2 is "Planned")

- `scripts/download.sh` does NOT exist when S1 is implemented. ⇒ S1 MUST guard
  `[ -x "$plugin_dir/scripts/download.sh" ]` before invoking it; until S2 lands the download step
  is skipped (falls through to step 4 ⇒ exit 1) — CORRECT behavior (no download capability yet).
- **The handshake S1 relies on (so S2 can be implemented compatibly):** S1 calls
  `sh "$plugin_dir/scripts/download.sh" "$bin_dir"`; S2 detects `$(uname -sm)` → platform triple
  → fetches the matching tarball from the latest GitHub release → SHA256-verifies → extracts the
  binary into `$bin_dir`; S2 exits 0 with `$bin_dir/tmux-2html` present+executable, or non-zero.
  S1 then needs only `[ -x "$bin" ]` to accept (PRD §10 step 3 "extract into the bin dir" → done;
  S2 owns tarball version/SHA correctness). S1 does NOT pass the version to S2 (S2 downloads the
  latest release; S1 does not re-verify the downloaded version, to avoid over-constraining — see
  PRP Anti-Patterns).

## §9  plugin_dir resolution inside ensure_binary.sh

- The loader invokes us by ABSOLUTE path: `sh "$plugin_dir/scripts/ensure_binary.sh"`. ⇒ `$0`
  inside the script is that absolute path. Resolve robustly:
  `script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)`; `plugin_dir=$(dirname -- "$script_dir")`
  (= the dir holding `build.zig`, `src/`, `scripts/`). The loader ALSO exports `$plugin_dir`, but
  deriving from `$0` keeps the script runnable standalone/CI (no reliance on the export).

## §10  Testing approach (NO shell test framework in repo — mirror the loader PRPs)

- The repo's test suite is Zig golden/unit tests (`zig build test`). There is NO shell harness. The
  prior loader PRPs (P2.M2.T2.S1/S2) validated via inline fake-tmux stubs + an isolated tmux server.
  ensure_binary.sh is tmux-AGNOSTIC, so it is testable WITHOUT any tmux server — simpler:
  - **Level 1:** `sh -n scripts/ensure_binary.sh`; `shellcheck -s sh` (0.11.0 installed); bashism grep.
  - **Level 2 (stubs, deterministic, PRIMARY):** fake `zig` that writes a dummy binary to
    `$tmp/bin/tmux-2html` (simulate a successful build); a fake pre-existing binary (matching vs
    mismatching `--version`); a staged `download.sh`; PATH with/without zig. Assert: version-match ⇒
    exit 0 (no build); version-mismatch/missing + zig ⇒ build + atomic mv + exit 0; missing + no zig
    + download.sh ⇒ exit 0; missing + no zig + no download ⇒ exit 1; the destination is never a
    half-written file; the temp is cleaned up.
  - **Level 3 (REAL zig build, integration — deps are cached so ~18s):**
    `sh scripts/ensure_binary.sh "$tmpbin"` with real zig + the real `$plugin_dir` ⇒ produces a
    working `$tmpbin/tmux-2html` whose `--version` ⇒ `tmux-2html 0.1.0`. This is the end-to-end proof
    of the build path. (CI also runs ReleaseFast tests in P4.M1.T1.S2.)
  - **Level 4 (manual TPM):** real plugin install via TPM, observe the binary acquired (build if zig
    present; download once S2 lands), `prefix O` works.

## §11  Edge cases / failure modes (all must degrade to step-4 exit 1, never crash, never half-write)

- zig present but build fails (offline / compile error / out-of-space) ⇒ rm temp ⇒ fall to download
  ⇒ (no download) ⇒ exit 1. ✓
- build succeeds but artifact not at `$tmp/bin/tmux-2html` (defensive 2-path locate: also try
  `$tmp/tmux-2html`) ⇒ if still not found ⇒ rm temp ⇒ fall through. ✓
- `mv` fails (permissions) ⇒ rm temp ⇒ fall to download. ✓ (don't `exit 1` on mv — download may still work)
- `bin_dir` not creatable (`mkdir -p` fails) ⇒ stderr + exit 1. ✓
- existing binary is a zero-byte / non-executable file ⇒ step-1 `[ -x ]` false ⇒ rebuild. ✓
- `EXPECTED_VERSION` drifts from build.zig.zon ⇒ step-1 compare fails for a stale-but-executable
  binary ⇒ rebuild (harmless; and the loader fast-path means this path is rarely hit in v1). ✓
- concurrent runs (two plugin loads) ⇒ each gets a unique `mktemp` temp ⇒ no collision; the final
  `mv` is atomic per-writer (last writer wins; both produce the same binary). ✓
