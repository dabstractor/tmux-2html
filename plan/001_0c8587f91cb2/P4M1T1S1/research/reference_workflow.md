# Reference Workflow & Research — P4.M1.T1.S1 (4-target release matrix)

> SOURCED 2026-07-10. The PRIMARY reference is the ACTUAL `aarol/term2html`
> `.github/workflows/build-binaries.yml` (fetched raw from `main`), which the contract
> (item description §1) cites as the VERIFIED shape. term2html's workflow is the
> authoritative source; `architecture/external_deps.md §3` is a (slightly imprecise)
> paraphrase of it. Where they differ, term2html wins.

## 1. The ACTUAL term2html build-binaries.yml (fetched raw — the gold reference)

```yaml
name: Build Binaries

on:
  workflow_dispatch:
  push:
    tags:
      - "v*"

permissions:
  contents: write

jobs:
  build:
    name: ${{ matrix.artifact_name }}
    runs-on: ${{ matrix.os }}
    strategy:
      fail-fast: false
      matrix:
        include:
          - os: ubuntu-latest
            target: x86_64-linux-gnu
            artifact_name: term2html-linux-x64
            extra_flags: ""
          - os: ubuntu-latest
            target: aarch64-linux-gnu
            artifact_name: term2html-linux-arm64
            extra_flags: "-Dsimd=false"
          - os: macos-latest
            target: x86_64-macos
            artifact_name: term2html-macos-x64
            extra_flags: "-Dsimd=false"
          - os: macos-latest
            target: aarch64-macos
            artifact_name: term2html-macos-arm64
            extra_flags: ""

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup Zig
        uses: mlugg/setup-zig@v2
        with:
          version: 0.15.2

      - name: Build
        run: |
          zig build --fetch

          zig build -Doptimize=ReleaseFast -Dtarget=${{ matrix.target }} ${{ matrix.extra_flags }}
        env:
          ZIG_HTTP_MAX_CONNS: 1

      - name: Package
        run: |
          mkdir -p dist
          cp zig-out/bin/term2html dist/
          tar -C dist -czf ${{ matrix.artifact_name }}.tar.gz term2html

      - name: Upload artifact
        uses: actions/upload-artifact@v4
        with:
          name: ${{ matrix.artifact_name }}
          path: ${{ matrix.artifact_name }}.tar.gz
          if-no-files-found: error

  release_draft:
    name: Create release draft
    needs: build
    if: startsWith(github.ref, 'refs/tags/')
    runs-on: ubuntu-latest

    steps:
      - name: Download build artifacts
        uses: actions/download-artifact@v4
        with:
          path: dist

      - name: Create draft release
        uses: softprops/action-gh-release@v2
        with:
          draft: true
          files: dist/**/*.tar.gz
```

### Key facts confirmed from term2html (VERIFIED, primary source)
- **`mlugg/setup-zig@v2` with `version: 0.15.2`** (unquoted) installs Zig onto PATH for
  later `run:` steps. (Web search confirms `goto-bus-stop/setup-zig` is marked
  "unmaintained — please use mlugg/setup-zig instead".)
- **`ZIG_HTTP_MAX_CONNS: 1`** is set as `env:` on the Build step (covers BOTH
  `zig build --fetch` and `zig build`). It IS a real env var — the verified reference uses
  it. (Used to avoid GitHub rate-limiting / connection exhaustion when the package manager
  fetches the ghostty tarball + its ~25 transitive C++ SIMD sub-deps from github.com.)
- **`zig build --fetch`** is run as a separate command (NOT a separate STEP — same `run:`
  block) before `zig build -Dtarget=…`. Pre-populates the global zig cache (`~/.cache/zig/p/`)
  so the build step doesn't re-fetch mid-build; fails fast on dependency-download errors.
- **Matrix `extra_flags`** = `"-Dsimd=false"` on the two CROSS targets
  (`aarch64-linux-gnu` cross on ubuntu; `x86_64-macos` cross on macos-latest arm64) and `""`
  on the two NATIVE targets (`x86_64-linux-gnu` on ubuntu; `aarch64-macos` on macos-latest
  arm64).
