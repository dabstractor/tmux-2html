# PRP — P1.M1.T2.S1: HTML-escape `--font` / `@tmux-2html-font` at the emission point (Issue 2 XSS)

## Goal

**Feature Goal**: Close the stored-XSS / HTML-attribute-injection vector in PRD §Issue 2. The
absorbed `ScreenFormatter` bakes the user's `--font` value **raw** into the `<pre style="…">`
attribute (`src/ghostty_format.zig:841`: `buf_writer.print("font-family: {s};", .{font})`), so a
`"` in the value breaks out of the attribute and injects arbitrary attributes / DOM-event
handlers (e.g. `onmouseover="alert(1)"`) — executable when the shared HTML is opened. Replace
that one line with an inline per-byte HTML-escape loop (the same escape set as the project's
`writeEscaped`), and add a unit test that proves the payload is neutralized. Goldens are
unaffected (they use `null` font → `"monospace"`, no special chars — proven byte-equal).

**Deliverable**: Three small edits, no new files:
1. **EDIT `src/ghostty_format.zig`** — replace line 841 (the raw `font-family: {s}` print) with
   an inline HTML-escape loop (`"` `&` `<` `>` `'` → entities; `catch return error.WriteFailed`).
2. **EDIT `src/render.zig`** — add one unit test (right after the existing `test "writeEscaped:
   …"`) that calls `renderGrid` with the XSS payload font and asserts the entity-escaped form +
   no attribute breakout.
3. **EDIT `docs/CONFIGURATION.md`** — one-sentence security note on the `@tmux-2html-font` row.

**Success Definition** (all VERIFIED in a throwaway build against the live repo):
- `zig build test --release=fast` → exit 0, **all 326 tests pass** (incl. the new XSS test +
  both goldens byte-equal).
- The new test is a **proven regression detector**: with the fix reverted (test kept) it FAILS
  (`325/326, 1 failed`, this test named); with the fix applied it PASSES.
- `render --font 'a" onmouseover="alert(1)'` now emits `font-family: a&quot;
  onmouseover=&quot;alert(1);` — no raw `"` leaks, no `onmouseover` attribute is created.

## User Persona

