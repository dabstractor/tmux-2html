# Research Findings — P1.M1.T3.S2 (cli.zig: parg flag/option parser for all subcommands)

> All facts below were **verified empirically** on 2026-07-08 against the real
> Zig 0.15.2 toolchain + the cached parg dep, by building and running the exact
> `src/cli.zig` in an isolated throwaway project (`/tmp/t2h-t3s2-verify`) that
> reuses the repo's real `build.zig` + `build.zig.zon` + the T3.S1 `src/main.zig`.
> Every code shape and behavior below was observed to compile and behave as stated.

## 0. Starting point (the contract this task consumes — from P1.M1.T3.S1, DONE on disk)

- `src/main.zig` (T3.S1) is the **real dispatcher**: `main() !u8` → `argsAlloc` →
  `parg.parseSlice(args, .{})` → skip program name via `nextValue()` → switch on the
  first token → `dispatch(allocator, name, args[2..])`. It catches `error.NotImplemented`
  → prints `tmux-2html: this subcommand is not yet implemented` → exit 1. Other errors
  propagate. **VERIFIED unchanged**: `diff -q` shows the T3.S1 `main.zig` is byte-identical
  before/after T3.S2 — this task touches ONLY `src/cli.zig`.
- `src/cli.zig` (T3.S1) is the **4 stub file** (`render`/`pane`/`region`/`syncPalette`,
  each `(allocator, args) !u8` returning `error.NotImplemented`). T3.S2 **REPLACES** it
  with the real parser. The `pub fn` names + signatures are a FIXED CONTRACT — unchanged.
- Hand-off: `main.zig` calls `cli.<sub>(allocator, sub_args)` where `sub_args = args[2..]`
  is `[]const []const u8` (the flags AFTER the subcommand). T3.S2 re-parses `sub_args` per
  subcommand via `parg.parseSlice(sub_args, .{})`.

## 1. parg API used (verified from cached source + empirical)

Cached parg: `~/.cache/zig/p/parg-0.0.0-.../src/parser.zig`. Read in full. The exact surface:

```zig
pub const Token = union(enum) { flag: Flag, arg: []const u8, unexpected_value: []const u8 };
pub const Flag = struct {
    name: []const u8, kind: FlagType,
    pub fn is(self, other: []const u8) bool
    pub fn isLong(self, other: []const u8) bool   // is() AND kind == .long
    pub fn isShort(self, other: []const u8) bool
};
pub const FlagType = enum { short, long, pub fn prefix(self) []const u8 };
pub fn parseSlice(slice: []const []const u8, options: Options) Parser(SliceIter)  // <-- per-subcommand
// Parser(T):  next(self) ?Token | nextValue(self) ?[]const u8 | skipFlagParsing(self) | deinit(self)
pub const Options = struct { auto_double_dash: bool = true };
```

### CRITICAL value-consumption behavior (verified by running, see §gotcha G7)

`parser.nextValue()` is **dumb** about flag-vs-value: in the `.default` state it just calls
`pull()` = `source.next()` and returns the next raw token **regardless of whether it starts
with `-`**. So `--cols --rows 24` consumes `--rows` as the value of `--cols`. This affects
EVERY value-option (e.g. `--font --output` would silently set `font="--output"`).

Verified empirically: with a naïve `requireValue`, `parseRender(&.{ "--cols", "--rows", "24" })`
returned `error.InvalidNumber` (because `"--rows"` failed `parseInt`), NOT `MissingValue`.

**The fix (in the verified cli.zig):** `requireValue` treats a consumed value that looks like
another flag (`v.len > 1 and v[0] == '-'`) as `error.MissingValue`. A lone `"-"` (stdin) is
allowed. This is safe for ALL our value-options (cols/rows/history = unsigned ints; font is a
CSS family that never starts with `-`; output/target/from-path never start with `-`; selection
is comma ints) and gives the user a correct "missing value" message instead of a misleading
"invalid number". After this fix `--cols --rows` → `MissingValue`. **VERIFIED.**

### The `=value` form (verified)

`--cols=80` → `next()` returns `.flag{cols}` and sets internal state to `.value`; the FOLLOWING
`nextValue()` returns `"80"`. So calling `nextValue()` after matching a value-flag handles BOTH
`--cols 80` and `--cols=80`. **VERIFIED** by the `parseRender: --cols=value form` test.

### `.unexpected_value` and stray positionals (verified)

