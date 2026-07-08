# PRP — P1.M2.T1.S2: Palette cache read/write (XDG path, plain-text format)

## Goal

**Feature Goal**: Add the cache I/O layer to `src/palette.zig` — the persistence half of
the palette subsystem (PRD §6). Implement a plain-text, debuggable cache format at
`${XDG_CACHE_HOME:-$HOME/.cache}/tmux-2html/palette`, with `cachePath` (XDG resolution),
`writeCache` (atomic temp+rename write), and `loadCache` (parse + tolerate missing entries),
all round-tripping a `Colors` struct **exactly**. Split disk I/O from parse/serialize logic so
the round-trip and tolerance are unit-tested with **no filesystem** (pure functions) plus one
disk round-trip via `std.testing.tmpDir`.

**Deliverable** (at `/home/dustin/projects/tmux-2html/`):
- **MODIFY `src/palette.zig`** — ADD to the existing file (created in P1.M2.T1.S1): the three
  public cache functions (`cachePath`, `writeCache`, `loadCache`), two pure helpers
  (`serialize`, `parse`), two dir-scoped helpers (`writeCacheDir`, `loadCacheDir`), an ISO 8601
  formatter, and ~6 new unit tests. Do NOT alter anything S1 already defined (`Colors`,
  `defaultColors`, `applyOscCommand`, `queryColors`, its tests).
- **CREATE `docs/CONFIGURATION.md`** — a `## Palette` (§Palette) section documenting the cache
  file location + plain-text format. Create the file if absent (it does not exist today).
- `src/main.zig`, `build.zig`, `build.zig.zon`, `src/cli.zig` **UNCHANGED** — the top-level
  `test { _ = @import("palette.zig"); }` block already exists (added in S1), so new tests in
  palette.zig are automatically reachable from `zig build test`.

**Success Definition** (all VERIFIED against Zig 0.15.2 + cached ghostty 1.3.1):
- `zig build test --release=fast` → exit 0, all NEW cache tests pass **plus** S1's tests still
  pass, no leaks under `std.testing.allocator`.
- `zig build --release=fast` → exit 0 (ghostty stays lazy on the exe path; no new imports).
- **Round-trip exactness**: for a fully-populated `Colors` (non-null fg/bg), `writeCache(c)` then
  `loadCache()` ⇒ `palette` byte-identical, `foreground` identical, `background` identical,
  `palette_received_count == 256`.
- **Tolerance**: `loadCache` of a truncated/partial file (missing indices, missing fg/bg, no
  header) still returns a usable `Colors` (seeded from `defaultColors()`) — never errors on a
  missing entry; only errors on truly malformed lines.
- **Format compliance**: `writeCache` emits verbatim — header line
  `# tmux-2html palette (queried <iso8601>)`, then `fg R G B`, `bg R G B`, then `0 R G B` …
  `255 R G B` (258 lines total for a full file). Parse is human-debuggable plain text.
- `docs/CONFIGURATION.md` exists with a `## Palette` section.

> **`--release=fast` is MANDATORY** on every build/test (Debug `R_X86_64_PC64` linker bug
> inherited from S1: the test path compiles ghostty-vt).

## User Persona

**Target User**: (1) Downstream implementers — `palette.resolve()` (P1.M2.T1.S3) reads the cache
via `loadCache`; the `sync-palette` body (P1.M2.T2.S1) writes it via `writeCache`; the renderer's
`--palette cached` mode (P1.M3.T1.S3) consumes it. (2) End users who run `tmux-2html sync-palette`
interactively and later `render --palette cached` (or the default `cached→live→default` chain) in a
no-tty `run-shell` context. (3) Power users inspecting/editing the cache file by hand.

**Use Case**: `sync-palette` (T2.S1) calls `queryColors()` (S1) to capture the live terminal
palette, then `writeCache()` to persist it. On every subsequent render, `palette.resolve()`
(S3) calls `loadCache()` — if present, render with the cached palette; if absent, fall through to
`live` (only if a tty exists) or `default`. Because `run-shell` has no tty, the cache is the
**primary** palette source in the tmux plugin flow (PRD §6).

**Pain Points Addressed**: Renders use the user's *actual* terminal colors even when no tty is
available (the entire reason the cache exists, per §6); the plain-text format is greppable/editable
by hand; atomic writes never leave a truncated/half-written file mid-sync.

## Why

- **Persistence half of PRD §6.** S1 produced the *capture* (`queryColors`) and *defaults*
  (`defaultColors`); this task adds the *store* so the palette survives across runs without a tty.
  `resolve()` (S3) and the renderer cannot function without it.
- **Exact round-trip is the contract.** PRD §6 says the cache is "plain text, debuggable"; the item
  contract demands "round-trip must be exact." A `Colors` written then read must reproduce every
  one of its 258 color values, so the renderer sees the same palette the user captured.
- **Isolates all filesystem/atomicity concerns in ONE module.** `resolve()`, `sync-palette`, and
  the renderer never open files or think about XDG paths — they call `loadCache()`/`writeCache()`.
- **Faithful to the verified std API surface.** Every filesystem, formatting, and timestamp API
  used here was read line-by-line from Zig 0.15.2 std source (citations in
  `research/findings.md`); the allocator-explicit `std.ArrayList(u8)` (the unmanaged `Aligned`
  variant in 0.15.2) and `makePath`/`rename`/`tmpDir` semantics are all confirmed.

## What

### Public API added to `src/palette.zig`

```zig
/// Resolve the cache file path: `${XDG_CACHE_HOME:-$HOME/.cache}/tmux-2html/palette`.
/// XDG_CACHE_HOME is honored only if set, non-empty, AND absolute (else $HOME/.cache).
/// Caller owns the returned slice.
pub fn cachePath(allocator: std.mem.Allocator) ![]u8;

/// Serialize `colors` to the cache file ATOMICALLY (temp file in the same dir + rename).
/// mkdir's the parent (`…/tmux-2html/`) first (idempotent). Best-effort fsync before rename.
pub fn writeCache(allocator: std.mem.Allocator, colors: Colors) !void;

/// Read + parse the cache file. Seeds from defaultColors(), then overwrites every parsed
/// entry (palette index / fg / bg). Tolerates missing entries; errors only on malformed lines
/// or a missing $HOME. palette_received_count = number of palette index lines actually parsed.
pub fn loadCache(allocator: std.mem.Allocator) !Colors;
```

