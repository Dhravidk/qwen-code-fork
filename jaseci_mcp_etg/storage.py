"""Simple persistence for ETG and graph metadata.

This module stores lightweight graph and ETG state under ``~/.qwen/graphs``
as JSON so that the MCP server can respond without requiring a full Jaseci
runtime. The shape aligns with the interfaces in ``docs/INTERFACES.md``.
"""

from __future__ import annotations

import hashlib
import json
import os
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, Iterable, List, Optional

GraphFiles = Dict[str, Dict]


@dataclass
class ProjectData:
    project_root: str
    graph: Dict = field(default_factory=lambda: {"files": {}, "symbols": {}, "concepts": {}})
    etg: Dict = field(
        default_factory=lambda: {
            "tasks": {},
            "steps": {},
            "tools": {},
            "checkpoints": {},
            "errors": {},
            "task_steps": {},
        }
    )

    def to_json(self) -> Dict:
        return {
            "project_root": self.project_root,
            "graph": self.graph,
            "etg": self.etg,
        }


class ProjectStorage:
    """Disk-backed storage for project graphs and ETG."""

    def __init__(self, base_dir: Optional[str] = None) -> None:
        self.base_dir = Path(base_dir or Path.home() / ".qwen" / "graphs")
        self.base_dir.mkdir(parents=True, exist_ok=True)

    def _project_hash(self, root: str) -> str:
        return hashlib.sha1(root.encode("utf-8")).hexdigest()

    def _project_path(self, root: str) -> Path:
        return self.base_dir / self._project_hash(root) / "project.json"

    def _load(self, root: str) -> ProjectData:
        path = self._project_path(root)
        if path.exists():
            with path.open("r", encoding="utf-8") as f:
                raw = json.load(f)
            project = ProjectData(project_root=raw.get("project_root", root))
            project.graph = raw.get("graph", project.graph)
            project.etg = raw.get("etg", project.etg)
            return project
        return ProjectData(project_root=root)

    def _save(self, data: ProjectData) -> None:
        path = self._project_path(data.project_root)
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("w", encoding="utf-8") as f:
            json.dump(data.to_json(), f, indent=2)

    # Graph operations
    def index_project(self, root: str, mode: str = "full") -> Dict[str, int]:
        project = self._load(root)
        if mode == "full":
            project.graph["files"] = {}
        files_indexed = self._walk_and_index(project.graph["files"], root)
        self._save(project)
        return {
            "files_indexed": files_indexed,
            "symbols_indexed": len(project.graph.get("symbols", {})),
            "concepts_indexed": len(project.graph.get("concepts", {})),
        }

    def update_files(self, root: str, paths: Iterable[str]) -> Dict[str, int]:
        project = self._load(root)
        files_updated = 0
        for path in paths:
            normalized = self._normalize_path(root, path)
            if not os.path.isfile(normalized):
                continue
            project.graph.setdefault("files", {})
            project.graph["files"][normalized] = self._file_metadata(normalized)
            files_updated += 1
        self._save(project)
        return {
            "files_updated": files_updated,
            "symbols_updated": len(project.graph.get("symbols", {})),
        }

    # ETG operations
    def log_event(self, root: str, task_id: Optional[str], kind: str, payload: Dict) -> Dict[str, Optional[str]]:
        project = self._load(root)
        tasks = project.etg.setdefault("tasks", {})
        steps = project.etg.setdefault("steps", {})
        tools = project.etg.setdefault("tools", {})
        checkpoints = project.etg.setdefault("checkpoints", {})
        errors = project.etg.setdefault("errors", {})
        task_steps = project.etg.setdefault("task_steps", {})

        task_id = task_id or str(uuid.uuid4())
        step_id: Optional[str] = None
        tool_id: Optional[str] = None

        if kind == "task_start":
            tasks[task_id] = {
                "id": task_id,
                "created_at": payload.get("created_at") or _now_iso(),
                "user_prompt": payload.get("user_prompt", ""),
                "status": "running",
                "tags": payload.get("tags", []),
                "files_touched": [],
            }
            task_steps.setdefault(task_id, [])
        elif kind == "step":
            step_id = str(uuid.uuid4())
            order = payload.get("order") or len(task_steps.get(task_id, [])) + 1
            step = {
                "id": step_id,
                "task_id": task_id,
                "order": order,
                "role": payload.get("role", ""),
                "llm_summary": payload.get("llm_summary", ""),
                "files_touched": [],
            }
            steps[step_id] = step
            task_steps.setdefault(task_id, []).append(step_id)
        elif kind == "tool_start":
            step_id = self._ensure_step_for_task(task_id, task_steps, steps)
            tool_id = str(uuid.uuid4())
            tool = {
                "id": tool_id,
                "task_id": task_id,
                "step_id": step_id,
                "tool_name": payload.get("tool_name", ""),
                "params_json": payload.get("params_json"),
                "started_at": payload.get("started_at") or _now_iso(),
                "files_touched": payload.get("files_touched", []) or [],
                "success": None,
            }
            tools[tool_id] = tool
            self._merge_files_touched(steps.get(step_id), tasks.get(task_id), tool["files_touched"])
        elif kind == "tool_end":
            tool_id = payload.get("tool_id") or self._latest_tool_id(tools, task_id)
            if tool_id and tool_id in tools:
                tool = tools[tool_id]
                tool["success"] = payload.get("success")
                tool["duration_ms"] = payload.get("duration_ms")
                tool["stdout"] = payload.get("stdout")
                tool["stderr"] = payload.get("stderr")
                new_files = payload.get("files_touched", []) or []
                tool.setdefault("files_touched", [])
                tool["files_touched"].extend([f for f in new_files if f not in tool["files_touched"]])
                self._merge_files_touched(steps.get(tool.get("step_id")), tasks.get(task_id), new_files)
                step_id = tool.get("step_id")
            else:
                tool_id = None
        elif kind == "checkpoint":
            step_id = self._ensure_step_for_task(task_id, task_steps, steps)
            checkpoint_id = str(uuid.uuid4())
            checkpoints[checkpoint_id] = {
                "id": checkpoint_id,
                "task_id": task_id,
                "step_id": step_id,
                "checkpoint_file": payload.get("checkpoint_file"),
                "created_at": payload.get("created_at") or _now_iso(),
            }
        elif kind == "error":
            step_id = self._ensure_step_for_task(task_id, task_steps, steps)
            error_id = str(uuid.uuid4())
            errors[error_id] = {
                "id": error_id,
                "task_id": task_id,
                "step_id": step_id,
                "error_type": payload.get("error_type", "runtime_error"),
                "message": payload.get("message", ""),
                "raw_log_excerpt": payload.get("raw_log_excerpt", ""),
            }
            steps[step_id]["last_error_id"] = error_id
        elif kind == "task_end":
            if task_id in tasks:
                tasks[task_id]["status"] = payload.get("status", "completed")
        else:
            raise ValueError(f"Unsupported event kind: {kind}")

        self._save(project)
        return {"task_id": task_id, "step_id": step_id, "tool_id": tool_id}

    def query_similar(self, root: str, query: str, file_paths: Optional[List[str]], limit: int) -> Dict:
        project = self._load(root)
        query_lc = query.lower()
        file_filters = {self._normalize_path(root, f) for f in file_paths or []}

        candidates = []
        for step_id, step in project.etg.get("steps", {}).items():
            task = project.etg.get("tasks", {}).get(step.get("task_id"), {})
            files = set(step.get("files_touched", []))
            if file_filters and not (files & file_filters):
                continue
            text = "\n".join(
                [
                    task.get("user_prompt", ""),
                    step.get("llm_summary", ""),
                    " ".join(files),
                ]
            ).lower()
            score = text.count(query_lc) + sum(1 for f in files if query_lc in f.lower())
            if score == 0:
                # fall back to substring presence
                score = 1 if query_lc in text else 0
            if score > 0:
                candidates.append(
                    {
                        "step_id": step_id,
                        "task_id": step.get("task_id"),
                        "score": score,
                        "user_prompt": task.get("user_prompt", ""),
                        "llm_summary": step.get("llm_summary", ""),
                        "files": sorted(files),
                        "errors": self._errors_for_step(project, step_id),
                    }
                )

        candidates.sort(key=lambda c: c["score"], reverse=True)
        results = candidates[:limit]
        summary_lines = [
            f"- Step {idx + 1} (task {r['task_id']}): score={r['score']} files={', '.join(r['files'])}"
            for idx, r in enumerate(results)
        ]
        summary_markdown = "\n".join(summary_lines) if summary_lines else "No similar attempts found."
        return {"results": results, "summary_markdown": summary_markdown}

    def context_for_files(self, root: str, file_paths: List[str], radius: int) -> Dict:
        project = self._load(root)
        normalized_files = [self._normalize_path(root, p) for p in file_paths]
        steps_for_files = self._steps_for_files(project, normalized_files)
        context_pack = {
            "files": {f: project.graph.get("files", {}).get(f, {}) for f in normalized_files},
            "symbols": {},
            "concepts": {},
            "etg_steps": steps_for_files,
            "radius": radius,
        }
        lines = ["### Graph context", "Files:"]
        for f in normalized_files:
            meta = context_pack["files"].get(f)
            if meta:
                lines.append(f"- {f} (size={meta.get('size_bytes')}, lang={meta.get('language')})")
            else:
                lines.append(f"- {f} (not indexed)")
        if steps_for_files:
            lines.append("\n### Recent ETG steps")
            for step in steps_for_files:
                lines.append(
                    f"- Task {step['task_id']} step {step['step_id']}: {step.get('llm_summary','')} (files: {', '.join(step.get('files_touched', []))})"
                )
        summary = "\n".join(lines)
        return {"context_pack": context_pack, "returnDisplay": summary}

    # Helpers
    def _walk_and_index(self, files_graph: GraphFiles, root: str) -> int:
        files_indexed = 0
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if d not in {".git", "node_modules", "dist", "__pycache__", ".qwen"}]
            for filename in filenames:
                path = os.path.join(dirpath, filename)
                files_graph[path] = self._file_metadata(path)
                files_indexed += 1
        return files_indexed

    def _file_metadata(self, path: str) -> Dict:
        stat = os.stat(path)
        return {
            "path": path,
            "language": _language_from_path(path),
            "size_bytes": stat.st_size,
            "hash": _hash_file(path),
            "last_modified": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(stat.st_mtime)),
        }

    def _normalize_path(self, root: str, path: str) -> str:
        if os.path.isabs(path):
            return os.path.normpath(path)
        return os.path.normpath(os.path.join(root, path))

    def _ensure_step_for_task(self, task_id: str, task_steps: Dict[str, List[str]], steps: Dict[str, Dict]) -> str:
        if task_steps.get(task_id):
            return task_steps[task_id][-1]
        step_id = str(uuid.uuid4())
        step = {
            "id": step_id,
            "task_id": task_id,
            "order": 1,
            "role": "",
            "llm_summary": "",
            "files_touched": [],
        }
        steps[step_id] = step
        task_steps[task_id] = [step_id]
        return step_id

    def _latest_tool_id(self, tools: Dict[str, Dict], task_id: str) -> Optional[str]:
        for tool_id, tool in reversed(list(tools.items())):
            if tool.get("task_id") == task_id:
                return tool_id
        return None

    def _merge_files_touched(self, step: Optional[Dict], task: Optional[Dict], files: Iterable[str]) -> None:
        files = list(files or [])
        if step is not None:
            step.setdefault("files_touched", [])
            for f in files:
                if f not in step["files_touched"]:
                    step["files_touched"].append(f)
        if task is not None:
            task.setdefault("files_touched", [])
            for f in files:
                if f not in task["files_touched"]:
                    task["files_touched"].append(f)

    def _errors_for_step(self, project: ProjectData, step_id: str) -> List[Dict]:
        errs = []
        for err in project.etg.get("errors", {}).values():
            if err.get("step_id") == step_id:
                errs.append(err)
        return errs

    def _steps_for_files(self, project: ProjectData, files: List[str]) -> List[Dict]:
        matched_steps = []
        for step_id, step in project.etg.get("steps", {}).items():
            step_files = set(step.get("files_touched", []))
            if step_files & set(files):
                matched_steps.append({**step, "step_id": step_id})
        matched_steps.sort(key=lambda s: s.get("order", 0))
        return matched_steps


def _hash_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()


def _language_from_path(path: str) -> str:
    ext = Path(path).suffix.lower()
    mapping = {
        ".py": "python",
        ".ts": "typescript",
        ".js": "javascript",
        ".tsx": "tsx",
        ".jsx": "jsx",
        ".md": "markdown",
        ".json": "json",
    }
    return mapping.get(ext, "unknown")


def _now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
