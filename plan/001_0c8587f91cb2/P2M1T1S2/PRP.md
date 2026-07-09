name: "P2.M1.T1.S2 — Parse capture output → Captured; visible vs full; history cap + truncation flag"
description: |

---

## REVISED PRP — addresses Issue Feedback (attempt 1/3)

The original S2 PRP failed because it was a **fragile MODIFY/delta on top of S1's end-state**
(rename `Size`→`Geometry`, add a field to an existing `Captured`, replace S1's 2-field
`parseGeom`, leave S1's `captureCmd`/`realRun` "unchanged"), but **S1's deliverable
(`src/capture.zig`) did not exist** — S1 was marked "Complete" in `tasks.json` while its code was
absent. There was nothing to delta against.

**Root-cause fix (now landed):** S1 has since been implemented and **S2 was folded into it**.
`src/capture.zig` now exists and already contains the complete S1+S2 shape (a 3-field
`Geometry`, a `Captured` with `truncated`, the `effectiveHistory`/`wasTruncated` helpers, and
the 6-arg `capture(..., configured_limit)`). The truncation **notice emission** lives in the pane
subcommand (`src/main.zig`), which is also already present.

**Therefore this revised PRP is SELF-CONTAINED** — it specifies the COMPLETE S2 surface of
`capture.zig` (not a delta on a separate S1), so it can never again be broken by a missing
prerequisite. Because the implementation is already present and the gate is green (verified:
`zig build -Doptimize=ReleaseFast` and `zig build test -Doptimize=ReleaseFast` both exit 0), the
implementing agent's job is to **VERIFY the contract is met against the live code, confirm the
gate stays green, and fill any genuine gap** (none is expected). The one place the implementation
deliberately diverges from the contract's literal wording — **truncation is detected via
`#{history_size} > effective`, NOT by counting captured rows** — is a researched, necessary
improvement and MUST NOT be reverted (see "Known Gotchas").

---

## Goal

**Feature Goal**: `capture.zig` parses a pane's `capture-pane` ANSI into a self-contained
`Captured` result that distinguishes **visible** (default) from **full** (scrollback) modes,
applies the `@tmux-2html-history-limit` cap (default 50 000) when computing the `-S`/`-E` line
range, and sets a deterministic `truncated: bool` flag when the pane's scrollback exceeded the
effective cap. The flag is surfaced so the pane subcommand (P2.M1.T2.S1) can emit the PRD §13
"status notice".

**Deliverable**: The S2-relevant surface of `src/capture.zig` — already implemented and verified
present:
- `pub const Captured = struct { ansi: []u8, cols: u16, rows: u16, truncated: bool, history_size: u32, effective: u32 }` (src/capture.zig:45).
- `pub const Geometry = struct { cols: u16, rows: u16, history_size: u32 }` (src/capture.zig:35) — the 3-field geometry, with `history_size` (`#{history_size}`) added for truncation detection.
- `pub fn effectiveHistory(cli_history: u32, configured_limit: u32) u32` (src/capture.zig:165) — PURE `@min(cli, configured)`.
- `pub fn wasTruncated(mode: Mode, history_size: u32, effective: u32) bool` (src/capture.zig:172) — PURE, `mode == .full and history_size > effective`.
- `pub fn geometry(runner, alloc, pane)` (src/capture.zig:186) — runs `display-message` with format `"#{pane_width} #{pane_height} #{history_size}"`, parses EXACTLY 3 ints.
- `pub fn capture(runner, alloc, pane, mode, history, configured_limit)` (src/capture.zig:214) — passes the EFFECTIVE cap (not raw `history`) into `captureCmd`'s `-S`, and computes `truncated` via `wasTruncated`.
- Unit tests covering: `effectiveHistory` (min), `wasTruncated` (full+`>`/`==`/`<`, visible), `capture` (truncation per `history_size`, effective = min(cli, configured)), and `captureCmd` visible/full argv (the PRD §15 "capture-line-range → -S/-E derivation" case).
- NOTICE emission realized in the pane subcommand layer: `panePrepare` (src/main.zig) computes the notice text from `cap.truncated`/`cap.effective`/`cap.history_size`; `paneBody` writes it to stderr + best-effort `tmux display-message`.

**Success Definition**: `zig build test -Doptimize=ReleaseFast` exits 0 with the S2 capture tests
present and passing; every contract point in "What → Success Criteria" is verifiable against the
live code; the `history_size`-based truncation approach is intact (not reverted to row counting);
no regression to P1 (palette/render/golden) or the pane subcommand.

## User Persona (if applicable)

**Target User**: The pane subcommand body (P2.M1.T2.S1) and the future region TUI (P3).

**Use Case**: A tmux binding runs `tmux-2html pane --full`. The pane body calls
`capture.capture(capture.real, alloc, pane, .full, opts.history, configured_limit)`, receives
`Captured{ansi, cols, rows, truncated, history_size, effective}`, frees `ansi`, renders the grid
with `.{ .cols = cap.cols, .rows = cap.rows }`, and — when `cap.truncated` — emits the notice.

**Pain Points Addressed**: (1) huge scrollback (`history-limit` up to 1 000 000) would otherwise
produce multi-GB captures — capped at the effective limit; (2) the user must be told when older
output was dropped (the `truncated` flag + subcommand notice).

## Why

- **PRD §5.2 + §13 compliance.** `--full` must capture `[-S -<history> -E -]`; `--visible`
  (default) only the visible rows. Huge scrollback is capped at `@tmux-2html-history-limit`
  (default 50k) with a status notice when truncated.
- **Deterministic truncation signal.** Row counting is ambiguous (see findings.md); the live
  `#{history_size}` is the exact, deterministic signal and is captured in the SAME geometry
  `display-message` call (no extra subprocess).
- **Decoupling.** `capture.zig` takes the RESOLVED `configured_limit` as a parameter (it does NOT
  query `@tmux-2html-history-limit` itself) and exposes the flag; the subcommand layer resolves
  the option + emits the notice. This keeps `capture.zig` option-naming-free and testable with a
  `FakeTmux` (no live tmux in unit tests).

## What

The capture subsystem, for a given pane + mode, produces a `Captured` whose `truncated` field is
**true iff mode == .full and the pane's `#{history_size}` strictly exceeded the effective cap**
(`min(--history, @tmux-2html-history-limit)`). The `-S` flag passed to `capture-pane` receives
that effective cap (NOT the raw `--history`), so tmux returns the most-recent `effective` history
lines + the visible pane; anything older is dropped ⇒ truncated.

> **Contract wording note (DO NOT "fix").** The contract literally says *"if the captured row
> count hit the cap, set a `truncated` flag."* Counting captured rows is **fundamentally
> ambiguous** and is NOT how this is implemented — see "Known Gotchas". The implemented
> `#{history_size} > effective` test is the correct, researched realization of that intent.

### Success Criteria (each verifiable against the live `src/capture.zig`)

- [ ] `Captured` includes `truncated: bool` (src/capture.zig:45,49).
- [ ] `Geometry` carries `history_size: u32` from a 3-field `display-message` format
      `"#{pane_width} #{pane_height} #{history_size}"` (src/capture.zig:35,38,186,188).
- [ ] `effectiveHistory(cli, configured) == @min(cli, configured)` — PURE (src/capture.zig:165).
- [ ] `wasTruncated(.full, hs, eff) == (hs > eff)`; `==` ⇒ false; `.visible` ⇒ always false
      (src/capture.zig:172-173).
- [ ] `capture(...)` passes the EFFECTIVE cap into `captureCmd` (so `-S` gets `min(...)`), and
      sets `truncated = wasTruncated(mode, geom.history_size, eff)` (src/capture.zig:214-240).
- [ ] `captureCmd(.full, N)` yields the 11-token argv `["tmux","capture-pane","-e","-J","-p",
      "-t",pane,"-S","-<N>","-E","-"]`; `.visible` yields the 7-token argv with no `-S`/`-E`.
- [ ] `-S/-E` derivation + truncation logic are unit-tested with a `FakeTmux` (NO live tmux);
      two fakes with different testdata do not cross-contaminate.
- [ ] The pane subcommand (`src/main.zig`) emits the notice (stderr + best-effort
      `display-message`) when `cap.truncated` is true; it computes the limit default (50000) when
      the option is unset.

## All Needed Context

### Context Completeness Check

_"If someone knew nothing about this codebase, would they have everything needed to implement
this successfully?"_ **Yes.** The S2 surface is fully specified here (signatures, line numbers,
exact tmux argv, the FakeTmux pattern, the validation gate, and the one deliberate deviation with
its proof). Because the implementation is already present, this PRP doubles as an exact contract
to verify against — no guessing.

