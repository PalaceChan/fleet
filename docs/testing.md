# Testing

```
make test          # Python bridge tests + ERT in a dedicated disposable Emacs server
make test-py       # Python only (unittest)
make test-el       # ERT only; starts `emacs -Q --daemon=fleet-test-$UID`, runs, stops it
make test-native   # ERT with FLEET_TEST_NATIVE=1 (real ECA pair, real user systemd; costs model turns)
make compile       # byte-compile lisp/
```

ERT runs through `emacsclient` against a **dedicated** daemon, never the editing Emacs. Every test uses
`fleet-test-with-roots` (fresh temporary data/cache/config/runtime/development roots) and, unless native,
`fleet-test-with-fakes` which replaces `fleet-eca-start/submit/request-cancel` and
`fleet-runtime-stop/inspect` with in-memory doubles that cannot launch anything.

## What is simulated and what is real

| Suite | Real | Simulated |
|---|---|---|
| `fleet-paths-tests` | filesystem | — |
| `fleet-store-tests` | SQLite | — |
| `fleet-runtime-tests` | fake `systemctl` script for parsing/verdicts; **native**: `systemd-run` + detached child + `systemctl --user stop` | — |
| `fleet-git-tests` | real Git in temp repos (worktrees, remotes via file://, squash/rebase, retention refs, native refusals) | — |
| `fleet-eca-tests` | the installed eca-emacs frontend code, `tests/fake_eca.py` speaking the recorded protocol; **native**: one real model turn | server behaviour scripted from recorded traces |
| `fleet-core-tests`, `fleet-supervisor-tests`, `fleet-rpc-tests`, `fleet-dashboard-tests` | store, Git, RPC socket, lease helper (real flock) | ECA connection and systemd doubles |
| `test_bridge.py` | bridge process, fake NDJSON socket server, real flock | Fleet server |
| `fleet-native-tests` (**native**) | everything: lease, socket, systemd unit, native ECA, MCP bridge, one model turn, verified stop | — |

Fixtures: `tests/fixtures/eca/*.json` are redacted raw traces with provenance; `probe.py` regenerates them
against a server; `systemd-spike.sh` reproduces the child-lifetime evidence.

## Acceptance evidence (2026-09-08, eca-emacs 20260529.1500 + eca 0.158.1)

- 97 deterministic ERT tests + 9 Python tests pass.
- Native: `fleet-runtime-native-detached-child-stopped-with-unit`, `fleet-eca-native-minimal-turn`,
  `fleet-native-commander-boot-tools-and-verified-stop` pass. The last asserts that the bridge fetched the
  commander's tool list over the socket with the commander credential and that ECA advertised the Fleet
  tools to the model, then a `stopped` verdict; whether the model calls a tool in its boot turn is only
  reported (it did in two of three runs).
- Not yet exercised natively: `disabledTools` effect on `eca__spawn_agent` and, for operators,
  `eca__ask_user`. Tracked in `docs/eca-compatibility.md`.

## Writing tests

Add regression tests at the owning layer. Async code is tested with `fleet-test-wait-for` (event loop until a
predicate holds, bounded) — never `sleep-for` on real delays. Refusal paths are first-class: assert the
`fleet-error` code with `fleet-test-should-fail`.
