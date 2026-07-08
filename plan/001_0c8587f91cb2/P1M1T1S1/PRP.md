# PRP — P1.M1.T1.S1: `build.zig.zon` with ghostty + parg dependencies

## Goal

**Feature Goal**: Create the project's `build.zig.zon` build manifest declaring
the two verified dependencies (ghostty v1.3.1 and parg) so that
`zig build --fetch` resolves both successfully under the pinned Zig 0.15.2
toolchain. This is the foundation every subsequent Zig task builds on.

**Deliverable**: A single file, `build.zig.zon`, at the repository root
(`/home/dustin/projects/tmux-2html/build.zig.zon`), with exact dependency URLs
and content hashes. Plus the minimal on-disk scaffolding (empty dirs/files) the
manifest's `.paths` field requires so the manifest validates.

**Success Definition**: `zig build --fetch` exits 0 and both dependencies land
in the global Zig package cache under their declared hashes:

- `ghostty-1.3.1-5UdBCwYm-gQeBa4bu1-sMooCQS4KVriv5wWSIJ_sI-Cb`
- `parg-0.0.0-dOPWZNhYAABEHE6EGXmwIucnu9vj-emodT9vmHeYynAP`

## Why

- **Foundation for the whole build system.** No Zig code can compile until the
  manifest resolves its dependencies. This unblocks sibling task P1.M1.T1.S2
  (`build.zig` wiring) and everything downstream (the ghostty-vt renderer,
  parg CLI parser, TUI).
- **Pins the exact dependency versions** the architecture research verified by
  reading `aarol/term2html`'s real `build.zig.zon` and by live-fetching each
  tarball under Zig 0.15.2.
- **Locks the Zig toolchain.** `minimum_zig_version = "0.15.2"` is the version
  installed in this environment and the one term2html targets — confirmed real.

## What

A valid Zig 0.15.2 `build.zig.zon` at the repo root that:

1. Names the package `.tmux_2html` (underscore — see Gotcha 2).
2. Pins `version = "0.1.0"`, `minimum_zig_version = "0.15.2"`.
3. Declares exactly two dependencies — `ghostty` and `parg` — with the verified
   URLs and content hashes (copy verbatim — do NOT regenerate).
4. Declares `.paths` covering the repo layout the PRD specifies (§4).
5. Includes a `.fingerprint` value (REQUIRED in 0.15.2 — see Gotcha 1).
6. Creates the on-disk stubs every `.paths` entry points at so the manifest
   validates at fetch time.

The executable's hyphenated name (`tmux-2html`), the ghostty-vt module import,
version baking, the `-Dsimd` option, and the test step all live in
`build.zig` — that is **sibling task P1.M1.T1.S2**, explicitly out of scope here.
S1 ships only the manifest plus a minimal `build.zig` stub sufficient for
`zig build --fetch` to run.

### Success Criteria

- [ ] `build.zig.zon` exists at repo root with the exact content in the
      Blueprint below.
- [ ] All `.paths` entries exist on disk (stub dirs/files created).
- [ ] A minimal `build.zig` stub exists (so the build runner can evaluate the
      manifest for `--fetch`).
- [ ] `zig build --fetch` exits 0.
- [ ] Both deps appear in the global cache under their declared hashes (see
      Validation Loop §3).
- [ ] `zig version` reports `0.15.2` (the pinned toolchain is present).

## All Needed Context

### Context Completeness Check

_Pass: "If someone knew nothing about this codebase, would they have everything
needed to implement this successfully?"_ — Yes. The manifest is fully specified
verbatim below, every gotcha is documented, and the validation commands are
verified to run on the installed toolchain. No codebase knowledge required
(greenfield repo; only `PRD.md` + `plan/` exist today).

### Documentation & References

```yaml
# MUST READ - the authoritative source for deps (verified by reading term2html's real zon)
- file: plan/001_0c8587f91cb2/architecture/external_deps.md
  why: "§1 holds the EXACT ghostty v1.3.1 + parg URLs/hashes (verified). This PRP copies them verbatim."
  critical: "Do NOT regenerate hashes with `zig fetch --save`; they are already correct and risk a typo."

- file: plan/001_0c8587f91cb2/architecture/findings_and_corrections.md
  why: "§4 confirms Zig 0.15.2 is the pinned toolchain; §1 notes the greenfield repo state."
  pattern: "Read 'Project reality' — only PRD.md + plan/ exist; everything else is to be created."

- file: plan/001_0c8587f91cb2/P1M1T1S1/research/findings.md
  why: "Companion research note documenting the live-verification of every value in this PRP."
  critical: "Records the FINGERPRINT gotcha (§2) and parg URL username `judofhr` (§4) — both verified empirically against zig 0.15.2."

# Out-of-scope reference (for awareness of the handoff boundary, not to implement now)
- file: plan/001_0c8587f91cb2/architecture/external_deps.md
  section: "§2 build.zig wiring"
  why: "This is what SIBLING task P1.M1.T1.S2 will build on top of S1's manifest. Do NOT implement it here — S1 ships only a minimal build.zig stub."
```

