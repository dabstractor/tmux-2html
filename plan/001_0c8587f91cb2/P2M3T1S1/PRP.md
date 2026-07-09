name: "P2.M3.T1.S1 — scripts/ensure_binary.sh: version check → zig build → download fallback (atomic, POSIX, tmux-agnostic)"
description: |

---

## Goal

**Feature Goal**: Create `scripts/ensure_binary.sh` — a POSIX `sh` script (run as a
**child** process by the TPM loader, never sourced) that **acquires a working
`tmux-2html` binary** into the plugin's bin dir by trying, in order: (1) **reuse** the
existing binary if its `--version` matches a **baked constant**; (2) **build from
source** with `zig build --release=fast` (when `zig` is on PATH); (3) **download** via
the sibling `scripts/download.sh` (P2.M3.T1.S2 — not yet done, so gracefully skipped
until it lands). Every build/download lands via an **atomic rename** (temp dir created
*inside* the bin dir ⇒ same filesystem ⇒ `mv` is a true atomic `rename(2)`, never a
half-written binary). On **any** failure, write a diagnostic to **stderr** and **exit
non-zero** so the loader flashes `tmux display-message "tmux-2html: install failed (see
README)"` and skips binding — **`ensure_binary.sh` itself never calls `tmux`** (keeps it
tmux-agnostic and unit-testable in CI without a tmux server).

**Deliverable** (ONE new file at `/home/dustin/projects/tmux-2html/`):
- **CREATE `scripts/ensure_binary.sh`** — the complete 4-step acquisition script
  (`set -eu`; exit code = the loader interface: `0` ⇒ binary ready, non-zero ⇒ failed).
  It is **invoked by the already-Complete loader** (`tmux-2html.tmux` §2) as
  `sh "$plugin_dir/scripts/ensure_binary.sh" "$TMUX_2HTML_BIN"`, where **`$1` = the bin
  DIR** (e.g. `…/tmux-2html/bin`), and `$0` = the absolute path to this script.

**Nothing else changes**: do NOT modify `tmux-2html.tmux` (Complete contract + the C-o
region binding task P2.M2.T2.S2 edits it in parallel), `build.zig`/`build.zig.zon`,
`src/*.zig`, or any docs (install flow is documented in the README by P4.M2.T1.S1).

**Success Definition**:
- `sh -n scripts/ensure_binary.sh` passes; `shellcheck -s sh` is clean (ShellCheck 0.11.0
  is installed at `/usr/bin/shellcheck`); no real bashisms (precise grep — the word
  "source" in comments is NOT a bashism).
- **Step 1 (version match)**: a pre-existing executable `$bin_dir/tmux-2html` whose
  `--version` prints exactly `tmux-2html 0.1.0` ⇒ `exit 0` with NO build and NO download
  invocation. (Baked constant `EXPECTED_VERSION="0.1.0"` matches `build.zig.zon`
  `.version`; `--version` output empirically verified = `tmux-2html 0.1.0`.)
- **Step 2 (zig build)**: `zig` on PATH + (missing OR stale-version) binary ⇒
  `zig build --release=fast --prefix "$tmp" install` runs with CWD = the plugin dir, the
  exe lands at `$tmp/bin/tmux-2html`, then `mv -f` into `$bin_dir/tmux-2html` ⇒ `exit 0`,
  and `$tmp` (created INSIDE `$bin_dir`) is cleaned up. A failed build / missing artifact
  / failed `mv` **falls through** to download rather than aborting.
- **Step 3 (download)**: when `scripts/download.sh` is executable, it is invoked as
  `sh "$plugin_dir/scripts/download.sh" "$bin_dir"`; on success S1 accepts via
  `[ -x "$bin" ]` ⇒ `exit 0`. Until S2 lands, the guard skips it (falls through to step 4).
- **Step 4 (failure)**: every path exhausted ⇒ one stderr line + `exit 1` (loader flashes
  the message). Verified the script is **idempotent** and **never leaves a half-written
  binary or a leftover temp**.
- **Atomicity**: the final install is a same-filesystem `mv` (temp created inside
  `$bin_dir`); concurrent runs get unique `mktemp` dirs (last writer wins, both produce
  the same binary).
- **End-to-end (Level 3)**: `sh scripts/ensure_binary.sh "$tmpbin"` with real `zig 0.15.2`
  produces `$tmpbin/tmux-2html` whose `--version` ⇒ `tmux-2html 0.1.0` (deps cached ≈ 18s).
- **POSIX portability**: runs under `dash`/`ash`/`busybox sh`, not just bash-as-`sh`
  (the `set -eu` cascade + `x=$(…)||…` capture idiom are POSIX §2.8.1-correct).

## User Persona (if applicable)

**Target User**: a tmux user installing the plugin via TPM (who may or may not have `zig`
on their machine), and **the plugin loader itself** (`tmux-2html.tmux` §2) which is the
single caller of this script.

**Use Case**: on first plugin load (or after an upgrade), the binary is absent/stale and
must be acquired transparently — build it if the user has Zig, else download a prebuilt
release (once S2 ships), else fail loudly with a clear status-line message.

**User Journey**: `prefix I` (TPM install) → plugin sourced → loader sees no executable →
runs `ensure_binary.sh` → binary built/downloaded into `$TMUX_2HTML_BIN` → bindings go
live. On any failure: status line shows `tmux-2html: install failed (see README)`, no
bindings, user's tmux keeps running.

**Pain Points Addressed**: zero-friction install for Zig users (build) and non-Zig users
(download), with a hard guarantee the plugin **never crashes tmux** and **never leaves a
corrupt binary** that would silently break every `prefix O`.

## Why

- **PRD §10 mandates this exact 4-step "flipped-hybrid" order** (reuse → build → download
  → fail loudly) and the atomic-rename + never-half-written guarantees. This script IS §10.
- **§9.1 step 2 makes binary acquisition the loader's second responsibility** — but the
  loader is *sourced* (must never `set -e` or exit non-zero), so all acquisition logic is
  isolated into this **child** script where `set -eu` is safe. The exit code is the only
  seam between the two (research/findings.md §2).
- **The script is deliberately tmux-agnostic** (it writes to stderr + exits; the *loader*
  owns `tmux display-message`). This is a verified, documented deviation from the literal
  contract ("on failure → message") that makes the script unit-testable in CI without a
  tmux server AND avoids double-flashing the identical message (research/findings.md §2.3).
  The user still sees the message either way; binding is still skipped via `binary_ready=0`.
- **Build-first (vs download-only)** is a strict improvement over the tmux ecosystem
  precedent (tmux-thumbs downloads only): users with `zig` get a guaranteed-version match
  for free; everyone else falls back to the GitHub release (research/external.md §d.10).

## What

### Behavior (`scripts/ensure_binary.sh` — a NEW file)

A `#!/usr/bin/env sh` script, `set -eu`, that implements this cascade (every
failure-prone command is a condition of an `if` or a non-last `&&`/`||` element so
`set -e` lets failures **fall through**, per POSIX §2.8.1 — only the explicit `exit 1`
at the bottom is the non-zero termination):

1. **Resolve inputs.** `bin_dir=${1:-${TMUX_2HTML_BIN:-}}` (the bin DIR; `$1` from the
   loader, env export as a `-u`-safe fallback). `bin="$bin_dir/tmux-2html"`. `script_dir`
   + `plugin_dir` from `$0` via `dirname` (loader passes an absolute `$0`; standalone/CI
   from repo root yields a usable relative path). `EXPECTED_VERSION="0.1.0"`.