> **Signature note:** the item contract writes `writeCache(Colors) !void`, `loadCache(alloc) !Colors`,
> `cachePath(alloc) ![]u8`. Zig requires an explicit allocator for the path string and the
> serialized buffer; this codebase passes allocators explicitly everywhere (`applyOscCommand(…,
> allocator)` in S1, `cli.*(allocator, …)`, tests use `std.testing.allocator`). So the public API
> is allocator-explicit — same intent, consistent with the sibling functions already in palette.zig.

### Cache file format (verbatim, PRD §6)

```
# tmux-2html palette (queried <iso8601>)
fg 255 255 255
bg 41 44 51
0 0 0 0
1 204 66 66
…
255 238 238 238
```

- Line 1: header comment, always starts with `#`. `loadCache` ignores every `#`-line.
- Lines 2–3: `fg R G B` and `bg R G B` (each R/G/B is a decimal u8, 0–255, space-separated).
- Lines 4–259: `i R G B` for i = 0…255.
- A single trailing `\n` after the last line is fine; `loadCache` skips empty lines.
- `<iso8601>` = UTC `YYYY-MM-DDThh:mm:ssZ` (RFC 3339 profile of ISO 8601). Informational only —
  does NOT affect the round-trip (header is skipped on read).

### Success Criteria

- [ ] `cachePath`, `writeCache`, `loadCache` added to `src/palette.zig`; `serialize`/`parse`/
      `writeCacheDir`/`loadCacheDir`/`formatIso8601` helpers present.
- [ ] `src/main.zig`, `build.zig`, `build.zig.zon`, `src/cli.zig` UNCHANGED.
- [ ] `zig build test --release=fast` → exit 0; new cache tests + S1 tests pass; no leaks.
- [ ] Round-trip: `serialize(c)` → `parse(text)` reproduces `c` exactly (all 256 + fg + bg).
- [ ] Tolerance: `parse` of a file with missing indices / no fg / no bg / no header still yields a
      valid `Colors` (default-seeded); `palette_received_count` reflects parsed palette lines.
- [ ] Disk round-trip via `std.testing.tmpDir`: `writeCacheDir` then `loadCacheDir` reproduces `c`.
- [ ] Format: `writeCache` output is the verbatim PRD §6 layout (header + fg + bg + 0…255).
- [ ] `docs/CONFIGURATION.md` created with a `## Palette` section (location + format).

## All Needed Context

### Context Completeness Check

_Pass: "If someone knew nothing about this codebase, would they have everything needed to
implement this successfully?"_ — Yes. Every Zig 0.15.2 std API used (`std.posix.getenv`,
`std.fs.path.isAbsolute`/`dirname`/`basename`, `std.fs.cwd().makePath`,
`std.fs.openDirAbsolute`, `Dir.createFile`/`openFile`/`rename`, `File.writeAll`/
`readToEndAlloc`/`sync`, `std.ArrayList(u8)` = unmanaged `Aligned` variant with
allocator-per-method calls, `std.mem.tokenizeAny`/`splitScalar`, `std.fmt.parseInt`,
`std.time.timestamp` + `std.time.epoch`, `std.testing.tmpDir`) was read **directly from the
cached Zig 0.15.2 source** with line citations in `research/findings.md`, and re-verified for this
PRP. The `Colors`/`color.RGB` input contract is fixed by S1 (its palette.zig already compiles).
The format spec is verbatim from PRD §6. The XDG + atomic-write + ISO 8601 rules are cited from
authoritative external sources in `research/external.md`. No guessing.

### Documentation & References

