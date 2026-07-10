# Design Notes — `src/tui/input.zig` (P3.M2.T1.S1)

The key-sequence decoder. Turns app.zig's typed `Event` stream into normalized `Key` values
(motion | action | search) for the motion engine (P3.M2.T1.S2). std-only + imports `app.zig`.

## 0. Where this module sits in the pipeline

```
pty bytes ──► app.readEvent (app.zig, SHIPPED) ──► Event ──► input.feed/decode (THIS) ──► Key ──► P3.M2.T1.S2 (cursor/scroll/search)
              (byte→Event: .key/.mouse/.seq/.eof)            (Event→Key: decode seqs,      (Key+count → move)
                                                                counts, gg, normalize)
```

**app.zig already does the byte→Event classification** (P3.M1.T1.S2, SHIPPED):
- `.key`  = a single non-ESC byte (printable / control / standalone Esc 0x1b)
- `.seq`  = a RAW multi-byte ESC sequence INCLUDING leading 0x1b (CSI `\x1b[..` / SS3 `\x1bO..`
            / Alt+char `\x1b<x>`) — handed UNDECODED to THIS module (the work item's "key decoder").
- `.mouse`= fully decoded MouseEvent (P3.M2.T2's job; THIS module does NOT consume mouse).
- `.eof`  = stdin closed.

So input.zig consumes `.key` + `.seq` (and tolerates `.mouse`/`.eof`); it produces `Key`.

## 1. The public API (the contract surface)

```zig
const std = @import("std");
const app = @import("app.zig"); // Event, EscSeq, Input, readEvent — all SHIPPED

/// Normalized vim motions (PRD §7.2 + decoded arrows/PgUp/Dn/Home/End/Ctrl-mods).
/// The DECODER collapses equivalent inputs to ONE variant (h≡←≡ESC[D ⇒ .down... wait .left).
/// S2 (P3.M2.T1.S2) switches on this; it owns cursor/scroll semantics.
pub const Motion = enum {
    left, right, up, down,           // h l j k / arrows
    word_fwd, word_back, word_end,   // w b e / Ctrl-Right Ctrl-Left
    line_start, first_nonblank, line_end, // 0 ^ $ / Home End
    doc_top, doc_bottom,             // gg G
    half_page_down, half_page_up,    // Ctrl-d Ctrl-u / Ctrl-Down Ctrl-Up
    page_down, page_up,              // Ctrl-f Ctrl-b / PgDn PgUp
    viewport_top, viewport_mid, viewport_bottom, // H M L
    paragraph_back, paragraph_fwd,   // { }
    match_bracket,                   // %
};

pub const Action = enum {
    visual_toggle,    // v
    visual_line,      // V
    visual_block,     // Ctrl-v (0x16) / R
    swap_end,         // o
    swap_end_other,   // O
    clear,            // Esc — handler clears selection OR quits (state-dependent; §3)
    quit,             // q / Ctrl-c
    confirm,          // Enter / y
};

pub const Search = enum {
    start_forward,    // /
    start_backward,   // ?
    next,             // n
    prev,             // N
};

pub const KeyKind = union(enum) {
    motion: Motion,
    action: Action,
    search: Search,
};

/// A fully-decoded key command. `count` is the multiplier (≥1); 1 when no digits were typed.
/// `0` as a count never occurs (leading 0 = line_start motion, not a count — §3).
pub const Key = struct {
    count: u32 = 1,
    kind: KeyKind,
};
```

**`Key.count` semantics:** `count=1` means "default (no digits) OR user typed 1" — identical for
all motions. The decoder resolves "no count" to 1 internally (keeps S2 simple: just multiply).
Count is capped to prevent u32 overflow from absurd digit streams (e.g. `99999999j`).

## 2. The Decoder state machine + the PURE/IO split (mirrors app.zig + capture.zig)

The codebase's proven convention: **PURE logic fn (fully unit-tested) + thin I/O driver + mockable
seam.** app.zig does it (`classifyEscSeq` pure + `readEvent` driver + `Input` seam). capture.zig
does it (`Runner` seam + pure argv builders + `realRun`). input.zig does the SAME:

### 2a. PURE leaf decoders (slice/byte in → classification out; fully unit-tested)

```zig
/// PURE: map a COMPLETE raw ESC sequence (INCLUDING leading 0x1b) to a Motion, or null if it
/// is not a motion this TUI recognizes (Alt+char, Insert, Delete, Shift-Tab, Shift/Alt-arrow).
/// Handles CSI (\x1b[..) + SS3 (\x1bO.) + the modifier param (1;5 = Ctrl) + ~ keys.
/// Called by feed() for .seq events. Source of every seq fact: external_keyseq_vim.md.
pub fn decodeSeq(seq: []const u8) ?Motion { ... }

/// PURE leaf classification of a single .key byte (NOT a digit, NOT 'g' — those are handled by
/// feed's state machine). Returns motion|action|search|ignore. Used by feed().
pub const ByteClass = union(enum) { motion: Motion, action: Action, search: Search, ignore };
pub fn decodeByte(b: u8) ByteClass { ... }
```

### 2b. The stateful state machine (the "count register" + g-prefix)

```zig
/// The decoder's state: the count being accumulated + a pending 'g' prefix. Reset on every
/// finalized Key. One of these lives in the EventHandler's ctx (P3.M2/P3.M3) OR is loop-local
/// in decode(driver).
pub const Decoder = struct {
    count: u32 = 0,
    has_count: bool = false,
    pending_g: bool = false,

    /// Reset after producing a Key (or on an ignored/unknown byte, which discards the count —
    /// vim semantics: an unmapped keypress clears any pending count).
    fn reset(self: *Decoder) void { self.* = .{}; }
};

/// The CORE state machine. Feed ONE Event; return a Key when a complete command is recognized,
/// or null while accumulating (digit / lone 'g') / on a non-key event (.mouse/.eof) / on an
/// ignored byte. PURE-ish (stateful but no I/O) ⇒ fully unit-testable by feeding Events directly.
/// This is what the real EventHandler (P3.M2/P3.M3) calls per event.
pub fn feed(self: *Decoder, ev: app.Event) ?Key { ... }
```

`feed` flow (the digit/`0`/`g` rules live HERE, around the leaf decoders):
```
switch (ev):
  .eof, .mouse ⇒ return null   // driver short-circuits eof; mouse is routed to select.zig by the
                               //   handler BEFORE it calls feed — feed is a no-op for mouse (robust).
  .seq ⇒ m = decodeSeq(bytes); if (m == null) { reset; return null } else finalize(.{.motion=m})
  .key ⇒ b:
    digit '1'..'9'        ⇒ count = min(count*10 + d, MAX_COUNT); has_count=true; return null
    '0' && has_count      ⇒ count = min(count*10, MAX_COUNT); return null   // extends count
    pending_g             ⇒ if (b=='g') finalize(.{.motion=.doc_top})
                            else { pending_g=false; /* fall through, re-process b normally */ }
    'g' (lower)           ⇒ pending_g=true; return null
    else                  ⇒ c = decodeByte(b);
                            if (c == .ignore) { reset; return null }   // unknown ⇒ swallow + clear count
                            finalize(c)
finalize(kind): Key{ count: if has_count then count else 1, kind }; reset; return Key
```

### 2c. The I/O driver + the EventReader seam (the literal `decode(reader) !Key`)

```zig
/// Mockable Event source — MIRRORS app.Input (ctx:*anyopaque NON-nullable + one fn) which itself
/// mirrors capture.Runner. readEvent returns a full app.Event (eof = the .eof variant, EXACTLY
/// like app.readEvent). prod impl wraps app.Input; test impl yields from a slice.
pub const EventReader = struct {
    ctx: *anyopaque,
    readEventFn: *const fn (ctx: *anyopaque) anyerror!app.Event,
    pub fn readEvent(self: EventReader) anyerror!app.Event {
        return self.readEventFn(self.ctx);
    }
};

/// The literal contract function: pull Events from `reader` until a complete Key is decoded.
/// .eof from the reader ⇒ error.EndOfStream (the region loop maps that to quit). .mouse events
/// are SKIPPED here (the canonical prod path is feed() via EventHandler, which routes mouse to
/// select.zig; decode(driver) is for the keyboard path + tests). Thin: all logic is in feed().
pub fn decode(self: *Decoder, reader: EventReader) anyerror!Key {
    while (true) {
        const ev = try reader.readEvent();
        if (ev == .eof) return error.EndOfStream;
        if (ev == .mouse) continue; // mouse routed elsewhere in the full loop; skip here
        if (try feed(self, ev)) |k| return k;
        // else: accumulating (digit/g) or ignored — keep reading
    }
}
```

> NOTE: `feed` is `?Key` (no error) so the driver wraps it in `try`? No — feed returns `?Key`
> (optional, infallible). The driver does `if (feed(self, ev)) |k| return k;` (NO try — feed is
> infallible). The `try` in the sketch is wrong; correct: `if (feed(self, ev)) |k| return k;`.
> (Confirmed: feed does no I/O, so it is infallible → optional return, no error union.)

**Why both `feed` and `decode`:** the canonical PROD path is the EventHandler (P3.M2/P3.M3) which
gets ONE event at a time from `app.runEvents` and calls `feed` (owning a `Decoder` in its ctx).
`decode(reader)` is provided to (a) satisfy the literal work-item contract `decode(reader) !Key`,
(b) be a self-contained, slice-testable end-to-end path, (c) be reusable for a keyboard-only loop.
Both share the SAME `feed` core → single source of truth for decode logic.

### 2d. Reader impls (test + prod)

```zig
// TEST — yields Events from a slice, then .eof. (FixedBufferStream-of-Events analogue.)
const SliceEventReader = struct {
    events: []const app.Event,
    idx: usize = 0,
    fn readEvent(ctx: *anyopaque) anyerror!app.Event {
        const self: *SliceEventReader = @ptrCast(@alignCast(ctx));
        if (self.idx >= self.events.len) return .eof;
        defer self.idx += 1;
        return self.events[self.idx];
    }
};

// PROD — wraps app.Input + app.readEvent. Compile-verified (real fd). region.zig may use this
// OR (canonical) drive feed() from its own EventHandler under app.runEvents.
const InputEventReader = struct {
    input: app.Input,
    fn readEvent(ctx: *anyopaque) anyerror!app.Event {
        const self: *InputEventReader = @ptrCast(@alignCast(ctx));
        return app.readEvent(self.input); // app.readEvent returns app.Event (.eof on stdin close)
    }
};
```

## 3. Key design decisions (documented; S2/region may revisit)

1. **Count = `u32`, resolved to 1 when none typed.** Simpler for S2 (multiply). `0` never appears as
   a count (leading 0 = `line_start` motion). Cap at `MAX_COUNT = 1_000_000` (absurd input ⇒ clamp,
   never overflow). The cap is a decoder concern (prevents `count*10` u32 overflow).
2. **`Esc` ⇒ `action.clear`, NOT `quit`.** Esc is state-dependent: clear an active selection, else
   quit (PRD §7.5). The DECODER is stateless about selection, so it emits `.clear`; the EventHandler
   (which knows selection state) maps `.clear` → clear-selection-or-quit. `q`/`Ctrl-c` ⇒ `.quit`
   unconditionally (app.zig's default already quits on these; the real handler does too).
3. **Ctrl-c ⇒ `quit`** (PRD §7.5: "q / Esc(no selection) / Ctrl-c → exit 1"). 0x03 maps to quit.
4. **Arrows ≡ hjkl; Ctrl-arrows ≡ word/half-page; Home/End ≡ 0/$; PgUp/Dn ≡ Ctrl-b/f.** This is the
   NORMALIZATION value of the decoder (collapse input forms to the PRD §7.2 motion set). All three
   arrow encodings (CSI `\x1b[A`, SS3 `\x1bOA`) collapse to one motion. (external_keyseq_vim.md §6.)
5. **`gg` ⇒ doc_top; the count typed before `g` carries through** (`5gg` ⇒ line 5). Lone `g` + non-g
   ⇒ cancel the prefix and re-process the byte (lone g discarded — vim's timeout behaviour).
6. **Search emits only a START key** (`/`,`?`,`n`,`N`). The PATTERN typed after `/` is collected by
   S2/region directly from the raw event stream (S2 enters a sub-mode; the decoder is idle then).
   The decoder does NOT collect patterns — it just signals search-start. (contract: "search-start".)
7. **`decodeByte` ignore ⇒ swallow + reset count** (vim: an unmapped key discards the pending count).
8. **Mouse is NOT decoded here.** feed() is a no-op for `.mouse` (the handler routes mouse to
   select.zig BEFORE calling feed). decode(driver) skips `.mouse`. (Mouse decode is app.zig's job;
   mouse→selection is P3.M2.T2.)

## 4. Scope boundaries (what THIS subtask does NOT do)

- ❌ Cursor movement / scroll math / viewport — **P3.M2.T1.S2** (and view.zig's scroll fns).
- ❌ Search scan / next-prev navigation / bracket+paragraph jumps — **P3.M2.T1.S2** (it consumes Key).
- ❌ Selection model (anchor/cursor/mode) — **P3.M2.T2.S1**.
- ❌ Mouse → selection — **P3.M2.T2** (mouse event is app.zig's; selection is P3.M2.T2's).
- ❌ The region loop wiring (enter/runEvents/confirm-render) — **P3.M3**.
- ❌ Search-pattern typing collection — **S2/region** (decoder emits start only).

THIS subtask = the decoder (types + decodeSeq + decodeByte + Decoder/feed + EventReader/decode +
tests). It must be reachable from main.zig's test block (ONE new line: `_ = @import("tui/input.zig");`).

## 5. Testing strategy (input.zig is std-only ⇒ separate test fns are SAFE — no cross-test GOTCHA)

input.zig imports ONLY `std` + `app.zig` (app.zig is std-only). NO ghostty-vt ⇒ NO Terminal.init ⇒
NO single-test-scope constraint. Every PURE fn gets its OWN `test` fn (mirrors app.zig's tests):

- `decodeSeq`: every accepted seq form (CSI+SS3 arrows, `1;5` Ctrl-mods, H/F/~ Home/End/PgUp/Dn) ⇒
  the right Motion; every rejected form (Alt+char `\x1bx`, Insert `\x1b[2~`, Delete `\x1b[3~`,
  Shift-Tab `\x1b[Z`, Shift-arrow `\x1b[1;2A`) ⇒ null.
- `decodeByte`: every motion/action/search byte ⇒ the right variant; every ignored byte ⇒ .ignore.
- `feed` (the state machine — feed app.Event values): count prefix (`5j`⇒count5/down; `10j`⇒count10;
  `0`⇒line_start no-count; `50`⇒count5 then `0`... wait `50` then a motion; `5gg`⇒count5/doc_top);
  `gg`⇒doc_top; `g`+non-g⇒cancel+reprocess; lone `g`+eof⇒null; unknown byte after count⇒swallow+reset;
  arrow seq ⇒ motion with count; `.mouse`/`.eof` ⇒ null.
- `decode(driver)` via SliceEventReader: feed a slice of Events (`{'5','j'}`⇒Key{5,down};
  `{'g','g'}`⇒doc_top; `{\x1b[A}`⇒up; slice ending ⇒ error.EndOfStream; mouse in slice ⇒ skipped).
- const/sanity: MAX_COUNT clamp; Esc⇒.clear; Ctrl-c⇒.quit.

## 6. Gotchas (codebase + Zig 0.15.2 + ghostty-vt)

- **ReleaseFast MANDATORY** for `zig build test` (Debug hits the `R_X86_64_PC64` linker bug with
  the bundled C++ SIMD libs — PRD §15). Every validation cmd uses `-Doptimize=ReleaseFast`.
- **`app.EscSeq.slice()` takes `self: *const EscSeq`** (NOT by-value) — Zig 0.15.2 miscompiles a
  by-value method returning a slice into an array field on a SSA temporary (app.zig GOTCHA). When
  calling `ev.seq.slice()`, `ev.seq` is already an lvalue in the union → fine. (Verified in app.zig.)
- **`@ptrCast(@alignCast(ctx))` for reader recovery** — `@alignCast` MANDATORY in 0.15.2
  (capture.zig:356, app.zig FdInput). The reader impl structs (SliceEventReader/InputEventReader)
  must be stack `var` so `&x` is `*T` (a const yields `*const T` which does NOT coerce — findings §2).
- **`app.Event` is a tagged union** — compare with `ev == .eof` / `ev == .mouse` (tag compare) or
  `switch (ev) { .key => |b| ..., ... }` (payload capture). `ev.seq` is the EscSeq payload.
- **Digit `0x30`-`0x39`** = '0'-'9'; digit value = `b - 0x30`. '0' as motion = `b == 0x30`.
- **Don't import ghostty-vt.** input.zig is std + app only (keeps it test-safe as separate fns).
- **main.zig test block** needs ONE new line: `_ = @import("tui/input.zig");` (after the view.zig
  import). NO other main.zig change; NO build.zig/build.zig.zon change; NO new deps.
- **No allocation needed.** The decoder is stack-only (fixed EscSeq buffer is in app.Event already;
  decodeSeq/decodeByte/feed/decode allocate nothing). Tests use no allocator (except none). Clean.