2. **Register an EXIT trap** that removes the temp build dir (`tmp`, empty until set) on
   any exit — reinforces "never half-written / never leftover temp".
3. **Step 1 — version match:** if `[ -x "$bin" ]`, capture `cur=$("$bin" --version
   2>/dev/null) || cur=""` (the `|| cur=""` is `-e`-safe); if `[ "$cur" = "tmux-2html
   $EXPECTED_VERSION" ]` → `exit 0`.
4. **Step 2 — zig build:** if `command -v zig`, create `tmp=$(mktemp -d
   "$bin_dir/.buildXXXXXX" 2>/dev/null)` (PID+epoch `mkdir -m 700` fallback). Then
   `if ( cd "$plugin_dir" && zig build --release=fast --prefix "$tmp" install ) && [ -x
   "$tmp/bin/tmux-2html" ] && mv -f "$tmp/bin/tmux-2html" "$bin"; then exit 0; fi`.
   (Temp INSIDE `$bin_dir` ⇒ same FS ⇒ `mv` = atomic rename; the whole chain is the `if`
   condition ⇒ build/mv failure falls through to download, NOT abort.)
5. **Step 3 — download:** if `[ -x "$plugin_dir/scripts/download.sh" ]`, `if sh
   "$plugin_dir/scripts/download.sh" "$bin_dir" 2>/dev/null; then [ -x "$bin" ] && exit
   0; fi`. (S2 not yet done ⇒ guard skips it ⇒ falls through to step 4 — correct.)
6. **Step 4 — fail loudly:** `echo "tmux-2html: ensure_binary.sh: could not obtain binary
   (version/build/download all failed)" >&2; exit 1`.

### Success Criteria

- [ ] `scripts/ensure_binary.sh` exists, `sh -n` passes, `shellcheck -s sh` clean, no real
      bashisms (`[ ]` not `[[ ]]`; `=` not `==`; `$( )` not backticks; no `local`/arrays).
- [ ] Step 1: matching binary ⇒ `exit 0`, no zig invocation, no download invocation.
- [ ] Step 2: `zig` present + missing/stale binary ⇒ build + atomic `mv` + `exit 0`;
      `$tmp` created inside `$bin_dir`; `--version` of the result = `tmux-2html 0.1.0`.
- [ ] Step 2 failure-path: build/mv failure ⇒ falls through to step 3 (does NOT abort),
      temp is cleaned by the EXIT trap.
- [ ] Step 3: a staged executable `download.sh` is invoked with `"$bin_dir"` and, on
      success (places an executable `$bin`), S1 `exit 0`.
- [ ] Step 4: no path succeeds ⇒ exactly one stderr diagnostic + `exit 1`.
- [ ] Never a half-written binary and never a leftover `.build*` temp after any run (atomic
      `mv` + EXIT trap).
- [ ] No modification to `tmux-2html.tmux`, `build.zig(.zon)`, `src/*.zig`, or any docs.

## All Needed Context

### Context Completeness Check

_Passes the "No Prior Knowledge" test_: the exact loader call site that invokes this
script is quoted verbatim below (and the loader is read in full — `tmux-2html.tmux`); the
version string is **empirically verified** (`./zig-out/bin/tmux-2html --version` ⇒
`tmux-2html 0.1.0`; `src/main.zig:108-110` `printVersion` prints `tmux-2html {s}` from
the `build_options.version` module, baked from `build.zig.zon` `.version`); the build
command + install layout are **empirically verified** (`zig build --release=fast --prefix
"$tmp" install` ⇒ `$tmp/bin/tmux-2html`, `--version` ⇒ `tmux-2html 0.1.0`, deps cached ≈
18s); `zig 0.15.2` is at `/home/dustin/.local/bin/zig`; the `set -eu` cascade + `x=$(…) ||
x=""` capture idiom are confirmed under `sh` (POSIX §2.8.1); `mktemp -d "$dir/.buildXXXXXX"`
inside the bin dir is confirmed (same-FS atomic `mv`); `scripts/` currently holds only
`.gitkeep` (this is a NEW file, already in `build.zig.zon` `.paths`); and every gotcha
(`$1` = bin DIR not binary path; the script is a child not sourced; never call `tmux`;
download.sh handshake with S2) is pinned in `research/findings.md` + `research/external.md`.
The verbatim-ready script (shellcheck-validated in this session) is in Implementation
Patterns. An implementer who has never seen this codebase can ship it from this PRP + the
cited files.

### Documentation & References

```yaml
# MUST READ — the ONE caller of this script (quoted verbatim below; its §2 IS our contract)
- file: tmux-2html.tmux
  why: "§2 invokes us: `sh \"$plugin_dir/scripts/ensure_binary.sh\" \"$TMUX_2HTML_BIN\"`
        inside `if ! …`. KEY: $TMUX_2HTML_BIN is the bin DIR (`$plugin_dir/bin`), so our
        `$1` = the bin DIR (binary path = `$1/tmux-2html`). The loader FAST-PATHS on
        `[ -x $bin ]` (calls us only when not executable), owns the user-facing
        `tmux display-message`, and gates bindings on `binary_ready`. We consume its
        exit-code contract; we NEVER call tmux. §1 exports TMUX_2HTML_BIN + plugin_dir
        (we re-derive plugin_dir from $0 for standalone/CI robustness)."
  pattern: "POSIX sh; the loader is SOURCED (no set -e, never non-zero). We are a CHILD sh
            (set -eu is safe — ShellCheck SC2187)."
  gotcha: "DO NOT modify this file — it is a Complete contract (P2.M2.T1.S1) AND P2.M2.T2.S2
           edits it in parallel. ensure_binary.sh is its DEPENDENCY, not its peer."

# MUST READ — the version source-of-truth (baked constant must match this)
- file: build.zig.zon
  why: "`.version = \"0.1.0\"` (line 3). `EXPECTED_VERSION=\"0.1.0\"` in our script MUST
        match this — the SINGLE sync point (bump both together on version bumps). Drift is
        low-frequency and harmless in v1 (the loader's `[ -x ]` fast-path means the version
        compare rarely fires). `minimum_zig_version = \"0.15.2\"` (explains the zig on PATH)."
- file: src/main.zig
  why: "printVersion (L108-110): `std.fmt.bufPrint(&buf, \"tmux-2html {s}\\n\", .{version_string})`
        where version_string = build_options.version (baked from build.zig.zon). So `--version`
        ⇒ `tmux-2html 0.1.0` (EMPIRICALLY VERIFIED). Step-1 compares the FULL line
        `tmux-2html $EXPECTED_VERSION`."
  section: "printVersion"

# MUST READ — the build wiring that step 2 drives
- file: build.zig
  why: "`b.standardOptimizeOption(.{})` ⇒ the CLI `--release=fast` selects the mode (L46
        comments \"--release=fast on the CLI; see Gotcha 1\"). `b.installArtifact(exe)` with
        `.name = \"tmux-2html\"` ⇒ the default install layout places the exe at
        `<prefix>/bin/tmux-2html` (EMPIRICALLY VERIFIED via `--prefix $tmp install`). So
        `zig build --release=fast --prefix \"$tmp\" install` ⇒ `$tmp/bin/tmux-2html`."
  gotcha: "`zig build` MUST run with CWD = the dir containing build.zig (= $plugin_dir). It
           fetches ghostty+parg into ~/.cache/zig on first build (network required); offline
           ⇒ build fails ⇒ fall through to download."