```yaml
# MUST READ — the consumed S1 contract (Colors/defaultColors/queryColors already exist)
- file: src/palette.zig
  why: "This file ALREADY EXISTS with Colors, defaultColors(), applyOscCommand(), queryColors()
        + S1's tests. This task ADDS to it. Read it first to match doc-comment style, the
        ghostty_vt import aliases (color = ghostty_vt.color), and the module-level header."
  pattern: "color.RGB is `packed struct(u24){ r: u8, g: u8, b: u8 }` — fields are PUBLIC.
            Use `rgb.r`, `rgb.g`, `rgb.b` (each u8). Literal: `.{ .r = 41, .g = 44, .b = 51 }`."
  gotcha: "Do NOT touch anything S1 defined. New pub fns + new tests append to the SAME file."

# MUST READ — the verified std API surface + design rationale (line citations)
- file: plan/001_0c8587f91cb2/P1M2T1S2/research/findings.md
  why: "Sections 0–9: getenv works without libc (simplified_logic=false on x86_64-linux); XDG
        resolution rules; the filesystem API (makePath idempotent + accepts absolute paths,
        Dir.rename same-dir atomicity, createFile truncates by default, openFile read-only by
        default, readToEndAlloc/writeAll/sync); the CRITICAL std.ArrayList(u8) 0.15.2 change
        (unmanaged = allocator-per-method); tokenizeAny/splitScalar; ISO 8601 via std.time.epoch;
        std.testing.tmpDir for the disk test; signatures + round-trip/tolerance semantics."
  critical: "§4 (ArrayList unmanaged: `appendSlice(gpa, items)`, `toOwnedSlice(gpa)`,
             `deinit(gpa)`, init with `.{}`) and §3 (makePath accepts absolute sub_path,
             PathAlreadyExists handled internally) are the two failure-prone APIs. Both verified
             against the 0.15.2 source in this PRP session."

# MUST READ — XDG / atomic write / ISO 8601 external correctness (URLs)
- file: plan/001_0c8587f91cb2/P1M2T1S2/research/external.md
  why: "§1 XDG: unset OR empty OR relative → $HOME/.cache (absolute-path requirement precedent:
        GLib g_get_user_cache_dir). §2 atomic write: temp file in the SAME dir as target (else
        rename(2) fails EXDEV), fsync-before-rename best-effort. §3 ISO 8601/RFC 3339 UTC 'Z'."
  critical: "Co-locating the temp file with the target is what makes rename atomic. A relative
             XDG_CACHE_HOME must fall back to $HOME/.cache (do NOT use a relative cache base)."

# MUST READ — PRD cache location + format (the source of truth)
- file: PRD.md
  section: "§6 Palette subsystem + §5.4 sync-palette"
  why: "Cache path ${XDG_CACHE_HOME:-$HOME/.cache}/tmux-2html/palette; verbatim format (header +
        fg + bg + 0…255); precedence cached → live → default; sync-palette writes the cache."
  critical: "The format string in the contract (fg/bg lines, then '0 R G B' … '255 R G B') is
             reproduced EXACTLY by serialize()."

# MUST READ — S1's PRP (the layer this builds on; gotchas 5/9 carry over)
- file: plan/001_0c8587f91cb2/P1M2T1S1/PRP.md
  why: "Documents Gotcha 5 (--release=fast mandatory) and the lazy-ghostty build graph. The
        main.zig test block already added in S1 makes new palette.zig tests reachable — NO main.zig
        edit needed here."

# Authoritative Zig 0.15.2 std (cached) — confirm any API doubt
- file: /home/dustin/.local/opt/zig-x86_64-linux-0.15.2/lib/std/posix.zig
  section: "getenv (2029) -> ?[:0]const u8"
- file: /home/dustin/.local/opt/zig-x86_64-linux-0.15.2/lib/std/fs.zig
  section: "cwd (220), openDirAbsolute (243)"
- file: /home/dustin/.local/opt/zig-x86_64-linux-0.15.2/lib/std/fs/Dir.zig
  section: "makePath (1175) / makePathStatus (1181, PathAlreadyExists handled internally),
            createFile (983), openFile (818), rename (1772), openDir (1444)"
- file: /home/dustin/.local/opt/zig-x86_64-linux-0.15.2/lib/std/fs/File.zig
  section: "writeAll (975), readToEndAlloc (809), sync (217); OpenOptions.mode default read_only,
            CreateFlags.truncate default true"
- file: /home/dustin/.local/opt/zig-x86_64-linux-0.15.2/lib/std/array_list.zig
  section: "Aligned (600) = unmanaged: deinit(gpa)@654, toOwnedSlice(gpa)@685, append(gpa,item)@893,
            appendSlice(gpa,items)@974. AlignedManaged (16) stores allocator (DEPRECATED)."
- file: /home/dustin/.local/opt/zig-x86_64-linux-0.15.2/lib/std/std.zig
  section: "ArrayList (48) = array_list.Aligned(T, null)  -> the UNMANAGED variant"
- file: /home/dustin/.local/opt/zig-x86_64-linux-0.15.2/lib/std/mem.zig
  section: "tokenizeAny (2275), splitScalar (2514)"
- file: /home/dustin/.local/opt/zig-x86_64-linux-0.15.2/lib/std/time.zig
  section: "timestamp (16) -> i64 Unix seconds"
- file: /home/dustin/.local/opt/zig-x86_64-linux-0.15.2/lib/std/time/epoch.zig
  section: "EpochSeconds{secs}@169, getEpochDay@174, getDaySeconds@180, calculateYearDay@136,
            calculateMonthDay@114, MonthAndDay.day_index (0..30)@130, Month.numeric() u4@83,
            DaySeconds.getHoursIntoDay@155/getMinutesIntoHour@159/getSecondsIntoMinute@163"
- file: /home/dustin/.local/opt/zig-x86_64-linux-0.15.2/lib/std/testing.zig
  section: "tmpDir (626) -> TmpDir{ .dir, .parent_dir, .sub_path }; TmpDir.cleanup() (618)"
- file: /home/dustin/.local/opt/zig-x86_64-linux-0.15.2/lib/std/fs/path.zig
  section: "isAbsolute (277), dirname (845, NULLABLE), basename (979)"
```

### Current Codebase tree (this task's starting point)

```bash
tmux-2html/
├── build.zig            # T1.S2 (LAZY ghostty-vt)                                 ← DO NOT TOUCH
├── build.zig.zon        # T1.S1 (ghostty 1.3.1 + parg)                            ← DO NOT TOUCH
├── src/
│   ├── main.zig         # T3.S1 dispatch + tests; ALREADY has palette test block  ← DO NOT TOUCH
│   ├── palette.zig      # S1: Colors/defaultColors/queryColors/applyOscCommand    ← ADD cache layer
│   ├── cli.zig          # T3.S1/T3.S2 parg parser                                 ← DO NOT TOUCH
│   ├── ghostty_format.zig # T2.S1 vendored formatter                              ← DO NOT TOUCH
│   └── .gitkeep
├── docs/                # DOES NOT EXIST yet                                      ← CREATE CONFIGURATION.md
├── LICENSE  licenses/  scripts/  testdata/  tmux-2html.tmux   # stubs (unchanged)
├── PRD.md  .gitignore  plan/
└── ~/.cache/zig/p/ holds ghostty-1.3.1-... + parg-0.0.0-...  (already fetched)
```

### Desired Codebase tree with files to be changed

```bash
tmux-2html/
├── src/
│   └── palette.zig      # + cachePath/writeCache/loadCache + serialize/parse (pure)
│                        #   + writeCacheDir/loadCacheDir + formatIso8601 + ~6 tests
└── docs/
    └── CONFIGURATION.md # (NEW) ## Palette section: cache location + plain-text format
# build.zig  build.zig.zon  src/main.zig  src/cli.zig   # UNCHANGED
```

### Known Gotchas of our codebase & Library Quirks

