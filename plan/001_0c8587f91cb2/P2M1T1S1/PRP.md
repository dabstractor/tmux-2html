name: "P2.M1.T1.S1 — Pane geometry + capture-pane command builder (src/capture.zig)"
description: |

---

## Goal

**Feature Goal**: Land `src/capture.zig` — the tmux-capture subsystem's foundation. It reads a
pane's geometry (`cols`/`rows`) from tmux via `display-message`, and builds + executes the
`capture-pane` argv for visible/full modes. Every tmux invocation goes through ONE injectable
`Runner` seam so unit tests feed a fake tmux returning testdata bytes — **no live tmux server
is ever required in unit tests**. cols/rows come from tmux formats (NOT a tty ioctl, because
there is no `/dev/tty` in `run-shell`).

**Deliverable**:
- `src/capture.zig` (NEW) containing: `pub const Size`, `pub const Mode{visible,full}`,
  `pub const Captured`, `pub const Runner` (the vtable seam), `pub const real` (prod runner),
  `pub fn geometry(runner, alloc, pane) !Size`, `pub fn captureCmd(alloc, pane, mode, history)
  !Cmd` (PURE argv builder), `pub fn capture(runner, alloc, pane, mode, history) !Captured`,
  plus a `FakeTmux`-driven unit-test suite.
- `src/main.zig` (MODIFIED) — one line added to the top-level `test { … }` block:
  `_ = @import("capture.zig");` so capture's tests are reachable from the test root.

