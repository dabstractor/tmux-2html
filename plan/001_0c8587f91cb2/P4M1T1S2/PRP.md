name: "P4.M1.T1.S2 — CI test job (ReleaseFast): run golden + unit tests on push/PR, linux + macos"
description: |
  Creates `.github/workflows/ci.yml` (NEW file). On every `push` + `pull_request`, a 2-host matrix
  (`ubuntu-latest` = linux-x86_64 native, `macos-latest` = macos-arm64 native) runs
  `zig build test -Doptimize=ReleaseFast` (with `zig build --fetch` first + `ZIG_HTTP_MAX_CONNS=1`,
  via `mlugg/setup-zig@v2` 0.15.2). `-Doptimize=ReleaseFast` is MANDATORY: PRD §15 — Debug-mode
  `zig build test` hits a linker bug (`R_X86_64_PC64`) with the bundled C++ SIMD libs (simdutf/
  highway/utfcpp via ghostty); release builds are unaffected (verified locally: all 275 tests green,
  exit 0). The single `test` step runs BOTH the golden harness (src/golden_test.zig) AND every
  per-file unit test (the build.zig `test` step is `b.addTest(.{ .root_module = exe.root_module })`,
  which roots all of src + the testdata module). SIMD stays ON (no `-Dsimd=false` — the bug is
  Debug-only; ReleaseFast links cleanly WITH SIMD, verified locally, so the SIMD paths are actually
  tested). SEPARATE from P4.M1.T1.S1's release.yml (which fires only on `v*` tags to build+publish
  binaries); ci.yml fires on every commit/PR. The OUTPUT "PRs are gated on green ReleaseFast tests"
  is realized by a one-time MANUAL branch-protection setting (Settings → Branches → Require status
  checks `ci / test (ubuntu-latest)` + `ci / test (macos-latest)`) — the workflow file PRODUCES the
  status check; branch protection ENFORCES it as a merge gate. NO source/build changes; the ONE
  deliverable is `.github/workflows/ci.yml`. The complete copy-ready YAML is in
  `research/design_notes.md §1` — it IS the spec.

---

## Goal

**Feature Goal**: A `.github/workflows/ci.yml` that, on every push and pull request, builds + runs
the full test suite (golden + unit, 275 tests) in ReleaseFast on **linux** (`ubuntu-latest`) and
**macos** (`macos-latest`), failing the build on any test failure — bypassing the PRD §15 Debug-mode
`R_X86_64_PC64` linker bug.

**Deliverable**: ONE new file — `.github/workflows/ci.yml`. A single `test` job with a 2-host matrix
(`ubuntu-latest`, `macos-latest`), `fail-fast: false`, `permissions: contents: read`, triggered on
`push` + `pull_request`. Steps: `actions/checkout@v4` → `mlugg/setup-zig@v2` (0.15.2) → `zig build
--fetch` then `zig build test -Doptimize=ReleaseFast` (`env: ZIG_HTTP_MAX_CONNS: "1"`). The complete,
copy-ready YAML is in `research/design_notes.md §1` — write it verbatim; it IS the spec. No other
files created or modified.

**Success Definition**:
- Pushing to any branch (or opening a PR) triggers `ci.yml`; both `test (ubuntu-latest)` and
  `test (macos-latest)` jobs run `zig build test -Doptimize=ReleaseFast` and exit green (all 275
  tests pass) on a clean runner.
- A failing test (e.g. temporarily break a golden) turns the status check red and the run fails —
  i.e. the test result is the gate signal.
- `ci.yml` is SEPARATE from `release.yml` (release.yml = `v*` tag build+publish; ci.yml =
  push/PR tests). No `test` job is added to release.yml.
- (MANUAL, after merge) Branch protection on the default branch requires `ci / test (ubuntu-latest)`
  + `ci / test (macos-latest)` to pass before merge → PRs are gated on green ReleaseFast tests.

## User Persona (if applicable)

**Target User**: the project maintainer (and any contributor) — CI gives instant, on-every-commit
confidence that the renderer goldens + unit tests still pass on both supported OSes, without anyone
having to install Zig 0.15.2 locally.

**Use Case**: contributor opens a PR → GitHub Actions runs `ci / test (ubuntu-latest)` +
`ci / test (macos-latest)`; the PR shows green/red status checks; with branch protection, the PR
cannot merge until both are green.

**User Journey**: push/PR → 2 green `test` jobs (linux + macos, ReleaseFast) → status checks on the
PR → (with branch protection) merge is blocked on red, allowed on green.

**Pain Points Addressed**: today there is NO CI test job — regressions in the renderer/goldens or the
selection/palette/CLI/TUI unit tests are caught only when someone happens to run `zig build test`
locally (and only if they remember `-Doptimize=ReleaseFast`, since the Debug linker bug makes the
naïve command fail). This task automates that gate on both OSes, on every commit.

## Why

- **Catches regressions early and on both OSes.** PRD §15 defines a real test suite (golden
  `testdata/*.ansi → *.html` byte-equality + selection/palette/capture/CLI/TUI unit tests) but
  nothing runs it continuously. This task wires it into CI so a broken render or a bad selection-
  math change is caught at the PR, not after merge.
