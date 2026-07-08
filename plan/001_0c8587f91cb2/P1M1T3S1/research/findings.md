# Research Findings — P1.M1.T3.S1 (main.zig: subcommand dispatch + --version/--help)

> All facts below were **verified empirically** on 2026-07-08 against the real Zig 0.15.2
> toolchain + the cached parg dep, by building and running the exact dispatch code in an
> isolated throwaway project (`/tmp/t2h-t3s1-verify`) reusing the repo's real `build.zig`
> + `build.zig.zon`. Every code shape below was observed to compile and behave as stated.

## 0. Starting point (post T1.S1 + T1.S2; T2.S1 in flight in parallel)

- `build.zig` (T1.S2, COMPLETE on disk) already wires `parg` (eager) + `build_options`
  (version baked in) + lazy `ghostty-vt` into the `src/main.zig` root module. **T3.S1 does
  NOT touch build.zig.** Verified by reading the on-disk `build.zig`.
- `src/main.zig` is currently the **T1.S2 build-graph stub** (prints `--version`, imports
  all three modules, has a smoke test). T3.S1 **REPLACES** it with real dispatch.
- T2.S1 (parallel) adds `src/ghostty_format.zig`. It does NOT touch `src/main.zig`. So when
  T3.S1 rewrites main.zig, it must NOT import `ghostty_format.zig`/`ghostty-vt` — that is
  render.zig's job (P1.M3). **Confirmed: a main.zig that does not `@import("ghostty-vt")`
  keeps the ghostty dependency LAZY** (build was ~11 s, i.e. ghostty never compiled). This
  is the desired, fast state for this subtask.

## 1. parg API (verified from cached source — exact, copy-able)

Cached parg: `~/.cache/zig/p/parg-0.0.0-dOPWZNhYAABEHE6EGXmwIucnu9vj-emodT9vmHeYynAP/src/parser.zig` (450 lines).

```zig
pub const Token = union(enum) {
    flag: Flag,
    arg: []const u8,            // positional
    unexpected_value: []const u8,
};

pub const Flag = struct {
    name: []const u8,
    kind: FlagType,             // .short | .long
    pub fn is(self, other: []const u8) bool
    pub fn isLong(self, other: []const u8) bool   // is() AND kind == .long
    pub fn isShort(self, other: u8... )  // isShort takes a []const u8 in this version; use isLong for long flags
};

pub const FlagType = enum { short, long,
    pub fn prefix(self) []const u8   // "-" for short, "--" for long
};

pub fn parseSlice(slice: []const []const u8, options: Options) Parser(SliceIter)
pub fn parseProcess(allocator, options) !Parser(ArgIterator)
pub fn parse(source: anytype, options: Options) Parser(@TypeOf(source))   // source needs .next()

// Parser(T):
//   pub fn next(self) ?Token
//   pub fn nextValue(self) ?[]const u8   // value after a flag; in .default state it just pulls the next raw arg
//   pub fn skipFlagParsing(self) void
//   pub fn deinit(self) void

pub const Options = struct { auto_double_dash: bool = true };
```

**Key behaviors (verified by reading the source + running):**
- `parseSlice(args, .{})` wraps the slice in a `SliceIter`. **`args` of type `[][:0]u8`
  (the `argsAlloc` return type) coerces to the `[]const []const u8` parameter — VERIFIED,
  compiles.** (Element coercion `[:0]u8 → []const u8` inside a slice is accepted by Zig 0.15.2.)
- `_ = parser.nextValue()` at the start **skips args[0] (the program name)**: in `.default`
  state `nextValue()` calls `pull()` = `source.next()`, which returns and discards the first
  arg. State stays `.default`. This is the documented term2html pattern (external_deps.md §4).
- `next()` then classifies args[1] onward: `--version`/`--help` → `.flag{.long}`, a bare
  word → `.arg`, `--name=val` → `.flag` then a following `.unexpected_value`.

**NO native subcommand support** in parg (confirmed — only flag/arg/unexpected_value tokens).
Subcommand dispatch is hand-rolled: peek the first token after the program name.

## 2. Zig 0.15.2 std APIs used (verified from std source + successful compile)

