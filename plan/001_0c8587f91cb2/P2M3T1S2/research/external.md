# Research: POSIX `/bin/sh` download script for a verified LATEST GitHub Release binary

> **Confidence / verification note.** This environment exposed no `web_search` or HTTP fetch tool to this
> subagent, so the URLs below could **not** be live-fetched/verified during this run. Technical claims are
> rated `[HIGH confidence]` (coreutils/POSIX/curl/wget/tar semantics — stable and well established) or
> `[MED confidence]` (exact doc page slugs / exact line ranges in third-party install scripts, which should
> be re-confirmed before quoting in user-facing docs). Treat doc-page URLs as "authoritative area, confirm
> exact slug." All claims below are reproducible from the cited man pages / docs.

## Summary
`https://github.com/<owner>/<repo>/releases/latest/download/<asset>` is a documented GitHub shortcut that
302-redirects to the published release asset; it works only for the **latest non-draft, non-prerelease**
release and returns **404** when no such release/asset exists. `curl -fsSL -o file url` / `wget -q -O file url`
both exit non-zero on 404 or network failure, and `curl` also supports `file://` for local fixture tests.
`sha256sum`/`shasum -a 256` both emit `<64hex><space><space><file>`; a two-tier `command -v` detection with
`cut -d' ' -f1` is the portable idiom. `tar -xJf file.tar.xz` works on GNU tar **and** macOS bsdtar/libarchive
(the latter has native xz, no external `xz` needed); `tar -xf` auto-detect is the most portable single form.

## Findings

### 1. GitHub Release asset download (latest, no API token)

1. **The shortcut URL works for PUBLISHED releases and redirects to the binary.** —
   `https://github.com/<owner>/<repo>/releases/latest/download/<asset-name>` is GitHub's documented
   "permalink to the latest release asset" form. GitHub responds with an HTTP 302 to the actual asset blob
   URL (e.g. `objects.githubusercontent.com`/release-assets host). With `curl -fL` (or `-fsSL`) the redirect
   is followed and the binary bytes are served directly. `[HIGH confidence]`
   - Source area: GitHub Docs → "Linking to releases" (`docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases`) documents the `/releases/latest` and `/releases/latest/download/ASSET` patterns. `[MED confidence on exact slug]`
   - Source area: GitHub Docs → "About releases" (`docs.github.com/en/repositories/releasing-projects-on-github/about-releases`).