### Documentation & References

```yaml
# MUST READ — the S2 research (the truncation-design proof). Read FIRST.
- docfile: plan/001_0c8587f91cb2/P2M1T1S2/research/findings.md
  why: "Proves row counting is ambiguous (100k cap 50k → 50k rows TRUNCATED vs 50k cap 50k → 50k
        rows NOT truncated — identical row counts); establishes truncated = (mode==full) and
        (history_size > effective). Live-verified #{history_size} (49), the 3-field geometry
        format, and that #{@tmux-2html-history-limit} returns empty when unset."
  critical: "Do NOT revert the history_size approach to row counting. This is the single most
            important fact for this item."

# MUST READ — the upstream contract this item realizes.
- docfile: plan/001_0c8587f91cb2/architecture/system_context.md
  why: "§3 'capture.zig' contract: build `tmux capture-pane -e -J -p -t <pane> [-S -<hist> -E -]`,
        read geometry via display-message, shells out using the $TMUX socket. §5 testing boundaries
        list 'capture-line-range -> -S/-E derivation' as a required unit case."
  section: "§3 (capture.zig) + §5 (testing)"

# PRD sections cited by the work item.
- docfile: plan/001_0c8587f91cb2/prd_snapshot.md
  why: "§5.2 (pane flags: --visible default vs --full; --history N default 50000; capture-pane
        -e -J -p -t <pane> [-S -N -E - | <none>]). §13 (huge scrollback up to 1,000,000 capped at
        @tmux-2html-history-limit default 50k with a status notice). §9.2 (@tmux-2html-history-limit
        default 50000). §15 (testing: capture-line-range -> -S/-E derivation is a unit case)."
  section: "§5.2, §9.2, §13, §15"

# THE IMPLEMENTATION UNDER VERIFICATION (read in full).
- file: src/capture.zig
  why: "The complete S1+S2 module. VERIFY the S2 surface here: Captured.truncated, Geometry.
        history_size, effectiveHistory, wasTruncated, geometry (3-field), capture (6-arg, passes
        effective into captureCmd), and the truncation tests."
  pattern: "PURE helpers (effectiveHistory/wasTruncated) are directly unit-testable; capture()
            threads the Runner seam so FakeTmux drives it (no live tmux)."
  gotcha: "captureCmd receives the EFFECTIVE cap, NOT raw history — this is the cap wiring."

# THE NOTICE EMITTER (subcommand layer; part of P2.M1.T2.S1 but already present).
- file: src/main.zig
  why: "panePrepare computes the notice text from cap.truncated/effective/history_size (NO I/O —
        unit-testable); paneBody emits it (stderr + best-effort display-message) and resolves the
        @tmux-2html-history-limit default (50000) when unset. Confirms the S2 flag is consumed."
  section: "fn panePrepare (~line 318), fn paneBody (~line 393), panePrepare tests (~line 669+)"

# THE CONSUMER of Captured.cols/rows (not modified by S2 — confirms the shape).
- file: src/render.zig
  why: "renderGrid(alloc, ansi, render.Size{cols,rows}, ...). The pane body maps
        Geometry{cols,rows} -> render.Size; history_size/truncated are NOT passed to renderGrid
        (truncated drives the notice only)."

# THE CLI TYPES the limit default comes from (not modified by S2).
- file: src/cli.zig
  why: "PaneOpts{ target, visible, full, history: u32 = 50000 }. The --history default (50000)
        must agree with the @tmux-2html-history-limit default (50000); the tighter cap wins."
```

