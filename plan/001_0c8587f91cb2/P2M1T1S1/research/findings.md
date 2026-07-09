# P2.M1.T1.S1 — Research findings (capture.zig: pane geometry + capture-pane builder)

> Consolidated, PRP-consistent research notes. The PRP (`../PRP.md`) is authoritative for
> naming/design (`Runner` vtable, `Cmd` owning-argv struct); this file is the supporting
> evidence. Three independent threads, all verified: Thread A (Zig 0.15.2 `Child` stdout
> capture) read from the BUNDLED STDLIB SOURCE + confirmed by a COMPILED throwaway program;
> Thread B (mockable seam) from focused subagent research vs the repo's two existing seams;
> Thread C (tmux argv) cross-checked against the LOCAL `tmux 3.6b` man page (`man 1 tmux`)
> AND the project PRD/architecture docs.

## 0. The task (contract recap)

`src/capture.zig` is the tmux-capture subsystem. CONTRACT:
1. NO `/dev/tty` in run-shell ⇒ read pane cols/rows from tmux via
   `display-message -p -t <pane> '#{pane_width} #{pane_height}'` (NOT getSize()). capture-pane
   flags `-e -J -p -t`; scrollback `-S -<N> -E -`; visible = omit `-S`/`-E`. `$TMUX`/`$TMUX_PANE`
   are set for run-shell children.
2. INPUT: pane id (`--target` or `$TMUX_PANE`), mode (visible/full), history limit (default 50000).
3. LOGIC: `geometry(pane) !Size` runs display-message; `captureCmd(pane, mode, history)` builds
   the argv; both shell out via `std.process.Child` with INHERITED env (`$TMUX` ⇒ right socket).
4. OUTPUT: `Captured { ansi: []u8, cols: u16, rows: u16 }` (cols/rows from tmux, NOT ioctl).
5. MOCKING: `geometry()`/`capture()` behind function pointers / an interface so unit tests
   inject a fake tmux returning testdata `.ansi`. NEVER require a live tmux server in unit tests.
DOCS: none — internal.

## 1. Thread A — Zig 0.15.2 `std.process.Child` stdout capture (VERIFIED: source + compiled test)

Stdlib: `/home/dustin/.local/opt/zig-x86_64-linux-0.15.2/lib/std/process/Child.zig`. `zig version` ⇒ 0.15.2.

### 1.1 `Child.run` (Child.zig:414) — the high-level helper (USE THIS)

Spawns stdin=`.Ignore`, stdout=`.Pipe`, stderr=`.Pipe`; collects BOTH via `std.Io.poll`
(deadlock-safe — polls stdout+stderr simultaneously); `wait()`s (reaps — no zombie); returns:

```zig
pub const RunResult = struct { term: Term, stdout: []u8, stderr: []u8 };
pub fn run(args: struct {
    allocator: mem.Allocator,
    argv: []const []const u8,
    cwd: ?[]const u8 = null, cwd_dir: ?fs.Dir = null,
    env_map: ?*const EnvMap = null,          // null (default) ⇒ INHERIT parent env
    max_output_bytes: usize = 50 * 1024,     // DEFAULT 50 KiB — OVERRIDE for big panes!
    expand_arg0: Arg0Expand = .no_expand,
    progress_node: std.Progress.Node = std.Progress.Node.none,
}) RunError!RunResult;
```
Caller OWNS `result.stdout` + `result.stderr` (free with `allocator`).

### 1.2 CRITICAL facts (read from source; #1–#4 ALSO confirmed by a compiled throwaway)

1. **ENV INHERITANCE:** `env_map: ?*const EnvMap = null` default ⇒ at Child.zig:605 the spawn
   does `if (self.env_map) |m| {...} else {...inherit parent environ...}`. **Leave `env_map`
   unset ⇒ child inherits `$TMUX`/`$TMUX_PANE`.** Empirically confirmed: a child spawned with
   `env_map` unset saw the parent `$PATH` (len 624, contains `/usr/bin`).
