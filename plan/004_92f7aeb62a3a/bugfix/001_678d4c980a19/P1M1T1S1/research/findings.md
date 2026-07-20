# Research Findings — P1.M1.T1.S1 (make `selectionBodyEmpty` pub)

> Tiny, surgical task (0.5 pts). Verified directly against the live source;
> baseline test gate run green.

## 1. The one edit (src/render.zig:609)

Current declaration (line 609) — module-private `fn`:
```zig
fn selectionBodyEmpty(html: []const u8) bool {
```
→ change to `pub fn` (visibility only; body untouched):
```zig
pub fn selectionBodyEmpty(html: []const u8) bool {
```

## 2. Why it's safe (nothing else changes)

- **Same-module caller stays identical**: `render.zig:789` `if (selectionBodyEmpty(html)) {`
  (the `--selection` arm). A `pub fn` is callable within its own module exactly as `fn` is;
  no call-site edit needed.
- **Unit test stays identical**: `render.zig:1317` `test "selectionBodyEmpty: blank body => true; content => false"`
  (5 assertions, lines 1317–1328). Visibility does not affect the test.
- **No region.zig caller yet**: `grep -c selectionBodyEmpty src/region.zig` = 0. S1 is the
  *enabling* change; **S2** (the sibling task) adds the first cross-module call in
  `region.zig`'s confirm arm. So S1 alone changes behavior for nobody — it only *unlocks*
  the symbol for S2.

## 3. The function (for reference — DO NOT change)

`selectionBodyEmpty(html)`: scans the body between the first `<pre` opening `>` and the next
`</pre>` for any non-whitespace byte. Returns **true** if empty/all-whitespace; **false**
otherwise (including malformed HTML with no `<pre`/`>`/`</pre>` → safe non-empty fallback).
Backed by PRD §13 ("empty/zero-cell selection ⇒ warn, no file, exit 1"). Used by the
`render --selection` path already; S2 will reuse it for the region confirm path.

## 4. Scope boundary

- **S1 (this task):** the `fn` → `pub fn` keyword change ONLY. No body/algorithm/caller/test change.
- **S2 (sibling):** add the empty-selection guard in `region.zig`'s `.confirm =>` arm —
  calls `render.selectionBodyEmpty(fragment)`, and if true prints `tmux-2html region:
  selection is empty` to stderr + exits 1 before writing the file/sidecar.
- **S3 (sibling):** the python3 pty integration test that drives a blank-cell region confirm.
- S1 does NOT touch region.zig, capture.zig, tui/*, or any test.

## 5. Validation gate (verified on baseline)

```
zig build test --release=fast   # EXIT 0 on baseline (ReleaseFast MANDATORY — Debug hits R_X86_64_PC64 linker bug, PRD §15)
zig build --release=fast        # clean build (compile-checks the pub symbol exports)
```
Note: S1 alone adds no new caller, so the only observable effect is that the symbol becomes
exported (S2's `render.selectionBodyEmpty(...)` call will then compile). The baseline test
suite is the regression guard (the existing selectionBodyEmpty unit test stays green).