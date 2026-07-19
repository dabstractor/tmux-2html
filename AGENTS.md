# AGENTS.md — agent operating rules for tmux-2html

> **Read this before touching anything.** It is normative, like PRD §0 / §0.1.
> The rules here exist because a prior agent run wrote **~12 GB** of
> `calls.log` to this repo and nearly took the host down. The protections
> below are deterministic on purpose: they fail closed.

---

## 0. What went wrong (so you understand the "why")

An agent ran a hand-rolled **`tmux` PATH-shim audit harness** (the pattern in
`plan/002_*/P1M1T3S1/PRP.md`). The shim logged every `tmux` call to `calls.log`
with an unbounded `>>`, then did `exec tmux ...` using a **bare `tmux`**.
Because the shim sat first on `PATH`, that bare `tmux` re-resolved to the shim
itself → **infinite self-`exec`, one appended line per loop, no cap** → GBs in
seconds. Two failure modes stacked:

1. **Recursive shim** — shim `exec`s the intercepted command by name instead of
   by absolute path.
2. **Unbounded log/scratch** — `>> calls.log` with no size cap, on a loop that
   never terminates.

These are the exact anti-patterns called out in PRD §0.1. Do not reintroduce
them.

---

## 1. Hard rules (never do these)

- **Never hand-roll a `tmux` (or any) PATH shim.** Use `scripts/with-tmux-audit.sh`
  (§3). It is correct by construction: absolute path, recursion guard, capped log,
  scoped teardown.
- **Never `exec`/call an intercepted command by bare name.** Always the real
  binary by **absolute path** (resolve it *before* prepending to `PATH`).
- **Never write a log/scratch file with an unbounded `>>`.** Cap it (byte or line
  limit), or write under `scripts/safe-run.sh` so `RLIMIT_FSIZE` caps it for you.
- **Never touch the user's running tmux.** No `kill-server`, `killall tmux`,
  `pkill tmux`, `pkill -f tmux`, no connecting to `$TMUX` / the default socket for
  anything but read-only `capture-pane`. This is PRD §0 — read it.
- **Never tear a test down globally.** Teardown is by exact named socket
  (`-L <name>`) / session (`-t <name>`) / PID you spawned, only.
- **Never spill large scratch to `/tmp`.** `/tmp` is tmpfs (RAM). Put scratch on
  real disk (a repo-local `scratch/` dir or `~/tmp`); don't point `TMPDIR` at
  `/tmp` for tools that write big artifacts.
- **Never fan out parallel heavy steps.** Run builds / large scans one at a time.

## 2. Required workflow for agents

1. **Before risky work:** read PRD §0 and §0.1.
2. **Run `scripts/check-safety.sh`** before committing and after editing shell
   or plan docs. CI runs it too. It fails on the patterns in §1.
3. **Run `scripts/preflight.sh`** after any test/audit run and before finishing a
   task. It reports giant files, audit residue, and low disk so nothing lingers.
4. **Wrap long-running / test / audit commands with `scripts/safe-run.sh`** so a
   runaway is killed by the kernel (`RLIMIT_FSIZE`, `RLIMIT_CPU`) before it
   threatens the host.
5. **For any tmux-call interception, use `scripts/with-tmux-audit.sh`.** Not a
   bespoke shim.

## 3. Deterministic protections in this repo

These are mechanical — they don't rely on an agent reading or remembering rules.

| File | What it enforces | How |
|---|---|---|
| `scripts/check-safety.sh` | Static guard against §1 anti-patterns | `grep` rules; **FAIL** on global tmux kill + recursive bare-`exec tmux`; **WARN** on hand-rolled shim recipe (`PATH=…:$PATH` + append) outside `scripts/`. Exits non-zero on FAIL. |
| `scripts/safe-run.sh` | Resource caps | Runs a command under `ulimit -f` (max file size → stops 6 GB logs) + `ulimit -t` (max CPU s → stops infinite self-`exec` loops) + `ulimit -c 0`. Pure kernel enforcement. |
| `scripts/with-tmux-audit.sh` | Approved tmux shim | Absolute `REAL_TMUX`, `T2H_AUDIT_ACTIVE` recursion guard, byte-capped `calls.log`, isolated `-L` socket, scoped `kill-session` teardown via `trap`. |
| `scripts/preflight.sh` | Residue / runaway detection | Bounded (`-xdev`, size-capped) scan for `>100 MiB` files, `.audit*` dirs, `calls.log`, stray `tmp.*`; reports disk free. |
| `scripts/hooks/pre-commit` | Commit gate | Runs `check-safety.sh --paths` on staged text files. **Opt-in** (§4). |
| `.gitignore` | Keep residue out of history | Ignores `.audit*/`, `calls.log`, `.last-output`, `tmp.*`. |

### Why `safe-run.sh` is the backstop that matters most

The incident was a single process writing one file without bound. The only
deterministic control that stops *that* is `RLIMIT_FSIZE` (`ulimit -f`): when a
process exceeds the cap, the kernel raises `SIGXFSZ` and the write fails. CPU
time (`ulimit -t`) catches the infinite-loop amplifiers. Anything you suspect
might run away — tests, audits, builds, generated-log producers — should run:

```sh
scripts/safe-run.sh --fsize 1024 --cpu 600 -- ./your-command
```

## 4. Opt-in: wire the guard into your commits

`check-safety.sh` runs in CI regardless. To also gate local commits:

```sh
git config core.hooksPath scripts/hooks   # reversible: git config --unset core.hooksPath
```

## 5. If something is running away right now

1. **Identify the exact PID** (`ps -ef | grep -E 't2h-audit|tmux-2html|<your-cmd>'`),
   kill **that PID** only. Never `pkill tmux` / `killall tmux` / `kill-server`.
2. If it created an isolated tmux server, tear down by its **named socket only**:
   `tmux -L <the-name> kill-session -t <session>` (never bare `kill-server`).
3. Remove residue: `rm -rf .audit*/ calls.log` (safe once the writer is dead).
4. Run `scripts/preflight.sh` to confirm disk/files are clean.

## 6. Pointers

- Canonical safety rules + isolated-harness pattern: **PRD §0 and §0.1**.
- System/operational safety (tmpfs, scoped scans, bounded harnesses): **PRD §0.1**.
- Testing harness rules: **PRD §15**.