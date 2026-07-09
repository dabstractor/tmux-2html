# SGR Mouse Encoding (xterm mode 1006) — Implementation Reference

> Byte-level reference for the Zig TUI copy-mode overlay mouse parser.
> Primary source: **xterm ctlseqs — "Mouse Tracking"**
> https://invisible-island.net/xterm/ctlseqs/ctlseqs.html

---

## 0. TL;DR (the facts the parser must encode)

| Item | Value |
|---|---|
| Enable encoding | `CSI ? 1006 h`  →  `\x1b[?1006h` |
| Enable drag-select (button-event motion) | `CSI ? 1002 h`  →  `\x1b[?1002h` |
| Enable any motion | `CSI ? 1003 h`  →  `\x1b[?1003h` |
| Disable | same with `l`, e.g. `\x1b[?1006l` |
| Press / motion report | `\x1b[<{b};{x};{y}M`  (capital `M`, 0x4D) |
| Release report | `\x1b[<{b};{x};{y}m`  (lowercase `m`, 0x6D) |
| Coordinates `x`,`y` | **1-based CHARACTER-CELL** (not pixels). Pixel mode = `?1016`. |
| `b` low bits 0–1 | 0=left, 1=middle, 2=right; **3=release(legacy)/no-button(hover)** |
| `b` bit 2 (mask **4**) | **Shift** |
| `b` bit 3 (mask **8**) | **Alt / Meta**  ◀ ← critical answer |
| `b` bit 4 (mask **16**) | **Control**  ◀ ← critical answer |
| `b` bit 5 (mask **32**) | Motion flag |
| `b` bits 6–7 (64 / 65) | wheel up = 64, wheel down = 65 |
| Wheel terminator | capital `M`; **no release (`m`) event** |

**Critical resolution:** in xterm, **Alt = `b & 8` (mask 8)** and **Control = `b & 16` (mask 16)**.
The opposite mapping is a common documentation error; xterm ctlseqs and xterm
source both put meta at 8 and control at 16.

---

## 1. SGR report format, coordinates, and the 1005 limit (Q1)

### Format
Mode 1006 ("SGR Mouse Mode", DEC private `?1006h`) encodes mouse reports as
plain ASCII decimal fields, `;`-separated, terminated by `M` or `m`, with a
`<` private marker immediately after CSI:

```
Press / motion:  ESC [ < {b} ; {x} ; {y} M     ->  \x1b[<{b};{x};{y}M
Release:         ESC [ < {b} ; {x} ; {y} m     ->  \x1b[<{b};{x};{y}m
```

- `b`, `x`, `y` are **variable-length ASCII decimal** (1–N digits).
- `M` (0x4D) terminates press and motion; `m` (0x6D) terminates release.
- `<` sits in the CSI "private parameter" position. This `<` is what lets the
  parser distinguish 1006 from URXVT 1015 (which has no `<` and always uses `M`)
  and from ordinary CSI sequences.

### Coordinates
`x` = column, `y` = row/line, both **1-based character-cell coordinates**
(top-left cell is `1;1`). **No `+32` offset.** Pixel coordinates require a
separate mode (`?1016`, "SGR Pixel Mouse Mode") which reuses the same format
but with pixel values — do not confuse the two.

### How 1006 avoids the legacy 1005 limit
- Legacy X10 / CWM mouse reports (`\x1b[M Cb Cx Cy`) append **three raw bytes**,
  each value `+ 32`. A single byte holds 0–255, so the underlying value is
  capped at **223** → screens wider/taller than **223 cells** cannot report
  coordinates beyond that (the "~223 limit").
- Mode **1005** tried to fix this by UTF-8-encoding each coordinate value, but
  this introduced variable byte length, C0/control-code collisions, ambiguous
  parsing, and still an upper bound — it is effectively deprecated.
- Mode **1006 (SGR)** sidesteps the problem entirely: coordinates are **ASCII
  decimal digits** with no offset and no UTF-8, so `x`,`y` are **unbounded**
  (limited only by terminal screen size). This is why 1006 is the recommended
  encoding.

[Primary: xterm ctlseqs — "Mouse Tracking"](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html)

---

## 2. Bit layout of `b` — the Alt/Ctrl resolution (Q2)