**Success Definition**: `zig build test -Doptimize=ReleaseFast` exits 0 with capture's unit
tests present and passing: (a) `captureCmd` produces the exact argv for visible AND full modes
(pure, no runner); (b) `geometry` parses `"80 24"` from an injected fake; (c) `capture` returns
`Captured{ ansi=<testdata bytes>, cols=80, rows=24 }` from an injected fake; (d) two fakes with
different testdata don't cross-contaminate. As elsewhere, a Debug-mode `R_X86_64_PC64` link
failure is EXPECTED (PRD §15) — ReleaseFast is the gate. **S1 does NOT wire the `pane`
subcommand body** (that's P2.M1.T2.S1) and does NOT emit the truncation notice (S2).

## User Persona (if applicable)

**Target User**: The `pane`/`region` subcommand bodies (P2.M1.T2.S1, P3.M3) and future
contributors.

**Use Case**: A tmux binding runs `tmux-2html pane --full` via `run-shell`. The pane body needs
the pane's ANSI bytes + its real cols/rows to feed `render.renderGrid`. capture.zig is the
module that produces `Captured{ansi, cols, rows}`. Because `run-shell` has no `/dev/tty`,
cols/rows MUST come from tmux formats (`#{pane_width}`/`#{pane_height}`), never from
`render.getSize()` (ioctl).

**User Journey**: pane body resolves the pane id (`--target` or `$TMUX_PANE`) → calls
`capture.capture(capture.real, alloc, pane, .full, 50000)` → gets `Captured` → frees `ansi` →
calls `render.renderGrid(alloc, c.ansi, .{ .cols = c.cols, .rows = c.rows }, …)`.

**Pain Points Addressed**: (1) no `/dev/tty` in `run-shell` ⇒ geometry from tmux, not ioctl
(PRD §2.2, render_pipeline.md §3); (2) testability — the tmux subprocess must be mockable so the
test suite runs in CI with no tmux installed (PRD §15, system_context.md §3 "MOCKING").

## Why

- **PRD §2.2 / §2.3 compliance.** Pane geometry is read from `#{pane_width}`/`#{pane_height}`
  and passed explicitly to the renderer; defaulting to 80×150 mis-wraps wide panes. There is no
  controlling terminal in a binding, so `getSize()` (ioctl `TIOCGWINSZ`) is unavailable there.
- **Foundation for all of P2/P3.** Every `pane`/`region` flow reduces to
  `capture → renderGrid`. This item lands the capture primitive + its mockable seam so the pane
  body (S2/T2) and the region TUI (P3) can call it concretely.
- **Test isolation.** The `Runner` seam means the entire capture surface (`geometry`/`capture`/
  `captureCmd`) is unit-tested against an injected fake — CI never needs tmux. The real
  subprocess wiring (`capture.real` → `Child.run`) is compile-verified + manually exercised,
  exactly like `palette.queryColors` / `render.getSize` are left (system_context.md §5).

## What

A new self-contained Zig module `src/capture.zig` (imports ONLY `std` — no ghostty, no cli, no
render; it FEEDS render, so it must not import it). It exposes:

1. **`Size`** = `struct { cols: u16, rows: u16 }` (mirrors `render.Size` exactly; the pane body
   copies fields into `render.Size` — `.{ .cols = c.cols, .rows = c.rows }`).
2. **`Mode`** = `enum { visible, full }` (defined LOCALLY, like `palette.Mode`, so capture.zig
   stays cli-free; the pane body maps `cli.PaneOpts` → `capture.Mode`).
3. **`Captured`** = `struct { ansi: []u8, cols: u16, rows: u16 }` — `ansi` is allocator-owned
   (caller frees); cols/rows from tmux.
4. **`Runner`** = the seam: `struct { ctx: *anyopaque, runFn: *const fn(*anyopaque, []const
   []const u8, Allocator) anyerror![]u8, pub fn run(self, argv, alloc) anyerror![]u8 }`.
5. **`real`** = `pub const real: Runner` — shells out via `std.process.Child.run` (env_map
   unset ⇒ inherits `$TMUX`/`$TMUX_PANE`; `max_output_bytes = 1<<28`; `expand_arg0` default
   `.no_expand` still PATH-searches `tmux`).
6. **`geometry(runner, alloc, pane) !Size`** — builds the display-message argv, runs it via
   `runner.run`, trims + splits `"80 24"` → `Size`.
7. **`captureCmd(alloc, pane, mode, history) !Cmd`** — PURE argv builder (no runner, no I/O).
   Returns an owning `Cmd{ argv: [][]const u8, history_token: ?[]u8 }`.
8. **`capture(runner, alloc, pane, mode, history) !Captured`** — `geometry` + `captureCmd` +
   `runner.run` → `Captured`.

### Success Criteria

- [ ] `src/capture.zig` exists and imports ONLY `std`.
- [ ] `captureCmd` is PURE and produces the exact argv (see Implementation Tasks) for visible
      (7 tokens, no `-S`/`-E`) and full (11 tokens incl. `-S`, `-<N>`, `-E`, `-`).
- [ ] `geometry` parses an injected `"80 24\n"` → `Size{80,24}` and rejects malformed output.
- [ ] `capture` returns `Captured{ansi=<fake's bytes>, cols, rows}` via an injected fake.
- [ ] The `Runner` seam lets two fakes with different testdata run without cross-contamination.
- [ ] `capture.real` compiles and shells out via `std.process.Child.run` with inherited env.
- [ ] `zig build test -Doptimize=ReleaseFast` exits 0; capture tests are reachable
      (`main.zig` test block imports capture.zig).

## All Needed Context

### Context Completeness Check

_"If someone knew nothing about this codebase, would they have everything needed to implement
this successfully?"_ **Yes** — this PRP includes the exact verified tmux argv arrays, the
empirically-verified `Child.run` pattern (with the env-inheritance + max-output-bytes + PATH-
resolution facts read from the bundled stdlib AND confirmed by a compiled throwaway program),
the complete `Runner` vtable design (the `*anyopaque`/`@alignCast`/`anyerror![]u8` gotchas), the
exact file/insertion-point guidance, and the explicit scope boundary vs S2.

### Documentation & References

```yaml
# MUST READ — the verified research for THIS task (every claim source-checked + empirically
# confirmed where noted). Read FIRST.
- docfile: plan/001_0c8587f91cb2/P2M1T1S1/research/findings.md
  why: "§1 = the Child.run API (source + empirical), incl. env_map=null=>inherit, max_output_bytes
        default 50KiB MUST be overridden, execvpe PATH-searches with no_expand, Term is
        std.process.Child.Term. §2 = the Runner vtable design + the 0.15.2 *anyopaque/@alignCast
        gotchas. §3 = the exact tmux argv (verified vs the LOCAL tmux 3.6b man page). §4 = the
        S1/S2 scope boundary."
  section: "§1 (subprocess), §2 (seam), §3 (tmux argv), §4 (scope), §5 (codebase facts)"
  critical: "the two highest-risk facts: (1) Child.run's max_output_bytes defaults to 50KiB ->
            error.StdoutStreamTooLong on big scrollback => pass 1<<28; (2) env_map MUST be left
            unset (null) to inherit $TMUX. Both verified empirically (findings §1.2/§1.3)."

# MUST READ — the contract source + the technical constraints this module satisfies.
- docfile: plan/001_0c8587f91cb2/architecture/findings_and_corrections.md
  why: "§3 'tmux integration facts': capture-pane -e -J -p -t, scrollback -S -N -E -, run-shell
        has NO /dev/tty but $TMUX/$TMUX_PANE ARE set => env inheritance is the designed socket
        path. This is WHY geometry uses display-message (not getSize) and WHY env_map=null."
  section: "§3"
- docfile: plan/001_0c8587f91cb2/architecture/render_pipeline.md
  why: "§3 'getSize / explicit geometry': getSize() (ioctl) FAILS in tmux bindings (no tty) =>
        pane/region MUST read cols/rows from tmux display-message. The explicit-size rule
        (§1) is what capture's geometry() feeds."
  section: "§3 (and §1's 'explicit size' rule)"
- docfile: plan/001_0c8587f91cb2/architecture/system_context.md
  why: "§3 'capture.zig' contract: INPUT/LOGIC/OUTPUT/MOCKING — this PRP realizes exactly that
        contract. §5 testing boundaries: 'capture-line-range -> -S/-E derivation' is a unit case
        (captureCmd covers it); integration (live tmux) is separate."
  section: "§3 capture.zig + §5 testing boundaries"

# THE TWO IN-REPO SEAMS this design generalizes — copy their shape.
- file: src/cli.zig
  why: "syncPalette(allocator, args, body: *const fn(...) anyerror!u8) is the injected-function-
        pointer precedent. The Runner.runFn type MUST be anyerror![]u8 (same flexibility) so
        realRun and FakeTmux.run coerce into one pointer type."
  pattern: "pub fn syncPalette(alloc, args, body: *const fn (Allocator, SyncPaletteOpts) anyerror!u8) !u8"
  gotcha: "anyerror (not a narrow error set) in the pointer type — exact same call site as cli.zig."
- file: src/palette.zig
  why: "resolve(allocator, mode, has_tty: bool) is the injected-dependency-as-parameter precedent
        (tests pass has_tty=false so the real /dev/tty is never hit). geometry(runner, ...) mirrors
        this: the I/O dependency is a parameter, never probed internally. ALSO: palette defines its
        OWN local Mode enum ('palette.zig must NOT import cli.zig') — capture.zig defining its own
        Mode{visible,full} is the SAME established convention."
  pattern: "pub fn resolve(allocator, mode: Mode, has_tty: bool) Colors   // infallible; dep injected"
  gotcha: "local Mode enum to stay cli-free (palette.zig does exactly this)."

# THE IN-REPO Child PROCESS PRECEDENT (spawn + reap).
- file: src/render.zig
  why: "spawnXdgOpen is the 0.15.2 Child idiom (Child.init + behaviors + spawn + wait, with an
        explicit wait() to reap — ghostty-org/ghostty#5999 zombie fix). capture's realRun reuses
        this shape, only stdout_behavior=.Pipe (and uses Child.run for capture). ALSO: render.Size
        = struct{cols:u16,rows:u16} — capture.Size mirrors it (capture does NOT import render)."
  pattern: "var child = std.process.Child.init(&.{...}, alloc); child.stdin_behavior=.Ignore; ...
            child.spawn() catch return; _ = child.wait() catch return;"
  gotcha: "always wait() to reap (no zombie). render.Size's field names are cols/rows (u16) — match them."

# THE SUBPROCESS HELPER (verified by reading the bundled stdlib source + a compiled test).
- file: /home/dustin/.local/opt/zig-x86_64-linux-0.15.2/lib/std/process/Child.zig
  why: "Child.run (line 414) is the high-level capture helper: spawns stdin=.Ignore/stdout=.Pipe/
        stderr=.Pipe, collects BOTH via std.Io.poll (deadlock-safe), wait()s, returns RunResult{
        term, stdout, stderr}. env_map=null (default) => inherits parent env (line 605).
        max_output_bytes default 50KiB (line 422) => OVERRIDE. Term (line 187) = union{Exited:u8,
        Signal:u32, Stopped:u32, Unknown:u32} — accessed as std.process.Child.Term."
  pattern: "const r = std.process.Child.run(.{ .allocator=alloc, .argv=argv, .max_output_bytes=MAX }) ...;
            switch (r.term) { .Exited => |code| if (code!=0) return error.TmuxNonZeroExit, else => ... }"
  critical: "max_output_bytes default is 50KiB => too small for scrollback; pass 1<<28. env_map MUST be
             unset to inherit $TMUX. execvpe PATH-searches argv[0] even with expand_arg0=.no_expand."

# THE CONSUMER — what Captured feeds (the pane body, S2/T2, calls this).
- file: src/render.zig
  why: "renderGrid(alloc, ansi, Size{cols,rows}, colors, sel, font, *std.Io.Writer) is the ONE
        render primitive. The pane body (NOT S1) calls it with capture's Captured. capture.zig does
        NOT call renderGrid — it only produces Captured. Size{.cols,.rows} fields copy straight in."
  pattern: "render.renderGrid(alloc, captured.ansi, .{ .cols=captured.cols, .rows=captured.rows }, ...)"
  gotcha: "S1 does NOT write this call — it's shown so you know the shape Captured must have."

# THE CLI TYPES the pane body will map from (S1 does not touch cli, but knows the shape).
- file: src/cli.zig
  why: "PaneOpts{ target:?[]const u8, visible:bool, full:bool, history:u32=50000, ... }. The pane
        body maps PaneOpts -> capture.Mode (opts.full => .full else .visible) and resolves target
        ($TMUX_PANE fallback). S1 only needs to know the field names so its Mode/defaults match."
  gotcha: "history default is 50000 (cli.PaneOpts.history) — capture's captureCmd default N must agree."
```

### Current Codebase tree (relevant subset)

```bash
src/
  main.zig           # top-level `test {}` block imports palette/render/golden_test (MODIFIED: +capture)
  cli.zig            # PaneOpts{target,visible,full,history}, syncPalette(*const fn) seam — UNCHANGED
  palette.zig        # local Mode enum + resolve(alloc,mode,has_tty) injected-dep precedent — UNCHANGED
  render.zig         # renderGrid + Size{cols,rows} + spawnXdgOpen (Child precedent) — UNCHANGED
  ghostty_format.zig # vendored formatter — UNCHANGED
  golden_test.zig    # golden harness — UNCHANGED
build.zig            # exe + test step; capture.zig is auto-included (it's under src/) — UNCHANGED
build.zig.zon        # — UNCHANGED
testdata/            # .ansi fixtures exist; capture tests may @embedFile one (optional) — UNCHANGED
```

### Desired Codebase tree with files to be added/modified

```bash
src/
  capture.zig        # NEW — Size, Mode, Captured, Runner, real, geometry, captureCmd, capture, tests
  main.zig           # MODIFIED — +1 line in the `test {}` block: _ = @import("capture.zig");
# No build.zig / build.zig.zon / cli.zig changes (capture.zig is auto-compiled as part of src/).
```

### Known Gotchas of our codebase & Library Quirks

```zig
// CRITICAL (verified empirically + from stdlib source): std.process.Child.run's
// `max_output_bytes` DEFAULTS TO 50 KiB. A full-scrollback capture-pane output (up to 50000
// lines × cols × SGR bytes) BLOWS PAST 50 KiB => error.StdoutStreamTooLong. capture's realRun
// MUST pass .max_output_bytes = 1 << 28 (256 MiB, matching render.MAX_STDIN). Geometry's output
// is tiny ("80 24\n") but pass the same generous cap uniformly.

// CRITICAL (verified empirically): env_map MUST be left UNSET (null) in Child.run so the child
// tmux INHERITS the parent's $TMUX / $TMUX_PANE (the socket path). Source: Child.zig:605
// (if env_map) build-from-map else inherit-parent-environ. A compiled test confirmed a child
// sees the parent $PATH (len 624) with env_map unset. Do NOT set .env_map.

// CRITICAL: there is NO /dev/tty in run-shell (PRD §2.2). So geometry() reads cols/rows from
// tmux display-message "#{pane_width} #{pane_height}" — NEVER call render.getSize() (ioctl) in
// the pane/region path. (render.getSize is for the interactive `render` subcommand only.)

// CRITICAL (Debug link bug, PRD §15): `zig build test` (Debug) FAILS to LINK (R_X86_64_PC64
// relocations from the bundled C++ SIMD libs). The GATE is: zig build test -Doptimize=ReleaseFast.
// capture.zig does NOT touch ghostty-vt Terminal.init => its tests are NOT subject to render.zig's
// "one renderGrid test scope" cross-test GOTCHA => capture tests CAN be separate `test` fns.

// GOTCHA: Term is `std.process.Child.Term` (NOT `std.process.Term` — that path does not exist).
// Term = union(enum){ Exited:u8, Signal:u32, Stopped:u32, Unknown:u32 }. Detect non-zero:
//   switch (result.term) { .Exited => |code| if (code != 0) return error.TmuxNonZeroExit,
//   else => return error.TmuxAbnormalExit }

// GOTCHA: execvpe PATH-searches argv[0] even with expand_arg0=.no_expand (the default). So
// argv[0]="tmux" resolves on PATH with NO extra config (matches render.spawnXdgOpen's "xdg-open").
// Verified empirically (argv[0]="sh" resolved with expand_arg0 unset). Do NOT pass an absolute
// path and do NOT set .expand_arg0.

// GOTCHA (Runner seam, Zig 0.15.2): ctx is the MUTABLE `*anyopaque`. *T -> *anyopaque via
// @ptrCast(&x) (dest inferred from the field). *anyopaque -> *T via @ptrCast(@alignCast(ctx)) —
// @alignCast is MANDATORY (anyopaque has unknown alignment; skipping traps in Debug / UB in
// ReleaseFast). The state backing ctx MUST be a mutable lvalue (`var`), so &x is *T and coerces
// to *anyopaque (a `const` yields *const T which does NOT coerce). runFn uses default .auto
// calling convention; plain fn addresses coerce with no callconv(...). runFn's type MUST be
// anyerror![]u8 (not a narrow set) so realRun + FakeTmux.run share one pointer type (exactly
// like cli.syncPalette's `body: *const fn(...) anyerror!u8`).

// GOTCHA: capture-pane's SGR state carries CONTINUOUSLY across lines (no per-line reset) and
// output is \n-terminated per logical line. capture() returns the raw bytes; the RENDERER (not
// capture) feeds them through renderGrid's per-byte \n->\r\n loop. capture must NOT split or
// munge the stream.

// GOTCHA: capture.zig imports ONLY std. It must NOT import cli.zig (cli must stay ghostty-free
// AND capture is a lower layer than render). Define Mode/Size/Captured locally (palette.zig's
// precedent). The pane body (main.zig, which already imports everything) bridges cli.PaneOpts
// -> capture.Mode and Captured -> render.renderGrid args.
```

## Implementation Blueprint

### Data models and structure

```zig
// src/capture.zig — ALL of these are NEW. capture.zig imports ONLY std.

/// Pane geometry from tmux. Mirrors render.Size's field names/types (cols:u16, rows:u16)
/// so the pane body copies fields straight into render.Size. capture.zig does NOT import
/// render (it FEEDS render; importing it would invert the layering), so this is a local copy.
pub const Size = struct { cols: u16, rows: u16 };

/// Capture mode (PRD §5.2 --visible default vs --full). Defined LOCALLY (like palette.Mode)
/// so capture.zig stays cli-free. The pane body maps cli.PaneOpts -> Mode.
pub const Mode = enum { visible, full };

/// The capture result. `ansi` is allocator-owned (caller frees with the same allocator);
/// cols/rows come from tmux display-message (NOT a tty ioctl).
pub const Captured = struct { ansi: []u8, cols: u16, rows: u16 };

/// The injectable executor seam. ONE method. Every tmux invocation (geometry, capture) goes
/// through runner.run(argv, alloc). PROD passes `capture.real`; tests pass a Runner backed by
/// FakeTmux whose ctx carries the testdata bytes. Generalizes cli.syncPalette's injected
/// `*const fn` (now stateful {ctx,runFn}) and palette.resolve's per-call dep injection.
pub const Runner = struct {
    ctx: *anyopaque,
    runFn: *const fn (ctx: *anyopaque, argv: []const []const u8, alloc: std.mem.Allocator) anyerror![]u8,
    pub fn run(self: Runner, argv: []const []const u8, alloc: std.mem.Allocator) anyerror![]u8 {
        return self.runFn(self.ctx, argv, alloc);
    }
};

/// Owning wrapper for captureCmd's argv. `argv` is the token array (caller passes to
/// runner.run); `history_token` is the ONE dynamically-allocated entry ("-<N>", full mode
/// only) that deinit frees. The pane slice and the static literals ("tmux","capture-pane",
/// "-e",...) are BORROWED/static (NOT freed) — only history_token + the array itself are owned.
/// Realizes the contract's "captureCmd(pane,mode,history) argv" with clean lifetime mgmt.
pub const Cmd = struct {
    argv: [][]const u8,
    history_token: ?[]u8 = null,
    pub fn deinit(self: *Cmd, alloc: std.mem.Allocator) void {
        if (self.history_token) |t| alloc.free(t);
        alloc.free(self.argv);
    }
};
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: CREATE src/capture.zig — types + constants + the Runner seam
  - IMPLEMENT: Size, Mode, Captured, Runner (vtable), Cmd (owning argv wrapper) — see "Data
    models" above (copy verbatim).
  - CONSTANT: `const MAX_OUTPUT: usize = 1 << 28;` (256 MiB cap; overrides Child.run's 50 KiB
    default — the #1 gotcha).
  - NAMING: PascalCase types; the Runner method is `run` (not `runFn` — that's the FIELD).
  - PLACEMENT: src/capture.zig (top of file). Imports: `const std = @import("std");` ONLY.

Task 2: IMPLEMENT the REAL runner — `realRun` + `pub const real`
  - IMPLEMENT realRun(ctx, argv, alloc) anyerror![]u8 per "Implementation Patterns" below:
    `std.process.Child.run(.{ .allocator=alloc, .argv=argv, .max_output_bytes=MAX_OUTPUT })`
    with env_map UNSET (=> inherits $TMUX/$TMUX_PANE). defer-free result.stderr; switch on
    result.term (.Exited code!=0 => error.TmuxNonZeroExit after freeing stdout; else =>
    error.TmuxAbnormalExit); return result.stdout on success.
  - STATE: `const RealState = struct {};` + `var real_state: RealState = .{};` (a `var` so
    &real_state is *RealState -> *anyopaque; NEVER `const` — see gotcha).
  - `pub const real: Runner = .{ .ctx = @ptrCast(&real_state), .runFn = realRun };`
  - FOLLOW pattern: render.zig spawnXdgOpen (Child idiom + ghostty#5999 reap). Child.run reaps
    internally (returns term) so no manual wait() needed.
  - GOTCHA: do NOT set .env_map (must inherit), do NOT set .expand_arg0 (no_expand PATH-searches),
    DO set .max_output_bytes=MAX_OUTPUT (default 50 KiB is too small).

Task 3: IMPLEMENT captureCmd — the PURE argv builder (no runner, no I/O)
  - SIGNATURE: `pub fn captureCmd(alloc: std.mem.Allocator, pane: []const u8, mode: Mode,
    history: u32) !Cmd`
  - BODY: build a `std.ArrayList([]const u8)` (unmanaged, .empty; appendSlice/deinit/toOwnedSlice
    take alloc — the 0.15.2 ArrayList idiom, see palette.zig). Base tokens (BOTH modes):
    `{ "tmux", "capture-pane", "-e", "-J", "-p", "-t", pane }` (7). If mode==.full: allocPrint
    the history token `"-{d}"` (.{history}) => e.g. "-50000" (OWNED, stored in Cmd.history_token),
    then append `{ "-S", hist, "-E", "-" }` (4 more => 11 total). Return Cmd{ argv: toOwnedSlice,
    history_token: hist-if-full-else-null }. The pane slice is BORROWED (caller keeps it alive
    during runner.run; capture() does).
  - NAMING/PLACEMENT: the function is PURE (deterministic, no I/O) — directly unit-testable.
  - GOTCHA: `-S`/`-E` take the NEXT argv token as their value even when it starts with `-`
    (so "-S","-50000" and "-S","-" parse correctly). NEVER glue ("-S-50000" is wrong). The
    history_token "-<N>" is the string "-50000" (leading minus is part of the token).

Task 4: IMPLEMENT geometry — display-message + parse
  - SIGNATURE: `pub fn geometry(runner: Runner, alloc: std.mem.Allocator, pane: []const u8) !Size`
  - BODY: `const out = try runner.run(&.{ "tmux", "display-message", "-p", "-t", pane,
    "#{pane_width} #{pane_height}" }, alloc); defer alloc.free(out);` then `const s =
    std.mem.trim(u8, out, " \t\n\r");` split on ' ' (splitScalar); parseInt(u16) both fields;
    return Size. Malformed => error.BadGeometry.
  - GOTCHA: the format string is ONE argv token "#{pane_width} #{pane_height}" (with a literal
    space) => ONE subprocess call printing "80 24\n". Use display-message (HYPHEN), NOT
    display_message. Do NOT pass -l (it suppresses expansion). Trim before splitting (tmux may
    emit a trailing newline).

Task 5: IMPLEMENT capture — geometry + capture-pane run -> Captured
  - SIGNATURE: `pub fn capture(runner: Runner, alloc: std.mem.Allocator, pane: []const u8,
    mode: Mode, history: u32) !Captured`
  - BODY: `const size = try geometry(runner, alloc, pane);` then `var cmd = try
    captureCmd(alloc, pane, mode, history); defer cmd.deinit(alloc);` then `const ansi = try
    runner.run(cmd.argv, alloc);` then `return .{ .ansi = ansi, .cols = size.cols, .rows =
    size.rows };`. (ansi is owned by the caller via Captured; capture does NOT free it.)
  - DEPENDENCIES: Tasks 3+4. The pane slice passed to captureCmd is kept alive through
    runner.run by capture's own frame.

Task 6: IMPLEMENT the FakeTmux + unit tests (NO live tmux)
  - IMPLEMENT FakeTmux{ cols:u16, rows:u16, ansi:[]const u8 } with a `fn run(ctx, argv, alloc)
    anyerror![]u8` that: recovers `const self: *FakeTmux = @ptrCast(@alignCast(ctx));` then if
    hasArg(argv,"display-message") => allocPrint "{d} {d}" (.{cols,rows}); else if
    hasArg(argv,"capture-pane") => alloc.dupe(u8, self.ansi); else error.UnexpectedArgv. Add a
    `fn hasArg(argv, needle) bool` helper.
  - TEST "captureCmd: visible mode argv is exactly 7 tokens, no -S/-E" — assert each token +
    history_token==null.
  - TEST "captureCmd: full mode argv is 11 tokens incl. -S -<history> -E -" — assert tokens,
    history_token==-50000 (for history=50000), and that argv[8]==history_token.? (same slice).
  - TEST "geometry: fake returns '80 24' => Size{80,24}" + a malformed case ("bogus") =>
    error.BadGeometry.
  - TEST "capture: fake returns testdata ansi + geometry => Captured{ansi,cols,rows}" — assert
    the bytes match (use a literal like "\x1b[31mred\x1b[0m\nplain\n" OR @embedFile a testdata
    .ansi; the literal is simplest and needs no build.zig change).
  - TEST "two fakes with different testdata do not cross-contaminate" — proves the per-instance
    ctx needs NO mutable global (the Option-B failure mode). This is the key mockability proof.
  - TEST "captureCmd: history formats the -N token" — e.g. history=1000 => "-1000".
  - PLACEMENT: all tests in src/capture.zig (capture does NOT touch Terminal.init => separate
    test fns are safe; no cross-test GOTCHA). Use std.testing.allocator (verify no leaks).

Task 7: MODIFY src/main.zig — reach capture's tests from the test root
  - ADD one line to the top-level `test { … }` block (alongside the existing
    `_ = @import("palette.zig");`, `_ = @import("render.zig");`, `_ = @import("golden_test.zig");`):
    `_ = @import("capture.zig"); // P2.M1: keep capture.zig unit tests reachable.`
  - PRESERVE: all existing imports + tests. NO other main.zig change (the pane BODY is S2/T2).
  - GOTCHA: capture.zig is auto-compiled on the prod path too (it's under src/), so importing it
    in the test block is the ONLY wiring needed — no build.zig change.
```

### Implementation Patterns & Key Details

```zig
// ===== realRun — the prod subprocess (verified empirically + from stdlib source) =====
// Child.run: spawns stdin=.Ignore/stdout=.Pipe/stderr=.Pipe, collects both via std.Io.poll
// (deadlock-safe), wait()s (reaps — no zombie), returns RunResult{term,stdout,stderr}.
// env_map UNSET => inherits $TMUX/$TMUX_PANE. max_output_bytes OVERRIDDEN (default 50KiB!).
fn realRun(ctx: *anyopaque, argv: []const []const u8, alloc: std.mem.Allocator) anyerror![]u8 {
    _ = ctx; // stateless
    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = argv,
        .max_output_bytes = MAX_OUTPUT, // 1<<28 — NOT the 50 KiB default (would truncate big panes)
        // .env_map omitted => child INHERITS parent env ($TMUX, $TMUX_PANE, PATH)
        // .expand_arg0 omitted (.no_expand) => execvpe still PATH-searches "tmux"
    }) catch return error.TmuxSpawnFailed;
    defer alloc.free(result.stderr); // collected but unused
    switch (result.term) {
        .Exited => |code| if (code != 0) {
            alloc.free(result.stdout);
            return error.TmuxNonZeroExit;
        },
        else => { // .Signal / .Stopped / .Unknown
            alloc.free(result.stdout);
            return error.TmuxAbnormalExit;
        },
    }
    return result.stdout; // caller owns
}

