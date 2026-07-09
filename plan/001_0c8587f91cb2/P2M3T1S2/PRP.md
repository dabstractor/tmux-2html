name: "P2.M3.T1.S2 — scripts/download.sh: platform triple → fetch → SHA256 verify → atomic extract (POSIX, tmux-agnostic)"
description: |

---

## Goal

**Feature Goal**: Create `scripts/download.sh` — a POSIX `sh` script (run as a
**child** process by `ensure_binary.sh`, never sourced) that **acquires a
prebuilt `tmux-2html` binary from the latest GitHub release** by: (1) detecting
the platform via `$(uname -sm)` → a **platform triple** (`linux-x86_64` /
`linux-aarch64` / `macos-x86_64` / `macos-arm64`); (2) fetching the matching
`tmux-2html-<triple>.tar.xz` **and** `SHA256SUMS.txt` from the release
(**`curl` preferred, `wget` fallback**); (3) **verifying the tarball's SHA256**
against the line for our tarball basename (**verify-before-extract**); (4)
extracting into a temp dir created **inside the bin dir** and installing via an
**atomic rename** (same-filesystem ⇒ `mv` is a true `rename(2)`, never a
half-written binary). On **any** failure (offline, 404, checksum mismatch,
unsupported platform, no fetch tool, no sha256 tool) it writes a diagnostic to
**stderr** and **exits non-zero** — the loader flashes `tmux display-message
"tmux-2html: install failed (see README)"` and skips binding. **`download.sh`
itself never calls `tmux`** (keeps it tmux-agnostic and unit-testable in CI
without a tmux server — and the caller `ensure_binary.sh` already suppresses our
stderr with `2>/dev/null`, so our diagnostics are for HUMAN/CI debugging only).

**Deliverable** (ONE new file at `/home/dustin/projects/tmux-2html/`):
- **CREATE `scripts/download.sh`** — the complete detect→fetch→verify→extract
  script (`set -eu`; exit code = the caller interface: `0` ⇒ an executable
  `$bin_dir/tmux-2html` was installed, non-zero ⇒ failed). It is invoked by the
  **already-Complete `scripts/ensure_binary.sh`** (P2.M3.T1.S1, step 3) as
  `sh "$plugin_dir/scripts/download.sh" "$bin_dir"`, where **`$1` = the bin DIR**
  (e.g. `…/tmux-2html/bin`), and `$0` = the absolute path to this script.

