[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

# Fleet

Emacs-native orchestration of [ECA](https://eca.dev) agents: one commander per project fleet, independent
operators in their own native chats and systemd-owned processes, and Emacs as the single owner of durable
state, scheduling and the dashboard. Zero-token supervision — no model is ever invoked to poll or wait.

- **Start here:** [`quickstart.md`](quickstart.md)
- Design: [`docs/design.md`](docs/design.md) (the specification this repository implements)
- ECA wire facts and every private assumption: [`docs/eca-compatibility.md`](docs/eca-compatibility.md)
- Recovery: [`docs/recovery.md`](docs/recovery.md) · Testing: [`docs/testing.md`](docs/testing.md)
- Contributor rules: [`AGENTS.md`](AGENTS.md)

## Layout

```
lisp/        fleet.el (commands) · fleet-paths · fleet-store · fleet-core · fleet-supervisor
             fleet-eca (only ECA-aware module) · fleet-runtime (systemd) · fleet-git · fleet-rpc · fleet-dashboard · fleet-telemetry
bridge/      fleet_bridge.py — stdio MCP server / socket client / lease holder (stdlib only)
prompts/     canonical commander/operator doctrine and task-kind briefs
schema/      001.sql, rpc-v1.json, tools-v1.json
tests/       ERT suites, Python bridge tests, fake ECA server, recorded protocol traces
```

## Status

Developed against eca-emacs `20260529.1500` + eca `0.158.1`/`0.159.0`, Emacs 30.2, Arch Linux systemd 260;
ECA versions are not pinned (`fleet-doctor` checks dependencies, not version numbers). Deterministic
tests run with fakes; `make test-native` additionally runs one real commander boot through the MCP bridge
and the real systemd detached-child stop test. See `docs/testing.md` for exactly which tests are native.

## Install

Load straight from the source tree with `use-package` (no copy into `~/.emacs.d/lisp` needed):

```elisp
(use-package fleet
  :load-path "~/development/fleet/lisp"
  :after eca
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
