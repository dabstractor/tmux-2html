# Design Notes — P4.M1.T1.S1 (release.yml: 4-target matrix + tar.xz + SHA256SUMS + draft)

This file IS the spec for `.github/workflows/release.yml`. The YAML in §1 is complete and
ready to write verbatim (it is a correct, self-contained GitHub Actions workflow). See
`reference_workflow.md` for the provenance (term2html gold reference + the
tmux-2html-specific deltas) and `PRP.md` for the implementation/validation plan.

## 0. The ONE deliverable + the consumer contract

- **Deliverable**: `.github/workflows/release.yml` (a NEW file; the `.github/workflows/`
  dir does not exist yet — create it). Two jobs: `build` (4-target matrix) + `release`
  (consolidated SHA256SUMS + draft). NO other files. NO test job (that's S2's scope).
- **Consumer**: `scripts/download.sh` (P2.M3.T1.S2, shipped). It fetches
  `https://github.com/$REPO/releases/latest/download/tmux-2html-<triple>.tar.xz` +
  `…/SHA256SUMS.txt`, greps SHA256SUMS.txt for the tarball basename, verifies, extracts a
  top-level `tmux-2html`, `chmod 0755`s it, atomically installs. So a PUBLISHED release
  (after a human promotes the draft) must expose exactly these 5 assets:
  `tmux-2html-linux-x86_64.tar.xz`, `tmux-2html-linux-aarch64.tar.xz`,
  `tmux-2html-macos-x86_64.tar.xz`, `tmux-2html-macos-arm64.tar.xz`, `SHA256SUMS.txt`.
- **Triples** (PRD §10): `linux-x86_64`, `linux-aarch64`, `macos-x86_64`, `macos-arm64`.
  These are the ASSET names; the Zig `-Dtarget` values are DIFFERENT (see §2 table).

## 1. The COMPLETE release.yml (verbatim — write this, then tweak only if a local `action`
   version pin is project policy)

```yaml
name: release

# Builds 4 prebuilt tmux-2html binaries (linux/macos × x86_64/aarch64), packages each as
# tmux-2html-<triple>.tar.xz, generates ONE consolidated SHA256SUMS.txt, and uploads all
# assets to a DRAFT GitHub release. A human reviews + Publishes; only then does
# scripts/download.sh's /releases/latest/download/ URL resolve (drafts are invisible to
# `latest` until promoted — intentional gate). PRD §10/§11.

on:
  workflow_dispatch:        # lets you test the build matrix without cutting a tag
  push:
    tags:
      - "v*"

permissions:
  contents: write           # REQUIRED for softprops/action-gh-release to create the release + upload assets

jobs:
  build:
    name: tmux-2html-${{ matrix.triple }}
    runs-on: ${{ matrix.os }}
    strategy:
      fail-fast: false      # one target failing must NOT cancel the other 3
      matrix:
        include:
          # PRD-triple (asset/artifact name) | Zig -Dtarget            | runner         | -Dsimd=false
          - { triple: linux-x86_64,  os: ubuntu-latest, target: x86_64-linux-gnu,  flags: ""              }
          - { triple: linux-aarch64, os: ubuntu-latest, target: aarch64-linux-gnu, flags: "-Dsimd=false" }
          - { triple: macos-x86_64,  os: macos-latest,  target: x86_64-macos,      flags: "-Dsimd=false" }
          - { triple: macos-arm64,   os: macos-latest,  target: aarch64-macos,     flags: ""              }

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup Zig
        uses: mlugg/setup-zig@v2
        with:
          version: 0.15.2

      - name: Build
        # --fetch pre-populates the global zig cache (fails fast on dep-download errors);
        # the build then compiles ReleaseFast for the target. ZIG_HTTP_MAX_CONNS=1 caps the
        # package manager's concurrent HTTP connections to avoid GitHub rate-limiting while
        # fetching ghostty + its ~25 transitive C++ SIMD sub-deps from github.com.
        run: |
          zig build --fetch
          zig build -Doptimize=ReleaseFast -Dtarget=${{ matrix.target }} ${{ matrix.flags }}
        env:
          ZIG_HTTP_MAX_CONNS: "1"

      - name: Package
        # Binary lands at zig-out/bin/tmux-2html (NOT target-suffixed) — copy into a clean
        # staging dir, then tar.xz the bare 'tmux-2html' so the tarball's top-level entry
        # IS 'tmux-2html' (what download.sh extracts + chmods). -cJf = xz; macOS bsdtar
        # supports -J natively (libarchive). The exec bit is preserved by cp + tar.
        run: |
          mkdir -p dist
          cp zig-out/bin/tmux-2html dist/
          tar -C dist -cJf tmux-2html-${{ matrix.triple }}.tar.xz tmux-2html

      - name: Upload artifact
        uses: actions/upload-artifact@v4
        with:
          name: tmux-2html-${{ matrix.triple }}   # MUST be unique per matrix job (v4 rule)
          path: tmux-2html-${{ matrix.triple }}.tar.xz
          if-no-files-found: error

  release:
    name: Create draft release
    needs: build
    # Only create the draft on a real tag push (a workflow_dispatch on a branch runs ONLY
    # the build matrix, so you can test packaging without publishing).
    if: startsWith(github.ref, 'refs/tags/')
    runs-on: ubuntu-latest

    steps:
      - name: Download build artifacts (flattened)
        # download-artifact@v4 nests each artifact in path/<name>/ by default; merge-multiple
        # + pattern FLATTENS all 4 tarballs into assets/ (unique filenames ⇒ no collision).
        uses: actions/download-artifact@v4
        with:
          path: assets
          pattern: tmux-2html-*
          merge-multiple: true

      - name: Generate SHA256SUMS.txt
        # ONE consolidated file, 4 lines (standard sha256sum format: <64-hex>  <basename>).
        # download.sh greps this for the requested tarball basename. sort -k2 → deterministic
        # alphabetical order regardless of glob/locale expansion.
        working-directory: assets
        run: |
          sha256sum tmux-2html-*.tar.xz | sort -k2 > SHA256SUMS.txt
          echo "=== SHA256SUMS.txt ==="
          cat SHA256SUMS.txt

      - name: Create draft release
        # draft:true → a human must Publish in the GitHub UI before /releases/latest/download/
        # resolves to these assets (intentional gate; download.sh 404s on drafts). tag is
        # auto-detected from github.ref (refs/tags/vX.Y.Z) — no tag_name needed. Asset NAME on
        # the release = each file's BASENAME. fail_on_unmatched_files → loud failure if a
        # tarball/sums file is missing.
        uses: softprops/action-gh-release@v2
        with:
          draft: true
          generate_release_notes: true
          fail_on_unmatched_files: true
          files: |
            assets/tmux-2html-*.tar.xz
            assets/SHA256SUMS.txt
```