**Target User**: Anyone who shares tmux-2html output (the explicit §8.1 use case: "a standalone
HTML document you can open, share, and trust in any browser"), and especially anyone who sets
`@tmux-2html-font` (or passes `--font`) — including from a copied/shared `tmux.conf` snippet.

**Use Case**: `set -g @tmux-2html-font "Fira Code"` keeps working unchanged; a careless or
malicious value like `bad" onmouseover="alert(1)` is now inert rather than weaponized.

**Pain Points Addressed**: Today a `"` in the font value executes attacker-controlled JS in
recipients' browsers when they hover the captured terminal content. This fix makes the §8.1
"trust in any browser" guarantee actually hold for the font knob.

## Why

- **PRD §8.1 (normative)**: "All text inserted into the envelope (`<title>`, etc.) is
  HTML-escaped" and the document must be safe to "share and open in any browser". The font value
  is inserted into an HTML *attribute* and currently bypasses all escaping — a direct §8.1
  violation. This fix routes it through the same HTML-escape discipline as `<title>`.
- **Stored-XSS, not just a cosmetic bug**: a crafted `@tmux-2html-font` in a shared `tmux.conf`
  bakes a JS payload into every HTML the victim generates and shares. Closing it at the single
  emission point covers all three subcommands (render/pane/region share `renderGrid`).
- **Zero behavior change for normal fonts**: a typical font name (`Fira Code`, `monospace`)
  contains none of `"` `&` `<` `>` `'`, so escaping is a byte-for-byte no-op — goldens stay
  byte-equal (proven). The browser decodes `&quot;` back to `"` for the CSS value, so a legit
  quoted font is unaffected.
- **Minimal, surgical, precedent-matched**: the escape set is copied verbatim from the project's
  own `writeEscaped` (`render.zig:299`); the error idiom (`catch return error.WriteFailed`) is
  copied from the adjacent lines (:831/:836/:842). No new abstraction, no new dependency.

## What

One line in `ghostty_format.zig` becomes a per-byte escape loop; one test is added in
`render.zig`; one docs sentence is appended. Semantics:

1. **Emission (ghostty_format.zig:841)**: write `font-family: `, then for each byte of `font`:
   `"`→`&quot;`, `&`→`&amp;`, `<`→`&lt;`, `>`→`&gt;`, `'`→`&#x27;`, else the byte; then `;`. All
   writes `catch return error.WriteFailed`. The `const font = self.opts.font orelse "monospace";`
   line above (840) is UNCHANGED.
2. **Test (render.zig)**: `renderGrid(…, "a\" onmouseover=\"alert(1)", &aw.writer)` → assert the
   buffered output contains `font-family: a&quot; onmouseover=&quot;alert(1);` and does NOT
   contain the raw breakout `onmouseover="alert`.
3. **Docs (CONFIGURATION.md)**: note the font value is HTML-escaped in the `style` attribute.

### Success Criteria

- [ ] `src/ghostty_format.zig:841` emits an entity-escaped `font-family` (no raw `{s}`).
- [ ] `src/render.zig` has the new `test "renderGrid escapes --font into <pre style> …"`.
- [ ] `zig build test --release=fast` → exit 0, all tests pass (incl. new test + goldens).
- [ ] Regression-detector proof: reverting the fix makes the new test FAIL (it catches the XSS).
- [ ] `docs/CONFIGURATION.md` font row notes the HTML-escaping.

## All Needed Context

### Context Completeness Check

_Pass: "If someone knew nothing about this codebase, would they have everything needed to
implement this successfully?"_ — Yes. The single line to replace is given as exact BEFORE/AFTER
(unique in the file); the verbatim test (proven FAIL-before/PASS-after) is given with its exact
insertion anchor; the escape set is copied from the project's own `writeEscaped`; the docs edit
names its exact row. The whole fix was built and run in a throwaway copy: 326/326 pass with it,
325/326 + this test failing without it. No guessing.

### Documentation & References

```yaml
# MUST READ — the authoritative fix recipe (escape set + buf_writer API + CSS safety)
- file: plan/002_e3d8d22c088d/bugfix/001_ce4fa4f55ddc/architecture/external_deps.md
  section: "§HTML Attribute Escaping (Issue 2)"
  why: "Canonical escape table (& < > \" '), confirms buf_writer has .writeAll/.writeByte/.print, and that &quot; renders back to \" for the CSS value."
  critical: "Single per-byte pass => no double-encoding. Don't reuse writeEscaped (different writer type); inline the loop with `catch return error.WriteFailed`."

# MUST EDIT — the bug site (THE primary deliverable)
- file: src/ghostty_format.zig
  section: "line 840 (const font = … orelse \"monospace\"); line 841 (buf_writer.print(\"font-family: {s};\", .{font}))"
  why: "Line 841 is THE bug — raw {s} into the double-quoted style attribute. Replace it with the escape loop. Line 840 stays."
  pattern: "Error idiom of this file: `<writer-call> catch return error.WriteFailed` (see :831, :836, :842). Match it exactly."
  gotcha: "`font` here is []const u8 (840 already unwrapped the optional), so `for (font) |c|` iterates bytes. Do NOT touch line 840 or the default."

# MUST EDIT — the test home (has tests today; reached by the test step)
- file: src/render.zig
  section: "writeEscaped fn :299 (escape-set reference); writeEscaped TEST :1338 (insertion anchor + std.Io.Writer.Allocating pattern); renderGrid pub fn :143 (the test target)"
  why: "Add the new test right after the writeEscaped test. Call renderGrid (sibling fn) with the XSS font; assert on aw.writer.buffered()."
  pattern: "Mirror `test \"writeEscaped: …\"`: `var aw = try std.Io.Writer.Allocating.initCapacity(std.testing.allocator, N); defer aw.deinit(); … try std.testing.expect(std.mem.indexOf(...) != null);`"
  gotcha: "main.zig:565 does `_ = @import(\"render.zig\")`, so tests here ARE in the test binary. ghostty_format.zig has NO test blocks — do NOT add the test there."

# INPUT CONTRACT — the font flow (do NOT re-implement; just understand the path the fix covers)
- file: src/cli.zig
  section: "opts.font (RenderOpts/PaneOpts/RegionOpts) -> renderGrid(font: ?[]const u8)"
  why: "Confirms render/pane/region ALL reach the fixed emission point via renderGrid -> ScreenFormatter.init(.font=font) -> self.opts.font. One fix covers all three."
- file: src/golden_test.zig
  section: ":30 renderDocument(..., null /* font */, ...)"
  why: "Goldens pass font=null => formatter default 'monospace' => no special chars => escaping is a no-op for them. PROVEN byte-equal with the fix."

# CONTRACT SOURCE — the bug report
- file: plan/002_e3d8d22c088d/bugfix/001_ce4fa4f55ddc/prd_snapshot.md  (or prd_index §Issue 2)
  section: "Issue 2 (HTML attribute injection / stored-XSS via --font)"
  why: "Repro, root cause, threat model, suggested fix. This PRP implements the 'escape at emission point' option."

# PARALLEL-TASK BOUNDARY (do NOT collide)
- file: plan/002_e3d8d22c088d/bugfix/001_ce4fa4f55ddc/P1M1T1S1/PRP.md
  why: "Issue 1 (apostrophe-in-title) is a SHELL-only fix: tmux-2html.tmux + tests/plugin_options.sh + a CONFIGURATION.md note in the TITLE/LANG threading paragraph (~lines 84-88). This task edits the FONT table row (line 45) — a different, non-adjacent location. No collision."

# PRD normative source
- file: PRD.md
  section: "§8.1 (HTML-escaped envelope; 'share and trust in any browser'); §5.1 (--font FAMILY); §9.2 (@tmux-2html-font)"

# Empirical verification for THIS task
- file: plan/002_e3d8d22c088d/bugfix/001_ce4fa4f55ddc/P1M1T2S1/research/findings.md
  why: "Records the throwaway build: PASS-after (326 green) + FAIL-before (325/326, this test named), the verbatim edits, the writeEscaped reference, and the golden-invariant proof."
```

### Current Codebase tree (relevant slice)

```bash
tmux-2html/
├── src/
│   ├── ghostty_format.zig   # <— EDIT line 841: raw {s} → inline HTML-escape loop (THE fix)
│   ├── render.zig           # <— EDIT: add the XSS unit test after the writeEscaped test (:1338)
│   ├── cli.zig              # opts.font — INPUT (do NOT edit)
│   ├── golden_test.zig      # null-font goldens — DO NOT touch (proven byte-equal)
│   └── main.zig  region.zig # render/pane/region reach renderGrid — DO NOT touch
├── docs/CONFIGURATION.md    # <— EDIT: @tmux-2html-font row security note
└── build.zig                # test step: addTest(.{.root_module=exe.root_module}) rooted at main.zig
```

### Desired Codebase tree with files to be changed

```bash
tmux-2html/
├── src/
│   ├── ghostty_format.zig   # MODIFIED — line 841 (1 print) → ~13-line escape loop; line 840 unchanged
│   └── render.zig           # MODIFIED — +1 test fn after the writeEscaped test
└── docs/CONFIGURATION.md    # MODIFIED — @tmux-2html-font row + security note
# NO new files. NO changes to cli.zig / golden_test.zig / testdata / tmux-2html.tmux.
```

### Known Gotchas of our codebase & Library Quirks

```zig
// GOTCHA 1 — buf_writer is a FIXED-BUFFER-STREAM writer, NOT std.Io.Writer. You CANNOT call
//   render.zig's writeEscaped(buf_writer, font) directly: writeEscaped takes *std.Io.Writer and
//   uses `try`; buf_writer's methods return an error union this file handles with
//   `catch return error.WriteFailed`. Inline the loop with THIS file's idiom. (external_deps.md
//   §HTML Attribute Escaping; verified by the adjacent lines.)

// GOTCHA 2 — `font` at line 840 is ALREADY []const u8 (orelse unwrapped the optional). So
//   `for (font) |c|` iterates BYTES directly — do NOT re-unwrap or assume ?[]const u8 here.

// GOTCHA 3 — single per-byte pass => NO double-encoding risk. The "escape & first" rule only
//   applies to sequential whole-string replacement; a per-byte switch maps each input byte to
//   exactly one output, so `&`→`&amp;` is never itself re-scanned. Order of switch arms is
//   irrelevant to correctness (kept parallel to writeEscaped only for readability).

// GOTCHA 4 — the default "monospace" (line 840) contains no special chars, so escaping it is a
//   byte-for-byte no-op. THAT is why goldens (null font => "monospace") stay byte-equal.
//   Do NOT special-case the default; escape `font` uniformly (simpler + correct).

// GOTCHA 5 — tests MUST run in ReleaseFast. `zig build test` (Debug) fails with the known Zig
//   0.15.2 linker bug (R_X86_64_PC64) from ghostty-vt's bundled C++ SIMD libs. Always:
//   `zig build test --release=fast`. (PRD §15; matches ci.yml.)

// GOTCHA 6 — the new test calls renderGrid with TRIVIAL input ("x\n", 1x1). The <pre> header
//   (with font-family) is emitted BEFORE the cell loop, so the font declaration is present even
//   for a 1-cell grid — no need to feed real ANSI. (Verified: the assertion matches.)

// GOTCHA 7 — assertion (2) checks the ABSENCE of the raw breakout `onmouseover="alert`. Do NOT
//   assert "no raw " anywhere" — the style attribute's own delimiters are legitimate " chars.
//   The targeted substring `onmouseover="alert` appears ONLY if the breakout succeeded; after
//   the fix it is `onmouseover=&quot;alert` (entity), so the absent-substring check is precise.
```

## Implementation Blueprint

### Data models and structure

No new types. The fix operates on `font: []const u8` (already materialized at `ghostty_format.zig:840`)
and emits entities inline. No struct/option changes.

### The exact deliverable — verbatim edits

#### FILE 1: `src/ghostty_format.zig` (1 edit — the fix)

Find the unique line 841 and replace it. (Line 840 above it is UNCHANGED.)

```zig
// ---- BEFORE (exact, unique in the file — line 841) ----
                buf_writer.print("font-family: {s};", .{font}) catch return error.WriteFailed;
```
```zig
// ---- AFTER ----
                // Issue 2 (P1.M1.T2.S1): HTML-escape the font value into the double-quoted
                // style attribute. A raw " breaks out and allows attribute/event-handler
                // injection (stored-XSS) in the shared HTML (PRD §8.1 trust). Escape set
                // matches writeEscaped (render.zig). Single per-byte pass: each input byte
                // maps to one output, so no double-encoding. Default "monospace" is safe.
                buf_writer.writeAll("font-family: ") catch return error.WriteFailed;
                for (font) |c| switch (c) {
                    '"' => buf_writer.writeAll("&quot;") catch return error.WriteFailed,
                    '&' => buf_writer.writeAll("&amp;") catch return error.WriteFailed,
                    '<' => buf_writer.writeAll("&lt;") catch return error.WriteFailed,
                    '>' => buf_writer.writeAll("&gt;") catch return error.WriteFailed,
                    '\'' => buf_writer.writeAll("&#x27;") catch return error.WriteFailed,
                    else => buf_writer.writeByte(c) catch return error.WriteFailed,
                };
                buf_writer.writeAll(";") catch return error.WriteFailed;
```

#### FILE 2: `src/render.zig` (1 edit — add the test)

Add this test **immediately after** the existing `test "writeEscaped: escapes & < > \" ' and
passes through safe bytes"` block (which ends at ~line 1350 with
`try std.testing.expectEqualStrings("a&lt;b&gt;&amp;&quot;&#x27;\xc2\xa3", aw.writer.buffered());`
then `}`). Anchor on that closing, then append:

