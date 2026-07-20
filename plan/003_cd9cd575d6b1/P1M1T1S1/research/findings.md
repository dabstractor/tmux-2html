# Research Findings — P1.M1.T1.S1 (status-line hint: `<S-sel>` → `v=sel C-v=block o=swap`)

> Every before/after snippet below was read directly from the live source
> (2026-07-19) and is byte-accurate. The validation gate `zig build test
> --release=fast` was run on the current baseline → EXIT 0.

## 1. Inventory: ALL 10 `<S-sel>` occurrences in the repo (grep-confirmed, no others)

```
src/tui/view.zig:216   doc comment           `<S-sel>Enter=render q=quit`
src/tui/view.zig:246   inline comment        // <S-sel> (only when a selection is active)
src/tui/view.zig:247   THE CODE CHANGE       if (status.has_selection) try w.writeAll("  <S-sel>");
src/tui/view.zig:731   test-1 comment        // <S-sel> shown (has_selection).
src/tui/view.zig:732   test-1 assertion      ...indexOf(u8, out, "<S-sel>") != null);
src/tui/view.zig:752   test-2 comment        // ...; no selection ⇒ no <S-sel>.
src/tui/view.zig:754   test-2 assertion      ...indexOf(u8, out, "<S-sel>") == null);
src/tui/select.zig:45  comment               ...the status line's `<S-sel>` token +...
docs/CONFIGURATION.md:114   format example   ...  <S-sel>  Enter=render q=quit
docs/CONFIGURATION.md:122   bullet           - `<S-sel>` — shown only when...
```
No `<S-sel>` in README.md, region.zig, or elsewhere. The contract's list is COMPLETE.

## 2. The core code change (view.zig:246–249) — exact current text

```zig
    // <S-sel> (only when a selection is active)
    if (status.has_selection) try w.writeAll("  <S-sel>");
    // static key hints (always shown)
    try w.writeAll("  Enter=render q=quit");
```
After:
```zig
    // static key hints (always shown; v/Ctrl-v/o mirror §7.4 selection keys)
    try w.writeAll("  v=sel C-v=block o=swap");
    try w.writeAll("  Enter=render q=quit");
```
(Removes the conditional + its comment; adds one unconditional writeAll. The
`// static key hints` comment can stay or be lightly updated — either is fine.)

## 3. Doc comment (view.zig:216) — exact current text

```
///   `[LINE|BLOCK]  row:N col:M  /pattern  N match(es)  <S-sel>Enter=render q=quit`
```
After (note: 2 spaces before Enter, matching codebase token convention):
```
///   `[LINE|BLOCK]  row:N col:M  /pattern  N match(es)  v=sel C-v=block o=swap  Enter=render q=quit`
```

## 4. SPACE CONVENTION (minor but byte-relevant)

The PRD §7.1 markdown renders `o=swap Enter=render` with ONE space. But the
codebase emits every token with a 2-space prefix (`"  v=sel..."`, `"  Enter..."`)
⇒ the actual output has TWO spaces between `o=swap` and `Enter`. The contract +
codebase_findings.md both specify the 2-space form (`o=swap  Enter=render`),
calling it "§7.1 byte-for-byte". FOLLOW THE 2-SPACE FORM (contract/codebase
convention) — the PRD's single space is typographic compression in markdown.

## 5. Status struct (view.zig:84–91) — UNCHANGED

`has_selection: bool` is RETAINED (set by region.zig:192 from `ctx.sel.active()`)
but no longer READ by renderStatus after this change. Acceptable per delta §3
(removing it would churn region.zig + fixtures). SelMode enum + other fields
unchanged. NO struct edit.

## 6. Test changes (view.zig ~713–790) — exact current assertions + required edits

- **Test 1** "renderStatus: [LINE] full line …" (has_selection=true):
  - L730 `    // <S-sel> shown (has_selection).`
  - L732 `    try std.testing.expect(std.mem.indexOf(u8, out, "<S-sel>") != null);`
  - → change to: assert `"v=sel C-v=block o=swap"` PRESENT and `"<S-sel>"` ABSENT.
- **Test 2** "renderStatus: [BLOCK] mode + field order" (has_selection=false):
  - L752 `    // empty pattern ⇒ no search token; no selection ⇒ no <S-sel>.`
  - L754 `    try std.testing.expect(std.mem.indexOf(u8, out, "<S-sel>") == null);`
  - → change to: assert `"v=sel C-v=block o=swap"` PRESENT (now unconditional);
    keep `"<S-sel>"` ABSENT.
- **Test 3** "renderStatus: mode=.none omits the bracket …" (has_selection=false):
  - L775 `    // static hints still present.`
  - L776 `    try std.testing.expect(std.mem.indexOf(u8, out, "Enter=render q=quit") != null);`
  - → ADD: `try std.testing.expect(std.mem.indexOf(u8, out, "v=sel C-v=block o=swap") != null);`
- **Test 4** "renderStatus: truncates the line to cols" (cols=10): NO assertion
  change. Verified: line is already >10 chars before the static tail (pattern is
  long), so truncation to cols=10 cuts at `row:1 col:` regardless of the new hint.
  Assertion `line.len <= 10` still holds.

## 7. select.zig:43–45 comment — exact current text

```zig
    /// True when a selection is active (mode != .none). Drives the Esc clear-vs-quit decision
    /// in region.zig + the status line's `<S-sel>` token + `view.Status.has_selection`.
```
After:
```zig
    /// True when a selection is active (mode != .none). Drives the Esc clear-vs-quit decision
    /// in region.zig + `view.Status.has_selection` (retained for future use).
```

## 8. docs/CONFIGURATION.md — exact current text (lines 114, 122–123, 125–126)

- L114: `[LINE|BLOCK]  row:N col:M  /pattern  N match(es)  <S-sel>  Enter=render q=quit`
- L122: `- `<S-sel>` — shown only when a selection is active.`
- L123: `- `Enter=render q=quit` — always shown.`
- L125–126: `For example, with nothing active the status line is just\n`row:1 col:1  Enter=render q=quit`.`
- (The §7.4 keybinding table ~L166 is ALREADY current — do NOT touch.)

## 9. Validation gate (verified on baseline)

```
zig build test --release=fast   # EXIT 0 on baseline (and required — Debug hits R_X86_64_PC64 linker bug, PRD §15)
zig build --release=fast        # clean build check
```
No tmux, no shim, no logs — this is a pure in-memory string-format change + tests.
check-safety.sh is irrelevant here (no shell changes) but would stay green.