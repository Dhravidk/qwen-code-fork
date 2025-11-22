# Execution Trace Graph & Code Graph Roadmap

This document outlines the planned integration of a Jaseci-based Execution Trace Graph (ETG) and object-spatial code graph into Qwen Code. The interface contracts are frozen in [`docs/INTERFACES.md`](../INTERFACES.md); this roadmap focuses on architecture, components, and delivery phases.

## Goals and memory layers

- **Structured graph memory:** Maintain two graphs per project in Jaseci: a code graph (files, directories, symbols, concepts) and an ETG (tasks, steps, tool calls, errors, checkpoints).
- **Textual memory:** Keep existing long-term text memories (`QWEN.md` imports and `.qwen/PROJECT_SUMMARY.md`) and inject compact graph-derived context into the model on demand.
- **Context on demand:** Heavy state stays in the graphs; only small summaries and context packs enter prompts when relevant files or prompts are detected.

## Major components

1. **Jaseci Graph Engine (JGE)**
   - Runs Jac walkers to index projects, log ETG events, and answer queries.
   - Persists one project-scoped database under `~/.qwen/graphs/<project_hash>/`.
   - Provides semantic search over Tasks/Steps/Files via stored embeddings.
2. **Jaseci MCP server**
   - Wraps JGE behind MCP tools (`graph_index_project`, `graph_update_files`, `etg_log_event`, `etg_query_similar_attempts`, `graph_context_for_files`).
   - Communicates via stdio (or HTTP) and returns JSON per the frozen schemas.
3. **Qwen Code integration**
   - MCP configuration in `.qwen/settings.json` points to the server.
   - A thin event logger wraps tool execution and checkpointing to send ETG events.
   - A retrieval hook calls ETG/context tools before final responses to surface past attempts and nearby code graph nodes.
4. **Subagents**
   - **Graph maintainer:** Keeps the code graph and ETG fresh (indexes on session start or big edits).
   - **ETG analyst:** Retrieves prior failures/attempts relevant to current files or prompts.

## Data model snapshot

The frozen schemas in [`docs/INTERFACES.md`](../INTERFACES.md) define:

- **Code graph:** Project/Directory/File/Symbol/Concept nodes with containment, call, test, and concept edges; optional embeddings per node.
- **ETG:** Task/Step/ToolInvocation/CheckpointNode/Error nodes with lifecycle edges, touched-file tracking, and similarity edges.
- **Event payloads:** Minimal JSON for `etg_log_event` kinds (`task_start`, `step`, `tool_start`, `tool_end`, `checkpoint`, `error`, `task_end`).

## Integration flows

- **Indexing:** `graph_index_project` builds the initial graph; `graph_update_files` re-indexes touched files using hash-based invalidation.
- **ETG logging:** Each tool lifecycle call emits `tool_start` and `tool_end` (with stdout/stderr snippets and touched files). Checkpoints and errors are logged as dedicated events.
- **Retrieval:** Before responding, Qwen Code identifies primary files and calls `etg_query_similar_attempts` plus `graph_context_for_files` to assemble a compact Markdown context pack.

## Delivery phases

1. **Interface freeze (done):** Capture schemas and MCP tool contracts in `docs/INTERFACES.md`.
2. **Jaseci graph engine:** Implement Jac nodes/edges and walkers for indexing, ETG logging, and retrieval queries.
3. **MCP server:** Ship a Python stdio server that exposes the walkers with JSON schemas and a CLI entrypoint.
4. **Qwen Code hooks:** Add event logging around tool execution, checkpoint creation, and pre-answer retrieval; document `.qwen/settings.json` MCP config.
5. **Subagents & docs:** Provide graph-maintainer and ETG-analyst subagents plus memory guidance in `QWEN.md`/project summaries.
6. **Testing & evaluation:** Unit tests for walkers, integration tests for repeated attempts and context retrieval, and performance/token-usage checks.

## Usage expectations

- Run the graph maintainer subagent at session start or after large edits to keep the graph fresh.
- Use the ETG analyst when facing flaky tests or repeated failures to avoid duplicating effort.
- Keep retrieval summaries small to preserve prompt budget while still surfacing relevant history.
