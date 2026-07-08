# External research — P1.M2.T1.S2 (palette cache read/write)

Companion to the std API citations in `findings.md`. Cites authoritative sources for
the three external correctness questions: XDG cache path resolution, atomic file
writes, and the ISO 8601 timestamp in the cache header.

> URLs below are canonical, stable references (man7.org, freedesktop.org,
> rfc-editor.org, lwn.net, iso.org). Live-verify before pasting into
> `docs/CONFIGURATION.md`; man7/rfc-editor/freedesktop/lwn are extremely stable.

## 1. XDG Base Directory Specification — `$XDG_CACHE_HOME`

Normative text: `$XDG_CACHE_HOME` is the base dir for user-specific non-essential
data files, with the explicit fallback:

> "If `$XDG_CACHE_HOME` is either not set or empty, a default equal to
> `$HOME/.cache` should be used."

Edge cases:
- **Unset → `$HOME/.cache`.** Explicit.
- **Empty string → `$HOME/.cache`.** The spec groups "not set or empty" into the
  same fallback; an empty value is treated as unset.
- **Relative path →** the spec text does not pin this as "undefined", but robust
  implementations (GLib `g_get_user_cache_dir`, Rust `dirs`, Python `platformdirs`)
  require an ABSOLUTE path and fall back to the default for any relative value.
  Treat relative as invalid → `$HOME/.cache`.
- **`$HOME` unset →** degenerate, implementation-defined. Real systems always set it.

Convention for a per-program cache: a program-specific subdirectory,
`$XDG_CACHE_HOME/<progname>/` (universal practice; not mandated by the spec text).

For tmux-2html the cache FILE is `$XDG_CACHE_HOME/tmux-2html/palette` (a single
plain-text file, not a directory of files — see PRD §6).

URLs:
- https://specifications.freedesktop.org/basedir-spec/latest/ — "Environment variables".
- https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html#variables (archived anchor).
- https://docs.gtk.org/glib/func.get_user_cache_dir.html — absolute-path-requirement precedent.

## 2. Atomic file write (POSIX/Linux)

Pattern: create a **temp file in the SAME directory** as the target, write data,
(optionally) `fsync` the temp file, `rename()` it over the target, then
(optionally) `fsync` the parent directory.

**Why same directory:** `rename(2)` is only atomic when source and destination are
on the same filesystem. Across filesystems the kernel cannot do an atomic rename and
the syscall **fails with `EXDEV`** — it does NOT silently copy. Co-locating the temp
file with the target guarantees the same filesystem, so a crash leaves either the old
file or the new file, never a truncated/half-written file.

**fsync tradeoff:** fsync-before-rename guarantees the new file's contents reach
stable storage before the rename makes it visible (protects against power loss
exposing an empty/partial file). The cost is latency. For a tiny (~3.6 KB) palette
cache that is rewritten rarely, calling `sync()` on the temp file before rename is
cheap and recommended; we tolerate `sync` errors (best-effort durability).

URLs:
- https://man7.org/linux/man-pages/man2/rename.2.html — EXDEV, atomicity.
- https://lwn.net/Articles/457667/ — "Ensuring data reaches disk" (fsync-before-rename + dir fsync).
- https://www.gnu.org/software/libc/manual/html_node/Renaming-Files.html

## 3. ISO 8601 / RFC 3339 UTC timestamp

`2026-07-08T14:30:00Z` is a valid **ISO 8601** extended date-and-time representation
(`YYYY-MM-DDThh:mm:ss`) and a valid **RFC 3339** `date-time` (RFC 3339 is a profile of
ISO 8601). The trailing **`Z`** is the Zulu/UTC designator (zero UTC offset;
interchangeable with `+00:00`). No fractional seconds, no other offset.

Note: the timestamp is purely informational (the header line). `loadCache` ignores
every line beginning with `#`, so the exact ISO 8601 value does NOT affect the
round-trip — it only needs to be a readable, valid UTC timestamp for humans inspecting
the cache file (the "debuggable plain text" goal, PRD §6).

URLs:
- https://www.rfc-editor.org/rfc/rfc3339 — canonical.
- https://www.rfc-editor.org/rfc/rfc3339#section-5.6 — §5.6 grammar + `Z`=UTC.
- https://en.wikipedia.org/wiki/ISO_8601 — accessible overview (ISO 8601-1:2019 is paywalled).