```zig
test "renderGrid escapes --font into <pre style> (Issue 2: attribute-injection XSS)" {
    // A " in the font value must NOT break out of the double-quoted style attribute.
    var aw = try std.Io.Writer.Allocating.initCapacity(std.testing.allocator, 1 << 16);
    defer aw.deinit();
    try renderGrid(
        std.testing.allocator,
        "x\n",
        .{ .cols = 1, .rows = 1 },
        palette.defaultColors(),
        null,
        "a\" onmouseover=\"alert(1)", // XSS payload
        &aw.writer,
    );
    const got = aw.writer.buffered();
    // (1) font value is HTML-entity-escaped inside the style attribute:
    try std.testing.expect(std.mem.indexOf(u8, got, "font-family: a&quot; onmouseover=&quot;alert(1);") != null);
    // (2) no raw attribute breakout: the payload never becomes a real HTML attribute:
    try std.testing.expect(std.mem.indexOf(u8, got, "onmouseover=\"alert") == null);
}
```

#### FILE 3: `docs/CONFIGURATION.md` (1 edit — font row security note)

Find the Options table row (line 45):

```markdown
| `@tmux-2html-font` | `monospace` | CSS `font-family` used in the rendered HTML. |
```
Replace with:
```markdown
| `@tmux-2html-font` | `monospace` | CSS `font-family` used in the rendered HTML. The value is HTML-escaped when emitted into the `style` attribute, so a font name containing `"` or other markup characters cannot inject attributes or scripts. |
```
(This is the font TABLE ROW — a different, non-adjacent location from the title/lang paragraph
the parallel Issue 1 task edits. No collision.)

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: EDIT src/ghostty_format.zig — escape the font-family emission (THE fix)
  - Replace line 841 (the single `buf_writer.print("font-family: {s};", .{font})`) with the
    inline per-byte escape loop above. Line 840 (const font = … orelse "monospace") UNCHANGED.
  - MATCH the file's error idiom: every write `catch return error.WriteFailed`.
  - DO NOT reuse render.zig's writeEscaped (different writer type — Gotcha 1).
  - WHY FIRST: Task 2's test exercises this emission path.

Task 2: EDIT src/render.zig — add the XSS regression test
  - Add the test verbatim above, immediately after the `test "writeEscaped: …"` block (~:1350).
  - CALL renderGrid (sibling fn, :143) with font = `a" onmouseover="alert(1)`; assert (1) the
    entity-escaped substring is present and (2) the raw breakout `onmouseover="alert` is absent.
  - NAMING: test "renderGrid escapes --font into <pre style> (Issue 2: attribute-injection XSS)".
  - PATTERN: std.Io.Writer.Allocating (mirror the writeEscaped test).
  - DEPENDENCIES: Task 1 (the fix must be in place or this test FAILS — which is the point).

