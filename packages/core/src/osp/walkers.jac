# @license
# Copyright 2025 Google LLC
# SPDX-License-Identifier: Apache-2.0

# Jac walkers that implement the Phase 0 Execution Trace Graph (ETG) and Code Graph
# surface defined in docs/INTERFACES.md. The walkers are intentionally verbose and
# documented so downstream tooling can mirror the intended behaviour even without
# a full runtime.

walker IndexProject {
    has root_path: str;
    has mode: str = "full"; # "full" or "incremental"
    has stats: dict;

    can normalize_path(path: str) -> str {
        py {
            import os
            return os.path.abspath(path)
        }
    }

    can parent_dir(path: str) -> str {
        py {
            import os
            return os.path.abspath(os.path.dirname(path))
        }
    }

    can walk_fs(root: str) -> list {
        py {
            import os
            results = []
            for current, dirs, files in os.walk(root):
                results.append({
                    "dir": os.path.abspath(current),
                    "dirs": [os.path.join(current, d) for d in dirs],
                    "files": [os.path.join(current, f) for f in files],
                })
            return results
        }
    }

    can file_meta(path: str) -> dict {
        py {
            import os
            from datetime import datetime
            st = os.stat(path)
            return {
                "size": st.st_size,
                "mtime": st.st_mtime,
                "mtime_str": datetime.fromtimestamp(st.st_mtime).isoformat(),
            }
        }
    }

    can hash_file(path: str) -> str {
        py {
            import hashlib
            h = hashlib.sha256()
            with open(path, "rb") as f:
                for chunk in iter(lambda: f.read(8192), b""):
                    h.update(chunk)
            return h.hexdigest()
        }
    }

    can detect_language(path: str) -> str {
        py {
            import os
            ext = os.path.splitext(path)[1].lower()
            mapping = {
                ".py": "python",
                ".ts": "typescript",
                ".tsx": "tsx",
                ".js": "javascript",
                ".jsx": "jsx",
                ".rs": "rust",
                ".java": "java",
                ".go": "go",
                ".cpp": "cpp",
                ".c": "c",
                ".h": "c",
                ".md": "markdown",
                ".json": "json",
                ".yaml": "yaml",
                ".yml": "yaml",
            }
            return mapping.get(ext, "unknown")
        }
    }

    root {
        assert root_path, "root_path is required";
        normalized_root = normalize_path(root_path);
        mode = mode or "full";
        stats = {
            "dirs_seen": 0,
            "dirs_created": 0,
            "files_created": 0,
            "files_updated": 0,
            "files_skipped": 0,
        };

        with project_node = spawn here ++:project {
            .id = digest(normalized_root);
            .root_path = normalized_root;
        }

        dir_cache = {};

        for entry in walk_fs(normalized_root) {
            dir_path = normalize_path(entry.dir);
            stats.dirs_seen += 1;

            with dir_node = spawn here ++:directory {
                .path = dir_path;
            }
            if not dir_cache.get(dir_path) { stats.dirs_created += 1; }
            dir_cache[dir_path] = dir_node;

            if dir_path == normalized_root {
                connect(project_node, dir_node, project_contains_dir);
            } else {
                p_path = parent_dir(dir_path);
                if not dir_cache.get(p_path) {
                    with parent_node = spawn here ++:directory { .path = p_path; }
                    dir_cache[p_path] = parent_node;
                }
                connect(dir_cache[p_path], dir_node, dir_contains_dir);
            }

            for subdir in entry.dirs {
                sub_path = normalize_path(subdir);
                if not dir_cache.get(sub_path) {
                    with child_dir = spawn here ++:directory { .path = sub_path; }
                    dir_cache[sub_path] = child_dir;
                    stats.dirs_created += 1;
                }
            }

            for f_path in entry.files {
                normalized_file = normalize_path(f_path);
                meta = file_meta(normalized_file);
                new_hash = hash_file(normalized_file);

                with file_node = spawn here ++:file { .path = normalized_file; }
                old_hash = file_node.hash;
                old_mtime = file_node.last_modified;

                needs_update = mode == "full" or old_hash == null or old_mtime == null or old_hash != new_hash or old_mtime != meta.mtime_str;

                if needs_update {
                    file_node.language = detect_language(normalized_file);
                    file_node.size_bytes = meta.size;
                    file_node.hash = new_hash;
                    file_node.last_modified = meta.mtime_str;
                    if old_hash == null { stats.files_created += 1; } else { stats.files_updated += 1; }
                } else {
                    stats.files_skipped += 1;
                }

                connect(dir_node, file_node, dir_contains_file);
            }
        }

        report {
            "project_root": normalized_root,
            "mode": mode,
            "dirs_seen": stats.dirs_seen,
            "dirs_created": stats.dirs_created,
            "files_created": stats.files_created,
            "files_updated": stats.files_updated,
            "files_skipped": stats.files_skipped,
        };
    }
}

