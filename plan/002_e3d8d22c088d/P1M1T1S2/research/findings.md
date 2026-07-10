# Research Findings — P1.M1.T1.S2 (locale→BCP-47 lang resolver)

> The reference implementation below was VERIFIED by compiling and running it
> against the real Zig 0.15.2 toolchain (`/home/dustin/.local/opt/zig-x86_64-linux-0.15.2`,
> `zig version` → `0.15.2`). A standalone `zig test` harness of all 27 cases
> passed (exit 0). The functions use only std-lib APIs already in use in
> `src/render.zig`. Throwaway harness: `/tmp/lang-resolve-verify` (removed).

## 1. Verified implementation (27/27 tests pass)

The four functions compile and behave exactly as the contract + architecture
doc specify. The verbatim code is in the PRP. Summary of the verified behavior:

| Input (`toBcp47`) | Output |
|---|---|
| `en_US.UTF-8` | `en-US` |
| `pt_BR.UTF-8` | `pt-BR` |
| `de_DE@euro` | `de-DE` (modifier stripped) |
| `zh_CN` | `zh-CN` |
| `en_us` | `en-US` (case normalized) |
| `en-US` | `en-US` (already BCP-47) |
| `eng_GB` | `eng-GB` (3-letter lang allowed) |
| `en` | `en` (lang-only) |
| `C`, `POSIX`, `C.UTF-8`, `""` | `null` |
| `english` (7 chars) | `null` |
| `e_US` (1-char lang) | `null` |
| `en_USA` (3-char region) | `null` |

`langFromEnvStrings` precedence + fallback and `resolveLang` explicit-wins were
all verified (see test list in the PRP).

## 2. No-allocation strategy: module-level STATIC buffer (not in-place, not stack)

The architecture doc (`lang_resolution.md` "Contract" section) offers three
no-alloc options. Two of them are UNSAFE — verified by reasoning about Zig's
type system:

- **In-place mutation of the input: REJECTED.** `toBcp47(locale: []const u8)`
  takes a `const` slice. Its callers pass either env strings (`std.posix.getenv`
  returns `?[:0]const u8` — const) or, in tests, string literals (e.g.
  `"en_US.UTF-8"`) which live in `.rodata`. Mutating via `@constCast` would be
  undefined behavior / segfault on read-only memory. The doc's "in-place
  normalization of the returned slice is acceptable" applies ONLY to the env
  path AND only if the lang were mutable; but the pure testable function MUST NOT
  mutate. So in-place is out for `toBcp47`.
- **Stack buffer: REJECTED.** Returning `[]const u8` that points into a function
  local `[N]u8` is a dangling pointer (the stack frame is gone). Classic bug.
- **Module-level static buffer: ADOPTED.** `var bcp47_buf: [16]u8 = undefined;`
  outlives the call, needs no allocator, and is fine because the buffer holds
  ONE tag at a time. (A normalized tag is at most 6 chars: `xxx-XX` per the
  regex `^[a-z]{2,3}(-[A-Z]{2})?$`; `[16]` is generous.)

CAVEAT (documented in PRP gotcha): the buffer is overwritten on every call.
`resolveLang`/`langFromEnv` are each called ONCE per render and the result is
stored into `DocumentOpts.lang` and consumed during that single `writeDocument`
— so no aliasing occurs in practice. Tests must check each result BEFORE calling
`toBcp47` again (holding two returned slices simultaneously aliases them).

## 3. Precedence with NO cascade (deliberate choice)

`langFromEnvStrings`: the first NON-EMPTY candidate (LC_ALL → LC_MESSAGES → LANG)
wins. If its `toBcp47` transform returns null, it falls DIRECTLY to `"en"` — it
does NOT try the next candidate. Rationale: POSIX says "LC_ALL (if non-empty)
overrides everything"; if a user sets `LC_ALL=C` they have chosen the C locale,
which correctly maps to `en` (POSIX default = English). Cascading to LANG would
second-guess that explicit choice. The contract's TDD cases do not test cascade,
so this is unconstrained; the non-cascade interpretation is simplest and
POSIX-faithful.

## 4. C / POSIX / empty are rejected by the lang-subtag length check (no special case)

