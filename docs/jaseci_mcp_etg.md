# Jaseci MCP ETG server

This repository includes a lightweight MCP server named `jaseci_mcp_etg` that
wraps the Execution Trace Graph (ETG) and code graph interfaces defined in
[`docs/INTERFACES.md`](./INTERFACES.md). It uses stdio transport and speaks the
Model Context Protocol JSON-RPC framing used by the Qwen Code MCP client.

## Running the server

The server can be launched directly with Python:

```bash
python -m jaseci_mcp_etg
```

By default the server uses the bundled JSON storage backend. To force the
Jac/Jaseci runtime (once the optional `jaclang` dependency is installed), set
`JASECI_ETG_BACKEND=jac`:

```bash
JASECI_ETG_BACKEND=jac python -m jaseci_mcp_etg
```

During development you can process a single JSON-RPC request (newline-separated)
by passing `--once`:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"initialize"}' | python -m jaseci_mcp_etg --once
```

## MCP configuration example

Add the server to `.qwen/settings.json` so Qwen Code can discover the tools:

```json
{
  "mcpServers": {
    "jaseci-etg": {
      "command": "python",
      "args": ["-m", "jaseci_mcp_etg"],
      "timeout": 600000,
      "trust": true,
      "includeTools": [
        "graph_index_project",
        "graph_update_files",
        "etg_log_event",
        "etg_query_similar_attempts",
        "graph_context_for_files"
      ]
    }
  }
}
```

This repository also ships a ready-to-use example at `.qwen/settings.json` that
matches the configuration above.

## Tool behavior

All tool parameters and responses follow the schemas frozen in
`docs/INTERFACES.md`. The Python package now ships two backends:

- **Storage backend (default):** persists lightweight graph + ETG state under
  `~/.qwen/graphs/<project_hash>/project.json` so callers can exercise flows
  without extra dependencies.
- **Jac backend (optional):** loads the Jac schema and production walkers in
  `jac/` to run against a real Jaseci runtime. Enable with
  `JASECI_ETG_BACKEND=jac` and ensure `jaclang` is installed in the environment
  where the MCP server runs.
