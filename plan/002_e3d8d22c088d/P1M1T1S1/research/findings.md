# Research Findings — P1.M1.T1.S1 (--title / --lang flags in cli.zig)

> All values below were verified by reading the live source tree (2026-07-10)
> and running the real Zig 0.15.2 toolchain. The contract's line numbers were
> confirmed exact; one contract mislabel (help-text file) was found and corrected.

## 1. Exact anchors in src/cli.zig (verified line numbers, current HEAD)

- `RenderOpts`  struct  → cli.zig:59   (fields cols/rows/font/palette_mode/output/open/selection)
- `PaneOpts`    struct  → cli.zig:70   (target/visible/full/history/font/output/open)
- `RegionOpts`  struct  → cli.zig:81   (target/font/output/open)
- `SyncPaletteOpts`     → cli.zig:89   (DO NOT TOUCH — must keep rejecting --title/--lang)
- `parseRender`         → cli.zig:153  (flag-chain `else { return error.UnknownFlag; }` at :175)
- `parsePane`           → cli.zig:184  (flag-chain else at :206)
- `parseRegion`         → cli.zig:216  (flag-chain else at :232)
- `parseSyncPalette`    → cli.zig:241  (flag-chain else at :261 — must still UnknownFlag on --title/--lang)
- `requireValue` helper → cli.zig:~122 (the mirror target for the new branches)

NOTE: line numbers shift as fields are added. Reference by STRUCT/FUNCTION NAME
in the PRP, not raw line numbers. The insertion point is the flag-chain `else`
INSIDE the `.flag => |flag| { ... }` arm — NOT the switch-level
`.arg, .unexpected_value => return error.UnknownFlag` (leave that alone).

## 2. The exact mirror pattern (the existing `--font` branch)

```zig
} else if (flag.isLong("font")) {
    opts.font = try requireValue(&parser);
}
```
New branches (drop into the existing `if/else if` chain, just before its `else`):
```zig
} else if (flag.isLong("title")) {
    opts.title = try requireValue(&parser);
} else if (flag.isLong("lang")) {
    opts.lang = try requireValue(&parser);
}
```

## 3. CONTRACT MISLABEL FOUND — help text is in cli.zig, NOT main.zig

The item contract says: "Update the per-subcommand --help usage text in
**src/main.zig** (the render/pane/region usage blocks)." This is WRONG about the
file:
- main.zig has ONE help string: `usage_text` (main.zig:134) — the TOP-LEVEL
  `tmux-2html --help`. It lists subcommands by one-line summary ONLY; it does NOT
  list per-subcommand flags like `--font`. It needs NO change for this task.
- The per-subcommand `--help` text that DOES list flags (incl. `--font FAMILY`)
  lives in **cli.zig** as the `render_help` / `pane_help` / `region_help` /
  `sync_palette_help` string constants (cli.zig:~284/~301/~321/~331).
→ The PRP must direct the implementer to edit `render_help`/`pane_help`/
  `region_help` in **cli.zig**, and explicitly NOT touch `sync_palette_help`
  (sync-palette emits no HTML) and NOT touch main.zig's top-level `usage_text`.

## 4. CRITICAL validation gotcha — tests MUST run in ReleaseFast

`zig build test` (default Debug) FAILS with a known Zig 0.15.2 linker bug:
```
error: fatal linker error: unhandled relocation type R_X86_64_PC64 ...
  note: in .../crt1.o:.sframe   /   .../libc_nonshared.a(pthread_atfork...)
```
This is NOT a test failure — it is the bundled-C++-SIMD Debug-linker bug
documented in `plan/001.../architecture/findings_and_corrections.md §4` and
PRD §15. The tests run fine in optimized mode. Verified working command:
```
zig build test -Doptimize=ReleaseFast      # EXIT 0 on baseline (and --release=fast too)
```
If the PRP said plain `zig build test`, the implementer would see a linker error
and wrongly conclude their code broke it.

## 5. Backward-compatibility SAFETY of adding defaulted fields

Adding `title: ?[]const u8 = null` / `lang: ?[]const u8 = null` (with defaults)
to the three Opts structs is fully safe — confirmed by grepping every construction
site. ALL literals use default (`.{}`) or PARTIAL named-field init that relies on
defaults for unspecified fields, e.g.:
- cli.zig parsers: `var opts = RenderOpts{};` / `PaneOpts{}` / `RegionOpts{}`
- main.zig tests: `cli.PaneOpts{ .target = "%5", .visible = true }` (partial)
- region.zig tests: `cli.RegionOpts{ .target = "%5" }` (partial)
No full-field literal exists anywhere → new defaulted fields break nothing.

## 6. Scope boundaries (out of scope for S1 — deferred to siblings)

- S2: `resolveLang` / `langFromEnv` locale→BCP-47 logic (render.zig).
- S3: render.zig `run` wiring `opts.title`/`opts.lang` into DocumentOpts.
- S4: pane (main.zig) + region (region.zig) honoring the flags.
- At the PARSE layer: `--lang` stores ANY string value (no BCP-47 validation here
  — that is resolveLang's job in S2). `--title` stores any string (HTML escaping
  already done by render.zig writeDocument/writeEscaped, not cli).
- `DocumentOpts` already has `lang: []const u8 = "en"` (render.zig:187) — callers
  just never set it. S1 does not touch render.zig at all.

## 7. Default-unchanged invariant (must hold after S1)

When `opts.title == null` and `opts.lang == null`, parse output + all downstream
behavior is byte-identical to today. The new fields merely become populated when
the user passes the flags. Tests must assert the null defaults explicitly.

## 8. The `requireValue` gotcha (reuse, don't reimplement)

`requireValue` treats a value that looks like another flag (len>1, leading `-`)
as `error.MissingValue` (so `--title --lang x` ⇒ `--title` errors MissingValue,
it does NOT swallow `--lang`). A lone `-` (stdin) is allowed. The new branches
call `requireValue` verbatim — no new helper needed. Test this negative case.

## 9. Test command summary (verified)
```
zig build test -Doptimize=ReleaseFast     # PRIMARY gate (ReleaseFast mandatory)
```