### Current Codebase tree (relevant subset)

```bash
src/
  capture.zig        # PRESENT (S1+S2 folded): Geometry(3-field), Captured(+truncated), Mode,
                     #   Runner, real, captureCmd, effectiveHistory, wasTruncated, geometry,
                     #   capture(6-arg), queryOption/querySessionName/resolveOutputDir/filename
                     #   helpers, FakeTmux test suite. Imports ONLY std+builtin.
  main.zig           # PRESENT: pane body (panePrepare testable core + paneBody) emits the
                     #   truncation notice; test block imports capture.zig (line ~470).
  cli.zig            # PaneOpts.history: u32 = 50000 — UNCHANGED by S2.
  palette.zig        # local-Mode + resolve(alloc,mode,has_tty) precedent — UNCHANGED.
  render.zig         # renderGrid + render.Size{cols,rows} — UNCHANGED.
  ghostty_format.zig # vendored formatter — UNCHANGED.
  golden_test.zig    # golden harness — UNCHANGED.
build.zig            # capture.zig auto-compiled under src/ — UNCHANGED.
```

### Desired Codebase tree

```bash
src/capture.zig      # UNCHANGED in shape — S2 surface already present. (Verify only.)
src/main.zig         # UNCHANGED — notice emission already present. (Verify only.)
# No new files, no build/cli changes. If a genuine gap is found, EDIT src/capture.zig in place
# using the self-contained spec below (do NOT recreate the file or touch unrelated symbols).
```

