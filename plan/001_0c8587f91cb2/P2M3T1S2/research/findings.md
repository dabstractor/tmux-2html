# Research findings — `scripts/download.sh` (P2.M3.T1.S2)

> The authoritative companion to `external.md` (POSIX/GitHub/curl/sha256/tar portability)
> and `codebase_recon.md` (verbatim repo facts). Every load-bearing fact is tagged
> **[LOCAL-VERIFIED]** (read from this repo / run in this shell) or **[EXTERNAL]**
> (see external.md). The verbatim-ready script lives in the PRP's *Implementation
> Patterns*; this file is the *why*.

## 1. Deliverable boundary — ONE new file, no other change

- **CREATE `scripts/download.sh`** (POSIX `sh`, `set -eu`). That is the WHOLE deliverable.
  `scripts/` already holds `ensure_binary.sh` (S1, in progress) + `.gitkeep`, and is already
  in `build.zig.zon` `.paths` ⇒ ships with the package + is cloned by TPM (git, not zig-pkg).
  **No** change to `ensure_binary.sh`, `tmux-2html.tmux`, `build.zig(.zon)`, `src/*.zig`, docs,
  or CI. **[LOCAL-VERIFIED]** `build.zig.zon` `.paths` includes `"scripts"` (external_deps.md §1).

## 2. The handshake with ensure_binary.sh (S1) — VERBATIM, our contract

ensure_binary.sh step 3 (`scripts/ensure_binary.sh:78-86`) **[LOCAL-VERIFIED]**:

```sh
if [ -x "$plugin_dir/scripts/download.sh" ]; then
    if sh "$plugin_dir/scripts/download.sh" "$bin_dir" 2>/dev/null; then   # ← $1 = bin DIR; stderr SUPPRESSED
        [ -x "$bin" ] && exit 0                                            # ← re-checks executability itself
    fi
fi
```

Implications (all **[LOCAL-VERIFIED]**):
- **`$1` = the bin DIR** (e.g. `…/tmux-2html/bin`), NOT the full binary path. The binary is
  `$1/tmux-2html`. (`bin_dir=${1:-${TMUX_2HTML_BIN:-}}`; `bin="$bin_dir/tmux-2html"`.)
- **ensure_binary.sh suppresses our stderr** (`2>/dev/null`). So our stderr diagnostics are
  for HUMAN/CI debugging only — they never reach the loader's status line. The loader's own
  `tmux display-message "tmux-2html: install failed (see README)"` is the user-facing message
  (tmux-2html.tmux §2, L47-49). **We never call `tmux`** (tmux-agnostic; same as S1).
- **Acceptance is an AND-gate**: download.sh must exit 0 AND place an executable
  `$bin_dir/tmux-2html`. ensure_binary.sh re-`[ -x ]`-checks; it does NOT trust our exit alone.
- ensure_binary.sh passes **no version** and does **not** re-verify the downloaded version (S1
  Anti-Pattern: S2 owns tarball version+SHA). ⇒ download.sh downloads the **latest** release;
  do NOT bake/pin a version.

## 3. The repo-name split (CRITICAL) — URL ≠ product name  [LOCAL-VERIFIED]

- `git config --get remote.origin.url` ⇒ `git@github.com:dabstractor/tmux-ansi2html.git`.
  So the GitHub **repo path segment is `tmux-ansi2html`** (owner `dabstractor`).
- EVERYTHING inside the repo uses `tmux-2html`: binary name (`build.zig:17`), matrix asset
  prefix (`tmux-2html-<triple>`), `--version` (`tmux-2html 0.1.0`), option prefix
  (`@tmux-2html-*`).
- ⇒ the release URL is `https://github.com/dabstractor/tmux-ansi2html/releases/latest/download/<asset>`,
  while the **asset filename** is `tmux-2html-<triple>.tar.xz`. **If you hardcode `tmux-2html`
  as the repo segment, every fetch 404s.** Bake a `REPO` constant (= `dabstractor/tmux-ansi2html`,
  overridable via env `TMUX_2HTML_REPO`), and document the split in the script header. This is
  THE single sync point with the real published repo (bump together on a repo rename/publish).

