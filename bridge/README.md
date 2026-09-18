# fleet_bridge.py

Standard-library Python; three modes. It frames, forwards and reports. It never decides task state, Git
gates or wake scheduling, and it never writes SQLite.

## `mcp` (default)

MCP server on stdio (newline-delimited JSON-RPC). Supports `initialize` (negotiates `2025-06-18`,
`2025-03-26` or `2024-11-05`; unknown requests get the newest), `notifications/initialized`, `ping`,
`tools/list`, `tools/call`; other methods → `-32601`, parse errors/oversize lines → `-32700`.

Environment: `FLEET_SOCKET` (Unix socket path) and `FLEET_CREDENTIAL_FILE` (`{"runtimeId","token"}`, mode
0600). Without a readable credential the server initializes normally but advertises **no tools** and every
call returns `isError`. With one, `tools/list` is fetched from Fleet (`tools_list`) — Fleet filters by the
credential's role, so a commander and an operator see different tools. `tools/call` forwards the arguments
as `params`, copies `arguments.idempotency_key` into the envelope `idempotencyKey`, and renders the result
(or the structured `{code,message,evidence,retryable}` error) as JSON text content.

Fleet runtimes get this server through a per-runtime `ECA_CONFIG` overlay; `M-x fleet-install-mcp` can
also merge the same entry into `~/.config/eca/config.json`.

## `lease LOCKFILE`

Takes `flock(LOCK_EX|LOCK_NB)` on LOCKFILE, prints `acquired` (exit 0 on EOF of stdin) or `busy` (exit 1).
Holding the descriptor for the parent's lifetime is its whole job; the lock file is never renamed or
unlinked.

## `rpc OPERATION [JSON]`

One request to the socket with the credential from the environment; prints the result or error.
**Mutation-capable:** this forwards any operation permitted by the credential, not just diagnostics.
Do not use it for passive monitoring unless the selected operation is read-only; never acknowledge events
or send health-check messages as an inspection side effect. See [recovery](../docs/recovery.md).

## Socket protocol

See [`schema/rpc-v1.json`](../schema/rpc-v1.json): one JSON object per line, `protocolVersion: 1`, `id`,
`operation`, `credential`, optional `idempotencyKey`, `params`. The implementation authenticates
`tools_list` too, despite the schema's credential exception. The MCP reader enforces the 1 MiB line bound
incrementally: an unterminated line is rejected with a `-32700 "message too large"` error as soon as it
crosses the bound, its remaining bytes are discarded up to the next newline, and framing then resumes;
EOF inside a rejected line exits cleanly. Interface/role/bounds discrepancies are tracked
in [known gaps](../docs/known-gaps.md#authority-and-interface); do not treat schema prose as enforcement.
