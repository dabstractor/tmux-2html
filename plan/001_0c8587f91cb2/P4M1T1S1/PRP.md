name: "P4.M1.T1.S1 — release.yml: 4-target build matrix + tar.xz + ONE consolidated SHA256SUMS.txt + draft release"
description: |
  Creates `.github/workflows/release.yml` (NEW file; the `.github/workflows/` dir does not exist
  yet). On tag `v*` (plus an optional `workflow_dispatch` to test the matrix without tagging), a
  4-target matrix (`linux-x86_64`, `linux-aarch64`, `macos-x86_64`, `macos-arm64` per PRD §10)
  builds `tmux-2html` with `mlugg/setup-zig@v2` (0.15.2) via `zig build --fetch` then
  `zig build -Doptimize=ReleaseFast -Dtarget=<Zig-triple> [-Dsimd=false]` (env `ZIG_HTTP_MAX_CONNS=1`),
  packages each as `tmux-2html-<triple>.tar.xz` (top-level entry = bare `tmux-2html` binary), uploads
  each as a uniquely-named artifact. A `release` job (`needs: build`) downloads all 4 FLATTENED
  (`merge-multiple: true`), generates ONE consolidated `SHA256SUMS.txt` (4 lines, standard
  `sha256sum` format: `<64-hex>  tmux-2html-<triple>.tar.xz`), and uploads the tarballs + the sums
  to a DRAFT GitHub release via `softprops/action-gh-release@v2` (auto-detects the tag; needs
  `permissions: contents: write`). A human Publishes; only then does `scripts/download.sh`'s
  `/releases/latest/download/` URL resolve (drafts are invisible to `latest` — intentional gate).
  The asset names + the SHA256SUMS format are the CONTRACT with the shipped `download.sh`
  (P2.M3.T1.S2). NO test job — that is S2 (P4.M1.T1.S2), a separate task. NO source-code changes.

---

## Goal

**Feature Goal**: A `.github/workflows/release.yml` that, on a `v*` tag push, produces 4 verified
prebuilt tarballs (`tmux-2html-linux-x86_64.tar.xz`, `tmux-2html-linux-aarch64.tar.xz`,
`tmux-2html-macos-x86_64.tar.xz`, `tmux-2html-macos-arm64.tar.xz`) + ONE consolidated
`SHA256SUMS.txt` and attaches all 5 to a DRAFT GitHub release — in exactly the shape the shipped
`scripts/download.sh` consumes (PRD §10 step 3, §11).

**Deliverable**: ONE new file — `.github/workflows/release.yml` (create the `.github/workflows/`
directory). Two jobs: `build` (the 4-target matrix) + `release` (flatten artifacts → consolidate
SHA256SUMS → draft). The complete, copy-ready YAML is in `research/design_notes.md §1` — it IS
the spec. No other files are created or modified.

**Success Definition**:
- Pushing a tag `vX.Y.Z` triggers the workflow; all 4 matrix jobs build `tmux-2html` for their
  target with Zig 0.15.2 (ReleaseFast), each producing a `tmux-2html-<triple>.tar.xz` whose
  top-level entry is the bare executable `tmux-2html`.
- The `release` job generates ONE `SHA256SUMS.txt` with exactly 4 lines, each
  `<64-lowercase-hex>  tmux-2html-<triple>.tar.xz` (standard `sha256sum` format), and uploads it +
  the 4 tarballs to a DRAFT GitHub release on tag `vX.Y.Z`.
- After a human Publishes the draft, `sh scripts/download.sh <bin_dir>` on each platform downloads
  the matching tarball, verifies its SHA256 against `SHA256SUMS.txt`, and atomically installs an
  executable `tmux-2html` — i.e. the release is byte-for-byte consumable by `download.sh`.
- `release.yml` contains ONLY `build` + `release` (NO test job — S2 owns that). The repo's existing
  build (`zig build -Doptimize=ReleaseFast`) is unchanged.

## User Persona (if applicable)

**Target User**: the project maintainer cutting a release (and, downstream, every end user who lets
`scripts/download.sh` fetch the prebuilt binary because they have no Zig toolchain).

**Use Case**: maintainer pushes `git tag v0.1.0 && git push --tags`; CI cross/native-builds 4
binaries, packages + checksums them, opens a draft release; maintainer reviews the assets +
SHA256SUMS in the GitHub UI, clicks Publish; from then on `tmux-2html`'s `ensure_binary.sh` →
`download.sh` path works for users with no compiler.

**User Journey**: tag push → 4 green matrix jobs → draft release with 5 assets → maintainer
Publishes → `download.sh` succeeds on linux-x86_64 / linux-aarch64 / macos-x86_64 / macos-arm64.

**Pain Points Addressed**: no prebuilt binaries today (users must install Zig 0.15.2 — heavy); the
flipped-hybrid acquisition (PRD §10) needs a published release to fall back to. This task ships the
release pipeline that produces those exact assets.

## Why

- **Closes the distribution gap.** PRD §10 step 3 (binary acquisition) falls back to
  `download.sh` only if a published release with the right tarballs + `SHA256SUMS.txt` exists.
  Today there is no release pipeline at all — so the download fallback can never succeed. This task
  creates it.
- **Faithful to PRD §11 + the term2html VERIFIED shape.** The contract (item §1) cites
  `architecture/external_deps.md §3` ("VERIFIED term2html build-binaries.yml shape") and we further
  verified it by fetching the ACTUAL `aarol/term2html/.github/workflows/build-binaries.yml` (see
  `research/reference_workflow.md`). We keep term2html's matrix / setup-zig / `--fetch` /
  `ZIG_HTTP_MAX_CONNS=1` / `-Dsimd=false`-on-cross pattern, change `tar.gz`→`tar.xz`, adopt PRD §10
  triple naming, and ADD the consolidated `SHA256SUMS.txt` term2html lacks.