2. **`max_output_bytes` default 50 KiB** ⇒ far too small for a full-scrollback capture
   (`error.StdoutStreamTooLong`). capture's `realRun` passes `MAX_OUTPUT = 1 << 28`.
3. **`expand_arg0 = .no_expand` (default) STILL searches PATH.** On POSIX spawn calls
   `posix.execvpeZ_expandArg0(.no_expand, argv0, argv, envp)` (Child.zig:661) — `execvpe` is the
   'p' variant ⇒ PATH-searches when `argv[0]` has no slash. So `argv[0]="tmux"` resolves with no
   extra config. Empirically confirmed (`argv[0]="sh"` resolved). Matches `render.spawnXdgOpen`.
4. **`Term` is `std.process.Child.Term`** (NOT `std.process.Term` — that path does not exist).
   `Term = union(enum){ Exited:u8, Signal:u32, Stopped:u32, Unknown:u32 }` (Child.zig:187).
   Empirically confirmed (`.Exited = 7` for `exit 7`).
5. **Reaping:** `Child.run` `wait()`s internally (returns `term`) ⇒ no manual `wait()`/zombie.
   (The ghostty-org/ghostty#5999 concern `render.spawnXdgOpen`'s manual `wait()` addresses.)

### 1.3 Empirical results (compiled `verify_stdout.zig`, 0.15.2, ALL PASSED)

```
T1 stdout='hello-capture-OK'  term=.{ .Exited = 0 }   # readToEndAlloc(child.stdout.?) works
T2 stdout=''  exit code = 7 (expect 7)                # non-zero via .Exited
T3 child $PATH len = 624 (>0 proves inheritance)       # env_map=null INHERITS parent env
T4 stdout len = 200000 (expect 200000)                 # NO deadlock on 200KB (>64KB pipe) w/ read-before-wait
T5 PATH-resolved argv[0]='sh' stdout='pathok'          # argv[0] PATH-resolves w/ expand_arg0 unset
```
(The manual alternative — `spawn()` → `stdout=.Pipe`,`stderr=.Inherit` → `child.stdout.?.readToEndAlloc` →
`wait()` — is ALSO deadlock-safe + env-inheriting + verified. `Child.run` is preferred: simpler, captures
stderr for diagnostics, uses `std.Io.poll`. Either works for `realRun`.)

## 2. Thread B — the mockable seam (`Runner` vtable — PRP-authoritative design)

RECOMMENDED (see PRP "Implementation Patterns"): a single-method `Runner` vtable, threaded
per-call as the FIRST arg to `geometry()`/`capture()`. Canonical Zig stdlib idiom (same shape
as `std.mem.Allocator`'s `{ptr,vtable}` and `std.io.Writer`'s `{context,writeFn}`).

```zig
pub const Runner = struct {
    ctx: *anyopaque,
    runFn: *const fn (ctx: *anyopaque, argv: []const []const u8, alloc: std.mem.Allocator) anyerror![]u8,
    pub fn run(self: Runner, argv: []const []const u8, alloc: std.mem.Allocator) anyerror![]u8 {
        return self.runFn(self.ctx, argv, alloc);
    }
};
```
- **vs reassignable global (`pub var runner = real;`):** per-test testdata lives in `Runner.ctx`
  ⇒ NO mutable global, no cross-test contamination. The repo has ZERO mutable-global seams.
- **vs `anytype`/`hasDecl` (comptime generics):** `Runner` is a CONCRETE type ⇒ the prod pane body
  constructs `capture.real` and calls `geometry`/`capture` with concrete types (no generic
  propagation; storable in fields; referable as `*const fn`). The contract says "function pointers /
  an interface" — `anytype` is neither.
- **vs bare `*const fn` (no ctx):** stateless ⇒ a fake could only vary output via a mutable global
  or hardcoded `const`. `*anyopaque ctx` carries per-test bytes cleanly.

**Generalizes the repo's TWO existing seams:** `cli.syncPalette(alloc, args, body: *const
fn(...) anyerror!u8)` (lifted from stateless pointer to stateful `{ctx,runFn}`; the pointer type
MUST be `anyerror![]u8` exactly like `body`) and `palette.resolve(alloc, mode, has_tty: bool)`
/`render.determineCols(opts_cols, has_tty)` (inject the I/O dependency as a per-call PARAMETER,
never probe internally — `geometry(runner,…)` mirrors this).

**Zig 0.15.2 concerns (verified against this repo's compiling code):**
- `ctx` is the MUTABLE `*anyopaque`. `*T → *anyopaque`: `@ptrCast(&x)` (dest inferred). `*anyopaque
  → *T`: `@ptrCast(@alignCast(ctx))` — **`@alignCast` MANDATORY** (anyopaque has unknown alignment;
  skipping traps in Debug / UB in ReleaseFast).
- The state backing `ctx` must be a mutable lvalue (`var`), so `&x` is `*T` and coerces to
  `*anyopaque`. A `const` yields `*const T` which does NOT coerce.
- `runFn` uses default `.auto` calling convention; plain `fn` addresses coerce with no
  `callconv(...)`. Its type MUST be `anyerror![]u8` (not a narrow set).

## 3. Thread C — tmux argv (display-message + capture-pane; VERIFIED vs local `tmux 3.6b` man page)

Cross-checked vs `man 1 tmux` (tmux 3.6b installed locally) + PRD §2.1/§5.2 + the architecture
docs. PANE is `%<digits>`. **All exec'd DIRECTLY (no shell) ⇒ a space inside one argv element
survives.**

### 3.1 Geometry — ONE call, parse `"<cols> <rows>"`
```
tmux display-message -p -t <PANE> "#{pane_width} #{pane_height}"
```
argv: `["tmux", "display-message", "-p", "-t", "<PANE>", "#{pane_width} #{pane_height}"]` (6 elems)
stdout: `"80 24\n"`. `-p` ⇒ stdout; `-t` ⇒ target pane; the message is a FORMAT string (expanded
by default — do NOT pass `-l`, which suppresses expansion). Combine both `#{…}` + the literal
space in ONE format string ⇒ ONE subprocess call. Use `display-message` (HYPHEN); `display_message`
is an unknown command. Parse: trim, `splitScalar(' ')`, exactly 2 fields → u16 cols/rows.