Task 3: EDIT docs/CONFIGURATION.md — font row security note (Mode A)
  - Append the HTML-escaping sentence to the @tmux-2html-font table row (line 45).
  - DO NOT touch the title/lang threading paragraph (~:84-88) — that is the parallel Issue 1 task.

Task 4: VALIDATE (see Validation Loop — all verified exit 0)
  - RUN: zig build test --release=fast   → expect exit 0, ALL tests pass (incl. new test + goldens)
  - PROVE the test is a real detector: temporarily revert ONLY Task 1's edit (keep the test),
    re-run → the new test FAILS (`325/326, 1 failed`, this test named). Restore. (Proven in research.)
```

### Implementation Patterns & Key Details

```zig
// PATTERN: inline per-byte HTML escape with the file's own error idiom (NOT writeEscaped).
for (font) |c| switch (c) {
    '"'  => buf_writer.writeAll("&quot;") catch return error.WriteFailed,
    '&'  => buf_writer.writeAll("&amp;")  catch return error.WriteFailed,
    '<'  => buf_writer.writeAll("&lt;")   catch return error.WriteFailed,
    '>'  => buf_writer.writeAll("&gt;")   catch return error.WriteFailed,
    '\'' => buf_writer.writeAll("&#x27;") catch return error.WriteFailed,
    else => buf_writer.writeByte(c)       catch return error.WriteFailed,
};