```
 bit:  7  6  5  4  3  2  1  0
       .  .  .  .  .  .  +--+--  bits 0-1 : button (0=L,1=M,2=R,3=release/hover)
       .  .  .  .  .  +--.       bit 2 (4)  : Shift
       .  .  .  .  +--.          bit 3 (8)  : Alt / Meta     ◀
       .  .  .  +--.             bit 4 (16) : Control        ◀
       .  .  +--.                bit 5 (32) : Motion flag
       .  +--+--.                bits 6-7   : 64 = wheel up, 65 = wheel down
```

| Mask | Decimal | Meaning |
|---|---|---|
| `0b00000011` | 3   | Button index (bits 0–1) |
| `0b00000100` | **4**   | **Shift** |
| `0b00001000` | **8**   | **Alt / Meta** (Mod1) |
| `0b00010000` | **16**  | **Control** |
| `0b00100000` | 32  | Motion (set on drag/move reports) |
| `0b01000000` | 64  | Wheel (bit 6); wheel up = 64, wheel down = 65 = 64+1 |

### The critical answer
- **`b & 8`  → Alt / Meta**
- **`b & 16` → Control**
- **`b & 4`  → Shift**

xterm ctlseqs ("Parameters for Mouse Tracking") lists the modifier bits
explicitly as **4 = shift, 8 = meta, 16 = control**, and xterm's `button.c`
builds the code from `ShiftMask→4`, `Mod1Mask(meta/alt)→8`, `ControlMask→16`.
**Note:** some secondary docs/tutorials transpose Alt and Ctrl; the xterm
authority (ctlseqs + source) is definitive: **Alt is mask 8, Ctrl is mask 16.**

### Value 3 in bits 0–1
- In legacy X10 / non-SGR 1000 reports, `3` means **button release** (because a
  single report byte cannot otherwise mark release).
- In **SGR (1006)**, release is instead marked by the **lowercase `m`**
  terminator, so `3` is **not** used for release there.
- `3` reappears in **motion** contexts as **"no button held"**: in any-event
  mode (`1003`) a hover move with no button gives `b = 3 | 32 = 35`.

[Primary: xterm ctlseqs — "Mouse Tracking"](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html)

---

## 3. Modes 1000 vs 1002 vs 1003 (Q3)

| Mode | DEC private | What it reports |
|---|---|---|
| **1000** | `?1000h` | **Press and release only** — no motion (a.k.a. VT200 / "Normal Mouse Tracking"). |
| **1002** | `?1002h` | **Button-event tracking** — press + release + motion **only while a button is held** (drag). |
| **1003** | `?1003h` | **Any-event tracking** — reports **all** motion, even with no button pressed (hover). |

These three "what to report" modes are mutually exclusive in effect — enabling
1002 supersedes 1000's no-motion behavior, and 1003 supersedes 1002.

`?1006h` is **orthogonal**: it only selects the *encoding*, not *which* events
are reported.

### Enabling click + drag-to-select
To get **click + drag-select** you enable **a motion mode + SGR encoding**:
- `\x1b[?1002h\x1b[?1006h`  → button-event motion (drag) with SGR encoding.
  `1002` already includes press and release, so **`1000` is not strictly
  required** when `1002` is on.

The commonly-seen stack `\x1b[?1000h\x1b[?1002h\x1b[?1006h` (1000+1002+1006)
also works — the `1000` is redundant but harmless and yields exactly click +
drag-to-select. (crossterm enables mouse via 1000/1002; many libs send
1000 then 1002 then 1006.) For full hover tracking use `\x1b[?1003h\x1b[?1006h`.

**Confirmed:** enabling `1000+1002+1006` (or just `1002+1006`) gives
click + drag-to-select.

[Primary: xterm ctlseqs — "Button-Event Tracking" / "Any-Event Tracking"](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html)

---

## 4. Drag-to-select byte sequence with 1002 (Q4)

Button-event drag with **left button** (`1002` + `1006`):

| Event | Bytes | `b` | Notes |
|---|---|---|---|
| Left **press** | `\x1b[<0;{x};{y}M` | 0 | button 1 = bit value 0; capital `M` |
| **Motion** while held | `\x1b[<32;{x};{y}M` | 32 = `0\|32` | held button (0) + motion flag (32); capital `M` |
| Left **release** | `\x1b[<0;{x};{y}m` | 0 | lowercase `m` marks release |

