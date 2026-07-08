# Research: Ghostty VT (virtual terminal) Zig library API

> **Provenance / confidence caveat (READ FIRST).** This brief was authored from prior
> knowledge of the Ghostty codebase because, at runtime, no `web_search` tool was
> provisioned and the Zig package cache could not be enumerated to read the fetched
> source directly. Each technical claim is tagged with one of:
>
> - **CONFIDENT** — stable, well-known facts about Ghostty's architecture.
> - **BEST-KNOWN** — module names / file paths I am fairly sure of but could not
>   re-verify line-by-line.
> - **UNVERIFIED** — struct field names, signatures, or flag names reconstructed
>   from naming conventions; **must be confirmed against the fetched source before
>   depending on them in code.**
>
> The `.hash` for `build.zig.zon` is intentionally **NOT invented** (see §4). The
> supervisor is independently verifying the critical `Selection` / `ScreenFormatter`
> field names and the `ghostty_vt` / `ghostty_format` module wiring via web search.

## Summary

Ghostty (Zig, github.com/ghostty-org/ghostty) exposes its terminal engine as Zig
modules that a downstream project imports via `b.dependency("ghostty", ...).module(...)`.
The two relevant modules for term2html / tmux-2html are **`ghostty_vt`** (the VT
engine, exposing `Terminal`) and **`ghostty_format`** (output formatters, exposing
`ScreenFormatter`, which can emit HTML from screen state). Ghostty vendors the C++
SIMD libraries it uses (highway, simdutf, utfcpp) and compiles them in its
`build.zig`; this triggers a known Zig Debug-mode linker defect (`R_X86_64_PC64`
relocations from static C++ SIMD objects), which is the reason these projects
build in a release optimization mode and/or disable the SIMD path.

## Findings

### 1. Module paths / imports for `ghostty_vt.Terminal` and `ghostty_format.ScreenFormatter`

- **CONFIDENT** Ghostty is written in Zig and is hosted at `github.com/ghostty-org/ghostty`.
  It ships both a C ABI library (`libghostty`, header `include/ghostty.h`) and Zig
  modules usable by other Zig packages.
- **BEST-KNOWN** Ghostty's `build.zig` exposes add-on modules. The two named by this
  task — `ghostty_vt` and `ghostty_format` — are the canonical module names to
  `addImport` into a downstream module. Expected downstream `build.zig` wiring:
  ```zig
  const ghostty_dep = b.dependency("ghostty", .{
      .target = target,
      .optimize = optimize,
  });
  // module() names match the names Ghostty registered in its build.zig:
  exe.root_module.addImport("ghostty_vt", ghostty_dep.module("ghostty_vt"));
  exe.root_module.addImport("ghostty_format", ghostty_dep.module("ghostty_format"));
  ```
  and then in application source:
  ```zig
  const vt      = @import("ghostty_vt");
  const Terminal = vt.Terminal;

  const fmtmod  = @import("ghostty_format");
  const ScreenFormatter = fmtmod.ScreenFormatter;
  ```
- **UNVERIFIED** The root source file each module points at. Best-known guesses,
  to confirm against the tree:
  - `ghostty_vt` root → something like `src/terminal/Terminal.zig` (or a barrel
    `src/terminal.zig` that re-exports `Terminal`). Ghostty's VT engine lives under
    `src/terminal/` (`Terminal.zig` = state + screen; `Parser.zig` = the ANSI/VT
    escape parser; `Screen.zig` = the buffer).
  - `ghostty_format` root → something like `src/format.zig` (or `src/format/`)
    re-exporting `ScreenFormatter`.
  - **Action to verify:** after fetching, run `zig build` with a wrong import and
    read the error path, or `grep -rn "addModule(\"ghostty_vt" ghostty/build.zig` /
    `addModule("ghostty_format"`.

### 2. `ScreenFormatter` API — construction + HTML emission + `content.selection`

**CONFIDENT (shape)** `ScreenFormatter` is Ghostty's formatter that renders a
screen/terminal snapshot to a target format. It is the type used for Ghostty's own
"copy as HTML"/rich-text rendering and screenshot-style export, and is what
term2html/tmux-2html lean on to turn VT state into HTML.

**UNVERIFIED (field/method names — schematic, confirm against source):**
```zig
pub const ScreenFormatter = struct {
    // Likely constructed via an init that binds a Terminal + an options bag:
    pub fn init(
        alloc: std.mem.Allocator,
        t: *Terminal,            // or: screen/cells snapshot
        opts: Options,
    ) ScreenFormatter { ... }

    pub const Options = struct {
        bg: ?Color = null,       // page background color
        fg: ?Color = null,       // default text foreground
        palette: ?Palette = null,// the 16/256-color palette for SGR colors
        font: []const u8 = "...",// CSS font-family
        font_size: ?u32 = null,  // CSS font-size (px)
        // possibly: url, padding, etc.
    };

    // Selection to highlight/copy is passed through a content struct:
    pub const Content = struct {
        selection: ?Selection = null,
        // (possibly: mode, wrap, etc.)
    };

    // Emits HTML to a writer (the method name is a guess — could be format/html/write):
    pub fn format(self: *ScreenFormatter, writer: anytype) !void { ... }
};
```
- **CONFIDENT** The formatter writes HTML incrementally to a `std.io.Writer`
  (rows → spans, mapping SGR foreground/background to inline styles or classes,
  escaping text). The background/foreground/palette/font options map to the
  document's base CSS and to color resolution.