- **Directly satisfies PRD §15 + the contract.** The contract (§1) cites PRD §15's note that
  `zig build test` hits a Debug-mode `R_X86_64_PC64` linker bug with the C++ SIMD libs and mandates
  running tests in ReleaseFast. This task implements exactly that: `zig build test
  -Doptimize=ReleaseFast`, on linux + macos, failing the build on test failure.
- **Complementary to, not conflicting with, P4.M1.T1.S1's release.yml.** release.yml ships prebuilt
  binaries on `v*` tags; it deliberately contains NO test job ("S2 owns that"). ci.yml adds the
  continuous-testing layer on push/PR. Different triggers ⇒ separate files (the idiomatic GH Actions
  split); no duplication, no conflict.
- **Enables the gating OUTPUT.** "PRs are gated on green ReleaseFast tests" requires (a) a workflow
  that produces the status check (this task) and (b) branch protection that enforces it (a manual
  one-time setting documented in the Validation Loop). This task delivers (a).

## What

A single new GitHub Actions workflow file, `.github/workflows/ci.yml`, with ONE job (`test`) on a
2-host matrix:

1. **`test`** — matrix `os: [ubuntu-latest, macos-latest]` (`fail-fast: false`). Each row:
   `actions/checkout@v4` → `mlugg/setup-zig@v2` (`version: 0.15.2`, auto-caches the global zig
   cache) → `Run tests (ReleaseFast)`: `zig build --fetch` then `zig build test -Doptimize=ReleaseFast`
   (`env: ZIG_HTTP_MAX_CONNS: "1"`).
2. Top-level: `on: { push:, pull_request: }` (every branch + every PR) and
   `permissions: { contents: read }` (least-privilege; the job writes nothing).

