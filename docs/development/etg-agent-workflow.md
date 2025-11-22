# ETG Integration Multi-Agent Workflow

This guide summarizes a staged workflow for integrating Qwen Code with a Jaseci-based Execution Trace Graph (ETG) and code graph using multiple agents. It captures the responsibilities described in the ETG integration spec so each contributor can pick up a phase without guesswork.

## Metrics to Track

When coordinating work across agents, track these metrics for transparency:

- **Repeated failures:** count of retries or blocked tasks.
- **Tokens used:** estimated LLM token consumption when applicable.
- **Time to fix:** wall-clock time from task start to completion.

## Agent Roles

### Agent A — Interface Freezing

- Produce `INTERFACES.md` that defines:
  - JSON schemas for the five MCP tools (`graph_index_project`, `graph_update_files`, `etg_log_event`, `etg_query_similar_attempts`, `graph_context_for_files`).
  - Jac node and edge type definitions for the Code Graph and ETG Graph, including required fields and types.
  - Canonical payload shapes for `etg_log_event` by event `kind`.
- Keep definitions unambiguous so downstream agents can implement without guessing.

### Agent B — Jac Implementation

- Implement Jaseci OSP code (`nodes.jac`, `walkers.jac`) that matches `INTERFACES.md`.
- Provide walkers: `IndexProject`, `LogEvent`, `SimilarAttempts`, and `ContextForFiles` for the ETG and Code Graph.
- Add tests showing a simple project indexed and an ETG trace created.

### Agent C — MCP Server

- Build a Python MCP server `jaseci_mcp_etg` that wraps the Jac walkers from Agent B.
- Use stdio transport with the MCP JSON-RPC protocol.
- Implement tool discovery and tools: `graph_index_project`, `graph_update_files`, `etg_log_event`, `etg_query_similar_attempts`, `graph_context_for_files` following `INTERFACES.md` schemas.

### Agent D — Qwen Code Integration

- Integrate the `jaseci-etg` MCP server into Qwen Code.
- Add a helper `logEtgEvent` and instrument tool execution, checkpoints, and pre-answer retrieval per the integration spec using the discovered MCP tools.
- Create tests verifying ETG events are emitted and retrieved summaries are surfaced in the LLM context.

## Coordination Tips

- Start each phase only after the upstream artifact (e.g., `INTERFACES.md` or Jac walkers) is ready and versioned.
- Keep MCP tool names stable across agents to avoid mismatches.
- Use incremental tests after each phase to catch schema or protocol drift early.
