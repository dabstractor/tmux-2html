# External Research — Key-Sequence Decoding + Vim Count Semantics

For `src/tui/input.zig` (P3.M2.T1.S1). All facts pinned to authoritative sources with URLs.
Goal: a Zig decoder that turns app.zig's `Event` stream (`.key` / `.seq` / `.eof`) into a
normalized `Key{count, motion|action|search}` for the motion engine (P3.M2.T1.S2).

---

## 1. CSI / SS3 structure grammar (how to slice an ESC sequence)

A control sequence (CSI = Control Sequence Introducer) has this byte grammar:

```
ESC  [   <parameter bytes>   <intermediate bytes>   <final byte>
0x1b 0x5b  0x30..0x3f (0-9 ; < = > ?)   0x20..0x2f (space !"#$%&'()*+,-./)   0x40..0x7e (@A-Z[\]^_`a-z{|}~)
```

- **Parameter bytes**: `0x30`–`0x3f` → digits `0`–`9`, `:`, `;`, `<`, `=`, `>`, `?`. Multiple
  params separated by `;`. Empty/omitted param = default (usually 1 for cursor keys).
- **Intermediate bytes**: `0x20`–`0x2f`. (Rarely used for input keys.)
- **Final byte**: `0x40`–`0x7e` — terminates the sequence and identifies it (`A`=cursor up, etc.).
- **SS3** (Single Shift 3): `ESC O <final>` — `0x4f` introducer, then ONE final byte (no params).
  Application Cursor Keys mode sends arrows/Home/End as SS3 (`ESC O A`) instead of CSI (`ESC [ A`).

Source: xterm ctlseqs "How to use this document" + ECMA-48 §5.4.
- https://invisible-island.net/xterm/ctlseqs/ctlseqs.html  (search "C1 (8-bit) Control Characters" + "CSI (Control Sequence Introducer) ... Pm ... Pi ... Pc")
- https://en.wikipedia.org/wiki/ANSI_escape_code#CSI_(Control_Sequence_Introducer)_commands

**Decoder rule (input.zig):** for a `.seq` event:
1. Require `bytes[0] == 0x1b`. `len == 1` ⇒ standalone Esc (app.zig already routes that to `.key(0x1b)`,
   so `.seq` always has `len >= 2`).
2. `bytes[1] == '['` ⇒ CSI: parse params (split `bytes[2..len-1]` on `;` into decimals),
   final byte = `bytes[len-1]`.
3. `bytes[1] == 'O'` ⇒ SS3: final byte = `bytes[2]` (no params).
4. Anything else ⇒ `ESC <char>` = Alt+char (NOT a motion for this TUI ⇒ ignore / null).

---

## 2. Cursor keys (plain) — CSI + SS3 forms

| Key       | CSI (normal cursor mode) | SS3 (application cursor mode) |
|-----------|--------------------------|-------------------------------|
| Up        | `ESC [ A`                | `ESC O A`                     |
| Down      | `ESC [ B`                | `ESC O B`                     |
| Right     | `ESC [ C`                | `ESC O C`                     |
| Left      | `ESC [ D`                | `ESC O D`                     |

Terminals pick CSI vs SS3 based on whether DECCKM (cursor-key mode, `?1`) is set. The popup
pty may emit either, so the decoder MUST accept BOTH forms and normalize them to the same motion.
Both map to the SAME motion as the vim `h j k l` keys (the normalization value of this subtask).

Source: xterm ctlseqs "Cursor Key Mode" / "PC-Style Function Keys".
- https://invisible-island.net/xterm/ctlseqs/ctlseqs.html  ("Cursor Key Mode ... sends ESC O x ... or ESC [ x")

---

## 3. Modified cursor keys — the modifier parameter `1;{mod}`

When a modifier (Shift/Alt/Ctrl) is held with an arrow, xterm sends the cursor sequence WITH a
modifier parameter: `ESC [ 1 ; {mod} {A|B|C|D}`. The leading `1` is the (default) cursor-key
identifier; the second parameter is the **modifier code**:

| Modifier code | Meaning            |
|---------------|--------------------|
| 2             | Shift              |
| 3             | Alt (Meta)         |
| 4             | Shift + Alt        |
| 5             | Control            |
| 6             | Shift + Control    |
| 7             | Alt + Control      |
| 8             | Shift + Alt + Control |

So:
- **Ctrl-Left** = `ESC [ 1 ; 5 D`  → normalizes to `word_back` (≡ vim `b`).
- **Ctrl-Right** = `ESC [ 1 ; 5 C` → normalizes to `word_fwd` (≡ vim `w`).
- **Ctrl-Up** = `ESC [ 1 ; 5 A`    → normalizes to `half_page_up` (≡ vim `Ctrl-u`).
- **Ctrl-Down** = `ESC [ 1 ; 5 B`  → normalizes to `half_page_down` (≡ vim `Ctrl-d`).

(The Ctrl-arrow → word/half-page mapping is a documented decoder DECISION, not a vim rule. It is
the near-universal editor convention for Ctrl-Left/Right = word motion; Ctrl-Up/Down = half-page
is a reasonable scroller convention. S2 owns motion→cursor semantics, so it can reinterpret.)

Shift-arrows (`1;2`), Alt-arrows (`1;3`), etc. are NOT motions in this TUI's normal mode ⇒ ignore.
Source: xterm ctlseqs "Modified Cursor Keys" / "modifyOtherKeys" — the modifier-code table.
- https://invisible-island.net/xterm/ctlseqs/ctlseqs.html  ("Modified Cursor Keys ... the same
  cursor keys ... with a parameter ... 2=Shift, 3=Alt, 4=Shift+Alt, 5=Control, 6=Shift+Control, 7=Alt+Control, 8=Shift+Alt+Control")

---

## 4. Home / End / PageUp / PageDown / Insert / Delete (~ and H/F finals)

| Key      | Forms accepted                                                                 |
|----------|--------------------------------------------------------------------------------|
| Home     | `ESC [ H` (screen) / `ESC O H` (SS3) / `ESC [ 1 ~` (xterm) / `ESC [ 7 ~` (rxvt) |
| End      | `ESC [ F` (screen) / `ESC O F` (SS3) / `ESC [ 4 ~` (xterm) / `ESC [ 8 ~` (rxvt) |
| PageUp   | `ESC [ 5 ~`  (+ modified `ESC [ 5 ; 5 ~` = Ctrl-PgUp, etc.)                     |
| PageDown | `ESC [ 6 ~`  (+ modified `ESC [ 6 ; 5 ~` = Ctrl-PgDn, etc.)                     |
| Insert   | `ESC [ 2 ~`  (NOT a motion ⇒ ignore)                                           |
| Delete   | `ESC [ 3 ~`  (NOT a motion ⇒ ignore)                                           |
| Shift-Tab| `ESC [ Z`    (NOT a motion ⇒ ignore)                                           |

**Decoder normalization:**
- Home → `line_start` (≡ vim `0`). End → `line_end` (≡ vim `$`).
  (Decision: Home/End are NOT in PRD §7.2's named motion list; mapping them to the line-edge
  motions is the common less/copy-mode expectation. S2/region can override in decodeSeq.)
- PageUp → `page_up` (≡ vim `Ctrl-b`). PageDown → `page_down` (≡ vim `Ctrl-f`).
- For `~` finals, param 5 ⇒ PageUp, 6 ⇒ PageDown, 1/4/7/8 ⇒ Home/End, 2/3 ⇒ ignore.
  Modified `~` (`5;5~` etc.) — ignore the modifier (treat as the base key).

Sources:
- xterm ctlseqs "PC-Style Function Keys": `ESC [ {code} ~` with code table
  (2=Insert, 3=Delete, 5=PageUp, 6=PageDown, 1/7=Home-ish, 4/8=End-ish).
  https://invisible-island.net/xterm/ctlseqs/ctlseqs.html
- tmux `tty-keys.c` real-world parser (corroborates H/F + ~ handling):
  https://github.com/tmux/tmux/blob/master/tty-keys.c

---

## 5. Vim normal-mode count semantics (the count register)

From `:help count` / `:help intro` / `:help motion.txt`:

- **`[count] command`** — a count is `1`-`9` followed by zero or more `0`-`9` digits, placed BEFORE
  the command. The count multiplies the command (e.g. `5j` moves the cursor down 5 lines).
  - https://vimhelp.org/intro.txt.html  ("A count ... [count] ... 1-9 ...")
  - https://vimhelp.org/motion.txt.html ("Either a single ... [count] before the command ...")
- **A leading `0` is NOT a count** — `0` is the "go to first character of the line" motion. `0`
  only contributes to a count when it FOLLOWS a non-zero digit (e.g. `10j` ⇒ count 10; `0` alone ⇒
  motion "line start"). This is the critical disambiguation rule for the decoder.
  - https://vimhelp.org/motion.txt.html  ("0   To the first character of the line. ... [count] ...")
- **An unknown/ignored command after a count discards the count.** (A non-mapping keypress clears
  any pending count — vim's command-line parse restarts.)
- **`gg`** — two-key command: `g` is a prefix; `gg` goes to the FIRST line. With a count N, `[count]gg`
  goes to line N. So the decoder must read a SECOND event after `g`, and the count typed before `g`
  carries through (e.g. `5gg` ⇒ Key{count=5, motion=doc_top}).
  - https://vimhelp.org/motion.txt.html  ("gg   Goto ... first line ... [count] ... line [count]")
- **`G`** — single key, goes to the LAST line. With count N, goes to line N.
  - https://vimhelp.org/motion.txt.html  ("G   Goto line [count] ... default last line")

**Decoder rule:** maintain a `count` register + a `pending_g` flag. Reading digit `1`-`9` sets /
extends count (return null, keep reading). Reading `0`: if count is active, extend it; else it is the
`line_start` motion. Reading `g`: if already pending_g ⇒ finalize `doc_top`; else set pending_g
(return null). Any other byte while pending_g ⇒ cancel pending_g and re-process the byte (lone `g`
discarded). Producing any Key resets count + pending_g.

---

## 6. PRD §7.2 motion set → byte/seq → normalized Motion

| Input                          | Byte / Sequence            | Normalized Motion        |
|--------------------------------|----------------------------|--------------------------|
| `h` / Left arrow               | `0x68` / `ESC[D`/`ESCOD`    | `left`                   |
| `l` / Right arrow              | `0x6c` / `ESC[C`/`ESCOC`    | `right`                  |
| `j` / Down arrow               | `0x6a` / `ESC[B`/`ESCOB`    | `down`                   |
| `k` / Up arrow                 | `0x6b` / `ESC[A`/`ESCOA`    | `up`                     |
| `w` / Ctrl-Right               | `0x77` / `ESC[1;5C`         | `word_fwd`               |
| `b` / Ctrl-Left                | `0x62` / `ESC[1;5D`         | `word_back`              |
| `e`                            | `0x65`                      | `word_end`               |
| `0` (no count) / Home          | `0x30` / `ESC[H`/`ESC[1~`   | `line_start`             |
| `^`                            | `0x5e`                      | `first_nonblank`         |
| `$` / End                      | `0x24` / `ESC[F`/`ESC[4~`   | `line_end`               |
| `gg`                           | `0x67 0x67`                 | `doc_top`                |
| `G`                            | `0x47`                      | `doc_bottom`             |
| `Ctrl-d` / Ctrl-Down           | `0x04` / `ESC[1;5B`         | `half_page_down`         |
| `Ctrl-u` / Ctrl-Up             | `0x15` / `ESC[1;5A`         | `half_page_up`           |
| `Ctrl-f` / PageDown            | `0x06` / `ESC[6~`           | `page_down`              |
| `Ctrl-b` / PageUp              | `0x02` / `ESC[5~`           | `page_up`                |
| `H`                            | `0x48`                      | `viewport_top`           |
| `M`                            | `0x4d`                      | `viewport_mid`           |
| `L`                            | `0x4c`                      | `viewport_bottom`        |
| `{`                            | `0x7b`                      | `paragraph_back`         |
| `}`                            | `0x7d`                      | `paragraph_fwd`          |
| `%`                            | `0x25`                      | `match_bracket`          |

## 7. Action / search keys (PRD §7.4 / §7.5)

| Input              | Byte / Seq        | Normalized             |
|--------------------|-------------------|------------------------|
| `v`                | `0x76`            | action `visual_toggle` |
| `V`                | `0x56`            | action `visual_line`   |
| `Ctrl-v` / `R`     | `0x16` / `0x52`   | action `visual_block`  |
| `o`                | `0x6f`            | action `swap_end`      |
| `O`                | `0x4f`            | action `swap_end_other`|
| `Esc` (0x1b)       | `0x1b`            | action `clear` (handler clears sel OR quits) |
| `q` / Ctrl-c       | `0x71` / `0x03`   | action `quit`          |
| `Enter` / `y`      | `0x0d`/`0x0a`/`0x79` | action `confirm`    |
| `/`                | `0x2f`            | search `start_forward` |
| `?`                | `0x3f`            | search `start_backward`|
| `n`                | `0x6e`            | search `next`          |
| `N`                | `0x4e`            | search `prev`          |

PRD §7.4 (selection): https://vimhelp.org/visual.txt.html ; PRD §7.5 (confirm/cancel).

## 8. Control-byte math (Ctrl-<letter> = letter & 0x1f)

`Ctrl-<uppercase-or-lowercase letter>` produces the byte `(letter_code & 0x1f)`:
- Ctrl-A=0x01 … Ctrl-Z=0x1a. So: Ctrl-B=`'b'&0x1f`=0x02, Ctrl-D=0x04, Ctrl-F=0x06,
  Ctrl-U=0x15, Ctrl-V=0x16, Ctrl-C=0x03.
- Esc = 0x1b (technically Ctrl-[). Enter = `\r`=0x0d (CR); some terminals send `\n`=0x0a (LF).
  Accept BOTH 0x0d and 0x0a as confirm.
- https://en.wikipedia.org/wiki/C0_and_C1_control_codes  +  vim `:help keycodes`
  (https://vimhelp.org/intro.txt.html "<Key> ... <CR> ... <Esc> ... <C-x>").

---

## SUMMARY for the decoder
- CSI: split params on `;`, final byte `0x40..0x7e`. SS3: `ESC O <final>`. Alt+char: ignore.
- Arrows: accept BOTH CSI (`ESC [ A..D`) and SS3 (`ESC O A..D`). Modifier `1;5` ⇒ Ctrl ⇒
  word/half-page. Home/End/PageUp/PageDown ⇒ line/page motions; Insert/Delete/Shift-Tab ⇒ ignore.
- Plain bytes: vim motion set + control bytes (Ctrl-b/d/f/u/v/c) + Esc/Enter/q/y + v/V/o/O/R +
  / ? n N. Digits 1-9 start count; 0 is count ONLY after a non-zero digit, else `line_start`.
- `g` is a prefix: `gg` ⇒ doc_top; the count typed before `g` carries through. Lone `g` + non-g ⇒
  cancel + re-process. Producing any Key resets count + pending_g.
- Output: `Key{ count: u32 (≥1, 1 when none typed), kind: motion|action|search }`.