### Current Codebase tree

```bash
# From repo root: tree -a -I '.git' --noreport   (or: find . -not -path '*/.git/*')
tmux-2html/
├── PRD.md
├── .gitignore
└── plan/
    └── 001_0c8587f91cb2/
        ├── tasks.json
        ├── prd_snapshot.md
        ├── prd_index.txt
        └── architecture/   (research_*.md, findings_and_corrections.md, external_deps.md, ...)
# NOTE: NO build.zig, NO build.zig.zon, NO src/, NO scripts/, etc. exist yet — greenfield.
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
tmux-2html/
├── build.zig              # (S1) MINIMAL STUB — empty build fn, enough for `zig build --fetch`.
│                          #        Full wiring (ghostty-vt import, -Dsimd, version, test step) is S2.
├── build.zig.zon          # (S1) THE DELIVERABLE — manifest: name, version, zig pin, ghostty+parg deps, paths.
├── src/                   # (S1) empty dir stub (in .paths; real src/main.zig lands in later tasks)
├── scripts/               # (S1) empty dir stub (in .paths; ensure_binary.sh/download.sh land in P2.M3)
├── licenses/              # (S1) dir stub (in .paths; TERM2HTML.txt + GHOSTTY-VT.txt land in P1.M1.T2.S1)
├── testdata/              # (S1) empty dir stub (in .paths; golden *.ansi/*.html pairs land in P1.M4.T2.S1)
├── tmux-2html.tmux        # (S1) empty FILE stub (in .paths; TPM entrypoint lands in P2.M2.T1.S1)
└── LICENSE                # (S1) empty FILE stub (in .paths; MIT text added per PRD §13 in a later task)
# These are SCAFFOLDING so the manifest's .paths validates. Real contents come later.
```

### Known Gotchas of our codebase & Library Quirks

```zig
// GOTCHA 1 — .fingerprint is REQUIRED in Zig 0.15.2, NOT auto-regenerated.
//   The item contract says "delete .fingerprint so zig build regenerates it".
//   That is IMPRECISE. Verified behavior (zig 0.15.2):
//     - omitting .fingerprint -> hard ERROR, exit != 0:
//         "error: missing top-level 'fingerprint' field; suggested value: 0x...."
//     - zig does NOT write the field back; the suggested value is RANDOM each run
//       (observed 3 different values in 3 runs). It is not content-derived.
//   CORRECT: hardcode ANY u64 (e.g. 0x95375ce2c9bf5b21 below — verified to build),
//            OR omit it, run `zig build`, copy the random suggestion from the error,
//            and paste it in. Either works; the value is arbitrary for greenfield.

// GOTCHA 2 — .name uses a Zig identifier, NOT a string. Hyphens are illegal in
//   identifiers, so use an underscore: `.name = .tmux_2html`. The hyphenated
//   executable name "tmux-2html" is set SEPARATELY in build.zig via
//   addExecutable(.{ .name = "tmux-2html" }) — that's task S2, not here.

// GOTCHA 3 — parg URL username is `judofhr` (with an 'h'). Some architecture docs
//   typo it `judofr`. The zon block below and the live fetch both confirm `judofhr`.
//   .url = "git+https://github.com/judofhr/parg.git#b9ce29e3dcbf9845dac8ee4b33a31bb1bff29f80"

// GOTCHA 4 — every entry in .paths MUST physically exist on disk before
//   `zig build --fetch` will run. Create the stub dirs/files FIRST (Task 1).

// GOTCHA 5 — `zig build --fetch` requires a parseable build.zig to exist (it is
//   in .paths and the build runner evaluates it). A minimal empty-fn stub is
//   sufficient for S1; fetch does not require the deps to be WIRED in build.zig,
//   only DECLARED in build.zig.zon. Verified: empty build fn → fetch exit 0.

// GOTCHA 6 — Do NOT run `zig fetch --save <url>` to "fill in" the hashes. The
//   hashes below are already the verified content hashes; regenerating is a
//   no-op that risks introducing a typo. Use them verbatim.
```

## Implementation Blueprint

### Data models and structure

Not applicable — this task produces a declarative Zig Object Notation (`.zon`)
manifest, no data models.

### The exact deliverable: `build.zig.zon`

Create this file verbatim at the repo root. (See Gotchas above for the
fingerprint and name rationale; both values verified against zig 0.15.2.)

