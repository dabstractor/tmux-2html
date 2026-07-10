# Shipped-Facts Sheet (README source of truth)

All evidence is from the actual shipped source in `/home/dustin/projects/tmux-2html`.
Line numbers are 1-indexed. Every value below is the EXACT string/value in code.

---

## 1. VERSION — what `tmux-2html --version` prints

Exact printed string: **`tmux-2html 0.1.0`**

Evidence:
- `build.zig.zon` line 3: `.version = "0.1.0",`
- `build.zig` line 2: `const version_string = @import("build.zig.zon").version;`
- `build.zig` line 15: `options.addOption([]const u8, "version", version_string);` (bakes the `.version` into the `build_options` module)
- `src/main.zig` line 9: `const version_string = build_options.version;`
- `src/main.zig` `printVersion` (format string): `std.fmt.bufPrint(&buf, "tmux-2html {s}\n", .{version_string})` → emits `tmux-2html 0.1.0\n`
- `scripts/ensure_binary.sh` baked constant: `EXPECTED_VERSION="0.1.0"` (comment says it MUST match build.zig.zon `.version`). Version-match check compares against the literal `tmux-2html $EXPECTED_VERSION`.

---

## 2. SUBCOMMANDS — exact names + one-line descriptions from `--help`

Dispatch is in `src/main.zig` `dispatch()` (the `if (std.mem.eql(u8, name, "<x>"))` chain).
Help text is the `usage_text` multi-line literal in `src/main.zig` (lines ~131-151).

The 4 shipped subcommands:
| name | exact one-line description (as printed in `--help`) |
|---|---|
| `render` | `Read ANSI from stdin, write HTML (core renderer).` |
| `pane` | `Capture a tmux pane and convert it to HTML.` |
| `region` | `Interactive copy-mode overlay: select a region, render it.` |
| `sync-palette` | `Query the terminal palette and cache it.` |

Exact lines from `usage_text` (verbatim):
```
Usage: tmux-2html <subcommand> [options]
       tmux-2html --version | --help

Convert tmux pane output to standalone HTML.

Subcommands:
  render        Read ANSI from stdin, write HTML (core renderer).
  pane          Capture a tmux pane and convert it to HTML.
  region        Interactive copy-mode overlay: select a region, render it.
  sync-palette  Query the terminal palette and cache it.

Common options:
  --version     Print the version and exit.
  --help        Show this help.

Exit codes: 0 success, 1 usage/runtime error, 2 capture/target error.
```

Exact `Usage:` line: `Usage: tmux-2html <subcommand> [options]`
Exact `--version` / `--help` line: `       tmux-2html --version | --help`
Note: there is NO top-level `tmux-2html` with no args — `main.zig run()` prints usage and returns 1 when no token is given. Global `--version` prints the version (exit 0); `--help` prints help (exit 0); any other flag in command position → exit 1.

---

## 3. FLAGS per subcommand — confirmed against `src/cli.zig`

User's list is **100% accurate**. Every flag exists; no flag is missing; no spurious flag.
All option structs and parsers are in `src/cli.zig`.

### `render` — `RenderOpts` (cli.zig lines 64-73), parser `parseRender` (cli.zig lines 155-186)
| flag | type | default |
|---|---|---|
| `--cols` | `?u16` | `null` |
| `--rows` | `?u16` | `null` |
| `--font` | `[]const u8` | `"monospace"` |
| `--palette` | `PaletteMode {default\|cached\|live}` | `.cached` |
| `--output` | `?[]const u8` | `null` |
| `--open` | `bool` | `false` |
| `--selection` | `?SelectionCoords` (`X1,Y1,X2,Y2[,rect]`, rect=1→block) | `null` |

User's list: ALL CONFIRMED. None missing.