- `.unexpected_value` arises when a flag is given `=value` but we DON'T consume it via
  `nextValue` (i.e. a boolean flag written as `--open=yes`, or a value-flag where we call
  `next()` instead of `nextValue()`). Since value-flags always call `nextValue()`, the only way
  `.unexpected_value` reaches our loop is `--bool=val` → mapped to `error.UnknownFlag`.
  **VERIFIED** by the `--open=yes` case in `parseRender: unknown flag and positional`.
- `.arg` = a bare positional. render/pane/region/sync-palette take NO positionals (all flags),
  so any `.arg` → `error.UnknownFlag`. **VERIFIED** by the `extra.txt` case.

## 2. Design decisions (each maps 1:1 to a PRD §5 field)

| Decision | Rationale | PRD anchor |
|---|---|---|
| **Option struct fields mirror the item contract EXACTLY.** `RenderOpts{cols,rows,font,palette_mode,output,open,selection}`, `PaneOpts{target,visible,full,history,font,output,open}`, `RegionOpts{target,font,output,open}`, `SyncPaletteOpts{from,force}`. No extra fields (so `--help` is NOT a struct field — see below). | The structs ARE the consumer-facing API (render.zig/capture.zig import them). Matching the contract exactly keeps downstream milestones aligned. | §5.1–5.4 |
| `cols/rows: ?u16` (nullable; null = derive later), `history: u32 = 50000` (PRD default). | PRD: cols "REQUIRED if no tty" is a RUNTIME check in render.zig, not parse-time; parser only captures. history default 50000 is a PRD literal. | §5.1/§5.2 |
| `font: []const u8 = "monospace"`, `output: ?[]const u8 = null`, `target: ?[]const u8 = null` (null → resolve `$TMUX_PANE` in capture.zig), `open/visible/full/force: bool = false`. | Defaults from PRD; env-var resolution is the body's job (capture.zig), not the parser's. | §5.1–5.4 |
| `palette_mode: PaletteMode = .cached` where `PaletteMode = enum{default,cached,live}` + `fromStr`. | PRD §5.1 "default \| cached \| live (default: cached→live→default)". The `.cached` default means "try cached→live→default"; the resolve precedence lives in palette.zig (P1.M2.T1.S3). Parser only captures the mode. | §5.1 |
| `selection: ?SelectionCoords` where `SelectionCoords{x1,y1,x2,y2:u32, rect:bool}` parsed from `X1,Y1,X2,Y2[,rect]` (4–5 comma ints; rect=1→block). | PRD §5.1. Conversion to ghostty `point.Pin`/`Selection` is render.zig (P1.M4.T1.S1); cli.zig stores plain ints and NEVER imports ghostty. | §5.1 |
| `from: PaletteSource = .tty` where `PaletteSource = union(enum){ tty, file: []const u8 }`. `--from tty` → `.tty`; `--from file PATH` → consumes a SECOND value as the path; anything else → `BadPaletteSource`. | PRD §5.4 "tty (default) \| file PATH" → value is a discriminator "tty"/"file"; "file" is followed by the path token. **Two-token consumption is intentional and documented.** | §5.4 |
| `--help` handled by a `hasHelpFlag(args)` PRE-SCAN in each dispatch fn (returns 0 + prints help), NOT a struct field. | Keeps the structs matching the contract; makes `--help` ALWAYS win (even with conflicting flags like `pane --visible --full --help`). PRD §5 "--help on every subcommand". Long form only (PRD §5.5). | §5/§5.5 |
| Mutual exclusivity (`pane --visible --full`) checked in `parsePane` AFTER the loop → `error.MutualExclusivity`. | The only cross-flag rule called out in the item; lives at parse level so it's unit-testable. | §5.2 |
| Parse fns are PURE (`ParseError!Opts`, no I/O) and `pub` so render.zig/capture.zig can call `cli.parseRender(args)`; dispatch fns own the exit code. | "consumers never touch parg directly" — the `pub` parse fns + `pub` structs are the consumer surface. Pure = unit-testable. | contract §3/§4 |

## 3. Error model (verified)

`pub const ParseError = error{ MissingValue, UnknownFlag, InvalidNumber, BadPaletteMode, BadSelection, BadPaletteSource, MutualExclusivity }`.

Dispatch fns: `parse*(args) catch |err| { reportError(sub, err); return 1; }`. `reportError` maps
each variant → a subcommand-scoped message (e.g. `tmux-2html pane: --visible and --full are
mutually exclusive`). Parse errors NEVER reach main.zig's `NotImplemented` handler — they are
caught inside cli.zig and return 1 directly. Successful parse → body → `error.NotImplemented`
(main maps → exit 1, "not yet implemented"). **VERIFIED** by the behavior matrix in §5.

