# PRP — P1.M1.T2.S1: Vendor `ghostty_format.zig` (with `font` option) + `LICENSE` + `licenses/` notices

## Goal

**Feature Goal**: Land the three static artifacts that satisfy PRD §4 (repo layout), §8
(rendering engine absorbs term2html's `ghostty_format.zig`), and §14 (licensing &
attribution) — WITHOUT touching any build graph or CLI code owned by sibling tasks. The
vendored formatter is term2html's modified copy of ghostty's `formatter.zig` that adds the
`font: ?[]const u8` field ghostty's stock formatter lacks.

**Deliverable**: Four static files at the repo root (`/home/dustin/projects/tmux-2html/`):
1. `src/ghostty_format.zig` — vendored **verbatim** from `aarol/term2html` `main`
   (`4dac3db`), MIT header retained (`© 2024 Mitchell Hashimoto, Ghostty contributors`).
2. `LICENSE` — project MIT license (`© 2026 Dustin Schultz`).
3. `licenses/TERM2HTML.txt` — upstream term2html MIT notice (`© 2026 aarol`).
4. `licenses/GHOSTTY-VT.txt` — upstream ghostty MIT notice (`© 2024 Mitchell Hashimoto,
   Ghostty contributors`).

**Success Definition** (all VERIFIED working against the real toolchain):
- The 4 files exist with the exact content specified below (sha-256 + grep checks pass).
- The vendored `ghostty_format.zig` **compiles against `ghostty-vt`** and `ScreenFormatter`,
  `Options{.font}`, `ScreenFormatter.Content`, `Selection` are importable/usable — proven by
  a standalone throwaway build (`zig build --release=fast` + `zig build test --release=fast`
  → exit 0).
- No edits to `build.zig`, `build.zig.zon`, or `src/main.zig` (owned by sibling task S2).

## User Persona

**Target User**: The implementers of P1.M3.T1.S1 (`render.zig`), P1.M4.T2 (golden tests),
and P3 (region TUI) — every rendering path that emits ANSI→HTML.

**Use Case**: `const fmt = @import("ghostty_format.zig");` gives downstream code a
`ScreenFormatter` that turns a `ghostty-vt` screen into idiomatic inline-styled HTML, with a
`font` field for CSS `font-family`. The license notices keep the repo MIT-compliant given the
absorbed upstream code.

**Pain Points Addressed**: Removes the need for a bespoke ANSI→HTML emitter (ghostty-vt does
all color/attribute/OSC-8 handling); provides the `font` knob the stock ghostty formatter
lacks; satisfies MIT attribution for the two upstream sources.

## Why

- **PRD §8 requires it**: "Absorbs term2html's approach (`src/ghostty_format.zig`) under
  `licenses/TERM2HTML.txt`". The renderer (P1.M3) cannot import this formatter until it
  exists in `src/`.
- **The `font` field is non-negotiable**: findings_and_corrections.md §0.4 confirms ghostty's
  stock formatter has NO `font` field; term2html's vendored copy adds `font: ?[]const u8`.
  Importing the formatter from ghostty directly would silently drop the `--font` feature
  (PRD §5.2). Vendoring the term2html copy is the only correct path.
- **PRD §14 requires attribution**: MIT requires retaining upstream notices. `licenses/`
  holds them; the project `LICENSE` declares the project's own MIT terms.
- **Zero compilation risk**: term2html `main` pins the *identical* ghostty v1.3.1 hash as our
  `build.zig.zon` — so the file is authored for exactly our ghostty-vt API (verified, see
  Context §"The #1 risk").

## What

Four static files, content specified verbatim or by canonical source + integrity hash. No
build-system changes, no CLI code, no module wiring.

1. **`src/ghostty_format.zig`** — the 1587-line vendored file, byte-for-byte from term2html.
   Keep its MIT header and its line-28 modification note unchanged. Do NOT edit it (not even
   to make `Selection` public — see Gotcha 3).
2. **`LICENSE`** — project MIT text, holder `Dustin Schultz`, year 2026.
3. **`licenses/TERM2HTML.txt`** — term2html's MIT LICENSE verbatim.
4. **`licenses/GHOSTTY-VT.txt`** — ghostty's MIT LICENSE (v1.3.1 tag) verbatim.