```zig
// GOTCHA 1 — CRITICAL (0.15.2): `std.ArrayList(u8)` is the UNMANAGED variant
//   (std.ArrayList = array_list.Aligned(T, null); std.zig:48). It does NOT store the allocator.
//   The allocator-STORING `AlignedManaged` is DEPRECATED. Correct usage:
//       var buf: std.ArrayList(u8) = .{};               // empty struct literal — NO init(gpa)
//       errdefer buf.deinit(allocator);
//       try buf.appendSlice(allocator, "literal");      // (self, gpa, items)
//       const text = try buf.toOwnedSlice(allocator);   // (self, gpa) — caller owns
//   Calling `buf.appendSlice(items)` (no allocator) will NOT COMPILE. Verified: array_list.zig
//   appendSlice(self,gpa,items)@974, toOwnedSlice(self,gpa)@685, deinit(self,gpa)@654.
//   AVOID std.ArrayList(u8).writer(allocator) — build each line with std.fmt.bufPrint(&line,
//   fmt, args) then appendSlice; longest line ~16 bytes ("255 255 255 255\n"), header ~50 → a
//   [64]u8 stack line buffer is plenty.

// GOTCHA 2 — std.posix.getenv works WITHOUT libc (link_libc=false in build.zig). On x86_64-linux
//   the LLVM backend ⇒ std.start.simplified_logic is false ⇒ full Zig start code populates
//   std.os.environ from kernel envp. getenv("XDG_CACHE_HOME") / getenv("HOME") return
//   ?[:0]const u8. NO build change needed. Signature: posix.zig:2029 getenv(key) ?[:0]const u8.

// GOTCHA 3 — XDG resolution (freedesktop spec): XDG_CACHE_HOME is honored ONLY if (set AND
//   non-empty AND absolute). Empty-string or relative value ⇒ fall back to $HOME/.cache (GLib
//   precedent: g_get_user_cache_dir requires absolute). $HOME unset ⇒ error (degenerate).

// GOTCHA 4 — makePath is IDEMPOTENT and accepts an ABSOLUTE sub_path (it uses componentIterator;
//   error.PathAlreadyExists is handled internally, NOT in the error set — Dir.zig:1181). So
//   `std.fs.cwd().makePath(parent_abs)` is safe whether or not the dir exists. Use it to create
//   `…/tmux-2html/` before opening it. Do NOT manually mkdir + catch PathAlreadyExists.

// GOTCHA 5 — CRITICAL (atomic write): the temp file MUST live in the SAME directory as the target.
//   rename(2) is atomic only within one filesystem; across filesystems it fails EXDEV. Co-locating
//   temp + target (both inside `…/tmux-2html/`) guarantees same-fs ⇒ crash leaves old OR new file,
//   never a truncated write. Use Dir.rename(tmp_name, "palette") (Dir.zig:1772, same-Dir rename).

// GOTCHA 6 — createFile truncates by default (CreateFlags.truncate default true, File.zig:148).
//   So Dir.createFile(tmp_name, .{}) gives a fresh empty file. openFile(name, .{}) defaults to
//   read-only (OpenOptions.mode default .read_only, File.zig:94). Always `defer f.close()`.

// GOTCHA 7 — readToEndAlloc(allocator, max_bytes) reads the WHOLE file (File.zig:809). For the
//   cache (~3.6 KB) pass a max_bytes like 1<<20 (1 MiB) — comfortably above the file, rejects a
//   pathologically huge file. Caller owns the returned slice (free it).

// GOTCHA 8 — ISO 8601 timestamp: use std.time.timestamp() (i64 Unix SECONDS, CLOCK_REALTIME wall
//   clock), NOT std.time.Instant (that's monotonic/boottime). Decompose via std.time.epoch:
//   EpochSeconds{.secs=@intCast(ts)} → getEpochDay → calculateYearDay → calculateMonthDay; and
//   getDaySeconds → getHoursIntoDay/getMinutesIntoHour/getSecondsIntoMinute. day_index is 0-based
//   (add 1). Month.numeric() returns u4. Format "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z".
//   The timestamp is informational — loadCache ignores ALL '#' lines, so its value can't break the
//   round-trip. Sanity-check against `date -u` once.

// GOTCHA 9 (carried from S1) — `zig build test` compiles ghostty-vt; the Debug linker hits
//   R_X86_64_PC64. ALWAYS pass --release=fast to every build/test command.

// GOTCHA 10 — tokenizeAny/splitScalar only (0.15.2). The bare std.mem.tokenize / std.mem.split
//   (no suffix) are GONE. Use std.mem.tokenizeAny(u8, line, " \t") for space/tab-separated fields,
//   std.mem.splitScalar(u8, text, '\n') to iterate lines (splitScalar KEEPS empty trailing tokens —
//   skip empties).

// GOTCHA 11 — Round-trip & count semantics (precise): writeCache ALWAYS emits all 258 lines for a
//   full Colors (header + fg + bg + 0…255; fg/bg emitted only when non-null — defaultColors and
//   queryColors are always non-null). loadCache SEEDS from defaultColors() (so a partial cache
//   still yields a usable palette), then overwrites each parsed entry. palette_received_count =
//   number of palette INDEX lines (0…255) actually parsed. For a well-formed writeCache output
//   that is exactly 256 ⇒ round-trips exactly. For a Colors with count<256, writeCache still
//   writes all 256 entries (some default-filled) ⇒ loadCache reports 256: the cache represents
//   "the palette to render", always complete.
```

## Implementation Blueprint

### Data models and structure