**Nothing else changes**: do NOT modify `scripts/ensure_binary.sh` (Complete
contract + the loader's download step), `tmux-2html.tmux`, `build.zig`/
`build.zig.zon`, `src/*.zig`, any docs (install flow is documented in the README
by P4.M2.T1.S1 — item contract: "DOCS: none"), or CI (the release pipeline is
P4.M1.T1.S1, Planned; THIS PRP *defines* the SHA256SUMS contract it must conform
to).

**Success Definition**:
- `sh -n scripts/download.sh` passes; `shellcheck -s sh` is clean (ShellCheck
  0.11.0 is installed at `/usr/bin/shellcheck`); no real bashisms (precise grep
  — the word "source" in comments is NOT a bashism).
- **Platform detect**: `$(uname -sm)` maps correctly via a `case` on
  `"$os-$arch_raw"`: `Linux x86_64`→`linux-x86_64`, `Linux aarch64/arm64`→
  `linux-aarch64`, `Darwin x86_64/amd64`→`macos-x86_64`, `Darwin arm64/aarch64`→
  `macos-arm64`. Any other combo ⇒ stderr + `exit 1` (unsupported platform).
  (Both arch spellings accepted: `aarch64`|`arm64`, `x86_64`|`amd64`.)
- **Checksum PASS (fixture)**: with `TMUX_2HTML_DL_BASE=file://$rel` pointing at
  a staged release dir holding a real `tmux-2html-<triple>.tar.xz` + a
  consolidated `SHA256SUMS.txt` (built exactly as P4.M1 will), download.sh
  fetches via real `curl` (no network), verifies the **tarball** hash, extracts,
  atomically installs an **executable** `$bin_dir/tmux-2html`, and `exit 0`.
- **Checksum MISMATCH**: a tampered `SHA256SUMS.txt` (wrong hash for our tarball,
  or our line absent) ⇒ `exit 1` + NO binary installed (no half-written file).
- **Offline / 404 / no published release**: pointing `DL_BASE` at a non-existent
  path ⇒ curl fails (non-zero) ⇒ `exit 1` with a clear message. (Draft releases
  are NOT reachable via `releases/latest/download` ⇒ 404 ⇒ loud failure —
  **correct** until the maintainer promotes the draft to published.)
- **No curl AND no wget** ⇒ loud failure. **No sha256sum AND no shasum** ⇒ loud
  failure. **Unsupported platform** ⇒ loud failure with the detected
  `uname -sm`. **Empty `$1`** ⇒ stderr + `exit 2`.
- **Atomicity**: temp created INSIDE `$bin_dir` ⇒ the final `mv` is a same-FS
  atomic rename; an EXIT trap cleans the temp on any exit; no `.dl*` temp or
  half-written `tmux-2html` survives any path.
- **POSIX portability**: runs under `dash`/`ash`/`busybox sh`, not just
  bash-as-`sh` (the `set -eu` cascade + `x=$(…) || …` capture idiom are POSIX
  §2.8.1-correct). `tar -xJf` works on GNU tar AND macOS bsdtar (native xz).

## User Persona (if applicable)

**Target User**: a tmux user installing the plugin via TPM who does **not** have
`zig` on PATH (and so cannot build from source), and **the plugin's
`ensure_binary.sh`** (step 3) which is the single caller of this script.

**Use Case**: on first plugin load (or after an upgrade), the binary is absent/
stale, `zig` is not installed (or the build failed), so `ensure_binary.sh` falls
through to step 3 and runs `download.sh` to fetch a verified prebuilt binary from
the latest GitHub release.

**User Journey**: `prefix I` (TPM install) → plugin sourced → loader sees no
executable → runs `ensure_binary.sh` → no zig / build failed → runs
`download.sh` → fetches + verifies + extracts the matching release tarball into
`$TMUX_2HTML_BIN` → bindings go live. On any failure: status line shows
`tmux-2html: install failed (see README)`, no bindings, tmux keeps running.

**Pain Points Addressed**: zero-friction install for **non-Zig users** (download a
verified binary), with a hard guarantee the plugin **never crashes tmux**, **never
installs a tampered/corrupt binary** (SHA256 gate), and **never leaves a
half-written binary** (atomic rename) that would silently break every `prefix O`.

## Why

- **PRD §10 step 3 mandates this exact download path** ("detect `$(uname -sm)` →
  map to a platform triple → download the matching tarball from the latest GitHub
  release → verify SHA256 against `SHA256SUMS.txt` → extract into the bin dir")
  and the four platform triples, plus §10's "Never leave a half-written binary
  (atomic rename)" guarantee. This script IS §10 step 3.
- **`ensure_binary.sh` step 3 (P2.M3.T1.S1, Complete) already calls us** with a
  precise handshake (`sh download.sh "$bin_dir" 2>/dev/null`, accept via
  `[ -x $bin ]`). We are its download sibling; S1 ships first and **guards with
  `[ -x download.sh ]`** so it cleanly no-ops until S2 lands, then activates.
- **The script is deliberately tmux-agnostic** (it writes to stderr + exits; the
  *loader* owns `tmux display-message`, and `ensure_binary.sh` even suppresses our
  stderr). This makes the script unit-testable in CI without a tmux server AND
  avoids double-flashing the identical message. Verified call site
  (`tmux-2html.tmux` §2 + `scripts/ensure_binary.sh` step 3).
- **Verify-before-extract is the secure + standard choice** (prevents malicious-
  tarball path traversal during extraction) and matches the industry-standard
  `sha256sum`-sidecar idiom (Starship/Deno/Zellij/Atuin all do this — see
  research/external.md §5). This PRP defines the SHA256SUMS.txt contract that
  P4.M1.T1.S1's release pipeline MUST conform to (S2 ships first; S2 defines the
  contract). **Cross-task flag** is recorded in Integration Points + Anti-Patterns.

## What

### Behavior (`scripts/download.sh` — a NEW file)

A `#!/usr/bin/env sh` script, `set -eu`, that implements this flow (every
failure-prone command is a condition of an `if`/`||` so `set -e` lets failures
**fall through** to a loud `exit 1`, per POSIX §2.8.1):

1. **Resolve inputs + config.**
   - `bin_dir=${1:-${TMUX_2HTML_BIN:-}}` (the bin DIR; `$1` from `ensure_binary.sh`,
     env export as a `-u`-safe fallback); `[ -z ]` guard → stderr + `exit 2`.
     `bin="$bin_dir/tmux-2html"`.
   - `REPO=${TMUX_2HTML_REPO:-dabstractor/tmux-ansi2html}` — **CRITICAL**: the
     published GitHub repo is `dabstractor/tmux-ansi2html` while EVERYTHING inside
     the repo uses `tmux-2html` (binary, `--version`, options, asset prefix).
     Hardcoding `tmux-2html` here would **404 every fetch**.
   - `DL_BASE=${TMUX_2HTML_DL_BASE:-https://github.com/$REPO/releases/latest/download}`
     — overridable for tests (`file://$dir` ⇒ real `curl` fetches a local fixture
     with ZERO network). `latest/download` 302-redirects to the asset blob for the
     newest **non-draft, non-prerelease** release; drafts 404 (correct until
     promoted).
2. **Register an EXIT trap** that removes the temp dir (`tmp`, empty until set) on
   any exit — reinforces "never half-written / never leftover temp".
3. **Platform detect**: `os=$(uname -s)`; `arch_raw=$(uname -m)`; `case
   "$os-$arch_raw"` → `triple`. Any unmatched combo ⇒ stderr (with the detected
   `uname -sm`) + `exit 1`. Then `tname="tmux-2html-$triple.tar.xz"`,
   `url="$DL_BASE/$tname"`, `sums_url="$DL_BASE/SHA256SUMS.txt"`.
4. **Create the temp INSIDE `$bin_dir`** (`mktemp -d "$bin_dir/.dlXXXXXX"`; PID+
   epoch `mkdir -m 700` fallback) ⇒ same filesystem ⇒ the final `mv` is an atomic
   `rename(2)`. Mirrors `src/render.zig renderToFileAtomic` + S1's same idiom.
5. **Fetch both files** via a `fetch()` helper (curl preferred `curl -fsSL -o`,
   wget fallback `wget -q -O`; both absent ⇒ return 3). Tarball fetch failure ⇒
   offline/no-published-release message + `exit 1`; no-fetch-tool ⇒ distinct
   message + `exit 1`. Checksum manifest fetch failure ⇒ same pattern.
6. **Verify the TARBALL SHA256** (verify-before-extract): compute via `sha256sum`
   (fallback `shasum -a 256`), take field 1; look up the expected hash for our
   tarball **basename** in `SHA256SUMS.txt` (robust grep + `tr -d '\r'` + awk
   field 1 + `head -n1`, so it works for a 1-line or 4-line consolidated file);
   compare **case-insensitively**. Empty expected OR mismatch ⇒ stderr + `exit 1`,
   NO extraction, NO binary installed.
7. **Extract** `tar -xJf "$tb" -C "$tmp"` (GNU tar + macOS bsdtar both accept `-J`;
   macOS has native xz — no external `xz` needed); verify `$tmp/tmux-2html`
   exists; `chmod 0755`.
8. **Atomic install**: `mv -f "$tmp/tmux-2html" "$bin"` (same-FS rename). `exit 0`.

### Success Criteria

- [ ] `scripts/download.sh` exists, `sh -n` passes, `shellcheck -s sh` clean, no
      real bashisms (`[ ]` not `[[ ]]`; `=` not `==`; `$( )` not backticks; no
      `local`/arrays).
- [ ] `$1` = the bin DIR (binary = `$1/tmux-2html`); empty `$1` ⇒ stderr + `exit 2`.
- [ ] Platform detect maps all 4 targets (both arch spellings); others ⇒ `exit 1`
      with the detected `uname -sm` in the message.
- [ ] Checksum PASS (fixture, `TMUX_2HTML_DL_BASE=file://…`) ⇒ installed +
      executable + atomic (no leftover temp, dest never half-written) + `exit 0`.
- [ ] Checksum MISMATCH (tampered SHA256SUMS.txt / our line absent) ⇒ `exit 1` +
      NO binary installed + temp cleaned.
- [ ] Offline / 404 (non-existent `DL_BASE`) ⇒ `exit 1` + clear message + temp
      cleaned. No curl/wget ⇒ distinct message + `exit 1`. No sha256 tool ⇒ `exit 1`.
- [ ] Never a half-written binary and never a leftover `.dl*` temp after any run
      (atomic `mv` + EXIT trap).
- [ ] Never calls `tmux` (writes stderr + exits; caller suppresses stderr, loader
      owns `display-message`).
- [ ] No modification to `ensure_binary.sh`, `tmux-2html.tmux`, `build.zig(.zon)`,
      `src/*.zig`, any docs, or CI.

## All Needed Context

### Context Completeness Check

_Passes the "No Prior Knowledge" test_: the exact call site that invokes this
script is quoted verbatim below (`scripts/ensure_binary.sh` step 3 — read in full
this session); the loader (`tmux-2html.tmux` §2) is read in full and its
fast-path + `display-message` ownership confirmed (line 42 `[ -x $bin ]` fast-
path; line 47-48 `if ! sh ensure_binary.sh …; then display-message`); the **repo
name split is empirically verified** (`git config --get remote.origin.url` ⇒
`git@github.com:dabstractor/tmux-ansi2html.git` ⇒ repo segment `tmux-ansi2html`);
the asset naming is pinned to PRD §10 + the P4.M1 matrix (`tmux-2html-<triple>` +
`tar.xz` + `SHA256SUMS.txt`, per `architecture/external_deps.md` §3); all host
tools are **empirically verified present** (curl/wget/sha256sum/shasum/tar at
their `/usr/bin` paths; shellcheck 0.11.0; current host `uname -sm` = `Linux
x86_64`); the `set -eu` cascade + `x=$(…) || …` capture idiom are confirmed
under `sh` (POSIX §2.8.1); `mktemp -d "$bin_dir/.dlXXXXXX"` inside the bin dir is
confirmed (same-FS atomic `mv`); and every gotcha (`$1` = bin DIR; child not
sourced; stderr suppressed by caller; verify-the-tarball-not-bare-binary;
`arm64`-on-macOS-vs-`aarch64`-on-Linux; draft-releases-404) is pinned in
`research/findings.md` + `research/external.md`. The verbatim-ready script
(shellcheck-validatable) is in Implementation Patterns. An implementer who has
never seen this codebase can ship it from this PRP + the cited files.

### Documentation & References

```yaml
# MUST READ — the ONE caller of this script (quoted verbatim below; its step 3 IS our contract)
- file: scripts/ensure_binary.sh
  why: "Step 3 (L78-86, [LOCAL-VERIFIED]): `if [ -x \"$plugin_dir/scripts/download.sh\" ];
        then if sh \"$plugin_dir/scripts/download.sh\" \"$bin_dir\" 2>/dev/null; then
        [ -x \"$bin\" ] && exit 0; fi; fi`. KEY: $1 = the bin DIR (binary = $1/tmux-2html);
        our stderr is SUPPRESSED (2>/dev/null) — diagnostics are HUMAN/CI-only; the loader's
        `tmux display-message \"tmux-2html: install failed (see README)\"` is the user-facing
        message. Acceptance is an AND-gate: download.sh must exit 0 AND place an executable
        $bin_dir/tmux-2html (ensure_binary re-[ -x ]-checks; it does NOT trust our exit alone).
        ensure_binary passes NO version and does NOT re-verify the downloaded version ⇒ we
        download the LATEST release (do NOT bake/pin a version)."
  pattern: "POSIX sh child script (set -eu safe — never sourced). It is invoked via `sh`,
            so +x is not strictly required but is the [ -x ]-tested + directly-runnable convention."
  gotcha: "DO NOT modify this file — it is a Complete contract (P2.M3.T1.S1). download.sh is
           its step-3 DEPENDENCY, not its peer. ensure_binary.sh guards with [ -x download.sh ],
           so until THIS task ships step 3 cleanly no-ops → falls through to step 4 (exit 1)."

# MUST READ — the loader that owns the user-facing message + fast-path (READ ONLY)
- file: tmux-2html.tmux
  why: "§2 (L42-48, [LOCAL-VERIFIED]): the loader FAST-PATHS on `[ -x \"$TMUX_2HTML_BIN/tmux-2html\" ]`
        → directly proceeds (does NOT call ensure_binary at all). Only when the binary is NOT
        executable does it run `if ! sh ensure_binary.sh \"$TMUX_2HTML_BIN\"; then tmux
        display-message \"tmux-2html: install failed (see README)\"`. So the WHOLE ensure→download
        cascade is reached only for a missing/non-exec binary. The loader owns display-message;
        we NEVER call tmux. §1 exports TMUX_2HTML_BIN (= $plugin_dir/bin)."
  gotcha: "DO NOT modify — Complete contract (P2.M2.T1.S1) AND P2.M2.T2.* edit it. We are 2 levels
           below it (loader → ensure_binary → download); our only seam is the exit code."

# MUST READ — the repo-name split (CRITICAL — URL ≠ product name)
- file: .git/config   # or run: git config --get remote.origin.url
  why: "[LOCAL-VERIFIED] `git@github.com:dabstractor/tmux-ansi2html.git` ⇒ the GitHub repo path
        segment is `tmux-ansi2html` (owner `dabstractor`). EVERYTHING inside the repo uses
        `tmux-2html` (binary name, matrix asset prefix `tmux-2html-<triple>`, --version
        `tmux-2html 0.1.0`, option prefix `@tmux-2html-*`). ⇒ the release URL is
        `https://github.com/dabstractor/tmux-ansi2html/releases/latest/download/<asset>` while
        the ASSET filename is `tmux-2html-<triple>.tar.xz`. If you hardcode `tmux-2html` as the
        repo segment, EVERY fetch 404s. Bake `REPO=dabstractor/tmux-ansi2html` (overridable via
        env `TMUX_2HTML_REPO`) — THE single sync point with the real published repo."
  critical: "This is the #1 way a naive implementation silently fails (every release URL 404s).
             Verify with `git config --get remote.origin.url` before shipping."

# MUST READ — the asset + SHA256SUMS naming the INPUT producer (P4.M1) must conform to
- file: plan/001_0c8587f91cb2/architecture/external_deps.md
  why: "§3 (the P4.M1 CI plan, [LOCAL-VERIFIED]) shows the matrix names (`tmux-2html-linux-x86_64`
        etc.), `tar.xz` (not gz), and the current packaging step. NOTE THE CONFLICT (findings.md §4):
        external_deps §3 currently hashes the BARE binary `tmux-2html` and runs once-per-matrix ⇒
        4 files all named `SHA256SUMS.txt` (collision/overwrite bug). THIS PRP's contract (verify
        the TARBALL against a single consolidated `SHA256SUMS.txt`) is AUTHORITATIVE; P4.M1.T1.S1
        must reconcile its packaging step to `(cd dist && sha256sum *.tar.xz > SHA256SUMS.txt)`."
  critical: "download.sh verifies the TARBALL hash (not the bare binary), against a single
             consolidated SHA256SUMS.txt at the release root. P4.M1 must produce THAT. Our
             basename-grep lookup is robust whether SHA256SUMS.txt has 1 line or all 4."

# MUST READ — the consolidated research (every load-bearing fact, verified in-repo)
- file: plan/001_0c8587f91cb2/P2M3T1S2/research/findings.md
  why: "EVERY mechanic is here + [LOCAL-VERIFIED]: the deliverable boundary (§1 — ONE file, no
        ensure/loader/zig/docs/CI change), the ensure_binary step-3 contract verbatim (§2 —
        $1=bin-DIR, stderr suppressed, accept via [ -x ], download the LATEST), the repo-name
        split (§3), the SHA256SUMS.txt contract + P4.M1 conflict resolution (§4), platform
        detection incl. the arm64/aarch64 + amd64/x86_64 dual-spelling gotcha (§5), fetching
        incl. TMUX_2HTML_DL_BASE for fixture tests + the draft-release-404 caveat (§6), SHA256
        compute/lookup/compare (§7), extraction + atomicity via same-FS temp (§8), the set -eu
        cascade idiom (§9), the self-contained sh stub test approach (§10), all edge cases (§11)."
