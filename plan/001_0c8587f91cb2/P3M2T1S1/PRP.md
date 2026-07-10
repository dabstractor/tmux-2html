name: "P3.M2.T1.S1 — Key-sequence decoder (arrows, Ctrl-mods, vim keys) + count prefix (NEW src/tui/input.zig)"
description: |

---

## Goal

**Feature Goal**: CREATE `src/tui/input.zig` — the key decoder that turns app.zig's typed
`Event` stream (`.key` / `.seq` / `.eof`, SHIPPED by P3.M1.T1.S2) into a **normalized `Key`**
(`{ count, motion | action | search }`) consumed by the motion engine (P3.M2.T1.S2). It does
three things (PRD §7.2 + arch `tui_region.md` §3):

1. **Decode ESC-prefixed sequences** (app.zig hands these RAW as `.seq`, incl. leading `\x1b`):
   arrows (`\x1b[A/B/C/D` CSI **and** `\x1bOA/B/C/D` SS3), Ctrl-modified arrows (`\x1b[1;5A/B/C/D`),
   Home/End (`\x1b[H/F`, `\x1bOH/F`, `\x1b[1~/4~/7~/8~`), PgUp/Dn (`\x1b[5~/6~`). Each collapses
   to a PRD §7.2 motion (arrow≡hjkl; Ctrl-Left/Right≡b/w; Home/End≡0/$; PgUp/Dn≡Ctrl-b/f).
2. **Decode plain keys** (`\x1b`/standalone bytes via `.key`): the full vim motion set
   (`h j k l w b e 0 ^ $ G Ctrl-d/u/f/b H M L { } %`), selection/confirm/cancel actions
   (`v V Ctrl-v/R o O Esc q Enter y`), and search (`/ ? n N`).
3. **Parse the count prefix** + **maintain a count register**: leading digits `1`-`9` (+ subsequent
   `0`-`9`) before a command ⇒ `Key.count` (e.g. `5j`⇒count 5). Leading `0` is the `line_start`
   motion, NOT a count (vim rule). `gg` is a two-key command (`g` prefix) whose count carries
   through (`5gg`⇒ doc_top, count 5).

**Deliverable** (ONE new file + ONE one-line main.zig test-block import; ALL else unchanged):
- **NEW FILE `src/tui/input.zig`** (std-only + `@import("app.zig")`; NO ghostty-vt ⇒ its tests are
  SAFE as separate `test` fns — no cross-test GOTCHA).
- **Public types**: `Motion` (21 variants, the PRD §7.2 set + Home/End), `Action` (8), `Search` (4),
  `KeyKind` (union `motion|action|search`), `Key{ count: u32 = 1, kind: KeyKind }`.
- **PURE leaf decoders** (slice/byte in → classification out; fully unit-tested): `decodeSeq(seq)
  ?Motion` (CSI+SS3+modifier-param+`~` keys), `decodeByte(b) ByteClass` (motion/action/search/ignore).
- **The state machine**: `Decoder{ count, has_count, pending_g }` + `feed(self, ev: app.Event) ?Key`
  (the count register + `gg` prefix + digit/`0` rules; PURE-ish stateful, no I/O ⇒ fully testable).
- **The driver + seam** (the literal `decode(reader) !Key`): `EventReader{ ctx:*anyopaque,
  readEventFn }` (mirrors `app.Input`/`capture.Runner`), `SliceEventReader` (test),
  `InputEventReader` (prod wrapper over `app.Input`), `decode(self:*Decoder, reader) !Key`
  (loops `reader.readEvent()`→`feed`, `.eof`⇒`error.EndOfStream`, skips `.mouse`).
- **Tests**: per-PURE-fn `test` blocks (decodeSeq all forms, decodeByte all bytes, feed state-machine
  cases incl. counts/gg/`0`/cancel, decode(driver) via SliceEventReader).
- **ONE main.zig edit**: add `_ = @import("tui/input.zig");` to the existing `test {}` block (after
  the `tui/view.zig` import at main.zig:493), so the new tests are reachable. NO other main.zig change.

**Nothing else changes**: NO edits to `app.zig` (its `Event`/`EscSeq`/`Input` surface is the INPUT
contract — consumed as-is), `view.zig`, `render.zig`, `palette.zig`, `capture.zig`, `cli.zig`,
`build.zig`/`build.zig.zon`, `PRD.md`, `tasks.json`. Sibling layers (P3.M2.T1.S2 motions,
P3.M2.T2 select, P3.M3 region) do NOT exist yet — this module's `Key`/`Decoder`/`feed` are designed
so they plug in later WITHOUT rewriting input.zig.

**Success Definition**:
- `zig build test -Doptimize=ReleaseFast` passes; input.zig's new PURE tests (decodeSeq, decodeByte,
  feed, decode-via-slice) are GREEN and reachable from main.zig's test block; ZERO regressions in the
  rest of the suite. (ReleaseFast MANDATORY — PRD §15 / main.zig Gotcha: Debug-mode `zig build test`
  hits the Zig linker bug `R_X86_64_PC64` with the bundled C++ SIMD libs.)
- `zig build -Doptimize=ReleaseFast` compiles — proof the `app.Event`/`app.EscSeq`/`app.Input`
  surface (all SHIPPED) is consumed correctly + the `EventReader`/`@ptrCast(@alignCast)` seam is right.
- The decode logic is correct (unit-asserted): every accepted ESC form → the right Motion; every vim
  byte → the right variant; counts parse (`5j`⇒5, `10j`⇒10, leading `0`⇒line_start-no-count); `gg`
  + count-carry-through; unknown bytes swallow + reset count; `.eof`/`.mouse` are no-ops for `feed`.

## User Persona (if applicable)

**Target User**: the motion engine `src/tui/...` (P3.M2.T1.S2) + ultimately `tmux-2html region`
(P3.M3.T1). input.zig is an INTERNAL library; no end user calls it directly.

**Use Case**: PRD §7.2/§7.4/§7.5 — inside the region popup, `region` calls `app.runEvents(handler)`
(P3.M3); the handler owns a `Decoder` and, per `Event`, routes `.mouse`→select (P3.M2.T2) and
`.key`/`.seq`→`decoder.feed(ev)`; when `feed` yields a `Key`, the handler dispatches `motion`→
cursor/scroll (P3.M2.T1.S2), `action`→selection/quit/confirm, `search`→enter pattern-typing. The
user types vim keys / arrows / counts exactly like tmux copy-mode.

**User Journey**: `prefix C-o` → popup → `app.enter()` → `app.runEvents(handler)` → user types `5j`
→ `feed` consumes `5`(digit,count=5)→null, `j`(motion)→`Key{count:5,.down}` → handler moves cursor
down 5 → `view.render`+`renderStatus` repaint → `q`→`feed`→`Key{.quit}`→exit.

**Pain Points Addressed**: vim/arrow/count input works faithfully in the overlay; the input layer is
decoupled (decode) from the action layer (motion/select) so each can evolve independently.

## Why

- **PRD §7.2 mandates the motion set** (`h j k l` + arrows, `w b e`, `0 ^ $`, `gg`/`G`, `Ctrl-d/u/f/b`,
  `H M L`, `{ }`, `%`, counts) and **arch `tui_region.md` §3 is the verified decode contract**
  (`\x1b[A/B/C/D`, `\x1b[1;5D` Ctrl-arrow, `\x1b[H/F`, `\x1b[5/6~`, then plain keys, leading-digit
  counts). This subtask is the decode half: raw input → normalized `Key`.
- **app.zig already did byte→Event** (P3.M1.T1.S2, SHIPPED): it classifies `\x1b[<…` as `.mouse`
  (fully decoded), other `\x1b[…]`/`\x1bO…`/`\x1b<x>` as `.seq` (RAW, undecoded — handed to THIS
  module), and plain bytes as `.key`. So the lone-Esc disambiguation + mouse decode are DONE; THIS
  module is purely **Event→Key** (seq decode + counts + normalization). Clean layering.
- **The decoder is the natural decoupling seam**: it collapses equivalent inputs (h≡←≡`\x1b[D`≡
  `\x1b[OD`; Home≡`0`) into ONE motion variant, so the motion engine (S2) switches on a small enum
  instead of re-parsing raw bytes/seqs. Count + `gg` state lives here, once.
