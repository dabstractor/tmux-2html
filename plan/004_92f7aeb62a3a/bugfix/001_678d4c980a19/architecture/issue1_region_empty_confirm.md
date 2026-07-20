# Issue 1 Architecture: Region Confirm Empty-Cell HTML Output

## Root Cause
`src/region.zig` `.confirm` arm (lines 438–506) guards only on `!ctx.sel.active()`
("was a selection *begun*?"). The comment at line 442 (`// "Empty" == no selection
begun (sel inactive)`) reveals the misreading: PRD §13 "empty/zero-cell selection"
means a selection that *renders zero non-blank cells*, not merely an inactive one.
An active selection over blank cells passes the guard and is rendered+written
unconditionally.

## The Existing Correct Pattern (render --selection)
`src/render.zig:789` — the `--selection` arm already checks emptiness:
```zig
const html = aw.writer.buffered(); // bare <pre> fragment
if (selectionBodyEmpty(html)) {
    stderr.writeAll("tmux-2html render: selection is empty\n") catch {};
    return 1;
}
```
The `selectionBodyEmpty()` helper (`render.zig:609–620`) scans the `<pre>` body
for any non-whitespace byte. It is **module-PRIVATE** (`fn`, not `pub`).

## Fix Plan

### Step 1: Make `selectionBodyEmpty` reusable
- File: `src/render.zig:609`
- Change: `fn selectionBodyEmpty` → `pub fn selectionBodyEmpty`
- The existing unit test at `render.zig:1317–1329` still passes (visibility change only)

### Step 2: Add empty guard in region.zig confirm arm
- File: `src/region.zig`
- Insertion point: after `defer allocator.free(html);` (~line 475), before `resolveOutputPath` (~line 479)
- New code:
  ```zig
  if (render.selectionBodyEmpty(html)) {
      stderr.writeAll("tmux-2html region: selection is empty\n") catch {};
      break :confirm_render 1;
  }
  ```
- This MUST break before `writeHtmlAtomic` (:487) and `writeLastOutput` (:497) so
  neither file nor sidecar is written.
- Also update the comment at line 442 to correct the misreading.

### Why `selectionBodyEmpty` works on region's full-doc HTML
In `render.run()`, the check applies to a bare `<pre>` fragment (envelope wrapping
happens after). In region, `renderSelectionHtml` returns the FULL `<!DOCTYPE…</html>`
document (envelope already wrapped via `render.writeDocumentBytes`). The §8.1 envelope
contains exactly ONE `<pre>` tag, so `selectionBodyEmpty`'s first-`<pre` scan lands on
the content `<pre>`. The malformed ⇒ non-empty fallback (`return false`) keeps it safe.

### Step 3: Integration test
Region/`renderSelectionHtml` cannot be unit-tested (Terminal + cross-test GOTCHA).
Must use python3 pty drive pattern from `tests/envelope_smoke.sh`.
Test should:
- Create isolated tmux server (`-L t2h-empty-$$`)
- Create pane with content, position cursor on a blank row
- Drive region via pty: `v` (begin selection) then `\r` (confirm) without moving cursor
- Assert: exit 1, NO output file exists, NO `.last-output` sidecar
- SKIP cleanly if `python3` absent

## Issue 3 (Sidecar Residue) — Subsumed
Issue 3 (stale `.last-output` sidecar) is fully resolved by Issue 1's fix:
the `break :confirm_render 1` fires before `writeLastOutput` (line 497), so the
sidecar is never written. The Issue 1 integration test should assert no sidecar.
**No separate implementation work needed.**