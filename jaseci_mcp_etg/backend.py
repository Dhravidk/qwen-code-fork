"""Backend selection for the Jaseci ETG MCP server.

Two implementations are provided:

- :class:`StorageBackend` (default) persists ETG + graph state as JSON under
  ``~/.qwen/graphs`` so the MCP surface works without extra dependencies.
- :class:`JacBackend` attempts to load the bundled Jac schema/walkers and run
  them via ``jaclang``. If the dependency is missing or initialization fails,
  :func:`select_backend` will fall back to :class:`StorageBackend` unless the
  caller forces ``backend="jac"``.

This module keeps the server logic agnostic to the storage layer while making
it easy to swap in the real Jac runtime when available.
"""

from __future__ import annotations

import logging
import os
from pathlib import Path
from typing import Iterable, Optional

from .storage import ProjectStorage

LOGGER = logging.getLogger(__name__)


class BackendUnavailable(RuntimeError):
    """Raised when the requested backend cannot be initialized."""


class GraphBackend:
    """Interface for graph + ETG operations used by the MCP server."""

    def index_project(self, root: str, mode: str = "full") -> dict:  # pragma: no cover - interface
        raise NotImplementedError

    def update_files(self, root: str, paths: Iterable[str]) -> dict:  # pragma: no cover - interface
        raise NotImplementedError

    def log_event(self, root: str, task_id: Optional[str], kind: str, payload: dict) -> dict:  # pragma: no cover - interface
        raise NotImplementedError

    def query_similar(self, root: str, query: str, file_paths: Optional[list[str]], limit: int) -> dict:  # pragma: no cover - interface
        raise NotImplementedError

    def context_for_files(self, root: str, file_paths: list[str], radius: int) -> dict:  # pragma: no cover - interface
        raise NotImplementedError


class StorageBackend(GraphBackend):
    """Default backend using the lightweight JSON persistence layer."""

    def __init__(self, storage: Optional[ProjectStorage] = None) -> None:
        self.storage = storage or ProjectStorage()

    def index_project(self, root: str, mode: str = "full") -> dict:
        return self.storage.index_project(root, mode=mode)

    def update_files(self, root: str, paths: Iterable[str]) -> dict:
        return self.storage.update_files(root, paths)

    def log_event(self, root: str, task_id: Optional[str], kind: str, payload: dict) -> dict:
        return self.storage.log_event(root, task_id, kind, payload)

    def query_similar(self, root: str, query: str, file_paths: Optional[list[str]], limit: int) -> dict:
        return self.storage.query_similar(root, query, file_paths, limit)

    def context_for_files(self, root: str, file_paths: list[str], radius: int) -> dict:
        return self.storage.context_for_files(root, file_paths, radius)


class JacBackend(GraphBackend):
    """Jac/Jaseci-backed implementation using bundled walkers.

    The backend defers all heavy lifting to Jac walkers defined under
    ``jac/``. Python collects file metadata/ETG payloads and hands them to the
    walkers so the graph lives in the Jaseci runtime rather than JSON files.
    """

    def __init__(self, jac_dir: Optional[Path] = None) -> None:
        self.jac_dir = jac_dir or Path(__file__).resolve().parent.parent / "jac"
        try:
            from jaclang.jac import JacProgram
            from jaclang.machine import JacMachine
        except Exception as exc:  # pragma: no cover - optional dependency
            raise BackendUnavailable(
                "jaclang is not installed; install jaclang to enable the Jac backend"
            ) from exc

        # Load program
        nodes_path = self.jac_dir / "nodes.jac"
        walkers_path = self.jac_dir / "core_walkers.jac"
        if not nodes_path.exists() or not walkers_path.exists():
            raise BackendUnavailable(f"Jac sources missing under {self.jac_dir}")

        program = JacProgram(files=[str(nodes_path), str(walkers_path)])
        self.machine = JacMachine()
        self.machine.load(program)

    # Helper to execute walker
    def _run(self, entry: str, ctx: dict) -> dict:
        try:
            result = self.machine.run(entry, ctx)
        except Exception as exc:  # pragma: no cover - defensive
            raise BackendUnavailable(f"Failed to run Jac walker {entry}: {exc}") from exc
        if isinstance(result, dict):
            return result
        if hasattr(result, "value"):
            return result.value  # type: ignore[attr-defined]
        return {"result": result}

    def index_project(self, root: str, mode: str = "full") -> dict:
        # Python gathers metadata, Jac stores it.
        from .storage import ProjectStorage  # local reuse for filesystem walk

        storage = ProjectStorage()
        payload = storage.index_project(root, mode=mode)
        files_graph = storage._load(root).graph.get("files", {})  # type: ignore[attr-defined]
        files = []
        for meta in files_graph.values():
            enriched = dict(meta)
            enriched["directory"] = os.path.dirname(enriched.get("path", ""))
            files.append(enriched)
        ctx = {"project_root": root, "mode": mode, "files": files}
        jac_result = self._run("ingest_project_graph", ctx)
        return jac_result or payload

    def update_files(self, root: str, paths: Iterable[str]) -> dict:
        storage = ProjectStorage()
        stats = storage.update_files(root, paths)
        files_graph = storage._load(root).graph.get("files", {})  # type: ignore[attr-defined]
        files = []
        for meta in files_graph.values():
            enriched = dict(meta)
            enriched["directory"] = os.path.dirname(enriched.get("path", ""))
            files.append(enriched)
        ctx = {"project_root": root, "mode": "incremental", "files": files}
        self._run("ingest_project_graph", ctx)
        return stats

    def log_event(self, root: str, task_id: Optional[str], kind: str, payload: dict) -> dict:
        ctx = {"project_root": root, "task_id": task_id, "kind": kind, "payload": payload}
        return self._run("record_etg_event", ctx)

    def query_similar(self, root: str, query: str, file_paths: Optional[list[str]], limit: int) -> dict:
        ctx = {"project_root": root, "query": query, "file_paths": file_paths or [], "limit": limit}
        return self._run("query_similar_attempts", ctx)

    def context_for_files(self, root: str, file_paths: list[str], radius: int) -> dict:
        ctx = {"project_root": root, "file_paths": file_paths, "radius": radius}
        return self._run("context_for_files", ctx)


def select_backend(preference: str | None = None) -> GraphBackend:
    """Choose the backend based on a preference or environment variable.

    ``preference`` can be "auto" (default), "jac", or "storage". When set to
    "jac" we raise :class:`BackendUnavailable` if jaclang cannot be loaded. In
    "auto" mode we attempt Jac first and fall back to storage with a log note.
    """

    preference = preference or os.getenv("JASECI_ETG_BACKEND", "auto")
    preference = preference.lower()
    if preference not in {"auto", "jac", "storage"}:
        LOGGER.warning("Unknown backend preference %s; defaulting to storage", preference)
        preference = "storage"

    if preference in {"auto", "jac"}:
        try:
            LOGGER.debug("Attempting Jac backend (preference=%s)", preference)
            return JacBackend()
        except BackendUnavailable as exc:
            if preference == "jac":
                raise
            LOGGER.info("Jac backend unavailable, falling back to storage: %s", exc)

    return StorageBackend()