- **Binary lands at `zig-out/bin/<name>`** (NOT target-suffixed) — confirmed from our
  `build.zig` (`addExecutable(.{.name="tmux-2html"})` + `installArtifact` + default prefix
  `zig-out/`). So `zig-out/bin/tmux-2html` regardless of `-Dtarget`. term2html does
  `cp zig-out/bin/term2html dist/`.
- **`fail-fast: false`** — one target failing does NOT cancel the others (you still get
  the 3 that succeeded, useful for a partial release investigation).
- **`permissions: contents: write`** at top-level — REQUIRED for action-gh-release.
- **`if: startsWith(github.ref, 'refs/tags/')`** on release_draft — so a `workflow_dispatch`
  on a branch runs ONLY the build matrix (no draft created). Lets you test the build
  pipeline before cutting a real tag.

## 2. What tmux-2html CHANGES vs term2html (PRD §10/§11 driven)

| Aspect | term2html | tmux-2html (THIS task) |
|---|---|---|
| Compression | `tar.gz` (`-czf`) | **`tar.xz` (`-cJf`)** — PRD §11 |
| Checksums | NONE | **ONE consolidated `SHA256SUMS.txt`** — 4 lines (one per tarball) — PRD §10 step 3 |
| Asset naming | `term2html-linux-x64` (mixed) | **`tmux-2html-<PRD-triple>`** where triple ∈ `linux-x86_64`, `linux-aarch64`, `macos-x86_64`, `macos-arm64` — PRD §10 |
| Binary name inside tarball | `term2html` | `tmux-2html` |
| Release draft `files` | `dist/**/*.tar.gz` | flattened tarballs + the single `SHA256SUMS.txt` |

### The PRD-triple ↔ Zig-target mapping (CRITICAL — they are DIFFERENT strings)
| PRD §10 triple (asset name) | Zig `-Dtarget` (build) | Runner | Native/Cross | `-Dsimd=false`? |
|---|---|---|---|---|
| `linux-x86_64`  | `x86_64-linux-gnu`  | `ubuntu-latest` | Native  | no  |
| `linux-aarch64` | `aarch64-linux-gnu` | `ubuntu-latest` | **Cross** | **yes** |
| `macos-x86_64`  | `x86_64-macos`      | `macos-latest`  | **Cross** (host arm64) | **yes** |
| `macos-arm64`   | `aarch64-macos`     | `macos-latest`  | Native  | no  |

So the matrix needs TWO columns: `target` (for `-Dtarget=`) AND `triple` (for the asset/
artifact/tarball name that `download.sh` consumes). The `-Dsimd=false` rationale:
ghostty's C++ SIMD libs (simdutf/highway via Google Highway `foreach_target.h`) can
misdetect HOST CPU features / emit wrong intrinsics when cross-compiling to a foreign
arch; `-Dsimd=false` skips building them entirely (scalar fallback — negligible perf hit
for ANSI parsing). `-Dsimd=false` is HARMLESS on native targets too (just slower UTF ops),
so applying it unconditionally per the contract's flag list is safe + deterministic.
`macos-latest` is arm64 (Apple Silicon) since ~mid-2024 ⇒ `x86_64-macos` is a cross-build.

## 3. The SHA256SUMS.txt CONSOLIDATION (the one real design difference)