## 4. The SHA256SUMS.txt contract — authoritative decision (resolves a P4.M1 conflict)

**The conflict.** `external_deps.md` §3 (the P4.M1 CI plan, the INPUT producer, lines 119-122)
packaging step **[LOCAL-VERIFIED]**:

```yaml
      - run: |
          mkdir -p dist && cp zig-out/bin/tmux-2html dist/
          (cd dist && sha256sum tmux-2html > ../SHA256SUMS.txt)   # ← hash of the BARE binary, NOT the tarball
          tar -C dist -cJf ${{ matrix.name }}.tar.xz tmux-2html     # ← tarball created AFTER, never hashed
```

Problems with the current P4.M1 plan:
1. It hashes the **bare binary `tmux-2html`**, not the tarball.
2. It runs **once per matrix job ⇒ 4 files all named `SHA256SUMS.txt`**; the release glob
   `dist/**/SHA256SUMS.txt` (L132) would upload 4 identically-named assets (collision/overwrite bug).

**The authoritative contract download.sh REQUIRES (and P4.M1 must produce — PRD §10 is on our side):**

PRD §10 step 3, literal order: *"download the matching tarball … verify SHA256 against
`SHA256SUMS.txt` → extract into the bin dir."* ⇒ **verify the TARBALL, then extract.**
This is also the secure choice (verify-before-extract prevents malicious-tarball path
traversal during extraction) and the industry-standard `sha256sum -c` convention.

⇒ **download.sh contract (authoritative for THIS PRP; flag for P4.M1 reconciliation):**
- The release publishes a **single** `SHA256SUMS.txt` at the release root, standard format:
  `<64hex>  tmux-2html-<triple>.tar.xz` (one line per platform; two-space separator, optional
  leading `./`, LF or CRLF — we strip `\r`).
- download.sh downloads `tmux-2html-<triple>.tar.xz` + `SHA256SUMS.txt`, computes the
  **tarball** sha256, looks up the line matching the tarball basename, compares. Match ⇒ extract;
  mismatch/missing-line ⇒ fail loudly.
- **Robustness note**: the lookup greps by tarball FILENAME so it works whether SHA256SUMS.txt
  has 1 line (just our platform) or all 4 (the consolidated file). It does NOT depend on line order.

> **Cross-task action:** when P4.M1.T1.S1 is implemented, its packaging step MUST emit a single
> consolidated `SHA256SUMS.txt` of **tarball** hashes (`(cd dist && sha256sum *.tar.xz > SHA256SUMS.txt)`),
> not bare-binary per-matrix files. This PRP's contract is the spec P4.M1 conforms to (S2 ships
> first; S2 defines the contract). Documented in the PRP's Integration Points + Anti-Patterns.

## 5. Platform detection — `$(uname -sm)` → triple  [EXTERNAL + mapping pinned]

`uname -sm` prints e.g. `Linux x86_64` / `Darwin arm64`. Map via a `case` on `"$os-$arch_raw"`
**[LOCAL-VERIFIED]** current host = `Linux x86_64`:

| `uname -s` | `uname -m` | triple |
|---|---|---|
| `Linux`  | `x86_64` / `amd64` | `linux-x86_64` |
| `Linux`  | `aarch64` / `arm64` | `linux-aarch64` |
| `Darwin` | `x86_64` / `amd64` | `macos-x86_64` |
| `Darwin` | `arm64` / `aarch64` | `macos-arm64` |

**GOTCHA**: `uname -m` reports **`arm64`** on macOS Apple Silicon but **`aarch64`** on Linux ARM64.
So you CANNOT normalize arch independently of OS — combine in one `case "$os-$arch_raw"`. Accept
both spellings (`aarch64`|`arm64`, `x86_64`|`amd64`) so we don't break on a quirky kernel. Any
unmatched combo ⇒ stderr + exit non-zero (unsupported platform).