### 3.2 capture-pane — visible vs full (man page, VERIFIED)
> "`-S` and `-E` specify the starting and ending line numbers, zero is the first line of the
> visible pane and negative numbers are lines in the history. `-` to `-S` is the start of the
> history and to `-E` the end of the visible pane. The default is to capture only the visible
> contents of the pane."

- **visible (default):** `["tmux", "capture-pane", "-e", "-J", "-p", "-t", "<PANE>"]` (7 elems).
  Omit `-S`/`-E` ⇒ only the on-screen rows.
- **full, capped to N scrollback lines:** add `-S -<N> -E -` ⇒
  `["tmux", "capture-pane", "-e", "-J", "-p", "-t", "<PANE>", "-S", "-<N>", "-E", "-"]` (11 elems).
  `-<N>` token = the string `"-50000"` (format via `std.fmt.allocPrint("-{d}", .{history})`).
  **tmux clamps if actual scrollback < N (so capping never under-captures).**
- **uncapped full (all scrollback):** replace `-<N>` with `-` ⇒ `[…, "-S", "-", "-E", "-"]`.

**Flags:** `-e` re-emits SGR colors/attributes AND OSC 8 hyperlinks; `-J` joins soft-wrapped lines
(changes newline structure — fewer, longer lines); `-p` ⇒ stdout; `-t` ⇒ target. **`-S`/`-E` each
take the NEXT argv token as their value even when it starts with `-`** (so `-S`,`-50000` and
`-S`,`-` parse correctly) — pass as SEPARATE tokens (never `-S-50000`).