// PATTERN: the regression test asserts a PRESENT escaped substring + an ABSENT raw breakout.
try std.testing.expect(std.mem.indexOf(u8, got, "font-family: a&quot; onmouseover=&quot;alert(1);") != null);
try std.testing.expect(std.mem.indexOf(u8, got, "onmouseover=\"alert") == null);  // the breakout, gone

// CRITICAL: goldens call renderDocument with font=null => "monospace" => no special chars =>
//   escaping is a no-op for them. Verified byte-equal (326/326 pass with the fix). Do NOT
//   touch golden_test.zig or testdata/*.
```

### Integration Points

```yaml
FORMATTER (ghostty_format.zig):
  - line 841 emission now escapes; line 840 default unchanged; the <pre> wrapper is project-
    specific (not upstream Ghostty) so editing it is in-scope (architecture/system_context.md §Issue 2).

TEST (render.zig):
  - new test after writeEscaped test; renderGrid is the public entry it exercises.
  - main.zig:565 `_ = @import("render.zig")` ensures render.zig tests are in the test binary.

DOCS (docs/CONFIGURATION.md):
  - @tmux-2html-font row gains a security note (no behavior change).

UPSTREAM/DOWNSTREAM (contract — do NOT re-implement):
  - cli.zig opts.font, renderGrid signature, ScreenFormatter.init(.font=…): unchanged.
  - Issue 1 (title/lang shell-escaping): parallel task P1.M1.T1.S1 — different files, no collision.
  - Issues 3 & 4 (--output mkdir; --lang "" locale): separate tasks — do not touch.

