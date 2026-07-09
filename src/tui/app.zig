//! app.zig — terminal control + event loop for the copy-mode TUI (PRD §7.1).
//!
//! The ONE module that takes over the display-popup's pty for `tmux-2html region` (P3.M3).
//! Ghostty-free: imports ONLY `std`, so its tests are SAFE as SEPARATE `test` fns (no
//! single-test-scope GOTCHA that constrains render.zig/golden_test.zig).
//!
//! Three jobs:
//!   1. enter():  enter the alternate screen, hide the cursor, switch stdin to raw termios
//!                (no echo, no canonical, byte-at-a-time blocking reads), install SIGINT/SIGTERM/
//!                SIGQUIT handlers.
//!   2. ALWAYS restore the terminal — cooked termios + primary screen + visible cursor — on
//!      EVERY exit path (normal return via defer, error return, SIGINT/SIGTERM/SIGQUIT, and Zig
//!      panic). The root panic override in main.zig calls restoreRaw(). All three paths share ONE
//!      idempotent `restoreRaw()` guarded by a module-level atomic `entered` flag.
//!   3. run(handler): forward-compatible event loop. Blocks on stdin one byte at a time and
//!      delegates each byte to a pluggable `Handler` that yields an `Action`. run()'s body NEVER
//!      changes across later tasks — only WHICH Handler is passed in grows (S2 mouse, T2 view,
//!      P3.M2 input/select).
//!
//! Anti-patterns avoided (see PRP): do NOT open /dev/tty here (the popup IS the tty, unlike
//! palette.queryColors which runs outside the popup); use `.FLUSH` on ENTER (drop typeahead) and
//! `.NOW` on RESTORE (don't drop user input); use the CORRECTED exit_seq (`?25h` show cursor,
//! NOT tui_region.md §1's `?25l` hide-cursor typo); keep it std-only.

const std = @import("std");

/// Why the run loop stopped. S1 yields only `.quit` (default_handler). `.confirm` is RESERVED —
/// future select/input handlers yield it on Enter/y with an active selection. region.zig (P3.M3)
/// maps .confirm→render+sidecar, .quit→no output. `.none` = byte consumed, keep looping.
pub const Action = enum { none, quit, confirm };

/// Saved terminal state. Carries ONLY what's needed to restore. S1 fields: fd + original termios.
/// S2 may add a `mouse_enabled` flag; the struct GROWS without changing enter/exit signatures.
pub const State = struct {
    fd: std.posix.fd_t,
    original: std.posix.termios,
};

/// Pluggable per-byte handler — MIRRORS capture.zig's `Runner = { ctx, runFn }` seam. S1 ships
/// `default_handler` (stateless). Later tasks build a Handler with a typed ctx:
///   S2 mouse      → ctx owns a decode buffer; classify() accumulates \x1b[<... sequences
///   T2 view       → ctx points at the view; classify() triggers repaint side-effects
///   P3.M2 input   → ctx points at the key decoder (vim/search) → returns motions
///   P3.M2 select  → classify() yields .confirm on Enter/y with an active selection
/// `run()`'s body never changes across any of these — only WHICH Handler is passed in.
/// ctx is `?*anyopaque` (nullable) so the stateless default passes null. Recover a typed pointer
/// in a future handler via `@ptrCast(@alignCast(ctx.?))` (the capture.zig 0.15.2 rule).
pub const Handler = struct {
    ctx: ?*anyopaque,
    classifyFn: *const fn (ctx: ?*anyopaque, byte: u8) Action,

    pub fn classify(self: Handler, byte: u8) Action {
        return self.classifyFn(self.ctx, byte);
    }
};

// === Escape sequences (PRD §7.1; tui_region.md §1 with the ?25l typo CORRECTED). ===
// Enter: enter alt screen (?1049h) + hide cursor (?25l).
// Exit:  SHOW cursor (?25h) + leave alt screen (?1049l). NOTE the ?25h — the arch doc's restore
//        literal used ?25l (cursor HIDE) which is a typo; restoring must SHOW the cursor.
pub const enter_seq = "\x1b[?1049h\x1b[?25l";
pub const exit_seq = "\x1b[?25h\x1b[?1049l";

// === Mouse escape sequences (PRD §7.6; arch tui_region.md §2; research/sgr_mouse_encoding.md). ===
// 1000 = click report; 1002 = button-event motion (drag) report; 1006 = SGR encoding
// (\x1b[<{b};{x};{y}M/m). Disabling uses the lowercase `l` forms. Comptime `++` of the
// string-literal consts yields comptime-known arrays, so enter()/restoreRaw() do ONE write each
// (restoreRaw stays one async-signal-safe syscall: disable mouse FIRST, then restore terminal).
pub const mouse_enable_seq = "\x1b[?1000h\x1b[?1002h\x1b[?1006h";
pub const mouse_disable_seq = "\x1b[?1000l\x1b[?1002l\x1b[?1006l";
pub const enter_full_seq = enter_seq ++ mouse_enable_seq; // alt+hide-cursor, THEN enable mouse
pub const restore_seq = mouse_disable_seq ++ exit_seq; // disable mouse FIRST, THEN show cursor + leave alt

// === Module-level backstop state (the signal handler + panic override have no context arg). ===
// THE shared crash-recovery state. `entered` is the idempotency guard: an atomic bool so defer +
// signal + panic can't double-restore from different contexts. Set in enter(); cleared by
// restoreRaw()'s atomic swap. `saved`/`saved_fd` are read by the signal handler + panic override.
var entered = std.atomic.Value(bool).init(false);
var saved: ?std.posix.termios = null;
var saved_fd: std.posix.fd_t = -1;
// Recursion guard for the root panic override in main.zig (read/set there before calling
// restoreRaw, so a panic INSIDE restoreRaw can't re-enter restoreRaw forever).
pub var panic_in_progress = false;

