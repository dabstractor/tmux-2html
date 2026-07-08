# Research findings — P1.M2.T1.S2 (palette cache read/write)

All facts read **directly from the cached source**:
- Zig 0.15.2 std: `/home/dustin/.local/opt/zig-x86_64-linux-0.15.2/lib/std`
- ghostty 1.3.1: `~/.cache/zig/p/ghostty-1.3.1-5UdBCwYm-gQeBa4bu1-sMooCQS4KVriv5wWSIJ_sI-Cb/src`

This task consumes the `Colors` struct + `defaultColors()` produced by P1.M2.T1.S1
(`src/palette.zig`, contract in `P1M2T1S1/PRP.md`) and adds the cache I/O layer to the
SAME file: `cachePath`, `writeCache`, `loadCache`, + pure `serialize`/`parse` helpers.

## 0. The consumed contract (P1.M2.T1.S1 — treat as fixed)

`src/palette.zig` will already export (PRP P1M2T1S1, verbatim):
```zig
const ghostty_vt = @import("ghostty-vt");
const color = ghostty_vt.color;
const osc = ghostty_vt.osc;

pub const Colors = struct {
    palette: [256]color.RGB,
    foreground: ?color.RGB,
    background: ?color.RGB,
    palette_received_count: u16,
};
pub fn defaultColors() Colors;            // palette=color.default; fg=default[7]; bg={41,44,51}; count=256
pub fn applyOscCommand(colors, cmd, allocator) void;
pub fn queryColors(allocator) !Colors;    // interactive-only (opens /dev/tty)
```
Tests are reachable because `src/main.zig` has the top-level `test { _ = @import("palette.zig"); }`
block (added in T1.S1). **This task ADDS to palette.zig; it must not change what T1.S1
already defined.** New functions + new tests go in the same file.

`color.RGB` = `packed struct(u24){ r: u8 = 0, g: u8 = 0, b: u8 = 0 }` (color.zig:400-403).
Fields are PUBLIC: `rgb.r`, `rgb.g`, `rgb.b`. `pub fn eql(self, other) bool` (color.zig:419).
`color.default: [256]RGB` (color.zig:8).

## 1. `std.posix.getenv` WORKS WITHOUT libc (link_libc=false) on x86_64-linux

`build.zig` sets `.link_libc = false`. `std.posix.getenv` (posix.zig:2029) has a libc
branch and a non-libc branch:
```
if (builtin.link_libc) { /* scans std.c.environ */ }
...
if (std.start.simplified_logic) return null;   // posix.zig:~2063
for (std.os.environ) |ptr| { ... }             // posix.zig:~2065
```
**`std.start.simplified_logic` is FALSE for x86_64-linux** (start.zig:17-25): it is `true`
only for the non-LLVM stage2 backends (`stage2_aarch64/arm/powerpc/sparc64/spirv/x86` — note
`stage2_x86` is 32-bit). The native x86_64-linux build uses the LLVM backend → `else => false`.
So the full Zig start code runs, populates `std.os.environ` from the kernel-supplied envp, and
`getenv("XDG_CACHE_HOME")` / `getenv("HOME")` return `?[:0]const u8`. **No build change needed.**

Signature: `pub fn getenv(key: []const u8) ?[:0]const u8` (posix.zig:2029).

## 2. XDG cache path resolution

Resolution (XDG spec — see external.md §1):
1. `XDG_CACHE_HOME` set AND non-empty AND absolute → use it.
2. Else → `$HOME/.cache`.
3. Else → error (degenerate; `$HOME` unset).

`cachePath(allocator) ![]u8` builds `$base/tmux-2html/palette` and returns owned memory:
```zig
const xdg = std.posix.getenv("XDG_CACHE_HOME");
const base = if (xdg) |x| (if (x.len != 0 and std.fs.path.isAbsolute(x)) x else fallback) else fallback;
// fallback = $HOME/.cache  (getenv("HOME") orelse return error.NoHomeDirectory)
return std.fmt.allocPrint(allocator, "{s}/tmux-2html/palette", .{base});
```
Caller frees the returned slice. (`std.fs.path.isAbsolute` — fs/path.zig.)

## 3. Filesystem API (all verified, Zig 0.15.2)

- `std.fs.cwd() Dir` (fs.zig:220) — the process cwd; `Dir` methods accept ABSOLUTE sub-paths
  on Linux (dirfd=AT_FDCWD + absolute path resolves absolutely).
