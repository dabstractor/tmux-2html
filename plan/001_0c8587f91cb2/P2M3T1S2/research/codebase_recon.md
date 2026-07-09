# Codebase Recon — `scripts/download.sh` (P2.M3.T1.S2)

Scope: the sibling of `scripts/ensure_binary.sh`. Every fact below is quoted from the
repo (not artifacts) with file:line refs. ⚠️ One discrepancy surfaces (Q6 + Q4): the
**GitHub repo name is `tmux-ansi2html`, not `tmux-2html`** — this changes the release
URL `download.sh` must construct.

---

## Q1 — ensure_binary.sh → download.sh handshake

`scripts/ensure_binary.sh` step 3 (lines 78–86) invokes download.sh:

```sh
# ---- step 3: download.sh (latest release; SHA256-verified) → done -----------   L78
if [ -x "$plugin_dir/scripts/download.sh" ]; then                                # L83
    if sh "$plugin_dir/scripts/download.sh" "$bin_dir" 2>/dev/null; then         # L84
        [ -x "$bin" ] && exit 0                                                  # L85
    fi
fi
```

- **Argument passed (`$1`): the bin DIR** (`"$bin_dir"`), where `bin="$bin_dir/tmux-2html"` (L19). NOT the full binary path. (`bin_dir=${1:-${TMUX_2HTML_BIN:-}}` at L17.)
- **Acceptance of result:** `if sh … ; then [ -x "$bin" ] && exit 0; fi` — download.sh exits 0 AND places an executable at `$bin_dir/tmux-2html`; ensure_binary.sh re-checks executability itself (it does NOT trust download.sh's exit alone; the `[ -x "$bin" ]` is an AND-gate).
- **stderr suppressed:** YES — `2>/dev/null` on the `sh … download.sh` invocation (L84). So download.sh's stderr is **discarded by the caller**. On any non-zero download exit OR a missing executable, it **falls through** to step 4 (L89–91): `echo "…could not obtain binary (version/build/download all failed)" >&2; exit 1`.
- ensure_binary.sh passes **NO version** to download.sh and does **not re-verify** the downloaded version (PRP S1 Anti-Pattern; S2 "owns tarball version+SHA").

**Implication for S2:** download.sh's contract is `(bin_dir) -> places executable $bin_dir/tmux-2html and exits 0 | exits non-zero`. stderr is invisible to the caller (only matters for human/CI debugging). download.sh must be the sole owner of version + SHA256 correctness; it should do atomic install too (mirror S1's same-FS temp + rename).

---

## Q2 — tmux-2html.tmux §2: how ensure_binary.sh is called; `binary_ready` on failure

`tmux-2html.tmux` §2 (lines 41–57):

```sh
binary_ready=1                                                                # L41
if [ -x "$TMUX_2HTML_BIN/tmux-2html" ]; then                                  # L43
    : # common case: binary present + executable; nothing to do.
elif [ -f "$plugin_dir/scripts/ensure_binary.sh" ]; then                      # L44
    # ensure_binary.sh owns the version-match vs build.zig.zon + build/download.
    # We pass "$TMUX_2HTML_BIN" as $1 (courtesy; it may also read the env we export).
    if ! sh "$plugin_dir/scripts/ensure_binary.sh" "$TMUX_2HTML_BIN" ; then    # L47
        tmux display-message "tmux-2html: install failed (see README)" 2>/dev/null  # L48
        binary_ready=0                                                        # L49
    fi
else
    tmux display-message "tmux-2html: installer missing (incomplete install)" 2>/dev/null  # L53
    binary_ready=0                                                            # L54
fi
export binary_ready                                                           # L57
```

- `ensure_binary.sh` is invoked **synchronously** via `sh` (NOT `run-shell`) inside `if ! …` so `$?` is decidable (run-shell is async). `$1 = "$TMUX_2HTML_BIN"` = the bin DIR (`$plugin_dir/bin`).
- **On failure:** the exact display-message is `tmux display-message "tmux-2html: install failed (see README)"` (L48), then `binary_ready=0`. `binary_ready` gates **all** bindings (full L138, visible L144, region L183) and the palette auto-sync popup (L216) — when `0`, nothing is bound. The loader never calls `tmux` from ensure_binary.sh (tmux-agnostic contract).

---

## Q3 — Version + binary name + `--version` format

`build.zig.zon` (lines 3–4):
```zig
.version = "0.1.0",
.minimum_zig_version = "0.15.2",
```

`build.zig` executable `.name` (line 17):
```zig
const exe = b.addExecutable(.{
    .name = "tmux-2html",
```

`src/main.zig` `printVersion` (lines 108–112):
```zig
fn printVersion(out: std.fs.File) !void {
    var buf: [64]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "tmux-2html {s}\n", .{version_string});
    try out.writeAll(s);
}
```
`version_string` = `@import("build.zig.zon").version` (build.zig:2), baked via `build_options` (build.zig:18).

**Empirically confirmed** (this session):
```
$ zig-out/bin/tmux-2html --version
tmux-2html 0.1.0
```
Format = `tmux-2html <version>\n` ⇒ **`tmux-2html 0.1.0`**. (Bare binary is named `tmux-2html` inside the tarball — relevant for SHA256 + extraction.)