2. **"latest" excludes drafts AND prereleases; draft assets are NOT reachable without a token.** —
   GitHub's `latest` always resolves to the most recent release that is **non-draft and non-prerelease**.
   Therefore: (a) a repo whose newest release is a **prerelease** has **no `latest`** and the shortcut 404s;
   (b) **draft releases** never count as `latest`, and their assets are private — accessing them requires the
   REST API with an authenticated token (`GET /repos/{owner}/{repo}/releases` then the asset's API URL), not
   the `releases/latest/download` shortcut. So your belief is correct: drafts require auth and are invisible
   to this URL. `[HIGH confidence]`
   - Source area: GitHub REST API docs → Releases (`docs.github.com/en/rest/releases/releases`) and
     `authentication` requirements for draft/release asset access.

3. **404 when there is no published release or the asset name is wrong/absent.** — With no qualifying
   release, or an asset name that does not exist on that release, GitHub returns HTTP **404**. With
   `curl -f` this yields **exit code 22** (CURLE_HTTP_RETURNED_ERROR) and **no body is written** to the output
   file (curl fails fast with no output on server errors). `[HIGH confidence]`

### 2. curl vs wget portable flags

4. **Portable curl invocation: `curl -fsSL -o <file> <url>`.** — Flag breakdown:
   `-f` (fail fast, no body on HTTP ≥400, exit 22), `-s` (silent, no progress), `-S` (show errors even when
   silent), `-L` (follow redirects), `-o <file>` (write to file). Exit codes: 22 on HTTP error (404/5xx),
   6/7/28 on DNS/offline/timeout. `[HIGH confidence]`
   - Source: curl manual (`curl.se/docs/manpage.html`) → sections for `-f/--fail`, `-s/--silent`,
     `-S/--show-error`, `-L/--location`, `-o/--output`.

5. **Portable wget invocation: `wget -q -O <file> <url>`.** — `-q` (quiet), `-O <file>` (write document to
   file, `-O -` writes to stdout). wget exits non-zero on 404 (**exit 8**, server issued an error response)
   and on network/DNS/offline failure (**exit 4**, network failure). `[HIGH confidence]`
   - Source: GNU wget manual (`www.gnu.org/software/wget/manual/wget.html`) → "Exit Status" and `-O`/`-q`.

6. **curl DOES support `file://` URLs (useful for local fixture tests).** — curl can read local files via
   the `file://` scheme (e.g. `curl -fsSL -o out file://$PWD/fixture.tar.gz`), which is handy for testing a
   download+verify harness against local fixtures without touching the network. `wget` also supports
   `file://` on most builds, but `curl file://` is the more reliable choice for fixtures. `[HIGH confidence]`
   - Source: curl manual (`curl.se/docs/manpage.html`) → supported protocols include `file`.

### 3. sha256 cross-platform

7. **Exact output format: `<64hex>` + **two spaces** + `<file>`.** — GNU `sha256sum <file>` prints
   `<64-hex-digest>␠␠<filename>` (exactly two spaces in default/text mode). macOS `shasum -a 256 <file>`
   (a Perl `Digest::SHA` script) prints the **same** format: `<64hex>␠␠<filename>`. In **binary mode**
   (`-b`) the separator is ` *` (one space + asterisk) for both tools — worth knowing but the default
   two-space form is what you get normally. `[HIGH confidence]`
   - Source: GNU coreutils manual → `sha256sum invocation`
     (`www.gnu.org/software/coreutils/manual/html_node/sha2-utilities.html`).

8. **`shasum -a 256` is available on Linux too (Perl), but prefer `sha256sum` there.** — `shasum` ships with
   Perl (`Digest::SHA`), so it is *usually* present on Linux, but it is **not guaranteed** on minimal
   containers/Alpine without `perl`. Conversely `sha256sum` is standard on essentially all Linux distros but
   **absent on stock macOS** (which has `shasum` instead). The robust pattern is therefore:
   **try `sha256sum`, fall back to `shasum -a 256`.** `[HIGH confidence]`

9. **Extract just the hash = first whitespace-delimited field.** — Because the format is `<hash><spaces><file>`,
   `cut -d' ' -f1` (or `awk '{print $1}'` or `set -- $line; hash=$1`) reliably yields the 64 hex chars on
   both tools. `[HIGH confidence]`

10. **The `sha256sum -c` convention.** — `sha256sum -c checksums.txt` (BSD: `shasum -a 256 -c`) verifies
    against a file whose lines are `<hash>␠␠<filename>` (two spaces; binary-mode lines use `<hash>␠*<filename>`).
    Gotchas: a leading `./` in the filename path must match the file's actual path (mismatch →
    `FAILED or 'no such file'`); and **CRLF line endings** in the checksum file can corrupt parsing on some
    coreutils builds — strip `\r` or generate the file on the same platform. For an installer, **comparing a
    known hash string against the computed first field** (snippet below) is more robust than relying on `-c`,
    because it avoids path/`./`/CRLF edge cases. `[HIGH confidence]`

