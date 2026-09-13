[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

# Fleet

Emacs-native orchestration of [ECA](https://eca.dev) agents: one commander per project fleet, independent
operators in their own native chats and systemd-owned processes, and Emacs as the single owner of durable
state, scheduling and the dashboard. Zero-token supervision — no model is ever invoked to poll or wait.

- **Operate Fleet:** [`quickstart.md`](quickstart.md) (install, commands, normal workflows)
- **Work on Fleet:** [`AGENTS.md`](AGENTS.md), then [`docs/development.md`](docs/development.md) as needed
- **Before unattended/recovery work:** [`docs/known-gaps.md`](docs/known-gaps.md) (limitations and closure criteria)
- Architecture and rationale: [`docs/design.md`](docs/design.md) — intended contracts, not proof of implementation
- ECA wire evidence and private integration: [`docs/eca-compatibility.md`](docs/eca-compatibility.md)
- Recovery: [`docs/recovery.md`](docs/recovery.md) · Verification: [`docs/testing.md`](docs/testing.md)

The repository owns engineering guidance; Git owns history. No external session checkpoint is required.
Owner preferences and private runtime follow-ups stay outside source; determine live status by inspection,
not by a remembered commit, process ID, or model selection.

## Layout

```
lisp/        fleet.el (commands) · fleet-paths · fleet-store · fleet-core · fleet-supervisor
             fleet-eca (only ECA-aware module) · fleet-runtime (systemd) · fleet-git · fleet-rpc · fleet-dashboard · fleet-telemetry
bridge/      fleet_bridge.py — stdio MCP server / socket client / lease holder (stdlib only)
prompts/     canonical commander/operator doctrine and task-kind briefs
schema/      ordered SQL migrations (001.sql, 002.sql), rpc-v1.json, tools-v1.json
tests/       ERT suites, Python bridge tests, fake ECA server, recorded protocol traces
```

## Status

Recorded development evidence uses eca-emacs `20260529.1500` + eca `0.158.1`/`0.159.0`, Emacs 30.2,
Arch Linux systemd 260; these are historical reference versions, not pins or a statement about this host.
Deterministic suites use temporary roots, real local components and fake ECA/systemd seams; native suites
also exercise real model turns, the MCP bridge and service stop. See [testing](docs/testing.md) for the
approved workflow and exact coverage, and [known gaps](docs/known-gaps.md) for unresolved safety/interface
findings. Doctor is a partial dependency/diagnostic check, not certification of unattended readiness.

## Install

Load straight from the source tree with `use-package` (no copy into `~/.emacs.d/lisp` needed):

```elisp
(use-package fleet
  :if (file-directory-p (expand-file-name "~/development/fleet/lisp"))
  :load-path "~/development/fleet/lisp"
  :commands (fleet-dashboard fleet-new fleet-park fleet-task-close fleet-destroy fleet-doctor
             fleet-watch-start fleet-watch-stop
             fleet-commander-stop fleet-commander-replace fleet-commander-set-model
             fleet-install-mcp fleet-timeline fleet-stats)
  :bind (("C-c h f" . fleet-dashboard))
  :custom
  (fleet-development-root "~/development"))
```

## License

[MIT](LICENSE).
