# Fleet

Emacs-native orchestration of [ECA](https://eca.dev) agents: one commander per project fleet, independent
operators in their own native chats and systemd-owned processes, and Emacs as the single owner of durable
state, scheduling and the dashboard. Zero-token supervision — no model is ever invoked to poll or wait.

- **Start here:** [`quickstart.md`](quickstart.md)
- Design: [`docs/design.md`](docs/design.md) (the specification this repository implements)
- Verified ECA pair and every private assumption: [`docs/eca-compatibility.md`](docs/eca-compatibility.md)
- Recovery: [`docs/recovery.md`](docs/recovery.md) · Testing: [`docs/testing.md`](docs/testing.md)
- Contributor rules: [`AGENTS.md`](AGENTS.md)

## Layout

```
lisp/        fleet.el (commands) · fleet-paths · fleet-store · fleet-core · fleet-supervisor
             fleet-eca (only ECA-aware module) · fleet-runtime (systemd) · fleet-git · fleet-rpc · fleet-dashboard
bridge/      fleet_bridge.py — stdio MCP server / socket client / lease holder (stdlib only)
prompts/     canonical commander/operator doctrine and task-kind briefs
schema/      001.sql, rpc-v1.json, tools-v1.json
tests/       ERT suites, Python bridge tests, fake ECA server, recorded protocol traces
```

## Status

Verified on eca-emacs `20260529.1500` + eca `0.158.1`, Emacs 30.2, Arch Linux systemd 260. Deterministic
tests run with fakes; `make test-native` additionally runs one real commander boot through the MCP bridge
and the real systemd detached-child stop test. See `docs/testing.md` for exactly which tests are native.

## License

Not yet chosen by the author; no license is granted until a `LICENSE` file is added.
