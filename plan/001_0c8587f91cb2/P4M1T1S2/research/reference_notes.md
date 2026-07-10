# P4.M1.T1.S2 — External Research Notes

Sources + exact facts backing the ci.yml design. (The complete ci.yml + rationale + gotchas live
in `design_notes.md`; this file is the provenance.)

---

## §1 `mlugg/setup-zig@v2` — the action release.yml already uses

**Repo:** https://github.com/mlugg/setup-zig (mirror: https://codeberg.org/mlugg/setup-zig)
**Marketplace:** https://github.com/marketplace/actions/setup-zig-compiler

Key facts (from the README + the Ziggit announcement https://ziggit.dev/t/github-actions-mlugg-setup-zig/4659):
- Input `version` (string): "You can use `version` to set a Zig version to download. This may be a
  release (`0.13.0`) or `master`." → `with: { version: 0.15.2 }` is correct and matches
  release.yml + `build.zig.zon`'s `minimum_zig_version`.
- **It AUTOMATICALLY caches the global Zig cache between runs** ("The global Zig cache directory
  (`~/.cache/zig` on Linux) is automatically cached between runs, and all local caches are
  redirected to the global cache" — README + Codeberg mirror + the `remove zig-action-cache as
  setup-zig does this now` commit at https://git.lerch.org/lobo/smithy/commit/47890eb9). ⇒ **No
  separate `actions/cache` step is needed** for the zig cache. (We still run `zig build --fetch`
  because the dependency fetch from github.com is what's being cached, and the first run on a
  cache miss must still fetch — `--fetch` makes that explicit + fail-fast.)
- The legacy `goto-bus-stop/setup-zig` redirects users to `mlugg/setup-zig`
  (https://github.com/goto-bus-stop/setup-zig/blob/default/README.md: "Please use mlugg/setup-zig
  instead"). ⇒ `mlugg/setup-zig` is the current canonical choice (which is what release.yml uses).

**Verdict for ci.yml:** use `mlugg/setup-zig@v2` with `version: 0.15.2`, identical to release.yml.

---

## §2 `macos-latest` is Apple Silicon (arm64) — confirmed

- github.blog changelog 2026-02-26 "macos-26 is now generally available … run natively on Apple
  Silicon (arm64)": https://github.blog/changelog/2026-02-26-macos-26-is-now-generally-available-for-github-hosted-runners/
- github.blog changelog 2025-09-19 "macOS 13 runner image is closing down" (retire by Dec 4 2025):
  https://github.blog/changelog/2025-09-19-github-actions-macos-13-runner-image-is-closing-down/
- actions/runner-images macos-14/macos-15 readmes confirm arm64:
  https://github.com/actions/runner-images/blob/main/images/macos/macos-14-Readme.md

**Implication:** the `macos-latest` test job runs on `aarch64-macos` natively. That's the dominant
macOS arch today — exactly what we want native test coverage on. Do NOT pin `macos-13` (Intel) —
it's being decommissioned + costs more. (release.yml's `macos-x86_64` is a CROSS target for binary
distribution; the test job is native and doesn't need that.)

---

## §3 Canonical GitHub Actions pattern for `zig build test` on push/PR

- **Latchkey Learn — "CI/CD for a Zig Project with GitHub Actions"**
  (https://latchkey.dev/learn/ci-recipes/ci-cd-for-a-zig-project-with-github-actions): the standard
  recipe is `actions/checkout` → `setup-zig` → `zig build test` (+ optional `zig fmt --check` +
  a release cross-compile job). This is exactly the 3-step shape our ci.yml uses.
- **Orhun's Blog — "Zig Bits 0x3"** (https://blog.orhun.dev/zig-bits-03/): shows a GitHub Actions
  workflow that "automates the process of building, testing, and checking the formatting of a
  project every time [a push/PR happens]" — same `on: [push, pull_request]` + matrix + `zig build
  test` shape.
- The idiomatic trigger for "run tests on every commit + PR" is `on: [push, pull_request]` (or the
  explicit map `on: { push:, pull_request: }`). Both are valid; the map form allows branch
  filters. We use the map form (no branch filter ⇒ all branches, broadest coverage, simplest match
  to the contract's "on push/PR").

**Common add-ons we deliberately OMIT** (scope: this task is "run golden + unit tests", nothing
more):
- `zig fmt --check` / `zig build -Demit-docs` / coverage upload — not in the contract; avoid scope
  creep. (Could be added in a later task if desired.)
- A separate `lint`/`build` job — not requested; the single `test` job is the deliverable.
- `actions/cache` for the zig cache — **redundant**; mlugg/setup-zig already caches it (§1).

---

## §4 Permissions for a read-only test job

- GitHub docs — "Automatic token authentication": for `pull_request` events (especially from forks)
  the `GITHUB_TOKEN` is read-only and secrets are NOT injected. For `push` events the token has
  the repo's default permissions. We use NO secrets (ghostty + parg are public) and write nothing.
- Adding an explicit `permissions: { contents: read }` at the top level is least-privilege hygiene
  (recommended by GitHub's security hardening guide) and is harmless. We include it.

---

## §5 The Debug R_X86_64_PC64 linker bug — why ReleaseFast (primary source = PRD §15)

PRD §15 (verbatim): "`zig build test` currently hits a Zig Debug-mode linker bug
(`R_X86_64_PC64`) with the bundled C++ SIMD libs on this toolchain; release builds are unaffected.
CI should run tests in `ReleaseFast` or track the upstream fix."

- The bug is in **Debug** mode linking the C++ SIMD libs (simdutf/highway/utfcpp, vendored via
  ghostty). `R_X86_64_PC64` is an x86-64 PC-relative 64-bit relocation that Debug-mode linking of
  those C++ objects mishandles.
- **ReleaseFast is unaffected** (PRD §15, + verified locally: `zig build test -Doptimize=ReleaseFast`
  exits 0). Hence the contract mandates `-Doptimize=ReleaseFast`.
- The contract's "or track upstream" alternative is OUT OF SCOPE here — we take the ReleaseFast path
  (the recommended, lowest-risk option). No build.zig changes are needed (the existing `test` step
  honors `-Doptimize` via `standardOptimizeOption`).

---

## §6 Why `zig build --fetch` + `ZIG_HTTP_MAX_CONNS=1` carry over from release.yml

These are NOT release-specific — they're "fetching ghostty's deps from github.com on a CI runner"
concerns, which the test job shares (the test binary links ghostty-vt; see design_notes §2/§3):

- `zig build --fetch`: pre-populates the global zig cache with ghostty + its ~25 transitive C++
  SIMD sub-deps, failing fast on a download error instead of mid-compile. (Same as release.yml's
  Build step.)
- `ZIG_HTTP_MAX_CONNS=1`: caps the package manager's concurrent HTTP connections to avoid
  GitHub rate-limiting / connection exhaustion while pulling those deps. (Same env release.yml uses.)

Both are inherited verbatim from the VERIFIED term2html reference workflow (P4.M1.T1.S1's
`reference_workflow.md §1`) and apply identically to the test job because the dep graph is the same.