```zig
// No NEW data types. This task CONSUMES the existing Colors (defined in S1, do not redefine):
pub const Colors = struct {
    palette: [256]color.RGB,         // color.RGB = packed struct(u24){ r: u8, g: u8, b: u8 }
    foreground: ?color.RGB,
    background: ?color.RGB,
    palette_received_count: u16,
};
// cachePath/writeCache/loadCache operate on Colors. serialize produces []u8; parse consumes []u8.
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: ADD to src/palette.zig — pure `serialize` + `parse`  (NO filesystem)
  - IMPLEMENT serialize(allocator, colors) ![]u8:
      * std.ArrayList(u8) unmanaged (Gotcha 1): var buf: std.ArrayList(u8) = .{};
        errdefer buf.deinit(allocator).
      * Header: append the ISO 8601 line via formatIso8601 (Task 2) into a [32]u8, then
        appendSlice "# tmux-2html palette (queried " + ts + ")\n".
      * fg/bg: ONLY if non-null, appendSlice "fg {d} {d} {d}\n" / "bg …\n" via bufPrint + appendSlice.
      * Loop i in 0..256: appendSlice "{d} {d} {d} {d}\n" .{ i, c.palette[i].r, .g, .b }.
      * return buf.toOwnedSlice(allocator).
  - IMPLEMENT parse(text, allocator) !Colors:
      * var result = defaultColors();  result.palette_received_count = 0;  (seed + tolerate missing)
      * for each line (std.mem.splitScalar(u8, text, '\n')):
          - skip empty lines; skip lines whose first non-space char is '#'.
          - tokenizeAny(u8, line, " \t"); first token decides kind:
              "fg" => expect 3 decimal tokens → result.foreground = RGB{r,g,b}.
              "bg" => expect 3 decimal tokens → result.background = RGB{r,g,b}.
              else => parseInt(u16, first, 10); must be 0..255; expect 3 more → result.palette[idx]
                      = RGB{r,g,b}; result.palette_received_count += 1.
          - on parseInt failure / wrong field count / out-of-range index => return an error
            (error.MalformedLine) — loadCache propagates it. This is the ONLY hard failure.
      * return result. (free the `text` you read is the CALLER's job in loadCache.)
  - NAMING: serialize / parse are module-private (fn, not pub fn) — only cachePath/writeCache/
    loadCache are pub. (They are unit-tested directly because they're in the same file.)
  - PLACEMENT: append in src/palette.zig, in a clearly-marked "---- Cache I/O ----" section.

Task 2: ADD formatIso8601 helper  (header timestamp)
  - IMPLEMENT fn formatIso8601(buf: []u8) []const u8:
      * const ts = std.time.timestamp();  if (ts < 0) return "?";  // pre-1970 guard (never in practice)
      * EpochSeconds{ .secs = @intCast(ts) } → getEpochDay → calculateYearDay → calculateMonthDay;
        getDaySeconds → getHoursIntoDay / getMinutesIntoHour / getSecondsIntoMinute.
      * md.day_index + 1 (0-based → 1-based). md.month.numeric() → u4.
      * std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{...}) catch "?".
      * Width specifiers {d:0>4}/{d:0>2} zero-pad. Return the slice.
  - NAMING: module-private fn. Stack buf in serialize: var tsbuf: [32]u8 = undefined;

Task 3: ADD cachePath(allocator) ![]u8  (XDG resolution, Gotcha 2 + 3)
  - RESOLVE base:
      const xdg = std.posix.getenv("XDG_CACHE_HOME");
      const base = if (xdg) |x| (if (x.len != 0 and std.fs.path.isAbsolute(x)) x else try fallbackHome())
                   else try fallbackHome();
    where fallbackHome() reads getenv("HOME") orelse return error.NoHomeDirectory.
  - return std.fmt.allocPrint(allocator, "{s}/tmux-2html/palette", .{base}).  // caller owns
  - GOTCHA 3: relative/empty XDG_CACHE_HOME → $HOME/.cache. Do NOT use a relative base.

Task 4: ADD dir-scoped helpers + writeCache/loadCache  (atomic write, Gotchas 4/5/6/7)
  - IMPLEMENT fn writeCacheDir(dir: std.fs.Dir, filename: []const u8, allocator, colors) !void:
      * const text = try serialize(allocator, colors);  defer allocator.free(text);
      * const tmp = ".palette.tmp";   // SAME dir as target ⇒ same filesystem (Gotcha 5)
      * var f = try dir.createFile(tmp, .{});  // truncate default (Gotcha 6)
        errdefer { f.close(); dir.deleteFile(tmp) catch {}; }   // cleanup on error
        try f.writeAll(text);
        f.sync() catch {};   // best-effort durability before rename (Gotcha 5)
        f.close();
      * dir.rename(tmp, filename) catch |err| { dir.deleteFile(tmp) catch {}; return err; };
  - IMPLEMENT fn loadCacheDir(dir: std.fs.Dir, filename: []const u8, allocator) !Colors:
      * var f = try dir.openFile(filename, .{});  defer f.close();   // read-only (Gotcha 6)
      * const text = try f.readToEndAlloc(allocator, 1 << 20);  defer allocator.free(text);  // Gotcha 7
      * return parse(text, allocator);   // seeds defaultColors + tolerates missing entries
  - IMPLEMENT pub fn writeCache(allocator, colors) !void:
      * const path = try cachePath(allocator);  defer allocator.free(path);
      * const dir_path = std.fs.path.dirname(path) orelse return error.BadPath;  // nullable (Gotcha)
      * std.fs.cwd().makePath(dir_path) catch {};   // idempotent (Gotcha 4); tolerate error
      * var dir = try std.fs.openDirAbsolute(dir_path, .{});  defer dir.close();
      * try writeCacheDir(dir, std.fs.path.basename(path), allocator, colors);
  - IMPLEMENT pub fn loadCache(allocator) !Colors:
      * const path = try cachePath(allocator);  defer allocator.free(path);
      * const dir_path = std.fs.path.dirname(path) orelse return error.BadPath;
      * var dir = try std.fs.openDirAbsolute(dir_path, .{});  defer dir.close();
      * return loadCacheDir(dir, std.fs.path.basename(path), allocator);
  - NAMING: pub fn for cachePath/writeCache/loadCache; fn for the dir-scoped helpers + serialize
    + parse + formatIso8601. Matches S1's style (queryColors is pub; feedAndApply/readAndFeed are fn).

Task 5: ADD unit tests to src/palette.zig  (NO real $XDG_CACHE_HOME; pure + tmpDir)
  - TEST "serialize: full format (header + fg + bg + 0..255)":
      serialize(defaultColors()); assert first line startsWith "# tmux-2html palette (queried ";
      assert lines[1] == "fg 187 187 187" (default[7]); lines[2] startswith "bg 41 44 51";
      assert a line "0 0 0 0" and "255 238 238 238" present (use default[0]/default[255]).
      Count '\n' == 258 (header+fg+bg+256). (Use std.testing.allocator; free the slice.)
  - TEST "parse + serialize round-trip is exact":
      const orig = defaultColors();  const text = serialize(orig);  const got = parse(text);
      assert got.palette == orig.palette (256-equal); got.foreground == orig.foreground;
      got.background == orig.background; got.palette_received_count == 256.
  - TEST "parse: truncated file still yields usable Colors (tolerance)":
      parse("0 1 2 3\n5 10 20 30\n");  // no header, no fg/bg, only 2 indices
      assert palette[0]=={1,2,3}; palette[5]=={10,20,30}; count==2; foreground/background ==
      defaultColors() (seeded, untouched); every other palette index == default.
  - TEST "parse: header + comment lines ignored":
      parse("# a comment\n# another\nfg 1 2 3\n0 4 5 6\n"); assert foreground=={1,2,3};
      palette[0]=={4,5,6}; count==1.
  - TEST "writeCacheDir + loadCacheDir disk round-trip (std.testing.tmpDir)":
      var tmp = std.testing.tmpDir(.{});  defer tmp.cleanup();
      const orig = defaultColors();  try writeCacheDir(tmp.dir, "palette", alloc, orig);
      const got = try loadCacheDir(tmp.dir, "palette", alloc);
      assert got.palette == orig.palette; got.foreground==orig.foreground; got.background==
      orig.background; got.palette_received_count == 256.
      (Inspect the file with tmp.dir.openFile("palette",.{}) + readToEndAlloc to assert the header
      line is present — proves the on-disk format, not just the API.)
  - TEST "parse: malformed line errors" (negative):
      expectError(error.MalformedLine, parse("0 notanumber\n"));
      expectError(error.MalformedLine, parse("300 1 2 3\n"));   // index out of range
  - TEST "cachePath: honors XDG_CACHE_HOME only when absolute":
      (Set env via a child process OR factor a cachePathBase() helper that takes the resolved base,
      and unit-test THAT directly with literal bases — avoids mutating process env. RECOMMENDED:
      extract `fn cacheBase() ![:0]const u8` returning the chosen base string from getenv, and test
      the fmt result of "{s}/tmux-2html/palette" against a literal base. Do NOT mutate environ.)
  - COVERAGE: round-trip (happy), tolerance (missing), header-ignore, disk round-trip, malformed
    (negative). Use std.testing.allocator everywhere; free every owned slice.
  - PLACEMENT: append to the existing "---- Unit tests ----" section in palette.zig.

Task 6: CREATE docs/CONFIGURATION.md  (Mode A — user-facing cache surface, PRD §6)
  - CREATE the file with a `# Configuration` title and a `## Palette` section documenting:
      * Cache file location: `${XDG_CACHE_HOME:-$HOME/.cache}/tmux-2html/palette`
        (XDG_CACHE_HOME honored only if absolute; else $HOME/.cache).
      * Plain-text format (show the verbatim PRD §6 block: header + fg + bg + 0…255).
      * How it is populated: `tmux-2html sync-palette` (§5.4); auto-sync on first plugin load (§6).
      * How it is consumed: render precedence cached → live → default (§6); the renderer reads it.
      * Hand-editability: it is plain text; lines can be deleted/edited; missing entries fall back
        to the bundled default palette.
  - This is a user-facing doc surface — keep it accurate, short, and matched to PRD §6 wording.

