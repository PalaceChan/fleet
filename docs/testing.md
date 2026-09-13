# Testing

[Safe commands](#existing-disposable-server-only) · [Coverage](#what-is-simulated-and-what-is-real) ·
[Native acceptance](#native-acceptance-and-historical-evidence) · [Recovery](recovery.md)

## Make targets: implementation, not owner-approved instructions

The [Makefile](../Makefile) currently does the following:

| Target | Actual behavior |
|---|---|
| `make test` | Python discovery, then `test-el`. |
| `make test-py` | `unittest` discovery relative to the repository working directory; no Emacs. |
| `make test-el` | Attempts `emacs -Q --daemon` startup, runs the ERT runner through `emacsclient`, then calls `server-stop`. |
| `make test-native` | Sets `FLEET_TEST_NATIVE=1` for a recursive `test-el`; real ECA/systemd tests can run. |
| `make compile` / `make lint` | Starts `emacs -Q --batch` for byte compilation / Checkdoc. |
| `make clean` | Removes Lisp bytecode and bridge/test Python caches. |

**Current owner policy: use `emacsclient` ONLY against existing servers. Never run tests in the editing
server.** Thus `test`, `test-el`, `test-native`, `server-start`, `compile`, and `lint` are not approved
recipes under this policy. Do not substitute the editing socket or set `EMACS=emacsclient` to work around it.

`TEST_SOCK` defaults to the fixed name `fleet-test-$UID`. `server-start` suppresses startup errors
(`|| true`), so an existing server at that name may be reused; `server-stop` sends `kill-emacs` to that
socket. A name alone proves neither isolation nor disposability. The native flag reaches a newly launched
daemon, not a reused server's environment. Also, the `test-el` output pipeline can
mask an `emacsclient` failure, and the runner returns failure counts as text rather than signaling them.
A successful `make` exit is therefore not sufficient evidence of passing tests. Do not use catch-all
process kills for cleanup.

## Existing disposable server only

First obtain the owner's confirmation that a **specific already-running named server** is disposable,
is not the editing server, and has no owner fleets or unrelated work. If none exists, stop and ask the
owner; these instructions neither launch nor shut down a server. The following Bash commands work from
any directory after setting `TEST_SOCKET` to that confirmed name:

```bash
: "${TEST_SOCKET:?Set TEST_SOCKET to the owner-confirmed existing disposable server name}"
emacsclient --alternate-editor=false --socket-name="$TEST_SOCKET" --eval \
  '(list :server server-name :pid (emacs-pid) :fleet-loaded (featurep (quote fleet)))'
```

Check that identity with the owner before proceeding. This query is not itself proof of disposability.
For the non-native suite, use the following command; update the explicit checkout path if using a
different worktree:

```bash
emacsclient --alternate-editor=false --socket-name="${TEST_SOCKET:?Confirm the disposable server first}" --eval '
(progn
  (setenv "FLEET_TEST_NATIVE" nil)
  (require (quote package))
  (package-initialize)
  (package-activate (quote eca))
  (require (quote eca))
  (setq load-prefer-newer t)
  (let ((root "/home/avelazqu/development/fleet"))
    (load (expand-file-name "tests/fleet-test-runner.el" root) nil t)
    (let ((summary (fleet-test-run-all root "^fleet-")))
      (unless (string-match "^PASSED [0-9]+  FAILED \\([0-9]+\\)  SKIPPED [0-9]+  TOTAL \\([0-9]+\\)$" summary)
        (error "Unrecognized Fleet ERT summary: %s" summary))
      (let ((failed (string-to-number (match-string 1 summary)))
            (total (string-to-number (match-string 2 summary))))
        (unless (and (= failed 0) (> total 0))
          (error "Fleet ERT did not pass: %s" summary)))
      summary)))'
```

Keep the `emacsclient` exit status: do not pipe it through an unchecked formatter. An unexpected ERT
result, empty selection, or malformed summary signals an error to the client. Successful output still
needs review for skipped tests; it is not native acceptance.

The native flag is cleared **inside the server**: unsetting it only in the client shell does not change
an existing Emacs process's environment. The `^fleet-` selector avoids unrelated registered ERT tests;
[fleet-test-run-all](../tests/fleet-test-runner.el) nevertheless reloads every Fleet Lisp source and every
`tests/*-tests.el`, so this is unsafe in the editing server even with temporary roots. Native tests are
skipped by [fleet-test-native-p](../tests/fleet-test-helpers.el) unless the server environment enables them.
`--alternate-editor=false` fails rather than launching a fallback when the named server is absent.

Python bridge tests alone, from any directory (no ECA model/server launch):

```bash
PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -B -m unittest discover \
  -s /home/avelazqu/development/fleet/tests \
  -p 'test_bridge.py' -v
```

This runs [test_bridge.py](../tests/test_bridge.py), not fixture probes. It uses temporary files, local
sockets, bridge subprocesses, and lease helpers; “non-native” does not mean “no processes or filesystem I/O.”

## What is simulated and what is real

| Suite | Real boundary exercised | Fake or excluded boundary |
|---|---|---|
| Paths / store | Files, canonical paths, SQLite and migrations in temporary roots | No model calls. |
| Runtime (non-native) | Verdict source and parsing of a fake `systemctl` executable's output | Service/cgroup evidence is synthetic, not a real stop proof. |
| Git | Git subprocesses, temporary repos/worktrees, file remotes, retention refs and refusal checks | No hosted remote or live owner worktree acceptance. |
| ECA adapter (non-native) | Fleet source and installed `eca-emacs` frontend with [fake_eca.py](../tests/fake_eca.py) | Scripted server protocol, not native ECA/model behavior. |
| Core / supervisor / RPC / dashboard / telemetry | Owning-layer source; SQLite/files/Git and, where covered, real local RPC sockets and `flock` lease helper | ECA/runtime seams replaced by doubles in fake-backed scenarios. |
| Python bridge | Bridge process, NDJSON socket traffic and real `flock` | Fake Fleet socket server. |
| Native opt-in cases | Real user systemd, native ECA/model; end-to-end case also uses lease, socket and MCP bridge | Narrow smoke scenarios, not full acceptance. |

[fleet-test-with-roots](../tests/fleet-test-helpers.el) supplies disposable roots where used;
[fleet-test-with-fakes](../tests/fleet-test-fakes.el) replaces `fleet-eca-start`, `fleet-eca-submit`,
`fleet-eca-request-cancel`, `fleet-runtime-stop`, and `fleet-runtime-inspect`. Not every test uses both
helpers: some are pure checks and others intentionally exercise subprocess, frontend, file or socket
boundaries. Fakes establish regression coverage at those seams, not native safety certification.

## Native acceptance and historical evidence

**Every native ECA/provider or systemd probe requires explicit owner opt-in, a confirmed disposable test
server where applicable, and no active owner fleets.** Isolation of test roots does not isolate the user's
systemd manager, installed frontend/global state, provider account or costs. Agree on exact scope and
runtime identities, bounded waits and scoped cleanup first; never use live owner fleets as fixtures.
Do not enable native tests merely to refresh documentation.

[probe.py](../tests/fixtures/eca/probe.py) has top-level side effects: importing it or asking for `--help`
still creates temporary roots, launches native ECA, initializes a session and writes output; import can
also take the default paid prompt path. It is not a passive inspection tool. Read its source rather than
executing it for discovery. [systemd-spike.sh](../tests/fixtures/eca/systemd-spike.sh) is likewise a native
experiment, not a prerequisite for reading these docs. Recorded traces live in
[tests/fixtures/eca](../tests/fixtures/eca/); protocol context is in [ECA compatibility](eca-compatibility.md).

**Historical report, September 8, 2026 — not a current run:** the prior acceptance record reported passing
deterministic ERT/Python suites and the native cases `fleet-runtime-native-detached-child-stopped-with-unit`,
`fleet-eca-native-minimal-turn`, and `fleet-native-commander-boot-tools-and-verified-stop`. The
[last case's source](../tests/fleet-native-tests.el) asserts authenticated commander tool-list fetching,
Fleet tool advertisement and a stopped verdict; whether the model actually calls a Fleet tool is reported,
not required. These observations do not establish today's installed versions or test totals.

The prior owner checkpoint also recorded successful unattended study/change rehearsals and post-restart
reconciliation (September 9–10, 2026). Those are historical observations, not a reproducible full acceptance
suite; they do not certify the source-review findings in [known gaps](known-gaps.md).

### Pending native acceptance

Record redacted evidence for these checks in an explicitly authorized disposable scenario; do not use the
next real owner fleet as a test fixture. The following remain unverified as native acceptance:

- **Tool exclusion:** operator `tool/serverUpdated` for server `eca` advertises neither `ask_user` nor
  `spawn_agent`; commander's human question channel remains available. Overlay construction and absence
  of calls in a transcript are not proof of exclusion.
- **Selection agreement:** requested model/variant, wire `chat/prompt`, server configuration announcement,
  runtime record and chat/dashboard display agree, including default variant selection and replacement.
  Use wire evidence, not undocumented ECA chat-cache parsing.
- **Admission feedback:** first prompt on a free lane says sent; a mid-turn prompt says queued; held and
  unknown delivery remain distinguishable. No extra concurrent prompt is dispatched.
- **Empty turns:** an accepted turn with no observed output/tool/error gets at most one automatic resend;
  a second empty result records `turn-empty` and surfaces give-up. Stopped, unknown, or observed-work turns
  are not retried by this path. Missing notifications still limit what this proves about side effects.
- **Model policy and fallback:** with a policy file present, a task created without `model` runs on the
  rule's model and the boot message shows the policy; an ask-first model is refused until `owner_approved`;
  after a barren turn on a model with a configured fallback, the runtime's next `chat/prompt` carries the
  fallback model in the same chat (history kept), the runtime row and dashboard agree, and a `model-fallback`
  event exists. Use wire evidence, not undocumented ECA chat-cache parsing.
- **Artifact roots:** a bare name that exists under the task's `workspace/` is stored as `workspace/<name>`
  and verifies using the same root. Existing deterministic tests are not native operator acceptance.
- **Cleanup refusal:** a change task with dirty/untracked/ignored paths is refused with the affected paths
  named, without removal. Preserve work; do not manufacture dirt in an owner worktree for this check.

See [authority and interface](known-gaps.md#authority-and-interface),
[fail-closed evidence](known-gaps.md#fail-closed-evidence), and
[verification and diagnostics](known-gaps.md#verification-and-diagnostics).

## Writing tests

Add regressions at the owning layer. Use `fleet-test-wait-for` for bounded asynchronous predicates rather
than blind delays, and `fleet-test-should-fail` to assert structured refusal codes. Review the source and
isolation boundary before executing a new case. For restart/delivery limitations, see
[recovery and delivery gaps](known-gaps.md#recovery-and-delivery) and [Recovery](recovery.md).