## 6. Fetching — curl/wget, latest-release redirect, draft caveat  [EXTERNAL]

- **Latest-release shortcut** `https://github.com/$REPO/releases/latest/download/<asset>`: GitHub
  302-redirects to the asset blob; works for the **latest PUBLISHED (non-draft, non-prerelease)**
  release. **DRAFT releases are NOT reachable** (need auth via API) — and P4.M1 publishes
  `draft: true`. ⇒ until the maintainer PROMOTES the draft to published, download.sh 404s ⇒
  fails ⇒ loader flashes the message. **This is CORRECT** (no release to download yet). Document it.
- **curl**: `curl -fsSL -o <file> <url>` (`-f` fail-fast no-body on ≥400 exit 22; `-sS` silent+
  show errors; `-L` follow redirect). **[LOCAL-VERIFIED]** curl at `/usr/bin/curl`; **also supports
  `file://`** (perfect for fixture tests). 404/offline ⇒ non-zero.
- **wget**: `wget -q -O <file> <url>` (exit 8 on HTTP error, 4 on network). **[LOCAL-VERIFIED]** at `/usr/bin/wget`.
- **Detection idiom**: prefer curl, fall back to wget: `if command -v curl >/dev/null 2>&1;
  then curl …; elif command -v wget …; else fail "no curl/wget"`. Both absent ⇒ loud failure.
- **For testability**: a `TMUX_2HTML_DL_BASE` env override defaults to
  `https://github.com/$REPO/releases/latest/download`. Tests point it at a local `file://` dir
  (curl fetches the staged tarball + SHA256SUMS.txt with ZERO network). **[LOCAL-VERIFIED]** the
  fixture fetch via `curl -fsSL -o … file://…` works in this shell.

## 7. SHA256 verification — portable compute + robust lookup  [EXTERNAL + EMPIRICALLY VERIFIED]

- **Compute** (try sha256sum, fall back to `shasum -a 256`; both emit `<64hex>␠␠<file>`):
  `hash=$(command -v sha256sum >/dev/null 2>&1 && sha256sum -- "$f" || shasum -a 256 -- "$f")`
  then take field 1 (`awk '{print $1}'` / `cut -d' ' -f1`). **[LOCAL-VERIFIED]** `sha256sum` at
  `/usr/bin/sha256sum`, `shasum` (Perl) at `/usr/bin/core_perl/shasum`.
- **Lookup the expected hash for our tarball** from SHA256SUMS.txt (robust to leading `./`, CRLF,
  one/two-space sep, and the file containing other platforms' lines):
  ```sh
  expected=$(grep -E "[[:space:]]${tname}\$" "$sums" | tr -d '\r' | awk '{print $1}' | head -n1)
  ```
  **[LOCAL-VERIFIED]** this returns exactly the right 64-hex for `tmux-2html-linux-x86_64.tar.xz`
  from a 4-line consolidated file; empty when the line is absent.
- **Compare** case-insensitively (some tools uppercase): `tr '[:upper:]' '[:lower:]'` both sides.
  Mismatch / empty expected ⇒ loud failure (PRD §13: instruct install Zig or place binary manually).
- We **don't** use `sha256sum -c` directly: it checks ALL files in the sums file, but we only
  downloaded ONE tarball. Manual compute+compare is correct + path/CRLF-safe.

## 8. Extraction + atomic install — mirror S1's same-FS temp + rename  [EXTERNAL + EMPIRICALLY VERIFIED]

- **Extraction**: `tar -xJf <tarball> -C "$tmp"` works on GNU tar AND macOS bsdtar (libarchive,
  native xz — no external `xz` needed on macOS). **[LOCAL-VERIFIED]** `tar -xJf` extracts here
  (GNU tar 1.35). The tarball's top-level entry is the bare `tmux-2html` (per external_deps §3
  `-C dist … tmux-2html`) ⇒ after extraction `$tmp/tmux-2html` exists.