- file: plan/001_0c8587f91cb2/P2M3T1S2/research/external.md
  why: "Canonical external references: GitHub `releases/latest/download/<asset>` redirect +
        draft/prerelease exclusion (§1), curl `-fsSL -o`/wget `-q -O` flags + exit codes + curl
        `file://` support (§2), sha256sum/shasum two-space output + portable detection (§3), tar
        `-xJf` works on GNU tar + macOS bsdtar (native xz, no external xz) (§4), real-world
        install-script idioms (Starship/Deno/Zellij/Atuin) (§5). NOTE: external.md had no web
        access during its run — POSIX/tool URLs are canonical-recalled (stable); the idioms are
        authoritative and [LOCAL-VERIFIED] where re-checked in findings.md."
  critical: "The real projects use a `<asset>.sha256` sidecar OR a pinned hash; we use the
             consolidated SHA256SUMS.txt + basename-grep (no per-release script edit needed)."

# MUST READ — the PRD contract
- file: PRD.md
  why: "§10 step 3 is the literal download spec this script implements (detect uname -sm →
        triple → fetch tarball → verify SHA256 against SHA256SUMS.txt → extract into bin dir;
        atomic rename; never half-written). §10 lists the 4 platform triples. §13 (offline /
        mismatch → fail loudly with instructions to install Zig or place a binary manually;
        concurrent runs). §0 (CRITICAL SAFETY — download.sh never touches tmux)."
  section: "§0", "§10", "§13"

# MUST READ — the sibling PRP (mirror its style/discipline; same POSIX shell contract family)
- file: plan/001_0c8587f91cb2/P2M3T1S1/PRP.md
  why: "S1 (ensure_binary.sh, Complete) is the script that CALLS us. Its PRP shows the EXACT
        conventions to mirror: the `set -eu` POSIX §2.8.1 fall-through cascade, the `x=$(…) || …`
        capture idiom, same-FS `mktemp` for atomic `mv`, the EXIT-trap `${tmp:-}` idiom, the
        self-contained sh stub test harness, the shellcheck/bashism-grep Level-1 checks. Our
        script follows the same discipline."

# MUST READ — the Zig-side atomic-write precedent (same idiom, different language)
- file: src/render.zig
  why: "renderToFileAtomic is the proven in-repo atomic-write idiom: create a temp IN THE SAME
        DIRECTORY as the target (same FS ⇒ rename is atomic, no EXDEV), write, rename(temp→target),
        cleanup on error. Our `mktemp -d \"$bin_dir/.dlXXXXXX\"` + `mv` into `$bin_dir` is the
        shell analogue."
  section: "renderToFileAtomic doc comment"

# External (stable, canonical-recalled — re-confirm exact GitHub doc slugs before user-facing citation)
- url: https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases
  why: "Documents GitHub's `releases/latest/download/<asset>` permalink: a 302 redirect to the
        published release asset blob. Works ONLY for the latest NON-draft, NON-prerelease release;
        returns 404 otherwise. Justifies our `DL_BASE` default + the draft-release caveat."
- url: https://curl.se/docs/manpage.html
  why: "`-f` (fail-fast, no body on HTTP ≥400, exit 22), `-s` (silent), `-S` (show errors),
        `-L` (follow redirects), `-o <file>`. Documents curl `file://` support (for fixture
        tests). 404/offline ⇒ non-zero exit."
- url: https://www.gnu.org/software/wget/manual/wget.html
  why: "`-q` (quiet), `-O <file>` (write to file). Exit 8 on HTTP error, 4 on network failure."
- url: https://www.gnu.org/software/coreutils/manual/html_node/sha2-utilities.html
  why: "`sha256sum` output format: `<64hex>␠␠<file>` (two spaces); extract field 1 for the hash.
        Portable detection: prefer `sha256sum`, fall back to `shasum -a 256` (macOS)."
- url: https://www.gnu.org/software/tar/manual/html_node/gzip.html
  why: "`tar -J` selects the xz filter; `-x` extracts. Accepted by GNU tar AND macOS bsdtar
        (libarchive), which has built-in xz (no external `xz` utility needed on macOS)."
- url: https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html#tag_18_08_01
  why: "POSIX §2.8.1: under `set -e`, `-e` is IGNORED for commands in an if/while CONDITION and
        for any NON-LAST command of an &&/|| list. This is why each fetch/verify/extract failure
        (wrapped as an `if`/`||` condition) FALLS THROUGH to the loud exit instead of aborting."
  critical: "Only the explicit `exit 1`s are the non-zero terminations."
- url: https://pubs.opengroup.org/onlinepubs/9699919799/functions/rename.html
  why: "`rename()` is atomic ONLY within one filesystem; cross-FS ⇒ EXDEV (mv then falls back to
        non-atomic copy+unlink). JUSTIFIES creating the temp INSIDE $bin_dir (same FS by
        definition) so the final mv is a true atomic rename."
  critical: "Never extract-then-mv across filesystems — that can leave a half-written binary."
```

### Current Codebase tree (relevant subset)

```bash
tmux-2html.tmux       # §2 fast-paths on [ -x $bin ]; on fail runs ensure_binary.sh; owns display-message.   ← READ ONLY (DO NOT MODIFY)
scripts/ensure_binary.sh  # Step 3 (L78-86) CALLS us: `sh download.sh "$bin_dir" 2>/dev/null`; accept [ -x ]. ← READ ONLY (Complete)
build.zig.zon         # `.version="0.1.0"` (we DON'T pin a version — we download latest). `scripts` in .paths. ← READ ONLY
src/render.zig        # renderToFileAtomic — the in-repo atomic-write precedent (same-FS temp).               ← READ ONLY
scripts/.gitkeep      # placeholder; leave it.
PRD.md                # §0, §10, §13.                                                                          ← READ ONLY
# Host tools [LOCAL-VERIFIED]: curl/wget/sha256sum/shasum/tar all at /usr/bin; shellcheck 0.11.0 at /usr/bin/shellcheck.
# git remote = git@github.com:dabstractor/tmux-ansi2html.git  (REPO segment = tmux-ansi2html, NOT tmux-2html).
# uname -sm = Linux x86_64. /bin/sh -> bash here, but the script MUST stay dash/ash/busybox-portable; shellcheck -s sh enforces it.
```

### Desired Codebase tree with file responsibilities

```bash
scripts/download.sh   # NEW. POSIX sh child script (set -eu): detect uname-sm → triple → fetch
                       #   tmux-2html-<triple>.tar.xz + SHA256SUMS.txt (curl|wget) → verify the TARBALL
                       #   sha256 → tar -xJf into a same-FS temp → atomic mv into $bin_dir. Exit code =
                       #   caller interface. NEVER calls tmux (writes stderr; ensure_binary.sh suppresses
                       #   it; loader owns display-message). EXIT trap cleans temp. Downloads the LATEST
                       #   release (no baked version). REPO=dabstractor/tmux-ansi2html (overridable).
# (No other files change. .gitkeep stays. ensure_binary.sh / tmux-2html.tmux / build.* / src/*.zig / docs / CI untouched.)
```

### Known Gotchas of our codebase & Library Quirks

```sh
# CRITICAL (URL ≠ product name — the repo-name split): the published GitHub repo is
#   dabstractor/tmux-ansi2html, but EVERYTHING inside the repo is named tmux-2html (binary,
#   asset prefix tmux-2html-<triple>, --version, @tmux-2html-* options). So the release URL is
#   https://github.com/dabstractor/tmux-ansi2html/releases/latest/download/<asset> while the
#   ASSET filename is tmux-2html-<triple>.tar.xz. Bake REPO=dabstractor/tmux-ansi2html
#   (overridable via TMUX_2HTML_REPO). If you hardcode tmux-2html as the repo segment, EVERY
#   fetch 404s. [LOCAL-VERIFIED] git config --get remote.origin.url.