- **Bytes match the consumer.** The asset names (`tmux-2html-<triple>.tar.xz`, `SHA256SUMS.txt`) +
  the SHA256SUMS line format + the tarball's top-level `tmux-2html` entry are dictated by the
  shipped `scripts/download.sh` (P2.M3.T1.S2). This task treats download.sh as the contract.
- **Safe + reviewable.** Drafts are invisible to `/releases/latest/download/` until a human
  Publishes — so a broken/accidental tag push never reaches downloaders. That gate is intentional
  (download.sh's own comments confirm it) and this task preserves it (`draft: true`).

## What

A single new GitHub Actions workflow file, `.github/workflows/release.yml`, with two jobs:

1. **`build`** — a 4-row matrix (one per PRD §10 triple). Each row: checkout → `mlugg/setup-zig@v2`
   (0.15.2) → `zig build --fetch` then `zig build -Doptimize=ReleaseFast -Dtarget=<Zig-triple>
   <flags>` (`ZIG_HTTP_MAX_CONNS=1`; `-Dsimd=false` on the two CROSS targets) → package
   `zig-out/bin/tmux-2html` into `tmux-2html-<triple>.tar.xz` → `upload-artifact@v4` under a
   unique name (`tmux-2html-<triple>`). `fail-fast: false`.
2. **`release`** (`needs: build`, `if: startsWith(github.ref,'refs/tags/')`) —
   `download-artifact@v4` with `merge-multiple: true` + `pattern: tmux-2html-*` (flatten the 4
   tarballs into `assets/`) → `sha256sum tmux-2html-*.tar.xz | sort -k2 > assets/SHA256SUMS.txt` →
   `softprops/action-gh-release@v2` with `draft: true`, `generate_release_notes: true`,
   `fail_on_unmatched_files: true`, `files:` = the tarballs + the single sums file.

Top-level: `on: { workflow_dispatch:, push: { tags: ["v*"] } }` and
`permissions: { contents: write }`.

### Success Criteria

- [ ] `.github/workflows/release.yml` exists and is valid YAML (passes `actionlint` / `yamllint`).
- [ ] The matrix has exactly 4 rows with the PRD-triple ↔ Zig-target mapping (§2 of design_notes);
      `-Dsimd=false` on `linux-aarch64` + `macos-x86_64` (the cross targets).
- [ ] Each tarball is named `tmux-2html-<triple>.tar.xz` and its TOP-LEVEL entry is `tmux-2html`
      (verified by the local dry-run: `tar -tJf … | head -1` == `tmux-2html`).
- [ ] `release` produces ONE `SHA256SUMS.txt` (not 4) with 4 lines in standard `sha256sum` format;
      the local dry-run proves `download.sh`'s grep matcher finds each tarball's hash.
- [ ] `release.yml` contains NO `test` job (S2's scope) and modifies NO source/build files.
- [ ] `permissions: contents: write` is present (required for action-gh-release).
- [ ] `draft: true` (NOT auto-published) — the `/releases/latest/download/` gate is preserved.

## All Needed Context

### Context Completeness Check

_If someone knew nothing about this codebase, would they have everything needed to implement this
successfully?_ **YES.** This PRP embeds: the COMPLETE copy-ready `release.yml` (verbatim in
`research/design_notes.md §1` — it IS the spec); the provenance (term2html gold reference +
tmux-2html deltas in `research/reference_workflow.md`); the EXACT consumer contract (the relevant
excerpt of `scripts/download.sh` — asset names, SHA256SUMS line format, the grep matcher, the
tarball top-level-entry expectation); the PRD-triple ↔ Zig-target matrix; the build.zig facts
(binary lands at `zig-out/bin/tmux-2html`, `-Dtarget`/`-Doptimize`/`-Dsimd` honored, lazy ghostty
dep); every gotcha (asset-name exactness, ONE consolidated sums, `merge-multiple` mandatory, v4
unique artifact names, draft-invisible-to-latest, `-Dsimd=false` rationale); and a locally-runnable
validation (YAML lint + a dry-run that reproduces the release job's packaging+checksum logic).

### Documentation & References

```yaml
# MUST READ — the COMPLETE, copy-ready spec for THIS subtask (the YAML is verbatim + final).
- docfile: plan/001_0c8587f91cb2/P4M1T1S1/research/design_notes.md
  why: §1 is the COMPLETE release.yml (write it, optionally pinning action SHAs to project policy).
       §3 shows the exact SHA256SUMS.txt format. §5 lists the 10 gotchas. This IS the implementation.
  section: "§1 The COMPLETE release.yml" + "§3 SHA256SUMS format" + "§5 Gotchas"

# MUST READ — provenance + the consumer contract + the API notes.
- docfile: plan/001_0c8587f91cb2/P4M1T1S1/research/reference_workflow.md
  why: §1 = the ACTUAL term2html build-binaries.yml (the VERIFIED gold reference the contract cites);
       §2 = the term2html→tmux-2html delta table + the PRD-triple↔Zig-target mapping; §3 = WHY the
       SHA256SUMS must be consolidated (term2html has none) + the download.sh contract excerpt;
       §4 = the verified GitHub Actions API notes (action-gh-release/upload/download-artifact).
  section: "§1 term2html gold reference" + "§2 deltas + triple mapping" + "§3 SHA256SUMS consolidation"

# The CONSUMER — the shipped downloader whose asset/sums contract this release MUST satisfy.
- file: scripts/download.sh
  why: Hardcodes the asset names (`tmux-2html-$triple.tar.xz`), the sums URL
       (`…/releases/latest/download/SHA256SUMS.txt`), the grep matcher
       (`grep -E "[[:space:]/]${tname}[[:space:]]*$"`), and the extract expectation
       (`tar -xJf … -C $tmp` then `[ -f $tmp/tmux-2html ]`). EVERY release asset decision flows
       from this file. Also note its REPO default (`dabstractor/tmux-ansi2html`) + the draft-404s
       comment (drafts are invisible to `/latest/download/` until published — intentional).
  pattern: "asset/sums URL construction + grep matcher + extract expectation (lines ~DL_BASE, tname,
           sums_url, the sha256 lookup, the tar -xJf + $tmp/tmux-2html check)"
  gotcha: "drafts 404 on /releases/latest/download/ until a human Publishes — DO NOT 'fix' with
           draft:false; that is the intended review gate."

# The build that the workflow invokes — confirms the flags + the output path.
- file: build.zig
  why: Confirms (a) `b.standardTargetOptions` honors `-Dtarget=<triple>`; (b) `standardOptimizeOption`
       honors `-Doptimize=ReleaseFast`; (c) `b.option(bool,"simd",…)` ⇒ `-Dsimd=false` works; (d)
       `addExecutable(.{.name="tmux-2html"})` + `installArtifact` ⇒ the binary is `zig-out/bin/tmux-2html`
       (NOT target-suffixed) for every target; (e) ghostty is a LAZY dep (`b.lazyDependency`) fetched
       at build time (⇒ `--fetch` + `ZIG_HTTP_MAX_CONNS=1` matter).
  pattern: "standardTargetOptions/standardOptimizeOption/simd option/addExecutable name=tmux-2html"
- file: build.zig.zon
  why: Confirms `.version = "0.1.0"` (baked into --version via build_options), `.minimum_zig_version =
       "0.15.2"` (⇒ setup-zig version 0.15.2), ghostty+parg deps, and that `paths` includes `scripts`
       (download.sh is in the package — but irrelevant to the workflow itself).

# PRD — the behavioral + naming contract.
- docfile: PRD.md
  why: §10 (platform triples linux-x86_64/linux-aarch64/macos-x86_64/macos-arm64; the
       detect→download→SHA256-verify→extract flow; SHA256SUMS.txt); §11 (Zig 0.15.2 pinned; CI
       `.github/workflows/release.yml` on tag `v*`; 4-target matrix; tar.xz; SHA256SUMS.txt; draft;
       macos-arm64/linux-aarch64 native preferred, cross elsewhere; version via build_options).
  section: "10. Binary acquisition" + "11. Build & release"

# The contract note that anchors the whole task (cited from architecture/external_deps.md §3).
- docfile: plan/001_0c8587f91cb2/architecture/external_deps.md
  why: §3 "GitHub Actions release matrix (verified from term2html build-binaries.yml)" — the
       mlugg/setup-zig@v2 + zig build --fetch + ZIG_HTTP_MAX_CONNS=1 + -Dsimd=false-on-cross shape,
       and the explicit "tmux-2html ADDS sha256sums + tar.xz" delta. (NOTE: its per-job sha256sum
       snippet is a known imprecision — the CORRECT consolidation is in the `release` job, per
       design_notes §1/§3 + reference_workflow §3. The real term2html has NO checksums at all.)
  section: "§3 GitHub Actions release matrix"
```

### Current Codebase tree (run `ls -la .github 2>/dev/null; tree -L 2 -I 'zig-cache|zig-out|zig-pkg|node_modules|.git'`)

```bash
$ ls -la .github 2>/dev/null || echo "no .github dir"     # ← no .github/ exists yet
no .github dir
$ tree -L 2 -I 'zig-cache|zig-out|zig-pkg|.git' --dirsfirst
.
├── build.zig               # the build the workflow invokes (-Dtarget/-Doptimize/-Dsimd; exe name tmux-2html)
├── build.zig.zon           # version 0.1.0; min_zig 0.15.2; ghostty(lazy)+parg deps
├── docs/
├── licenses/
├── PRD.md                  # §10/§11 = the contract for this task
├── scripts/
│   ├── download.sh         # the CONSUMER — asset names + SHA256SUMS format + extract expectation
│   └── ensure_binary.sh    # the caller (zig-build → download fallback)
├── src/                    # the Zig sources (UNCHANGED by this task)
├── testdata/               # golden fixtures (UNCHANGED; S2 runs them, not this task)
├── tmux-2html.tmux         # the TPM plugin entrypoint (UNCHANGED)
├── LICENSE
└── (no .github/)           # ← THIS TASK CREATES .github/workflows/release.yml
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
.github/
└── workflows/
    └── release.yml         # NEW (THIS TASK). Two jobs: build (4-target matrix) + release
                             #   (flatten artifacts → consolidate SHA256SUMS.txt → draft). On tag v*
                             #   (+ workflow_dispatch). permissions: contents: write. NO test job.
# (No source/build/script changes. S2 — P4.M1.T1.S2 — separately owns the CI test job.)
```

`.github/workflows/release.yml` responsibilities:
- `build` job: per-triple matrix → setup-zig 0.15.2 → `zig build --fetch` + `zig build
  -Doptimize=ReleaseFast -Dtarget=<Zig-triple> <flags>` (`ZIG_HTTP_MAX_CONNS=1`) → package
  `zig-out/bin/tmux-2html` → `tmux-2html-<triple>.tar.xz` → `upload-artifact@v4` (unique name).
- `release` job: `download-artifact@v4` (`merge-multiple: true`, flatten 4 tarballs) →
  `sha256sum tmux-2html-*.tar.xz | sort -k2 > SHA256SUMS.txt` → `softprops/action-gh-release@v2`
  (`draft: true`, upload tarballs + the single sums file).

### Known Gotchas of our codebase & Library Quirks

```yaml
# CRITICAL: the ASSET NAMES are a hard contract with scripts/download.sh. They MUST be exactly:
#   tmux-2html-linux-x86_64.tar.xz, tmux-2html-linux-aarch64.tar.xz,
#   tmux-2html-macos-x86_64.tar.xz, tmux-2html-macos-arm64.tar.xz, SHA256SUMS.txt
# Do NOT bake the version into the name (PRD §11 = tmux-2html-<triple>, NOT -<ver>-<triple>).
# download.sh hardcodes `tmux-2html-$triple.tar.xz` + `SHA256SUMS.txt` (uppercase). A stray
# suffix ⇒ a 404 on EVERY fetch.

# CRITICAL: ONE consolidated SHA256SUMS.txt — NOT per-job. external_deps.md §3's snippet shows a
# per-job `sha256sum` that would upload 4 colliding SHA256SUMS.txt files. The consolidation MUST
# happen in the `release` job, AFTER the flattened download, as `sha256sum tmux-2html-*.tar.xz |
# sort -k2 > SHA256SUMS.txt`. (The real term2html has NO checksums at all — we ADD this correctly.)

# CRITICAL: `merge-multiple: true` is MANDATORY on download-artifact@v4. Without it, the 4 tarballs
# land in assets/<artifact-name>/ subdirs and `sha256sum tmux-2html-*.tar.xz` matches nothing.

# CRITICAL: upload-artifact@v4 REQUIRES unique artifact `name` per run (v4 does NOT merge same-name
# artifacts like v3 did). Parameterize `name` by `matrix.triple` ⇒ all 4 unique.

# CRITICAL: `permissions: contents: write` is REQUIRED for softprops/action-gh-release to create the
# release + upload assets. Omit ⇒ 403. Put it top-level (covers both jobs) or job-level on `release`.

# CRITICAL: PRD-triple ≠ Zig-target. Asset `linux-x86_64` ↔ build target `x86_64-linux-gnu`. The
# matrix has BOTH columns (`triple` for asset/artifact/tarball naming; `target` for `-Dtarget=`).
# Mixing them up ⇒ wrong asset name (404) or wrong build target.

# CRITICAL: `-Dsimd=false` on the 2 CROSS targets (linux-aarch64, macos-x86_64). ghostty's C++ SIMD
# libs (highway/simdutf via foreach_target.h) can miscompile misdetecting HOST features under cross-
# compilation; -Dsimd=false skips them (scalar fallback, negligible for ANSI parsing). Keep it per the
# contract's explicit flag list EVEN IF you later move a target to a native runner (harmless on native).

# CRITICAL: the binary path is `zig-out/bin/tmux-2html` for ALL targets (NOT target-suffixed) — build.zig
# uses addExecutable(.{.name="tmux-2html"}) + installArtifact + default prefix zig-out/. Copy THAT path.

# CRITICAL: `draft: true` is INTENTIONAL. Drafts are invisible to /releases/latest/download/ until a
# human Publishes. download.sh will 404 on a draft — that is the review gate, NOT a bug. Do NOT set
# draft:false. (download.sh's own comments confirm: "drafts 404 here until promoted — CORRECT".)

# CRITICAL: `zig build --fetch` + the build MUST use `ZIG_HTTP_MAX_CONNS=1` (set as env on the Build
# step, covering both commands). The package manager fetches ghostty + ~25 transitive C++ SIMD sub-deps
# from github.com; capping concurrent HTTP conns avoids rate-limiting/connection exhaustion. This is
# straight from the VERIFIED term2html reference.

# NOTE: this task creates ONLY `build` + `release`. The CI TEST job (P4.M1.T1.S2) is a SEPARATE task —
# most naturally a separate `.github/workflows/ci.yml` on push/PR (so tests run every commit, not just
# tags), or an added job. Do NOT add a test job to release.yml; do NOT duplicate the build matrix.

# NOTE: you CANNOT run a GitHub Actions workflow locally. Validation = YAML lint (actionlint/yamllint)
# + a LOCAL dry-run that reproduces the release job's packaging+checksum logic (proves the tarball
# layout + the SHA256SUMS format download.sh expects) + a manual end-to-end via a real `v*` tag push
# (or workflow_dispatch). See the Validation Loop.
```

## Implementation Blueprint

### Data models and structure

No code data models. The "data" is the workflow's matrix + the asset-naming contract, both fully
specified in `research/design_notes.md §1` (the verbatim YAML) + §2 (the triple↔target table). The
matrix carries, per row: `triple` (PRD §10 asset name), `os` (runner), `target` (Zig `-Dtarget`),
`flags` (`""` or `"-Dsimd=false"`).

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: CREATE .github/workflows/release.yml (the ONLY deliverable)
  - WRITE the file with the COMPLETE YAML from research/design_notes.md §1 (verbatim). It is final.
  - STRUCTURE: `name: release`; `on: { workflow_dispatch:, push: { tags: ["v*"] } }`;
    `permissions: { contents: write }`; jobs `build` (matrix) + `release` (needs: build).
  - MATRIX (4 rows, `fail-fast: false`): {triple: linux-x86_64,  os: ubuntu-latest, target:
    x86_64-linux-gnu,  flags: ""} | {triple: linux-aarch64, os: ubuntu-latest, target:
    aarch64-linux-gnu, flags: "-Dsimd=false"} | {triple: macos-x86_64, os: macos-latest, target:
    x86_64-macos, flags: "-Dsimd=false"} | {triple: macos-arm64, os: macos-latest, target:
    aarch64-macos, flags: ""}.
  - BUILD steps: actions/checkout@v4 → mlugg/setup-zig@v2 (version: 0.15.2) → one `Build` `run:`
    (`zig build --fetch` then `zig build -Doptimize=ReleaseFast -Dtarget=${{ matrix.target }}
    ${{ matrix.flags }}`) with `env: ZIG_HTTP_MAX_CONNS: "1"` → `Package` `run:` (`mkdir -p dist;
    cp zig-out/bin/tmux-2html dist/; tar -C dist -cJf tmux-2html-${{ matrix.triple }}.tar.xz
    tmux-2html`) → actions/upload-artifact@v4 (name: tmux-2html-${{ matrix.triple }}, path:
    tmux-2html-${{ matrix.triple }}.tar.xz, if-no-files-found: error).
  - RELEASE job (if: startsWith(github.ref,'refs/tags/'), runs-on: ubuntu-latest): download-artifact@v4
    (path: assets, pattern: tmux-2html-*, merge-multiple: true) → `Generate SHA256SUMS.txt`
    (working-directory: assets; run: `sha256sum tmux-2html-*.tar.xz | sort -k2 > SHA256SUMS.txt`) →
    softprops/action-gh-release@v2 (draft: true, generate_release_notes: true,
    fail_on_unmatched_files: true, files: |  assets/tmux-2html-*.tar.xz \n assets/SHA256SUMS.txt).
  - NAMING: asset/tarball = `tmux-2html-${{ matrix.triple }}.tar.xz`; sums file = `SHA256SUMS.txt`
    (uppercase). Do NOT bake the version into asset names.
  - FOLLOW pattern: the term2html gold reference (research/reference_workflow.md §1) — same
    setup-zig/--fetch/ZIG_HTTP_MAX_CONNS/-Dsimd shape; change tar.gz→tar.xz, adopt PRD triples,
    ADD the consolidated SHA256SUMS (§3 of reference_workflow).
  - GOTCHA: NO `test` job (S2 owns it). NO edit to build.zig/build.zig.zon/scripts/src.

Task 2: VALIDATE YAML + lint (local — see Validation Loop Level 1)
  - RUN: `yamllint .github/workflows/release.yml` (install if needed) OR `python3 -c "import
    yaml,sys; yaml.safe_load(open('.github/workflows/release.yml'))"` for a zero-deps syntax check.
  - RUN (best effort): `actionlint .github/workflows/release.yml` (catches unknown inputs/typos;
    install via `go install github.com/rhysd/actionlint/cmd/actionlint@latest` or download the
    binary). If actionlint is unavailable, the python yaml parse + a careful read suffice.
  - EXPECTED: zero errors. Fix any indentation/quoting (the `files: |` block, the `env:` map, the
    matrix `include` rows are the spots YAML is pickiest about).

Task 3: LOCAL DRY-RUN of the packaging + checksum logic (proves the download.sh contract locally)
  - Build a native binary (x86_64-linux here): `zig build --fetch && zig build -Doptimize=ReleaseFast`.
  - Reproduce the `Package` step: `mkdir -p /tmp/t2h/dist && cp zig-out/bin/tmux-2html /tmp/t2h/dist/
    && tar -C /tmp/t2h/dist -cJf /tmp/t2h/tmux-2html-linux-x86_64.tar.xz tmux-2html`.
  - ASSERT the tarball top-level entry: `tar -tJf /tmp/t2h/tmux-2html-linux-x86_64.tar.xz | head -1`
    ⇒ prints exactly `tmux-2html` (what download.sh extracts + checks). If it prints `./tmux-2html`
    or a dir prefix, the staging/layout is wrong.
  - Reproduce the `Generate SHA256SUMS.txt` step against a fake 4-tarball set (copy the one tarball
    to the 4 triple names) and assert the line format: `cd /tmp/t2h && for t in linux-x86_64
    linux-aarch64 macos-x86_64 macos-arm64; do cp tmux-2html-linux-x86_64.tar.xz tmux-2html-$t.tar.xz;
    done && sha256sum tmux-2html-*.tar.xz | sort -k2 > SHA256SUMS.txt && cat SHA256SUMS.txt`.
  - ASSERT the sums line format: each line == `<64-lowercase-hex>  tmux-2html-<triple>.tar.xz`
    (two spaces; 64 hex). Then run download.sh's EXACT matcher against it for one triple and confirm
    it finds the hash:
    `tname=tmux-2html-linux-x86_64.tar.xz; grep -E "[[:space:]/]${tname}[[:space:]]*$" SHA256SUMS.txt |
    tr -d '\r' | awk '{print $1}'` ⇒ prints the 64-hex hash (non-empty). If empty, the format is wrong.
  - (Optional) Reproduce download.sh's full verify+extract against the staged tarball to prove the
    end-to-end consumer path: `TMUX_2HTML_DL_BASE=file:///tmp/t2h sh scripts/download.sh /tmp/t2h-bin`
    ⇒ exit 0 AND `/tmp/t2h-bin/tmux-2html` is executable. (download.sh supports file:// for tests.)
  - EXPECTED: all assertions pass. This proves the asset layout + sums format WITHOUT needing GitHub.

Task 4: (MANUAL, after merge) END-TO-END via a real tag push
  - Push `git tag v0.1.0-rc1 && git push --tags` (use an -rc tag to avoid polluting `latest` while
    testing) and watch the Actions tab: all 4 `build` jobs green; `release` creates a DRAFT with 5
    assets (4 tarballs + SHA256SUMS.txt). Inspect the draft's SHA256SUMS.txt in the UI (4 lines).
  - (Optional pre-tag test) Use `workflow_dispatch` (Actions → release → Run workflow) on a branch:
    only the `build` matrix runs (the `if:` on `release` skips it). Confirms setup-zig + the cross
    builds + packaging work WITHOUT creating a release.
  - After Publish (or for the rc, after promoting): on each target platform, run
    `sh scripts/download.sh <bin_dir>` and confirm an executable `tmux-2html` lands + `--version`
    matches build.zig.zon's `0.1.0`. (Cross-platform: use the rc tag's release on a linux-aarch64 /
    macos machine, or an emulator/QEMU for aarch64-linux.)
```

### Implementation Patterns & Key Details

```yaml
# === The Build step (verbatim from the verified term2html reference; ZIG_HTTP_MAX_CONNS covers both cmds) ===
#   - name: Build
#     run: |
#       zig build --fetch
#       zig build -Doptimize=ReleaseFast -Dtarget=${{ matrix.target }} ${{ matrix.flags }}
#     env:
#       ZIG_HTTP_MAX_CONNS: "1"

# === The Package step (tar.xz + bare-binary top entry; -cJf works on macOS bsdtar natively) ===
#   - name: Package
#     run: |
#       mkdir -p dist
#       cp zig-out/bin/tmux-2html dist/
#       tar -C dist -cJf tmux-2html-${{ matrix.triple }}.tar.xz tmux-2html

# === The unique-artifact upload (v4 REQUIRES unique names; parameterize by triple) ===
#   - uses: actions/upload-artifact@v4
#     with:
#       name: tmux-2html-${{ matrix.triple }}
#       path: tmux-2html-${{ matrix.triple }}.tar.xz
#       if-no-files-found: error

# === The release job's flatten + consolidate (the ONE real design difference from term2html) ===
#   - uses: actions/download-artifact@v4
#     with:
#       path: assets
#       pattern: tmux-2html-*
#       merge-multiple: true          # FLATTEN — without this the sha256sum glob matches nothing
#   - name: Generate SHA256SUMS.txt
#     working-directory: assets
#     run: |
#       sha256sum tmux-2html-*.tar.xz | sort -k2 > SHA256SUMS.txt
#       cat SHA256SUMS.txt
#   - uses: softprops/action-gh-release@v2
#     with:
#       draft: true                   # human Publishes; drafts invisible to /releases/latest/download/
#       generate_release_notes: true
#       fail_on_unmatched_files: true
#       files: |
#         assets/tmux-2html-*.tar.xz
#         assets/SHA256SUMS.txt
```

### Integration Points

```yaml
TRIGGER:
  - on.push.tags: ["v*"]  # the release gate; github.ref == refs/tags/vX.Y.Z
  - on.workflow_dispatch: # optional — test the build matrix without tagging (release job's `if:` skips the draft)
PERMISSIONS:
  - top-level `permissions: { contents: write }`  # REQUIRED for action-gh-release (create release + upload assets)
CONSUMER_CONTRACT (scripts/download.sh — shipped, READ ONLY):
  - assets exposed after Publish: tmux-2html-<triple>.tar.xz (4) + SHA256SUMS.txt (1), at
    https://github.com/<REPO>/releases/latest/download/<asset>. (download.sh's REPO default =
    dabstractor/tmux-ansi2html; override via TMUX_2HTML_REPO for forks.)
  - SHA256SUMS.txt line format: `<64-hex>  tmux-2html-<triple>.tar.xz` (standard sha256sum output).
  - tarball top-level entry: `tmux-2html` (download.sh does `tar -xJf … -C $tmp` then `[ -f $tmp/tmux-2html ]`).
BUILD (NO change):
  - build.zig honors -Dtarget/-Doptimize/-Dsimd; exe = zig-out/bin/tmux-2html for every target.
SCOPE_BOUNDARY:
  - P4.M1.T1.S2 (CI test job) is SEPARATE — do NOT add a test job to release.yml or duplicate the matrix.
```

## Validation Loop

> **NOTE**: a GitHub Actions workflow CANNOT be run locally. Validation is therefore (1) YAML
> well-formedness + lint, (2) a LOCAL dry-run that reproduces the release job's packaging +
> checksum logic exactly (proves the tarball layout + SHA256SUMS format `download.sh` expects),
> (3) a manual end-to-end via a real `v*` tag push (or `workflow_dispatch`).

### Level 1: Syntax & Style (Immediate Feedback — local)

```bash
# Zero-dependency YAML parse (python3 is on the runners + most dev boxes):
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/release.yml'))" && echo "YAML OK"
# Expected: prints "YAML OK". A parse error ⇒ indentation/quoting bug (check the `files: |` block,
#   the `env:` map, the matrix `include:` rows — the pickiest spots). Fix before proceeding.

# Best-effort workflow linter (catches unknown action inputs / expression typos):
#   install: go install github.com/rhysd/actionlint/cmd/actionlint@latest  (or grab the release binary)
actionlint .github/workflows/release.yml
# Expected: zero errors. If actionlint flags an action it can't fetch (offline), that's informational;
#   focus on the structural/expression errors it CAN detect offline.

# NOTE on `yamllint`: it may warn `[truthy]` on the top-level `on:` key (YAML 1.1 treats bare `on`/
#   `off` as booleans). That is a FALSE POSITIVE — GitHub Actions reads `on:` as the trigger map
#   correctly (every workflow uses it). Do NOT "fix" it by quoting to `"on":` (harmless if you do,
#   but unnecessary). actionlint (the authoritative check for Actions syntax) accepts bare `on:`.
```

### Level 2: Local Dry-Run of the packaging + checksum logic (proves the download.sh contract)

```bash
# (a) Build a native binary (x86_64-linux on this host) — proves the workflow's build command works:
zig build --fetch && zig build -Doptimize=ReleaseFast
# Expected: zig-out/bin/tmux-2html exists and is executable.

# (b) Reproduce the `Package` step verbatim:
mkdir -p /tmp/t2h/dist && cp zig-out/bin/tmux-2html /tmp/t2h/dist/
tar -C /tmp/t2h/dist -cJf /tmp/t2h/tmux-2html-linux-x86_64.tar.xz tmux-2html
# Expected: /tmp/t2h/tmux-2html-linux-x86_64.tar.xz created.

# (c) ASSERT the tarball's top-level entry is the bare 'tmux-2html' (what download.sh extracts + checks):
tar -tJf /tmp/t2h/tmux-2html-linux-x86_64.tar.xz | head -1
# Expected: prints exactly `tmux-2html` (NOT `./tmux-2html`, NOT a dir prefix). Critical for download.sh.

# (d) Reproduce the `Generate SHA256SUMS.txt` step against a synthetic 4-tarball set:
cd /tmp/t2h
for t in linux-x86_64 linux-aarch64 macos-x86_64 macos-arm64; do
  cp tmux-2html-linux-x86_64.tar.xz "tmux-2html-$t.tar.xz"
done
sha256sum tmux-2html-*.tar.xz | sort -k2 > SHA256SUMS.txt
cat SHA256SUMS.txt
# Expected: 4 lines, each `<64-lowercase-hex>  tmux-2html-<triple>.tar.xz` (two spaces). Alphabetical by name.

# (e) Run download.sh's EXACT hash matcher against the staged sums (proves the grep will hit):
tname=tmux-2html-linux-x86_64.tar.xz
grep -E "[[:space:]/]${tname}[[:space:]]*$" SHA256SUMS.txt | tr -d '\r' | awk '{print $1}'
# Expected: prints the 64-hex hash (non-empty). Empty ⇒ the sums line format is wrong.

# (f) (Optional, strong) End-to-end consumer test via download.sh's file:// test mode:
mkdir -p /tmp/t2h-bin
TMUX_2HTML_DL_BASE="file:///tmp/t2h" sh scripts/download.sh /tmp/t2h-bin ; echo "exit=$?"
# Expected: exit=0 AND /tmp/t2h-bin/tmux-2html is executable + runs `--version` == 0.1.0.
#   (download.sh supports file:// + fetches tmux-2html-<triple>.tar.xz + SHA256SUMS.txt from $DL_BASE.)
```

### Level 3: Integration Testing (MANUAL — a real tag push; needs the repo on GitHub)

```bash
# (a) Optional pre-tag smoke: trigger via workflow_dispatch on a branch (Actions → release → Run
#     workflow). Only the `build` matrix runs (the `release` job's `if:` skips it). Confirms
#     setup-zig + all 4 cross/native builds + packaging succeed WITHOUT creating any release.
#     Watch: all 4 `tmux-2html-<triple>` jobs green; each uploads its tarball artifact. Download
#     an artifact, `tar -tJf … | head -1` == `tmux-2html`.

# (b) Real end-to-end with a throwaway rc tag (keeps `latest` clean while you validate):
git tag v0.1.0-rc1 && git push --tags
# Watch the Actions run: 4 build jobs green → `release` creates a DRAFT release with 5 assets:
#   tmux-2html-linux-x86_64.tar.xz, tmux-2html-linux-aarch64.tar.xz, tmux-2html-macos-x86_64.tar.xz,
#   tmux-2html-macos-arm64.tar.xz, SHA256SUMS.txt.
# In the draft UI: open SHA256SUMS.txt — confirm 4 lines, correct format. Spot-check one hash:
#   download a tarball in the UI, `sha256sum` it locally, confirm it matches the line in SHA256SUMS.txt.

# (c) (After promoting the rc, or for the real v0.1.0:) consumer check on each platform:
sh scripts/download.sh /tmp/probe-bin ; echo "exit=$?"
/tmp/probe-bin/tmux-2html --version      # == 0.1.0 (from build.zig.zon)
# Expected on linux-x86_64 (this host): exit=0, executable installed, version matches.
#   For the other 3 platforms: run on real linux-aarch64 / macos-x86_64 / macos-arm64 hardware
#   (or QEMU for aarch64-linux). Each fetches its tarball, verifies SHA256, extracts + installs.
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Hash cross-check (catches a wrong-but-present sums file): in the published release, for EACH triple,
#   download the tarball + SHA256SUMS.txt, then `sha256sum -c SHA256SUMS.txt --ignore-missing` (or
#   `grep`-match each line). All 4 must verify. This is exactly what download.sh does per-fetch.

# Draft-gate check: while the release is still a DRAFT, confirm
#   curl -fsSL https://github.com/<REPO>/releases/latest/download/SHA256SUMS.txt
#   returns a 404 / redirects to the PREVIOUS published release (NOT the draft). After Publish, the
#   same URL serves the new sums. This proves the intentional gate (download.sh won't see a draft).

# fail-fast check: if you intentionally break one matrix row (e.g. a bad target string in a throwaway
#   branch + workflow_dispatch), confirm the OTHER 3 still run to completion (fail-fast: false).
```

## Final Validation Checklist

### Technical Validation

- [ ] `.github/workflows/release.yml` is valid YAML (`python3 -c "import yaml; yaml.safe_load(...)"`).
- [ ] `actionlint .github/workflows/release.yml` (if available) reports zero structural errors.
- [ ] Local dry-run (Level 2): tarball top-level entry == `tmux-2html`; SHA256SUMS has 4 correctly-
      formatted lines; download.sh's grep matcher finds each hash; (optional) `TMUX_2HTML_DL_BASE=
      file://… sh scripts/download.sh …` exits 0 + installs an executable binary.

### Feature Validation

- [ ] The matrix has exactly 4 rows with the correct `triple`↔`target` mapping; `-Dsimd=false` on
      `linux-aarch64` + `macos-x86_64`.
- [ ] Asset names are exactly `tmux-2html-<triple>.tar.xz` (4) + `SHA256SUMS.txt` (1) — no version
      baked in.
- [ ] ONE consolidated SHA256SUMS.txt generated in the `release` job (after the flattened download),
      NOT per-job.
- [ ] `release.yml` contains NO `test` job; NO source/build/script files modified.
- [ ] `permissions: contents: write` present; `draft: true` (the review gate preserved).
- [ ] (MANUAL) A `v*` tag push → 4 green builds → draft release with 5 assets; after Publish,
      `scripts/download.sh` succeeds on each platform + `--version` == 0.1.0.

### Code Quality Validation

- [ ] Follows the verified term2html reference shape (setup-zig/--fetch/ZIG_HTTP_MAX_CONNS/-Dsimd).
- [ ] Deltas from term2html are exactly: tar.xz (not gz), PRD §10 triple naming, the consolidated
      SHA256SUMS.txt (added), the bare-`tmux-2html` tarball entry.
- [ ] Step names + inline comments explain the non-obvious choices (merge-multiple, ZIG_HTTP_MAX_CONNS,
      -Dsimd on cross, draft-invisible-to-latest, the v4 unique-name rule).
- [ ] File placement matches the desired tree (`.github/workflows/release.yml`).

### Documentation & Deployment

- [ ] Inline comments document WHY (the download.sh contract, the consolidation rationale, the draft
      gate, the cross-compile simd flag) so a future maintainer doesn't "simplify" it into breaking.
- [ ] No new env vars / secrets required (uses the default `GITHUB_TOKEN` via `permissions`).

---

## Anti-Patterns to Avoid

- ❌ Don't bake the version into asset names (`tmux-2html-0.1.0-linux-x86_64.tar.xz`) — download.sh
  hardcodes `tmux-2html-$triple.tar.xz`; a version suffix 404s every fetch. PRD §11 = `tmux-2html-<triple>`.
- ❌ Don't generate SHA256SUMS per build job (4 colliding files) — generate ONE in the `release` job
  after the flattened download. (external_deps.md §3's per-job snippet is the trap; term2html has no
  sums at all.)
- ❌ Don't omit `merge-multiple: true` on download-artifact — without it the 4 tarballs nest in
  subdirs and `sha256sum tmux-2html-*.tar.xz` matches nothing.
- ❌ Don't give two matrix jobs the same upload-artifact `name` — v4 REQUIRES unique names (use
  `tmux-2html-${{ matrix.triple }}`).
- ❌ Don't confuse the PRD-triple (`linux-x86_64`) with the Zig-target (`x86_64-linux-gnu`) — the
  matrix has BOTH columns; `triple` names assets, `target` feeds `-Dtarget=`.
- ❌ Don't drop `-Dsimd=false` on the cross targets — ghostty's C++ SIMD libs can miscompile under
  cross-compilation. Keep it per the contract's explicit flag list (harmless on native too).
- ❌ Don't set `draft: false` to "fix" the `/releases/latest/download/` 404 — drafts being invisible
  to `latest` is the INTENTIONAL human-review gate (download.sh's own comments confirm it).
- ❌ Don't forget `permissions: contents: write` — action-gh-release 403s without it.
- ❌ Don't point the tarball at a target-suffixed binary path — the binary is ALWAYS
  `zig-out/bin/tmux-2html` (build.zig), regardless of `-Dtarget`.
- ❌ Don't add a `test` job — that's P4.M1.T1.S2 (a separate task). Keep release.yml to `build` +
  `release` only.
- ❌ Don't edit build.zig / build.zig.zon / scripts / src — this task is release INFRA only.
- ❌ Don't omit `zig build --fetch` or `ZIG_HTTP_MAX_CONNS=1` — both are in the VERIFIED term2html
  reference; `--fetch` pre-warms the cache (fail-fast on dep errors), the env caps HTTP conns to
  avoid GitHub rate-limiting while fetching ghostty + its C++ sub-deps.

---

## Confidence Score

**9/10** — The deliverable is a SINGLE new file (`.github/workflows/release.yml`) whose complete,
copy-ready YAML is authored verbatim in `research/design_notes.md §1` — it IS the spec, not a sketch.
The shape is anchored to a PRIMARY verified source: the ACTUAL `aarol/term2html/.github/workflows/
build-binaries.yml` (fetched raw), which the contract explicitly cites, plus the GitHub Actions API
facts confirmed from the action READMEs (action-gh-release@v2 `files`/`draft`/tag-auto-detect/
`contents: write`; upload-artifact@v4 unique-name; download-artifact@v4 `merge-multiple`). The ONE
material design difference from term2html — the consolidated `SHA256SUMS.txt` — is fully specified
and provably correct against the shipped `scripts/download.sh` consumer contract (the local dry-run
in the Validation Loop reproduces the exact packaging + `sha256sum … | sort -k2` + the download.sh
grep matcher + a `file://` end-to-end consumer test, all runnable WITHOUT GitHub). The PRD-triple ↔
Zig-target mapping, the `-Dsimd=false`-on-cross rationale, the binary path (`zig-out/bin/tmux-2html`),
and the draft-invisible-to-`latest` gate are all documented with primary sources.

Residual risks (all low): (1) CI can't be run locally — mitigated by the dry-run that proves the
download.sh contract + a manual rc-tag end-to-end. (2) `actionlint` may not be installed — mitigated
by the zero-deps `python3 yaml.safe_load` parse + careful review. (3) Cross-compiling `aarch64-linux`
and `x86_64-macos` with `-Dsimd=false` is the verified term2html path, but a future ghostty bump
could shift cross-compile behavior — mitigated by `fail-fast: false` (partial visibility) + the
`workflow_dispatch` pre-tag smoke. (4) GitHub could change `macos-latest`'s arch — but the
`-Dsimd=false` flags are tied to the TARGET (cross vs native) not the runner, so they stay correct
either way; if `macos-latest` ever reverted to Intel, `x86_64-macos` would become native (flag still
harmless) and `aarch64-macos` cross (would need `-Dsimd=false` added — a one-line matrix tweak, noted
in design_notes §5). The PARALLEL S2 (CI test job) is independent — this PRP's release.yml defines
only `build` + `release` and explicitly leaves the test job to S2, so there is no conflict.