// ===== captureCmd — PURE argv builder (the contract deliverable) =====
pub fn captureCmd(alloc: std.mem.Allocator, pane: []const u8, mode: Mode, history: u32) !Cmd {
    var list: std.ArrayList([]const u8) = .empty; // unmanaged (0.15.2 idiom; palette.zig uses this)
    errdefer list.deinit(alloc);
    try list.appendSlice(alloc, &.{ "tmux", "capture-pane", "-e", "-J", "-p", "-t", pane });
    var hist_tok: ?[]u8 = null;
    if (mode == .full) {
        hist_tok = try std.fmt.allocPrint(alloc, "-{d}", .{history}); // e.g. "-50000" (OWNED)
        errdefer alloc.free(hist_tok.?);
        try list.appendSlice(alloc, &.{ "-S", hist_tok.?, "-E", "-" });
    }
    return .{ .argv = try list.toOwnedSlice(alloc), .history_token = hist_tok };
}

// ===== geometry — display-message + parse (verified tmux argv) =====
pub fn geometry(runner: Runner, alloc: std.mem.Allocator, pane: []const u8) !Size {
    const out = try runner.run(
        &.{ "tmux", "display-message", "-p", "-t", pane, "#{pane_width} #{pane_height}" },
        alloc,
    );
    defer alloc.free(out);
    const s = std.mem.trim(u8, out, " \t\n\r");
    var it = std.mem.splitScalar(u8, s, ' ');
    const cols_s = it.next() orelse return error.BadGeometry;
    const rows_s = it.next() orelse return error.BadGeometry;
    if (it.next() != null) return error.BadGeometry; // extra token => malformed
    const cols = std.fmt.parseInt(u16, cols_s, 10) catch return error.BadGeometry;
    const rows = std.fmt.parseInt(u16, rows_s, 10) catch return error.BadGeometry;
    return .{ .cols = cols, .rows = rows };
}