# CRITICAL ($1 = the bin DIR, NOT the binary path): ensure_binary.sh step 3 does
#   sh "$plugin_dir/scripts/download.sh" "$bin_dir"
# so $1 is the DIRECTORY (…/tmux-2html/bin). The binary is "$1/tmux-2html".

# CRITICAL (this is a CHILD sh, never sourced): ensure_binary.sh runs `sh ".../download.sh" …`
# (an exec'd subshell), NOT `source`/`.`. So `set -eu` only affects the child — it can NEVER
# abort the user's `source-file` / `prefix I` (ShellCheck SC2187 is about SOURCING a set -e
# script — we are never sourced).

# CRITICAL (we MUST NOT call tmux): the loader ALREADY owns the user-facing
#   tmux display-message "tmux-2html: install failed (see README)"
# AND ensure_binary.sh SUPPRESSES our stderr (2>/dev/null) when it calls us. So our stderr is
# HUMAN/CI-only. On failure we write ONE line(s) to STDERR and exit non-zero; the loader turns
# that into the status-line message + sets binary_ready=0. We satisfy §10's "fail loudly" via
# exit code; the user-facing loud message is the loader's.

# CRITICAL (verify the TARBALL, not the bare binary): PRD §10 order is "verify SHA256 against
#   SHA256SUMS.txt → extract". So we hash the .tar.xz and compare to the line in SHA256SUMS.txt,
#   THEN extract. This is also the SECURE choice (verify-before-extract prevents malicious-tarball
#   path traversal during extraction). The current P4.M1 plan (external_deps §3) hashes the bare
#   binary — that is the conflict; THIS contract (verify the tarball) is authoritative for S2 and
#   P4.M1 must conform. Our basename-grep lookup works for a 1-line or 4-line SHA256SUMS.txt.

# CRITICAL (atomicity — never half-written): `mv`/`rename(2)` is atomic ONLY on the SAME
# filesystem (cross-FS ⇒ EXDEV ⇒ non-atomic copy+unlink). So the temp dir is created INSIDE
# $bin_dir (`mktemp -d "$bin_dir/.dlXXXXXX"`) — same FS by definition — so the final `mv -f
# $tmp/tmux-2html $bin` is a true atomic rename. Mirrors src/render.zig renderToFileAtomic.
# NEVER extract into /tmp and mv across.

# CRITICAL (uname -m arch spelling differs by OS): uname -m reports `arm64` on macOS Apple
#   Silicon but `aarch64` on Linux ARM64; some kernels report `amd64` instead of `x86_64`. So
#   you CANNOT normalize arch independently of OS — combine in ONE `case "$os-$arch_raw"` and
#   accept BOTH spellings (aarch64|arm64, x86_64|amd64). A combined case is the only correct map.

# CRITICAL (set -eu cascade — POSIX §2.8.1): every failure-prone command (fetch, hash compute,
#   grep lookup, compare, tar, mv) MUST be either (a) the condition of an `if`, or (b) a non-last
#   element of an &&/|| list, so a failure FALLS THROUGH to the loud exit instead of aborting
#   mid-script (skipping later messages + leaving temp). Only the explicit `exit 1`s are the
#   non-zero terminations. Do NOT write a bare `tar -xJf …` or `mv …` as a statement.

# PITFALL (x=$(cmd) under set -e is a portability trap): in dash/POSIX sh, `x=$(false)` ABORTS;
#   in bash it does NOT. Capture safely as a non-last list element. For our pipelines that END in
#   awk/head/tr (which always exit 0), the pipeline exit is 0 even on upstream failure, so a bare
#   `actual=$(sha256sum … | awk …)` is safe in practice — but for the mktemp capture use the
#   `tmp=$(…) || { fallback }` idiom (research/external.md §b.7, mirror S1).

# GOTCHA (command -v, NOT which): `command -v curl >/dev/null 2>&1` is the POSIX existence test.
#   `which` is non-POSIX + its output/exit-status varies across platforms.

# GOTCHA (mktemp -t is unportable): the `-t` flag differs GNU (deprecated template) vs BSD/macOS
#   (a prefix in $TMPDIR). Use the POSITIONAL template form `mktemp -d "$bin_dir/.dlXXXXXX"`
#   (≥3 trailing X) — portable across GNU/BSD/busybox AND places the temp inside $bin_dir (same
#   FS). Provide a PID+epoch `mkdir -m 700` fallback only if mktemp is absent (rare).

# GOTCHA (set -u + $1): referencing $1 with no arg aborts under set -u. Use
#   `bin_dir=${1:-${TMUX_2HTML_BIN:-}}` (default-expansion is -u-safe) + a `[ -z ]` guard.

# GOTCHA (the EXIT trap + set -e): reference tmp with `${tmp:-}` so it stays -u-safe even before
#   tmp is assigned. End the trap body with `|| :` so a failing rm never makes the trap return
#   non-zero. (An inline trap avoids ShellCheck SC2329 "function never invoked".)

# GOTCHA (draft releases are NOT reachable): releases/latest/download 302-redirects to the asset
#   ONLY for the newest NON-draft, NON-prerelease release. P4.M1 publishes `draft: true`, so until
#   the maintainer PROMOTES the draft, download.sh 404s ⇒ fails ⇒ loader flashes the message.
#   This is CORRECT (no published release to download yet). Documented in the script header.

# GOTCHA (SHA256SUMS.txt format robustness): standard `<64hex>␠␠<file>` lines; may have a leading
#   `./`, CRLF endings, one or two spaces, and lines for OTHER platforms' tarballs. Strip `\r`
#   (tr -d '\r'), grep by the tarball BASENAME at end-of-line, take awk field 1 (the hash), and
#   head -n1 (first match). Compare case-insensitively (some tools uppercase). We do NOT use
#   `sha256sum -c` (it verifies ALL listed files; we only downloaded ONE tarball).

# GOTCHA (tar -xJf portability): GNU tar needs an xz backend (the `xz` binary or liblzma; most
#   distros fine, minimal images can fail). macOS bsdtar (libarchive) has BUILT-IN xz — no
#   external xz needed. `tar -xJf` is explicit; if a target GNU-tar lacks xz, the user gets a
#   clear extract-failure message (and should install xz-utils or use the zig-build path).
```

## Implementation Blueprint

### Data models and structure

N/A — this is a stateless POSIX shell script. The only "data" is the baked
`REPO` literal (`dabstractor/tmux-ansi2html`, the single sync point with the
published repo), the derived platform `triple` + `tname`, and the exit code
(0 = installed, non-zero = failed), which is the single seam to `ensure_binary.sh`.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: CREATE scripts/download.sh
  - IMPLEMENT: the full detect→fetch→verify→extract flow EXACTLY as the verbatim-ready
    script in "Implementation Patterns & Key Details" below.
  - SHEBANG: `#!/usr/bin/env sh` (POSIX sh; the caller runs it via `sh`, but the
    shebang makes it directly executable too). `set -eu` at the top.
  - CONFIG: `REPO=${TMUX_2HTML_REPO:-dabstractor/tmux-ansi2html}`;
    `DL_BASE=${TMUX_2HTML_DL_BASE:-https://github.com/$REPO/releases/latest/download}`.
  - INPUTS: `bin_dir=${1:-${TMUX_2HTML_BIN:-}}` (bin DIR; guard `[ -z ]` → stderr +
    exit 2); `bin="$bin_dir/tmux-2html"`.
  - TRAP: `tmp=""; trap '[ -n "${tmp:-}" ] && [ -d "${tmp:-}" ] && rm -rf -- "${tmp:-}" 2>/dev/null || :' EXIT`
  - PLATFORM: `os=$(uname -s)`; `arch_raw=$(uname -m)`; `case "$os-$arch_raw"` →
    triple (Linux-x86_64|amd64, Linux-aarch64|arm64, Darwin-x86_64|amd64,
    Darwin-arm64|aarch64); else stderr+exit 1.
  - FETCH: a `fetch()` helper (curl `-fsSL -o` preferred, wget `-q -O` fallback,
    else return 3). Fetch tarball + SHA256SUMS.txt into the temp; each fetch wrapped
    in `if ! fetch …` → message + exit 1 on failure.
  - VERIFY: compute tarball sha256 (sha256sum | awk field1, fallback shasum -a 256);
    grep expected for our basename + `tr -d '\r'` + awk field1 + `head -n1`; compare
    case-insensitively; empty/mismatch → message + exit 1.
  - EXTRACT+INSTALL: `tar -xJf "$tb" -C "$tmp"`; verify `$tmp/tmux-2html`; `chmod 0755`;
    `mv -f "$tmp/tmux-2html" "$bin"`; exit 0.
  - FOLLOW pattern: POSIX §2.8.1 fall-through cascade; same-FS atomic temp
    (src/render.zig renderToFileAtomic; S1 PRP); basename-grep SHA256 lookup
    (research/findings.md §7).
  - NAMING: snake_case vars (bin_dir, bin, os, arch_raw, triple, tname, url, sums_url,
    tb, sums, actual, expected, a, e, tmp, _ts); the file is download.sh (lowercase,
    matches PRD §10 + the ensure_binary.sh call site).
  - PLACEMENT: scripts/download.sh (NEW file; scripts/ already in build.zig.zon .paths
    ⇒ ships with the package + is cloned by TPM via git).