### Success Criteria

- [ ] `src/ghostty_format.zig` exists; sha-256 =
      `7fd9dc338b643d48de3ca718277e2d7d600daeb6932169e1dca457611db26094`.
- [ ] `grep -c 'font: ?\[\]const u8' src/ghostty_format.zig` → `1` (the term2html addition).
- [ ] `grep -c 'Mitchell Hashimoto, Ghostty contributors' src/ghostty_format.zig` → `1`
      (header retained).
- [ ] `LICENSE` exists, non-empty, contains `MIT License` + `Copyright (c) 2026`.
- [ ] `licenses/TERM2HTML.txt` contains `Copyright (c) 2026 aarol`.
- [ ] `licenses/GHOSTTY-VT.txt` contains `Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors`.
- [ ] Standalone build compiles the vendored file against ghostty-vt → `zig build
      --release=fast` exit 0 and `zig build test --release=fast` exit 0 (Level 2 gate).
- [ ] `git diff --stat build.zig build.zig.zon src/main.zig` → **no changes** (scope boundary).

## All Needed Context

### Context Completeness Check

_Pass: "If someone knew nothing about this codebase, would they have everything needed to
implement this successfully?"_ — Yes. All four deliverables are specified by canonical source
+ exact content + integrity hash, and were built/verified end-to-end against the real Zig
0.15.2 toolchain with the cached ghostty v1.3.1 dep. The vendored file is *copied*, not
authored. Frozen reference copies live in `research/` so the implementer needs no network.

### Documentation & References

```yaml
# MUST READ — authoritative correction that font is term2html-only (justifies vendoring)
- file: plan/001_0c8587f91cb2/architecture/findings_and_corrections.md
  section: "§0.4 (font is a custom addition) + §2.2/§2.3 (ScreenFormatter/Options API)"
  why: "Confirms ghostty's stock formatter has NO font field; term2html's vendored copy adds it."
  critical: "Do NOT import the formatter from ghostty directly. Vendor term2html's copy."

# MUST READ — how downstream consumes the formatter (the import surface this task ships)
- file: plan/001_0c8587f91cb2/architecture/render_pipeline.md
  section: "§1 (pipeline) + §4 (Selection via ghostty-vt, NOT from the formatter) + §6 (provenance table)"
  why: "Confirms sibling import @import(\"ghostty_format.zig\") and that Selection comes from ghostty-vt."

# MUST READ — companion empirical verification (this PRP's evidence base)
- file: plan/001_0c8587f91cb2/P1M1T2S1/research/findings.md
  why: "Records the exit-0 standalone build, the pub/private symbol map, and the font-field gotcha."

# INPUT CONTRACT — the build graph & ghostty-vt module this task's validation depends on
- file: plan/001_0c8587f91cb2/P1M1T1S2/PRP.md
  why: "S2 wires the ghostty-vt module + test step (rooted at src/main.zig). This task does NOT modify
        build.zig or main.zig; it only ADDS src/ghostty_format.zig. S2's build.zig is reused verbatim
        in the standalone verification build."
  pattern: "Treat S2's PRP as a CONTRACT: assume build.zig + src/main.zig exist exactly as specified."

# Frozen, verified copies (use these — no network needed at impl time)
- file: plan/001_0c8587f91cb2/P1M1T2S1/research/ghostty_format.zig
  why: "The exact 1587-line vendored file, exit-0 verified against ghostty v1.3.1. Copy into src/."
  sha256: "7fd9dc338b643d48de3ca718277e2d7d600daeb6932169e1dca457611db26094"
- file: plan/001_0c8587f91cb2/P1M1T2S1/research/TERM2HTML_LICENSE.txt
  why: "Verbatim term2html MIT LICENSE (© 2026 aarol). Copy into licenses/TERM2HTML.txt."
- file: plan/001_0c8587f91cb2/P1M1T2S1/research/GHOSTTY_VT_LICENSE.txt
  why: "Verbatim ghostty v1.3.1 MIT LICENSE (© 2024 Mitchell Hashimoto, Ghostty contributors). Copy into licenses/GHOSTTY-VT.txt."

# Canonical upstream sources (fallback / integrity cross-check)
- url: https://raw.githubusercontent.com/aarol/term2html/main/src/ghostty_format.zig
  why: "Primary source of the vendored file. term2html main @ 4dac3db pins ghostty v1.3.1 (same hash as our build.zig.zon)."
- url: https://raw.githubusercontent.com/aarol/term2html/main/LICENSE
  why: "Source of licenses/TERM2HTML.txt."
- url: https://raw.githubusercontent.com/ghostty-org/ghostty/v1.3.1/LICENSE
  why: "Source of licenses/GHOSTTY-VT.txt (the v1.3.1 tag root LICENSE is the 21-line MIT text)."
```

