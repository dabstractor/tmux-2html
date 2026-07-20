# Codebase Findings — Plan 003 (§7.1 Status-Line Hint Sync)

## Exact current state of `renderStatus()` — `src/tui/view.zig`

### Function location

`src/tui/view.zig:226` — `pub fn renderStatus(out: *std.Io.Writer, tty_rows: u16, cols: u16, status: Status) !void`

### Current emit order (lines 228–253)

```zig
// Line 228: CUP to last row + reverse + bold
try out.print("\x1b[{d};1H\x1b[7m\x1b[1m", .{tty_rows});

// Lines 234–237: [LINE]/[BLOCK] (conditional on mode != .none)
if (status.mode != .none) {
    const tag: []const u8 = if (status.mode == .line) "LINE" else "BLOCK";
    try w.print("[{s}]  ", .{tag});
}

// Line 239: row:N col:M (1-based)
try w.print("row:{d} col:{d}", .{ status.cursor.y + 1, status.cursor.x + 1 });

// Lines 241–243: /pattern  N match(es) (conditional on pattern non-null AND non-empty)
if (status.pattern) |p| if (p.len > 0) {
    try w.print("  /{s}  {d} match(es)", .{ p, status.matches.len });
};

// Line 247: <S-sel> (conditional on has_selection) ← THE STALE TOKEN
if (status.has_selection) try w.writeAll("  <S-sel>");

// Line 249: static key hints (always shown)
try w.writeAll("  Enter=render q=quit");
```

### Required change

**Line 247** — Replace the conditional `<S-sel>` write with a **static** hint:
```zig
// REMOVE:
if (status.has_selection) try w.writeAll("  <S-sel>");

// ADD (before the existing "  Enter=render q=quit" on line 249):
try w.writeAll("  v=sel C-v=block o=swap");
```

The resulting always-shown tail becomes:
```
…  v=sel C-v=block o=swap  Enter=render q=quit
```

This matches PRD §7.1 byte-for-byte in field order.

### Doc comment — line 216

Current (line 216):
```
///   `[LINE|BLOCK]  row:N col:M  /pattern  N match(es)  <S-sel>Enter=render q=quit`
```

Required:
```
///   `[LINE|BLOCK]  row:N col:M  /pattern  N match(es)  v=sel C-v=block o=swap  Enter=render q=quit`
```

## Status struct — `src/tui/view.zig:84–91`

```zig
pub const Status = struct {
    mode: SelMode,
    cursor: Pos,
    pattern: ?[]const u8,
    matches: []const Match,
    has_selection: bool,   // ← RETAINED (delta §3 minimal recommendation)
};
```

**Decision:** Per delta §3, **retain** the `has_selection` field. It is cheap,
set by `region.zig:192` (`ctx.sel.active()`), and removing it would churn
`region.zig` and test fixtures. The `[LINE]/[BLOCK]` bracket already conveys
active-mode state. After this change, `has_selection` is set-but-not-read in
`renderStatus` — this is acceptable.

## Unit tests — `src/tui/view.zig` lines 702–800

### Test 1: `renderStatus: [LINE] full line` (line 713)
- Sets `has_selection = true`
- Asserts `"<S-sel>"` is present (line 732) ← **MUST CHANGE**
- **Required:** Assert `"v=sel C-v=block o=swap"` is present; assert `"<S-sel>"` is absent

### Test 2: `renderStatus: [BLOCK] mode + field order` (line 739)
- Sets `has_selection = false`
- Asserts `"<S-sel>"` is absent (line 754) ← **MUST CHANGE**
- **Required:** Assert `"v=sel C-v=block o=swap"` is present (new hint is always shown); assert `"<S-sel>"` is absent

### Test 3: `renderStatus: mode=.none omits the bracket` (line 758)
- Sets `has_selection = false`
- Asserts `"Enter=render q=quit"` is present (line 776) ← still valid
- **Required:** Add assertion that `"v=sel C-v=block o=swap"` is present (always shown now)

### Test 4: `renderStatus: truncates the line to cols` (line 779)
- Sets `has_selection = false`, cols=10
- Asserts `line.len <= 10` (truncation works) ← still valid
- **Required:** Confirm truncation still works with the longer static tail (the assertion is the same — `line.len <= cols` — but verify it passes with the longer hint)

## Comment update — `src/tui/select.zig:45`

Current comment references a token that will no longer exist:
```zig
/// True when a selection is active (mode != .none). Drives the Esc clear-vs-quit decision
/// in region.zig + the status line's `<S-sel>` token + `view.Status.has_selection`.
```

**Required:** Remove the `<S-sel>` token reference (it no longer exists):
```zig
/// True when a selection is active (mode != .none). Drives the Esc clear-vs-quit decision
/// in region.zig + `view.Status.has_selection` (retained for future use).
```

## Documentation — `docs/CONFIGURATION.md`

### Line 114 — status-line format example
Current:
```
[LINE|BLOCK]  row:N col:M  /pattern  N match(es)  <S-sel>  Enter=render q=quit
```
Required:
```
[LINE|BLOCK]  row:N col:M  /pattern  N match(es)  v=sel C-v=block o=swap  Enter=render q=quit
```

### Lines 122–123 — token explanations
Current:
```
- `<S-sel>` — shown only when a selection is active.
- `Enter=render q=quit` — always shown.
```
Required:
```
- `v=sel C-v=block o=swap` — always shown; press `v` to start/re-anchor a
  linewise selection, `Ctrl-v` to toggle visual block mode, `o` to swap the
  cursor to the other end of the selection (see Selection below).
- `Enter=render q=quit` — always shown.
```

### Lines 125–126 — "nothing active" example
Current:
```
For example, with nothing active the status line is just
`row:1 col:1  Enter=render q=quit`.
```
Required:
```
For example, with nothing active the status line is
`row:1 col:1  v=sel C-v=block o=swap  Enter=render q=quit`.
```

## README.md

Line 102: `"The in-app status line lists every key"` — generic, no change
needed per delta §4. The Mode B task should verify this is still accurate.

## Verification

```sh
# Build + test (must use ReleaseFast per PRD §15)
zig build --release=fast
zig build test --release=fast

# Confirm status line matches §7.1 byte-for-byte
# (verified by the updated unit tests)
```