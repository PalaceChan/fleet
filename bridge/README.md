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

One request to the socket with the credential from the environment; prints the result or error. Diagnostic
only.

## Socket protocol

See `schema/rpc-v1.json`: one JSON object per line, `protocolVersion: 1`, `id`, `operation`, optional
`credential`, optional `idempotencyKey`, `params`. Requests over 1 MiB are refused explicitly.
