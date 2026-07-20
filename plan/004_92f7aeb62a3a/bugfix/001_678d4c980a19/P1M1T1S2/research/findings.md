# Research Findings — P1.M1.T1.S2 (region.zig empty-selection guard in confirm arm)

> Verified by direct inspection of `src/region.zig` (HEAD) + `src/render.zig` +
> the architecture doc + the S1 PRP. No source was modified (research agent). The
> change is a 5-line control-flow insert + a comment edit; correctness is certain
> from Zig labeled-block + defer semantics (reasoned below). The build/test gate
> is the implementer's `zig build test --release=fast`.

## 1. The confirm arm structure (region.zig:438–509, verified line numbers)

```
438   .confirm => confirm_render: {
439       app.exit(state); // restore FIRST
441-444   // [COMMENT TO UPDATE — the "Empty == no selection begun" misreading]
445       if (!ctx.sel.active()) {                              // TIER 1 (existing)
446           stderr.writeAll("tmux-2html region: no selection (press v to begin, then Enter)\n") catch {};
447           break :confirm_render 1;
448       }
456       const font = ...; defer allocator.free(font);
469       const title = ...; defer allocator.free(title);
470       const lang = render.resolveLang(opts.lang);           // static-lifetime slice, no free
471       const html = renderSelectionHtml(allocator, &ctx, font, title, lang) catch { ... break :confirm_render 1; };
475       defer allocator.free(html);                           // <-- TIER 2 INSERT GOES AFTER THIS
477-478   // Output path: explicit --output wins ...
479       const path = resolveOutputPath(...) catch { ... break :confirm_render 1; };
484       defer allocator.free(path);
485       if (std.fs.path.dirname(path)) |dp| std.fs.cwd().makePath(dp) catch {};
487       writeHtmlAtomic(allocator, path, html) catch { ... break :confirm_render 1; };
...
498       writeLastOutput(bin_dir, path) catch {};              // sidecar
...
505       break :confirm_render 0;                              // success
506   },
```

## 2. The exact insert (after region.zig:475, before the output-path comment at 477)

```zig
            // PRD §13 / Issue 1: TIER 2 guard. An ACTIVE selection over blank cells
            // (a blank prompt line, trailing blank row, or empty rectangle) renders a
            // zero-non-blank-cell body. selectionBodyEmpty scans the <pre> body of the
            // full §8.1 document (the envelope has exactly one <pre>); warn + exit 1
            // BEFORE resolveOutputPath/writeHtmlAtomic/writeLastOutput so neither the
            // HTML file nor the .last-output sidecar is produced. Mirrors render.zig:788.
            if (render.selectionBodyEmpty(html)) {
                stderr.writeAll("tmux-2html region: selection is empty\n") catch {};
                break :confirm_render 1;
            }
```

- Message: `tmux-2html region: selection is empty\n` (region prefix, mirroring
  `tmux-2html render: selection is empty\n` at render.zig:789). The contract's
  wording drops the trailing `\n` in prose but the sibling emits one — match the
  sibling (newline-terminated), consistent with every other region stderr line.
- `break :confirm_render 1` (NOT `return 1`): region's confirm is a labeled block
  whose value becomes the switch-arm result (the exit code). render.zig uses
  `return 1` because `render.run` is a function; region uses `break` because the
  arm is a labeled expression block. Tier 1 (line 447) already uses this exact form.

## 3. defer semantics on the break path (no leak, confirmed)

`defer allocator.free(html)` (line 475) ALWAYS runs when the `confirm_render:`
block exits — including via `break :confirm_render 1`. So the tier-2 guard:
- frees `html` (no leak) ✓
- skips `resolveOutputPath` (479), `writeHtmlAtomic` (487), `writeLastOutput`
  (498), `spawnXdgOpen` (504) — so NO file, NO sidecar, NO browser open ✓
- yields exit code 1 (the labeled block evaluates to 1) ✓
This also resolves Issue 3 (sidecar residue) for free — the sidecar write is
after the break point, so it never runs on the empty path.

## 4. Why `selectionBodyEmpty` is correct on region's FULL-document `html`

`renderSelectionHtml` (region.zig:535) returns the FULL `<!DOCTYPE…</html>`
document: it renders the `<pre>` fragment, then wraps it via
`render.writeDocumentBytes(...)` and returns `allocator.dupe(u8, dw.writer.buffered())`
(an owned `[]u8`). `selectionBodyEmpty` (render.zig:609) finds the FIRST `<pre`,
the `>` opening it, the `</pre>` closing it, and scans that body for non-whitespace.
The §8.1 envelope (writeDocumentBytes) contains exactly ONE `<pre>` (the content
cell-grid), so the scan lands on the right body. Malformed HTML ⇒ `return false`
(non-empty fallback), so it can never false-positive into suppressing a real render.
`html` is `[]u8`, which coerces to the `[]const u8` param. ✓

## 5. The comment update (region.zig:441–444)

CURRENT (the PRD-§13 misreading to correct):
```
            // PRD 7.5: empty selection => warn, no file, exit 1. "Empty" == no selection begun
            // (sel inactive). The TUI lets Enter/y through regardless (the handler returns
            // .confirm unconditionally); THIS arm is where the empty guard lives. (`stderr` is
            // body()'s already-declared stderr writer.)
```
This conflates "inactive selection" (tier 1) with PRD §13's "renders zero
non-blank cells" (tier 2). Rewrite to state the TWO-TIER guard explicitly (see
PRP verbatim). Keep the useful note that the TUI handler returns `.confirm`
unconditionally and that `stderr` is body()'s writer.

## 6. Symbols/imports already present (no new imports needed)

- `render` alias: region.zig:41 `const render = @import("render.zig");` →
  `render.selectionBodyEmpty(html)` resolves.
- `stderr`: region.zig:292 `const stderr = std.fs.File.stderr();` in body() scope
  (a `std.fs.File`; `.writeAll(...) catch {}` is the established best-effort idiom).
- `selectionBodyEmpty`: render.zig:609 — already `pub fn` (S1 makes/has made it
  `pub`). S2 treats S1 as a contract: the symbol is cross-module-callable.

## 7. Scope boundaries (vs siblings)

- S1 (parallel): `fn selectionBodyEmpty` → `pub fn` in render.zig. S2 CONSUMES it;
  does NOT re-edit render.zig.
- S2 (THIS task): region.zig ONLY — the tier-2 guard insert + the comment fix.
  No new test in S2 (the existing `selectionBodyEmpty` unit test in render.zig
  covers the helper's logic; S3 adds the pty integration test for region).
- S3 (sibling): the python3 pty integration test (blank-cell confirm ⇒ exit 1,
  no file, no sidecar). Not in S2.
- Issue 3 (sidecar residue): fully subsumed by S2 (the break precedes writeLastOutput).

## 8. Validation gate

`zig build test --release=fast` (ReleaseFast MANDATORY — plain `zig build test`
hits the known `R_X86_64_PC64` Debug linker bug from ghostty-vt's C++ SIMD libs,
not a code error). The change is additive control-flow; it cannot regress the
existing suite (non-empty confirms have content ⇒ `selectionBodyEmpty` ⇒ false ⇒
guard does not fire ⇒ unchanged path). A full end-to-end proof of the NEW empty
path is S3's pty test; S2's gate is compile + existing tests green + a manual
reasoning check (or an optional manual repro from the bug report's steps).