# MUST READ — the consolidated research (every load-bearing fact, verified in-repo)
- file: plan/001_0c8587f91cb2/P2M3T1S1/research/findings.md
  why: "EVERY mechanic is here + verified: the deliverable boundary (§1 — ONE file, no
        loader/zig/docs change), the loader §2 contract we consume verbatim (§2 — incl. the
        $1=bin-DIR fact + the 'loader owns display-message / we use stderr' deviation §2.3),
        the locked version string + constant location (§3-§4), the build command + install
        layout (§5, empirical), atomicity via same-FS temp (§6, mirrors render.zig
        renderToFileAtomic), the set -eu cascade idiom + x=$(…) pitfall (§7), the download.sh
        handshake with S2 (§8 — guard + pass bin dir + accept via [ -x ]), plugin_dir from
        $0 (§9), the testing approach (§10 — no shell harness; mirror loader PRPs' stubs),
        and all edge cases (§11)."
- file: plan/001_0c8587f91cb2/P2M3T1S1/research/external.md
  why: "Canonical POSIX references for the idiom: zig `--prefix` install layout (§a, LOCAL-
        VERIFIED), the set -eu fall-through cascade via POSIX §2.8.1 + the x=$(false) dash
        pitfall (§b), same-filesystem atomic rename + EXDEV (§c), tmux-thumbs binary-download
        precedent (§d.10), and mktemp portability + the `-t` GNU/BSD divergence + PID fallback
        (§e). NOTE: external.md §6's example treats `$1` as the FULL binary path
        (DEST_BIN=$1) — that is a DISCREPANCY with the real loader; findings.md §2 is
        authoritative ($1 = bin DIR). The script in Implementation Patterns follows findings.md."
  critical: "external.md was produced without web access — its POSIX URLs are canonical-recalled
             (V3_chap02.html, set.html, command.html, functions/rename.html are stable). The
             action items + idiom are authoritative regardless."

# MUST READ — the PRD contract
- file: PRD.md
  why: "§10 is the literal 4-step spec this script implements (reuse→build→download→fail;
        atomic rename; never half-written; platform triples live in download.sh/S2). §9.1
        step 2 (loader calls us; on failure display-message + skip binding). §12 (zig 0.15.2,
        tmux ≥ 3.2). §13 (concurrent runs — unique mktemp temps)."
  section: "§9.1", "§10", "§12", "§13"

# MUST READ — the Zig-side atomic-write precedent (same idiom, different language)
- file: src/render.zig
  why: "renderToFileAtomic (L195-253) is the proven in-repo atomic-write idiom: create a temp
        named `.{base}.{rand}.tmp` IN THE SAME DIRECTORY as the target (same FS ⇒ rename is
        atomic, no EXDEV), write, best-effort sync, rename(temp→target), cleanup temp on error.
        Our `mktemp -d \"$bin_dir/.buildXXXXXX\"` + `mv` into `$bin_dir` is the shell analogue."
  section: "renderToFileAtomic doc comment (L196-217)"

# READ ONLY — the download sibling this script defers to (does NOT exist yet)
- file: scripts/download.sh   # ← does NOT exist when S1 ships (S2 = P2.M3.T1.S2, "Planned")
  why: "The handshake S1 relies on (so S2 can be implemented compatibly): S1 calls
        `sh download.sh \"$bin_dir\"`; S2 detects `$(uname -sm)` → platform triple → fetches
        the matching tarball from the latest GitHub release → SHA256-verifies → extracts the
        binary into `$bin_dir`; S2 exits 0 with `$bin_dir/tmux-2html` executable, or non-zero.
        S1 accepts via `[ -x $bin ]` and does NOT pass the version to S2 (S2 downloads the
        latest; S1 does not re-verify the downloaded version — see Anti-Patterns). Until S2
        lands the `[ -x download.sh ]` guard skips this step."
  gotcha: "S1 ships BEFORE S2. Guard with [ -x ], never assume it exists."

# External (stable, canonical-recalled — re-fetch anchors before external citation)
- url: https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html#tag_18_08_01
  why: "POSIX §2.8.1 'Consequences of Shell Errors': under `set -e`, the `-e` is IGNORED for
        commands in an if/elif/while CONDITION and for any non-last command of an &&/|| list.
        This is EXACTLY why each stage's failure-prone command is the condition of an `if` (or
        non-last in &&) so it FALLS THROUGH instead of aborting."
  critical: "Only the explicit `exit 1` at the bottom is the non-zero termination."
- url: https://pubs.opengroup.org/onlinepubs/9699919799/utilities/set.html
  why: "`set -e` (errexit) + `set -u` (nounset) semantics. Justifies `set -eu` in the child sh."
- url: https://pubs.opengroup.org/onlinepubs/9699919799/functions/rename.html
  why: "`rename()` is atomic ONLY within one filesystem; cross-FS ⇒ EXDEV (mv then falls back
        to non-atomic copy+unlink). JUSTIFIES creating the temp INSIDE $bin_dir (same FS by
        definition) so the final mv is a true atomic rename."
  critical: "Never build into /tmp and mv across to $bin_dir — that can leave a half-written binary."
- url: https://pubs.opengroup.org/onlinepubs/9699919799/utilities/command.html
  why: "`command -v zig` is the POSIX existence test (NOT `which`, which is non-POSIX + output
        varies). `command -v zig >/dev/null 2>&1` ⇒ true if zig on PATH."
```

### Current Codebase tree (relevant subset)

```bash
tmux-2html.tmux       # FILLED by P2.M2.T1.S1 + P2.M2.T2.S1/S2. §2 CALLS ensure_binary.sh.     ← READ ONLY (DO NOT MODIFY)
build.zig             # `--release=fast` selects optimize; installArtifact exe = tmux-2html.    ← READ ONLY
build.zig.zon         # `.version = "0.1.0"` — the baked constant's sync partner.               ← READ ONLY
src/main.zig          # printVersion (L108): `tmux-2html {s}` ⇒ `tmux-2html 0.1.0`.             ← READ ONLY
src/render.zig        # renderToFileAtomic — the in-repo atomic-write precedent (same-FS temp). ← READ ONLY
scripts/              # holds only `.gitkeep` today. (In build.zig.zon .paths ⇒ shipped by TPM.) ← ADD ensure_binary.sh HERE
scripts/.gitkeep      # placeholder; leave it (keeps the dir in git before any real file).
PRD.md                # §9.1, §10, §12, §13.                                                    ← READ ONLY
# zig 0.15.2 at /home/dustin/.local/bin/zig ; shellcheck 0.11.0 at /usr/bin/shellcheck ; /bin/sh -> bash here
# (but the script MUST stay dash/ash/busybox-portable; shellcheck -s sh enforces it.)
```

### Desired Codebase tree with file responsibilities

```bash
scripts/ensure_binary.sh   # NEW. POSIX sh child script (set -eu): step1 reuse-if-version-matches
                           #   → step2 zig build --release=fast into a same-FS temp + atomic mv →
                           #   step3 sh download.sh "$bin_dir" (guarded; S2 not done yet) →
                           #   step4 stderr + exit 1. Exit code = loader interface. NEVER calls tmux
                           #   (writes stderr; loader flashes display-message). EXIT trap cleans temp.
# (No other files change. .gitkeep stays. tmux-2html.tmux / build.* / src/*.zig / docs untouched.)
```

### Known Gotchas of our codebase & Library Quirks

```sh
# CRITICAL ($1 = the bin DIR, NOT the binary path): the loader does
#   TMUX_2HTML_BIN="$plugin_dir/bin"; sh ".../ensure_binary.sh" "$TMUX_2HTML_BIN"
# so $1 is the DIRECTORY (…/tmux-2html/bin). The binary is "$1/tmux-2html". The earlier
# external.md example (DEST_BIN=$1) assumed $1 was the full binary path — that is WRONG for
# this loader; findings.md §2 is authoritative. (RECONCILED — the script below uses bin_dir=$1.)

