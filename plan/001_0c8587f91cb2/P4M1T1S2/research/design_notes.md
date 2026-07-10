# P4.M1.T1.S2 — CI test job (ReleaseFast): Design Notes

The COMPLETE, copy-ready `.github/workflows/ci.yml` (§1) + the design rationale (§2) + the
gotchas (§3) + the local verification that the test command works (§4) + the branch-protection
gating note (§5, the manual step that turns green-tests into PR gating).

---

## §1 The COMPLETE `.github/workflows/ci.yml` (write this verbatim — it IS the spec)

```yaml
name: ci

# Continuous testing: runs `zig build test -Doptimize=ReleaseFast` (golden + unit) on every
# push and pull request, on linux + macos. Gates PRs on green ReleaseFast tests.
#
# WHY ReleaseFast (not Debug): PRD §15 — `zig build test` in Debug hits a linker bug
# (R_X86_64_PC64) with the bundled C++ SIMD libs (simdutf/highway/utfcpp via ghostty);
# release builds are unaffected. So CI MUST pass -Doptimize=ReleaseFast. Verified locally:
# `zig build test -Doptimize=ReleaseFast` exits 0 with all 275 tests green.
#
# WHY a SEPARATE file (not a job in release.yml): release.yml fires ONLY on `v*` tags (+ an
# optional workflow_dispatch) to build+publish prebuilt binaries. Tests must run on EVERY
# commit/PR, not just releases. Different trigger ⇒ separate workflow file. (P4.M1.T1.S1's
# release.yml is explicitly build+release only; it leaves the test job to this task — S2.)

on:
  push:
  pull_request:

# Least-privilege: this job only reads the repo + fetches PUBLIC deps (ghostty/parg). It creates
# no release assets and writes nothing. The default GITHUB_TOKEN for push/PR is read-only anyway;
# this `permissions:` block makes the read-only intent explicit (good hygiene; harmless).
permissions:
  contents: read

jobs:
  test:
    name: test (${{ matrix.os }})
    runs-on: ${{ matrix.os }}
    strategy:
      fail-fast: false        # one OS failing must NOT cancel the other (maximizes signal)
      matrix:
        # ubuntu-latest = linux-x86_64 (native). macos-latest = macos-arm64 / Apple Silicon
        # (native, GA since macos-14). Tests run on the HOST arch natively — we do NOT need the
        # 4-target cross-matrix that release.yml uses; 2 native hosts cover "linux + macos".
        os: [ubuntu-latest, macos-latest]

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup Zig
        # mlugg/setup-zig@v2 downloads Zig 0.15.2 to PATH AND auto-caches the global zig cache
        # (~/.cache/zig on Linux, ~/Library/Caches/zig on macOS) across runs (it also redirects
        # all local caches into the global cache). So no separate cache action is needed. Mirrors
        # release.yml's Setup Zig step exactly (version pinned to build.zig.zon's minimum_zig_version).
        uses: mlugg/setup-zig@v2
        with:
          version: 0.15.2

      - name: Run tests (ReleaseFast)
        # `zig build test` builds + runs ALL tests reachable from exe.root_module: the golden
        # harness (src/golden_test.zig: testdata/*.ansi → byte-equal *.html, 2 test fns) AND every
        # per-file unit test (cli/palette/render/capture/tui/region/main = 273 fns; 275 total).
        #
        # --fetch pre-warms the global zig cache: the test binary LINKS ghostty-vt (render.zig,
        # palette.zig, tui/view.zig all @import("ghostty-vt")), so ghostty + its ~25 transitive
        # C++ SIMD sub-deps MUST be fetched even for tests. On a fresh CI runner this is the
        # first-fetch; setup-zig's cache makes later runs warm. --fetch also fails fast on
        # dep-download errors (instead of a confusing mid-compile failure).
        #
        # ZIG_HTTP_MAX_CONNS=1 caps the package manager's concurrent HTTP connections while
        # fetching ghostty's deps from github.com — avoids rate-limiting/connection exhaustion.
        # Same env release.yml uses for its build.
        #
        # SIMD stays ON (we do NOT pass -Dsimd=false): the Debug R_X86_64_PC64 bug is Debug-only;
        # ReleaseFast links cleanly WITH SIMD enabled (verified locally). Keeping SIMD on means
        # the SIMD code paths are actually exercised by the tests (better coverage). -Dsimd=false
        # would silently skip them.
        run: |
          zig build --fetch
          zig build test -Doptimize=ReleaseFast
        env:
          ZIG_HTTP_MAX_CONNS: "1"
```

---

## §2 Design rationale (each choice, with the evidence)

