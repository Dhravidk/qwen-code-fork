"""Stdio MCP server exposing graph and ETG walkers.

The server speaks the MCP JSON-RPC protocol over newline-delimited stdio.
Only the tool surface from ``docs/INTERFACES.md`` is implemented. A minimal
persistence layer is used so callers can test flows without a full Jaseci
runtime.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from typing import Any, Dict, Iterable, List, Optional

from .backend import BackendUnavailable, GraphBackend, select_backend
from .schemas import get_tool_definitions

PROTOCOL_VERSION = "2025-06-18"


class JsonRpcError(Exception):
    def __init__(self, code: int, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


class JaseciMcpServer:
    def __init__(self, backend: Optional[GraphBackend] = None) -> None:
        self.backend = backend or select_backend()
        self.tools = get_tool_definitions()

    # Protocol handlers
    def handle_message(self, message: Dict[str, Any]) -> Dict[str, Any]:
        method = message.get("method")
        msg_id = message.get("id")
        try:
            if method == "initialize":
                result = self._handle_initialize()
            elif method == "ping":
                result = {}
            elif method == "tools/list":
                result = self._handle_tools_list()
            elif method == "tools/call":
                params = message.get("params", {})
                result = self._handle_tools_call(params)
            elif method == "roots/list":
                result = {"roots": []}
            else:
                raise JsonRpcError(-32601, f"Method not found: {method}")
            return {"jsonrpc": "2.0", "id": msg_id, "result": result}
        except JsonRpcError as err:
            return {
                "jsonrpc": "2.0",
                "id": msg_id,
                "error": {"code": err.code, "message": err.message},
            }
        except Exception as exc:  # pragma: no cover - defensive
            return {
                "jsonrpc": "2.0",
                "id": msg_id,
                "error": {"code": -32000, "message": str(exc)},
            }

    def _handle_initialize(self) -> Dict[str, Any]:
        return {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": "jaseci_mcp_etg", "version": "0.2.0"},
        }

    def _handle_tools_list(self) -> Dict[str, Any]:
        return {"tools": self.tools, "nextCursor": None}

    def _handle_tools_call(self, params: Dict[str, Any]) -> Dict[str, Any]:
        name = params.get("name")
        arguments = params.get("arguments", {}) or {}
        if name is None:
            raise JsonRpcError(-32602, "Missing tool name")

        handlers = {
            "graph_index_project": self.graph_index_project,
            "graph_update_files": self.graph_update_files,
            "etg_log_event": self.etg_log_event,
            "etg_query_similar_attempts": self.etg_query_similar_attempts,
            "graph_context_for_files": self.graph_context_for_files,
        }
        if name not in handlers:
            raise JsonRpcError(-32601, f"Unknown tool: {name}")

        structured = handlers[name](arguments)
        text_summary = json.dumps(structured, indent=2)
        return {"content": [{"type": "text", "text": text_summary}], "structuredContent": structured}

    # Tool implementations
    def graph_index_project(self, args: Dict[str, Any]) -> Dict[str, Any]:
        project_root = os.path.abspath(self._require(args, "project_root"))
        mode = args.get("mode", "full")
        started = time.time()
        stats = self.backend.index_project(project_root, mode=mode)
        stats["duration_ms"] = int((time.time() - started) * 1000)
        return stats

    def graph_update_files(self, args: Dict[str, Any]) -> Dict[str, Any]:
        project_root = os.path.abspath(self._require(args, "project_root"))
        paths: Iterable[str] = self._require(args, "paths")
        started = time.time()
        stats = self.backend.update_files(project_root, paths)
        stats["duration_ms"] = int((time.time() - started) * 1000)
        return stats

    def etg_log_event(self, args: Dict[str, Any]) -> Dict[str, Any]:
        project_root = os.path.abspath(self._require(args, "project_root"))
        task_id = args.get("task_id")
        kind = self._require(args, "kind")
        payload = self._require(args, "payload")
        try:
            return self.backend.log_event(project_root, task_id, kind, payload)
        except BackendUnavailable as exc:
            raise JsonRpcError(-32001, str(exc))

    def etg_query_similar_attempts(self, args: Dict[str, Any]) -> Dict[str, Any]:
        project_root = os.path.abspath(self._require(args, "project_root"))
        query = self._require(args, "query")
        file_paths: Optional[List[str]] = args.get("file_paths")
        limit = int(args.get("limit", 5))
        result = self.backend.query_similar(project_root, query, file_paths, limit)
        return result

    def graph_context_for_files(self, args: Dict[str, Any]) -> Dict[str, Any]:
        project_root = os.path.abspath(self._require(args, "project_root"))
        file_paths = self._require(args, "file_paths")
        radius = int(args.get("radius", 1))
        return self.backend.context_for_files(project_root, list(file_paths), radius)

    # Utilities
    @staticmethod
    def _require(obj: Dict[str, Any], key: str) -> Any:
        if key not in obj:
            raise JsonRpcError(-32602, f"Missing required argument: {key}")
        return obj[key]


# CLI entry point

def main() -> None:
    parser = argparse.ArgumentParser(description="Run the Jaseci MCP ETG stdio server")
    parser.add_argument(
        "--once",
        action="store_true",
        help="Process a single JSON-RPC request from stdin (for debugging).",
    )
    parser.add_argument(
        "--backend",
        choices=["auto", "jac", "storage"],
        default=os.getenv("JASECI_ETG_BACKEND", "auto"),
        help="Choose backend implementation (auto tries Jac then storage).",
    )
    args = parser.parse_args()

    server = JaseciMcpServer(select_backend(args.backend))

    if args.once:
        line = sys.stdin.readline()
        if not line:
            return
        message = json.loads(line)
        response = server.handle_message(message)
        sys.stdout.write(json.dumps(response) + "\n")
        sys.stdout.flush()
        return

    for line in sys.stdin:
        if not line.strip():
            continue
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            sys.stdout.write(json.dumps({"jsonrpc": "2.0", "error": {"code": -32700, "message": "Parse error"}}) + "\n")
            sys.stdout.flush()
            continue
        response = server.handle_message(message)
        sys.stdout.write(json.dumps(response) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