- `Dir.makePath(sub_path)` (Dir.zig:1175) → recursively `makeDir` bottom-up via
  `componentIterator`. **Accepts absolute paths** (each component's full path is mkdir'd on
  `self`=cwd). Returns `MakeError || StatFileError`; `error.PathAlreadyExists` is NOT in the
  error set (it is handled internally — a pre-existing dir is fine). So `makePath` is idempotent.
- `std.fs.openDirAbsolute(path, flags: Dir.OpenOptions) !Dir` (fs.zig:243) = `cwd().openDir(path, flags)`.
  Use `.{} ` (defaults). `defer dir.close();`.
- `Dir.createFile(sub_path, flags: File.CreateFlags) !File` (Dir.zig:983). `CreateFlags.truncate`
  defaults to `true` (File.zig:148) → opening with `.{}` truncates. `defer f.close();`.
- `Dir.openFile(sub_path, flags: File.OpenFlags) !File` (Dir.zig:818). `OpenFlags.mode` defaults to
  `.read_only` (File.zig:94) → `.{}` opens read-only.
- `Dir.rename(old_sub, new_sub)` (Dir.zig:1772) — rename WITHIN the same Dir. Atomic if same
  filesystem. (Same-dir temp file guarantees this — see external.md §2.)
- `File.writeAll(bytes)` (File.zig:975).
- `File.readToEndAlloc(allocator, max_bytes) ![]u8` (File.zig:809) — reads whole file.
- `File.sync() !void` — best-effort durability (call before rename; tolerate errors).
- `std.fs.path.dirname(path) ?[]const u8` (path.zig:845, NULLABLE), `basename(path) []const u8` (979).

## 4. `std.ArrayList(u8)` in 0.15.2 is the Unmanaged-style (allocator-per-method)

**CRITICAL API CHANGE vs older Zig.** In 0.15.2 (std.zig:48 `pub fn ArrayList(T)`):
`std.ArrayList(u8)` does NOT store the allocator; you pass it to each method.
`std.ArrayListUnmanaged` is a DEPRECATED alias for `ArrayList` (std.zig:57-58). The
allocator-STORING variant (`Managed`) is also deprecated (array_list.zig:14-16).

Correct usage (array_list.zig: deinit@654, appendSlice@974, toOwnedSlice@685):
```zig
var buf: std.ArrayList(u8) = .{};          // empty struct literal — NO init(allocator)
errdefer buf.deinit(allocator);
try buf.appendSlice(allocator, "literal");  // (self, gpa, items)
const text = try buf.toOwnedSlice(allocator); // (self, gpa)
```
`buf.writer(allocator)` exists (array_list.zig:1071) but to avoid the writer-deprecation
question, build each line with `std.fmt.bufPrint(&line_buf, fmt, args)` (returns a slice into
the stack buffer) then `buf.appendSlice(allocator, slice)`. Longest line ~16 bytes
(`255 255 255 255\n`); header ~50 bytes → a `[64]u8` stack line buffer is plenty.

## 5. String tokenization (0.15.2)

- `std.mem.tokenizeAny(T, buf, delims) TokenIterator(.any)` (mem.zig:2275) — skips empty tokens.
  Use for space-separated fields: `var f = std.mem.tokenizeAny(u8, line, " \t");`
- `std.mem.tokenizeScalar` / `splitScalar` / `splitAny` / `splitSequence` also exist (mem.zig:2319/2514/2494/2473).
- `std.mem.splitScalar(u8, text, '\n')` (mem.zig:2514) — iterate LINES (split keeps empty
  trailing tokens; skip empty lines).
- `std.fmt.parseInt(T, s, base) !T` — parse `"204"` etc.

NOTE: the old `std.mem.tokenize`/`split` (no suffix) are GONE in 0.15.2 — always use the
suffixed forms.

## 6. ISO 8601 from wall-clock time (header line, cosmetic but correct)

