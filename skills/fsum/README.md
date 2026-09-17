# fsum skill

Read-only Fleet bearings for the root commander: `/fsum` gives one screen of supervisors, moving work and
what needs the user. `SKILL.md` is the ECA skill (contract, output shape, guardrails); this file covers
installation and development.

## Layout

| Path | Role |
|---|---|
| `SKILL.md` | ECA skill loaded by the commander |
| `scripts/fleet-read.el` | Read helper: `fleet-read-bearings` (plist, `fleet-read-schema` 1), `fleet-read-bearings-json`. Shared with `/frev` by path or copy. |
| `scripts/fsum.el` | Formatter and entry point: `fsum-render`, `fsum-bearings` (Markdown string). Loads `fleet-read.el` from its own directory. |
| `test/fsum-tests.el` | ERT suite over a faked store API with a mutation spy; no live fleet, no SQLite, no ECA. |

## How it reads

The scripts are loaded into the **already-running Fleet owner Emacs** with `emacsclient` and call only
installed Fleet read functions against the **already-open** store handle (`fleet-supervisor--store`):
`fleet-core-fleet`, `fleet-store-get`, `fleet-store-lieutenants`, `fleet-store-snapshot` (one fleet at a
time, never the unscoped all-fleets read) and `fleet-config-lieutenants`; `fleet-dashboard-*` label
functions are used when present. They never load Fleet's Lisp themselves, so the observed behaviour is
that of whatever Fleet revision the owner has loaded — not the checkout the skill lives in. A store that
is not open is reported, not opened.

Configured-but-uncreated lieutenants are listed from the owner's `config.json` and marked
`declared in config, not created`; `fleet-core-ensure-lieutenants` is never called.

## Install (owner step, separate from merging)

Skills on this host are symlinks into a checkout, e.g. `~/.config/eca/skills/elpy → …/dotfiles/…/elpy`.
Wire this one the same way once the branch is merged (or pointing at a worktree while trying it):

```bash
ln -s ~/development/fleet/skills/fsum ~/.config/eca/skills/fsum
```

ECA discovers `SKILL.md` on the next skill scan/session. The commander then loads the bridge with the path
in `SKILL.md`; if you install elsewhere, that path is the only thing to change. A commander already running
does not see a newly installed skill until its skills are reloaded (a new commander boot does).

## Tests

Run in a **disposable** Emacs server only — never the editing server, never with owner fleets (see
`docs/testing.md`). Convention: the owner starts `emacs -Q --daemon=fleet-test`. Then:

```bash
timeout 120 emacsclient --alternate-editor=false --socket-name=fleet-test --eval '
(progn
  (load "/home/avelazqu/development/fleet/skills/fsum/test/fsum-tests.el" nil t)
  (let ((stats (ert-run-tests-batch "^fsum-test-")))
    (format "PASSED %d FAILED %d SKIPPED %d TOTAL %d"
            (ert-stats-completed-expected stats) (ert-stats-completed-unexpected stats)
            (ert-stats-skipped stats) (ert-stats-total stats))))'
```

Replace the checkout path with your worktree when developing. The suite fakes the five read functions and
arms a denylist spy (`fleet-core-ensure-lieutenants`, `fleet-store-exec/insert/update`,
`fleet-supervisor-send`, `fleet-core-start-task`, `fleet-dashboard`, …): a test fails if the reader calls
anything outside the read allowlist. It passes with or without Fleet loaded in the test server; with Fleet
loaded, dashboard labels such as `live/idle` replace the raw runtime lifecycle.

Byte-compile check (same server): `(byte-compile-file "/path/to/skills/fsum/scripts/fsum.el")`.

## Caveats

- Output of `emacsclient --eval` is an Elisp string literal; `SKILL.md` shows the unescape step.
- Observation is sequential reads, not an atomic census; the heading's time and the `Coverage` notes say
  what was and was not seen.
- No historical comparison, trend, or "since last summary" store — by design.