## 4. Zig 0.15.2 std APIs used (verified from std source + compile)

```zig
std.mem.eql(u8, a, b)                                  // string compare
std.mem.splitScalar(u8, s, ',')  -> SplitIterator      // .next() ?[]const u8  (selection parsing)
std.fmt.parseInt(u16|u32, s, 10) catch -> InvalidNumber // integer parse
std.fmt.bufPrint(&buf, "tmux-2html {s}: {s}\n", .{})   // formatted -> []const u8
std.fs.File.stdout() / .stderr() -> File               // writeAll (getStdOut is GONE; inherited T3.S1)
std.testing.expectEqual / expectError / expectEqualStrings  // unit tests
```

- `--release=fast` MANDATORY (Debug `R_X86_64_PC64` linker bug, inherited T3.S1/T1.S2).
- `pub fn main() !u8` (T3.S1) — exit code channel; UNCHANGED by T3.S2.
- cli.zig does NOT import `ghostty-vt` / `ghostty_format.zig` → ghostty stays LAZY (verified:
  cached build 0.15 s; ghostty never compiled for the cli-only path).

## 5. Verified behavior matrix (run against the built binary in /tmp/t2h-t3s2-verify)

| Invocation | stdout | stderr | exit |
|---|---|---|---|
| `render --help` | render help text | — | 0 |
| `pane --help` / `region --help` / `sync-palette --help` | (sub) help text | — | 0 |
| `render --cols` (missing value) | — | `tmux-2html render: missing value for option` | 1 |
| `render --cols --rows 24` (flag-like value) | — | `... missing value for option` | 1 |
| `render --palette neon` | — | `... --palette must be default\|cached\|live` | 1 |
| `render --selection 1,2,3` | — | `... --selection must be X1,Y1,X2,Y2[,rect]` | 1 |
| `render --bogus` / `render extra.txt` / `render --open=yes` | — | `... unknown or unexpected argument` | 1 |
| `pane --visible --full` | — | `tmux-2html pane: --visible and --full are mutually exclusive` | 1 |
| `sync-palette --from ftp` | — | `... --from must be 'tty' or 'file PATH'` | 1 |
| `render --cols 80 --font Fira` (parses OK) | — | `tmux-2html: this subcommand is not yet implemented` | 1 |
| `sync-palette --from file /tmp/x` (parses OK) | — | `... not yet implemented` | 1 |

Notes:
- Successful parse → body not implemented → `error.NotImplemented` → main.zig prints "not yet
  implemented" exit 1. This is CORRECT for T3.S2: parsing works end-to-end; bodies land in
  P1.M2 (sync-palette), P1.M3 (render), P2.M1 (pane), P3 (region).
- Exit code 2 (capture/target) is still unused — arrives with capture.zig (P2.M1).

## 6. Unit-test coverage (21 tests, all PASS, verified `21/21`)

- parseRender: all options / defaults / `--cols=value` form / missing value (incl. flag-like) /
  invalid number / bad palette mode / bad selection / selection-without-rect (linewise) /
  unknown flag + positional + `--bool=val`.
- parsePane: full set / visible-alone / **mutual exclusivity (both orders)** / history default.
- parseRegion: options / rejects pane-only flags (`--full`).
- parseSyncPalette: tty default + force / explicit tty / `--from file PATH` / bad source +
  missing value.
- hasHelpFlag: detects `--help`, ignores `--help=1`.

## 7. Gotchas baked into the verified code

- **G1** parg's `nextValue()` consumes the next raw token even if it looks like a flag →
  `requireValue` must reject flag-like values as `MissingValue` (see §1).
- **G2** `--name=value` is handled by calling `nextValue()` after the flag (NOT `next()`); calling
  `next()` instead yields `.unexpected_value`.
- **G3** `--release=fast` is MANDATORY on build/test (Debug linker bug).
- **G4** `std.io.getStdOut()` is GONE → `std.fs.File.stdout()` (inherited T3.S1).
- **G5** cli.zig must NOT import ghostty-vt/ghostty_format.zig (keeps ghostty lazy; ghostty is
  render.zig's concern).
- **G6** cli.zig is a relative sibling import `@import("cli.zig")` (extension required); parg is
  a registered module `@import("parg")` (no extension). Both already work via T3.S1's main.zig.
- **G7** `PaneOpts{}` cannot be used inline as a function arg in 0.15.2 (`expected ',' after
  argument`); bind to a `const` first inside tests.
- **G8** `--from file PATH` consumes TWO tokens — documented, intentional (PRD §5.4 "file PATH").
