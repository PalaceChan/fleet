# Testing

[Safe commands](#start-or-reuse-the-fleet-test-server) · [Coverage](#what-is-simulated-and-what-is-real) ·
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

**Agent rule: use `emacsclient` for Emacs operations; the sole launch exception is exactly
`emacs -Q --daemon=fleet-test`, as described below.** This does not approve `test`, `test-el`, `test-native`,
`server-start`, `compile`, or `lint`; do not substitute the editing socket or set `EMACS=emacsclient` to work
around the Make targets.

`TEST_SOCK` defaults to the fixed name `fleet-test-$UID`. `server-start` suppresses startup errors
(`|| true`), so an existing server at that name may be reused; `server-stop` sends `kill-emacs` to that
socket. A name alone proves neither isolation nor disposability. The native flag reaches a newly launched
daemon, not a reused server's environment. Also, the `test-el` output pipeline can
mask an `emacsclient` failure, and the runner returns failure counts as text rather than signaling them.
A successful `make` exit is therefore not sufficient evidence of passing tests. Do not use catch-all
process kills for cleanup.

## Start or reuse the `fleet-test` server

Use only the `fleet-test` socket for ERT; never touch the editing socket `server` or any other socket. The
only permitted daemon launch is exactly `emacs -Q --daemon=fleet-test`: no other socket name, init file,
Emacs launch, or Make `server-start`/test target is approved. Before launching, check
`ls "$XDG_RUNTIME_DIR/emacs/"` and query `fleet-test` with `--alternate-editor=false` using the identity
query below. If it answers, do not start another daemon; use it only if the owner-isolation check below
passes. If that check fails or cannot be made, do not use or kill the daemon; report to whoever coordinates
the work. If the socket file exists but nothing answers, treat it as stale: remove only
`"$XDG_RUNTIME_DIR/emacs/fleet-test"`, then launch. If no server answers and no stale socket needs removal,
launch exactly the command above. The launcher forks and prints "Done" immediately; that is normal.

Immediately after launching, run the identity query below, record its full output (`:server`, `:pid`, and
`:fleet-loaded`), and keep the PID. Apply the same owner-isolation check to launched and reused daemons
before using them. If a launched daemon fails or cannot pass that check, do not use or kill it; report.
`:fleet-loaded` is recorded but is not evidence either way; prior test runs load Fleet.

Always clean up a daemon you started that passed the check when your runs are done, including after a failed
or wedged run: `timeout 10 emacsclient --socket-name=fleet-test --eval '(kill-emacs)'`. If that does not
answer, first confirm that the recorded PID is still the daemon you launched, then `kill <recorded-pid>`;
never use a process-name pattern (`pkill`/`killall`). Confirm afterwards that
`"$XDG_RUNTIME_DIR/emacs/fleet-test"` is gone. If you reused someone else's daemon, leave it running.

**Reuse caveat (observed 2026-09-13):** the runner reloads every source and test file, and a second
full-suite run in the same daemon inherited timers and lease-helper processes from the first: a
pre-existing supervisor test failed and the following lease test hung until interrupted (`kill -USR2
<pid>` breaks a wedged eval without killing the server). The same suite passed 137/137 on a fresh daemon.
Observed again 2026-09-15: after two or three targeted runs that start fake commanders, a fake-backed
supervisor test that had just passed ran for minutes on the reused daemon, and a second `USR2` while
wedged terminated the server. Also, `fleet-dash-jump`'s `recenter` errors in a frameless daemon; tests
stub it. Use a **fresh daemon for full-suite runs**. If the current daemon is yours, clean it up as above
and launch a fresh one; if it belongs to someone else, do not kill it or start a second daemon—report to
whoever coordinates the work. Treat targeted reuse as a convenience for one or two runs, each wrapped in
`timeout` on the `emacsclient` call so a wedge is visible.
The following Bash commands use only `TEST_SOCKET=fleet-test`. After listing the socket directory above,
run this query before any launch. `--alternate-editor=false` makes it fail rather than starting a fallback:

```bash
: "${TEST_SOCKET:?Set TEST_SOCKET to fleet-test after checking the socket}"
test "$TEST_SOCKET" = fleet-test || { echo "Only TEST_SOCKET=fleet-test is allowed" >&2; exit 2; }
OWNER_PID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["emacsPid"])' \
  "$HOME/.local/share/fleet/owner.json") || exit
printf 'Owner emacsPid: %s\n' "$OWNER_PID"
emacsclient --alternate-editor=false --socket-name="$TEST_SOCKET" --eval \
  '(list :server server-name :pid (emacs-pid) :fleet-loaded (featurep (quote fleet)))'
```

This is the owner-isolation check for every daemon, launched or reused: the query must show server name
`fleet-test`, and its `:pid` from `(emacs-pid)` must differ from `emacsPid` printed from
`~/.local/share/fleet/owner.json` above. If either condition fails or the owner PID cannot be read, do not
use or kill the daemon; report to whoever coordinates the work. `:fleet-loaded` is recorded but is not
evidence either way, because prior test runs load Fleet. This check protects the owner's running
interactive Emacs.
For the non-native suite, use the following command; update the explicit checkout path if using a
different worktree:

```bash
: "${TEST_SOCKET:?Set TEST_SOCKET to fleet-test after the owner-isolation check}"
test "$TEST_SOCKET" = fleet-test || { echo "Only TEST_SOCKET=fleet-test is allowed" >&2; exit 2; }
emacsclient --alternate-editor=false --socket-name="$TEST_SOCKET" --eval '
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

### Sharing the daemon with a fleet run

A `fleet-test` daemon can be shared with a live fleet run or another agent; its death can interrupt that
work. Only whoever launched a daemon may clean it up. Observed 2026-09-17: an operator
byte-compiled its file through the daemon, the eval wedged, `kill -USR2` entered the debugger's recursive
edit, and the recovery attempt killed the server; ERT then had no test server available. Rules for a shared
daemon:

- **Never byte-compile, `checkdoc`, or install, refresh, upgrade or compile packages (`package-install`,
  `package-refresh-contents`, …) through the daemon.** Activating the installed `eca` exactly as the
  command above does (`package-initialize`, `package-activate`) is required, not forbidden. Load sources
  with `load`, run ERT, and nothing else. Byte compilation belongs in `emacs -Q --batch` on a checkout,
  which these instructions do not run either; leave it to the owner.
- **Run targeted selectors** (`(fleet-test-run-all root "^fleet-rpc-")`, a single test name), one at a
  time, each wrapped in `timeout` on the client so a wedge is visible rather than waited on.
- **Wedge recovery, once:** For a daemon you started that passed the owner-isolation check, confirm its
  recorded PID, send one `kill -USR2 <recorded-pid>` attempt, then immediately run
  `timeout 10 emacsclient --alternate-editor=false --socket-name=fleet-test --eval '(top-level)'`.
  If that trivial eval still times out, clean up your daemon as above and launch a fresh one. Do not send
  recovery signals to or kill a daemon you reused; report its wedge to whoever coordinates the work. If a
  daemon you started dies or wedges a second time in the same task, stop and report instead of looping. A
  second `USR2` has terminated the server before.
- Reloads are cheap but not free of state: the runner reloads every source, resets the cached tool
  schema, and re-registers tests; fake commanders and lease helpers from earlier runs still linger.
  After two or three targeted runs, get a fresh daemon rather than debugging a hang: clean up the daemon
  you started as above and launch a new one. If you reused someone else's daemon, do not kill it or start a
  second daemon; report to whoever coordinates the work.

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

Successful unattended study/change rehearsals and post-restart reconciliation were also recorded
(September 9–10, 2026). Those are historical observations, not a reproducible full acceptance
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