Task 7: VALIDATE  (see Validation Loop — every command verified against this toolchain)
  - RUN: zig build test --release=fast      # new cache tests + S1 tests pass, no leaks
  - RUN: zig build --release=fast           # ghostty stays lazy; exe builds
  - RUN: git diff --stat src/main.zig build.zig build.zig.zon src/cli.zig   # expect: unchanged
```

### Implementation Patterns & Key Details

```zig
// PATTERN: serialize a Colors to the verbatim PRD §6 plain-text format.
fn serialize(allocator: std.mem.Allocator, colors: Colors) ![]u8 {
    var buf: std.ArrayList(u8) = .{};                 // unmanaged (Gotcha 1)
    errdefer buf.deinit(allocator);
    var line: [64]u8 = undefined;

    // Header (ISO 8601, informational — skipped on read).
    var tsbuf: [32]u8 = undefined;
    const ts = formatIso8601(&tsbuf);
    try buf.appendSlice(allocator, "# tmux-2html palette (queried ");
    try buf.appendSlice(allocator, ts);
    try buf.appendSlice(allocator, ")\n");

    // fg / bg (only when present — defaultColors/queryColors are always non-null).
    if (colors.foreground) |fg| {
        const s = std.fmt.bufPrint(&line, "fg {d} {d} {d}\n", .{ fg.r, fg.g, fg.b }) catch unreachable;
        try buf.appendSlice(allocator, s);
    }
    if (colors.background) |bg| {
        const s = std.fmt.bufPrint(&line, "bg {d} {d} {d}\n", .{ bg.r, bg.g, bg.b }) catch unreachable;
        try buf.appendSlice(allocator, s);
    }
    // 0..255.
    var i: u16 = 0;
    while (i < 256) : (i += 1) {
        const p = colors.palette[i];
        const s = std.fmt.bufPrint(&line, "{d} {d} {d} {d}\n", .{ i, p.r, p.g, p.b }) catch unreachable;
        try buf.appendSlice(allocator, s);
    }
    return buf.toOwnedSlice(allocator);
}

// PATTERN: parse into a defaultColors()-seeded Colors (tolerates missing entries).
fn parse(text: []const u8) !Colors {   // allocator-free: parse never allocates (operates on `text`)
    var result = defaultColors();
    result.palette_received_count = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');   // keeps empty trailing tokens
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#') continue;                  // header + comments
        var f = std.mem.tokenizeAny(u8, line, " \t");
        const head = f.next() orelse continue;
        if (std.mem.eql(u8, head, "fg") or std.mem.eql(u8, head, "bg")) {
            const r = parseU8(f.next()) catch return error.MalformedLine;
            const g = parseU8(f.next()) catch return error.MalformedLine;
            const b = parseU8(f.next()) catch return error.MalformedLine;
            const rgb: color.RGB = .{ .r = r, .g = g, .b = b };
            if (std.mem.eql(u8, head, "fg")) result.foreground = rgb else result.background = rgb;
        } else {
            const idx = std.fmt.parseInt(u16, head, 10) catch return error.MalformedLine;
            if (idx > 255) return error.MalformedLine;
            const r = parseU8(f.next()) catch return error.MalformedLine;
            const g = parseU8(f.next()) catch return error.MalformedLine;
            const b = parseU8(f.next()) catch return error.MalformedLine;
            result.palette[idx] = .{ .r = r, .g = g, .b = b };
            result.palette_received_count += 1;
        }
    }
    return result;
}
fn parseU8(tok: ?[]const u8) !u8 {
    return std.fmt.parseInt(u8, tok orelse return error.MalformedLine, 10);
}
// NOTE: `parse` takes no allocator — it indexes into the caller-owned `text`. loadCacheDir owns
// `text` (readToEndAlloc) and frees it after parse. This keeps parse pure & allocation-free.

// PATTERN: atomic write (temp file in SAME dir + rename). See Gotcha 5.
fn writeCacheDir(dir: std.fs.Dir, filename: []const u8, allocator: std.mem.Allocator, colors: Colors) !void {
    const text = try serialize(allocator, colors);
    defer allocator.free(text);
    const tmp = ".palette.tmp";                       // same dir ⇒ same filesystem
    var f = try dir.createFile(tmp, .{});             // truncate default (Gotcha 6)
    errdefer { f.close(); dir.deleteFile(tmp) catch {}; }
    try f.writeAll(text);
    f.sync() catch {};                                // best-effort durability
    f.close();
    dir.rename(tmp, filename) catch |err| { dir.deleteFile(tmp) catch {}; return err; };
}