CONFIG / DATABASE / ROUTES:
  - none.
```

## Validation Loop

> PRIMARY gate: `zig build test --release=fast` → exit 0 with the new XSS test passing AND both
> goldens byte-equal. Plus the FAIL-before proof that the test actually catches the regression.

### Level 1: Syntax & Style (Immediate Feedback)

```bash
cd /home/dustin/projects/tmux-2html
# The optimized build IS the syntax/type check. Confirms the escape loop compiles (for-switch,
# writeByte on buf_writer, the new test's renderGrid call + std.mem.indexOf assertions).
zig build --release=fast 2>&1 | head -20
# Expected: success. An error naming ghostty_format.zig => typo in the escape loop (did you keep
#   line 840? is `font` still []const u8?); naming render.zig => test compile issue (renderGrid
#   arity / a missing import). Both are type-checked and unlikely given the verbatim edits.
```

### Level 2: Unit + Golden Tests (PRIMARY gate)

```bash
zig build test --release=fast
# Expected: exit 0. ALL tests pass. CRITICAL: both golden tests still pass BYTE-EQUAL (they use
#   font=null => "monospace" => no special chars => the escape is a no-op for them). The new test
#   "renderGrid escapes --font into <pre style> (Issue 2: attribute-injection XSS)" PASSES.
#
# PROOF the test is a real detector (do this once, then restore):
#   1. Temporarily revert ONLY src/ghostty_format.zig line 841 back to the raw print
#      (`buf_writer.print("font-family: {s};", .{font}) catch return error.WriteFailed;`).
#   2. Re-run `zig build test --release=fast` → expect: `run test 325/326 passed, 1 failed`,
#      the failing test named "renderGrid escapes --font into <pre style> …", exit 1.
#   3. Restore the escape loop. Re-run → 326/326, exit 0.
# (This confirms the test catches the XSS — it is not a tautology. Proven in research §4.)
```

### Level 3: Binary / End-to-End Smoke (the actual XSS is closed)

```bash
zig build --release=fast
BIN=./zig-out/bin/tmux-2html

# The PRD Issue 2 repro — AFTER the fix, the payload is entity-escaped and cannot break out:
printf 'x\n' | $BIN render --cols 3 --rows 1 --font 'a" onmouseover="alert(document.domain)' > /tmp/fx.html
grep -o 'font-family: [^;]*;' /tmp/fx.html
# Expected: font-family: a&quot; onmouseover=&quot;alert(document.domain)
grep -c 'onmouseover="alert' /tmp/fx.html   # Expected: 0  (no raw attribute breakout)
# A normal font is unaffected (escaping is a no-op for safe names):
printf 'x\n' | $BIN render --cols 3 --rows 1 --font 'Fira Code' | grep -o 'font-family: [^;]*;'
# Expected: font-family: Fira Code
```

### Level 4: Confidence checks

```bash
# Confirm goldens are byte-identical to HEAD (the fix must not change null-font output):
git stash         # set the fix aside
zig build test --release=fast >/tmp/before.txt 2>&1; echo "baseline exit: $?"
git stash pop     # restore the fix
zig build test --release=fast >/tmp/after.txt  2>&1; echo "fixed exit: $?"
diff <(grep -c 'passed' /tmp/before.txt) <(grep -c 'passed' /tmp/after.txt)  # same pass count
# (Both exit 0; the only difference is +1 test in the fixed run — the new XSS test.)