---

## Q4 — GitHub Actions release matrix (external_deps.md §3)

Source: `plan/001_0c8587f91cb2/architecture/external_deps.md` §3 (lines 90–132).

### (a) The 4 matrix `name` values (lines 108–111)
```yaml
          - { os: ubuntu-latest, target: x86_64-linux-gnu,  name: tmux-2html-linux-x86_64,  flags: "" }
          - { os: ubuntu-latest, target: aarch64-linux-gnu, name: tmux-2html-linux-aarch64, flags: "-Dsimd=false" }
          - { os: macos-latest,  target: x86_64-macos,      name: tmux-2html-macos-x86_64,  flags: "-Dsimd=false" }
          - { os: macos-latest,  target: aarch64-macos,     name: tmux-2html-macos-arm64,   flags: "" }
```
- **Asset filename pattern: `${{ matrix.name }}.tar.xz`** (i.e. `tmux-2html-<triple>.tar.xz`), where `<triple>` is one of: `linux-x86_64`, `linux-aarch64`, `macos-x86_64`, `macos-arm64`.
- ⚠️ The `name`/asset uses the hyphenated prefix **`tmux-2html`** (the binary/product name), NOT `tmux-ansi2html`. Only the GitHub **repo** name (URL component) is `tmux-ansi2html` (see Q6).

### (b) What SHA256SUMS.txt contains — BARE binary, one per matrix job

The packaging `run:` step verbatim (lines 119–122):
```yaml
      - run: |   # tmux-2html ADDS sha256sums + tar.xz (term2html used tar.gz only)
          mkdir -p dist && cp zig-out/bin/tmux-2html dist/
          (cd dist && sha256sum tmux-2html > ../SHA256SUMS.txt)
          tar -C dist -cJf ${{ matrix.name }}.tar.xz tmux-2html
```
- The hash is of the **BARE binary `tmux-2html`**, NOT the tarball (`sha256sum tmux-2html` runs on the file in `dist/`, and the tarball is created *after* — and never hashed).
- **One SHA256SUMS.txt per matrix job (4 total)**, NOT a single consolidated file. Each matrix job's `run:` writes `SHA256SUMS.txt` (content = `<hash>  tmux-2html`), and `upload-artifact@v4` (L124) uploads it under that job's artifact dir. The release job (L125–132) downloads all artifacts into `dist/` and globs `dist/**/SHA256SUMS.txt` (L132) — i.e. 4 separate files, each living in its job's subdirectory under `dist/`.

Release draft wiring (lines 126–132):
```yaml
  release_draft:
    needs: build
    if: startsWith(github.ref, 'refs/tags/')
    runs-on: ubuntu-latest
    steps:
      - uses: actions/download-artifact@v4
        with: { path: dist }
      - uses: softprops/action-gh-release@v2
        with: { draft: true, files: "dist/**/*.tar.xz\ndist/**/SHA256SUMS.txt" }
```

**Implication for download.sh:** the bare-binary name inside every tarball is `tmux-2html` (top-level entry of the tar — `tar -cJf … tmux-2html` with `-C dist`). The hash line is in the form `<64-hex>  tmux-2html` (sha256sum default = two-spaces + filename). The SHA256SUMS file is co-located with the tarball (same artifact subdir ⇒ same release asset dir after upload); download.sh should fetch BOTH `${name}.tar.xz` and the matching `SHA256SUMS.txt` for the detected platform, verify `sha256sum -c` (or compute + compare) against the **extracted bare binary**, then install.

---

## Q5 — Sibling PRPs' Level-2 shell testing pattern

Both sibling PRPs use a **self-contained bash/sh stub harness with fake binaries on PATH** — NO external test framework. Pattern (quote from `P2M3T1S1/PRP.md` Level 2, "a self-contained harness"):

> A self-contained harness: a fake `zig` (writes a dummy exe to $tmp/bin/tmux-2html on `build`), a fake pre-existing binary (matching/mismatching --version), a staged download.sh, and PATH manipulation. Asserts every branch + atomicity + temp cleanup.

Concretely (`P2M3T1S1/PRP.md` Level 2, the staged-`download.sh` test):
```bash
work=$(mktemp -d); repo=$(pwd); fakebin="$work/fakebin"; mkdir -p "$fakebin"
# fake tool stubbed on PATH:
cat > "$fakebin/zig" <<'EOF'
#!/usr/bin/env sh
…   # writes $prefix/bin/tmux-2html on `build … --prefix <dir> install`
EOF
chmod +x "$fakebin/zig"
# staged sibling:
cat > "$repo/scripts/download.sh" <<'EOF'
#!/usr/bin/env sh
printf 'download.sh got arg=%s\n' "$1" > "$1/.download-arg"
printf '#!/usr/bin/env sh\necho "tmux-2html 0.1.0"\n' > "$1/tmux-2html"; chmod +x "$1/tmux-2html"
EOF
chmod +x "$repo/scripts/download.sh"
out=$(PATH="/usr/bin:/bin" sh "$repo/scripts/ensure_binary.sh" "$binE" 2>"$work/errE"); rc=$?
[ "$rc" = 0 ] && echo "PASS …"
rm -f "$repo/scripts/download.sh"          # CLEAN UP the staged sibling
rm -rf "$work"
```