```zig
.{
    .name = .tmux_2html,
    .version = "0.1.0",
    .minimum_zig_version = "0.15.2",
    .fingerprint = 0x95375ce2c9bf5b21,
    .dependencies = .{
        .ghostty = .{
            .url = "https://github.com/ghostty-org/ghostty/archive/refs/tags/v1.3.1.tar.gz",
            .hash = "ghostty-1.3.1-5UdBCwYm-gQeBa4bu1-sMooCQS4KVriv5wWSIJ_sI-Cb",
        },
        .parg = .{
            .url = "git+https://github.com/judofhr/parg.git#b9ce29e3dcbf9845dac8ee4b33a31bb1bff29f80",
            .hash = "parg-0.0.0-dOPWZNhYAABEHE6EGXmwIucnu9vj-emodT9vmHeYynAP",
        },
    },
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
        "scripts",
        "tmux-2html.tmux",
        "LICENSE",
        "licenses",
        "testdata",
    },
}
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: CREATE the .paths scaffolding (so the manifest validates at fetch time)
  - CREATE dirs:  src/  scripts/  licenses/  testdata/   (empty; add .gitkeep if git rejects empty dirs)
  - CREATE empty files:  tmux-2html.tmux   LICENSE        (in .paths; real content lands in later tasks)
  - WHY FIRST: `zig build --fetch` verifies every .paths entry exists; missing entries hard-error.

Task 2: CREATE build.zig (MINIMAL STUB — full wiring is sibling task S2)
  - FILE: build.zig
  - CONTENT (verbatim):
        const std = @import("std");
        pub fn build(b: *std.Build) void {
            _ = b;
        }
  - WHY: the build runner needs a parseable build.zig to evaluate the manifest for --fetch.
         Fetch resolves DECLARED deps without requiring them WIRED in build.zig (verified exit 0).
  - SCOPE NOTE: Do NOT add addExecutable / ghostty-vt import / -Dsimd / version / test step here.
         That is P1.M1.T1.S2. S1 ships the stub only.

Task 3: CREATE build.zig.zon  (THE DELIVERABLE)
  - FILE: build.zig.zon  (use the exact content in the Blueprint above, verbatim)
  - NAMING: .name = .tmux_2html  (underscore; see Gotcha 2)
  - HASHES: copy ghostty + parg hash/url strings EXACTLY — do not regenerate (Gotcha 6)
  - FINGERPRINT: keep the hardcoded 0x95375ce2c9bf5b21, OR delete the line and let `zig build`
                 print a random suggestion to paste back (Gotcha 1). Hardcoding is simpler.

Task 4: VALIDATE  (see Validation Loop)
  - RUN: zig version   → expect "0.15.2"
  - RUN: zig build --fetch   → expect exit 0
  - CHECK: both dep hashes present in ~/.cache/zig/p/ (or %LOCALAPPDATA% on Windows)
```

### Implementation Patterns & Key Details

```zig
// Minimal build.zig stub for S1 (full wiring deferred to S2).
// This is intentionally near-empty: S1's job is the MANIFEST, not the build graph.
const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b;
}
```

### Integration Points

```yaml
BUILD GRAPH:
  - this task:    build.zig.zon + minimal build.zig stub + .paths scaffolding
  - next (S2):    replace build.zig stub with full wiring that consumes these deps:
                    * b.dependency("parg", .{}).module("parg")
                    * b.lazyDependency("ghostty", .{...}).module("ghostty-vt")
                    * addExecutable(.{ .name = "tmux-2html", ... })   # hyphen OK here, NOT in .name
                    * b.addOptions() to bake version; -Dsimd option; test step
  - S2 will NOT touch build.zig.zon again (manifest is complete after S1).

CONFIG:
  - none (build manifest only; no env vars, no settings files).

DATABASE / ROUTES:
  - none.
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Zig has no separate linter/formatter step for .zon; the build runner is the checker.
# Confirm the pinned toolchain is present:
zig version          # MUST print: 0.15.2

# If you omitted .fingerprint, this surfaces the required value:
zig build --fetch 2>&1 | grep fingerprint   # shows: error: missing top-level 'fingerprint' field; suggested value: 0x....

# Expected: zig version == 0.15.2. If a different version, the toolchain is wrong for this task.
```

### Level 2: Manifest Validation (Component Validation)

```bash
# Resolve & fetch dependencies. This is the PRIMARY validation gate for S1.
zig build --fetch
# Expected: exit code 0, no errors. Downloads ghostty (large, ~hundreds of MB on first run)
# and parg on first run; subsequent runs are instant (global cache hit).

# Edge-case check: confirm the manifest rejects a deliberately-wrong hash (sanity that the
# gate actually validates). NOT required for success — only run if you suspect a hash typo:
#   (temporarily corrupt a hash → zig build --fetch should error with "hash mismatch")
```