Task 2: MAKE EXECUTABLE + VALIDATE (every command verified — see Validation Loop)
  - chmod +x scripts/download.sh (the caller invokes via `sh` so +x is not strictly
    required, but it is the [ -x ]-tested + directly-runnable convention).
  - Level 1: sh -n; shellcheck -s sh (0.11.0 at /usr/bin/shellcheck); precise bashism
    grep (comment lines excluded).
  - Level 2 (stubs/fixture, deterministic, PRIMARY): build a REAL tarball + consolidated
    SHA256SUMS.txt in a staged "release dir"; set `TMUX_2HTML_DL_BASE=file://$rel` so
    download.sh fetches locally with REAL curl (no network). Cases: (a) platform-detect
    maps Linux x86_64→linux-x86_64 (+ fake `uname` stubs for the other 3 + an unsupported
    combo); (b) checksum PASS ⇒ installed + executable + atomic + exit 0; (c) checksum
    MISMATCH (tampered SHA256SUMS.txt) ⇒ exit 1 + NO binary; (d) missing asset (404/empty
    base) ⇒ exit 1; (e) no curl/wget ⇒ exit 1; (f) unsupported platform ⇒ exit 1;
    (g) `$1` empty ⇒ exit 2.
  - Level 3 (optional, live — only if a published release exists): point at the real
    GitHub URL (default DL_BASE) and confirm a real fetch+verify+install. NOTE: until
    P4.M1 ships + a release is PROMOTED (non-draft), this will 404 (correct).
  - Level 4 (manual TPM): real plugin install via TPM without zig; observe the binary
    downloaded into $TMUX_2HTML_BIN.
```

### Implementation Patterns & Key Details

```sh
# ===== scripts/download.sh — VERBATIM-READY (run sh -n + shellcheck -s sh against this) =====
#!/usr/bin/env sh
# download.sh — download the latest prebuilt tmux-2html binary (PRD §10 step 3).
# Detects the platform via `uname -sm` → a platform triple → fetches the matching
# `tmux-2html-<triple>.tar.xz` from the latest GitHub release → verifies its SHA256
# against the release's `SHA256SUMS.txt` (verify BEFORE extract) → extracts the
# binary into the bin dir via an ATOMIC rename (temp created inside the bin dir ⇒
# same filesystem). On any failure (offline, 404, checksum mismatch, unsupported
# platform, no fetch tool, no sha256 tool) → stderr + exit non-zero; the caller
# (scripts/ensure_binary.sh step 3) then falls through and the loader flashes
#   tmux display-message "tmux-2html: install failed (see README)"
# We NEVER call tmux ourselves (tmux-agnostic + unit-testable in CI). Never leaves a
# half-written binary (atomic rename) or a leftover temp (EXIT trap).
#
# Invoked by ensure_binary.sh step 3 as:
#   sh "$plugin_dir/scripts/download.sh" "$bin_dir" 2>/dev/null
# ⇒ $1 = the bin DIR (…/tmux-2html/bin); the binary is "$1/tmux-2html".
# Acceptance (AND-gate): exit 0 AND an executable $1/tmux-2html (caller re-[ -x ]-checks;
# it does NOT trust our exit alone). The caller passes NO version and does NOT re-verify
# the downloaded version ⇒ we download the LATEST release (do NOT bake/pin a version).
# `set -eu` is SAFE: we are a child `sh`, never sourced (ShellCheck SC2187).

set -eu

# ---- config (single sync points) --------------------------------------------
# GitHub repo path segment. CRITICAL: the published repo is `dabstractor/tmux-ansi2html`
# while EVERYTHING inside the repo uses `tmux-2html` (binary, --version, options,
# release asset prefix). Hardcoding `tmux-2html` here would 404 EVERY fetch.
# Override via env for forks/mirrors. Bump together with the real published repo.
REPO=${TMUX_2HTML_REPO:-dabstractor/tmux-ansi2html}
# Release download base. Default = the latest-published-release shortcut (GitHub
# 302-redirects to the asset blob). For tests, set TMUX_2HTML_DL_BASE=file://$dir to
# fetch a staged fixture dir with ZERO network (curl supports file://). NOTE: `latest`
# resolves only to the newest NON-draft, NON-prerelease release; drafts (how P4.M1
# publishes) 404 here until promoted — that's CORRECT (no release to download yet).
DL_BASE=${TMUX_2HTML_DL_BASE:-https://github.com/$REPO/releases/latest/download}

# ---- inputs -----------------------------------------------------------------
# $1 = bin dir (caller contract). Default-expand for -u + standalone safety;
# also honor an exported $TMUX_2HTML_BIN as a fallback.
bin_dir=${1:-${TMUX_2HTML_BIN:-}}
if [ -z "$bin_dir" ]; then
    echo "tmux-2html: download.sh: no bin dir given (pass it as \$1)" >&2
    exit 2
fi
bin="$bin_dir/tmux-2html"

# temp cleanup on ANY exit (reinforces "never half-written / never leftover temp").
# Empty until set; `${tmp:-}` stays -u-safe even before tmp is assigned. Inline (not
# a named fn) so shellcheck sees no "unused function" (SC2329); end with `|| :` so a
# failing rm never makes the trap return non-zero.
tmp=""
trap '[ -n "${tmp:-}" ] && [ -d "${tmp:-}" ] && rm -rf -- "${tmp:-}" 2>/dev/null || :' EXIT

# ---- platform detection: $(uname -sm) → triple ------------------------------
# GOTCHA: uname -m reports `arm64` on macOS Apple Silicon but `aarch64` on Linux
# ARM64; some kernels report `amd64` not `x86_64`. So combine os+arch in ONE case
# (you CANNOT normalize arch independently of OS) and accept BOTH spellings.
os=$(uname -s 2>/dev/null) || os=""
arch_raw=$(uname -m 2>/dev/null) || arch_raw=""
case "$os-$arch_raw" in
    Linux-x86_64|Linux-amd64)    triple=linux-x86_64  ;;
    Linux-aarch64|Linux-arm64)   triple=linux-aarch64 ;;
    Darwin-x86_64|Darwin-amd64)  triple=macos-x86_64  ;;
    Darwin-arm64|Darwin-aarch64) triple=macos-arm64   ;;
    *)
        echo "tmux-2html: download.sh: unsupported platform ($os $arch_raw); please install Zig or place a binary manually (see README)" >&2
        exit 1
        ;;
esac

tname="tmux-2html-$triple.tar.xz"
url="$DL_BASE/$tname"
sums_url="$DL_BASE/SHA256SUMS.txt"

# ---- fetch helper (curl preferred, wget fallback) ---------------------------
# Returns non-zero on failure; the caller wraps each fetch in `if ! fetch …`.
# curl supports file:// (used by the fixture tests); both exit non-zero on 404/offline.
fetch() {
    # $1 = url, $2 = output file
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$2" "$1"            # -f fail-fast on HTTP>=400 (exit 22); -L follow redirect
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$2" "$1"               # exit 8 on HTTP error, 4 on network failure
    else
        return 3                            # no fetch tool
    fi
}

# ---- stage the temp INSIDE bin_dir (same FS ⇒ atomic mv) --------------------
tmp=$(mktemp -d "$bin_dir/.dlXXXXXX" 2>/dev/null) || {
    _ts=$(date +%s 2>/dev/null) || _ts=0
    tmp="$bin_dir/.dl.$$.$_ts"
    mkdir -m 700 "$tmp" 2>/dev/null || tmp=""
}
if [ -z "$tmp" ]; then
    echo "tmux-2html: download.sh: could not create temp dir in $bin_dir" >&2
    exit 1
fi
tb="$tmp/$tname"
sums="$tmp/SHA256SUMS.txt"

# ---- fetch the tarball + the checksum manifest ------------------------------
# NOTE: do NOT write `if ! fetch …; then rc=$?` — the `!` NEGATES the exit status, so
# `$?` in the then-branch is ALWAYS 0 and the `case $rc` can never distinguish the
# "no curl/wget" (rc=3) path. Instead capture the code with `fetch … || rc=$?`
# (a non-last element of a `||` list ⇒ POSIX §2.8.1 exempts it from set -e, and `$?`
# at `rc=$?` is fetch's true exit). A fetch failure then falls through to a loud exit
# (the trap cleans tmp).
rc=0
fetch "$url" "$tb" || rc=$?
if [ "$rc" -ne 0 ]; then
    case $rc in
        3) echo "tmux-2html: download.sh: no curl/wget on PATH; please install Zig or place a binary manually (see README)" >&2 ;;
        *) echo "tmux-2html: download.sh: failed to download $url (offline? no published release yet?)" >&2 ;;
    esac
    exit 1
fi
rc=0
fetch "$sums_url" "$sums" || rc=$?
if [ "$rc" -ne 0 ]; then
    echo "tmux-2html: download.sh: failed to download $sums_url (offline? no published release yet?)" >&2
    exit 1
fi