`P2M2T1S1/PRP.md` Level 2 uses the **same shape**: a fake `tmux` stub on PATH returning canned `show-option` values, + `TMUX_2HTML_DEBUG=<file>` seam to assert resolved vars. Each branch is an isolated `mktemp -d` work dir + `PASS`/`FAIL` echo assertions; `rm -rf "$work"` at the end. **Mirror this for download.sh:** a fake `curl`/`tar`/`sha256sum` (or a fake HTTP server / staged files), a staged "release dir" mimicking the GH layout (`${name}.tar.xz` + `SHA256SUMS.txt`), PATH control, and `PASS`/`FAIL` asserts — plus a Level 3 integration that hits a *real* (or self-built local) tarball.

---

## Q6 — Repo name (CRITICAL discrepancy)

```
$ git -C /home/dustin/projects/tmux-2html config --get remote.origin.url
git@github.com:dabstractor/tmux-ansi2html.git
```
- The GitHub **repo** is **`tmux-ansi2html`** (owner `dabstractor`), NOT `tmux-2html`.
- Everything *inside* the repo (binary name `tmux-2html`, matrix `name` prefix `tmux-2html-…`, `--version` output `tmux-2html …`, loader option prefix `@tmux-2html-*`) uses **`tmux-2html`**.
- **download.sh implication:** the release download URL must use the repo name `tmux-ansi2html`. The GitHub "latest release" shortcut download pattern is:
  `https://github.com/dabstractor/tmux-ansi2html/releases/latest/download/<asset>`
  If download.sh hardcodes `tmux-2html` as the repo path segment, **every release fetch will 404.** (The asset filenames themselves remain `tmux-2html-<triple>.tar.xz` and `SHA256SUMS.txt`, per Q4.) Recommend baking a `REPO="dabstractor/tmux-ansi2html"` constant (or deriving owner/repo from the install source) and document the repo≠product-name split in the script header.

---

## Summary of load-bearing facts for the download.sh PRP

| Concern | Value | Source |
|---|---|---|
| Caller arg `$1` | bin DIR (`…/tmux-2html/bin`) | ensure_binary.sh:17,84 |
| Caller acceptance | `sh … 2>/dev/null; then [ -x "$bin" ] && exit 0` | ensure_binary.sh:84-85 |
| Caller stderr | suppressed (`2>/dev/null`) | ensure_binary.sh:84 |
| Binary name (in tarball + bin dir) | `tmux-2html` | build.zig:17, external_deps.md:120-122 |
| `--version` output | `tmux-2html 0.1.0\n` | main.zig:108-112 (empirical) |
| Repo name (URL) | **`tmux-ansi2html`** (owner dabstractor) | git remote.origin.url |
| Asset pattern | `tmux-2html-<triple>.tar.xz` | external_deps.md:122 |
| 4 triples | linux-x86_64, linux-aarch64, macos-x86_64, macos-arm64 | external_deps.md:108-111 |
| SHA256SUMS content | hash of BARE `tmux-2html`; form `<hex>  tmux-2html` | external_deps.md:120-121 |
| SHA256SUMS count | ONE per matrix job (4 files, glob `dist/**/SHA256SUMS.txt`) | external_deps.md:121,132 |
| Tarball layout | top-level entry `tmux-2html` (created via `-C dist … tmux-2html`) | external_deps.md:122 |
| Testing pattern | self-contained sh stub harness + fake tools on PATH + mktemp work dirs; no framework | P2M3T1S1 & P2M2T1S1 PRP Level 2 |

### Open questions for the PRP author
1. **Repo-name split (Q6):** bake `REPO="dabstractor/tmux-ansi2html"` constant. Verify the actual (future) release URL shape and whether `releases/latest/download/<asset>` is the intended mechanism or whether download.sh should call the `/releases` API (to discover the latest tag + asset URLs explicitly). The external_deps.md workflow uses `softprops/action-gh-release` with `draft: true` — ⚠️ **draft releases are NOT downloadable via `releases/latest/download/`** (drafts aren't "latest"). Confirm whether releases are published or how download.sh resolves the latest *published* release.
2. **SHA256 verification target:** verify against the extracted bare `tmux-2html` (matches how the hash was computed), not the tarball.
3. **`uname -sm` → triple mapping** (mentioned in S1 PRP §8 / Anti-Patterns) is not pinned in external_deps.md — needs defining: `Linux x86_64 → linux-x86_64`, `Linux aarch64 → linux-aarch64`, `Darwin x86_64 → macos-x86_64`, `Darwin arm64 → macos-arm64` (note `uname -m` reports `arm64`, not `aarch64`, on macOS).
4. **Atomicity:** mirror S1's same-filesystem temp + rename install (`mktemp -d "$bin_dir/.dlXXXXXX"`) so download never leaves a half-written binary (ensure_binary.sh step 3 relies on `[ -x "$bin" ]` post-success).
