# Lang Resolution Algorithm (PRD §8.1 `@tmux-2html-lang` / locale)

Derives the HTML `<html lang>` value. Source: PRD §8.1 ("default `en`;
configurable via `@tmux-2html-lang` / locale") + research (POSIX/glibc/RFC 5646
BCP 47 / WHATWG HTML / MDN). This is the contract for `render.resolveLang`.

## Precedence

```
1. explicit  (@tmux-2html-lang  →  binary --lang flag)
2. locale    (env:  LC_ALL  →  LC_MESSAGES  →  LANG)
3. fallback  "en"
```

- POSIX category precedence: `LC_ALL` (if non-empty) overrides everything; else
  category-specific `LC_*`; else `LANG`. For *language* the semantically correct
  category is `LC_MESSAGES`. ⇒ probe order `LC_ALL → LC_MESSAGES → LANG`.
- Treat a set-but-EMPTY value as unset (POSIX override semantics: `LC_ALL=""`
  does not force).

## Transform: POSIX locale name → BCP 47 tag

POSIX locale grammar (glibc): `language[_territory][.codeset][@modifier]`.

```
to_bcp47(locale) -> tag | none:
    s = locale
    s = before_first(s, '.')      # strip .codeset      en_US.UTF-8 -> en_US
    s = before_first(s, '@')      # strip @modifier     de_DE@euro  -> de_DE
    s = replace(s, '_', '-')      # underscore -> hyphen (BCP 47 mandates '-')
    parts = split(s, '-')
    parts[0] = lower(parts[0])    # language subtag lowercase
    if len(parts) > 1:
        parts[1] = upper(parts[1])   # region subtag UPPERCASE
    s = join(parts, '-')
    if s in {"C", "POSIX", ""}: return none
    if not s matches /^[a-z]{2,3}(-[A-Z]{2})?$/: return none
    return s
```

**Keep the region subtag** (`pt_BR.UTF-8` → `pt-BR`, NOT `pt`). It is valid BCP 47
and strictly more useful. The PRD `en` default is the *no-locale fallback*, not a
transform rule. The hyphen separator is **mandatory** (HTML/BCP 47; `pt_BR` is
invalid). `@modifier` (e.g. `@latin`) is DROPPED (script-variant mapping is out
of scope for this delta).

## Edge cases → all fall back to `en`

| Input | Result |
|---|---|
| `C`, `POSIX`, `C.UTF-8` | `en` (not BCP 47 tags) |
| empty / unset (all three vars) | `en` |
| invalid shape (fails regex) | `en` |
| `en_US.UTF-8` | `en-US` |
| `pt_BR.UTF-8` | `pt-BR` |
| `de_DE@euro` | `de-DE` |
| `zh_CN` | `zh-CN` |

## Contract for the implementation (Zig, `.link_libc=false`)

- PURE: reads env via `std.posix.getenv` (already used in render.zig for TMPDIR);
  NO `/dev/tty`, NO allocation needed for the returned static slice when the
  result is `"en"`. For derived values (`en-US` etc.) the common env values are
  short literals; the impl may return a pointer into the env string slice after
  in-place normalization (env strings are mutable process memory; lowercasing
  the lang / uppercasing the region in place is acceptable AND avoids alloc), or
  use a small stack buffer. Prefer no-alloc; if alloc is unavoidable, document it.
- Public surface:
  - `pub fn langFromEnv() []const u8` — locale algorithm only (precedence + transform + fallback).
  - `pub fn resolveLang(explicit: ?[]const u8) []const u8` —
    `if (explicit) |e| (to_bcp47(e) orelse "en") else langFromEnv()`.
    (An explicit `--lang C` or invalid value also degrades to `en` — defensive.)
- Unit tests (pure, no tty): `en_US.UTF-8`→`en-US`; `pt_BR.UTF-8`→`pt-BR`;
  `C`→`en`; unset→`en`; `de_DE@euro`→`de-DE`; explicit override wins; explicit
  invalid→`en`. Set/restore the env vars around each case (Zig `std.process`
  has no setenv in `.link_libc=false`; inject the source string into the pure
  `to_bcp47`/precedence fns directly — i.e. make the env-probing fn take the
  strings as params so it is deterministic & testable, with a thin `langFromEnv`
  wrapper that reads env).

## Sources

- POSIX Base Definitions Ch. 8 (LANG/LC_ALL/LC_* precedence) — pubs.opengroup.org
- glibc Manual "Locale Names" (grammar `lang[_terr][.codeset][@mod]`)
- RFC 5646 (BCP 47) — hyphen syntax, subtag validity
- WHATWG HTML — `lang`/`xml:lang` must be valid BCP 47
- MDN — HTML global attribute `lang`