# Confirm the edit is surgical (only the 3 intended files changed):
git diff --stat
# Expected: src/ghostty_format.zig, src/render.zig, docs/CONFIGURATION.md ONLY.
```

## Final Validation Checklist

### Technical Validation

- [ ] `zig build --release=fast` succeeds (Level 1).
- [ ] `zig build test --release=fast` exits 0 (Level 2 — primary gate).
- [ ] Both golden tests pass BYTE-EQUAL (font=null ⇒ "monospace" ⇒ escape is a no-op).
- [ ] New test "renderGrid escapes --font into <pre style> (Issue 2…)" PASSES.
- [ ] Regression-detector proof: reverting line 841 makes the new test FAIL (Level 2 note).

### Feature Validation

- [ ] `render --font 'a" onmouseover="alert(1)'` → `font-family: a&quot; onmouseover=&quot;alert(1);`.
- [ ] No raw `onmouseover="alert` attribute appears in any `--font` output.
- [ ] A normal font (`Fira Code`) is byte-identical before/after (escaping is a no-op).
- [ ] `docs/CONFIGURATION.md` font row notes the HTML-escaping.

### Code Quality Validation

- [ ] Only `src/ghostty_format.zig` (line 841), `src/render.zig` (+1 test), `docs/CONFIGURATION.md`
      (font row) changed — nothing else.
- [ ] Escape set is the project's own `writeEscaped` set (`"` `&` `<` `>` `'`).
- [ ] Error idiom matches the file (`catch return error.WriteFailed`), not render.zig's `try`.
- [ ] Line 840 (`const font = … orelse "monospace"`) and the default value are UNCHANGED.

### Documentation & Deployment

- [ ] CONFIGURATION.md font row security note added (Mode A; no separate subtask).
- [ ] No new env vars / config; no help-text change.

---

## Anti-Patterns to Avoid

- ❌ Don't call `writeEscaped(buf_writer, font)` from ghostty_format.zig — it takes
  `*std.Io.Writer` and uses `try`; `buf_writer` is a fixed-buffer-stream writer handled with
  `catch return error.WriteFailed`. Inline the loop with this file's idiom (Gotcha 1).
- ❌ Don't change line 840 or the `"monospace"` default — only the emission (line 841) changes.
  The default has no special chars; escaping it uniformly is correct and keeps goldens stable.
- ❌ Don't worry about double-encoding (`&amp;lt;`) — the single per-byte pass never re-scans its
  own output (Gotcha 3).
- ❌ Don't assert "no raw `"` anywhere" in the test — the style attribute's own delimiters are
  legitimate `"`. Assert the targeted absent breakout `onmouseover="alert` (Gotcha 7).
- ❌ Don't place the test in `ghostty_format.zig` — it has no test blocks and is reached only
  transitively; `render.zig` is the proven home (main.zig:565 forces its analysis).
- ❌ Don't run plain `zig build test` (Debug) — it hits the `R_X86_64_PC64` linker bug. Use
  `--release=fast` (Gotcha 5; PRD §15; ci.yml).
- ❌ Don't touch `cli.zig`, `golden_test.zig`, `testdata/*`, `tmux-2html.tmux`, or
  `tests/plugin_options.sh` — Issue 1 (shell) is a parallel task; Issues 3/4 are separate; the
  goldens must stay byte-equal (proven).
- ❌ Don't edit the title/lang paragraph in CONFIGURATION.md (~:84-88) — that is the parallel
  Issue 1 task; edit only the font table row (line 45) to avoid a merge collision.

---

**Confidence Score: 10/10** for one-pass implementation success.

The fix is a single line → a per-byte escape loop whose escape set is copied verbatim from the
project's own `writeEscaped` (`render.zig:299`) and whose error idiom (`catch return
error.WriteFailed`) is copied from the adjacent lines (:831/:836/:842). The whole change — fix +
test — was built and run in a throwaway copy of the live repo: with the fix, **326/326 tests
pass** (incl. the new XSS test and both null-font goldens byte-equal); with the fix reverted
(test kept), **325/326 pass and the one failure is exactly this test** — so the test is a proven
regression detector, not a tautology. The non-obvious points are all handled: `buf_writer` is a
fixed-buffer-stream writer (not `std.Io.Writer`, so `writeEscaped` can't be reused directly);
`font` is already `[]const u8` at the call site; the single per-byte pass precludes
double-encoding; the default `"monospace"` is a no-op for the escaper (goldens stable); and
ReleaseFast is mandatory. The CONFIGURATION.md edit targets the font row (line 45), which does
not collide with the parallel Issue 1 task's title/lang paragraph. The implementer is pasting
exit-0-verified edits and running one command.