walker LogEvent {
    has project_root: str;
    has task_id: str;
    has kind: str;
    has payload: dict;

    root {
        assert project_root, "project_root is required";
        assert kind, "kind is required";

        # Reuse or create the project node.
        with project_node = spawn here ++:project {
            .id = digest(project_root);
            .root_path = project_root;
        }

        if kind == "task_start" {
            task_id = payload.get("task_id", gen_uuid());
            with t = spawn project_node ++:task {
                .id = task_id;
                .created_at = now();
                .user_prompt = payload.user_prompt;
                .project_id = project_node.id;
                .status = "running";
                .tags = payload.tags or [];
                .files_touched = [];
                .embedding = [];
            }
            report {"task_id": task_id, "step_id": null, "tool_id": null};
        }

        if kind == "step" {
            assert task_id, "step requires a task_id";
            with t = project_node-->task(id=task_id) { }
            with s = spawn project_node ++:step {
                .id = payload.get("step_id", gen_uuid());
                .order = payload.order;
                .role = payload.get("role", "");
                .llm_summary = payload.get("llm_summary", "");
                .files_touched = payload.get("files_touched", []);
                .embedding = [];
            }
            connect(t, s, task_has_step);
            report {"task_id": task_id, "step_id": s.id, "tool_id": null};
        }

        if kind == "tool_start" {
            assert task_id, "tool_start requires a task_id";
            with current_step = latest(project_node, task_id) { }
            with tool = spawn project_node ++:tool_invocation {
                .id = gen_uuid();
                .tool_name = payload.tool_name;
                .params_json = payload.get("params_json", {});
                .started_at = now();
                .files_touched = payload.get("files_touched", []);
            }
            connect(current_step, tool, step_invokes_tool);
            for f_path in payload.get("files_touched", []) {
                if f_path has file_node {
                    connect(tool, file_node, tool_touches_file);
                }
            }
            report {"task_id": task_id, "step_id": current_step.id, "tool_id": tool.id};
        }

        if kind == "tool_end" {
            assert task_id, "tool_end requires a task_id";
            with current_step = latest(project_node, task_id) { }
            with tool = latest_tool(current_step, payload.tool_name) { }
            tool.success = payload.success;
            tool.duration_ms = payload.get("duration_ms", 0);
            tool.stdout = payload.get("stdout", "");
            tool.stderr = payload.get("stderr", "");
            if payload.get("files_touched", []) {
                tool.files_touched = payload.files_touched;
            }
            for f_path in tool.files_touched {
                if f_path has file_node {
                    connect(tool, file_node, tool_touches_file);
                }
            }
            report {"task_id": task_id, "step_id": current_step.id, "tool_id": tool.id};
        }

        if kind == "checkpoint" {
            with current_step = latest(project_node, task_id) { }
            with c = spawn current_step ++:checkpoint_node {
                .id = gen_uuid();
                .checkpoint_file = payload.checkpoint_file;
                .created_at = payload.get("created_at", now());
            }
            connect(current_step, c, step_has_checkpoint);
            report {"task_id": task_id, "step_id": current_step.id, "tool_id": null};
        }

        if kind == "error" {
            with current_step = latest(project_node, task_id) { }
            with e = spawn current_step ++:error {
                .id = gen_uuid();
                .error_type = payload.error_type;
                .message = payload.message;
                .raw_log_excerpt = payload.get("raw_log_excerpt", "");
            }
            connect(current_step, e, step_has_error);
            report {"task_id": task_id, "step_id": current_step.id, "tool_id": null};
        }

        if kind == "task_end" {
            with t = project_node-->task(id=task_id) { }
            t.status = payload.status;
            report {"task_id": task_id, "step_id": null, "tool_id": null};
        }
    }
}

walker SimilarAttempts {
    has project_root: str;
    has query: str;
    has file_paths: list;
    has limit: int = 5;

    root {
        assert project_root, "project_root is required";
        assert query, "query is required";

        with project_node = spawn here ++:project {
            .id = digest(project_root);
            .root_path = project_root;
        }

        results = [];
        for s in project_node-->step {
            score = similarity(query, s.embedding, s.files_touched, file_paths);
            if len(results) < limit or score > results[-1].score {
                results.append({"step_id": s.id,
                                 "task_id": (s<-task_has_step).id,
                                 "files": s.files_touched,
                                 "score": score,
                                 "llm_summary": s.llm_summary});
                results = sort_desc(results, "score")[:limit];
            }
        }

        summary_markdown = render_results(results);
        report {"results": results, "summary_markdown": summary_markdown};
    }
}

walker ContextForFiles {
    has project_root: str;
    has file_paths: list;
    has radius: int = 1;

    root {
        assert project_root, "project_root is required";
        assert file_paths and len(file_paths) > 0, "file_paths are required";

        with project_node = spawn here ++:project {
            .id = digest(project_root);
            .root_path = project_root;
        }

        symbols = [];
        concepts = [];
        steps = [];

        for f_path in file_paths {
            for f in project_node-->file(path=f_path) {
                for s in f-->file_contains_symbol {
                    symbols.append(s);
                    for hop in bfs(s, radius) {
                        if hop isa symbol { symbols.append(hop); }
                        if hop isa concept { concepts.append(hop); }
                    }
                }
            }
        }

        for t in project_node-->task {
            for s in t-->task_has_step {
                if overlaps(s.files_touched, file_paths) {
                    steps.append(s);
                }
            }
        }

        returnDisplay = render_context(symbols, concepts, steps);
        report {"context_pack": {"symbols": unique(symbols),
                                  "concepts": unique(concepts),
                                  "steps": unique(steps),
                                  "files": file_paths},
                "returnDisplay": returnDisplay};
    }
}

# Simple demonstration walker that exercises IndexProject and returns its summary
walker DemoIndexProject {
    has sample_root: str;

    root {
        assert sample_root, "sample_root is required";
        summary = run_walker(IndexProject, {"root_path": sample_root, "mode": "full"});
        report {"indexed_root": sample_root, "summary": summary};
    }
}