// ===== capture — geometry + capture-pane run -> Captured =====
pub fn capture(runner: Runner, alloc: std.mem.Allocator, pane: []const u8, mode: Mode, history: u32) !Captured {
    const size = try geometry(runner, alloc, pane);
    var cmd = try captureCmd(alloc, pane, mode, history);
    defer cmd.deinit(alloc);
    const ansi = try runner.run(cmd.argv, alloc); // caller owns via Captured
    return .{ .ansi = ansi, .cols = size.cols, .rows = size.rows };
}

// ===== FakeTmux — the test double (NO live tmux) =====
const FakeTmux = struct {
    cols: u16,
    rows: u16,
    ansi: []const u8, // testdata bytes returned for capture-pane
    fn run(ctx: *anyopaque, argv: []const []const u8, alloc: std.mem.Allocator) anyerror![]u8 {
        const self: *FakeTmux = @ptrCast(@alignCast(ctx)); // @alignCast MANDATORY (0.15.2)
        if (hasArg(argv, "display-message"))
            return std.fmt.allocPrint(alloc, "{d} {d}", .{ self.cols, self.rows });
        if (hasArg(argv, "capture-pane"))
            return alloc.dupe(u8, self.ansi); // caller frees
        return error.UnexpectedArgv;
    }
};
fn hasArg(argv: []const []const u8, needle: []const u8) bool {
    for (argv) |a| if (std.mem.eql(u8, a, needle)) return true;
    return false;
}