### Why each non-obvious line is the way it is
- **`on.workflow_dispatch`**: lets you trigger the build matrix manually (Actions tab → Run
  workflow) to validate the pipeline + packaging WITHOUT cutting a tag. The `if:` on
  `release` keeps it from creating a draft on a branch-only dispatch.
- **`fail-fast: false`**: if `macos-x86_64` fails to cross-compile, the other 3 still run
  to completion — you see exactly which target(s) broke instead of one cancelling the rest.
- **`ZIG_HTTP_MAX_CONNS: "1"`** (quoted to satisfy YAML as a string — unquoted `1` is also
  fine; term2html uses unquoted `1`): applies to BOTH `zig build --fetch` and `zig build`
  (same `run:` block). The package manager honors it for dep fetches.
- **`flags: "-Dsimd=false"`** on the 2 cross targets: ghostty's C++ SIMD libs (highway/
  simdutf) can miscompile when cross-compiling; `-Dsimd=false` skips them (scalar fallback).
  Harmless on native too — kept on the cross targets only to match the verified term2html
  matrix + the contract's explicit flag list.
- **`tar -C dist -cJf … tmux-2html`**: stages the bare binary, then archives it so the
  tarball's TOP-LEVEL entry is `tmux-2html` (download.sh does `tar -xJf … -C $tmp` then
  checks `$tmp/tmux-2html`). `-C dist` sets the working dir for the path `tmux-2html`.
- **upload `name: tmux-2html-${{ matrix.triple }}`**: v4 REQUIRES unique artifact names per
  run; parameterizing by `triple` makes all 4 unique. The `pattern: tmux-2html-*` in the
  release job matches all 4.
- **`merge-multiple: true`**: flattens the 4 per-target artifacts into one `assets/` dir so
  the single `sha256sum tmux-2html-*.tar.xz` glob sees all 4 at once (otherwise they'd be
  in `assets/tmux-2html-linux-x86_64/…` subdirs and the glob would miss them).
- **`generate_release_notes: true`**: GitHub auto-builds a release body from commits since
  the last tag. Harmless for a draft; editable before publish.
- **`fail_on_unmatched_files: true`**: if the download/consolidation somehow lost a tarball,
  the upload step FAILS instead of silently publishing a partial release.

