"""JSON Schemas for MCP tools exposed by the server."""

from __future__ import annotations

from typing import Any, Dict, List


def _object_schema(properties: Dict[str, Any], required: List[str] | None = None) -> Dict[str, Any]:
    return {
        "type": "object",
        "properties": properties,
        "required": required or [],
        "additionalProperties": False,
    }


def get_tool_definitions() -> List[Dict[str, Any]]:
    """Return MCP tool definitions with input schemas."""

    return [
        {
            "name": "graph_index_project",
            "description": "Build or refresh the code graph for a project root.",
            "inputSchema": _object_schema(
                {
                    "project_root": {"type": "string", "description": "Absolute project root path"},
                    "mode": {
                        "type": "string",
                        "enum": ["full", "incremental"],
                        "description": "Full or incremental indexing",
                        "default": "full",
                    },
                },
                required=["project_root"],
            ),
        },
        {
            "name": "graph_update_files",
            "description": "Re-index a list of files and refresh related symbol edges.",
            "inputSchema": _object_schema(
                {
                    "project_root": {"type": "string", "description": "Absolute project root path"},
                    "paths": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "File paths to update (absolute or relative to project)",
                    },
                },
                required=["project_root", "paths"],
            ),
        },
        {
            "name": "etg_log_event",
            "description": "Upsert Execution Trace Graph nodes and edges for a task lifecycle event.",
            "inputSchema": _object_schema(
                {
                    "project_root": {"type": "string"},
                    "task_id": {"type": ["string", "null"], "description": "Existing task id or null to start"},
                    "kind": {
                        "type": "string",
                        "enum": [
                            "task_start",
                            "step",
                            "tool_start",
                            "tool_end",
                            "checkpoint",
                            "error",
                            "task_end",
                        ],
                    },
                    "payload": {"type": "object", "description": "Event-specific payload"},
                },
                required=["project_root", "kind", "payload"],
            ),
        },
        {
            "name": "etg_query_similar_attempts",
            "description": "Retrieve relevant past tasks/steps based on similarity and touched files.",
            "inputSchema": _object_schema(
                {
                    "project_root": {"type": "string"},
                    "query": {"type": "string"},
                    "file_paths": {
                        "type": ["array", "null"],
                        "items": {"type": "string"},
                        "description": "Optional file path filter",
                    },
                    "limit": {"type": "integer", "minimum": 1, "default": 5},
                },
                required=["project_root", "query"],
            ),
        },
        {
            "name": "graph_context_for_files",
            "description": "Return a focused subgraph and ETG context for given files.",
            "inputSchema": _object_schema(
                {
                    "project_root": {"type": "string"},
                    "file_paths": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Files to gather graph context for",
                    },
                    "radius": {"type": "integer", "minimum": 0, "default": 1},
                },
                required=["project_root", "file_paths"],
            ),
        },
    ]
