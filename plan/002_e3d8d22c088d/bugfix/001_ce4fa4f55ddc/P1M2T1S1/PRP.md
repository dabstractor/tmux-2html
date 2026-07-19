# PRP — P1.M2.T1.S1: `makePath` in `renderToFileAtomic` + `writeDocFileAtomic` (Issue 3)

## Goal

**Feature Goal**: Fix the `render --output` / `--selection` "cannot write output file" bug
(architecture `system_context.md` §Issue 3; PRD §5.1) by ensuring the two atomic-write helpers in
`src/render.zig` create missing parent directories before opening the target dir — exactly as
`pane` (`main.zig:496`) and `region` (`region.zig:484`) already do. After the fix, writing to a
path whose parent dir does not yet exist succeeds instead of erroring.

**Deliverable**: ONE file changed (`/home/dustin/projects/tmux-2html/src/render.zig`):
- **2 one-line edits** — add `std.fs.cwd().makePath(dir_path) catch {};` in `renderToFileAtomic`
  (after line 547) and `writeDocFileAtomic` (after line 603).
- **1 new unit test** — `writeDocFileAtomic` creates nested parent dirs (proves the makePath idiom).
- **No new files, no other files touched.** `build.zig`, `cli.zig`, `main.zig`, `region.zig`
  UNCHANGED.

**Success Definition** (VERIFIED against the on-disk `src/render.zig` + Zig 0.15.2 std):
- `zig build test --release=fast` → exit 0; the new nested-dir test passes; all existing tests
  still pass (no new Terminal-init in a separate test fn — see Gotcha 3).
- The exact bug repro from the issue now succeeds end-to-end:
  `printf 'hi\n' | ./zig-out/bin/tmux-2html render --cols 5 --rows 1 --output nested/deep/out.html`
  → exit 0, and `nested/deep/out.html` exists with valid HTML.

## User Persona

**Target User**: (1) End users who run `tmux-2html render --output some/nested/path.html` (or the
`--selection` path); (2) the tmux plugin, whose bindings pass `--output` paths derived from
capture output that may land in directories tmux-2html didn't create.

**Use Case**: A user pipes ANSI to `render --output builds/2024/q3/report.html` where
`builds/2024/q3/` doesn't exist yet. Today this exits 1 (`cannot write output file`); after the
fix it writes the file. The same flag already works this way in `pane` and `region`.

**Pain Points Addressed**: Eliminates the confusing inconsistency where `--output` works for
`pane`/`region` but fails for `render` with the same flag and a missing parent dir.

## Why

- **Consistency for the same flag.** `--output FILE` is shared by `render`/`pane`/`region` (PRD
  §5.1–§5.3). `pane` calls `makePath(out_dir)` (main.zig:496); `region` calls
  `makePath(dirname(path))` (region.zig:484); only `render` omitted it. This PRP closes the gap.
- **User-facing robustness, low risk.** `makePath` is idempotent and the `catch {}` means the
  subsequent `openDir` still reports the real failure (e.g. permission denied) when makePath can't
  help. Zero behavior change for paths whose parent already exists.
- **Documented expected behavior (PRD §5.1).** `--output FILE write here instead of stdout` implies
  the file is written; the issue explicitly flags the missing-dir failure as a minor bug to fix.

## What

Make `renderToFileAtomic` and `writeDocFileAtomic` mirror `region`'s idiom: after computing
`dir_path`, call `std.fs.cwd().makePath(dir_path) catch {};` before the `openDir` branch. Add one
unit test proving a nested (non-existent) output path is created.

### Success Criteria

- [ ] `renderToFileAtomic` (src/render.zig:547) gains `std.fs.cwd().makePath(dir_path) catch {};`.
- [ ] `writeDocFileAtomic` (src/render.zig:603) gains the same line.
- [ ] New unit test `writeDocFileAtomic: creates nested parent dirs (Issue 3 …)` passes.
- [ ] `zig build test --release=fast` → exit 0 (all tests pass; no new Terminal-init crash).
- [ ] Bug repro (`render --output nested/deep/out.html`) → exit 0, file created with valid HTML.
- [ ] Only `src/render.zig` changed; `writeFileAtomic` (line 639) NOT touched (out of scope).

