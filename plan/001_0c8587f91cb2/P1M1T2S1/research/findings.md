# Research Findings — P1.M1.T2.S1 (Vendor ghostty_format.zig + LICENSE + notices)

> All facts below were **verified empirically** on 2026-07-08 against the real Zig 0.15.2
> toolchain + the cached ghostty v1.3.1 dep, and against the live upstream repositories.
> Frozen reference copies live alongside this file:
> `ghostty_format.zig`, `TERM2HTML_LICENSE.txt`, `GHOSTTY_VT_LICENSE.txt`.

## 1. The vendored file — provenance & integrity

- **Source**: `aarol/term2html`, branch `main`, latest commit `4dac3dbdae4a96cfae68aa744b94570e22fe0361` (pushed 2026-04-17).
- **Raw URL**: `https://raw.githubusercontent.com/aarol/term2html/main/src/ghostty_format.zig`
- **File**: `src/ghostty_format.zig` (1587 lines, 61925 bytes).
- **SHA-256** of frozen copy: `7fd9dc338b643d48de3ca718277e2d7d600daeb6932169e1dca457611db26094`
- **Header** (lines 1-3): MIT, `Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors`.
- **Modification note** (line 28, verbatim): *"This is copied from the Ghostty codebase
  and has been modified to output more idiomatic HTML as well as provide more control over the output."*

## 2. The #1 risk (ghostty API drift) — ELIMINATED

term2html's `main` branch `build.zig.zon` pins **exactly** the same ghostty version we do:

```
.url = "https://github.com/ghostty-org/ghostty/archive/refs/tags/v1.3.1.tar.gz",
.hash = "ghostty-1.3.1-5UdBCwYm-gQeBa4bu1-sMooCQS4KVriv5wWSIJ_sI-Cb",
```

Our `build.zig.zon` (from S1) uses the **identical** URL + hash. Therefore the vendored
file is compiled against the **exact** ghostty-vt API it was authored for. No drift.

## 3. Compilation — VERIFIED (standalone build, exit 0)

Built a throwaway project at `/tmp/t2h-vendor-verify` reusing the repo's real `build.zig` +
`build.zig.zon` (which wire the `ghostty-vt` module per S2), added the vendored file, and a
consumer `src/main.zig` that forces analysis of the required symbols:

- `zig build --fetch` → exit 0
- `zig build --release=fast` → exit 0, produces `zig-out/bin/tmux-2html` (2394528 bytes ELF)
- `zig build run --release=fast` → prints `tmux-2html 0.1.0: formatter vendored OK`
- `zig build test --release=fast` → exit 0 (test exercising `Options.font` passes)

(As in S2, `--release=fast` is MANDATORY — bare Debug hits the `R_X86_64_PC64` linker bug.)

## 4. Importable symbols — what is actually `pub`

Verified from the frozen file. Downstream (`render.zig`, region TUI, golden tests) consumes
the formatter as a **sibling file**: `const fmt = @import("ghostty_format.zig");`
(NOTE the `.zig` extension — it is NOT a registered module; `@import("ghostty_format")` fails
with `no module named 'ghostty_format' available within module 'root'`. VERIFIED error.)