# CRITICAL (this is a CHILD sh, never sourced): the loader runs `sh ".../ensure_binary.sh" …`
# (an exec'd subshell), NOT `source`/`.`. So `set -eu` only affects the child — it can NEVER
# abort the user's `source-file` / `prefix I` (ShellCheck SC2187). This is WHY set -eu is safe
# here but NOT in tmux-2html.tmux. Verified the call site: `if ! sh "$plugin_dir/scripts/ensure_binary.sh" "$TMUX_2HTML_BIN"`.

# CRITICAL (we MUST NOT call tmux): the loader ALREADY owns the user-facing
#   tmux display-message "tmux-2html: install failed (see README)"
# Calling it ourselves would double-flash the identical message AND couple us to a tmux server
# (un-unit-testable in CI). On failure we write ONE line to STDERR and exit non-zero; the loader
# turns that into the status-line message + sets binary_ready=0 (bindings skipped). This
# SATISFIES the contract's "on failure → message + skip binding" (research/findings.md §2.3).

# CRITICAL (atomicity — never half-written): `mv`/`rename(2)` is atomic ONLY on the SAME
# filesystem (cross-FS ⇒ EXDEV ⇒ mv falls back to non-atomic copy+unlink; a crash leaves a
# partial file). So the build temp dir is created INSIDE $bin_dir (`mktemp -d
# "$bin_dir/.buildXXXXXX"`) — same FS by definition — so the final `mv -f $tmp/bin/tmux-2html
# $bin` is a true atomic rename. Mirrors src/render.zig renderToFileAtomic (same-dir temp +
# rename). NEVER build into /tmp and mv across.

# CRITICAL (set -eu cascade — POSIX §2.8.1): every failure-prone command (zig build, the
#   --version probe, mv, download.sh) MUST be either (a) the condition of an `if`, or (b) a
#   non-last element of an &&/|| list, so a failure FALLS THROUGH to the next stage instead of
#   aborting. Only the explicit `exit 1` is the non-zero termination. Do NOT write
#   `zig build ... ` as a bare statement (a build failure would abort → step 4 message skipped
#   + temp not cleaned). Do NOT put the failing command as the LAST element of a bare && list.

# PITFALL (x=$(cmd) under set -e is a portability trap): in dash/POSIX sh, `x=$(false)` ABORTS;
#   in bash it does NOT. Never assume the bash behavior in a #!/usr/bin/env sh script. Capture
#   safely as a non-last list element: `cur=$(... ) || cur=""` (the || makes the $(...) non-last
#   ⇒ -e exempt). Used for the --version probe. (research/external.md §b.7)

# GOTCHA (command -v, NOT which): `command -v zig >/dev/null 2>&1` is the POSIX existence test.
#   `which` is non-POSIX + its output/exit-status varies across platforms.

# GOTCHA (mktemp -t is unportable): the `-t` flag differs GNU (deprecated template) vs BSD/macOS
#   (a prefix in $TMPDIR). Use the POSITIONAL template form `mktemp -d "$bin_dir/.buildXXXXXX"`
#   (≥3 trailing X) — portable across GNU/BSD/busybox AND places the temp inside $bin_dir (same
#   FS). Provide a PID+epoch `mkdir -m 700` fallback only if mktemp is absent (rare).

# GOTCHA (set -u + $1): referencing $1 with no arg aborts under set -u. Use
#   `bin_dir=${1:-${TMUX_2HTML_BIN:-}}` (default-expansion is -u-safe) + a `[ -z ]` guard.

# GOTCHA (the EXIT trap + set -e): the trap string is evaluated at FIRE time; reference tmp with
#   `${tmp:-}` so it stays -u-safe even before tmp is assigned. End the trap body with `|| :` so
#   a failing rm never makes the trap return non-zero. (An inline trap avoids ShellCheck SC2329
#   "function never invoked"; a named fn + `trap fn EXIT` is also fine if you disable SC2329.)

# GOTCHA (download.sh does NOT exist when S1 ships — S2 = P2.M3.T1.S2 is "Planned"): guard with
#   `[ -x "$plugin_dir/scripts/download.sh" ]` BEFORE invoking. Until S2 lands step 3 is skipped
#   → falls through to step 4 (exit 1) — CORRECT (no download capability yet).

# GOTCHA (the loader fast-paths on [ -x ]): it calls ensure_binary.sh ONLY when the binary is NOT
#   executable. So step 1's version compare is reached when the binary is missing OR
#   exists-but-not-executable. We still implement step 1 correctly so the script is right
#   standalone/CI and if the loader ever loosens its fast-path (idempotent).

# GOTCHA (shellcheck SC1007/SC2329 false positives): `CDPATH= cd` triggers SC1007 — AVOID by
#   using plain `dirname -- "$0"` (the loader's $0 is already absolute; canonicalization isn't
#   needed). A named `cleanup()` fn only ever called via the trap triggers SC2329 — use an
#   inline trap string (`trap '... ' EXIT`) to keep shellcheck -s sh clean.
```

## Implementation Blueprint

### Data models and structure

N/A — this is a stateless POSIX shell script. The only "data" is the baked
`EXPECTED_VERSION="0.1.0"` literal (sync partner: `build.zig.zon` `.version`) and the
exit code (0 = ready, non-zero = failed), which is the single seam to the loader.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: CREATE scripts/ensure_binary.sh
  - IMPLEMENT: the full 4-step cascade (reuse → zig build → download → fail) EXACTLY as the
    verbatim-ready script in "Implementation Patterns & Key Details" below.
  - SHEBANG: `#!/usr/bin/env sh` (POSIX sh; the loader runs it via `sh`, but the shebang makes
    it directly executable too). `set -eu` at the top.
  - INPUTS: `bin_dir=${1:-${TMUX_2HTML_BIN:-}}` (bin DIR; guard `[ -z ]` → stderr + exit 2);
    `bin="$bin_dir/tmux-2html"`; `script_dir=$(dirname -- "$0")`; `plugin_dir=$(dirname --
    "$script_dir")`; `EXPECTED_VERSION="0.1.0"`.
  - TRAP: `tmp=""; trap '[ -n "${tmp:-}" ] && [ -d "${tmp:-}" ] && rm -rf -- "${tmp:-}" 2>/dev/null || :' EXIT`
  - STEP 1: version match (capture `cur=$(...) || cur=""`; compare full line `tmux-2html $EXPECTED_VERSION`).
  - STEP 2: `command -v zig` → mktemp inside bin_dir → `cd $plugin_dir && zig build
    --release=fast --prefix "$tmp" install` → `[ -x "$tmp/bin/tmux-2html" ] && mv -f …` (all
    inside an `if` condition → fall-through on failure).
  - STEP 3: `[ -x download.sh ]` guard → `sh download.sh "$bin_dir"` → `[ -x "$bin" ] && exit 0`.
  - STEP 4: stderr line + `exit 1`.
  - FOLLOW pattern: POSIX §2.8.1 fall-through cascade (research/external.md §b); same-FS atomic
    temp (src/render.zig renderToFileAtomic; research/findings.md §6).
  - NAMING: snake_case vars (bin_dir, plugin_dir, EXPECTED_VERSION, tmp, cur, _ts); the file is
    ensure_binary.sh (lowercase, matches PRD §10 + the loader call site).
  - PLACEMENT: scripts/ensure_binary.sh (NEW file; scripts/ already in build.zig.zon .paths).