## 2. The PRD-triple ↔ Zig-target matrix (reference — already embedded in §1)

| `triple` (asset name) | Zig `target` (`-Dtarget=`) | `os` | Native/Cross | `flags` |
|---|---|---|---|---|
| `linux-x86_64`  | `x86_64-linux-gnu`  | `ubuntu-latest` | Native  | `""` |
| `linux-aarch64` | `aarch64-linux-gnu` | `ubuntu-latest` | Cross   | `"-Dsimd=false"` |
| `macos-x86_64`  | `x86_64-macos`      | `macos-latest`  | Cross (host arm64) | `"-Dsimd=false"` |
| `macos-arm64`   | `aarch64-macos`     | `macos-latest`  | Native  | `""` |

## 3. SHA256SUMS.txt — the format download.sh REQUIRES

After the release job's Generate step, `assets/SHA256SUMS.txt` looks like (4 lines):
```
<64-lowercase-hex>  tmux-2html-linux-aarch64.tar.xz
<64-lowercase-hex>  tmux-2html-linux-x86_64.tar.xz
<64-lowercase-hex>  tmux-2html-macos-arm64.tar.xz
<64-lowercase-hex>  tmux-2html-macos-x86_64.tar.xz
```
(`sort -k2` orders alphabetically by basename.) download.sh's matcher:
```sh
expected=$(grep -E "[[:space:]/]${tname}[[:space:]]*$" "$sums" | tr -d '\r' | awk '{print $1}' | head -n1)
```
matches because the char before `tmux-2html-…` is a space (whitespace) and the line ENDS
with the basename (no trailing text). `tr -d '\r'` tolerates CRLF. The two-space separator
is standard `sha256sum` output. ✓

## 4. Validation approach (CI can't run locally — but YAML + contract CAN be checked)

CI workflows can't be executed on a dev box, so validation is: (a) YAML well-formedness +
lint, (b) a LOCAL dry-run of the packaging+checksum logic that mimics the release job
exactly (proves the SHA256SUMS format + tarball layout download.sh expects), (c) a manual
end-to-end via a real `v*` tag push (or `workflow_dispatch`). See PRP.md Validation Loop.

## 5. Gotchas (the things that will bite if missed)

1. **Asset names must be EXACTLY `tmux-2html-<triple>.tar.xz` + `SHA256SUMS.txt`** —
   download.sh hardcodes `tmux-2html-$triple.tar.xz` and `SHA256SUMS.txt` (uppercase). A
   stray suffix (e.g. a version in the name) ⇒ 404 on every fetch. Do NOT bake the version
   into the asset name (PRD §11 uses `tmux-2html-<triple>`, NOT `tmux-2html-<ver>-<triple>`).
2. **PRD-triple ≠ Zig-target.** `linux-x86_64` (asset) vs `x86_64-linux-gnu` (build). The
   matrix has BOTH columns; mixing them up ⇒ wrong asset name or wrong build target.
3. **ONE consolidated SHA256SUMS.txt, not per-job.** external_deps.md §3's snippet shows a
   per-job `sha256sum` that would upload 4 colliding `SHA256SUMS.txt`. The consolidation
   MUST happen in the `release` job after the flattened download (§1). This is the #1 way a
   naive copy of term2html goes wrong (term2html has no checksums at all).
4. **`merge-multiple: true` is mandatory** on the download step — without it the 4 tarballs
   land in `assets/<name>/` subdirs and `sha256sum tmux-2html-*.tar.xz` matches nothing.
5. **upload-artifact `name` must be unique per matrix job** (v4) — parameterize by `triple`.
6. **`permissions: contents: write`** is required (top-level here; applies to both jobs).
   Without it action-gh-release gets a 403 creating the release.
7. **`-Dsimd=false` on the 2 cross targets** (aarch64-linux, x86_64-macos) — without it the
   ghostty C++ SIMD libs can fail/miscompile under cross-compilation. The contract's flag
   list is authoritative; keep it even if you later switch a target to a native runner.
8. **Drafts are invisible to `/releases/latest/download/`** — INTENTIONAL. download.sh will
   404 until a human Publishes. Do NOT set `draft: false` to "fix" the 404; that's the gate.
9. **Binary path is `zig-out/bin/tmux-2html`** (not target-suffixed) for ALL targets — copy
   that exact path into the staging dir.
10. **`zig build test` is NOT this task** — S2 owns the CI test job. release.yml must contain
    ONLY `build` + `release`. Do not add a `test` job here.