| Decision | Choice | Why / Evidence |
|---|---|---|
| **File** | NEW `.github/workflows/ci.yml` (separate from release.yml) | release.yml triggers ONLY on `v*` tags (+workflow_dispatch). The contract requires tests on every push/PR. Different trigger ⇒ separate file. P4.M1.T1.S1's release.yml is explicitly build+release-only and "leaves the test job to S2 (a separate task — most naturally a separate `.github/workflows/ci.yml`)". A separate file is also the idiomatic GH Actions split (ci.yml = continuous testing; release.yml = releases). |
| **Trigger** | `on: { push:, pull_request: }` (every branch + every PR) | Contract §3: "a CI job (on push/PR)". The array/map form runs on ANY branch push + ANY PR — broadest coverage, simplest match to the contract. (Minor: this double-runs when you push to a branch that has an open PR — acceptable for a small project; an optional `concurrency:` group could dedupe, see §3.) |
| **Matrix** | `os: [ubuntu-latest, macos-latest]` (2 jobs) | Contract §3: "on linux + macos". `ubuntu-latest`=linux-x86_64 (native); `macos-latest`=macos-arm64/Apple Silicon (native, GA since macos-14). Tests run on the HOST arch natively — the 4-target cross-matrix is a RELEASE concern (release.yml), not a test concern. 2 native hosts cover the two OSes the contract names. |
| **`fail-fast: false`** | yes | One OS failing must NOT cancel the other (maximizes signal; matches release.yml's choice). |
| **Test command** | `zig build test -Doptimize=ReleaseFast` | Contract §1/§3 + PRD §15: Debug `zig build test` hits the R_X86_64_PC64 linker bug with the C++ SIMD libs; ReleaseFast is unaffected. Verified locally: exits 0, all 275 tests pass. |
| **`zig build --fetch` first** | yes | The test binary links ghostty-vt (render.zig/palette.zig/tui/view.zig `@import("ghostty-vt")`), so ghostty + ~25 transitive C++ SIMD sub-deps MUST be fetched even for tests. On a fresh CI runner `--fetch` pre-warms the cache + fails fast on dep-download errors. Same step release.yml uses for the build. |
| **`ZIG_HTTP_MAX_CONNS: "1"`** | yes | Caps the package manager's concurrent HTTP conns while fetching ghostty's deps from github.com — avoids rate-limiting/connection exhaustion. Same env release.yml uses. |
| **SIMD stays ON (no `-Dsimd=false`)** | yes | The R_X86_64_PC64 bug is **Debug-only**; ReleaseFast links cleanly WITH SIMD (verified locally). Keeping SIMD on means the SIMD code paths are actually tested. `-Dsimd=false` would skip them. (release.yml uses `-Dsimd=false` only on its two CROSS-compile targets — a cross-miscompilation concern, NOT the Debug linker bug; irrelevant to a native ReleaseFast test.) |
| **Setup Zig** | `mlugg/setup-zig@v2` with `version: 0.15.2` | Matches release.yml + build.zig.zon `minimum_zig_version = "0.15.2"`. setup-zig@v2 also auto-caches the global zig cache across runs (and redirects local caches into it) — no separate cache action needed. |
| **`permissions: contents: read`** | yes (least-privilege hygiene) | The job only reads the repo + fetches PUBLIC deps; creates no release assets. Default token for push/PR is read-only anyway; making it explicit is good hygiene. (For `pull_request` from forks, the token is already read-only + secrets unavailable — we use no secrets, so this is fine.) |
| **No release/upload/download steps** | correct | This is a TEST job, not a release job. No artifacts to upload (test pass/fail is the signal). |

---

## §3 Gotchas (the non-obvious traps)

1. **ReleaseFast is MANDATORY, not optional.** The PRD §15 R_X86_64_PC64 linker bug fires in
   **Debug** mode with the C++ SIMD libs. A bare `zig build test` (which defaults to Debug) WILL
   fail to link on CI. You MUST pass `-Doptimize=ReleaseFast`. This is the entire reason this task
   exists. (Verified: `zig build test -Doptimize=ReleaseFast` exits 0 locally; `zig build test`
   alone does not.) Do NOT "simplify" by dropping the flag.

2. **Do NOT add `-Dsimd=false` to the test job.** The bug is Debug-only; ReleaseFast links
   cleanly WITH SIMD. `-Dsimd=false` would skip the SIMD code paths, silently reducing coverage.
   release.yml uses `-Dsimd=false` only on its two CROSS targets (a cross-miscompilation concern),
   which is a different problem. Tests run NATIVELY in ReleaseFast — keep SIMD on. (Confirmed: the
   local `zig build test -Doptimize=ReleaseFast` run had no `-Dsimd=false` and passed.)

3. **The test binary links ghostty-vt — `--fetch` + `ZIG_HTTP_MAX_CONNS=1` are required even for
   tests.** `src/render.zig`, `src/palette.zig`, and `src/tui/view.zig` all do
   `@import("ghostty-vt")`. The build.zig `test` step is `b.addTest(.{ .root_module = exe.root_module })`
   — i.e. the SAME module that imports ghostty-vt. So the test binary pulls in ghostty + its ~25
   transitive C++ SIMD sub-deps. On a fresh CI runner these are not yet cached; `--fetch`
   pre-warms the global cache (and setup-zig keeps it warm across runs). Skipping `--fetch` risks
   a mid-compile fetch failure or GitHub rate-limiting while compiling.

4. **Do NOT fold this into release.yml.** release.yml's trigger is `push.tags: ["v*"]` +
   `workflow_dispatch`. Adding a `push:`/`pull_request:` trigger to release.yml would make the
   4-target build matrix run on every PR too (slow, wasteful, and not what's wanted). Keep ci.yml
   separate — it's a 2-job test matrix, release.yml is a 4-target build+release pipeline. S1's
   PRP explicitly scopes release.yml to build+release and defers the test job to this file.

5. **The OUTPUT "PRs are gated on green tests" is NOT enforced by the workflow file.** A workflow
   produces a STATUS CHECK (e.g. `ci / test (ubuntu-latest)`, `ci / test (macos-latest)`); turning
   that into a merge GATE requires enabling branch protection (Settings → Branches → Require status
   checks). That is a one-time MANUAL repo setting (see §5), exactly analogous to how S1's release
   draft-publish is a manual step. The workflow file alone does NOT block merges.

6. **`macos-latest` is Apple Silicon (arm64), NOT x86_64.** As of macos-14 (late 2024),
   `macos-latest` runs natively on arm64; macos-13 (Intel) is being retired (Dec 2025). So the
   macos job tests `aarch64-macos` natively. This is FINE — we want native test coverage on the
   dominant macOS arch. Do NOT try to force Intel (`macos-13`) — it's being decommissioned and is
   slower/more expensive. (Sources: github.blog changelog 2026-02-26 "macos-26 … run natively on
   Apple Silicon (arm64)"; github.blog 2025-09-19 "macOS 13 runner image is closing down".)

7. **`on: [push, pull_request]` double-runs on PR branches.** When you push to a branch that has
   an open PR, GitHub fires BOTH a `push` event and a `pull_request` event → 2 runs. For a small
   project this is acceptable (cheap tests, fast feedback). If it becomes noisy, add a
   `concurrency:` group to cancel superseded runs:
   ```yaml
   concurrency:
     group: ci-${{ github.ref }}-${{ github.event_name }}
     cancel-in-progress: true
   ```
   This is an OPTIONAL enhancement — the minimal correct workflow omits it.

8. **No `workflow_dispatch` needed (unlike release.yml).** release.yml has `workflow_dispatch` so
   you can smoke-test the build matrix without cutting a tag. ci.yml fires on every push/PR anyway,
   so a manual trigger is redundant. (You can always re-run a failed run from the Actions UI.)

9. **A GitHub Actions workflow CANNOT be run locally.** Validation = YAML lint (python
   `yaml.safe_load` / actionlint) + the LOCAL `zig build test -Doptimize=ReleaseFast` run (proves
   the core command works on both OS classes via the host) + a manual push-a-branch-and-watch-the-
   Actions-tab end-to-end. See the PRP's Validation Loop.

---

## §4 Local verification that the test command works (run on the dev host)

```bash
$ zig version
0.15.2
$ zig build test -Doptimize=ReleaseFast ; echo "EXIT=$?"
… (test output: stderr from CLI-error-path tests is EXPECTED — e.g.
    "tmux-2html: unknown subcommand 'no-such-subcommand'", "[default] (warn): palette: only
    1/256 colors captured" — these are tests that intentionally exercise error/warn paths) …
EXIT=0
```

- **Exit code 0** = all tests pass (the build.zig `test` step's `addRunArtifact` exits non-zero on
  any test failure). The stderr noise is NOT failure — it's the captured output of tests that
  deliberately invoke error/warning code paths (CLI dispatch on a bogus subcommand; palette
  capture against a non-terminal). Verified: 275 test fns total
  (19 cli + 28 palette + 18 render + 2 golden + 17 capture + 11 tui/app + 19 tui/view + 39
  tui/input + 53 tui/motion + 40 tui/select + 14 main + 15 region).
- **`zig build test` = golden + unit.** The `test` step is
  `b.addTest(.{ .root_module = exe.root_module })`. `exe.root_module` roots `src/main.zig`, which
  transitively pulls in every src file (incl. `src/golden_test.zig`) + the `testdata` module
  (`testdata/embed.zig`, which `@embedFile`s the fixtures). So a single `zig build test` run
  executes BOTH the golden harness AND all unit tests. Nothing extra is needed to satisfy the
  contract's "golden + unit tests".

---

## §5 The OUTPUT "PR gating" step is a manual branch-protection setting (do AFTER merge)

The contract's OUTPUT ("PRs are gated on green ReleaseFast tests") is realized by enabling
**branch protection** on the default branch — the workflow FILE only *produces* the status check.
One-time manual config (repo Settings → Branches → Add rule for the default branch, e.g. `main`):

- ✅ **Require status checks to pass before merging** → add `ci / test (ubuntu-latest)` AND
  `ci / test (macos-latest)`.
- (Optional) "Require branches to be up to date before merging".
- (Optional) "Do not allow bypassing the above".

This is analogous to how P4.M1.T1.S1's draft→Publish is a manual human gate. Document it in the
PRP's Validation Loop Level 3/4 so the implementer + reviewer don't forget. Until this is set,
green tests are reported but NOT enforced on merges.