**Output structure:** each logical line `\n`-terminated (trailing newline present). SGR state
carries CONTINUOUSLY across lines (no per-line reset) ⇒ feed the WHOLE stream to one fresh VT
(exactly `render.renderGrid`'s per-byte `\n`→`\r\n` loop). capture returns raw bytes; the RENDERER
feeds them. Do NOT split/munge.

### 3.3 Environment
`$TMUX_PANE` = originating pane id (`%<digits>`), set by `run-shell` ⇒ the `--target` default.
`$TMUX` = `<socket_path>,<pid>,<session_idx>`, present in run-shell child env in the standard
single-server case ⇒ a bare child `tmux` connects to the right server. **Don't hard-depend on
`$TMUX`; just invoke `tmux` (env_map=null ⇒ inherited).** `-t %5` is valid from any client context
(pane ids are globally unique per server).

## 4. Scope boundary vs sibling S2 (P2.M1.T1.S2) — DO NOT overlap

- **S1 (THIS item) owns:** `Size`, `Mode{visible,full}`, `Captured`, `Runner` + `real` + `realRun`,
  `geometry(runner,alloc,pane)`, the PURE argv builder `captureCmd(alloc,pane,mode,history)`
  (realized as an owning `Cmd{argv,history_token}` struct — see PRP), `capture(runner,…)` (=
  geometry + capture-pane run → Captured), the `FakeTmux` + unit tests, the main.zig test-block
  import. **`captureCmd` DOES build the `-S -<N> -E -` argv** (pure argv construction from
  mode+history — that's S1's job; PRD §15 names "capture-line-range → `-S/-E` derivation" as a
  unit case — `captureCmd`'s test covers it).
- **S2 owns:** the truncation NOTICE (PRD §13 "cap capture at history-limit with a status notice
  when truncated" — detection + stderr warning when the pane's scrollback exceeds the cap); any
  post-capture parsing beyond "raw stdout → ansi field"; the pane-subcommand-level visible-vs-full
  decision plumbing. **S1 does NOT emit the truncation notice.**

## 5. Codebase facts that shape the implementation

- `render.Size = struct{cols:u16, rows:u16}` (render.zig). `Captured.cols/rows` are u16 (match
  ghostty `size.CellCountInt`). capture.zig defines its OWN `Size` (mirror shape) to stay
  dependency-free (capture FEEDS render; importing it would invert the layering). The pane body
  copies fields into `render.Size` (trivial: `.{ .cols=c.cols, .rows=c.rows }`).
- `palette.zig` defines its OWN `Mode` enum locally ("palette.zig must NOT import cli.zig") —
  capture.zig defining its own `Mode{visible,full}` is the SAME convention (capture stays cli-free;
  the pane body maps `cli.PaneOpts` → `capture.Mode`).
- `render.spawnXdgOpen` (render.zig) is the in-repo `Child` precedent (`Child.init` + behaviors +
  `spawn()` + `wait()` reap, ghostty #5999). `realRun` reuses the shape via `Child.run`.
- The Debug-mode `R_X86_64_PC64` link bug (PRD §15) ⇒ `zig build test` REQUIRES `-Doptimize=ReleaseFast`.
  capture.zig does NOT touch ghostty-vt `Terminal.init` ⇒ its tests are NOT subject to render.zig's
  "one renderGrid test scope" GOTCHA ⇒ capture tests CAN be separate `test` fns.
- `main.zig`'s top-level `test { … }` block must `@import("capture.zig")` so capture's tests are
  reachable (mirrors the palette/render/golden_test imports). capture.zig is auto-compiled on the
  prod path (under src/), so this is the ONLY wiring needed — no build.zig change.
- The stdout writer bridge (`var fw = out_file.writer(&buf); … &fw.interface`) is NOT needed in
  capture.zig — capture returns bytes; the PANE BODY (S2/T2) does renderGrid + write. S1 produces
  `Captured` only.

## 6. Confidence

- Thread A: **HIGH** — read the bundled stdlib source + compiled a verifying program (all 5 tests passed).
- Thread B: **HIGH** — grounded in the repo's two compiling seams + the stdlib vtable idiom.
- Thread C: **HIGH** — verified against the LOCAL `tmux 3.6b` man page (`-S`/`-E`/`-`/default
  semantics quoted verbatim) + the project PRD/architecture docs. The argv arrays are safe to
  implement now.
