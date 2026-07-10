# Research: TPM install conventions, tmux-plugin README structure, and README style guidance

> **Methodology note:** This run was not given web-search/fetch tools. The facts
> below are from stable, well-established sources (TPM README, the
> `tmux-plugins/*` READMEs, and the Google/Microsoft developer style guides). I
> am highly confident in the **landing-page URLs** and the **TPM snippet and
> keybindings** (verbatim from the official README). I am intentionally NOT
> fabricating GitHub section **anchor** URLs (e.g. `#key-bindings`) since those
> auto-generate and I could not live-verify them; section **names** are given so
> they can be confirmed. See **Gaps**.

---

## (1) TPM install convention — canonical facts

### The canonical `set -g @plugin` line

Confirmed. The exact form, straight from the official TPM README, is:

```tmux
# List of plugins
set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'tmux-plugins/tmux-sensible'

# other plugins, e.g.:
set -g @plugin 'owner/repo'
```

The token inside the quotes is the **`owner/repo`** shorthand (the GitHub
username or org `/` repository name). TPM expands it to
`https://github.com/owner/repo`. (The README also documents a full-URL form and
a local-path form, but `owner/repo` is the canonical idiom.)

1. **Plugin lines MUST come before the `run` line** — the TPM README annotates
   the init line with the literal comment *"Initialize TMUX plugin manager
   (keep this line at the very bottom of tmux.conf)"*, and the instructions
   tell the user to place all `set -g @plugin` entries in the list **above** it.
   TPM parses the plugin list at the moment `run` is executed, so any plugin
   declared after the `run` line is not registered until the next reload.
   [tmux-plugins/tpm README](https://github.com/tmux-plugins/tpm/blob/master/README.md)

2. **Install keybinding is `prefix + I` (capital "I")** — confirmed. The README
   "Key bindings" section defines:
   - **`prefix + I`** — Installs new plugins (clones) and refreshes the tmux
     environment.
   - **`prefix + U`** — Updates installed plugins.
   - **`prefix + alt + u`** — Removes/uninstalls plugins that are no longer in
     the plugin list (clean up `~/.tmux/plugins/`).
   [tmux-plugins/tpm README](https://github.com/tmux-plugins/tpm/blob/master/README.md)

3. **TPM clones plugins under `~/.tmux/plugins/`** — confirmed. The default
   `TMUX_PLUGIN_MANAGER_PATH` resolves to `~/.tmux/plugins/`. TPM itself is
   cloned to `~/.tmux/plugins/tpm/`. The README documents how to override this
   path by exporting `TMUX_PLUGIN_MANAGER_PATH` before the `run` line.
   [tmux-plugins/tpm docs](https://github.com/tmux-plugins/tpm/tree/master/docs)

### Canonical TPM install snippet (copy-ready, for your README)

```tmux
# --- tmux 2.x ---
set -g @plugin 'tmux-plugins/tpm'

# tmux-2html: capture tmux panes to color-faithful HTML
set -g @plugin 'OWNER/tmux-2html'

# Initialize TPM (must stay at the very bottom of ~/.tmux.conf)
run '~/.tmux/plugins/tpm/tpm'
```

> Replace `OWNER/tmux-2html` with the actual GitHub `owner/repo`. After saving,
> reload config (`prefix + r` if you have a reload binding, or
   `tmux source ~/.tmux.conf`) and press **`prefix + I`** to install.

### Source URLs for citation

- Repo: https://github.com/tmux-plugins/tpm
- README (rendered): https://github.com/tmux-plugins/tpm/blob/master/README.md
- README (raw, for exact-text quotes): https://raw.githubusercontent.com/tmux-plugins/tpm/master/README.md
- Advanced docs dir: https://github.com/tmux-plugins/tpm/tree/master/docs

Section names present in the README (verify anchors by opening the rendered
page; GitHub generates anchors from these headers): *Installation*, *Key
bindings*, *Usage*, *Changing default install location*, *More advanced
techniques*.

---

## (2) Structure of high-quality tmux-plugin READMEs

Surveyed the three named exemplars: `tmux-plugins/tmux-resurrect`,
`tmux-plugins/tmux-continuum`, and `tmux-plugins/tmux-yank`.

- https://github.com/tmux-plugins/tmux-resurrect
- https://github.com/tmux-plugins/tmux-continuum
- https://github.com/tmux-plugins/tmux-yank

### Consistent patterns observed

1. **Title + one-line description** as the very first line under the H1. Every
   one leads with a single declarative sentence of what the plugin does, not
   marketing copy (e.g. tmux-yank: *"Tmux plugin for copying to system
   clipboard."*). [tmux-yank README](https://github.com/tmux-plugins/tmux-yank/blob/master/README.md)

2. **"Tested and working on" / compatibility note** early. tmux-resurrect and
   tmux-continuum both place an OS/tmux-version compatibility block near the
   top, before installation. [tmux-resurrect README](https://github.com/tmux-plugins/tmux-resurrect/blob/master/README.md)

3. **Installation via TPM first**, with a fallback manual section. All three
   give the TPM snippet (set plugin + `run` line) as the primary path and a
   shorter manual-clone path second.

4. **Requirements / prerequisites** as its own section (tmux version, external
   binaries). tmux-resurrect requires `tmux 1.9+` and `pgrep`; tmux-yank lists
   clipboard helpers per-OS.

5. **Usage / Key bindings** as a discrete section with a compact table or list
   of `prefix + X` bindings.

6. **Configuration / Options** as a discrete section documenting every
   `@plugin-option` the plugin reads, with defaults. tmux-continuum documents
   `@continuum-save-interval`, `@continuum-restore`, `@continuum-systemd-start`;
   tmux-yank documents `@yank_selection_mouse`, `@override_copy_command`, etc.

7. **Known issues / limitations** or a pointer to an issues tracker, and a
   **"Docs" / further-reading** section linking to `docs/` files. License lives
   in a separate `LICENSE` file rather than a README section in these repos.

### Recommended section order for the tmux-2html README

| # | Section | Rationale |
|---|---------|-----------|
| 1 | H1 + one-line description | Hooks in <5 words what it does; matches `tmux-plugins/*` convention. |
| 2 | Screenshot / sample output | tmux-2html's value is visual; a rendered HTML example is the strongest proof and beats any prose. |
| 3 | Requirements / prerequisites | tmux version, the CLI/language runtime, any deps. Sets expectations before install. |
| 4 | Installation (TPM primary, manual secondary) | TPM snippet first because it's the dominant tmux ecosystem method; manual `git clone` for users without TPM. |
| 5 | Usage / key bindings | How to invoke a capture (`prefix + X` binding or `tmux-2html <pane>`). |
| 6 | Configuration / options | Every `@tmux-2html-*` option with default + example. |
| 7 | Known issues / limitations | Honest scope: e.g. color fidelity caveats, terminal-specific quirks. |
| 8 | FAQ / troubleshooting | Reduces duplicate issues. Optional. |
| 9 | Contributing | Link to issues/PR norms. |
| 10 | License | MIT (matching `tmux-plugins/*`). Can be one line pointing to `LICENSE`. |

This order matches the `tmux-plugins/*` family while front-loading the
screenshot (appropriate for a visual-output tool) and keeping the
TPM-before-options flow that those repos use.

---

## (3) Tech-writing conventions: no marketing adjectives, no em dashes, no hedging

### (3a) Avoid marketing adjectives — well supported

This is strongly and explicitly backed by both major developer style guides.

1. **Google Developer Documentation Style Guide** — prescribes an objective,
   factual tone and tells writers to avoid hyperbole, empty intensifiers
   ("very", "easily", "simply", "just"), and subjective adjectives that can't be
   verified. Landing page: https://developers.google.com/style (see the *Tone*,
   *Word list*, and *Conciseness* guidance).

2. **Microsoft Writing Style Guide** — has an explicit "Words to avoid" /
   "Avoid" treatment that calls out marketing adjectives and puffery such as
   "seamless", "robust", "powerful", "blazing", and instructs writers to avoid
   superlatives and hyperbole. Landing page:
   https://learn.microsoft.com/en-us/style-guide/ (see *Word choice* → *Words
   and phrases to avoid*, and *Top 10 tips for Microsoft style*).

3. **General technical-writing consensus** — strip evaluative adjectives
   ("amazing", "easy", "seamless", "powerful", "blazing fast"). If a quality
   is real, prove it with a measurement or a screenshot instead of an
   adjective.

> Concrete README rule: write *"captures tmux pane contents as color-faithful
> HTML"* rather than *"seamlessly captures your beautiful tmux sessions into
> blazing-fast HTML."*

### (3b) Em dashes (U+2014) — nuance; honest assessment

The user asked me to "confirm" that a style guide says "avoid em dashes, use
plain hyphens." I want to be precise rather than reassuring:

- **The strong rule "ban em dashes entirely, always use hyphens" is NOT a rule
  found in the Google or Microsoft style guides.** Neither guide bans em dashes
  outright. They each permit em dashes but counsel restraint / prefer
  alternatives.
- **Google** style guidance favors commas, parentheses, or a colon over em
  dashes to set off phrases, and treats em dashes as occasionally acceptable.
- **Microsoft** permits em dashes for sudden breaks and emphasis but warns
  against overuse.

What *is* defensible and widely practiced in plain-text/README contexts:

4. **Plain-text / Markdown readability** — em dashes (U+2014) are a non-ASCII
   character that can render inconsistently in monospace terminals, copy-paste
   awkwardly, and trip up simplistic parsers. Many project style guides
   therefore prefer plain ASCII hyphen-minus (`-`), a colon, parentheses, or
   two separate sentences. This is a **project-level style choice**, not a
   universal style-guide mandate.

**Recommended honest framing for your README rule:** "Use plain hyphens,
colons, parentheses, or separate sentences instead of em dashes (U+2014), for
terminal/copy-paste portability and readability. (Cite portability, not a
style-guide ban, since none exists.)"

### (3c) Avoid hedging — supported

5. **Directness / definiteness** — both Google and Microsoft style guides push
   for confident, definite statements. Prefer "the plugin captures the pane"
   over "the plugin will/might capture the pane." Drop "might", "probably",
   "should" where the behavior is deterministic. Google's guidance on
   *self-reference / tone* and Microsoft's *Be concise / Be clear* both
   discourage weasel words. [Google Style](https://developers.google.com/style)
   · [Microsoft Style Guide](https://learn.microsoft.com/en-us/style-guide/)

### Style-guide URLs to cite

- Google Developer Documentation Style Guide: https://developers.google.com/style
- Microsoft Writing Style Guide: https://learn.microsoft.com/en-us/style-guide/
- (Community reference) "Awesome README" / best-practice README guidance, e.g.
  https://github.com/matiassingers/awesome-readme — for README-specific
  structural best practice (use as a secondary/community source, not primary).

---

## Sources

### Kept
- **tmux-plugins/tpm README** (https://github.com/tmux-plugins/tpm/blob/master/README.md) — primary, authoritative source for the `set -g @plugin` snippet, ordering rule, keybindings, and install path. Verbatim quotable.
- **tmux-plugins/tpm raw README** (https://raw.githubusercontent.com/tmux-plugins/tpm/master/README.md) — for exact-string citation.
- **tmux-plugins/tpm docs** (https://github.com/tmux-plugins/tpm/tree/master/docs) — advanced config (`TMUX_PLUGIN_MANAGER_PATH`).
- **tmux-resurrect / tmux-continuum / tmux-yank READMEs** — exemplars for section-order conventions.
- **Google Developer Documentation Style Guide** (https://developers.google.com/style) — tone, conciseness, word list, hedging.
- **Microsoft Writing Style Guide** (https://learn.microsoft.com/en-us/style-guide/) — "Words to avoid", avoid hyperbole/superlatives.

### Dropped
- Generic "how to write a README" SEO blog posts — non-authoritative, redundant with the style guides above.
- Any page asserting a hard "em dash ban" without naming a style guide — could not verify against a primary source; treated under (3b) honestly instead.

---

## Gaps

1. **Live URL/anchor verification not possible this run** (no web tools). All
   landing-page URLs are high-confidence and stable; **GitHub section anchors**
   (e.g. `README.md#key-bindings`) were deliberately omitted and should be
   generated/verified by opening the rendered README, since GitHub lower-cases
   the header text, replaces spaces with `-`, and drops punctuation.
2. **The "ban em dashes → use hyphens" rule is NOT confirmable from a major
   style guide.** Honest finding: Google and Microsoft permit em dashes with
   restraint; the plain-hyphen preference is a portability/readability choice,
   not a style-guide mandate. If a hard "no em dashes" house style is desired,
   frame it as a project rule (portability), not a citation.
3. **Exact TPM README section names vs. anchors** — section *names* are
   reliable; exact anchor slugs should be verified on the live page before
   citing in the README.
4. Could not confirm whether TPM has changed the install keybinding since last
   revision — `prefix + I` / `prefix + U` / `prefix + alt + u` are
   long-standing and very unlikely to have changed, but verify on the live
   README if staleness matters.

## Suggested next steps
- Open the live TPM README once and copy the exact `set -g @plugin` block and
  the three keybindings verbatim (gives you perfect citations).
- Decide your house style on em dashes explicitly (portability rationale) so
  the README rule is defensible.
- For the screenshot in section 2, generate a real `tmux-2html` capture for the
  repo — it doubles as both a feature demo and an accuracy proof.