# ---- SHA256 verify the TARBALL (verify-before-extract) ----------------------
# Compute: try sha256sum, fall back to `shasum -a 256` (macOS has no sha256sum).
# Both emit `<64hex>  <file>`; take field 1. The pipeline ENDS in awk (exit 0) so a
# bare `actual=$(… | awk …)` is set -e-safe (the pipeline exit is awk's = 0).
if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum -- "$tb" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
    actual=$(shasum -a 256 -- "$tb" | awk '{print $1}')
else
    echo "tmux-2html: download.sh: no sha256 tool (need sha256sum or shasum)" >&2
    exit 1
fi
# Lookup the expected hash for OUR tarball basename from SHA256SUMS.txt. Robust to:
# leading `./`, CRLF endings, one/two-space sep, and lines for OTHER platforms'
# tarballs (works whether the file has 1 line or all 4). The pipeline ends in head
# (exit 0) so `expected=$(… | head -n1)` is set -e-safe; empty when no line matches.
expected=$(grep -E "[[:space:]]${tname}\$" "$sums" | tr -d '\r' | awk '{print $1}' | head -n1)
# Case-insensitive compare (some tools uppercase the digest).
a=$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')
e=$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')
if [ -z "$e" ] || [ "$a" != "$e" ]; then
    echo "tmux-2html: download.sh: SHA256 mismatch (or no entry) for $tname" >&2
    echo "  expected: ${expected:-<none>}" >&2
    echo "  actual:   $actual" >&2
    echo "  Please install Zig or place a binary manually (see README)." >&2
    exit 1
fi

# ---- extract + atomic install -----------------------------------------------
# tar -xJf works on GNU tar AND macOS bsdtar (libarchive, native xz — no external
# xz needed on macOS). We verify BEFORE extract (path-traversal safety); extract
# into the throwaway temp (NOT directly into bin). The tarball's top-level entry is
# the bare `tmux-2html` ⇒ after extract `$tmp/tmux-2html` exists.
if ! tar -xJf "$tb" -C "$tmp"; then
    echo "tmux-2html: download.sh: failed to extract $tname (missing xz backend?)" >&2
    exit 1
fi
if [ ! -f "$tmp/tmux-2html" ]; then
    echo "tmux-2html: download.sh: $tname did not contain a 'tmux-2html' entry" >&2
    exit 1
fi
chmod 0755 "$tmp/tmux-2html"
# Atomic install: same-FS rename (temp is inside bin_dir). A reader/crash sees EITHER
# the old binary or the new one, never a partial file.
mv -f "$tmp/tmux-2html" "$bin"

exit 0
# ===== end =====

# WHY REPO=dabstractor/tmux-ansi2html (NOT tmux-2html): git config --get remote.origin.url
#   ⇒ git@github.com:dabstractor/tmux-ansi2html.git. The repo path segment is tmux-ansi2html;
#   the asset FILENAME is tmux-2html-<triple>.tar.xz. Hardcoding tmux-2html as the repo segment
#   404s every fetch. [LOCAL-VERIFIED]
# WHY verify the TARBALL (not the bare binary): PRD §10 order is verify → extract; this is the
#   secure choice (verify-before-extract) and the industry standard. The current P4.M1 plan
#   (external_deps §3) hashes the bare binary per-matrix — that is the CONFLICT; THIS contract
#   (hash the tarball, single consolidated SHA256SUMS.txt) is authoritative; P4.M1 must conform.
# WHY a basename-grep lookup (not `sha256sum -c`): we only downloaded ONE tarball; `sha256sum -c`
#   verifies ALL files listed in SHA256SUMS.txt (the other platforms' tarballs are absent ⇒ it
#   errors). Computing our hash + grepping the matching line + comparing is correct + path/CRLF-safe.
# WHY the temp is INSIDE $bin_dir: `mv`/`rename` is atomic only on the same filesystem (cross-FS
#   ⇒ EXDEV ⇒ non-atomic copy). Same dir ⇒ same FS ⇒ true atomic rename ⇒ never a half-written
#   binary. Mirrors src/render.zig renderToFileAtomic + S1's same idiom.
# WHY `fetch … || rc=$?` (NOT `if ! fetch …; then rc=$?`): the `!` negation DISCARDS the exit
#   status, so `$?` in the then-branch is always 0 and the `case $rc` (distinguishing rc=3
#   "no curl/wget" from generic) NEVER matches. `cmd || rc=$?` is a non-last `||` element
#   (POSIX §2.8.1 ⇒ set -e-exempt) and `$?` at `rc=$?` is fetch's TRUE exit code. (Verified
#   by running Level-2 case (d) against the verbatim script before handoff.)
# WHY stderr + exit (NOT tmux display-message): the loader already owns the user-facing message
#   (tmux-2html.tmux §2), AND ensure_binary.sh SUPPRESSES our stderr (2>/dev/null) when calling us.
#   So our stderr is HUMAN/CI-only; the exit code is the real seam. stderr+exit non-zero is the
#   clean, testable contract.
# WHY download the LATEST (no baked version): the caller (ensure_binary.sh) does NOT pass a version
#   and does NOT re-verify the downloaded version. Pinning/baking a version would reject a valid
#   latest release right after a version bump. We fetch /releases/latest/download/<asset>.
```

### Integration Points

```yaml
CALLER (scripts/ensure_binary.sh step 3 — ALREADY consumes us, DO NOT CHANGE):
  - calls:    `sh "$plugin_dir/scripts/download.sh" "$bin_dir" 2>/dev/null`  (inside `if [ -x download.sh ]`)
  - $1 =      the bin DIR (…/tmux-2html/bin)
  - exit 0 ⇒  ensure_binary re-`[ -x "$bin" ]`-checks ⇒ if true, ensure_binary exit 0 (loader keeps
              binary_ready=1, bindings go live)
  - exit≠0 ⇒  ensure_binary falls through to step 4 (stderr + exit 1) ⇒ loader runs
              `tmux display-message "tmux-2html: install failed (see README)"` + binary_ready=0.
              [WE do NOT call tmux — loader owns it; our stderr is even suppressed by the caller.]
LOADER (tmux-2html.tmux §2 — 2 levels up, READ ONLY):
  - fast-paths on `[ -x "$TMUX_2HTML_BIN/tmux-2html" ]` (L42) → directly proceeds, never calls
    ensure_binary. So the whole ensure→download cascade is reached ONLY for a missing/non-exec binary.
REPO / URL (single sync points in download.sh):
  - REPO=dabstractor/tmux-ansi2html (overridable via TMUX_2HTML_REPO). Bump together with the real
    published repo on a rename/fork. VERIFY with `git config --get remote.origin.url`.
  - DL_BASE defaults to https://github.com/$REPO/releases/latest/download (overridable via
    TMUX_2HTML_DL_BASE; tests point it at file://$dir). latest = newest non-draft/non-prerelease.
RELEASE ASSET CONTRACT (THIS PRP IS AUTHORITATIVE; P4.M1.T1.S1 must conform — CROSS-TASK FLAG):
  - assets: `tmux-2html-<triple>.tar.xz` for triple in {linux-x86_64, linux-aarch64, macos-x86_64,
    macos-arm64}, PLUS a single consolidated `SHA256SUMS.txt` at the release ROOT.
  - SHA256SUMS.txt format: standard `<64hex>  tmux-2html-<triple>.tar.xz` (two-space sep; one line
    per platform). It hashes the TARBALLS, not the bare binary.
  - P4.M1 reconciliation: its packaging step MUST emit `(cd dist && sha256sum *.tar.xz > SHA256SUMS.txt)`
    and upload ONE consolidated file (not 4 per-matrix bare-binary files). download.sh's basename-grep
    lookup tolerates a 1-line or 4-line file, but the bare-binary-per-matrix form would NOT match our
    tarball hashes → it would fail loudly (correctly) until P4.M1 conforms.
BUILD/PACKAGE:
  - scripts/ is ALREADY in build.zig.zon `.paths` ⇒ download.sh ships with the package + is cloned by
    TPM (git clone, not zig-pkg). NO build.zig(.zon) change needed.
DOCS:
  - NO CHANGE — install flow is documented in the README by P4.M2.T1.S1 (item contract: "DOCS: none").
TEST ISOLATION (PRD §0/§13):
  - download.sh is tmux-AGNOSTIC ⇒ Level 1-2 tests need NO tmux server (and NO network when
    TMUX_2HTML_DL_BASE=file://…). Concurrent plugin loads each get a unique mktemp temp (last writer
    wins; both produce the same binary) — PRD §13 spirit.
```

## Validation Loop

### Level 1: Syntax & Style (after creating the script)

```bash
chmod +x scripts/download.sh
sh -n scripts/download.sh && echo "syntax OK"            # POSIX syntax (mandatory)
command -v shellcheck >/dev/null && shellcheck -s sh scripts/download.sh && echo "shellcheck CLEAN" \
  || echo "shellcheck N/A"
# Bashism scan — exclude comment lines (the English word "source"/"local" in comments is NOT a
# bashism). Expect ZERO hits in real code. NOTE: `\[\[` would FALSE-POSITIVE on the legitimate
# POSIX character class `[[:space:]]` used inside the `grep -E "..."` SHA256SUMS lookup string —
# so require `[[` to be a real COMMAND (followed by whitespace/$), not a `[[:class:]]` token.
grep -vnE '^[[:space:]]*#' scripts/download.sh | grep -E '\[\[[[:space:]\$]|[^=!]==[^=]|BASH_SOURCE|declare |[[:space:]]local |[[:space:]]let |<\(|\[[0-9]+\]=' \
  && echo "FAIL: bashisms found" || echo "no bashisms"