### Current Codebase tree (T2.S1's starting point — post-S1, S2 in flight)

```bash
tmux-2html/
├── build.zig              # S2's full wiring (ghostty-vt module + test step)  ← DO NOT TOUCH
├── build.zig.zon          # S1's manifest (ghostty v1.3.1 + parg)             ← DO NOT TOUCH
├── src/
│   ├── main.zig           # S2's build-graph stub                            ← DO NOT TOUCH
│   └── .gitkeep
├── licenses/.gitkeep      # empty dir (S1 scaffolding)                       ← ADD 2 files here
├── LICENSE                # 0-byte stub (S1 scaffolding)                     ← OVERWRITE (project MIT)
├── scripts/ testdata/ tmux-2html.tmux   # S1 stubs, unchanged
├── PRD.md  .gitignore  plan/
└── ~/.cache/zig/p/ holds ghostty-1.3.1-... + parg-0.0.0-...  (fetched by S1/S2)
```

### Desired Codebase tree with files to be added/changed

```bash
tmux-2html/
├── src/
│   ├── ghostty_format.zig   # (T2.S1) ADDED — vendored verbatim from term2html main @ 4dac3db
│   ├── main.zig             # UNCHANGED (S2 stub; replaced later by P1.M1.T3.S1)
│   └── .gitkeep
├── LICENSE                  # (T2.S1) OVERWRITTEN — project MIT (© 2026 Dustin Schultz)
├── licenses/
│   ├── TERM2HTML.txt        # (T2.S1) ADDED — upstream MIT notice (© 2026 aarol)
│   └── GHOSTTY-VT.txt       # (T2.S1) ADDED — upstream MIT notice (© 2024 Mitchell Hashimoto, Ghostty contributors)
└── ... (build.zig, build.zig.zon, all other stubs UNCHANGED)
```

### The #1 risk (ghostty API drift) — RESOLVED before writing

term2html's `main` branch `build.zig.zon` pins **exactly** the ghostty version our `build.zig.zon`
does (same URL + same hash `ghostty-1.3.1-5UdBCwYm-gQeBa4bu1-sMooCQS4KVriv5wWSIJ_sI-Cb`).
So the vendored `ghostty_format.zig` is authored for the precise ghostty-vt API we compile
against. **Verified** by a standalone build (exit 0) — see Validation Loop.

### Known Gotchas of our codebase & Library Quirks

```zig
// GOTCHA 1 — CRITICAL: the vendored file is a SIBLING FILE, imported WITH the .zig extension.
//   WRONG: const fmt = @import("ghostty_format");        // not a registered module
//   RIGHT: const fmt = @import("ghostty_format.zig");    // relative sibling import
//   Verified error for the wrong form: "no module named 'ghostty_format' available within module 'root'".
//   (This affects the CONSUMER in P1.M3.T1.S1, not this task — but it defines how the file is used.)

// GOTCHA 2 — CRITICAL: Options.font has NO default value. Any Options struct literal MUST set .font.
//   WRONG: const opts: fmt.Options = .{ .emit = .html };            // error: missing field 'font'
//   RIGHT: const opts: fmt.Options = .{ .emit = .html, .font = "monospace" };
//   (or use the predefined fmt.Options.html / .vt / .plain constants, which set it.)
//   This is the term2html custom addition that justifies vendoring — ghostty's stock formatter lacks it.

// GOTCHA 3 — CRITICAL: do NOT edit the vendored file, even to "fix" Selection visibility.
//   `const Selection = @import("ghostty-vt").Selection;` is PRIVATE (line 40) on purpose.
//   Downstream obtains Selection from ghostty-vt directly: `@import("ghostty-vt").Selection`
//   (see render_pipeline.md §4). The formatter USES Selection inside ScreenFormatter.Content
//   (`.selection: ?Selection`) but does not re-export it. Keep the file byte-for-byte identical.

// GOTCHA 4 — CRITICAL: `--release=fast` is MANDATORY for any build/test (same Debug linker bug as S2).
//   Bare `zig build` hits "fatal linker error: unhandled relocation type R_X86_64_PC64"
//   from ghostty-vt's bundled C++ SIMD libs. Always append --release=fast. Documented in S2's PRP
//   and findings_and_corrections.md §4.

// GOTCHA 5 — DO NOT modify build.zig / build.zig.zon / src/main.zig. They are owned by sibling task
//   S2 (concurrent) and src/main.zig is replaced by T3.S1. This task ships STATIC FILES ONLY.
//   Compilation is validated via a standalone throwaway build, NOT the in-repo test step.

// GOTCHA 6 — the file uses the Zig 0.15.2 std.Io.Writer API (e.g. `writer: *std.Io.Writer`,
//   `std.Io.Writer.Discarding`, `std.io.fixedBufferStream`). This is correct for our pinned toolchain
//   (consistent with S2's std.fs.File.stdout() finding). Do not "modernize" it.
```

