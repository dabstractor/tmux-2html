# Research findings — P1.M2.T1.S1: makePath in renderToFileAtomic + writeDocFileAtomic (Issue 3)

Bug: `render --output nested/deep/out.html` fails (`cannot write output file`, exit 1) when
`nested/deep/` doesn't exist, because the atomic-write helpers in `src/render.zig` call
`openDir(dir_path)` without first `makePath(dir_path)`. `pane` (main.zig:496) and `region`
(region.zig:484) already do it right. This PRP mirrors their idiom.

All facts read directly from `src/render.zig` (1560 lines, current on-disk state) + Zig 0.15.2 std.

## 1. The two functions and their IDENTICAL dir_path + openDir structure

Both functions compute `dir_path` then `openDir` (absolute-aware) with NO makePath:

**`renderToFileAtomic`** (`pub fn`, line 538) — the `render --output` path:
```zig
) !void {
    const dir_path = std.fs.path.dirname(path) orelse "."; // null for bare filenames   // line 547
    const base = std.fs.path.basename(path);
    ... tmp_name ...
    var dir = if (std.fs.path.isAbsolute(dir_path))                                       // line 558
        try std.fs.openDirAbsolute(dir_path, .{})                                         // line 559
    else
        try std.fs.cwd().openDir(dir_path, .{});                                          // line 561
    defer dir.close();
```

**`writeDocFileAtomic`** (private `fn`, line 602) — the `--selection` path:
```zig
fn writeDocFileAtomic(alloc, path, doc, fragment_bytes) !void {
    const dir_path = std.fs.path.dirname(path) orelse "."; // null for bare filenames   // line 603
    const base = std.fs.path.basename(path);
    ... tmp_name ...
    var dir = if (std.fs.path.isAbsolute(dir_path))                                       // line 611
        try std.fs.openDirAbsolute(dir_path, .{})
    else
        try std.fs.cwd().openDir(dir_path, .{});                                          // line 614
    defer dir.close();
```

(Note: `writeFileAtomic` at line 639 has the SAME structure but is NOT in scope — the item
names only the two functions above.)

**The fix (identical in both):** insert `std.fs.cwd().makePath(dir_path) catch {};` immediately
after the `const dir_path = …` line, before the `base`/tmp_name/openDir logic.

## 2. The correct precedent (pane + region already do this)

- `main.zig:496` (pane): `std.fs.cwd().makePath(out_dir) catch {};`
- `region.zig:484`: `if (std.fs.path.dirname(path)) |dp| std.fs.cwd().makePath(dp) catch {};`

Both use `std.fs.cwd().makePath(...)` unconditionally (no absolute/relative branching). Our two
functions already reduced `dirname(path) orelse "."`, so we insert `std.fs.cwd().makePath(dir_path)
catch {};` — one line, same idiom.

## 3. makePath is safe for our three cases (verified from std)

`std.fs/Dir.zig:1175` `pub fn makePath(self: Dir, sub_path) (MakeError||StatFileError)!void` —
idempotent (creates each missing component; if a component exists and is a dir, continues):
- **Relative `dir_path`** (e.g. `nested/deep`): creates from cwd. ✓
- **Absolute `dir_path`** (e.g. `/tmp/x/nested/deep`): `cwd()` is `AT_FDCWD`; `mkdirat` ignores
  `dirfd` for absolute paths on Linux → creates from root. Precedent (region/main) proves this. ✓
- **`dir_path == "."`** (bare filename, `orelse "."`): `makeDir(".")` → PathAlreadyExists →
  statFile → directory → continues; returns `.existed`. Harmless no-op. Plus `catch {}` swallows
  any error. ✓

So the existing absolute-aware `openDir` branch STAYS; makePath is a separate idempotent pre-step.

## 4. CRITICAL — the Terminal cross-test GOTCHA (decides the test strategy)

`src/render.zig:838` (the comment block above the tests) documents verbatim:
> "GHOSTTY-VT GOTCHA: ghostty-vt's Terminal.init leaves process-global state corrupted such that
> a **Terminal.init in a SEPARATE test function crashes (core dump)**. Sequential renderGrid calls
> in the SAME test scope are fine (verified). So ALL renderGrid assertions live in ONE test…"

`renderToFileAtomic` → `renderDocument` → `renderGrid` → `Terminal.init`. Therefore a NEW separate
test fn that calls `renderToFileAtomic` would risk crashing the whole suite. **CONSEQUENCE: do NOT
add a separate renderToFileAtomic test fn.** Instead:
- **Unit test `writeDocFileAtomic`** — it does NOT touch Terminal (it wraps a pre-rendered
  `fragment_bytes` via `writeDocumentBytes`, no renderGrid). Safe as its own test fn. It shares the
  IDENTICAL `dir_path` + `openDir` structure (and the identical makePath fix), so it proves the
  atomic-write idiom creates nested dirs.