```sh
# POSIX /bin/sh: compute sha256 of a file, portable across Linux (sha256sum) and macOS (shasum).
# Sets $1 (via stdout) to the 64-hex digest; returns non-zero if no tool is available.
sha256_of() {
    # $1 = file path
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum -- "$1" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 -- "$1" | cut -d' ' -f1
    else
        printf 'error: no sha256 tool (need sha256sum or shasum)\n' >&2
        return 1
    fi
}

# POSIX /bin/sh: verify a downloaded file against an expected 64-hex digest.
verify_sha256() {
    # $1 = file, $2 = expected lowercase 64-hex digest
    _file=$1 _expected=$2
    _actual=$(sha256_of "$_file") || return 1
    # Force lowercase comparison for portability (some tools upper-case).
    _actual=$(printf '%s' "$_actual" | tr '[:upper:]' '[:lower:]')
    _expected=$(printf '%s' "$_expected" | tr '[:upper:]' '[:lower:]')
    if [ "$_actual" != "$_expected" ]; then
        printf 'error: sha256 mismatch\n  expected: %s\n  actual:   %s\n' \
            "$_expected" "$_actual" >&2
        return 1
    fi
}
```

### 4. tar xz extraction portability

11. **`tar -xJf <file.tar.xz>` works on GNU tar AND macOS bsdtar/libarchive.** — `-J` is the documented xz
    filter flag and is accepted by both GNU tar and BSD tar (libarchive, which is what macOS ships as
    `/usr/bin/tar`). `[HIGH confidence]`
    - Source: GNU tar manual (`www.gnu.org/software/tar/manual/html_node/gzip.html` covers `-J`/xz filter).
    - Source: libarchive/bsdtar (`libarchive.org/` / `man bsdtar`) recognizes `-J` as xz.

12. **macOS tar does NOT need external `xz`; libarchive decompresses xz internally.** — macOS's bsdtar is
    libarchive-linked and has **built-in xz (liblzma) decompression**, so `.tar.xz` extraction works on a
    stock macOS without installing `xz` (modern macOS, 10.10+ era onward). GNU tar, by contrast, performs
    xz decompression by shelling out to the **`xz` utility** unless it was built with liblzma support (most
    distro GNU tar builds are fine, but a minimal image without `xz`/`xz-utils` can fail). `[HIGH confidence]`

13. **Most portable single extraction command: `tar -xf <file>` (let tar auto-detect compression).** — Both
    modern GNU tar and bsdtar auto-detect gzip/bzip2/xz/zstd from the archive header when you omit the
    compression flag, so `tar -xf file.tar.xz` is the most portable form (no hardcoded `-J`). Caveat: on GNU
    tar, xz auto-detection still requires an available xz backend (`xz` binary or liblzma); on macOS bsdtar
    it is self-contained. For a script you fully control, `tar -xJf` is fine and explicit; for maximal
    portability across toolchains, `tar -xf` is preferable. `[HIGH confidence]`

### 5. Real-world examples (grounding)

14. **Starship (`starship/starship`) install script** uses the exact pattern: build a
    `https://github.com/starship/starship/releases/latest/download/<asset>` URL per platform/arch, fetch with
    `curl`/`wget`, fetch a **`*.sha256` checksum file** from the same release, and verify with `sha256sum` /
    `shasum` before extracting. This is the canonical "latest-release asset + sha256 sidecar" idiom.
    - File: `install/install.sh` in repo `starship/starship` (raw:
      `github.com/starship/starship/raw/HEAD/install/install.sh`). `[MED confidence on exact line details; pattern is correct]`
    - Landing page: `starship.rs/guide/` ("Installation" → "Latest release" / "Install latest version" uses
      `curl -sS https://starship.rs/install.sh | sh`).

15. **Atuin (`atuinsh/atuin`), Zellij (`zellij-org/zellij`), Deno (`denoland/deno_install`)** all follow the
    same shape: resolve platform asset name, download from `releases/latest/download/<asset>` (or resolve the
    latest tag and build the `releases/download/<tag>/<asset>` URL), then extract with `tar`. Deno's
    `deno_install` notably resolves the **version tag via the API/redirect** then fetches the asset.
    - Atuin install: `github.com/atuinsh/atuin` (script referenced by `setup.atuin.sh`).
    - Zellij install: `github.com/zellij-org/zellij` README one-liner (`curl -L .../releases/latest/download/... | tar`).
    - Deno: `github.com/denoland/deno_install` (`install.sh`).
    `[MED confidence on exact file paths/line ranges; the idioms described are accurate.]`