### Known Gotchas of our codebase & Library Quirks

```zig
// CRITICAL (THE deliberate deviation — DO NOT REVERT): The contract says "if the captured row
// count hit the cap, set truncated". Row counting is AMBIGUOUS:
//   history_size=100000, cap=50000 -> tmux emits 50000 history lines (TRUNCATED)
//   history_size= 50000, cap=50000 -> tmux emits 50000 history lines (NOT truncated)
// Identical captured row counts — counting newlines CANNOT distinguish them. The implemented
// test `wasTruncated(mode, history_size, effective) = (mode==.full) and (history_size > effective)`
// is the deterministic, correct signal (strict `>`: ==cap means everything fit => NOT truncated).
// This is live-verified (findings.md) and MUST be preserved.

// CRITICAL: capture() passes the EFFECTIVE cap (min(cli, configured)) into captureCmd, so the
// `-S` flag gets `-<effective>` (NOT the raw --history). The line range and the cap are the SAME
// number by design. Do not pass raw `history` to `-S`.

// CRITICAL (Debug link bug, PRD §15): `zig build test` (Debug) FAILS to LINK (R_X86_64_PC64
// relocations from bundled C++ SIMD libs). The GATE is `zig build test -Doptimize=ReleaseFast`.
// capture.zig does NOT touch ghostty-vt Terminal.init => its tests are safe as separate `test`
// fns (no render.zig single-test-scope cross-test GOTCHA).

// CRITICAL: geometry's display-message format is ONE argv token:
//   "#{pane_width} #{pane_height} #{history_size}"  (literal spaces) => ONE subprocess call
//   printing e.g. "80 24 49\n". parse must require EXACTLY 3 ints (reject 2 and 4). Use
//   display-message (HYPHEN), not display_message. Do NOT pass -l.

// GOTCHA: `-S`/`-E` take the NEXT argv token as their value even when it starts with `-`. NEVER
// glue ("-S-50000" is wrong); pass separate tokens ("−S","-50000","−E","-"). The "-<N>" token's
// leading minus is part of the string (allocPrint("-{d}", .{N}) => "-50000").

// GOTCHA: capture.zig imports ONLY std (+builtin). It must NOT import cli/render/ghostty (it is
// a lower layer that FEEDS render). Mode/Geometry/Captured are defined locally (palette.zig's
// local-Mode precedent). The configured_limit is a PARAMETER, not queried inside capture.zig.

// GOTCHA (Runner seam, Zig 0.15.2): recover a typed ptr from *anyopaque with
// @ptrCast(@alignCast(ctx)) — @alignCast is MANDATORY (skipping traps in Debug / UB in
// ReleaseFast). The state backing ctx MUST be a `var` (so &x is *T -> *anyopaque; a `const`
// yields *const T which does NOT coerce). runFn's type MUST be anyerror![]u8 so realRun +
// FakeTmux.run share one pointer type (exactly cli.syncPalette's `body: *const fn(...) anyerror!u8`).

// GOTCHA: capture-pane's SGR state carries CONTINUOUSLY across lines (no per-line reset).
// capture() returns the raw bytes; the RENDERER feeds them via renderGrid. capture must NOT
// split/munge the stream.
```

## Implementation Blueprint

### Data models and structure (self-contained spec of the S2 surface)

> These are the **target** definitions. They are ALREADY present in `src/capture.zig`; the agent
> verifies each matches (line numbers cited). If any symbol is missing/different, restore it to
> exactly this shape.

```zig
// src/capture.zig — imports ONLY std (+builtin).

pub const Mode = enum { visible, full }; // local enum (palette.zig precedent); visible is default

/// 3-field geometry. history_size is the pane's CURRENT scrollback line count (#{history_size});
/// it drives truncation detection. cols/rows feed render.Size.
pub const Geometry = struct { cols: u16, rows: u16, history_size: u32 };

/// Capture result. ansi is allocator-OWNED (caller frees). truncated is set by capture() when the
/// pane's scrollback exceeded the effective cap (PRD §13). history_size/effective are surfaced so
/// the subcommand can build the notice text (capture sets them; pane renders the message).
pub const Captured = struct {
    ansi: []u8,
    cols: u16,
    rows: u16,
    truncated: bool,
    history_size: u32,
    effective: u32,
};

/// The injectable executor seam (one method). PROD passes capture.real; tests pass a Runner
/// backed by FakeTmux. NO mutable global => per-test testdata never cross-contaminates.
pub const Runner = struct {
    ctx: *anyopaque,
    runFn: *const fn (ctx: *anyopaque, argv: []const []const u8, alloc: std.mem.Allocator) anyerror![]u8,
    pub fn run(self: Runner, argv: []const []const u8, alloc: std.mem.Allocator) anyerror![]u8 {
        return self.runFn(self.ctx, argv, alloc);
    }
};
```