### Why term2html's release job can't be copied verbatim
term2html uploads `dist/**/*.tar.gz` directly — it has NO checksum file. Our
`download.sh` (P2.M3.T1.S2, shipped) downloads ONE `SHA256SUMS.txt` from
`/releases/latest/download/SHA256SUMS.txt` and greps it for the line matching the
requested tarball basename. So we need **ONE file with all 4 lines** — not 4 per-job
files. (external_deps.md §3's snippet shows a per-job `(cd dist && sha256sum … >
../SHA256SUMS.txt)` which would produce 4 colliding `SHA256SUMS.txt` uploads — a BUG for
our use case. The real term2html doesn't do that step at all. We do the consolidation in
the RELEASE job, correctly.)

### The download.sh CONTRACT (the consumer — read `scripts/download.sh`)
```sh
DL_BASE=${TMUX_2HTML_DL_BASE:-https://github.com/$REPO/releases/latest/download}
tname="tmux-2html-$triple.tar.xz"          # e.g. tmux-2html-linux-x86_64.tar.xz
url="$DL_BASE/$tname"
sums_url="$DL_BASE/SHA256SUMS.txt"
…
# looks up the hash for THIS tarball basename:
expected=$(grep -E "[[:space:]/]${tname}[[:space:]]*$" "$sums" | tr -d '\r' | awk '{print $1}' | head -n1)
```
So `SHA256SUMS.txt` MUST contain, per tarball, a line:
```
<64-lowercase-hex>  tmux-2html-<triple>.tar.xz
```
(standard `sha256sum` output: 64 hex + TWO spaces + basename). The grep matches because
the char before the basename is whitespace, and the line ENDS with the basename. `tr -d
'\r'` tolerates CRLF. Each tarball then extracts to a top-level `tmux-2html` binary
(`tar -C dist -cJf … tmux-2html` ⇒ top entry `tmux-2html`), which download.sh `chmod 0755`s.

### Correct consolidation design (release job)
1. Download all 4 artifacts FLATTENED into one dir (download-artifact@v4 default nests each
   artifact in `path/<artifact-name>/`; use `merge-multiple: true` + `pattern` to flatten).
2. `sha256sum tmux-2html-*.tar.xz | sort -k2 > SHA256SUMS.txt` (4 lines, deterministic order).
3. Upload the tarballs + the single `SHA256SUMS.txt` to the draft release.

See `design_notes.md` for the verbatim YAML + the exact `merge-multiple` block.

## 4. GitHub Actions API notes (verified from action READMEs)

- **softprops/action-gh-release@v2**: `draft`, `files` (newline-delimited globs via YAML
  `|`), `fail_on_unmatched_files`, `generate_release_notes`. Auto-detects the tag from
  `github.ref` on tag push — NO `tag_name` needed. Needs `permissions: contents: write`.
  Upserts: creates a NEW draft or updates an existing one for that tag. Asset NAME on the
  release = the file's BASENAME (so `dist/SHA256SUMS.txt` → asset `SHA256SUMS.txt` ✓, and
  `dist/tmux-2html-linux-x86_64.tar.xz` → asset `tmux-2html-linux-x86_64.tar.xz` ✓).
  **DRAFT releases are invisible to `/releases/latest/download/`** until a human clicks
  Publish — INTENTIONAL gate (download.sh comments confirm: drafts 404 on `latest` until
  promoted). Source: https://github.com/softprops/action-gh-release + GitHub REST "Get the
  latest release" (excludes drafts/prereleases).
- **actions/upload-artifact@v4**: artifact `name` MUST be unique within the run (v4 does
  NOT merge same-name artifacts — v3 did). In a matrix, parameterize `name` per job (here
  `tmux-2html-${{ matrix.triple }}`). `path` accepts a single file. `if-no-files-found:
  error` makes a missing build output a hard failure. Source:
  https://github.com/actions/upload-artifact.
- **actions/download-artifact@v4**: default nests each artifact in `path/<name>/`. To
  FLATTEN, set `merge-multiple: true` + `pattern: <glob>`. With unique filenames there's
  no collision. Source: https://github.com/actions/download-artifact.
- **tar -cJf on macos-latest**: macOS ships bsdtar (libarchive) which supports `-J` (xz)
  natively — no separate xz install needed. (We package per-target; the SHA256SUMS step
  runs on ubuntu-latest where `sha256sum` exists, so macOS's lack of `sha256sum` is moot.)
- **macos-latest = arm64** since ~mid-2024 (macos-14). ⇒ `aarch64-macos` native,
  `x86_64-macos` cross. Source: https://github.com/actions/runner-images.

## 5. Scope boundary with P4.M1.T1.S2 (the test job — NOT this task)

- THIS task (S1) creates `.github/workflows/release.yml` with TWO jobs: `build` (the 4-
  target matrix) + `release` (the draft + assets). Trigger: `on.push.tags: [v*]` (+ optional
  `workflow_dispatch` to test the matrix without tagging).
- S2 ("CI test job (ReleaseFast) — run golden + unit tests") is a SEPARATE task and owns
  the test job. The natural home is a SEPARATE workflow `.github/workflows/ci.yml` on
  `push`/`pull_request` (so tests run on every commit, not just tags), OR an added job.
  Either way S2 must NOT alter the `build`/`release` jobs S1 defines here — this PRP's
  release.yml is the contract for the release pipeline.