# Expected: "syntax OK"; "shellcheck CLEAN" (the script in Implementation Patterns is shellcheck-validatable);
# "no bashisms". (The verbatim script was validated end-to-end: sh -n + shellcheck -s sh CLEAN + a
# 7-case stub/fixture suite all PASS — see the notes in Implementation Patterns.)
```

### Level 2: Stub + fixture tests (PRIMARY — deterministic, no network, no tmux)

```bash
# A self-contained harness: build a REAL tarball + consolidated SHA256SUMS.txt in a staged
# "release dir"; point TMUX_2HTML_DL_BASE=file://$rel so download.sh fetches locally with REAL
# curl (no network). Asserts every branch + atomicity + temp cleanup.
work=$(mktemp -d); repo=$(pwd)

# ---- build a fixture release dir for the HOST triple (linux-x86_64 here) ----
rel="$work/release"; mkdir -p "$rel"
triple="linux-x86_64"   # the host's detected triple (uname -sm = Linux x86_64)
# a fake-but-real binary: prints a version so we can prove it installed.
printf '#!/usr/bin/env sh\necho "tmux-2html 0.1.0"\n' > "$work/fixture-tmux-2html"; chmod +x "$work/fixture-tmux-2html"
tbname="tmux-2html-$triple.tar.xz"
tar -C "$work" -cJf "$rel/$tbname" fixture-tmux-2html       # top-level entry = fixture-tmux-2html...
# WAIT: our script expects the tarball entry named EXACTLY `tmux-2html` (not fixture-...).
# Rebuild with the canonical name:
rm -f "$rel/$tbname"
( cd "$work" && cp fixture-tmux-2html tmux-2html && tar -cJf "$rel/$tbname" tmux-2html && rm -f tmux-2html )
# consolidated SHA256SUMS.txt of the TARBALL (authoritative contract):
( cd "$rel" && sha256sum "$tbname" > SHA256SUMS.txt )

DL="file://$rel"

# ---- (a) platform detect: host maps to linux-x86_64; assert via a dry probe. ----
# (We can't easily assert the triple without re-running detection; instead assert the END-TO-END
#  behavior per case below, which transitively proves detection + asset naming.)
binA="$work/binA"; mkdir -p "$binA"
TMUX_2HTML_DL_BASE="$DL" sh "$repo/scripts/download.sh" "$binA" 2>"$work/errA"; rc=$?
[ "$rc" = 0 ] && echo "PASS a: checksum PASS ⇒ exit 0"
[ -x "$binA/tmux-2html" ] && echo "PASS a: binary installed + executable"
"$binA/tmux-2html" 2>/dev/null | grep -qx 'tmux-2html 0.1.0' && echo "PASS a: installed binary runs"
ls -A "$binA" | grep -qE '^\.dl' && echo "FAIL a: leftover temp" || echo "PASS a: no leftover temp (atomic + trap)"

# ---- (b) checksum MISMATCH: tamper SHA256SUMS.txt for our tarball ⇒ exit 1, NO binary. ----
binB="$work/binB"; mkdir -p "$binB"
rel2="$work/release2"; mkdir -p "$rel2"; cp "$rel/$tbname" "$rel2/"
printf '%s  %s\n' "0000000000000000000000000000000000000000000000000000000000000000" "$tbname" > "$rel2/SHA256SUMS.txt"
out=$(TMUX_2HTML_DL_BASE="file://$rel2" sh "$repo/scripts/download.sh" "$binB" 2>"$work/errB"); rc=$?
[ "$rc" = 1 ] && echo "PASS b: checksum mismatch ⇒ exit 1"
[ ! -e "$binB/tmux-2html" ] && echo "PASS b: NO half-written binary on mismatch"
grep -q 'SHA256 mismatch' "$work/errB" && echo "PASS b: mismatch diagnostic on stderr"

# ---- (c) missing asset (404/empty base): DL_BASE points at an empty dir ⇒ curl 404s. ----
binC="$work/binC"; mkdir -p "$binC"; emptyrel="$work/empty"; mkdir -p "$emptyrel"
out=$(TMUX_2HTML_DL_BASE="file://$emptyrel" sh "$repo/scripts/download.sh" "$binC" 2>"$work/errC"); rc=$?
[ "$rc" = 1 ] && echo "PASS c: missing asset ⇒ exit 1"
grep -q 'failed to download' "$work/errC" && echo "PASS c: download-failure diagnostic"
[ ! -e "$binC/tmux-2html" ] && echo "PASS c: no binary on missing asset"

# ---- (d) no curl/wget ⇒ exit 1 with the distinct message. ----
# To force `command -v curl` AND `command -v wget` to fail while KEEPING sh + the
# core utils runnable, build an isolated PATH dir that symlinks every needed util
# EXCEPT curl/wget. (Do NOT use `PATH=$(mktemp -d)` alone — an empty PATH also lacks
# `sh`, so the `sh script` invocation itself 404s with exit 127.)
binD="$work/binD"; mkdir -p "$binD"; isolbin="$(mktemp -d)"
for _t in sh uname mktemp date mkdir sha256sum grep awk tr head tar chmod mv rm; do
    ln -sf "/usr/bin/$_t" "$isolbin/$_t" 2>/dev/null || :
done
# shasum lives in a Perl sub-dir on some distros; add it too (harmless if absent).
ln -sf "$(command -v shasum 2>/dev/null || echo /bin/true)" "$isolbin/shasum" 2>/dev/null || :
PATH="$isolbin" command -v curl >/dev/null 2>&1 || echo "  (d) curl confirmed absent"
out=$(PATH="$isolbin" TMUX_2HTML_DL_BASE="$DL" sh "$repo/scripts/download.sh" "$binD" 2>"$work/errD"); rc=$?
[ "$rc" = 1 ] && echo "PASS d: no curl/wget ⇒ exit 1"
grep -q 'no curl/wget' "$work/errD" && echo "PASS d: no-fetch-tool diagnostic"
rm -rf "$isolbin"

# ---- (e) unsupported platform via a fake `uname` stub on PATH. ----
binE="$work/binE"; mkdir -p "$binE"; stubbin="$(mktemp -d)"
cat > "$stubbin/uname" <<'EOF'
#!/usr/bin/env sh
# emulate `uname -sm` for an unsupported combo
case "$1" in
  -s) echo "FreeBSD" ;;
  -m) echo "x86_64"  ;;
  *)  uname "$@" ;;   # delegate anything else to the real uname
esac
EOF
chmod +x "$stubbin/uname"
out=$(PATH="$stubbin:/usr/bin:/bin" TMUX_2HTML_DL_BASE="$DL" sh "$repo/scripts/download.sh" "$binE" 2>"$work/errE"); rc=$?
[ "$rc" = 1 ] && echo "PASS e: unsupported platform ⇒ exit 1"
grep -q 'unsupported platform (FreeBSD x86_64)' "$work/errE" && echo "PASS e: message includes detected uname -sm"

# ---- (e2) the OTHER 3 supported triples map correctly (fake uname stubs). ----
mkuname() { printf '#!/usr/bin/env sh\ncase "$1" in -s) echo "%s";; -m) echo "%s";; *) uname "$@";; esac\n' "$1" "$2" > "$stubbin/uname"; }
for combo in "Linux aarch64:linux-aarch64" "Darwin x86_64:macos-x86_64" "Darwin arm64:macos-arm64"; do
    inp="${combo%%:*}"; want="${combo##*:}"
    set -- $inp; mkuname "$1" "$2"
    # point DL_BASE at empty dir ⇒ it will fail at the fetch (asset for that triple absent) but
    # ONLY AFTER detection; assert the url it tried (in the err) contains the expected asset name.
    out=$(PATH="$stubbin:/usr/bin:/bin" TMUX_2HTML_DL_BASE="file://$emptyrel" sh "$repo/scripts/download.sh" "$binE" 2>"$work/errE2"); 
    grep -q "tmux-2html-$want.tar.xz" "$work/errE2" && echo "PASS e2: $inp ⇒ triple $want (url correct)" || echo "FAIL e2: $inp did not yield $want"
done

# ---- (f) empty $1 ⇒ stderr + exit 2 (does not abort caller). ----
out=$(PATH="/usr/bin:/bin" TMUX_2HTML_BIN="" sh "$repo/scripts/download.sh" 2>"$work/errF" || true)
grep -q 'no bin dir given' "$work/errF" && echo "PASS f: missing bin dir ⇒ stderr diagnostic"

