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
    _ = std.posix.write(saved_fd, exit_seq) catch {};
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
    try std.fs.File.stdout().writeAll(enter_seq); // alt screen + hide cursor
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