### Implementation Tasks (ordered: VERIFY-first, EDIT only on a found gap)

```yaml
Task 1: VERIFY the S2 surface is present in src/capture.zig
  - READ src/capture.zig in full. Confirm these symbols/behaviors (line refs above):
      * Captured.truncated: bool (and history_size/effective)            (capture.zig:45)
      * Geometry{ cols, rows, history_size }                            (capture.zig:35)
      * effectiveHistory(cli, configured) -> @min                        (capture.zig:165)
      * wasTruncated(mode, hs, eff) = (mode==.full) and (hs > eff)       (capture.zig:172)
      * geometry 3-field format + EXACTLY-3-ints parse                   (capture.zig:186)
      * capture(...) passes EFFECTIVE cap into captureCmd; sets truncated (capture.zig:214)
  - CONFIRM capture.zig imports ONLY std+builtin (grep '@import' => exactly 2 lines).
  - NO EDIT if all present and correct. This is the expected outcome.

Task 2: VERIFY the truncation logic matches the RESEARCHED approach (DO NOT revert)
  - CONFIRM wasTruncated uses #{history_size} > effective (NOT row/newline counting).
  - Read plan/001_0c8587f91cb2/P2M1T1S2/research/findings.md §"KEY DESIGN DECISION" for the
    ambiguity proof. If anyone changed it to count rows, RESTORE the history_size test.
  - NAMING/SHAPE: strict `>` (history_size == effective => everything fit => NOT truncated);
    .visible => always false.

Task 3: VERIFY captureCmd wiring (the -S/-E derivation, PRD §15 unit case)
  - CONFIRM captureCmd(alloc, pane, .full, N) builds 11 tokens:
      ["tmux","capture-pane","-e","-J","-p","-t",pane,"-S","-<N>","-E","-"]
    and .visible builds 7 tokens with NO -S/-E. The "-<N>" token = allocPrint("-{d}", .{N}).
  - CONFIRM capture() calls captureCmd with the EFFECTIVE cap (eff), NOT raw history.
  - GOTCHA: never glue -S to its value; separate tokens.

Task 4: VERIFY the notice is emitted by the subcommand layer (src/main.zig)
  - READ panePrepare (~src/main.zig:318): computes notice text (allocPrint) when cap.truncated,
    using cap.effective + cap.history_size. paneBody (~src/main.zig:393): writes notice to stderr
    + best-effort `tmux display-message`.
  - CONFIRM the @tmux-2html-history-limit default (50000) is applied when the option is unset/
    non-numeric (panePrepare parses queryOption result, defaults to 50000 on parse failure).
  - SCOPE: notice emission belongs to the pane subcommand (P2.M1.T2.S1) but is ALREADY present;
    S2 only owns the FLAG + helpers that drive it. Do not move logic between layers.

Task 5: VERIFY the S2 unit tests exist and cover the contract
  - CONFIRM these test fns exist in src/capture.zig (and the pane truncation test in main.zig):
      * "effectiveHistory: min of the two"
      * "wasTruncated: full + history_size>eff => true; ==eff => false; visible => false"
      * "capture: fake ansi + geometry => Captured (truncated per history_size)"
      * "capture: effective = min(cli, configured)"
      * "captureCmd: visible => ... 7 tokens ..."  AND  "... full => 11 tokens ... -S -<history> -E -"
      * "geometry: fake '80 24 49' => Geometry{80,24,49}" + malformed => error.BadGeometry
      * (main.zig) "panePrepare: full with big history_size + small history => notice set (truncated)"
  - IF a named behavior is UNTESTED, ADD a focused test mirroring the existing FakeTmux pattern
    (per-instance ctx; std.testing.allocator for leak checks). This is the only likely edit.

Task 6: RUN THE GATE (the authoritative success check)
  - `zig build -Doptimize=ReleaseFast`           # prod build (capture compiles on the prod path)
  - `zig build test -Doptimize=ReleaseFast`       # THE GATE — must exit 0
  - EXPECTED: exit 0. A Debug-mode R_X86_64_PC64 link failure is NOT a defect (PRD §15).
```