// ===== real — the concrete prod Runner (the pane body passes THIS) =====
const RealState = struct {};
var real_state: RealState = .{}; // `var` (not const) so &real_state is *RealState -> *anyopaque
pub const real: Runner = .{ .ctx = @ptrCast(&real_state), .runFn = realRun };
```

**Blessed argv reference (sanity-check captureCmd against these EXACT tokens):**
```
visible: ["tmux","capture-pane","-e","-J","-p","-t","<PANE>"]                              (7 tokens)
full:    ["tmux","capture-pane","-e","-J","-p","-t","<PANE>","-S","-<N>","-E","-"]         (11 tokens)
geometry:["tmux","display-message","-p","-t","<PANE>","#{pane_width} #{pane_height}"]      (stdout "80 24\n")
```
(Verified: findings.md §3, cross-checked vs the LOCAL `tmux 3.6b` man page + PRD §2.1/§5.2; tmux ≥ 3.2 floor.)

### Integration Points

```yaml
TEST ROOT (src/main.zig):
  - add: "_ = @import(\"capture.zig\");" to the existing top-level `test { }` block
  - pattern: "mirror the existing _ = @import(\"palette.zig\"); / render.zig / golden_test.zig lines"
  - preserve: "all existing imports + tests; NO pane-body wiring (that's S2/T2)"

