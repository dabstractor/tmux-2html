//! input.zig — the key decoder for the copy-mode TUI (PRD §7.2/§7.4/§7.5; arch tui_region.md §3).
//!
//! The module that turns app.zig's typed `Event` stream (`.key` / `.seq` / `.eof`, SHIPPED by
//! P3.M1.T1.S2) into a **normalized `Key`** (`{ count, motion | action | search }`) consumed by
//! the motion engine (P3.M2.T1.S2). It does three things:
//!   1. Decode ESC-prefixed sequences (arrows, Ctrl-mods, Home/End, PgUp/Dn) → motions.
//!   2. Decode plain keys (the vim motion set + selection/confirm/cancel actions + search).
//!   3. Parse the count prefix + maintain a count register (leading digits ⇒ count; leading `0`
//!      is the line_start motion; `gg` is a two-key command whose count carries through).
//!
//! Layering (arch §3): app.zig ALREADY classifies `\x1b[<…` ⇒ `.mouse` (decoded) and other
//! `\x1b…` ⇒ `.seq` (RAW, undecoded, leading `\x1b` INCLUDED). So this module ONLY does
//! Event → Key. The lone-Esc disambiguation + mouse decode are DONE (in app.zig); do NOT
//! re-handle them here.
//!
//! Ghostty-free: imports ONLY `std` + `app.zig`, so its tests are SAFE as SEPARATE `test` fns
//! (no single-test-scope GOTCHA that constrains render.zig/golden_test.zig). No allocation —
//! the decoder is stack-only (app.Event's EscSeq is a fixed inline buffer).

const std = @import("std");
const app = @import("app.zig"); // Event, EscSeq, Input, readEvent, makeEscSeq, max_esc_len — SHIPPED (consume as-is)

// ============================================================================
// Public types — the normalized key contract consumed by the motion engine (S2) + select (T2).
// ============================================================================

/// Normalized vim motions (PRD §7.2 + decoded arrows/Ctrl-mods/Home/End/PgUp/Dn). The DECODER
/// collapses equivalent inputs to ONE variant (h ≡ ← ≡ `\x1b[D` ≡ `\x1b[OD` ⇒ .left). S2
/// (P3.M2.T1.S2) switches on this enum instead of re-parsing raw bytes/seqs.
pub const Motion = enum {
    left, // h / ← / \x1b[D / \x1b[OD
    right, // l / → / \x1b[C / \x1b[OC
    up, // k / ↑ / \x1b[A / \x1b[OA
    down, // j / ↓ / \x1b[B / \x1b[OB
    word_fwd, // w / Ctrl-→ (\x1b[1;5C)
    word_back, // b / Ctrl-← (\x1b[1;5D)
    word_end, // e
    line_start, // 0 / Home (\x1b[H, \x1bOH, \x1b[1~, \x1b[7~)
    first_nonblank, // ^
    line_end, // $ / End (\x1b[F, \x1bOF, \x1b[4~, \x1b[8~)
    doc_top, // gg (two-key; count carries: 5gg ⇒ doc_top, count 5)
    doc_bottom, // G
    half_page_down, // Ctrl-d / Ctrl-↓ (\x1b[1;5B)
    half_page_up, // Ctrl-u / Ctrl-↑ (\x1b[1;5A)
    page_down, // Ctrl-f / PgDn (\x1b[6~)
    page_up, // Ctrl-b / PgUp (\x1b[5~)
    viewport_top, // H
    viewport_mid, // M
    viewport_bottom, // L
    paragraph_back, // {
    paragraph_fwd, // }
    match_bracket, // %
};

/// Selection/confirm/cancel actions (PRD §7.4/§7.5). `.clear` (Esc) is state-dependent: the
/// handler clears an active selection OR quits when there is nothing to clear (design_notes §3).
pub const Action = enum {
    visual_toggle, // v
    visual_line, // V
    visual_block, // Ctrl-v (0x16) / R
    swap_end, // o
    swap_end_other, // O
    clear, // Esc (0x1b) — handler clears selection OR quits (state-dependent)
    quit, // q / Ctrl-c (0x03)
    confirm, // Enter (0x0d / 0x0a) / y
};

/// Search actions (PRD §7.3). `.start_forward` / `.start_backward` enter pattern-typing; the
/// decoder emits START only — S2 collects the pattern directly from the raw stream (decoder idle).
pub const Search = enum {
    start_forward, // /
    start_backward, // ?
    next, // n
    prev, // N
};

/// The kind of a decoded Key. S2 dispatches on the active tag.
pub const KeyKind = union(enum) {
    motion: Motion,
    action: Action,
    search: Search,
};

/// A fully-decoded key command. `count` is the multiplier (≥1); 1 when no digits were typed.
/// `0` never appears as a count (leading `0` = line_start motion, the #1 decode pitfall). The
/// count is resolved to a value here (NOT left as `?u32`) so S2 just multiplies — no optionality.
/// Capped at `max_count` (pathological digit streams can't overflow u32).
pub const Key = struct {
    count: u32 = 1,
    kind: KeyKind,
};

/// Absurd-count clamp (prevents `count*10` u32 overflow from pathological digit streams). Vim
/// itself caps counts well below this; the cap is a safety bound, not a UX feature.
pub const max_count: u32 = 1_000_000;