### Implementation Patterns & Key Details

```zig
// ===== effectiveHistory — PURE min (the cap wiring) =====
pub fn effectiveHistory(cli_history: u32, configured_limit: u32) u32 {
    return @min(cli_history, configured_limit); // tighter cap wins (both default 50000)
}

// ===== wasTruncated — PURE, the deterministic signal (DO NOT use row counting) =====
pub fn wasTruncated(mode: Mode, history_size: u32, effective: u32) bool {
    return (mode == .full) and (history_size > effective); // strict > ; ==cap => NOT truncated
}

// ===== capture — geometry + capture-pane run -> Captured (S2: effective cap + truncated) =====
pub fn capture(
    runner: Runner,
    alloc: std.mem.Allocator,
    pane: []const u8,
    mode: Mode,
    history: u32,
    configured_limit: u32,
) CaptureError!Captured {
    const geom = try geometry(runner, alloc, pane);
    const eff = effectiveHistory(history, configured_limit);
    const trunc = wasTruncated(mode, geom.history_size, eff);
    var cmd = try captureCmd(alloc, pane, mode, eff); // pass eff (the cap), NOT raw history
    defer cmd.deinit(alloc);
    const ansi = runner.run(cmd.argv, alloc) catch |err| switch (err) { /* map -> CaptureError */ };
    return .{
        .ansi = ansi,
        .cols = geom.cols,
        .rows = geom.rows,
        .truncated = trunc,
        .history_size = geom.history_size,
        .effective = eff,
    };
}

// ===== captureCmd — PURE argv builder (the -S/-E derivation; verified vs tmux man page) =====
pub fn captureCmd(alloc: std.mem.Allocator, pane: []const u8, mode: Mode, history: u32) !Cmd {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(alloc);
    try list.appendSlice(alloc, &.{ "tmux", "capture-pane", "-e", "-J", "-p", "-t", pane });
    var hist_tok: ?[]u8 = null;
    if (mode == .full) {
        hist_tok = try std.fmt.allocPrint(alloc, "-{d}", .{history}); // "-50000" (OWNED)
        errdefer alloc.free(hist_tok.?);
        try list.appendSlice(alloc, &.{ "-S", hist_tok.?, "-E", "-" });
    }
    return .{ .argv = try list.toOwnedSlice(alloc), .history_token = hist_tok };
}

// ===== geometry — 3-field display-message (history_size added for S2 truncation) =====
pub fn geometry(runner: Runner, alloc: std.mem.Allocator, pane: []const u8) CaptureError!Geometry {
    const out = runner.run(
        &.{ "tmux", "display-message", "-p", "-t", pane, "#{pane_width} #{pane_height} #{history_size}" },
        alloc,
    ) catch |err| switch (err) { /* map -> CaptureError */ };
    defer alloc.free(out);
    const s = std.mem.trim(u8, out, " \t\n\r");
    var it = std.mem.splitScalar(u8, s, ' ');
    const cols_s = it.next() orelse return error.BadGeometry;
    const rows_s = it.next() orelse return error.BadGeometry;
    const hist_s = it.next() orelse return error.BadGeometry;
    if (it.next() != null) return error.BadGeometry; // a 4th token => malformed
    const cols = std.fmt.parseInt(u16, cols_s, 10) catch return error.BadGeometry;
    const rows = std.fmt.parseInt(u16, rows_s, 10) catch return error.BadGeometry;
    const history_size = std.fmt.parseInt(u32, hist_s, 10) catch return error.BadGeometry;
    return .{ .cols = cols, .rows = rows, .history_size = history_size };
}

// ===== FakeTmux test double — NO live tmux; per-instance state in ctx =====
const FakeTmux = struct {
    cols: u16, rows: u16, history_size: u32, ansi: []const u8, /* + options map */
    fn run(ctx: *anyopaque, argv: []const []const u8, alloc: std.mem.Allocator) anyerror![]u8 {
        const self: *FakeTmux = @ptrCast(@alignCast(ctx)); // @alignCast MANDATORY (0.15.2)
        if (hasArg(argv, "display-message")) {
            if (hasArg(argv, "#{pane_width} #{pane_height} #{history_size}"))
                return std.fmt.allocPrint(alloc, "{d} {d} {d}", .{ self.cols, self.rows, self.history_size });
            // ... session_name branch ...
        }
        if (hasArg(argv, "capture-pane")) return alloc.dupe(u8, self.ansi);
        // ... show-option branch ...
        return error.UnexpectedArgv;
    }
};
```