- **Forward-compatible seams.** `feed` is the per-event entry the EventHandler calls; `decode(reader)`
  is the literal contract fn (slice-testable). Both share the SAME `feed` core → single source of
  truth. S2 consumes `Key`; P3.M3 wires the loop. No rewrite needed for any later task.

## What

### Behavior (`src/tui/input.zig` — NEW module; std + `app.zig` only)

1. **`decodeSeq(seq: []const u8) ?Motion`** — PURE. `seq` INCLUDES leading `\x1b` (app.zig's
   `.seq` payload). CSI `\x1b[<params><final>`: split params on `;`; final byte ∈ `0x40..0x7e`.
   SS3 `\x1b O <final>` (no params). Returns the Motion or `null` (Alt+char, Insert, Delete,
   Shift-Tab, Shift/Alt-arrow are NOT motions). Mapping (full table: `research/external_keyseq_vim.md`):
   - `\x1b[A`/`\x1bOA`⇒up; `B`⇒down; `C`⇒right; `D`⇒left. With `1;5` ⇒ Ctrl: `1;5A`⇒half_page_up,
     `1;5B`⇒half_page_down, `1;5C`⇒word_fwd, `1;5D`⇒word_back. (`1;2`/`1;3`/etc ⇒ null.)
   - `\x1b[H`/`\x1bOH`/`\x1b[1~`/`\x1b[7~`⇒line_start (Home); `\x1b[F`/`\x1bOF`/`\x1b[4~`/`\x1b[8~`⇒line_end (End).
   - `\x1b[5~`⇒page_up; `\x1b[6~`⇒page_down. (`\x1b[2~`/`3~`/`Z` ⇒ null.)
2. **`decodeByte(b: u8) ByteClass`** — PURE. One byte ⇒ `motion`/`action`/`search`/`ignore`.
   - motions: `h`⇒left,`l`⇒right,`j`⇒down,`k`⇒up,`w`⇒word_fwd,`b`⇒word_back,`e`⇒word_end,
     `0`⇒line_start,`^`⇒first_nonblank,`$`⇒line_end,`G`⇒doc_bottom,`H`⇒viewport_top,`M`⇒viewport_mid,
     `L`⇒viewport_bottom,`{`⇒paragraph_back,`}`⇒paragraph_fwd,`%`⇒match_bracket, Ctrl bytes
     `0x02`⇒page_up(b),`0x04`⇒half_page_down(d),`0x06`⇒page_down(f),`0x15`⇒half_page_up(u).
     (`g` is NOT here — feed handles the `gg` prefix; `G` IS here.)
   - actions: `v`⇒visual_toggle,`V`⇒visual_line,`0x16`(Ctrl-v)/`R`⇒visual_block,`o`⇒swap_end,
     `O`⇒swap_end_other,`0x1b`(Esc)⇒clear,`q`/`0x03`(Ctrl-c)⇒quit,`0x0d`/`0x0a`(Enter)/`y`⇒confirm.
   - search: `/`⇒start_forward,`?`⇒start_backward,`n`⇒next,`N`⇒prev.
   - everything else ⇒ `ignore`.
3. **`Decoder` + `feed`** — the count register + `gg` state machine (PURE-ish, no I/O). `feed`:
   - `.eof`/`.mouse` ⇒ `null` (no-op; driver short-circuits eof; handler routes mouse to select FIRST).
   - `.seq` ⇒ `decodeSeq`; null⇒reset+null; else finalize motion.
   - `.key` byte `b`: resolve `pending_g` first (clear it; if `b=='g'`⇒finalize doc_top else fall
     through); then digits (`1`-`9` start/extend count; `0` extends count only if `has_count`, else
     falls through to `decodeByte`⇒line_start); then `b=='g'`⇒set pending_g+null; else
     `decodeByte(b)`: ignore⇒reset+null, else finalize. finalize ⇒ `Key{count: has_count?count:1,
     kind}` then reset count/pending_g; return Key. (Full flow in Implementation Blueprint.)
4. **`EventReader` seam + `decode(driver)`** — mirrors `app.Input`/`capture.Runner`: `{ctx:*anyopaque,
   readEventFn}` + `readEvent()!app.Event`. `SliceEventReader` (test, yields slice then `.eof`),
   `InputEventReader` (prod, wraps `app.Input`+`app.readEvent`). `decode(self, reader) !Key` loops
   `reader.readEvent()`; `.eof`⇒`error.EndOfStream`; `.mouse`⇒continue (skip); `feed`⇒ first non-null Key.

### Success Criteria

- [ ] NEW `src/tui/input.zig` imports ONLY `std` + `app.zig` (ghostty-free ⇒ separate test fns safe).
- [ ] `decodeSeq` decodes EVERY accepted form (CSI+SS3 arrows, `1;5` Ctrl-mods, H/F + `~` Home/End,
      `5~`/`6~` PgUp/Dn) to the right Motion; rejects Alt+char/Insert/Delete/Shift-Tab/Shift-arrow (null).
- [ ] `decodeByte` maps EVERY vim motion/action/search byte to the right variant; unmapped ⇒ ignore.
- [ ] `feed` parses counts (`5j`⇒{5,down}, `10j`⇒{10,down}, leading `0`⇒{1,line_start}), `gg`⇒doc_top
      (count carries: `5gg`⇒{5,doc_top}), lone-`g`+non-g⇒cancel+reprocess, unknown-after-count⇒swallow+
      reset, arrow `.seq`⇒motion-with-count, `.eof`/`.mouse`⇒null.
- [ ] `decode(driver)` via SliceEventReader: `{'5','j'}`⇒{5,down}; `{'g','g'}`⇒doc_top; `{\x1b[A}`⇒up;
      end-of-slice⇒`error.EndOfStream`; `.mouse` in slice⇒skipped.
- [ ] main.zig test block gains exactly ONE line (`_ = @import("tui/input.zig");`); nothing else changes.
- [ ] `zig build -Doptimize=ReleaseFast` compiles; `zig build test -Doptimize=ReleaseFast` GREEN (no regressions).

## All Needed Context

### Context Completeness Check