`std.time.timestamp() i64` (time.zig:16) = Unix epoch SECONDS (CLOCK_REALTIME wall clock).
`std.time.Instant` is MONOTONIC/BOOTTIME (time.zig:145 `.linux => CLOCK.BOOTTIME`) — do NOT use
it for a calendar timestamp. Use the `std.time.epoch` module to decompose `timestamp()`:
```zig
fn formatIso8601(buf: []u8, ts: i64) []const u8 {
    if (ts < 0) return "?";                       // pre-1970 guard (never in practice)
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(ts) };
    const ed = es.getEpochDay();                  // EpochDay{ day: u47 }
    const yd = ed.calculateYearDay();             // YearAndDay{ year: u16, day: u9 }
    const md = yd.calculateMonthDay();            // MonthAndDay{ month: Month, day_index: u5 }
    const ds = es.getDaySeconds();                // DaySeconds{ secs: u17 }
    return std.fmt.bufPrint(buf,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
            yd.year,
            md.month.numeric(),   // Month enum -> u4 (1..12)
            md.day_index + 1,     // 0-based -> 1-based (epoch.zig:130 "0 to 30")
            ds.getHoursIntoDay(),
            ds.getMinutesIntoHour(),
            ds.getSecondsIntoMinute(),
        }) catch "?";
}
```
Verified field/method names (epoch.zig): `EpochSeconds{secs:u64}`@169, `getEpochDay`@174,
`getDaySeconds`@180; `EpochDay.calculateYearDay`@136; `MonthAndDay{month,day_index}`@128
(day_index "0 to 30"); `DaySeconds.getHoursIntoDay/getMinutesIntoHour/getSecondsIntoMinute`@155-163.
`Month.numeric() u4`@83.

The header is informational: `loadCache` skips lines starting with `#`, so the timestamp value
does NOT affect the round-trip. Sanity-check the output against `date -u` once.

## 7. Testability: `std.testing.tmpDir` for the disk round-trip

`std.testing.tmpDir(opts: std.fs.Dir.OpenOptions) TmpDir` (testing.zig:626) creates
`.zig-cache/tmp/<random>/` and returns `TmpDir{ .dir, .parent_dir, .sub_path }`. `tmp.dir` is an
open `Dir`; call `tmp.cleanup()` (testing.zig:618) in a defer. This lets the disk round-trip test
write/read `palette` inside a throwaway dir without touching the real `$XDG_CACHE_HOME`.

So the design splits I/O from logic:
- `pub fn writeCache(allocator, colors)` / `pub fn loadCache(allocator)` resolve `cachePath`,
  open the PARENT dir (openDirAbsolute), and delegate to dir-scoped helpers.
- `fn writeCacheDir(dir, filename, allocator, colors)` / `fn loadCacheDir(dir, filename, allocator)`
  do the actual atomic write / read inside a given Dir → tested with `std.testing.tmpDir`.
- `fn serialize(allocator, colors) ![]u8` and `fn parse(text, allocator) !Colors` are PURE →
  unit-tested with NO filesystem at all (the primary round-trip + tolerance tests).

## 8. Signatures (deviation from the literal contract — documented)

The item contract writes `writeCache(Colors) !void`, `loadCache(alloc) !Colors`,
`cachePath(alloc) ![]u8`. Zig requires an explicit allocator for path memory and the formatted
buffer; this codebase passes allocators explicitly everywhere (`applyOscCommand(..., allocator)`
in T1.S1, `cli.*(allocator, …)`, tests use `std.testing.allocator`). Therefore the public API is:
```zig
pub fn cachePath(allocator: std.mem.Allocator) ![]u8;
pub fn writeCache(allocator: std.mem.Allocator, colors: Colors) !void;
pub fn loadCache(allocator: std.mem.Allocator) !Colors;
```
Same intent; just allocator-explicit (consistent with the sibling functions in palette.zig).

## 9. Round-trip & tolerance semantics (precise)

- `writeCache` ALWAYS emits all 258 lines: header + `fg` + `bg` + `0`…`255` (fg/bg emitted only
  when non-null; defaultColors/queryColors are always non-null → full file). It writes
  `colors.palette[i]` for i=0..255 verbatim.
- `loadCache` SEEDS the result from `defaultColors()` (so a truncated/partial cache still yields
  a usable palette → "tolerate missing entries"), then overwrites every parsed entry.
  `palette_received_count` = number of palette index lines actually parsed (0..256). For a
  well-formed file written by writeCache that is 256 → round-trips exactly.
- "Round-trip exact" holds for the normal case (a fully-populated `Colors` with non-null fg/bg):
  `writeCache(c)` then `loadCache()` ⇒ `palette` identical, `foreground` identical, `background`
  identical, `palette_received_count == 256`. (For a Colors with `palette_received_count < 256`,
  writeCache still writes all 256 entries — some pre-filled with defaults — so loadCache reports
  256. The cache represents "the palette to render", always complete.)