BUILD (build.zig) / PACKAGE (build.zig.zon):
  - NO CHANGE — capture.zig under src/ is auto-compiled on both prod + test paths. New test fns
    in an imported file are pulled in automatically.

DOWNSTREAM CONSUMERS (NOT modified by S1 — shown so the Captured shape is unambiguous):
  - pane body (P2.M1.T2.S1): capture.capture(capture.real, alloc, pane, .full, 50000) -> Captured;
    then render.renderGrid(alloc, c.ansi, .{ .cols=c.cols, .rows=c.rows }, colors, null, font, &w)
  - pane body resolves pane id: opts.target orelse (std.posix.getenv("TMUX_PANE") orelse error) and
    maps cli.PaneOpts -> capture.Mode (opts.full => .full else .visible). S1 does NOT do this.
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# After creating src/capture.zig + editing main.zig:
zig build -Doptimize=ReleaseFast            # prod build must succeed (capture.zig compiles on the prod path)
zig build test -Doptimize=ReleaseFast       # the GATE — see Level 2
# Expected: both exit 0. A Debug-mode R_X86_64_PC64 link error is EXPECTED (PRD §15), NOT a defect.
# If ReleaseFast fails to COMPILE, the likely causes (in order): (1) `std.process.Term` used instead
# of `std.process.Child.Term`; (2) a `const` (not `var`) backing the ctx => *const T won't coerce to
# *anyopaque; (3) a narrow error set on runFn instead of anyerror![]u8; (4) missing @alignCast on the
# *anyopaque -> *FakeTmux recovery. Read the compile error; they're all self-explanatory.
```

### Level 2: Unit Tests (Component Validation)

```bash
# The gate. MUST exit 0.
zig build test -Doptimize=ReleaseFast