| Symbol | Access | pub? | Notes |
|---|---|---|---|
| `Format` | `fmt.Format` | ✅ | enum `.plain`/`.vt`/`.html` |
| `Options` | `fmt.Options` | ✅ | has `font: ?[]const u8` (line 133, term2html custom addition, **no default** — required field) |
| `ScreenFormatter` | `fmt.ScreenFormatter` | ✅ | `.init(screen, opts)`, then set `.content`/`.extra` |
| `ScreenFormatter.Content` | `fmt.ScreenFormatter.Content` | ✅ | `union(enum){ none, selection: ?Selection }` |
| `ScreenFormatter.Extra` | `fmt.ScreenFormatter.Extra` | ✅ | packed struct; `.none`/`.styles`/`.all` |
| `TerminalFormatter` | `fmt.TerminalFormatter` | ✅ | takes a `*const Terminal` (vs ScreenFormatter's `*const Screen`) |
| `PageListFormatter` / `PageFormatter` | ... | ✅ | used internally; also pub |
| `Hyperlink` | `fmt.Hyperlink` | ✅ | |
| `Selection` | — | ❌ **private** | `const Selection = @import("ghostty-vt").Selection;` (line 40) |

### Critical nuance about `Selection`
The item contract says "Selection importable from it", but the vendored file makes
`Selection` a **private** const alias (line 40). Downstream must obtain `Selection` from
`ghostty-vt` directly: `const Selection = @import("ghostty-vt").Selection;`. This matches
`render_pipeline.md` §4 (`const Selection = @import("ghostty-vt").Selection;`). The
formatter *uses* `Selection` inside `ScreenFormatter.Content.selection: ?Selection` — it
just doesn't re-export it. **Do NOT edit the vendored file to make it pub** — keep it
verbatim; downstream already imports Selection from `ghostty-vt`.

## 5. `Options.font` — the term2html custom addition

```zig
// line 104-135 (verbatim from frozen file)
pub const Options = struct {
    emit: Format,
    unwrap: bool = false,
    trim: bool = true,
    codepoint_map: ?std.MultiArrayList(CodepointMap) = .{},
    background: ?color.RGB = null,
    foreground: ?color.RGB = null,
    palette: ?*const color.Palette = null,
    font: ?[]const u8,          // <-- line 133: NO default. Required when constructing Options.
    pub const plain: Options = .{ .emit = .plain };
    pub const vt: Options = .{ .emit = .vt };
    pub const html: Options = .{ .emit = .html };
};
```
GOTCHA: because `font` has no default, any `Options` literal MUST set `.font`, e.g.
`.{ .emit = .html, .font = "monospace" }` or `.{ .emit = .html, .font = null }`. The
predefined `.plain`/`.vt`/`.html` constants set it implicitly (verified). This is exactly
the field ghostty's stock formatter lacks (findings_and_corrections.md §0.4).

## 6. The formatter's full import surface (verified — lines 30-44)

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const color = @import("ghostty-vt").color;
const size = @import("ghostty-vt").size;
const ghostty_vt = @import("ghostty-vt");
const kitty = @import("ghostty-vt").kitty;
const modespkg = @import("ghostty-vt").modes;
const Screen = @import("ghostty-vt").Screen;
const Terminal = @import("ghostty-vt").Terminal;
const Cell = @import("ghostty-vt").page.Cell;
const Coordinate = @import("ghostty-vt").point.Coordinate;
const Page = @import("ghostty-vt").page.Page;
const PageList = @import("ghostty-vt").PageList;
const Pin = PageList.Pin;
const Row = @import("ghostty-vt").page.Row;
const Selection = @import("ghostty-vt").Selection;
const Style = @import("ghostty-vt").Style;
```
All resolve against ghostty v1.3.1 (verified by the exit-0 build). Uses the Zig 0.15.2
`std.Io.Writer` API (`*std.Io.Writer`, `.Discarding`, etc.) — consistent with our toolchain.

## 7. License texts (frozen, verbatim)

### 7a. term2html LICENSE (`licenses/TERM2HTML.txt`)
MIT, single line: `Copyright (c) 2026 aarol` (matches PRD §4 exactly). Full text in
`research/TERM2HTML_LICENSE.txt` (21 lines). Source: `aarol/term2html/main/LICENSE`.

### 7b. ghostty LICENSE (`licenses/GHOSTTY-VT.txt`)
MIT, single line: `Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors`. Full text
in `research/GHOSTTY_VT_LICENSE.txt` (21 lines). Source: `ghostty-org/ghostty` tag `v1.3.1`
(`/LICENSE`). NOTE: ghostty's LICENSE is a flat MIT file at the v1.3.1 tag root (the large
`LICENSE-MIT.txt`/bundled-notice layout appears in later tags/dist tarballs; the v1.3.1 tag
root `LICENSE` is the 21-line MIT text). We are consuming the `ghostty-vt` Zig module, so the
MIT notice is the correct attribution (PRD §14).

### 7c. project LICENSE
MIT. Holder: `Dustin Schultz` (from `git config user.name`). Year: `2026` (current).
`Copyright (c) 2026 Dustin Schultz`. (Human-owned value; flagged for adjustment in PRP.)

## 8. Scope boundary (CRITICAL — runs in parallel with P1.M1.T1.S2)

- **DO NOT** modify `build.zig` (owned by S2) or `src/main.zig` (S2 stub; replaced by T3.S1).
  Both are being implemented concurrently; touching either risks merge conflicts.
- **DO NOT** wire a `ghostty_format` module into the build, and **DO NOT** add an
  `@import("ghostty_format.zig")` to `main.zig`. Sibling-file import is the consumer's job
  (P1.M3.T1.S1 `render.zig`), not this task's.
- The deliverables are 4 **static files**: `src/ghostty_format.zig`, `LICENSE`,
  `licenses/TERM2HTML.txt`, `licenses/GHOSTTY-VT.txt`.
- Compilation is validated via a **standalone throwaway build** (mirrors S2's
  `/tmp/t2h-s2-verify` approach), NOT via the in-repo test step. In-repo compilation of the
  formatter is exercised later by P1.M3.T1.S1 (render.zig imports it) — out of scope here.

## 9. Exact validation commands (all verified exit 0)

```bash
zig version                       # 0.15.2
# (in the throwaway verify dir that reuses build.zig + build.zig.zon + src/ghostty_format.zig + a consumer)
zig build --fetch                 # exit 0
zig build --release=fast          # exit 0, binary produced
zig build test --release=fast     # exit 0
```
Plus content/integrity checks (sha256, grep for `font: ?[]const u8`, license lines) — see PRP.
