# Research findings — P1.M1.T1.S3 (`render.run` wires resolved title + lang into `DocumentOpts`)

Scope: the single `DocumentOpts{...}` construction inside `render.run`. Confirmed
against the working tree where **S1 (Complete) and S2 (implemented in file) are both
present**.

## 1. The exact edit site (anchor drift 636 → 729)

The item description cites `render.zig:636`, but that was written against pre-S2 HEAD.
S2 inserted the lang-resolution block (~120 lines: 4 fns + ~26 unit tests) AFTER
`DocumentOpts` (now :187–192). The `run` function's doc construction therefore moved
down to **line 729**.

`src/render.zig:729` (verified unique in the file):
```zig
const doc = DocumentOpts{ .title = "tmux-2html", .background = colors.background };
```
This is the ONLY `DocumentOpts{...}` literal inside `run`. (Line 885 is in the pane
dispatcher in `main.zig`-adjacent code; line 954 is a test — neither is S3's concern.)

## 2. The four arms all reuse `doc` (no per-arm change needed)

`run` (start: `pub fn run` at `render.zig:708`) computes `doc` ONCE at :729, then:

| Arm | condition | consumes `doc` via |
|-----|-----------|--------------------|
| `--selection` | `if (opts.selection)` | `writeDocFileAtomic(…, doc, html)` / `writeDocumentBytes(…, doc, html)` |
| `--output` | `if (opts.output)` | `renderToFileAtomic(…, opts.font, doc)` |
| `--open` (no output) | `else if (opts.open)` | `renderToFileAtomic(…, opts.font, doc)` |
| stdout | `else` | `renderDocument(…, opts.font, doc, &fw.interface)` |

=> Editing the single `const doc = …` line propagates title+lang to ALL four arms.
   "No other change — the four arms already use `doc`." (contract §3)

## 3. Input contract — types match exactly (no conversion)

- `cli.RenderOpts` (`src/cli.zig:59`) has, from S1:
  - `title: ?[]const u8 = null` (cli.zig:67)
  - `lang: ?[]const u8 = null`  (cli.zig:68)
  - parsed by `parseRender` (`--title`/`--lang` branches cli.zig:180–183)
- S2 provides `pub fn resolveLang(explicit: ?[]const u8) []const u8` (render.zig:281).
- `opts.lang` is `?[]const u8`; `resolveLang` takes `?[]const u8` → **pass directly**.
- `opts.title` is `?[]const u8`; `orelse "tmux-2html"` yields `[]const u8` for `DocumentOpts.title`.

## 4. Envelope emission already wired (writeDocument)

`writeDocument` (`render.zig:310`) emits:
- `<html lang="` + `writeEscaped(out, doc.lang)` + `">`  (:317–318)
- `<title>` + `writeEscaped(out, doc.title)` + `</title>` (:321–323)

=> Setting `doc.title` / `doc.lang` is the COMPLETE behavior. title is HTML-escaped
   (so `--title "a < b"` is safe); lang is escaped too.

## 5. CRITICAL INVARIANT — goldens cannot change

`src/golden_test.zig` builds its OWN `DocumentOpts` literals and calls
`render.renderDocument(...)` DIRECTLY (golden_test.zig:22 & :57; doc literals at :29 & :64):
```zig
.{ .title = "tmux-2html", .background = palette.defaultColors().background }
```
- It NEVER calls `render.run`.
- Its doc literal omits `.lang` ⇒ defaults to `"en"` (DocumentOpts.lang default).
- Therefore S3's edit to `run` is **provably invisible to the golden suite**.
- Verification: `zig build test -Doptimize=ReleaseFast` → both golden tests still byte-equal.

## 6. No existing test exercises `run` (no regression surface)

grep for `.run(` / `render.run` across `src/`:
- `cli.zig:405` — `render_mod.run(allocator, opts)` is the CLI dispatch entry (prod, not test).
- All other `.run(` hits are `runner.run` / `std.process.Child.run` (capture.zig, main.zig) — unrelated.

=> The codebase deliberately does NOT unit-test `run` (it does I/O: stdin read, file
   write, xdg-open spawn). The tested layer is the pure primitives: `renderGrid`,
   `writeDocument`, `writeDocumentBytes`, `renderDocument`. Formal `--title`/`--lang`
   OUTPUT assertion tests are owned by **P1.M1.T3.S1** (the validation task). S3's
   validation is a binary smoke check (Level 3) + the golden-unchanged proof.

## 7. `bcp47_buf` lifetime is safe across the doc construction

`resolveLang` returns a slice into the module-level `bcp47_buf` (`render.zig:203`) OR
the string literal `"en"`. `doc.lang` holds that slice. Between the `resolveLang(opts.lang)`
call and `doc.lang` being consumed (in `writeDocument`, via whichever arm runs), NOTHING
re-invokes `toBcp47`/`resolveLang`/`langFromEnv`:
- `renderGrid`, `renderDocument`, `renderToFileAtomic`, `writeDocumentBytes`,
  `writeDocFileAtomic` — none reference `bcp47_buf` (grep-confirmed; only `toBcp47` and
  `langFromEnvStrings` write it, plus the S2 unit tests).
- `palette.resolve` (line 718) is a DIFFERENT resolve; doesn't touch `bcp47_buf`.

=> This is exactly S2 PRP Gotcha 2's safety condition ("called ONCE per render; result
   consumed during that single writeDocument; no aliasing"). The slice is stable. No alloc,
   no free needed (`[]const u8` into static/rodata memory).

## 8. The exact change (1 line → 3 lines)

```zig
// render.zig:729  BEFORE:
const doc = DocumentOpts{ .title = "tmux-2html", .background = colors.background };

// AFTER:
const title = opts.title orelse "tmux-2html";
const lang = resolveLang(opts.lang);
const doc = DocumentOpts{ .title = title, .lang = lang, .background = colors.background };
```

`opts` is the `cli.RenderOpts` parameter of `run` (already in scope). `resolveLang` is
in the SAME file (`render.zig`) → no import. Placement: immediately after
`const colors = palette.resolve(...)` / `determineCols` / `lineCount` block, exactly where
the old `const doc = …` sat (now :729). The `const stderr = …` line at :727 stays.

## 9. Build/test gotcha (mandatory)

`zig build test` (Debug) FAILS with an unrelated Zig 0.15.2 linker bug
(`R_X86_64_PC64` from ghostty-vt's bundled C++ SIMD libs). Always validate with:
```
zig build test -Doptimize=ReleaseFast
```
(Confirmed in plan/001 findings_and_corrections.md §4, PRD §15, S1 & S2 PRPs.)
```
zig build --release=fast
```
builds the optimized binary used for the Level 3 smoke checks.
