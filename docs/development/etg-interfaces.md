# ETG MCP Interface Contracts

This document freezes the interfaces for the Execution Trace Graph (ETG) work so downstream agents can implement Jac walkers,
Python MCP servers, and Qwen Code integrations without guessing. It defines MCP tool schemas, Jac graph shapes, and canonical
payloads for ETG log events.

## MCP Tool Schemas

Each tool follows the MCP JSON-RPC conventions and uses JSON Schema draft-07 style definitions. Inputs marked as **required**
must be provided; outputs should be treated as authoritative.

### `graph_index_project`

- **Purpose:** Index an entire project into the Code Graph.
- **Input schema:**
  ```json
  {
    "type": "object",
    "required": ["project_root", "files"],
    "properties": {
      "project_root": {
        "type": "string",
        "description": "Absolute path to the project root"
      },
      "files": {
        "type": "array",
        "items": { "type": "string" },
        "description": "File paths (relative to project_root) to ingest"
      },
      "language_hints": {
        "type": "object",
        "additionalProperties": { "type": "string" },
        "description": "Optional map from path to language id override"
      }
    }
  }
  ```
- **Output schema:**
  ```json
  {
    "type": "object",
    "required": ["indexed_files", "graph_version"],
    "properties": {
      "indexed_files": { "type": "array", "items": { "type": "string" } },
      "graph_version": {
        "type": "string",
        "description": "Opaque version or hash for the Code Graph"
      }
    }
  }
  ```

### `graph_update_files`

- **Purpose:** Incrementally update the Code Graph after edits.
- **Input schema:**
  ```json
  {
    "type": "object",
    "required": ["project_root"],
    "properties": {
      "project_root": { "type": "string" },
      "added_or_modified": {
        "type": "array",
        "items": { "type": "string" },
        "description": "Paths (relative to project_root) to upsert"
      },
      "deleted": {
        "type": "array",
        "items": { "type": "string" },
        "description": "Paths (relative to project_root) to remove from the graph"
      }
    }
  }
  ```
- **Output schema:**
  ```json
  {
    "type": "object",
    "required": ["updated_files", "graph_version"],
    "properties": {
      "updated_files": { "type": "array", "items": { "type": "string" } },
      "graph_version": { "type": "string" }
    }
  }
  ```

### `etg_log_event`

- **Purpose:** Append an event to the ETG for a specific attempt.
- **Input schema:**
  ```json
  {
    "type": "object",
    "required": ["attempt_id", "kind", "payload"],
    "properties": {
      "attempt_id": {
        "type": "string",
        "description": "Opaque identifier for the attempt/run"
      },
      "kind": {
        "type": "string",
        "enum": [
          "tool_start",
          "tool_end",
          "checkpoint",
          "context_retrieved",
          "answer_rendered"
        ],
        "description": "Event category"
      },
      "timestamp": { "type": "string", "format": "date-time" },
      "payload": {
        "type": "object",
        "description": "Event-kind-specific fields (see canonical shapes below)"
      }
    }
  }
  ```
- **Output schema:**
  ```json
  {
    "type": "object",
    "required": ["event_id", "attempt_id"],
    "properties": {
      "event_id": { "type": "string" },
      "attempt_id": { "type": "string" }
    }
  }
  ```

### `etg_query_similar_attempts`

- **Purpose:** Retrieve similar historical attempts using ETG and Code Graph context.
- **Input schema:**
  ```json
  {
    "type": "object",
    "required": ["query"],
    "properties": {
      "query": {
        "type": "string",
        "description": "User problem or failure description"
      },
      "files": {
        "type": "array",
        "items": { "type": "string" },
        "description": "Optional file paths relevant to the query"
      },
      "top_k": { "type": "integer", "minimum": 1, "default": 5 },
      "min_score": {
        "type": "number",
        "minimum": 0,
        "maximum": 1,
        "default": 0.2
      }
    }
  }
  ```