**Blessed argv reference (sanity-check captureCmd + geometry against these EXACT tokens):**
```
visible: ["tmux","capture-pane","-e","-J","-p","-t","<PANE>"]                       (7 tokens)
full:    ["tmux","capture-pane","-e","-J","-p","-t","<PANE>","-S","-<N>","-E","-"]  (11 tokens)
geometry:["tmux","display-message","-p","-t","<PANE>","#{pane_width} #{pane_height} #{history_size}"]
```
(Verified: P2M1T1S2/research/findings.md + the LOCAL tmux 3.6b man page; tmux ≥ 3.2 floor.)

### Integration Points

```yaml
CONSUMER (pane subcommand — already present, NOT built by S2):
  - main.zig panePrepare: configured_limit = parse(queryOption("@tmux-2html-history-limit")) default 50000;
    cap = capture.capture(capture.real, alloc, target, mode, opts.history, configured_limit);
    render.renderGrid(alloc, cap.ansi, .{ .cols = cap.cols, .rows = cap.rows }, colors, null, font, &w);
    if (cap.truncated) build + emit notice(cap.effective, cap.history_size).
  - S2 owns: the flag + effective/wasTruncated helpers + the 6-arg capture signature.
  - The subcommand owns: option resolution + notice text + notice I/O.

BUILD / PACKAGE / CLI:
  - NO CHANGE. capture.zig under src/ is auto-compiled; new test fns are pulled in via the
    existing `_ = @import("capture.zig");` in main.zig's test block.

TEST ROOT (src/main.zig):
  - ALREADY imports capture.zig (line ~470). S2 adds NO main.zig test-root line.
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Verify the module compiles on the prod path (capture is on the prod path).
zig build -Doptimize=ReleaseFast
# Expected: exit 0. A Debug-mode R_X86_64_PC64 link error is EXPECTED (PRD §15), not a defect.

# Layering invariant: capture.zig must import ONLY std (+builtin).
grep -n '@import' src/capture.zig   # expect exactly: const std = @import("std"); + builtin
```

### Level 2: Unit Tests (the GATE)

```bash
# The authoritative gate. MUST exit 0.
zig build test -Doptimize=ReleaseFast
# Expected: exit 0. If a capture test fails, its name (e.g. "wasTruncated: ...") names the culprit.

# Confirm the S2 tests actually ran (not silently skipped) and the named contract cases exist:
grep -nE 'test "(effectiveHistory|wasTruncated|capture: |captureCmd: |geometry: )' src/capture.zig
grep -n 'notice set (truncated)' src/main.zig
```

### Level 3: Integration Testing (manual; OPTIONAL — needs a live tmux)

```bash
# capture.zig is unit-tested via fakes (no live tmux in CI). This is a MANUAL sanity check that
# the argv + the history_size signal behave against a real tmux. Run ONLY inside a tmux session.
if command -v tmux >/dev/null 2>&1 && [ -n "$TMUX" ]; then
  tmux display-message -p -t "$TMUX_PANE" '#{pane_width} #{pane_height} #{history_size}'  # => "C R H"
  tmux capture-pane -e -J -p -t "$TMUX_PANE" -S -50000 -E - | wc -l                          # capped
  echo "argv + history_size verified against live tmux"
fi
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Contract-shape check: the S2 deliverables exist + are pub:
grep -nE 'pub const (Captured|Geometry|Mode)\b|pub fn (effectiveHistory|wasTruncated|capture|captureCmd|geometry)\b' src/capture.zig

# Deviation-guard: truncation MUST use history_size, NOT row counting. Confirm the strict-> test:
grep -n 'history_size > effective' src/capture.zig   # expect exactly the wasTruncated body

# Cap-wiring guard: capture() must pass the EFFECTIVE cap into captureCmd (not raw history):
grep -n 'captureCmd(alloc, pane, mode, eff)' src/capture.zig   # eff = effectiveHistory(...)

# Leak guard: std.testing.allocator is used in every capture test (verify no leaks slipped in).
grep -n 'std.testing.allocator' src/capture.zig | head
```

## Final Validation Checklist

### Technical Validation

- [ ] `zig build -Doptimize=ReleaseFast` exits 0.
- [ ] `zig build test -Doptimize=ReleaseFast` exits 0 (the gate).
- [ ] capture's S2 unit tests are present and pass (effectiveHistory, wasTruncated, capture
      truncation, captureCmd visible/full, geometry 3-field).