Task 2: MAKE EXECUTABLE + VALIDATE (every command verified — see Validation Loop)
  - chmod +x scripts/ensure_binary.sh (the loader invokes via `sh` so +x is not strictly
    required, but it is the [ -x ]-tested + directly-runnable convention).
  - Level 1: sh -n; shellcheck -s sh (0.11.0 at /usr/bin/shellcheck); precise bashism grep
    (comment lines excluded).
  - Level 2 (stubs, deterministic, PRIMARY): fake-zig (writes a dummy exe to $tmp/bin/tmux-2html);
    a fake pre-existing binary (matching vs mismatching --version); a staged download.sh; PATH
    with/without zig. Assert: match ⇒ exit 0 (no build/download); mismatch/missing+zig ⇒ build +
    atomic mv + exit 0 + temp cleaned; missing+no-zig+no-download ⇒ exit 1; staged download ⇒
    exit 0; destination never half-written.
  - Level 3 (REAL zig build, integration — deps cached ≈ 18s): sh scripts/ensure_binary.sh
    "$tmpbin" with real zig + the real $plugin_dir ⇒ produces a working $tmpbin/tmux-2html whose
    --version ⇒ tmux-2html 0.1.0.
  - Level 4 (manual TPM): real plugin install via TPM; observe the binary acquired.
```

### Implementation Patterns & Key Details

```sh
# ===== scripts/ensure_binary.sh — VERBATIM-READY (shellcheck CLEAN, sh -n OK, validated this session) =====
#!/usr/bin/env sh
# ensure_binary.sh — acquire the tmux-2html binary (PRD §10).
# Order: (1) existing binary whose --version matches the baked constant → done;
#        (2) `zig build --release=fast` into the bin dir (atomic rename) → done;
#        (3) scripts/download.sh (latest GitHub release, SHA256-verified) → done;
#        (4) any failure → stderr diagnostic + exit non-zero (the loader flashes
#            `tmux display-message "tmux-2html: install failed (see README)"` and
#            skips binding — we NEVER call tmux ourselves: tmux-agnostic + unit-
#            testable). Never leaves a half-written binary (atomic rename).
# Invoked by tmux-2html.tmux §2 as:
#   sh "$plugin_dir/scripts/ensure_binary.sh" "$TMUX_2HTML_BIN"
# ⇒ $1 = the bin DIR (…/tmux-2html/bin); $0 = our absolute path.
# `set -eu` is SAFE: we are a child `sh`, never sourced (ShellCheck SC2187).

set -eu

# ---- inputs + paths ---------------------------------------------------------
# $1 = bin dir (loader contract). Default-expand for -u + standalone/CI safety;
# also honor an exported $TMUX_2HTML_BIN as a fallback.
bin_dir=${1:-${TMUX_2HTML_BIN:-}}
if [ -z "$bin_dir" ]; then
    echo "tmux-2html: ensure_binary.sh: no bin dir given (pass it as \$1)" >&2
    exit 2
fi
bin="$bin_dir/tmux-2html"

# Plugin dir = the dir holding build.zig (= parent of scripts/). Derive from $0;
# the loader invokes us by ABSOLUTE path (so dirname is already absolute), and a
# standalone/CI run from the repo root yields a relative-but-usable "." path.
script_dir=$(dirname -- "$0")
plugin_dir=$(dirname -- "$script_dir")

# Baked plugin version — MUST match build.zig.zon `.version` (single sync point:
# bump both together). main.zig printVersion prints `tmux-2html <version>`.
EXPECTED_VERSION="0.1.0"

# tmp cleanup on ANY exit (reinforces "never half-written"); empty until set.
# Inline (not a named fn) so shellcheck sees no "unused function"; `${tmp:-}`
# stays -u-safe even before tmp is assigned.
tmp=""
trap '[ -n "${tmp:-}" ] && [ -d "${tmp:-}" ] && rm -rf -- "${tmp:-}" 2>/dev/null || :' EXIT

# ---- step 1: existing binary at the baked version? → done -------------------
if [ -x "$bin" ]; then
    # Capture --version safely: under set -e, `x=$(...)` in dash ABORTS on a
    # failing $(...); the trailing `|| cur=""` makes the assignment a non-last
    # list element (POSIX §2.8.1) so a failing/empty --version does NOT abort.
    cur=$("$bin" --version 2>/dev/null) || cur=""
    if [ "$cur" = "tmux-2html $EXPECTED_VERSION" ]; then
        exit 0
    fi
fi

# ---- step 2: build from source via zig? → done ------------------------------
if command -v zig >/dev/null 2>&1; then
    # Temp dir INSIDE bin_dir ⇒ same filesystem ⇒ the final `mv` is an atomic
    # rename (no EXDEV copy). Positional mktemp template (NOT -t: GNU vs BSD
    # differ). PID+epoch mkdir fallback for the rare mktemp-less host.
    tmp=$(mktemp -d "$bin_dir/.buildXXXXXX" 2>/dev/null) || {
        _ts=$(date +%s 2>/dev/null) || _ts=0
        tmp="$bin_dir/.build.$$.$_ts"
        mkdir -m 700 "$tmp" 2>/dev/null || tmp=""
    }
    if [ -n "$tmp" ]; then
        # cd into the source dir (build.zig lives there) + install to the temp
        # prefix; the exe lands at $tmp/bin/tmux-2html. The whole pipeline is
        # the condition of an `if` ⇒ a failed/aborted build (and even a failed
        # mv) FALLS THROUGH to download instead of aborting (POSIX §2.8.1).
        if ( cd "$plugin_dir" && zig build --release=fast --prefix "$tmp" install ) \
           && [ -x "$tmp/bin/tmux-2html" ] \
           && mv -f "$tmp/bin/tmux-2html" "$bin"; then
            exit 0
        fi
        # build/artifact/mv failed → fall through to download (trap cleans tmp).
    fi
fi

# ---- step 3: download.sh (latest release; SHA256-verified) → done -----------
# download.sh is P2.M3.T1.S2 (NOT YET DONE). Guard before invoking; until S2
# lands this step is skipped → falls through to step 4 (correct: no download
# capability yet). Handshake: S1 passes the bin dir; S2 downloads/verifies/
# extracts into it; S1 accepts via [ -x $bin ] (S2 owns tarball version/SHA).
if [ -x "$plugin_dir/scripts/download.sh" ]; then
    if sh "$plugin_dir/scripts/download.sh" "$bin_dir" 2>/dev/null; then
        [ -x "$bin" ] && exit 0
    fi
fi

# ---- step 4: every path failed → loud failure (loader flashes the message) --
echo "tmux-2html: ensure_binary.sh: could not obtain binary (version/build/download all failed)" >&2
exit 1
# ===== end =====

