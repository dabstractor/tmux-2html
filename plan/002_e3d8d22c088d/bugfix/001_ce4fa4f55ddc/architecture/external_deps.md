# External Dependencies & Technical References — Bug Fix 001

## POSIX Shell Single-Quote Escaping (Issue 1)

### The Problem
In POSIX sh, single-quoted strings (`'...'`) cannot contain a literal apostrophe (`'`).
The standard idiom to embed a `'` is to break out of single quotes, add an escaped `'`,
and re-enter single quotes: `'\''`. This sequence:
1. `'` — closes the current single-quoted string
2. `\'` — a literal apostrophe (escaped outside of quotes)
3. `'` — opens a new single-quoted string

### Canonical shell_escape function (POSIX sh)
```sh
# Usage: shell_escape "value with 'apostrophe'" → 'value with '\''apostrophe'\'''
shell_escape() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}
```
The `sed` expression `s/'/'\\\\''/g` is processed by the shell to `s/'/'\''/g`, which
replaces each `'` with `'\''`.

**Alternative without command substitution** (avoids trailing-newline stripping edge case):
```sh
shell_escape() {
    _v=$1
    _v=$(printf '%s' "$_v" | sed "s/'/'\\\\''/g")
    printf "'%s'" "$_v"
}
```

### How tmux run-shell processes the bound command
tmux `bind-key KEY run-shell "CMD"` stores `CMD` as a string. When the key is pressed,
tmux expands `#{...}` format variables, then passes the string to `/bin/sh -c "CMD"`.
The CMD string is already double-quoted at the tmux level, so:
- `\"` inside CMD → literal `"` in the /bin/sh context
- `\$` inside CMD → literal `$` (deferred expansion at fire time)
- `$(...)` inside CMD → command substitution at fire time

The title_arg/lang_arg fragments are interpolated (unquoted) into CMD at source time
(when tmux-2html.tmux runs), so they become part of the CMD string that /bin/sh later
parses. If they contain unbalanced quotes, /bin/sh fails to parse CMD → silent failure
(stderr swallowed by `2>/dev/null`).

### Verification approach for the fix
The `tests/plugin_options.sh` harness captures the EXACT bound command string via a mock
`tmux()` function. After fixing, the test should:
1. Source the loader with `@tmux-2html-title` = `Bob's pane`
2. Capture the bound command string for all 3 bindings
3. Assert the title_arg fragment parses under `/bin/sh -n` (syntax check, no execution)
4. Assert the title_arg contains the expected `--title` token with the escaped value

## HTML Attribute Escaping (Issue 2)

### OWASP HTML escaping reference
The existing `writeEscaped` function in `src/render.zig:299` escapes these characters:
| Char | Entity | Why |
|------|--------|-----|
| `&`  | `&amp;` | Must be first (prevents double-encoding of other entities) |
| `<`  | `&lt;`  | Prevents tag injection |
| `>`  | `&gt;`  | Prevents tag injection |
| `"`  | `&quot;`| Prevents attribute breakout in double-quoted attributes |
| `'`  | `&#x27;`| Prevents attribute breakout in single-quoted attributes |

This is the exact set needed for the `font-family` value in the `<pre style="...">` attribute.
The `"` is the critical one (the style attribute is double-quoted); the others are defense-in-depth.

### Ghostty stream writer API
The `buf_writer` in `ghostty_format.zig` is `stream.writer()` from ghostty's internal stream.
Available methods (confirmed by usage at lines 831, 836, 842):
- `.print(comptime fmt, args)` — formatted write
- `.writeAll(bytes)` — write a byte slice
- `.writeByte(c)` — write a single byte (standard writer method)

### CSS font-family value safety
CSS font-family values in a `style` attribute are double-quoted by the attribute delimiter.
A value like `a" onmouseover="alert(1)` breaks out because the `"` terminates the attribute.
Escaping `"` → `&quot;` makes it safe. The browser decodes `&quot;` back to `"` for the CSS
value, so `font-family: a&quot;b` renders correctly as `font-family: a"b` in the browser.

## Zig std.fs path operations (Issue 3)

### makePath
`std.fs.cwd().makePath(path)` creates all directories in `path` if they don't exist.
It is idempotent (no error if the path already exists). The project pattern is to
call it with `catch {}` (ignore errors — the subsequent file open will report the real error).

For absolute paths, `std.fs.makeDirAbsolute(path)` can be used, but `makePath` with cwd()
works for both relative and absolute paths when called from `std.fs.cwd()`.

### Pattern used by pane (main.zig:496) and region (region.zig:484)
```zig
std.fs.cwd().makePath(out_dir) catch {};  // pane: creates output dir
// OR
if (std.fs.path.dirname(path)) |dp| std.fs.cwd().makePath(dp) catch {};  // region: creates parent
```

The render path needs the same treatment in `renderToFileAtomic` and `writeDocFileAtomic`,
which currently call `openDir` directly without ensuring the directory exists.

## Zig optional string handling (Issue 4)

### `?[]const u8` semantics
In Zig, `@as(?[]const u8, "")` is `Some("")` — a non-null optional containing an empty slice.
This is different from `null` (no value). The CLI parser sets `opts.lang = try requireValue(&parser)`
which returns the raw argument value, so `--lang ""` sets `opts.lang` to `Some("")`.

### The resolveLang fix
```zig
pub fn resolveLang(explicit: ?[]const u8) []const u8 {
    if (explicit) |e| {
        if (e.len == 0) return langFromEnv(); // empty explicit => derive from locale
        return toBcp47(e) orelse "en";
    }
    return langFromEnv();
}
```
This treats empty explicit the same as null/unset, falling through to locale derivation.