## All Needed Context

### Context Completeness Check

_Pass: "If someone knew nothing about this codebase, would they have everything needed to
implement this successfully?"_ — Yes. The exact lines to edit (547, 603), the exact one-liner to
insert, the edit-anchor-uniqueness pitfall (the `dir_path` line appears 3× — anchor on each
function's signature), the in-codebase precedents (main.zig:496, region.zig:484), the makePath
safety for absolute/relative/`.` cases, the verbatim test to add (modelled on the existing
`writeFileAtomic` test at line 1310), and the critical Terminal cross-test GOTCHA (which forces
testing `writeDocFileAtomic`, not `renderToFileAtomic`, as a separate test fn) are all documented
with line citations in `research/findings.md`. The implementer is making a verified, mechanical
2-line edit + 1 test.

### Documentation & References

```yaml
# MUST READ — the authoritative bug + fix recipe (line citations, GOTCHA, verbatim test)
- file: plan/002_e3d8d22c088d/bugfix/001_ce4fa4f55ddc/P1M2T1S1/research/findings.md
  why: "§1 the two functions + their IDENTICAL dir_path/openDir structure (lines 547, 603);
        §2 the correct precedent (main.zig:496, region.zig:484); §3 makePath is safe for
        absolute/relative/'.'; §4 the Terminal cross-test GOTCHA -> test writeDocFileAtomic;
        §5 the verbatim test (modeled on the writeFileAtomic test at line 1310);
        §6 the anchor-uniqueness pitfall (dir_path line appears 3×)."
  critical: "The Terminal-init cross-test GOTCHA (render.zig:838): a SEPARATE test fn calling
             renderToFileAtomic crashes (core dump). Test writeDocFileAtomic instead (no Terminal),
             and prove renderToFileAtomic via the Level-3 integration repro."

# MUST READ — the file being edited
- file: src/render.zig
  section: "renderToFileAtomic (538, dir_path at 547); writeDocFileAtomic (602, dir_path at 603);
            writeFileAtomic (639, NOT in scope); the writeFileAtomic test (1310, the test pattern
            to mirror); the Terminal GOTCHA comment block (838); DocumentOpts (198)."
  why: "Confirms the exact edit points, that the two functions share identical dir_path+openDir
        logic, that writeFileAtomic is OUT of scope, and that the test pattern + assertions are
        already proven by writeFileAtomic/writeDocument tests."
  gotcha: "The `const dir_path = std.fs.path.dirname(path) orelse \".\";` line appears 3× (547,
           603, 639) — it is NOT a unique edit anchor. Distinguish by each function's signature
           (renderToFileAtomic: the `font: ?[]const u8,` line above; writeDocFileAtomic: its
           single-line signature). Never edit writeFileAtomic (639)."