// ============================================================================
// PURE helpers — unit-tested. makeRaw copies the termios flag syntax from palette.zig:106-109
// (MIN/TIME changed to 1/0 for BLOCKING reads instead of palette's 0/5 timed OSC read).
// ============================================================================

/// PURE: produce a raw-mode termios from `original`. Clears ICANON/ECHO (lflag),
/// IXON/ICRNL/BRKINT (iflag), OPOST (oflag); sets CSIZE=.CS8 (cflag); sets cc[V.MIN]=1 /
/// cc[V.TIME]=0 (BLOCKING byte-at-a-time reads). Leaves every other field EQUAL to `original`.
/// No I/O — directly unit-tested.
pub fn makeRaw(original: std.posix.termios) std.posix.termios {
    var raw = original;
    raw.lflag.ICANON = false; // no canonical (line) mode
    raw.lflag.ECHO = false; // no echo of keystrokes
    raw.iflag.IXON = false; // disable Ctrl-S/Ctrl-Q flow control
    raw.iflag.ICRNL = false; // don't translate CR→NL
    raw.iflag.BRKINT = false; // no SIGINT on break
    raw.oflag.OPOST = false; // no output processing (we emit raw escapes)
    raw.cflag.CSIZE = .CS8; // 8-bit chars (term2html/tui_region §1)
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1; // BLOCKING: read returns ≥1 byte (palette uses 0)
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0; // no inter-byte timer (palette uses 5 = 500ms)
    return raw;
}

/// PURE: classify a single input byte for the default (quit-only) handler.
/// 'q'(0x71), Ctrl-C(0x03), Esc(0x1b) ⇒ `.quit`; everything else ⇒ `.none`.
pub fn classifyByte(byte: u8) Action {
    return switch (byte) {
        'q', 0x03, 0x1b => .quit,
        else => .none,
    };
}

// ============================================================================
// restoreRaw — the ONE idempotent restore shared by defer (via exit) + signal handler + panic.
// NOT unit-testable (real fd) — compile-verified + manually tested (mirrors palette.queryColors).
// ============================================================================

/// Idempotent restore of the terminal to cooked mode + primary screen + visible cursor.
/// Guarded by an atomic swap on `entered` so defer + signal-handler + panic-override can NEVER
/// double-restore. Uses raw `std.posix.write` (async-signal-safe) for the exit sequence and
/// `tcsetattr(.NOW)` for the termios restore (don't drop user input). Reads module globals —
/// it is the version the signal handler and the root panic override call (no params).
pub fn restoreRaw() void {
    if (!entered.swap(false, .acq_rel)) return; // already restored ⇒ no-op (double-restore safe)
    if (saved_fd < 0) return; // never entered ⇒ nothing to restore
    // Raw write (async-signal-safe): show cursor + leave alt screen. saved_fd is the pty stdin
    // fd; in the display-popup stdin/stdout are the same pty, so writing escapes to saved_fd works.
    _ = std.posix.write(saved_fd, restore_seq) catch {};
    if (saved) |s| std.posix.tcsetattr(saved_fd, .NOW, s) catch {}; // .NOW restore (don't drop input)
}

// ============================================================================
// enter / exit — real-fd fns; compile-verified + manually tested (Level 3 smoke).
// ============================================================================

/// Enter terminal raw mode for the TUI: save stdin's termios, write enter_seq (alt screen + hide
/// cursor), switch to raw termios (`.FLUSH` drops stray typeahead), install SIGINT/SIGTERM/SIGQUIT
/// handlers, set the `entered` flag. Returns the saved State for the caller's `defer exit(state)`.
/// Errors: `error.NoTty` if stdin isn't a terminal (tcgetattr fails — e.g. piped stdin).
pub fn enter() !State {
    const stdin = std.fs.File.stdin();
    const fd = stdin.handle;
    const original = std.posix.tcgetattr(fd) catch return error.NoTty; // .NotATerminal etc.
    saved = original; // backstop for the signal handler + panic override (no context arg)
    saved_fd = fd;
    try std.fs.File.stdout().writeAll(enter_full_seq); // alt screen + hide cursor + enable mouse
    try std.posix.tcsetattr(fd, .FLUSH, makeRaw(original)); // .FLUSH on enter (drop typeahead)
    installSignalHandlers();
    entered.store(true, .release);
    return .{ .fd = fd, .original = original };
}

/// The caller-facing restore for `defer exit(state)` — normal + error returns. Delegates to the
/// ONE idempotent restoreRaw() (so the defer path shares the same restore as the signal handler +
/// panic override). The `state` param documents the enter/exit pairing (contract requirement);
/// the actual values come from the module globals set in enter() (they equal state).
pub fn exit(state: State) void {
    _ = state; // values are already in the module globals set by enter(); restoreRaw reads those.
    restoreRaw();
}

// ============================================================================
// Signal handler — restore-then-re-raise (GNU readline signals.c idiom).
// ============================================================================

/// Async-signal-safe: restore the terminal, reset the disposition to default, re-raise the
/// signal so the process dies with the conventional 128+sig exit status. Fallback
/// `std.posix.exit(128+sig)` if re-raise somehow returns. NEVER calls printf/malloc.
fn sigHandler(sig: c_int) callconv(.c) void {
    restoreRaw(); // termios + exit_seq via raw write (idempotent)
    const s: u8 = @intCast(sig);
    var dfl = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(s, &dfl, null); // reset to default disposition
    // Re-raise: kill(getpid(), sig) so the default disposition fires → dies with 128+sig.
    // getpid lives at std.os.linux.getpid (std.posix has no getpid in 0.15.2); kill is
    // async-signal-safe. Errors are ignored (we exit unconditionally next).
    _ = std.posix.kill(std.os.linux.getpid(), s) catch {};
    std.posix.exit(@intCast(128 + sig)); // fallback if re-raise somehow returns
}

