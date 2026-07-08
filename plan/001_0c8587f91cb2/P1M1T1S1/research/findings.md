# Research Findings — P1.M1.T1.S1 (build.zig.zon with ghostty + parg)

> All findings below were VERIFIED by running the real Zig 0.15.2 toolchain
> (`/home/dustin/.local/bin/zig`, `zig version` → `0.15.2`) against a faithful
> throwaway repo. None of this is from training-knowledge guessing.

## 1. Verified dependency hashes (live-fetch confirmed)

Both dependencies from `architecture/external_deps.md §1` resolve and cache
under their EXACT declared hashes — `zig build` exits 0, and the global Zig
cache (`~/.cache/zig/p/`) holds:

- `ghostty-1.3.1-5UdBCwYm-gQeBa4bu1-sMooCQS4KVriv5wWSIJ_sI-Cb`
- `parg-0.0.0-dOPWZNhYAABEHE6EGXmwIucnu9vj-emodT9vmHeYynAP`

→ **Do NOT regenerate these hashes** (no `zig fetch --save`). They are already
correct; regenerating would produce the same values but risks a typo.

## 2. CRITICAL — fingerprint behavior in Zig 0.15.2

The item contract says *"Delete the `.fingerprint` field so `zig build`
regenerates it."* This is **imprecise / misleading**. Empirically:

- `.fingerprint` is a **REQUIRED** top-level `u64` field in 0.15.2.
- When omitted, `zig build` **ERRORS** (exit ≠ 0):
  `error: missing top-level 'fingerprint' field; suggested value: 0x....`
- It does **NOT** auto-write the field into the `.zon`.
- The suggested value is **RANDOM each invocation** (observed 3 distinct values
  in 3 runs: `0x...b5f3a24e`, `0x...14a3cf56`, `0x...33318f1a`). It is NOT
  content-derived.

→ **Correct workflow:** hardcode ANY `u64` value (e.g. the one in the PRP,
`0x95375ce2c9bf5b21`, which builds cleanly), OR omit it, run `zig build`, read
the random suggestion from the error, and paste it back. Either yields a
working manifest. The value is arbitrary for a greenfield package with no
dependents; Zig never re-validates it.

## 3. `.name` identifier form

`.name = .tmux_2html` (underscore — no hyphen) **parses and builds cleanly** in
0.15.2. (The executable name `tmux-2html` with a hyphen is set separately in
`build.zig` via `addExecutable(.{ .name = "tmux-2html" })` — that is sibling
task S2, not this one.)

## 4. parg URL — username is `judofhr`

The verified, fetchable URL is
`git+https://github.com/judofhr/parg.git#b9ce29e3dcbf9845dac8ee4b33a31bb1bff29f80`.
NOTE the username spelling: **`judofhr`**. Some architecture docs (`findings_and_
corrections.md §4`, `research_zig_build.md §1`) typo it as `judofr`. The
`external_deps.md` zon block and my live fetch both confirm `judofhr`.

## 5. `.paths` entries must physically exist

`zig build --fetch` validates that every entry in `.paths` exists on disk.
S1 must therefore create stubs for: `src/`, `scripts/`, `licenses/`,
`testdata/`, `tmux-2html.tmux`, `LICENSE`, plus `build.zig` and `build.zig.zon`.

## 6. Minimal `build.zig` is enough for fetch

S1's deliverable is `build.zig.zon` only; the full `build.zig` wiring
(ghostty-vt module import, version bake, `-Dsimd`, test step) is **sibling task
P1.M1.T1.S2**. For S1's validation gate (`zig build --fetch`) to run, a
`build.zig` must exist and parse — a minimal stub is sufficient:

```zig
const std = @import("std");
pub fn build(b: *std.Build) void { _ = b; }
```

`zig build --fetch` evaluates the manifest and resolves dependencies WITHOUT
requiring `build.zig` to wire them. Verified exit 0.

## 7. Validation gate (verified working)

```
zig build --fetch     # → exit 0; ghostty + parg resolved & cached
```

Primary command. (Full `zig build` also exits 0 with the stub `build.zig`, but
that compiles nothing meaningful until S2 wires the executable.)