# WHY set -eu (and why it's safe here): we are exec'd as a child `sh`, NOT sourced. A sourced
#   plugin (tmux-2html.tmux) must never set -e / never non-zero (it would abort the user's
#   source-file). Here set -eu is correct + desirable: it catches typos/unbound vars locally
#   and can never leak to the user's tmux. (ShellCheck SC2187 is about SOURCING a set -e script —
#   we are never sourced.)
# WHY the `if A && B && mv` chain (not bare `zig build`): under set -e a bare failing build
#   ABORTS (skips step 3 + the step-4 message + leaves temp). Wrapping the whole build+verify+mv
#   as the CONDITION of an `if` makes every failure FALL THROUGH (POSIX §2.8.1) to download, then
#   to step 4. The EXIT trap cleans the temp on every path (incl. success).
# WHY the temp is INSIDE $bin_dir: `mv`/`rename` is atomic only on the same filesystem (cross-FS
#   ⇒ EXDEV ⇒ non-atomic copy). Same dir ⇒ same FS ⇒ true atomic rename ⇒ never a half-written
#   binary a reader/crash could observe. Mirrors src/render.zig renderToFileAtomic.
# WHY stderr + exit (NOT tmux display-message): the loader already owns the user-facing message
#   (tmux-2html.tmux §2). Calling tmux ourselves would double-flash it AND couple us to a server
#   (un-testable in CI). stderr + exit non-zero is the clean, testable contract.
# WHY [ "$cur" = "tmux-2html $EXPECTED_VERSION" ] (full-line, not substring): strictest + simplest.
#   --version prints exactly `tmux-2html 0.1.0\n`; $(...) strips the newline. A substring
#   `*"0.1.0"*` would wrongly match `0.1.0-rc1`. Full-line compare keeps the prefix `tmux-2html `
#   (the program name from main.zig printVersion) as part of the match.
# WHY pass the bin DIR to download.sh (not the version): S2 downloads the LATEST release; S1 does
#   not over-constrain by re-verifying the downloaded version (would reject valid latest releases
#   on a version bump). S2 owns tarball version+SHA correctness; S1 just [ -x ]-accepts. See
#   Anti-Patterns.
```

### Integration Points

```yaml
LOADER (tmux-2html.tmux §2 — ALREADY consumes us, DO NOT CHANGE):
  - calls:    `sh "$plugin_dir/scripts/ensure_binary.sh" "$TMUX_2HTML_BIN"`  (inside `if ! …`)
  - $1 =      $TMUX_2HTML_BIN (the bin DIR: $plugin_dir/bin)
  - exit 0 ⇒  loader keeps binary_ready=1 (bindings go live)
  - exit≠0 ⇒  loader runs `tmux display-message "tmux-2html: install failed (see README)"`
              + sets binary_ready=0 (§9.1: skip binding). [WE do NOT call tmux — loader owns it.]
  - note:     loader fast-paths on `[ -x $bin ]` → calls us only when binary not executable.
VERSION SYNC:
  - EXPECTED_VERSION="0.1.0" (in ensure_binary.sh) ↔ build.zig.zon `.version` ("0.1.0") ↔
    src/main.zig printVersion output ("tmux-2html 0.1.0"). ONE sync point (the .version literal);
    bump all three together on a release.
DOWNLOAD SIBLING (scripts/download.sh — P2.M3.T1.S2, NOT YET DONE):
  - handshake: S1 calls `sh download.sh "$bin_dir"`; S2 downloads the latest GitHub release for
    the $(uname -sm)→platform-triple, SHA256-verifies vs SHA256SUMS.txt, extracts into $bin_dir;
    S2 exits 0 with $bin_dir/tmux-2html executable (or non-zero). S1 accepts via `[ -x $bin ]`.
  - S1 does NOT pass the version to S2 and does NOT re-verify the downloaded version.
  - Until S2 ships, the `[ -x download.sh ]` guard skips step 3 → step 4 (exit 1). CORRECT.
BUILD/PACKAGE:
  - scripts/ is ALREADY in build.zig.zon `.paths` ⇒ the script ships with the package + is cloned
    by TPM (git clone, not zig-pkg). NO build.zig(.zon) change needed.
  - zig 0.15.2 required (build.zig.zon minimum_zig_version); fetched deps cache in ~/.cache/zig.
DOCS:
  - NO CHANGE — install flow is documented in the README by P4.M2.T1.S1 (item contract: "DOCS:
    none"). docs/CONFIGURATION.md is about runtime options, not install.
TEST ISOLATION (PRD §0/§13):
  - ensure_binary.sh is tmux-AGNOSTIC ⇒ Level 1-3 tests need NO tmux server (simpler than the
    loader PRPs). Concurrent plugin loads each get a unique mktemp temp (last writer wins; both
    produce the same binary) — PRD §13 spirit.
```

## Validation Loop

### Level 1: Syntax & Style (after creating the script)

```bash
chmod +x scripts/ensure_binary.sh
sh -n scripts/ensure_binary.sh && echo "syntax OK"            # POSIX syntax (mandatory)
command -v shellcheck >/dev/null && shellcheck -s sh scripts/ensure_binary.sh && echo "shellcheck CLEAN" \
  || echo "shellcheck N/A"
# Bashism scan — exclude comment lines (the English word "source"/"local" in comments is NOT a
# bashism). Expect ZERO hits in real code.
grep -vnE '^[[:space:]]*#' scripts/ensure_binary.sh | grep -E '\[\[|==|BASH_SOURCE|declare |[[:space:]]local |[[:space:]]let |<\(' \
  && echo "FAIL: bashisms found" || echo "no bashisms"
# Expected: "syntax OK"; "shellcheck CLEAN" (the script in Implementation Patterns is pre-validated);
# "no bashisms".
```

### Level 2: Step-by-step stub tests (PRIMARY — deterministic, no real build, no tmux)

```bash
# A self-contained harness: a fake `zig` (writes a dummy exe to $tmp/bin/tmux-2html on `build`),
# a fake pre-existing binary (matching/mismatching --version), a staged download.sh, and PATH
# manipulation. Asserts every branch + atomicity + temp cleanup.
work=$(mktemp -d); repo=$(pwd); fakebin="$work/fakebin"
mkdir -p "$fakebin"
# fake zig: on `build ... --prefix <dir> install`, create <dir>/bin/tmux-2html (a dummy exe).
cat > "$fakebin/zig" <<'EOF'
#!/usr/bin/env sh
# only the build subcommand with --prefix matters; grab the --prefix arg.
prefix=""
prev=""
for a in "$@"; do
    [ "$prev" = "--prefix" ] && prefix="$a"
    prev="$a"
done
case "$1" in
  build) mkdir -p "$prefix/bin"; printf '#!/usr/bin/env sh\necho tmux-2html 0.1.0\n' > "$prefix/bin/tmux-2html"; chmod +x "$prefix/bin/tmux-2html";;
  *) exit 0;;
esac
EOF
chmod +x "$fakebin/zig"

# ---- (a) STEP 1: matching binary ⇒ exit 0, NO zig, NO download. ----
binA="$work/binA"; mkdir -p "$binA"
printf '#!/usr/bin/env sh\necho "tmux-2html 0.1.0"\n' > "$binA/tmux-2html"; chmod +x "$binA/tmux-2html"
out=$(PATH="$fakebin:/usr/bin:/bin" sh "$repo/scripts/ensure_binary.sh" "$binA" 2>"$work/errA"); rc=$?
[ "$rc" = 0 ] && echo "PASS a: matching binary ⇒ exit 0"
[ -s "$work/errA" ] && echo "FAIL a: wrote stderr on success" || echo "PASS a: no stderr on success"

# ---- (b) STEP 2: zig present + STALE binary (mismatch) ⇒ build + atomic mv + exit 0; temp cleaned. ----
binB="$work/binB"; mkdir -p "$binB"
printf '#!/usr/bin/env sh\necho "tmux-2html 0.0.1-stale"\n' > "$binB/tmux-2html"; chmod +x "$binB/tmux-2html"
PATH="$fakebin:/usr/bin:/bin" sh "$repo/scripts/ensure_binary.sh" "$binB" 2>"$work/errB"; rc=$?
[ "$rc" = 0 ] && echo "PASS b: stale+zig ⇒ exit 0 (rebuilt)"
"$binB/tmux-2html" 2>/dev/null | grep -qx 'tmux-2html 0.1.0' && echo "PASS b: rebuilt binary is the fresh version"
# atomicity + temp cleanup: no leftover .build* temp inside binB.
ls -A "$binB" | grep -qE '^\.build' && echo "FAIL b: leftover build temp" || echo "PASS b: no leftover temp (atomic + trap)"
ls -A "$binB" | grep -qx 'tmux-2html' && echo "PASS b: only the binary remains in bin dir"

