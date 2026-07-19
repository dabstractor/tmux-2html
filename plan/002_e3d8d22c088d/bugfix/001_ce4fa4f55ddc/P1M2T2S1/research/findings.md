# Research findings — P1.M2.T2.S1 (Issue 4: `--lang ""` forces `en`)

## 1. The bug (confirmed by reading src/render.zig directly)

`resolveLang` (render.zig:292):
```zig
pub fn resolveLang(explicit: ?[]const u8) []const u8 {
    if (explicit) |e| return toBcp47(e) orelse "en";   // <-- empty e reaches here
    return langFromEnv();
}
```
When the CLI passes `--lang ""`, cli.zig sets `opts.lang = @as(?[]const u8, "")` — a **non-null,
zero-length slice**. `if (explicit) |e|` unwraps it to `e = ""`, calls `toBcp47("")` which returns
`null` (its guard `if (lang_src.len < 2 …) return null;` at render.zig:239), and `orelse "en"`
forces `"en"` — **skipping `langFromEnv()` (locale derivation) entirely**.

The documented behavior (PRD §8.1; docs/CONFIGURATION.md:49 "Empty ⇒ locale-derived") and the
plugin's own `[ -n "$lang_opt" ]` guard (omits `--lang` when empty) both treat empty as "derive
from locale". Only an explicit CLI `--lang ""` hit this branch.

## 2. The surrounding functions (exact current signatures, read line-by-line)

- `fn toBcp47(locale: []const u8) ?[]const u8` (render.zig:221) — PURE POSIX-locale→BCP-47
  transform; strips `.codeset`/`@modifier`, `_`→`-`, validates `^[a-z]{2,3}(-[A-Z]{2})?$`;
  returns null for C/POSIX/empty/invalid. Writes into module-level `bcp47_buf` (static, no free).
- `fn langFromEnvStrings(lc_all, lc_messages, lang: ?[]const u8) []const u8` (render.zig:272) —
  **PURE, param-taking**: LC_ALL→LC_MESSAGES→LANG→"en"; set-but-EMPTY counts as unset (POSIX
  override semantics); first non-empty candidate wins, invalid → "en" (no cascade). DETERMINISTIC
  + already unit-tested (render.zig:1571-1587).
- `pub fn langFromEnv() []const u8` (render.zig:281) — reads env via `std.posix.getenv`, delegates
  to langFromEnvStrings.
- `pub fn resolveLang(explicit: ?[]const u8) []const u8` (render.zig:292) — the buggy fn.

## 3. Callers of resolveLang / langFromEnv (grep across src/)

- `resolveLang` is called by: `main.zig:532` (pane), `region.zig:470`, `render.zig:747`. All pass
  `opts.lang` (`?[]const u8`). → resolveLang is the single public entry; its signature MUST stay
  `pub fn resolveLang(explicit: ?[]const u8) []const u8`.
- `langFromEnv` is called ONLY by `resolveLang` (render.zig:294) today. After the refactor it
  delegates to the new pure core (kept alive + DRY — see §5).

## 4. The env-mocking constraint (DRIVES the test design)

- **Zig 0.15.2 std has NO `setenv`** (verified in the P1.M2.T2.S1 feature PRP research; also
  `link_libc = false` in build.zig:24 ⇒ no libc `setenv` either). So a unit test CANNOT set
  `LANG=de_DE.UTF-8` to make `resolveLang("")` deterministic via the real env.
- The existing `resolveLang` tests (render.zig:1590-1604) acknowledge this: the null/env test only
  asserts `got.len > 0` ("reads the real host env, not deterministic").
- An invariant test `resolveLang("") == resolveLang(null)` is NOT a robust regression test: in an
  env with no locale, `langFromEnv()` returns `"en"`, so the OLD buggy code (`resolveLang("")="en"`)
  and the new code both satisfy the invariant → false negative.
- **CONCLUSION**: to deterministically prove the empty branch, the fix must funnel through a PURE,
  param-taking helper (mirroring the existing `langFromEnv`→`langFromEnvStrings` split). This is
  the contract's own fallback ("if env mocking is impractical … test … the underlying pure
  function"), realized cleanly.

## 5. The fix (Option B — pure core, deterministic-testable, idiomatic)

Add `fn resolveLangImpl(explicit, lc_all, lc_messages, lang)` (PURE, param-taking) that holds the
empty guard; `resolveLang` + `langFromEnv` both delegate to it. This:
- makes the empty-branch DETERMINISTICALLY testable (pass `"de_DE.UTF-8"` as the `lang` param);
- mirrors the EXACT `langFromEnv`(pub, env-reader) / `langFromEnvStrings`(pure, param-taker)
  precedent already in this file;
- is behavior-preserving for every existing case (resolveLangImpl(null,…) == langFromEnvStrings(…));
- keeps `langFromEnv` meaningful (it delegates to resolveLangImpl(null,…) — no dead code).

```zig
pub fn resolveLang(explicit: ?[]const u8) []const u8 {
    return resolveLangImpl(explicit, std.posix.getenv("LC_ALL"), std.posix.getenv("LC_MESSAGES"), std.posix.getenv("LANG"));
}
pub fn langFromEnv() []const u8 {
    return resolveLangImpl(null, std.posix.getenv("LC_ALL"), std.posix.getenv("LC_MESSAGES"), std.posix.getenv("LANG"));
}
fn resolveLangImpl(explicit: ?[]const u8, lc_all: ?[]const u8, lc_messages: ?[]const u8, lang: ?[]const u8) []const u8 {
    if (explicit) |e| {
        if (e.len == 0) return langFromEnvStrings(lc_all, lc_messages, lang); // Issue 4: empty explicit == unset
        return toBcp47(e) orelse "en";
    }
    return langFromEnvStrings(lc_all, lc_messages, lang);
}
```
Tests call the module-private `resolveLangImpl` directly (same-file tests can call private fns —
precedent: existing tests call private `toBcp47`/`langFromEnvStrings`/`clampExtent`/`writeFileAtomic`).

## 6. No conflict with parallel work

- P1.M2.T1.S1 (Issue 3, parallel) edits render.zig at **lines 547/603** (makePath in
  renderToFileAtomic/writeDocFileAtomic) + a test after **line 1336**. This task edits
  **lines 281-294** (langFromEnv/resolveLang → resolveLangImpl) + tests near **line 1606**.
  Disjoint regions ⇒ no merge conflict.
- P1.M1.T2.S1 (Issue 2 XSS) edits ghostty_format.zig + a test after line 1338. Also disjoint.

## 7. Docs target

docs/CONFIGURATION.md:49 (options table): `@tmux-2html-lang … Empty ⇒ locale-derived, fallback en.`
and lines 84-86 ("How options are read": the plugin bakes @tmux-2html-lang into `--lang`; "you can
also pass --title/--lang yourself"). Add one clarifying sentence: passing `--lang ""` (explicit
empty) is treated as unset → locale-derived (LC_ALL→LC_MESSAGES→LANG→en). This makes the binary
consistent with the already-documented "Empty ⇒ locale-derived" option semantics.

## 8. Build fact (confirmed)

`zig build test --release=fast` is the test gate (Debug hits R_X86_64_PC64 — see P1.M2.T1.S1 PRP
Gotcha 4; same toolchain). `link_libc = false` (build.zig:24) reinforces the no-setenv constraint.