# MUST READ — the in-codebase correct precedents to mirror verbatim
- file: src/region.zig
  section: "line 484"
  why: "`if (std.fs.path.dirname(path)) |dp| std.fs.cwd().makePath(dp) catch {};` — the exact
        idiom. Our functions already reduced dirname to `dir_path` (orelse \".\"), so we insert
        `std.fs.cwd().makePath(dir_path) catch {};`."
- file: src/main.zig
  section: "line 496 (pane)"
  why: "`std.fs.cwd().makePath(out_dir) catch {};` — confirms cwd().makePath is the established
        pattern (handles absolute + relative paths; idempotent)."

# PRD context (the documented --output behavior)
- file: PRD.md
  section: "§5.1 (render --output FILE) + Minor Issue 3"
  why: "Confirms this is a documented minor bug: --output should write the file; render omitted
        makePath that pane/region have."

# Zig 0.15.2 std (authoritative for makePath)
- file: /home/dustin/.local/opt/zig-x86_64-linux-0.15.2/lib/std/fs/Dir.zig
  section: "makePath (1175), makePathStatus (1181)"
  why: "makePath is idempotent: creates each missing component; if a component exists & is a dir,
        continues; returns .existed for an already-present path. Safe no-op for \".\" (bare
        filename via orelse \".\"). mkdirat(AT_FDCWD, absolute_path) ignores dirfd on Linux for
        absolute paths."
```

### Current Codebase tree (this task's starting point)

```bash
tmux-2html/
├── src/
│   ├── render.zig        # 1560 lines; renderToFileAtomic(538) + writeDocFileAtomic(602) ← EDIT
│   ├── main.zig          # pane makePath precedent (line 496)                        ← DO NOT TOUCH
│   ├── region.zig        # region makePath precedent (line 484)                      ← DO NOT TOUCH
│   ├── cli.zig  palette.zig  ghostty_format.zig  capture.zig  ...                    ← DO NOT TOUCH
├── build.zig  build.zig.zon                                                           ← DO NOT TOUCH
└── PRD.md  plan/  ...
```

### Desired Codebase tree with files to be changed

```bash
tmux-2html/
└── src/
    └── render.zig        # +2 makePath lines (547, 603) +1 nested-dir unit test
```

### Known Gotchas of our codebase & Library Quirks

```zig
// GOTCHA 1 — EDIT-ANCHOR UNIQUENESS: the line `const dir_path = std.fs.path.dirname(path)
//   orelse ".";` appears THREE times (547, 603, 639) — NOT a unique anchor on its own. To edit
//   renderToFileAtomic and writeDocFileAtomic WITHOUT touching writeFileAtomic (639, OUT of
//   scope), your edit's oldText must pair the signature lines with the `dir_path` line so each
//   match is unique and lands in the intended function:
//     - renderToFileAtomic (547): oldText = the full 5-line `Before` block in Edit 1 below
//       (`font: ?[]const u8,` / `doc: DocumentOpts,` / `) !void {` / `const dir_path = …` /
//       `const base = …`). VERIFIED unique (1 occurrence in render.zig). The bare `dir_path`
//       line alone would also match lines 603 + 639 — so always include the signature.
//     - writeDocFileAtomic (603): oldText = its single-line signature `fn writeDocFileAtomic(
//       alloc: …, doc: DocumentOpts, fragment_bytes: []const u8) !void {` + the `dir_path` line.
//       VERIFIED unique (1 occurrence).
//   Use the exact `Before` blocks in Edit 1 / Edit 2 below verbatim — both are verified unique.

// GOTCHA 2 — makePath before openDir, with `catch {}`: std.fs.cwd().makePath(dir_path) catch {};
//   Idempotent + error-tolerant. If makePath can't help (e.g. permission denied on a parent),
//   the subsequent openDir reports the REAL failure — so `catch {}` is correct (don't surface a
//   confusing makePath error). cwd().makePath handles absolute paths (mkdirat ignores AT_FDCWD
//   for absolute paths on Linux) AND "." (bare filename via orelse ".") — proven by main.zig:496
//   and region.zig:484 which use it unconditionally.

// GOTCHA 3 — CRITICAL (test strategy): render.zig:838 documents that ghostty-vt's Terminal.init
//   leaves process-global state corrupted so that "a Terminal.init in a SEPARATE test function
//   crashes (core dump)". renderToFileAtomic -> renderDocument -> renderGrid -> Terminal.init.
//   THEREFORE: do NOT add a separate test fn that calls renderToFileAtomic. Test writeDocFileAtomic
//   instead — it wraps a pre-rendered fragment (writeDocumentBytes) and NEVER touches Terminal, so
//   it is safe as its own test fn. It shares the IDENTICAL dir_path+openDir structure (and the
//   identical makePath fix). Prove the actual render --output bug path via the Level-3 integration
//   repro (build + run the exact issue repro). The item explicitly permits "(or writeDocFileAtomic)".

// GOTCHA 4 — build/test MUST use --release=fast: Debug linking hits the ghostty R_X86_64_PC64
//   linker bug. `zig build test` (no release flag) will FAIL. Always `zig build test --release=fast`.

// GOTCHA 5 — std.testing.tmpDir auto-cleans via `defer tmp.cleanup()`; the HTML output is tiny.
//   This matches the existing writeFileAtomic test (line 1310) and AGENTS.md §1 (no large scratch
//   on tmpfs). Do NOT invent a getenv("TMPDIR")-based temp scheme — tmpDir is the in-codebase idiom.
```

## Implementation Blueprint

### Data models and structure

No data-model changes. The only types referenced are already in `render.zig`:
`DocumentOpts` (line 198: `title: []const u8` required; `lang` defaults `"en"`, `background`
defaults `null`) — used by the new test as `.{ .title = "t" }`.

### The exact deliverable: `src/render.zig` (EDIT — 2 lines + 1 test)

**Edit 1 — `renderToFileAtomic`** (anchor on the unique signature lines just above line 547):

Before:
```zig
    font: ?[]const u8,
    doc: DocumentOpts,
) !void {
    const dir_path = std.fs.path.dirname(path) orelse "."; // null for bare filenames
    const base = std.fs.path.basename(path);
```
After (one new line):
```zig
    font: ?[]const u8,
    doc: DocumentOpts,
) !void {
    const dir_path = std.fs.path.dirname(path) orelse "."; // null for bare filenames
    std.fs.cwd().makePath(dir_path) catch {}; // Issue 3: ensure parent dirs exist (idempotent; openDir below reports the real failure)
    const base = std.fs.path.basename(path);
```

**Edit 2 — `writeDocFileAtomic`** (anchor on its unique single-line signature):

Before:
```zig
fn writeDocFileAtomic(alloc: std.mem.Allocator, path: []const u8, doc: DocumentOpts, fragment_bytes: []const u8) !void {
    const dir_path = std.fs.path.dirname(path) orelse "."; // null for bare filenames
    const base = std.fs.path.basename(path);
```
After (one new line):
```zig
fn writeDocFileAtomic(alloc: std.mem.Allocator, path: []const u8, doc: DocumentOpts, fragment_bytes: []const u8) !void {
    const dir_path = std.fs.path.dirname(path) orelse "."; // null for bare filenames
    std.fs.cwd().makePath(dir_path) catch {}; // Issue 3: ensure parent dirs exist (idempotent)
    const base = std.fs.path.basename(path);
```

**New test** — insert immediately AFTER the existing `test "writeFileAtomic: writes target,
leaves no .tmp"` (ends ~line 1336) and BEFORE the
`// ---- §8.1 HTML document envelope unit tests …` comment (line 1337). This is a DIFFERENT
insertion anchor than the parallel P1.M1.T2.S1 task (which inserts after the `writeEscaped`
test at line 1338), so the two do not collide.

```zig
test "writeDocFileAtomic: creates nested parent dirs (Issue 3: render --output)" {
    // writeDocFileAtomic shares the IDENTICAL dir_path + openDir structure as renderToFileAtomic,
    // so it proves the makePath fix for the atomic-write idiom. It does NOT touch Terminal
    // (render.zig:838 GOTCHA), so it is safe as its own test fn — unlike renderToFileAtomic.
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_abs);
    // nested/deep/ does NOT exist under tmp — makePath must create it.
    const nested = try std.fmt.allocPrint(alloc, "{s}/nested/deep/out.html", .{dir_abs});
    defer alloc.free(nested);
    try writeDocFileAtomic(alloc, nested, .{ .title = "t" }, "<pre>NESTED</pre>");

    // File created with a valid §8.1 document (DOCTYPE first, fragment present, closes </html>).
    var f = try tmp.dir.openFile("nested/deep/out.html", .{});
    defer f.close();
    const got = try f.readToEndAlloc(alloc, 1 << 16);
    defer alloc.free(got);
    try std.testing.expect(std.mem.startsWith(u8, got, "<!DOCTYPE html>"));
    try std.testing.expect(std.mem.indexOf(u8, got, "<pre>NESTED</pre>") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "</html>") != null);
}
```

Why the assertions hold: `writeDocument`/`writeDocumentBytes` emit `<!DOCTYPE html>` first and end
with `</body>\n</html>\n` wrapping the fragment — proven by the existing
`test "writeDocument: full §8.1 envelope …"` (line 1365) and `test "writeDocumentBytes: …"` (1412).
`writeDocFileAtomic` is a private fn callable from same-file tests (precedent: the `writeFileAtomic`
test calls the private `writeFileAtomic`).

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: EDIT src/render.zig — renderToFileAtomic (line 547)
  - ADD: `std.fs.cwd().makePath(dir_path) catch {};` immediately after the
          `const dir_path = std.fs.path.dirname(path) orelse ".";` line.
  - ANCHOR: use the full 5-line `Before` block in Edit 1 below verbatim as oldText. It pairs the
            renderToFileAtomic signature with the `dir_path` line and is VERIFIED unique (1 match).
            (The bare `dir_path` line alone is NOT unique — it also appears at 603/639.)
  - DO NOT touch writeFileAtomic (639).

Task 2: EDIT src/render.zig — writeDocFileAtomic (line 603)
  - ADD: the same line after its `const dir_path = …` line.
  - ANCHOR: the unique single-line `fn writeDocFileAtomic(…) !void {` signature.

Task 3: ADD unit test in src/render.zig (after the writeFileAtomic test, ~line 1336)
  - ADD: the `test "writeDocFileAtomic: creates nested parent dirs (Issue 3: render --output)"` block above.
  - FOLLOW pattern: the existing `writeFileAtomic` test at line 1310 (tmpDir + realpathAlloc + openFile + readToEndAlloc).
  - COVERAGE: nested path whose parent doesn't exist -> file created with valid HTML.
  - WHY writeDocFileAtomic not renderToFileAtomic: Gotcha 3 (Terminal cross-test crash).

Task 4: VALIDATE  (see Validation Loop)
  - RUN: zig build test --release=fast      # new test + all existing pass
  - RUN: zig build --release=fast            # build the binary
  - RUN: the Issue 3 repro (Level 3)         # render --output nested/... -> exit 0, file exists
```

### Implementation Patterns & Key Details

```zig
// PATTERN: makePath before openDir, idempotent + error-tolerant. Mirrors region.zig:484 +
//   main.zig:496 verbatim. cwd().makePath handles absolute (mkdirat ignores AT_FDCWD for abs
//   paths) and "." (bare filename via orelse "."). The `catch {}` lets the subsequent openDir
//   report the real failure when makePath can't help (e.g. permission denied).
const dir_path = std.fs.path.dirname(path) orelse ".";
std.fs.cwd().makePath(dir_path) catch {};   // <-- THE FIX (one line)
const base = std.fs.path.basename(path);
...
var dir = if (std.fs.path.isAbsolute(dir_path))   // UNCHANGED
    try std.fs.openDirAbsolute(dir_path, .{})
else
    try std.fs.cwd().openDir(dir_path, .{});

// PATTERN: unit test for the atomic-write idiom, modelled on the writeFileAtomic test (line 1310).
//   Uses std.testing.tmpDir + realpathAlloc to get an absolute tmp path, builds a NESTED path
//   whose parent doesn't exist, calls the fn, then opens+reads the file via tmp.dir (relative
//   nested path) and asserts content. writeDocFileAtomic (not renderToFileAtomic) because the
//   latter would crash a separate test fn (Terminal cross-test GOTCHA, render.zig:838).
```

### Integration Points

```yaml
BUILD GRAPH:
  - consumes (unchanged): build.zig, build.zig.zon, all other src/*.zig. No new imports.
  - produces: src/render.zig with 2 makePath lines + 1 test.
  - PARALLEL WORK (P1.M1.T2.S1): also edits src/render.zig — it adds a test after the `writeEscaped`
    test (line 1338) and edits ghostty_format.zig. This task's edit points (lines 547, 603, and
    the test inserted after line 1336) are DIFFERENT anchors, so the two do not collide. Do NOT
    touch ghostty_format.zig or the writeEscaped test (owned by P1.M1.T2.S1).

CLI SURFACE (PRD §5.1):
  - No flag/API/help-text change. `--output FILE` now writes the file even when the parent dir is
    absent, matching pane/region. The render --help text does not mention parent dirs, so no doc edit.
```

## Validation Loop

> Re-run verbatim. EVERY build/test command MUST include `--release=fast` (Gotcha 4).

### Level 1: Syntax & Style (Immediate Feedback)

```bash
zig version            # MUST print: 0.15.2
zig build --fetch      # exit 0 (deps cached)
```

### Level 2: Unit tests (PRIMARY gate — proves the makePath idiom)

```bash
# The new writeDocFileAtomic nested-dir test + ALL existing tests (incl. the renderGrid test at
# 913 which must NOT be disturbed). No new Terminal-init in a separate fn (Gotcha 3).
zig build test --release=fast          # expect: all passed, exit 0

# If "unhandled relocation type R_X86_64_PC64" -> forgot --release=fast (Gotcha 4).
# If a core dump / crash appears -> a Terminal-init was added in a separate test fn (Gotcha 3);
#   ensure the new test calls writeDocFileAtomic, NOT renderToFileAtomic.
```

### Level 3: Integration — the actual bug repro (proves renderToFileAtomic end-to-end)

```bash
zig build --release=fast               # expect: exit 0; zig-out/bin/tmux-2html produced
BIN="zig-out/bin/tmux-2html"

# Exact repro from the issue (architecture system_context.md §Issue 3). Before the fix this
# exited 1 with "cannot write output file"; after the fix it must exit 0 and create the file.
rm -rf nested
printf 'hi\n' | "$BIN" render --cols 5 --rows 1 --output nested/deep/out.html
echo "exit=$? (want 0)"
test -f nested/deep/out.html && echo "file created: OK"
grep -q '<!DOCTYPE html>' nested/deep/out.html && echo "valid HTML: OK"
rm -rf nested   # cleanup (scoped — only the dir this command created)

# Also exercise the --selection path (writeDocFileAtomic) for completeness:
rm -rf nested
printf 'hi\n' | "$BIN" render --cols 5 --rows 1 --selection 0,0,2,0 --output nested/sel/out.html
echo "selection exit=$? (want 0)"
test -f nested/sel/out.html && echo "selection file created: OK"
rm -rf nested
```

### Level 4: Scope boundary (Domain Validation)

```bash
# ONLY src/render.zig changed; build files + other src files untouched.
git diff --stat build.zig build.zig.zon src/main.zig src/region.zig src/cli.zig   # expect: no output
git diff --stat src/render.zig                                                    # expect: render.zig modified

# writeFileAtomic (line 639) NOT touched:
git diff src/render.zig | grep -n 'writeFileAtomic' || echo "writeFileAtomic untouched: OK"
```

## Final Validation Checklist

### Technical Validation

- [ ] `zig version` prints `0.15.2`; `zig build --fetch` exits 0.
- [ ] `zig build test --release=fast` exits 0 (new test + all existing tests pass; no crash).
- [ ] `zig build --release=fast` exits 0; `zig-out/bin/tmux-2html` produced.

### Feature Validation

- [ ] `renderToFileAtomic` (547) + `writeDocFileAtomic` (603) each have `std.fs.cwd().makePath(dir_path) catch {};`.
- [ ] New `writeDocFileAtomic: creates nested parent dirs (Issue 3 …)` test passes.
- [ ] Bug repro: `printf 'hi\n' | ./zig-out/bin/tmux-2html render --cols 5 --rows 1 --output nested/deep/out.html` → exit 0, file exists with `<!DOCTYPE html>`.
- [ ] `--selection` path also creates nested dirs (writeDocFileAtomic repro → exit 0).

### Code Quality Validation

- [ ] The makePath idiom matches `region.zig:484` / `main.zig:496` verbatim (cwd().makePath + catch {}).
- [ ] `writeFileAtomic` (line 639) NOT modified (out of scope).
- [ ] New test follows the existing `writeFileAtomic` test pattern (tmpDir + realpathAlloc + openFile + readToEndAlloc).
- [ ] No new Terminal-init introduced in a separate test fn (Gotcha 3 respected).

### Documentation & Deployment

- [ ] No flag/API/help-text change (the render --help text does not mention parent dirs).
- [ ] No new env vars or config.

---

## Anti-Patterns to Avoid

- ❌ Don't edit `writeFileAtomic` (line 639) — it shares the `dir_path` line but is OUT of scope; the
  item names only `renderToFileAtomic` and `writeDocFileAtomic`. The `dir_path` line appears 3×, so
  anchor each edit on the function's unique signature, not the shared line (Gotcha 1).
- ❌ Don't add a separate test fn that calls `renderToFileAtomic` — it does `renderGrid`→`Terminal.init`,
  which crashes a separate test fn per the documented GOTCHA (render.zig:838). Test `writeDocFileAtomic`
  (no Terminal) and prove `renderToFileAtomic` via the Level-3 integration repro (Gotcha 3).
- ❌ Don't surface makePath errors — use `catch {}` so the subsequent `openDir` reports the real
  failure (e.g. permission denied). makePath is a best-effort, idempotent pre-step.
- ❌ Don't branch makePath on absolute/relative — `std.fs.cwd().makePath(dir_path)` handles both
  (precedent: main.zig:496, region.zig:484). The existing absolute-aware `openDir` branch stays as-is.
- ❌ Don't build/test WITHOUT `--release=fast` — Debug linking hits `R_X86_64_PC64` (Gotcha 4).
- ❌ Don't invent a `getenv("TMPDIR")` temp scheme — use `std.testing.tmpDir(.{})` + `defer tmp.cleanup()`
  (the in-codebase idiom, matches the writeFileAtomic test; Gotcha 5).
- ❌ Don't touch `ghostty_format.zig` or the `writeEscaped` test — those are owned by the parallel
  P1.M1.T2.S1 task. This task's edit anchors (lines 547, 603, test after 1336) are distinct.

---

**Confidence Score: 9/10** for one-pass implementation success.

The fix is a verified, mechanical 2-line edit (one `std.fs.cwd().makePath(dir_path) catch {};` per
function) verbatim-mirroring two in-codebase precedents (`region.zig:484`, `main.zig:496`). Both
target functions share an identical `dir_path` + `openDir` structure (read line-by-line at 547 and
603), and `makePath` is proven idempotent + safe for absolute/relative/`.` paths from the Zig 0.15.2
std source. The one subtlety — the documented Terminal cross-test GOTCHA (`render.zig:838`) that
forbids a separate `renderToFileAtomic` test fn — is sidestepped by testing `writeDocFileAtomic`
(no Terminal; same atomic-write idiom) and proving the actual `render --output` bug path via the
Level-3 integration repro. The new test's assertions (DOCTYPE-first, fragment present, `</html>`)
are proven by the existing `writeDocument`/`writeDocumentBytes` tests. The only residual risk is a
merge-ordering interaction with the parallel P1.M1.T2.S1 render.zig edit, mitigated by using distinct
edit anchors (547/603 + test-after-1336 vs. P1.M1.T2.S1's ghostty_format.zig:841 + test-after-1338).