# ---- (c) STEP 2 → build FAILS (no zig on PATH) + no download ⇒ exit 1 + stderr. ----
binC="$work/binC"; mkdir -p "$binC"
out=$(PATH="/usr/bin:/bin" sh "$repo/scripts/ensure_binary.sh" "$binC" 2>"$work/errC"); rc=$?
[ "$rc" = 1 ] && echo "PASS c: no zig + no download ⇒ exit 1"
grep -q 'could not obtain binary' "$work/errC" && echo "PASS c: stderr diagnostic on failure"
[ ! -e "$binC/tmux-2html" ] && echo "PASS c: no half-written binary left"

# ---- (d) STEP 2 build FAILS but zig present (fake zig that always fails) ⇒ fall through to step 4. ----
# (Dedicated PATH with ONLY a failing fake zig, so we reach step 3/4 without a real build.)
binD="$work/binD"; mkdir -p "$binD" "$work/zb"
cat > "$work/zb/zig" <<'EOF'
#!/usr/bin/env sh
echo "zig: simulated network/compile failure" >&2; exit 1
EOF
chmod +x "$work/zb/zig"
out=$(PATH="$work/zb:/usr/bin:/bin" sh "$repo/scripts/ensure_binary.sh" "$binD" 2>"$work/errD"); rc=$?
[ "$rc" = 1 ] && echo "PASS d: zig build failure ⇒ exit 1 (no download available)"
ls -A "$binD" | grep -qE '^\.build' && echo "FAIL d: leftover temp after failed build" || echo "PASS d: failed-build temp cleaned by trap"

# ---- (e) STEP 3: staged download.sh ⇒ invoked with "$bin_dir", S1 accepts via [ -x $bin ]. ----
binE="$work/binE"; mkdir -p "$binE"
cat > "$repo/scripts/download.sh" <<'EOF'
#!/usr/bin/env sh
# fake S2: record the arg it received, then place an executable binary in $1.
printf 'download.sh got arg=%s\n' "$1" > "$1/.download-arg"
printf '#!/usr/bin/env sh\necho "tmux-2html 0.1.0"\n' > "$1/tmux-2html"; chmod +x "$1/tmux-2html"
EOF
chmod +x "$repo/scripts/download.sh"
# disable zig (ensure we reach step 3) by a PATH without it:
out=$(PATH="/usr/bin:/bin" sh "$repo/scripts/ensure_binary.sh" "$binE" 2>"$work/errE"); rc=$?
[ "$rc" = 0 ] && echo "PASS e: download path ⇒ exit 0"
grep -q "arg=$binE" "$binE/.download-arg" && echo "PASS e: download.sh invoked with the bin DIR"
"$binE/tmux-2html" 2>/dev/null | grep -qx 'tmux-2html 0.1.0' && echo "PASS e: downloaded binary accepted via [ -x ]"
rm -f "$repo/scripts/download.sh"          # CLEAN UP the staged sibling (S2 ships it for real)

# ---- (f) atomicity guarantee: destination is never observable as half-written. ----
# (Conceptual assertion reinforced by (b)/(c)/(d): the temp lives in $bin_dir/.build* and the
#  final install is a single `mv` = atomic rename; a reader/crash sees EITHER the old binary or
#  the new one, never a partial file. No .build* temp survives any path.) Already covered above.

# ---- (g) standalone/CI: no $1 ⇒ stderr + exit 2 (does not abort caller). ----
out=$(PATH="/usr/bin:/bin" TMUX_2HTML_BIN="" sh "$repo/scripts/ensure_binary.sh" 2>"$work/errG" || true); 
grep -q 'no bin dir given' "$work/errG" && echo "PASS g: missing bin dir ⇒ stderr diagnostic"