- **Prove the actual `render --output` bug path via the Level-3 integration repro** (build the
  binary, run the exact repro from the issue, assert exit 0 + file exists). This exercises
  renderToFileAtomic end-to-end WITHOUT a Terminal-touching unit test.

This gives complete coverage (unit for the idiom + integration for the bug path) and respects the
documented GOTCHA. The item explicitly permits "(or writeDocFileAtomic)".

## 5. The unit test to add (model on the existing writeFileAtomic test, line 1310)

The closest analog is `test "writeFileAtomic: writes target, leaves no .tmp"` (line 1310), which:
- `var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();`
- `const dir_abs = try tmp.dir.realpathAlloc(alloc, ".");`
- builds an absolute path, calls the fn, opens + reads the file, asserts content.

The new test mirrors this but uses a NESTED path `{dir_abs}/nested/deep/out.html` (where
`nested/deep/` does NOT pre-exist) and asserts the file is created with valid HTML:

```zig
test "writeDocFileAtomic: creates nested parent dirs (Issue 3: render --output)" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_abs);
    // nested/deep/ does NOT exist yet — makePath must create it.
    const nested = try std.fmt.allocPrint(alloc, "{s}/nested/deep/out.html", .{dir_abs});
    defer alloc.free(nested);
    try writeDocFileAtomic(alloc, nested, .{ .title = "t" }, "<pre>NESTED</pre>");
    var f = try tmp.dir.openFile("nested/deep/out.html", .{});
    defer f.close();
    const got = try f.readToEndAlloc(alloc, 1 << 16);
    defer alloc.free(got);
    // Valid §8.1 document: DOCTYPE first, fragment present, closes </html>.
    try std.testing.expect(std.mem.startsWith(u8, got, "<!DOCTYPE html>"));
    try std.testing.expect(std.mem.indexOf(u8, got, "<pre>NESTED</pre>") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "</html>") != null);
}
```

Why these assertions are correct: `writeDocument`/`writeDocumentBytes` emit DOCTYPE first (proven by
the existing `test "writeDocument: full §8.1 envelope …"` at line 1365: "DOCTYPE is the FIRST
bytes"), wrap the fragment in `<body>`, and end with `</body>\n</html>\n`. `writeDocFileAtomic`
calls `writeDocumentBytes(&fw.interface, doc, fragment_bytes)` — same envelope.

`writeDocFileAtomic` is a PRIVATE fn; tests in the same file can call it (precedent: the
`writeFileAtomic` test calls the private `writeFileAtomic`). `DocumentOpts` needs only `.title`
(`lang` defaults `"en"`, `background` defaults `null`).

**Placement:** insert immediately AFTER the existing `writeFileAtomic` test (ends ~line 1336) and
BEFORE the `// ---- §8.1 HTML document envelope unit tests …` comment (line 1337). This keeps it
next to its closest analog and is a DIFFERENT insertion anchor than the parallel P1.M1.T2.S1 task
(which inserts after the `writeEscaped` test at line 1338) — no textual collision.

## 6. Edit-anchor uniqueness (implementer note)

The line `const dir_path = std.fs.path.dirname(path) orelse "."; // null for bare filenames` appears
**3×** (lines 547, 603, 639) — it is NOT a unique anchor. Distinguish by each function's signature:
- renderToFileAtomic: anchor on the unique `font: ?[]const u8,\n    doc: DocumentOpts,\n) !void {`
  immediately above its `dir_path` line.
- writeDocFileAtomic: anchor on the unique single-line signature `fn writeDocFileAtomic(alloc:
  std.mem.Allocator, path: []const u8, doc: DocumentOpts, fragment_bytes: []const u8) !void {`.
- Do NOT touch writeFileAtomic (line 639) — out of scope.

## 7. Build/test gate

- `zig build test --release=fast` — mandatory `--release=fast` (Debug hits the ghostty
  `R_X86_64_PC64` linker bug; documented across earlier PRPs + render.zig GOTCHA 5).
- `std.testing.tmpDir` creates a small temp dir and `defer tmp.cleanup()` removes it — no large
  scratch on tmpfs, consistent with the existing writeFileAtomic test and AGENTS.md §1.

## 8. Confidence

Surgical 2-line fix (one makePath per function) verbatim-mirroring two in-codebase precedents
(pane + region). The only subtlety is the Terminal cross-test GOTCHA (§4), which is sidestepped by
testing writeDocFileAtomic (no Terminal) + an integration repro for renderToFileAtomic. The test
assertion values (DOCTYPE-first, fragment present, `</html>`) are proven by the existing
writeDocument tests. No guessing.