// ============================================================================
// PURE leaf: decodeSeq — map a COMPLETE raw ESC sequence to a Motion (or null).
// Source of every fact: research/external_keyseq_vim.md §1-§4 (xterm ctlseqs, authoritative).
// ============================================================================

/// PURE: map a COMPLETE raw ESC sequence (INCLUDING the leading 0x1b, as app.zig's `.seq` payload
/// provides it) to a Motion, or null if it is not a motion this TUI recognizes.
///
/// Grammar (xterm ctlseqs):
///   CSI  `\x1b[<params><final>`  (params split on ';', each a decimal; final byte ∈ 0x40..0x7e)
///   SS3  `\x1b O <final>`        (no params — application cursor keys / Home/End)
///   Alt+char `\x1b<x>`           (2-byte) ⇒ NOT a motion ⇒ null
///
/// Accepted forms (research/external_keyseq_vim.md):
///   Arrows: `\x1b[A/B/C/D` (CSI) AND `\x1bOA/B/C/D` (SS3) ⇒ up/down/right/left.
///   Ctrl-modified arrows: `\x1b[1;5A/B/C/D` (modifier code 5 = Ctrl) ⇒
///     A⇒half_page_up, B⇒half_page_down, C⇒word_fwd, D⇒word_back. (Shift=2/Alt=3/etc ⇒ null.)
///   Home: `\x1b[H`, `\x1bOH`, `\x1b[1~`, `\x1b[7~` ⇒ line_start.
///   End:  `\x1b[F`, `\x1bOF`, `\x1b[4~`, `\x1b[8~` ⇒ line_end.
///   PgUp: `\x1b[5~` ⇒ page_up.  PgDn: `\x1b[6~` ⇒ page_down.
///   Rejected (null): Alt+char (`\x1bx`), Insert (`\x1b[2~`), Delete (`\x1b[3~`), Shift-Tab
///     (`\x1b[Z`), Shift/Alt arrows (`\x1b[1;2A`, `\x1b[1;3A`).
pub fn decodeSeq(seq: []const u8) ?Motion {
    // Need ESC + introducer + ≥1 final byte. seq[0] MUST be 0x1b (app.zig includes the leading ESC).
    if (seq.len < 3 or seq[0] != 0x1b) return null;

    if (seq[1] == 'O') { // SS3 application cursor keys / Home-End: ESC O <final> (no params)
        return switch (seq[2]) {
            'A' => .up,
            'B' => .down,
            'C' => .right,
            'D' => .left,
            'H' => .line_start, // Home (SS3)
            'F' => .line_end, // End (SS3)
            else => null,
        };
    }

    if (seq[1] != '[') return null; // Alt+char (`\x1b<x>`) or other ⇒ not a motion (ignore)

    const final = seq[seq.len - 1];
    const params = seq[2 .. seq.len - 1]; // bytes between '[' and the final byte (may be empty)

    // Parse up to 2 params (cursor keys use 0 or 1 params; `~` keys use 1; modifiers add a 2nd).
    var p = [_]u32{ 0, 0 };
    var np: usize = 0;
    if (params.len > 0) {
        var it = std.mem.splitScalar(u8, params, ';');
        while (it.next()) |tok| {
            if (np >= 2) return null; // ≥3 params ⇒ unknown
            p[np] = std.fmt.parseInt(u32, tok, 10) catch return null; // malformed ⇒ unknown
            np += 1;
        }
    }

    const mod = if (np >= 2) p[1] else 0; // modifier code (2=Shift, 3=Alt, 5=Ctrl, ...)

    switch (final) {
        'A', 'B', 'C', 'D' => { // arrows; Ctrl-mod (1;5) ⇒ word/half-page; Shift/Alt/other ⇒ null
            const m: Motion = switch (final) {
                'A' => .up,
                'B' => .down,
                'C' => .right,
                'D' => .left,
                else => unreachable, // switch is exhaustive over 'A'..'D'
            };
            return switch (mod) {
                0 => m, // plain arrow (≡ hjkl)
                5 => switch (final) { // Ctrl-arrow
                    'A' => .half_page_up,
                    'B' => .half_page_down,
                    'C' => .word_fwd,
                    'D' => .word_back,
                    else => unreachable,
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
                1, 7 => .line_start, // Home (xterm / rxvt)
                4, 8 => .line_end, // End (xterm / rxvt)
                else => null, // 2=Insert, 3=Delete, etc. ⇒ not a motion
            };
        },
        else => return null, // `\x1b[Z` (Shift-Tab) etc. ⇒ not a motion
    }
}

// ============================================================================
// PURE leaf: decodeByte — classify ONE .key byte → motion/action/search/ignore.
// ============================================================================

/// The classification of a single `.key` byte. `.ignore` ⇒ unmapped (swallow + reset count).
pub const ByteClass = union(enum) { motion: Motion, action: Action, search: Search, ignore };

/// PURE leaf classification of ONE `.key` byte (NOT a digit, NOT handled by feed's `g`-prefix).
///
/// Motions: the vim set (`h j k l w b e 0 ^ $ G H M L { } %`) + Ctrl control bytes
/// (0x02=Ctrl-b⇒page_up, 0x04=Ctrl-d⇒half_page_down, 0x06=Ctrl-f⇒page_down, 0x15=Ctrl-u⇒
/// half_page_up). `G` (0x47) IS here (⇒ doc_bottom, single key); `g` (0x67) is NOT here (feed's
/// pending_g handles the two-key `gg`). The digit `0` IS here (⇒ line_start) — feed only
/// intercepts `0` when extending an active count.
///
/// Actions: `v`⇒visual_toggle, `V`⇒visual_line, Ctrl-v (0x16) / `R`⇒visual_block, `o`⇒swap_end,
/// `O`⇒swap_end_other, Esc (0x1b)⇒clear, `q` / Ctrl-c (0x03)⇒quit, Enter (0x0d OR 0x0a) / `y`⇒confirm.
///
/// Search: `/`⇒start_forward, `?`⇒start_backward, `n`⇒next, `N`⇒prev.
///
/// Everything else ⇒ `.ignore` (feed resets the count, vim semantics).
pub fn decodeByte(b: u8) ByteClass {
    return switch (b) {
        // motions — vim keys + Ctrl control bytes
        'h' => .{ .motion = .left },
        'l' => .{ .motion = .right },
        'j' => .{ .motion = .down },
        'k' => .{ .motion = .up },
        'w' => .{ .motion = .word_fwd },
        'b' => .{ .motion = .word_back },
        'e' => .{ .motion = .word_end },
        '0' => .{ .motion = .line_start },
        '^' => .{ .motion = .first_nonblank },
        '$' => .{ .motion = .line_end },
        'G' => .{ .motion = .doc_bottom },
        'H' => .{ .motion = .viewport_top },
        'M' => .{ .motion = .viewport_mid },
        'L' => .{ .motion = .viewport_bottom },
        '{' => .{ .motion = .paragraph_back },
        '}' => .{ .motion = .paragraph_fwd },
        '%' => .{ .motion = .match_bracket },
        0x02 => .{ .motion = .page_up }, // Ctrl-b
        0x04 => .{ .motion = .half_page_down }, // Ctrl-d
        0x06 => .{ .motion = .page_down }, // Ctrl-f
        0x15 => .{ .motion = .half_page_up }, // Ctrl-u
        // actions — selection / confirm / cancel
        'v' => .{ .action = .visual_toggle },
        'V' => .{ .action = .visual_line },
        0x16, 'R' => .{ .action = .visual_block }, // Ctrl-v (0x16) / R
        'o' => .{ .action = .swap_end },
        'O' => .{ .action = .swap_end_other },
        0x1b => .{ .action = .clear }, // Esc — handler clears sel OR quits (state-dependent)
        'q', 0x03 => .{ .action = .quit }, // q / Ctrl-c
        0x0d, 0x0a, 'y' => .{ .action = .confirm }, // Enter (\r or \n) / y
        // search
        '/' => .{ .search = .start_forward },
        '?' => .{ .search = .start_backward },
        'n' => .{ .search = .next },
        'N' => .{ .search = .prev },
        else => .ignore, // unmapped ⇒ swallow (feed resets the count, vim semantics)
    };
}

// ============================================================================
// The state machine: Decoder + feed — the count register + `gg` prefix.
// PURE-ish (stateful, no I/O) ⇒ fully unit-testable. Infallible ⇒ returns ?Key (NOT !Key).
// ============================================================================

/// Decoder state: the count being accumulated + a pending `g` prefix. Reset on every finalized
/// Key (and on an ignored byte, which discards the count — vim: an unmapped key clears pending
/// count). One lives in the EventHandler's ctx (P3.M2/P3.M3) OR is loop-local in decode(driver).
pub const Decoder = struct {
    count: u32 = 0,
    has_count: bool = false,
    pending_g: bool = false,

    /// Produce the Key (count resolved to 1 when none typed), then reset ALL state. Infallible.
    fn finalize(self: *Decoder, kind: KeyKind) Key {
        const k = Key{ .count = if (self.has_count) self.count else 1, .kind = kind };
        self.count = 0;
        self.has_count = false;
        self.pending_g = false;
        return k;
    }

    /// Reset count + pending_g (used on unknown seq / ignored byte — vim discards pending count).
    fn reset(self: *Decoder) void {
        self.count = 0;
        self.has_count = false;
        self.pending_g = false;
    }
};

/// The CORE state machine. Feed ONE `app.Event`; return a `Key` when a complete command is
/// recognized, or `null` while accumulating (digit / lone `g`) / on a non-key event
/// (`.mouse` / `.eof`) / on an ignored byte.
///
/// Infallible (no I/O) ⇒ returns `?Key` (optional), NOT an error union. The driver `decode()`
/// calls this WITHOUT `try`: `if (feed(self, ev)) |k| return k;`.
///
/// Ordering matters (makes `5gg` / `g5` / `10j` all behave vim-faithfully):
///   (1) resolve a pending `g` prefix FIRST (so a key after a lone-`g` cancels cleanly),
///   (2) digits extend the count (`1`-`9` always; `0` only if a count is already active — the
///       leading-`0` rule, #1 decode pitfall),
///   (3) `g` starts a prefix (read the next key); `G` is handled by decodeByte (single key),
///   (4) leaf classification via decodeByte — `.ignore` ⇒ swallow + reset count.
pub fn feed(self: *Decoder, ev: app.Event) ?Key {
    switch (ev) {
        .eof, .mouse => return null, // driver short-circuits eof; handler routes mouse to select FIRST
        .seq => |s| {
            const m = decodeSeq(s.slice()) orelse { // unknown seq ⇒ swallow + reset count
                self.reset();
                return null;
            };
            return self.finalize(.{ .motion = m });
        },
        .key => |b| {
            // (1) resolve a pending 'g' prefix FIRST (so a key after lone-g cancels cleanly).
            if (self.pending_g) {
                self.pending_g = false;
                if (b == 'g') return self.finalize(.{ .motion = .doc_top }); // gg (count carries)
                // else: fall through — re-process b below (digits / g-start / leaf)
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
            if (b == 'g') {
                self.pending_g = true;
                return null;
            }
            // (4) leaf classification. ignore ⇒ swallow + reset count (vim discards pending count).
            switch (decodeByte(b)) {
                .ignore => {
                    self.reset();
                    return null;
                },
                .motion => |m| return self.finalize(.{ .motion = m }),
                .action => |a| return self.finalize(.{ .action = a }),
                .search => |sr| return self.finalize(.{ .search = sr }),
            }
        },
    }
}

// ============================================================================
// The driver + seam: EventReader (mirrors app.Input / capture.Runner), SliceEventReader (test),
// InputEventReader (prod wrapper over app.Input), and decode(self, reader) — the literal contract.
// ============================================================================

/// Mockable Event source — MIRRORS `app.Input` (NON-nullable ctx + one fn) which mirrors
/// `capture.Runner`. `readEvent` returns a FULL `app.Event` (eof = the `.eof` variant — NOT
/// optional), exactly like `app.readEvent`.
pub const EventReader = struct {
    ctx: *anyopaque,
    readEventFn: *const fn (ctx: *anyopaque) anyerror!app.Event,

    pub fn readEvent(self: EventReader) anyerror!app.Event {
        return self.readEventFn(self.ctx);
    }
};

/// The literal contract fn: pull Events from `reader` until a complete Key is decoded.
///
/// `.eof` ⇒ `error.EndOfStream` (region maps that to quit) — checked BEFORE feed (else
/// `.eof`⇒feed returns null⇒infinite loop). `.mouse` ⇒ `continue` (skip; the full loop routes
/// mouse to select.zig — decode(driver) is the keyboard path). `feed` is infallible ⇒ called
/// WITHOUT `try`. Thin: ALL logic is in `feed()`.
pub fn decode(self: *Decoder, reader: EventReader) anyerror!Key {
    while (true) {
        const ev = try reader.readEvent();
        if (ev == .eof) return error.EndOfStream;
        if (ev == .mouse) continue; // mouse routed elsewhere in the full loop
        if (feed(self, ev)) |k| return k; // feed is infallible ⇒ NO `try`
        // else: accumulating (digit / g) or ignored — keep reading
    }
}

/// TEST reader — yields Events from a slice, then `.eof`. Used by the decode(driver) tests.
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

/// PROD reader — wraps `app.Input` + `app.readEvent`. Compile-verified (real fd). region.zig
/// (P3.M3) drives feed() from its own EventHandler under app.runEvents (the canonical path);
/// this wrapper lets decode(driver) run against real stdin if a keyboard-only loop is ever wanted.
const InputEventReader = struct {
    input: app.Input,
    fn readEvent(ctx: *anyopaque) anyerror!app.Event {
        const self: *InputEventReader = @ptrCast(@alignCast(ctx));
        return app.readEvent(self.input); // app.readEvent returns app.Event (.eof on stdin close)
    }
};

// ============================================================================
// Unit tests — ALL as SEPARATE `test` fns (input.zig is ghostty-free ⇒ safe; mirrors app.zig).
// Pure fns (decodeSeq, decodeByte) + the stateful feed() + the slice-driven decode() driver.
// ============================================================================

const testing = std.testing;

// ---- decodeSeq: CSI arrows --------------------------------------------------

test "decodeSeq: CSI arrows A/B/C/D => up/down/right/left" {
    try testing.expectEqual(@as(?Motion, .up), decodeSeq("\x1b[A"));
    try testing.expectEqual(@as(?Motion, .down), decodeSeq("\x1b[B"));
    try testing.expectEqual(@as(?Motion, .right), decodeSeq("\x1b[C"));
    try testing.expectEqual(@as(?Motion, .left), decodeSeq("\x1b[D"));
}

test "decodeSeq: SS3 arrows OA/OB/OC/OD => up/down/right/left" {
    try testing.expectEqual(@as(?Motion, .up), decodeSeq("\x1bOA"));
    try testing.expectEqual(@as(?Motion, .down), decodeSeq("\x1bOB"));
    try testing.expectEqual(@as(?Motion, .right), decodeSeq("\x1bOC"));
    try testing.expectEqual(@as(?Motion, .left), decodeSeq("\x1bOD"));
}

test "decodeSeq: Ctrl-modified arrows 1;5A/B/C/D => half-page/word" {
    try testing.expectEqual(@as(?Motion, .half_page_up), decodeSeq("\x1b[1;5A"));
    try testing.expectEqual(@as(?Motion, .half_page_down), decodeSeq("\x1b[1;5B"));
    try testing.expectEqual(@as(?Motion, .word_fwd), decodeSeq("\x1b[1;5C"));
    try testing.expectEqual(@as(?Motion, .word_back), decodeSeq("\x1b[1;5D"));
}

test "decodeSeq: Home/End CSI H/F + SS3 OH/OF => line_start/line_end" {
    try testing.expectEqual(@as(?Motion, .line_start), decodeSeq("\x1b[H"));
    try testing.expectEqual(@as(?Motion, .line_end), decodeSeq("\x1b[F"));
    try testing.expectEqual(@as(?Motion, .line_start), decodeSeq("\x1bOH"));
    try testing.expectEqual(@as(?Motion, .line_end), decodeSeq("\x1bOF"));
}

test "decodeSeq: ~ keys Home/End/PgUp/PgDn (1/4/5/6/7/8)" {
    try testing.expectEqual(@as(?Motion, .line_start), decodeSeq("\x1b[1~"));
    try testing.expectEqual(@as(?Motion, .line_end), decodeSeq("\x1b[4~"));
    try testing.expectEqual(@as(?Motion, .line_start), decodeSeq("\x1b[7~"));
    try testing.expectEqual(@as(?Motion, .line_end), decodeSeq("\x1b[8~"));
    try testing.expectEqual(@as(?Motion, .page_up), decodeSeq("\x1b[5~"));
    try testing.expectEqual(@as(?Motion, .page_down), decodeSeq("\x1b[6~"));
}

test "decodeSeq: rejected forms => null (Alt+char, Insert, Delete, Shift-Tab, Shift/Alt-arrow)" {
    try testing.expectEqual(@as(?Motion, null), decodeSeq("\x1bx")); // Alt+char (2-byte)
    try testing.expectEqual(@as(?Motion, null), decodeSeq("\x1b[2~")); // Insert
    try testing.expectEqual(@as(?Motion, null), decodeSeq("\x1b[3~")); // Delete
    try testing.expectEqual(@as(?Motion, null), decodeSeq("\x1b[Z")); // Shift-Tab
    try testing.expectEqual(@as(?Motion, null), decodeSeq("\x1b[1;2A")); // Shift-Up
    try testing.expectEqual(@as(?Motion, null), decodeSeq("\x1b[1;3A")); // Alt-Up
    try testing.expectEqual(@as(?Motion, null), decodeSeq("\x1b[1;4A")); // Shift+Alt-Up (other mod)
    try testing.expectEqual(@as(?Motion, null), decodeSeq("\x1b[1;2D")); // Shift-Left
    // malformed / too-short / wrong-introducer
    try testing.expectEqual(@as(?Motion, null), decodeSeq("\x1b")); // len 1 (app won't send, but guard)
    try testing.expectEqual(@as(?Motion, null), decodeSeq("\x1b[")); // len 2, no final
    try testing.expectEqual(@as(?Motion, null), decodeSeq("")); // empty
    try testing.expectEqual(@as(?Motion, null), decodeSeq("abc")); // no leading ESC
    try testing.expectEqual(@as(?Motion, null), decodeSeq("\x1b[1;2;3A")); // ≥3 params ⇒ unknown
    try testing.expectEqual(@as(?Motion, null), decodeSeq("\x1b[abc")); // non-numeric param ⇒ unknown
}

// ---- decodeByte: motions ----------------------------------------------------

test "decodeByte: vim motion keys h/l/j/k/w/b/e/0/^/$/G/H/M/L/{/}/%" {
    try testing.expectEqual(ByteClass{ .motion = .left }, decodeByte('h'));
    try testing.expectEqual(ByteClass{ .motion = .right }, decodeByte('l'));
    try testing.expectEqual(ByteClass{ .motion = .down }, decodeByte('j'));
    try testing.expectEqual(ByteClass{ .motion = .up }, decodeByte('k'));
    try testing.expectEqual(ByteClass{ .motion = .word_fwd }, decodeByte('w'));
    try testing.expectEqual(ByteClass{ .motion = .word_back }, decodeByte('b'));
    try testing.expectEqual(ByteClass{ .motion = .word_end }, decodeByte('e'));
    try testing.expectEqual(ByteClass{ .motion = .line_start }, decodeByte('0'));
    try testing.expectEqual(ByteClass{ .motion = .first_nonblank }, decodeByte('^'));
    try testing.expectEqual(ByteClass{ .motion = .line_end }, decodeByte('$'));
    try testing.expectEqual(ByteClass{ .motion = .doc_bottom }, decodeByte('G'));
    try testing.expectEqual(ByteClass{ .motion = .viewport_top }, decodeByte('H'));
    try testing.expectEqual(ByteClass{ .motion = .viewport_mid }, decodeByte('M'));
    try testing.expectEqual(ByteClass{ .motion = .viewport_bottom }, decodeByte('L'));
    try testing.expectEqual(ByteClass{ .motion = .paragraph_back }, decodeByte('{'));
    try testing.expectEqual(ByteClass{ .motion = .paragraph_fwd }, decodeByte('}'));
    try testing.expectEqual(ByteClass{ .motion = .match_bracket }, decodeByte('%'));
}

test "decodeByte: Ctrl control bytes 0x02/0x04/0x06/0x15 => page/half-page" {
    try testing.expectEqual(ByteClass{ .motion = .page_up }, decodeByte(0x02)); // Ctrl-b
    try testing.expectEqual(ByteClass{ .motion = .half_page_down }, decodeByte(0x04)); // Ctrl-d
    try testing.expectEqual(ByteClass{ .motion = .page_down }, decodeByte(0x06)); // Ctrl-f
    try testing.expectEqual(ByteClass{ .motion = .half_page_up }, decodeByte(0x15)); // Ctrl-u
}

test "decodeByte: NOT 'g' (feed's pending_g handles gg); 'G' IS here (doc_bottom)" {
    // 'g' (0x67) is intercepted by feed's pending_g — if decodeByte sees it, it's .ignore
    // (feed never routes 'g' here, but assert the leaf is a no-op for robustness).
    try testing.expectEqual(ByteClass.ignore, decodeByte('g'));
    // 'G' (0x47) IS a single-key motion ⇒ doc_bottom.
    try testing.expectEqual(ByteClass{ .motion = .doc_bottom }, decodeByte('G'));
}

// ---- decodeByte: actions ----------------------------------------------------

test "decodeByte: visual actions v/V/Ctrl-v(0x16)/R/o/O" {
    try testing.expectEqual(ByteClass{ .action = .visual_toggle }, decodeByte('v'));
    try testing.expectEqual(ByteClass{ .action = .visual_line }, decodeByte('V'));
    try testing.expectEqual(ByteClass{ .action = .visual_block }, decodeByte(0x16)); // Ctrl-v
    try testing.expectEqual(ByteClass{ .action = .visual_block }, decodeByte('R')); // R (alt binding)
    try testing.expectEqual(ByteClass{ .action = .swap_end }, decodeByte('o'));
    try testing.expectEqual(ByteClass{ .action = .swap_end_other }, decodeByte('O'));
}

test "decodeByte: clear (Esc 0x1b), quit (q / Ctrl-c 0x03), confirm (Enter 0x0d/0x0a / y)" {
    try testing.expectEqual(ByteClass{ .action = .clear }, decodeByte(0x1b)); // Esc
    try testing.expectEqual(ByteClass{ .action = .quit }, decodeByte('q'));
    try testing.expectEqual(ByteClass{ .action = .quit }, decodeByte(0x03)); // Ctrl-c
    try testing.expectEqual(ByteClass{ .action = .confirm }, decodeByte(0x0d)); // Enter (\r)
    try testing.expectEqual(ByteClass{ .action = .confirm }, decodeByte(0x0a)); // Enter (\n)
    try testing.expectEqual(ByteClass{ .action = .confirm }, decodeByte('y'));
}

// ---- decodeByte: search + ignore --------------------------------------------

test "decodeByte: search / ? n N" {
    try testing.expectEqual(ByteClass{ .search = .start_forward }, decodeByte('/'));
    try testing.expectEqual(ByteClass{ .search = .start_backward }, decodeByte('?'));
    try testing.expectEqual(ByteClass{ .search = .next }, decodeByte('n'));
    try testing.expectEqual(ByteClass{ .search = .prev }, decodeByte('N'));
}

test "decodeByte: unmapped bytes => ignore (x, X, space, 0xff; '1' digit is feed's job)" {
    try testing.expectEqual(ByteClass.ignore, decodeByte('x'));
    try testing.expectEqual(ByteClass.ignore, decodeByte('X'));
    try testing.expectEqual(ByteClass.ignore, decodeByte(' '));
    try testing.expectEqual(ByteClass.ignore, decodeByte(0xff));
    // '1' would be .ignore if reached — feed intercepts digits, but the leaf itself ignores it.
    try testing.expectEqual(ByteClass.ignore, decodeByte('1'));
    try testing.expectEqual(ByteClass.ignore, decodeByte('z'));
}

// ---- feed: count parsing ----------------------------------------------------

test "feed: 5j => Key{count 5, motion .down}" {
    var d: Decoder = .{};
    try testing.expectEqual(@as(?Key, null), feed(&d, .{ .key = '5' }));
    try testing.expectEqual(Key{ .count = 5, .kind = .{ .motion = .down } }, feed(&d, .{ .key = 'j' }).?);
}

test "feed: 10j => Key{count 10, motion .down} (0 extends count only when active)" {
    var d: Decoder = .{};
    try testing.expectEqual(@as(?Key, null), feed(&d, .{ .key = '1' }));
    try testing.expectEqual(@as(?Key, null), feed(&d, .{ .key = '0' }));
    try testing.expectEqual(Key{ .count = 10, .kind = .{ .motion = .down } }, feed(&d, .{ .key = 'j' }).?);
}

test "feed: leading 0 => Key{count 1, motion .line_start} (NOT a count — #1 pitfall)" {
    var d: Decoder = .{};
    try testing.expectEqual(Key{ .count = 1, .kind = .{ .motion = .line_start } }, feed(&d, .{ .key = '0' }).?);
}

test "feed: 50j => Key{count 50, motion .down}" {
    var d: Decoder = .{};
    try testing.expectEqual(@as(?Key, null), feed(&d, .{ .key = '5' }));
    try testing.expectEqual(@as(?Key, null), feed(&d, .{ .key = '0' }));
    try testing.expectEqual(Key{ .count = 50, .kind = .{ .motion = .down } }, feed(&d, .{ .key = 'j' }).?);
}

test "feed: count resolves to 1 when no digits typed (plain j => {1, .down})" {
    var d: Decoder = .{};
    try testing.expectEqual(Key{ .count = 1, .kind = .{ .motion = .down } }, feed(&d, .{ .key = 'j' }).?);
}

// ---- feed: gg prefix --------------------------------------------------------

test "feed: gg => Key{count 1, motion .doc_top}" {
    var d: Decoder = .{};
    try testing.expectEqual(@as(?Key, null), feed(&d, .{ .key = 'g' }));
    try testing.expectEqual(Key{ .count = 1, .kind = .{ .motion = .doc_top } }, feed(&d, .{ .key = 'g' }).?);
}

test "feed: 5gg => Key{count 5, motion .doc_top} (count carries through the prefix)" {
    var d: Decoder = .{};
    try testing.expectEqual(@as(?Key, null), feed(&d, .{ .key = '5' }));
    try testing.expectEqual(@as(?Key, null), feed(&d, .{ .key = 'g' }));
    try testing.expectEqual(Key{ .count = 5, .kind = .{ .motion = .doc_top } }, feed(&d, .{ .key = 'g' }).?);
}

test "feed: g then j => g cancelled, j classified fresh => Key{1, .down}" {
    var d: Decoder = .{};
    try testing.expectEqual(@as(?Key, null), feed(&d, .{ .key = 'g' }));
    try testing.expectEqual(Key{ .count = 1, .kind = .{ .motion = .down } }, feed(&d, .{ .key = 'j' }).?);
}

test "feed: g then 5j => g cancelled, fresh count => Key{5, .down}" {
    var d: Decoder = .{};
    try testing.expectEqual(@as(?Key, null), feed(&d, .{ .key = 'g' }));
    try testing.expectEqual(@as(?Key, null), feed(&d, .{ .key = '5' }));
    try testing.expectEqual(Key{ .count = 5, .kind = .{ .motion = .down } }, feed(&d, .{ .key = 'j' }).?);
}

test "feed: G (single key) => Key{1, .doc_bottom} (NOT the gg prefix)" {
    var d: Decoder = .{};
    try testing.expectEqual(Key{ .count = 1, .kind = .{ .motion = .doc_bottom } }, feed(&d, .{ .key = 'G' }).?);
}

// ---- feed: unknown-after-count + reset semantics ----------------------------

test "feed: 5 then x (ignored) => x returns null AND count reset (next j => {1, .down})" {
    var d: Decoder = .{};
    try testing.expectEqual(@as(?Key, null), feed(&d, .{ .key = '5' }));
    try testing.expectEqual(@as(?Key, null), feed(&d, .{ .key = 'x' })); // ignored ⇒ reset count
    // count was discarded — a fresh 'j' is count 1, NOT 5.
    try testing.expectEqual(Key{ .count = 1, .kind = .{ .motion = .down } }, feed(&d, .{ .key = 'j' }).?);
}

test "feed: count finalized once then state reset (5j then j => {5} then {1})" {
    var d: Decoder = .{};
    try testing.expectEqual(@as(?Key, null), feed(&d, .{ .key = '5' }));
    try testing.expectEqual(Key{ .count = 5, .kind = .{ .motion = .down } }, feed(&d, .{ .key = 'j' }).?);
    // after finalize, count reset — a fresh 'j' is count 1.
    try testing.expectEqual(Key{ .count = 1, .kind = .{ .motion = .down } }, feed(&d, .{ .key = 'j' }).?);
}

// ---- feed: seq with count + eof/mouse no-ops --------------------------------

test "feed: 5 then arrow seq \\x1b[B => Key{count 5, motion .down} (arrow ≡ j, count applies)" {
    var d: Decoder = .{};
    try testing.expectEqual(@as(?Key, null), feed(&d, .{ .key = '5' }));
    try testing.expectEqual(Key{ .count = 5, .kind = .{ .motion = .down } }, feed(&d, .{ .seq = app.makeEscSeq("\x1b[B") }).?);
}

test "feed: arrow seq \\x1b[A => Key{1, .up} (count 1, no digits)" {
    var d: Decoder = .{};
    try testing.expectEqual(Key{ .count = 1, .kind = .{ .motion = .up } }, feed(&d, .{ .seq = app.makeEscSeq("\x1b[A") }).?);
}

test "feed: unknown seq after count => null + count reset (next j => {1, .down})" {
    var d: Decoder = .{};
    try testing.expectEqual(@as(?Key, null), feed(&d, .{ .key = '5' }));
    // \x1b[2~ (Insert) is not a motion ⇒ swallow + reset count.
    try testing.expectEqual(@as(?Key, null), feed(&d, .{ .seq = app.makeEscSeq("\x1b[2~") }));
    try testing.expectEqual(Key{ .count = 1, .kind = .{ .motion = .down } }, feed(&d, .{ .key = 'j' }).?);
}

test "feed: .eof => null (state unchanged); .mouse => null (state unchanged)" {
    var d: Decoder = .{};
    try testing.expectEqual(@as(?Key, null), feed(&d, .{ .key = '5' })); // accumulate count
    try testing.expectEqual(@as(?Key, null), feed(&d, .eof)); // no-op, state unchanged
    // a mouse press — no-op, state unchanged.
    try testing.expectEqual(@as(?Key, null), feed(&d, .{ .mouse = .{ .button = .left, .action = .press, .x = 1, .y = 1, .shift = false, .alt = false, .ctrl = false } }));
    // count survived the no-op events — 'j' ⇒ {5, .down}.
    try testing.expectEqual(Key{ .count = 5, .kind = .{ .motion = .down } }, feed(&d, .{ .key = 'j' }).?);
}

// ---- feed: action + search finalize with count ------------------------------

test "feed: 3q => Key{count 3, action .quit}" {
    var d: Decoder = .{};
    try testing.expectEqual(@as(?Key, null), feed(&d, .{ .key = '3' }));
    try testing.expectEqual(Key{ .count = 3, .kind = .{ .action = .quit } }, feed(&d, .{ .key = 'q' }).?);
}

test "feed: / => Key{1, search .start_forward}; 2n => Key{2, .next}" {
    var d: Decoder = .{};
    try testing.expectEqual(Key{ .count = 1, .kind = .{ .search = .start_forward } }, feed(&d, .{ .key = '/' }).?);
    var d2: Decoder = .{};
    try testing.expectEqual(@as(?Key, null), feed(&d2, .{ .key = '2' }));
    try testing.expectEqual(Key{ .count = 2, .kind = .{ .search = .next } }, feed(&d2, .{ .key = 'n' }).?);
}

// ---- decode(driver) via SliceEventReader ------------------------------------

test "decode: [5,j] => Key{5, .down} via SliceEventReader" {
    var d: Decoder = .{};
    var r = SliceEventReader{ .events = &[_]app.Event{ .{ .key = '5' }, .{ .key = 'j' } } };
    const reader = EventReader{ .ctx = @ptrCast(&r), .readEventFn = SliceEventReader.readEvent };
    try testing.expectEqual(Key{ .count = 5, .kind = .{ .motion = .down } }, try decode(&d, reader));
}

test "decode: [g,g] => Key{1, .doc_top} via SliceEventReader" {
    var d: Decoder = .{};
    var r = SliceEventReader{ .events = &[_]app.Event{ .{ .key = 'g' }, .{ .key = 'g' } } };
    const reader = EventReader{ .ctx = @ptrCast(&r), .readEventFn = SliceEventReader.readEvent };
    try testing.expectEqual(Key{ .count = 1, .kind = .{ .motion = .doc_top } }, try decode(&d, reader));
}

test "decode: [seq \\x1b[A] => Key{1, .up} via SliceEventReader" {
    var d: Decoder = .{};
    var r = SliceEventReader{ .events = &[_]app.Event{.{ .seq = app.makeEscSeq("\x1b[A") }}};
    const reader = EventReader{ .ctx = @ptrCast(&r), .readEventFn = SliceEventReader.readEvent };
    try testing.expectEqual(Key{ .count = 1, .kind = .{ .motion = .up } }, try decode(&d, reader));
}

test "decode: [5, seq \\x1b[1;5D] => Key{5, .word_back} (Ctrl-Left with count)" {
    var d: Decoder = .{};
    var r = SliceEventReader{ .events = &[_]app.Event{ .{ .key = '5' }, .{ .seq = app.makeEscSeq("\x1b[1;5D") } } };
    const reader = EventReader{ .ctx = @ptrCast(&r), .readEventFn = SliceEventReader.readEvent };
    try testing.expectEqual(Key{ .count = 5, .kind = .{ .motion = .word_back } }, try decode(&d, reader));
}

test "decode: empty slice => error.EndOfStream" {
    var d: Decoder = .{};
    var r = SliceEventReader{ .events = &[_]app.Event{} };
    const reader = EventReader{ .ctx = @ptrCast(&r), .readEventFn = SliceEventReader.readEvent };
    try testing.expectError(error.EndOfStream, decode(&d, reader));
}

test "decode: [j] then eof on first call; 2nd call on empty reader => error.EndOfStream" {
    var d: Decoder = .{};
    var r = SliceEventReader{ .events = &[_]app.Event{.{ .key = 'j' }} };
    const reader = EventReader{ .ctx = @ptrCast(&r), .readEventFn = SliceEventReader.readEvent };
    // first decode consumes 'j' ⇒ {1, .down}
    try testing.expectEqual(Key{ .count = 1, .kind = .{ .motion = .down } }, try decode(&d, reader));
    // second decode: reader exhausted ⇒ .eof ⇒ error.EndOfStream
    try testing.expectError(error.EndOfStream, decode(&d, reader));
}

test "decode: [mouse, q] => mouse skipped, then q => Key{1, .quit}" {
    var d: Decoder = .{};
    var r = SliceEventReader{ .events = &[_]app.Event{
        .{ .mouse = .{ .button = .left, .action = .press, .x = 1, .y = 1, .shift = false, .alt = false, .ctrl = false } },
        .{ .key = 'q' },
    } };
    const reader = EventReader{ .ctx = @ptrCast(&r), .readEventFn = SliceEventReader.readEvent };
    try testing.expectEqual(Key{ .count = 1, .kind = .{ .action = .quit } }, try decode(&d, reader));
}

test "decode: [eof] immediately => error.EndOfStream (eof short-circuit, not fed to feed)" {
    var d: Decoder = .{};
    var r = SliceEventReader{ .events = &[_]app.Event{app.Event.eof} };
    const reader = EventReader{ .ctx = @ptrCast(&r), .readEventFn = SliceEventReader.readEvent };
    try testing.expectError(error.EndOfStream, decode(&d, reader));
}