# Confirm capture's tests actually RAN (not silently skipped). Build the test runner and grep:
zig build test -Doptimize=ReleaseFast --summary all 2>&1 | head -40
# Expected: "All N tests passed" (N grew by ~6 capture tests), no failures. If a capture test FAILS,
# the name (e.g. "capture: fake returns testdata ansi + geometry") names the culprit.
```

### Level 3: Integration Testing (System Validation) — OPTIONAL / manual

```bash
# capture.zig is unit-tested via fakes (no live tmux in CI). This level is a MANUAL sanity check
# that capture.real actually shells out (not asserted in unit tests, mirroring palette.queryColors).
# Run ONLY if a tmux server is available; skip in CI. Prove the argv flags are right directly:
if command -v tmux >/dev/null 2>&1 && [ -n "$TMUX" ]; then
  tmux display-message -p -t "$TMUX_PANE" '#{pane_width} #{pane_height}'   # => e.g. "200 50"
  tmux capture-pane -e -J -p -t "$TMUX_PANE" | head                          # visible
  tmux capture-pane -e -J -p -t "$TMUX_PANE" -S -50000 -E - | head           # full, capped
  echo "argv flags verified against a live tmux"
fi
# Expected (if run): geometry two integers; visible = current screen; full = scrollback included.
# The capture realRun pattern (Child.run, env_map=null, max_output override) is the SAME verified
# pattern used in the compiled throwaway (findings §1.3); geometry/capture just pick argv + parse.
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Mockability proof (the contract's #5 requirement): prove NO live tmux is needed.
# The "two fakes don't cross-contaminate" test (Task 6) IS this proof — it must pass. Confirm it ran:
zig build test -Doptimize=ReleaseFast 2>&1 | grep -qi 'contamination\|cross' && echo "mockability OK"

# Scope-discipline check: capture.zig must import ONLY std (no cli/render/ghostty). Verify:
grep -n '@import' src/capture.zig   # expect exactly ONE line: const std = @import("std");
# (any other @import = a layering violation — capture must stay self-contained.)

# Contract-shape check: the named deliverables exist + are pub:
grep -nE 'pub const (Size|Mode|Captured|Runner|real)\b|pub fn (geometry|captureCmd|capture)\b' src/capture.zig
# expect: Size, Mode, Captured, Runner, real (consts) + geometry, captureCmd, capture (fns).

# History-cap argv check (PRD §15 "capture-line-range -> -S/-E derivation" unit case):
# captureCmd(.full, 50000) MUST yield the 11-token argv with -S -50000 -E -. The Task-6 test pins it.
```

## Final Validation Checklist

### Technical Validation

- [ ] `zig build -Doptimize=ReleaseFast` succeeds (prod unaffected; capture compiles on the prod path).
- [ ] `zig build test -Doptimize=ReleaseFast` exits 0.
- [ ] capture's ~6 unit tests appear in the test output and pass.
- [ ] A Debug-mode link failure (`R_X86_64_PC64`) is NOT treated as a defect.
- [ ] `grep '@import' src/capture.zig` shows exactly ONE import (`std`) — no layering violation.

### Feature Validation

- [ ] `captureCmd(.visible)` => 7 tokens `["tmux","capture-pane","-e","-J","-p","-t",pane]`, history_token null.
- [ ] `captureCmd(.full, 50000)` => 11 tokens incl. `-S`,`-50000`,`-E`,`-`; history_token == `-50000`.
- [ ] `geometry` parses an injected `"80 24"` => `Size{80,24}`; rejects malformed output.
- [ ] `capture` returns `Captured{ansi=<fake bytes>, cols, rows}` from an injected fake.
- [ ] Two fakes with different testdata don't cross-contaminate (mockability proof).
- [ ] `real` compiles and shells out via `Child.run` with env_map unset (inherits) + max_output_bytes overridden.
- [ ] main.zig's test block imports capture.zig (tests reachable).

### Code Quality Validation

- [ ] capture.zig imports ONLY `std` (no cli/render/ghostty) — self-contained lower layer.
- [ ] `Runner` vtable mirrors the `*anyopaque` + `anyerror![]u8` shape of cli.syncPalette's `body`.
- [ ] `Mode`/`Size`/`Captured` defined locally (palette.zig's local-Mode precedent).
- [ ] `Cmd.deinit` frees exactly history_token + the argv array (no borrowed/static double-free).
- [ ] No `build.zig` / `build.zig.zon` / `cli.zig` changes (capture auto-compiled; main.zig +1 line only).
- [ ] No scope creep: S1 produces `Captured` + the seam; it does NOT wire the pane body or emit notices.

### Documentation & Deployment

- [ ] No new env vars. No user-facing docs (contract DOCS §5: "none — internal").
- [ ] The pane-body consumption shape is documented above for P2.M1.T2.S1 (the next item).
- [ ] No new licensing — original code.

---

## Anti-Patterns to Avoid

- ❌ Don't call `render.getSize()` (ioctl) in the capture path — there is NO `/dev/tty` in run-shell
  (PRD §2.2). Read cols/rows from `tmux display-message "#{pane_width} #{pane_height}"`. getSize is
  for the interactive `render` subcommand only.
- ❌ Don't leave `max_output_bytes` at Child.run's default (50 KiB) — a full-scrollback capture-pane
  output far exceeds it => `error.StdoutStreamTooLong`. Pass `MAX_OUTPUT = 1 << 28`.
- ❌ Don't set `.env_map` — it MUST be unset (null) so the child tmux inherits `$TMUX`/`$TMUX_PANE`
  (the socket path). Verified empirically (findings §1.3).
- ❌ Don't use `std.process.Term` — it doesn't exist; it's `std.process.Child.Term`. (The throwaway
  verify program hit exactly this compile error.)
- ❌ Don't back the `Runner.ctx` with a `const` — `&const_x` is `*const T`, which does NOT coerce to
  the mutable `*anyopaque`. Use a `var` (real_state, and `var fake = …` in tests).
- ❌ Don't skip `@alignCast` when recovering a typed pointer from `*anyopaque` — it traps in Debug /
  is UB in ReleaseFast (findings §2).
- ❌ Don't give `runFn` a narrow error set — it MUST be `anyerror![]u8` so realRun + FakeTmux.run
  share one pointer type (exactly cli.syncPalette's `body: *const fn(...) anyerror!u8`).
- ❌ Don't import cli/render/ghostty into capture.zig — it's a lower layer that FEEDS render. Define
  Mode/Size/Captured locally (palette.zig's local-Mode precedent). The pane body bridges types.
- ❌ Don't glue `-S` to its value (`-S-50000`) — `-S`/`-E` take the NEXT argv token; pass them as
  separate tokens (`"-S"`, `"-50000"`). The `-50000` token's leading minus is part of the string.
- ❌ Don't run tests in Debug — the `R_X86_64_PC64` link failure is a toolchain bug (PRD §15), not
  your code. The gate is `zig build test -Doptimize=ReleaseFast`.
- ❌ Don't wire the `pane` subcommand body or emit the truncation notice here — that's P2.M1.T2.S1
  (pane wiring) and P2.M1.T1.S2 (truncation notice) respectively. S1 produces `Captured` + the seam.
- ❌ Don't split or munge the captured ANSI stream — SGR state carries continuously across lines
  (no per-line reset); capture returns the raw bytes and the RENDERER feeds them via renderGrid's
  per-byte `\n`→`\r\n` loop.
- ❌ Don't use a mutable global (`pub var runner = real;`) for the seam — per-test testdata lives in
  `Runner.ctx` (per-instance), so fakes never cross-contaminate. The repo has ZERO mutable-global
  seams; the per-call-threaded `runner` parameter mirrors palette.resolve's `has_tty` injection.