_Passed._ An agent who knows nothing about this codebase can implement this from: the SHIPPED
`app.zig` `Event`/`EscSeq`/`Input` surface (the INPUT contract — exact symbols cited in
`research/design_notes.md` §0–§2 + read `src/tui/app.zig`); the AUTHORITATIVE keyseq/vim facts
(modifier codes, CSI/SS3 grammar, `~` table, count/`0`/`gg` rules, control-byte math) in
`research/external_keyseq_vim.md` (every claim URL-cited); the API + seam design + `feed` flow +
scope boundaries + gotchas in `research/design_notes.md`; the `capture.Runner`/`app.Input` seam to
mirror (read `src/capture.zig:58-66` + `src/tui/app.zig`). Every protocol fact is pinned to xterm
ctlseqs / vimhelp; every Zig API to the shipped 0.15.2 stdlib (and app.zig's verified usage).

### Documentation & References

```yaml
# MUST READ — the AUTHORITATIVE keyseq/vim facts (PRIMARY; do not guess modifier codes / count rules)
- file: plan/001_0c8587f91cb2/P3M2T1S1/research/external_keyseq_vim.md
  why: CSI/SS3 grammar (params 0x30-0x3f on ';', final 0x40-0x7e); the FULL modifier-code table
       (2=Shift,3=Alt,5=Ctrl,...) so Ctrl-Left=`\x1b[1;5D`; arrows CSI `\x1b[A..` AND SS3 `\x1bOA..`;
       Home/End (`\x1b[H/F`, `\x1bOH/F`, `\x1b[1~/4~/7~/8~`); PgUp/Dn (`\x1b[5~/6~`); Insert/Delete/
       Shift-Tab ⇒ ignore; the count rule (1-9 then 0-9; LEADING 0 = line_start motion NOT a count);
       gg = two-key (count carries: `[count]gg`⇒line N); G single; Ctrl-<letter> = letter & 0x1f.
  critical: the LEADING-0 rule is the #1 decode pitfall — `0` is the line_start motion UNLESS it
            follows a non-zero digit. `1;5` (not `5` alone) is the Ctrl modifier param. Accept BOTH
            CSI and SS3 arrow forms (the popup pty may emit either). Esc=0x1b, Enter=0x0d OR 0x0a.

# MUST READ — the API + seam design + feed flow + scope boundaries + Zig gotchas
- file: plan/001_0c8587f91cb2/P3M2T1S1/research/design_notes.md
  why: The exact public API (Motion/Action/Search/KeyKind/Key + Decoder/feed + EventReader/decode +
       SliceEventReader/InputEventReader); the feed() flow (pending_g resolved FIRST, then digits,
       then g-start, then leaf decodeByte — the precise ordering that makes `5gg`/`g5`/`10j` correct);
       WHY count=u32 resolved-to-1 (S2 just multiplies); WHY Esc⇒.clear not .quit (state-dependent);
       WHY Ctrl-c⇒.quit; WHY arrows≡hjkl is the normalization; WHY search emits START only (S2 collects
       the pattern); the EventReader seam mirroring app.Input; the prod-path-is-feed note; gotchas.
  critical: feed is INFALLIBLE (no I/O) ⇒ returns ?Key (optional), NOT !Key — the driver does
            `if (feed(self, ev)) |k| return k;` with NO `try`. decodeByte handles '0'⇒line_start and
            'G'⇒doc_bottom, but NOT 'g'/'1'-'9' (feed intercepts those). MAX_COUNT clamp prevents
            u32 overflow. The one main.zig edit is in the test {} block (after the view.zig import).

# MUST READ — the INPUT contract: app.zig's SHIPPED Event/EscSeq/Input surface (read it; consume as-is)
- file: src/tui/app.zig
  why: input.zig consumes app.zig's `Event = union(enum){ key:u8, mouse:MouseEvent, seq:EscSeq,
       eof:void }`, `EscSeq{ bytes:[max_esc_len]u8, len:u8, pub fn slice(self:*const EscSeq)[]const u8 }`
       (slice takes *const self — app.zig GOTCHA; ev.seq.slice() is fine since ev is an lvalue param),
       `Input{ ctx:*anyopaque, readByteTimeoutFn }` (the byte source; InputEventReader wraps this),
       `readEvent(input: Input) anyerror!Event` (returns app.Event, .eof on stdin close — NOT optional),
       `max_esc_len`. app.zig ALREADY classifies `\x1b[<…`⇒.mouse (decoded) and other `\x1b…`⇒.seq (RAW,
       undecoded, leading \x1b INCLUDED) — so input.zig ONLY does Event→Key. Do NOT touch app.zig.
  critical: .seq bytes INCLUDE the leading 0x1b (decodeSeq matches "\x1b[A" etc.). readEvent returns a
            full Event (eof = the .eof variant) — so EventReader.readEvent returns !app.Event (NOT ?Event),
            and decode() checks `ev == .eof` ⇒ error.EndOfStream (do NOT feed .eof to feed in a loop).

# MUST READ — the seam to mirror (proven mockability in this repo)
- file: src/capture.zig   # lines 58-66 (Runner), 127-130 (real singleton), 356 (@ptrCast/@alignCast)
  why: `Runner = struct { ctx: *anyopaque, runFn: *const fn(...)..., pub fn run(...) }` is the EXACT
       shape `EventReader` mirrors (NON-nullable ctx + fn pointer + thin method). The prod singleton
       (`real: Runner = .{ .ctx = @ptrCast(&real_state), ... }`) + FakeTmux test double +
       `@ptrCast(@alignCast(ctx))` recovery (line 356) is exactly how SliceEventReader/InputEventReader
       recover their typed pointer. @alignCast is MANDATORY in 0.15.2.
  pattern: copy the {ctx, fn} struct + thin method; the impl struct must be a stack `var` so &x is *T.

# READ — the consumer contract (what Key must feed) + the selection/search consumers
- file: plan/001_0c8587f91cb2/tasks.json   # P3.M2.T1.S2 / P3.M2.T2.S1 context_scope
  why: S2 (vim motions) INPUT = "Key + count; grid dims + decoded per-row cell text"; it implements the
       §7.2 motions + `/`/`?`/`n`/`N` search. P3.M2.T2.S1 INPUT = "cursor model from input.zig" and
       defines `Mode{none,linewise,block}` + `Sel{anchor,cursor,mode}`. So Key.kind must be {motion,
       action, search} with the variants listed in design_notes §1 — that is what they consume.

# READ — the contract spec + the testing/safety rules
- file: PRD.md
  why: §7.2 (the motion set + counts — the variants Motion enumerates), §7.4 (v/V/Ctrl-v/R/o/O/Esc —
       the Action variants), §7.5 (q/Esc/Ctrl-c quit; Enter/y confirm), §7.3 (//?nN search), §7.1
       (raw termios — keys arrive byte/seq-at-a-time, already handled by app.zig), §0+§15 (NEVER touch
       the user's running tmux; ReleaseFast mandatory for tests).
- file: plan/001_0c8587f91cb2/architecture/tui_region.md
  why: §3 IS the decode contract (the sequences + plain keys + leading-digit counts this subtask names).
       Confirms mouse (`\x1b[<`) is app.zig's job (NOT decoded here) and non-mouse ESC seqs are THIS
       module's job (app.zig hands them as raw .seq).

# EXTERNAL (authoritative; re-fetch anchors before CI citation)
- url: https://invisible-island.net/xterm/ctlseqs/ctlseqs.html
  why: xterm ctlseqs — PRIMARY authority for CSI/SS3 grammar, "Cursor Key Mode", "Modified Cursor Keys"
       (the 2/3/5/... modifier table), "PC-Style Function Keys" (the `~` code table). Cite for every
       seq-form assertion.
- url: https://vimhelp.org/motion.txt.html
  why: the motion set + `[count]` rule + the LEADING-0-is-line_start rule + `gg`/`G` with count.
- url: https://vimhelp.org/intro.txt.html
  why: `[count] command` syntax + Ctrl-<letter> = control bytes; Esc/Enter keycodes.
```

### Current Codebase tree (relevant slice)

```bash
src/
├── main.zig          # test {} block (main.zig:476) — needs ONE new line `_ = @import("tui/input.zig");`
├── capture.zig       # ← the Runner seam (ctx:*anyopaque, runFn) to mirror for EventReader
└── tui/
    ├── app.zig       # ← SHIPPED (P3.M1.T1). Event/EscSeq/Input/readEvent = the INPUT contract. NOT edited.
    ├── view.zig      # ← SHIPPED (P3.M1.T2). NOT edited by this subtask.
    └── input.zig     # ← NEW (THIS subtask). std + app only.
plan/001_0c8587f91cb2/architecture/tui_region.md   # §3 = the decode contract
plan/001_0c8587f91cb2/P3M2T1S1/research/           # external_keyseq_vim.md, design_notes.md
```

### Desired Codebase tree with files to be added/modified

```bash
src/
├── main.zig          # MODIFIED — +1 line in test {} block (`_ = @import("tui/input.zig");`). Nothing else.
└── tui/
    └── input.zig     # NEW — Motion/Action/Search/KeyKind/Key + decodeSeq + decodeByte + Decoder/feed
                      #        + EventReader/SliceEventReader/InputEventReader + decode + tests.
# NO other files change. NO build.zig/build.zig.zon edit. NO new deps.
```

### Known Gotchas of our codebase & Library Quirks

```zig
// CRITICAL: `zig build test` (Debug) HITS a Zig linker bug (R_X86_64_PC64) with the bundled C++
//   SIMD libs. Tests MUST run as `zig build test -Doptimize=ReleaseFast` (PRD §15). Every Validation
//   command below uses ReleaseFast.

// CRITICAL: input.zig imports ONLY `std` + `app.zig` (app.zig is std-only). NO ghostty-vt ⇒ NO
//   Terminal.init ⇒ NO single-test-scope GOTCHA. Every PURE fn (decodeSeq, decodeByte) + feed + the
//   slice-driven decode() gets its OWN separate `test` fn (mirrors app.zig's separate test fns).

// CRITICAL: app.zig classifies input for you. `\x1b[<{b};{x};{y}M/m` ⇒ .mouse (DECODED — not yours;
//   P3.M2.T2's job). Other `\x1b[…]` / `\x1bO…` / `\x1b<x>` ⇒ .seq (RAW, undecoded, leading \x1b
//   INCLUDED — THIS module decodes them). Plain bytes (incl. standalone Esc 0x1b) ⇒ .key. So
//   decodeSeq ONLY ever sees non-mouse sequences with a leading \x1b. Do NOT re-handle mouse.

// CRITICAL: the LEADING-0 rule. A '0' (0x30) is the line_start motion UNLESS it follows a non-zero
//   digit (then it extends the count: `10j` ⇒ count 10). feed implements this: digits '1'-'9' always
//   extend count; '0' extends count ONLY when has_count, else falls through to decodeByte('0')⇒
//   line_start. NEVER let '0' start a count.

// CRITICAL: `gg` is a TWO-key command. 'g' (0x67) is a PREFIX: feed sets pending_g and returns null;
//   the NEXT key: if 'g' ⇒ finalize doc_top (count carries: `5gg` ⇒ {5, doc_top}); if non-g ⇒ cancel
//   pending_g and re-process the byte (digits start a fresh count, etc.). 'G' (0x47) is a SINGLE key
//   ⇒ doc_bottom (in decodeByte, NOT the prefix path). Do NOT confuse 'g' and 'G'.

// CRITICAL: feed is INFALLIBLE (no I/O). It returns `?Key` (optional), NOT an error union. The driver
//   decode() calls it WITHOUT `try`: `if (feed(self, ev)) |k| return k;`. decodeByte/decodeSeq are
//   also infallible. Only EventReader.readEvent / decode(driver) are `!` (they do I/O via the reader).

// CRITICAL: EventReader.readEvent returns `anyerror!app.Event` (a FULL Event — eof is the .eof variant,
//   mirroring app.readEvent EXACTLY — NOT an optional). decode() must check `if (ev == .eof) return
//   error.EndOfStream;` BEFORE feeding (else .eof⇒feed returns null⇒infinite loop reading eof).
//   `.mouse` ⇒ `continue` (skip; the full loop routes mouse to select.zig — decode(driver) is the
//   keyboard path). SliceEventReader yields the slice then returns `.eof`.

// GOTCHA: `app.EscSeq.slice()` takes `self: *const EscSeq` (by-pointer, NOT by-value — app.zig's
//   verified SROA GOTCHA). In feed, `ev.seq.slice()` is safe because `ev` is a named parameter (an
//   lvalue), so `ev.seq` is addressable. Do NOT copy the EscSeq into a temporary then call slice().

// GOTCHA: `@ptrCast(@alignCast(ctx))` is MANDATORY for reader-impl pointer recovery in 0.15.2
//   (capture.zig:356, app.zig FdInput). SliceEventReader/InputEventReader must be stack `var` so `&x`
//   is `*T` (a `const` yields `*const T` which does NOT coerce — capture findings §2). Wire EventReader
//   via `.{ .ctx = @ptrCast(&r), .readEventFn = SliceEventReader.readEvent }`.

// GOTCHA: no allocation needed. The decoder is stack-only — app.Event's EscSeq is a fixed inline
//   buffer (app.max_esc_len=16); decodeSeq/decodeByte/feed/decode allocate nothing. Tests use no
//   allocator. This keeps the module trivially leak-free.

// GOTCHA: tagged-union compare/capture in Zig 0.15.2: `ev == .eof` / `ev == .mouse` (tag compare);
//   `switch (ev) { .key => |b| ..., .seq => |s| ..., else => {} }` (payload capture; s is the EscSeq).
//   Compare Key with std.testing.expectEqual (Key is a plain struct of a u32 + a tagged union —
//   structural equality works). For decodeSeq results compare the ?Motion (expectEqual on optionals).

// GOTCHA: the ONE main.zig edit is in the `test {}` block (main.zig:476), adding
//   `_ = @import("tui/input.zig");` AFTER the existing `_ = @import("tui/view.zig");` (main.zig:493).
//   Do NOT touch any other part of main.zig (no panic override, no dispatch, no imports-on-exe-path).
//   input.zig is reached on the EXE path transitively only if something imports it — for v1 it is
//   test-only (region.zig will import it in P3.M3); the test-block import makes its tests reachable.
```

## Implementation Blueprint

### Data models and structure

```zig
// src/tui/input.zig — NEW. std + app only.
const std = @import("std");
const app = @import("app.zig"); // Event, EscSeq, Input, readEvent — SHIPPED (consume as-is)

/// Normalized vim motions (PRD §7.2 + decoded arrows/Ctrl-mods/Home/End/PgUp/Dn). The DECODER
/// collapses equivalent inputs to ONE variant (h≡←≡`\x1b[D`≡`\x1b[OD` ⇒ .left). S2 switches on this.
pub const Motion = enum {
    left, right, up, down,                // h l j k / arrows
    word_fwd, word_back, word_end,        // w b e / Ctrl-Right Ctrl-Left
    line_start, first_nonblank, line_end, // 0 ^ $ / Home End
    doc_top, doc_bottom,                  // gg G
    half_page_down, half_page_up,         // Ctrl-d Ctrl-u / Ctrl-Down Ctrl-Up
    page_down, page_up,                   // Ctrl-f Ctrl-b / PgDn PgUp
    viewport_top, viewport_mid, viewport_bottom, // H M L
    paragraph_back, paragraph_fwd,        // { }
    match_bracket,                        // %
};

pub const Action = enum {
    visual_toggle, // v
    visual_line, // V
    visual_block, // Ctrl-v (0x16) / R
    swap_end, // o
    swap_end_other, // O
    clear, // Esc — handler clears selection OR quits (state-dependent; §3 of design_notes)
    quit, // q / Ctrl-c (0x03)
    confirm, // Enter (0x0d/0x0a) / y
};

pub const Search = enum {
    start_forward, // /
    start_backward, // ?
    next, // n
    prev, // N
};

pub const KeyKind = union(enum) {
    motion: Motion,
    action: Action,
    search: Search,
};

/// A fully-decoded key command. `count` is the multiplier (≥1); 1 when no digits were typed.
/// `0` never appears as a count (leading 0 = line_start motion). Capped at MAX_COUNT.
pub const Key = struct {
    count: u32 = 1,
    kind: KeyKind,
};

/// Absurd-count clamp (prevents `count*10` u32 overflow from pathological digit streams).
pub const max_count: u32 = 1_000_000;
```

### PURE leaf: `decodeSeq` (CSI + SS3 + modifier param + `~` keys)

```zig
/// PURE: map a COMPLETE raw ESC sequence (INCLUDING leading 0x1b) to a Motion, or null if it is
/// not a motion this TUI recognizes. CSI `\x1b[<params><final>` (params split on ';', final
/// 0x40..0x7e); SS3 `\x1bO<final>` (no params); Alt+char `\x1b<x>` ⇒ null. Source of every fact:
/// research/external_keyseq_vim.md §1-§4.
pub fn decodeSeq(seq: []const u8) ?Motion {
    if (seq.len < 3 or seq[0] != 0x1b) return null; // need ESC + introducer + ≥1 final
    if (seq[1] == 'O') { // SS3 application cursor keys / home-end: ESC O <final>
        return switch (seq[2]) {
            'A' => .up, 'B' => .down, 'C' => .right, 'D' => .left,
            'H' => .line_start, 'F' => .line_end, // Home/End (SS3)
            else => null,
        };
    }
    if (seq[1] != '[') return null; // Alt+char or other ⇒ not a motion (ignore)
    const final = seq[seq.len - 1];
    const params = seq[2 .. seq.len - 1]; // between '[' and final (may be empty)
    // parse up to 2 params (cursor keys use 0 or 1 params; ~ keys use 1; modifiers add a 2nd)
    var p = [_]u32{ 0, 0 };
    var np: usize = 0;
    if (params.len > 0) {
        var it = std.mem.splitScalar(u8, params, ';');
        while (it.next()) |tok| {
            if (np >= 2) return null; // too many params ⇒ unknown
            p[np] = std.fmt.parseInt(u32, tok, 10) catch return null;
            np += 1;
        }
    }
    const mod = if (np >= 2) p[1] else 0; // modifier code (2=Shift,3=Alt,5=Ctrl,...)
    switch (final) {
        'A', 'B', 'C', 'D' => { // arrows; Ctrl-mod (1;5) ⇒ word/half-page; Shift/Alt ⇒ null
            const m: Motion = switch (final) { 'A' => .up, 'B' => .down, 'C' => .right, 'D' => .left, else => unreachable };
            return switch (mod) {
                0 => m, // plain arrow (≡ hjkl)
                5 => switch (final) { // Ctrl-arrow
                    'A' => .half_page_up, 'B' => .half_page_down,
                    'C' => .word_fwd, 'D' => .word_back, else => null,
                },
                else => null, // Shift/Alt/other-mod arrows ⇒ not a motion
            };
        },
        'H' => return if (mod == 0) .line_start else null, // Home (CSI)
        'F' => return if (mod == 0) .line_end else null, // End (CSI)
        '~' => { // numeric special keys: param p[0] selects the key
            return switch (p[0]) {
                5 => .page_up, // PgUp
                6 => .page_down, // PgDn
                1, 7 => .line_start, // Home (xterm/rxvt)
                4, 8 => .line_end, // End (xterm/rxvt)
                else => null, // 2=Insert,3=Delete, etc. ⇒ not a motion
            };
        },
        else => return null,
    }
}
```

### PURE leaf: `decodeByte` (single key byte → motion/action/search/ignore)

```zig
pub const ByteClass = union(enum) { motion: Motion, action: Action, search: Search, ignore };

/// PURE leaf classification of ONE .key byte (NOT a digit, NOT handled by feed's g-prefix). The
/// digit '0' IS handled here (⇒ line_start) because feed only intercepts '0' when extending a
/// count. 'g' (0x67) is NOT here (feed's pending_g handles gg); 'G' (0x47) IS here (⇒ doc_bottom).
pub fn decodeByte(b: u8) ByteClass {
    return switch (b) {
        // motions (vim + Ctrl control bytes)
        'h' => .{ .motion = .left }, 'l' => .{ .motion = .right },
        'j' => .{ .motion = .down }, 'k' => .{ .motion = .up },
        'w' => .{ .motion = .word_fwd }, 'b' => .{ .motion = .word_back }, 'e' => .{ .motion = .word_end },
        '0' => .{ .motion = .line_start }, '^' => .{ .motion = .first_nonblank }, '$' => .{ .motion = .line_end },
        'G' => .{ .motion = .doc_bottom },
        'H' => .{ .motion = .viewport_top }, 'M' => .{ .motion = .viewport_mid }, 'L' => .{ .motion = .viewport_bottom },
        '{' => .{ .motion = .paragraph_back }, '}' => .{ .motion = .paragraph_fwd },
        '%' => .{ .motion = .match_bracket },
        0x02 => .{ .motion = .page_up }, // Ctrl-b
        0x04 => .{ .motion = .half_page_down }, // Ctrl-d
        0x06 => .{ .motion = .page_down }, // Ctrl-f
        0x15 => .{ .motion = .half_page_up }, // Ctrl-u
        // actions (selection/confirm/cancel)
        'v' => .{ .action = .visual_toggle }, 'V' => .{ .action = .visual_line },
        0x16, 'R' => .{ .action = .visual_block }, // Ctrl-v / R
        'o' => .{ .action = .swap_end }, 'O' => .{ .action = .swap_end_other },
        0x1b => .{ .action = .clear }, // Esc — handler clears sel OR quits (state-dependent)
        'q', 0x03 => .{ .action = .quit }, // q / Ctrl-c
        0x0d, 0x0a, 'y' => .{ .action = .confirm }, // Enter (\r or \n) / y
        // search
        '/' => .{ .search = .start_forward }, '?' => .{ .search = .start_backward },
        'n' => .{ .search = .next }, 'N' => .{ .search = .prev },
        else => .ignore, // unmapped ⇒ swallow (feed resets the count, vim semantics)
    };
}
```

### The state machine: `Decoder` + `feed` (the count register + `gg` prefix)

```zig
/// Decoder state: the count being accumulated + a pending 'g' prefix. Reset on every finalized Key
/// (and on an ignored byte, which discards the count — vim: an unmapped key clears pending count).
/// One lives in the EventHandler's ctx (P3.M2/P3.M3) OR is loop-local in decode(driver).
pub const Decoder = struct {
    count: u32 = 0,
    has_count: bool = false,
    pending_g: bool = false,

    /// Produce the Key (count resolved to 1 when none typed), then reset all state. Infallible.
    fn finalize(self: *Decoder, kind: KeyKind) Key {
        const k = Key{ .count = if (self.has_count) self.count else 1, .kind = kind };
        self.count = 0; self.has_count = false; self.pending_g = false;
        return k;
    }
};

/// The CORE state machine. Feed ONE Event; return a Key when a complete command is recognized, or
/// null while accumulating (digit / lone 'g') / on a non-key event (.mouse/.eof) / on an ignored
/// byte. Infallible (no I/O) ⇒ `?Key`, NOT `!Key`. The driver decode() calls this WITHOUT `try`.
/// Order matters: resolve pending_g FIRST, then digits, then g-prefix-start, then the leaf decodeByte.
pub fn feed(self: *Decoder, ev: app.Event) ?Key {
    switch (ev) {
        .eof, .mouse => return null, // driver short-circuits eof; handler routes mouse to select FIRST
        .seq => |s| {
            const m = decodeSeq(s.slice()) orelse { // unknown seq ⇒ swallow + reset count
                self.count = 0; self.has_count = false; self.pending_g = false;
                return null;
            };
            return self.finalize(.{ .motion = m });
        },
        .key => |b| {
            // (1) resolve a pending 'g' prefix FIRST (so a digit/key after lone-g cancels cleanly)
            if (self.pending_g) {
                self.pending_g = false;
                if (b == 'g') return self.finalize(.{ .motion = .doc_top }); // gg (count carries)
                // else: fall through — re-process b below (digits/g-start/leaf)
            }
            // (2) digits extend the count. '1'-'9' always; '0' only if a count is already active.
            if (b >= '1' and b <= '9') {
                self.count = @min(self.count *% 10 +% (b - '0'), max_count);
                self.has_count = true;
                return null;
            }
            if (b == '0' and self.has_count) {
                self.count = @min(self.count *% 10, max_count);
                return null;
            }
            // (3) 'g' starts a prefix (read the next key). 'G' is handled by decodeByte (single key).
            if (b == 'g') { self.pending_g = true; return null; }
            // (4) leaf classification. ignore ⇒ swallow + reset count (vim discards pending count).
            switch (decodeByte(b)) {
                .ignore => { self.count = 0; self.has_count = false; self.pending_g = false; return null; },
                .motion => |m| return self.finalize(.{ .motion = m }),
                .action => |a| return self.finalize(.{ .action = a }),
                .search => |sr| return self.finalize(.{ .search = sr }),
            }
        },
    }
}
```
> NOTE on `*%`/`+%`: Zig 0.15.2 wrapping arithmetic operators (`*%`, `+%`) make the count math
> overflow-safe even before the `@min(…, max_count)` clamp (belt-and-suspenders; ReleaseFast is
> UB-adjacent on plain overflow). `b - '0'` is safe because `b >= '1'` is guaranteed in that branch.

### The driver + seam: `EventReader`, `SliceEventReader`, `InputEventReader`, `decode`

```zig
/// Mockable Event source — MIRRORS app.Input (NON-nullable ctx + one fn) which mirrors capture.Runner.
/// readEvent returns a FULL app.Event (eof = the .eof variant — NOT optional), exactly like app.readEvent.
pub const EventReader = struct {
    ctx: *anyopaque,
    readEventFn: *const fn (ctx: *anyopaque) anyerror!app.Event,
    pub fn readEvent(self: EventReader) anyerror!app.Event {
        return self.readEventFn(self.ctx);
    }
};

/// The literal contract fn: pull Events from `reader` until a complete Key is decoded. `.eof` ⇒
/// error.EndOfStream (region maps that to quit); `.mouse` ⇒ skip (the full loop routes mouse to
/// select.zig; decode(driver) is the keyboard path). Thin: ALL logic is in feed(). Tested via
/// SliceEventReader; InputEventReader + real stdin is compile-verified (mirrors app.FdInput).
pub fn decode(self: *Decoder, reader: EventReader) anyerror!Key {
    while (true) {
        const ev = try reader.readEvent();
        if (ev == .eof) return error.EndOfStream;
        if (ev == .mouse) continue; // mouse routed elsewhere in the full loop
        if (feed(self, ev)) |k| return k; // feed is infallible ⇒ NO `try`
        // else: accumulating (digit/g) or ignored — keep reading
    }
}

// TEST reader — yields Events from a slice, then .eof.
const SliceEventReader = struct {
    events: []const app.Event,
    idx: usize = 0,
    fn readEvent(ctx: *anyopaque) anyerror!app.Event {
        const self: *SliceEventReader = @ptrCast(@alignCast(ctx)); // @alignCast MANDATORY (0.15.2)
        if (self.idx >= self.events.len) return .eof;
        defer self.idx += 1;
        return self.events[self.idx];
    }
};

// PROD reader — wraps app.Input + app.readEvent. Compile-verified (real fd). region.zig (P3.M3)
// drives feed() from its own EventHandler under app.runEvents (the canonical path); this wrapper
// lets decode(driver) run against real stdin if a keyboard-only loop is ever wanted.
const InputEventReader = struct {
    input: app.Input,
    fn readEvent(ctx: *anyopaque) anyerror!app.Event {
        const self: *InputEventReader = @ptrCast(@alignCast(ctx));
        return app.readEvent(self.input); // app.readEvent returns app.Event (.eof on stdin close)
    }
};
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: CREATE src/tui/input.zig with the imports + the 5 public types (Motion, Action, Search,
        KeyKind, Key) + max_count — see Data models.
  - IMPORT: `const std = @import("std"); const app = @import("app.zig");` (app.zig is ONE dir up
    from input.zig? NO — both are in src/tui/, so `@import("app.zig")` is correct, sibling file).
  - NAMING: CamelCase types; snake_case fields/variants. Key.count defaults to 1 (u32).
  - GOTCHA: NO ghostty-vt import (keeps the module test-safe as separate fns). Motion has 21
    variants (the full PRD §7.2 set + line_start/line_end for Home/End).

Task 2: ADD decodeSeq(seq: []const u8) ?Motion — see PURE leaf: decodeSeq.
  - IMPLEMENT: SS3 (`\x1bO.`, no params) + CSI (`\x1b[..)`: split params on ';', final byte, mod
    code = 2nd param). Arrows (CSI+SS3) + Ctrl (mod 5) + Home/End (H/F/OH/OF + ~ 1/4/7/8) + PgUp/Dn
    (~ 5/6). Everything else (Alt+char, Insert 2~, Delete 3~, Shift-Tab Z, Shift/Alt-arrow) ⇒ null.
  - GOTCHA: `seq[0]` MUST be 0x1b (app.zig's .seq includes the leading ESC). Guard `seq.len < 3`.
    parseInt each param token; `catch return null` on malformed. Cap parsed params at 2 (≥3 ⇒ null).
  - GOTCHA: Ctrl = mod code 5 (the SECOND param after the cursor-key '1'); Shift=2/Alt=3 ⇒ null for
    arrows. ~ keys use p[0] (the FIRST/only param) as the selector (5=PgUp,6=PgDn,1/7=Home,4/8=End).

Task 3: ADD ByteClass + decodeByte(b: u8) ByteClass — see PURE leaf: decodeByte.
  - IMPLEMENT: the full motion/action/search byte table (§6/§7 of external_keyseq_vim.md); `else ⇒
    .ignore`. Enter accepts BOTH 0x0d and 0x0a. Esc (0x1b) ⇒ .clear (handler decides clear-vs-quit).
  - GOTCHA: '0'⇒line_start IS here (feed only intercepts '0' when has_count). 'g' (0x67) is NOT
    here (feed's pending_g); 'G' (0x47) IS here (doc_bottom). Ctrl-v = 0x16 AND 'R' ⇒ visual_block.

Task 4: ADD Decoder + feed(self, ev: app.Event) ?Key + finalize — see The state machine.
  - IMPLEMENT: the 4-step flow (pending_g FIRST ⇒ digits ⇒ g-start ⇒ leaf decodeByte). finalize
    resolves count (has_count?count:1) + resets state. ignore ⇒ reset + null. .eof/.mouse ⇒ null.
  - GOTCHA: feed is INFALLIBLE ⇒ `?Key` (NOT `!Key); decode() calls it WITHOUT `try`. pending_g must
    be resolved BEFORE the digit check (so `g5` cancels g and '5' starts a fresh count). Use `*%`/`+%`
    + @min(max_count) for the count math. `ev.seq.slice()` (ev is an lvalue param ⇒ safe).

Task 5: ADD EventReader + SliceEventReader + InputEventReader + decode(self, reader) !Key — see the
        driver + seam.
  - FOLLOW pattern: src/capture.zig:58-66 Runner (ctx:*anyopaque NON-nullable + fn + thin method) for
    EventReader; src/tui/app.zig FdInput/SliceInput for the impl structs (@ptrCast(@alignCast)).
  - GOTCHA: readEvent returns `anyerror!app.Event` (FULL Event; eof = .eof variant, NOT optional).
    decode checks `ev == .eof` ⇒ error.EndOfStream BEFORE feed (else .eof⇒null⇒infinite loop). `.mouse`
    ⇒ continue. SliceEventReader yields slice then `.eof`. Impl structs are stack `var` for &x ⇒ *T.

Task 6: ADD the unit tests — see Validation Loop L2. ALL as SEPARATE `test` fns (input.zig is
        ghostty-free ⇒ safe; mirrors app.zig). decodeSeq (every form), decodeByte (every byte),
        feed (counts/gg/0/cancel/seq-with-count/eof/mouse), decode via SliceEventReader.
  - GOTCHA: build app.Event values directly: `.{ .key = 'j' }`, `.{ .seq = app.makeEscSeq("\x1b[A") }`
    (app.makeEscSeq is the shipped PURE helper), `.{ .mouse = ... }`, `.eof`. Compare Key/ByteClass/
    ?Motion with std.testing.expectEqual (structural equality). For decode()'s eof use `expectError(
    error.EndOfStream, ...)`. Wire SliceEventReader via `.{ .ctx = @ptrCast(&r), .readEventFn =
    SliceEventReader.readEvent }` (r is a stack `var`).

Task 7: EDIT src/main.zig — add ONE line to the test {} block (main.zig:476): after the existing
        `_ = @import("tui/view.zig");` (main.zig:493), add:
            // P3.M2.T1.S1: keep tui/input.zig unit tests reachable (region.zig, its caller, does
            // NOT exist yet — without this import the tests are unreachable). input.zig is
            // ghostty-free ⇒ separate test fns (no cross-test GOTCHA).
            _ = @import("tui/input.zig");
  - PRESERVE: every other line of main.zig. NO exe-path import needed for v1 (region.zig will import
    input.zig in P3.M3); the test-block import makes the tests reachable NOW.
  - GOTCHA: do NOT touch the panic override / dispatch / any other import. ONLY the test {} block.
```

### Implementation Patterns & Key Details

```zig
// feed's invariant ordering (resolve pending_g BEFORE digits — makes `5gg`/`g5`/`10j` all correct):
if (self.pending_g) { self.pending_g = false; if (b == 'g') return self.finalize(.{ .motion = .doc_top }); }
if (b >= '1' and b <= '9') { self.count = @min(self.count *% 10 +% (b - '0'), max_count); self.has_count = true; return null; }
if (b == '0' and self.has_count) { self.count = @min(self.count *% 10, max_count); return null; }
if (b == 'g') { self.pending_g = true; return null; }
switch (decodeByte(b)) { .ignore => { /* reset; null */ }, .motion => |m| ..., .action => ..., .search => ... }

// decodeSeq's modifier extraction (Ctrl = 2nd param == 5):
const mod = if (np >= 2) p[1] else 0;
'A','B','C','D' => switch (mod) { 0 => plain_arrow, 5 => ctrl_arrow_word_or_halfpage, else => null }

// decode() eof short-circuit (do NOT feed .eof — feed returns null on it ⇒ infinite loop):
const ev = try reader.readEvent();
if (ev == .eof) return error.EndOfStream;
if (ev == .mouse) continue;
if (feed(self, ev)) |k| return k; // feed infallible ⇒ no `try`

// Building Events in tests (app.makeEscSeq is the shipped PURE helper):
const evs = [_]app.Event{ .{ .key = '5' }, .{ .key = 'j' } };
const ev_arrow = app.Event{ .seq = app.makeEscSeq("\x1b[1;5D") }; // Ctrl-Left
```

### Integration Points

```yaml
BUILD:
  - change: NONE. input.zig is under src/tui/ (root module). Its tests are pulled into the test
    binary via the ONE new main.zig test-block import (Task 7). No build.zig/build.zig.zon edit. No
    new deps (std + app only).
  - verify: `zig build -Doptimize=ReleaseFast` succeeds; `zig build test -Doptimize=ReleaseFast` GREEN.

MAIN.ZIG:
  - change: +1 line in the `test {}` block (Task 7). Nothing else. main.zig already wires tui/app.zig
    (import + panic override + test import) and tui/view.zig (test import) from prior subtasks.

APP.ZIG:
  - change: NONE. input.zig CONSUMES app.zig's shipped Event/EscSeq/Input/readEvent/makeEscSeq/
    max_esc_len surface as-is. app.zig is the INPUT contract; do NOT edit it.

FUTURE CONSUMERS (do NOT implement now — boundary docs only):
  - P3.M2.T1.S2 (motions): consumes Key — switch (key.kind) { .motion => |m| moveCursor(m, key.count),
    .action => ..., .search => |s| if (s == .start_forward or .start_backward) enterPatternMode() ... }.
    It owns cursor/scroll (calling view.zig's scroll fns from P3.M1.T2.S2) + the search scan
    (view.findMatches from P3.M1.T2.S2) + bracket/paragraph jumps. It collects the search PATTERN
    directly from the raw event stream (decoder is idle then — search emits START only).
  - P3.M2.T2 (select): owns the selection model; reads mouse events (app.zig decodes them) + the
    .action keys (visual_toggle/line/block/swap/clear). .clear (Esc) ⇒ clear selection OR quit.
  - P3.M3 (region.zig): app.runEvents(handler) where the handler owns a Decoder; per Event: route
    .mouse → select; .key/.seq → if (decoder.feed(ev)) |key| dispatch(key). (OR use decode(driver) for
    a keyboard-only path; canonical is feed via the EventHandler.)
```

## Validation Loop

> **MANDATORY:** every `zig build` / `zig build test` below uses `-Doptimize=ReleaseFast`
> (PRD §15 / main.zig Gotcha: Debug-mode `zig build test` hits the Zig linker bug
> `R_X86_64_PC64` with the bundled C++ SIMD libs; ReleaseFast is unaffected).

### Level 1: Syntax & Style (Immediate Feedback)

```bash
cd /home/dustin/projects/tmux-2html
# Compile the whole binary in ReleaseFast — proof the new module + the app.zig surface consumption +
# the EventReader/@ptrCast(@alignCast) seam are correct.
zig build -Doptimize=ReleaseFast
# Expected: zero errors. If an app.Event/EscSeq/Input symbol, the @import("app.zig") path, the
# tagged-union switch/capture, or the reader fn-pointer type is wrong, it fails HERE — read the
# error, fix against research/design_notes.md + src/tui/app.zig.
```

### Level 2: Unit Tests (the PURE core + the slice-driven driver — all separate `test` fns)

```bash
cd /home/dustin/projects/tmux-2html
zig build test -Doptimize=ReleaseFast
# Expected: all GREEN — input.zig's new tests + ZERO regressions (app.zig, view.zig, render.zig,
# palette.zig, capture.zig, golden_test.zig, main.zig).
#
# The tests to ADD (in src/tui/input.zig, as SEPARATE `test` fns — ghostty-free ⇒ safe):
#   decodeSeq (CSI + SS3 + modifiers + ~):
#     - "\x1b[A"⇒up, "\x1b[B"⇒down, "\x1b[C"⇒right, "\x1b[D"⇒left.
#     - "\x1bOA"⇒up, "\x1bOB"⇒down, "\x1bOC"⇒right, "\x1bOD"⇒left (SS3).
#     - "\x1b[1;5A"⇒half_page_up, "\x1b[1;5B"⇒half_page_down, "\x1b[1;5C"⇒word_fwd, "\x1b[1;5D"⇒word_back.
#     - "\x1b[H"⇒line_start, "\x1b[F"⇒line_end, "\x1bOH"⇒line_start, "\x1bOF"⇒line_end.
#     - "\x1b[1~"⇒line_start, "\x1b[4~"⇒line_end, "\x1b[7~"⇒line_start, "\x1b[8~"⇒line_end.
#     - "\x1b[5~"⇒page_up, "\x1b[6~"⇒page_down.
#     - null: "\x1bx" (Alt+char), "\x1b[2~" (Insert), "\x1b[3~" (Delete), "\x1b[Z" (Shift-Tab),
#       "\x1b[1;2A" (Shift-Up), "\x1b[1;3A" (Alt-Up), "\x1b" (len 1, though app won't send it).
#   decodeByte (every variant):
#     - motions: 'h'⇒left,'l'⇒right,'j'⇒down,'k'⇒up,'w'⇒word_fwd,'b'⇒word_back,'e'⇒word_end,
#       '0'⇒line_start,'^'⇒first_nonblank,'$'⇒line_end,'G'⇒doc_bottom,'H'⇒viewport_top,
#       'M'⇒viewport_mid,'L'⇒viewport_bottom,'{'⇒paragraph_back,'}'⇒paragraph_fwd,'%'⇒match_bracket.
#     - Ctrl bytes: 0x02⇒page_up, 0x04⇒half_page_down, 0x06⇒page_down, 0x15⇒half_page_up.
#     - actions: 'v'⇒visual_toggle,'V'⇒visual_line, 0x16⇒visual_block,'R'⇒visual_block,
#       'o'⇒swap_end,'O'⇒swap_end_other, 0x1b⇒clear, 'q'⇒quit, 0x03⇒quit, 0x0d⇒confirm, 0x0a⇒confirm,
#       'y'⇒confirm.
#     - search: '/'⇒start_forward,'?'⇒start_backward,'n'⇒next,'N'⇒prev.
#     - ignore: 'x','X','1' (digit handled by feed, but decodeByte sees only non-intercepted; '1'
#       would be .ignore if reached), ' ', 0xff.
#   feed (the state machine — feed app.Event values to a fresh Decoder each case):
#     - count: {'5','j'} (feed both) ⇒ Key{5, motion .down}; {'1','0','j'} ⇒ Key{10, .down};
#       {'0'} ⇒ Key{1, .line_start} (leading 0 = motion, NO count); {'5','0','j'} ⇒ Key{50, .down}.
#     - gg: {'g','g'} ⇒ Key{1, .doc_top}; {'5','g','g'} ⇒ Key{5, .doc_top} (count carries);
#       {'g','j'} ⇒ 'g' cancelled ⇒ Key{1, .down} (the 'j' classified fresh); {'g','5','j'} ⇒
#       'g' cancelled, count 5 ⇒ Key{5, .down}.
#     - unknown-after-count: {'5','x'} ⇒ 'x' ignored ⇒ feed returns null for 'x' AND count reset
#       (feed a 'j' after ⇒ Key{1,.down}, NOT 5 — count was discarded).
#     - seq with count: {'5', seq "\x1b[B"} ⇒ Key{5, .down} (arrow ≡ j, count applies).
#     - eof/mouse: feed(.eof) ⇒ null (state unchanged); feed(.mouse press) ⇒ null (state unchanged).
#   decode(driver) via SliceEventReader:
#     - [{'5'},{'j'}] ⇒ Key{5,.down}; [{'g'},{'g'}] ⇒ Key{1,.doc_top}; [seq "\x1b[A"] ⇒ Key{1,.up};
#       [{'5'}, seq "\x1b[1;5D"] ⇒ Key{5,.word_back}.
#     - [] (empty) ⇒ error.EndOfStream; [{'j'},] then eof ⇒ Key{1,.down} on the first, then a 2nd
#       decode() call on the now-empty reader ⇒ error.EndOfStream.
#     - [.mouse press, {'q'}] ⇒ the mouse is skipped, then 'q' ⇒ Key{1,.quit} (mouse not lost to
#       decode; but NOTE decode skips mouse — the full loop routes it; this asserts skip-then-key).
```

### Level 3: Integration / manual check (the live tty is deferred to P3.M3)

> input.zig's fns are PURE or slice-tested (Level 2). The LIVE key decode (real arrow keys / counts
> / gg in the popup pty) is proven when region.zig (P3.M3) wires `enter()`→`runEvents(handler)`→
> `feed`→motion/select in an isolated tmux server (PRD §0/§15). **Do NOT wire region here.** This
> Level 3 asserts structure + the seam is wired (no live terminal).

```bash
cd /home/dustin/projects/tmux-2html
# (a) Confirm the ONE new file + the ONE main.zig line (nothing else touched):
git status --short src/ build.zig build.zig.zon            # ONLY src/tui/input.zig (new) + src/main.zig (modified)
# (b) Confirm the public surface exists:
grep -n 'pub const Motion = enum\|pub const Action = enum\|pub const Search = enum\|pub const KeyKind = union\|pub const Key = struct' src/tui/input.zig
grep -n 'pub fn decodeSeq(' src/tui/input.zig
grep -n 'pub fn decodeByte(' src/tui/input.zig
grep -n 'pub fn feed(' src/tui/input.zig
grep -n 'pub const EventReader = struct\|pub fn decode(self: \*Decoder, reader: EventReader)' src/tui/input.zig
# (c) Confirm input.zig is ghostty-free (keeps its tests safe as separate fns) + imports app:
grep -n '@import' src/tui/input.zig                        # std + app.zig only; NO ghostty-vt
! grep -n 'ghostty' src/tui/input.zig                      # no ghostty (grep exits 1)
# (d) Confirm the main.zig edit is ONLY the test-block import:
grep -n '@import("tui/input.zig")' src/main.zig            # exactly ONE occurrence, in test {}
# (e) Confirm app.zig is UNCHANGED (the INPUT contract — consumed, not edited):
git diff src/tui/app.zig | head                            # empty ⇒ app.zig untouched
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Confirm the decode boundary is correct (the work item's three responsibilities):
#   1. ESC sequences decoded to motions; 2. plain keys decoded; 3. count prefix parsed.
grep -n 'pub fn decodeSeq(' src/tui/input.zig              # pillar 1 (seq → motion)
grep -n 'pub fn decodeByte(' src/tui/input.zig             # pillar 2 (byte → motion/action/search)
grep -n 'has_count\|pending_g\|pub fn feed(' src/tui/input.zig  # pillar 3 (count register + gg)
# Confirm the leading-0 rule (the #1 decode pitfall) is handled:
grep -n "b == '0' and self.has_count" src/tui/input.zig    # 0 extends count ONLY when active
grep -n "'0' => .{ .motion = .line_start }" src/tui/input.zig  # else 0 is line_start motion
# Confirm Ctrl-modifier arrows (the work item's named `\x1b[1;5D`) decode:
grep -n "1;5\|mod == 5\|=> 5 =>" src/tui/input.zig         # Ctrl modifier → word/half-page
# Confirm BOTH CSI and SS3 arrows are accepted (popup pty may emit either):
grep -n "seq\[1\] == 'O'\|seq\[1\] == '\['" src/tui/input.zig
# Confirm the normalization (arrows ≡ hjkl — collapse to ONE motion variant):
grep -n "'A' => .up, 'B' => .down, 'C' => .right, 'D' => .left' src/tui/input.zig  # CSI arrows
```

## Final Validation Checklist

### Technical Validation

- [ ] `zig build -Doptimize=ReleaseFast` succeeds (new module + app.zig surface + EventReader seam correct).
- [ ] `zig build test -Doptimize=ReleaseFast` is GREEN — input.zig's tests (decodeSeq/decodeByte/feed/decode) + ZERO regressions.
- [ ] input.zig imports ONLY `std` + `app.zig` (ghostty-free ⇒ separate test fns safe).
- [ ] ONE new file (`src/tui/input.zig`) + ONE main.zig test-block line; NO build.zig/build.zig.zon change; NO new deps; app.zig UNCHANGED.

### Feature Validation

- [ ] `decodeSeq` decodes every accepted form (CSI+SS3 arrows, `1;5` Ctrl-mods, H/F + `~` Home/End, `5~`/`6~` PgUp/Dn) to the right Motion; rejects Alt+char/Insert/Delete/Shift-Tab/Shift-arrow (null).
- [ ] `decodeByte` maps every vim motion/action/search byte to the right variant; unmapped ⇒ ignore; Enter accepts `\r`+`\n`.
- [ ] `feed` parses counts (`5j`⇒5, `10j`⇒10, leading `0`⇒line_start-no-count), `gg`⇒doc_top (count carries: `5gg`⇒5), lone-`g`+non-g⇒cancel+reprocess, unknown-after-count⇒swallow+reset, arrow `.seq`⇒motion-with-count, `.eof`/`.mouse`⇒null.
- [ ] `decode(driver)` via SliceEventReader: key slices ⇒ Key; empty/eof ⇒ `error.EndOfStream`; `.mouse` skipped.

### Code Quality Validation

- [ ] `feed` ordering correct (pending_g FIRST, then digits, then g-start, then leaf) — `5gg`/`g5`/`10j` all behave vim-faithfully.
- [ ] `feed` is infallible (`?Key`); `decode()` calls it without `try`; count math uses `*%`/`+%` + `@min(max_count)`.
- [ ] `EventReader` mirrors `app.Input`/`capture.Runner` (NON-nullable ctx + fn + thin method); impls use `@ptrCast(@alignCast)` + stack `var`.
- [ ] No new deps; `app.zig` consumed as-is (the INPUT contract); main.zig edit is the test block only.

### Documentation & Deployment

- [ ] Code is self-documenting (decodeSeq cites xterm forms; decodeByte cites the vim key; feed cites the count/`gg`/leading-0 rules; each public type documents its consumer).
- [ ] The `Motion`/`Action`/`Search`/`Key` types + `Decoder`/`feed` document their forward-contract role (S2 consumes Key; P3.M3 wires the loop).

---

## Anti-Patterns to Avoid

- ❌ Don't re-decode mouse — app.zig ALREADY classifies `\x1b[<…` as `.mouse` (decoded). input.zig's `.seq` is ONLY non-mouse sequences. feed is a no-op for `.mouse`; decode() skips it.
- ❌ Don't make `feed` return an error union — it does NO I/O, so it's `?Key` (infallible). The driver `decode()` is the only `!` fn (it does reader I/O).
- ❌ Don't let a leading `0` start a count — `0` is the `line_start` motion unless it follows a non-zero digit (the #1 decode pitfall; vim rule).
- ❌ Don't confuse `g` (prefix → `gg`) with `G` (single key → doc_bottom). And don't forget the count carries across the `g` prefix (`5gg` ⇒ line 5).
- ❌ Don't feed `.eof` to `feed` in a loop — `decode()` short-circuits `.eof` ⇒ `error.EndOfStream` BEFORE calling feed (else `.eof`⇒null⇒infinite loop).
- ❌ Don't accept only CSI arrows OR only SS3 arrows — the popup pty may emit either (`\x1b[A` vs `\x1bOA`); decodeSeq handles both.
- ❌ Don't import ghostty-vt into input.zig — it must stay std+app only so its tests are safe as separate `test` fns (no cross-test GOTCHA).
- ❌ Don't edit `app.zig` — it's the INPUT contract (shipped, consumed as-is). And don't edit anything but the ONE main.zig test-block line.