- **Output schema:**
  ```json
  {
    "type": "object",
    "required": ["matches"],
    "properties": {
      "matches": {
        "type": "array",
        "items": {
          "type": "object",
          "required": ["attempt_id", "score", "summary"],
          "properties": {
            "attempt_id": { "type": "string" },
            "score": { "type": "number" },
            "summary": { "type": "string" },
            "related_files": { "type": "array", "items": { "type": "string" } }
          }
        }
      }
    }
  }
  ```

### `graph_context_for_files`

- **Purpose:** Pull summarized code context for one or more files.
- **Input schema:**
  ```json
  {
    "type": "object",
    "required": ["project_root", "files"],
    "properties": {
      "project_root": { "type": "string" },
      "files": { "type": "array", "items": { "type": "string" } },
      "max_tokens": { "type": "integer", "minimum": 128, "default": 2048 }
    }
  }
  ```
- **Output schema:**
  ```json
  {
    "type": "object",
    "required": ["contexts"],
    "properties": {
      "contexts": {
        "type": "array",
        "items": {
          "type": "object",
          "required": ["file", "summary"],
          "properties": {
            "file": { "type": "string" },
            "summary": { "type": "string" },
            "symbols": {
              "type": "array",
              "items": { "type": "string" },
              "description": "Symbol names or anchors relevant to the summary"
            }
          }
        }
      }
    }
  }
  ```

## Jac Graph Types

Jac nodes and edges must align with the schemas above to guarantee consistent persistence and retrieval.

### Code Graph

- **Nodes:**
  - `File`: `{ path: string, language: string, hash: string, project_root: string }`
  - `Symbol`: `{ name: string, kind: string, file_path: string, span: { start: number, end: number } }`
  - `ContextChunk`: `{ file_path: string, snippet: string, embedding: list<float> }`
- **Edges:**
  - `file_has_symbol` (`File` → `Symbol`)
  - `symbol_in_context` (`Symbol` → `ContextChunk`)
  - `file_has_context` (`File` → `ContextChunk`)

### ETG Graph

- **Nodes:**
  - `Attempt`: `{ attempt_id: string, started_at: datetime, graph_version: string }`
  - `Event`: `{ event_id: string, kind: string, timestamp: datetime, payload: dict }`
  - `ToolCall`: `{ name: string, arguments: dict, status: string, duration_ms: number }`
  - `Summary`: `{ text: string, source: string, embedding: list<float> }`
- **Edges:**
  - `attempt_has_event` (`Attempt` → `Event`)
  - `event_invokes_tool` (`Event` → `ToolCall`)
  - `event_reads_file` (`Event` → `File`)
  - `attempt_has_summary` (`Attempt` → `Summary`)
  - `event_links_context` (`Event` → `ContextChunk`)

## Canonical `etg_log_event` Payloads

All events share the base envelope `{ attempt_id, kind, timestamp, payload }`. Timestamps should be ISO-8601 with timezone.

- **`tool_start`:**

  ```json
  {
    "payload": {
      "tool": "shell_run",
      "arguments": { "cmd": "npm test" }
    }
  }
  ```

- **`tool_end`:**

  ```json
  {
    "payload": {
      "tool": "shell_run",
      "status": "ok",
      "duration_ms": 1823,
      "output_ref": "log://attempt123/tool456"
    }
  }
  ```

- **`checkpoint`:**

  ```json
  {
    "payload": {
      "message": "Generated patch for utils/logger.ts",
      "files": ["utils/logger.ts"],
      "graph_version": "cg-2024-05-01T12:00:00Z"
    }
  }
  ```

- **`context_retrieved`:**

  ```json
  {
    "payload": {
      "files": ["app/main.py"],
      "snippets": [
        {
          "file": "app/main.py",
          "summary": "Handler dispatches requests to route registry",
          "symbols": ["Router", "dispatch"]
        }
      ]
    }
  }
  ```

- **`answer_rendered`:**
  ```json
  {
    "payload": {
      "content": "Here is the patch...",
      "citations": ["app/main.py:L10-L40"],
      "token_count": 512
    }
  }
  ```

Implementations should reject events that omit required fields for their kind and persist `graph_version` on checkpoints to tie
ETG entries to the Code Graph snapshot used.