- [ ] A Debug-mode link failure (`R_X86_64_PC64`) is NOT treated as a defect (PRD §15).
- [ ] `grep '@import' src/capture.zig` shows only `std` (+`builtin`) — no layering violation.

### Feature Validation

- [ ] `Captured.truncated: bool` exists and is set by `capture()` only when `mode == .full` and
      `history_size > effective`.
- [ ] `effectiveHistory(cli, configured) == @min(...)`; both default to 50000.
- [ ] `capture(...)` passes the EFFECTIVE cap into `captureCmd` (`-S` gets `min(...)`).
- [ ] `captureCmd(.full, N)` => 11 tokens incl. `-S`,`-<N>`,`-E`,`-`; `.visible` => 7 tokens.
- [ ] `geometry` parses a 3-field `"C R H"` and rejects 2-field / 4-field / non-numeric output.
- [ ] The pane subcommand emits the notice (stderr + display-message) when `cap.truncated`, and
      applies the 50000 default when `@tmux-2html-history-limit` is unset.
- [ ] The truncation approach uses `#{history_size}`, NOT row counting (NOT reverted).

### Code Quality Validation

- [ ] capture.zig imports ONLY std (+builtin); Mode/Geometry/Captured defined locally.
- [ ] `effectiveHistory`/`wasTruncated` are PURE (directly unit-testable, no I/O).
- [ ] `Runner` seam is unchanged (per-instance ctx; `anyerror![]u8` runFn); two fakes don't
      cross-contaminate.
- [ ] No `build.zig` / `build.zig.zon` / `cli.zig` changes; no new files (verify-only unless a
      genuine gap forces an in-place edit).
- [ ] No scope creep: S2 owns the flag + helpers; the subcommand owns option resolution + notice.

### Documentation & Deployment

- [ ] No new env vars. No user-facing docs (contract DOCS §5: "none — internal").
- [ ] Any edit is self-documenting (the existing doc-comments explain the history_size rationale).

---

## Anti-Patterns to Avoid

- ❌ Don't implement truncation by **counting captured rows / newlines** — it is ambiguous (the
  100k-cap-50k vs 50k-cap-50k case). Use `wasTruncated(mode, history_size, effective)` =
  `(mode == .full) and (history_size > effective)`. This is the single most important guard.
- ❌ Don't pass the RAW `--history` into `captureCmd`/`-S` — pass the EFFECTIVE cap
  (`effectiveHistory(...)`). The cap and the line-range value are the same number by design.
- ❌ Don't treat the contract's literal "captured row count hit the cap" as a spec to implement
  literally — it is realized by the `history_size` test (researched + live-verified).
- ❌ Don't query `@tmux-2html-history-limit` inside `capture.zig` — it takes the RESOLVED
  `configured_limit` as a parameter (keeps capture option-naming-free + testable with a fake).
  Option resolution + the 50000 default belong to the pane subcommand (main.zig).
- ❌ Don't move the notice emission into `capture.zig` — the contract delegates it to "the
  subcommand layer" (main.zig panePrepare/paneBody), where it already lives.
- ❌ Don't run tests in Debug — the `R_X86_64_PC64` link failure is a toolchain bug (PRD §15). The
  gate is `zig build test -Doptimize=ReleaseFast`.
- ❌ Don't glue `-S` to its value (`-S-50000`) — `-S`/`-E` take the NEXT argv token; pass them
  separately. The `-50000` token's leading minus is part of the string.
- ❌ Don't recreate `src/capture.zig` or touch unrelated symbols — the file is present and the gate
  is green; verify against the spec above and EDIT in place ONLY if a genuine gap is found.
- ❌ Don't import cli/render/ghostty into capture.zig — it is a lower layer that FEEDS render.
- ❌ Don't use a mutable global for the seam — per-test testdata lives in `Runner.ctx` (per-
  instance); fakes never cross-contaminate.

---

## Confidence Score

**9/10** for one-pass success. Rationale: the S2 contract is **already implemented** in
`src/capture.zig` (S1+S2 folded), the pane subcommand already emits the notice, and both
`zig build -Doptimize=ReleaseFast` and `zig build test -Doptimize=ReleaseFast` were verified
EXIT 0 immediately before this PRP was written. The remaining work is verification + gap-fill
(only a missing/insufficient test would require an edit), and the one design-critical invariant
(history_size-based truncation, not row counting) is documented with its proof and an explicit
DO-NOT-REVERT guard. The −1 accounts for the unusual "verify-existing" nature: an agent expecting
to write fresh code must correctly read this as a verification task and not destabilize working
code.