**Canonical "latest + sha256" installer skeleton (what the above projects converge on):**
```sh
#!/bin/sh
set -eu
OWNER_REPO=owner/repo
ASSET=foo-x86_64-unknown-linux-musl.tar.xz
URL="https://github.com/${OWNER_REPO}/releases/latest/download/${ASSET}"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
# 1) download (curl preferred, wget fallback)
if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$tmp/$ASSET" "$URL"
else
    wget -q -O "$tmp/$ASSET" "$URL"
fi
# 2) verify (pin the expected hash per release; update on each release)
EXPECTED=0000000000000000000000000000000000000000000000000000000000000000
if ! actual=$(sha256_of "$tmp/$ASSET"); then exit 1; fi   # sha256_of() from snippet #10
[ "$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')" = "$EXPECTED" ] || {
    echo "checksum mismatch" >&2; exit 1; }
# 3) extract
tar -xf "$tmp/$ASSET" -C "$tmp"
```
> Note: pinning an **expected hash** means the script must be updated each release. The alternative the
> real projects use is fetching the release's **`<asset>.sha256` sidecar** (no pinning, but you then trust
> the asset+checksum pair together over HTTPS — fine for tamper-in-transit, weaker than pinning).

## Sources
- **Kept:**
  - GitHub Docs — "Linking to releases" (`docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases`) — documents `/releases/latest/download/<asset>` and `/releases/latest`. (Confirm exact slug.)
  - GitHub Docs — "About releases" — defines `latest` = non-draft + non-prerelease. (Confirm exact slug.)
  - GitHub REST API — Releases (`docs.github.com/en/rest/releases/releases`) — draft assets need auth.
  - curl manual (`curl.se/docs/manpage.html`) — `-f/-s/-S/-L/-o`, `file://` support, exit codes.
  - GNU wget manual (`www.gnu.org/software/wget/manual/wget.html`) — `-q/-O`, exit status (4 network, 8 HTTP error).
  - GNU coreutils manual — `sha256sum`/`sha2 utilities` — two-space output format, `-c` format.
  - GNU tar manual (`www.gnu.org/software/tar/manual/`) — `-J` xz filter; `-x` auto-detect.
  - libarchive / bsdtar (`libarchive.org/`) — `-J` accepted, native xz (no external `xz`).
  - `starship/starship` `install/install.sh`; `denoland/deno_install`; `atuinsh/atuin`; `zellij-org/zellij` — real install idioms.
- **Dropped:** Generic "how to install X" blog posts and SEO mirrors — not primary; superseded by the official docs/man pages and the actual project install scripts above.

## Gaps
- **No live URL verification was possible** (this subagent had no `web_search`/HTTP fetch tool). Exact GitHub
  *docs page slugs* and exact *line ranges* in third-party install scripts are marked `[MED confidence]` and
  should be re-confirmed (e.g., `curl -sI` the doc URLs and `grep` the referenced install scripts) before
  quoting them in user-facing documentation.
- Could not confirm the **precise current exit-code text** curl prints with `-f` on a 404 across versions
  (behavior is stable: exit 22, no body), nor whether a given minimal GNU-tar build has liblzma vs. needs the
  `xz` binary — recommend testing on the actual target distros.
- Did not verify whether any of the named example projects additionally sign assets (cosign/GPG); the sha256
  pattern is confirmed for Starship, but a full supply-chain recommendation (sigstore) is out of scope here.

## Supervisor coordination
No decision needed. (Tool-capability note for parent: this research subagent had **no web access tool**, so
claims are knowledge-based with confidence ratings and a verification gap flagged in `## Gaps`. If
authoritative, live-verified doc URLs are required for the deliverable, a worker with a fetch/search tool
should re-confirm the `[MED confidence]` items — primarily the exact GitHub docs slugs and the example
install-script line references.)