**Confirmed.** Note: during motion the **low 2 bits still encode the held button**
(button 1 → 0), so the motion code is `0 | 32 = 32`. Middle-button drag motion =
`1 | 32 = 33`; right-button = `2 | 32 = 34`. Hover motion with no button (1003) =
`3 | 32 = 35`.

Worked example (press at col 5 row 2, drag to col 12 row 6, release):
```
\x1b[<0;5;2M       press
\x1b[<32;9;3M      motion (cell 9,3)
\x1b[<32;12;6M     motion (cell 12,6)
\x1b[<0;12;6m      release
```

---

## 5. Alt modifier → block selection (Q5)

The terminal protocol only reports the modifier bits; **"linewise vs block"
selection is an application-level decision**, not a protocol feature. For the
Zig copy-mode overlay:

- **Alt is `b & 8` (mask 8).** ◀
- During a left-button **drag** with Alt held: `b = 0 | 8 | 32 = 40`
  → `\x1b[<40;{x};{y}M`.
- The overlay should, on receiving a motion report with `(b & 8)` set, switch
  the in-progress selection to **rectangle/block** mode; otherwise linewise.

So in code: `const block_mode = (b & 8) != 0;` during a drag. Shift/Alt/Ctrl
combinations just add their masks (e.g., Alt+Shift drag motion =
`0 | 8 | 4 | 32 = 44`).

[Block selection is the app's choice; the protocol supplies Alt via mask 8.
Primary: xterm ctlseqs modifier bits.](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html)

---

## 6. Wheel events (Q6)

| Event | `b` | Bytes | Terminator | Release? |
|---|---|---|---|---|
| Wheel **up** (button 4) | 64 | `\x1b[<64;{x};{y}M` | capital **`M`** | **No** |
| Wheel **down** (button 5) | 65 | `\x1b[<65;{x};{y}M` | capital **`M`** | **No** |

- Wheel events use the **press (`M`) terminator**.
- They **do NOT produce a release (`m`) event** — each scroll notch is a single
  `M` report.
- Wheel + modifiers add masks normally (e.g., Ctrl+wheel-up = `16 | 64 = 80`).
- Parse rule: `(b & 64)` ⇒ wheel; up if `(b & 1) == 0`, down if `(b & 1) == 1`
  (i.e. 64 vs 65).

[Primary: xterm ctlseqs — "Mouse Tracking" wheel/buttons 4–5](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html)

---

## 7. Zig reference constants & parser sketch