// PATTERN: XDG resolution (Gotcha 2 + 3). cachePath owns the returned slice.
pub fn cachePath(allocator: std.mem.Allocator) ![]u8 {
    const base = try cacheBase();
    return std.fmt.allocPrint(allocator, "{s}/tmux-2html/palette", .{base});
}
fn cacheBase() ![:0]const u8 {
    if (std.posix.getenv("XDG_CACHE_HOME")) |x| {
        if (x.len != 0 and std.fs.path.isAbsolute(x)) return x;   // honor absolute only
    }
    return std.posix.getenv("HOME") orelse return error.NoHomeDirectory;
}
```

### Integration Points

```yaml
BUILD GRAPH:
  - consumes (unchanged): build.zig (LAZY ghostty-vt via exe.root_module.addImport),
    build.zig.zon, src/main.zig (test block already present from S1). src/cli.zig (parallel — do not touch).
  - produces: additions to src/palette.zig (cache layer) + new docs/CONFIGURATION.md.
  - next (P1.M2.T1.S3 resolve): palette.resolve(mode) calls loadCache() for "cached" → on error/
              missing falls through to "live" (queryColors, only if tty) → "default" (defaultColors).
  - next (P1.M2.T2.S1 sync-palette body): cli.SyncPaletteOpts → queryColors/--from file → writeCache.
  - next (P1.M3.T1.S3 renderer --palette): the cached/live/default precedence lives in resolve().

CONFIG / ENV:
  - cachePath reads XDG_CACHE_HOME (absolute only) / HOME. No new env vars.
  - The cache file is $XDG_CACHE_HOME/tmux-2html/palette (a FILE, not a dir of files — PRD §6).

FILESYSTEM SURFACE:
  - mkdir (idempotent makePath) $XDG_CACHE_HOME/tmux-2html/
  - create+write+sync $XDG_CACHE_HOME/tmux-2html/.palette.tmp, rename over …/palette (atomic)
  - read …/palette on load (errors → resolve() falls through; that's S3's job, not here)

TEST DISCOVERY:
  - New tests in palette.zig run via the EXISTING main.zig test-block import (no main.zig change).
  - Disk round-trip uses std.testing.tmpDir (throwaway .zig-cache/tmp/<rand>/); never touches the
    real $XDG_CACHE_HOME. Pure serialize/parse tests touch no filesystem at all.

DOCUMENTATION (Mode A, PRD §5):
  - docs/CONFIGURATION.md §Palette: cache location + plain-text format + how it's populated/consumed.
```

## Validation Loop

> Re-run verbatim. EVERY build/test command MUST include `--release=fast` (Gotcha 9).

### Level 1: Syntax & Style (Immediate Feedback)

```bash
zig version            # MUST print: 0.15.2
zig build --fetch      # exit 0 (deps cached; instant)
```

### Level 2: Build + unit tests (PRIMARY gate)

```bash
# New cache tests + S1 palette tests + existing main/cli tests. No leaks (std.testing.allocator).
zig build test --release=fast          # expect: all passed, exit 0

# Exe still builds; ghostty stays LAZY on the non-test path (no new imports).
zig build --release=fast               # expect: exit 0
ls -la zig-out/bin/tmux-2html          # expect: ELF binary exists

# If "unhandled relocation type R_X86_64_PC64" -> forgot --release=fast (Gotcha 9).
# If std.ArrayList appendSlice "expected 1 arg, found 2" / "no field or member function named
#   'deinit'" -> used the MANAGED (allocator-storing) API on the unmanaged ArrayList (Gotcha 1).
# If testing.allocator reports a leak -> forgot to free the serialize() / readToEndAlloc() slice.
```

### Level 3: Behavior (the contract — round-trip exact + tolerance + format)

```bash
# The unit tests ARE the Level-3 gate (no real $XDG_CACHE_HOME in CI). They assert:
#   serialize(defaultColors()) -> 258 lines; header startswith "# tmux-2html palette (queried ";
#     fg line; bg line "bg 41 44 51"; a "0 0 0 0" line; a "255 ..." line.
#   parse(serialize(c)) reproduces c EXACTLY (palette, fg, bg, count==256).
#   parse of a truncated/missing-entry file -> default-seeded Colors, count = parsed palette lines.
#   parse ignores '#' comment/header lines.
#   writeCacheDir + loadCacheDir round-trip via std.testing.tmpDir (disk); on-disk header present.
#   parse of a malformed line (non-numeric / idx>255) -> error.MalformedLine.
zig build test --release=fast -- 2>&1 | tail    # confirm cache test names appear + pass
```

### Level 4: Scope boundary + format sanity (Domain Validation)

```bash
# ONLY palette.zig changed + docs/CONFIGURATION.md added; build files + main.zig + cli.zig untouched.
git diff --stat build.zig build.zig.zon src/main.zig src/cli.zig   # expect: no output (unchanged)
git diff --stat src/palette.zig                                    # expect: palette.zig modified (additions)
git status --short docs/CONFIGURATION.md                           # expect: new untracked file

# Format sanity: produce a real cache file in a throwaway XDG and eyeball it against PRD §6.
mkdir -p /tmp/t2h-xdg && XDG_CACHE_HOME=/tmp/t2h-xdg zig-out/bin/tmux-2html sync-palette 2>/dev/null \
  || true   # sync-palette body lands in T2.S1; if it's still a stub, instead cat a test fixture:
# (If sync-palette is not wired yet, write a tiny throwaway test main that calls palette.writeCache,
#  OR inspect the serialize() output captured in the unit test.) The expected shape:
#   # tmux-2html palette (queried 2026-07-08T..:..:..Z)
#   fg 187 187 187
#   bg 41 44 51
#   0 0 0 0
#   ...
#   255 238 238 238
head -4 /tmp/t2h-xdg/tmux-2html/palette 2>/dev/null    # eyeball header + fg + bg + first index
tail -1 /tmp/t2h-xdg/tmux-2html/palette 2>/dev/null    # eyeball last index line "255 R G B"
wc -l /tmp/t2h-xgd/tmux-2html/palette 2>/dev/null      # expect 258 lines for a full file
rm -rf /tmp/t2h-xdg
```

## Final Validation Checklist

### Technical Validation

- [ ] `zig version` prints `0.15.2`; `zig build --fetch` exits 0.
- [ ] `zig build test --release=fast` exits 0 (new cache tests + S1 tests + existing tests pass, no leaks).
- [ ] `zig build --release=fast` exits 0; `zig-out/bin/tmux-2html` produced.

### Feature Validation

- [ ] `serialize(defaultColors())` produces the verbatim PRD §6 format: header (ISO 8601) + `fg` +
      `bg` + `0`…`255` (258 lines for a full file).
- [ ] `parse(serialize(c))` reproduces `c` exactly (`palette`, `foreground`, `background`,
      `palette_received_count == 256`).
- [ ] `parse` tolerates missing entries (no header, missing indices, missing fg/bg): seeds from
      `defaultColors()`, `palette_received_count` = parsed palette lines; never errors on a MISSING entry.
- [ ] `parse` errors (`error.MalformedLine`) ONLY on a malformed line (non-numeric / index > 255).
- [ ] `writeCacheDir`/`loadCacheDir` round-trip on disk via `std.testing.tmpDir`; on-disk file has
      the header line (proves the format, not just the API).
- [ ] `cachePath` honors `XDG_CACHE_HOME` only when set + non-empty + absolute; else `$HOME/.cache`.
- [ ] `docs/CONFIGURATION.md` created with a `## Palette` section (location + format + populate/consume).

