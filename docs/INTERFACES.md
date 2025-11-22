# Execution Trace Graph (ETG) & Code Graph Interfaces

This document freezes the Phase 0 interface for integrating Qwen Code with a Jaseci-based Execution Trace Graph and object-spatial code graph. It describes the MCP tools, data schemas, and event payload shapes expected by the integration.

## MCP Tools

The Jaseci MCP server exposes the following tools. All parameter and response bodies are JSON.

### `graph_index_project`

- **Purpose:** Build or refresh the code graph for a project.
- **Params:**
  - `project_root` (string, required): Absolute project root path.
  - `mode` (string, optional): `"full"` (default) or `"incremental"`.
- **Response:** `{ files_indexed: number, symbols_indexed: number, concepts_indexed: number, duration_ms: number }`

### `graph_update_files`

- **Purpose:** Re-index specific files and update related symbol edges.
- **Params:**
  - `project_root` (string, required)
  - `paths` (string[], required): File paths (absolute or project-relative).
- **Response:** `{ files_updated: number, symbols_updated: number, duration_ms: number }`

### `etg_log_event`

- **Purpose:** Upsert ETG nodes and edges for the current task/step/tool call lifecycle.
- **Params:**
  - `project_root` (string, required)
  - `task_id` (string | null, optional): Existing task id (or null to start a new task).
  - `kind` (enum, required): One of `"task_start"`, `"step"`, `"tool_start"`, `"tool_end"`, `"checkpoint"`, `"error"`, `"task_end"`.
  - `payload` (object, required): Event-specific fields (see **ETG Event Payloads**).
- **Response:** `{ task_id: string, step_id: string | null, tool_id: string | null }`

### `etg_query_similar_attempts`

- **Purpose:** Retrieve relevant past tasks/steps based on semantic similarity and touched files.
- **Params:**
  - `project_root` (string, required)
  - `query` (string, required)
  - `file_paths` (string[] | null, optional): Filter to attempts that touched these files.
  - `limit` (integer, optional, default 5)
- **Response:**
  - `results` (array): Ranked task/step summaries with scores, ids, files, and errors.
  - `summary_markdown` (string): Human-readable summary for context injection.

### `graph_context_for_files`

- **Purpose:** Return a focused subgraph for specified files.
- **Params:**
  - `project_root` (string, required)
  - `file_paths` (string[], required)
  - `radius` (integer, optional, default 1): Hop distance for neighbor symbols/concepts.
- **Response:**
  - `context_pack` (object): Symbols, concepts, ETG steps, and textual summary.
  - `returnDisplay` (string): Markdown-rendered context.

## Code Graph Schema (Jaseci)

Nodes:

- **Project**: `{ id, root_path }`
- **Directory**: `{ path }`
- **File**: `{ path, language, size_bytes, hash, last_modified }`
- **Symbol**: `{ name, kind (function|class|method|component|test|route|config|other), signature, span: { start_line, end_line }, docstring? }`
- **Concept**: `{ label, description, source (issue|todo|commit|manual|llm) }`

Edges:

- `project_contains_dir` (Project → Directory)
- `dir_contains_dir` (Directory → Directory)
- `dir_contains_file` (Directory → File)
- `file_contains_symbol` (File → Symbol)
- `symbol_calls_symbol` (Symbol → Symbol)
- `symbol_tests_symbol` (Symbol → Symbol)
- `symbol_implements_concept` (Symbol → Concept)
- `file_mentions_concept` (File → Concept)

Optional attributes:

- Embeddings for File, Symbol, Concept nodes stored externally and referenced by node id.

## ETG Schema

Nodes:

- **Task**: `{ id, created_at, user_prompt, project_id, status (planned|running|success|failed|aborted), tags[] }`
- **Step**: `{ id, order, role (planning|reading|editing|testing|refactoring|docs), llm_summary }`
- **ToolInvocation**: `{ id, tool_name, params_json, started_at, duration_ms, success, stdout, stderr }`
- **CheckpointNode**: `{ id, checkpoint_file, created_at }`
- **Error**: `{ id, error_type (test_failure|compile_error|tool_error|runtime_error), message, raw_log_excerpt }`

Edges:

- `task_has_step` (Task → Step, ordered)
- `step_invokes_tool` (Step → ToolInvocation)
- `tool_touches_file` (ToolInvocation → File)
- `step_has_checkpoint` (Step → CheckpointNode)
- `step_has_error` (Step → Error)
- `step_depends_on_step` (Step → Step)
- `task_related_to_concept` (Task → Concept)
- `similar_step` (Step ↔ Step)

Derived attributes:

- `embedding` for Task/Step computed from prompt, summaries, errors, file paths.
- `files_touched` (denormalized set) for filtering queries.

## ETG Event Payloads

This section enumerates minimal payloads for `etg_log_event` by `kind`.

### `task_start`

```
{ "user_prompt": string, "tags"?: string[] }
```

### `step`

```
{ "order": integer, "role"?: string, "llm_summary"?: string }
```

### `tool_start`

```
{ "tool_name": string, "params_json"?: object, "files_touched"?: string[] }
```

### `tool_end`

```
{ "tool_name": string, "success": boolean, "duration_ms"?: number, "stdout"?: string, "stderr"?: string, "files_touched"?: string[] }
```

### `checkpoint`

```
{ "checkpoint_file": string, "created_at"?: string }
```

### `error`

```
{ "error_type": string, "message": string, "raw_log_excerpt"?: string }
```

### `task_end`

```
{ "status": string }
```

## Persistence & Scope

- Store graphs per project under `~/.qwen/graphs/<project_hash>/` (or equivalent) managed by Jaseci persistence.
- Hash-based invalidation is recommended; re-index files only when content hash changes.
- All schemas above are considered frozen for Phase 0; later phases may extend them but should remain backward compatible.