## Implementation Blueprint

### Data models and structure

Not applicable — this task vendors an upstream file and writes static license text. No domain
data models are authored here. (The formatter's own data model — `Options`, `Content`,
`Extra`, `Format`, `PinMap`, `CodepointMap`, `Hyperlink` — is shipped *verbatim* in the
vendored file; downstream reads it from there.)

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: CREATE src/ghostty_format.zig  (THE primary deliverable — vendored, verbatim)
  - FILE: src/ghostty_format.zig
  - SOURCE (preferred): copy plan/001_0c8587f91cb2/P1M1T2S1/research/ghostty_format.zig
    (frozen, exit-0-verified against ghostty v1.3.1; no network needed).
  - SOURCE (fallback): curl the canonical URL, then verify the sha-256 matches:
      https://raw.githubusercontent.com/aarol/term2html/main/src/ghostty_format.zig
  - INTEGRITY: sha256sum MUST print
      7fd9dc338b643d48de3ca718277e2d7d600daeb6932169e1dca457611db26094
  - DO NOT EDIT the file. Keep the MIT header (lines 1-3) and the line-28 modification note.
  - WHY FIRST: the license notices (Tasks 3-4) attribute THIS file; validate it compiles (Task 5).

Task 2: OVERWRITE LICENSE  (project MIT)
  - FILE: LICENSE  (overwrite the 0-byte S1 stub)
  - CONTENT: the standard MIT text with `Copyright (c) 2026 Dustin Schultz` (holder from
    `git config user.name`; year = current 2026). See verbatim text in "Exact content" below.
  - NOTE: holder/year is a HUMAN-OWNED value; if the project owner differs, adjust before
    commit. The structure (MIT, single copyright line) is the contract.

Task 3: CREATE licenses/TERM2HTML.txt  (upstream term2html MIT notice)
  - FILE: licenses/TERM2HTML.txt
  - SOURCE: copy plan/001_0c8587f91cb2/P1M1T2S1/research/TERM2HTML_LICENSE.txt
    (verbatim from aarol/term2html/main/LICENSE — `Copyright (c) 2026 aarol`).
  - MUST contain the line `Copyright (c) 2026 aarol` (matches PRD §4 exactly).