rm -rf "$work"
# Expected: every PASS prints; exit codes 0/1/1/1/1 per branch; no leftover temps; never a
# half-written binary; the other 3 triples detected via fake uname stubs.
```

### Level 3: Live release (optional — only when a PUBLISHED release exists)

```bash
# Only meaningful once P4.M1.T1.S1 ships AND the maintainer PROMOTES the draft to published.
# Until then the default URL 404s (draft releases are NOT reachable via releases/latest/download) —
# that is CORRECT (no published release yet). When a release exists:
work=$(mktemp -d); bin="$work/bin"; mkdir -p "$bin"
# unset the override so it uses the real https://github.com/dabstractor/tmux-ansi2html/releases/latest/download
env -u TMUX_2HTML_DL_BASE -u TMUX_2HTML_REPO sh scripts/download.sh "$bin"; echo "exit=$?"
[ -x "$bin/tmux-2html" ] && "$bin/tmux-2html" --version
rm -rf "$work"
# Expected: real fetch + verify + install; --version ⇒ tmux-2html 0.1.0.
```

### Level 4: Manual / interactive (real TPM install without zig — NOT in CI)

```bash
# In a REAL tmux + TPM setup (or an isolated test socket) with zig NOT installed, after `prefix I`:
#   1. TPM clones the repo; loader sees no executable ⇒ runs ensure_binary.sh.
#   2. ensure_binary step 1 (version) N/A; step 2 (zig build) skipped (no zig) ⇒ step 3 download.sh.
#   3. download.sh detects the platform, fetches tmux-2html-<triple>.tar.xz + SHA256SUMS.txt from
#      the latest published release, verifies the tarball SHA256, extracts, atomically installs
#      $TMUX_2HTML_BIN/tmux-2html ⇒ bindings go live.
#   4. On any failure: status line shows `tmux-2html: install failed (see README)`, no bindings,
#      tmux keeps running.
ls -la "$TMUX_2HTML_BIN/tmux-2html"   # the downloaded binary
"$TMUX_2HTML_BIN/tmux-2html" --version
```

## Final Validation Checklist

### Technical Validation
- [ ] `sh -n scripts/download.sh` passes; `shellcheck -s sh` clean; no real bashisms (Level 1).
- [ ] Level 2 stub/fixture tests all PASS: (a) checksum PASS ⇒ installed + executable + atomic + exit 0
      + temp cleaned; (b) checksum mismatch ⇒ exit 1 + NO binary + mismatch diagnostic; (c) missing
      asset ⇒ exit 1 + download-failure diagnostic; (d) no curl/wget ⇒ exit 1 + distinct diagnostic;
      (e) unsupported platform ⇒ exit 1 + message includes detected `uname -sm`; (e2) the other 3
      triples detected via fake `uname` stubs (url contains the right asset name); (f) empty `$1` ⇒
      stderr + exit 2.

### Feature Validation
- [ ] Platform detect maps all 4 targets (both arch spellings); others ⇒ exit 1 with detected
      `uname -sm` in the message.
- [ ] Fetches the tarball + SHA256SUMS.txt (curl preferred, wget fallback) from the latest published
      release; both absent ⇒ loud failure.
- [ ] Verifies the **tarball** SHA256 (not the bare binary) against the basename's line in
      SHA256SUMS.txt; mismatch/absent-line ⇒ loud failure, NO extraction, NO binary installed.
- [ ] Extracts via `tar -xJf` into the temp (verify-before-extract); atomic `mv` into `$bin_dir`.
- [ ] Exit code is the caller interface: 0 ⇒ executable `$bin_dir/tmux-2html` installed, non-zero ⇒
      failed (ensure_binary falls through; loader flashes the message).
- [ ] Downloads the LATEST release (no baked/pinned version); never calls tmux (stderr + exit).

### Code Quality Validation
- [ ] POSIX-portable (`[ ]`, `=`, `$( )`, quoted expansions, no arrays/`local`, `command -v` not
      `which`, positional `mktemp` template not `-t`). Runs under dash/ash/busybox, not just bash.
- [ ] `set -eu` cascade correct (POSIX §2.8.1): every failure-prone command is an `if`/`||` condition
      ⇒ failures fall through to a loud exit; pipelines ending in awk/head/tr are set -e-safe.
- [ ] Atomicity: temp created INSIDE `$bin_dir` (same FS) ⇒ `mv` is a true atomic rename; EXIT trap
      cleans the temp on every path.
- [ ] tmux-agnostic: never calls `tmux` (writes stderr + exits; caller suppresses stderr, loader
      owns `display-message`).
- [ ] `$1` treated as the bin DIR (binary = `$1/tmux-2html`).
- [ ] `REPO=dabstractor/tmux-ansi2html` (overridable via `TMUX_2HTML_REPO`) — verified against
      `git config --get remote.origin.url`.

### Documentation & Deployment
- [ ] NO doc changes (item contract "DOCS: none"; README install flow is P4.M2.T1.S1's job).
- [ ] NO build.zig(.zon)/src/*.zig change (scripts/ already in build.zig.zon `.paths`).
- [ ] NO modification to `scripts/ensure_binary.sh`, `tmux-2html.tmux`, or any CI.
- [ ] `chmod +x scripts/download.sh`; `.gitkeep` left in place.
- [ ] **Cross-task flag recorded**: P4.M1.T1.S1's packaging MUST emit a single consolidated
      `SHA256SUMS.txt` of **tarball** hashes (not 4 per-matrix bare-binary files) to conform to the
      contract THIS script requires.

---

## Anti-Patterns to Avoid

- ❌ Don't hardcode the repo segment as `tmux-2html` — the published repo is
  `dabstractor/tmux-ansi2html` (verify: `git config --get remote.origin.url`). The asset FILENAME is
  `tmux-2html-<triple>.tar.xz`. Hardcoding `tmux-2html` as the repo segment 404s EVERY fetch. Use
  `REPO=${TMUX_2HTML_REPO:-dabstractor/tmux-ansi2html}`.
- ❌ Don't treat `$1` as the FULL binary path. ensure_binary.sh passes the bin DIR
  (`$plugin_dir/bin`). The binary is `$1/tmux-2html`. (Mirror S1's `bin_dir=$1`.)
- ❌ Don't verify the BARE binary's hash. PRD §10 order is verify → extract; we hash the **tarball**
  and compare to its line in SHA256SUMS.txt, THEN extract. This is the secure choice (verify-before-
  extract) and the contract P4.M1 must conform to.
- ❌ Don't use `sha256sum -c` — it verifies ALL files listed in SHA256SUMS.txt (the other platforms'
  tarballs are absent ⇒ it errors). Compute our hash + grep the matching basename line + compare.
- ❌ Don't normalize `uname -m` independently of the OS. `arm64` on macOS vs `aarch64` on Linux ARM
  means a standalone arch map is wrong. Combine os+arch in ONE `case "$os-$arch_raw"` and accept both
  spellings (`aarch64`|`arm64`, `x86_64`|`amd64`).
- ❌ Don't `source`/`.` this script or remove `set -eu` "to be safe". It is exec'd as a child `sh`;
  `set -eu` is correct and desired there (ShellCheck SC2187 is about SOURCING a set -e script — we
  are never sourced).
- ❌ Don't call `tmux display-message` — the loader owns that exact message AND the caller
  (`ensure_binary.sh`) suppresses our stderr (`2>/dev/null`). Calling tmux would double-flash it AND
  couple the script to a tmux server (un-testable in CI). Write to **stderr** + **exit non-zero**.
- ❌ Don't extract into `/tmp` and `mv` across to `$bin_dir` — cross-filesystem `mv` falls back to a
  non-atomic copy+unlink (EXDEV), so a crash/reader could see a half-written binary. Create the temp
  **inside** `$bin_dir` (`mktemp -d "$bin_dir/.dlXXXXXX"`) so the final `mv` is a true atomic rename.
  (Mirrors src/render.zig renderToFileAtomic + S1.)
- ❌ Don't write `if ! fetch …; then rc=$?` to inspect a helper's exit code — the `!`
  NEGATES the status, so `$?` in the then-branch is always 0 and you can NEVER distinguish
  return codes (e.g. the "no curl/wget" rc=3 path). Capture with `fetch … || rc=$?` (a non-last
  `||` element, set -e-safe) so `$?` is fetch's true exit. (This was a real bug, caught by
  validating the verbatim script's Level-2 case (d) before handing off.)
- ❌ Don't write `tar -xJf …` or `mv …` as a bare statement — under `set -e` a failure ABORTS
  (skips the loud message + leaves the temp). Wrap each as the CONDITION of an `if …; then …; else
  rc=$?; …; fi` (or `cmd || rc=$?`) (POSIX §2.8.1) so failures fall through to a loud exit (trap
  cleans the temp).
- ❌ Don't capture `x=$(failing-cmd)` bare under `set -e` — dash ABORTS on it (bash doesn't). For
  `mktemp` use `tmp=$(…) || { fallback }`; for pipelines that END in awk/head/tr the pipeline exit
  is 0 (safe), but be deliberate about it.
- ❌ Don't use `which curl`/`which wget` — non-POSIX, output/exit-status varies. Use `command -v`.
- ❌ Don't use `mktemp -t` — `-t` differs GNU vs BSD/macOS. Use the positional template
  `mktemp -d "$bin_dir/.dlXXXXXX"` (portable + places the temp in $bin_dir for atomicity).
- ❌ Don't reference `$1` under `set -u` without a default — use `bin_dir=${1:-${TMUX_2HTML_BIN:-}}`.
- ❌ Don't bake/pin a version into the URL — the caller downloads the LATEST release and does NOT
  re-verify the downloaded version. Pinning would reject a valid latest release right after a version
  bump. Use `/releases/latest/download/<asset>`.
- ❌ Don't modify `scripts/ensure_binary.sh`, `tmux-2html.tmux`, `build.zig`/`build.zig.zon`,
  `src/*.zig`, any docs, or CI — this task is ONE new file (`scripts/download.sh`). The release
  pipeline is P4.M1.T1.S1's job (Planned); THIS PRP defines the SHA256SUMS contract it conforms to.