- **UNVERIFIED** Whether `font` is a single family string or a richer font spec,
  whether options are a nested struct or individual `init` params, and whether the
  method is `format`, `html`, or `write`.
  - **Action to verify:** open the formatter source and read the actual `Options`
    struct and the `init`/emit signature. The supervisor is confirming this.

### 3. `Selection` struct — coordinates + rectangle/block flag

**CONFIDENT** Ghostty represents a selection as two coordinate points plus a mode
that distinguishes a contiguous (line/“stream”) selection from a rectangular/block
selection (the Alt-drag / rectangle-select mode). Coordinates are in
column/row space.

**UNVERIFIED (field names — schematic, confirm against source):**
```zig
pub const Selection = struct {
    start: Point(usize),
    end:   Point(usize),
    mode:  Mode,          // the rectangle/block flag is an enum variant, not a bool

    pub const Mode = enum {
        // best-known variant names:
        normal,            // contiguous/stream selection
        rectangle,         // aka block / Alt-select
        line,              // whole-line selection (triple-click)
    };
};
```
- **BEST-KNOWN** Ghostty's point type is a generic `Point` (under something like
  `src/terminal/Point.zig` / `terminal.point`) with `.x` (column) and `.y` (row)
  fields, i.e. `Point(usize)`. Selections are typically normalized internally so
  `start` may not be top-left; look for ordering helpers like `topLeft()` /
  `bottomRight()` or a `sort`/`ordered()` on the selection.
- **UNVERIFIED** Whether the rectangle flag is `mode == .rectangle` or a separate
  `rectangle: bool` field; whether coordinates are `Point(usize)` or `Point(?usize)`
  (nullable for "no selection").
  - **Action to verify:** grep `pub const Selection` in the fetched tree; this is
    the single highest-risk item for a build break if the field names are wrong.

### 4. Declaring ghostty as a `build.zig.zon` dependency (`.url` / `.hash`)

- **CONFIDENT** Standard Zig package-manager syntax. The dependency key name is
  arbitrary (conventionally `ghostty`); `.url` points at a tarball; `.hash` is the
  **multihash (SHA-256)** digest Zig computes over the tarball, formatted as
  `1220…` (`0x12` = sha2-256, `0x20` = 32-byte digest, then ~52 base32 chars).
  ```zig
  .dependencies = .{
      .ghostty = .{
          .url = "https://github.com/ghostty-org/ghostty/archive/<commit-or-tag>.tar.gz",
          .hash = "1220<...DO NOT GUESS — obtain via zig fetch...>",
      },
  },
  ```
- **CONFIDENT** How to obtain the hash (do **not** hand-write it):
  ```sh
  zig fetch --save https://github.com/ghostty-org/ghostty/archive/<commit>.tar.gz
  ```
  or, if you add the `.url` with a placeholder/wrong `.hash` first, Zig prints the
  *expected* hash in the build failure message — copy that into `.hash`.
  `<commit>` should be a full 40-char commit SHA (pin for reproducibility) or a tag.
- **BEST-KNOWN** Fetch URL format is the GitHub source archive:
  `https://github.com/ghostty-org/ghostty/archive/<ref>.tar.gz`. Some Zig setups
  instead use the codeload endpoint
  `https://codeload.github.com/ghostty-org/ghostty/tar.gz/<ref>`; both resolve to
  the same tarball. (There is **no** ghostty package published on a Zig package
  registry as of training — it is consumed directly from the git archive.)
- **CAVEAT** Ghostty's `build.zig` is a large native build (Obj-C on macOS, C++ SIMD
  libs, fontconfig, etc.). Using it purely as a Zig tarball dependency works only
  if the subset you import (`ghostty_vt`, `ghostty_format`) and the build options
  you pass don't require platform GUI toolchain pieces. Pin a known-good commit and
  pass `optimize`/`target` consistently (see §6).

### 5. Transitive C++ SIMD dependencies — simdutf, highway, utfcpp

- **CONFIDENT** Ghostty vendors (does not require system installs of) several C/C++
  libraries and compiles them in `build.zig`. The SIMD-related ones relevant here:
  - **highway** (Google SIMD library) — used for SIMD-accelerated terminal/parser
    hot paths.
  - **simdutf** — fast UTF-8/16/32 validation and transcoding.
  - **utfcpp** (UTF8-CPP) — UTF conversion helpers.
  These live under Ghostty's vendored deps directory (best-known: `vendor/` or
  `deps/`, e.g. `vendor/simdutf`, `vendor/highway`, `vendor/utfcpp` — confirm the
  exact dir in the tree).
- **CONFIDENT** They are built **automatically** by Ghostty's `build.zig` (as
  `addCSourceFile`/`StaticLibrary` steps) whenever the SIMD code path is enabled.
  A downstream project does **not** add them separately — they come in through the
  `ghostty` dependency.