```zig
// DebugAllocator (std/heap/debug_allocator.zig):
//   pub fn DebugAllocator(comptime config: Config) type
//   config: DebugAllocatorConfig = .{}  (sensible defaults; thread_safe etc.)
var gpa = std.heap.DebugAllocator(.{}){};   // type-instance via struct literal (default fields)
defer _ = gpa.deinit();                      // deinit() returns std.heap.Check (.ok | .leak)
const allocator = gpa.allocator();           // needs *Self → pass &gpa implicitly via method call

// process args (std/process.zig):
const args = try std.process.argsAlloc(allocator);   // returns ![][:0]u8  (caller MUST argsFree)
defer std.process.argsFree(allocator, args);

// stdout/stderr (std/fs/File.zig) — getStdOut() is GONE in 0.15.2:
const stdout = std.fs.File.stdout();   // *File
const stderr = std.fs.File.stderr();
try stdout.writeAll(bytes);
var buf: [N]u8 = undefined;
const s = try std.fmt.bufPrint(&buf, "tmux-2html {s}\n", .{version});
```

- `main()` may return `!u8`; the returned u8 becomes the process exit code. A propagated
  error aborts with a stack trace + non-zero exit, so we catch known errors and map to
  explicit codes (0/1/2). **VERIFIED: `pub fn main() !u8` compiles and the returned value
  is the real exit code** (e.g. `--version` → exit 0, `bogus` → exit 1).

## 3. Sibling import of cli.zig needs NO build.zig change

`const cli = @import("cli.zig");` is a **relative sibling import** (like
`@import("ghostty_format.zig")`). The build system analyzes it automatically once `src/main.zig`
is the root. **VERIFIED: adding `src/cli.zig` as a sibling and importing it compiled with the
existing `build.zig` unchanged.** (Contrast: registered modules like `parg`/`build_options`/
`ghostty-vt` are imported WITHOUT the `.zig` extension; sibling files WITH it.)

## 4. Verified behavior matrix (exit codes) — run against the built binary

| Invocation                  | stdout                     | stderr                          | exit |
|-----------------------------|----------------------------|---------------------------------|------|
| (no args)                   | —                          | usage text                      | 1    |
| `--version`                 | `tmux-2html 0.1.0`         | —                               | 0    |
| `--help`                    | usage/help text            | —                               | 0    |
| `render`                    | —                          | `... not yet implemented`       | 1    |
| `pane` / `region` / `sync-palette` | —                  | `... not yet implemented`       | 1    |
| `bogus`                     | —                          | `unknown subcommand 'bogus'` + usage | 1 |
| `--unknown`                 | —                          | `unknown option '--unknown'` + usage | 1 |
| `render --cols 80`          | —                          | `... not yet implemented`       | 1 (sub_args handed off OK) |

Notes:
- Exit codes match PRD §5: 0 success, 1 usage/runtime, 2 capture/target (2 is unused at this
  subtask — it arrives with capture.zig in P2.M1).
- `-h` / `-V` (short forms) are treated as unknown options (exit 1). PRD §5.5 specifies only
  `--version` / `--help` (long forms), so this is contract-correct. Short aliases are NOT
  required; do not add them speculatively.
- "no subcommand" exits 1 (usage error to stderr). This is the conventional choice (vs. 0 for
  an explicit `--help`). The item allows "exit 0/1"; 1 is defensible and matches most CLIs.

## 5. The hand-off interface to cli.zig (sets up T3.S2)

- main.zig passes `(allocator: std.mem.Allocator, sub_args: []const []const u8)` to each
  `cli.<sub>` function, where `sub_args = args[2..]` (the flags AFTER the subcommand).
  The subcommand is ALWAYS the first positional = args[1], so args[2..] is exactly that
  subcommand's flag set. **VERIFIED: `args[2..]` (type `[][:0]u8`) coerces to
  `[]const []const u8` and reaches the stub.**
- T3.S2 will make each `cli.<sub>` re-parse `sub_args` via `parg.parseSlice(sub_args, .{})`
  and handle that subcommand's flags (incl. per-subcommand `--help`, PRD §5 "`--help` on
  every subcommand").
- Each cli function returns `!u8` (the exit code). Stubs return `error.NotImplemented`,
  which main maps to exit 1.

## 6. Gotchas baked into the verified code

1. `std.io.getStdOut()` is GONE in 0.15.2 — use `std.fs.File.stdout()` (inherited from T1.S2).
2. `--release=fast` is MANDATORY for build/test (Debug linker `R_X86_64_PC64` bug, inherited
   from T1.S2 / findings §4). Bare `zig build` fails to link.
3. `nextValue()` to skip the program name only works because parg's `.default`-state
   `nextValue()` calls `pull()`. Do NOT call `next()` to skip the program name (that would
   mis-classify args[0] if it looked like a flag).
4. `main()` returning `!u8` is the exit-code channel — do not switch to `!void` or the exit
   codes won't propagate.
5. Do NOT import `ghostty-vt` / `ghostty_format.zig` from main.zig — it is render.zig's job
   (P1.M3). Importing it here would un-lazily compile ghostty (~minutes) for no reason.