rm -rf "$work"
# Expected: every PASS prints; exit codes 0/0/1/1/0 per branch; no leftover temps; download.sh
# invoked with the bin dir; never a half-written binary.
```

### Level 3: Real zig build (integration — deps cached ≈ 18s)

```bash
# End-to-end proof of the build path with the REAL toolchain + the REAL plugin source.
# (No tmux needed — ensure_binary.sh is tmux-agnostic.) zig 0.15.2 at /home/dustin/.local/bin/zig.
work=$(mktemp -d); repo=$(pwd)
tmpbin="$work/bin"; mkdir -p "$tmpbin"
# (a) Fresh bin dir, no pre-existing binary ⇒ must build from source.
time sh "$repo/scripts/ensure_binary.sh" "$tmpbin"; echo "exit=$?"
[ -x "$tmpbin/tmux-2html" ] && echo "PASS L3a: built binary exists + executable"
"$tmpbin/tmux-2html" --version | grep -qx 'tmux-2html 0.1.0' && echo "PASS L3a: --version ⇒ tmux-2html 0.1.0"
# (b) Re-run ⇒ step 1 fast-path (version matches) ⇒ exit 0, no rebuild (instant).
time sh "$repo/scripts/ensure_binary.sh" "$tmpbin"; echo "exit=$? (should be near-instant: step-1 reuse)"
# (c) Simulate a stale binary ⇒ must rebuild (≈18s) + atomic mv.
printf '#!/usr/bin/env sh\necho "tmux-2html 0.0.0-stale"\n' > "$tmpbin/tmux-2html"; chmod +x "$tmpbin/tmux-2html"
sh "$repo/scripts/ensure_binary.sh" "$tmpbin"; echo "exit=$?"
"$tmpbin/tmux-2html" --version | grep -qx 'tmux-2html 0.1.0' && echo "PASS L3c: stale binary rebuilt to 0.1.0"
rm -rf "$work"
# Expected: L3a builds (~18s) + version matches; L3b instant reuse; L3c rebuilds stale.
```

### Level 4: Manual / interactive (real TPM install — NOT in CI)

```bash
# In a REAL tmux + TPM setup (or an isolated test socket), after `prefix I`:
#   1. TPM clones the repo to $TMUX_PLUGIN_MANAGER_PATH/tmux-2html and sources tmux-2html.tmux.
#   2. Loader §2: no executable ⇒ runs scripts/ensure_binary.sh "$TMUX_2HTML_BIN".
#   3. With zig installed: ~18s build, binary lands in …/tmux-2html/bin/tmux-2html, bindings go live.
#      Without zig (once S2 ships): download.sh fetches the matching release tarball, verifies SHA256,
#      extracts into the bin dir, bindings go live.
#   4. On any failure: status line shows `tmux-2html: install failed (see README)`, no bindings,
#      tmux keeps running.
#   5. Verify reuse on next load: instant (step-1 version match), no rebuild.
ls -la "$TMUX_2HTML_BIN/tmux-2html"   # the acquired binary
"$TMUX_2HTML_BIN/tmux-2html" --version
```

## Final Validation Checklist

### Technical Validation
- [ ] `sh -n scripts/ensure_binary.sh` passes; `shellcheck -s sh` clean; no real bashisms (Level 1).
- [ ] Level 2 stub tests all PASS: (a) match ⇒ exit 0 no build/download; (b) stale+zig ⇒ build +
      atomic mv + exit 0 + temp cleaned + only the binary in bin dir; (c) no-zig/no-download ⇒
      exit 1 + stderr + no half-written binary; (d) zig build failure ⇒ exit 1 + temp cleaned;
      (e) staged download.sh ⇒ invoked with the bin DIR + accepted via `[ -x $bin ]`; (g) no $1 ⇒
      stderr + exit 2.
- [ ] Level 3 real zig build: fresh ⇒ builds (~18s) + `--version` ⇒ `tmux-2html 0.1.0`; re-run ⇒
      instant step-1 reuse; stale binary ⇒ rebuilds to 0.1.0.

### Feature Validation
- [ ] Step 1 reuses a version-matching binary without building or downloading.
- [ ] Step 2 builds with `zig build --release=fast --prefix "$tmp" install` (CWD = plugin dir),
      exe at `$tmp/bin/tmux-2html`, atomic `mv` into `$bin_dir/tmux-2html`.
- [ ] Step 3 invokes `download.sh "$bin_dir"` only when executable; accepts via `[ -x $bin ]`.
      (Gracefully skipped until S2 ships.)
- [ ] Step 4 writes one stderr line + `exit 1` on total failure (loader flashes the message).
- [ ] Exit code is the loader interface: 0 ⇒ ready, non-zero ⇒ failed (loader skips binding).
- [ ] Idempotent; never a half-written binary; never a leftover `.build*` temp (atomic mv + EXIT trap).

### Code Quality Validation
- [ ] POSIX-portable (`[ ]`, `=`, `$( )`, quoted expansions, no arrays/`local`, `command -v` not
      `which`, positional `mktemp` template not `-t`). Runs under dash/ash/busybox, not just bash.
- [ ] `set -eu` cascade correct (POSIX §2.8.1): every failure-prone command is an `if` condition or
      non-last `&&`/`||` element ⇒ failures fall through; `cur=$(…)||cur=""` capture idiom avoids
      the dash `x=$(false)` abort.
- [ ] Atomicity: build temp created INSIDE `$bin_dir` (same FS) ⇒ `mv` is a true atomic rename.
- [ ] tmux-agnostic: never calls `tmux` (writes stderr + exits; loader owns `display-message`).
- [ ] `$1` treated as the bin DIR (binary = `$1/tmux-2html`); `plugin_dir` derived from `$0`.
- [ ] `EXPECTED_VERSION="0.1.0"` matches `build.zig.zon` `.version` (single documented sync point).

### Documentation & Deployment
- [ ] NO doc changes (item contract "DOCS: none"; README install flow is P4.M2.T1.S1's job).
- [ ] NO build.zig(.zon)/src/*.zig change (scripts/ already in build.zig.zon `.paths`).
- [ ] NO modification to `tmux-2html.tmux` (Complete contract + P2.M2.T2.S2 edits it in parallel).
- [ ] `chmod +x scripts/ensure_binary.sh`; `.gitkeep` left in place.

---

## Anti-Patterns to Avoid

- ❌ Don't treat `$1` as the FULL binary path. The loader passes `$TMUX_2HTML_BIN` = the bin DIR
  (`$plugin_dir/bin`). The binary is `$1/tmux-2html`. (The earlier external.md §6 example
  `DEST_BIN=$1; BIN_DIR=$(dirname …)` assumed a full path — WRONG for this loader; findings.md §2
  is authoritative. The script in Implementation Patterns uses `bin_dir=$1`.)
- ❌ Don't `source`/`.` this script or remove `set -eu` "to be safe". It is exec'd as a child `sh`
  by the loader; `set -eu` is correct and desired there (ShellCheck SC2187 is about SOURCING a
  set -e script — we are never sourced). The sourced loader (tmux-2html.tmux) is the one that must
  NOT set -e.
- ❌ Don't call `tmux display-message` from ensure_binary.sh — the loader §2 ALREADY owns that
  exact message; calling it yourself double-flashes it AND couples the script to a tmux server
  (un-testable in CI). Write to **stderr** + **exit non-zero**; the loader turns that into the
  status-line message + `binary_ready=0`.
- ❌ Don't build into `/tmp` and `mv` across to `$bin_dir` — cross-filesystem `mv` falls back to a
  non-atomic copy+unlink (EXDEV), so a crash/reader could see a half-written binary. Create the
  temp **inside** `$bin_dir` (`mktemp -d "$bin_dir/.buildXXXXXX"`) so the final `mv` is a true
  atomic rename. (Mirrors src/render.zig renderToFileAtomic.)
- ❌ Don't write the build as a bare `zig build …` statement — under `set -e` a build failure ABORTS
  (skips download, skips the step-4 message, leaves the temp). Wrap the whole build+verify+`mv` as
  the CONDITION of an `if` (POSIX §2.8.1) so failures FALL THROUGH to download, then to step 4.
- ❌ Don't capture `x=$(failing-cmd)` bare under `set -e` — dash ABORTS on it (bash doesn't). Use
  `cur=$(…) || cur=""` (the `||` makes the `$(…)` a non-last list element ⇒ `-e`-exempt).
- ❌ Don't pass the version to `download.sh` or re-verify the downloaded version — S2 downloads the
  LATEST release; re-verifying against `EXPECTED_VERSION` would reject a valid latest release right
  after a version bump. S2 owns tarball version+SHA correctness; S1 just `[ -x ]`-accepts.
- ❌ Don't use `which zig` — non-POSIX, output/exit-status varies. Use `command -v zig`.
- ❌ Don't use `mktemp -t` — `-t` differs GNU vs BSD/macOS. Use the positional template
  `mktemp -d "$bin_dir/.buildXXXXXX"` (portable + places the temp in $bin_dir for atomicity).
- ❌ Don't reference `$1` under `set -u` without a default — use `bin_dir=${1:-${TMUX_2HTML_BIN:-}}`.
- ❌ Don't modify `tmux-2html.tmux`, `build.zig`/`build.zig.zon`, `src/*.zig`, or any docs — this
  task is ONE new file (`scripts/ensure_binary.sh`). The loader is a Complete contract AND P2.M2.T2.S2
  edits it in parallel; build.zig.zon `.version` is the sync partner, not an edit target.
- ❌ Don't implement `download.sh` (that's P2.M3.T1.S2) — guard `[ -x ]` before calling it; until S2
  ships, step 3 is skipped and the script correctly falls through to step 4.
- ❌ Don't use substring version matching (`*"0.1.0"*`) — it wrongly matches `0.1.0-rc1`. Compare
  the FULL `--version` line `tmux-2html $EXPECTED_VERSION` (strictest + simplest).
- ❌ Don't add a `local`/`declare`/arrays/`[[ ]]`/`==`/backticks — keep it POSIX (`[ ]`, `=`,
  `$( )`, quoted expansions) so it runs under dash/ash/busybox, not just bash-as-`sh`.

---

**Confidence Score: 9/10**

*(−1: the live download path is only stub-tested until P2.M3.T1.S2 ships download.sh; the
guard makes this safe — step 3 is skipped and the script falls through to step 4 — but the
real S2→S1 handshake is integration-validated only after S2 lands. Every other path — version
match, real zig build, atomicity, failure modes, POSIX portability — is empirically verified
in this session: `--version` ⇒ `tmux-2html 0.1.0`; `zig build --release=fast --prefix $tmp
install` ⇒ `$tmp/bin/tmux-2html`; the `set -eu` cascade + `x=$(…)||…` idiom + same-FS `mv` +
`mktemp -d` inside bin_dir all confirmed under `sh`; the verbatim script is shellcheck-clean.)*
