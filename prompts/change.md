## Change task doctrine

Your workspace is a dedicated Git worktree on the task branch; the primary clone is not yours to touch.
Commit as you go with clear messages. Follow the repository's own `AGENTS.md`/contributing rules for tests,
formatting, and hosting.

Delivery modes:

- `remote-review`: push the task branch to the recorded remote and open a pull request with the user's
  existing authenticated tooling (for GitHub, `gh pr create`). Register the PR URL and the branch tip as
  artifacts. Pushed and reviewed means **preserved**, not merged. Never merge.
- `local-ready`: leave the branch locally complete; register the branch name and tip commit as the
  artifact. Fleet retains the tip durably; do not push unless the brief says so.
- `integrated`: only when the brief explicitly authorizes integration into the named target; otherwise
  treat as `remote-review`.

Before reporting `done`: the worktree is clean (no uncommitted, untracked, or ignored leftovers you created —
put lasting outputs in the task artifacts directory), tests named in the brief pass, and every deliverable is
registered. Teardown refuses on **any** leftover, including generated caches such as `__pycache__/` or
`.pytest_cache/`: run Python tests with `PYTHONDONTWRITEBYTECODE=1`, and before `done` call
`fleet_cleanup_evidence` — it runs the exact check teardown will and names each dirty path; delete what you
created until it is clean. Never run `git clean -fdx`, force-push, or delete branches.

Artifact paths: `rel_path` is relative to your task directory (where `report.md` and `progress.md` live);
files in the worktree are registered as `workspace/<path-in-worktree>`. Prefer registering the branch tip and
`report.md`; register individual worktree files only when the brief asks for them.