- **UNVERIFIED** The exact build-option flag to disable SIMD. The task names
  `-Dsimd=false`; this is plausible (Ghostty exposes `-D…` build options) but I
  could not confirm the literal flag name. Candidates to grep in `build.zig`:
  `-Dsimd=false`, `-Dsimd-…=false`, or a combined `-Doptimize`/capability option.
  - **Action to verify:** `grep -nE "b\.option|simd" ghostty/build.zig` and read
    the registered option names; pass the matching `-D<name>=false` to disable
    SIMD (and thereby drop the problematic C++ static libs).

### 6. Known Zig Debug-mode linker bug (`R_X86_64_PC64`) with bundled C++ SIMD libs

- **CONFIDENT (nature)** `R_X86_64_PC64` is a 64-bit PC-relative relocation. It is
  produced by C/C++ object code that uses absolute addressing patterns the Zig
  (stage2) linker in **Debug** mode cannot always satisfy when linking **static,
  bundled** C++ SIMD objects (highway/simdutf emit such relocations in places).
  The failure looks like:
  ```
  error: unsupported relocation type: R_X86_64_PC64
  ```
  during the link step of the Debug build.
- **CONFIDENT (workarounds)**, in order of practicality:
  1. **Build the ghostty dependency (and your exe) in a release mode** —
     `-Doptimize=ReleaseSafe` (or `ReleaseFast`). Release object codegen +
     the release linker path avoid the relocation, and this is the common fix.
  2. **Disable the SIMD path** with the flag from §5 (e.g. `-Dsimd=false`),
     which removes the offending C++ SIMD static libs from the link entirely.
  3. **Pin a Zig version** where the stage2/x86_64 linker handles `R_X86_64_PC64`
     (track the upstream `ziglang/zig` issue for PC64 support / "unsupported
     relocation" in Debug with static C++). Matching the Zig version Ghostty's
     `build.zig.zon` `.minimum_zig_version` expects avoids regressions here.
  4. (Less relevant for a pure HTML tool) link system copies of highway/simdutf
     instead of the vendored ones if Ghostty exposes that option.
- **CONFIDENT (why it matters for tmux-2html)** term2html/tmux-2html only need the
  VT **parsing** + **formatting** logic, not rendering. Disabling SIMD or building
  release both let the link succeed; the project convention (per the task) is to
  not ship a Debug build against the bundled SIMD libs.

## Sources

- Kept:
  - `github.com/ghostty-org/ghostty` (upstream repo) — authoritative for `build.zig`,
    `build.zig.zon`, `src/terminal/` (VT engine), and the `ghostty_format` /
    `ghostty_vt` module definitions. **Path names are best-known, not line-verified.**
  - `include/ghostty.h` — the C ABI surface (confirms Ghostty's terminal model and
    that a Zig-native `Terminal`/formatter layer sits beneath it).
  - Zig package-manager docs — `.url`/`.hash` semantics, `zig fetch` workflow,
    multihash format (`1220…`).
  - Zig linker error catalog — `R_X86_64_PC64` / "unsupported relocation" in Debug
    with static C++ objects.
- Dropped:
  - None fetched live (no web access at runtime). Any blog/Reddit commentary on
    Ghostty internals was excluded as non-authoritative.

## Gaps

The following must be verified against the **fetched** ghostty source before the
findings are trusted for implementation (the supervisor is doing this in parallel):

1. **Exact module wiring** — confirm `ghostty_dep.module("ghostty_vt")` and
   `module("ghostty_format")` are the registered names, and find each module's root
   source file. `grep -n 'addModule(' ghostty/build.zig`.
2. **`Selection` field names** (highest build-break risk) — exact names of start/end
   points and whether the block flag is `mode == .rectangle` or a `rectangle: bool`.
   Confirm the `Point` type used (`Point(usize)` vs `Point(?usize)`; `.x`/`.y` vs
   `.col`/`.row`).
3. **`ScreenFormatter` signature** — constructor args, the `Options` struct field
   names (`bg`/`fg`/`palette`/`font`/`font_size`?), the `Content.selection` path,
   and the emit method name (`format` vs `html` vs `write`).
4. **The SIMD-disable flag** — confirm `-Dsimd=false` is the literal option name
   in `build.zig` (grep `b.option`).
5. **The `.hash`** — must be computed, never guessed: `zig fetch --save <url>`.
6. **Known-good commit + Zig version** — pin a ghostty commit and a Zig version
   that matches `build.zig.zon`'s `minimum_zig_version` and that resolves the
   `R_X86_64_PC64` Debug-link issue (or just build release).

## Suggested next steps

- Once ghostty is fetched, run targeted greps for the four UNVERIFIED signatures
  above and paste the real declarations into this brief.
- Record the exact `zig fetch`-produced `.hash` and the pinned commit in the
  project's `build.zig.zon`.
- Decide SIMD policy (disable vs release-build) and lock the `optimize` mode so the
  Debug linker defect never surfaces in CI.