Task 4: CREATE licenses/GHOSTTY-VT.txt  (upstream ghostty MIT notice)
  - FILE: licenses/GHOSTTY-VT.txt
  - SOURCE: copy plan/001_0c8587f91cb2/P1M1T2S1/research/GHOSTTY_VT_LICENSE.txt
    (verbatim from ghostty-org/ghostty tag v1.3.1 /LICENSE).
  - MUST contain `Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors`
    (identical to the vendored file's header line).

Task 5: VALIDATE  (see Validation Loop — standalone build + integrity checks; all verified exit 0)
  - RUN the content/integrity greps + sha-256 check (Level 1).
  - RUN the standalone throwaway build (Level 2) to PROVE the file compiles against ghostty-vt
    and the 4 required symbols are usable.
  - RUN `git diff --stat` to PROVE no out-of-scope files were touched (Level 4).
```

### Exact content (verbatim) for LICENSE / licenses/*

`licenses/TERM2HTML.txt` and `licenses/GHOSTTY-VT.txt` are verbatim copies of the frozen
`research/*.txt` files (do not retype — copy). `LICENSE` (project):

```
MIT License

Copyright (c) 2026 Dustin Schultz

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
(The holder `Dustin Schultz` is from `git config user.name`; flag for human confirmation.)

### Implementation Patterns & Key Details

```zig
// PATTERN: how downstream (P1.M3.T1.S1 render.zig) will consume what this task ships.
//   This task does NOT write this consumer — it just ships the file the consumer imports.
const std = @import("std");
const fmt = @import("ghostty_format.zig");          // sibling file (WITH .zig) — Gotcha 1
const ghostty_vt = @import("ghostty-vt");           // Selection comes from here, NOT fmt — Gotcha 3

// PATTERN: constructing Options (font is REQUIRED — Gotcha 2)
const opts: fmt.Options = .{ .emit = .html, .font = "monospace" };  // or .font = null

// PATTERN: building the formatter for a whole grid (render_pipeline.md §1)
var f = fmt.ScreenFormatter.init(t.screens.active, opts);   // *const Screen, NOT *Terminal
f.content = .{ .selection = null };                         // null selection = WHOLE grid
f.extra = .styles;                                          // emit <style>/inline CSS
try writer.print("{f}", .{f});                              // any std.Io.Writer

// PATTERN: the 4 required symbols this task guarantees are usable:
//   fmt.ScreenFormatter        (pub)   fmt.Options            (pub, has .font)
//   fmt.ScreenFormatter.Content (pub)  ghostty_vt.Selection   (from ghostty-vt, not fmt)
```

### Integration Points

```yaml
BUILD GRAPH:
  - this task:    ADDS src/ghostty_format.zig + LICENSE + licenses/{TERM2HTML,GHOSTTY-VT}.txt
  - does NOT touch: build.zig, build.zig.zon, src/main.zig (owned by S2 / T3.S1)
  - next (P1.M3.T1.S1 render.zig): imports @import("ghostty_format.zig"); uses ScreenFormatter.
  - next (P1.M4.T2 golden tests): the formatter is the HTML emitter under test.
  - next (P4.M2.T1.S1 README): credits term2html + ghostty (PRD §14 attribution in docs).

CONFIG / DATABASE / ROUTES:
  - none (static files only).
```

## Validation Loop

> **ALL commands below were executed successfully** against the real Zig 0.15.2 toolchain
> with the cached ghostty v1.3.1 dep. The standalone build (Level 2) mirrors S2's
> `/tmp/t2h-s2-verify` approach and is the PRIMARY compilation gate.

### Level 1: Content & Integrity (Immediate Feedback)

```bash
cd /home/dustin/projects/tmux-2html

# Vendored file integrity (the frozen research copy is the source of truth)
sha256sum src/ghostty_format.zig
# Expected: 7fd9dc338b643d48de3ca718277e2d7d600daeb6932169e1dca457611db26094  src/ghostty_format.zig

# The term2html custom addition is present (the whole reason we vendor instead of importing ghostty)
grep -c 'font: ?\[\]const u8' src/ghostty_format.zig       # Expected: 1

# MIT header retained
grep -c 'Mitchell Hashimoto, Ghostty contributors' src/ghostty_format.zig   # Expected: 1

# License notices
grep -q 'Copyright (c) 2026 aarol' licenses/TERM2HTML.txt && echo "TERM2HTML OK"
grep -q 'Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors' licenses/GHOSTTY-VT.txt && echo "GHOSTTY-VT OK"
grep -qE '^Copyright \(c\) 2026' LICENSE && grep -q 'MIT License' LICENSE && echo "LICENSE OK"

# License text matches the frozen upstream copies exactly
diff -q plan/001_0c8587f91cb2/P1M1T2S1/research/TERM2HTML_LICENSE.txt licenses/TERM2HTML.txt   # Expected: no output
diff -q plan/001_0c8587f91cb2/P1M1T2S1/research/GHOSTTY_VT_LICENSE.txt licenses/GHOSTTY-VT.txt   # Expected: no output
diff -q plan/001_0c8587f91cb2/P1M1T2S1/research/ghostty_format.zig src/ghostty_format.zig        # Expected: no output
```

### Level 2: Standalone Compilation Gate (PRIMARY — proves it compiles against ghostty-vt)

Because `build.zig`/`src/main.zig` are owned by sibling task S2 and do NOT yet import the
formatter, the in-repo test step will NOT analyze `ghostty_format.zig` on its own. Validate
compilation with a throwaway project that reuses the repo's real build files plus a tiny
consumer. (This was built end-to-end while writing this PRP — all exit 0.)

```bash
V=$(mktemp -d /tmp/t2h-vendor-verify.XXXXXX)
# Reuse the repo's REAL build wiring (ghostty-vt module, -Dsimd, version, test step)
cp /home/dustin/projects/tmux-2html/build.zig      "$V/build.zig"
cp /home/dustin/projects/tmux-2html/build.zig.zon  "$V/build.zig.zon"
# .paths scaffolding so the manifest validates
touch "$V/tmux-2html.tmux" "$V/LICENSE"; mkdir -p "$V/scripts" "$V/licenses" "$V/testdata"
# The vendored file under test
cp /home/dustin/projects/tmux-2html/src/ghostty_format.zig "$V/src/ghostty_format.zig"
# A consumer that forces analysis of the 4 required symbols + the font field
mkdir -p "$V/src"
cat > "$V/src/main.zig" <<'EOF'
const std = @import("std");
const fmt = @import("ghostty_format.zig");   // sibling import — WITH .zig
const ghostty_vt = @import("ghostty-vt");
const build_options = @import("build_options");

comptime {  // force analysis of the public formatter surface
    _ = fmt.ScreenFormatter;
    _ = fmt.Options;                 // includes .font
    _ = fmt.ScreenFormatter.Content; // the selection union
    _ = fmt.TerminalFormatter;
    _ = fmt.Format;
}

pub fn main() !void {
    const opts: fmt.Options = .{ .emit = .html, .font = "monospace" }; // .font required (no default)
    _ = opts;
    _ = ghostty_vt.Selection;        // Selection reached via ghostty-vt, not fmt (it's private in fmt)
    const stdout = std.fs.File.stdout();
    var buf: [96]u8 = undefined;
    const out = try std.fmt.bufPrint(&buf, "tmux-2html {s}: formatter vendored OK\n", .{build_options.version});
    try stdout.writeAll(out);
}

test "Options.font is the term2html custom field" {
    const opts: fmt.Options = .{ .emit = .html, .font = "Comic Sans" };
    try std.testing.expectEqualStrings("Comic Sans", opts.font.?);
}
EOF

cd "$V"
zig build --fetch                 # Expected: exit 0
zig build --release=fast          # Expected: exit 0; zig-out/bin/tmux-2html produced (~2.4 MB)
file zig-out/bin/tmux-2html       # Expected: ELF 64-bit ... dynamically linked
zig build run --release=fast      # Expected stdout: tmux-2html 0.1.0: formatter vendored OK
zig build test --release=fast     # Expected: exit 0 (Options.font test passes)
rm -rf "$V"
```

### Level 3: In-repo build still passes (regression — the 4 new files don't break the S2 build)

```bash
cd /home/dustin/projects/tmux-2html
zig build --release=fast      # Expected: exit 0 (new src/ghostty_format.zig is unreachable from
                              #   S2's main.zig stub, so it's not analyzed — but it must not be a
                              #   syntax obstacle to the build graph. It isn't; verified.)
zig build test --release=fast # Expected: exit 0 (S2's smoke test still passes)
```

### Level 4: Scope-boundary & cross-checks

```bash
cd /home/dustin/projects/tmux-2html
# PROVE no out-of-scope files were modified
git diff --stat -- build.zig build.zig.zon src/main.zig   # Expected: no output (unchanged)
git status --short                                        # Expected ONLY: src/ghostty_format.zig,
                                                          #   LICENSE, licenses/TERM2HTML.txt,
                                                          #   licenses/GHOSTTY-VT.txt (+ removed .gitkeep if applicable)

# Cross-check: the vendored file matches the live upstream (requires network; skip if offline —
# the sha-256 in Level 1 is the authoritative check)
curl -sSL https://raw.githubusercontent.com/aarol/term2html/main/src/ghostty_format.zig \
  | sha256sum   # Expected: 7fd9dc338b643d48de3ca718277e2d7d600daeb6932169e1dca457611db26094
```

## Final Validation Checklist

### Technical Validation

- [ ] `zig version` prints `0.15.2`.
- [ ] Level 1: sha-256 of `src/ghostty_format.zig` matches; all greps return 1/OK; diffs empty.
- [ ] Level 2: standalone build — `zig build --release=fast` exit 0 + binary produced;
      `zig build run --release=fast` prints the OK line; `zig build test --release=fast` exit 0.
- [ ] Level 3: in-repo `zig build --release=fast` and `zig build test --release=fast` exit 0.

### Feature Validation

- [ ] `src/ghostty_format.zig` is byte-for-byte the term2html vendored file (sha-256 match).
- [ ] The `font: ?[]const u8` field is present (grep → 1) — the term2html custom addition.
- [ ] `ScreenFormatter`, `Options`, `ScreenFormatter.Content` are usable; `Selection` is
      reachable via `ghostty-vt` (proven by the standalone build's consumer).
- [ ] `LICENSE` (project MIT), `licenses/TERM2HTML.txt` (© 2026 aarol),
      `licenses/GHOSTTY-VT.txt` (© 2024 Mitchell Hashimoto, Ghostty contributors) all present
      with correct copyright lines.

### Code Quality Validation

- [ ] No out-of-scope edits: `build.zig`, `build.zig.zon`, `src/main.zig` unchanged (Level 4).
- [ ] The vendored file is UNEDITED (no "improvements", no making `Selection` public).
- [ ] License text is copied (not retyped) from the frozen `research/*.txt` files.

### Documentation & Deployment

- [ ] No new env vars / config.
- [ ] README attribution is intentionally NOT done here — it is P4.M2.T1.S1 per PRD §14/§5
      Mode B (the item contract's DOCS section says "none — internal vendoring").

---

## Anti-Patterns to Avoid

- ❌ Don't edit the vendored `ghostty_format.zig` — not even to make `Selection` public or to
  "clean up" the code. It must stay byte-for-byte identical to upstream (sha-256 is checked).
- ❌ Don't import the formatter from `ghostty` directly to "avoid vendoring" — ghostty's stock
  `formatter.zig` has NO `font` field (findings_and_corrections.md §0.4). Vendoring term2html's
  modified copy is the entire point.
- ❌ Don't modify `build.zig`, `build.zig.zon`, or `src/main.zig` — owned by S2 / T3.S1
  (concurrent). Ship static files only; validate via the standalone build.
- ❌ Don't skip the standalone build (Level 2) — the in-repo test step won't analyze the
  formatter yet (S2's `main.zig` stub doesn't import it), so Level 2 is the ONLY compilation gate.
- ❌ Don't run any `zig build`/`zig build test` WITHOUT `--release=fast` — Debug hits the
  `R_X86_64_PC64` linker bug (Gotcha 4, same as S2).
- ❌ Don't construct `fmt.Options` literals without `.font` — it has no default (Gotcha 2).
- ❌ Don't try to import `Selection` from `ghostty_format` — it's private there; get it from
  `@import("ghostty-vt").Selection` (Gotcha 3, render_pipeline.md §4).
- ❌ Don't write the README attribution now — PRD §14/§5 Mode B defers it to P4.M2.T1.S1.

---

**Confidence Score: 10/10** for one-pass implementation success.

Every deliverable is specified by a frozen, sha-256-verified copy in `research/` (so the
implementer needs no network) plus a canonical upstream URL as fallback. The vendored file
was compiled end-to-end against the real Zig 0.15.2 toolchain with the cached ghostty v1.3.1
dep in a standalone throwaway project (`/tmp/t2h-vendor-verify`) — `zig build --release=fast`
→ exit 0 + 2.4 MB binary; `zig build run` → `formatter vendored OK`; `zig build test
--release=fast` → exit 0 (Options.font test passes). The #1 risk (ghostty API drift) is
eliminated: term2html `main` pins the *identical* ghostty v1.3.1 hash as our `build.zig.zon`.
The implementer is copying verified files into place, not authoring code.