### `pane` — `PaneOpts` (cli.zig lines 77-86), parser `parsePane` (cli.zig lines 188-216)
| flag | type | default |
|---|---|---|
| `--target` | `?[]const u8` | `null` (prod wrapper falls back to `$TMUX_PANE`) |
| `--visible` | `bool` | `false` (but visible is the default CAPTURE mode when `--full` is absent) |
| `--full` | `bool` | `false` |
| `--history` | `u32` | `50000` |
| `--font` | `[]const u8` | `"monospace"` |
| `--output` | `?[]const u8` | `null` |
| `--open` | `bool` | `false` |

Mutual exclusivity: `--visible` and `--full` together → `error.MutualExclusivity` → exit 1 (cli.zig line 214).
User's list: ALL CONFIRMED. None missing.

### `region` — `RegionOpts` (cli.zig lines 89-94), parser `parseRegion` (cli.zig lines 218-240)
| flag | type | default |
|---|---|---|
| `--target` | `?[]const u8` | `null` (fallback `$TMUX_PANE`) |
| `--font` | `[]const u8` | `"monospace"` |
| `--output` | `?[]const u8` | `null` |
| `--open` | `bool` | `false` |

User's list: ALL CONFIRMED. None missing. (parseRegion explicitly REJECTS pane-only flags like `--full` → `error.UnknownFlag`, per test `parseRegion: rejects pane-only flags`.)

### `sync-palette` — `SyncPaletteOpts` (cli.zig lines 97-100), parser `parseSyncPalette` (cli.zig lines 242-268)
| flag | type | default |
|---|---|---|
| `--from` | `PaletteSource { tty \| file PATH }` | `.tty` (`--from file PATH` takes the path as the next value) |
| `--force` | `bool` | `false` |

User's list: ALL CONFIRMED. None missing.

### Per-subcommand `--help`
Each subcommand also accepts `--help` (detected by `hasHelpFlag`, cli.zig lines ~271-274) and prints its own help block (`render_help`, `pane_help`, `region_help`, `sync_palette_help`, cli.zig lines ~284-345), then returns 0.

---

## 4. KEYBINDS — `tmux-2html.tmux`

All bindings are gated on `[ "$binary_ready" = 1 ]`.

`read_opt` defaults (§3 of the script):
```sh
full_key=$(read_opt @tmux-2html-full-key O)
region_key=$(read_opt @tmux-2html-region-key C-o)
visible_key=$(read_opt @tmux-2html-visible-key "")
```

Bind-key lines (verbatim, quoting preserved):
- **prefix O → `pane --full`** (the full-key binding):
```sh
[ "$binary_ready" = 1 ] && tmux bind-key "$full_key" run-shell \
    "out=\$(\"$TMUX_2HTML_BIN/tmux-2html\" pane --full --target '#{pane_id}' 2>/dev/null); tmux display-message \"tmux-2html: \$out\""
```
- **prefix <visible-key> → `pane --visible`** — ONLY bound if `visible_key` is non-empty:
```sh
if [ -n "$visible_key" ]; then
    [ "$binary_ready" = 1 ] && tmux bind-key "$visible_key" run-shell \
        "out=\$(\"$TMUX_2HTML_BIN/tmux-2html\" pane --visible --target '#{pane_id}' 2>/dev/null); tmux display-message \"tmux-2html: \$out\""
fi
```
  → Since `visible_key` default is empty, the visible-only capture is **UNBOUND by default** until the user sets `@tmux-2html-visible-key`. CONFIRMED.
- **prefix C-o → region popup** (display-popup):
```sh
[ "$binary_ready" = 1 ] && tmux bind-key "$region_key" run-shell \
    "last=\"$TMUX_2HTML_BIN/.last-output\"; rm -f \"\$last\"; tmux display-popup -E -w 100% -h 100% \"$TMUX_2HTML_BIN/tmux-2html region --target '#{pane_id}'\"; if [ -f \"\$last\" ]; then out=\$(cat \"\$last\"); tmux display-message \"tmux-2html: wrote \$out\"; fi"
```
  → Confirms prefix C-o opens a full-screen (`-w 100% -h 100%`) `display-popup` running `region --target '#{pane_id}'`, then reads the `.last-output` sidecar to flash `tmux-2html: wrote <path>`.