### Level 3: Dependency Resolution (System Validation)

```bash
# Confirm BOTH dependencies landed in the global Zig cache under their declared hashes.
ls ~/.cache/zig/p/ 2>/dev/null \
  | grep -E 'ghostty-1\.3\.1-5UdBCwYm-gQeBa4bu1-sMooCQS4KVriv5wWSIJ_sI-Cb' \
  | grep -E 'parg-0\.0\.0-dOPWZNhYAABEHE6EGXmwIucnu9vj-emodT9vmHeYynAP'
# Expected: BOTH lines print. If either is missing, the corresponding dep failed to resolve.

# (On Windows the cache lives under %LOCALAPPDATA%\zig\p\. On macOS/Linux it is ~/.cache/zig/p/.)

# Optional: full `zig build` should also exit 0 with the stub build.zig (compiles nothing
# meaningful yet — S2 adds the real target). This is a smoke test, not the gate:
zig build 2>&1 | tail -5   # expect: exit 0, no output (stub build fn builds nothing)
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Domain-specific: confirm a corrupted hash is REJECTED (proves the gate is real, not a no-op).
# OPTIONAL — skip unless verifying robustness:
cp build.zig.zon /tmp/build.zig.zon.bak
sed -i 's/ghostty-1.3.1-5UdBCwYm/ghostty-1.3.1-ZZZZZZZ/' build.zig.zon
zig build --fetch; echo "expect NON-zero: $?"    # should error: hash mismatch
cp /tmp/build.zig.zon.bak build.zig.zon         # restore
zig build --fetch; echo "restored, expect 0: $?"
# Expected: corrupted hash → failure; restored → exit 0.
```

## Final Validation Checklist

### Technical Validation

- [ ] `zig version` prints `0.15.2`.
- [ ] `zig build --fetch` exits 0 (Level 2 gate — the primary success signal).
- [ ] Both dep hashes present in `~/.cache/zig/p/` (Level 3).
- [ ] Full `zig build` exits 0 with the stub `build.zig` (smoke test).

### Feature Validation

- [ ] `build.zig.zon` exists at repo root with the exact Blueprint content.
- [ ] `.name = .tmux_2html` (underscore), `version = "0.1.0"`,
      `minimum_zig_version = "0.15.2"`.
- [ ] ghostty + parg declared with the verified URLs/hashes (verbatim).
- [ ] `.paths` lists all 8 entries and each exists on disk.
- [ ] `.fingerprint` present (hardcoded) — no "missing fingerprint" error.
- [ ] Success criteria from "What" section all met.

### Code Quality Validation

- [ ] `build.zig` stub is minimal and clearly marked as a placeholder for S2.
- [ ] No out-of-scope work (no executable wiring, no module imports, no test step).
- [ ] Stub dirs use `.gitkeep` (or equivalent) if the repo must commit empty dirs.

### Documentation & Deployment

- [ ] No new env vars or config (manifest-only task).
- [ ] The manifest is self-documenting (standard Zig `.zon` fields).

---

## Anti-Patterns to Avoid

- ❌ Don't run `zig fetch --save` to "regenerate" the hashes — they are already
  verified; regenerating risks a typo and is a no-op. Copy them verbatim.
- ❌ Don't omit `.fingerprint` expecting `zig build` to silently fix it — it
  hard-errors in 0.15.2 (the contract wording is imprecise; see Gotcha 1).
  Hardcode a value, or paste the random suggestion it prints.
- ❌ Don't use `.name = .@"tmux-2html"` or `.name = "tmux-2html"` — use the
  underscore form `.tmux_2html`. The hyphenated binary name is a `build.zig`
  concern (task S2).
- ❌ Don't typo the parg username as `judofr` — it is `judofhr`.
- ❌ Don't implement the full `build.zig` wiring here (executable, ghostty-vt
  import, `-Dsimd`, version bake, test step) — that is sibling task S2. S1 ships
  a minimal stub only.
- ❌ Don't skip creating the `.paths` scaffolding — `zig build --fetch` validates
  that every path exists and hard-errors on a missing entry.

---

**Confidence Score: 10/10** for one-pass implementation success.

Every value in this PRP — the `.name` form, the `.fingerprint` requirement, both
dependency URLs, both content hashes, the parg username spelling, and the exact
`zig build --fetch` exit-0 behavior — was verified empirically against the real
Zig 0.15.2 toolchain (`/home/dustin/.local/bin/zig`) by building a faithful
throwaway repo and running the validation commands. The manifest content is
specified verbatim, so the implementer is copying verified values, not guessing.