### Code Quality Validation

- [ ] `std.ArrayList(u8)` used as the UNMANAGED variant: `.{}` init, `appendSlice(gpa, …)`,
      `toOwnedSlice(gpa)`, `deinit(gpa)` (Gotcha 1) — no `init(gpa)`/managed API.
- [ ] Atomic write: temp file `.palette.tmp` in the SAME dir as `palette` + `rename` (Gotcha 5);
      temp cleaned up on error; best-effort `sync()` before rename.
- [ ] `src/main.zig`, `build.zig`, `build.zig.zon`, `src/cli.zig` unchanged.
- [ ] No new `@import("ghostty-vt")` (palette.zig already imports it from S1); nothing outside the
      test root imports palette.zig (cache fns are called by future resolve()/sync-palette).
- [ ] New tests use `std.testing.allocator`; every owned slice (`serialize`, `readToEndAlloc`,
      `cachePath`) is freed; no leaks.

### Documentation & Deployment

- [ ] `docs/CONFIGURATION.md` matches PRD §6 wording for the cache location + format.
- [ ] No new env vars (XDG_CACHE_HOME / HOME already standard).
- [ ] The ISO 8601 timestamp is cosmetic; its value is sanity-checked against `date -u` once.

---

## Anti-Patterns to Avoid

- ❌ Don't use the MANAGED `std.ArrayList` API (`var buf = std.ArrayList(u8).init(allocator)` /
  `buf.append(x)` / `buf.deinit()`) — in 0.15.2 `std.ArrayList(u8)` is the UNMANAGED `Aligned`
  variant; those calls won't compile. Use `.{}` + `appendSlice(gpa, …)` + `toOwnedSlice(gpa)` +
  `deinit(gpa)` (Gotcha 1).
- ❌ Don't put the temp file in `/tmp` or the cwd — `rename(2)` across filesystems fails EXDEV and is
  NOT atomic. Co-locate `.palette.tmp` with `palette` inside `…/tmux-2html/` (Gotcha 5).
- ❌ Don't catch + ignore a missing cache in `loadCache` to "fall back to default" — that's
  `resolve()`'s job (S3). `loadCache` should PROPAGATE the open error; `resolve()` decides the
  precedence. (Tolerance is about *partial files*, not *missing files*.)
- ❌ Don't seed `loadCache`/`parse` from a zero `Colors` — seed from `defaultColors()` so a partial
  cache still renders (the "tolerate missing entries" contract). Only parsed entries overwrite.
- ❌ Don't let `parse` mutate process env to test `cachePath` — extract a `cacheBase()` helper and
  unit-test the path-building against a literal base instead. Mutating `environ` is unsafe.
- ❌ Don't build/test WITHOUT `--release=fast` — palette.zig compiles ghostty-vt in the test path;
  Debug linking hits `R_X86_64_PC64` (Gotcha 9).
- ❌ Don't use bare `std.mem.tokenize` / `std.mem.split` (no suffix) — GONE in 0.15.2. Use
  `tokenizeAny(u8, line, " \t")` for fields, `splitScalar(u8, text, '\n')` for lines (Gotcha 10).
  Remember `splitScalar` keeps empty trailing tokens — skip empty lines.
- ❌ Don't modify `build.zig`, `build.zig.zon`, `src/main.zig`, or `src/cli.zig` — the main.zig test
  block already reaches palette.zig (S1), and ghostty-vt is already a lazy import on `exe.root_module`.
- ❌ Don't alter anything S1 defined in `palette.zig` (`Colors`, `defaultColors`, `applyOscCommand`,
  `queryColors`, S1's tests). This task APPENDS a cache section to the same file.
- ❌ Don't use `std.time.Instant` for the header timestamp — it's monotonic/boottime, not wall-clock.
  Use `std.time.timestamp()` (Unix seconds) decomposed via `std.time.epoch` (Gotcha 8).
- ❌ Don't count `palette_received_count` on `fg`/`bg` lines — only on palette INDEX lines (0…255),
  matching S1's `applyOscCommand` semantics.

---

**Confidence Score: 9/10** for one-pass implementation success.

Every Zig 0.15.2 std API used (`std.posix.getenv`, `std.fs.path.isAbsolute/dirname/basename`,
`std.fs.cwd().makePath`, `std.fs.openDirAbsolute`, `Dir.createFile/openFile/rename`,
`File.writeAll/readToEndAlloc/sync`, the unmanaged `std.ArrayList(u8)` with allocator-per-method
calls, `std.mem.tokenizeAny/splitScalar`, `std.fmt.parseInt`, `std.time.timestamp` +
`std.time.epoch`, `std.testing.tmpDir`) was read line-by-line from the cached Zig 0.15.2 source
(citations in `research/findings.md`) and re-verified against the std source in this PRP session —
including the critical confirmation that `std.ArrayList(T) = array_list.Aligned(T, null)` is the
unmanaged variant (allocator-per-method), and that `makePath` is idempotent + accepts absolute
paths. The `Colors`/`color.RGB` input contract is fixed by S1 (its palette.zig already compiles
and passes). The cache format is verbatim from PRD §6; the XDG/atomic-write/ISO 8601 rules are
cited from authoritative external sources. The pure `serialize`/`parse` split makes the
round-trip + tolerance deterministically unit-testable with no filesystem, and `std.testing.tmpDir`
covers the atomic disk path without touching the real `$XDG_CACHE_HOME`. The only residual risk is
the cosmetic ISO 8601 timestamp value, which is explicitly excluded from the round-trip (header
lines are skipped on read), so it cannot affect correctness.