- **Atomicity** (PRD §10 "Never leave a half-written binary"): extract into a temp dir created
  **INSIDE `$bin_dir`** (`mktemp -d "$bin_dir/.dlXXXXXX"`) ⇒ same filesystem ⇒ the final
  `mv -f "$tmp/tmux-2html" "$bin_dir/tmux-2html"` is a true atomic `rename(2)` (no EXDEV copy).
  Mirrors `src/render.zig renderToFileAtomic` + S1's same idiom. **[EXTERNAL]** rename(2) atomicity.
- **EXIT trap** cleans the temp on any exit (success or failure); `${tmp:-}` stays `-u`-safe.
- chmod +x the extracted binary before/after the mv (tar preserves the +x bit from the fixture,
  but be explicit: `chmod 0755`).
- **Path-traversal safety**: we verify the tarball hash BEFORE extraction, and extract into a
  throwaway temp (not directly into bin). GNU tar by default also refuses absolute/`..`-escaping
  members with a warning; extracting to a dedicated temp confines any such member.

## 9. The `set -eu` cascade — same discipline as S1 (POSIX §2.8.1)  [EXTERNAL]

Every failure-prone command (curl/wget, the hash compute, grep lookup, compare, tar, mv) is the
**condition of an `if`** or a **non-last** `&&`/`||` element ⇒ failures fall through to the final
loud-failure `exit 1` instead of aborting mid-script. `x=$(…) || x=""` / `if x=$(…)` idiom for
captures (dash aborts on bare `x=$(false)`; bash doesn't). `bin_dir=${1:-${TMUX_2HTML_BIN:-}}`
for `-u`-safe `$1`. **[EXTERNAL]** see external.md §(b)/POSIX §2.8.1.

## 10. Testing approach — self-contained sh stub harness (mirror S1/S2-M2T1S1)  [LOCAL-VERIFIED]

No test framework exists. Sibling PRPs (P2M3T1S1, P2M2T1S1) Level-2 use a **self-contained
bash/sh stub harness**: `work=$(mktemp -d)`; stage fake tools/files; run the script with
controlled PATH/env; `PASS`/`FAIL` echo asserts; `rm -rf "$work"`. For download.sh:
- **Fixture**: build a real `tmux-2html-<triple>.tar.xz` + consolidated `SHA256SUMS.txt` in a
  staged "release dir" (exactly as P4.M1 would, per §4); set `TMUX_2HTML_DL_BASE=file://$rel`
  so download.sh fetches locally with real curl (no network). **[LOCAL-VERIFIED]** this whole
  fixture+fetch+verify+extract flow runs clean in this shell (see §7/§8 empirical checks).
- **Cases**: (a) platform-detect maps `Linux x86_64`→`linux-x86_64` (and force other
  `uname` stubs for macos-arm64 etc.); (b) checksum PASS ⇒ installed + executable + atomic (no
  leftover temp, dest never half-written); (c) checksum MISMATCH (tampered SHA256SUMS.txt) ⇒
  exit non-zero + NO binary installed; (d) missing asset (404/empty base) ⇒ loud failure; (e) no
  curl/wget ⇒ loud failure; (f) unsupported platform ⇒ loud failure; (g) `$1` empty ⇒ exit 2.
- **`uname` stubbing**: for non-host platforms, put a fake `uname` on PATH that prints
  `Darwin arm64` etc.; assert the triple + asset name chosen.

## 11. Edge cases & limits (PRD §0/§13)  [LOCAL-VERIFIED]
- **Offline / 404 / mismatch**: fail loudly (stderr, exit non-zero) — PRD §13. ensure_binary.sh
  then falls to step 4 → loader flashes the message. Never a half-written binary (atomic mv).
- **Concurrent runs**: unique `mktemp -d "$bin_dir/.dlXXXXXX"` per run (last writer wins; both
  produce the same binary). PRD §13 spirit.
- **No curl AND no wget**: loud failure (can't download).
- **Unsupported platform**: loud failure with the detected `uname -sm` (helps the user file a bug).
- **Test safety (PRD §0)**: download.sh never touches tmux; tests need NO tmux server.