/// Install the restore-then-re-raise handler for SIGINT (Ctrl-C), SIGTERM (kill), and SIGQUIT
/// (Ctrl-\: cleanup + core). Idempotent in shape (safe to call once per enter()). NOT unit-tested
/// — compile-verified + manually tested (Level 3 Ctrl-C + kill -TERM).
fn installSignalHandlers() void {
    var act = std.posix.Sigaction{
        .handler = .{ .handler = &sigHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null); // Ctrl-C
    std.posix.sigaction(std.posix.SIG.TERM, &act, null); // kill
    std.posix.sigaction(std.posix.SIG.QUIT, &act, null); // Ctrl-\ (cleanup + core)
}

// ============================================================================
// run + default_handler — the forward-compatible event loop.
// ============================================================================

/// Block-read stdin one byte at a time and delegate each byte to `handler.classify`. Returns the
/// `Action` the handler yields on `.quit`/`.confirm`; `.none` keeps looping; EOF ⇒ `.quit`.
/// `run()`'s body is the STABLE forward-compat surface — later tasks only change WHICH Handler is
/// passed (S2 mouse, T2 view, P3.M2 input/select). Errors: `error.ReadFailed` if stdin.read fails.
pub fn run(handler: Handler) !Action {
    const stdin = std.fs.File.stdin();
    var buf: [1]u8 = undefined;
    while (true) {
        const n = stdin.read(&buf) catch return error.ReadFailed; // 0..=1 (raw, MIN=1)
        if (n == 0) return .quit; // EOF
        switch (handler.classify(buf[0])) {
            .none => continue,
            .quit => return .quit,
            .confirm => return .confirm,
        }
    }
}

/// The stateless default classifyFn: delegates to the pure classifyByte.
fn defaultClassify(_: ?*anyopaque, byte: u8) Action {
    return classifyByte(byte);
}

/// The default (quit-only) handler — quits on `q`(0x71), Ctrl-C(0x03), Esc(0x1b). Stateless
/// (ctx = null). Later tasks supply richer handlers (mouse decode, view repaint, vim/search, select).
pub const default_handler: Handler = .{ .ctx = null, .classifyFn = defaultClassify };

// ============================================================================
// S2: event-level surface — mouse enable/disable (enter/restoreRaw above), SGR mouse decode,
// and a typed Event stream (readEvent/EventHandler/runEvents) consumed by P3.M2 input.zig /
// select.zig and driven by P3.M3 region.zig via runEvents. S1's byte-level run()/Handler stay
// as the smoke-test path; this event-level surface is what the real TUI uses. std-only.
// ============================================================================

/// Max bytes captured for one ESC sequence (CSI/SS3 ≤ ~8; Alt+char = 2; mouse ≤ ~12). 16 is
/// generous. Bounds the readEvent accumulation buffer + the EscSeq fixed array.
pub const max_esc_len: usize = 16;
/// The inter-byte gap (ms) after an ESC byte used to detect end-of-sequence / a lone Esc.
/// 50ms: terminals send sequences atomically, so real sequences never gap; a true lone-Esc
/// pays this once (standard; libvaxis/termbox use similar). Tunable.
pub const esc_followup_ms: i32 = 50;

pub const MouseButton = enum { left, middle, right, none };
pub const MouseAction = enum { press, release, motion, wheel_up, wheel_down };

/// A decoded SGR (mode 1006) mouse event. x/y are 1-based CHARACTER cells as reported by the
/// terminal (mode 1006 is NOT pixel — pixel is the separate ?1016 mode). The consumer
/// (select.zig, P3.M2.T2) subtracts 1 for 0-based grid indexing. `alt` is set when (b & 8) —
/// the SELECT layer switches a drag to BLOCK selection when alt is set during motion (PRD §7.6).
pub const MouseEvent = struct {
    button: MouseButton,
    action: MouseAction,
    x: u32, // 1-based SGR column
    y: u32, // 1-based SGR row
    shift: bool, // (b & 4)
    alt: bool, // (b & 8)  — Alt/Meta; consumer uses for block-drag (PRD §7.6)
    ctrl: bool, // (b & 16)
};

/// A raw multi-byte ESC sequence (CSI \x1b[... / SS3 \x1bO... / Alt+char \x1b<char>) handed
/// UNDECODED to the key decoder (P3.M2.T1.S1 input.zig). Bytes INCLUDE the leading 0x1b so the
/// decoder can pattern-match "\x1b[A" etc. Fixed inline buffer (no allocation).
pub const EscSeq = struct {
    bytes: [max_esc_len]u8 = [_]u8{0} ** max_esc_len,
    len: u8 = 0,
    // NOTE: `self: *const EscSeq` (NOT by-value) — Zig 0.15.2 miscompiles a by-value method that
    // returns a slice into an array field when the receiver is a returned/SSA temporary
    // (SROA drops the @memcpy'd bytes → 0xaa garbage). Taking the address keeps the read through
    // a pointer the optimizer cannot eliminate. Verified in Debug + ReleaseFast.
    pub fn slice(self: *const EscSeq) []const u8 {
        const ptr: [*]const u8 = @ptrCast(&self.bytes[0]);
        return ptr[0..self.len];
    }
};

/// A decoded terminal input event — the typed stream `readEvent` produces, consumed by the
/// input/select layer (P3.M2 input.zig, select.zig). Three categories (arch §3 + work item):
///   .key   = a single non-sequence byte (printable, control, or standalone Esc 0x1b)
///   .mouse = a fully decoded SGR mouse event (THIS subtask's core deliverable)
///   .seq   = a raw ESC sequence for the key decoder P3.M2.T1.S1 (arrows/Ctrl-mods/fn/vim)
///   .eof   = stdin closed
pub const Event = union(enum) {
    key: u8,
    mouse: MouseEvent,
    seq: EscSeq,
    eof: void,
};

// ============================================================================
// PURE decoders (slice-based; fully unit-tested — no reader, no timing).
// Mirrors the capture.zig "pure parse vs real-fd execution" split: these helpers are separate
// `test` fns with no seam; readEvent/FdInput/runEvents (real fd) are compile-verified + manual.
// ============================================================================

const MouseDecode = struct {
    button: MouseButton,
    action: MouseAction,
    shift: bool,
    alt: bool,
    ctrl: bool,
};

/// PURE: true if `c` is a CSI/SS3 final byte (0x40..=0x7e). Used by readEvent's fast-stop.
/// '<' (0x3c) is in the PARAMETER range (0x30-0x3f) so it never matches here.
fn isCsiFinal(c: u8) bool {
    return c >= 0x40 and c <= 0x7e;
}

/// PURE: decode the SGR button/motion integer `b` + terminator ('M' press/motion/wheel, 'm'
/// release) into button/action/modifier fields. Bit layout (xterm ctlseqs, authoritative):
///   bits0-1 (0/1/2/3) = button (0=left,1=middle,2=right,3=none/hover); bit2(4)=Shift;
///   bit3(8)=Alt/Meta; bit4(16)=Control; bit5(32)=motion; bits6-7(64/65)=wheel up/down.
/// Alt=(b&8); Ctrl=(b&16). Wheel 64=up/65=down (b&1 distinguishes), no release event.
pub fn decodeButton(b: u32, term: u8) MouseDecode {
    const shift = (b & 4) != 0;
    const alt = (b & 8) != 0;
    const ctrl = (b & 16) != 0;
    if ((b & 64) != 0) { // wheel
        return .{ .button = .none, .action = if ((b & 1) == 0) .wheel_up else .wheel_down, .shift = shift, .alt = alt, .ctrl = ctrl };
    }
    const motion = (b & 32) != 0;
    const btn: MouseButton = switch (b & 3) {
        0 => .left,
        1 => .middle,
        2 => .right,
        else => .none,
    };
    const action: MouseAction = if (motion) .motion else (if (term == 'm') .release else .press);
    return .{ .button = btn, .action = action, .shift = shift, .alt = alt, .ctrl = ctrl };
}

/// PURE: parse a complete SGR mouse payload "{b};{x};{y}{M|m}" (the bytes AFTER "\x1b[<") into a
/// MouseEvent, or null if malformed. b/x/y are unsigned decimals; the LAST byte is the terminator
/// ('M' = press/motion/wheel, 'm' = release). Exactly 3 ';' fields.
pub fn parseMousePayload(payload: []const u8) ?MouseEvent {
    if (payload.len < 1) return null;
    const term = payload[payload.len - 1];
    if (term != 'M' and term != 'm') return null;
    const nums = payload[0 .. payload.len - 1]; // "b;x;y"
    var it = std.mem.splitScalar(u8, nums, ';');
    const b_s = it.next() orelse return null;
    const x_s = it.next() orelse return null;
    const y_s = it.next() orelse return null;
    if (it.next() != null) return null; // exactly 3 fields
    const b = std.fmt.parseInt(u32, b_s, 10) catch return null;
    const x = std.fmt.parseInt(u32, x_s, 10) catch return null;
    const y = std.fmt.parseInt(u32, y_s, 10) catch return null;
    const d = decodeButton(b, term);
    return .{ .button = d.button, .action = d.action, .x = x, .y = y, .shift = d.shift, .alt = d.alt, .ctrl = d.ctrl };
}

/// PURE: copy a raw ESC slice into a fixed EscSeq (clamp to max_esc_len). The slice is assumed to
/// INCLUDE the leading 0x1b (so the key decoder can match "\x1b[A" etc.).
pub fn makeEscSeq(seq: []const u8) EscSeq {
    var e: EscSeq = .{};
    const n = @min(seq.len, max_esc_len);
    @memcpy(e.bytes[0..n], seq[0..n]);
    e.len = @intCast(n);
    return e;
}

/// PURE: classify a COMPLETE ESC sequence (INCLUDING the leading 0x1b) into an Event.
///   "\x1b" alone                     → .key(0x1b)   (standalone Esc)
///   "\x1b[<{b};{x};{y}{M|m}"         → .mouse       (fully decoded; malformed → fall to .seq)
///   any other "\x1b[..." / "\x1bO..." / "\x1b<char>" → .seq (raw bytes for the key decoder)
pub fn classifyEscSeq(seq: []const u8) Event {
    if (seq.len == 1) return .{ .key = 0x1b }; // lone Esc
    if (seq.len >= 3 and seq[1] == '[' and seq[2] == '<') {
        if (parseMousePayload(seq[3..])) |m| return .{ .mouse = m };
        // malformed SGR mouse → hand the raw bytes to the decoder (robust fallback)
    }
    return .{ .seq = makeEscSeq(seq) };
}

// ============================================================================
// The Input byte-source seam (mirrors capture.Runner: ctx *anyopaque NON-nullable + one fn).
// FdInput = prod (stdin fd + std.posix.poll); SliceInput = test (fixedBufferStream).
// ============================================================================

/// The mockable byte source readEvent reads from — MIRRORS capture.zig:58-66 `Runner`. ONE method;
/// ctx is *anyopaque (NON-nullable, like Runner) — prod FdInput + test SliceInput both carry state.
/// timeout_ms: <0 = BLOCK forever (first byte of an event); >=0 = wait ≤ that many ms, return null
/// on timeout/EOF. This split lets readEvent block for byte 1 then time-out the ESC follow-up.
pub const Input = struct {
    ctx: *anyopaque,
    readByteTimeoutFn: *const fn (ctx: *anyopaque, timeout_ms: i32) anyerror!?u8,

    pub fn readByteTimeout(self: Input, timeout_ms: i32) anyerror!?u8 {
        return self.readByteTimeoutFn(self.ctx, timeout_ms);
    }
};

/// PROD Input — real stdin fd + poll. Blocks (ms<0) or polls-then-reads (ms>=0).
/// poll spelling: std.posix.pollfd (lowercase struct) + std.posix.POLL.IN (capital const).
/// Verified: posix.zig:6447/92/143 + os/linux.zig:7041/7050. NOT unit-tested — compile-verified.
const FdInput = struct {
    fd: std.posix.fd_t,
    fn readByteTimeout(ctx: *anyopaque, timeout_ms: i32) anyerror!?u8 {
        const self: *FdInput = @ptrCast(@alignCast(ctx)); // @alignCast MANDATORY (0.15.2)
        if (timeout_ms >= 0) {
            var fds = [_]std.posix.pollfd{.{ .fd = self.fd, .events = std.posix.POLL.IN, .revents = 0 }};
            if ((try std.posix.poll(&fds, timeout_ms)) == 0) return null; // timed out
        }
        var b: [1]u8 = undefined;
        const n = try std.posix.read(self.fd, &b); // 0 = EOF
        if (n == 0) return null;
        return b[0];
    }
};

/// TEST Input — fixedBufferStream; ignores timeout, returns null at EOF (models "no more bytes now").
/// FixedBufferStream([]const u8) read is infallible (error{}).
const SliceInput = struct {
    fbs: *std.io.FixedBufferStream([]const u8),
    fn readByteTimeout(ctx: *anyopaque, _: i32) anyerror!?u8 {
        const self: *SliceInput = @ptrCast(@alignCast(ctx));
        var one: [1]u8 = undefined;
        const n = try self.fbs.read(&one);
        return if (n == 0) null else one[0];
    }
};

/// Read one logical input event from `input`. Blocks for the first byte (timeout < 0):
///   null ⇒ .eof; a non-ESC byte ⇒ .key(byte); an ESC byte ⇒ accumulate the sequence with a
///   ~esc_followup_ms inter-byte gap (+ CSI-final fast-stop) into a [max_esc_len]u8 buffer, then
///   PURE classifyEscSeq. Errors propagate (e.g. error.ReadFailed from poll/read). NOT pure
/// (timing) — exercised via SliceInput in tests; FdInput + poll is compile-verified + manual.
pub fn readEvent(input: Input) anyerror!Event {
    const first = (try input.readByteTimeout(-1)) orelse return .eof; // block for byte 1
    if (first != 0x1b) return .{ .key = first }; // plain single byte (printable/control)

    // ESC seen — accumulate the rest of the sequence.
    var buf: [max_esc_len]u8 = [_]u8{0} ** max_esc_len;
    buf[0] = 0x1b;
    var len: usize = 1;
    while (len < max_esc_len) {
        const b = try input.readByteTimeout(esc_followup_ms);
        if (b == null) break; // 50ms gap ⇒ end of sequence (or lone Esc if len==1)
        buf[len] = b.?;
        len += 1;
        if (len >= 3 and isCsiFinal(buf[len - 1])) break; // CSI/SS3 final byte ⇒ done (no latency)
    }
    return classifyEscSeq(buf[0..len]); // PURE decode of the accumulated bytes
}

// ============================================================================
// The event-level loop seam (mirrors S1's Handler/run/default_handler, but consumes an Event).
// P3.M2 supplies the real EventHandler (vim/search/select); P3.M3 region.zig calls runEvents.
// ============================================================================

/// Pluggable per-EVENT handler — MIRRORS S1's `Handler` (nullable ctx), but consumes a decoded
/// `Event` instead of a raw byte. This is the event-level seam P3.M2's input/select handlers
/// implement; P3.M3 region.zig calls runEvents(input_handler). S1's byte-level run()/Handler stay
/// as the smoke-test path — S2's runEvents/EventHandler is what the real TUI uses.
pub const EventHandler = struct {
    ctx: ?*anyopaque,
    handleFn: *const fn (ctx: ?*anyopaque, ev: Event) Action,
    pub fn handle(self: EventHandler, ev: Event) Action {
        return self.handleFn(self.ctx, ev);
    }
};

/// Block-read decoded events via readEvent (stdin FdInput) and dispatch each to `handler.handle`.
/// Returns the Action on .quit/.confirm; .eof from readEvent ⇒ .quit (stdin closed). Errors
/// (error.ReadFailed etc.) propagate. P3.M3 region.zig calls this with P3.M2's handler.
pub fn runEvents(handler: EventHandler) !Action {
    var fd_in: FdInput = .{ .fd = std.fs.File.stdin().handle };
    const input: Input = .{ .ctx = @ptrCast(&fd_in), .readByteTimeoutFn = FdInput.readByteTimeout };
    while (true) {
        const ev = try readEvent(input);
        if (ev == .eof) return .quit; // stdin closed
        switch (handler.handle(ev)) {
            .none => continue,
            .quit => return .quit,
            .confirm => return .confirm,
        }
    }
}

/// The event-level default: quits on `key` events for 'q'(0x71), Ctrl-C(0x03), Esc(0x1b). Stateless
/// (ctx=null). The event-level twin of S1's default_handler. P3.M2 supplies the real handler.
fn defaultEventHandle(_: ?*anyopaque, ev: Event) Action {
    return switch (ev) {
        .key => |b| switch (b) { 'q', 0x03, 0x1b => .quit, else => .none },
        else => .none, // mouse / seq handled by richer handlers (P3.M2)
    };
}

/// The event-level default handler (stateless) — the twin of S1's default_handler.
pub const default_event_handler: EventHandler = .{ .ctx = null, .handleFn = defaultEventHandle };

// ============================================================================
// Unit tests (PURE helpers only — makeRaw / classifyByte / sequences).
// enter/exit/restoreRaw/run/sigHandler/installSignalHandlers touch the REAL tty and are NOT
// unit-tested — compile-verified + manually tested (Level 3), exactly like palette.queryColors.
// app.zig is ghostty-free ⇒ these are SAFE as separate `test` fns.
// ============================================================================

test "makeRaw: clears ICANON/ECHO/IXON/ICRNL/BRKINT/OPOST, sets CS8, MIN=1/TIME=0, keeps rest" {
    // Build a termios with the to-be-cleared flags SET and CSIZE != CS8, then verify makeRaw
    // clears/sets exactly the right fields and leaves unrelated fields (ispeed/ospeed) intact.
    var input: std.posix.termios = std.mem.zeroes(std.posix.termios);
    input.lflag.ICANON = true;
    input.lflag.ECHO = true;
    input.iflag.IXON = true;
    input.iflag.ICRNL = true;
    input.iflag.BRKINT = true;
    input.oflag.OPOST = true;
    input.cflag.CSIZE = .CS5; // != CS8 so we can prove makeRaw forces CS8
    input.ispeed = .B9600; // speed_t enum; set distinct values to prove makeRaw preserves them
    input.ospeed = .B38400;

    const raw = makeRaw(input);

    // cleared lflag / iflag / oflag flags
    try std.testing.expectEqual(false, raw.lflag.ICANON);
    try std.testing.expectEqual(false, raw.lflag.ECHO);
    try std.testing.expectEqual(false, raw.iflag.IXON);
    try std.testing.expectEqual(false, raw.iflag.ICRNL);
    try std.testing.expectEqual(false, raw.iflag.BRKINT);
    try std.testing.expectEqual(false, raw.oflag.OPOST);
    // cflag forced to CS8
    try std.testing.expectEqual(@as(@TypeOf(raw.cflag.CSIZE), .CS8), raw.cflag.CSIZE);
    // cc[V.MIN] = 1, cc[V.TIME] = 0 (BLOCKING)
    try std.testing.expectEqual(@as(u8, 1), raw.cc[@intFromEnum(std.posix.V.MIN)]);
    try std.testing.expectEqual(@as(u8, 0), raw.cc[@intFromEnum(std.posix.V.TIME)]);
    // unrelated fields unchanged (speed_t enum values preserved)
    try std.testing.expectEqual(input.ispeed, raw.ispeed);
    try std.testing.expectEqual(input.ospeed, raw.ospeed);
    try std.testing.expectEqual(@as(@TypeOf(raw.ispeed), .B9600), raw.ispeed);
    try std.testing.expectEqual(@as(@TypeOf(raw.ospeed), .B38400), raw.ospeed);
}

test "makeRaw: idempotent over an already-raw input (no flags to clear)" {
    var raw_input: std.posix.termios = std.mem.zeroes(std.posix.termios);
    raw_input.cflag.CSIZE = .CS8;
    raw_input.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw_input.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    const out = makeRaw(raw_input);
    try std.testing.expectEqual(false, out.lflag.ICANON);
    try std.testing.expectEqual(false, out.lflag.ECHO);
    try std.testing.expectEqual(@as(@TypeOf(out.cflag.CSIZE), .CS8), out.cflag.CSIZE);
    try std.testing.expectEqual(@as(u8, 1), out.cc[@intFromEnum(std.posix.V.MIN)]);
    try std.testing.expectEqual(@as(u8, 0), out.cc[@intFromEnum(std.posix.V.TIME)]);
}

test "classifyByte: 'q', Ctrl-C (0x03), Esc (0x1b) => .quit; rest => .none" {
    try std.testing.expectEqual(Action.quit, classifyByte('q'));
    try std.testing.expectEqual(Action.quit, classifyByte(0x03));
    try std.testing.expectEqual(Action.quit, classifyByte(0x1b));
    // a sampling of non-quit bytes
    try std.testing.expectEqual(Action.none, classifyByte('j'));
    try std.testing.expectEqual(Action.none, classifyByte('\n'));
    try std.testing.expectEqual(Action.none, classifyByte('h'));
    try std.testing.expectEqual(Action.none, classifyByte(0x00));
    try std.testing.expectEqual(Action.none, classifyByte(0xff));
    // 'Q' (capital) is NOT 'q' => none (case-sensitive)
    try std.testing.expectEqual(Action.none, classifyByte('Q'));
}

test "default_handler.classify: stateless delegation to classifyByte" {
    try std.testing.expectEqual(Action.quit, default_handler.classify('q'));
    try std.testing.expectEqual(Action.quit, default_handler.classify(0x03));
    try std.testing.expectEqual(Action.quit, default_handler.classify(0x1b));
    try std.testing.expectEqual(Action.none, default_handler.classify('x'));
    // ctx is null (stateless)
    try std.testing.expectEqual(@as(?*anyopaque, null), default_handler.ctx);
}

test "enter_seq / exit_seq: exact bytes (exit shows cursor ?25h, NOT hides it ?25l)" {
    try std.testing.expectEqualStrings("\x1b[?1049h\x1b[?25l", enter_seq);
    try std.testing.expectEqualStrings("\x1b[?25h\x1b[?1049l", exit_seq);
    // explicit guard against the tui_region.md §1 typo (?25l on restore = cursor HIDE):
    try std.testing.expect(!std.mem.eql(u8, exit_seq, "\x1b[?25l\x1b[?1049l"));
}

// ============================================================================
// S2 tests — mouse seq literals, PURE decoders (decodeButton / parseMousePayload /
// classifyEscSeq), readEvent via SliceInput, and default_event_handler. S1's symbols
// (run/Handler/default_handler/enter_seq/exit_seq) are UNCHANGED — the tests above stay GREEN.
// ============================================================================

test "mouse seq literals: enable/disable + comptime enter_full_seq / restore_seq" {
    // enable = 1000 (click) + 1002 (button-event motion/drag) + 1006 (SGR format)
    try std.testing.expectEqualStrings("\x1b[?1000h\x1b[?1002h\x1b[?1006h", mouse_enable_seq);
    // disable = lowercase `l` forms
    try std.testing.expectEqualStrings("\x1b[?1000l\x1b[?1002l\x1b[?1006l", mouse_disable_seq);
    // enter_full_seq = alt+hide-cursor THEN enable mouse (comptime ++ concatenation)
    try std.testing.expectEqualStrings("\x1b[?1049h\x1b[?25l\x1b[?1000h\x1b[?1002h\x1b[?1006h", enter_full_seq);
    // restore_seq = disable mouse FIRST, THEN show cursor + leave alt (signal/panic-safe order)
    try std.testing.expectEqualStrings("\x1b[?1000l\x1b[?1002l\x1b[?1006l\x1b[?25h\x1b[?1049l", restore_seq);
    // S1 consts UNCHANGED (S2 is additive — zero regressions)
    try std.testing.expectEqualStrings("\x1b[?1049h\x1b[?25l", enter_seq);
    try std.testing.expectEqualStrings("\x1b[?25h\x1b[?1049l", exit_seq);
}

test "decodeButton: left/middle/right/none + motion(bit32) + wheel(64/65) + release('m') + mods" {
    // plain button presses (terminator 'M')
    try std.testing.expectEqual(MouseDecode{ .button = .left, .action = .press, .shift = false, .alt = false, .ctrl = false }, decodeButton(0, 'M'));
    try std.testing.expectEqual(MouseDecode{ .button = .middle, .action = .press, .shift = false, .alt = false, .ctrl = false }, decodeButton(1, 'M'));
    try std.testing.expectEqual(MouseDecode{ .button = .right, .action = .press, .shift = false, .alt = false, .ctrl = false }, decodeButton(2, 'M'));
    // release via lowercase 'm' (button retained, NOT legacy b=3)
    try std.testing.expectEqual(MouseDecode{ .button = .left, .action = .release, .shift = false, .alt = false, .ctrl = false }, decodeButton(0, 'm'));
    // motion flag = bit 32 (drag) — button still in low 2 bits
    try std.testing.expectEqual(MouseDecode{ .button = .left, .action = .motion, .shift = false, .alt = false, .ctrl = false }, decodeButton(32, 'M'));
    // wheel = bit 64; up=(b&1)==0, down=(b&1)==1; 'M' terminator, NO release
    try std.testing.expectEqual(MouseDecode{ .button = .none, .action = .wheel_up, .shift = false, .alt = false, .ctrl = false }, decodeButton(64, 'M'));
    try std.testing.expectEqual(MouseDecode{ .button = .none, .action = .wheel_down, .shift = false, .alt = false, .ctrl = false }, decodeButton(65, 'M'));
    // modifier masks: shift=4, alt/meta=8, ctrl=16 (xterm authoritative)
    try std.testing.expectEqual(MouseDecode{ .button = .left, .action = .press, .shift = true, .alt = false, .ctrl = false }, decodeButton(4, 'M'));
    try std.testing.expectEqual(MouseDecode{ .button = .left, .action = .press, .shift = false, .alt = true, .ctrl = false }, decodeButton(8, 'M'));
    try std.testing.expectEqual(MouseDecode{ .button = .left, .action = .press, .shift = false, .alt = false, .ctrl = true }, decodeButton(16, 'M'));
    // Alt-drag: b = 0|8|32 = 40 → left/motion + alt (PRD §7.6 block-drag consumer reads .alt)
    try std.testing.expectEqual(MouseDecode{ .button = .left, .action = .motion, .shift = false, .alt = true, .ctrl = false }, decodeButton(40, 'M'));
    // hover motion no button (1003 only): b = 3|32 = 35 → none/motion
    try std.testing.expectEqual(MouseDecode{ .button = .none, .action = .motion, .shift = false, .alt = false, .ctrl = false }, decodeButton(35, 'M'));
}

test "parseMousePayload: valid 3-field reports + malformed → null" {
    // valid press
    try std.testing.expectEqual(MouseEvent{ .button = .left, .action = .press, .x = 5, .y = 10, .shift = false, .alt = false, .ctrl = false }, parseMousePayload("0;5;10M").?);
    // motion (drag)
    try std.testing.expectEqual(MouseEvent{ .button = .left, .action = .motion, .x = 5, .y = 10, .shift = false, .alt = false, .ctrl = false }, parseMousePayload("32;5;10M").?);
    // wheel up
    try std.testing.expectEqual(MouseEvent{ .button = .none, .action = .wheel_up, .x = 1, .y = 1, .shift = false, .alt = false, .ctrl = false }, parseMousePayload("64;1;1M").?);
    // release (lowercase m)
    try std.testing.expectEqual(MouseEvent{ .button = .left, .action = .release, .x = 1, .y = 1, .shift = false, .alt = false, .ctrl = false }, parseMousePayload("0;1;1m").?);
    // malformed: 2 fields
    try std.testing.expect(parseMousePayload("0;5") == null);
    // malformed: 4 fields
    try std.testing.expect(parseMousePayload("0;5;10;1M") == null);
    // malformed: wrong terminator
    try std.testing.expect(parseMousePayload("0;5;10X") == null);
    // malformed: non-numeric
    try std.testing.expect(parseMousePayload("a;b;cM") == null);
    // malformed: empty
    try std.testing.expect(parseMousePayload("") == null);
}

test "classifyEscSeq: lone Esc, mouse, CSI seq, SS3 seq, Alt+char, malformed-mouse→seq" {
    // lone Esc → .key(0x1b)
    try std.testing.expectEqual(Event{ .key = 0x1b }, classifyEscSeq("\x1b"));
    // SGR mouse → fully decoded .mouse
    try std.testing.expectEqual(Event{ .mouse = .{ .button = .left, .action = .press, .x = 5, .y = 10, .shift = false, .alt = false, .ctrl = false } }, classifyEscSeq("\x1b[<0;5;10M"));
    try std.testing.expectEqual(Event{ .mouse = .{ .button = .none, .action = .motion, .x = 2, .y = 3, .shift = false, .alt = false, .ctrl = false } }, classifyEscSeq("\x1b[<35;2;3M"));
    // non-mouse CSI sequences → raw .seq (bytes INCLUDE leading 0x1b; decoder is P3.M2.T1.S1)
    try std.testing.expectEqualStrings("\x1b[A", classifyEscSeq("\x1b[A").seq.slice());
    try std.testing.expectEqualStrings("\x1b[1;5D", classifyEscSeq("\x1b[1;5D").seq.slice());
    // SS3 sequence
    try std.testing.expectEqualStrings("\x1bOH", classifyEscSeq("\x1bOH").seq.slice());
    // Alt+char (2-byte) → raw .seq
    try std.testing.expectEqualStrings("\x1bx", classifyEscSeq("\x1bx").seq.slice());
    // malformed SGR mouse falls through to raw .seq
    try std.testing.expectEqualStrings("\x1b[<badM", classifyEscSeq("\x1b[<badM").seq.slice());
}

test "readEvent via SliceInput: mouse seq, plain key, lone Esc, eof" {
    // mouse sequence → .mouse
    {
        var fbs = std.io.fixedBufferStream("\x1b[<0;5;10M");
        var s = SliceInput{ .fbs = &fbs };
        const input: Input = .{ .ctx = @ptrCast(&s), .readByteTimeoutFn = SliceInput.readByteTimeout };
        try std.testing.expectEqual(Event{ .mouse = .{ .button = .left, .action = .press, .x = 5, .y = 10, .shift = false, .alt = false, .ctrl = false } }, try readEvent(input));
    }
    // plain key → .key(byte)
    {
        var fbs = std.io.fixedBufferStream("x");
        var s = SliceInput{ .fbs = &fbs };
        const input: Input = .{ .ctx = @ptrCast(&s), .readByteTimeoutFn = SliceInput.readByteTimeout };
        try std.testing.expectEqual(Event{ .key = 'x' }, try readEvent(input));
    }
    // lone Esc (SliceInput returns null at EOF ⇒ lone Esc) → .key(0x1b)
    {
        var fbs = std.io.fixedBufferStream("\x1b");
        var s = SliceInput{ .fbs = &fbs };
        const input: Input = .{ .ctx = @ptrCast(&s), .readByteTimeoutFn = SliceInput.readByteTimeout };
        try std.testing.expectEqual(Event{ .key = 0x1b }, try readEvent(input));
    }
    // empty / EOF → .eof
    {
        var fbs = std.io.fixedBufferStream("");
        var s = SliceInput{ .fbs = &fbs };
        const input: Input = .{ .ctx = @ptrCast(&s), .readByteTimeoutFn = SliceInput.readByteTimeout };
        try std.testing.expectEqual(Event.eof, try readEvent(input));
    }
}

test "default_event_handler.handle: quits on q/Ctrl-C/Esc key events; rest => .none" {
    try std.testing.expectEqual(Action.quit, default_event_handler.handle(.{ .key = 'q' }));
    try std.testing.expectEqual(Action.quit, default_event_handler.handle(.{ .key = 0x03 }));
    try std.testing.expectEqual(Action.quit, default_event_handler.handle(.{ .key = 0x1b }));
    try std.testing.expectEqual(Action.none, default_event_handler.handle(.{ .key = 'j' }));
    // mouse + seq events are handled by richer handlers (P3.M2); default => .none
    try std.testing.expectEqual(Action.none, default_event_handler.handle(.{ .mouse = .{ .button = .left, .action = .press, .x = 1, .y = 1, .shift = false, .alt = false, .ctrl = false } }));
    try std.testing.expectEqual(Action.none, default_event_handler.handle(.{ .seq = makeEscSeq("\x1b[A") }));
    // stateless: ctx is null
    try std.testing.expectEqual(@as(?*anyopaque, null), default_event_handler.ctx);
}