All four claims in the task (O→full, C-o→region popup, visible default empty/unbound, quoted read_opt defaults) are CONFIRMED.

---

## 5. OPTIONS — `@tmux-2html-*` defaults as coded (`tmux-2html.tmux` §3 + §1)

| option | literal default as coded |
|---|---|
| `@tmux-2html-full-key` | `O` |
| `@tmux-2html-region-key` | `C-o` |
| `@tmux-2html-visible-key` | `` (empty string ⇒ unbound) |
| `@tmux-2html-open` | `on` |
| `@tmux-2html-font` | `monospace` |
| `@tmux-2html-history-limit` | `50000` |
| `@tmux-2html-output-dir` | `` (empty). When empty it resolves to `${XDG_DATA_HOME:-~/.local/share}/tmux-2html`, where XDG_DATA_HOME is honored ONLY if it is set AND non-empty AND absolute (rule: `[ "${XDG_DATA_HOME#/}" != "$XDG_DATA_HOME" ]`). |
| `@tmux-2html-binary-dir` | `$TMUX_2HTML_BIN`, which itself folds to (§1 precedence): env `$TMUX_2HTML_BIN` → the `@tmux-2html-binary-dir` option → `"$plugin_dir/bin"` default. |

Note on `output-dir` default logic (verbatim):
```sh
output_dir=$(read_opt @tmux-2html-output-dir "")
if [ -z "$output_dir" ]; then
    data_home="$HOME/.local/share"
    if [ -n "${XDG_DATA_HOME:-}" ] && [ -n "$XDG_DATA_HOME" ] \
        && [ "${XDG_DATA_HOME#/}" != "$XDG_DATA_HOME" ]; then
        data_home=$XDG_DATA_HOME
    fi
    output_dir="$data_home/tmux-2html"
fi
```

(There are exactly 8 `@tmux-2html-*` options: full-key, region-key, visible-key, open, font, history-limit, output-dir, binary-dir.)

---

## 6. `ensure_binary.sh` — exact order of binary acquisition

From `scripts/ensure_binary.sh`. The header comment states the order; the code below implements it. EXACT order:

1. **Version-match fast-path**: if an executable binary already exists at `$bin`, run `--version`; if it prints exactly `tmux-2html 0.1.0` (== `EXPECTED_VERSION`), `exit 0`. (script lines: `[ -x "$bin" ]` → `cur=$("$bin" --version 2>/dev/null)` → `if [ "$cur" = "tmux-2html $EXPECTED_VERSION" ]; then exit 0; fi`)
2. **Build from source (if Zig present)**: `if command -v zig >/dev/null 2>&1; then ... ( cd "$plugin_dir" && zig build --release=fast --prefix "$tmp" install ) && [ -x "$tmp/bin/tmux-2html" ] && mv -f "$tmp/bin/tmux-2html" "$bin" → exit 0`. Builds into a temp dir INSIDE `bin_dir` (same FS ⇒ atomic rename). On any build/artifact/mv failure it FALLS THROUGH to download (does not abort — `set -eu` but the whole pipeline is the condition of an `if`).
3. **Download** (if `scripts/download.sh` is executable): `if [ -x "$plugin_dir/scripts/download.sh" ]; then if sh "$plugin_dir/scripts/download.sh" "$bin_dir" 2>/dev/null; then [ -x "$bin" ] && exit 0; fi; fi`. ⚠️ `download.sh` DOES exist and is executable (9187 bytes, `-rwxr-xr-x` in `scripts/`). So this step IS active today — see Risks.
4. **Fail**: `echo "tmux-2html: ensure_binary.sh: could not obtain binary (version/build/download all failed)" >&2; exit 1`.

**Build-by-default vs download-by-default answer:** It is **BUILD-BY-DEFAULT** for users who have Zig installed (step 2 runs before step 3). It is **DOWNLOAD-BY-DEFAULT** ONLY for users without Zig (or whose build fails). So: not "download-by-default for users without Zig, build-by-default" as an either/or — it is build-first-then-download-fallback, gated on Zig presence.