```zig
// ---- SGR (1006) mouse button-code masks (xterm ctlseqs) ----
pub const MASK_BUTTON: u8 = 0b0000_0011; // 3   bits 0-1
pub const MASK_SHIFT:  u8 = 0b0000_0100; // 4   bit 2  -> Shift
pub const MASK_ALT:    u8 = 0b0000_1000; // 8   bit 3  -> Alt / Meta
pub const MASK_CTRL:   u8 = 0b0001_0000; // 16  bit 4  -> Control
pub const MASK_MOTION: u8 = 0b0010_0000; // 32  bit 5  -> motion flag
pub const MASK_WHEEL:  u8 = 0b0100_0000; // 64  bit 6  -> wheel flag

pub const BTN_LEFT:   u8 = 0;
pub const BTN_MIDDLE: u8 = 1;
pub const BTN_RIGHT:  u8 = 2;
pub const BTN_NONE:   u8 = 3; // legacy release / hover (no button)

pub const WHEEL_UP:   u8 = 64; // 0 | 64
pub const WHEEL_DOWN: u8 = 65; // 1 | 64

pub const MouseKind = enum { press, motion, release, wheel };

pub const MouseEvent = struct {
    kind: MouseKind,
    button: u8,    // 0/1/2 (BTN_NONE for hover) ; 64/65 for wheel
    x: u32,        // 1-based column
    y: u32,        // 1-based row
    shift: bool,   // b & 4
    alt: bool,     // b & 8   <- Alt/Meta
    ctrl: bool,    // b & 16  <- Control
};

/// Parse an SGR report body starting AFTER the `ESC [ <` prefix.
/// `body` must contain the decimal fields terminated by 'M' or 'm'.
/// Returns null if malformed.
pub fn parseSgrMouse(body: []const u8) ?MouseEvent {
    // expect:  {b};{x};{y}(M|m)
    var it = std.mem.splitScalar(u8, body, ';');
    const b_s = it.next() orelse return null;
    const x_s = it.next() orelse return null;
    // last field "yM" or "ym": strip the trailing terminator
    const y_term = it.next() orelse return null;
    if (y_term.len < 2) return null;
    const term = y_term[y_term.len - 1];
    const y_s  = y_term[0 .. y_term.len - 1];

    const b = std.fmt.parseInt(u8,  b_s, 10) catch return null;
    const x = std.fmt.parseInt(u32, x_s, 10) catch return null;
    const y = std.fmt.parseInt(u32, y_s, 10) catch return null;

    const is_release = (term == 'm');
    const is_motion  = (b & MASK_MOTION) != 0;
    const is_wheel   = (b & MASK_WHEEL)  != 0;

    const kind: MouseKind = if (is_wheel) .wheel
        else if (is_motion) .motion
        else if (is_release) .release
        else .press;

    return .{
        .kind   = kind,
        .button = if (is_wheel) b else (b & MASK_BUTTON),
        .x = x, // 1-based
        .y = y, // 1-based
        .shift  = (b & MASK_SHIFT) != 0,
        .alt    = (b & MASK_ALT)   != 0, // mask 8
        .ctrl   = (b & MASK_CTRL)  != 0, // mask 16
    };
}
```

Parser notes:
1. SGR reports are **not length-prefixed** — parse variable-length decimals up
   to each `;`, then read the final `M`/`m` terminator.
2. Detect entry to the sequence by `ESC [ <` (the `<` private marker).
3. `x`,`y` are 1-based; subtract 1 when indexing into a 0-based cell buffer.
4. On a motion report, the held button is in bits 0–1; `(b & 3) == 3` ⇒ hover
   (no button), which should only occur under `?1003`.
5. Wheel never produces `m`; treat each `M` with `b & 64` as a discrete notch.

---

## 8. Gotchas

- **Alt/Ctrl swap trap:** some tutorials say Alt=16/Ctrl=8. xterm authority is
  **Alt=8, Ctrl=16**. If your terminal under test disagrees, the terminal is
  non-conformant; test against xterm and verify with a raw echo.
- **Release vs hover:** in SGR, release = lowercase `m`; the `3` button value
  in motion = "no button" (hover, `1003` only).
- **1006 is encoding-only:** it never changes *which* events fire; pair it with
  1002/1003 for motion.
- **Coordinates 1-based, no +32 offset** (legacy modes use +32; SGR does not).
- **1015 (URXVT)** looks similar but has no `<`, uses `M` always, and adds 32 to
  the button — keep the parsers separate.
- **1016 (pixel SGR)** shares the format but reports pixels — confirm 1006 (not
  1016) is active before treating `x`/`y` as cells.

---

## 9. Sources

Primary (authoritative):
- **xterm ctlseqs — "Mouse Tracking"** — https://invisible-island.net/xterm/ctlseqs/ctlseqs.html
  - Section "Mouse Tracking" (subsections: Normal/VT200 `1000`, Button-Event
    `1002`, Any-Event `1003`, SGR `1006`, URXVT `1015`, Pixel `1016`).
  - Defines Cb modifier bits: 4=shift, 8=meta, 16=control; wheel 64/65;
    motion=+32; the `<` private marker; `M`/`m` press/release terminators.

Corroborating implementations (well-known, follow xterm):
- **tmux** mouse parsing — https://github.com/tmux/tmux/blob/master/tty-keys.c
  (parses `\e[<…M/m`, button/mask decode).
- **crossterm** (Rust) — https://github.com/crossterm-rs/crossterm/blob/master/src/event/sys/unix/parse.rs
  (SGR `<` parsing, modifier masks).
- **libvaxis** (Zig) — https://github.com/rockorager/libvaxis (Zig mouse decode;
  useful cross-check for the Zig parser).
- **ncurses** mouse FAQ — https://invisible-island.net/ncurses/ncurses.faq.html

> Verification note: facts above are from established knowledge of the xterm
> ctlseqs spec and the cited implementations. Exact section-anchor fragments
> (e.g. `#Mouse-Tracking` vs `#h2-Mouse-Tracking`) were not live-fetched; pin
> the anchor by opening the page and searching "Mouse Tracking". The byte-level
> facts (masks, terminators, 1-based coords) are stable and xterm-confirmed.