The doc lists `C`, `POSIX`, `C.UTF-8`, `""` as explicit "→ none" cases. In the
verified implementation these fall out NATURALLY from the validation:
- `C` → lang subtag `C` is 1 char → fails `len 2..3` → null.
- `POSIX` → 5 chars → fails → null.
- `C.UTF-8` → strip `.UTF-8` → `C` → 1 char → null.
- `""` → 0 chars → fails → null.
No explicit `if (eql("C"))` branch is needed; the regex/length check subsumes it.
(An explicit guard is harmless but redundant — the PRP uses the length check only.)

## 5. Testability split: pure strings fn + thin env wrapper

Under `.link_libc=false` there is NO `setenv` in `std.process`/`std.posix`, so
`langFromEnv()` (which reads the real process env) CANNOT be made deterministic
in a unit test. Solution (from the architecture doc, verified): the env-probing
logic lives in a PURE `langFromEnvStrings(lc_all, lc_messages, lang)` that takes
the three values as params — tests drive this directly with string literals
(fully deterministic). `langFromEnv()` is a one-line wrapper that reads
`std.posix.getenv` and delegates. This is the same getenv pattern render.zig
already uses at line 565 (`std.posix.getenv("TMPDIR") orelse "/tmp"`).

## 6. Placement + API anchors in src/render.zig (verified against HEAD)

- `DocumentOpts` struct: render.zig:187–192 (`lang: []const u8 = "en"` at :189).
  Insert the four lang functions IMMEDIATELY AFTER line 192 (`};`), before
  `writeEscaped` (line 196). This is "next to DocumentOpts" per the contract.
- Tests: append at end of file (render.zig is 1341 lines; last test
  `clampExtent: last_row==0` ends ~line 1340). Follow the existing
  `test "<fn>: <scenario>"` naming (22 existing tests use this form).
- The only `DocumentOpts{...}` construction today is render.zig:636
  (`.title = "tmux-2html"`, lang defaults to `"en"`). S2 does NOT touch this —
  that is S3's wiring (`.lang = resolveLang(opts.lang)`). S2 is purely additive
  (new fns + new tests), so it cannot regress goldens or existing behavior.

## 7. std-lib APIs (all confirmed in 0.15.2, all already used in render.zig)

- `std.mem.indexOfScalar(u8, slice, c)` → `?usize` (mem.zig:1244). For `.codeset`/`@modifier` strip.
- `std.ascii.toLower(u8)`/`toUpper(u8)` → u8 (ascii.zig:191/185). Only A–Z/Z–a
  are changed; digits/symbols pass through unchanged (so the post-case `<'a'|>'z'`
  check correctly rejects non-letters).
- `std.posix.getenv("NAME")` → `?[:0]const u8` (coerces to `?[]const u8` param).
- `std.testing.expectEqualStrings` / `expectEqual(@as(?[]const u8, null), x)` for null cases.

## 8. Validation gate: `zig build test -Doptimize=ReleaseFast`

Standalone `zig test file.zig` works in DEBUG for THIS pure code (no ghostty dep
in the standalone harness — that's how I verified the algorithm fast). BUT the
PROJECT test step is `b.addTest(.{ .root_module = exe.root_module })` rooted at
src/main.zig, which imports ghostty-vt. The test binary therefore links
ghostty-vt's C++ SIMD libs (simdutf/highway/utfcpp), so plain `zig build test`
(Debug) hits the known `R_X86_64_PC64` linker bug. **The project gate is
`zig build test -Doptimize=ReleaseFast`** (mandatory, per plan/001 findings_and_
corrections.md §4 / PRD §15). S1's PRP documents the same gotcha.

## 9. Scope boundaries (vs siblings)

- S1 (parallel): adds `--lang`/`--title` to cli.zig RenderOpts/PaneOpts/RegionOpts as raw `?[]const u8`. S2 does NOT touch cli.zig.
- S2 (this task): adds the resolver fns + tests to render.zig ONLY. Additive; no wiring.
- S3: render.run wires `.lang = resolveLang(opts.lang)` into DocumentOpts (render.zig:636 area).
- S4: pane (main.zig) + region (region.zig) honor `--lang`/`--title` override via resolveLang.
- S2's `pub fn resolveLang`/`langFromEnv` signatures are the stable contract S3/S4 consume.