`-Doptimize=ReleaseFast` is **mandatory** (PRD §15 Debug linker bug). SIMD stays **ON** (no
`-Dsimd=false`) so the SIMD code paths are exercised — ReleaseFast links cleanly with SIMD (verified
locally). `--fetch` + `ZIG_HTTP_MAX_CONNS=1` are required because the test binary links ghostty-vt
(`render.zig`/`palette.zig`/`tui/view.zig` `@import("ghostty-vt")`), so ghostty + its ~25 transitive
C++ SIMD sub-deps must be fetched on a clean runner (same as release.yml's build).

### Success Criteria

- [ ] `.github/workflows/ci.yml` exists and is valid YAML (`python3 yaml.safe_load` / `actionlint`).
- [ ] Trigger is `push` + `pull_request` (every branch + every PR); NOT `v*` tags.
- [ ] The `test` job matrix has exactly 2 hosts: `ubuntu-latest` + `macos-latest`; `fail-fast: false`.
- [ ] The test step runs `zig build test -Doptimize=ReleaseFast` (ReleaseFast flag PRESENT — the
      whole point; a bare `zig build test` fails to link in Debug per PRD §15).
- [ ] The test step runs `zig build --fetch` first, with `env: ZIG_HTTP_MAX_CONNS: "1"` (the test
      binary links ghostty-vt → deps must be fetched; caps HTTP conns to avoid rate-limiting).
- [ ] SIMD is ON (no `-Dsimd=false`) — ReleaseFast links cleanly with SIMD; `-Dsimd=false` would skip
      the SIMD paths and reduce coverage.
- [ ] `mlugg/setup-zig@v2` with `version: 0.15.2` (matches release.yml + build.zig.zon
      `minimum_zig_version`).
- [ ] `permissions: contents: read` present (read-only; no release assets written).
- [ ] NO `test` job added to release.yml; NO source/build/script files modified. ci.yml is the only
      new file.
- [ ] (MANUAL, after merge) Branch protection requires `ci / test (ubuntu-latest)` +
      `ci / test (macos-latest)` before merge.

## All Needed Context

### Context Completeness Check

_If someone knew nothing about this codebase, would they have everything needed to implement this
successfully?_ **YES.** This PRP embeds: the COMPLETE copy-ready `ci.yml` (verbatim in
`research/design_notes.md §1` — it IS the spec); WHY ReleaseFast is mandatory (PRD §15's
`R_X86_64_PC64` Debug linker bug, + the local verification that ReleaseFast exits 0 with 275 tests
green); WHY the test binary needs `--fetch` + `ZIG_HTTP_MAX_CONNS=1` (it links ghostty-vt via
render.zig/palette.zig/tui/view.zig); WHY SIMD stays on (the bug is Debug-only; ReleaseFast links
cleanly with SIMD, verified); the `test` step's reach (golden + unit, because build.zig's `addTest`
uses `exe.root_module` which roots all of src + testdata); the parallel-S1 boundary (release.yml is
build+release on `v*` tags; ci.yml is tests on push/PR — separate files, no conflict); the
mlugg/setup-zig caching fact (auto-caches global zig cache, no separate cache action); the
macos-latest = arm64 fact; and the OUTPUT gating truth (branch protection is a manual repo setting,
analogous to S1's manual draft-publish).

### Documentation & References

```yaml
# MUST READ — the COMPLETE, copy-ready spec for THIS subtask (the YAML is verbatim + final).
- docfile: plan/001_0c8587f91cb2/P4M1T1S2/research/design_notes.md
  why: §1 is the COMPLETE ci.yml (write it verbatim). §2 = per-decision rationale table. §3 = the 9
       gotchas (ReleaseFast mandatory; NO -Dsimd=false; --fetch required; separate file; gating is
       manual; macos-latest=arm64; double-run; no workflow_dispatch; can't run locally). §4 = the
       local verification. §5 = the branch-protection gating step. This IS the implementation.
  section: "§1 The COMPLETE ci.yml" + "§3 Gotchas" + "§5 PR gating"

# MUST READ — provenance for the action/runner/permissions facts.
- docfile: plan/001_0c8587f91cb2/P4M1T1S2/research/reference_notes.md
  why: §1 = mlugg/setup-zig@v2 (version input + AUTO-caches global zig cache ⇒ no cache action).
       §2 = macos-latest=arm64 (Apple Silicon GA; macos-13 Intel retiring Dec 2025). §3 = canonical
       `zig build test` on push/PR pattern (checkout→setup-zig→test). §4 = read-only permissions.
       §5 = PRD §15 R_X86_64_PC64 Debug linker bug (primary source). §6 = why --fetch +
       ZIG_HTTP_MAX_CONNS=1 carry over from release.yml. URLs to every claim.
  section: "all"

# The PARALLEL sibling (P4.M1.T1.S1) — what release.yml already is; do NOT duplicate or conflict.
- docfile: plan/001_0c8587f91cb2/P4M1T1S1/PRP.md
  why: release.yml is the CONTRACT boundary: it fires ONLY on `v*` tags (+workflow_dispatch), has
       jobs `build` (4-target matrix) + `release`, and explicitly contains NO test job ("S2 owns
       that"). ci.yml must be a SEPARATE file (different trigger) and must NOT add a test job to
       release.yml. Mirror release.yml's conventions: same `mlugg/setup-zig@v2` version 0.15.2,
       same `ZIG_HTTP_MAX_CONNS: "1"` env, same `zig build --fetch` first-step pattern.
  section: "Goal + Implementation Tasks (the build/release structure ci.yml must NOT touch)"

# The build + test step definitions — proves what `zig build test` reaches.
- file: build.zig
  why: (a) `b.standardOptimizeOption(.{})` ⇒ `-Doptimize=ReleaseFast` is honored by the `test` step
       (PRD §15 workaround). (b) `const test_step = b.step("test", …); const tests = b.addTest(.{
       .root_module = exe.root_module });` ⇒ `zig build test` builds + runs ALL tests reachable
       from exe.root_module = the golden harness (src/golden_test.zig) + every per-file unit test
       (cli/palette/render/capture/tui/region/main) — a SINGLE command covers "golden + unit". (c)
       `exe.root_module.addImport("ghostty-vt", …)` ⇒ the test binary LINKS ghostty-vt ⇒ the dep
       must be fetched on CI (⇒ `--fetch` + `ZIG_HTTP_MAX_CONNS=1`).
  pattern: "standardOptimizeOption + addTest(.{.root_module = exe.root_module}) + ghostty-vt import"
  gotcha: "`zig build test` with NO -Doptimize defaults to Debug, which hits the R_X86_64_PC64
          linker bug (PRD §15). The -Doptimize=ReleaseFast flag is MANDATORY."

# The Debug linker bug — the entire reason ReleaseFast is required.
- docfile: PRD.md
  why: §15 "Testing strategy" — the normative note: "`zig build test` currently hits a Zig Debug-mode
       linker bug (`R_X86_64_PC64`) with the bundled C++ SIMD libs … release builds are unaffected.
       CI should run tests in `ReleaseFast` or track the upstream fix." This is the PRIMARY source
       for the -Doptimize=ReleaseFast requirement. §15 also defines the test SUITE (golden
       testdata/*.ansi→*.html byte-equality + selection/palette/capture/CLI unit tests) that this
       job runs. §11 confirms Zig 0.15.2 pinned (⇒ setup-zig version 0.15.2) + `--release=fast`.
  section: "15. Testing strategy" + "11. Build & release"

# setup-zig action — confirms the version input + auto-cache behavior.
- url: https://github.com/marketplace/actions/setup-zig-compiler
  why: confirms `with: { version: <semver> }` input + "The global Zig cache directory is
       automatically cached between runs, and all local caches are redirected to the global cache"
       ⇒ NO separate actions/cache step is needed. (Mirror: https://codeberg.org/mlugg/setup-zig.)
  critical: "setup-zig@v2 auto-caches the global zig cache — do NOT add a redundant actions/cache
             step for it; it would just duplicate work."
```

### Current Codebase tree (run `ls -la .github/workflows/`)

```bash
$ ls -la .github/workflows/
release.yml        # P4.M1.T1.S1 — build (4-target) + release (draft). Fires on `v*` tags + workflow_dispatch. NO test job.
# (ci.yml does NOT exist yet — THIS TASK creates it.)
$ tree -L 2 -I 'zig-cache|zig-out|zig-pkg|.git' --dirsfirst
.
├── build.zig            # `test` step = addTest(.{.root_module=exe.root_module}); honors -Doptimize; links ghostty-vt
├── build.zig.zon        # minimum_zig_version 0.15.2 (⇒ setup-zig version); .version 0.1.0
├── .github/
│   └── workflows/
│       └── release.yml  # P4.M1.T1.S1 (parallel). UNCHANGED by this task.
├── docs/
├── licenses/
├── PRD.md               # §15 = the ReleaseFast mandate + test-suite definition; §11 = Zig 0.15.2
├── scripts/
│   ├── download.sh
│   └── ensure_binary.sh
├── src/                 # the Zig sources (UNCHANGED) — render.zig/palette.zig/tui/view.zig import ghostty-vt
├── testdata/            # golden fixtures (.ansi/.html) + embed.zig (UNCHANGED; the tests run them)
├── tmux-2html.tmux
└── LICENSE
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
.github/
└── workflows/
    ├── release.yml      # UNCHANGED (P4.M1.T1.S1). build (4-target) + release (draft) on `v*` tags. NO test job.
    └── ci.yml           # NEW (THIS TASK). `test` job on 2-host matrix; `zig build test -Doptimize=ReleaseFast`
                         #   on push + pull_request. Gates PRs on green ReleaseFast tests (via branch protection).
# (No source/build/script changes. Only ONE new file: .github/workflows/ci.yml.)
```

`.github/workflows/ci.yml` responsibilities:
- Trigger on every `push` + `pull_request` (every branch; NOT `v*` tags).
- `test` job, matrix `os: [ubuntu-latest, macos-latest]`, `fail-fast: false`:
  `actions/checkout@v4` → `mlugg/setup-zig@v2` (0.15.2) → `zig build --fetch` then
  `zig build test -Doptimize=ReleaseFast` (`env: ZIG_HTTP_MAX_CONNS: "1"`).
- `permissions: contents: read` (read-only; no release assets).

### Known Gotchas of our codebase & Library Quirks

```yaml
# CRITICAL: -Doptimize=ReleaseFast is MANDATORY. PRD §15: Debug-mode `zig build test` hits a linker
# bug (R_X86_64_PC64) with the bundled C++ SIMD libs (simdutf/highway/utfcpp via ghostty); release
# builds are unaffected. A bare `zig build test` WILL fail to link on CI. Verified locally:
# `zig build test -Doptimize=ReleaseFast` exits 0 (275 tests green). Do NOT drop the flag.

# CRITICAL: do NOT add -Dsimd=false to the test job. The R_X86_64_PC64 bug is Debug-ONLY; ReleaseFast
# links cleanly WITH SIMD enabled (verified locally — the green run had no -Dsimd=false). Adding
# -Dsimd=false would SKIP the SIMD code paths, silently cutting test coverage. release.yml uses
# -Dsimd=false only on its two CROSS-compile targets (a cross-miscompilation concern) — NOT applicable
# to a native ReleaseFast test. Keep SIMD on.

# CRITICAL: the test binary LINKS ghostty-vt. src/render.zig, src/palette.zig, src/tui/view.zig all do
# @import("ghostty-vt"). build.zig's test step is b.addTest(.{ .root_module = exe.root_module }) — the
# SAME module that imports ghostty-vt. So ghostty + its ~25 transitive C++ SIMD sub-deps MUST be
# fetched even for tests. On a clean CI runner: `zig build --fetch` pre-warms the global cache (and
# mlugg/setup-zig keeps it warm across runs); ZIG_HTTP_MAX_CONNS=1 caps the package manager's HTTP
# conns to avoid GitHub rate-limiting. Skipping --fetch risks a mid-compile fetch failure.

# CRITICAL: do NOT fold this into release.yml. release.yml triggers on push.tags:["v*"] + workflow_dispatch.
# Adding push/pull_request to release.yml would run the 4-target BUILD matrix on every PR (slow, wasteful).
# Keep ci.yml SEPARATE — a 2-host TEST matrix. P4.M1.T1.S1's release.yml is explicitly build+release-only
# and "leaves the test job to S2 (a separate .github/workflows/ci.yml)". No conflict, no duplication.

# CRITICAL: the OUTPUT "PRs are gated on green tests" is NOT enforced by the workflow file. The workflow
# PRODUCES status checks (ci / test (ubuntu-latest), ci / test (macos-latest)); turning them into a
# merge GATE requires enabling branch protection (Settings → Branches → Require status checks). That is
# a one-time MANUAL repo setting (see Validation Loop Level 4) — analogous to S1's manual draft→Publish.
# Until set, green tests are reported but NOT enforced on merges.

# NOTE: macos-latest is Apple Silicon (arm64) as of macos-14 (macos-13/Intel retiring Dec 2025). So the
# macos job tests aarch64-macos NATIVELY — exactly the dominant macOS arch we want covered. Do NOT pin
# macos-13 (decommissioned + costlier).

# NOTE: `on: [push, pull_request]` double-runs when you push to a branch with an open PR (one push event
# + one pull_request event). Acceptable for a small project (cheap, fast). OPTIONAL dedupe:
#   concurrency: { group: ci-${{ github.ref }}-${{ github.event_name }}, cancel-in-progress: true }
# The minimal correct workflow omits it.

# NOTE: mlugg/setup-zig@v2 AUTO-CACHES the global zig cache across runs (and redirects local caches into
# it). Do NOT add a redundant actions/cache step for the zig cache.

# NOTE: you CANNOT run a GitHub Actions workflow locally. Validation = YAML lint (python yaml.safe_load /
# actionlint) + the LOCAL `zig build test -Doptimize=ReleaseFast` run (proves the core command works on
# the host) + a manual push-a-branch-and-watch-the-Actions-tab end-to-end. See the Validation Loop.
```

## Implementation Blueprint

### Data models and structure

No code data models. The "data" is the workflow's 2-host matrix + the mandatory flags, both fully
specified in `research/design_notes.md §1` (the verbatim YAML) + §2 (the rationale table). The matrix
carries one column: `os` (`ubuntu-latest` | `macos-latest`).

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: CREATE .github/workflows/ci.yml (the ONLY deliverable)
  - WRITE the file with the COMPLETE YAML from research/design_notes.md §1 (verbatim). It is final.
  - STRUCTURE: `name: ci`; `on: { push:, pull_request: }` (every branch + every PR; NOT v* tags);
    `permissions: { contents: read }`; one job `test`.
  - JOB `test` (name: test (${{ matrix.os }}), strategy.fail-fast: false, matrix.os:
    [ubuntu-latest, macos-latest]): `actions/checkout@v4` → `mlugg/setup-zig@v2` (version: 0.15.2) →
    `Run tests (ReleaseFast)` step: `run: | zig build --fetch` newline `zig build test
    -Doptimize=ReleaseFast` with `env: ZIG_HTTP_MAX_CONNS: "1"`.
  - FLAGS: -Doptimize=ReleaseFast is MANDATORY (PRD §15 Debug linker bug). SIMD stays ON (NO
    -Dsimd=false — the bug is Debug-only; ReleaseFast links cleanly with SIMD, verified locally).
  - NAMING: workflow `name: ci` → status checks appear as `ci / test (ubuntu-latest)` +
    `ci / test (macos-latest)` (these exact names are what branch protection must require).
  - FOLLOW pattern: P4.M1.T1.S1's release.yml for the shared pieces — same `actions/checkout@v4`,
    same `mlugg/setup-zig@v2` version 0.15.2, same `zig build --fetch` first-step + same
    `ZIG_HTTP_MAX_CONNS: "1"` env (the test binary links the same ghostty dep graph as the build).
  - GOTCHA: NO edit to release.yml (do NOT add a test job there). NO edit to build.zig /
    build.zig.zon / src / scripts / testdata. ci.yml is the ONLY new file.

Task 2: VALIDATE YAML + lint (local — see Validation Loop Level 1)
  - RUN: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml'))" && echo OK`
    (zero-deps syntax check).
  - RUN (best effort): `actionlint .github/workflows/ci.yml` (catches unknown action inputs /
    expression typos; install via `go install github.com/rhysd/actionlint/cmd/actionlint@latest`
    or download the release binary). If unavailable, the python yaml parse + a careful read suffice.
  - EXPECTED: zero errors. The pickiest YAML spots: the `env:` map indentation under the `run:` step,
    the `matrix:` list form. Fix any indentation/quoting before proceeding.

Task 3: VERIFY the core test command locally (proves the PRD §15 workaround works — both OS classes
  share the same build.zig, so a green local ReleaseFast run is strong evidence both CI hosts pass)
  - RUN: `zig build --fetch && zig build test -Doptimize=ReleaseFast ; echo "EXIT=$?"`
  - EXPECTED: EXIT=0. (stderr noise like "tmux-2html: unknown subcommand …" or "[default] (warn):
    palette: only 1/256 colors captured" is EXPECTED — those are tests that intentionally exercise
    error/warning code paths, NOT failures. The exit code is the signal.)
  - ASSERT the suite ran BOTH golden + unit: the build.zig `test` step is
    `b.addTest(.{ .root_module = exe.root_module })`, so a green run covers src/golden_test.zig
    (golden) + every per-file unit test. (275 test fns total.) No extra flag needed.
  - NOTE: this proves the COMMAND; the actual 2-host CI run is the manual end-to-end (Task 4).

Task 4: (MANUAL, after merge) END-TO-END via a real push/PR + enable branch-protection gating
  - Push a branch (or open a PR) → watch the Actions tab: `ci / test (ubuntu-latest)` +
    `ci / test (macos-latest)` both run `zig build --fetch` + `zig build test -Doptimize=ReleaseFast`
    and go green.
  - (Smoke the gate) Temporarily break a golden (e.g. append a byte to testdata/colors16.html on a
    throwaway branch) → push → confirm BOTH jobs (or at least the one whose fixture you broke) go
    RED and the run fails. Revert.
  - (Enable gating) Repo Settings → Branches → Add rule for the default branch (e.g. `main`) →
    ✅ "Require status checks to pass before merging" → add `ci / test (ubuntu-latest)` AND
    `ci / test (macos-latest)`. Now PRs cannot merge until both are green.
```

### Implementation Patterns & Key Details

```yaml
# === The trigger (every commit + every PR; NOT tags) ===
#   on:
#     push:
#     pull_request:

# === Least-privilege permissions (read-only; no release assets written) ===
#   permissions:
#     contents: read

# === The 2-host matrix (native test hosts; fail-fast: false so one OS doesn't cancel the other) ===
#   jobs:
#     test:
#       name: test (${{ matrix.os }})
#       runs-on: ${{ matrix.os }}
#       strategy:
#         fail-fast: false
#         matrix:
#           os: [ubuntu-latest, macos-latest]   # linux-x86_64 native + macos-arm64 native
#       steps:
#         - uses: actions/checkout@v4
#         - uses: mlugg/setup-zig@v2
#           with:
#             version: 0.15.2
#         - name: Run tests (ReleaseFast)
#           run: |
#             zig build --fetch
#             zig build test -Doptimize=ReleaseFast
#           env:
#             ZIG_HTTP_MAX_CONNS: "1"

# === WHY each non-obvious line (see design_notes §2 for the full table) ===
#   -Doptimize=ReleaseFast : MANDATORY — PRD §15 Debug R_X86_64_PC64 linker bug with the C++ SIMD libs.
#   no -Dsimd=false         : the bug is Debug-only; ReleaseFast links cleanly WITH SIMD (verified),
#                             so the SIMD paths are actually tested. Adding it would cut coverage.
#   zig build --fetch       : the test binary links ghostty-vt (render/palette/tui/view @import it);
#                             deps must be fetched on a clean runner. Fails fast on download errors.
#   ZIG_HTTP_MAX_CONNS=1    : caps the package manager's HTTP conns while fetching ghostty's ~25 C++
#                             SIMD sub-deps from github.com — avoids rate-limiting. Same as release.yml.
#   setup-zig@v2            : auto-caches the global zig cache across runs (no separate cache action).
#   macos-latest            : arm64 (Apple Silicon) native — the dominant macOS arch (macos-13/Intel
#                             retiring Dec 2025). Do NOT pin macos-13.
```

### Integration Points

```yaml
TRIGGER:
  - on.push:           # every branch (NOT tags — release.yml owns v*)
  - on.pull_request:   # every PR (incl. forks; token is read-only + no secrets — we use none)
PERMISSIONS:
  - top-level `permissions: { contents: read }`  # read-only; no release assets, no writes
BUILD (NO change):
  - build.zig `test` step = addTest(.{.root_module = exe.root_module}); honors -Doptimize (⇒ ReleaseFast
    works); the test binary links ghostty-vt (⇒ --fetch + ZIG_HTTP_MAX_CONNS=1 required on CI).
PARALLEL-S1 BOUNDARY (P4.M1.T1.S1):
  - release.yml is build+release on `v*` tags (+workflow_dispatch), explicitly NO test job. ci.yml is a
    SEPARATE file on push/PR. Do NOT add a test job to release.yml; do NOT duplicate the 4-target matrix.
OUTPUT (PR gating):
  - The workflow PRODUCES status checks `ci / test (ubuntu-latest)` + `ci / test (macos-latest)`.
    Enforcing them as a merge gate = a MANUAL branch-protection setting (Settings → Branches → Require
    status checks). Documented in Validation Loop Level 4. The workflow file alone does NOT block merges.
```

## Validation Loop

> **NOTE**: a GitHub Actions workflow CANNOT be run locally. Validation is therefore (1) YAML
> well-formedness + lint, (2) the LOCAL `zig build test -Doptimize=ReleaseFast` run (proves the core
> command + the PRD §15 workaround work — both CI OS classes share the same build.zig), (3) a manual
> push-a-branch / open-a-PR end-to-end, (4) enabling branch-protection gating (the OUTPUT).

### Level 1: Syntax & Style (Immediate Feedback — local)

```bash
# Zero-dependency YAML parse (python3 is on the runners + most dev boxes):
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml'))" && echo "YAML OK"
# Expected: prints "YAML OK". A parse error ⇒ indentation/quoting bug (check the `env:` map under the
#   `run:` step + the `matrix:` list — the pickiest spots). Fix before proceeding.

# Best-effort workflow linter (catches unknown action inputs / expression typos):
#   install: go install github.com/rhysd/actionlint/cmd/actionlint@latest  (or grab the release binary)
actionlint .github/workflows/ci.yml
# Expected: zero errors. If actionlint flags an action it can't fetch (offline), that's informational;
#   focus on the structural/expression errors it CAN detect offline.

# NOTE on `yamllint`: it may warn `[truthy]` on the top-level `on:` key (YAML 1.1 treats bare `on`/`off`
#   as booleans). That is a FALSE POSITIVE — GitHub Actions reads `on:` as the trigger map correctly.
#   Do NOT "fix" it by quoting to `"on":` (harmless if you do, but unnecessary). actionlint (the
#   authoritative check for Actions syntax) accepts bare `on:`.
```

### Level 2: Local Verification of the core test command (proves the PRD §15 workaround)

```bash
# (a) Confirm Zig version matches build.zig.zon minimum_zig_version + the setup-zig pin:
zig version          # == 0.15.2

# (b) Run the EXACT command the CI job runs (proves ReleaseFast links + all tests pass):
zig build --fetch && zig build test -Doptimize=ReleaseFast ; echo "EXIT=$?"
# Expected: EXIT=0. stderr noise like "tmux-2html: unknown subcommand 'no-such-subcommand'" or
#   "[default] (warn): palette: only 1/256 colors captured" is EXPECTED — those are tests that
#   intentionally exercise error/warning code paths, NOT failures. The exit code is the signal.

# (c) Sanity: confirm the suite ran BOTH golden + unit (no extra flag needed — the build.zig `test`
#     step is addTest(.{.root_module = exe.root_module}), which roots all of src + the testdata module):
grep -n "addTest\|root_module = exe.root_module" build.zig
# Expected: shows `const tests = b.addTest(.{ .root_module = exe.root_module });` ⇒ one `zig build test`
#   covers src/golden_test.zig (golden) + every per-file unit test. The contract's "golden + unit" is
#   satisfied by the single command.

# (d) (Negative control, optional) Confirm Debug mode DOES hit the bug (proves WHY ReleaseFast is
#     mandatory) — run ONLY if you want to reproduce PRD §15; this is expected to fail to link:
#   zig build test 2>&1 | grep -i "R_X86_64_PC64\|error" || echo "(Debug link may or may not reproduce here)"
```

### Level 3: Integration Testing (MANUAL — a real push/PR; needs the repo on GitHub)

```bash
# (a) Push a feature branch (or open a PR) and watch the Actions tab:
git checkout -b ci-test-smoke
git push -u origin ci-test-smoke
# Watch: `ci / test (ubuntu-latest)` + `ci / test (macos-latest)` both run `zig build --fetch` +
#   `zig build test -Doptimize=ReleaseFast` and go GREEN. (If you opened a PR, both status checks
#   appear on it.) Both jobs should take a few minutes (first run fetches ghostty's deps; later runs
#   use setup-zig's cached global zig cache).

# (b) Smoke the gate (prove a test failure turns the run RED): on a throwaway branch, break a golden
#     fixture, push, confirm the run fails, then revert:
git checkout -b ci-test-negative
printf 'X' >> testdata/colors16.html      # append one byte ⇒ golden byte-equality fails
git add testdata/colors16.html && git commit -m "ci smoke: break a golden"
git push -u origin ci-test-negative
# Watch: `ci / test (ubuntu-latest)` (+ macos) go RED; the run's test step prints the golden mismatch
#   ([golden] fixture 'colors16' mismatch …). This proves test FAILURE fails the build (the gate signal).
git checkout main && git branch -D ci-test-negative   # cleanup the throwaway (also delete the remote branch)
```

### Level 4: Enable PR-gating (the OUTPUT — a manual branch-protection setting; do once, after merge)

```bash
# The workflow PRODUCES status checks; branch-protection ENFORCES them as a merge gate. This is a
# one-time repo setting (UI), NOT a file edit — analogous to P4.M1.T1.S1's manual draft→Publish:
#
#   Repo → Settings → Branches → Add branch protection rule for the default branch (e.g. "main"):
#     ✅ Require status checks to pass before merging
#         → search + add:  ci / test (ubuntu-latest)
#         → search + add:  ci / test (macos-latest)
#     (optional) ✅ Require branches to be up to date before merging
#     (optional) ✅ Do not allow bypassing the above settings
#
# After this: opening a PR shows the two checks; merge is BLOCKED until both are green. That is the
# contract's OUTPUT ("PRs are gated on green ReleaseFast tests") fully realized.
#
# (CLI alternative, if you prefer gh:) gh api repos/:owner/:repo/branches/main/protection …
#   — but the UI path is simpler + self-documenting. Either way it's a one-time manual config.
```

## Final Validation Checklist

### Technical Validation

- [ ] `.github/workflows/ci.yml` is valid YAML (`python3 -c "import yaml; yaml.safe_load(...)"`).
- [ ] `actionlint .github/workflows/ci.yml` (if available) reports zero structural errors.
- [ ] Local verification (Level 2): `zig build --fetch && zig build test -Doptimize=ReleaseFast`
      exits 0; the build.zig `test` step covers golden + unit (addTest uses exe.root_module).

### Feature Validation

- [ ] Trigger is `push` + `pull_request` (every branch + every PR); NOT `v*` tags.
- [ ] `test` job matrix = exactly `[ubuntu-latest, macos-latest]`; `fail-fast: false`.
- [ ] Test step runs `zig build test -Doptimize=ReleaseFast` (ReleaseFast flag PRESENT — PRD §15).
- [ ] Test step runs `zig build --fetch` first, with `env: ZIG_HTTP_MAX_CONNS: "1"` (test binary
      links ghostty-vt → deps fetched; caps HTTP conns).
- [ ] SIMD ON (NO `-Dsimd=false`) — ReleaseFast links cleanly with SIMD; SIMD paths exercised.
- [ ] `mlugg/setup-zig@v2` with `version: 0.15.2` (matches release.yml + build.zig.zon).
- [ ] `permissions: contents: read` present (read-only).
- [ ] NO `test` job added to release.yml; NO source/build/script/testdata files modified.
- [ ] (MANUAL) A push/PR → both `ci / test` jobs green; a broken golden → run RED.
- [ ] (MANUAL) Branch protection requires `ci / test (ubuntu-latest)` + `ci / test (macos-latest)`.

### Code Quality Validation

- [ ] Mirrors release.yml's shared conventions (setup-zig@v2 0.15.2, --fetch, ZIG_HTTP_MAX_CONNS=1).
- [ ] Inline comments explain the non-obvious choices (why ReleaseFast; why no -Dsimd=false; why
      --fetch for a test; macos-latest=arm64; the gating-is-manual truth) so a future maintainer
      doesn't "simplify" it into breaking.
- [ ] File placement matches the desired tree (`.github/workflows/ci.yml`, alongside release.yml).

### Documentation & Deployment

- [ ] Inline comments document WHY (PRD §15 Debug linker bug; ghostty-vt link ⇒ --fetch; SIMD-on;
      separate-file-from-release.yml; status-check-vs-branch-protection).
- [ ] No new env vars / secrets required (deps are public; default GITHUB_TOKEN suffices, scoped read).

---

## Anti-Patterns to Avoid

- ❌ Don't drop `-Doptimize=ReleaseFast` — PRD §15 Debug linker bug (`R_X86_64_PC64`) with the C++
  SIMD libs makes a bare `zig build test` fail to link on CI. ReleaseFast is mandatory.
- ❌ Don't add `-Dsimd=false` to the test job — the bug is Debug-only; ReleaseFast links cleanly WITH
  SIMD (verified locally). `-Dsimd=false` would skip the SIMD code paths, cutting coverage.
- ❌ Don't fold the test job into release.yml — release.yml triggers on `v*` tags; tests must run on
  every push/PR. Different trigger ⇒ separate file (ci.yml). Adding the test job to release.yml would
  also re-run the 4-target BUILD matrix on every PR (wasteful).
- ❌ Don't skip `zig build --fetch` or `ZIG_HTTP_MAX_CONNS=1` — the test binary links ghostty-vt
  (render/palette/tui/view `@import` it), so ghostty + ~25 C++ SIMD sub-deps must be fetched on a
  clean runner; the env caps HTTP conns to avoid GitHub rate-limiting. (Same as release.yml's build.)
- ❌ Don't add a redundant `actions/cache` step for the zig cache — `mlugg/setup-zig@v2` already
  auto-caches the global zig cache across runs (and redirects local caches into it).
- ❌ Don't pin `macos-13` (Intel) — `macos-latest` is arm64/Apple Silicon (the dominant macOS arch);
  macos-13/Intel is being retired (Dec 2025) and is costlier.
- ❌ Don't assume the workflow file alone "gates PRs" — the workflow PRODUCES status checks; ENFORCING
  them as a merge gate is a manual branch-protection setting (Settings → Branches). Document + do it.
- ❌ Don't add `workflow_dispatch` "for symmetry" with release.yml — ci.yml fires on every push/PR
  already; a manual trigger is redundant (you can re-run any run from the Actions UI).
- ❌ Don't edit release.yml / build.zig / build.zig.zon / src / scripts / testdata — this task is CI
  infra only; the ONE deliverable is `.github/workflows/ci.yml`.
- ❌ Don't expand scope (add `zig fmt --check`, coverage upload, a lint job, etc.) — the contract is
  "run golden + unit tests in ReleaseFast". Keep ci.yml to the single `test` job.

---

## Confidence Score

**9/10** — The deliverable is a SINGLE new file (`.github/workflows/ci.yml`) whose complete,
copy-ready YAML is authored verbatim in `research/design_notes.md §1` — it IS the spec, not a sketch.
The core command (`zig build test -Doptimize=ReleaseFast`) is VERIFIED working locally (exit 0, all
275 tests green), which is strong evidence both CI OS hosts (which share the identical build.zig)
will pass. The mandatory `-Doptimize=ReleaseFast` is anchored to the PRIMARY source (PRD §15's
`R_X86_64_PC64` Debug linker bug). The shared pieces (setup-zig@v2 0.15.2, `--fetch`,
`ZIG_HTTP_MAX_CONNS=1`) are mirrored from the parallel P4.M1.T1.S1 release.yml — already in the repo,
same dep graph (the test binary links ghostty-vt: render.zig/palette.zig/tui/view.zig `@import` it,
confirmed). The non-obvious choices are all documented with evidence: SIMD stays ON (bug is
Debug-only; ReleaseFast links cleanly with SIMD, verified); macos-latest = arm64 (GA, macos-13
retiring); setup-zig auto-caches the zig cache (no cache action); ci.yml is separate from release.yml
(different triggers). The ONE residual ambiguity — that "PR gating" is a manual branch-protection
setting, not a workflow-file property — is explicitly called out with the exact UI steps, analogous
to S1's manual draft→Publish gate.

Residual risks (all low): (1) CI can't be run locally — mitigated by the verified-local ReleaseFast
run + a manual push-smoke (incl. a negative-control broken-golden) + the branch-protection step.
(2) `actionlint` may not be installed — mitigated by the zero-deps `python3 yaml.safe_load` parse +
careful review. (3) A future Zig bump or ghostty bump could shift the Debug-link bug / cross-compile
behavior — but this task tests NATIVELY in ReleaseFast (the unaffected path), so it's insulated;
the matrix is 2 native hosts (no cross-compile, no `-Dsimd=false` cross concerns). (4) The
double-run-on-PR-branch behavior of `on: [push, pull_request]` is a minor noise issue with an
optional `concurrency:` fix documented in design_notes §3 — not a correctness problem. The PARALLEL
S1 (release.yml) is independent — this PRP's ci.yml is a separate file with a separate trigger, adds
no job to release.yml, and modifies no shared files, so there is no conflict.