Atomic-rename guarantee: temp dir is created inside `bin_dir` via `mktemp -d "$bin_dir/.buildXXXXXX"`; trap cleans up on any exit; `mv -f` is the final rename.

---

## 7. EXIT CODES

Documented in `usage_text` (src/main.zig): `Exit codes: 0 success, 1 usage/runtime error, 2 capture/target error.`

Actual shipped behavior (0/1/2):
- `0` — success: `--version`, `--help`, successful render/pane/region/sync-palette, region confirm (renders + sidecar + optional --open).
- `1` — usage/runtime error: no subcommand given; unknown top-level option; unknown subcommand; `error.NotImplemented` (currently unused — all 4 bodies are implemented); any per-subcommand parse error (MissingValue / UnknownFlag / InvalidNumber / BadPaletteMode / BadSelection / BadPaletteSource / MutualExclusivity); region `quit` (cancel, no output); region confirm with empty selection; region render/path/write failures; cache-write failures in sync-palette; `--from file` missing/malformed.
- `2` — capture/target error: `pane`/`region` capture or target-resolution failures (bad pane id / tmux unavailable / option-query failure); `render` size errors (`render.zig:472 return 2; // size error`, e.g. no tty and no `--cols`); `pane`/`region` when `$TMUX_PANE` unset and no `--target`; sync-palette tty query failure (no controlling tty / terminal unresponsive).

⚠️ Minor doc inconsistency to flag (NOT a blocker for the README, but worth knowing): the per-subcommand `render_help` text says only `Exit codes: 0 success, 1 usage/runtime error.` — omitting `2` — but `render.zig` actually returns `2` on size errors. The authoritative top-level `usage_text` correctly lists 0/1/2. For the README, use 0/1/2.

---

## Flags/claims in the task list — verification matrix

All confirm/deny requests from the task:
- render: --cols ✓, --rows ✓, --font ✓, --palette ✓, --output ✓, --open ✓, --selection ✓ — ALL EXIST.
- pane: --target ✓, --visible ✓, --full ✓, --history ✓, --font ✓, --output ✓, --open ✓ — ALL EXIST.
- region: --target ✓, --font ✓, --output ✓, --open ✓ — ALL EXIST.
- sync-palette: --from ✓, --force ✓ — ALL EXIST.
- NO flag in the user's list is spurious. NO flag was missed.

Keybind claims:
- prefix O → `pane --full` — CONFIRMED.
- prefix C-o → region popup (`display-popup -E -w 100% -h 100%`) — CONFIRMED.
- visible key default empty/unbound — CONFIRMED (`visible_key=$(read_opt @tmux-2html-visible-key "")`, binding guarded by `if [ -n "$visible_key" ]`).

---

## Risks / things the README writer must NOT over-claim

1. **`region` is FULLY implemented, not a stub.** `src/region.zig` confirm arm (lines ~426-490) renders the selection, writes the HTML atomically, writes the `.last-output` sidecar, optionally `--open`s, and returns `0`. The stale comments in `src/main.zig` ("region currently returns NotImplemented/exit 1, so until P3 the popup opens then closes and shows nothing — inert but correct") and in `src/region.zig` ("Confirm => exit 1 (S1 STUB; P3.M3.T1.S2...)") are OBSOLETE — the confirm-render flow is done. Do NOT claim region is inert/stubbed.
2. **`download.sh` exists and is executable.** `scripts/ensure_binary.sh` step 3 IS reachable today. The inline comment in `ensure_binary.sh` ("download.sh is P2.M3.T1.S2 (NOT YET DONE)") is STALE. Do NOT claim "download not yet available."
3. **`render_help` omits exit code 2** (see §7). Use the top-level 0/1/2 statement for the README.
4. **Pane `--visible` default nuance:** the struct default is `false`, but visible capture is the DEFAULT mode when `--full` is absent (main.zig `panePrepare`: `const mode = if (opts.full) .full else .visible;`). The `pane_help` text documents this: `--visible  only the visible rows (default)`.
5. All 4 subcommands accept their own `--help` (in addition to the top-level `--help`/`--version`).
